# A-生产者:KafkaProducer 客户端子系统源码深读

> 基于仓库:`kafka` 4.5.0-SNAPSHOT,commit `f6149f1c`(2026-09-05)。
> 除特别注明外,`文件:行号` 均以 `clients/src/main/java/org/apache/kafka/` 为根,如 `producer/KafkaProducer.java:1174`。
> 本文所有结论均来自对当前工作区源码的实际阅读,未引入外部记忆。

---

## ① 全景:线程模型与组件拓扑

生产者是典型的「**用户线程 + 单一后台 IO 线程**」两级流水线:

- **用户线程**(可以是多个):执行 `send()`,完成拦截 → 序列化 → 分区 → 追加进累加器,立即返回 `Future`(`producer/KafkaProducer.java:1141-1145`)。`KafkaProducer` 明确宣称 thread-safe,共享单实例通常比多实例更快(类注释,KafkaProducer.java:112-113)。
- **Sender IO 线程**:命名 `kafka-producer-network-thread | <clientId>`,构造器中启动(KafkaProducer.java:515-518)。它是一个 `SenderThread extends KafkaThread` 包着 `Sender implements Runnable`(internals/Sender.java:1138-1143)。主循环 `while (running) runOnce()`(Sender.java:241-251),职责是:ready 检查 → drain 批次 → 组装 ProduceRequest → `client.poll()` 收响应 → 回调完成。

关键组件与归属(字段见 KafkaProducer.java:274-291):

| 组件 | 归属线程 | 职责 |
|---|---|---|
| `ProducerInterceptors` | 用户线程 | `onSend`/`onAcknowledgement`/`onSendError` 链(internals/ProducerInterceptors.java:63-98) |
| Serializer | 用户线程 | key/value 序列化(KafkaProducer.java:1198-1212) |
| `Partitioner` / `BuiltInPartitioner` | 用户线程 + Sender 线程 | 定分区;sticky 状态用 `AtomicReference` 无锁共享 |
| `RecordAccumulator` | 双方共享 | 按 TopicPartition 分桶缓冲 `ProducerBatch`;粒度锁在单个分区 Deque 上 |
| `BufferPool` | 双方共享 | 有限内存池,满了让用户线程阻塞等待 |
| `TransactionManager` | 双方共享(`synchronized`) | PID/epoch/sequence、事务状态机、txn 请求队列 |
| `Sender` + `NetworkClient` | IO 线程 | 网络收发、InFlightBatches 跟踪、ack/重试决策 |

一个值得注意的新变化:**4.5 的 Sender 不再自己继承线程**,而是被 `Sender.SenderThread` 包装(KafkaProducer.java:517),这让 `TransactionManager` 能用 `Thread.currentThread() instanceof Sender.SenderThread` 判断"非法状态迁移发生在哪条线程上"——用户线程上的非法迁移只抛 `IllegalStateException` 不污染状态,IO 线程上的则直接把自己"毒化"为 `FATAL_ERROR`(internals/TransactionManager.java:313-315,注释引 KAFKA-14831)。

优雅关闭链路:`close(timeout)` → `sender.initiateClose()`(先 `accumulator.close()` 拒绝新 append,再停线程)→ join;超时则 `forceClose` 中止全部未完成批次(KafkaProducer.java:1596-1645;Sender.java:544-558)。在 callback 里调用 `flush()` 直接抛异常防死锁(KafkaProducer.java:1417-1420),在 callback 里 `close()` 会把超时强制降为 0 防自 join(KafkaProducer.java:1604-1609)。

---

## ② 一条 send 的完整旅程

### 数据流总图

```
 用户线程(可多个)                                Sender IO 线程
 ─────────────────────────────────               ─────────────────────────────────────
 send(record, callback)
   │ interceptors.onSend()            K.java:1143
   ▼
 doSend()                                           runOnce()                        S.java:310
   │ waitOnMetadata(topic)  ──────► (wakeup,       │ transactionManager 状态检查/
   │  metadata.add + awaitUpdate     元数据等待)     │  maybeResolveSequences/bumpId    S.java:311-335
   ▼                                K.java:1293     ▼
 key/value serialize                K.java:1197    sendProducerData()               S.java:380
   ▼                                                │ accumulator.ready()   ←──┐
 partition()  (用户指定 > 自定义 >                    │ accumulator.drain()      │ mute/backoff
   murmur2(key) > UNKNOWN)          K.java:1675     │   ├ setProducerState     │
   ▼                                                │   ├ sequenceNumber++     │
 ensureValidRecordSize               K.java:1362     │   └ addInFlightBatch     │
   ▼                                                │ sendProduceRequests() ───┘
 accumulator.append()                K.java:1229     ▼                (ProduceRequest)
   │ 1) sticky peek partition                       client.poll()  ◄── 响应
   │ 2) 锁分区 Deque, tryAppend                     ▼
   │ 3) 不够则 BufferPool.allocate(阻塞)            handleProduceResponse()
   │ 4) 新批: MemoryRecords.builder                 │ acks=0: 直接 completeBatch
   │    → ProducerBatch → deque.addLast             │ error : canRetry?→reenqueue
   ▼                                                │        : failBatch
 maybeAddPartition (事务)            K.java:1237     └ NONE  : completeBatch → future.done
   │ (batchIsFull||newBatch) →                        (回调在 IO 线程执行,须快)
 wakeup sender                       K.java:1241
   │
 返回 FutureRecordMetadata
```

### 逐段解读

**(1) 拦截器。** `send()` 只做一件事:把 record 交给 `interceptors.onSend()`(可能被改写甚至返回 null),随后进入 `doSend()`(KafkaProducer.java:1141-1145)。`onSend` 抛异常只告警不中断(ProducerInterceptors.java:63-75)。`onAcknowledgement` 被包装进 `AppendCallbacks`,在批次完成时由 IO 线程回调,先拦截器后用户 callback(KafkaProducer.java:1794-1802)。

**(2) 等元数据。** `waitOnMetadata` 把 topic 加入 metadata 白名单;若缓存里已有分区数且(未指定分区或分区号在范围内)直接返回 0 等待(KafkaProducer.java:1302-1306);否则循环 `requestUpdateForTopic → wakeup → awaitUpdate` 直到超时 `max.block.ms`(KafkaProducer.java:1314-1345)。循环条件值得注意:即使拿到了 topic 元数据,若**指定分区号超出已知分区数**,仍会继续刷新——覆盖"扩分区后旧缓存不包含新分区"的场景。等待期间若 topic 元数据带错误(如授权失败),`maybeThrowExceptionForTopic` 会把 topic 级错误以 TimeoutException 复合异常的形式抛回(KafkaProducer.java:1325-1342)。这就是"第一条消息可能阻塞"的根源;类注释建议用 `partitionsFor()` 预热(KafkaProducer.java:1035-1039)。事务版的 `sendOffsetsToTransaction` 也复用了同样的预取模式,只是把等待时间从 `max.block.ms` 预算里扣除(KafkaProducer.java:823-832)。

**(3) 序列化与分区。** 序列化在用户线程同步做(KafkaProducer.java:1198-1212)。分区决策(KafkaProducer.java:1675-1695)优先级为:用户指定 `record.partition()` → 自定义 `Partitioner.partition()`(校验非负)→ 有 key 时 `BuiltInPartitioner.partitionForKey = toPositive(murmur2(keyBytes)) % numPartitions`(internals/BuiltInPartitioner.java:413-415)→ 无 key 返回 `UNKNOWN_PARTITION`,**分区延后到 accumulator 内用 sticky 逻辑决定**(KafkaProducer.java:1214-1217 注释;internals/RecordAccumulator.java:311-320)。

**(4) 尺寸校验。** `ensureValidRecordSize` 用上界估计比较 `max.request.size` 与 `buffer.memory`,超限抛 `RecordTooLargeException`(KafkaProducer.java:1362-1372)。

**(5) doSend 的异常兜底。** `ApiException` 不抛出,而是同步触发 callback、记录拦截器 `onSendError`,并 `maybeTransitionToErrorState`,同时返回一个 `isDone()==true` 的 `FutureFailure`(KafkaProducer.java:1249-1261;KafkaProducer.java:1726-1759)。

**(6) ack 之后。** 响应处理里 v13+ 用 topicId 反查 batch(Sender.java:622-634);成功路径 `completeBatch → batch.complete → produceFuture.set → 逐条 Thunk 回调 → produceFuture.done`(internals/ProducerBatch.java:242-345)。同一 partition 的回调有序性正是由"单批次内顺序遍历 thunks + 分区 FIFO 队列"保证的(KafkaProducer.java:1083-1085 注释;ProducerBatch.java:327-343)。

**(6b) 批终态机。** `ProducerBatch` 用 CAS 维护 `FinalState { ABORTED, FAILED, SUCCEEDED }`(ProducerBatch.java:64、296-316):终态只允许失败→成功这样一次"翻案"(对应"本地已判失败但 broker 实际写入成功"的场景),失败→失败忽略,成功之后任何迁移抛 IllegalStateException。`completeFutureAndFireCallbacks` 先 `produceFuture.set` 再执行回调,因为 `onCompletion` 的默认实现依赖 future 已就绪(KafkaProducer.java:1796-1798)。

**(7) Future 的链式语义与批次拆分。** `send()` 返回的 `FutureRecordMetadata` 并非独立对象,而是携带 `(produceFuture 批级结果, batchIndex 相对偏移)` 的轻量句柄(ProducerBatch.java:176-180)。当一批因 `MESSAGE_TOO_LARGE` 被 broker 拒绝时,`split()` 把原批逐条搬进新批,**原 Thunk 的 future 会被 chain 到新批的 future 上**(ProducerBatch.java:206-207),批级 `ProduceRequestResult` 通过 `addDependent` 建立依赖(ProducerBatch.java:403-414)——这保证 `flush()` 对拆分后的子批仍然有效:`awaitFlushCompletion` 等的是 `awaitAllDependents` 而非简单 `await`(RecordAccumulator.java:1222-1238)。这是"一次 send 语义上只有一次完成"的实现基础。

**(8) acks 的三种形态在代码中的落点。** `acks=0` 时 `client.newClientRequest` 传 `acks != 0` 为 false,即不注册响应处理器,响应回来后走"无响应分支"直接把全部批次按 `Errors.NONE` 完成(Sender.java:653-658,945-946),`RecordMetadata.offset` 为 -1(类注释,KafkaProducer.java:1042-1043);`acks=1` 与 `acks=all` 的区分完全在 broker 侧,客户端只是把配置透传进 `ProduceRequestData.setAcks`(Sender.java:932)。这也解释了为什么 `acks=0` 时即使 broker 返回错误客户端也感知不到。

### 协议要点:ProduceRequest v3+ 与 record batch 格式

- Produce API((apiKey=0)当前 `validVersions: 3-13`、flexibleVersions 9+(common/message/ProduceRequest.json:41-50)。4.0 起删除 v0-2;v3 引入 `TransactionalId` 与 magic v2 支持;v7 加 zstd;v8 加 RecordErrors;v9 flexible;v11/12 加 `TRANSACTION_ABORTABLE`(KIP-890);**v13 用 topicId 替代 topic name**。请求结构仅 `TransactionalId + Acks + TimeoutMs + TopicData[PartitionData]`(ProduceRequest.json:54-72),记录本体以不透明 `records` 字段传输。
- 记录容器是 **magic v2(RecordBatch)**:`CURRENT_MAGIC_VALUE = MAGIC_VALUE_V2`(record/internal/RecordBatch.java:41-46)。批量头部字段布局固定(record/internal/DefaultRecordBatch.java:104-131):baseOffset(占位)| batchLength | partitionLeaderEpoch | magic | crc | attributes | lastOffsetDelta | baseTimestamp | maxTimestamp | **producerId(8B) | producerEpoch(2B) | baseSequence(4B)** | recordsCount——幂等/事务字段直接内嵌在 batch header 中,`RECORD_BATCH_OVERHEAD = 61` 字节。非幂等生产者写入 `NO_PRODUCER_ID=-1 / NO_SEQUENCE=-1`(RecordBatch.java:57-59)。
- **事务 V2(KIP-890 part 2)**:客户端通过 finalized feature `transaction.version >= 2` 探测开启(TransactionManager.java:520-532);TV2 下 EndTxn v5+ 响应会回传新 pid/epoch,每笔事务结束即自动 bump epoch(TransactionManager.java:1810-1824);未启用 TV2 时 ProduceRequest 被钉在 ≤v11(`LAST_STABLE_VERSION_BEFORE_TRANSACTION_V2`,requests/ProduceRequest.java:43-50)。

---

## ③ RecordAccumulator 与 BufferPool 的内存管理

### 分桶结构与 append

数据结构:每 topic 一个 `TopicInfo{ CopyOnWriteMap<TopicPartition, Deque<ProducerBatch>> batches; BuiltInPartitioner }`(RecordAccumulator.java:1478-1485)。锁粒度是**单个分区的 Deque**,外层 `topicInfoMap`/`batches` 用 CopyOnWriteMap,读不加锁(RecordAccumulator.java:92-93)。

`append()`(RecordAccumulator.java:285-366)是一条精巧的双检锁 + 重试循环:

```java
// RecordAccumulator.java:324-345(节选)
synchronized (dq) {
    if (partitionChanged(topic, topicInfo, partitionInfo, dq, nowMs, cluster))
        continue;                                   // sticky 被并发切换,重试
    RecordAppendResult r = tryAppend(timestamp, key, value, headers, callbacks, dq, nowMs);
    if (r.appended()) return updatePartitionInfoOnAppend(...);
}
if (buffer == null) {
    int size = Math.max(this.batchSize, estimateSizeInBytesUpperBound(...));
    buffer = free.allocate(size, maxTimeToBlock);   // 可能阻塞 max.block.ms
}
synchronized (dq) {
    if (partitionChanged(...)) continue;
    RecordAppendResult r = appendNewBatch(tp, dq, ..., () -> MemoryRecords.builder(batchBuffer, ...), nowMs);
    if (r.newBatchCreated) buffer = null;           // buffer 所有权移交批次
}
```

- 第一段锁内**只尝试**往队尾批写(`tryAppend`,RecordAccumulator.java:532-548);写不进去(满或无批)先释放锁再去 `BufferPool` 申请内存——这是避免"持锁阻塞"的经典手法。拿锁后再验一次 sticky 分区是否被并发改写(`partitionChanged`,RecordAccumulator.java:242-265)。
- `appendNewBatch`(RecordAccumulator.java:470-499)里还有一层"先 tryAppend 再建批":如果阻塞等内存期间别的线程已经建好了批,直接复用,避免空批。
- 批的创建大小 `max(batchSize, 单条估算上界)`:单条超 batch.size 时按需扩大(RecordAccumulator.java:335-337),这就是普通路径上"单条大于 batch.size"仍可发送的机制。

### sticky batching 与自适应分区(KIP-794)

无 key 记录的分区由 `BuiltInPartitioner` 决定(每 topic 一个实例):

- `peekCurrentPartitionInfo` 返回当前 sticky 分区(CAS 创建,BuiltInPartitioner.java:174-186);追加成功后 `updatePartitionInfo` 累加 producedBytes,**累计 ≥ `batchSize`(stickyBatchSize)且当前队列全部为满时**切换到 `nextPartition()`;若队列里还有未发满的批则暂缓切换,避免产生 4KB 那样的"尾巴批"——注释给了 linger.ms=500 的完整例子(BuiltInPartitioner.java:221-259;RecordAccumulator.java:383-387)。
- `nextPartition` 优先基于 Sender 侧统计的队列积压构建**累计频率表 CFT**,按"积压越少权重越大"反折加权随机;队列长度全相等或分区 <2 时退化为对 `availablePartitions` 均匀随机(BuiltInPartitioner.java:74-137、273-359)。
- 自适应模式还支持**机架感知**(同 rack leader 优先, BuiltInPartitioner.java:88-95)和**可用性剔除**:`partitioner.availability.timeout.ms` 内 ready 与 drain 时间差过大的节点,其分区从候选剔除(RecordAccumulator.java:842-855、1095-1113)。

### ready / drain 与 mute 语义

`ready()`(RecordAccumulator.java:892-903)遍历 topic→partition,判定节点可发的条件汇总在类注释里:分区不在 backoff、未 muted,且(满 | 等待 ≥ linger | 内存耗尽有线程在等 | accumulator 关闭 | flush 中 | 事务 completing)(RecordAccumulator.java:876-890、714-736)。注意"内存耗尽 → 立刻全部可发"是为了解救阻塞在 `allocate` 上的用户线程。

`drain()`(RecordAccumulator.java:1083-1093)按节点逐个 drain,每节点维护 `nodesDrainIndex` 轮转起点防饥饿(RecordAccumulator.java:982-990)。单节点 drain(RecordAccumulator.java:976-1061)的关键点:

- `isMuted(tp)` 直接跳过(Sender 在 `max.in.flight.requests.per.connection=1` 时 drain 后 mute、completeBatch 后 unmute 来保证顺序,Sender.java:420-426、736-738);
- 超过 `maxRequestSize` 且已收集到批则 break;单批本身超限仍放行(压缩后偶发,RecordAccumulator.java:1013-1020);
- **幂等批的出队即赋号**:无 sequence 的批在此刻写入 pid/epoch/baseSequence 并 `incrementSequenceNumber`,`addInFlightBatch` 进入事务管理器跟踪(RecordAccumulator.java:1027-1049);带 sequence 的重试批**不改号**,防止"上一次其实成功了 → 本次改号会造成重复"(注释,RecordAccumulator.java:1034-1037)。
- 幂等/事务下的 drain 纪律由 `shouldStopDrainBatchesForPartition`(RecordAccumulator.java:939-974)约束:partition 未加入事务不许发;`producerIdAndEpoch` 无效不许发;存在**旧 epoch 的在途批**或**未决序列**(unresolved)不许发新批;重试期间实际退化为"每分区单 in-flight"。

### BufferPool:固定块 + FIFO 公平等待

`BufferPool` 是高度定制的内存池(类注释,BufferPool.java:39-47):`poolableSize`(= batch.size)的块进 free list 回收;非整块内存记入 `nonPooledAvailableMemory`。

`allocate(size, maxTimeToBlockMs)`(BufferPool.java:136-220):

```java
// BufferPool.java:156-194(节选)
if (size == poolableSize && !this.free.isEmpty())
    return this.free.pollFirst();                   // 命中整块,快路径
int freeListSize = freeSize() * this.poolableSize;
if (this.nonPooledAvailableMemory + freeListSize >= size) {
    freeUp(size);                                   // 把 free 块折算回可用内存
    this.nonPooledAvailableMemory -= size;
} else {
    while (accumulated < size) {                    // 阻塞路径:累够为止
        remainingTimeToBlockNs -= awaitMemory(moreMemory, remainingTimeToBlockNs, ...);
        ... freeUp(size - accumulated);
        int got = (int) Math.min(size - accumulated, this.nonPooledAvailableMemory);
        this.nonPooledAvailableMemory -= got; accumulated += got;
    }
}
```

要点:① 公平性——`waiters` 是 FIFO 的 Condition 队列,`signalNextWaiterIfMemoryAvailable` 只唤醒队首(BufferPool.java:422-425),防止大请求被后来小请求饿死(注释点名防死锁);② 等待中途拿到部分内存也算持有,异常时在 finally 归还(`nonPooledAvailableMemory += accumulated`,BufferPool.java:199-203);③ `deallocate` 只回收整块进 free list,其余折回内存并 signal(BufferPool.java:481-496)。

**新特性:INCREMENTAL(chunked)分配策略**。`buffer.memory.allocation.strategy` 选 `incremental` 且 `batch.size >= 16KB` 时,producer 改用 `ChunkedRecordAccumulator` + `BufferPool.allocateChunks`:每批由固定 16KB chunk 按需挂载,内存占用随实际写入量而非 `分区数 × batch.size` 增长(internals/ChunkedRecordAccumulator.java:41-46;KafkaProducer.java:461-512)。其 append 循环比 full 策略多一种结果:open 批在 batch.size 限额内但 chunk 容量不足时返回 `needsBufferExtension(n)`,由调用方先分配 n 字节 chunk 挂上去再重试(RecordAccumulator.java:1369-1441 的 `RecordAppendResult` 三态注释)。附带两个间接收益:chunk 归还池化后 GC 压力更平稳;且"批未写满不预留整块"使高分区数下的 OOM 风险大幅下降。当前限制:不支持压缩(KAFKA-20579,KafkaProducer.java:477-483)。`allocateChunks` 原子地按 chunk 向上取整预订,失败整体退款(BufferPool.java:277-392)。

**超期清理**:`delivery.timeout.ms` 到期的批由 Sender 在 `sendProducerData` 里分两处收割——未 drain 的(`accumulator.expiredBatches`)与已 drain 在途的(`getExpiredInflightBatches`),后者失败时**不立即释放 buffer**(KAFKA-19012:网络层可能仍在读),标记后由后续响应路径释放(Sender.java:185-217、362-378、854-863;RecordAccumulator.java:1163-1180)。过期批若处于重试中还会 `markSequenceUnresolved`,把该分区冻结到所有在途请求落定(Sender.java:373-377)。

**强杀路径**:`abortIncompleteBatches` 用 `appendsInProgress` 计数器做"终止循环条件"——只要还有用户线程在 append,就再跑一轮 abort,直到没有任何线程在写入,最后一轮 abort 兜住"最后一个 append 刚建出的批"(RecordAccumulator.java:1251-1264)。`appendsInProgress.incrementAndGet` 放在 append 的最前面(RecordAccumulator.java:299),这正是它存在的理由。事务下的中止则走 `abortUndrainedBatches`:只中止**还没有 sequence** 的批(带 sequence 的可能已经上过 broker,只能等响应)(RecordAccumulator.java:1298-1314)。

**内存记账的两个细节**:其一,`ProducerBatch` 继续用 `estimatedSizeInBytes()`(MemoryRecordsBuilder 的实时估算)而非 buffer 容量来参与 drain 的 `maxSize` 判断与指标统计(RecordAccumulator.java:1013、1055),压缩进行中这个值会缓慢增长;其二,`completeBatch → deallocate` 有 `isBufferDeallocated` 幂等保护与 inflight 状态校验,重复释放或对在途批释放都会被拦截,后者还会向池"捐赠"一块同容量 buffer 以免池记账丢失(ProducerBatch.java:159-161;RecordAccumulator.java:1170-1177)。

### Sender 主循环:runOnce 的完整走查

`runOnce()`(Sender.java:310-346)第一步永远先照料事务:`maybeResolveSequences` 收口未决序列 → fatal 时 `maybeAbortBatches` 后直接 `client.poll` 返回 → abortable 时按授权错误分流 → `bumpIdempotentEpochAndResetIdIfNeeded` 幂等补号 → `maybeSendAndPollTransactionalRequest` 若有事务请求在飞则本轮完全让路(返回 true 提前结束)。事务路径被设计成"独占轮次":同一轮要么只跑事务请求,要么只跑 produce,不交错。

随后 `sendProducerData`(Sender.java:380-455)按序完成:ready → unknown-leader 触发元数据更新 → `client.ready` 过滤掉 TCP 未就绪节点并记录 `pollDelayMs` → drain → 注册 InFlightBatches → (order 保证时)mute → 收割过期批 → 更新指标 → 计算下次 poll 超时(取"最近的可发检查时刻 / 节点就绪延迟 / 最近的批过期时刻"三者最小,有 ready 节点则直接 0)→ `sendProduceRequests`。

pollTimeout 的计算逻辑(Sender.java:442-452)是理解"Sender 空闲时睡多久"的钥匙:没有任何 ready 数据时,睡到"下一个批次进入 linger 到期"或"下一个批次即将过期"或"下一个节点可连接"三者中最早的时刻,避免空转;有 ready 数据则零超时,让本轮 send 完成后立刻再进 loop 继续凑下一轮请求。

---

## ④ 幂等与事务:状态机、sequence 与 epoch

### 4.1 幂等最小机制:pid + epoch + baseSequence

每个分区维护 `TxnPartitionEntry{ producerIdAndEpoch, nextSequence, lastAckedSequence, inflightBatchesBySequence(TreeSet), lastAckedOffset }`(internals/TxnPartitionEntry.java:33-74)。发批时:

1. drain 时取 `sequenceNumber(tp)` 作为该批 `baseSequence`,再 `incrementSequence(recordCount)`(RecordAccumulator.java:1042-1043);序列号用 `DefaultRecordBatch.incrementSequence` 做 int 溢出回绕。
2. broker 侧按 `(pid, epoch, sequence)` 连续性去重;乱序返回 `OUT_OF_ORDER_SEQUENCE_NUMBER`。
3. 响应成功时 `handleCompletedBatch` 单调推进 `lastAckedSequence` 并更新 `lastAckedOffset = baseOffset + recordCount - 1`(TransactionManager.java:766-782)。

**LastError / OutOfOrderSequence 的客户端处置**(`TransactionManager.canRetry`,TransactionManager.java:1043-1110)非常讲究:

- `OUT_OF_ORDER_SEQUENCE_NUMBER` 只有当该批**不是**"lastAcked+1"或者存在未决序列时才重试(说明是乱序到达的后续批,等前面的批落地即可);若确认真出现空洞:幂等(非事务)生产者走 `requestIdempotentEpochBumpForPartition` 本地 bump epoch 后重试;事务生产者不重试,转为 abortable error(TransactionManager.java:1089-1105)。
- `UNKNOWN_PRODUCER_ID`(broker 丢了 producer state):利用响应里的 `logStartOffset` 区分"日志头部被 retention 删除"(可以 `startSequencesAtBeginning` 从 0 重发,TransactionManager.java:1070-1081)与"数据真的丢了"(事务生产者 abortable/fatal)。这是客户端代码里和 **LSO/log start offset** 交互最直接的地方。
- **未决序列(unresolved)**:批本地超期(delivery timeout)但它可能已到达 broker,`(sequence, epoch)` 的最终状态未知 → `markSequenceUnresolved` 记录"下一个应出现的 sequence"(TransactionManager.java:868-874),期间 `shouldStopDrainBatchesForPartition` 禁止向该分区发新批(RecordAccumulator.java:958-963)。所有在途请求落定后,`maybeResolveSequences` 收口:若后续批成功(序列衔接上了)则解除;否则幂等生产者 bump epoch 重来、事务生产者转 abortable error(TransactionManager.java:878-911)。
- 幂等 epoch bump 采取**客户端本地 bump**(`bumpIdempotentProducerEpoch`,epoch 到 Short.MAX_VALUE 才 reset pid 重新 InitProducerId,TransactionManager.java:646-689),并在 Sender.runOnce 开头 `bumpIdempotentEpochAndResetIdIfNeeded` 驱动(TransactionManager.java:691-705)。bump 后 `startSequencesAtBeginning` 会**重写所有在途批的 header sequence**(ProducerBatch.resetProducerState → `reopenAndRewriteProducerState`,TxnPartitionEntry.java:116-125;ProducerBatch.java:524-529)。

> 关于"POCH":在当前代码库 clients 侧**不存在**名为 POCH 的机制(全仓 grep 无命中)。与"epoch/序列决断"相关职责由上述 per-partition `TxnPartitionEntry` + unresolved-sequence + epoch bump 三件套承担,推测问题所指即这一组机制。

### 4.2 事务状态机

状态集合与合法迁移(TransactionManager.java:157-195):

```
UNINITIALIZED → INITIALIZING → READY → IN_TRANSACTION → COMMITTING_TRANSACTION ─┐
                     ▲           │  │           └→ PREPARED_TRANSACTION ────────┤→ READY
                     │           │  └→ ABORTING_TRANSACTION ────────────────────┘
                     │           └→ PREPARED_TRANSACTION (2PC)
        COMMITTING/ABORTING → INITIALIZING;ABORTABLE_ERROR ⇄ ABORTING
        FATAL_ERROR:任何状态可达、不可恢复
```

- `initTransactions()` → `initializeTransactions`:入队 `InitProducerIdHandler`(优先级队列,FIND_COORDINATOR(0) < INIT_PRODUCER_ID(1) < ADD_PARTITIONS_OR_OFFSETS(2) < END_TXN(3) < EPOCH_BUMP(4),TransactionManager.java:201-213),成功后 `setProducerIdAndEpoch + transitionTo(READY)`(TransactionManager.java:321-356、1549-1596)。2PC 的 `initTransactions(true)` 带 `keepPreparedTxn`,broker 在响应里回传 `ongoingTxnProducerId/Epoch`,客户端直接进入 `PREPARED_TRANSACTION` 保留在途事务(TransactionManager.java:1557-1568)。
- `beginTransaction()` 纯状态迁移,不发请求(TransactionManager.java:358-363)。
- **AddPartitions**:发消息成功 append 后 `maybeAddPartition`(KafkaProducer.java:1237-1239;TransactionManager.java:465-488)——注释解释了为什么必须在 append 之后(分区可能是 UNKNOWN,且 Sender 在分区入事务前拒绝出队批,RecordAccumulator.java:1235-1236 注释)。TV1 下新分区进 `newPartitionsInTransaction`,由 `nextRequest` 在队头转 `AddPartitionsToTxnHandler`;TV2 下**跳过该请求**,直接记入 `partitionsInTransaction`(TransactionManager.java:476-479,445 注释)。
- **sendOffsetsToTransaction**:TV1 走 `AddOffsetsToTxn → TxnOffsetCommit` 两跳;TV2 直接 TxnOffsetCommit(TransactionManager.java:432-463)。KafkaProducer 侧会先做**部分元数据刷新**保证 topicId 可用(KafkaProducer.java:841-859)。
- **EndTxn**:commit/abort 都走 `beginCompletingTransaction`(TransactionManager.java:401-430):先补发 AddPartitions(如有),再入队 `EndTxnHandler`,并调用 `maybeUpdateTransactionV2Enabled` 固定本次事务的协议版本。`nextRequest` 保证 EndTxn 只有在 accumulator 没有未完成批次时才出队(`hasIncompleteBatches`),空事务则不发送直接 done(TransactionManager.java:930-954)——这就是 `commitTransaction()` 语义上先 flush 的实现方式。
- **pendingTransition 缓存**:状态迁移型调用(initWith/commit/abort)经 `handleCachedTransactionRequestResult` 包装,`max.block.ms` 超时后再调用同种操作会拿到同一 result 幂等续等,不同操作则抛 IllegalStateException(TransactionManager.java:1319-1341;KafkaProducer.java:915-921 的超时语义注释)。
- **请求生命周期与重试**:每个 handler 在 `onComplete` 里对断连做 `lookupCoordinator + reenqueue`,可重试错误 reenqueue,认证/授权失败按 abortable/fatal 分流(TransactionManager.java:1463-1486)。AddPartitionsToTxn 对 `CONCURRENT_TRANSACTIONS` 有个特殊处理:若本事务还没有任何分区成功加入,把退避压到 20ms(`ADD_PARTITIONS_RETRY_BACKOFF_MS`)以快速重试,注释说明这是对 KAFKA-5482 的临时补丁(TransactionManager.java:1697-1706、140)。
- 错误分类:`maybeTransitionToErrorState` 把 `ClusterAuthorization/TransactionalIdAuthorization/ProducerFenced/UnsupportedVersion/InvalidPidMapping` 定为 fatal;事务生产者的 `RetriableException`(重试耗尽后)与 `InvalidTxnStateException` 包成 `TransactionAbortableException` 转 abortable(TransactionManager.java:792-814)。abortable 与 fatal 的分界是"能否通过 epoch bump 恢复":`canHandleAbortableError = coordinatorSupportsBumpingEpoch || isTransactionV2Enabled`(TransactionManager.java:1384-1386)。
- 请求严格串行:`TxnRequestHandler.onComplete` 校验 correlationId,发现超过一个在途事务请求直接 fatal(TransactionManager.java:1463-1467);Sender 侧 `maybeSendAndPollTransactionalRequest` 同一时间只发一个 txn 请求(Sender.java:460-519)。

### 4.3 两阶段提交(2PC,KIP-939 扩展)

`prepareTransaction()` 先 `flush()` 再迁移到 `PREPARED_TRANSACTION`,返回 `(producerId, epoch)` 作为 PreparedTxnState 令牌(KafkaProducer.java:889-902;TransactionManager.java:370-379)。此后 `throwIfInPreparedState` 拦截一切 send/begin(KafkaProducer.java:1161-1169),只允许 `commitTransaction/abortTransaction/completeTransaction`。`completeTransaction` 比对令牌一致则 commit、不一致则 abort——支持外部事务管理器跨进程/跨实例裁决(KafkaProducer.java:994-1014)。构造事务生产者时 `transaction.two.phase.commit.enable=true` 才可用(KafkaProducer.java:893-895)。

2PC 设计的关键洞察是:**把"是否提交"的决定权从生产进程剥离**。令牌 `(pid, epoch)` 由 broker 签发、进程无关,因此崩溃后用 `initTransactions(true)` 重入的进程能拿到同一份 `preparedTxnState`(经由 InitProducerId 响应中的 `ongoingTxnProducerId/Epoch`,TransactionManager.java:1557-1568),再与外部系统给出的令牌比对即可恢复到一致决策。这本质上把 Kafka 事务嵌入了任意 XA 风格的协调流程,而不需要 broker 实现 prepare 日志——prepare 状态只存在于客户端视角,broker 看到的仍是普通 IN_TRANSACTION。

### 4.4 Sender 侧的事务纪律回看

回到生产主路径,事务对 Sender 的约束可以总结为四道闸门(`shouldStopDrainBatchesForPartition` 与 `runOnce`):① fatal error 时 runOnce 直接放弃发送并 abort 全部未完成批次(Sender.java:316-323、533-539);② abortable error 时先 `abortUndrainedBatches` 再走完 EndTxn 流程(Sender.java:467-471);③ `isSendToPartitionAllowed`:分区必须已在 `partitionsInTransaction`(TransactionManager.java:494-498);④ `hasUnresolvedSequence` 与 stale epoch 检查(RecordAccumulator.java:951-963)。四道闸门合起来保证:**任何未登记进事务的字节,永远不可能越过 accumulator 到达网络**——这是事务原子性在客户端侧的守门人。

---

## ⑤ 设计动机与取舍

1. **为什么"用户线程做序列化/分区、IO 线程做网络"?** 序列化与 murmur2 计算是 CPU 密集的 O(n) 工作且与消息量线性相关,放用户线程天然并行、不占 IO 线程;IO 线程只碰字节缓冲。代价是拦截器/自定义分区器异常会直接打到业务线程(doSend 的 catch 链,KafkaProducer.java:1249-1274)。
2. **为什么锁粒度是分区 Deque 而不是全局?** `partitionReady` 的注释明说该循环在大分区数下极热,必须避免增加与 `send()` 线程的同步、只做最少的事(Sender 侧 KAFKA-16226,RecordAccumulator.java:801-808)。CopyOnWriteMap + volatile sticky 引用让无冲突路径完全无锁。
3. **为什么 sticky batching?** 旧 round-robin 会把无 key 消息打散到所有分区,每分区批都半满,请求放大 N 倍;sticky 让一段时间内流量集中到一个分区,`batch.size` 才真正吃得满。切换时机与"队列全满"对齐以消除尾巴批,并把 producedBytes 上限钳到 2×batchSize 防止病态滞留(BuiltInPartitioner.java:229-258)。
4. **BufferPool 为什么只回收整块?** 分配/回收 O(1)、避免碎片;非整块(压缩膨胀、超大单条)直接折算成可用字节。公平 FIFO 等待是防止"大消息永远拿不到内存"。
5. **为什么 `max.in.flight=1` 用 mute 而幂等模式下可以 >1?** mute 是"无幂等时保证顺序"的粗手段;幂等后 broker 能按 sequence 重排,客户端只需在**重试发生时**退化排队(`shouldStopDrainBatchesForPartition` 的 `firstInFlightSequence` 逻辑,RecordAccumulator.java:965-971),以及用 `insertInSequenceOrder` 保证重入队后的 sequence 有序(RecordAccumulator.java:659-699)。
6. **为什么分区要在 accumulator 里"再定一次"?** key 有 hash 分区、无 key 用 sticky;sticky 状态由多线程共享,只能延迟到拿到分区锁后才能安全决策(KafkaProducer.java:1214-1217 注释)。
7. **事务为什么不复用普通 send 队列?** 事务请求(FindCoordinator/InitProducerId/AddPartitions/EndTxn)必须与 produce 严格有序交互,用独立优先级队列 + 单在途请求 + correlationId 校验换取可推理的正确性;代价是吞吐上不去——事务路径本来就为低频提交设计。
8. **TSV2/2PC 的演进方向**:TV2 把 epoch bump 移到 EndTxn 内部做(TransactionManager.java:1810-1818),消除客户端与服务端的 bump 协调;chunked accumulator 把 `buffer.memory` 从"按峰值预留"改为"按用量增长"——都是把复杂度下沉/按需化的统一思路。
9. **构造器为什么在 try 里包 close(0)?** 构造链中任何一环失败(metadata 引导、NetworkClient 建立、Sender 线程启动)都会走到 `catch (Throwable)` 里调用 `close(Duration.ZERO, swallowException=true)`,把已经建好的插件、metrics、JMX 注册等逐个关闭再重抛 `KafkaException`,对应注释里的 KAFKA-2121 反泄漏修复(KafkaProducer.java:522-527、1647-1654)。

---

## ⑥ FAQ

1. **Q: `send()` 什么时候会阻塞?** A:两类:首次遇到某 topic 需要拉元数据(`waitOnMetadata`,≤ `max.block.ms`),以及 `BufferPool.allocate` 内存不足时排队等释放(KafkaProducer.java:1031-1034 注释;BufferPool.java:172-196)。分区计算、序列化是纯 CPU 不阻塞。
2. **Q: `linger.ms=0` 还会批量化吗?** A:会。满批(`deque.size()>1 || batch.isFull()`)立即 ready,高并发下批天然聚起来;`linger.ms` 只影响"半满批"再等多久(RecordAccumulator.java:718-726;KafkaProducer.java:155-157 注释)。
3. **Q: `batch.size` 与 `buffer.memory` 谁先触发背压?** A:两者独立。单批 `batch.size`(可被大消息动态放大);池总上限 `buffer.memory` 决定并发批总量,耗尽则用户线程阻塞,超时抛 `BufferExhaustedException`(BufferPool.java:248-252)。
4. **Q: callback 在哪条线程执行?能做重活吗?** A:在 IO 线程(ProducerBatch.completeFutureAndFireCallbacks 由 Sender 调用);文档明确要求快速或在回调内自建线程池,否则拖慢所有分区投递(KafkaProducer.java:1123-1126)。
5. **Q: `flush()` 和 `commitTransaction()` 什么关系?** A:事务内不需要手动 flush:EndTxn 请求在 accumulator 完全 drained 前不会出队(nextRequest 的 isEndTxn 检查),语义等价于内置 flush(TransactionManager.java:930-932)。
6. **Q: `enable.idempotence=false` 现在还有意义吗?** A:关掉后 TransactionManager 为 null(KafkaProducer.java:658-683),Sender 不再赋 sequence(RecordAccumulator.java:1027 的 null 分支)、batch 靠 `max.in.flight=1 + mute` 保序,吞吐略高但可能重复。
7. **Q: 看到 `OutOfOrderSequenceException` 该怎么办?** A:事务生产者:不可恢复,close 重建;幂等生产者:客户端通常已自动 bump epoch 重试,若异常外抛应 close 重建以保证后续顺序(KafkaProducer.java:1099-1115 的错误处理说明)。
8. **Q: 事务超时(`transaction.timeout.ms`)谁负责?** A:broker 侧 coordinator 超时会 abort 事务;客户端 `commitTransaction` 的 `max.block.ms` 超时**不代表**提交失败,请求可能已到达——只能重试同一操作,不能改 abort(KafkaProducer.java:915-921)。
9. **Q: 为什么分区的第一条消息延迟明显?** A:sticky 首选分区 + 元数据冷启动两个因素叠加;`partitionsFor()` 预热可消掉元数据等待,但 `metadata.max.idle.ms` 空闲后缓存会被清(KafkaProducer.java:1035-1039)。
10. **Q: chunked(incremental)策略现在能用了吗?** A:实验性。要求 `batch.size ≥ 16KB` 且 `compression.type=none`,否则构造期报错或回退 full 策略(KafkaProducer.java:465-483)。

---

## ⑦ 深挖问题(供后续章节展开)

1. **ChunkedRecordAccumulator 的扩展路径与压缩的关系**:`needsBufferExtension` 结果(RecordAccumulator.java:1426-1441)目前只在 incremental 路径出现;一旦 KAFKA-20579 落地支持压缩,中段扩展如何与 `MemoryRecordsBuilder` 的压缩缓冲交互?`estimateSizeInBytesUpperBound` 的上界在压缩场景还准吗?
2. **unresolved-sequence 与 broker 端 LSO 的耦合**:`partitionsWithUnresolvedSequences` 阻塞该分区新批 drain(RecordAccumulator.java:958-963),但已入事务的分区会拉低 broker LSO,可能放大下游 `read_committed` 消费者的可见性延迟。值得在事务章节量化"一条批超期对整个事务 LSO 的影响窗口"。
3. **sticky 分区与机架感知的统计时效性**:`partitionLoadStatsHolder` 由 Sender 每次 `ready()` 更新、用户线程每次 `nextPartition` 消费,存在跨线程的陈旧窗口(BuiltInPartitioner.java:47)。大分区数 + 快速 leader 切换场景下,加权表过期是否会造成倾斜?
4. **TV2 升级窗口的正确性**:升级瞬间 `clientSideEpochBumpRequired` 的处理(TransactionManager.java:418-427、520-532)依赖 EndTxn 请求构建与发送之间的原子性;若 EndTxn 用 v11 发出后 finalized feature 生效,下一事务立即 TV2,序列重置由谁保证?注释提到这是用 bump epoch 规避的边缘场景(425-431 行注释)。
5. **KAFKA-19012 的缓冲生命周期**:in-flight 批本地超期时"不释放、等响应释放"(Sender.java:854-863、RecordAccumulator.java:1170-1176),若连接长期挂起且响应永不回来,内存会滞留多久?与 `connections.max.idle.ms`、`delivery.timeout.ms` 的相互作用值得实测。

---

### 附:本次调研覆盖文件

- `clients/src/main/java/org/apache/kafka/clients/producer/KafkaProducer.java`
- `.../producer/internals/RecordAccumulator.java`、`Sender.java`、`TransactionManager.java`
- `.../producer/internals/BufferPool.java`、`ProducerBatch.java`、`BuiltInPartitioner.java`、`TxnPartitionEntry.java`、`ProducerInterceptors.java`、`ChunkedRecordAccumulator.java`(概览)
- `.../common/record/internal/RecordBatch.java`、`DefaultRecordBatch.java`(头部布局)
- `.../common/requests/ProduceRequest.java`、`common/message/ProduceRequest.json`(协议版本)
