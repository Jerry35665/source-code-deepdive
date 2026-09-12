# 第 21 章 · ffplay:一个能跑的播放器——三线程模型与音视频同步

> 基线:commit `9f63b36a`。行号以 fftools/ffplay.c(约 3800 行)与 ffplay_renderer.c 为准。全系列的知识在本章汇成一个可执行文件:02 章 avio/demuxer、03 章 send/receive、04 章滤镜、07/08 章解码、13 章 seek——ffplay 是它们的总装车间。一处勘误:ffplay_renderer.c 不是 SDL 封装,而是**可选的 libplacebo/Vulkan 渲染器**(VkRenderer 五函数指针,ffplay_renderer.c:48-60)。

## 21.0 全景:线程拓扑

```
主线程: event_loop(:3477)──SDL 事件→refresh_loop_wait_event(:3403)
        │                        │ 消费 pictq,按节拍重绘
read_thread(:2879,每输入 1 个)
  avformat_open_input(:2921)→stream_component_open(:2689)
  └ 循环 av_read_frame(:3155)→按类型入 audioq/videoq/subtitleq(:3209-3214)
解码线程×3(audio_thread:2128 / video_thread:2217 / subtitle_thread:2320)
  各自:PacketQueue →(audio 过滤镜图)→ FrameQueue(pictq/sampq/subpq)
SDL 音频回调线程(独立):sdl_audio_callback(:2533)消费 sampq ←时钟心脏
```

五个并发单元围绕**两个队列类型+三个时钟**协作:`audclk/vidclk/extclk`(VideoState,ffplay.c:219-221;Clock 结构 :139-147)。队列规格写在 stream_open:pictq=3/keep_last=1、sampq=9、subpq=16(:3256-3260;FRAME_QUEUE_SIZE=16 :129)——**画面队列只有 3 帧**:解码快过显示时立刻背压,内存常驻极小。

## 21.1 双队列:PacketQueue 与 FrameQueue

PacketQueue(:115-124)是带 serial(代数)的链表队列,两个关键机制:

- **abort 熔断**:`packet_queue_abort`(:515)置位并 signal,所有阻塞在条件变量上的操作立即返回——这是退出协议的神经;
- **flush 用 serial 隔代**:seek 时 `serial++`(:503),队列里的旧代数据被消费端丢弃,不需要物理清空。

FrameQueue 更精妙:固定环形数组+**keep_last 语义**——`frame_queue_next`(:789-802)首次推进只置 `rindex_shown=1` 不真正释放,保证"当前显示帧"永远可读;`nb_remaining=size−rindex_shown`(:805)是真实可消费计数。FrameQueue 没有自己的 abort,而是**借用上游 PacketQueue 的 abort_request 唤醒**(:751-758)——单一熔断源,退出时 `decoder_abort`(:820)必须 packet_queue_abort+frame_queue_signal 两路齐发。

## 21.2 音频心脏:回调链与主时钟

为什么音频做主时钟?**音频输出是唯一有硬件节拍的设备**:声卡按固定采样率取数据,回调被动的频率就是物理时间基准。链条:

```
SDL 线程 → sdl_audio_callback(:2533)
  → audio_decode_frame:从 sampq 取帧 → synchronize_audio 微变速
  → 拷贝到硬件缓冲
  → audio_clock = af->pts + nb_samples/rate(:2516)
  → set_clock_at 扣除"已写未播"的硬件缓冲(:2570-2572)
```

`synchronize_audio`(:2375-2414)用低通平均 A-V 差(系数 exp(log(0.01)/20),:2797),偏差超阈值(=硬件缓冲时长,:2801)时调 `swr_set_compensation`(:2487)做 **±10% 以内的微变速**——正是 07 章讲的"重采样步进追钟"在播放器的实战:听感无感的速度差吸收时钟漂移。

## 21.3 视频从动轮:compute_target_delay

视频显示节拍由 `video_refresh`(:1630)驱动:

```c
/* ffplay.c(骨架) */
last_duration = vp_duration(last_vp, vp);        /* :1673 */
delay = compute_target_delay(last_duration, is); /* :1674 */
if (time < frame_timer + delay) → 还不到,带 remaining_time 返回
frame_timer += delay;                            /* :1682 累积制 */
if (偏差 > 0.1s) frame_timer = now;              /* :1683-1684 硬重置 */
```

`compute_target_delay`(:1580)是同步算法核心:`diff = vidclk − master` 音视频差,**落后**(diff>阈值区间 [0.04,0.1])缩短 delay 追赶(:1595-1596);**超前**则拉长 delay 重复显示(delay 小则翻倍 :1600,delay>0.1 直接加 diff :1597-1598)。`frame_timer += delay` 用**累积**而非赋值——每帧只承担自己的误差,不放大。丢帧两级:解码后按 dpts 落后丢弃(get_video_frame,:1843-1854,即 `-framedrop`),显示迟到再丢(:1691-1698)。

## 21.4 刷新循环与 seek

`refresh_loop_wait_event`(:3403)按 remaining_time 睡眠到点再刷新——**重绘节拍由同步算法决定**,不是固定 60fps。seek 走请求信箱:用户事件→`stream_seek`(:1527)只置 SeekReq 结构并 signal 读线程(:1536),实际执行在读线程 :3093-3122:flush 三个 PacketQueue(serial 隔代)+ extclk 设目标值——**读线程单点执行 seek**消除并发竞态。

## 21.5 退出协议与渲染

退出序(:1314 起):`is->abort_request` 置位——它**同时是 avio 中断回调 decode_interrupt_cb(:2849)的返回值**,一个标志同时熔断网络阻塞与全部队列;等读线程退出(:1315)→逐流 decoder_abort→avformat_close_input(:1325)。渲染默认路径 `upload_texture`(:909-941)YUV 直传 SDL_Texture;ffplay_renderer.c 提供 libplacebo/Vulkan 高级渲染(VkRenderer,:48-60;三级回退 map→transfer→软拷贝 :707-719),并能为硬解提供 GPU 设备(:540)。

## 21.6 设计动机

1. **为什么不用 avfilter 管线贯通全图**:播放器需要逐帧取回+精确节拍控制,滤镜图的批处理语义反而碍事——ffplay 只在音频重采样处用最小滤镜图(video_audio 互不干扰)。**框架是给转码的,播放器要的是时钟**;
2. **音频主时钟是物理约束的选择**:视频可等待/重复/丢弃(视觉无感),音频只能微变速(听觉敏感)——把不可控的一方当主,可控的一方当从;
3. **信箱模式处处可见**:SeekReq/StepReq/暂停标志全部"置位+signal",由目标线程自取——跨线程操作不共享锁,只共享不可变请求结构;
4. **队列深度即内存策略**:pictq=3 意味着最多缓冲 3 帧,4K 播放器常驻显存/内存可预期——深度是产品参数,不是实现细节。

## 21.7 FAQ

**Q1:为什么音频回调是"心脏"?**
声卡以物理采样率取数,回调时点=真实时间基准(:2533);视频/外时钟都向它对齐(compute_target_delay,:1580)。

**Q2:seek 会不会撞上正在解码的线程?**
不会:seek 只置 SeekReq 信箱,由读线程单点执行(:3093-3122);解码线程靠 serial 隔代自动丢弃旧包(:503)。

**Q3:帧队列为什么固定 3?**
背压最快触发、内存可预算(:3256-3260);keep_last(:789-802)保证当前帧不被释放。

**Q4:音画差多少会被听到?**
阈值=硬件缓冲时长(:2801),低于此不干预;超过则 ±10% 微变速(:2487)——短促偏差靠重复/丢帧吸收,长期偏差靠变速。

**Q5:framedrop 丢的是解码帧还是显示帧?**
两级:解码后按 dpts 落后丢(:1843-1854),显示迟到丢(:1691-1698);默认只做后者。

**Q6:外部时钟(EXTERNAL_CLOCK)什么时候用?**
`get_master_sync_type`(:1477):音频缺席(无声视频)或跟随系统时钟场景——extclk 变成主。

**Q7:退出时网络阻塞怎么办?**
abort_request 同时是 avio interrupt 回调的返回值(:1314,:2849):retry_transfer_wrapper(09 章)下一轮就退出,不需要等超时。

**Q8:硬解帧怎么显示?**
libplacebo/Vulkan 渲染器可零拷贝承接硬解表面(ffplay_renderer.c:540,707-719);默认路径 upload_texture 做下载+上传(:909-941)。

**Q9:为什么 ffplay 不用 av_interleaved 那套交织?**
播放器按流即时消费,无需跨流交织;mux 侧才需要(05 章)。

**Q10:subtitle 为什么队列最长(16)?**
字幕显示时长独立于视频节拍,需要更大缓冲避免抖动丢字幕(:3256-3260)。

## 21.8 小结与深挖方向

本章结论:**ffplay = "读线程+解码线程×3+音频回调心脏+信箱式控制"**,同步算法一句话:视频按 A-V 差伸缩显示间隔、音频用微变速吃掉长期漂移、frame_timer 累积制分摊误差。深挖:

1. compute_target_delay 阈值区间 [0.04,0.1] 的听视感来源与动态调整;
2. serial 隔代机制与 AVStream 内部 cur_dts 在 seek 后的一致性;
3. libplacebo 渲染路径的 HDR 色调映射(vs 15 章 swscale CMS);
4. sampq=9 与音频滤镜图批大小的耦合;
5. subtitle_thread 的 blitter 与硬字幕滤镜(11 章)的分工。

> 下一章:AVCodecParser——demux 与 decode 之间那层隐形的帧边界仲裁者。
