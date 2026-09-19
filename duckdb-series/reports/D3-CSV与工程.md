# 报告 D3 · CSV Reader 与工程质量(DuckDB 卷三)

> 基线:7e886f44(2026-09-17)——本报告核实:DuckDB 的 CSV reader 是"查表状态机 + 缓冲边界认领 + 嗅探打分"三位一体的核心内置算子(位于 `src/execution/operator/csv_scanner/`,注意目录名是 csv_scanner 而非 csv);工程质量体系则是"自研扩展版 sqllogictest(4900+ .test)+ OSS-Fuzz 三消毒剂矩阵 + Main.yml 单流水线多 job"的组合,版本号不再取自 git tag 而取自 `scripts/ci/release_version.txt`(当前 2.1)。

---

## 1. 代码地图与总体架构

CSV scanner 全部位于 `src/execution/operator/csv_scanner/`(仓库内无 `src/execution/operator/csv` 目录,亦无 `read_csv_binding` 文件),分七个子目录:

- `state_machine/`:csv_state_machine.cpp(22 行,薄封装)+ csv_state_machine_cache.cpp(495 行,转移表生成);
- `buffer_manager/`:csv_buffer / csv_buffer_manager / csv_file_handle / csv_random_access_buffer_manager / csv_sequential_buffer_manager;
- `scanner/`:string_value_scanner.cpp(2065 行,正式扫描)、column_count_scanner.cpp(224 行,嗅探专用)、skip_scanner.cpp、scanner_boundary.cpp(158 行)、csv_schema.cpp;
- `sniffer/`:csv_sniffer.cpp(261 行)+ dialect_detection.cpp(632 行)+ type_detection.cpp(571 行)+ header_detection.cpp(364 行)等;
- `table_function/`:global_csv_state.cpp(218 行,并行调度)、csv_file_scanner.cpp、csv_multi_file_info.cpp(490 行,bind);
- `util/`:csv_error.cpp(642 行)、csv_reader_options.cpp(875 行)、csv_validator.cpp;
- `encode/`:csv_encoder.cpp(148 行,把非 UTF-8 编码流转成 UTF-8 后再喂扫描器,见 csv_encoder.hpp:44-47)。

表函数入口在 `src/function/table/read_csv.cpp`(230 行):`read_csv`/`read_csv_auto` 是同一个 `MultiFileFunction<CSVMultiFileInfo>` 的两个名字(read_csv.cpp:171-184,注册于 186-189),另有独立表函数 `sniff_csv` 供"只嗅探不读取"(sniff_csv.cpp:39-48),`FROM 'x.csv'` 靠 replacement scan 改写成 read_csv_auto(read_csv.cpp:191-219)。

数据流:bind(CSVSchemaDiscovery 嗅探)→ CSVBufferManager 按 32MB 切块 → CSVGlobalState 发放 CSVIterator 边界 → 工作线程认领 boundary 构造 StringValueScanner → 逐字节查 256×19 转移表 → StringValueResult 组 chunk → 错误统一进 CSVErrorHandler 按行号顺序抛出。

关键设计动机(全部可在源码定位):
1. **消分支**:状态转移用预生成的 256 字符×19 状态二维数组直接查表,注释明言"动机是靠预测状态来消除常规 CSV 解析中的分支"(csv_state_machine.hpp:117-118);
2. **并行零通信**:线程间只通过 buffer 边界(boundary_idx)与"行号簿"LinesPerBoundary 协调,错误线程只缓存错误、由 error_handler 在轮到该 boundary 时按全局行号抛出(csv_error.cpp:24-38,63-85);
3. **嗅探即扫描**:sniffer 不另写解析器,而是与正式扫描复用同一套 ColumnCountScanner/StringValueScanner 与状态机(csv_sniffer.cpp:80-113);
4. **缓冲复用**:bind 阶段嗅探读过的 buffer 被 ReadCSVData.buffer_manager 持有,扫描阶段直接复用,避免二次 I/O(read_csv.hpp:72-74);
5. **确定性错误**:多线程下行号会乱,故用 validator 校验各线程 start/end 位置衔接(容 2 字节 `\r\n` 误差),不衔接则建议 `parallel=false`(csv_validator.cpp:20-44);
6. **最坏情况隔离**:脏数据可走 `store_rejects` 落入 rejects 表而非中断查询,scans 表还记录整次扫描的方言快照(13 列,global_csv_state.cpp:120-216)。

## 2. 状态机:19 个状态、256×19 查表、SWAR 加速

状态全集共 19 个(uint8_t 枚举):STANDARD、DELIMITER、三个多字节分隔符中间态(DELIMITER_FIRST/SECOND/THIRD_BYTE,支持 2-4 字节分隔符)、RECORD_SEPARATOR、CARRIAGE_RETURN、QUOTED、UNQUOTED、ESCAPE、INVALID、NOT_SET、QUOTED_NEW_LINE、EMPTY_SPACE、COMMENT、STANDARD_NEWLINE、UNQUOTED_ESCAPE、ESCAPED_RETURN、MAYBE_QUOTED(csv_state.hpp:16-38;NUM_STATES=19、NUM_TRANSITIONS=256 见 csv_state_machine_cache.hpp:22-23)。

转移只看"当前字节 + 上一状态",且状态是滑动的二元组(states[0]=旧态、states[1]=新态):

```cpp
// src/include/duckdb/execution/operator/csv_scanner/csv_state_machine.hpp:127-130
inline void Transition(CSVStates &states, char current_char) const {
    states.states[0] = states.states[1];
    states.states[1] = transition_array[static_cast<uint8_t>(current_char)]
                                     [static_cast<uint8_t>(states.states[1])];
}
```

转移表不是硬编码,而是按"分隔符/引号/escape/注释/换行风格/strict_mode"六元组在 CSVStateMachineCache 中现场生成并缓存(csv_state_machine_cache.cpp:13-52;状态机构造函数仅从 cache 取表, csv_state_machine.cpp:9-14;缓存键哈希组合见 csv_state_machine_cache.hpp:40-49)。strict_mode(RFC 4180)直接改变默认转移:非 strict 时 UNQUOTED 态遇到任意字节回 UNQUOTED(容忍未转义引号),strict 时回 INVALID;CARRIAGE_RETURN 态同理(csv_state_machine_cache.cpp:27-47)。进入引号域的转移也一目了然:

```cpp
// src/execution/operator/csv_scanner/state_machine/csv_state_machine_cache.cpp:117-128(节选)
// 2) Field Separator State
if (quote != '\0') {
    transition_array[quote][static_cast<uint8_t>(CSVState::DELIMITER)] = CSVState::QUOTED;
}
if (delimiter_first_byte != ' ') {
    transition_array[' '][static_cast<uint8_t>(CSVState::DELIMITER)] = CSVState::EMPTY_SPACE;
}
```

多字节分隔符按长度 2/3/4 分别展开成中间态转移,含首字节重复等边界情形(csv_state_machine_cache.cpp:144-171)。同一 cache 还生成三张"可跳过字节"表 skip_standard/skip_quoted/skip_comment 与 SWAR 停止模式,供 CSVByteSkipper 一次 64 字节块跳过普通字节(csv_state_machine_cache.hpp:25-33;csv_byte_skipper.hpp:17-31)——`SkipUntilState` 在 STANDARD/QUOTED 态即用它加速(string_value_scanner.cpp:1771-1780)。空文件也物化一个空 buffer(csv_buffer_manager.cpp:38-41);换行风格由首块 sniff 判定 `\r\n`/`\n`/`\r`(DetectNewLineDelimiter,dialect_detection.cpp:575-592)。

## 3. 嗅探:方言候选 × 打分 × 类型提升

**方言候选空间**:默认分隔符 `,` `|` `;` `\t`(dialect_detection.cpp:17-19);quote/escape 组合 9 种({'\0','\0'}、双引号×4 escape、单引号×4, dialect_detection.cpp:21-24);注释字符 `'\0'` 与 `'#'`(dialect_detection.cpp:26-28)。用户显式指定任一项都会裁剪候选集(dialect_detection.cpp:76-133)。GenerateStateMachineSearchSpace 按 注释×quote/escape×分隔符 三重循环生成全部状态机候选(dialect_detection.cpp:135-172)。

**打分**:每个候选用 ColumnCountScanner 前扫 `sniff_size=2048` 行(csv_reader_options.hpp:110),AnalyzeDialectCandidate 统计 consistent_rows/padding_count/dirty_notes/ignored_rows 后按布尔条件裁决(dialect_detection.cpp:316-334):`more_values`(行数更多且列数不低于当前最优)、`more_columns`(行数持平而列数更多)、`require_less_padding`、`single_column_before`、`rows_consistent`(脏行+注释+空行+跳行之后行数对账)、`invalid_padding`(不允许 padding 却有 padding 即出局)。两条软偏好值得注意:出现过引号的候选被优先("Give preference to quoted boys",dialect_detection.cpp:384),而 `ignore_errors + 非 null_padding` 时改用"众数列数"而非最大列数(dialect_detection.cpp:237-239)。注释字符候选另设 3/5 多数派门槛(AreCommentsAcceptable,min_majority=0.6,dialect_detection.cpp:175-209)。胜出候选需再跑 RefineCandidates 在最多 `sample_size_chunks=10` 个 chunk 上逐个复验、失败换下一候选(dialect_detection.cpp:501-545;sample_size_chunks 定义 csv_reader_options.hpp:116)。

**类型候选提升**:候选栈按"特异性升序"排列,先试栈顶,转换失败则 pop;`auto_type_candidates` 默认序为 VARCHAR→DOUBLE→BIGNUM→HUGEINT→BIGINT→TIMESTAMP_TZ→TIMESTAMP→DATE→TIME→BOOLEAN→SQLNULL,注释明言"按特异性升序排列"(csv_reader_options.hpp:84-93)。试转统一走 CanYouCastIt 的逐类型 switch(type_detection.cpp:148-300):

```cpp
// src/execution/operator/csv_scanner/sniffer/type_detection.cpp:417-455(节选)
auto cur_top_candidate = col_type_candidates.back();
while (col_type_candidates.size() > 1) {
    const auto &sql_type = col_type_candidates.back();
    ...
    if (CanYouCastIt(...)) { break; }
    if (row_idx != start_idx_detection &&
        (cur_top_candidate == LogicalType::BOOLEAN || ... )) {
        // 布尔/日期/时间误判 → 立即弹到 VARCHAR(type_detection.cpp:441-451)
        while (col_type_candidates.back() != LogicalType::VARCHAR) {
            col_type_candidates.pop_back();
        }
        break;
    }
    col_type_candidates.pop_back();
}
```

某列若从未被弹过(候选数仍等于全集)说明全是空值,兜底 VARCHAR(csv_sniffer.cpp:143-147)。日期/时间戳先识别分隔符模板(StartsWithNumericDate 要求"数字+分隔符+数字+分隔符+数字"结构,type_detection.cpp:23-75),再从 6/7 个 strftime 模板中挑且跳过 ISO 8601(csv_sniffer.hpp:182-187;type_detection.cpp:330-343)。表头判定:首行各列类型与数据行完全一致且非全 VARCHAR 时才认为无表头(header_detection.cpp:264-286)。嗅探总量:单文件约 10 chunk×2048 行(≈20480 行,csv_reader_options.hpp:110-116);多文件 bind 时 CSVSchemaDiscovery 对前 `files_to_sniff=10` 个文件累计嗅到 20480 行为止(csv_multi_file_info.cpp:68-92);扫描阶段每个文件再走 AdaptiveSniff:先 MinimalSniff(单 chunk 快速定列数/类型/表头, csv_sniffer.cpp:80-144),出错或与统一 CSVSchema 不匹配才回落完整 SniffCSV(csv_sniffer.cpp:146-160;csv_file_scanner.cpp:37)。

## 4. 并行模型:边界认领、错误恢复、列数不一致

**切块与认领**:buffer 默认大小 = ROWS_PER_BUFFER(16)×maximum_line_size 默认 2,000,000 = 32,000,000 字节(csv_buffer.hpp:96-97;csv_reader_options.hpp:98,122),与 csv_buffer.hpp:41-42 的"32Mb"注释一致。每个 buffer 切成 4 份:BytesPerThread = buffer_size/16×4 即 buffer_size/4(scanner_boundary.cpp:36-50,ROWS_PER_THREAD=4 定义于 scanner_boundary.hpp:81)。CSVGlobalState::Next 顺序发放 boundary,lstate 只带迭代器与 buffer_tracker,真正的 StringValueScanner 由工作线程在认领(claim)后才构造:

```cpp
// src/execution/operator/csv_scanner/table_function/global_csv_state.cpp:47-64(节选)
void CSVLocalState::Materialize() {
    D_ASSERT(claim_state == ClaimState::PENDING && !csv_reader);
    csv_reader = make_uniq<StringValueScanner>(scanner_idx, file_scan->buffer_manager,
        file_scan->state_machine, file_scan->error_handler, file_scan, false, iterator,
        STANDARD_VECTOR_SIZE, true);
    ...
    claim_state = CSVLocalState::ClaimState::MATERIALIZED;
}
```

认领未执行即析构也要在行号簿上补一条记录,保证后续行号计算正确(global_csv_state.cpp:47-54)。CSVBufferUsage 析构时 ResetBuffer 释放该块(string_value_scanner.hpp:18-28)。

**单/多线程开关**:满足 `文件数>1 且 文件数>2×系统线程数` 或用户 `parallel=false` 时整体单线程(global_csv_state.cpp:17-21);单线程 iterator 不设边界(scanner_boundary.cpp:122-126)。文件句柄能否 seek 决定走 CSVRandomAccessBufferManager(可无 I/O 预知每块字节区间,KnownBufferCount/KnownBufferSize 纯算术, csv_buffer_manager.cpp:35-50)还是 CSVSequentialBufferManager(边读边缓存,遇递归 CTE 重扫需 Reset,管道文件则直接拒绝递归 CTE, csv_sequential_buffer_manager.cpp:21-52)。近期还引入 GetBufferResidency/TryPin:线程可"只查块驻留状态而不阻塞",不驻留则 scanner 置 suspended 让出,由加载路径补齐后再续(csv_buffer_manager.hpp:43-44;csv_buffer.hpp:80-93;string_value_scanner.cpp:1984-1997 的 MoveBufferResult::NOT_IN_MEMORY 分支)。

**错误在哪个线程报**:任何线程发现格式错误(UNTERMINATED_QUOTES/INVALID_STATE/超行宽等,错误类型全集 CAST_ERROR→INVALID_STATE 共 10 种, csv_error.hpp:29-39)都只调 CSVErrorHandler::Error;若尚未轮到该 boundary(CanGetLine 按"前面 boundary 是否全部完成"判定)则缓存,否则直接抛(csv_error.cpp:63-72)。ThrowError 还会在多个缓存错误里挑"全局行号最小"的一个,先打 "CSV Error on Line: N" 与原始行(csv_error.cpp:24-56,行号打点在 41)。行号由 LinesPerBoundary(每 boundary 行数)累加重放得到(csv_error.hpp:24-28,131-132)。

**校验兜底**:FinishFile 时(多线程且未忽略错误)跑 validator.Verify():各 scanner 提交 {start_pos, end_pos} 区间,按 boundary 顺序检查衔接,超出 2 字节 `\r\n` 余量即抛 NotImplementedException 建议单线程重试(global_csv_state.cpp:109-117;csv_validator.cpp:20-44)。

**列数不一致**:多列按 strict_mode 二分——strict 下首个超出的值若为 NULL(且 allow_quoted_nulls)可豁免,否则记 TOO_MANY_COLUMNS;非 strict 直接吞掉并置 used_unstrictness(string_value_scanner.cpp:162-181)。少列仅在未开 null_padding 时逐列记 TOO_FEW_COLUMNS(string_value_scanner.cpp:861-866);是否致命由 ignore_errors/store_rejects 决定(global_csv_state.cpp:110-112)。嗅探期则完全不同:少列行在允许 padding 的候选里计 padding_count,更大的 num_cols 行可回头把之前的行全部"变成"待 padding 行(dialect_detection.cpp:259-273);ignore_errors 众数策略下不一致行直接计入 ignored_rows(dialect_detection.cpp:267-281)。

## 5. ASCII:CSV 多线程读入管线

```
 read_csv('f.csv')  [src/function/table/read_csv.cpp:171-178]
        │  bind: OpenCSV→CSVFileHandle(压缩/编码感知)      csv_buffer_manager.cpp:16-29
        ▼
 ┌─ CSVBufferManager(32MB/块 = 16×2MB max_line)────────────────────┐
 │  RandomAccess(可seek,区间可算)或 Sequential(边读边缓存)   │
 └───────┬──────────────────────────────────────────────────────────┘
         │ GetBuffer(i) / TryPin(只查驻留,不阻塞)
         ▼
   [Buf0 32MB] [Buf1 32MB] [Buf2] ... 每块切 4 个 boundary(8MB/线程)
         │        scanner_boundary.cpp:36-50 (buffer/16×4)
         ▼
 CSVGlobalState::Next() 顺序发放 boundary_idx → 工作线程认领(PENDING→MATERIALIZED)
         │        global_csv_state.cpp:66-94
         ▼
 ┌─ 线程A StringValueScanner ─┐ ┌─ 线程B ... ─┐   逐字节:
 │ states = STA[byte][state]  │ │            │   csv_state_machine.hpp:127-130
 │ STANDARD/QUOTED 态 SWAR 跳过│ │            │   string_value_scanner.cpp:1771-1780
 └──────┬─────────────────────┘ └─────┬──────┘
        │ StringValueResult(DataChunk)│
        ▼                             ▼
   CSVErrorHandler(共享): 错误按 boundary 顺序缓存 → 按全局行号抛出
   CSVValidator: 各线程 start/end 衔接校验(±2B \r\n 余量)   csv_validator.cpp:20-44
        ▼
 FinishFile: validator.Verify() → error_handler.ErrorIfAny() → FillRejectsTable
              global_csv_state.cpp:104-118
```

与 Parquet 一句话对比:Parquet reader 是 extension(默认静态内嵌,extension/extension_config.cmake:11-12)、由 footer 元数据驱动的 row group 粒度并行(extension/parquet/parquet_reader.cpp:1968-2108),无需嗅探;CSV 是核心内置算子,按"字节边界 + 状态机重定位行首"并行,一切 schema 知识都得靠嗅探猜出来。

## 6. sqllogictest:自研扩展的 .test 体系

runner 在 test/sqlite/(不是 tools/sqllogictest,后者只余 tools/sqllogic/tests 空壳)。README 明言代码源自 SQLite 的 SQLLogicTest,DuckDB 已大幅扩展(test/sqlite/README.md:3-8)——是 vendored 后重写的 C++,不是调用上游二进制。语法核心仍是 `statement <期望>` 与 `query <列类型串>`,期望值支持 ok/error/…;parser 指令全集 26 种:

```cpp
// test/sqlite/sqllogic_parser.hpp:19-46(节选)
enum class SQLLogicTokenType {
    SQLLOGIC_INVALID,
    SQLLOGIC_SKIP_IF,
    SQLLOGIC_ONLY_IF,
    SQLLOGIC_STATEMENT,
    SQLLOGIC_QUERY,
    SQLLOGIC_HASH_THRESHOLD,
    SQLLOGIC_HALT,
    SQLLOGIC_MODE,
    SQLLOGIC_SET,
    SQLLOGIC_RESET,
    SQLLOGIC_LOOP,
    SQLLOGIC_FOREACH,
    SQLLOGIC_CONCURRENT_LOOP,   // 并发循环:同一 SQL 多连接并发跑
    ...
    SQLLOGIC_TAGS,              // 标签:CI 按标签选择/跳过
    SQLLOGIC_INCLUDE
};
```

Runner 层把 statement/query 定义为"可计数断言"(IsCountableStatement),mode/loop/load 属"基建命令"(sqllogic_command.hpp:78-82);Query 结构带 expected_column_count 与 SortStyle(sqllogic_command.hpp:120-134);statement 支持期望错误文本(sqllogic_parser.hpp:95-96)。组织方式:test_sqllogictest.cpp 递归遍历测试目录,把每个 `.test`/`.test_slow`/`.test_coverage` 注册为一个 Catch2 用例(test_sqllogictest.cpp:38-47):

```cpp
// test/sqlite/test_sqllogictest.cpp:38-41
static bool IsSQLLogicTestFile(const string &path) {
    return endsWith(path, ".test") || endsWith(path, ".test_slow")
        || endsWith(path, ".test_coverage");
}
```

规模:全仓 `*.test` 4936 个,其中 test/sql 下 4130 个、`*.test_slow` 754 个,仅 test/sql/copy/csv 下就有 268 个 CSV 专项用例。test/smoke_tests.list 是快速冒烟白名单,由 `make smoke` 以 `--test-list` 消费(Makefile:627)。扩展指令 tags 支持 `--skip-tag slow --select-tag-set "['memory>=64GB']"`(AND 语义集合、OR 内多值),且 require-env/test_env 会自动生成隐式 `env[VAR]` 标签(test/sqlite/README.md:20-37)。每个用例运行在独立临时目录与 HOME 沙箱中(RunSQLLogicTest, test_sqllogictest.cpp:51-64)。

## 7. fuzz 基建、CI 与发行工程

**fuzz 三层**:(1) OSS-Fuzz 对接:`.github/workflows/cifuzz.yml` 以 address/undefined/memory 三消毒剂矩阵构建 fuzzers(cifuzz.yml:29-40),并按路径过滤忽略 md/tools 变更(cifuzz.yml:8-14);测试源在 test/ossfuzz/——csv_json_fuzz_test.cpp 用首字节选 4 条路径,轮换打 `read_csv_auto`(注释点名 CSVSniffer/CSVStateMachine/StringValueScanner/类型与方言检测)与显式列定义的 `read_csv`,以及 JSON 函数(test/ossfuzz/csv_json_fuzz_test.cpp:1-56),payload 限 8192 字节防超时(csv_json_fuzz_test.cpp:21-24);seeds 为 clusterfuzz 回归样例(test/ossfuzz/cases/clusterfuzz-test-*)。(2) 历史语料回归:test/fuzzer/ 下 afl(15 个)、sqlsmith、duckfuzz、pedro 的 .test 文件直接并入 sqllogictest 回归。(3) test/memoryleak 与 ExtendedTests.yml 的专项夜跑。

**CI**:入口 Main.yml(约 1200+ 行),先 prepare job 做"runner 探测 → 解析 commit/版本 → 改动检测 → Lint CI → 选择启用 job"(Main.yml:76-200),后续 job 全部以 `needs: prepare` + `contains(enabled_jobs)` 门控。代表 job:

```yaml
# .github/workflows/Main.yml:256-262(节选)
      - name: Check format
        run: |
          make format-check-silent enum-integrity-check extension-patch-check -j -Otarget
          echo "::group::Check generated files"
          make generate-files
          git diff --exit-code
```

`linux-relassert` 以 release 构建开启慢验证器与消毒剂跑测试(Main.yml:264-266,355);Tidy Check 用 clangd(Main.yml:380-398);另有 Build/Deploy extensions(Main.yml:416-500)。工作流文件共 25 个:Main、OnPR、NightlyTests(113 个 job 名)、ExtendedTests、ExtraTests、Windows/OSX/Android/Swift、coverity、cifuzz、Regression 等;注意没有名为 `_reformat` 的 job——格式检查在 prepare 尾部的 `Check format` 步骤。extension-patch-check 校验 `.github/patches/extensions` 对扩展源码的补丁仍可应用(Makefile:773-775);enum-integrity-check 用脚本核对 C API 枚举(Makefile:770-771)。

**发行工程**:版本三级来源——环境 `DUCKDB_VERSION`/`OVERRIDE_GIT_DESCRIBE` 优先;否则读 `scripts/ci/release_version.txt`(内容 `2.1`)得主次版本,dev 迭代号用 `git rev-list --count HEAD`;git hash 截前 10 位小写写入(CMakeLists.txt:428-500),hash 非法(非十六进制、<10 或 >64 位)直接 FATAL_ERROR(CMakeLists.txt:470-478)。扩展机制一句话:构建期由 `DUCKDB_EXTENSION_NAMES` 经 configure_file 生成 generated_extension_headers.hpp 与加载器,`SHOULD_LINK` 的扩展(默认 core_functions 与 parquet,见 extension/extension_config.cmake:10-12)直接静态链接进主库并随启动注册;运行期 INSTALL/autoload 才走动态下载路径(extension/CMakeLists.txt:1-40;generated_extension_loader.hpp:17-29;autoload 失败提示见 extension_install.cpp:351)。

## 8. 纠偏(以本 commit 源码为准)

1. **"状态机只服务嗅探"是过时注释**:csv_state_machine.hpp:118 声称"The State Machine is currently utilized solely in the CSV Sniffer",但正式扫描路径 StringValueScanner 全程调用 `state_machine->Transition`(string_value_scanner.cpp:1275,1472,1485,1757),引用该注释会得出错误架构图。
2. **目录名不是 csv**:常见转述写 `src/execution/operator/csv/`,实际是 `src/execution/operator/csv_scanner/`;task 假设的 `read_csv_binding` 文件不存在,绑定逻辑在 `table_function/csv_multi_file_info.cpp` 与 `src/function/table/read_csv.cpp`。
3. **"CI 有 _reformat job"不成立**:格式检查是 Main.yml prepare 内的 `Check format` 步骤(Main.yml:256-262),无独立 reformat workflow;`.github/workflows/` 下实有 25 个文件(第 7 节清单)。
4. **"32MB 缓冲是拍脑袋常数"不准确**:32MB = 16(ROWS_PER_BUFFER)× 2,000,000(maximum_line_size 默认),均为具名常量且联动;用户把 buffer_size 调小于 max_line_size 会被自动抬升并同步(csv_reader_options.hpp:98,122;csv_reader_options.cpp:284-286,301-305)。
5. **"版本号取 git tag"不成立**:除非显式传 DUCKDB_VERSION,版本来自 scripts/ci/release_version.txt(当前 2.1)+ rev-list 计数,git describe 仅作 OVERRIDE 输入(CMakeLists.txt:428-500)。
6. **"DuckDB 直接用上游 sqllogictest"不成立**:runner 是 vendored 后重写的 C++,新增 loop/concurrent/tags/test_env/restart 等 26 种指令(sqllogic_parser.hpp:19-46;test/sqlite/README.md:3-8);且工具目录是 test/sqlite 而非 tools/sqllogictest。
7. **"多线程 CSV 一定更快"要限定**:文件数超过 2×线程数时强制单线程逐文件扫(global_csv_state.cpp:17-21);多线程完整读还须 validator 通过,否则建议 parallel=false(csv_validator.cpp:34-40);管道文件不允许递归 CTE(csv_sequential_buffer_manager.cpp:32-34)。
8. **"嗅探在扫描前只跑一次"已不精确**:bind 时全量嗅探一次,扫描时每文件还有 AdaptiveSniff(MinimalSniff 快路径 + 不合格才全量重嗅,csv_sniffer.cpp:80-146;csv_file_scanner.cpp:37)。

## 9. FAQ 候选

1. **CSV 状态机有多少状态?** 19 个(uint8_t 枚举,含 3 个多字节分隔符中间态),查表 256×19(csv_state.hpp:16-38;csv_state_machine_cache.hpp:22-23)。
2. **状态机转移表是硬编码的吗?** 不是,按分隔符/引号/escape/注释/换行/strict_mode 六元组现场生成并按键复用(csv_state_machine_cache.cpp:13-52)。
3. **默认方言候选有哪些?** 分隔符 `,` `|` `;` `\t`,quote/escape 9 种组合,注释 `'\0'`/`'#'`(dialect_detection.cpp:17-28)。
4. **嗅探最多看多少数据?** 单文件约 10 chunk×2048 行(≈20480 行);多文件扩到前 10 个文件累计 20480 行(csv_reader_options.hpp:110-116)。
5. **类型嗅探候选顺序?** VARCHAR→DOUBLE→BIGNUM→HUGEINT→BIGINT→TIMESTAMP_TZ→TIMESTAMP→DATE→TIME→BOOLEAN→SQLNULL,自顶向下弹栈,VARCHAR 兜底(csv_reader_options.hpp:84-93;type_detection.cpp:417-455)。
6. **并行时格式错误由哪个线程抛出?** 由"轮到出错 boundary"的线程按全局最小行号抛,其他线程只缓存(csv_error.cpp:24-56,63-85)。
7. **多列/少列怎么处理?** 多列 strict 下报 TOO_MANY_COLUMNS(NULL 首溢可豁免)、非 strict 吞掉;少列未开 null_padding 才报 TOO_FEW_COLUMNS(string_value_scanner.cpp:162-181,861-866)。
8. **一个 buffer 被几个线程分?** 4 个 boundary(buffer_size/4),32MB 即每线程约 8MB(scanner_boundary.cpp:36-50;scanner_boundary.hpp:81)。
9. **validator 是干什么的?** 校验各线程扫描区间首尾衔接(容 ±2 字节 \r\n),断裂说明无法并行完整读,建议 parallel=false(csv_validator.cpp:20-44)。
10. **sqllogictest 支持哪些 DuckDB 扩展指令?** 26 种,含 loop/concurrent_loop、tags、require-env、restart/reconnect、test_env 等(sqllogic_parser.hpp:19-46)。
11. **OSS-Fuzz 怎么打 CSV?** csv_json_fuzz_test 首字节选 4 条路径,把任意字节流直接喂给 read_csv_auto/read_csv,cifuzz 用 ASan/UBSan/MSan 三矩阵(test/ossfuzz/csv_json_fuzz_test.cpp:20-56;cifuzz.yml:29-40)。
12. **哪些扩展静态内嵌?** 默认 core_functions 与 parquet,由构建期生成的 headers/loader 注册进主库(extension/extension_config.cmake:10-12;extension/CMakeLists.txt:1-40)。

## 10. 深挖方向

1. **string_value_scanner.cpp 的 over-buffer 长值路径**(ProcessOverBufferValue/ProcessExtraRow,string_value_scanner.cpp:1271-1510):跨 buffer 值拼接、双状态机(state_machine 与 state_machine_strict)并用(string_value_scanner.cpp:1757,1775)的语义与开销值得单独一节。
2. **CSVByteSkipper/SWAR 与 skip_* 表的生成逻辑**(csv_byte_skipper.hpp 全文;csv_state_machine_cache.cpp 的 stop_patterns 计算):64 字节块位掩码如何在 STANDARD/QUOTED 两态间保证安全跳过。
3. **csv_sequential_buffer_manager 的"预取+让出"调度**:GetBufferResidency/TryPin/suspended 协作下的 I/O 与计算重叠,可与卷二 Buffer Manager 的 eviction 机制对照。
4. **sniffer 决策测试覆盖**:test/sql/copy/csv 下 268 个用例 + afl/sqlsmith 语料如何反推打分规则;可用 DialectCandidates::Print 复现候选空间(dialect_detection.cpp:30-74)。
5. **CI 矩阵经济学**:Main.yml prepare 的 job 选择机制(enabled_jobs)、smoke_tests.list 与 4936 个全量用例的分层耗时权衡、NightlyTests 113 个 job 的分组策略;统计 test/executions.csv(仓库自带执行统计)。

## 11. 正文蒸馏要点

1. CSV scanner 位于 `src/execution/operator/csv_scanner/`(非 csv 目录),核心三件套是状态机、buffer manager、sniffer;`read_csv`/`read_csv_auto` 同一实现两个名字,注册于 read_csv.cpp:186-189。
2. 状态机是 256×19 查表转移,按 dialect 六元组现场生成、cache 复用,strict_mode 直接改写默认转移目标(csv_state_machine_cache.hpp:22-23;csv_state_machine_cache.cpp:27-47)。
3. 方言打分以 consistent_rows/num_cols/padding 为主轴,偏好"出现过引号"与"更少 padding";ignore_errors 时列数取众数(dialect_detection.cpp:316-334,384,230-231)。
4. 类型候选按特异性升序排栈、自顶向下弹栈试转,VARCHAR 永远兜底;布尔/日期/时间误判一次性弹到 VARCHAR(csv_reader_options.hpp:84-93;type_detection.cpp:441-451)。
5. 并行单位是 boundary(默认 buffer/4),CSVGlobalState 顺序发放、线程认领后自建 scanner,解析状态零跨线程共享(global_csv_state.cpp:66-94;scanner_boundary.cpp:36-50)。
6. 错误恢复的关键是"缓存 + 按全局行号重放":CSVErrorHandler 依据 boundary 完成度决定何时抛,保证错误带准确行号(csv_error.cpp:24-85);validator 兜底校验线程区间衔接(csv_validator.cpp:20-44)。
7. 列数不一致:strict 多列报错(NULL 首溢豁免)、少列在无 null_padding 时报错;嗅探期则用 padding 计数软处理,允许大列数行"顶掉"前文(string_value_scanner.cpp:162-181,861-866;dialect_detection.cpp:259-273)。
8. 多文件 bind 时统一 schema(CSVSchemaDiscovery,前 10 文件、≈20480 行),扫描时每文件 AdaptiveSniff 快速校验、不合格才全量重嗅(csv_multi_file_info.cpp:68-92;csv_sniffer.cpp:80-146)。
9. 与 Parquet 的架构差异:Parquet 靠 footer 元数据、row group 并行、无嗅探,且是默认静态内嵌的 extension;CSV 一切并行与 schema 都要从字节流"猜"并靠状态机重定位(extension/extension_config.cmake:10-12;parquet_reader.cpp:1968-2108)。
10. 测试基建是自研 sqllogictest(vendored 自 SQLite 并扩展 26 种指令),4936 个 .test 文件(4130 个在 test/sql,CSV 专项 268 个),每文件注册为一个 Catch2 用例(sqllogic_parser.hpp:19-46;test_sqllogictest.cpp:38-47)。
11. fuzz 三层:OSS-Fuzz 三消毒剂矩阵 + test/ossfuzz 定向 fuzz(csv_json_fuzz_test)+ 历史 AFL/sqlsmith 语料转正为回归 .test(cifuzz.yml:29-40;test/fuzzer/)。
12. CI 强制"生成物零漂移"(generate-files 后 git diff --exit-code)与枚举完整性、扩展补丁可应用性检查;版本号源自 scripts/ci/release_version.txt(2.1)而非 git tag(Main.yml:256-262;Makefile:770-775;CMakeLists.txt:476-500)。

---

*报告完毕。所有行号以 commit 7e886f44428e90c8379d4d34e2afb866108ff079 工作区为准。*
