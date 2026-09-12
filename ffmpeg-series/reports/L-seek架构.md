# L 篇 · FFmpeg seek 跨格式架构深读

> 源码:FFmpeg master(commit 9f63b36a)。所有行号均在该 commit 下逐一核对。
> 本篇主线:`avformat_seek_file` 从公开 API 一路落到 avio 字节定位的完整链路。

---

## 1. 全景:一次 avformat_seek_file 的决策树

一次 seek 调用穿过四层:**API 层**(语义归一化)→ **generic 层**(libavformat 通用算法)→ **demuxer 层**(容器私有索引)→ **avio 层**(字节定位)。核心代码几乎全部集中在 libavformat/seek.c(760 行)。

```text
avformat_seek_file(s, st_idx, min_ts, ts, max_ts, flags)     seek.c:664
│  参数校验 min_ts<=ts<=max_ts                               seek.c:670
│  seek2any→加 AVSEEK_FLAG_ANY;剥掉 BACKWARD                 seek.c:675-677
│
├─ demuxer 有 read_seek2?(demux.h:177,目前只有字幕类/concat/imf)
│   └─ 是 → ff_read_frame_flush → (单流时 min/max_ts 重采样到流时基)
│          → read_seek2(...)                                 seek.c:679-701
│
└─ 否 → 模拟老 API:ts 离 min/max 哪边远就加 BACKWARD          seek.c:705
    av_seek_frame(s, st_idx, ts, flags|dir)                  seek.c:641,706
    │  demuxer 只有 read_seek2 没 read_seek?→ 反向桥接回新 API seek.c:646-654
    │
    seek_frame_internal(s, st_idx, ts, flags)                seek.c:597
    ├─ flags & AVSEEK_FLAG_BYTE → seek_frame_byte            seek.c:603-607
    │    (格式带 AVFMT_NO_BYTE_SEEK 则拒绝;clamp 后直接 avio_seek) seek.c:505-524
    ├─ stream_index == -1 → av_find_default_stream_index      seek.c:610-611
    │    + timestamp 从 AV_TIME_BASE 换算到流时基              seek.c:617-618
    ├─ demuxer 有 read_seek?→ flush 后直接交给容器             seek.c:622-628
    │    (mov.c:12525 / matroskadec.c:5049 / hls.c:3189 ...)
    └─ 没有 read_seek → 按 AVFMT_NOBINSEARCH / AVFMT_NOGENSEARCH
         兜底:
         ├─ 有 read_timestamp 回调 → ff_seek_frame_binary     seek.c:630-633
         │    (mpegts.c:3887 的 mpegts_get_dts 走这条)
         └─ 否则 → seek_frame_generic(边读边建索引)           seek.c:634-636
              最终都要落到 → avio_seek                         aviobuf.c:236
              缓冲内挪指针 / 前向读填充 / 真正调 s->seek
              → AVIOContext.seek = ffurl_seek2                 avio.c:489-492
              → prot->url_seek(URLProtocol,如 http.c:2303)    avio.c:645-652
```

要点:read_seek2 是"新区间 API"(min/ts/max 三点约束),read_seek 是"老单点 API";两边互为桥接(seek.c:646-654 向上桥、seek.c:705-711 向下桥,后者失败时还会用 max_ts/min_ts 各试一次再回到 ts)。

---

## 2. API 语义专节:参数与 flags 的精确含义

### 2.1 四个 flag(avformat.h:2618-2621)

```c
#define AVSEEK_FLAG_BACKWARD 1 ///< seek backward
#define AVSEEK_FLAG_BYTE     2 ///< seeking based on position in bytes
#define AVSEEK_FLAG_ANY      4 ///< seek to any frame, even non-keyframes
#define AVSEEK_FLAG_FRAME    8 ///< seeking based on frame number
```

注意:本 commit 中**不存在** `AVSEEK_FLAG_TARGET_TIMESTAMP`(全仓 `git log -S` 亦无痕迹);avio 层另有 `AVSEEK_SIZE 0x10000`(avio.h:468)与 `AVSEEK_FORCE 0x20000`(avio.h:476),后者在 avio_seek 入口被剥离(aviobuf.c:243)。

- **BACKWARD**:统一含义是"落到目标之前的关键帧"。它不是方向开关,而是"没有精确命中时选前驱还是后继"。索引查找里表现为 `m = (flags & BACKWARD) ? a : b`(seek.c:163,a/b 是二分夹出的前/后边界);二分 seek 收尾同样按它选 pos_min/pos_max(seek.c:491-492)。`avformat_seek_file` 会把它剥掉(seek.c:677),改由 min_ts/max_ts 表达方向意图,再在回落老 API 时按"ts 离哪端远"重推出来(seek.c:705)。
- **BYTE**:timestamp 字段装的是**文件字节位置**而非时间。走 `seek_frame_byte`:clamp 到 `[data_offset, avio_size-1]` 后直接 `avio_seek`,并置 `s->io_repositioned = 1`(seek.c:505-524)。带 `AVFMT_NO_BYTE_SEEK`(avformat.h:506)的格式(如 mov,mov.c:12518)在入口就被拒(seek.c:603-605)。
- **ANY**:把非关键帧也当可落点。索引查找会跳过"向后找关键帧"的循环(seek.c:165-168 只在无 ANY 时执行);HLS 中 ANY 表示不做"对齐分片起点"的快照(hls.c:3005-3007 判断 `!(flags & AVSEEK_FLAG_ANY)`)。`AVFormatContext.seek2any`(avformat.h:1804)可全局强制加此 flag(seek.c:675-676)。
- **FRAME**:以帧号为坐标系(avformat.h:2463 的文档说明),实际 demuxer 中极少支持。

### 2.2 stream_index、时间单位与默认轨

- stream_index == -1 时,`seek_frame_internal` 调 `av_find_default_stream_index`(avformat.c:469-502)选默认轨:打分制——视频 +25、有分辨率再 +50、attached_pic 封面 -400、音频有采样率 +50、探测期已见帧 +12、未被 discard +200。选中后 timestamp **从 AV_TIME_BASE 单位重采样到该流 time_base**(seek.c:616-618)。
- stream_index 合法时,timestamp 以该流 time_base 为单位(avformat.h:2444-2447 文档)。
- `avformat_seek_file` 走 read_seek2 且**只有一条流**时,min/max/ts 三值一起从 AV_TIME_BASE 重采样到流时基,min 向上取整、max 向下取整以保持区间安全(seek.c:683-693);多流时 read_seek2 的实现者自行处理(ts 单位仍是 AV_TIME_BASE,见 demux.h:177 文档)。

### 2.3 min_ts / max_ts(max_ts 语义)

`avformat_seek_file` 的文档写明目标是"所有活动流都能成功呈现、且结果落在 [min_ts, max_ts] 内、尽量接近 ts"(avformat.h:2493-2496)。参数合法性检查是 `min_ts > ts || max_ts < ts` 直接返回 -1(seek.c:670-671)。对只支持 read_seek 的老 demuxer,ffmpeg 用"dir 启发 + 最多三次 av_seek_frame"模拟区间语义:先朝远端方向 seek ts;失败且端点不同,再 seek 到 dir 端,成功后反向补一次(seek.c:705-711)。

---

## 3. generic 二分 seek 专节:ff_seek_frame_binary

适用对象:没有 read_seek 但提供 `read_timestamp` 回调的格式(demux.h:132-133,回调语义"从 *pos 开始向前读,返回下一个时间戳")。典型代表是 MPEG-TS(mpegts.c:3887)。

### 3.1 流程图

```text
ff_seek_frame_binary(s, st_idx, target_ts, flags)            seek.c:290
│  用现成索引夹边界(seek.c:312-343):
│    BACKWARD 查找 → pos_min/ts_min(<=target 的最后关键帧)    seek.c:317-326
│    前向查找     → pos_max/ts_max/pos_limit(>=target 最近项) seek.c:331-342
│    (pos_limit = pos_max - min_distance,保护最后一个关键帧   seek.c:339)
│
│  ff_gen_search(...)                                        seek.c:345
│    ts_min 无值 → 从 data_offset 读第一个 ts                  seek.c:413-418
│    ts_min >= target → 直接返回 pos_min                      seek.c:420-423
│    ts_max 无值 → ff_find_last_ts 从文件尾倒着探              seek.c:425-429
│                   (步长 1024 翻倍,seek.c:360-396)
│    ts_max <= target → 直接返回 pos_max                      seek.c:431-434
│
│    while (pos_min < pos_limit)                             seek.c:439
│      ┌ 第 1 次插值:按 (target-ts_min)/(ts_max-ts_min) 线性映射
│      │   字节区间再减关键帧近似距离                          seek.c:448-450
│      ├ 插值不收敛(no_change==1)→ 纯二分 (pos_min+pos_limit)/2
│      │                                                     seek.c:451-453
│      └ 再失败 → 线性逐个扫(pos=pos_min)                     seek.c:454-457
│      pos 夹进 (pos_min, pos_limit]                         seek.c:459-462
│      ts = read_timestamp 回调(内部先包一层 wrap_timestamp)  seek.c:466
│                (包装函数 seek.c:281-288)
│      target<=ts → 收上界:pos_limit=start_pos-1, pos_max=pos seek.c:480-484
│      target>=ts → 收下界:pos_min=pos, ts_min=ts            seek.c:485-488
│
│  BACKWARD ? (pos_min,ts_min) : (pos_max,ts_max)             seek.c:491-492
│
│  avio_seek(s->pb, pos, SEEK_SET)                           seek.c:351
│  ff_read_frame_flush(s)                                    seek.c:354
│  avpriv_update_cur_dts(s, st, ts)                          seek.c:355
```

### 3.2 读-比较-回跳循环的本质

`ff_gen_search`(seek.c:398-503)不是教科书二分:容器里**读单位是变长的包流**,时间戳和字节位置之间没有解析关系,所以第一策略是"插值"(利用 ts-pos 局部线性假设,比纯二分少几次 I/O),插值点还要减去 `pos_max - pos_limit` 作为关键帧距离的保守修正(seek.c:446-450)。一旦两次落点没有推进(no_change 计数,seek.c:467-470),降级为二分,再降级为线性扫描——对应注释"bisection failed, can only happen if there are very few or no keyframes"(seek.c:455-456)。

边界条件:read_timestamp 在中途失败(读到坏包)直接判失败返回 -1(seek.c:476-479);ts 用 `AV_NOPTS_VALUE` 作哨兵;ts_min/ts_max 恰好夹住 target 时短路返回(seek.c:420-423、431-434),保证 while 循环内 `ts_min < target < ts_max` 恒成立(断言 seek.c:436)。

---

## 4. demuxer 专节:三种容器的三种答案

### 4.1 MOV/MP4:stbl 全量索引直接落点

mov 在 read_header 期间把每个 sample 的 (pos, dts) 建进 `sti->index_entries`,因此 seek 是纯查表:

- `mov_read_seek`(mov.c:12394-12448):先 `mov_seek_stream` 定目标轨 sample(mov.c:12407),随后两条路:`seek_streams_individually` 选项(默认开,mov.c:12457-12460)把其余轨按目标时间戳重采样后各自 `mov_seek_stream`(mov.c:12411-12428);否则用 `mov_find_next_sample`(mov.c:11809)跨轨按 DTS 交替推进、模拟交织读取顺序(mov.c:12436-12445)。
- `mov_seek_stream`(mov.c:12303-12383):先把 PTS 目标减去 `min_corrected_pts + dts_shift` 折到 DTS 时间轴(mov.c:12311-12312),处理 fMP4 时先 `mov_seek_fragment`(mov.c:12314);然后 `av_index_search_timestamp` 查表,若命中的不是可落点 sample,就逐步回退时间戳重查(处理 edit list 造成的 pts-dts 错位,mov.c:12321-12340)。查到后同步 stts/stsc 游标(mov.c:12346-12377)。
- 注册:`ff_mov_demuxer.read_seek = mov_read_seek`(mov.c:12525),flags 带 `AVFMT_NO_BYTE_SEEK | AVFMT_SEEK_TO_PTS`(mov.c:12518)——即 mov 只认 PTS seek、拒绝字节 seek。

### 4.2 Matroska:cues 惰性解析 + cluster 对齐

`matroska_read_seek`(matroskadec.c:4501-4567)的特点:

1. cues(索引)**延迟到第一次 seek 才解析**:`cues_parsing_deferred` 标志在读头时置 1(matroskadec.c:3434),seek 时补 `matroska_parse_cues`(matroskadec.c:4511-4514,解析函数在 2031)。
2. 无索引或目标超出范围 → 返回 -1,并且注释明说这是故意"allows proper fallback to the generic seeking code"(matroskadec.c:4557-4566):错误路径把 EBML 状态机复位(matroska_reset_status,matroskadec.c:846-865)后交还上层。
3. 目标落在索引尾部之外时,先 reset 到最后一个 cue 点、循环 `matroska_parse_cluster` 边读边补索引直到追上(matroskadec.c:4520-4529)。
4. 命中后 `matroska_reset_status(matroska, 0, index_entries[index].pos)` 把解析器挪到目标 **cluster 的 Level-1 元素**上(matroskadec.c:4545),清各轨音频子包缓冲(matroskadec.c:4536-4542),置 `skip_to_keyframe`/`skip_to_timecode` 让后续 read_packet 丢弃早于目标的包(matroskadec.c:4546-4554),最后 `avpriv_update_cur_dts`(matroskadec.c:4555)。注册于 matroskadec.c:5049。

### 4.3 MPEG-TS:没有 read_seek,全靠 read_timestamp + 边 seek 边建索引

mpegts 两个 demuxer 都**不注册 read_seek**,只注册 `read_timestamp = mpegts_get_dts`(mpegts.c:3887、3900),于是 `seek_frame_internal` 落到 `ff_seek_frame_binary`(seek.c:630-633)。`mpegts_get_dts`(mpegts.c:3783-3820)的实现:

```c
pos = ((*ppos  + ts->raw_packet_size - 1 - pos47) / ts->raw_packet_size)
      * ts->raw_packet_size + pos47;              // 对齐 188 字节包边界
ff_read_frame_flush(s);
if (avio_seek(s->pb, pos, SEEK_SET) < 0)
    return AV_NOPTS_VALUE;
...
while(pos < pos_limit) {
    int ret = av_read_frame(s, pkt);
    ...
    if (pkt->dts != AV_NOPTS_VALUE && pkt->pos >= 0) {
        ff_reduce_index(s, pkt->stream_index);     // 索引超限就减半
        av_add_index_entry(s->streams[pkt->stream_index],
                           pkt->pos, pkt->dts, 0, 0,
                           AVINDEX_KEYFRAME);      // 顺路建索引
        if (pkt->stream_index == stream_index && pkt->pos >= *ppos)
            ... return dts;
    }
}
```

(mpegts.c:3788-3816,节选 15 行内。)它把 pos 对齐到 TS 包边界(`pos47` 记录首包相位),真读包直到拿到 DTS——所以 TS 的二分 seek 每次探测都是"解一小段真实码流",代价高但通用。索引条目用 `ff_reduce_index`(seek.c:50-62)控制在 `max_index_size`(avformat.h:1650)以内。Ogg 也是这条路的变体:ogg_read_seek 包一层 keyframe_seek 标志后直接调 `ff_seek_frame_binary`(oggdec.c:981,附近 ogg_reset 于 971/983)。

---

## 5. seek 后状态修复:ff_read_frame_flush

每个 seek 分支执行前/后都会调用 `ff_read_frame_flush`(seek.c:716-744;调用点 seek.c:354、584、606、623、632、635、681)。它做四件事:

1. **清包队列**:`ff_flush_packet_queue` 释放 parse_queue / packet_buffer / raw_packet_buffer(avformat.c:139-147)——否则 seek 后先吐出的是旧位置的包。
2. **销毁解析器**:`av_parser_close(sti->parser)`,清 `last_IP_pts`、`last_dts_for_order_check`(seek.c:725-730)——B 帧/AVC 跨包缓冲全部作废。
3. **重置 cur_dts**:首 dts 尚未知时置 `RELATIVE_TS_BASE`(avformat_internal.h:105),否则置 `AV_NOPTS_VALUE` 即"未定原点"(seek.c:731-735)。之后 demuxer 层会用 `avpriv_update_cur_dts`(seek.c:37-48,demux.h:255;注意本版函数名是 `avpriv_update_cur_dts`,无 `ff_update_cur_dts`)把参考轨 timestamp 按 `av_rescale` 换算到**每条流各自的 time_base** 写进 `sti->cur_dts`(seek.c:43-46)——这是多轨 DTS 同步的锚点,mkv 在 matroskadec.c:4555、二分 seek 在 seek.c:355 都依赖它。
4. **清探测/重排缓冲**:`probe_packets` 重置、`pts_buffer[MAX_REORDER_DELAY+1]` 全 NOPTS、`skip_samples = 0`(seek.c:737-742)。

**B 帧与 BACKWARD 的关系**:解码器从任意点起播必须有可解的参考帧,所以索引查找和二分收尾在无 ANY 时都强制落在关键帧上:索引侧向后/向前walk 到 `AVINDEX_KEYFRAME` 条目(seek.c:165-168,flag 定义 avformat.h:628);二分侧用 pos_limit 保守收上界(seek.c:339、446-450);HLS 直接把目标快照到分片起点(hls.c:3005-3007)。调用方约定俗成"seek 时必须带 AVSEEK_FLAG_BACKWARD"正是为了让落点在目标之前的关键帧——不带时可能落到目标之后的第一关键帧,解出的首帧时间戳晚于请求值。

---

## 6. 网络 URL 的 seek:协议层三种命运

avio 层把字节 seek 转发给协议:`ffio_fdopen` 用 `avio_alloc_context(..., ffurl_read2, ffurl_write2, ffurl_seek2)` 构造 AVIOContext(avio.c:489-492);`ffurl_seek2` 调 `h->prot->url_seek`(avio.c:645-652;回调字段 url.h:79)。`avio_seek`(aviobuf.c:236-319)则是缓冲感知的:目标在缓冲窗口内只挪 `buf_ptr`(aviobuf.c:277-280);前向小距离直接 `fill_buffer` 读过去,不发起真 seek(aviobuf.c:281-289);小距离回退(<buffer/2)用"回跳+重读"伪装(aviobuf.c:290-301);否则真正调 `s->seek`(aviobuf.c:302-316)。`ff_configure_buffers_for_index`(seek.c:175-243)会按索引里相邻关键帧的 pos 间距放大缓冲与 `short_seek_threshold`(seek.c:230-242),这正是给网络流"减少真 seek 次数"的优化。不可 seek 协议:`s->seek` 为空时返回 `AVERROR(EPIPE)`(aviobuf.c:307-308),`avio_size` 返回 `ENOSYS`(aviobuf.c:337-338)。

- **HLS**:`hls_read_seek`(hls.c:2934,注册 hls.c:3189)。拒绝 BYTE 和被标记 `AVFMTCTX_UNSEEKABLE`(avformat.h:1288;hls.c:1170-1173 在直播无法回溯时打标)的流(hls.c:2945-2946)。关键动作是 **seek 前刷新播放列表**:对未 finished 的 playlist,若目标超出已加载窗口(或直播窗口头部已过期)且距上次加载超过最小重载间隔,重新 `parse_playlist`(hls.c:2971-2984,注释引 RFC 8216 6.3.4)。然后 `find_timestamp_in_playlist` 把时间戳映射到 sequence number(hls.c:3001-3003),视频且 BACKWARD 非 ANY 时把目标对齐到分片起点保证关键帧(hls.c:3005-3007,snapped_to_segment 于 3007)。随后对**每个** playlist:关连接、清缓冲、`pb->pos = 0`、对内嵌 TS/fMP4 子 demuxer 执行 `ff_read_frame_flush`(hls.c:3031-3044),重置 init section(hls.c:3049-3050)。
- **RTMP**:协议层就支持时间戳 seek——`rtmp_seek` 作为 `url_read_seek` 回调注册(rtmpproto.c:3244,函数 3019-3033),发 `seek` AMF 命令(`gen_seek`,rtmpproto.c:851-866),随后 `rt->flv_off = rt->flv_size`、`rt->state = STATE_SEEKING`(rtmpproto.c:3027-3029)等服务器从新时间点推流。上层 flv demuxer 另有 `flv_read_seek`(注册 flvdec.c:2000)按索引落点。
- **HTTP**:普通静态文件靠 Range 请求,`http_seek` 实现 url_seek(http.c:2266-2268,注册 2303),内部 `http_seek_internal` 重新定位并按需重连(http.c:2160)。
- **RTSP**:走 demuxer 层 `rtsp_read_seek`(rtspdec.c:1071,注册 1115),向服务器发 RTSP PAUSE/PLAY 重新协商时间点;demux.h:136-140 的 `read_set_state` 注释也点明这是"network-based format (RTSP)"的状态切换。
- 另有 `avio_seek_time`(aviobuf.c:1235-1252):对带 `read_seek` 的自定义 AVIOContext(如 rtp 解复用)做时间 seek 后重同步缓冲位置。

---

## 7. 设计动机:seek 为什么这么复杂

1. **两套坐标系**:用户说"第 30 秒",I/O 只认"第 N 字节"。有索引的格式(mov stbl、mkv cues、avi idx1)能在 O(log n) 内换算;没索引的格式(TS、Ogg、RM)只能靠 `read_timestamp` 回调做"读-比较-回跳"(seek.c:439-489),这就是 ff_gen_search 存在的理由。BYTE flag(seek.c:603-607)干脆把字节坐标暴露给调用方,作为逃生通道。
2. **关键帧墙**:视频压缩使得任意字节落点不可解,一切算法都在回答"目标之前最近的关键帧在哪"——索引查找的后退 walk(seek.c:165-168)、pos_limit 的保守修正(seek.c:339)、HLS 分片对齐(hls.c:3005)是同一件事的三种表达。AVSEEK_FLAG_ANY 存在是因为某些场景(如逐帧分析、CDG 字幕)确实想要非关键帧。
3. **B 帧重排**:PTS 与 DTS 错位,mov 必须先把目标从 PTS 折到 DTS 才能查表(mov.c:12311-12312);seek 后必须清空 `pts_buffer` 与解析器(seek.c:725-740),否则旧重排队列会污染新起点的时间戳。BACKWARD 的真实身份是"解码起点语义"而非"搜索方向"。
4. **多轨同步**:一次 seek 是全流事件。mov 要么逐轨独立落点、要么按交织顺序对齐(mov.c:12411-12445);`avpriv_update_cur_dts` 把参考轨时间广播到所有轨(seek.c:37-48);attached picture 队列 seek 后要重新排队(seek.c:659、699,实现在 demux_utils.c:87)。
5. **实时/流式协议没有"位置"**:HLS 的"位置"是 sequence number 且窗口在漂移(所以要 seek 前刷新列表,hls.c:2971-2984);RTMP/RTSP 的 seek 是服务器端命令而非本地 I/O(rtmpproto.c:3019、rtspdec.c:1071)。FFmpeg 的答案是把"能否 seek"做成能力协商(AVFMTCTX_UNSEEKABLE、AVIO_SEEKABLE、AVFMT_NO_*SEEK 三个 flag,avformat.h:504-506),让上层在同一套 API 下退化。

---

## 8. FAQ 素材

1. **av_seek_frame 和 avformat_seek_file 该用哪个?** 新代码用后者:区间语义 [min_ts, max_ts] 更稳;前者在有 read_seek2 无 read_seek 时会被桥接进新 API(seek.c:646-654),反向则由 seek.c:705-711 模拟。
2. **为什么 seek 完取的第一帧时间戳常常小于请求值?** 默认落关键帧:索引查找 BACKWARD 语义选前驱(seek.c:163),这是"能解"的代价。想精确到非关键帧加 AVSEEK_FLAG_ANY,但解码器可能解不出。
3. **seek 必须带 AVSEEK_FLAG_BACKWARD 吗?** 播放场景强烈建议;`avformat_seek_file` 内部会剥掉它改用 min/max_ts 表达(seek.c:677、705)。
4. **MP4 seek 是 O(1) 吗?** 查索引是 O(log n)(ff_index_search_timestamp,seek.c:132-173),无 I/O;但 fMP4 还要定位/加载 mfrag(mov.c:12314)。
5. **MKV 第一次 seek 为什么慢?** cues 被刻意延迟解析(matroskadec.c:3434、4511-4514),首次 seek 一次性付清解析成本;失败还会退回 generic seek(4557-4566)。
6. **TS 能精确 seek 吗?** 没有 read_seek,靠 mpegts_get_dts 探测 + 插值二分(mpegts.c:3783、seek.c:630-633);每次探测都要真实解包,精度受 PCR/DTS 采样限制。
7. **AVSEEK_FLAG_BYTE 什么时候能用?** 格式不得有 AVFMT_NO_BYTE_SEEK(seek.c:603-605),且语义是"落到该字节附近的下一个包",无关键帧保证。
8. **stream_index=-1 时 timestamp 单位是什么?** AV_TIME_BASE(微秒),内部会先选默认轨(avformat.c:469 打分制)再换算(seek.c:616-618);非 -1 时是所选流的 time_base。
9. **HLS 直播能 seek 吗?** 取决于 playlist 类型与窗口:不可回溯时 hls 会置 AVFMTCTX_UNSEEKABLE,hls_read_seek 直接 ENOSYS(hls.c:1170-1173、2945)。
10. **seek 后不 flush 会怎样?** av_read_frame 会先吐完旧位置的缓冲包并带着旧 parser 状态,时间戳错乱——所以每个分支都先 `ff_read_frame_flush`(seek.c:606、623、632、635)。

## 9. 深挖方向

1. **mov 的 edit list 与 seek**:mov_seek_stream 的回退循环(mov.c:12321-12340)如何处理 `min_corrected_pts`/`dts_shift` 与空编辑列表;音频 skip_samples 的精确补偿(mov.c:12387-12393、12414)。
2. **ff_gen_search 的插值退化实测**:对 CBR TS 与 VBR Ogg 分别统计插值/二分/线性三档的触发比例(no_change 计数,seek.c:445-470),量化"插值优于二分"的注释主张。
3. **索引内存治理**:ff_reduce_index 的"减半"策略(seek.c:50-62)与 max_index_size(avformat.h:1650)在长视频/TS 流下的索引精度损失。
4. **fMP4/HLS 交叉**:hls demuxer 内嵌子 demuxer 的 seek 双层刷新(hls.c:3031-3044)与 `mov_seek_fragment`(mov.c:12314)在 DASH 场景的一致性。
5. **read_seek2 的收敛现状**:目前仅字幕类与 concat/imf 实现区间 seek(如 concatdec.c:964、imfdec.c:1045),可调研 mov/mkv 迁移 read_seek2 的可行性(mov 的 AVFMT_SEEK_TO_PTS 已是半步,mov.c:12518)。

---

## 写作要点速查表

| 主题 | 文件:行号 | 内容 |
|---|---|---|
| 公开 API | libavformat/seek.c:641 / 664 | av_seek_frame / avformat_seek_file |
| 老新 API 桥接 | seek.c:646-654, 705-711 | read_seek2<->read_seek 互相模拟 |
| 分派核心 | seek.c:597-639 | seek_frame_internal 三岔口 |
| 字节 seek | seek.c:505-524 | seek_frame_byte(clamp+avio_seek) |
| 索引二分 | seek.c:132-173 | ff_index_search_timestamp(163 BACKWARD,165-168 关键帧 walk) |
| 通用二分 | seek.c:290 / 398 / 360 | ff_seek_frame_binary / ff_gen_search / ff_find_last_ts |
| 插值循环 | seek.c:439-492 | 插值→二分→线性退化,收尾 BACKWARD 选择 |
| 状态清空 | seek.c:716-744 | ff_read_frame_flush(cur_dts 重置 731-735) |
| cur_dts 广播 | seek.c:37-48, demux.h:255 | avpriv_update_cur_dts |
| flags 定义 | libavformat/avformat.h:2618-2621 | BACKWARD/BYTE/ANY/FRAME(无 TARGET_TIMESTAMP) |
| 格式能力 flag | avformat.h:504-506, 520 | NOBINSEARCH/NOGENSEARCH/NO_BYTE_SEEK/SEEK_TO_PTS |
| demuxer 回调 | libavformat/demux.h:125 / 132 / 177 | read_seek / read_timestamp / read_seek2 |
| 默认轨 | libavformat/avformat.c:469-502 | av_find_default_stream_index 打分制 |
| mov seek | libavformat/mov.c:12394 / 12303 / 11809 / 12525 | read_seek / 单轨查表 / 交织对齐 / 注册 |
| mkv seek | libavformat/matroskadec.c:4501-4567 / 2031 / 5049 | cues 惰性解析+generic 兜底 |
| TS 兜底 | libavformat/mpegts.c:3783 / 3887 / 3900 | mpegts_get_dts 边 seek 边建索引 |
| avio seek | libavformat/aviobuf.c:236-319 | 缓冲内/前读/小回退/真 seek 四分支 |
| 协议转发 | libavformat/avio.c:489-492, 645-652; libavformat/url.h:79 | ffurl_seek2 -> url_seek |
| HLS seek | libavformat/hls.c:2934-3060 / 3189 | 刷新列表 2971-2984,分片对齐 3005-3007 |
| RTMP seek | libavformat/rtmpproto.c:3019 / 851 / 3244 | url_read_seek + AMF seek 命令 |
| HTTP seek | libavformat/http.c:2160 / 2266 / 2303 | Range 重定位 |
| RTSP seek | libavformat/rtspdec.c:1071 / 1115 | 服务器端协商 |
