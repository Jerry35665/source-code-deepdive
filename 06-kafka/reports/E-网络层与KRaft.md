# 第六章 · 调研报告 E:网络层与 KRaft 控制器

> 仓库:kafka(Kafka 4.5.0-SNAPSHOT,commit f6149f1c,2026-09-05)
> 本文所有 `文件:行号` 均以该 commit 为准。行号为阅读时实测,长文件可能有 ±2 行漂移。

---

## ① 全景:一个请求的一生(从 socket 到响应)

4.x 的 broker 网络层是「1 Acceptor + N Processor + M Handler + 1 RequestChannel」的经典 Reactor 多线程模型:

1. **Acceptor**(每个 listener 一个线程,`core/src/main/scala/kafka/network/SocketServer.scala:458`)在 `ServerSocketChannel` 上 `select`,accept 出 `SocketChannel`,做连接配额检查后以 **round-robin** 方式分配给某个 Processor(`SocketServer.scala:623-658`)。
2. **Processor**(每个 listener 配 `num.network.threads` 个,`SocketServer.scala:742-766`)拥有独立的 `Selector`,在主循环里完成「注册新连接 → 取响应 → poll → 处理已完成读 → 处理已完成写 → 处理断连」(`SocketServer.scala:871-898`)。读完整请求后,解析 RequestHeader、构造 `RequestContext` 与 `Request`,调用 `requestChannel.sendRequest(req)` 入队,并立即 `selector.mute(connectionId)` —— 一个连接一次只允许一个未完成请求(`SocketServer.scala:1019-1021`)。
3. **RequestChannel**(`core/src/main/scala/kafka/network/RequestChannel.scala:40`)是一个 `ArrayBlockingQueue`,M 个 **KafkaRequestHandler**(`num.io.threads`,见 `core/src/main/scala/kafka/server/KafkaRequestHandler.scala:91,117,167`)阻塞式 `receiveRequest(300)` 取请求,交给 `KafkaApis.handle`。
4. Handler 的处理若可同步完成则直接 `requestChannel.sendResponse`;若需等待(如 acks=-1 的 Produce 等副本落盘、DelayedFetch 等数据攒批),则创建 **DelayedOperation** 挂入 **DelayedOperationPurgatory**,响应回调由 Purgatory 在条件满足或超时时触发。
5. 响应经由 `RequestChannel.sendResponse` 路由回 **发起请求的那个 Processor** 的 `responseQueue`(`RequestChannel.scala:149-154`),Processor 的 `processNewResponses` 把它变成 `NetworkSend` 注册写事件,`processCompletedSends` 写完后 `tryUnmuteChannel` 恢复该连接的读取(`SocketServer.scala:1041-1059`)。整条链路的队列时间/处理时间指标由 `request.updateRequestMetrics` 记录(`SocketServer.scala:1062-1066`)。

客户端侧是对称的:Producer/Consumer 的前台线程构造 `ClientRequest`,`NetworkClient.send` 挂入 InFlightRequests 并交给 Selector 写出;`poll()` 是事件泵,读回响应后按 correlation id 配对、回调(`clients/src/main/java/org/apache/kafka/clients/NetworkClient.java:695-730`)。

KRaft 控制器的元数据读写也走这条网络层,只是消息体不同:控制器 quorum 节点间用 VOTE / BEGIN_QUORUM_EPOCH / END_QUORUM_EPOCH / FETCH / FETCH_SNAPSHOT 等 RPC 复制 `__cluster_metadata-0` 这个单分区日志;`QuorumController` 则把所有元数据变更写成 records 追加进该日志。

---

## ② NetworkClient 逐段解读

文件:`clients/src/main/java/org/apache/kafka/clients/NetworkClient.java`(1879 行)。类注释明确 **"This class is not thread-safe!"**(`NetworkClient.java:85`),它只在调用方(如 Sender 线程)单线程中使用。

### 2.1 核心组件(87-163 行)

- `selector: Selectable` —— 真正的 NIO 封装(98 行);
- `metadataUpdater: MetadataUpdater` —— 元数据刷新策略,默认实现为内部类 `DefaultMetadataUpdater`(100、363-369 行);AdminClient/RAF 场景可换成 `ManualMetadataUpdater`;
- `connectionStates: ClusterConnectionStates` —— 每个节点 (idString) 的连接状态机与退避计时(105、373-375 行);
- `inFlightRequests: InFlightRequests` —— 每连接的请求窗口(108 行);
- `nodesNeedingApiVersionsFetch` —— 新连接待发 ApiVersionsRequest 的节点表(145 行);
- `abortedSends` —— 版本不匹配等原因直接本地失败的请求,下次 poll 优先回报(147、699-706 行);
- 4.x 新增的**异步 bootstrap**:bootstrap.servers 的 DNS 解析放到单线程 `bootstrapExecutor` 中,构造时"提前发起一次解析",但计时器延迟到第一次 `poll()` 才启动,注释解释这是为了让"构造到首次调用之间的空档不占用解析预算"(153-163、393-410 行)。

### 2.2 连接与就绪判定(424-598 行)

`ready()` 是上游(Sender)决定"能否向该节点发请求"的入口:`isReady` 且否则在 `canConnect`(退避已过)时 `initiateConnect`(424-436 行)。真正的就绪条件三合一:

```java
// NetworkClient.java:595-598
private boolean canSendRequest(String node, long now) {
    return connectionStates.isReady(node, now) && selector.isChannelReady(node) &&
        inFlightRequests.canSendMore(node);
}
```

注意 `selector.isChannelReady`:TCP 三次握手成功 ≠ 可发请求,SASL/SSL 握手、以及 ApiVersions 协商都完成前连接不算 ready(1185-1199 行注释)。另外 `isReady` 会因"元数据需要立即更新"而整体返回 false,强制优先发 Metadata 请求(583-587 行)。

`InFlightRequests.canSendMore` 有个容易被忽略的细节(`clients/src/main/java/org/apache/kafka/clients/InFlightRequests.java:96-100`):队列为空,或 **"最后一个已发出的 send 已写完 且 队列长度 < maxInFlight"** 才允许继续发。它把队首当作"最后一个发出的"(add 用 `addFirst`,45-50 行;completeNext 用 `pollLast`,65-69 行),从而保证 pipelining 严格按发送顺序完成,响应配对与 `acks` 语义都依赖这一点。

### 2.3 发送与版本协商(606-683 行)

`doSend` 的版本协商逻辑:若本地无该节点的 `NodeApiVersions`(首次连上、还没收到 ApiVersionsResponse),直接用 builder 的 `latestAllowedVersion`;否则取 `latestUsableVersion(apiKey, oldestAllowed, latestAllowed)`(631-647 行)。若构建期抛 `UnsupportedVersionException`,请求不上线,直接造一个本地失败的 `ClientResponse` 放进 `abortedSends`(648-663 行)。

correlation id 由 `nextCorrelationId()` 递增生成;SASL 握手阶段会保留一段负数 id 区间用于内部消息,正常 id 越界后绕回该区间之后(1752-1758 行)。解析响应时若发现 id 对不上会抛 `CorrelationIdMismatchException`,并在 SASL 保留段场景给出专门诊断(917-933 行)。

### 2.4 poll():客户端的事件泵(695-730 行)

`poll` 的骨架是:确保已 bootstrap → 快速处理 abortedSends → 计算 metadata/telemetry 超时并 `selector.poll(min(...))` → 依次处理八个事件面:

```java
// NetworkClient.java:717-727
List<ClientResponse> responses = new ArrayList<>();
handleCompletedSends(responses, updatedNow);
handleCompletedReceives(responses, updatedNow);
handleDisconnections(responses, updatedNow);
handleConnections();
handleInitiateApiVersionRequests(updatedNow);
handleTimedOutConnections(responses, updatedNow);
handleTimedOutRequests(responses, updatedNow);
handleRebootstrap(responses, updatedNow);
```

关键语义:

- **handleCompletedSends**(1051-1060 行):只对 `expectResponse=false` 的请求立即完成(如 NoResponse 类请求),否则等响应。
- **handleCompletedReceives**(1087-1114 行):`inFlightRequests.completeNext(source)` 弹出配对请求,`parseResponse` 反序列化;`maybeThrottle` 按响应里的 `throttleTimeMs` 把整个连接 `connectionStates.throttle(nodeId, now + throttleTimeMs)`(1071-1079 行)——配额限流是**连接级**而非请求级;内部请求(METADATA / API_VERSIONS / telemetry)直接由 updater 消费,不进入业务响应列表(1103-1112 行)。
- **连接状态机的推进**:`handleConnections` 只把新连接放进 `nodesNeedingApiVersionsFetch`(1185-1199 行);`handleInitiateApiVersionRequests` 在 channel ready 且窗口有位时才真正发 ApiVersionsRequest,并把状态置为 `CHECKING_API_VERSIONS`(1201-1230 行,注释解释了为何在"排队发送时"而非"TCP 建连时"切状态,否则可能永远卡在该状态)。`handleApiVersionsResponse` 里有个向后兼容细节:若服务端回 `UNSUPPORTED_VERSION` 且响应携带了 ApiVersions 自身的版本表(Kafka 2.4+ 行为),客户端用其 maxVersion 降级重试;否则回退到 v0(1131-1148 行)。4.x 还加了 KIP-1242:连接时可携带 clusterId+nodeId 让 broker 校验,不匹配时服务端返回 `REBOOTSTRAP_REQUIRED` 触发客户端重 bootstrap(1119-1131、1217-1224 行)。
- **两类超时**:请求超时(`handleTimedOutRequests`,1009-1017 行)和连接建立超时(`handleTimedOutConnections`,1032-1043 行)都以**关闭连接**收尾——超时被统一建模为断连。
- **断连处理**(970-1000 行):按 `ChannelState` 区分认证失败/认证中断/未连上等,更新退避、清除 apiVersions、`cancelInFlightRequests` 给所有在途请求发 `disconnected` 回调。

### 2.5 leastLoadedNode 与元数据刷新(835-899、1404-1638 行)

`leastLoadedNode` 从随机偏移开始遍历(848 行)避免所有客户端同时选中同一 broker;规则是:有连接且 inflight=0 直接返回(859-864 行),否则优先 ready 节点中 inflight 最小者,再退而求其次选"正在建连"的,最后选"可以发起连接"的(884-898 行)。

`DefaultMetadataUpdater.maybeUpdate`(1450-1484 行)在 `metadata.timeToNextUpdate==0` 且无在途 Metadata 请求时触发:挑 leastLoadedNode 发 MetadataRequest(`sendInternalMetadataRequest`,`isInternalRequest=true`,611-614 行);若没有可用节点且配置了 `MetadataRecoveryStrategy.REBOOTSTRAP`,直接回退到 bootstrap 地址重来(1470-1476 行)。成功响应回调 `handleSuccessfulResponse`(1519-1553 行)里:leader 的 listener 缺失会打 WARN(最多列 10 个分区);空 broker 列表视为临时态忽略;否则 `metadata.update(...)`。断连会 `metadata.requestUpdate(false)`(1500-1508 行)——**用陈旧元数据连上错误 broker、被断连、再请求新元数据**正是客户端自愈循环。

### 2.6 4.x 新变化小结

对比老版本,本版本 NetworkClient 的显著变化:① TelemetrySender(KIP-714)内嵌为内部类,粘性节点策略(1640-1741 行);② 异步 DNS bootstrap + `BootstrapResolutionException` 超时路径(1301-1402 行,超时不抛出而是落到 metadata 层由上层观察,1338-1346 行);③ rebootstrap 元数据恢复策略全程贯穿(1232-1244、1539-1541 行)。

---

## ③ SocketServer / Processor 与 RequestChannel

### 3.1 路径变迁:壳在 server,实现在 core

任务书提示的 `server/src/main/java/org/apache/kafka/network/SocketServer.java` 在 4.x 只是一个 42 行的**壳类**:仅保留 metrics 常量(`METRICS_GROUP`、可再配置项集合)和静态工具 `closeSocket`(该文件 24-42 行)。真正实现仍在 `core/src/main/scala/kafka/network/SocketServer.scala`(1693 行);Java 侧的 `Processor`、`Request`、`Response`(Send/NoOp/CloseConnection/Start/EndThrottling)等抽象已抽到 `server/src/main/java/org/apache/kafka/network/` 包,Scala 与 Java 通过 `import ...{Processor => JProcessor, SocketServer => JSocketServer}` 桥接(`SocketServer.scala:43`)。这是典型的"JVM 多语言仓库逐步 Java 化"的中间态。

### 3.2 SocketServer 与 Acceptor

`SocketServer` 持有 `memoryPool`(请求缓冲池,`queued.max.bytes` 限总量,`SocketServer.scala:97`)、每个 endpoint 一个 `DataPlaneAcceptor`、以及唯一的 `dataPlaneRequestChannel`(99-100 行)。4.x 的启动顺序值得一提:构造时只创建 Acceptor/Processor 并**不启动线程**(142-150 行注释);`enableRequestProcessing(authorizerFutures)` 会把每个 listener 的启动**链在 Authorizer 初始化完成之后**(`SocketServer.scala:173-211`),避免鉴权器未就绪时放行请求。

`Acceptor.run()` 主循环极简:select(500ms) → 对每个 OP_ACCEPT 调 `accept()` → 关闭到期的 throttled 连接(572-591 行)。`accept()` 里 `connectionQuotas.inc` 可能抛两类异常:超上限抛 `TooManyConnectionsException` 直接关;超**建连速率**抛 `ConnectionThrottledException`,连接先放进 `throttledSockets` 优先队列延迟关闭(663-687 行)。socket 统一 `TcpNoDelay=true`、`KeepAlive=true`(689-695 行)。

新连接的分配是**阻塞式 round-robin**:遍历 processor 列表,谁的 `newConnections` 队列(容量 `CONNECTION_QUEUE_SIZE`)有位给谁;全满则 `mayBlock=true` 用 `put` 硬塞最后一个,Acceptor 为此阻塞的时间计入 `AcceptorBlockedPercentMeter`(623-658、1119-1136 行)。

### 3.3 Processor:一个连接复用器的自洽循环

Processor 线程名形如 `data-plane-kafka-network-thread-{nodeId}-{listener}-{protocol}-{id}`(746 行)。其主循环(`SocketServer.scala:871-898`)各步骤的要点:

- **processNewResponses**(915-951 行):五种响应各司其职——`NoOpResponse`(如 acks=0)不发包但要尝试 unmute 让服务端继续读该连接上的流水线请求;`SendResponse` 注册写;`CloseConnectionResponse` 主动断连;Start/EndThrottling 驱动 channel mute 状态机。
- **mute/unmute 协议**:读完一个请求立刻 `selector.mute(connectionId)`(1021 行);响应真正写完后 `processCompletedSends` 再 unmute(1052-1053 行)。这保证"处理中"的连接不再读入新请求,内存池不会被慢请求撑爆。
- **processCompletedReceives**(982-1039 行):`JProcessor.parseRequestHeader` 解析头部 → 构造 `RequestContext`(含 principal、listenerName、clientInformation)→ `new Request(...)`;ApiVersionsRequest 在此被截获注册 `ClientInformation`(软件名+版本,KIP-511,1009-1018 行)。SASL 重认证也在这条路径触发(990-992 行)。
- **processDisconnected**(1068-1084 行):递减连接配额、通知 disconnect listeners。
- **closeExcessConnections**(1086-1092 行):broker 总连接数超限时,通过 `selector.lowestPriorityChannel()` 关掉**最老**的连接。

连接 id 格式为 `localAddr:localPort-remoteAddr:remotePort-index`,index 单调递增,防止端口重用导致在途响应路由错乱(866-869、1178-1182 行)。

### 3.4 ConnectionQuotas:四层配额

`ConnectionQuotas`(`SocketServer.scala:1252-1693`)在 `inc()` 里串行施加:① broker 总建连速率 sensor;② listener 建连速率;③ IP 建连速率(超限回滚记录并抛 `ConnectionThrottledException`,1531-1546 行);④ 每 IP 最大连接数(超限抛 `TooManyConnectionsException`,1271-1286 行)。listener 级 maxConnections 打满时,`waitForConnectionSlot` 让 **Acceptor 线程** `counts.wait()`(1429-1446 行)——这也是 Acceptor 可能被阻塞的第二个来源。特例:`interBrokerListenerName` 是"受保护 listener",其他 listener 都满时它仍可建连(1463-1464、1454-1461 行),保证集群内部通信不被外部客户端挤死。

### 3.5 RequestChannel:两条队列

`RequestChannel`(`RequestChannel.scala:40-201`)有两条 `ArrayBlockingQueue`:主 `requestQueue`(容量 `queued.max.requests`)与 `callbackQueue`。`receiveRequest(timeout)` **优先**消费 callbackQueue(160-171 行)——回调请求(如 AlterPartition 的异步续段)已经排过一次队,优先执行减少整体延迟;`sendCallbackRequest` 时会向主队列塞一个 `WakeupRequest` 唤醒 Handler,塞不进去说明队列满、Handler 反正会被唤醒(195-199 行)。`sendResponse` 按 `request.processor` 找回原 Processor 投递(149-154 行);Processor 可能已被动态摘除,此时响应直接丢弃。

Processor 数量支持动态增减:`num.network.threads` 的 reconfiguration 校验只允许在新值处于旧值 [0.5x, 2x] 区间内(360-425 行);摘除 processor 时同步从 requestChannel 移除并丢弃其 pending 响应(539-547 行)。

---

## ④ Purgatory:DelayedOperation 与 TimingWheel

### 4.1 DelayedOperation:完成的"一次性和并发安全"

`server-common/.../purgatory/DelayedOperation.java`(155 行)是所有延迟操作(Produce acks=-1、DelayedFetch、DelayedJoin、DelayedCreateTopics 等)的基类。三要素:`onComplete()`(业务完成逻辑,恰执行一次)、`onExpiration()`(超时逻辑)、`tryComplete()`(条件检查)。完成入口收敛到 `forceComplete()`:

```java
// DelayedOperation.java:60-81(节选)
public boolean forceComplete() {
    if (completed) return false;
    lock.lock();
    try {
        if (!completed) {
            completed = true;
            cancel();          // 取消 TimingWheel 里的超时任务
            onComplete();
            return true;
        } else return false;
    } finally { lock.unlock(); }
}
```

`run()`(定时器线程执行)就是 `forceComplete() → onExpiration()`(145-149 行)——超时与提前完成共用同一条完成路径,谁先抢到 completed 标志谁生效。

### 4.2 tryCompleteElseWatch 与 watcher 分片

`DelayedOperationPurgatory`(`DelayedOperationPurgatory.java`)以 `(操作, watchKeys)` 二元组织:操作按 key 挂到 watcher 列表,key 事件发生时外部调 `checkAndComplete(key)` 触发批量重试(184-199 行)。`tryCompleteElseWatch`(122-176 行)的经典范式是"检查-注册-再检查":先 `safeTryCompleteOrElse`(持操作锁尝试完成,失败则把操作挂到所有 key 的 watcher 列表,155-162 行),全部挂好后**再** tryComplete 一次——第二次仍失败即可保证不漏掉任何后续事件(注册发生在事件检查之后,与事件回调构成 happens-before)。类内注释用一段"story about lock"(133-154 行)解释了两轮锁序死锁场景,结论是 `checkAndComplete` 调用方不应持有排他锁。

watcher 列表按 `key.hashCode % 512` 分片(41、105-107 行)降低锁竞争;操作按 key 挂到 watcher 列表后,`Watchers.tryCompleteWatched` 遍历尝试完成并清理(333-352 行)。

### 4.3 层级时间轮

`server-common/.../timer/TimingWheel.java` 是教科书级层级时间轮实现(类注释 22-95 行给出完整推导:插入/删除 O(1),对比 DelayQueue/Timer 的 O(log n))。`add` 的三分支(147-179 行):

```java
// TimingWheel.java:150-177(节选)
if (timerTaskEntry.cancelled()) return false;
else if (expiration < currentTimeMs + tickMs) return false;         // 已到期
else if (expiration < currentTimeMs + interval) {                   // 本轮能装下
    long virtualId = expiration / tickMs;
    int bucketId = (int) (virtualId % (long) wheelSize);
    TimerTaskList bucket = buckets[bucketId];
    bucket.add(timerTaskEntry);
    if (bucket.setExpiration(virtualId * tickMs)) queue.offer(bucket); // 只有桶到期时间变了才入 DelayQueue
    return true;
} else {                                                            // 溢出,交给上层轮
    if (overflowWheel == null) addOverflowWheel();
    return overflowWheel.add(timerTaskEntry);
}
```

两个精妙点:① **桶复用**:bucket 是环形数组槽,只有当 `setExpiration` 改变了桶的到期时间(轮子转过一圈后被复用)才重新入 DelayQueue(163-171 行注释);② **溢出轮按需创建**,上层轮的 tickMs = 本层 interval,wheelSize 不变,`overflowWheel` 因双检锁需要 volatile(106-108、131-145 行)。

`SystemTimer`(SystemTimer.java)默认 tickMs=1ms、wheelSize=20(44-46 行),`advanceClock(timeoutMs)` 从 DelayQueue poll 出到期桶,`bucket.flush` 把任务**逐个重插**回时间轮(89-106 行)——重插时若已到期则直接提交单线程 taskExecutor 执行(76-83 行),这正是层级轮"高层降级到低层"的机制。Purgatory 的 `ExpiredOperationReaper` 线程循环 `advanceClock(200ms)`(409-422 行),顺带在 `estimatedTotalOperations - numDelayed > purgeInterval` 时清理 watcher 列表里已被别人完成的残留项(386-404 行),防止长期运行后的内存驻留。

KRaft 里没有直接复用这套类:`KafkaRaftClient` 用的是 `ThresholdPurgatory`(累计阈值型,构造于 `KafkaRaftClient.java:304-305`),见 §5。

---

## ⑤ KRaft:KafkaRaftClient、KafkaRaftLog 与 QuorumController

### 5.1 KafkaRaftClient:单线程事件驱动的 Raft 实现

`raft/src/main/java/org/apache/kafka/raft/KafkaRaftClient.java`(4185 行)是 KRaft 的心脏。它的线程模型:**所有状态变更都在单一 poll 线程上发生**。`poll()`(3687-3712 行)= 关机检查 → `pollCurrentState`(按 Leader/Candidate/Prospective/Follower/Unattached/Resigned 分派,3540-3556 行)→ 快照清理计时 → `messageQueue.poll(pollTimeoutMs)` 阻塞等待 → 处理入站消息 → 处理 listener 注册。入站 RPC 通过 `handle()` 投入 `BlockingMessageQueue` 返回 future(3672-3681 行),从而免锁。

**选举**。状态机含 6 态,比标准 Raft 多了 `Prospective`(pre-vote,KIP-2082 系列演进而来)与 `Unattached`/`Resigned`。发起选举:`transitionToProspective` 先发 **不带自增 epoch** 的 PreVote(`maybeSendVoteRequests` 中 `boolean preVote = quorum.isProspective()`,3223-3249 行),拿到多数 PreVote 同意才 `transitionToCandidate` 真正抬 epoch;若对端回 `UNSUPPORTED_VERSION`(不支持 preVote 的老节点),则立刻降级为传统 Candidate(960-967 行)。`handleVoteRequest`(835-951 行)的投票条件是候选人的 (lastEpoch, lastOffset) 字典序 **不落后于** 本地 `endOffset()`(925-929 行,`canGrantVote`),并校验 cluster id、voter key(静态目录 id,901-918 行)。

**获胜与就任**。选票过半后 `onBecomeLeader`(651-677 行)做四件事:创建 `BatchAccumulator`( linger 批量)、`quorum.transitionToLeader`、`log.initializeLeaderEpoch` 在日志尾打**epoch 起点标记**、立即 `appendStartOfEpochControlRecords` 写控制记录——注释解释:"HWM 只有在新 epoch 有记录写入后才能推进,先写一条控制记录避免提交延迟"(670-673 行)。随后 leader 周期性向未确认的 voter 补发 `BEGIN_QUORUM_EPOCH`(3119-3149 行)。

**失效检测**。leader 侧 `LeaderState.checkQuorumTimeoutMs = fetchTimeoutMs * CHECK_QUORUM_TIMEOUT_FACTOR`(`raft/src/main/java/org/apache/kafka/raft/LeaderState.java:153`),超时未收到某 voter 的 FETCH(或 FETCH_SNAPSHOT,`KafkaRaftClient.java:2031-2038` 连快照拉取也算活性)则 `transitionToResigned`(3186-3190 行);follower 侧 `hasFetchTimeoutExpired` 超时则转 Prospective 触发新选举(3343-3346 行)。Resigned 状态会发送 `END_QUORUM_EPOCH` 并可指定 preferred successors,配合 `strictExponentialElectionBackoffMs`(1064-1073 行)让继任者按优先级指数退避抢主,减少选举风暴。

**复制**。leader 不主动推送,全部由 follower 的 FETCH 拉动。leader 侧 `handleFetchRequest`(1487-1603 行)立即返回的条件有六:出错/有数据/maxWaitMs=0/日志分叉需截断/需转快照/HWM 有更新(1535-1548 行);否则挂入 `fetchPurgatory.await(fetchOffset, maxWaitMs)` 长**轮询**(1551-1602 行)。`tryCompleteFetchRequest`(1605-1658 行)里藏着 HWM 的推进点:`state.updateReplicaState(...)` 记录该 follower 的拉取位置,**只有 HWM 变化时**才 `onUpdateLeaderHighWatermark`(1637-1639 行)。leader 自身写路径:`prepareAppend` 只入 `BatchAccumulator` 并按需 wakeup(3715-3745 行);poll 线程 `maybeAppendBatches` 到 linger 期后 drain → `appendBatch` 落盘 → `flushLeaderLog`(先 `updateLeaderEndOffsetAndTimestamp` 再 `log.flush`,679-683 行)。HWM 更新(`onUpdateLeaderHighWatermark`,368-395 行)一气呵成:`log.updateHighWatermark` → 完成 `appendPurgatory`(等多数派确认的 append future)→ `fetchPurgatory.completeAll`(所有挂起的 FETCH 都可能因新 HWM 满足)→ 通知 listener。follower 侧 `handleFetchResponse`(1693+ 行)处理三种指令:`divergingEpoch` 非负则**截断**——且拒绝截到 HWM 以下(1752-1758 行,防数据丢失);`snapshotId` 非负则转 FETCH_SNAPSHOT;否则 `appendAsFollower` 落盘并用 `min(本地 endOffset, leader HWM)` 更新本地 HWM(342-354 行)。

**快照**。leader 对"空日志 + 存在非 bootstrap 快照"的 follower 直接回快照 id 而非日志数据(1625-1628 行);`handleFetchSnapshotRequest`(1926-2045 行)按 (position, maxBytes) 对快照文件切片回传。listener(KRaft 内部的元数据应用方)落后于 log start offset 时也会直接收到快照句柄(`updateListenersProgress`,403-435 行)。

### 5.2 KafkaRaftLog:4.5 的元数据日志已"投靠" UnifiedLog

原 `KafkaMetadataLog` 在本版本已不存在;grep 全仓后确认其演化形态是 `raft/src/main/java/org/apache/kafka/raft/internals/KafkaRaftLog.java`(838 行),`implements RaftLog`。最大的结构变化:**底座从自管理 segment 换成了标准 `UnifiedLog`**(`KafkaRaftLog.java:84`),由 `core/src/main/scala/kafka/raft/KafkaRaftManager.scala:195-205` 的 `KafkaRaftLog.createLog` 构建在 `metadata.log.dir` 下。这意味着元数据日志复用了数据日志的全部工程积累(段管理、恢复 LogLoader、索引、flush 语义),`read()` 把 `Isolation.COMMITTED` 映射为 `FetchIsolation.HIGH_WATERMARK`(119-125 行),append 则区分 `appendAsLeader(AppendOrigin.RAFT_LEADER)` 与 `appendAsFollower`(147-167 行)。

快照与清理的关键不变量:

- **快照 id 必须 batch 对齐**:`createNewSnapshot` 用一次 `maxTotalBatchBytes=1` 的受限读验证 snapshotId.offset 恰是某 batch 的 baseOffset,否则抛异常(355-377 行)——否则 follower 应用快照后将无法从该 offset 继续 FETCH。
- **删除只能向前**:`deleteBeforeSnapshot` 把 log start offset 推进到快照终点后 `deleteOldSegments`,并删除更旧的快照(471-501 行);`truncateTo` 禁止低于 HWM(233-241 行);`truncateToLatestSnapshot` 处理"快照比日志新"(follower 落后太多时整卷重来)的场景(243-264 行)。
- 清理由 `RaftMetadataLogCleanerManager` 每 60s 触发一次 `maybeClean`(`KafkaRaftClient.java:315、3632-3660`),按 `metadata.max.retention.bytes` / `.ms` 反复"删最旧快照 → 推进 log start → 删段",但**永远保留最后一个快照**(`cleanSnapshots` 要求 `snapshots.size() >= 2`,`KafkaRaftLog.java:560-583`)。

### 5.3 QuorumController:事件队列上的状态机复制机

`metadata/src/main/java/org/apache/kafka/controller/QuorumController.java`(2245 行)是 KRaft 架构下的 active/standby 控制器。要点:**单线程事件队列**(`KafkaEventQueue`,1359 行)+ ** records = 真相**。它与 `KafkaRaftClient` 的接口就是 `raftClient.register(metaLogListener)`(1657 行)注册的四个回调:`handleCommit` / `handleLoadSnapshot` / `handleLoadBootstrap` / `handleLeaderChange`(`QuorumMetaLogListener`,967-1144 行)。

**激活(claim)**。`handleLeaderChange` 发现自己是新 leader 时,以 `raftClient.logEndOffset()` 作为 newNextWriteOffset 调 `claim(epoch, newNextWriteOffset)`(1118-1122 行)。`claim`(1154-1176 行)置 `curClaimEpoch`、激活 offset/cluster 两个子管理器,并把一个 `ControllerWriteEvent("completeActivation")` **prepend 到事件队列头部**——注释强调"prepend 只准用于此处",保证激活逻辑先于队列中积压的任何用户写事件执行(1164-1172 行)。`CompleteActivationEvent` 调 `ActivationRecordsGenerator.generate(...)` 生成激活 records(未提交的 bootstrap 元数据、feature level 等,1178-1202 行)。相应的 `renounce()`(1204-1220 行)会 `raftClient.resign`、把 deferredEventQueue 里所有等待中的请求以 `NOT_CONTROLLER` 失败化。

**复制与写路径**。写事件 `ControllerWriteEvent.run`(781-854 行)是理解 KRaft 控制器的核心:

```java
// QuorumController.java:816-842(节选)
long offset = appendRecords(log, result, maxRecordsPerBatch,
    records -> {
        int recordIndex = 0;
        long lastOffset = raftClient.prepareAppend(controllerEpoch, records);
        long baseOffset = lastOffset - records.size() + 1;
        for (ApiMessageAndVersion message : records) {
            replay(message.message(), Optional.empty(), baseOffset + recordIndex); // 先改内存态
            recordIndex++;
        }
        raftClient.schedulePreparedAppend();   // 再触发复制
        offsetControl.handleScheduleAppend(lastOffset);
        return lastOffset;
    });
...
if (!future.isDone()) deferredEventQueue.add(resultAndOffset.offset(), this);
```

三步语义:① `generateRecordsAndResult()` 先**纯计算**出 records(不改硬状态);② active 控制器**乐观地在内存里先行 replay**(失败即 fatal,因为 Raft 复制不可回滚);③ 请求 future 按"日志 offset"注册进 `deferredEventQueue`,等日志提交到该 offset 后由 `handleCommit` 回调统一放行。无 records 的"纯读"也会等待 purgatory 里最高 pending offset,保证读到不早于其排队时刻的状态(793-812 行)。`appendRecords`(889-942 行)按 `maxRecordsPerBatch` 切批,`isAtomic()` 的结果必须单批。`handleCommit` 回调(active 侧只需 `offsetControl.handleCommitBatch` + `deferredEventQueue.completeUpTo(lastStableOffset)`;standby 侧逐条 `replay`,969-1020 行)。standby 加载快照直接重放 records(`handleLoadSnapshot`,1023-1066 行),且 active 控制器收到加载快照事件视为 fatal。

`replay()`(1229-1328 行)是所有元数据 record 类型的分发中枢(30+ 种)。值得注意的一个历史痕迹:`ZK_MIGRATION_STATE_RECORD` 分支注释明言"4.0 起 ZK 已移除,但 3.x 迁移到 KRaft 后滚动升级到 4.0 的用户元数据日志里还有这种 record,故保留为 no-op"(1302-1306 行)——这正是 ZK 时代对照在代码里的化石层。

**旁路机制**:active 控制器空闲时周期写 `NoOpRecord`(`registerWriteNoOpRecord`,1660-1672 行),让 follower 的 FETCH 有数据可拉、HWM 持续推进,缩短 failover 后的追赶时间;`maybeFenceStaleBroker` 周期取 `sessionTimeout/8`(1684-1686 行),注释给出"最多 112.5% 会话超时内完成 fencing"的推导。

### 5.4 与 ZK 时代的对照要点

| 维度 | ZK 时代(Kafka ≤2.8 / 3.x 兼容态) | KRaft(本仓库) |
|---|---|---|
| 元数据存储 | ZooKeeper znode 树(`/brokers/topics/...`、`/controller`) | `__cluster_metadata-0` 单分区日志,由 `KafkaRaftLog` 管理(`KafkaRaftLog.java:79`) |
| 控制器选举 | ZK 临时节点争抢 + ZK watch 驱动 | Raft 协议(VOTE/preVote/BEGIN_QUORUM_EPOCH),`KafkaRaftClient` |
| 控制器→broker 广播 | ControllerChannelManager 发 LeaderAndIsr/StopReplica 等转发 RPC | broker 自己 FETCH 元数据日志并回放,无需广播 |
| 元数据一致性 | ZK znode version + controller epoch,部分更新非事务 | records 按日志序全序提交,写事件"先重放后提交"严格可串行(`QuorumController.java:816-842`) |
| 故障恢复 | 重读全量 znode 重建状态 | 从快照 + 日志回放(`handleLoadSnapshot`) |
| 代码现状 | 4.0 起整体移除(KIP-833);仅剩 `ZK_MIGRATION_STATE_RECORD` no-op 分支(`QuorumController.java:1302-1306`) | 唯一权威实现 |

另一个有趣的闭环:KRaft quorum 节点间的所有 RPC 复用的正是 §2 的 `NetworkClient`——`KafkaRaftManager.buildNetworkClient` 用 `ManualMetadataUpdater`(目标节点由 quorum state 维护)、`maxInflightRequestsPerConnection = 1`(`core/src/main/scala/kafka/raft/KafkaRaftManager.scala:207-263`),即 KRaft 流量对每个节点严格串行,牺牲吞吐换低乱序风险。

---

## ⑥ 设计动机与取舍

1. **双队列 Reactor + mute 协议**(§③)。Processor 在读出一个完整请求后立即 mute 连接,把"慢处理"从网络线程卸载给 Handler 线程池,同时避免慢请求无限拉入新请求耗尽内存(配合 `queued.max.bytes` 内存池)。代价是**每连接并发度恒为 1**(服务端无 pipelining),单连接吞吐受 RTT 限制——这正是客户端 `max.in.flight` 的意义所在,也解释了为何服务端要把 NoOpResponse 也要 unmute 尽早恢复读。
2. **InFlightRequests 的"队首已完成才继续发"**(§2.2)。为了支持 `max.in.flight > 1` 且不破坏顺序性,客户端选择"只有上一条完全写完才允许 pipelining 下一条",这是顺序性与吞吐的折中;开启幂等后重试仍需排队,这一窗口直接决定乱序风险。
3. **Purgatory 的"条件满足即完成 + 时间轮兜底"**(§④)。大量延迟操作(可能百万级 DelayedFetch)要求 O(1) 取消与插入;层级时间轮 + DelayQueue 只管理"桶"而非"任务",任务到期前被提前完成时 `cancel()` 即可 O(1) 摘除。取舍是时间轮精度只有 1ms(可接受)且 Reaper 需要定期 purge 残留。
4. **KRaft 选择"日志即真相 + 内存快照 + 乐观重放"**(§5.3)。写请求先在内存中重放自己的 records,若失败直接 fatal——因为日志一旦复制成功不可撤销,与其实现回滚不如 fail-fast 依赖 Raft 多数派兜底。代价是单个 bug 即可 fatal 整个控制器进程;收益是路径极简、无两阶段提交。
5. **元数据日志换底 UnifiedLog**(§5.2)。放弃自管理 segment 意味着让 KRaft 日志吃上数据路径久经考验的恢复/索引/清理代码,代价是要维护 Raft 语义(epoch 起点、HWM、batch 对齐快照)与 UnifiedLog 概念间的适配层;`updateHighWatermark` 里那条"log HWM != local HWM"的临时 WARN(`KafkaRaftLog.java:289-292`,挂 KAFKA-14825)就是适配期的痕迹。
6. **preVote + 指数退避的选举治理**(§5.1)。Prospective 态避免"网络分区的少数派反复抬 epoch 打断稳定 leader";preferred successor 的指数退避让 resign 指定的继任者有序接棒,避免全员随机超时互抢。
7. **壳化迁移策略**(§3.1)。把 Scala 类逐步抽成 Java 接口/POJO(server 包)而保留 Scala 实现(core 包),是为了在不中断 KafkaCore 依赖图的前提下渐进去 Scala 化;副作用是同一个概念(Processor/SocketServer)有两处定义,读者需要靠 import 别名建立映射。

---

## ⑦ FAQ

**Q1:客户端连接就绪(TCP established)后为什么还不能发请求?**
`NetworkClient.java:1185-1199` 注释:SASL/SSL 握手发生在 TCP 之后;且 `discoverBrokerVersions=true` 时必须先收到 ApiVersionsResponse(状态机经 `CHECKING_API_VERSIONS`,`ClusterConnectionStates.java:248`)才算 `isReady`。

**Q2:max.in.flight.requests.per.connection > 1 时如何保证顺序?**
`InFlightRequests.canSendMore`(`InFlightRequests.java:96-100`)要求上一条请求的 send 完全写完才允许再发,排队按 FIFO 完成(`completeNext` 取队尾)。因此窗口内请求**总是按发送序完成**;非幂等 producer 重试时的乱序风险来自"断连后重发",而非正常 pipelining。

**Q3:broker 端一个连接同时只有一个在途请求,会不会造成队头阻塞?**
会,这是设计取舍:Processor 读完即 mute(`SocketServer.scala:1021`),响应写完才 unmute(1052-1053 行)。好处是内存池可控、实现简单;对策是客户端多连接/多分区并发,以及 Handler 快速返回 NoOpResponse 恢复读取(915-930 行)。

**Q4:请求超时后客户端做什么?**
`handleTimedOutRequests`(`NetworkClient.java:1009-1017`)**关闭整条连接**,所有在途请求收到 `timedOut` 标记的断连回调,退避后重连。连接建立超时同理(1032-1043 行)。

**Q5:broker 的连接数限制是如何分层的?**
四层:broker 总速率、listener 速率、IP 速率、每 IP 连接数上限,外加 listener/broker 级 maxConnections(`SocketServer.scala:1271-1286,1429-1446,1531-1546`)。inter-broker listener 是受保护 listener,不会被外部流量挤占配额(1463-1464 行)。

**Q6:DelayedOperationPurgatory 为什么不用 DelayQueue 直接存任务?**
DelayQueue 插入/删除 O(log n) 且不支持 O(1) 取消;时间轮插入/取消 O(1),DelayQueue 只存"到期时间变化的桶",任务提前完成时直接 `cancel()`(`TimingWheel.java:22-49` 注释;`DelayedOperation.java:72`)。

**Q7:KRaft 的 preVote 解决什么问题?**
避免被隔离的少数派反复自增 epoch(每次都会让现存 leader 被废黜)。Prospective 先用不自增 epoch 的 PreVote 探路,拿到多数同意才真正抬 epoch(`KafkaRaftClient.java:3223-3249`);对不支持 preVote 的节点自动降级(960-967 行)。

**Q8:KRaft leader 挂了,数据(元数据)会丢吗?**
不会。写请求只有当 records 被 Raft 多数派持久化、HWM 推进后才通过 `deferredEventQueue.completeUpTo` 回调客户端(`QuorumController.java:985-990`);leader 切换后新 leader 从日志/快照恢复状态,未提交的请求以 NOT_CONTROLLER 失败由客户端重试。

**Q9:为什么 metadata log 也要有快照,不能只靠日志?**
日志只能有限保留(`metadata.max.retention.bytes/ms`);快照让落后节点/新节点跳过已被清理的日志段。快照 id 必须 batch 对齐(`KafkaRaftLog.java:355-377`),否则 follower 应用快照后无法从 snapshot offset 继续 FETCH(读取总是返回包含该 offset 的整个 batch 的 baseOffset)。

**Q10:KRaft 用哪个网络层?和客户端一样吗?**
同一个 NetworkClient,但配置不同:`ManualMetadataUpdater` + `maxInflightRequestsPerConnection=1`(`KafkaRaftManager.scala:237-260`),节点列表来自 quorum state 而非 Metadata 请求。

---

## ⑧ 深挖问题(供后续章节/进一步调研)

1. **`ThresholdPurgatory` 与 `DelayedOperationPurgatory` 的语义差异**:KRaft 的 fetch/append purgatory(`KafkaRaftClient.java:304-305`)按"offset 阈值 + 超时"完成,不走 watcher/watcherKey 模型。值得对比二者在大量挂起 FETCH 时的唤醒放大效应(leader HWM 每次更新 `fetchPurgatory.completeAll`,368-395 行,是否会导致惊群?)。
2. **`ZK_MIGRATION_STATE_RECORD` no-op 的生命周期**(QuorumController.java:1302-1306):4.x 之后何时可以安全删除?删除时如何处理老元数据日志升级过程中的未知 record(目前 `default` 分支直接抛异常,1325-1326 行,意味着 KRaft 版本降级读新日志会 fatal)。
3. **ActivationRecordsGenerator 的正确性边界**:claim 时以 `raftClient.logEndOffset()` 为 nextWriteOffset(`QuorumController.java:1118-1122`),若上届 leader 在 `prepareAppend` 后、`handleCommit` 前崩溃,乐观重放进内存的 records 已提交但 deferredEventQueue 未回调——新 leader 的激活 records 如何保证与这些"孤儿写入"幂等?建议精读 `OffsetControlManager.activate/deactivate`(`OffsetControlManager.java:241,260`)与 `SnapshotRegistry` 回滚。
4. **ServerConnectionId 生成规则对响应路由的正确性**:`SocketServer.scala:866-869` 的 index 单调递增依赖 Processor 单线程递增,动态增减 Processor 时(`removeProcessors`,539-547 行)`nextProcessorId` 全局分配(`SocketServer.scala:102,154-156`)与 response 路由 `processors.get(request.processor)`(RequestChannel.scala:149)之间的竞态是否有完备保护(注释声称 processor==null 时响应丢弃即可,是否覆盖所有场景)?
5. **Acceptor 阻塞风险评估**:`waitForConnectionSlot` 在 listener 配额满时让 Acceptor `counts.wait()`(SocketServer.scala:1429-1446),此时该 listener 的**所有**新连接(包括已 accept 的)排队;结合受保护 listener 机制,评估极端场景(某 listener 建连风暴)是否会拖垮 inter-broker 通信。

---

*(报告完。全部结论基于 commit f6149f1c 实读源码,引用格式为 `文件:行号`。)*
