# Q - containerd 事件系统深读：Exchange、GRPC 桥接与丢失语义

> 依据 containerd commit `f6132db`（f6132dbe1f482cbe0aebc4bd3d8d7a184fb4a2aa，2.x 主干，2025-09 前后主干）。所有行号为该 commit 实测（grep -n / Read 核对）。
> 承接卷一 A 报告的结论：事件总线是**纯内存 pub/sub，不持久化**。本章展开它的完整链路、过滤语法、桥接细节与丢失语义。

---

## 1. 全景：产生 → 分发 → 消费

```
 [事件产生源]                                    [Exchange (纯内存)]                 [消费端]
 ────────────────────────────────────          ─────────────────────               ──────────────────────────
 shim 进程内 (runc v2)                          Exchange.broadcaster
   s.events chan ──forward loop──┐              (docker/go-events)                  GRPC 长连接订阅者
                                 │            ┌──────────────────┐                (ctr events / Go client /
 shim ──ttrpc Forward────────────┤            │  Broadcaster     │                docker/containerd client)
   (pkg/shim/publisher.go)       │            │   单 goroutine   │                 └─ api/services/events/
                                 ├──Write──▶  │   顺序写 sinks   │──Subscribe()─────   v1/service.go:101
 daemon 内部 Publish:            │            │   每 sink 一条   │   filters            ↘ srv.Send (流式)
   /containers/*  (containers    │            │   无界 Queue)    │                       ↘ 外部进程
    service local.go)            │            └──────────────────┘
   /images/* /snapshot/*         │                                        内部消费者
   /content/* /namespaces/*      │                                         └─ CRI EventMonitor
   /sandboxes/*                  │                                            (cri/server/events/
                                 │                                             events.go) OOM+images
 GC 删除补偿 ──commit 后异步──────┘                                         └─ CRI GetContainerEvents
 (db.go publishEvents)                                                        (CRI 自有 eventq)
```

要点：
- 事件本体是 `Envelope{Timestamp, Namespace, Topic, Event typeurl.Any}`（core/events/events.go:27-32），Event 字段用 typeurl 编码的 protobuf Any。
- 三个接口定义：Publisher / Forwarder / Subscriber（core/events/events.go:68-80）。
- Exchange 只是 `broadcaster *goevents.Broadcaster` 的一层封装（core/events/exchange/exchange.go:36-38），由 `plugins/events/plugin.go:27-33` 注册为 EventPlugin "exchange"。

### 1.1 产生源清单（Publish/Forward 调用面）

| 主题 | 事件类型 | 发布点 |
|---|---|---|
| /containers/create、/update、/delete | ContainerCreate/... | plugins/services/containers/local.go:139、179、198 |
| /images/create、/update、/delete | ImageCreate/... | core/metadata/images.go:169、270、337 |
| /content/create、/delete | ContentCreate/... | core/metadata/content.go:632、236 |
| /snapshot/prepare、/commit、/remove | SnapshotPrepare/... | core/metadata/snapshot.go:281、669、740 |
| /namespaces/create、/update、/delete | NamespaceCreate/... | plugins/services/namespaces/local.go:144、198、216 |
| /sandboxes/create、/start、/exit | SandboxCreate/... | plugins/services/sandbox/controller_service.go:141、168、202 |
| /tasks/create…/tasks/* | TaskCreate…TaskDelete | shim 进程内发布（见下） |
| /tasks/oom | TaskOOM | core/metrics/cgroups/v1/cgroups.go:90（daemon 侧 cgroup v1 OOM 监控）；shim 内 cmd/containerd-shim-runc-v2/task/service.go:698 |

任务类事件的路径与容器类不同：它们在 **shim 进程内**产生，由 shim 的 forward 循环发出（cmd/containerd-shim-runc-v2/task/service.go:818-830，`publisher.Publish(ctx, runtime.GetTopic(e), e)`），topic 由 `runtime.GetTopic` 按事件 Go 类型映射（core/runtime/events.go:53-64，常量 `/tasks/create` 等在 25-39 行）。shim 通过 ttrpc 把事件 **Forward** 到 containerd 主进程：pkg/shim/publisher.go:127-152 构造 `ForwardRequest`，154-188 行发送（5 秒超时、失败重连一次）。shim 侧 publisher 是注册在 shim 插件注册表里的 EventPlugin "publisher"（pkg/shim/shim.go:334-349）。

daemon 收到 Forward 后进总线：plugins/services/events/service.go:93-99；外部也可以直接调 Publish RPC 注入事件（service.go:85-91），`ctr` 的 `containerd publish` 子命令就是这么干的（cmd/containerd/command/publish.go:68）。

还有一个兜底源：shim 意外断连时，`cleanupAfterDeadShim` 会替它补发 TaskExit + TaskDelete（core/runtime/v2/shim.go:182-195；若 shim 已成功投递过 delete 则跳过，163-167 行）。

---

## 2. Exchange 专节：Publish、Topic 命名与 filter 语法

### 2.1 Publish（core/events/exchange/exchange.go:80-119）

```go
func (e *Exchange) Publish(ctx context.Context, topic string, event events.Event) (err error) {
        namespace, err = namespaces.NamespaceRequired(ctx)      // 86 行：必须带 namespace
        if err := validateTopic(topic); err != nil { ... }      // 90 行
        encoded, err := typeurl.MarshalAny(event)               // 94 行
        envelope.Timestamp = time.Now().UTC()                   // 99 行：发布时刻打时间戳
        envelope.Namespace = namespace
        envelope.Topic = topic
        envelope.Event = encoded
        return e.broadcaster.Write(&envelope)                   // 118 行：扔进总线即返回
}
```

`Forward`（exchange.go:55-75）与 Publish 的区别：调用者自带完整 Envelope（时间戳、namespace 已定），只做 `validateEnvelope` 校验后直接 `broadcaster.Write`（74 行）；校验规则在 validateEnvelope（exchange.go:224-238）：namespace 合法、topic 合法、时间戳非零。

### 2.2 Topic 命名约定（exchange.go:201-222）

validateTopic 强制：非空；必须以 `/` 开头；至少两个 component；每一段都要过 `identifiers.Validate`（215-218 行）。这就是全仓库 topic 都形如 `/images/delete`、`/tasks/exit` 的来源——**两级：`/资源/动作`**。注意 namespace 不进 topic，是 Envelope 的独立字段（events.go:29），隔离靠订阅过滤器。

### 2.3 Subscribe 与 filter 语法（exchange.go:128-199）

每个订阅者建立一条独立 sink 链（129-135 行）：

```go
evch = make(chan *events.Envelope)       // 130 行：最终交付通道(无缓冲)
channel = goevents.NewChannel(0)         // 132 行：0 = 无缓冲 channel
queue   = goevents.NewQueue(channel)     // 133 行：无界内存队列
if len(fs) > 0 {
        filter, err := filters.ParseAll(fs...)                 // 148 行
        dst = goevents.NewFilter(queue, goevents.MatcherFunc(  // 155-157 行
                func(gev goevents.Event) bool { return filter.Match(adapt(gev)) }))
}
e.broadcaster.Add(dst)                                            // 160 行
```

- filter 语法（pkg/filters/parser.go:32-46）：`<fieldpath><op><value>` 的 selector，操作符 `==` / `!=` / `~=`（正则），多个 filter 之间是 **any-match**（ParseAll，parser.go:63）。
- 匹配字段由 `Envelope.Field`（core/events/events.go:36-62）提供：`namespace`、`topic`、以及 `event.<fieldpath>`（对事件体再取 Field，如 `event.id`）。所以 CRI 的订阅串长这样：`topic=="/tasks/oom"`、`topic~="/images/"`（~ 正则匹配前缀）。
- filter 解析失败：错误写入 errs 通道并就地收摊（exchange.go:149-153）。
- 订阅循环（162-196 行）：从 queue 的 channel 取事件，经 `evch <- env` 交给上层；ctx 取消即退出并关闭一切（closeAll，137-142 行：关 channel、关 queue、从 broadcaster 摘除 sink）。

---

## 3. GRPC 桥接专节：EventService 如何把内存事件推给外部

### 3.1 服务装配（plugins/services/events/service.go）

一个 service 双协议：GRPC 服务给外部客户端，ttrpc 服务给 shim（59-73 行结构体同时持有两者；75-83 行 `Register`/`RegisterTTRPC`）。它依赖 EventPlugin "exchange"（42-57 行）——即同一个进程内总线实例。

### 3.2 Subscribe 的 broker→stream 桥（service.go:101-120）

```go
func (s *service) Subscribe(req *api.SubscribeRequest, srv api.Events_SubscribeServer) error {
        ctx, cancel := context.WithCancel(srv.Context())       // 102 行：挂到连接生命周期
        defer cancel()
        eventq, errq := s.events.Subscribe(ctx, req.Filters...) // 105 行
        for {
                select {
                case ev := <-eventq:
                        if err := srv.Send(toProto(ev)); err != nil {  // 109 行：发不出去就退订
                                return fmt.Errorf("failed sending event to subscriber: %w", err)
                        }
                case err := <-errq:                             // 112 行
                        ...
                }
        }
}
```

`toProto`（122-129 行）把内部 Envelope 转成 `types.Envelope`，Event 字段仍是 typeurl 字节，客户端按 typeurl 反序列化——事件类型注册表（typeurl）是两端共享约定。

### 3.3 客户端侧与断连语义

- Go 客户端：client/events.go:80-125，goroutine 里 `session.Recv()` 循环推入本地 chan（109-120 行）；连接断开 → Recv 返回错误 → 写入 errs 通道，调用方感知。
- client.go:802 直接用 `proxy.NewRemoteEvents(c.conn)` 包出同一个三接口（Publisher/Forwarder/Subscriber）。
- 代理实现：core/events/proxy/remote_events.go:42-63 支持 grpc 与 ttrpc 两种底层（ttrpc 版 149-231 行，正是 shim 消费 containerd 事件用的桩）。
- **背压与断连**：没有 ack/流量控制。客户端读得慢 → `srv.Send` 阻塞 → 交换机侧 `evch <- env` 阻塞 → go-events Queue（无界）开始堆积，仅此而已（见第 4 节）。客户端断连 → srv.Context 取消 → exchange.Subscribe 退出、sink 摘除。期间发生的事件**不补发**。
- ttrpc 生成桩对 shim 的意义：shim 只需调 Forward/Publish 一个 RPC（api/services/events/v1/events_ttrpc.pb.go:39），主进程转发入总线，shim 不需要知道别的订阅者。

---

## 4. 时序与丢失专节

### 4.1 排序保证：单订阅者 FIFO，无全局序

- Broadcaster 单 goroutine 顺序遍历 sinks 写入（vendor/github.com/docker/go-events/broadcast.go:112-127）；每个订阅者的 Queue 是 FIFO 链表（queue.go:93-112）→ **同一订阅者收到的顺序 = 发布进总线的顺序**。
- 但总线没有序列号、没有全局时钟排序；多发布者并发 Publish 到 broadcaster 的无缓冲 chan（broadcast.go:32，`make(chan Event)`），到达顺序即写顺序。**跨 topic、跨 namespace 的相对顺序无任何保证**。
- `envelope.Timestamp` 是发布时刻（exchange.go:99），不是"业务发生"时刻——shim 侧业务发生到 Forward 进总线之间有时间差；GC 补发事件的时间戳更是晚于删除本身。

### 4.2 消费慢会怎样：不丢，但吃内存

关键在 go-events 的 sink 链：Broadcaster.Write 永不阻塞（broadcast.go:48-55），真正兜底的是每订阅者一条的 **无界 Queue**（queue.go:10-12 注释自述 "It is unbounded"）。慢订阅者的后果是容器进程内存无上限增长，而不是丢事件——这与很多"ring buffer 满即丢"的总线相反。真正丢事件的三条缝：

1. sink 写失败且非 ErrSinkClosed：只打一条 "broadcaster: dropping event" 日志（broadcast.go:120-124）；Queue 向下游（已关闭的 Channel）写失败也是 debug 级丢弃（queue.go:74-86）。
2. shim 侧 RemoteEventsPublisher：本地 requeue chan 容量 2048（pkg/shim/publisher.go:36），失败重试最多 5 次（37 行），超限**直接丢弃**并打日志（102-108 行）。
3. 进程重启：一切归零。

### 4.3 事件与 bolt 元数据的关系：删除补偿

卷一 A 的结论仍成立：事件不写库。但 GC 路径有个"补发"设计：

- `DB.Publisher`（core/metadata/db.go:288-298）在 bolt 事务内**故意返回 nil**——绝不在事务中发事件（未提交的状态不该被看见）。
- GC 扫描删除时把事件攒成 `[]namespacedEvent`（db.go:395-424，rm 回调 415-422 行），**bolt 提交成功后**异步发布：`wg.Go(func(){ m.publishEvents(events) })`（db.go:440-443）。
- publishEvents 只认识两种类型并映射 topic：`*eventstypes.ImageDelete → /images/delete`、`*eventstypes.SnapshotRemove → /snapshot/remove`（db.go:354-362），其他类型只打 debug 日志。
- 也就是说：镜像/快照被 **GC**（而非 API Delete）干掉时，外部（如 kubelet 的 image GC 感知、Docker）仍能收到 /images/delete——但这是"尽力而为"：publishEvents 失败仅 debug 日志（364 行），进程在 commit 后、发布前崩溃则事件永久丢失。
- GC 的触发节奏由 mutation callback 驱动：metadata 每次变更回调 GC 调度器（db.go:300-309），调度器 `c.RegisterMutationCallback(s.mutationCallback)`（plugins/gc/scheduler.go:182），按阈值攒批后调 GarbageCollect。

### 4.4 消费方必须接受的对账义务

事件系统对消费方的隐含契约是：**事件只是提醒，不是事实**。事实要用 API 重新拉取。CRI 就是范本：
- 订阅只挑两个 topic：`topic=="/tasks/oom"`、`topic~="/images/"`（internal/cri/server/service.go:302），且启动注释明说 filters 是 any-match。
- TaskExit（容器退出这条最关键的状态转移）**不走事件总线的主路径**——CRI 用独立 goroutine 监听 `task.Wait`（internal/cri/server/events/events.go:120-125 的 NOTE），事件监控只是兜底。
- 启动时 recover 全量对账（service.go:318），事件仅用于增量。
- CRI 事件处理失败进 backoff 队列重试（events.go:144-152；1s 起步、5min 封顶，34-38 行常量）。

---

## 5. 设计动机

**为什么不持久化（对照 Kafka / etcd 事件）？**

- Kafka 是"日志即数据"：分区、offset、消费组、可重放，代价是独立集群与运维。etcd 的 watch 带 MVCC revision，断线可从上次 revision 续传。containerd 的 Exchange 三者皆无：没有 offset/revision、没有存储、没有消费组——它是**进程内通知器**，天然是 best-effort。
- 但 containerd 并不需要事件承担"事实来源"职责：资源事实在 bolt（元数据）与 shim（运行态）里，任何一个消费端都可以 List + 对账重建状态。持久化事件反而会引入第二份需要 GC、需要一致性维护的状态（Kafka 的 retention 配置、etcd 的 compact 就是为此付出的代价）。
- 简化可靠性的另一半是 namespace：Envelope 自带 Namespace 字段（events.go:29-30），Publish 强制从 ctx 取（exchange.go:86），ttrpc/GRPC 服务端再把它塞进 ctx——事件不会跨 namespace 泄露，过滤器显式指定即可，无需在 topic 里编码租户信息。
- 代价也被明码标价：客户端（dockerd、kubelet）必须自己处理断连重订 + 全量刷新；本文 4.4 的 CRI 三件套（限 topic、独立 Wait、启动 recover）就是官方给出的标准姿势。

---

## 6. FAQ 素材

1. **`ctr events` 能看到订阅之前的事件吗？** 不能。Subscribe 只从订阅时刻开始推（exchange.go:128 的语义；CRI 注释 events.go:73-74 "All events happen after it should be monitored"），没有回放。
2. **订阅者消费慢，事件会丢吗？** 不会丢，但会**无限堆积内存**——每订阅者一条无界 Queue（queue.go:10-12），背压一路传导到队列涨大为止。
3. **dockerd/kubelet 断连期间的事件怎么办？** 丢。重连后须自行 List 对账；CRI 启动 recover（service.go:318）就是示范。
4. **/images/delete 有两个发布点？** 是。API 删除在 core/metadata/images.go:337（事务提交后发）；GC 删除在 db.go:348-368（commit 后异步补发，仅 ImageDelete/SnapshotRemove 两种）。
5. **shim 崩了事件还发得出吗？** daemon 侧 cleanupAfterDeadShim 兜底补发 TaskExit + TaskDelete（core/runtime/v2/shim.go:182-195），但 shim 已投递过 delete 就不重复（163-167 行）。
6. **订阅过滤器支持什么？** `fieldpath==value` / `!=` / `~=`（正则），多过滤器 any-match（pkg/filters/parser.go:32-46、63）；可匹配 namespace、topic、event.<fieldpath>（events.go:41-60）。
7. **能按事件内容过滤吗（如只订某容器）？** 能，前提是该事件类型的 proto 实现了 Field 访问器，如 `event.id==xxx`；否则该字段路径匹配失败（events.go:53-59 的类型断言兜底）。
8. **namespace 隔离在哪层？** Envelope 字段而非 topic 前缀；订阅者必须显式过滤，CRI 甚至要手动过滤非 k8s namespace（events.go:135-138，service.go:300-301 注释承认过滤器不能表达"不等于"组合）。
9. **为什么 events 有 GRPC 和 ttrpc 两套？** 同一 service 对外双协议（service.go:75-83）：GRPC 给外部客户端，ttrpc 给 shim（轻量，shim Forward 事件用）。
10. **事件顺序有保证吗？** 单订阅者 FIFO 有；跨发布者、跨 topic 无全局序，GC 补发还是异步的（db.go:440-443），时间戳也不能当排序依据（发布时刻而非发生时刻）。

## 7. 深挖方向

1. **go-events 三层 sink 链的背压传导**：Filter→Queue→Channel（exchange.go:132-134）各自独立 goroutine，把"慢消费者"逐级变成内存堆积——可以量化：一个不读的 GRPC 订阅者 + 高频 /tasks/exit 时的容器 RSS 增长曲线。
2. **shim RemoteEventsPublisher 的可靠性模型**：2048 深度本地队列 + 线性退避（count 秒）+ 5 次上限（pkg/shim/publisher.go:36-37、117-124），以及 ttrpc 断线重连（154-188 行）——它是全链路里唯一会"主动丢"的一环。
3. **GC 事件的事务一致性**：为什么事务内 Publisher 必须为 nil（db.go:288-298）、commit 后异步发布的窗口期语义、以及 publishEvents 只认两种类型的扩展成本。
4. **typeurl 事件编码**：Envelope.Event 是 typeurl.Any，事件类型靠双方注册表对齐；新事件类型的完整清单（api/events/*.proto → typeurl 注册）可作为一节。
5. **CRI 双通道**：containerd 事件（EventMonitor，OOM/images 兜底）与 CRI 自有事件队列（GetContainerEvents 流式接口，internal/cri/server/container_events.go:23-33 + internal/eventq/eventq.go：无订阅者时缓存 5 分钟、订阅 chan 容量 100、超时丢弃计数）是两套语义不同的队列，kubelet 1.30+ 的 ContainerEvent 消费走后者。

---

## 写作要点速查表

| 主题 | 文件:行号 | 关键点 |
|---|---|---|
| Envelope 结构 | core/events/events.go:27-32 | Timestamp/Namespace/Topic/typeurl.Any |
| Publisher 等三接口 | core/events/events.go:68-80 | Publish/Forward/Subscribe |
| Exchange 定义 | core/events/exchange/exchange.go:36-45 | 一层 goevents.Broadcaster 封装 |
| Publish | exchange.go:80-119 | ctx 取 ns(86)、打时间戳(99)、Write(118) |
| validateTopic | exchange.go:201-222 | /开头、两级、identifiers 校验 |
| Subscribe sink 链 | exchange.go:128-160 | Channel(0)(132)+无界 Queue(133)+ParseAll(148) |
| 订阅泵循环 | exchange.go:162-196 | evch 交付、ctx 退出、closeAll |
| filter 语法 | pkg/filters/parser.go:32-46,63 | == != ~=，any-match |
| Envelope 匹配字段 | core/events/events.go:36-62 | namespace/topic/event.* |
| Broadcaster 分发 | vendor/docker/go-events/broadcast.go:107-154 | 单 goroutine 顺序写；drop 日志 120-124 |
| 无界队列 | vendor/docker/go-events/queue.go:10-12,74-86 | 慢消费者→内存堆积不丢 |
| GRPC Subscribe 桥 | plugins/services/events/service.go:101-120 | srv.Send 失败即退订 |
| 双协议注册 | plugins/services/events/service.go:59-83 | grpc+ttrpc 同一 service |
| shim→daemon Forward | pkg/shim/publisher.go:127-188 | 5s 超时、重连；队列 2048/5 次(36-37,102-108) |
| shim forward 循环 | cmd/containerd-shim-runc-v2/task/service.go:818-830 | GetTopic 映射(core/runtime/events.go:53-64) |
| GC 补发 | core/metadata/db.go:348-368,395-443 | 事务内 nil(288-298)、commit 后异步(440-443) |
| shim 死亡兜底 | core/runtime/v2/shim.go:182-195 | 补发 TaskExit/TaskDelete |
| CRI 订阅 | internal/cri/server/service.go:302 | topic=="/tasks/oom", topic~="/images/" |
| CRI 事件循环 | internal/cri/server/events/events.go:126-186 | ns 过滤(135)、backoff(144-152) |
| CRI HandleEvent | internal/cri/server/events.go:322-392 | Exit/OOM/Image 分派 |
