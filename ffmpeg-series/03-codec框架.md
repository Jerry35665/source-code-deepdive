# 第 03 章 · 编解码器框架:send/receive 管线与 H.264 案例

> 基线:commit `9f63b36a`。行号以 `libavcodec/` 为准。

## 3.0 全景:两条对称的管线

FFmpeg 编解码层的公共 API 只有四个函数,解码与编码互为镜像:

| 方向 | 提交 | 收割 | 输入/输出 |
|---|---|---|---|
| 解码 | `avcodec_send_packet` | `avcodec_receive_frame` | AVPacket → AVFrame |
| 编码 | `avcodec_send_frame` | `avcodec_receive_packet` | AVFrame → AVPacket |

**源码布局细节**:send_packet 在 decode.c:730,send_frame 在 encode.c:545——每个文件拥有自己方向的"输入侧";收割侧统一收敛到 avcodec.c:720 按解码/编码分发。**API 的对称性是"形状对称",实现是"每个方向拥有自己的输入侧"。**

框架内存模型是**容量为 1 的单格有界队列**(`buffer_pkt`/`buffer_frame`),满一格返回 EAGAIN——EAGAIN 即反压。

```
解码                                          编码
pkt --send_packet--> buffer_pkt       frame --send_frame--> buffer_frame
        | av_packet_ref                        | av_frame_ref
        v                                      v
  [内置 BSF 链 avci->bsf]              encode_send_frame_internal
        |                                      |
  ff_decode_get_packet                ff_encode_get_frame
        |                                      |
  decode_simple_internal              encode_simple_internal
        | codec->cb.decode()                  | codec->cb.encode()
        v                                      v
   AVFrame                               AVPacket
        |                                      |
  receive_frame                         receive_packet
```

## 3.1 decode 框架逐段

`send_packet` 做 `av_packet_ref` 引用计数后存入 `buffer_pkt`(decode.c:745-748);pkt 为空标记 draining(冲刷模式)。`receive_frame` 时如果 `buffer_frame` 有货直接 move_ref 返回(822-823);否则进入 `decode_receive_frame_internal`(661):

- 帧线程模式走 `ff_thread_receive_frame`(668-669);
- codec 是 receive_frame 型(如某些硬件解码器)直接调回调(634-651);
- 否则走"简单 API"循环:`decode_simple_internal`(428)——先从 BSF 链拉包(437-442),再调 `codec->cb.decode()`。

**解码器内置 BSF 链是隐藏的包预处理层**:每个解码器可用 `FFCodec.bsfs` 字符串声明内置 BSF(decode.c:189-222 在 open 时装配),用户的包先过 `avci->bsf` 再进解码器。bsf.c 的 send/receive + 单格缓冲 + NULL=EOF 语义与 decode 框架同构,`bsf_list_filter`(bsf.c:310-350)用游标状态机实现链式推送-拉取。

## 3.2 AVPacket/AVFrame 引用计数

`AVPacket` 的 data/buf 使用 `AVBufferRef` 引用计数(packet.c):`av_packet_ref` 浅拷贝引用 +1,`av_packet_unref` 引用 -1 归零释放。**多个 AVPacket 可共享同一块压缩数据**——零拷贝传递给解码器。

`AVFrame` 同理(frame.c):视频帧的 data[0-7] 各指向一个 AVBufferRef;**解码器输出的帧可以不拷贝地传给滤镜或编码器**。这是 FFmpeg 转码零拷贝的基础。

## 3.3 H.264 解码器案例

`h264dec.c`(1212 行)是 FFmpeg 中最成熟的解码器之一。入口流程:

1. `h264_decode_init`:分配 h264_ctx(包含 SPS/PPS 解析状态、DPB 解码画面缓冲);
2. `h264_decode_frame`:调 `decode_nal_units` 解析 NAL 包 → 生成/更新 slices → 逐帧输出;
3. `h264_decode_end`:释放 DPB 与解析上下文。

**软件/硬件不是两条管线**:同一个 `ff_h264_decoder`(h264dec.c:1160-1212)靠 `avctx->hwaccel` 是否为 NULL 区分路径。`ff_get_format`(decode.c:1229-1365)让解码器提交候选像素格式列表,用户回调选格式、框架校验 `AVCodecHWConfigInternal` 后把不合格格式剔除并重新协商。

## 3.4 FAQ

**Q1:EAGAIN 是错误吗?**
不是。单格缓冲满/空时返回 EAGAIN,语义是"先把另一侧收割干净再来提交"——这是 send/receive 模型的流控机制。

**Q2:为什么不用回调模型(有数据就调我)?**
send/receive 让调用方完全控制节奏:不调 receive 就不会消费,不会被解码器淹没。回调模型则要求内部排队,增加复杂度。

**Q3:BSF 和 decoder 的区别?**
BSF 在 packet 级做变换(不改数据格式,如提取 H.264 的 SPS/PPS 从 extradata 到每帧);decoder 在 packet 级做解压(输出原始帧)。

**Q4:硬件解码的 codec_id 和软件一样吗?**
一样。`ff_h264_decoder` 只有一个;hwaccel 挂载在 `avctx->hwaccel` 上,解码器在 decode 循环中检测到 hwaccel 就把 IDR 交给 GPU 而非 CPU。

## 3.5 小结与深挖方向

本章结论:**编解码框架 = "单格缓冲 + EAGAIN 反压 + 引用计数零拷贝 + BSF 前置预处理"**;send/receive 的对称性让解码和编码共享同一套框架语义。深挖:

1. 帧线程模式(`ff_thread_receive_frame`)的 DPB 同步;
2. BSF 链的 `bsf_list_filter` 游标状态机与 EOF 传播;
3. hwaccel 的 `AVCodecHWConfigInternal` METHOD 位覆盖范围;
4. `extract_packet_props` 的属性粘贴机制。

> 下一章:滤镜图框架——activate 调度、多输入同步与有理数时间戳。
