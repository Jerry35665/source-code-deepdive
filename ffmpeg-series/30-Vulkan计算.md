# 第 30 章 · Vulkan 计算:GPU 平行管线与 avfilter 框架的兼容(卷末)

> 基线:commit `9f63b36a`。行号以 libavutil/hwcontext_vulkan.c、libavutil/vulkan.c、libavfilter/vulkan_filter.c 与 vf_*_vulkan.c 为准。12 章讲了三个解码后端,19 章讲了 CPU 滤镜——本章讲"GPU 计算"这条平行管线:数据驻留 GPU 全程,shader 替代 C 函数。

## 30.0 全景:两条平行管线

```
CPU 管线(19 章):  frame(system memory) → filter_frame → C 函数逐像素
GPU 管线(本章):   frame(VkImage, GPU memory) → dispatch → compute shader
                        ↑ 两者共用 avfilter 框架:同一 activate/filter_frame
                          回调、同一 framesync、同一 negotiate——只是
                          像素格式变成 AV_PIX_FMT_VULKAN、内存驻留变了
```

数据结构上,Vulkan 滤镜是标准 `FFFilter`,声明 `FF_FILTER_FLAG_HWFRAME_AWARE`,像素格式协商只出 `AV_PIX_FMT_VULKAN`——**框架无感,感知在内存**。这正是 12 章 get_format 协商的镜像:GPU 计算不是新框架,是"帧住在哪"的改变。

## 30.1 hwcontext_vulkan:队列三分离与帧池

设备创建的核心是 **queue family 三分离**:graphics/compute/transfer 依次挑选(:1735-1737),打分原则"最少能力位者胜"(pick_queue_family,:1588-1593)——**专才优先**:能用 transfer 队列搬数据的绝不占用 compute 队列。scale 滤镜硬性要求 compute 队列,`ff_vk_qf_find(VK_QUEUE_COMPUTE_BIT)` 失败即 ENOTSUP(vf_scale_vulkan.c:265)。

帧池= `av_buffer_pool_init2` 回调 `vulkan_pool_alloc`(:2902-2979,挂接 :3367-3373):每项是外部内存导出+建 VkImage+初始 layout——与 12 章 NVDEC surface 池对照:Vulkan 的池项自带**同步原语**,每个 VkImage 配一个 timeline semaphore(:2734-2742,:2803;字段 hwcontext_vulkan.h:290-320)。零拷贝导入:DRM/VAAPI 的 DMA-BUF 直接绑成 VkImage(:4276-4299,:3459,DMA_BUF 句柄 :3512-3516)——**12 章 VAAPI 的 VASurface 可经 DMA-BUF 无拷贝进入 Vulkan**,这是 Linux 硬件栈的完整闭环。

transfer 双路径(:4760-5057):host copy 直接 `CopyMemoryToImageEXT`(免命令缓冲)vs staging buffer+`CmdCopyBufferToImage`;**upload 异步、download 同步**(:5046-5050)——下载是消费终点必须等,上传可流水。

## 30.2 基础设施:shader 即资源

libavutil/vulkan.c 把 compute 封装成两层:**ExecPool**(timeline sem+command buffer 轮转)+ **Shader**(descriptor/push constant/pipeline)。shader 是 22 个 `.comp.glsl` 文件,**构建期编译**:configure 探测 glslc/glslangValidator(:7817-7859),make 规则 `.glsl→.spv→(gzip)→bin2c→.spv.o` 链入二进制(ffbuild/common.mak:125-136;`--disable-shader-compression` :539,运行时解压 :2494-2502)。**C 侧与 GLSL 侧的参数协议**:workgroup 尺寸 {32,32,1} 以 specialization constant ID 253/254/255 注入(:2480-2492,对应 scale.comp.glsl:28)——shader 的"常量"由 C 侧填,一个模板适配所有硬件的 local size 限制。

## 30.3 滤镜族:七步提交模板

vulkan_filter.c 提供 process_simple/2pass/Nin 三个通用提交模板,核心是七步(:242-316):exec_get→start→dep_frame(等待依赖帧的 semaphore)→imageview/descriptor→bind+push→barrier→dispatch→submit。**submit 后只解锁帧不等待**——同步延迟到下一消费者(exec_start 预等待 :680;vulkan.c:983-1056):GPU 计算的"产出"是"信号量已记账"而非"像素已就绪",与 21 章 ffplay 的 frame_timer 累积思想同构:**异步管线里,"完成"是消费点的等待,不是生产点的返回**。

overlay 的双输入直接**复用 CPU 滤镜的 framesync**:dualinput+activate+on_event(vf_overlay_vulkan.c:189-201),双输入 dispatch 走 process_Nin(:413,调用 :164-166)——19 章 framesync 的 sync 等级语义原样工作在 GPU 帧上。

## 30.4 libplacebo 的分工

vf_libplacebo(及 21 章 ffplay_renderer)与自带 Vulkan 滤镜**共享同一设备**(pl_vulkan_import):FFmpeg 自带滤镜管"几何/格式级"变换(scale/overlay/transpose/hflip),libplacebo 管"画质链"(色调映射/锐化/去带)——**基础设施共享、能力分层**,这是 12 章"后端实现通用接口"的滤镜版。

## 30.5 设计动机

1. **为什么坚持兼容 avfilter 框架而非另起 GPU 图引擎**:框架的价值在调度/协商/EOF 语义(04 章),GPU 只改变执行单元——重写框架等于放弃 20 年的边界语义积累;
2. **shader 内嵌+构建期编译**:GLSL 源码入库可 review 可 diff,SPIR-V 二进制不进仓库;gzip 链接控制二进制膨胀——**源码即文档**的传统在 shader 上延续;
3. **timeline semaphore 契约**:每帧一 sem 的记账模型让"异步生产+延迟消费"可组合——多滤镜串联时,semaphore 链替代了 CPU 管线的函数调用栈;
4. **queue 三分离的硬件现实**:现代 GPU 的 copy engine 与 SM 是物理分离的——用对队列,传输与计算真并行;打分选"最少能力位"(强调 :1588-1593)是把硬件文档翻译成代码。

## 30.6 FAQ

**Q1:Vulkan 滤镜和 CPU 滤镜能混在一张图里吗?**
能,但交叉点需要 map(download/upload):纯 GPU 链(scale_vulkan→overlay_vulkan)零回传,插一个 CPU 滤镜即两次传输。

**Q2:为什么 scale_vulkan 要求 compute 队列?**
shader dispatch 只能在 compute/graphics 队列(:265);打分逻辑倾向给 compute 专用队列(:1588-1593)。

**Q3:硬解(VAAPI)出来的帧能直接进 Vulkan 滤镜吗?**
Linux 上能:DMA-BUF 零拷贝导入(:4276-4299)——12 章 VAAPI 表面与 Vulkan 帧的桥。

**Q4:shader 怎么进二进制的?**
.glsl→glslc→.spv→gzip→bin2c→.o(common.mak:125-136);无 glslc 时 configure 失败——shader 是构建依赖。

**Q5:submit 返回了帧就处理完了吗?**
没有:只解锁记账,等 semaphore 发生在下一消费者(:983-1056)——30.3 的"延迟同步"。

**Q6:overlay_vulkan 和 overlay 的行为一致吗?**
一致:复用同一 framesync(:189-201),sync 等级/EOF 策略语义相同——只是混合算子在 GPU。

**Q7:workgroup 尺寸为什么从 C 侧注入?**
各硬件 local size 上限不同,specialization constant(ID 253-255,:2480-2492)让同一 SPIR-V 适配全家族。

**Q8:Vulkan 和 NVDEC/NVENC 什么关系?**
正交:NVDEC 产 CUDA 帧,Vulkan 滤镜吃 Vulkan 帧——跨帧池需 map;Vulkan 解码(av1 有一族)是另一条路。

**Q9:没有 libplacebo 能用 Vulkan 滤镜吗?**
能:自带 22 个 shader 滤镜独立工作;libplacebo 只补画质链(21 章 ffplay_renderer 同源)。

**Q10:GPU 滤镜的失败模式是什么?**
设备丢失/队列满:框架层表现为帧错误而非崩溃——hwframe 语义(12 章)接管错误传播。

## 30.7 小结与卷末语

本章结论:**GPU 计算 = "内存驻留改变 + 同步原语记账(shader 链用 semaphore 替代函数栈)"**,框架层的 activate/framesync/协商语义原封不动。FFmpeg 第五卷(26-30)至此完——硬件后端补全、加密栈、图片管线、mux 对比、Vulkan 计算,第二梯队收编完毕。

至此《FFmpeg 深读》全系列:首卷(框架 01-08)+ 第二卷(子系统 09-14)+ 第三卷(管线上层 15-20)+ 第四卷(第一梯队 21-25)+ 第五卷(第二梯队 26-30),共 31 篇正文+27 份调研报告,全部结论钉在 commit 9f63b36a 可对照验证。深挖方向留给后续:

1. timeline sem 链在 10+ 滤镜串联的 semaphore 池水位;
2. DMA-BUF 导入路径与 12 章 VAAPI quirks(hwcontext_vaapi.c:392-415)的组合矩阵;
3. 22 个 shader 的 SPIR-V 体积与启动时的 pipeline cache;
4. Vulkan 解码(av1 等)与 30.1 池的统一;
5. GPU 语境下 color_range(28 章)与 CMS(15 章)的元数据传递。

— 《FFmpeg 深读》五卷完结。AI 编码助手:GLM-5.3-Flash。
