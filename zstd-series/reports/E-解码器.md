# E 篇:zstd 解码器——每 GB 吞吐数 GB 的另一半秘密

> 本系列第五篇之第 5 章(E)。源码:facebook/zstd,shallow clone,commit `d79e72359582d2326c63e9669fe05c2f6580fec5`(2026-09 时点),所有 `文件:行号` 均为仓库相对路径,经 grep -n / Read 实际核对。
> 前四章讲了压缩侧(找匹配、熵编码、写块);本章走"回程":解压一帧的完整数据流、字面量 4 流调度、三 FSE 表联合解码、match 的重叠拷贝、DDict 与窗口管理,以及解码端性能工程盘点。解压没有"搜索",只有"按图施工"——这正是它比压缩快一个量级的根本原因。

---

## 1. 全景:解压一帧的数据流

帧格式回顾(A 篇):`Magic → Frame_Header → Block* → [Checksum]`。解码器的顶层入口 `ZSTD_decompress` 一路下到 `ZSTD_decompressMultiFrame`,对每个帧做"初始化 → 逐块分派"两步:

```
ZSTD_decompress (zstd_decompress.c:1201)
  └─ ZSTD_decompressMultiFrame (:1068)             while srcSize≥帧头最小长度:
       ├─ skippable frame? → 整帧跳过 (:1118-1130)
       ├─ ZSTD_decompressBegin_usingDict/DDict (:1132-1139)  ← 熵表/rep 重置 + 字典装载
       ├─ ZSTD_checkContinuity (:1140)              ← dst 连续性裁决 → extDict 模式
       └─ ZSTD_decompressFrame (:951)
            ├─ 帧头: ZSTD_frameHeaderSize_internal + ZSTD_decodeFrameHeader (:969-977)
            │        windowSize / frameContentSize / dictID / checksumFlag
            ├─ while(1) 逐块 (:984-1041), 3 字节块头 ZSTD_getcBlockSize (:62)
            │    ├─ bt_raw      → ZSTD_copyRawBlock (memmove, :1018-1021)
            │    ├─ bt_rle      → ZSTD_setRleBlock (:1022-1024)
            │    ├─ bt_reserved → corruption_detected (:1025-1027)
            │    └─ bt_compressed → ZSTD_decompressBlock_internal (:1016)
            │         ├─ 字面量段 ZSTD_decodeLiteralsBlock (:2186)
            │         │    头 1-5B → Huffman 表(或 repeat) → 1/4 流解码 → litBuffer 三形态
            │         ├─ 序列段头 ZSTD_decodeSeqHeaders (:2226)
            │         │    nbSeq 变长 + LL/OF/ML 三张表描述 → ZSTD_buildSeqTable ×3
            │         ├─ 解码器选型: Long(prefetch) / SplitLitBuffer / 普通 (:2258-2274)
            │         └─ 解码循环: ZSTD_decodeSequence ↔ ZSTD_execSequence
            │              先拷 litLength 字节字面量,再按 offset+matchLength 拷 match(重叠分段)
            │              收尾: 残余字面量落盘 + rep 写回 dctx->entropy.rep (:1683/:1776)
            ├─ 每块 XXH64_update (:1031-1033)
            └─ frameContentSize 校验 + 4 字节 checksum (:1043-1057)
```

### 1.1 输出缓冲三形态

同一个解码内核,吃三种输出形态(即 `dst` 从哪来、往哪写):

1. **单缓冲整帧**:`ZSTD_decompress` 一次性给足 `dstCapacity`,`op` 在帧内连续推进(`ZSTD_decompressFrame` 内 `ostart/op/oend`,:957-959)。
2. **逐块直写(bufferless)**:`ZSTD_decompressContinue`(:1273)由调用方按 `ZSTD_nextSrcSizeToDecompress` 逐块喂入,每次给一块的 `dst`——各块 `dst` 不必连续,不连续时 `ZSTD_checkContinuity`(:1278 调用)把旧段降级为"外部字典"(extDict)。
3. **流式内部缓冲**:`ZSTD_decompressStream`(:2084)维护 `inBuff/outBuff`,输出先落内部窗口再 flush 给用户(`ZSTD_decompressContinueStream` :2055-2082,`ZSTD_bm_buffered` 分支 :2059-2069);`ZSTD_bm_stable` 模式则直接写用户的稳定输出缓冲(:2070-2080)。内部 outBuff 尺寸有讲究:`windowSize + 2*blockSize + 2*WILDCOPY_OVERLENGTH`(:1978)——多出的 2 个 blockSize 正是为"字面量散置在块输出之后"预留的(见 §3.2)。

块级还有一个平行的"字面量缓冲三形态"(`ZSTD_litLocation_e`,zstd_decompress_internal.h:120-124):`ZSTD_in_dst`(字面量整体存放在 dst 内当前块输出之后)、`ZSTD_not_in_dst`(存于 `litExtraBuffer` 或直接引用压缩流)、`ZSTD_split`(拆成 dst 尾部 + `litExtraBuffer` 两段)。§3.2 详述。

---

## 2. 帧循环专节:ZSTD_decompressFrame

### 2.1 帧头与全局校验

帧头解析在 `ZSTD_getFrameHeader_advanced`(zstd_decompress.c:445-549):FHD 字节解出 dictID 尺寸码/checksum/singleSegment/FCS 尺寸码(:500-505);windowSize 由 `windowLog+10` 与低 3 位分数部分合成 `2^w + (2^w >> 3)*(wlByte&7)`(:512-518);`blockSizeMax = MIN(windowSize, ZSTD_BLOCKSIZE_MAX)`(:544)。`ZSTD_decodeFrameHeader`(:700-722)把结果存入 `dctx->fParams`,校验 dictID 匹配(:715-716),并决定是否启用 XXH64(:718-719)。

### 2.2 逐块循环与 in-place 保护

```c
/* lib/decompress/zstd_decompress.c:984-1010 (节选) */
while (1) {
    BYTE* oBlockEnd = oend;
    size_t decodedSize;
    blockProperties_t blockProperties;
    size_t const cBlockSize = ZSTD_getcBlockSize(ip, remainingSrcSize, &blockProperties);
    if (ZSTD_isError(cBlockSize)) return cBlockSize;
    ip += ZSTD_blockHeaderSize;
    remainingSrcSize -= ZSTD_blockHeaderSize;
    RETURN_ERROR_IF(cBlockSize > remainingSrcSize, srcSize_wrong, "");
    if (ip >= op && ip < oBlockEnd) {
        /* We are decompressing in-place. Limit the output pointer so that we
         * don't overwrite the block that we are currently reading. */
        oBlockEnd = op + (ip - op);
    }
```

块分派 switch 在 :1012-1028。两个值得注意的细节:

- **in-place 解压支持**:当输入指针追上输出指针时,把 `oBlockEnd` 钳到 `ip` 当前位置(:995-1010),配合 `ZSTD_allocateLiteralsBuffer` 保证字面量不会写到输入上;`bt_raw` 特意用 `oend` 而非 `oBlockEnd`,因为 `ZSTD_copyRawBlock` 是 memmove、天生重叠安全(:1018-1021,memmove 在 :903)。
- **逐块校验**:每块解出后 `XXH64_update`(:1031-1033),帧尾核对 `frameContentSize`(:1043-1046)与 4 字节 checksum(:1047-1057)。

### 2.3 窗口连续性:ZSTD_checkContinuity 与 extDict 三指针

```c
/* lib/decompress/zstd_decompress_block.c:2280-2288 */
void ZSTD_checkContinuity(ZSTD_DCtx* dctx, const void* dst, size_t dstSize)
{
    if (dst != dctx->previousDstEnd && dstSize > 0) {   /* not contiguous */
        dctx->dictEnd = dctx->previousDstEnd;
        dctx->virtualStart = (const char*)dst - ((const char*)(dctx->previousDstEnd) - (const char*)(dctx->prefixStart));
        dctx->prefixStart = dst;
        dctx->previousDstEnd = dst;
    }
}
```

DCtx 用四个指针刻画历史(zstd_decompress_internal.h:134-137):`previousDstEnd`(上一段输出结束处)、`prefixStart`(当前段起点)、`virtualStart`(若历史紧贴当前段时假想的起点)、`dictEnd`(上一段的终点,即 extDict)。`checkContinuity` 每块/每帧调用一次(zstd_decompress.c:888、:1140、:1278):`dst` 恰好接续上次输出 → 什么也不做,匹配可以跨块在"同一段连续内存"里回溯;不连续 → 旧段整体变成 `dictEnd` 结尾的 extDict,新 `dst` 开启新 prefix。此后 match 拷贝若 `offset > oLitEnd - prefixStart` 就要"跨界"到 extDict 取数——`ZSTD_execSequence` 里表现为 `match = dictEnd + (match - prefixStart)`(zstd_decompress_block.c:1062),必要时再劈成"extDict 段 + prefix 段"两段拷(:1067-1073)。字典装载走同一套机制:`ZSTD_refDictContent`(zstd_decompress.c:1433-1444)把字典设为初始的历史段。

---

## 3. 字面量解码专节:Huffman 4 流与 litBuffer 的组织

### 3.1 头部、模式与 repeat 跳过重建

`ZSTD_decodeLiteralsBlock`(zstd_decompress_block.c:133-339)先看首字节低 2 位(`litEncType`,:141):`set_basic`(原始)/`set_rle`/`set_compressed`/`set_repeat`。**repeat 模式直接沿用上一块的 Huffman 表**,只需检查 `dctx->litEntropy` 标志(:146-149)——该标志在解码器复位时清零(zstd_decompress.c:1573),首次成功解码压缩字面量后置 1(zstd_decompress_block.c:244)。这就是"解码端也保存前块熵表"的第一个落点。

压缩模式的 1 字节类型码给出头长与 4 流资格(:162-183):3/4/5 字节头对应 10+10/14+14/18+18 位的 litSize+litCSize;`singleStream`(lhlCode==0)用 1 流,否则必须 4 流且 `litSize >= MIN_LITERALS_FOR_4_STREAMS(6)`(lib/common/zstd_internal.h:92,检查在 :186-189)。repeat 与 compressed 的分派只差一件事:repeat 调 `HUF_decompress1X/4X_usingDTable`(用现成表,:199-209),compressed 调 `_DCtx_wksp` 变体现场重建 `dctx->entropy.hufTable`(:210-228,4 流入口 `HUF_decompress4X_hufOnly_wksp` 在 :224)。冷字典时还有一层启发式预取:`ddictIsCold && litSize > 768` 就 `PREFETCH_AREA(dctx->HUFptr, ...)`(:195-197)。

### 3.2 litBuffer 三形态:把字面量"藏"进输出缓冲

字面量解码后需要一个暂存区供序列解码阶段回读。zstd 的做法不是无条件另开缓冲,而是按 dst 余量三选一(`ZSTD_allocateLiteralsBuffer`,:79-123):

```c
/* lib/decompress/zstd_decompress_block.c:86-101 (节选) */
if (streaming == not_streaming && dstCapacity > blockSizeMax + WILDCOPY_OVERLENGTH + litSize + WILDCOPY_OVERLENGTH) {
    /* So if we have space after the end of the block, just put it there. */
    dctx->litBuffer = (BYTE*)dst + blockSizeMax + WILDCOPY_OVERLENGTH;
    dctx->litBufferEnd = dctx->litBuffer + litSize;
    dctx->litBufferLocation = ZSTD_in_dst;
} else if (litSize <= ZSTD_LITBUFFEREXTRASIZE) {
    dctx->litBuffer = dctx->litExtraBuffer;
    dctx->litBufferLocation = ZSTD_not_in_dst;
} else { /* ZSTD_split: dst 尾部 + litExtraBuffer 各存一部分 */ }
```

- `ZSTD_in_dst`:一次性 API 的 dst 至少能装下"块 + 字面量",字面量直接写在当前块输出的后面——**零额外内存、零拷贝搬移**,序列循环把 `oend` 钳到 `dctx->litBuffer` 以防输出踩到它(:1721-1723,:1840-1842)。
- `ZSTD_not_in_dst`:字面量小(≤64B~128KB 内部缓冲,`ZSTD_LITBUFFEREXTRASIZE`,zstd_decompress_internal.h:118)时放 `litExtraBuffer`。
- `ZSTD_split`:Huffman 先整体解到 dst 尾部,再把最后 `ZSTD_LITBUFFEREXTRASIZE` 字节搬到 `litExtraBuffer`,前段留 dst(:230-238);序列循环里一旦读到 split 分界,就把残余拷到输出、切换到 litExtraBuffer 续读(:1616-1640)。

`set_basic` 还有第四条捷径:字面量原样躺在压缩流里且 wildcopy 读得安全时,**直接把 `litPtr` 指进输入缓冲**,一个字节都不搬(:289-294)。

### 3.3 4 流调度(与 B 篇 X1/X2 交叉)

块内字面量用 4 条独立 Huffman 位流(前置 6 字节 jumpTable,B 篇 §4.3)。解码端三套实现:

- **保守循环** `HUF_decompress4X1_usingDTable_internal_body`(huf_decompress.c:603-699):4 个 `BIT_DStream_t`,主循环每轮"4 流 × 4 符号 = 16 符号"(:653-675),溢出检查只信 `op4 < olimit` 一条,收尾逐流 `HUF_decodeStreamX1`(:687-690),四流 `BIT_endOfDStream` 全过才算对(:693-694)。
- **fast 循环** `HUF_decompress4X1_usingDTable_internal_fast_c_loop`(:722-832):手写 5 符号/流/轮的展开循环,`U64 bits[4]` 哨兵位方案(`bits>>53` 直查 11 位表 :788-794,`ctz` 定位重载边界 :796-805),每轮最多 55 bit < 7 字节/流(:753-757)。x86-64 BMI2 上直接换汇编版 `huf_decompress_amd64.S` 的 loop(:717-719,:908-909 选择)。
- **X2 双符号**:同构的 `HUF_decompress4X2_*`(:1385 起),一格表项吐 2 字节。

派发逻辑 `HUF_decompress4X1_usingDTable_internal`(:898-929):fast 失败(条件不符返回 0)或被 flag 禁用则回退保守版;X1/X2 之选在字面量段由 `HUF_selectDecoder` 按 `Q=cSrcSize*16/dstSize` 查预标定耗时表(:1830-1852)。fast 循环的准入门槛:`dtLog == HUF_DECODER_FAST_TABLELOG(11)`(:220-221)且每流 ≥8 字节(:237)。

---

## 4. 序列解码专节:三表联合 + match 的重叠拷贝

### 4.1 序列段头:三张 FSE 表的构建

`ZSTD_decodeSeqHeaders`(:694-777):nbSeq 用 1-3 字节变长编码(:707-717,`0xFF` 前缀加 `LONGNBSEQ=0x7F00`,lib/common/zstd_internal.h:96);随后 1 字节描述符 packed 四组 2 bit:LL/OF/ML 各自的模式 + 保留位(必须为 0,:729-733)。`ZSTD_buildSeqTable`(:646-692)按模式四选一:`set_rle` 造单格表(:656-665)、`set_basic` 指向预编译的默认表(LL/OF/ML 默认 DTable 在 :363/:401/:424)、`set_repeat` 直接复用 `dctx->entropy.LLTable` 等并做 `fseEntropy` 门检(:669-677,冷字典且 nbSeq>24 时预取表)、`set_compressed` 走 `FSE_readNCount + ZSTD_buildFSETable`(:678-687)。

`ZSTD_buildFSETable_body`(:484-602)把归一化计数摊成 2^log 行的 `ZSTD_seqSymbol{nextState, nbAdditionalBits, nbBits, baseValue}`(zstd_decompress_internal.h:67-72)。工程亮点是**两阶段 symbol spreading**(:528-587):无低概率符号时先用 U64 按 8 字节平铺计数(:537-552),再以固定步长无分支地散到表里(:559-573)——注释明说是为了消掉变长内循环的分支预测失败。

### 4.2 联合解码循环:一次迭代产出 litLength+offset+matchLength

seqState 携带三个 FSE 状态 + rep 缓存(zstd_decompress_block.c:791-797);`ZSTD_initFseState` 为每个表读 tableLog 位初态(:1199-1208)。主循环极简(:1759-1770):`decodeSequence → execSequence → op += oneSeqSize`,连循环体都没有多余语句——`DONT_VECTORIZE`(:1503/:1714)刻意禁止向量化,这循环要的是稳定的乱序流水而非 SIMD。

`ZSTD_decodeSequence`(:1236-1447)每符号从三个表各取一格(`table + state`),并把三者的附加位**交织**着从同一位流读:offset → matchLength → litLength,x86 路径 :1351-1443(aarch64 有独立分支 :1239-1350,用 ZSTD_memcpy 强制单条 64 位装载)。细节:

- `ofBits>1`:`offset = ofBase + BIT_readBitsFast(ofBits)`,同时滚动 rep 环(:1379-1398);
- `ofBits<=1` 走 repcode 语义(`ofBits==0` 且 ll0 时 rep[1] 上位,:1399-1412),与 D 篇压缩侧 `ZSTD_updateRep` 严格对偶;损坏输入通过 `temp -= !temp` 强制成非法 offset,在 execSequence 兜底报错(:1408);
- **最后一个序列不更新 FSE 状态**(:1435-1442 `if (!isLastSeq)`),状态机的最后一次转移被省掉;
- 循环结束必须 `BIT_endOfDStream`(:1774/:1681)——位流要么恰好耗尽要么报 corruption,这是"多余比特也是错误"的强校验。

rep 状态在块间持久:块尾 `dctx->entropy.rep[i] = seqState.prevOffset[i]`(:1683/:1776/:1965),帧头初始化为 `repStartValue`(:1577-1578);字典则自带 rep(`ZSTD_loadDEntropy` 读 12 字节三个 rep,zstd_decompress.c:1524-1532)。

### 4.3 match 拷贝:重叠拷贝的分段处理(本篇最核心 30 行)

match 拷贝的难点是 `matchLength > offset` 的自引用:直接 memcpy 会读到尚未写出的字节。zstd 把它分成三档:

**第一档:offset ≥ 16(占绝大多数)** —— 16 字节宽拷贝,无需任何检查:

```c
/* lib/decompress/zstd_decompress_block.c:1084-1101 */
if (LIKELY(sequence.offset >= WILDCOPY_VECLEN)) {   /* WILDCOPY_VECLEN == 16 */
    /* We bet on a full wildcopy for matches, since we expect matches to be
     * longer than literals (in general). In silesia, ~10% of matches are longer
     * than 16 bytes. */
    ZSTD_wildcopy(op, match, sequence.matchLength, ZSTD_no_overlap);
    return sequenceLength;
}
/* Copy 8 bytes and spread the offset to be >= 8. */
ZSTD_overlapCopy8(&op, &match, sequence.offset);
if (sequence.matchLength > 8) {
    ZSTD_wildcopy(op, match, sequence.matchLength - 8, ZSTD_overlap_src_before_dst);
}
```

offset≥16 时,每个 16 字节 chunk 的源都比目标落后至少一个 chunk,读到的永远是"上一轮定稿"的字节——周期性平铺语义自动成立,且允许最多越界写 32 字节(`WILDCOPY_OVERLENGTH`,lib/common/zstd_internal.h:201),这正是序列循环把 `oend_w = oend - WILDCOPY_OVERLENGTH` 留作安全余量的原因(:1016)。

**第二档:offset < 16** —— `ZSTD_overlapCopy8`(:806-827)用两组经典表把周期"摊"到 8 字节:`dec32table[]/dec64table[]`(:811-812,承自 LZ4)让一次 8 字节写之后 `op-ip ≥ 8` 成立(:826 断言),随后 `ZSTD_wildcopy` 在 `overlap_src_before_dst` 模式下自动退化为 8 字节 COPY8 循环(lib/common/zstd_internal.h:225-229)。**逐字节复制只出现在慢路径**:`ZSTD_safecopy`(:840-878)处理块尾/缓冲边界——长度 <8 时(:849-851)与 wildcopy 之后的残余(:877)才是真正的逐字节循环。

**第三档:extDict 与 memmove 语义**。凡源在 extDict(可能上一次输出的旧缓冲,in-place 场景下甚至与当前 dst 物理重叠),一律 `ZSTD_memmove`:整段在 dict 内一次搬(:1064),跨 extDict/prefix 边界则先搬 dict 段再续 prefix 段(:1067-1073)。`ZSTD_execSequenceEnd`(:914-955)与 SplitLitBuffer 版(:962-1004)是同样的慢速镜像。

快慢路径的准入只有一条 UNLIKELY 判定(:1032-1036):字面量越界、match 端进入 oend 前 32 字节、或 32 位模式溢出,才走 `execSequenceEnd`。字面量拷贝同样有"押注":先无条件 `ZSTD_copy16`,litLength>16 才补 wildcopy(:1050-1054,注释称 gcc-9 上 +1.6%)。

### 4.4 三个变体与选型

`ZSTD_decompressBlock_internal`(:2168-2276)在表头解出后做两次决策:

- **Long(prefetch)解码器**:`ZSTD_getOffsetInfo` 统计 OF 表中 `nbAdditionalBits > 22` 的占比(:2114-2140);64 位下默认不需要,仅当 `ddictIsCold`(:2218)或 `totalHistorySize > 16MB && nbSeq > 8` 且占比达到启发线(64 位 7/128、32 位 20/128,:2249)时启用。`ZSTD_decompressSequencesLong_body`(:1833-1990)维护 8 深度的序列队列(`STORED_SEQS 8`,:1852-1855):解码超前 8 条序列,对即将拷贝的 match 地址提前 `PREFETCH_L1`(`ZSTD_prefetchMatch`,:1815-1826),把长距离匹配的主存延迟藏进解码流水。
- **SplitLitBuffer 变体**(:1504-1711):字面量处于 split 状态时的专用循环,前半段从 dst 读、后半段从 litExtraBuffer 读,切换点处理见 :1616-1640。
- 普通变体(:1715-1790)。三者各再乘 BMI2 双版本(:2004-2038)。

另一个性能细节写进了注释:解码主循环按 `.p2align 6/5/4` 手工对齐(:1583-1597),因为 i9-9900K 上"循环体掉出 DSB(μop 缓存)会让解压速度波动 10%"(:1539-1560)。

---

## 5. DDict 专节:double indirection 与字典复制

### 5.1 结构:两级指针的"消化字典"

```c
/* lib/decompress/zstd_ddict.c:36-44 */
struct ZSTD_DDict_s {
    void* dictBuffer;          /* ZSTD_dlm_byCopy 时持有复制来的字典内容 */
    const void* dictContent;   /* 指向 dictBuffer 或外部缓冲 */
    size_t dictSize;
    ZSTD_entropyDTables_t entropy;   /* 预建的 LL/OF/ML + Huffman 表 + rep */
    U32 dictID;
    U32 entropyPresent;
    ZSTD_customMem cMem;
};
```

"double indirection"指:DCtx 只持 `const ZSTD_DDict* ddict`(zstd_decompress_internal.h:165),而解码内核实际用的 `LLTptr/MLTptr/OFTptr/HUFptr` 在 `ZSTD_decompressBegin_usingDDict` 时经 `ZSTD_copyDDictParameters`(zstd_ddict.c:58-86)**指进 ddict 内部的表**(:75-78),而不是拷贝进 DCtx——即 `dctx->LLTptr → ddict->entropy.LLTable` 的二次跳转。窗口四指针同样指到 `ddict->dictContent`(:64-67),字典成为初始历史段,match 可以直接回溯到字典内容。

### 5.2 为什么要复制(以及为什么不)

`ZSTD_initDDict_internal`(:120-143)在 `dlm_byCopy` 时把用户字典 memcpy 进自有 `dictBuffer`(:125-135)。三个动机:

1. **生命周期解耦**:`ZSTD_createDDict` 注释直说"`dict` content is copied inside DDict. Consequently, `dict` can be released after DDict creation"(:166-169);调用方的临时缓冲可以立刻释放。
2. **一次消化、多次使用**:熵表在 DDict 创建时建好(`ZSTD_loadEntropy_intoDDict` :89-117 → `ZSTD_loadDEntropy`,zstd_decompress.c:1450-1535),之后每次绑到新 DCtx 都是零成本指针赋值——这是"digested dictionary, without startup delay"的字面实现。逐帧流式解码多 DCtx 共享一个 DDict 时,预建表是纯收益。
3. **局部性**:字典内容与表在同一(或紧邻)分配里;冷字典判定 `ddictIsCold = (dctx->dictEnd != dictEnd)`(zstd_decompress.c:1607)直接触发 §4.4 的 prefetch 解码器与表预取。

不想复制也有 `ZSTD_createDDict_byReference`(:180-184,要求 dictBuffer 比 DDict 长寿)与 `ZSTD_initStaticDDict`(:187-209,把 DDict 头与字典内容摊进调用方给的一块静态内存)。

### 5.3 与 CDict 的对称性

CDict(C 篇)与 DDict 是同一设计模板的两面:`createCDict/createDDict` 都"复制内容 + 预建熵表 + 记 dictID";都有 byRef 变体、static 初始化变体、`estimate*Size`。差异只在表的方向(压缩建 CTable vs 解码建 DTable)和窗口含义(CDict 消化的是"压缩起始状态",DDict 消化的是"初始历史段")。逐帧 API 侧的 `ZSTD_decompress_insertDictionary`(:1537-1556)是"裸字典"路径:不走 DDict,直接把熵表灌进 DCtx 并 `ZSTD_refDictContent`——少一层间接,但每次 begin 都要重新解析字典,这正是 DDict 存在的意义。

---

## 6. 性能专节:吞吐的工程手段盘点

**内存访问类**
- 4 流 Huffman + BMI2 汇编循环(§3.3),ILP 与 DSB 双收益(B 篇 §4.3 交叉);
- Long 解码器的 8 深度预取队列(§4.4),冷字典/长偏移场景藏主存延迟;
- 冷表预取三连:HUF 表 `litSize>768`(:195-197)、FSE 表 `nbSeq>24`(:672)、冷字典直接切 prefetch 解码器(:2218);
- 字面量优先写进 dst(§3.2),省一次整段拷贝与等量内存;
- aarch64 上 match 地址预取(PREFETCH_L1,:1023-1026)与 `ZSTD_decodeSequence` 的 aarch64 专用分支(:1239-1350)。

**分支/流水类**
- 快慢路径极简二分:一条 UNLIKELY 判定分出 `execSequenceEnd`(:1032-1036),FORCE_NOINLINE 防止慢路径污染寄存器分配(:912);
- offset≥16 与 offset<16 的 match 拷贝分档(:1084-1101),把重叠检查从热路径赶走;
- FSE 建表两阶段 spread 消分支(:528-587);
- DSB 对齐注释与 `.p2align` 补丁(:1539-1597)——性能工程里少见的"逐编译器版本调 nop"的实证记录;
- last sequence 不更新 FSE 状态(:1435-1442)。

**语义/API 类**
- repeat 模式跨块复用熵表:块间只有改数据才付建表钱(:146-149、:669-677);
- rep 状态/熵表标志的持久化即"上下文复用"(§4.2);
- `litEntropy/fseEntropy` 双标志把"哪个段可 repeat"分而治之(zstd_decompress_internal.h:144-145);
- 工作区复用:DCtx 的 `entropy.LLTable...MLTable` 在建 Huffman 表时当 scratch 用(静态断言保证够大,zstd_decompress.c:1460-1464)。

**错误检测点与不可信输入边界**(简列):magic 与 skippable 识别(:456-492);保留位必须 0(:509、:729);块大小上限双重校验(`cBlockSize > blockSizeMax` 在流式 :1313,`srcSize > ZSTD_blockSizeMax` 在块级 :2183);offset 越界在 exec 三处 `virtualStart` 检查(:939/:988/:1061);位流必须恰好耗尽(:1774);4 流各流独立 endCheck(:693-694);checksum/帧内容大小终验(:1043-1057);fuzzing 模式下放宽 dictID 检查以扩大搜索面(:711-714)。设计哲学:所有损坏要么在"结构校验点"被显式拒绝,要么被钳成一个必然失败的值(offset=-1)——解压任何输入都不会写越界,最多报 corruption。

---

## 7. 与前作对照:deflate 解码器 vs zstd 解码器

| 维度 | zlib inflate(位级流式) | zstd(块级 + 表驱动) |
|---|---|---|
| 输入模型 | 一条位流逐位推进,块边界与位对齐交织 | 3 字节块头定界,块内三段自描述 |
| 熵解码 | 动态 Huffman 树遍历或 (code,length) 双表,树随块重建 | FSE 状态机一格一符号 + Huffman 11 位直查;repeat 可整块跳过重建 |
| 字面量/序列耦合 | length/distance 码与字面量同流交织 | 字面量段独立解码进 litBuffer,序列段统一"查三表+读附加位" |
| 匹配拷贝 | 同样要处理重叠(byte-by-byte + 短距摊开),但宽度/分档更粗 | 三档分档 + WILDCOPY_OVERLENGTH 越界写预算 + extDict memmove |
| 历史管理 | 单窗口,滑动 | 四指针段模型,不连续即 extDict,流式环形缓冲 |
| 校验 | Adler-32 | XXH64(块级增量,可关) |

**解压为什么比压缩快**:压缩要为每个位置做匹配搜索(C 篇的 hash chain/binary tree,对窗口的多次探测)再为每块做熵建模与选择(D 篇);解码端没有任何搜索——序列就是压缩时写下的"操作脚本",解码只是三个表查询加两段拷贝,每输出字节摊到常数次访存。zstd 基准的"解压 ≥ 数 GB/s/核"正来自这个不对称:压缩端复杂度可以随级别增长,解码端格式被冻结成"查表+拷贝"。

---

## 8. 设计动机三问

**为什么解码端也保存前块熵表?** 格式层允许 `set_repeat`(B 篇),解码端必须持有"上一块的 LL/OF/ML 表 + Huffman 表 + rep"才能兑现。保存位置就是 `dctx->entropy`(zstd_decompress_internal.h:80-87)——它同时是 DCtx 成员(跨块存活)和 DDict 成员(字典自带,拷贝参数即复用)。代价是 DCtx 变大(三张 FSE 表 + 12KB Huffman 表容量),收益是重复分布(常见于同类数据)时每块省掉全部建表成本。注意熵表还有第二身份:建 Huffman 表时的工作区(:1463 静态断言),一份内存两个用途。

**输出三形态的 API 代价?** 三形态(单缓冲/逐块直写/流式内部缓冲)让同一内核适配三种调用契约,代价全部转嫁为块级代码的分支复杂度:字面量三形态(:79-123)、序列解码三变体、`oend` 的三处不同钳制(:1721-1723、:1840-1842、:1510)。这是 zstd "one core, many skins" 的典型取舍——内核每加一个功能(如 split literals)要在 3 个变体里各实现一遍(对照 :1502 与 :1833 两份近乎平行的 split 处理)。

**为什么字典要复制?** 见 §5.2:生命周期解耦是首要动机(注释原文),消化(预建表)是性能动机,byRef/static 变体保留了不复制的选择权——复制是默认而非强制,正说明这是 API 契约问题(DDict 必须自足)而非技术必然。

---

## 9. FAQ 素材与深挖

**FAQ(8 条)**
1. **解压一帧最少要多少内存?** 流式下 `windowSize + 2*blockSize + 2*WILDCOPY_OVERLENGTH`(zstd_decompress.c:1978),多出的两个 blockSize 是给"散置字面量"和跨块 wildcopy 越界写的。
2. **repeat 模式什么时候非法?** `set_repeat` 出现在本帧第一个字面量/序列段(litEntropy/fseEntropy 未置位)即 corruption(:148、:670)。
3. **为什么 4 流要求 litSize ≥ 6?** 每流至少 1 字节 + jumpTable 6 字节,低于 6 则 4 流无意义(zstd_decompress_block.c:186-189,常量 :92)。
4. **matchLength < offset 会怎样?** 不会出现逐字节回退——`overlapCopy8` 把周期摊到 ≥8 后照用宽拷贝;只有块尾慢路径才逐字节(:849-851)。
5. **offset 可以指到字典里吗?** 可以,`offset > oLitEnd - prefixStart` 时转入 extDict 取数(:1059-1074),越界由 `virtualStart` 检查拒绝。
6. **Long 解码器何时启用?** 冷字典,或历史 >16MB 且 nbSeq>8 且 OF 表长偏移占比过线(64 位 7/128)(:2218、:2239-2252)。
7. **DDict 被多个 DCtx 共享安全吗?** 安全:begin 时只读拷贝参数(:58-86),表与内容从不被解码修改。
8. **校验和能关吗?** 能,`forceIgnoreChecksum`(:1049),但帧大小校验(:1043-1046)不可关——结构完整性是底线。

**深挖(4 条)**
1. **huf_decompress.c:788-805 哨兵位方案**:与 B 篇深挖条目 2 呼应,`bits | 1` + ctz 让"剩余位数"与"重载点"共用一个寄存器,fast 循环零显式计数器;对照 `HUF_initRemainingDStream`(:282-304)如何从 fast 状态无损退回 BIT_DStream_t。
2. **三个 `ZSTD_decompressSequences_*` 变体的 litLocation 状态机**:梳理 :1616-1640 与 :1879-1922 两份 split 切换逻辑的等价性,理解为什么 Long 版用环形队列而普通版用两段顺序循环。
3. **`ZSTD_execSequence` 的 wildcopy 越界写预算**:为什么 `oend_w = oend - WILDCOPY_OVERLENGTH`(:1016)恰好是 32 字节——X2 每符号最多 3 字节 × 16 字节粒度 + 跨 chunk 推测的余量,可对照 lib/common/zstd_internal.h:210-246。
4. **DSB 对齐的实证方法论**::1539-1582 注释给出 perf 命令与跨 CPU 复现矩阵,是研究"编译器布局如何影响解压吞吐"的一手材料。

---

## 写作要点速查表

| 主题 | 函数/结构 | 位置(仓库相对路径:行号) |
|---|---|---|
| 帧头解析 | `ZSTD_getFrameHeader_advanced` | lib/decompress/zstd_decompress.c:445-549 |
| 帧头落地/校验 | `ZSTD_decodeFrameHeader` | lib/decompress/zstd_decompress.c:700-722 |
| 帧级块循环 | `ZSTD_decompressFrame` | lib/decompress/zstd_decompress.c:951-1064 |
| 多帧循环/跳帧 | `ZSTD_decompressMultiFrame` | lib/decompress/zstd_decompress.c:1068-1167 |
| 连续性裁决 | `ZSTD_checkContinuity` | lib/decompress/zstd_decompress_block.c:2280-2288 |
| 字面量缓冲三形态 | `ZSTD_allocateLiteralsBuffer` / `ZSTD_litLocation_e` | lib/decompress/zstd_decompress_block.c:79-123 / zstd_decompress_internal.h:120-124 |
| 字面量段解码 | `ZSTD_decodeLiteralsBlock` | lib/decompress/zstd_decompress_block.c:133-339 |
| 4 流 X1 保守/fast 循环 | `..._4X1_usingDTable_internal_body / _fast_c_loop` | lib/decompress/huf_decompress.c:603-699 / 722-832 |
| fast 循环派发 | `HUF_decompress4X1_usingDTable_internal` | lib/decompress/huf_decompress.c:898-929 |
| X1/X2 选择 | `HUF_selectDecoder` | lib/decompress/huf_decompress.c:1830-1852 |
| FSE 表构建 | `ZSTD_buildFSETable_body`(两阶段 spread) | lib/decompress/zstd_decompress_block.c:484-602 |
| 序列段头 | `ZSTD_decodeSeqHeaders` / `ZSTD_buildSeqTable` | lib/decompress/zstd_decompress_block.c:694-777 / 646-692 |
| 单序列解码 | `ZSTD_decodeSequence`(repcode/last-seq) | lib/decompress/zstd_decompress_block.c:1236-1447 |
| match 拷贝三档 | `ZSTD_execSequence` / `ZSTD_overlapCopy8` / `ZSTD_safecopy` | lib/decompress/zstd_decompress_block.c:1008-1103 / 806-827 / 840-878 |
| 解码主循环 | `ZSTD_decompressSequences_body(SplitLitBuffer)` | lib/decompress/zstd_decompress_block.c:1715-1790 / 1504-1711 |
| prefetch 解码器 | `ZSTD_decompressSequencesLong_body` / `ZSTD_prefetchMatch` | lib/decompress/zstd_decompress_block.c:1833-1990 / 1815-1826 |
| 块级总控/选型 | `ZSTD_decompressBlock_internal` | lib/decompress/zstd_decompress_block.c:2168-2276 |
| DDict 结构/参数拷贝 | `ZSTD_DDict_s` / `ZSTD_copyDDictParameters` | lib/decompress/zstd_ddict.c:36-44 / 58-86 |
| 字典消化 | `ZSTD_loadDEntropy`(Huf+3×FSE+rep) | lib/decompress/zstd_decompress.c:1450-1535 |
| 解码器复位(rep/表指针) | `ZSTD_decompressBegin` | lib/decompress/zstd_decompress.c:1558-1584 |
| 逐块状态机 | `ZSTD_decompressContinue` | lib/decompress/zstd_decompress.c:1273-1442 |
| 流式缓冲尺寸 | `ZSTD_decodingBufferSize_internal` | lib/decompress/zstd_decompress.c:1968-1984 |
