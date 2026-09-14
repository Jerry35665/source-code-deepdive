# containerd 全景：daemon、插件 DAG、boltDB 元数据与事件总线

> 《源码深读》第五系列之四《Docker 深读》卷一 · containerd 侧第 1 章
> 代码版本：containerd **2.x 主干，commit `f6132db`**（v2.4.0-beta+unknown，见 `version/version.go:31`）。
> 注意：2.x 相比 1.x 大规模调整了目录：`plugin/plugin.go` 独立为 `github.com/containerd/plugin` 模块（本文引用其 vendor 副本）；`metadata/`→`core/metadata/`、`events/exchange.go`→`core/events/exchange/exchange.go`、daemon 的 `server.go`→`cmd/containerd/server/server.go`。行号均按本 commit 实测核对。

---

## 1. 全景：containerd 在容器栈中的位置

containerd 是"容器运行时的事实标准中间层"：上接 dockerd / nerdctl / kubelet(CRI)，下管镜像内容、快照与 shim 进程，真正的进程创建交给 runc。

```
        dockerd                kubelet            nerdctl / ctr
  (build/network/volume)   (CRI kubelet 插件)      (直接客户端)
          |   socket: /run/containerd/containerd.sock
          ▼
┌─────────────────────────── containerd daemon ───────────────────────────┐
│  GRPC API 服务层   tasks/images/containers/content/snapshots/events ...  │
│        │  一切服务皆插件 (plugins.GRPCPlugin)，经插件 DAG 初始化          │
│        ▼                                                                 │
│  metadata store (boltDB meta.db)：namespace 隔离的元数据真相 + GC        │
│        │                     │                          │                │
│        ▼                     ▼                          ▼                │
│  content store(拉取层)  snapshotter(overlayfs...)   事件总线 exchange    │
│        └──────────────────────────┬───────────────────────┘               │
│                                   ▼                                       │
│            runtime v2 TaskManager ──按 bundle 启动──► containerd-shim-runc-v2
│                                                     (每容器一个 shim 进程)│
└──────────────────────────────────────────────────────────────────────────┘
                                                     shim──create/start──► runc ──► 容器进程
```

要点：
- 守护进程入口极薄：`cmd/containerd/main.go:29-35` 的 `main()` 只调用 `command.App().Run`，并 blank-import `cmd/containerd/builtins`（`cmd/containerd/main.go:26`）触发全部内置插件的 `init()` 注册。
- 默认地址 `/run/containerd/containerd.sock`（`defaults/defaults_linux.go:21`），root=`/var/lib/containerd`、state=`/var/run/containerd`（`defaults/defaults_unix.go:24-26`）。
- shim 只负责单个容器的生命周期与 IO，与 daemon 之间是 ttrpc；本章只做分工预告，shim 细节留给 C 报告。

---

## 2. 插件体系：类型注册与依赖 DAG

### 2.1 Registration 与全局注册表

插件框架独立成模块 `github.com/containerd/plugin`（仓库内以 vendor 形式存在）。核心是 `Registration` 四要素：Type、ID、Requires、InitFn（`vendor/github.com/containerd/plugin/plugin.go:61-84`）：

```go
type Registration struct {
        Type     Type          // 插件类型（见下）
        ID       string        // 插件实例 ID
        Config   interface{}   // toml 配置默认值
        Requires []Type        // 依赖的插件类型列表，"*" 表示全部
        InitFn   func(*InitContext) (interface{}, error)
}
```

各包在 `init()` 中调用 `registry.Register` 把 Registration 追加进全局不可变 Registry（`vendor/github.com/containerd/plugin/registry/register.go:31-35`）；`Register` 会 panic 拒绝空 Type/空 ID/重复 (Type,ID)，并校验 Requires 语义：`"*"` 必须单独出现、不得依赖自身类型（`plugin.go:160-178`）。

### 2.2 PluginType 枚举

容器内置类型常量集中在 `plugins/types.go:25-88`，常用的有：`RuntimePluginV2`=`io.containerd.runtime.v2`（:31）、`GRPCPlugin`=`io.containerd.grpc.v1`（:35）、`TTRPCPlugin`（:37）、`SnapshotPlugin`=`io.containerd.snapshotter.v1`（:39）、`DiffPlugin`（:45）、`MetadataPlugin`=`io.containerd.metadata.v1`（:47）、`ContentPlugin`（:49）、`GCPlugin`（:51）、`EventPlugin`（:53）、`ServicePlugin`（:33，进程内 local 服务的载体）、`ServerPlugin`（:83，GRPC/ttrpc 监听器）。2.x 还新增了 `TransferPlugin`、`SandboxStorePlugin`、`SandboxControllerPlugin`、`ImageVerifierPlugin`、`MountManagerPlugin` 等。

### 2.3 依赖 DAG：Graph 的 DFS 拓扑排序

初始化顺序由 `Registry.Graph` 计算（`vendor/github.com/containerd/plugin/plugin.go:114-135`）：对每个未处理的注册项，沿 `Requires` 深度优先地把被依赖者先排进有序列表；检测到环时直接 panic（`plugin.go:137-156`，`children()` 用执行栈比对实现，`ErrPluginCircularDependency` 定义在 `plugin.go:42-43`）。因此加载顺序天然保证"被依赖者先初始化"。

```go
// vendor/github.com/containerd/plugin/plugin.go:126-133（节选）
for _, r := range registry {
        if _, ok := handled[r]; ok { continue }
        children(append(stack, r), registry, handled, &ordered)
        handled[r] = struct{}{}
        ordered = append(ordered, *r)
}
```

`Requires` 的粒度是**类型**而非实例：声明依赖 `SnapshotPlugin` 的插件初始化时会拿到该类型下的全部实例（`ic.GetByType`），如 metadata bolt 收集所有 snapshotter（`plugins/metadata/plugin.go:117-125`）；要指定唯一实例则用 `GetSingle`（多实例即报错，`context.go:137-160`）或 `GetByID`。

几个真实节点的 Requires（构成本书反复引用的依赖链）：

| 插件 | Requires | 位置 |
|---|---|---|
| metadata/bolt | ContentPlugin + EventPlugin + SnapshotPlugin | `plugins/metadata/plugin.go:98-102` |
| shim/manager | EventPlugin + MetadataPlugin | `core/runtime/v2/shim_manager.go:63-70` |
| runtime v2 task | ShimPlugin + MountManagerPlugin + WarningPlugin | `core/runtime/v2/task_manager.go:60-64` |
| GC scheduler | MetadataPlugin | `plugins/gc/scheduler.go:89-93` |
| services/* (GRPC 门面) | ServicePlugin | `plugins/services/tasks/service.go:37-40`、`containers/service.go:34-37` |
| server/grpc | GRPCPlugin + MetricsPlugin | `plugins/server/grpc/plugin.go:65-68` |
| CRI | CRIServicePlugin、PodSandbox、SandboxController、NRI、Event、Service、Lease… | `plugins/cri/cri.go:52-60` |

于是主链为：content/snapshotter/event → **metadata** → shim/manager → task manager → services(×) → server/grpc → CRI。

### 2.4 初始化循环

`server.New`（`cmd/containerd/server/server.go:125-234`）遍历 `LoadPlugins` 返回的有序图：为每个插件构造 `InitContext`，注入 root/state 目录等 Properties（:167-176），`p.Init(initContext)` 执行 InitFn（:190），结果进 `plugin.Set`。失败可跳过（`ErrSkipPlugin`），但配置中 `required_plugins` 声明的插件失败则 daemon 拒绝启动（:202-208）。Type=`ServerPlugin` 的实例被收进 `s.servers`，`Server.Start` 逐个启动（:273-280）。

### 2.5 两类"外挂"：proxy 插件与 GRPC 服务聚合

- **Proxy 插件**：配置文件里声明的第三方 snapshotter/content/diff/sandbox 以 GRPC 客户端形式注册进同一张图（`cmd/containerd/server/server.go:316-382`），支持 snapshotter/content/sandbox/diff 四种（:327-348）。
- **GRPC 服务聚合**：`server/grpc` 插件初始化时遍历插件 Set，把所有实现了 `Register(*grpc.Server)` 的 GRPCPlugin 挂到一个 `grpc.Server` 上（`plugins/server/grpc/plugin.go:108-131`）；单个服务失败不拖垮监听器（:114-117 注释）。这就是"一切皆插件"的最终落点——API 面也是插件图的产物。

**为什么一切皆插件**：内容/快照/运行时在不同平台有不同实现（overlayfs/btrfs/devmapper、runc/runhcs），K8s 生态还要求第三方替换（如 nydus-snapshotter 用 proxy 插件注入）。把"类型+依赖+初始化顺序"抽象成一张 DAG 后，daemon 退化为通用加载器：启动流程、生命周期、配置迁移（`Registration.ConfigMigration`，`plugin.go:76-83`）全部统一，新增实现只需要一次 `init()` 注册。

---

## 3. metadata store：boltDB 是唯一的元数据真相

### 3.1 布局：version/namespace/object/key

`core/metadata/buckets.go` 的包注释是全书最重要的 ASCII 之一：通用布局 `<version>/<namespace>/<object>/<key> -> <field>`（`buckets.go:29`），完整 schema 树在 `buckets.go:60-138`，顶层为 `v1`（`db.go:49` `schemaVersion="v1"`，兼容式演进由 `dbVersion=4` 追踪，`db.go:54`）。命名空间下并列：`labels`、`images`、`containers`、`snapshots/<snapshotter>/<key>`、`content/blob|ingests`、`sandboxes`、`leases`。

容器桶字段一例（`buckets.go:75-89`）：`spec`（proto 序列化的 OCI spec）、`image`、`snapshotter`、`snapshotKey`、`runtime/{name,options}`、`extensions`、`labels`。桶 key 常量在 `buckets.go:147-157`，helper 全是 `getBucket(tx, keys...)` 的变长路径查找（`buckets.go:183-194`）。

以容器对象为例，一个 `ctr -n test c create` 最终落库为：

```
bkt[v1]/bkt[test]/bkt[containers]/bkt[<container-id>]
    spec        = proto(OCI Spec)        createdat = binary time
    snapshotter = "overlayfs"            image     = "docker.io/library/nginx:latest"
    snapshotKey = <id 的快照键>           runtime/name = "io.containerd.runc.v2"
    labels      = { ... }
```

读取端只是同一条路径的 `getBucket` 查找：`getContainerBucket(tx, namespace, id)`（`core/metadata/buckets.go:249-251`）。也就是说，**bolt 的嵌套桶本身就是 ORM 的表/行/列**，containerd 没有再建一层模型。

### 3.2 命名空间隔离

隔离完全靠"桶路径第一层是 namespace"实现：每个读写函数先 `namespaces.NamespaceRequired(ctx)`（如 `core/metadata/containers.go:56,82,133`），namespace/id 合法性由 `pkg/identifiers/validate.go:52` 校验。同名 key 在不同 namespace 互不可见；跨 namespace 共享的只有底层 content/snapshot 数据本身，是否"看见即共享"由 `content_sharing_policy`（shared/isolated）控制（`plugins/metadata/plugin.go:49-82`，默认 shared :104）。

### 3.3 DB 结构与事务模型

`core/metadata/db.go:84-116` 定义 `DB`：包着 bolt `Transactor`（`View/Update`，`core/metadata/bolt.go:30-33`）、内容/快照代理 store、`wlock sync.RWMutex`、`dirty` 原子计数与 `dirtySS/dirtyCS` 脏标记。事务三规则：

1. 读走 `View`，写走 `Update`；`Update` 持 `wlock.RLock`，保证 GC 期间无新写事务（`db.go:272-284`）。
2. 可组合事务：`view()/update()` 优先复用 ctx 里携带的 bolt 事务（`core/metadata/bolt.go:37-55`），一次 GRPC 请求跨多个 store 只开一个写事务。
3. 事件不在事务内发布：`DB.Publisher` 检测到 ctx 带事务即返回 nil（`db.go:288-298`），GC 事件则在提交后异步补发（`db.go:441-443`）。

bolt 打开参数也讲究：`NoFreelistSync`+`NoStatistics` 降低损坏面与争用，`boltOpenTimeout=0` 表示 flock 等待无限（`plugins/metadata/plugin.go:132-144`）——这就是"已有 containerd 在跑时第二个实例会卡在 bolt.Open"的原因，`cmd/containerd/command/main.go:211-214` 注释也专门说明了这一点。

### 3.4 GC：三色标记 + 标签引用 + 调度器

引用关系不靠外键，靠**约定 label**：`containerd.io/gc.ref.<type>`（`core/metadata/gc.go:73-75`）。GC 主流程 `DB.GarbageCollect`（`db.go:383-489`）：持 `wlock.Lock` → `getMarked` 从 roots（活跃容器/租约/镜像）出发，用 `gc.Tricolor` 求可达集（`db.go:492-536`；三色算法本体在 `pkg/gc/gc.go:64-105`）→ 在一个 bolt 写事务里 `scanAll` 删除不可达元数据（`db.go:396-431`；`remove` 在 `core/metadata/gc.go:1034`）→ 提交后再异步清理 snapshotter 与 content 的真实数据（`db.go:449-479`）。"先删元数据、再删数据"保证崩溃时不产生悬挂引用。

谁来触发？独立 GC 插件 `gc/scheduler` 注册 mutation 回调（`plugins/gc/scheduler.go:182`），按 `PauseThreshold=0.02 / MutationThreshold=100 / StartupDelay=100ms` 等阈值决定何时调用 `GarbageCollect`（`scheduler.go:96-102` 配置默认值，:298 调用点）。

---

## 4. 事件总线：纯内存 pub/sub

事件插件只注册了一个 `exchange.NewExchange()`（`plugins/events/plugin.go:26-34`）。Exchange 内部就是 `docker/go-events` 的 Broadcaster（`core/events/exchange/exchange.go:36-45`）：

```go
type Exchange struct {
        broadcaster *goevents.Broadcaster
}
func NewExchange() *Exchange {
        return &Exchange{ broadcaster: goevents.NewBroadcaster() }
}
```

- **Publish**：从 ctx 取 namespace，`typeurl.MarshalAny` 编码事件，打上时间戳/namespace/topic 后 `broadcaster.Write`（`exchange.go:80-119`）。topic 必须形如 `/tasks/create`，逐段校验（`exchange.go:201-222`）。
- **Subscribe**：为每个订阅者建 Channel+Queue，可选 filter（containerd filter 语法），goroutine 把 envelope 转投到用户 channel，ctx 取消即退订（`exchange.go:128-199`）。
- **Envelope** 四字段：Timestamp/Namespace/Topic/Event（`core/events/events.go:27-31`）。

Publish 的关键几行（`exchange.go:94-102`）：

```go
encoded, err := typeurl.MarshalAny(event)
...
envelope.Timestamp = time.Now().UTC()
envelope.Namespace = namespace
envelope.Topic     = topic
envelope.Event     = encoded
return e.broadcaster.Write(&envelope)
```

**是否持久化到 bolt？没有。** 全代码库 `exchange` 无任何落盘逻辑；它只是进程内广播。bolt 里的桶树（第 3 节 schema）没有任何 events 桶。持久观感来自三点：元数据本身就是真相（可重放状态）、订阅者（kubelet/cri）断线后靠 List+Watch 补齐、以及 metadata GC 会把删除动作补发为 `/images/delete`、`/snapshot/remove` 事件（`core/metadata/db.go:348-368` `publishEvents`，topic 映射 :354-362）。GRPC 侧的 `Events.Subscribe` 是个流式转发（`plugins/services/events/service.go:101-115`）。

事件类型定义在 `api/events/*.proto`（如 TaskCreate/TaskStart/TaskExit/TaskOOM，`api/events/task.proto:28-90`），`api/events.proto` 在 2.x 已按类型拆分成该目录。

---

## 5. GRPC API 面：服务清单与端到端调用链

### 5.1 服务清单

`api/services/` 下 16 个版本化服务：containers、content、diff、events、images、introspection、leases、mounts、namespaces、sandbox、snapshots、streaming、tasks、transfer、ttrpc、version。每个服务是两层插件：`ServicePlugin`（进程内 local 实现，直连 metadata DB）+ `GRPCPlugin`（proto 门面，转发给 local）。各服务的 local 层全部经 `ic.GetSingle(plugins.MetadataPlugin)` 拿到同一个 bolt DB（`plugins/services/containers/local.go:54`、`services/content/store.go:36`、`services/images/local.go:55`、`services/snapshots/snapshotters.go:35`、`services/namespaces/local.go:52`、`services/tasks/local.go:110`），即"所有 API 最终收敛到一把 bolt 写锁"。

| 服务 | proto | 说明 |
|---|---|---|
| Tasks | `api/services/tasks/v1/tasks.proto:33-68` | Create/Start/Kill/Exec/Checkpoint/Wait 等 17 个 RPC |
| Events | `api/services/events/v1/events.proto:32-48` | Publish/Forward + 流式 Subscribe |
| Images | `api/services/images/v1/images.proto` | 镜像记录 CRUD（写 `v1/<ns>/images`） |
| Content | `api/services/content/v1/content.proto` | blob 读写/ingest 推进 |
| Snapshots | `api/services/snapshots/v1/snapshots.proto` | 按名字选择 snapshotter（overlayfs…） |
| Introspection | `api/services/introspection/v1/introspection.proto:35-39` | Plugins/Server/PluginInfo 插件自省 |
| Leases | `api/services/leases/v1/leases.proto` | GC 租约管理（pull 的保护伞） |
| Transfer/Streaming/Sandbox/Mounts… | 同目录 | 2.x 新增面 |

Task 服务 RPC 全集见 `api/services/tasks/v1/tasks.proto:33-68`（Create/Start/Delete/Kill/Exec/Pause/Resume/Checkpoint/Wait/Metrics…）；Events 服务三方法 Publish/Forward/Subscribe（`api/services/events/v1/events.proto:32-48`）；Introspection 提供 `Plugins` 列举运行中的插件（`api/services/introspection/v1/introspection.proto:35-39`）。

### 5.2 端到端：pull → create → start

客户端 `client.New` 只做 GRPC 拨号与默认拦截器（namespace 注入），不加载任何插件（`client/client.go:104-183`）。以 `ctr run` 等价序列为例：

1. **Pull**（`client/pull.go:43-194`）：先 `WithLease` 包住整个操作防 GC 误删（:86）→ resolver.Resolve 拿 manifest 描述符 → Handler 链 FetchHandler 把 blob 写入 content store（`pull.go:196-303`）→ 若 unpack，挂 `unpack.Unpacker` 经 snapshotter+diff 建根快照（:94-155）→ `createNewImage` 调 ImageService.Create/Update 写入 `v1/<ns>/images`（`pull.go:306-332`）。
2. **NewContainer**（`client/client.go:340-379`）：组装 `containers.Container{ID, Runtime.Name=io.containerd.runc.v2}`，`ContainerService().Create` → 经 services/containers → metadata `createContainersBucket` 落桶。
3. **NewTask**（`client/container.go:226-290`）：发 `CreateTaskRequest{ContainerID, Rootfs mounts, IO}` → tasks 服务 local 层（`plugins/services/tasks/local.go:171` Create）→ runtime v2 `TaskManager.Create`：`NewBundle` 建 `/run/containerd` 下的 bundle 目录（`core/runtime/v2/task_manager.go:159-168`）→ `manager.Start` 拉起 shim 二进制（:192）→ `shimTask.Create` 经 ttrpc 让 shim 调 runc create（:226）。
4. **Start**：`task.Start` → 同链路 → shim 调 runc start，随后 TaskStart 事件从 shim 逆向上抛，经 exchange 广播给所有订阅者。

把控制面与数据面分开看，一次 pull 的数据流是：

```
ctr/docker pull
  ├─ Resolver(HTTPS 到 registry) ──blob 字节──► content store
  │       （元数据: v1/<ns>/content/blob/<digest> 逐条登记）
  └─ Unpacker ──逐层 Apply──► diff 服务 ──► snapshotter(overlayfs)
          （元数据: v1/<ns>/snapshots/overlayfs/<key>）
```

控制面只发"指令 + 描述符"，字节流永远不进 GRPC API——blob 经 content 服务的流式 ingest 或客户端直写本地 store，这也是 containerd 能支撑大镜像高吞吐的关键。

---

## 6. 设计动机三问

**为什么元数据用 bolt 而不是 SQL？** 元数据是"单机、单进程、低频写、小对象、强一致"的纯嵌套数据：一次 pull 写几十个 blob 记录、一次 create 写一个容器桶，没有跨表 join 需求。bolt 是单写多读的 mmap B+树，嵌入进程零运维、崩溃即回滚，桶即命名空间层级，与 GC 的"在一个写事务里原子 sweep"完美契合（`db.go:396` 一次 `db.Update` 同时删多类资源）。代价是写吞吐，containerd 用 NoFreelistSync/NoStatistics/可选 NoSync（`plugins/metadata/plugin.go:132-165`）与读多写少的负载特性来对冲。

**为什么事件总线不持久化？** containerd 的哲学是"元数据即真相，事件只是通知"。状态可随时通过 images/containers/tasks List API 重建，订阅者只需"变化通知+自愈能力"（CRI 侧 List+Watch）。持久化事件流反而引入第二个真相源与清理问题；所以连 GC 删除都只是"提交后补发通知"（`db.go:440-443`），错过就靠重新 List。

**守护进程如何做到"无状态化"？** 严格说是"状态全部收敛到 root 目录（bolt+content+snapshot）"。state 目录只放易失的运行态（shim socket、bundle 地址），重启后 `LoadExistingShims` 从 state 恢复 shim 连接（`core/runtime/v2/task_manager.go:102,139`），元数据从 meta.db 重建。daemon 进程本身不缓存任何必须持久化的东西，这使 containerd 可以随 systemd 任意重启升级（shim 存活、容器不断）。

---

## 7. FAQ 素材

1. **ctr/nerctl/docker 连不上 containerd 最常见原因？** meta.db 被 flock：`bolt.Open` 的 timeout 默认 0 即无限等待（`plugins/metadata/plugin.go:44,139`），现象是 daemon 启动卡住 10 秒后打 "waiting for response from boltdb open" 日志（:172-182）。
2. **containerd 有几种"服务插件"类型？** 三层：GRPCPlugin（proto 门面）、ServicePlugin（进程内 local）、TTRPCPlugin（shim 侧），另有 ServerPlugin 承载监听器（`plugins/types.go:33-37,83`）。
3. **两个 namespace 里 pull 同一个镜像会下载两次吗？** 默认不会：content_sharing_policy=shared，blob 一旦存在即可按 digest 认领，只是元数据各自记录（`plugins/metadata/plugin.go:49-65`）。
4. **删除容器后磁盘立刻释放吗？** 不会。GC 是异步三色标记，先删 bolt 元数据再异步清 snapshotter/content（`core/metadata/db.go:396-479`），由 scheduler 插件按阈值触发（`plugins/gc/scheduler.go:96-102`）。
5. **containerd 重启后运行中的容器怎么办？** shim 独立存活，daemon 启动时 `LoadExistingShims` 重连（`core/runtime/v2/task_manager.go:102`）；`containerd-shim-runc-v2` 一个 shim 可管多容器（runtime id `io.containerd.runc.v2`，`plugins/types.go:91-92`）。
6. **如何列出 daemon 实际加载了哪些插件？** `ctr plugins ls` → Introspection 服务 `Plugins` RPC（`api/services/introspection/v1/introspection.proto:35`），数据来自初始化完成的 plugin Set。
7. **为什么有的插件加载失败 daemon 不退出？** 普通插件失败仅告警跳过；`required_plugins` 里的失败才会终止启动（`cmd/containerd/server/server.go:197-208,224-230`）。
8. **第三方 snapshotter 怎么接入？** 配置 `[proxy_plugins]`，daemon 以 GRPC 客户端包装注册进插件图（`cmd/containerd/server/server.go:316-382`）。
9. **事件 topic 命名规则？** 必须以 `/` 开头、逐段过 identifiers 校验（`core/events/exchange/exchange.go:201-222`），官方 topic 即 `api/events/*.proto` 中的消息族。
10. **schema 如何演进？** 顶层桶 `v1` 之下只允许兼容追加，结构变更加 `dbVersion` 并跑 migrations（`core/metadata/db.go:42-54`，迁移执行 :156-236）。

## 深挖方向

1. **GC 引用图的完备性**：`containerd.io/gc.ref.*` 的所有 labelHandler 与"镜像过期"（`isExpiredImage`，`core/metadata/gc.go:1136`）如何组合出安全删除边界；泄漏一条引用即可常驻泄漏磁盘。
2. **bolt 事务与 ctx 组合**：`boltutil.Transaction(ctx)` 如何让一次 GRPC 请求内的多 store 写合并为单事务（`core/metadata/bolt.go:37-55`）及其对锁粒度的影响。
3. **typeurl 事件编码**：Publish 用 `typeurl.MarshalAny`（`exchange.go:94-97`），跨进程如何还原任意 proto Any——客户端 `client/client.go:83-100` 预注册 OCI 类型是必读补充。
4. **transfer 服务**：2.x 新增的拉取架构（`api/services/transfer` + `plugins/transfer/plugin.go:47-51`），对比 5.2 的经典 Pull 链路，预判 CRI/ctr 的迁移路径。
5. **proxy 插件的代理栈**：snapshotter proxy 的 Lease/快照语义在 GRPC 边界如何保真（`cmd/containerd/server/server.go:327-332` 与 `core/snapshots/proxy`）。

---

## 写作要点速查表（函数 → 行号）

| # | 事实 | 位置 |
|---|---|---|
| 1 | `main()` 仅启动 App + blank import builtins | `cmd/containerd/main.go:26,29-35` |
| 2 | 插件 Registration 四要素定义 | `vendor/github.com/containerd/plugin/plugin.go:61-84` |
| 3 | Registry.Graph DFS 拓扑排序（环 panic 在 children） | `plugin.go:114-135,137-156` |
| 4 | 全局注册表 `registry.Register` | `vendor/.../plugin/registry/register.go:31-35` |
| 5 | PluginType 全集常量 | `plugins/types.go:25-88` |
| 6 | `server.New` 插件初始化主循环 | `cmd/containerd/server/server.go:125-234` |
| 7 | `LoadPlugins`+proxy 插件注册+出图 | `cmd/containerd/server/server.go:313-387` |
| 8 | GRPC 服务聚合循环 | `plugins/server/grpc/plugin.go:108-131` |
| 9 | metadata bolt 插件：Requires/meta.db/bolt.Open/NewDB | `plugins/metadata/plugin.go:94-205`（98-102,169,184,198） |
| 10 | bolt 桶树 schema 注释 + 桶 key 常量 | `core/metadata/buckets.go:29,60-138,147-157` |
| 11 | `DB.Update` 持 wlock.RLock + mutation 回调 | `core/metadata/db.go:272-284` |
| 12 | `GarbageCollect` 标记-清扫主流程 | `core/metadata/db.go:383-489`；`getMarked` :492-536 |
| 13 | 三色标记本体 `Tricolor` | `pkg/gc/gc.go:64-105` |
| 14 | `containerd.io/gc.ref.*` 标签常量 | `core/metadata/gc.go:73-75`；`remove` :1034 |
| 15 | GC scheduler 阈值与 mutation 回调 | `plugins/gc/scheduler.go:85-127,182,298` |
| 16 | Exchange 内存广播/Publish/Subscribe | `core/events/exchange/exchange.go:36-45,80-119,128-199` |
| 17 | Envelope 结构（不落盘） | `core/events/events.go:27-31` |
| 18 | Task 服务门面：门面→local 两层插件 | `plugins/services/tasks/service.go:35-51`；local Create :171 |
| 19 | 客户端链路：New/Pull/NewContainer/NewTask | `client/client.go:104,340`；`client/pull.go:43,157,177`；`client/container.go:226` |
| 20 | runtime v2 Create：NewBundle→Start shim→shimTask.Create | `core/runtime/v2/task_manager.go:159,160,192,226` |
