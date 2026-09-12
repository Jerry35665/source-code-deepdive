# P 章 | RTSP 与 RTP：控制与数据分离的实时传输协议族（FFmpeg 源码深读）

> 源码基线：libavformat，commit 9f63b36a（master）。本文所有行号均为该仓库相对路径下的实际行号。
> 行号速查总表见文末"写作要点速查表"。

---

## 1. 全景：一个会话，三条通道

09 章讲过 RTMP：一条 TCP 连接上"握手 + 信令 + 音视频数据"全部复用（flv 无真正的流描述）。RTSP 协议族走的是另一条设计路线——**控制面与数据面物理分离**：

```
 客户端                                        服务器
 ┌──────────┐  ① RTSP/TCP 554 (OPTIONS/DESCRIBE/  ┌──────────┐
 │          │◄─────SETUP/PLAY, 明文文本, CSeq────►│          │
 │  ffmpeg  │      控制通道, 一个会话只有一条        │  流媒体   │
 │  demuxer │                                     │  服务器   │
 │          │  ② RTP/UDP  client_port=N           │          │
 │          │◄═══════ 音视频负载(二进制) ══════════│          │
 │          │  ③ RTCP/UDP client_port=N+1         │          │
 │          │◄───── SR/RR 统计与时间映射 ─────────►│          │
 └──────────┘                                     └──────────┘
```

- 通道①：RTSP 信令，`RTSPState.rtsp_hd` 一个 TCP 句柄（libavformat/rtsp.h:228）。
- 通道②③：每个媒体轨一对 UDP 端口（RTP=偶数, RTCP=奇数），由 `ff_rtsp_make_setup_request` 中 `j += 2` 的端口分配逻辑体现（libavformat/rtsp.c:1670-1673），`RTSPTransportField.client_port_min/max` 描述（rtsp.h:103）。TCP 模式下②③退化进①，即交错帧（见第 5 节）。

三种 lower transport 在枚举 `RTSPLowerTransport` 中定义：UDP=0、TCP=1、UDP_MULTICAST=2（rtsp.h:39-52）。

与 RTMP 的关键差异：RTSP 的"流是什么"由 **SDP**（一个独立文本描述，DESCRIBE 响应体或 ANNOUNCE 请求体携带）声明，每轨独立 SETUP；RTMP 则在 `createStream`/`@setDataFrame` 中隐式携带。SDP 解析入口 `ff_sdp_parse`（libavformat/rtsp.c:751），逐行走 `sdp_parse_line`（rtsp.c:448）。

---

## 2. RTSP 客户端状态机专节：OPTIONS → DESCRIBE → SETUP → PLAY

demuxer 侧状态机全部收敛在 `rtsp_read_header`（libavformat/rtspdec.c:851）→ `ff_rtsp_connect`（libavformat/rtsp.c:1897）里，随后 `rtsp_read_play` 发 PLAY。命令收发由 `ff_rtsp_send_cmd`（rtsp.c:1525）统一完成：写入请求 → `ff_rtsp_read_reply` 等响应。

### 2.1 行号链（客户端播放路径）

| 步骤 | 函数 | 位置 | 说明 |
|---|---|---|---|
| 连接 TCP | `ff_rtsp_connect` | rtsp.c:1897 | 打开 `rtsp://host:554`（默认端口 rtsp.h:75） |
| 复位 CSeq | `rt->seq = 0` | rtsp.c:2113 | 每条命令自增后发送 |
| ① OPTIONS | `ff_rtsp_send_cmd("OPTIONS"...)` | rtsp.c:2149 | 响应用来探测服务器类型（Real/WMS，rtsp.c:2176-2181） |
| ② DESCRIBE | `ff_rtsp_setup_input_streams` | rtspdec.c:721，DESCRIBE 在 :740 | 响应体是 SDP，`ff_sdp_parse` 在 :750 解析 |
| SDP→轨 | `sdp_parse_line` 'm=' 分支 | rtsp.c:502-598 | 每个 m= 建 `RTSPStream`（rtsp.c:525-529）与 `avformat_new_stream`（rtsp.c:573） |
| ③ SETUP×N | `ff_rtsp_make_setup_request` | rtsp.c:1599，循环体 :1630 | **每轨一条** SETUP，`ff_rtsp_send_cmd("SETUP", rtsp_st->control_url, ...)` 在 rtsp.c:1749 |
| ④ PLAY | `rtsp_read_play` | rtspdec.c:527，PLAY 命令 :573 | 由 `rtsp_read_header` :879 或 `av_read_play` 触发 |

### 2.2 CSeq 与 Session id 的流转

- **CSeq**：请求里由 `ff_rtsp_send_cmd_with_content_async` 自动写入（rtsp.c:1444 起）；响应里 `ff_rtsp_parse_line` 解析 `CSeq:` 存入 `reply->seq`（rtsp.c:1152-1153）。listen/服务器侧还校验 `request->seq != rt->seq + 1`（rtspdec.c:163-167）。
- **Session id**：服务器在第一个 SETUP 响应中给出；客户端在 `ff_rtsp_read_reply_internal` 里**只在本地 session_id 为空时**抄写一次（rtsp.c:1303-1304），存入 `RTSPState.session_id[512]`（rtsp.h:253）。之后每条命令由 send_cmd 拼上 `Session:` 头。`Session: xxx;timeout=N` 的解析在同一处（rtsp.c:1141-1147），`timeout` 驱动后文的心跳保活（rtspdec.c:1050-1065）。
- 服务器检测到 session 不匹配会回 454（listen 侧 `check_sessionid`，rtspdec.c:129-145）。

### 2.3 内部状态 `RTSPClientState`

`IDLE / STREAMING / PAUSED / SEEKING`（rtsp.h:202-207），存于 `RTSPState.state`（rtsp.h:239）。`rtsp_read_play`（rtspdec.c:527）与 `rtsp_read_pause`（rtspdec.c:598）按状态决定是否真的发命令，避免重复 PLAY/PAUSE（注释见 rtsp.h:235-238）。seek 是"PAUSE→改 Range→PLAY"的合成：`rtsp_read_seek`（rtspdec.c:1071-1096）只暂存 `seek_timestamp`，PLAY 时拼成 `Range: npt=...`（rtspdec.c:568-572）。

### 2.4 listen 模式（推流到 ffmpeg 的反向状态机）

`RTSP_FLAG_LISTEN`（rtsp.h:460）时 `rtsp_read_header` 走 `rtsp_listen`（rtspdec.c:758）：bind TCP 等连接（:796-801），循环解析对端发来的请求行 `parse_command_line`（rtspdec.c:383），状态合法性校验在该函数 :419-442（IDLE 只认 ANNOUNCE/OPTIONS；PAUSED 只认 OPTIONS/RECORD/SETUP；STREAMING 只认 PAUSE/OPTIONS/TEARDOWN）。OPTIONS/ANNOUNCE/SETUP/RECORD 分别由 rtspdec.c:224/177/242/361 处理，其中 `rtsp_read_setup` 自行生成不少于 8 位的 session id（rtspdec.c:349-350，RFC 2326 要求）。

---

## 3. RTP 解包专节：从字节流到 AVPacket

每轨一个解包上下文 `RTPDemuxContext`（libavformat/rtpdec.h:148-191），在 `ff_rtsp_open_transport_ctx` 里由 `ff_rtp_parse_open` 创建（libavformat/rtsp.c:904-906），并把 SDP 阶段匹配到的动态 payload handler 注入（rtsp.c:914-918，SRTP 密钥 :919-922）。

### 3.1 一条解析链

总入口 `ff_rtp_parse_packet`（libavformat/rtpdec.c:925）：

```
ff_rtp_parse_packet (rtpdec.c:925)
 ├─ SRTP 解密(可选)              rtpdec.c:929
 ├─ rtp_parse_one_packet         rtpdec.c:838
 │   ├─ 版本校验 (V==2)          rtpdec.c:868  (RTP_VERSION=2, rtp.h:80)
 │   ├─ RTCP? → rtcp_parse_packet rtpdec.c:870-872 → :181
 │   ├─ 抖动统计 rtcp_update_jitter rtpdec.c:874-882 → :295
 │   ├─ 重排序决策               rtpdec.c:884-913
 │   │    首包/queue_size<=1 → 直接解析 :884-886
 │   │    乱序入队 enqueue_packet :900-901 (按 seq 有序链表, :774)
 │   │    太旧丢弃              :890-895
 │   └─ rtp_parse_packet_internal rtpdec.c:678
 │        ├─ 头字段解析          rtpdec.c:688-697  (PT/M/seq/timestamp/SSRC)
 │        ├─ 序列号合法性        rtpdec.c:705 → rtp_valid_packet_in_sequence :249
 │        │   (MAX_DROPOUT=3000, MAX_MISORDER=100, MIN_SEQUENTIAL=2, :252-254)
 │        ├─ padding/CSRC/扩展头剥离 rtpdec.c:712-740
 │        ├─ payload handler 分发 rtpdec.c:742-746 (s->handler->parse_packet)
 │        │   handler 注册表: rtp_dynamic_protocol_handler_list rtpdec.c:75-132
 │        │   查找: ff_rtp_handler_find_by_name/:154, find_by_id/:168
 │        └─ finalize_packet     rtpdec.c:756 → :630 (时间戳→PTS)
 └─ 排空重排队列                  rtpdec.c:933-935
```

### 3.2 时间戳 → PTS 的换算与 RTCP SR 校准（重点）

RTCP 复合包在 `rtcp_parse_packet`（rtpdec.c:181-220）处理：PT=200（RTCP_SR，rtp.h:99）时提取 **SSRC、64 位 NTP 时间戳、32 位 RTP 时间戳**（rtpdec.c:195-197）存入 `s->last_sr`；首个 SR 记录 `first_rtcp_ntp_time` 并计算 `rtcp_ts_offset = (int32_t)(rtp_ts - base_timestamp)`（rtpdec.c:204-208）。PT=203（BYE）返回 `-RTCP_BYE`（rtpdec.c:212-213），上层据此计 EOF（libavformat/rtsp.c:2539-2547）。

PTS 最终在 `finalize_packet`（rtpdec.c:630-676）确定，三条路径：

1. depacketizer 已设 pts/dts → 直接返回（rtpdec.c:638-639）；
2. **多流且收到过 SR**：用 NTP 映射统一时间轴（rtpdec.c:649-663）：

```c
delta_timestamp = (int32_t)(timestamp - s->last_sr.rtp_timestamp);
addend = av_rescale(s->last_sr.ntp_timestamp - s->first_rtcp_ntp_time,
                    s->st->time_base.den,
                    (uint64_t) s->st->time_base.num << 32);
pkt->pts = s->range_start_offset + s->rtcp_ts_offset + addend + delta_timestamp;
```

   NTP 是 64 位（高 32 秒/低 32 小数），左移 32 对齐 time_base.den 的写法即在此。同一 SR 也会以 `AV_PKT_DATA_RTCP_SR` side data 附到包上（rtp_add_sr_sidedata，rtpdec.c:614-624；挂载点 :632-636），并生成 producer reference time（rtp_set_prft，rtpdec.c:594-612）。
3. **无 SR 的兜底**：以首包 timestamp 为 `base_timestamp`，用 `(int32_t)` 差值防回绕累加出 `unwrapped_timestamp`，`pts = unwrapped - base_timestamp + range_start_offset`（rtpdec.c:665-675）。

多轨同步的粘合：任一轨先拿到 SR 后，`ff_rtsp_fetch_packet` 会把 `first_rtcp_ntp_time`/`rtcp_ts_offset` 按 time_base 换算复制给其余轨（libavformat/rtsp.c:2507-2529），并填充 `s->start_time_realtime`（rtsp.c:2531-2537）。

### 3.3 反向 RTCP：RR、PLI、NACK 与保活

- Receiver Report 每"收到的字节×5/1000÷50"字节发送一次（rtpdec.c:334-339，比例常数 rtp.h:84-85），构造于 `ff_rtp_check_and_send_back_rr`（rtpdec.c:313-413），UDP 读包路径每次成功读取后调用（rtsp.c:2398）。
- 乱序/丢包时发 PSFB(NACK)/PLI 反馈：`ff_rtp_send_rtcp_feedback`（rtpdec.c:469-531，PLI :502-509、NACK+missing_mask :511-520），仅在 SDP 协议为 AVPF 时启用（`rtsp_st->feedback`，rtsp.c:549-550 与 2498-2503）。
- NAT 打洞：PLAY 前对 UDP socket 发最小 RTP+RR 空包 `ff_rtp_send_punch_packets`（rtpdec.c:415-437，调用点 rtspdec.c:537-548）。

---

## 4. H264 打包/重组对称专节（RFC 3984）

解包器文件头注释明确：只支持 Single NAL（mode 0）与 Non-Interleaved（mode 1），不支持 Interleaved（libavformat/rtpdec_h264.c:29-34）。

### 4.1 重组侧 rtpdec_h264.c

分发函数 `h264_handle_packet`（rtpdec_h264.c:313-375），按 NAL 头低 5 位 type 分派：

| type | 含义 | 处理 |
|---|---|---|
| 1-23 | 单 NAL | 前补起始码 00 00 00 01（`start_sequence`，:66）后整体拷出，:331-341 |
| 24 | STAP-A 聚合 | `ff_h264_handle_aggregated_packet`，两遍法（先算总长再拷贝），每个子 NAL 2 字节长度前缀，:207-263，分派点 :343-349 |
| 25/26/27/29 | STAP-B/MTAP/FU-B | 不支持，:351-357 |
| 28 | FU-A 分片 | `h264_handle_packet_fu_a`，:286-310，分派点 :359-362 |

FU-A 重组核心（rtpdec_h264.c:297-301）：

```c
fu_indicator = buf[0];
fu_header    = buf[1];
start_bit    = fu_header >> 7;        /* S 位 */
nal_type     = fu_header & 0x1f;      /* 原 NAL type */
nal          = fu_indicator & 0xe0 | nal_type;  /* 还原 NAL 头 */
```

起始分片写 4 字节起始码+还原的 NAL 头，后续分片只追加裸数据（`ff_h264_handle_frag_packet`，rtpdec_h264.c:265-284）。注意 FU-A 的"包间重组"并不在 rtpdec_h264 里缓存——每个 FU 分片直接成为一个 AVPacket（必要时含起始码），真正的帧拼接交给 `need_parsing = AVSTREAM_PARSE_FULL` 的上层解析器（rtpdec_h264.c:416）。

**sprop 参数集注入**：SDP `a=fmtp:... sprop-parameter-sets=<SPS b64>,<PPS b64>` 在 `sdp_parse_fmtp_config_h264` 的 `sprop-parameter-sets` 分支（rtpdec_h264.c:168-181）被解码为 extradata：`ff_h264_parse_sprop_parameter_sets`（:97-143）逐段 base64 解码（:117），每段前拼 4 字节起始码后追加进 `par->extradata`（:131-138）。`profile-level-id` 解析在 :68-95，`packetization-mode` 在 :152-164。SDP a= 行进入该函数的入口是 handler 的 `parse_sdp_a_line = parse_h264_sdp_line`（:390-410），由 rtsp.c:740-744 的通用回调触发。

### 4.2 打包侧 rtpenc_h264_hevc.c（H264 与 HEVC 共用）

入口 `ff_rtp_send_h264_hevc`（rtpenc_h264_hevc.c:181-211）：用起始码扫描（AnnexB，:189-191）或长度前缀（avcC，`nal_length_size`，由 rtpenc.c:216-221 从 extradata[0]==1 判定）切出 NAL，逐个 `nal_send`（:207）。

`nal_send`（rtpenc_h264_hevc.c:56-179）与解包严格对称：

- 小 NAL（≤max_payload_size）：优先聚合为 **STAP-A**——缓冲区首字节写 24（:87），随后"2 字节长度+NAL"逐个排队（:93-97），凑不下或收尾时 `flush_buffered`（:37-54）发出；只有一个 NAL 时退化为单 NAL 直发（:43-49）。
- 大 NAL：**FU-A** 切片（:112-124 建头）：

```c
s->buf[0] = 28;             /* FU Indicator, Type=28 */
s->buf[0] |= nri;           /* 继承原 NRI */
s->buf[1] = type | 1 << 7;  /* FU header: S=1 + 原 type */
...
while (size + header_size > s->max_payload_size) {   /* :168 */
    ff_rtp_send_data(s1, s->buf, s->max_payload_size, 0);  /* 中间片 M=0 */
    s->buf[flag_byte] &= ~(1 << 7);      /* 清 S 位 */
}
s->buf[flag_byte] |= 1 << 6;             /* 置 E 位 */   /* :175 */
ff_rtp_send_data(s1, s->buf, size + header_size, last); /* 末片带 M */
```

- RTP 通用头的写与序号自增在 `ff_rtp_send_data`（libavformat/rtpenc.c:364-383，M 位由调用方传入）。

---

## 5. UDP vs TCP 专节：两条接收路径

`ff_rtsp_fetch_packet`（libavformat/rtsp.c:2418）是统一入口，下层分派在 `read_packet`（rtsp.c:2380-2416）。

### 5.1 UDP 路径（rtsp.c:2259-2334）

- 每个轨打开两个 socket fd（RTP+RTCP），加上 RTSP TCP fd 一起构成 pollfd 数组（rtsp.c:2270-2298），一个 `poll()` 同时监视所有通道（:2306）。
- 数据到来按 `p[j]/p[j+1]` 定位轨并 `ffurl_read`（:2309-2320）；RTSP TCP 上若有新消息则 `parse_rtsp_message` 处理（:2323-2327）。
- 收到包顺手回 RR（rtsp.c:2397-2398）。
- RTCP 与 RTP 不区分端口归属时靠 `pick_stream` 用 SSRC/payload type 认领（rtsp.c:2336-2378）。多轨共享一个 jitter buffer 上限 `RTP_REORDER_QUEUE_DEFAULT_SIZE=500`（rtpdec.h:39）；TCP 或 max_delay=0 时禁用重排（rtsp.c:874-879）。
- UDP 超时且客户端允许 TCP 时自动降级重连：`rtsp_read_packet` 捕获 `ETIMEDOUT` → `resetup_tcp`（rtspdec.c:943-954）→ 重新 SETUP/PLAY（rtspdec.c:1024-1045）。

### 5.2 交错 TCP 路径（$ 块）

RTSP/TCP 上数据与信令复用同一连接，数据帧以 `'$' + 1 字节通道 id + 2 字节长度` 开头。解析位置在**信令读取器内部**：`ff_rtsp_read_reply_internal` 逐字符读行时，若行首字符是 `'$'`：调用方允许中途返回就置 `rt->pending_packet=1` 并 return 1，否则就地 `ff_rtsp_skip_packet` 吞掉（libavformat/rtsp.c:1260-1268）。

demuxer 的真正取包在 `ff_rtsp_tcp_read_packet`（libavformat/rtspdec.c:892-941）：

```c
ret = ff_rtsp_read_reply(s, &reply, NULL, 1, NULL);  /* 1 = 遇'$'即返回 */
if (ret == 1) break;                                  /* :904-908 */
...
ret = ffurl_read_complete(rt->rtsp_hd, buf, 3);       /* $, id, len hi/lo */
id  = buf[0];
len = AV_RB16(buf + 1);                               /* :913-918 */
...
for (...) if (id >= rtsp_st->interleaved_min && id <= rtsp_st->interleaved_max)
    goto found;                                       /* :931-936 */
```

通道 id 与轨的映射关系来自 SETUP 时协商的 `interleaved=`（`RTSPTransportField.interleaved_min/max`，rtsp.h:95；解析于 rtsp.c:1026-1031；客户端请求侧生成于 rtsp.c:1712-1719，每轨递增 2——RTP 用偶数 id、RTCP 用奇数 id）。跳包函数 `ff_rtsp_skip_packet`（rtsp.c:1199-1225）。

---

## 6. mux 侧：rtspenc 与 rtpenc（ANNOUNCE/RECORD 推流）

RTSP 推流 = 对外说 RTSP + 每轨一个内嵌 RTP muxer。

1. `rtsp_write_header`（libavformat/rtspenc.c:127-141）：`ff_rtsp_connect` 后 `ff_rtsp_setup_output_streams`（rtspenc.c:47-110）用 `av_sdp_create`（libavformat/sdp.c:877）生成 SDP 并以 **ANNOUNCE**（Content-Type: application/sdp）发出（rtspenc.c:85-87）；随后 `rtsp_write_record` 发 **RECORD**（rtspenc.c:112-125）。SDP 头由 `sdp_write_header` 拼出 v=/o=/s=/c=/t= 行（sdp.c:80-92），每轨媒体行由 `ff_sdp_write_media`（sdp.c:848）生成。listen 模式的对端等价物是 rtspdec.c 的 ANNOUNCE 处理（rtspdec.c:177-222）。
2. 每轨内嵌 RTP muxer 由 `ff_rtp_chain_mux_open` 创建（libavformat/rtpenc_chain.c:29，`oformat = av_guess_format("rtp",...)` :35）。
3. `rtsp_write_packet`（rtspenc.c:182-229）先非阻塞 poll 读掉服务器可能发来的响应/请求（:187-214），再把 AVPacket `ff_write_chained` 进对应 rtp muxer（:221）；TCP 模式下 rtp muxer 写的是动态包缓冲，需要 `ff_rtsp_tcp_write_packet` 把缓冲里每个 RTP 包改写成交错帧——巧思在于 4 字节长度前缀恰好被 `'$'+id+len` 原地覆盖（rtspenc.c:154-177，RTCP 包用奇数 id :167-170）。
4. 收尾：`rtsp_write_close` 先 `ff_rtsp_undo_setup(s,1)` 让各轨发 BYE（rtspenc.c:231-238，BYE 在 rtpenc.c:682-692 的 trailer 中产生），再 TEARDOWN（rtspenc.c:240）。
5. RTP muxer 本体（libavformat/rtpenc.c）：`rtp_write_header`（:100）随机化 `base_timestamp`/SSRC/起始 seq（:128-148），`max_payload_size = packet_size - 12`（:164），视频 time_base 固定 1/90000、音频用采样率（:166-170）；`rtp_write_packet`（:549）按 codec 分派到各打包器（H264→`ff_rtp_send_h264_hevc` :619-621）；RTCP SR 按"5s 或字节增量"条件发送（:558-566），SR 中 rtp_ts 由 NTP 差值 rescale 回 time_base 再加 base_timestamp（`rtcp_send_sr`，rtpenc.c:317-360，:325-326）——这正是解包侧 3.2 节映射的逆运算。

---

## 7. 设计动机

- **控制/数据分离**：RTSP 是纯文本的"遥控器"，重传无状态、可代理可鉴权；数据走 RTP/UDP 才能容忍丢包、低延迟。TCP 交错模式（$ 块）是给穿墙/防火墙场景的折中，FFmpeg 把它实现在信令解析器里而不是独立 socket 抽象，代价是 `ff_rtsp_read_reply` 必须随时准备"读到一半变数据"（rtsp.c:1260）。
- **每轨独立 SETUP**：SDP 的 m= 行天然按轨声明（rtsp.c:502），而每轨的传输参数（端口对、interleaved id、时钟率）彼此独立，逐轨 SETUP 让服务器可以逐轨拒绝（461）并让客户端逐轨降级；`ff_rtsp_make_setup_request` 的循环结构（rtsp.c:1630）就是协议分层在代码里的直接投影。
- **90kHz 惯例**：视频统一 1/90000（rtpenc.c:169）——能被 24/25/30/50/60 整除，且 32 位时间戳回绕周期约 13 小时，兼顾精度与回绕频率；MPEG-TS 甚至要求 payload 对齐 188 字节（rtpenc.c:181-193）。解包侧不需要知道"为什么是 90k"，time_base 完全由 SDP rtpmap 决定（sdp_parse_rtpmap，rtsp.c:314）。
- **(int32_t) 差值回绕**：RTP 时间戳只保证差值有意义，`finalize_packet`/`rtp_set_prft` 全部用有符号 32 位差值（rtpdec.c:655, 606）处理回绕，这是 RTP 代码的通用心法。
- **SDP 既是元数据也是协商输入**：sprop-parameter-sets（rtpdec_h264.c:168）意味着参数集可以不经 RTP 带内传输——SDP 完成带外注入，收流端无需等 I 帧即可初始化解码器。

---

## 8. FAQ 素材

1. **RTSP 和 RTP 是什么关系？** RTSP 只管会话控制（OPTIONS/DESCRIBE/SETUP/PLAY/PAUSE/TEARDOWN，方法枚举在 libavformat/rtspcodes.h:129-141）；RTP 管数据，RTCP 管反馈。FFmpeg 里三者在代码上也是三个文件：rtsp*.c / rtpdec*.c / rtpenc*.c。
2. **ffmpeg 拉 RTSP 流时 UDP 和 TCP 怎么选？** 默认按 SDP/SETUP 协商；`?tcp` 选项对应 `RTSP_FLAG_PREFER_TCP`（rtsp.h:464）。UDP 超时还会自动降级 TCP 重试（rtspdec.c:1024-1045）。
3. **为什么 RTSP 拉流 PTS 偶尔从 0 开始有时很大？** 取决于是否收到 RTCP SR：有 SR 走 NTP 映射路径（rtpdec.c:649-663），无 SR 走 base_timestamp 兜底（rtpdec.c:665-675）；PLAY 响应的 Range 还会引入 `range_start_offset`（rtspdec.c:577-591）。
4. **H264 over RTP 一帧为什么拆成好几个 AVPacket？** FU-A 分片并不在 depacketizer 里拼帧（rtpdec_h264.c:286-310），靠 `AVSTREAM_PARSE_FULL` 的解析器合并（rtpdec_h264.c:416）。
5. **sprop-parameter-sets 丢了会怎样？** extradata 为空，只能等带内 SPS/PPS；末尾多逗号（缺 PPS）会被直接忽略并告警（rtpdec_h264.c:170-173）。
6. **jitter buffer 多大？** 默认 500 包（rtpdec.h:39），TCP 传输自动禁用（rtsp.c:874-879），可由 `reordering_queue_size` 覆盖（rtsp.h:433）。
7. **交错 TCP 的 $ 块怎么认轨？** 1 字节通道 id 落在轨的 `interleaved_min..max` 区间即归属该轨（rtspdec.c:931-936）；RTP/RTCP 分别占用偶/奇 id（rtsp.c:1717-1719）。
8. **RTSP 会话保活怎么做？** 每半个 timeout 周期发一次 GET_PARAMETER 或 OPTIONS 心跳（rtspdec.c:1050-1065），timeout 来自 SETUP 响应的 `Session:...;timeout=`（rtsp.c:1141-1147）。
9. **RTCP BYE 意味着什么？** 单轨 BYE 计数，全部轨都 BYE 才返回 EOF（rtsp.c:2539-2547）。
10. **为什么 SDP demuxer（`-f sdp`）可以脱离 RTSP 工作？** SDP 只描述流，`sdp_read_header`（rtsp.c:2606）直接按 c=/m= 行打开 UDP/TCP 收 RTP；多轨复用一个输入时靠 SSRC/PT 认领（pick_stream，rtsp.c:2336-2378）。

## 9. 深挖素材

1. **NTP↔RTP 双向映射的完整闭环**：mux 侧 `rtcp_send_sr`（rtpenc.c:325-326）与 demux 侧 `finalize_packet`（rtpdec.c:649-663）互为逆运算；`start_time_realtime` 的推导（rtsp.c:2531-2537）是理解"墙钟时间对齐"的钥匙。
2. **重排序队列实现**：`enqueue_packet` 按 seq 有序插入单链表（rtpdec.c:774-799）、`has_next_packet`（:801-804）与队列满强出（rtpdec.c:907-910）共同构成 mini jitter buffer；`ff_rtp_queued_packet_time` 驱动跨轨的 `max_delay` 等待（rtsp.c:2451-2473, 2483-2490）。
3. **RTCP 反馈全家桶**：RR（rtpdec.c:313）、PLI/NACK（rtpdec.c:469，需 AVPF）、以及 mux 侧 SR/CNAME/BYE（rtpenc.c:317-360）——对比 RFC 3550 报文格式逐字段看。
4. **RTSP over HTTP 隧道**：`RTSP_LOWER_TRANSPORT_HTTP`（rtsp.h:44）、`rtsp_hd_out` 独立写句柄（rtsp.h:358）、`ff_rtsp_connect` 中两段 HTTP 连接的建立（rtsp.c:2060-2100 附近）。
5. **SRTP 通道**：SDP `a=crypto:` 解析（rtsp.c:686-693）→ `ff_rtp_parse_set_crypto`（rtpdec.c:587-592）→ `ff_rtp_parse_packet` 入口解密（rtpdec.c:929），实现位于 libavformat/srtp.c。

---

## 写作要点速查表

| 事实 | 位置 |
|---|---|
| RTSPState / RTSPStream 结构定义 | libavformat/rtsp.h:226-455 / 477-519 |
| lower transport 枚举（UDP/TCP/组播） | libavformat/rtsp.h:39-52 |
| 客户端连接 + OPTIONS 探测 | rtsp.c:1897, 2149 |
| DESCRIBE 拿 SDP 并解析 | rtspdec.c:721, 740, 750 |
| SDP m=/a= 行解析、建轨 | rtsp.c:448 (m= :502, a=rtpmap :625, a=fmtp :638) |
| 逐轨 SETUP 循环（TCP interleaved / UDP client_port） | rtsp.c:1599, 1712-1719, 1695-1699 |
| Transport 头解析（interleaved= 等） | rtsp.c:951, 1026-1031 |
| PLAY 命令与 Range 拼接 | rtspdec.c:527, 573, 568-572 |
| 交错帧 `$` 检测（信令读取器内） | rtsp.c:1260-1268；跳包 rtsp.c:1199 |
| TCP 取包：3 字节头 + id 认轨 | rtspdec.c:892, 913-918, 931-936 |
| UDP poll 多路复用与 RR 回发 | rtsp.c:2259, 2270-2298, 2397-2398 |
| 统一取包与 SR 跨轨同步 | rtsp.c:2418, 2507-2537 |
| RTP 头解析与 handler 分发 | rtpdec.c:678, 688-697, 742-746 |
| 序列号合法性（dropout/probation） | rtpdec.c:249, 252-254 |
| 乱序重排队列（入队/出队） | rtpdec.c:774, 811, 838-913 |
| RTCP SR 解析与 first_rtcp_ntp_time | rtpdec.c:181, 195-208 |
| 时间戳→PTS 三条路径（finalize_packet） | rtpdec.c:630, 649-663, 665-675 |
| sprop-parameter-sets → extradata | rtpdec_h264.c:97-143, 168-181 |
| FU-A 重组 / STAP-A 聚合重组 | rtpdec_h264.c:286-310, 207-263, 313-375 |
| H264/HEVC 打包（STAP-A 拼装 + FU-A 切片） | rtpenc_h264_hevc.c:56-179 (S/E 位 :119,:168-177), 181-211 |
| RTP 打包头写与 SR 生成 | rtpenc.c:364-383, 317-360, 90kHz :169 |
| ANNOUNCE(带 SDP)/RECORD 推流 | rtspenc.c:47-110, 112-125 |
| TCP 交错写包（$ 头原地覆盖） | rtspenc.c:143-180 |
| SDP 生成（v/o/s/c/t 行） | sdp.c:80-92, 848, 877 |
| RTSP muxer/demuxer 注册 | rtspenc.c:248 / rtspdec.c:1105 |
