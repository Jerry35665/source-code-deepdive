# 第 05 章 · 网络层与 KRaft:从 Reactor 到"日志即真相"

> 基线:Kafka 4.5.0-SNAPSHOT,commit `f6149f1c`。行号均以该版本源码为准。
> 路径勘误:`server/.../network/SocketServer.java` 只是 42 行壳类(metrics 常量),真正实现在 `core/.../kafka/network/SocketServer.scala`(1693 行)——"JVM 多语言仓库逐步 Java 化"的中间态。

## 5.0 一个请求的一生

1. **Acceptor**(每 listener 一个,SocketServer.scala:458)accept 后 round-robin 分给 Processor;
2. **Processor**(num.network.threads 个,各持独立 Selector):注册连接 → poll → 读完整请求 → 构造 RequestContext 入 RequestChannel → **立即 mute 连接**(1019-1021);
3. **RequestChannel**(ArrayBlockingQueue)→ M 个 KafkaRequestHandler(num.io.threads)取请求交 KafkaApis;
4. 需等待的(acks=-1、DelayedFetch)挂 **DelayedOperationPurgatory**;
5. 响应路由回**原 Processor** 的 responseQueue,写完后 unmute(1052-1053)。

**mute/unmute 协议是核心取舍**:"处理中"的连接不再读入新请求——每连接并发度恒为 1(服务端无 pipelining),内存池可控、实现简单;代价是单连接吞吐受 RTT 限制。四层连接配额(broker 速率/listener 速率/IP 速率/每 IP 上限)层层设防;inter-broker listener 是"受保护 listener",不会被外部流量挤死。

## 5.1 NetworkClient:客户端事件泵

类注释明言 "This class is not thread-safe!"——只在 Sender 线程单线程使用。要点:

- **就绪三合一**(595-598):连接状态机 ready ∧ channel ready ∧ `canSendMore`。TCP 握手成功 ≠ 可发请求——SASL/SSL 握手与 ApiVersions 协商完成前不算 ready;
- **InFlightRequests 的顺序保证**(96-100):队列为空或"最后一个 send 已写完且队列 < maxInFlight"才允许继续发——pipelining 严格按发送序完成,响应配对与 acks 语义都依赖这一点;
- **版本协商**:无节点 ApiVersions 时用 latestAllowed,收到 UNSUPPORTED_VERSION 且响应带版本表则降级重试(2.4+ 行为),否则回退 v0;
- **超时 = 断连**:请求超时与建连超时都以关闭整条连接收尾,所有在途请求收到 disconnected 回调;
- **自愈循环**:用陈旧元数据连错 broker → 被断连 → 请求新元数据;4.x 还加了 rebootstrap 策略(元数据彻底失效时回退 bootstrap 地址重来)与异步 DNS bootstrap。

## 5.2 Purgatory:层级时间轮

`DelayedOperation` 三要素:tryComplete(条件检查)/onComplete(恰一次)/onExpiration;**超时与提前完成共用 forceComplete 一条路径,谁先抢到 completed 标志谁生效**。

`DelayedOperationPurgatory` 的经典范式是 **"检查-注册-再检查"**(tryCompleteElseWatch):先尝试完成,失败则挂到所有 key 的 watcher 列表,挂好后再试一次——第二次仍失败即可保证不漏掉任何后续事件(happens-before 论证;类注释用一段"story about lock"解释了两轮锁序死锁场景)。

**层级时间轮**(TimingWheel,注释 22-95 行给出完整推导:插入/删除 O(1) vs DelayQueue 的 O(log n)):桶只在到期时间变化时才入 DelayQueue;溢出轮按需创建、tickMs 逐层翻倍。任务提前完成时 `cancel()` O(1) 摘除。KRaft 里没有复用这套——`KafkaRaftClient` 用 ThresholdPurgatory(offset 阈值 + 超时)。

## 5.3 KRaft:单线程 poll 驱动的 Raft

`KafkaRaftClient`(4185 行)的线程模型:**所有状态变更都在单一 poll 线程**——入站 RPC 经 BlockingMessageQueue 投入,poll 阻塞等待,免锁。6 态状态机(比标准 Raft 多 Prospective(pre-vote)与 Unattached/Resigned):

- **选举**:Prospective 先发**不自增 epoch** 的 PreVote,拿到多数同意才真正抬 epoch(被隔离的少数派不再打断稳定 leader);对不支持 preVote 的老节点自动降级;
- **就任四件事**:BatchAccumulator、transitionToLeader、日志尾打 epoch 起点标记、**立即写一条控制记录**——"HWM 只有在新 epoch 有记录写入后才能推进,先写一条避免提交延迟"(与 etcd/raft 卷的 noop entry 同源同义!);
- **失效检测双向**:leader 侧 checkQuorumTimeout 未收到某 voter 的 FETCH 则退位;follower 侧 fetch 超时转 Prospective;Resigned 态发 END_QUORUM_EPOCH 并按 preferred successor 指数退避有序接棒;
- **复制全靠 FETCH 拉动**:leader 侧能立即返回的六条件(有数据/分叉/需快照/HWM 更新…),否则挂 fetchPurgatory 长轮询;follower 侧 divergingEpoch 截断——**且拒绝截到 HWM 以下**(防数据丢失);
- **HWM 更新一气呵成**:updateHighWatermark → 完成 appendPurgatory(等多数派确认的 future)→ fetchPurgatory.completeAll → 通知 listener。

**KafkaRaftLog:4.5 元数据日志"投靠"UnifiedLog**。原 KafkaMetadataLog 已不存在;KafkaRaftLog(838 行)底座换成标准 UnifiedLog——**元数据日志复用了数据日志的全部工程积累**(段管理、LogLoader 恢复、索引、flush)。关键不变量:快照 id 必须 batch 对齐(否则 follower 应用快照后无法继续 FETCH);清理永不删最后一个快照;truncateTo 禁止低于 HWM。

## 5.4 QuorumController:乐观重放的写协议

`QuorumController`(2245 行)= 单线程事件队列 + **records = 真相**。与 KafkaRaftClient 的接口就是四个回调(handleCommit/handleLoadSnapshot/handleLoadBootstrap/handleLeaderChange)。

**写事件三步语义**(816-842):① generateRecordsAndResult **纯计算**出 records(不改硬状态);② **乐观地在内存里先行 replay**——失败即 fatal,因为 Raft 复制成功后不可回滚,与其实现回滚不如 fail-fast;③ future 按"日志 offset"注册进 deferredEventQueue,等日志提交到该 offset 后由 handleCommit 统一放行。**激活(claim)事件必须 prepend 到队列头部**——注释强调"prepend 只准用于此处",保证激活先于积压的用户写事件。

旁路机制:active 控制器空闲时周期写 NoOpRecord 让 follower 的 FETCH 有数据可拉、缩短 failover 追赶时间;`maybeFenceStaleBroker` 周期取 sessionTimeout/8(注释给出"最多 112.5% 会话超时内完成 fencing"的推导)。

**与 ZK 时代的对照**:元数据从 znode 树变为单分区日志;控制器选举从 ZK 临时节点变为 Raft;broker 从被动接收 LeaderAndIsr 广播变为**自己 FETCH 元数据日志并回放**;故障恢复从重读全量 znode 变为快照 + 日志回放。化石层:`ZK_MIGRATION_STATE_RECORD` 保留为 no-op 分支("4.0 起 ZK 已移除,但 3.x 迁移用户的日志里还有这种 record")。

## 5.5 FAQ

**Q1:broker 端一个连接只有一个在途请求,不会队头阻塞吗?**
会,是设计取舍:mute 协议换内存可控;对策是客户端多连接/多分区并发。

**Q2:max.in.flight>1 时如何保证顺序?**
canSendMore 要求上一条完全写完才允许 pipelining 下一条;窗口内请求总按发送序完成。乱序风险来自断连后重发,非正常 pipelining。

**Q3:DelayedOperationPurgatory 为什么不用 DelayQueue 存任务?**
O(log n) 且不支持 O(1) 取消;时间轮插删 O(1),DelayQueue 只存"桶"。

**Q4:KRaft leader 挂了,元数据会丢吗?**
不会:写请求只有 records 被 Raft 多数派持久化、HWM 推进后才回调客户端;未提交请求以 NOT_CONTROLLER 失败由客户端重试。

**Q5:为什么 metadata log 也要快照?**
日志只能有限保留;快照让落后节点跳过已清理段。快照 id 必须 batch 对齐,否则 follower 无法从快照 offset 继续 FETCH。

**Q6:KRaft 用哪个网络层?**
与客户端同一个 NetworkClient,但配置 ManualMetadataUpdater + maxInflightRequestsPerConnection=1——KRaft 流量对每个节点严格串行,牺牲吞吐换低乱序风险。

## 5.6 小结与深挖方向

本章结论:**网络层 = mute 协议的双队列 Reactor;Purgatory = 时间轮 + 检查-注册-再检查;KRaft = 单线程 poll + 乐观重放 + 日志即真相**;三层在"KRaft quorum 复用 NetworkClient(maxInflight=1)"处闭环。深挖:

1. ThresholdPurgatory 与 DelayedOperationPurgatory 的唤醒放大对比(leader HWM 更新 completeAll 是否惊群);
2. ZK_MIGRATION_STATE_RECORD 的删除时机与降级 fatal;
3. 激活时"孤儿写入"(prepareAppend 后崩溃)与幂等的正确性边界;
4. ServerConnectionId 生成与响应路由在动态 Processor 增减下的竞态;
5. Acceptor 阻塞(listener 配额满时 wait)对 inter-broker 通信的极端影响。

> 下一章(卷末):总结与跨卷对照。
