# 控制器模式:Informer、工作队列与 Deployment 控制器

> 系列:源码深读·系统开源项目解读系列 第七卷《Kubernetes》
> 基线:master @ 517a94ff(2026-09-04)
> 源码路径约定:以下引用均相对仓库根目录 `kubernetes/`。

---

## ① 全景:从声明式 API 到控制循环

Kubernetes 控制面的核心不是"执行命令",而是"声明期望、持续调和(reconcile)"。用户提交 `Deployment.Spec`(期望状态),控制器做的事只有一件:比较期望与实际,不断把实际推向期望。这个模式在源码中有一句精炼的表达——`sharedIndexInformer` 的文档注释把整个控制面描述为"由 informer 组成的底层控制器支撑起来的高层控制器骨干":

> "This file implements a low-level controller that is used in sharedIndexInformer ... Such informers, in turn, are key components in the high level controllers that form the backbone of the Kubernetes control plane."(`staging/src/k8s.io/client-go/tools/cache/controller.go:36-43`)

通用骨架由四层组成,自上而下:

1. **Reflector**:通过 LIST+WATCH 从 apiserver 拉取对象变更,写入 DeltaFIFO;
2. **DeltaFIFO**:变更事件的"缓冲 + 合并"队列,同一 key 的多个 delta 攒成一条 `Deltas`;
3. **Indexer(本地缓存 Store)**:Pop 出来的对象落地为带索引的本地只读缓存,配合 Lister 供控制器无锁读;
4. **工作队列 + worker**:事件处理器不直接执行业务,只把对象 key 丢进限速队列,N 个 worker 逐个取出 key,执行 `syncHandler` 调和逻辑。

这条链路的每一环都在为同一目标服务:**把"事件驱动"(edge)可靠地转化为"状态驱动"(level)**——事件可能丢、可能乱、可能重复,但只要本地缓存最终与 etcd 一致,worker 每次调和都从缓存读全量状态,系统就收敛。

## ② Informer 三件套逐段解读

### 2.1 数据流总览

```
   kube-apiserver
     │  LIST (分页/watch-list 流式)
     │  WATCH (RV=lastSyncResourceVersion, 5~10min 随机超时)
     ▼
┌──────────────┐  Add/Update/Delete/Replace/Resync
│  Reflector   │──────────────►┌───────────────┐
│ (生产者)     │               │   DeltaFIFO   │
└──────────────┘               │ items: key→[]Delta │
        ▲  store.Resync()      │ queue: [key…]  │
        │  (周期性 Sync delta) └──────┬────────┘
        │                            │ Pop(Deltas)  [持锁回调]
        │                            ▼
        │               ┌─────────────────────────┐
        │               │ handleDeltas            │
        │               │  1. 更新 Indexer(缓存)│
        │               │  2. processor.distribute│
        │               └──────┬──────────┬───────┘
        │                      │          │
        │              Indexer │          │ 每监听者一条事件管道
        │        (Lister 读)   ▼          ▼
        │                 ┌────────┐  processorListener×N
        └── KnownObjects ─│ 磁盘?否│   addCh → ring buffer → nextCh
                          │ 本地缓存│   → ResourceEventHandler
                          └────────┘        │ enqueue(key)
                                            ▼
                                     workqueue(限速)
```

### 2.2 Reflector:LIST-WATCH 的执行者

Reflector 的主循环极简:`Run` 里一个带退避的无限循环反复调用 `ListAndWatch`,成功后重置退避计时:

```go
func (r *Reflector) RunWithContext(ctx context.Context) {
    // Until: immediate=true, sliding=true, 成功后重置退避
    _ = r.delayHandler.Until(ctx, true, true, func(ctx context.Context) (bool, error) {
        if err := r.ListAndWatchWithContext(ctx); err != nil {
            r.watchErrorHandler(ctx, r, err)
        }
        return false, nil
    })
}
```
(`staging/src/k8s.io/client-go/tools/cache/reflector.go:423-435`)

退避参数在文件头定义:初始 800ms、上限 30s,2 分钟无错误即重置,目标是 apiserver 不健康时把重试 QPS 压到约 0.22(`reflector.go:59-67`)。

`ListAndWatchWithContext` 的三步编排(`reflector.go:470-509`):

1. 若启用 `WatchListClient` 特性,先尝试 `watchList`——用 `SendInitialEvents=true` 的流式 watch 代替 LIST,收到 `initial-events-end` bookmark 才算同步完成(`reflector.go:785-808, 887-906`);
2. 否则走经典 `list()`:经 `pager` 分页拉全量,把 `listMetaInterface.GetResourceVersion()` 记为本次快照 RV,再 `syncWith → store.Replace` 整体灌入(`reflector.go:674-783, 911-917`);
3. `watchWithResync`:后台起 `startResync` 协程,前台进入 `watch` 消费循环。

关于 **ResyncChan**:题目中提到的 `resyncChan` 在本版本仍然存在,它返回一个定时器 channel 与清理函数,`resyncPeriod==0` 时直接返回永不触发的 nil channel(`reflector.go:445-456`)。`startResync` 每 tick 检查 `ShouldResync`(由 SharedInformer 注入,实为 `processor.shouldResync`),为真则调用 `store.Resync()` 让 DeltaFIFO 给每个已知 key 补一条 `Sync` delta(`reflector.go:514-536`)。注意:**resync 不访问 apiserver**,只是把本地缓存里的对象重新推给处理器——这是理解"周期性调和"与"网络流量"无关的关键。

watch 消费循环 `watch` 的几个防御性细节(`reflector.go:561-670`):

- 每次发起 watch 前检查 stopCh,watch 超时在 `[minWatchTimeout, 2*minWatchTimeout)` 随机取值(默认 5~10 分钟,`reflector.go:57-58, 588`),避免大量客户端同时断开造成惊群;
- `AllowWatchBookmarks: true`(`reflector.go:597`),bookmark 事件仅用于推进 RV,不进 store;
- 429 与连接拒绝类错误按退避重试 watch 而不是 relist(`reflector.go:607-615, isWatchErrorRetriable:1195-1205`);
- 收到 410 Gone(expired)时,`relistResourceVersion` 会返回 `""` 触发 quorum 全量 relist(`reflector.go:1116-1132, isExpiredError:1154-1160`)。

`handleAnyWatch` 是事件落地的最后一跳,按事件类型直接调 `store.Add/Update/Delete`(`reflector.go:1037-1073`),并推进 `lastSyncResourceVersion`——但有个微妙条件:只有收到过非 Added 事件后才开始传播 RV,以避免初始合成 Added 事件乱序污染 RV(`reflector.go:585-586, 621-638`)。

### 2.3 DeltaFIFO:合并非去重的变更账本

DeltaFIFO 的自我定位写在结构体注释里:它是"生产者-消费者队列,Reflector 是生产者,调 Pop 的是消费者",解决四个用例:**每个变更至多处理一次、处理时能看到自上次处理以来的全部变更、能感知删除、可周期性重处理**(`staging/src/k8s.io/client-go/tools/cache/delta_fifo.go:83-97`)。

核心数据结构(`delta_fifo.go:108-158`):

```go
type DeltaFIFO struct {
    lock sync.RWMutex
    cond sync.Cond
    // items: key → Deltas(至少 1 条)
    items map[string]Deltas
    // queue: key 的 FIFO 顺序,无重复;key 在 queue 中 ⇔ 在 items 中
    queue []string
    ...
}
```

两个设计要点:

**第一,key 去重、delta 追加。** 同一对象连续多次变更不会占多个队列槽位,而是追加到该 key 的 `Deltas` 尾部;只有当 key 不在 `items` 里时才进 `queue`(`queueActionLocked`,`delta_fifo.go:518-528`)。唯一做的去重是"连续两个 Deleted 合并",保留信息更多的那个(`dedupDeltas/isDeletionDup`,`delta_fifo.go:443-478`)。因此消费方拿到的是"该对象自上次消费以来的完整变更序列",最新状态在 `Deltas.Newest()`。

**第二,Replace 是删除的兜底。** relist 后的 `Replace(list, rv)` 除了把全量对象打上 `Sync/Replaced` delta,还会把"不在新列表里"的旧 key(包括队列中的与 KnownObjects 即 Indexer 中的)补发 `Deleted` delta,对象本体用 `DeletedFinalStateUnknown` 包裹(`delta_fifo.go:619-690`)。这解决了 watch 断连期间漏掉删除事件的经典难题;`DeletedFinalStateUnknown` 的定义与语义见 `delta_fifo.go:793-800`。

`Pop` 的语义值得咀嚼(`delta_fifo.go:562-608`):出队时把 key 从 `items` 与 `queue` 同时删掉,**先删后处理**,所以处理失败需要调用方用 `AddIfNotPresent` 塞回去;process 回调在持锁状态下执行,注释明确警告"process 应避免昂贵 I/O,否则 Add/Get 都会被阻塞"。`initialPopulationCount` 递减到 0 即宣告首次 LIST 消化完毕,`HasSynced` 变为 true(`checkSynced_locked`,`delta_fifo.go:369-382`)——这正是控制器启动时 `WaitForCacheSync` 等待的信号。

`Resync()` 则遍历 KnownObjects(即 Informer 的 Indexer)的每个 key,若该 key 当前没有排队中的 delta,则补一条 `Sync` delta(`delta_fifo.go:704-747`)。这就是 ②.2 中 reflector resync 定时器最终到达的地方。

### 2.4 Indexer:被忽视的第三件套

三件套的最后一员 Indexer 常被略过,但它是"读路径"的全部:控制器在调和时**绝不直接 GET apiserver**,而是通过 Lister 读 Indexer 里的内存快照。Indexer 在线程安全的 Store 之上维护多个副索引:`index map[string]indexMap` 按"索引名 → 索引值 → key 集合"组织,查询先经 `indexFunc` 得到索引值再取 key(`staging/src/k8s.io/client-go/tools/cache/index.go`)。Deployment 控制器的两个使用范例:pod informer 上按 ControllerRef UID 建索引,使"列出某 RS 的全部 Pod"从 O(全部 Pod) 降为 O(命中数)(`deployment_controller.go:162-165, 557-570`);Lister 本身就是 "Indexer + namespace 分桶" 的门面。写入路径上,Indexer 的增删改全部发生在 `handleDeltas` 持锁回调内,与 DeltaFIFO 的 `knownObjects` 视图保持同一把锁下的强一致——这正是 DeltaFIFO `Replace` 能可靠探测删除的前提(②.3)。

### 2.5 sharedIndexInformer 与 processorListener

`sharedIndexInformer` 由三部分组成:本地索引缓存 `indexer`、一个把 ListerWatcher 泵入 DeltaFIFO 并不断 Pop 处理的内部 `controller`、以及把通知分发给各客户端的 `sharedProcessor`(`staging/src/k8s.io/client-go/tools/cache/shared_informer.go:697-709`)。`Run` 时组装 Config 并把 `handleDeltas` 作为 Pop 的 Process 回调(`shared_informer.go:841-905`);内部的 `controller.processLoop` 就是一个不断 `Pop` 的死循环(`cache/controller.go:238-263`)。

`handleDeltas → processDeltas` 是"缓存写"与"事件分发"的合流点:对每条 delta,先写 Indexer 再通知 handler;`Sync/Replaced/Added/Updated` 统一处理——存在则 `Update+OnUpdate`,不存在则 `Add+OnAdd`(`cache/controller.go:823-881`)。`OnUpdate` 里有个精妙的判定:**ResourceVersion 未变的事件视为 resync 事件**,只分发给要求 resync 的监听者(`shared_informer.go:1091-1110`)。

事件分发端 `processorListener` 是"每个 handler 一条独立管道"的实现,注释自述其构造:**3 个 goroutine、2 个 channel、1 个无界环形缓冲**(`shared_informer.go:1337-1353`):

```go
func (p *processorListener) pop() {
    ...
    select {
    case nextCh <- notification:          // 交给 run()
        notification, ok = p.pendingNotifications.ReadOne()
        if ok { ... } else { nextCh = nil } // 无积压则摘除该 case
    case notificationToAdd, ok := <-p.addCh: // 接收分发
        if notification == nil { notification = notificationToAdd; nextCh = p.nextCh }
        else { p.pendingNotifications.WriteOne(notificationToAdd) } // 积压
    }
}
```
(`shared_informer.go:1444-1476`)

`pop` 负责把 `addCh` 的事件搬运到 `nextCh`,搬不动就压进 `pendingNotifications` 环形缓冲(无界——注释坦承:卡死的监听者会无限堆积直到 OOM,`shared_informer.go:1366-1374`);`run` 从 `nextCh` 逐条同步调用 handler 回调,panic 会被捕获并跳过该条、1 秒后继续(`shared_informer.go:1478-1521`)。这个两级结构的意义:**慢消费者不会拖慢 informer 的主循环,只会拖慢自己**;代价是内存无上界,所以官方注释要求"handler 必须快速处理,耗时工作丢给 workqueue"(`shared_informer.go:136-140`)。

Resync 的多 handler 协商也在这里:每个 listener 记录自己的 `requestedResyncPeriod`,下限 1s(`minimumResyncPeriod`,`shared_informer.go:993`);informer 的 `resyncCheckPeriod` 取所有 listener 请求值的交集逻辑(`AddEventHandlerWithOptions`,`shared_informer.go:999-1028`),reflector 每次 tick 调 `processor.shouldResync` 决定哪些 listener 参与本轮 resync(`shared_informer.go:1306-1324`)。

## ③ 工作队列:去重、延迟与限速

### 3.1 Type:dirty/processing 双集合去重

`workqueue.Typed` 用一个 FIFO 切片加两个集合实现"处理中重复入队不丢失"(`staging/src/k8s.io/client-go/util/workqueue/queue.go:190-222`):

```go
func (q *Typed[T]) Add(item T) {
    ...
    if q.dirty.Has(item) {           // 已排队待处理:直接吞掉
        if !q.processing.Has(item) { q.queue.Touch(item) }
        return
    }
    q.dirty.Insert(item)
    if q.processing.Has(item) { return } // 正在处理:标记 dirty,不重复入队
    q.queue.Push(item)
    q.cond.Signal()
}
```
(`queue.go:227-251`)

`Get` 把 item 从 queue 弹出并做 `dirty.Delete / processing.Insert`(`queue.go:265-284`);`Done` 时若发现该 item 处理期间又被标记过 dirty,就重新入队(`queue.go:289-302`)。合起来的不变式是:**同一 key 不会被两个 worker 并发处理;处理期间的新事件不会丢,但也不会重复排队**。这正是"事件是通知、调和靠全量状态"语义的队列层保障——worker 处理 key 时从 Lister 读到的是最新缓存,中途到达的多次变更自然被合并成一次重调。

### 3.2 DelayingQueue:最小堆 + 心跳兜底

`delayingType.AddAfter` 把( item, readyAt )塞进容量 1000 的 `waitingForAddCh`,由单一 `waitingLoop` 协程统一调度(`util/workqueue/delaying_queue.go:147-159, 249-268`)。循环每轮:把已到期的堆顶弹出入队、按最近到期时间设定 timer,然后 select 等待四种事件(stop/heartbeat/nextReadyAt/新条目)(`delaying_queue.go:276-352`)。两个细节:

- `maxWait = 10s` 心跳是保险丝,保证"已过期条目最多滞留 10 秒"(`delaying_queue.go:270-273`);
- `insert` 对已存在的条目只在能**更早**触发时才更新 readyAt(`delaying_queue.go:355-369`)。

### 3.3 RateLimitingQueue 与指数退避

`rateLimitingType` 只是薄封装:`AddRateLimited(item) = AddAfter(item, rateLimiter.When(item))`(`util/workqueue/rate_limiting_queue.go:130-148`)。默认限速器 `DefaultTypedControllerRateLimiter` 是取最大值复合器,内含两级(`util/workqueue/default_rate_limiters.go:50-56`):

```go
return NewTypedMaxOfRateLimiter(
    NewTypedItemExponentialFailureRateLimiter[T](5*time.Millisecond, 1000*time.Second),
    &TypedBucketRateLimiter[T]{Limiter: rate.NewLimiter(rate.Limit(10), 100)},
)
```

`ItemExponentialFailureRateLimiter` 按 `baseDelay * 2^failures` 计算退避、封顶 `maxDelay`,`When` 每调用一次失败计数 +1,`Forget` 清零(`default_rate_limiters.go:116-149`);`BucketRateLimiter` 则是全队列共享的 10 QPS/100 突发令牌桶(`default_rate_limiters.go:62-77`)。两层相乘的含义:**单个失败 key 指数退避,同时所有重试共享一个总吞吐上限**,防止某个坏对象引发的雪崩放大。

一个常被忽视的契约:构造函数注释反复强调 "Remember to call Forget!"(`rate_limiting_queue.go:63-66`)——控制器必须在 sync 成功时 `Forget(key)`,否则失败计数永不衰减,后续正常的重排队也会被指数拉长。Deployment 控制器的 `handleErr` 就是标准范例:成功/命名空间终止则 `Forget`;`NumRequeues < maxRetries(15)` 则 `AddRateLimited`;超过则放弃并 `Forget`(`pkg/controller/deployment/deployment_controller.go:53-60, 499-519`)。注释里甚至算好了 15 次对应的退避序列:5ms, 10ms, …, 82s。

## ④ Deployment 控制器:sync 流程逐段

### 4.1 装配:三个 informer 一个队列

`NewDeploymentController` 挂了三个 informer 的事件处理器:Deployment 全事件、ReplicaSet 全事件、Pod 仅 Delete(`pkg/controller/deployment/deployment_controller.go:123-150`),并给 pod informer 加了按 ControllerRef UID 的索引(`deployment_controller.go:162-165`)。事件处理器的共同模式是**"找出该对象背后的 Deployment,把它入队"**——`resolveControllerRef` 按 Name 查 Lister 再校验 UID(`deployment_controller.go:461-477`);孤儿 ReplicaSet 则反查所有 label 匹配的 Deployment 一并入队,让它们来"认领"(addReplicaSet,`deployment_controller.go:233-263`)。`updateReplicaSet` 还处理 ControllerRef 变更时新旧两个 owner 都要唤醒的边界(`deployment_controller.go:289-331`)。

`Run` 的启动序列是所有控制器的模板(`deployment_controller.go:171-199`):启动事件广播 → `WaitForNamedCacheSyncWithContext` 等三个缓存就绪 → 起 N 个 worker(`wait.UntilWithContext(ctx, dc.worker, time.Second)`)→ 阻塞在 ctx.Done,退出时 `queue.ShutDown()`。

### 4.2 syncDeployment 编排

```go
func (dc *DeploymentController) syncDeployment(ctx context.Context, key string) error {
    namespace, name, err := cache.SplitMetaNamespaceKey(key)
    ...
    deployment, err := dc.dLister.Deployments(namespace).Get(name)
    if errors.IsNotFound(err) { return nil }   // 已删除,直接退出
    d := deployment.DeepCopy()                 // 防止改写共享缓存
    ...
    rsList, err := dc.getReplicaSetsForDeployment(ctx, d)  // 认领/释放 RS
    if d.DeletionTimestamp != nil { return dc.syncStatusOnly(...) }
    if err = dc.checkPausedConditions(ctx, d); err != nil { return err }
    if d.Spec.Paused { return dc.sync(ctx, d, rsList) }
    if getRollbackTo(d) != nil { return dc.rollback(ctx, d, rsList) }
    scalingEvent, err := dc.isScalingEvent(ctx, d, rsList)
    if scalingEvent { return dc.sync(ctx, d, rsList) }
    switch d.Spec.Strategy.Type {
    case apps.RecreateDeploymentStrategyType:
        podMap, err := dc.getPodMapForDeployment(d, rsList)
        return dc.rolloutRecreate(ctx, d, rsList, podMap)
    case apps.RollingUpdateDeploymentStrategyType:
        return dc.rolloutRolling(ctx, d, rsList)
    }
    ...
}
```
(`pkg/controller/deployment/deployment_controller.go:574-660`,有删节)

要点逐条:

1. **先读缓存再 DeepCopy**:所有读都走 Lister(本地缓存),写才走 client;`DeepCopy` 注释明确"否则我们在改写自己的缓存"(`deployment_controller.go:597-598`);
2. **空 selector = 选择所有 Pod,直接告警并只推进 ObservedGeneration**(`deployment_controller.go:600-608`);
3. `getReplicaSetsForDeployment` 列出命名空间全部 RS,经 `ReplicaSetControllerRefManager.ClaimReplicaSets` 完成 adopt(给孤儿 RS 打上 controller ownerRef)/orphan(择不再匹配的 RS 摘除 ownerRef);认领前有一个**去缓存化的二次校验** `RecheckDeletionTimestamp`(quorum GET,对应 issue #42639)(`deployment_controller.go:524-549`);
4. 分支优先级:删除(只刷状态)→ paused → rollback → 缩放事件 → Recreate/RollingUpdate(`deployment_controller.go:617-659`)。

### 4.3 新 RS 的诞生:pod-template-hash 与 revision

`getAllReplicaSetsAndSyncRevision → getNewReplicaSet` 负责区分新旧 RS 并推进版本号(`pkg/controller/deployment/sync.go:124-134, 146-181`):

- `FindNewReplicaSet` 用 `EqualIgnoreHash`(比较模板时忽略 `pod-template-hash` label)找出与 Deployment 当前模板相同的 RS(`pkg/controller/deployment/util/deployment_util.go:616-640`);
- 找不到且 `createIfNotExisted` 为真时,基于 Deployment 的 pod template 新建 RS:计算 `pod-template-hash`(模板散列,label 保证新旧 RS 的 selector 互斥),revision 置为 `maxOldRevision+1`,并回写 Deployment 的 revision annotation;
- revision 语义:`deployment.kubernetes.io/revision` 单调递增,是 `kubectl rollout undo/rollback` 的定位依据(`sync.go:113-121` 的三步注释)。

### 4.4 滚动更新:rolloutRolling 的"先升后降"

`rolloutRolling` 每次调和只做**一步**——要么扩新、要么缩旧,然后立刻刷新状态并退出,靠下一轮调和继续推进(`pkg/controller/deployment/rolling.go:31-66`):

```go
newRS, oldRSs, err := dc.getAllReplicaSetsAndSyncRevision(ctx, d, rsList, true)
allRSs := append(oldRSs, newRS)
// Scale up, if we can.
scaledUp, err := dc.reconcileNewReplicaSet(ctx, allRSs, newRS, d)
if scaledUp { return dc.syncRolloutStatus(ctx, allRSs, newRS, d) }
// Scale down, if we can.
scaledDown, err := dc.reconcileOldReplicaSets(ctx, allRSs, ..., newRS, d)
if scaledDown { return dc.syncRolloutStatus(ctx, allRSs, newRS, d) }
if deploymentutil.DeploymentComplete(d, &d.Status) {
    if err := dc.cleanupDeployment(ctx, oldRSs, d); err != nil { return err }
}
return dc.syncRolloutStatus(ctx, allRSs, newRS, d)
```

**扩新**(`rolling.go:68-84`):新 RS 已超目标副本则缩回;否则 `NewRSNewReplicas` 计算本轮可扩数量——`maxTotalPods = spec.Replicas + maxSurge`,扩量 = `maxTotalPods - 当前总量`,且不超过目标副本(`deployment_util.go:817-836`)。

**缩旧**(`rolling.go:86-152`)是滚动更新最讲究的部分,`maxScaledDown = allPodsCount - minAvailable - newRSUnavailablePodCount`(`rolling.go:127-131`)。注释里给出的算例值得精读(10 副本、maxUnavailable=2、maxSurge=3):新 Pod 全部 crashloop 时 `13-8-5=0`,旧的一个也不会缩,避免可用性进一步恶化;回滚后 `13-8-1=4`,先缩 4 个坏 Pod。缩旧分两步:先 `cleanupUnhealthyReplicas` 清不健康副本(排序保证先删 not-ready 的,`rolling.go:155-189`),再 `scaleDownOldReplicaSetsForRollingUpdate` 按 `availablePodCount > minAvailable` 的余量缩旧 RS(`rolling.go:193-235`)。多版本并存时 `scale()` 还有按比例分配副本的 `GetReplicaSetProportion` 逻辑(`sync.go:329-398`,`deployment_util.go:479-497`)。

**清理**:`cleanupDeployment` 按 `RevisionHistoryLimit` 保留最新 N 个旧 RS,只删副本数为 0 的(`sync.go:441-476`)。

值得停下来想一想:为什么每次调和只前进一步,而不是在控制器内部写一个"扩一缩一"的循环把它推到终态?因为**副本从扩出到 Ready 需要分钟级的外部时间**(调度、拉镜像、探针通过),控制器若原地等待,会长时间占用 worker 并阻塞同队列的其他 Deployment。正确的姿势是:做一步可安全执行的变更,把当前进度写进 `status`(经 `syncRolloutStatus` 更新 conditions 与 `observedGeneration`),然后退出;Pod 变 Ready 触发的新事件或 resync 会自然唤醒下一轮调和。整个滚动更新因此被摊平成一串相互独立的短事务,任一环失败都由队列退避重试兜底——这是"调和函数必须快速返回"原则在业务层的直接体现。

### 4.5 回到队列

worker 从队列取 key → `syncHandler`(即 syncDeployment)→ `handleErr` 决定 Forget / AddRateLimited / 放弃(见 ③.3)。注意 sync 中所有会改变外界的动作(RS 的 Create/Update/Delete、Status 更新)都可能失败返回 error,由队列层统一退避重试——**控制器内部不为写操作写重试循环**,这是 workqueue 存在的全部意义。

## ⑤ Leader Election 与级联删除概览

### 5.1 Leader Election:Lease 资源锁

kube-controller-manager 同时只有一个实例在工作,靠 `client-go/tools/leaderelection` 实现:竞争对象是一个 `coordination/v1 Lease` 资源(`resourcelock/leaselock.go:31-39`),`holderIdentity/leaseDuration/renewTime` 直接映射到 `LeaseSpec` 字段(`leaselock.go:122-149`)。

参数约束在构造时强校验:`LeaseDuration > RenewDeadline > RetryPeriod * 1.2`,默认 15s/10s/2s(`leaderelection.go:76-91, 116-143`)。核心 `tryAcquireOrRenew` 是四步乐观流程(`leaderelection.go:444-515`):① 自己已是有效 leader 则直接 Update(乐观快路径);② Get 不到则 Create;③ 记录他人持有的有效租约则返回 false;④ 否则 Update 抢占(靠 RV 乐观并发,冲突即失败)。持有者 `renew` 循环在 `RenewDeadline` 内以 `RetryPeriod` 间隔续约,失败即交权(`leaderelection.go:279-312`);非持有者 `acquire` 以带抖动的 `RetryPeriod` 反复尝试(`leaderelection.go:252-276`)。**续约失败 → OnStoppedLeading → 组件自杀退出**,是控制面组件的标准姿势:宁可重启,不可双主。

### 5.2 ownerReference 与 GC 级联删除

从 Deployment 到 RS 到 Pod 的所有权链,靠 `metadata.ownerReferences`(controller=true)表达。级联删除由独立的 GarbageCollector 控制器完成:它把所有对象建成图,对每个对象的 owner 引用分类为 solid(存在)/dangling(悬空)/waitingForDependentsDeletion(`pkg/controller/garbagecollector/garbagecollector.go:464-489`),对悬空引用的从属对象执行删除;支持 Background / Foreground(从属对象先删,owner 挂 `foregroundDeletion` finalizer)/ Orphan(摘除 ownerRef,`orphanDependents`,`garbagecollector.go:683-715`)三种策略(`garbagecollector.go:628-654`)。对 Deployment 控制器而言,这意味着 `cleanupDeployment` 删 RS 时无需亲自删 Pod——GC 会顺着 ownerRef 清理。

### 5.3 认领机制

`BaseControllerRefManager.ClaimObject` 是 adopt/release 的决策核心(`pkg/controller/controller_ref_manager.go:69-128`):有主且 UID 不同则无视;有主是自己但 selector 不匹配则 release;孤儿且 selector 匹配则 adopt。adopt/release 都是 strategic-merge patch 增删 ownerRef(`controller_ref_manager.go:222-259`)。配套的 `ControllerExpectations`( expectations 机制)则解决"RS 扩缩副本时,Pod 事件还没回来前不要重复下发"的问题——用加/减两个计数器跟踪"期望的创建/删除",未满足或未过期就不启动新一轮 sync(`pkg/controller/controller_utils.go:122-134, 195-223`)。

## ⑥ 设计动机与取舍:level-triggered 为什么是 K8s 的灵魂

1. **edge 会丢,level 不会。** watch 断连、事件乱序、控制器重启,都会造成 edge 丢失。K8s 的解法不是"把事件做可靠"(那是消息队列的活),而是让每次调和都基于"全量当前状态"重算:`syncDeployment` 不关心"谁改了我",只关心"现在 RS 们长什么样"。DeltaFIFO 的 Replace 补发删除(②.3)、resync 周期重推 Sync delta,都是在为"错过 edge 也能靠 level 兜底"服务。
2. **ResyncPeriod 是有意的冗余。** 默认 resync 会把全量对象重推给 handler,看似浪费,实为自愈手段:任何因 bug、竞态、瞬时分 区而"调和了一半"的对象,都会在下一个 resync 周期被再次调和。代价是 handler 必须幂等且便宜——`ResourceEventHandler` 文档明确 OnUpdate "即使什么都没变也会被调用"(`cache/controller.go:271-276`)。
3. **去重发生在三个层次,各有含义。** DeltaFIFO 按 key 合并 delta(事件层);workqueue 按 key 去重(任务层);`updateReplicaSet` 里 `ResourceVersion 相同直接 return`(通知层,`deployment_controller.go:292-296`)。三层合起来,把"高频变更"折叠成"低频调和",apiserver 与控制器都按"对象数"而非"变更数"付费。
4. **乐观并发 + 补偿,而非悲观锁。** 组件间不抢分布式锁(除了 leader election 这一个"是否工作"的粗粒度锁),对象级并发靠 resourceVersion 的 compare-and-swap;写冲突就返回错误,交给 workqueue 退避重试。简洁性来自"失败是常态路径"的假设。
5. **取舍的另一面。** 这套机制并不便宜:每个 informer 一份全量内存缓存(O(对象数));无界环形缓冲与无界 DeltaFIFO 意味着慢消费者的爆炸上限是 OOM(`shared_informer.go:1366-1374` 的坦承);resync 的全量重推在十万级对象下是实打实的 CPU 开销。因此社区持续演进:watch-list 流式初始化降低 LIST 内存峰值(KEP-3157,`reflector.go:162-170`)、`TransformFunc` 在入缓存前裁剪字段省内存(`delta_fifo.go:160-176`)、实验性的 RealFIFO/批量处理(`cache/controller.go:1063-1094`)。
6. **与强一致系统的对照。** 传统分布式系统用"强一致存储 + 分布式锁 + 事务"保证正确性;K8s 把正确性拆成了三件更便宜的事:apiserver 侧的对象级乐观并发(resourceVersion CAS)、控制器侧的幂等调和(读全量、写期望)、以及 GC 侧的引用图清理。任何一环出现竞态或故障,系统的恢复方式都不是回滚,而是"下一轮调和把它算回来"。理解了这一点,就理解了为什么 K8s 里"先写后读"要靠 status + generation/observedGeneration 之类的代数比对(`deployment_controller.go:603-606`),以及为什么事件(Event)只是审计信息而从不参与调和决策——**可丢弃的永远不进关键路径**。

## ⑦ FAQ

**Q1:Informer 缓存读到旧数据怎么办?**
这是设计内行为:缓存只保证最终一致(`shared_informer.go:46-98` 的 eventually consistent 契约)。写后立读的需求要么改读自己的写入对象,要么像 adopt 前的 `RecheckDeletionTimestamp` 那样做一次去缓存 quorum GET(`deployment_controller.go:537-546`)。

**Q2:resync 和 relist 是一回事吗?**
不是。resync 纯本地:Reflector 定时器触发 `store.Resync()`,DeltaFIFO 补 Sync delta,零网络流量(`reflector.go:514-536`、`delta_fifo.go:704-719`)。relist 是 watch 断开/410 后重新 LIST 全量,代价高。

**Q3:DeltaFIFO 里同一对象反复变更,会不会撑爆内存?**
不会无限:同一 key 的 delta 只在队列里合并成一条 `Deltas`,queue 中该 key 只出现一次;消费时一次 Pop 带走全部积压变更。最坏情形是"消费停摆 + 变更持续",此时确实无界——所以 processLoop 消费不过来是严重事故。

**Q4:handler 里能不能直接做耗时工作?**
不能。文档明确要求把耗时工作转交给 workqueue(`shared_informer.go:136-140`);handler 慢只影响自己的 `pendingNotifications`,但会无界增长。标准做法就是 Deployment 控制器式的事件处理器:只 `queue.Add(key)`。

**Q5:worker 数量怎么定?同一 Deployment 会被并发调和吗?**
`Run(ctx, workers)` 决定并发度(kube-controller-manager 默认 5)。同一 key 不会被并发处理——`Typed.Get/Done` 的 processing 集合保证(`queue.go:199-203, 481-484` 的 worker 注释"enforces that the syncHandler is never invoked concurrently with the same key")。

**Q6:AddRateLimited 和 AddAfter 有什么区别?成功后为什么必须 Forget?**
AddRateLimited 的延迟由 rateLimiter 的失败历史决定(指数退避),AddAfter 是显式延迟。Forget 清空失败计数;不 Forget 则计数永久保留,之后每次重排队延迟都从高基数起步(`default_rate_limiters.go:116-149`、`rate_limiting_queue.go:63-66`)。

**Q7:DeletedFinalStateUnknown 是什么,控制器该怎么处理?**
relist 时发现"缓存里有、新列表里没有"或 watch 删除事件丢失时,DeltaFIFO 用它包裹"最后已知状态"补发 Deleted delta(`delta_fifo.go:616-690, 793-800`)。对象的 Obj 可能过期,但 Key 可靠;Deployment 控制器的 deleteReplicaSet/deletePod 都先做 tombstone 断言再取对象(`deployment_controller.go:214-230, 336-354`)。

**Q8:maxSurge/maxUnavailable 是百分比时按什么算?**
按 `spec.replicas` 换算(`GetScaledValueFromIntOrPercent`,`deployment_util.go:821`),surge 向上取整、unavailable 向下取整,两者联合解析见 `ResolveFenceposts`(`deployment_util.go:883-882` 注释含算例)。

**Q9:Deployment 删除时 RS/Pod 谁来删?**
控制器只刷状态(`deployment_controller.go:617-619`),真正级联删除由 GC 完成:删除 Deployment 时 apiserver 依据删除策略(默认 Background)让 GC 沿 ownerRef 图清理 RS 与 Pod(⑤.2)。

**Q10:为什么 leader election 默认参数是 15s/10s/2s?**
LeaseDuration 是"他人等多久才可抢",RenewDeadline 是"自己多久续不上就认输",RetryPeriod 是续约/抢锁节奏;三者满足 `15 > 10 > 2×1.2` 的硬约束(`leaderelection.go:76-91`)。LeaseDuration 越小故障切换越快,但对时钟漂移与 apiserver 抖动越敏感(`leaderelection.go:120-133` 注释)。

## ⑧ 深挖问题

1. **RV 传播的保守性**:`handleAnyWatch` 中 `propagateRVFromStart` 逻辑规定,watch 从空 RV(或 "0")启动时,必须等收到第一个非 Added 事件才把 RV 写入 `lastSyncResourceVersion`(`reflector.go:585-638`)。这与 watch-list 的 `initial-events-end` bookmark 如何统一?错误传播 RV 会导致什么具体故障(提示:410 循环)?
2. **processorListener 的 OOM 边界**:环形缓冲无界是已知取舍(`shared_informer.go:1366-1374`)。能否给 listener 加背压/丢弃策略?与"事件必须按序、至多一次送达 handler"的契约(`shared_informer.go:122-126`)如何相容?
3. **期望机制的普适性**:`ControllerExpectations` 只被 RS/Job 等少数控制器使用,Deployment 自身不用。为什么"滚动更新一步一调"的模式可以不依赖 expectations,而"一次扩 N 副本"的 RS 必须依赖?若去掉 expectations,RS 控制器在 Pod 创建慢时会发生什么抖动?
4. **maxScaledDown 公式的安全性**:`allPodsCount - minAvailable - newRSUnavailablePodCount`(`rolling.go:127-131`)把新 RS 的不可用副本计入"不可缩额度",避免了缩旧导致可用性下穿;但多版本 RS(>2 个)并存时,`cleanupUnhealthyReplicas` 按 `ReplicaSetsByCreationTimestamp` 从旧到新清理是否总是最优?构造一个反例。
5. **DeltaFIFO → RealFIFO 的演进**:`newQueueFIFO` 在 `InOrderInformers` 特性门开启时改用 RealFIFO,支持 `ReplacedAll/Bookmark/SyncAll` 等新 delta 类型与原子批量处理(`cache/controller.go:1063-1094`)。对比两者在"relist 后删除语义"与"事件批处理"上的差异,评估这对超大规模集群(百万对象)的内存与吞吐收益。

---

### 附:覆盖文件清单

| 文件 | 主题 |
| --- | --- |
| staging/src/k8s.io/client-go/tools/cache/reflector.go | LIST-WATCH、resyncChan、RV 管理 |
| staging/src/k8s.io/client-go/tools/cache/delta_fifo.go | DeltaFIFO、Replace/Resync、DeletedFinalStateUnknown |
| staging/src/k8s.io/client-go/tools/cache/shared_informer.go | SharedInformer、sharedProcessor、processorListener |
| staging/src/k8s.io/client-go/tools/cache/controller.go | 低层 controller、processDeltas |
| staging/src/k8s.io/client-go/util/workqueue/queue.go | Type/Typed 双集合去重队列 |
| staging/src/k8s.io/client-go/util/workqueue/delaying_queue.go | AddAfter、waitingLoop |
| staging/src/k8s.io/client-go/util/workqueue/rate_limiting_queue.go | AddRateLimited/Forget |
| staging/src/k8s.io/client-go/util/workqueue/default_rate_limiters.go | 指数退避 + 令牌桶 |
| staging/src/k8s.io/client-go/tools/leaderelection/leaderelection.go | LeaderElector、tryAcquireOrRenew |
| staging/src/k8s.io/client-go/tools/leaderelection/resourcelock/leaselock.go | Lease 锁实现 |
| pkg/controller/controller_utils.go | KeyFunc、ControllerExpectations |
| pkg/controller/controller_ref_manager.go | ClaimObject、adopt/release |
| pkg/controller/deployment/deployment_controller.go | 事件路由、worker、syncDeployment |
| pkg/controller/deployment/sync.go | scale、cleanupDeployment、getNewReplicaSet |
| pkg/controller/deployment/rolling.go | rolloutRolling、maxScaledDown |
| pkg/controller/deployment/util/deployment_util.go | MaxSurge/MaxUnavailable、EqualIgnoreHash、NewRSNewReplicas |
| pkg/controller/garbagecollector/garbagecollector.go | 级联删除策略概览 |
