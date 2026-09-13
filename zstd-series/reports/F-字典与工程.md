# F-字典与工程：zstd 的字典机制与外围工程实践

> 调研对象：facebook/zstd @ commit `d79e723`（2026-09-11，dev 分支浅克隆）。本文所有行号均以该 commit 为准，用 grep -n / Read 实际核对。
> 定位：第五系列第 6 章（卷末）。前五章（A-E）讲压缩/解码本体，本章讲两个"外围但关键"的板块：**字典机制**（小数据压缩的命门）与**工程实践**（测试/构建/发布）。

---

## 1. 全景：字典的两种来源与 CDict/DDict 的"预编译"价值

### 1.1 两种字典来源

```
                      ┌────────────────────────────────────────────────┐
   用户样本语料        │   训练生成（智能字典）                            │
   (几千个相似文件) ──>│  ZDICT_trainFromBuffer (lib/dictBuilder/zdict.c:1111)
                      │    └─ 默认走 fastCover, d=8, steps=4 (zdict.c:1114-1124)
                      │  --train-cover / --train-fastcover / --train-legacy
                      │    (programs/zstdcli.c:298-303)
                      │  产物: [magic 0xEC30A437 | dictID | 熵表 | 内容段]
                      │        (zdict.c:882-937, magic 见 lib/zstd.h:143)
                      └───────────────┬────────────────────────────────┘
                                      │
   用户自带缓冲区 ─────────────────────┤
   (如 --patch-from 的旧文件)          │   ZSTD_dct_auto: 有 magic 当全字典,
                                      │   否则当 raw content (lib/zstd.h:1374)
                      ┌───────────────┴────────────────────────────────┐
                      │   用户提供（raw content 字典）                    │
                      │  "Any buffer is a valid raw content dictionary"
                      │  (lib/zdict.h:126-129)
                      │  无 dictID、无熵表，只贡献匹配窗口
                      └────────────────────────────────────────────────┘
```

两种来源在运行时由三个 `ZSTD_dct_*` 开关分流（lib/zstd.h:1374-1376）：
`ZSTD_dct_auto`（有 magic 才解析熵表）/ `ZSTD_dct_rawContent`（强制按字节内容）/ `ZSTD_dct_fullDict`（非规范字典直接报错）。压缩侧的分流实现集中在 `ZSTD_compress_insertDictionary`（lib/compress/zstd_compress.c:5222-5258）：先查 magic，非 magic 且 auto 则"raw content dictionary detected"（zstd_compress.c:5245-5250）。

### 1.2 CDict/DDict：把"传表"成本摊销掉

小数据场景每条记录只有几百字节，若每次压缩都重新把字典内容灌进匹配表、重建熵表，开销可能超过压缩本身。zstd 的答案是**预编译字典对象**：

- **ZSTD_CDict**：`ZSTD_initCDict_internal`（lib/compress/zstd_compress.c:5579-5626）在**创建时**就完成一次 `ZSTD_compress_insertDictionary`（5620-5622，传 `ZSTD_tfp_forCDict`），把哈希表/链表、熵参数全部算好挂在 CDict 上；`ZSTD_dlm_byCopy` 时内容 memcpy 进 CDict 自己的 workspace（5591-5596），`byRef` 则只存指针（5590）。之后每次会话只需 `ZSTD_resetCCtx_usingCDict` 引用现成结构。官方文档明确写了 byRef "logically smaller"（lib/zstd.h:1816）。
- **ZSTD_DDict**：`ZSTD_loadEntropy_intoDDict`（lib/decompress/zstd_ddict.c:90-118）创建时解析 magic、dictID 和熵表（111-115）；`ZSTD_copyDDictParameters`（zstd_ddict.c:58-83）把 `prefixStart/dictEnd` 与四张熵表指针一次性挂进 DCtx。
- **attach/copy/load 三态**：解压侧用 `ddictIsCold` 标记字典是否换了热身（lib/decompress/zstd_decompress.c:1599-1611，`dctx->ddictIsCold = (dctx->dictEnd != dictEnd)`），冷字典首次使用时在字面量解码（zstd_decompress_block.c:195，`litSize > 768`）和序列解码（672，`nbSeq > 24`）处做启发式预取，并启用 prefetch 解码器（2218）。压缩侧有实验参数 `ZSTD_c_forceAttachDict`（lib/zstd.h:2060，`ZSTD_dictForceAttach/Copy/Load` 枚举在 1437-1439）：小输入 attach 共享 CDict 表，大输入干脆重灌字典。
- **CDict 启用启发式**：`ZSTD_compressBegin_internal` 里 pledged srcSize < 128KB 或 < 6 倍字典大小就走 CDict 参数（zstd_compress.c:5260-5261、5282-5289）——这正是"小数据摊销"的代码化表述。

`ZSTD_dlm_byCopy / byRef` 定义在 lib/zstd.h:1380-1381；注意解压侧 byRef 时字典缓冲必须活得比 DCtx 久（zstd_ddict.c:169 注释）。

### 1.3 接口面

- `ZDICT_trainFromBuffer`（lib/zdict.h:190-210）：最简入口，内存约 6 MB，建议 ~100KB 字典、几千样本、总样本量 ≈ 100 倍字典大小（zdict.h:204-208）。
- `ZDICT_optimizeTrainFromBuffer_cover` / `..._fastCover`：参数自动搜索版（cover.c:1197 / fastcover.c:615）。
- `ZDICT_finalizeDictionary`：把任意内容段"包装"成规范字典（zdict.c:862）。
- CLI：`--train` / `--train-cover=k=,d=,steps=,split=,shrink` / `--train-fastcover=...,f=,accel=` / `--train-legacy=s=#`（programs/zstdcli.c:298-303，参数解析在 490-570）。

---

## 2. cover / fastcover 专节：分治 score 优化的数学

### 2.1 学术底子

cover.c 开头注明算法来自论文 Liao, Petri, Moffat, Wirth, *Effective Construction of Relative Lempel-Ziv Dictionaries*（WWW 2016），改编自 Giuseppe Ottaviano（@ot）的代码（lib/dictBuilder/cover.c:12-18）。核心抽象是 **d-mer**（d 字节子串）与**段（segment）**。

### 2.2 目标函数与滑动窗口最大化

段的 score 定义（cover.c:483-490，fastcover.c:140-147 各有一份）：

```c
/* cover.c:486-490 */
/* Let F(d) be the frequency of dmer d.
 * Let S_i be the dmer at position i of segment S which has length k.
 *
 *     Score(S) = F(S_1) + F(S_2) + ... + F(S_{k-d+1})
 *
 * Once the dmer d is in the dictionary we set F(d) = 0.
 */
```

选中一个段后把它覆盖的所有 d-mer 频率清零（cover.c:561-567），后续段不再重复计分——这是贪心：每轮在当前 epoch 内找 score 最大的 k 长窗口。`COVER_selectSegment`（cover.c:492-569）用定长滑动窗口增量维护 score：新 d-mer 首次入窗加分（517-523），窗口滑出且该 d-mer 在窗内无剩余出现则减分（528-539）。fastcover 版（fastcover.c:149-219）用 `U16 segmentFreqs[]` 哈希数组替代 cover 的自定义哈希 map，去重逻辑相同（177-194）。

一个耐人寻味的注释：论文建议用 L-0.5 范数计分，但实验显示没用（cover.c:519-521）——工程对论文的修正。

### 2.3 cover 的前处理：部分后缀数组 + 按样本计数

`COVER_ctx_init`（cover.c:628-716）为每个 d 值构建**部分后缀数组**：`suffixSize = trainingSamplesSize - MAX(d, sizeof(U64)) + 1`（669），稳定排序只按前 d 字节比较（stableSort，cover.c:350-375，为 qsort_r/qsort_s/C90 qsort 写了五种平台适配，71-91）。然后 `COVER_groupBy` 把相同 d-mer 的位置分组，`COVER_group`（431-478）统计**每个 d-mer 出现于多少个不同样本**——不是出现次数：

```c
/* cover.c:453-456 */
/* Dictionaries only help for the first reference to the dmer.
 * After that zstd can reference the match from the previous reference.
 * So only count each dmer once for each sample it is in.
 */
```

这是字典训练区别于通用统计的关键洞见：样本内重复匹配 zstd 本来就能自引用，只有**跨样本**重复才值得进字典。

### 2.4 epoch 分治与"从尾部填字典"

训练语料被切成若干 **epoch**，每个 epoch 独立选一个最优段，轮转填充直到字典满。`COVER_computeEpochs`（cover.c:734-749）保证每 epoch 至少 `k*10` 字节；cover 主训练传 passes=4（762），fastcover 传 passes=1（fastcover.c:404-405）。字典**从尾部向前填**，让最优段落在最小偏移处：

```c
/* cover.c:795-799 */
/* We fill the dictionary from the back to allow the best segments to be
 * referenced with the smallest offsets.
 */
tail -= segmentSize;
memcpy(dict + tail, ctx->samples + segment.begin, segmentSize);
```

连续 10 次选到零分段则提前终止（fastcover.c:406、427-433；cover.c:763 的上限随 epoch 数放大到 100）。样本总量不足时告警"至少 10x、最好 100x 字典大小"（cover.c:718-732）。

### 2.5 (d, k) 网格搜索与并行评估

`ZDICT_optimizeTrainFromBuffer_cover`（cover.c:1197-1333）做完整网格搜索：d ∈ {6,8}（1206-1207），k 从 50 到 2000 步进 `(kMaxK-kMinK)/40`（1208-1211），迭代总数公式 `(1+(kMaxD-kMinD)/2)*(1+(kMaxK-kMinK)/kStepSize)`（1212-1213）。每个 (d,k) 组合丢进线程池（1243-1248），`COVER_tryParameters`（1151-1195）独立建字典，`COVER_best_finish`（982-1026）用互斥锁保存"测试集压缩总尺寸最小"的字典。评估指标是真刀真枪的压缩：`COVER_checkTotalCompressedSize`（868-918）用 `ZSTD_compress_usingCDict` 把测试样本逐个压一遍求和。

fastcover 的同构实现（fastcover.c:615-765）额外引入两个加速参数：
- **f**（默认 20，上限 31，fastcover.c:43/46/636）：用 2^f 的哈希频次数组（fastcover.c:377）替代后缀数组，d 只允许 6 或 8，对应 `ZSTD_hash6Ptr/ZSTD_hash8Ptr`（fastcover.c:84-89）。
- **accel**（1-10，fastcover.c:44/101-113）：统计频率时每 skip+1 个 d-mer 跳过一个（`FASTCOVER_computeFrequency`，fastcover.c:276-295，accel=10 时 skip=9），finalize 阶段只用 `finalize%` 的样本（96、496）。

fastcover 是"快 10 倍、质量近似"的工程折中：`--train-fastcover=k=48,d=8,f=20,steps=32,accel=2` 这样的默认即由此来（programs/zstdcli.c:528）。

### 2.6 训练/测试切分与 shrinkDict

`splitPoint` 把样本切成训练/测试两半（cover.c:634-638，fastcover.c:316-319），optimize 版默认 0.75（fastcover.c:45/626-627），而一次性入口 `ZDICT_trainFromBuffer_cover/_fastCover` 强制 `splitPoint = 1.0`（cover.c:818，fastcover.c:559）——因为没有参数搜索就没有过拟合评估的意义。`COVER_selectDict`（cover.c:1049-1134）支持 `shrinkDict`：在回归容忍度 `shrinkDictMaxRegression%` 内（1059、1124）二分试探更小的字典（从 ZDICT_DICTSIZE_MIN 起倍增，1097-1128），换内存与速度。

---

## 3. zdict 专节：候选段选择与字典头格式

### 3.1 字典二进制布局

任务清单里提到的 `doc/zstd_dictionary_format.md` **在本 commit 中不存在**（doc/ 下只有压缩格式文档与 RFC8878 引用，README.md:6）；字典格式的事实定义在代码里：8 字节头 + 熵表 + 内容（zdict.c:882-937）：

```c
/* zdict.c:881-888 */
/* dictionary header */
MEM_writeLE32(header, ZSTD_MAGIC_DICTIONARY);
{   U64 const randomID = XXH64(customDictContent, dictContentSize, 0);
    U32 const compliantID = (randomID % ((1U<<31)-32768)) + 32768;
    U32 const dictID = params.dictID ? params.dictID : compliantID;
    MEM_writeLE32(header+4, dictID);
}
hSize = 8;
```

dictID 默认由内容 XXH64 派生并压进 [32768, 2^31) 区间（883-885）——保证"无 ID 冲突 + 避免 0/小值"的启发式。熵表由 `ZDICT_analyzeEntropy` 写入：HUF 字面量表（779-788）+ 三张 FSE 偏移/匹配长/字长 NCount（790-821）+ 12 字节 repcode 初值（835-837）。**repcode 写的是默认值 `repStartValue` 而不是统计出的最优偏移**——最优值算出来了但被 `#if 0` 掉，注释说"统计影响未被正确评估"（833-838）。

熵统计的方法是把字典当 raw content 建 CDict（`ZSTD_dct_rawContent`，zdict.c:703），逐样本压缩并从 seqStore 抽字面量/偏移/长度直方图（`ZDICT_countEStats`，570-623）。有个防御性补丁：语料字面量分布不可压缩时用 `ZDICT_flatLit` 伪造"近似平坦但可编码"的分布（653-660、735-740），避免 HUF 表写不出去。

### 3.2 布局细节：padding 在内容之前

```c
/* zdict.c:917-925 */
size_t const dictSize = hSize + paddingSize + dictContentSize;
/* The dictionary consists of the header, optional padding, and the content.
 * The padding comes before the content because the "best" position in the
 * dictionary is the last byte.
 */
BYTE* const outDictHeader = (BYTE*)dictBuffer;
BYTE* const outDictPadding = outDictHeader + hSize;
BYTE* const outDictContent = outDictPadding + paddingSize;
```

内容至少要能容纳最大 repcode（872-873 `minContentSize = ZDICT_maxRep(repStartValue)`），不够就补零 padding 且 padding 放在**内容前面**——因为 repcode=1 引用的是字典最后一字节，"最好的位置是最后一个字节"（920-922）。内容放不下时从尾部截断（903-905）。

### 3.3 legacy 训练器：被快照的第一代

`ZDICT_trainFromBuffer_unsafe_legacy`（zdict.c:982-1082）是前 cover 时代的贪心：用完整 divsufsort 后缀数组（510）找高频重复段（dictItem 的 pos/length/savings，153-157），按 savings 排序截取，尾部填噪当哨兵（978-979、1101，`NOISELENGTH 32`）。它仍随 `--train-legacy` 暴露（zstdcli.c:303），且自带一堆"字典偏小/偏大怎么办"的自诊断提示（1036-1050）。这段代码是理解 fastcover 演进的活化石。

---

## 4. 测试专节：从"反证法"到 fuzz 优先

zstd 的 CI 分 short/medium/long 三层（TESTING.md:4-44）：short 在 CircleCI 每个分支跑编译矩阵 + playTests.sh + 小工具；medium 在 dev 分支跑 ASan/UBSan/MSan + 三大 fuzzer + Tsan + valgrind；long 在 release 分支跑全量，含"版本测试：确保 zstd 能解所有旧版本的文件"（TESTING.md:44 附近）。README 挂着 OSS-Fuzz 状态徽章（README.md:18、26-27）。

### 4.1 decodecorpus：格式理解的"反证法"

tests/decodecorpus.c（1998 行）不是在压缩后验证解压，而是**反着来**：从随机种子直接按格式规范**手写**帧——窗口描述符、块头、Huffman/FSE 表、序列段逐位构造（writeFrameHeader 275、writeLiteralsBlockCompressed 496、generateSequences 674、writeSequencesBlock 1028、writeChecksum 1162、generateFrame 1272）——然后交给真 zstd 解码器验证 round-trip（runFrameTest，1541-1571：simple/streaming/带字典三种模式分别测，1461 `testDecodeWithDict`）。压缩 block 生成还有合法性自检：cSize 必须严格小于原大小，否则重摇种子（1229-1240）。

这个工具同时是格式正确性的**双向证明**：解码器若理解错规范，手写帧会炸；生成器若写错规范，自己的帧也拼不出来。它还能输出语料喂给 fuzzer（`generateCorpus` 1629 / `generateCorpusWithDict` 1670），并直接 #include 内部实现拿 seqStore（decodecorpus.c:23）。

### 4.2 fuzzers：21 个目标，按"面"覆盖

tests/fuzz/（任务清单写的 tests/fuzzers/ 实际路径是 tests/fuzz/）在 Makefile 里注册 21 个 target（tests/fuzz/Makefile:112-134）：simple/stream/block 三种 round_trip、三种 decompress、dictionary_round_trip / dictionary_decompress / dictionary_loader / raw_dictionary_round_trip / dictionary_stream_round_trip（字典相关占 5 个）、fse_read_ncount、huf_round_trip / huf_decompress、decompress_cross_format 等。fuzz.py 统一驱动 libfuzzer / afl / regression 三引擎并管理语料下载（tests/fuzz/README.md:1-40）。dictionary_loader 的目标定义很干净："只要字典能被加载，就必须能 round trip"（tests/fuzz/dictionary_loader.c:16-18）——把"加载成功"与"可解码"绑成不变量。

fuzzers 大量使用 `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` 宏：连解码器内部都为 fuzz 留了断言钩子（zstd_ddict.c:68-70 的 `dictContentBeginForFuzzing`）。

### 4.3 常规阵地：playTests.sh 与小工具

tests/playTests.sh（1934 行）是 CLI 级端到端：`roundTripTest` 用 datagen 造数据、压缩、解压、MD5 对比（44-60）。字典相关覆盖很细：`--train` 造两个字典验证 dictID 必须不同（1135-1136）、错字典解压必须失败（1133）、`--maxdict=4K/1K` 尺寸限制（1140-1142）、拒绝管道喂字典（1122-1124）、"zero weight dict" 合规性用例（1033-1046）。更新的 tests/cli-tests/ 目录提供了按场景分组的 CLI 黑盒测试（dict-builder、dictionaries 子目录）。配套小工具各管一层：fuzzer.c（5715 行 API 级 fuzz）/ zstreamtest.c（3467 行流式 fuzz）/ invalidDictionaries.c / largeDictionary.c / longmatch.c / roundTripCrash.c。

### 4.4 兼容性测试：legacy 浮图层

- tests/legacy.c：硬编码**每一代旧格式**的真实压缩帧（v0.1-v0.7，26-49 起的 FRAME_V0x_SIZE），按编译期 `ZSTD_LEGACY_SUPPORT` 决定解哪些（22-27）——兼容矩阵被钉死在源码里。
- tests/test-zstd-versions.py：从 GitHub 拉所有历史 tag，逐一编译 vdevel 与旧版本，互相压缩/解压/字典训练交叉验证（14-35）。
- CHANGELOG v1.6.0 起的立场变化："legacy format support is now disabled by default"，`ZSTD_LEGACY_SUPPORT` 默认 0（CHANGELOG:1-4；lib/libzstd.mk:32）。

### 4.5 与 Git/FFmpeg 测试文化的对照

- **Git**（第四系列）靠 t*.sh 脚本断言 + 大量真实仓库 fixture：以"行为快照"为主。zstd 的 playTests.sh 同型（shell + datagen 参数化），但 zstd 额外把**格式本身**变成被测对象（decodecorpus），Git 没有等价物——因为 packfile 格式没有独立的"从零手写帧"需求。
- **FFmpeg**（第二系列）fuzz 文化极盛（目标数百个、OSS-Fuzz 长期高产），但它是"给定格式解析任意输入"的健壮性 fuzz。zstd 的差异在 decodecorpus 这层：**生成合法输入**验证"该解的必须解对"，与 fuzz 验证"不该崩的不能崩"形成对偶。二者合起来才是格式实现的完整证明。

---

## 5. 构建专节：多构建系统并存的政治学

### 5.1 现状盘点

| 系统 | 位置 | 角色 |
|---|---|---|
| Make（主） | Makefile、lib/Makefile、lib/libzstd.mk | 参考实现，功能最全（tests、fuzz、install） |
| CMake | build/cmake/CMakeLists.txt | 从 Make 版"生成"，README 明言"推荐用 cmake 生成 VS solution"（README.md:212 附近） |
| Meson | build/meson/meson.build | 社区维护（2018 起独立目录） |
| Visual Studio | build/VS2010/、build/VS2008/ | 手工维护的 .sln/.vcxproj + 自动构建脚本 build/VS_scripts（README.md:210-212） |
| Buck/Bazel | 无 in-tree 文件 | buck 走 contrib；bazel 用 Bazel Central Registry 上的外部 module（README.md:221-223） |
| 单文件 | build/single_file_libs/ | combine.py 拼接（见 5.3） |

### 5.2 为什么留这么多

zstd 的用户面极端宽：Linux 发行版与内核（contrib/linux-kernel）、嵌入式、Windows 游戏、JS/WASM、bazel 单仓。每个生态都有自己的"母语"构建系统，**库本体只有十几个 .c 文件且无第三方依赖**（libzstd.mk 只管理编译开关），维护多套构建的成本近似线性而收益是"官方一等公民"地位——CHANGELOG 里 build 类条目常年占四分之一（v1.5.7：meson/Apple Framework/icc/Android NDK，CHANGELOG:11-15；v1.5.6：bazel support，CHANGELOG:72）。这是社区驱动项目少见的"构建系统联邦"：核心开发者只保证 Make 版正确，其余以"接受 PR + CI 编译矩阵"（TESTING.md:8-11 列 x86/ARM/AArch64/PowerPC 全家桶）托底。

### 5.3 单文件发行与最小构建

- **ZSTD_LIB_MINIFY**（lib/libzstd.mk:27-29）：一键空间优化——强制 Huffman 只留 x1 表、序列只留 short 解码路径、去 inline、剥错误字符串（36-42），并探测 `-Oz`（85-100）。服务"塞进引导扇区/WASM"的场景。
- **单文件拼接**：build/single_file_libs/ 用 combine.py 把 lib/ 拼成一个 zstd.c / zstddeclib.c（build/single_file_libs/README.md:1-40）：解码器单文件在 Emscripten/WASM 下约 26kB、原生 40-70kB，全库约 1.2MB。build_decoder_test.sh/build_library_test.sh 把拼接产物**也纳入测试**。
- **freestanding**：contrib/freestanding_lib 提供"裁剪式构建"（去 libc 依赖），对应 v1.5.6 "reduce binary size with selective build-time exclusion"（CHANGELOG:64）。
- ZSTD_LEGACY_SUPPORT 的开关逻辑（libzstd.mk:198-203）：值 <8 时按位段拼 `v0[X-7].c` 文件——legacy 源文件按格式版本切片入库。

---

## 6. 版本、API 与发布节奏

- **版本号**：`ZSTD_VERSION_MAJOR/MINOR/RELEASE` 与 `ZSTD_VERSION_NUMBER` 三乘法宏（lib/zstd.h:112-115），当前 1.6.0。稳定 API 用 `ZSTDLIB_API`，实验 API 需 `ZSTD_STATIC_LINKING_ONLY` 且"枚举值本身都可能变"（zstd.h:507-520）——稳定承诺是**符号级**而非参数级。
- **格式承诺**：格式稳定并已文档化为 RFC8878（README.md:6），多实现并存；参考实现的包袱只剩"能解 RFC 之前的自家旧格式"。
- **发布节奏**（CHANGELOG 版本序列：1-681 行）：v1.0.0（2016-09）→ v1.6.0（2025-12），约 40 个版本 / 9 年，平均 3-4 个/年；2019 年最密（v1.4.0-v1.4.4 一年五个，CHANGELOG:339-444），2021 后放缓为约一年一版（v1.5.7 2025-02 → v1.6.0 2025-12，CHANGELOG:1-5）。中间还出现过"dev version, unpublished"的 v1.5.3（CHANGELOG:145）——版本号被打空，是语义化纪律与滚动开发的折中痕迹。
- **Facebook 内部使用**（README 的卖点自述）：zstd 定位 real-time 场景（README.md:3-5）；小数据章节用 github-users 样本集（1 万条 × ~1KB JSON 记录）演示训练字典带来"压缩比大幅提升且压缩/解压速度更快"（README.md:80-95）——字典不是锦上添花而是负成本。Meta 内部存储/数据库栈（Zstandard homepage 列出的 ports 与绑定，README.md:11）是字典训练能力的天然大客户。

---

## 7. 设计动机

**为什么字典是小数据的胜负手**：压缩算法靠"过去"预测"未来"，数据集开头没有过去（README.md:82-85）。zstd 把"过去"外置成可训练、可分发的对象：熵表省掉每帧的表头成本（zdict.h:117-120），内容段提供跨样本匹配窗口。100KB 是官方给的效果边界（zdict.h:71-72），110KB 是 CLI 默认（zdict.h:120-121）。

**fastcover 为什么替代 cover 成默认**：cover 的部分后缀数组要 O(n log n) 排序且每个 d 值一份；fastcover 用 2^f 哈希桶 + accel 抽样把统计降到 O(n)，代价是 d 限定 {6,8} 与哈希碰撞近似。`ZDICT_trainFromBuffer` 直接绑定 fastCover d=8/steps=4（zdict.c:1114-1117）就是官方表态；cover 保留为"精度选项"而非弃用代码。同时 `--train-legacy` 保留第一代算法，三代同堂供回归对照。

**fuzz 优先的测试策略**：zstd 的破绽从来不在"正常路径"而在"恶意/损坏输入 + 组合状态机"（流式、字典、多线程、legacy）。所以它把 CI 预算压倒性投向 fuzz 与 sanitizer（TESTING.md:14-24），并用 decodecorpus 保证"合法输入的合法性"不被 fuzz 训练带偏。字典链路被 fuzz 覆盖了 5/21 个目标，与"字典=第二入口"的地位相称。

---

## 8. FAQ 素材

1. **字典训练至少要多少样本？** 至少 5 个训练样本（cover.c:648-650、fastcover.c:331-334 硬检查）；官方建议总量 ≈ 100 倍字典大小、几千个（zdict.h:132-135、204-208），不足 10 倍会打警告（cover.c:718-732）。
2. **字典多大合适？** ~100KB 通用推荐（zdict.h:120），CLI 默认 110KB；`shrinkDict` 可自动收缩到"压缩比不显著退化"的最小值（cover.c:1049-1134）。
3. **raw content 字典和训练字典怎么选？** raw 是"任意缓冲都合法"的零成本方案（zdict.h:126-129），适合 --patch-from；训练字典多 8 字节头 + 熵表（zdict.c:882-899），小数据压缩比更好。
4. **dictID 从哪来？** 内容 XXH64 映射进 [32768, 2^31)（zdict.c:883-885），也可用 `--dictID=#` 指定；解压端靠它匹配字典（zstd_ddict.c:108）。
5. **byCopy 和 byRef 有什么实际差别？** CDict byCopy 时表已算好、内容拷进 workspace（zstd_compress.c:5591-5596）；byRef 省内存但要求缓冲长寿（zstd.h:1816、zstd_ddict.c:169）。解压端 byRef+换字典还会触发冷字典预取（zstd_decompress_block.c:195、672）。
6. **为什么 repcode 统计了却不写进字典？** 代码里被 `#if 0`：写最优 rep 偏移的收益"未被正确评估"，暂用默认 repStartValue（zdict.c:828-838）。
7. **legacy 支持默认开了吗？** v1.6.0 起默认关（CHANGELOG:1-4；libzstd.mk:32），要解 v0.x 文件需 `ZSTD_LEGACY_SUPPORT=<N>`（libzstd.mk:198-203），测试锚在 tests/legacy.c 的硬编码旧帧上。
8. **fastcover 的 accel 参数到底省了什么？** 统计频率时隔 skip 个 d-mer 采一个、finalize 只压部分样本（fastcover.c:101-113、496），10 倍加速基本不掉质量。
9. **训练出的字典为什么"内容在尾部、头在前面"？** 填字典从缓冲尾部向前，让高分段落在最小偏移（cover.c:795-799）；finalize 时 padding 又垫在内容前，保证 repcode 引用最优的"最后一字节"（zdict.c:917-925）。
10. **为什么有四套构建系统？** 用户生态割裂（发行版/Windows/WASM/bazel 单仓），库本体极小使维护成本可控；bazel 干脆走 Bazel Central Registry 外置（README.md:221-223）。

## 9. 深挖选题

1. **cover 论文到 fastcover 的算法史**：从 WWW 2016 的 Lempel-Ziv 字典构造（cover.c:12-18）到 2018 年 fastcover PR（哈希近似 + epoch 单 pass）的取舍——"近似评分够用"的实证案例，附 cover.c:492-569 vs fastcover.c:149-219 的同构对比。
2. **decodecorpus 作为"规范的可执行化"**：1998 行手写帧生成器如何倒逼规范实现双写（decodecorpus.c:23 直接 include 内部源），可展开成"用生成器测试解码器"的方法论（对比 FFmpeg 的 byte-exact fixture 流派）。
3. **CDict 附加策略的微观经济学**：`ZSTD_USE_CDICT_PARAMS_SRCSIZE_CUTOFF` 128KB/6 倍字典（zstd_compress.c:5260-5261）+ attach/copy/load 三态（zstd.h:1437-1439）+ 冷字典预取（zstd_decompress_block.c:195/672/2218）串成一条"字典热身成本"预算线。
4. **多构建系统联邦的维护成本实测**：统计 CHANGELOG 里 build/port 类修复占比，论证"无依赖小库 + 全生态构建"策略的可持续性；对照 zlib 的单一 configure 模型。
5. **legacy 版本矩阵的工程纪律**：ZSTD_LEGACY_SUPPORT 按版本切片编译（libzstd.mk:198-203）+ tests/legacy.c 硬编码帧 + test-zstd-versions.py 全版本互解三重防线，及其在 v1.6.0 "默认关闭"决策中的角色。

---

## 写作要点速查表（关键函数 + 行号）

| 主题 | 函数/常量 | 位置 |
|---|---|---|
| 训练默认入口 | ZDICT_trainFromBuffer（fastCover d=8,steps=4） | lib/dictBuilder/zdict.c:1111-1127 |
| cover 评分定义 | Score(S)=ΣF(S_i) 注释 | lib/dictBuilder/cover.c:483-490 |
| cover 滑窗选段 | COVER_selectSegment（L-0.5 范数弃用注） | lib/dictBuilder/cover.c:492-569 |
| cover 按样本计数 | COVER_group（首个引用才计分） | lib/dictBuilder/cover.c:431-478 |
| cover 网格搜索 | ZDICT_optimizeTrainFromBuffer_cover（d∈{6,8},k∈[50,2000]） | lib/dictBuilder/cover.c:1197-1333 |
| fastcover 哈希频次 | FASTCOVER_ctx_init（2^f 表）；accel 表 | lib/dictBuilder/fastcover.c:377、101-113 |
| fastcover 选段 | FASTCOVER_selectSegment（U16 segmentFreqs） | lib/dictBuilder/fastcover.c:149-219 |
| 尾部填充 | COVER_buildDictionary（"最小偏移"注释） | lib/dictBuilder/cover.c:795-799 |
| 字典头写入 | ZDICT_finalizeDictionary（magic+dictID+熵表+padding+content） | lib/dictBuilder/zdict.c:862-941 |
| 熵表生成 | ZDICT_analyzeEntropy（repcode #if 0 段） | lib/dictBuilder/zdict.c:663-847 |
| CDict 预编译 | ZSTD_initCDict_internal（创建时插字典） | lib/compress/zstd_compress.c:5579-5626 |
| CDict 启用启发式 | ZSTD_compressBegin_internal（128KB/6x） | lib/compress/zstd_compress.c:5260-5290 |
| DDict 熵加载 | ZSTD_loadEntropy_intoDDict；copyDDictParameters | lib/decompress/zstd_ddict.c:90-118、58-83 |
| 冷字典判定 | ZSTD_decompressBegin_usingDDict（ddictIsCold） | lib/decompress/zstd_decompress.c:1599-1611 |
| 反证法测试 | decodecorpus generateFrame/runFrameTest | tests/decodecorpus.c:1272-1285、1541-1571 |
| fuzz 目标清单 | FUZZ_TARGETS（21 个，字典占 5） | tests/fuzz/Makefile:112-134 |
| legacy 锚点 | 硬编码旧版本帧 | tests/legacy.c:26-49 |
| 最小构建 | ZSTD_LIB_MINIFY；ZSTD_LEGACY_SUPPORT?=0 | lib/libzstd.mk:27-42、32 |
| 版本宏 | ZSTD_VERSION_NUMBER（1.6.0） | lib/zstd.h:112-115 |
| legacy 默认关 | v1.6.0 变更 | CHANGELOG:1-4 |
