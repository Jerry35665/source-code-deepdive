# F - 工程文化与测试体系

> 调研对象:SQLite 3.54.0(commit `5251f4d7` 对应 manifest.uuid,manifest 记录日期 2026-08-27;`VERSION` 文件内容为 `3.54.0`)。
> 本文所有结论均来自对仓库的实际浏览,标注格式为 `文件:行号`。行号以该版本为准。

---

## ① 工程文化全景:"boring engineering" 的具体表现

"boring engineering" 在 SQLite 里不是一句口号,而是可以逐条指认的制度与工件。以下按"证据强度"排列:

**1. 所有制与贡献模型被写死在文档里。** 仓库根目录的 `AGENTS.md` 开宗明义:源码是 public domain,任何文件都不应添加版权头;顶部那段"blessing"注释(愿你有好有坏、愿你有赦免、愿你自由分享)是有意为之,必须原样保留(`AGENTS.md` "Project nature" 节;实际样板见 `src/test1.c:1-9`、`test/select1.test:1-9`)。SQLite 不接受未经事先同意/法律文书(将贡献放入 public domain)的 PR;人类开发者只把 PR 当作 proof-of-concept 审阅,然后**自己重新实现**。甚至明确写了"SQLite does not accept agentic code",但接受带可复现测试用例的 bug 报告。这套流程的本质是:把"知识产权洁净性"放在"贡献速度"之上——这是 boring engineering 的第一性原理。

**2. 每次提交前至少跑一遍 devtest。** `main.mk:1848-1853` 的注释原话:"This is the testing target preferred by the core SQLite developers... The devs run `make devtest` prior to each check-in, at a minimum. Probably other tests too, but at least this one."。`devtest` 目标先做 `srctree-check`(校验生成文件与源树一致,见 `main.mk:1854`、`tool/srctree-check.tcl:1-10`)再跑 `testrunner.tcl mdevtest`。纪律不是靠 CI 提醒,而是靠 Makefile 里的注释与目标组织固化的。

**3. 生成文件一律不手改。** `AGENTS.md` "Do not edit generated files" 给出完整对照表:`sqlite3.h` ← `tool/mksqlite3h.tcl`;`parse.c/parse.h` ← lemon + `src/parse.y`;`opcodes.h` ← `tool/mkopcodeh.tcl`(直接读 `src/vdbe.c` 提取 opcode);`keywordhash.h`、`pragma.h`、`sqlite3.c`(amalgamation)← `tool/mksqlite3c.tcl`。连编译期选项的自省文件 `ctime.c` 都是生成的(`main.mk:1207` `ctime.c: $(TOP)/tool/mkctimec.tcl`),仓库里根本不存在 `src/ctime.c`。添加 PRAGMA 的官方路径是先改 `tool/mkpragmatab.tcl` 再再生成 `pragma.h`(`AGENTS.md` "Editing rules")。

**4. 编码规约偏保守到刻板。** `AGENTS.md` "Coding conventions":仅 C89/C99 兼容 C,无 C++、无 VLA;所有内存分配必须走 `sqlite3Malloc`/`sqlite3_malloc64`,禁止裸 `malloc`;可能超过 2G 的数值一律用 `i64`,禁用裸 `long`;错误传播统一 `SQLITE_OK`/`SQLITE_*` 返回码 + OOM 时设置 `db->mallocFailed` 延迟判错;"Assert liberally for invariants"。

**5. 历史包袱被平静地保留。** `test/select1.test:14` 仍保留 CVS 时代的 `$Id: select1.test,v 1.70 2009/05/28 01:00:56 drh Exp $` 标签——比 Fossil 更早的历史。`src/tclsqlite.c` 甚至内嵌了一段"Copy of tclsqlite.h"(tclsqlite.c:32-51)以便单独追加编译,并手写了 Tcl 8.6/9.0 兼容宏(`Tcl_Size`、`Tcl_BounceRefCount`,tclsqlite.c:36-50)。这种"不优雅但稳定"的选择随处可见。

**6. 量级感受。** `test/` 目录 1288 个条目,其中 1194 个 `.test` 文件、31 个 `.c` 辅助程序、约 30 个 `.tcl` 公共库;对 `test/*.test` 与 `ext/*/test/*.test` 粗略统计,`do_test`/`do_execsql_test`/`do_catchsql_test`/`do_malloc_test`/`do_ioerr_test`/`do_faultsim_test`/`do_eqp_test` 断言调用约 44,000 处。支撑这一切的 C 侧测试代码有 36 个 `src/test_*.c` 文件(合计中 `src/test1.c` 一个就 9535 行)。

一句话概括:SQLite 的文化是把"可复制性"(同一份输入、同一份工具链、同一个版本号能复现一切)和"最小惊讶"(API 不变、行为不变、文件头不变)当成产品特性来维护。

---

## ② 测试金字塔逐层解读

SQLite 的测试体系常被外部概括为"百万级测试用例、100% 分支覆盖",本节按仓库内可见的分层自下而上解读。注意:仓库中只有公开层,顶层的 TH3 仓库里不存在代码,仅作概述。

**第 0 层:测试基础设施(testfixture)。** 测试不是用 shell 脚本或 pytest,而是把 SQLite 自己 + 36 个 `src/test_*.c` 编成一个增强版 TCL 解释器 `testfixture`(`main.mk:722-816` 的 `TESTSRC`/`TESTSRC2` 列表;`main.mk:1802-1804` `TESTFIXTURE_SRC = $(TESTSRC) tclsqlite-ex.c`)。运行入口是 `test/main.test`(单体文件)、`test/testrunner.tcl`(并行跑全量,AGENTS.md "Testing" 节)。所有 `.test` 文件第一行都是 `set testdir [file dirname $argv0]; source $testdir/tester.tcl`(如 `test/select1.test:15-16`)。

**第 1 层:TCL 单元/回归测试。** 框架核心是 2626 行的 `test/tester.tcl`:
- `do_test NAME SCRIPT EXPECTED`(tester.tcl:703):执行脚本、比对结果,支持三种"软断言"——`/RE/` 正则、`~/RE/` 反向正则、`#...#` 数值区间(±10%,tester.tcl:747-760 起),并在每个用例前调用 `sqlite3_memdebug_settitle` 把用例名传给 C 侧(tester.tcl:709),这样 OOM 崩溃时错误信息能定位到具体用例。
- 高阶封装:`do_execsql_test`(tester.tcl:941)、`do_catchsql_test`(973,断言 SQL 错误码)、`do_eqp_test`(1048,断言查询计划)、`do_select_tests`(1103,表驱动批量)。
- 每个文件结束的 `finish_test`(tester.tcl:1237)统一收尾;`slave_test_file`(tester.tcl:2392)保证隔离性:每个 `.test` 在**新建的 slave interpreter** 里执行,`::G` 数组整体复制进去(tester.tcl:2368-2375),跑完后检查 `sqlite_open_file_count` 归零(文件句柄泄漏检查,tester.tcl:2415-2420)、shared-cache 全局开关未被脚本篡改(tester.tcl:2423-2428)、PRNG 状态重置。

代表性文件组织(三种不同风格):
- `test/select1.test`(1234 行):最古老的风格,用例编号 `select1-1.1`、`select1-1.2`…(select1.test:21-61),手工断言列提取、JOIN 等 SELECT 语义;
- `test/main.test`(481 行):按源文件对应,测 `main.c` 暴露的 `sqlite3_complete()`,首尾用 `ifcapable {complete}` 守卫编译裁剪(main.test:22-27);
- `test/wal.test`:混合风格,`source lock_common.tcl`、`malloc_common.tcl`、`wal_common.tcl` 三件套(wal.test:21-23),文件头注释直接说明主题是 `PRAGMA journal_mode=WAL`;`ifcapable !wal {finish_test; return}`(wal.test:26)声明对编译特性的依赖。
- `test/e_expr.test`:文档测试(见下文 EVIDENCE-OF),注释明确写 "verify that the 'testable statements' in the lang_expr.html document are correct"(e_expr.test:17-19)。

**第 2 层:故障注入(fault injection)。** 这是 SQLite 区别于大多数项目的杀手锏,全部在 `testfixture` 内以 C 钩子实现:
- OOM 注入:`sqlite3_memdebug_fail N -repeat R` 让第 N 次 malloc 失败并重复(`src/test_malloc.c:544`,TCL 绑定注册于 test_malloc.c:1437;TCL 封装在 `test/malloc_common.tcl:193`)。`test/malloc.test:10-16` 注释明确了机制:"causes the N-th malloc to fail"。
- I/O 错误注入:`do_ioerr_test ioerr-1 -erc 1 -ckrefcount 1 -sqlprep {...} -sqlbody {...}`(`test/ioerr.test:33-55`),枚举脚本中第 1..N 次 I/O 调用分别失败,并校验引用计数/校验和。
- 统一故障框架:`malloc_common.tcl:32-46` 定义 `FAULTSIM(oom-transient)`、`FAULTSIM(oom-persistent)`、I/O 错误等注入器,`do_faultsim_test`(malloc_common.tcl:121)统一驱动。
- (注:传闻中的 `sqlite3HaltMalloc` 并不存在,仓库内 grep 为 0 命中;等价物即 `sqlite3_memdebug_fail`。)

这里藏着"百万用例"数字的真正来源:`do_malloc_test`(如 malloc.test:60-70 的 `do_malloc_test 1 -tclprep {...} -tclbody {...} -sqlbody {...}`)内部是一个**故障序号循环**——malloc_common.tcl:681 的 `if {$::DO_MALLOC_TEST} {sqlite3_memdebug_fail $iFail -repeat $nRepeat}` 会让同一段测试逻辑对"第 1 次、第 2 次……第 N 次 malloc 失败"各跑一遍,N 由该脚本实际 malloc 次数决定;`do_ioerr_test` 对 I/O 调用同理(ioerr.test:29-33 之前的注释甚至逐条解释了哪几次 I/O 在 auto_vacuum 下会被 pager 抑制)。因此 ② 开头统计的 44,000 是**静态断言调用数**,乘上故障枚举与置换系数后,运行时执行的用例数高出一到两个数量级。

**第 3 层:组合/置换测试(permutations,详见第④节)。** 同一批 `.test` 文件在 60+ 种"初始化脚本 + 预置 SQL + 编译选项"组合下重跑。其中有一组值得单独点名:以 `coverage-` 为前缀的套件(`coverage-wal`、`coverage-pager`、`coverage-analyze`、`coverage-sorter`,permutations.test:467-515),注释明确说明它们是为配合覆盖率分析而调整运行方式的套件——即"覆盖率需求反过来组织测试运行"的做法。另外 quick 全集还受两个环境变量微调:`QUICKTEST_INCLUDE` 往 quick 集合里追加文件,`QUICKTEST_OMIT` 用逗号分隔的正则剔除文件(permutations.test:149-171),这让 CI 可以按平台裁剪而不改仓库代码。

**第 4 层:多进程并发(mptest)。** 见下文专述。另外还有 valgrind 专项:permutations.test 定义了 `valgrind`(228)与 `valgrind-nolookaside`(242)两个套件,后者在 initialize 里 `sqlite3_config_lookaside 0 0`——因为在 lookaside 打开时 valgrind 无法追踪单块内存,必须关掉才能做有效检测;发布矩阵里 linux.Valgrind 配置(testrunner_data.tcl:30)对接 `make valgrindtest`(main.mk:1906-1907,`OMIT_MISUSE=1` 运行)。性能回归则由 `speedtest1.c`(参数化可复现的合成负载,`test/run-wordcount.sh`/`wordcount.c` 记录写入吞吐)承担,但 SQLite 对性能数字的态度同样是"boring":测试脚本里大量 `speed_trial` 辅助函数(tester.tcl:1168-1209)只记录不判死限,防止机器抖动造成假失败。

**第 5 层:模糊测试。** SQLite 有五套互不重复的模糊工具,覆盖三种攻击面:
1. `test/fuzz.test`:纯 TCL 的 SQL 语法树模糊器,`expr srand(0)` 固定种子、`::REPEATS 5000`(quick 模式降到 20,fuzz.test:26-31),生成"语义上大体合法"的随机 SQL;
2. `test/fuzzcheck.c`(2767 行):外部模糊器产出的**回归测试回放器**。输入是一个 SQLite 数据库,内含 `db(dbid,dbcontent)`(数据库镜像 BLOB)、`xsql(sqlid,sqltext)`(SQL 脚本)、`readme(msg)` 三张表(fuzzcheck.c:20-33);每条 SQL 逐一打到每个数据库镜像上,专找崩溃/断言失败/内存泄漏。仓库自带 8 个种子库 `test/fuzzdata1.db`~`fuzzdata8.db`(合计约 62MB),兼容 Google dbsqlfuzz 的"hex DB + 分隔行 + SQL"文本格式(fuzzcheck.c:75-92 `--load-dbsql`)。配套 `test/fuzzinvariants.c`(2022-06-14)做**查询不变量校验**:记录当前行输出,构造一个"应当返回同一行"的替代查询并执行比对(fuzzinvariants.c:12-20);
3. `test/ossfuzz.c`(206 行):OSS-Fuzz 官方入口 `LLVMFuzzerTestOneInput`(ossfuzz.c:119),用 progress handler 设置截止时间防卡死(ossfuzz.c:67-76);
4. `test/dbfuzz.c` / `test/dbfuzz2.c`:针对**损坏数据库文件**的模糊器,dbfuzz2 直接用 `clang -fsanitize=fuzzer` 驱动,种子库 `dbfuzz2-seed1.db`(dbfuzz2.c:17-40);
5. `test/sessionfuzz.c`:session 模块模糊器,头文件里给出了 AFL 的完整使用流程,甚至写明"...let the previous step run for a while. Weeks, maybe.",并用 `afl-cmin` 做语料最小化(sessionfuzz.c:23-33)。
另外 `tool/fuzzershell.c` 是给外部模糊器(如 AFL)用的"阉割版 shell":去掉了 dot-command,防止 fuzzer 自己发现 `.shell rm -rf ~`(fuzzershell.c:7-12)。`test/optfuzz.c` 则针对查询规划器。`make fuzztest` 目标把 fuzzcheck + sessionfuzz 串起来(`main.mk:1826`),testrunner 还会为部分构建额外跑 `fuzzcheck-asan`/`fuzzcheck-ubsan` 变体(`test/testrunner_data.tcl` `trd_fuzztest_data` 中 `sanBuilds {All-Debug Apple Have-Not Update-Delete-Limit}`)。

**第 6 层:多平台发布矩阵(releasetest)。** `test/testrunner.tcl`(2205 行)是并行测试调度器,而且它调度自身用的就是一张 SQLite 表:`jobs` 表带 `depid` 依赖、`priority`、`state` 检查约束(testrunner.tcl:400-431),用 SQLite 本身当消息队列——典型的吃自家狗粮。构建矩阵在 `test/testrunner_data.tcl:13-39`:linux 17 个配置(Debug-One、Have-Not、Secure-Delete、Unlock-Notify、Extra-Robustness、Sanitize、Valgrind…)、osx 2 个、win 5 个,每个配置映射到一个置换套件档位(veryquick/all/valgrind)。`make releasetest` = `testrunner.tcl release`(`main.mk:1885-1887`)。

**第 7 层(仓库外):TH3。** 仓库中 grep "TH3" 无任何命中——TH3 是 Hwaci 私有的第四套测试工具,公开资料(sqlite.org/testing.html)说明其特点:与本仓库 TCL 测试互补、追求 100% MC/DC(修正条件/判定覆盖)、在真实设备(含飞行软件、医疗嵌入式场景)上运行,是 SQLite 用于安全关键认证声明的依据。本文不展开,只强调分层逻辑:开源层负责"快速发现",私有层负责"穷尽覆盖"。

此外还有性能回归(`test/speedtest1.c`、`test/wordcount.c`、`test/speedtest.tcl`)和 `test/c/` 下的独立 C 小程序测试(testrunner.tcl:140 有专门的 `c` 类别,如 `test/c/snprintf1.c` 直接 `main()` 返回非零即失败)。

---

## ③ test1.c 绑定机制:如何把内部函数暴露给 TCL

`src/test1.c`(9535 行)的文件头自我定位非常清晰:"Code for testing all sorts of SQLite interfaces. **This code is not included in the SQLite library.** It is used for automated testing of the SQLite library."(test1.c:11-14)。它不进 amalgamation(`tool/mksqlite3c.tcl` 的文件清单里没有 test1.c),只编进 testfixture。

**注册机制是"表驱动 + 双入口"。** `Sqlitetest1_Init` 末尾(test1.c:9442-9448)循环注册两张静态表:
- `aCmd[]`(旧式 `Tcl_CreateCommand`,test1.c:9138 起);
- `aObjCmd[]`(新式 `Tcl_CreateObjCommand`,约 9200-9417 行,含 100+ 项)。
表项格式即 `{TCL命令名, C函数, clientData}`。之后是十几组 `Tcl_LinkVar`(test1.c:9449-9533),把 C 全局计数器**双向绑定**为 TCL 变量:`sqlite_search_count`(查询扫描行数)、`sqlite_sort_count`、`sqlite_interrupt_count`、`sqlite_open_file_count`、`sqlite_sync_count`、`bitmask_size`(只读)等。这让 TCL 脚本可以直接 `if {$sqlite_search_count>100} {...}` 断言执行计划的行为,而不需要任何输出解析。

还有一个工程细节:`test1.c:42-59` 解释了为什么用全局哈希表传指针而不是 `printf("%p")` 十六进制串——因为某些"safe compiler"(如 filcc)不允许对从字符串解码的指针解引用。每次把 `(sqlite3_stmt*)` 之类传给 TCL 时登记进哈希表、传回时取回原指针(`getDbPointer`)。这是为适配安全关键编译器付出的接口成本,直接佐证了前述 TH3/嵌入式场景。

**具体绑定例 1:一行包装器。** `sqlite3_libversion_number`(test1.c:1808-1816)是所有绑定里最短的一个:取参数个数为 0,直接 `Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_libversion_number()))`。它的存在意义是让 `test/` 里的脚本能在运行时校验被测库版本与期望一致。

**具体绑定例 2:官方测试后门的 TCL 化。** `sqlite3_test_control`(test1.c:8104-8170)把 `sqlite.h.in:8705-8719` 定义的那个"官方声明不稳定"的测试接口(见第⑤节)包装成 TCL 命令,`aVerb[]` 表列出可用动词(test1.c:8113-8119):`SQLITE_TESTCTRL_LOCALTIME_FAULT`(让 localtime() 注入失败)、`SQLITE_TESTCTRL_SORTER_MMAP`、`SQLITE_TESTCTRL_IMPOSTER`(制造假表以测损坏库)、`SQLITE_TESTCTRL_INTERNAL_FUNCTIONS`、`SQLITE_TESTCTRL_FK_NO_ACTION`,每个动词有独立的参数个数校验。这类绑定体现了"测试钩子三件套":状态注入、行为触发、环境破坏。

**具体绑定例 3:回调往返。** `add_test_collate`(test1.c:3407 起)向数据库注册一个**用 TCL 脚本实现的排序规则**:C 侧的 collation 回调把两个值编码后通过 `Tcl_EvalObjEx` 调回 TCL 脚本比较(test1.c:3390-3402 一带可见 `Tcl_EvalObjEx(i, pX, 0)` 再取回整数结果)。它专门用来测试 UTF-16 编码路径下的 collation 分派(test1.c:9348-9353 的注册点就在 `#ifndef SQLITE_OMIT_UTF16` 内)。这层"C↔TCL 回调往返"能测到纯 C 测试覆盖不到的编码转换边界。

**绑定注册还有一个值得注意的历史层次。** `aCmd[]` 表用旧式 `Tcl_CreateCommand`(char* 参数、字符串解释,test1.c:9442-9444),`aObjCmd[]` 用新式 `Tcl_CreateObjCommand`(Tcl_Obj 体系,test1.c:9445-9448)——两套并存说明绑定代码跨越了 TCL 8.0 到 9.0 的年代,但注册入口统一收敛在 `Sqlitetest1_Init` 一处,新代码一律走 aObjCmd。对外部项目的启示是:绑定表只需要"加一行"的成本,就会让一个内部函数获得全套 TCL 测试能力;SQLite 因此把几乎所有内部计数器(`sqlite3_pager_readdb_count`、`sqlite3_xferopt_count` 等,test1.c:9469-9476)都顺手暴露, optimizer 测试才能对"是否用了覆盖索引""是否做了 xfer 优化"做断言,而不依赖输出文本。

**其他典型绑定族**(test1.c:9327-9343):`file_control_*` 系列把 `sqlite3_file_control` 的每个 opcode 暴露成独立命令(`persist_wal`、`powersafe_overwrite`、`sizehint`、`reservebytes` 等),测试由此可以对 VFS 锁语义做细粒度断言。

**tclsqlite.c 的角色分工。** `src/tclsqlite.c`(4662 行)不是测试代码,而是**产品级的 TCL 扩展**——文件头写明 "A TCL Interface to SQLite. Append this file to sqlite3.c and compile the whole thing to build a TCL-enabled version of SQLite."(tclsqlite.c:12-14)。它注册 `sqlite3` 命令(tclsqlite.c:4499),命令体 `DbObjCmd`(tclsqlite.c:2485)用一个 42 项的子命令表 `DB_strs`(2494-2510)分发:`authorizer`、`backup`、`busy`、`eval`(核心,case DB_EVAL 在 3354)、`function`、`incrblob`、`serialize`/`deserialize`、`trace_v2`、`wal_hook` 等;`$db config` 又把 28 个 `SQLITE_DBCONFIG_*` 开关镜像成 TCL 选项(2927-2930)。分工边界因此清楚:`tclsqlite.c` 提供"正常用户视角"的 TCL 面(也是 testrunner 用 `package require sqlite3` 的来源,testrunner.tcl:29-40),`test1.c` 等 36 个文件提供"上帝视角"的测试钩子;`tester.tcl` 的 `autoinstall_test_functions`(tester.tcl:512 等)负责在测试环境把后者挂上。这个双层设计让"测试专用面"与"用户面"在代码里物理隔离。

---

## ④ permutations 与编译选项矩阵

`test/permutations.test`(1273 行)是同一套 `.test` 文件在多种配置下重跑的**注册中心**。核心机制:

**1. 声明式套件定义。** `test_suite NAME OPTIONS` 过程(permutations.test:32-55)只做一件事:把 `-description/-initialize/-shutdown/-presql/-files/-prefix/-dbconfig` 存进 `::testspec($name)` 数组并登记到 `::testsuitelist`。文件中共定义 **63 个**命名套件(grep `^test_suite` 计数)。执行时 `run_test_suite`(permutations.test:1196)调用 `run_tests`(1140 起):设置 `::G(perm:name/prefix/dbconfig/presql)`,对 `-files` 列表中的每个文件调用 `slave_test_file`——**每个 `.test` 文件都在新 slave interpreter 里 source 一遍**,`::G` 数组(含 permutation 上下文)整体复制进去(tester.tcl:2368-2375)。`-initialize`/`-shutdown` 脚本在每组文件前后执行,用来 `sqlite3_shutdown` + 重新 `sqlite3_config` + `autoinstall_test_functions`。被测代码完全不用感知自己在哪个 permutation 下,只需用 `permutation` 命令查询(如 tester.tcl:738 对 `maindbname` 套件的特判)。

**2. 四类配置旋钮。** 以实际定义为例:
- **运行时配置类**:`singlethread`(permutations.test:580-598)在 initialize 里 `sqlite3_config singlethread`;`memsubsys1`(517)调用 `test_set_config_pagecache 4096 24` 预分配页缓存;`nolookaside`(562)关掉 lookaside;`memsys3`/`memsys5`(821/857)切换内置分配器。
- **预置 SQL 类**:`persistent_journal`(706)只有一段 `-presql { pragma journal_mode = persist }` + 固定 8 个文件;`truncate_journal`(717)、`no_journal`(739)、`inmemory_journal`(776)、`utf16`(657,`pragma encoding = 'UTF-16'`)、`exclusive`(683,`pragma locking_mode=EXCLUSIVE`)同理。
- **连接参数类**:`nomutex`(600)通过 `set ::G(perm:sqlite3_args) [list -fullmutex 0 -nomutex 1]` 改变 `sqlite3_open` 的 flags;`onefile`(646)用 `-vfs fs` 换 VFS。
- **文件选择类**:`veryquick`(194)= quick 集合再排除 `*malloc* *ioerr* *fault* *bigfile* *_err*` 等;`extraquick`(209)再砍慢用例。文件集合由 `test_set -include/-exclude`(permutations.test:60-80)做集合运算,初始全集自动 `glob $testdir/*.test` 加上 `ext/{rtree,fts5,expert,lsm1,recover,rbu,intck,session}` 的测试(89-104)。

**3. 全量矩阵的组成。** `test/all.test:22-47` 直接顺序调用 25+ 个 `run_test_suite`:`full`、`no_optimization`、`memsubsys1/2`、`singlethread`、`multithread`、`onefile`、`utf16`、`exclusive`、`persistent_journal(_error)`、`no_journal(_error)`、`autovacuum_ioerr`、`no_mutex_try`、`fullmutex`、`journaltest`、`inmemory_journal`、`pcache0/10/50/90/100`、`prepare`、`mmap`。也就是说,"全量测试"不是"跑一遍所有文件",而是**跑约 25 遍所有文件**。这回答了"百万测试用例"的量级来源:44k 静态断言 × 置换系数。

**4. 与编译选项的衔接。** permutation 覆盖运行时旋钮,编译期旋钮(如 `SQLITE_OMIT_*`、`SQLITE_THREADSAFE`)则由 testrunner 的**构建矩阵**覆盖:`test/testrunner_data.tcl:13-39` 为每个平台定义构建配置(linux 17 个、osx 2 个、win 5 个),每个配置是一组 `./configure` 选项 + `-D` 宏(如 `build(Default)` 含 `--disable-amalgamation --enable-session -DSQLITE_ENABLE_RBU`,74 行起;`build(All-Debug)` 为 `--with-debug --enable-all`),每个配置再映射到要跑的置换套件。`.test` 文件内部用 `ifcapable`(如 wal.test:26)与编译特性协商,跳过不适用用例。两级矩阵(编译期 build × 运行期 permutation)是 SQLite 测试体系的骨架。

**5. 防作弊细节。** `run_tests` 支持 `TCLTEST_PART` 环境变量把文件列表切片并行(permutations.test:1161-1165)、`SQLITE_TEST_PATTERN_LIST` 过滤(1168-1177);`TEST_FAILURE` 环境变量会强制注入一次失败来**测试测试框架本身**(permutations.test:173-179,配套 main.test)。

---

## ⑤ 可插拔设计与 API 稳定性

**sqlite3_config:全局参数的可插拔枢纽。** `src/main.c:443` 起的 `sqlite3_config(op, ...)` 用 va_args 分发约 30 个 `SQLITE_CONFIG_*` 选项(main.c:470-762),关键的可插拔点:
- `SQLITE_CONFIG_MALLOC`(main.c:511-518):整体替换内存分配器 `sqlite3_mem_methods`(xMalloc/xRealloc/xFree/xSize/xRoundup/xInit/xShutdown);
- `SQLITE_CONFIG_PAGECACHE`/`PCACHE2`(541/573):预分配页缓存块 / 换掉整个 page cache 实现;
- `SQLITE_CONFIG_HEAP`(597)/`LOOKASIDE`(638):堆与 lookaside 参数;
- `SQLITE_CONFIG_MUTEX`/`GETMUTEX`(497/504):替换互斥实现;
- `SQLITE_CONFIG_LOG`(648)、`SQLITE_CONFIG_MMAP_SIZE`(694)等。
纪律性也很强:库已初始化后调用默认返回 `SQLITE_MISUSE`,仅 `SQLITE_CONFIG_LOG` 与 `PCACHE_HDRSZ` 两个位掩码白名单选项允许任意时刻调用(main.c:447-457 的 `mAnytimeConfigOption`)。每一处都带 `EVIDENCE-OF: R-xxxxx` 标注(如 main.c:514 `EVIDENCE-OF: R-55594-21030`),全 src/ 共 105 处——编号对应 sqlite.org 文档数据库中"可测试语句"的唯一 ID,`test/e_*.test`(25 个文件)在 TCL 侧反向校验这些语句,文档-代码-测试三点闭环。类似的还有 29 处 `IMPLEMENTATION-OF: R-xxxxx`(如 main.c:100-106 对 sqlite3_sourceid() 的行为声明)。

**API 稳定性承诺落在三个具体机制上:**
1. **单一权威头文件。** `src/sqlite.h.in:12-16`:"If a C-function, structure, datatype, or constant definition does not appear in this file, then it is **not a published API** of SQLite, is subject to change without notice"。文件内 216 处 `CAPI3REF` 注释块,官方文档直接从这些注释生成(sqlite.h.in:24-26 自述)。`.h.in` 后缀说明它是模板:构建时由 `tool/mksqlite3h.tcl` 注入版本号(main.mk:1133-1137)。
2. **实验/弃用标记退化为空宏。** `SQLITE_DEPRECATED`/`SQLITE_EXPERIMENTAL` 现在是 no-op(sqlite.h.in:100-107),注释解释了原因:原先的编译器魔法"generated such a flurry of bug reports that we have taken it all out"——连弃用告警都被用户报告逼退了,只能靠文档纪律。
3. **版本断言惯例。** sqlite.h.in:160-172 官方建议应用层写 `assert( sqlite3_libversion_number()==SQLITE_VERSION_NUMBER ); assert( strncmp(sqlite3_sourceid(),SQLITE_SOURCE_ID,80)==0 );` 防止头文件与动态库错配。版本号规则(X*1000000+Y*1000+Z,单调递增)在 sqlite.h.in:129-132 写死。3.54.0 的 sqlite.h.in 还新增了 `SQLITE_SCM_BRANCH/SQLITE_SCM_TAGS/SQLITE_SCM_DATETIME` 三个宏(149-154),把 SCM 元数据烧进发布头文件。

**测试接口的"反稳定性"承诺。** 与之对照,`sqlite3_test_control`(sqlite.h.in:8705-8719)被官方明文声明"not for use by applications...subject to change without notice";38 个 `SQLITE_TESTCTRL_*` 编号(sqlite.h.in:8732-8769,FIRST=5,LAST=34)从不承诺跨版本一致。公共 API 二十年不变、测试后门随时可变,这两条并存正是 SQLite 兼容性策略的完整表达。

**VFS 与加载扩展。** VFS 层的可插拔由 `sqlite3_vfs_register` 支撑(`src/os_unix.c:8532-8535` 在 os_init 时注册 unix 系 VFS;`test/test_vfs.c`、`test/test_demovfs.c` 提供测试 VFS);置换套件 `onefile`(permutations.test:646)演示了用 `-vfs fs` 整体换 VFS 跑测试。这与第③节 `file_control_*` 绑定族共同构成"存储栈每层都可被测试替换"的完整链条。

---

## ⑥ 发布流程与版本纪律

**SCM 层:Fossil 三件套。** 仓库根目录有 `manifest`(每个文件一行哈希,外加 `C` 提交注释、`D` UTC 时间戳、`branch/tag` 行)、`manifest.uuid`(本次检出哈希 `5251f4d7071f...`)、`manifest.tags`。Fossil 自 3.6.18 起使用(sqlite.h.in:134-136 自述),manifest 是 Fossil 的检出快照格式。`AGENTS.md` 明确"canonical repository is sqlite.org/src"——Git 镜像只是镜像。

**版本注入链。** `VERSION` 文件(纯文本 `3.54.0`)→ `make sqlite3.h` 规则(main.mk:1133-1137)声明 sqlite3.h 依赖 `src/sqlite.h.in` + `manifest` + `mksourceid` + `VERSION`,由 `tool/mksqlite3h.tcl` 生成,把 `--VERS--`、`--SOURCE-ID--` 占位符替换为真值。`SQLITE_SOURCE_ID` 的哈希部分由 `tool/mksourceid.c` 对整树计算(SHA3),**若源码被改动,哈希末 4 位十六进制会被修改**(sqlite.h.in:140-143 的官方规则;sqlite3_sourceid() 的实现只是 `return SQLITE_SOURCE_ID;`,main.c:106)。这意味着"你手里的 sqlite3.c 是否被动过"可以在运行时查出来——供应链完整性的朴素但有效的实现。

**发布前校验。** `tool/srctree-check.tcl:1-10`:"confirm that various aspects of the source tree are up-to-date",目前检查 Makefile.msc 与 autoconf/Makefile.msc 一致、VERSION 与 autoconf/tea/configure.ac 一致;它挂在 `devtest`/`releasetest` 前面(main.mk:1854、1885-1886 `releasetest: srctree-check has_tclsh85 verify-source`),防止"改了 parse.y 忘了重新生成"这类事故进入发布。`make releasetest` 走 testrunner 的 `release` 档位,即第④节的多平台构建矩阵。

**打包产物。** amalgamation 由 `tool/mksqlite3c.tcl`(517 行)生成:先 `make target_source` 把所有源码汇入 `tsrc/`,脚本按依赖顺序读入每个文件,遇到白名单头文件(btree.h、pager.h、vdbeInt.h 等 30+ 个,200-220 行的 `available_hdr` 列表)就**递归内联一次**、再次遇到则注释掉;给所有 `sqlite3*_` 函数自动加 `SQLITE_API`/`SQLITE_PRIVATE` 链接标记(253-303),支持 `--linemacros` 生成 `#line` 便于调试,并检测 parse.c 是否支持 `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`(155-163);`sqlite3_sourceid` 的定义被注释掉、留到文件末尾合成(296-301)。产物是单个 `sqlite3.c`——这正是 fuzzcheck/ossfuzz/dbfuzz 各工具编译命令里那个 "sqlite3.c" 的来源。自动发布还包括 autoconf 包(`tool/mkautoconfamal.sh`)、zip(`tool/mkamalzip.tcl`、`mksrczip.tcl`)、VSIX(`tool/mkvsix.tcl`)。

**版本纪律的表现。** 版本号只有 `VERSION` 一个事实来源;`SQLITE_VERSION_NUMBER` 语义(每发布号单调递增)写在头文件注释里;连 CLI 资源文件的 `SQLITE_RESOURCE_VERSION` 都从 `VERSION` 生成(main.mk:1472-1473 sqlite3rc.h 规则)。没有任何一处硬编码版本字符串需要人工同步——需要人工的只有"改 VERSION 并 tag"这一个动作。

---

## ⑦ 对其他项目的可借鉴清单

1. **把"提交前测试"写成构建目标 + 注释**,而不是口头规范:`main.mk:1848-1853` 的 devtest 注释是最佳范本;更进一步,给测试目标挂上源树一致性校验(`srctree-check`),让"忘记再生成"在开发循环早期失败。
2. **测试代码与产品代码物理隔离但同仓**:36 个 `test_*.c` 只编进 testfixture,绝不进发布物(mksqlite3c.tcl 清单不含它们),但与产品代码同目录同版本演进。对比"测试另建仓库"或"测试混进发布库"两种常见错误,SQLite 的第三条路值得抄。
3. **故障注入做成一等公民**:`sqlite3_memdebug_fail` 式的"N 次分配中第 K 次失败"枚举 + `do_faultsim_test` 声明式框架,比随机的 chaos engineering 可复现得多;OOM/IO 错误路径因此获得与正常路径同等覆盖。
4. **permutation 思想**:与其写 60 份"不同配置下的专属测试",不如写一套测试 + 一张"(initialize 脚本, presql, 文件集合)声明表"重跑 60 遍。框架成本(1273 行)远低于内容重复的成本。
5. **测试调度器吃自家狗粮**:testrunner 用一张 SQLite 表调度并行任务(依赖、优先级、状态机),复用了被测系统的全部健壮性,还顺便测了它。
6. **文档即测试的锚点**:文档中每条"可测试语句"编号化(EVIDENCE-OF R-xxxxx),代码侧标注、测试侧校验(`e_*.test`)。文档腐化会立刻变成测试失败。
7. **模糊测试配"回放器+种子库"**:外部 fuzzer(ossfuzz/AFL)产出进语料库(fuzzdata*.db,fuzzcheck 可 `--load-sql/--load-db` 增补),CI 每日回放——fuzzer 找新病,回放器防旧病复发。再加上 fuzzinvariants 式"替代查询等价性"断言,把 fuzzer 从"只找崩溃"升级为"找语义错误"。
8. **防御式宏配覆盖率豁免**:ALWAYS/NEVER/sqlcase/testcase 四件套(sqliteInt.h:503-571)在 NDEBUG 构建零开销,在 coverage 构建被硬编码为真/假以免"不可达分支"污染覆盖率统计(543-545)。想让团队"敢写防御代码",必须同时给覆盖率工具打补丁。
9. **生成文件Never-Edit 纪律 + 机器校验**:AGENTS.md 表格列出每个生成文件与再生成命令,`srctree-check` 机器验证。文档+工具双保险。
10. **版本号单源化**:一处 `VERSION`,其余全部生成,连 SCM 哈希都烧进头文件。

---

## ⑧ FAQ

**Q1:为什么 2026 年还在用 TCL 做测试?**
A:历史惯性 + 工程理性并存。SQLite 的作者社区与 TCL 渊源极深,1990 年代第一版测试就是 TCL(test/select1.test:1-15 的 CVS 标签可追溯到 2001 年 9 月 15 日);更重要的是 testfixture 模式——把被测库直接链进解释器,可以注册"上帝视角"命令(第③节),这是纯外部黑盒框架做不到的。`tclsqlite.c` 同时是产品级 TCL 扩展,维护成本被两用摊薄。

**Q2:测试为什么放在 `src/test1.c` 而不是 `test/` 目录?**
A:`test/` 放 TCL 脚本与少量独立 C 程序,而所有需要链接进 testfixture 的 C 钩子按 SQLite 惯例都叫 `src/test_*.c`(36 个文件,`main.mk:722-816`)。它们在 amalgamation 生成清单之外(mksqlite3c.tcl 的输入列表不含),所以不污染发布物。

**Q3:SQLITE_OMIT_* 到底有多少、真的有人用吗?**
A:`src/*.c`+`src/*.h` 中共 124 处条件编译引用、69 个不同的 `SQLITE_OMIT_*` 宏(去重统计);引用最多的是 `SQLITE_OMIT_VIRTUALTABLE`(166 处)、`SQLITE_OMIT_UTF16`(94)、`SQLITE_OMIT_WINDOWFUNC`(93)、`SQLITE_OMIT_WAL`(89)。不是摆设:Have-Not、Update-Delete-Limit 等发布矩阵构建配置(testrunner_data.tcl:13-39)专门验证裁剪产物。

**Q4:四万多个用例跑完要多久?开发者每天怎么跑?**
A:分层。`veryquick` 自述"minutes on a workstation"(permutations.test:194-201),`quick` 约 10 分钟(265);`make devtest`(testrunner `mdevtest`)是提交前最低要求(main.mk:1848-1853);全量 `releasetest` 走 24 个构建 × 28 个置换(testrunner_data.tcl:74-80 `all_configs`)的矩阵,由 testrunner 用 `--jobs`/`NJOB` 并行(testrunner.tcl:127、230)。

**Q5:TH3 在仓库里吗?**
A:不在。grep "TH3" 零命中。TH3 是私有测试工具,公开层(sqlite.org/testing.html)描述其定位于 100% MC/DC 覆盖与真实设备测试,支撑安全关键场景的认证声明。开源仓库 + 私有 TH3 的组合是刻意设计:开源层保证可复现性,私有层保证穷尽性。

**Q6:`sqlite3HaltMalloc` 存在吗?**
A:不存在(全仓库 grep 为 0)。OOM 注入的实际入口是 `sqlite3_memdebug_fail COUNTER ?OPTIONS?`(test_malloc.c:544,TCL 名注册于 1437),配合 `-repeat` 与 benign malloc 计数(malloc_common.tcl:193、501)。

**Q7:permutation 和 build 配置会不会重复劳动?**
A:分工明确:permutation(test/permutations.test)只改**运行时**状态(sqlite3_config、PRAGMA、open flags、文件子集),同一二进制可跑全部 63 个套件;build 配置(testrunner_data.tcl)改**编译期**宏与 configure 选项,需要重新构建。两者正交,组合才是完整矩阵。

**Q8:测试基础设施自己怎么被测试?**
A:三处可见证据:`TEST_FAILURE` 环境变量触发框架自测(permutations.test:173-179);`slave_test_file` 对每个文件做句柄泄漏与全局状态篡改检查(tester.tcl:2415-2428);`grep '!' testrunner.log` 是 AGENTS.md "Testing" 节给出的官方查失败方式。

**Q9:为什么官方文档说 amalgamation 比多文件编译更推荐?测试不就跑不了了吗?**
A:恰恰相反:发布矩阵里 Default 构建显式带 `--disable-amalgamation`(testrunner_data.tcl build(Default)),专门测多文件路径;amalgamation 是给下游用户的产品形态。两者都被覆盖,不存在"只测发布形态"的问题。

**Q10:seen 测试文件里有奇怪的 `temptrigfault.tes`(缺字母)是怎么回事?**
A:这是真实存在的文件名(`test/temptrigfault.tes`),一个历史笔误,从 CVS 时代一直保留至今——组织对"改名破坏外部引用"极其保守的又一例证(改名会让书签/脚本失效,收益却只是文件名好看)。

---

## ⑨ 深挖问题(供后续调研)

1. **permutation 的隔离边界在哪?** `slave_test_file` 用 slave interpreter 隔离脚本状态(tester.tcl:2360-2390),但 `sqlite3_config` 是进程级全局的,`-initialize` 里的 shutdown/config/initialize 序列如何保证不泄漏到下一个文件?值得精读 `run_tests`(permutations.test:1140-1193)与 `finalize_testing`(tester.tcl:1256)的清理顺序,特别是 `valgrind-nolookaside` 这类永久改 lookaside 的套件(permutations.test:242-252)的 shutdown 恢复是否完整。
2. **fuzzinvariants 的替代查询如何保证不误报?** `test/fuzzinvariants.c` 声称构造"应返回同一行"的等价查询(12-20 行),但索引、列顺序、NULL 处理都可能造成合法的输出差异。它对哪些语句类型(只读 SELECT?含聚合?)启用了不变量检查、失败时如何降级,需要读全文验证。
3. **mptest 的任务表协议如何处理客户端崩溃?** 客户端从共享库的 `task` 表拉任务(mptest.c:537-596),`--exit` + `finishScript` 可模拟崩溃(mptest.c:959-963),但崩溃后任务行残留谁清理?`--wait all` 的超时路径(mptest.c:796-829)与 `DEFAULT_TIMEOUT 10000`(mptest.c:92)的交互值得跑一遍 crash01.test 观察。
4. **EVIDENCE-OF 编号体系如何维护?** 105 处 `EVIDENCE-OF: R-xxxxx`(src/)对应的"可测试语句"清单在 sqlite.org 的文档数据库中;问题是如何在修改文档语句时同步改代码标注——是否存在工具校验 R 编号存在性,还是纯人工?可对照 `tool/` 下是否有相关脚本。
5. **ALWAYS/NEVER 与 SQLITE_OMIT_AUXILIARY_SAFETY_CHECKS 的成本核算。** 该宏在覆盖率/变异测试下把 ALWAYS/NEVER 硬编码(sqliteInt.h:543-545,562-571),188 处 ALWAYS、142 处 NEVER(btree/pager/wal 为主)。值得统计这些防御分支在 release 构建的体积/分支预测代价,以及 SQLite 是否量化过"self-healing"路径实际救回的故障(与 TH3 的损坏库测试数据对照)。

---

### 附:本文引用的文件与关键行号索引

| 主题 | 文件:行号 |
|---|---|
| Blessing 头/公共领域 | AGENTS.md(Project nature);src/test1.c:1-9 |
| 提交前 devtest 纪律 | main.mk:1848-1857;srctree-check main.mk:1854 |
| 生成文件清单 | AGENTS.md(Do not edit generated files);main.mk:1207,1133-1137 |
| 测试框架核心 | test/tester.tcl:703(do_test),941,973,1048,1237,1674,2392 |
| OOM/IO 注入 | src/test_malloc.c:544,1437;test/malloc.test:10-16;test/malloc_common.tcl:32-46,121,193;test/ioerr.test:33 |
| TCL 绑定表 | src/test1.c:9138(aCmd),9200-9417(aObjCmd),9442-9448(注册),9449-9533(Tcl_LinkVar),1808,3407,8104 |
| TCL 产品接口 | src/tclsqlite.c:12-14,36-50,2485,2494-2510,3354,4499 |
| permutation 机制 | test/permutations.test:32-55,89-104,194,220,228,265,517,580,600,706,776,1196,1140-1193 |
| 置换套件总表 | test/testrunner_data.tcl:74-80(all_configs),13-39(build 矩阵) |
| testrunner 调度 | test/testrunner.tcl:127,230,363-433(jobs 表) |
| fuzzcheck | test/fuzzcheck.c:20-33(schema),75-92(dbsqlfuzz);test/fuzzinvariants.c:12-20 |
| ossfuzz | test/ossfuzz.c:67-76,119 |
| dbfuzz/sessionfuzz | test/dbfuzz2.c:17-40;test/sessionfuzz.c:23-33 |
| mptest | mptest/mptest.c:92,537-596,796-829,959-963,1129-1153;mptest/config01.test;crash01.test |
| sqlite3_config | src/main.c:443,447-457,470-762(511 MALLOC,541 PAGECACHE,573 PCACHE2,597 HEAP,638 LOOKASIDE) |
| API 稳定性 | src/sqlite.h.in:12-16,100-107,129-132,149-154,160-172,8705-8719 |
| 防御式宏 | src/sqliteInt.h:466-481(NDEBUG),503-512(testcase),519-537(TESTONLY/VVA),543-571(ALWAYS/NEVER),595-601 |
| EVIDENCE-OF | src/main.c:100-106,514-521;全 src/ 105 处 |
| amalgamation | tool/mksqlite3c.tcl:1-35,155-163,200-220,253-303 |
| 版本/发布 | VERSION;manifest;manifest.uuid;tool/mksourceid.c;tool/srctree-check.tcl:1-10;main.mk:1472-1473 |
