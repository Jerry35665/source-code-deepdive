# D 篇 · Muxer 框架、硬件加速与工程文化

> 《源码深读·FFmpeg》系列第二子系统调研报告
> 仓库：`ffmpeg` master @ `9f63b36a`（"MAINTAINERS: add myself for the D3D12 video filters"）
> 面向读者：有 3-5 年后端经验、不熟悉音视频的工程师。所有结论均标注 `文件:行号`，行号对应该 commit。

---

## ① Mux 框架全景：write_header → write_frame → write_trailer 与交织

### 1.1 三段式写入生命周期

FFmpeg 的封装（muxing）API 是一个经典的三段式状态机，全部通用逻辑集中在 `libavformat/mux.c`（1436 行）：

```
avformat_alloc_output_context2()   选格式、分配 priv_data
        ↓
avformat_write_header()            校验 + 写文件头
        ↓
av_interleaved_write_frame()  ×N   送包（内部交织排序）
        ↓
av_write_trailer()                 冲刷队列 + 写文件尾 + 释放
```

`avformat_alloc_output_context2`（mux.c:95-151）先按用户显式指定的 format 名或文件扩展名调用 `av_guess_format` 推断输出格式，然后为该 muxer 分配 `priv_data`（mux.c:127-136）——这是每个具体 muxer（如 MP4 的 `MOVMuxContext`）的私有配置结构，通过 AVClass/AVOpt 体系自动接收用户选项。

`avformat_write_header`（mux.c:467-501）的流程是：

1. 调 `avformat_init_output` → `init_muxer`（mux.c:187-381）做全面校验；
2. 调具体 muxer 的 `write_header` 回调（mux.c:481），写之前先用 `avio_write_marker` 标记 HEADER 区域（mux.c:480）；
3. 调 `init_pts`（mux.c:383-424）为每条流初始化 PTS 生成器（一个分数累加器 `FFFrac`，`frac_init`/`frac_add` 定义在 mux.c:57-93）。

`init_muxer` 里的校验值得细看。对没有 time_base 的流给出回退值：音频用 `1/sample_rate`，视频用 `1/90000`（MPEG 系时钟，mux.c:228-234）；音频必须有 sample_rate（mux.c:238-242）、视频必须有宽高（mux.c:249-254）；codec_tag 与 codec_id 必须匹配 muxer 声明的 tag 表（`validate_codec_tag`，mux.c:153-184）。所有 muxer 的能力约束不是硬编码在框架里的，而是由 `FFOutputFormat` 的标志位驱动：`AVFMT_NOSTREAMS`、`AVFMT_NODIMENSIONS`、`FF_OFMT_FLAG_MAX_ONE_OF_EACH`、`FF_OFMT_FLAG_ONLY_DEFAULT_CODECS` 等（mux.c:216、250、273-296）。

`av_write_trailer`（mux.c:1238-1282）做四件事：先把各流 bitstream filter 里残留的包冲出来（mux.c:1244-1254），再冲刷交织队列（mux.c:1255），然后调 muxer 的 `write_trailer` 回调（mux.c:1259-1265），最后统一释放每条流的 priv_data 和索引条目（mux.c:1273-1276）。错误处理风格是 `ret1/ret` 双变量累加：只要前面成功过，就保留第一个错误码返回（mux.c:1252-1264），保证"冲刷失败不吞错、但也不提前中断其他流的清理"。

### 1.2 两个 write_frame 的区别：所有权与交织

框架提供两个写包入口，语义差异在 `avformat.h` 的 API 注释里写得很清楚（avformat.h:2736-2766）：

- `av_interleaved_write_frame`：**接管**调用者对引用计数包的所有权，返回后包变空白（即使出错）；传 NULL 可随时冲刷交织队列（不只是结尾）；要求同流 dts 严格递增（除非格式打了 `AVFMT_TS_NONSTRICT`）。
- `av_write_frame`：不接管所有权、不修改调用者的包（mux.c:1196-1213 显式复制 props 就是为了 `ff_write_chained` 能在调用后恢复原包，mux.c:1337-1365），不排队、按到达顺序直写。

两者的公共管线在 `write_packets_common`（mux.c:1151-1174）：`check_packet`（stream_index 合法性，mux.c:761-775）→ `prepare_input_packet`（时间戳净化与单调性检查，mux.c:777-831；空包视为 BSF EOS 并强制补一个 0 尺寸引用计数包，mux.c:823-828）→ `check_bitstream`（mux.c:1056-1073，触发 muxer 按需自动插入比特流过滤器，如 MP4 给 AAC 自动加 `aac_adtstoasc`）→ 有 BSF 则走 `write_packets_from_bsfs` 的 send/receive 循环（mux.c:1118-1149，`EAGAIN`/`EOF` 视为正常暂停），否则直接 `write_packet_common`。

真正的落盘在 `write_packet`（mux.c:722-759）：先应用 `output_ts_offset` 偏移（mux.c:731-738），再处理负时间戳规避（下节），最后调 muxer 自己的 `write_packet` 回调并检查底层 `pb->error`——**I/O 错误是延迟到写后检查的**（mux.c:749-753），这是这套框架处理 avio 异步缓冲错误的统一手法。

### 1.3 交织（interleaving）算法：per_dts 排序 + 三条 flush 规则

交织解决的问题是：音视频包按各流到达顺序写入会导致文件的音视频数据块相隔很远，播放器需要大量 seek。目标输出是"音频包和视频包在文件里按播放时间交错排列"。

`init_muxer` 末尾选择交织器（mux.c:331-335）：

```c
fci->interleave_packet = of->interleave_packet;
if (!fci->interleave_packet)
    fci->interleave_packet = fci->nb_interleaved_streams > 1 ?
                             ff_interleave_packet_per_dts :
                             ff_interleave_packet_passthrough;
```

单流直接透传；多流默认按 DTS 排序。muxer 也可以自带交织器覆盖默认行为（如 mpegts）。

**入队**：`ff_interleave_add_packet`（mux.c:835-907）把包插进全局链表 `packet_buffer`。每个流记一个 `last_in_packet_buffer` 指针，如果该流上一个包还在队尾附近，就从那里继续比较插入——**利用到达顺序近似有序的性质，把插入从 O(n) 优化到接近 O(1)**（mux.c:859-863）。`max_chunk_size`/`max_chunk_duration` 触发的 `CHUNK_START` 标记（mux.c:865-881）保证大块数据不被拆散到不同 chunk。

**比较器**：`interleave_compare_dts`（mux.c:909-937）核心是一行 `av_compare_ts`（跨 time_base 的时间戳比较，避免有理数运算误差）。`audio_preload` 选项给音频包减去一个预加载量再比较，实现"音频略微提前写入"的行业惯例（mux.c:916-932，用于 VBR 音频 seek 友好）；DTS 相同时按 stream_index 稳定排序（mux.c:934-935）。

**出队**：`ff_interleave_packet_per_dts`（mux.c:939-1019）决定何时放行队头包，有三条规则：

1. **所有可交织流都已有排队包**（`stream_count == nb_interleaved_streams`，mux.c:967-968）——说明队头包不可能再被更早的包超越，安全输出；
2. **max_interleave_delta 超限**（mux.c:970-1004）：计算队头包与各流最新排队包之间的最大 DTS 差，超过阈值（微秒）就强制输出，防止某条流长时间不出包把队列撑爆。日志写得很直白："Delay between the first packet and last packet in the muxing queue is ... forcing output"（mux.c:998-1001）；
3. **flush（EOF）**：`av_interleaved_write_frame(s, NULL)` 或 `av_write_trailer` 强制清空。

字幕、附件流不参与"必须等到"的计数（mux.c:959-964），否则一条只有对白时才出包的字幕轨会阻塞整个队列。

### 1.4 负时间戳与 DTS 补全

两个工程细节：

- `handle_avoid_negative_ts`（mux.c:636-712）：很多容器（MP4）不允许负 DTS。框架在写第一个包前**偷看交织队列**估计全局最小时间戳（mux.c:656-670），必要时给所有流统一加偏移 `mux_ts_offset`。队列偷看之所以可行，正是因为交织队列本来就是"未来包的缓冲区"——框架把两个子系统的数据结构复用了。
- `compute_muxer_pkt_fields`（mux.c:509-601，当前处于 `FF_API_COMPUTE_PKT_FIELDS2` 弃用周期内）：对缺失 DTS 的包，利用 `video_delay`（B 帧重排深度）维护一个 `pts_buffer` 冒泡排序推算 DTS（mux.c:547-555）；对完全没时间戳的包直接用分数累加器"编造"DTS 并全局只警告一次（mux.c:535-544，注释自嘲 "XXX/FIXME this is a temporary hack until all encoders output pts"——这条 20 年历史的注释本身也是工程文化的注脚）。

---

## ② movenc.c：MP4 muxer 案例侧面

`libavformat/movenc.c` 9632 行，是仓库里最大的 muxer，同一份代码注册了 mov/mp4/psp/3gp/3g2/ipod 等多个 `AVOutputFormat` 变体，回调完全相同（movenc.c:9453-9545），靠 `mode` 字段区分行为。

### 2.1 盒子（box）写法：先占位、后回填

ISO-BMFF（MP4）是一层套一层的"盒子"：`ftyp` → `moov`（索引/元数据）→ `mdat`（媒体数据）。每个盒子头部是 4 字节大端长度 + 4 字节 fourcc。**写盒子时长度未知，所以标准套路是先写 0 占位，写完子盒子后 seek 回来回填**：

```c
static int64_t update_size_and_version(AVIOContext *pb, int64_t pos, int version)
{
    int64_t curpos = avio_tell(pb);
    avio_seek(pb, pos, SEEK_SET);
    avio_wb32(pb, curpos - pos); /* rewrite size */
    avio_skip(pb, 4);
    avio_w8(pb, version); /* rewrite version */
    avio_seek(pb, curpos, SEEK_SET);
    return curpos - pos;
}
```
（movenc.c:165-175）

这个 10 行的函数在 movenc.c 里被调用上百次，是理解整个文件的钥匙：**写 MP4 的本质是"顺序写 + 随机回填"**，这也解释了后面 faststart 的实现方式。

`mdat` 的收尾回填在 `mov_write_mdat_size`（movenc.c:9074-9094）：数据总量 `mdat_size + 8 <= UINT32_MAX` 时直接回写 32 位长度；超过 4GB 时走 ISO-BMFF 的大盒子扩展——写特殊值 1，后面跟 64 位真实长度（movenc.c:9085-9093）。

### 2.2 faststart：第二遍移动 moov

moov 是索引，放文件尾则播放器必须下载完整文件才能开始播。`-movflags +faststart` 的作用是把 moov 挪到文件头。实现（`mov_write_trailer` 内，movenc.c:9178-9185）分三步：

1. **算 moov 有多大**：`compute_moov_size`（movenc.c:9019-9042）往一个 null 缓冲区（`ffio_open_null_buf`）空写一遍 moov 拿到尺寸；然后给每条轨的 chunk 偏移加上这个尺寸再空写一遍——因为 moov 前移后所有 `stco` 表里的绝对文件偏移都要平移，而偏移平移可能让 32 位 `stco` 装不下、需要切到 64 位 `co64`（`co64_required`，movenc.c:177-182），moov 自身大小又会变。所以**空写两遍并做差值修正**（movenc.c:9035-9039），注释解释得非常清楚。
2. **挪数据**：`shift_data`（movenc.c:9059-9072）调通用的 `ff_format_shift_data` 把 mdat 整体后移 moov_size 字节。
3. **写 moov**：seek 回文件头预留位置，正式写 `mov_write_moov_tag`。

另一个变体 `reserved_moov_size`（`-moov_size` 选项，movenc.c:105）在 header 阶段就预留固定空间，trailer 时写入 moov 后用 `free` 盒子填满剩余（movenc.c:9186-9198）——一次流式写完，不需要第二遍，代价是要预估索引大小。

另外值得注意：MP4 muxer 的 `check_bitstream` 回调（movenc.c:9239-9252）发现 AAC 流是 ADTS 格式就自动挂 `aac_adtstoasc` 过滤器、VP9 挂 `vp9_superframe`——这正是 ①.2 里 `AVFMT_FLAG_AUTO_BSF` 机制的最著名用户。"编码器输出裸流 + muxer 自动转格式"的分工让用户不必理解 Annex-B vs ASC 这类格式细节。

`mov_write_trailer`（movenc.c:9096-9237）整体逻辑极长：给未闭合的字幕补结束样本（movenc.c:9108-9115）、冲刷缓冲的 EAC3 包（movenc.c:9117-9133）、必要时补写章节轨（movenc.c:9143-9149）、回填 mdat 尺寸、再走 faststart/fragment 分支。fragmented MP4（fMP4，流媒体用）则完全不同：边写边出 `moof` 片，trailer 只补 `sidx`/`mfra` 索引（movenc.c:9213-9233）。

---

## ③ 硬件加速框架：hwcontext 通用层 + CUDA 后端

### 3.1 设计：两张 vtable + 引用计数包装

libavutil 的 hwcontext 是一个**设备抽象层**：它不实现编解码，只管"GPU 上下文"和"GPU 显存帧池"的创建、跨厂商派生和数据搬运。核心是两张表：

- 公共头文件暴露 `AVHWDeviceContext` / `AVHWFramesContext`；
- 内部 `HWContextType`（libavutil/hwcontext_internal.h:29-91）是每个后端必须实现的函数表：`device_create/device_derive/device_init/device_uninit`、`frames_init/frames_uninit/frames_get_buffer`、`transfer_data_to/transfer_data_from`、`map_to/map_from` 等。

后端注册是一张编译期裁剪的静态表（libavutil/hwcontext.c:32-76）：

```c
static const HWContextType * const hw_table[] = {
#if CONFIG_CUDA
    &ff_hwcontext_type_cuda,
#endif
#if CONFIG_D3D11VA
    &ff_hwcontext_type_d3d11va,
#endif
    ...
#if CONFIG_VULKAN
    &ff_hwcontext_type_vulkan,
#endif
    NULL,
};
```

14 种后端（cuda、d3d11va、d3d12va、drm、dxva2、opencl、qsv、vaapi、vdpau、videotoolbox、mediacodec、vulkan、amf、oh）条件编译进表，配一个枚举→字符串的名字表（hwcontext.c:78-93）。没有动态注册、没有全局构造函数——**FFmpeg 一贯避免静态初始化钩子，一切可见性都由条件编译显式控制**。

对象模型是 FFmpeg 私有结构嵌公共结构的双段模式：`FFHWDeviceContext { AVHWDeviceContext p; const HWContextType *hw_type; AVBufferRef *source_device; }`（hwcontext.c:95-108）。整个对象用 `av_buffer_create` 包成 `AVBufferRef` 引用计数管理，free 回调里保证 `device_uninit` 先于用户的 `free` 回调执行（hwcontext.c:157-174）。

### 3.2 关键流程

**设备创建**两段式：`av_hwdevice_ctx_alloc`（hwcontext.c:176-221）按后端声明的 `device_hwctx_size` 给 `ctx->hwctx`（后端私有区，如 CUDA 的 `AVCUDADeviceContext`）分配零化内存；`av_hwdevice_ctx_init`（hwcontext.c:223-233）才调后端的 `device_init`。分配与初始化分离，让用户可以在 init 前先填 hwctx 里的字段（比如外部传入的 CUDA context）。

**帧池**：`AVHWFramesContext` 持有一个 `AVBufferPool`。`av_hwframe_ctx_init`（hwcontext.c:337-384）校验像素格式属于后端声明的 `pix_fmts` 列表、校验尺寸，调后端 `frames_init`，若 `initial_pool_size > 0` 就**预分配整个池**（`hwframe_pool_prealloc`，hwcontext.c:309-335）——预分配能提前暴露显存不足，避免运行中分配失败炸掉解码管线。

**取帧**：`av_hwframe_get_buffer`（hwcontext.c:506-568）从池里取；对"派生帧上下文"（derived frames context）则递归到源上下文分配再 map 过来（hwcontext.c:512-547）。

**数据搬运**：`av_hwframe_transfer_data`（hwcontext.c:448-504）处理三种方向：HW→SW（调 src 的 `transfer_data_from`）、SW→HW（调 dst 的 `transfer_data_to`）、HW→HW（src 或 dst 任一后端能做即可，失败回退另一个，hwcontext.c:481-485）。若目标帧未分配内存，`transfer_data_alloc`（hwcontext.c:398-446）自动按后端报告的首选格式补分配。

**设备派生**：`av_hwdevice_ctx_create_derived_opts`（hwcontext.c:651-716）是跨 API 互操作的关键。先沿 `source_device` 链找同类型祖先直接引用（免重复创建）；否则沿链逐级尝试各后端的 `device_derive`——例如 Vulkan 设备可以派生 CUDA 设备（CUDA 后端用 `VkPhysicalDeviceIDProperties` 里的 UUID 匹配物理设备，hwcontext_cuda.c:833-919）。这让"一层 hwdevice 挂一串派生设备"的用法成为可能：`vulkan → cuda → nvenc`。

**映射**：`av_hwframe_map`（hwcontext.c:793 起）与 `ff_hwframe_map_create`（hwcontext.c:741-791）用了一个巧妙手法：把 `HWMapDescriptor`（含 `unmap` 回调）挂到目标帧的 `buf[0]` 上，**引用计数归零时自动触发 unmap**（hwcontext.c:726-739）——把资源生命周期管理完全交给既有的 AVBuffer 机制。

### 3.3 CUDA 后端概览

`libavutil/hwcontext_cuda.c`（956 行）展示了后端的典型写法：

- 函数表注册（hwcontext_cuda.c:932-956）：`transfer_data_to` 和 `transfer_data_from` 指向**同一个** `cuda_transfer_data`（CUDA 的 `cuMemcpyDtoH`/`cuMemcpyHtoD` 天然双向）；`pix_fmts` 是 `AV_PIX_FMT_CUDA`（普通线性显存）和可选的 `AV_PIX_FMT_CUARRAY`（CUDA 数组，用于 NVENC 硬编码输入）。
- `cuda_device_create`（hwcontext_cuda.c:793-831）：解析选项 → `cuInit(0)` → `cuDeviceGet` 按序号取设备 → `cuda_context_init` 建上下文。所有 CUDA 调用经 `CHECK_CU` 宏包装，错误统一走 `error:` 标签调 `cuda_device_uninit` 清理（hwcontext_cuda.c:828-830）——与 mux.c 的 `goto fail` 是同一套纪律。
- **动态加载**：所有 CUDA API 通过 ffnvcodec 生成的加载器（`hwctx->internal->cuda_dl`）在运行时 dlopen libcuda 获取——FFmpeg 二进制不硬链接任何 GPU 驱动库，没装驱动的机器上编译进来的 CUDA 支持只是"不可用"而非"崩溃"。这也是 configure 里 `ffnvcodec` 作为独立探测项（configure:2175）的原因。
- `cuda_get_buffer`（hwcontext_cuda.c:398-487）里藏着一个兼容性 hack 的好例子：NVENC 期望的 YUV420P U/V 平面顺序与 FFmpeg 相反且色度半对齐，于是在取帧时直接交换 `frame->data[1]`/`data[2]` 指针（hwcontext_cuda.c:477-482），注释明说 "Nvenc expects the U/V planes in swapped order"。

后端代码里的平台分支（`#if HAVE_FFNVCODEC_CUARRAY`、`#if CONFIG_VULKAN`）密度很高，这是硬件抽象层的常态：通用层定义接口，后端层各自消化平台差异。

---

## ④ FATE 测试体系

FATE（FFmpeg Automated Test Environment）是一个"可复现构建 + 比对式回归测试 + 志愿者农场"三位一体的体系。仓库内三件套：`tests/fate.sh`（农场节点驱动）、`tests/Makefile`（测试矩阵定义）、`tests/fate-run.sh`（单测执行与比对）。

### 4.1 fate.sh：农场节点的最小化驱动

`tests/fate.sh` 只有 140 行 POSIX shell，职责是把一台机器变成 FATE 农场节点。它读一个用户配置文件（定义 `slot`、`repo`、`samples` 等变量），然后执行完整的"检出 → configure → 编译 → 测试 → 上报"流水线：

- `configure`（fate.sh:44-73）固定带 `--enable-gpl --enable-memory-poisoning`（内存投毒帮助暴露未初始化内存问题），其余编译器/架构/交叉编译参数全部由配置变量注入——**同一个测试矩阵要在 x86/ARM/MIPS、gcc/clang/icc、Linux/BSD/Solaris 上各跑一遍**；
- 版本号没变就直接退出实现增量测试（fate.sh:129-131）；
- `report`（fate.sh:102-108）把 `fate:1:日期:slot:版本:状态...` 头 + 完整 configure 结果（`ffbuild/config.fate`）+ 每个测试的 `.rep` 报告打包 gzip 通过 `$fate_recv` 上传。失败码区分三个阶段：3=configuring、2=compiling、1=testing（fate.sh:136-138）。

fate.ffmpeg.org 聚合所有志愿节点的结果，这就是 MAINTAINERS 里 `fate.ffmpeg.org` 一行的归属（MAINTAINERS:67）。

### 4.2 Makefile：用 make 表达"能力门控"的测试矩阵

`tests/Makefile`（367 行）最有意思的设计是 **ALLYES 依赖门**（tests/Makefile:75-79）：一条测试只有在它依赖的所有 `CONFIG_*` 开关（编码器、解码器、muxer、demuxer、协议……）全部启用时才被纳入矩阵：

```make
ENCDEC  = $(call ALLYES, $(firstword $(1))_ENCODER $(lastword $(1))_DECODER  \
                         $(firstword $(2))_MUXER   $(lastword $(2))_DEMUXER  \
                         $(3) FILE_PROTOCOL)
```

于是 `FATE_AAC += $(call ENCDEC, aac, adts)` 这类声明自动适配任意 configure 组合——`--disable-everything` 的最小构建不会因缺组件而报错，只是安静地少跑测试。在此之上叠出 REMUX、FRAMEMD5、TRANSCODE、FILTERDEMDEC 等十余个组合宏（tests/Makefile:92-130），覆盖 remux/转码/滤镜/seek 等场景。

测试域按模块拆成 130+ 个 `tests/fate/*.mak` 文件（tests/Makefile:144-266），从 `acodec.mak` 到 `vvc.mak`，按编解码器/容器/滤镜分域——**测试定义与被测代码同域同名，找某个 muxer 的测试从文件名就能定位**。

### 4.3 比对机制：参考文件 + 容差

`fate-run.sh` 每条测试的默认流程：跑命令 → 生成输出 → 与 `tests/ref/fate/<测试名>` 参考文件比对（fate-run.sh:17）。比对方式由 `CMP` 参数选择，默认 `diff`，媒体数据则用：

- **MD5**：原始解码输出直接 `do_md5sum`（fate-run.sh:236、297、301），参考文件里存的只是 md5 串——几 KB 的参考文件代表任意大的二进制；
- **tiny_psnr 容差比较**（fate-run.sh:65-82）：对有损编码，比较解码输出的 stddev/maxdiff 与参考值之差是否落在 `FUZZ` 容差内。绝对比特一致对浮点/多线程不可行，**"统计量 + 容差"是有损场景的正确近似**；
- oneoff（fate-run.sh:84-85）、refcmp_metadata（fate-run.sh:531 起，滤镜输出的元数据级比对）等特化比较器。

关键配套：**参考输入不是二进制样本，而是程序合成的**。`VREF = tests/vsynth1/00.pgm`、`AREF = tests/data/asynth1.sw`（tests/Makefile:15-16）由 `tests/videogen`/`tests/audiogen` 现场生成（tests/Makefile:29-36）——不依赖外部素材就能测完整编码管线。外部样本（受版权限制的码流）走 `SAMPLES` 目录 rsync 自 fate-suite.ffmpeg.org，未配置 SAMPLES 时只跑免费子集（tests/Makefile:297-308）。硬件相关测试默认不进 `make fate`，单列为 `fate-hw`（tests/Makefile:318-320）。

---

## ⑤ configure 与构建体系

### 5.1 一份 9006 行的手写 POSIX shell

FFmpeg 拒绝 autoconf/cmake，`configure` 是手写 POSIX shell（9006 行），开头甚至在检测并逃离坏 shell：try_exec 依次尝试 bash/ksh/`/usr/xpg4/bin/sh`（configure:17-55），错误信息写着 "THIS IS NOT A BUG IN FFMPEG"（configure:47）——Solaris 的历史伤痕。

### 5.2 探测原语：一切皆"编译一段代码试试"

feature 探测不查版本表，而是**直接编译链接最小测试程序**：

```sh
check_func(){
    log check_func "$@"
    func=$1
    shift
    disable $func
    test_ld "cc" "$@" <<EOF && enable $func
extern int $func();
int main(void){ $func(); }
EOF
}
```
（configure:1461-1470）

在此之上组合出 `check_func_headers`（头文件+函数符号存在性，还要防 LTO 把测试函数优化掉，configure:1500-1503）、`check_pkg_config`（pkg-config 封装）、`check_cpp_condition`（预处理条件，如"头文件里定义的版本宏 ≥ X"）、`check_cflags_cc`（编译器 flag 支持性探测，configure:1563-1567）。`require_*` 变体在探测失败时直接报错终止（configure:1787 起）。**编译探测天然跨平台：不用维护"哪个发行版哪个包提供什么"的数据库，答案权威地来自工具链本身**。

### 5.3 开关宇宙与 config.h

configure 定义了庞大的组件清单变量：解码器/编码器/muxer/demuxer/滤镜/BSF/协议/硬件加速，例如 `HWACCEL_AUTODETECT_LIBRARY_LIST`（configure:2166-2184）列出 cuda/vaapi/vulkan/d3d12va 等 17 个自动探测的硬件后端，`HWACCEL_LIBRARY_NONFREE_LIST`（configure:2193-2196）单独隔离不可再分发的组件。每个组件生成 `CONFIG_XXX` 变量，最终写入 `config.h` 与 `config.mak`——源码里漫山遍野的 `#if CONFIG_CUDA` 就是这么来的。默认全开：`enable $PROGRAM_LIST ... $LIBRARY_LIST`（configure:4481-4485）。

这套体系与 FATE 的 ALLYES 门控形成闭环：configure 决定 CONFIG 矩阵，Makefile 依据 CONFIG 裁剪测试矩阵，farm.sh 保证矩阵在几十种组合上被真实执行。

---

## ⑥ 代码风格与工程文化

### 6.1 语言与命名

- **C99 特性随手用**：循环内声明 `for (int i = 0; ...)`（mux.c:166、222；configure 检测器保证工具链支持）、指定初始化器（`hw_type_names[]` 按枚举索引，hwcontext.c:78-93；`default_codec_offsets[]` 按媒体类型索引，mux.c:193-197）、复合字面量 `(AVRational){1, st->codecpar->sample_rate}`（mux.c:628）。但不上 VLA、不用 C11 thread，保持对老工具链的兼容。
- **命名前缀即可见性契约**：`av_` 公共 API；`ff_` 库内私有（如 `ff_interleave_packet_per_dts`）；`avpriv_` 跨库但不出源码树。公共/私有结构成对：`AVOutputFormat p` + `FFOutputFormat`（mux.h:61-65）、`AVHWDeviceContext p` + `FFHWDeviceContext`（hwcontext.c:95-99）——**ABI 稳定的公共部分冻结在头文件，可自由演化的私有部分藏在 .c**，升级不破坏下游。
- **注释文化**：Doxygen 风格强制（developer.texi:287-291 要求"所有非平凡函数"都要有注释，结构体每个成员也要注释），mux.h:77-103 对 `write_packet`/`interleave_packet` 回调的语义文档精细到"返回 0 表示还有数据、1 表示冲刷完毕"。

### 6.2 错误处理

统一约定：**成功返回 0，失败返回负的 AVERROR**。`AVERROR(e)` 就是 `-(e)`（libavutil/error.h:41），另有 `FFERRTAG` 构造的库特定错误码（error.h:49）。典型形态是 `int ret` + `goto fail` 单出口清理（mux.c:145-150、378-381；hwcontext_cuda.c:828-830），配合 `ret1/ret` 累加保证清理链上的首个错误不丢（mux.c:1242-1264）。三级断言 `av_assert0`（生产保留）/`av_assert1`/`av_assert2`（分级编译，mux.c:414、743、897）区分"不可违反的内部不变式"与"调试辅助"。用户侧则提供 `av_err2str`（error.h:122）栈上缓冲把错误码转字符串。

### 6.3 邮件列表治理与模块负责制

- **README.md:41-45 的态度**："Patches should be submitted to the ffmpeg-devel mailing list using `git format-patch` or `git send-email`. Github pull requests should be avoided because they are not part of our review process and will be ignored."——PR 明确不被接受，评审在邮件列表完成。
- **MAINTAINERS 文件**（643 行）按目录列出每个模块的负责人，带四级状态标签：`[X] 老代码`、`[0] 无维护者（也许你可以接手）`、`[1] 有维护者但没时间`、`[2] 真正有人在看`（MAINTAINERS:9-13）。例如 `hwcontext_cuda*  Timo Rothenpieler`、`hwcontext_vulkan* [2] Lynne`（MAINTAINERS:94-97），文档整体由 Stefano Sabatini 等四人负责（MAINTAINERS:54），release management 长期由 Michael Niedermayer 承担（MAINTAINERS:59）。本 commit 本身就是一条 MAINTAINERS 更新（"add myself for the D3D12 video filters"）——**负责制文件是活的**。
- developer.texi 的提交规则极具特色：排版变更必须与功能变更分开成独立 patch（developer.texi:502）；patch 发出后一周无人反对即可自行合入（developer.texi:533-535）；用 `patcheck` 工具自查（developer.texi:751）；修复安全研究者报告的问题必须致谢（developer.texi:528）。缩进规则直接给出发 vimrc/emacs 配置（developer.texi:253-285）——4 空格、禁 tab、禁行尾空白。

### 6.4 文档矩阵

doc/ 目录是一套完整的 texinfo 文档生态：用户侧（ffmpeg.texi、faq.texi）、开发者侧（developer.texi、build_system.txt、filter_design.txt、errno.txt 错误码清单）、社区侧（community.texi）、测试侧（fate.texi + fate_config.sh.template 模板）。加上 `doc/examples/` 的 C API 示例、随版本发布的 `APIchanges` 变更日志、Doxyfile。对新晋贡献者，"如何在提交前跑 FATE"写在 developer.texi 里（developer.texi:754），文档-工具-流程三者互相引用成环。

---

## ⑦ FAQ

**Q1: 为什么 av_interleaved_write_frame 返回后我的包变空了？**
这是设计而非 bug：交织版接管引用计数所有权并在合适时机 unref（avformat.h:2739-2744）。非交织版 av_write_frame 则保证不碰调用者的包（mux.c:1196-1213 的注释点名了 ff_write_chained 依赖此行为）。需要保留就自己先 av_packet_ref。

**Q2: 为什么交织队列会积压？积压多大算正常？**
直到每条可交织流都至少有一个包入队才会出包（mux.c:967-968）。视频 B 帧深度、字幕轨稀疏、或某路输入断流都会拉长积压。上限由 `max_interleave_delta`（默认 10 秒量级的微秒值）兜底强制冲刷（mux.c:970-1004）。

**Q3: "Packets poorly interleaved, failed to avoid negative timestamp" 警告怎么办？**
负 DTS 规避依赖队首偷看估计最小时间戳（mux.c:656-670）；某流严重乱序到达时估计失效。警告文本自己给了两个 workaround：`-avoid_negative_ts 1` 或 `-max_interleave_delta 0`（mux.c:702-710）。

**Q4: faststart 会不会把文件写两遍？磁盘要留双倍空间吗？**
不需要双倍空间。`ff_format_shift_data` 是**原位**后移 mdat（分块搬运），不是复制整文件；moov 大小通过两次空写（null 缓冲，movenc.c:8994-8998）精确预计算，连 stco→co64 的尺寸跳变都补偿了（movenc.c:9035-9039）。

**Q5: MP4 超 4GB 怎么处理的？**
ISO-BMFF 大盒子扩展：长度字段写特殊值 1，紧跟 64 位真实长度（movenc.c:9085-9093）。chunk 偏移同理从 stco 切 co64（movenc.c:177-182）。

**Q6: 我的 AAC 文件封装成 MP4 报格式错误？**
大概率是 ADTS 裸流。MP4 muxer 会通过 check_bitstream 自动挂 aac_adtstoasc 过滤器（movenc.c:9244-9246），前提是 `AVFMT_FLAG_AUTO_BSF` 没被关掉（mux.c:1060-1062）。这是框架层机制，所有 muxer 都能用。

**Q7: hwcontext 和 nvdec/nvenc/qsv 这些词是什么关系？**
hwcontext 只管设备与显存帧的抽象（开 GPU 上下文、分配/搬运显存帧）。编解码器（nvdec/nvenc/qsv 等位于 libavcodec）消费 hwcontext 提供的帧。每个软解器还通过 `.hw_configs` 声明自己支持的硬件加速后端（vp9.c:1963-1995 列了 10 种）。

**Q8: 装不上 CUDA 驱动还能用编译了 CUDA 的 FFmpeg 吗？**
能构建能运行，只是设备创建会失败。所有 CUDA API 是运行时 dlopen 的（hwcontext_cuda.c:812 经 cuda_dl），二进制不链接驱动库。

**Q9: FATE 为什么用 md5 比对？浮点不确定性怎么办？**
md5 覆盖确定性路径（原缓解参考文件体积问题）；有损/浮点路径用 tiny_psnr 比较统计量（stddev/maxdiff）并给 FUZZ 容差（fate-run.sh:65-82）。合成输入源（videogen/audiogen，tests/Makefile:29-36）保证无需外部素材即可全流程回归。

**Q10: 为什么不用 CMake 而手写 9000 行 configure？**
历史（2000 年起，configure:5）+ 约束：要支持的平台/工具链组合极广（含 Solaris、嵌入式交叉编译、非主流 shell），自带的"编译即探测"原语不依赖目标环境装任何元工具，且探测结果直接生成 config.h/config.mak 与 FATE 联动。

---

## ⑧ 深挖问题

**P1: 交织队列的插入复杂度与回退路径。** `ff_interleave_add_packet` 借助 `last_in_packet_buffer` 做近似 O(1) 插入，但乱序严重时从 tail 全链扫描（mux.c:886-896）；`CHUNK_START` 逻辑（mux.c:865-881）与 audio_preload 合用时的正确性边界值得写测试验证。可深挖：对比 mpegts 自带交织器与 per_dts 的行为差异。

**P2: avoid_negative_ts 的"一次性快照"语义。** 偏移在第一个有效包时计算并冻结（`AVOID_NEGATIVE_TS_UNKNOWN → KNOWN`，mux.c:645-683），若后续出现更早的时间戳，只有警告没有补救（mux.c:702-710）。直播场景反复追加写入（append）时这是否构成正确性风险？

**P3: fMP4 与 faststart 的统一抽象。** `shift_data` 被复用于 faststart（挪 moov）与 GLOBAL_SIDX（插 sidx，movenc.c:9217-9227），HYBRID_FRAGMENTED 甚至在 trailer 时把整段 fMP4"折叠"回普通 MP4（movenc.c:9153-9168，含 "Clear the empty_moov flag" 的 hack）。三种"回头改文件"策略的磁盘 I/O 模式差异（随机回填 vs 整体平移）值得基准测试。

**P4: hwcontext 派生链的资源生命周期。** `av_hwdevice_ctx_create_derived_opts` 沿 source_device 链向上找同类设备直接引用（hwcontext.c:661-672），意味着释放派生链中段设备时语义如何？map 的 unmap 依赖 buf[0] 引用计数（hwcontext.c:726-739），跨线程取帧/映射的竞争面在哪里？

**P5: FATE 参考值的漂移治理。** 容差比对（tiny_psnr fuzz）+ 合成输入能挡住大部分平台差异，但不同编译器/浮点 ABI 下 stddev 参考值如何判定"可接受的漂移 vs 真回归"？fate.sh 上报的 `.rep` 格式（fate.sh:104-107）只有 pass/fail/差异值，农场间如何仲裁？这决定"几千个参考文件"这一资产管理模式的长期可扩展性。

---

### 附：本篇实际阅读清单

| 文件 | 行数 | 覆盖方式 |
|---|---|---|
| libavformat/mux.c | 1436 | 全文精读 |
| libavformat/movenc.c | 9632 | 定向段落（盒回填、mdst、faststart、trailer、check_bitstream） |
| libavformat/mux.h、avformat.h（API 注释） | — | 接口契约段 |
| libavutil/hwcontext.c | 952 | 主体精读 |
| libavutil/hwcontext_internal.h、hwcontext_cuda.c | 956 | vtable + 关键函数 |
| tests/fate.sh、tests/Makefile、tests/fate-run.sh | — | 体系结构 + 比对机制 |
| configure | 9006 | 头部、探测原语、组件清单段 |
| libavcodec/vp9.c | 1996 | 生命周期与 hw_configs 段 |
| README.md、MAINTAINERS、doc/developer.texi | — | 全文/相关章节 |
