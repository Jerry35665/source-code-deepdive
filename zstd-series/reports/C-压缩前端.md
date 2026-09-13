# C 章：zstd 压缩前端 —— match finder 与策略族

> 调研对象：zstd 仓库（shallow clone，commit `d79e723`，"Merge pull request #4781 from facebook/legacy-default-off-followup"）。
> 本文所有行号均为该 commit 下 `lib/compress/` 相对路径的实际行号，已用 grep/Read 核对。

---

## 1. 全景：一条流水线，九种策略

zstd 的帧格式是固定的（序列 = 字面量长度 + 偏移/repcode + 匹配长度），压缩前端的全部工作就是把输入变成"序列串"。**前端不改变格式，只改变"怎么找匹配、怎么挑匹配"**。这个"怎么挑"由 strategy 枚举决定（lib/zstd.h:336-344）：`ZSTD_fast=1, dfast=2, greedy=3, lazy=4, lazy2=5, btlazy2=6, btopt=7, btultra=8, btultra2=9`。

```
 速度轴 <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< 比率轴
 fast    dfast   greedy   lazy    lazy2   btlazy2  btopt  btultra2
 (L1-2)  (L3-4)  (L5)     (L6-7)  (L8-12) (L13-15) (L16-17) (L18-22)
   |        |        |       |        |        |        |        |
 单hash  双hash  hash链  hash链  hash链   二叉树   最优解析  最优解析
 直配    长短表  depth0  depth1  depth2   +lazy    动态规划  +两遍扫描
```

族谱逻辑是一条清晰的强化链（文件与行号见后文专节）：

- fast：每位置只看 hash 表里的**一个**候选（lib/compress/zstd_fast.c:264）。
- dfast：同一位置查**长(8B)/短(4B)两张表**，先试长的再试短的（lib/compress/zstd_double_fast.c:203-222）。
- greedy/lazy/lazy2：hash 链回溯 `searchLog` 个候选（lib/compress/zstd_lazy.c:689,708），区别只在"找到匹配后还愿不愿意再往前看 1~2 步"（depth 参数，lib/compress/zstd_lazy.c:1832,1876,1920）。greedy=0 步，lazy=1 步，lazy2=2 步。
- btlazy2：把 hash 链换成**二叉排序树**（DUBT），同 hash 的历史位置形成有序树，比较次数换更准的候选（lib/compress/zstd_lazy.c:243-390）。
- btopt/btultra2：不再贪心，而是**动态规划**选序列组合，价格模型估熵（lib/compress/zstd_opt.c:1077-1434）。

### 1.1 clevels.h：级别 = 参数表

每一级就是一行 7 元组 `{windowLog, chainLog, hashLog, searchLog, minMatch, targetLength, strategy}`（lib/compress/clevels.h:25-130）。共 4 张表，按 `srcSizeHint` 分档（>256KB / ≤256KB / ≤128KB / ≤16KB），表 ID 的推导在 `ZSTD_getCParams_internal`（lib/compress/zstd_compress.c:8290-8298）：`tableID = (rSize<=256KB)+(rSize<=128KB)+(rSize<=16KB)`。

以"srcSize > 256 KB"主表为例（lib/compress/clevels.h:26-51）：

```
    /* W,  C,  H,  S,  L, TL, strat */
    { 19, 12, 13,  1,  6,  1, ZSTD_fast    },  /* base for negative levels */ (行28)
    { 20, 15, 16,  1,  6,  0, ZSTD_fast    },  /* level  2 */                (行30)
    { 21, 16, 17,  1,  5,  0, ZSTD_dfast   },  /* level  3 */                (行31)
    { 21, 19, 20,  4,  5, 16, ZSTD_lazy2   },  /* level  8 */                (行36)
    { 22, 22, 22,  4,  5, 32, ZSTD_btlazy2 },  /* level 13 */                (行41)
    { 22, 22, 22,  5,  5, 48, ZSTD_btopt   },  /* level 16 */                (行44)
    { 27, 27, 25,  9,  3,999, ZSTD_btultra2},  /* level 22 */                (行50)
```

规律：windowLog（19→27）决定搜索窗；searchLog（1→9）是每次搜索的候选预算 `2^searchLog`；minMatch 从 6 降到 3（允许更短匹配）；targetLength 在 opt 级是 DP 的"足够长即停"阈值（999 意味着几乎不早停）。**负级别**也走这张表：row 0 是负级基线，`targetLength = -level` 变成大步跳跃的步长（lib/compress/zstd_compress.c:8305-8310）。

所有策略函数都把结果写进同一个 `SeqStore_t`（字面量缓冲 + `SeqDef` 数组），落库函数 `ZSTD_storeSeq`（lib/compress/zstd_compress_internal.h:798-833）接收 `(litLength, literals, offBase, matchLength)` 五元组；wildcopy 加速字面量拷贝（行 820-826）。策略解耦了"找匹配"与"编码"——后面接 FSE/Huffman 的部分（B 章内容）对所有策略一视同仁。

### 1.2 分发：两级表驱动

入口 `ZSTD_buildSeqStore`（lib/compress/zstd_compress.c:3292）→ `ZSTD_selectBlockCompressor`（lib/compress/zstd_compress.c:3097）。后者是一张 `[dictMode][strategy]` 的二维函数指针表（行 3099-3143），共 4 个 dictMode（noDict/extDict/dictMatchState/dedicatedDictSearch）× 9 个策略；若启用了 SIMD 行式匹配器（greedy~lazy2 支持，行 237-247），则换用另一张 row 版表（行 3150-3171）。函数指针最终在行 3443-3448 被调用。

窗口管理：匹配器可跨块引用历史，靠 `ZSTD_window_t`（lib/compress/zstd_compress_internal.h:249-264）——`base` 指向当前缓冲、`dictBase` 指向"上一个"缓冲。流式输入不连续时，`ZSTD_window_update`（internal.h:1376-1412）把旧前缀降级为 extDict（`dictBase=旧base; base=新输入`，行 1395-1396），这正对应流式模式下 `inBuff` 双缓冲的轮换（分配在 lib/compress/zstd_compress.c:2280）；即匹配器看到的永远是"当前缓冲 + 上一缓冲"两段连续内存，32 位索引 + `dictLimit/lowLimit` 两个分界线把两段统编址。有效候选下界的计算收敛于两个内联函数：`ZSTD_getLowestMatchIndex`（窗口/字典全局下界，internal.h:1417-1429）与 `ZSTD_getLowestPrefixIndex`（仅当前前缀，行 1434-1448）；fast/dfast 用后者（候选只在前缀内），lazy/opt 用前者（可下潜到 extDict/字典）。

### 1.3 数据结构对照：同一份 MatchState，各策略各取所需

`ZSTD_MatchState_t`（internal.h:272-315）持有三张预分配表 `hashTable / hashTable3 / chainTable`（行 290-292）加 row 模式的 `tagTable`（行 285），各策略的解释完全不同：

| 策略 | hashTable | chainTable | hashTable3 | 备注 |
|---|---|---|---|---|
| fast | mls 字节 hash，单槽覆盖 | 不用 | 不用 | zstd_fast.c:198 |
| dfast | 8 字节 hash，单槽覆盖 | 复用为 mls 字节第二张单槽表 | 不用 | zstd_double_fast.c:110-112 |
| greedy/lazy/lazy2 | 链头表 | 前驱链（chainLog） | 不用 | zstd_lazy.c:637-640 |
| lazy2(row) | 行内候选 | 不分配 | 不用 | tagTable 替代，zstd_lazy.c:1185 |
| btlazy2 | 链头表 | 隐式二叉树（chainLog-1，2 U32/位） | 不用 | zstd_lazy.c:259-261 |
| btopt+ | 树的链头 | 同 btlazy2 | 3 字节专用表（hashLog3） | zstd_opt.c:452-453,411-430 |

`hashTable3` 只在 opt 且 minMatch==3 时启用（zstd_opt.c:699-712 的 "HC3 match finder"），因为 3 字节匹配偏移/长度收益薄、误碰撞高，值得单独一张大表精确索引。

---

## 2. fast / dfast：hash 表的两档速射

### 2.1 fast：单槽 hash + 手工流水线

`ZSTD_compressBlock_fast_noDict_generic`（lib/compress/zstd_fast.c:192-423）。结构极简：一张 `hashTable`，`matchIdx = hashTable[hash0]`（行 264）直接取唯一候选，4 字节命中即成匹配（`ZSTD_match4Found_cmov`，行 102-125）。

它的灵魂是注释里那张流水线图（行 144-189）：hash→查表→读候选→比较四步各有缓存时延，代码把相邻位置的四个阶段交错起来（H/T/M 标记，行 166-174），像 CPU 流水线一样跑；找到匹配就"冲刷流水线"重进循环（行 180-188）。

行号要点：
- 步长即 targetLength：`stepSize = targetLength + !targetLength + 1`，最小 2（行 200）——这就是负级别"加速"的实现点，targetLength 越大跳得越猛；且步长在长距离无匹配时会自增（行 342-347），配合 `kStepIncr = 1<<(kSearchStrength-1)`（行 234，kSearchStrength=8，internal.h:32）。
- repcode 优先：循环内先查 `rep_offset1` 在 ip2 处的 4 字节命中（行 268-290），命中直接 `REPCODE1_TO_OFFBASE`——**不查 hash 表**，一次读一次比就出序列。
- 插入即覆盖：`hashTable[hash0] = current0`（行 272），单槽表新位置永远顶掉旧位置，无冲突处理。
- 匹配后补插 + 立即 repcode：匹配尾部回填两个表项（行 407-408），然后 while 循环连吃 `rep_offset2` 的后续重复（行 410-420）——`/* faster when present ... (?) */` 这个保留疑问的注释从 2016 年留到了今天。
- mls 变体：minMatch 4~7 各生成一个特化函数（宏 `ZSTD_GEN_FAST_FN`，行 425-441），cmov 与分支两种候选校验按 `windowLog < 19` 选择（行 449）——小窗口候选大多有效用分支，大窗口不可预测用 cmov。
- 越界 repcode 恢复：块首若 rep 超出窗口先置 0 并暂存（行 238-244），块尾按规则恢复（行 350-372），保证 rep 历史跨块语义正确。

字典模式下 fast 换用带标签的双 hash：`dictMatchState_generic`（行 483-679）在字典 hash 上附 8 位 tag（`ZSTD_hashPtr(ip, dictHBits, mls)` 返回 hash+tag 的和类型，行 546），先比 tag 再比 4 字节内容，把字典误碰撞的内存访问降到接近零——CDict 预填充走 `ZSTD_fillHashTableForCDict`（行 16-49），与 CCtx 的逐步填充（行 53-96）分开成两条实现。

### 2.2 dfast：长表抓长匹配，短表抓覆盖

`ZSTD_compressBlock_doubleFast_noDict_generic`（lib/compress/zstd_double_fast.c:105-323）。两张表：`hashLong`（8 字节 hash，占 hashTable）+ `hashSmall`（mls 字节 hash，**复用 chainTable**，行 25/110-112）。为什么快？一次读 8 字节查长表，命中即得 ≥8 匹配（行 206-211），无 8 匹配再查短表 4 字节（行 217-222），且找到短匹配后还会看 ip1 处的长表候选能否"反超"（`_search_next_long`，行 253-273）。**8 字节读与 4 字节读同价，但 8 字节命中意味着更少序列、更短偏移码流**——这是 dfast 在几乎同 fast 的开销下比率明显更好的关键。

填充阶段也是双表联动：`fillDoubleHashTableForCDict` 每隔 `fastHashFillStep=3` 位置双插，非空槽才插长表（行 30-53）。匹配后补插在 `_match_stored`（行 297-304）：`curr+2` 与 `ip-2/ip-1` 双表回填，再连吃 `offset_2` 立即 repcode（行 308-320）。

### 2.3 fast 路径的 repcode

fast/dfast 的共同模式：**repcode 检查先于 hash 搜索**（fast 行 275、dfast 行 190-195），序列落库后又有"立即 repcode"循环（fast 行 410、dfast 行 308）。原因：repcode 匹配零查表成本（偏移已知），且 RLE 类重复（日志、表格）在真实数据里密集出现。可以说 fast 的实际比率有一大半是 repcode 撑起来的。

---

## 3. lazy 专节：hash chain、binary tree 与"再看一步"

### 3.1 hash chain（greedy/lazy/lazy2 共用 HC4）

- `NEXT_IN_CHAIN(d,mask) = chainTable[(d)&mask]`（lib/compress/zstd_lazy.c:626）：chainTable 是"同 hash 前驱索引"数组，hashTable 存链头。
- 插入：`ZSTD_insertAndFindFirstIndex_internal`（行 632-657）把 `nextToUpdate` 到当前位置之间逐位置入链（头插，行 647-648）。
- 搜索：`ZSTD_HcFindBestMatch`（行 667-773）沿链走，预算 `nbAttempts = 1 << searchLog`（行 689），每步先 `MEM_read32(match+ml-3)` 快速否决（行 714，比较匹配尾部字节，失败即跳过完整 count），保留最长者（行 724-728）。

**chain 与 bt 的取舍**：hash chain 内存 O(chainLog)，插入 O(1)，但链是无序的，回溯像开盲盒，`searchLog` 次预算可能全花在近处的短候选上。二叉树内存同是 chainTable（复用！），插入 O(searchLog)，但同 hash 候选按字典序有序，同样的预算能保证"每一步都比上一步更接近最优"。

### 3.2 binary tree（btlazy2，DUBT）

树本身不存在——它是 `bt[2*(idx&btMask)]` 两个 U32（smaller/larger 指针）散布在 chainTable 上的**隐式二叉排序树**，`btLog = chainLog - 1`（lib/compress/zstd_opt.c:452-453；lib/compress/zstd_lazy.c:259-261）。窗口滚动即环形复用：`idx & btMask` 让新位置覆盖旧槽位。

- `ZSTD_DUBT_findBestMatch`（lib/compress/zstd_lazy.c:243-390）：先沿"未排序标记"（`ZSTD_DUBT_UNSORTED_MARK`）把上次插入后挂起的新候选串起来（行 276-287），再**批量**把它们插进树（`ZSTD_insertDUBT1`，行 299-307），最后在树中一次二分找最长匹配（行 310 起）。这个"惰性批量插入"是节点复用的核心：一次搜索顺带把多个待插位置完成，摊薄树维护成本。
- `ZSTD_insertBt1`（lib/compress/zstd_opt.c:442-558，opt 族使用）：单位置插入，下降路径上顺便记录 `commonLengthSmaller/Larger`，避免重复比较；返回值是"可以一次跳过几个位置"——若当前位置有超长匹配，中间位置全部不需要入树（行 553-557）。`ZSTD_updateTree_internal`（行 562-581）按此推进 `nextToUpdate`。

### 3.3 "再往前看一步"：lazy 的 gain 公式

主循环 `ZSTD_compressBlock_lazy_generic`（lib/compress/zstd_lazy.c:1560-1823），depth 为 0/1/2 分别对应 greedy/lazy/lazy2（行 1832/1876/1920）。当前匹配 (matchLength, offBase) 与前进 1(或 2) 字节后的新候选比较：

```c
size_t const ml2 = ZSTD_searchMax(ms, ip, iend, &ofbCandidate, ...);
int const gain2 = (int)(ml2*4 - ZSTD_highbit32((U32)ofbCandidate));   /* raw approx */
int const gain1 = (int)(matchLength*4 - ZSTD_highbit32((U32)offBase) + 4);
if ((ml2 >= 4) && (gain2 > gain1)) { ... continue; }   /* 换新解，继续找 */
```
（行 1699-1706；depth2 版在行 1735-1742，repcode 候选版在行 1677-1683/1712-1718）

`ml*4` 估匹配收益、`highbit32(offBase)` 估偏移的位宽代价（偏移越大越贵）——这就是 lazy 家族的"微价格模型"，没有熵表，纯线性近似。**lazy2 的额外一步**（行 1709-1742）意味着一次决策最多向后推挤 2 个位置；更远的不满由 targetLength（TL 参数）弥补不了，这正是 13 级之后改用 btlazy2/btopt 的原因。

另一个速度技巧是 lazy skipping：连续 2KB 无匹配后步长 >8（`kLazySkippingStep=8`，行 20），进入"只插被搜索位置"模式（行 1660-1667、internal.h:309-314 的 `lazySkipping` 字段；hash chain 侧在 internal 插入处生效，行 651-652）。

### 3.4 dedicatedDictSearch：字典的预分桶索引

小字典 + 高频冷启动场景（zstd --train 产物）走 `ZSTD_dedicatedDictSearch`：建字典时把 dictMatchState 的 hash 链重排成每桶 `2^ZSTD_LAZY_DDSS_BUCKET_LOG=2` 项的扁平桶（lib/compress/zstd_lazy.h:22；`ZSTD_dedicatedDictSearch_recoverIndex` 一族在 zstd_lazy.c:420-510 附近），搜索时一次 prefetch 拿到两个候选（`ZSTD_dedicatedDictSearch_lazy_search`，行 529-620），省掉链式追踪的多次缓存未命中。代价是字典格式与普通 dict 不兼容（需 `ZSTD_c_enableDedicatedDictSearch`），且只服务 lazy 家族（selectBlockCompressor 第 4 行 dictMode 列，zstd_compress.c:3133-3142）。

### 3.5 row-based matchfinder（lazy 家族的 SIMD 皮肤）

`useRowMatchFinder` 打开时（greedy~lazy2，zstd_compress.c:237-247），同一套 lazy 主循环改调 `ZSTD_RowFindBestMatch`（lib/compress/zstd_lazy.c:1185）：hash 空间切成行（每行 `searchLog` 槽，`ZSTD_ROW_HASH_MAX_ENTRIES=64` 行 780），tag 表存 8 位标签（lib/compress/zstd_lazy.h:24），SIMD 一次比较整行得 mask（`ZSTD_VecMask`，行 784-792）。数据结构不同，语义与 chain 版一致——所以主循环可以完全复用，只换 `searchMax` 分发的搜索函数（`searchMethod_e`，行 1468；分发行 1531-1556）。

---

## 4. btopt 专节：最优解析与价格模型

### 4.1 价格模型：以比特为单位的固定点数

optState（internal.h:226-247）维护四张频率表（litFreq/litLengthFreq/matchLengthFreq/offCodeFreq），价格以 `BITCOST_MULTIPLIER` 为 1 bit 的定点数（lib/compress/zstd_opt.c:25-36，BITCOST_ACCURACY=8 即 1/256 bit 精度）。`ZSTD_bitWeight = highbit32(stat+1)`（行 43-47）近似 -log2(p)；btultra 用 `ZSTD_fracWeight` 线性插值出分数比特（行 49-62）——**这就是 btultra 比 btopt 慢的微观原因之一：每符号每候选都做更贵的估值**。

三段价格函数：
- `ZSTD_rawLiteralsCost`（行 266-291）：逐字节 `litSumBasePrice - WEIGHT(litFreq[c])`，未压缩模式固定 8 bit/字节（行 273-274），小输入用预定义 6 bit（行 276-277）。
- `ZSTD_litLengthPrice`（行 295-315）：LL 符号代价 + 附加位 `LL_bits[llCode]`。
- `ZSTD_getMatchPrice`（行 323-352）：offCode*1bit + ML 符号 + ML 附加位；**长距离惩罚**：`offCode >= 20` 时加 `(offCode-19)*2` bit（行 340-341，照顾解压速度）；再加 1/5 bit 的"少些序列"启发（行 348）。

统计初始化 `ZSTD_rescaleFreqs`（行 140-261）：首块无字典时直接对源做直方图（行 218-219）+ 人工先验（LL/offset 的 base 表，行 222-247）；有字典时从字典的 Huffman/FSE 表反推频率（行 158-210）；后续块把累计频率降采样作种子（行 251-258）。每产生一条真实序列，`ZSTD_updateStats`（行 356-387）回写频率——**价格模型在块内自我进化**。

DP 内层的价格以宏速记（lib/compress/zstd_opt.c:1070-1072）：`LIT_PRICE(p)` 单字面量价、`LL_PRICE(l)` 字面量长度符号价、`LL_INCPRICE(l) = LL_PRICE(l) - LL_PRICE(l-1)` 是"多 1 个字面量的边际价"——它可以小于 0（LL 符号落进更便宜的桶），正因如此 opt 解析器才有"匹配尾巴 +1 字面量反而更便宜"的修正分支（行 1219-1244）。调试视角的价格换算在 `ZSTD_fCost`（行 71-76）。

### 4.2 状态推进：前向 DP + 回溯

`ZSTD_compressBlock_opt_generic`（行 1077-1434）。`opt[pos]` 是块内相对位置的 DP 表（`ZSTD_optimal_t`：price/mlen/litlen/rep，internal.h:218-223；`ZSTD_OPT_NUM = 1<<12`，lib/common/zstd_internal.h:62）。流程：

1. 首匹配初始化 opt[0]（行 1143-1152），预填 minMatch..maxML 的初价（行 1171-1196）；超长匹配（`> sufficient_len = MIN(targetLength, ZSTD_OPT_NUM-1)`，行 1096）直接"立即编码"（行 1160-1169）。
2. 前向推进 `for (cur = 1; cur <= last_pos; cur++)`（行 1200）：每位置先试"上一状态 + 1 字面量"（行 1206-1211，价格差含 `LL_INCPRICE`），再 `getAllMatches` 收集全部候选（行 1278），对每个候选的每个长度自长到短刷价格（行 1305-1336）。btopt（optLevel=0）在这里有两处剪枝：下一位置更便宜就跳过（行 1268-1272，注释自称 ~+6% 速度）与"价格没有更好立即终止内层"（行 1334，~+10% 速度）。**btultra（optLevel=2）不剪**，且用精确分数比特——慢一个数量级由此而来。
3. 匹配选定后用 `ZSTD_newRep` 更新该状态的 rep 历史（行 1254-1261）——**DP 状态里带 rep 三元组**，因为 repcode 代价是路径依赖的。
4. `_shortestPath` 回溯（行 1340-1429）：沿 mlen/litlen 链倒走，把"stretch"（匹配+后续字面量）翻转回"序列"（字面量+匹配）落库（行 1404-1424），随后 `ZSTD_setBasePrices` 刷新基价（行 1428）。

### 4.3 为什么 btultra 慢一个数量级

三重叠加：(a) optLevel=2 用 fracWeight 精确估值（行 36），每个候选贵几倍；(b) 不做 btopt 的两级剪枝（行 1268-1272、1334）；(c) btultra2 还要**两遍扫描**：首块先跑一遍 opt2 只为收集统计（`ZSTD_initStats_ultra`，行 1476-1499），再真压一遍（`ZSTD_compressBlock_btultra2`，行 1509-1535，注释明说"首块 ~2x CPU 换 ~0.5% 比率"，行 1516-1523）。加上 clevels 里 btultra2 的 targetLength 高达 256~999（clevels.h:47-50），DP 窗口几乎不早停。

---

## 5. LDM 专节：长距离匹配的分桶与过滤

LDM 解决的问题：windowLog 拉到 27（128MB，`ZSTD_WINDOWLOG_LIMIT_DEFAULT`，lib/zstd.h:1287）以上时，主匹配器的 hash 表已被撑爆，远处（GB 级）重复找不到。启用条件是 auto 模式下 `strategy >= btopt && windowLog >= 27`（lib/compress/zstd_compress.c:289-293）。

核心是"内容定义切分"（gear hash）+ 分桶去重（lib/compress/zstd_ldm.c）：

- **gear hash 定锚**：`ZSTD_ldm_gear_feed` 用滚动 hash（`hash=(hash<<1)+gearTab[c]`，行 108 起，表在 zstd_ldm_geartab.h）扫描，hash 低位为 0 处即切分点，切分密度由 `hashRateLog` 控制。参数推导在 `ZSTD_ldm_adjustParameters`（行 135-171）：`hashRateLog = 7 - strategy/3`（行 151，fast→7 档稀疏，btultra2→4 档密集）；`minMatchLength` 默认 64，btultra 以上减半（行 161-165）。
- **桶**：hash 后再丢低位形成桶（`getBucket = hashTable + (hash << bucketSizeLog)`，行 190-194），每桶 `2^bucketSizeLog` 个 `ldmEntry_t{offset, checksum}`（internal.h:323-326），插入是桶内轮转覆盖（`bucketOffsets`，行 198-208）。bucketSizeLog 下限由策略定（行 166-170）——**策略越高，桶越大，候选越多**。
- **校验过滤**：切分点用 `XXH64(minMatchLength 字节)` 高 32 位做 checksum（行 395-400），桶内候选先比 checksum（行 431）再真正 `ZSTD_count`（行 442-457），前后向扩展取总长最优（行 458-465）。
- **重叠去重**：长重复模式（全零文件）命中后直接跳到锚点后重置 hash（行 501-511，注释称 20x 加速）。
- 产出 `rawSeq` 交回主流程：`ZSTD_ldm_blockCompress`（行 685-749）对 opt 级策略只把 LDM 序列**作为候选**注入 DP（行 702-708 走 `ms->ldmSeqStore` → `ZSTD_optLdm_processMatchCandidate`，zstd_opt.c:1021 起）；对 fast 级策略则切段后逐段调用普通块压缩器并手工维护 rep（行 713-743）。切段由 `maybeSplitSequence`（行 644-682）完成：序列超过块尾或 minMatch 约束时截断，被截掉的 matchLength 若不足 minMatch 则整段降级为字面量（offset=0 语义，行 658-668）。

---

## 6. repcode 专节：三个槽位的复利

格式规定每序列偏移可为"引用最近用过的三个偏移之一"（1 字节编码）。三槽 `rep[3]` 与更新规则在 internal.h：

```c
ZSTD_updateRep(U32 rep[ZSTD_REP_NUM], U32 const offBase, U32 const ll0)
{
    if (OFFBASE_IS_OFFSET(offBase)) {  /* full offset */
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = OFFBASE_TO_OFFSET(offBase);
    } else {   /* repcode */
        U32 const repCode = OFFBASE_TO_REPCODE(offBase) - 1 + ll0;
        if (repCode > 0) {  /* note : if repCode==0, no change */
            U32 const currentOffset = (repCode==ZSTD_REP_NUM) ? (rep[0] - 1) : rep[repCode];
            rep[2] = (repCode >= 2) ? rep[1] : rep[2];
            rep[1] = rep[0];
            rep[0] = currentOffset;
        } ...
```
（lib/compress/zstd_compress_internal.h:839-857；offBase 编码宏在行 743-748，repcodes_t 在行 859-861）

要点：
- **offBase 求和类型**：1/2/3 表示 repcode ID，>3 表示真偏移（值减 3）。一条编码走哪条更新分支由它决定。
- **ll0 语义**：litLength==0 时 rep1 不可用（否则自引用），序列实际引用的是 rep2/rep3，`-1+ll0` 完成槽位换算；`repCode==3` 特殊处理 `rep[0]-1`（连发 rep2 时偏移微调 1，源自格式定义）。
- **使用即前置**：用 rep_k 产生序列后它成为新 rep1，原 rep1 顺移为 rep2——LRU 语义。
- 为什么是"秘密武器"：偏移字段从"绝对距离"变成"最近 3 个距离的引用"，只需 ~1-2 bit（btopt 价格里 repcode 的 offCode=0，`ZSTD_getMatchPrice` 行 330）。对结构化数据（表格列、日志时间戳、PARQUET 行组），同一偏移反复出现的分布极厚，repcode 把这些偏移的编码成本摊薄到近零。所以每个匹配器都要：入口先试 rep（fast zstd_fast.c:275、lazy zstd_lazy.c:1644-1648、opt 的 repcode 候选 zstd_opt.c:644-698）、出口连吃立即 rep（fast 行 410-420、dfast 行 308-320、lazy 行 1801-1811）。opt 解析器甚至把 rep 三元组嵌进每个 DP 状态（zstd_opt.c:1254-1261），`ll0` 在候选收集中影响首个 repcode 的取值（行 644-646）。

---

## 7. 与前作对照

- **deflate（zlib/gzip）**：压缩前端只有一条路径——hash 链 + greedy（level 1-3）或 greedy+lazy 二选一（level 4-9，lazy_match/max_chain 等参数调节），"策略"不换、只换预算。zstd 则把"策略"升格为一等公民：9 个策略 × 4 种字典模式 × mls 变体的模板矩阵，编译期特化（`ZSTD_GEN_FAST_FN` zstd_fast.c:425、`ZSTD_BT_GET_ALL_MATCHES_FN` zstd_opt.c:854-878）。
- **FFmpeg/PG 系列"级别即参数表"**：与 FFmpeg 的 flac/lavc preset、PG 的 codegen 级别类似，zstd 的 1-22 级不是代码分支而是**纯数据**（clevels.h 一张 4×23 常量表）。区别在于 zstd 的表里混入了"策略"这一离散维度——级别不仅调参，还换算法。这是它对"速度-比率曲线"控制力的来源：曲线每一段都由算法形态保证凸性，参数只做段内微调。

## 8. 设计动机

- **为什么按块选策略**：块是格式与并行的最小单位（128KB），策略函数签名统一为 `(ms, seqStore, rep, src, srcSize)`（ZSTD_BlockCompressor_f），于是 LDM、外部序列生产者、block splitter 都能按块插手（buildSeqStore 的四路分支，zstd_compress.c:3335-3449）；多线程每 job 可独立持有窗口（window 双缓冲）而不碰共享状态。
- **参数表的工程经济学**：clevels 是几千小时基准测试的结晶，暴露成配置文件只会招来"用户调出比默认差得多的参数然后怪 zstd"。硬编码 + `ZSTD_c_*` 参数仅覆盖 windowLog/hashLog 等"可解释"维度的组合，把自由的 targetLength/searchLog 留给库作者演进（历史上 clevels 参数被无数次微调而 ABI 不变）。
- **内存换时间的显式定价**：hashLog/chainLog 决定表大小，searchLog 决定每次搜索预算，lazy 的 gain 公式决定"再看一步"的边际收益——每个策略都是同一问题的不同"预算档位"，接口统一使 A/B 与特化（cmov/branch、row/hashChain）都变成查表。
- **模板爆炸的自觉控制**：每处泛型都尽量收口——fast 的 mls 只有 4-7 四档（zstd_fast.c:452-477），lazy 的 mls 被 `BOUNDED(4, minMatch, 6)` 夹住、rowLog 夹在 [4,6]（zstd_lazy.c:1575-1576），opt 的 getAllMatches 只实例化 3-6 四档（zstd_opt.c:870-886）。全量展开会让编译时间与二进制体积失控，这些边界本身就是调优过的工程决策。

## 9. FAQ 素材

1. **Q: level 19 为什么只比 18 慢一点点却贵很多 CPU？** A: 18→19 换 btultra2，首块多一遍统计扫描（zstd_opt.c:1516-1533），targetLength 32→256 使 DP 几乎不早停（clevels.h:46-47）。
2. **Q: fast 级别的 targetLength=0/1 有什么用？** A: fast 把它当步长：`step = TL + !TL + 1`（zstd_fast.c:200），0/1 都等价最小步 2；负级别 TL=-level 越大跳越远（zstd_compress.c:8305-8310）。
3. **Q: dfast 的短表为什么放在 chainTable 里？** A: fast 用不到 chainTable，dfast 也不用链，于是 chainTable 的内存被复用为第二张 hash 表（zstd_double_fast.c:25/110-112）；决定分配与否的开关在 `ZSTD_allocateChainTable`（zstd_compress.c:275-283）。
4. **Q: hash chain 和 binary tree 都用 chainTable，谁在什么时候分配？** A: fast 不分配链表；row 模式不分配（zstd_compress.c:282）；btlazy2/opt 把它当树用（zstd_opt.c:452-453，btLog=chainLog-1，因为每位置占 2 个 U32）。
5. **Q: lazy 的 gain 公式里的 ×3/×4 是什么？** A: 每字节收益的经验权重，3 用于 repcode 候选、4 用于普通候选（zstd_lazy.c:1679-1682/1701-1702），本质是"匹配长度的边际价值高于偏移位宽"的线性近似。
6. **Q: repcode 的 ll0 是什么？** A: litLength==0 时序列紧跟上一匹配结尾，rep1 会指到自己；此时引用 rep1 实际取 rep2（internal.h:847 的 `-1+ll0`）。
7. **Q: LDM 什么时候自动开？** A: auto 模式下 `strategy>=btopt && windowLog>=27`（zstd_compress.c:292）；大文件压缩 --long 即是提高 windowLog 触发。
8. **Q: btopt 的长距离惩罚惩罚的是什么？** A: offCode>=20（偏移 >1MB）每个加 2(offCode-19)/256 bit（zstd_opt.c:340-341），不是嫌它贵，而是大偏移伤害解压缓存。
9. **Q: 为什么 btultra2 没有字典/外字典变体？** A: 两遍扫描只在"首块且无任何前置数据"时合法（zstd_opt.c:1570-1572 注释；selectBlockCompressor 表中 btultra2 的 dms/extDict 槽位直接复用 btultra 函数，zstd_compress.c:3120/3131）。
10. **Q: row matchfinder 是第九个策略吗？** A: 不是，是 greedy/lazy/lazy2 的可选执行引擎（zstd_compress.c:244-247），策略语义不变，只换数据结构（SIMD 行比较）。

## 10. 深挖方向

1. `ZSTD_insertBtAndGetAllMatches`（zstd_opt.c:590-830）：opt 解析器的候选收集内幕——hash3 表（3 字节专用表，行 411-430）、repcode 候选、hash 链/树双源候选如何去重排序。
2. `ZSTD_DUBT_findBestMatch` 的"惰性排序"协议（zstd_lazy.c:276-307）：`ZSTD_DUBT_UNSORTED_MARK` 如何兼作链指针与哨兵，以及它对 `ZSTD_WINDOW_START_INDEX=2` 的依赖（internal.h:1360）。
3. 窗口溢出修正 `ZSTD_window_correctOverflow`（internal.h:1150-1250）：32 位索引在超长流上的周期性重基（nbOverflowCorrections，internal.h:260-263）。
4. block splitter（zstd_preSplit.c）与策略的交互：分块边界改变每块的统计与 rep 传递。
5. 外部序列生产者（zstd_compress.c:3379-3441）：把"前端"整体替换为用户回调时的校验与回退逻辑。

---

## 写作要点速查表

| # | 事实 | 位置 |
|---|------|------|
| 1 | 级别参数表 4×23，7 元组 | lib/compress/clevels.h:25-130（主表 26-51） |
| 2 | strategy 枚举 fast=1..btultra2=9 | lib/zstd.h:336-344 |
| 3 | 策略分发二维函数表 [dictMode][strategy] | lib/compress/zstd_compress.c:3097-3180 |
| 4 | buildSeqStore 四路分支（LDM/外部生产者/普通） | lib/compress/zstd_compress.c:3292-3455 |
| 5 | fast 步长=targetLength；流水线注释；rep 先行 | lib/compress/zstd_fast.c:200,144-189,275 |
| 6 | fast mls 4-7 × cmov/branch 特化 | lib/compress/zstd_fast.c:425-479 |
| 7 | dfast 双表（hashLong 8B + hashSmall=chainTable mlsB） | lib/compress/zstd_double_fast.c:110-112,203-222,253-273 |
| 8 | hash chain：头插 + searchLog 预算回溯 | lib/compress/zstd_lazy.c:626-657,667-773 |
| 9 | lazy gain 公式与 depth 0/1/2 | lib/compress/zstd_lazy.c:1699-1742,1832,1876,1920 |
| 10 | DUBT 隐式二叉树 + 惰性批量排序 | lib/compress/zstd_lazy.c:243-390 |
| 11 | ZSTD_insertBt1：树插 + 跳位优化 | lib/compress/zstd_opt.c:442-558 |
| 12 | 价格模型：定点 bit、rawLiteralsCost/getMatchPrice | lib/compress/zstd_opt.c:26-62,266-352 |
| 13 | opt DP：前向刷价 + _shortestPath 回溯 | lib/compress/zstd_opt.c:1143-1196,1200-1338,1340-1429 |
| 14 | btultra2 两遍扫描（首块统计） | lib/compress/zstd_opt.c:1476-1535 |
| 15 | LDM：gear hash + 分桶 + XXH64 校验 | lib/compress/zstd_ldm.c:135-171,190-208,385-511 |
| 16 | LDM 自动启用条件 | lib/compress/zstd_compress.c:289-293 |
| 17 | ZSTD_updateRep 三槽更新（含 ll0） | lib/compress/zstd_compress_internal.h:839-857 |
| 18 | offBase 求和类型宏 | lib/compress/zstd_compress_internal.h:743-748 |
| 19 | 窗口双缓冲：base/dictBase 切换 | lib/compress/zstd_compress_internal.h:249-264,1376-1412 |
| 20 | 负级别 acceleration=targetLength | lib/compress/zstd_compress.c:8305-8310 |

---

（本报告基于 commit d79e723 的源码逐行核对；A 章《全景与帧格式》、B 章《熵编码》与本章构成压缩侧三部曲：A 章讲"格式允许写什么"，B 章讲"符号怎么编码"，本章讲"内容怎么挑"。）
