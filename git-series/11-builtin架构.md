# 第 11 章 · builtin 架构:200+ 命令的公共骨架(卷末)

> 基线:commit `47ce805`。行号以 git.c、parse-options.c、config.c、setup.c 为准。卷一 07 章讲了工程文化四柱——本章讲代码架构本体:149 条 builtin 如何共享一个骨架。

## 11.0 全景:一次 `git commit` 的分发链

```
cmd_main(git.c:922)
  → handle_options(:157)吃掉全局选项(-C/-c/--exec-path…)
  → run_argv(:842):命令别名展开
  → handle_builtin(:754):get_builtin 线性查表(:691,149 条 strcmp)
  → run_builtin(:470):按 cmd_struct 标志位依次
      setup(:483-490)→ pager config(:493)→ setup_work_tree(:503)
      → p->fn(argc, argv, prefix, repo)(:510)
  查表未命中 → execv_dashed_external(:793):拼 git-<cmd> 走 PATH
```

分发表 `commands[]`(git.c:533-689)恰好 149 条,每条是 `struct cmd_struct{名,函数,标志位}`(:21-37)——`RUN_SETUP`(发现仓库)、`NEED_WORK_TREE`(再检出工作树)、`DELAY_PAGER` 等;`commit` 在 :560;`clone` 是唯一无 setup 标志的 porcelain(:558)。两个体贴的细节:`git cmd -h` 把 RUN_SETUP 降级 GENTLY(:478-481)——**帮助在仓库外也能跑**;查表是朴素线性扫描无哈希(:691-699)——149 条 strcmp 的成本可忽略,**简单即正确**。

## 11.1 外部命令与别名

查表未命中走 `execv_dashed_external`(:793):拼 `git-<cmd>` 在 PATH 找(ENOENT 放行)——这是历史遗留的"外部 git-* 命令"扩展点(现在也容纳第三方子命令)。**别名展开后必 fork 子进程**(:859-902):因为全局环境(setup 的 chdir、变量)已被改过,不再安全复用进程——"展开"不是文本替换而是重新执行。对照 FFmpeg CLI(16 章):ffmpeg 把全部逻辑收进一个二进制的任务装配,git 保留"命令=独立入口"的 Unix 形态,分发表只是入口的路由器。

## 11.2 parse-options:宏族与自动 usage

`OPT_*` 宏族(parse-options.h)声明选项,parse_options_step 状态机解析。三个内置语义(:530-565):**`--no-` 取反与前缀缩写匹配是解析器内置**,非逐选项实现;usage 自动生成时显示 `--[no-]<name>`(:1444-1447)——选项的"可否定性"是一等公民。用法错误退出码 129 写死(:1209-1211)。**子命令模式**是框架的精妙处:`git stash push/pop/list` 用 OPT_SUBCOMMAND 表+`SUBCOMMAND_OPTIONAL|KEEP_UNKNOWN_OPT|KEEP_DASHDASH`(builtin/stash.c:2463-2487),裸 `stash` 手工补 "push"——**子命令不是分发器特例,是选项解析的一个模式**。

## 11.3 config:回调式与 includeIf

读取层级即优先级(config.c:1556-1622 的 `do_git_config_sequence`,顺序执行后写覆盖):system(:1583)→ XDG(:1592)→ ~/.gitconfig(:1596)→ local `<commondir>/config`(:1600)→ worktree `config.worktree`(:1605,需 extensions.worktreeConfig)→ 命令行 -c(:1613)。**-c 的传递机制**:经 git.c:264 转义后进 `GIT_CONFIG_PARAMETERS` 环境变量(config.c:453-467)——穿透子进程,`git -c x=y submodule update` 的深层配置生效原理。

API 是**回调式**(config_fn_t,config.h:163)而非一次性加载:遍历文件逐条调 fn——注释明说"后写者覆盖"就是优先级的实现(:163)。C 无闭包,函数指针+void* 载荷即"闭包"。include/includeIf 是回调链上的**装饰器**(config.c:419-451:先转发后递归);条件五族 gitdir:/worktree:/onbranch: 等(:393-417),未知条件恒假(:415)——**安全的默认失败**。

## 11.4 setup:仓库发现

`setup_git_directory` 向上逐级 walk 找 .git(:413-451 的 is_git_directory 三签名:HEAD+objects/+refs/);**每级过 dubious ownership 检查**(:1677-1682,CVE-2022-24765 的防线)——目录属主与当前用户不符即拒。发现后**进程 chdir 到工作树顶**(:1957-1961),prefix=原 cwd 的相对路径(:2117-2124 导出 GIT_PREFIX)——builtin 收到的路径参数都是相对 prefix 的,这是"在子目录运行 git 命令"的实现根基。

## 11.5 设计动机

1. **分发表+标志位是"声明式 main"**:149 个命令的行为差异被压缩成 3 个标志位——RUN_SETUP 隐含了仓库发现/所有权检查/chdir/prefix 全链条,新 builtin 只写业务;
2. **回调式 config 优于对象式**:不建内存模型,流式遍历+后写覆盖——低内存、无同步问题、include 天然组合;代价是每条配置的查询都要重走遍历(有缓存层);
3. **"-h 在仓库外可跑"是产品意识**:(:478-481)的 GENTLY 降级让新手第一命令 `git help` 永不失败;
4. **dubious ownership 是事故驱动的安全**:CVE-2022-24765(恶意仓库诱导)后每级目录都验属主(:1677-1682)——**安全检查挂在"发现"这个必经点**最经济。

## 11.6 FAQ

**Q1:git 命令是进程还是函数?**
builtin=同进程函数(分发表直调);git-<cmd> 外部命令才 execv(:793);别名总是子进程(:859-902)。

**Q2:`git -c x=y` 怎么传给子命令?**
进 GIT_CONFIG_PARAMETERS 环境变量(config.c:453-467)——环境变量是跨进程的配置管道。

**Q3:为什么在子目录运行 git 也能工作?**
setup 向上找 .git 后 chdir 到树顶+prefix 记住原位置(:1957-1961,:2117-2124)。

**Q4:config 的优先级到底谁赢?**
后读的覆盖先读的:命令行 -c > worktree > local > global > system(config.c:1556-1622 顺序即实现)。

**Q5:includeIf "gitdir:" 怎么匹配?**
五族条件(:393-417);未知条件恒假(:415)——向前兼容的失败方向。

**Q6:git stash pop 的 pop 是怎么解析的?**
OPT_SUBCOMMAND 模式(builtin/stash.c:2463-2487):子命令是选项系统的一个特性。

**Q7:git commit -h 在仓库外为什么能跑?**
-h 触发 RUN_SETUP 降级 GENTLY(:478-481)。

**Q8:149 条命令的查表为什么不建哈希?**
一次性进程内 149 次 strcmp 成本可忽略(:691-699)——数据规模决定优化必要性。

**Q9:恶意 .git 目录能骗过我吗?**
dubious ownership 检查(:1677-1682,CVE-2022-24765 防线):属主不符即拒。

**Q10:builtin 和 dashed 命令的性能差多少?**
同进程省 fork+exec;这也是历史上 shell 脚本命令逐步 builtin 化的动因。

## 11.7 小结与全卷终

本章结论:**builtin 架构 = "声明式分发表 + 内置语义的选项系统 + 回调式分层 config + 带安全检查的仓库发现"**——新命令的全部成本是"写业务+选标志位"。

至此《Git 深读》两卷完:卷一(01-07:对象/引用/索引/pack/传输/合并/文化)+ 卷二(08-11:性能基建/fsck 抢救/submodule-worktree/builtin 架构),共 11 章+11 份调研报告,全部结论钉在 commit 47ce805。深挖方向:

1. commands[] 线性查表(:691)在 CLI 补全工具(git-completion)中的镜像实现;
2. config 回调链(:419-451)与 includeIf onbranch: 的组合陷阱;
3. setup 的 chdir+prefix(:1957-1961)对相对路径工具(如 worktree 内嵌仓库)的影响;
4. parse-options 的 PARSE_OPT_HIDDEN 选项(隐藏后门)盘点;
5. dashed external(:793)与第三方子命令(git-lfs)的命名空间治理。

— 《Git 深读》两卷完结。AI 编码助手:GLM-5.3-Flash。
