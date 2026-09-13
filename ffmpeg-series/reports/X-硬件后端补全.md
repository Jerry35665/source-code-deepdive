# 硬件后端补全：QSV / MediaCodec / D3D12VA / AMF

> 源码基线：ffmpeg master，commit `9f63b36a`。所有行号经 `grep -n` / Read 实际核对，路径为仓库相对路径。
> 前置：第 12 章已讲清 VAAPI/NVDEC/VideoToolbox 共用的协商链（`ff_get_format → hwaccel_init → surface 池`）。本章只讲差异，不再重复该链路本身。

## 1. 全景：hwaccel 接口的四种"填法"

第 12 章三个后端的共同点是：软件解码器内部挂一个 `AVHWAccel`，`ff_get_format` 选中 hw 像素格式后由 `hwaccel_init` 接管。本章四家填同一套接口的方式完全不同——**只有 D3D12VA 是真正的 hwaccel**，其余三家是"包装解码器"（wrapper decoder，`hwaccel = NULL`，注册成独立的 `h264_qsv` / `xxx_amf` / `xxx_mediacodec` 解码器）：

| 后端 | 平台 | 解码 / 编码 | 接口形态 | 原生帧对象 | 输出模型 |
|---|---|---|---|---|---|
| VAAPI / NVDEC / VideoToolbox（12 章） | Linux / 跨平台 / Apple | 解码为主 | 真 hwaccel（hwconfig.h:72-77 的 `HW_CONFIG_HWACCEL(..., &ff_xxx_hwaccel)`） | VASurfaceID / CUdeviceptr / CVPixelBuffer | hw 帧内含句柄，transfer/map 出软件帧 |
| **QSV** | Windows + Linux(Intel) | 解码 + 编码 + VPP | wrapper：`qsv_hw_configs` 中 `.hwaccel = NULL`（qsvdec.c:118-129），`AV_PIX_FMT_QSV` 帧的 `data[3]` 指向 `mfxFrameSurface1` | `mfxFrameSurface1`（MemId 是 `mfxHDLPair`） | video memory（QSV 帧出）或 system memory（SDK 内部拷出）双模式 |
| **MediaCodec** | Android | 视频解码 + 音频解码 + 编码 | wrapper：`AV_CODEC_HW_CONFIG_METHOD_AD_HOC`（mediacodecdec.c:583-594），帧里**没有像素数据** | `AVMediaCodecBuffer`（buffer index 令牌） | Surface 模式（渲染令牌）/ Byte Buffer 模式（CPU 拷贝） |
| **D3D12VA** | Windows 10+ | 解码 + 编码 | **真 hwaccel**：`HW_CONFIG_HWACCEL(1, 1, 0, D3D12, D3D12VA, ...)`（hwconfig.h:82-83），`ff_h264_d3d12va_hwaccel` 带 start_frame/decode_slice/end_frame（d3d12va_h264.c:200-214） | `AVD3D12VAFrame`（ID3D12Resource + 每帧一个 fence） | D3D12 帧内含 texture 指针，transfer 走 COPY 队列 + staging |
| **AMF** | Windows(AMD) / Linux(Vulkan) | 解码 + 编码（解码为新加入） | wrapper：`amf_hw_configs` 中 `.hwaccel = NULL`（amfdec.c:45-56），`AV_PIX_FMT_AMF_SURFACE` 帧的 `data[0]` 是 `AMFSurface*` | `AMFSurface`（COM 引用计数对象） | AMF 帧出（数据仍在 SDK 池）或 `Convert(AMF_MEMORY_HOST)` 拷出 |

wrapper 解码器不走 12 章的 `hwaccel_init`，但**仍然走 `ff_get_format`**——比如 QSV 在首个包解析出头后用 `{AV_PIX_FMT_QSV, 系统内存格式, NONE}` 调 `ff_get_format`（qsvdec.c:302-311），MediaCodec 用 `{AV_PIX_FMT_MEDIACODEC, NONE}`（mediacodecdec_common.c:748-754）。差别在于：hwaccel 形态下 `ff_get_format` 的返回值决定"是否挂 hwaccel"，wrapper 形态下它只决定"输出 QSV 帧还是系统内存帧"。

hwconfig.h 的用法差异一句话：12 章三家用 `HW_CONFIG_HWACCEL` 宏把 hwaccel 指针挂进配置（hwconfig.h:42-52）；本章 wrapper 三家手写 `AVCodecHWConfigInternal` 或用 `HW_CONFIG_ENCODER_*` 宏（hwconfig.h:97-101，AMF 编码器在 amfenc.c:714-726），`.hwaccel` 恒为 NULL；D3D12VA 则完全复用 12 章的宏，只是 ad_hoc 参数为 0（hwconfig.h:83）。

本章文件地图（方便对照翻阅）：QSV 三件套 `libavcodec/qsv.c`（session/allocator 共享层）+ `qsvdec.c`（解码器）+ `libavutil/hwcontext_qsv.c`（设备/帧上下文与上下行）；MediaCodec 六件 `mediacodecdec.c` / `mediacodecdec_common.c` / `mediacodec_wrapper.c`（JNI+NDK）/ `mediacodec_surface.c` / `mediacodec.c`（公开渲染 API）+ `libavutil/hwcontext_mediacodec.c`；D3D12VA 两件 `libavcodec/d3d12va_decode.c`（编解码共享提交层）+ `libavutil/hwcontext_d3d12va.c`，各 codec 文件（d3d12va_h264.c 等）只是填参数；AMF 三件 `amfdec.c` / `amfenc.c` + `libavutil/hwcontext_amf.c`。

## 2. QSV 专节：session 生命周期与 mfx→VAAPI 网关

### 2.1 三级 session 来源

QSV 的一切围绕 `mfxSession`。解码器初始化时按优先级选 session 来源（qsvdec.c:186-247 `qsv_init_session`）：用户经 `avctx->hwaccel_context` 直供的 session → 从 `hw_frames_ctx` 派生 → 从 `hw_device_ctx` 派生 → 完全内部自建。`mfxSession` 直接嵌在 `AVQSVDeviceContext` 里随 `AVHWDeviceContext` 生命周期管理（hwcontext_qsv.c:77-90，`qsv_device_free` 里 `MFXClose`+`MFXUnload`，hwcontext_qsv.c:2354-2366）。

oneVPL（API 2.0+）走 loader/config 枚举路径：`MFXLoad → MFXCreateConfig → MFXSetConfigFilterProperty → MFXCreateSession`（qsv.c:494-638）；旧 MediaSDK 走 `MFXInitEx`（qsv.c:642-679）。从设备/帧上下文派生子 session 后，用 `MFXJoinSession` 把子 session 挂到父 session 共享调度资源（qsv.c:1092-1097，hwcontext_qsv.c:1341-1348，要求运行时 ≥1.25）。

### 2.2 Linux 网关：mfx 借 VAAPI 的显示连接

mfx 在 Windows 上自带 D3D9/D3D11 适配，在 Linux 上**没有任何自己的设备层**——必须有人递给它一个 `VADisplay`。这就是网关：

```c
// qsv.c:464-492（仅 Linux 编译，宏定义见 qsv_internal.h:26-28：CONFIG_VAAPI && !_WIN32）
static int ff_qsv_set_display_handle(AVCodecContext *avctx, QSVSession *qs)
{
    ...
    av_dict_set(&child_device_opts, "vendor_id", "0x8086", 0);
    av_dict_set(&child_device_opts, "driver",    "iHD",    0);
    ret = av_hwdevice_ctx_create(&qs->va_device_ref, AV_HWDEVICE_TYPE_VAAPI, ...);
    ...
    ret = MFXVideoCORE_SetHandle(qs->session,
            (mfxHandleType)MFX_HANDLE_VA_DISPLAY, (mfxHDL)hwctx->display);
```

三个要点：
1. **条件编译**：`AVCODEC_QSV_LINUX_SESSION_HANDLE` 仅在 `CONFIG_VAAPI && !defined(_WIN32)` 时定义（qsv_internal.h:26-28）——libva-win32 明确排除。
2. **驱动强约束**：创建子 VAAPI 设备时写死 `vendor_id=0x8086` + `driver=iHD`（qsv.c:471-472）；hwcontext 层的 `qsv_device_create` 同样如此（hwcontext_qsv.c:2572-2573），注释明说 libmfx 依赖 iHD 的特定行为。这一步发生在**内部自建 session** 的路径上（qsv.c:710-714）。
3. **反向复用**：用户显式给 `qsv:...` 设备时，`qsv_device_create` 先创建一个**真正的子设备**（VAAPI/D3D11/DXVA2），再把它的句柄 `MFXVideoCORE_SetHandle` 进 mfx（hwcontext_qsv.c:2407-2478 `qsv_device_derive_from_child`，VAAPI 情况取 `child_device_hwctx->display`，hwcontext_qsv.c:2425-2426）。QSV 设备从此持有 child_device_ctx 引用（QSVDevicePriv，hwcontext_qsv.c:73-75）。

运行期判定走 `MFXQueryIMPL` + `MFX_IMPL_VIA_MASK`：`MFX_IMPL_VIA_VAAPI/D3D11/D3D9` 三分支映射 handle_type 与 child 设备类型（hwcontext_qsv.c:311-332 `qsv_device_init`；qsv.c:1057-1066）。Windows 内部自建时 D3D11 优先尝试（qsv.c:684-689 的 `impls[]`）。

### 2.3 表面池：opaque vs non-opaque 与双池派生

- **opaque（仅旧 MediaSDK）**：`QSV_HAVE_OPAQUE = !QSV_ONEVPL`（qsv_internal.h:67-68）。SDK 自己管池，FFmpeg 只递一张表面指针数组（`mfxExtOpaqueSurfaceAlloc`，hwcontext_qsv.c:1443-1464）；此时不设 allocator（qsv.c:1135-1153 的 `if (!opaque)`）。代价是表面身份对 FFmpeg 不透明、oneVPL 已废弃。
- **non-opaque**：帧池建立在**child 设备**上——`qsv_init_child_ctx` 用 mfx 句柄反手造一个 VAAPI/D3D11/DXVA2 的 frames context，再把每个 `VASurfaceID`/`ID3D11Texture2D` 包成 `mfxHDLPair`（hwcontext_qsv.c:524-667）。VAAPI 的 pair.first 是 `VASurfaceID*` 指针、second 恒 `MFX_INFINITE`（hwcontext_qsv.c:615-624）；D3D11 的 second 是 texture array 下标（hwcontext_qsv.c:626-644）。
- **动态池**：`initial_pool_size == 0`（oneVPL 2.9+ 且非 D3D9，qsvdec.c:344-347）时每次取帧现场从 child 池借纹理（`qsv_dynamic_pool_alloc`，hwcontext_qsv.c:426-510），池大小不再预绑定解码 DPB。

正因为表面身份就是 child 设备的对象，QSV↔VAAPI/D3D11 之间的 map/derive 只是拆包重贴标签：`qsv_frames_derive_from` 直接把 pair.first 抄进 `AVVAAPIFramesContext.surface_ids`（hwcontext_qsv.c:1518-1532），`qsv_map_from` 把 `VASurfaceID` 塞进 `dst->data[3]`（hwcontext_qsv.c:1604-1613）。上下行回传则借 VPP：惰性创建 session_download/session_upload，`MFXVideoVPP_RunFrameVPPAsync` + `MFXVideoCORE_SyncOperation`（hwcontext_qsv.c:1288-1405 建链，1869-1887 收割）。

### 2.4 首包建链：header → QueryIOSurf → 池定型

wrapper 解码器没有 `avcodec_open2` 时刻的码流信息，于是把"协商"推迟到第一个可解析的包：`qsv_process_data` 检测到 `!q->session || !q->initialized` 时走 `qsv_decode_header`（`MFXVideoDECODE_DecodeHeader`，qsvdec.c:425-492），成功后 `MFXVideoDECODE_QueryIOSurf` 拿 SDK 建议的表面数 `suggest_pool_size`（qsvdec.c:1042-1046），再进 `qsv_decode_preinit`：`ff_get_format`（qsvdec.c:307）、按 `hw_device_ctx` 现建 hw_frames_ctx（固定池大小 `suggest_pool_size + 16 + extra_hw_frames`，动态池条件见 2.3，qsvdec.c:327-357）、推断 iopattern（qsvdec.c:359-378）并最终建 session。码流侧颜色/场序信息也从 header 的 `mfxExtVideoSignalInfo` 回填 avctx（qsvdec.c:470-476）。分辨率参数变更复用同一通道：`MFX_ERR_INCOMPATIBLE_VIDEO_PARAM` 置 reinit_flag → 零长包冲刷 → 重新走 header（qsvdec.c:827-832, 1014-1052）。用户直供 session 的老接口是 `AVQSVContext`（av_qsv_alloc_context，qsv_api.c:33-37），session/iopattern/ext_buffers 三件套在 qsvdec.c:319-325 接入。

### 2.5 解码主循环：异步深度与同步时机

```c
// qsvdec.c:813-825
do {
    ret = get_surface(avctx, q, &insurf);
    ...
    ret = MFXVideoDECODE_DecodeFrameAsync(q->session, avpkt->size ? &bs : NULL,
                                          insurf, &outsurf, sync);
    if (ret == MFX_WRN_DEVICE_BUSY)
        av_usleep(500);
} while (ret == MFX_WRN_DEVICE_BUSY || ret == MFX_ERR_MORE_SURFACE);
```

每次成功产出 `(sync, out_frame)` 入 `async_fifo`（qsvdec.c:856-870），队列深度即 `async_depth`（默认 4，qsv_internal.h:50）；攒满或 flush 时才出队一帧（qsvdec.c:875-880）。**关键同步时机**：只有输出为系统内存（`avctx->pix_fmt != AV_PIX_FMT_QSV`）时才当场 `SyncOperation`（qsvdec.c:883-887）——QSV 帧输出时同步被推迟到消费者 transfer/map 那一刻。参数变更重初始化（分辨率切换）用 reinit_flag + 零包刷新处理（qsvdec.c:827-832, 1014-1052）。

## 3. MediaCodec 专节：Surface 令牌、JNI 双后端与同步适配

### 3.1 输出模式：configure 时一次定型

Surface 还是 Byte Buffer，不是解码中途可选的开关，而是 **`ff_AMediaCodec_configure(codec, format, s->surface, NULL, 0)` 时是否传 surface 一次定型**（mediacodecdec_common.c:854）。surface 有两个来源：`AV_HWDEVICE_TYPE_MEDIACODEC` 设备上下文里的 `AVMediaCodecDeviceContext.surface/native_window`（mediacodecdec_common.c:758-767），或旧 API `av_mediacodec_default_init` 塞进 `avctx->hwaccel_context` 的全局引用（mediacodec.c:44-63，mediacodecdec_common.c:769-772）。`s->surface` 存在则输出格式恒为 `AV_PIX_FMT_MEDIACODEC`（mediacodecdec_common.c:227-229）。

- **Surface 模式（零拷贝出显示）**：输出 buffer 是解码器私有的 graphic buffer，FFmpeg 拿到的"帧"只是索引令牌。`mediacodec_wrap_hw_buffer` 把 `AVMediaCodecBuffer`（含 buffer index、serial、ctx 引用）挂到 `frame->data[3]`（mediacodecdec_common.c:296-369，352 行），帧的 `buf[0]` 释放回调只做 `releaseOutputBuffer(index, render=0)` 归还、**不渲染**（mediacodecdec_common.c:278-294）。真正的上屏由播放器在合适的时机调公开 API `av_mediacodec_render_buffer` / `av_mediacodec_render_buffer_at_time`（mediacodec.c:88-118），底层即 JNI `releaseOutputBuffer(IZ)`（mediacodec_wrapper.c:259）或 NDK 同名函数。
- **Buffer 模式（可回读）**：`getOutputBuffer` 拿原始指针，按厂商 color format 分发拷贝函数（mediacodecdec_common.c:1036-1047，分发表 488-509，格式表 191-218）——QCOM/TI/NVIDIA 的私有 YUV 排布各有专属 copy 例程（借道 GStreamer 的成果，mediacodecdec_common.c:45-84 致谢注释）。拷贝原因是 flush 会作废所有 MediaCodec buffer，必须先复制进自己的引用计数 buffer（mediacodecdec_common.c:459-465 注释）。

`delay_flush` 选项与 serial 计数实现了"用户还持有输出 buffer 时推迟 flush"的协议：flush 先置 `flushing=1`，等 `hw_buffer_count` 归零才真正 `AMediaCodec.flush`（mediacodecdec_common.c:1105-1133，serial 检查在 284）。

参数侧还有一段纯 FFmpeg 的活：MediaCodec 需要 `csd-0`/`csd-1` 初始化数据，H264/HEVC 由 FFmpeg 自己的 PS 解析器从 extradata 提取 SPS/PPS(VPS) 再转义成 Annex-B NALU（mediacodecdec.c:131-192 的 `h2645_ps_to_nalu`，含防竞争字节 0x03 插入，101-119），其余编码直接透传 extradata（mediacodecdec.c:298-308）。同一套 wrapper 也包了音频解码（AAC/AMR-NB/AMR-WB/MP3，mediacodecdec.c:700-714），音频侧只有 Buffer 模式，输出经 `ff_get_buffer` + memcpy 并即时 release（mediacodecdec_common.c:371-442，注释解释 flush 语义强制拷贝）。

### 3.2 JNI wrapper 层：一套虚表两种实现

`FFAMediaCodec` 是手写虚表接口，两个实现：JNI 后端（`FFAMediaCodecJni`，mediacodec_wrapper.c:283-300）与 NDK 后端（dlsym `libmediandk.so` 的 `AMediaCodec_*`）。JNI 后端每个调用都要 `ff_jni_get_env` 拿线程附着后的 JNIEnv（宏定义 mediacodec_wrapper.c:309-316），方法 ID 在加载期集中反射注册（如 `releaseOutputBuffer(IZ)V`，mediacodec_wrapper.c:259）。选择逻辑：`ndk_codec` 默认 -1 时，**没有 JavaVM 就用 NDK**（mediacodecdec.c:320-322 `s->use_ndk_codec = !av_jni_get_java_vm(avctx)`）。

hwcontext 一侧极薄：`AV_HWDEVICE_TYPE_MEDIACODEC` 设备上下文只是个 surface/native_window 载体（hwcontext_mediacodec.c:31-36），**没有任何 frames 方法**（hwcontext_mediacodec.c:107-121）——因为帧的产出/回收完全由解码器 wrapper 直连 MediaCodec，不经过 hwframes 池。`create_window` 选项会 dlopen libmediandk 创建持久输入 surface（hwcontext_mediacodec.c:76-89）。hwconfig 用 `AV_CODEC_HW_CONFIG_METHOD_AD_HOC`（mediacodecdec.c:587）正是因为渲染要靠 mediacodec.h 公开 API 而非 hwframes map 机制。

### 3.3 异步模型：SDK 有、FFmpeg 不用

wrapper 层实现了 `setAsyncNotifyCallback`（wrapper.h:367，NDK 实现 mediacodec_wrapper.c:2529-2560，JNI 实现 1865-1932），但**全树没有任何解码器调用它**——FFmpeg 解码用的是同步轮询：`dequeueOutputBuffer` 超时 8ms（mediacodecdec_common.c:86-87），draining 时 1s（88 行）；`mediacodec_receive_frame` 里"输入端口满就阻塞等输出"的双端口泵（mediacodecdec.c:511-527），专门处理 `send_packet/receive_frame` 双侧都 EAGAIN 违反 API 契约的边角。

## 4. D3D12VA 专节：command queue 语义与显式同步

D3D12VA 是四家中唯一照 12 章剧本演的：真 hwaccel、走 `ff_decode_get_hw_frames_ctx`（d3d12va_decode.c:421）、每帧 start_frame/decode_slice/end_frame。差异全在 D3D12 本身——它没有隐式同步，一切靠"队列-命令列表-fence"三件套。

### 4.1 建链：decoder + heap + 专用队列

`ff_d3d12va_decode_init`（d3d12va_decode.c:405-493）一次建齐：

```c
// d3d12va_decode.c:412-417 + 467-476
D3D12_COMMAND_QUEUE_DESC queue_desc = {
    .Type     = D3D12_COMMAND_LIST_TYPE_VIDEO_DECODE,   // 专用解码队列类型
    ...
};
DX_CHECK(ID3D12Device_CreateCommandQueue(...  &ctx->command_queue));
DX_CHECK(ID3D12Device_CreateCommandList(0, queue_desc.Type,
         command_allocator, NULL, ..., &ctx->command_list));
DX_CHECK(ID3D12VideoDecodeCommandList_Close(ctx->command_list));
ID3D12CommandQueue_ExecuteCommandLists(ctx->command_queue, 1, ...);  // 预热
```

能力探测先行：`D3D12_FEATURE_VIDEO_DECODE_SUPPORT` 不支持即 ENOSYS，**DecodeTier < TIER_2 直接拒绝**（d3d12va_decode.c:347-357——tier 1 的按分块解码未实现）；若配置要求 `REFERENCE_ONLY_ALLOCATIONS_REQUIRED` 则额外建 reference-only 资源槽位表（d3d12va_decode.c:361-369，槽位复用逻辑在 `get_reference_only_resource`，50-112 行，注释解释了不按输出资源去重会耗尽槽位的泄漏问题）。对象分两层：`ID3D12VideoDecoder`（无状态，376-377）与 `ID3D12VideoDecoderHeap`（携带分辨率/码率/DPB 深度，`MaxDecodePictureBufferCount = max_num_ref`，d3d12va_decode.c:304-316）。

### 4.2 每帧提交与双 fence

`ff_d3d12va_common_end_frame`（d3d12va_decode.c:558-692）是所有 codec 共享的提交尾：resource barrier 把输出纹理从 COMMON 推到 VIDEO_DECODE_WRITE（618-628），参考帧批量推到 VIDEO_DECODE_READ（663），`DecodeFrame`（667），barrier 原地翻转还原（669-672），Close 后 `ExecuteCommandLists`（674-676），然后 **Signal 两把 fence**——帧级 `f->sync_ctx.fence`（678）与解码器全局 fence（680）。帧级 fence 的妙处在**消费点同步**：同一帧纹理被复用前才 `d3d12va_fence_completion`（644，SetEventOnCompletion + WaitForSingleObjectEx，263-274），未复用就永不阻塞 CPU，管线上多帧可并行。

辅助对象（command allocator + bitstream upload buffer）用对象池回收：用完压入 `objects_queue`（异步深度 36，d3d12va_decode.h:140），下次先查 `ID3D12Fence_GetCompletedValue >= fence_value` 才复用，否则新建（d3d12va_decode.c:193-261）——allocator 不可重置直到 GPU 用完，这正是 D3D12 显式生命周期的教科书处理。

### 4.3 与 dxva2/d3d11va 的血缘（只提名）

D3D12VA 的码流侧直接复用旧后端的家底：`d3d12va_h264.c` include 的是 `dxva2_internal.h`（d3d12va_decode.c:36 同样引入），H264 的 `DXVA_PicParams_H264`/`DXVA_Qmatrix_H264` 结构与 slice 解析就是 dxva2/d3d11va 那一套——`max_num_ref` 取自 `FF_ARRAY_ELEMS(pp.RefFrameList) + 1`（d3d12va_h264.c:193）。变化只在提交端：dxva2 的 `IDirectXVideoDecoder_Execute`/d3d11va 的 `VideoDecoderEndFrame` 换成了"录命令列表→ExecuteCommandLists→Signal fence"。hwconfig 层也能看出代际：旧 `HWACCEL_D3D11VA` 宏是 ad_hoc-only、device_type=NONE 的兼容残迹（hwconfig.h:80-81），而 `HWACCEL_D3D12VA` 是 (device,frames,no-adhoc) 的现代形态（hwconfig.h:82-83）。

### 4.4 hwcontext：COPY 队列与跨队列等待

frames 层（hwcontext_d3d12va.c）自建 `D3D12_COMMAND_LIST_TYPE_COPY` 队列做上下行（142-146），staging buffer 按 READBACK/UPLOAD 堆类型惰性创建（108-134，531-537/574-580）。下载时关键的跨队列同步：

```c
// hwcontext_d3d12va.c:558-562（下载：拷贝前等解码队列完成该帧）
DX_CHECK(ID3D12CommandQueue_Wait(s->command_queue, f->sync_ctx.fence, f->sync_ctx.fence_value));
ID3D12CommandQueue_ExecuteCommandLists(s->command_queue, 1, ...);
ret = d3d12va_wait_queue_idle(&s->sync_ctx, s->command_queue);
```

GPU 在 GPU 上等待（`CommandQueue_Wait`），无需 CPU 介入——这是 D3D12 相对 dxva2/d3d11va"Lock 即阻塞"的本质升级。池侧支持单纹理数组模式（`AV_D3D12VA_FRAME_FLAG_TEXTURE_ARRAY`，一次 `CreateCommittedResource` 分配整个数组，帧只记 subresource_index，hwcontext_d3d12va.c:239-273, 329-355），每张纹理出厂自带独立 fence（311-314）。设备侧 dlopen d3d12.dll/dxgi.dll（629-643）、`D3D12CreateDevice` 要求 FL 12.0（757）、`QueryInterface` 出 `ID3D12VideoDevice`（686-687）。

## 5. AMF 专节："只有编码"已成历史，组件事件模型是本体

### 5.1 现状勘误：解码器已在树中

AMF **不再只有编码**。`amfdec.c` 定义了 h264/hevc/vp9/av1 四个 `_amf` 解码器（amfdec.c:840-843），构建项 `OBJS-$(CONFIG_AV1_AMF_DECODER) += amfdec.o`（libavcodec/Makefile:183、436、467、825），configure 声明 `av1_amf_decoder_deps="amf"` 等（configure:3635、3655、3681、3744）。连 configure 帮助文本都还是旧话："--disable-amf disable AMF video **encoding** code"（configure:351）——文档滞后于代码。报告与旧资料若写"AMF 仅编码"，需要注明这是历史状态。解码器同样是 wrapper 形态（amfdec.c:45-56 `.hwaccel = NULL`，capabilities 含 `AV_CODEC_CAP_HARDWARE`，amfdec.c:833）。

### 5.2 组件与事件驱动：SubmitInput / QueryOutput / Drain

AMF 是 COM 风格组件模型：`factory->CreateComponent(context, codec_id, &decoder)`（amfdec.c:116），一切配置走 `AMF_ASSIGN_PROPERTY_*` 宏（色彩、DPB、低延迟、Smart Access Video 等，amfdec.c:119-158）。驱动循环是**生产-消费轮询**而非回调：

```c
// amfdec.c:707-715（提交侧背压）
res = amf_buffer_from_packet(avctx, avpkt, &buf);
do {
    res = ctx->decoder->pVtbl->SubmitInput(ctx->decoder, (AMFData*) buf);
    if (res == AMF_DECODER_NO_FREE_SURFACES)
        av_usleep(100);
} while (res == AMF_DECODER_NO_FREE_SURFACES);
```

输出侧 `QueryOutput`（amfdec.c:587），`AMF_REPEAT` 即"暂无输出"映射为 EAGAIN（741-743）；EOF 后进入 drain 状态机（688-703, 744-773）。**分辨率切换**是事件化的：`SubmitInput` 返回 `AMF_RESOLUTION_CHANGED` → 主动 `Drain` 收干旧流 → EOS 后读 `AMF_VIDEO_DECODER_CURRENT_SIZE`、`ReInit` 组件、重建 hw_frames_ctx（amfdec.c:723-729, 744-771）。

### 5.3 池的真相：SDK 内部池 + dummy AVBufferPool

AMF 的表面池在 **SDK 内部**：`AMF_VIDEO_DECODER_SURFACE_POOL_SIZE` 设 36 + extra_hw_frames + 帧线程数，上限硬剪 100（amfdec.c:82, 175-188）。FFmpeg 侧的 `AVHWFramesContext` 是个空壳——`AMFFramesContext` 注释明说只为满足 "HW format requires hw_frames_ctx to be non-NULL"（hwcontext_amf.c:102-109），池分配器返回 data 为 NULL 的占位 buffer（hwcontext_amf.c:370-381），真正的 `AMFSurface*` 由解码器在输出时包进 `av_buffer_create` + Release 回调（amfdec.c:530-536）。无 hw 设备时走 `surface->Convert(AMF_MEMORY_HOST)` 逐平面拷出（amfdec.c:541-556；hwcontext 的 transfer_data_from 同样如此，hwcontext_amf.c:505）。设备侧 dlopen AMF 运行库（hwcontext_amf.c:654-668），初始化顺序 DX11 → DX9 → Vulkan（hwcontext_amf.c:612-626），可从 D3D11/DXVA2/D3D12 设备派生（hwcontext_amf.c:828-859，D3D12 走 `AMFContext2.InitDX12`，805-824）。

编码侧同构：四种输入来源各走各路——D3D11 纹理经 `CreateSurfaceFromDX11Native` 零拷贝包裹（数组下标用 `SetPrivateData(AMFTextureArrayIndexGUID)` 侧带，amfenc.c:405-418）、DXVA2 包裹（420-428）、AMF_SURFACE 直接 Acquire（430-436）、软件帧 AllocSurface+拷贝（437-443）。背压用 `AMF_INPUT_FULL`：塞不进就暂存 surface 稍后重投（amfenc.c:530-543, 675-693）；无查询超时支持的驱动上 1ms 轮询（660-667）。帧生命周期靠把 `AVFrame*` 指针塞进 surface 的 int64 属性、输出时取回释放（amfenc.c:368-390）。DTS 延迟从时间戳 FIFO 尾差推算（amfenc.c:261-277）。

## 6. 差异对比（与 12 章合并视角）

| 维度 | VAAPI/NVDEC/VT（12 章） | QSV | MediaCodec | D3D12VA | AMF |
|---|---|---|---|---|---|
| 失败暴露时机 | ff_get_format 时 probe/创建失败即降级软解 | **延迟到首包**：`DecodeHeader` 成功才建 session/池（qsvdec.c:1022-1052），打开时几乎不失败 | configure/start 在 init 即失败（mediacodecdec_common.c:854-875） | avcodec_open2 时 hwaccel_init 内建 decoder+heap（d3d12va_decode.c:405-493），tier2 探测即拒 | init 时 CreateComponent+Init（amfdec.c:284），分辨率/格式延迟到输出 |
| 池策略 | hwframes 池持原生 surface | 固定池包 child 设备表面，或动态池（hwcontext_qsv.c:411-522；qsvdec.c:344-347） | **无 FFmpeg 池**：SDK 私有 buffer，帧是索引令牌 + hw_buffer_count 记账 | AVBufferPool 持 ID3D12Resource，或单纹理数组模式（hwcontext_d3d12va.c:275-355） | SDK 内部池（36+ext，cap 100），FFmpeg 池是占位（hwcontext_amf.c:370-381） |
| 降级路径 | 标准：hwaccel 失败回软件解码 | iopattern 回落 `OUT_SYSTEM_MEMORY`（qsvdec.c:376-377），输出即软件帧；VPP 上下行不可用则报 ENOSYS | Surface 不给即 Buffer 模式（表面→CPU 拷贝本身就是降级） | 无池内降级，走 12 章通用 ff_get_format 回软解 | `Convert(AMF_MEMORY_HOST)` 拷出（amfdec.c:541） |
| 同步模型 | 各异（VAAPI BID 等） | sync point FIFO，QSV 帧输出时**零同步**（qsvdec.c:883-887） | 无显式同步（Android 侧保证） | 双 fence + 跨队列 GPU Wait | 轮询 + usleep，无 fence |
| 帧内是什么 | 句柄（surface id/指针/pixelbuffer） | `mfxFrameSurface1*`（data[3]） | `AVMediaCodecBuffer*` 索引令牌（data[3]） | `AVD3D12VAFrame*`（data[0]，含 texture+fence） | `AMFSurface*`（data[0]） |

补一条表格装不下的横向观察——**flush 语义**：hwaccel 形态（12 章 + D3D12VA）flush 即重置解析器、池归位；wrapper 形态则各有一套"排空协议"：QSV 用零长包冲刷 async_fifo（qsvdec.c:999-1000, 1014-1020），MediaCodec 靠 serial/delay_flush 等 buffer 归还（3.1 节），AMF 走 Drain→QueryOutput→AMF_EOF 状态机（amfdec.c:688-703）——flush 是否阻塞、是否丢帧，三家答案完全不同，这是上层播放器接入时最常踩的差异点。

## 7. 设计动机

**QSV 为何必须跨后端网关**：mfx 是纯用户态 API 抽象，Linux 上没有自己的 KMS/DRM 层，硬编解码最终要落到 i915 的 VAAPI 路径上——所以"QSV 设备"在 FFmpeg 里的实体就是一个**持有 VADisplay 的 VAAPI 子设备 + 一个 SetHandle 过的 mfxSession**（hwcontext_qsv.c:2407-2464）。这一设计一石三鸟：省掉第二份设备管理代码；让 QSV 与 VAAPI 表面天然互通（derive/map 全是拆包，2.3 节）；把 Intel 驱动碎片化（iHD vs 旧驱动）封死在设备创建选项里。Windows 上同理落到 D3D11 设备，且 oneVPL 默认 D3D11（hwcontext_qsv.c:2527-2532）。

**MediaCodec 双输出模式的硬件现实**：Android 解码输出直接进 SurfaceFlinger 的 buffer 队列，Surface 模式下 CPU **根本拿不到像素**——只有 buffer index 与 release/render 语义。这决定了 FFmpeg 的帧只能是"令牌"：`data[3]` 放 `AVMediaCodecBuffer`，AD_HOC config 方法，渲染时机交给上层（3.1 节）。Buffer 模式则是兼容层：覆盖 20 余种厂商 color format 的拷贝例程（mediacodecdec_common.c:191-218）本身说明该模式"每台设备都可能不一样"，也解释了为何 Surface 模式是首选、Buffer 是回读与降级通道。

**D3D12 为什么是 command queue 而非直接提交**：D3D12 移除了驱动隐式同步与状态管理。解码必须录进 `ID3D12VideoDecodeCommandList`、经 `VIDEO_DECODE` 型队列执行；资源状态迁移（COMMON↔VIDEO_DECODE_WRITE/READ）要显式 barrier（d3d12va_decode.c:618-672）；allocator 用完必须等 GPU 才能重置（4.2 节对象池）。回报是：跨队列 GPU 端等待（hwcontext_d3d12va.c:558）替代 CPU 阻塞、帧级 fence 把同步推迟到真正需要结果的时刻、解码与拷贝两条队列并行。dxva2/d3d11va 时代"一个 Lock 函数全解决"的语义，在 D3D12 里被拆成了显式的四步（录制-barrier-提交-signal）。

**AMF 为何长期只有编码、又为何是事件驱动**：历史上 AMD 开放的是 VCE/UVD 编码路径，AMF runtime 早期围绕编码器属性面板构建；解码接入（含 FFmpeg 侧）是近年随驱动补齐的。其组件模型用属性串（而非结构体字段）配置、用 SubmitInput/QueryOutput/Drain 三原语驱动，天然贴合"多 GPU 队列、驱动内部调度"的现实——FFmpeg 侧只用 usleep 轮询适配（5.2 节），等价于把 mfx 的 MFX_WRN_DEVICE_BUSY 循环（qsvdec.c:822-824）和 MediaCodec 的 dequeue 超时（mediacodecdec_common.c:86-88）换了个名字。

## 8. FAQ 素材

1. **QSV 解码器为什么叫 h264_qsv 而不是 h264+hwaccel？** 它是 wrapper 解码器，码流交给 SDK 自己的解析器（`MFXVideoDECODE_DecodeHeader`，qsvdec.c:462），`.hwaccel = NULL`（qsvdec.c:126），因此 12 章的 `hwaccel_init` 不参与。
2. **Linux 上没装 iHD 驱动 QSV 能用吗？** 不能走硬件路径：设备创建固定 `driver=iHD, vendor_id=0x8086`（qsv.c:471-472），且宏仅在 CONFIG_VAAPI 时启用（qsv_internal.h:26-28）。
3. **opaque 模式还能用吗？** 仅旧 MediaSDK：`QSV_HAVE_OPAQUE = !QSV_ONEVPL`（qsv_internal.h:67-68），oneVPL 下 iopattern 只剩 video/system memory（qsv.c:94-96 也被条件编译掉）。
4. **QSV 帧输出为什么延迟低还不同步？** 同步点挂在 `async_fifo`（深度=async_depth），输出 QSV 帧时跳过 `SyncOperation`（qsvdec.c:883-887），同步成本转嫁给最终 transfer/map。
5. **MediaCodec 解码出的 AVFrame 里为什么没有数据？** Surface 模式帧只是 buffer 令牌（mediacodecdec_common.c:352），上屏需调 `av_mediacodec_render_buffer`（mediacodec.c:88-102）；不渲染直接 release 即丢弃。
6. **MediaCodec 有异步模式吗？** wrapper 预留了 `setAsyncNotifyCallback`（wrapper.h:367），但树内无调用者；解码始终同步轮询（8ms 超时，mediacodecdec_common.c:86-87）。
7. **D3D12VA 为什么要求 Tier 2？** Tier 1 的分块/加密流解码路径未实现，探测失败直接 `AVERROR_PATCHWELCOME`（d3d12va_decode.c:353-357）。
8. **AMF 到底能不能解码？** 能：h264/hevc/vp9/av1 四个 `_amf` 解码器在树中（amfdec.c:840-843，Makefile:825），configure 帮助文本"仅编码"是陈旧描述（configure:351）。
9. **AMF 的 hwframes 池为什么分配出 NULL？** 池是满足框架校验的占位（hwcontext_amf.c:102-109），真表面由 SDK 内部池管理、输出时以引用计数包裹（amfdec.c:530-536）。
10. **QSV/AMF 都说"从 D3D11 设备派生"，一样吗？** QSV 是把句柄 SetHandle 进 mfx session（hwcontext_qsv.c:2458）；AMF 是 `context->InitDX11(device)`（hwcontext_amf.c:791）——前者共享显示连接，后者把 D3D11 设备注入 AMF context。

## 9. 深挖方向

1. **QSV 动态池与 DPB 的博弈**：oneVPL 2.9+ 且非 D3D9 时 `initial_pool_size=0`（qsvdec.c:344-347），表面按需借还（hwcontext_qsv.c:426-510）——对比固定池 `suggest_pool_size + 16 + extra_hw_frames` 的行为差异与 VPP 上下行在动态池下的退化路径（`qsv_transfer_data_child`，hwcontext_qsv.c:1690-1722）。
2. **D3D12VA reference-only 槽位泄漏修复**：`get_reference_only_resource` 先按 `output_resource` 匹配旧槽（d3d12va_decode.c:64-74 注释明说否则池耗尽）——可沿 `used_mask`（ff_d3d12va_get_surface_index，156-191）梳理参考帧状态机的完整闭环。
3. **MediaCodec serial/delay_flush 协议**：`serial` 递增使旧 buffer 释放失效、flush 延期到 `hw_buffer_count==0`（mediacodecdec_common.c:278-294, 1105-1133）——对比 Android NDK 官方 reclaim 语义。
4. **mfx 内部 session 的 allocator 注入**：`ff_qsv_init_session_frames` 把 `qsv_frame_alloc/lock/get_hdl` 挂进 SDK（qsv.c:1109-1157），lock 时用 `av_hwframe_map(DIRECT)` 现场映射系统内存（qsv.c:927-991）——SDK 外部分配器的完整范例。
5. **AMF↔D3D12 派生与 Vulkan 回退**：`amf_init_from_d3d12_device`（hwcontext_amf.c:805-824）与 DX11→DX9→Vulkan 三级回退（hwcontext_amf.c:612-643）——Linux 上 AMF 仅 Vulkan 一条路对 ff_amfenc_hw_configs（amfenc.c:714-726）无 VAAPI 项的影响。

## 写作要点速查表

| 关键事实 | 位置 |
|---|---|
| QSV wrapper 配置（hwaccel=NULL） | qsvdec.c:118-129 |
| QSV Linux 宏条件（CONFIG_VAAPI && !_WIN32） | qsv_internal.h:26-28 |
| mfx→VAAPI 网关：iHD + SetHandle(VA_DISPLAY) | qsv.c:464-492（471-472, 483-484） |
| 从设备派生子 session + MFXJoinSession | qsv.c:1057-1106（Join 在 1092-1097） |
| QSV 解码异步循环 + async_fifo 出队 | qsvdec.c:813-880（busy 循环 820-825） |
| QSV 帧输出跳过同步的条件 | qsvdec.c:883-887 |
| QSV 设备创建：oneVPL 默认 D3D11 / VAAPI 子设备选项 | hwcontext_qsv.c:2499-2619（2527-2532, 2572-2573） |
| QSV↔VAAPI surface 拆包 map/derive | hwcontext_qsv.c:1511-1532, 1587-1688 |
| MediaCodec AD_HOC 配置 + wrapper 声明 | mediacodecdec.c:583-594, 616-634 |
| Surface 决定输出模式（configure） | mediacodecdec_common.c:854（surface 来源 758-772） |
| Surface 令牌包装 / 释放 / 渲染 API | mediacodecdec_common.c:296-369（352）, 278-294; mediacodec.c:88-118 |
| Buffer 模式厂商拷贝分发 | mediacodecdec_common.c:488-509（格式表 191-218） |
| MediaCodec hwcontext 无 frames 方法 | hwcontext_mediacodec.c:107-121 |
| D3D12VA 真 hwaccel + VIDEO_DECODE 队列 | d3d12va_h264.c:200-214; d3d12va_decode.c:412-417, 467-476 |
| Tier2 探测 / decoder+heap 创建 | d3d12va_decode.c:347-357, 371-383; heap 297-327 |
| 每帧提交：barrier→DecodeFrame→双 Signal | d3d12va_decode.c:558-692（667-680） |
| 辅助对象 fence 校验复用 / 每帧 fence 消费点等待 | d3d12va_decode.c:193-261（214-221）, 644, 263-274 |
| D3D12VA COPY 队列 + GPU 跨队列 Wait | hwcontext_d3d12va.c:142-146, 558-562 |
| AMF 解码器在树（勘误"仅编码"） | amfdec.c:840-843; Makefile:825; configure:351（陈旧）, 3635 |
| AMF 组件循环 SubmitInput/QueryOutput/Drain | amfdec.c:707-733, 580-612, 723-729 |
| AMF dummy 池 + SDK 内部池参数 | hwcontext_amf.c:102-109, 370-381; amfdec.c:175-188 |

使用说明：速查表行号基于 commit `9f63b36a`；引用 QSV 动态池、opaque 废弃等结论前，建议先核对 `qsv_internal.h:67-68` 的 `QSV_ONEVPL/QSV_HAVE_OPAQUE` 与所链 SDK 头文件版本，二者随构建环境浮动。
