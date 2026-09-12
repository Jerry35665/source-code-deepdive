# W 章 · 音频滤镜族与 AAC 编码器内部

> 调研基线:ffmpeg master commit 9f63b36a。行号均为仓库相对路径 `文件:行号`,经 grep/Read 实际核对。
> 本章与系列前章的对称关系:07 章 swresample ↔ 本章 af_pan/af_aresample 的"下沉";19 章视频滤镜族 ↔ 本章音频滤镜落地;08 章解码侧 ↔ 本章 aacenc 编码侧。

---

## 1. 全景:音频滤镜族地图 + AAC 编码数据流

### 1.1 滤镜范式对照表(对照 19 章视频滤镜)

| 维度 | 视频滤镜(19 章) | 音频滤镜(本章) | 依据 |
|---|---|---|---|
| 协商三元组 | width/height/pix_fmt | sample_fmt / sample_rate / ch_layout | libavfilter/af_aformat.c:107-133 |
| 协商入口 | FILTER_QUERY_FUNC2(query_formats) | 同左 | libavfilter/af_volume.c:469 |
| 输出属性定妆 | config_props 可改写几何 | config_output 只读协商结果 | libavfilter/af_amix.c:243-291 |
| 帧同步 | framesync(PTS 对齐帧) | input_state + av_audio_fifo(凑样本) | libavfilter/vf_overlay.c:343 vs libavfilter/af_amix.c:436-515 |
| 缓冲 | 帧引用计数 | av_audio_fifo 按输入逐路积压 | libavutil/audio_fifo.h:65,94,144 |
| 最简样本 | vf_rotate 等 | af_volume(单输入单输出) | libavfilter/af_volume.c:443-457 |
| swr 复用 | — | af_pan / af_aresample 直接下沉 swresample | libavfilter/af_pan.c:302-347 |

音频协商的核心 API 三件套:`ff_set_sample_formats_from_list2`(格式)、`ff_set_common_samplerates_from_list2`(采样率)、`ff_set_common_channel_layouts_from_list2`(布局),af_aformat.c:107-133 是三者最干净的示范:

```c
static int query_formats(const AVFilterContext *ctx,
                         AVFilterFormatsConfig **cfg_in,
                         AVFilterFormatsConfig **cfg_out)
{
    ...
    if (s->nb_formats)
        ret = ff_set_sample_formats_from_list2(ctx, cfg_in, cfg_out, s->formats);
    if (s->nb_sample_rates)
        ret = ff_set_common_samplerates_from_list2(ctx, cfg_in, cfg_out, s->sample_rates);
    if (s->nb_channel_layouts)
        ret = ff_set_common_channel_layouts_from_list2(ctx, cfg_in, cfg_out, s->channel_layouts);
```
(libavfilter/af_aformat.c:107-133,摘录有省略)

aformat 自身被标记 `AVFILTER_FLAG_METADATA_ONLY`(libavfilter/af_aformat.c:139)——它不碰数据,只收缩协商空间,是"纯协商滤镜"的极端样本。

### 1.2 AAC 编码数据流(对照 08 章解码侧的逆向)

```
AVFrame(FLTP, 1024 samples/ch)
   │  ff_af_queue_add 存 PTS 账本        libavcodec/aacenc.c:1234
   ▼
copy_input_samples:3072 样本滑窗 + 声道重排   aacenc.c:1196-1216
   ▼
逐元素(chan_map: SCE/CPE/LFE)
   ├─ psy.model->window[_pair]  选块类型(长/短/过渡)  aacenc.c:1291 / aacpsy.c:1162-1209
   ├─ 削波风险评估 clip_avoidance_factor            aacenc.c:1313-1336
   └─ apply_window_and_mdct(KBD/正弦窗 + MDCT1024/128) aacenc.c:599-614
   ▼
打包分配 ff_alloc_packet(8192*ch)                 aacenc.c:1351
   ▼
do-while 率控循环(λ 调整,最多数轮)               aacenc.c:1354-1577
   ├─ psy.model->analyze 阈值/PE/比特分配          aacenc.c:1383 → aacpsy.c:680-946
   ├─ common_window 判决(CPE 两声道同窗)          aacenc.c:1391-1402
   ├─ TNS 搜索+滤波(NMR 码型时先于量化)           aacenc.c:1404-1423,1454-1462
   ├─ M/S / I/S 判决(NMR 预判决或搜索)            aacenc.c:1438-1442,1467-1481
   ├─ search_for_quantizers(码本/scalefactor)      aacenc.c:1452
   └─ 写码流:元素头→ics_info→MS→band/sf/pulse→TNS→谱  aacenc.c:1483-1494
   ▼
TYPE_END + flush + ff_af_queue_remove 补 PTS       aacenc.c:1615-1641
   ▼
AVPacket(extradata=AudioSpecificConfig 在 init 生成,aacenc.c:494-523)
```

---

## 2. af_volume 专节:最简滤镜与三精度路径

### 2.1 选项即协商

volume 的三个关键选项(libavfilter/af_volume.c:66-88):`volume`(表达式,默认 "1.0")、`precision`(fixed/float/double)、`eval`(once/frame)。`precision` 不是运算细节,而是直接决定协商集合——query_formats 用二维表按精度给出允许的采样格式(libavfilter/af_volume.c:135-155):fixed 允许 U8/S16/S32(含 planar),float 只允许 FLT/FLTP,double 只允许 DBL/DBLP,再交给 `ff_set_sample_formats_from_list2`(af_volume.c:158)。

### 2.2 表达式与变量

表达式变量表含 n/pts/t/volume 等 11 个符号(libavfilter/af_volume.c:46-59),`set_expr` 用 `av_expr_parse` 解析(af_volume.c:92-110)。`set_volume` 求值并处理 NaN:once 模式报错、frame 模式降级为 0(af_volume.c:249-257)。fixed 精度把音量量化为 `volume_i = volume*256`(af_volume.c:264-268)。

### 2.3 三路分派:函数指针而非 switch

固定点路径按"打包格式 + 音量大小"选内核——小音量用省掉 int64 的 `_small` 变体(af_volume.c:216-229),这决定了 `volume_init` 只需在 set_volume/replaygain 变更时重跑一次(af_volume.c:272, 367):

```c
case AV_SAMPLE_FMT_S16:
    if (vol->volume_i < 0x10000)
        vol->scale_samples = scale_samples_s16_small;
    else
        vol->scale_samples = scale_samples_s16;
    break;
...
#if ARCH_X86 && HAVE_X86ASM
    ff_volume_init_x86(vol);
#endif
```
(libavfilter/af_volume.c:222-241)

浮点/双精度不走函数指针,直接用 fdsp 的 SIMD:`vector_fmul_scalar`(float)与 `vector_dmul_scalar`(double),见 filter_frame 分派(af_volume.c:420-431)。固定点内核是手写循环 + 饱和裁剪,例如 s16:`av_clip_int16(((int64_t)smp_src[i] * volume + 128) >> 8)`(af_volume.c:188)。

### 2.4 filter_frame:教科书式单帧处理

流程(af_volume.c:323-441):
1. 查 replaygain side data(331);若启用,track/album 增益 + preamp 换算为线性 `ff_exp10((g+preamp)/20)`(362),noclip 时再压到 `1/peak`(364),随后移除 side data(369);
2. 更新表达式变量(372-378),eval=frame 时逐帧重估(380-381);
3. 快路径:volume==1.0 直接透传(383-386);
4. 就地写:输入帧可写且非 fixed-负增益时复用原帧(389-391),否则 `ff_get_audio_buffer` 新分配并拷贝 props(392-404);
5. 按 plane 迭代,planar 时 plane_samples=`FFALIGN(nb_samples, align)`、packed 时乘声道数(409-412);
6. `ff_filter_frame` 下推(440)。

教学要点:replaygain 变更后调用 `volume_init(vol)` 重建函数指针(367)——"参数变更→重选内核"是这个滤镜教给后来者的模板;运行时 `volume` 命令同理走 process_command(af_volume.c:307-321)。滤镜注册为 `AVFILTER_FLAG_SUPPORT_TIMELINE_GENERIC`(af_volume.c:463),表示逐帧无状态、可安全用于时间线裁剪。

---

## 3. af_pan 专节:矩阵语法 → swr 下沉

### 3.1 语法解析(init)

pan 只有一个 `args` 选项(libavfilter/af_pan.c:409-412),语法 `out_layout | out_ch = gain * in_ch + ...`,`<` 前缀表示归一化(af_pan.c:184-194,`need_renorm` 位图记录于 187)。声道名支持命名(FL/FR,经 `av_channel_from_string`)与 `cN` 序号两种(af_pan.c:66-92),两者不可混用(af_pan.c:208-213)。64×64 增益矩阵存于 `gain[MAX_CHANNELS][MAX_CHANNELS]`(af_pan.c:47)。

解析末尾一个关键判定:`are_gains_pure`(af_pan.c:94-114)——所有增益非 0 即 1、且每个输出声道只由单一输入组成时,视为"纯增益"。纯增益根本不是混音,而是通道重排/丢弃/复制。

### 3.2 下沉:两条路

config_props(af_pan.c:272-373)把矩阵翻译给 swresample。swr 上下文用同格式同采样率、只变布局地构建(af_pan.c:302-305),于是 swr 内部退化为纯 rematrix——这正是 07 章 rematrix 机制在滤镜侧的借尸还魂:

- 纯增益路:由矩阵反推 `channel_map`,走 `swr_set_channel_mapping`(af_pan.c:310-325;API 见 libswresample/swresample.h:371)。通道映射是 O(1) 拷贝,不做乘加;
- 混音路:若某输出带 `<` 前缀,先把该行归一化(除以该行增益绝对值之和,af_pan.c:327-343),再 `swr_set_matrix(pan->swr, pan->gain[0], stride)`(af_pan.c:344;API 见 libswresample/swresample.h:415)。

最后统一 `swr_init`(af_pan.c:347)。filter_frame 每帧分配输出帧后一次 `swr_convert`(af_pan.c:387),无 FIFO、无延迟(rematrix 不需要延迟)。

### 3.3 与 07 章的衔接

07 章讲过 swr 的 rematrix 在 `swr_init` 时由 in/out 布局自动推导(如 5.1→stereo 的默认下混系数);pan 的价值在于把"用户自定义矩阵"喂进同一条管线。同一机制在 af_aresample 里还有第三个入口:link 侧的 `AV_FRAME_DATA_DOWNMIX_MATRIX` side data 也会调 `swr_set_matrix`(libavfilter/af_aresample.c:148-157)。三处入口、一个引擎——这是"语法糖下沉公共库"的标准案例。

---

## 4. af_amix 专节:多输入 activate 调度与归一化

### 4.1 状态机:INPUT_ON / INPUT_EOF

amix 只有两位状态(libavfilter/af_amix.c:48-49):`INPUT_ON`(活跃)与 `INPUT_EOF`(已收到 EOF 但 FIFO 里可能还有余样)。EOF 后 `INPUT_ON` 被清除的时机是 FIFO 排空那一刻(af_amix.c:481-482)——"EOF"与"死亡"是两个时刻,这个区分是整个调度的基础。

### 4.2 为什么不用 framesync(对照 19 章 overlay)

vf_overlay 用 `ff_framesync_init_dualinput` + `ff_framesync_activate`(libavfilter/vf_overlay.c:343,903),按 PTS 对齐"帧"。音频等价物存在两难:各输入帧的 nb_samples 任意、PTS 粒度是样本而不是帧;音频混音需要的不是"同一时刻的两帧",而是"同一时刻的 N 个样本"。amix 的解法:

1. 每路输入挂一个 `av_audio_fifo`(af_amix.c:264-268,初始 1024 样本容量,自动扩容);
2. 只有第一路输入维护 FrameList(libavfilter/af_amix.c:56-75)——链表记录每帧的 (nb_samples, pts),输出帧尺寸永远跟随第一路的帧边界(af_amix.c:303-305),PTS 也从链表头取(af_amix.c:319);
3. 其余各路只问 FIFO 够不够:`av_audio_fifo_size < nb_samples` 且未 EOF 就 `return 0` 等待(af_amix.c:308-312),已 EOF 就把输出截短"排水"(af_amix.c:313-315)。

一句话:视频 framesync 对齐的是离散帧序列,音频 amix 对齐的是连续样本流上的"第一路节拍器"。

### 4.3 activate 主循环

```c
FF_FILTER_FORWARD_STATUS_BACK_ALL(outlink, ctx);        // amix.c:443
for (i = 0; i < s->nb_inputs; i++) {
    if ((ret = ff_inlink_consume_frame(ctx->inputs[i], &buf)) > 0) {
        if (i == 0)   // 第一路:记录帧边界
            frame_list_add_frame(s->frame_list, buf->nb_samples, pts);
        av_audio_fifo_write(s->fifos[i], ...);
        output_frame(outlink);   // 每来一帧就尝试产出一帧
    }
}
```
(libavfilter/af_amix.c:443-471,摘录有省略)

随后处理 EOF 确认(474-490)、按 duration 模式判全局 EOF(492-495,逻辑在 calc_active_inputs af_amix.c:421-434:longest 熄灭全部、shortest 任一熄灭、first 第一路熄灭),最后按需向输入催帧(497-512):第一路没帧了向 input0 要(503-506),否则带着期望样本数调 `request_samples`(af_amix.c:394-413),它对每个不够数的输入调 `ff_inlink_request_frame`(409)。DURATION_FIRST 时最小样本数直接取 fifo0 水位(400-401)。

### 4.4 权重与 dropout_transition

`calculate_scales`(af_amix.c:212-241)每帧重算各路缩放:
- 归一化分母是**活跃**输入的权重绝对值和(217-219),不是配置的总和——某路 EOF 后其余路自动抬升;
- 但抬升不是阶跃:`scale_norm` 以 `nb_samples/(dropout_transition*sample_rate)` 的斜率渐变到新目标(221-228),默认过渡 2 秒(选项定义 af_amix.c:193-195),避免换歌瞬间音量跳变;
- `normalize=0` 时直接用 `|weights[i]|`(233-234)。

混音本体是 `vector_fmac_scalar`(累加乘,FLT/DBL 两版)逐 plane 累到 out_buf(af_amix.c:352-378)。注意 amix 只协商浮点格式(`FILTER_SAMPLEFMTS(AV_SAMPLE_FMT_FLT, FLTP, DBL, DBLP)`,af_amix.c:630-631),整数输入必须前置 aformat/aresample。

权重可运行时改:`process_command` 重解析后重置 scale_norm(af_amix.c:593-609)。

---

## 5. AAC 编码专节:从 init 到 bitstream 的行号链

### 5.1 init:协商与常量(libavcodec/aacenc.c:1727-1899)

- 帧长写死:`avctx->frame_size = 1024; avctx->initial_padding = 1024`(aacenc.c:1738-1739);λ 初值 120(1740);
- 布局检查:遍历 `aac_normal_chan_layouts` 匹配则免 PCE(1746-1751);7.1(wide) 因历史误标问题强制 PCE,除非 `-aac_allow_71wide`(1753-1765);冷门布局查 37 项 `aac_pce_configs` 表(94-431),查不到直接 EINVAL(1773-1775);命中则取 reorder_map/chan_map(1779-1780);
- 默认码率:未指定时按元素类型猜——CPE 128k、SCE 69k、LFE 16k(1788-1794);
- 采样率:必须在 `ff_mpeg4audio_sample_rates` 13 档表中(av_assert1 兜底,1797-1803);
- 码率上限:每帧 6144 bit/声道封顶并钳制(1806-1811);
- M/S 在 >3 声道时直接关掉(1831-1833,注释承认是权宜);
- 带宽 cutoff:按每声道码率查表插值,下限 8kHz、上限 Nyquist(1836-1859);
- 生成 extradata `put_audio_specific_config`(1879 调用,函数体 494-523):5bit profile+1、4bit 采样率档、4bit chcfg、GASpecificConfig 中"frame length - 1024 samples"写 0(509),并显式声明无 SBR(516-518);
- 资源:mdct1024/mdct128 两个 av_tx(1677-1694)、每声道 3*1024 浮点滑窗(1696-1704)、psy 上下文 `ff_psy_init`(1888-1890)、TNS 用 LPC 求解器(1891)、PTS 账本 `ff_af_queue_init`(1896)。

### 5.2 帧收集与滑窗(aacenc.c:1218-1350)

`aac_encode_frame` 先把帧挂进 afq(1234),再 `copy_input_samples`:每声道 3072 样本环形布局,前 1024 是上一帧尾部,新样本写中段,EOF 后清零补 padding(1196-1216);`reorder_map` 在这里完成"libavcodec 默认序 → AAC 传输序"(1196 注释与 1210)。首帧 `frame_num==0` 只填窗不发码(1243-1244)。

逐元素循环(1247-1350):
- CPE 两声道先做 `psy.model->window_pair` 联合选窗(1256-1266),防两声道块类型分叉;LFE 强制 ONLY_LONG 且 num_swb 只有 1~3(1278-1289);
- 普通声道 `s->psy.model->window(...)` 单独选窗(1291-1293);
- 削波评估:每窗 2048/num_windows 个时域样本的最大绝对值超 `CLIP_AVOIDANCE_FACTOR`(0.95,libavcodec/aacenc.h:37)则记 window_clipping 并算缩减因子(1313-1336);
- `apply_window_and_mdct`:四种窗序列各自加窗(539-597),长块一次 mdct1024、短块 8 次 mdct128(599-614),随后把 audio 后半 memcpy 到前半(612)、coeffs 备份到 pcoeffs 供率控回滚(613);
- NaN/Inf 检查:系数绝对值 ≥1E16 直接报错(1340-1345)。

### 5.3 psy 模型(aacpsy.c)

模型注册(`ff_aac_psy_model`,aacpsy.c:1211-1219)名字自述 "3GPP TS 26.403-inspired":window=psy_lame_window(LAME 派生选块)、analyze=psy_3gpp_analyze(3GPP 派生阈值)。psymodel.c 只是壳:按 codec_id 挂模型、按 chan_map 分组(每组 CPE 两声道+双份虚拟声道给耦合用)(libavcodec/psymodel.c:28-65)。

`psy_3gpp_analyze_channel`(aacpsy.c:680-913)的阈值流水线,全部对应 3GPP TS 26.403 小节:
1. `calc_thr_3gpp` 算每 sfb 能量/初始阈值(714);
2. 扩散:向高低频邻带取 `FFMAX(thr, 邻带thr*spread系数)`(720-729);
3. 绝对阈 ATH 合入(731-734,ath 函数 315-327);
4. 前回声控制:新阈值不高于上帧的 RPELEV 倍(736-744);
5. 感知熵 PE 累加(747-749);
6. 目标比特:QSCALE 模式按 global_quality 缩放 PE(761-777),ABR 模式走 `calc_bit_demand` 位 reservoir(778-790),结果写 `ctx->bitres.alloc`(790);
7. 两轮 reduction 迭代把 PE 压到目标(792-834);
8. 结果回写 `psy_band->threshold/energy/bits`(890-897)。

选块器 psy_lame 系(978-1209):高通 FIR + 子块能量比对检测 attack(1001-1049),新增的"新颖性检查"用 HP 包络历史过滤周期性脉冲(1035-1046);分组按首个 attack 位置查表(1149-1155)。本 commit 新增的 pair 同步:两声道 attack 图合并(merge)、除非 `pair_decoupled` 判定该声道对联合工具已死(aacpsy.c:1191-1208)。

### 5.4 TNS(aacenc_tns.c)

TNS = 时域噪声整形:在频域系数上跑一阶 AR 滤波,把量化噪声推到掩蔽更强的时域区段。搜索入口 `ff_aac_search_for_tns`(281-453):
- 长块最多 3 个滤波器、每滤波器阶数 12,短块 1 个 7 阶(288, 311);
- 滤波方向按时域能量重心定:e_early>e_late 则正向(325-334),"让量化噪声留在响的被掩蔽侧";
- LPC 拟合在感知加权谱 `X/sqrt(thr)` 上做,阈值地板 `TNS_WEIGHT_FLOOR`(357-375);
- 双重接受门:LPC 预测增益 ∈ [1.4, 6.0](47-50,判决在 376-377),量化后再实测增益过 `c1`(长块 1.4/短块 3.2,412-413)——注释明说这是 Apple RE 派生的经验门槛;
- 应用侧 `ff_aac_apply_tns`(112-160)完全模仿解码器路径(`tns_decode_coef`→AR 滤波,152-156),且在 M/S、I/S 之后的系数上跑(120-122);
- 与 PNS 互斥:`tns_max_nonpns` 把 TNS 带范围截在第一个 NOISE_BT 前(103-109)。

### 5.5 立体声工具判决

本 commit 的显著变化:默认码型是 `AAC_CODER_NMR`(aacenc.c:1903;枚举 aacenc.h:40-49),派发表在 libavcodec/aaccoder.c:827-865,其 search_for_ms/search_for_is 为 NULL(861-862)——因为 NMR 在量化**之前**按 psy 数据逐带判决立体声模式(`nmr_decide_stereo`,aacenc.c:843-1000):
- M/S 条件:`es < 0.5*em`(NMR_MS_EQUIV,739)+ EMA 平滑 + 粘滞系数;
- I/S 条件:频带 >6100Hz(736)+ 速率压力斜坡 is_ramp(873-875)+ 图像误差 EMA 过门限(733);
- 判决后立即原地把 L/R 重写为 M/S 或载波+置零(757-778, 813-836),让后续量化直接工作在最终频谱上;
- 联合工具"候选率"回灌 psy 的 `pair_decoupled`,形成窗口同步↔立体声判决的跨帧反馈(990-999)。

传统路径仍然保留:`ff_aac_search_for_is`(libavcodec/aacenc_is.c:109 起)按"量化代价 dist2 ≤ dist1"逐带试错(aac_is_encoding_err 45-107,pass 判定在 99),低频限 `INT_STEREO_LOW_LIMIT 6100`(34);`search_for_ms` 与 `apply_mid_side_stereo`(aacenc.c:1002-1032)在率控循环内调用(1467-1481)。

### 5.6 量化循环与码流写出

率控 do-while(1354-1577)是 AAC 编码的心脏:
1. 每轮 init_put_bits 重写整个包(1355);
2. 元素循环内 `s->psy.model->analyze` 出比特分配 target_bits(1383-1389);
3. 各码型的 `search_for_quantizers` 定 scalefactor/码本(1452);
4. 写出顺序严格对应 AAC 语法:元素 tag(3bit)+inst index(1371-1372)→ CPE common_window 标志+ics_info+ms_info(1483-1490)→ 单声道:global_gain(1158)→ics_info(若无公共窗)→band_info→scalefactor 差分霍夫曼(1051-1082)→pulse→TNS 标志/信息→谱系数(1106-1129,`quantize_and_encode_band`);
5. λ 迭代:超码率时 `s->lambda *= FFMIN(0.9f, ratio)`(1526);稳态用四重平方根 + [0.9,1.1] 钳制做慢跟踪(1551-1552);若启用了 M/S 等有损变换,重试前从 pcoeffs 恢复系数(1563-1571);
6. 收尾:TYPE_END(1615)、flush(1616)、`ff_af_queue_remove` 把正确 PTS 还给包(1641)。

编码器能力:`AV_CODEC_CAP_DELAY | AV_CODEC_CAP_SMALL_LAST_FRAME`(1935-1936),只吃 `AV_SAMPLE_FMT_FLTP`(1944)。收尾时打印工具使用率统计(Qavg/TNS/M-S/I-S/PNS 百分比,1655-1663)。

---

## 6. 设计动机

**为什么 pan 直接下沉 swr,而不自己写混音循环?** 混音矩阵乘、饱和、定点化在 swresample 里已有一套 SIMD 优化过的实现;pan 的全部语义(init 解析出矩阵/映射)恰是 swr 的输入格式。pan 自身 filter_frame 只做"分配输出帧 + swr_convert"(af_pan.c:375-398),维护成本近乎为零。代价是 pan 沿用了 swr 的限制(最大 64 声道,af_pan.c:41)。

**为什么 amix 自己管理 FIFO,而视频用 framesync?** 见 4.2:音频的连续流语义使"帧对齐"失去意义,真正的同步单位是样本数;FIFO + 第一路 FrameList 是这个语义的最小实现。另外 framesync 依赖 PTS 相等或可插拔,而 amix 的 duration=longest 语义天然要求"EOF 后继续消费余样",FIFO 状态机(INPUT_ON/INPUT_EOF,af_amix.c:48-49)表达得更直接。

**为什么 aresample 要 preinit 里就 swr_alloc?** 滤镜的 options 继承机制:`resample_child_class_iterate` 把 swr 的类设为子类(af_aresample.c:398-426),用户 `-af aresample=osf=fltp` 直接写 swr 选项;而 query_formats 需要读这些选项(osf/osr/ochl)来约束 outlink(af_aresample.c:80-123),这发生在 preinit 之后、init 之前,所以 swr 上下文必须在 preinit 就存在(af_aresample.c:48-58)。

**为什么音频滤镜没有视频的"几何 outlink"问题?** 视频的 outlink 尺寸可能依赖首帧(如 scale=w=-1),协商期拿不到;音频的三个属性(fmt/rate/layout)在 query_formats 阶段就能枚举完整,config_output 只是"验收"(af_amix.c:243-291 只做分配)。唯一的例外是重采样类:aresample 的解法不是推迟协商,而是让 swr 选项**参与**协商(af_aresample.c:97-123 把 osr/osf/ochl 变成 outlink 候选集),再用 assert 兜底验证(af_aresample.c:238-240)。

**AAC encoder 与 decoder 的结构对称性** (对照 08 章):语法层完全镜像——enc 的 put_ics_info/encode_ms_info/encode_scale_factors/encode_pulses(aacenc.c:620-650,1051-1101)逐字段对应 dec 的读出函数;TNS 应用侧刻意"按解码器的方式走带区"(aacenc_tns.c:336-340 注释);initial_padding=1024(aacenc.c:1739)与 decoder 侧 skip_samples 配对。差异在驱动方向:dec 是语法驱动的自顶向下解析,enc 是 psy→率控→量化的自底向上搜索,所以 enc 多出 psy/aaccoder/率控三大件而 dec 没有。

**为什么 volume 要三精度而不是统一 float?** 嵌入式/老硬件无 FPU 时 fixed 路径(纯整数移位乘加)是必需品;而 u8/s16 的小音量 `_small` 变体(af_volume.c:173-199)展示了最后一层抠门:音量 <1.0 时乘积必然不溢出,可省掉 int64 中间量。

---

## 7. FAQ 素材

1. **volume 的 precision 选项改变什么?** 改变协商的采样格式集合(af_volume.c:135-158),进而决定走整数函数指针还是 fdsp SIMD;不是"同一运算的不同数值精度"。
2. **运行时改音量怎么做?** `volume=...` 命令走 process_command(af_volume.c:307-321);eval=frame 时表达式每帧重估(380-381)。
3. **replaygain 在哪生效?** filter_frame 里逐帧查 AV_FRAME_DATA_REPLAYGAIN side data(af_volume.c:331-370),noclip 用峰值钳制(364)。
4. **pan=1c|c0=1 是混音吗?** 不是——are_gains_pure 判定后走 swr 通道映射,零乘加(af_pan.c:94-114,310-325)。
5. **pan 的 `<` 归一化什么时候做?** config_props 里,因为那时才知道输入布局(af_pan.c:291-293 注释,327-343)。
6. **amix 一路结束后其他路为什么不会突然变响?** scale_norm 斜坡,时长 dropout_transition 默认 2s(af_amix.c:221-228,193-195)。
7. **amix 输出帧尺寸由谁决定?** 第一路输入的帧边界(FrameList),第一路 EOF 后取其余 FIFO 最小水位(af_amix.c:303-328)。
8. **aresample 的 PTS 怎么不漂?** swr_next_pts 补偿滤波器延迟(af_aresample.c:288-295),flush 时传 INT64_MIN(325)。
9. **AAC 每帧固定多少样本?** 1024(aacenc.c:1738),extradata 的 GASpecificConfig 也标 1024(509);率控上限 6144 bit/帧/声道(1517)。
10. **aac_coder 三个选项什么关系?** twoloop/fast/nmr 三套 search_for_quantizers 挂在 ff_aac_coders 派发表(aaccoder.c:827-865),默认 nmr(aacenc.c:1903),后者把立体声判决移到量化前(aacenc.c:1438-1442)。

## 深挖线索

1. **双层率控**:psy 层 bitres.alloc 给目标(aacpsy.c:778-790),enc 层 λ 迭代收敛(aacenc.c:1538-1577),两层之间靠 pcoeffs 快照/回滚(613,1563-1571)保持幂等。
2. **NMR 码型的跨帧反馈环**:立体声候选率 EMA → pair_decoupled → 窗口同步/解耦 → 下帧判决(aacenc.c:990-999 ↔ aacpsy.c:1191-1199),是理解本 commit 行为变化的关键。
3. **psy 的率控重入**:同一帧会因 λ 迭代多次 analyze,状态用 rc_* 快照回滚只推进一次(aacpsy.c:905-925)。
4. **TNS 双门限的来源**:预测增益门与量化后实测门(TNS_PREDGAIN_GATE/c1)是 Apple RE 派生经验,短块门槛 3.2 远高于长块 1.4(aacenc_tns.c:47-51)。
5. **I/S 的两种判决哲学对比**:传统 cost-based(dist2≤dist1,aacenc_is.c:99)vs NMR 的 psy-based 预判决(aacenc.c:867-869 注释)——同一工具、两种架构位置,适合做架构选型讨论。

---

## 写作要点速查表

| 事实 | 位置 |
|---|---|
| volume 精度→格式协商表 | libavfilter/af_volume.c:130-163 |
| volume 三路分派 + x86 钩子 | libavfilter/af_volume.c:211-242 |
| replaygain 换算/去 side data | libavfilter/af_volume.c:331-370 |
| pan 纯增益判定 | libavfilter/af_pan.c:94-114 |
| pan 下沉:swr_set_matrix/映射 | libavfilter/af_pan.c:302-347 |
| amix input_state 二态 | libavfilter/af_amix.c:48-49 |
| amix FIFO 建立(1024 样本) | libavfilter/af_amix.c:264-268 |
| amix 输出帧尺寸/排水逻辑 | libavfilter/af_amix.c:303-328 |
| amix activate 主循环 | libavfilter/af_amix.c:436-515 |
| dropout 斜坡 | libavfilter/af_amix.c:212-241 |
| aresample 读 swr 选项参与协商 | libavfilter/af_aresample.c:66-124 |
| aresample swr_next_pts/延迟 | libavfilter/af_aresample.c:267-295 |
| aformat 三元组协商范本 | libavfilter/af_aformat.c:107-133 |
| AAC extradata(AudioSpecificConfig) | libavcodec/aacenc.c:494-523 |
| 窗函数四型 + MDCT | libavcodec/aacenc.c:539-614 |
| 帧主函数/率控循环 | libavcodec/aacenc.c:1218-1649(loop 1354-1577) |
| init:frame_size=1024/带宽/布局 | libavcodec/aacenc.c:1727-1899 |
| psy 阈值流水线(3GPP) | libavcodec/aacpsy.c:680-913 |
| psy 模型注册/LAME 选块 | libavcodec/aacpsy.c:1162-1219 |
| TNS 搜索/双门限 | libavcodec/aacenc_tns.c:281-453 |
| NMR 立体声预判决 | libavcodec/aacenc.c:843-1000 |
| 码型派发表(默认 nmr) | libavcodec/aaccoder.c:827-865 |
