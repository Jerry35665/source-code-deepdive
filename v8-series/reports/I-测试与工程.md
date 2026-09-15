# I — 测试与工程：V8 的测试金字塔、变体哲学与 Chromium 共生

> 基于 V8 源码 commit `c6a1f7c2`（2026-09-14，浅克隆）。所有行号均为该 commit 下的仓库相对路径实际核对值。
> 本章是精简卷卷末（第 5 章），对照系列前作：Git bats / FFmpeg FATE / zstd decodecorpus / caddytest 的测试文化。

---

## 1. 全景：V8 测试金字塔

V8 的测试资产按"抽象层级"分四层，越往上数量越多、越贴近用户；越往下越贴近 C++ 内部实现：

```
                          ▲  覆盖面 / 真实性
        ┌─────────────────────────────────────────────┐
        │  fuzzers（Fuzzilli REPRL / libFuzzer wasm /  │   无穷输入
        │  foozzie 差分 / js_fuzzer / num_fuzzer)      │   持续轰炸
        ├─────────────────────────────────────────────┤
        │  test262（TC39 官方一致性，DEPS 拉取 data/)   │   规范即规格
        │  + mozilla / webkit（历史兼容语料）           │
        ├─────────────────────────────────────────────┤
        │  mjsunit（~9280 个 .js，JS 级行为测试）        │   引擎行为
        │  + inspector / debugger / message / intl     │
        ├─────────────────────────────────────────────┤
        │  cctest（自研宏挂 C++ 单测，test-api.cc 3.2万行）│  内部实现
        │  unittests（gtest，463 个 *-unittest.cc）     │  白盒
        └─────────────────────────────────────────────┘
                          ▼  精确性 / 可诊断性
```

数据支撑：
- mjsunit 有 9280 个 .js 文件（`find test/mjsunit -name '*.js' | wc -l`），其中 `test/mjsunit/regress/` 下 3944 个回归测试，`test/mjsunit/compiler/` 下约 1000 个编译器测试。
- unittests 有 463 个 `*-unittest.cc`，按 src/ 目录结构镜像组织为 40 个子目录（api/builtins/compiler/heap/maglev/wasm/zone…，见 `test/unittests/` 目录列表）。
- cctest 约 170 个 .cc/.h 文件；单 `test/cctest/test-api.cc` 就有 32198 行（`wc -l`），是 API 面的"百科全书"。
- 统一入口：`tools/run-tests.py` 只有 15 行，真正驱动器在 `tools/testrunner/`（`tools/run-tests.py:11-15` 直接实例化 `StandardTestRunner`）。文档入口是 `docs/test.md:9-33`（`gm x64.release.check` 用法）。

套件编组（哪些套件算"默认要跑"）定义在 `tools/testrunner/base_runner.py:38-56` 的 `TEST_MAP`：`bot_default` 包含 debugger/mjsunit/cctest/wasm-spec-tests/inspector/webkit/bigint/mkgrokdump/wasm-js/fuzzer/message/intl/unittests/wasm-api-tests/filecheck 共 15 个套件，并注明"必须与 test/BUILD.gn 的 group('v8_bot_default') 同步"（`base_runner.py:39`）。

---

## 2. mjsunit 专节：一个断言库 + 一条 natives 语法 + 一个 status 文件

### 2.1 断言库 mjsunit.js

`test/mjsunit/mjsunit.js`（1016 行）被注入每一个测试之前执行（`test/mjsunit/testcfg.py:99-102`：除非源码里有 `// NO HARNESS`，否则命令行总是先挂 `mjsunit.js`）。文件头注释道破天机：

```js
/* This file is included in all mini jsunit test cases.  The test
 * framework expects lines that signal failed tests to start with
 * the f-word and ignore all other lines. */
```
（`test/mjsunit/mjsunit.js:58-62`——测试框架只认 "Failure"/"Failed" 开头的失败行）

断言函数全览（均在 `test/mjsunit/mjsunit.js`）：
- 基础：`assertSame`:501、`assertEquals`:511（深相等，`deepEquals`:423 递归比对内部属性）、`assertArrayEquals`:532、`assertTrue`:564、`assertFalse`:569、`assertNull`:574、`assertInstanceof`:675。
- 异常：`assertThrows`:607（可校验异常类型 + message 正则）、`assertThrowsEquals`:627、`assertThrowsAsync`:637、`assertEarlyError`:656（专测解析期 early error）、`assertThrowsAtRuntime`:666（专测运行期错误——把"何时抛"本身变成可断言对象）。
- 异步：`assertPromiseResult`:735，用一个全局 `promiseTestChain`:766 把所有 promise 测试串成一条链，失败时用 `setTimeout` 重抛以逃出 promise 链（:748-751），并用 `concatenateErrors`:722 拼接栈。
- 失败输出：`MjsUnitAssertionError`:28 自定义 `prepareStackTrace`:959，过滤掉 mjsunit 自身帧（:962-980）让栈直接指向业务测试行。

### 2.2 natives syntax：把优化器的内部状态变成断言对象

V8 最独特的测试手法：`--allow-natives-syntax`（`src/flags/flag-definitions.h:3334`，默认 false）允许在 JS 里直接调用 `%Foo` 形式的内部 runtime 函数。`src/runtime/runtime-test.cc`（2949 行，156 个 `RUNTIME_FUNCTION`）就是这些"测试后门"的总汇。

三段式测优化器的标准范式（`test/mjsunit/compiler/abstract-equal-oddball.js:5-25`，文件第 5 行 `// Flags: --allow-natives-syntax --turbofan`）：

```js
%PrepareFunctionForOptimization(foo);      // 12 行:声明要测的函数
assertFalse(foo(2, true));                 // 13-16:解释器下先跑,收集反馈
%OptimizeFunctionOnNextCall(foo);          // 17 行:强制下一调用走优化
assertFalse(foo(2, true));                 // 18-21:优化代码下同样正确
assertOptimized(foo);                      // 22 行:断言"确实处于优化态"
assertFalse(foo(0, null));
assertUnoptimized(foo);                    // 25 行:null 使假设失效→应急去优化
```

- `%OptimizeFunctionOnNextCall` 的 C++ 实现在 `src/runtime/runtime-test.cc:374-419`：校验可优化性后调 `JSFunction::RequestOptimization`，第二个参数 `"concurrent"` 可切换并发模式（:390-399）；配套的 `%PrepareFunctionForOptimization` 在 :634。
- OSR 用独立后门 `%OptimizeOsr()`（`test/mjsunit/compiler/osr-simple.js:11`，循环内第 11 次迭代触发）。
- 状态位查询：`%GetOptimizationStatus` 返回位图，JS 侧在 `test/mjsunit/mjsunit.js:186-210` 定义了 23 个位（kOptimized/kMaglevved/kTurboFanned/kInterpreted/kBaseline/kTopmostFrameIsMaglev…），注释强调"必须与 Runtime_GetOptimizationStatus 同步"（:185）。
- 由此派生出一族"层级探测器"：`isInterpreted`:872、`isBaseline`:880、`isMaglevved`:899、`isTurboFanned`:929、`topFrameIs*`:937-955。分层编译的每一级都有对应的测试探针。
- `assertOptimized`:819 / `assertUnoptimized`:784 内置了妥协逻辑：当 `--deopt-every-n-times` 之类 stress flag 出现时"不再保证具体函数是否仍被优化"，此时放行继续跑（:789-795 注释），保证同一份测试在 stress 变体下不死。

**为什么用 natives syntax？** 因为"优化器是否触发""是否发生了去优化"不是 JS 可观察行为，黑盒无法直接断言。V8 选择给测试开一条只属于测试的后门，而不是靠计时/启发式猜测。代价是 `%` 语法污染了测试源码——所以它是默认关闭的 flag（`flag-definitions.h:3334`），且 diff fuzzer 有专门开关 `--allow-natives-for-differential-fuzzing`（`flag-definitions.h:3338`）。

### 2.3 status 文件：3500 行的期望数据库

`test/mjsunit/mjsunit.status`（3504 行）用 `[条件, {规则}]` 段落表达"哪些测试在哪些配置下期望什么"。语义常量（SKIP/FAIL/PASS/SLOW/CRASH/NO_VARIANTS/FAIL_OK…）定义在 `tools/testrunner/local/statusfile.py:36-60`。典型段落：

- `[ALWAYS, { ... }]`：无条件规则，如 `'bugs/*': [FAIL]`（:47-48，"bug 目录里的测试本来就该失败"——把已知错误固化成回归资产）、辅助库跳过 `'wasm/wasm-module-builder': [SKIP]`（:37-40 附近）。
- flaky 显式标注：`'setters-on-elements': [PASS, FAIL]`（:53-55，双期望=接受偶发失败）。
- 条件段：`['mode == debug', {...}]`:505、`['gc_stress', {...}]`:657-747——gc_stress 模式下大量测试要 SKIP/SLOW，这本身就是 stress 测试成本的账本。
- 建构变量条件：`['not has_webassembly or (variant == jitless ...)', {...}]`:802+，测试期望可以感知二进制的编译配置。

### 2.4 测试文件协议与合批

每个 mjsunit 测试是自包含脚本，头部 `// Flags: ...` 注释声明所需 flag，由 `test/mjsunit/testcfg.py:38` 的 `FILES_PATTERN`/flag 正则解析（`_parse_source_flags`，:108）；`// Files:` 可挂载依赖文件（:38,:84-96）。runner 还会把"同 flag 的无依赖测试"合批进一个 d8 进程跑（`TestCombiner.get_group_key`:148-165），但把 `--trace*`、`--harmony*` 等易互相干扰的 flag 列入 `MISBEHAVING_COMBINED_TESTS_FLAGS` 黑名单禁止合批（:43-55）。

---

## 3. 变体（variants）哲学：stress 是主武器

V8 测试文化最核心的一点：**同一个测试矩阵 × 几十个 flag 配置 = 几十倍测试面**。变体定义集中在 `tools/testrunner/local/variants.py`：

- `ALL_VARIANT_FLAGS`（:6-170）共 60+ 个变体。`"default": []`（:11）是零 flag 基线；`"stress"`（:135-140）= `--no-liftoff --stress-lazy-source-positions --no-wasm-generic-wrapper --no-wasm-lazy-compilation`——注意它禁掉 WASM 的快速基线编译器 Liftoff，强制一切走优化管线。
- 更多 stress 家族：`stress_maglev`:61-64、`stress_concurrent_inlining`:142、`stress_incremental_marking`:150、`stress_snapshot`:151、`stress_concurrent_allocation`:141、`nooptimization`:130-132（关掉所有优化编译器，专测解释器/Liftoff-only）。
- 每个变体还声明与其他 flag 的矛盾集 `INCOMPATIBLE_FLAGS_PER_VARIANT`（:189-304），runner 在装载时自动展开取反并做一致性校验（:322-329）。
- 别名分组在 `tools/testrunner/standard_runner.py:42-57`：`dev`=[default]（开发者日常，:33）、`more`=[stress, stress_js_bg_compile_wasm_code_gc, stress_incremental_marking, future]（:35-40，所有 CI bot 都跑）、`exhaustive`=more+dev（:50-51）、`extra`=[jitless, nooptimization, …]（:53-56，子集 bot）。
- GC 压力不走变体而走 flag 注入：`GC_STRESS_FLAGS = ['--gc-interval=500', '--stress-compaction', … '--stress-flush-code', '--flush-bytecode', '--wasm-code-gc', …]`（`standard_runner.py:59-64`），`--gc-stress` 选项直接叠加（:158-159）；随机版 `RANDOM_GC_STRESS_FLAGS`（:66-67）。
- 快慢分级调度：`SLOW_VARIANTS = {stress, stress_snapshot, nooptimization}`（`variants.py:422-426`）优先调度（跑得久先启动），`FAST_VARIANTS={default}` 最后（:428-441）。
- 本地快速自检 `--quickcheck` = `stress,default` 两个变体 + 跳过慢测（`standard_runner.py:186-190`）——连快速检查都要带一个 stress，可见其地位。

**stress 变体为什么是主武器？** 因为 V8 的 bug 高发区不是"功能错"，而是"并发时序错 / GC 时机错 / 分层切换错"。这些 bug 在 default 配置下概率极低，stress flag 把低概率事件变成必然事件（如 `--gc-interval=500` 每 500 次分配必 GC，把"GC 打断任意代码"从百万分之一变成二百分之一）。同一份测试文件在 60 个变体下重放，等于用一份维护成本买 60 份时序覆盖。这与 zstd 的 decodecorpus"受控随机生成合法输入"是同一哲学的两种粒度：zstd 随机输入，V8 随机**执行环境**。

---

## 4. test262 专节：一致性测试的组织

- 语料不进 V8 仓库：`test/test262/data` 由 DEPS 钉死到 tc39/test262 的具体 revision（`DEPS:220-221`，`gclient sync` 拉取；`test/test262/README` 明确说明只有 DEPS 版本保证通过）。
- 适配层 `test/test262/testcfg.py`（291 行）：`FEATURE_FLAGS`（:44-72）把 test262 的 feature 前缀映射成 V8 flag（如 `'iterator-helpers': '--harmony-iterator-helpers'`），未实现的 feature 进 `SKIPPED_FEATURES`（:74）。
- 严格模式展开：`VariantsGenerator.gen`（:89-110）把每个测试跑两遍——默认一遍 + `--use-strict` 一遍；`onlyStrict`/`noStrict` frontmatter（:103-105）决定只跑其一。规范测试天然双模。
- 期望文件 `test/test262/test262.status`（1246 行）：少量 `[FAIL]` 项（:38-51 是一组复合赋值的历史偏差）就是 V8 与规范的全部已知分歧面。
- CI 权重：`infra/testing/builders.pyl:43` 显示主 bot 上 test262 配 **12 个 shards**（mjsunit 的 v8testing 才 4 个，:44），一致性测试的机器成本可见一斑。

对照：FFmpeg 用 FATE 自建语料库 + 参考哈希；V8 则直接把 TC39 的规范测试集作为外部钉版依赖——"规范即测试"由上游社区共同维护，V8 只维护适配器与 skip 清单。

### 3.1 mjsunit 内部的分工版图

顶层 9280 个文件不是平铺的，子目录各自承担明确的测试职责：
- `compiler/`（约 1000 个）：TurboFan/Maglev 优化正确性，natives syntax 密集区；OSR 一族就有 49 个 `osr-*.js`（`test/mjsunit/compiler/` 目录）。
- `regress/`（3944 个）：bug 修复回归库，命名直接用 issue 号（如 `regress-748069`），是"每个修复必须带测试"政策的时间胶囊；其中 `regress/modules-skip*` 等辅助文件在 status 里被显式 SKIP（`test/mjsunit/mjsunit.status:32-36`）。
- `wasm/`（530 个）：WASM 的 JS API 面 + `wasm-module-builder.js` 这个用 JS 手工拼 wire bytes 的构建库（在 status :40 被标为辅助库 SKIP）。
- `es6/ es7/ es8/ es9/ harmony/ ignition/ baseline/ maglev/ lithium/`：按语言版本与执行层级归档，目录名本身就是引擎演进史（lithium 是已淘汰的旧后端，测试仍在）。
- `sandbox/`：沙箱自攻击测试（见第 6 节第 5 条）；`bugs/`：已知失败（status :47-48 全目录 FAIL）。
- 期望值冲突的仲裁全部走 status 文件而非改测试——期望与实现分离。

---

## 5. C++ 双轨单测：cctest 与 unittests

### 5.1 cctest：自研宏、进程内 Isolate

`test/cctest/cctest.h:72-78` 定义 `TEST(Name)` 宏——把测试函数注册进全局 `CcTest` 对象（静态构造期自注册，gtest 风格但**不用 gtest**）：

```cpp
#ifndef TEST
#define TEST(Name)                                                     \
  static void Test##Name();                                            \
  CcTest register_test_##Name(Test##Name, __FILE__, #Name, true, true, \
                              nullptr, nullptr);                       \
  static void Test##Name()
#endif
```
（另有 `UNINITIALIZED_TEST`:80-86、`TEST_WITH_FLAGS`:88-94（单测自带 flag）、`TEST_WITH_PLATFORM`:96-108（自定义平台实现）、`DISABLED_TEST`:110-115。）

cctest 的特色是测试与真实 Isolate/堆同进程共存（`cctest.h` 直接 include factory/heap 头，:33-45），适合测 GC、API、编译器后端等需要操控内部对象的部分；`test/cctest/compiler/` 下还有 35 个 TurboFan 后端测试。期望管理用 `test/cctest/cctest.status`（506 个规则条目）。

### 5.2 unittests：gtest 主阵地

`test/unittests/` 依赖 `//testing/gtest`（`test/unittests/BUILD.gn:54` 等 7 处），463 个 `*-unittest.cc` 按 src/ 目录镜像。典型风格是"图归约器白盒测试"——直接构造 TurboFan 节点图、跑单一 Reducer、断言图被正确化简（`test/unittests/compiler/branch-elimination-unittest.cc:15-28` 的 `BranchEliminationTest::Reduce()`，`TEST_F` 用例在 :37 起）。解释器侧有金标准文件机制：`bytecode_expectations/*.golden` 由 `generate-bytecode-expectations` 工具再生成（`docs/test.md:76-105`）。
新动向：unittests 里已接入 Google FuzzTest（`test/unittests/fuzztest.cc:18` `#ifdef V8_ENABLE_FUZZTEST`，域约束示例 :65-66），单测与 fuzz 的边界正在融合。

---

## 6. fuzz 专节：四个入口覆盖四种面

1. **Fuzzilli（JS 深度模糊）**：`test/fuzzilli/` 提供 REPRL 协议端（`README.md:3` 说明用 `libreprl.c` fork+exec d8、管道通信、子进程复用），覆盖率经 Clang SanitizerCoverage 共享内存回传（`README.md:9-11`）。这是学术 fuzz器 Fuzzilli 的官方集成。
2. **libFuzzer 结构化 wasm fuzz**：`test/fuzzer/`（`README.md:1-8` 教你新增一个 libFuzzer 入口）。wasm 侧不是乱喂字节，而是**结构化生成合法模块**：`test/fuzzer/wasm/compile.cc:12-20` 的 `WasmCompileMVPFuzzer::GenerateModule` 调 `GenerateRandomWasmModule` 生成合法 wire bytes，再 `LLVMFuzzerTestOneInput`（:29-33）执行；同目录还有 compile-simd/compile-wasmgc/streaming/deopt/async/module 等入口，把每个 wasm 子系统各开一个 fuzz 面。
3. **差分 fuzzer foozzie**：`tools/clusterfuzz/foozzie/v8_foozzie.py:24` 起 `CONFIGS` 定义多组"同一 JS、不同执行配置"（ignition=纯解释器、ignition_turbo、no-ic 等，:26-46），同一输入在多配置下结果必须一致，不一致即正确性 bug。这是对"分层编译应当语义等价"这一不变量的机器检验。配套 mock（`v8_mock.js` 等）让 Math.random/Date 可复现。
4. **num_fuzzer + js_fuzzer**：`tools/testrunner/num_fuzzer.py:28` `DEFAULT_SUITES = ["mjsunit", "webkit", "benchmarks"]`——把现有 mjsunit 测试本身当作 fuzz 语料随机串烧（配合 `test/mjsunit/mjsunit_numfuzz.js` 替身 harness，`test/mjsunit/testcfg.py:63,:104-105`）；`tools/clusterfuzz/js_fuzzer/README.md` 则是 mutation 式 JS fuzzer，语料库来自浏览器测试套件。
5. **安全侧**：`test/mjsunit/sandbox/` 配合 `--expose-memory-corruption-api`（`test/mjsunit/sandbox/memory-corruption-api.js:5`）直接暴露 `Sandbox.MemoryView`，让 fuzzer 能读写沙箱内任意内存、主动验证沙箱防线（实现在 `src/sandbox/testing.h:20-29`）。这是"给攻击者先发武器"的自攻击测试姿态。

---

## 7. 工程文化专节：V8 先行，Chromium 拉取

- **CI 拓扑（简）**：V8 用 Luci/Swarming，测试规格是 src-side 的 `infra/testing/builders.pyl`（2953 行）：开发者改 CL 时就声明"这个 flag 组合要在哪个 bot 跑"（`infra/testing/README.md:3-8`——"必须跑在 runtime flag 后面的特性，应映射为 variants.py 里的命名变体"）。这就是 src-side 规格 + CQ 门禁的模型，infra 侧 recipe 只认 builder 名。
- **与 Chromium 的依赖方向**：V8 的构建/测试基建全部从 Chromium 拉取——`DEPS:59` 定义 `chromium_url`，`DEPS:164-166` 钉 build/buildtools 版本，连 CPython 都是 chromium 定制版（`DEPS:80`）。测试语料（test262/mozilla）也是 V8 自己 DEPS 钉版（`DEPS:219-221`）。方向是：**V8 main 先行验证，Chromium 按 milestone 拉取 V8**；Chromium 侧再由自己的 CI 跑布局/浏览器级测试。V8 没有 LTS：分支 `refs/branch-heads/12.1` 式命名（`docs/release-process.md:24-30`），Beta 转 Stable 后旧 Stable 分支即停止维护（:66）。
- **发布节奏**（`docs/release-process.md`）：Canary 每天（:11）、Dev 每周（:17）、Beta 约每 2 周切分支（:22）、Stable 约 4 周晋升（:34-36）。版本号 `x.y.z.w`：x.y = Chromium milestone ÷ 10，z 随 LKGR 自动跳，w 是 backmerge 补丁数（`docs/version-numbers.md:5-11`）。本仓库 `include/v8-version.h:11-12` 为 `V8_MAJOR_VERSION 15 / V8_MINOR_VERSION 5`（对应 M155）。
- **维护者模型**：多平台OWNER文件（根目录 `OWNERS`、`PPC_OWNERS`、`RISCV_OWNERS`、`S390_OWNERS`、`LOONG_OWNERS`、`MIPS_OWNERS` 等）——架构移植方各自守门；`docs/become-committer.md`/`committer-responsibility.md` 描述社区提交者制度。
- **开发者工作流**：入口是 `gm`（build+test 一键）与 `tools/run-tests.py`（`docs/test.md:14-33`），调试 flaky 有专门文档 `docs/flake-bisect.md`；性能回归另立一套微基准 `test/js-perf-test/`，由独立驱动器 `tools/run_perf.py` 跑（`docs/test.md:45-52`）——正确性与性能的测试管线在 V8 是物理分离的。
- **测试即数据**：所有套件的期望（status 文件）、金标准（bytecode golden）、语料（test262/mozilla DEPS 钉版）都是数据而非代码；runner（`tools/testrunner/`）是通用解释器。新增一套测试 = 一个 `testcfg.py` + 一个 status 文件 + 一行 TEST_MAP/bot 配置，不需要改框架。

---

## 8. 三种测试形态的谱系（对照前作）

| 维度 | Git bats（进程外 CLI） | zstd decodecorpus（反证法） | V8（natives+变体） |
|---|---|---|---|
| 被测对象 | shell 命令的 stdout/exit code | 解压器的"必须拒绝坏输入" | 优化器的"必须语义等价 + 必须真的优化" |
| 断言媒介 | 文本比对 | ` CU_assert ` 生成/破坏 corpus | JS 断言 + `%GetOptimizationStatus` 位图 |
| 随机性 | 无 | 受控随机合法输入 | 受控随机**执行环境**（stress flag 矩阵） |
| 白盒度 | 0（黑盒） | 中（知道格式不变量） | 高（runtime 后门直读内部状态） |
| caddytest 对照 | — | — | caddytest 用进程内 HTTP 请求断言配置行为；V8 的 cctest 同样进程内、共享真实 Isolate |

FFmpeg FATE 与 test262 同属"外部语料钉版"谱系：FATE 自有语料库+哈希，V8 的 test262 则是上游社区共同维护的规范语料，V8 只付适配器 + 12 shards 的机器成本。共同的洞见：**大项目的测试资产应沉淀为独立于主线代码的数据（语料/期望文件），由 runner 解释**——V8 的 status 文件（mjsunit.status 3504 行 + cctest.status + unittests.status + test262.status + fuzzer.status…）就是这套"期望数据库"的极端形态。

---

## 9. 设计动机：为什么是 natives syntax 与 stress 变体

1. **可观察性缺口**：JS 语义层看不到"函数是否被优化/去优化/在哪个层级"。要测"优化器触发了且结果正确"，只能开后门。`%PrepareFunctionForOptimization` 先确保反馈向量存在（`runtime-test.cc:421-443` 的 `EnsureCompiledAndFeedbackVector`），否则优化无从谈起——这暴露了优化依赖反馈的真实工程约束。
2. **把不变量变成可断言**：`assertOptimized`/`assertUnoptimized` 让"分层切换正确性"成为一行断言（`mjsunit.js:819/:784`），而不是玄学。`assertThrowsAtRuntime`（:666）同理把"错误时机"变成断言。
3. **stress 换概率**：并发 bug 无法确定性复现，就提高触发频率。`--gc-interval=500`（`standard_runner.py:59`）、`--stress-compaction`、60 个变体（`variants.py:6-170`）把时序空间系统性扫过。status 文件里整段的 `['gc_stress', {SKIP…}]`（:657-747）坦诚标注了这一武器的误伤率。
4. **容忍不确定性的测试框架**：`assertOptimized` 在 `--deopt-every-n-times` 下主动放行（`mjsunit.js:789-795`）、`[PASS, FAIL]` 双期望（`mjsunit.status:53-55`）、`RerunProc` 自动重跑——V8 接受"有些测试只能概率性通过"，用框架层机制管理 flaky，而不是假装它不存在。
5. **为什么 status 文件不直接写进测试？** 因为期望是"测试 × 配置"矩阵的函数，不是测试本身的属性：同一个测试在 default 下 PASS、gc_stress 下 SLOW、jitless 下 SKIP、debug 下 CRASH。把矩阵维度的知识外置到集中式数据库（`mjsunit.status` 按 `[variant == …]` 段组织，见 :657 起），实现变更时只需审一处 diff；这也让"某个变体的总误伤面"成为可审计的单一数字。

---

## 10. FAQ 素材

1. **mjsunit 是什么？** "mini jsunit"，文件头自嘲注释见 `test/mjsunit/mjsunit.js:58-62`；9280 个 JS 文件，每文件一个主题，头部 `// Flags:` 声明配置。
2. **`%OptimizeFunctionOnNextCall` 是语言特性吗？** 不是。它是 `--allow-natives-syntax`（默认关闭，`flag-definitions.h:3334`）下的测试后门，实现在 `runtime-test.cc:590`。
3. **为什么测试里先 `%PrepareFunctionForOptimization` 再 `%OptimizeFunctionOnNextCall`？** 优化需要反馈向量，前者确保它存在（`runtime-test.cc:421-443`）。
4. **stress 变体是什么？** `variants.py:135-140` 定义的 flag 组合，禁 Liftoff、强制懒源位置等，用于在每次 CI 都必现低概率时序 bug；CI 上所有 bot 都跑 `more` 别名（`standard_runner.py:35-40`）。
5. **V8 怎么跑 ECMAScript 一致性？** DEPS 钉版拉取 tc39/test262（`DEPS:220-221`），`test/test262/testcfg.py` 适配（feature→flag 映射 :44-72，严格模式双跑 :89-110），分歧记在 `test262.status`。
6. **cctest 和 unittests 为什么有两套 C++ 测试？** cctest 自研宏（`cctest.h:72-78`）+ 进程内共享 Isolate，适合堆/API 白盒；unittests 用 gtest（`BUILD.gn:54`）做纯函数/图归约级单测。历史演进 + 测什么决定用哪个。
7. **V8 怎么 fuzz？** Fuzzilli（REPRL，`test/fuzzilli/README.md`）+ libFuzzer 结构化 wasm（`test/fuzzer/wasm/compile.cc`）+ foozzie 差分（`v8_foozzie.py:24`）+ num_fuzzer 测试串烧（`num_fuzzer.py:28`）四路并进。
8. **V8 有 LTS 吗？** 没有。跟随 Chrome 四通道：每日 Canary、双周 Beta 分支、四周 Stable（`docs/release-process.md:11-36`），backmerge 走 `branch-heads/x.y`。
9. **怎么本地快速跑测试？** `gm x64.optdebug.check` 或 `tools/run-tests.py --outdir=out/x64.optdebug mjsunit/regress/regress-123`（`docs/test.md:18-33`）；快速烟测 `--quickcheck`（`standard_runner.py:186-190`）。
10. **沙箱怎么测试自身安全性？** `--expose-memory-corruption-api` 暴露 MemoryView 给测试/fuzzer 直接改内存，验证逃逸防线（`test/mjsunit/sandbox/memory-corruption-api.js:5`、`src/sandbox/testing.h:20-29`）。

## 11. 深挖方向

1. `%GetOptimizationStatus` 的 23 个位如何随分层编译（Ignition→Sparkplug→Maglev→TurboFan）演化，`mjsunit.js:186-210` 与 `runtime-test.cc` 对应实现的位同步机制。
2. `TestCombiner` 合批算法（`test/mjsunit/testcfg.py:148-170`）：同 flag 测试合并进一个 d8 进程对总测试时长的影响估算。
3. foozzie 差分配置的"语义等价不变量"边界：`v8_suppressions.py` 里豁免了哪些合法分歧。
4. FuzzTest 在 unittests 的扩散程度（`test/unittests/fuzztest.cc`）——单测与 fuzz 融合是否会成为 Chromium 系新范式。
5. status 文件的条件 DSL 完整语法（`tools/testrunner/local/statusfile.py:59-60` 的 ALWAYS/NO_VARIANTS/FUZZ_RARE 等）与 `variants.py` 的 INCOMPATIBLE 校验（:322-329）如何共同防止"变体 × 期望"组合爆炸失控。

---

## 写作要点速查表

| 事实 | 文件:行号 |
|---|---|
| 断言库（f-word 注释/自注册错误类） | test/mjsunit/mjsunit.js:58-62, :28 |
| 23 个优化状态位定义 | test/mjsunit/mjsunit.js:186-210 |
| assertOptimized / assertUnoptimized（stress 放行） | test/mjsunit/mjsunit.js:819, :784-795 |
| natives 三段式测试范式 | test/mjsunit/compiler/abstract-equal-oddball.js:5-25 |
| %OptimizeFunctionOnNextCall 实现 | src/runtime/runtime-test.cc:374-419 |
| allow_natives_syntax 默认关闭 | src/flags/flag-definitions.h:3334 |
| stress 变体定义（60+ 变体总表/default 空表） | tools/testrunner/local/variants.py:135-140, :6-170 |
| 变体别名 dev/more/exhaustive + GC_STRESS_FLAGS | tools/testrunner/standard_runner.py:42-57, :59-64 |
| status 文件语义（bugs/* FAIL、gc_stress 段） | test/mjsunit/mjsunit.status:47-48, :657-747 |
| 测试合批与 Flags 注释解析 | test/mjsunit/testcfg.py:38-55, :148-165 |
| test262 DEPS 钉版 + feature→flag + 严格双跑 | DEPS:220-221; test/test262/testcfg.py:44, :89-110 |
| cctest 自研 TEST 宏 / unittests 用 gtest | test/cctest/cctest.h:72-78; test/unittests/BUILD.gn:54 |
| wasm 结构化 fuzz / Fuzzilli REPRL / foozzie 差分 | test/fuzzer/wasm/compile.cc:12-33; test/fuzzilli/README.md:3; tools/clusterfuzz/foozzie/v8_foozzie.py:24 |
| CI 规格 builders.pyl（test262 12 shards） | infra/testing/builders.pyl:42-44 |
| 发布节奏（Canary 日/Beta 双周/Stable 四周）/版本号 | docs/release-process.md:11-36; docs/version-numbers.md:5-11 |
| 套件编组 TEST_MAP（15 套件） | tools/testrunner/base_runner.py:38-56 |

（完，约 340 行）
