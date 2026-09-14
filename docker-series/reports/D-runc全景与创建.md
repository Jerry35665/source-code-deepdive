# D - runc 全景与容器创建

> 依据 opencontainers/runc shallow clone commit `579be22`（VERSION 为 `1.5.0-rc.1+dev`）源码逐行核对。
> 行号均为仓库相对路径。注意：本版本中 `Container` 已是一个 struct（旧版本的 `Container` 接口 + `linuxContainer` 实现的拆分已合并），见 libcontainer/container_linux.go:33。

---

## 1. 全景：`runc create` + `runc start` 的完整旅程

runc 是 OCI runtime 参考实现。它处理一个 "bundle"（`config.json` + `rootfs/`），生命周期命令与 OCI runtime-spec 的 state 流转严格对应：`creating → created → running → stopped`。

```
 runc create <id>                              runc start <id>
 ================                              ================
 main() (main.go:88)
   └─ createCommand.Action (create.go:63)
       └─ startContainer(CT_ACT_CREATE)        startCommand.Action (start.go:24)
          (utils_linux.go:381,400)               └─ Load(root,id) (utils_linux.go:38 → factory_linux.go:108)
          └─ setupSpec: 读 config.json              └─ 读 state.json 重建 Container
             (utils.go:72 → spec.go:121)            └─ 状态==Created → container.Exec()
       └─ specconv.CreateLibcontainerConfig         (start.go:42 → container_linux.go:227)
          (utils_linux.go:189 → spec_linux.go:384)      │
       └─ libcontainer.Create                            │ 写 1 字节到
          (utils_linux.go:203 → factory_linux.go:35)     │ <root>/<id>/exec.fifo
             └─ 建状态目录 /run/runc/<id>/                ▼
   └─ runner.run (utils_linux.go:223)          runc init 侧(阻塞等待 fifo):
       └─ newProcess: spec.Process→Process        standard_init_linux.go:264 reopen fifo
          (utils_linux.go:50)                     :269 write("0") 后立刻 execve 用户进程
       └─ container.Start(process)
          (utils_linux.go:290 → container_linux.go:205→364 start)
             └─ createExecFifo: exec.fifo (container_linux.go:379→492)
             └─ newParentProcess (container_linux.go:541)
                 ├─ exeseal: 克隆 /proc/self/exe (557-573, 防 CVE-2019-5736)
                 ├─ exec.Command(exe, "init") (575)   ← 自我重执行!
                 └─ 环境变量指路: _LIBCONTAINER_{INITPIPE,SYNCPIPE,LOGPIPE,...}
             └─ initProcess.start (process_linux.go:778)
                 ├─ cmd.Start()  ── clone/fork+exec "runc init" ──┐
                 ├─ cgroupManager.Apply(pid) (826)                │
                 ├─ netlink bootstrap → INITPIPE (848)            │ nsexec.c
                 ├─ 收 {stage1_pid,stage2_pid} (852→637)          │ 3 stage
                 ├─ initConfig JSON → INITPIPE (904)              │ 进 namespace
                 ├─ sync: procReady→写rlimits→存state.json        │
                 │   →procRun (983-1015)                          │
                 │   (状态=created, state.json 落盘)               ▼
                 └─ [runc create 到此返回, detach]           Go 侧 init_linux.go
                                                             ├─ 读 JSON config (233)
                                                             ├─ prepareRootfs/mounts
                                                             │   (standard_init_linux.go:91
                                                             │    → rootfs_linux.go:170)
                                                             ├─ procHooks→procReady→procRun
                                                             └─ 等 fifo → execve
```

**两阶段设计的意义**：OCI 把 "create" 与 "start" 分开，是为了给上层（containerd/conmana/K8s）一个窗口——在用户进程真正 execve 之前完成 tty 接管、`pidfd` 登记、sd_notify（NOTIFY_SOCKET）准备等。`runc create` 返回时容器处于 `created` 状态：init 进程已存在、namespace/cgroup/rootfs 全部就绪，只是卡在 exec.fifo 上等待放行（`refreshState` 正是靠 exec.fifo 是否存在来区分 created/running，libcontainer/container_linux.go:930-934）。`runc start` 只是往 fifo 写一个字节。单命令 `runc run` 则是 create+start 的合体：`CT_ACT_RUN` 路径下 `Run()` 在 `start()` 后立即调用 `c.exec()`（container_linux.go:214-224）。

另一个关键点：`runc create` 天然是 detach 的——`detach := r.detach || (r.action == CT_ACT_CREATE)`（utils_linux.go:224），create 的父进程随即退出，容器 init 被内核重新收养（reparent），这就是为什么 state.json 必须落盘、为什么 `runc start` 能从磁盘重建 Container 对象。

**`runc create` 全程时间线**（编号即严格的先后顺序）：

| # | 阶段 | 位置 | 说明 |
|---|---|---|---|
| 1 | chdir bundle + 读 config.json | utils.go:73-83 | process 部分先过 validateProcessSpec |
| 2 | spec → configs.Config | spec_linux.go:384 | 纯翻译，无内核副作用 |
| 3 | 建状态目录 + cgroup 预检 | factory_linux.go:45-93 | `<root>/<id>/` 0711；cgroup 空且未冻结 |
| 4 | runner.run：组 Process、IO、listenFDs | utils_linux.go:223-286 | create 必为 detach |
| 5 | mkfifo exec.fifo | container_linux.go:379→492 | created 状态的物证 |
| 6 | 克隆 exe、组装 cmd | container_linux.go:541-668 | fd3+=init/sync/log pipe，env 指路 |
| 7 | `cmd.Start()` → nsexec 三级跳 | process_linux.go:780；nsexec.c:847 | clone/unshare/setns 全在此 |
| 8 | 父进程 Apply cgroup | process_linux.go:826 | 先于子进程一切动作 |
| 9 | 发 netlink bootstrap、收双 pid | process_linux.go:848-855 | stage-0 → 父 |
| 10 | 发 initConfig JSON；收 procHooks/procReady | process_linux.go:904-909 | 子进程做 mounts/pivot 等 |
| 11 | procReady：rlimits→**state.json**→procRun | process_linux.go:983-1015 | 状态置 created |
| 12 | create 返回（容器停在 fifo 前） | create.go:67-74 | init 已是 `runc:[2:INIT]` |

**`runc start` 全程只有三步**：Load（state.json）→ 校验状态为 Created → `container.Exec()` 写 fifo；随后 init 侧 reopen fifo 写 "0"、close pipes、execve 用户进程（standard_init_linux.go:250-303），start 的 handleFifo poll 返回后跑 poststart 钩子并删除 fifo（container_linux.go:247-266、341-362）。

---

## 2. 命令分派：main → create.go → factory

runc 用 urfave/cli v3 做命令分派。`main()` 在 main.go:88 构造 `cli.Command`，17 个子命令注册在 `app.Commands`（main.go:136-154）。两个全局决定：

- **状态根目录**：`root = "/run/runc"`（main.go:98）；若设置了 `XDG_RUNTIME_DIR` 且 `shouldHonorXDGRuntimeDir()` 为真则改用 `$XDG_RUNTIME_DIR/runc`（main.go:100-104；判定逻辑在 rootless_linux.go:55，非 root 或 user namespace 内的 root 才启用 XDG）。XDG 场景下目录以 `0700|sticky` 创建（main.go:160-167）——tmpfs 上的 sticky 目录防止低权限用户篡改他人状态。
- **bundle 定位**：`specConfig = "config.json"`（main.go:62）；`--bundle` 落为一次 `os.Chdir`（utils.go:73-78），之后一切相对路径都以 bundle 为基准。

`runc create <id>` 的调用链（每一步都可直接核对）：

1. create.go:63 `Action` → create.go:67 `startContainer(cmd, CT_ACT_CREATE, nil)`。
2. utils_linux.go:381 `startContainer`：revisePidFile（utils.go:86，先转绝对路径再 chdir）→ utils.go:72 `setupSpec` → spec.go:121 `loadSpec`（JSON 解码 + `validateProcessSpec` 校验 Cwd/Args/Selinux）→ utils_linux.go:400 `createContainer`。
3. utils_linux.go:184 `createContainer`：specconv.CreateLibcontainerConfig（189 行，OCI spec → 内核配置）→ factory_linux.go:35 `libcontainer.Create(root, id, config)`（203 行）。
4. utils_linux.go:416-431 组装 `runner{init:true, action:...}` 并 `r.run(spec.Process)`。
5. utils_linux.go:223 `runner.run`：按 action 分派到 `r.container.Start(process)`（CT_ACT_CREATE，289-290 行）或 `Run`（CT_ACT_RUN，293-294 行）。

**factory 的角色**：`Create`/`Load` 就是本版的 factory 函数（factory_linux.go:35 与 108）。`Create` 做 4件事：校验 id 字符集 `[A-Za-z0-9_+-.]`（factory_linux.go:192-219 `validateID`）、`validate.Validate(config)`、建状态目录 `<root>/<id>/`（先 SecureJoin 防路径逃逸，factory_linux.go:48；再 `os.Mkdir 0711`，factory_linux.go:91）、构造 cgroup manager 并确认 cgroup 不存在或为空、未冻结（factory_linux.go:69-88，防复用残留 cgroup）。`Load`（`runc start/kill/delete/state/exec` 共用的入口是 utils_linux.go:32 `getContainer`）则反其道：读 `state.json`（factory_linux.go:150 `loadState`），重建 Container 与 cgroupManager，再 `refreshState()` 用运行时事实（进程存活、freezer 状态、fifo 是否在）修正状态（container_linux.go:919-936）。

## 3. init 重执行：/proc/self/exe + nsexec 的 C 阶段

runc 没有 init 二进制；它重执行自己。`newParentProcess` 中：

```go
// libcontainer/container_linux.go:566-582
safeExe, err = exeseal.CloneSelfExe(c.stateDir)
...
exePath = "/proc/self/fd/" + strconv.Itoa(int(safeExe.Fd()))
...
cmd := exec.Command(exePath, "init")
cmd.Args[0] = os.Args[0]
```

- **为什么要重执行**：namespace/unshare 语义要求"调用者之后创建的进程"才进入新环境；Go 运行时多线程又使得在父进程内直接 setns/unshare 不可靠。于是 runc fork 出子进程再重执行 `/proc/self/exe init`，子进程从零开始，在 Go runtime 启动前由 C 构造函数完成 namespace 操纵。
- **为什么要克隆 exe**：`CloneSelfExe`（libcontainer/exeseal/cloned_binary_linux.go:218）优先用只读 overlayfs 封印 `/proc/self/exe`，失败则拷贝进 memfd 并加 seal——防 CVE-2019-5736（容器内进程替换 runc 二进制实现逃逸）。注释见 container_linux.go:547-551。
- **Go 侧入口钩子**：仓库根 init.go:10-16 的包级 `init()` 检查 `os.Args[1] == "init"` 则调用 `libcontainer.Init()`；而更早的 C 阶段由 nsenter 包注册：nsenter/nsenter.go:13 `void __attribute__((constructor)) init(void) { nsexec(); }`——GCC 的 constructor 在 Go runtime 引导之前运行。

**nsexec 三级跳**（libcontainer/nsenter/nsexec.c）：

- 入口 nsexec()（nsexec.c:725）：从环境变量取 `_LIBCONTAINER_INITPIPE`（743），没有就说明不是 `runc init`，直接返回让 Go 接管（744-747）；否则 `nl_parse`（761）解析父进程通过 init pipe 发来的 **netlink 格式** bootstrap 数据，写 oom_score_adj（769），置 `PR_SET_DUMPABLE,0`（783）。
- **stage 0（STAGE_PARENT，nsexec.c:855）**：`clone_parent(&env, STAGE_CHILD)` 产出 stage-1（867）；随后是同步循环：响应 SYNC_USERMAP_PLS 为 stage-1 写 `/proc/<pid>/uid_map|gid_map|setgroups`（904-908）、收 stage-2 pid 并用 `dprintf(pipenum, "{\"stage1_pid\":%d,\"stage2_pid\":%d}\n", ...)`（937）回报给父进程 runc、代写 timens offsets（946）。stage-0 之所以要当"中间人"，是因为先 unshare userns 会丢光旧 namespace 的 capabilities（nsexec.c:814-820 的长注释），uid/gid map 必须由仍在旧 userns 的进程写。
- **stage 1（STAGE_CHILD，nsexec.c:1010）**：进程名 `runc:[1:CHILD]`（1023）。先 setns 加入要复用的 namespace（1032-1033 `join_namespaces`），再 `try_unshare(CLONE_NEWUSER)`（1054-1055，userns 最先 unshare，因为它是特权判定上下文，且必须分步 unshare 避免 mqueue/SELinux 标签错乱，1036-1053 注释）、请求 stage-0 写映射后 `setresuid(0,0,0)` 变成新 userns 的 root（1093），然后一次性 `try_unshare(config.cloneflags, "remaining namespaces")`（1107）创建其余 namespace。最后因 PID namespace 只对"子进程"生效（setns/unshare 不能改变自身 PID ns 的视角，1122-1130 注释），再次 `clone_parent(&env, STAGE_INIT)`（1132）产生 stage-2 并上报其 pid。
- **stage 2（STAGE_INIT，nsexec.c:1169）**：进程名 `runc:[2:INIT]`（1188）。收 SYNC_GRANDCHILD 后 `setsid()/setuid(0)/setgid(0)`（1195-1202），SYNC_CHILD_FINISH 告知 stage-0，然后 `return`（1223）——**唯一返回 Go runtime 的分支**，交给 init_linux.go。

`join_namespaces` 的次序论证（nsexec.c:646-654）：先 join 所有非 user namespace（趁还有旧凭据时能 join 的都 join），再 join userns 并切 root（571-577），最后再试剩余（rootless 场景下要拿到新 userns 的 CAP_SYS_ADMIN 才有权限 join 的那批）。三次调用分别为 nsexec.c:651-653。

bootstrap 数据格式：父进程 `bootstrapData`（container_linux.go:1088）把 cloneFlags（1106）、namespace 路径（1117）、uid/gid map（1139/1156）、oom_score_adj（1176）、rootless 标志（1185）、timens offsets（1197）编码为自定义 netlink 消息；这就是 nsexec.c 里 `nl_parse` 的对端。

## 4. init 子进程：JSON 传递与 final exec 前的准备

**fd 3 号通道的约定**：`stdioFdCount = 3`（container_linux.go:30），ExtraFiles 从 fd 3 起编号。父进程给 `runc init` 挂的通道（container_linux.go:599-620）：

| 环境变量 | 通道 | 用途 |
|---|---|---|
| `_LIBCONTAINER_INITPIPE` | socketpair | 传 netlink bootstrap（C 阶段读）+ initConfig JSON（Go 阶段读） |
| `_LIBCONTAINER_SYNCPIPE` | socketpair(SCM_RIGHTS) | JSON 同步消息 procError/procReady/procRun/procHooks/procSeccomp… |
| `_LIBCONTAINER_LOGPIPE` | os.Pipe | 子进程 logrus JSON 日志回传，父进程 ForwardLogs（libcontainer/logs/logs.go:17） |
| `_LIBCONTAINER_FIFOFD` | O_PATH fd → exec.fifo | 仅 standard init，start 的"发令枪" |
| `_LIBCONTAINER_CONSOLE` / `_LIBCONTAINER_PIDFD_SOCK` | unix socket | master pty 回传 / pidfd 外发 |
| `_LIBCONTAINER_INITTYPE` | 值 `standard`/`setns` | init_linux.go:33-36，决定走创建容器还是 runc exec 的 setns 路径 |

配置不是命令行参数而是 **JSON over init pipe**：init 子进程 Go 侧 `startInitialization`（init_linux.go:128）解析上述环境变量（130-216）、`os.Clearenv()`（220）、然后 `json.NewDecoder(initPipe).Decode(&config)`（233）拿到整个 `initConfig`——其中嵌着完整 `configs.Config`（init_linux.go:64-65）。任何失败的错误都会以 `procError` 同步消息回传（init_linux.go:145-149）。

`containerInit`（init_linux.go:241-269）按 INITTYPE 分派到 `linuxStandardInit`（standard_init_linux.go:51 `Init()`）或 `linuxSetnsInit`（setns_init_linux.go:35，`runc exec` 用，无 rootfs/mount 逻辑）。standard 路径的 final exec 前准备，顺序即安全顺序：

1. session keyring 隔离（standard_init_linux.go:52-79，防父进程 keyring 泄漏）；
2. `prepareRootfs`（91 行 → rootfs_linux.go:170）：挂 root、逐个 `setupAndMountToRootfs`（193）、`syncParentHooks`（210，触发父进程跑 prestart/createRuntime 钩子）、CreateContainer 钩子（229）、`pivotRoot`/`msMoveRoot`/`chroot` 三选一（234-240）；
3. console（99-106，alloc pty 并把 master 经 console socket 用 SCM_RIGHTS 送出，init_linux.go:375-417）、pidfd（108-112）、`finalizeRootfs` 重挂只读（115-119 → rootfs_linux.go:277）；
4. hostname/domainname（121-130）、**apparmor**（131 `apparmor.ApplyProfile`）、**sysctl**（135 `sys.WriteSysctls`）、readonlyPaths（138）、maskPaths（144，bind /dev/null 覆盖敏感文件）、NoNewPrivileges（152-156）、scheduler/iopriority/personality/memory-policy（158-175）；
5. `syncParentReady`（180 → init_linux.go:422）：**父进程此刻设置 rlimits（因为进 userns 后就再无权限抬 limit，process_linux.go:985-989）、写 state.json、回 procRun**；
6. selinux exec label（183-187）、seccomp（191-200 无 NNP 时先装，配合 syncParentSeccomp 把 notify fd 交父进程转发给 listener，init_linux.go:445）；`finalizeNamespace`（201 → init_linux.go:300）：CloseExecFrom（304）、chdir 两段式（314 先试、353 setupUser 后再试）、**capabilities：先 ApplyBoundingSet（341）→ setuser（348，含 fixStdioPermissions 与 setgroups/setgid/setuid，init_linux.go:468-513）→ verifyCwd 防 CVE-2024-21626 逃逸（358 → init_linux.go:273-295）→ ApplyCaps（364）**；
7. ppid 校验防收养（224-226）、`exec.LookPath`（229，提前把"命令不存在"作为 create 期错误回传）、NNP 时 seccomp 尽量晚装（239-248）、关 sync pipe（252）与 log pipe（256）、**写 exec.fifo 一个字节 "0"**（264-271，与 `runc start` 握手）、StartContainer 钩子（282-288）、`UnsafeCloseFrom` 清除一切多余 fd（300，CVE-2024-21626 加固）、最终 `linux.Exec(name, args, env)`（303）——init 进程的躯壳换成用户进程。

## 5. 状态同步：init pipe、sync 消息与 state.json

**同步协议**定义在 libcontainer/sync.go:42-50：`procError/procReady/procRun/procHooks/procHooksDone/procMountPlease/procSeccomp/procSeccompDone`，消息体 `syncT{Type,Flags,Arg,File}`（sync.go:59-64，File 走 SCM_RIGHTS）。父进程视角的完整握手在 `initProcess.start`（process_linux.go:778）：

```
 runc(create 父进程)                          runc init(stage-2, Go 侧)
 -------------------                          --------------------------
 cmd.Start() ──────────────────────────────► nsexec[0→1→2] 完成, 返回 Go
 manager.Apply(pid)                            startInitialization()
 io.Copy(initPipe, netlink bootstrap) ──────► (C 阶段 nl_parse 已消费 netlink)
 getChildPid() ◄── {"stage1_pid","stage2_pid"} ──── (来自 stage-0, 走 INITPIPE)
 waitForChildExit(stage-1)
 WriteJSON(initPipe, initConfig) ───────────► json.Decode(initPipe) (init_linux.go:233)
                                               ...mounts/pivot/console...
                                               ◄── procHooks ──  (rootfs_linux.go:210)
 manager.Set + prestart/createRuntime 钩子
 ── procHooksDone ──────────────────────────►
                                               ...hostname/apparmor/sysctl...
                                               ◄── procReady ── (standard_init_linux.go:180)
 setupRlimits(pid) (子进程已无权)
 updateState → state.json 落盘
 ── procRun ────────────────────────────────► selinux/seccomp/finalizeNamespace
 (关闭 sync 写端 SHUT_WR, 1053)                reopen exec.fifo, write "0"
 [create 返回; 容器停在 execve 前]             execve(用户进程)   (303)
```

- cmd.Start() 后立即 `manager.Apply(pid)` 把 init 挪进 cgroup（826，先于一切，防止子进程逃出 cgroup，823-825 注释）；
- 发 netlink bootstrap（848）、收 `{stage2_pid, stage1_pid}` JSON（852 → 637 `getChildPid`；struct 定义 init_linux.go:40-43）、`waitForChildExit` 等 stage-1 退出（867 → 654）；
- 起挂载源服务 goroutine 响应 `procMountPlease`（877-885 + 911-939；非 rootless 才有，因为需要宿主权限 open_tree）；
- `utils.WriteJSON(initSockParent, p.config)`（904）——**initConfig 经同一条 init pipe 的第二次投递**（第一次是 netlink）；
- `parseSync` 主循环（909）：`procSeccomp`（940，pidGetFd 拿子进程 notify fd 转发 seccomp listener）、`procReady`（983：`setupRlimits` 987 → 记录 `created` 时间戳 992 → 置 `createdState` 993 → **`updateState` 落盘 state.json** 1006 → 回 `procRun` 1013）、`procHooks`（1016：先 `manager.Set` 应用 cgroup 资源限制 1018，再跑 Prestart/CreateRuntime 钩子 1036-1041，回 procHooksDone 1044）。procReady 处理块原文：

```go
// libcontainer/process_linux.go:983-1015（节选）
case procReady:
	seenProcReady = true
	// Set rlimits, this has to be done here because we lose permissions
	// to raise the limits once we enter a user-namespace
	if err := setupRlimits(p.config.Rlimits, p.pid()); err != nil { ... }
	// generate a timestamp indicating when the container was started
	p.container.created = time.Now().UTC()
	p.container.state = &createdState{c: p.container}
	...
	state, uerr := p.container.updateState(p)   // ← state.json 在此落盘
	if uerr != nil { return fmt.Errorf("unable to store init state: %w", uerr) }
	p.container.initProcessStartTime = state.InitProcessStartTime
	// Sync with child.
	if err := writeSync(p.comm.syncSockParent, procRun); err != nil { return err }
```

**state.json**：由 `saveState`（container_linux.go:882-906）以"临时文件 + rename"原子写入 `<root>/<id>/state.json`；结构 `State`（container_linux.go:49-80）= `BaseState`（container.go:44-57：ID、InitProcessPid、InitProcessStartTime、Created 时间戳、完整 Config 副本）+ CgroupPaths + NamespacePaths + ExternalDescriptors + IntelRdt 路径。写入时机正是 procReady 处理中、procRun 之前（process_linux.go:997-1005 的注释解释了为什么必须赶在 procRun 前写：若 runc create 在这之后被 kill，`runc delete` 将因没有 state.json 无法清理泄漏的 runc init stage-2）。

**exec.fifo 的二次握手**：create 阶段 `createExecFifo` mkfifo 0622 并 chown 给容器 root（container_linux.go:492-516）；init 进程持有其 O_PATH fd，在 final exec 前 reopen+write（standard_init_linux.go:264-271）；`runc start` 侧 `Container.Exec()` → `c.exec()`（container_linux.go:233-240）→ `handleFifo`（247-266）：内核 ≥5.3 时对 fifo+pidfd 做**一次 poll** 同时等" fifo 有数据"或"init 死亡"（271-303），读到字节后删除 fifo（262）并跑 poststart 钩子（341-362）。`refreshState` 用 fifo 的存在性判定 created（container_linux.go:930-934），因此 created→running 的状态跃迁完全由这个文件驱动。

**错误回传**：init 任何阶段失败，以 `procError{Message}` 写回 sync pipe（init_linux.go:138-152 的 defer），父进程 parseSync 报 "error during container init: ..."（process_linux.go:1059-1060）；启动失败还有 OOM 归因逻辑（process_linux.go:789-821）。`runc delete`（delete.go:50-91）：Stopped → `Destroy()`（删 cgroup + stateDir，state_linux.go:39-67）；Created → killContainer（SIGKILL 轮询后 Destroy，delete.go:17-26）。

## 6. 与 OCI runtime-spec 的对照：config.json → 内核操作

转换总入口 `specconv.CreateLibcontainerConfig`（libcontainer/specconv/spec_linux.go:384）。spec.Process 单独走 utils_linux.go:50 `newProcess`，两者在 `newInitConfig`（container_linux.go:725-786）合流（process 属性优先）。

| config.json 字段 | specconv/libcontainer 去处 | 内核操作（发生在哪个进程） |
|---|---|---|
| `linux.namespaces` | namespaceMapping 表（spec_linux.go:51-61）→ `config.Namespaces`（449-458） | CloneFlags（configs/namespaces_syscall.go:24）进 netlink bootstrap → nsexec stage-1 unshare；带 Path 的进 stage-1 join_namespaces setns |
| `linux.namespaces[type=user].uidMappings/gidMappings` | setupUserNamespace（spec_linux.go:1080）→ UIDMappings | stage-0 写 /proc/<stage1>/uid_map（nsexec.c:907） |
| `mounts[]` | createLibcontainerMount（spec_linux.go:641）→ config.Mounts | init 子进程 prepareRootfs 内逐个挂（rootfs_linux.go:192-196）；父进程可为子进程代开挂载源（procMountPlease） |
| `root.readonly` | config.Readonlyfs（spec_linux.go:407） | finalizeRootfs 重挂 ro（rootfs_linux.go:277-289） |
| `root.path` | config.Rootfs（spec_linux.go:396-399） | pivotRoot（rootfs_linux.go:237→1147）/ msMoveRoot / chroot |
| `process.capabilities` | config.Capabilities（spec_linux.go:597-605） | init 子进程 finalizeNamespace：ApplyBoundingSet→ApplyCaps（init_linux.go:341/364） |
| `process.rlimits` | newProcess → lp.Rlimits（utils_linux.go:83-89） | **父进程**在 procReady 时 setupRlimits（process_linux.go:987 → init_linux.go:615）——进 userns 后就没权限了 |
| `process.noNewPrivileges` | config.NoNewPrivileges（spec_linux.go:594） | prctl(PR_SET_NO_NEW_PRIVS)（standard_init_linux.go:152-156）；并决定 seccomp 早装还是晚装 |
| `linux.seccomp` | SetupSeccomp（spec_linux.go:489-495→1195） | seccomp.InitSeccomp，notify fd 经 procSeccomp 同步交父进程转发 listener（standard_init_linux.go:191-200/239-248） |
| `linux.sysctl` | config.Sysctl（spec_linux.go:487） | init 子进程 WriteSysctls（standard_init_linux.go:135） |
| `linux.maskedPaths/readonlyPaths` | config.MaskPaths/ReadonlyPaths（spec_linux.go:484-485） | init 子进程 maskPaths/readonlyPath（standard_init_linux.go:138-146） |
| `linux.apparmorProfile`/`process.selinuxLabel` | config.AppArmorProfile/ProcessLabel | ApplyProfile（standard_init_linux.go:131）/ SetExecLabel（183-187） |
| `process.oomScoreAdj` | config.OomScoreAdj（spec_linux.go:593）→ netlink OomScoreAdjAttr（container_linux.go:1176-1182） | **C 阶段** nsexec 写（nsexec.c:769，必须在 !dumpable 之前） |
| `hostname/domainname` | config.Hostname/Domainname（spec_linux.go:408-409） | init 子进程 sethostname/setdomainname（standard_init_linux.go:121-130） |
| `hooks`（prestart/createRuntime/createContainer/startContainer/poststart/poststop） | createHooks（spec_linux.go:1286→621） | 分布在：父进程 procHooks（prestart/createRuntime，process_linux.go:1036-1041）、init 子进程 createContainer（rootfs_linux.go:229）与 startContainer（standard_init_linux.go:285）、父进程 poststart（container_linux.go:341-362）/poststop（state_linux.go:69-82） |
| `process.cwd` | initConfig.Cwd | 两段式 chdir + verifyCwd（init_linux.go:309-358） |
| `linux.personality/memoryPolicy/intelRdt/timeOffsets` | spec_linux.go:496-538 等 | 各自的 setup*/netlink 属性 |

cgroups（`linux.resources`）→ `CreateCgroupConfig`（spec_linux.go:778）→ cgroup manager；Apply/Set/Destroy 的时机见第 5 节。cgroup 细节留待 F 报告。

## 7. 设计动机

- **为什么 create/start 分离**：给 supervisor 一个"进程已就绪但未 exec"的稳定锚点。containerd 在这个窗口完成 console 接管（--console-socket）、pidfd 登记（--pidfd-socket，utils_linux.go:434-459 要求内核 ≥5.3）、sd_notify 桥接（start.go:38 notifySocketStart）。同时 created 状态使 shims 可以"先建后启"解耦编排逻辑。代价是必须把全部状态落盘（state.json + exec.fifo），因为 create 的 runc 进程会退出，后续命令全靠 `Load` 从磁盘重建对象（factory_linux.go:108-148）。
- **为什么 init 的 namespace 逻辑用 C 写**：Go runtime 启动即多线程，而 setns(CLONE_NEWPID)/unshare(CLONE_NEWUSER) 与多线程程序的兼容性糟糕（runc 只对单线程进程保证安全，见 nsenter.go:3-8 的包注释）；且 uid_map 的写入者必须在旧 userns 保有 CAP_SYS_ADMIN，时序苛刻。C constructor 保证这些操作发生在 Go runtime 引导**之前**，用 setjmp/longjmp + 两次 clone_parent 完成三级跳（nsexec.c:847 起）。同样的理由解释了为什么 oom_score_adj 也在 C 阶段写。
- **为什么 JSON 走 fd 而不走命令行/环境变量**：initConfig 里嵌整个 configs.Config（含 mounts、caps、seccomp…），环境变量有大小和转义限制，且 `os.Clearenv()`（init_linux.go:220）要清空环境防泄漏；socketpair 天然双向，还能借 SCM_RIGHTS 捎带 fd（exec.fifo、console、seccomp notify）。
- **为什么状态目录在 /run（tmpfs）**：容器状态是运行时事实而非持久数据——重启即失效，放 tmpfs 天然自动清理；/run 归 root，目录 0700+sticky（main.go:160-167）防跨用户篡改；state.json 里存有 NamespacePaths 等可被利用的宿主路径，不能放全局可读处。rootless 则退到 XDG_RUNTIME_DIR。
- **为什么 exec.fifo 而不是信号/管道**：fifo 文件本身就是状态——`refreshState` 靠它区分 created/running（container_linux.go:932）；O_PATH 打开 + /proc 重开的姿势（container_linux.go:527-539、standard_init_linux.go:264）让容器进程拿不到 stateDir 的 dirfd，这是 CVE-2016-9962/CVE-2024-21626 一脉的加固。

## 8. FAQ 素材

1. `runc create` 返回后容器里是什么进程？——是名为 `runc:[2:INIT]` 的 runc 自己（已进入全部 namespace、完成 rootfs/caps 准备），阻塞在 exec.fifo 上，还没 exec 用户程序。
2. `runc run` 和 `create+start` 的差别？——Run() 在 start() 后立即 c.exec() 写 fifo（container_linux.go:214-224）；且 run 非 detach 时父进程留在前台转发信号（utils_linux.go:324-326）。
3. `runc start` 如何找到容器？——`getContainer`（utils_linux.go:32-39）→ `Load(root,id)` 读 state.json；所以 `--root` 必须与 create 时一致。
4. `runc init` 是独立二进制吗？——不是，是 runc 自我重执行（exec.Command(exePath,"init")，container_linux.go:575）；`ps` 里看到的 `runc:[0:PARENT]/[1:CHILD]/[2:INIT]` 是 prctl(PR_SET_NAME) 起的调试名（nsexec.c:1023/1188）。
5. 为什么 `runc create` 后 state.json 才出现、失败时没有？——saveState 只发生在 procReady 之后（process_linux.go:1006）；中途失败 runc 会 SIGKILL init 并 Destroy cgroup（process_linux.go:789-819）。
6. created 与 running 如何判定？——运行时用 exec.fifo 存在性（container_linux.go:930-934），加载时用 refreshState 结合 init 进程存活（/proc/pid/stat starttime 比对，container_linux.go:939-952，防 PID 复用）。
7. exec.fifo 里写的什么？——一个字节 "0"（standard_init_linux.go:269）；父进程只检查"读到非空"（container_linux.go:329-339）。
8. 杀不掉容器会泄漏进程吗？——没有私有 PID ns 时，SIGKILL 走 signalAllProcesses 按 cgroup 清扫（container_linux.go:452-468）；Destroy 也会再补一刀（state_linux.go:48-51）。
9. `runc delete` 对没有 state.json 的残目录怎么办？——直接 RemoveAll `<root>/<id>`（delete.go:59-69）。
10. 为什么要 `--preserve-fds`？——把调用方额外 fd 原样传给容器 init（utils_linux.go:254-260），配合 LISTEN_FDS 实现 socket 激活；runc 会在启动前把非 stdio 的 fd 全部 O_CLOEXEC（container_linux.go:402）。

## 9. 深挖方向

1. **exeseal**：libcontainer/exeseal/cloned_binary_linux.go——overlayfs 封印 /proc/self/exe（218）与 memfd+seal 回退，CVE-2019-5736 的现代解法；Go stdlib fd shuffle bug 的规避（container_linux.go:622-646，golang/go#61751、runc#4294）。
2. **挂载源服务**：process_linux.go:682 `goCreateMountSources`——init 子进程无权 open 源挂载点时通过 procMountPlease/procMountFd 让父进程代劳（open_tree/file 域），新内核挂载 API 与 idmapped mount 的衔接（另见 F 报告）。
3. **同步协议与 cmsg**：libcontainer/sync.go 全文 + newSyncSockpair；procSeccomp 用 pidfd_getfd 取 notify fd（process_linux.go:951、1106 pidGetFd），以及 init 子进程侧"尽量少 syscall 防 SCMP_ACT_NOTIFY 死锁"的设计（init_linux.go:445-465 注释）。
4. **状态机**：libcontainer/state_linux.go 的 containerState 五态（stopped/created/running/paused/restored/loaded）与非法跃迁报错（stateTransitionError，state_linux.go:24-31）。
5. **runc exec 的 setns 路径**：newSetnsProcess（container_linux.go:699-723）用 `bootstrapData(0, state.NamespacePaths)`、setns_init_linux.go 的精简 Init；exec 也有自己的 console/pidfd/seccomp 处理，且不走 fifo。

## 10. 写作要点速查表

| # | 关键函数/事实 | 位置（仓库相对:行号） |
|---|---|---|
| 1 | 全局 root 默认 /run/runc；17 个子命令注册 | main.go:98；main.go:136-154 |
| 2 | createCommand → startContainer(CT_ACT_CREATE) | create.go:63-74 |
| 3 | start：Load → Created 才可 → container.Exec() | start.go:28-48 |
| 4 | setupSpec/loadSpec 读 bundle 的 config.json | utils.go:72-84；spec.go:121-138 |
| 5 | createContainer：specconv→libcontainer.Create | utils_linux.go:184-204 |
| 6 | Create：validateID + Mkdir 0711 + cgroup 预检 | factory_linux.go:35-103；validateID:192 |
| 7 | Load/loadState 读 state.json 重建 Container | factory_linux.go:108-148；loadState:150 |
| 8 | Start/Run/Exec 与 exec()=handleFifo+postStart | container_linux.go:205/214/227/233 |
| 9 | start()：createExecFifo→newParentProcess→CloseExecFrom→parent.start | container_linux.go:364-431 |
| 10 | newParentProcess：exeseal 克隆 exe、exec "init"、_LIBCONTAINER_* 指路 | container_linux.go:541-668 |
| 11 | newInitProcess/newSetnsProcess + bootstrapData(netlink) | container_linux.go:670/699/1088 |
| 12 | initProcess.start：Apply cgroup→发 bootstrap→收 pid→发 JSON→同步循环 | process_linux.go:778-1063 |
| 13 | procReady：rlimits→created 时间戳→state.json 落盘→procRun | process_linux.go:983-1015（updateState:871，saveState:882） |
| 14 | State/BaseState 字段（NamespacePaths 等） | container_linux.go:33-80；container.go:44-57 |
| 15 | nsexec C constructor 与三级跳 | nsenter/nsenter.go:13；nsexec.c:725/855/1010/1169 |
| 16 | userns 先 unshare、uid_map 由 stage-0 代写、PID ns 需再 fork | nsexec.c:1054/907/1132（论证 800-845） |
| 17 | join_namespaces 三段次序 | nsexec.c:646-654 |
| 18 | Go 侧 Init：环境变量→Clearenv→JSON decode→containerInit | init.go:10-16；init_linux.go:128-269 |
| 19 | standard Init 全序（rootfs→钩子→ready→caps→seccomp→fifo→exec） | standard_init_linux.go:51-304；final exec:303 |
| 20 | finalizeNamespace：caps/setuser/verifyCwd 次序 | init_linux.go:300-368（setupUser:468） |

---

*报告完。所有行号基于 commit 579be22（1.5.0-rc.1+dev），如后续 rebase 请重新核对。*
