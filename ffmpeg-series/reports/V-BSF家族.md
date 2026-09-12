# V 章 — BSF（Bitstream Filter）家族：不解码的比特流手术刀

> 源码基线：ffmpeg master commit 9f63b36a。核心文件：`libavcodec/bsf.c`（559 行）、`libavcodec/bsf.h`（708 行）、`libavcodec/bsf_internal.h`（252 行）、`libavcodec/bitstream_filters.c`、`libavcodec/bsf/` 子目录（50+ 个实现）。所有行号均以该 commit 实测为准。
>
> 03 章一句话带过"BSF 是不解码就改写包的过滤器"，16 章提到"mux 线程出包前过 BSF"。本章把框架机制讲透，再用 6 个代表性实现深拆。

---

## 1. 全景：BSF 在管线中的位置

BSF 的官方定义只有一句：**"Bitstream filters transform encoded media data without decoding it"**（`libavcodec/bsf.h:36-38`）。它操作的对象是 `AVPacket`，输入输出都是"已编码的码流"，不吃帧、不吐帧、不碰 YUV/PCM。

```
        解码侧 (demux → decode)                 编码侧 (encode → mux)
 ┌──────────┐    ┌────────┐    ┌─────────┐    ┌──────────┐    ┌──────┐    ┌──────────┐
 │ AVFormat │    │  BSF   │    │ Decoder │    │ Encoder  │    │ BSF  │    │ AVFormat │
 │ demuxer  │───▶│ (可选) │───▶│  avctx  │    │  avctx   │───▶│(可选)│───▶│  muxer   │
 │ read_pkt │    │        │    │ send/rcv│    │ send/rcv │    │      │    │ write_pkt│
 └──────────┘    └────────┘    └─────────┘    └──────────┘    └──────┘    └──────────┘
   例: demux 侧 extract_extradata 自动补参数集
       例: mux 侧 h264_mp4toannexb / aac_adtstoasc / vp9_superframe

 同一 API 形态：av_bsf_send_packet() 进、av_bsf_receive_packet() 出，
 与 AVCodecContext 的 send_packet/receive_packet 接口"神似但独立实现"。
```

四个挂接点：

| 位置 | 触发者 | 典型例子 | 代码证据 |
|---|---|---|---|
| demux 后、decode 前 | libavformat `demux.c` 自动插入 `extract_extradata` | 裸流缺 extradata 时补 SPS/PPS | `libavformat/demux.c:1449-1457` |
| decode 前（硬件解码器） | 硬件解码器声明 `.bsfs` | QSV/CUVID/MediaCodec 吃 AnnexB | `libavcodec/qsvdec.c:1279`、`libavcodec/cuviddec.c:1847` |
| encode 后、mux 前 | 用户 `-bsf:v` 或 muxer `check_bitstream` 自动挂 | `h264_mp4toannexb` 写裸流 | `fftools/ffmpeg_mux_init.c:1432-1439`、`libavformat/mux.c:1056-1073` |
| 纯手动 API 调用 | 应用代码 | libavcodec 内部编码器也用 | `libavcodec/libaomenc.c:1080`（拿 `extract_extradata`） |

## 2. 框架专节：AVBSFContext 生命周期与零拷贝引用语义

### 2.1 两个结构体：公开壳 + 私有内脏

公开的 `AVBSFContext`（`libavcodec/bsf.h:68-109`）只有 6 个字段：`filter`、`priv_data`、`par_in`、`par_out`、`time_base_in`、`time_base_out`。私有壳 `FFBSFContext`（`libavcodec/bsf.c:36-40`）往后面追加两个字段：

```c
typedef struct FFBSFContext {
    AVBSFContext pub;
    AVPacket *buffer_pkt;   // 单槽缓冲：send 进来的包暂存在这里
    int eof;                // 是否已收到 EOF（空包）
} FFBSFContext;
```

关键点：**框架层没有队列**。`buffer_pkt` 是单槽的——上一包没被 filter 取走，`av_bsf_send_packet` 就返回 `EAGAIN`（`libavcodec/bsf.c:217-218`）。这强制了"send → drain → 再 send"的节拍，与解码器 API 的背压哲学一致（`bsf.h:175-177` 明文要求 send 之后必须 receive 到 EAGAIN/EOF）。需要缓存多包的 BSF（如 vp9_superframe 攒 8 个 alt-ref 帧）自己在 priv_data 里建缓存。

过滤器描述符同样分两层：公开 `AVBitStreamFilter`（`bsf.h:111-131`，只有 name/codec_ids/priv_class），私有 `FFBitStreamFilter`（`libavcodec/bsf_internal.h:29-80`）追加 `priv_data_size`、`init/filter/close/flush` 四个回调，以及一套尚在演化中的 graph/pad/activate 接口（`bsf_internal.h:41-79`，sink/source link、`ff_bsf_graph_run_once`，目前是内部实验性设计）。所有实现文件导出的都是 `FFBitStreamFilter`，公共 API 用 `ff_bsf()` 内联转回（`bsf_internal.h:82-85`）。

### 2.2 生命周期四步：alloc → 填参数 → init → 用完 free

1. **查找**：`av_bsf_get_by_name()` 线性遍历静态注册表（`libavcodec/bitstream_filters.c:100-114`；注册表由 `bsf_list.c` 生成的 `bitstream_filters[]` 数组构成，`bitstream_filters.c:86` include）。`av_bsf_iterate()` 同文件 88-98 行。
2. **分配**：`av_bsf_alloc()`（`bsf.c:99-145`）一次性分配 FFBSFContext、`par_in`/`par_out` 两份 AVCodecParameters、按 `priv_data_size` 分配私有数据并 `av_opt_set_defaults`（123-133 行）、以及一个空的 `buffer_pkt`（134-138 行）。
3. **init**：`av_bsf_init()`（`bsf.c:147-186`）做三件事，顺序固定：
   - **codec_ids 白名单校验**（152-169 行）：比如把 AAC 流喂给 `h264_mp4toannexb` 在这里就被拒；
   - **par_out 先原样拷贝 par_in、time_base_out 拷贝 time_base_in**（173-177 行）——注释明说"init below might overwrite that"；
   - 调 filter 自己的 `init()`（179-183 行）。**extradata 的"一次性变换"就发生在这一步**：h264_mp4toannexb 在 init 里解析 AVCC、把 SPS/PPS 拷进私有缓存并生成 AnnexB 版 par_out->extradata（`bsf/h264_mp4toannexb.c:264-281`）；filter_units 在 init 里对 extradata 做 cbs 读-写一遍完成参数集过滤（`bsf/filter_units.c:202-215`）。
4. **flush / free**：`av_bsf_flush()`（`bsf.c:188-198`）清 eof、unref buffer_pkt、调 filter 的 flush（重置跨包状态但不丢 extradata 缓存——见 h264_mp4toannexb flush 458-465 行只重置 idr 标志）。`av_bsf_free()`（47-70 行）逆序调 close → av_opt_free → 释放 par_in/par_out。

### 2.3 send/receive：移动引用而非拷贝数据

```c
// libavcodec/bsf.c:200-231（节选）
int av_bsf_send_packet(AVBSFContext *ctx, AVPacket *pkt)
{
    ...
    if (!pkt || AVPACKET_IS_EMPTY(pkt)) {   // 空包 = EOF 信号
        if (pkt) av_packet_unref(pkt);
        bsfi->eof = 1;
        return 0;
    }
    if (bsfi->eof) ... return AVERROR(EINVAL);   // EOF 后不许再喂
    if (!AVPACKET_IS_EMPTY(bsfi->buffer_pkt))
        return AVERROR(EAGAIN);                  // 单槽满：背压
    ret = av_packet_make_refcounted(pkt);
    ...
    av_packet_move_ref(bsfi->buffer_pkt, pkt);   // 只挪引用，不拷字节
    return 0;
}
int av_bsf_receive_packet(AVBSFContext *ctx, AVPacket *pkt)
{
    return ff_bsf(ctx->filter)->filter(ctx, pkt); // 直接进 filter 回调
}
```

三条语义由此确立：

- **空包即 EOF**（`bsf.c:205-210`；文档 `bsf.h:182-185`）。"empty"指的是 `pkt==NULL` 或 data/side_data 全空，而不是 `size==0`。
- **send 交出所有权**：`av_packet_move_ref` 把引用整个搬进 buffer_pkt，调用者侧 pkt 复位（`bsf.h:180-181`）。全程无 memcpy。
- **filter 侧取包**有两个出口：`ff_bsf_get_packet_ref()` 把 buffer_pkt 的引用 move 给 filter（`bsf.c:254-267`）——不打算改数据的 filter（null/filter_units 走 cbs 重建/setts）用它，包在输入输出间原引用传递，真正零拷贝；`ff_bsf_get_packet()` 用指针交换 + 补一个新空包（`bsf.c:233-252`）——h264_mp4toannexb 用它，因为要保留原包做源数据、另建输出包。

接收端语义（`bsf.h:209-220`）：0 = 拿到包、`EAGAIN` = 还要再喂、`EOF` = 结束。**N 进 M 出合法**：vp9_superframe 攒 N 包吐 1 包（send 后立刻 EAGAIN），filter_units 整包删光时返回 EAGAIN 把包"吞掉"（`bsf/filter_units.c:140-144`）。

### 2.4 bsf_list：把 N 个 filter 串成一个

`-bsf:v "a=b,c=d"` 语法由 `av_bsf_list_parse_str()` 解析（`bsf.c:524-549`，逗号分隔、`名字=选项`），`av_bsf_list_finalize()`（487-511 行）在只有一个 filter 时直接返回该 filter 本体（免包装），否则套上内置的 `list_bsf`（403-411 行）。链式 filter 的 init 按序级联：上一个的 `par_out`/`time_base_out` 作为下一个的 `par_in`/`time_base_in`（`bsf_list_init`，281-308 行）。运行时 `bsf_list_filter()`（310-350 行）用 `lst->idx` 游标逐级 send/receive，处理 EAGAIN 回退与 EOF 穿透。单个 filter 也可以等价为零 filter：`av_bsf_get_null_filter()`（551-559 行）优先用 `null` BSF——它的 filter 回调就是 `ff_bsf_get_packet_ref` 本身（`bsf/null.c:26-29`），一行直通。

与 AVCodec 的接口差异值得专门对照：BSF 的 `AVBSFContext` 没有 `AVCodecContext` 的封送线程/硬件层，没有 `AVCodec.pad`，回调只有 4 个；codec 的 send/receive 之间隔着 decode 线程与帧缓冲，BSF 的 send/receive 之间只隔着一次函数调用。BSF 也不是 AVCodec 的子类——它有独立的注册表、独立的 `AVERROR_BSF_NOT_FOUND`、独立的 AVClass category（`AV_CLASS_CATEGORY_BITSTREAM_FILTER`，`bsf.c:91`）。

## 3. h264_mp4toannexb 专节：MP4(AVCC) → 裸流(AnnexB)

这是整个 BSF 家族最重要的成员，解决一个格式鸿沟：MP4/MKV 存 H.264 用"4 字节大端长度前缀 + NALU"（AVCC），参数集放在 extradata（avcC 盒子）；而 TS/裸流要求每个 NALU 前面是 `00 00 00 01` 起始码（AnnexB），参数集必须周期性内联在码流里。多数硬件解码器和所有 TS 复用器只吃 AnnexB。

### 3.1 init：解析 avcC extradata（一次性）

`h264_mp4toannexb_init`（`bsf/h264_mp4toannexb.c:264-281`）先判断输入是否已是 AnnexB：extradata 开头 3/4 字节是 `00 00 01` 直接放行（269-275 行）。否则进 `h264_extradata_to_annexb()`（84-190 行）：

- 跳过 avcC 头 4 字节，第 5 字节低 2 位 +1 得 `length_size`（107 行，通常为 4）；
- 循环读 SPS/PPS 单元：每个单元前有 2 字节长度（119 行），单元总数在第 6 字节的低 5 位（110 行）。每读一个单元，就在输出缓冲里写 `00 00 00 01` + NALU 内容（130-131 行，`nalu_header[4]={0,0,0,1}` 定义在 93 行）；
- **sps 偏移缓存**：`pps_offset` 记录 PPS 在临时缓冲里的起点（135 行），之后 SPS 段拷进 `s->sps`、PPS 段拷进 `s->pps` 两块可复用缓冲（142-169 行，用 `av_fast_realloc` 控制内存预算，缓冲只增不减，close 时释放 450-456 行）；
- 同时把 AnnexB 化的完整 extradata 写进 `ctx->par_out->extradata`（279-280 行）——下游 muxer 拿到的参数已经是目标格式。

### 3.2 filter：两遍扫描，逐包重写

每包进入 `h264_mp4toannexb_filter`（283-448 行）后：

1. 先处理 `AV_PKT_DATA_NEW_EXTRADATA` side data——上游动态换参数集时重新解析（300-308 行）；
2. 若 extradata 从未解析成功，原包直通（311-315 行）；
3. `h264_mp4toannexb_filter_ps()`（221-262 行）第一遍快速扫包，把**包内自带**的 SPS/PPS 更新进缓存（`save_ps`，192-219 行）——流内参数集比 avcC 里的新，永远以流内为准；
4. 然后是核心的**两遍算法**（`for (int j = 0; j < 2; j++)`，325 行）：j=0 只计数不拷贝（算出输出精确尺寸），据此 `av_new_packet` 分配输出（419-428 行）；j=1 真正填写。避免边写边 realloc。

长度前缀 → 起始码的替换循环（332-417 行）：

```c
// libavcodec/bsf/h264_mp4toannexb.c:332-341（j 循环体内，节选）
do {
    uint32_t nal_size = 0;
    for (int i = 0; i < s->length_size; i++)          // 读 length_size 字节大端长度
        nal_size = (nal_size << 8) | buf[i];
    buf += s->length_size;                            // 跳过长度前缀
    if ((int64_t)nal_size > buf_end - buf) {          // 越界校验(防恶意流)
        ret = AVERROR_INVALIDDATA; goto fail;
    }
    ...
    unit_type = *buf & 0x1f;                          // NALU 类型
```

每遇到一个 NALU，`count_or_copy()`（55-82 行）决定写什么：SPS/PPS 自带时写 3 字节起始码（非首 NALU）或 4 字节（首 NALU，PS_IN_BAND / out_size==0 分支）；普通 NALU 一律写 3 字节 `00 00 01`（PS_NONE）。**4 字节长度前缀就这样被 3-4 字节起始码替换**，输出包尺寸随之略变（长度前缀 4 字节 → 起始码 3 字节，SPS/PPS 注入时变大）。

参数集注入逻辑（这是"为什么"的答案）：

- 包内有 PPS 但没 SPS → 把 avcC 缓存的 SPS 前置（359-366 行）；
- IDR 帧（`H264_NAL_IDR_SLICE`，类型 5）且 `new_idr` 且流内还没出现过 SPS/PPS → 前置缓存的 SPS+PPS（390-395 行）——解码器从 IDR 开始需要参数集；
- buffering period SEI 出现但参数集缺席 → 同样前置（377-387 行）；
- 遇到非 IDR 普通切片（类型 1）→ 重置 `new_idr/sps_seen/pps_seen`（410-414 行），保证下一个 IDR 再次注入。

跨包状态（`new_idr/idr_sps_seen/idr_pps_seen`，结构体 43-45 行）在包间延续、flush 时复位（458-465 行）——所以同一个 MP4 切成两段 TS，两段开头都会被注入参数集。收尾时 `av_assert1(out_size == opkt->size)` 验证两遍扫描一致性（432 行），`av_packet_copy_props` 搬运 pts/dts/side data（438 行）。

### 3.3 为什么不反过来做

AnnexB→AVCC（去掉起始码、参数集抽进 extradata）由 `extract_extradata`（remove=1）+ 封装器协作完成，或者用 `vvc/hevc_mp4toannexb` 的反向兄弟（如 `hevc_mp4toannexb.c` 同型实现）。TS→MP4 场景较少，因为 MP4 muxer 本来就能吃 AnnexB 后自行打包（movenc 的 `ff_avc_parse_nal_units` 路径），而反向（MP4→TS）是高频刚需。

## 4. aac_adtstoasc 专节：ADTS → 裸 AAC + ASC extradata

ADTS（Audio Data Transport Stream）是 AAC 的"自带包头"格式：每帧前 7 字节（含 CRC 则 9 字节）头。MP4/FLV/MKV 存 AAC 要求**头只存一次**（extradata 里的 AudioSpecificConfig，ASC），帧体裸放。这个 BSF 就是中间转换器（`bsf/aac_adtstoasc.c`）：

```c
// libavcodec/bsf/aac_adtstoasc.c:51-73（节选）
if (bsfc->par_in->extradata && pkt->size >= 2 && (AV_RB16(pkt->data) >> 4) != 0xfff)
    return 0;                                   // 已经是裸 ASC 流: 直通
if (pkt->size < AV_AAC_ADTS_HEADER_SIZE) goto packet_too_small;
if (ff_adts_header_parse_buf(pkt->data, &hdr) < 0) ...   // 解析 7 字节头
...
pkt->size -= AV_AAC_ADTS_HEADER_SIZE + 2 * !hdr.crc_absent;  // 剥头(带CRC则9字节)
if (pkt->size <= 0) goto packet_too_small;
pkt->data += AV_AAC_ADTS_HEADER_SIZE + 2 * !hdr.crc_absent;  // 指针前移,零拷贝
```

三个设计点：

1. **extradata 从第一个包的头部现场生成**（75-118 行）：用 PutBitContext 按 ASC 位流语法拼 13 位——5 位 object_type + 4 位 sampling_index + 4 位 chan_config + 3 个标志位（106-112 行），以 `AV_PKT_DATA_NEW_EXTRADATA` side data 的形式交给下游（98-99 行），由 muxer（如 movenc）取走写进 stsd。只做一次（`first_frame_done` 标志，117 行）。
2. **PCE 处理**：当 ADTS 头里 `chan_config==0`（非常规声道布局），真正的声道信息在帧内 PCE 语法元素里。代码校验帧首 3 位是 `5`（PCE 前导），用 `ff_copy_pce_data()` 把 PCE 原样拷出追加到 ASC 后面，并把帧体指针跳过 PCE（80-96 行）。
3. **init 时校验已有 extradata**（130-144 行）：若 par_in 已带 ASC，用 `avpriv_mpeg4audio_get_config2` 解析一遍确认合法——不合法直接 init 失败，比流中途爆掉好。

对比 h264_mp4toannexb：这个 filter **不重建输出包**，只做指针/长度手术（pkt->data += 7），是家族里最"零拷贝"的重写者；而 extradata 的产出靠 side data 而非 par_out（它没实现"把 extradata 写进 par_out"的路径）。

## 5. 通用手术刀三件

### 5.1 filter_units：按 NALU 类型增删

`filter_units` 建立在 CBS（Coded Bitstream Component，`libavcodec/cbs.h`）之上——CBS 把包解析成单元数组，改完再序列化回去。支持 H.264/H.265/H.266/AV1 等 `ff_cbs_all_codec_ids`（`bsf/filter_units.c:283`）。选项三组（232-272 行）：

- `pass_types`：白名单，只留列出的单元类型；`remove_types`：黑名单，删掉列出的类型。二者互斥（165-169 行）。支持 `5|6|9-15` 区间语法（`filter_units_make_type_list`，54-106 行，两遍扫描先计数后填充）。
- `discard`：按 AVDiscard 语义整帧丢弃（nonref/bidir/nonkey/all 等，240-263 行），交给 `ff_cbs_discard_units`（127 行）。
- 三者都没配 → `passthrough=true`，包原引用直通（118-119 行、187-190 行）。

主循环倒序删单元（129-137 行，倒序避免索引移动）；**整包删空时返回 EAGAIN 吞包**（140-144 行："Don't return packets with nothing in them"）；init 时对 extradata 也做同样的读-过滤-写（202-215 行）。典型用法：`-bsf:v "filter_units=remove_types=6"` 删所有 SEI。

### 5.2 extract_extradata：从码流里"钓"出参数集

这个 filter 的特殊之处是**不改包本身（默认）**，而是从包里扫描参数集，打包成 `AV_PKT_DATA_NEW_EXTRADATA` side data 附加在输出包上（`bsf/extract_extradata.c:635-643`）。下游 demuxer/muxer 认识这个 side data。按 codec 分派到 7 种提取器（`extract_tab`，584-601 行）：AV1 找 sequence header OBU + 全局 metadata（96-164 行）、H.264/HEVC/VVC 用 `ff_h2645_packet_split` 找 SPS/PPS(/VPS)（166-275 行）、MPEG-1/2 找 0x1B3 序列头（526-553 行）、MPEG4/AVS 找 0x1B3/0x1B6（555-582 行）、VC1 找 SEQHDR/ENTRYPOINT（491-524 行）、LCEVC 有专门的 SEI 剥离逻辑（283-489 行）。

门槛校验（222-225 行）：H.264 必须见到 SPS、HEVC 必须 VPS+SPS 齐活才生成 extradata，防半个参数集误导下游。`remove=1` 选项反向操作：把参数集从码流里**剥掉**只留 extradata（230-271 行，重建 filtered_buf 换掉 pkt->buf）——用于 "参数集只进 extradata" 的封装（MP4 系）。

**谁在用它**：demux 侧，`libavformat/demux.c` 在流参数更新后发现 `avctx->extradata` 为空时自动建一个（2477-2515 行建、2517-2564 行逐包喂数据直到钓出 extradata 塞回 `sti->avctx`）；mux 侧，FLV muxer 对没有 extradata 的 H.264/HEVC/VVC/AV1/MPEG4 自动挂（`libavformat/flvenc.c:1495-1502`）；编码器内部也用（`libavcodec/libaomenc.c:1080`、`libavcodec/qsvenc_av1.c:117`）。

### 5.3 setts：时间戳表达式重写器

唯一不碰 data、只碰 pts/dts/duration 的 BSF（`bsf/setts.c`）。四个表达式选项 `ts/pts/dts/duration`（274-282 行），可用变量 21 个（32-55 行）：N（帧号）、TS、PREV_INPTS/PREV_OUTDTS（前后包时间戳）、NEXT_PTS、STARTPTS、TB/TB_OUT、SR 等。init 时 `av_expr_parse` 编译（119-145 行），filter 时逐包求值并 llrint 取整（210-224 行）。

最巧妙的细节是**延迟一包**：因为表达式引用 `NEXT_PTS`（下一包的值），filter 把当前包在 `s->cur_pkt` 里扣一拍，等下一包来了才输出上一包（179-186 行 + 227-232 行的引用轮换）——send/receive 的 EAGAIN 机制天然支持"吃一包吐零包"。`time_base` 选项还能顺带改输出时基（147-154 行），`prescale=1` 决定变量在求值前还是求值后做时基换算（171、236-240 行）。

## 6. vp9_superframe：一个"隐形必需"案例

VP9 有个别致的设计：不可见帧（alt-ref，`show_existing_frame`/invisible 标志为 1 的帧，用于前向参考不用于显示）在 WebM/IVF 存储时要**合并进 superframe**——多帧拼接，尾部再加一个 marker 字节索引（`110[mag:2][nframes:3]`）。解封装器解出来的 alt-ref 是独立的包；直接喂给要求 superframe 语法的封装（WebM）或硬件解码器就会炸。`vp9_superframe` BSF 就是自动补齐：

```c
// libavcodec/bsf/vp9_superframe.c:120-161（节选）
marker = pkt->data[pkt->size - 1];
if ((marker & 0xe0) == 0xc0) { ...uses_superframe_syntax = ...; }  // 已是superframe?
...
if (get_bits1(&gb)) { invisible = 0; }        // 非关键帧路径
else { get_bits1(&gb); invisible = !get_bits1(&gb); }  // 读 invisible 标志
...
} else if ((!invisible || uses_superframe_syntax) && !s->n_cache)
    return 0;                                  // 可见帧: 直通(零拷贝)
...
av_packet_move_ref(s->cache[s->n_cache++], pkt);
if (invisible) return AVERROR(EAGAIN);        // 攒着,先不出
// 可见帧到来: merge_superframe() 把缓存的所有帧拼成一个superframe输出
```

`merge_superframe`（52-99 行）按最大帧尺寸选索引字宽 mag（0-3 字节，59 行），写 `marker + 各帧长度 + marker` 尾索引。缓存上限 `MAX_CACHE=8`（28 行），超过报错（151-155 行）。它是"BSF 作为隐形兼容层"的标本：用户从没写过 `-bsf:v vp9_superframe`，但 `ffmpeg -i in.webm -c:v copy out.ivf` 能跑通，靠的就是 IVF muxer 自动挂载（`libavformat/ivfenc.c:42`）、movenc/mkv muxer 对 VP9 自动挂载（`libavformat/movenc.c:9247-9248`、`libavformat/matroskaenc.c:3638-3639`）。

## 7. 集成专节：-bsf:v 用户路径与 mux 自动挂接

### 7.1 用户路径：-bsf:v → av_bsf_list_parse_str → mux 线程

1. 选项注册：`fftools/ffmpeg_opt.c:2054-2056`，`"bsf"` 是 OPT_PERSTREAM 选项（所以有 `-bsf:v`、`-bsf:a`、`-bsf:s` 流指定符），存进 `o->bitstream_filters`。
2. ost_add 时解析：`fftools/ffmpeg_mux_init.c:1432-1439`，`av_bsf_list_parse_str(bsfs, &ms->bsf_ctx)` 把逗号串变成链式 BSF（或 NULL 直通）挂到 `MuxStream.bsf_ctx`（`fftools/ffmpeg_mux.h:48`）。
3. 参数就位：真正的 init 被推迟到 `bsf_init()`（`fftools/ffmpeg_mux.c:572-604`）——此时编码器参数已定，`par_in` 拷自 `ms->par_in`、`time_base_in` 拷自流时基、`av_bsf_init` 后把 `par_out`/`time_base_out` **回写**给输出流的 codecpar/time_base（594-597 行）——BSF 改了 extradata 这件事由此传导给 muxer。
4. mux 线程过包（16 章的衔接点）：`fftools/ffmpeg_mux.c:315-354`。每个包先 `av_packet_rescale_ts` 到 `bsf_ctx->time_base_in`，send 之后 while 循环 receive 到 EOF；`EAGAIN` 直接返回（等下一包再驱赶），`EOF` 时以 NULL 包触发 sync_queue 收尾。输出包时间戳按 `time_base_out` 标记（343 行）。没有 BSF 的流走 else 分支直通（350-354 行）。

### 7.2 自动挂接：check_bitstream 回调 + AVFMT_FLAG_AUTO_BSF

封装器通过 `check_bitstream` 回调声明"我需要什么格式"，mux 通用层在每个输出包上调用一次（首个包检查后记忆，`libavformat/mux.c:1056-1073`，受 `AVFMT_FLAG_AUTO_BSF` 开关控制，`-fflags +nobuffer` 反义为 `-fflags +autobsf-`）；命中则调 `ff_stream_add_bitstream_filter()`（1294-1335 行）就地给流装一个 BSF，日志 "Automatically inserted bitstream filter"（1331-1333 行）。实际写包路径在 `write_packets_common()`（1151-1174 行）：有 bsfc 就走 `write_packets_from_bsfs()`（1118-1149 行）send/receive 循环 + 时基重缩放。实测的自动挂接条件：

| muxer | 条件（文件:行号） | 自动插入 |
|---|---|---|
| h264/vvc/hevc 裸流 | 首包开头不是 `00 00 01` 起始码（`libavformat/rawenc.c:389-391,414-416,439-441`） | `*mp4toannexb` |
| MP4/MOV | AAC 且首两帧字节是 ADTS 同步字 `0xFFFx`（`libavformat/movenc.c:9241-9244`）；VP9 无条件（9245-9247） | `aac_adtstoasc` / `vp9_superframe` |
| Matroska/WebM | AAC 同步字（`matroskaenc.c:3634-3637`）；VP9（3638-3639）；PGS 字幕（3640-3642） | 同上 + `pgs_frame_merge` |
| FLV | ADTS 同步字；或 H.264/HEVC/VVC/AV1/MPEG4 缺 extradata（`flvenc.c:1490-1502`） | `aac_adtstoasc` / `extract_extradata` |
| IVF | VP9（`ivfenc.c:42`）；AV1 补插入 temporal delimiter（`ivfenc.c:46`） | `vp9_superframe` / `av1_metadata td=insert` |
| MPEG-TS | 按 descriptor 表（`mpegtsenc.c:2376`，如 AAC LATM） | 各类 |
| mxf | H.264 且非 AnnexB（`mxfenc.c:3636`）；PCM 重分块（3081 行） | `h264_mp4toannexb` / `pcm_rechunk` |

demux 侧的自动插入见 5.2 节（extract_extradata）。**规则总结：容器要"参数集进 extradata、帧体裸放"就挂 adtstoasc/extract_extradata；容器要"起始码内联"就挂 mp4toannexb；容器有特殊帧语法就挂对应语法修补器。**

## 8. 设计动机：为什么 BSF 独立成层

1. **格式转换的正交性**。编码器只管产码流，封装器只管装箱；两者对码流"外壳"（起始码 vs 长度前缀、参数集内联 vs 外置、superframe 语法）的诉求常常冲突。若把转换塞进编码器，每个编码器要适配每种封装（M×N 组合）；塞进封装器，每个封装器要理解每种码流（同样 M×N）。BSF 把它抽成可插拔的中间件，M+N 个实现解决 M×N 个组合——check_bitstream 自动挂接（mux.c:1056）就是这种正交性的运行时体现。
2. **零拷贝引用的意义**。BSF 常见于 `-c copy` 流拷贝场景，此时整条管线唯一的 CPU 开销就是 BSF 本身。send/receive 全程 move_ref（bsf.c:220-223、264），不改数据的 filter（null、setts 之外的 passthrough 分支）输出就是输入的同一个引用，成本为零；要改写时也尽量指针手术（aac_adtstoasc 只挪 pkt->data）。对比一个"总是深拷贝"的设计，4K 60fps 场景每秒省下数百 MB 的 memcpy。
3. **init 时一次性 extradata vs 逐包变换**。extradata 是"流级常量"（个别动态更新的除外，走 NEW_EXTRADATA side data 通道，h264_mp4toannexb.c:300-308），把它的工作放在 init（bsf.c:179-183）意味着：每包处理只需查缓存的 SPS/PPS 指针，无解析开销；且 par_out 在 init 后立即定型，muxer 写文件头时就能拿到正确的 extradata——若推迟到首包才生成，文件头可能已带着空 extradata 写出去了。逐包状态（idr_seen 标志、vp9 缓存、setts 的 prev 包）则严格限定在 filter 回调内，flush 回调负责清场。

## FAQ 素材

1. **Q: BSF 和 AVFilter 什么区别？** A: BSF 操作编码后的 AVPacket（不解码），AVFilter 操作解码后的 AVFrame；BSF 在 libavcodec，AVFilter 在 libavfilter；BSF 的"图"只有线性 list（bsf.c:403-411 的 list_bsf），AVFilter 有真正的 DAG。
2. **Q: 为什么 send 之后必须循环 receive？** A: 单槽 buffer_pkt（bsf.c:36-40）+ 契约规定（bsf.h:175-177）。不清空就 send 会得到 EAGAIN；N 出型 filter（vp9_superframe）一包进多包出。
3. **Q: 为什么有的包进去就"消失"了？** A: filter_units 把 NALU 删光时返回 EAGAIN（filter_units.c:140-144），vp9_superframe 把 alt-ref 攒起来（vp9_superframe.c:158-161）——BSF 合法地改变包数。
4. **Q: -bsf:v 和 muxer 自动插入的 BSF 会叠加吗？** A: 会共存于不同层：用户的在 fftools 层（ffmpeg_mux.c:315），muxer 的在 libavformat 层（mux.c:1169），同一个包会先后过两道。同名 BSF 重复挂载会各自实例化。
5. **Q: 怎么关掉自动 BSF？** A: `AVFMT_FLAG_AUTO_BSF` 标志（mux.c:1060），命令行 `-fflags +autobsf-`（默认开启）。
6. **Q: h264_mp4toannexb 对已经是 AnnexB 的流做什么？** A: init 检测 extradata 开头是起始码就跳过解析（h264_mp4toannexb.c:269-275）；即使解析了，filter 检测到 `extradata_parsed==0` 也原包直通（311-315 行）——所以"重复挂"无害。
7. **Q: aac_adtstoasc 遇到 CRC 帧怎么办？** A: 头长度按 7+2*CRC 处理（aac_adtstoasc.c:70-73），CRC 尾随字节跟头一起剥掉。
8. **Q: BSF 能动态改参数集吗？** A: 能，约定通道是 AV_PKT_DATA_NEW_EXTRADATA side data：上游 demuxer/BSF 附加，下游 BSF 消费后移除（h264_mp4toannexb.c:300-308），demuxer 也能钓它做 avctx->extradata（demux.c:2550-2559）。
9. **Q: setts 为什么输出总慢一帧？** A: NEXT_PTS 变量需要预读下一包，实现上延迟一拍输出（setts.c:179-186）。
10. **Q: BSF 之间怎么传 options？** A: 字符串语法 `name=opt1=v1:opt2=v2`，由 `av_opt_set_from_string` 解析（bsf.c:455-465）。

## 深挖方向

1. **新 graph-based BSF API**：bsf_internal.h:41-79 已预留 pad/activate/`ff_bsf_graph_run_once` 与 source/sink BSF（`bsf/source.c`、`bsf/sink.c`，bitstream_filters.c:83-84 特意注释"formatted to not be found by grep"）。这是把 libavfilter 的 activate 调度模型移植进 BSF 的进行时工程，值得跟踪后续 commit。
2. **hevc/vvc_mp4toannexb 与 h264 版的算法差异**：HEVC 有 2 字节 NALU 头、参数集是 VPS/SPS/PPS 三件套（`bsf/hevc_mp4toannexb.c`）；VVC 版用 `h2645_parse` 复用解析（vvc_mp4toannexb.c:193-322）。三兄弟对比可写一篇"同一算法的三个时代"。
3. **dts2pts BSF**（bsf/dts2pts.c）：用 H.264 picture timing SEI + CTS 反推 PTS，是家族里最"重"的时序修复器，可与 setts 对比"表达式重写 vs 语义推导"两条路线。
4. **CBS 的开销问题**：filter_units/h264_metadata 系列都要 cbs read+write 全包，对比 h264_mp4toannexb 的手工逐字节替换，量化两种写法的性能差（CBS 有分配/释放单元的开销）。
5. **pcm_rechunk**（bsf/pcm_rechunk.c）：唯一的"按采样数重组包"BSF，daudenc/gxfenc/mxfenc 用它凑固定块（libavformat/daudenc.c:44），是"BSF 做复用器整形"的另类样本。

## 写作要点速查表

| 事实 | 文件:行号 |
|---|---|
| FFBSFContext：buffer_pkt 单槽 + eof | libavcodec/bsf.c:36-40 |
| av_bsf_alloc：分配 par_in/par_out/priv_data | libavcodec/bsf.c:99-145 |
| av_bsf_init：codec_ids 校验→par_out 拷贝→filter init | libavcodec/bsf.c:147-186（extradata 变换时机=179-183） |
| 空包即 EOF；EAGAIN 背压；move_ref 零拷贝 | libavcodec/bsf.c:205-223 |
| receive 就是直接调 filter 回调 | libavcodec/bsf.c:228-231 |
| ff_bsf_get_packet_ref（move）/get_packet（指针交换） | libavcodec/bsf.c:233-267 |
| bsf_list 级联 init（上家 par_out→下家 par_in） | libavcodec/bsf.c:281-308 |
| "-bsf a,b" 字符串解析 | libavcodec/bsf.c:524-549 |
| null BSF = get_packet_ref 直通 | libavcodec/bsf/null.c:26-29 |
| avcC 解析：length_size & SPS/PPS 缓存 | libavcodec/bsf/h264_mp4toannexb.c:84-190（107/135/142-169） |
| 两遍扫描 j=0 计数 j=1 写；IDR 前置参数集 | libavcodec/bsf/h264_mp4toannexb.c:325-429（390-403） |
| ADTS 剥头 7(+2 CRC) 字节；ASC 位流拼装 | libavcodec/bsf/aac_adtstoasc.c:70-73 / 106-112 |
| filter_units：REMOVE/PASS + 整包删空返回 EAGAIN | libavcodec/bsf/filter_units.c:129-144 |
| extract_extradata：钓参数集进 NEW_EXTRADATA | libavcodec/bsf/extract_extradata.c:635-643 |
| setts 延迟一包支持 NEXT_PTS | libavcodec/bsf/setts.c:179-186 |
| vp9 alt-ref 攒 8 帧合 superframe（marker 0xC0） | libavcodec/bsf/vp9_superframe.c:52-99,151-161 |
| -bsf 选项注册 / 解析 / mux 线程 send-receive | fftools/ffmpeg_opt.c:2054 / ffmpeg_mux_init.c:1432 / ffmpeg_mux.c:315-354 |
| bsf_init 回写 par_out/time_base_out 给流 | fftools/ffmpeg_mux.c:572-604 |
| mux 自动挂接 check_bitstream + AUTO_BSF 开关 | libavformat/mux.c:1056-1073,1169 |
| ff_stream_add_bitstream_filter | libavformat/mux.c:1294-1335 |
| 裸流 muxer 自动 mp4toannexb 条件 | libavformat/rawenc.c:389-391 |
| movenc 自动 adtstoasc/vp9_superframe 条件 | libavformat/movenc.c:9239-9248 |
| demux 自动 extract_extradata 补 extradata | libavformat/demux.c:1449-1457,2477-2564 |

（全文完，约 300 行）
