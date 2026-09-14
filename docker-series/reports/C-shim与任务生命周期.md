# C 篇：shim v2 与容器任务生命周期深读

> 基于 containerd 2.x 主干，commit `f6132db`（shallow clone）。文中路径均为仓库相对路径，行号以该 commit 实测（grep -n / Read 核对）。
> 卷一第 3 章配套：A 篇已讲到 Task 创建链入口（`client/container.go:226` NewTask → `plugins/services/tasks/service.go:62` → `plugins/services/tasks/local.go:171,277` → `core/runtime/v2/task_manager.go:159/160/192/226`）。本篇从 TaskManager 往下，展开 shim 进程本身。

## 1. 全景：一个容器的完整生命周期

```
 dockerd (moby)                containerd daemon                      shim 进程(每容器/每Pod)          runc
 ─────────────                 ─────────────────                      ──────────────────────          ────
 NewTask ──gRPC──▶ TaskService().Create (client/container.go:297)
                        │
                        ▼ (daemon 内)
                   local.Create (plugins/services/tasks/local.go:171,277)
                        │
                        ▼
                   TaskManager.Create (core/runtime/v2/task_manager.go:159)
                   ├─ NewBundle: 建目录/写 config.json (:160, bundle.go:50)
                   ├─ ShimManager.Start (:192 → shim_manager.go:205)
                   │    └─ binary.Start: exec shim <start> (binary.go:66)
                   │         stdin=BootstrapParams (command.go:129-155)
                   │         stdout=BootstrapResult{address} (binary.go:129)
                   │         → shim 进程已常驻: ttrpc socket (fd3 继承, pkg/shim/shim.go:475)
                   ├─ taskMounts.Activate 挂 rootfs (:206)
                   └─ shimTask.Create: ttrpc Task.Create (shim.go:713, :226) ─────▶ runc.NewContainer
                        │                                                            (runc/container.go:47)
                        │                                                          runc create --bundle
                        │                                                            (go-runc/runc.go:203)
                        │                                                       [init 进程 paused 诞生]
                   shimTask.Start: ttrpc Task.Start (shim.go:807) ──────────────▶ runc start
                        │
   docker logs/attach ◀══ FIFO ══▶ shim 转发 stdio (process/io.go:134 copyPipes)
                        │
   事件: shim ──ttrpc Forward──▶ containerd events exchange (pkg/shim/publisher.go:154)
                                 ▲ OOM/TaskExit/TaskStart 都走这条回路
```

**控制面与数据面分离**：控制面是两跳 RPC（client → containerd daemon 的 gRPC → shim 的 ttrpc）；数据面（stdin/stdout/stderr、日志、容器输出）完全不经过 containerd 的 RPC 栈，走 FIFO/文件/外部日志进程，由 shim 做搬运工。事件流则是 shim 反向通过 ttrpc 推回 containerd。

## 2. shim 启动专节：binary 协议、bootstrap 传递、TTRPC 通道

### 2.1 目录更名说明

1.x 里的 `runtime/v2/shim`（shim 进程内入口框架）在 2.x 主干已迁到 `pkg/shim/`（如 `pkg/shim/shim.go`），daemon 侧的 shim 管理在 `core/runtime/v2/`。runc 适配器在 `cmd/containerd-shim-runc-v2/`。

### 2.2 binary call 协议：exec shim 二进制 + 子命令

containerd 不通过 RPC 启动 shim，而是把 shim 当 CLI 调：`exec <runtime-path> -namespace ... -id ... start`（`core/runtime/v2/command.go:78-95`，`Action` 为 `start`/`delete` 二选一，`command.go:58`）。进程环境注入 `TTRPC_ADDRESS`/`GRPC_ADDRESS`/`NAMESPACE`/`MAX_SHIM_VERSION`（`command.go:40-45,108-110`），工作目录即 bundle（`binary.go:74` WorkDir=bundle.Path；`command.go:102` cmd.Dir）。

启动阶段的输出复用做了两件事：

- 先打开 bundle 下的 `log` FIFO，把 shim 日志流拷到 containerd 的 stderr（`binary.go:92-114`；FIFO 路径 `core/runtime/v2/shim_unix.go:37-39`）；shim 侧用 `OpenFifoDup2("log", stderr)` 接管（`pkg/shim/shim_unix.go:110-112`）。
- `cmd.CombinedOutput()` 捕获 stdout（`binary.go:115`），解析出 `BootstrapResult`（`binary.go:129` → `core/runtime/v2/shim.go:293` parseStartResponse；老 shim 的"纯字符串地址"回退为 ttrpc v2，`shim.go:309-314`）。

### 2.3 bootstrap 传递：stdin 进、stdout 出、bootstrap.json 落盘

2.3+ shim 采用新 Bootstrap 协议（`command.go:129-156`）：containerd 把 `BootstrapParams`（namespace、两代地址、containerd 二进制路径、runtime options 以 Extension 附带）序列化后写 shim 的 **stdin**（`command.go:150-155`）；shim 的 start 动作读 stdin（`pkg/shim/shim.go:275`，限 10MB），start 完成后把 `BootstrapResult{Protocol,Address,Version=3}` proto 写 **stdout**（`pkg/shim/shim.go:307-314`）。containerd 拿到结果后：

1. 建立到 shim 的长连接 ttrpc/grpc（`binary.go:134` → `makeConnection`，`core/runtime/v2/shim.go:369-402` 按 Protocol 分派）；
2. 把结果原子写入 `bootstrap.json` 供 containerd 重启后恢复 shim 连接（`binary.go:140`；写函数 `shim.go:324-347`；恢复入口 `shim_manager.go:392-420` restoreBootstrapParams，含老 shim 从 `address` 文件迁移的逻辑）。

注意：新协议下 shim 不再自写 bundle 的 `address` 文件——`cmd/containerd-shim-runc-v2/task/service.go:97` 的 `ReadAddress("address")` 只是兼容旧布局的尽力而为清理；同时把 runtime 二进制路径存 `shim-binary-path`（`binary.go:125`），供死后 `shim delete` 收尸时重新 exec（`binary.go:154-216` Delete）。

### 2.4 shim 常驻进程与 TTRPC 服务注册

shim 二进制的 start 动作只是"一次性引导进程"：它 exec 自身（`cmd/containerd-shim-runc-v2/manager/manager_linux.go:84-114` newCommand，`os.Executable()` 自调、Setpgid），创建 ttrpc socket（:150-185 newShimSocket，地址经 `shim.CreateSocketAddress`，`pkg/shim/util_unix.go:77`），并把 **listen fd 作为 ExtraFiles（fd=3）传给常驻进程**（`manager_linux.go:235`）。常驻进程不接收 bootstrap 参数，直接从 fd 3 起监听（`pkg/shim/shim_unix.go:52-71` serveListener：path=="" 时 `net.FileListener(os.NewFile(fd))`；调用点 `pkg/shim/shim.go:475` `serveListener(socketFlag, 3)`）。

常驻进程的插件装配与 ttrpc 注册在 `pkg/shim/shim.go`：

```go
// pkg/shim/shim.go:434-445（节选）
server, err := newServer(ttrpc.WithUnaryServerInterceptor(unaryInterceptor))
...
for _, srv := range ttrpcServices {
    if err := srv.RegisterTTRPC(server); err != nil { ... }
}
if err := serve(ctx, server, signals, sd.Shutdown, pprofHandler); err != nil { ... }
```

runc 适配器注册的是 TaskService（`cmd/containerd-shim-runc-v2/task/service.go:289-292` `taskAPI.RegisterTTRPCTaskService`）。shim 还会注册事件 publisher 插件（`pkg/shim/shim.go:334-349`，`NewPublisher(ttrpcAddress)`）——这就是事件回传通道的源头（见第 6 节）。shim 自身资源约束：`GOMAXPROCS=2`、定期 FreeOSMemory（`pkg/shim/shim.go:150-162`），作为 child subreaper 收养容器进程（:232-236，SIGCHLD reaper `pkg/shim/shim_unix.go:73-92`）。

**多容器共享一个 shim（Pod 分组）**：manager.Start 读 bundle 的 `config.json` 注释，命中 `io.containerd.runc.v2.group` 或 `io.kubernetes.cri.sandbox-id` 标签则以分组 ID 建 socket（`cmd/containerd-shim-runc-v2/manager/manager_linux.go:67-70,200-211`）；socket 已被占用且可连通时直接复用现有 shim（:164-165 返回 `ErrAlreadyExists` + 既有地址）。sandbox 场景由 `core/runtime/v2/shim_manager.go:209-274` 决定"新起 shim 还是加入既有 shim"（shim 版本 ≥3 才支持 sandbox API，:271-274）。

引导进程与常驻进程的分工可总结为一条时间线：

1. containerd exec shim 二进制 `start` 子命令（`binary.go:66-83`），stdin 给 BootstrapParams；
2. start 进程创建 socket、确定分组，**exec 自身**为常驻 daemon 并传 listen fd（`manager_linux.go:196-265`）；
3. start 进程等常驻进程可连后（Windows 才需要 awaitPipeReady，`pkg/shim/shim.go:299-305`），把 BootstrapResult 写 stdout 退出；
4. 常驻进程跑插件图、注册 TaskService，阻塞在 reap/signal 循环（`pkg/shim/shim.go:360-445,504`），此后 containerd 只与它保持 ttrpc 长连接。

另外，启动顺序上 shim 在 rootfs 挂载激活之前就已存在（`task_manager.go:188-210`，注释：起 shim 不需要 rootfs，只有 task.Create 消费 Rootfs），因此 shim 有机会在 Create 前上报自己支持的挂载类型与变换（mount activation 机制）。

### 2.5 shim 断连与收尸

ttrpc onClose 回调触发 `cleanupAfterDeadShim`（`core/runtime/v2/shim_manager.go:297-306` 注册 → `core/runtime/v2/shim.go:146-196`）：用 `shim-binary-path` 重新 exec `shim delete`（binary.Delete，`binary.go:154-216`，stdout 返回 DeleteResponse proto），并补发 TaskExit/TaskDelete 事件（`shim.go:182-195`）。

```go
// core/runtime/v2/shim.go:182-195（节选）
events.Publish(ctx, runtime.TaskExitEventTopic, &eventstypes.TaskExit{
    ContainerID: id, ID: id, Pid: pid,
    ExitStatus: exitStatus, ExitedAt: protobuf.ToTimestamp(exitedAt),
})
events.Publish(ctx, runtime.TaskDeleteEventTopic, &eventstypes.TaskDelete{ ... })
```

containerd 重启后由 `LoadExistingShims` 扫 state 目录恢复所有 shim 连接（`core/runtime/v2/shim_load.go:39` → loadShims :66 → loadShim :128，恢复时用 `AnonReconnectDialer`，`core/runtime/v2/shim.go:80-144`）。恢复路径同样先开 `log` FIFO 同步 shim 日志（`shim.go:87-109`），再读 `bootstrap.json` 建连（:116-124）。新起（AnonDialer，容忍 socket 尚未出现）与重连（fail-fast）两种拨号行为在 `makeConnection` 文档注释中明确区分（`shim.go:363-368`）。

## 3. bundle 专节：目录结构与各文件角色

`NewBundle`（`core/runtime/v2/bundle.go:50-133`）在两个根下建目录：state 根（`/run/containerd/`，bundle.Path = state/ns/id，:59-64）与 work 根（rootDir/ns/id，:59），bundle 下放软链指回 work（:106）。

```
/run/containerd/<ns>/<id>/          ← bundle.Path（state，短路径）
├── config.json        OCI spec，NewBundle 写入（bundle.go:125-126, oci.ConfigFilename）
├── rootfs/            容器根fs挂载点（bundle.go:90-93 建目录；runc 侧 mount.All, runc/container.go:120）
├── work -> /var/lib/containerd/.../<ns>/<id>/   软链（bundle.go:106）
│   └── log.json       runc 日志（process/init.go:88）
├── bootstrap.json     shim 连接参数{protocol,address,version}（binary.go:140 / shim.go:324）
├── shim-binary-path   runtime 二进制绝对路径（binary.go:125）
├── options.json       runc Options（runc/container.go:96,156-187）
├── runtime            opts.BinaryName（runc/container.go:100-102,198-201）
├── log                shim 日志 FIFO（core/runtime/v2/shim_unix.go:38）
├── init.pid / exit    pid 文件（process/utils.go:44）/ 退出状态（runc/util.go:71）
└── <plugin URI>/      shim 插件 state 目录（pkg/shim/shim.go:372）
```

要点：`bootstrap.json` 是 containerd 重启后"找回活 shim"的凭据；删除 bundle 是先递归 umount rootfs、再 rename 成隐藏目录后删除的原子流程（`bundle.go:146-184`，atomicDelete :174-184）。

## 4. 任务 API 专节：shim 侧实现链

daemon 侧 `shimTask` 是 `TaskServiceClient` 的薄包装（`core/runtime/v2/shim.go:598-614` newShimTask），按 shim version 2/3 选 API。每条链的"daemon 侧 → shim 侧"对应关系（行号）：

| 操作 | daemon 侧 | shim 侧（task/service.go） | runc 命令 |
|---|---|---|---|
| Create | `task_manager.go:159` → `shim.go:713` shimTask.Create → `s.task.Create` :737 | `service.go:222` Create → `runc.NewContainer` :228 → `p.Create`（process/init.go:110） | `runc create --bundle`（go-runc/runc.go:203-204） |
| Start | `shim.go:807` → :808 task.Start | `service.go:295` Start → `container.Start` :316 → initState→`p.start`（process/init.go:272-275） | `runc start` |
| Kill | `shim.go:817` → task.Kill | `service.go:492` Kill → `container.Kill`（runc/container.go:413） | `runc kill [id] [sig] [--all]`（go-runc/runc.go:423-431） |
| Delete | `shim.go:644` delete → task.Delete → `waitShutdown` :690 → `ShimInstance.Delete` :694（关连接+删 bundle） | `service.go:353` Delete → `container.Delete` :358；发 TaskDelete :367 | `runc delete`（go-runc/runc.go:397-404） |
| Wait | `shim.go:890` → 先 PID(Connect) :891-894 再 task.Wait :895 | `service.go:575` Wait → `p.Wait` :585（纯内存 channel 等待） | 无（shim reaper 通告退出） |
| State | `shim.go:952` | `service.go:420`（状态机 created/running/paused/stopped） | `runc state`（go-runc/runc.go:122） |
| Shutdown | `shim.go:616` | `service.go:607`：还有容器则 no-op :612-614，否则触发退出 :618 | — |

Create 的细节值得展开：shim 侧 Create 只让 `runc create` 产出 **paused 的 init 进程**并读 pid 文件（`process/init.go:149-178`），即 `CreateTaskResponse.Pid`（`service.go:284-286`）；真正的用户进程要等 Start 的 `runc start`。退出收养由 shim 的 `processExits` 循环完成（`service.go:658-695`，`runcC.Monitor = reaper.Default` :91），init 退出走专门的 `handleInitExit`（:722-764，先 KillAll 子进程、等 exec 全退再发 init 的 TaskExit），并把退出状态写 bundle 的 `exit` 文件（`handleProcessExit` :771，`runc/util.go:71`）。

**进程状态机**：shim 内为 init/exec 进程维护显式状态机（created/running/paused/pausing/stopped），迁移集中在 `cmd/containerd-shim-runc-v2/process/init_state.go`（createdState.Start :78、runningState 的 Pause/Resume :237/:252 等），`State` RPC 只是把它映射成 proto 枚举（`task/service.go:433-445`）。Start 双重调用会被状态机拒绝（`process/init.go:265-270` 转发到 initState.Start）。

**Delete 的重试与事件去重**：daemon 侧 delete 是"task.Delete → Shutdown → 关连接 → 删 bundle"三段式（`core/runtime/v2/shim.go:644-711`）；若 task.Delete 已在 shim 成功过，结果会缓存到 shim 实例（`taskDeleteState`，`shim.go:285-291` 定义、:576-593 存取），重试 Delete 时直接返回缓存 exit，避免 ttrpc onClose 路径重复发 exit 事件（注释还点名 moby 侧也应容忍重复事件，`shim.go:660-676`）。

**超时常量**：load 5s / cleanup 5s / shutdown 3s 三个 timeout 注册（`core/runtime/v2/shim.go:63-78`），分别用于恢复 shim 连接、死后清理与 Shutdown 等待（`shim.go:626-630` waitShutdown）。

## 5. stdio 专节：FIFO 创建与输出回流

**client 侧创建 FIFO**：`cio.Creator` 在 `/run/containerd/io/<ns>/<id>` 临时目录下建 `<id>-stdin/stdout/stderr` 三个 FIFO（`pkg/cio/io_unix.go:35-55` NewFIFOSetInDir），client 端以 gRPC `CreateTaskRequest.Stdin/Stdout/Stderr` 字符串路径传给 shim（`client/container.go:240-245` → `core/runtime/v2/shim.go:718-727`）。

**shim 侧消费**（非终端路径，`cmd/containerd-shim-runc-v2/process/init.go:110-180`）：

```go
// process/init.go:149-156（节选）
if err := p.runtime.Create(ctx, r.ID, r.Bundle, opts); err != nil { ... }  // runc create
if r.Stdin != "" {
    if err := p.openStdin(r.Stdin); err != nil { ... }   // fifo.OpenFifo O_WRONLY
}
...
console, err := socket.ReceiveMaster()                    // 终端路径: init.go:160
console, err = p.Platform.CopyConsole(ctx, console, ...)  // epoll 统一 console 转发
```

- 非 TTY：`createIO` 按 stdout 的 URI scheme 分派（`process/io.go:84-132`）：`fifo`（默认）→ `runc.NewPipeIO` 造一对匿名管道供 runc 子进程用（:105-107）；`binary`/`binary-v2` → 起外部日志进程并经 ExtraFiles 喂数据（:108-109, NewBinaryIO :257-324）；`file` → 直接打开文件。随后 `copyPipes`（:134-228）把 runc 管道的输出 `io.CopyBuffer` 到 bundle 外的 stdout/stderr FIFO（:189-194 双向打开 FIFO 触发握手），stdin FIFO 以 `O_RDONLY|O_NONBLOCK` 打开灌进 runc（:213-226）。
- TTY：`runc.NewTempConsoleSocket`（`init.go:119`）由 runc 交回 console master，shim 的 Platform（单个 epoll 实例，`task/service.go:857-868` initPlatform）统一 CopyConsole 到 stdout FIFO（`init.go:160-168`）。

```go
// cmd/containerd-shim-runc-v2/process/io.go:104-109（节选）
switch u.Scheme {
case "fifo":
    pio.copy = true
    pio.io, err = runc.NewPipeIO(ioUID, ioGID, withConditionalIO(stdio))
case "binary", "binary-v2":
    pio.io, err = NewBinaryIO(ctx, id, u)
```

补充两个 stdio 细节：stdout 与 stderr 指向同一 FIFO/文件时用引用计数 writer 保证只关一次（`process/io.go:196-207` countingWriteCloser）；`binary-v2` 日志进程必须向继承的管道写一个字节表示 ready，否则 Create 失败（:307-317），防止日志静默丢失。

**回流路径**：容器进程 → runc 管道 → shim goroutine 拷贝 → bundle 外 FIFO → client（dockerd）已在 FIFO 读端 `io.CopyBuffer` 到用户终端/日志驱动（`pkg/cio/io_unix.go:57-105` copyIO）。所以 `docker logs` 的实时性取决于两级拷贝，containerd daemon 主体不碰字节流。

## 6. OOM/事件专节：事件回传通道与 OOM 监控

**事件回路**：shim 里的 `RemoteEventsPublisher` 用 `TTRPC_ADDRESS` 环境变量反连 containerd 的 ttrpc events 服务（`pkg/shim/publisher.go:59-78` NewPublisher → `ttrpcutil.NewClient`；发布 `:127-152` Publish 组 Envelope；`:154-188` forwardRequest 调 `v1.Forward`，失败重连+退避重试，队列 2048、最多重排 5 次 `:35-38,102-115`）。containerd 侧由 `plugins/services/events/service.go:81` 注册 `RegisterTTRPCEventsService` 接收并进 exchange。TaskCreate/TaskStart/TaskExit 等都先进 shim 内存 channel（`task/service.go:706-711` send），由 `forward` goroutine 统一发布（`:818-843`）。Envelope 自带 namespace/topic/timestamp/event（anyurl 引用 typeurl 注册类型），事件对象在 `api/events` 下定义。

shim 日志则是另一条独立链路（不要与事件混淆）：bundle 下的 `log` FIFO，containerd 在启动/加载 shim 时打开并 `io.Copy` 到自己 stderr（`binary.go:92-114`；恢复路径 `core/runtime/v2/shim.go:87-109`），shim 侧 `OpenFifoDup2` 把 logrus 输出 dup2 到该 FIFO（`pkg/shim/shim_unix.go:110-112`）。

**OOM 监控（每容器）**，在 Create 内尽早挂上（`task/service.go:251-276`，注释明确：init 在 cgroup 内 paused 时就可能 OOM）：

- cgroup v1：`oomv1.New(publisher)` + epoll 循环（`task/service.go:68-74`；`pkg/oom/v1` 实现）。
- cgroup v2：`oomv2.New()`（`task/service.go:80` cg2oom），Add 时用 inotify 盯 `memory.events`：`InotifyInit1(IN_NONBLOCK)` + `InotifyAddWatch(..., IN_MODIFY)`（`internal/oom/utils.go:33-47`），goroutine 读事件后解析 `memory.events` 的 `oom_kill` 计数，计数增长即回调（`internal/oom/watcher.go:102-141`，:128 读文件、:136-139 比较）。回调 `oomEvent` 发布 `TaskOOM`（`task/service.go:697-704`），容器删除时 `cg2oom.Stop`（:778）。

另有一处防呆：shim 进程自身会调 `AdjustOOMScore` 调低被杀概率（`manager_linux.go:292`）。forkloop/PdeathSignal：shim 为 init 进程设 `PdeathSignal: SIGKILL`（`process/init.go:90`），shim 死则容器进程被内核带走。

## 7. 设计动机

1. **每容器（组）一个 shim 进程**：容器 init 退出的 `waitpid` 只能由其祖先做，shim 以 subreaper 身份常驻保证"状态活在不朽进程里"——containerd 重启/升级都不影响运行中容器（`bootstrap.json` + LoadExistingShims 重连即可，`core/runtime/v2/shim_load.go:39`）。runc 是一次性 CLI，无法承载 Wait/Exec 等长生命周期 API，shim 补上了这一层；Pod 内多容器共享一个 shim（分组标签，`manager_linux.go:67-70`）折衷了进程数与隔离度。
2. **崩溃/升级隔离**：shim 被 OOM-kill 或手杀时，daemon 侧 ttrpc onClose 立即感知并用 `shim-binary-path` 重放 `shim delete` 收尸补事件（`binary.go:125,154`；`shim.go:146-196`），故障域收敛到单容器。
3. **TTRPC 而非 gRPC**：ttrpc 复用 gRPC 语义但省掉 HTTP/2 栈，单 shim `GOMAXPROCS=2`（`pkg/shim/shim.go:157-161`）即可低成本服务一条 unix socket；事件 Forward 用 ttrpc 单连接（`publisher.go`）。协议字段仍预留 `grpc+vsock`（`makeConnection` 双协议分派，`core/runtime/v2/shim.go:376-401`），为虚机级 runtime 留路。
4. **stdio 走 FIFO**：FIFO 是跨进程、可被路径传递、无 daemon 中转的字节流汇点——client 创建、shim 消费，路径就是寻址方式；shim 死了 FIFO 里未读数据不丢、dockerd attach 生命周期与 shim 解耦；TTY 时由 epoll Platform 统一拷贝（`service.go:857-868`），避免每容器一个 epoll。
5. **binary call + Bootstrap 协议**：start/delete 用"exec + stdin/stdout proto"一次性引导（`command.go:129-156`），保证协议版本协商与地址交换发生在受控的一次进程调用内，之后才切到长连接；`bootstrap.json` 落盘让恢复路径无需重新引导。

## 8. FAQ 素材与深挖

### FAQ 素材

1. shim 进程在 `ps` 里显示的 cwd 为什么是 bundle？——`command.go:102` 把 cmd.Dir 设为 bundle.Path，serve 时 `os.Getwd()` 也用它（`pkg/shim/shim.go:470`）。
2. containerd 重启后为什么容器没死、还能 exec？——shim 常驻 + `bootstrap.json` 恢复连接（`binary.go:140`；`shim_load.go:39`）。
3. `bootstrap.json` 与旧 `address` 文件什么关系？——新协议凭据，老 shim 靠 `restoreBootstrapParams` 迁移（`shim_manager.go:392-420`）。
4. Create 返回的 Pid 是什么？——`runc create` 产出的 paused init 进程 pid（`process/init.go:174-178`），不是已运行进程。
5. shim 死了会发生什么？——onClose → `shim delete` 收尸 + 补发 TaskExit/TaskDelete（`shim.go:146-196`），exit status 兜底 255。
6. 事件是怎么回到 `ctr events` 的？——shim ttrpc Forward 到 containerd events exchange（`publisher.go:154-188`；`plugins/services/events/service.go:81`），不是 binary log 协议（那是 shim 日志：bundle 的 `log` FIFO）。
7. 为什么有时一个 Pod 只有一个 shim 进程？——分组标签复用 socket（`manager_linux.go:200-233`）。
8. `docker logs` 的字节经过 containerd 吗？——不经过，路径是 容器→runc管道→shim 拷贝→FIFO→client（第 5 节）。
9. Kill 之后容器进程谁 reap？——shim 的 SIGCHLD reaper（`pkg/shim/shim_unix.go:84-87`）+ `processExits`（`task/service.go:658`）。
10. ShimPid 与 TaskPid 区别？——`Connect` 返回 shim 自身 pid 和 init pid（`task/service.go:596-605`）。
11. 为什么要 `MAX_SHIM_VERSION`/版本协商？——2.3 引入 Bootstrap 协议与 streaming IO（shim 版本 3），daemon 据此决定走新协议还是老 exec 约定（`command.go:44,106`；`shim_manager.go:261-274`）。
12. shim 里的 `options.json`/`runtime` 文件是谁写的？——shim 侧 NewContainer 落盘 runc Options 与 BinaryName（`runc/container.go:96-102`），供恢复/调试读取（ReadOptions/ReadRuntime :160-201）。
13. 为什么 shim 要 `Setpgid`/子进程组？——引导进程启动常驻进程时 `Setpgid: true`（`manager_linux.go:110-112`），配合 sched_core 进程组（:247-251）。

### 深挖方向

1. `binary-v2` 日志协议就绪握手：logging 二进制需向继承 fd 写一个字节才算 ready（`process/io.go:307-317`）。
2. `clientVersionDowngrader`：2.x 对 1.7 遗留 Pod shim 的 v3→v2 API 降级重试（`core/runtime/v2/task_manager.go:225-245`；`shim.go:268-283`）。
3. init 退出与 exec 退出的顺序不变量：TaskExit 必须最后发（`task/service.go:713-764` handleInitExit 的 exec 计数等待）。
4. socket 路径 104/108 限制的应对：`maxSocketDirLen=38/42` 与多级候选目录（`core/runtime/v2/socket_unix.go:27`；`socket_linux.go:25`；`shim_unix.go:52-92`）。
5. TaskManager.Create 中"先起 shim、后激活 rootfs 挂载"的顺序及其回滚链（`task_manager.go:177-217`，注释解释 shim 需先上报自身挂载能力）。
6. shim 作为 subreaper 的收养语义：`subreaper()` PR_SET_CHILD_SUBREAPER（`pkg/shim/shim_linux.go:29`），SIGCHLD→reaper.Reap（`pkg/shim/shim_unix.go:84-87`），这是"shim 进程不死则容器状态不丢"的内核基础。

## 写作要点速查表

| # | 关键事实 | 位置 |
|---|---|---|
| 1 | TaskManager.Create：NewBundle→Start shim→shimTask.Create | core/runtime/v2/task_manager.go:159,160,192,226 |
| 2 | ShimManager.Start（sandbox 复用 vs 新起；版本≥3 才支持 sandbox API） | core/runtime/v2/shim_manager.go:205,271-274,318 |
| 3 | binary.Start：exec start + log FIFO + 解析 BootstrapResult + 写 bootstrap.json | core/runtime/v2/binary.go:66,92,115,125,129,140 |
| 4 | Bootstrap 协议：params 走 stdin，结果走 stdout | core/runtime/v2/command.go:129-155；pkg/shim/shim.go:275,307-314 |
| 5 | shim 常驻进程从 fd3 建 ttrpc listener | pkg/shim/shim_unix.go:52-71；pkg/shim/shim.go:475 |
| 6 | Pod 分组标签与 socket 复用 | cmd/containerd-shim-runc-v2/manager/manager_linux.go:67-70,200-233 |
| 7 | NewBundle 目录：rootfs/work 软链/config.json | core/runtime/v2/bundle.go:50,90-93,106,125-126 |
| 8 | shimTask 各 API（Create/Start/Kill/Delete/Wait） | core/runtime/v2/shim.go:713,807,817,644,890 |
| 9 | shim 侧 Task service：Create 里挂 OOM、Start 发 TaskStart | cmd/containerd-shim-runc-v2/task/service.go:222,251-276,295 |
| 10 | runc create/--bundle 与 PdeathSignal | vendor/.../go-runc/runc.go:203-204；process/init.go:82-94,149 |
| 11 | 非 TTY stdio：createIO 分派 fifo/binary/file | cmd/containerd-shim-runc-v2/process/io.go:84-132,134-228 |
| 12 | TTY：TempConsoleSocket + epoll CopyConsole | process/init.go:119,160-168；task/service.go:857-868 |
| 13 | shim 日志 FIFO：bundle/log | core/runtime/v2/shim_unix.go:37-39；pkg/shim/shim_unix.go:110-112 |
| 14 | 事件 Forward 回路 | pkg/shim/publisher.go:59,127,154-188；plugins/services/events/service.go:81 |
| 15 | OOM v2：inotify memory.events + oom_kill 计数 | internal/oom/utils.go:33-47；internal/oom/watcher.go:102-141 |
| 16 | 死 shim 收尸：shim-binary-path 重放 delete + 补事件 | binary.go:125,154-216；core/runtime/v2/shim.go:146-196 |
| 17 | 断线恢复：LoadExistingShims/restoreBootstrapParams | core/runtime/v2/shim_load.go:39；shim_manager.go:392-420 |
| 18 | 客户端 FIFO 创建 | pkg/cio/io_unix.go:35-55,106-137 |
| 19 | Create 链路 daemon 侧入口 | client/container.go:226,297；plugins/services/tasks/local.go:171,277 |
| 20 | Shutdown 语义：有容器则 no-op | cmd/containerd-shim-runc-v2/task/service.go:607-621 |
