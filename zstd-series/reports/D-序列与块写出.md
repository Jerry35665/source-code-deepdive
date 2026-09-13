# 第五章 序列与块写出:匹配找到之后,字节怎么落盘

> 本系列第五篇之第 5 章(D)。源码:facebook/zstd,commit `d79e723`(2025-11 shallow clone 时点),所有 `文件:行号` 均为仓库相对路径。
> 前一章(C)讲"怎么找到匹配"(各策略匹配查找器);本章讲匹配结果的"后半程":seqStore 中间表示 → 直方图统计 → 熵表类型决策 → 建表 → 字面量 Huffman → 序列 FSE 位流 → 块头,以及超级块(targetCBlockSize)这一条支线。

---

## 1. 全景:从 seqStore 到块字节的管道

匹配查找器(fast/doubleFast/lazy/opt)不停扫描,只做一件事:往 `SeqStore_t` 里追加序列。真正"写块"的是这条固定管道。

### 1.1 中间表示:SeqDef 与 SeqStore_t

每条序列被压成 8 字节的定长结构(zstd_compress_internal.h:85-89):

```c
typedef struct SeqDef_s {
    U32 offBase;   /* offBase == Offset + ZSTD_REP_NUM, or repcode 1,2,3 */
    U16 litLength;
    U16 mlBase;    /* mlBase == matchLength - MINMATCH */
} SeqDef;
```

`offBase` 是一个 sum-type(zstd_compress_internal.h:744-748):值 1/2/3 表示"复用 repcode 1/2/3",值 ≥4 表示真实偏移(= offset+3)。这样 repcode 匹配和真实距离匹配共用一个字段,后续 `ZSTD_updateRep` 才能统一记账。

序列缓冲 SeqStore_t 分四条平行数组(zstd_compress_internal.h:98-115):`sequences`(SeqDef 数组)、`litStart/lit`(字面量字节池,由 `ZSTD_storeSeq` 用 wildcopy 拷入,zstd_compress_internal.h:818-829)、以及三条符号码表 `llCode/mlCode/ofCode`。注意 SeqDef 里 litLength/mlBase 只有 U16,超过 65535 的"超长字面量/匹配"靠 `longLengthType + longLengthPos` 单槽位修补:写入时记 `ZSTD_llt_literalLength/matchLength`(zstd_compress_internal.h:766-785),读回时 `ZSTD_getSequenceLength` 加回 0x10000(zstd_compress_internal.h:126-140)。整个块只允许一处超长——对 128KB 的块够用。

### 1.2 管道总图

```
src[block]
   │  ZSTD_buildSeqStore (zstd_compress.c:3292)          ← C 章:匹配查找器
   ▼
SeqStore_t  {litStart..lit} + {SeqDef[]}  (+rep 状态 nextCBlock)
   │  ZSTD_compressBlock_internal (zstd_compress.c:4410)
   ▼
ZSTD_entropyCompressSeqStore (zstd_compress.c:3072)
   │   └─ internal (zstd_compress.c:2915)
   │
   ├─[第一遍:统计+建表]──────────────────────────────────────
   │  字面量: ZSTD_compressLiterals (zstd_compress_literals.c:129)
   │      HIST_count_wksp 直方图 → HUF_buildCTable → 写 Huffman 头 → 4 流编码
   │  序列:   ZSTD_buildSequencesStatistics (zstd_compress.c:2790)
   │      ZSTD_seqToCodes (2721): litLength/mlBase/offBase → LL/ML/OF 符号码
   │      HIST_countFast_wksp ×3 (2816/2846/2878)
   │      ZSTD_selectEncodingType ×3 (2819/2852/2882): RLE? 预定义表? 复用上块? 压缩表?
   │      ZSTD_buildCTable ×3 (zstd_compress_sequences.c:242): 写 NCount 头
   │
   ├─[第二遍:序列化]─────────────────────────────────────────
   │  ZSTD_encodeSequences (zstd_compress_sequences.c:419)
   │      倒序循环: FSE_encodeSymbol(OF/ML/LL) + BIT_addBits(附加位)
   │
   ▼
[literals 头+位流][nbSeq 头][seqHead 1B][FSE 表头][序列位流]
   │  块头 3B: lastBlock + bt_compressed<<1 + cSize<<3
   │  (zstd_compress.c:4683-4687 / writeBlockHeader:3644)
   ▼
块字节落盘;ZSTD_blockState_confirmRepcodesAndEntropyTables (3634)
   双缓冲交换 prevCBlock/nextCBlock,熵表与 rep 状态滚入下一块
```

为什么统计和编码分两遍?一句话:**FSE/Huffman 的解码表必须先于位流出现,而表的最终形态(NCount 头多大、用哪张表)取决于整块统计,编码第一个符号之前这些都必须定案**。细节见第 4 节。

---

## 2. 序列编码专节:三张 FSE 表的决策

序列段按格式先写 nbSeq(1~3 字节,zstd_compress.c:2970-2980,阈值 128 与 LONGNBSEQ=0x7F00,见 zstd_internal.h:96),再写 1 字节 seqHead,打包三个 2-bit 类型域:`(LLtype<<6)+(Offtype<<4)+(MLtype<<2)`(zstd_compress.c:2996)。每个域四选一:`set_basic/set_rle/set_compressed/set_repeat`(SymbolEncodingType_e,zstd_internal.h:94)。

### 2.1 ZSTD_selectEncodingType 的决策树(zstd_compress_sequences.c:156-235)

决策输入是符号直方图(`count`,由 `HIST_countFast_wksp` 对三条码表统计而来,zstd_compress.c:2816/2846/2878)。先处理退化情形(zstd_compress_sequences.c:166-178):

- `mostFrequent == nbSeq`:整块只有一个符号 → `set_rle`(建单符号表只花 1 字节符号值,zstd_compress_sequences.c:256-260);例外:nbSeq≤2 且允许预定义表时选 `set_basic`——RLE 要 1 字节,而 basic 每 symbol 只要 5-6 bit,反而更省。

然后按策略分岔(zstd_compress_sequences.c:179):

**(a) strategy < ZSTD_lazy(快档,不精确算账)**:
- 上一块的表仍有效(`FSE_repeat_valid`)且 nbSeq<1000 → `set_repeat`,零成本复用(zstd_compress_sequences.c:187-191);
- nbSeq 太小(`< dynamicFse_nbSeq_min`,按 defaultNormLog 折算约 28-36 个 offset / 56-72 个 length)或分布太平(`mostFrequent < nbSeq>>(defaultNormLog-1)`)→ `set_basic`,用格式内置的预定义分布(zstd_compress_sequences.c:192-203)。
- 其余 → `set_compressed`。

**(b) strategy ≥ ZSTD_lazy(认真比较三条路的比特代价)**(zstd_compress_sequences.c:205-231):

```c
size_t const basicCost = isDefaultAllowed ? ZSTD_crossEntropyCost(defaultNorm, defaultNormLog, count, max) : ERROR(GENERIC);
size_t const repeatCost = *repeatMode != FSE_repeat_none ? ZSTD_fseBitCost(prevCTable, count, max) : ERROR(GENERIC);
size_t const NCountCost = ZSTD_NCountCost(count, max, nbSeq, FSELog);
size_t const compressedCost = (NCountCost << 3) + ZSTD_entropyCost(count, max, nbSeq);
```

- `basicCost`(zstd_compress_sequences.c:139-154):假设用预定义表编码本块分布的交叉熵;`norm[s]==-1` 表示低概率符号按 count=1 算(第 147 行)。
- `repeatCost`(zstd_compress_sequences.c:104-132):沿用上块 FSE 表的代价;若表里某符号概率为 0(`bitCost >= badCost`,第 125 行)或 maxSymbolValue 不够(第 114 行),直接报错不可用。
- `compressedCost`:自建表的两部分之和——NCount 表头字节数×8(zstd_compress_sequences.c:70-78)加理想熵代价 `ZSTD_entropyCost`(84-98,查 `kInverseProbabilityLog256` 定点对数表,21-44)。

三者取最小:basic ≤ repeat 且 ≤ compressed → `set_basic`(219-224);repeat ≤ compressed → `set_repeat`(225-229);否则 `set_compressed` 并把 `repeatMode` 置 `FSE_repeat_check` 供下一块复核(232-234)。OF 表多一道闸:仅当 max≤DefaultMaxOff 才允许预定义表(zstd_compress.c:2849)。

### 2.2 AccuracyLog 怎么定

选了 `set_compressed` 后,表精度由 `FSE_optimalTableLog(FSELog, nbSeq, max)` 决定(fse_compress.c:371-374):上限是各表配额(OffFSELog/MLFSELog/LLFSELog),再按"源 size 的 log2 减 2"下调(`maxBitsSrc = highbit32(srcSize-1) - minus`,fse_compress.c:358-359),并用 `FSE_minTableLog` 兜底。即**小块自动用低精度表,省表头字节**。归一化时另有一个开关:`ZSTD_useLowProbCount`(nbSeq≥2048 时返回 1,zstd_compress_sequences.c:57-64)——小块用 `ncount=+1` 表示低概率符号(解码端开销小),大块才用 `-1`(压缩率高)。建表前还有一个细节:若最后一个序列的符号 count>1,先减一并少算一个序列,保证 FSE 编码器初始化合法(zstd_compress_sequences.c:271-274)。

### 2.3 写出循环(zstd_compress_sequences.c:290-382)

FSE 位流是**倒序写、正序读**的:编码器从最后一个序列开始,先把三个 FSE 状态用 `FSE_initCState2` 初始化(311-313),再把最后一条序列的字面量长/匹配长/偏移的"附加位"直接 `BIT_addBits`(314-329);随后主循环 `for (n=nbSeq-2; n<nbSeq; n--)`(注释 intentional underflow,333-369)对每条序列依次 `FSE_encodeSymbol`(OF→ML→LL,346-349)再补加 `litLength/mlBase/offBase` 的附加位(352-366)。顺序严格镜像解码端:解码器按 LL→ML→OF 读,编码端恰好反向。32 位平台附加位超过 `STREAM_ACCUMULATOR_MIN` 时启用 longOffsets 两段写(318-326,由 `ZSTD_seqToCodes` 返回值决定,zstd_compress.c:2739-2740)。最后按 ML→OF→LL 冲刷三个终态(371-376)。

---

## 3. 字面量编码专节

字面量段的类型头是 `2+2+1+1 bit` 的结构:2bit 类型 + 1bit "1 流/4 流" + 可变长的原大小/压缩大小字段。`ZSTD_compressLiterals`(zstd_compress_literals.c:129-235)是唯一入口。

### 3.1 三型判定

- **Raw(set_basic)**:`disableLiteralCompression`(154-155)、字面量太小于尝试阈值 `ZSTD_minLiteralsToCompress`(114-127:8<<shift,随策略收紧至 8 字节;上一块表 `HUF_repeat_valid` 时仅 6 字节)、或压缩后无最小收益 `cLitSize >= srcSize - ZSTD_minGain(...)`(187-191;minGain 公式在 zstd_compress_internal.h:699-705,`(srcSize>>minlog)+2`,btultra 以上 minlog=strategy-1)。
- **RLE(set_rle)**:压缩器返回 `cLitSize==1`(单符号信号)且 `srcSize>=8 || allBytesIdentical`(192-201)→ 只写 1 字节内容(zstd_compress_literals.c:104)。
- **Compressed(set_compressed)或 set_repeat**:真正调 `HUF_compress1X_repeat / HUF_compress4X_repeat`(172-178)。若 Huffman 层复用了上一块的表(`repeat != HUF_repeat_none`,180-184),头部类型记 `set_repeat`,即格式里的 Treeless_Literals_Block。

大小头先于内容确定:`lhSize = 3 + (srcSize>=1KB) + (srcSize>=16KB)`(140),三种头部布局 `2-2-10-10 / 2-2-14-14 / 2-2-18-18`(209-232)。若压缩结果涨出当前头部能表示的范围,则整体退回 Raw——这是第 5 节超级块里"头尺寸猜错"问题的常规版。

### 3.2 Huffman 4 流的切分点

`singleStream = srcSize < 256`(zstd_compress_literals.c:142);若上一块表有效且 lhSize==3,强制仍走单流(171,省跳转表)。4 流的物理切分在 huf_compress.c:1163-1222:

```c
size_t const segmentSize = (srcSize+3)/4;   /* first 3 segments */
...
op += 6;   /* jumpTable */
```

即**均分为 4 段**(前 3 段各 `(srcSize+3)/4`,尾段收余),先跳过 6 字节跳转表,四段各自独立 `HUF_compress1X_usingCTable`,每段压缩完把段大小以 LE16 回填跳转表(ostart+0/+2/+4,第 1178/1188/1198 行)。4 流的意义是解码端可用 4 个独立线程并行解四段。守门条件:少于 `MIN_LITERALS_FOR_4_STREAMS=6` 字节不得用 4 流(zstd_internal.h:92,断言在 zstd_compress_literals.c:212/218)。Huffman 表本身的上限是 `LitHufLog=11`(zstd_internal.h:101);表描述头部最大 128 字节(zstd_internal.h:115)。

### 3.3 直方图统计(hist.c)

字面量直方图有两个调用点:(1)块级统计决策 `ZSTD_buildBlockEntropyStats_literals` 里 `HIST_count_wksp`(zstd_compress.c:3702-3706),据此做 RLE/不可压/复用判定;(2)真正编码时 `HUF_compress_internal` 内部再做一次 `HIST_count_wksp`(huf_compress.c:1383)。hist.c 提供三档:`HIST_count_simple`(hist.c:45,单循环)、`HIST_count_parallel_wksp`(hist.c:321,分四带并行计数再合并)、`HIST_countFast_wksp`(hist.c:394,信任符号值范围跳过钳位检查);`HIST_count_wksp`(414-428)按信任度自动分发。序列侧统计用的正是 Fast 版(zstd_compress.c:2816),因为码表值域本来就 ≤ MaxLL/MaxML/MaxOff。

### 3.4 块级字面量决策(供超级块复用)

超级块需要"先决策、后复用",于是 zstd 把字面量决策抽成了独立函数 `ZSTD_buildBlockEntropyStats_literals`(zstd_compress.c:3660-3764):禁用→set_basic(3684);≤63 字节(上块表有效时 6)→set_basic(3691-3699);直方图发现单符号→set_rle(3707-3711);`largest <= (srcSize>>7)+4`(分布太平,预估每符号赚不到 1/128 位)→set_basic(3713-3717);然后建新表并估新表代价 `newCSize+hSize`,与复用旧表代价 `oldCSize` 比较,旧表更省(且 `oldCSize <= hSize+newCSize || hSize+12 >= srcSize`)→set_repeat(3744-3751);新表也赚不回→set_basic(3753-3757);否则 set_compressed 并把表描述写进 `hufMetadata->hufDesBuffer`(3739-3742,3759-3762)。这条流水线与 `ZSTD_entropyCompressSeqStore_internal` 内嵌版逻辑同源,是超级块的"第一遍"。

---

## 4. 两遍结构专节:统计先行,写出自后

### 4.1 为什么不能单遍

1. **表的物理位置在前**:FSE 的 NCount 头、Huffman 表描述都写在各自位流之前,而表头字节宽度(甚至选不选表)依赖整块直方图——写第一个符号时必须已定案。所以管道必然是:直方图(一遍扫描)→ 选型 → 建表/写头 → 再扫一遍符号序列做 FSE 编码(`ZSTD_encodeSequences` 消费的是建表后冻结的 `CTable_*`,zstd_compress.c:3002-3008)。
2. **选型本身是代价比较**:strategy≥lazy 时,`ZSTD_selectEncodingType` 要对同一份直方图算 basic/repeat/compressed 三个代价再取小(zstd_compress_sequences.c:206-230),这要求统计完备。
3. **跨块约束**:`set_repeat` 的可用性取决于上一块留下的表(`prevCTable`);`ZSTD_fseBitCost` 要整块直方图才能验证上块表是否覆盖所有符号。双缓冲 `prevCBlock/nextCBlock` 在块成功落盘后交换(`ZSTD_blockState_confirmRepcodesAndEntropyTables`,zstd_compress.c:3634-3640,调用点 4465-4466),实现"上一块的表"语义。
4. **字面量侧同理**:`ZSTD_compressLiterals` 先建 CTable、估 cLitSize、与 minGain 比较,再决定写 Raw/RLE/Compressed(187-201),最后才做位流编码;4 流还要先知道各段大小才能回填跳转表。

### 4.2 repcode 状态跨块的维护

repcode 是解码器也在维护的滑动历史,压缩端必须逐块与之同步,关键规则(zstd_compress_internal.h:839-857):

```c
if (OFFBASE_IS_OFFSET(offBase)) {  /* full offset */
    rep[2] = rep[1]; rep[1] = rep[0];
    rep[0] = OFFBASE_TO_OFFSET(offBase);
} else {   /* repcode */
    U32 const repCode = OFFBASE_TO_REPCODE(offBase) - 1 + ll0;
    if (repCode > 0) {
        U32 const currentOffset = (repCode==ZSTD_REP_NUM) ? (rep[0] - 1) : rep[repCode];
        ...
```

`ll0 = (litLength==0)` 时 repcode 语义整体上移一位,`repCode==3` 退化为 `rep[0]-1`(格式规定的 repcode 借位)。块的输出形态决定状态是否推进:**只有压缩块才确认(交换)nextCBlock 的 rep/熵表**(zstd_compress.c:4464-4467);Raw/RLE 块解码器不更新 rep,压缩端也回滚(`*dRep = dRepOriginal`,4183/4188)。块分裂路径把这个分歧显式建模为双账本 `dRep/cRep`:`cRep` 始终按 seqStore 推进,`dRep` 只对压缩分区推进;逐序列模拟解码侧 rep(`ZSTD_resolveRepcodeToRawOffset`,zstd_compress.c:4065-4082),发现两边算出的原始偏移不一致时把 repcode 改写成真实偏移(`ZSTD_seqStore_resolveOffCodes`,4097-4125),最终以 `dRep` 传给下一块(4377)。超级块路径若尾部遗留未压缩子块,则重放已完成序列重算 rep(zstd_compress_superblock.c:648-657)。另有一个小状态机:offcode 表 `FSE_repeat_valid` 在每块后降级为 `FSE_repeat_check`,因为下一块偏移可能超出表覆盖(zstd_compress.c:4472-4473)。

### 4.3 块的切分与 lastBlock

`ZSTD_compress_frameChunk` 循环切块(zstd_compress.c:4619-4720):块大小由 `ZSTD_optimalBlockSize` 决定(4580-4610)——不足 128KB 直接取剩余;满 128KB 时启用"预切分" `ZSTD_splitBlock`(4609,指纹直方图法,zstd_preSplit.c:18 起,`BLOCKSIZE_MIN=3500`),但要求全局累计 `savings >= 3` 字节才允许(4594-4597),防止对不可压数据白付块头。`lastBlock = lastFrameChunk & (blockSize == remaining)`(4646)。三条输出路径(4664-4689):targetCBlockSize → 超级块;postBlockSplitter → 块分裂;常规 → `ZSTD_compressBlock_internal`。压缩失败(返回 0)则写 Raw 块(4679-4681),`cSize==1` 走 RLE 块(4683-4685)。postBlockSplitter 默认在 `strategy>=ZSTD_btopt && windowLog>=17` 时开启(zstd_compress.c:268-272),其做法是二分递归比较"整块 vs 对半两块"的估计压缩大小(zstd_compress.c:4224-4260,最小 300 序列,4208),再逐分区独立成块。

---

## 5. 超级块专节:一个 128KB 逻辑块拆成多个物理块

**状态:已完整实现,但仅在设置 `ZSTD_c_targetCBlockSize`(参数 130,zstd.h:415-425,v1.5.6 起稳定,Chrome 低带宽流式场景)时启用**;入口 `ZSTD_compressBlock_targetCBlockSize`(zstd_compress.c:4534-4552)→ body(4478-4532)→ `ZSTD_compressSuperBlock`(zstd_compress_superblock.c:665-688)。默认 targetCBlockSize=0,即默认不走这条路(启用判定 `ZSTD_useTargetCBlockSize`,zstd_compress.c:2753-2757)。

核心思想:**熵表只写一次,后续子块全部复用**。`ZSTD_compressSubBlock_multi`(zstd_compress_superblock.c:479-663)的流程:

1. 先用 `ZSTD_buildBlockEntropyStats` 对整个逻辑块完成一次"统计+选型+建表"(672-677,注释明确"also employed in superblock",zstd_compress.c:3824),得到 `entropyMetadata`(hType/llType/ofType/mlType + 表描述缓冲,zstd_compress_internal.h:154-177)。
2. 估计整块压缩大小 `ZSTD_estimateSubBlockSize`(397-416):字面量用 `HUF_estimateCompressedSize`(322),三张 FSE 表用 `ZSTD_fseBitCost`/交叉熵(348-354);若 `estBlockSize > srcSize` 直接放弃、退单个 Raw 块(532)。
3. 按 `targetCBlockSize` 折算子块数,`sizeBlockSequences`(442-470)按平均每字面量/每序列代价累计预算切序列(熵头按 120 字节保守预算,448)。
4. 第一个子块带熵表写(`writeLitEntropy/writeSeqEntropy=1`):字面量子段写 `hufMetadata->hufDesBuffer`(71-76),序列子段把三个类型域写进 seqHead 并拷入 `fseTablesBuffer`(198-205);后续子块 seqHead 全部填 `set_repeat`(206-209),字面量走 Treeless——这就是"子块布局与复用熵表"的落点。
5. 子块失败/涨大即与后续子块合并(562-581 只在 `cSize < decompressedSize` 时提交);若到结尾熵表仍未写出:字面量表未写就恢复旧表状态(628-631),序列表未写则整体放弃返回 0(632-638,契约破坏时宁可退 Raw 块)。
6. 尾部剩余字节作为 Raw 子块补上(640-647),并重放序列重算 rep(648-657)。

兼容性细节不少:为绕过 ≤1.3.4 解码器对 NCount<4 字节的误报,表头+位流 <4 字节时放弃(229-235);≤1.4.0 对序列段体 <4 字节误报,同样放弃(248-252)。另有既有的"块分裂"(第 4.3 节)与"超级块"两条独立支线,前者是每分区重建熵,后者是一份熵多处复用,语义不同。

---

## 6. 与前作对照

- **deflate 的 dynamic Huffman 块**:每个 deflate 块都要传 HLIT/HDIST/HCLEN 并重造码表,块间只有"code length 码"的复用;块小、表头税高。zstd 把这层决策做成四态(含 RLE 和跨块 repeat),且序列侧是三张独立小表(LL/ML/OF),各表可以各自选型——例如长字面量流配 repeat 的 OF 表。zstd 的块也大得多(128KB vs deflate 常见 ~16-64KB),摊薄表头的思路一致但手段更细。
- **brotli**:前缀编码统一了字面量与距离/插入长度的建模(块内一个"命令+前缀"体系);zstd 则把"字面量(Huffman)"和"序列(FSE)"刻意分成两个独立熵域,各自选型。一句话:brotli 是一体化前缀,zstd 是分域多表。
- FFmpeg BSF 那类"逐块改写"属于转码工具链,与本章的编码器内部结构无对应关系,不展开。

---

## 7. 设计动机

- **字面量与序列分开编码**:匹配式压缩的数据里,字面量是"没有模型可借的字节"(分布接近文本字节分布),序列的 LL/ML/OF 是"强结构化小字母表"。混在一个熵域会互相污染精度;分开后字面量用 Huffman(字节字母表,256 符号),序列用 FSE(小字母表,tANS 状态机更快也更省),还可独立选 RLE/Raw 退化。
- **预定义表(set_basic)的意义**:小数据传表不划算。预定义 LL/ML/OF 分布内置于格式(zstd_internal.h:126-164,LL/ML 的 defaultNormLog=6,OF 为 5),小块直接引用零表头;解码端同样内置,互不通信。`ZSTD_defaultNormLog` 也是快档启发式的基准(log2 后的 28-36/56-72 阈值,zstd_compress_sequences.c:184)。
- **AccuracyLog 的精度预算**:表精度每 +1,表头(NCount)指数级变贵,但符号概率量化更细。`FSE_optimalTableLog` 用"srcSize 的 log2 - 2"封顶(fse_compress.c:358),让精度永远匹配数据量;`useLowProbCount`(nbSeq≥2048,zstd_compress_sequences.c:63)则是低概率表示法的精度预算,小块宁可用稍差的 +1 编码换解码简单。
- **minGain 门槛**:`(srcSize>>minlog)+2`(zstd_compress_internal.h:699-705)保证压缩块/压缩字面量段必须比 Raw 至少省一个比例,防止"赚 1 字节赔 CPU"和边界坏case。
- **repeat 态(四态里的第四态)**:把"上一块的表"变成免费资源,是 zstd 大块场景下表头税趋近于零的关键;代价是必须维护 `repeatMode` 三态(none/check/valid)与跨块确认协议。

---

## 8. FAQ

**Q1:nbSeq 头为什么有三个宽度?** 1 字节(<128)、2 字节(<LONGNBSEQ=0x7F00,zstd_internal.h:96)、3 字节(0xFF + LE16 偏移基准),避免大块被 1 字节上限卡住(zstd_compress.c:2970-2980)。

**Q2:seqHead 那 1 字节是什么?** 三个 2-bit 域:`LLtype<<6 | Offtype<<4 | MLtype<<2`(zstd_compress.c:2996);超级块的 repeat 子块填全 repeat(zstd_compress_superblock.c:208)。

**Q3:为什么序列位流倒着写?** zstd 位流按"后写先读"排列,倒序编码使解码端正序读符号时状态转移方向正确(zstd_compress_sequences.c:333 注释 intentional underflow)。

**Q4:litLength/mlBase 只有 U16,更长的怎么办?** 单槽 longLengthType/longLengthPos 补偿 +0x10000(zstd_compress_internal.h:766-785,126-140);码表符号同样取 MaxLL/MaxML(zstd_compress.c:2742-2745)。

**Q5:offCode 是什么?** `ZSTD_highbit32(offBase)`(zstd_compress.c:2733),即 offBase 的位长-1;offBase≥4 时解码端再由附加位补全真实偏移,1-3 则是 repcode。

**Q6:set_repeat 和 set_compressed 有什么联系?** set_compressed 后 `repeatMode=FSE_repeat_check`(zstd_compress_sequences.c:233),下一块会先算 `ZSTD_fseBitCost` 验证旧表对本块分布是否够用(概率非零,125-128),够用且最省才真正 set_repeat。

**Q7:nbSeq==0 的块(纯字面量块)序列段长什么样?** 只有 nbSeq 头;同时把上一块 FSE 表"当作 repeat"拷进 next,保持熵状态推进一致(zstd_compress.c:2982-2986)。

**Q8:字面量 4 流的切分点在哪、跳转表多大?** 均分 4 段(`(srcSize+3)/4`),跳转表 6 字节=3×LE16(尾段大小可由总长推出),huf_compress.c:1165-1198。

**Q9:什么情况下一个块整体退 Raw?** 三条主因:压缩结果 ≥ srcSize-minGain(zstd_compress.c:3061-3063)、统计判不可压(`largest <= (srcSize>>7)+4` 等,zstd_compress.c:3713-3717)、输出空间不足(3054-3056);超级块另有契约失败退路(zstd_compress_superblock.c:632-638)。

**Q10:块间传递的"状态"到底有哪几样?** 两样:熵表(HUF CTable + 三张 FSE CTable,含 repeatMode)和 rep[3];都装在 `ZSTD_compressedBlockState_t`,块成功后双缓冲交换(zstd_compress.c:3634-3640)。用前缀字典时,字典的这套状态在 `ZSTD_resetCCtx_byCopyingCDict` 里整体拷入 prevCBlock(zstd_compress.c:2510),于是第一块就能 set_repeat / 用 repcode——这就是字典加速小数据的第一性原理。

---

## 9. 深挖

1. **dRep/cRep 双账本**(zstd_compress.c:4097-4125,4304-4321):块分裂把同一 seqStore 切成多个物理块后,某些分区可能以 Raw/RLE 落盘,解码器的 rep 历史与压缩器预设分叉;压缩端逐序列模拟解码侧 rep 并改写冲突 repcode 为真实偏移。这是理解"为什么改写块会牵连后续块"的最佳样本,也是做 zstd 重压缩/改写工具的核心难点。
2. **`rep[0]-1` 借位**(zstd_compress_internal.h:847-849 与 zstd_compress.c:4068-4080):litLength==0 时 repcode 编号整体 +1,repcode3 语义变为 rep[0]-1;`ZSTD_resolveRepcodeToRawOffset` 里注释了 rep[0]==1 时会算出 0 的边缘情况——格式层面的边角都在这里。
3. **`ZSTD_entropyCompressSeqStore_internal` 与超级块的字面量决策重复**(zstd_compress.c:2949-2965 vs zstd_compress.c:3660-3764):常规路径把字面量决策交给 `ZSTD_compressLiterals` 内嵌完成,超级块则用块级 metadata 版;两条代码路径语义对齐但实现独立,对比阅读可看清"决策"与"写出"的耦合边界。
4. **`ZSTD_encodeSequences` 的位累加器边界**(zstd_compress_sequences.c:344-367):注释里逐行列出 32/64 位平台每步最多消耗多少位,`BIT_flushBits` 的插入位置是按 `STREAM_ACCUMULATOR_MIN` 精确推导的;想吃透 BIT 模块这是最好的习题。
5. **预切分 vs 后切分**(zstd_preSplit.c:18 起 vs zstd_compress.c:4224-4260):前者在匹配前用 2 字节指纹直方图找"内容断面",零成本感知数据换界;后者在 seqStore 上用真实压缩大小估计二分。两者层级不同(128KB 逻辑块内 vs 逻辑块切物理块),合起来才是 zstd 的完整切块策略。

---

## 10. 写作要点速查表

| 主题 | 函数/常量 | 位置 |
|---|---|---|
| 序列中间表示 | `SeqDef`(offBase/litLength/mlBase) | zstd_compress_internal.h:85-89 |
| 序列缓冲 | `SeqStore_t`(lit 池 + ll/ml/ofCode) | zstd_compress_internal.h:98-115 |
| 超长长度补偿 | `ZSTD_storeSeqOnly` / `ZSTD_getSequenceLength` | zstd_compress_internal.h:756-789 / 126-140 |
| offBase sum-type | `OFFSET_TO_OFFBASE` 等宏 | zstd_compress_internal.h:744-748 |
| rep 记账 | `ZSTD_updateRep`(ll0 借位) | zstd_compress_internal.h:839-857 |
| 符号码化 | `ZSTD_seqToCodes`(ofCode=highbit32) | zstd_compress.c:2721-2747 |
| LL/ML 码表 | `ZSTD_LLcode` / `ZSTD_MLcode` | zstd_compress_internal.h:606-635 |
| 常规块入口 | `ZSTD_compressBlock_internal` | zstd_compress.c:4410-4476 |
| 熵管道主体 | `ZSTD_entropyCompressSeqStore_internal` | zstd_compress.c:2915-3031 |
| 统计+选型+建表 | `ZSTD_buildSequencesStatistics` | zstd_compress.c:2790-2908 |
| 四态决策 | `ZSTD_selectEncodingType` | zstd_compress_sequences.c:156-235 |
| 代价函数 | `ZSTD_entropyCost/fseBitCost/crossEntropyCost/NCountCost` | zstd_compress_sequences.c:84-154/70 |
| 建表+写 NCount | `ZSTD_buildCTable` | zstd_compress_sequences.c:242-288 |
| 序列位流 | `ZSTD_encodeSequences_body`(倒序循环) | zstd_compress_sequences.c:290-382 |
| 字面量入口 | `ZSTD_compressLiterals`(三型+头部) | zstd_compress_literals.c:129-235 |
| 4 流切分/跳转表 | `HUF_compress4X_usingCTable_internal` | huf_compress.c:1163-1222 |
| 块级字面量决策 | `ZSTD_buildBlockEntropyStats_literals` | zstd_compress.c:3660-3764 |
| 块级序列决策 | `ZSTD_buildBlockEntropyStats(_sequences)` | zstd_compress.c:3826-3854/3786-3817 |
| 块循环/lastBlock | `ZSTD_compress_frameChunk`(4646 行 lastBlock) | zstd_compress.c:4619-4720 |
| 超级块入口/复用熵 | `ZSTD_compressSuperBlock` / `ZSTD_compressSubBlock_multi` | zstd_compress_superblock.c:665-688/479-663 |
| 块分裂+rep 对账 | `ZSTD_seqStore_resolveOffCodes` | zstd_compress.c:4097-4125 |
| 状态双缓冲 | `ZSTD_blockState_confirmRepcodesAndEntropyTables` | zstd_compress.c:3634-3640 |
| 压缩门槛 | `ZSTD_minGain` | zstd_compress_internal.h:699-705 |
