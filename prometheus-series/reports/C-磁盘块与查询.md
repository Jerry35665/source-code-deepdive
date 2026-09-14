# 卷一 · 第 3 章：磁盘块（Block）的格式与读取

> 调研对象：prometheus/prometheus，commit `b0f312b`（2026-09-14）。所有行号以该 commit 为准，路径为仓库相对路径。
> 姊妹篇：B 报告《Head 内存块》讲的是"最近 2~3 小时活在内存里的数据"；本章讲这些数据被切走之后，在磁盘上变成什么、怎么被读回来。

---

## 1. 全景：block 目录布局

每个磁盘块是一个以 ULID 命名的目录（BlockMeta.ULID，`tsdb/block.go:166`），时间上覆盖一个连续、**不可变**的区间。目录里只有四样东西：

```
data/
├── 01ARZ3NDEKTSV4RRFFQ69G5FAV/          ← ULID 命名的块目录（meta.json 里可查）
│   ├── meta.json                        ← 块的"身份证"：时间范围/版本/压缩谱系
│   ├── index                            ← 倒排索引（符号表+Series 段+Postings，单文件）
│   ├── chunks/                          ← 样本数据，切成多个 512MB 顺序分片
│   │   ├── 000001
│   │   └── 000002
│   └── tombstones                       ← 删除墓碑（可选，无删除时不存在）
├── 01ARZ3N.../                          ← 下一个块
└── wal/ & chunks_head/                  ← Head 的领地（B 报告）
```

打开一个块就是打开四个 reader（`tsdb/block.go` `OpenBlock`，355-406 行）：

```go
// tsdb/block.go:365-390（节选）
meta, sizeMeta, err := readMetaFile(dir)          // 365 读 meta.json
cr, err := chunks.NewDirReader(chunkDir(dir), pool) // 370 mmap chunks/ 下全部分片
ir, err := index.NewFileReader(filepath.Join(dir, indexFilename), decoder) // 380 mmap index
tr, sizeTomb, err := tombstones.ReadTombstones(dir) // 386 整读 tombstones 进内存
```

### 1.1 meta.json：块的身份证

结构体 `BlockMeta`（`tsdb/block.go:164-181`）：`ulid`、`minTime`、`maxTime`、`stats`（样本/序列/chunk/墓碑计数，184-191 行）、`compaction`（`level`/`sources`/`parents`/`hints`，200-216 行）、`version`。要点：

- **版本校验**：`readMetaFile` 只认 `metaVersion1`（`tsdb/block.go:284-286`），版本不符直接拒绝打开——格式演进的第一道闸门。
- **原子写**：`writeMetaFile` 先写 `meta.json.tmp`、fsync，再 `fileutil.Replace` 原子改名（`tsdb/block.go:294-325`）。块的元数据永远处于"完整或不存在"二态，不会出现半截 JSON。
- **半开区间**：块的 `[MinTime, MaxTime)` 是半开的（`OverlapsClosedInterval`，`tsdb/block.go:750-754`）；而单个 chunk 是闭区间 `[MinTime, MaxTime]`。这解释了 B 报告提过的一个细节：Head 落盘时 maxt 要 +1（`tsdb/blockwriter.go:99-101`）。

### 1.2 打开即 mmap，读时零拷贝

`OpenBlock` 里没有任何"解析"动作：index 和 chunks 都是 `fileutil.OpenMmapFile` 直接映射（index 在 `tsdb/index/index.go:1005-1019`，chunks 在 `tsdb/chunks/chunks.go:641-674`）；tombstones 因为小，直接 `os.ReadFile` 进内存（`tsdb/tombstones/tombstones.go:190`）。真正的解析被推迟到第一次查询时——这是"打开快、查询按需付费"的设计。

---

## 2. index 格式专节：倒排索引的落地

index 是块内**唯一**的索引文件，魔数 `0xBAAAD700` + 1 字节版本号开头（`tsdb/index/index.go:41-43`，写入在 `writeMeta` 425-431 行），尾部是 TOC。整体布局（`tsdb/docs/format/index.md:6-34`）：

```
┌ magic 0xBAAAD700 <4B> ┬ version <1B> ┐
│ Symbols   符号表（排序去重的字符串字典）│
│ Series    序列段（16B 对齐，正排）      │
│ Postings  倒排表（label→series 引用）  │
│ Postings Offset Table 倒排偏移表       │
│ TOC       目录（6 个 uint64 + CRC32）  │
└──────────────────────────────────────┘
```

### 2.1 TOC：从文件尾反推全貌

`TOC` 结构是 6 个 uint64 偏移：Symbols / Series / LabelIndices / LabelIndicesTable / Postings / PostingsTable（`tsdb/index/index.go:171-178`）。读取时取**文件末尾 52 字节**（`indexTOCLen = 6*8+4`，index.go:689），先验 CRC32 再解出 6 个偏移（`NewTOCFromByteSlice`，181-203 行）。即：读 index 永远从文件尾部开始，一次定位所有段。

### 2.2 Symbols：字符串字典

符号表是排序去重的标签名/标签值字符串，Series 段里只存它的序号（uint32），大幅压缩索引体积（`tsdb/docs/format/index.md:41-46`）。磁盘格式：`<len 4B><#symbols 4B><uvarint len + bytes>...<CRC32>`；写入时先占位 "alenblen" 8 字节，写完回填长度与计数（`startSymbols` index.go:530-535，`finishSymbols` 552-595 行，CRC 在 582 行 mmap 回读补算）。

读取端 `Symbols` 只把**每第 32 个符号的偏移**装进内存做跳表（`symbolFactor = 32`，index.go:1164；`NewSymbols` 1167-1191 行）：

```go
// tsdb/index/index.go:1193-1210（节选）
func (s Symbols) Lookup(o uint32) (string, error) {
    ...
    d.Skip(s.offsets[int(o/symbolFactor)])  // 1204 先跳到 1/32 抽样锚点
    for i := o - (o/symbolFactor*symbolFactor); i > 0; i-- {
        d.UvarintBytes()                     // 1206 最多再顺序走 31 个符号
    }
    ...
}
```

内存开销从 O(符号数) 降到 O(符号数/32)，单次 Lookup 最多线性走 32 个 uvarint。反查 `ReverseLookup` 用 `sort.Search` 在锚点数组上二分再顺序定位（index.go:1217-1258，二分在 1221 行）。

### 2.3 Series 段：16 字节对齐的正排

Series 段按标签集字典序存放每个序列。**每条序列 16 字节对齐，序列 ID = 文件偏移 / 16**（`seriesByteAlign = 16`，index.go:54；写入时对齐在 `AddSeries` 465-471 行）——这是 v2 格式的核心巧思：4 字节的 series ref 本来只能寻址 4GB，除以 16 后可寻址 64GB（写入端 64GB 上限检查在 `FileWriter.Write`，index.go:315-317）。

每条序列的载荷（写入 `Writer.AddSeries` 434-528 行，解码 `Decoder.Series` 1806-1877 行）：

```
<uvarint 标签数> (<uvarint32 名符号>, <uvarint32 值符号>)×N
<uvarint chunk 数>
<varint64 c0.mint> <uvarint64 c0.maxt-mint> <uvarint64 c0.ref>
<uvarint64 Δmint>  <uvarint64 Δmaxt>       <varint64 Δref>  ← 后续 chunk 全是增量
```

时间与 chunk ref 全部差分编码（写入 494-512 行，读取 1848-1875 行），一个 2h 块内一条序列通常只有 1 个 chunk，增量编码几乎零成本。**索引里存了每个 chunk 的 mint/maxt**，这让"时间剪枝"可以完全不碰 chunks 文件就完成（见 §5）。注意 Series 段入口不经过任何偏移表——postings 里的引用本身就是偏移，`Reader.Series` 只需 `offset = id * seriesByteAlign`（index.go:1468-1486，乘法在 1473 行）。

### 2.4 Postings 与偏移表：二分 + 顺序游走

Postings 段是若干"某 label 对 → 序列引用列表"的倒排表，raw 编码为 `<BE32 len><BE32 n><BE32 ref>×n`（`EncodePostingsRaw`，index.go:834-844；解码 `DecodePostingsRaw` 1772-1782 行，直接把底层 mmap 字节包成 `bigEndianPostings`，零拷贝）。

查找的钥匙是尾部的 **Postings Offset Table**：每条目 `<uvarint 2><uvarint name><uvarint value><uvarint64 offset>`，按 (name, value) 字典序排列（`writePosting` 写入临时文件时顺手记录，index.go:846-877；最终回填调整偏移在 `writePostingsOffsetTable` 598-667 行）。

打开 index 时（`newReader`，1021-1123 行），v2/v3 格式**并不**整表加载，而是每 32 个 value 抽样 1 个（外加每个 name 的首尾值），只把样本放进 `r.postings[name][]postingOffset` 内存 map（1075-1099 行，抽样条件 `valueCount%symbolFactor == 0` 在 1085 行）。

查询 `Postings(ctx, name, values...)`（index.go:1526-1606）的三级定位：

```go
// tsdb/index/index.go:1558-1578（节选）
slices.Sort(values)                       // 1558 排序后可顺序扫表
...
i := sort.Search(len(e), func(i int) bool { return e[i].value >= value }) // 1568 内存样本二分
if i > 0 && e[i].value != value { i-- }   // 1573 退到前一个锚点
if err := r.traversePostingOffsets(ctx, e[i].off, func(val string, postingsOff uint64) ... // 1578
```

即：内存二分锚点 → 从锚点在磁盘上顺序游走到目标 value（`traversePostingOffsets`，1490-1524 行，用缓存的 keylen 跳过 name 字段）→ 按偏移 mmap 直读 postings。单次查询的磁盘随机读被压缩到"一个锚点 + 短程顺序扫描"。

顺带一提：LabelValues 也是同一张表一次顺序遍历拿完（index.go:1364-1412），不必为每个 value 单独二分。

---

## 3. chunks 专节：切片文件与 mmap 零拷贝读

### 3.1 分片文件

chunks/ 下是 `%0.6d` 顺序命名的分片文件（`segmentFile`，`tsdb/chunks/chunks.go:748-750`），每个分片头部 8 字节：**大端**魔数 `0x85BD40DD` + 1 字节版本(=1) + 3 字节 padding（`MagicChunks` chunks.go:34；`SegmentHeaderSize` 41 行；写入 460-464 行，读校验 619-637 行）。

两个容易混淆的尺寸：

| 场景 | 默认分片大小 | 出处 |
|---|---|---|
| 磁盘块 chunks/ | **512 MiB** | `DefaultChunkSegmentSize`，chunks.go:300 |
| Head chunks_head/ mmap 段 | 128 MiB | `MaxHeadChunkFileSize`，chunks/head_chunks.go:59 |

写满即切新分片：`WriteChunks` 按批估算大小决定切割点（chunks.go:480-539），`cutSegmentFile` 用 `fileutil.Preallocate` 预分配再截断（chunks.go:450-454，截断在 `finalizeTail` 378-385 行）。

### 3.2 chunk 的盘上格式与 BlockChunkRef

每个 chunk 落盘为：`<uvarint 数据长><1B 编码><data><CRC32-4B>`（写入 `writeChunks` 544-577 行；格式文档 `tsdb/docs/format/chunks.md:30-34`）。写入时立刻生成引用：

```go
// tsdb/chunks/chunks.go:553
chk.Ref = ChunkRef(NewBlockChunkRef(seq, uint64(w.n)))  // 分片号<<32 | 分片内偏移
```

`BlockChunkRef` 高 4 字节是分片序号、低 4 字节是 chunk 在分片内的起始偏移（chunks.go:100-111）。这个 64 位值存进 index 的 Series 段，就是 index 与 chunks 两个文件之间**唯一的桥**。

### 3.3 mmap 读：零拷贝直达样本

读取端 `ChunkOrIterable`（chunks.go:686-724）全程在 mmap 字节上滑动，没有一次 `read()` 系统调用：

```go
// tsdb/chunks/chunks.go:687-723（节选）
sgmIndex, chkStart := BlockChunkRef(meta.Ref).Unpack()  // 687 拆 64 位引用
c := sgmBytes.Range(chkStart, chkStart+MaxChunkLengthFieldSize) // 700 mmap 切片
chkDataLen, n := binary.Uvarint(c)                       // 701 读 uvarint 长度头
...
if err := checkCRC32(sgmBytes.Range(chkEncStart, chkDataEnd), sum); ... // 716 CRC 校验
chkData := sgmBytes.Range(chkDataStart, chkDataEnd)      // 720 数据仍是 mmap 切片
chk, err := s.pool.Get(chunkenc.Encoding(chkEnc), chkData) // 722 包成 XOR chunk 等
```

page cache 即查询缓存：热数据第二次读不再碰磁盘；`pool.Get` 对 XOR chunk 只包一层 header 不复制数据。读 Head 落盘前的 mmap 段时是同一套思路（B 报告的 `head_chunks.go`）。

---

## 4. tombstones 专节：墓碑的区间格式与过滤

块不可变，删除只能"标记"。标记存在块根目录的 `tombstones` 文件里（`TombstonesFilename`，`tsdb/tombstones/tombstones.go:34`）：

- 头部：大端魔数 `0x0130BA30`（4B，tombstones.go:38, 100 行）+ 1 字节版本(=1)；
- 主体：N 条记录，每条 `<uvarint64 seriesRef><varint64 mint><varint64 maxt>`（`Encode` 142-154 行）；
- 尾部：全文件 CRC32（读时校验在 `ReadTombstones` 208-215 行）。

注意编码是**扁平三元组流**，同一 series 的多个区间就是多条记录，读取后归并进内存 map（`Decode` 158-180 行 → `MemTombstones`）。文件不存在不算错误——`ReadTombstones` 对 `IsNotExist` 返回空墓碑（192-194 行）。

**写入路径**：`Block.Delete` 按匹配器选序列、把重叠 chunk 的区间 clamp 后加入墓碑，再 `tombstones.WriteFile` + 回写 meta.json（`tsdb/block.go:615-680`，WriteFile 调用在 669 行）。真正物理清除靠 `CleanTombstones` 重写整个块（block.go:686-707）。

**内存归并**：`Intervals.Add` 保持区间集有序、不重叠，用 `sort.Search` 找到重叠邻域后原地合并（tombstones.go:350-381）——查询前先把墓碑集合压成最小形态。

**查询过滤在两个层级**（细节见 §5）：

1. chunk 级：整段被删的 chunk 直接从结果剔除——`Interval{Mint: chk.MinTime, Maxt: chk.MaxTime}.IsSubrange(intervals)`（`tsdb/querier.go:628`）；
2. 样本级：部分重叠的 chunk 交给 `DeletedIterator`，逐样本跳过落在删除区间内的点（querier.go:1338-1350 的 `Next`，用 `tr.InBounds(ts)` 判定）。

查询范围外的部分也"伪装"成墓碑来裁剪：`intervals.Add({MinInt64, mint-1})` 与 `{maxt+1, MaxInt64}`（querier.go:648-653）——裁剪与删除统一成一个机制，非常优雅。

---

## 5. 查询专节：块内剪枝与跨块合并

（跨块/head 合并的完整图景留给 E 报告，这里只讲块侧。）

**第一层剪枝在 DB 层**：`DB.Querier` 只为 `OverlapsClosedInterval(mint, maxt)` 的块创建 querier（`tsdb/db.go:2585-2589`）——meta.json 的 MinTime/MaxTime 让"这个块与查询无关"的判断是 O(1) 的。

**第二层是索引求值**：`selectSeriesSet` 先 `PostingsForMatchers` 把 matchers 编译成 postings 的交并差（`tsdb/querier.go:188-220`；编译器 270-416 行）。要点：等值与集合匹配走 `ix.Postings` 快路径（querier.go:418-436）；负匹配器转成 `Without` 减法；`Intersect` 用多路 Seek 跳跃求交（`tsdb/index/postings.go:601-682`），`Merge` 用 loser tree 归并去重（postings.go:685-724）。纯元数据查询（`hints.Func == "series"`）直接挂 NopChunkReader，一个样本都不读（querier.go:213-215）。

**第三层在序列游标**：`blockBaseSeriesSet.Next`（querier.go:582-661）对每条序列：

```go
// tsdb/querier.go:621-631（节选）
for _, chk := range b.bufChks {
    if chk.MaxTime < b.mint { continue }   // 622 时间剪枝：只看 index 里的 mint/maxt
    if chk.MinTime > b.maxt { continue }   // 625
    if (tombstones.Interval{Mint: chk.MinTime, Maxt: chk.MaxTime}.IsSubrange(intervals)) {
        continue                           // 628 整段被墓碑覆盖的 chunk 剔除
    }
    chks = append(chks, chk)
}
```

全程没有触碰 chunks 文件。只有存活下来的 chunk 才在 `populateWithDelGenericSeriesIterator.next`（querier.go:721-774）里经 `ChunkOrIterable`（747 行）真正读盘；部分删除的 chunk 再包一层 `DeletedIterator`（765-772 行）。

**跨块合并**：DB 把每个块的 querier 与 head querier 打包给 `storage.NewMergeQuerier(..., ChainedSeriesMerge)`（db.go:2645-2653）。同一序列如果同时活在两个块（例如 2h 块与它的 6h 上层块在 compaction 窗口内共存——实际上 compaction 保证了时间不重叠，这里主要用于 head + 块 + OOO head 的拼接），由 `ChainedSeriesMerge` 垂直拼接成一条序列。块间时间不重叠这一不变式，正是合并可以做到 O(序列数) 而非 O(样本数×块数) 的前提。

---

## 6. 设计动机

**为什么 2 小时一块？** `DefaultBlockDuration = 2h`（`tsdb/db.go:55-56`，Min/MaxBlockDuration 默认都取它，87-88 行）；compaction 层级按 3 倍指数增长：`ExponentialBlockRanges(min, 10, 3)` 生成 [2h, 6h, 18h, 54h, …]（`tsdb/compact.go:41-50`，调用在 db.go:982-986）。2h 的取舍是三边的平衡：太小则块数爆炸、index 打开成本（每块全量建 Symbols 锚点表）被反复支付、上层 compaction 频繁；太大则 retention/删除的最小粒度过粗、Head 单次落盘（head compaction）时间过长、内存峰值高。2h 也让"数据先落盘为 2h 块、后台再合并成 6h/18h 块"的 LSM 式漏斗有了自然的节奏。

**为什么 index 与 chunks 分离？** 三个原因。其一，访问模式不同：索引求值是"点查+短程扫描"（postings、series 元数据），样本读取是"按 ref 顺序流式"，mmap 单文件各自的 page cache 友好度完全不同。其二，引用设计解耦：index 用 4 字节 series ID（×16 寻址），chunks 用 (分片号, 偏移) 8 字节 ref，二者可独立增长/重写——`CleanTombstones` 重写样本时 index 结构照样复用逻辑。其三，块级去重/合并时 chunks 可以硬链接拷贝（`Block.Snapshot`，`tsdb/block.go:710-747`），快照近零成本。

**为什么 meta.json 是"块的身份证"？** 它是唯一描述"这个目录是什么"的文件：打开块前先校验 version=1（block.go:284）；DB 重载块列表、规划 compaction、判断查询相关性，全部只依赖 meta.json 的 minTime/maxTime/compaction 谱系，无需打开 index/chunks。原子写（tmp + Replace，block.go:294-325）保证它不会处于中间态，因此"meta.json 存在且合法" = "块可用"，这是崩溃一致性的锚点。

**不可变块的红利。** 块一旦落盘永不修改，于是：① 无并发控制——`startRead` 只是一个 WaitGroup 计数（block.go:455-464），读多线程无锁；② 缓存永远有效——mmap page cache、Symbols 锚点、postings 抽样表都可在 Open 时一次性构建；③ 备份/快照 = 硬链接目录；④ 删除 = 墓碑延迟到下次重写（`CleanTombstones`），写放大被摊销；⑤ 压缩格式可以激进（差分、16B 对齐），因为永远不需要就地更新。代价是删除/更新被延迟可见——这正是墓碑机制存在的理由。

---

## 7. FAQ 与深挖

### FAQ

1. **Q: 一个块的 index 文件有多大上限？** A: 64GiB。`FileWriter.Write` 里 `pos > 16*math.MaxUint32` 即报 `ErrIndexExceeds64GiB`（tsdb/index/index.go:315-317），根源是 v2 的 4 字节 series ref × 16 字节对齐。
2. **Q: series ID 为什么是"偏移/16"？** A: `AddSeries` 写每条序列前补齐到 16 字节边界（index.go:465-471），postings 里只需存 `offset/16` 的 4 字节 ID；读取时 `id * seriesByteAlign` 还原偏移（index.go:1473）。
3. **Q: 查询 `{__name__="up"}` 到底读了几次磁盘？** A: 理想情况：Open 时已 mmap（0 次 syscall），查询 = 偏移表锚点游走（顺序 page cache 命中）+ postings mmap 直读 + chunk mmap 直读。冷页时才产生缺页 IO。
4. **Q: chunks 分片为什么默认 512MB，Head 却是 128MB？** A: 块分片 512MB（chunks.go:300）减少长块（上层 compaction 产物）的文件数；Head 的 mmap 段 128MiB（head_chunks.go:59）是因为它 2h 就要truncate+换新，且 mmap 段越多 Head 截断越快。
5. **Q: 墓碑文件什么情况下不存在？** A: 块从未执行过 `Delete`（API 删除或 retention 之外的删除请求）。`ReadTombstones` 把文件缺失视为空墓碑集（tombstones.go:192-194）。
6. **Q: meta.json 的 compaction.parents 和 sources 有什么用？** A: sources 是参与合并的源 head 块 ULID，parents 是直接来源块的 (ULID, min, max) 描述（block.go:200-216）；运维据此追溯块的谱系，也用于去重保护。
7. **Q: 查询命中已压缩块时会不会读到旧块？** A: DB 重载块列表时以 meta.json 为准整体替换 `db.blocks`（`reloadBlocks`）；旧块的 reader 通过 `pendingReaders` WaitGroup 排空后才 Close（block.go:409-421），在途查询不受影响。
8. **Q: Label Index / Label Offset Table 段还在用吗？** A: 不再使用（docs/format/index.md:133, 188 明确标注 "no longer used"），但磁盘布局仍保留这两段占位，TOC 仍有其偏移。
9. **Q: 块与块时间重叠怎么办？** A: 正常 compaction 保证不重叠；加载到重叠块时 DB 会告警（db.go:815-816）并走垂直合并路径（overlapping compaction，详见 E 报告）。
10. **Q: 为什么 tombstones 读进内存而不是 mmap？** A: 体量小（三元组流）且查询时每条序列都要 `Get(ref)`，map 随机访问远快于盘上查找；代价是块打开时整读一次（tombstones.go:190）。

### 深挖

1. **postings 偏移表抽样因子 32 的权衡**：`symbolFactor=32` 同时控制 Symbols 锚点密度与 postings 偏移表抽样（index.go:1164, 1085）。把它调大可省内存但每次查找盘上游走更长；符号表体量可通过 `prometheus_tsdb_symbol_table_size_bytes` 观测（tsdb/db.go:408，Block.GetSymbolTableSize 上报，block.go:490-493）。
2. **`traversePostingOffsets` 的 keylen 缓存**（index.go:1498-1507）：同一 (name) 下所有条目的 `keycount+name` 字节长度相同，解析一次后用 `d.Skip(skip)` 跳过，避免反复 uvarint 解码 name。
3. **XOR2 编码的联合控制前缀**（docs/format/chunks.md:97-133）：新编码把时间戳 dod 与"值是否变化"合成一个字节对齐的控制前缀，常见 dod（0、±小值）落在单字节内，解码分支更 cache 友好；由 `storage.tsdb.chunk_encoding.floats` 配置选择。
4. **`DeletedIterator` 的区间前移优化**（querier.go:1320-1327）：`Seek` 中 `ts > itv.Maxt` 时直接 `it.Intervals = it.Intervals[1:]` 弹出已越过区间，长期查询的墓碑过滤接近 O(存活样本)。
5. **BlockChunkRef 与 compaction 的相互作用**：块内 chunk ref 编码了 (分片号, 偏移)，因此上层 compaction 合并块时**必须**重写 index 里的 chunk ref（分片布局变了）；这也是 compaction 必须重写 index 而非只搬 chunks 的形式原因。

---

## 写作要点速查表

| # | 关键点 | 位置 |
|---|---|---|
| 1 | meta.json 文件名/原子写 | tsdb/block.go:256, 291-326 |
| 2 | OpenBlock 四 reader 装配 | tsdb/block.go:355-406 |
| 3 | 块时间区间半开 [MinT, MaxT) | tsdb/block.go:750-754 |
| 4 | index 魔数 0xBAAAD700 / TOC 结构 | tsdb/index/index.go:41, 171-203 |
| 5 | TOC 取文件尾 52 字节 | tsdb/index/index.go:689, 181-203 |
| 6 | series 16B 对齐，ID=offset/16 | tsdb/index/index.go:54, 465-471 |
| 7 | Series 段 chunk 差分编码 | tsdb/index/index.go:494-512（写），1806-1877（读） |
| 8 | symbolFactor=32 锚点抽样 | tsdb/index/index.go:1164, 1179-1186, 1085 |
| 9 | Postings 查询三级定位（排序→二分→游走） | tsdb/index/index.go:1526-1606（1568 二分） |
| 10 | postings raw 编码 <BE32 len><BE32×n> | tsdb/index/index.go:834-844 |
| 11 | chunks 魔数 0x85BD40DD / 8B 头 | tsdb/chunks/chunks.go:34, 41 |
| 12 | 块分片默认 512MiB | tsdb/chunks/chunks.go:300 |
| 13 | BlockChunkRef = 分片号<<32 \| 偏移 | tsdb/chunks/chunks.go:100-111, 553 |
| 14 | ChunkOrIterable mmap 零拷贝读 | tsdb/chunks/chunks.go:686-724 |
| 15 | 墓盘格式 三元组流 + CRC | tsdb/tombstones/tombstones.go:142-154, 189-227 |
| 16 | Intervals.Add 有序合并 | tsdb/tombstones/tombstones.go:350-381 |
| 17 | 块内序列游标：时间剪枝+墓碑剔除 | tsdb/querier.go:582-661（622-631） |
| 18 | trim 伪装成墓碑区间 | tsdb/querier.go:648-653 |
| 19 | PostingsForMatchers 交并差编译 | tsdb/querier.go:270-416 |
| 20 | 2h 默认块长 / 3 倍指数层级 | tsdb/db.go:55-56；tsdb/compact.go:41-50；tsdb/db.go:982-986 |
| 21 | DB.Querier 块筛选 + MergeQuerier | tsdb/db.go:2579-2653 |
