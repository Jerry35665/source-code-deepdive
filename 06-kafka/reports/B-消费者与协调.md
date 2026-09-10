# B 篇 · 消费者客户端与消费组协调

> 版本基线：Kafka 4.5.0-SNAPSHOT（commit f6149f1c，2026-09-05）。文中 `文件:行号` 均以仓库根目录为基准。核心阅读对象：`clients/src/main/java/org/apache/kafka/clients/consumer/internals/`（下文简称 `client/internals/`）。

## ① 全景：消费模型的三代演进

Kafka 消费组协议经历了三代演进，本版本（4.5.0-SNAPSHOT）三代共存：

1. **Classic 协议（eager / cooperative）**：客户端三段式 `FindCoordinator → JoinGroup/SyncGroup/Heartbeat → OffsetCommit`，由 Leader 成员在客户端执行分区分配。实现从旧版 `core` 中的 Scala `GroupCoordinator.scala` 全面迁移为 Java 重写版（`group-coordinator/` 模块），旧 Scala 文件已删除，服务端状态机位于 `group-coordinator/src/main/java/org/apache/kafka/coordinator/group/classic/ClassicGroupState.java`。
2. **Cooperative 协议**：仍是 classic 协议族，只是分配器声明 `RebalanceProtocol.COOPERATIVE`（`client/../CooperativeStickyAssignor.java:72`），rebalance 从"全量交还"变为"只 revoke 被移动的分区"。
3. **Consumer 协议（KIP-848，新协议）**：服务端集中分配，心跳即协调。`AsyncKafkaConsumer` 的类注释明确写着它是 KIP-848 的一部分、"intended to be the default in coming releases"（`client/internals/AsyncKafkaConsumer.java:173-175`）。但**本版本尚未默认启用**：`ConsumerConfig.java:120-121` 中 `DEFAULT_GROUP_PROTOCOL = GroupProtocol.CLASSIC.name().toLowerCase(Locale.ROOT)`，即 `group.protocol=classic` 仍是默认值。服务端默认已同时启用三种协议：`group.coordinator.rebalance.protocols` 默认为 `CLASSIC, CONSUMER, STREAMS`（`group-coordinator/.../GroupCoordinatorConfig.java:88-94`，该配置自 4.3 起标记废弃，5.0 将改由 feature version 控制）。

此外还有 **ShareGroup（KIP-932）**：一种无分区独占关系的"共享消费"组，客户端 `KafkaShareConsumer`、服务端 `core/src/main/java/kafka/server/share/`，见第 ⑥ 节。

### 文件地图（本篇涉及）

| 层 | 文件 | 职责 |
|---|---|---|
| 客户端-应用线程 | `client/internals/AsyncKafkaConsumer.java`（2555 行） | Consumer API 门面，事件提交/后台事件消费 |
| 客户端-网络线程 | `client/internals/ConsumerNetworkThread.java` | 事件处理器 + RequestManager 轮询 + NIO |
| 拉取 | `client/internals/FetchCollector.java`、`CompletedFetch.java`、`FetchBuffer.java` | 缓冲区→ConsumerRecords |
| 拉取会话 | `clients/src/main/java/org/apache/kafka/clients/FetchSessionHandler.java` | KIP-227 增量拉取 |
| 协调 | `client/internals/CoordinatorRequestManager/CommitRequestManager/ConsumerMembershipManager/ConsumerHeartbeatRequestManager` | FindCoordinator/提交/心跳/调和 |
| 服务端 | `group-coordinator/.../GroupMetadataManager.java`（10073 行）、`classic/`、`modern/`、`assignor/` | 组状态机、目标分配、位移存储 |
| Share | `client/internals/Share*`、`core/.../share/SharePartition*.java` | KIP-932 |

## ② AsyncKafkaConsumer 的双线程事件模型

### 2.1 线程与事件流全景

```
 应用线程 (user thread)                        网络线程 consumer_background_thread
┌────────────────────────────┐   ApplicationEvent   ┌──────────────────────────────────┐
│ poll()/commitSync()/seek() │ ──(LinkedBlockingQ)─▶│ ConsumerNetworkThread.runOnce()  │
│   AsyncKafkaConsumer       │                      │  1. processApplicationEvents()   │
│                            │                      │     → ApplicationEventProcessor  │
│  checkInflightPoll()       │                      │  2. 各 RequestManager.poll(t)    │
│   ├ AsyncPollEvent 提交 ───┼──────────────────────┼─▶ 3. NetworkClientDelegate.poll  │
│   ├ commit 回调执行         │ ◀──BackgroundEvent───┤    (KafkaClient.poll, NIO)       │
│   └ processBackgroundEvents│   (LinkedBlockingQ)  │  4. reap 超时事件                 │
├────────────────────────────┤                      ├──────────────────────────────────┤
│ FetchCollector.collectFetch│ ◀══ 共享 FetchBuffer ═▶ FetchRequestManager 收到响应   │
│  (仅应用线程使用)           │   (线程安全, 519 行)  │  填入 CompletedFetch             │
└────────────────────────────┘                      └──────────────────────────────────┘
```

设计核心是**单写多读的两条队列 + 一个共享缓冲区**：

- **ApplicationEvent 队列**（`AsyncKafkaConsumer.java:511`）：应用线程的所有"要做事"（poll、commit、seek、订阅变更、position 检查）都被封装为 `CompletableApplicationEvent` 投递过去，方法内用 `addAndGet()` 阻塞在事件 future 上（如 `seek`：1164-1170 行）。
- **BackgroundEvent 队列**（`AsyncKafkaConsumer.java:374,480`）：网络线程只回传两类东西：错误（`ErrorEvent`，应用线程 `process` 时直接 `throw`，见 227-229 行）和**必须在应用线程执行的回调**（`PartitionsAssignedEvent`/`PartitionsRemovedEvent` → rebalance listener，`AsyncKafkaConsumer.java:192-363` 的 `BackgroundEventProcessor`）。
- **共享 FetchBuffer**（`AsyncKafkaConsumer.java:380-386` 注释明确说明它是双线程共享、线程安全的）：网络线程把 `FetchResponse` 装箱为 `CompletedFetch` 塞入；应用线程在 `FetchCollector.collectFetch` 中取走并反序列化。
- **轻量锁**：`currentThread`/`refCount`（`AsyncKafkaConsumer.java:420-421`）保证 Consumer API 仍是非线程安全的——被保护的是状态对象，而不是网络 I/O。

网络线程主循环 `runOnce()`（`ConsumerNetworkThread.java:210-237`）做了四件事：清空应用事件队列交给 `ApplicationEventProcessor`；遍历 `RequestManagers`（`RequestManagers.java:52-64`：coordinator/commit/heartbeat/membership/fetch/offsets 等十来个 Optional 管理器）收集待发请求；`networkClientDelegate.poll(pollWaitTimeMs)` 做真正的 NIO；最后收割超时事件（reaper 模式，保证 `addAndGet` 的超时语义）。这与 classic 路径形成鲜明对比——`ClassicKafkaConsumer` 直接在应用线程持有 `ConsumerNetworkClient`（`ClassicKafkaConsumer.java:137`），网络 I/O 发生在用户调用 poll/commit 期间。

### 2.2 应用事件清单与超时收割

`ApplicationEventProcessor.process` 的 switch（`events/ApplicationEventProcessor.java:80-178`）列出了全部约二十种应用事件：拉取侧的 `ASYNC_POLL`/`CREATE_FETCH_REQUESTS`，提交侧的 `COMMIT_SYNC`/`COMMIT_ASYNC`/`COMMIT_ON_CLOSE`，位置侧的 `CHECK_AND_UPDATE_POSITIONS`/`RESET_OFFSET`/`LIST_OFFSETS`/`FETCH_COMMITTED_OFFSETS`，订阅与组侧的 `TOPIC_SUBSCRIPTION_CHANGE`/`ASSIGNMENT_CHANGE`/`UNSUBSCRIBE`/`LEAVE_GROUP_ON_CLOSE` 等。每种事件都带截止时间（`calculateDeadlineMs`），由 `CompletableEventReaper` 在网络线程每轮循环末尾收割：到期的未完成事件被异常完成，等待它的 `addAndGet` 因此拿到超时而非永久挂起（`ConsumerNetworkThread.java:252-254,269-275`）。这套"事件 + future + reaper"把 classic 版层层嵌套的 `RequestFuture`/定时器组合改写成了统一的超时语义，是阅读新版代码时最重要的心智模型。

另有两个值得记录的边界处理：其一，`unsubscribe` 期间用 `skipAssignmentEvents` 跳过分区分配类后台事件并异常完成它们（`AsyncKafkaConsumer.java:2345-2407`），避免退订流程被一个过期的分配事件卡死；其二，构造函数初始化失败时会尽力 `close(..., LEAVE_GROUP, true)` 释放资源再抛 `KafkaException`（`AsyncKafkaConsumer.java:597-605`，对应注释中提到的 KAFKA-2121 防泄漏修复）。

### 2.3 回调为什么要"弹回"应用线程

KIP-848 把 membership 全部搬到后台线程，但 `ConsumerRebalanceListener` 必须与 `poll()` 同线程（用户假设）。于是网络线程在调和时只发一个 `PartitionsAssignedEvent/RemovedEvent`，应用线程在下次 `poll()` 内的 `processBackgroundEvents()`（`AsyncKafkaConsumer.java:2370`）里执行回调，再以 `ConsumerRebalanceListenerCallbackCompletedEvent` 通知后台线程继续（`AsyncKafkaConsumer.java:274-288`）。应用线程若长时间不调 poll，rebalance 就会卡在等待回调 ack——这与旧协议"poll 期间才跑回调"的语义一致，代价是协调复杂度。

## ③ poll 的四阶段

### 3.1 应用线程骨架

```java
// AsyncKafkaConsumer.java:933-977（节选）
public ConsumerRecords<K, V> poll(final Duration timeout) {
    ...
    do {
        wakeupTrigger.maybeTriggerWakeup();
        checkInflightPoll(timer, firstPass);          // (1) 管理 inflight 轮询事件
        final Fetch<K, V> fetch = pollForFetches(timer); // (2)(3) 等待+收集
        if (!fetch.isEmpty()) {
            sendPrefetches(timer);                    // (4) 预取流水线
            return interceptors.onConsume(...);
        }
    } while (timer.notExpired());
}
```

`checkInflightPoll`（993-1030 行）维护一个 `AsyncPollEvent`：无 inflight 就提交一个新事件并 `add` 到后台队列；提交后立刻执行 commit 回调并 `processBackgroundEvents()`——后台的调和（revoke）需要应用线程配合完成回调，所以这里必须"边等边处理"，否则会死锁（类似 `unsubscribe` 里注释说明的配合语义，2345-2370 行）。

### 3.2 网络线程侧：AsyncPollEvent 的四个阶段

`AsyncPollEvent` 到达后台后被 `ApplicationEventProcessor.process`（`events/ApplicationEventProcessor.java:728-770`）按序执行，这正是本报告所称"poll 四阶段"的服务端侧真相：

1. **调和检查（更新元数据/组状态）**：`consumerMembershipManager.maybeReconcile(true)`（731-732 行）。参数 `canCommit=true` 表示此时触发调和可以安全地做自动提交并标记待 revoke 分区。完成后 `event.markReconciliationCheckComplete()`（736 行）——应用线程的 `collectFetch`（`AsyncKafkaConsumer.java:2042-2066`）会**显式等待这个标记**，防止把即将被 revoke 的分区里的数据返回给用户。
2. **自动提交 + poll 计时器**：`commitRequestManager.updateTimerAndMaybeCommit()`（到 interval 就发 auto-commit）；同时 `membershipManager.onConsumerPoll()` 与 `hrm.resetPollTimer()`（740-747 行）——这就是 KIP-848 下 `max.poll.interval.ms` 的喂狗点。
3. **校验/更新 Position**：`offsetsRequestManager.updateFetchPositions(event.deadlineMs())` 后 `markValidatePositionsComplete()`（756-757 行）。对没有有效 position 的分区，后台去拉 committed offset 或按 `auto.offset.reset` 重置（详见 3.4）。应用线程在 `collectFetch` 中同样要等这个标记（2074-2082 行），避免两个线程并发改 `SubscriptionState.position`（注释 2068-2073 行明确说明这一竞态）。
4. **创建 Fetch 请求**：`fetchRequestManager.createFetchRequests()`，按 leader 节点分组、经 `FetchSessionHandler` 构造增量请求（`FetchRequestManager.java:94-124,152+`）。事件四阶段全部完成后 `completeSuccessfully()`，应用线程的 `addAndGet`/`isComplete` 检查才放行。

### 3.3 FetchCollector：从缓冲区到 ConsumerRecords

`pollForFetches`（1980-2034 行）先 `collectFetch()` 直接取；空则 `fetchBuffer.awaitWakeup(pollTimer)` 阻塞等待，且有三种情况把等待上限压到 `retryBackoffMs`（无已分配分区 1993-1997、position 未齐 1998-2003、有 fetchable 分区无缓冲数据 2004-2011），保证状态变化能被及时重估。这三条"压短等待"的规则解释了一个常见的生产疑问：为什么明明没有数据，poll 也不是精确等满 timeout 才返回——它在等待期会多次醒来重查订阅、分配与 position 状态。唤醒路径同样有讲究：`wakeupTrigger.setFetchAction(fetchBuffer)`（2018 行）把 wakeup 与具体等待对象绑定，避免唤醒信号被无关阶段吞掉；而拿到数据之后到返回记录之间不再响应 wakeup（949-953 行注释解释了原因：position 已推进，若此时抛 WakeupException，这批记录将永远无法返回）。

inflight 轮询事件的生命周期管理（`checkInflightPoll`/`maybeClearPreviousInflightPoll`/`maybeClearCurrentInflightPoll`，993-1088 行）还有一处精妙设计：上一轮 poll 事件若已完成**且**填满了 fetch buffer，则不提交新事件（1050-1058 行）。注释里给出了反例推演——若每次 `poll(0)` 都强制发新事件，新事件的"校验 position"阶段会先于 buffer 数据被消费，导致 buffer 中的数据被无限期搁置、poll 永远返回空。这是异步化改造中用老老实实的注释换来的可维护性。

`FetchCollector.collectFetch`（`FetchCollector.java:91-147`）按 `max.poll.records` 上限循环：初始化 `CompletedFetch` → 跳过 paused 分区（把数据放回队列）→ `fetchRecords()`。`fetchRecords`（149-217 行）有三道防线：分区已不被本消费者持有则丢弃（152-154，rebalance 发生在取回前）；`nextFetchOffset != position.offset` 则视为过期响应丢弃（205-210）；成功路径上**先更新 position 再标记 buffer 耗尽**（189-193 行注释：防止后台线程看到 `isConsumed=true` 但 position 未更新而重复发旧 offset 的请求）。返回的 `Fetch` 携带 `nextOffsets`（`OffsetAndMetadata(nextFetchOffset,...)`，204 行）——这就是"poll 返回的最后一条记录 +1"语义，也是自动提交的数据来源（`commit` 中 `subscriptions.allConsumed()`）。

### 3.4 Position 与重置语义

- `position()`（1230-1257 行）：读 `subscriptions.validPosition`，无则循环调用 `updateFetchPositions`。
- `updateFetchPositions`（2094-2105 行）本质是发 `CheckAndUpdatePositionsEvent` 并 `addAndGet`，把实际工作交给后台 `OffsetsRequestManager`（先查 committed，无则按重置策略 ListOffsets）。
- `seek`/`seekToBeginning`/`seekToEnd`（1156-1227 行）分别封装为 `SeekUnvalidatedEvent` 与 `ResetOffsetEvent`，全部走后台线程完成。
- 重置兜底在 fetch 侧：`FetchCollector.handleInitializeErrors`（321-366 行）收到 `OFFSET_OUT_OF_RANGE` 时，若有重置策略则 `subscriptions.requestOffsetResetIfPartitionAssigned(tp)`（356 行），否则抛 `OffsetOutOfRangeException`（359-360 行）。**注意在 KIP-848 下这个异常从后台线程通过 `ErrorEvent` 弹回应用线程再抛出**（`AsyncKafkaConsumer.java:227-229`），与 classic 直接在 poll 栈上抛出路径不同。
- 三种 position 概念容易混淆：`position`（下一条待消费位移，即 consumed position）、`committed`（已提交到协调器的位移，查询见 `committed()`，1264-1292 行）、fetch 请求的 `fetchOffset`（= position，但响应可能因位点漂移被丢弃）。`Fetch.nextOffsets` 返回的 `OffsetAndMetadata(nextFetchOffset)`（204 行）表示"这批记录之后下一条的位移"，自动提交用的 `subscriptions.allConsumed()` 正是这组值的快照——因此自动提交的语义是"at-least-once 处理进度"，而非"已处理完成"。

### 3.5 FetchSession：KIP-227 增量拉取

`FetchSessionHandler`（`clients/src/main/java/org/apache/kafka/clients/FetchSessionHandler.java`）为**每个 broker** 维护一个拉取会话：`nextMetadata`（68 行）在 `INITIAL(全量)` 与 `(sessionId, epoch)`（增量）间流转。build 时若 `nextMetadata.isFull()` 则发送全部 fetchable 分区（278-293 行）；增量请求只带**新增/变化**分区与 `forget` 列表，服务端未列出分区沿用会话内旧值。响应处理（551-605 行）是一张状态转移表：session id 冲突、非法增量响应、服务端关闭会话都回退到 `FetchMetadata.INITIAL` 或 `nextCloseExistingAttemptNew()` 重新建会话。价值在于把每轮 fetch 的请求/响应体积从 O(分区数) 降到 O(变化量)，对小分区场景显著降低 CPU。服务端对等实现是 `server/src/main/java/org/apache/kafka/server/FetchSession.java`（此处从略）。

## ④ Rebalance 三种协议对照

### 4.1 Classic eager：全量重分配

客户端 `AbstractCoordinator`（`client/internals/AbstractCoordinator.java`）：`sendJoinGroupRequest`（608 行）→ `JoinGroupResponseHandler`（640 行）→ `sendSyncGroupRequest`（808 行）→ leader 用本地分配器（Range/RoundRobin/Sticky）算出全员 assignment。服务端（Java 重写版）状态机：

```
EMPTY ──join──▶ PREPARING_REBALANCE ──全部 join──▶ COMPLETING_REBALANCE ──SyncGroup──▶ STABLE
                   ▲  心跳超时/离开/订阅变化(回归)        ▲  新成员 join(回归)
```
（`group-coordinator/.../classic/ClassicGroupState.java:44-115`，每个状态的 action/transition 注释写得非常清楚，如 PREPARING_REBALANCE 期间"respond to heartbeats with REBALANCE_IN_PROGRESS"，49-50 行。）

eager 协议下 generation +1，所有成员在 `SyncGroup` 后拿到全新 assignment，**交还全部分区**（`ConsumerCoordinator.onJoinComplete`：`client/internals/ConsumerCoordinator.java:379-469`，先 `invokePartitionsRevoked(旧全部)` 再 `invokePartitionsAssigned(新增)`，445/468 行）。

客户端侧的 classic 协调逻辑分布在两个类里：`AbstractCoordinator` 负责 RPC 时序与心跳——`sendJoinGroupRequest`（608 行）、`sendSyncGroupRequest`（808 行）、`sendHeartbeatRequest`（1225 行），心跳由内部 Heartbeat 线程按 session 间隔触发（`HeartbeatThread`，1464 行），心跳收到 `REBALANCE_IN_PROGRESS` 即重新入组（1257-1259 行）；`ConsumerCoordinator` 负责"入组之后"的事情——`onJoinComplete`（379 行起）反序列化 assignment、校验订阅快照（412-415 行，不一致则请求重新入组）、回调 listener，以及按 `partition.assignment.strategy` 选择分配器（389-391 行）。值得注意这套逻辑**全部运行在应用线程**：任何一次 rebalance 都要求用户及时调用 poll 才能推进，这正是 KIP-848 双线程改造的直接动因。

### 4.2 Cooperative sticky：增量两段式

`CooperativeStickyAssignor` 声明支持 `COOPERATIVE, EAGER` 两种协议（72 行）。关键在 `adjustAssignment`（129-136 行）：

```java
// CooperativeStickyAssignor.java:129-136
// Following the cooperative rebalancing protocol requires removing partitions
// that must first be revoked from the assignment
private void adjustAssignment(Map<String, List<TopicPartition>> assignments,
                              Map<TopicPartition, String> partitionsTransferringOwnership) {
    for (Map.Entry<TopicPartition, String> partitionEntry : partitionsTransferringOwnership.entrySet()) {
        assignments.get(partitionEntry.getValue()).remove(partitionEntry.getKey());
    }
}
```

即"属主转移集合"（同一分区：A 交出、B 接收）先从 B 的新 assignment 里剔除，本轮 A 只 revoke 这些分区，**下一轮** rebalance B 才真正拿到——用两轮 rebalance 换取未被移动的分区全程不中断。`StickyAssignor`（181 行起）则提供"粘性"算法（`AbstractStickyAssignor` 的平衡度优先迁移最小化），但走 eager 协议。Range（102 行）/RoundRobin（104 行）均为 eager 且无粘性。

### 4.3 KIP-848：服务端分配 + 心跳即协调

新协议把 JoinGroup/SyncGroup/Heartbeat 三个 RPC 合并为单个 `ConsumerGroupHeartbeat`（v0），且**分配在服务端**完成：

- 客户端心跳：`ConsumerHeartbeatRequestManager.buildHeartbeatRequest`（173-175 行）携带 member id/epoch/instanceId/rack/订阅/服务端 assignor 名（`group.remote.assignor`，`AsyncKafkaConsumer.java:590-593` 提到该配置由后台线程消费）。
- 服务端 `consumerGroupHeartbeat`（`GroupMetadataManager.java:2561-2690+`）四步：get/create group 与 member（memberEpoch==0 才创建，2578 行；静态成员走 `getOrMaybeSubscribeStaticConsumerGroupMember`，2595 行）→ 订阅变化则 bump **group epoch**（2649-2675 行）→ group epoch > target assignment epoch 时重算**目标分配**（2679-2686 行，调用 `assignor/` 下服务端分配器）→ 对未收敛成员做 `maybeReconcile`（2690 行）。服务端分配器默认提供 `uniform`（`UniformAssignor.java:46-80`，按同构/异构订阅选 Homogeneous/Heterogeneous builder）与 `range`（同目录 `RangeAssignor.java`）。
- 成员侧状态机 `MemberState`（`client/internals/MemberState.java:35-141`）：`UNSUBSCRIBED→JOINING→RECONCILING→(ACKNOWLEDGING)→STABLE→PREPARE_LEAVING→LEAVING`，另有 FENCED/FATAL/STALE 终止态，静态定义了合法前驱（120-141 行）。
- **增量调和**（`AbstractMembershipManager.reconcile`，875-1035 行）：服务端下发目标 assignment 后，客户端计算 `addedPartitions = assigned - owned`、`revokedPartitions = owned - assigned`（916-923 行）；先标记 revoke 分区暂停 fetch（949 行），然后**自动提交 → onPartitionsRevoked → onPartitionsAssigned** 串行执行（953-1010 行），全部完成后 `transitionTo(MemberState.ACKNOWLEDGING)`（1030 行）并通过下一次心跳 ack 新 assignment（`ConsumerMembershipManager.java:87-100` 的注释流程图）。每个 target assignment 有 localEpoch，部分完成也可先 ack（900-905 行），因此是真正增量的：**未被移动的分区全程保持消费**，且没有全局"stop the world"。
- 心跳间隔由**服务端下发**：`heartbeatIntervalForResponse` 直接读 `response.data().heartbeatIntervalMs()`（`ConsumerHeartbeatRequestManager.java:205-206`），服务端默认 5000ms（`GroupCoordinatorConfig.java:201-203`），session timeout 默认 45000ms（189-191 行）。
- `max.poll.interval.ms` 由客户端 pollTimer 强制（`AbstractHeartbeatRequestManager.java:93,114,170-180`）：到期则发 LeaveGroup 心跳自杀（`transitionToSendingLeaveGroup(true)`）；再次 poll 时若已过期则尝试 rejoin（`resetPollTimer`，280-290 行）。
- fenced 恢复是自动的：`transitionToFenced`（`AbstractMembershipManager.java:448-490`）清空 assignment 后 `transitionToJoining()` 重新入组——**不需要重启**，这是相对旧协议（Generation 错误即致命）的重要改进。

### 4.4 静态成员 group.instance.id

Classic 路径：`classicGroupJoinNewStaticMember`（`GroupMetadataManager.java:7239-7253`）用 `group.staticMemberId(instanceId)` 找到旧 member，转 `updateStaticMemberThenRebalanceOrCompleteJoin`（8135 行）：`replaceStaticMember` 换绑 member id（8144 行）并重排心跳；若组处于 STABLE 且协议选择不变，则**不触发 rebalance**，直接回填当前 assignment（8162-8214 行）——静态成员重启不引发组重分配，代价是 KIP-345 的 session timeout 内"僵尸实例"问题。落库失败时回滚到旧 member id（8181-8183 行）。新协议同样支持 instanceId（2561-2605 行内 `getOrMaybeSubscribeStaticConsumerGroupMember`）。

### 4.5 对照表

| 维度 | eager (classic) | cooperative-sticky | KIP-848 consumer |
|---|---|---|---|
| 分配位置 | Leader 客户端 | Leader 客户端 | 服务端 assignor |
| 交还范围 | 全量 revoke | 仅属主转移分区 | 仅 revoked 差集，逐成员增量 |
| 协议 RPC | Join/Sync/Heartbeat ×3 | 同左（两轮） | Heartbeat 单 RPC |
| 分配器 | Range/RR/Sticky | CooperativeSticky | uniform/range（服务端可插拔） |
| Fenced/STALE | 基本致命 | 基本致命 | 自动 rejoin（448-490 行） |
| 心跳间隔 | 客户端配置 | 客户端配置 | 服务端下发（205-206 行） |

## ⑤ 提交与位移语义

### 5.1 客户端：三类提交共用一条路径

`commitSync`/`commitAsync` 都构造 `CommitEvent`（`SyncCommitEvent`:1814 / `AsyncCommitEvent`:1120）交给后台 `CommitRequestManager` 构造 `OffsetCommitRequest`。两个细节值得注意：

```java
// AsyncKafkaConsumer.java:1140-1154（commit 公共路径, 节选）
private CompletableFuture<...> commit(final CommitEvent commitEvent) {
    throwIfGroupIdNotDefined();
    offsetCommitCallbackInvoker.executeCallbacks();
    if (commitEvent.offsets().isPresent() && commitEvent.offsets().get().isEmpty())
        return CompletableFuture.completedFuture(null);
    applicationEventHandler.add(commitEvent);
    // 阻塞直到后台线程取走 allConsumed 位置快照，保证之后的新 fetch 不影响待提交位移
    ConsumerUtils.getResult(commitEvent.offsetsReady(), defaultApiTimeoutMs.toMillis());
    return commitEvent.future();
}
```

未显式给 offsets 时，`offsetsReady` future 保证**后台线程在取快照前不会有新的消费推进**，从根上消除了 classic 版"提交位置竞态"。`commitSync` 还会先 `awaitPendingAsyncCommitsAndExecuteCommitCallbacks`（1830-1853 行）等齐挂起的 async commit（只追踪最后一个 `lastPendingAsyncCommit`，414-416 行，因为事件有序所以前序必然先完成），再等本 future，最后执行拦截器/回调。`commitAsync` 只注册 `whenComplete`，把用户回调排进 `OffsetCommitCallbackInvoker`，在**下次 poll** 的应用线程里执行（1014 行）。

### 5.2 自动提交的三处触发点

`CommitRequestManager`：① 周期性异步提交 `maybeAutoCommitAsync`（289-304 行，interval 默认 5s，155-160 行，同一时刻仅允许一个 in-flight）；② **rebalance 前同步提交** `maybeAutoCommitSyncBeforeRebalance`（342-352 行），重试至成功/致命/超时，把 `STALE_MEMBER_EPOCH` 视为可重试、`UNKNOWN_TOPIC_OR_PARTITION` 视为致命以防 rebalance 卡死（注释 333-340 行）；③ KIP-848 的调和起点也会先走这条路径（`ConsumerMembershipManager.signalReconciliationStarted`，237-244 行，以 rebalanceTimeoutMs 为上限）。

### 5.3 位移查询：committed() 与 OffsetFetch

与提交对称的查询路径是 `committed(Set, Duration)`（`AsyncKafkaConsumer.java:1264-1292`）：构造 `FetchCommittedOffsetsEvent` 并 `addAndGet` 阻塞后台，由 `OffsetsRequestManager` 发 `OffsetFetch` 请求到协调器（并处理 KIP-320 的 leader epoch 校验与 `UNSTABLE_OFFSET_COMMIT` 重试）。注意该事件同时挂到 `wakeupTrigger`（1278 行），说明同步查询类 API 的可中断性是显式设计的：wakeup 会以 `WakeupException` 打断等待，但事件本身继续在后台执行，下次查询可复用结果。

### 5.4 服务端：__consumer_offsets 即状态机日志

新协调器把位移当 record 写入 `__consumer_offsets`：`OffsetMetadataManager.commitOffset`（`group-coordinator/.../OffsetMetadataManager.java:620-679`）逐分区校验（metadata 过大 → `OFFSET_METADATA_TOO_LARGE`，成员合法性由 `CommitPartitionValidator` 检查）后 `GroupCoordinatorRecordHelpers.newOffsetCommitRecord(...)` 生成 `OffsetCommitKey/Value` 记录（670-677 行），经 `CoordinatorRuntime` 按 `__consumer_offsets` 分片（shard）单线程写日志再回放内存态；删除与过期写成 tombstone（1151-1156 行）。retention 到期时间在 v0 由 `retentionTimeMs` 推导（591-601 行）。CoordinatorRuntime 每个 offsets 分区一个 shard、事件单线程化，写吞吐靠 `group.coordinator.append.linger.ms` 聚批（`GroupCoordinatorConfig.java:96-99`）——这是 4.x 重写时对旧 `DelayedOperation` Purgatory 模型的替换。

## ⑥ ShareGroup 概览（KIP-932）

ShareGroup 引入"共享消费"：组内成员可**同时消费同一分区**，通过确认（acknowledge）机制完成消息级语义。本版本代码已成体系：

- **客户端**：`KafkaShareConsumer` 委托 `ShareConsumerImpl`（`client/internals/ShareConsumerImpl.java`）；`ShareConsumeRequestManager`（1799 行）负责 `ShareFetchRequest` + `ShareAcknowledgeRequest` 两类 RPC（72-73 行注释），且发起新 fetch 前先冲刷 pending acknowledgements（158 行）；`ShareFetchCollector.collect`（`ShareFetchCollector.java:55-80`）与普通 `FetchCollector` 同构。ack 语义三选一：`ACCEPT / RELEASE / REJECT`。
- **服务端**：`core/src/main/java/kafka/server/share/SharePartitionManager.java` 持有每个 share-partition 的内存状态 `SharePartition`（3645 行）。核心是记录级/批级状态机：`AVAILABLE → ACQUIRED → (ACKNOWLEDGED | ARCHIVED)`，ack 类型映射为 `ACCEPT→ACKNOWLEDGED, RELEASE→AVAILABLE, REJECT→ARCHIVED`（`SharePartition.java:150-153`）。记录被 `acquire` 时 `tryUpdateBatchState(RecordState.ACQUIRED, DeliveryCountOps.INCREASE, ...)` 递增投递计数（968 行），超过 `max.delivery.count` 转入 ARCHIVED（2392、2479 行注释；上限来自组配置，`SharePartitionManager.java:147`）——即"毒丸消息"自动进死信态。持久化由 `share-coordinator` 模块（仓库顶层目录）+ `ShareCoordinatorMetadataCacheHelperImpl` 承担，配合 `DelayedShareFetch`/`ReplicaManagerLogReader`（同目录）做延迟拉取。

与消费组语义的差别一句话概括：消费组的互斥单元是**分区**（commit 位移），ShareGroup 的互斥单元是**记录**（ack 状态），因此没有 position/重置语义，也没有 rebalance 的分区转移。使用上，ShareGroup 的典型场景是"多应用实例分摊同一条队列"但又不想在扩缩容时经历 rebalance 抖动，或者希望消息按条 ack（近似队列语义）而保持 Kafka 的存储模型不变。需要注意的是：SharePartition 的内存状态（每个批次的投递计数、租约状态）必须与 share-coordinator 的持久化日志保持一致，broker 崩溃恢复时未终结的 ACQUIRED 记录会按 delivery count 判断是否重回 AVAILABLE，这是它与普通拉取路径（无服务端消费状态）最本质的工程差异。

## ⑦ 设计动机与取舍

1. **双线程事件模型的本质**：把"用户代码不可控"（回调、阻塞）与"网络 I/O 必须及时"（心跳不能被用户长时间处理阻塞）解耦。代价是三重复杂度：事件 future 超时收割（reaper）、回调必须"弹回"应用线程再确认（reconciliation 与 poll 的握手：`collectFetch` 等两个标记，2048-2082 行）、以及 `FetchBuffer` 的跨线程一致性协议（先 position 后 isConsumed，`FetchCollector.java:189-193`）。classic 路径单线程模型里这些问题天然不存在，但心跳 starvation 是真实生产事故源。
2. **KIP-848 的杠杆点**：分配从客户端 Leader 移到服务端后，① 不再有"Leader 崩溃触发额外一轮 JoinGroup"；② 分配器升级不依赖客户端发版；③ 增量调和与 fenced 自动恢复让 rebalance 从"组级 STW"变为"成员级后台调和"。代价是服务端负担（每个 group epoch 变化都要重算 target assignment 并写日志）与单 RPC 的能力上限。
3. **协调器 Java 重写 + KRaft 化**：`GroupCoordinatorService` 基于 `CoordinatorRuntime`（`GroupCoordinatorService.java:90-101` imports），状态即 `__consumer_offsets` 日志的前缀，天然获得与 KRaft 一致的"日志即真相"模型；换来的是写路径统一为 append+replay，以及 `unstable.api.versions.enable` 对新 API 版本的灰度门（`DefaultApiVersionManager.java:39-63`）。
4. **FetchSession 与 poll 流水线**：`sendPrefetches`（2120-2127 行）在返回数据前就异步提交下一轮 fetch 事件并**吞掉异常**（2123-2126 行注释："this method is designed to suppress all exceptions"）——拿不到预取只是下一轮 poll 慢一点，不能让已到手的 records 报错。这是"宁可重复劳动、不可阻塞返回"的取舍。
5. **增量调和的"部分完成也可 ack"**：当目标 assignment 尚有未解析的 topic id 时，成员先对已解析片段完成调和并 ack（`AbstractMembershipManager.java:900-905`），未解析部分靠元数据更新继续推进。这比"等全部解析完再一次性调和"显著降低了大元数据集群下 rebalance 的长尾延迟，代价是同一 target 可能触发多轮心跳 ack，服务端必须容忍乱序收敛（用 assignment localEpoch 比对实现幂等）。
6. **静态成员的权衡**：KIP-345 用 `group.instance.id` 换取"重启不 rebalance"，但服务端为此要维护 staticMembers 映射、处理新实例顶替旧实例（`replaceStaticMember`，`ClassicGroup.java:542-596`）、以及旧 member id 心跳失效后的清理。动态成员的"简单"是靠牺牲有状态部署的运维便利换来的，这一权衡在 KIP-848 中被原样继承。

## ⑧ FAQ

**Q1：本版本 KIP-848 是默认吗？** 不是。`group.protocol` 默认 `classic`（`ConsumerConfig.java:120-121`）；`AsyncKafkaConsumer` 仅在 `group.protocol=consumer` 时被 `KafkaConsumer` 选择。服务端三种协议默认全开（`GroupCoordinatorConfig.java:88-94`）。

**Q2：poll 返回的记录会被重复返回吗？** 正常不会：`fetchRecords` 要求 `nextFetchOffset == position.offset`，过期响应直接丢弃（`FetchCollector.java:205-210`）；且 position 在返回前已推进（返回 0 条但 position 前进的情形见 `AsyncKafkaConsumer.java:967-970`）。

**Q3：commitSync 为什么没有指定 offsets 也不会提交错？** `CommitEvent.offsetsReady` 让后台线程先取 `allConsumed` 快照并阻塞应用线程至取走（`AsyncKafkaConsumer.java:1150-1153`），取快照后的新 fetch 不影响本次提交。

**Q4：max.poll.interval.ms 超时后发生了什么？** KIP-848：网络线程检测到 pollTimer 过期即发 LeaveGroup（`AbstractHeartbeatRequestManager.java:170-180`），之后用户再调 poll 会尝试 rejoin（`resetPollTimer`，280-290 行）；classic 路径则由 `ConsumerCoordinator.pollTimeoutHandler` 类似机制触发离组再重入。

**Q5：rebalance 期间后台拉到的数据怎么办？** 分区 revoke 前被 `markPendingRevocation` 暂停（`AbstractMembershipManager.java:949,1320-1328`），不再发新 fetch；in-flight 响应到达应用线程时因分区不再 assigned/fetchable 被丢弃（`FetchCollector.java:152-161`）。

**Q6：静态成员重启会触发 rebalance 吗？** Classic 下若组 STABLE 且协议选择不变则不触发（`GroupMetadataManager.java:8162-8170`），直接沿用原 assignment；否则走普通 rebalance。新协议同理由 instanceId 复用 member（2594-2605 行）。

**Q7：FetchSession 的 sessionId 从哪来、何时失效？** 由服务端在首次全量响应里分配，客户端记入 `nextMetadata`（`FetchSessionHandler.java:577-581`）；收到 `FetchSessionIdNotFoundException`、非法增量响应或网络错误时关闭旧会话并重建（536、546、588、618-631 行）。

**Q8：cooperative rebalance 为什么常常要两轮？** 属主转移分区必须先由旧属主 revoke、服务端确认后才能给新属主，`CooperativeStickyAssignor.adjustAssignment` 本轮先从新属主 assignment 中剔除这些分区（129-136 行），下一轮再补上，换取其余分区不中断。

**Q9：自动提交失败会怎样？** 周期性 auto-commit 失败仅记日志/退避重试（`CommitRequestManager.java:313-324`），不抛给用户；rebalance 前的同步 auto-commit 则会重试至成功或超时（342-380 行），可能延迟 rebalance。

**Q10：ShareGroup 与消费组能混用吗？** 不能。`group.protocol=consumer` 与 share 是不同组类型（服务端 `Group.GroupType.CLASSIC/CONSUMER/STREAMS/SHARE` 分别由不同 manager 处理），ShareGroup 用 `KafkaShareConsumer` + Share* RPC 独立成族。

## ⑨ 深挖问题（后续可继续追查）

1. **`canCommit=false` 的调和被静默跳过的语义**：`AbstractMembershipManager.java:929` 在非 poll 触发的调和遇 revoke/自动提交时直接 `return`，目标 assignment 留在待调和集——需要确认下一次 `maybeReconcile(true)` 之前的窗口内，ack 缺失是否会触发服务端 STALE_MEMBER_EPOCH 并连锁 rejoin（此处未见补偿逻辑）。
2. **`__consumer_offsets` 双写者问题**：classic 组与 consumer 组共写同一 offsets 主题，`GroupCoordinatorService` 的 shard 划分是否保证同一 groupId 的新旧协议记录严格有序（尤其 admin 迁移 `ConsumerGroupMigrationPolicy` 路径），值得读 `GroupCoordinatorShard` 与 migration 代码验证。
3. **FetchBuffer 与 `inflightPoll` 的边界竞态**：`maybeClearPreviousInflightPoll`（1032-1065 行）为避免 `poll(0)` 饥饿而"事件完成且 buffer 非空时不发新事件"，但 `sendPrefetches` 又可能同时补请求——两条路径对 buffer 的生产者-消费者配平依赖 `fetchBuffer.wakeup()`（`FetchRequestManager.java:165-169`），极端时序下的丢唤醒值得构造并发测试。
4. **服务端 assignor 的 rack 感知与粘性**：`uniform` 分配器在成员订阅异构时走 Heterogeneous builder，但其对 `rackId`/粘性（member epoch 不变时迁移最小化）的实现程度与客户端 StickyAssignor 的差距，可对比 `UniformHomogeneousAssignmentBuilder` 与 `AbstractStickyAssignor` 的策略差异。
5. **SharePartition 状态机的持久化边界**：内存 `InFlightState` 与 share-coordinator 快照间的窗口（`SharePartition.java:530-560` 的 persister 回放路径）在 broker 崩溃时如何保证 delivery count 不回退/不虚增，涉及 `DelayedShareFetch` 与 share-coordinator 的 checkpoint 协议，值得单开一篇。
