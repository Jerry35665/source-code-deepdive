# U 章 AV1 生态:三路解码、三路编码与 CBS 支撑层

> 源码基线:master @ 9f63b36a。行号均为 `libavcodec/` 仓库相对路径 + 行号,已逐一核对。
> 本章承接 08 章(解码框架)与 14 章(x264/x265 wrapper),wrapper 通用概念不再复述,只讲 AV1 特有部分。

---

## 1. 全景:AV1 在 FFmpeg 的地图

AV1 是 FFmpeg 中"同名 codec 多实现"最密集的 codec:解码有 3 条主力路径(另有 cuvid/qsv/mediacodec 等 hwaccel-only 变体),编码有 3 个外部 wrapper(另有 nvenc/qsv/vaapi/amf/vulkan/d3d12va 硬件编码器)。与 H.264/HEVC 不同,AV1 的 native 解码器 `av1dec` 自身**不做像素解码**,只是 CBS 语法机 + hwaccel 前端。

```
                        AV_CODEC_ID_AV1
                              |
   +----------- 解码(3 路)-----------+     +-------- 编码(3 路)--------+
   |                                  |     |                           |
 libdav1d.c                    libaomdec.c                          libaomenc.c
 (dav1d,首选)                  (libaom,参考实现)                    (libaom)
   |  send_data/get_picture         |  aom_codec_decode                |  aom_codec_encode
   |  零拷贝 in+out                  |  整帧 memcpy 拷贝                 |  200+ ctl 选项映射
   v                                v                                  v
 libsvtav1.c  (SVT-AV1,管线式 send/receive,内部分层线程池)
 librav1e.c   (Rust rav1e,状态机 + ENOUGH_DATA 背压)
   |
 av1dec.c + av1dec.h   (native "av1",hwaccel-only)
   |  CBS 语法解析(av1dec.c:883 ff_cbs_init)
   |  start_frame/decode_slice/end_frame 抛给 hwaccel(av1dec.c:1342/1370/1428)
   +---> vaapi_av1.c / nvdec_av1.c / dxva2_av1.c / d3d12va_av1.c /
         vdpau_av1.c / videotoolbox_av1.c / vulkan_av1.c

   公共支撑层(解码侧共用):
   av1_parse.c/h  — 轻量 OBU 切分(parse_obu_header/ff_av1_packet_split),给 av1_parser 与
                    bsf/extract_extradata.c 用;libdav1d 只借用 ff_av1_framerate
   cbs_av1.c + cbs_av1_syntax_template.c — 完整 OBU 语法读/写,av1dec 的主干
```

三路解码一句话定位:**libdav1d = 生产默认;libaom-av1 = 参考实现,慢但权威;av1 = 硬解入口**。三个编码 wrapper 则是三种上游线程模型移植到 FFmpeg encode API 的三个样本(见第 4 节)。

---

## 2. 解码三路对比:libdav1d vs libaomdec vs av1dec

### 2.1 对比总表

| 维度 | libdav1d | libaomdec | av1dec (native) |
|---|---|---|---|
| 私有上下文 | `Libdav1dContext`:Dav1dContext+AVBufferPool+Dav1dData(libdav1d.c:45-57) | `AV1DecodeContext`:仅一个 `aom_codec_ctx`(libaomdec.c:42-44) | `AV1DecContext`:CBS ctx+OBU 片段+8 个 ref 槽(av1dec.h:85-122) |
| 输出 API | `FF_CODEC_RECEIVE_FRAME_CB`(libdav1d.c:614) | 旧式 `FF_CODEC_DECODE_CB`(libaomdec.c:297) | `FF_CODEC_RECEIVE_FRAME_CB`(av1dec.c:1554) |
| 线程模型 | 库内多线程:`s.n_threads=FFMIN(thread_count,MAX)`(libdav1d.c:229);caps `OTHER_THREADS|DELAY`(libdav1d.c:615)+ `AUTO_THREADS|SETS_FRAME_PROPS`(libdav1d.c:616-617) | 库内线程,上限 16:`deccfg.threads=FFMIN(thread_count?:cpu_count,16)`(libaomdec.c:50-51) | **单线程**,caps 只有 `DR1`(av1dec.c:1555);像素工作在 hwaccel 进程/驱动里 |
| 输入拷贝 | **零拷贝**:`dav1d_data_wrap` 直接挂 AVPacket 的 buf(libdav1d.c:309,见 2.2) | 直接把 `avpkt->data` 指针交给 `aom_codec_decode`(libaomdec.c:197),但库语义要求 padding 后数据驻留,输出侧必拷 | CBS 解析也零拷贝(`ff_cbs_read_packet` 引用 pkt buf,av1dec.c:1487) |
| 输出拷贝 | **零拷贝**:自定义 picture allocator 把 dav1d 输出帧放 AVBufferPool,`frame->buf[0]` 直接引 allocator_data(libdav1d.c:392) | **必须整帧拷**:`ff_get_buffer` 后 `av_image_copy`(libaomdec.c:229, 264);16bit 容器存 8bit 时还有专门转换(libaomdec.c:258-259) | 不产软帧;`av_frame_ref` 引用 `ff_progress_frame_get_buffer` 的 hw 帧(av1dec.c:945, 1132) |
| 像素格式决策 | 一次性查表 `pix_fmt[layout][hbd]`(libdav1d.c:59-64,156) | 逐帧按 `aom_image` 的 fmt/bit_depth/monochrome 重查(libaomdec.c:68-144) | 序列头算软格式(av1dec.c:473-534),再与 9 种 hwaccel 格式合成候选表(av1dec.c:542-586) |
| metadata/HDR | mastering/cll/T.35/film grain 全导出(libdav1d.c:457-552) | 仅 OBU_METADATA_ITUT_T35(libaomdec.c:166-187) | mdcv/cll/T.35 队列 + film grain(av1dec.c:999-1118) |
| 无 hwaccel 时 | 软解可用 | 软解可用 | 直接 `AVERROR(ENOSYS)`,日志"doesn't support hardware accelerated AV1 decoding"(av1dec.c:693-698) |

### 2.2 libdav1d:双向零拷贝是它成为默认的技术根因

输入零拷贝:packet 的 AVBufferRef 被直接"包"进 Dav1dData,引用计数由回调接管,FFmpeg 侧只把所有权交出去:

```c
// libdav1d.c:308-325
if (pkt->size) {
    res = dav1d_data_wrap(data, pkt->data, pkt->size,
                          libdav1d_data_free, pkt->buf);
    ...
    pkt->buf = NULL;                       // 所有权移交 dav1d

    res = dav1d_data_wrap_user_data(data, (const uint8_t *)pkt,
                                    libdav1d_user_data_free, pkt);  // pkt 本体作 user_data
    ...
    pkt = NULL;
}
```

`pkt` 整个挂在 `Dav1dData.m.user_data` 上,解码出帧后原样取回,用于回填 pts/dts/size(libdav1d.c:428-435)——这比"记一个 FIFO"更抗重排。

输出零拷贝:dav1d 允许注册 picture allocator(libdav1d.c:215-217),wrapper 用 AVBufferPool 发帧,再手工把指针对齐到 `DAV1D_PICTURE_ALIGNMENT`(av_malloc 不保证,见注释 libdav1d.c:103-107):

```c
// libdav1d.c:77-99(节选)
static int libdav1d_picture_allocator(Dav1dPicture *p, void *cookie)
{
    ...
    ret = av_image_get_buffer_size(format, w, h, DAV1D_PICTURE_ALIGNMENT);
    if (ret != dav1d->pool_size) {          // 分辨率变化才重建池
        av_buffer_pool_uninit(&dav1d->pool);
        dav1d->pool = av_buffer_pool_init(ret + DAV1D_PICTURE_ALIGNMENT * 2, NULL);
        ...
    }
    buf = av_buffer_pool_get(dav1d->pool);
```

出帧路径 `libdav1d_receive_frame`(libdav1d.c:374-564)是个 do-while 循环喂包取图(libdav1d.c:382-384),然后:引 allocator_data 进 `frame->buf[0]`(:392)、平面指针/stride 平移(:398-403)、`DAV1D_EVENT_FLAG_NEW_SEQUENCE` 时重算参数(:405-407)、按 frame_hdr 设置 SAR(:421-426)/key 标志(:436-439)/pict_type(:441-455),最后把 mastering display(:457-478)、content light(:479-490)、ITU-T T.35(:491-504)、film grain 参数(:505-552)全部转成 AVFrame side data。

线程:FFmpeg 不参与 frame/tile 线程分配,只传一个 `s.n_threads`(libdav1d.c:229)。早期 dav1d API 需要分别设 `n_frame_threads/n_tile_threads`,当前 master 已收敛为单参数、由 dav1d 内部划分;`max_frame_delay` 选项(libdav1d.c:591)配合 `AV_CODEC_FLAG_LOW_DELAY` 强制为 1(libdav1d.c:230-232)。`dav1d_get_frame_delay`(libdav1d.c:254,需 dav1d>=6.7)把库内 lookahead 报给 `c->delay`。`skip_frame` 也被映射进 dav1d 的 decode_frame_type(libdav1d.c:236-243),连跳帧都下沉到库里。

所谓"8/10bit 双 API"是 dav1d 0.x 时代的旧事;现行树里只有 `dav1d_get_picture` 一个出口,位深差异由序列头的 `hbd` 字段查表决定(libdav1d.c:59-64)。真正存在"两条拷贝路径"的是 libaomdec(见下)。

### 2.3 libaomdec:最"老实"的 wrapper,代价是每帧两次内存搬运

```c
// libaomdec.c:229-266(节选)
if ((ret = ff_get_buffer(avctx, picture, 0)) < 0)      // FFmpeg 分配目标帧
    return ret;
...
if ((img->fmt & AOM_IMG_FMT_HIGHBITDEPTH) && img->bit_depth == 8)
    ff_aom_image_copy_16_to_8(picture, img);            // 16bit 容器 + 8bit 内容
else {
    ...
    av_image_copy(picture->data, picture->linesize, planes,
                  stride, avctx->pix_fmt, img->d_w, img->d_h);  // 整帧拷贝
}
```

libaom 的解码 API 是"推一包、迭代取图":`aom_codec_decode`(libaomdec.c:197)→`aom_codec_get_frame(iter)`(libaomdec.c:209)。它没有 allocator 回调、没有 user_data 通道,时间戳只能靠 FFmpeg decode.c 的默认排队机制回填;key/pict_type 也要靠额外的 `AOMD_GET_FRAME_FLAGS` 控制查询,且整个块包在 `#ifdef AOM_CTRL_AOMD_GET_FRAME_FLAGS` 里做 ABI 兼容(libaomdec.c:232-249)。像素格式判断是一份 70 行的 switch(libaomdec.c:81-143),profile 顺带推出(MAIN/HIGH/PROFESSIONAL)。

### 2.4 av1dec:不是软解,是"CBS + hwaccel 转接器"

`AV1DecContext`(av1dec.h:85-122)的核心是 `CodedBitstreamContext *cbc` 与 `CodedBitstreamFragment current_obu`,外加 8 个 `AV1Frame ref[]` 参考槽和 `tile_group_info[]`。它回答了"native AV1 解码器是不是必须有 hwaccel":是。`get_pixel_format` 末尾的检查写得很直白:

```c
// av1dec.c:688-698
/**
 * check if the HW accel is inited correctly. If not, return un-implemented.
 * Since now the av1 decoder doesn't support native decode, if it will be
 * implemented in the future, need remove this check.
 */
if (!avctx->hwaccel) {
    av_log(avctx, AV_LOG_ERROR, "Your platform doesn't support"
           " hardware accelerated AV1 decoding.\n");
    avctx->pix_fmt = AV_PIX_FMT_NONE;
    return AVERROR(ENOSYS);
}
```

主循环是按 OBU 的状态机(av1dec.c:1232-1474):

- `SEQUENCE_HEADER`(:1257-1290):保存原始字节 `seq_data_ref`(供 hwaccel `decode_params` 用,:1281-1288),更新 avctx 宽高/颜色/帧率(:789-830);
- `FRAME`/`FRAME_HEADER`(:1295-1351):`show_existing_frame` 直接从 ref 槽取帧输出(:1312-1331);否则 `get_current_frame`(:1169-1230)——分配帧(`ff_progress_frame_get_buffer`,av1dec.c:945)、算 global motion/skip mode/lossless/order hint/胶片颗粒参数(:1218-1222,这些是 hwaccel 需要但 CBS 不给的"半语法"推导,实现于 av1dec.c:46-408)、调 hwaccel `start_frame`(:1342-1349);
- `TILE_GROUP`:`get_tiles_info` 逐 tile 解析大小/偏移/行列号(av1dec.c:428-471),整组 tile 数据交给 hwaccel `decode_slice`(:1369-1377);
- 当 `tg_end` 收齐(`s->tile_num == tg_end+1`,:1421):`end_frame`(:1428)、`update_reference_list` 按 `refresh_frame_flags` 滚动 ref 槽(:1158-1167)、`show_frame` 则 `set_output_frame` 导出 metadata/film grain 后输出(:1442-1454)。

Tiling 的处理印证了它的角色:FFmpeg 自己不碰 tile 熵编码,只把 tile 边界切成 `TileGroupInfo`(av1dec.h:78-83)传给硬件;`TILE_LIST`(大规模 tile)直接报"unsupported"(av1dec.c:1245-1249)。caps 上它声明 `FF_CODEC_CAP_USES_PROGRESSFRAMES`(av1dec.c:1558)——虽然本尊不解码像素,progress frame 机制仍用于管理 ref 生命周期。

---

## 3. CBS / av1_parse 支撑层

### 3.1 两套解析器,两种取舍

`av1_parse.c/h` 是轻量版:只切 OBU 边界、不展开语法。`parse_obu_header`(av1_parse.h:92-134)读 1 字节头(forbidden/type4/ext1/has_size1/res1)+ 可选扩展字节 + leb128 尺寸;`ff_av1_packet_split`(av1_parse.c:56-102)把整包切成 `AV1OBU` 数组,`get_obu_bit_length`(av1_parse.h:136-167)处理 trailing_one_bit。用户只有 av1_parser.c 和 bsf/extract_extradata.c(grep 证实);libdav1d 只借用 `ff_av1_framerate`(libdav1d.c:158,实现在 av1_parse.c:110-122)。

`cbs_av1.c` 是重量版:读/写双向(uvlc/leb128/ns/increment/subexp 五种自定义编码,cbs_av1.c:32/125/196/274/337),语法模板在 cbs_av1_syntax_template.c(`FUNC()` 宏展开 read/write 两份)。av1dec 只订阅 7 种 OBU(av1dec.c:862-870):

```c
// av1dec.c:862-870
static const CodedBitstreamUnitType decompose_unit_types[] = {
    AV1_OBU_FRAME,
    AV1_OBU_FRAME_HEADER,
    AV1_OBU_METADATA,
    AV1_OBU_REDUNDANT_FRAME_HEADER,
    AV1_OBU_SEQUENCE_HEADER,
    AV1_OBU_TEMPORAL_DELIMITER,
    AV1_OBU_TILE_GROUP,
};
```

`cbs_av1_read_unit`(cbs_av1.c:839)按 operating_point_idc 丢弃不在选定 operating point 内的 OBU(`AVERROR(EAGAIN)` 即 spec 的 drop_obu,cbs_av1.c:879-891);序列头读取时校验用户指定的 operating_point 并落 `operating_point_idc`(cbs_av1.c:901-911)——av1dec 的 `operating_point` 选项就是通过 `av_opt_set_int(s->cbc->priv_data, ...)` 注进去的(av1dec.c:895)。tile group 的数据区不展开语法,仅"引用"原始字节(`cbs_av1_ref_tile_data`,cbs_av1.c:811-837)。

extradata 的双格式在这里统一处理:`data[0]&0x80` 说明是 MP4/Matroska 的 AV1CodecConfigurationRecord v1,跳过 4 字节头再按裸 OBU 流解析(cbs_av1.c:722-753)。libdav1d 不走 CBS,自己复刻了同一逻辑(libdav1d.c:172-187),随后用 dav1d 自带的 `dav1d_parse_sequence_header` 提参数(libdav1d.c:189-194)。

### 3.2 与 14 章"手工拼 avcC"的对照

x264/x265 wrapper 需要手工把 SPS/PPS/VPS 拼成 avcC/hvcC;AV1 的 extradata 是**裸 OBU 序列头**(temporal unit),三个编码 wrapper 各取所需:

- libaomenc:不直接产头,挂 `extract_extradata` bitstream filter 从首包抽(libaomenc.c:1079-1099,输出侧再过滤一次 :1177-1191);
- libsvtav1:`svt_av1_enc_stream_header` 让库生成,memcpy 进 extradata(libsvtav1.c:523-545);
- librav1e:`rav1e_container_sequence_header` 直接拿(librav1e.c:405-420)。

三方殊途同归于"裸 OBU",所以 AV1 没有 avcC 那种"wrapper 手工组包"环节;解码侧则必须同时容忍裸 OBU 与 config record 两种形态(上节)。

---

## 4. 编码三路:参数映射与线程模型

### 4.1 对比总表

| 维度 | libaomenc | libsvtav1 | librav1e |
|---|---|---|---|
| 速度/质量旋钮 | `cpu-used` 0-8,运行时可调(libaomenc.c:1586,VER 标志) | `preset` -2..MAX_ENC_PRESET(libsvtav1.c:793-794) | `speed` 0-10(librav1e.c:613) |
| RC 模式 | `rc_end_usage` 四态推导:CBR/CQ/Q/VBR(libaomenc.c:834-852);无 b 无 crf 时警告并用 CRF=32(:846-852) | `rate_control_mode`:0(CRF/qp)、1(VBR max≠avg)、2(CBR max==avg)(libsvtav1.c:240-249);crf/qp 都走 mode 0(:256-267) | `quantizer` 与 `bitrate` 互斥,bitrate 时把 qmax 当 quantizer 上限传(librav1e.c:339-368) |
| lookahead | `lag-in-frames`(libaomenc.c:1589→:831-832),pass1 强制 0(:1032-1033) | 库内管线深度,不经 FFmpeg | 库内,不经 FFmpeg |
| 通用工具链 | 两遍 base64 stats(:1034-1060/1258-1276)、`qcompress→rc_2pass_vbr_bias_pct`(:874)、still-picture(AVIF,g_limit=1+lag=0,:917-927) | 两遍 rc_stats_buffer(libsvtav1.c:366-401)、2.0 起取首遍 stats 用 stream info 接口(:677-719) | 两遍 stats get/set(librav1e.c:119-172) |
| 线程模型 | `g_threads=FFMIN(thread_count?:cpu_count,64)`(libaomenc.c:828-829)+ 可选 `row-mt`(选项 :1613,ctl :983-984) | **全库内**:wrapper 不传线程数,SVT 自己按管线阶段开线程池;caps `OTHER_THREADS|AUTO_THREADS`(libsvtav1.c:863-865) | `threads` 走配置字符串(librav1e.c:282-284),库内线程池 |
| 输出内存 | 从 aom pkt memcpy 到 FFmpeg pkt(storeframe,libaomenc.c:1147-1153) | `av_buffer_pool` 承接 + 一次 memcpy(libsvtav1.c:721-731) | `rav1e_data` 引用拷出(librav1e.c:442 起的 receive_packet) |
| 像素格式 | I420/I422/I444 8/10/12 + GBR(libaomenc.c:517-580) | 只有 420P/420P10(libsvtav1.c:866) | 420/422/444 全家含 12bit(librav1e.c:630-644) |

### 4.2 libaomenc:200+ 开关的"翻译官"

AOMContext 有 70 多个 int 字段(libaomenc.c:72-145)。映射分两层:cfg 层(`aom_config`,libaomenc.c:800-930:宽高/timebase/g_threads/lag/RC/kf/tiles)和 ctl 层(`aom_codecctl`,libaomenc.c:932-1010:`AOME_SET_CPUUSED`、30 余个 tool 开关、颜色、`AV1E_SET_TILE_COLUMNS` 等)。tool 开关用一张 `{ctl, offsetof}` 表驱动(libaomenc.c:761-798),凡默认值 -1(未设)就跳过(:942-946)。Tiling 值得一提:`choose_tiling`(libaomenc.c:606-759)按 AV1 最大 tile 尺寸/面积约束自动算行列数,再在 64/128 superblock 间挑 uniform 布局。新参数走 `aom-params` 字典透传 `aom_codec_set_option`(libaomenc.c:988-999,选项 :1657-1659),与 14 章 x265 的 params 透传同构。输出侧一次 `aom_codec_encode` 可能产多帧,queue_frames 用链表缓存(libaomenc.c:1203-1294)。它还是唯一支持 `AV_CODEC_CAP_ENCODER_RECONF`(运行时改分辨率,libaomenc.c:1690,1698)的 AV1 wrapper。

### 4.3 libsvtav1:管线式 send/receive

SVT 的分层线程模型(pool of threads,按 stage 划分)完全藏在库里,wrapper 呈现为一个标准的 `RECEIVE_PACKET` 编码器(libsvtav1.c:861):每次调用先 `ff_encode_get_frame` 取一帧 `svt_av1_enc_send_picture`(libsvtav1.c:660-666,617),再 `svt_av1_enc_get_packet` 收一个包(:671);`EB_NoErrorEmptyQueue` 映射为 EAGAIN(:672-673)。输入是"软引用":`read_in_data` 把 AVFrame 平面指针/stride 直接填进 `EbSvtIOFormat`(libsvtav1.c:471-477),不拷像素;输出反而要 memcpy 进 buffer pool(:727-731)。RC 映射见总表,注意 `qp`(而非 crf)时会显式关掉自适应量化 `aq_mode/enable_adaptive_quantization`(libsvtav1.c:259-267)。版本兼容用 `SVT_AV1_CHECK_VERSION` 宏密布(如 <3.0.0 拒绝小于 64x64 输入,libsvtav1.c:219-234)。`svtav1-params` 字典透传给 `svt_av1_enc_parse_parameter`(libsvtav1.c:347-356)。

### 4.4 librav1e:Rust 状态机的背压样本

rav1e 的 `rav1e_send_frame` 会返回 `RA_ENCODER_STATUS_ENOUGH_DATA`(队列满),wrapper 必须把没送进去的 RaFrame 存起来下次重试——这是三个 wrapper 里唯一的显式背压:

```c
// librav1e.c:494-501
ret = rav1e_send_frame(ctx->ctx, rframe);
if (rframe)
    if (ret == RA_ENCODER_STATUS_ENOUGH_DATA) {
        ctx->rframe = rframe;   /* Queue is full. Store the RaFrame to retry next call */
    } else {
        rav1e_frame_unref(rframe);
        ctx->rframe = NULL;
    }
```

收包侧 `RA_ENCODER_STATUS_ENCODED` 触发 `goto retry` 循环(librav1e.c:538-539),`LIMIT_REACHED` 映射 EOF。参数全部经字符串配置(`rav1e_config_parse`,librav1e.c:254-260),连宽高都是(:262-274);time_base 传的是帧率的倒数(:210-223,注释解释了 rav1e 只拿它算 RC 用帧率)。输入要按平面 fill(拷贝,librav1e.c:482-488)。它保留着 422/444/12bit 全格式和 `REORDERED_OPAQUE` 支持(librav1e.c:666-668),是三路中能力最宽但性能最弱的(社区共识, 本章只陈述代码事实:全格式列表 librav1e.c:630-644)。

---

## 5. 注册与优先级:同名 codec 怎么选

`codec_list.c` 是 configure 生成的:configure:4609-4610 用 `find_things_extern` 按 **allcodecs.c 中的 extern 声明顺序** 抽出 ENCODER_LIST/DECODER_LIST,configure:4611-4614 拼成 CODEC_LIST(先编码器后解码器),configure:8970 `print_enabled_components` 只写出 enabled 项。查找时 `find_codec` 顺序遍历 `av_codec_iterate`(allcodecs.c:943-953),返回第一个匹配项,`AV_CODEC_CAP_EXPERIMENTAL` 的实现在全部非实验实现之后兜底(allcodecs.c:964-983)。

于是 AV1 解码器的实际优先级 = allcodecs.c 声明顺序(外部库区在 native 区之前,注释"hwaccel hooks only, so prefer external decoders",allcodecs.c:850):

1. `ff_libdav1d_decoder`(allcodecs.c:778)
2. `ff_libaom_av1_decoder`(allcodecs.c:849)
3. `ff_av1_decoder`(allcodecs.c:851,hwaccel-only)
4. `ff_av1_cuvid_decoder`(:852)、`ff_av1_mediacodec_decoder`(:854)、`ff_av1_qsv_decoder`(:857)、`ff_av1_amf_decoder`(:860)

即 `avcodec_find_decoder(AV_CODEC_ID_AV1)` 在装了 dav1d 的构建里永远命中 libdav1d;要硬解必须显式 `-c:v av1`(或 hwwaccel 格式协商)。编码侧 `ff_libaom_av1_encoder`(allcodecs.c:772)先于 `ff_librav1e_encoder`(:803)与 `ff_libsvtav1_encoder`(:808)声明,故默认 `-c:v av1` 编码命中 libaom-av1;svt/rav1e 都要按名字显式指定。

---

## 6. 设计动机

**为什么 AV1 有 CBS 通用语法层作为解码主干,而 H.264 没有(在这个位置)?** 严格说 H.264 也有 cbs_h264(14 章的 bsf/解析工具),差别在**角色**:H.264/HEVC 的 native 软解成熟自足,语法解析内嵌于解码器,CBS 只是旁路工具(bsf、export_mvs 等);AV1 的 `av1dec` 从未实现像素解码(注释自认,av1dec.c:690-691),它存在的唯一意义就是"把语法读成结构体、把 tile 数据递给硬件",于是 cbs_av1 从工具升格为主干。AV1 语法又是全新且规整的(无 H.264 那种历史包袱的 cabac/mb 层纠缠),让 cbs_av1_syntax_template 一次写就 read/write 双实现成为可能。

**为什么 dav1d 成为事实默认?** 代码给出三个可验证的理由:(1) 接口贴合——`receive_frame` + 库内线程(`AUTO_THREADS`)+ `dav1d_get_frame_delay` 报延迟,FFmpeg 不需要任何胶水线程;(2) 双向零拷贝——data wrap 输入 + allocator 输出(libdav1d.c:309/216),这是 aom API 没有的能力;(3) 同源——dav1d 作者即 FFmpeg/VLC 的解码核心作者,metadata 事件(`DAV1D_EVENT_FLAG_NEW_SEQUENCE`)、skip_frame 下沉等都是按 FFmpeg 需求演进的接口。

**wrapper 差异反映上游 API 设计差异。** aom 是"一个 ctx + 一万个 ctl 枚举"的 C 风格配置面,所以 libaomenc 一半篇幅在做枚举翻译与 cfg 推导;SVT 是数据流管线(EbBufferHeaderType 进出),wrapper 自然长成 send/receive 对;rav1e 是 Rust 所有权风格(state machine + 显式背压 + 字符串配置),wrapper 就要处理 ENOUGH_DATA 重试与配置字符串化。三个 wrapper 是同一 FFmpeg encode API 对三种上游抽象的三个适配样本,比 14 章 x264/x265(两者 API 形态接近)更具对比价值。

---

## 7. FAQ 素材

1. **ffmpeg 怎么知道该用哪个 AV1 解码器?** 按 codec_list 顺序找第一个匹配(allcodecs.c:964-983),dav1d 声明在最前(allcodecs.c:778),所以有 dav1d 就用它;`-c:v libaom-av1`/`-c:v av1` 可强制。
2. **native `av1` 解码器为什么报"does not support hardware accelerated decoding"?** 它根本没有软解路径,get_pixel_format 里无 hwaccel 直接 ENOSYS(av1dec.c:693-698)。
3. **libdav1d 解码会不会拷贝数据?** 输入 `dav1d_data_wrap` 挂 packet buffer(libdav1d.c:309),输出走 AVBufferPool allocator(libdav1d.c:77-123,392),双向零拷贝;libaomdec 则输入直传、输出必拷(libaomdec.c:264)。
4. **`-threads` 对 libdav1d 生效吗?** 生效但只作为一个总数 `s.n_threads`(libdav1d.c:229),frame/tile 线程由 dav1d 内部划分;caps 是 OTHER_THREADS 而非 FRAME_THREADS(libdav1d.c:615)。
5. **libaom 编码默认 CRF 是多少?** 没给 -b 也没给 -crf 时警告并取 32(libaomenc.c:846-852);CBR 判定条件是 min==max==b(:834-836)。
6. **SVT-AV1 的 preset 怎么映射?** 选项 `preset` 直接写 `enc_mode`(libsvtav1.c:237-238);crf/qp 都映射 `rate_control_mode=0`(:256-262),CBR/VBR 是 mode 2/1(:240-249)。
7. **AV1 的 extradata 是 avcC 那样的盒子吗?** 不是,是裸 OBU;若 `data[0]&0x80` 则是 4 字节头 + OBU 的 config record,两套解析都兼容(cbs_av1.c:722-753,libdav1d.c:172-187)。
8. **dav1d 的 `oppoint`/`alllayers` 干什么用?** 选可分级码流的 operating point / 输出全部空间层(libdav1d.c:593-594);CBS 侧同名选项作用于 OBU 丢弃逻辑(cbs_av1.c:901-911, av1dec.c:895)。
9. **film grain 是解码时加还是导出?** 默认 dav1d 在库内应用(libdav1d.c:219-222);`-flags +export_film_grain` 时改为导出参数 side data(libdav1d.c:505-552),av1dec 只导出不应用(av1dec.c:1142-1148)。
10. **SVT-AV1 编码小分辨率报错?** <3.0.0 的库要求至少 64x64,wrapper 提前拦截(libsvtav1.c:219-234)。

## 深挖方向

1. **tile 级硬解数据流**:get_tiles_info 的 tile 边界表(av1dec.c:428-471)如何被 vaapi/nvdec 的 decode_slice 消费,对比 08 章 h264 slice 的对应物。
2. **零拷贝链路验证**:dav1d allocator 的 AVBufferPool 与 FFmpeg frame pool 生命周期(libdav1d.c:89-107),为何池尺寸按 128 对齐后的 w/h 计算。
3. **operating point 全链路**:CBS 丢 OBU(cbs_av1.c:879-891)→ av1dec 按 spatial_id 跳层(av1dec.c:1128-1130)→ dav1d 库内 all_layers(oppoint),三处语义差异。
4. **三个编码 wrapper 的两遍编码实现对比**:aom 的 stats 包/base64(libaomenc.c:1258-1276) vs svt 的 rc_stats_buffer(libsvtav1.c:366-401) vs rav1e 的 get_stats(librav1e.c:119-172)。
5. **`extract_extradata` bsf 对 AV1 的路径**:它用 av1_parse 而非 CBS 切 OBU(bsf/extract_extradata.c),与 libaomenc 挂 bsf 抽头(libaomenc.c:1079-1099)构成闭环。

---

## 写作要点速查表

| 关键事实 | 位置 |
|---|---|
| Libdav1dContext(pool+data+max_frame_delay) | libdav1d.c:45-57 |
| 像素格式表 layout×hbd | libdav1d.c:59-64 |
| picture allocator(AVBufferPool+对齐) | libdav1d.c:77-123 |
| n_threads 单参数/LOW_DELAY 强制 delay=1 | libdav1d.c:229-232 |
| 零拷贝输入 dav1d_data_wrap(+user_data 挂 pkt) | libdav1d.c:309-325 |
| 出帧主循环/时间戳回填/ SideData 导出 | libdav1d.c:374-564 |
| libdav1d caps(OTHER_THREADS+AUTO_THREADS) | libdav1d.c:615-617 |
| aom 解码:线程上限 16 / 整帧拷贝 | libaomdec.c:50-51, 264 |
| libaom-av1 解码器 caps(旧式 DECODE_CB) | libaomdec.c:297-300 |
| av1dec 无软解检查(ENOSYS) | av1dec.c:688-698 |
| av1dec OBU 状态机/硬解三回调 | av1dec.c:1232-1474(1342/1370/1428) |
| AV1DecContext/ref 槽/tile 表 | av1dec.h:85-122, av1dec.c:428-471 |
| parse_obu_header / ff_av1_packet_split | av1_parse.h:92-134, av1_parse.c:56-102 |
| CBS extradata config-record 识别 | cbs_av1.c:722-753 |
| cbs_av1_read_unit(operating point 丢 OBU) | cbs_av1.c:839-915(879-891) |
| aom RC 四态推导 / 默认 CRF 32 | libaomenc.c:834-852 |
| cpu-used / lag-in-frames / usage 选项 | libaomenc.c:1586, 1589, 1618-1621 |
| choose_tiling 自动 tile 布局 | libaomenc.c:606-759 |
| SVT rc mode 映射 / svtav1-params 透传 | libsvtav1.c:240-267, 347-356 |
| rav1e ENOUGH_DATA 背压 / speed/tiles 选项 | librav1e.c:494-501, 613-616 |
| AV1 解码器声明顺序(dav1d→aom→native) | allcodecs.c:778, 849-860 |
| find_codec 顺序遍历+experimental 兜底 | allcodecs.c:964-983 |
| codec_list.c 生成顺序来源 | configure:4609-4614, 8970 |
