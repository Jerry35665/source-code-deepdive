# C - 调度器:调度框架与算法

> 代码基线:kubernetes master @ 517a94ff(2026-09-04)。核心目录 `pkg/scheduler/`。
> 注:该基线相对经典教材描述已有明显演进——出现了 PodGroup/GenericWorkload 调度、OpportunisticBatching(KEP-5598)、SchedulerPopFromBackoffQ(KEP-5142)、AsyncAPICalls/APICacher、异步抢占(KEP-4832)等新机制,本文以实际代码为准并标注这些演进点。

## ① 全景:调度 = 过滤 + 打分 + 绑定的函数式流水线

kube-scheduler 的本质是一个**串行取件、并行评估、异步落库**的流水线:

1. **取件**:`Scheduler.Run` 用单个 goroutine 循环调用 `ScheduleOne`,它阻塞在 `sched.NextEntity`(即 `podQueue.Pop`)上取下一个待调度实体(pod 或 pod group)(`pkg/scheduler/scheduler.go:390`、`pkg/scheduler/scheduler.go:469`)。**整个调度器每个时刻只有一个调度周期在推进**(绑定周期异步并行)。
2. **调度周期(同步)**:更新快照 → PreFilter → Filter(逐节点并发)→ Score(并发打分 + 归一化)→ 选 host → assume → Reserve → Permit。
3. **绑定周期(异步)**:`go sched.runBindingCycle(...)` 起 goroutine(`pkg/scheduler/schedule_one.go:143`),执行 WaitOnPermit → PreBind → Bind(apiserver 调用)→ PostBind。

函数式视角:`pick(pod) = argmax_{n ∈ filter(snapshot, pod)} score(n, pod)`,其中 `filter`/`score` 是十几个插件的可组合集合,权重加权求和。快照(snapshot)是输入的不可变近似,assume 是把"将要发生"的绑定提前记入内存,从而解耦调度周期与 apiserver 往返延迟。

## ② 调度框架:扩展点逐段

框架把一个 Pod 的调度拆成一组扩展点,接口定义在 `staging/src/k8s.io/kube-scheduler/framework/interface.go`(pkg 侧门面在 `pkg/scheduler/framework/interface.go:193`)。设计上框架与内核类型解耦:接口全部下沉到 staging 的 `k8s.io/kube-scheduler/framework` 包,`pkg/scheduler/framework` 只保留 `Framework` 门面和少量调度器私有类型(NodeToStatus、PodsToActivate 等),为 out-of-tree 插件提供稳定 ABI。关键接口与行号:

| 扩展点 | 接口 | 位置 | 失败语义 |
|---|---|---|---|
| QueueSort | `QueueSortPlugin.Less` | interface.go:461 | 全局唯一,决定 activeQ 堆序 |
| PreEnqueue | `PreEnqueuePlugin` | interface.go:447 | 失败 → pod 标记 gated,进 unschedulable |
| PreFilter | `PreFilterPlugin.PreFilter` | interface.go:520 | 可返回节点子集直接剪枝;Unschedulable 保留抢占资格 |
| Filter | `FilterPlugin.Filter` | interface.go:549 | 逐节点;UnschedulableAndUnresolvable 表示抢占也无解 |
| PostFilter | `PostFilterPlugin.PostFilter` | interface.go:578 | 全部节点过滤失败后运行(抢占入口) |
| PreScore/Score | `ScorePlugin` | interface.go:632/653 | 0..100 分,权重加权 |
| Reserve | `ReservePlugin` | interface.go:670 | 两段式 Reserve/Unreserve,Unreserve 必须幂等 |
| Permit | `PermitPlugin` | interface.go:714 | 可返回 Wait,挂起 pod 等待 gang 成员 |
| PreBind/Bind/PostBind | interface.go:686/727/703 | Bind 返回 Skip 表示"我不处理,下一个来" |

调度周期与绑定周期的 ASCII 图(行号对应 `pkg/scheduler/schedule_one.go`):

```
ScheduleOne (schedule_one.go:69)
 └─ scheduleOnePod (:95)
     ├─ schedulingCycle (:171) ————— 同步,持有"调度线程"
     │   ├─ Cache.UpdateSnapshot           (:179)  快照增量更新
     │   ├─ schedulingAlgorithm            (:252)
     │   │   ├─ SchedulePod → findNodesThatFitPod (:590)
     │   │   │    ├─ RunPreFilterPlugins           (fw.go:943)
     │   │   │    ├─ [nominated/hint node 先试]    (:677)
     │   │   │    ├─ findNodesThatPassFilters      (:788) ← 并发 Filter
     │   │   │    └─ findNodesThatPassExtenders    (:903)
     │   │   ├─ prioritizeNodes (:954)  PreScore → Score → Normalize
     │   │   └─ [失败] RunPostFilterPlugins → 抢占 (:298)
     │   └─ prepareForBindingCycle (:198)
     │        ├─ assume (Cache.AssumePod)  (:330,:1069)
     │        ├─ RunReservePluginsReserve  (:341)
     │        └─ RunPermitPlugins → Wait? → AddWaitingPod (:213)
     └─ go runBindingCycle (:143) ————— 异步,可多线程
          ├─ RunPreBindPreFlights  (:415, NominatedNodeNameForExpectation)
          ├─ WaitOnPermit          (:435)  阻塞在 channel (<-waitingPod.s)
          ├─ SchedulingQueue.Done  (:457)  尽早释放 in-flight 记录
          ├─ RunPreBindPlugins     (:468)
          ├─ bind → RunBindPlugins (:480, DefaultBinder POST /bind)
          └─ RunPostBindPlugins    (:497)
```

几个运行时要点:

- **CycleState** 是一次调度周期的黑板:`framework.NewCycleState()` 每周期新建(`pkg/scheduler/schedule_one.go:123`),插件用 `Write/Read` 传递 PreFilter 计算结果;克隆语义由各插件自定(多数返回自身引用)。这个设计把"每节点重复计算"变成"每周期一次计算 + N 次读取",是 Filter 能做到 O(节点内 pod 数) 而非 O(集群 pod 数) 的前提。抢占模拟时框架会对 CycleState 做 Clone,AddPod/RemovePod 在克隆态上增量修正,不污染主周期状态。
- **状态码的分类学贯穿全框架**:`Unschedulable` 表示"驱逐别人可能有解",会进入抢占候选;`UnschedulableAndUnresolvable` 表示"怎么驱逐都没用"(如 nodeSelector 匹配不上、请求超过节点总量),抢占直接跳过;`Error` 则是调度器内部错误,按临时错误退避重试。NodeToStatus 用 `absentNodesStatus` 惰性表示"所有没记到 map 里的节点都是同一状态",避免 PreFilter 全局失败时逐节点写 map(`pkg/scheduler/framework/interface.go:33-61`)。
- **Skip 协议**:PreFilter/PreScore 返回 Skip 时,框架记录插件名,Coupled 的 Filter/Score 在本周期被跳过(`pkg/scheduler/framework/runtime/framework.go:969-972`、`framework.go:1387-1390`)。
- **Multipoint 展开**:默认插件只写一遍 `MultiPoint`,框架按插件实现的接口自动展开到各扩展点(`pkg/scheduler/framework/runtime/framework.go:659` `expandMultiPointPlugins`)。
- **绑定周期失败的语义边界**:注释明确"Permit 是最后一个能判 Unschedulable 的点;PreBind/Bind 失败只能进 BackoffQ 重试"(`pkg/scheduler/schedule_one.go:451-453`)——这是理解错误分类的关键。

## ③ scheduleOne 主流程逐段解读

### 3.1 快照与起点轮转

每周期先把 cache 的增量合并进 `nodeInfoSnapshot`(`schedule_one.go:179`),之后 Filter/Score 全部读快照,不再碰带锁的 cache。快照更新是增量的:`cacheImpl.UpdateSnapshot` 只处理自上次以来变过的节点(cache 内部用链表把脏节点移到头部来追踪,`backend/cache/cache.go:206-324`),因此节点数固定的大集群里这一步接近 O(变化数) 而非 O(节点数)。为避免大集群里总从头扫节点,`nextStartNodeIndex` 记录上周期处理到的位置,本轮从它继续(`schedule_one.go:703-704`):

```go
// schedule_one.go:702-704
processedNodes := len(feasibleNodes) + diagnosis.NodeToStatus.Len()
sched.nextStartNodeIndex = (sched.nextStartNodeIndex + processedNodes) % len(allNodes)
```

这个"轮转起点"是调度器里少有的公平性设计:连续调度一批相似 pod 时,不会让字典序靠前的节点永远先被评估,从而在 LeastAllocated 打分近似退化的场景下仍保持均匀分散。

### 3.2 提前短路的三条路径

1. **单节点可行即选**:只剩 1 个可行节点时跳过打分(`schedule_one.go:605-615`)。
2. **无打分器 + 无 extender 过滤时,`numNodesToFind = 1`**:找到一个能跑的节点就走(`schedule_one.go:797-799`)。
3. **NominatedNodeName / 批处理 hint 先试**:抢占提名的节点或 OpportunisticBatching 给出的 nodeHint 若通过 Filter 直接采用,否则才全量扫描(`schedule_one.go:677-686`)。

这三条短路揭示了一个容易被忽略的事实:调度结果并不总是"全集群最优"。`numNodesToFind` 的采样截断意味着 Filter 阶段先找到的那批节点构成打分的样本集,而"先找到"受 `nextStartNodeIndex` 轮转和并发调度顺序影响。这是刻意的工程折衷——k8s 用"足够好的节点"换"每秒多调度几百个 pod",并把严格最优的需求交给 topology spread 约束或外部批量调度器表达。

### 3.3 并发 Filter(代码原文)

Filter 是"逐节点并发、够数即停"的扇出模型(`pkg/scheduler/schedule_one.go:822-857`):

```go
checkNode := func(i int) {
    nodeInfo := nodes[(sched.nextStartNodeIndex+i)%numAllNodes]
    status := schedFramework.RunFilterPluginsWithNominatedPods(ctx, state, pod, nodeInfo)
    if status.Code() == fwk.Error { errCh.SendWithCancel(...); return }
    if status.IsSuccess() {
        length := atomic.AddInt32(&feasibleNodesLen, 1)
        if length > numNodesToFind {
            cancel(errors.New("findNodesThatPassFilters has found enough nodes"))
            atomic.AddInt32(&feasibleNodesLen, -1)
        } else { feasibleNodes[length-1] = nodeInfo }
    } else { result[i] = &nodeStatus{...} }   // 失败原因记入 diagnosis
}
schedFramework.Parallelizer().Until(ctx, numAllNodes, checkNode, metrics.Filter)
```

要点:并发度由 `Parallelizer`(默认 16,`scheduler.go:187` `WithParallelism`)经 chunk 切分(`parallelize/parallelism.go:69-78`);**找够 `numNodesToFind` 个就 cancel 其余 goroutine**;失败节点状态写入 `diagnosis.NodeToStatus` 供 PreFilter 失败消息与抢占复用。`numFeasibleNodesToFind` 自适应:`percentage = 50 - numAllNodes/125`,下限 5%、且至少 100 个节点(`schedule_one.go:875-901`,常量 `:59,:64`)。

每个节点的 Filter 之前还要跑 `RunFilterPluginsWithNominatedPods`(`runtime/framework.go:1284`):把**优先级 ≥ 当前提名到该节点的 pod** 先"虚加"进 NodeInfo 和 CycleState 跑第一遍,全部通过再用原始状态跑第二遍——保守双重检查,避免提名 pod 把资源"看起来可用"实际被占(`framework.go:1288-1305` 注释,`addGENominatedPods` :1334)。

### 3.4 打分与归一化

`prioritizeNodes`(`schedule_one.go:954`)→ `RunScorePlugins`(`runtime/framework.go:1414`):先并发对每个节点跑全部插件的 `Score`(原始分),再并发跑每个插件的 `NormalizeScore`,最后加权求和并做范围校验(`runtime/framework.go:1567-1585`):

```go
if score > fwk.MaxScore || score < fwk.MinScore {
    err := fmt.Errorf("plugin %q returns an invalid score %v, ...", pl.Name(), score)
    errCh.SendWithCancel(err, cancel); return
}
weightedScore := score * int64(weights[i])
nodePluginScores[i] = fwk.PluginScore{Name: pl.Name(), Score: weightedScore}
totalScore += weightedScore
```

分数界为 [0,100](`staging/.../framework/interface.go:331,:334`)。最终 `NewSortedScoredNodes(priorityList).Pop()` 取最高分(`schedule_one.go:622-623`),同分用 `Randomizer` 随机打散(`framework/sorted_nodes.go:41-43`)。注意 3.2 的短路:默认配置下大多数 pod 只对 ≥100 或 5% 的节点打分——**打分的样本集本身就是被 Filter 采样截断的**。

### 3.5 assume:两阶段的粘合剂

选中节点后,`assume` 把 pod 的 `Spec.NodeName` 直接改写并放入 scheduler cache(`schedule_one.go:1069-1104`),随后 cache 把该 pod 计入节点的 requested/affinity 索引(`backend/cache/cache.go:447-460` `AssumePod` → `addPod(..., true)`)。这样下一个调度周期看到的快照已包含本 pod 的占用,而真实的 apiserver Bind 在异步绑定周期里才发生。**assume 的本质是把 pod 的四种状态机(队列中 → 调度中 → assumed → bound)的前两段切进调度器内存,后两段交给 apiserver/informer 回流收敛**,调度器由此获得"不阻塞的吞吐",代价是要处理三条时序风险:

1. assume 后 informer 还没看到 bound 版本,期间同 pod 的更新事件可能把旧版本写回 cache —— `skipPodSchedule` 用 `Cache.IsAssumedPod` 拦截重复入队的 assumed pod(`schedule_one.go:567-576`);
2. Bind 失败必须显式回滚(见下);
3. 绑定周期里 pod 已占用资源,若同时被选为更高优先级调度的 victim,需要在内存里取消它(`executor.go:116-124` 的 PodInPreBind 机制),否则会出现"幽灵占用"。

失败回滚是 `unreserveAndForget`(`schedule_one.go:368`):先跑 `RunReservePluginsUnreserve` 再 `Cache.ForgetPod`(`cache.go:477`)。绑定成功后 informer 收到 `assignedPod(newPod)` 更新事件,转成 `addAssignedPodToCache` 并从队列移除旧记录(`eventhandlers.go:181-191`)——cache 中 assumed 的 pod 被真实版本覆盖,状态机闭环。

### 3.6 Bind 调用

`bind` 先让 extender 有机会当 binder,否则走 Bind 插件(`schedule_one.go:1109-1120`)。DefaultBinder 构造 `v1.Binding` 对象 POST 到 apiserver 的 `pods/{name}/bind` 子资源(`framework/plugins/defaultbinder/default_binder.go:45-67`;`util/utils.go:111-117` 带重试)。启用了 `SchedulerAsyncAPICalls` 时改经 `APICacher/APIDispatcher` 异步下发(`default_binder.go:52`)。

## ④ 三队列与 backoff:调度队列的状态机

`PriorityQueue` 由三部分组成(`backend/queue/scheduling_queue.go:199-263`):`activeQ`(堆,QueueSort 排序)、`backoffQ`(堆,按 backoff 到期时间排序)、`unschedulableEntities`(map)。此外还有 pod group 专用的 `pendingPodGroupPods`/`incompletePodGroupPods`/`workloadForest`(仅 GenericWorkload 启用时使用,`scheduling_queue.go:217-229`)。

### 4.1 Pop 循环与并发模型

**不是一 pod 一协程**。`Run` 起一个 goroutine `wait.UntilWithContext(ctx, sched.ScheduleOne, 0)`(`scheduler.go:469`),Pop 阻塞在 `sync.Cond` 上(`backend/queue/active_queue.go:313-335`):

```go
// active_queue.go:320-335
func (aq *activeQueue) unlockedPop(logger klog.Logger) (framework.QueuedEntityInfo, error) {
    var entity framework.QueuedEntityInfo
    for aq.queue.Len() == 0 {
        if aq.backoffQPopper != nil && aq.backoffQPopper.lenBackoff() != 0 { break }
        if aq.closed { return nil, nil }
        aq.cond.Wait()
    }
    ...
```

选择用函数 + 条件变量而不是 channel 是有注释解释的:`scheduler.go:68-72` 指出调度一个 pod 可能耗时很长,若走 channel,pod 会在 channel 里"变陈旧",而堆可以随时按最新优先级重排。这也是为什么入队方(`add`/`moveToActiveQ`)从不直接唤醒 Pop,而是统一在锁外调 `activeQ.broadcast()`(`scheduling_queue.go:810`,`active_queue.go:571-573`)——保证 Pop 被唤醒时堆头已经是最高优先级实体。

Pop 时 pod 进入 `inFlightPods`,同时在 `inFlightEvents` 链表上落一个标记;之后发生的集群事件按序追加在该链表后(`active_queue.go:188-203`)。当 pod 失败归来(`AddUnschedulablePodIfNotPresent`,`scheduling_queue.go:1079`),`determineSchedulingHintForInFlightPod`(`:1038`)回放**调度期间错过的全部事件**,用 QueueingHint 判定这次失败是否其实已被某个事件修复,若是则直接回 activeQ 而非 unschedulable——这是 v1.31 引入的 in-flight 事件机制,解决了"调度中发生的事件丢失"的竞态。`Done(uid)` 尽早释放链表头部(`bindingCycle` 在 WaitOnPermit 之后立刻调用,`schedule_one.go:457`;`active_queue.go:514-555` 的裁剪逻辑:链表头部到下一个 pod 标记之间的事件已无人引用,可以整段删除)。

### 4.2 backoff 与两支退避堆

backoff 指数退避:初始 1s、上限 10s(`scheduling_queue.go:78,:82`),`1s << (count-1)` 截断到 max(`backend/queue/backoff_queue.go:249-266`)。失败原因分两类,入不同的堆(`backoff_queue.go:300-325`):

- **插件拒绝**(UnschedulablePlugins/PendingPlugins 非空)→ `entityBackoffQ`;
- **临时错误**(网络等,无拒绝插件)→ `entityErrorBackoffQ`(`ConsecutiveErrorsCount` 计数,`scheduling_queue.go:1103-1111`)。

区分两类失败是必要的:插件拒绝意味着"集群状态不满足",重试必须等事件;临时错误意味着"集群状态可能没变",只能靠定时重试兜底,且错误连续计数在收到正常拒绝时清零。backoff 到期时间的计算是惰性缓存:实体上记 `BackoffExpiration`,失败归类或时间戳变化时清空缓存重算(`scheduling_queue.go:1114-1119`)。

`Run` 起两个后台 goroutine(`scheduling_queue.go:500-507`):一个对齐 1 秒窗口周期性 `flushBackoffQCompleted`(backoff 到期 → activeQ);另一个每 30s `flushUnschedulableEntitiesLeftover`(滞留超过 `podMaxInUnschedulablePodsDuration` 默认 5 分钟则强制 flush,`:65,:1314-1336`)。flush 出来的 pod 会置 `WasFlushedFromUnschedulable`,成功调度后计入 `pod_scheduling_after_flush` 指标(`schedule_one.go:492-495`)。

### 4.3 事件驱动的 requeue:QueueingHint

`MoveAllToActiveOrBackoffQueue` 先用 `isEventOfInterest` 剪掉没人关心的事件,再对 unschedulable 中每个实体问 `isPodWorthRequeuing`(`scheduling_queue.go:578-675`):只咨询**当初拒绝它的那些插件**注册的 `QueueingHintFn`,返回 `Queue`(→ backoffQ/activeQ)、`QueueSkip`(留在原地)或 Pending 插件的 `Queue`(→ 立即 activeQ)。三级策略枚举在 `:512-519`。锁序有严格注释:`SchedulingQueue.lock > activeQueue.lock > backoffQueue.lock > nominator.nLock`(`scheduling_queue.go:205-207`)。整个三队列状态机可以画成:

```
                     新 pod (eventhandlers.Add) / Activate / flush
                          │
                          ▼
                   ┌─────────────┐  PreEnqueue 失败(如 SchedulingGates、抢占进行中)
                   │   activeQ   │──────────────────────────┐
                   │ (堆:QueueSort)│◄──── backoff 到期         │
                   └──────┬──────┘   (flushBackoffQCompleted)│
                          │ Pop                              ▼
                          ▼                          ┌──────────────┐
                    调度 + 绑定周期                    │ unschedulable │
                          │ 失败                      │  Entities    │
                          └─────────────────────────►│  (map+gate)  │
                              AddUnschedulablePod…   └──────┬───────┘
                                    ▲      匹配 QueueingHint │ 5min flush
                                    │      的事件(含 in-flight 回放)
                                    └───────────────────────┘
```

unschedulable 不是队列而是"带原因的停车场":每个实体记着 `UnschedulablePlugins`/`PendingPlugins`(拒绝它的插件集合),集群事件到来时只询问这些插件注册的 hint,答案是 Queue 才搬走——这把无谓重试的量级从"事件数 × 停车场大小"降到"真正相关的 (事件, pod) 对"。

## ⑤ 关键插件算法

### 5.1 NodeResourcesFit:过滤

Pod 请求向量在 PreFilter 一次计算:常规容器求和、init 容器逐维取 max、加 overhead(`noderesources/fit.go:296-333`)。Filter 就是逐维比较 `request > allocatable - requested`(`fit.go:713-802`),要点:

- 先查 `AllowedPodNumber`(pod 数上限,`fit.go:716-725`);
- `Unresolvable` 标志:**当请求超过节点总量时**置位,状态升级为 UnschedulableAndUnresolvable,告诉抢占"别在我身上浪费时间"(`fit.go:736-744`);
- 事件注册体现了 QueueingHint 的精细度:只对"已调度 pod 被删除且在目标 pod 关心的资源维度上确实变小"或"节点 allocatable 增加"才返回 Queue(`fit.go:364-387`,资源比对 `fit.go:475-522`)。

### 5.2 NodeResourcesFit:打分(Binpack vs Spreading 的当代形态)

策略表在 `fit.go:65-90`:LeastAllocated(spreading)/MostAllocated(binpack)/RequestedToCapacityRatio(自定义曲线)。默认 LeastAllocated,权重 1(`apis/config/v1/default_plugins.go:43`);PodTopologySpread 和 InterPodAffinity 默认权重 2(`default_plugins.go:48-49`),TaintToleration 权重 3、NodeAffinity 权重 2(`:40-41`)。 LeastAllocated 公式(`least_allocated.go:52-61`):

```go
func leastRequestedScore(requested, capacity int64) int64 {
    if capacity == 0 { return 0 }
    if requested > capacity { return 0 }
    return ((capacity - requested) * fwk.MaxNodeScore) / capacity
}
```

一个微妙点:打分用 `requested = allocated + podRequests`(`resource_allocation.go:190`),且 CPU/内存用 **non-zero requested**(未声明 request 的容器按默认值 100m CPU/200Mi 内存计,`resource_allocation.go:204,:245-249`)。BalancedAllocation 则比较加 pod 前后的 CPU/Mem 配比方差,把"改善量"折算进 [50,100](`balanced_allocation.go:204-218`)。

### 5.3 NodeAffinity 与 TaintToleration

NodeAffinity 的 Filter 就是 `nodeSelector/requiredNodeAffinity.Match(node)`,失败返回 UnschedulableAndUnresolvable(`nodeaffinity/node_affinity.go:212-244`)。TaintToleration 的 Filter 只容忍 NoSchedule/NoExecute(`taint_toleration.go:118`);Score 统计节点上不能被容忍的 PreferNoSchedule 数量,再 `DefaultNormalizeScore(max, reverse=true, ...)` 反向归一化成"越能容忍分越高"(`taint_toleration.go:197-214`,`helper/normalize_score.go:27`)。

### 5.4 InterPodAffinity:对称问题与 topology map

Pod 亲和的难点是**双向性**:新 pod 有 affinity 规则,已运行 pod 的 anti-affinity 规则同样能拒绝新 pod。所谓"对称问题"指的是:判断节点 N 能否放新 pod P,需要同时回答三个方向的问题——(a) P 的 required affinity:节点(或其拓扑域)上是否已有匹配 P 亲和规则的 pod;(b) P 的 required anti-affinity:节点上是否已有与 P 反亲和规则冲突的 pod;(c) 现有 pod 的 anti-affinity:节点上是否有 pod 的反亲和规则拒绝 P。前两者语义是"找满足全部项的单个 pod"(AND 语义),第三者语义是"任一冲突即拒"(OR 语义)。由于 (a) 的目标可能是任意拓扑域(如 zone)上的 pod,PreFilter 必须扫全集群构建三张 topologyPair→count 表:existing anti-affinity(现有 pod 反亲和拒新 pod)、incoming affinity/anti-affinity(`interpodaffinity/filtering.go:93-134`)。这是 O(集群 pod 数) 的开销,Preemption 的 AddPod/RemovePod 增量回放正是为了不在每次 victim 模拟时重建该表(`interface.go:508-515` PreFilterExtensions)。

一个不显然的边界情况是**自亲和**(pod 匹配自己的亲和规则):当集群里还没有任何匹配 pod 时,`clusterWideAffinityCounts` 为空,框架靠"计数为 0 则放行第一个 pod"的特判让自亲和组能落地(`filtering.go:79-85` 注释);hostname 快速路径下则改用全局计数器 `matchingHostScopedAffinityPodsCount` 维护同一语义(`filtering.go:186-200`)。新基线还加了 hostname 快速路径:`kubernetes.io/hostname` 维度的规则可完全绕过全局拓扑图,只在节点本地检查(`filtering.go:44-92` 的长注释与 `classifyTermsBasedOnScope` :227)——官方注释里给出了为什么亲和项不能按 scope 拆开、而反亲和项可以拆开的完整推理(AND 语义要求跨 scope 联合匹配,OR 语义允许独立短路)。打分侧 PreScore 并行扫描全集群节点累积 topologyScore(亲和为正、反亲和为负),Score 只查候选节点的 label 命中(`scoring.go:190-248`),NormalizeScore 做 min-max 归一(`scoring.go:260-292`)。**注意其代价模型:Incoming pod 无 preferred 亲和时只扫 `HavePodsWithAffinityList()` 节点,否则全量**(`scoring.go:150-164`)。

## ⑥ 抢占(preemption)

### 6.1 入口与评估

调度失败(FitError)且无 PodGroup 上下文时运行 PostFilter(`schedule_one.go:292-311`)→ `DefaultPreemption.PostFilter` → `Evaluator.Preempt`(`framework/preemption/preemption.go:181`)。评估流程(`preemption.go:98-163`):

1. 取 informer 中的最新 pod 版本;
2. `PodEligibleToPreemptOthers`:`preemptionPolicy=Never` 拒绝;提名节点上已有终止中 victim 则不再重复抢占(`defaultpreemption/default_preemption.go:451-476`);
3. 候选节点只取 **Filter 阶段状态为 Unschedulable(可解)的节点**——`NodeToStatus.NodesForStatusCode(Unschedulable)`,UnschedulableAndUnresolvable 的直接排除(`preemption.go:207`,`framework/interface.go:100-131`);
4. `DryRunPreemption` 随机 offset + 按百分比/绝对数采样节点(`default_preemption.go:248-267`),对每个候选跑 `SelectVictimsOnNode`。

### 6.2 victim 选择(SelectVictimsOnNode)

核心是"全删→试放→按重要性回赎"(`defaultpreemption/default_preemption.go:286-441`):

```go
// 1) 把本节点所有低优先级 victim 全部从 NodeInfo 移除
for _, victim := range potentialVictims { removeVictim(victim) }
// 2) 全删后仍放不下 → 该节点无资格
if status := pl.fh.RunFilterPluginsWithNominatedPods(...); !status.IsSuccess() { return }
// 3) 按重要性降序回赎;先赎 PDB 违反者,放得下就赎回
sort.Slice(potentialVictims, func(i, j int) bool {
    return pl.MoreImportantVictim(potentialVictims[i], potentialVictims[j]) })
violatingVictims, nonViolatingVictims := preemption.FilterVictimsWithPDBViolation(...)
```

每次回赎都要重跑 Filter + PreFilterExtension AddPod(增量修 topology 计数)。重要性排序:优先级 > (victim 类型:CPG>PodGroup>Pod) > 存活时长 > 组大小(`default_preemption.go:141-146`)。最终节点间择优 `pickOneNodeForPreemption` 的硬编码字典序:PDB 违反数 → 最高 victim 优先级 → victim 优先级总和 → victim 数量 → 最高优先级 victim 的启动时间(`preemption.go:329-334`)。

### 6.3 执行:_deletePod 逻辑概览

`Executor.PreemptPod`(`framework/preemption/executor.go:104-161`)三种分支:

1. victim 是 **WaitingPod**(卡在 Permit)→ 内存中直接 `waitingPod.Preempt()`,不发删除调用(`executor.go:111-115`);
2. victim 正在 **preBind 阶段** → `podInPreBind.CancelPod()` 取消绑定协程(`executor.go:116-124`;配对机制在 `schedule_one.go:459-466` 的 `AddPodInPreBind` 与 `runtime/pods_in_prebind_map.go`);
3. 否则走 apiserver:先 patch `DisruptionTarget` condition,再 `DeletePod`(DELETE 带 gracePeriod,`executor.go:125-152`,`util/utils.go:196`)。

执行可异步(KEP-4832):`prepareCandidateAsync` 起**独立 context 的 goroutine**(`executor.go:199-312`),并行驱逐除最后一个之外的所有 victim,最后一个串行处理并在 `lastVictimsPendingPreemption` 登记,供 `PreEnqueue` 判断"抢占已收尾但事件未到"避免误 gate(`executor.go:268-304`,`default_preemption.go:165-216`)。抢占比 Pods 多一个时才需要此协议,否则删除事件本身即可唤醒队列。被抢占者退出后,preemptor 依靠 `NominatedNodeName` 在下个周期优先重试提名节点(`schedule_one.go:674-686`)。

把抢占全流程串起来看,它是一次**跨调度周期的事务**:PostFilter 阶段"提交"的是提名与删除意图,真正的"生效"要等 victim 优雅退出、事件回流、preemptor 重新走完整调度周期。任何一环失败(删除 API 失败、victim 卡在不可终止状态、提名节点被别的 pod 抢先占据)都不会回滚到抢占前状态,而是靠事件驱动的重试收敛。理解这一点,才能理解为什么抢占代码里到处是"失败但不致命"的容错分支(如 `executor.go:262-266` 清除提名失败仅记日志不返回错误)。

## ⑦ 设计动机与取舍

1. **Predicate/Priority 拆分的存续**:旧调度器的 predicates/priorities 被框架扩展点替代,但"硬过滤先行、软打分随后"的结构保留——因为 filter 是可剪枝的(找到 numNodesToFind 即停),score 必须对全部幸存者计算。让昂贵检查(卷绑定、拓扑)早退,是吞吐的第一杠杆。
2. **默认权重即立场**:NodeResourcesFit(LeastAllocated)权重 1、PodTopologySpread 2、InterPodAffinity 2(`default_plugins.go:40-52`)。k8s 从 1.x 时代的 spreading 默认 SelectedSpread 演进为:资源维度默认"最少占用"(倾向 spreading,防止热点),同时把 binpack 的诉求移交给用户显式配置 `MostAllocated`/`RequestedToCapacityRatio` 或 PodTopologySpread 的 constraints。**争论的本质**:binpack 提高碎片利用率/利于缩容,spreading 降低单机过载爆炸半径;k8s 选择保守 spreading 为默认、策略可插拔,把选择题交给集群管理员。
3. **快照 + assume 而非分布式锁**:调度正确性建立在对"过期快照"的容忍上——误判由 kubelet admission/事件回流兜底。assume 用乐观并发换吞吐:调度周期不等 Bind 的 RTT。代价是处理 cache 与 apiserver 的偏差(`fit.go:809-847` 甚至为 in-place resize 专门做了 delta 补偿)。
4. **单调度循环 + 异步绑定**:`ScheduleOne` 串行保证"同周期内 resource 语义一致",绑定 goroutine 化让 apiserver 慢不阻塞调度。`Done()` 在 WaitOnPermit 后立刻调用(`schedule_one.go:455-457`)体现内存优化的斤斤计较。
5. **把"何时重试"做成一等公民**:从 unschedulableQ + 粗暴 flush,演进到 QueueingHint(插件声明什么事件能解决我的拒绝)→ in-flight events → PreQueueingHint(先挑 pod 再跑 hint)。这是调度器近年最重的投入,因为大集群 80% 的 CPU 浪费在"无效重试不可调度的 pod"上。
6. **抢占的保守性**:只对 Unschedulable(可解)节点做 dry-run、victim 必须优先级更低、PDB 违反者优先回赎、抢占失败不影响 pod 已有提名——每一步都在限制抢占的破坏半径。
7. **新演进的一体化方向**:本基线里 PodGroup 调度(`schedule_one_podgroup.go`)、gang 插件、TopologyAwarePlacement 等把"批量原子调度"从外件(Volcano/Kueue 领域)往内核搬;`SignPlugin` 签名 + 结果缓存则把"相同 pod 不必重复算"做成框架能力。内核调度器正在从"单 pod 最优放置"转向"workload 感知",但函数式扩展点的骨架未变——新能力全部以新扩展点(PlacementGenerate/PlacementScore/PodGroupPostFilter/PlacementFeasible)嫁接在原流水线上,而非另起炉灶。

## ⑧ FAQ

**Q1:调度器是每个 pod 一个 goroutine 吗?**
不是。调度循环单线程(`scheduler.go:469`),内部 Filter/Score 用 Parallelizer(默认 16 worker)对节点分片并发;绑定周期才 `go runBindingCycle` 异步化,因此可同时存在多个绑定中的 pod,但同一时刻只有一个调度周期(`schedule_one.go:143`)。

**Q2:Filter 和 PreFilter 的分工?**
PreFilter 每周期跑一次,做全集群级预处理(如 InterPodAffinity 的 topology map)并可一次性把候选缩到子集;Filter 每个候选节点跑一次,读 PreFilter 写入 CycleState 的缓存结果做 O(节点内 pod 数) 的判断(如 `fit.go:657`)。

**Q3:pod 调度失败后会立刻重试吗?**
不会。走 `AddUnschedulablePodIfNotPresent`:有 rejector 插件记录时,只有匹配 QueueingHint 的集群事件或 5 分钟 flush 才会把它捞回;临时错误(无插件拒绝)退避后回队列(`scheduling_queue.go:1103-1149`)。

**Q4:backoff 时长怎么算?会被绕过吗?**
`initial << (count-1)` 封顶 max,默认 1s→10s;pod group 按 sqrt(组大小) 放大上限(`backoff_queue.go:249-266`)。Pending 插件的 hint 返回 Queue 时可 `queueImmediately` 跳过 backoff 直达 activeQ(`scheduling_queue.go:654-658`)。

**Q5:assume 了但 Bind 失败会怎样?**
绑定周期错误路径调 `unreserveAndForget`:Unreserve 插件回滚 + `Cache.ForgetPod`,同时以 `EventAssignedPodDelete` 事件 `MoveAllToActiveOrBackoffQueue` 唤醒可能等它腾位的 pod(`schedule_one.go:509-538`)。

**Q6:两个同名同优先级的 pod 谁先调度?**
activeQ 的 Less 是 priority 相同时比 Timestamp(`queuesort/priority_sort.go:43-47`);打分相同则靠 `Randomizer` 随机选 host(`sorted_nodes.go:41-43`),天然负载离散化。

**Q7:抢占为什么看不到 UnschedulableAndUnresolvable 的节点?**
因为 Filter 已判定"资源维度上即使清空也不够"(如请求超过节点 allocatable,`fit.go:743`),对它们做 victim 模拟是纯浪费;`findCandidates` 只取 `NodesForStatusCode(Unschedulable)`(`preemption.go:207`)。

**Q8:NominatedNodeName 会不会被永久占用造成饿死?**
不会独占:它只是软提名。下个周期先单点试提名节点,不过就全量扫描(`schedule_one.go:677-686`);更高优先级 pod 可以把它从 nominator 里顶掉;`PodEligibleToPreemptOthers` 在提名节点有终止中 victim 时阻止重复抢占(`default_preemption.go:465-474`)。

**Q9:Permit 的 Wait 期间 pod 在哪里?占资源吗?**
pod 已 assume(占用 cache 资源),框架挂在 `waitingPods` map,阻塞发生在绑定协程的 `WaitOnPermit` channel 上(`runtime/framework.go:2260-2285`);超时或被拒绝触发 Unreserve。调度循环本身不被阻塞。

**Q10:Extender 和插件是什么关系?**
历史遗留的进程外钩子:Filter/ Prioritize / ProcessPreemption / Bind 四个 HTTP 接口,在框架插件之后顺序执行,可 ignorable。插件化之后 extender 的存在感持续下降(绑定优先级也排在 Bind 插件之前而非之后,`schedule_one.go:1115-1119`)。

**Q11:同一 profile 的多个调度器实例怎么隔离?**
以 `pod.Spec.SchedulerName` 维度建多个 profile,每个 profile 一套独立插件链(`scheduler.go:336-350` 装配;`schedule_one.go:105` `frameworkForPod` 按 pod 选框架)。事件处理器用 `responsibleForPod` 过滤不属于本进程任何 profile 的 pod(`eventhandlers.go:464`),队列与 cache 是全体 profile 共享的。

## ⑨ 深挖问题(供后续章节或自行验证)

1. **PodGroup 调度周期与单 pod 周期的资源核算**:pod group 走 `snapshot.AssumePod` 而非 cache(`schedule_one.go:1086-1092`),多 placement 模拟下快照的 ForgetPod 需要严格 LIFO(`snapshot.go:643-711`)。问题:placement 失败后,`unschedulableEntities` 中的组级 backoff 与成员 pod 级 backoff 如何避免双重惩罚?(见 `scheduling_queue.go:1164-1277` AddAttemptedPodGroupIfNeeded)
2. **OpportunisticBatching(KEP-5598)的签名失效边界**:`SignPod` 聚合各插件的 SignFragment 形成签名,任何 Filter/Score 插件不实现 SignPlugin 即全局关闭批处理(`framework.go:842-893`)。问题:节点 allocatable 变化不参与签名,批处理缓存的复用是否会系统性高估可行性?`maxBatchAge` 默认 500ms 的取舍?
3. **inFlightEvents 链表的内存与正确性**:事件在 pod in-flight 期间全部暂存(`active_queue.go:203`),若 pod 长期卡在 Permit Wait(而 Done 已提前调用),期间的事件谁来消费?`EventForceActivate` 的补登记(`scheduling_queue.go:1000`)是否覆盖所有路径?
4. **抢占的公平性盲区**:`MoreImportantVictim` 偏向"大 PodGroup 更难安放所以先牺牲小组"(`default_preemption.go:141-146`),与 PDB 的 disruption budget 语义叠加后,是否可能出现同一 PodGroup 被多个高优 pod 反复猎杀?NoPreempt 与优先级倒挂场景下的 TTL 机制缺失是否可接受?
5. **Filter 并发与 context 取消的传播**:`cancel("found enough nodes")` 后,`RunFilterPluginsWithNominatedPods` 内部两次 pass 之间不检查 ctx,插件被要求"鼓励自行检查 ctx 并返回 UnschedulableAndUnresolvable"(`staging/.../interface.go:566-572`)——一个已取消 ctx 上的错误状态是否会污染 `diagnosis.NodeToStatus` 并误导抢占候选集?

---
### 附:本文引用的关键文件清单
- `pkg/scheduler/schedule_one.go`、`pkg/scheduler/scheduler.go`、`pkg/scheduler/eventhandlers.go`
- `pkg/scheduler/framework/interface.go`、`pkg/scheduler/framework/runtime/framework.go`、`framework/sorted_nodes.go`、`framework/cycle_state.go`
- `pkg/scheduler/backend/queue/scheduling_queue.go`、`active_queue.go`、`backoff_queue.go`、`unschedulable_entities.go`
- `pkg/scheduler/backend/cache/cache.go`、`snapshot.go`
- `pkg/scheduler/framework/plugins/noderesources/{fit.go,resource_allocation.go,least_allocated.go,balanced_allocation.go}`
- `pkg/scheduler/framework/plugins/{nodeaffinity,tainttoleration,interpodaffinity,queuesort,defaultbinder}`
- `pkg/scheduler/framework/plugins/defaultpreemption/default_preemption.go`、`pkg/scheduler/framework/preemption/{preemption.go,executor.go}`
- `pkg/scheduler/apis/config/v1/default_plugins.go`、`pkg/scheduler/framework/plugins/registry.go`、`plugins/names/names.go`
- `staging/src/k8s.io/kube-scheduler/framework/interface.go`、`pkg/scheduler/util/utils.go`
