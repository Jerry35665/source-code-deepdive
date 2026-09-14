# 卷一 · 第 2 章 Head 内存块：TSDB 的内存侧时序引擎

> 调研对象：prometheus/prometheus，commit `b0f312b`（shallow clone）。所有行号均以该 commit 的仓库相对路径标注，已用 grep/Read 逐条核对。

Head 是 TSDB 中"活着的那一块"：最近约 2 小时（默认 `chunkRange`，head.go:243 附近 `DefaultBlockDuration` 决定）的样本全部驻留在 Head 里，可写可查；compaction 把 Head 中已封口的数据落成不可变 block。本章沿"一次 Append 的旅程"把 Head 拆开：series 管理（stripe 分片锁）、chunk 编码（XOR/Gorilla）、乱序窗口（OOO）、内存截断（truncate → minValidTime）。

---

## 1. 全景：一次 Append 的旅程

调用方（scrape manager / remote write）拿到 `storage.Appender`，逐条 `Append(ref, lset, t, v)`，最后 `Commit()` 一次性落 WAL + 内存。核心代码在 `tsdb/head_append.go`（head.go 本体不含 Append 路径，Append 相关全部拆在 head_append.go，另有 v2 批量接口 head_append_v2.go:71 `AppenderV2`）。

```
 scraper                      Head                                     磁盘
   │                            │                                        │
   │ Appender(ctx)              │                                        │
   ├───────────────────────────>│ head_append.go:172  Head.Appender      │
   │<── headAppender ───────────┤  未初始化则包一层 initAppender(:38)      │
   │                            │  appender():186 记下 minValidTime/     │
   │                            │  headMaxt/oooTimeWindow 快照           │
   │                            │                                        │
   │ Append(ref,lset,t,v)       │                                        │
   ├───────────────────────────>│ head_append.go:443                     │
   │                            │  1) 快速越界拒绝 (t<minValidTime :444)  │
   │                            │  2) getByID(ref) 找 series (:451)      │
   │                            │     └─ miss → getOrCreate(:455)        │
   │                            │        labels→hash→stripe 哈希表       │
   │                            │        新 series → postings.Add        │
   │                            │  3) lockForAppend 锁 series (:484)     │
   │                            │  4) appendable() 判序 (:491)           │
   │                            │     in-order / OOO / 拒绝              │
   │                            │  5) markPendingCommit (:499) 防 GC     │
   │                            │  6) 样本进 batch（内存暂存，:517）      │
   │<── ref ────────────────────┤                                        │
   │                            │                                        │
   │ Commit()                   │                                        │
   ├───────────────────────────>│ head_append.go:1769                    │
   │                            │  a) log():1116 先写 WAL（series→samples│
   │                            │     →histograms 顺序）─────────────────> WAL
   │                            │  b) commitFloats(:1373)/               │
   │                            │     commitHistograms(:1529)/…          │
   │                            │     逐 series 加锁 →                   │
   │                            │     in-order: memSeries.append(:1904)  │
   │                            │       └─ appendPreprocessor(:2038)     │
   │                            │          满了就 cutNewHeadChunk(:2191) │
   │                            │       └─ s.app.Append(t,v) → XOR 编码  │
   │                            │     OOO: memSeries.insert(:1867)       │
   │                            │       └─ OOOChunk 排序插入 ────────────> WBL
   │                            │  c) updateMinMaxTime(:1858)            │
   │                            │  d) 释放 appendID（查询隔离）           │
   │<───────────────────────────┤                                        │
```

要点：**Append() 阶段不碰 chunk，只做查 series + 校验 + 攒批**；所有真正的写入（编码进 chunk、切新 chunk、mmap 旧 chunk）都发生在 `Commit()`。这让每次系统调用的粒度是"一个 scrape 批次"，而不是"一个样本"。WAL 与内存的先后顺序是：先 `log()` 写 WAL 成功，再把样本应用到内存（head_append.go:1783-1841），崩溃恢复以 WAL 为准。

WAL 记录顺序有讲究：`log()` 先写 series 定义（head_append.go:1124-1132），再写 metadata、float samples、histograms（head_append.go:1146-1160），保证重放时先见标签后见样本。

---

## 2. series 管理专节：stripe 分片锁与 series 创建

### 2.1 memSeries：一条时间线在内存里的全部家当

`tsdb/head.go:2888` `type memSeries struct`：

```go
type memSeries struct {
    ref  chunks.HeadSeriesRef      // 全局递增 ID（head.go:86 lastSeriesID）
    meta *metadata.Metadata
    shardHash uint64              // TSDB 分片查询用，非 sharding 时恒 0
    sync.Mutex                      // 此行之后一切访问都要持锁
    lset labels.Labels
    mmappedChunks []*mmappedChunk   // 已 mmap 落盘的只读 chunk（head.go:2911）
    headChunks   *memChunk          // 链表头：正在写的 head chunk（head.go:2916）
    firstChunkID chunks.HeadChunkID
    ooo *memSeriesOOOFields         // 乱序专用字段，见第 4 节（head.go:2919）
    nextAt int64                    // 预测的下一个 chunk 切割时间戳（head.go:2923）
    state  uint32                   // pendingCommit 计数 + GCed 标志打包（head.go:2925）
    lastValue float64               // 最后一个 float，用于去重（head.go:2934）
    app chunkenc.Appender           // 当前 head chunk 的编码器（head.go:2943）
    txs *txRing                     // appendID 环，查询隔离用（head.go:2946）
}
```

注意 `pendingCommit` 并不是布尔而是计数器：`markPendingCommit()`（head.go:2966）直接 `s.state++`，`unmarkPendingCommit()`（head.go:2977）`s.state--`，`isGCed()`（head.go:2985）检查 `state&seriesGCedFlag`。同一个 series 可被多个 appender 同时标记 pending，计数归零才可能被 GC。

chunk 的双段结构：`mmappedChunks`（旧，mmap 只读，内核按需换页）+ `headChunks`（新，Go 堆上可写）。compaction 时指针前移，head.go:2903-2910 的注释画了 `firstChunkID` 如何平移。旧 head chunk 的 mmap 不在 append 路径上做，而是由后台 `mmapHeadChunks()`（head.go:2254）批量做——注释明说"持锁 mmap 会拖慢下一次 scrape"（head.go:2244-2246）。

### 2.2 stripeSeries：按 ID 与按 hash 双索引 + 取模分片锁

`tsdb/head.go:2403`：

```go
type stripeSeries struct {
    size     int
    series   []map[chunks.HeadSeriesRef]*memSeries // 按 ref 分片
    hashes   []seriesHashmap                       // 按 label hash 分片
    locks    []stripeLock                          // 同一套锁数组两用
    mmapReady []paddedAtomicInt32                  // 每 stripe 的 mmap 候选计数
    seriesLifecycleCallback SeriesLifecycleCallback
}
type stripeLock struct {
    sync.RWMutex
    _ [40]byte        // 填充，避免多锁挤进同一 cache line（head.go:2415）
}
```

分片方式就是**取模（位与）**：`refStripe(ref) = ref & (size-1)`（head.go:2779），hash 侧同样 `hash & uint64(s.size-1)`（head.go:2803）。默认 `DefaultStripeSize = 1 << 14`，即 16384 个分片（head.go:2394）。

- 按 ID 查：`getByID`（head.go:2792）→ 读锁 `s.locks[i]` 后查 map。
- 按标签查：`getByHash`（head.go:2802）→ 同样只持读锁一瞬间。
- 插入：`setUnlessAlreadySet`（head.go:2822）比较特殊，要**先后拿两把锁**——先拿 hash 分片锁做"查重+入哈希表"，再拿 ref 分片锁挂到 `series[stripe][ref]`。因为同一 series 的 hash 分片与 ref 分片通常不是同一把锁。

`seriesHashmap`（head.go:2327）是"unique + conflicts"两级结构：`unique map[uint64]*memSeries` 存哈希无冲突的 series；哈希碰撞的进 `conflicts map[uint64][]*memSeries`（head.go:2330），`get` 时逐个 `labels.Equal` 精确比对（head.go:2333-2343）。这是典型的"以 uint64 hash 为 O(1) 索引、以完整标签为最终裁决"的做法——hash 只加速，不做正确性依据。

为什么取模分片？Head 是全机写入的必经之路，数百个 scrape job 并发 Append，若整表一把锁，锁竞争会成为吞吐瓶颈。16384 个分片把冲突概率摊薄到忽略不计，同时单次查找仍是 O(1) map 访问 + 一把几乎无争用的读写锁。40 字节填充保证相邻锁不在同一 cache line，避免伪共享（head.go:2414-2415 注释：实测把 map 塞进填充区反而更慢，因为多一次指针解引用）。这与 PostgreSQL 的分区锁/缓冲区锁是同一思路：**用空间（更多锁对象）换并行度**，只是 PG 按关系/页面粒度分区，Prometheus 按 ID/hash 数值取模分区。

### 2.3 series 创建

入口 `Head.getOrCreate`（head.go:2191）：先 `getByHash` 查到就直接返回；否则进 `getOrCreateWithOptionalID`（head.go:2201）：

```go
func (h *Head) getOrCreateWithOptionalID(id chunks.HeadSeriesRef, hash uint64,
    lset labels.Labels, pendingCommit bool) (*memSeries, bool, error) {
    if preCreationErr := h.series.seriesLifecycleCallback.PreCreation(lset); ... // :2203
    if id == 0 {
        id = chunks.HeadSeriesRef(h.lastSeriesID.Inc())   // :2211 原子发号
    }
    shardHash := uint64(0)
    if h.opts.EnableSharding { shardHash = labels.StableHash(lset) }
    optimisticallyCreatedSeries := newMemSeries(lset, id, shardHash, ..., pendingCommit) // :2217
    s, created := h.series.setUnlessAlreadySet(hash, lset, optimisticallyCreatedSeries)  // :2218
    if !created { return s, false, nil }   // 并发下别人先建了，丢掉自己这份
    h.metrics.seriesCreated.Inc()
    h.numSeries.Inc()
    h.postings.Add(storage.SeriesRef(id), lset)          // :2223 挂倒排索引
    h.series.postCreation(lset)                          // :2225
    return s, true, nil
}
```

三处细节值得写进书里：
1. **乐观创建**：先 `newMemSeries` 再 `setUnlessAlreadySet` 查重，冲突则白建一个对象直接丢弃——比"先锁全表查重再建"便宜（新建一个 struct 比持全局锁便宜得多）。
2. **id 可能浪费**：head.go:2210 注释明说并发时这个 id 会被浪费（发号发生在查重之前）。
3. **postings.Add 是创建的完成标志**：head.go:2224 注释"Adding the series in the postings marks the creation of series"。`MemPostings.Add`（tsdb/index/postings.go:409）把 series ref 追加进 `m[name][value]` 的倒排链。

appender 侧的包装 `headAppenderBase.getOrCreate`（head_append.go:563）负责清洗标签（`WithoutEmpty`、查重复 label 名，head_append.go:564-570），并把这批新 series 记进 `a.seriesRefs`，Commit 时作为 `record.RefSeries` 写 WAL。创建出来的 series 以 `pendingCommit=true`（head.go:3034-3036）起步：如果 appender 最终 Rollback，`releaseCreatedSeriesReservations`（head_append.go:1746）释放预约，GC 才允许回收这些"只被本 appender 看见"的 series。

创建后还有个竞态要防：`lockForAppend`（head_append.go:594-611）在拿到 series 锁后发现 `isGCed()` 为真（查找与加锁之间被 GC 摘走），就用原标签重新 `getOrCreate`，循环直到拿到活 series。注释（head_append.go:597-602）解释：否则样本会写进一个已从索引摘除的 series，被静默丢弃。

---

## 3. chunk 编码专节：XOR chunk 与 Gorilla 落地

Prometheus 的 float chunk 就是 Gorilla 论文（Facebook, VLDB 2015）的 Go 实现，文件 `tsdb/chunkenc/xor.go`（572 行）。编码常量在 `tsdb/chunkenc/chunk.go:26-34`：`EncXOR` 之外还有 `EncXOR2`（新编码，chunk.go:30）、直方图系列编码。chunk 上限 `MaxBytesPerXORChunk = 1024` 字节（chunk.go:65）。

三层数据各自的编码方式（`xorAppender.Append`，xor.go:161）：

- **首个样本**：timestamp 用 varint 原样写，value 用完整 64 bit 写（xor.go:168-172）。
- **第二个样本**：写 `tDelta = t - t0`（uvarint），value 走 XOR（xor.go:174-180）。
- **后续样本**：写 delta-of-delta（dod = 本次的 tDelta - 上次的 tDelta），再写 value 的 XOR（xor.go:183-211）。

```go
// tsdb/chunkenc/xor.go:186-211（Append 内，dod 分桶）
tDelta = uint64(t - a.t)
dod := int64(tDelta - a.tDelta)
switch {
case dod == 0:                 a.b.writeBit(zero)                     // '0'
case bitRange(dod, 14):        a.b.writeByte(0b10<<6 | ...); ...      // '10' + 14 bit
case bitRange(dod, 17):        a.b.writeBits(0b110, 3); +17 bit
case bitRange(dod, 20):        a.b.writeBits(0b1110, 4); +20 bit
default:                       a.b.writeBits(0b1111, 4); +64 bit
}
a.writeVDelta(v)
```

这就是 Gorilla 的 **delta-of-delta 前缀码**：固定采集间隔下 dod 几乎恒为 0，一个 bit 搞定时间戳。Prometheus 相对论文的改动是毫秒精度需要更大的桶（论文是秒级 7/12/20 bit），xor.go:189-191 注释明说这一点，TODO 里还提到可参考 varbit.go 收紧分桶。

value 的 XOR 编码在 `xorWrite`（xor.go:466）：

```go
// tsdb/chunkenc/xor.go:466-502（节选）
delta := math.Float64bits(newValue) ^ math.Float64bits(currentValue)
if delta == 0 { b.writeBit(zero); return }            // 值不变：1 bit
b.writeBit(one)
newLeading := uint8(bits.LeadingZeros64(delta))
newTrailing := uint8(bits.TrailingZeros64(delta))
if newLeading >= 32 { newLeading = 31 }               // :477 防溢出
if *leading != 0xff && newLeading >= *leading && newTrailing >= *trailing {
    b.writeBit(zero)                                   // 复用上次窗口：1 bit + 有效位
    b.writeBits(delta>>*trailing, 64-int(*leading)-int(*trailing))
    return
}
*leading, *trailing = newLeading, newTrailing
b.writeBit(one); b.writeBits(uint64(newLeading), 5)   // '1' + 5bit 前导零
sigbits := 64 - newLeading - newTrailing
b.writeBits(uint64(sigbits), 6)                       // 6bit 有效位长
b.writeBits(delta>>newTrailing, int(sigbits))         // 有效位载荷
```

value 不变 → 1 bit；有效位落在上次窗口内 → 1 bit 控制位 + 有效位；否则 1+5+6+有效位。读侧有极好的注脚：`xorIterator.Next`（xor.go:330-341）为"dod==0 且 value 不变"的常见情形做了连续两个 bit 的快速路径，正是对编码统计特性的反向利用。

**何时切 chunk** 不在编码层而在 series 层：`appendPreprocessor`（head_append.go:2038）里，达到预测时间 `s.nextAt` 或样本数达到 `samplesPerChunk*2`（默认 `DefaultSamplesPerChunk=120`，head.go:245；head_append.go:2090-2094）就 `cutNewHeadChunk`；字节达到 `MaxBytesPerXORChunkBeforeAppend`（=1024-19，chunk.go:68；head_append.go:2059）也切。`computeChunkEndTime`（head_append.go:2183）在样本量达到目标的 1/4 时按当前速率重新预测切割点，让一个 `chunkRange`（默认 2h）内切出的 chunk 数量尽量均匀。

---

## 4. OOO 乱序专节：out-of-order window

历史版本里时间戳早于 head 最大值就报 `ErrOutOfOrderSample` 丢弃；现在允许一个可配置的乱序窗口（默认关闭，`--storage.tsdb.out-of-order-time-window`），窗口内乱序样本照单全收。

**开关**：`HeadOptions.OutOfOrderTimeWindow`（head.go:76，atomic 支持运行时改），`SetOutOfOrderTimeWindow`（head.go:1167）在启用时同时挂上 WBL（write-back log，head.go:1168-1170）——乱序样本重放不能走普通 WAL，需要独立的日志流。`DefaultOutOfOrderCapMax = 32`（head.go:243）限制单个内存 OOO chunk 的样本上限。

**判序**在 `memSeries.appendable`（head_append.go:694）：

```go
// tsdb/head_append.go:696-731（节选）
if t >= minValidTime {                        // 合法区间内先试 in-order
    if s.headChunks == nil { return false, 0, nil }        // 新 series
    msMaxt := s.maxTime()
    if t > msMaxt { return false, 0, nil }                 // 正常追加
    if t == msMaxt { /* 完全重复按容忍处理 :706-719 */ }
}
if oooTimeWindow > 0 && t >= headMaxt-oooTimeWindow {
    return true, headMaxt - t, nil           // :722 进 OOO 路径
}
if oooTimeWindow > 0 {
    return true, headMaxt - t, storage.ErrTooOldSample     // :725 窗口外太老
}
if t < minValidTime { return false, ..., storage.ErrOutOfBounds }
return false, ..., storage.ErrOutOfOrderSample            // :730 窗口关闭时的老行为
```

注意 `appendable` 在 Append()（预检，head_append.go:491）和 Commit()（终检，head_append.go:1447）各跑一次：head 最大时间在两次调用间可能前移，Commit 时的复检决定了该样本最终走 in-order 还是 OOO，或者被拒。

**乱序样本的落点**：`memSeries.insert`（head_append.go:1867）→ OOO 专用字段 `memSeriesOOOFields`（head.go:3021：`oooMmappedChunks` / `oooHeadChunk` / `firstOOOChunkID`），其中活动的容器是 `oooHeadChunk`（head.go:3212），包着 `OOOChunk`（tsdb/ooo_head.go:27）——**未压缩的 `[]sample` 切片**（ooo_head.go:31 注释：先排序、暂不压缩，"perhaps we can be more efficient later"）。插入是二分定位（`sort.Search`，ooo_head.go:51），时间戳重复直接拒绝（ooo_head.go:59-61）：

```go
// tsdb/ooo_head.go:45-52
if len(o.samples) == 0 || t > o.samples[len(o.samples)-1].t {
    o.samples = append(o.samples, sample{st, t, v, h, fh})   // 常见情形：尾部追加
    return true
}
i := sort.Search(len(o.samples), func(i int) bool { return o.samples[i].t >= t })
```

攒满 `oooCapMax`（默认 32）个样本就 `cutNewOOOHeadChunk`（head_append.go:2225）：把旧 OOO chunk 经 `ToEncodedChunks`（ooo_head.go:78，按时间区间可能裂成多个）编码成正式 chunk，经 `chunkDiskMapper.WriteChunk` mmap 落盘（head_append.go:2252-2260），旧的从内存释放。查询时 OOO m-map chunk 与 in-order 数据做垂直合并（ooo_head_read.go）。

**WBL 与 mmap 标记**：commitFloats 里 OOO 分支（head_append.go:1456-1499）每新建一个 OOO chunk 就记一个 `oooMmapMarkers[series.ref]`，`collectOOORecords`（head_append.go:1268）把这些记录写进 WBL（head_append.go:1862-1868）；WBL 重放时靠 mmap marker 把重放的乱序样本接到正确的 chunk 位置（`Head.Init`，head.go:738）。这是 OOO 特性带来的最大复杂度：**同一份样本有了两条日志流和两种落盘形态**。

---

## 5. truncate 专节：内存截断与 minValidTime

Head 的过期由 `DB` 周期性调用 `Head.Truncate(mint)`（head.go:1250）：先 `truncateMemory` 再 `truncateWAL`（WAL 截断本章从略）。

```go
// tsdb/head.go:1267-1306（节选）
func (h *Head) truncateMemory(mint int64) (err error) {
    ...
    h.lastMemoryTruncationTime.Store(mint)        // :1287
    h.memTruncationInProcess.Store(true)
    ...
    if initialized {
        h.WaitForPendingReadersInTimeRange(h.MinTime(), mint)  // :1293 等查询退出
    }
    h.minTime.Store(mint)
    h.minValidTime.Store(mint)                    // :1299 关键：写入下界同步前移
    for h.MaxTime() < mint { h.maxTime.CompareAndSwap(...) }    // :1302-1304
    if !initialized { return nil }
    h.metrics.headTruncateTotal.Inc()
    return h.truncateSeriesAndChunkDiskMapper("truncateMemory") // :1306
}
```

**minValidTime 的三重身份**（head.go:83 注释："Mint allowed to be added to the head. It shouldn't be lower than the maxt of the last persisted block."）：
1. 写入下界：appender 创建时快照为 `minValidTime`，配合 `cwEnd = MaxTime - chunkRange/2`（head_append.go:212）取 max，保证新样本不会落进正在压缩的时间窗，也保证 Head 与上一个 block 的时间轴不重叠；
2. 截断边界：truncateMemory 把它一次性推到 mint；
3. 恢复基线：`Head.Init(minValidTime)`（head.go:738）重放 WAL 时丢弃更早的样本。

真正的删除在 `truncateSeriesAndChunkDiskMapper`（head.go:1744）→ `Head.gc`（head.go:1988）：

- `stripeSeries.gc`（head.go:2453）逐 stripe 加锁，删掉所有 chunk 都早于 mint 的 chunk；整条 series 无剩余 chunk 且不在 pending/隔离窗口内则整体摘除（回调 `isSeriesWithoutOOO`/`isStaleSeries`/`hasAppendIDAbove`，head.go:1317-1360 处理 OOO 与 stale 变体），同时收集受影响的 label；
- 回到 `Head.gc`：`h.postings.Delete(deleted, affected)`（head.go:2010）把死 series 从倒排表摘除；`h.walExpiries[ref] = actualInOrderMint`（head.go:2015-2021）记录"这些 series 的样本在 WAL 里保留到何时"，防止 WAL checkpoint 过早删掉标签定义导致重放后样本无主；
- 回到 truncateSeriesAndChunkDiskMapper：若 GC 后实际存活数据比请求的 mint 更新（`actualMint > minTime`），则把 `minTime/minValidTime` 校正为 `min(actualMint, appendableMinValidTime)`（head.go:1753-1763）；最后 `chunkDiskMapper.Truncate(minMmapFile)`（head.go:1773）删掉不再被引用的 `chunks_head` mmap 文件。OOO 侧还要用 `headMaxt - oooTimeWindow` 兜底校正 `minOOOTime`（head.go:1764-1770）。

一个时序细节：`h.minTime.Store(mint)` 发生在 gc **之前**（head.go:1298），所以截断期间查询会看到 Head 的 minTime 已前移而数据尚未物理删除；`WaitForPendingReadersInTimeRange`（head.go:1530）+ `memTruncationInProcess`（head.go:1288）负责让旧查询先落地、新查询拿到一致视图。

---

## 6. 设计动机

**为什么自研 TSDB 而不是用 InfluxDB/Graphite**。Prometheus 的数据模型是 `<metric name>{label=value,...}` 的多维标签，2016-2017 年团队评估现有时序库（含 InfluxDB、OpenTSDB、Graphite）后均无法承接：要么标签维度是一等公民但写入吞吐/运维复杂度不合适，要么是树状/固定 schema，倒排索引 + 按时间分片的结构只能自己做。TSDB v2（Fabian Reinartz，2017）的三个支点在本章都有落点：Gorilla 压缩（第 3 节）、倒排索引（postings）、内存 Head + 2h block 的 LSM 式分层。Head 之所以把"可变层"收敛到 2 小时粒度，是因为 compaction 只处理不可变 block，可变层的并发控制（stripe 锁 + appendID 隔离）只需撑住一个很小的时间窗。

**标签模型的存储含义：高基数**。每条新标签组合 = 一个新 memSeries + 一组 postings（head.go:2223）+ 一个独立的 chunk 链。基数爆炸不是"存得多"，而是 series 对象数 × 每对象一把 Mutex × postings 链长度的复合增长——这解释了为什么 Head 上专门有 `cardinalityCache`（head.go:135-138，30 秒过期）和 `PostingsCardinalityStats`（head.go:1176）供 API 暴露 top-k 基数。也解释了设计选择：series 查找优先走 `getByID`（head.go:2794 注释"ID-based lookups are preferred ... for performance reasons"），scrape 用 GetRef 缓存 ref，避免每次都走 hash→标签比对的贵路径。

**分片锁的取舍**。16384 个 stripe 意味着每 stripe 平均只服务几千条 series（百万 series 规模下），锁争用趋近于零；代价是：跨两个索引（ref/hash）的操作要拿两把锁（head.go:2822-2837），GC 要遍历全部 stripe（head.go:2453），全局快照/遍历需要按 stripe 串行加锁。这是"读多写多都要快、但全局操作 rare"这一工作负载下的经典权衡，与 PG 里"分区锁便宜、全局锁昂贵"完全同构。

**内存到磁盘的坡道**：head chunk（堆内存）→ mmap chunk（`chunks_head/`，内核页缓存托管，head.go:140 `chunkDiskMapper`）→ block（不可变文件）。OOO chunk 额外多一级"未压缩切片 → 编码 mmap"的转化。这个三级坡道让写入路径永远只写内存，落盘都异步化。

---

## 7. FAQ 素材

1. **Append() 里到底写没写 chunk？** 没写。只做 series 查找/创建、判序、标记 pendingCommit、把样本塞进 `appendBatch`（head_append.go:443-523）；真正的 chunk 编码在 Commit() 的 commitFloats/commitHistograms 里。
2. **为什么 Commit 先写 WAL 再写内存？** `a.log()` 失败会整体 Rollback（head_append.go:1783-1786）；顺序反过来则内存里已有样本而 WAL 没有，崩溃后数据丢失。
3. **同一时间戳重复样本怎么办？** `t == msMaxt` 时完全相同的样本静默容忍（federation 场景合法），值不同报 `ErrDuplicateSampleForTimestamp`；直方图/浮点互转另有错误（head_append.go:706-719）。
4. **series 的 ID 从哪来？** `h.lastSeriesID` 原子自增（head.go:2211），即 `chunks.HeadSeriesRef`；ID 同时是 stripe 分片的 key。
5. **hash 冲突了会不会串数据？** 不会。`seriesHashmap` 用 conflicts 链 + `labels.Equal` 全量比对（head.go:2333-2343），hash 只是索引。
6. **pendingCommit 是什么？** 一个打包进 `state` 字段的计数器（head.go:2925、2966），表示"有 in-flight 样本要写进这条 series"，防止 Commit 前被 GC 摘除；Rollback/Commit 后释放。
7. **chunk 多大切一次？** 目标 120 样本（head.go:245）；样本量达 1/4 时按速率预测切割点（head_append.go:2085-2089），超 2×120 或 1005 字节硬切。
8. **乱序样本存哪？** 先存未压缩的 `OOOChunk`（ooo_head.go:27），攒满 32 个（head.go:243）编码成 mmap chunk 落盘，并写 WBL 保证崩溃恢复（head_append.go:1862-1868）。
9. **truncate 之后为什么样本还被拒（ErrOutOfBounds）？** `minValidTime` 被 truncateMemory 推进到 mint（head.go:1299），早于它的样本永远进不来；appender 层面还有 `MaxTime - chunkRange/2` 的压缩窗保护（head_append.go:211-214）。
10. **查询会不会读到截断中的数据？** truncate 先 `WaitForPendingReadersInTimeRange`（head.go:1293）再动数据，且查询侧有 `IsQuerierCollidingWithTruncation`（head.go:1570）二次防护。

## 深挖题

1. **两把锁的插入顺序**：`setUnlessAlreadySet` 先 hash 锁后 ref 锁（head.go:2822-2837），而 GC 的 `gcSeries` 侧如何避免反序死锁？可对照 head.go:2676 与 `deleteSeriesByID`（head.go:2589）梳理锁序约定。
2. **appendID 查询隔离**：`isolation.newAppendID`（tsdb/isolation.go:184）+ `memSeries.txs` 环（head.go:2946）如何做到"查询看不到未 Commit 的样本"；`cleanupAppendIDsBelow`（head.go:3153）如何收缩每个 series 的 tx 记录。
3. **XOR2 编码**：`EncXOR2`（chunk.go:30）相对 EncXOR 的差异（tsdb/chunkenc/xor2.go），以及 `UseXOR2FloatEncoding`（head.go:267）运行时切换与 `CompatibleValues`（chunk.go:250-256）允许同 chunk 混编的条件（`appendPreprocessor` head_append.go:2061-2068）。
4. **mmap 候选机制**：`mmapReady` 每 stripe 原子计数（head.go:2407）+ `incMmapReady`（head.go:2783）如何让 `mmapHeadChunks` 免于全表扫描；对照 head.go:2236-2251 的 `onChunkCreated`。
5. **WAL 重放路径如何复用本章结构**：`Head.Init`（head.go:738）把 WAL 样本灌回 memSeries 时如何处理 `minValidTime` 之前的记录、OOM 系列的 `loadMmappedChunks`（head.go:998）如何与 mmap chunk 对齐。

---

## 写作要点速查表

| 主题 | 位置 | 内容 |
|---|---|---|
| Head 结构 | tsdb/head.go:71 | minTime/maxTime/minValidTime 原子量、series/postings/iso/chunkDiskMapper |
| Appender 入口 | tsdb/head_append.go:172,186 | Head.Appender → appender()，快照 minValidTime/oooTimeWindow |
| Append（float） | tsdb/head_append.go:443 | 快速越界拒绝→getByID→getOrCreate→appendable→攒批 |
| 判序核心 | tsdb/head_append.go:694-731 | appendable：in-order/重复/OOO 窗口/TooOld/OutOfBounds |
| Commit | tsdb/head_append.go:1769 | log()写 WAL(:1783)→commitFloats(:1837)→updateMinMaxTime(:1858)→WBL(:1863) |
| WAL 记录 | tsdb/head_append.go:1116 | log()：series→samples→histograms 顺序 |
| in-order 写入 | tsdb/head_append.go:1904 | memSeries.append：preprocessor+s.app.Append |
| 切 chunk | tsdb/head_append.go:2038,2191 | appendPreprocessor、cutNewHeadChunk、nextAt 预测 |
| OOO 判定 | tsdb/head_append.go:722 | `t >= headMaxt-oooTimeWindow` 进 OOO |
| OOO 容器 | tsdb/ooo_head.go:27,37 | OOOChunk 未压缩切片、二分插入、ToEncodedChunks(:78) |
| OOO 写入 | tsdb/head_append.go:1867 | memSeries.insert、capMax=32（head.go:243） |
| stripe 锁 | tsdb/head.go:2403,2779,2394 | stripeSeries、ref & (size-1)、DefaultStripeSize=1<<14 |
| series 创建 | tsdb/head.go:2191,2201,2223 | getOrCreate、乐观创建、postings.Add |
| memSeries | tsdb/head.go:2888 | headChunks/mmappedChunks/ooo/state(nextAt,app,txs) |
| XOR 编码 | tsdb/chunkenc/xor.go:161,466 | Append 三段式、xorWrite（dod 分桶+前导零窗口） |
| 编码常量 | tsdb/chunkenc/chunk.go:26-34,65 | EncXOR/EncXOR2/…；chunk 上限 1024B |
| 倒排索引 | tsdb/index/postings.go:60,409,601 | MemPostings、Add、Intersect（多路归并求交 :649） |
| 截断 | tsdb/head.go:1250,1267,1299 | Truncate→truncateMemory→minValidTime.Store(mint) |
| GC | tsdb/head.go:1988,2453 | Head.gc（postings.Delete :2010、walExpiries :2015）、stripeSeries.gc |
| 查询隔离 | tsdb/isolation.go:184 | newAppendID/低水位，配合 memSeries.txs |
