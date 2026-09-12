# 第 13 章 · seek 跨格式架构:四层决策树与一次"有教育意义的试错"

> 基线:commit `9f63b36a`。行号以 libavformat/ 为准。本章调研纠正两个常见谬传:①`AVSEEK_FLAG_TARGET_TIMESTAMP` 在本 commit **不存在**(git log -S 零痕迹),公开 flag 只有四个(avformat.h:2618-2621);②`ff_update_cur_dts` 实为 `avpriv_update_cur_dts`(seek.c:37)。

## 13.0 全景:一次 seek 的四层决策树

```
avformat_seek_file(s, st, min_ts, ts, max_ts, flags)   seek.c:664
   │ 校验 min_ts<=ts<=max_ts(:670)
   │ demuxer 有 read_seek2(demux.h:177)?──是──→ 区间 seek 直通(:679-701)
   │ 否则:按 ts 离 min/max 哪端远,重推 BACKWARD(:705-706)
   ▼
av_seek_frame(st=-1 或指定, ts, flags)                  seek.c:641
   │                                        ┌ seek_frame_internal(seek.c:597)
   │  flags & AVSEEK_FLAG_BYTE ──────────────→ seek_frame_byte(:505)
   │  stream_index==-1 ──→ av_find_default_stream_index 打分(avformat.c:469)
   │                        微秒 → 流时基换算(:616-618)
   │  demuxer->read_seek 存在?──是──→ 直接委托(:622-628)
   │  否则按格式 flags(avformat.h:504-505):
   │     AVFMT_NOBINSEARCH ──→ seek_frame_generic(:636)
   │     其余 ──────────────→ ff_seek_frame_binary(:633)
   ▼
avio_seek(aviobuf.c:236)──→ AVIOContext.seek=ffurl_seek2(avio.c:489-492)
                              ──→ URLProtocol.url_seek(avio.c:645-652)
```

四层各司其职:**API 层**管区间语义,**分派层**管选轨与坐标系,**generic 层**管"没有索引怎么办",**avio 层**管字节真的去哪。

## 13.1 API 语义:四个 flag 与区间协商

公开 flag 四个(avformat.h:2618-2621):`BACKWARD`(允许落在目标之前)、`BYTE`(ts 实为字节位置)、`ANY`(跳非关键帧)、`FORWARD`。`avformat_seek_file` 的精髓是 **min_ts/max_ts 区间**:调用方承认"我接受 [min,max] 内的任何点",demuxer 若实现 `read_seek2`(目前仅字幕类/concat/imf,seek.c:679-701)可一步到位;否则 API 层"按 ts 离哪端远就往哪端贴"地重推 BACKWARD(:705-706),退化为 `av_seek_frame`——**区间协商是对旧 demuxer 的向下兼容垫**。反向桥接也存在:只有 read_seek2 的格式被 av_seek_frame 调用时按时间戳转发(:646-654)。

`stream_index=-1` 时选默认轨:`av_find_default_stream_index` 打分(视频优先,avformat.c:469),再把这个轨的时间戳换算到目标轨(:616-618)。**seek 永远有一个"参考轨"**,多轨同步由参考轨时间广播决定(见 13.4)。

## 13.2 generic 层:二分扫描,没有索引就现造一个

`ff_seek_frame_binary`(seek.c:290)先把已有索引条目夹出 `[pos_min, pos_max]`(:312-343);核心循环在 `ff_gen_search`(seek.c:398):

```c
/* seek.c:448-470(骨架):插值 → 二分 → 线性 三级退化 */
pos = ... 插值预测;  /* :448-450 */
if (no_change 计数超限) 退化为二分;   /* :453,467-470 */
再退化 → 线性步进;                    /* :457 */
每步:avio_seek(pos) → read_timestamp 回调 → 与目标比较 → 调整区间
收尾按 BACKWARD 选前驱/后继(:491)
```

read_timestamp 回调由 demuxer 提供(TS 的实现:mpegts_get_dts,mpegts.c:3783,包边界对齐并**顺路 av_add_index_entry 建索引** :3810-3811)。这就是 TS 的 seek 真相:**没有 read_seek 的格式,首次 seek = 一次带学习的线性/二分扫描,扫过的位置自动沉淀为索引**。

BACKWARD 的统一语义是二分方向选择:`m = BACKWARD ? a : b`(seek.c:163,收尾同理 :491)——保证结果落在目标时间**之前**。为什么必须向前:B 帧依赖前面的参考帧,跳到关键帧之后必花屏。

## 13.3 demuxer 层:三方各自的 seek

第 10 章的容器哲学在 seek 处完全显影:

```
MOV  read_seek=mov_read_seek(mov.c:12525;注册 flags 含
     AVFMT_NO_BYTE_SEEK|AVFMT_SEEK_TO_PTS :12518)
     └→ stbl 全量索引查表 + 关键帧回退(mov.c:12394,12320,12327)
MKV  matroskadec.c:4501-4566
     └→ 惰性解析 Cues(:3434,4511)→ cluster 对齐 → 关键帧门控
        失败退回 generic 扫描(兜底注释 :4557-4560)
TS   无 read_seek → 必走 ff_seek_frame_binary(seek.c:630-633)
     └→ 边读边建索引(mpegts.c:3810-3811)
```

`AVFMT_SEEK_TO_PTS`(mov.c:12518)值得单独解释:MOV 的索引按时间戳组织,seek 入参直接是 PTS;不带此 flag 的格式(多数)seek 语义是 DTS——**同一个 ts 参数,坐标系由格式 flag 声明**。

## 13.4 seek 后的状态修复:ff_read_frame_flush

跳转成功只是前半场,内部状态必须复位(`ff_read_frame_flush`,seek.c:716-744):清三重包队列、销毁各流 parser(B 帧重组缓存)、`cur_dts` 置 NOPTS 或 `RELATIVE_TS_BASE`(:731-735)、清 pts_window。随后 `avpriv_update_cur_dts`(seek.c:37)把参考轨时间**按各流 time_base 广播**到每个流——多轨同步的锚点就在这一行:所有流共享参考轨的绝对时间,各按自己的时间基换算。

## 13.5 网络 URL 的 seek 三态

- **HLS**:seek 前按 RFC 8216 重拉 playlist(hls.c:2971-2984),视频吸附分片起点(:3005-3007);对不可 seek 的直播流打 `AVFMTCTX_UNSEEKABLE`(avformat.h:1288)并在 seek 入口拒绝(hls.c:2945);
- **RTMP**:协议级 `url_read_seek` 回调发 AMF seek 命令给服务器(rtmpproto.c:3019,3244)——**seek 是服务器行为**,客户端只负责吞掉快进期间吐出的旧包(rtmpproto.c:2542-2547);
- **不可 seek 协议**:avio_seek 返回 EPIPE(aviobuf.c:307-308),generic 层自然失败——与本地文件统一处理,不设特例。

## 13.6 设计动机

1. **seek 复杂度是容器设计的罚金**:关键帧、B 帧重排、多轨、字节/时间戳双坐标系——四层决策树每一层对应一种复杂性;MOV 把索引做进容器,它的 seek 层几乎为零;TS 什么都不做,它的 seek 层最重。**成本守恒,只是记账位置不同**;
2. **generic 层是容器无关的兜底文明**:read_timestamp 回调让"毫无索引的流"也能 seek,且扫过即建索引(mpegts.c:3810-3811)——花一次线性扫描买断后续全部二分;
3. **BACKWARD 默认化是 B 帧物理**:解码器只能从过去构建未来,任何"精确命中"语义都必须让位于"落在目标之前"的现实约束;
4. **read_seek2 区间语义是新方向**:把"接受范围"交还调用方,消除 API 层的方向猜测(seek.c:705-706 的重推逻辑本质上是在模拟调用方意图)。

## 13.7 FAQ

**Q1:av_seek_frame 和 avformat_seek_file 什么关系?**
后者是区间版(:664),优先走 read_seek2;旧格式经方向重推退到前者(:705-706);两者可互相桥接(:646-654)。

**Q2:AVSEEK_FLAG_TARGET_TIMESTAMP 存在吗?**
不存在,本 commit 零痕迹。公开 flag 只有 BACKWARD/BYTE/ANY/FORWARD(avformat.h:2618-2621)——网上教程的第五个 flag 是老版本残留记忆。

**Q3:stream_index=-1 时 seek 谁的时间?**
先按打分选默认轨(视频优先,avformat.c:469),用它的时基换算 ts(seek.c:616-618),seek 后参考轨时间广播到全部流(seek.c:37)。

**Q4:BACKWARD 到底保证什么?**
保证落在目标**之前**——二分方向 m = BACKWARD ? a : b(seek.c:163,491)。与"就近"无关,方向性是物理约束(B 帧)。

**Q5:为什么 TS seek 第一次特别慢?**
无 read_seek 无索引:ff_seek_frame_binary 现场扫描,mpegts_get_dts 边读边把位置写进索引(mpegts.c:3783,3810-3811);第二次起就是二分。

**Q6:MKV 第一次 seek 卡顿和 TS 慢是一回事吗?**
不是。MKV 是回文件尾解析 Cues(matroskadec.c:4510-4514),一次性 I/O;TS 是从当前位置线性读流,可能读几十 MB。失败时 MKV 也退到 TS 同款扫描(:4557-4560)。

**Q7:seek 后 parser 的半包数据会污染新流吗?**
不会。ff_read_frame_flush 清三重包队列并销毁全部 parser(seek.c:716-744),cur_dts 复位(:731-735)——不 reset 就会把上一时间线的 B 帧缓存拼进新位置。

**Q8:RTMP 的 seek 是本地跳转吗?**
不是,是发 AMF seek 命令让服务器跳(rtmpproto.c:3244),客户端进入 STATE_SEEKING 吞包(:2542-2547)。网络协议的 seek 权在服务端。

**Q9:字节 seek 什么时候用?**
流损坏无时间戳时按字节找(avformat.h flag BYTE → seek_frame_byte,seek.c:505);MOV 显式禁用(AVFMT_NO_BYTE_SEEK,mov.c:12518),因为其索引只认时间戳。

**Q10:HLS 直播能 seek 吗?**
滑动窗口内的可以:重拉 playlist 定位(hls.c:2971-2984);无 ENDLIST 且窗口外则 AVFMTCTX_UNSEEKABLE 拒绝(:2945)——"可 seek 的范围"由服务器清单决定,不是客户端能力。

## 13.8 小结与深挖方向

本章结论:**seek = 一棵四层决策树,每层收容一类复杂性;generic 层的 read_timestamp 回调让"无索引"不再是 seek 的资格线**。深挖:

1. `ff_gen_search` 三级退化(插值→二分→线性,seek.c:448-457)的触发概率与 no_change 阈值调优;
2. `RELATIVE_TS_BASE`(seek.c:731-735)如何解决"流开头时间戳可为负"的表示问题;
3. 多轨 seek 的时间一致性:参考轨广播机制(seek.c:37)下音视频错帧的成因;
4. TS 自动索引的内存上限(av_add_index_entry 的 index 条目管理)与长视频膨胀;
5. AVFMT_SEEK_TO_PTS(mov.c:12518)下 DTS/PTS 混用 bug 的经典来源。

> 下一章:x264/x265 编码器封装——外部库如何被包成 AVCodec。
