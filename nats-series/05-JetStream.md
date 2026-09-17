# 第 05 章 · JetStream:流存储与 Raft 复制

> 基线:commit `8f3f31b0`。代码平铺在 server/ 下:jetstream*.go、stream.go、consumer.go、filestore.go、raft.go。

## 5.0 全景:一条 PUB 到 PubAck 的完整路径

```
client PUB → stream leader internalLoop(stream.go:8513)
  → processClusteredInboundMsg(jetstream_cluster.go:12491)
  → commitSingleMsg 编码 Propose(jetstream_batching.go:1078)
     ├ raft: storeToWAL(本机 WAL=filestore)+ AppendEntries($NRG.> subject)
     └ followers: WAL 追加 → ack
  → quorum 提交(tryCommit/applyCommit,raft.go:4023/3885)
  → applyStreamEntries(:5110)→ applyStreamMsgOp(:5622)
  → mset.processJetStreamMsg:真正写入 filestore msg.blk(stream.go:6433)
  → 此刻 leader 才回 PubAck(:7451)——ACK 隐含"多数派 WAL 已落记录"
元层:$SYS 账号下 _meta_ Raft 组(:1314)负责 stream/consumer 的 assignment
```

三层结构:meta 组管"谁在哪",每个 stream 一个 copy 组(S-R3F-xxx),每个非 ephemeral consumer 一个组(C-R3F-xxx)——**故障域、恢复速度、磁盘布局按流隔离**。

## 5.1 存储:文件块+索引,顺序追加

每个 stream 目录下 `%d.blk`(消息数据)+`%d.idx`(块索引)+`%d.key`;consumer 状态在 obs/o.dat。块大小分级:普通 8MB、interest/workqueue/KV 4MB、镜像 1MB(filestore.go:373-386)。写路径严格顺序追加(writeAt),索引只存摘要与删除位图;大文件切块后 purge/compact/truncate 都能以块为粒度进行。fsync 三档:SyncAlways(每写必盘)/AsyncFlush(后台)/默认 2 分钟周期同步。**精妙的解耦**:副本数>1 时自动启用 AsyncFlush(filestore.go:803)——持久性由复制保证,本地 fsync 让位给吞吐。用户以 Replicas 换一致性强度,持久化语义是 Replicas 的函数。

## 5.2 Raft 借宿在 NATS 总线上

raft.go 是通用实现:WAL 接口的实现就是 filestore(raft.go:5101 storeToWAL 直接写块文件);**Raft 传输走 `$NRG.>` subject**(raft.go:2607)——复制协议搭核心总线的便车,零新端口零新协议。leader 心跳 1s,选举超时 4-9s 随机;提交路径 trackResponse→tryCommit→applyCommit→ApplyQ。"日志"与"数据"同构:stream 业务数据本身就是 filestore 的 msg block。

## 5.3 consumer:ack 本身也是 Raft 日志

R>1 时,`+ACK` 被编码成 updateAcksOp 提案进 consumer 自己的 Raft 组(consumer.go:3128-3140),ackFloor/pending 随日志复制;投递动作同样提案(updateDeliveredOp)。**任意 follower 升主后凭日志重建 ackFloor 与 pending,语义无缝**;ack-reply 的延迟天然绑定 quorum,客户端拿到的回执即集群共识。at-least-once 的核心 checkPending:AckWait 过期且未达 MaxDeliver 的序列重投,突发到期合并成批;Interest/WorkQueue 保留策略则由 consumer ack 反向联动 stream 删消息(stream.go:9388-9392)。

mirror 不是特殊协议而是**标准 consumer**:向源 stream 建一个 AckNone push consumer,deliver 到 $JS.M 前缀回流,lead 切换后以 state.LastSeq+1 重建——天然断点续传(stream.go:3755-3829)。

## 5.4 语义边界:core 与 JetStream

core NATS 的契约就是一行短路:无匹配订阅直接丢弃("Check for no interest, short circuit if so",client.go:4500)=at-most-once。JetStream 把语义抬到 at-least-once:存储路径保证已确认消息不丢,重投路径保证未确认消息会再来;重复由 Nats-Msg-Id 去重窗口兜到"效果上恰好一次"。分界线 precisely 是:**是否把"投递"升级为需要多方确认的事件**。

## 5.5 设计动机

1. **per-stream Raft 而非全局日志**:单条全局日志让所有流争抢同一写入点;按流隔离故障域与恢复速度,meta 只管"谁在哪";
2. **文件块+索引**:追加写保持顺序 IO;切块让 purge/truncate 以块为粒度;
3. **ack 也是日志**:ackFloor 是 consumer 的"写状态",只存本地则 leader 切换必丢 pending;
4. **meta 独立成组**:低频控制面与高频数据面隔离,元层快照只有 assignment,回放极快;
5. **API 走 subject 而非 gRPC**:$JS.API.> 复用 NATS 的寻址/鉴权/账号隔离,客户端零依赖——"自举"是这个代码库的审美。

## 5.6 FAQ

**Q1:PubAck 返回时消息在哪?**
多数派 WAL 已落记录,leader 本地 filestore 已写入;fsync 可能滞后(R>1 时)。

**Q2:R=1 会 fsync 吗?**
可配 SyncAlways 每写必盘;R>1 自动 AsyncFlush,用复制换 fsync。

**Q3:consumer 挂了会丢 ack 吗?**
不会:ack 是 consumer Raft 组的日志,升主后凭日志重建。

**Q4:stream 的 Raft 组名什么含义?**
S-R3F-xxx:R3=副本数,F/M=file/memory 存储(jetstream_cluster.go:10394)。

**Q5:镜像和源怎么实现?**
标准 consumer:AckNone push consumer + $JS.M/$JS.S 前缀回流,断点续传。

**Q6:重启后怎么恢复?**
三段式:扫 blk 重建消息态(校验 checksum 截断坏尾)、读 o.dat 重建 consumer 态、meta 回放 assignment 重建拓扑。

**Q7:$JS API 是什么协议?**
普通 request-reply:$JS.API.> subject+JSON 响应,处理表即 subject→handler 对。

**Q8:去重怎么做?**
Nats-Msg-Id+clfs 序列与去重窗口(stream.go:6433)。

**Q9:重投间隔?**
AckWait 过期重投,1ms ackWaitDelay 合并突发;MaxDeliver 封顶。

**Q10:消息的 Raft 日志和最终数据是两份吗?**
不是同构的两份视图:WAL 实现就是 filestore 本身,leader 提交后同一 filestore 服务读取。

## 5.7 小结与深挖方向

本章结论:**JetStream="每流一组 Raft+WAL 即 filestore+ack 即日志+复制换 fsync,自举于核心总线"**。深挖:

1. clseq/clfs 预分配序列在 leader 切换后跳洞的恢复;
2. batching.go 的批量提案窗口与延迟权衡;
3. meta Observer 模式的跨域扩展(jetstream_cluster.go:1344);
4. filestore 块级 Compact/Truncate 与消费者读游标的协调;
5. pull consumer 的 pending 请求注册为何也走提案。
