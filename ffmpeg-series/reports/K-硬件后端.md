# K. 硬件后端：VAAPI / NVDEC / VideoToolbox 如何实现 hwcontext 通用接口

> 调研基线：FFmpeg master，commit 9f63b36a。本卷不重复首卷的 hw_device_ctx / hw_frames_ctx 通用概念，只回答一个问题：**三个具体后端各自用什么"原生对象"填进通用框架的插槽，以及在协商、池化、取帧、报错上各自怎么落地。**
> 注：本版本源码中 NVDEC 的 frames 逻辑全部在 `libavcodec/nvdec.c`（libavutil 下无 hwcontext_nvdec.c，NVDEC 复用 `hwcontext_cuda.c`）；VideoToolbox 解码器实现在 `libavcodec/videotoolbox.c`（无 videotoolboxdec.c）。

## 1. 全景：同一套接口，三种"原生对象"

`libavutil/hwcontext.c:337 av_hwframe_ctx_init()` 只认 `HWContextType` 函数表（VAAPI 的表在 `hwcontext_vaapi.c:2080`，VideoToolbox 的在 `hwcontext_videotoolbox.c:840`），每个后端负责把自家对象塞进统一容器：

| 插槽 | VAAPI | NVDEC | VideoToolbox |
|---|---|---|---|
| 设备级原生对象 | `VADisplay`（`hwcontext_vaapi.c:1714 vaapi_device_create`，`vaInitialize` 在 1703） | `CUcontext` + 解码器私有 `CUvideodecoder`（`nvdec.c:49-67 NVDECDecoder`） | 设备无状态，会话即 `VTDecompressionSession`（`videotoolbox.c:1007`） |
| 帧级原生对象 | `VASurfaceID` | pitch-linear: `CUdeviceptr`（cuvidMapVideoFrame 映射出）；opaque: `CUarray` | `CVPixelBufferRef`（IOSurface 背书） |
| hw 像素格式 | `AV_PIX_FMT_VAAPI` | `AV_PIX_FMT_CUDA` / `AV_PIX_FMT_CUARRAY`（SDK 13.1+，`nvdec.h:50`） | `AV_PIX_FMT_VIDEOTOOLBOX` |
| 句柄藏在 AVFrame 哪里 | `data[3]` = surface id（`vaapi_get_buffer` `hwcontext_vaapi.c:743`） | 映射模式 `data[0]/data[1]` = 平面指针 + unmap 簿记（`nvdec.c:905-924`）；CUARRAY 模式 `data[0]` = CUarray（`nvdec.c:844`） | `data[3]` = pixbuf（`vt_get_buffer` `hwcontext_videotoolbox.c:319`） |
| pool 分配函数 | `vaapi_pool_alloc`：`vaCreateSurfaces` 逐个造（`hwcontext_vaapi.c:531-573`） | 无 hwcontext pool；用 refstruct pool 发"surface 索引"（`nvdec.c:694`，分配回调 279-290） | `vt_pool_alloc_buffer`：从 `CVPixelBufferPool` 取（`hwcontext_videotoolbox.c:249-274`） |
| 释放路径 | `vaapi_buffer_free` → `vaDestroySurfaces`（`hwcontext_vaapi.c:515-529`） | CUARRAY: 引用计数归零清 `surface_in_use` 槽（`nvdec.c:759-768`）；映射模式 buf[1] 释放时 `cuvidUnmapVideoFrame`（728-750） | `CVPixelBufferRelease`（`hwcontext_videotoolbox.c:244-247`） |

`data[3]` 是 VAAPI/VT 共享的约定：通用层不解释它，只有 map/download 路径（`hwcontext_vaapi.c:840`、`hwcontext_videotoolbox.c:686`）把它还原成原生句柄。

## 2. 解码协商链专节：ff_get_format 是软硬解的唯一汇合点

完整行号链（以 h264 为例）：

1. 解码器解析出 SPS/PPS 后组装候选格式表并调用协商：`libavcodec/h264_slice.c:935 return ff_get_format(h->avctx, pix_fmts);`（895-932 行按 bitdepth 手工拼 `AV_PIX_FMT_VAAPI` 等候选，硬件格式在前、软件格式垫底）。
2. `ff_get_format`（`libavcodec/decode.c:1229-1365`）：1242-1248 行利用"软件格式必须是最后一项"的约定顺手记录 `avctx->sw_pix_fmt`——这是所有 hwaccel 初始化的先决输入（如 `nvdec.c:427`）。
3. 进入 `for(;;)` 循环（1254 行起）：每次先 `ff_hwaccel_uninit`（1217-1227，销毁上一次失败的 hwaccel），再调用户回调 `avctx->get_format`（1258）。默认实现 `avcodec_default_get_format`（decode.c:1006-1067）：设了 `hw_device_ctx` 就优先挑匹配 device_type 的硬件格式（1014-1031），否则挑第一个软件格式（1037-1041）。
4. 用户选中的格式在 `codec->hw_configs` 表中查找（1286-1296；h264 的表在 `h264dec.c:1172`，条目由宏生成 `libavcodec/hwconfig.h:42-52`，`HWACCEL_VAAPI`/`HWACCEL_NVDEC`/`HWACCEL_VIDEOTOOLBOX` 在 72/68/76 行，均为 device+frames 双方法）。校验 frames_ctx/device_ctx 匹配（1305-1337），然后 `hwaccel_init`（decode.c:1182-1215）调用各后端的 init；失败 `goto try_again` 把该格式从候选中剔除重来（1348-1357）——**这就是"硬解失败自动回退软解"的机制本体**。
5. hwaccel init 内部拿 frames ctx：`ff_decode_get_hw_frames_ctx`（decode.c:1069，用户没给就用 device_ctx 现建）。

之后的逐帧流程：解码器通过宏调 hwaccel 回调——h264 在 NAL 分发处 `FF_HW_CALL(start_frame)`（`h264dec.c:714`）、`decode_slice`（722）、场结束时 `FF_HW_SIMPLE_CALL(end_frame)`（`h264_picture.c:207`）。取到输出帧前，通用层统一执行 `fdd->hwaccel_priv_post_process`（`decode.c:706-713`），NVDEC/VT 都靠这个钩子把异步产物挂上帧。

```
avcodec_send_packet
  └─ h264 解码(软解 parser/DPB 不变)
       └─ SPS 变化 → h264_get_pixel_format (h264_slice.c:895-935)
            └─ ff_get_format (decode.c:1229)
                 └─ avctx->get_format (decode.c:1258, 默认实现 :1006)
                 └─ hwaccel_init (decode.c:1182)
                      ├─ ff_vaapi_decode_init        (vaapi_decode.c:692)
                      ├─ ff_nvdec_decode_init        (nvdec.c:404)
                      └─ ff_videotoolbox_common_init (videotoolbox.c:1287)
  ── 每帧 ──
  start_frame → decode_slice* → end_frame (h264dec.c:714/722, h264_picture.c:207)
  └─ get_buffer → decode.c:706 post_process 钩子
       ├─ nvdec_retrieve_data   (nvdec.c:771)   cuvidMapVideoFrame / CUarray
       └─ videotoolbox_postproc (videotoolbox.c:121) data[3]=CVPixelBuffer
```

## 3. VAAPI 专节

**profile 匹配表**：`vaapi_profile_map[]`（`libavcodec/vaapi_decode.c:409-472`）是 `codec_id + AV_PROFILE + VAProfile(+可选解析函数)` 三元组，HEVC REXT/SCCC 挂了专门 parser（439-442 行）。匹配在 `vaapi_decode_make_config`（478 行）：先 `vaQueryConfigProfiles` 拉驱动全量支持列表（508），再双层循环（520-545）——外层遍历 FFmpeg 表、内层对驱动列表，`exact_match` 表示 avctx->profile 精确命中；不精确命中且未开 `AV_HWACCEL_FLAG_ALLOW_PROFILE_MISMATCH` 直接拒绝（554-570）。命中后 `vaCreateConfig(profile, VAEntrypointVLD)`（572-574）得到 VAConfigID。

**VAConfigID 生命周期**：真实解码时由 `ff_vaapi_decode_init` 创建（710 行调用 make_config）、`ff_vaapi_decode_uninit` 销毁 config+context（751/744）；而 `frame_params` 探测路径 `ff_vaapi_common_frame_params`（668-690）建完就毁（687）——用完即弃，只为把约束写回 frames_ref。

**surface pool**：`vaapi_frames_init`（`hwcontext_vaapi.c:575`）补齐 `VASurfaceAttribPixelFormat`/`MemoryType` 属性（599-641，受 quirk 影响跳过）后挂内部 pool（663-665）。每个 buffer 就是一个 `vaCreateSurfaces` 产物（`vaapi_pool_alloc` 545-548），surface id 以整数形式塞进 `AVBufferRef->data`（556），同时登记进 `avfc->surface_ids[]`（568）——这个数组随后整体传给 `vaCreateContext`（`vaapi_decode.c:715-720`），因为 VA-API 的解码上下文创建时就要求绑定全部 render target。pool 大小由 codec 决定：H264/HEVC/AV1 +16、VP9 +8、VP8 +3、其他 +2（`vaapi_decode.c:628-649`），libva 1.x 新接口路径（CONFIG_VAAPI_1）则交给动态池（629）。

**map/download**：`vaapi_frames_init` 结尾用试分配的 surface 探测 `vaDeriveImage` 是否可行（675-718，`derive_works` 694）。`vaapi_map_frame`（824）先 `vaSyncSurface`（866）等 GPU 写完；derive 可行走零拷贝 `vaDeriveImage+vaMapBuffer`（881-928，注释解释 Gen7-Gen9 非 cache 内存读取慢所以 READ 请求不走 derive，874-880），否则 `vaCreateImage+vaGetImage` 拷贝路径（900-919）。YV12 类色度反转用指针交换修复（952-956）。`av_hwframe_transfer_data` 下载即 `vaapi_transfer_data_from`（971）：map 后 `av_frame_copy`（992）。

**四角格式 quirk 机制**：驱动怪癖表 `vaapi_driver_quirks_table`（`hwcontext_vaapi.c:392-415`）按 vendor 字符串子串匹配（`vaapi_device_init` 470-498）：
- `i965` → `AV_VAAPI_DRIVER_QUIRK_RENDER_PARAM_BUFFERS`（397-404，仅在链接 libva<1.0 时编译进来，注释明说"The i965 driver did not conform before version 2.0"）；
- `ubit`（Intel iHD）→ `ATTRIB_MEMTYPE`（405-409）；
- Splitted-Desktop VDPAU wrapper → `SURFACE_ATTRIBUTES`（410-414）。

RENDER_PARAM_BUFFERS 在解码提交处生效：`ff_vaapi_decode_issue`（`vaapi_decode.c:166`）正常路径 `vaBeginPicture→vaRenderPicture(参数 190/slice 199)→vaEndPicture(208)` 后不销毁 buffer；带 quirk 时 render 即销毁（220-222）。SURFACE_ATTRIBUTES 则让 frames_init 跳过属性传递（600-641）。用户也可用 `driver_quirks` 选项强行指定（470-472）。

## 4. NVDEC 专节

**nvdec 与 cuvid 的关系**：同一 NVDEC 硬件引擎有两套入口。
- hwaccel 路线：`nvdec.c` 实现的 `FFHWAccel`（如 `nvdec_h264.c` 尾部 `ff_h264_nvdec_hwaccel`），软解 parser 完整保留，只把 CUVIDPICPARAMS 填好后丢给 cuvidCreateDecoder 出的 session；
- 原生解码器路线：`cuviddec.c` 的 `h264_cuvid` 等，自带 NAL parser + 显示队列回调（`cuvid_handle_video_sequence` `cuviddec.c:269`、`cuvid_handle_picture_decode` 734、`cuvid_handle_picture_display` 775），其 `hw_configs` 特意设 `hwaccel = NULL`（1799/1810）表示不参与 hwaccel 体系，但仍在回调里调 `ff_get_format`（387）复用同一协商协议。
- "冲突"不在 configure（两者是独立编译目标），而在运行期：二者都会在 GPU 上各建一个 CUvideodecoder 会话，对同一路流用 `-c:v h264_cuvid` 与 `-hwaccel nvdec` 混用属用户错误；文档语义是二选一。

**session 建立**：`ff_nvdec_decode_init`（`nvdec.c:404`）映射 codec/chroma id（76/96）→ 组 CUVIDDECODECREATEINFO：`ulNumDecodeSurfaces = FFMIN(decode_pool_size, 32)`（628）、`ulNumOutputSurfaces` opaque 为 0、unsafe 至多 64、常规为 1（629）→ `nvdec_decoder_create`（222）里 `cuvidLoadFunctions`+`cuvidGetDecoderCaps` 能力预检（115-173，驱动太旧则"Continuing blind"）+ `cuvidCreateDecoder`（263）。超过 32 surfaces 失败时有专门提示建议降低线程数（633-638）。

**surface pool 的两套实现**：
- 传统（frames ctx 格式 = AV_PIX_FMT_CUDA）：hwcontext 侧用 `nvdec_alloc_dummy`（316-324）占位——真正的像素内存在 NVDEC 内部，FFmpeg 只维护一个 refstruct pool 发 `unsigned int` 索引（`NVDECFramePool` `nvdec.c:69-72`，分配回调 279-290 顺序发号）。`ff_nvdec_start_frame`（946）从池取 idx（965-971），池耗尽报 "No decoder surfaces left"（967）；`ff_nvdec_end_frame`（1014）`cuvidDecodePicture` 提交（1040）。输出帧上 `nvdec_retrieve_data`（771，挂在 decode.c:706 钩子）调 `cuvidMapVideoFrame` 得 `CUdeviceptr`（893-895），把 unmap 回调封进 `frame->buf[1]`（905-911）实现"引用归零才归还映射"。不安全输出（UNSAFE_OUTPUT flag）跳过 `av_frame_make_writable`（943）即跳过拷贝。
- CUARRAY opaque（SDK 13.1+，`nvdec.h:50`）：frames ctx 格式 AV_PIX_FMT_CUARRAY，hwcontext_cuda 真造 `CUarray` 池，NVDEC 用 `cuvidRegisterDecodeSurfaces` 直接把解码输出写进这些数组（`nvdec.c:664-670`），帧零拷贝；`surface_in_use` 原子数组 + buf[0] 释放回调配对置位/清位（829-831/759-768），decoder 析构断言全部归还（183-207）。

**像素格式映射（"nvdec_map"）**：`ff_nvdec_frame_params`（1083-1178）在 get_format 阶段就定死 frames ctx：宽度偶对齐（1122-1129）、`initial_pool_size = dpb_size + 2`（1130-1134，注释：防去交织 filter 持帧）、按 bitdepth/chroma 选 sw_format（NV12/P010/P012/NV16/P210/NV24/P410…，1136-1175）。codec 侧每个 `nvdec_*.c` 的 `frame_params` 回调（如 `nvdec_h264.c` 的 `sps->ref_frame_count + sps->num_reorder_frames`）喂 DPB 深度。

**与 NVENC 的关系**：NVDEC 不建自己的 CUDA 上下文——`nvdec_decoder_create` 直接用设备 ctx 的 `cuda_ctx`（243-245）。因此同一 `AVHWDeviceType_CUDA` 设备可同时挂 nvdec 解码与 nvenc 编码，编码器可直接消费解码输出的 CUDA 帧；CUARRAY/`zero_copy` 路线把"解码输出=编码输入"做成真正的零拷贝（cuviddec 的 `zero_copy` 选项强制 CUARRAY，`cuviddec.c:157-166`）。所谓"动态并行度"即 `ulNumDecodeSurfaces` 随线程数/DPB 深度伸缩（628 行 + 633-638 警告）+ cuviddec 的显示延迟缓冲 `CUVID_MAX_DISPLAY_DELAY`（`cuviddec.c:145-148`）。

## 5. VideoToolbox 专节：回调式异步输出与同步取帧的适配

**建立 session**：`videotoolbox_start`（`videotoolbox.c:907`）：codec id → `kCMVideoCodecType_*`（920-965，ProRes 用 codec_tag bswap）→ 组 decoder_spec（`videotoolbox_decoder_config_create` 836：H264/HEVC 强制 `Require HW decoder`，847-854；avcC/hvcC/vpcC/av1C extradata 注入 868-891）→ `CMVideoFormatDescriptionCreate`（988）→ 注册输出回调（1004-1005）→ `VTDecompressionSessionCreate`（1007-1012），错误码一一映射为 AVERROR（1019-1040）。兼容性入口：ProRes 需 macOS 10.9 的 `VTRegisterProfessionalVideoWorkflowVideoDecoders`（967-973），macOS 11+ 补注册补充解码器（975-979）——VT 是否有硬解由系统在运行时决定，这正是 get_format 运行时协商价值的极端例子。

**异步→同步适配（核心）**：VT 的输出走 `videotoolbox_decoder_callback`（717-744）：只做 `CVPixelBufferRetain` 存进 `vtctx->frame`（743），上一帧还在就直接 Release 丢弃（727-730）。同步侧 `ff_videotoolbox_common_end_frame`（1056-1086）提交 bitstream 后立刻 `VTDecompressionSessionWaitForAsynchronousFrames` 把回调全部收干（`videotoolbox_session_decode_frame` 760-766），再用 `videotoolbox_buffer_create`（544）把 pixbuf 包进早先 `ff_videotoolbox_alloc_frame`（152-180）预埋的 `VTHWFrame`：`fdd->hwaccel_priv_post_process = videotoolbox_postproc_frame`（173），由 decode.c:706 统一执行，最后 `frame->data[3] = pixbuf`（140-147）。sw_format/尺寸变了就重建缓存 frames ctx（575-600）。

**错误恢复即生命周期管理**：callback 收到空 image 触发 `reconfig_needed`（732-741，但 macOS 12 的 -17694 引用缺失不触发）；decode 返回 `kVTVideoDecoderMalfunctionErr`/`kVTInvalidSessionErr` 也置位（1076-1077）；下一帧开头 `videotoolbox_stop + videotoolbox_start` 整体重建 session（1062-1069）。

**hwcontext_videotoolbox**：frames pool 就是 `CVPixelBufferPoolCreate`（`hwcontext_videotoolbox.c:230`）+ `CVPixelBufferPoolCreatePixelBuffer`（257）；map 路径 = `CVPixelBufferLockBaseAddress` 后搬 base address/linesize（`vt_map_frame` 683-737）。格式表 `cv_pix_fmts`（45-90）带 full_range 维度，同一 NV12 分 Video/Full Range 两个 OSType（163-180）。

## 6. 三后端差异对比

| 维度 | VAAPI | NVDEC(hwaccel) | VideoToolbox |
|---|---|---|---|
| 输出模型 | 同步：vaEndPicture 入队，读帧前 vaSyncSurface（`hwcontext_vaapi.c:866`） | 半异步：decode 提交即返回，读帧时 map/retrieve（`nvdec.c:771`） | 全异步回调 + 显式 WaitForAsynchronousFrames 转同步（`videotoolbox.c:766`） |
| surface 归属 | FFmpeg 全权：vaCreateSurfaces/DestroySurfaces（531/524） | NVDEC 内部，FFmpeg 只持索引；CUARRAY 模式才真正持有 CUarray | 系统池（CVPixelBufferPool），FFmpeg 持引用 |
| 协商自由度 | 驱动 query 约束 + best-format 挑选（`vaapi_decode.c:317-407`） | 静态表映射（`nvdec.c:1136-1175`） | 静态表 + color range 二维（`hwcontext_videotoolbox.c:45-90`） |
| 错误恢复 | hwaccel 失败 → ff_get_format 剔除格式重试乃至回退软解（decode.c:1348） | 同左；surface 耗尽报 ENOMEM（nvdec.c:967） | session 级自愈：reconfig 重建（videotoolbox.c:1062-1077） |
| 特有坑 | 驱动 quirk 三件套（`hwcontext_vaapi.c:392-415`） | >32 decode surfaces 失败（nvdec.c:633） | 系统决定有无解码器；回调丢帧（727-730） |

## 7. 设计动机

- **为什么用 get_format 运行时协商而不是编译期选择**：硬解可用性取决于运行时才可知的事实——驱动/驱动版本（VAAPI quirk 表按 vendor 字符串匹配，`hwcontext_vaapi.c:476-489`）、GPU 代际能力（`cuvidGetDecoderCaps`，`nvdec.c:115`）、操作系统与系统注册的解码器（`videotoolbox.c:975-979`）、以及 profile/分辨率约束（`vaapi_decode.c:596-607`）。ff_get_format 的"失败剔除重试"循环（decode.c:1348-1357）让每个候选格式都是一次可回退的尝试，最终自然落到软件格式。
- **hwaccel 与普通 decoder 的复用关系**：hwaccel 只接管宏块级处理（start_frame/decode_slice/end_frame），码流解析、DPB、参考帧管理全部复用软解代码——`h264dec.c:714-770` 的 FF_HW 调用点嵌在正常 NAL 分发里即是证据。代价是 hwaccel 必须按软解的数据结构反推硬件参数（如 nvdec_h264 逐字段填 CUVIDH264PICPARAMS）。cuviddec 是反面教材/对照组：绕开软解 parser 换来自带裁剪/缩放/去交织，但失去与软解生态（错误恢复、SEI 处理）的一致性，所以它的 hw_config 显式 `hwaccel=NULL`（`cuviddec.c:1799`）。
- **frame_params 回调**：让 hwaccel 在 get_format 阶段（hwaccel 尚未 init）就能约束未来 frames ctx 的 sw_format/pool 尺寸（`nvdec.c:1093-1096` 注释直说"This may be called from get_format() before avctx->hwaccel is set"），VAAPI 对应 `ff_vaapi_common_frame_params`（668）。

## 8. FAQ 素材

1. **为什么 get_format 回调可能被连续调多次？** ff_get_format 内部循环：init 失败或校验不过就把该格式从候选剔除重来（decode.c:1254-1357），每次都会先 uninit 上一个 hwaccel（1256）。
2. **AV_PIX_FMT_VAAPI 帧的 data[3] 是什么？** VASurfaceID 整数（`vaapi_get_buffer` `hwcontext_vaapi.c:743`；map 路径 840 行还原）。
3. **NVDEC 报 "No decoder surfaces left"？** refstruct 索引池耗尽（`nvdec.c:965-971`），通常是 initial_pool_size（dpb+2，1134）小于实际占用，加 `extra_hw_frames` 或降低输出端持帧。
4. **`h264_cuvid` 和 `-hwaccel nvdec` 能同时用吗？** 不能——两条路线各自创建 CUVID session，语义上二选一；cuvid 的 hw_config 甚至没有 hwaccel（`cuviddec.c:1799`）。
5. **vaDeriveImage 失败会怎样？** frames_init 探测 `derive_works=0`（`hwcontext_vaapi.c:694-716`），map 退化为 vaGetImage 内存拷贝（881-919），`AV_HWFRAME_MAP_DIRECT` 请求会直接 EINVAL（843-846）。
6. **VideoToolbox 播着播着卡死/重启？** callback 空输出或 malfunction 会置 reconfig_needed，下一帧整 session 重建（`videotoolbox.c:1062-1077`）；-17694（参考帧缺失）被特判不触发重配（732-741）。
7. **Intel i965 的历史包袱是什么？** 老 i965 在 vaEndPicture 前就消费参数 buffer，FFmpeg 用 RENDER_PARAM_BUFFERS quirk 在 render 后立即销毁（`vaapi_decode.c:213-222`；quirk 表 `hwcontext_vaapi.c:397-404`，libva≥1.0 后整体裁掉）。
8. **hwdownload 报"输入不是硬件帧"？** 滤镜查询格式时输入侧只收带 HWACCEL flag 的格式、输出侧只收软件格式（`vf_hwdownload.c:38-48`），实际搬运用 `av_hwframe_transfer_data`（141）。
9. **hwmap 如何跨设备？** 支持 `av_hwframe_ctx_create_derived`（`vf_hwmap.c:118/161`）和 `av_hwframe_map`（292/344），模式由derive/映射 flags 决定。
10. **AV_HWACCEL_FLAG_ALLOW_PROFILE_MISMATCH 干嘛的？** VAAPI profile 精确匹配失败时放行近似 profile（`vaapi_decode.c:554-570`），NVDEC 无此层（codec id 映射不看 profile）。

## 9. 深挖方向

1. **DRM prime 互操作**：`vaapi_map_from_drm`（`hwcontext_vaapi.c:1109`）如何用 VaapiSurfaceID 绑定 prime fd，是 Linux 下硬解→零拷贝渲染的枢纽。
2. **hwcontext 派生（derive）**：`vaapi_device_derive`（1992）从 DRM/VAAPI 既有显示派生设备，配合 `av_hwdevice_ctx_create_derived`（`hwcontext.c:651`）。
3. **Vulkan 后端对照**：`hwcontext_vulkan.c` 是唯一自带大规模 frame queue/信号量同步的后端，可与本文三个"薄封装"后端对比 FFmpeg 对现代显式 API 的适配成本。
4. **帧线程与 hwaccel**：`HWACCEL_CAP_ASYNC_SAFE`（`hwaccel_internal.h:31`，vaapi_h264.c 有标注）与 frame-threaded hwaccel 路径的交互。
5. **CUARRAY zero-copy 全 GPU 管线**：nvdec CUARRAY → scale_cuda/nvenc 的实测带宽收益与 `surface_in_use` 原子簿记（`nvdec.c:759-768`）。

## 写作要点速查表

| 主题 | 文件:行号 |
|---|---|
| 默认 get_format 实现（设备优先→软件格式） | libavcodec/decode.c:1006-1067 |
| hwaccel_init / 失败回滚 | libavcodec/decode.c:1182-1215 |
| ff_get_format 主循环 + 剔除重试 | libavcodec/decode.c:1229-1365（1258/1348） |
| post_process 统一出口 | libavcodec/decode.c:706-713 |
| h264 协商入口与 hw_configs 表 | libavcodec/h264_slice.c:935；libavcodec/h264dec.c:1172 |
| HW_CONFIG 宏（NVDEC/VAAPI/VT） | libavcodec/hwconfig.h:42-52,68-77 |
| VAAPI profile 表 / make_config / render | libavcodec/vaapi_decode.c:409-472 / 478-666 / 166-245 |
| VAAPI quirk 表 + vendor 匹配 | libavutil/hwcontext_vaapi.c:392-415,470-498 |
| VAAPI surface pool + derive 探测 | libavutil/hwcontext_vaapi.c:531-573,575-726 |
| VAAPI map（sync/derive/copy 三路） | libavutil/hwcontext_vaapi.c:824-969 |
| NVDEC session 建立 + 表面数上限 | libavcodec/nvdec.c:404-712（628-638） |
| NVDEC 索引池 / start_frame / retrieve | libavcodec/nvdec.c:279-290,946-982,771-944 |
| NVDEC sw_format 映射（dpb+2） | libavcodec/nvdec.c:1083-1178（1134） |
| cuvid hw_configs（hwaccel=NULL） | libavcodec/cuviddec.c:1790-1819 |
| cuvid 回调内 ff_get_format | libavcodec/cuviddec.c:269-418（387） |
| VT session 建立 + 错误码映射 | libavcodec/videotoolbox.c:907-1041（1007） |
| VT 异步回调 / 等待同步 | libavcodec/videotoolbox.c:717-744,760-766 |
| VT reconfig 自愈 | libavcodec/videotoolbox.c:1056-1086 |
| VT CVPixelBufferPool / map | libavutil/hwcontext_videotoolbox.c:192-274,683-737 |
| hwdownload / hwmap 关键行 | libavfilter/vf_hwdownload.c:38-48,141；libavfilter/vf_hwmap.c:118,292,344 |
