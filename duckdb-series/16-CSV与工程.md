# 第 16 章 · CSV Reader 与工程质量:查表状态机与确定性行号

> 基线:commit `7e886f44`。核心:src/execution/operator/csv_scanner/(七个子目录)与 test/tools 基建。

## 16.0 全景:多线程 CSV 管线

```
 read_csv('f.csv')(read_csv.cpp:171-178;FROM 'x.csv' 经 replacement scan 改写 read_csv_auto)
   │ bind:CSVSchemaDiscovery 嗅探(≈10 chunk×2048 行)
   ▼ CSVBufferManager(32MB/块=16×2MB max_line;可 seek 走 RandomAccess,管道走 Sequential)
   ▼ 每块切 4 个 boundary(scanner_boundary.cpp:36-50)
   ▼ CSVGlobalState::Next() 顺序发放 boundary → 工作线程认领后才构造 StringValueScanner
   ▼ 逐字节查 256×19 转移表(states[byte][state],csv_state_machine.hpp:127-130)
   │  STANDARD/QUOTED 态用 SWAR 一次 64 字节块跳过(string_value_scanner.cpp:1771-1780)
   ▼ StringValueResult 组 chunk;错误进共享 CSVErrorHandler 按全局行号抛出
```

纠偏:"状态机只用于嗅探"是本 commit 中**仍存在的过时注释**(csv_state_machine.hpp:118)——实际正式扫描路径 StringValueScanner 全程查表(:1275, 1472-1757);目录名是 csv_scanner 而非 csv,也不存在 read_csv_binding(绑定在 csv_multi_file_info.cpp+read_csv.cpp:171-189)。

## 16.1 状态机:19 状态、现场生成、SWAR 跳过

状态全集 19 个(STANDARD/QUOTED/ESCAPE/多字节分隔符中间态/COMMENT 等,csv_state.hpp:16-38);转移只看"当前字节+上一状态"的滑动二元组。转移表**不是硬编码**——按"分隔符/引号/escape/注释/换行风格/strict_mode"六元组现场生成并缓存(csv_state_machine_cache.cpp:13-52);strict_mode(RFC 4180)直接改变默认转移:非 strict 容忍未转义引号,strict 回 INVALID(:27-47)。同一 cache 还生成三张"可跳过字节"表供 CSVByteSkipper 块级跳过(csv_state_machine_cache.hpp:25-33)。注释明言设计动机:"靠预测状态来消除常规 CSV 解析中的分支"(csv_state_machine.hpp:117-118)。

## 16.2 嗅探:候选打分与类型提升

方言候选空间:分隔符 `,|;\t`×quote/escape 9 组×注释 `'\0','#'`(dialect_detection.cpp:17-28);每候选用 ColumnCountScanner 前扫 2048 行,按 consistent_rows/more_columns/require_less_padding 等布尔条件裁决(:316-334);出现过引号的候选优先(:384),胜出者再在最多 10 个 chunk 上复验(:501-545)。类型候选栈按特异性升序:VARCHAR→DOUBLE→…→BOOLEAN,试转失败则 pop;**布尔/日期误判立即弹到 VARCHAR**(:417-455);全空列兜底 VARCHAR(csv_sniffer.cpp:143-147)。表头判定:首行类型与数据行完全一致且非全 VARCHAR 才算无表头(header_detection.cpp:264-286)。

## 16.3 并行模型:边界认领与确定性行号

单/多线程开关:文件数>1 且 >2×线程数,或用户 parallel=false 时单线程(global_csv_state.cpp:17-21)。错误恢复是"**缓存+按全局行号重放**":任何线程发现格式错误只缓存到共享 CSVErrorHandler,由"轮到出错 boundary"的线程按全局最小行号抛出(csv_error.cpp:24-56, 63-85);行号由 LinesPerBoundary 累加重放。CSVValidator 兜底校验各线程区间衔接(容 2 字节 \r\n 余量),断裂建议 parallel=false(csv_validator.cpp:20-44)——这是"无锁并行却仍给出确定性行号报错"的关键。列数不一致按 strict_mode 二分;脏数据可走 store_rejects 落 rejects 表而非中断查询。

## 16.4 工程质量:sqllogictest 重写版 + 三消毒剂矩阵

sqllogictest runner 是 vendored 后重写:支持 **26 种扩展指令**(sqllogic_parser.hpp:19-46),仓库内有 **4936 个 .test** 文件。CI 没有 `_reformat` job——格式检查是 Main.yml prepare 内 `Check format` 步骤:强制 `make generate-files` 后 `git diff --exit-code` 零漂移(Main.yml:256-262)。OSS-Fuzz 是三消毒剂矩阵(cifuzz.yml:29-40)。纠偏:**版本号不取 git tag**,而取 `scripts/ci/release_version.txt`(当前 2.1)+ rev-list 计数(CMakeLists.txt:476-500)。

## 16.5 设计动机

1. **消分支查表**:256×19 二维数组直接转移,常规解析零分支(csv_state_machine.hpp:127-130);
2. **并行零通信**:线程间只通过 buffer 边界与行号簿协调,错误按 boundary 顺序重放(csv_error.cpp:24-38);
3. **嗅探即扫描**:sniffer 复用同一套 Scanner 与状态机,不写第二套解析器(csv_sniffer.cpp:80-113);
4. **缓冲复用**:嗅探读过的 buffer 被持有,扫描阶段免二次 I/O(read_csv.hpp:72-74);
5. **rejects 隔离**:脏数据落表而非中断,scans 表记录方言快照 13 列(global_csv_state.cpp:120-216);
6. **零漂移格式门禁**:生成文件后 diff 必须为空,防手改生成物(Main.yml:256-262)。

## 16.6 FAQ

**Q1:状态机表是硬编码的吗?**
不是,按六元组现场生成并缓存(csv_state_machine_cache.cpp:13-52)。

**Q2:支持多字节分隔符吗?**
支持 2-4 字节,展开成 DELIMITER_FIRST/SECOND/THIRD_BYTE 中间态(:144-171)。

**Q3:嗅探读多少数据?**
单文件约 10 chunk×2048 行;多文件前 10 个文件累计 20480 行(csv_reader_options.hpp:110-116)。

**Q4:错误在哪个线程抛?**
轮到出错 boundary 的线程,按全局最小行号(csv_error.cpp:63-85)。

**Q5:断裂的并行读会怎样?**
Validator 校验区间衔接,失败建议 parallel=false(csv_validator.cpp:20-44)。

**Q6:buffer 多大、怎么切?**
32MB/块,每块切 4 份 boundary(scanner_boundary.cpp:36-50)。

**Q7:非 UTF-8 文件呢?**
csv_encoder 先转 UTF-8 再喂扫描器(csv_encoder.hpp:44-47)。

**Q8:sniff_csv 是什么?**
独立表函数,只嗅探不读取(sniff_csv.cpp:39-48)。

**Q9:空文件会崩吗?**
不会,物化一个空 buffer(csv_buffer_manager.cpp:38-41)。

**Q10:版本号从哪来?**
release_version.txt+rev-list 计数,不取 git tag(CMakeLists.txt:476-500)。

## 16.7 小结与深挖方向

本章结论:**CSV=查表状态机+边界认领+嗅探打分三位一体;工程=自研 sqllogictest(4936 test)+零漂移门禁+三消毒剂 fuzz**。深挖:

1. CSVByteSkipper 的 SWAR 掩码生成与边界回退(csv_byte_skipper.hpp:17-31);
2. TryPin/buffer residency 的挂起-续扫状态机(string_value_scanner.cpp:1984-1997);
3. 日期模板识别的 strftime 候选与 ISO 8601 跳过逻辑(type_detection.cpp:330-343);
4. sqllogictest 26 种扩展指令全集与并发验证模式(sqllogic_parser.hpp:19-46);
5. rejects 表与 scans 表的元数据 schema(global_csv_state.cpp:120-216)。
