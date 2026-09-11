# F-音频管线:重采样、格式转换与音频编解码

> 系列第二系列《FFmpeg》子系统调研。仓库:master @ 9f63b36a。
> 涉及库:libswresample、libavutil(samplefmt/channel_layout)、libavcodec(aac/opus)、libavfilter。
> 阅读对象:有 3-5 年后端经验、不熟悉音视频的工程师。所有结论均标注 `文件:行号`,行号以该 commit 为准。

---

## ① 全景:数字音频基础,以及为什么需要重采样

一段数字音频由三个正交参数描述:

- **采样率(sample rate)**:每秒采集多少个振幅样本。CD 音质 44100 Hz,视频工业标准 48000 Hz,语音常见 16000 Hz。
- **位深与格式(bit depth / sample format)**:每个样本用几比特、什么编码表示。FFmpeg 用 `AVSampleFormat` 枚举 12 种:u8/s16/s32/s64/flt/dbl 各有 packed 与 planar 两种变体(`libavutil/samplefmt.c:36-49`)。
- **声道布局(channel layout)**:几个声道、每个声道对应空间中哪个喇叭。mono、stereo、5.1、7.1 等(`libavutil/channel_layout.c:190-231`)。

未经压缩时,数据量 = 采样率 × 声道数 × 每样本字节 × 时长。48 kHz 立体声 s16 一分钟约 11.5 MB。

实际工程中,**任何两个音频片段几乎总会在上述三个参数上不一致**:解码器输出 fltp 44.1 kHz 5.1,声卡要 s16 48 kHz stereo;播放器内部滤镜工作在 fltp;不同来源的音轨要拼接。把 A 参数空间映射到 B 参数空间的三个操作,构成了 FFmpeg 的音频管线:

1. **采样格式转换**:`libswresample/audioconvert.c`,纯逐样本的算术/移位;
2. **重采样(resampling)**:`libswresample/resample.c`,多相 FIR 滤波,改变采样率;
3. **声道重映射/混音(rematrix)**:`libswresample/rematrix.c`,输出声道 = 输入声道的加权和(矩阵乘法)。

三者由 `libswresample/swresample.c` 的 `SwrContext` 编排成一条固定流水线。libavfilter 的 `aresample` 滤镜再把 `SwrContext` 包成滤镜图的一个节点。这就是本报告②③⑤的主线。④则进入两个代表性编解码器 AAC 与 Opus 的解码器,看它们输出什么、为什么离不开上述管线。

另一个贯穿全文的主题是**时间戳**:音频 PTS 以样本为天然单位(采样率的倒数就是一个 tick),重采样会改变样本计数、引入滤波器群延迟,还可能被"拉伸/压缩"做时钟补偿,因此音频 PTS 的精度与连续性要求远高于视频,详见⑥末尾。

---

## ② swresample 逐段解读

### 2.1 入口:swr_init 如何决定"内部工作格式"

`swr_init()`(`libswresample/swresample.c:156-406`)是理解全库的钥匙。它做四件事:

**(a) 选择重采样引擎**(197-205 行):编译期检测到 libsoxr 则 `SWR_ENGINE_SOXR` 可用,默认 `SWR_ENGINE_SWR` 用自家实现:

```c
switch(s->engine){
#if CONFIG_LIBSOXR
    case SWR_ENGINE_SOXR: s->resampler = &swri_soxr_resampler; break;
#endif
    case SWR_ENGINE_SWR : s->resampler = &swri_resampler; break;
```

两个引擎都实现同一个 8 函数接口 `struct Resampler`(init/free/multiple_resample/flush/set_compensation/get_delay/invert_initial_buffer/get_out_samples,`libswresample/swresample_internal.h:83-92`)——一个教科书式的算子抽象层。

**(b) 自动选择内部采样格式 int_sample_fmt**(227-254 行):所有中间处理统一在 planar 格式上进行。规则是一组按成本排序的启发式:输入输出都 ≤16bit 且不改采样率 → `S16P`;否则字节和 ≤3 → `S16P`;输入 ≤4 字节 → `FLTP`;再不然 → `DBLP`。且内部格式只允许 s16p/s32p/s64p/fltp/dblp 这五种 planar(257-264 行)。**这是 swresample 最重要的架构决定:内部一律 planar**,好处是 SIMD 按声道整段搬运、混音按平面遍历缓存友好。

**(c) 决定要不要 rematrix**(223-225 行):输入输出布局不同、或音量 ≠1、或用户给了自定义矩阵,就需要混音。若任一侧布局是 `AV_CHANNEL_ORDER_UNSPEC`(只知道声道数不知道位置),且声道数对不上,直接报错 "not enough information"(327-333 行)——混音必须知道每个声道的空间语义。

**(d) 装配转换器与流水线缓冲**(346-384 行):一个极常见的捷径——如果既不重采样、不混音、无 channel_map、无抖动,就只分配一个 `full_convert` 直通转换器(346-350 行);否则分配 `in_convert`(原始格式→int_fmt,顺带做 channel_map)与 `out_convert`(int_fmt→输出格式)。

### 2.2 重采样流水线 ASCII 图

`swr_convert_internal()`(`swresample.c:591-719`)驱动如下数据流:

```
 in(packed 或 planar,原始格式)
   │
   ▼  in_convert:格式转换 + channel_map 选道(audioconvert.c)
 ┌─────────┐  无需转换时 postin 直接别名到 in(627-628 行)
 │ postin  │
 └────┬────┘
      │  resample_first?(由 337 行启发式决定)
      ├──────── true ──────────────┬─────── false ─────────────┐
      ▼                            │                           ▼
 ┌──────────┐                      │                     ┌──────────┐
 │ resample │ 多相FIR(resample.c)  │                     │ rematrix │ 矩阵混音(rematrix.c)
 └────┬─────┘                      │                     └────┬─────┘
      ▼                            │                          ▼
 ┌──────────┐                      │                     ┌──────────┐
 │  midbuf  │                      │                     │  midbuf  │
 └────┬─────┘                      │                     └────┬─────┘
      ▼                            │                          ▼
 ┌──────────┐                      │                     ┌──────────┐
 │ rematrix │                      │                     │ resample │
 └────┬─────┘                      │                     └────┬─────┘
      └──────────────┬─────────────┴───────────────────────────┘
                     ▼
                ┌─────────┐   dither 噪声整形(可选,667-714 行)
                │ preout  │──▶ preout 直接别名到 out 时整体零拷贝(636-647 行)
                └────┬────┘
                     ▼  out_convert:int_fmt → 输出格式
                   out
```

真实代码里 `postin/midbuf/preout` 只是三个 `AudioData` 句柄,当相邻两级被跳过(如无需重采样)时,后级直接指向前级的缓冲(630-634 行),`AudioData` 结构见 `swresample_internal.h:47-55`(每声道指针数组 `ch[]` + bps + planar 标志)。因此"5 级流水线"在典型配置(如 s16p→fltp 同采样率)下实际只执行首尾两次转换,中间全部指针别名。

### 2.3 SWR 引擎:双相位内插的多相滤波器

**滤波器组构建** `build_filter`(`resample.c:41-174`):对每个相位 ph ∈ [0, phase_count),生成一条截短的 sinc 低通,再乘窗。支持三种窗:三次样条 `SWR_FILTER_TYPE_CUBIC`(75-80 行,其实不是 sinc 而是 Catmull-Rom 式曲线,质量最低)、Blackman-Nuttall 加窗 sinc(81-85 行)、默认的 Kaiser 加窗 sinc(86-89 行,`av_bessel_i0`,kaiser_beta 默认 9,`options.c:118-123`)。每个相位的多头是对称的:phase_count 为偶数时,`phase_count-ph` 相直接镜像复制 ph 相的系数(105-107 行),省一半计算与存储。

**初始化** `resample_init`(`resample.c:184-278`),几个关键量:

- `cutoff` 默认 0.97,`factor = min(out_rate*cutoff/in_rate, 1)`(188-189 行)——抗混叠截止频率随降采样比例收窄;
- `phase_count = 1 << phase_shift`,phase_shift 默认 10 即 **1024 个相位**(`options.c:85`,`resample.c:190`);
- `exact_rational` 默认开(197-205 行):用 `av_reduce` 求出 out/in 的精确有理比,若分子 ≤1024 则直接用精确相位数替换 2^phase_shift——例如 48000→44100 恰为 147:160,滤波器组可以用 160 个相位**精确**覆盖所有插值位置,杜绝相位截断误差;
- 步进量 `src_incr/dst_incr = out/in (约分)`(258-266 行),并把 `dst_incr` 拆成 `dst_incr_div` 与 `dst_incr_mod`,让内层循环不用做除法;
- 起始 `index = -phase_count*((filter_length-1)/2)`(268 行):**滤波器从负索引起步**,意味着前半段抽头落在"未来"数据上,这就是流式重采样必须先攒 `filter_length/2` 个样本才能出第一个输出样本的群延迟来源。

**逐样本内插内核** `resample_template.c` 是对 s16/s32/flt/dbl 四种 FELEM 的模板展开。两个核心函数:

`resample_common`(94-147 行)——定点相位查表:输出样本 y = Σ src[sample_index+i]·filter_bank[index][i],`index` 是相位号、`sample_index` 是输入游标,每产生一个输出后按 `frac += dst_incr_mod; index += dst_incr_div` 推进,frac 溢出 src_incr 时进位(128-138 行)。注意它用双累加器把奇偶抽头展开成两条独立乘加链(116-121 行),这是典型的打破 FPU 依赖链的优化。

`resample_linear`(149-207 行)——"双相位内插":除了相位 `index` 处的滤波器,再取相邻相位 `index+1`(内存上即 `filter[i + filter_alloc]`,因滤波器组按 filter_alloc 对齐步进排布)算出 v2,然后按小数相位 `frac/src_incr` 线性插值:

```c
val += src[sample_index + i] * (FELEM2)filter[i];
v2  += src[sample_index + i] * (FELEM2)filter[i + c->filter_alloc];
...
val += (FELEM2)(v2 - val) * inv_src_incr * frac;   /* 浮点路径,resample_template.c:181 */
```

即用 1024 个离散相位 + 相邻相位线性插值逼近**连续**相位,这就是"双相位内插"的全部含义:分辨率从 1/1024 相位提升到任意相位,代价是多一遍滤波。调用侧由 `multiple_resample`(`resample.c:389-390`)裁决:仅当 `c->linear && (c->frac || c->dst_incr_mod)`(相位恰好对齐时无需插值)才走 `resample_linear`,否则 `resample_common`。另有退化路径 `resample_one`(filter_length==1 且 phase_count==1,359-377 行),等价于最近邻抽头步进,用于 filter_size=0 的低质量模式。

**流式缓冲管理**:`swresample.c:496-589` 的 `resample()` 负责把调用方给的不定长输入喂给引擎——剩余未消费样本回存环形 `in_buffer`(index/count 两个游标,544-563 行),并调用 `invert_initial_buffer`(`resample.c:457-502`)在流开头把已有输入**镜像折叠**到滤波器的负索引区,让第一个输出样本就能用满整条滤波器;`resample_flush`(`resample.c:437-454`)在流结尾做同样的镜像反射填充。x86 上还有 `padless = 7` 的小输入直通优化(`swresample.c:501`)。

**时钟补偿**:`set_compensation`(`resample.c:328-347`)把 `dst_incr` 临时偏离理想值(`ideal_dst_incr - ideal*sample_delta/compensation_distance`),在 `compensation_distance` 个输出样本内线性恢复——这就是播放器"拉伸/压缩音频追赶时钟"的底层机制。注意 SOXR 引擎的 `Resampler` 结构**没有** `set_compensation` 成员(`soxr_resample.c:126-134`),`swr_set_compensation` 对它返回 `EINVAL`(`swresample.c:922-923`)。

**SOXR 引擎**(`soxr_resample.c`)是对 libsoxr 的薄封装:create 把 FFmpeg 参数映射为 soxr 的 io_spec/quality_spec(32-62 行,precision 映射质量档位、cutoff 映射 passband_end);process 直调 `soxr_process`(84-97 行);flush 时用 `delayed_samples_fixup` 修正 soxr 内部延迟的记账(69-82 行)。它是"外包专业库换质量"的典型插件化设计。

### 2.4 rematrix:矩阵混音

`rematrix.c` 的核心是把"输入布局 → 输出布局"编译成一个 `matrix[out][in]` 系数表,再在样本域做矩阵乘。

**系数推导** `build_matrix`(151-570 行)思路是"对齐公共声道 + 路由未对齐声道(unaccounted)":两边都有的声道直接 1:0 恒等(185-188 行);输入有而输出没有的声道,按空间就近规则分摊。例如 FC(中置)进 stereo:有 FL/FR 时按 `center_mix_level` 混入两侧(193-204 行);stereo 缩成 mono 型 FC 则按 `M_SQRT1_2` 相加(205-213 行)。环绕声道下混还有 Dolby Surround / Pro Logic II 兼容模式,用**负系数制造相位差**以便矩阵环绕解码器还原(253-267 行 DPLII 分支,系数含 SQRT3_2)。LFE 默认按 `lfe_mix_level` 混入(518-527 行)。最后做能量归一化:任一输出行系数绝对值和超过 maxval 时全阵除以 maxcoef,防止整数输出削波(543-569 行)。布局合法性由 `sane_layout` 把关:必须有前向声道、左右声道必须成对(114-149 行)。

**量化与执行** `swri_rematrix_init`(673-793 行):double 矩阵按中间格式物化成 float/int 版本;**s16 路径系数乘 32768 取整,并对量化误差做逐项误差扩散(`rem` 变量,704-715 行)**;若每行系数和 ≤32768 则选不饱和的 copy_s16/sum2_s16,否则带 clip 版本(717-725 行)。还预计算稀疏索引 `matrix_ch[i] = {非零系数个数, 输入声道...}`(768-786 行)。

执行函数 `swri_rematrix`(800-879 行)按每输出声道的非零输入数分四档:

```c
case 1:  /* 单输入:系数 1.0 且无需拷贝时,直接交换平面指针——零拷贝 */
    out->ch[out_i]= in->ch[in_i];                     /* rematrix.c:834 */
case 2:  /* 双输入:mix_2_1 SIMD + 尾部标量 */
default: /* N 输入:标量内积,s16 用 (v + 16384)>>15 舍入 */
```

一/双输入覆盖了绝大多数真实场景(stereo↔5.1 矩阵高度稀疏),所以 SIMD 化只做这两档就拿到了 95% 的收益——这是"针对常见形状特化"的又一例。

### 2.5 通道映射(channel map)与抖动(dither)

`swr_set_channel_mapping`(`swresample.c:47-52`)设置 int 数组:`output[i] 取自 input[channel_map[i]]`,负值表示静音——在 `swri_audio_convert` 里体现为取 `ctx->silence` 平面(`audioconvert.c:240-248`)。channel_map 在 `in_convert` 分配时传入(`swresample.c:352-353`),所以它是"输入选道",发生在一切处理之前;而 rematrix 是"加权和",发生在中段,两者互补。

dither 管线挂在 preout→out_convert 之间(`swresample.c:667-714`):矩形/三角抖动用 SIMD `mix_2_1` 把预生成噪声平面按样本混入;noise-shaping 类(Lipshitz/Shibata 等,`options.c:76-82`)走 `swri_noise_shaping_*`。降位深(如 fltp→s16)不配抖动会产生可听的相关性量化噪声,这一级是音频质量的最后一道闸门。

### 2.6 PTS 记账:swr_next_pts 与 async 补偿

`swr_convert` 每输出 ret 个样本就把 `s->outpts += ret * in_sample_rate`(`swresample.c:779-780`)——`outpts` 的时间基是 **1/(in_rate×out_rate)** 秒。`swr_next_pts`(`swresample.c:929-961`)以同样时间基计算外部 PTS 与内部样本账的差:偏差超阈值就 `swr_inject_silence` 填充或 `swr_drop_output` 丢弃(943-947 行),小偏差按 `max_soft_compensation` 摊到 `soft_compensation_duration` 内用 `swr_set_compensation` 微调步进(950-956 行)。aresample 滤镜把该时间基换算回 1/out_rate,详见⑤。

---

## ③ 采样格式与声道布局

### 3.1 samplefmt:planar 与 packed 的内存布局

`libavutil/samplefmt.c:36-49` 的 `sample_fmt_info` 表定义 12 种格式的名称/位深/是否 planar/对偶格式。核心函数:

- `av_get_bytes_per_sample` = `bits >> 3`(`samplefmt.c:108-112`),注意它对 packed/planar 一视同仁,返回的是**单样本**字节数;
- `av_samples_get_buffer_size`(`samplefmt.c:121-151`)一行代码浓缩了两种布局的差异:

```c
line_size = planar ? FFALIGN(nb_samples * sample_size,               align) :
                     FFALIGN(nb_samples * sample_size * nb_channels, align);
return planar ? line_size * nb_channels : line_size;              /* :145-150 */
```

即:**packed(交错)** 所有声道逐样本交织在一个平面里,`data[0] = s0L s0R s1L s1R ...`;**planar(分平面)** 每声道一段连续样本,`data[ch]` 各自步进 `linesize`。`av_samples_fill_arrays` 印证了这点:planar 时 `audio_data[ch] = buf + ch*line_size`(175-177 行)。

planar 的工程优势:同声道样本连续,SIMD/缓存友好;加声道无需重排已有数据;混音/重采样天然按平面处理(与②的 int_fmt 选 planar 呼应)。packed 的优势:与声卡/多数编码器位流格式一致,少一次交错。u8 格式的静音值是 0x80 而非 0x00(无符号偏置,`samplefmt.c:253-254`),这也是 swresample 在 u8 输入时预填 0x80 silence 的原因(`audioconvert.c:167-168`)。

### 3.2 channel_layout:从 64bit 掩码到任意自定义布局

FFmpeg 5.x 起布局 API 进入 `AVChannelLayout` 时代,四种序(`libavutil/channel_layout.h:119-155`):

| Order | 含义 | u 联合体 |
|---|---|---|
| UNSPEC | 只知道声道数,不知道位置 | — |
| NATIVE | 64bit 掩码,bit i 置位表示存在第 i 号命名声道 | u.mask |
| CUSTOM | 逐声道枚举,可带任意 id(含 AV_CHAN_UNKNOWN)与自定义名字 | u.map |
| AMBISONIC | 前 (n+1)² 个 ambisonic 分量 + 掩码描述的附加声道 | u.mask |

`av_channel_layout_from_mask` 即"NATIVE + popcount"(`channel_layout.c:253-264`)。经典 5.1/7.1 是 NATIVE 掩码的宏:`AV_CH_LAYOUT_5POINT1 = 5.0(side)+LFE`,`AV_CH_LAYOUT_5POINT1_BACK = 5.0(back)+LFE`,7.1 再加一对后置(`channel_layout.h:226-242`)。**"5.1"和"5.1(side)"其实是两种不同布局**——区别在环绕声道用 side 还是 back 位置,字符串映射表见 `channel_layout.c:200-204`。`av_channel_layout_default(n)` 按"第一个声道数匹配的命名布局"回退,如 6 声道默认 5.1(side),找不到才落 UNSPEC(841-852 行)。

CUSTOM 布局支持 `FL@Left+FR@Right` 式的带名通道与 USRnn 任意 id,解析在 `parse_channel_list`(266-311 行);`av_channel_layout_retype` 还能在 CUSTOM↔NATIVE↔AMBISONIC↔UNSPEC 间做(可能损失的)规范化,`canonical_order` 自动识别"这个 CUSTOM 其实是标准掩码"的情形(528-553 行)。`av_channel_layout_compare` 对 UNSPEC 特殊处理:双方都 UNSPEC 且声道数相同即视为相等(811-839 行)——因为此时位置语义缺失,无从比较。

---

## ④ AAC / Opus 解码器概览

### 4.1 AAC(libavcodec/aac/aacdec.c)

AAC 的"容器格式"有三层:

1. **裸帧(raw_data_block)**:由语法元素组成,SCE(单声道)/CPE(声道对)/LFE/CCE(耦合)/FIL(扩展)等,按 channel_config 或 PCE 定义的出现顺序排列(`decode_frame_ga` 主循环,`aacdec.c:2330` 起);
2. **ADTS 流**:7/9 字节头前缀,带 0xFFF 同步字,自描述采样率/声道配置,适合流式广播。解码入口 `aac_decode_frame_int` 检测 `show_bits(gb,12)==0xfff` 即解析 ADTS 头(`aacdec.c:2516-2525`,头解析在 `parse_adts_frame_header:2189-2249`);
3. **RAW 格式**:无头,配置经 AudioSpecificConfig(ASC)放进 extradata;运行中换配置靠 `AV_PKT_DATA_NEW_EXTRADATA` side data(`aacdec.c:2580-2589`)。LATM/LOAS 是第三种带复用头的封装,独立注册为 `aac_latm` 解码器(`aacdec.c:2624-2626`)。

每帧 1024 样本(或 960,`m4ac.frame_length_short`;ER LD/ELD 减半,2258-2263 行)。解码主链 `spectral_to_sample`(`aacdec.c:2123-2187`)按固定顺序套用工具:耦合 → LTP 预测 → TNS 时域噪声整形 → IMDCT 加窗 → **SBR** → 后置耦合。

**SBR(Spectral Band Replication)与 PS(Parametric Stereo)** 是 HE-AAC 的两个扩展,都藏匿于 FIL 元素的扩展载荷中(`decode_extension_payload`,`aacdec.c:2024-2083`):类型 EXT_SBR_DATA 表示"SBR 数据来了",此时把 `m4ac.sbr` 置 1、profile 升为 HE(2057-2060 行);若此前是单声道且 PS 未定,则判定 HE-AAC v2,`sbr=1; ps=1`,**输出布局直接重配为立体声**并打印 "Treating HE-AAC mono as stereo"(2050-2068 行)。SBR 的原理是把核心层 AAC 只编码低频段,高频用低频谱包络+噪声参数在解码端重建:`ff_aac_sbr_apply`(`aacsbr_template.c:1685-1758`)先做 64 带 QMF 分析(`sbr_qmf_analysis`),生成高频(`sbr_hf_gen`/`sbr_hf_assemble`),再综合回时域——**输出样本数是核心层的 2 倍**(升采样),这正是"SBR 扩展"对管线的含义:解码器内部完成了一次 2x 重采样。

配置协商用双缓冲 `OutputConfiguration oc[2]` push/pop(1225 行、2557 行):ADTS 头每帧都带 chan_config,但只有 `OC_LOCKED`(来自显式 ASC/PCE)的配置不可被覆盖,保证流中段误码不会撕裂布局。

### 4.2 Opus(libavcodec/opus/dec.c + parse.c)

Opus 包级"容器"极简:一个 **TOC 字节**描述一切(`parse.c:96-100`):

```c
i = *ptr++;
pkt->code   = (i     ) & 0x3;   /* 帧打包模式 0-3 */
pkt->stereo = (i >> 2) & 0x1;
pkt->config = (i >> 3) & 0x1F;  /* 32 档:码流模式+带宽+帧长 */
```

code 0=单帧,1=两等长帧,2=两变长帧(首帧长度用 Xiph lacing 变长整数编码),3=1~48 帧+可选 padding+可选 VBR 每帧长度表(175-244 行)。config 的高 3 位决定码流模式:config<12 → SILK(语音),12-15 → HYBRID,≥16 → CELT(音乐/通用)(254-263 行);单包总时长不得超过 120ms(249-252 行)。Opus 没有带外参数,一切自描述,RFC 7587 的 Ogg/WebM 封装只透传预跳(skip samples)与增益。

解码侧两个值得注意的事实:

- **Opus 解码器内嵌 libswresample**:`opus/dec.c:48` 直接 `#include "libswresample/swresample.h"`。SILK 核心按带宽只输出 8/12/16 kHz(`get_silk_samplerate`,132-139 行),解码器为每个流维护一个 `SwrContext` 统一升到 48 kHz,并预先喂入带宽相关的对齐静音 `silk_resample_delay`(71-73 行,193-216 行),SILK 帧解码后立即 `swr_convert` 到 48k 输出(266-274 行)。CELT 路径则原生 48 kHz,无需重采样;
- **多流/立体声相位抵消**:OpusContext 支持≥2 个流,`apply_phase_inv` 对侧链做相位反转防串音(124 行),流间用 `AVAudioFifo` 同步不同重采样延迟(86、110 行)。

与 AAC 对比:Opus 帧长 2.5-60ms 任意(每包自描述),无带外配置,无 SBR 式隐式升采样;AAC 帧长固定 1024,配置可带外可带内,扩展靠 FIL 元素逐步"升 profile"。两者的输出都交还给②的管线做后续规格化。

---

## ⑤ 音频滤镜:af_aresample 与 af_aformat

### 5.1 aresample:把 SwrContext 变成滤镜

`libavfilter/af_aresample.c` 是 libswresample 在滤镜图中的代言人,三个要点:

**(a) 格式协商**:query_formats(66-124 行)把用户通过 swr 选项设定的输出格式/率/布局作为输出侧**约束**注入滤镜协商(如 `osr` 定了就只允许该采样率),输入侧全放开;协商收敛后 `config_output` 用最终确定的输入输出参数 `swr_alloc_set_opts2` + `swr_init`(141-229 行)。aresample 通过 `child_class_iterate/child_next` 把 SwrContext 挂为**子对象**(398-426 行),所以 `-af aresample=osr=48000:clev=1.5` 这类 swr 选项可直接透传。

**(b) 下混元数据**:输入链带 `AV_FRAME_DATA_DOWNMIX_MATRIX` 或 `DOWNMIX_INFO` side data 时,把 DTS/AC-3 码流里携带的混音系数与 Lt/Rt 类型喂给 `swr_set_matrix` 与 matrix_encoding(148-227 行)——5.1 下混立体声时优先尊重混音师意图,而非 rematrix.c 的通用公式。

**(c) PTS 与缓冲排空**:`outlink->time_base = {1, out_rate}`(236 行),输出 PTS 天然以样本为 tick。`filter_frame` 里三步换算(288-295 行):

```c
int64_t inpts = av_rescale(insamplesref->pts,
        inlink->time_base.num * (int64_t)outlink->sample_rate * inlink->sample_rate,
        inlink->time_base.den);              /* → 1/(in_rate*out_rate) 时间基 */
int64_t outpts = swr_next_pts(aresample->swr, inpts);
outsamplesref->pts = ROUNDED_DIV(outpts, inlink->sample_rate);  /* → 1/out_rate */
```

输出缓冲预估 `n_in*ratio + 32 + 滤波器延迟`(261-269 行);因重采样器有内部滞留,activate 循环在消费完输入帧后还会以 `flush_frame` 反复排空(354-363 行),EOF 时 `swr_convert(NULL,...)` 触发镜像反射 flush 并把 EOF 的 PTS 定在 `next_pts`(380-389 行)——**帧结束时间戳也按样本精确记账**。

### 5.2 aformat:只谈格式、不碰数据的"声明式"滤镜

`af_aformat.c` 全文 145 行,没有任何样本处理代码:它只在 query_formats 里把用户给的 `sample_fmts|sample_rates|channel_layouts` 白名单声明为输入输出共同约束(107-133 行),元数据类滤镜标记 `AVFILTER_FLAG_METADATA_ONLY`(139 行)。真正的转换由滤镜图格式协商**自动插入的 aresample** 完成——`aformat` 是约束的声明,`aresample` 是约束的执行,二者配合正是 FFmpeg "negotiation + auto-conversion" 架构的缩影。

---

## ⑥ 设计动机与取舍

1. **内部统一 planar + 固定中缀格式**:swresample 把任意格式对收敛为"入转换 → {重采样,混音} → 出转换"三段,状态空间从 O(格式²×阶段²) 压到 O(格式×阶段)。代价是同格式直通时要靠指针别名恢复零拷贝(`swresample.c:627-647`),逻辑较绕(三个 AudioData 指针互相赋值的推断链)。
2. **自研引擎 + soxr 插件**:内置 SWR 引擎胜在零依赖、支持精确有理比、可做实时 compensation(拉流跟钟必需);soxr 胜在极致质量。用 8 函数 Resampler 接口隔离,用户一个 `resampler=soxr` 选项切换。取舍:soxr 不支持 compensation,直播场景不能换。
3. **多相查表 + 双相位内插,而非任意相位卷积**:把连续相位插值问题离散成 1024 相位查表 + 相邻相位线性插值,把每输出样本的卷积核选择从乘法运算降为两次查表;`exact_rational` 再把常见比率(48k↔44.1k)退化为零误差查表。这是"精度-吞吐"曲线上的甜点位。
4. **rematrix 的常识规则表而非通用算法**:build_matrix 是几百行 if 链,每条注释对应 ITU/ISMFE/BS.2127 规范的具体系数。不优雅但可审计、可与规范逐条对照;通用几何算法(如 VBAP)反而难保证与行业下混听感一致。
5. **AAC 双缓冲配置协商**:OC_LOCKED/OC_TRIAL 的 push/pop 用极小的状态机解决了"带内配置可变 + 误码回滚"两个难题,是流式解码器容错的范本。
6. **Opus 解码器复用 swresample**:库间无分层洁癖。48 kHz 是 Opus 的"虚拟原生率",SILK 的 8/12/16k 输出直接用自家重采样器补齐,避免了在 SILK 里再实现一遍多相滤波。
7. **音频 PTS 为什么比视频要求高**:①视频帧间隔 40ms 量级,呈现端有 vsync 队列缓冲,1 帧内的抖动无感;音频是连续流,样本即时间——48 kHz 下 1 样本 ≈ 20.8µs,重采样步进 `frac/index` 本身就是分数样本精度的状态机(`resample_template.c:128-138`),延迟查询精确到任意时间基(`resample.c:408-416` 的 `av_rescale`)。②编解码帧长固定(AAC 1024 样本、Opus 120ms 上限),封装层必须按样本数滚动记账,差一个样本长年累月就漂成可闻的口型失配。③音频是唯一能"无损变速"的轨道:`swr_set_compensation` 改变 dst_incr 即可微拉伸,FFmpeg 的 async 补偿(②.6)全部构建在样本精度之上——视频若要补偿只能丢帧/重复帧。④所以滤镜图把音频输出 time_base 设为 1/sample_rate(`af_aresample.c:236`),比视频常用的 1/90000 或 1/fps 精细 2-3 个数量级。

---

## ⑦ FAQ

**Q1:为什么 swresample 内部只认 s16p/s32p/s64p/fltp/dblp?**
中间所有阶段(重采样滤波、矩阵混音)都按"每声道一段 float/int 连续样本"实现,packed 会迫使 SIMD 按交错步长处理。校验在 `swresample.c:257-264`;单声道时 packed 与 planar 等价,所以 `set_audiodata_fmt` 直接把 ch_count==1 视为 planar(98-104 行)。

**Q2:s16 混音的矩阵为什么乘 32768?误差怎么处理?**
s16 样本域是 [-32768,32767],系数 1.0 对应 32768 定点(`rematrix.c:709`)。量化到 int 的舍入误差用 `rem` 逐系数扩散到下一项(704-715 行),避免所有系数同向偏置。

**Q3:什么时候 swr_convert 完全不发生数据拷贝?**
需同时满足:int_fmt==输出格式且输出 planar、preout 可别名到 in/postin/midbuf、dither 关闭(636-647 行的别名链),常见于 fltp→fltp 同率纯 rematrix。反向同理(627-628 行)。

**Q4:44100→48000 为什么没有相位误差?**
`exact_rational`(默认开)发现 48000/44100 = 160/147 可精确约分,phase_count 取 160,所有插值位置都落在整相位上,连线性插值分支都不会进(`resample.c:197-205`,`options.c:87`)。

**Q5:SOXR 引擎有什么限制?**
不支持 `swr_set_compensation`(Resampler 表缺该成员,`soxr_resample.c:126-134`;`swresample.c:922-923` 返回 EINVAL),因此 async 时间基补偿模式下不能用 soxr。另外它内部延迟的记账在 flush 时由 `delayed_samples_fixup` 修正(69-82 行)。

**Q6:AAC 的 ADTS、LATM、RAW 三种封装有什么区别?**
ADTS 每帧带同步头(0xFFF),自描述、容错好但每帧浪费 7-9 字节(`aacdec.c:2516`);RAW 无头,配置放 extradata,是 MP4/MKV 的方式;LATM/LOAS 是 AAC 专属复用封装,单独注册为 aac_latm 解码器(2624-2626 行)。同一套核心解码,入口分流在 `aac_decode_frame:2603-2612`。

**Q7:为什么 HE-AAC v2 单声道流会解码出立体声?**
PS(Parametric Stereo)用单声道核心+空间参数重建双声道。解码器在 FIL 扩展里探测到 PS 时把 `m4ac.ps` 置 1 并重新配置输出布局(`aacdec.c:2050-2056`),这是少数"解码过程中改变输出声道数"的合法情形。

**Q8:Opus 解码输出一定是 48 kHz 吗?**
是。SILK 核心按带宽输出 8/12/16 kHz,解码器用内嵌 SwrContext 升到 48 kHz(`opus/dec.c:193-216,266-274`);CELT 原生 48 kHz。48 kHz 是 Opus 规范规定的唯一输出率。

**Q9:"5.1"和"5.1(side)"有什么区别?我该用哪个?**
环绕声道位置不同:side(SL/SR)vs back(BL/BR)。Dolby 数字 5.1 传统上 back,ITU 建议侧置。字符串表见 `channel_layout.c:200-204`。混音系数会不同(rematrix 对 side/back 有专门路由规则),标错会导致环绕声像偏移。

**Q10:u8 格式静音为什么是 0x80?**
u8 是无符号格式,0 表示最小振幅,中点 128 才是零电平。`av_samples_set_silence` 特判(`samplefmt.c:253-254`),u8↔s16 转换时统一做 ±0x80 偏置(`audioconvert.c:55,60`)。

---

## ⑧ 深挖问题(供后续调研)

1. **补偿态与 exact_rational 的交互**:`set_compensation` 触发 `rebuild_filter_bank_with_compensation` 用 `phase_count_compensation` 重建滤波器组并同步缩放 `index`(`resample.c:280-326,321`);补偿进行中 `get_out_samples` 的上界还特意加了 `+2` 容差以"便于证明优化不破坏上界"(418-424 行注释)。值得验证:补偿反复启停时 frac/index 的不变量与 get_delay 的符号约定。
2. **镜像反射 flush 的边界伪影**:`invert_initial_buffer` 与 `resample_flush` 都用样本镜像填充滤波器历史(`resample.c:457-502,437-454`),等价于在流首/尾做对称延拓。它与 AAC 解码器的 priming(skip_samples=1024,`aacdec.c:2007-2009`)叠加时,首帧 PTS 与实际可听样本的对齐关系值得实验验证。
3. **别名链的极限配置**:636-647 行的 preout→out 别名在 `S32P 输出 + dither.output_sample_bits&31` 时被显式排除;可系统梳理"哪些(入,出,int_fmt,dither)组合能达到全链零拷贝",作为性能回归清单。
4. **rematrix 规则表的完备性**:build_matrix 中大量 `av_assert0(0)` 兜底分支(如输出既无 FL 也无 FC,`rematrix.c:203,239`)依赖 `sane_layout` 的前置过滤;构造 AMBISONIC/CUSTOM 输入 + 非常规输出能否绕过 sane_layout 到达 assert,是一个模糊测试向的课题。
5. **outpts 时间基的数值极限**:1/(in_rate×out_rate) 基下,192k×192k ≈ 3.7e10 tick/s,int64 可承载约 8000 年,安全;但 `swr_next_pts` 中 `fdelta = delta/(double)(in_rate*out_rate)`(`swresample.c:939-940`)在极端采样率组合下的双精度舍入是否影响 min_compensation 判定,可用属性测试确认。

---

### 附:本文引用文件清单

| 文件 | 主题 |
|---|---|
| libswresample/swresample.c | 上下文初始化、流水线编排、流式缓冲、PTS 补偿 |
| libswresample/resample.c / resample_template.c | 多相滤波器组、双相位内插内核、补偿与延迟 |
| libswresample/soxr_resample.c | SOXR 引擎适配 |
| libswresample/audioconvert.c | 采样格式转换、channel_map、SIMD 分发 |
| libswresample/rematrix.c | 混音矩阵推导、量化与执行 |
| libswresample/options.c / swresample_internal.h | 默认参数、AudioData/Resampler 接口 |
| libavutil/samplefmt.c | 格式表、planar/packed 缓冲尺寸与填充 |
| libavutil/channel_layout.c(/.h) | 布局解析/比较/规范化,AVChannelOrder |
| libavcodec/aac/aacdec.c、aacsbr_template.c | AAC 容器/语法元素/SBR/PS |
| libavcodec/opus/dec.c、parse.c | Opus TOC 打包、SILK 重采样、流同步 |
| libavfilter/af_aresample.c、af_aformat.c | 滤镜化重采样与格式约束 |
