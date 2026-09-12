# O 章 · ffmpeg CLI 转码管线与多线程调度(fftools/)

> 源码版本:master @ 9f63b36a。旧版 ffmpeg.c 是一个 6000+ 行的单线程"读包→解码→滤镜→编码→写包"大循环;现代 CLI 已完全重写为**每个环节一个线程、中央调度器居中**的管线。本章按运行时数据流讲述:调度器(ffmpeg_sched.c)→ 输入线程(ffmpeg_demux.c)→ 滤镜线程(ffmpeg_filter.c)→ 编解码线程(ffmpeg_dec/enc.c)→ 封装线程(ffmpeg_mux.c),外加 sync queue、streamcopy、-ss/-t 三条横切路径。
>
> 与前章衔接:B 章讲的 avcodec 是被 ffmpeg_dec/ffmpeg_enc 线程驱动的"从动件",C 章的 AVFilterGraph 被 ffmpeg_filter 线程驱动,A 章的 demuxer 跑在 ffmpeg_demux 线程里,I 章的封装格式写盘发生在 mux 线程的 `av_interleaved_write_frame()` 内。本章回答的是:**这些库组件如何被装配、被喂数、被限速、被关停**。

## 1. 全景:线程拓扑

`fftools/ffmpeg_sched.h:30-86` 的头注释是官方架构说明书:组件之间**只与调度器通信,彼此不直接通信**;整个转码结构是一张有向无环图(启动时检查无环,`fftools/ffmpeg_sched.c:1589`)。

```
                    ┌─────────────────────────── Scheduler (sch) ───────────────────────────┐
                    │  ffmpeg_sched.c: SchDemux/SchDec/SchEnc/SchFilterGraph/SchMux          │
                    │  schedule_update_locked(): 按 DTS 决定谁可以继续读 (choked/unchoke)      │
                    └───────────────────────────────────────────────────────────────────────┘
  输入文件 ×N              解码线程 ×K             滤镜图线程 ×G            编码线程 ×J        输出文件 ×M
 ┌─────────────┐   pkt   ┌──────────┐   frame  ┌──────────────┐ frame  ┌─────────┐  pkt  ┌───────────┐
 │ demux 线程 0 │────────▶│ dec 线程  │─────────▶│ filtergraph  │───────▶│ enc 线程 │──────▶│ mux 线程 0 │
 │ (input_     │  TQ(8)  │ (每路一个)│  TQ(2)   │ 线程 (每个图  │  TQ(2) │(每输出流 │ TQ(8) │ av_interleaved_
 │  thread)    │────────▶└──────────┘          │  一个线程)    │───────▶└─────────┘       │ _write_frame│
 └─────────────┘   pkt(直通)                    └──────────────┘                          └───────────┘
       │              │ streamcopy 不解码不滤镜,demux 包直接进 mux 的 pre-mux 队列        ▲
       │              └─────────────────────────────────────────────────────────────────┘
       │
  (每线程先在 sch_start() 里 pthread_create,见 ffmpeg_sched.c:1741-1795)
```

要点:
- **线程创建顺序**:mux(仅当流全部 ready)→ enc → filter → dec → demux(`fftools/ffmpeg_sched.c:1752-1795`),即从下游往上游拉起,避免上游先跑时无处可写。
- **队列类型与默认深度**:包队列 8(`fftools/ffmpeg_sched.h:257 DEFAULT_PACKET_THREAD_QUEUE_SIZE`),帧队列 2(`fftools/ffmpeg_sched.h:262`,且 `fftools/ffmpeg_sched.c:390` 断言帧队列不得超此值,因为解码器按固定 frame pool 计数)。mux 队列可被 `-thread_queue_size` 覆盖(`fftools/ffmpeg_opt.c:1805`、`fftools/ffmpeg_mux_init.c:3557`)。
- **主线程不再参与数据面**:`main()` 装配后只做 `sch_start → while(!sch_wait(...)) 轮询进度/键盘 → sch_stop → of_write_trailer`(`fftools/ffmpeg.c:901-949`)。

## 2. 调度器专节(ffmpeg_sched.c)

### 2.1 核心数据结构

| 结构 | 行号 | 作用 |
|---|---|---|
| `SchTask` | ffmpeg_sched.c:63-72 | pthread 封装:func/func_arg/线程句柄 |
| `SchDemux` + `SchDemuxStream` | 156-170 / 150-154 | 每个 demuxer 一个 waiter,每流一个 `dst[]` 目标数组 |
| `SchDec` | 80-98 | 输入 ThreadQueue + `queue_end_ts` 消息队列(向 demux 回传 flush 后结束时间戳) |
| `SchEnc` | 109-148 | 输入帧队列 + `open_cb`(首帧回调开编码器)+ 可选 sync queue 归属 `sq_idx[2]` |
| `SchFilterGraph` | 245-265 | 输入队列 `nb_inputs+1` 路(最后一路是控制流,收 filter 命令)+ waiter |
| `SchMux`/`SchMuxStream`/`PreMuxQueue` | 212-233 / 190-210 / 172-188 | mux 线程启动前的 pre-mux 包缓冲 FIFO |
| `Scheduler` | 273-312 | 五类节点数组 + `schedule_lock` + `finish_lock/finish_cond` + `last_dts` |

连接由 `sch_connect()` 建立(ffmpeg_sched.c:957):demux 流→dec/mux;dec 输出→filter 输入/enc;filter 输出→enc/另一 filter 输入;enc→mux/dec(回环解码器)。每条边在两端各记录对方,供 EOF 判定与 choke 回溯。

### 2.2 背压:谁阻塞谁

背压分两层:

**第一层:队列级阻塞(点对点)。** `tq_send()` 在队列满且接收端未完成时 `pthread_cond_wait` 睡眠(thread_queue.c:132-133):

```c
// fftools/thread_queue.c:132
while (!(*finished & FINISHED_RECV) && !av_fifo_can_write(tq->fifo_stream_index))
    pthread_cond_wait(&tq->cond, &tq->lock);
```

所以"队列满"的直接后果是**上游生产者线程阻塞在 tq_send**,链条:demux 满→dec 包队列(8)→ 阻塞 demux 线程;filter 输入满→dec 帧队列(2)→ 阻塞 dec 线程;enc 输出满→mux 包队列(8)→ 阻塞 enc 线程。demux→mux 的 streamcopy 直连路径多了第三级缓冲:pre-mux 队列 `mux_queue_packet()`,它只放大到 `max_packets`(达到 data_threshold 后生效,默认 `-thread_queue_size`),超限报 "Too many packets buffered for output stream" 并返回 `AVERROR_BUFFER_TOO_SMALL`(ffmpeg_sched.c:1973-2007)。

**第二层:全局 DTS 节流(choke 机制)。** 仅阻塞还不够——多输入时 ffmpeg 要求"所有输出流保持同速推进,即 DTS 大致对齐"(ffmpeg_sched.h:63-71)。`schedule_update_locked()`(ffmpeg_sched.c:1422-1513)在每次有流写入 mux 或收到 EOF 时执行:

1. `trailing_dts()` 取所有 mux 流中最慢的 dts(438-458);
2. 对每条未完成的 mux 流,若其 `last_dts` 落后 trailing 超过 `SCHEDULE_TOLERANCE`(100ms,ffmpeg_sched.c:45)则不解除其源;否则 `unchoke_for_stream()` 沿 `src` 链回溯到 demux 或含内源滤镜图,解除 waiter(1351-1390);
3. 保证至少放行一个源(`UNCHOKE_ONCE`,1484-1497),防饿死;
4. 差异更新 waiter 并对 demux 下游队列 `tq_choke()`(1392-1420,1499-1512)。

被 choke 的 demux 线程在 `sch_demux_send()` 入口 `waiter_wait()` 自旋等待,`terminate` 置位时返回 `AVERROR_EXIT`(ffmpeg_sched.c:320-337、2188-2190)。滤镜图的 choke 语义不同:choked 的滤镜线程改为从 `sch_filter_receive()` 拿 `EAGAIN` 去拉取自己的输出(read_frames 路径),即"不进新数据,但把已进的处理完"。

### 2.3 EOF 传播到全图

EOF 是逐级"发空帧/发 finish"向下传播的,任一节点所有下游都 EOF 后自身退出(`*_done` 系列):

```
demux 线程退出 → demux_done(): 每流 demux_send_for_stream(NULL)
  → 对 dec: tq_send_finish(dec.queue)      (ffmpeg_sched.c:2097)
  → 对 mux: send_to_mux(NULL) 即 source_finished=1  (ffmpeg_sched.c:2095)
dec 收 AVERROR_EOF → 发 EOF 哑帧(FRAME_OPAQUE_EOF, pts=末帧+dur)→ sch_dec_send
  (fftools/ffmpeg_dec.c:989-999) → send_to_filter/send_to_enc 携带 NULL → tq_send_finish
filter 收 EOF 帧 → send_eof(): av_buffersrc_close() 关 buffersrc (fftools/ffmpeg_filter.c:3119)
  → read_frames 收尾 → close_output(): sch_filter_send(NULL) (ffmpeg_filter.c:2749-2803)
enc 收 AVERROR_EOF → flush_encoder() 编完残余 → enc_done(): send_to_mux(NULL)
  (fftools/ffmpeg_enc.c:1085、ffmpeg_sched.c:2535-2549)
mux 收到所有流 EOF → sch_mux_receive 返回 stream_idx<0 → mux 线程退出
  → mux_done(): nb_mux_done++ 并 signal(finish_cond) (ffmpeg_sched.c:2280-2305)
主线程 sch_wait() 醒来,nb_mux_done==nb_mux → 返回 1 结束轮询 (ffmpeg_sched.c:1807-1830)
```

两个细节:① demux 级 seek 会发 `stream_index=-1` 的 flush 包走 `demux_flush()`(ffmpeg_sched.c:2135-2177,用于 `-stream_loop`),带 `send_end_ts` 的解码器会把 flush 后的结束时间戳经 `queue_end_ts` 消息队列回传(2307-2333);② sync queue 之后的 EOF 语义被 `send_to_enc_sq()` 特殊处理:必须显式把 `ms->source_finished=1` 通知调度器,否则 sq 等别的流时上游会卡死(ffmpeg_sched.c:1877-1905,作者自留 TODO)。

### 2.4 退出与错误

- 任一任务线程返回负错误 → `task_wrapper()` 置 `sch->task_failed=1` 并唤醒主线程(ffmpeg_sched.c:2734-2739);`sch_wait()` 见 `task_failed` 即返回 1(1823),主循环 break。
- `sch_stop()` 置 `terminate`,choke 所有 demux/滤镜 waiter 但 `choke_demux(...,0)` 解冻队列让在途包排空,再按 demux→dec→filter→enc→mux 顺序 join(ffmpeg_sched.c:2770-2826)。
- 信号:`sigterm_handler` 记 `received_nb_signals`,主循环检测后 break(ffmpeg.c:147-160、923-924);超过 3 个信号硬 `exit(123)`(ffmpeg.c:154-159);Windows CTRL_CLOSE 事件则阻塞等 `ffmpeg_exited`(ffmpeg.c:174-185)。退出码:信号 255、解码错误率超限 69(ffmpeg.c:1057-1058,错误率检查在 ffmpeg_dec.c:1007-1014)。
- trailer 始终由**主线程**在 `sch_stop` 后写:`of_write_trailer()`(ffmpeg.c:938-941 → ffmpeg_mux.c:752-788)。

## 3. demux 线程专节(ffmpeg_demux.c)

每个输入文件一个线程,入口 `input_thread()`(ffmpeg_demux.c:843),线程名 `dmx<N>:<format>`(813)。主循环只有约 70 行:

```c
// fftools/ffmpeg_demux.c:863-938(节选)
while (1) {
    ret = av_read_frame(f->ctx, dt.pkt_demux);
    if (ret == AVERROR(EAGAIN)) { av_usleep(10000); continue; }
    if (ret < 0) { /* EOF/错误:exit_on_error 决定是否致命 */
        ...
        if (d->loop) { /* -stream_loop: 发 stream_index=-1 flush 包再 seek_to_start */ }
        break;
    }
    ...
    ret = input_packet_process(d, dt.pkt_demux, &send_flags);  // ts_fixup/-t 判定
    if (d->readrate) readrate_sleep(d);                        // -re/-readrate 限速
    ret = demux_send(d, &dt, ds, dt.pkt_demux, send_flags);
    if (ret < 0) break;
}
```

- **队列深度**:demuxer 本身不建队列;它把包推给每个下游解码器的 `ThreadQueue`(深度 8,ffmpeg_sched.c:802)。对 mux 直连(streamcopy)则推 `PreMuxQueue`。所以"包队列深度"= 8(per demux→dec 边),阻塞点在 `sch_demux_send → tq_send`。
- **线程内循环职责**:时间戳修正 `ts_fixup`(390-479,含不连续检测 `ts_discontinuity_detect` 242-308)、`-t` 到点判定(497-505)、`-readrate` 限速睡眠(525-584)、BSF 链(715-747)、sub2video 心跳包(692-708)。
- **失败传播**:`do_send()` 收到 `AVERROR_EOF` 表示该流所有下游都完成,计 `nb_streams_finished`,全部完成则返回 EOF 结束线程(586-613);`AVERROR_EXIT`(收到终止信号)直接上抛;`exit_on_error` 时 demux 错误致命(881)。线程返回值经 `task_wrapper` 合并进 `task_failed`。
- EOF/EXIT 视为正常退出返回 0(941-943);退出后统计每流包数/字节 `demux_final_stats`(951-989)。

## 4. mux 线程专节(ffmpeg_mux.c)

### 4.1 何时开线程

mux 线程启动比其他节点复杂(ffmpeg_sched.h:210-251 有完整解释):编码器要等首帧才能初始化 → 调 `sch_mux_stream_ready()`(ffmpeg_mux.c:606-645 在 `of_stream_init` 里);一个 muxer 所有流 ready 后写 header(`mux_check_init`→`avformat_write_header`,ffmpeg_mux.c:550-570);若要写 SDP(rtp),必须等**所有** muxer 的 header 写完、SDP 落盘后再统一开线程,避免并发 header 抢 stderr 与 SDP 时序问题(ffmpeg_sched.c:1199-1233)。线程启动时 `mux_task_start()` 会按 DTS 从小到大把 pre-mux 队列里的积压包灌进 mux 队列(1135-1195)。

### 4.2 交织在 avformat 还是 fftools?

**在 avformat。** mux 线程不做交织算法,只循环:`sch_mux_receive()` 拿包(ffmpeg_mux.c:421)→ `mux_packet_filter()`(283:streamcopy 剪裁、`-fix_sub_duration` 心跳、输出 BSF)→ `write_packet()` 调 `av_interleaved_write_frame()`(231),交织缓冲与 max_delay 由 libavformat 完成。ffools 这层只做:时间基重缩放与非单调 DTS 修补(`mux_fixup_ts` 138-202)、文件大小上限 `-fs`(214)、mux 级 sync queue(`sync_queue_process` 245-278)。trailer/关文件在主线程(752-788)。

### 4.3 收尾判定

`sch_mux_receive` 返回 `pkt->stream_index<0` 表示"所有流都 EOF"(ffmpeg_mux.c:423-427,由 `receive_locked` 在全部流 finished 后给出,thread_queue.c:194);单流 EOF 则回写 `sch_mux_receive_finish()`(437),它同时把 `source_finished=1` 反馈进调度循环(ffmpeg_sched.c:2236-2252)。输出为空文件会在 trailer 阶段报错/警告(`check_written`,ffmpeg_mux.c:647-684)。

## 5. 滤镜图专节(ffmpeg_filter.c)

每个滤镜图(简单图 per 输出流、复杂图 per `-filter_complex`)一个线程,入口 `filter_thread()`(ffmpeg_filter.c:3443):

```c
// fftools/ffmpeg_filter.c:3467-3545(节选)
while (1) {
    input_status = sch_filter_receive(sch, sch_idx, &input_idx, fgt.frame);
    if (input_status == AVERROR_EOF) break;           // 调度器宣告全部输入结束
    ...
    if (fgt.frame->buf[0]) ret = send_frame(...);     // 真帧:查参数变化→进 buffersrc
    else ret = send_eof(&fgt, ifilter, ...);          // EOF 哑帧:关 buffersrc
    ...
read_frames:
    ret = read_frames(fg, &fgt, fgt.frame);           // 从 buffersink 拉帧送编码器
}
```

**喂数循环的本质是"推一帧、拉空、再选下一个最需要的输入"**:
- `sch_filter_receive()` 由调度器决定喂哪个输入(`best_input`,滤镜线程自报,ffmpeg_sched.c:2551-2599;滤镜图含 lavfi 源时 `in_idx=nb_inputs` 表示"不缺输入",用作速率控制,此时收到 `EAGAIN` 去执行 read_frames);
- `read_frames()`(2975-3033)清空各 `buffersink`(3001-3010),再 `avfilter_graph_request_oldest()`(3013);若 `EAGAIN` 则用 `choose_input()` 按各 buffersrc 的 failed_requests 计数挑最饿的输入(2462-2483),否则把 `next_in` 设为 `nb_inputs` 让调度器限速(3026-3029);
- **图无法继续推进的原因分类**:①某输入 EOF→`send_eof()` 关 buffersrc,带 EOF 时间戳;若图未配置且无 fallback 参数则报 "Cannot determine format of input ... after EOF"(3123-3160);②下游编码器 EOF(`sch_filter_send` 返回 EOF)→ 标 `eof_out`,该输出终止(2854-2864);③全部输出完成→ `read_frames` 返回 EOF 线程退出(3032);④参数变化→ `send_frame` 检出格式/分辨率/colorspace/矩阵/下混/hw_frames_ctx 变化,触发**图重配**(3190-3241,`ReinitReason` 3167;`-flags2 +dropchanged` 可改为丢帧 3229-3234)。重配不是推倒重建线程,而是 `configure_filtergraph()` 内 `cleanup_filtergraph` + 重建 AVFilterGraph(2159-2238),`check_reinit()`(3407)还支持按 pts 队列化的 `-enc_time_base` 类 reinit opts。
- 零帧输出兜底:`close_output()` 在从未出帧时构造纯参数哑帧初始化编码器(2749-2797),保证空图也能写 header。

## 6. 同步专节:sync queue 与 -shortest

`fftools/sync_queue.c` 实现多流时间戳对齐队列(684 行,独立于调度器):流分 **limiting**(限长)与非 limiting;队列保证任何流的输出不超过 limiting 流的头部时间戳(头注释 42-46)。

ffmpeg 有**两种** sync queue,接线在 `setup_sync_queues()`(ffmpeg_mux_init.c:2059-2159):

1. **编码前 sync queue(调度器内,SchSyncQueue)**:条件是 `-shortest` 且 ≥2 路编码 A/V、或有帧数上限流、或有固定帧长音频编码器(2103)。此时编码器的帧不直接进线程队列,而走 `send_to_enc_sq()`:发帧线程持 `sq->lock` 做 `sq_send` + 立即 `sq_receive` 转发给就绪的编码器线程(ffmpeg_sched.c:1877-1951);音频定长重排由 `enc_open` 回调返回 frame_size 后 `sq_frame_samples()` 生效(1832-1856)。多个编码器跨线程,所以必须由调度器统一加锁——注释明说(ffmpeg_mux_init.c:2092-2102)。
2. **mux 前 sync queue(muxer 内,`mux->sq_mux`,SYNC_QUEUE_PACKETS)**:存在 streamcopy 等额外交织流时启用(2128),在 mux 线程内单线程执行(`sync_queue_process`,ffmpeg_mux.c:245-278)。

`-shortest` 的实现位置因此是:把每个 A/V 编码流标记为 `limiting`(ffmpeg_mux_init.c:2119/2146),先到头的 limiting 流经 `finish_stream()` 反向把已超头的其他流也判定为 finished(sync_queue.c:161、253-259),其余流就此收尾——这就是"以最短流截断"。防卡死兜底:`overflow_heartbeat()` 在队列积压超过 `buf_size_us`(默认 `-shortest_buf_duration` 秒)时给滞后流注入假心跳(sync_queue.c:272-331,`sq_receive` EAGAIN 后重试 586-592)。

## 7. streamcopy 捷径路径

streamcopy 不建解码器也不建滤镜图, demux 流通过 `sch_connect(demux→mux)` 直连(ffmpeg_mux_init.c:1512 一带)。路径:

```
input_thread → demux_send → do_send → sch_demux_send
  → demux_stream_send_to_dst(dst=MUX) → send_to_mux → tq_send(mux.queue)
```

- `-t` 到点:demux 侧发 `DEMUX_SEND_STREAMCOPY_EOF` 标志,把包变成"仅 EOF 信号"发给 mux(ffmpeg_demux.c:497-505;调度器 ffmpeg_sched.c:2076-2080;标志定义 ffmpeg_sched.h:335-341)。
- mux 侧再过一遍剪裁:`of_streamcopy()`(ffmpeg_mux.c:455-498)跳过起始非关键帧(返回 `EAGAIN` 表示先丢弃,467-469)、按 `-ss` 的 `ts_copy_start`(ffmpeg_mux_init.c:1059-1062)与 `of->start_time` 丢头、整体平移 `ts_offset`。音频 streamcopy 的时间基精细重缩放用 `av_rescale_delta()`(ffmpeg_mux.c:143-156)。
- demux EOF 或 `-t` 触发的 `send_to_mux(NULL)` 把该流标 finished;若所有流都直通,`send_to_mux` 在 mux 线程启动前只入 pre-mux 队列。

## 8. -ss / -t 的实现位置

| 选项 | 输入级 | 输出级 |
|---|---|---|
| `-ss` | `ifile_open` 内 `avformat_seek_file` 真实 seek(dts 启发式回退 3AV_TIME_BASE/23,ffmpeg_demux.c:2468-2490;`-sseof` 折算 2441-2456);解码路径再叠加 trim:起始点由 `accurate_seek` 决定是否为 `AV_NOPTS_VALUE`(ffmpeg_demux.c:1293) | `of->start_time`(ffmpeg_mux_init.c:3523):转码路径作为滤镜图 `trim` 的 start(ffmpeg_mux_init.c:893 → ffmpeg_filter.c:1831/1910);streamcopy 路径在 `of_streamcopy` 丢头(ffmpeg_mux.c:478) |
| `-t` | `d->recording_time`:streamcopy 用 `DEMUX_SEND_STREAMCOPY_EOF`(ffmpeg_demux.c:497-505);解码用 `trim_end_us`(ffmpeg_demux.c:1295 → input trim 2049/2103) | `of->recording_time`(ffmpeg_mux_init.c:3522):输出滤镜 `insert_trim` 的 duration(ffmpeg_filter.c:1636 起,1831/1910 应用) |

即:**输入级 -ss 是"seek+trim",输出级 -ss/-t 是"滤镜图尾部插 trim 滤镜"**(insert_trim 在 simple 图的输出链尾、复杂图各输出与输入端分别插入,ffmpeg_filter.c:1831/1910/2049/2103)。`-to` 在输入级折算成 `-t`(ffmpeg_demux.c:2282-2290;输出级 ffmpeg_mux_init.c:3513),与 `-t` 同用时报错。trim 选项在 ffmpeg_opt.c:1596-1612 声明为 `OPT_INPUT|OPT_OUTPUT` 双栖。

## 9. 设计动机:为什么从单线程循环改成多线程

- **吞吐与并行**:旧 ffmpeg.c 一个大循环,任何一环(读盘/解码/滤镜/编码/写盘)慢都拖住全体,多核只能靠 codec 内部线程。新架构每 demuxer、每滤镜图、每解码器、每编码器、每 muxer 一个线程,天然并行;队列默认很小(8 包/2 帧)以保低延迟与低内存。
- **pull vs push 的取舍**:整体是**推(push)模型**——上游 `tq_send` 阻塞式下发,天然背压;但对"图内多输入谁先喂数"这种调度难题,采用**半拉模式**:滤镜线程通过 `sch_filter_receive(&input_idx)` 上报自己想要哪个输入、由调度器按 DTS 授权(demux/滤镜图还有 waiter-choke 闸门)。即"数据推、许可拉"。
- **DTS 中心化调度**:把"多输出流同速"的全局知识(各 mux 流 last_dts)集中到 `schedule_lock` 下的一处计算(ffmpeg_sched.c:1422),换取消除旧版散落各处的 `nb_interleaved/queue 饥饿` 修补;代价是每次发包要短暂拿全局锁(代码里留有 TODO 想用原子优化,2051)。
- **错误处理策略**:单任务失败不立即杀进程,而是 `task_failed` 唤醒主线程优雅停机(`sch_stop` 先 choke/解冻排空再 join),保证 trailer、进度统计、退出码一致;EOF 与错误严格区分(`err_merge`、`AVERROR_EOF` 视为成功,ffmpeg_sched.c:2731-2733)。
- **延迟测量内建**:包/帧携带 `FrameData.wallclock[]` 探针(demux/dec/filter/enc 各打点,ffmpeg_demux.c:510),`-debug_ts` 时 mux 端打印各阶段延迟占比(ffmpeg_mux.c:64-136)。

## 10. FAQ 素材

1. **ffmpeg 一条命令开多少线程?** 至少:每输入 1(demux)+ 每解码器 1 + 每滤镜图 1 + 每输出流 1(编码)+ 每输出 1(mux)+ 主线程;另有 codec/滤镜内部线程池(滤镜线程数由 `-filter_threads`/`-filter_nbthreads` 设,ffmpeg_filter.c:2176-2204)。
2. **`-thread_queue_size` 调大有什么用?** 只影响 mux 输入队列(demux→dec 队列固定 8,帧队列固定 2);对实时流/坏交织文件可缓解 "Too many packets buffered for output stream"(ffmpeg_sched.c:1987)。
3. **为什么 `-re` 时输入读得慢?** demux 线程内 `readrate_sleep()` 按 `readrate` 限速,追滞后可加速到 `readrate_catchup`(ffmpeg_demux.c:525-584)。
4. **Ctrl+C 后文件还能播吗?** 能:信号只置标志,主循环 break 后走 `sch_stop`(排空)+ `of_write_trailer`,trailer 由主线程写(ffmpeg.c:935-941)。
5. **`-shortest` 为什么有时多出几秒?** 它在 sync queue 层面按"流头部时间戳"截断,音视频帧粒度不同;且 mux 前 sq 与 enc 前 sq 触发条件不同(ffmpeg_mux_init.c:2087-2090),可配 `-shortest_buf_duration`。
6. **"Transcoding graph has a cycle" 是什么?** `-filter_complex` 输出再喂另一个图输入形成环,启动时 DFS 检查拒绝(ffmpeg_sched.c:1589-1623)。
7. **streamcopy 为什么也能用 `-t`?** demux 层用 `DEMUX_SEND_STREAMCOPY_EOF` 标志把到点后的包变成 EOF(ffmpeg_demux.c:497-505),mux 层 `of_streamcopy` 还有 `recording_time` 二次保险(ffmpeg_mux.c:463-465)。
8. **`q` 键退出原理?** 主线程 `check_keyboard_interaction` 读键返回 `AVERROR_EXIT` break,与信号同路(ffmpeg.c:846-849);`c` 键 filter 命令经 sch_filter_command 的"控制流"(ffmpeg.c:852-877 → ffmpeg_filter.c:3488-3497)。
9. **报错 "Empty output stream"?** trailer 阶段 `check_written` 发现该流 0 包(ffmpeg_mux.c:664-668);常见原因是 `-ss` 剪光了流或滤镜无输出。
10. **退出码 69 是什么?** 解码错误率超过 `-max_error_rate`(FFMPEG_ERROR_RATE_EXCEEDED,ffmpeg_dec.c:1009-1012 → ffmpeg.c:1057-1058)。
11. **滤镜线程和滤镜内部线程是什么关系?** 每张图 1 个 fftools 线程(喂数+收帧),图内 `AVFilterGraph->nb_threads` 另建 libavfilter 线程池做 filter 级并行(ffmpeg_filter.c:2176-2204);两层互不感知,ffools 线程只与 buffersrc/buffersink 交互。

## 11. 深挖建议

1. **调度公平性压力测试**:构造"视频快、音频坏交织"的输入,观察 `SCHEDULE_TOLERANCE`=100ms 与 pre-mux `max_packets` 交互下的 "Too many packets buffered" 触发时机(ffmpeg_sched.h:63-71 官方承认此局限)。
2. **回环解码器(`-dec` 参数,GROUP_DECODER)**:enc→dec 边(ffmpeg_sched.c:1113-1123)支撑 `-bsf` 探测/多视图场景,`sch_mux_sub_heartbeat` 心跳通道(2276-2278、ffmpeg_mux.c:304-313)可单独成节。
3. **`send_end_ts` 机制**:`-stream_loop` 下 demux flush 后音频结束时间戳如何经 `queue_end_ts` 回传并驱动 seek_to_start(ffmpeg_sched.c:806-810、2135-2177、ffmpeg_demux.c:887-898)。
4. **滤镜图重配的时序**:`send_frame` 检出参数变化 → `ifilter_parameters_from_frame` → 下次 `check_reinit`/configure 重开图,与帧队列深度 2 的相互作用(ffmpeg_filter.c:3243-3260、2159)。
5. **音频定长重排全链**:enc `open_cb` 返回 frame_size → `sq_frame_samples` → `receive_samples` 拆帧对齐(ffmpeg_sched.c:1832-1856 → sync_queue.c:640、428-500)。

## 附:写作要点速查表

| 主题 | 函数/宏 | 位置 |
|---|---|---|
| main 与装配 | main / ffmpeg_parse_options | ffmpeg.c:995 / ffmpeg_opt.c:1424 |
| 主循环 | transcode(sch_start/sch_wait/sch_stop) | ffmpeg.c:901-949 |
| 线程启动 | sch_start(下游→上游) | ffmpeg_sched.c:1741-1795 |
| 全局节流 | schedule_update_locked / trailing_dts | ffmpeg_sched.c:1422 / 438 |
| 阻塞原语 | tq_send(满则睡) | thread_queue.c:117-154 |
| demux 主循环 | input_thread / do_send | ffmpeg_demux.c:843 / 586 |
| demux -t 判定 | input_packet_process | ffmpeg_demux.c:497-505 |
| mux 线程 | muxer_thread / mux_check_init | ffmpeg_mux.c:402 / 550 |
| mux 时机 | sch_mux_stream_ready / mux_init(SDP) | ffmpeg_sched.c:1251 / 1199 |
| pre-mux 队列 | mux_queue_packet(超限报错) | ffmpeg_sched.c:1973-2007 |
| 滤镜线程 | filter_thread / read_frames / choose_input | ffmpeg_filter.c:3443 / 2975 / 2462 |
| EOF/重配 | send_eof(av_buffersrc_close) / send_frame | ffmpeg_filter.c:3104 / 3180 |
| 解码线程 | decoder_thread(sch_dec_receive) | ffmpeg_dec.c:909 |
| 编码线程 | encoder_thread(sch_enc_receive/flush) | ffmpeg_enc.c:1009 |
| enc 前 sync queue | send_to_enc_sq / setup_sync_queues | ffmpeg_sched.c:1877 / ffmpeg_mux_init.c:2059 |
| 队列深度 | DEFAULT_*_THREAD_QUEUE_SIZE | ffmpeg_sched.h:257/262 |
| streamcopy | of_streamcopy / DEMUX_SEND_STREAMCOPY_EOF | ffmpeg_mux.c:455 / ffmpeg_sched.h:340 |
| -ss/-t | ifile_open seek / insert_trim | ffmpeg_demux.c:2468-2490 / ffmpeg_filter.c:1636 |
| 收尾 | sch_stop / of_write_trailer / task_wrapper | ffmpeg_sched.c:2770 / ffmpeg_mux.c:752 / 2716 |
