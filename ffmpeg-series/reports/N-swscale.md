# FFmpeg 源码深读(八):libswscale —— 视频缩放与像素格式转换

> 依据 commit `9f63b36a`(master,libswscale 版本 10.2.100,`libswscale/version.h:31-32`)。
> 本文是《音频管线 swresample》一章的视频对标篇:同样是"格式转换 + 重采样(缩放)"两条主线,但 swscale 的工程复杂度、SIMD 覆盖度和历史包袱都高一个数量级。
> 所有行号均为仓库相对路径,基于本次核对的 commit。

## 1. 全景:一条"按行流式"的四段流水线

swresample 是"样本进、样本出"的五级流水线;swscale 则是**逐输出行驱动**的流水线——每要产出一行输出,就按需把输入行拉进来做水平变换、缓存在环形缓冲里,再做垂直合成写出。两条流水线的共同哲学是:**预计算系数表(上下文建立期一次性算好)+ 运行期零分支查表执行**。

```
                     sws_init_context() 建立期
  ┌─────────────────────────────────────────────────────────────────┐
  │ initFilter(): 算法 → int16 定点系数数组 hLumFilter/vLumFilter...  │
  │ sws_init_swscale(): 按格式/CPU 选好 input/output/hscale/vscale   │
  │ ff_init_filters(): 装配 SwsFilterDescriptor 描述符链 + SwsSlice  │
  └─────────────────────────────────────────────────────────────────┘

                     运行期(ff_swscale(),按 dstY 一行一行推进)
  AVFrame 输入
     │
     ▼  desc[0..lumEnd):输入像素读(input.c 函数,经描述符调度)
  ┌──────────────┐   lum_convert / chr_convert —— 任意源格式 → 内部 YUV/Gray 15/19bit
  │ input 像素读  │   (hscale.c:88 lum_convert, hscale.c:205 chr_convert)
  └──────┬───────┘
         ▼  desc[lumStart..chrEnd):水平滤波
  ┌──────────────┐   lum_h_scale / chr_h_scale —— 查 hLumFilter/hChrFilter 系数表
  │ hscale 水平缩放│   (hscale.c:39 / hscale.c:168),顺带做 range 压缩(lumConvertRange)
  └──────┬───────┘
         ▼  环形行缓冲 SwsSlice(hout_slice,ring=1,slice.c:309)
  │  ……缩放比大时缓冲 vFilterSize+4 行(MAX_LINES_AHEAD,slice.c:266)……
         ▼  desc[vStart..vEnd):垂直滤波 + 像素写
  ┌──────────────┐   packed_vscale / lum_planar_vscale —— 按 vLumFilterPos[dstY] 取行加权
  │ vscale+output│   随即调用 yuv2planeX/yuv2packedX 等 output.c 函数写出目标格式
  └──────┬───────┘   (vscale.c:109 packed_vscale,vscale.c:41 lum_planar_vscale)
         ▼
  AVFrame 输出
```

与 swresample 对照:

| | swresample | swscale |
|---|---|---|
| 内部表示 | 32bit float / int32 样本 | 15bit(8bit 源)或 19bit(深色深源)定点中间行 |
| 缩放核 | 双线性/三次样条重采样系数 | bicubic/lanczos/spline 等 → int16 定点滤波核 |
| 组织方式 | 五级转换链(格式/平面/重排/系数/规格化) | 描述符数组 `c->desc[]`,按 `descIndex[]` 分成 lum/chr/vertical 三段(swscale.c:300-305) |
| 快路径 | memcpy 等价格式直通 | unscaled 特判表 30+ 种组合(swscale_unscaled.c:2392) |
| 线程 | 无内置切片线程 | slice 线程 + 每线程独立上下文(utils.c:1840) |

值得一提的是,这一版 swscale 正处于**双引擎并存**期:上述 legacy 引擎之外,还有一套新的"ops 后端"(`ops.c`/`ops_dispatch.c`,把转换表达为 READ/SWIZZLE/CONVERT/LINEAR 等操作序列,`ops.h:36-75`),由 graph 层(`graph.c`)按需选择(graph.c:727 `prefer_ops_backend`:设 `SWS_UNSTABLE` 或浮点格式时优先 ops,否则默认 legacy)。新 API `sws_scale_frame()` 走 graph(`swscale.c:1405-1480`),legacy API `sws_scale()` 保持原路径(`swscale.c:1626-1643`)。

### 1.1 两代 API 入口对照

同一份上下文,因 `is_legacy_init` 标志(utils.c:1895)而分流到两套运行时:

```
legacy 路径(sws_getContext/sws_init_context 建立):
  sws_scale() swscale.c:1626
    └─ scale_internal() swscale.c:1022
         ├─ gamma / cascaded / unscaled 分流(1076-1082、1163)
         └─ ff_swscale() swscale.c:263(四段流水线主循环)

new 路径(直接 av_opt_set 后 init,未走 legacy init):
  sws_scale_frame() swscale.c:1405
    └─ sws_frame_setup() swscale.c:1500(参数校验+HW 检查)
        └─ ff_sws_graph_run() graph.c(graph 内建 pass 列表)
             ├─ input/rgb0/xyz 预处理 pass(graph.c:308-352)
             ├─ 转换 pass:ops 或 legacy(736 add_convert_pass)
             ├─ 3D LUT / 色调映射 pass(graph.c:760)
             └─ graph worker 并行执行(graph.c:854)
```

交互式逐片输入是 legacy 独有的能力:`sws_frame_start()`(swscale.c:1304)→ 多次 `sws_send_slice()`(1337)→ `sws_receive_slice()`(1361,EAGAIN 语义)→ `sws_frame_end()`(1219);输出切片对齐要求由 `sws_receive_slice_alignment()`(1352)给出。swresample 那章的读者可以把 `sws_send_slice/receive_slice` 理解为视频版"分块进出"——但因为垂直滤波核有跨行视野(vFilterSize),输入必须按整个滤波窗口提前提交,这是音频流式处理(逐样本)与视频行处理(逐窗)的本质差异。

## 2. 上下文建立:sws_init_context 如何把选项变成系数数组

入口链:`sws_getContext()`(utils.c:1922)→ `sws_init_context()`(utils.c:1887)→ 多线程则 `context_init_threaded()`(utils.c:1840),否则 `ff_sws_init_single_context()`(utils.c:1137)。

### 2.1 校验与格式协商

- `handle_jpeg()` 把废弃的 YUVJ 格式改写为普通 YUV 并置 range 标志(utils.c:773,调用点 utils.c:1906-1907)。
- `handle_formats()` 处理 0 号 alpha 通道(`handle_0alpha`)与 XYZ 格式(`handle_xyz`),XYZ 需要填充专用矩阵表 `ff_sws_fill_xyztables()`(utils.c:831-842,表生成在 utils.c:735)。
- 输入/输出格式白名单检查 `sws_isSupportedInput/Output`,查的是 format.c 里的 `legacy_format_entries[]` 位标志表(format.c:50-286,每项 3 个 bit:输入/输出/字节序转换;查询函数 format.c:287-302)。唯一例外:字节序翻转对(如 BE↔LE)可跳过检查(utils.c:1181-1182)。
- 未指定算法时一律默认 `SWS_BICUBIC`(utils.c:1209-1217);同时给了多个算法 flag 则报错(utils.c:1218-1222);`SWS_FAST_BILINEAR` 在宽度过小时自动降级为 bilinear(utils.c:1224-1230)。
- 缩放比用 16.16 定点增量表示:`lumXInc = ((srcW<<16)+dstW/2)/dstW`(utils.c:1253),chroma 同理(utils.c:1431);xInc 超范围直接 `AVERROR_PATCHWELCOME`(utils.c:1452-1456)。
- 色度降采样策略:RGB 输出默认 `chrDstHSubSample=1`(即内部水平只算半宽色度,utils.c:1362-1363),除非强制 `SWS_FULL_CHR_H_INT`(utils.c:1273-1289);RGB 源降采样到 YUV 时若满足条件也把 `chrSrcHSubSample=1`(utils.c:1372-1393,一大串 GBR 格式豁免列表)。
- 源/目标位深决定内部精度:`srcBpc/dstBpc`,8bit 源配 ≤14bit 目标走 15bit 内部,否则 19bit(utils.c:1404-1413);浮点源统一按 16bit 处理(utils.c:1562-1566)。

### 2.2 缩放算法 → 定点系数数组(initFilter)

`initFilter()`(utils.c:197-612)是核心系数生成器。它先在 int64 域用高精度 `fone = 1 << (54 - min(log2(srcW/dstW), 8))`(utils.c:210)算出浮点级系数,最后归一化压到 int16:

1. **按算法定核形状**:未缩放直接置 `filterSize=1`、系数全 fone(utils.c:219-228);`SWS_POINT` 同为 1 tap(utils.c:229);面积平均上采样和 fast bilinear 用 2 tap 线性插值(utils.c:244-267);其余按 `scale_algorithms[]` 表的 size_factor 定窗宽(utils.c:184-194:bicubic=4、bilinear=2、gauss/X=8、sinc/spline=20;Lanczos 可由参数覆盖为 `ceil(2*param)` utils.c:278-279),tap 数 `1 + sizeFactor * srcW/dstW`(下采样时核变宽,utils.c:287-290)。bicubic 的双三次基函数在此以 int64 定点逐项展开(B=(1<<24)、C=0.6*(1<<24),utils.c:312-332);spline/utils.c:371、gauss/utils.c:355、lanczos/utils.c:360 各有其闭式。
2. **裁剪与对齐**:去掉左右近零系数以压缩 `minFilterSize`(utils.c:429-457),再按 SIMD 对齐要求(MMX=4、AltiVec=8、NEON=4、LSX/LASX=8)圆整 filterSize(utils.c:1678-1682,459-488)。
3. **超限走级联**:filterSize 超过 `MAX_FILTER_SIZE`(受 SWS_ACCURATE_RND 影响的 APCK_SIZE 分母,utils.c:492-496)返回 `RETCODE_USE_CASCADE`,上层用几何平均尺寸 `sqrt(srcW*dstW)` 拆成两级上下文(utils.c:1806-1836)。
4. **边界修补与归一化**:filterPos 越界的系数往回搬(utils.c:520-560);然后逐 tap 除以和、用误差扩散法保均值地写入 int16 输出数组(utils.c:568-588)。水平核定点单位是 `one = 1<<14`(utils.c:1686),垂直核是 `1<<12`(utils.c:1716)——这两个 1<<14/1<<12 就是后面 vscale.c 里 `4096` 特判的来源(vscale.c:139-148)。
5. **SIMD 布局重排**:`ff_shuffle_filter_coefficients()`(utils.c:97)把系数重排成 SIMD 交错布局(utils.c:1693、1704);尾部多复制 3 项位置/系数,因为 MMX/SSE 会越界读(utils.c:590-599,注释明说 "the MMX/SSE scaler will read over the end")。

fast bilinear 在 x86 上还有一条极端路径:直接 JIT 生成专用水平缩放机器码——`ff_init_hscaler_mmxext()` 两次调用,`ff_sws_jit_alloc()/ff_sws_jit_protect()` 把缓冲区改成可执行页(utils.c:1646-1674;JIT 封装在 jit.c:40-79,POSIX 用 mprotect、Windows 用 VirtualAlloc)。这就是为什么 `SWS_FAST_BILINEAR` 的系数不进通用数组(utils.c:244-245)。

### 2.3 何时整体级联(cascaded_context)

单上下文搞不定的转换会拆成 2-3 个子上下文串联,运行时由 `scale_cascaded()`(swscale.c:993)/`scale_gamma()`(swscale.c:959)驱动。触发点:

- gamma 校正(sws->gamma_flag):src→RGBA64LE→缩放→RGBA64LE→dst 三段,内部 gamma 表由 `alloc_gamma_tbl(2.2)` 生成(utils.c:1465-1525);
- Bayer 传感器格式:先转 RGB24/RGB48 再转目标(utils.c:1527-1553);
- 带 alpha 混合的"透明抠除":src→alphaless_fmt→dst(utils.c:1568-1608);
- YUV→YUV 但两矩阵不同:经 RGB 中转(utils.c:915-989,在 sws_setColorspaceDetails 里触发);
- 滤波核超长:几何平均中间尺寸(utils.c:1806-1836)。

## 3. unscaled 快路径:尺寸相等时的"格式转换直通车"

判定:srcW==dstW && srcH==dstH(utils.c:1162),且用户没挂额外的预/后置滤波器(`usesHFilter/usesVFilter`,utils.c:1259-1266)、range 匹配或 RGB/浮点(utils.c:1627-1629)。满足则调 `ff_get_unscaled_swscale()`(swscale_unscaled.c:2392-2706)查特判表,命中就把 `c->convert_unscaled` 指向专用整帧转换函数,日志 "using unscaled special converter"(utils.c:1633-1638);运行时 `scale_internal` 直接调它、完全绕开四段流水线(swscale.c:1163-1186)。

特判表按"后命中覆盖先命中"的顺序排列,主要条目:

- 平面↔半平面:YUV420P↔NV12(2408/2418)、YUV444P↔NV24(2413/2423);
- YUV420P→RGB 全家族:`ff_yuv2rgb_get_func_ptr(c)`(2429,要求非 ACCURATE_RND、Bayer 抖动或自动、偶数行);
- 高深色深:P010/P016(2438/2443)、YUV410P→YUV420P(2449)、BGR24→YV12(2457);
- RGB↔RGB 打包族:`rgbToRgbWrapper`(2461、2466,含 AYUV/VUYA 互转);
- 打包↔平面 RGB:GBRP↔GBRAP(2479)、GBRP→RGB24/32(2490/2493)、RGB48/RGBA64→GBRP9-16(2508)、RGB→平面 RGB(2537/2541);
- Bayer→RGB/YUV(2546-2550);
- 字节序翻转 bswap_16bpc/32bpc(2612/2617);调色板类 palToGbrp/palToRgb(2621/2627);
- YUV422P↔YUY2/UYVY(2634/2636/2654/2656)、YUYV↔YUV420/422(2661-2668)、NV24→YUV420(2669);
- 同格式或同构平面拷贝:packedCopyWrapper/planarCopyWrapper(2676-2695,兜底);
- 最后按架构再补特判:PPC/ARM/AARCH64(2699-2705)。

设计动机:同样是"格式转换",unscaled 版本可以逐像素直写、不需要 15/19bit 中间行缓冲,还能让 SIMD 用最紧凑的打包布局(如 yuv2rgb 查表直出 RGB32),比走通用流水线快数倍;这也是 swscale 在 libavfilter 里被 swscale filter 高频调用的场景(缩放为 0 的纯格式转换极常见)。

## 4. 色彩空间:矩阵、表、CMS 三层

### 4.1 经典层:YUV↔RGB 系数表

- 标准矩阵表 `ff_yuv2rgb_coeffs[11][4]`(yuv2rgb.c:47-59),索引即 `SWS_CS_*` 常量(swscale.h:458-465:ITU709=1、FCC=4、ITU601/SMPTE170M/默认=5、SMPTE240M=7、BT2020=9);`sws_getCoefficients()` 越界回退默认(yuv2rgb.c:61-66)。表项是 `crv/cbu/cgu/cgv` 四个 16.16 定点数,注释给出推导公式(yuv2rgb.c:40-45)。
- `sws_setColorspaceDetails()`(utils.c:849-1005):RGB/Gray 目标强制 range=0(utils.c:877-880);变化则重初始化 range 转换(`ff_sws_init_range_convert`,swscale.c:626,把 limited↔full 映射解成 coeff+offset,定点推导在 swscale.c:577-588);YUV→YUV 且矩阵不同时级联经 RGB(utils.c:926);RGB 输出则重建 `c->table_rV/table_gU/table_bU` 查表(`ff_yuv2rgb_c_init_tables`,定义在 yuv2rgb.c:717,表指针存储在 swscale_internal.h:464-465)——yuv2rgb 运行时正是靠 `LOADCHROMA/PUTRGB` 宏 `r[Y]+g[Y]+b[Y]` 三次查表拼出像素(yuv2rgb.c:68-79)。反向(RGB→YUV)用 `fill_rgb2yuv_table()`(utils.c:614,调用点 utils.c:1002)。
- 亮度/色度 limited↔full 范围转换内嵌在流水线里:`lumConvertRange/chrConvertRange` 在水平缩放后逐行应用(hscale.c:61-63),具体函数 swscale.c:163-255,x86/AARCH64 各有 SIMD 版(swscale.c:651-659;x86 版见 x86/swscale.c:469)。

### 4.2 gamma

用户开 `sws->gamma_flag` 后走三段级联,中间夹一个 gamma 描述符:`gamma_convert()` 对 16bit RGB 逐样本查 65536 项表(gamma.c:31-55),表由 `alloc_gamma_tbl(2.2)` 预计算(utils.c:1495-1496),描述符挂在流水线最前端 `ff_init_gamma_convert`(gamma.c:59,装配于 slice.c:325-329)。

### 4.3 新层:CMS(色彩管理)与 3D LUT

`cms.c` 是近年新增的色彩管理模块,围绕 **IPT/ICtCp 类感知空间**做色域映射与色调映射:

- `SwsColorMap` 描述 src/dst 的 primaries+TRC+range+intent(cms.h:60-64);noop 判定 ff_sws_color_map_noop(cms.c:34)。
- 色域数学:primaries→LMS 用 `ff_sws_ipt_rgb2lms`(csputils.c:219,反变换 csputils.c:239),XYZ 转换矩阵 csputils.c:92/130,Bradford 类色适应 `ff_sws_get_adaptation`(csputils.c:191)。
- 四种 intent 的映射函数:perceptual/relative/absolute/saturation(cms.c:520-559),gamut 边界用 ICh 极坐标饱和(cms.c:243,243-273),软裁剪 softclip(cms.c:274)。
- ST.2094 色调映射:knee 点计算 st2094_pick_knee(cms.c:381),setup(cms.c:420)、apply(cms.c:493)。
- 输出接口是生成 3D/2D 查找表:`ff_sws_color_map_generate_static/dynamic`(cms.c:685/690,内部用切片线程并行,cms.c:742 附近)与 `ff_sws_tone_map_generate`(cms.c:749)。
- 集成点在 graph 层:`generate_3dlut()`(graph.c:760)按需在转换链里插一个 `SWS_OP_LUT_3D` pass(graph.c:418 run_legacy_lut3d;ops 类型定义 ops.h:73)。

## 5. SIMD 分发:函数指针 + CPU flag 阶梯

模式与 swresample 一致但规模大得多:**建立期一次性选型,运行期零开销**。中央分发是 `ff_sws_init_scale()`(swscale.c:697):先跑 C 版 `sws_init_swscale()`(swscale.c:662,装默认 input/output/hscale 函数),再按架构调 `ff_sws_init_swscale_x86` 等(swscale.c:703-714)。x86 内部(916 行):

```c
// x86/swscale.c:485
av_cold void ff_sws_init_swscale_x86(SwsInternal *c)
{
    int cpu_flags = av_get_cpu_flags();
    ...
    if (X86_MMXEXT(cpu_flags)) {
        if (!is16BPS(dst_format) && ... && !(c->opts.flags & SWS_BITEXACT)) {
            if (c->opts.flags & SWS_ACCURATE_RND) { ... yuv2rgb32_X_ar_mmxext ... }
            else {
#if HAVE_SSE2_EXTERNAL
                if (EXTERNAL_SSE2(cpu_flags)) {
                    c->use_mmx_vfilter = 1;
                    c->yuv2planeX = yuv2yuvX_sse2;
                    if (EXTERNAL_SSE3(cpu_flags)) c->yuv2planeX = yuv2yuvX_sse3;
                    if (EXTERNAL_AVX2_FAST(cpu_flags)) c->yuv2planeX = yuv2yuvX_avx2;
```
(x86/swscale.c:485-524)

要点:
- 分发按"外部汇编(EXTERNAL_*)/内联汇编(INLINE_*)"与 ISA 阶梯(MMXEXT→SSE2→SSE3→AVX2_FAST)逐级覆盖函数指针,如水平缩放 `ASSIGN_SSE_SCALE_FUNC(c->hyScale, ...)`(x86/swscale.c:637-638)。
- `use_mmx_vfilter=1` 时垂直缩放用专用的 MMX 交错系数布局(vscale.c:152-155 写入 lumMmxFilter),但**最后两行必须回退 C**:MMX 写出会越过数组尾部,swscale.c:523-531 特判重新装函数。这类"边界行退化"是 swscale SIMD 的典型痕迹。
- unscaled 特判表也有各自的架构补丁(swscale_unscaled.c:2699-2705);rgb2rgb 家族集中初始化于 `ff_sws_rgb2rgb_init()`(rgb2rgb.c:127-138,一次 ff_thread_once,utils.c:1901)。
- 输入侧 `ff_sws_init_input_funcs`(input.c:1849)与输出侧 `ff_sws_init_output_funcs`(output.c:3291)按源/目标格式逐 case 挑函数,x86 又在回调里二次覆盖(如 `ff_yuyvToY_sse2`,x86/swscale.c:645)。
- ops 后端的架构分发则是另一套:`ff_sws_op_backends[]` 注册表(ops.c:42-47:backend_c、backend_murder、aarch64、x86、spirv),`ff_sws_ops_compile()` 顺序尝试(ops_dispatch.c:106-126);是否启用由 `ff_sws_enabled_backends()` 决定,AVX2 gather 不慢才放行 x86 ops(utils.c:106)。

## 6. 切片线程模型:slice.c 与逐线程上下文

- 建立期:`sws->threads != 1` 时 `context_init_threaded()` 创建切片线程池,并**为每个线程复制一份完整 SwsContext**(`av_opt_copy` + `ff_sws_init_single_context`,utils.c:1860-1875)——因为流水线里的环形缓冲和 dstY 状态都是可变的。若用户选了误差扩散抖动则退回单线程(误差有跨行依赖,utils.c:1877-1881)。
- 提交/收割 API:`sws_send_slice()` 登记输入行区间(swscale.c:1337-1350),`sws_receive_slice()` 只有在输入完整时才执行,否则返回 EAGAIN(swscale.c:1368-1374);输出切片必须按 `sws_receive_slice_alignment()`(通常 `1<<chrDstVSubSample`,utils.c:1271)对齐(swscale.c:1375-1385)。
- 执行:`sws_receive_slice` 触发 `avpriv_slicethread_execute2`(swscale.c:1387-1392),worker 回调 `ff_sws_slice_worker`(swscale.c:1645-1679)把输出按 `dst_slice_align` 对齐的高度切块,每个线程调用自己的 `slice_ctx[threadnr]` 跑 `scale_internal`,只写自己那一段输出行(swscale.c:1652-1672)。输出行之间无依赖,所以输出切分天然并行;输入则全量可读。
- 与线程无关但同属 slice.c 的,是单线程内的**行级流水线数据结构**:`SwsSlice` 环形行缓冲(alloc_slice ring 参数,slice.c:79-105)、`ff_rotate_slice()` 滑窗推进(slice.c:120-146)、按最大跳变算缓冲行数 `get_min_buffer_size()`(slice.c:217-242),以及描述符装配 `ff_init_filters()`(slice.c:246-380:input desc→hscale desc→gamma 可选→vscale desc)。

## 7. Dither:三种流派

- **有序抖动(Bayer)**:8x8 基表 `ff_dither_8x8_128[9][8]`(swscale.c:42),按输出行号轮换 `c->lumDither8/chrDither8`(swscale.c:519-522),仅对 NBPS/16BPS 源启用(should_dither,swscale.c:291-292);非抖动路径换成常数表 sws_pb_64(swscale.c:385-387)。常用于低 bpp RGB 输出(默认 AUTO 时 bpp<24 且走非 full-chroma 路径就选它,utils.c:1296-1319)。
- **误差扩散(Floyd-Steinberg 式)**:output.c 中 `Y += (7*err + 1*e[i] + 5*e[i+1] + 3*e[i+2] + 8 - 256) >> 4` 的 1:5:3:7 核(output.c:692-710 等),状态存 `c->dither_error[4]`(swscale_internal.h:479,分配于 utils.c:1747-1749);`SWS_BITEXACT` 下每帧清零(swscale.c:1084-1086)。它会破坏线程切分(见上)。
- **算术抖动(a/x dither)**:仅用于 full-chroma 打包输出路径(output.c:2072-2100 的 case 分派),配合 SWS_FULL_CHR_H_INT 使用(utils.c:1302-1310)。

## 8. 设计动机

1. **为什么内部系数固定为 int16(1<<14 / 1<<12)?** 中间行定点化让所有 SIMD 通路(水平 16bit 乘加、垂直累加)共享同一数据布局,8bit 源只损失 1bit 精度而收益是 NEON/SSE 的 8-16 路并行;19bit 通路(dstBpc>14)则换 `int32` 累加避免溢出——两种精度由 `hScale8To15_c / hScale16To19_c` 等函数族显式分开(swscale.c:69-162)。系数生成期用 int64 高精度算完再一次性量化归一(utils.c:568-588),把舍入成本从"每帧每像素"挪到"每上下文一次"。
2. **为什么要 unscaled 特判表?** 格式转换(不缩放)是 swscale 最常见的用途;绕开 15/19bit 中间缓冲后,可直接逐像素读打包数据、调用查表 yuv2rgb,吞吐高一个量级;而 30+ 个条目几乎穷举了高频组合,未命中的仍可回退通用流水线,可靠性由 `convert_unscaled==NULL` 判定保证(utils.c:1633)。
3. **为什么 SIMD 用函数指针表而非运行时分支?** swscale 每行要调用数十次 input/hscale/vscale 函数,函数指针在上下文建立期定死(swscale.c:662-714),内层循环零分支;代价是"每加一个 ISA 阶梯要改三处分发"(C 默认、x86 覆盖、unscaled 补丁),这也是新一代 ops 后端想收敛的问题——把转换拆成可枚举的操作码序列,让编译器/JIT(backend_murder 即 JIT 编译后端,ops.c:35)自动生成内核。
4. **为什么多线程按输出切片切?** 输出行相互独立、输入行只读,切输出即可无锁并行;共享状态(dstY、环形缓冲)全被复制进每线程上下文(utils.c:1860-1875),用内存换无同步。误差扩散这类跨行依赖算法则明确拒绝并行(utils.c:1877-1881)。

## 9. FAQ 素材

1. **为什么 sws_getContext 后还要 sws_init_context?** 前者=alloc_set_opts+后者(utils.c:1929-1938);已有多线程 API 里二者分离,允许先填 `SwsContext` 字段再初始化(swscale.h:421、522)。
2. **sws_scale 报 "Slices start in the middle"?** 非零起点切片必须是首片或末片,中间起始被拒(swscale.c:1096-1100)。
3. **sws_receive_slice 返回 EAGAIN?** 输入行还没通过 sws_send_slice 送满整帧(swscale.c:1368-1374)。
4. **SWS_FAST_BILINEAR 为什么画质差?** 它走 2 tap 线性插值系数(utils.c:244-245)加免归一化的快速通路(hscale_fast_bilinear.c:21-31),并用 JIT 机器码(x86 下 utils.c:1646-1674),精度换速度。
5. **改了 dstFormat 为什么还要管 range?** RGB/Gray 侧 range 被强制为 0(数据本就全量程),仅 YUV 侧参与 limited/full 转换(utils.c:877-880)。
6. **SWS_ACCURATE_RND/SWS_BITEXACT 的代价?** 禁用舍入不同的 SIMD 变体(如 x86/swscale.c:492-495 分支)并压平滤波核(utils.c:512),换取与 C 完全一致的位输出。
7. **为什么 YUV→YUV 同尺寸也走不了 unscaled?** 矩阵不同时需经 RGB 中转级联(utils.c:915-989),矩阵相同时才有 packedCopy/planarCopy 快路径(swscale_unscaled.c:2676-2695)。
8. **调色板格式怎么转换?** 运行期先 `ff_update_palette` 刷新内部 RGB 调色板(swscale.c:1088-1089),pal 指针传进 input 描述符(hscale.c:110)。
9. **XYZ12 是一等公民吗?** 不是:进出都靠 scratch 缓冲整帧预转换 xyz12↔rgb48(swscale.c:1126-1139、1194-1210,矩阵表 utils.c:735)。
10. **同一转换反复建上下文太慢?** 用 `sws_getCachedContext()` 复用并在参数变化时重建(utils.c:2334-2384)。

## 10. 深挖方向

1. **ops 后端全链路**:从 `ff_sws_op_list_generate`(graph.c:710)的操作序列生成,到 `ff_sws_op_list_update_comps` 优化、`compile_backend`(ops_dispatch.c:65)的按后端编译,以及 backend_murder 的 JIT 策略——这是 swscale 的下一代架构,值得单独成篇。
2. **x86 汇编内核选读**:scale.asm/scale_avx2.asm 的水平缩放宏展开与 yuv2yuvX_avx2 的 gather 优化(x86/swscale.c:730-737 对 SLOW_GATHER 的规避),对照 input.asm/output.asm 的打包转换。
3. **cms.c 感知映射数学**:IPT/ICtCp 空间的 gamut 边界求解(cms.c:220-320)与 ST.2094 knee 映射(cms.c:381-520),可对照色彩科学文献精读。
4. **Vulkan 后端**:libswscale/vulkan/ 的 GPU 缩放实现与 graph 层的接入方式(graph.c 中 hw pass 相关代码),对照《硬件后端》一章。
5. **fuzz/一致性测试**:libswscale/tests/ 中 sws-float像素与 bitexact 校验如何覆盖双引擎(legacy vs ops)输出一致性。

## 附:写作要点速查表

| 函数/结构 | 位置 |
|---|---|
| sws_getContext / sws_init_context | libswscale/utils.c:1922 / 1887 |
| 单上下文初始化(协商+装配) | libswscale/utils.c:1137(ff_sws_init_single_context) |
| unscaled 判定与特判入口 | libswscale/utils.c:1162、1627-1640 |
| 系数生成 initFilter(定点核) | libswscale/utils.c:197(fone=210,bicubic=312,归一化=568) |
| scale_algorithms 算法表 | libswscale/utils.c:184-194 |
| 多线程上下文复制 | libswscale/utils.c:1840(context_init_threaded) |
| 滤波系数 SIMD 重排 | libswscale/utils.c:97(ff_shuffle_filter_coefficients) |
| 主循环 ff_swscale | libswscale/swscale.c:263(行循环=412,desc 执行=498-534) |
| scale_internal(总入口) | libswscale/swscale.c:1022(unscaled 调用=1163-1186) |
| sws_scale / sws_scale_frame / slice API | libswscale/swscale.c:1626 / 1405 / 1304-1403 |
| 切片 worker | libswscale/swscale.c:1645(ff_sws_slice_worker) |
| 描述符装配 ff_init_filters | libswscale/slice.c:246(numSlice/numDesc=278-281) |
| 环形缓冲 rotate / min buffer | libswscale/slice.c:120 / 217 |
| 水平描述符(hscale) | libswscale/hscale.c:39、88、146、168、205 |
| 垂直描述符(vscale,4096 特判) | libswscale/vscale.c:109(packed_vscale)、214、258 |
| unscaled 特判表 | libswscale/swscale_unscaled.c:2392-2706 |
| 输入/输出函数分派 | libswscale/input.c:1849 / output.c:3291 |
| YUV↔RGB 系数矩阵表 | libswscale/yuv2rgb.c:47(coeffs)、717(建表)、68-79(查表宏) |
| sws_setColorspaceDetails | libswscale/utils.c:849(YUV→YUV 级联=915) |
| range 转换初始化 | libswscale/swscale.c:626(定点求解=577) |
| gamma 描述符 | libswscale/gamma.c:31、59 |
| CMS 静态/动态 3D LUT | libswscale/cms.c:685、690;intent 函数=520-559 |
| xyz/色适应矩阵 | libswscale/csputils.c:92、191、219 |
| x86 总分发 | libswscale/x86/swscale.c:485(AVX2 yuv2yuvX=513-524) |
| ops 后端注册表/编译 | libswscale/ops.c:42 / ops_dispatch.c:65、106 |
| ops 类型枚举 | libswscale/ops.h:36-75 |
| graph 层 pass 装配/后端选择 | libswscale/graph.c:694、727、736、760 |
| 格式能力位表 | libswscale/format.c:50-286(查询=287-302) |
| Bayer 抖动表 | libswscale/swscale.c:42(应用=519-522) |
| 双精度滤波核生成(ops 用) | libswscale/filters.c:187(ff_sws_filter_generate) |
| fast bilinear JIT 辅助 | libswscale/jit.c:40-79、hscale_fast_bilinear.c |
