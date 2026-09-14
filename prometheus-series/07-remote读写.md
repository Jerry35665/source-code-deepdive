# 第 07 章 · remote write 与 WAL 回放:数据的第二条生命

> 基线:commit `b0f312b`。行号以 storage/remote/ 为准。

## 7.0 全景:WAL 驱动的发送管道

```
Head append 提交后 Notify(head_append.go:1793)
  → main.go:1541 db.SetWriteNotified(remoteStorage)
  → 每条 remote_write 配置一个 QueueManager(queue_manager.go:544 内建 wlog.NewWatcher)
  → watcher 跟读 WAL:Series 进 ref→labels 缓存;样本按 T>startTimestamp 过滤(watcher.go:560)
  → shards.enqueue 按 uint64(ref) % len(queues) hashmod 分片(queue_manager.go:1366)
  → 每 shard queue 攒批 → runShard 串行消费:protobuf+snappy → HTTP POST
```

**为什么从 WAL 读而非内存直发**:WAL 即持久缓冲——重启不丢、不占 TSDB 内存、时序天然有序(:544 的 watcher 设计宣言)。**分片算法保证 per-series 顺序性**(同 series 恒同 shard,:1366)。

## 7.1 queue manager:背压分级与动态 reshard

- **背压分级**:队列满→入队侧 5ms 起指数退避重试(**不丢**);超龄丢样本仅当 `sample_age_limit` 非 0;硬停超 flushDeadline 才丢内存尾巴(:1337-1355)。**本版仍是纯内存队列,无 on-disk spill**——可靠性由"WAL 即持久缓冲"兜底;
- **动态 reshard**:每 10s 按 EWMA 算期望 shard 数(:1159),±30% 容忍带、落后>10s 不缩、夹在 MinShards(1)/MaxShards(50);换群先冲刷旧 shards 再启动(:1235-1250)保顺序;
- **重试矩阵**:网络错/5xx/429(需 `retry_on_http_429`)→无限指数退避(30ms→5s,:2042),Retry-After 优先,重试期间禁 reshard 防限流放大(:2081-2090);其余 4xx 立即放弃;重试重建请求时**剔除过龄样本**(:1796-1815)。

## 7.2 接收端与 remote read

接收端 /api/v1/write(write_handler.go:96):snappy 解压已由库外 handler 完成;**OOO 映射为 400**,注释明言"防发送端重试"(TSDB 非幂等,:115-118);v2 部分写:4xx 保留已写部分并回报 Written-* 统计头,5xx 整体 Rollback(:279-285)。remote read 默认优先 STREAMED_XOR_CHUNKS(client.go:66-69,帧=uvarint 长度+Castagnoli CRC,chunked.go:67);readRecent=false 时按本地起始时间裁剪查询(read.go:108)。

## 7.3 设计动机

1. **WAL 作为发送队列**:推送数据的"至少一次"由 WAL 的持久性免费提供——重放即重发,时间过滤(:560)防重启洪泛;
2. **hashmod 分片**:per-series 顺序性+无共享状态;reshard 会临时破坏顺序(接受,因为指标样本独立);
3. **可恢复/不可恢复的显式分级**:5xx/网络=无限重试,4xx=放弃(:322-325)——把"错误语义"编码成重试策略;
4. **接收端 400 映射 OOO**(:115-118):让发送端停止重试一个"永远会失败"的请求——协议层的止损。

## 7.4 FAQ

**Q1:remote_write 会丢数据吗?**
进程崩溃不丢(WAL 重放续传 :301-331);接收端永久 4xx 的样本会放弃。

**Q2:两个 remote_write 配置互相影响吗?**
各自独立 QueueManager+watcher(:544):互不干扰。

**Q3:下游挂了会内存爆炸吗?**
队列有上限,满了入队侧退避(:1337-1355);WAL 兜底不丢。

**Q4:为什么 shard 数会自动变?**
EWMA 计算的期望 shard 数(:1159):按吞吐自适应;±30% 防抖。

**Q5:OOO 样本发送失败为什么是 400?**
接收端 TSDB 的 OOO 窗口外的样本不可写(:115-118):重试无意义。

**Q6:remote read 的 streamed 模式是什么?**
XOR chunk 流式传输(:66-69):避免服务端全量物化。

**Q7:重启后为什么不会把历史数据全发一遍?**
样本过滤 T>startTimestamp(:560):只发"新"样本。

**Q8:序列的顺序性在多 shard 下如何?**
同 series 恒同 shard(:1366):series 内有序,全局无序——接收端按 series 处理无所谓。

## 7.5 小结与深挖方向

本章结论:**remote write="WAL 即队列+hashmod 分片+分级重试+接收端止损"**。深挖:

1. EWMA reshard(:1159)在突发流量的震荡;
2. 30ms→5s 退避(:2042)与 Retry-After 的优先级交互;
3. 过龄样本剔除(:1796-1815)与 sample_age_limit 的组合;
4. 接收端 v2 部分写(:279-285)的 Written-* 统计语义;
5. streamed remote read 的 chunk 帧与卷一 03 章 XOR 的衔接。

> 下一章:rules 引擎——告警的生老病死。
