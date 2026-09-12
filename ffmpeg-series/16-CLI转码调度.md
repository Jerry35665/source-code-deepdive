# 第 16 章 · ffmpeg CLI 转码调度:线程拓扑与背压

> 基线:commit `9f63b36a`。行号以 fftools/ 为准。FFmpeg CLI 已从"单线程大循环"演化为**由调度器串起的多线程流水线**——这是近十年最大的架构变迁,本章讲它的现状。

## 16.0 全景:线程拓扑

```
 主线程: 装配(ffmpeg.c main)→ sch_start → sch_wait(轮询)→ sch_stop → 写 trailer
                    │ ffmpeg_sched.c(调度器:五类节点+队列)
 ┌──────────┬──────┴───────┬─────────────┬──────────────┐
 │ 每输入文件 │  每解码器    │  每滤镜图   │  每输出文件   │
 │ demux线程 │  1 线程      │  1 线程     │  1 mux 线程  │
 │ (ffmpeg_ │  (ffmpeg_   │  (ffmpeg_  │  (ffmpeg_    │
 │  demux.c │   dec.c:909)│   filter.c │   mux.c:402) │
 │  :843)   │      │帧队列│   :3443)   │      ▲       │
 │    │包队列│      │深 2 │      │          │编码线程    │
 │    │深 8 ─┴→ 解码 ┴─→ 滤镜图 ─→ (ffmpeg_ ┘       │
 └──────────┘      帧        帧      enc.c:1009)      │
                        └─────────── 每输出流 ─────────┘
```

队列深度:包队列默认 8、帧队列默认 2(ffmpeg_sched.h:257/262;sched.c:390 断言帧队列不得超 2——与解码器 frame pool 计数耦合);两者都可被 `-thread_queue_size` 覆盖。线程按**下游→上游**顺序创建(sch_start,ffmpeg_sched.c:1741-1795):先 mux 后 demux,保证上游发送时下游必然就绪。启动前还有一道 DFS 环检查——转码图成环直接报 "Transcoding graph has a cycle"(:1589)。

## 16.1 调度器:全局节流与背压

背压有**两层**:

**第一层·队列级**:上游发包走 `tq_send`,队列满则 `pthread_cond_wait` 阻塞(thread_queue.c:132-133)——这是最朴素的背压,逐级向上传导。streamcopy 直连另有 pre-mux FIFO,超限报 "Too many packets buffered"(ffmpeg_sched.c:1973-2007)。

**第二层·全局 DTS 级**:每次发包/EOF 触发 `schedule_update_locked`(ffmpeg_sched.c:1422-1513):

```c
/* ffmpeg_sched.c(骨架) */
/* 以所有 mux 流中最慢的 trailing_dts 为基准 */
/* SCHEDULE_TOLERANCE=100ms(:45)内才 unchoke */
unchoke_for_stream(...);   /* 沿 src 链放行对应 demux/滤镜图 */
/* 被 choke 的 demux 在 sch_demux_send 入口阻塞(:2188) */
```

**为什么需要第二层**:队列级背压只保证"不爆内存",不保证"多输出进度均衡"——两个输出文件消费速度不同时,快的会拖着全系统跑,慢的流被甩开。DTS 级节流把整个图的推进锚定在最慢的 mux 流上,100ms 容差内的流才被放行。**这就是 `-shortest` 之外真正的"全局进度控制器"**。

## 16.2 demux 线程:70 行的主循环

每个输入文件一个线程,主循环意外地短(ffmpeg_demux.c:843-938):

```c
/* ffmpeg_demux.c(骨架,约 70 行) */
while (1) {
    ret = av_read_frame(ic, pkt);       /* 拉包 */
    ts_fixup(d, pkt);                   /* 时间基准修正 */
    readrate_sleep(d);                  /* -re 限速 */
    demux_send(d, thread_ctx, pkt);     /* 入队(可能阻塞) */
}
```

`-t` 的输入级截断在 :497-505 实现:到时后发 `DEMUX_SEND_STREAMCOPY_EOF` 标志,让 streamcopy 分支干净收尾。线程内的失败经队列传播为 EOF+错误码,不在循环里裸退。

## 16.3 mux 线程:交织仍在 avformat

**关键分工**:包的交织仍由 `av_interleaved_write_frame` 完成(ffmpeg_mux.c:231,首卷 05 章)——fftools 侧只做时间戳修正(mux_fixup_ts)、BSF 过滤与 sync queue;header 写出等**所有流的 `sch_mux_stream_ready` 就绪**才执行(ffmpeg_sched.c:1251,1199——SDP 场景下全部 muxer 统一开线程以共享 SDP);trailer 由主线程在 sch_wait 返回后写(ffmpeg.c:938-941 → ffmpeg_mux.c:752)。

## 16.4 滤镜图线程:喂与拉的双向循环

每个滤镜图一个线程(ffmpeg_filter.c:3443),循环体是三件事:

1. `sch_filter_receive`:等调度器递帧;
2. `send_frame`/`send_eof`:喂给 buffersrc——**参数变化(分辨率/像素格式突变)在此触发图重建**(:3180-3260,首卷 02 章 probe 重开机制的下游);EOF 用 `av_buffersrc_close`(:3119);
3. `read_frames`:从 buffersink 把输出拉空,然后 `choose_input`(:2462)挑"最饿"的输入继续喂——**饥饿驱动的轮转**,与 avfilter activate 的 ready 队列(首卷 04 章)在两个层次上做了同一件事。

## 16.5 同步:两级 sync queue 与 -shortest

多流不保证均衡产出(字幕流可能迟迟不来),sync_queue.c 提供带限额的汇聚点(:272):**两级部署**——编码器前(调度器内,跨线程加锁)与 mux 前(mux 线程内,ffmpeg_mux_init.c:2059-2159)。`-shortest` 的实现就是把 A/V 流标为 `limiting`(:2119,2146)——limiting 流到点即触发全组 EOF;`overflow_heartbeat` 防止某流永不产出导致死锁。

## 16.6 streamcopy 与 -ss

streamcopy 是贯穿全图的捷径:demux 出包**不进解码器、不进滤镜**,经 sync queue/BSF 直达 mux——这也是第一层 FIFO 特化它的原因。`-ss` 有两级(ffmpeg_demux.c:2468-2490):

- 输入级 `-ss`:打开后立即 `avformat_seek_file` 真实 seek(DTS 荒谬时的启发式回退 3AV_TIME_BASE/23);
- 输出级 `-ss`/`-t`:在滤镜链尾部 `insert_trim`(ffmpeg_filter.c:1636)丢帧截断。

前者省解码,后者精确到帧——**两级的组合是"快而准"转码的标准配方**。

## 16.7 EOF 与退出:逐级 tq_send_finish

EOF 传播是显式链:每类线程结束都 `tq_send_finish` 标记自己的队列,下游收到全 EOF 后同样向上传;mux 全流结束触发 `nb_mux_done++` 唤醒主线程(ffmpeg_sched.c:2280-2305)。主线程只等计数,不做广播——**退出协议是"计数倒计时"而非"信号风暴"**,不存在僵尸线程等另一个线程的环。

## 16.8 设计动机

1. **为什么改多线程**:旧单线程循环里,demux/decode/filter/encode/mux 轮流独占——任何一环慢,全管道空转;网络输入(-re 直播)尤其致命。多线程后每级独立节拍,吞吐由最慢级而非"最慢级+调度开销"决定;
2. **pull 与 push 的混合**:线程内是 push(队列),滤镜图内是 pull(read_frames 拉空)——队列解决跨线程解耦,pull 解决图内多输出的公平;两层背压是这种混合的代价与收益;
3. **调度器收权**:旧版把进度控制散在各循环的 if 里,新版收进 ffmpeg_sched.c 一个函数(schedule_update_locked)——全局策略必须住在全局唯一的地方;
4. **主线程退化为装配工**:main 只做 parse→build→start→wait→stop,全部运行时决策下沉——这与 K8s 控制面/数据面分离(第一系列 07 章)是同构思想。

## 16.9 FAQ

**Q1:转码时到底开了多少线程?**
每输入 1 demux + 每解码器 1 + 每滤镜图 1 + 每输出流 1 编码 + 每输出文件 1 mux(拓扑见 16.0);另有 avcodec 内部工作线程(首卷 08 章)与本拓扑正交。

**Q2:队列满了谁先停?**
最上游:队列级背压逐级传导,tq_send 的 cond_wait(thread_queue.c:132)最终阻塞 demux 线程;DTS 级 choke 则直接在 sch_demux_send 入口挡住(ffmpeg_sched.c:2188)。

**Q3:-thread_queue_size 调大有副作用吗?**
只影响内存与延迟,不影响正确性;调大可缓解读慢写快场景的抖动丢包警告。

**Q4:-shortest 精确吗?**
基于 sync queue 的 limiting 标记(ffmpeg_mux_init.c:2119),有 overflow_heartbeat 兜底;截断点在流边界而非帧边界,亚帧误差属正常。

**Q5:streamcopy 为什么快?**
跳过 decode/filter/encode 三级(包直达 mux),只过 BSF 与时间戳修正——队列与调度开销仍在。

**Q6:-ss 放 -i 前后有什么区别?**
放前是输入级真实 seek(ffmpeg_demux.c:2468-2490,快但只到关键帧);放后是滤镜尾部丢帧(ffmpeg_filter.c:1636,精确但要先解码)。

**Q7:滤镜图什么时候会重建?**
解码输出参数突变(流切换/动态分辨率)时,send_frame 处触发(ffmpeg_filter.c:3180-3260)——重建期间图内已缓冲帧丢弃。

**Q8:"Too many packets buffered" 是错误吗?**
是背压上限告警(ffmpeg_sched.c:1973-2007):streamcopy FIFO 超 max_packets,通常意味着某输出 mux 卡住(磁盘慢/网络慢)。

**Q9:两个输出文件会互相拖慢吗?**
DTS 级节流让全图锚定最慢输出(schedule_update_locked,sched.c:1422-1513)——会。追求独立吞吐应跑两个进程。

**Q10:主线程还做什么?**
装配、校验、sch_start、sch_wait 等待完成计数、sch_stop、写 trailer(ffmpeg.c:938-941)——运行时不参与数据面。

## 16.10 小结与深挖方向

本章结论:**CLI = "五类线程 + 两层背压 + 计数式退出"的调度器架构**;全局进度锚定最慢 mux 流是它最精妙的一笔。深挖:

1. schedule_update_locked 的 100ms 容差(SCHEDULE_TOLERANCE,ffmpeg_sched.c:45)对不同码率场景的适应性;
2. 帧队列深度 2 的硬断言(sched.c:390)与解码器 frame pool 的耦合细节;
3. 滤镜图重建期间的数据一致性(已缓冲帧的去向);
4. sync queue 两级部署的锁开销实测(enc 级跨线程 vs mux 级单线程);
5. 环检查 DFS(1589)对合法反馈拓扑(字幕延迟滤镜)的误判面。

> 下一章:RTSP/RTP——控制与数据分离的实时传输协议族。
