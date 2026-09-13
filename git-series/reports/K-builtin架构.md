# K 章：Builtin 架构 —— 149 个命令如何共享一副骨架

> 调研对象：Git 源码，commit `47ce805`（"A bit more for -rc1"）。本文所有 `文件:行号` 均以该提交为准，行号经 grep/Read 实际核对。
>
> 上一章（G）讲工程文化四柱，本章下沉到代码架构本体：`git` 可执行文件里的近 150 个 builtin 命令（git.c:533-689 的 `commands[]` 表恰好 149 条），加上 command-list.txt 里登记的约 190 个命令（含外部命令），如何共用"入口分发 → setup → 选项解析 → config 回调"这一副骨架。

## 1. 全景：一次 `git commit` 的完整分发链

从用户敲下 `git commit -m "msg"` 到 `builtin/commit.c` 里的业务代码，链路如下（每一步都给出行号锚点）：

```c
/* git.c:922 起的 cmd_main 是整个 Git 的真 main（由 common-main.c 包装） */
int cmd_main(int argc, const char **argv)
{
        cmd = argv[0];              /* git.c:928，取 argv[0] 的 basename */
        ...
        /* Look for flags.. */
        argv++;
        argc--;
        handle_options(&argv, &argc, NULL);   /* git.c:960 */
```

1. **argv[0] 归一化**：`git-foo` 形式的直接调用（`/usr/bin/git-commit`）剥掉 `git-` 前缀后直接走 builtin，不走外部命令 fallback（git.c:949-955，注释明说"cannot execute it externally"）。
2. **全局选项预处理**：`handle_options()`（git.c:157-360）吃掉 `<command>` 之前的所有全局开关，多数通过 `setenv` 落进环境变量：`--git-dir`→`GIT_DIR`（git.c:214-227）、`--work-tree`→`GIT_WORK_TREE`（git.c:242-255）、`-C <path>` 直接 `chdir`（git.c:316-326）。最关键的是 `-c`（git.c:264-269）：调用 `git_config_push_parameter()` 把键值对推入 `GIT_CONFIG_PARAMETERS` 环境变量（config.c:453-467），等仓库发现之后再统一读取——这就是"-c 优先级最高"的实现方式。
3. **无命令时打印 usage**（git.c:962-969），`--version`/`--help` 被改写为 `version`/`help` 命令（git.c:971-974）——它们本身也是 commands[] 表中的普通条目（git.c:683、git.c:593）。
4. **`setup_path()`**（git.c:984）把 exec-path 前插到 PATH，为外部命令铺路。
5. **`run_argv()` 循环**（git.c:842-920，由 cmd_main 的 while 驱动 git.c:989-1009）：这是别名展开与命令分发的中枢。
6. **`handle_builtin()`**（git.c:754-791）：先处理 `git cmd --help` → 改写为 `git help cmd`（git.c:762-771），然后 `get_builtin()` 查表（git.c:773），命中则 `run_builtin()` 并 `exit(ret)`（git.c:786-789）。
7. **`run_builtin()`**（git.c:470-531）：按命令的标志位做 setup（详见第 2 节），最后 `status = p->fn(argc, argv, prefix, repo)`（git.c:510）——这就是 `cmd_commit()` 的调用点（签名见 builtin/commit.c:1698-1701）。
8. 若查表未命中：`execv_dashed_external()`（git.c:793-834）尝试执行 `git-<cmd>` 外部程序；仍未命中则把参数交给 `handle_alias()`（git.c:912）做别名展开，展开后重跑循环。

`run_builtin` 的核心骨架（git.c:476-510）浓缩后只有十几行：

```c
int run_setup = (p->option & (RUN_SETUP | RUN_SETUP_GENTLY));

help = argc == 2 && (!strcmp(argv[1], "-h") || ...);      /* git.c:478 */
if (help && (run_setup & RUN_SETUP))
        run_setup = RUN_SETUP_GENTLY;   /* git cmd -h 在仓库外也能跑 */

if (run_setup & RUN_SETUP) {
        prefix = setup_git_directory(the_repository);   /* git.c:484 */
} else if (run_setup & RUN_SETUP_GENTLY) {
        prefix = setup_git_directory_gently(the_repository, &no_repo);
} ...
if (use_pager == -1 && run_setup && !(p->option & DELAY_PAGER_CONFIG))
        use_pager = check_pager_config(repo, p->cmd);   /* git.c:495 */
...
if (!help && p->option & NEED_WORK_TREE)
        setup_work_tree(the_repository);                /* git.c:503-504 */
...
status = p->fn(argc, argv, prefix, no_repo ? NULL : repo);  /* git.c:510 */
```

注意 `git commit` 在表中的登记是 `{ "commit", cmd_commit, RUN_SETUP | NEED_WORK_TREE }`（git.c:560）——所以走到 cmd_commit 时：仓库已发现、cwd 已 chdir 到工作树顶、`prefix` 已算好、config 已可读。

## 2. 分发表专节：cmd_struct 标志位语义

### 2.1 表结构与标志位定义

```c
/* git.c:21-31 */
#define RUN_SETUP           (1<<0)
#define RUN_SETUP_GENTLY    (1<<1)
#define USE_PAGER           (1<<2)
/*
 * require working tree to be present -- anything uses this needs
 * RUN_SETUP for reading from the configuration file.
 */
#define NEED_WORK_TREE      (1<<3)
#define DELAY_PAGER_CONFIG  (1<<4)
#define NO_PARSEOPT         (1<<5) /* parse-options is not used */
#define DEPRECATED          (1<<6)

struct cmd_struct {                      /* git.c:33-37 */
        const char *cmd;
        int (*fn)(int, const char **, const char *, struct repository *);
        unsigned int option;
};
```

builtin.h:9-110 有一份"官方注释版"的标志位文档（`RUN_SETUP` 在 builtin.h:32，`NEED_WORK_TREE` 在 builtin.h:49，`DELAY_PAGER_CONFIG` 在 builtin.h:55，`NO_PARSEOPT` 在 builtin.h:63，"How a built-in is called" 在 builtin.h:97）。逐个落地语义：

| 标志位 | run_builtin 中的落地 | 含义 |
|---|---|---|
| `RUN_SETUP` | git.c:483-485 | 仓库发现失败即 die；发现成功则 chdir 到工作树顶并返回 `prefix` |
| `RUN_SETUP_GENTLY` | git.c:486-487 | 尽力而为，仓库外也能跑（如 `git config`、`git hash-object`，git.c:563、592） |
| `USE_PAGER` | git.c:496-497 | stdout 为 tty 时挂分页器（如 `range-diff`，git.c:635） |
| `NEED_WORK_TREE` | git.c:503-504 | 在 RUN_SETUP 之上多调一次 `setup_work_tree()`（setup.c:494-511），非工作树内直接 die("this operation must be run in a work tree") |
| `DELAY_PAGER_CONFIG` | git.c:493-495 | 推迟 `pager.<cmd>` 配置判断，让 builtin 按子命令自行决定（branch/tag/status 家族，git.c:542、663、669） |
| `NO_PARSEOPT` | 仅作标记 | 该命令自造解析器，`git --list-cmds=parseopt` 会把它排除（git.c:331-337），补全脚本据此分流 |
| `DEPRECATED` | git.c:836-840 | 废弃命令仍可用，但别名可覆盖之（git.c:848-858） |

几个值得注意的表内事实：`clone` 是极少数**无任何 setup 标志**的 porcelain（git.c:558，它自己创造仓库）；`rev-parse`、`diff` 等至今标着 `NO_PARSEOPT`（git.c:571、652）；`pickaxe` 是 `blame` 的旧别名（git.c:630，同一函数指针）；`stage` 与 `add` 共享 `cmd_add`（git.c:534、662）。

### 2.2 查表与外部命令（dashed）路径

`get_builtin()` 是一次朴素的线性 `strcmp` 扫描（git.c:691-699）——对 149 个条目、一次性进程而言，不值得上哈希表。

查表失败后的 `execv_dashed_external()`（git.c:793-834）：

```c
strvec_pushf(&cmd.args, "git-%s", argv[0]);   /* git.c:802 */
strvec_pushv(&cmd.args, argv + 1);
cmd.clean_on_exit = 1;
cmd.silent_exec_failure = 1;
cmd.trace2_child_class = "dashed";            /* git.c:807 */
...
status = run_command(&cmd);                   /* git.c:823 */
if (status >= 0)
        exit(status);
else if (errno != ENOENT)
        exit(128);                            /* git.c:830-833 */
```

要点：它按 PATH 搜索 `git-<cmd>`（exec-path 已由 git.c:984 前插），`ENOENT` 时静默返回继续尝试别名。今天还活着的 dashed 外部命令主要是 `git-daemon`、远程侧 helper（`git-remote-*`、`git-upload-pack`）和各类 `git-credential-*`。**性能含义**：builtin 命中时全程零 fork；只有 alias 展开后才被迫走子进程——git.c:859-867 的注释专门解释了这一点："If we tried alias and futzed with our environment, it is no longer safe to invoke builtins directly"，所以别名指向 builtin 时也要 fork 一次 `git <cmd>`（git.c:870-902，trace2 标为 `_run_git_alias_`）。此外 run_builtin 末尾会检查 stdout 的写错误（git.c:516-529），这是把"管道关闭"这类错误也归口到统一出口的细节。

## 3. parse-options 专节：一套宏 + 一个状态机

### 3.1 数据结构与宏族

一切选项描述收敛到一个 11 字段的结构体（parse-options.h:155-170），核心是 `type / short_name / long_name / value / argh / help / flags / callback / defval / subcommand_fn`。宏族分两批：

- **底层带 `_F` 的构造器**（parse-options.h:172-231）：`OPT_BIT_F`（172）、`OPT_COUNTUP_F`（183）、`OPT_SET_INT_F`（192）、`OPT_CALLBACK_F`（203）、`OPT_STRING_F`（213）、`OPT_INTEGER_F`（222）——直接展开成 `struct option` 复合字面量。
- **上层便捷宏**（parse-options.h:233-403）：`OPT_END()`（233，表终止哨兵）、`OPT_BOOL`（269，= `OPT_SET_INT_F(...,1,0)`）、`OPT_BIT`（245）、`OPT_CMDMODE`（280，自带 `PARSE_OPT_CMDMODE` 互斥标志）、`OPT_STRING_LIST`（304，预绑 `parse_opt_string_list` 回调）、`OPT_SUBCOMMAND`（396-403）。

`flags` 分两层，作用域完全不同，初读极易混淆：
- **上下文级** `enum parse_opt_flags`（parse-options.h:34-43）：`PARSE_OPT_STOP_AT_NON_OPTION`（36）、`KEEP_UNKNOWN_OPT`（38）、`NO_INTERNAL_HELP`（39）、`SUBCOMMAND_OPTIONAL`（42）——传给 `parse_options()` 的行为开关；
- **选项级** `enum parse_opt_option_flags`（parse-options.h:45-57）：`OPTARG`（46，可选参数）、`NOARG`（47）、`NONEG`（48，禁止 `--no-` 变体）、`HIDDEN`（49）、`CMDMODE`（56，互斥）。

### 3.2 状态机与自动 usage

`parse_options()`（parse-options.c:1189-1245）先 `preprocess_options` 展开 `OPT_ALIAS`，再驱动 `parse_options_step()`（parse-options.c:995-1177）逐个吃参数，返回值直接映射到退出码：`PARSE_OPT_HELP → exit(0)`，`ERROR → exit(129)`（parse-options.c:1207-1211）——Git 用户熟悉的"用法错误退出码 129"就写死在这里。状态机主干：

- 非选项参数：无子命令模式时看 `PARSE_OPT_STOP_AT_NON_OPTION`——置位则返回 `PARSE_OPT_NON_OPTION` 让调用方接管剩余 argv（parse-options.c:1014-1018），未置位则收集进 out（1017）；有子命令模式则查 `parse_subcommand()`（1020-1046）。
- **孤立的 `-h`**（total==1 且仅为 `-h`）：直接跳 usage（parse-options.c:1050-1051）——配合 git.c:478-481 的降级，`git commit -h` 在任何目录都能打印帮助而不必发现仓库。
- 短选项聚簇：`-avp` 拆开循环解析（parse-options.c:1062-1110）。
- `--` 终止符与 `--end-of-options`（parse-options.c:1113-1125）；`--help-all`（1127-1129）。
- 长选项 `parse_long_opt`（parse-options.c:519-597）内置两个高级语义：`--no-` 前缀取反（530-534，`OPT_UNSET` 标志一路传给回调的 `unset` 参数）与**前缀缩写匹配**（553-565），歧义时报 "ambiguous option"（567-574）。

usage 文本完全由选项表生成：`usage_with_options_internal()`（parse-options.c:1324 起）按 `USAGE_OPTS_WIDTH 26` 对齐（parse-options.c:1304-1312），`argh` 里含 `()<>[]|` 时原样输出否则加尖括号（`usage_argh`，1247-1300），布尔选项自动打印 `--[no-]<name>`（parse-options.c:1444-1447）。这也解释了 t0450 测试为什么能机器比对 -h 输出与文档 SYNOPSIS（builtin.h:74-75 的注释提到）。

### 3.3 子命令模式：`git stash push` 是如何炼成的

OPTION_SUBCOMMAND 是较新的架构：命令表里登记"子命令名 → 函数指针"，状态机遇到第一个非选项参数时匹配之（parse-options.c:609-620，把 `subcommand_fn` 写入 `value`）并整体返回，剩余 argv 留给子命令函数再解析一轮。builtin/stash.c:2463-2475 一口气登记 12 个子命令：

```c
/* builtin/stash.c:2463-2475（cmd_stash 内的选项表） */
OPT_SUBCOMMAND("apply", &fn, apply_stash),
OPT_SUBCOMMAND("push",  &fn, push_stash_unassumed),
OPT_SUBCOMMAND_F("save", &fn, save_stash, PARSE_OPT_NOCOMPLETE),
OPT_END()
```

随后 `git stash` 以三个标志解析（builtin/stash.c:2483-2487）：`PARSE_OPT_SUBCOMMAND_OPTIONAL | PARSE_OPT_KEEP_UNKNOWN_OPT | PARSE_OPT_KEEP_DASHDASH`——子命令可选、未知选项与 `--` 都留给子函数。`fn == NULL` 且无参数时，代码把 `"push"` 手工压进 argv 头部，实现"裸 `git stash` 等价于 `git stash push`"的默认行为（builtin/stash.c:2496-2502 的 "Assume 'stash push'"）。

### 3.4 Callback 模式与 CMDMODE 互斥

`OPTION_CALLBACK` 的取值逻辑在 `do_get_value()`（parse-options.c:236-259）：先判定 `p_unset`（`--no-` 形式、`NOARG`、`OPTARG` 无值三种情形），再调 `opt->callback(opt, p_arg, p_unset)`。这是 Git 世界里"函数指针 + void* 数据"的标准闭包替身：宏 `parse_options.h:71` 定义了 `parse_opt_cb` 三参签名。常用预制回调集中在 parse-options.h:530-547（`parse_opt_verbosity_cb`、`parse_opt_object_id`、`parse_opt_passthru` 等）。`git commit -m` 就是典型用户回调（builtin/commit.c:1713 `OPT_CALLBACK('m', "message", &message, ..., opt_parse_m)`）。

另一个精致细节：`PARSE_OPT_CMDMODE` 让一组互斥选项（如 `--amend`/`--fixup`）自动冲突检测——`get_value()` 里维护 cmdmode 链表，一旦两个 CMDMODE 选项都非零就报 "options '%s' and '%s' cannot be used together"（parse-options.c:386-423，报错在 414 行）。`git commit` 选项表 1705-1790 行展示了全部惯用法：分组（`OPT_GROUP`，1709）、可选参数（`-S` 的 `PARSE_OPT_OPTARG`，1730-1739）、隐藏选项（`OPT_HIDDEN_BOOL`）。

## 4. config 专节：层级、includeIf 与回调式 API

### 4.1 读取层级：一条行号链

真正的层级序藏在 `do_git_config_sequence()`（config.c:1556-1622），按调用顺序：

1. **system**：`GIT_CONFIG_SYSTEM` 环境变量或编译期 `ETC_GITCONFIG`（config.c:1508-1515；读取点 config.c:1583-1588）；`GIT_CONFIG_NOSYSTEM` 可整体关闭（config.c:1551-1554）。
2. **global（XDG 优先判空）**：`GIT_CONFIG_GLOBAL` → `~/.gitconfig` → `~/.config/git/config`（config.c:1537-1549；读取点 1592-1598）。
3. **local**：`<commondir>/config`（config.c:1576；读取点 1600-1603）。
4. **worktree**：`<gitdir>/config.worktree`，仅当 `extensions.worktreeConfig`（`repo->repository_format_worktree_config`）开启时读（config.c:1605-1611）。
5. **命令行**：`git_config_from_parameters()` 最后读（config.c:1613-1614）——"最后写者胜"的解析器行为使 -c 覆盖一切。

`git -c` 的实现链：git.c:264-269 → `git_config_push_parameter()`（config.c:469-503，把键值 sq_quote 后追加进 `GIT_CONFIG_PARAMETERS` 环境变量，453-467）→ 读取期 `git_config_from_parameters()`（config.c:734-790，兼容 `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` 计数式变量，744-782）。这套"环境变量中转"是为了让 `-c` 穿透子进程（dashed 外部命令、hook）——环境在，配置就在。

### 4.2 include / includeIf：回调链上的装饰器

Git 没有把 include 做进解析器，而是包了一层装饰器函数 `git_config_include()`（config.c:419-451）：`config_with_options()` 在 `respect_includes` 时把用户的 fn 换成它（config.c:1632-1638）。装饰器先无条件把每条配置转发给真 fn（config.c:432，保证 `git config --get include.path` 可查询），再针对 `include.path`（436-437）与 `includeIf.<cond>.path`（439-448）递归拉起新的解析。`handle_path_include()`（config.c:142-191）处理路径展开：相对路径**基于包含它的文件所在目录**而非 cwd（162-175），深度上限 10 层防环（135、178-179）。

条件判断在 `include_condition_is_true()`（config.c:393-417）：`gitdir:`、`gitdir/i:`、`worktree:`、`onbranch:`、`hasconfig:remote.*.url:` 五族前缀（399-413），**未知条件恒为假**（415-416）——向前兼容的手法。`gitdir:` 的模式匹配先经 `prepare_include_condition_pattern()`（config.c:199-236）规范化：相对模式自动加 `**/` 前缀（227-228）、目录尾部补 `**`（193-197），所以 `gitdir:nebula/` 能匹配任意深度的仓库路径。

### 4.3 回调式 API 为什么比对象式好

`repo_config()`（config.c:2346-2354）是大多数 builtin 的入口：仓库未就绪时降级 `read_very_early_config`（2348-2351），否则惰性初始化缓存（`git_config_check_init`，2332-2337 → `repo_read_config`，2299-2330，把所有层级灌进 `repo->config` 这个 config_set）再 `configset_iter()` 重放（1666-1685）。config.h:207 附近的注释直接给出了设计理由——"call `repo_config` with a callback function and void data pointer"。这个设计的本质是**用函数指针模拟闭包**：

- 回调签名 `config_fn_t(var, value, ctx, data)`（config.h:163）中 `data` 即闭包环境。config.h:205-214 的注释把语义说得很直白：按优先级递增顺序喂给回调，"a callback should typically overwrite previously-seen entries with new ones"——C 没有嵌套函数，也无法为每个 key 动态分发,遍历式回调把"解析顺序"变成了"优先级"——后读的 local 配置后到，回调里"后写者覆盖"只需要简单赋值。
- 同一个数据流有三种消费方式：流式（一次性，read_early_config，config.c:1687-1720，仓库未发现时也能读、不污染全局状态）、缓存式（repo_config 先 init 再迭代）、点查式（`repo_config_get_value_multi`，config.c:2369-2374，供需要"多值"语义的调用方如 `remote.*.url`）。别名查找就是流式的受益者：`alias_lookup()` 用 `read_early_config`（alias.c:84-91），使得别名展开不必先完成仓库 setup（git.c:372-468 的 handle_alias 因此可以在 setup 之前工作）。

对比"一次性加载成哈希表"的对象式 API：回调式天然保留了**来源信息**（`ctx->kvi` 携带 filename/linenr/scope，config.c:1679-1683 报错时能指到行号），且多值（`[a] b=1 b=2`）不需要特判；代价是调用方写回调样板代码。Git 的折中是两者都留：新代码先用回调，再按需落缓存。

## 5. setup 专节：仓库发现算法

### 5.1 向上找 .git 的 walk

`setup_git_directory()`（setup.c:2189-2192）如今只是 `setup_git_directory_gently(repo, NULL)` 的薄包装。搜索核心在 `repo_discovery_find_dir()`（setup.c:1569-1724）：

- 若 `GIT_DIR` 环境变量已设，**完全跳过搜索**只做验证（setup.c:1578-1582）。
- `GIT_CEILING_DIRECTORIES` 先行处理：过滤、规范化、`longest_ancestor_length` 算出 ceil_offset（setup.c:1584-1594）。
- 每一级目录的检查顺序在注释里写明（setup.c:1610-1616）：`.git` 文件（gitfile，内容 `gitdir: ...`）→ `.git/` 目录 → 当前目录本身（bare）。判定 `.git/` 是否是仓库用 `is_git_directory()`（setup.c:413-451）：三签名 `HEAD`（可解析的引用，420-424）+ `objects/`（435-440）+ `refs/`（442-445）。
- 默认**不跨文件系统**：记录起始目录的 `st_dev`，越界即返回 `GIT_DIR_HIT_MOUNT_POINT`（setup.c:1617-1618、1720-1722），`GIT_DISCOVERY_ACROSS_FILESYSTEM` 可解除。
- 每发现一个候选 gitdir 都过 `ensure_valid_ownership()`（setup.c:1677-1682）——"dubious ownership" 检查，失败时 repo_discover 给出 `safe.directory` 建议（setup.c:1981-1996）。
- 到顶（ceil_offset）仍未找到 → `GIT_DIR_HIT_CEILING`（setup.c:1711-1717）。

### 5.2 chdir 语义与 prefix

找到仓库后 `repo_discover()`（setup.c:1935-2014）做一件对外不可见却影响深远的事：**把进程 cwd chdir 到工作树顶**（`GIT_DIR_DISCOVERED` 分支，setup.c:1957-1961），然后把"原 cwd 相对树顶的路径"算成 `prefix`（repo_discover_implicit_gitdir 内，setup.c:1268-1278，形如 `sub/dir/`）。显式 GIT_DIR 时 worktree 判定规则更细：`GIT_WORK_TREE` 环境变量压过 `core.worktree`（setup.c:1177-1185），相对 `core.worktree` 要做三段 chdir 往返解析（1195-1203），cwd 在树内则同样算 prefix（1222-1232）。prefix 最终导出为 `GIT_PREFIX` 环境变量（setup.c:2117-2124），alias 的 shell 形式依赖它（git.c:392-393 的注释"Aliases expect GIT_PREFIX, GIT_DIR etc to be set"）。

这就是第 2 节标志位的最终归宿：`RUN_SETUP`（git.c:484）触发上述全流程；`NEED_WORK_TREE` 再补一刀 `setup_work_tree()`（git.c:503-504 → setup.c:494-511），后者在 bare 仓库里直接 die（setup.c:502-503），并把相对 `GIT_WORK_TREE` 规范成 `.`（setup.c:509-510），保证子进程再走 setup 时结果一致。`setup_original_cwd()`（setup.c:513 起）则记录原始 cwd，供某些命令（如 `git update-index` 从树外运行）判断行为。多工作树（linked worktree）场景下 gitdir 与 commondir 分离，`repo_discover_explicit_gitdir` 的 `dir_inside_of` 判定与 t1510 测试注释编号（setup.c:1174、1221 等 `#3, #7, #11...`）是这个矩阵复杂度的直接证据。

## 6. 设计动机

**为什么 builtin 化**。早期 Git 的 porcelain 多是 shell 脚本（`git-clone.sh` 时代），每个命令一次 `exec git-xxx`，Windows 上 fork 开销与引号转义都是灾难。迁入 `commands[]` 表后：一个可执行文件承载所有命令（部署、升级、补全、`git` 前缀校验都简化）；命令间共享进程内对象库与索引缓存；trace2 埋点统一（git.c:507）。如今 builtin 化仍在进行——commands[] 里 `merge-recursive` 等纯 plumbing 也在表中（git.c:613-616），而 shell 残留只剩 mergetool 等少数（仓库根目录仍可见 git-mergetool.sh）。

**分发表 + 标志位 vs FFmpeg CLI 的任务装配**（16 章对照）。两者都是"C 语言里手造的声明式框架"，但形态相反：FFmpeg 用"组件注册表 + 运行时图装配"（编解码器/滤镜各自注册，`ffmpeg` 进程内动态连线），Git 用"静态表 + 互斥标志位"（149 条 `{名字, 函数, 标志}` 编译期定死，标志位只描述 setup 需求而非能力）。Git 的选择源于它的任务形状——每个命令生命周期短、setup 流程高度收敛（发现仓库、读 config、挂 pager），用 7 个位就刻画完了；不需要运行时图。代价是可扩展性：第三方命令永远进不了 commands[] 表，只能走 dashed 外部路径（第 2 节）——这也是 Git 生态里"subcommand 插件"始终二等公民的结构性原因。

**回调式 config 的取舍**。备选方案是"加载成 config_set 再点查"（Git 也做了，config.c:2369-2374）或"解析成树"。回调式胜在：来源可溯（kvi 携带文件名行号）、流式处理让 include/includeIf 只是 fn 上的装饰器（第 4.2 节）、优先级即迭代顺序无需排序逻辑。牺牲的是写法直观性——每个消费方都要写一个 callback + context struct。alias.c:16-82 的 `config_alias_cb` 是这份"样板税"的标准样例：约 60 行只为从 config 里捞出 `alias.<name>`。

## 7. FAQ 素材

1. **`git commit -h` 为什么在非仓库目录也能跑？** run_builtin 检测到唯一参数是 `-h` 时把 `RUN_SETUP` 降级为 `RUN_SETUP_GENTLY`（git.c:478-481），parse-options 侧孤立 `-h` 直通 usage（parse-options.c:1050-1051）。
2. **`git --exec-path`、`--list-cmds=` 这类"伪选项"是谁处理的？** handle_options 里的普通分支（git.c:178-197、338-344），它们在进入命令分发前就消费掉了。
3. **选项用法错误为什么总是退出码 129？** parse_options 的 switch 里写死 `exit(129)`（parse-options.c:1209-1211）。
4. **`git stash`（无子命令）为什么等价于 `git stash push`？** `PARSE_OPT_SUBCOMMAND_OPTIONAL` 让子命令可缺省，`fn==NULL` 时手工补 "push" 参数重推（builtin/stash.c:2483-2502）。
5. **`--no-xxx` 是每个选项手动实现的吗？** 不是，parse-options 自动生成：`--no-` 前缀在 parse_long_opt 统一识别（parse-options.c:530-534），usage 里自动显示 `--[no-]`（parse-options.c:1444-1447）；`PARSE_OPT_NONEG` 可禁用（parse-options.h:48）。
6. **长选项可以缩写吗？** 可以，无歧义前缀即命中（parse-options.c:553-565），歧义时报 "ambiguous option"；测试环境可用 `GIT_TEST_DISALLOW_ABBREVIATED_OPTIONS` 强制禁用（parse-options.c:1198-1199）。
7. **`git -c foo.bar=1` 如何传给子进程（hook/dashed 命令）？** 键值对 sq_quote 进 `GIT_CONFIG_PARAMETERS` 环境变量（config.c:453-467），任何子进程里的 Git 都会在 config 序列最后读取它（config.c:1613-1614）。
8. **config 优先级里 XDG 和 ~/.gitconfig 谁赢？** do_git_config_sequence 先读 XDG 后读 user，后到者胜；而 `git_global_config()` 给 `git config --global --edit` 等挑选编辑目标时的规则不同：~/.gitconfig 存在即用它（config.c:1517-1535）。
9. **includeIf 为什么未知条件一律为假？** 向前兼容设计（config.c:415-416），老版本 Git 读到新条件语法时静默忽略而非报错。
10. **alias 展开后的 builtin 为什么还要 fork 子进程？** 别名可能改动环境（handle_options 的 envchanged），git.c:859-867 注释明说不安全，所以统一走 `git <cmd>` 子进程。

## 深挖方向

1. **`git cmd --help` 的改写链**：handle_builtin 把 `git commit --help` 改写成 `git help --exclude-guides commit`（git.c:762-771）——文档系统与命令系统的接缝，可延伸到 `git help` 的分类列表如何消费 command-list.h（help.c:14 include，help.c:85-91 使用）。
2. **OPT_ALIAS 与 preprocess_options**：选项级别的别名（如 `git branch --move` 之于 `-m`）在解析前被展开（parse-options.c:1202），宏定义在 parse-options.h:389-394。
3. **`ensure_valid_ownership` 与 safe.directory 的攻防**：仓库发现路径上每一级都验证所有者（setup.c:1677-1682），其审计线索可从 setup.c:1981-1996 的报错文案反查。
4. **completion 的私聊协议**：`--git-completion-helper`（parse-options.c:1057-1060）与 `git --list-cmds=parseopt`（git.c:331-337）是 Git 与补全脚本的私有接口，`PARSE_OPT_NOCOMPLETE`/`COMP_ARG`（parse-options.h:54-55）是其元数据。
5. **worktree 配置的分层陷阱**：`config.worktree` 仅在 `extensions.worktreeConfig` 开启时生效（config.c:1605-1611），与 `core.bare`/`core.worktree` 的冲突校验（apply_repository_format，setup.c:1779-1789）构成一个值得单独成文的配置语义矩阵（t1510 的编号注释就是地图）。

## 写作要点速查表

| 主题 | 锚点 | 内容 |
|---|---|---|
| 标志位定义 | git.c:21-31 | RUN_SETUP 等 7 个位 + cmd_struct |
| run_builtin 骨架 | git.c:470-531 | -h 降级(478)、setup(483)、pager(493)、worktree(503)、p->fn(510) |
| commands[] 表 | git.c:533-689 | 149 条；commit 在 560，clone 无标志在 558 |
| 线性查表 | git.c:691-699 | get_builtin 的 strcmp 扫描 |
| dashed 外部命令 | git.c:793-834 | "git-%s"拼接(802)、ENOENT 放行(830-833) |
| 别名循环中枢 | git.c:842-920 | 弃用命令可被 alias 覆盖(854)、alias 后必 fork(870-902) |
| 全局选项 | git.c:157-360 | -c(264)、--git-dir(214)、-C(316) |
| 选项上下文 flags | parse-options.h:34-43 | STOP_AT_NON_OPTION、KEEP_UNKNOWN 等 |
| 状态机 | parse-options.c:995-1177 | 孤立-h(1050)、子命令(1020)、--(1113) |
| usage 生成 | parse-options.c:1304-1500 | 宽度26(1304)、--[no-](1444) |
| 子命令注册 | builtin/stash.c:2463-2487 | OPT_SUBCOMMAND + 三个 flags |
| config 层级链 | config.c:1556-1622 | system(1583)→xdg(1592)→global(1596)→local(1600)→worktree(1605)→cmdline(1613) |
| includeIf 条件 | config.c:393-417 | gitdir:/onbranch: 五族(399-413)、未知恒假(415) |
| include 装饰器 | config.c:419-451, 1632-1638 | 先转发后递归(432) |
| 回调式入口 | config.c:2346-2354 | repo_config→惰性缓存(2332)→迭代(1666) |
| 仓库发现 walk | setup.c:1569-1724 | GIT_DIR 短路(1578)、三签名(413-451)、ownership(1677) |
| chdir+prefix | setup.c:1957-1961, 1268-1278 | 树顶 chdir、prefix 计算、GIT_PREFIX 导出(2117-2124) |
| 别名展开 | git.c:372-468 + alias.c:84-91 | !shell 形式(388)、环检测(429-449)、early config 读取 |
