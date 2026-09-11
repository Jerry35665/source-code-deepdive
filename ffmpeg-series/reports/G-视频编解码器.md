# 源码深读 · FFmpeg 系列(G):视频编解码器内部 —— H.264 / HEVC / VP9 与多线程

> 仓库:`source-code-deepdive/repos/ffmpeg`(master,commit `9f63b36a`)
> 本文聚焦**框架层**:码流如何被切分、参数如何管理、帧间依赖如何调度、多线程如何并行。不深入具体预测/变换的数学细节。读者假设有 3-5 年后端经验但无视频编解码背景。

---

## ① 全景:视频编解码 = 预测 + 变换 + 熵编码

现代视频编解码器(H.264/HEVC/VP9)的每一帧画面,本质上被压缩成三类信息的组合:

- **预测信息**:这块画面和参考帧(时间域)或本帧相邻块(空间域)差不多,只存"差多少"(残差)以及"怎么参照"(运动矢量/预测模式);
- **变换信息**:残差做类似 FFT 的整数变换(DCT 变体),能量集中到低频,再量化丢弃高频细节;
- **熵编码**:把上面所有语法元素用尽量少的比特表示(H.264 用 CAVLC/CABAC,HEVC/VP9 只用算术编码的变体)。

**解码就是编码的镜像**:熵解码 → 反量化/反变换 → 加上预测值 → 环路滤波(去块效应)→ 输出。三者的组织单位不同:

| 编解码器 | 参数集 | 图像基本单元 | 帧内并行手段 | 熵编码 |
|---|---|---|---|---|
| H.264 | SPS/PPS(独立 NAL) | 宏块 MB(16×16) | slice | CAVLC / CABAC |
| HEVC | VPS/SPS/PPS(独立 NAL) | CTU(最大 64×64) | tile / WPP 波前 | CABAC |
| VP9 | 无,参数在每个帧头里 | 64×64 superblock | tile 列 | bool 算术编码 |

**FFmpeg 中"解码器多、编码器少"的结构性原因**。libavcodec 收录上百个解码器,但 H.264/HEVC 这类主流格式没有原生编码器——`ff_h264_decoder` 定义在 `libavcodec/h264dec.c:1160`,而对应的 H.264 编码是转调外部库的封装 `libavcodec/libx264.c`、`libx265.c`(目录中实际存在这两个文件)。原因有三层:

1. **复杂度不对称**:解码器是"按规范执行"的确定性状态机,规范把每一步都定死了;编码器要在指数级的编码模式空间里做率失真优化(RDO),x264 花了十几年调优才达到质量/速度平衡,FFmpeg 社区没必要重复造轮子,封装成熟库是理性选择。
2. **判决自由度**:解码端任何自由发挥都会导致不兼容;编码端的全部价值恰恰在于自由发挥(怎么选模式、怎么分配码率),这部分是经验工程而非规范实现。
3. **生态分工**:解码是播放的基础设施,必须人人都有;编码市场早已被 x264/x265/libvpx/aom 占据。

所以读 FFmpeg 的视频编解码代码,读的主要是**解码器框架**,这也是本文的主线。

---

## ② H.264:NAL → slice → DPB 逐段解读

### 2.1 码流分层与 NAL 切分

H.264 码流由 NAL(Network Abstraction Layer)单元组成。裸流(Annex B 格式)用起始码 `00 00 01` 分隔;MP4 等容器(nalff 格式)用长度前缀。两种格式统一由 `ff_h2645_packet_split()` 处理(`libavcodec/h2645_parse.c:527`):nalff 时按长度读取(`h2645_parse.c:549-558`),否则 `find_next_start_code()` 扫起始码(`h2645_parse.c:565-568`)。

切出的 NAL 里可能含有"防竞争字节" `03`(编码器为避免载荷里意外出现起始码而插入的 `00 00 03`),`ff_h2645_extract_rbsp()` 负责剥掉它们(`h2645_parse.c:37`),转义处理在 `h2645_parse.c:108-131`。值得一提的是这里有个技巧性很强的 64 位扫描:一次检查 8 字节里是否存在零字节(`h2645_parse.c:60-68` 的位运算魔法),把最常见的"没有零"的情形用一条比较处理掉。

NAL 头只有 1 字节:`h264_parse_nal_header()` 读 1 位 forbidden_zero、2 位 nal_ref_idc(参考优先级)、5 位类型(`h2645_parse.c:448-463`)。类型表见 `h2645_parse.c:307-340`:1=非 IDR slice、5=IDR slice、7=SPS、8=PPS。注意同一个 `ff_h2645_packet_split()` 还服务 HEVC(6 位类型 + layer id + temporal id,`h2645_parse.c:427-446`)和 VVC——按 `codec_id` 分派不同头部解析器(`h2645_parse.c:644-653`),这是 FFmpeg 代码复用的典型做法。

### 2.2 参数集:SPS / PPS

SPS(序列参数集)描述整段视频的静态属性(分辨率、色度格式、POC 计算方式),PPS(图像参数集)描述常用编码参数(CABAC 开关、QP 初值、slice 数量上限等)。解码器把它们缓存在 `h->ps` 的哈希表中,按 id 引用:`h264_slice_header_parse()` 里每个 slice 头携带 `pps_id`,回查 `h->ps.pps_list[sl->pps_id]`,再由 PPS 间接拿到 SPS(`libavcodec/h264_slice.c:1755-1767`)。找不到就报 "non-existing PPS referenced"(`h264_slice.c:1760-1765`)——这是实战中常见的码流开头缺参数集错误。

容器内的参数集 extradata(avcC)在初始化时单独解析:`ff_h264_decode_extradata()` 通过 `data[0]==1` 识别 avcC 格式,并取出 `nal_length_size`(`libavcodec/h264_parse.c:466-524`,长度字段在 `h264_parse.c:516`)。甚至在每帧解码时还支持通过 side data 热更新 extradata(`libavcodec/h264dec.c:1089-1095`)。

### 2.3 一次解码调用的流程

入口 `h264_decode_frame()`(`libavcodec/h264dec.c:1070`),核心在 `decode_nal_units()`(`h264dec.c:605`):

```c
// libavcodec/h264dec.c:632-641(节选)
ret = ff_h2645_packet_split(&h->pkt, buf, buf_size, avctx, h->nal_length_size,
                            avctx->codec_id, !!h->is_avc * H2645_FLAG_IS_NALFF);
...
if (avctx->active_thread_type & FF_THREAD_FRAME)
    nals_needed = get_last_needed_nal(h);
```

`get_last_needed_nal()`(`h264dec.c:501-553`)是帧线程化的关键前置:在真正解码前先把整个包轻量扫一遍,找出"最后一个会影响本帧的 NAL"位置。注释解释了原因:一个包里可能混着多组 SPS/PPS 或两个场的 slice,帧线程必须等这些读完了才能放行下一个线程(`h264dec.c:513-516`)。这就是帧级多线程"两遍扫描"的第一遍。

随后逐 NAL 分派(`h264dec.c:645-797`):IDR 先清空参考队列(`idr()`,`h264dec.c:438-448`,调用点 `h264dec.c:667-670`);SPS/PPS 走参数集解析(`h264dec.c:750-779`);VCL slice 调 `ff_h264_queue_decode_slice()` 入队(`h264dec.c:697`),队列满或包结束时统一执行 `ff_h264_execute_decode_slices()`(`h264dec.c:719-728`、`h264dec.c:799`)。

### 2.4 slice 头解析

每个 slice 自带完整定位信息,`h264_slice_header_parse()`(`h264_slice.c:1716`)依次读出:

- `first_mb_addr`:本 slice 从第几个宏块开始(`h264_slice.c:1730`)——slice 就是"一帧内一段连续宏块",这是 H.264 唯一的帧内并行单位;
- `slice_type`:I/P/B,大于 4 表示"后续 slice 同类型"(`h264_slice.c:1732-1747`);
- `frame_num` / POC 相关字段:播放顺序的依据(`h264_slice.c:1769`、`1816-1829`);
- 参考帧数量与重排序指令(`h264_slice.c:1838-1850`);
- 加权预测参数表 `ff_h264_pred_weight_table()`(`libavcodec/h264_parse.c:30`);
- QP、deblocking 参数(`h264_slice.c:1884-1915`)。

POC(Picture Order Count)是解码顺序≠显示顺序的根源:B 帧要等后面的帧解出来才能输出。`ff_h264_init_poc()` 按 SPS 的 `poc_type` 三种公式计算(`libavcodec/h264_parse.c:280-365`)。输出端 `send_next_delayed_frame()` 就是在 delayed 队列里挑 POC 最小且可安全输出的帧(`libavcodec/h264dec.c:1038-1049`)。

### 2.5 宏块解码循环与 DPB

多 slice 时 `ff_h264_execute_decode_slices()` 先计算每个 slice 的 `next_slice_idx`(下一个 slice 的起始宏块序号),用于运行时检测 slice 重叠(`h264_slice.c:2902-2919`),再经 `avctx->execute()` 把每个 slice 派给一个工作线程(`h264_slice.c:2921-2922`);单 slice 时直接内联调用(`h264_slice.c:2891-2899`)。

`decode_slice()`(`h264_slice.c:2664`)是真正的逐宏块循环,CABAC 分支如下:

```c
// libavcodec/h264_slice.c:2699-2722(节选)
if (h->ps.pps->cabac) {
    align_get_bits(&sl->gb);
    ret = ff_init_cabac_decoder(&sl->cabac,
                          sl->gb.buffer + get_bits_count(&sl->gb) / 8,
                          (get_bits_left(&sl->gb) + 7) / 8);
    ...
    for (;;) {
        ...
        ret = ff_h264_decode_mb_cabac(h, sl);   // 解析一个宏块语法
        if (ret >= 0)
            ff_h264_hl_decode_mb(h, sl);        // 重建像素
        eos = get_cabac_terminate(&sl->cabac);  // end_of_slice_flag
```

每解一个宏块,先熵解码语法(`ff_h264_decode_mb_cabac`,`libavcodec/h264_cabac.c:1920`),再重建像素(`ff_h264_hl_decode_mb`),一行走完做环路滤波(`loop_filter`,`h264_slice.c:2760`)。CABAC 的 `end_of_slice_flag` 或到达帧尾则结束(`h264_slice.c:2737`、`2771-2779`)。

**DPB(Decoded Picture Buffer)**是解码器的"帧缓存池"。`H264Context` 固定携带 36 个 `H264Picture` 槽位(`H264_MAX_PICTURE_COUNT=36`,`libavcodec/h264dec.h:47`,数组在 `h264dec.h:355`)。每帧开始时 `h264_frame_start()` 从中 `find_unused_picture()` 找空闲槽(`h264_slice.c:497-502`)并分配像素内存(`h264_slice.c:531`)。解码完成后,参考帧按 H.264 的滑动窗口/MMCO 规则挂入 `h->short_ref`(短期,按 frame_num 排序)或 `h->long_ref`(长期);P/B slice 解码时从这些队列构建参考列表:`h264_initialise_ref_list()` 对 B 帧按 POC 双向排序(`libavcodec/h264_refs.c:133-159`,排序核心 `add_sorted()` 在 `h264_refs.c:103-123`),再拼上长期参考(`build_def_list()`,`h264_refs.c:77-101`)。IDR 帧强制清空全部参考(`h264dec.c:438-448` 的 `idr()`),这也是"从 IDR 开始才能干净起播"的原因。

### 2.6 解码全流程图

```
AVPacket ──► h264_decode_frame (h264dec.c:1070)
                │
                ▼
        decode_nal_units (h264dec.c:605)
                │
     ┌──────────┴───────────────────────────────┐
     ▼                                          ▼
ff_h2645_packet_split                    get_last_needed_nal
 (起始码/长度前缀切分,                     (帧线程前瞻,只定位
  剥离 0x03 转义)                           不解码, h264dec.c:501)
     │
     ▼  逐 NAL 分派 (h264dec.c:645)
 ┌───────────────────────────────────────────────┐
 │ SPS/PPS ──► 参数集哈希表 h->ps                │
 │ IDR     ──► idr(): 清空 short_ref/long_ref    │
 │ slice   ──► ff_h264_queue_decode_slice        │
 │              ├─ h264_slice_header_parse       │
 │              ├─ 新帧? h264_field_start        │
 │              │    └─ h264_frame_start:        │
 │              │       DPB 空槽 → alloc_picture │
 │              └─ 入队 slice_ctx[nb_queued++]   │
 └───────────────────────────────────────────────┘
                │  队列满 / 包结束
                ▼
   ff_h264_execute_decode_slices (h264_slice.c:2876)
                │
      ┌─────────┼─────────┐  avctx->execute (slice 线程)
      ▼         ▼         ▼
  decode_slice × N (每 slice 一个上下文)
      │  逐宏块: CABAC 解码 → 重建 → 环路滤波
      ▼
   ff_h264_field_end (h264dec.c:1122)
                │  POC 排序 + 参考管理
                ▼
      finalize_frame → 输出 AVFrame (h264dec.c:1126-1130)
```

---

## ③ 帧级 / 片级多线程模型

FFmpeg 支持三种线程模型:`THREAD_FRAME`(帧级)、`THREAD_SLICE`(片级)、`THREAD_AUTO`。解码器通过 capability 声明支持哪些(H.264 两者都支持,`h264dec.c:1169-1171`)。`doc/multithreading.txt` 是官方设计文档,pthread_frame.c 和 pthread_slice.c 的头注释都指向它(`pthread_frame.c:22`、`pthread_slice.c:22`)。

### 3.1 帧级多线程:每线程一份 AVCodecContext

设计(`libavcodec/pthread_frame.c`):主线程持有 `FrameThreadContext`,管理 N 个 `PerThreadContext`,**每个工作线程拥有独立的 AVCodecContext 副本和独立的解码器私有数据**(`pthread_frame.c:78-115`;副本创建于 `init_thread()` 的 `av_memdup(avctx,...)` 与 `av_mallocz(codec->priv_data_size)`,`pthread_frame.c:820`、`843-845`)。包在线程间轮转分发(`submit_packet()` 末尾 `next_decoding = (next_decoding+1) % thread_count`,`pthread_frame.c:550`)。

帧与帧之间的解码顺序依赖,由编解码器实现的 `update_thread_context(dst, src)` 回调弥补:提交第 N+1 个包前,把第 N 个线程已解析出的状态(参数集、参考队列、POC)同步给下一个线程(`update_context_from_thread()`,`pthread_frame.c:343-452`;调用点 `submit_packet()` 内 `pthread_frame.c:529`)。H.264 的实现是暴力但正确的整表搬运:`ff_h264_update_thread_context()` 复制 SPS/PPS 引用、DPB 全部 36 槽、short_ref/long_ref/delayed_pic 数组乃至 mmco 标记(`libavcodec/h264_slice.c:338-469`,参考队列表拷贝在 `h264_slice.c:441-444`)。

**进度协调是第二个关键机制**。帧 N+1 解码时可能要参考帧 N,而帧 N 可能还没解完。每个画面携带原子进度计数,解码器在需要参考像素前 `ff_thread_await_progress()`,解到某行后 `ff_thread_report_progress()`(`pthread_frame.c:621-663`)。为减少等待,解码器应尽早调用 `ff_thread_finish_setup()` 声明"设置阶段结束,后续只读已就绪数据"(`pthread_frame.c:665-708`);H.264 在第一个 slice 头解析完就调用(`h264dec.c:706-711`)。

线程主循环 `frame_worker_thread()`(`pthread_frame.c:241-333`)的骨架:

```c
// libavcodec/pthread_frame.c:250-259(节选)
while (1) {
    while (atomic_load(&p->state) == STATE_INPUT_READY && !p->die)
        pthread_cond_wait(&p->input_cond, &p->mutex);   // 等待派包
    if (p->die) break;
    if (!codec->update_thread_context)
        ff_thread_finish_setup(avctx);                  // 无状态回调的编解码器
    ...
    while (ret >= 0) {                                  // 尽量排空输入
        ret = ff_decode_receive_frame_internal(avctx, frame);
    }
```

三个状态(`STATE_INPUT_READY / SETTING_UP / SETUP_FINISHED`,`pthread_frame.c:50-57`)构成一台小状态机:主线程提交包时置 SETTING_UP 并 `signal input_cond`(`pthread_frame.c:545-546`);worker 完成后回置 INPUT_READY 并 `signal output_cond`(`pthread_frame.c:324-327`)。注意主线程提交第 N+1 包前会**同步等待第 N 个线程离开 SETTING_UP 状态**(`submit_packet()`,`pthread_frame.c:516-522`)——因为 update_thread_context 必须读到一致的状态,这是流水线启动的节拍器。

用户视角 API 是"取帧"驱动:`ff_thread_receive_frame()` 在没有缓存结果时不断向线程池提交包,直到轮到 `next_finished` 指向的线程产出(`pthread_frame.c:555-619`);代价是帧级多线程天然引入 `thread_count-1` 帧延迟(`ff_frame_thread_init()`,`pthread_frame.c:947-948`)。线程数默认 `min(cpu+1, MAX_AUTO_THREADS=16)`(`pthread_frame.c:916-923`;`MAX_AUTO_THREADS` 定义于 `libavcodec/pthread_internal.h:26`)。

### 3.2 片级多线程:一帧拆多片

`libavcodec/pthread_slice.c` 只有 154 行,是一个通用"任务池":初始化时创建线程并安装两个回调指针 `avctx->execute / avctx->execute2`(`pthread_slice.c:151-152`)。编解码器把一帧的工作切成 N 个 job 调用 `avctx->execute2(avctx, func, arg, ret, job_count)`,内部 `worker_func()` 按 `jobnr/threadnr` 分派(`pthread_slice.c:58-70`);未启用 slice 线程时退化为串行循环(`pthread_slice.c:85-87`)。

H.264 的用法:`ff_h264_execute_decode_slices()` 把每个 slice 作为 job 提交(`h264_slice.c:2921-2922`)。因为 slice 之间只在帧级别有依赖(同一帧内后续 slice 的解码不读前面 slice 的像素结果,除了环路滤波),线程数可从 slice 数获得。代价是:错误恢复与 slice 线程不兼容——FFmpeg 直接警告"unsafe and unsupported"(`h264dec.c:426-430`)。HEVC 的 slice 线程则进一步用于 WPP(见④)。VP9 更激进,直接用 `ff_slice_thread_execute_with_mainfunc()` 提交 tile 列,主函数回调 `loopfilter_proc` 由其中一个线程承担(`vp9.c:1805`;`FF_CODEC_CAP_SLICE_THREAD_HAS_MF` 标志,`vp9.c:1951`;机制在 `pthread_slice.c:107-113`)。

### 3.3 并行结构图

```
帧级(THREAD_FRAME)—— 线程间是流水线,延迟 N-1 帧:
 主线程:  pkt0──►pkt1──►pkt2──►pkt3──►(按提交顺序收帧)
            │      │      │      │
         submit_packet: 复制用户选项 + update_thread_context(prev→cur)
            ▼      ▼      ▼      ▼
 worker0: [解码帧0────────]──► 输出
 worker1:        [解码帧1────────]──► 输出     ← 每线程独立
 worker2:               [解码帧2───────]──►     AVCodecContext+DPB
            ▲
            └── 帧间依赖: ff_thread_await_progress(参考帧行进度)
                (pthread_frame.c:644-663)

 片级(THREAD_SLICE)—— 同一帧内,扇出-汇合,零额外延迟:
 主线程: 解析所有 slice 头 → execute2(decode_slice, N jobs)
            ├────────────┬────────────┐
            ▼            ▼            ▼
        slice0 MBA行  slice1 MBA行  slice2 MBA行   (并行)
            │            │            │
            └────────────┴────────────┘
                         ▼
              帧尾: field_end + 环路滤波收尾
```

帧级收益:对无 slice 的主流(绝大多数)也能并行;片级收益:单帧延迟低、内存只有一份解码上下文,但依赖码流里有 slice/tile。两者可叠加声明,`avctx->active_thread_type` 决定实际生效哪一种。

---

## ④ HEVC 与 H.264 的框架差异

HEVC 解码器在 `libavcodec/hevc/hevcdec.c`(4311 行)。NAL 层与 H.264 共享同一套 `ff_h2645_packet_split()`,只是头部变成 2 字节:6 位类型、6 位 layer id、3 位 temporal id(`h2645_parse.c:427-446`)。类型表扩充到 64 项(`h2645_parse.c:234-299`),增加了 CRA/BLA 等随机访问点。

框架层的核心差异:

1. **CTU 取代宏块,且解析顺序由 PPS 驱动**。H.264 的 slice 内宏块严格光栅顺序;HEVC 的 CTU 扫描顺序(`ctb_addr_rs_to_ts`)是 PPS 里可配的(tiles/scan 方案),所以解码循环从"mb_x/mb_y 递增"变成"时间序地址表迭代":`hls_decode_entry()` 沿 `ctb_addr_ts` 前进,经 `pps->ctb_addr_ts_to_rs[]` 反算物理位置(`hevcdec.c:2768-2775`),每个 CTU 内部 `hls_coding_quadtree()` 按四叉树递归划分(`hevcdec.c:2791`)。

2. **tile 与 WPP 成为码流内建并行**。H.264 的 slice 是唯一帧内并行单位且熵编码后无法并行(CABAC 状态连续);HEVC 吸取教训:tile 把画面切成矩形区,每个 tile 独立熵编码;WPP(Wavefront Parallel Processing)让每个 CTU 行使用独立的 CABAC 引擎,行 N+2 只需等行 N 解完第二列即可启动——并行粒度细到一行。FFmpeg 的实现:每个 entry point 对应一个 CTU 行,`hls_slice_data_wpp()` 按 entry point 偏移切出独立的字节区间并初始化独立的 range decoder(`hevcdec.c:2931-3029`,偏移表构建在 `hevcdec.c:2975-3002`);行线程间用 `ff_thread_progress_await/report` 同步相邻行(`hls_decode_entry_wpp()`,`hevcdec.c:2840-2842`、`2872`)。调度条件是"slice 线程开启 + 有 entry point + 单 tile"(`hevcdec.c:3079-3082`)——tile 模式下则由 tile 边界自然隔离。

3. **参考帧管理改为标志位 DPB**。H.264 用 short_ref/long_ref 两条数组;HEVC 的 `HEVCFrame` 带 `HEVC_FRAME_FLAG_OUTPUT | SHORT_REF | LONG_REF` 位标志(`ff_hevc_set_new_ref()`,`libavcodec/hevc/refs.c:239-246`),DPB 上限 16(`HEVC_MAX_DPB_SIZE`,`libavcodec/hevc/hevc.h:120`)。输出策略集中在一个循环里:当输出待定数超限或 DPB 压力过大,选 POC 最小的帧输出(`ff_hevc_output_frames()`,`refs.c:267-325`)。

4. **slice 段(segment)与依赖 slice**。HEVC 允许 dependent_slice_segment 继承前一个 slice 的头(`decode_slice_data()` 校验前段存在性,`hevcdec.c:3062-3069`),头开销更低。

5. **上下文副本是"每线程 local_ctx"而非"每线程解码器"**。slice 线程下 HEVC 不复制整个解码器,只为每个线程分配轻量 `HEVCLocalContext`(CABAC 状态、邻居缓存),不足时按 `thread_count` 动态扩容(`hevcdec.c:2950-2970`)。

6. **帧线程状态迁移面更小**。H.264 的 update_thread_context 要搬 DPB、参考队列;HEVC 复用 `FF_CODEC_CAP_USES_PROGRESSFRAMES` 的进度框架并以 refstruct 引用交换参数集,decoder 声明见 `hevcdec.c:4269-4276`(SLICE+FRAME 双支持)。同时 HEVC 是新 API 的先行者:`hevc_receive_frame()` 基于 receive_frame 回调(`hevcdec.c:4272`),而 H.264 还在用旧式 decode 回调(`h264dec.c:1168`)。

一句话总结:**H.264 的框架并行单位是"slice/帧",HEVC 把并行性做进了码流语义(tile/WPP/entry point),解码器退化为调度器**。

---

## ⑤ VP9:self-describing 的异类

VP9(`libavcodec/vp9.c`)是三者的架构异类,它没有 SPS/PPS:

1. **每个帧头自带全部参数**。`decode_frame_header()` 从帧第一个比特开始读:2 位 frame marker(`vp9.c:543`)、profile(`vp9.c:547-554`)、show_existing_frame 位——为 1 时后续 3 位就是参考帧索引,直接把旧帧引用出来输出,连解码都不用(`vp9.c:555-558`;解码路径 `vp9_decode_frame()` 里 `ret==0` 分支,`vp9.c:1636-1654`)。关键帧还要 24 位同步码 + 色彩信息 + 宽高(16 位+1,`vp9.c:569-578`);非关键帧可以完全继承参考帧的分辨率(三个 1 位开关,`vp9.c:620-632`)。头解析完记录 `uncompressed_header_size`(`vp9.c:906`)——uncompressed header 之后全是算术编码数据,这名字就是"self-describing"的直接体现。缺点是**丢一个包可能丢掉后续所有帧需要的参数**,收益是**帧级封装极简、点播/直播切流零参数集管理**。

2. **superframe index:一个包多帧**。VP9 允许把多个帧打包进一个 packet,最后一字节是索引:`(hdr & 0xe0)==0xc0` 判定为 superframe,低 3 位是帧数-1,接着 2 位编码每帧长度的字节数(`libavcodec/cbs_vp9.c:375-384`)。切分逻辑在 `cbs_vp9_split_fragment()`(`cbs_vp9.c:364-433`):解析索引、按 `frame_sizes[]` 依次切出子帧。因为索引在包尾,一般的流式解析器很难自动处理,所以 VP9 解码器直接声明内置 bsf:`.bsfs = "vp9_superframe_split"`(`vp9.c:1959`),让解码管线自动插入拆包过滤器。

3. **参考帧是固定 8 槽数组**。不像 H.264/HEVC 动态管理 DPB 输出顺序,VP9 每帧用 `refreshrefmask`(8 位)声明刷新哪几个槽(`vp9.c:601`、`1691-1695`),invisible 帧(例如 alt-ref 前向参考帧)解完不输出(`vp9.c:1846-1850`)。这继承了 VP8/WebM 的简单哲学:编码器自己决定缓冲策略,解码器无 POC 重排序逻辑。

4. **并行 = tile 列**。tile 列数由码流宽度自动推导上下限(`vp9.c:805-810`),slice 线程模式下 `active_tile_cols = tile_cols`、否则为 1(`vp9.c:829-830`);每列独立的 range decoder,末列尺寸=剩余字节,其他列前缀 4 字节长度(`vp9.c:1318-1325`、`1789-1792`)。tile 内解码循环还区分 pass:帧线程+非 parallelmode 时概率自适应需要先跑一遍统计(probs)再重放,`vp9_decode_frame()` 用 `do {...} while (s->pass++ == 1)` 两遍执行(`vp9.c:1824`、`1730-1731`)。

5. **帧头解析交给 CBS**。本仓库的 VP9 已迁移到 cbs_vp9 做(uncompressed)帧头的规范化读写(`vp9_decode_frame()` 里 `ff_cbs_read_packet()`,`vp9.c:1620-1625`),原生 H.264/HEVC 则仍用自己的参数集缓存。这是一次"码流描述从手写 get_bits 迁移到声明式 CBS"的渐进重构样本。

---

## ⑥ CABAC 与指数哥伦布:两个熵编码原语

### 6.1 指数哥伦布(Exp-Golomb)

H.264 的 SPS/PPS/slice 头全部用 Exp-Golomb 编码:值 k 编码为 `前导零 × log2(k+1) 个信息位`,如 0→`1`,1→`010`,2→`011`,3→`00100`。无预置表、任意大数值都可行,非常适合参数这种"多数很小、偶尔很大"的分布。

`libavcodec/golomb.h` 的实现有两条路径(`get_ue_golomb()`,`golomb.h:53-99`):快路径一次看 32 位,若前 5 位非零(值 ≤8190)直接查 512 项表得长度和码值(`golomb.h:81-87`);慢路径用 `2*av_log2(buf)-31` 定位前导零个数再移位提取(`golomb.h:88-97`)。任意大值走 `get_ue_golomb_long()`:前导零个数 log 直接由 `31 - av_log2(buf)` 给出,跳过后读 log+1 位减 1(`golomb.h:104-113`)。有符号版本 `get_se_golomb()` 只是加了 zigzag 映射(偶数正、奇数负,`golomb.h:285-289` 与 `golomb.h:294-299`)。对无视频编解码背景的工程师,可以把它理解成"变长整数 varint 的位级表亲":protobuf varint 用连续位,Exp-Golomb 用前导零计数。

### 6.2 CABAC

CABAC(Context-Adaptive Binary Arithmetic Coding)是 H.264 主 profile、HEVC、以及 VP9 bool coder 的共同祖先思路:**逐比特算术编码 + 概率状态机**。与哥伦布不同,它没有"码字"概念——每个二判决(比特)按当前概率模型把区间 [low, low+range) 划分一次,概率模型本身随判决结果自适应。

FFmpeg 的实现分两层。底层 `libavcodec/cabac.c` 只有 187 行,核心是三张预计算表(`ff_h264_cabac_tables`,`cabac.c:32-156`):64 组 LPS(低概率符号)区间值、状态转移表 `mlps_state`、8x8 块的 last_coeff_flag 偏移。初始化 `ff_init_cabac_decoder()` 读入前两字节作为 low 初值,range 固定起点 `0x1FE`(`cabac.c:162-187`)。

单比特判决 `get_cabac_inline()`(`libavcodec/cabac_functions.h:116-137`)是全解码器最热的代码之一:

```c
// libavcodec/cabac_functions.h:116-137(节选)
static av_always_inline int get_cabac_inline(CABACContext *c, uint8_t * const state){
    int s = *state;
    int RangeLPS = ff_h264_lps_range[2*(c->range&0xC0) + s];
    c->range -= RangeLPS;
    lps_mask = ((c->range<<(CABAC_BITS+1)) - c->low) >> 31;  // 符号位: 走MPS还是LPS
    c->low  -= (c->range<<(CABAC_BITS+1)) & lps_mask;
    c->range += (RangeLPS - c->range) & lps_mask;            // 无分支重命名区间
    s ^= lps_mask;
    *state = (ff_h264_mlps_state+128)[s];                    // 状态机一步转移
    lps_mask = ff_h264_norm_shift[c->range];                 // 归一化(重整)
    c->range <<= lps_mask;
    c->low   <<= lps_mask;
    if (!(c->low & CABAC_MASK))
        refill2(c);                                          // 补充输入比特
    return s & 1;
}
```

读懂这段的钥匙:`lps_mask` 是全 0/全 1 掩码,把 if/else 压成位运算(无分支对现代 CPU 的预测器友好);概率模型被离散成 64 个状态存 1 字节 `state`,判决后查表转移(`cabac.c:118-150` 的 `mlps_state` 表,含 MPS/LPS 翻转);"上下文自适应"就体现在**语法元素各持一份 state**,历史相关即隐含其中。上层 `libavcodec/h264_cabac.c`(2499 行)把每个宏块的几百个二判决串起来(`ff_h264_decode_mb_cabac`,`h264_cabac.c:1920`),每个语法元素一个 context 索引——H.264/HEVC 解码慢,主要就慢在这每比特几纳秒的乘数效应上。这也是为什么 CABAC 码流无法随机访问、WPP 才需要为每行维护独立引擎。

---

## ⑦ 设计动机与取舍

1. **两遍扫描换流水线安全**(帧线程):`get_last_needed_nal()` 的存在说明一个通用原则——当工作单元之间有"设置阶段/执行阶段"之分时,先廉价前瞻读完所有设置信息,才能让下一单元提前开工。代价是每包多一次轻量扫描,收益是流水线不被参数更新打断。

2. **复制上下文而非共享上下文**(帧线程):每线程一份 AVCodecContext + 解码器私有数据,牺牲 N 倍解码器状态内存(每个 H.264 线程都有自己的 36 槽 DPB 引用),换来零锁的解码热路径;共享只发生在三处:`buffer_mutex` 保护的帧缓冲分配(`pthread_frame.c:1029-1033`)、进度原子量、以及 update_thread_context 时点上的显式状态移交。典型的"以空间换无锁"。

3. **并行性内建到码流**(HEVC/VP9):H.264 时代硬件解码器只能靠帧间并行;HEVC 的 tile/WPP、VP9 的 tile 是标准制定者直接把并行协议化。软件上 FFmpeg 对应两套调度:HEVC 用 entry point 表 + 行进度同步,VP9 用 slice 线程池 + 主函数回调。代价是码流冗余(每个 entry point 要存字节偏移)、以及行间等待引入的吞吐上限。

4. **VP9 放弃参数集是故意简化**:self-describing 帧头让解码器无跨帧参数状态(概率上下文除外),播放器/裁剪/转封装都更鲁棒;但码率上每帧多付几十字节,且丢帧传播风险更高。工程上"参数跟着帧走"和"参数集中声明"是流式系统永恒的权衡,视频码流只是它的又一个实例。

5. **无分支位运算贯穿始终**:从 `ff_h2645_extract_rbsp` 的 64 位零扫描(`h2645_parse.c:60-68`)到 `get_cabac_inline` 的掩码判决,热路径普遍消除了数据依赖分支。对后端工程师的启示:在每帧运行数十万次的内层循环里,可预测性比可读性重要——但 FFmpeg 把这种代码严格限制在最内层,外层结构依旧清晰。

6. **旧 API 与新 API 并存**:H.264/VP9 用旧 `decode` 回调(`h264dec.c:1168`、`vp9.c:1950`),HEVC 已迁到 `receive_frame`(`hevcdec.c:4272`)。框架允许渐进迁移,而不是一次性大爆炸重构——大型 C 项目存续的关键纪律。

---

## ⑧ FAQ

**Q1:为什么从任意位置起播必须等 IDR?**
IDR 会清空 DPB 与参考队列(`idr()`,`h264dec.c:438-448`),之后所有 slice 都不引用 IDR 之前的帧。非 IDR 帧的参考列表由 `h->short_ref/long_ref` 构建(`h264_refs.c:133-159`),缺历史帧只能靠丢失隐藏(灰色帧/错误恢复)。

**Q2:为什么 H.264 解码有延迟、输出顺序和送入顺序不一致?**
B 帧按 POC 重排序输出。解码顺序由码流给定,显示顺序由 POC 决定(`ff_h264_init_poc()`,`h264_parse.c:280`);delayed 队列挑最小 POC 输出(`h264dec.c:1038-1049`)。帧线程模式还会额外加 `thread_count-1` 帧流水线延迟(`pthread_frame.c:947-948`)。

**Q3:AVCodecContext 的 thread_count=0 是什么意思?**
自动探测:`min(cpu数+1, 16)`(帧线程 `pthread_frame.c:916-923`,slice 线程 `pthread_slice.c:121-129`,后者还会按 `height/16` 封顶——没有那么多宏块行时slice 并行无意义)。

**Q4:帧级和片级多线程能同时用吗?**
一次解码只能选一种生效(active_thread_type),但解码器可以两者都声明支持(H.264/HEVC/VP9 均同时声明 `AV_CODEC_CAP_SLICE_THREADS | AV_CODEC_CAP_FRAME_THREADS`,`h264dec.c:1169-1171`、`hevcdec.c:4272-4273`、`vp9.c:1950-1951`),用户用 `thread_type` 提示偏好。

**Q5:update_thread_context 里为什么复制的是"指针替换"而不是深拷贝?**
SPS/PPS 和 DPB 用 `av_refstruct_replace()` 增引用计数(`h264_slice.c:368-374`、`404-408`),多线程共享不可变参数集对象,避免拷贝大结构,也避免了悬垂指针——引用结构体池(refstruct)是 FFmpeg 后期引入的统一方案。

**Q6:slice 线程为什么和错误恢复(error resilience)冲突?**
错误恢复需要跨 slice 的宏块状态做遮挡修补,而 slice 线程下各线程并发修改;FFmpeg 干脆在 slice 线程时默认关闭 ER,用户强开则打 unsafe 警告(`h264dec.c:423-430`)。

**Q7:VP9 superframe index 为什么放在包尾而不是包头?**
设计取舍:编码器必须先完成所有子帧编码才知道各帧大小,放尾部可以边编码边写子帧;拆包器只需回读最后 1-6 字节。缺点是流式切分器必须保留包尾,这就是 FFmpeg 用 bsf(`vp9_superframe_split`,`vp9.c:1959`)统一预处理的原因。

**Q8:WPP 和 tile 有什么本质区别?**
tile 是二维矩形分块,块间零依赖,并行度等于 tile 数;WPP 是按 CTU 行波前推进,行 N+2 只等行 N 的第二列(`hls_decode_entry_wpp` 的 `await progress+SHIFT_CTB_WPP+1`,`hevcdec.c:2840-2842`),依赖限制了最大并行度为"行数",但压缩效率损失远小于 tile(不需要重置所有上下文)。FFmpeg 只在单 tile 时启用 WPP 调度(`hevcdec.c:3079-3082`)。

**Q9:为什么 `ff_thread_finish_setup()` 之后就不能再调用 get_buffer?**
`thread_get_buffer_internal()` 显式检查该状态并报错(`pthread_frame.c:1023-1026`)。因为 buffer 分配受 buffer_mutex 保护且与下一个线程的状态移交存在顺序约束,finish_setup 意味着"上下文允许被读取",此后再改共享状态会破坏移交一致性。

**Q10:CABAC 与 CAVLC 如何选择?**
slice 头之外的 PPS 里 `cabac` 标志决定(`decode_slice()` 检查 `h->ps.pps->cabac`,`h264_slice.c:2699`;非 CABAC 分支走 CAVLC 循环,`h264_slice.c:2781`)。Baseline profile 只允许 CAVLC(硬件简单),主 profile 用 CABAC(约省 10% 码率)。FFmpeg 按标志在运行时走两条解码路径。

---

## ⑨ 深挖问题(留给下一轮调研)

1. **H.264 MBAFF/场编码的线程语义**:`decode_slice()` 中 `FRAME_MBAFF` 时一个宏块行要解两次(`h264_slice.c:2728-2736`),`ff_h264_field_end` 的第二场等待逻辑(`h264dec.c:1122-1131`)与帧线程 `ff_thread_report_progress` 的 field 参数(`h264dec.c:869-872`)如何互动?隔行码流在帧线程下有哪些额外串行点?

2. **HEVC 多层(SHV/alpha 层)与 DPB**:hevcdec 支持 `layers[]` 多层上下文(`hevc_frame_start()`,`hevcdec.c:3239-3278` 对 base/non-base 层参数一致性校验),`ff_hevc_output_frames()` 按 layer 位图计数输出(`refs.c:278-304`)。多层并发解码时的进度上报与层间参考(base_layer_frame,`refs.c:236-237`)值得单独一篇。

3. **VP9 两遍解码(pass 1/2)与概率自适应**:`uses_2pass` 时块缓冲按两遍布局分配(`update_block_buffers()`,`vp9.c:339-345`),第一遍收集 `counts`、第二遍 `decode_sb_mem` 重放分区决策(`vp9.c:1371-1380`),随后 `ff_vp9_adapt_probs()`(`vp9.c:1820-1823`)。它与帧线程 `refreshctx && !parallelmode` 的耦合是理解 VP9 帧线程正确性的钥匙。

4. **`ff_thread_sync_ref` 与懒初始化共享**:`pthread_frame.c:1074-1092` 允许副本线程从首线程"接手"某个 refstruct 指针(配合 `internal->is_copy`,`pthread_frame.c:864-865`)。这是对"每个线程 init 一遍全局表"的优化,哪些解码器在用、语义边界如何,值得对照 vlc 表初始化(`ff_thread_once` 的全局单例,`h264dec.c:382-397`)一起分析。

5. **错误恢复路径的数据流**:`h264_er_decode_mb()` 用普通宏块解码器做遮挡修补(`h264dec.c:68-102`),`ff_er_frame_end` 在 `decode_nal_units` 末尾执行(`h264dec.c:833-867`),错误标志经原子量跨线程合并(`h264dec.c:804-815`)。可以度量一次"丢包-隐藏-恢复点"全链路的状态机。

---

### 附:本文引用文件一览

| 文件 | 角色 |
|---|---|
| `libavcodec/h264dec.c` | H.264 解码器入口、NAL 分派、延迟输出 |
| `libavcodec/h2645_parse.c` | H.264/HEVC/VVC 共享 NAL 切分与 RBSP 提取 |
| `libavcodec/h264_parse.c` | extradata/POC/加权预测等纯解析工具 |
| `libavcodec/h264_slice.c` | slice 头解析、宏块循环、slice 线程执行、帧线程状态迁移 |
| `libavcodec/h264_refs.c` | 参考列表构建(short/long ref → ref_list) |
| `libavcodec/hevc/hevcdec.c` + `hevc/refs.c` | HEVC 解码、CTU/WPP、DPB 输出 |
| `libavcodec/vp9.c` + `cbs_vp9.c` | VP9 帧头/superframe/tile 并行 |
| `libavcodec/pthread_frame.c` / `pthread_slice.c` | 帧级/片级线程框架 |
| `libavcodec/golomb.h` / `cabac.c` / `cabac_functions.h` / `h264_cabac.c` | 熵编码原语 |
