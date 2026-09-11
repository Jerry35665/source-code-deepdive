# 第 05 章 · Mux 框架、硬件加速与工程文化

> 基线:commit `9f63b36a`。行号均以该版本源码为准。

## 5.0 Mux 框架:三段式写入与交织

```
avformat_alloc_output_context2()  → 选格式、分配 priv_data
avformat_write_header()            → 校验 + 写文件头
av_interleaved_write_frame() ×N   → 送包(内部交织排序)
av_write_trailer()                 → 冲刷队列 + 写文件尾 + 释放
```

`init_muxer`(mux.c:187-381)的校验:无 time_base 给回退(音频 `1/sample_rate`,视频 `1/90000`);codec_tag 与 codec_id 必须匹配 muxer 声明的 tag 表。**muxer 能力约束由 FFOutputFormat 标志位驱动**而非硬编码(mux.c:216、250、273-296)。

**交织(interleaving)是 mux 框架的枢纽数据结构**:`ff_interleave_packet_per_dts` 把音视频包按 DTS 排序输出,使文件中数据块按播放时间交错排列。三条 flush 规则(mux.c:939-1019):

1. **全员到齐**:所有可交织流都有排队包——队头包不可能再被超越,安全输出;
2. **max_interleave_delta 超限**:某流长时间不出包,强制输出防队列撑爆;
3. **EOF**:强制清空。

字幕流不参与"必须等到"的计数——否则一条只有对白时才出包的字幕轨会阻塞整个队列。**入队利用到达顺序近似有序的性质,插入从 O(n) 优化到接近 O(1)**(mux.c:859-863)。

**两个 write_frame 的区别**(avformat.h:2736-2766):`av_interleaved_write_frame` **接管所有权**(返回后包变空白);`av_write_frame` 不接管、不排队直写。

## 5.1 movenc:faststart 的两遍空写

MP4 muxer 的 `faststart` 选项要求把 moov(元数据)放在 mdat(数据)前面。但 moov 内的 chunk 偏移在 moov 大小确定前不可知;而偏移增大可能触发 stco→co64 切换,**反过来改变 moov 自身大小**——一个自指问题。

`compute_moov_size`(movenc.c:9019-9042)的解法:**用 null 缓冲空写两遍并做差值修正**——第一遍算出 moov 大小,第二遍用正确偏移重写。"容器格式自指问题的教科书解法"。

## 5.2 硬件加速框架

`libavutil/hwcontext.c`(952 行)定义通用抽象:`AVHWDeviceContext`(设备,如 CUDA context)+ `AVHWFramesContext`(帧池)。每种后端(CUDA/Vulkan/VAAPI/VDPAU/D3D12VA/Metal)实现一张 `HWContextType` vtable(hwcontext_internal.h):`device_create/transfer_get_frames/map_from/map_to` 等回调。

与编解码器(第 03 章)的衔接:解码器通过 `ff_get_format` 提交 hwaccel 候选格式;用户选定后框架创建 hwframes 并挂到 `avctx->hw_frames_ctx`。解码器在 decode 循环中检测 hwaccel 即把 IDR 交给 GPU。

## 5.3 FATE 测试与 configure

**FATE**(FFmpeg Automated Test Environment)是测试矩阵执行器:tests/fate.sh 逐平台/工具链组合运行 tests/Makefile 中的数千条用例,每条用例含输入文件 + 命令行 + 参考哈希(或参考帧逐像素比对)。

**configure**(9006 行 POSIX sh)的探测哲学:不查版本数据库,而是**现场编译最小 C 程序**验证 feature(configure:1461-1470),生成 CONFIG_* 矩阵。tests/Makefile 用 `ALLYES` 宏(tests/Makefile:75-79)让每条测试自动适配任意构建组合——**裁剪构建与裁剪测试由同一套 CONFIG 变量驱动**。

## 5.4 代码风格与工程文化

- **命名约定**:`av_` 前缀(公共 API)、`ff_` 前缀(内部 API)、`LIBAVFORMAT_` 宏前缀;结构体 tag 以 `AV`/`FF` 开头;
- **错误处理**:全部返回负数 `AVERROR(e)` 宏(跨平台映射 errno);`av_log(ctx, level, fmt, ...)` 统一日志;
- **MAINTAINERS 文件**:每个模块列负责人,commit 必须抄送——**责任到人不是口号是基础设施**;
- **汇编优化**:每个性能关键函数有 C 参考实现 + x86/ARM/MIPS SIMD 实现,编译器按 `ARCH_X86` 等宏选择;`checkasm` 工具验证汇编与 C 输出一致。

## 5.5 FAQ

**Q1:av_interleaved_write_frame 返回后 pkt 还能用吗?**
不能。它接管了所有权,返回后 pkt 变空白。要保留请先 `av_packet_ref`。

**Q2:为什么我的 muxer 输出的音视频在文件里不交错?**
检查是否用了 `av_write_frame`(不排队直写)而非 `av_interleaved_write_frame`。

**Q3:faststart 是什么?**
把 MP4 的 moov(索引)放到文件头,使流媒体播放器可边下边播。实现是两遍空写+差值修正。

**Q4:FATE 的测试哈希怎么生成?**
每个用例定义输入文件 + 命令行 + 输出字段选择;fate-run.sh 执行后对指定字段计算 MD5 与参考值比对。

**Q5:如何给 FFmpeg 加一个新编解码器?**
写一个 `FFCodec`(含 `cb.decode/encode` 回调),在 `allcodecs.c` 注册,configure 中添加 `decoder_name_select` 依赖,在 MAINTAINERS 中登记负责人。

## 5.6 小结与深挖方向

本章结论:**mux = "三段式 + 交织队列 + 自指解法";硬件 = "hwcontext 通用抽象 + get_format 协商";工程 = "configure 探测 × FATE 矩阵 × MAINTAINERS 责任制"**。深挖:

1. `ff_interleave_packet_per_dts` 的 `audio_preload` 对 VBR seek 的量化影响;
2. faststart 在 moov > 2GB 时的 co64 切换正确性;
3. hwcontext Vulkan 的多队列提交;
4. FATE 参考帧在大端/小端平台的一致性保证。

> 下一章(卷末):总结。
