# Kafka 源码深读 · Broker 日志存储与副本管理(storage/internals/log 与 core)

> 基于 Kafka 4.5.0-SNAPSHOT(commit f6149f1c,2026-09-05)。所有结论均标注 `文件:行号`。
> 注意:4.x 起 Kafka 完成了 "core Scala → storage Java 模块" 的搬迁,UnifiedLog/LogSegment 等已位于
> `storage/src/main/java/org/apache/kafka/storage/internals/log/`,core 中只保留 ReplicaManager、Partition、KafkaApis 等胶水层。

---

## ① 全景:日志即一切(Log is Everything)

Kafka 的存储哲学可以浓缩成一句话:**把所有数据问题都规约成"对同一个只追加字节序列(append-only log)的多视角读写"**。生产者是往日志尾部追加,消费者是按 offset 顺序读,副本同步是 follower 拉取日志尾部,流式处理/连接器是消费日志的再加工。因此 broker 端几乎不存在"存储引擎"的选择问题——没有 B-tree、没有页缓存管理,只有一个精心设计的文件布局加操作系统的 page cache。

代码结构对应关系:

- `UnifiedLog`(storage/.../log/UnifiedLog.java:105):一个分区的逻辑日志,统一管理本地段(local)与远程分层段(tiered)。类注释明确:"tiered 段在日志开头,可选重叠区之后是 local 段,active segment 恒为 local"(UnifiedLog.java:95-104)。
- `LocalLog`(LocalLog.java):本地段容器 + 日志级可变状态(LEO、recoveryPoint、flush)。
- `LogSegment` / `LogSegments` / `OffsetIndex` / `TimeIndex` / `TransactionIndex`:物理文件层。
- `ReplicaManager`(core/.../server/ReplicaManager.scala:154)+ `Partition`(core/.../cluster/Partition.scala):把"一份本地日志"升级为"一个多副本、有 leader/ISR/高水位语义的复制分区"。
- KRaft 的元数据日志同样复用 `UnifiedLog`:`raft/.../internals/KafkaRaftLog.java:79-84` 中 `KafkaRaftLog implements RaftLog` 内部直接持有一个 `UnifiedLog`,构建时调 `UnifiedLog.create(...)`(KafkaRaftLog.java:712-726),只是把 time/byte 保留策略设为 -1 关闭(KafkaRaftLog.java:696-698)。这就是"元数据日志与数据日志是同一套引擎"的直接证据。

理解这套代码有三个前提。第一,**模块分层**:UnifiedLog 及其以下"不知道副本的存在"——它只负责把字节按 offset 写进文件、按 offset 读出来;副本、ISR、高水位这些"多机语义"全部上移到 Partition/ReplicaManager。这条分界线在 4.x 的模块搬迁中被制度化:storage 模块不依赖 core,因此同一份日志代码可以被 broker 的数据分区和 KRaft 控制器的元数据分区共用。第二,**offset 是唯一的一等键**:offset 既决定文件名(段 base offset)、索引键(相对 offset)、恢复点(recovery point),也充当复制协议中的进度指针(follower 的 fetch offset)和一致性边界(HW/LSO 都是 offset),整份代码里几乎不存在第二种全局标识。第三,**锁的层级**:进程级有 LogManager 的目录级锁,分区级有 `Partition.leaderIsrUpdateLock`(读写锁,保护 leader/ISR 状态),日志级有 `UnifiedLog.lock`(保护段集合与 LEO 的所有变更,UnifiedLog.java:123),段与索引内部各自有锁(AbstractIndex.java:59-61)。追加路径依次穿过这三层,读路径则尽量只碰无锁或读锁部分,这是理解后面每一处"为什么在这里加锁"的钥匙。

---

## ② 物理结构:segment、稀疏索引与 mmap

### 2.1 目录与文件布局

每个分区对应一个目录 `topic-partition`(LocalLog.java:740 `logDirName`),目录内按 segment 分文件。segment 的 javadoc 写得很直白:base offset 为 N 的段对应 `N.log` 与 `N.index` 两个文件(LogSegment.java:56-62)。文件名由 `filenamePrefixFromOffset` 生成(固定 20 位、零填充,保证字典序 == offset 序,LogFileUtils.java:102),后缀规则见 LogFileUtils.java:127/149(及 UnifiedLog.java:109-116 的常量)。

```text
my-topic-0/
├── 00000000000000000000.index        # offset 稀疏索引(4+4 字节/条)
├── 00000000000000000000.log          # FileRecords:消息批次顺序写
├── 00000000000000000000.timeindex    # 时间索引(8+4 字节/条)
├── 00000000000000000000.txnindex     # 事务索引(仅 aborted txn)
├── 00000000000000000036.log          # 下一段:文件名 = 该段 base offset
├── 00000000000000000036.index
├── ...
├── leader-epoch-checkpoint           # LeaderEpochFileCache 落盘文件
├── partition.metadata                # topic id(UnifiedLog.java:1126 flush 时机)
├── producerid-0000000000.snapshot    # ProducerStateManager 快照(LogFileUtils.java:92)
├── recovery-point-offset-checkpoint  # 恢复点(LogManager.java:85)
└── log-start-offset-checkpoint       # 日志起点(LogManager.java:86)
```

### 2.2 稀疏索引写入规则(核心机制)

`LogSegment` 持有 `bytesSinceLastIndexEntry` 计数器(LogSegment.java:103)。追加时的规则在 `LogSegment.append`(LogSegment.java:251-281):先把批次写入 `.log`(行 261),然后**只有当距离上一个索引条目累计的字节数超过 `index.interval.bytes` 时,才同时追加一条 offset 索引与一条 time 索引**(LogSegment.java:271-275):

```java
if (bytesSinceLastIndexEntry > indexIntervalBytes) {
    offsetIndex().append(batchLastOffset, physicalPosition);
    timeIndex().maybeAppend(maxTimestampSoFar(), shallowOffsetOfMaxTimestampSoFar());
    bytesSinceLastIndexEntry = 0;
}
```

也就是说:索引条目以**批**(batch)为粒度、以字节间隔为触发条件,`.index` 记录 `(lastOffset → 物理文件位置)`,`.timeindex` 记录 `(maxTimestampSoFar → 该最大时间戳批的 lastOffset)`。崩溃恢复时 `LogSegment.recover` 用完全相同的间隔规则重建两个索引(LogSegment.java:501-505),并把尾部无法通过 CRC 校验的字节截掉(LogSegment.java:519-523)。

`TimeIndex.maybeAppend` 还有额外约束:时间戳和 offset 都必须单调不减,时间戳不大于最后条目时直接忽略(LogTimeIndex.java:193-198、203);条目为 12 字节(`putLong(timestamp)` + `putInt(relativeOffset)`,TimeIndex.java:205-207)。而 `OffsetIndex` 每条 8 字节:4 字节 **相对 offset**(`offset - baseOffset`,int 即可,溢出由 `canConvertToRelativeOffset` 检查并触发 roll,LogSegment.java:237-239/168-174)+ 4 字节物理位置(OffsetIndex.java:150-151,读回时 `baseOffset() + relativeOffset`,OffsetIndex.java:199-201)。

### 2.3 mmap 与"热段"

所有索引文件通过 `MappedByteBuffer` mmap 进内存,读写都走 OS page cache(AbstractIndex.java:100-124、345-352)。`AbstractIndex` 用两把锁:普通写锁串行化变更,`remapLock`(读写锁)保证 remap(索引增长需重映射)期间读的可见性(AbstractIndex.java:59-61)。索引文件预分配、按需 remap/resize(AbstractIndex.java:200-227)。

一段非常值得细读的注释(AbstractIndex.java:354-373)解释了为什么 Kafka 为索引搜索定制了"缓存友好二分"(warm binary search):标准二分查找在索引只增长在尾部、查询集中在尾部的访问模式下,会反复冷读中间页导致 page fault,实测可让 produce 延迟从几毫秒跳到 1 秒量级;因此查找实现优先走尾部热页。这解释了"热段"概念:active segment 的索引几乎全部命中 page cache。

`LogSegments` 用 `ConcurrentSkipListMap<Long, LogSegment>` 保存段(LogSegments.java:42),提供 `floorSegment`(找到 baseOffset ≤ 目标 offset 的段,LogSegments.java:220)、`higherSegment` 等导航方法——这就是读取路径二段定位的第一跳。

还有三类"伴随文件"值得交代。**事务索引**(`*.txnindex`):每个段一个,只记录本段内 **aborted** 的事务区间(`AbortedTxn`:producerId/firstOffset/lastOffset/lastStableOffset,LogSegment.java:349-358),消费者以 read_committed 抓取时用它过滤掉已 abort 的数据;它不是 mmap 结构,而是追加 JSON 行的简单文件。**Producer 快照**(`*.snapshot`):ProducerStateManager 在段 roll 时为每个 active segment base offset 打一份幂等生产者状态快照(LogFileUtils.java:92、UnifiedLog.java:2217-2226),恢复时从最近快照开始重放,避免全量扫日志重建幂等序号。**Leader epoch checkpoint**:承载 4.2 节的 epoch→offset 表。三者共同构成"日志数据 + 各维元数据"的完整恢复单元,也是 Kafka 崩溃恢复快于通用 WAL 系统的原因——每类状态都有与日志对齐的落盘检查点,恢复时无需从头推导。

---

## ③ 追加与读取路径

### 3.1 追加路径:appendAsLeader → append

入口分两条:`appendAsLeader`(leader 侧,需要分配 offset,UnifiedLog.java:1049-1058)与 `appendAsFollower`(follower 侧复用 leader 已分配的 offset,`validateAndAssignOffsets=false`,UnifiedLog.java:1080-1090)。核心方法 `append`(UnifiedLog.java:1115-1292)按顺序做七件事:

1. **先落 partition.metadata**:确保崩溃后 topic id 可恢复(UnifiedLog.java:1124-1126)。
2. **analyzeAndValidateRecords**(UnifiedLog.java:1128,方法体 1489-1592):逐批检查——RAFT_LEADER 追加时批内 leaderEpoch 必须一致(1506-1509);offset 单调(1541);批大小 ≤ `max.message.bytes`(1551);CRC 校验(1559-1562)。特别地,KAFKA-18723 修复:复制来源(REPLICATION)的批若其 partitionLeaderEpoch **高于**本副本当前 epoch(失去 leader 后延迟到达的 FETCH 响应),则跳过该批及后续所有批(1516-1524,判定函数 1603-1607)。`requireOffsetsMonotonic` 只对 follower/复制路径强制(1577-1583)。
3. **trimInvalidBytes** 截掉尾部残缺批次(UnifiedLog.java:1135,1616-1630)。
4. leader 路径由 `LogValidator` 分配 offset:非压缩路径对每条 record 递增 `offsetCounter`,批尾 `setLastOffset(offsetCounter.value - 1)` 并 `setPartitionLeaderEpoch`(LogValidator.java:226-246);压缩/格式转换路径需整批重写,判定条件见 LogValidator.java:272-277。
5. **epoch 缓存登记**:v2+ 批的 `partitionLeaderEpoch` 变化时 `assignEpochStartOffset`(UnifiedLog.java:1213-1225)。
6. **maybeRoll**:三个 roll 条件——段满(`size > segment.bytes - 本次写入`)、超过 `segment.ms`(带 jitter)、索引满或相对 offset 溢出,汇总在 `LogSegment.shouldRoll`(LogSegment.java:168-174;调用点 UnifiedLog.java:2164)。roll 时给 ProducerStateManager 打快照、异步 flush 旧段(UnifiedLog.java:2212-2235);`LocalLog.roll` 还处理同名空 active 段的 KAFKA-6388 边界(LocalLog.java:593-615)。
7. **幂等/事务校验 + 真正落盘**:`analyzeAndValidateProducerState` 检出重复批则直接返回原 offset 元数据(UnifiedLog.java:1243-1254);否则 `localLog.append(lastOffset, validRecords)` 写入 active 段并立即推进 LEO(UnifiedLog.java:1262-1263 → LocalLog.java:527-530),再更新 producer 状态、写事务索引(仅 aborted txn,LogSegment.java:349-358)、推进 firstUnstableOffset(UnifiedLog.java:1266-1281)。fsync 是异步/攒批的:`unflushedMessages >= flushInterval` 才 flush(1286)。

### 3.2 读取路径:fetch → readFromLog → UnifiedLog.read → LogSegment.read

Fetch 请求进入 `ReplicaManager.fetchMessages`(ReplicaManager.scala:1665-1748):先同步 `readFromLog` 试读一次,若"不需要等待(maxWaitMs≤0)/ 不需要数据 / 已读到 minBytes / 出错 / 发现 diverging epoch / 指定了 preferred read replica"任一成立则立即响应(ReplicaManager.scala:1705-1706);否则构造 `DelayedFetch` 放入 purgatory 等 HW/LEO 推进后补读(1728-1745)。

`readFromLog`(ReplicaManager.scala:1753-1893)有两个关键细节:

- **字节预算分配**:`limitBytes` 从 `fetch.max.bytes` 开始,逐分区扣减;第一个非空分区返回前 `minOneMessage=true`(保证至少一条完整批),之后才恢复分区级 `max.bytes` 限制(ReplicaManager.scala:1876-1891)。
- ** follower 限流与残缺首批**:follower 抓取被 quota 限流、或首条批不完整(`firstEntryIncomplete`)时,统一替换成空记录集,让 follower 下次重试(ReplicaManager.scala:1760-1771)。

真正的定位由 `UnifiedLog.read`(UnifiedLog.java:1649-1660)完成:先 `checkLogStartOffset`(1632-1637),按 `FetchIsolation` 选读上限——`LOG_END`(follower 用)、`HIGH_WATERMARK`、`TXN_COMMITTED`(LSO,read_committed 消费者用,1654-1658)。然后 `LocalLog.read`(LocalLog.java:463-525)执行两段式定位:

1. `segments.floorSegment(startOffset)` 找目标段(LocalLog.java:477);
2. `LogSegment.read`(LogSegment.java:436-464):`translateOffset` = 先 `offsetIndex().lookup(offset)` 二分找到 ≤ 目标 offset 的最大条目,再从该物理位置线性扫描定位到确切批(LogSegment.java:399-402);`fetchSize = min(maxPosition - startPosition, adjustedMaxSize)`,其中 maxPosition 被隔离级别对应的 maxOffsetMetadata 截住(LocalLog.java:494-504),`minOneMessage` 时把 maxSize 抬高到首批大小(449-451);最后 `log.slice(startPosition, fetchSize)` 返回零拷贝视图(LogSegment.java:460-463)。若段尾没数据则用 `higherSegment` 跳到下一段循环(LocalLog.java:512)。

返回值 `FetchDataInfo` 携带 `(fetchOffsetMetadata, records, firstEntryIncomplete, abortedTransactions, delayedRemoteStorageFetch)`(FetchDataInfo.java:26-31)——read_committed 路径还会顺带收集 txnindex 中的 aborted 列表(LocalLog.java:532-553)。

几个容易忽略的边界行为,恰好体现了读路径的健壮性设计。其一,`startOffset == maxOffset` 或 `startOffset > maxOffset` 时直接返回空结果而非报错(LocalLog.java:483-484),后者会先做一次单字节 read 把 offset 换算成带段内位置的元数据再返回,因此消费者不会因"恰好追平"而收到异常。其二,若 floorSegment 里目标 offset 之前的消息已被清理(logStartOffset 推进到段中间),`translateOffset` 返回 null,循环跳到下一段;当所有段都无数据时返回空集合并附 LEO 元数据(LocalLog.java:515-522),而不是抛 OffsetOutOfRange——只有 startOffset 越过 LEO 或低于 logStartOffset 才报错(LocalLog.java:479-481、UnifiedLog.java:1632-1637)。其三,follower 抓取是"尽力而为"的对齐:follower 请求的 offset 可能不在批边界(比如按字节数截断的响应残端),`firstEntryIncomplete` 标记让 leader 返回空集,follower 下次按完整批重新请求(ReplicaManager.scala:1764-1767)。

---

## ④ HW 与 Leader Epoch:一致性机制

### 4.1 三个水位与两个 offset 语义

- **LEO**(log end offset):下一条待写 offset,append 后立即推进(LocalLog.java:529)。
- **HW**(high watermark):ISR 中最小 LEO,消费者只能读到 HW 之前。leader 用 `maybeIncrementHighWatermark`:只允许单调前进,且新值必须 ≤ LEO(UnifiedLog.java:563-581);follower 用 `maybeUpdateHighWatermark`,允许夹在 `[logStartOffset, LEO]` 区间内回填(UnifiedLog.java:542-552)。HW 更新会联动 producer 状态(清理点)与 listener(UnifiedLog.java:621-636)。
- **LSO**(last stable offset):`min(HW, firstUnstableOffset)`,read_committed 的读边界(UnifiedLog.java:648-676)。
- **logStartOffset**:对外可见的最小 offset,受"不得越过 HW"约束(UnifiedLog.java:155-160 注释)。

leader 侧 HW 推进入口在 `Partition.maybeIncrementLeaderHW`(Partition.scala:1010-1053):取 maximalIsr(已提交 ISR ∪ 正在加入的副本,KIP-497)内所有副本 LEO 的最小值,且对"已 caught-up 但尚未进 ISR"的副本也等待(Partition.scala:1022-1031),避免 follower 的 LEO 永远追不上 HW。副本 LEO 来自 follower fetch:`updateFollowerFetchState` 记录抓取位置后依次触发 `maybeExpandIsr` 与 `maybeIncrementLeaderHW`(Partition.scala:767-817)。

值得展开的是 HW 与 LEO 在两个路径上的不对称更新。leader 侧:本地 append 完成后 LEO 立即前移,但 HW 不动——它要等 DelayedProduce 中 `checkEnoughReplicasReachOffset` 的下一次 tryComplete 或下一次 follower fetch 推进(Partition.scala:1010-1053),因此 HW 的前进节奏由"最慢的 ISR 副本"决定。follower 侧:每次 fetch 成功会先推进 LEO(`updateLogEndOffset`,LocalLog.java:529),随后用响应里 leader 带回的 HW 更新本地副本的 HW(`maybeUpdateHighWatermark`,允许 HW ≤ LEO 的任意回填,UnifiedLog.java:592-600);follower 的 HW 仅用于其自身升级为 leader 后确定消费者可见位置与截断下界。这条"leader 定 HW、follower 追 HW"的单向流动保证了:任何时刻,所有副本上 HW 之前的数据都已在至少 min.isr 个副本上持久,消费者读到的每个字节都不会因为选举而消失——这正是 HW 不允许回退(unifiedLog.java:627-628 只警告不拒绝)背后的完整逻辑。

### 4.2 LeaderEpochFileCache:offset 区间与 epoch 的双向映射

`leader-epoch-checkpoint` 文件由 `LeaderEpochFileCache` 管理:内部 `TreeMap<epoch, EpochEntry(epoch, startOffset)>`(LeaderEpochFileCache.java:60)。`assign` 保证 epoch 单调,新的更小 startOffset 会触发移除冲突条目(LeaderEpochFileCache.java:124-162)。两个关键读写方向:

- **写方向**:每次 leader 变更,`Partition.makeLeader` 以当前 LEO 登记新 epoch 的起始 offset(Partition.scala:635-649);每次 append 中批次 epoch 变化也登记(UnifiedLog.java:1213-1215);段恢复时重建(LogSegment.java:508-511)。
- **读方向**:`endOffsetFor(requestedEpoch, LEO)` 返回"该 epoch 的截止 offset = 下一个 epoch 的 startOffset"(LeaderEpochFileCache.java:284-328)。这是 fencing 与截断的核心:请求 epoch == 最新 epoch 时返回当前 LEO(292-297)。

### 4.3 Fencing 的三层防线

1. **fetch 带 currentLeaderEpoch**:`Partition.localLogWithEpochOrThrow` 比较——请求 epoch 小于当前 epoch 抛 `FencedLeaderEpochException`(老 leader 的残留请求被拒),大于则抛 `UnknownLeaderEpochException`(分区归属校验,Partition.scala:369-382、426-438)。
2. **follower 增量截断**:follower 在 fetch 请求中携带 `lastFetchedEpoch`,leader 用 `endOffsetFor` 对比;若 `epochEndOffset.endOffset < fetchOffset` 或 epoch 更老,说明 follower 日志有分叉,返回 `divergingEpoch`,follower 收到后按 (epoch, endOffset) 截断再重新拉取(Partition.scala:1383-1413,结果封装于 LogReadInfo)。
3. **复制路径 epoch 校验**:过期副本带着高 epoch 的数据来 append 时被跳过(UnifiedLog.java:1516-1524,见 3.1 第 2 步)。

leader 本地截断(如 becoming follower 后)由 `UnifiedLog.truncateTo` 完成:截断后同步 `leaderEpochCache.truncateFromEndAsyncFlush` 清掉尾部 epoch 条目、重建 producer 状态、必要时回落 HW(UnifiedLog.java:2348-2390)。epoch checkpoint 的截断走异步 fsync,注释明确是为避免 ReplicaFetcher 线程被高 fsync 延迟卡住(LeaderEpochFileCache.java:335-355)。

---

## ⑤ 副本同步与 leader 变更流程(ReplicaManager)

### 5.1 DelayedProduce 与 Purgatory 概览

ReplicaManager 持有多个 `DelayedOperationPurgatory`(ReplicaManager.scala:184-208):Produce/Fetch/DeleteRecords/RemoteFetch/RemoteListOffsets/ShareFetch。Purgatory 的通用模式是 `tryCompleteElseWatch`:先试完成一次,不满足则挂到各分区 key 上监听,后续任何 HW/LEO 变化都会 `checkAndComplete` 唤醒。

Produce 路径(`appendRecords`,ReplicaManager.scala:638-678):

1. `appendToLocalLog` 逐分区同步写本地日志(入口 `partition.appendRecordsToLeader`,其中先做 min.isr 检查——ISR 数 < min.isr 且 acks=-1 直接抛 `NotEnoughReplicasException`,Partition.scala:1227-1243;再 `leaderLog.appendAsLeader`,ReplicaManager.scala:1415)。
2. `maybeAddDelayedProduce`(ReplicaManager.scala:878-918):仅当 `requiredAcks == -1` 且至少一个分区写成功时创建 `DelayedProduce`(`delayedProduceRequestRequired`,1361-1367);其 `requiredOffset` = 本批 lastOffset + 1(buildProducePartitionStatus,ReplicaManager.scala:840)。
3. `DelayedProduce.tryComplete`(server/.../purgatory/DelayedProduce.java:140-172)对每个仍 `acksPending` 的分区调用 validator——即 `Partition.checkEnoughReplicasReachOffset`:`HW >= requiredOffset` 且 ISR ≥ min.isr 则完成(出现 `NOT_ENOUGH_REPLICAS_AFTER_APPEND` 表示写进去了但 ISR 掉到 min.isr 之下,Partition.scala:947-983);全部满足则 `forceComplete` 并在 `onComplete` 执行响应回调(DelayedProduce.java:188-196)。
4. append 返回后通过 ActionQueue 依据 `LeaderHwChange` 决定唤醒哪些 purgatory(HW 增加唤醒 produce/fetch/deleteRecords/share fetch,只更新 LEO 只唤醒 fetch)(ReplicaManager.scala:853-876)。

### 5.2 makeLeaders / makeFollowers:KRaft 下的 leader 变更

ZooKeeper 时代的 `makeLeaders/makeFollowers` 批量方法已消失;KRaft 中 broker 消费元数据增量,由 `applyLocalLeadersDelta` / `applyLocalFollowersDelta` 逐分区驱动(ReplicaManager.scala:2418-2447、2449-2540):

- **become leader**:`replicaFetcherManager.removeFetcherForPartitions`(自己不再拉)→ `partition.makeLeader(...)`(ReplicaManager.scala:2432)。`makeLeader` 持 `leaderIsrUpdateLock` 写锁(Partition.scala:593):校验 partition epoch(599)、更新 assignment/ISR(620-627)、创建/加载日志(629);若 leaderEpoch 变化,以 `leaderLog.logEndOffset` 作为新 epoch 起点 `assignEpochStartOffset`(635-649,注释解释:短暂期内连续选举时,follower 可能持有比新 leader 更高 epoch 的数据,必须登记本 epoch 起点让它们能正确截断),重置各 remote replica 状态(653-660),最后尝试推 HW(678)。HW 推进后 `tryCompleteDelayedRequests()` 唤醒 purgatory(681-683)。
- **become follower**:`partition.makeFollower(...)` 更新 leader/epoch 并清空 ISR(Partition.scala:694-743);若 epoch 变化则停旧 fetcher → 计算初始抓取位置(`initialFetchOffset`)→ `addFetcherForPartitions` 启动新 fetcher(ReplicaManager.scala:2510-2536)。
- ISR 维护:后台定时 `maybeShrinkIsr`(ReplicaManager.scala:2100-2107 → Partition.scala:1089),按 `replica.lag.time.max.ms` 判定;扩容只在 follower fetch 更新状态时做(Partition.scala:797)。判定 caught-up 的依据不是简单比较 LEO,而是副本 `lastCaughtUpTime`:leader 在每次 fetch 中记录该 follower 抓到的位置与当时的 leader LEO,只要 follower 曾在 leader 的某个 LEO 产生后的一段时间内抓到了它,就算追上——因此短暂的网络抖动不会立刻把副本踢出 ISR,而持续落后才会。

- HW 持久化:后台线程定期把各分区 HW 写入 log dir 的 `highwatermark` checkpoint 文件(ReplicaManager.scala:216-218、2116-2138),重启时用它恢复消费者可见位置。

### 5.3 truncateTo 链路

leader 侧触发(follower 截断由 fetcher 线程按 diverging epoch 完成):`Partition.truncateTo` 读锁 + `LogManager.truncateTo`(Partition.scala:1547-1553 → storage LogManager.java:934-968)。LogManager 层若截断点小于 active 段 baseOffset,会先 `abortAndPauseCleaning` 并把 cleaner checkpoint 回退(LogManager.java:945-948),再进入 `UnifiedLog.truncateTo`(见 4.3),最终 `LocalLog.truncateTo` 逐段 `LogSegment.truncateTo` 截索引与数据(LogSegment.java:562-580)。

---

## ⑥ 日志清理与保留概览

### 6.1 deletion 保留策略(整段删除)

`UnifiedLog.deleteOldSegments`(UnifiedLog.java:1967-1996)按 `cleanup.policy` 分派:delete 策略执行三个条件检查——logStartOffset 超前、大小超限(retention.bytes)、时间超限(retention.ms),顺序为 startOffset → size → ms(1971-1973);compact 策略只删 logStartOffset 之前的段(1974-1975)。可删判定有两条硬约束:段必须是"从最老起连续可删"的(`deletableSegments` 遇到第一个不满足条件的段即停止,UnifiedLog.java:1887-1907),且 **段的上界 offset 必须不超过 HW**(`highWatermark() >= upperBoundOffset`,UnifiedLog.java:1894)——保证 logStartOffset 永不超过 HW。删除时若会删光所有段,先 roll 出一个新 active 段再删(UnifiedLog.java:1933-1942)。远程存储开启时还有 local retention(`log.local.retention.ms/bytes`)变体(1979-1982)。

时间维度的判定基准是段的 **最大消息时间戳** 而非文件修改时间:`startMs - segment.largestTimestamp() > retentionMs`(UnifiedLog.java:2007-2015);段的 largestTimestamp 取自 timeindex 最后一条(懒物化,LogSegment.java:198-220),因此"最后写入的消息"决定整段何时过期。大小维度则是从最老段开始累计,直到删够 `logSize - retentionSize` 字节(UnifiedLog.java:2044-2055)。两者都以整段为最小单位,这正是 Kafka 保留策略"粗但零成本"的体现:没有逐条 TTL,只有逐段淘汰。

### 6.2 compaction 语义(log cleaner)

`LogCleaner` 把日志分成 clean/dirty 两区,dirty 又分 cleanable 与 uncleanable,active segment 永远不可清理(LogCleaner.java:52-54)。调度依据 `LogToClean.cleanableRatio = cleanableBytes / totalBytes`(LogToClean.java:45-55)与 `min.cleanable.dirty.ratio`;进度 checkpoint 在 `cleaner-offset-checkpoint`(LogCleanerManager.java:66)。cleaner 与截断、删除之间存在竞态:任何 truncate 或段删除操作前必须 `abortAndPauseCleaning`(storage LogManager.java:945-948),结束后再恢复,LogCleanerManager 用状态机记录每个分区当前的清理状态以防新旧清理任务交叉。

`Cleaner.doClean`(Cleaner.java:159-209)四步:

1. `buildOffsetMap`:从 firstDirtyOffset 扫到 firstUncleanableOffset(不越过 active segment 与 `min.compaction.lag.ms` 边界),把每个 key → 最大 offset 填进堆外哈希表 `SkimpyOffsetMap`(Cleaner.java:174-178);
2. `groupSegmentsBySize` 把若干段分组,保证压缩后产物段尺寸合法(193-198);
3. `cleanSegments` 每组写出到 `*.kafka.cleaned` 临时段再原子替换,期间保留 key 最新的记录、保留事务边界内所有记录、按 `delete.retention.ms` 丢弃过期墓碑(Cleaner.java:228-303;替换逻辑在 LocalLog.replaceSegments,LocalLog.java:1004);
4. 清理过程中 ongoing transaction 的记录不丢弃(`lastRecordsOfActiveProducers` 保护,Cleaner.java:243)。

### 6.3 KRaft 元数据日志概览

`KafkaRaftLog`(raft/.../internals/KafkaRaftLog.java)实现 `RaftLog` 接口,内部就是一个 `UnifiedLog`,目录为 `__cluster_metadata-0`(KafkaRaftLog.java:712-726)。差异仅在于配置:max.batch.bytes 显式设置、retention 全部关闭(696-698)、producer id 过期检查关闭,并额外管理 Raft 快照文件(`recoverSnapshots`,751+),启动时"快照 > 日志末尾则整段截断"(746)。所以第六章的大部分机制(epoch cache、稀疏索引、恢复)对元数据日志同样成立。

---

## ⑦ 设计动机与取舍

- **顺序写为什么快**:机械盘顺序写接近磁盘带宽而随机写差 2-3 个数量级;SSD/NVM 上顺序写还能绕过写放大与 fsync 元数据开销。Kafka 的日志结构使每分区的写入永远是"active segment 文件尾部 append"(LocalLog.java:527-530),索引也是纯尾部追加(AbstractIndex.java:349-352 注释:"Kafka always appends to the end of the index file"),完全避免就地更新。
- **稀疏索引的取舍**:每个 batch 才可能建一条索引(`index.interval.bytes`,LogSegment.java:271),把索引体积压到数据的约 1/1000,换来"二分定位 + 最多一个 interval 的线性扫描"(LogSegment.java:399-402)。定位粒度是批不是条,压缩批量写也天然适配。
- **与 LSM/B-tree 一句话对照**:LSM 用 memtable+WAL+compaction 换随机写性能、牺牲读放大;Kafka 的 log-structured 存储把"写路径"退化为纯顺序追加、把"随机访问"交给 offset 二分与 page cache,以不支持原地更新/随机写为代价获得可预测的写吞吐——它不是通用 KV 引擎,而是"消息即日志"的专用形态。
- **零拷贝 + page cache 优先**:不缓存数据在 JVM,依赖 OS page cache,避免 GC 与双份缓存;索引 mmap 也是同一思路(AbstractIndex.java:345-352)。
- **fsync 的克制**:默认依赖"多副本 + 恢复点"而非每笔 fsync 换持久性,`flush.messages/flush.ms` 交由用户按需收紧(UnifiedLog.java:1286);这是把" durability"问题从单机 IO 转移到复制协议上的关键取舍。
- **HW 单调 + maximalIsr(KIP-497)+ epoch fencing** 是一组保守取舍:宁可消费者暂时读不到最新数据(HW 不回退),也绝不暴露可能被截断的数据。

---

## ⑧ FAQ

**Q1:offset 与文件位置如何对应?为什么 .index 文件里存的是相对 offset?**
每段 `.index` 条目为 `(相对offset: int, 物理位置: int)` 共 8 字节(OffsetIndex.java:150-151),读取时加回 baseOffset(OffsetIndex.java:200)。相对值保证 int 够用;一旦 `lastOffset - baseOffset` 超过 int 上限,`canConvertToRelativeOffset` 为假并触发强制 roll(LogSegment.java:168-174、237-239)。

**Q2:consumer 给定 offset 后,定位一次要扫描多少数据?**
先对 `.index` 二分找 ≤ offset 的最大条目(最多 miss 到 `(baseOffset,0)`,OffsetIndex.java:97-106),再从该物理位置顺序扫描到目标批;最坏扫描量 ≈ index.interval.bytes 的一个 batch 区间。这也是"调大 index.interval.bytes 换更小索引、调小换更快定位"的定量依据——间隔越小,线性扫描窗口越短,但索引文件与 page cache 占用越大。

**Q3:为什么读不到超出 HW 的数据?follower 为什么可以?**
`UnifiedLog.read` 按 `FetchIsolation` 选择上界:消费请求隔离在 HW 或 LSO,副本同步(fetch from follower)用 LOG_END(UnifiedLog.java:1654-1658)。这保证消费者永远读已提交(多副本可达)的数据。对 read_committed 消费者,上界进一步收紧到 LSO=min(HW, firstUnstableOffset)(UnifiedLog.java:648-676),未决事务之后的所有数据都被扣住,即使它们属于别的事务或非事务记录——这是把"线性日志"适配成"事务可见性"语义的代价。

**Q4:acks=-1 时 produce 请求何时返回?**
本地写入立即完成,但响应由 DelayedProduce 延迟完成:等 HW ≥ 本批 requiredOffset 且 ISR ≥ min.isr(ReplicaManager.scala:886-911、Partition.scala:969-979),或超时返回 REQUEST_TIMED_OUT。超时前 ISR 若掉到 min.isr 之下,即使 HW 已经追上,也会以 `NOT_ENOUGH_REPLICAS_AFTER_APPEND` 失败——数据已落盘但客户端被要求重试,防止"写成功但副本不足"被误认为已提交。

**Q5:leader 切换后,新 leader 上遗留了老 leader 的多写数据怎么办?**
靠 leader epoch:follower fetch 带 lastFetchedEpoch,leader 通过 `endOffsetFor` 发现 follower 的 offset 超过该 epoch 终点即返回 divergingEpoch,follower 截断后再拉(Partition.scala:1383-1413);新 leader 自身则在 makeLeader 时以 LEO 登记新 epoch 起点(Partition.scala:649)。值得注意的是,这套机制替代了早期"按 HW 截断"的保守策略:HW 截断在连续选举场景下会错误保留老 leader 的独有数据(数据分叉),而 epoch 精确到"每个任期内写到哪",可以把日志收敛到任意一次历史真值上。

**Q6:为什么 produce 延迟偶尔出现 1 秒级尖刺?**
源码注释给出的真实案例:索引增长跨越 page 边界时,标准二分查找到冷页引发 page fault(AbstractIndex.java:354-373),因此实现了缓存友好的变体二分。

**Q7:roll 由什么触发?可以保证段时间均匀吗?**
`shouldRoll`:段满、`segment.ms` 超时(减去随机 jitter 防止同时 roll)、索引满、相对 offset 溢出(LogSegment.java:168-174)。jitter 避免多分区同时产生大量新段。

**Q8:清理(compact)会改变 offset 吗?offset 还连续吗?**
不会改变已有 offset;压缩只是丢弃同 key 的旧记录,offset 会出现"空洞",消费者按 offset 顺序读不受影响。active segment 与进行中的事务记录不参与清理(LogCleaner.java:52-54、Cleaner.java:243)。

**Q9:Broker 崩溃后如何恢复?重放多少数据?**
从 recovery-point-offset-checkpoint 记录的恢复点开始,`LogSegment.recover` 重放校验并重建索引、截掉尾部残缺字节(LogSegment.java:483-529);HW、logStartOffset、producer 快照均有各自 checkpoint(LogManager.java:85-86、ReplicaManager.scala:2116-2138)。代价是未 flush 的数据可能截断后从 leader 重新复制。

**Q10:KRaft 元数据日志也做 retention 吗?**
不做 time/bytes 保留(强制 -1,KafkaRaftLog.java:696-698);空间回收依赖 Raft 快照:快照点之前的日志段通过 logStartOffset 推进被删除,启动时若快照超前于日志则整段截断(KafkaRaftLog.java:744-746)。

---

## ⑨ 深挖问题(供后续章节跟进)

1. **`UnifiedLog.lock` 的锁粒度与 append 延迟**:所有 append/roll/truncate/flush 共用一把对象锁(UnifiedLog.java:123),而 `Partition.appendRecordsToLeader` 外层又持 `leaderIsrUpdateLock` 读锁(Partition.scala:1227)。大流量下 roll(内部含 producer 快照与异步 flush 调度,UnifiedLog.java:2212-2235)与读路径的 `checkIfMemoryMappedBufferClosed` 之间的竞争值得 benchmark。
2. **KAFKA-18723 修复的边界**:复制路径按 epoch 跳批(UnifiedLog.java:1516-1524)后,这些批要等下一次 FETCH 才能补齐——follower 的 LEO 推进与 ISR 判定在该窗口内如何避免抖动?
3. **压缩路径的 double-write**:`validateMessagesAndAssignOffsetsCompressed`(LogValidator.java:279)在源/目标压缩不同或格式转换时整批重写,offset 全部分配在新缓冲上;这段 CPU 开销与 `max.message.bytes` 二次校验(UnifiedLog.java:1176-1187)是 produce 热点,值得结合 JMH 基准(jmh-benchmarks 模块)量化。
4. **mmap remap 与索引满的交互**:索引满会触发 roll(LogSegment.java:173),而 remap 需要写锁(AbstractIndex.java:455-459);极端小 `maxIndexSize` 下会出现"roll 出 size=0 的段又被删重建"(LocalLog.java:593-615 的 KAFKA-6388),此保护逻辑是否已覆盖所有 crash-recovery 场景?
5. **分层存储读路径的一致性**:`UnifiedLog.read` 的 floorSegment 定位、`localLogStartOffset` 与 `logStartOffset` 的双轨(UnifiedLog.java:233-235),以及 readFromLog 对 `delayedRemoteStorageFetch` 的预算估算(ReplicaManager.scala:1884-1885)如何影响 `fetch.max.bytes` 语义,值得单独一章(与 08 卷 Tiered Storage 呼应)。
