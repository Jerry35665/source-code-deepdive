# 第 17 章 · RTSP/RTP:控制与数据分离的实时传输

> 基线:commit `9f63b36a`。行号以 libavformat/ 为准。09 章讲过 RTMP 的"单 TCP 全复用",本章的对立面正是 RTSP:**控制面与数据面物理分离**——文本信令走一条 TCP,媒体数据每轨一对 UDP 端口。

## 17.0 全景:三通道架构

```
客户端                                    服务器
  │══ RTSP 控制通道(单 TCP)══════════════│  OPTIONS/DESCRIBE/SETUP/PLAY
  │   rtsp_hd(rtsp.h:228)                 │  文本,带 CSeq/Session
  │
  │── RTP 数据(每轨一个 UDP 端口)──────→│  rtsp.c:1670-1673 分配(j+=2)
  │←── RTCP 反馈(配对端口)──────────────│  SR 报文对时
  │
  │  [TCP 模式] RTP/RTCP 以 $+id+len16 交错块复用进控制通道
```

与 RTMP 对比:RTMP 把所有轨复用进一条 TCP(靠 channel id 分流),RTSP 给**每轨独立端口对**——丢包控制、jitter buffer、加密策略都可以按轨定制,代价是防火墙/NA T 穿透复杂。FFmpeg 两种都支持:UDP 直连或 TCP 交错。

## 17.1 客户端状态机:五步握手

播放路径的完整行号链:

```
ff_rtsp_connect(rtsp.c:1897) ── OPTIONS(:2149)──→ 探测服务器类型
ff_rtsp_setup_input_streams(rtspdec.c:721)
  ── DESCRIBE(:740)──→ SDP 文本
  │   ff_sdp_parse(rtsp.c:751):m= 行建轨(:502)
ff_rtsp_make_setup_request(rtsp.c:1599) 逐轨:
  ── SETUP(:1749)──→ TCP 协商 interleaved(:1712-1719)
  │                    UDP 协商 client_port(:1695-1699)
rtsp_read_play(rtspdec.c:527) ── PLAY(:573)──→ 数据开始流动
```

三个细节:①**Session id 只在为空时从响应抄写一次**(rtsp.c:1303-1304)——后续请求全部携带;②SDP 的 `m=` 行是"轨声明",每行生成一个 RTSPStream;③listen 模式(rtspdec.c:758)是反向状态机:服务器主动连入,走 ANNOUNCE→SETUP→RECORD——同一套消息,方向反转。

## 17.2 RTP 解包:头解析链与乱序重排

`rtp_parse_one`(rtpdec.c:678 起)一条链:头字段提取(:688-697)→ payload handler 分发(:742-746,注册表 :75-132)。UDP 世界没有 TCP 的可靠性,秩序靠自己:

- **序列号合法性窗口**:MAX_DROPOUT=3000、MAX_MISORDER=100(rtpdec.c:249,252-254)——偏离超过此窗口的包直接丢弃(防伪造/防回放);
- **乱序重排队列**:按 seq 插入排序缓冲,默认 500 包(rtpdec.h:39;逻辑 :774,:811,:838-913);TCP 交错模式自动禁用(rtsp.c:874-879)——TCP 自己保序,重排是纯开销。

## 17.3 PTS 三路径:谁说了算

RTP 时间戳是"媒体时钟 tick",不是 FFmpeg 的 PTS。`finalize_packet`(rtpdec.c:630)按优先级三选一:

```
① depacketizer 已设 PTS(内嵌时间戳的载荷,如 MPEG-TS over RTP)→ 直接用(:638)
② 收过 RTCP SR → NTP↔RTP 映射换算(:649-663)
   (int32_t) 差值运算防 32bit 回绕
③ 都没有 → base_timestamp 兜底(:665-675,首包起算)
```

RTCP SR(Sender Report)解析在 rtpdec.c:181:提取 SSRC、NTP 墙钟、RTP 媒体时钟三元组(:195-197),换算偏移 `rtcp_ts_offset`(:204-208);BYE 返回 -RTCP_BYE(:212)。**SR 是多轨同步的锚**:视频/音频轨各自的 RTP 时钟经 NTP 对齐后,跨轨才能对上——最终汇合在 rtsp.c:2507-2537 的跨轨同步逻辑。这一设计与 07 章"音频 PTS 以样本为 tick"呼应:RTP 音频轨时钟=采样率,视频轨=90kHz。

## 17.4 H264 打包/重组:对称的两半

**重组**(rtpdec_h264.c):

- FU-A 分片重组(:286-310):`nal = fu_indicator & 0xe0 | nal_type` 还原 NAL 头(:301)——**分片包不拼帧**,重组后靠 `need_parsing=AVSTREAM_PARSE_FULL`(:416)交给上层 parser 完成帧边界划分(AVC 起始码重排也是它);
- STAP-A 聚合包两遍重组(:207-263):一遍计数一遍拷贝;
- SDP 里的 `sprop-parameter-sets` base64 解码并前拼 4 字节起始码塞进 extradata(:168-181,起始码逻辑 :97-143,:131-138)——**参数集在会话建立时就位**,不等流内 SPS/PPS。

**打包**(rtpenc.c/rtpenc_h264_hevc.c):H264/HEVC 共用一个实现——小 NAL 用 STAP-A 聚合(marker 24,:87),大 NAL 切 FU-A(FU Indicator=28,:116-119,S/E 位循环 :168-177);通用 RTP 头写入在 rtpenc.c:364-383;视频 RTP 时钟固定 90kHz(rtpenc.c:169)。打包与重组共享同一套 FU-A 布局——**协议的两端在 FFmpeg 里是两份对称代码,改一头必须想起另一头**。

## 17.5 UDP vs TCP:两套数据接收路径

- **UDP**:每轨独立 socket,rtpdec 直收,乱序重排(17.2);
- **TCP 交错**:控制通道内混流,`$` 块检测在信令读取器内部(rtsp.c:1260-1268),数据侧取包循环 rtspdec.c:892-941——3 字节头(`$`+id+len16,:913-918),按 id 认轨(:931-936)。

## 17.6 mux 侧:ANNOUNCE/RECORD 推流

推流方向:SDP 由 `av_sdp_create`(sdp.c:877)从输出轨道生成,经 ANNOUNCE 发给服务器(rtspenc.c:80-87),随后 RECORD 开流(:112-125);TCP 模式写包用 4 字节长度头原地覆盖 `$` 头(rtspenc.c:154-177)。与播放状态机严格镜像。

## 17.7 保活与降级

会话维持:timeout/2 周期发 GET_PARAMETER/OPTIONS 心跳(rtspdec.c:1050-1065);**UDP 数据超时自动降级**:resetup_tcp 走 TCP 交错重试(:1024-1045)——防火墙挡 UDP 的企业网环境里,这个自动降级是"能播"与"黑屏"的分界线。

## 17.8 设计动机

1. **控制/数据分离**:信令要可靠(状态机不能乱),媒体要实时(丢包好过迟到)——两者 QoS 相反,必须分道;RTMP 用一条 TCP 换简单性,牺牲了丢包时的队头阻塞;
2. **每轨独立 SETUP**:轨是协商单元(端口、编码参数、加密各自定),SDP 的 m= 行与之对齐——协议模型天然支持轨道级增删;
3. **SR 对时是唯一可信源**:RTP 时间戳只有相对意义,墙钟锚点必须来自 RTCP——FFmpeg 的三路径兜底(17.3)是对"服务器不发 SR"这种现实妥协;
4. **降级链完整**:UDP 失败→TCP 交错,重排队列按传输模式启停——运行时自适应取代用户配置。

## 17.9 FAQ

**Q1:RTSP 为什么比 RTMP 更适合低延迟?**
UDP 数据面无队头阻塞、无 TCP 重传延迟;RTSP+RTP 可到亚秒级,RTMP 受 TCP 窗口拖累。

**Q2:乱序包窗口为什么是 500 包?**
rtpdec.h:39 的默认值:覆盖典型网络重排深度,同时限制内存;TCP 模式自动关闭(rtsp.c:874-879)。

**Q3:没有 RTCP SR 会怎样?**
PTS 退到 base_timestamp 兜底(rtpdec.c:665-675)——能播,但多轨同步漂移(各自起点无墙钟锚)。

**Q4:H264 FU-A 重组后的帧边界谁定?**
不是重组器:need_parsing=AVSTREAM_PARSE_FULL(rtpdec_h264.c:416)交给通用 parser 按起始码/片头划分——重组器只管把 NAL 拼完整。

**Q5:sprop-parameter-sets 是什么?**
SDP 里内联的 base64 SPS/PPS(rtpdec_h264.c:168-181):会话建立即有参数集,避免"等到流内 SPS 才能起播"的延迟。

**Q6:为什么视频 RTP 时钟固定 90kHz?**
rtpenc.c:169:90kHz=2^8×350 约数丰富、精度 11μs、覆盖 25/30/50/60fps 整数倍——RFC 3551 的行业惯例。

**Q7:TCP 交错模式怎么区分 RTP 和 RTCP?**
$ 块的 id 字段:每轨 RTP/RTCP 各占一个 channel id(SETUP 时 interleaved=0-1 协商,rtsp.c:1712-1719)。

**Q8:UDP 超时后会失败吗?**
不会,自动降级 resetup_tcp(rtspdec.c:1024-1045)——数据面静默切到 TCP 交错。

**Q9:listen 模式是干什么的?**
服务器主动连入的场景(摄像头推到 FFmpeg):反向状态机 ANNOUNCE→SETUP→RECORD(rtspdec.c:758)。

**Q10:心跳为什么用 GET_PARAMETER?**
比 OPTIONS 更轻,部分服务器只认它;timeout/2 周期(rtspdec.c:1050-1065)保证超时前至少一次重试。

## 17.10 小结与深挖方向

本章结论:**RTSP 族 = "文本状态机 + 每轨端口对 + SR 对时 + 对称打包/重组"**;它的复杂性都在信令,数据面反而简单。深挖:

1. 乱序重排队列的插入排序代价(:838-913)与实时场景的抖动上限;
2. SR 缺失时音频/视频轨 PTS 漂移的量化(90kHz vs 48kHz 时钟漂移率);
3. RTCP APP/REMB 带宽反馈在 FFmpeg 的支持现状;
4. RTP over RTSP over TLS(sips/srtp)的栈叠放位置;
5. rtspenc 与 rtpenc_chain 的多轨会话复用(sdp.c:877 的轨道协商面)。

> 下一章:libavutil 工具箱——支撑这一切的地基货架。
