# G 章 · Git 工程文化：一个 20 年 C 项目的自维持体系

> 调研对象：Git 源码仓库，commit 47ce805（2026-09-11，v2.56.0-rc1 准备中，
> GIT-VERSION-GEN 默认版本 v2.56.0-rc0）。行号均以该 commit 实际核对。

---

## 1. 全景：四柱体系

Git 没有公司、没有 ISSUE 驱动，却维持了 20 年高质量迭代。它依赖的是写进仓库
本身的"自维持体系"——规范、测试、构建、流程四根柱子，每根都是可执行或可核对的
文本，而非口头约定：

```
                 ┌──────────────────────────────┐
                 │        Git 自维持体系         │
                 └──────────────────────────────┘
   ┌──────────────────┬──────────────────┬──────────────────┐
 ┌─▼────────┐    ┌────▼─────┐    ┌───────▼──┐    ┌─────────▼┐
 │ ① 规范   │    │ ② 测试   │    │ ③ 构建   │    │ ④ 流程   │
 └──────────┘    └──────────┘    └──────────┘    └──────────┘
 CodingGuidelines t/test-lib.sh  Makefile(4134行) SubmittingPatches
 C/shell/错误信息 test-lib-       特性开关 NO_*    commit msg 规范
 S_verb() 命名法  functions.sh    GIT-VERSION-GEN  邮件补丁文化
                  1058 个 tNNNN.sh sparse/coccicheck maint/next/seen
                  trash 目录隔离   DEVELOPER=1 警告 maintain-git 模型
                  test_expect_    差异化最小构建   RelNotes (542份)
                  failure=bug存档 (NO_CURL/NO_PERL) 8-10 周一个周期
      └──────── 可移植性纪律统一四柱：老平台支持决定一切 ────────┘
```

四柱的配合方式：贡献者按④发补丁 → 评审者按①挑毛病 → 合并前必须过②的
1058 个测试脚本 → ③保证这些测试能在任意老平台跑起来。

---

## 2. 测试框架专节：shell 宏如何变成断言与计数

### 2.1 一切测试都是"退出码 + 计数器"

Git 没有用任何第三方断言库。核心机制：`test_expect_success`（t/test-lib-functions.sh:924）
接收标题和 shell 代码体，执行后按退出码调用计数器函数——`test_ok_`
（t/test-lib.sh:804）与 `test_failure_`（t/test-lib.sh:814）：

```sh
test_ok_ () {
	test_success=$(($test_success + 1))
	say_color "" "ok $test_count - $@"
	finalize_test_case_output ok "$@"
}
```

输出直接采用 TAP 格式（t/README:30-34），`prove -j 15` 等任意 TAP harness 都能
并行接管。测试体还支持 heredoc 传参（`test_body_or_stdin`，
t/test-lib-functions.sh:883-897），避免引号嵌套地狱。

### 2.2 框架会先"链检"你的测试本身

`test_run_`（t/test-lib.sh:1084）最独特之处：执行测试体之前先用魔法退出码 117
做 `&&` 链完整性检查，若链路写法有短路掩盖直接 `BUG "broken &&-chain"`
（:1089-1094）；配套 t/chainlint.pl 与 t/check-non-portable-shell.pl（非可移植
shell 用法静态检查）。**测试代码本身也被当作受检代码**。

### 2.3 trash 目录：每次运行从零开始

t/test-lib.sh:44 点明设计："tests are kept in t/ subdirectory and are run in
'trash directory' subdirectory"。每个脚本获得独立目录
`trash directory.$TEST_NAME`（:370），运行前先 `rm -rf` 旧目录（:1601-1616），
通过后自动删除（:1296-1305）。配合 `test_tick` 把时间冻结在固定起点、每次
+60 秒（t/test-lib-functions.sh:136-149，初始值 1112911993），commit hash 完全
可复现——**测试结果与时间、环境、残留状态彻底解耦**。

### 2.4 test_expect_failure：已知 bug 的"存档"语义

t/test-lib-functions.sh:901 定义的 `test_expect_failure` 不是"期望失败"，而是把
当前错误行为登记在案。t/README:897-900 官方措辞："This is NOT the opposite of
test_expect_success, but is used to mark a test that demonstrates a known
breakage"。其输出语义是 `ok ... # TODO known breakage vanished`
（t/test-lib.sh:841-845）：一旦"已知破坏"通过，框架大声警告
`known breakage(s) vanished; please update test(s)`（:1251-1253），提醒开发者
把用例转正为 `test_expect_success`。最终统计写入 `.counts` 文件：total/success/
fixed/broken/failed/missing_prereq 六项（:1241-1248）——**带自动化核对的行为
变更台账**。

### 2.5 断言原语与测试命名规格

- `test_cmp`（t/test-lib-functions.sh:1274-1277）：`eval "$GIT_TEST_CMP" '"$@"'`，
  expect/actual 文件对比是整个体系的原子操作；变体 test_cmp_sorted（:1281）、
  test_cmp_config（:1293）。
- `test_grep`（:1323）取代了旧的 `test_i18ngrep`——后者现在直接
  `BUG "do not use test_i18ngrep---use test_grep instead"`（:1319-1320），
  用运行时炸弹强制迁移 API。
- 测试文件名即索引：t/README:482-501 规定 `tNNNN-commandname-details.sh`，
  首位数字分家族（0 基础、4 diff、7 上层 worktree 命令、9 工具），次位是命令
  编号。t3200-branch.sh 单文件 2181 行、195 个 `test_expect_success`
  （全文 grep 统计），是"一个命令一个文件"的典范。
- 最早的 t1000-read-tree-m-3way.sh 展示"测试即规格"：test_description
  （:6-29）用四条规则完整定义 3-way merge 决策原则，摘录（≤15 行）：

```
This test tries three-way merge with read-tree -m
There is one ancestor (called O for Original) and two branches A
and B derived from it. ...
 - If only A does something to it and B does not touch it, take
   whatever A does.
```

- 单元测试层也已建立：t/unit-tests/ 下 28 个 `u-*.c`（Clar 框架），
  与端到端 shell 测试并行成两级体系（t/Makefile:91-97 的 unit-tests 目标）。

## 3. 规范专节：CodingGuidelines 的亮点条目

Documentation/CodingGuidelines（1025 行）开篇是一段罕见的"哲学宣言"（对照
FFmpeg 系列 configure/FATE 章：FFmpeg 的规范是"规则表"，Git 的规范是
"决策原则 + 规则表"），按优先级排列（:4-19）：
1. "我们从不说'It 在 POSIX 里，你的系统不遵守是你的事'。我们活在现实中。"
2. "但我们常说'离那个构造远点，它连 POSIX 都不是'。"
3. "尽管有以上两条，我们有时会说'虽然不在这版 POSIX 里，但它足够方便/可读，
   我们关心的平台都支持，所以用'。"
这组三段论把**可移植性从教条降级为可权衡的工程决策**，同时保留底线。其他亮点：

- **反洁癖条款**（:21-27）：修真 bug 时顺手清理风格可以，专门发风格补丁
  不行——"Once it _is_ in the tree, it's not really worth the patch noise"（:24-25）。
- **日志消息与代码同等重要**（:29-31）：注释解释"代码如何工作"，
  commit log 解释"为什么必须改"。正式写进规范而非口口相传。
- **NEEDSWORK 标签**（:36-42）：代码内"待定设计决策"标记；"解决一个
  NEEDSWORK 的 80% 工作是判断它是否还成立"——甚至允许只删除该注释作为合法补丁。
- **C 标准采用"测试气球"制**（:279-330）：要求 C99（v2.35.0 起，:280-281），
  但每个 C99 特性逐个"试点"，带引入 commit 记录时间线：非常量初始化器
  （2007）、尾逗号 enum（2012）、指定初始化器（2017）、for 内声明（2021）、
  stdbool（2023）。新特性先放"test balloon"：复合字面量 2024 年底入气球，
  "期望 2026 年中正式采纳"（:314-320）。禁用项有真实平台背书：`%z` 因
  MinGW C 库不支持（:324-327）；`.a.b = *c` 简写绊倒 IBM XLC（:328-330）。
- **变量声明**（:334-338）：必须块首声明（`-Wdeclaration-after-statement`）；
  **零初始化交给 BSS**（:339-341）；NULL 不写 0（:342）；星号靠变量名
  `char *string`（:344-346）。
- **结构体命名法**（:614-650）：子系统 `S` 的主数据结构叫 `struct S`，
  操作函数叫 `S_<verb>()` 且首参为结构体指针；并标准化了
  `S_init/S_release/S_clear/S_free` 四个生命周期动词的精确语义
  （`S_clear` = release + init；若提供 clear，则 init 不得再分配需释放的资源，
  :637-643）——这是用文字实现的 RAII 约定。
- **错误消息细则**（:770-793）：单句结尾不加句号；首词不因句首而大写；
  先说错误是什么（"cannot open '%s'" 而非 "%s: cannot open"）；
  错误主体用单引号包住；porcelain 命令的报错要 `_(...)` 走翻译，
  plumbing 命令面向机器不翻译；`BUG()` 是给开发者的、永不翻译（:792-793）。
- **shell 脚本规范**（:61-247）：tab 缩进、重定向 `>"$file"`（:77-79）、
  禁 bashism（无数组 :112、无 `${var/pat/rep}` :114、无进程替换 :118）、
  `test` 优先于 `[`（:153）、`local` 虽非 POSIX 但重度使用（:196-198）——
  "现实世界"哲学的落地。

## 4. coccinelle 专节：语义补丁做机械重构

tools/coccinelle/（本 commit 中 26 个文件，含 22 个 `.cocci` 语义补丁）是 Git
最独特的实践之一：用 Coccinelle（Linux 内核同款"语义补丁语言"）把**机械重构
写成可执行、可复检、可入 CI 的规则**。README:3-4 开宗明义，并区分两类用途：

1. **坏模式检查**（README:7-11）：`make coccicheck` 检出即视为回归，
   "any resulting patch indicates a regression"。经典案例（README:13-21）：
   commit 67947c34ae 把 `hashcmp() != 0` 机械转为 `!hasheq()`；
   f919ffebed 用 MOVE_ARRAY 替换手工 memmove。
2. **大规模重构**（README:32-45）：改函数签名这类全局重构会产生大量文本/语义
   冲突，所以 `*.pending.cocci` 后缀的规则被 coccicheck 忽略、单独用
   `make coccicheck-pending` 应用——**把"计划中的重构"作为仓库资产持久保存**，
   而不是邮件里的一次性脚本。

一个完整的语义补丁小到 10 行。tools/coccinelle/xcalloc.cocci:1-10
（把 xcalloc 的参数顺序从 `(sizeof, n)` 统一为 `(n, sizeof)`）：

```cocci
@@
type T;
T *ptr;
expression n;
@@
  xcalloc(
+ n,
  \( sizeof(T) \| sizeof(*ptr) \)
- , n
  )
```

preincr.cocci:4-5 更短：`- ++i > 1` / `+ i++`。strbuf.cocci 用格式串正则判断：
当 `strbuf_addf` 的格式串不含 `%` 时自动改写为 `strbuf_addstr`
（tools/coccinelle/strbuf.cocci:1-12）。

工程细节同样讲究（tools/coccinelle/README:48-70 与 Makefile:1005-1040）：
coccicheck 借用头文件依赖缓存只重跑受影响的 `.c`；所有 `.cocci` 默认拼接成
ALL.cocci 一次解析全库；spatchcache 是"coccinelle 的 ccache"，
默认用 Redis 做缓存后端（README:68-70）。

---

## 5. 构建专节：特性开关矩阵与 minimal 理念

顶层 Makefile 约 4134 行，文件头集中了约 59 个 `NO_*` / `USE_*` 开关注释，构成
"依赖可选化矩阵"（对照 05 章 FFmpeg configure：同样的"能力探测 + 显式开关"，
Git 用手写 Makefile 而非 configure 脚本完成）：

| 开关 | 行号 | 效果 |
|---|---|---|
| NO_CURL | Makefile:465-467 | 不编 http 传输，http://https:// 全不可用 |
| USE_LIBPCRE | Makefile:484-490 | 仅支持 PCRE2，PCRE1 支持已删除 |
| NO_PERL | Makefile:227 | 去掉全部 Perl 脚本 |
| NO_TCLTK | Makefile:245 | 去掉 git-gui |
| NO_GETTEXT | Makefile:429 | 关闭 i18n |
| NO_OPENSSL / NO_MMAP / NO_IPV6 / NO_NSEC | :43 / :134 / :178 / :210 | 老平台兼容 |

两条设计决策：

- **删除也是构建变更**：USE_LIBPCRE1 移除后在 Makefile:1768-1769 留下
  `$(error The USE_LIBPCRE1 build option has been removed, ...)`——过时开关
  直接报错而非静默忽略。
- **差异化最小构建是测试目标**：NO_CURL 下 git-http-fetch/push 不构建，其余
  功能完整可用（Makefile:465-467），CI 有专门的 minimal 构建校验
  （Makefile:2610 注释提及 ci/run-build-and-minimal-fuzzers.sh）。

版本号不靠脚本猜：GIT-VERSION-GEN:3 定义默认 `DEF_VER=v2.56.0-rc0`，:42-57
依次尝试发布包内 `version` 文件 → `git describe --dirty --match="v*"` → 默认值；
并用 `GIT_CEILING_DIRECTORIES` 防止在无关仓库里误读版本（:33-36）。
`DEVELOPER=1`（Makefile:588-598，CodingGuidelines:266-269）把项目在意的全部
编译警告打包，配 `config.mak` 一行启用。

辅助检查工具链：`make check-builtins`（Makefile:3978-3979）调用
tools/check-builtins.sh，把 Makefile 声明的 BUILT_INS 与 git.c 命令表交叉比对；
`sparse` 目标（Makefile:997-998）以 `-std=gnu99 -D__STDC_NO_VLA__` 做静态
检查——连 VLA 都在构建层禁掉，与可移植性纪律呼应。

---

## 6. 流程专节：邮件补丁文化与 commit message 规范

### 6.1 邮件补丁：评审是"获取帮助"而非"通过审批"

Documentation/SubmittingPatches（1024 行）定义了补丁生命周期（:13-20）：
"You do not need any pre-authorization"——不需要预先许可，直接写代码发列表。
:33-35 给出文化内核：评审的目标是"获取帮助做出比自己单独更好的方案"，而非
"说服别人你做的是好的"。评审意见要用"Reply-All"公开逐条回应（:60-63）；设计层
质疑未解决前不许进入实现冲刺（:69-72）。MyFirstContribution.adoc 是新人教程，
明确推荐 `git send-email` 工作流（MyFirstContribution.adoc:843-855，
:1019-1029 起为配置章节）。

### 6.2 commit message："area: summary" 的三个理由

Documentation/SubmittingPatches:334-343 规定首行 50 字符软限制、省略句号、
加 `area: ` 前缀（如 `doc: clarify distinction between sign-off and pgp-signing`
:339-341）。规范还细致到：area 前缀后的首词不大写，除非该词本来就该大写
（:346-353，"`refs: HEAD is also treated as a ref`" 合法）。为什么执着于
"area: summary"？

1. **邮件语境**：每条 commit 在邮件列表就是一个补丁邮件，标题即邮件主题，
   area 前缀让维护者按子系统过滤海量邮件。
2. **考古语境**：不确定 area 时运行 `git log --no-merges -- <files>` 学习现有
   惯例（:343-345）——标题是 `git log --oneline` 的唯一载体，必须可扫读。
3. **语义语境**：正文要求四要素（:355-364）——问题是什么、为什么此方案更好、
   放弃的备选方案、评审争议的结论。问题陈述用现在时（:369-375，描述"没有你的
   补丁时的代码"），变更用祈使句（:379-384，"make xyzzy do frotz"）。
   **log 是写给三年后考古者的因果记录，不是给当代人的变更通知**。

### 6.3 维护模型与发布节奏

Documentation/howto/maintain-git.adoc 是维护者手册（以"被巴士撞了怎么办"开场，
:5-7）。维护者时间分配自述：沟通 45%、集成 50%、自己开发只有 5%（:15-20）。
分支模型（:34-84）：`master`（下一功能版）、`maint`（维护版）、`next`
（主题凑齐评审后进入，**至少测试 7 个自然日**才准进 master，:52-59）、`seen`
（试验场，3 周无人问津即可丢弃，:69-72）。发布节奏（:110-114）：一个功能发布
周期 **8-10 周**，正式版前若干个相隔约一周的 RC、RC 前一周发 preview。
Documentation/RelNotes/ 累计 542 份发布说明（1.5.0 到 2.56.0），每版人工撰写
面向用户的变更清单——发布说明也是长期文档资产。

---

## 7. 设计动机：可移植性纪律如何反过来塑造代码

- **老平台是规范之源，不是负担**。CodingGuidelines 的 POSIX 三段论（:4-19）
  与 `%z` 禁令（:324-327，MinGW）、IBM XLC 禁令（:328-330）说明：Git 支持的
  平台横跨 AIX、老 MSVC 到现代 Linux。为了保持可构建，代码风格被"降维"——
  变量声明必须块首、零初始化交给 BSS、不用 VLA。**风格即兼容性策略的固化**。
- **测试即规格**。t1000-read-tree-m-3way.sh 的 test_description（:6-29）不是
  注释而是可执行的算法说明：四条合并规则与后续用例一一对应。没有正式规格书的
  项目里，test_description + Documentation/ + RelNotes 共同承担规格角色，而测试
  是唯一能自动验证"规格仍被遵守"的部分。
- **已知 bug 存档体现"诚实工程"**：项目不假装没有 bug，而是把 bug 行为登记为
  TODO 测试（t/README:897-904）。当"已知破坏"变绿，事件本身触发一次评审
  （t/test-lib.sh:1251-1253），防止行为变化无记录地溜进主干。
- **机械重构入版本库**（coccinelle）：大库签名级重构的最大成本是语义冲突，
  Git 把重构规则本身 commit 进仓库、以 pending 后缀区分"在执行的"与"计划中的"
  （tools/coccinelle/README:32-45），使重构可从任何时间点恢复、复检、续做。
- **自研容器是风格的样板间**。strbuf.h:5-8 的"NOTE FOR STRBUF DEVELOPERS"
  禁止 strbuf 依赖上层 API；:19-25 定义核心不变量（`buf` 永不为 NULL、始终
  保有 `len+1` 字节且多出的一字节放 NUL，但无函数依赖"无内嵌 NUL"）。
  strvec.h:3-8 定义 strvec 不变量：`v` 非 NULL、在 `v[nr]` 处 NULL 结尾、可直接
  传给期望 argv 的函数；:15-17 说明 strvec 拥有自己的内存、push 即复制。两者
  都有 `STRBUF_INIT { .buf = strbuf_slopbuf }`（strbuf.h:74-80）式静态零分配
  初始化——**不变量写在头文件最显眼处，API 围绕不变量设计**。
- **邮件文化反向塑造 commit 格式**。"area: summary"（SubmittingPatches:337-343）
  存在的原因是补丁的评审界面是邮箱线程；50 字符限制对应 `git log --oneline`
  的扫读宽度。工具形态决定文本格式，再由规范固化为纪律。

## 8. FAQ 素材

**Q1：Git 为什么坚持用 shell 脚本写测试而不用 pytest/GoogleTest？**
被测对象是"git 命令在真实文件系统上的行为"，端到端 shell 是最贴近用户的观测层；
输出走 TAP（t/README:30-34），任意 harness 可接管。C 层另有单元测试
（t/unit-tests/，Clar 框架，28 个用例文件）。

**Q2：test_expect_failure 的用例转正流程是什么？**
通过时输出 `ok ... # TODO known breakage vanished`（t/test-lib.sh:841-845），
总结时打印 "known breakage(s) vanished; please update test(s)"（:1251-1253），
开发者此时应改写为 test_expect_success 并记录行为变更。

**Q3：为什么新测试跑之前会先报 "broken &&-chain"？**
test_run_ 先以退出码 117 试运行 `fail_117 && <测试体>`（t/test-lib.sh:1089-1094），
检测 `&&` 链中失败被短路的写法错误——测试代码同样受纪律约束。

**Q4：C99 特性怎么引入？为什么 %z 至今禁用？**
逐特性"测试气球"制（CodingGuidelines:314-320）：先小范围试用，确认平台无恙
再放开。`%z` 因 MinGW 的 C 库不支持而禁用（:324-327）。

**Q5：coccinelle 的 pending 后缀是什么意思？**
`*.pending.cocci` 不参与 `make coccicheck`（否则 CI 因计划中的重构报错），用
`make coccicheck-pending` 单独应用（tools/coccinelle/README:32-45）。

**Q6：为什么 commit 标题必须 "area: summary" 且不大写首词？**
标题同时充当补丁邮件主题与 `git log --oneline` 行（见 6.2 节）；句首大写对扫描
无益（SubmittingPatches:346-353），area 前缀才是检索主键。

**Q7：Git 多久发一个版本？**
功能版周期 8-10 周，前有 preview、后有若干相隔约一周的 RC
（maintain-git.adoc:110-114）；RelNotes 共 542 份发布说明可交叉印证。

**Q8：next 分支为什么要停 7 天？**
主题合入 `next` 后至少暴露 7 个自然日让使用者发现回归
（maintain-git.adoc:52-59）；`seen` 更松，3 周无人推动即丢弃（:69-72）。

**Q9：strbuf 和 string_list 为什么并存？**
strvec.h:10-13 解释了 argv 场景：string_list 的 item 带 util 字段，与传统 argv
接口不兼容；strvec 保证 NULL 结尾，可直接传给 exec 类接口。

**Q10：minimal 构建有什么用？**
NO_CURL 等开关（Makefile:465-467）让嵌入式/老平台只编核心功能，CI 有专门的
minimal 构建检查（Makefile:2610 注释）保证"减配后仍然链接可用"。

## 9. 深挖方向

1. **chainlint 的实现深度**：t/chainlint.pl 如何在 POSIX shell 语法层识别
   `&&` 链断裂与子 shell 遮蔽——"测试测试代码"主题的最好样本。
2. **spatchcache**（tools/coccinelle/spatchcache）：用 Redis 缓存 Coccinelle
   结果的"ccache 思想"，可对比现代编译缓存设计。
3. **GIT_TEST_USE_SET_E**（t/test-lib.sh:22-38）：框架对 `set -e` 的谨慎采用
   （bash>=5 才默认开），展示 20 年兼容层的渐进现代化。
4. **GIT_TEST_INSTALLED**（t/test-lib.sh:170-176）：测试永远针对"刚构建的那个
   git"，可与容器化 CI 的 hermetic 原则对照。
5. **RelNotes 写作流水线**：542 份发布说明如何半自动生成又保持人写口吻，
   可考 Documentation/RelNotes/ 目录。

---

## 10. 写作要点速查表

| 文件 | 行号 | 要点 |
|---|---|---|
| t/test-lib-functions.sh | 924 / 901 | test_expect_success / test_expect_failure 宏定义 |
| t/README | 897-900 | "known breakage"语义官方定义 |
| t/test-lib.sh | 841-847 | known_broken 计数器与 TODO 标记输出 |
| t/test-lib.sh | 1084-1094 | test_run_ 与 &&-chain 链检（魔法码 117） |
| t/test-lib.sh | 1231-1248 | test_done 写 .counts 六项统计 |
| t/test-lib.sh | 370 | TRASH_DIRECTORY="trash directory.$TEST_NAME" |
| t/test-lib-functions.sh | 1274 / 1319 / 1323 | test_cmp / test_i18ngrep 已废 / test_grep |
| t/test-lib-functions.sh | 136-149 | test_tick 固定时间起点 +60s/次 |
| t/README | 482-501 | tNNNN 命名法与家族编号 |
| Documentation/CodingGuidelines | 4-19 / 279-330 | POSIX 三段论；C99 时间线与测试气球 |
| Documentation/CodingGuidelines | 334-346 / 770-793 | 块首声明等 C 规矩；错误消息细则与 BUG() |
| Documentation/CodingGuidelines | 614-650 | struct S + S_verb() 命名法与生命周期动词 |
| Documentation/SubmittingPatches | 334-353 / 355-384 | 50 字符 + area: 前缀；正文四要素/祈使句 |
| tools/coccinelle/README | 7-45 | coccicheck 查坏模式 + pending 大重构 |
| tools/coccinelle/xcalloc.cocci | 1-10 | 语义补丁实例（参数顺序统一） |
| Makefile | 465-490 / 3978-3979 | NO_CURL/USE_LIBPCRE；check-builtins 交叉核对 |
| GIT-VERSION-GEN | 3, 42-57 | 版本号三级解析链 |
| Documentation/howto/maintain-git.adoc | 15-20 / 52-72 / 110-114 | 45/50/5 时间分配；next 7 天/seen 3 周；8-10 周节奏 |
| strbuf.h / strvec.h | strbuf.h:5-25,74-80 / strvec.h:3-17 | 低层原语禁令；argv 兼容不变量 |
