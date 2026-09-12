# H — 网络流协议:URLProtocol 层、RTMP、HLS、DASH(源码调研)

> 基于 ffmpeg master(commit 9f63b36a)。所有行号均已用 grep/Read 实际核对,仓库相对路径标注。

---

## 1. 全景:URLProtocol 如何叠加在 avio 之上

FFmpeg 的网络 I/O 是三层结构:**协议回调表(URLProtocol)→ URLContext → 带缓冲的 AVIOContext**。

### 1.1 回调表与上下文

`URLProtocol` 是一张纯 C 函数指针表(libavformat/url.h:53-99),关键字段:

- `url_open` / `url_open2`(url.h:55,61)——open2 版本可接收未识别的 AVDictionary 选项并向下传给嵌套协议;
- `url_read` / `url_write` / `url_seek` / `url_close`(url.h:77-80);
- 流控专用:`url_read_pause`(url.h:81)与 `url_read_seek`(url.h:82)——这是网络流"按时间暂停/跳转"的入口,由 RTMP 实现;
- `flags`(url.h:91)可带 `URL_PROTOCOL_FLAG_NETWORK`(url.h:33)与 `URL_PROTOCOL_FLAG_NESTED_SCHEME`(url.h:32,用于 `crypto+https:` 这类叠加 scheme);
- `default_whitelist`(url.h:98)为协议默认白名单。

`URLContext`(url.h:35-51)持有 prot 指针、priv_data,以及两个贯穿全库的控制字段:`interrupt_callback`(url.h:44)和 `rw_timeout`(url.h:45,微秒)。两者都注册为通用选项(libavformat/avio.c:64-70,`rw_timeout` 在 avio.c:67)。

### 1.2 打开链路

1. `ffurl_alloc`(avio.c:360-371)→ `url_find_protocol`(avio.c:317-358)按 `scheme:` 前缀在 `url_protocols[]` 表(由 protocol_list.c 生成,声明见 libavformat/protocols.c:27-84)中匹配;无 scheme 一律回退 "file"(avio.c:324-327)。
2. `ffurl_connect`(avio.c:210-273)先做白/黑名单校验(avio.c:225-233),再优先调 `url_open2`,没有才退 `url_open`(avio.c:249-254)。
3. `ffio_fdopen`(avio.c:470-527)把 URLContext 包成 AVIOContext:读/写/seek 回调直接绑定为 `ffurl_read2/ffurl_write2/ffurl_seek2`(avio.c:491-492),并把协议的 `url_read_pause/url_read_seek` 挂到 `s->read_pause/s->read_seek`(avio.c:517-523),支持 `AVIO_SEEKABLE_TIME`(avio.c:521-522)。

入口 API `avio_open2 → ffio_open_whitelist2 → url_open_whitelist`(avio.c:559-563, 529-549, 400-459)。

### 1.3 读路径与中断:retry_transfer_wrapper

所有 `ffurl_read*` 最终走 `retry_transfer_wrapper`(avio.c:571-614),这是**中断与超时机制的唯一汇聚点**:

```c
// libavformat/avio.c:581-601
while (len < size_min) {
    if (ff_check_interrupt(&h->interrupt_callback))
        return AVERROR_EXIT;                     // 用户回调要求退出
    ret = read ? h->prot->url_read(...) : ...;
    if (ret == AVERROR(EINTR)) continue;
    if (ret == AVERROR(EAGAIN)) {
        ret = 0;
        if (fast_retries) { fast_retries--; }
        else {
            if (h->rw_timeout) {
                if (!wait_since) wait_since = av_gettime_relative();
                else if (av_gettime_relative() > wait_since + h->rw_timeout)
                    return AVERROR(EIO);         // rw_timeout 超时
            }
            av_usleep(1000);
        }
    }
    ...
}
```

- `ffurl_read2`(avio.c:616-623)以 `size_min=1` 调用——读到任意字节即返回;
- `ffurl_read_complete`(avio.c:625-630)以 `size_min=size` 调用——循环补满;
- `ff_check_interrupt`(avio.c:922-927)就是调用户的 `AVIOInterruptCB`;
- `rw_timeout` 双保险:除上述应用层计时外,TCP 协议还把它设为 socket SO_RCVTIMEO/SO_SNDTIMEO(libavformat/tcp.c:174-176),`tcp_read/tcp_write` 里经 `ff_network_wait_fd_timeout` 带 `interrupt_callback` 轮询(tcp.c:275,291)。所以 RTMP/HLS 的阻塞读"打断"= 用户回调每轮循环被询问一次 + socket 级超时兜底。

### 1.4 hls 为何不是"协议+demuxer 二合一"(纠偏)

任务前提说"hls 是 URLProtocol+demuxer 二合一",**当前树并非如此**:hls.c 只注册 `ff_hls_demuxer`(libavformat/hls.c:3178-3190),全库 grep 无任何 `ff_hls_protocol`;DASH 同理(dashdec.c:2558-2570)。历史上的 hls 协议(逐段下载拼字节流)早已删除——因为它无法支持 seek 与多码率切换。现代实现里,hls demuxer **给每个 media playlist 手工造一个内存 AVIOContext**,读回调指向自己的 `read_data_continuous`:

```c
// libavformat/hls.c:2448-2450
ffio_init_context(&pls->pb, pls->read_buffer, INITIAL_BUFFER_SIZE, 0, pls,
                  read_data_continuous, NULL, NULL);
```

再在这个自造 AVIOContext 上 `avformat_open_input` 一个子 demuxer(mpegts/fMP4)。这就是"demuxer 内部再起 AVIO"的准确形态(详见 §3、§6.2)。

---

## 2. RTMP(rtmpproto.c + rtmppkt.c)

### 2.1 协议注册与嵌套传输

六个 flavor(rtmp/rtmpe/rtmps/rtmpt/rtmpte/rtmpts)用同一宏展开,共享同一组回调(libavformat/rtmpproto.c:3240-3251):`url_open2=rtmp_open`、`url_read=rtmp_read`、`url_write=rtmp_write`、`url_read_seek=rtmp_seek`、`url_read_pause=rtmp_pause`。

`rtmp_open`(rtmpproto.c:2688)按 scheme 拆出嵌套传输:rtmpt/rtmpts→`ffrtmphttp`(2729-2734)、rtmps→`tls`(2735-2739)、rtmpe→`ffrtmpcrypt`(2740-2746)、纯 rtmp→`tcp`(2748-2757,listen 模式加 `?listen&listen_timeout`,2751-2755),随后 `ffurl_open_whitelist` 传入 `&s->interrupt_callback`(2761-2763)——这就是 interrupt_callback 从用户 AVFormatContext 一路下钻到 socket 的路径。

### 2.2 握手 rtmp_handshake(1264-1458)

客户端握手步骤(行号链):

1. 构造 C0+C1:首字节 3(明文)+ uptime + 版本 4 字节 + 1536 字节伪随机(tosend 数组初始化 1267-1274,LFG 填充 1289-1290);
2. Adobe 风格:在 C1 中 imprint HMAC-SHA256 digest(`rtmp_handshake_imprint_with_digest`,1310;实现 1062-1085);
3. 发出 C0+C1(1314-1318),`ffurl_read_complete` 收 S0+S1(1320-1324)、收 C2(1326-1330);
4. 若服务端版本 ≥3,验证 S1 digest:先试偏移 772 再试 8(1336-1353;`rtmp_validate_digest` 1087-1103),失败即 `AVERROR(EIO)`(1350-1351);
5. 用 server_key 计算摘要、再对收到的 C2 前 1504 字节计算签名并与末 32 字节比对(1363-1390,不匹配报 "Signature mismatch" 1387-1390);
6. 生成带 digest 的 C2 回写服务器(1392-1418)。
7. 老式服务器(serverdata[5]<3)走 else 分支:直接把 S1 原样回传当 C2(1427-1446)。

服务器侧 `rtmp_server_handshake`(1501-1563):收 C0 验版本字节==3(1514-1523),回 S0(1524),收 C1、回 S1(随机数填充 1540-1542),把 C1 内容当 S2 回发(1550-1556),再收 C2(1557-1563)。

### 2.3 chunk 机制(rtmppkt.c)

RTMP 消息被切成 chunk;本文件负责打包/解包:

- 读单条:`ff_rtmp_packet_read`(rtmppkt.c:159-169)先 `ffurl_read` 1 字节 basic header,再进 `ff_rtmp_packet_read_internal` 循环(298-311,EAGAIN 则继续读后续 chunk);
- `rtmp_packet_read_one_chunk`(171-296):basic header 低 6 位为 channel id,`<2` 时扩展 1-2 字节(186-194);`hdr>>=6` 得 fmt(203);fmt0/1/2 分别补 11/7/3 字节消息头(204-227);时间字段 0xFFFFFF 时追加 4 字节扩展时间戳(228-234);**每 channel 的半成品包保存在 `prev_pkt[channel_id]`**,fmt1/2 从中继承 size/type/extra(199-201);有效载荷一次只读 `FFMIN(剩余, chunk_size)`(276-283),读不完就把 data 挂回 prev_pkt 并返回 `AVERROR(EAGAIN)`(285-292);
- `prev_pkt` 数组按需扩容:`ff_rtmp_check_alloc_array`(138-157,每次 +16);
- 写:`ff_rtmp_packet_write`(313-414)按"与同 channel 上一包的 type/size/ts_field 相同程度"选 fmt(delta 判断 332-355);body 按 chunk_size 循环,块间插 `0xC0|channel_id` 续块标记(394-412,标记在 400),扩展时间戳在续块也要重复(404-410);
- chunk size 双方默认 128(rtmpproto.c:2779-2780),对端发 `Set Chunk Size` 时 `handle_chunk_size`(rtmpproto.c:1575-1607)更新 `in_chunk_size`,且发送方向会把该控制包原样回显并同步 out_chunk_size(1587-1592)。

### 2.4 命令序列(ASCII 时序)

播放端(is_input)在 `rtmp_open` 中只发 connect(2915-2917),其余命令由 `_result` 触发链式下发(`handle_invoke_result`,rtmpproto.c:2132-2202;tracked method 机制在 `rtmp_send_packet` 239-266,按 invoke id 记账):

```
客户端                                服务器
  |== C0+C1 (1537B, 含digest) =========>|   rtmp_handshake rtmpproto.c:1314
  |<========= S0+S1 ====================|                                  :1320
  |<========= C2 =======================|                                  :1326
  |== C2'(带签名回写) =================>|                                  :1416
  |== connect(app,tcUrl,flashVer) =====>|   gen_connect :330 (AMF@351-437)
  |<======== _result(connect) ==========|
  |== Window Ack Size =================>|   gen_window_ack_size :978 (:2154)
  |== createStream ====================>|   gen_create_stream :732 (:2158)
  |<======== _result(createStream,id) ==|   stream_id 记录 :2172-2178
  |== getStreamLength =================>|   gen_get_stream_length :783 (:2185)
  |== play(playpath, live*1000) =======>|   gen_play :827 (live 偏移@846)
  |== UserControl:SetBufferLength =====>|   gen_buffer_time :805 (:2190)
  |<== NetStream.Play.Start(onStatus) ==|   state→PLAYING :2232
  |<== audio/video chunks ==============>|   get_packet :2504 → append_flv_data :2296
```

推流端对应分支:connect _result 后发 `releaseStream`+`FCPublish`(:2148-2152,gen_release_stream:660 / gen_fcpublish:684),createStream _result 后发 `publish(playpath,"live")`(:2180-2182,gen_publish:904,"live" 字符串在 :923)。状态机枚举 STATE_START…STATE_STOPPED 在 62-70 行;`handle_invoke_status`(2204-2236)把 NetStream.Play.Stop/UnpublishNotify 映射为 STATE_STOPPED(2233-2234)。

### 2.5 直播模式与 FLV 化输出

- `rtmp_live` 选项三态:-2 any / -1 live / 0 recorded(3205-3215);live==-1 时 connect 后补发 `FCSubscribe`(2164-2170,gen_fcsubscribe_stream:1034),play 命令带 `rt->live*1000` 起播偏移(846);
- 输出侧伪装成 FLV:open 时预造 13 字节 FLV header(2941-2947),收到 metadata/首帧后补 HasAudio/HasVideo 标志(2962-2967);`rtmp_read`(2992-3017)从 `flv_data/flv_off` 环形缓冲搬数据;`append_flv_data`(2296-2332)把 RTMP chunk 重排成 FLV tag(11 字节头+PreviousTagSize,2307-2320);无 metadata 且有 duration 时注入伪 onMetaData(`inject_fake_duration_metadata`,2625);
- seek/pause 走协议级:`rtmp_seek`(3019-3038)发 gen_seek(:851)并置 STATE_SEEKING,get_packet 在该状态下吞包直到 onStatus 回 PLAYING(2542-2547,状态复位 2236);`rtmp_pause`(3040-3053)发 gen_pause(:877)——两者经 url.h:81-82 回调暴露给上层(avio.c:517-523 挂接)。

### 2.6 阻塞读如何被打断

`get_packet`→`ff_rtmp_packet_read`→`ffurl_read/ffurl_read_complete`→`retry_transfer_wrapper`(avio.c:571)每轮循环查 interrupt_callback(avio.c:582);连续 EAGAIN 超过 5 次快速重试后按 rw_timeout 计时返回 EIO(avio.c:590-601);底层 socket 另有 SO_RCVTIMEO(tcp.c:174-176,275,291)。RTMP 层无需自己实现任何超时——全靠这三层叠加。

---

## 3. HLS(libavformat/hls.c)

### 3.1 主/媒体 playlist 两级解析:parse_playlist(830-1186)

一个函数同时解析 Master Playlist 与 Media Playlist,靠 `pls` 参数区分(pls==NULL → master,开 playlist 时 hls_read_header:2332 传 NULL):

- `#EXTM3U` 校验(890-893);
- `#EXT-X-STREAM-INF`(907-916):置 is_variant,`ff_parse_key_value` 提取 BANDWIDTH/AUDIO/VIDEO/SUBTITLES(handle_variant_args,404-421);其后第一个 URI 行建 variant(1053-1058 → `new_variant` 378-402);
- `#EXT-X-KEY`(917-930):METHOD=AES-128 → KEY_AES_128(922-923),SAMPLE-AES → KEY_SAMPLE_AES(924-925),IV 十六进制解析(926-929),key URI 暂存;
- `#EXT-X-MEDIA-SEQUENCE`(952-963)→ `pls->start_seq_no`;`#EXT-X-PLAYLIST-TYPE`(964-971)EVENT/VOD;`#EXT-X-MAP`(972-1007)fMP4 init section,无显式 IV 时默认 IV=序列号(987-989);
- `#EXT-X-ENDLIST`(1029-1031)→ `pls->finished=1`(即 VOD 结束标志);
- `#EXTINF`(1032-1039)置 is_segment;`#EXT-X-BYTERANGE`(1040-1048)记 size/offset;
- URI 行(1052-1140):建 segment——无显式 IV 时同样用 `start_seq_no+n_segments` 的大端 64 位作 IV(1070-1076),key 绝对化(1078-1093),URL 绝对化(1095-1103),`test_segment` 探测分片封装(1111),BYTERANGE 连续段偏移累加(1129-1137)。

重载时新旧序列号衔接:reload 后 `start_seq_no` 前移则把差值折算进 first_timestamp(1143-1162)。

### 3.2 variant 选择:AVProgram 而非 bitmask

每个 variant 在 read_header 中建一个 AVProgram(hls.c:2385-2393),`variant_bitrate` 写入 program metadata(2392);每个 playlist 的流通过 `add_stream_to_programs`(2164-2188)挂进所属 program,并回写流级 `variant_bitrate`(2186-2187)。所谓"选择"不是位运算,而是 **AVDISCARD 驱动**:用户 discard 某 program/流后,`recheck_discard_flags`(2614-2657)更新 `pls->needed`,`playlist_needed`(1638-1682)检查 playlist 内流(1650-1655)与其所属 program(1668-1678)是否全被 AVDISCARD_ALL;不需要的 playlist 连 reload 都跳过(reload_playlist:1691-1692 直接 EOF)。

Master→media 二级打开:hls_read_header 若发现 `n_playlists>1` 或首个 playlist 无分片,则对每个 media playlist 再调一次 parse_playlist(2341-2353)。

### 3.3 直播 vs VOD 分片选择

`select_cur_seq_no`(2089-2162):

- 已结束 playlist 且播放中:按当前时间戳在旧列表里找对应序号(2101-2104);
- 直播中切码率:沿用当前 `cur_seq_no`(2107-2114,注释明言协议不保证但实践可行);
- 首次进直播:`live_start_index`(默认 -3,选项 3130-3132)为负从尾部数、为正从头部数(2118-2123);
- `#EXT-X-START` TIME-OFFSET 重算(2126-2156,受 prefer_x_start 选项 3133-3134 控制);
- VOD:直接 `start_seq_no`(2160-2161)。

直播"追尾同步":某 playlist 落后最高序号一个分片时对齐到最新(2433-2436),保证 find_stream_info 能同时看到所有流。

### 3.4 playlist 重载状态机(read_data_continuous + reload_playlist)

每个 playlist 的 AVIOContext 读回调是 `read_data_continuous`(1761-1888);reload 逻辑在 `reload_playlist`(1684-1759):

```c
// libavformat/hls.c:1711-1755(reload 标签循环,节选)
reload:
    reload_count++;
    if (reload_count > c->max_reload)          // :1713 上限,默认 100(选项 3154-3155)
        return AVERROR_EOF;
    if (!v->finished &&
        av_gettime_relative() - v->last_load_time >= reload_interval) {
        parse_playlist(c, v->url, v, NULL);    // :1717 真正重载
        reload_interval = v->target_duration / 2;  // :1726 重载失败降半间隔
    }
    if (v->cur_seq_no < v->start_seq_no) ...   // :1728 窗口滑过则跳到最新
    else if (v->last_seq_no == v->cur_seq_no) {
        v->m3u8_hold_counters++;               // :1738 无新分片计数
        if (v->m3u8_hold_counters >= c->m3u8_hold_counters)  // :1739 默认 1000(选项 3156-3157)
            return AVERROR_EOF;                // :1740 判定直播结束
    }
    if (v->cur_seq_no >= v->start_seq_no + v->n_segments) {   // :1745 还没有新分片
        while (av_gettime_relative() - v->last_load_time < reload_interval) {
            if (ff_check_interrupt(c->interrupt_callback))    // :1749 可被打断
                return AVERROR_EXIT;
            av_usleep(100*1000);               // :1751 100ms 粒度等待
        }
        goto reload;                           // :1754
    }
```

重载间隔 = 最后一个分片时长或 target_duration(`default_reload_interval`,1631-1636)。状态要点:finished(VOD)永不 reload(1715);连续 reload 次数与"无新分片"次数双计数器封顶;等待期间每 100ms 检查一次 interrupt_callback——这就是直播空转如何响应退出。

### 3.5 seek 时 reload 与分片重定位

`hls_read_seek`(2934-3092):直播/EVENT 列表先判断目标时间是否超出已加载窗口,超出且距上次加载超过最小重载间隔则 `parse_playlist` 刷新(2966-2984,注释引 RFC 8216 6.3.4);`find_timestamp_in_playlist`(2050)按分片时长累加映射到 seq_no(2999);BACKWARD seek 吸附到分片起点以落在关键帧(3002-3008);随后关闭所有分片连接、清空子 demuxer 缓冲并 `ff_read_frame_flush`(3026-3047),init section 置空待重取(3052)。

### 3.6 AES-128 加密分片解密路径

1. 解析期:segment 记下 key_type/key URI/IV(parse_playlist 917-930,1070-1093);
2. 取 key:`open_input`(1467)发现 AES-128 且 key URL 与缓存不同则 `read_key`(1436-1465)经 `open_url` 拉 16 字节密钥存 `pls->key`(1447-1462);
3. 解密:**不在 hls.c 内做 AES**,而是把 URL 包装成 `crypto:`/`crypto+` 前缀交给 crypto 协议(1528-1544):

```c
// libavformat/hls.c:1528-1540
if (seg->key_type == KEY_AES_128) {
    ff_data_to_hex(iv, seg->iv, sizeof(seg->iv), 0);
    ff_data_to_hex(key, pls->key, sizeof(pls->key), 0);
    if (strstr(seg->url, "://"))
        snprintf(url, sizeof(url), "crypto+%s", seg->url);   // 嵌套 scheme
    else
        snprintf(url, sizeof(url), "crypto:%s", seg->url);
    av_dict_set(&opts, "key", key, 0);
    av_dict_set(&opts, "iv", iv, 0);
    ret = open_url(pls->parent, in, url, &c->avio_opts, opts, &is_http);
}
```

   这正是 `URL_PROTOCOL_FLAG_NESTED_SCHEME`(url.h:32)的用武之地:crypto 协议在 url_open2 里再 ffurl_open 内层 http。SAMPLE-AES 则不同——分片本体不加密传输,解密推迟到包级:hls_read_packet 检测 `KEY_SAMPLE_AES` 且子 demuxer 非 mov 时调 `ff_hls_senc_decrypt_frame`(2807-2812)。

安全约束:open_url 只放行 http(s)/file/data 三种协议(695-746,file 另查扩展名白名单 710-718);子 demuxer 的 io_open 被替换为 `nested_io_open` 直接拒绝打开任何外部文件(1917-1925)。

传输优化:http_persistent 时 playlist 与分片复用 keep-alive 连接(parse_playlist 854-866,open_url 755-772),http_multiple(HLS/1.1+)可预取下一分片(1832-1846),BYTERANGE 连续段合并为单请求(1495-1515)。

---

## 4. DASH 解析端(libavformat/dashdec.c)

MPD → 时间轴 → 分片 URL 的行号链:

1. **下载与 XML 解析**:`parse_manifest`(1271-1444)经 io_open 拉取 MPD、整读进 BPrint 后 `xmlReadMemory`(1305);根节点必须是 `MPD`(1314-1320),`type="dynamic"` 置 `c->is_live`(1330-1332)。
2. **层级遍历**:MPD→Period→AdaptationSet→Representation,`parse_manifest_representation`(899-1167)为每个 representation 建 `struct representation`;内容类型识别三级回退:representation→contentComponent→adaptationSet(931-943),非音视频/字幕跳过。
3. **BaseURL 解析栈**:MPD/Period/AdaptationSet/Representation 四级 BaseURL 节点数组(974-977)交 `resolve_content_path`(722)合成基础路径(979)。
4. **SegmentTemplate 分支**(985-1063):按 representation→adaptationset→period 优先级在 5 个节点中找 initialization/media/presentationTimeOffset 属性(987-991,`get_val_from_nodes_tab` 533);初始化段 URL 生成(993-1008);media 模板存 `rep->url_template`(1009-1016);`SegmentTimeline` 的 `<S t d r>` 序列经 `parse_manifest_segmenttimeline`(681-721)展开成时间线条目(1055-1063)。
5. **SegmentList 分支**(1078-1108):逐 `<SegmentURL>` 走 `parse_manifest_segmenturlnode`(615-680)生成显式分片列表;单 BaseURL 无列表时整个文件当一个分片(1064-1077)。
6. **时间轴→序号**:`calc_cur_seg_no`(1445-1479)——直播三种模式:n_fragments 直接 first_seq_no(1452-1454);n_timelines 取"末端前 60 秒"(1457-1460);fragment_duration 按 `(now - availability_start_time)*timescale/duration - min_buffer_time` 计算(1461-1474)。`calc_max_seg_no`(1495-1518)处理 `r=-1` 无限重复(1505-1507);`calc_min_seg_no`(1481-1493)按 `time_shift_buffer_depth` 求最老可用分片(1488)。
7. **分片 URL 计算**:`get_current_fragment`(1654-1742)——列表模式直接索引 fragments(1664-1677);模板模式用 `ff_dash_fill_tmpl_params` 填 $Number$/$Time$ 等占位符(1725)生成 URL。
8. **喂给子 demuxer**:`read_data`(1848-1917)是每个 representation 的 AVIO 读回调——取分片 → 先吐 init section(`update_init_section` 1792;read_data 1888-1895)→ 读媒体数据 → EOF 后 cur_seq_no++ 续下一分片(1909-1913)。`reopen_demux_for_component`(1938-1994)`ffio_init_context` 绑定 read_data(1962-1964)、`av_probe_input_buffer` 探测封装(1973)、io_open 同样换成 nested_io_open 禁止外链(1978,实现 1919-1927)。
9. **直播刷新**:`refresh_manifest`(1555)重拉 MPD 并 `move_segments/move_timelines`(1534/1520)迁移游标;get_current_fragment 内 max_reload 限次(1678-1689)。
10. 总装:`dash_read_header`(2142)→ parse_manifest(2154)→ 每个 video/audio representation 调 `open_demux_for_component`(2015,内含 calc_cur_seg_no 初始化 2020)→ 输出流复制进主 AVFormatContext(2032-2052)。注册:`ff_dash_demuxer`(2558-2570)。

---

## 5. mux 侧:hlsenc 与 dashenc

### 5.1 hlsenc.c(分片切割 + hls_window)

- 注册:`ff_hls_muxer`,"hls" 名字,`AVFMT_NOFILE`(3209-3225);
- **切割判定**在 `hls_write_packet`(2426-2709):视频流要求关键帧才可切(`can_split`,2492-2495;split_by_time 例外);累计时长到达 `recording_time(=hls_time)×number` 触发(2469,2519-2521);hls_time 默认 2 秒(3141)。首包 pts 记 start_pts(2479-2490);
- 切割动作:flush 子 muxer → 记 vs->size(2531-2534)→ fMP4 先落 init 段(2535-2551)→ SINGLE_FILE 走 dynbuf(2558-2566)否则按 `crypto:` 前缀打开分片文件带 key/iv(2577-2595)并 flush 落盘(2606-2613),HTTP 上传失败自动换新连接重试一次(2613-2623);
- 登记与窗口:`hls_append_segment`(1045-1146)入链表;EVENT/VOD 强制关闭滑动窗口(1119-1121);`nb_entries ≥ max_nb_segments(hls_list_size,默认 5,3143)` 时摘掉链表头(1123-1136),带 delete_segments 标志时物理删除(1128-1133 → hls_delete_old_segments 532);
- **hls_window**(1547-1689)重写 m3u8:target_duration = 最长分片取整(1600-1603);版本号按特性爬升(1567-1587,如 fMP4→7);EXT-X-KEY 行在有新 key/iv 时输出(1617-1625);每分片 `ff_hls_write_file_entry` 输出 `#EXTINF`(libavformat/hlsplaylist.c:144,调用点 1632-1637);ENDLIST 仅 last 且未 omit(1645-1646);file 协议先写 .tmp 再 rename 原子替换(1558,1593,1679-1683);VOD 不在每分片后重写窗口(2650-2660,仅 trailer 一次)。

### 5.2 dashenc.c(段写出 + manifest 更新)

- **切割判定**在 `dash_write_packet`(1953-2121):关键帧且 `elapsed_duration ≥ seg_end_duration`(2049-2051);use_template&&!use_timeline 时按 `segment_index × seg_duration` 的绝对时间轴(2028-2031),否则按相对 start_pts(2032-2034);时长漂移超 ±10% 告警并建议 use_timeline(2060-2067);seg_duration 默认 5 秒(2281)。
- **段写出**在 `dash_flush`(1793-1925):视频关键帧触发本流 flush,同时同步冲所有音频流(1829-1839);file 协议先写 temp 再 rename(1798-1799,1854-1858);`add_segment`(1633-1672)登记 Segment(time/duration/range),并用 `next_exp_index` 校正落后的段号(1806-1814,1660-1667);窗口清理:`window_size`(默认 0=不裁,2293)+ `extra_window_size`(默认 5)超出即删文件(1879-1886);
- **manifest 更新**:非 streaming 模式在 flush 完成后 `write_manifest(s, final)`(1919-1922);streaming 模式改在段首写(注释 1919-1920);final 时补 trailer/global SIDX(1888-1910);availability_start_time 在首个包时取当前时间写入(1995-2003)。use_template 默认开(2290)。

---

## 6. 设计动机分析

**6.1 为什么协议都实现成 URLProtocol?**
(a)组合性:RTMP 需要 tcp/tls/http 传输、HLS 需要 crypto+http、RTMPE 需要 ffrtmpcrypt——`url_open2` + 选项透传(avio.c:249-254)让任意协议可嵌套任意协议,scheme 语法 `crypto+https:` 靠 NESTED_SCHEME 标志解析(avio.c:345-349);(b)统一抽象:demuxer 只认 AVIOContext,不感知对端是 socket 还是 file,seek/pause 语义由可选回调协商(ffio_fdopen avio.c:514-523);(c)横切策略集中:白名单(avio.c:225-233)、rw_timeout、interrupt_callback 三者只在 URLContext 一层实现(avio.c:571-614),所有协议免费获得;(d)plugin 式扩展:外置协议(libsrt/librtmp 等)与内置协议同表竞争(protocols.c:69-80)。

**6.2 为什么 HLS demuxer 内部再起 AVIOContext?**
HLS 的"文件"不是一个字节流而是一个**随时间增长的分片序列**——没有任何单一 URL 能表达它。于是 demuxer 把"分片序列"伪装成一个无穷字节流:自造 AVIOContext(hls.c:2449-2450)的 read 回调内部完成"取 playlist→选分片→开 HTTP→跨分片续读"(read_data_continuous 1761-1888),mpegts/fMP4 子 demuxer 完全无感知地当作连续输入做 probe 和解析(reopen/probe 流程 2409-2475)。这样:(a)子 demuxer 复用零改动;(b)跨分片的 ID3 时间戳拦截可以在字节流层做(intercept_id3 1336,调用点 1859-1863);(c)crypto/AES 也顺势下沉为 `crypto:` URL(§3.6),解密与解封装彻底解耦。DASH 用完全相同的模式(dashdec.c:1962-1964)。代价是 seek 无法映射为字节偏移,只能自己实现 `read_seek`/重新定位 seq_no(hls_read_seek 2934)并声明 `AVFMT_NO_BYTE_SEEK`(hls.c:3182)。

**6.3 其他值得注意的动机**
- RTMP 输出伪装成 FLV 流(rtmp_read/append_flv_data),使 flvdec 无需知道 RTMP 存在——协议层与格式层再次解耦;
- hls/dash 把"多码率"建模为 AVProgram/多子 demuxer 并行(hls.c:2385-2393;dashdec 每个 representation 一个子 ctx),而不是单 demuxer 内切换,避免了解析器状态丢失;
- "hls" 既是 demuxer 名(hls.c:3179)又是 muxer 名(hlsenc.c:3210),但都不是协议名——用户 `-f hls` 与 `ffprobe hls://...` 走的是完全不同的注册表。

---

## 7. FAQ 素材

1. **Q: rw_timeout 和 interrupt_callback 谁先生效?** A:interrupt_callback 每轮读循环最先被检查,立即返回 AVERROR_EXIT;rw_timeout 只在持续 EAGAIN 时计时,超时返回 AVERROR_EIO——依据 avio.c:582-583 与 595-600。
2. **Q: ffurl_read 和 ffurl_read_complete 的区别?** A:前者 size_min=1 读到任意字节即返回,后者 size_min=size 必须补满——avio.c:616-623 与 625-630。
3. **Q: RTMP 握手为什么要算两次 HMAC-SHA256?** A:第一次验证服务端 C2 签名(用 server_key,rtmpproto.c:1363-1390),第二次构造我方 C2 签名(用 player_key,1392-1418)。
4. **Q: RTMP 默认 chunk size 是多少、何时变?** A:双向默认 128(rtmpproto.c:2779-2780),对端 SetChunkSize 后经 handle_chunk_size 更新 in_chunk_size(1575-1607),发送方还会回显该控制包(1587-1592)。
5. **Q: RTMP 一个大消息怎么读?** A:每 channel 半成品挂在 prev_pkt[],单次最多读一个 chunk_size,未读完返回 EAGAIN 由外层循环续读——rtmppkt.c:276-292 与 298-311。
6. **Q: ffmpeg 的 rtmp_live 选项影响什么?** A:-1(live)时 connect 后补发 FCSubscribe(rtmpproto.c:2164-2170)且 play 命令不带起播偏移,0(recorded)时发 getStreamLength 获取时长(2184-2187)。
7. **Q: HLS 直播列表没有新分片时循环何时退出?** A:连续刷新 m3u8_hold_counters(默认 1000)次仍无新分片判 EOF——hls.c:1734-1741、选项 3156-3157。
8. **Q: HLS AES-128 是 demuxer 自己解密吗?** A:不是,分片 URL 被包成 `crypto:` 交给 crypto 协议,hls 只负责取 key 与传 key/iv 选项——hls.c:1528-1544;SAMPLE-AES 才在包级解密(2807-2812)。
9. **Q: HLS seek 为什么可能先重新拉一次 m3u8?** A:直播窗口在变,目标时间超出已加载区间且超过最小重载间隔时先刷新再映射 seq_no——hls.c:2966-2984。
10. **Q: DASH 模板分片 URL 的 $Number$ 在哪填?** A:get_current_fragment 里 ff_dash_fill_tmpl_params 按 cur_seq_no 与 timeline 起始时间填充——dashdec.c:1725。
11. **Q: hls muxer 的 m3u8 为什么先写 .tmp?** A:file 协议且非 VOD(或显式 temp_file 标志)时先写临时文件再 ff_rename,避免播放器读到半截 playlist——hlsenc.c:1558,1593,1679-1683。
12. **Q: dashenc 的 manifest 什么时候刷新?** A:每个段 flush 完成后 write_manifest(streaming 模式除外,它在段首写)——dashenc.c:1911-1922。

---

## 8. 深挖方向

1. **crypto 协议本体**:libavformat/crypto.c 的 AES-CBC 实现、嵌套 URL 解析与 padding 处理,与 hls.c:1528-1544 的 key/iv 选项对接细节。
2. **ffrtmphttp/RTMPT 隧道**:libavformat/rtmphttp.c 如何把 RTMP chunk 塞进 HTTP POST/响应,rtmp_flush_interval(rtmpproto.c:3210)与 POST 边界的关系。
3. **HLS 字节流层的 ID3 时间戳**:hls.c intercept_id3(1336-1434)与 fill_timing_for_id3_timestamped_stream(2659)如何把裸 AAC 直播流的时间轴拼起来。
4. **rtmp_write 推流侧状态机**:rtmpproto.c:3055-3203 从 FLV tag 流反向解析出 chunk 的完整逻辑(flv_header 缓冲 3074-3110、audio/video channel 选择 3076-3093)。
5. **多码率切换的用户接口**:avformat.find_program_info/discard 如何驱动 playlist_needed(hls.c:1638-1682)与 recheck_discard_flags(2614-2657),对比 dash 的 is_common_init_section_exist 复用优化(dashdec.c:2092)。

---

## 写作要点速查表

| # | 关键函数/结构 | 文件:行号 | 一句话 |
|---|---|---|---|
| 1 | URLProtocol 回调表 | libavformat/url.h:53-99 | url_open2/read/write/seek/read_pause/read_seek 全在此 |
| 2 | URLContext(int_cb+rw_timeout) | libavformat/url.h:35-51 | interrupt_callback@44,rw_timeout@45 |
| 3 | retry_transfer_wrapper | libavformat/avio.c:571-614 | 中断检查@582,rw_timeout 判定@595-600 |
| 4 | ffurl_read2 / read_complete | libavformat/avio.c:616-623 / 625-630 | size_min=1 vs size_min=size |
| 5 | ffio_fdopen 挂接 | libavformat/avio.c:470-527 | read_pause/read_seek 接线@517-523 |
| 6 | scheme→协议查找 | libavformat/avio.c:317-358 | 无 scheme 回退 file@324-327 |
| 7 | rtmp_handshake | libavformat/rtmpproto.c:1264-1458 | 发C0C1@1314,验签@1336-1390,回写C2@1416 |
| 8 | rtmp_packet_read_one_chunk | libavformat/rtmppkt.c:171-296 | EAGAIN 续块@291,read_internal@298-311 |
| 9 | ff_rtmp_packet_write | libavformat/rtmppkt.c:313-414 | 续块标记 0xC0|ch@400 |
| 10 | handle_invoke_result | libavformat/rtmpproto.c:2132-2202 | connect→createStream→play/publish 命令链 |
| 11 | gen_play/gen_publish | rtmpproto.c:827-849 / 904-926 | live*1000@846,"live"@923 |
| 12 | parse_playlist(hls) | libavformat/hls.c:830-1186 | KEY@917,MAP@972,ENDLIST@1029,分片@1052-1140 |
| 13 | reload_playlist | libavformat/hls.c:1684-1759 | reload@1717,hold_counters@1738-1741,等待循环@1748-1752 |
| 14 | read_data_continuous | libavformat/hls.c:1761-1888 | playlist 伪 AVIO 的读回调 |
| 15 | crypto 包装 | libavformat/hls.c:1528-1544 | AES-128 下沉为 crypto: URL |
| 16 | select_cur_seq_no | libavformat/hls.c:2089-2162 | live_start_index@2118-2123 |
| 17 | parse_manifest_representation | libavformat/dashdec.c:899-1167 | SegmentTemplate@985,SegmentList@1078 |
| 18 | calc_cur_seg_no / get_current_fragment | dashdec.c:1445-1479 / 1654-1742 | 时间轴→序号;模板填参@1725 |
| 19 | hls_write_packet / hls_window | hlsenc.c:2426-2709 / 1547-1689 | 切割@2519-2521,EXTINF@1632,滚动窗@1123-1136 |
| 20 | dash_write_packet / dash_flush | dashenc.c:1953-2121 / 1793-1925 | 关键帧+seg_duration@2049-2051,manifest@1919-1922 |
