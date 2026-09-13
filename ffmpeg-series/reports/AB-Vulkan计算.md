# AB 章 Vulkan 硬件上下文与 GPU 计算滤镜

> 源码版本:FFmpeg master,commit 9f63b36a。所有行号均以该快照为准,用 grep -n / Read 实际核对。
> 本章讲"GPU 计算"这条平行管线:libavutil/hwcontext_vulkan.c(硬件上下文)+ libavutil/vulkan.c(compute 基础设施)+ libavfilter/*_vulkan.c(shader 滤镜族)。不深入 shader 数学;21 章 ffplay_renderer.c 的 libplacebo 渲染路径只在第 6 节做分工边界对照。

---

## 1. 全景:两条平行管线

第 19 章的 CPU 滤镜链每经过一个滤镜,帧数据要么原地改写、要么 memcpy 一份新 buffer;而 Vulkan 滤镜链要求帧从进链到出链全程驻留 GPU 显存,帧本体是一个 `VkImage` 集合(`AVVkFrame`),CPU 侧只见指针与同步原语。

```
【CPU 滤镜管线(19 章)】
  decode → AVFrame(data 指向系统内存)
             │  av_hwframe_transfer_data(hwf→swf)  ← 下载
             ▼
  [scale] ── [overlay/framesync] ── [transpose]      ← 每步都是 CPU 读写内存
             │
             ▼  av_hwframe_transfer_data(swf→hwf)   ← 上传
  encode

【Vulkan 计算管线(本章)】
  decode(VK decode queue / 导入) → AVFrame(AV_PIX_FMT_VULKAN, data[0]=AVVkFrame)
             │  AVVkFrame{ img[i], mem[i], sem[i], layout[i], sem_value[i] }
             ▼                                            (hwcontext_vulkan.h:290-320)
  [scale_vulkan] ── [overlay_vulkan] ── [transpose_vulkan]  ← 每步一个 CmdDispatch,
             │   compute queue 上排队                          GPU 显存零下载
             ▼
  encode / 显示(仍是同一批 VkImage)

  只有两种情况数据才回 CPU:
  a) 链尾是 CPU 滤镜/输出 → vulkan_transfer_data_from(hwcontext_vulkan.c:5180)
  b) 中途插入 CPU 滤镜    → 同上,经 vulkan_transfer_frame(hwcontext_vulkan.c:4881)
```

关键结构契约:Vulkan 滤镜统一只接受/输出 `AV_PIX_FMT_VULKAN` 单一像素格式(vf_scale_vulkan.c:436、vf_transpose_vulkan.c:228 `FILTER_SINGLE_PIXFMT(AV_PIX_FMT_VULKAN)`),硬件感知靠 `.flags_internal = FF_FILTER_FLAG_HWFRAME_AWARE`(vf_scale_vulkan.c:437),设备靠 `.p.flags = AVFILTER_FLAG_HWDEVICE`。这与 12 章的 VAAPI/NVDEC 后端共享同一套 hwframes 机制,但滤镜内部走的是完全不同的执行模型。

---

## 2. hwcontext_vulkan 专节(约 5264 行)

### 2.1 设备创建与 queue family 三分离

Vulkan 的设备级并行单位是 queue family。FFmpeg 在创建逻辑设备时,按"能力最少者胜出"的原则为 graphics/compute/transfer 各挑一个 family:

- `pick_queue_family()`(libavutil/hwcontext_vulkan.c:1574-1601)对所有 family 打分:`score = av_popcount(qflags) + timestampValidBits`(行 1589),分数越低说明该 family 越"专一",并用 timestampValidBits 当使用计数(行 1598)实现负载均衡。
- `setup_queue_families()`(行 1632-1802)依次执行 `PICK_QF(VK_QUEUE_GRAPHICS_BIT) / PICK_QF(VK_QUEUE_COMPUTE_BIT) / PICK_QF(VK_QUEUE_TRANSFER_BIT)`(行 1735-1737),再为视频编解码、光流各挑专用 family(行 1739-1755)。若 GPU 的 compute family 天生带 graphics 位(桌面 GPU 常态),三组会落到同一 family——机制上是"按需分离",不是强制。
- NVIDIA 私有驱动被特殊照顾:`limit_queues` 默认把每个 family 收窄到 1 个队列(行 1720-1728,`VK_DRIVER_ID_NVIDIA_PROPRIETARY`)。
- 真正的 CreateDevice 在 `vulkan_device_create_internal()`(行 1847-1952):create_instance(1865)→ find_device(1869)→ check_extensions(1876)→ features 拷贝(1884-1892)→ setup_queue_families(1900)→ `vk->CreateDevice`(1904)。

为什么 scale 要 compute 队列?滤镜初始化时用 `ff_vk_qf_find(&s->vkctx, VK_QUEUE_COMPUTE_BIT, 0)` 显式找 compute family(libavfilter/vf_scale_vulkan.c:265;vf_overlay_vulkan.c:62;vf_transpose_vulkan.c:51),找不到直接 `AVERROR(ENOTSUP)`("Device has no compute queues")。dispatch 无法提交到 graphics-only family,因此纯 compute 队列是滤镜族的硬需求。帧池内部的布局准备/上传/下载又分别建了三个 exec pool,compute pool 用 `p->compute_qf`,upload/download pool 用 `p->transfer_qf`(hwcontext_vulkan.c:3285-3298;两个指针在 vulkan_device_init 中赋值,行 2130-2131)——下载走 transfer 队列、计算走 compute 队列,两类工作互不阻塞。

### 2.2 外部内存与帧池(对照 12 章 surface 池)

12 章讲过 VAAPI 的 surface 池:解码器从固定大小的 surface 池里取 buffer。Vulkan 侧是同一个思想,但多了一层"外部内存导出",让同一块显存能被别的 API(DRM/VAAPI/CUDA)看见:

- 内存类型选择:`alloc_mem()`(hwcontext_vulkan.c:2316-2372)遍历 memoryType 找第一个同时满足 requirement bitmask 和属性 flags 的类型(行 2333-2351)——Vulkan 规范保证类型按"最优"顺序排列,第一个命中即最快。
- 每帧结构:`create_frame()`(行 2720-2827)为每个平面 `CreateImage`(行 2793),同时为每个 image 配一个 timeline semaphore(行 2734-2742 创建、2803 挂到 `f->sem[i]`),并探测可导出性后把 export 属性挂进 sem 的 pNext(行 2744-2759)。`AVVkFrame` 公开字段 access/layout/sem/sem_value/queue_family 见 libavutil/hwcontext_vulkan.h:290-320,这是跨 API 同步的协议载体。
- 导出探测:`try_export_flags()`(行 2830-2900)用 `GetPhysicalDeviceImageFormatProperties2` 试探 opaque fd / dmabuf / win32 句柄是否可导出(行 2883-2892)。
- 池子:`vulkan_pool_alloc()`(行 2902-2979)是 `av_buffer_pool_init2` 的回调(vulkan_frames_init 行 3367-3373 挂池):按平台选 handle 类型——Win32 用 OPAQUE_WIN32(_KMT),非 Win32 用 OPAQUE_FD,DRM modifier tiling 用 DMA_BUF(行 2919-2934);然后 create_frame + `alloc_bind_mem`(带 `VkExportMemoryAllocateInfo`,行 2936-2950),最后按用途选 PREP_MODE 把新帧转进初始 layout(行 2954-2964)。

### 2.3 map 的两种路径与 transfer 的三条路

**零拷贝 import(不拷数据)**:`vulkan_map_from()`(行 4596-4620)把 Vulkan 帧映射为 DRM_PRIME(行 4603)或 VAAPI(行 4609),反向 `vulkan_map_to()`(行 4276-4299)则把 DRM/VAAPI 帧导入为 VkImage。核心在 `vulkan_map_from_drm_frame_desc()`(行 3459 起):用 `VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT`(行 3512-3516)创建"外部内存镜像",再 `vkBindImageMemory2` 把 DMA-BUF 绑到 VkImage 上——数据从未移动,只是换了一层视图。这与 12 章"hwmap 零拷贝"是同一套哲学的 Vulkan 实现。

**拷贝 transfer(CPU 数据进出)**:`vulkan_transfer_frame()`(行 4881-5057)有两条路:
1. **host copy 捷径**:`hwctx->usage & VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT` 时走 `vulkan_transfer_host()`(行 4937-4938 → 4760-4879)——这是无 command buffer 的主机路径,`CopyMemoryToImageEXT/CopyImageToImageEXT` 直接从主机指针拷(行 4846/4872),配合 host 侧 layout 转换(行 4818-4820)。该 usage 位在 `vulkan_frames_init()` 中按 `FF_VK_EXT_HOST_IMAGE_COPY` 扩展自动补上(行 3226-3228),不可用则回落(行 3275-3277)。
2. **staging buffer 经典路**:先尝试把 CPU 帧的 AVBufferRef 直接 import 成 VkBuffer(`host_map_frame()`,行 4703-4758,单 buffer 覆盖全部平面时零拷贝映射,行 4725-4735;NVIDIA 驱动默认关掉此路径 `avoid_host_import`,行 1935);失败则从池里取 HOST_VISIBLE 暂存 buffer 并 memcpy(`get_plane_buf`/`copy_buffer_data`,行 4664-4701、4622-4662)。随后录 command buffer:`CmdCopyBufferToImage`/`CmdCopyImageToBuffer`(行 5032/5037),upload 提交后立即返回,download 则 `ff_vk_exec_wait` 同步等完再回拷(行 5045-5050)——下载是同步的,上传是异步的。

CUDA 互操作是第三条路:`vulkan_transfer_data_to/from_cuda`(行 5086-5177、4182 起)通过外部内存+外部 semaphore 在两套驱动上下文间直接共享(平台差异:Win32 用 OPAQUE_WIN32 句柄,POSIX 用 fd,行 5068-5075)。

**平台相关说明**:当前 master 的 hwcontext_vulkan.c 里已没有 Wayland/X11 WSI surface 代码(grep 验证:无 wayland/x11 匹配);"平台相关"体现为外部内存句柄类型(行 2919-2934 的 Win32/POSIX 分支)与 VulkanVideo/DRM modifier 扩展,显示侧(WSI swapchain)不在 hwcontext 职责范围内,由调用方(如 21 章的播放器渲染层)负责。

---

## 3. 基础设施专节:libavutil/vulkan.c(约 2899 行)

### 3.1 三层抽象:ExecPool / Shader / ImageView

`FFVulkanContext`(libavutil/vulkan.h:294-354)是所有 Vulkan 滤镜私有限上下文的第一个成员(vf_scale_vulkan.c:58 `FFVulkanContext vkctx`),内含函数表 vkfn、扩展掩码、设备/帧上下文引用和输入输出格式协商结果。

**ExecPool = command buffer + 队列 + timeline 信号灯的打包**。`ff_vk_exec_pool_init()`(vulkan.c:395-592)为每个 context 建一个 command pool/buffer(行 432-465)和一个 timeline semaphore(行 544-555);每个 context 绑定到 family 内的具体 queue,用 `phase` 相位错开不同 pool 的起始下标,视频编解码 pool 固定钉住相位队列,其余轮转(行 532-573)。`FF_VK_DEFAULT_EXEC_CONTEXTS = 4`(vulkan.h:121)——即同一滤镜最多 4 个在途 submission,天然支持 4 级流水。取 context 用轮转原子计数 `ff_vk_exec_get()`(vulkan.c:622-643)。

**Shader = 描述符布局 + push constant + pipeline/shader object**。`FFVulkanShader`(vulkan.h:210-250)持有 `desc_set[4]`、`push_consts[4]`、`lg_size[3]`(workgroup 尺寸)与最终的 `pipeline` 或 `VkShaderEXT object`。

### 3.2 编译期开关与 shader 交付方式

本快照的 shader 已全部改为**构建期编译的独立 .glsl 文件**,不再以 C 字符串内嵌:

- GLSL 源码位于 `libavfilter/vulkan/*.comp.glsl`(22 个 compute shader;目录经 libavfilter/Makefile:28 `include $(SRC_PATH)/libavfilter/vulkan/Makefile` 纳入构建)。
- 编译器探测在 configure:`probe_glslc()`(configure:7817-7846)优先 glslang/glslangValidator(`-V --target-env spirv1.6`,行 7822),否则 Google glslc(`--target-env=vulkan1.4 --target-spv=spv1.6`,行 7831);实际调用循环在行 7859。配置项 `--glslc`/`--glslcflags` 见 configure:406、432。
- Make 规则(ffbuild/common.mak:125-136):`%.spv: %.glsl` → (可选 gzip)→ `bin2c` 生成 `%.spv.c`,最终链接成 `vulkan/scale.comp.spv.o` 这类目标(libavfilter/vulkan/Makefile:11-12);滤镜 .c 里以 extern 符号引用产物(vf_scale_vulkan.c:29-33 `ff_scale_comp_spv_data/ff_scale_comp_spv_len`)。
- **压缩开关**:`--disable-shader-compression`(configure:539),默认随 zlib 开启(configure:4496 `enable shader_compression`,依赖 zlib+gzip,行 7291)。C 侧对应 `CONFIG_SHADER_COMPRESSION`:`ff_vk_shader_link()` 里 zlib 解压后再建 shader(vulkan.c:2494-2502)。

### 3.3 pipeline/descriptor 封装与参数传递

`ff_vk_shader_load()`(vulkan.c:2255-2287)只是"登记":记录 stage、specialization、workgroup 尺寸并选 bind point(行 2278-2279 compute)。真正的构建在 `ff_vk_shader_link()`(行 2459-2563):

1. 若 precompiled,自动把 workgroup 尺寸以 specialization constant ID **253/254/255** 追加进 spec info(行 2480-2492)——这正对应每个 .comp.glsl 里的 `layout (local_size_x_id = 253, ...) in;`(libavfilter/vulkan/scale.comp.glsl:28),让 C 侧 `(uint32_t[]){32,32,1}` 能在编译期决定 workgroup。
2. `init_descriptors()`(行 2417-2457):如果设备支持 push descriptor 且绑定数不超标,布局打上 `VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR`(行 2429-2442),一次 cmd 内直接推描述符,省掉 set 分配。
3. 两条执行路径(行 2513-2539):优先 `VK_EXT_shader_object`(`create_shader_object()`,行 2376-2415,免 pipeline 编译),否则经典 `VkShaderModule + VkComputePipeline`(`init_compute_pipeline()`,行 2341-2374)。

**帧间变化的参数走 push constant**:`ff_vk_shader_add_push_const()`(声明在 vulkan.h:702)登记区间,每帧用 `ff_vk_shader_update_push_const()` → `vk->CmdPushConstants`(vulkan.c:2773-2781)灌进 command buffer。scale 的整个参数块(yuv 矩阵+裁剪框+输入尺寸,一个 C struct)一次灌入(vf_scale_vulkan.c:148-149,279)。

**描述符更新**:图像数组用 `ff_vk_shader_update_img_array()`(vulkan.c:2734 起)→ `update_set_pool_write()`(行 2682-2707):singular set 广播到所有 context,push descriptor 走 `CmdPushDescriptorSetKHR`(行 2696-2701),否则 `UpdateDescriptorSets` 定点写(行 2703-2704)。

### 3.4 一帧的执行契约

`ff_vk_exec_start()`(vulkan.c:660-710)先 WaitSemaphores 等上一个用完这个 context 的 submission(行 680),然后 Begin + 把 context 的 sem_value 自增并登记为 signal(行 699-705)——timeline 信号灯就是 context 的互斥锁。`ff_vk_exec_submit()`(行 983-1056)`QueueSubmit2`(行 1014)后立即解锁所有 frame dep 并按记录更新 `vkf->layout/access/queue_family`(行 1032-1051),所以**滤镜内不需要显式 wait**:下一级滤镜会通过帧上的 sem_value 与本 exec 的依赖链自然同步;只有拿回 CPU(transfer download)或销毁帧(vulkan_frame_free 中 `WaitSemaphores`,hwcontext_vulkan.c:2429-2439)才真正阻塞。

---

## 4. 滤镜族专节

### 4.1 scale_vulkan:submit→wait 全流程

文件 libavfilter/vf_scale_vulkan.c(438 行),带一个意外特性:输入 `AV_PIX_FMT_BAYER_RGGB16` 时切换成 debayer 滤镜(行 272-275),以及在"只改尺寸不改格式或反之"的退化场景直接回落 swscale CPU 实现(行 339-346 建 sws,行 280-283 执行)。

GPU 路径一帧的生命周期(`scale_vulkan_filter_frame`,行 231-294):

```c
// libavfilter/vf_scale_vulkan.c:278-279
RET(ff_vk_filter_process_simple(&s->vkctx, &s->e, &s->shd, out, in,
                                s->sampler, 1, &s->opts, sizeof(s->opts)));
```

`ff_vk_filter_process_simple()`(libavfilter/vulkan_filter.c:242-316)展开为七步:

1. `ff_vk_exec_get` 轮转拿一个 exec context(行 258);
2. `ff_vk_exec_start`(行 259)——等 context 空闲、Begin command buffer;
3. 对输出/输入帧 `ff_vk_exec_add_dep_frame` 建依赖(行 263、271)——帧被"锁"到本次执行,防止框架提前复用;
4. `ff_vk_create_imageviews`(行 266、274)+ `ff_vk_shader_update_img_array`(行 267、275)把帧的每个平面绑成描述符;
5. `ff_vk_exec_bind_shader` + push constant 灌参(行 281-284);
6. `ff_vk_frame_barrier` 生成 layout 迁移屏障后 `CmdPipelineBarrier2`(行 287-305);
7. `CmdDispatch` 按 `FFALIGN(w,lg)/lg` 计算组数(行 307-310)→ `ff_vk_exec_submit`(行 312)。

"wait"发生在两处:同一 context 复用时(`exec_start` 行 680)或 download 回 CPU 时(hwcontext_vulkan.c:5046-5050)。滤镜循环本身异步推进——这是与 CPU 滤镜"处理完才返回"最大的语义差别。

首次调用时懒初始化(`init_filter`,行 86-183):建 exec pool(118)→ 建 sampler(120,双线性/最近邻对应 VK_FILTER_LINEAR/NEAREST,行 98-105)→ 用 `SPEC_LIST_CREATE/ADD` 宏装 specialization(vulkan.h:44-71;vf_scale_vulkan.c:122-125:nb_planes/mode/fullrange 三个常量,与 scale.comp.glsl:35-37 的 constant_id 0/1/2 一一对应)→ 声明描述符集 input_img(sampler 数组)+ output_img(storage 数组,行 130-146)→ push constant(148)→ 需要格式转换时在 CPU 侧算好 RGB→YUV 矩阵塞进 opts(行 151-168,`ff_fill_rgb2yuv_table`)→ `ff_vk_shader_link` 挂 SPIR-V(173-175)→ `ff_vk_shader_register_exec`(177)。

### 4.2 overlay_vulkan:双输入与 framesync 复用

vf_overlay_vulkan.c(270 行)证明 Vulkan 滤镜**不必重造帧同步**:它直接复用 19 章 CPU overlay 同款的 FFFrameSync 机制——`ff_framesync_init_dualinput`(行 189)+ `ff_framesync_activate`(行 196-201)+ `on_event` 回调(行 207),时间轴对齐逻辑与 CPU 版完全同源(framesync.c 一套代码两个世界共用)。

区别在融合动作本身:回调 `overlay_vulkan_blend()`(行 126-177)拿到 main/overlay 两帧后,调三输入版通用函数:

```c
// libavfilter/vf_overlay_vulkan.c:164-166
RET(ff_vk_filter_process_Nin(&s->vkctx, &s->e, &s->shd,
                             out, (AVFrame *[]){ input_main, input_overlay }, 2,
                             VK_NULL_HANDLE, 1, &s->opts, sizeof(s->opts)));
```

`ff_vk_filter_process_Nin()`(vulkan_filter.c:413-492)支持最多 16 入 1 出(声明见 vulkan_filter.h:62),把 main/overlay/output 三组图像都声明为 `VK_DESCRIPTOR_TYPE_STORAGE_IMAGE`(vf_overlay_vulkan.c:81-98)——overlay 不做纹理采样,直接 imageLoad/imageStore 读像素,因此连 sampler 都传 `VK_NULL_HANDLE`。alpha 混合逻辑在 libavfilter/vulkan/overlay.comp.glsl 里。CPU overlay(19 章)的逐行 memcpy+alpha 插值在这里变成一次 dispatch。

### 4.3 最简样本:transpose_vulkan / flip

vf_transpose_vulkan.c(230 行)是"写一个 Vulkan 滤镜"的最小完整模板,五个固定步骤:

1. 私有上下文第一个成员 `FFVulkanContext vkctx`(行 33);
2. 懒初始化 `init_filter`(行 44-90):`ff_vk_qf_find(COMPUTE)`(51)→ `exec_pool_init`(58)→ `ff_vk_shader_load` 传 workgroup `{32,1,planes}`——z 维直接当平面索引用(60-61)→ 两个 storage image 描述符(66-78)→ push constant 只有一个 int 即 `dir`(63-64,80-82 链接 SPIR-V)→ `register_exec`(84);
3. `filter_frame`(92-132):passthrough 直通(100-101)→ `ff_get_video_buffer`(103,从 2.2 节的帧池取)→ `process_simple`(112-113,push 源就是 `&s->dir`)→ `av_frame_copy_props`(115)→ 交换 SAR(117-122);
4. `config_props_output`(147-177):横竖对调 output 尺寸(167-168),landscape/portrait passthrough 直接透传输入 hw_frames_ctx(156-165);
5. 滤镜定义(218-230):`FILTER_SINGLE_PIXFMT(AV_PIX_FMT_VULKAN)` + `FF_FILTER_FLAG_HWFRAME_AWARE`。

对应 shader flip.comp.glsl(59 行,flip 与 transpose 共用一套 vf_flip_vulkan.c)只有 main 函数一个 switch(行 49-54),非均匀平面索引用 `nonuniformEXT(gl_LocalInvocationID.z)`(行 44)——workgroup z 维遍历平面,是这套滤镜族的惯用 idiom。基类还提供 2-pass 版 `ff_vk_filter_process_2pass`(vulkan_filter.c:318-411,中间 tmp 帧、单次 submit 双 dispatch),gblur_vulkan 用它做水平+垂直高斯(vf_gblur_vulkan.c:238);函数选型:单入单出 simple、多入 Nin、两阶段 2pass(vulkan_filter.h:45-66)。

### 4.4 libplacebo:外包给专业渲染库

vf_libplacebo.c(1813 行)不走 FFmpeg 自家 shader 栈,而是把 hwcontext 的设备**整包 import 进 libplacebo**:`init_vulkan()`(行 673-753)从 `AVVulkanDeviceContext` 抽出 instance/device/extensions,把 `hwctx->qf[]` 按 flags 分拣进 `queue_graphics/compute/transfer`(行 698-706),`pl_vulkan_import`(行 709);没有外部设备时才 `pl_vulkan_create` 自建(行 712-714)。帧处理是 `pl_map_avframe_ex` → `pl_render_image[_mix]` → `pl_unmap_avframe`(行 1015、1062、1083)。这与 21 章 ffplay_renderer.c 的 libplacebo 链路是同一库的两类消费者:ffplay 用它做最终显示渲染,vf_libplacebo 把它做成可编排的滤镜(色调映射/锐化/自定义 hook,`--shader` 加载 MPV 风格用户 shader,行 728-734)。分工边界:FFmpeg 自带 Vulkan 滤镜族管"格式转换/几何/去噪"这类管线内计算;libplacebo 管"画质增强与显示映射"这条专家链。

---

## 5. 对比表:CPU 滤镜 vs Vulkan 计算滤镜

| 维度 | CPU 滤镜(19 章) | Vulkan 滤镜(本章) |
|---|---|---|
| 开发一个新滤镜 | 写一个 C 函数 + filter_frame,几十行 | .comp.glsl + ~230 行 C 骨架(transpose),需懂 descriptor/barrier/queue 模型 |
| 像素格式 | 任意 sw format | 单一 AV_PIX_FMT_VULKAN(vf_transpose_vulkan.c:228),格式由 hwfc->sw_format 决定 |
| 数据驻留 | 每帧进出系统内存 | 全程 VkImage;仅 transfer download 时回 CPU(hwcontext_vulkan.c:5180) |
| 帧同步 | filter_frame 返回即完成 | submit 异步;timeline sem + frame dep 延迟同步(vulkan.c:983-1056) |
| 多线程并行 | 框架级 slice/thread 模型 | exec pool 4 context 轮转(vulkan.h:121),context 级流水 |
| 输入适配 | 直接接 sw 帧 | 必须 hw_frames_ctx(vulkan_filter.c:183-191 强制) |
| 帧时间轴同步 | 逐帧推进 | overlay 等直接复用 framesync(vf_overlay_vulkan.c:189-201) |
| 参数传递 | AVOption 运行时读 | AVOption → push constant(每帧)/ specialization constant(每管线) |
| 退化路径 | 无 | scale 可回落 swscale(vf_scale_vulkan.c:280-283) |
| 框架兼容 | 原生 | 完全兼容:仍是 FFFilter/hwframe_aware 滤镜,可与 CPU 滤镜混插(自动插 transfer) |

---

## 6. 设计动机

**为什么 Vulkan 后进、却先行兼容 avfilter 框架**。Vulkan 滤镜族出现远晚于 VAAPI/CUDA,但它没有另起炉灶:所有滤镜都注册为普通 `FFFilter`,输入输出协商走标准 config_props(vulkan_filter.c:176-231),帧来自标准 hwframe 池,时间轴同步直接复用 framesync。收益是:`scale_vulkan`、`overlay_vulkan` 能与 CPU 滤镜自由混排,插入点由框架自动补 transfer;代价是每个滤镜要遵守 `FF_FILTER_FLAG_HWFRAME_AWARE` 契约(帧指针是 AVVkFrame、布局状态在帧上)。这是"新管线嫁接老框架"的教科书做法。

**shader 内嵌 → 独立 .glsl 的取舍**。早期版本把 GLSL 作为 C 字符串内嵌并运行时编译(需链接 glslang);本快照改为构建期 glslc/glslangValidator 编译成 SPIR-V,再经 bin2c 变成只读数组(ffbuild/common.mak:125-136)。好处:运行时零 GLSL 编译器依赖(分发环境不再需要 glslang 库)、shader 与 C 代码解耦可单独审阅;代价:构建机需要 glslc(configure:7817-7859 探测)、二进制体积(可用 shader_compression 的 gzip 缓解,configure:539)。specialization constant 253/254/255 作为 C 与 GLSL 之间的"workgroup 协议"(vulkan.c:2480-2492 ↔ scale.comp.glsl:28)是这个体系的粘合剂。

**queue 分离的硬件现实**。移动/集成 GPU 上 transfer 与 compute 往往是不同 family:compute 队列不支持某些拷贝优化,graphics 队列可能被合成器/显示占用。FFmpeg 不假设任何布局,而是运行时打分挑选(hvcontext pick_queue_family,hwcontext_vulkan.c:1588-1593)——宁可用 popcount 最小的"专才"family,并把 timestampValidBits 当作轮转计数。scale 坚持要 compute 队列(vf_scale_vulkan.c:265-270)而非蹭 graphics,保证在 graphics 饱和时滤镜链仍能推进。

**libplacebo 的分工边界**。FFmpeg 自家 shader 栈刻意保持"薄":只封装 pipeline/descriptor/exec,不做色彩科学。色调映射、HDR、去带这类需要持续跟进学术与规范的工作整体外包给 libplacebo,vf_libplacebo 用 `pl_vulkan_import` 复用同一个设备(vf_libplacebo.c:698-709),两边共享 queue family 分拣结果。用户视角:管线内变换用 *_vulkan 滤镜,画质链用 libplacebo 滤镜,21 章播放器则用 libplacebo 直渲。

---

## 7. FAQ 素材

1. **scale_vulkan 为什么会报 "Device has no compute queues"?** 滤镜用 `ff_vk_qf_find(VK_QUEUE_COMPUTE_BIT)` 找 compute family(vf_scale_vulkan.c:265),设备所有 family 都无 compute 位时返回 ENOTSUP。极少数 graphics-only 设备(如某些远古驱动/软件光栅)会命中。
2. **Vulkan 滤镜输出是异步的,框架不会读到写了一半的帧吗?** 不会。`ff_vk_exec_submit` 只解锁帧不等待(vulkan.c:1032-1051),但帧上 timeline semaphore 的 sem_value 已推进;下一级消费者提交命令前会 wait 该值,download 回 CPU 时则显式 `ff_vk_exec_wait`(hwcontext_vulkan.c:5046-5047)。
3. **上传一帧到 Vulkan 一定要拷贝吗?** 不一定。支持 `VK_EXT_external_memory_host` 时 CPU 帧 buffer 被 import 成 VkBuffer 零拷贝(host_map_frame,hwcontext_vulkan.c:4725-4735);支持 host image copy 时连 staging buffer 都省了,直接 CopyMemoryToImageEXT(行 4846)。NVIDIA 默认禁用 host import(avoid_host_import,行 1935)。
4. **VAAPI 解码的帧能直接喂 scale_vulkan 吗?** 可以:hwmap 零拷贝导入。`vulkan_map_to` 把 VAAPI/DRM_PRIME 帧的 DMA-BUF 绑成 VkImage(hwcontext_vulkan.c:4284-4294,3459 起),前提是 modifier/句柄兼容,否则框架退回 transfer 拷贝。
5. **每帧参数(裁剪、坐标)怎么传给 shader?** push constant:结构体一次 `CmdPushConstants`(vulkan.c:2773-2781),如 scale 的 opts 结构(vf_scale_vulkan.c:148-149)。不随帧变的常量(平面数、算法模式)用 specialization constant 在 pipeline 创建时固化(行 122-125)。
6. **为什么 shader 里没有 #version 和入口声明?** 每个文件头 `#pragma shader_stage(compute)`(scale.comp.glsl:22)+ 构建 target 环境 spirv1.6,由 glslc 定 stage;入口固定叫 main(ff_vk_shader_link 的 entrypoint 参数)。
7. **一次 dispatch 处理多大?** workgroup 尺寸由 C 侧传 `{32,32,1}` 等决定(vf_scale_vulkan.c:128),dispatch 组数 `FFALIGN(dim,lg)/lg` 在 vulkan_filter.c:307-310 算;transpose 用 `{32,1,planes}` 让 z 维携带平面号(vf_transpose_vulkan.c:61)。
8. **overlay_vulkan 的帧同步和 CPU overlay 是一套吗?** 是。同一 FFFrameSync/framesync.c,`ff_framesync_init_dualinput` + activate(vf_overlay_vulkan.c:189-201);只有像素混合本身换成 GPU dispatch。
9. **shader 会压缩进二进制吗?** 默认开启 shader_compression(gzip,configure:4496),运行时 zlib 解压(vulkan.c:2494-2502);`--disable-shader-compression` 可关(行 539)。
10. **必须先 av_hwdevice_ctx_create(AV_HWDEVICE_TYPE_VULKAN) 吗?** 是。vulkan_filter.c:122-125 明确要求 hw_device_ctx,否则 "Vulkan filtering requires a device context";frames 上下文可由滤镜自动创建(ff_vk_filter_init_context,行 128-146)并复用上游帧池(行 37-118 的复用检查:尺寸/格式/tiling/usage/storage 能力逐项比对)。

## 深挖方向

1. **描述符三策略实测**:push descriptor(vulkan.c:2429-2432)vs 普通 pool(register_exec,2599-2671)vs descriptor buffer(FFVulkanShaderData,vulkan.h:258-270)在不同驱动上的性能差异;`update_set_pool_write`(2682-2707)的分派逻辑是入口。
2. **AVVkFrame 状态机的并发正确性**:layout/access/queue_family/sem_value 四个数组(hwcontext_vulkan.h:290-320)由 frame lock(vulkan_frames_init:3279-3283)+ exec dep(hvcontext exec_submit 解锁)双保险维护;可对照 vulkan_frame_free 的 WaitSemaphores(hwcontext_vulkan.c:2429-2439)理解生命周期。
3. **NVIDIA 特例清单**:limit_queues(hwcontext_vulkan.c:1720-1728)、avoid_host_import(1935)、CUDA 外部内存互操作(3942-4182);跨驱动兼容代码密度是 hwcontext 里最高的一段。
4. **多平面单镜像 vs 多镜像**:hwctx->format[] 决定 NV12 是 1 个 multiplane image 还是 2 个 image(vulkan_frames_init:3172-3204),`disable_multiplane` 选项影响它;对导出给 VAAPI 的兼容性有直接影响。
5. **与 VulkanVideo 的交界**:帧池 usage 会按编解码角色追加 VIDEO_* 位(vulkan_frames_init:3214-3234),pool_alloc 按 DPB/DST 选 PREP_MODE(hwcontext_vulkan.c:2954-2964)——这是 12 章解码缓冲概念在 Vulkan 侧的对应物,可做跨章串联素材。

---

## 写作要点速查表

| 主题 | 文件:行号 | 内容 |
|---|---|---|
| queue 挑选 | libavutil/hwcontext_vulkan.c:1574-1601 | pick_queue_family 按 popcount 打分 |
| 三分离 PICK_QF | libavutil/hwcontext_vulkan.c:1735-1737 | graphics/compute/transfer 各挑 family |
| CreateDevice | libavutil/hwcontext_vulkan.c:1847-1952 | vulkan_device_create_internal 全流程 |
| 帧池回调 | libavutil/hwcontext_vulkan.c:2902-2979 | vulkan_pool_alloc:导出句柄+建帧+初始布局 |
| 池挂接 | libavutil/hwcontext_vulkan.c:3367-3373 | frames_init 挂 av_buffer_pool_init2 |
| 零拷贝导入 | libavutil/hwcontext_vulkan.c:3459(3512-3516) | DRM/DMABUF → VkImage bind |
| 下载/上传 | libavutil/hwcontext_vulkan.c:4881-5057 | vulkan_transfer_frame 双路径 |
| host copy | libavutil/hwcontext_vulkan.c:4760-4879 | CopyMemoryToImageEXT 无命令缓冲路径 |
| exec pool | libavutil/vulkan.c:395-592 | timeline sem+queue 轮转(vulkan.c:573) |
| submit | libavutil/vulkan.c:983-1056 | QueueSubmit2 后解锁帧依赖 |
| shader link | libavutil/vulkan.c:2459-2563 | spec 253/254/255(2480)+ shader object(2513) |
| push const | libavutil/vulkan.c:2773-2781 | CmdPushConstants 每帧传参 |
| 通用提交 | libavfilter/vulkan_filter.c:242-316 | process_simple 七步:exec→dep→bind→barrier→dispatch→submit |
| scale 帧处理 | libavfilter/vf_scale_vulkan.c:231-294 | filter_frame,278 行处 process_simple 调用 |
| overlay framesync | libavfilter/vf_overlay_vulkan.c:189-201 | dualinput 复用 CPU 滤镜同步机制 |
| overlay 提交 | libavfilter/vf_overlay_vulkan.c:164-166 | process_Nin 双输入 |
| 最简模板 | libavfilter/vf_transpose_vulkan.c:44-132 | init_filter + filter_frame |
| shader 编译 | configure:7817-7859;ffbuild/common.mak:125-136 | glslc 探测与 .glsl→.spv→.c 规则 |
| 压缩开关 | configure:539,4496;libavutil/vulkan.c:2494-2502 | shader_compression 默认开 |
| libplacebo 导入 | libavfilter/vf_libplacebo.c:673-753 | pl_vulkan_import 复用设备与 queue 分拣 |
