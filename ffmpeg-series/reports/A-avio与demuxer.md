# A-avio I/O 层与 demuxer 框架

> 系列第二系列《FFmpeg》子系统调研报告。仓库:`ffmpeg` master @ `9f63b36a`(2026-09-04)。
> 本报告覆盖 `libavformat/avio.c、aviobuf.c、url.c、protocols.c、format.c、options.c、utils.c、demux.c、mov.c` 及相关头文件,所有结论均以 `文件:行号` 标注。

---

## ① 全景:avio 在 FFmpeg 分层架构中的位置

FFmpeg 对外暴露三组核心抽象:**libavformat**(容器层)、**libavcodec**(编解码层)、**libavfilter**(滤镜层)。一次典型的转码数据流是:

```
            ┌─────────────────────────────────────────────┐
 应用层      │ ffmpeg / ffplay / 自研播放器                  │
            └───────────────┬─────────────────────────────┘
                            │ AVFormatContext / AVCodecContext
 ┌──────────────────────────▼──────────────────────────┐
 │ libavformat  avformat_open_input()                   │
 │   ① avio 层: AVIOContext(带缓冲) ←→ URLProtocol 回调表 │
 │      file / http / rtmp / tls / pipe ... (avio.c)    │
 │   ② 内容探测: av_probe_input_buffer2 → AVInputFormat  │
 │   ③ demuxer.read_header → AVStream[n] + codecpar     │
 │   av_read_frame() → AVPacket                         │
 └──────────────────────────┬──────────────────────────┘
                            │ AVPacket(带 codec_id / extradata / pts)
 ┌──────────────────────────▼──────────┐
 │ libavcodec  avcodec_send_packet /    │
 │             avcodec_receive_frame → AVFrame
 └──────────────────────────┬──────────┘
 ┌──────────────────────────▼──────────┐
 │ libavfilter 滤镜图 → (转码时)回到      │
 │ libavformat 的 mux 侧 av_interleaved_write_frame
 └─────────────────────────────────────┘
```

这条链路上有**两个互相正交的"插件系统"**,是理解 libavformat 的关键:

1. **协议层(URLProtocol)**:解决"从哪里拿字节"。每个协议实现一张 C 函数指针回调表(`libavformat/url.h:59-97`):`url_open/url_read/url_write/url_seek/url_close` 等。全部协议以静态数组在编译期生成(`libavformat/protocols.c:84` 引入 configure 生成的 `protocol_list.c`),运行时可用白/黑名单过滤(`ffurl_get_protocols`,`protocols.c:126-146`)。
2. **格式层(AVInputFormat / FFInputFormat)**:解决"字节如何组成流"。每个 demuxer 实现 `read_probe/read_header/read_packet/read_close/read_seek` 五个回调(`libavformat/demux.h:66-106`),同样通过 configure 生成 `demuxer_list.c` 静态表,由 `av_demuxer_iterate()` 遍历(`libavformat/allformats.c:618-633`)。MP4、MKV、MPEG-TS 各是一个 demuxer。

协议与格式之间靠**带缓冲的 AVIOContext** 解耦:上层 demuxer 只看到 `avio_read/avio_seek`,完全不感知下面是磁盘还是 HTTP。这就是本文第二章的主角。

---

## ② AVIOContext 逐段解读:双回调 + 双缓冲

### 2.1 两层对象:URLContext(无缓冲)与 AVIOContext(缓冲)

`avio_open("http://...")` 的完整路径是(`avio_open2 → ffio_open_whitelist2`,`libavformat/avio.c:559-563、529-549`):

1. `url_find_protocol()` 按 scheme 查表(`avio.c:317-358`):取 URL 前缀中合法 scheme 字符(`avio.c:312-315` 的 `URL_SCHEME_CHARS`),无 `:` 或是 DOS 盘符则回落到 `"file"` 协议(`avio.c:324-327`);支持 `tls+https` 这类 `+` 嵌套协议(`avio.c:332-334`)。
2. `url_alloc_for_protocol()` 分配 URLContext,并把 `filename` 柔性数组式地附在结构体尾部(`avio.c:144-151`)。
3. `ffurl_connect()` 强制执行白/黑名单(`avio.c:225-233`),然后调用协议的 `url_open2/url_open`(`avio.c:249-254`);对可写流或 file 协议,用一次 `ffurl_seek(0, SEEK_SET)` 试探是否可回退,失败则标记 `is_streamed=1`(`avio.c:262-266`)。
4. `ffio_fdopen()` 套上缓冲层(`avio.c:470-527`):缓冲区大小取协议 `max_packet_size`(如 UDP),否则 `IO_BUFFER_SIZE = 32768`(`avio.c:40、476-481`);再以协议回调为底座创建 AVIOContext:

```c
// libavformat/avio.c:491-492
*sp = avio_alloc_context(buffer, buffer_size, h->flags & AVIO_FLAG_WRITE, h,
                         ffurl_read2, ffurl_write2, ffurl_seek2);
```

URLContext 还挂着一组通用选项(`avio.c:64-70`):`protocol_whitelist/protocol_blacklist/rw_timeout`——这是 SSRF 防护与网络超时的入口。

### 2.2 读缓冲:三个指针 + 一个绝对偏移

```
读方向(以 fill_buffer 驱动)
buffer                         buf_ptr          buf_end         buffer+buffer_size
  │                               │                │                   │
  ▼                               ▼                ▼                   ▼
  ┌───────────────────────────────┬────────────────┬───────────────────┐
  │ 已读过但仍在缓冲内(可向后 seek) │ 尚未消费的有效数据 │      空闲区域       │
  └───────────────────────────────┴────────────────┴───────────────────┘
  s->pos = 缓冲区末字节之后下一个字节的物理流绝对偏移
           (读模式下 buffer 首字节对应 pos - (buf_end - buffer),aviobuf.c:251-253)
```

- `avio_r8/avio_rb32/...` 等按位读取器只在缓冲区内移动 `buf_ptr`,耗尽才触发 `fill_buffer`(`aviobuf.c:606-613`)。
- `fill_buffer()`(`aviobuf.c:514-566`)优先把数据追加在 `buf_end` 之后以保留前面的数据供回退;若放不下则整体回到 `buffer` 头部覆写。**探测结束后自动缩容**:`av_probe_input_buffer2` 会把缓冲撑到 1MB,`fill_buffer` 检测到 `buffer_size > orig_buffer_size` 就调 `set_buf_size` 缩回 32KB(`aviobuf.c:538-549、1090-1104`)。
- `avio_read()` 有一条**旁路**:当请求量 `size > buffer_size` 且无 CRC 校验需求时,直接调 `read_packet_wrapper` 把数据读进用户缓冲,完全绕过内部缓冲(`aviobuf.c:622-644`)——这让 mov 这类"按索引大块读样本"的 demuxer 不做无谓拷贝。

### 2.3 写缓冲:buf_ptr_max 与"先回退再写"

```
写方向
buffer                 buf_ptr_max             buf_ptr      buffer+buffer_size
  │                        │                      │               │
  ▼                        ▼                      ▼               ▼
  ┌────────────────────────┬──────────────────────┼───────────────┤
  │  已提交待写出数据         │  本次新增未写出数据     │    空闲        │
  └────────────────────────┴──────────────────────┴───────────────┘
  flush_buffer(): writeout(buffer, buf_ptr_max - buffer) 后 buf_ptr/buf_ptr_max 归零
  (aviobuf.c:168-182)
```

`buf_ptr_max` 记录"写到的最远位置",配合 `avio_flush()` 里的 `seekback` 实现**头部改写**:muxer 先写占位数据,稍后回退填真实长度(`aviobuf.c:228-234`)。`avio_write_marker()`(`aviobuf.c:464-499`)则给输出流打"同步点/边界点"标记,供 `tee`/interleaved mux 决定在哪里真实落盘。

### 2.4 seek 语义:五级降级

`avio_seek()`(`aviobuf.c:236-319`)是 avio 层最精巧的函数,按代价从低到高依次尝试:

1. **AVSEEK_SIZE 透传**:直接问协议"流多大",不动位置(`aviobuf.c:248-249`)。
2. **缓冲区内命中**:`offset1 = offset - pos` 落在 `[0, 有效长度]` 内,只移动 `buf_ptr`,零 I/O(`aviobuf.c:275-280`)。
3. **短前向 seek**:目标不超过"缓冲区 + short_seek_threshold(默认 32768,`aviobuf.c:43`)"时,不调协议 seek,而是循环 `fill_buffer` 把数据**读过来丢掉**直到到达目标(`aviobuf.c:281-289`)。对流式协议(HTTP)这比 Range 请求便宜得多;阈值可被协议通过 `short_seek_get` 动态调大(`avio.c:524`,如 http 根据服务器能力)。
4. **小幅回退**:目标在当前位置前半个缓冲区内时,直接回 seek 半个缓冲区再整块重读,从中挑出目标点(`aviobuf.c:290-301`)。
5. **真实 seek**:先 `flush_buffer` 写出脏数据,再调 `s->seek` 回调(`aviobuf.c:302-316`)。

可 seek 性是**位掩码**而非布尔:`AVIO_SEEKABLE_NORMAL`(字节可回退,`avio.h:41`)与 `AVIO_SEEKABLE_TIME`(协议实现 `url_read_seek`,可按时间 seek,`avio.h:46`),由 `ffio_fdopen` 依据 `is_streamed` 与协议能力设置(`avio.c:514-523`)。MP4 demuxer 要求前者,否则退化为顺序播放。

对**完全不可 seek 的流**(管道),aviobuf 提供两个关键补救:`ffio_ensure_seekback()` 通过扩容缓冲保证"接下来 N 字节还能读回去"(`aviobuf.c:1026-1062`);`ffio_rewind_with_probe_data()` 干脆把探测读过的数据**变成新缓冲**,避免任何协议层 seek(`aviobuf.c:1151-1192`)。

### 2.4b AVIOContext 同时是一等公民 API:自备数据源

`avio_alloc_context` 是公开 API:应用可以把自己的内存池、加密通道、自研 RPC 封装成三个回调(`read_packet/write_packet/seek`)塞给 `AVFormatContext.pb`,从而让**任何一个现成 demuxer 直接吃你的数据源**,完全不必经过 URLProtocol。这正是 `init_input` 决策树里"用户自备 s->pb"分支的存在意义(`demux.c:165-174`)。对此框架做了两点配合:① custom IO 不会被框架关闭(见 FAQ Q3);② demuxer 里凡是要二次打开数据源的地方(mov 的外链 dref、HLS 的分片下载)都走 `AVFormatContext.io_open/io_close2` 虚函数,默认实现才是 `ffio_open_whitelist2`(`options.c:141-163`),应用可以整体替换。

读侧还有一批"便利层":`ffio_read_indirect` 优先返回缓冲区内部指针避免拷贝(`aviobuf.c:675-685`),`avio_read_partial` 只保证"至少来一点"适配阻塞网络流(`aviobuf.c:687-715`),`ff_get_line/read_string_to_bprint` 服务于 HLS m3u8 这类文本清单,以及一组 CRC 校验器挂载点 `ffio_init_checksum`(`aviobuf.c:594-603`),供 MPEG-PS 等格式边读边校验。这些函数全部构建在 `avio_r8/avio_read` 的缓冲语义之上——**缓冲层之上再抽象,而不是绕过缓冲**,是 aviobuf.c 一以贯之的原则。

### 2.5 interrupt_callback:协作式取消

FFmpeg 没有 I/O 线程,所有阻塞点都靠用户注入的回调 `AVFormatContext.interrupt_callback`(`avformat.h:1620`)协作取消。检查点有三处:每次 `url_read/url_write` 循环开头(`retry_transfer_wrapper`,`avio.c:582`)、`find_stream_info` 主循环每轮(`demux.c:2708-2712`)。命中即返回 `AVERROR_EXIT`。`ff_check_interrupt` 本体只有 5 行(`avio.c:922-927`)。同函数里还处理 `EAGAIN` 重试:前 5 次忙旋,之后每次 `av_usleep(1000)`,直至 `rw_timeout` 微秒超时返回 `EIO`(`avio.c:590-601`)。

---

## ③ demux 框架三阶段

### 3.1 avformat_open_input():定格式 + 读头

`avformat_open_input`(`demux.c:231-375`)第一步 `init_input` 是一棵决策树(`demux.c:158-187`):

```
用户自备 s->pb(custom AVIOContext)?
 ├─ 是 → 只能在缓冲上探测格式(av_probe_input_buffer2),禁止自行开关 IO
 └─ 否 → 已指定 iformat 且 AVFMT_NOFILE?(设备类 demuxer,如 lavfi/x11grab)
          ├─ 是 → 不开 IO,直接用文件名
          └─ 否 → s->io_open()(默认 ffio_open_whitelist2)打开 URL
                   → 仍无 iformat → 在 AVIOContext 上边读边探测
```

**内容探测**(`av_probe_input_buffer2`,`format.c:256-346`)是指数退避式读入:从 `PROBE_BUF_MIN=2048` 字节起,每轮翻倍至 `PROBE_BUF_MAX=1MB`(`internal.h:33-34`),每轮都让全部 demuxer 的 `read_probe` 在已有数据上打分;还在持续读入时把及格线压到 `AVPROBE_SCORE_RETRY=25`,防止"数据太少导致低分误中"(`format.c:292、316`)。探测缓冲尾部必须零填充 `AVPROBE_PADDING_SIZE=32` 字节,允许 probe 函数安全地多读几个字节(`format.c:313`,`avformat.h:485`)。结束后把探测数据"塞回"AVIOContext(`ffio_rewind_with_probe_data`,`format.c:340`),demuxer 重读头部时零成本。

随后主流程按序:继承协议黑白名单(`demux.c:270-284`)→ 校验 `format_whitelist`(`demux.c:286-290`)→ 分配 demuxer 私有数据并灌默认选项(`demux.c:305-316`)→ 对 ID3 系格式先摘 ID3v2 标签(`demux.c:319-320`)→ **`read_header` 回调**(`demux.c:322-327`,demuxer 在此创建 AVStream)→ 记录 `data_offset`(`demux.c:350-351`)。失败路径注意 `FF_INFMT_FLAG_INIT_CLEANUP`:置位后框架会替 demuxer 调 `read_close`,否则失败清理是 demuxer 自己的责任(`demux.c:324-326`,mov 置了此位,`mov.c:12519`)。

### 3.2 avformat_find_stream_info():补齐 codecpar

MP4 这类"索引完备"的容器,`read_header` 后 `codecpar` 已齐;但 MPEG-TS/FLV 这类**无头容器**(flag `AVFMTCTX_NOHEADER`)什么都要靠读数据才知道。`avformat_find_stream_info`(`demux.c:2606-3213`)就是一个受双重预算约束的读循环:

- **字节预算** `probesize`(默认 5MB,`options_table.h:39`):累计读入超过即停(`demux.c:2779-2794`)。
- **时间预算** `max_analyze_duration`:默认 5 秒,字幕 30 秒,FLV 特例 90 秒,MPEG/MPEG-TS 特例 7 秒(`demux.c:2628-2636`)。

每轮循环:① 检查取消回调;② 找出第一个"参数还不全"的流——不全的判据 `has_codec_parameters`(缺宽高/采样率等,`demux.c:2728`),或帧率还没数够 `fps_analyze_framecount`(默认 20 帧,timebase 粗于 0.5ms 时翻倍,`demux.c:2725-2734`);③ `read_frame_internal` 读一包,塞进 `packet_buffer`(`demux.c:2799-2815`,这些包之后会原样交给用户,探测不丢数据);④ `try_decode_frame` **真的打开解码器解几帧**来补参数(`demux.c:2935`),并用 `extract_extradata` 位流过滤器从码流里抠 H.264 SPS/PPS 之类(`demux.c:2920-2924`)。

收尾阶段:由累计的 dts 序列估算 `avg_frame_rate`,并**吸附到 1% 误差内的标准帧率**(23.976/29.97 等,分母 `12*1001`,`demux.c:3019-3047`);`estimate_timings` 按 `AVFMT_NO_BYTE_SEEK` 等旗标选择"精确/按码率估算"补全总时长。参数确实补不齐时,给出那条开发者最熟悉的告警 "Consider increasing the value for the 'analyzeduration' and 'probesize'"(`demux.c:3114-3120`)。

时长估算有三条降级路径,体现了"能精确则精确、不能精确则估算"的工程取向:① 容器声明了时长(MP4 mvhd)直接用;② 可 seek 时,读到各流最远 dts 相加(`update_stream_timings`,`demux.c:1705-1797`);③ 都不行就 `estimate_timings_from_bit_rate`,用 `avio_size × 8 / bit_rate` 反推时长——码率来自各流声明值或探测期实测,结果误差可以到秒级,但对播放器进度条已经够用。这也解释了为什么 find_stream_info 里要专门维护 `fps_first_dts/fps_last_dts` 并检测 DTS 断流(相差超过平均包时长 1000 倍即重置采样,`demux.c:2846-2862`):**估算的输入本身也要先做健全性检查**。

EOF 之后的兜底同样值得注意:循环因 EOF 退出时,还有一批"参数仍不全"的流会被强制打开解码器再试一次(`demux.c:2945-2960`),已缓冲的包用现有 delay 信息重排 dts(`update_dts_from_pts`,`demux.c:2964-2966`),最后清理全部探测用的临时解码器与 `sti->info`(`demux.c:3184-3202`)。探测是"临时借解码器一用",用完必须完整归还——这也是 `codecpar` 与内部 `avctx` 分层(见第⑤节第 6 点)能维持干净 ABI 的前提。

### 3.3 av_read_frame():三级队列与时间戳修补

用户调用链 `av_read_frame → read_frame_internal → ff_read_packet → iformat->read_packet`(`demux.c:1588-1681、1388-1586、629-691`)。框架在 demuxer 与用户之间维护**三级队列**(`internal.h:64-104` 的 FFFormatContext + `demux.c:606、1306`):

```
demuxer.read_packet
   │  (流级探测期间排队)
   ▼
raw_packet_buffer ── probe_codec 用probesize封顶 ──► 直接透传
   │
   ▼ read_frame_internal:按需挂 parser 拆帧
parse_queue(AVParser 把"一包多帧"拆成单帧包)
   │
   ▼ find_stream_info 期间探测的包
packet_buffer ──► av_read_frame 优先从这里出货
```

几个关键机制:

- **流内格式探测**:`ff_read_packet` 拿到包后经 `handle_new_packet`(`demux.c:577-620`)进入 `probe_codec`(`demux.c:424-475`):某些容器(如 MPEG-PS)不声明子流编码,框架把该流前若干包攒成 `AVProbeData` 再次调用 `av_probe_input_format3` 识别出 `h264/aac/mp3/...` 并回填 `codecpar->codec_id`(`fmt_id_type` 表,`demux.c:106-130`)。
- **parser 拆帧**:`need_parsing` 的流(典型是 TS)把大包交给 `av_parser_parse2` 循环切分成帧,写入 `parse_queue`(`parse_packet`,`demux.c:1178-1332`)。
- **时间戳修补** `compute_pkt_fields`(`demux.c:983-1170`):这是 demux 框架里最"脏"的代码——处理 dts 倒序检测(`dts_ordered/dts_misordered` 计数器,`demux.c:1000-1020`)、33-bit PTS 回绕校正(`demux.c:1040-1047`)、无 B 帧流的 `pts=dts` 补全、以及 H.264/HEVC/VVC 的 `pts_buffer` 重排序窗口(`demux.c:1148-1155`)。对完全没有时间基准的流,框架先发"相对时间戳"(`RELATIVE_TS_BASE = INT64_MAX - (1<<48)`,`avformat_internal.h:105`;新流 `cur_dts` 以它为基点,`options.c:301`),在 `av_read_frame` 出口再统一减掉基座,保证用户永远看到自洽的单调 dts(`demux.c:1675-1678`)。
- **错误透传**:demuxer 返回 `FFERROR_REDO` 表示"这包是垃圾已丢弃,再给我一次"(`demux.c:664-668`);EOF 但底层 `pb->error` 非零时,把 I/O 错误而非 EOF 返回给用户(`demux.c:1580-1583`)。

### 3.4 流的生命周期:nb_streams、codecpar 与内部 avctx

`AVStream` 的唯一合法出生点是 `avformat_new_stream`(`options.c:247-328`),几乎总在 demuxer 的 `read_header` 里被调用(trak→`mov.c:5561`)。它一次性初始化了后面所有机制的"地基":`codecpar` 独立分配(`options.c:270`)、无头容器用的探测状态 `info`(fps 首尾 dts 等,`options.c:285-293`)、默认 MPEG time_base 1/90000(`options.c:296`)、以及 `cur_dts` 预置为相对时间戳基座(`options.c:301`)。数组 `s->streams` 按 `nb_streams` 增长,但受 `max_streams` 硬顶(默认 64 级别)保护,超限直接拒绝打开——这是对"畸形容器声明上千轨"的资源攻击防线(`options.c:253-258`)。

对无头容器,流的出生点会推迟到 `find_stream_info` 甚至 `av_read_frame` 期间(`AVFMTCTX_NOHEADER` 语义,注释见 `demux.c:2769-2776、2797-2798`),这意味着**调用方不能假设 open 之后 nb_streams 就固定**,`orig_nb_streams` 快照只用于给"原有流"分发 options(`demux.c:2613-2614、2936`)。生命终点是 `avformat_close_input → avformat_free_context`:先 `read_close`(`demux.c:392-394`)、再关 IO(除非 CUSTOM_IO),然后释放每个流的 `codecpar/priv_data/parser`。另外新版引入了 `AVStreamGroup`(IAMF、Dolby Vision、LCEVC 等流间关系),创建与校验逻辑平行于普通流(`options.c:470-571`),读取路径上 mov 已在使用(`mov.c:11630-11647`)。

`st->index`(0..nb_streams-1 的数组下标)与 `st->id`(容器里的轨道号,如 MP4 track_ID、TS PID)是两套编号,`AVPacket.stream_index` 永远是前者;mov 在 `MOVStreamContext.ffindex` 里维护映射(`mov.c:5569`)。而 `codecpar` 与内部 `sti->avctx` 的同步是单向拉取式:demuxer 改了 `codecpar` 就置 `need_context_update`,下次 `read_frame_internal` 循环统一 `avcodec_parameters_to_context` 并按需重建 parser(`demux.c:1427-1461、191-225`)——**公共参数是唯一事实源,内部解码上下文只是缓存**,这保证用户在 read 循环中改 codecpar 也被尊重。

---

## ④ MP4 demuxer 案例分析(mov.c,12526 行)

### 4.1 盒子树与解析循环

MP4 = 一棵 `size(4B,大端) + type(4B FourCC)` 前序遍历的盒子树。`ff_mov_demuxer` 的名字是 `"mov,mp4,m4a,3gp,3g2,mj2"`——一个 demuxer 吃掉整个 ISO-BMFF 家族(`mov.c:12513-12525`);flags 带 `AVFMT_SEEK_TO_PTS`(按 pts seek)。

```
典型文件布局(progressive download:mdat 在前,moov 在后)
offset 0
 ├─ ftyp   品牌/兼容品牌                         mov_read_ftyp (mov.c:1648)
 ├─ mdat   样本数据本体(大二进制块)
 ├─ free   填充
 └─ moov  ─── mov_read_header 的主解析目标
     ├─ mvhd  全局 timescale/duration            mov.c:2048
     ├─ trak  ×N(每轨一个)─► avformat_new_stream mov.c:5555-5570
     │   ├─ tkhd  显示矩阵/宽高                    mov.c:5952
     │   └─ mdia
     │       ├─ mdhd  track timescale → time_base mov.c:2002
     │       └─ minf/stbl ←—— 采样表,seek 与解码的钥匙
     │           ├─ stsd  样例描述:编码参数+extradata  mov.c:3451
     │           ├─ stts  dts 增量表 (count,duration)   mov.c:3807
     │           ├─ ctts  B帧 pts 偏移 (count,offset)   mov.c:3976
     │           ├─ stsc  chunk → 样本数映射
     │           ├─ stsz  每样本大小(或统一 size)
     │           ├─ stco/co64  chunk 文件偏移
     │           ├─ stss  关键帧样本序号表
     │           └─ elst  edit list(剪辑起点/空窗)     mov.c:6735
     └─ (fMP4) moof{mfhd,tfhd,trun} + mdat,按片段追加   mov.c:6057/6190
```

所有解析的引擎是 `mov_read_default()`(`mov.c:10126-10246`),一个递归下降循环:

```c
// libavformat/mov.c:10140-10193(节选)
while (total_size <= atom.size - 8) {
    a.size = avio_rb32(pb);        // 大端 4 字节长度
    a.type = avio_rl32(pb);        // FourCC 按小端读 → 'moov'
    ...
    if (a.size == 1) { a.size = avio_rb64(pb) - 8; }   // 64 位扩展长度
    if (a.size == 0) { a.size = atom.size - total_size + 8; } // 延伸到父盒末尾
    for (i = 0; mov_default_parse_table[i].type; i++)
        if (mov_default_parse_table[i].type == a.type) { parse = ...; }
    if (!parse) avio_skip(pb, a.size);   // 不认识的叶子盒直接跳过
    else int err = parse(c, pb, a);      // 递归/叶子解析
```

细节值得玩味:嵌套深度硬限 10(`mov.c:10132`);`trak/mdat` 出现在错误层级时回退 8 字节中止(`mov.c:10162-10171`);解析完每个盒子都做"剩余对齐"——多了跳过、少了(overread)回 seek 并告警(`mov.c:10227-10235`)。**parse 表驱动**:128 个 FourCC 条目(`mov.c:9992-10124`)把盒子映射到处理器,容器盒(`dinf/edts/minf/stbl`)就递归映射回 `mov_read_default` 本身。读到 `moov+mdat` 双双凑齐时提前返回——对边下边播(`mdat` 在前)的流,不必等整个文件(`mov.c:10219-10226`)。

`mov_read_header`(`mov.c:11574-11733`)把"根原子"设为整个文件大小(`mov.c:11587-11590`),一次 `mov_read_default` 扫完全树;若 moov 不在(还在下载),seek 回 0 再试一次(`moov_retry`,`mov.c:11593-11601`);最终连 moov 都没有就报 `AVERROR_INVALIDDATA`(`mov.c:11602-11605`)。

两个容易忽视的环节:第一,moov 之外的"二级头"在 header 阶段一并处理——ID3 之外的章节轨(`mov_read_chapters`)、时间码轨(tmcd/rtmd)都在可 seek 时补齐(`mov.c:11618-11627`);第二,header 尾部是一轮**逐流收尾**:用 `stts` 累计出的 `duration_for_fps/nb_frames_for_fps` 计算 `avg_frame_rate`(`mov.c:11674-11676`),AAC 的 `initial_padding` 转成 `skip_samples`(`mov.c:11670-11673`),甚至针对 HandBrake 老版本产物的 MP3 流强制开启全量 parsing(`mov.c:11701-11706`)——一个维护了二十年的 demuxer,一半代码在处理**生态里真实存在的破损文件与编码器 bug**,这也回应了第⑤节"为什么探测复杂"的同一主题。

### 4.2 从采样表到 AVIndexEntry:mov_build_index

`trak` 解析完毕后,`avpriv_set_pts_info(st, 64, 1, sc->time_scale)` 把轨道 timescale 变成流的 `time_base`(`mov.c:5591`),然后 `mov_build_index`(`mov.c:4960+`)把四张正交表**叉乘展开**成逐样本索引:

- 外层遍历 `stco` 的 chunk 偏移;`stsc` 告诉每个 chunk 装多少样本(运行长度编码,两个游标 `stsc_index` 推进,`mov.c:5058-5063`);
- 每个样本:大小来自 `stsz`,是否关键帧来自 `stss/stps/rap_group` 三种来源的并集(`mov.c:5082-5098`),dts 从 0 累加 `stts` 的 duration 得到(`mov.c:5137-5139`),最终写入框架统一的 `AVIndexEntry{pos,timestamp,size,flags}`(`mov.c:5121-5126`)。

elst(edit list)在这之前完成时间轴平移:空编辑段决定 `time_offset`,AAC 的 priming 样本被换算成 `initial_padding` 供解码端裁剪(`mov.c:4977-5024`)。**这就是 MP4 能精确 seek 的全部原因**:seek 只是"在已展开的 `index_entries` 数组里二分找 timestamp",不碰媒体数据。

### 4.3 读包与 dts/pts 的最终合成

`mov_read_packet`(`mov.c:12059-12238`)是多路**解复用**的范本:`mov_find_next_sample` 在所有流的"下一个样本"里挑 dts 最小者(`mov.c:12105`)——交错(interleave)是 demuxer 主动做的,不是框架做的;随后 `avio_seek(sample->pos)` + `av_get_packet(size)` 读出原始样本(`mov.c:12124、12187`),经 `mov_finalize_packet` 合成时间戳(`mov.c:11975-12057`):

```c
// libavformat/mov.c:11982-11997
pkt->dts = sample->timestamp;                        // stts 展开:解码序
if (sc->ctts_count && sc->tts_index < sc->tts_count)
    pkt->pts = av_sat_add64(pkt->dts,
                 av_sat_add64(sc->dts_shift,
                              sc->tts_data[sc->tts_index].offset)); // ctts:呈现序
else
    pkt->pts = pkt->dts;                             // 无 B 帧:pts == dts
```

即 **dts 来自 stts 累加,pts = dts + dts_shift + ctts_offset**;`dts_shift` 处理某些 H.264 文件 ctts 为负的畸形情况。若同轨有多个 `stsd` 描述条目,切换样本参数时会现场更换 `extradata`(`mov_change_extradata`,`mov.c:12037-12054`)。fMP4(分片)则没有静态表:`tfhd` 给默认参数、`trun` 逐样本给 size/duration/flags,边读边向 `frag_index` 追加(`mov.c:6057-6092、6190`),moov 里的 stbl 全空是合法的(`mov.c:5598` 的注释)。

---

## ⑤ 设计动机与取舍:为什么探测机制如此复杂

1. **格式只能"猜",不能只看扩展名。** 用户喂给 FFmpeg 的可能是裸流(无扩展名)、伪装扩展名、或 HTTP 响应。所以 `av_probe_input_format3`(`format.c:156-236`)是一套**计分竞赛**:每个 demuxer 的 `read_probe` 对内容打 0-100 分(`AVPROBE_SCORE_MAX=100`),扩展名命中只给 50(`AVPROBE_SCORE_EXTENSION`),MIME 命中加 30(`avformat.h:478-483`)。分数体系的不对称是刻意的:**内容证据永远压倒元数据**。
2. **误判的代价不对称。** 探测有个反直觉设计:平分时返回 NULL——`score == score_max` 则 `fmt = NULL`(`format.c:228-229`)。两个 demuxer 都声称 100 分说明证据冲突,宁可失败让用户 `-f` 指定。同理,数据还在增长时及格线压到 25 分(`format.c:292`),因为"现在 25 分"只是"数据不够";EOF 后同样的分数就够格了(`format.c:303` 置 0 再比)。
3. **生态污染必须主动隔离。** MP3 前面挂 ID3v2 是家常便饭,探测前先循环剥掉 ID3 标签再比(`format.c:175-189`),且剥不干净时还要压低扩展名得分,防止"xxx.mp3 文本文件被 mp3 demuxer 90 分误收"。mov_probe 同样谨慎:`ftyp/mdat/moov` 给满分,`free/wide/junk` 只给 95,`skip/uuid` 只给 50,连 JPEG2000 装在 ftyp 里的情况都降分到 5(`mov.c:10274-10302`)。
4. **探测与缓冲深度耦合。** 探测"偷看"的数据必须零成本归还:pipe 不可 seek,于是有 `ffio_rewind_with_probe_data` 直接把探测缓冲变成 AVIOContext 缓冲(`aviobuf.c:1151-1192`),以及探测后缩容(`aviobuf.c:538-549`)。这是一套为"任意字节源(包括 stdin)"设计的自洽机制。
5. **find_stream_info 是把解码器当"探测器"用。** 容器头信息不可靠(甚至不存在),最权威的参数来源是码流本身。代价是打开一个真解码器解几帧(慢、耗内存),所以框架给了 `probesize/analyzeduration/fps_probe_size` 一组旋钮,且确定性的容器(MP4)在 `read_header` 后就能提前退出循环(`demux.c:2766-2777`)。追求低延迟的直播场景常设 `AVFMT_FLAG_NOBUFFER` + 小 probesize 来绕过它。
6. **ABI 稳定与内部自由的分层。** 对外暴露的 `AVStream.codecpar`(AVCodecParameters,纯 POD 参数)冻结了 ABI;demuxer 内部随便用 `FFStream.avctx`(真 AVCodecContext)做探测解码,两边用 `avcodec_parameters_to/from_context` 同步(`demux.c:216、3132-3140`)。`AVStream/AVFormatContext` 都是内嵌在 `FFStream/FFFormatContext` 里的"公共头"(`internal.h:135-139`),这是 FFmpeg 全库惯用的继承替代手法。
7. **交错是 demuxer 的责任,不是框架的。** 框架从不要求 demuxer 按时间序输出——mov 靠 `mov_find_next_sample` 每次挑全局最小 dts 的样本(`mov.c:12105`),MPEG-TS 天然交错,MKV 靠 Cluster。但 mux 侧的 `av_interleaved_write_frame` 反而在框架层做了交错排序。读写两侧的不对称说明:**解复用相信文件本身的结构,复用则必须替用户收拾任意输入顺序**。这也决定了 mov 的 `interleaved_read` 选项(`mov.c:12505-12506`)存在的原因:关掉它可以省掉样本间的来回 seek,代价是调用方拿到整段视频才见音频。
8. **静态注册而非插件加载。** 协议、demuxer 全部是编译期静态表(`protocols.c:84`、`allformats.c:618-633`),configure 按启用的组件生成列表文件,二进制里没有 dlopen。代价是加一个协议要重编译,收益是零初始化顺序问题、可被 `protocol_whitelist` 在打开时精确裁剪(对 SSRF/协议走私攻击是第一道闸,`avio.c:225-233`)。对嵌入式裁剪 build 也简单到只是改 configure 开关。
9. **时间戳修补放在 demux 框架而非解码器,是历史与现实的妥协。** `compute_pkt_fields` 那几百行 pts/dts 修补逻辑(`demux.c:983-1170`)看起来属于解码器的事,但大量真实文件在**容器层**就把时间戳写坏了(PTS 回绕、TS 丢包、B 帧偏移缺失),而 FFmpeg 的 API 承诺"从 `av_read_frame` 拿到的包就能直接送解码器"。把修补下沉到框架,500 多个 demuxer 各自只需填最少的时间信息,剩余的脏活集中在两三千行框架代码里。代价同样明显:这段代码是 demux.c 中最难维护、回归风险最高的部分——它对 H.264/HEVC/VVC 特判(`onein_oneout`,`demux.c:993-995`)、对 mov/flv 特判跳过(`demux.c:1056-1058`),每一处特判背后都是一个具体文件的 bug 报告。

---

## ⑥ FAQ

**Q1:`avio_skip()` 会触发真实 I/O 吗?**
不一定。它只是 `avio_seek(SEEK_CUR)` 的别名(`aviobuf.c:321-324`);落在缓冲区内就只挪 `buf_ptr`(`aviobuf.c:277-280`),前向不超过缓冲区+32KB 也只是"读过来丢掉"。读盒子树时的大量 4 字节对齐跳过几乎全是零成本。

**Q2:为什么 `av_read_frame` 返回的每个包都必须 `av_packet_unref`?**
包数据是引用计数的(`ff_read_packet` 里 `av_packet_make_refcounted`,`demux.c:681`),可能直接引用 parser 或 demuxer 的内部缓冲;框架各级队列(`packet_buffer/parse_queue`)也以引用计数共享同一块数据。不 ref/unref 就泄漏或悬垂。

**Q3:我自己 `avio_alloc_context` 塞给 `AVFormatContext.pb`,谁来关它?**
你。框架检测到 custom IO 后置 `AVFMT_FLAG_CUSTOM_IO`(`demux.c:255-256`),`avformat_close_input` 会跳过关闭(`demux.c:388-390`);open 失败路径同样只关自己开的(`demux.c:370-371`)。

**Q4:`probesize`、`format_probesize`、`analyzeduration` 三个参数的区别?**
`format_probesize`(默认 1MB,`options_table.h:40`)管**认容器**的探测上限;`probesize`(默认 5MB,`options_table.h:39`)管 find_stream_info 与流内 codec 探测的字节预算;`analyzeduration` 是同一循环的时间预算(默认 5s)。认错容器是前者的问题,读不出参数是后两者的问题。

**Q5:为什么某些 TS 流 `av_read_frame` 前几个包特别慢?**
`avformat_find_stream_info` 在攒帧估算 fps(默认 20 帧)、打开解码器补参数、抽取 extradata。MP4 不慢是因为 `read_header` 已经把参数凑齐,循环第一轮就 break(`demux.c:2766-2777`)。

**Q6:`AVFMT_NOFILE` 是什么?**
该 demuxer 不消费字节流,只消费 URL 字符串(如 `lavfi`、设备)。`init_input` 见到此 flag 就不去 `io_open`(`demux.c:176-178`),`avformat_close_input` 也不会关 pb(`demux.c:388`)。这类格式只能靠文件名"探测"(`av_probe_input_format3` 的 `is_opened` 分支,`format.c:194`)。

**Q7:网络流卡死了,interrupt_callback 检查得到吗?**
能,但只是协作式:检查点在 `retry_transfer_wrapper` 每轮(`avio.c:582`)与 find_stream_info 每轮(`demux.c:2708`)。协议内部单次阻塞(如 TCP read)期间无法打断,只能靠 `rw_timeout`(`avio.c:67`)或协议自身超时兜底。

**Q8:MP4 的 `time_base` 为什么不是 1/90000 之类固定值?**
`st->time_base = 1/track_timescale`(`mov.c:5591`),逐轨独立;而框架给新流的默认值是 MPEG 系的 1/90000(`options.c:296`)。跨流比较/展示时用 `av_rescale_q` 换算,find_stream_info 最后统一算出微秒级的 `ic->duration`(`demux.c:1787-1796`)。

**Q9:ctts 是 B 帧才有的吗?没有 ctts 的流 pts 是什么?**
ctts 非必需。没有它时 `pkt->pts = pkt->dts`(`mov.c:11997`);时长还要从"下一样本 dts - 当前 dts"反推(`mov.c:11991-11996`)。有 ctts 但全部 offset=0 等价于无 B 帧。

**Q10:为什么 demuxer 的 read_packet 返回的 dts 有时是"奇怪的大数"?**
那是相对时间戳(`RELATIVE_TS_BASE` 附近),来自无时间基准的流;正常路径下 `av_read_frame` 出口已减去基座(`demux.c:1675-1678`)。若你绕过框架直接用 `ff_read_packet`(库内 API)就会看到它。

---

## ⑦ 深挖问题(供下一轮调研)

1. **`ffio_rewind_with_probe_data` 的 overlap 合并**(`aviobuf.c:1151-1192`):探测数据与 AVIOContext 已缓冲数据可能部分重叠,代码用 `buffer_start = s->pos - buffer_size` 推导重叠区并 `memcpy` 去重。边界条件:`buffer_start > buf_size` 时直接失败——什么输入能构造出这种"探测读了 2048 字节但 IO 缓冲起点更靠后"的状态?这与 `fill_buffer` 的追加策略如何互动?
2. **`compute_pkt_fields` 的重排序启发式**:H.264 的 `has_decode_delay_been_guessed` 用 7/18/20 三个魔数判断"解码延迟已猜够"(`demux.c:759-777`),`select_from_pts_buffer` 用误差指数衰减(EWMA)挑最可信 dts(`demux.c:791-838`)。这些常数如何标定?对 DAMR/双 B 帧流是否仍成立?
3. **mov edit list 的完整语义**:`advanced_editlist` 打开时按 elst 重排 `AVIndex`(`mov.c:4977-5024`),关闭时只做 `time_offset` 平移;AAC `initial_padding` 与 `skip_samples` side-data(由 `demux.c:1545-1557` 注入)的接力链值得端到端追一遍。
4. **stts 负 delta 修正与 `dts_shift`**(`mov.c:3864-3885`):无符号 delta 被当作 int32 补码修正的启发式(`max_stts_delta` 默认 `UINT_MAX-48000*10`,`mov.c:12506`)与 `mov_read_default` 各处的畸形输入防御(fuzzing 目标)如何协同?
5. **三级队列的内存上界**:`raw_packet_buffer` 受 `probesize` 封顶(`demux.c:456-457`),但 `parse_queue`/`packet_buffer` 在 `find_stream_info` + `genpts` 组合下是否仍有界?低内存设备上 `AVFMT_FLAG_NOBUFFER` 之外还有哪些降级路径?

---

*报告完。字数约 8600 字。*
