# 编解码器框架:decode 与 encode 管线

> 源码深读·系统开源项目解读系列 · 第二系列《FFmpeg》
> 基线:master @ 9f63b36a。所有 `文件:行号` 均以该提交为准;行号引用未加 `libavcodec/`、`libavutil/` 前缀时按上下文所属目录理解。

面向有 3-5 年后端经验、但不熟悉音视频的工程师。你可以把本文读成"一个用了 25 年的媒体数据处理框架,如何设计它的作业(job)提交/收割接口、对象生命周期与插件注册机制"。

---

## ① 全景:两条对称的管线

FFmpeg 编解码层的公共 API 只有四个提交/收割函数,解码与编码互为镜像:

| 方向 | 提交 | 收割 | 输入/输出对象 |
|---|---|---|---|
| 解码 | `avcodec_send_packet` | `avcodec_receive_frame` | 压缩包 AVPacket → 像素/采样 AVFrame |
| 编码 | `avcodec_send_frame` | `avcodec_receive_packet` | AVFrame → AVPacket |

有意思的源码布局细节:**send_packet 实现在 decode.c**(decode.c:730),**send_frame 实现在 encode.c**(encode.c:545)——每个文件拥有自己方向的"输入侧";而两个方向的"收割侧"则统一汇聚到 `avcodec_receive_frame`(avcodec.c:720-723),它按 `ff_codec_is_decoder` 分发给 `ff_decode_receive_frame` 或编码器的重建帧输出 `ff_encode_receive_frame`(avcodec.c:715-717)。

两条管线的完整数据流(以解码为主线,编码在括号中给出对偶):

```
        解码                                   编码
用户 pkt --send_packet--> avci->buffer_pkt   用户 frame --send_frame--> avci->buffer_frame
                |  av_packet_ref(引用计数)                |  av_frame_ref / 音频补齐
                v                                        v
        [codec 内置 BSF 链 avci->bsf]            encode_send_frame_internal
                |                                        |
        ff_decode_get_packet                    ff_encode_get_frame
                |                                        |
        decode_simple_internal                  encode_simple_internal
                |  codec->cb.decode()                   |  codec->cb.encode()
                v                                        v
           AVFrame(带 props)                      AVPacket(带 props)
                |                                        |
        ff_decode_receive_frame                 avcodec_receive_packet
                v                                        v
           用户 frame <-- receive_frame           用户 pkt <-- receive_packet
```

`avci`(AVCodecInternal,定义于 libavcodec/internal.h:60-157)是框架的"车间内存":`buffer_pkt`/`buffer_frame` 是 API 与编解码器之间的单格缓冲(满一格返回 EAGAIN),`in_pkt`/`in_frame` 是正在被编解码器消费的半成品,`last_pkt_props` 暂存最近一个包的属性用于给输出帧"贴标签"(internal.h:83-90、144-146)。

驱动注册方面,`codec_list[]` 是构建期生成的静态数组(allcodecs.c:934-941 直接 `#include "libavcodec/codec_list.c"`,由 configure 脚本按编译开关生成),`av_codec_iterate` 顺序遍历它(allcodecs.c:943-953);`avcodec_find_decoder/encoder` 按 codec_id 线性扫描并跳过 experimental 实现(全部 experimental 都被跳过后才作为兜底返回,allcodecs.c:964-983)。codec_desc.c 中 ~800 条 `AVCodecDescriptor` 静态表(codec_desc.c:34 起)提供与具体实现无关的元数据:name、媒体类型、属性位(LOSSY/INTRA_ONLY/REORDER…)与 profile 表,H.264 条目见 codec_desc.c:229-237;查询用二分 `avcodec_descriptor_get`(codec_desc.c:3891-3895)。解码器在 open 时会把描述符缓存到 `avctx->codec_descriptor`(avcodec.c:294),后续 intra-only 判定、字幕格式判定都依赖它。

---

## ② decode 框架逐段解读

### 2.1 send/receive 数据流 ASCII 图

```
用户线程                       decode.c 内部                         编解码器回调
─────────────────────────────────────────────────────────────────────────────────
send_packet(pkt)
  │ pkt 非空? av_packet_ref(buffer_pkt, pkt)      (decode.c:745-748)
  │ pkt 为空? draining_started = 1                 (decode.c:752)
  │ buffer_frame 空则尝试预解码 ───────────────────────────► decode_receive_frame_internal
  ▼                                                              │
receive_frame(frame)                                              │
  │ buffer_frame 有货? move_ref 直接返回           (decode.c:822-823)
  ▼                                                              │
  │            decode_receive_frame_internal      (decode.c:661)
  │              │ 帧线程模式? ff_thread_receive_frame (668-669)
  │              ▼
  │            ff_decode_receive_frame_internal   (decode.c:625)
  │              │ codec 是 receive_frame 型? 直接调 cb.receive_frame (634-651)
  │              ▼ 否则走"简单 API"
  │            decode_simple_receive_frame 循环    (decode.c:609-623)
  │              └► decode_simple_internal        (decode.c:428)
  │                    │ in_pkt 空? ff_decode_get_packet (437-442)
  │                    │     └► av_bsf_send_packet(buffer_pkt) → BSF 链
  │                    │         └► av_bsf_receive_packet → in_pkt
  │                    │     └► extract_packet_props → last_pkt_props (178-187)
  │                    │     └► apply_param_change(采样率/尺寸热更新)(117-176)
  │                    └► codec->cb.decode(avctx, frame, &got_frame, pkt) ──► h264_decode_frame 等
  │                          部分消费? pkt->data += consumed (508-519)
  ▼
frame_validate + apply_cropping + fill_frame_props
+ best_effort_timestamp = guess_correct_pts       (decode.c:830-840, 694-696)
```

### 2.2 send_packet:单格缓冲与"顺手解码"

`avcodec_send_packet` 做三件事(decode.c:730-761):

1. 校验:上下文已 open 且是解码器(736-737);进入 drain 状态后拒绝新包,直接 `AVERROR_EOF`(739-740);
2. 把用户的包**引用计数复制**进 `avci->buffer_pkt`(decode.c:748,`av_packet_ref`);如果传 NULL,则置 `draining_started=1`(decode.c:752),这是"没有更多输入了"的信号;
3. **顺手预解码**:若 `buffer_frame` 还空着,立即尝试产出一帧存进去(754-758)。这解释了 API 语义——send 返回 0 不代表包已消费,只是"收下了"。

框架层会吞掉预解码产生的 EAGAIN/EOF,其它错误才上抛(decode.c:756-757)。

### 2.3 receive_frame:循环收割与四种返回值

`avcodec_receive_frame` 先 `av_frame_unref(frame)` 清空调用方缓冲(avcodec.c:710),然后进入 `ff_decode_receive_frame`(decode.c:817-846)。最终在 `decode_simple_internal`(decode.c:428-522)里驱动编解码器:

- **输入获取**:当前 `in_pkt` 没数据且未 drain,就调 `ff_decode_get_packet`(decode.c:437-442)。后者是包的"装配线"(decode.c:254-284):先把 `buffer_pkt` 喂给解码器私有的 BSF 链(`av_bsf_send_packet`,decode.c:273),再从链尾 `av_bsf_receive_packet` 取出;同时拷贝包属性到 `last_pkt_props`、应用 `AV_PKT_DATA_PARAM_CHANGE` 侧数据(采样率/宽高可随流变更,decode.c:117-176,需要编解码器声明 `AV_CODEC_CAP_PARAM_CHANGE`)。
- **调用编解码器**:`codec->cb.decode(avctx, frame, &got_frame, pkt)`(decode.c:457)。旧式回调按"本次吃掉多少字节"返回 `consumed`;视频解码器如果没出帧,框架将其规范化为 EAGAIN(463-466)。
- **部分消费**:`consumed < pkt->size` 时指针前移、清空 pts/dts 继续用剩余数据(decode.c:508-519)——一个物理包可产出多帧(如某些音频或裸流格式)。
- **drain 防死循环**:drain 期间编解码器每次报错都计数,超过 `20 + 线程数` 就强制 `draining_done=1` 并返回 `AVERROR_BUG`(decode.c:490-506)。这是对"编解码器在 drain 时永远返回错误"这类 bug 的防御。

返回值语义:`0`=拿到帧;`AVERROR(EAGAIN)`=需要再喂包;`AVERROR_EOF`=drain 完成,之后所有调用都返回 EOF;其它负值=流数据错误。**EAGAIN 和 EOF 都是正常控制流**,不是错误。

### 2.4 帧属性组装与 pts 修复

真正返回给用户前,框架做四步收尾(decode.c:661-728、817-846):

1. `detect_colorspace`:从帧上携带的 ICC profile 反推 primaries/trc(decode.c:525-566,需 LCMS2);
2. `fill_frame_props`:帧上"未指定"的颜色、SAR、像素格式、声道布局等字段从 avctx 兜底(decode.c:574-607);
3. 包侧数据 → 帧侧数据:按静态映射表 `ff_sd_global_map`(avcodec.c:57-70)把 DISPLAYMATRIX、STEREO3D、HDR10+ 等从 packet side data 搬到 frame side data(decode.c:1550-1596),`AV_PKT_FLAG_DISCARD` 也会传染成 `AV_FRAME_FLAG_DISCARD`(1584-1586);
4. `guess_correct_pts`(decode.c:296-320):统计 PTS/DTS 各自的单调性违规次数,哪边更可信就用哪边,结果写入 `frame->best_effort_timestamp`。这是对"容器时间戳损坏"的启发式容错,类似数据库里"以更一致的副本为准"。

视频帧还要过 `frame_validate`(宽高/格式合法性,decode.c:791-815)与 `apply_cropping`(把 H.264 SPS 里的裁剪窗口应用到 data 指针偏移,decode.c:763-788;非法裁剪直接清零并告警,769-781)。

### 2.5 hwaccel:格式的协商式挂载点

硬件解码的接入点是 `get_format` 回调协商,而非单独 API:

- 编解码器解析出流参数后,调用 `ff_get_format(avctx, fmt[])` 给出**候选像素格式列表**(decode.c:1229-1365)。约定软件格式排最后(1243-1248,同时记录到 `sw_pix_fmt`)。
- 框架调用 `avctx->get_format`(默认实现 `avcodec_default_get_format`,decode.c:1006-1067)选一个:若用户挂了 `hw_device_ctx`,优先选与之匹配的硬件格式(1014-1031);否则**选第一个软件格式**(1037-1041);都不行才选可 `METHOD_INTERNAL` 自举的硬件格式(1046-1062)。
- 选中的若是硬件格式,框架在 `FFCodec.hw_configs` 数组里按 pix_fmt 找到 `AVCodecHWConfigInternal`(decode.c:1286-1296;结构见 hwconfig.h:24-33,`public` 是暴露给用户的 `AVCodecHWConfig`,`hwaccel` 是内部 `FFHWAccel`),校验用户提供的 `hw_frames_ctx`/`hw_device_ctx` 类型匹配(1305-1337),然后 `hwaccel_init` 把 `avctx->hwaccel` 指过去并调用其 `init`(1182-1215)。校验失败就把该格式从候选表中**剔除并重新协商**(try_again,decode.c:1348-1357)——用户回调只需要"表达偏好",兜底逻辑在框架里。
- 之后解码器分配输出缓冲统一走 `ff_get_buffer`(decode.c:1777-1848):若 hwaccel 有 `alloc_frame` 则由它分配显存表面(1815-1819),否则走用户可替换的 `get_buffer2`;最后附上 `FrameDecodeData`(`frame->private_ref`,decode.c:1704-1775),为 hwaccel 后处理挂钩。

`AVCodecHWConfig` 与解码器的关系一句话概括:**hw_configs 是解码器的"硬件能力清单"**(每个 H.264 hwaccel 编译单元一项,h264dec.c:1172-1204),`AVCodecHWConfig` 是这份清单对用户可见的投影(`avcodec_get_hw_config`,utils.c:857-867)。硬件解码与软件解码由此统一在**同一个解码器实例**内:同一个 `ff_h264_decoder`,`avctx->hwaccel` 为 NULL 就是纯软件路径。

### 2.6 字幕:绕过 send/receive 的旁路

并非所有媒体类型都走主管线。字幕解码器用的是独立的旧式接口 `avcodec_decode_subtitle2`(decode.c:935-1004):输入包直接调 `cb.decode_sub` 产出 `AVSubtitle` 结构,不经过 buffer_pkt/buffer_frame,也没有 EAGAIN 语义。框架在这里额外做两件事:用 iconv 把非 UTF-8 字幕转码(recode_subtitle,decode.c:855-914),以及校验解码产物是合法 UTF-8 否则报 `AVERROR_INVALIDDATA`(decode.c:987-997)。对应地,字幕编码走 `avcodec_encode_subtitle`(encode.c:204-216)。给后端读者的类比:这是框架里保留的一条"旁路快车道",没有进入统一调度模型——迁移成本高于收益,于是和主管线长期并存。

### 2.7 生命周期:open → 使用 → flush → close

`avcodec_open2`(avcodec.c:144-387)的顺序值得背下来:

1. 分配 `AVCodecInternal`(按解码/编码分配不同的 DecodeContext/EncodeContext,avcodec.c:194-201)与 `buffer_frame`/`buffer_pkt`(203-208);
2. 分配编解码器私有上下文 `priv_data` 并填默认值(210-224),随后 `av_opt_set_dict2` 把用户的 AVDictionary option 灌进 avctx + priv_data(226-228)——这就是 ffmpeg CLI 里 `-b:v 2M` 之类参数的注入通道;
3. 参数体检:extradata 上限 256MB(177-178)、宽高(max_pixels)、采样率、声道数(260-291);
4. `ff_encode_preinit`/`ff_decode_preinit`(318-323)。解码侧(`ff_decode_preinit`,decode.c:2029-2159)分配 `in_pkt`/`last_pkt_props`(2129-2132)、初始化**解码器内置 BSF 链**(如 aac 解码器自带的 `aac_adtstoasc`,由 `FFCodec.bsfs` 字符串声明,decode.c:189-222);
5. 线程初始化 `ff_thread_init`(325-333),然后才调用编解码器的 `codec2->init`(337-349);帧线程模式下 worker 的 init 已由 ff_thread_init 完成,主上下文跳过(337 条件);
6. 失败路径统一 `ff_codec_close`(384-386),它按依赖逆序拆除:线程 → close 回调 → 各种缓冲 → hwaccel → bsf → priv_data(avcodec.c:443-507)。`avcodec_is_open` 的判据就是 `avctx->internal != NULL`(avcodec.c:702-705),所以 open 失败后上下文可以安全重开。

`avcodec_flush_buffers`(seek 时调用,avcodec.c:389-419):编码器必须显式声明 `AV_CODEC_CAP_ENCODER_FLUSH` 才支持 flush,否则 no-op 并告警(396-403);解码侧清 `in_pkt`/`last_pkt_props`、BSF 链、pts 修正状态(decode.c:2365-2383),再调编解码器自己的 `flush`(h264 的实现丢弃 DPB 全部参考帧,h264dec.c:476-499)。

### 2.8 encode 侧的 option 传递与差异

编码管线的对应物:

- `avcodec_send_frame`(encode.c:545-576)把帧 `av_frame_ref` 进 `buffer_frame`(562→523);音频帧不足 `frame_size` 时由框架补静音并标记这是最后一帧(encode.c:505-518,`pad_last_frame` 会写入 `AV_FRAME_DATA_SKIP_SAMPLES` 侧数据);传 NULL 开启 draining(559-560)。
- `encode_simple_internal`(encode.c:342-385)取出帧调用 `codec->cb.encode`;对无 `AV_CODEC_CAP_DELAY` 的编码器,空帧直接 EOF(360-363);带延迟的编码器在 drain 时收到 `frame = NULL` 用于冲刷(365-367)。
- **option 传递**:编码器参数 100% 走 avctx 字段 + `priv_data` option。`ff_encode_preinit`(encode.c:898-987)逐项校验:time_base 必须设置(904-907)、像素格式/采样率/声道布局必须命中编码器声明的能力列表(encode.c:709-737、813-888,能力列表来自 `avcodec_get_supported_config`,avcodec.c:818-835)。运行期改参数走 `avcodec_encode_reconfigure`(encode.c:673-694),仅 `AV_CODEC_CAP_ENCODER_RECONF` 编码器支持,且实现是"先 dry-run option 解析、成功才真正应用"(encode.c:642-664)——事务式配置变更的思路。
- 包属性回填 `encode_set_packet_props`(encode.c:233-278):无延迟编码器由框架把 `frame->pts` 搬到 `pkt->pts`;有 `AV_CODEC_PROP_REORDER` 且有延迟的编码器必须自己填(encode.c:314-330 里 `dts = pts` 也仅在无重排时成立)。
- 一个硬约束:**编码器输出的包必须引用计数**(encode.c:420-422 的 `av_assert0(!avpkt->data || avpkt->buf)`);老式编码器给出裸指针时框架代为 `encode_make_refcounted` 拷贝一份(encode.c:137-152)。

---

## ③ AVPacket / AVFrame 的引用计数

两者是同一套 `AVBufferRef`(libavutil/buffer.c)原子引用计数上的两种"容器视图"。理解它们的关键是:**结构体本身不拷贝,引用的是底层 buffer**。

### 3.1 AVPacket

```c
// packet.c:442-476(节选)
int av_packet_ref(AVPacket *dst, const AVPacket *src)
{
    dst->buf = NULL;
    ret = av_packet_copy_props(dst, src);      // pts/dts/flags/side_data 深拷贝
    if (!src->buf) {                           // 源不是引用计数 → 真拷贝数据
        ret = packet_alloc(&dst->buf, src->size);
        memcpy(dst->buf->data, src->data, src->size);
        dst->data = dst->buf->data;
    } else {                                   // 源已引用计数 → 只加引用
        dst->buf = av_buffer_ref(src->buf);
        dst->data = src->data;
    }
    dst->size = src->size;
}
```

要点:

- `av_packet_ref` 在 decode.c:748 被 `avcodec_send_packet` 用来接管用户的包——若用户的包来自 `av_packet_alloc`/demuxer(已引用计数),这一步是 O(1) 加引用 + **props 深拷贝**(side data 每项 memcpy,packet.c:417-429)。所以"零拷贝"只对 data 生效,元数据永远是值拷贝,这是刻意的隔离设计。
- `av_packet_unref`(packet.c:434-440)释放 side data、opaque_ref 与 buf 引用并复位结构体;`av_packet_move_ref`(491-495)是纯指针搬移 + 源清零——框架内部几乎全部用 move 传递,避免多余原子操作(如 decode.c:822-823 输出 buffer_frame 前的 packet move)。
- `av_packet_make_writable`(packet.c:516-536)是 COW(copy-on-write):引用计数 >1 时复制一份再改。BSF 框架在入口强制 `av_packet_make_refcounted`(bsf.c:220),保证链上的包永远可被多个持有者共享。
- side data 有两套 API:挂在 AVPacket 上的老式 `av_packet_new_side_data/get_side_data`(packet.c:231-267),和 6.x 引入的独立数组式 `av_packet_side_data_new/get/remove/free`(packet.c:613-668),后者供 `coded_side_data`(容器级元数据)复用。

### 3.2 AVFrame

AVFrame 的引用结构更复杂,因为一帧可能由多个 buffer 拼成:

- `buf[0..7]`:平面缓冲引用;`extended_buf`:planar 音频声道数超过 8 时溢出的声道(libavutil/frame.c:323-339);`hw_frames_ctx`:硬件表面池的引用(341-347);`side_data[]`:每项自带 AVBufferRef(frame.c:248-272);`private_ref`:解码框架私有的 `FrameDecodeData`(decode.c:703-725,用 refstruct 而非 AVBufferRef)。
- `av_frame_ref`(frame.c:278-374)对**非引用计数的帧**退化为深拷贝(300-310);`av_frame_unref`(496-521)按上面清单逐一释放,最后 `get_frame_defaults` 复位;`av_frame_move_ref`(523-533)O(1)。`av_frame_make_writable`(552-597)同样是 COW。
- 与 AVPacket 不同的地方:props 复制时 side data **共享底层 buffer**(frame.c:262-270 `av_buffer_ref(sd_src->buf)`),只有 `av_frame_copy_props`(force_copy=1,frame.c:599-602)才深拷贝。解码器把帧交给下游 filter/graph 时侧数据随之零拷贝。
- 解码输出路径上真正大量发生的只有两种操作:`av_frame_move_ref` 从 `avci->buffer_frame` 搬到用户帧(decode.c:822-823),以及 H.264 参考帧管理里的 `av_frame_ref`(h264dec.c:915,输出帧加一次引用交给用户,DPB 里仍持有原引用)。一次 1080p 解码每帧只有十几次原子加减,这就是 FFmpeg 敢把"每帧一个 AVFrame"做进公共 API 的底气。

### 3.3 buffer 的对齐与 padding 约定

两个容易被忽略但会直接导致崩溃/性能问题的约定:

- **AV_INPUT_BUFFER_PADDING_SIZE**:每个 AVPacket 的数据末尾必须保留(当前为 64 字节)的可读零填充(packet.c:89-93 分配时强制补齐;encode.c:125 写包后补零)。位读取器以 8/32 字节为粒度批量读取,不逐字节检查边界,这 64 字节是"读越界但有底"的安全垫。自己从网络收包构造 AVPacket 时若漏掉 padding,是最常见的段错误来源。
- **对齐**:帧缓冲默认按 32/64 字节对齐(frame.c:73 `ALIGN = HAVE_SIMD_ALIGN_64 ? 64 : 32`,分配时逐平面对齐,frame.c:135),SIMD 例程直接假设这一点。行尾同样有 linesize ≥ width × bytes 的余量,解码器允许在行尾越界读几个像素。

### 3.4 内存所有权规则速记

| API | 传入对象的所有权 | 返回对象的所有权 |
|---|---|---|
| `avcodec_send_packet(pkt)` | 用户保留;框架 `av_packet_ref`,用户用完自行 unref | — |
| `avcodec_receive_frame(frame)` | frame 须先自行 alloc/unref | 帧归用户,须 unref |
| `avcodec_send_frame(frame)` | 同上,框架 `av_frame_ref` | — |
| `avcodec_receive_packet(pkt)` | 同上 | 包归用户,须 unref |

---

## ④ H.264 解码器案例:h264dec.c 入口流程

`ff_h264_decoder`(h264dec.c:1160-1212)注册的是老式 `decode` 回调(`FF_CODEC_DECODE_CB(h264_decode_frame)`,1168),能力位 `AV_CODEC_CAP_DR1 | DELAY | SLICE_THREADS | FRAME_THREADS`(1169-1171)。DELAY 说明它会积压重排序帧——框架据此允许 drain 阶段用空包冲刷。

一次 `h264_decode_frame`(h264dec.c:1070-1138)的骨架:

```c
// h264dec.c:1070-1130(节选)
static int h264_decode_frame(AVCodecContext *avctx, AVFrame *pict,
                             int *got_frame, AVPacket *avpkt)
{
    if (buf_size == 0)                     // drain:按 POC 顺序吐出延迟帧
        return send_next_delayed_frame(h, pict, got_frame, 0);
    if (av_packet_get_side_data(avpkt, AV_PKT_DATA_NEW_EXTRADATA, NULL))
        ff_h264_decode_extradata(...);     // 运行中热更新 SPS/PPS
    buf_index = decode_nal_units(h, avpkt->buf, buf, buf_size);
    if (!(avctx->flags2 & AV_CODEC_FLAG2_CHUNKS) && (!h->cur_pic_ptr || !h->has_slice))
        return AVERROR_INVALIDDATA;        // 包里没有任何 slice
    ff_h264_field_end(h, &h->slice_ctx[0], 0);   // 去块滤波、POC 收尾
    if (h->next_output_pic)
        finalize_frame(h, pict, h->next_output_pic, got_frame);
    return buf_size;
}
```

`decode_nal_units`(h264dec.c:605-875)概览(不深入 NAL 语法):

1. **切分**:`ff_h2645_packet_split` 把 Annex-B(00 00 01 起始码)或 AVCC(长度前缀)统一拆成 NAL 数组(h264dec.c:632-638);AVCC/Annex-B 的嗅探在 625-630。
2. **帧线程预扫**:帧线程模式下先跑 `get_last_needed_nal` 找出"下一个线程可以开始之前必须读完的 NAL 下标"(h264dec.c:640-643、501-553)——因为 SPS/PPS 可能跟在 slice 后面,而线程副本要靠 `update_thread_context` 拷贝参数,过早放手会读到未初始化的参数集。
3. **逐 NAL 分发**(switch,h264dec.c:659-790):
   - `IDR_SLICE`:先 `idr()` 清空参考队列(660-672);
   - `SLICE`:入队 slice 上下文 `ff_h264_queue_decode_slice`(697);攒满 `nb_slice_ctx`(slice 线程数)就 `ff_h264_execute_decode_slices` 并行解码(719-728);第一个 slice 时若挂了 hwaccel 则触发 `start_frame`(713-717);
   - `SPS/PPS`:解析参数集,且先转发给 hwaccel 的 `decode_params`(750-779)——硬解时参数集要同时喂给 GPU;
   - `SEI`:解析 recovery point 等消息(738-749)。
4. **收尾**:再次 `execute_decode_slices` 清空队列(799-801);解码出错时在帧上置 `FF_DECODE_ERROR_DECODE_SLICES`(804-815),启用错误隐藏时跑 `ff_er_frame_end`(820-867);最后向帧线程报告进度(869-872)。

与框架的衔接点:`finalize_frame`(974-1027)按 `out->recovered`(防"花屏优先")与 `AV_CODEC_FLAG_OUTPUT_CORRUPT` 决定是否出帧,`output_frame`(911-948)里 `av_frame_ref(dst, srcp->f)` 把 DPB 中的图加引用交给框架的 frame——这就是第③节引用计数在真实解码器里的落点。drain 路径 `send_next_delayed_frame`(1029-1068)按最小 POC 重排输出,回应了 `AV_CODEC_CAP_DELAY` 的承诺。

---

## ⑤ BSF 框架:packet 级别的变换器

BSF(Bitstream Filter)做**不改语义、只改封装**的字节级变换:H.264 的 Annex-B↔AVCC(`h264_mp4toannexb`)、提取/改写 metadata 等。它与 decode 的区别一句话:**BSF 输入输出都是 AVPacket,没有时域状态积累意义上的"解码",天然可流式、可逆(多数场景)**;decode 则要维护参考帧、重排缓冲。

框架实现(bsf.c)与 decode 框架惊人地对称,同样是 send/receive + 单格缓冲:

```c
// bsf.c:200-231(节选)
int av_bsf_send_packet(AVBSFContext *ctx, AVPacket *pkt)
{
    if (!pkt || AVPACKET_IS_EMPTY(pkt)) { bsfi->eof = 1; return 0; }   // NULL = EOF
    if (!AVPACKET_IS_EMPTY(bsfi->buffer_pkt))
        return AVERROR(EAGAIN);                                        // 单格缓冲
    av_packet_make_refcounted(pkt);                                    // 强制引用计数
    av_packet_move_ref(bsfi->buffer_pkt, pkt);
    return 0;
}
int av_bsf_receive_packet(AVBSFContext *ctx, AVPacket *pkt)
{
    return ff_bsf(ctx->filter)->filter(ctx, pkt);   // 直通到具体 filter
}
```

关键机制:

- **上下文**:`av_bsf_alloc` 分配 `AVBSFContext`(含 `par_in`/`par_out` 两个 AVCodecParameters 与私有数据,bsf.c:99-145);`av_bsf_init` 校验 `filter->codec_ids` 白名单(如 `h264_mp4toannexb` 只认 H.264,bsf.c:152-169),`par_out` 初始为 `par_in` 的拷贝(173),time_base 直通(177)。
- **链式组合**:`av_bsf_list_parse_str("a=opt1=v,b")` 解析逗号分隔的 filter 串(bsf.c:524-549),多个 filter 装进内置的 `bsf_list` 复合 filter(403-411)。`bsf_list_filter`(310-350)用一个 `idx` 游标在链上做推送-拉取状态机:EAGAIN 逐级回退、EOF 逐级注入(NULL 包向下传,336)。单个 filter 时 `av_bsf_list_finalize` 直接解引用返回,省掉一层包装(492-497)。
- **与 decode 的内嵌关系**:每个解码器可用 `FFCodec.bsfs` 声明内置 BSF 串(codec_internal.h:266-271),`ff_decode_preinit` 里 `decode_bsfs_init` 把它建成 `avci->bsf`(decode.c:189-222),用户送进来的包**先过这条链再进解码器**(decode.c:273、234)。ffmpeg CLI 的 `-bsf:v` 则是用户在 demuxer 与 decoder 之间显式插链。`avcodec_flush_buffers` 也会 `av_bsf_flush`(decode.c:2378-2379)。
- drain 语义与 decode 完全一致:send NULL 置 eof,之后收非 NULL 包报 EINVAL(bsf.c:205-215)。
- **flush 与线程**:av_bsf_flush 复位 eof、清空单格缓冲并透传给具体 filter 的 flush 回调(bsf.c:188-198);链表 flush 则逐级调用并把游标归零(bsf.c:352-359)。BSF 全程不触碰用户线程之外的状态,天然线程封闭——一个 AVBSFContext 同一时间只能被一个线程使用,但多个 BSF 上下文之间无共享。

对后端工程师的心智模型:BSF 是"包级中间件/middleware 链",decode 是"有状态的计算节点";前者像 HTTP header 改写代理,后者像有会话状态的服务。

---

## ⑥ 设计动机与取舍:为什么是 send/receive 而不是回调

FFmpeg 3.1 之前是纯回调式 API(`avcodec_decode_video2`,一进一出)。现在的 send/receive 模型解决了四类问题,源码里都能找到证据:

1. **多输出**:一个输入包可能产出 0/N 帧(音频 AAC 一包一帧尚可,但带 `AV_CODEC_CAP_DELAY` 的解码器在 drain 时要连续吐出重排缓冲),一个输出帧也可能消费多个包(部分消费,decode.c:508-519)。回调的"一进一出"签名表达不了这种 1:N/N:1,receive 侧的循环 + EAGAIN 天然表达(decode_simple_receive_frame 的 `while (!frame->buf[0])`,decode.c:614-620)。
2. **反压(backpressure)**:单格 `buffer_pkt`/`buffer_frame` 满了返回 EAGAIN(avcodec.c/decode.c:746-747),消费者速度跟不上时生产者自然被限流,不会把无限内存耗在队列里——这是有界队列容量为 1 的生产者-消费者模型。
3. **drain/flush 的统一语义**:NULL 包/帧 = EOF 信号(decode.c:752、encode.c:559-560),之后 receive 连续返回帧直至 EOF。API 层面一个哨兵值解决了"解码器内部还有多少帧"的不可知问题。
4. **线程模型的兼容**:帧线程下 send/receive 的边界正好是调度边界——`ff_thread_receive_frame` 把 packet 分发给 worker、按输出顺序收割(decode.c:668-669);receive_frame 型解码器(如部分新解码器)甚至自己拉输入(`cb.receive_frame` + `ff_decode_get_packet`,codec_internal.h:214-221),框架对两种回调形态做了统一适配(decode.c:634-653)。

代价也很清楚:

- 调用方必须写"EAGAIN↔喂包"的状态循环,比回调啰嗦(官方示例 decode.c demo 就是经典 while 循环);
- 单格缓冲意味着 send 与 receive 事实上是**半双工交替**的,无法纯粹流水;
- EAGAIN/EOF 作为正常返回值混在错误通道里,新人容易当错误处理(框架内甚至有 `nb_draining_errors` 防御解码器作者自己犯错,decode.c:493-502)。

其它值得注意的取舍:

- **注册用静态表而非运行时注册**:codec_list 由 configure 生成(allcodecs.c:940),无锁、缓存友好、可裁剪(嵌入式可 configure 掉不用的编解码器);代价是不能像 GStreamer 那样插件热插拔——FFmpeg 的"插件"是编译期开关。
- **packet/frame 双对象而非统一 buffer**:AVPacket 是"编码域"(字节 + 时间戳),AVFrame 是"采样域"(平面数据 + 属性),各自携带类型化的 side data,编译期就能抓住大多数误用。
- **refstruct 与 AVBufferRef 并存**:新代码里帧间共享的元数据(进度、解码错误标志、`FrameDecodeData`)逐步迁到 `av_refstruct`(decode.c:59、1691-1702),因为它支持对象池,避免高频小对象走通用分配器。

---

## ⑦ FAQ

**Q1:`avcodec_send_packet` 返回 EAGAIN,是我的包太大吗?**
不是。EAGAIN 只有一个来源:`avci->buffer_pkt` 还占着没被消费(decode.c:746-747)。正确姿势是先调 `avcodec_receive_frame` 把流水线抽干,再重试 send。包大小与 EAGAIN 无关。

**Q2:send 和 receive 必须严格交替吗?**
不必,但建议循环"send 直到 EAGAIN → receive 直到 EAGAIN"。send 成功后框架可能已经顺手解码出一帧存在 `buffer_frame`(decode.c:754-758),下次 receive 直接 move 出来(decode.c:822-823)。

**Q3:为什么我的解码器一次 send 后要 receive 很多次才 EAGAIN?**
三种典型原因:① 带重排的码流(H.264 有 B 帧),解码器必须积攒 `has_b_frames` 帧才能按序输出,前面的输入在"垫背";② 一个物理包含多个访问单元,`decode_simple_internal` 会在 `in_pkt` 上指针前移反复解码(decode.c:508-519);③ drain 阶段本来就是连续吐帧。

**Q4:drain 之后想继续解码怎么办?**
只能重开上下文或 `avcodec_flush_buffers`。`draining_started` 一旦置位,send_packet 永远返回 EOF(decode.c:739-740);flush 会复位 draining/draining_started 并清空缓冲(avcodec.c:407-412),编解码器侧对应 `flush` 回调(如 h264 丢 DPB,h264dec.c:476-499)。但注意:部分解码器 flush 后仍需新的 IDR 才能输出干净画面。

**Q5:`AVERROR_EXTERNAL`/负值错误后,上下文还能用吗?**
数据错误(`AVERROR_INVALIDDATA` 等)通常可以继续喂包,解码器自带错误恢复(H.264 的 ER,h264dec.c:820-867)。真正要区分的是 `AVERROR(EAGAIN)`/`AVERROR_EOF`(控制流)与其它负值(数据/内部错误)。帧上会带 `decode_error_flags` 供下游识别"这帧是 concealment 出来的"(h264dec.c:804-815)。

**Q6:硬件解码要改多少代码?**
最小路径:给 avctx 挂 `hw_device_ctx`(`av_hwdevice_ctx_alloc/init`),然后什么都不用改——`avcodec_default_get_format` 会自动选中匹配的硬件格式(decode.c:1014-1031),框架自动初始化 hwaccel 并分配 `hw_frames_ctx`(`ff_decode_get_hw_frames_ctx`,decode.c:1069-1118)。拿到的 frame 的 `data[]` 是 GPU 句柄,format 带 `AV_PIX_FMT_FLAG_HWACCEL`,要用 `av_hwframe_transfer_data` 拉回内存或直接送渲染。想精细控制则自己建 `hw_frames_ctx` 传入。

**Q7:同一进程能并发使用多少个 AVCodecContext?**
不同上下文之间无共享可变状态,天然并发;`avcodec_open2` 仅对声明 `FF_CODEC_CAP_NOT_INIT_THREADSAFE` 的编解码器加全局锁(avcodec.c:100-112、327-341)。单个 AVCodecContext 不是线程安全的,多线程消费一个上下文需要外部队列;但可以开帧/片线程让 FFmpeg 内部并行(`AV_CODEC_CAP_FRAME_THREADS/SLICE_THREADS`,h264dec.c:1169-1171)。

**Q8:AVPacket/AVFrame 能不能跨线程传递?**
可以,这正是引用计数存在的意义:`av_packet_ref`/`av_frame_ref` 后把副本交给其它线程,引用计数的原子性(libavutil/buffer.c)保证安全。唯一纪律是每个持有者负责自己的 `unref`,且不要原地改共享数据(要改先 `make_writable`)。

**Q9:profile/level 在哪里生效?**
`avctx->profile` 是**约束**(编码时),`avctx->codec_descriptor->profiles` 是**名称映射表**(展示用)。`av_get_profile_name` 查编码器自带表(utils.c:433-444),`avcodec_profile_name` 查描述符表(utils.c:446-459);解码时 profile 由解码器从码流里读出后回写 avctx,不用用户设置。

**Q10:怎么知道某个解码器支持哪些硬件路径?**
枚举 `avcodec_get_hw_config(codec, i)`(utils.c:857-867)直到返回 NULL,每项给出 pix_fmt、`AV_CODEC_HW_CONFIG_METHOD_*` 位与 device_type。这个列表就是 h264dec.c:1172-1204 那段 `hw_configs` 数组的公开投影。

**Q11:为什么外部库编码器(libx264 等)不是默认选择?**
allcodecs.c 中外部库编解码器被显式注释为 "shouldn't be used by default if one of the above is available"(allcodecs.c:841-842)。`find_codec` 按注册顺序返回第一个命中者(allcodecs.c:971-979),内置实现在 codec_list 中排在外部库之前,因此 `avcodec_find_encoder(AV_CODEC_ID_H264)` 返回内置的(实验性)实现;要用 libx264 必须 `avcodec_find_encoder_by_name("libx264")` 按名字指定。这是一个"注册顺序即优先级"的隐式约定。

---

## ⑧ 深挖问题(供后续调研)

1. **帧线程的数据流契约**:`ff_thread_receive_frame` / `ff_thread_get_packet`(decode.c:266-267、668-671)如何在 worker 之间搬运 packet/frame?`update_thread_context`(h264dec.c:1208)拷贝哪些 H.264 状态、`ff_thread_finish_setup`(h264dec.c:709)的分界意味着什么?这关系到"解码延迟 = thread_count × has_b_frames"的定量解释。
2. **receive_frame 型解码器的统一化**:cb 联合体里 6 种回调形态如何共存(codec_internal.h:191-249)?`FF_CODEC_CAP_SETS_FRAME_PROPS` 省掉 `last_pkt_props` 的条件(decode.c:238、515)说明框架在向"解码器自治"迁移,老的 decode 回调会被淘汰吗?
3. **`frame->private_ref` 与 refstruct 池**:`FrameDecodeData` 的 hwaccel 后处理链(`post_process`,decode.c:703-721)与 LCEVC 增强(decode.c:1717-1772)如何借用 `progress_frame_pool`(decode.c:2134-2143)复用对象?这是理解 FFmpeg 减少每帧 malloc 的钥匙。
4. **BSF 与解析器的边界**:`ff_h2645_packet_split` 在 h264dec.c:632 与若干 BSF 中重复出现,h2645_parse.c 能否抽成公共"NAL 级流抽象"?对比 `h264_mp4toannexb` BSF 与解码器内置 BSF 链(decode.c:189-222)在 AVCC 探测逻辑(h264dec.c:625-630、950-972)上的重复度。
5. **`avcodec_encode_reconfigure` 的事务式参数热更**(encode.c:599-694:dry-run + 双阶段提交)能否推广到解码器?与 `AV_PKT_DATA_PARAM_CHANGE`(decode.c:117-176)触发的隐式参数变更之间的一致性如何保证?

---

### 附:本文引用的核心文件

| 文件 | 职责 |
|---|---|
| libavcodec/decode.c (2515 行) | 解码框架主体:send_packet、BSF 装配、get_format/hwaccel、帧属性 |
| libavcodec/encode.c (1112 行) | 编码框架主体:send_frame/receive_packet、preinit 校验、重配置 |
| libavcodec/avcodec.c (885 行) | avcodec_open2/flush_buffers/codec_close、receive_frame 分发 |
| libavcodec/packet.c (700 行) | AVPacket 生命周期、side data、引用计数 |
| libavutil/frame.c (830 行) | AVFrame 生命周期、引用计数、裁剪应用 |
| libavcodec/allcodecs.c / codec_desc.c | 编解码器静态注册表 / 描述符表与查找 |
| libavcodec/utils.c / hwconfig.h / codec_internal.h | 工具函数、HWConfig 内部结构、FFCodec 抽象 |
| libavcodec/h264dec.c (1212 行) | H.264 解码入口与 NAL 分发 |
| libavcodec/bsf.c (559 行) | BSF 框架:单 filter 与 filter 链 |
