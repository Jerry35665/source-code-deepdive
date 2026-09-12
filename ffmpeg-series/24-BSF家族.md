# 第 24 章 · BSF 家族:不改码流语义的比特手术刀

> 基线:commit `9f63b36a`。行号以 libavcodec/bsf.c、bsf.h 与 libavcodec/bsf/ 子目录(50+ 实现)为准。03 章框架层一句话带过 BSF,16 章 mux 线程提到过它——本章把机制与代表实现讲透。

## 24.0 全景:BSF 的位置与定义

BSF=**不解码而改写 AVPacket** 的过滤器(bsf.h:36-38)。两个部署位:

```
demux ─→ BSF ─→ decoder        (解封装侧修正:mp4toannexb 等)
encoder ─→ BSF ─→ mux          (封装侧适配:adtstoasc/extradata 提取)
```

框架极简:公开 AVBSFContext 仅 6 字段(bsf.h:68-109);私有壳 FFBSFContext 只加**单槽 buffer_pkt+eof 标志**(bsf.c:36-40)——**框架层没有队列**,槽未消费时 send 返回 EAGAIN(bsf.c:217-218),强制调用方"send→drain→再 send"节拍。生命周期:`av_bsf_alloc`(:99-145,预分配 par_in/par_out/priv_data)→ 调用方填 par_in → `av_bsf_init`(:147-186,codec 白名单校验→**par_out 原样拷 par_in**→filter 的 init 回调)→ send/receive → flush(:188-198)/free(:47-70)。

## 24.1 零拷贝与取包两出口

三个关键语义:

- **空包=EOF 信号**(:205-210);
- **send 用 `av_packet_move_ref` 挪引用不拷字节**(:220-223)——BSF 链全程引用传递,一次拷贝都没有;
- **filter 取包两出口**:`ff_bsf_get_packet_ref`(move 引用,不改数据者用,:254-267)vs `ff_bsf_get_packet`(指针交换,重写者用,:233-252)。

N 进 M 出合法:吞包(filter_units 删空返回 EAGAIN)与攒包(vp9_superframe 合帧)都是标准用法。链式 `-bsf "a,b"` 由 `av_bsf_list_parse_str` 解析(bsf.c:524-549),list_bsf 级联 init **把上家 par_out 接下家 par_in**(:281-308);null BSF 即 get_packet_ref 直通(null.c:26-29)。

**extradata 的一次性变换发生在 init 时**(:179-183):par_out 定型后 muxer 才写文件头——这决定了"头数据"与"包数据"在 BSF 里永远分两步处理。

## 24.2 h264_mp4toannexb:逐字节替换的教科书

MP4 存 H264 用"4 字节长度前缀",TS/裸流用 `00 00 01` 起始码——这个 BSF 做格式翻译:

**init**(bsf/h264_mp4toannexb.c):检测 extradata 头 3/4 字节非 `00 00 01` 才解析 avcC(:269-275);`length_size=(byte&3)+1`(:107);逐单元写 `00 00 00 01`+NALU,按 `pps_offset`(:135)切分 SPS/PPS 存入 av_fast_realloc 缓存(:142-169),AnnexB 版 extradata 写回 par_out(:279-280)。

**filter**(:325-429)三步:

1. 先消费 NEW_EXTRADATA side data(流中参数集变更,:300-308),`filter_ps` 扫包内 SPS/PPS 更新缓存(:221-262,流内优先);
2. **两遍扫描**:j=0 只计数、j=1 才写(:325-429)——避免 realloc;
3. 逐 NALU:读 length_size 字节大端长度(:337-338)→越界校验(:344)→丢弃长度前缀→写 3 字节(非首)或 4 字节起始码(:55-82)。

**IDR 且流内未见参数集时前置缓存的 SPS/PPS**(:390-395)——解码器拿到 IDR 却没有参数集必花屏,这一步是"TS 流中途接入"能工作的隐形前提;遇普通切片重置 seen 标志(:410-414);状态跨包延续、flush 复位(:458-465)。

## 24.3 aac_adtstoasc:剥头与 ASC 生成

ADTS(裸 AAC 流)每帧 7 字节头(+2 CRC),MP4 需要 单个 extradata(ASC):BSF 剥掉每帧 ADTS 头(:70-73,106-112),用 PutBitContext 把 13 位 ASC 拼进 NEW_EXTRADATA——方向与 mp4toannexb 相反:**一个加头,一个剥头**,合起来覆盖 AAC 双形态。

## 24.4 通用工具三件

- **filter_units**:按 NAL 类型增删的手术刀(:140-144 删空吞包;init 时 extradata 同步过滤 :202-215)——去掉 SEI/前置 AUD 的标准工具;
- **extract_extradata**:自动探测参数集写 extradata,是 fMP4/RAW 封装的隐形前提( demux 侧自动挂接:demux.c:2477-2564);
- **setts**:表达式重算 ts/pts/dts 的时间戳手术——与 19 章 settb 滤镜呼应但工作在包层。

外加一个"隐形必需"案例 **vp9_superframe**:VP9 的 alt-ref 帧标志丢失会花屏,BSF 攒最多 8 帧合成 superframe(marker=`0xC0|(mag<<3)|(n-1)`,:52-99,151-161)——WebM 封装前它是必需品。

## 24.5 集成:自动挂接与用户路径

muxer 用 `check_bitstream` 回调声明自动 BSF:裸流写出且非起始码→自动挂 h264_mp4toannexb(rawenc.c:389-391);AAC 无 ASC→adtstoasc(movenc.c:9239-9248,flvenc.c:1490-1502);缺 extradata→extract_extradata。用户路径:`-bsf:v` 从 ffmpeg_opt.c:2054 → ffmpeg_mux_init.c:1432 → mux 线程 send/receive(ffmpeg_mux.c:572-604,315-354,bsf_init 回写 par_out)。**"能自动就不让用户操心"是 check_bitstream 机制的设计意图**。

## 24.6 设计动机

1. **为什么独立成层**:码流形态(AnnexB/avcC、ADTS/ASC)与编解码逻辑正交——塞进 decoder 会让每个解码器背两种输入格式;BSF 让"格式适配"成为可组合的独立单元;
2. **单槽即节拍**:框架无队列是刻意的——BSF 是同步变换点,缓冲应该住在调用方(mux 线程队列/16 章);
3. **init 分离 par_out**:extradata 变换必须发生在写文件头之前——生命周期上"头先于包"被结构固化;
4. **两遍扫描**:一包数十个 NALU 时避免中间 realloc,是流式代码的典型预算控制。

## 24.7 FAQ

**Q1:BSF 和滤镜图什么区别?**
BSF 改写压缩域字节(不解码);滤镜改写解码后的像素/样本。一个在 decode 前/encode 后,一个在 decode 后/encode 前。

**Q2:为什么 BSF 框架没有队列?**
单槽强制 send→drain 节拍(bsf.c:36-40,217-218);缓冲职责在调用方(16 章 mux 线程)。

**Q3:MP4 转 TS 为什么必须 h264_mp4toannexb?**
TS 无 avcC,解码器只认起始码流;BSF 换长度前缀为 00 00 01 并前置 SPS/PPS(:390-395)——缺失即花屏。

**Q4:参数集在流中变化怎么办?**
NEW_EXTRADATA side data 先消费(:300-308),filter_ps 更新缓存(:221-262)——流内优先于 extradata。

**Q5:-bsf "a,b" 链上 par 怎么传?**
list_bsf 级联 init 把上家 par_out 接下家 par_in(bsf.c:281-308)——链式变换的头数据一致。

**Q6:BSF 能输出与输入不同数量的包吗?**
能:filter_units 删空吞包、vp9_superframe 攒帧合成——N 进 M 出是标准语义。

**Q7:extradata 变换发生在什么时候?**
av_bsf_init 时一次完成(:179-183),之后 par_out 定型——muxer 写头用的是变换后的。

**Q8:什么情况 muxer 会自动挂 BSF?**
muxer 的 check_bitstream:裸流非起始码→mp4toannexb(rawenc.c:389-391)、AAC 缺 ASC→adtstoasc(flvenc.c:1490-1502)。

**Q9:BSF 会拷贝包数据吗?**
框架层零拷贝:send/receive 全程 move_ref(:220-223);只有"重写型" BSF 内部才产生新缓冲(get_packet 指针交换,:233-252)。

**Q10:vp9 为什么需要 superframe BSF?**
alt-ref 帧标志在 WebM 容器中必须以 superframe index 呈现,BSF 攒帧合成 marker(:52-99)——缺失即花屏,属于"隐形必需"。

## 24.8 小结与深挖方向

本章结论:**BSF = "单槽零拷贝框架 + init 期头变换 + N 进 M 出语义"**,h264_mp4toannexb 是流式逐字节改写的教学范本。深挖:

1. 两遍扫描(:325-429)在超大包(4K IDR)下的缓存行效率;
2. filter_units 与 CBS metadata BSF(h264_metadata 等)的能力边界;
3. dts2pts BSF 的 B 帧时间戳重建算法(与 22 章 parser DTS 外推对照);
4. check_bitstream 自动挂接与用户显式 -bsf 的冲突仲裁;
5. bsfgraph(编码侧滤镜图式 BSF 链)的扩展前景。

> 下一章:音频滤镜与 AAC 编码器——19 章视频范式的对称面。
