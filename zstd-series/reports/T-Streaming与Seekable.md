# T 篇:流式 API 内部机制与 Seekable Format

> 调研对象:zstd @ commit `d79e723`(d79e72359582d2326c63e9669fe05c2f6580fec5,2025 年主线)。
> 本文所有行号均以该 commit 的仓库相对路径标注,已逐条 grep/Read 核对。

---

## 1. 全景:一次流式压缩的生命周期

zstd 的流式 API 只有一个核心入口 `ZSTD_compressStream2(cctx, output, input, endOp)`
(声明:`lib/zstd.h:796`;实现:`lib/compress/zstd_compress.c:6475`)。
旧的 `ZSTD_compressStream`/`ZSTD_flushStream`/`ZSTD_endStream` 都是对它的薄包装
(`zstd_compress.c:6329`、`8178`、`8185`)。

```
 ZSTD_createCStream()                    /* CStream 就是 CCtx 的别名, lib/zstd.h:776 */
   │
   ▼
 ┌────────────── 循环(应用驱动) ──────────────┐
 │  ZSTD_compressStream2(cctx,&out,&in,endOp)  │
 │                                             │
 │  [透明初始化 zcss_init]                      │  首次调用才真正 init:
 │     ├─ e_end → pledgedSrcSize = 本次输入大小  │  zstd_compress.c:6394
 │     └─ 否则按参数建/重置压缩上下文            │  zstd_compress.c:6508
 │                                             │
 │  单线程状态机 ZSTD_compressStream_generic    │  zstd_compress.c:6131
 │     zcss_load ──攒满一块(blockSizeMax)──►    │  6173
 │        │  ZSTD_compressContinue/End_public   │  6236-6242
 │        ▼                                     │
 │     zcss_flush ──把 outBuff 拷进用户 output─► │  6278
 │        │  拷不完?留在 outBuff,下次继续        │  6289-6294
 │        └──► 回到 zcss_load                   │  6302
 │                                             │
 │  endOp = continue: 攒不满一块就返回(省流量)  │  6198-6202
 │  endOp = flush   : 把已给输入全部变成块写出   │  6203-6207
 │  endOp = end     : 末块置 lastBlock+写 epilogue,帧结束 6236/6296
 └─────────────────────────────────────────────┘
   │  返回值 == 0(e_end 时) → 帧完整落盘
   ▼
 ZSTD_freeCStream()
```

消费模型:输入/输出各是一个三字段结构(`lib/zstd.h:701-711`):

```c
typedef struct ZSTD_inBuffer_s {
  const void* src;    /**< start of input buffer */
  size_t size;        /**< size of input buffer */
  size_t pos;         /**< position where reading stopped. Will be updated. */
} ZSTD_inBuffer;      /* ZSTD_outBuffer 同构,dst 可写 */
```

调用者填 `src/size`,把 `pos` 归零;函数返回后 `pos` 告诉调用者"我吃到哪/写到哪"。
**所有权永远在调用者手里**:zstd 不缓存用户输出指针,只在自己的 `inBuff/outBuff` 里中转
(`zstd_compress_internal.h:512-521`)。返回值不是错误码而是"内部还剩多少待 flush 数据"的
下界估计(`zstd.h:808-812`;单线程实现就是 `outBuffContentSize - outBuffFlushedSize`,
`zstd_compress.c:6571`)。

解压侧对称:`ZSTD_decompressStream`(`lib/decompress/zstd_decompress.c:2084`)是五状态机
`zdss_init → loadHeader → read → load → flush`(`zstd_decompress_internal.h:94-95`),
后文 §2.4。

## 2. 三种 endOp 专节:`ZSTD_e_continue / e_flush / e_end`

语义定义在 `lib/zstd.h:783-794`:continue 让编码器自己决定何时出块(压缩率优先);
flush 立即产出至少一个完整块,但**帧不关**,后续数据仍可引用之前内容;end 出块并写
epilogue 关帧,帧与帧相互独立。

### 2.1 ZSTD_e_continue:能攒就攒

单线程路径 `ZSTD_compressStream_generic` 里,buffered 模式先把用户输入拷进内部 `inBuff`
(`zstd_compress.c:6191-6197`),只有攒够 `inBuffTarget`(一块)才真正压缩:

```c
/* zstd_compress.c:6198-6202 */
if ( (flushMode == ZSTD_e_continue)
  && (zcs->inBuffPos < zcs->inBuffTarget) ) {
    /* not enough input to fill full block : stop here */
    someMoreWork = 0; break;
}
```

即 continue 模式下不满一块直接返回,零压缩输出——这是压缩率与延迟的基本权衡。
MT 路径更宽松:"只要求有进展,不要求最大进展",消费或产出任意字节、或任一缓冲满即返回
(`zstd_compress.c:6543-6549`)。

### 2.2 ZSTD_e_flush:把已交的输入变成可解码字节

flush 强制把 `inBuff` 里未压缩的存量(`inBuffPos - inToCompress`)压成块:

```c
/* zstd_compress.c:6203-6207 */
if ( (flushMode == ZSTD_e_flush)
  && (zcs->inBuffPos == zcs->inToCompress) ) {
    /* empty */
    someMoreWork = 0; break;      /* 存量已清空才返回 */
}
```

代价有二:块不满也要发出(每块 3 字节块头 + 熵编码重新起表,压缩率受损);MT 模式会
**阻塞**到 flush 完成或输出满(`zstd.h:756-757`)。`ZSTD_flushStream` 包装时把
`input.size = input.pos`,即"不再吃新输入,只清库存"(`zstd_compress.c:8180-8182`)。

### 2.3 ZSTD_e_end:关帧

end 做三件事:压缩存量、把最后一块的 `lastBlock` 位置 1(调 `ZSTD_compressEnd_public`
而非 `ZSTD_compressContinue_public`,`zstd_compress.c:6236-6243`)、随后在 flush 阶段
发出 epilogue(含可选 xxh64 校验和)并 `ZSTD_CCtx_reset(session_only)`
(`zstd_compress.c:6296-6300`)。返回 0 才代表帧真正结束。若第一次调用就带 `e_end` 且输出
够大,直接走单遍捷径,块连内部 outBuff 都不进,直接压进用户缓冲
(`zstd_compress.c:6174-6189`;`ZSTD_compress2` 就是这么做的,6596-6625)。
end 之后若返回值非 0,只允许继续 flush/end(`zstd.h:813-814`;MT 路径继续发 continue
会报 `stage_wrong`,`zstdmt_compress.c:1865-1868`)。

另:`e_end` 会把本次输入总量自动当成 pledgedSrcSize,用于参数自适应
(`zstd_compress.c:6394`)。

### 2.4 流式解压:五状态机

`ZSTD_decompressStream`(`zstd_decompress.c:2084-2388`)按 `zdss_*` 状态推进:

- `zdss_loadHeader`(2125):拼帧头(不够就返回提示字节数,2161-2176);若帧内容大小已知
  且输出装得下,走**单遍捷径**直接 `ZSTD_decompress_usingDDict`(2184-2200);
  按帧头声明检查窗口是否超过 `maxWindowSize`(2228-2230),并按需重分配
  `inBuff`(≥ blockSizeMax 与 4 字节校验和的较大者)与 `outBuff`(≈windowSize)
  (2235-2267)。
- `zdss_read`(2271):输入够一整个块就**直接从用户 src 解码**,不经内部缓冲(2280-2286)。
- `zdss_load`(2291):不够则拷入 `inBuff` 攒齐再解(2304)。
- `zdss_flush`(2319):buffered 模式先解进内部 `outBuff` 再拷给用户;拷完后若
  `outBuff` 剩余放不下下一块,回卷 `outStart = outEnd = 0` 复用空间(2329-2335)。
- 防呆:连续 16 次零进展报错(`ZSTD_NO_FORWARD_PROGRESS_MAX`,`zstd_decompress.c:50-51`,
  判定在 2354-2360)。**hostageByte** 技巧:帧解完但输出没拷完时,把 `input.pos` 回退
  1 字节当"人质",逼调用者再来一次调用取走尾部输出,否则返回 1 表示"还有事"
  (2364-2382)。

## 3. Seekable Format 专节:contrib/seekable_format

### 3.1 思路与文件布局

把流切成若干**独立压缩的 zstd 帧**,帧后追加一个装 seek table 的 skippable frame。
普通解码器会忽略跳过帧(向后兼容);感知该格式的解码器用表直接跳帧,实现随机访问。
格式规范:`contrib/seekable_format/zstd_seekable_compression_format.md:19-114`;
README 概述 `contrib/seekable_format/README.md`(选 maxFrameSize ≈ 典型访问粒度,
避免 <1KB 的碎帧)。

```
[帧0][帧1]...[帧N-1][skippable frame: seek table]
                     ├ magic 0x184D2A5E + Frame_Size(4+4B)   (md:39-54)
                     ├ N 条 entry: Compressed_Size(4B)|Decompressed_Size(4B)|[Checksum(4B)]
                     │                                        (md:94-113)
                     └ footer 9B: Number_Of_Frames(4)|Descriptor(1)|Magic 0x8F92EAB1(4)
                                                                (md:58-92)
```

常量:`ZSTD_SEEKABLE_MAGICNUMBER 0x8F92EAB1`(`zstd_seekable.h:14`)、footer 尺寸 9
(`zstd_seekable.h:12`)、最大帧数 `0x8000000`(1.28 亿,`zstd_seekable.h:16`)、
单帧解压上限 1GB(`zstd_seekable.h:19`)。

### 3.2 压缩侧(zstdseek_compress.c)

`ZSTD_seekable_CStream_s` 内嵌一个普通 `ZSTD_CStream` + 一个 frameLog
(`zstdseek_compress.c:52-64`);entry 三元组 `{cSize, dSize, checksum}`
(`zstdseek_compress.c:34-38`)。切帧逻辑极简:

```c
/* zstdseek_compress.c:235 + 256-262 */
inLen = MIN(inLen, (size_t)(zcs->maxFrameSize - zcs->frameDSize));
...
if (zcs->maxFrameSize == zcs->frameDSize) {
    /* log the frame and start over */
    size_t const ret = ZSTD_seekable_endFrame(zcs, output);
    ...
    return (size_t)zcs->maxFrameSize;   /* 提示:本帧已满 */
}
```

`ZSTD_seekable_endFrame`(197-226)调底层 `ZSTD_endStream` 关掉当前帧(201),把
cSize/dSize/checksum(XXH64 低 32 位,214-215)记入 frameLog,然后
`ZSTD_CCtx_reset(session_only)` 开新帧(222)——每帧独立、无背引用。
`ZSTD_seekable_endStream`(353-365)先关最后一帧,再写 seek table;若缓冲太小没写完,
返回 `endFrame + seekTableSize` 让调用者备空间。

`ZSTD_seekable_writeSeekTable`(297-351)与 `ZSTD_stwrite32`(278-295)用
`seekTablePos/seekTableIndex` 记录进度,支持任意小的输出缓冲分多次续写(302-304 注释
明说了这一意图)。

### 3.3 解压侧与随机访问(zstdseek_decompress.c)

加载时只读文件尾:`ZSTD_seekable_loadSeekTable`(374-456)先 seek 到尾部读 9 字节
footer,校验 magic(382)与保留位(390-392),再回头读整张表,把"每帧大小"**换算成
累计偏移**存为 `{cOffset, dOffset, checksum}`,并多造一个哨兵条目方便算"最后一帧的
大小"(413-448):

```c
/* zstdseek_decompress.c:435-440(节选) */
entries[idx].cOffset = cOffset;
entries[idx].dOffset = dOffset;
cOffset += MEM_readLE32(zs->inBuff + pos);  pos += 4;   /* Compressed_Size */
dOffset += MEM_readLE32(zs->inBuff + pos);  pos += 4;   /* Decompressed_Size */
```

`ZSTD_seekable_offsetToFrameIndex` 在 dOffset 上**二分**定位目标帧(296-315)。
`ZSTD_seekable_decompress(zs, dst, len, offset)`(489-582)的随机访问主循环:

1. 二分找 `targetFrame`,seek 到该帧压缩偏移并复位 DStream/XXH64(501-511);
2. 若目标 offset 在帧中部,先把前面的字节"dummy 解压"进内部 `outBuff` 丢弃
   (523-525 注释 "dummy decompressions until we get to the target offset");
3. 到达目标区间后,`ZSTD_outBuffer` 直接指向用户 `dst`(526-528);
4. 帧解完即校验 checksum 低 32 位(556-560);需求跨帧则重新二分、继续循环
   (562-567,外层 `do..while` 在 579);
5. 零输出进展超过 16 次判 IO 错误(135,541-548)。

单帧接口 `ZSTD_seekable_decompressFrame`(584-600)即"解一整帧";单帧压缩大小就是
相邻两个 cOffset 之差(355-360)。`ZSTD_seekTable_create_fromSeekable`(256-277)允许
只拿 seek table 做远程/索引场景。

## 4. 窗口管理专节:windowLog 的滑动与引用

zstd 的"窗口"不是环形缓冲,而是**逻辑索引上的滑动窗口**:数据不需要物理搬动,只维护
几条边界索引(`zstd_compress_internal.h:254-264`):

```c
typedef struct {
    BYTE const* nextSrc;       /* 当前 prefix 段的续写点 */
    BYTE const* base;          /* 正常索引的参考零点 */
    BYTE const* dictBase;      /* extDict 索引的参考零点 */
    U32 dictLimit;             /* 低于此:需去 extDict 找 */
    U32 lowLimit;              /* 低于此:不再有合法匹配 */
    U32 nbOverflowCorrections;
} ZSTD_window_t;               /* ZSTD_WINDOW_START_INDEX = 2 (行266) */
```

- **追加数据** `ZSTD_window_update`(`zstd_compress_internal.h:1376-1412`):若新块与
  上一块内存连续,仅推进 `nextSrc`;**不连续**(流式换缓冲是常态)则把旧 prefix 整体降格
  为 extDict:`lowLimit = 旧dictLimit`、`dictLimit = 当前距离`、base 挪到新缓冲
  (1388-1400)。输入与 extDict 内存重叠时收紧 `lowLimit` 防陈旧引用(1403-1410)。
  调用点:`ZSTD_compressContinue_internal`(`zstd_compress.c:4845-4851`,LDM 窗口同步
  更新)。`lowLimit < dictLimit` 即"正处于 extDict 模式"(1083-1086)。
- **滑动裁剪** `ZSTD_window_enforceMaxDist`(1277-1314):每块压缩前,把
  `lowLimit` 抬到 `blockEndIdx - maxDist`,`maxDist = 1 << windowLog`
  (`zstd_compress.c:4629`);字典末尾一旦滑出窗口,同步置空
  `loadedDictEnd/dictMatchState`(1310-1312)。`ZSTD_checkDictValidity`
  (1322-1354)处理"整块都在窗口边缘"的保守失效。
- **索引溢出纠正**:索引是 U32,长流(>约 2-3.5GB)必须回卷。`ZSTD_CURRENT_MAX`
  64 位下 3500MB(`zstd_compress_internal.h:1053`);`ZSTD_window_needOverflowCorrection`
  (1154-1168)达标后,`ZSTD_window_correctOverflow`(1181-1251)把 base/dictBase 平移
  correction,并把所有表内索引同步减去 correction(`ZSTD_reduceIndex`,
  `zstd_compress.c:4554-4576`)。纠正保留 cycleLog 对齐以免破坏链/树结构
  (1203-1220)。
- 每块的完整纪律在 `ZSTD_compress_frameChunk`(`zstd_compress.c:4629,4655-4661`):
  overflow 纠正 → 字典有效性 → enforceMaxDist → `nextToUpdate` 不低于 `lowLimit`。
- 参数:`ZSTD_c_windowLog=101`(`lib/zstd.h:368-372`),上限 32 位 30 / 64 位 31
  (`lib/zstd.h:1263-1265`);解压侧对应 `ZSTD_d_windowLogMax=100`(`lib/zstd.h:642-646`),
  流式解压在 `zdss_loadHeader` 检查(2228-2230)。

## 5. 设计动机

- **为什么是"推数据+返回剩余量"而不是回调式**:`ZSTD_inBuffer/outBuffer.pos` 模型让
  调用者完全掌控内存与阻塞点,库内部**永不持有用户缓冲引用**(除 stable 模式,且带
  稳定性校验,`zstd_compress.c:6353-6370`)。返回值语义"内部剩余待 flush 下界"
  (`zstd.h:808-812`)足以驱动任何 IO 循环(epoll、管道、文件),不需要回调也不需要
  锁。`examples/streaming_compression.c:57-93` 展示了标准循环:读一块→
  continue/end→写光 output→直到 finished。
- **为什么内部要有 inBuff/outBuff 两级**:压缩以块(默认 128KB)为单位,熵编码的表
  状态跨调用存在;用户的输入粒度任意,所以 buffered 模式先攒块(6191-6197),输出侧
  因为"块压缩不可中断"(6223 注释)而先落 `outBuff` 再拷贝(6278-6294)。代价是两次
  memcpy——追求性能的调用者可开 `ZSTD_bm_stable` 双稳定模式让库直接压用户缓冲
  (免拷但需保证指针稳定,6491-6507 的延迟初始化配合它)。
- **flush 与 end 的代价**:flush 打散块边界 → 更多块头/熵表重置/失去跨块匹配机会,
  MT 模式还会阻塞等 job 出空(`zstd.h:756-757`);end 额外写 epilogue(至少 4 字节
  帧尾 + 可选 4 字节 xxh64)并使 repcode/窗口历史作废——之后是新帧。endStream 在
  单线程下会精确预告"还差多少字节"(lastBlockSize + checksum,
  `zstd_compress.c:8192-8196`),方便调用者确保输出缓冲够大。
- **为什么 Seekable 放在 contrib 而非核心**:seekable 只是**帧的排列约定**+一张表,
  核心格式 RFC 无需改动;它绑定了 FILE/内存读取器和 fseek 语义(`zstdseek_decompress.c:139-195`),
  且参数(maxFrameSize、checksum)是应用层策略,不属于压缩算法本体。放 contrib
  保持 libzstd 小而稳,格式仍可通过 skippable frame 与普通解码器兼容
  (`zstd_seekable_compression_format.md:44-49`)。

## 6. FAQ 素材

1. **Q: compressStream2 返回值是错误码吗?** A: 不是。非错误时是"内部还剩多少数据待
   flush"的下界(`lib/zstd.h:808-812`);单线程恰好等于 outBuff 未拷净字节数
   (`zstd_compress.c:6571`)。用 `ZSTD_isError()` 判错。
2. **Q: e_continue 会丢我的数据吗?** A: 不会。它只保证消费到某处,`input.pos` 记录
   进度,剩余输入下次原样再给(`zstd.h:734-741`)。
3. **Q: 什么时候数据真正写进 output?** A: 攒满一块、或 flush/end 指令时;块压缩不可
   分割,先进内部 outBuff 再拷出(`zstd_compress.c:6223-6294`)。首次调用就 e_end 且
   输出足够时可零中转(6174-6189)。
4. **Q: 为什么 flush 后压缩率下降?** A: 块被截断,块头与熵编码状态重复计费,且
   flush 语义允许后续帧内容继续引用旧数据但**块级**匹配机会减少;end 则彻底分帧。
5. **Q: e_end 返回非 0 怎么办?** A: 继续用 e_end(或 e_flush)直到返回 0;期间发
   e_continue 在 MT 下报 stage_wrong(`zstdmt_compress.c:1865-1868`)。
6. **Q: 解压时 output 多小才够?** A: 推荐每轮至少 `ZSTD_CStreamOutSize()`
   (`zstd_compress.c:5982-5985`);不够不会错,只是进度暂停,靠返回 hint 续喂。
7. **Q: 解压能限制内存吗?** A: 能,`ZSTD_d_windowLogMax` 默认按编译位数设上限
   (`lib/zstd.h:642-646`),超限报 `frameParameter_windowTooLarge`
   (`zstd_decompress.c:2229-2230`)。
8. **Q: Seekable 文件普通 zstd 解压会怎样?** A: 帧顺序拼接,解出完整原文;seek table
   是 skippable frame 被忽略(`zstd_seekable_compression_format.md:34,44-49`)。
9. **Q: Seekable 单帧最大多大?** A: 默认/上限 `ZSTD_SEEKABLE_MAX_FRAME_DECOMPRESSED_SIZE`
   = 1GB(`zstd_seekable.h:19`),因为表项大小字段只有 4 字节(md:98-109)。
10. **Q: Seekable 随机访问要解压多少废数据?** A: 最多一帧:目标 offset 之前的帧内
    字节被"dummy 解压"丢弃(`zstdseek_decompress.c:523-525`),所以 maxFrameSize 应
    ≈ 典型读取粒度(contrib/seekable_format/README.md"Maximum Frame Size"节)。

## 7. 深挖题

1. **stable 缓冲的延迟初始化**:`ZSTD_bm_stable` + e_continue + 输入不足一块时,
   compressStream2 假装消费了输入(`input->pos = input->size`)但记下
   `stableIn_notConsumed`,推迟到攒够一块/flush 才真正初始化并回退 pos
   (`zstd_compress.c:6491-6507,6522-6528,6147-6152`)——参数可因"看到了更多数据"而
   更优,同时用 expectedInBuffer 严查指针稳定性(6496-6497)。
2. **hostageByte 协议**:帧解码完成后若内部 outBuff 尚有字节未拷给用户,把 input.pos
   减 1 扣下最后一字节;只有当 output 全部拷净且调用者再喂回这 1 字节才返回 0
   (`zstd_decompress.c:2364-2382`)。否则调用者会误以为帧结束而丢弃尾巴。
3. **MT 下 endOp 的降级**:输入没吃完时 e_end 自动降级为 e_flush
   (`zstdmt_compress.c:1898-1907`);rsyncable 开启时在内容同步点把 e_continue 升级为
   e_flush(1885-1888)——同一 endOp 在不同配置下产生不同块边界。
4. **U32 索引与 3.5GB 回卷**:为什么窗口用 U32 索引而非 U64?表项省一半内存/缓存;
   代价是长流需 `ZSTD_window_correctOverflow` 整体平移并 `ZSTD_reduceIndex` 重写全部
   表(`zstd_compress.c:4554-4576`),fuzz 构建下可强制频繁纠正做测试
   (`zstd_compress_internal.h:1102-1112`)。
5. **解压单遍捷径的完整性校验**:`zdss_loadHeader` 中,若帧内容大小已知且输出装得下,
   先用 `ZSTD_findFrameCompressedSize_advanced` 确认整个帧都在当前输入里,才敢一次性
   `ZSTD_decompress_usingDDict`(`zstd_decompress.c:2184-2200`)——"看起来够"不够,
   必须验证帧真的完整。

## 8. 写作要点速查表

| 主题 | 位置(仓库相对:行号) |
|---|---|
| in/out buffer 结构与 pos 语义 | lib/zstd.h:701-711 |
| 三 endOp 语义注释 | lib/zstd.h:783-794 |
| CStream=CCtx 别名 | lib/zstd.h:776 |
| compressStream2 主体/返回值 | lib/compress/zstd_compress.c:6475-6572(返回 6571) |
| 透明初始化(pledgedSrcSize 自动) | lib/compress/zstd_compress.c:6377-6471,6488-6510 |
| 单线程状态机 load/flush | lib/compress/zstd_compress.c:6131-6315(捷径 6174-6189) |
| flushStream/endStream 包装 | lib/compress/zstd_compress.c:8178-8198 |
| CCtx 流式字段 inBuff/outBuff | lib/compress/zstd_compress_internal.h:511-527 |
| MT 流式(e_end→e_flush 降级) | lib/compress/zstdmt_compress.c:1854-1924 |
| 解压五状态机 | lib/decompress/zstd_decompress.c:2084-2388(枚举 zstd_decompress_internal.h:94-95) |
| 单遍捷径/hostageByte | lib/decompress/zstd_decompress.c:2184-2200 / 2364-2382 |
| findFrameCompressedSize | lib/decompress/zstd_decompress.c:799-810(逐块 767-795) |
| seek table 格式规范 | contrib/seekable_format/zstd_seekable_compression_format.md:34-114 |
| seekable 压缩切帧/写表 | contrib/seekable_format/zstdseek_compress.c:228-266,297-365 |
| seekable 载表/二分/随机访问 | contrib/seekable_format/zstdseek_decompress.c:374-456,296-315,489-582 |
| seekable 常量(magic/上限) | contrib/seekable_format/zstd_seekable.h:12-19 |
| window 结构与更新 | lib/compress/zstd_compress_internal.h:254-266,1376-1412 |
| enforceMaxDist/溢出纠正 | lib/compress/zstd_compress_internal.h:1277-1314,1154-1251 |
| 每块窗口纪律 | lib/compress/zstd_compress.c:4629,4655-4661(windowLog 参数 lib/zstd.h:368-372) |
