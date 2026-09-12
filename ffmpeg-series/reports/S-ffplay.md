# S 章 · ffplay：一个能跑的播放器如何把全部库串起来

> 源码：`fftools/ffplay.c`（3982 行）+ `fftools/ffplay_renderer.c`（890 行），commit 9f63b36a（master）。
> 前置章节：02-05 框架层、16 章 CLI 转码调度。本章是"三大工具"系列的收官：ffprobe 看得到、ffmpeg 写得出、ffplay 播得动——它把 avformat/avcodec/swresample/swscale/avfilter 全部串进一个 ~4000 行的实时状态机。

---

## 1. 全景：线程拓扑

ffplay 一共跑 **5 类线程**（1 读 + 3 解码 + 1 主线程事件循环），外加 1 个 **SDL 音频回调线程**（由驱动调度，不计入 SDL_CreateThread）：

```
 main() ffplay.c:3850
   ├─ stream_open() :3237  分配 VideoState、init 三对队列、init 三个时钟
   │    └─ SDL_CreateThread(read_thread) :3296
   ├─ event_loop(is) :3977  ← 主线程从此不再返回
   │
   ▼
┌─────────────────── read_thread :2879 ───────────────────┐
│ avformat_open_input :2921 → avformat_find_stream_info   │
│   → stream_component_open(audio/video/subtitle)         │
│       :3048/3053/3059（内部各自 decoder_start 起解码线程）│
│ 循环：av_read_frame :3155 → 按 stream_index 分发入队     │
│   audioq :3209 / videoq :3212 / subtitleq :3214         │
└──────┬~~~~~~~~~~~~~~~~~~~~~~┬~~~~~~~~~~~~~~~~~~~~~~~┬──┘
       ▼ PacketQueue          ▼                       ▼
┌─ audio_thread :2128 ┐ ┌─ video_thread :2217 ┐ ┌─ subtitle_thread :2320 ┐
│ decoder_decode_frame│ │ get_video_frame     │ │ decoder_decode_frame   │
│   → avfilter(agraph)│ │   → avfilter(graph) │ │   → avcodec_decode_    │
│   → FrameQueue sampq│ │   → FrameQueue pictq│ │     subtitle2          │
└──────┬──────────────┘ └──────┬──────────────┘ └──────┬─────────────────┘
       ▼                       ▼                       ▼ FrameQueue subpq
┌─ SDL 音频回调线程（心脏）┐   │                        │
│ sdl_audio_callback      │   ▼                        │
│   :2533                 │ video_refresh :1630        │
│   ← audio_decode_frame  │ （在主线程 event_loop 内、  │
│     :2423               │  由 refresh_loop_wait_event│
│   ← synchronize_audio   │   :3403 驱动，计算节拍）    │
│     :2375               │                            │
│   → set_clock(audclk)   │                            │
│     :2570               │                            │
└─────────────────────────┘                            ▼
   主线程 event_loop :3448 ← refresh_loop_wait_event :3403
   SDL_PeepEvents 无事件时调用 video_refresh 刷帧 → video_display :1415
```

三条不变式：
- **读线程只碰 PacketQueue，解码线程只碰 FrameQueue**，主线程只消费 FrameQueue——单向数据流，跨级只通过 `serial` 对账。
- 音频消费不在任何显式线程里，而在 **SDL 音频驱动的回调线程**，它是整个播放器唯一"由外部节拍器推动"的环节，所以天然适合当主时钟。
- 主线程 `event_loop` 里没有 sleep-based 渲染循环的独立线程：`refresh_loop_wait_event` 用 `video_refresh` 算出的 `remaining_time` 决定睡多久（:3403-3418）。

---

## 2. VideoState 解剖

`VideoState` 是整个播放器的"全局状态单例"，一个文件一个实例（`stream_open` :3242 `av_mallocz`）。关键字段（ffplay.c:203-305）：

| 字段组 | 行号 | 说明 |
|---|---|---|
| `read_tid` / `abort_request` | :204/:206 | 读线程句柄与总闸 |
| `seek_req/seek_pos/seek_rel/seek_flags` | :211-214 | seek 请求信箱（见 §7） |
| `paused` / `last_paused` / `step` | :208/:209/:293 | 暂停与单步 |
| `audclk/vidclk/extclk` | :219-221 | 三个 `Clock`（结构在 :139-147） |
| `pictq/subpq/sampq` | :223-225 | 三个 FrameQueue |
| `auddec/viddec/subdec` | :227-229 | 三个 `Decoder`（:188-201） |
| `audioq/videoq/subtitleq` | :242/:286/:279 | 三个 PacketQueue |
| `audio_buf/audio_buf1/audio_buf_index...` | :244-249 | 回调级音频缓冲 |
| `audio_src/audio_tgt/swr_ctx` | :252/:254/:255 | 重采样参数对 |
| `audio_diff_cum/audio_diff_avg_coef/audio_diff_threshold` | :237-240 | 音频同步低通滤波器状态 |
| `frame_drops_early/frame_drops_late` | :256-257 | 两级丢帧计数（状态行 fd= 显示） |
| `frame_timer` | :281 | 视频显示节拍器的"下一拍"时刻 |
| `in_video_filter/out_video_filter/agraph` | :296-300 | 每流一条滤镜链 |
| `continue_read_thread` | :304 | 唤醒读线程的 cond（seek/队列消耗时用） |

`Clock`（:139-147）值得单独看：`pts` 是基准，`pts_drift = pts - 更新时刻`，读数时用 `get_clock`（:1429-1439）按真实时间外推：

```c
static double get_clock(Clock *c)
{
    if (*c->queue_serial != c->serial)
        return NAN;                 // 时钟已随旧序列作废
    if (c->paused) {
        return c->pts;
    } else {
        double time = av_gettime_relative() / 1000000.0;
        return c->pts_drift + time - (time - c->last_updated) * (1.0 - c->speed);
    }
}
```

`queue_serial` 指向对应 PacketQueue 的 `serial`——**用一次指针解引用实现"时钟是否还属于当前播放序列"的判断**，seek 后旧时钟自动变 NAN，不用显式清理。

---

## 3. 双队列专节：PacketQueue / FrameQueue 的并发设计

### 3.1 PacketQueue：互斥 + 条件变量 + abort + serial

定义 :115-124：底层是 `AVFifo`（`av_fifo_alloc2` :476），元素 `MyAVPacketList{pkt, serial}`（:110-113）。四个元数据随队列维护：`nb_packets/size/duration/serial`。

- **put/get 是标准生产者-消费者**：`packet_queue_get`（:535-567）在锁内循环，空且 `block` 则 `SDL_CondWait`（:562）；`packet_queue_put_private` 入队后 `SDL_CondSignal`（:440）。
- **abort_request 机制**（:515-524）：置位后 `SDL_CondSignal` 唤醒所有等待者，`get` 立即返回 -1（:543-546）——这是"从任意线程拆掉一条阻塞管线"的唯一通道。`packet_queue_init` 把它初始化为 1（:489），即"队列天生是停的"，`decoder_start` 里的 `packet_queue_start`（:526-532）才放行并 `serial++`。
- **serial 是版本号**：`flush`（:493-505）清空队列并 `serial++`（:503）；此后旧 serial 的包/帧/时钟全部作废。读包时 `packet_queue_put_private` 给每个包打上当前 serial（:431），消费端靠 `pkt_serial != queue->serial` 识别"seek 前的遗留数据"。
- **背压**：不靠条件变量，而是读线程轮询——总字节数超 `MAX_QUEUE_SIZE`（15 MB，:66）或各流 `stream_has_enough_packets`（:2855-2860，>25 包且时长 >1s，:67）就 `SDL_CondWaitTimeout(10ms)`（:3134-3144）。

### 3.2 FrameQueue：无锁写入点 + keep_last 语义

定义 :169-180：定长环形数组 `Frame queue[FRAME_QUEUE_SIZE]`（=16，:129；视频实际 max_size=3，:126）。**它故意不用一把锁保护读端索引**：

- `rindex/rindex_shown` 只被消费者改，`windex` 只被生产者改，`size` 在锁内改。`frame_queue_push`（:779-787）：生产者先在锁外填好 `windex` 槽位，再锁内 `size++` 并 signal。
- **写入侧** `frame_queue_peek_writable`（:747-761）：`size >= max_size` 时等待，但注意它的退出条件是 `!f->pktq->abort_request`——**FrameQueue 没有 abort 标志，借用上游 PacketQueue 的**（`f->pktq` 在 `frame_queue_init` :704 绑定）。`decoder_abort`（:820-827）因此必须两连击：`packet_queue_abort` + `frame_queue_signal`（:725-730）才能把两侧都解锁。
- **读取侧** `frame_queue_peek_readable`（:763-777）：`size - rindex_shown <= 0` 才等。
- **keep_last / rindex_shown 是本队列最精妙的设计**（`frame_queue_next` :789-802）：

```c
static void frame_queue_next(FrameQueue *f)
{
    if (f->keep_last && !f->rindex_shown) {
        f->rindex_shown = 1;      // 第一帧"消费"时不释放，留在 rindex 供重绘
        return;
    }
    frame_queue_unref_item(&f->queue[f->rindex]);
    ...
}
```

`keep_last=1`（pictq/sampq，:3256/:3260）意味着"最后一帧永不释放，除非来新帧顶替"。于是：
- `frame_queue_peek_last`（:742-745）返回"当前正在显示的帧"，窗口 expose/全屏切换时可以零成本重绘（video_refresh 的 `display:` 标签 :1741-1744 就靠它）；
- `frame_queue_nb_remaining`（:805-808）= `size - rindex_shown`，即"未显示帧数"，是同步算法的输入；
- peek 与 peek_last 因此错开一格：`peek` = `queue[(rindex + rindex_shown) % max_size]`（:732-735）。

初始化处也印证了语义：subpq `keep_last=0`（:3258），因为字幕过期即焚，无需重绘。

---

## 4. 音频心脏专节：回调链为什么是主时钟

完整调用链（每处行号实核）：

```
SDL 驱动线程周期性调用（周期由 audio_open :2606 决定：
  samples = max(512, 2^ceil(log2(freq/30)))，约 ≥1/30 秒一回调）
  └─ sdl_audio_callback :2533
       ├─ audio_callback_time = now（:2538，供波形显示与 Win32 等待估算）
       ├─ while(len>0) :2540        ← SDL 要多少填多少
       │    ├─ 缓冲耗尽 → audio_decode_frame :2542 / :2423
       │    │    ├─ frame_queue_peek_readable(sampq) :2441 → frame_queue_next :2443
       │    │    ├─ synchronize_audio :2450 / :2375  ← 算"该给多少样本"
       │    │    ├─ swr_alloc_set_opts2/swr_convert :2458/:2496 ← 重采样+补偿
       │    │    └─ is->audio_clock = af->pts + nb_samples/sample_rate :2516
       │    │        （即"这块缓冲播完时音频流应到达的 pts"）
       │    ├─ 失败 → 填静音 :2543-2546（播放器永不因缺数据停摆）
       │    └─ memcpy / SDL_MixAudioFormat :2557-2563（音量在混合时施加）
       └─ 回调尾：set_clock_at(&audclk, ...) :2570-2572
            pts = audio_clock - (2*hw_buf_size + write_buf_size)/bytes_per_sec
            sync_clock_to_slave(&extclk, &audclk) :2572
```

为什么音频是主时钟？三点结构性原因：

1. **节拍是硬件给的**。声卡以固定速率消费样本，回调周期不由 ffplay 控制——这个"外部强制节拍"正是时钟的定义。视频没有对应物：`SDL_RENDERER_PRESENTVSYNC`（:3955）只是尽力而为。
2. **读数是插值出来的**。回调结束时刻，硬件里还压着约 `2*hw_buf_size + audio_write_buf_size` 字节没播（:2568-2571），所以时钟要**往回扣**这段硬件延迟——`audclk` 读出的永远是"耳朵此刻听到的 pts"，而非"刚解码的 pts"。
3. **更新在回调里、消费在别处**，天然线程安全：`synchronize_audio`（:2375-2414）与 `compute_target_delay`（:1580）只是读时钟，从不写。

`synchronize_audio` 的细节（:2375-2414）：仅当音频**不是** master 时工作。它对 `diff = audclk - master` 做一阶低通（`audio_diff_cum`，系数 `exp(log(0.01)/20)` 在 :2797 初始化，即 20 次平均），累计 20 个样本（`AUDIO_DIFF_AVG_NB` :97）后，若平均偏差超过阈值 `audio_diff_threshold`（= 硬件缓冲时长，:2801），就请求 `wanted_nb_samples = nb_samples + diff*freq`，并夹在 ±10%（`SAMPLE_CORRECTION_PERCENT_MAX` :89，:2397-2399）。**校正不靠丢样本，而靠 `swr_set_compensation`（:2487-2488）让重采样器微变速**——听感无察觉。

---

## 5. 视频同步专节：compute_target_delay 与两级 framedrop

视频是"从动轮"：`get_master_sync_type`（:1477-1491）默认 `AV_SYNC_AUDIO_MASTER`（全局默认 :328），有视频无音频时回落 external。

### 5.1 核心算法（video_refresh 内，:1672-1684）

```c
/* compute nominal last_duration */
last_duration = vp_duration(is, lastvp, vp);        // :1673
delay = compute_target_delay(last_duration, is);    // :1674

time = av_gettime_relative()/1000000.0;
if (time < is->frame_timer + delay) {               // :1677 还没到点
    *remaining_time = FFMIN(is->frame_timer + delay - time, *remaining_time);
    goto display;                                   // 上一帧继续留着显示
}
is->frame_timer += delay;                           // :1682 推进节拍器
if (delay > 0 && time - is->frame_timer > AV_SYNC_THRESHOLD_MAX)
    is->frame_timer = time;                         // :1683-1684 落后太多，硬重置
```

`frame_timer` 是"理想显示时刻"的累积器——**每帧加一个 delay，而不是设为 now**，这样累积误差为零；只有偏差超过 0.1s（`AV_SYNC_THRESHOLD_MAX` :82）才放弃累积直接对齐 now。暂停恢复时 `stream_toggle_pause` 也要补偿 frame_timer（:1544）。

### 5.2 compute_target_delay：超前等待 / 落后丢帧（:1580-1608）

视频非 master 时，`diff = vidclk - master`（:1588）：
- `diff <= -sync_threshold`（视频落后，阈值夹在 [0.04, 0.1] 且随 delay 自适应，:1593）：`delay = max(0, delay+diff)` —— **缩短显示时长，尽快追**；
- `diff >= sync_threshold` 且 `delay > AV_SYNC_FRAMEDUP_THRESHOLD`（0.1，:84）：`delay += diff` —— 落后太多就整帧重复；
- `diff >= sync_threshold` 但 delay 很小：`delay = 2*delay` —— 翻倍等待（温和的重复）；
- `|diff| > max_frame_duration` 视为时间戳跳变，不校正（:1594）。
误差超过 `AV_NOSYNC_THRESHOLD`（10s，:86）后 `sync_clock_to_slave` 直接硬拨时钟（:1469-1475）。

`vp_duration`（:1610-1620）：优先用 `nextvp.pts - vp.pts`（同 serial 才有效），异常时退回 `frame->duration`，跨 serial 返回 0——保证 seek 后第一帧立即显示。

### 5.3 两级 framedrop

- **early（解码线程，get_video_frame :1843-1854）**：`framedrop` 开启（默认 -1=自动，:339，非视频 master 即生效）且 `dpts < master_clock`（扣除滤镜延迟 :1847）、队列里还有包时，直接 `av_frame_unref` 丢弃，`frame_drops_early++`。**这是主丢弃路径**：解码后、进滤镜前丢，最省 CPU。
- **late（主线程，video_refresh :1691-1698）**：已有下一帧且 `time > frame_timer + duration` 时跳过当前帧，`frame_drops_late++`。它救的是"帧已排队但显示已迟到"。

两级计数都汇入状态行 `fd=%d`（:1779）。`is->step`（单步模式）会绕过 late 丢弃（:1694 `!is->step`）。

---

## 6. 刷新循环专节：refresh_loop_wait_event 的显示节拍

ffplay 没有独立的"渲染线程"，主线程 `event_loop`（:3448）里每次迭代先 `refresh_loop_wait_event`（:3403-3418）：

```c
static void refresh_loop_wait_event(VideoState *is, SDL_Event *event) {
    double remaining_time = 0.0;
    SDL_PumpEvents();
    while (!SDL_PeepEvents(event, 1, SDL_GETEVENT, ...)) {
        ...  // 光标自动隐藏 :3407-3410
        if (remaining_time > 0.0)
            av_usleep((int64_t)(remaining_time * 1000000.0));
        remaining_time = REFRESH_RATE;              // :3413 兜底 0.01s（:100）
        if (is->show_mode != SHOW_MODE_NONE && (!is->paused || is->force_refresh))
            video_refresh(is, &remaining_time);     // :3415 同步+按需重绘
        SDL_PumpEvents();
    }
}
```

三个要点：
1. **首轮 remaining_time=0 不睡**，立刻跑一次 video_refresh；此后由 video_refresh 写回的 `remaining_time` 决定下一轮睡多久——睡到"下一帧该显示的时刻"，而不是傻等固定 10ms。`REFRESH_RATE 0.01`（:100）只是上限兜底。
2. **video_refresh 决定"要不要重绘"**：只有 `force_refresh` 置位或帧切换时才真正调 `video_display`（:1741-1744）；`force_refresh` 在帧推进（:1736）、窗口事件（:3634）、全屏切换（:3468）等处置位，用完即清（:1746）。
3. **暂停态靠 `force_refresh` 例外**（:3414）保证暂停瞬间画面仍然刷出，随后不再空转。

真正的绘制在 `video_display`（:1415-1427）：`SDL_RenderClear` → 音频可视化（`video_audio_display` 波形/RDFT 频谱，:1102-1251，用的是回调里 `update_sample_display` 存进 `sample_array` 的样本）或 `video_image_display`（:1006-1095，含字幕纹理合成），最后 `SDL_RenderPresent`。

---

## 7. seek 与退出专节

### 7.1 seek：三层接力

1. **UI 层**（event_loop :3536-3559）：左右键 ±10s、上下 ±60s、右键按窗口比例拖动（:3596-3619）、章节键 `seek_chapter`（:3420-3445）。`seek_by_bytes` 模式（流不支持时间戳 seek 时，自动判定在 :2968-2971）改按字节位置换算（:3537-3550）。最终都汇入 `stream_seek`。
2. **请求信箱**（stream_seek :1527-1538）：只是填 `seek_pos/seek_rel/seek_flags` 并置 `seek_req=1`，`SDL_CondSignal(continue_read_thread)`（:1536）把可能在 10ms 小睡里的读线程踢醒。**若已有 pending 的 seek，新的直接被丢弃**（:1529）——天然合并连续按键。
3. **执行层**（read_thread :3093-3122）：`avformat_seek_file(ic, -1, seek_min, seek_target, seek_max, flags)`（:3100，min/max 由 seek_rel 推出，±2 的舍入修正见 :3097 注释），成功后三队列 `packet_queue_flush`（:3105-3110，serial++ 使旧帧/旧时钟全部失效）、`extclk` 设到目标时刻（:3111-3115）。attach_pic（封面）重新入队（`queue_attachments_req`，:3123-3131）。

### 7.2 退出：abort 波纹

退出有五个入口：q/ESC 键（:3458）、鼠标（:3566）、窗口关闭/`SDL_QUIT`/`FF_QUIT_EVENT`（:3637-3639）、读线程失败推事件（:3226-3232）、SIGINT/SIGTERM（`sigterm_handler` 直接 `exit(123)`，:1374-1377，不走清理）。

正常路径 `do_exit` → `stream_close`（:1311-1345）的次序很讲究：

```
is->abort_request = 1            :1314   ← 总闸，同时是 avio 中断回调的返回值
                                          （decode_interrupt_cb :2849-2853，
                                           让阻塞在网络的 av_read_frame 立即失败）
SDL_WaitThread(read_tid)         :1315   ← 等读线程死透
逐流 stream_component_close      :1318-1323
    └─ decoder_abort(dec, fq)    :1264/:1281/:1285 → :820-827
        packet_queue_abort(queue)        ← 解锁 packet_queue_get
        frame_queue_signal(fq)           ← 解锁 peek_writable/readable
        SDL_WaitThread(decoder_tid)      ← 等解码线程退出
        packet_queue_flush(queue)
    SDL_CloseAudioDevice（音频流特有）:1265
avformat_close_input             :1325
三个 packet_queue_destroy        :1327-1329
三个 frame_queue_destroy         :1332-1334
```

要点：**abort 顺序必须先读线程、后解码线程**——读线程活着时还会往队列塞包；解码线程阻塞在 `packet_queue_get` 或 `frame_queue_peek_writable`，靠 `abort_request` + `frame_queue_signal` 两路唤醒。音频设备最后关，避免回调线程还在摸 `sampq`。

---

## 8. ffplay_renderer.c 简述与 upload_texture 归位

- **SDL_Renderer 路径（默认）**：纹理上传在 ffplay.c 自己的 `upload_texture`（:909-941）：查 `sdl_texture_format_map`（:372-395，含 YUV420P→IYUV 等映射）能直传就 `SDL_UpdateYUVTexture`（:920-926，负 linesize 翻转处理）；不能直传则转 ARGB8888 交 swscale。YUV→RGB 的色彩空间由 `set_sdl_yuv_conversion_mode`（:954-968）按帧的 colorspace/range 设 SDL 2.0.8+ 的转换模式。滤镜链的 buffersink 也只放行 SDL 支持的像素格式（configure_video_filters :1920-1927、:1973-1985）——**"让滤镜做格式转换"而不是"上传时转换"**，是 ffplay 渲染管线的核心取舍。
- **Vulkan 路径（`-enable_vulkan`，ffplay_renderer.c）**：`VkRenderer` 是 5 个函数指针的小型接口（:48-60：create/get_hw_dev/display/resize/destroy）。SDL 窗口 + libplacebo swapchain（`create` :465-538），`display`（:724-790）里 `convert_frame` 先把任意硬件帧（CUDA 等）map/transfer 成 VULKAN 帧（:693-722，map 失败退 transfer，hw 失败退软件拷贝，三级回退 :707-719），再 `pl_map_avframe_ex` → `pl_render_image` → `pl_swapchain_submit_frame`。它同时向解码器提供 hw device（`get_hw_dev` :540-546，`create_hwaccel` ffplay.c:2652-2686 用它派生），实现"硬解零拷贝上屏"。编译开关 `HAVE_VULKAN_RENDERER` 需 SDL≥2.0.6 且 libplacebo（:25-29），未启用时 `vk_get_renderer()` 返回 NULL（:859-862）。

---

## 9. 设计动机三问

**Q1 为什么不用一条 avfilter 图管线打通 demux→decode→render？**
因为播放器的三路流有不同的实时性约束：音频必须由硬件回调按固定节拍拉取，视频必须按同步算法决定显示时刻，字幕要叠加在视频矩形上。ffplay 的选择是"每流一条解码+格式转换滤镜链"（`configure_video_filters` :1904、`configure_audio_filters` :2056），但**跨流调度自己写**——三对队列 + 三个时钟。滤镜图擅长单链数据变换，不擅长带反馈的实时调度（A-V 误差要反喂给丢帧/加样本决策），这正是 ffmpeg.c（转码，管线化、`ffmpeg_sched` 调度）与 ffplay.c（播放，状态机+时钟）架构分野的根本原因。同一作者、同一个库、两种编排哲学。

**Q2 为什么音频做主时钟？**
§4 已述结构性原因：唯一由硬件节拍驱动的消费者、可连续微调（重采样变速 ±10% 无感）、读数可通过硬件缓冲扣减精确到"耳朵时刻"。视频做不到连续微调——它只有"重复一帧/丢一帧"两种离散手段（compute_target_delay 的两个分支正对应这两手）。反过来若视频做 master（`-sync video`），音频就靠 `synchronize_audio` 微变速去追，:2380 的 `get_master_sync_type(is) != AV_SYNC_AUDIO_MASTER` 就是这条反向路径的开关。

**Q3 SDL 解耦的意义？**
ffplay.c 里没有任何平台代码（无 X11/Win32 调用），窗口/纹理/线程/互斥全部经 SDL 抽象；于是这 4000 行成为**库 API 的权威用法示例**（doc/examples 之外唯一的官方级完整消费者）。它也是 FFmpeg 的"最恶劣用户"：新 API 若让 ffplay 变复杂，通常意味着 API 设计有问题——历史上 FF_API_* 多处弃用都拿 ffplay 当试金石。代价是 SDL 的局限也成为 ffplay 的局限：单窗口、无音频设备枚举 UI、`SDL_RENDERER_PRESENTVSYNC` 与自算节拍双轨并行（帧率被 min(vsync, frame_timer) 约束）。

---

## 10. FAQ 素材

1. **ffplay 一共开几个线程？** 最多 5 个 SDL 线程（read + 3 解码 + 主线程）+ 1 个 SDL 音频回调线程；解码器内部线程（`threads=auto`，:2747-2748）与滤镜线程（`filter_nbthreads`，:2068/:2262）另计。
2. **暂停时时钟为什么不会跑飞？** `get_clock` 对 paused 直接返回 `pts`（:1433-1435）；恢复时 `stream_toggle_pause` 补偿 frame_timer（:1543-1549）并重设四个时钟（:1551）。
3. **窗口被遮挡再露出，画面为什么能恢复？** `SDL_WINDOWEVENT_EXPOSED` 置 `force_refresh`（:3633-3634），display 分支用 `frame_queue_peek_last` 重绘上一帧（:1743、:1012）——keep_last 语义的直接收益。
4. **状态行 `A-V: xxx` 是什么？** `get_clock(audclk) - get_clock(vidclk)`，30ms 刷新一次（:1755，计算在 :1765-1771）。
5. **EOF 后播放器怎么收尾？** 读线程给三条队列各塞一个 null packet（:3157-3163），解码线程收到后 `finished = pkt_serial`（:617-621）；`-autoexit` 时读线程推 FF_QUIT_EVENT（:3150-3152 经 :3226-3232），否则停在最后一帧。
6. **`-loop` 怎么实现？** 读线程检测两条流都 finished 且帧队列排空（:3145-3147），`stream_seek` 回起点（:3148-3149）——循环复用 seek 机制，不重建解码器。
7. **为什么 seek 后可能闪一帧旧画面？** flush 只清 packet 队列与 serial，pictq 里已解码的旧帧要等 video_refresh 里 `vp->serial != videoq.serial` 的 retry 循环逐个跳过（:1661-1664）。
8. **音量调节在哪生效？** 回调内 `SDL_MixAudioFormat`（:2557-2563），对 S16 样本混合时缩放，`update_volume` 按 dB 步进（:1565-1570，步长 0.75dB :77）。
9. **纯音频文件显示的频谱是什么？** RDFT（实数傅里叶，av_tx，:1202-1203）逐列画进 vis_texture；失败自动退回波形模式（:1205-1207）。
10. **`audio_buf` 和 `audio_buf1` 的区别？** `audio_buf1` 是 swr 输出的堆缓冲（`av_fast_malloc` :2493）；无重采样时 `audio_buf` 直接指向帧数据（:2509），零拷贝——生命周期由 FrameQueue keep_last 保证安全。

## 深挖方向

1. **serial 贯穿链**：`packet_queue_flush/start` 的 serial++（:503/:530）→ 包携带 serial（:431）→ `Decoder.pkt_serial`（:634）→ Frame.serial（:1819/:2187）→ `Clock.queue_serial` 反查（:1465）→ video_refresh retry（:1661）与 `audio_decode_frame` 的 `while (af->serial != audioq.serial)`（:2444）。一次 seek 会让全链数据"作废但不崩溃"。
2. **音频双通路**：`audio_thread` 走滤镜图输出 sampq（:2176-2195），`audio_decode_frame` 再做 swr 到硬件参数（:2476-2507）——为什么不在滤镜图里一次到位？因为 `audio_tgt`（硬件参数）只有 `audio_open` 之后才知道，且硬件参数变化（设备切换）只影响末端。
3. **`decoder_decode_frame` 的状态机**（:582-679）：send/receive 双向 EAGAIN 处理（:624 + `packet_pending` :630/:655/:673）、subtitle 特殊路径（:648-659，subtitle API 是 pull 模型）、serial 变化时 `avcodec_flush_buffers`（:636-641）。
4. **external clock 的自适应变速**（check_external_clock_speed :1512-1524）：队列少于 2 包减速到 0.9，多于 10 包加速到 1.01——实时流防止缓冲耗尽的软着陆。
5. **Win32 特有的 sampq 忙等**（:2434-2440）：Windows 音频回调线程优先级高，不能 CondWait（回调里锁+等易死锁），改为估剩余硬件缓冲、超 1/2 秒预算就返回静音。

---

## 写作要点速查表（函数 → 行号，ffplay.c 除注明外）

| 函数/结构 | 行号 | 一句话 |
|---|---|---|
| `PacketQueue` / `FrameQueue` / `Clock` / `Decoder` / `VideoState` | 115 / 169 / 139 / 188 / 203 | 五大结构定义 |
| 同步常量（threshold/framedup/nosync） | 80-97 | 0.04/0.1/10s/±10% |
| `packet_queue_get` / `abort` / `flush` | 535 / 515 / 493 | 消费、熔断、换代 |
| `decoder_decode_frame` | 582-679 | send/receive 状态机 |
| `frame_queue_peek_writable` / `next` / `nb_remaining` | 747 / 789 / 805 | keep_last 核心 |
| `decoder_abort` | 820-827 | 两路唤醒+收线程 |
| `upload_texture` | 909-941 | YUV 直传 SDL |
| `video_image_display` | 1006-1095 | 视频+字幕合成 |
| `stream_close` / `do_exit` | 1311 / 1347 | 退出序 |
| `get_clock` / `get_master_sync_type` / `get_master_clock` | 1429 / 1477 / 1494 | 时钟读取与主从选择 |
| `stream_seek` / `stream_toggle_pause` | 1527 / 1541 | 请求信箱 / 时钟补偿 |
| `compute_target_delay` | 1580-1608 | 超前等待/落后丢帧 |
| `vp_duration` | 1610-1620 | 帧时长估算 |
| `video_refresh` | 1630-1795 | 帧节拍（frame_timer 推进 :1682，late 丢帧 :1691-1698） |
| `queue_picture` / `get_video_frame`（early 丢帧） | 1797 / 1828(:1843) | 生产帧 / 主丢弃路径 |
| `audio_thread` / `video_thread` / `subtitle_thread` | 2128 / 2217 / 2320 | 三解码线程 |
| `decoder_start` | 2206-2215 | packet_queue_start+起线程 |
| `synchronize_audio` | 2375-2414 | 音频微变速校正 |
| `audio_decode_frame` | 2423-2530 | 取帧→swr→更新 audio_clock(:2516) |
| `sdl_audio_callback` | 2533-2574 | 心脏；尾部 set_clock(:2570) |
| `audio_open` | 2576-2650 | SDL 音频协商 |
| `stream_component_open` | 2689-2847 | 每流装配（音频分支 :2770） |
| `read_thread` | 2879-3235 | 打开→选流→分发循环（seek :3093，背压 :3134，EOF :3145） |
| `stream_open` | 3237-3304 | 装配+起读线程(:3296) |
| `refresh_loop_wait_event` | 3403-3418 | 主线程显示节拍 |
| `event_loop` / `main` | 3448 / 3850 | 按键分发 / 装配入口 |
| `vk_get_renderer`（ffplay_renderer.c） | 838-855 | Vulkan 接口装配；display :724 |
