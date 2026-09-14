# D 章：WAL、Checkpoint 与 Compaction —— 从易失内存到持久块的完整链路

> 源码版本：prometheus/prometheus @ commit `b0f312b`（2026-09 快照，master 分支）。所有行号以该 commit 为准。
> 说明：本版本中压缩器代码位于 `tsdb/compact.go`（而非旧版的 `tsdb/compact/` 子目录），WAL 位于 `tsdb/wlog/`。

## 1. 全景：WAL → Head → compact → blocks 的生命周期

```
 写入路径 (B 章)                      后台/启动路径 (本章)
 ─────────────────                   ────────────────────────────────────────────────
 Appender.Commit()
   │  ①先编码并写入 WAL 记录           启动时: db.open()
   │    (series→samples→exemplars)      ├─ head.Init(): 重放 chunk snapshot / mmap chunks
   ▼                                    │   └─ checkpoint.N → 段 000000..NNN 逐条重放进 Head
 Head(内存 + mmap chunks) ◄─────────────┘
   │
   │  ②每 2min: head.truncateMemory()   内存裁剪(旧 chunk GC)
   │  ③compactable(): Max-Min > chunkRange*3/2 → db.Compact()
   │      ├─ compactor.Write(head视图)  ──► 写出块: ULID.tmp-for-creation/
   │      │     chunks/(512MB 段) + index + meta.json + tombstones
   │      │     └─ fsync 目录后 rename ──► ULID/        (原子发布)
   │      ├─ reloadBlocks(): 换入新块, 标记旧块 deletable
   │      ├─ head.truncateMemory(): 释放已落块内存
   │      └─ head.truncateWAL():  对前 2/3 段做 Checkpoint
   │              checkpoint.N/{000000..} 收缩版 WAL(仅保留存活 series)
   │              └─ wal.Truncate(last+1): 删除旧段; 删除更旧 checkpoint
   ▼
 blocks/(时间分区目录)
   │  ④compactBlocks(): Plan() 选块 → Compact() 纵向/横向合并 → 更大块
   │  ⑤retention: 超时/超容量块 → rename .tmp-for-deletion → 删除
   ▼
 磁盘上的持久时间分区(每块 [mint,maxt) 不重叠, 除 OOO 块)
```

关键分工：**WAL 只负责"块窗口内"（约 2–3 小时）的崩溃恢复；一旦数据落成块，WAL 中对应段就被 Checkpoint+Truncate 丢弃**。两者是接力而非冗余。

## 2. WAL 格式专节

### 2.1 segment 与 page

- WAL 目录下是编号递增的段文件 `00000000`、`00000001`…（`%08d` 命名：`tsdb/wlog/wlog.go:508-510`）；默认段大小 **128MB**（`DefaultSegmentSize`，`tsdb/wlog/wlog.go:41`）。
- 段内按 **32KB 页** 写入（`pageSize`，`tsdb/wlog/wlog.go:42`），页是批量落盘的单位；单条记录超过页大小时会被拆成多个片段（fragment）分页写入（`tsdb/wlog/wlog.go:52-55` 注释）。
- **记录永不跨段**：写不下就切新段。这保证整段可安全截断，且"撕裂写"（torn write）只影响最近一个段（`tsdb/wlog/wlog.go:177-181` 的 WL 类型注释）。判断逻辑在 `log()`：`tsdb/wlog/wlog.go:707-714`。
- 段文件名必须连续，否则 `listSegments` 直接报错 "segments are not sequential"（`tsdb/wlog/wlog.go:909-913`）。
- 段切换 `nextSegment`：flush 当前页 → 创建下一段 → 旧段的 fsync+Close 异步丢给 actor goroutine（`tsdb/wlog/wlog.go:530-565`）。
- 注意：**每次 Commit 并不 fsync**。`Log()` 只把页写到文件（write 系统调用），fsync 只发生在切段和 `Close()`（`tsdb/wlog/wlog.go:822-834, 863`）。崩溃时最多丢掉页缓存里未刷盘的若干条，恢复语义靠"最后一条记录不完整则丢弃"兜底。

### 2.2 记录编码：头 7 字节 + 类型位

首字节格式（`tsdb/wlog/wlog.go:611-618`）：

```
[3 bits unallocated] [1 bit zstd] [1 bit snappy] [3 bit record type]
snappyMask=1<<3, zstdMask=1<<4, recTypeMask=0b111
```

片段类型 5 种（`tsdb/wlog/wlog.go:622-628`）：`recPageTerm=0`（页尾填充）、`recFull=1`、`recFirst=2`、`recMiddle=3`、`recLast=4`。每片段头为 7 字节（`recordHeaderSize`，`tsdb/wlog/wlog.go:43`）：1 字节类型 + 2 字节大端长度 + 4 字节 CRC32-**Castagnoli**（表初始化在 `tsdb/wlog/wlog.go:50`，写入在 `tsdb/wlog/wlog.go:751-754`）。

压缩：WAL 记录可选 snappy/zstd（默认关闭，`WALCompression: compression.None`，`tsdb/db.go:92`）。压缩在 `log()` 入口做，且**压缩后不省字节就放弃压缩**（小记录 snappy 可能反而变大，`tsdb/wlog/wlog.go:685-702`）。

写入主循环 `log()`（`tsdb/wlog/wlog.go:675-781`）：按页剩余空间切片段 → 写头+数据 → 页满即 `flushPage`（`tsdb/wlog/wlog.go:583-609`）。片段循环核心（节选自 `tsdb/wlog/wlog.go:718-757`）：

```go
for i := 0; i == 0 || len(enc) > 0; i++ {
    p := w.page
    var (
        l    = min(len(enc), (pageSize-p.alloc)-recordHeaderSize)
        part = enc[:l]
        typ  recType
    )
    switch {
    case i == 0 && len(part) == len(enc): typ = recFull
    case len(part) == len(enc):           typ = recLast
    case i == 0:                          typ = recFirst
    default:                              typ = recMiddle
    }
    buf[0] = byte(typ)
    crc := crc32.Checksum(part, castagnoliTable)
    binary.BigEndian.PutUint16(buf[1:], uint16(len(part)))
    binary.BigEndian.PutUint32(buf[3:], crc)
    copy(buf[recordHeaderSize:], part)
```

`flushPage` 在强制清页时把 `p.alloc` 抬到页尾，剩余字节补零——这正是读端识别"页填充"的依据。

### 2.3 业务记录类型（record 包）

WAL 记录本体首字节是业务类型（`Decoder.Type`，读首字节判型：`tsdb/record/record.go:220-232`），常量表在 `tsdb/record/record.go:38-67`：

| Type | 值 | 含义 |
|---|---|---|
| Series | 1 | series 增量（ref+labels） |
| Samples | 2 | float 样本（ref,t,v） |
| Tombstones | 3 | 删除标记 |
| Exemplars | 4 | exemplar |
| MmapMarkers | 5 | OOO WBL 的 mmap 标记 |
| Metadata | 6 | 元数据（type/unit/help） |
| HistogramSamples/Float | 7/8 | 原生直方图 |
| CustomBuckets* | 9/10 | 自定义桶直方图 |
| SamplesV2 / HistV2 | 11/12/13 | 带 ST 的新编码 |

Series 记录体（`Encoder.Series`，`tsdb/record/record.go:887-896`）= 类型字节 + 每条 `BE64(ref)` + uvarint 标签数 + 逐个 `uvarintstr(name/value)`。

写端按固定顺序落记录：**series → metadata → floats → histograms → exemplars**（`headAppenderBase.log()`，`tsdb/head_append.go:1116-1202`；exemplar 必须在样本后，注释见 `tsdb/head_append.go:1188-1191`）。

### 2.4 读端校验（reader.go）

`Reader.Next` 逐片段读：跳过并校验页填充零字节（`tsdb/wlog/reader.go:86-111`，非零即 "unexpected non-zero byte in padded page"）；长度上限 `pageSize-recordHeaderSize`（`tsdb/wlog/reader.go:123-125`）；CRC 不符即报错（`tsdb/wlog/reader.go:135-137`）；片段序列合法性 `validateRecord`（`tsdb/wlog/reader.go:138-140`）；到 `recFull/recLast` 才解压返回完整记录（`tsdb/wlog/reader.go:142-145`）。

**撕裂检测**：EOF 时若最后片段是 `recFirst/recMiddle`，报 "last record is torn"（`tsdb/wlog/reader.go:52-55`）——这就是崩溃后"最后一条未写完的记录被自动丢弃"的实现点。`Err()` 把错误包装为带段号+偏移的 `CorruptionErr`（`tsdb/wlog/reader.go:157-174`），供 Repair 定位。

## 3. Checkpoint 专节：收缩旧段

`wlog.Checkpoint(logger, w, from, to, keep, mint, ...)`（`tsdb/wlog/checkpoint.go:112`）由 `Head.truncateWAL` 调用（`tsdb/head.go:1677`）。

### 3.1 触发策略（head.go 侧）

`truncateWAL`（`tsdb/head.go:1644-1714`）：
1. 先 `NextSegment()` 开新段——让低写入量实例也不会积累过多 WAL（`tsdb/head.go:1660-1662`）；`last--` 保证最新段不进 checkpoint（`tsdb/head.go:1663`）。
2. 只对**前 2/3 的段**做 checkpoint：`last = first + (last-first)*2/3`，注释明言"默认 2h 块下，WAL 约保留 3 小时数据"（`tsdb/head.go:1667-1671`）。节选（`tsdb/head.go:1658-1677`）：

```go
// Start a new segment, so low ingestion volume TSDB don't have more WAL than
// needed.
if _, err := h.wal.NextSegment(); err != nil { ... }
last-- // Never consider last segment for checkpoint.
...
// The lower two thirds of segments should contain mostly obsolete samples.
// If we have less than two segments, it's not worth checkpointing yet.
// With the default 2h blocks, this will keeping up to around 3h worth
// of WAL segments.
last = first + (last-first)*2/3
...
wlog.Checkpoint(h.logger, h.wal, first, last, h.keepSeriesInWALCheckpointFn(mint), mint, ...)
```
3. Checkpoint 成功后 `wal.Truncate(last+1)` 删旧段（失败仅记日志，下次重来，`tsdb/head.go:1684-1689`），再 `DeleteCheckpoints` 清更旧的 checkpoint（`tsdb/head.go:1701`）。

### 3.2 Checkpoint 本体

- 目录名 `checkpoint.N`（N=末段号，`CheckpointDir`，`tsdb/wlog/checkpoint.go:443-445`），内部**就是 WAL 段格式**，因此重放时可用同一套 reader 拼接读取（`tsdb/wlog/checkpoint.go:108-111` 注释）。
- 先把上一个 checkpoint 与 `[from,to]` 段拼成一个流（`tsdb/wlog/checkpoint.go:119-141`），写入 `checkpoint.N.tmp`，成功后 fsync 目录并 `fileutil.Replace` 原子改名（`tsdb/wlog/checkpoint.go:416-435`）。
- 过滤规则：series 按 `keep(ref)` 保留；samples/histograms/exemplars 按 `T >= mint`；tombstone 随 series 一起删或区间整体过期才删（`tsdb/wlog/checkpoint.go:318-341`）；metadata 只保留每条 series 的**最新一条**（`latestMetadataMap`，`tsdb/wlog/checkpoint.go:360-376`，最后统一回写 `tsdb/wlog/checkpoint.go:405-414`）；未知类型（未来版本）直接跳过（`tsdb/wlog/checkpoint.go:377-380`）。
- 攒批 1MB 才写一次（`tsdb/wlog/checkpoint.go:386-392`）。
- **为什么必须保留 series 记录**：samples 记录只含 ref（8 字节整数），不含标签；一旦 checkpoint 丢掉仍被 Head 引用的 series 记录，重放时这些样本就成"无主样本"，只能丢弃。`keep` 回调来自 Head：series 在 Head 中存在、或其 `walExpiries` 到期时间 ≥ mint 都要保留（`keepSeriesInWALCheckpointFn`，`tsdb/head.go:1630-1641`）。注释还强调 keep 的结果在 Checkpoint 运行期间必须稳定（由 chunkSnapshotMtx 串行化保证，`tsdb/wlog/checkpoint.go:99-106`）。
- **checkpoint 读到损坏是硬错误**，不可修复——Head 无法知道丢了哪些 series 记录（`tsdb/wlog/checkpoint.go:394-398`）。

## 4. 恢复专节：重放与损坏截断

### 4.1 启动重放（Head.Init）

`Head.Init`（`tsdb/head.go:738-996`，由 `db.open` 在 `tsdb/db.go:1210` 调用）流程：
1. （可选）chunk snapshot 快速恢复（`EnableMemorySnapshotOnShutdown`，`tsdb/head.go:761-805`；snapshot 写入在 `tsdb/head_wal.go:1444`）。
2. mmap chunks 重放；损坏则 `removeCorruptedMmappedChunks` 丢弃、交给 WAL 补（`tsdb/head.go:819-836`）。
3. `wlog.LastCheckpoint` 找最近 checkpoint（`tsdb/head.go:850-853`），`wlog.Segments` 找末段号（`tsdb/head.go:856-859`）。
4. 先重放 checkpoint，再从 `startFrom` 到 `endAt` 逐段重放 WAL（`tsdb/head.go:887-943`）；之后重放 OOO 的 WBL（`tsdb/head.go:947-972`）。
5. `defer h.gc()`：重放完清过期数据（`tsdb/head.go:744`；`gc` 在 `tsdb/head.go:1988`）。

### 4.2 并行重放与错误上抛

`loadWAL`（`tsdb/head_wal.go:81`）：单 goroutine 解码，按 `ref % concurrency` 分发给多个 worker 并行重建 chunk（`tsdb/head_wal.go:94-132`；worker 主体 `processWALSamples`，`tsdb/head_wal.go:775-869`，早于 `mmMaxTime` 的样本直接跳过，`tsdb/head_wal.go:814-816`）。解码失败打包成带段号/偏移的 `CorruptionErr`（如 `tsdb/head_wal.go:167-172`）。样本引用了不存在的 series 只计数告警、不致命（`tsdb/head_wal.go:503-520`）——这正对应"checkpoint 已正确收缩"的正常情形；真正的读错误在 `tsdb/head_wal.go:499-501` 上抛。

### 4.3 损坏自动修复（Repair）

`db.open` 捕获 `head.Init` 的错误，调 `wal.Repair(initErr)`（`tsdb/db.go:1210-1225`）。`WL.Repair`（`tsdb/wlog/wlog.go:400-505`）策略是**截断到最后一条完整记录**：
1. 删除损坏段**之后**的所有段（`tsdb/wlog/wlog.go:421-439`）——因为记录不跨段，后面段的内容建立在损坏段之上，不可信；
2. 把损坏段改名 `.repair`，新建干净段（`tsdb/wlog/wlog.go:445-457`）；
3. 重读损坏段，把 `Offset < cerr.Offset` 的记录逐条重新 `Log` 进新段（`tsdb/wlog/wlog.go:466-477`）；
4. 补零到页尾，删除 `.repair`，再建 `Segment+1` 段恢复写入（`tsdb/wlog/wlog.go:480-504`）。
注释解释了为什么不做"只丢撕裂记录"的精细模式：记录间有因果性（series 先于 samples），中间损坏后所有后续记录都不可信（`tsdb/wlog/wlog.go:398-405`）。

另外，写端打开旧段时若发现最后页是撕裂的，先补零——读端会以"页尾之后出现垃圾"的形式把它判定为损坏（`OpenWriteSegment`，`tsdb/wlog/wlog.go:135-146`）。

## 5. Compaction 专节

### 5.1 块范围与"何时切 Head"

- 块时长默认 **2h**（`DefaultBlockDuration`，`tsdb/db.go:55-56`）；压缩层级范围 `ExponentialBlockRanges(2h, 10, 3)`：2h→6h→18h→…指数递增（`tsdb/db.go:981-985`，生成函数 `tsdb/compact.go:41-50`），超过 `MaxBlockDuration` 的层级被裁掉（`tsdb/db.go:1005-1010`）。
- Head 可压缩条件：跨度 > `chunkRange*3/2`（即 2h 块要等 3h 数据），`head.compactable()`，`tsdb/head.go:2143-2149`。
- 触发链：`db.run` 每 `BlockReloadInterval`（默认 1 分钟，`tsdb/db.go:68`）发 compact 信号（`tsdb/db.go:1280-1290`），消费端调 `db.Compact`（`tsdb/db.go:1316-1330`）。

### 5.2 Head → block（compactHead）

`db.Compact`（`tsdb/db.go:1519-1611`）优先做 Head 压缩：
1. `mint=head.MinTime()`，`maxt=rangeForTimestamp(mint, chunkRange)` 对齐到 2h 边界（`tsdb/db.go:1563-1564`）；
2. 包一层 `RangeHead`，`maxt-1` 因块区间是半开 `[mint,maxt)`（`tsdb/db.go:1566-1573`；RangeHead 定义 `tsdb/head.go:1799`，`BlockMaxTime()=MaxTime+1` 在 `tsdb/head.go:1852-1854`）；
3. `compactHead`：`compactor.Write(db.dir, head, min, BlockMaxTime, nil)` 写块 → `reloadBlocks` 换入 → 失败则删新块 → `head.truncateMemory` 释放内存（`tsdb/db.go:1747-1773`）；
4. 结束时（defer）`truncateWAL(lastBlockMaxt)` 回收 WAL（`tsdb/db.go:1530-1535`）。

### 5.3 计划：哪些块合并（Plan）

`LeveledCompactor.Plan`（`tsdb/compact.go:255-283`）→ `plan`（`tsdb/compact.go:285-344`，先把 stale/selected 标记块与普通块分类、不混编）→ `planClass`（`tsdb/compact.go:350-399`），优先级：
1. **时间重叠的块**优先纵合并 `selectOverlappingDirs`（OOO 补写导致，`tsdb/compact.go:366-369`，实现 `tsdb/compact.go:442-465`）；
2. 普通横向合并 `selectDirs`（`tsdb/compact.go:403-438`）：把块按 `splitByRange` 对齐分桶（`t0 = tr*(MinTime/tr)`，`tsdb/compact.go:471-508`），某桶在高层级范围内"铺满或全部位于最新块之前"且 ≥2 块才合并——避免过早压缩。`splitByRange` 的官方例子（`tsdb/compact.go:467-470` 注释）：块 `[0-10, 10-20, 50-60, 90-100]` 在 tr=30 下分成 `[0-10, 10-20]`、`[50-60]`、`[90-100]` 三桶，只有第一桶会被选（铺满 [0,30)）。**最后一个块被刻意排除**（`dms[:len(dms)-1]`），注释：给新块留一个完整块窗口做逐块备份（`tsdb/compact.go:370-373`）；
3. **墓碑 >5%** 的块单独重写（`tsdb/compact.go:382-396`）；`db.CleanTombstones` 走同类逻辑（`tsdb/db.go:2789`）。

### 5.4 写块的数据流：iter → merge → 写出

`Compactor.Compact`（`tsdb/compact.go:584-683`）读入各源块（已打开的复用，`tsdb/compact.go:611-627`），合并元数据 `CompactBlockMetas`（min/max 取并集、Level+1、记录 sources/parents，`tsdb/compact.go:512-580`），新块 ULID 由时间戳+随机数生成（`tsdb/compact.go:635`）。合并结果 0 样本时，源块全部标记 `Deletable` 并写回 meta（`tsdb/compact.go:640-659`）。

核心在 `write`（`tsdb/compact.go:760-871`）+ `PopulateBlock`（`tsdb/compact.go:895-1044`）：
- 每个源块产出 `BlockChunkSeriesSet`（限定 `[mint, maxt-1]`，`tsdb/compact.go:954-956`）；
- 多块时 `NewMergeChunkSeriesSet(sets, 0, mergeFunc)` 做按 labels 的**多路归并**，默认合并器 `storage.NewCompactingChunkSeriesMergerWithFloatEncoding(ChainedSeriesMerge)`（`tsdb/compact.go:980-985` 与 `218-221`）——与查询路径的垂直合并是同一套 merger（E 章查询复用点）；
- 逐 series：`chunkw.WriteChunks` + `indexw.AddSeries`，统计进 meta.Stats（`tsdb/compact.go:1012-1030`），chunk 归还池（`tsdb/compact.go:1032-1036`）。

### 5.5 原子落地与删除（对照系列模式 4）

`write` 的落盘序列（`tsdb/compact.go:761-868`）：
1. 先写 `ULID + ".tmp-for-creation"` 临时目录（后缀定义 `tsdb/db.go:66-68`，出错则 defer 里 `RemoveAll`，`tsdb/compact.go:768-770`）；
2. 写 chunks/（段默认 512MB，`chunks.DefaultChunkSegmentSize`，`tsdb/chunks/chunks.go:299-300`）、index、meta.json、空 tombstones（`tsdb/compact.go:787-843`）；
3. 显式 Close 写手（Windows 删除限制，`tsdb/compact.go:822-829`）→ fsync 临时目录（`tsdb/compact.go:845-857`）→ **`fileutil.Replace(tmp, dir)` 原子改名发布**（`tsdb/compact.go:865-868`）。
空块提前返回，临时目录被 defer 清掉（`tsdb/compact.go:831-834`）。

删除同样原子：`deleteBlocks` 先 `Replace(块, 块+".tmp-for-deletion")` 再 `RemoveAll`，注释言明防"删除中途崩溃留下半删块"（`tsdb/db.go:2332-2339`）。配合 `reloadBlocks` 的规则——**新块 meta 的所有 Parents 一律标记 deletable**，即使崩溃在"压缩成功但未删源块"之间，重启后也会续删（`tsdb/db.go:2083-2096`）。

### 5.6 保留策略（retention）

`reloadBlocks` 每轮计算 `blocksToDelete`（`tsdb/db.go:2080`）＝显式 `Deletable` 标记 ∪ `BeyondTimeRetention`（默认 15 天，`tsdb/db.go:89, 2246-2266`）∪ `BeyondSizeRetention`（百分比优先于绝对值，`tsdb/db.go:2270-2310`），随后统一走 `deleteBlocks`。

## 6. 设计动机

1. **为什么是 2h 块**：块窗口决定崩溃恢复重放量与查询必读内存量。2h=默认 chunkRange（`tsdb/db.go:55-56`），Head 聚到 3h 数据（compactable 阈值 `1.5*chunkRange`，`tsdb/head.go:2148`）才切，避免频繁小块；`selectDirs` 又"滞后一个块"启动合并，保留一个完整窗口的原始块供备份。
2. **WAL 与块的分工**：WAL 是"未成块数据"的重放日志，生命周期只有约 3h（truncateWAL 的 2/3 策略，`tsdb/head.go:1667-1671`）；块是自包含的不可变时间分区（chunks+index+meta）。WAL 换来的是 Commit 路径只有顺序写（无随机 IO）；块换来的是查询与保留策略只触碰分区目录，不需要重写历史。
3. **compaction vs LevelDB**：LevelDB 按 key 空间分层（L0→Ln，SSTable 键区间可重叠再合并）；Prometheus 按**时间**分区——块 `[mint,maxt)` 天然不重叠，横向合并只是"把相邻小时拼成更大小时"，几乎零重算；只有 OOO/回填造成的**纵向重叠**才需要真正的多路归并（`selectOverlappingDirs` + `mergeFunc`）。时间单调性还让 retention 变成 O(1) 的"删最老目录"，而 LSM 的 retention 需要全 key 空间扫描。
4. **为什么 checkpoint 保留 series 记录**：WAL 记录用 8 字节 ref 代替完整标签（`Encoder.Series` vs `Samples`），ref→labels 的映射只存在于 series 记录；checkpoint 是 WAL 的"有损压缩"，但映射必须保真，否则重放出的 Head 无法解释样本。
5. **原子性的两层**：文件级用 rename（tmp-for-creation/deletion），目录级用 fsync 父目录 + `fileutil.Replace`；元数据层面的"事务"则靠 meta.json 的 Parents/Deletable 字段 + 启动时 `reloadBlocks` 收敛（`tsdb/db.go:2083-2096`）——没有 WAL 的块世界，用幂等收敛代替日志。

## 7. FAQ 素材

1. **Q: WAL 段多大？为什么按页写？** A: 默认 128MB/段（`tsdb/wlog/wlog.go:41`），32KB/页（`:42`）；页化让写系统调用批量化，并让"页尾补零"成为识别撕裂的哨兵。
2. **Q: 崩溃时 WAL 会丢多少数据？** A: Commit 不 fsync（`tsdb/wlog/wlog.go:657-669` 无 sync 调用；fsync 仅在切段/关闭），掉电可能丢页缓存中未落盘记录；进程崩溃（OS 存活）不丢。
3. **Q: WAL 损坏会怎样？** A: 启动时 Repair 截断到最后完整记录，其后全部丢弃（`tsdb/wlog/wlog.go:400-505`）；checkpoint 内损坏则直接拒绝启动（`tsdb/wlog/checkpoint.go:394-398`）。
4. **Q: WAL 压缩默认开吗？** A: 默认 None（`tsdb/db.go:92`），可配 snappy/zstd；压缩反而变大时自动放弃（`tsdb/wlog/wlog.go:693-700`）。
5. **Q: Checkpoint 里为什么还有 samples？** A: 只对前 2/3 段做 checkpoint，`mint` 之后的样本仍会被重放；checkpoint 是"收缩"不是"清空"。
6. **Q: Head 什么时候切块？** A: 数据跨度超过 1.5 个块时长（`tsdb/head.go:2143-2149`），每分钟检查一次（`tsdb/db.go:1280-1290`）。
7. **Q: 块目录里有什么？** A: `chunks/`（512MB 段）、`index`、`meta.json`、`tombstones`（`tsdb/block.go:255-272`，`OpenBlock` 在 `:355`）。
8. **Q: 重叠块（乱序补采）怎么处理？** A: Plan 优先挑重叠组纵合并（`tsdb/compact.go:366-369`），合并器按 labels 归并去重排序（`:980-985`），metrics `prometheus_tsdb_vertical_compactions_total` 计数（`:117-120`）。
9. **Q: 删除数据（Delete API）怎么生效？** A: 写 tombstone，等块重写（墓碑>5% 触发，`tsdb/compact.go:382-396`）或 `CleanTombstones` 才物理删除。
10. **Q: 启动重放慢怎么办？** A: 三层加速：chunk snapshot（`tsdb/head.go:761-805`）、并行重放（`tsdb/head_wal.go:94-132`）、以及本版本新增的 fast-startup series state（`tsdb/head.go:861-881`）。

## 8. 深挖线索

1. **`fileutil.Replace` 的可移植性**：Windows 上 rename-over-exist 不可靠，块/检查点发布前都先 Close 临时目录句柄（`tsdb/compact.go:822-829, 845-863`）；Repair 也因 Windows 先显式 Close 再删 `.repair`（`tsdb/wlog/wlog.go:424-431, 484-491`）。
2. **multiRef 与 walExpiries**：checkpoint 之间同 ref 重复注册（段里旧 series 记录+新 series 记录）时，重放建立 `multiRef` 重映射（`tsdb/head.go:269-271`），并 `updateWALExpiry` 保住旧 ref 的 series 记录不被下次 checkpoint 丢掉（`tsdb/head.go:1620-1626`）——一个容易忽略的正确性细节。
3. **OOO WBL**：乱序样本写独立的 `wbl/` 目录（同一种段格式，`WblDirName`，`tsdb/wlog/wlog.go:44`），由 `compactOOOHead` 单独成块（`tsdb/db.go:1646-1743`），块 meta 带 `FromOutOfOrder` 提示，用于 `inOrderBlocksMaxTime` 区分（`tsdb/db.go:2461-2471`）。
4. **plan 的 hint 隔离**（新近改动 #18379）：from-stale-series / from-selected-series 块不与普通块混编，防止 hint 丢失后错误推进 WAL 重放截止点（`tsdb/compact.go:290-313` 注释）。
5. **LiveReader vs Reader**：`reader.go` 是启动重放用的整段读；`live_reader.go` 是远程写（read API tail）用的可逐字节追踪边界的读端（`tsdb/wlog/live_reader.go:135` 起），同一格式的两种消费方式。

## 9. 写作要点速查表

| 论断 | 位置 |
|---|---|
| WAL 段 128MB / 页 32KB / 片段头 7B | tsdb/wlog/wlog.go:41-43 |
| 记录不跨段的切段判断 | tsdb/wlog/wlog.go:707-714 |
| 首字节格式（snappy/zstd/type 位） | tsdb/wlog/wlog.go:611-618 |
| 片段类型 recFull/First/Middle/Last/PageTerm | tsdb/wlog/wlog.go:622-628 |
| CRC32-Castagnoli 写入与校验 | tsdb/wlog/wlog.go:751-754; tsdb/wlog/reader.go:135-137 |
| 页 flush 与页尾补零 | tsdb/wlog/wlog.go:583-609 |
| 撕裂最后记录判定 | tsdb/wlog/reader.go:47-60 |
| Repair=删后段+重放到损坏偏移 | tsdb/wlog/wlog.go:400-505 |
| WAL 业务类型常量表 | tsdb/record/record.go:38-67 |
| Commit 先 log() 后应用内存 | tsdb/head_append.go:1769-1790; log():1116-1202 |
| Checkpoint 主流程/keep 语义/硬错误 | tsdb/wlog/checkpoint.go:112, 192-208, 394-398 |
| truncateWAL 的 2/3 段策略 | tsdb/head.go:1644-1714（关键 :1667-1671） |
| Init 重放序：snapshot→mmap→checkpoint→段 | tsdb/head.go:738-996（:850-943） |
| 并行重放/未知 ref 容忍 | tsdb/head_wal.go:81-132, 503-520 |
| compactable 阈值 1.5*chunkRange | tsdb/head.go:2143-2149 |
| compactHead：Write→reload→truncateMemory | tsdb/db.go:1747-1773 |
| Plan 优先级：重叠→横向→墓碑 | tsdb/compact.go:350-399 |
| 合并数据流 MergeChunkSeriesSet | tsdb/compact.go:895-1044（:980-985） |
| 块原子发布 tmp-for-creation→Replace | tsdb/compact.go:761-868（:866） |
| retention（时间/容量）与原子删除 | tsdb/db.go:2246-2310, 2315-2344 |
