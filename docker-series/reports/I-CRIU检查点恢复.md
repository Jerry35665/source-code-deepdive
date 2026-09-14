# I - CRIU 检查点/恢复：容器的"冻结快照与迁移"

> 调研对象：runc @ commit 579be22（VERSION 为 1.5.0-rc.1+dev）。所有行号以该 commit 为准，均经 grep -n / Read 实际核对。
> containerd 侧引用其主仓 commit f6132db，仅作对接简查。

---

## 1. 全景：checkpoint/restore 的字节流

runc 自己不实现"快照"，它是 CRIU 的编排者：把 OCI 配置翻译成 CRIU RPC 参数，启动一个 CRIU 子进程，通过 socketpair 上的 protobuf 与之对话。

```text
 源主机                                    CRIU images (一个目录)                     目标主机
┌─────────────────────────────┐          ┌──────────────────────────┐          ┌─────────────────────────────┐
│ runc checkpoint <id>        │          │ dump.log                 │          │ runc restore --image-path …  │
│  │ CLI 组装 CriuOpts        │          │ inventory.img  core-*.img│          │  │ prepareCriuRestoreMounts  │
│  ▼                          │  swrk    │ fdinfo-*.img  mm-*.img   │          │  │ (重建挂点/bind mount)     │
│ Container.Checkpoint()      │ ───────► │ pagemap-*.img  ids.img   │ ──────►  │  ▼                           │
│  rpcOpts(CRIU protobuf)     │  socket  │ pstree.img  tcpqueue.img │  拷贝目录 │ Container.Restore()          │
│  ▼                          │          │ pages-*.img(内存页)       │          │  criu swrk ← RESTORE 请求    │
│ criu swrk (独立进程)         │          │ descriptors.json(runc写) │          │  ▼                           │
│  冻结进程树(cgroup freezer)  │          └──────────────────────────┘          │ CRIU 恢复器:重建 pid ns       │
│  /proc/pid/… → 二进制镜像    │                pre-dump: 父子目录增量           │ 按原始 PID 重建进程树         │
│  (非 pre-dump) 杀死进程      │                                                │ setns 进其余 ns,恢复内存/fd   │
│  stateDir/checkpoint 标记    │                                                │  ▼ post-restore 通知         │
│  Destroy() → 容器 stopped    │                                                │ runc 认领 init,状态 Running  │
└─────────────────────────────┘                                                 └─────────────────────────────┘
```

一次 checkpoint 落盘的是"CRIU 镜像目录"，而不是单个文件：内存页（pages-*.img）、页表（pagemap-*.img）、fd 表、进程树（pstree.img）等若干 protobuf 镜像文件；runc 额外写入一个 `descriptors.json`（libcontainer/criu_linux.go:110、criu_linux.go:488-497），记录容器 init 的外部 fd（stdin/stdout/stderr 管道等），restore 时回填为 InheritFd。

**关键分工**：runc 负责"容器级"的事（镜像目录、cgroup、外部 namespace、bind mount、钩子、状态文件），CRIU 负责"进程级"的事（冻结、内存/fd/寄存器转储、按原 PID 重建）。runc 编译时可用 `runc_nocriu` tag 去掉这一切，届时 Checkpoint/Restore 只返回 `ErrNoCR`（libcontainer/criu_disabled_linux.go:7-15）。

---

## 2. checkpoint 专节：参数组装与 CRIU 调用

### 2.1 入口与前置检查

CLI 层 `runc checkpoint`（checkpoint.go:21-84）先做两件事：

- 状态把关：Created/Stopped 状态直接拒绝——没有运行中的进程树就没有可转储的东西（checkpoint.go:67-69）；
- 组装 `CriuOpts`（checkpoint.go:118-142，结构体定义在 libcontainer/criu_opts_linux.go:13-39）。镜像目录缺省为当前目录下的 `checkpoint`（utils_linux.go:41-47）。

rootless 下直接告警"untested"（checkpoint.go:54-57；libcontainer 内注释同样说明 CRIU 2.0 的非特权 dump 对容器场景不够用，criu_linux.go:299-303）。

进入 `Container.Checkpoint()`（libcontainer/criu_linux.go:294-506）后：

```go
// libcontainer/criu_linux.go:305-317（摘录）
// We are relying on the CRIU version RPC which was introduced with CRIU 3.0.0
if err := c.checkCriuVersion(30000); err != nil {
    return err
}
if criuOpts.ImagesDirectory == "" {
    return errors.New("invalid directory to save checkpoint")
}
cgMode, err := criuCgMode(criuOpts.ManageCgroupsMode)
```

版本探测通过 CRIU 的 VERSION/FEATURE_CHECK RPC（checkCriuVersion，criu_linux.go:93-108；特性探测 checkCriuFeatures，criu_linux.go:37-81），版本号缓存在 `Container.criuVersion`（container_linux.go:42）。

### 2.2 rpcOpts：一次 dump 的完整参数

核心是把 Go 侧 `CriuOpts` 一对一映射成 protobuf `criurpc.CriuOpts`（criu_linux.go:332-352）。值得圈点的字段：

| runc 选项 | CRIU 语义 | 行号 |
|---|---|---|
| `TcpEstablished` | 连已建立的 TCP 连接一起转储（对端无感知，靠 TCP repair） | criu_linux.go:343 |
| `TcpSkipInFlight` | 跳过 in-flight 连接 | criu_linux.go:344 |
| `ExtUnixSk` | 允许转储连接到容器外进程的 Unix socket | criu_linux.go:346 |
| `FileLocks` | 连文件锁一起转储（否则持有 flock 的容器 dump 后锁状态丢失） | criu_linux.go:347 |
| `EmptyNs` | 这些 ns 只建空壳、不转储属性（默认含 NEWNET） | criu_linux.go:348；checkpoint.go:163 |
| `ShellJob` | 共享终端的作业（控制终端） | criu_linux.go:341 |
| `LeaveRunning` | dump 后不杀进程（快照≠停机） | criu_linux.go:342 |
| `LazyPages` | 恢复期用 userfaultfd 按需补页 | criu_linux.go:351 |
| `NotifyScripts` | 打开脚本/通知协议（runc 依赖它收 notify 事件） | criu_linux.go:339 |

外部 namespace（net/pid）在 dump 侧被声明为 `--external <type>[inode]:extRoot<Type>NS`——CRIU 不转储这些 ns 的内容，只记录"引用了一个外部 ns"，restore 时凭同名 key 继承（handleCheckpointingExternalNamespaces，criu_linux.go:203-223；key 构造 criuNsToKey，criu_linux.go:187-201）。net ns 需要 CRIU ≥3.11、pid ns ≥3.15（criuSupportsExtNS，criu_linux.go:171-185）。

### 2.3 冻结：freezer 优先，ptrace 兜底

```go
// libcontainer/criu_linux.go:385-392（摘录）
// CRIU can use cgroup freezer; when rpcOpts.FreezeCgroup
// is not set, CRIU uses ptrace() to pause the processes.
// Note cgroup v2 freezer is only supported since CRIU release 3.14.
if !cgroups.IsCgroup2UnifiedMode() || c.checkCriuVersion(31400) == nil {
    if fcg := c.cgroupManager.Path("freezer"); fcg != "" {
        rpcOpts.FreezeCgroup = new(fcg)
    }
}
```

即：runc 告诉 CRIU freezer cgroup 的路径，冻结由 CRIU 执行——一致性快照的前提是整棵进程树先静止。cgroup v2 freezer 是 CRIU 3.14 才有的能力，否则 CRIU 退回 ptrace 逐个 attach。这与 `runc pause` 用的是同一族机制（container_linux.go:806-823 的 `cgroupManager.Freeze(Frozen)`），但 pause 只停不存。

### 2.4 需要转储什么：进程/内存/fd/网络/挂载

- 进程与内存：CRIU 遍历 `/proc`，转储整棵树的地址空间（pages-*.img）与寄存器。bind mount、cgroup 挂载、MaskPaths（被 /dev/null 遮蔽的路径）以 `ExtMountMap` 形式声明为外部挂载，CRIU 不打包它们的容量（addCriuDumpMount criu_linux.go:112-122；addMaskPaths criu_linux.go:124-144；挂载收集循环 criu_linux.go:457-481）。
- fd：`descriptors.json` 记录 init 的外部管道 fd（criu_linux.go:488-497）。
- 网络：默认 `EmptyNs` 掩码含 `CLONE_NEWNET`（checkpoint.go:163-179）——网络栈"不打包"，迁移时由上层（Docker/containerd+CNI）在目标机重新组网；只有显式清空该掩码时才让 CRIU 连 netns 内容（含 TCP 状态）一起转储。
- 不可打包的部分都以"external/inherit"声明，这正是容器快照的设计哲学：宿主侧资源一律引用而非复制。

### 2.5 pre-dump：增量机制与 parentPath

pre-dump 是 live migration 的核心。第一次 `runc checkpoint --pre-dump` 只转储内存（不杀进程，容器继续跑），后续最终 dump 通过 `--parent-path` 指向前次镜像目录，CRIU 用软迁移（track memory changes）只写"变脏的页"：

```go
// libcontainer/criu_linux.go:402-421（摘录）
// pre-dump may need parentImage param to complete iterative migration
if criuOpts.ParentImage != "" {
    rpcOpts.ParentImg = new(criuOpts.ParentImage)
    rpcOpts.TrackMem = new(true)
}
var t criurpc.CriuReqType
if criuOpts.PreDump {
    feat := criurpc.CriuFeatures{ MemTrack: new(true) }
    if err := c.checkCriuFeatures(criuOpts, &feat); err != nil { return err }
    t = criurpc.CriuReqType_PRE_DUMP
} else {
    t = criurpc.CriuReqType_DUMP
}
```

要点：

- CLI 强制 `--parent-path` 必须是相对路径（相对 image-path），且必须已存在（checkpoint.go:96-115），防止把上一个镜像目录指到任意文件系统位置。
- pre-dump 前先 FEATURE_CHECK `MemTrack`（内存脏页跟踪依赖内核特性，criu_linux.go:409-416）。
- pre-dump 不写 descriptors.json、不处理挂载（`if !criuOpts.PreDump` 分支，criu_linux.go:457-498）——它只是内存快照的第一层。
- pre-dump 结束时 CRIU 进程按协议会"正常地"以非零退出（它在等下一次 dump，而 runc 每次只发一条 PRE_DUMP 就完事），runc 在 criuSwrk 尾部为它开了特例（criu_linux.go:1067-1076）。
- `--auto-dedup`（criu_opts_linux.go:28）让增量镜像去重，父子的相同页共享存储。

典型迭代迁移：`pre-dump → (业务低峰) pre-dump --parent-path=p1 → final dump --parent-path=p2 → 拷贝全部目录 → 目标机 restore`。停机窗口只剩"最后一次 dirty 增量 + 网络切换"。

### 2.6 lazy-pages 与 page-server

- `--page-server ADDRESS:PORT`：把内存页推给远端 CRIU page server 而非写本地盘（criu_linux.go:395-400）。
- `--lazy-pages`：restore 侧不立即灌入全部内存页，注册 userfaultfd，缺页时再从源端拉（feature check 在 criu_linux.go:423-431）。`--status-fd` 用于源端得知"lazy server 就绪"：CRIU ≥3.15 走 notify 事件 `status-ready`（runc 往 fd 写一个 `\0`，criu_linux.go:1199-1208），旧版本直接传 StatusFd 给 CRIU（criu_linux.go:432-448）。

---

## 3. restore 专节：重建与 namespace 的重进

### 3.1 runc 侧的准备（全部发生在 CRIU 开工之前）

`runc restore`（restore.go:12-129）复用创建旅程的骨架：`startContainer(CT_ACT_RESTORE)`（utils_linux.go:381-403）→ `createContainer` 从 bundle 的 config.json 新建 Container 对象 → runner 分流到 `container.Restore(process, criuOpts)`（utils_linux.go:288-297）。注意它**不执行** `container.Start()`——不需要 runc 去 clone 任何进程。

`Container.Restore`（criu_linux.go:633-814）的准备动作：

1. 把容器 rootfs **递归 bind mount 到 stateDir/criu-root**（criu_linux.go:665-684）。注释给出原因：CRIU 要求 root 必须是挂点、且父目录未被 overmount——这是满足 CRIU 约束的妥协。
2. `prepareCriuRestoreMounts`：像首次创建那样为每个挂载点创建目录；挂点位于 tmpfs 上的跳过——tmpfs 的内容由 CRIU 从镜像整体恢复（isOnTmpfs criu_linux.go:540-547，跳过逻辑 593-597）；bind mount 立即挂上以便建深层挂点，收尾时再卸掉（criu_linux.go:614-621，清理 562-582）。
3. 组 RESTORE 请求：`RstSibling: true`（恢复出的进程作为 criu 的兄弟而不是子进程，criu_linux.go:693），LSM profile/mount-context 需 CRIU ≥3.16（criu_linux.go:709-722）。
4. namespace 三条路（handleRestoringNamespaces，criu_linux.go:225-261）：
   - **net/pid ns 有外部路径** → `InheritFd`：runc 打开 ns 文件，把 fd 通过 ExtraFiles 递给 criu，`Fd: 4+len(extraFiles)`（0/1/2 和 swrk socket 占了前四个，criu_linux.go:281-289）；
   - **其余 ns 有路径** → `JoinNs`（直接 setns 到既有 ns；NEWCGROUP 不支持，criu_linux.go:245-248）;
   - **没有路径** → CRIU 按镜像重建该 ns。
5. 网络：只有当 `EmptyNs` 未含 NEWNET 时才传 veth 对（restoreNetwork，criu_linux.go:520-538、780-782）。
6. descriptors.json 里的 `pipe:` fd 转成 InheritFd 回接 stdio（criu_linux.go:788-802）。
7. cgroup：criuApplyCgroups 把 **criu swrk 进程自己**放进目标 cgroup 并写入资源限制、附上 CgRoot（criu_linux.go:866-898）——恢复出的进程继承其 cgroup。

### 3.2 CRIU 侧的重建：为什么 restore 不走 04 章的 init 路径

04 章的创建旅程是"runc init 子进程 + nsexec 隆重入场"：先 clone 出带新 ns 的子进程，六步同步（sync.go）里由 Go 运行时之外的 C 代码 setns/pivot_root/挂 sysfs……那套流程是为了**从零创建**进程。

restore 完全不同：**进程本来就"存在"**，镜像里存着原始 PID、寄存器、内存内容、fd 偏移。CRIU 的 restorer 直接在重建出的 PID namespace 里以原 PID 逐个 fork 出进程（因此必须先重建 pid ns 才能占用原 PID），setns 进入其余 namespace，mmap 回内存、恢复 fd 表，最后把每个线程从"尸位"上真正唤醒。runc 的 nsexec/init Go 代码在这条路上没有角色——如果再跑一遍 `runc init`，就等于把一个已经活着的应用"重新初始化"了，寄存器现场、堆栈内容全都不对。

runc 需要做的只有一件事：**认领**。CRIU 恢复完成后通过 notify 协议把 restored init 的 PID 告诉 runc：

```go
// libcontainer/criu_linux.go:1145-1163（摘录）
case "post-restore":
    pid := notify.GetPid()
    p, err := os.FindProcess(int(pid))
    if err != nil { return err }
    cmd.Process = p                      // cmd.Process 将被 restored init 取代
    r, err := newRestoredProcess(cmd, fds)
    if err != nil { return err }
    process.ops = r
    if err := c.state.transition(&restoredState{ imageDir: opts.ImagesDirectory, c: c }); err != nil {
        return err
    }
```

`restoredProcess`（libcontainer/restored_process.go:11-78）是对这个"非亲生但同 runc 进程树"进程的适配器：signal/terminate 直接作用于原 PID；wait 只能等 criu swrk 的退出码（TODO 注释承认这是近似，restored_process.go:47-49）。

其余 notify 事件各司其职（criuNotifications，criu_linux.go:1108-1211）：

- `setup-namespaces`：此刻 CRIU 已建好 ns、init 有真实 PID，runc 在此补跑 Prestart/CreateRuntime 钩子（criu_linux.go:1130-1144）——创建旅程中这两个钩子由 init 进程路径触发，restore 路径由 notify 触发；
- `post-restore` 里还把 `c.created` 重置为当前时刻，并按需给配置追加 time namespace（CRIU 3.14+ 会把进程放进 timens，criu_linux.go:1165-1173）；
- `orphan-pts-master`：CRIU 经 SCM_RIGHTS 递回伪终端 master，runc 转发给 console-socket 持有者（criu_linux.go:1182-1198）；
- `network-lock`/`network-unlock`：dump/restore 的网络静默窗口（criu_linux.go:1122-1129；lockNetwork/unlockNetwork criu_linux.go:1080-1106）。注意现行 runc 的 network strategy 表里只剩 loopback（network_linux.go:21-23），对 Docker 的 veth 组网而言这两个钩子基本是空操作，真正的网络静默要靠上层（CNI 链路拆除/TC 重定向）。

### 3.3 criuSwrk：runc 与 CRIU 的对话协议

所有模式共用一个传输层（criuSwrk，criu_linux.go:900-1078）：

- `socketpair(AF_LOCAL, SOCK_SEQPACKET)` 建双端（criu_linux.go:901）；
- `exec.Command("criu", "swrk", "3")` 把 server 端 fd 作为 ExtraFile 3 递过去（criu_linux.go:924-933）；启动后立刻关掉自己手里那端，保证 CRIU 崩溃时 runc 不会挂在 read 上（criu_linux.go:939）；
- protobuf 请求一次写入（criu_linux.go:986-993），随后循环收响应：失败即带 errno 报错（criu_linux.go:1024-1025）；收到 NOTIFY 则执行 criuNotifications 后回一条 `NotifySuccess` 继续等（criu_linux.go:1032-1048）；
- 结束时 CloseWrite + Wait（criu_linux.go:1059-1065）；失败时 `logCriuErrors` 模仿 `grep -B5 Error` 从 dump.log/restore.log 抽错误上下文（criu_linux.go:816-864）。

---

## 4. 状态机专节：checkpoint 之后容器是什么

libcontainer 的状态机（libcontainer/state_linux.go）共 7 态：stopped/running/created/paused/restored/loaded + destroy 流程。与 C/R 相关的三处：

1. **checkpoint 后**：dump 成功且未 `--leave-running`、非 pre-dump 时，CLI 调 `container.Destroy()`（checkpoint.go:75-81）。CRIU 在 dump 收尾会杀死冻结的进程树，`refreshState` 检测 init 已死（hasInit：/proc stat 的 StartTime 不匹配或 Zombie/Dead，container_linux.go:938-952）→ 迁移到 stoppedState → `destroy()` 清 cgroup、删 stateDir、跑 Poststop 钩子（state_linux.go:39-67）。**所以对 runc 而言，被 checkpoint 的容器等于"stopped"，OCI 语义上不存在 "checkpointed" 状态**；若 `--leave-running` 或 pre-dump，则容器全程 Running（pre-dump 的定义就是"转储后继续运行"，checkpoint.go:45）。
2. **checkpoint 标记文件**：`post-dump` 通知时 runc 在 stateDir 创建名为 `checkpoint` 的文件（criu_linux.go:1116-1121），`post-restore` 时删除（criu_linux.go:1177-1181）；restoredState.destroy 会 stat 它但结果基本被忽略（state_linux.go:215-222）——它更像暴露给外部观察者的"该容器已有镜像"的哨兵。
3. **restore 后**：`restoredState` 的 status() 就是 **Running**（state_linux.go:203-205），只是额外带着 imageDir——因为容器随时可以被再次 checkpoint。状态转换表里 stopped→restored 合法（state_linux.go:93-102），restored→stopped/running 合法（state_linux.go:207-213）。

state.json 的变化由 `updateState`/`saveState` 统一处理：写临时文件后 rename 原子替换（container_linux.go:871-906）。restore 认领 init 后立刻 `updateState(r)`，新 state.json 记录 restored init 的 PID/StartTime/namespace 路径（criu_linux.go:1174-1176）；字段如 `ExternalDescriptors` 注释明确写着"needed for checkpoint and restore"（container_linux.go:70-72）。另一个容易被忽略的点：**restored 容器的 Created 时间戳是恢复时刻而非首次创建时刻**（criu_linux.go:1166）。

---

## 5. 能力边界专节：什么状态不可快照

如实列出 runc/CRIU 的边界（多数是"默认拒绝、显式打开选项后尽力而为"）：

- **外部 TCP 连接**：默认拒绝；`--tcp-established` 借 TCP repair 冻结连接状态，但对端不知道你迁移了——RTT 内对端仍在向旧主机发包。`--tcp-skip-in-flight` 则直接丢弃 in-flight 数据（criu_linux.go:343-344）。
- **跨容器的 Unix socket**：`--ext-unix-sk` 允许转储连接到容器外对端的 socket；若对端进程不在镜像里，restore 时连接无法重接，CRIU 只能尽力（criu_opts_linux.go:21）。
- **宿主侧网络**：默认 EmptyNs 含 NEWNET，网络栈根本不进镜像；迁移后的 IP/端口 continuity 由编排层负责（Docker 的 checkpoint API 至今实验性）。
- **PID 依赖的外部资源**：绑定到具体 PID 的东西（如某些 prctl 语义、外部监控以 pid 为键）在 PID 漂移（跨 PID ns 迁移）后失配。
- **时间依赖**：CLOCK_BOOTTIME 等单调时钟在 restore 后"跳变"；CRIU 3.14+ 用 time namespace 掩盖（runc 在 post-restore 自动追加 NEWTIME，criu_linux.go:1167-1173），旧内核无解。
- ** tmpfs/挂载**：tmpfs 内容会随镜像走（restore 时跳过 tmpfs 上的挂点，criu_linux.go:593-597）；但 bind mount、MaskPaths 只是引用源路径——目标机上若没有同样的源路径/设备文件，restore 直接失败（prepareCriuRestoreMounts 需要重建挂点，criu_linux.go:583-631）。
- **rootless**：checkpoint/restore 在 rootless 下明确"untested"，代码注释承认非特权 dump/restore 尚不可行（checkpoint.go:54-57、criu_linux.go:299-303、642-645）。
- **空闲 vs 在用资源**：file locks、终端作业、in-flight 网络数据这类"瞬时状态"都要专门选项，默认一律不接受。

### live migration 完整链路

1. 源机 `runc checkpoint --pre-dump --image-path=dir`（容器继续运行，page-1 落盘）；
2. 间隔若干秒/分钟，反复 `checkpoint --pre-dump --parent-path=上一轮`（增量脏页，AutoDedup 可去重）；
3. 最终 `checkpoint --parent-path=最后一轮`（或加 `--lazy-pages` + page-server 进一步压缩停机窗口）——此刻容器被冻结并销毁；
4. 镜像目录整体拷贝到目标机；网络切换（上层负责，例如 IP take-over/SDN 重编址）；
5. 目标机 `runc restore --image-path=dir --bundle=bundle`，CRIU 重建进程树，runc 认领 init，容器在目标机 Running。
   `--lazy-pages` 的变体是"先恢复控制流、内存按缺页从源机慢慢拉"（criu_linux.go:423-449、1199-1208），适合大内存容器缩短感知中断。

---

## 6. 设计动机

**为什么起外部 criu 进程而非链接为库？**
其一，CRIU 的核心工作（ptrace 全进程、读 /proc、恢复任意 fd/内存映射）本质是"对系统状态做手术"，以独立 root 权限进程运行，边界清晰、崩溃不连累 runc——runc 甚至专门在启动后关闭 socketpair 的 server 端来保证"criu 死了 runc 不挂"（criu_linux.go:938-939）。其二，协议即解耦：protobuf over socketpair（criuSwrk）让 runc 可以跟随 CRIU 版本演进而只用做版本/特性 RPC 探测（criu_linux.go:93-108、37-81），不匹配时报错而非链接失败。其三，swrk 模式让 CRIU 的 stdio 可以直接桥接给容器进程（`cmd.Stdin = process.Stdin`，criu_linux.go:925-929），restore 后的容器 I/O 天然接续。其四，发行版可以打 `runc_nocriu` 构建一个不背 CRIU 依赖的二进制（criu_disabled_linux.go）。

**为什么 pre-dump 是迁移的关键？**
停机时间 = 冻结后必须搬运的数据量。pre-dump 把"内存搬运"从停机窗口挪到窗口之前：迭代期间容器照常服务，每轮只写脏页增量（TrackMem），几何级地缩小最后一轮的残余——最终停机窗口趋近于"最后一轮脏页 + 网络切换"。这是虚拟机 live migration（迭代预拷贝）思想在进程粒度的重演，`--lazy-pages`（userfaultfd）则是另一种答案：先恢复运行、页异步补齐。

**容器快照与虚拟机快照的本质差异？**
虚拟机快照捕获的是"一整台机器"：CPU/内存/设备全部入镜，边界清晰。容器是"宿主上的一组进程 + 隔离视图"，它与宿主共享内核与文件系统，因此快照必须大量使用"外部引用"而非"内联拷贝"：bind mount、netns、pidns、cgroup 都是 `external/inherit` 声明（criu_linux.go:203-223、225-292）。这带来容器快照的天然弱点——可迁移性受宿主环境同质性约束（同内核版本、同挂载布局、同网络编排），以及天然优势——镜像小（只存进程私有状态）、恢复快（无需引导设备/内核）。本质上：VM 快照序列化的是硬件状态，容器快照序列化的是"进程树在命名空间坐标系下的完整现场"。

---

## 7. FAQ 素材

1. **`runc checkpoint` 后 `runc list` 里容器为什么是 stopped？** dump 收尾 CRIU 杀掉了进程树（除非 --leave-running），CLI 随即 Destroy（checkpoint.go:75-81），refreshState 判 init 已死 → stopped（container_linux.go:927-929）。OCI 状态模型没有"checkpointed"。
2. **`./checkpoint` 目录和 stateDir 里的 `checkpoint` 文件是什么关系？** 前者是 CRIU 镜像目录（缺省 cwd/checkpoint，utils_linux.go:41-47）；后者是 dump 成功的标记文件（criu_linux.go:1116-1121），两者同名但毫无关系。
3. **`--parent-path` 为什么必须是相对路径？** 防止把父镜像指到任意位置（checkpoint.go:101-103），约定它位于 image-path 之下，迁移时整棵父子目录树一起拷贝。
4. **pre-dump 后容器还在跑吗？** 在跑。pre-dump 只转储内存且不杀进程（checkpoint.go:45），容器全程 Running，可以反复做。
5. **restore 需要重新跑 config.json 里的 process.args 吗？** 不需要。args/环境/寄存器都在镜像里，bundle 只用于重建 mount/cgroup/ns 骨架；`runc restore` 也从不调用 runc init。
6. **为什么 restore 时 rootfs 要 bind mount 一遍？** CRIU 要求恢复根是挂点且父目录未被 overmount，runc 把 rootfs bind 到 stateDir/criu-root 来满足（criu_linux.go:666-684）。
7. **TCP 连接迁移后对端会断开吗？** 不会立刻。`--tcp-established` 用 TCP repair 把连接状态原样搬走，但旧主机上的报文残留与路由收敛需要上层配合（BGP/SDN）；in-flight 数据默认是拒绝的，可显式 `--tcp-skip-in-flight` 丢弃。
8. **Docker 怎么用这套？** `docker checkpoint create/ start --checkpoint` 走 containerd shim：shim 调 `runc checkpoint` CLI（带 --image-path 等），恢复时在 task Start 里转成 `runc restore`（见第 8 节行号表）。该功能在 Docker 侧至今是实验性的。
9. **checkpoint 之前必须先 pause 吗？** 不用。CRIU 拿到 FreezeCgroup 路径后自己冻结（criu_linux.go:385-392）；无 freezer 时用 ptrace。用户手动 pause 反而会因状态机停留 Paused 引入多余步骤。
10. **为什么版本门槛这么多（30000/31100/31400/31500/31600）？** 每个 C/R 能力锚定一个 CRIU 版本：RPC 协议 3.0、外部 netns 3.11、v2 freezer 与 timens 3.14、外部 pidns 与 status-ready 3.15、LSM 选项修复 3.16（criu_linux.go:306、177、388、180-181、443、712）。

## 深挖方向

1. **criuSwrk 的 NOTIFY 应答循环**（criu_linux.go:997-1057）：SEQPACKET + OOB（SCM_RIGHTS 收 orphan-pts master），一次实现"协议引擎 + fd 通道"，可与 04 章 init 同步管道对照。
2. **restoredProcess.wait 的语义缺陷**（restored_process.go:47-49 的 TODO）：runc 无法真正 wait restored init（注释建议 --exec-cmd），信号转发表与退出码传播如何弥补。
3. **pre-dump + lazy-pages + page-server 三者的组合矩阵**：与 CRIU 上游的 p.haul/移动式页服务对照，runc 侧参数如何透传（criu_linux.go:395-400、423-449）。
4. **状态机对照实验**：同一容器 checkpoint→destroy 与 pause→destroy 的 stateDir/state.json 差异（state_linux.go:165-194 vs 39-67）。
5. **containerd 侧 image 导出**：shim 只管 C/R，把镜像目录打成 OCI image layer 的是 containerd 的 checkpoint image 逻辑（cmd/ctr/commands/tasks/checkpoint.go），可对比"runtime 快照"与"镜像快照"两层。

## containerd 侧对接（简查）

- shim 的 `Init.checkpoint` 调 go-runc 的 `runtime.Checkpoint`，即**拉起 `runc checkpoint` CLI**，透传 WorkDir/ImagePath/ParentPath 等并组装 LeaveRunning 动作（`Exit==false → LeaveRunning`）：cmd/containerd-shim-runc-v2/process/init.go:437-470（containerd @ f6132db）。
- 失败时把 CRIU 的 dump.log 拷回 bundle 作为 criu-dump.log（init.go:458-462），与 runc 的 logCriuErrors 互补。
- "从检查点创建任务"：Create 携带 Checkpoint 路径时走 createCheckpointedState（init.go:134-136、192-209），状态机置为 createdCheckpointState，其 Start 调 `runc restore`（init_state.go:147 起）——即 containerd 的"restore"被伪装成一次普通的 task Start。

---

## 写作要点速查表

| 主题 | 函数/位置 | 行号 |
|---|---|---|
| checkpoint CLI 入口/状态拒绝/事后销毁 | checkpoint.go Action | 50-83（拒绝 67-69，销毁 75-81） |
| --parent-path 相对路径校验 | checkpoint.go prepareImagePaths | 96-115 |
| CriuOpts 结构体（全部选项语义） | criu_opts_linux.go | 13-39 |
| Checkpoint 主流程（版本检查→rpcOpts→pre-dump 分支→criuSwrk） | criu_linux.go Checkpoint | 294-506 |
| rpcOpts 组装（tcp/extUnixSk/fileLocks/lazyPages） | criu_linux.go | 332-352 |
| 冻结方式（freezer vs ptrace） | criu_linux.go | 385-392 |
| pre-dump 请求类型 + ParentImg/TrackMem | criu_linux.go | 402-421 |
| 外部 ns dump 声明（extRoot<TYPE>NS key） | criu_linux.go handleCheckpointingExternalNamespaces | 203-223 |
| descriptors.json 写入 | criu_linux.go | 488-497 |
| Restore 主流程（criu-root bind、挂点重建、RESTORE 请求） | criu_linux.go Restore | 633-814 |
| restore 挂点重建（tmpfs 跳过/bind 先挂后卸） | criu_linux.go prepareCriuRestoreMounts | 549-631 |
| restore 的 ns 重进（JoinNs/InheritFd，fd 偏移 4） | criu_linux.go handleRestoringNamespaces/…External | 225-292 |
| cgroup 应用到 criu 进程 | criu_linux.go criuApplyCgroups | 866-898 |
| swrk 传输层（socketpair/exec criu swrk 3/NOTIFY 循环） | criu_linux.go criuSwrk | 900-1078 |
| notify 钩子（post-dump 标记/post-restore 认领/timens） | criu_linux.go criuNotifications | 1108-1211 |
| restoredState（status=Running）与标记检查 | state_linux.go | 196-222 |
| 状态刷新/hasInit 判死 | container_linux.go refreshState/hasInit | 919-952 |
| state.json 原子写 | container_linux.go saveState | 882-906 |
| restoredProcess 适配器（wait 的 TODO） | restored_process.go | 11-78 |
| CLI→Restore 分流 | utils_linux.go runner.run | 288-297 |
| nocriu 构建的空实现 | criu_disabled_linux.go | 7-15 |
| containerd shim 转发 checkpoint/restore | containerd init.go/init_state.go | 437-470 / 147 起 |
