# G · CRI 插件：kubelet 与 containerd 的正式接口

> 源码版本：containerd 2.x 主干，commit `f6132db`。本文所有行号以该 commit 为准。
> 路径说明：2.x 中 CRI 实现已从 `plugins/cri/server` 迁入 `internal/cri/`；`plugins/cri/` 只剩薄薄的插件注册层（`plugins/cri/cri.go` + `runtime/` + `images/` 三个入口），沙箱逻辑拆到 `internal/cri/server/podsandbox/`（1.x 的 `pod_sandbox.go` 对应今天的 `sandbox_run.go` + `podsandbox/` 包）。本文按新布局标注。

## 1. 全景：kubelet→CRI→containerd→shim→runc 调用链

```
kubelet (kubelet/kuberuntime)
   │  gRPC (CRI api.proto: RuntimeService + ImageService)
   ▼
containerd daemon ── plugins/cri/cri.go:47-69 注册 GRPCPlugin "cri"
   │  ├─ RuntimeService  : RunPodSandbox/CreateContainer/Start/Stop/Exec/...（cri.go:211）
   │  ├─ ImageService    : PullImage/ListImages/RemoveImage/ImageFsInfo（cri.go:212）
   │  └─ instrument 层包一层 metrics/tracing（cri.go:210, internal/cri/instrument/）
   ▼
internal/cri/server/  — CRI 语义层（pod/容器状态机、CNI、日志、事件）
   │  内存 store: sandboxStore/containerStore/imageStore（service.go:135-143）
   │  持久 store: containerd metadata(bolt) 的 sandbox/container 记录 + 本地 checkpoint 文件
   ▼
containerd core（client 走 in-memory services，命名空间 k8s.io，cri.go:118-123）
   │  ├─ ContainerStore/TaskService/SandboxStore/Leases（bolt 元数据）
   │  ├─ Snapshotter（rootfs）  └─ ContentStore（镜像 blob）
   ▼
runtime/v2 shim（io.containerd.runc.v2 等，由 container_create.go:387 WithRuntime 指定）
   │  每容器一个 shim 进程：管 stdio/exit/挂载命名空间宿主侧
   ▼
runc create/start → 容器进程（cgroup+namespace 由 OCI spec 决定）
```

关键点：CRI 插件是 containerd 内部的一个 GRPCPlugin（`plugins/cri/cri.go:49-68`），它通过 `containerd.New(..., WithInMemoryServices(ic))` 直接复用同一进程内的 containerd 服务，不走 socket（`cri.go:118-123`）；kubelet 只跟 CRI gRPC 说话，永远看不到 containerd 原生 API。CRI 双服务注册在同一个 gRPC server 上（`cri.go:209-214`），还可选开 TCP 端口（`cri.go:187-191`，默认关）。

服务启动时序：`initCRIService`（cri.go:71）→ `server.NewCRIService`（service.go:208）→ goroutine `s.Run(ready)`（cri.go:172-178）。`Run` 里做四件事：订阅 `/tasks/oom` 与 `/images/` 事件（service.go:302）、启动恢复 `c.recover`（service.go:318，实现在 restart.go:55）、起 eventMonitor 与 CNI conf 同步器（service.go:324-347）、起流式服务器（service.go:350-358），最后 `initialized.Store(true)` 放行 gRPC 流量（service.go:366）。

## 2. pod 语义：RunPodSandbox 与 infra 容器

### 2.1 RunPodSandbox 流程（行号链）

入口 `internal/cri/server/sandbox_run.go:54`。K8s 的"启动 Pod"在这条函数里被翻译成宿主机上的一组资源：

1. **生成 ID/预留名字**：`util.GenerateID()`（sandbox_run.go:64），`makeSandboxName`（sandbox_run.go:69 → helpers.go:119），名字写入 registrar 防并发（sandbox_run.go:85）。
2. **建 lease**：以 sandbox ID 建 lease 防止资源被 GC（sandbox_run.go:96-100）。
3. **选 runtime**：`config.GetSandboxRuntime(config, runtimeHandler)`（sandbox_run.go:117 → config.go:732；untrusted 注解走 untrusted runtime，config.go:733-750）。选出的 `ociRuntime.Sandboxer` 决定走哪条沙箱通道（sandbox_run.go:122-123）。
4. **写 containerd sandbox store**：`SandboxStore().Create`（sandbox_run.go:161），CRI 自己的 Metadata 挂在 extension 里（sandbox_run.go:157，`podsandbox.MetadataKey`）。这是"宿主侧沙箱"元数据的持久层。
5. **网络命名空间**：非 hostNetwork 时 `netns.NewNetNS` 在 `/var/run/netns` 建宿主侧 netns（sandbox_run.go:203-218），然后 `setupPodNetwork` 调 CNI 插件组网（sandbox_run.go:266 → 456-527；`netPlugin.Setup` 在 500-504），把 Pod IP 缓存进 sandbox（sandbox_run.go:515-518，避免每次 Status 都进 netns 查 IP，注释见 258-265）。端口映射/带宽/DNS 作为 CNI capability 传入（sandbox_run.go:530-561）。
6. **预拉 pause 镜像**：`ensurePauseImageExists`（sandbox_run.go:298-299，实现 416-438；默认 `registry.k8s.io/pause:3.10.2`，config.go:76）。注释明说是 HACK：本应归 sandbox 实现管，但为了兼容"大家都依赖 pause 容器"的现状由 CRI 层代拉（sandbox_run.go:285-297）。
7. **Create+Start 沙箱**：`sandboxService.CreateSandbox`（sandbox_run.go:281）→ `StartSandbox`（sandbox_run.go:307）。
8. **收尾**：记录 PID（sandbox_run.go:353-359）、NRI 钩子（361-374）、状态置 `StateReady`（376-382）、加入内存 store（385-387）、发 CONTAINER_CREATED/STARTED 事件给 kubelet（394、409）、挂 exit 监视（396-406）。

### 2.2 sandbox 容器（infra/pause 容器）的角色

默认 sandboxer 是 `podsandbox`（config.go:677-679 自动补默认值），实现在 `internal/cri/server/podsandbox/`（controller.go:45-107 注册 `PodSandboxPlugin`）。`Controller.Start`（podsandbox/sandbox_run.go:61）里能看到 pause 容器的全部特殊性：

- **跑的是 pause 镜像**：`getSandboxImageName`（podsandbox/sandbox_run.go:352-360），取 `pinned_images["sandbox"]` 或默认 pause。
- **rootfs 只读、无 side effects**：`WithRootFSReadonly`（podsandbox/sandbox_run_linux.go:49）。
- **持有 Pod 级 cgroup**：`kubelet 的 cgroupParent → WithCgroup`（podsandbox/sandbox_run_linux.go:63-66），它就是 Pod cgroup 层级的锚点。
- **持有 Pod 网络命名空间**：netns 以路径形式挂进 OCI spec（podsandbox/sandbox_run_linux.go:77-86；hostNetwork 则干脆去掉 net/uts namespace）。
- **贡献 /etc/hosts、/etc/hostname、resolv.conf、/dev/shm**：`setupSandboxFiles`（podsandbox/sandbox_run.go:231）+ spec 里的 bind mount（podsandbox/sandbox_run_linux.go:121-144）。
- **资源份额极小**：`WithDefaultSandboxShares`（podsandbox/sandbox_run_linux.go:195）、固定低 OOM 分值（205）。
- **不接 stdio**：`container.NewTask(ctx, containerdio.NullIO)`（podsandbox/sandbox_run.go:258），业务容器不共享它的 rootfs——它只"占着"namespace 和 cgroup。
- 创建→启动全程走 containerd 原生 API：`client.NewContainer`（214）→ `NewTask`（258）→ `task.Start`（300），随后置 `StateReady`（304-311）。

业务容器"加入 Pod"的方式在创建业务容器时揭晓：network/IPC/UTS namespace 直接用 `/proc/<sandboxPid>/ns/{net,ipc,uts}` 路径（`internal/cri/opts/spec_opts.go:349-359`，PID namespace 缺省也指到 sandboxPid，shareProcessNamespace 时才共享）；这就是为什么 pause 容器必须先活着的——它是 Pod 内所有容器 namespace 的宿主。

```go
// internal/cri/opts/spec_opts.go:348-361
func WithPodNamespaces(config *runtime.LinuxContainerSecurityContext,
    sandboxPid uint32, targetPid uint32, uids, gids []runtimespec.LinuxIDMapping) oci.SpecOpts {
    namespaces := config.GetNamespaceOptions()
    opts := []oci.SpecOpts{
        oci.WithLinuxNamespace(runtimespec.LinuxNamespace{Type: runtimespec.NetworkNamespace, Path: GetNetworkNamespace(sandboxPid)}),
        oci.WithLinuxNamespace(runtimespec.LinuxNamespace{Type: runtimespec.IPCNamespace, Path: GetIPCNamespace(sandboxPid)}),
        oci.WithLinuxNamespace(runtimespec.LinuxNamespace{Type: runtimespec.UTSNamespace, Path: GetUTSNamespace(sandboxPid)}),
    }
    if namespaces.GetPid() != runtime.NamespaceMode_CONTAINER {
        opts = append(opts, oci.WithLinuxNamespace(runtimespec.LinuxNamespace{
            Type: runtimespec.PIDNamespace, Path: GetPIDNamespace(targetPid)}))
    }
    ...
```

namespace 路径的拼法就是 `/proc/<pid>/ns/<type>`（spec_opts.go:396-412 的 `Get*Namespace` 函数族）。沙箱退出（pause 容器死掉）时所有业务容器的 netns 一起失效——这正是 kubelet 把 Pod 整体重建的原因之一；containerd 侧对应 `handleSandboxExit`（events.go:104-117）把 sandbox 置 `StateNotReady` 并发 CONTAINER_STOPPED_EVENT。

### 2.3 配置面：runtime handler、网络插件与沙箱模式

CRI 配置经三个子插件分别校验装载（runtime: `plugins/cri/runtime/plugin.go:47-56`；images: `plugins/cri/images/plugin.go:45-58`；顶层聚合: `plugins/cri/cri.go:65-68`），核心结构在 `internal/cri/config/config.go`：

- **Runtime（每个 runtime handler 一份，config.go:85-139）**：`runtime_type` 选 shim（87）、`snapshotter` 运行时级快照器（122）、`sandboxer` 沙箱模式（127）、`disable_pause_image_pull`（133）、`io_type` 容器 IO 走 FIFO 或 streaming（138）、`cni_conf_dir/cni_max_conf_num` 按 RuntimeClass 分网络（112-117）、`base_runtime_spec` 共享基础 spec（110-111）。
- **handler 选择**：`GetSandboxRuntime`（config.go:732-759）——untrusted 注解强制走 `untrusted` handler（733-750），空 handler 落到 `default_runtime_name`（752-754），找不到即报错（756-759）。每个 handler 的能力（rro 挂载、userns）由启动时 shim 内省得到并上报 kubelet（service.go:425-459）。
- **网络插件**：默认全局一份 CNI（`defaultNetworkPlugin`，service.go:67），RuntimeClass 可覆盖；conf 目录变更由 `cniNetConfSyncer` 监听热加载（service.go:258-273、327-347）。
- **沙箱模式**：`sandboxer` 留空自动补 `podsandbox`（config.go:677-679）；可显式配 `shim` 把沙箱创建外包给 shim 实现（见 2.4）。

### 2.4 宿主侧沙箱模式（新）

`Runtime.Sandboxer` 字段（config.go:123-127）有两种取值：`podsandbox`（宿主侧 Controller，即上面那条路径，2.0 起默认）与 `shim`（由 shim 自己实现 `sandbox.Controller`，如 Windows HCS、 illusions 等 VM 运行时）。两类控制器在 cri.go:258-276 统一收进 `map[string]sandbox.Controller`。`disable_pause_image_pull = true` 时 shim 型沙箱自管 pause 镜像（config.go:128-133，调用点 sandbox_run.go:298-305）——这条是"去 pause 化"的渐进出口。

## 3. 容器生命周期：CRI → containerd API 映射

### 3.1 CreateContainer

入口 `internal/cri/server/container_create.go:59`：

1. 校验 sandbox 就绪：`sandboxStore.Get`（container_create.go:64）+ `SandboxStatus` 拿真实 sandboxID/PID（69-77），sandbox 非 Ready 直接拒绝（78-80）。
2. 生成容器 ID/预留名字（88、103），拼 CRI 容器名 `k8s_<container>_<pod>_<ns>_<uid>_<attempt>`（98 → helpers.go:131）。
3. 解析镜像：`LocalResolve` → `toContainerdImage`（131-138），镜像必须已 Pull。
4. 生成 OCI spec：`buildLinuxSpec`（679 起）注入 env/hostname/mounts，业务容器 binds sandbox 的 /etc/hosts 等（`linuxContainerMounts`，1089 起）；`runtimeSpec`（510）可叠加 `base_runtime_spec`（RuntimeService 接口 `LoadOCISpec`，service.go:97）。
5. 组装 `NewContainerOpts` 并落库（container_create.go:313-408）：

```go
opts := []containerd.NewContainerOpts{
    containerd.WithSnapshotter(c.RuntimeSnapshotter(r.ctx, ociRuntime)), // 314
    customopts.WithNewSnapshot(r.containerID, *r.containerdImage, ...),  // 320 预建 rootfs
    ...
    containerd.WithSpec(spec, specOpts...),                              // 386
    containerd.WithRuntime(runtimeName, runtimeOption),                  // 387 继承 sandbox 的 shim
    containerd.WithContainerLabels(containerLabels),                     // 388 kind=container
    containerd.WithContainerExtension(crilabels.ContainerMetadataExtension, r.meta), // 389
}
opts = append(opts, containerd.WithSandbox(r.sandboxID))                 // 392
cntr, err = c.client.NewContainer(r.ctx, r.containerID, opts...)         // 406
```

注意 CreateContainer 只建"容器对象+rootfs 快照"，**不建 task**（task 在 Start 才建，见 C 卷对照：containerd 里 container 与 task 分离）。

### 3.2 StartContainer

入口 `internal/cri/server/container_start.go:41`：

1. `containerStore.Get`（44）→ `setContainerStarting` 占住状态防并发 start/remove（61、213-229）。
2. 再查 sandbox Ready（84-91）。
3. `container.NewTask`（138，真正的 shim task 在这创建）→ `task.Wait`（154）→ `task.Start`（179）。
4. 成功后 `Status.UpdateSync` 写 PID/StartedAt（184-190），挂 exit 监视（193），向 kubelet 发 CONTAINER_STARTED_EVENT（195），NRI PostStart 钩子（197）。
5. 日志：stdout/stderr 经 FIFO 由 `createContainerLoggers` 写入 `meta.LogPath`（95 → 241-275，按 CRI 格式切行，255）。

Stop/Remove：`StopContainer`（container_stop.go:40）先 SIGTERM 等 timeout 再 kill（112 起）；`RemoveContainer`（container_remove.go:34）强停后 `Container.Delete(ctx, WithSnapshotCleanup)` 连快照一起删（107）。

### 3.3 Pod 级回收：StopPodSandbox / RemovePodSandbox

`StopPodSandbox`（sandbox_stop.go:35）按 CRI 规范必须幂等——sandbox 已不存在时直接返回空响应（sandbox_stop.go:38-46，注释引用了 cri-api proto 的幂等条款）。真正干活的 `stopPodSandbox`（sandbox_stop.go:60）顺序非常讲究：

1. 遍历内存 containerStore，把该 Pod 下所有容器以 **timeout=0** 强杀（sandbox_stop.go:67-79；绕过 `StopContainer` 以避免 list-then-remove 竞态，见注释）。
2. sandbox 处于 Ready/Unknown 时调 `sandboxService.StopSandbox` 停 pause 容器（sandbox_stop.go:81-91）。
3. 拆 CNI 网络 `teardownPodNetwork`（sandbox_stop.go:154 起；调用点 113-129），netns 已关闭则置空路径走 CNI 规范的空 netns 语义（118-121）。
4. 清理 sandbox 的 image mount（135）。

`RemovePodSandbox`（sandbox_remove.go:34）同样幂等（40-46），在强制复用 `stopPodSandbox`（59）之后：删 lease（63）、等 netns 关闭（68-75）、逐个 `RemoveContainer`（82-90，复用容器级删除以清快照与 checkpoint）、`ShutdownSandbox`（95）、发 CONTAINER_DELETED 事件（100）、删内存 store 与 core sandbox store（112-117）、释放名字（122）。kubelet 的 syncPod 驱动这条链，因此 Pod 的最终回收权在 kubelet 手里，containerd 只保证每一步幂等可重入。`StopPodSandbox`（sandbox_stop.go:35）会先以 0 超时强杀 Pod 内全部容器（sandbox_stop.go:67-79），再停沙箱、拆 CNI 网络（113-134）；`RemovePodSandbox`（sandbox_remove.go:34）依次删 lease（62-67）、删全部容器（78-90）、`ShutdownSandbox`（95）、删两层 store（112-117）。

### 3.4 CRI 元数据存放

三层：

- **containerd bolt（持久）**：容器对象的 extension 里存 `containerd.io.cri.container.metadata` = CRI `Metadata{ID,Name,SandboxID,Config…}` JSON（container_create.go:389；常量定义 `internal/cri/labels/labels.go:56-59`；typeurl 注册 container_create.go:53-56）。sandbox 侧对应 `podsandbox.MetadataKey` extension + core sandbox store 记录（sandbox_run.go:157-163）。
- **本地 checkpoint 文件**：容器运行时状态（PID/时间戳/退出码/资源限制）以 JSON 写 `<root>/containers/<id>/status`，`continuity.AtomicWriteFile` 原子替换（`internal/cri/store/container/status.go:167-180`；UpdateSync 271-287；LoadStatus 184-195）。root 目录即 `io.containerd.grpc.v1.cri`（plugins/cri/runtime/plugin.go:80-81）。
- **内存索引**：`containerStore`/`sandboxStore`（service.go:135、140）+ 名字 registrar（service.go:138、143），重启后由 restart.go 重建（见第 5 节）。

## 4. 镜像服务：PullImage 与 kubelet 驱动的 GC

### 4.1 CRI 视角的 PullImage

gRPC 入口 `internal/cri/server/images/image_pull.go:101`（从请求闭包构造认证函数 105-114），核心 `CRIImageService.PullImage`（123）：

```go
namedRef, err := distribution.ParseDockerRef(name)          // 153 规范化引用
snapshotter, err := c.snapshotterFromPodSandboxConfig(...)  // 168 runtime 级 snapshotter
if c.config.UseLocalImagePull {                             // 187
    image, ... = c.pullImageWithLocalPull(...)              // 188 client.Pull 老路径
} else {
    image, ... = c.pullImageWithTransferService(...)        // 190 transfer service，2.x 默认
}
configDesc, _ := image.Config(ctx)                          // 199
imageID := configDesc.Digest.String()                       // 203 返回值就是 image config digest
for _, r := range []string{imageID, repoTag, repoDigest} {  // 207
    c.createOrUpdateImageReference(ctx, r, ...)             // 211 打 CRI 管理标记
    c.imageStore.Update(ctx, r)                             // 218 同步内存索引
}
return imageID, nil                                         // 238
```

CRI 的镜像服务是 containerd 镜像数据的"过滤视图"：拉完后同时登记 imageID/tag/repoDigest 三个引用（207-221），并维护自己的内存 imageStore（`internal/cri/store/image/image.go:99` Update）。snapshotter 选择可被 Pod annotation 或 runtime handler 覆写（869 起；runtime 配置向 image 服务传播见 plugins/cri/cri.go:90-101）。拉取超时由 `image_pull_progress_timeout` 控制，默认 5 分钟（config.go:43-63，注释解释了从 dockershim 的 1m 调整为 5m 的原因）。

### 4.2 GC 协同：containerd 只供数，kubelet 决策

containerd CRI **没有**自己的镜像驱逐策略，GC 完全是 kubelet 驱动的闭环：

1. kubelet 周期调 `ImageFsInfo`（imagefs_info.go:30）拿镜像文件系统用量。返回按 snapshotter 分组、由 snapshot store 汇总 Size/Inodes（34-50），并且注释明说"kubelet 只取数组第一项"，所以默认 snapshotter 必须排第一（54-63）。
2. kubelet 按自己的 `ImageGCHighThresholdPercent/LowThresholdPercent` 计算要删多少，按 LRU+in-use 规则选镜像，逐个调 `RemoveImage`（image_remove.go:36/44）。containerd 侧删掉该镜像全部引用，最后一个引用 `SynchronousDelete()` 同步删以触发内容/快照 GC（image_remove.go:58-66）。
3. kubelet 的容器级 GC（退出容器上限）对应 `RemoveContainer`；Pod 级回收对应 `RemovePodSandbox`。

containerd 自己唯一的"巡检"是启动/配置重载时的 `CheckImages`（check.go:32）：校验内容完整性、是否 unpacked、刷新内存索引——只记日志不删除（29-31 注释），与 GC 无关。

## 5. 状态专节：Status 从哪里组装

**PodSandboxStatus**（`internal/cri/server/sandbox_status.go:33`）：

- 元数据（ID/Pod 名/labels/annotations/RuntimeHandler）：内存 `sandboxStore` 的 Metadata（34、145-174 `toCRISandboxStatus`）。
- 状态/创建时间/verbose info：`sandboxService.SandboxStatus` 问沙箱控制器（49）；控制器 NotFound（shim 崩溃）时降级为 `SANDBOX_NOTREADY` 而不是报错（51-68 注释，这正是 kubelet 期望的语义）。
- Pod IP：读 RunPodSandbox 时缓存的 CNI 结果 + netns 存活检查（39 → 98-114；hostNetwork 返回空 103-105）。
- CreatedAt 兜底：core sandbox store 的 CreatedAt（83-90）。
- 沙箱自己没有磁盘 checkpoint：状态在内存 Status + core sandbox store extension，重启后由 `podsandbox/recover.go:51 RecoverContainer` 从容器 extension 重建（含 UpdatedResources extension，65-77）。

**ContainerStatus**（`internal/cri/server/container_status.go:34`）：

- 元数据/日志路径/挂载：CRI Metadata（140-160 组装，字段全部来自 `meta.Config`）。
- 运行态：内存 Status 三时间戳推出五态机——`Status.State()` 用 FinishedAt/StartedAt/CreatedAt 是否非零依次判定 EXITED/RUNNING/CREATED/UNKNOWN（`internal/cri/store/container/status.go:104-118`；状态机图 31-62）。状态变迁由事件驱动：TaskExit 事件 → `handleContainerExit`（events.go:173）写 FinishedAt/ExitCode（events.go:294-297）并删 task（241）；OOM 检测另查 cgroup memory 事件（194-214，注释详解了 systemd scope 的竞态）。沙箱退出则把整个 Pod 置 NotReady（events.go:104-117）。
- CreatedAt 兜底读 containerd 容器对象（78-85）。
- verbose Info：runtime spec、snapshotKey、runtime 类型等现场数据（178-221）。

**重启恢复**：`criService.recover`（restart.go:55）按 label `kind=sandbox` / `kind=container` 列出 containerd 容器（57、175），extension 反解 Metadata（286）+ 磁盘 LoadStatus（289）重建内存 store；存量一致性由 core SandboxStore().List 交叉核对（98-114）。

## 6. 设计动机

- **为什么 K8s 抽象 Pod 而非容器**：Pod 是"共享 network/IPC/UTS namespace 与 cgroup 域的一组容器"。docker 的抽象里容器是一等公民，Pod 得靠 kubelet 拼 `docker run --network container:<id>`，infra 容器的生死、IP、日志目录都散落在外。CRI 把"沙箱"（Pod 级资源持有者）与"容器"（业务进程）做成两个独立对象（对照卷一 A：docker 只有一个 container 对象），kubelet 才能以 Pod 为单位做调度、GC 与状态同步——RunPodSandbox 一次建齐 netns+cgroup+hosts 文件，业务容器只做 `NewContainer→NewTask→Start` 三步（3.1/3.2 的行号链即是证据）。
- **为什么 CRI 是 gRPC**：接口要同时容纳 dockerd（进程外）、containerd+插件、Kata/VM 独立 runtime 等实现，必须是不绑定进程边界的稳定 IDL；gRPC 给了版本化 proto、双向流（exec/attach/port-forward、GetContainerEvents 事件流）和跨语言实现能力。kubelet 与 runtime 也可分进程/分容器部署。
- **为什么 CRI 放进 containerd 而非独立项目**：前身 cri-containerd 是独立项目（目录里 `cri-containerd` 前缀的 typeurl 注册名是化石，如 sandbox_run.go:48-50、container_create.go:54-56），1.x 合入后，CRI 可以直接用 in-memory services 访问 metadata/snapshot/content（cri.go:118-123），省掉一层自建存储和 socket 转发，pod_sandbox 的 CNI/lease/sandbox store 也只有住在 containerd 进程内才做得这么紧；代价是 CRI 语义与 containerd 内部 API 形成强耦合（这也是 2.x 把它挪进 `internal/`、并抽出 core/sandbox.Controller 接口解耦的原因）。

## 7. FAQ 素材

1. **kubelet 怎么"启动 Pod"？** 一次 RunPodSandbox + N 次 CreateContainer/StartContainer；沙箱不是 Pod 里"第一个业务容器"，而是 pause 容器（2.1/2.2）。
2. **pause 容器里跑的是什么？** pause 镜像的 entrypoint（默认 `registry.k8s.io/pause:3.10.2`，config.go:76），只读 rootfs、无 stdio，唯一工作是住着 namespace/cgroup（podsandbox/sandbox_run.go:258、sandbox_run_linux.go:49）。
3. **业务容器怎么共享 Pod 网络？** OCI spec 直接写 `/proc/<sandboxPid>/ns/net` 等 namespace 路径（opts/spec_opts.go:352-356），不是 dockerd 式 `--network container:`。
4. **Pod IP 是每次查的吗？** 不是，RunPodSandbox 时 CNI 返回后缓存，Status 直读缓存（sandbox_run.go:515-518、sandbox_status.go:39/113）。
5. **containerd 重启后 kubelet 为什么还能看到容器？** CRI 元数据在 bolt extension、运行状态在本地 checkpoint 文件、启动时 recover 重建内存 store（3.3、5、restart.go:55）。
6. **谁删镜像？** kubelet。containerd 只提供 ImageFsInfo 用量与 RemoveImage 删除；`CheckImages` 只巡检不删（4.2）。
7. **CreateContainer 为什么不启动进程？** containerd 的 container/task 分离（卷一 C），Create 只建对象+rootfs 快照，Start 才 NewTask（container_create.go:406 vs container_start.go:138）。
8. **ImagePull 返回的 ImageRef 是什么？** 镜像 config 的 digest（image_pull.go:199-204），即 `crictl image` 里的 IMAGE ID。
9. **CRI 的事件从哪来？** 订阅 containerd 事件总线 `/tasks/oom` 与 `/images/`（service.go:302），加上 CRI 自产的 ContainerEvent 事件（sandbox_run.go:394、container_start.go:195），经 `generateAndSendContainerEvent`（helpers.go:358）推给 kubelet 的 GetContainerEvents 流。
10. **一个 Pod 能用不同 runtime 吗？** 只能整 Pod 一个 handler（RuntimeHandler 在 RunPodSandbox 传入，业务容器继承 sandbox 的 runtime，container_create.go:380-387）。
11. **CNI 配置热更新怎么生效？** `cniNetConfSyncer` 用 fsnotify 监听 conf 目录，变更即 reload（internal/cri/server/cni_conf_syncer.go:44-47, 81；Run 里 service.go:327-347 启动），新 Pod 用新配置、存量 Pod 不动。
12. **Exec/Attach/PortForward 走哪条路？** CRI 返回的是 kubelet 可访问的 streaming server URL（`streaming.NewServer`，service.go:251；配置 config.StreamingConfig，cri.go:133-136），真正的 exec 由 kubelet 反向请求该 HTTP 服务，与 gRPC 主连接分离。
13. **CRI 的容器名为什么那么长？** `makeContainerName` 拼 `k8s_<container>_<pod>_<ns>_<uid>_<attempt>`（helpers.go:131-139），把 K8s 元数据冗余进名字，方便 `ctr` 调试和第三方工具反查归属。

## 深挖线索

1. **shim 型沙箱与去 pause 化**：`Runtime.Sandboxer=shim` + `disable_pause_image_pull` 的组合如何让 Windows HCS/VM 运行时彻底摆脱 pause 容器（config.go:123-133；sandbox_run.go:298-305）。
2. **transfer service 拉取路径**：`pullImageWithTransferService`（image_pull.go:304）与老 `client.Pull`（246）的差异、为何还不支持全部 CRI 镜像配置（179-182 注释）。
3. **OOMKilled 的竞态**：events.go:194-214 长注释——CRI 单 goroutine 处理 OOM 事件、Wait 先返回、systemd scope 提前回收导致检测不稳定，是讲事件模型的好案例。
4. **ContainerEvents 流**：`containerEventsQ`（service.go:163、237-244，5 分钟丢弃窗口）实现 CRI `GetContainerEvents`，kubelet 1.30+ 事件驱动 Pod 生命周期的基础。
5. **runtime feature 内省**：`introspectRuntimeFeatures`（service.go:461-503）经 shim 的 PluginInfo 拿 runc features（rro 挂载、userns），决定 RuntimeHandler.Features 上报 kubelet（service.go:425-459）。

## 写作要点速查表

| 主题 | 文件:行号 |
|---|---|
| CRI 插件注册（GRPCPlugin "cri"） | plugins/cri/cri.go:47-69 |
| 双服务注册到同一 gRPC server | plugins/cri/cri.go:209-214 |
| in-memory client + k8s.io 命名空间 | plugins/cri/cri.go:118-123 |
| CRI 服务启动序列（事件/恢复/CNI/流） | internal/cri/server/service.go:298-399 |
| RunPodSandbox 主流程 | internal/cri/server/sandbox_run.go:54-414 |
| CNI 组网 setupPodNetwork | internal/cri/server/sandbox_run.go:456-527 |
| pause 镜像预拉 ensurePauseImageExists | internal/cri/server/sandbox_run.go:416-438 |
| podsandbox Controller.Start（pause 容器） | internal/cri/server/podsandbox/sandbox_run.go:61-339 |
| pause 容器 OCI spec（netns/cgroup/shares） | internal/cri/server/podsandbox/sandbox_run_linux.go:40-215 |
| 业务容器加入 Pod namespace | internal/cri/opts/spec_opts.go:348-380 |
| CreateContainer → client.NewContainer | internal/cri/server/container_create.go:59-167, 406 |
| CRI 元数据 extension 写入 | internal/cri/server/container_create.go:389（labels 常量 internal/cri/labels/labels.go:56-59） |
| StartContainer → NewTask/Start | internal/cri/server/container_start.go:41-208 |
| 容器状态 checkpoint 落盘 | internal/cri/store/container/status.go:167-195 |
| 五态状态机 State() | internal/cri/store/container/status.go:104-118 |
| TaskExit → EXITED 状态迁移 | internal/cri/server/events.go:173, 294-297 |
| PodSandboxStatus 组装 | internal/cri/server/sandbox_status.go:33-96, 145-174 |
| PullImage（本地/transfer 双路径） | internal/cri/server/images/image_pull.go:123-239 |
| ImageFsInfo（kubelet GC 供数） | internal/cri/server/images/imagefs_info.go:30-83 |
| RemoveImage（最后引用同步 GC） | internal/cri/server/images/image_remove.go:44-77 |
| 重启恢复 recover | internal/cri/server/restart.go:55-114 |
| sandboxer=podsandbox 默认化 | internal/cri/config/config.go:677-679（模式定义 66-81） |
