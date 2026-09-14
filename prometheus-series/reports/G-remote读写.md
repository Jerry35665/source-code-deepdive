# G 章 · Remote Write 与 Remote Read 深读

> 源码版本:prometheus/prometheus @ commit `b0f312b`(b0f312ba48c9d31dad04e7014bfb0fa300153a07)。所有 `文件:行号` 均为该 commit 下仓库相对路径的实际核对结果。

卷一讲 fanout 存储时留了一个尾巴:remote_write 出口。本章把这个出口讲透——数据如何从 WAL 流向远端、队列如何分片与伸缩、失败如何重试;顺带把接收端(`/api/v1/write`)与 remote read 两条路也走完。

## 1. 全景:数据流

```
                    ┌────────────────────────── Prometheus 发送端 ──────────────────────────┐
 scrape/OTLP 收数    │  TSDB Head ──写 WAL──> wlog.Watcher ──Append──> QueueManager          │
          │          │     (head_append.go:1793          (tsdb/wlog/watcher.go)  │           │
          ▼          │      Notify 触发读)                    ▲                ▼           │
      Head Append    │                                 StoreSeries/     shards(N 个)     │
                    │                                 SeriesReset      │ hashmod 分片     │
                    │                                                  ▼                 │
                    │                              queue(batchQueue chan) ◄─ 定时 5s      │
                    │                                       │                            │
                    │                                       ▼                            │
                    │                          runShard:攒批 → buildWriteRequest           │
                    │                          (protobuf marshal + snappy 压缩)            │
                    │                                       │                              │
                    │                                       ▼                              │
                    │                     client.Store:HTTP POST + 指数退避重试             │
                    └───────────────────────────────────────┼──────────────────────────────┘
                                                            ▼
                    ┌────────────────────────── 接收端 ────────────────────────────────────┐
                    │  POST /api/v1/write → remoteapi handler(解压 snappy,库外实现)        │
                    │      → writeHandler.Store(write_handler.go:95)                       │
                    │      → prompb/writev2 Unmarshal → Appender.Append(含 OOO 判定)        │
                    │      → 接收端自己的 TSDB(同样写它自己的 WAL,闭环回到左图)              │
                    └──────────────────────────────────────────────────────────────────────┘
```

几个关键的"接线"事实:

- 每个 `QueueManager` 在构造时就内嵌创建了自己的 WAL watcher:`storage/remote/queue_manager.go:544`(`wlog.NewWatcher(...)`),即一条 remote_write 配置 = 一个队列 + 一个 WAL 跟读者。
- Head 每次 append 提交后调用 `h.writeNotified.Notify()`(`tsdb/head_append.go:1793`),而 `writeNotified` 在 main 里被设置为 remoteStorage:`cmd/prometheus/main.go:1541`(TSDB 模式)与 `cmd/prometheus/main.go:1600`(Agent 模式)。`WriteStorage.Notify()` 再逐个唤醒队列的 watcher(`storage/remote/write.go:131-139`)。
- 多个 remote_write 目标各自拥有独立 queue,由 `WriteStorage.ApplyConfig` 按 config 哈希增删(`storage/remote/write.go:143-242`);配置哈希用 md5(yaml 序列化),`storage/remote/storage.go:229-236`。
- `WriteStorage.Appender` 只是一个"计数的空 Appender"(timestampTracker),用于统计 samplesIn EWMA 与最高接收时间戳,不真正存数据(`storage/remote/write.go:244-252`、`storage/remote/write.go:373-381`)。

## 2. queue_manager 专节:分片、批、背压、重试

### 2.1 两级结构:shards → queue → batch

`shards` 持有 N 个 `queue`(`storage/remote/queue_manager.go:1260-1285`)。分片算法一行:

```go
// storage/remote/queue_manager.go:1363-1371
func (s *shards) enqueue(ref chunks.HeadSeriesRef, data timeSeries) bool {
	s.mtx.RLock()
	defer s.mtx.RUnlock()
	shard := uint64(ref) % uint64(len(s.queues))
	select {
	case <-s.softShutdown:
		return false
	default:
		appended := s.queues[shard].Append(data)
```

即 **hashmod(seriesRef, N)**:同一 series 恒定落入同一 shard,保证 per-series 顺序。注意分片键是 Head 的 series ref(非 labels),ref 由 WAL record 分配,天然稳定。

每个 `queue` 不是 sample 级 channel,而是 **batch 级 channel**:`newQueue` 按 `capacity / batchSize` 算出通道容量,`batchQueue chan []timeSeries`(`storage/remote/queue_manager.go:1428-1442`)。入队时 sample 先攒进部分批,攒满 `MaxSamplesPerSend` 才试图推入 channel;channel 满则回退最后一个 sample 并返回 false(`storage/remote/queue_manager.go:1446-1466`)——这就是背压的起点。

### 2.2 背压与降速的分级(谁在什么时候慢下来)

| 层级 | 触发 | 行为 | 位置 |
|---|---|---|---|
| L1 入队重试 | shard 队列满 | `Append` 返回 false,调用方以 5ms 起步指数退避重试(`backoff *= 2`,上限 `MaxBackoff`),计数 `enqueue_retries_total` | queue_manager.go:759-784, 777 |
| L2 丢弃超龄 | `sample_age_limit` 配置非零 | 超过时限的 sample/histogram/exemplar 直接丢,计 `dropped_*_total{reason="too_old"}` | queue_manager.go:643-651, 734-736 |
| L3 批发送阻塞 | 单 shard 消费不过来 | `runShard` 串行消费 batchQueue,天然滞后;pending 积压由指标暴露 | queue_manager.go:1617-1657 |
| L4 reshard 禁用 | 收到 `Retry-After` 类可恢复错误 | 禁止 reshard 一段时间(`sleepDuration*2`),防止被限流时越扩越糟 | queue_manager.go:2081-2090 |
| L5 硬停丢数据 | Stop 超过 flushDeadline | `hardShutdown()` 取消在途 HTTP,剩余队列数据全部计为 failed/dropped | queue_manager.go:1337-1355, 1619-1634 |

要点:**正常路径丢数据只有两种可能**——`sample_age_limit`(默认 0,即不丢,config/config.go:1654)和硬停机。内存队列不会因"内存压力"主动丢样本;队列满时是**上游等待**(L1),而不是丢弃。这是很多人对 remote write 的第一误解。

确认"内存队列 vs on-disk 队列":本版(commit b0f312b)的队列仍是**纯内存**实现(`batchQueue chan []timeSeries`,queue_manager.go:1397),没有官方的磁盘溢出队列。可靠性完全由"数据源是 WAL"兜底——内存队列丢了不要紧,只要 watcher 还没推进,重启后会从 WAL 重放(见第 3 节)。这是设计上最漂亮的一点:**WAL 就是 remote write 的持久化缓冲区**。

### 2.3 动态 reshard(弹性伸缩)

每 10 秒(`shardUpdateDuration`,queue_manager.go:58)计算期望分片数:

```go
// storage/remote/queue_manager.go:1168-1190(节选)
dataInRate      = t.dataIn.rate()
dataOutRate     = t.dataOut.rate()
dataKeptRatio   = dataOutRate / (t.dataDropped.rate() + dataOutRate)
dataOutDuration = t.dataOutDuration.rate() / float64(time.Second)
highestSent     = t.metrics.highestSentTimestamp.Get()
highestRecv     = t.highestRecvTimestamp.Get()
delay           = highestRecv - highestSent
dataPending     = delay * dataInRate * dataKeptRatio
...
backlogCatchup  = 0.05 * dataPending
timePerSample   = dataOutDuration / dataOutRate
desiredShards   = timePerSample * (dataInRate*dataKeptRatio + backlogCatchup)
```

约束条件一应俱全:变化幅度必须超出 ±30% 容忍带(`shardToleranceFraction`,queue_manager.go:61、1206-1217);落后超过 10 秒时不许缩容(queue_manager.go:1221-1224);夹在 `[MinShards, MaxShards]`(默认 1/50,config/config.go:241-242);上次成功发送距今不足一个 tick 才允许 reshard(queue_manager.go:1139-1144)。真正的换血在 `reshardLoop`:先 `shards.stop()` 完整冲刷旧队列,再 `start(n)`,注释明说这是为了保证"只按顺序投递"(queue_manager.go:1235-1250)。

### 2.4 重试矩阵(发送端)

`runShard` → `sendSamples` → `sendSamplesWithBackoff`(queue_manager.go:1759)→ `sendWriteRequestWithBackoff`(queue_manager.go:2042)。判定链条从 HTTP 层开始:

```go
// storage/remote/client.go:294-299, 313-326(节选)
httpResp, err := c.Client.Do(httpReq.WithContext(ctx))
if err != nil {
	// 网络错误 → 可恢复
	return WriteResponseStats{}, RecoverableError{err, defaultBackoff}
}
...
if httpResp.StatusCode/100 == 2 {
	return rs, nil
}
...
if httpResp.StatusCode/100 == 5 ||
	(c.retryOnRateLimit && httpResp.StatusCode == http.StatusTooManyRequests) {
	return rs, RecoverableError{err, retryAfterDuration(httpResp.Header.Get("Retry-After"))}
}
return rs, err   // 其余 4xx:不可恢复,整批放弃
```

完整矩阵:

| 错误类别 | 分类 | 后果 | 行号 |
|---|---|---|---|
| 网络错误 / 连接失败 | Recoverable(defaultBackoff=0) | 无限重试,退避 MinBackoff(30ms)→×2→MaxBackoff(5s) | client.go:298; queue_manager.go:2101 |
| 5xx | Recoverable | 同上;`Retry-After` 头优先于默认退避 | client.go:322-325; queue_manager.go:2067-2073 |
| 429(仅当 `retry_on_http_429: true`) | Recoverable | 同上 | client.go:323; config/config.go:1651 |
| 其他 4xx(400/404…) | 非 Recoverable | 整批放弃,计 `failed_*_total` | queue_manager.go:2060-2064 |
| proto marshal 失败 | 非 Recoverable | 立即放弃本批(几乎不可能发生) | queue_manager.go:1763-1767 |
| 重试期间样本老化 | — | 用 `isTimeSeriesOldFilter` 重建请求,把过龄样本剔掉再发 | queue_manager.go:1796-1815 |

每次重试会在请求头带上 `Retry-Attempt: <n>`(client.go:284-286),供接收端/代理识别。重试"无限"而非有上限次数——因为队列阻塞在 `sendWriteRequestWithBackoff` 里时,新 sample 继续涌入 queue channel,直到塞满触发 L1 背压,整个管道就这样慢下来。v2 还有一步防御:2xx 但响应头统计显示什么都没写,视为失败(常见于只支持 v1 却不检查 Content-Type 的接收端),queue_manager.go:1937-1949。

### 2.5 指标速览

queue manager 注册了 30 个指标(queue_manager.go:335-369)。排障最常用的几个:`prometheus_remote_storage_samples_pending`(队列内积压,queue_manager.go:254)、`shards`/`shards_desired`(实际 vs 期望分片,queue_manager.go:282-309)、`samples_retried_total` vs `samples_failed_total`(可恢复重试 vs 永久失败)、`sent_batch_duration_seconds`(queue_manager.go:225-235)。所有指标带 `remote_name`/`url` 常量标签区分多目标(queue_manager.go:108-111)。

## 3. WAL watcher 专节:从 WAL 尾部跟读

watcher 在 `tsdb/wlog/watcher.go`,实现 `WriteTo` 消费者接口(watcher.go:53-73)。核心是 `Run()` 的三段式启动:

```go
// tsdb/wlog/watcher.go:301-331(节选)
func (w *Watcher) Run() error {
	_, lastSegment, err := Segments(w.walDir)
	...
	w.sendSamples = false
	w.logger.Info("Replaying WAL", "queue", w.name)
	// 1) 先回放 checkpoint,只取 Series 记录建立 ref→labels 缓存
	lastCheckpoint, checkpointIndex, err := LastCheckpoint(w.walDir)
	...
	currentSegment, err := w.findSegmentForIndex(checkpointIndex)
	// 2) 从 checkpoint 之后第一个 segment 开始逐段 tail
	for !isClosed(w.quit) {
		w.currentSegmentMetric.Set(float64(currentSegment))
		if err := w.watch(currentSegment, currentSegment < lastSegment); ...
		currentSegment++
	}
}
```

**重启续传(start pos)的答案**:remote write 没有自己的 checkpoint 文件,它的"位点"就是 WAL 自身的 checkpoint + segment 结构。启动时从最新 checkpoint 目录(`checkpoint.000NNN`)读出全部 Series 记录(只读 series,跳过 samples,官方注释称这使重放提速 10 倍以上,watcher.go:545-549),然后从 `findSegmentForIndex(checkpointIndex)` 找到 ≥ checkpoint 序号的第一个 segment(watcher.go:354-367)。对**早于启动时间戳**的历史样本直接跳过(`s.T > w.startTimestamp` 才发,watcher.go:560;`startTimestamp` 在每次 `loop` 重试时重置为当前时间,watcher.go:286、707-710)——即:**series 元数据全量补,样本数据只发新的**,避免重启后洪泛。

**跟读机制**:进入当前(未写满的)segment 后,`watch` 用 4 个信号源驱动读取循环(watcher.go:412-476):

| 信号 | 周期/来源 | 作用 | 行号 |
|---|---|---|---|
| `w.readNotify` | Head 每次 commit 后 Notify | 主路径:读到 EOF 为止 | watcher.go:469-476 |
| readTicker | 15s 无通知兜底 | 防通知丢失 | watcher.go:44、460-467 |
| segmentTicker | 100ms | 发现新 segment → 读完当前段尾换段 | watcher.go:38、448-456 |
| checkpointTicker | 5s | 异步读新 checkpoint 做系列 GC | watcher.go:37、427-445 |

`readSegment` 按 record 类型分发(watcher.go:514-672):Series → `StoreSeries`(建立 ref→labels 并过 relabel,queue_manager.go:1013-1032);Samples/Histograms → `Append*`;Metadata → `StoreMetadata`(v2 专用,queue_manager.go:1035-1049)。外层 `loop` 里任何 WAL 读失败都等 5 秒整体重来(watcher.go:284-296),所以单个 segment 损坏不会杀死远程队列。

watcher 与 queue 的内存 GC 契约:`StoreSeries` 时在 `seriesSegmentIndexes` 记下 series 所在段号,checkpoint 推进后 `SeriesReset(index)` 删掉段号小于 checkpoint 的所有映射(queue_manager.go:1053-1079)。

## 4. 接收端专节:/api/v1/write

路由挂载在 `web/api/v1/api.go:490`(`r.Post("/write", ...)`,handler 构造在 api.go:380)。HTTP 层的 snappy 解压与 Content-Type/版本协商不在本仓库——`NewWriteHandler` 委托给 `remoteapi.NewWriteHandler`(write_handler.go:81),来自依赖 `github.com/prometheus/client_golang/exp/api/remote`(go.mod:66-67);本仓库的 `Store` 拿到的已是解压后的字节,注释明言"Store receives request with decompressed content in body"(write_handler.go:96)。

- **v1 流**(write_handler.go:104-128):整个 `prompb.WriteRequest` 一次 Unmarshal → `write()` 循环 append;任何样本 OOO(`ErrOutOfOrderSample`/`ErrOutOfBounds`/`ErrDuplicateSampleForTimestamp`/`ErrTooOldSample`)→ **400**,并显式注释"把 OOO 标为 bad request 以防发送端重试"(write_handler.go:115-118)——因为 TSDB 非幂等,重试会造成重复写。
- **v2 流**(write_handler.go:130-146、270-305):支持**部分写**。`appendV2` 逐 series 处理,坏 series(符号表解析失败、缺 metric name、重复标签、无样本)进 `badRequestErrs` 继续(write_handler.go:307-478);最终 400 + `errors.Join`,已写部分按 `X-Prometheus-Remote-Write-Written-*` 响应头回报统计;**5xx 则整体 Rollback**(write_handler.go:279-285)。
- **OOO 接受度由 TSDB 决定**:handler 只做"未来时间"防线的包装——`remoteWriteAppender` 拒绝超过 `now+10min`(maxAheadTime,write_handler.go:53、501-511)的样本;样本是否乱序、能否进 OOO head,由 `head.oooTimeWindow`(即 `out_of_order_time_window` 配置)在 `tsdb/head_append.go:694` 的 `appendable()` 判定。接收端开 OOO 窗口,上游发送端才敢乱序发。
- 原生直方图 schema 超指数上限时降分辨率后再写(write_handler.go:519-527);metadata 何时入 WAL 由 `appendMetadata` 开关控制(write_handler.go:459-466)。
- 接收端状态码矩阵(与发送端重试矩阵互为镜像):

| 接收端情形 | 状态码 | 发送端看到后 | 行号 |
|---|---|---|---|
| protobuf 解码失败 | 400 | 非 Recoverable,放弃本批 | write_handler.go:107-111、132-136 |
| v1 任何样本 OOO/越界/重复 | 400 | 非 Recoverable(防重复写) | write_handler.go:115-121 |
| v2 部分 series 坏数据 | 400 + Written-* 头 | 已写部分按统计确认,坏 series 放弃 | write_handler.go:141-146、474-478 |
| 存储层内部错误(5xx 类) | 500 + v1 全量 Rollback / v2 全量 Rollback | Recoverable,退避重试 | write_handler.go:123-125、279-285 |
| 成功 | 200 + v2 统计头 | 确认;v1 无头时按全成功假设(queue_manager.go:1851-1859) | write_handler.go:127、146 |

## 5. remote read 专节

客户端默认同时声明两种响应类型,优先 streamed:`AcceptedResponseTypes = [STREAMED_XOR_CHUNKS, SAMPLES]`(client.go:66-69)。请求仍是 snappy 压缩的 protobuf POST(`X-Prometheus-Remote-Read-Version: 0.1.0`,client.go:394-398);响应按 Content-Type 分派(client.go:429-455):

- **instant/sampled**(`application/x-protobuf`):整包读入→snappy 解码→`ReadResponse`→`combineQueryResults`(client.go:458-484)。一次性物化全部样本,适合小查询。
- **streamed chunked**(`application/x-streamed-protobuf; proto=prometheus.ChunkedReadResponse`):分帧流。帧格式 = uvarint 长度 + big-endian CRC32(Castagnoli)+ 数据(chunked.go:60-88);客户端 `ChunkedReader.Next` 校验并受 `--storage.remote.read-chunked-bytes-limit` 限制(chunked.go:113-143)。服务端 `StreamChunkedReadResponses` 要求 series 有序,单 series 可跨多帧、每帧受 `max_bytes_in_frame` 约束(codec.go:228-304,read_handler.go:231-239)。

服务端 `/api/v1/read`(api.go:489)用 `gate.New(concurrencyLimit)` 限制并发(read_handler.go:54、73);未声明响应类型时向后兼容回退 SAMPLES(codec.go:206-208)。`readRecent=false` 时 `preferLocalStorage` 会用本地起始时间裁剪查询区间甚至直接 noop,只让"本地查不到的老数据"走远端(read.go:108-124);`requiredMatchers` 不匹配则返回空结果,实现"这条 remote read 只服务某些 series"(read.go:141-160)。querier 层的 LabelValues/LabelNames 未实现,直接报错(read.go:213-222)——remote read 只补样本,不参与元数据 API。

另注意读路径的几个工程约束:请求体被 `decodeReadLimit = 32MB` 硬顶(codec.go:43-44、74-76);多查询 sampled 响应按 Results 顺序一一对应,数量不符直接报错(client.go:479-481);sortSeries 只在 sampled 模式下由客户端执行,chunked 模式依赖服务端排序(client.go:355-356 注释);remote Storage 把所有 read endpoint 包成 MergeQuerier 做 fanout,且注释要求 SeriesSet 首次 Next 即就绪——因为 PromQL 引擎不支持中途失败的流(storage.go:154-158)。

## 6. 设计动机

1. **为什么从 WAL 发,而不是内存直发?** 内存直发意味着"remote write 挂了→数据没了"或者要自建持久缓冲。WAL 是 Head 本来就要写的,零额外落盘成本;watcher 独立消费 WAL,发送链路的任何故障(网络中断、reshard、进程重启)都不丢数据,恢复后自动从 WAL 追上。副作用是 remote write 的延迟下限 = WAL 异步消费延迟,以及"TSDB 模式才有 remote write"(Agent 模式同样有 WAL,故也支持,main.go:1600)。
2. **为什么 hashmod 分片到 shard?** 单队列串行发送吞吐有限;多 shard 并行时若同一 series 的样本散落多队列,乱序会触发远端 OOO 拒绝。按 seriesRef hashmod 保证 per-series 严格有序,同时 shard 间完全独立、可独立重试。reshard 先冲刷旧 shards 再启新(queue_manager.go:1239-1245)同样是为这个顺序性。
3. **为什么重试要分级?** 5xx/网络错重试有意义(服务端问题);4xx 重试只会永远失败且 TSDB 非幂等,重试可能重复写,所以立即放弃;429 特殊——它是"过会儿就好"的信号,但默认关(`retry_on_http_429`),避免与动态 reshard 相互放大:被限流时扩容只会更糟,所以可恢复错误期间禁用 reshard(queue_manager.go:2075-2090)。
4. **为什么 batch 是 channel 元素而不是 sample?** 一次 HTTP 请求 2000 样本(默认,config/config.go:243),把"攒批"放在无锁的 append 侧、channel 只传 batch 指针,把 channel 操作开销摊薄 2000 倍;batch 缓冲用 per-queue 池回收(queue_manager.go:1487-1545)。
5. **为什么接收端把 OOO 映射为 400?** 防止发送端把"乱序"当网络故障无限重试(见 4 节引文,write_handler.go:116-117);而 v2 部分写协议让"好的写进去、坏的报出来",是 1.x 全有或全无的演进。

## 7. FAQ 素材

1. **Q: remote write 会丢数据吗?** A: 正常运行不丢(背压等待);两种例外:`sample_age_limit` 主动丢弃超龄样本(queue_manager.go:734-736),以及 Stop 超过 `flush_deadline` 硬停丢内存尾巴(queue_manager.go:1340-1345)。进程崩溃也不丢——数据还在 WAL 里。
2. **Q: 队列满会怎样?** A: `Append` 阻塞重试(5ms→指数→MaxBackoff),WAL watcher 跟着阻塞,最终 Head 不受影响(它只写 WAL);积压看 `prometheus_remote_storage_samples_pending`。
3. **Q: 本版支持磁盘队列吗?** A: 不支持。队列是内存 channel(queue_manager.go:1397),持久化靠 WAL 本身;官方没有 on-disk spill。
4. **Q: shard 数怎么定?** A: 自动:基于输入速率、发送时延 EWMA、积压时间差估算(queue_manager.go:1159-1233),夹在 `min_shards`(1)与 `max_shards`(50)之间;默认配置的注释算过账:50 shard × 2000 样本/批 ÷ 100ms ≈ 1M 样本/s(config/config.go:239-240)。
5. **Q: 重试次数上限?** A: 无上限,可恢复错误无限重试(queue_manager.go:2047-2104);退避 `min_backoff`(30ms)指数增长到 `max_backoff`(5s),或按 `Retry-After` 头。
6. **Q: 重启后会重发历史数据吗?** A: 不会。样本只发 `> 启动时间戳` 的(watcher.go:560);但 series 元数据会从 checkpoint 全量重放(watcher.go:314-323)。
7. **Q: exemplar/native histogram 怎么开关?** A: 对应 `send_exemplars`/`send_native_histograms`,watcher 据此跳过 WAL 记录(watcher.go:573-576、590-593);NHCB 在 v1 协议下直接丢并计 `reason="nhcb_in_rw1_not_supported"`(queue_manager.go:858-863)。
8. **Q: metadata 是怎么发过去的?** A: 两条路。v1:`metadata_config.send` 走 MetadataWatcher 定期(默认 1min)从 scrape manager 收集去重后单独 POST(metadata_watcher.go:128-150);v2:metadata 进 WAL,随每个 series 内联发送,`metadata_config.send` 被自动视为冗余禁用(queue_manager.go:550-557)。
9. **Q: 一个目标挂了会拖累其他目标吗?** A: 不会。每个 remote_write config 一个独立 QueueManager+watcher+client(write.go:202-227),互不影响。
10. **Q: external labels 在哪加?** A: 发送端在 `StoreSeries` 时合并到 seriesLabels(同名标签 series 优先,queue_manager.go:1097-1103);接收端 remote read 时再过滤/合并回(read_handler.go:262-283)。

## 8. 深挖方向

1. **`enqueue` 的锁竞争画像**:`shards.mtx` 是 RWMutex,"与 WAL 并存时从不争用"是作者的乐观假设(queue_manager.go:1261)——reshard 瞬间写锁会挡住所有 append,可量化 reshard 风暴下的入队毛刺。
2. **v1/v2 双轨的维护成本**:`sendSamplesWithBackoff` 与 `sendV2SamplesWithBackoff` 近乎复制(queue_manager.go:1708-1709 官方 TODO),`populateTimeSeries`/`populateV2TimeSeries` 同理;v2 的 symbol table 生命周期(per-batch Reset,queue_manager.go:1613)是理解 v2 内存模型的钥匙。
3. **EWMA 与 reshard 的控制论**:`ewmaRate`(ewma.go:23-70)α=0.2、10s tick;`dataKeptRatio`、`backlogCatchup=5%`、tolerance 30% 这组参数如何决定收敛速度与振荡倾向,值得仿真。
4. **watcher 的 LiveReader 容错边界**:`readAndHandleError` 对"回放段"宽容、对"tail 段"严格(非 EOF 即致命,watcher.go:369-387);段中间损坏时数据是否可跳过、与 checkpoint GC 的交互(readSegmentForGC,watcher.go:676-705)。
5. **远程读的帧协议与 gRPC-stream 的取舍**:自研 uvarint+CRC32 分帧(chunked.go)而非 gRPC,为何;`chunkedReadLimit` 超限直接断流的客户端行为(chunked.go:119-121)。

## 写作要点速查表

| # | 函数/常量 | 位置 | 一句话 |
|---|---|---|---|
| 1 | `QueueManager.Append` | storage/remote/queue_manager.go:730 | watcher→队列入口;过龄丢弃+满队指数退避 |
| 2 | `shards.enqueue`(hashmod) | storage/remote/queue_manager.go:1363(分片:1366) | `uint64(ref) % len(queues)` 保证 per-series 顺序 |
| 3 | `newQueue` / `queue.Append` | storage/remote/queue_manager.go:1428 / 1446 | batch 级 channel;满则弹回样本返回 false |
| 4 | `runShard` | storage/remote/queue_manager.go:1547 | 单 shard 消费循环;BatchSendDeadline 5s 定时冲批 |
| 5 | `sendWriteRequestWithBackoff` | storage/remote/queue_manager.go:2042 | 可恢复错误无限重试;Retry-After 优先;禁 reshard |
| 6 | `calculateDesiredShards` | storage/remote/queue_manager.go:1159 | 动态分片公式;±30% 容忍、落后>10s 不缩 |
| 7 | `Client.Store` | storage/remote/client.go:266 | snappy 压缩(274)、Retry-Attempt 头(285)、5xx/429 可重试(322-325) |
| 8 | `Watcher.Run` | tsdb/wlog/watcher.go:301 | checkpoint 回放→findSegmentForIndex→逐段 tail |
| 9 | `Watcher.watch` | tsdb/wlog/watcher.go:392 | Notify 主驱动;15s 兜底/100ms 换段/5s checkpoint |
| 10 | `Watcher.readSegment` | tsdb/wlog/watcher.go:514 | record 分发;`s.T > startTimestamp` 才发(560) |
| 11 | `writeHandler.Store` | storage/remote/write_handler.go:95 | 解压后 Unmarshal;v1 OOO→400(115);v2 部分写(270) |
| 12 | `remoteWriteAppender.Append` | storage/remote/write_handler.go:501 | 拒绝 now+10min 未来样本(maxAheadTime:53) |
| 13 | `DecodeReadRequest` / 分帧 | storage/remote/codec.go:64 / chunked.go:67,113 | 读:32MB snappy 限制;uvarint+CRC32 帧 |
| 14 | `remoteReadStreamedXORChunks` | storage/remote/read_handler.go:189 | streamed 响应;series 有序、gate 限并发(73) |
| 15 | `preferLocalStorage` | storage/remote/read.go:108 | readRecent=false 时裁剪/短路远端查询 |
| 16 | `DefaultQueueConfig` | config/config.go:238-254 | MaxShards 50/批 2000/容量 10000/backoff 30ms-5s |
| 17 | `Notify` 接线 | tsdb/head_append.go:1793; cmd/prometheus/main.go:1541 | Head commit → remoteStorage → watcher 读 WAL |
| 18 | `buildWriteRequest` | storage/remote/queue_manager.go:2152 | marshal+snappy;统计 highest/lowest 时间戳供重试过滤 |
