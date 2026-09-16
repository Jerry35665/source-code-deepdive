# S 章 · 多线程压缩与字典压缩内部

> 调研对象:zstd 源码,commit `d79e723`(仓库根目录 `repos/zstd`,2026-09-11)。
> 本章聚焦两条主线:**多线程压缩(ZSTDMT)** 与 **字典压缩(训练/格式/加载)**。
> 所有行号均经 grep/Read 实际核对,路径为仓库相对路径。

---

## 1. 全景:两条数据流

### 1.1 多线程压缩数据流

```
输入字节流
   │  memcpy 进 roundBuff(环形输入缓冲,job 直接引用其中片段,零拷贝)
   ▼
[填满 targetSectionSize(=job 大小)]──→ ZSTDMT_createCompressionJob
   │                                     │ 填 ZSTDMT_jobDescription(src/prefix/params/cdict...)
   │                                     │ POOL_tryAdd(work 线程池) → ZSTDMT_compressionJob
   ▼                                     ▼
┌─────────────── worker j ────────────────────────┐
│ getCCtx(复用池) + getSeq + getBuffer(dst)        │
│ SerialState 串行段:LDM 序列生成 + 全帧 XXH64     │ ← 按 jobID 顺序推进(nextJobID++)
│ compressBegin:载入 prefix(上一 job 尾部 overlap) │
│ 首个 job:改载 CDict(字典)                       │
│ 按 4×128KB chunk 循环 compressContinue           │
│ lastJob 用 compressEnd 写 EndMark(+校验交给主线程)│
└────────────┬─────────────────────────────────────┘
             │ job.dstBuff + cSize(逐 chunk 递增,cond 通知)
             ▼
ZSTDMT_flushProduced:只刷 doneJobID 指向的 job ──→ 输出字节流
   (job 完成且刷完 → doneJobID++,天然按序拼接,绝不乱序)
```

关键结论:**每个 job 产出一个独立的 zstd 帧;输出 = 多个帧的顺序拼接**,故解码端不需要任何"多线程模式"标志。

### 1.2 字典压缩数据流

```
样本集(samples)
   │  cover:后缀数组按前 d 字节分组 → 频率 F(dmer)
   │  fastcover:直接哈希 2^f 桶计数(跳过 suffix array)
   ▼
epoch 循环:每个 epoch 滑窗选一个高分段(贪心 cover 算法)
   │  选中段的 dmer 频率清零 → 继续下一 epoch,直到填满 dictBuffer
   ▼
ZDICT_finalizeDictionary:
   [magic 4B][dictID 4B][熵表:HUF+OF/ML/LL FSE+3×rep][content(尾对齐)]
   ▼
压缩端:ZSTD_createCDict(一次预填哈希表+熵表) → 各 CCtx attach/copy 复用
解压端:ZSTD_createDDict(一次解析熵表) → ZSTD_copyDDictParameters 注入 DCtx
   → 首块即有"热"熵表与 match 窗口,小文件免 cold start
```

---

## 2. 多线程专节(ZSTDMT)

### 2.1 入口与 nbWorkers

- 用户设 `ZSTD_c_nbWorkers`;上限 `ZSTDMT_NBWORKERS_MAX`(32 位 64 / 64 位 256,`lib/compress/zstdmt_compress.h:29-30`)。
- 流式入口在 `ZSTD_compressStream2` 初始化时分流(`lib/compress/zstd_compress.c:6412-6446`):pledgedSrcSize ≤ `ZSTDMT_JOBSIZE_MIN`(512KB,`zstdmt_compress.h:32-33`)时强制退回单线程(`zstd_compress.c:6420-6422`);否则创建/复用 `mtctx` 并调 `ZSTDMT_initCStream_internal`(`zstd_compress.c:6436-6439`)。
- 压缩循环每轮调 `ZSTDMT_compressStream_generic`(`zstd_compress.c:6532`)。

### 2.2 ZSTDMT_CCtx 与四大资源池

`struct ZSTDMT_CCtx_s`(`lib/compress/zstdmt_compress.c:866-892`)持有:线程池 `factory`、`jobs` 表、`bufPool`、`cctxPool`、`seqPool`、`serial`(SerialState)、`roundBuff`、`cdict` 等。三大池在创建时按 nbWorkers 定容:

- **bufferPool**:输出缓冲池,容量 `2*nbWorkers+3`(注释:每 worker 2 个 + 输入 1 + 待提交 1 + 队列滞留 1,`zstdmt_compress.c:273-278`);每个 buffer 大小设为 `ZSTD_compressBound(jobSize)`(`zstdmt_compress.c:1313`)。
- **CCtxPool**:每 worker 一个可复用的 `ZSTD_CCtx`,`getCCtx` 空了会临时新建、`releaseCCtx` 满了直接释放(`zstdmt_compress.c:435-462`);池创建时先备 1 个供单线程模式(`zstdmt_compress.c:398-400`)。
- **seqPool**:LDM 外部序列缓冲,每 worker 1 份(`zstdmt_compress.c:280-282`)。

job 表大小为 `nbWorkers+2` 向上取 2 的幂(`zstdmt_compress.c:953, 908-927`),用 `jobIDMask` 取模成环。

### 2.3 job 的划分

job 目标大小 `targetSectionSize`:用户显式 jobSize,否则 `1 << ZSTDMT_computeTargetJobLog`,即 `MAX(20, windowLog+2)`(LDM 下 `MAX(21, cycleLog+3)`)且夹在 [512KB, 1GB](`zstdmt_compress.c:1186-1198, 1292-1296, 1268-1269`)。

主线程把输入 memcpy 进 `roundBuff` 的当前 section(`zstdmt_compress.c:1871-1896`);填满(或 flush/end)后 `ZSTDMT_createCompressionJob` 填一份 job 描述(`zstdmt_compress.c:1404-1480`):

```c
/* lib/compress/zstdmt_compress.c:1419-1427(节选) */
mtctx->jobs[jobID].src.start = src;
mtctx->jobs[jobID].src.size  = srcSize;
mtctx->jobs[jobID].prefix    = mtctx->inBuff.prefix;          /* overlap */
mtctx->jobs[jobID].cdict     = mtctx->nextJobID==0 ? mtctx->cdict : NULL; /* 字典只进 job0 */
mtctx->jobs[jobID].firstJob  = (mtctx->nextJobID==0);
mtctx->jobs[jobID].lastJob   = endFrame;
```

随后 `POOL_tryAdd` 提交;若无空闲 worker 则置 `jobReady=1` 下轮再交(`zstdmt_compress.c:1472-1478`)——这是流式的**背压**。下一 job 的 prefix 取上一 job 输入尾部 `MIN(srcSize, targetPrefixSize)` 字节(`zstdmt_compress.c:1444-1447`)。

### 2.4 worker 执行:ZSTDMT_compressionJob

worker 侧(`zstdmt_compress.c:693-820`)要点:

1. 从池中借 CCtx/seq/dstBuffer(`:697-699`);
2. jobID≠0 的 job 关掉自身 checksum(由主线程统一算,`:716`)、关 LDM(`:718`)、nbWorkers 清 0(`:720`)——**worker 内部永远是单线程压缩**;
3. 先做串行段 `ZSTDMT_serialState_genSequences`(`:726`);
4. 初始化:job0 且有 cdict → `ZSTD_compressBegin_advanced_internal(..., job->cdict, ...)`(`:728-731`);否则把 `job->prefix` 作为 rawContent 字典载入,非首 job 置 `forceMaxWindow`(`:732-747`,pledgedSrcSize:首 job 用整帧大小、其余用本 job 大小,`:733`);
5. 非 job0 用一次 `srcSize==0` 的 compressContinue 先把**帧头**写出,再 `ZSTD_invalidateRepCodes` 清 repcode(`:753-757`)——前缀只是 rawContent,repcode 不成立;
6. job 内部再按 `4*ZSTD_BLOCKSIZE_MAX` 分 chunk 循环压缩,每 chunk 更新 `job->cSize/consumed` 并 cond_signal 让主线程能边压边刷(`:760-784`);
7. 尾 chunk:lastJob 用 `ZSTD_compressEnd_public`(写 EndMark),否则 `compressContinue`(`:788-794`)。非 last job 的帧**不带 EndMark**,但帧头里写了 Frame_Content_Size=job 大小,解码器据此收帧;
8. 结束后归还资源,`consumed==src.size` 即 job 完成(`:811-817`)。

### 2.5 barrier 与按序输出

乱序防护有**三道闸**:

- **输出序**:主线程只刷 `doneJobID` 指向的 job。`ZSTDMT_flushProduced`(`zstdmt_compress.c:1489-1573`)在 `dstFlushed==cSize` 且未完成时 cond_wait(`:1500-1508`);刷完且 job 完成 → 释放 dstBuff、`doneJobID++`(`:1550-1560`)。即使 job 3 先完成,也必须等 job 0..2 全部刷完才轮到它——输出严格按 jobID 拼接。
- **串行段序(SerialState)**:LDM 序列生成与全帧 XXH64 必须按输入顺序串行执行。`ZSTDMT_serialState_genSequences` 用 `while (nextJobID < jobID) cond_wait` 强制各 worker 按号过闸,过完 `nextJobID++; broadcast`(`zstdmt_compress.c:585-620`,结构体 `:471-485`)。出错时 `ZSTDMT_serialState_ensureFinished` 直接跳号放行后续 job(`:636-653`)。
- **表满背压**:`nextJobID > doneJobID + jobIDMask` 时不再建新 job(`:1409-1413`)。

此外 `ZSTDMT_waitForAllJobsCompleted` 在复位/析构时逐 job 等 `consumed==src.size`(`:1031-1044`)。

### 2.6 溢出与重排(roundBuff 环形复用)

输入不整体持有,而是放在一个环形 `RoundBuff_t`(`zstdmt_compress.c:833-845`,容量计算 `:1314-1339`:LDM 窗口与 `nbWorkers×jobSize+slack` 取大)。当剩余空间不足一个 section 时需要**绕回开头**,但开头可能仍被未完成 job 的 src/prefix 引用:

- `ZSTDMT_getInputDataInUse` 扫描所有未完成 job,返回最早未完成 job 的 prefix/src 区间(`zstdmt_compress.c:1580-1611`);
- `ZSTDMT_tryGetInputRange`(`:1681-1733`)检查新区间与在用区间是否重叠(`ZSTDMT_isOverlapped`, `:1616-1634`):重叠则放弃本轮(等下轮);绕回时若空间不足,把 prefix `memmove` 到 buffer 开头(`:1692-1708`)。LDM 开启时还要等 `ldmWindow` 移出该区间(`ZSTDMT_waitForLdmComplete`, `:1658-1674`)。

这是"溢出重排"的实质:**数据不动,指针绕环;引用未释放就让主线程等**。

### 2.7 overlap:MT 为什么几乎不掉压缩率

各 job 是独立帧,无法跨 job 引用;补偿手段是 overlap(前缀重叠):

- overlap 大小 `targetPrefixSize = 1 << (windowLog - (9 - overlapLog))`,overlapLog 缺省随策略 6~9(`ZSTDMT_overlapLog_default`, `zstdmt_compress.c:1200-1245`);
- worker 把 prefix 当 rawContent 字典载入,match 窗口连续,`forceMaxWindow` 保证偏移合法性(`:732-747`);
- repcode 被禁用(`:757`)、job 间 LDM 由 SerialState 统一做(`:716-726`),checksum 由主线程串行累计后补写进帧尾(`:1523-1533`)。
- 代价是输入重复约 overlap 大小/每 job;`ZSTDMT_initCStream_internal` 保证 jobSize ≥ overlapSize(`:1310`)。

另有 `rsyncable` 选项:`findSynchronizationPoint` 用 32 字节滚动哈希找同步点提前切 job(`zstdmt_compress.c:849-864, 1746-1841, 1885-1888`),代价是 job 边界不再对齐 targetSectionSize。

---

## 3. 字典训练专节(cover 与 fastcover)

### 3.1 cover:后缀数组 + epoch 贪心选段

**预处理**(`COVER_ctx_init`,`lib/dictBuilder/cover.c:628-716`):把所有样本拼接;构建**部分后缀数组**——只按每个位置前 d 字节(dmer)做稳定排序(`:691-702`,d≤8 用 8 字节整数比较 `COVER_cmp8`, `:302-310`);同组位置构成一个 dmer,`COVER_group` 统计该 dmer **出现在多少个不同样本中**(`:431-478`,跨样本去重 `:453-459`),频率存进 `freqs[dmerID]`(`:477`)。

**选段打分**(`COVER_selectSegment`, `:492-569`),注释给出定义(:483-490):

```
Score(S) = F(S_1) + F(S_2) + ... + F(S_{k-d+1})   // 长度 k 的段内所有 dmer 频率之和
// dmer 入典后 F(d)=0,避免重复计分
```

实现为滑窗:右沿加 dmer、左沿丢 dmer,`activeDmers` 哈希 map 保证一个 dmer 在窗内只计一次(`:512-545`);再剪掉零频头尾(`:546-560`)。

**epoch 分治**(`COVER_buildDictionary`, `:754-807`):把 dmer 空间切成 `epochs.num = MAX(1, dictSize/k/4)` 个 epoch(`COVER_computeEpochs`, `:734-749`,每个 epoch 至少 10k 个 dmer);每轮从各 epoch 各选一个最高分段,从**字典尾部向前**填(`:795-799`,注释:好段放尾部 → 引用偏移最小);连续多个零分段则提前停止(`:763-764, 783-788`)。

**参数 d/k**(`COVER_checkParameters`, `:575-594`):d 是 dmer 字节数(匹配灵敏度),k 是段长(=每段字典贡献);约束 `d ≤ k ≤ maxDictSize`。自动调参 `ZDICT_optimizeTrainFromBuffer_cover`(`:1197-1333`)在 d∈{6,8}(步 2)、k∈[50,2000](40 步)网格上并行试参(`:1204-1213, 1243-1248, 1254-1316`),每个 (d,k) 由 `COVER_tryParameters`(`:1151-1195`)建典,并用 `COVER_selectDict`(`:1049-1134`)做 finalize 后在**测试集**上实测压缩总量,`COVER_best_finish` 保留最优(`:982-1026`)。训练/测试切分由 `splitPoint` 控制(`:634-638`)。

### 3.2 fastcover:哈希频率 + epoch/accel 加速

fastcover 把 cover 的后缀数组换成**哈希桶频率**:

- 频率表大小 `2^f`(f 缺省 20,`lib/dictBuilder/fastcover.c:46, 377`),d 只允许 6 或 8(`:229-232`),直接用 `ZSTD_hash6/8Ptr` 计桶(`:84-89`);
- `FASTCOVER_computeFrequency`(`:276-295`)一遍扫训练样本计数;**accel** 参数按表隔 `skip` 个 dmer 采样(`:101-113`:accel=1 全采,accel=10 每 10 个采 1);
- `FASTCOVER_selectSegment`(`:149-219`)与 cover 相同滑窗,只是 `segmentFreqs` 用 U16 数组按哈希桶去重——哈希冲突是近似来源,也是速度来源(无排序,O(n));
- `FASTCOVER_buildDictionary`(`:394-453`)同样 epoch 循环,但 `COVER_computeEpochs(..., passes=1)` 的 epoch 数是 cover 的 4 倍(cover 传 passes=4,`cover.c:761-762`);
- `ZDICT_trainFromBuffer_fastCover`(`:547-612`)与 `ZDICT_optimizeTrainFromBuffer_fastCover`(`:615-765`)结构与 cover 对应;finalize 只用 `nbTrainSamples * finalize%` 个样本(`:496`,accel=1 时 100%)。
- 公共入口 `ZDICT_trainFromBuffer` 现在直接走 fastCover,d=8、steps=4(`lib/dictBuilder/zdict.c:1111-1127`);legacy 训练器(`ZDICT_analyzePos`, `zdict.c:169`;`ZDICT_trainBuffer_legacy`, `:469`)仍保留但非默认。

### 3.3 字典大小与训练集的关系

- `COVER_warnOnSmallCorpus`(`cover.c:718-732`):`nbDmers/maxDictSize < 10` 即警告,建议训练集 ≥ 字典 10 倍(最好 100 倍);
- 样本下限:训练样本数 ≥ 5(`cover.c:648-651`, `fastcover.c:331-334`);总量上限 4GB(32 位 1GB,`fastcover.c:42`);
- `splitPoint`(cover 缺省 1.0、fastcover 自动模式缺省 0.75,`fastcover.c:45`)把样本切成训练/测试:选段只用训练集,`COVER_checkTotalCompressedSize`(`cover.c:868-918`)用测试集逐样本 `ZSTD_compress_usingCDict` 实测总压缩量来评参;
- 字典内容可被 `COVER_selectDict` 的 shrinkDict 逻辑从最小 1KB(`ZDICT_DICTSIZE_MIN`)逐倍上探,在允许的比率回退内选更小字典(`cover.c:1095-1129`)。

---

## 4. 字典格式专节

字典是**格式规范**的一部分(magic `0xEC30A437`,`lib/zstd.h:143`),布局:

```
[magic 4B][dictID 4B][熵表: HUF CTable | OF FSE | ML FSE | LL FSE | 3×rep(12B)][content]
```

**压缩端解析** `ZSTD_loadCEntropy`(`lib/compress/zstd_compress.c:5089-5178`):

- 跳过 magic+dictID 共 8 字节(`:5094-5096`);
- HUF CTable:`HUF_readCTable`,全部符号非零权重才置 `HUF_repeat_valid`(`:5101-5107`);
- OF/ML/LL 三张 FSE:`FSE_readNCount` + `FSE_buildCTable_wksp`(`:5113-5153`),ML/LL 同时判 `ZSTD_dictNCountRepeat` 决定 repeat 模式;OF 的可重复性要等知道 content 大小后再判(`:5161-5168`);
- 3 个 repcode 初始值 12 字节(`:5155-5159`),必须非 0 且 ≤ content 大小(`:5170-5175`)。

`ZSTD_loadZstdDictionary`(`:5189-5217`)再调 `ZSTD_loadDictionaryContent` 把 content 灌进 match 窗口并预填哈希表;`ZSTD_compress_insertDictionary`(`:5221-5258`)先看 magic:无 magic 且 dct_auto → 按 rawContent 处理(`:5245-5250`)。

**解压端解析** `ZSTD_loadDEntropy`(`lib/decompress/zstd_decompress.c:1449-1535`):同样跳 8 字节(`:1458`),读 HUF DTable(`:1467-1476`)、buildFSETable×3(`:1479-1522`)、repcode 校验(`:1524-1532`)。**dictID 生成**:训练时取 content 的 XXH64 映射到 [32768, 2^31) 区间(`lib/dictBuilder/zdict.c:883-887`)。

---

## 5. 字典的使用:CDict/DDict 与 MT 的交互

### 5.1 CDict:一次建表,处处复用

`ZSTD_initCDict_internal`(`zstd_compress.c:5579-5630`)在 CDict 内部**预先完成**字典的全部消化:content 拷贝/byRef(`:5590-5597`)、matchState 建表、`ZSTD_compress_insertDictionary(..., ZSTD_dtlm_full, ZSTD_tfp_forCDict, ...)`(`:5619-5622`)——熵表 + 哈希/链表全部就绪。此后每个 CCtx 只需:

- **attach**(零拷贝):`ZSTD_resetCCtx_byAttachingCDict` 把 `dictMatchState` 指向 CDict 的 matchState(`:2392`),索引空间平移(`:2396-2402`),复制 cBlockState(含熵表与 repcode,`:2409`);
- **copy**:把 CDict 的哈希/链表整块 memcpy 进 CCtx(`ZSTD_resetCCtx_byCopyingCDict`, `:2459-2491`),含 "short cache" 标签剥离(`ZSTD_copyCDictTableIntoCCtx`, `:2414-2428`)。

选择由 `ZSTD_shouldAttachDict`(`:2337-2350`)裁定:pledgedSrcSize ≤ 该策略的 cutoff(`attachDictSizeCutoffs`, `:2324-2335`,fast 8KB ~ btopt 32KB,btultra 8KB)或未知时 attach——即"小输入才值得让字典留在原地共享"。入口判定在 `ZSTD_compressBegin_internal`(`:5282-5290`,cutoff 常量 `:5260-5261`)。

### 5.2 MT 模式下的字典:不广播,只给 job0

这是"MT × 字典"交互的答案:**CDict 不复制给每个 worker**。

- `ZSTDMT_initCStream_internal` 把用户字典转成一个 `mtctx->cdictLocal`(`zstdmt_compress.c:1352-1370`;rawContent 字典则直接挂成 `inBuff.prefix`,`:1357-1359`。注:该函数 `:1278-1288` 还残留一段等价的 byCopy 版本,被后一段覆盖,属冗余代码);
- `ZSTDMT_createCompressionJob` 只把 cdict 给 job0:`jobs[jobID].cdict = mtctx->nextJobID==0 ? mtctx->cdict : NULL`(`:1426`);worker 侧也 assert 只有首 job 允许 cdict(`:730`);
- 后续 job 靠 **prefix(overlap)机制**继承字典效果:job0 的输出(含字典影响)尾部 overlap 成为 job1 的 rawContent 前缀,逐级传递。因此 MT 下字典的成本(建表)只付一次,传播靠数据本身;
- 走外置 CDict 时(`ZSTD_compressStream2` 传 `cctx->cdict`,`zstd_compress.c:6436-6439`)同理,`ZSTDMT_initCStream_internal` 里 `cdict` 与 `dict` 互斥(`zstdmt_compress.c:1262`)。

### 5.3 DDict:解压端对称设计

`ZSTD_DDict` 结构(`lib/decompress/zstd_ddict.c:36-44`)内嵌**已解析的** `ZSTD_entropyDTables_t`。`ZSTD_loadEntropy_intoDDict`(`:89-117`)在创建时校验 magic、读 dictID(`:109`)、解析熵表(`:112-114`)。使用时 `ZSTD_copyDDictParameters`(`:58-86`)把表指针与 repcode、字典窗口四指针一次性注入 DCtx;`ZSTD_decompressBegin_usingDDict`(`zstd_decompress.c:1599-1616`)标记 `ddictIsCold`(同字典连续解多帧时表可保持热,`:1607`)。帧头 dictID 与 DDict dictID 不匹配会在解码前报 `dictionary_wrong`。

### 5.4 字典为什么能大幅提升小文件压缩

- 128KB 的 block window 对几 KB 的文件意味着哈希表近乎空转、熵表只能按"第一个块"现场建模——**熵表本身的开销(count 表 + CTable/DTable)可能占输出的一大半**;
- 字典把这两样都预置了:首块直接继承训练集的 HUF/FSE 分布(`5.1/5.3` 的熵表段)与 repcode 初值,match 侧直接有一个已建好索引的 100KB 级"虚拟前文";
- repcode 初始值(训练分布中最常见距离)对小于 3 字面量的序列尤其有效;`ZDICT_analyzeEntropy` 虽然统计了最常见首偏移,但当前实现仍写默认 `repStartValue`(`zdict.c:828-839`)。

---

## 6. 设计动机小结

1. **MT=独立帧拼接**:帧格式天然允许 concat,多线程无需改格式;job 边界即帧边界,输出序由 doneJobID 单调递增保证,正确性不依赖锁顺序而依赖"单写者+条件变量"。
2. **比率损失被三个机制压缩**:overlap 前缀(窗口连续)、LDM/checksum 串行化(全局信息不丢)、非首 job 禁 repcode+帧头重写(正确性优先,损失有限)。
3. **资源池化**:CCtx/buffer/seq 全部按 nbWorkers 预建复用,流式长跑零 malloc 抖动;`2N+3` 个 buffer 的冗余正是为了"压缩与 flush 流水并行"。
4. **字典=把训练代价一次性前置**:CDict/DDict 都是"预消化"对象;attach 模式下多线程/多连接共享只读 matchState,内存与 CPU 双省。
5. **cover→fastcover 是一次精度换速度的工程化**:后缀数组(精确频率)→ 哈希桶(近似频率)+ accel 采样 + 4 倍 epoch,调参网格不变。

---

## 7. FAQ 素材

1. **MT 输出和单线程输出格式一样吗?** 一样,就是多个合法帧顺序拼接;`cat` 语义,任何标准解码器都能解(`zstdmt_compress.c:753-757` 每 job 独立帧头)。
2. **为什么 nbWorkers>0 时小输入反而更慢/退化为单线程?** pledgedSrcSize ≤ 512KB 时强制 nbWorkers=0(`zstd_compress.c:6420-6422`);一个 job 都切不出来,线程开销纯亏。
3. **MT 会丢校验和吗?** 不会。只有 job0 的 worker 在帧头声明 checksum,全帧 XXH64 由 SerialState 串行累计,由主线程在最后一个 job 刷出时补写 4 字节(`zstdmt_compress.c:716, 1523-1533`)。
4. **overlapLog 是什么?** 控制 job 间前缀重叠量 = `windowLog - (9 - overlapLog)`;9=全窗口,0=按策略缺省(fast 系 6,btultra2 9)(`zstdmt_compress.c:1200-1245`)。
5. **jobSize 可以随便设吗?** 被夹在 [512KB, 1GB](32 位 512MB)(`zstdmt_compress.h:32-36`, `zstdmt_compress.c:1268-1269`);过小会同时伤害比率(job 边界多)与吞吐(调度粒度碎)。
6. **cover 的 d/k 怎么选?** d=匹配单位长度(6~8 最有效),k=候选段长;`--train` 自动模式扫 d∈{6,8}×k∈[50,2000] 共 ~85 组(`cover.c:1204-1213`)。
7. **fastcover 为什么快?** 免后缀数组排序(哈希计数 O(n))+ accel 隔点采样;f=20 时频率表仅 4MB,哈希冲突带来轻微近似(`fastcover.c:84-89, 101-113, 276-295`)。
8. **训练样本越多字典越好吗?** 不是。`COVER_warnOnSmallCorpus` 要求样本量 ≥ 10× 字典大小;字典过大而样本不足会导致选段分数普遍偏低、泛化差(`cover.c:718-732`)。
9. **dictID 必须手工指定吗?** 不必,缺省由 content 的 XXH64 派生到安全区间(`zdict.c:883-887`);也可在训练参数里指定,解压端据此校验。
10. **MT 下每个 worker 都加载一份字典?** 不是。字典只在 job0 载入一次(`zstdmt_compress.c:1426`),后续 job 通过 overlap 前缀间接继承字典上下文。

---

## 8. 深挖线索

1. **ZSTDMT 输入环的正确性证明**:`ZSTDMT_getInputDataInUse` 只返回"最早未完成 job"的区间,为什么一个区间就够?(job 顺序完成,prefix 单调前移;`zstdmt_compress.c:1580-1611` + `:1681-1733`)。可对照 `ZSTDMT_waitForLdmComplete` 的 LDM 窗口额外约束(`:1658-1674`)。
2. **CDict attach 的索引平移**:`ZSTD_resetCCtx_byAttachingCDict` 把工作窗口 `nextSrc` 抬到 `cdictEnd` 之上再 `window_clear`(`zstd_compress.c:2394-2402`),配合 matchState 里 "short cache" 标签索引(`:2414-2428`)——理解 dictMatchState 引用式匹配的关键。
3. **dedicatedDictSearch**:`ZSTD_shouldAttachDict` 对 DDS 直接放行 attach(`zstd_compress.c:2342-2343`),它把 lazy 系字典建表换成"只建 chainTable"的廉价模式(`ZSTD_dedicatedDictSearch_lazy_loadDictionary`, `:5027-5029`)。
4. **非 EndMark 帧的解码语义**:非 last job 的帧不带 last-block,靠 Frame_Content_Size 收帧;追踪解码器 `ZSTD_decompressContinue` 如何按 `fParams.frameContentSize` 判帧尾、`ZSTD_findFrameCompressedSize` 如何在拼接帧间前进(`lib/decompress/zstd_decompress.c`)。
5. **字典 shrink 权衡**:`COVER_selectDict` 在 `shrinkDict` 开启时从 `ZDICT_DICTSIZE_MIN` 逐倍放大,只要压缩量回退 ≤ `shrinkDictMaxRegression%` 就接受更小字典(`cover.c:1095-1129`)——部署侧内存与比率的自动化权衡。

---

## 9. 写作要点速查表

| 主题 | 函数/结构 | 位置 |
|---|---|---|
| MT 入口分流(≤512KB 退单线程) | ZSTD_compressStream2 / ZSTD_CCtx_init_compressStream2 | lib/compress/zstd_compress.c:6420-6446 |
| job/worker 上限与 jobSize 边界 | ZSTDMT_NBWORKERS_MAX / JOBSIZE_MIN/MAX | lib/compress/zstdmt_compress.h:29-36 |
| MT 上下文与资源池 | struct ZSTDMT_CCtx_s;bufPool 2N+3 | lib/compress/zstdmt_compress.c:866-892, 273-282 |
| job 描述(含 cdict 只给 job0) | ZSTDMT_jobDescription / createCompressionJob | lib/compress/zstdmt_compress.c:662-682, 1404-1480 |
| worker 主函数(独立帧、chunk 循环) | ZSTDMT_compressionJob | lib/compress/zstdmt_compress.c:693-820 |
| 按序输出(barrier 之一) | ZSTDMT_flushProduced(doneJobID++) | lib/compress/zstdmt_compress.c:1489-1573 |
| 串行段(LDM+checksum 过闸) | SerialState / serialState_genSequences | lib/compress/zstdmt_compress.c:471-485, 580-621 |
| 输入环溢出重排 | getInputDataInUse / tryGetInputRange | lib/compress/zstdmt_compress.c:1580-1611, 1681-1733 |
| job 大小与 overlap 公式 | computeTargetJobLog / computeOverlapSize | lib/compress/zstdmt_compress.c:1186-1198, 1228-1245 |
| MT 下字典接线 | initCStream_internal(:1352-1370)+ job.cdict(:1426) | lib/compress/zstdmt_compress.c |
| cover 选段与分治 | COVER_selectSegment / COVER_buildDictionary | lib/dictBuilder/cover.c:492-569, 754-807 |
| cover 调参网格 d/k | ZDICT_optimizeTrainFromBuffer_cover | lib/dictBuilder/cover.c:1197-1333 |
| fastcover 加速(hash+accel) | FASTCOVER_computeFrequency / accel 表 | lib/dictBuilder/fastcover.c:276-295, 101-113 |
| 字典头写入(magic/dictID/熵表) | ZDICT_finalizeDictionary | lib/dictBuilder/zdict.c:862-941 |
| 熵表统计与写出 | ZDICT_analyzeEntropy | lib/dictBuilder/zdict.c:663-847 |
| 压缩端字典解析 | ZSTD_loadCEntropy / insertDictionary | lib/compress/zstd_compress.c:5089-5178, 5221-5258 |
| CDict 预填 + attach/copy 决策 | ZSTD_initCDict_internal / shouldAttachDict | lib/compress/zstd_compress.c:5579-5630, 2337-2350 |
| DDict 预解析 + 注入 DCtx | loadEntropy_intoDDict / copyDDictParameters | lib/decompress/zstd_ddict.c:89-117, 58-86 |

*(行号对应 commit d79e723;引文均为仓库相对路径。)*
