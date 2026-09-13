# 源码深读 · zstd 系列（五）之第 1 章：全景架构与帧/块格式

> 调研对象：facebook/zstd，shallow clone，commit `d79e723`（2025 系列, Merge PR #4781）。
> 本文是格式层总纲：以 `doc/zstd_compression_format.md`（规范 v0.4.5, 2026-05-14）为锚，对照 `lib/` 实现逐行核对。熵编码（FSE/Huffman）、压缩器策略、字典构建、多线程等细节分别留给后续章节。

---

## 1. 全景：一个 zstd 文件的字节布局

zstd 的压缩产物由若干**帧（frame）**串联而成。帧有两类：Zstandard 帧（装数据）与 Skippable 帧（装用户元数据）。单帧布局（doc/zstd_compression_format.md:110-112）：

```
 一个 .zst 文件（多帧串联）
┌────────────┬────────────┬────────────┬──────────────────┐
│ Zstd 帧 #1 │ Skippable帧│ Zstd 帧 #2 │       ...        │
└────────────┴────────────┴────────────┴──────────────────┘
     │              │             │
     ▼              ▼             ▼
┌───────── 单个 Zstandard 帧 ─────────┐   ┌── Skippable 帧 ──────┐
│ Magic_Number │ 4B, LE, 0xFD2FB528  │   │ Magic_Number 4B      │
│ Frame_Header │ 2-14 B              │   │  0x184D2A50~5F (LE)  │
│ Data_Block   │ ≥1 个, 3B头+内容    │   │ Frame_Size   4B (LE) │
│   [更多块…]  │                     │   │ User_Data    n B     │
│ [Checksum]   │ 0-4 B (xxh64 低32)  │   └──────────────────────┘
└─────────────────────────────────────┘
```

三个版本层（自底向上的兼容栈）：

| 层 | magic | 位置 | 作用 |
|---|---|---|---|
| legacy v0.1–v0.7 | 各版本独立 magic | lib/legacy/zstd_legacy.h:58-80 | 解码 0.8.0 之前旧格式，编译开关隔离 |
| zstd（现行） | 0xFD2FB528 | lib/zstd.h:142 | 主体格式，本文核心 |
| skippable | 0x184D2A50–5F | lib/zstd.h:144-145 | 透传元数据，解码器只跳过 |

magic 常量定义在 lib/zstd.h:142-145；字典文件另有 magic 0xEC30A437（lib/zstd.h:143，规范 doc/zstd_compression_format.md:1491-1494）。

解码入口的帧分派骨架：`ZSTD_decompressMultiFrame`（lib/decompress/zstd_decompress.c:1068）→ 逐帧判 magic → 现行格式走 `ZSTD_decompressFrame`，legacy magic 走 `ZSTD_decompressLegacy`（lib/legacy/zstd_legacy.h:121），skippable 帧直接前跳。压缩侧对称地由 `ZSTD_compressBegin_internal`（lib/compress/zstd_compress.c:5266）初始化上下文、`ZSTD_compressContinue_internal`（lib/compress/zstd_compress.c:4820）逐块产出、`ZSTD_compressEnd_public`（lib/compress/zstd_compress.c:5435）收尾。

## 2. 帧头专节：Frame_Header 逐位解

帧头 2–14 字节，结构（doc/zstd_compression_format.md:147-149）：

```
Frame_Header_Descriptor │ [Window_Descriptor] │ [Dictionary_ID] │ [Frame_Content_Size]
        1 B             │       0-1 B         │     0-4 B       │        0-8 B
```

### 2.1 FHD（Frame_Header_Descriptor）逐位

位表（doc/zstd_compression_format.md:157-164）：

| 位 | 7-6 | 5 | 4 | 3 | 2 | 1-0 |
|---|---|---|---|---|---|---|
| 字段 | Frame_Content_Size_flag | Single_Segment_flag | Unused | Reserved(必须0) | Content_Checksum_flag | Dictionary_ID_flag |

- **FCS_flag**：2 位，映射 Frame_Content_Size 字段宽 0或1/2/4/8 字节（doc:177-183）；flag=0 时若 Single_Segment 置位则取 1 字节，否则完全没有 FCS。实现对照：`ZSTD_fcs_fieldSize[4] = {0,2,4,8}`（lib/common/zstd_internal.h:79）。
- **Single_Segment_flag**：置位时整个帧内容必须在一段连续内存中重建，Window_Descriptor 被省略，且 FCS 必须存在——此时 Window_Size 就等于 Frame_Content_Size（doc:185-200）。
- **Reserved_bit**（bit3）：必须为 0，解码器必须拒绝非零值（doc:212-218）；实现见 lib/decompress/zstd_decompress.c:509-510 的 `fhdByte & 0x08` 检查。
- **Checksum_flag**：帧尾追加 xxh64 低 32 位、小端（doc:133-139, 220-223）。
- **DID_flag**：2 位，映射 Dictionary_ID 字段宽 0/1/2/4 字节（doc:231-233）；实现 `ZSTD_did_fieldSize[4] = {0,1,2,4}`（lib/common/zstd_internal.h:80）。

压缩端一次性拼出这个字节（lib/compress/zstd_compress.c:4734-4736）：

```c
U32 const fcsCode = params->fParams.contentSizeFlag ?
                 (pledgedSrcSize>=256) + (pledgedSrcSize>=65536+256) + (pledgedSrcSize>=0xFFFFFFFFU) : 0;
BYTE const frameHeaderDescriptionByte =
    (BYTE)(dictIDSizeCode + (checksumFlag<<2) + (singleSegment<<5) + (fcsCode<<6) );
```

解码端对称拆解（lib/decompress/zstd_decompress.c:500-510）：`dictIDSizeCode=fhdByte&3; checksumFlag=(fhdByte>>2)&1; singleSegment=(fhdByte>>5)&1; fcsID=fhdByte>>6;`。

### 2.2 Window_Descriptor：指数+尾数

仅当 Single_Segment 未置位时存在，1 字节（doc:235-258）：

```
windowLog  = 10 + Exponent;              /* Exponent = byte >> 3, 5 位 */
windowBase = 1 << windowLog;
windowAdd  = (windowBase / 8) * Mantissa; /* Mantissa = byte & 7, 3 位 */
Window_Size = windowBase + windowAdd;     /* 范围 1 KB ~ 3.75 TB */
```

- 10 是下限常量 `ZSTD_WINDOWLOG_ABSOLUTEMIN`（lib/common/zstd_internal.h:78）。
- 解码实现：lib/decompress/zstd_decompress.c:512-518，`windowLog = (wlByte >> 3) + ZSTD_WINDOWLOG_ABSOLUTEMIN`，`windowSize += (windowSize >> 3) * (wlByte&7)`。
- 压缩实现：lib/compress/zstd_compress.c:4733，`windowLogByte = (windowLog - 10) << 3`——注意参考实现编码时尾数恒为 0（只用 2 的幂），尾数位是留给其他编码器的细化空间。
- windowLog 上限：32 位平台 30、64 位平台 31（lib/zstd.h:1263-1265），解码时超限报 `frameParameter_windowTooLarge`（lib/decompress/zstd_decompress.c:515）。

### 2.3 Dictionary_ID 与 Frame_Content_Size

- Dictionary_ID 小端，宽度由 DID_flag 决定；0 等价于"未指定"（doc:277-297）。压缩端按 dictID 数值选宽度：`(dictID>0)+(dictID>=256)+(dictID>=65536)`（lib/compress/zstd_compress.c:4728）。
- Frame_Content_Size 小端；**2 字节形式要加 256 偏移**（doc:306-316）。压缩端写 `pledgedSrcSize-256`（lib/compress/zstd_compress.c:4766），解码端读 `MEM_readLE16+256`（lib/decompress/zstd_decompress.c:535）——两侧互为镜像。
- 单段模式的意义：小文件（≤windowSize）时省掉 Window_Descriptor 且解码端可一次性精确分配 `Frame_Content_Size` 内存；`singleSegment = contentSizeFlag && (windowSize >= pledgedSrcSize)`（lib/compress/zstd_compress.c:4732）。单次 API（ZSTD_compress 等）总是写 FCS（lib/zstd.h:195-196 注释），因此对这类文件解压内存 = 内容本身大小。

## 3. 块层专节：Block_Header 与三种块类型

### 3.1 Block_Header：24 位小端

帧头之后是 ≥1 个块。块头 3 字节小端（doc:327-340）：

```
bit  0    : Last_Block
bits 1-2  : Block_Type
bits 3-23 : Block_Size（21 位）
```

实现就是一次 LE24 读（lib/decompress/zstd_decompress_block.c:62-76）：

```c
U32 const cBlockHeader = MEM_readLE24(src);
U32 const cSize = cBlockHeader >> 3;
bpPtr->lastBlock = cBlockHeader & 1;
bpPtr->blockType = (blockType_e)((cBlockHeader >> 1) & 3);
bpPtr->origSize = cSize;   /* only useful for RLE */
```

压缩端对称地拼（lib/compress/zstd_compress.c:4683-4686）：

```c
U32 const cBlockHeader = cSize == 1 ?
    lastBlock + (((U32)bt_rle)<<1) + (U32)(blockSize << 3) :
    lastBlock + (((U32)bt_compressed)<<1) + (U32)(cSize << 3);
MEM_writeLE24(op, cBlockHeader);
```

### 3.2 三种块类型（第 4 种 Reserved）

枚举 `blockType_e { bt_raw, bt_rle, bt_compressed, bt_reserved }`（lib/common/zstd_internal.h:86），语义（doc:349-374）：

| 类型 | Block_Content | Block_Size 含义 |
|---|---|---|
| Raw_Block (0) | 原样拷贝 | 内容字节数 |
| RLE_Block (1) | 1 字节 | 重复次数（头后仅 1 字节载荷，见 zstd_decompress_block.c:72 `return 1`） |
| Compressed_Block (2) | 压缩流 | 压缩字节数，解压后大小未知但有上限保证 |
| Reserved (3) | 非法，视为数据损坏 | — |

压缩端不可压时自动降级为 Raw（lib/compress/zstd_compress.c:4679-4681 `ZSTD_noCompressBlock`）；帧需要一个"空 last 块"收尾时写出 `lastBlock+bt_raw, size=0` 的 3 字节头（lib/compress/zstd_compress.c:4798-4805）。

解码主循环按类型分派（lib/decompress/zstd_decompress.c:1012-1028）：`bt_compressed → ZSTD_decompressBlock_internal`、`bt_raw → ZSTD_copyRawBlock`、`bt_rle → ZSTD_setRleBlock`、`bt_reserved → 报 corruption_detected`。`lastBlock` 置位即退出循环（zstd_decompress.c:1040），随后校验 FCS 一致性（1043-1046）与可选校验和（1047-1057）。

### 3.3 Block_Maximum_Size = min(Window_Size, 128 KiB) 的推导

规范（doc:388-401）：`Block_Maximum_Size` 是二者的较小者——Window_Size 与 128 KiB。任何块的**压缩前与压缩后大小**都不得超过它。

- 128 KiB 是编译期常量：`ZSTD_BLOCKSIZELOG_MAX 17`、`ZSTD_BLOCKSIZE_MAX (1<<17)`（lib/zstd.h:147-148）。
- 帧级上限在解析帧头时锁定：`zfhPtr->blockSizeMax = MIN(windowSize, ZSTD_BLOCKSIZE_MAX)`（lib/decompress/zstd_decompress.c:544）。小窗口帧（如 windowLog=10 的 1 KB）的块也必须 ≤1 KB。
- 为什么这样设计：解码器在帧头后即可确定两个工作缓冲（输出窗口 + 块缓冲）的尺寸，为后续所有块一次性分配，无需边解边扩。流式解码端正是按 `blockSizeMax` 与 `windowSize` 配置缓冲的：`neededInBuffSize = MAX(blockSizeMax, 4)`，输出缓冲由 `ZSTD_decodingBufferSize_internal(windowSize, frameContentSize, blockSizeMax)` 给出（lib/decompress/zstd_decompress.c:2234-2238；公开接口 lib/decompress/zstd_decompress.c:1986-1989）。
- 反向关系：块 ≤ window 保证**任何块内的匹配距离都不可能超过 Window_Size**，因此解压只需保留最近 window 字节的历史。

### 3.4 压缩块内部（速览，细节留第 2/3 章）

Compressed_Block 分两段：Literals Section（4 类 literals 块 + Huffman 树描述，doc:445-470）与 Sequences Section（变长 nbSeq + 三张 FSE 表的模式字节 + bitStream，doc:639-704）。解码端入口 `ZSTD_decodeSeqHeaders`（lib/decompress/zstd_decompress_block.c:694-777）：nbSeq 变长解码（707-717，`0xFF` 前缀加偏移 `LONGNBSEQ 0x7F00`，lib/common/zstd_internal.h:96），模式字节拆 `LLtype/OFtype/MLtype`（730-732），预留低 2 位必须为 0（729）。序列三要素的基值表在 lib/decompress/zstd_decompress_internal.h:30-56（`LL_base[36]`、`OF_base[32]`、`ML_base[53]`），对应附加位数 `LL_bits/ML_bits` 在 lib/common/zstd_internal.h:119-125, 136-144；符号数上限 `MaxLL=35, MaxML=52, MaxOff=31`（lib/common/zstd_internal.h:103-107），FSE 表精度 `LLFSELog=MLFSELog=9, OffFSELog=8`（108-111）。

## 4. API 分层专节：三层对象模型

lib/zstd.h 的公开 API 呈三层金字塔：

### 4.1 简单层（one-shot）

```c
ZSTD_compress(dst, dstCapacity, src, srcSize, compressionLevel);      /* lib/zstd.h:160 */
ZSTD_decompress(dst, dstCapacity, src, compressedSize);               /* lib/zstd.h:173 */
```

- `ZSTD_compressBound(srcSize)` 给最坏情况输出上界，公式 `srcSize + srcSize/8 + 小文件边距`，且保证 bound(A)+bound(B) ≤ bound(A+B)（lib/zstd.h:249）。
- 元数据探针：`ZSTD_getFrameContentSize`（lib/zstd.h:205）返回三态——真实大小 / `ZSTD_CONTENTSIZE_UNKNOWN`(0-1) / `ZSTD_CONTENTSIZE_ERROR`(0-2)（lib/zstd.h:203-204）；`ZSTD_findFrameCompressedSize`（lib/zstd.h:227）扫完整帧给出压缩大小。
- 错误模型：所有 `size_t` 返回值用 `ZSTD_isError` 探测（lib/zstd.h:259）。

### 4.2 字典层

`ZSTD_compress_usingDict / ZSTD_decompress_usingDict`（懒加载）与 `ZSTD_createCDict / ZSTD_createDDict`（预编译字典，把熵表与匹配结构物化，压缩端见 lib/compress/zstd_compress.c:5266 起的 `ZSTD_compressBegin_internal` 中 cdict 快路径）。帧头 Dictionary_ID 字段就是字典协商的运行时校验位。

### 4.3 流式层与高级参数层

- `typedef struct ZSTD_CCtx_s ZSTD_CCtx;`（lib/zstd.h:280）；**v1.3.0 起 `ZSTD_CStream` 就是 `ZSTD_CCtx` 的别名**（lib/zstd.h:725, 776）。一个上下文 = 一个状态机，可跨多次压缩复用（参数是"粘性"的，lib/zstd.h:727-728）。
- 推荐入口 `ZSTD_compressStream2(cctx, out, in, endOp)`（lib/zstd.h:823，实现 lib/compress/zstd_compress.c:6475），endOp 三档（lib/zstd.h:783-794）：`ZSTD_e_continue`（攒块）、`ZSTD_e_flush`（强制出块、帧不关）、`ZSTD_e_end`（出块并封帧）。解压对称：`ZSTD_decompressStream`（lib/zstd.h:899 附近说明，实现 lib/decompress/zstd_decompress.c:2084）。
- 高级参数层 `ZSTD_compress2`（lib/zstd.h:623，实现 lib/compress/zstd_compress.c:6596-6625）：把参数预先塞进 CCtx（"sticky"参数，lib/zstd.h:323-328），内部复用一次 `ZSTD_compressStream2(..., ZSTD_e_end)`。参数经 `ZSTD_CCtx_setParameter`（lib/zstd.h:570）写入 `requestedParams`，压缩启动时验证并落到 `appliedParams`——这是一条两阶段管道：用户意图 → 校验/裁剪 → 实际生效。
- 关键 `ZSTD_c_*` 参数（lib/zstd.h）：`ZSTD_c_compressionLevel=100`（355）、`ZSTD_c_windowLog=101`（368）、`ZSTD_c_strategy=107`（410）、`ZSTD_c_checksumFlag=201`（462）；解压侧唯一常用参数 `ZSTD_d_windowLogMax=100`（lib/zstd.h:642），约束解码端肯为单帧分配的最大窗口。

### 4.4 window 语义闭环

- 压缩端：windowLog 是**回溯距离上限**（lib/zstd.h:368-374），逐块执行 `ZSTD_window_enforceMaxDist` 把超出窗口的旧引用作废（lib/compress/zstd_compress.c:4658）。
- 解压端：`windowSize` 决定输出环形缓冲大小；流式解码检查 `windowSize > maxWindowSize` 即拒帧（lib/decompress/zstd_decompress.c:2227-2230），`maxWindowSize` 默认 `(1<<27)+1 = 128 MB+1`（`ZSTD_MAXWINDOWSIZE_DEFAULT`，lib/decompress/zstd_decompress.c:39-40；默认值来自 `ZSTD_WINDOWLOG_LIMIT_DEFAULT 27`，lib/zstd.h:1287-1288），可用 `ZSTD_DCtx_setMaxWindowSize`（lib/decompress/zstd_decompress.c:1802-1812）或 `ZSTD_d_windowLogMax` 调整。
- 规范建议解码器至少支持 8 MB 窗口、编码器默认别超过 8 MB（doc:270-272），保证互操作性。

## 5. 与 gzip/lz4 对比：zstd 的定位

| 维度 | gzip (DEFLATE) | lz4 | zstd |
|---|---|---|---|
| 熵编码 | Huffman | 无（纯 LZ77） | Huffman(literals) + FSE(序列) |
| 窗口 | 32 KB 硬编码 | 64 KB 量级 | 可协商 1 KB–3.75 TB |
| 块大小 | 无显式块头 | 4 B 头 | 3 B 头，≤128 KiB |
| 级别 | 1–9 | 1–9（近似） | 1–22 + 负级 |
| 校验 | CRC32 | xxh32（可选） | xxh64 低 32 位（可选） |
| 定位 | 兼容/古董 | 极速低比 | 实时与高比兼顾的甜点 |

zstd 的卖点是把" lz4 的实时性"与" gzip 之上的比率"放进同一格式：低级别用 `ZSTD_fast` 追平 lz4 的吞吐，高级别用 `ZSTD_btultra2` 拿到接近经典高压缩器几十个百分点的比率提升。级别不是 22 套独立代码，而是**参数表**：`ZSTD_defaultCParameters[4][23]`（lib/compress/clevels.h:25）按输入规模分 4 档（>256KB / ≤256KB / ≤128KB / ≤16KB），每行 7 元组 `{windowLog, chainLog, hashLog, searchLog, minMatch, targetLength, strategy}`（lib/compress/clevels.h:27-50）。策略随级别爬升：

```
level 1-2: fast → 3-4: dfast → 5: greedy → 6-12: lazy/lazy2
         → 13-15: btlazy2 → 16-17: btopt → 18-22: btultra/btultra2
```

`ZSTD_MAX_CLEVEL 22`（lib/compress/clevels.h:19）；负级别沿用各级表第 0 行的 fast 参数（lib/compress/clevels.h:28 等）。窗口随级别从 19 递增到 27（"default" 档, lib/compress/clevels.h:29-50）——即默认级别 1-19 解压内存最多约 128 MB，仍在 `ZSTD_WINDOWLOG_LIMIT_DEFAULT` 红线内。

## 6. 设计动机

1. **解压只需 window 大小的内存**：帧头只携带 Window_Descriptor 一个字节（压缩端付出 1 字节换解码端 O(1) 空间承诺）；块大小 ≤ min(window,128KiB) 使"块缓冲 + 滑动窗口"两个缓冲即可解码任意长流（doc:33-36 开篇即声明"先验有界中间存储"）。对比 gzip 固定 32 KB 窗口——zstd 把这个常数变成可协商参数，让"大窗口高比"与"小窗口低内存"各取所需。
2. **magic 与前向兼容**：0xFD2FB528 精心避开 ASCII/UTF8/重复字节模式，降低误识别概率（doc:114-122）。FHD 的 Unused_bit 允许未来版本加"对解码透明的"属性，Reserved_bit 允许加"必须理解的"属性（doc:205-218），配合解码器"不认识就报错"的约定（doc:49-55），格式可在不换 magic 的情况下演化。
3. **Skippable frames**：16 个连续 magic（0x184D2A50-5F）+ 4 字节长度，解码器无需理解内容即可跳过（doc:989-1028）。这让第三方能在串联帧流里插入自定义元数据（分包信息、水印）而不破坏主格式；规范明说它兼容 lz4 的 skippable 帧设计（doc:999）。参考实现的写出接口是 `ZSTD_writeSkippableFrame`（lib/compress/zstd_compress.c:4779-4791）。
4. **legacy 为什么单独目录**：v0.1–v0.7 是 0.8.0 前的七代格式，每代独立 magic 与独立解码器（lib/legacy/zstd_legacy.h:58-80 的 switch 逐版本认 magic）。它们与现行格式不共享任何熵编码代码，放进 lib/legacy/ 并由 `ZSTD_LEGACY_SUPPORT` 编译开关裁剪（默认 8 = 不含任何 legacy 代码，lib/legacy/zstd_legacy.h:24-27），使主库不背历史包袱，嵌入式用户可整体 `-DZSTD_LEGACY_SUPPORT=0` 排除。

## 7. FAQ 素材

1. **Q: 为什么压缩输出总是 0xFD2FB528 开头？** A: 它是现行格式 magic，4 字节小端（doc:114-117；lib/zstd.h:142），自 v0.8.0 起使用。
2. **Q: 帧头为什么是变长的？** A: FHD 字节自描述其余字段有无与宽度（doc:153-155），最省 2 字节（magic 外的 1B FHD + 1B 单段 FCS），最省不出 14 B（规范值；参考实现静态上界 18 B，lib/zstd.h:1257）。
3. **Q: 不读 Frame_Content_Size 能解压吗？** A: 能，用流式 API；FCS 缺省时 `ZSTD_decompress` 无从校验上界（lib/zstd.h:187-194）。
4. **Q: 一个 .zst 文件里能有多帧吗？** A: 能，帧间相互独立、按序串联，解压结果为各帧内容拼接（doc:97-100）；帧间不能互相引用。
5. **Q: 块为什么默认 128 KiB？** A: `ZSTD_BLOCKSIZELOG_MAX 17`（lib/zstd.h:147）；21 位块头也足以表达，且大块利于长匹配与 4 流 Huffman 并行，小块利延迟——但帧窗口小于 128 KiB 时上限跟着缩水（doc:390-396）。
6. **Q: RLE 块 1 字节能表示多大？** A: 最多 2^21-1 次重复，Block_Size 21 位即重复计数（doc:383-384；实现 zstd_decompress_block.c:72）。
7. **Q: 解压恶意文件会被撑爆内存吗？** A: 三道闸——windowLog 上限 30/31（lib/zstd.h:1263-1265）、流式默认 128 MB+1 窗口红线（lib/decompress/zstd_decompress.c:40）、规范明确允许解码器拒绝超出授权范围的内存请求（doc:195-200）。
8. **Q: 校验和是什么哈希？** A: xxh64 原始内容、seed 0，取低 32 位小端存帧尾（doc:133-139）；验证在 lib/decompress/zstd_decompress.c:1047-1057。
9. **Q: 压缩级别怎么映射到实际行为？** A: 查 `ZSTD_defaultCParameters` 参数表（lib/compress/clevels.h:25-130），仅决定 window/搜索深度/策略等 cParams，不改变帧格式。
10. **Q: 单段模式和 windowLog 有什么关系？** A: 互斥省字节： pledgedSrcSize ≤ windowSize 时压缩器自动选单段模式省掉 Window_Descriptor（lib/compress/zstd_compress.c:4732），此时 Window_Size=FCS。

## 深挖方向

1. **块拆分器（pre-block splitter）**：`ZSTD_compress_frameChunk` 里每块大小并非恒 128 KiB，而是 `ZSTD_optimalBlockSize(...)` 按策略与"历史节省额"动态决定（lib/compress/zstd_compress.c:4640-4645, 4691-4705），这是近年压缩比提升的关键之一。
2. **原地解压（in-place）**：`ZSTD_decompressFrame` 对输入输出重叠情形收缩输出边界、把 literals 放进 dst 尾部（lib/decompress/zstd_decompress.c:995-1010；lib/decompress/zstd_decompress_block.c:79-115），内存布局极为讲究。
3. **FSE 表复用与 Repeat_Mode 的跨块状态**：帧内上一压缩块的 Huffman 树/FSE 表可被下一块免描述复用（doc:421-433, 698-704），解压端 `ZSTD_entropyDTables_t` 常驻 DCtx（lib/decompress/zstd_decompress_internal.h:80-87）——字典的本质就是预填这些表。
4. **ZSTD_compressBound 的数学**：为什么最坏情况是 `srcSize + srcSize/8 + 边距`（lib/zstd.h:249）？从 Raw 块 3B/128KiB 开销与块拆分器的最小块尺寸推导，注释里给出了 1 KB/块的保守假设（lib/compress/zstd_compress.c:4691-4697）。
5. **缓冲复用与降配**：流式解码按 `ZSTD_WORKSPACETOOLARGE_FACTOR 3` 判定缓冲超标、持续 128 次后缩容（lib/common/zstd_internal.h:260-267）——长寿命服务的内存治理。

---

## 写作要点速查表

| 事实 | 位置（仓库相对路径:行号） |
|---|---|
| magic 0xFD2FB528 / skippable 0x184D2A50-5F / 字典 0xEC30A437 | lib/zstd.h:142-144 |
| 帧布局表 magic→header→blocks→checksum | doc/zstd_compression_format.md:110-112 |
| FHD 位表（FCS/单段/校验/字典 flag） | doc/zstd_compression_format.md:157-164 |
| Window_Descriptor 指数+尾数公式 | doc/zstd_compression_format.md:245-256 |
| Block_Header 24 位定义 | doc/zstd_compression_format.md:333-340 |
| Block_Maximum_Size = min(window,128KiB) | doc/zstd_compression_format.md:388-396 |
| 压缩端写帧头（FHD 拼装/windowLogByte/单段判定） | lib/compress/zstd_compress.c:4723-4771 |
| 压缩端块循环与 LE24 块头/RLE 降级 | lib/compress/zstd_compress.c:4638-4688 |
| 逐块入口 compressContinue_internal | lib/compress/zstd_compress.c:4820-4879 |
| compressBegin_internal（字典/cdict 接入） | lib/compress/zstd_compress.c:5266-5305 |
| compress2 = reset + compressStream2(e_end) | lib/compress/zstd_compress.c:6596-6625 |
| 解码端帧头解析（FHD 拆位/window/+256 FCS） | lib/decompress/zstd_decompress.c:500-544 |
| 解码端逐块分派循环 | lib/decompress/zstd_decompress.c:984-1041 |
| LE24 块头解析 getcBlockSize | lib/decompress/zstd_decompress_block.c:62-76 |
| 流式 window 红线检查（默认 (1<<27)+1） | lib/decompress/zstd_decompress.c:39-40, 2227-2230 |
| LL_base/OF_base/ML_base 基值表 | lib/decompress/zstd_decompress_internal.h:30-56 |
| MaxLL/MaxML/MaxOff/FSELog 常量 | lib/common/zstd_internal.h:103-111 |
| 级别参数表 4×23 与策略阶梯 | lib/compress/clevels.h:25-130 |
| legacy 七版本 magic 识别 + 编译开关 | lib/legacy/zstd_legacy.h:24-80 |
| skippable 帧写出接口 | lib/compress/zstd_compress.c:4779-4791 |

（本章 commit：d79e723；规范文档版本 0.4.5。行号以该 commit 为准。）
