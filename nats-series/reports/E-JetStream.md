# E · JetStream：流存储与 Raft 复制

> 系列第 E 篇。基线 commit `8f3f31b0366eca0d855d0750b7ca547eadd10eff`（nats-server）。
> 注：本仓库中 JetStream 代码并不在 `server/jetstream/` 子目录，而是平铺在 `server/` 下：
> `jetstream.go`（账号/资源）、`jetstream_api.go`（$JS API）、`jetstream_cluster.go`（元层与资产编排）、
> `stream.go`/`consumer.go`（资产本体）、`filestore.go`/`memstore.go`/`store.go`（存储层）、`raft.go`（通用 Raft）。

## 0. 顶层架构与一条 PUB 的生命周期

```
                          NATS 核心总线 (core NATS: 无持久化, 订阅匹配即转发)
   client PUB ────────────────────────────────────────────────────────────────┐
      │                                                                      │
      ▼                                                                      ▼
 [stream leader]  internalLoop (stream.go:8513)                     普通订阅者: 无确认, no-interest
      │ msgs 队列                                                     直接丢弃 (client.go:4500)
      │ processClusteredInboundMsg (jetstream_cluster.go:12491)              = at-most-once
      ▼
   node.Propose ──► raft.go: storeToWAL(本机 WAL=filestore) + AppendEntries($NRG)
      │                       │
      │                       ├─► follower A: WAL 追加 → ack
      │                       └─► follower B: WAL 追加 → ack
      ▼ quorum (tryCommit/applyCommit, raft.go:4023/3885)
   ApplyQ ──► monitorStream (jetstream_cluster.go:3889) ──► applyStreamEntries (:5110)
      │                                                          │
      │                                             applyStreamMsgOp (:5544)
      ▼                                                          ▼
   mset.processJetStreamMsg (stream.go:6433) ──► filestore StoreMsg(msg.blk 追加写)
      │
      └─► 领导者此刻才向 publisher 回 PubAck (stream.go:7451)  ← 复制确认先于 ACK

 元层(metagroup):  $SYS 账号下 _meta_ 组 (jetstream_cluster.go:1314,746-748)
   ┌──────────────────────────────────────────────────────┐
   │  meta Raft (3/5 节点, 独立组)                          │
   │   - stream/consumer assignment → selectPeerGroup     │
   │     (jetstream_cluster.go:10089, 10421)              │
   └──────────┬───────────────────────┬───────────────────┘
              ▼                       ▼
   ┌─────────────────┐     ┌─────────────────┐   每个 stream: 一个 copy 组
   │ stream S-R3F-xx │     │ stream S-R3F-yy │   (groupName, jetstream_cluster.go:10394)
   │  Raft + filestore│    │  Raft + filestore│  每个(非 ephemeral)consumer: C-R3F-xx
   └─────────────────┘     └─────────────────┘   (groupNameForConsumer, :10390)
```

一个 stream 副本组、一个 consumer 副本组、一个 meta 组各自是独立 Raft 组；WAL 复用 filestore，
而 stream 的业务数据本身就是 filestore 的 msg block——"日志"与"数据"同构。

## 1. 定位与存储模型

Retention 三策略定义在 `server/store.go:148-160`：`LimitsPolicy`（默认，按限制淘汰）、
`InterestPolicy`（所有已知 consumer 都 ack 才可删）、`WorkQueuePolicy`（第一个 worker ack 即删）。
存储类型 `FileStorage=22 / MemoryStorage=33`（`server/store.go:36-39`）。stream 配置入口是
`StreamConfig`（`server/stream.go:52`，Retention:56 / Storage:64 / Replicas:65 / Mirror:69 / Sources:70）。

filestore 的磁盘布局（`server/filestore.go:319-333`）：每个 stream 目录下按块编号存
`%d.blk`（消息数据）、`%d.idx`（块索引）、`%d.key`（加密密钥），consumer 状态在 `obs/` 目录的
`o.dat`（`consumerDir`/`consumerState`，:331-333，写点 :13408）。块大小分级：普通 8MB、
interest/workqueue 4MB、KV 4MB、镜像/源的小块 1MB（:373-386）。

```
filestore.go:319-326 (节选)
	blkScan = "%d.blk"
	blkSuffix = ".blk"
	...
	indexScan = "%d.idx"
	keyScan = "%d.key"
```

写路径是严格的顺序追加：`msgBlock.writeAt`（:8688）只做 `WriteAt(buf, wp)`，由
`flushPendingMsgsLocked`（:8703）把内存 cache 里的脏数据顺序推入块文件；索引文件 `%d.idx`
记录 msgs/bytes/first/last 与删除位图，读回在 `readIndexInfo`（:10148）。预分配体现在按
`BlockSize` 一次建文件、按块滚动，避免随机 IO。fsync 策略三层：`SyncAlways`（每写必 sync）、
`AsyncFlush`（后台 flush 循环）、默认的周期同步 `defaultSyncInterval = 2m`（:339），由
`setSyncTimer`（:12124-12135）错峰调度、`syncBlocks`（:8205）执行。内存存储一句话：
`memStore` 就是 `map[uint64]*StoreMsg` + subject 树的纯内存实现（`server/memstore.go:26-30`），
代码注释自评"a fairly simplistic approach"。

## 2. $JS API：控制面就是 request-reply

所有 API 走系统账号 subject `$JS.API.>`（`jsAllAPI`，`server/jetstream_api.go:41`；前缀常量 :46）。
服务端用 `s.sysSubscribe(jsAllAPI, js.apiDispatch)` 挂接（:1107），客户端发普通 request、
服务端回 JSON response——没有 gRPC、没有自定义协议。处理表就是一张 subject→handler 对：

```
jetstream_api.go:1118-1130 (节选)
	pairs := []struct {
		subject string
		handler msgHandler
	}{
		{JSApiStreamCreate, s.jsStreamCreateRequest},
		{JSApiStreamUpdate, s.jsStreamUpdateRequest},
		{JSApiStreamDelete, s.jsStreamDeleteRequest},
		{JSApiStreamPurge, s.jsStreamPurgeRequest},
		...
	}
```

`apiDispatch`（:942）做权限/账号校验后把请求投进 `ipQueue`（:1020），由 worker 池
`processJSAPIRoutedRequests`（:1039）异步执行，避免慢请求阻塞消息面。元管理类请求
`$JS.API.META.LEADER.STEPDOWN / SERVER.REMOVE / RESCUE`（:215-233）在 dispatch 层被短路给
meta 层专用 handler。创建 stream 的请求最终落到 `jsStreamCreateRequest`（:1528）：非集群直接建；
集群模式由 meta leader 提案 `encodeAddStreamAssignment`（`jetstream_cluster.go:10585`，编码 :11690）。
消息面的 `$JS.FC` 流控应答（发消息头里带 flow control 的 reply）由
`sendFlowControlReply`（`stream.go:4765`）/`handleFlowControl`（:4787）处理，同样是一条普通 subject 往返。

## 3. meta 层 Raft：`_meta_` 组与资产分配

集群启动时 `setupMetaGroup`（`jetstream_cluster.go:1314`）在 `$SYS` 账号的
`<StoreDir>/<sys>/_js_/_meta_` 下建一个 1MB 块的 filestore 作为 meta WAL（:1329-1331），
然后 `startRaftNode` 启动元组；冷启动（无 peer state）先 `bootstrapRaftNode` + `n.Campaign()`（:1353, :1400）。
（社区文档常称之为 "R0M"，代码里组名就是 `_meta_`，`defaultMetaGroupName`，:746-748。）

`monitorCluster`（:1947）是元层的心跳泵：恢复期回放日志/快照（`applyMetaSnapshot` :2402、
`applyMetaEntries` :3424，把 assignment 增量编码成 map），平时按阈值做快照 + 日志压缩，
并监听 `LeadChangeC` 处理主从切换。分配算法在 `selectPeerGroup`（:10089）：取 meta 组的随机化
peer 列表（:10126 `cc.meta.Peers()`），按 tags/placement/unique-tag 过滤、按剩余可用字节数加权排序，
选出 R 个节点；`createGroupForStream`（:10421）把它打包成 `raftGroup` 并生成组名：

```
jetstream_cluster.go:10394-10396
func groupName(prefix string, peers []string, storage StorageType) string {
	gns := getHash(nuid.Next())
	return fmt.Sprintf("%s-R%d%s-%s", prefix, len(peers), storage.String()[:1], gns)
}
```

即 `S-R3F-xxxx` / `C-R3F-xxxx`：前缀标资产类型，`R3` 是副本数，`F/M` 是存储介质。meta leader
把 `AddStreamAssignment` 提案进日志，每台服务器在 apply 时执行 `processStreamAssignment`（:6044），
若自己是成员则拉起 stream 与 `monitorStream`；consumer 同理由 `processConsumerAssignment`（:6898）
驱动。这样"谁该运行哪个资产"只存在于元层日志里，重启/扩缩容都是重放同一份事实。

## 4. raft.go：一个借宿在 NATS 总线上的通用 Raft

`raft` 结构（`server/raft.go:159`）自带 `wal WAL`（接口，实现即 filestore/memstore，:175）、
term/commit/snapshot 状态、pending append entries 缓存，以及六个 `ipQueue`（prop/entry/resp/apply…）
做无锁阶段间传递（:247-250）。主循环 `run()`（:2730）按状态机在 `runAsFollower/runAsCandidate/
runAsLeader` 间轮转；leader 心跳是 1s ticker（`hbIntervalDefault` :311，`hb := time.NewTicker(hbInterval)`
:3492），选举超时 4-9s 随机（:307-313）。

两个关键决定值得写进文章：
1. **WAL 就是 filestore**：leader 聚合 entries 成 `appendEntry`，`storeToWAL`（:5101）直接
   `n.wal.StoreMsg(...)` 写进块文件并校验 index 连续性（:5109-5116）；follower 同样收到的是
   整条 appendEntry 编码后的一行记录。快照、Compact 也全走 filestore 的 `Truncate/Compact`（:566-575, :1675）。
2. **Raft 消息走 NATS subject**：传输层常量 `raftAllSubj = "$NRG.>"`（:2607），每个组在系统账号里
   挂 vote/append/propose 订阅（`createInternalSubs` :2664），无需额外端口与协议。

提交路径：follower 响应聚合到 `trackResponse`（:4048）→ `tryCommit`（:4023）达成 quorum →
`applyCommit`（:3885）把 committed entries push 进 `apply` 队列（:3938），上层 monitor 消费。
这就是"复制确认"的确切位置。

## 5. stream 复制：PubMsg → replicate → commit → 才有 ACK

集群模式下，stream 的 internalLoop 从 msgs 队列取出消息后交给 `processClusteredInboundMsg`
（`jetstream_cluster.go:12491`）：校验 leader/sealed/资源限额后，`commitSingleMsg`
（`server/jetstream_batching.go:1072`）编码并 Propose：

```
jetstream_batching.go:1077-1080 (节选)
	esm := encodeStreamMsgAllowCompress(subject, reply, hdr, msg, mset.clseq, time.Now().UnixNano(), false)
	if err := node.Propose(term, esm); err != nil {
		return err
	}
```

此时 leader 并不回 ACK——publisher 的 reply 随消息一起进了日志。等 quorum 提交、
`applyStreamEntries`（:5110）按 op 类型分发到 `applyStreamMsgOp`（:5544），后者在 :5622 调
`mset.processJetStreamMsg`：真正写入 filestore、推进 `mset.lseq`，并且只有"leader 且带 reply"
才发送 PubAck（`stream.go:6433` 函数内 `canRespond := doAck && len(reply) > 0 && isLeader`，
发送点 :7451）。于是语义上：**ACK 隐含"多数派 WAL 已落记录"**。

`clseq/clfs`（`stream.go:647-648`）是 leader 侧预分配序列与失效偏移，用于在未提交前保持
单调序列、在 leader 切换后跳洞。落盘方面有个精妙的解耦：副本数 >1 时自动启用 `AsyncFlush`
——因为持久性由复制保证，本地 fsync 可以让位给吞吐：

```
filestore.go:803-806 (节选)
		supportsAsyncFlush := !fs.fcfg.SyncAlways && cfg.Replicas > 1
```

fsync 与复制确认是两条正交的持久化轴：R1+SyncAlways 是"本机每写必盘"，R3+AsyncFlush 是
"多数派内存/WAL + 周期 fsync"，用户以 Replicas 换一致性强度。

## 6. consumer：ack 本身也是 Raft 日志

consumer 分 push/pull 两种投递形态，但 ack 语义统一。`processAck`（`server/consumer.go:2838`）
按 payload 分派 `+ACK/+NAK/+WPI(+IN_PROGRESS)/+TERM`；"+ACK 的持久化"发生在
`processAckMsgLocked`（:3732）推进 `pending/adflr/asflr`（字段定义 :454-455 "ack delivery/store
floor"）之后，`updateAcks`（:3128）：

```
consumer.go:3128-3140 (节选)
func (o *consumer) updateAcks(dseq, sseq uint64, reply string) {
	if o.node != nil {
		var b [2*binary.MaxVarintLen64 + 1]byte
		b[0] = byte(updateAcksOp)
		...
		o.propose(b[:n])
		if reply != _EMPTY_ {
			o.addAckReply(sseq, reply)
		}
	} else if o.store != nil {
```

即 R>1 时 ack 被编码成 `updateAcksOp` 提案进 consumer 自己的 Raft 组，`o.replies` 记下待回
的 ack-reply，提交后再响应客户端；R1 则直接 `store.UpdateAcks` 写 `obs/<name>/o.dat`。
投递动作同样被复制：`updateDelivered`（:3077）提案 `updateDeliveredOp`；pending pull 请求的
注册/注销也是提案（:3153 起）。这让任意 follower 升主后都能凭日志重建 ackFloor 与 pending。

at-least-once 的机制核心是 `checkPending`（:6117）：leader 周期扫描 pending 表，`AckWait` 过期
且未达 `MaxDeliver` 的序列进入重投队列；`ackWait`（:3368）外加 1ms 的 `ackWaitDelay`（:3365）
把突发到期合并成一批。重启后红投也不丢：`applyState`（:3440）从恢复的 ConsumerState 重建
`pending/rdc` 并立即设置检查定时器（:3455-3464）。Interest/WorkQueue 保留策略则反向联动 stream：
consumer 的 ack 经 `mset.ackMsg`（`stream.go:9313`）判定"无剩余兴趣"后，由 stream leader 提案
`deleteRange/deleteMsg` 把消息真正删掉（:9388-9392）。

## 7. mirror 与 source：用 API 消费者搭出的跨流复制

mirror 的优雅之处：它不是特殊协议，而是一个**标准 consumer**。`setupMirrorConsumer`
（`stream.go:3755`）向源 stream 发 `$JS.API.CONSUMER.CREATE`，建一个 `AckNone` 的 push
consumer，deliver subject 用 `syncSubject("$JS.M")`（:3806；sources 用 `$JS.S`，:4318）。
消息回流到 `processInboundMirrorMsg`（:3467），作为"leader 的入站消息"直接提案进本地流组：

```
stream.go:3596-3598 (节选)
		} else {
			err = node.Propose(term, encodeStreamMsg(m.subj, _EMPTY_, m.hdr, m.msg, sseq-1, ts, true, ...
```

lead 切换时的逻辑统一收口在 `stream.setLeader`（:1417）：失去 leader 就 `stopSourceConsumers/
stopClusterSubs/unsubscribeToStream`，成为 leader 则 `startClusterSubs + subscribeToStream`（:1456/:1460），
mirror/source consumer 会以 `state.LastSeq+1` 为起点重建（`OptStartSeq`，:3829），天然断点续传。

## 8. 恢复：重启时如何回到现场

三段式。**流数据**：`newFileStoreWithCreatedAndMode(..., recovering=true)`（`filestore.go:412`）
触发 `recoverFullState`（:1955，读顶层状态文件）→ `recoverMsgs`（:2581，扫描各 `%d.blk`，
`recoverMsgBlock` :1260 逐块 `rebuildState` :1586 校验 checksum，必要时 `rebuildStateFromBufLocked`
截断坏尾）；**consumer 状态**：`stateWithCopyLocked`（:14175）发现无内存态就从 `o.dat` 读入
（:14205-14207）`Delivered/AckFloor/Pending/Redelivered`，上层 `consumer.setStoreState/applyState`
（`consumer.go:3468-3475`，:3440）接管并重启重投定时器；**拓扑**：meta 组回放自己的 WAL/快照，
`applyMetaSnapshot`（`jetstream_cluster.go:2402`）还原全部 assignment，随后
`processStreamAssignment/processConsumerAssignment` 按需在本地重建资产——数据、游标、拓扑三者
各自持久化、互不嵌套。

## 9. 与核心 NATS 的语义边界

核心 NATS 的契约在代码里就是一行短路：消息到达时若无匹配订阅，直接丢弃、无任何持久化——
"Check for no interest, short circuit if so. This is the fanout scale."
（`server/client.go:4500-4502`）。这是 at-most-once 的结构性证据。JetStream 把语义抬到
at-least-once：存储路径（本报告 §5）保证已确认消息不丢，重投路径（§6 checkPending/AckWait）
保证未确认消息会再来——代价是可能出现重复，由客户端 `Nats-Msg-Id` 去重（`mset.clfs` 与
dedupe 窗口，`stream.go:6433` 内 `getCLFS`/dup 检查）兜底到"效果上恰好一次"。两者的分界线
precisely 是：是否把"投递"升级为需要多方确认的事件。

## 10. 设计动机

1. **为什么 per-stream Raft 而非全局日志**：单条全局日志会让所有流争抢同一写入点，而
   `S-R3F-*` 每流一组（§3）让故障域、恢复速度与磁盘布局按流隔离；meta 只管"谁在哪"，
   不管数据面吞吐，规模随流数线性横向扩展。
2. **为什么文件块 + 索引**：追加写 `%d.blk` 保持顺序 IO，`%d.idx` 只存每块摘要与删除位图，
   读回靠 `readIndexInfo`（§1）；大文件切成 8MB 块后，purge/compact/truncate 都能以块为
   粒度进行（`Truncate` :11248），避免重写整个流。
3. **为什么 ack 也是 Raft 日志**：ackFloor/pending 是 consumer 的"写状态"，若只存本地文件，
   leader 切换必丢 pending 或重投已消费消息；`updateAcksOp` 进日志（§6）使任意副本升主后
   语义无缝，且 ack-reply 的延迟天然绑定 quorum，客户端拿到的回执即集群共识。
4. **为什么 meta 独立成组**：stream 消费者是高频数据面，meta 是低频控制面；二者隔离后，
   元层快照只有 assignment（`metaSnapshot` :2395），体积极小、回放极快，集群可以容忍数据面
   大量堆积而控制面始终秒级收敛；同时 `_meta_` 的 Observer 模式（:1344）支持跨域扩展。
5. **为什么 API 走 subject 而非 gRPC**：request-reply 复用现有 NATS 的寻址、鉴权、账号隔离与
   leaf/gateway 路由（`$JS.API.>` 是系统账号的 service export，jetstream_api.go:1110），
   客户端零依赖；Raft 传输同理走 `$NRG.>`（raft.go:2607）——"自举"是这个代码库的审美：
   用核心总线承载一切扩展，包括它自己的复制协议。
6. （附）**为什么复制能换掉 fsync**：`Replicas > 1` 时自动 AsyncFlush（filestore.go:803），
   把单机 fsync 延迟从关键路径移除，用多数派副本间 replication 抵御单机断电——持久化
   语义对用户是 Replicas 的函数，而非隐式行为。

## 11. 写作素材清单（16 条，文件:行号均已核对）

1. `server/jetstream_api.go:41-46, 215-233` — `$JS.API.>` 前缀与元管理 subject
2. `server/jetstream_api.go:1118-1155` — API 处理表（pairs/infopairs）
3. `server/jetstream_api.go:942 / 1020 / 1039` — `apiDispatch` 入队与 worker 池
4. `server/jetstream_cluster.go:1314-1400, 746-748` — `setupMetaGroup`（`_meta_` WAL + bootstrap）
5. `server/jetstream_cluster.go:1947 / 2402 / 3424` — `monitorCluster` 与 meta 回放
6. `server/jetstream_cluster.go:10089 / 10421 / 10394-10396` — 选点、建组、组名
7. `server/raft.go:159-250 / 2607 / 5101-5116` — raft 结构、`$NRG.>`、`storeToWAL`
8. `server/raft.go:2730 / 3458 / 3492 / 3885 / 3938` — run、leader 心跳、applyCommit→ApplyQ
9. `server/jetstream_cluster.go:12491` + `server/jetstream_batching.go:1072-1081` — 发布提案
10. `server/jetstream_cluster.go:5110 / 5544 / 5622` + `server/stream.go:6433 / 7451` — 提交、落盘、PubAck
11. `server/filestore.go:319-333 / 373-386 / 8688 / 8703 / 10148` — 块布局、顺序写、索引
12. `server/filestore.go:803-806 / 8205 / 12124-12135` — AsyncFlush（R>1）与周期 fsync
13. `server/consumer.go:2838 / 3128-3140 / 3732 / 6277` — ack 分派、`updateAcksOp` 提案、reply 令牌
14. `server/consumer.go:6117 / 3365-3372 / 3440` + `server/stream.go:9313 / 9388-9392` — 重投、恢复、兴趣删除
15. `server/stream.go:1417 / 1456 / 3755 / 3467+3596 / 3829` — setLeader 与 mirror/source 断点续传
16. `server/filestore.go:1955 / 2581 / 1586 / 14175 / 14205` + `server/client.go:4500-4502` — 恢复链；at-most-once 对照
