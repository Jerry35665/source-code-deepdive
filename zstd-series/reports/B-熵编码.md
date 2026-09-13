# B 篇：zstd 熵编码底座——FSE 与 Huffman

> 调研对象：zstd 源码（shallow clone，commit `d79e72359582d2326c63e9669fe05c2f6580fec5`，2026-09-11）。
> 所有行号以该 commit 为准，路径为仓库相对路径，均经 grep -n / Read 实际核对。
> 本文是第五系列第 2 章，聚焦熵编码数学引擎：FSE（tANS 变体）、Huffman（Huff0）与共享位流层。

---

## 1. 全景：熵编码在 zstd 块内的位置

zstd 的一个压缩块（block）拆成三部分：字面量段、序列段、以及块头。熵编码的分工在格式文档里一句话说清：
"Huffman is used to compress literals, while FSE is used for all other symbols (Literals_Length_Code, Match_Length_Code, offset codes) and to compress Huffman headers"（doc/zstd_compression_format.md:1034-1039）。

```
Compressed_Block
├── Literals_Section（字面量段 —— Huffman / Huff0）
│     ├── Literals_Section_Header
│     ├── [Huffman_Tree_Description]        ← 权重本身可用 FSE 压（huf_compress.c:273-279）
│     └── 1 或 4 个 Huffman 位流（4 流时前置 6 字节 jumpTable）
│          格式布局见 doc/zstd_compression_format.md:445
└── Sequences_Section（序列段 —— 3 张 FSE 表）
      ├── Symbols_Decoding_Table_Descriptions（LL/OF/ML 三张表头，各 1-2 bit 模式位）
      │     模式：Predefined / RLE / FSE_Compressed / Repeat（doc:684-696）
      └── Sequence_Bitstream：一个位流交织三个 FSE 状态
            编码顺序 ofCode→mlCode→llCode（zstd_compress_sequences.c:346-349）
```

解码端对应关系：字面量走 `HUF_decompress4X_hufOnly_wksp`（lib/decompress/zstd_decompress_block.c:224），
序列表由 `ZSTD_buildSeqTable` 逐张构建 LL/OF/ML（zstd_decompress_block.c:737-771，内部调 `FSE_readNCount` :681），
序列本体由三个状态 `stateLL/stateML/stateOffb` 在同一位流上交织解码（ZSTD_decodeSequence，zstd_decompress_block.c:1236）。

直觉分工：字面量是"字节 alphabet（256 符号）、静态前缀码"，适合 Huffman；序列的 LL/ML/Off 是"小 alphabet、分布偏斜、每符号只出现一次的模型"，用 tANS 可拿到分数比特精度。连 Huffman 树描述里的权重串也复用 FSE 压缩（最大 tableLog 6，huf_compress.c:137）。

---

## 2. FSE 原理专节：tANS 的状态机视角

### 2.1 直观解释：一张 2^n 行的"概率表"被折成状态机

FSE（Finite State Entropy）是 ANS 家族的 tANS（table variant）。格式文档给出了解码侧的完备定义：
解码表大小为 `Table_Size = 1 << Accuracy_Log`，每行三个字段 `Symbol / Num_Bits / Baseline`，
"An FSE state value represents an index in this table"（doc:1055-1058）。
解码一个符号 = 用当前状态当行号 → 查出 `Symbol`；再从位流读 `Num_Bits` 位，加上 `Baseline` 得到下一状态（doc:1060-1063）。

概率 P 的符号分到 P 行；一行被访问的频率正比于它在表中的占比，于是每符号摊到约 `log2(2^n/P)` 比特——分数比特精度的来源。代码侧的解码结构体正好对应这三元组：

```c
/* lib/common/fse.h:510-515 */
typedef struct
{
    unsigned short newState;
    unsigned char  symbol;
    unsigned char  nbBits;
} FSE_decode_t;   /* size == U32 */
```

`Baseline` 没有显式存储——`newState` 已经是"Baseline 排好序后的基址"，`state = newState + lowBits` 一步完成（fse.h:540-549 的 `FSE_decodeSymbol`）。整个解码是"查表 + 移位 + 加法"，没有除法、没有树遍历，每符号 O(1)。

### 2.2 FSE_normalizeCount：计数 → 2^n 配额（lib/compress/fse_compress.c:465-525）

压缩的第一性问题是：真实直方图 sum(count)=N，而解码表要求 sum=2^tableLog。归一化就是"分配配额"。主算法一行除法搞定：

```c
/* lib/compress/fse_compress.c:475-480（节选） */
static U32 const rtbTable[] = { 0, 473195, 504333, 520860, 550000, 700000, 750000, 830000 };
short const lowProbCount = useLowProbCount ? -1 : 1;
U64 const scale = 62 - tableLog;
U64 const step = ZSTD_div64((U64)1<<62, (U32)total);   /* <== here, one division ! */
int stillToDistribute = 1<<tableLog;
```

- `step = 2^62/total` 把除法提到循环外，循环内只剩乘法+移位（fse_compress.c:486-501）。
- 小概率符号（`count[s] <= total>>tableLog`，fse_compress.c:484,489）直接给配额 1；`useLowProbCount` 决定这个"1"记作 `-1`（省 1 比特表头但解码器要多写一条分支）还是 `1`（fse.h:89-97 注释解释了取舍；zstd 侧的策略是 `nbSeq >= 2048` 才用 -1，zstd_compress_sequences.c:57-64）。
- `proba<8` 时用 `rtbTable` 做"该不该四舍五入进位"的查表修正（fse_compress.c:494-497）。
- 误差残差全部记到最大符号头上：`normalizedCounter[largest] += stillToDistribute`（fse_compress.c:502-507）；若残差过大（≥最大配额的一半）则退回备用算法 `FSE_normalizeM2`（fse_compress.c:379-463），它用 64 位定点步长 `rStep = ((1<<vStepLog)*ToDistribute+mid)/total` 按 count 精确铺分（fse_compress.c:446-460）。

配套的 `FSE_optimalTableLog_internal`（fse_compress.c:357-369）动态决定 tableLog：`maxBitsSrc = highbit32(srcSize-1) - minus` 限制"精度不超样本量"，`FSE_minTableLog`（:348-355）保证 alphabet 能被安全表示；zstd 中 FSE 表上限 `FSE_MAX_TABLELOG=12`（fse.h:612，源自 `FSE_MAX_MEMORY_USAGE 14`，fse.h:582），下限 5（fse.h:616）。

### 2.3 buildCTable 的 spread：为什么要把符号"打散"

表构建两步走（`FSE_buildCTable_wksp`，fse_compress.c:68-214）：

1. **铺符号**：按符号顺序，把每个符号的 `norm[s]` 个副本沿固定步长撒进 `tableSymbol[]`：
   `position = (position + step) & tableMask`，其中 `step = (tableSize>>1)+(tableSize>>3)+3`（`FSE_TABLESTEP`，fse.h:623；格式文档同一公式 doc:1171-1175）。
   概率为 -1 的"低概率符号"从表尾倒着放（`highThreshold--`，fse_compress.c:104-106）。
2. **建转移表**：`tableU16[cumul[s]++] = tableSize + u`（fse_compress.c:170-173），即同一符号的行按表位置升序拿到递增的 newState。

为什么要打散而不是顺序填表？两个原因：

- **数学正确性**：tANS 要求"同一符号的各状态在数值上近似均匀间隔"，这样读出的低 bits 才近似均匀分布；若顺序堆叠，状态转移会退化为周期性的、相关性极强的比特模式，压缩率崩掉。作者本人的解释链接就写在代码注释里："For explanations on how to distribute symbol values over the table: fastcompression.blogspot.fr/2014/02/fse-distributing-symbol-values.html"（fse_compress.c:93-94）。
- **步长选 `(1/2+1/8)*size+3` 这种与 2^n 互素的奇数**，保证铺满整表且高、低区间混排，避免任何规律性。

值得注意的是工程优化版本：当没有 -1 低概率符号时，先按序写进 `spread` 暂存（一次 `MEM_write64` 写 8 份符号），再用免分支的双展开循环撒进表里——注释明说是为了消除变长内循环的 branch miss（fse_compress.c:116-153；解码侧同款优化在 fse_decompress.c:92-134）。

### 2.4 buildDTable 与编码端 symbolTT 的镜像

解码表构建 `FSE_buildDTable_internal`（fse_decompress.c:58-159）的核心三行：

```c
/* lib/common/fse_decompress.c:150-156（节选） */
for (u=0; u<tableSize; u++) {
    FSE_FUNCTION_TYPE const symbol = (FSE_FUNCTION_TYPE)(tableDecode[u].symbol);
    U32 const nextState = symbolNext[symbol]++;
    tableDecode[u].nbBits = (BYTE) (tableLog - ZSTD_highbit32(nextState) );
    tableDecode[u].newState = (U16) ( (nextState << tableDecode[u].nbBits) - tableSize);
}
```

同一符号的第 k 次出现（按表位置序拿到递增 `nextState`），`highbit32(nextState)` 给出它落在哪个"2 的幂区间"，区间差就是读的位数——这正是 doc:1187-1223 那个 5 行示例表（5 个状态、3 个宽 32、2 个宽 16）的代码化。

编码端不存表，而是把每符号信息压成 8 字节的定点数 `FSE_symbolCompressionTransform {deltaFindState, deltaNbBits}`（fse.h:423-426），构建见 fse_compress.c:175-200（`maxBitsOut = tableLog - highbit32(norm-1)` :195）。于是每编码一个符号只是：

```c
/* lib/common/fse.h:454-461 */
MEM_STATIC void FSE_encodeSymbol(BIT_CStream_t* bitC, FSE_CState_t* statePtr, unsigned symbol)
{
    FSE_symbolCompressionTransform const symbolTT = ...[symbol];
    U32 const nbBitsOut  = (U32)((statePtr->value + symbolTT.deltaNbBits) >> 16);
    BIT_addBits(bitC, (BitContainerType)statePtr->value, nbBitsOut);
    statePtr->value = stateTable[ (statePtr->value >> nbBitsOut) + symbolTT.deltaFindState];
}
```

解码还有个 fast 版本 `FSE_decodeSymbolFast`，仅在"没有任何符号概率 >50%"时安全（fse.h:551-553）；`FSE_buildDTable_internal` 据此设 `fastMode` 标志（出现 `norm >= 1<<(tableLog-1)` 即关闭，fse_decompress.c:78-88），运行时静态分派两个编译版本（fse_decompress.c:283-288）。

---

## 3. 位流模型专节：BIT_CStream / BIT_DStream 的容器化设计

`lib/common/bitstream.h` 是 FSE/Huffman 共享的位流层，核心思想是"寄存器容器 + 手动 flush/reload"。

### 3.1 反向语义是整个体系的锚点

位流层开篇就声明："A critical property of these streams is that they encode and decode in **reverse** direction. So the first bit sequence you add will be the last to be read, like a LIFO stack"（bitstream.h:52-55）。FSE 的状态转移天然要求解码逆着编码进行，所以**编码器从缓冲区末尾往前写、解码器从末尾往前读**，格式文档同样强调 "all FSE bitstreams are read from end to beginning"（doc:1044-1049）。zstd 序列编码 therefore 是 `ip` 从 `iend` 起步 `*--ip`（fse_compress.c:551-608），最后 flush 状态的顺序也与解码取初态顺序严格镜像（编码 flush ML/OF/LL，zstd_compress_sequences.c:372-376；解码 init 时先读 LL 再 ML 再 OF）。

### 3.2 一次性 64 位读 + bitsConsumed 游标

```c
/* lib/common/bitstream.h:90-96 */
typedef struct {
    BitContainerType bitContainer;   /* size_t：32 位机 32 位，64 位机 64 位 */
    unsigned bitsConsumed;
    const char* ptr;
    const char* start;
    const char* limitPtr;
} BIT_DStream_t;
```

`BIT_initDStream`（bitstream.h:254-300）一次性把**离末尾最近的一个容器**读进寄存器（`MEM_readLEST`，:263），并用最后一字节的 `highbit32` 定位 endMark 得到 `bitsConsumed` 初值（:264-266）；小于 8 字节的流走 switch 逐字节拼装（:270-291）。读位用 `BIT_lookBits` 从容器顶部取（bitstream.h:330-342），消费只是 `bitsConsumed += nbBits`（:353-356）——**位操作全在寄存器里完成，内存访问被摊薄到每 8 字节一次 reload**。64 位机上一次 reload 保证至少 57 个有效位（`STREAM_ACCUMULATOR_MIN_64 = 57`，bitstream.h:43-44；32 位机为 25，这就是"单次 addBits ≤ 24/25 位"约束的由来，bitstream.h:79）。

`BIT_reloadDStream`（bitstream.h:412-444）返回四态枚举 `unfinished/endOfBuffer/completed/overflow`（:98-102）：`ptr >= limitPtr` 时放心整容器重读；临近 `start` 时切换"谨慎模式"逐字节退（:432-443）；溢出时把 `ptr` 指向一个静态零页而非写坏状态（:415-420）。

编码端镜像操作：`bitContainer |= value << bitPos` 累积（BIT_addBits，:180-188），`BIT_flushBits` 整容器 `MEM_writeLEST` 写出后 `bitContainer >>= nbBytes*8`（:221-231）。关流时补 1 位 endMark（`BIT_closeCStream`，:236-242）——这正是格式文档"compressor writes a single 1-bit ... the last byte cannot be 0"（doc:1244-1247）的实现，也是解码端定位位流边界的依据。

### 3.3 两套更快的特化位流

- FSE 编码用 `FSE_initCState2` 起步让首个符号用最小状态（fse.h:443-452）。
- Huffman 解码有专门的 fast 路径 `HUF_initFastDStream`（huf_decompress.c:151-158）：`readLEST(ip) | 1` 在容器最低位塞一个哨兵 1，之后 `CountTrailingZeros(bits[])` 直接数出已消费位数（huf_decompress.c:796-805, :1621-1627）——把"游标"编码进数据本身，省掉一个独立变量。
- BMI2 到处渗透：`BIT_getLowerBits` 用 `_bzhi`（bitstream.h:162-175），`BIT_getMiddleBits` 在 x86-64 上故意用 `(1<<nbBits)-1` 让编译器折叠成 bzhi（:307-322），HUF 的 `HUF_addBits` 则吃 `shrx` 只读低 6 位的特性（huf_compress.c:882-886）。

---

## 4. Huffman 专节（Huff0）

### 4.1 深度限制：HUF_setMaxHeight 的推平算法（lib/compress/huf_compress.c:376-499）

Huff0 把 tableLog 钳在 `HUF_TABLELOG_MAX 12`、默认 11（huf.h:37-38）。Huffman 树自然构建时可能超深（fse 树是 unlimited 的，huf_compress.c:682-719 的 `HUF_buildTree` 注释直说 "unlimited-depth"），超深后的"推平"不是重建树，而是对排序好的叶子数组做**代价守恒的重排**：

1. 把所有 `nbBits > targetNbBits` 的叶子统一压到 targetNbBits，累计"赚到的"代价 `totalCost`（单位是 2^largestBits 尺度下的份子，`baseCost = 1 << (largestBits - targetNbBits)`，huf_compress.c:385-397）。
2. 把 totalCost 换算到 targetNbBits 尺度（:403-407），然后用 `rankLast[]`（每深度最后一个叶子的下标，:410-421）贪心"还债"：找最小的能减半代价的 rank，把该 rank 的最深叶子加深 1 位（`totalCost -= 1 << (nBitsToDecrease-1); huffNode[rankLast].nbBits++`，:447-449）。
3. 还多了（`totalCost < 0`）就从 rank0 挪最小的叶子补回 rank1（:479-494）。

这是一个离线 Karp 风格的长度受限 Huffman 方案，复杂度 O(alphabet)，不改树结构只改码长，最后仍保持 canonical 排布。构建入口 `HUF_buildCTable_wksp`（:756-792）的流水线是 sort → buildTree → setMaxHeight → 按层分配合法码值（`HUF_buildCTableFromTree`，:731-754，`valPerRank[n] = min; min = (min + nbPerRank[n]) >> 1` :742-747）。排序用的是"192 个桶 + 桶内 quicksort/insertion"的混合（`HUF_sort` :621-666，`HUF_getIndex` 大计数 log2 分桶 :531-535），且 `HUF_OPTIMAL_DEPTH_THRESHOLD = ZSTD_btultra` 以上才启用逐深度试探的 `HUF_flags_optimalDepth`（huf.h:90-91,117；试探循环 huf_compress.c:1300-1324：每个候选 tableLog 实际构建+估尺寸，直到出现尺寸回升）。

### 4.2 CTable 序列化：权重 + FSE 压权重

CTable 每符号是一个 `size_t`：低 8 位存 nbBits，高位存逆序码值 `value << (64-nbBits)`（`HUF_setValue`，huf_compress.c:214-221；格式注释 :824-840）。序列化（`HUF_writeCTable_wksp`，:248-289）先把码长换回权重 `w = huffLog+1-nbBits`（:267-271），然后两条路：

- 路径 A：权重串交给 FSE 压（`HUF_compressWeights` :146-186，tableLog 上限 6），首字节 = FSE 压缩后长度 0-127（entropy_common.c:255,258-259 读端对应）；
- 路径 B：FSE 不划算时直接 4bit×2 打包，首字节 = `128 + (maxSymbolValue-1)`（huf_compress.c:284-288）。

读端 `HUF_readStats`（entropy_common.c:242-306）解析后做三条一致性校验：`weightTotal` 折半和必须是 2 的幂、最后隐式符号的权重必须是"干净的 2 的幂"（:286-298）、rank1 的符号数至少 2 且为偶数（:301）。

### 4.3 4 流设计：为什么是 4

`HUF_compress4X_usingCTable_internal`（huf_compress.c:1168-1216）把输入切成 4 段（`segmentSize = (srcSize+3)/4` :1173），各自独立 Huffman 编码，段长用 3×LE16 的 jumpTable 前置（:1182,1187）。收益有两层：

1. **位流级并行**：解码端 4 个独立 `BIT_DStream_t` 交织解码，主循环"4 流 × 4 符号 = 16 符/轮"（X1 版 huf_decompress.c:653-676；X2 版 :1434-1480），把串行链路上的查表-跳位依赖摊到 4 条流上，ILP 直接受益；
2. **SIMD/手工展开**：fast 路径干脆用 `U64 bits[4]; ip[4]; op[4]` 四路同构循环（`HUF_DecompressFastArgs`，huf_decompress.c:174-182），x86-64 BMI2 上还有纯汇编版 `huf_decompress_amd64.S`（:717-719, :908-909 选择）；X1 fast 循环每流每轮 5 符号、每符号一条 `bits>>53` 查表（:788-794）。

为什么字节数是 4 而非 8/16：4 段保证每段 ≥ 一定长度时仍能摊薄 jumpTable 与 endMark 的固定开销（`cSize > 65535` 直接放弃 4 流，huf_compress.c:1186——即段上限 64KB 与 128KB 块自洽）；且 4 路恰好覆盖通用寄存器额度，8 路会溢出寄存器反而变慢。fast 循环只接受 `dtLog == 11`（`HUF_DECODER_FAST_TABLELOG`，huf_decompress.c:32,220-221）与每流 ≥8 字节（:237），否则回退保守循环。

### 4.4 解码 DT 表：单表查一次出一个（或两个）符号

X1（单符号）解码表 `HUF_DEltX1 { BYTE nbBits; BYTE byte; }` 每项 2 字节（huf_decompress.c:330），表大小 2^dtLog。`HUF_readDTableX1_wksp`（:386-520）构建时先把 tableLog 放大到 `MIN(maxTableLog+1, 11)` 并同步放大权重（`HUF_rescaleStats`，:353-376），让高频符号占据更大的表面积——**用内存换"一次 lookBits 直出符号、无需比较"**。解码一个符号（:522-529）：

```c
/* lib/decompress/huf_decompress.c:522-529 */
FORCE_INLINE_TEMPLATE BYTE HUF_decodeSymbolX1(BIT_DStream_t* Dstream, const HUF_DEltX1* dt, const U32 dtLog)
{
    size_t const val = BIT_lookBitsFast(Dstream, dtLog); /* note : dtLog >= 1 */
    BYTE const c = dt[val].byte;
    BIT_skipBits(Dstream, dt[val].nbBits);
    return c;
}
```

X2（double-symbol）解码表 `HUF_DEltX2 { U16 sequence; BYTE nbBits; BYTE length; }` 每项 4 字节（:954），一格直接存"两个符号的拼串"：权重低（码短）的符号在格内继续挂第二层符号（`HUF_fillDTableX2` 两级填充，:1125-1169），解码时一次 `MEM_readLE32` 查表、`write16` 吐 2 字节、`op += entry>>24` 前进（fast 循环 :1606-1615）。dtLog≤11 时每轮 5 次查表最多产 10 字节（:1316-1324）。X2 是空间换时间的极致：表最大 2^12×4B=16KB，但每符号均摊查表次数近乎减半。选哪个由预标定的耗时表决定：`HUF_selectDecoder` 用 `Q = cSrcSize*16/dstSize` 查 `algoTime[16][2]`（huf_decompress.c:1803-1822,1844），还给省内存的一方 3% 的 cache 加成（`DTime1 += DTime1>>5`，:1848）。

---

## 5. 序列化专节：NCount 的位级格式

FSE 表头（normalized counter）是熵层里最精巧的紧凑编码。写端 `FSE_writeNCount_generic`（fse_compress.c:233-327），读端 `FSE_readNCount_body`（entropy_common.c:41-187），格式文档在 doc:1077-1141 有逐位定义。要点：

- **tableLog 只存 4 位**：`bitStream += (tableLog - FSE_MIN_TABLELOG) << bitCount; bitCount += 4;`（fse_compress.c:252-253），读端 `nbBits = (bitStream & 0xF) + FSE_MIN_TABLELOG`（entropy_common.c:72），即 Accuracy_Log = 低 4 位 + 5（doc:1077-1079）。
- **概率编码 = "剩余配额决定字段宽" + "低值逃逸"**：`remaining` 从 `tableSize+1` 起步（`+1` 是给进位留的余量，fse_compress.c:256），每次读 `nbBits` 位；当值落在"低值区"（`count < max`，`max = (2*threshold-1) - remaining`）时只消耗 `nbBits-1` 位——写端 `bitCount -= (count<max)`（fse_compress.c:291-302），读端对称分支（entropy_common.c:135-142）。小概率因此平均更省位。
- **概率 -1 即"低于 1"**：`Probability = Value - 1`，Value 0 表示概率 -1（doc:1113-1121）；这既是"出现次数为 0~1 的符号"的精确表达，也把表尾保留区留给了 spread（见 2.3）。
- **零游程编码**：概率 0 后跟 2bit 重复标志，0-3，遇到 3 再续一段（doc:1129-1133）。写端把 ≥24 的游程直接写成两个字节的 1（`bitStream += 0xFFFFU`，fse_compress.c:265-274），读端用 CTZ 一次数完 2bit 段：`repeats = ZSTD_countTrailingZeros32(~bitStream | 0x80000000) >> 1`（entropy_common.c:88-103）——小表头是热路径，这里全是位技巧。
- **阈值收缩**：每写/读一个概率，`remaining` 下降，`while (remaining < threshold) { nbBits--; threshold >>= 1; }`（fse_compress.c:302；读端 `nbBits = highbit32(remaining)+1`，entropy_common.c:158-166）——字段宽度随剩余空间对数级缩窄，这保证表头尺寸是"信息论紧"的。
- 边界处理：读端要求 hbSize≥8，不足则拷入栈上 8 字节缓冲重入（entropy_common.c:57-66）；收尾校验 `remaining != 1` 即分布非法（:179）。

Huffman 侧的对应物（权重串的 FSE 化）已在 4.2；两者共享一个事实：**表头本身就是一次完整的熵编码问题**，zstd 连表头都不放过。

---

## 6. 与经典对照：deflate 的 Huffman-only vs zstd 的 FSE+Huffman

deflate 只有 Huffman（动态树+静态树+stored），对 LL/ML/距离码整体使用前缀码，比特数必须是整数。zstd 的拆分是"精度与速度的分工"：

- **字面量用 Huffman**：256 符号 alphabet、分布平稳、且字面量段常常占大头——Huffman 的整数比特损失对字节分布而言很小，而解码端单表 O(1) 查找快到极致（配合 4 流/汇编）。甚至 Huffman 树描述本身再被 FSE 压一层（4.2）。
- **序列用 FSE**：LL/ML/Off 的 alphabet 只有几十个码点，却高度偏斜（大量 0 码），分数比特在这里价值最大；tANS 的"查表+加法"解码也能压住熵编码常见的算力成本。三个 FSE 状态在同一 BIT_DStream 上交织（第 1 节），复用同一容器重载节奏。
- 预定义分布表（Predefined_Mode，zstd_internal.h:119-164 的 LL/ML/OF defaultNorm）相当于 deflate 的 fixed trees，给小块省掉表头。
- 对照现代 rANS（LZ-BitStream/ryg_rans 一类）：rANS 编码侧做除法、解码侧乘法+查表，解码吞吐与 tANS 相当且表构建更简单，但 zstd 选择 tANS 是因为编码端免除法（`step` 一次除法预计算，fse_compress.c:478）、且位流可与其他字段无缝混排——一句话：rANS 更现代更简单，tANS 在 2014 年前后的工程约束下是更优解，且它已经写进了 format。

---

## 7. 设计动机汇总

1. **所有较劲都在"归一化"上**：normalizeCount 的单除法+rtbTable 进位（fse_compress.c:475-507）、M2 备胎（:379-463）、optimalTableLog 的动态降档（:357-369）、以及 zstd 层连"用不用 -1"都要按 nbSeq 决策（zstd_compress_sequences.c:57-64）——归一化直接决定压缩率与表头成本，其余只是搬运。
2. **解码表为什么能 O(1) 每 symbol**：因为把"哈夫曼/算术解码的树遍历、区间比较"全部折进建表（nbBits/newState 在 buildDTable 里一次算好，fse_decompress.c:149-156；X2 连两个符号都折进一格，huf_decompress.c:954）。运行时只剩 lookBits + 一次访存 + skipBits。
3. **4 流与 SIMD 的关系**：4 条独立位流天然消解符号间数据依赖，映射到 4 组指针/容器后编译器与手写汇编（huf_decompress_amd64.S）都能满载乱序流水；这也是"表构建省下的每周期"能兑现的前提。
4. **反向位流不是怪癖而是必要**：tANS 状态转移方程在逆向上才有"读 nbBits 位加 baseline"的简洁形式（doc:1044-1049），整条管线（编码倒着写、endMark 收尾、解码从尾部 init）都由它一个决定派生。
5. **fastMode/fast 路径的静态分派**：用 `forceinline + 模板参数`（`FORCE_INLINE_TEMPLATE`）把分支抬到编译期（fse_decompress.c:286-287、huf_decompress.c:923-928），配合 DYNAMIC_BMI2 的运行时双份编译，是 zstd 全库的统一风格。

---

## 8. FAQ 素材

1. **FSE 和 Huffman 在 zstd 里各管什么？** 字面量段归 Huffman，序列段的 LL/ML/Off 三个码点流归 FSE，Huffman 树描述的权重串也用 FSE 压（doc:1034-1039；huf_compress.c:273-279）。
2. **为什么序列段不用 Huffman？** 小 alphabet 高偏斜分布下分数比特收益大；tANS 解码仍是查表 O(1)，速度不输。
3. **Accuracy_Log 是什么？** 解码表大小 2^AL 的指数，表头低 4 位 + 5（entropy_common.c:72；doc:1077-1079），zstd 内 FSE 上限 12（fse.h:612）。
4. **概率 -1 是什么？** "出现不足 1 次"的符号，Value 0 表示；这些符号只占表尾一行，且使 fastMode 关闭的判定保持简单（doc:1113-1121；fse_decompress.c:81-87）。
5. **为什么 FSE 位流要倒着读？** tANS 编码-解码天然互逆，编码正向写则解码必须逆向读（bitstream.h:52-55；doc:1044-1049）。
6. **表头里的 0xFFFF 是什么？** ≥24 个连续概率 0 的游程缩写，两个字节全是 1（fse_compress.c:265-274），读端 CTZ 一次数完（entropy_common.c:88-103）。
7. **Huffman 深度为什么限制 11/12？** 表常驻内存与解码查表索引宽度（`bits>>53` 需要 dtLog≤11 的 fast 路径）；超深用 HUF_setMaxHeight 做代价守恒推平（huf_compress.c:376-499；huf.h:37-38）。
8. **X1/X2 解码器怎么选？** 按压缩比 Q 与输出规模查预标定耗时表 algoTime，X2（双符号/大表）在高压缩比大数据时更快，还享受 3% cache 加成（huf_decompress.c:1803-1852）。
9. **为什么字面量段常有 4 个流？** 4 流并行解码+汇编循环显著提速；jumpTable 6 字节是唯一开销（huf_compress.c:1182；huf_decompress.c:653-676）。
10. **fastMode 是什么？** 若没有任何符号概率超过 50%，解码可用免分支的 FSE_decodeSymbolFast（fse.h:551-553），表头 1 个 bit 决定走哪个编译版本（fse_decompress.c:78-88,286-287）。

## 9. 深挖线索

1. **fse_decompress.c:92-134 与 fse_compress.c:116-153 的双阶段 spread**：uint64 批量铺 + 双展开免分支撒放，是"小块表构建"优化的教科书案例，注释里写明了动机（branch miss）。
2. **huf_decompress.c:788-805 的哨兵位技巧**：`MEM_read64(ip) | 1` + `ctz` 同时承载"游标位置"与"重载边界"，彻底消灭独立计数器；X2 版（:1606-1628）进一步把第 4 流的解码塞进重载宏以省寄存器（`HUF_4X2_3WAY`，:1630-1660）。
3. **HUF_setMaxHeight 的 rankLast 贪心**（huf_compress.c:410-471）：有限深度 Huffman 的在线修正算法，值得与经典包合并/Karp 对照阅读；`TODO.` 注释（:477）说明作者自己都认为这段值得补文档。
4. **zstd_decompress_block.c:1252-1262（aarch64 memcpy hack）**：把 3 张 FSE 表的行读合并成整 8 字节 load，展示 ZSTD_seqSymbol 64 位设计与 ISA 的配合。
5. **lib/decompress/huf_decompress_amd64.S**：手写汇编的 4 流 fast 循环，与 C 版 `HUF_4X1_DECODE_SYMBOL`（:788-794）逐指令对应，可作"编译器为何打不过手写"的样本。

---

## 10. 写作要点速查表

| 主题 | 文件:行号 | 要点 |
|---|---|---|
| 熵分工总纲 | doc/zstd_compression_format.md:1034-1039 | 字面量→Huffman，序列→FSE |
| FSE 表行结构/解码一步 | lib/common/fse.h:505-515, 540-549 | FSE_decode_t{newState,symbol,nbBits}；state=newState+lowBits |
| 解码表构建 | lib/common/fse_decompress.c:149-156 | nbBits=tableLog-highbit(nextState) |
| 低概率符号置表尾 | lib/common/fse_decompress.c:78-87 | norm==-1 → highThreshold-- |
| CTable 转移表+symbolTT | lib/compress/fse_compress.c:170-200 | tableU16[cumul[s]++]=tableSize+u；定点 deltaNbBits |
| 归一化主算法 | lib/compress/fse_compress.c:465-525 | 单除法 step+rtbTable+残差给最大符号 |
| NCount 写端 | lib/compress/fse_compress.c:233-327 | 4bit tableLog+低值逃逸+0xFFFF 游程 |
| NCount 读端 | lib/common/entropy_common.c:41-187 | CTZ 数零游程 :88-103 |
| 位流容器+反向语义 | lib/common/bitstream.h:52-96 | CStream/DStream；LIFO 读写互逆 |
| reload 四态+endMark | lib/common/bitstream.h:98-102, 412-444, 236-242 | 状态机+1 位收尾 |
| Huffman 深度推平 | lib/compress/huf_compress.c:376-499 | HUF_setMaxHeight 代价守恒 |
| Huffman 4 流 | lib/compress/huf_compress.c:1168-1216 | segmentSize=(srcSize+3)/4, jumpTable 6B |
| Huffman 权重序列化/读端 | huf_compress.c:248-289 + entropy_common.c:242-306 | FSE 压权重 or 4bit 打包 |
| X1 表构建/单符号解码 | lib/decompress/huf_decompress.c:386-520, 522-529 | rescale 至 11、lookBitsFast 查表 |
| X2 双符号表 | lib/decompress/huf_decompress.c:954, 1125-1169 | 4 字节项存两符号 |
| X1 fast 循环 | lib/decompress/huf_decompress.c:788-805 | bits>>53 + ctz 哨兵重载 |
| X1/X2 选择器 | lib/decompress/huf_decompress.c:1803-1852 | algoTime 表+cache 加成 |
| 直方图 4 表并行 | lib/compress/hist.c:320-387 | 16 字节条带、计数器分片 |
| lowProbCount 策略 | lib/compress/zstd_compress_sequences.c:57-64 | nbSeq>=2048 用 -1 |
| 序列三状态编解码 | zstd_compress_sequences.c:311-376 + zstd_decompress_block.c:643-771 | flush ML/OF/LL；ZSTD_buildSeqTable×3 |

（表内未注完整路径者以同行首个 `lib/` 前缀为准；全部行号基于 commit d79e723 实测。）
