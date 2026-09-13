# Z 章 · 图片管线：单帧视频的边界情况

> 源码版本：ffmpeg master commit 9f63b36a。所有行号均已用 grep -n / Read 实际核对。
> 本章回答一个问题：**一张图片如何被塞进"视频流"的心智模型，又在哪里偏离了它。**

---

## 1. 全景：图片在 FFmpeg 里的身份 = 单帧流

FFmpeg 没有独立的"图片子系统"。一张 PNG/JPEG/GIF 在内部就是一个：
- **一路视频流（1 个 AVStream）+ 每帧一个独立 AVPacket** 的"视频"；
- 时间戳要么由 framerate 合成，要么由文件格式自带的帧时长（GIF delay / APNG fcTL / WebP ANMF）给出；
- 像素格式走 RGB/灰度/pal8 路线（JPEG 例外，走 YUV 全 range）。

把"一组编号文件"变成"一路视频流"的是 image2 demuxer 家族，其装配链如下：

```
                      ┌─ img2dec.c: ff_img_tags 扩展名表 (img2.c:29-99)
 用户输入 img%03d.png ─┤
                      ├─ ff_img_read_header (img2dec.c:171)
                      │    ├─ is_pipe 判定: AVFMT_NOFILE→文件序列, 否则 pipe (196-201)
                      │    ├─ framerate → time_base (211-213)
                      │    ├─ find_image_range: 探测首号+倍增找尾号 (98-152)
                      │    └─ codec 选择: 逐 demuxer probe → 扩展名兜底 (285-325)
                      │
                      ▼
        ff_img_read_packet (img2dec.c:364) ── 每个 pkt = 完整打开一个文件
                      │      pkt->pts = s->pts++; pkt flags |= KEY (473-474, 539)
                      ▼
        解码器: pngdec / mjpegdec / gifdec / webp.c ── 一包一图,无帧间预测依赖
```

单文件图片则走 `image_<fmt>_pipe` 自动 demuxer 宏（img2dec.c:1192-1252）：`jpeg_probe` 对完整 JPEG 给 AVPROBE_SCORE_EXTENSION+1=51（img2dec.c:803-804），压过 image2 的扩展名分 50，于是"单张 jpg"实际由 `image_jpeg_pipe`（img2dec.c:1225，raw_codec_id=MJPEG）接管。

支持动画的格式另有专属 demuxer：`apng`（libavformat/apngdec.c）、`gif`（libavformat/gifdec.c）、`webp`/`webp_anim`（libavformat/webp_anim_dec.c）；GIF/WebP/APNG 的"动图"本质是**容器层把帧时长翻译成 pkt->duration，解码层仍每包一帧**。TIFF/BMP/DPX/EXR/PSD/QOI 等静态格式与 PNG 同构（单帧、probe+raw_codec_id），不展开。

---

## 2. image2 专节：%d 序列展开——把文件系统当容器

### 2.1 pattern 判定与文件枚举

`VideoDemuxData` 定义了全部状态：img_first/img_last/img_number/pts/pattern_type（img2.h:40-63），pattern 枚举 PT_GLOB/PT_SEQUENCE/PT_NONE/PT_DEFAULT（img2.h:33-38）。

header 阶段先决定模式：`PT_DEFAULT` 在有 pb 时降级为 PT_NONE、无 pb 时升级为 PT_SEQUENCE（img2dec.c:221-227）。PT_SEQUENCE 用 `find_image_range` 做两段式枚举（img2dec.c:98-152）：

```c
/* img2dec.c:106-113 从 start_number 起线性试探首个存在文件 */
for (first_index = start_index;
     first_index < start_index + start_index_range; first_index++) {
    ret = ff_bprint_get_frame_filename(&filename, path, first_index, 0);
    if (avio_check(filename.str, AVIO_FLAG_READ) > 0)
        break;
}
/* img2dec.c:120-145 尾号用"倍增+回退"探测,上限 1<<30 */
for (;;) {
    range = 0;
    for (;;) {
        if (!range) range1 = 1; else range1 = 2 * range;
        ret = ff_bprint_get_frame_filename(&filename, path, last_index + range1, 0);
        if (avio_check(filename.str, AVIO_FLAG_READ) <= 0) break;
        range = range1;
        if (range >= (1 << 30)) { ret = AVERROR(EINVAL); goto fail; }
    }
    if (!range) break;
    last_index += range;
}
```

`%d` 展开的真正实现是 `ff_bprint_get_frame_filename`（libavformat/utils.c:293-342）：遇到 `%[0-9]*d` 时按 `av_bprintf(buf, "%0*d", nd, number)` 做零填充（utils.c:325），负数额外加一位符号宽度（utils.c:323-324）；**路径里没有 %d 直接判 EINVAL**（utils.c:335-336），这就是 muxer 报"missing pattern"的源头。`av_filename_number_test` 即"能否用该函数展开 number=1"（utils.c:121-129）。

找到范围后写入流时长：`st->duration = last_index - first_index + 1`（img2dec.c:266-269）。PT_GLOB 则用系统 glob 一次枚举（img2dec.c:241-256）。

### 2.2 framerate 合成时间戳

图片文件本身无时间概念，image2 的默认答案是"均匀 25fps"：

```c
/* img2dec.c:211-213 */
avpriv_set_pts_info(st, 64, s->framerate.den, s->framerate.num);
st->avg_frame_rate = st->r_frame_rate = s->framerate;
```

framerate 默认 25（img2dec.c:588），time_base = 1/framerate，于是每个 pkt 的 pts 就是读包计数 `s->pts++`（img2dec.c:539，赋值在 489）。备选方案 `ts_from_file`：用文件 mtime 当 pts（秒或纳秒精度，img2dec.c:475-487），并把 (序号→mtime) 塞进 index entry 以支持 seek（img2dec.c:487、565-583，seek 的取模循环在 580）。

### 2.3 读包：每帧一次 avio 打开

`ff_img_read_packet`（img2dec.c:364）核心动作：

- 按 pattern 生成文件名（PT_NONE 直接用 url、glob 取 gl_pathv、sequence 走 %d 展开，img2dec.c:382-394）；
- `s1->io_open` 打开文件、`avio_size` 取长度、读完即关（img2dec.c:399-418, 517-518）；
- pkt 打上 `AV_PKT_FLAG_KEY`（img2dec.c:474）——每张图都是关键帧；
- codec 未定时用第一帧内容再 probe 一次（img2dec.c:421-442）；RAWVIDEO 无尺寸时用 `infer_size` 按面积猜（img2dec.c:62-87, 444-445）；
- 彩蛋：`.y` 扩展名触发 **split_planes**，按 Y/U/V（+A）各开一个文件，文件名尾字符依次替换为 'U'/'V'/'A'（img2dec.c:283, 417；img2enc.c:105-110, 277, 281-298）。

### 2.4 pipe 模式：单帧路径

image2pipe 及全部 `image_*_pipe` demuxer 没有 AVFMT_NOFILE（img2dec.c:642-650, 1194-1204），因此 header 里 `is_pipe=1` 且 `need_parsing = AVSTREAM_PARSE_FULL`（img2dec.c:196-201）。读包时不再开文件，直接吃 pb：有 frame_size 用之；无 parser 时一次读完整个流；否则按 4096 块喂 parser 切帧（img2dec.c:446-459）。这就是 `cat a.jpg b.jpg | ffmpeg -f image2pipe -i -` 能出两帧的机制：**parser 负责 JPEG 帧边界，demuxer 只搬运字节**。

### 2.5 muxer：每帧一文件

img2enc.c 的 `write_packet`（img2enc.c:199）四选一生成文件名：update（覆盖单文件，213-214）、strftime（215-220）、frame_pts（用 pts 命名，221-226）、默认 %d+img_number（227-229）。首个包若发现路径无 %d 会警告并退化为单文件名；**第二个包再撞同名则直接报错**，提示缺 `-update` 或序列 pattern（img2enc.c:230-240）。GIF/FITS/AV1 的 codec 会内嵌转发到同名 muxer（img2enc.c:97-102, 140-176），`atomic_writing` 用 .tmp+rename 保证原子性（img2enc.c:249-255, 309-315）。image2 muxer 声明 `AVFMT_NOTIMESTAMPS`（img2enc.c:404）——时间戳在文件名里，不在容器里。

---

## 3. PNG 专节：块流、行过滤与 APNG

### 3.1 块流解析

PNG 解码是"单状态机 + chunk 循环"。`decode_frame_common`（pngdec.c:1493）逐 chunk 读：4 字节长度 + 4 字节 tag + payload + CRC（pngdec.c:1526-1547），CRC 校验仅在 `AV_EF_CRCCHECK` 时做（pngdec.c:1532-1546）。IHDR 解析校验 bit_depth ∈ {1,2,4,8,16}（pngdec.c:702-707）。像素格式由 color_type×bit_depth 查表决定（pngdec.c:920-954），pal8 输出 256 色 palette 到 data[1]（pngdec.c:1038-1039）；tRNS 会把 RGB24 升格 RGBA（pngdec.c:956-982），解压后再逐像素展开透明（pngdec.c:1768-1810）。zlib 数据在 `png_decode_idat` 里用 inflate 逐行吐出（pngdec.c:422-451），每满一行回调 `png_handle_row`（pngdec.c:341-420），Adam7 隔行用 7 个 pass 的位掩码拼装（pngdec.c:134-147, 378-418）。

### 3.2 行过滤器：5 种反滤波

每行首字节是 filter 类型，`ff_png_filter_row`（pngdec.c:260-313）实现 None/Sub/Up/Avg/Paeth 五种：

```c
/* pngdec.c:269-294 (节选) */
case PNG_FILTER_VALUE_SUB:
    for (i = 0; i < bpp; i++) dst[i] = src[i];
    ...
    p = ((s & 0x7f7f7f7f) + (p & 0x7f7f7f7f)) ^ ((s ^ p) & 0x80808080);  /* 4bpp SIMD 展开 */
    break;
case PNG_FILTER_VALUE_UP:
    dsp->add_bytes_l2(dst, src, last, size);        /* 上行累加,走 pngdsp */
    break;
case PNG_FILTER_VALUE_AVG:
    ... dst[i] = ((((x)+(l))>>1) + (s)) & 0xff;     /* 左/上均值预测 */
case PNG_FILTER_VALUE_PAETH:
    dsp->add_paeth_prediction(dst + i, src + i, last + i, size - i, bpp);
```

编码端对称：`png_choose_filter`（pngenc.c:205-232）支持 MIXED 模式——**每行把 5 种滤镜都算一遍，按 |int8| 代价和最小者入选**（pngenc.c:214-228）。zlib 压缩在 `png_write_row`/`png_write_image_data` 中边 deflate 边切 IDAT（pngenc.c:255-282, 283-306），IHDR/pHYs 等头块由 `encode_headers` 写出（pngenc.c:378-394）。

### 3.3 APNG：fcTL 时序如何映射成"正常视频帧序列"

APNG 复用 PNG 块语法加三种块：acTL（帧数+播放次数）、fcTL（帧几何+时长+dispose/blend）、fdAT（带序列号的帧数据）。解码器侧（AV_CODEC_ID_APNG）：

- **extradata 承载静态头**：demuxer 把 PNGSIG 到首个 fcTL 之前的全部 chunk 塞进 extradata（apngdec.c:182-191, 213-222），APNG 解码器首包前先解 extradata 里的 IHDR/acTL（pngdec.c:1943-1952）；
- **每个包 = fcTL + 若干 fdAT**：demuxer 在 `apng_read_packet` 把一个 fcTL 到下一个 fcTL/IEND 之间的数据拼成一个 pkt（apngdec.c:337-388）；
- **时间戳在 demuxer 生成**：time_base 固定 1/100000（apngdec.c:172-174），fcTL 的 delay_num/delay_den（den=0 视为 100）经 `av_rescale_q` 变成 pkt->duration（apngdec.c:256-264），pkt 的 pts/dts 保持 NOPTS 由通用层按 duration 累加（apngdec.c:386-387）；
- 解码器用 `decode_fctl_chunk` 校验几何/blend（pngdec.c:1295-1364；首帧 PREVIOUS 降级为 BACKGROUND，1338-1343），随后按 overlay 语义合成：先拷贝上帧未变区域，再对 OVER 混合做 alpha 合成（`handle_p_frame_apng`，pngdec.c:1388-1475；FAST_DIV255 近似除法在 1386），DISPOSE_OP_BACKGROUND 在输出后把矩形抹黑（`apng_reset_background`，pngdec.c:1477-1491, 1827-1828）。pal8 在 APNG 下直接输出 RGBA 以便混合（pngdec.c:940, 1752-1765）。
- fdAT 与 IDAT 的差别只是多了 4 字节序列号，解码器剥掉后走同一条 inflate 路径（pngdec.c:1589-1603，序列号读取在 1596）；编码端对应 `png_write_image_data` 的 IDAT/fdAT 分叉（pngenc.c:255-282），fcTL 的 delay 留给 muxer 回填（pngenc.c:1087-1088）。

一句话：**APNG 把"帧间叠加关系"留在解码器，把"帧节奏"放在 demuxer，于是上层看到的仍是一条 pts 单调、每帧 KEY 标记由 is_key_frame 决定（apngdec.c:297-302, 384-385）的普通视频流。**

---

## 4. MJPEG 专节：自带容器的"视频编解码器"

### 4.1 每帧 = 完整 JPEG

MJPEG 的特殊性：它没有容器却自带全部同步信息——每个帧都以 SOI(0xFFD8) 开头、EOI(0xFFD9) 结尾，量化表/Huffman 表随帧携带。解码主循环 `ff_mjpeg_decode_frame_from_buf`（mjpegdec.c:2394）逐 marker 分发（2421-2624）：SOI(2485)、DHT(2491)、SOF0/1 基线(2497)、SOF2 渐进(2509)、SOF3 无损(2517)、SOF55 JPEG-LS(2525)、SOS 扫描(2580)、EOI 出帧(2540-2579)。**遇到第一个 EOI 就 av_frame_ref 并返回**（mjpegdec.c:2564-2579）——一次 decode 调用只产出一帧，这就是"每帧独立 JPEG"的实现点；若流里缺 EOI 还会补一个"emulating"（2625-2628）。Huffman 解码是逐 bit 的 VLC 查表：`mjpeg_decode_dc` 用 get_vlc2（mjpegdec.c:840-852），块内 DC 差分累加 `last_dc`（decode_block，mjpegdec.c:855-867）；SOS 数据先经 `ff_mjpeg_unescape_sos` 做 0xFF00 去填充（mjpegdec.c:2251-2378）。SOF 里 h/v 采样因子拼成 pix_fmt_id 决定 420/422/444 等格式（mjpegdec.c:506-509, 553-716）。流式输入靠 `ff_mjpeg_parser` 按 0xFFD8+marker / 0xFFD9 切帧（mjpeg_parser.c:41-103, 132-137）；HTTP 摄像机的 multipart 流另有 mpjpeg demuxer（libavformat/mpjpegdec.c:110 起）。

### 4.2 yuvj full-range 的历史包袱

JPEG 的 YUV 按定义是 full-range（0-255），而广播视频是 limited-range（16-235）。FFmpeg 早期直接造了 YUVJ* 像素格式族来表达"YUV+full-range"，后来被标记废弃：

```c
/* libavutil/pixfmt.h:85-87 */
AV_PIX_FMT_YUVJ420P, ///< planar YUV 4:2:0, 12bpp, full scale (JPEG),
                     ///< deprecated in favor of AV_PIX_FMT_YUV420P and setting color_range
```

mjpegdec 至今双轨并存：`cs_itu601` 为假时仍输出 YUVJ420P 并设 `color_range = AVCOL_RANGE_JPEG`，为真时输出 YUV420P+MPEG range（mjpegdec.c:694-696，444/422 同理见 553-555, 617-618, 661-663）。JFIF 头里的 SAR 也在此解析（mjpegdec.c:1885-1908），Adobe APP14 的 transform 决定 YUV→RGB 变换（mjpegdec.c:1923-1940），Exif 走 APP1（mjpegdec.c:2033-2044）。对色彩管理的影响（呼应第 15 章）：**同一像素值，挂在 YUVJ420P 上没人再解释 range（格式名即语义），挂在 YUV420P+color_range=JPEG 上才是现代正解**——转码管线若不透传 color_range，JPEG 转 yuv420p 视频就会发灰，这正是 yuvj 遗产在日常"图片变视频"工作流里最经典的翻车点。

---

## 5. GIF/WebP 专节：disposal、透明与每帧 delay

### 5.1 GIF：LZW 与 disposal 状态机

GIF 解码器输出固定 RGB32（gifdec.c:461）。每帧流程（`gif_read_image`，gifdec.c:133-317）：读 9 字节 Image Descriptor 得子矩形（146-153）→ 可选局部调色板（157-172）→ **先执行上一帧遗留的 disposal**（218-244：BACKGROUND 把上次矩形填 stored_bg_color，RESTORE 从 stored_img 恢复）→ LZW 初始化（251-256）→ 逐行解码、跳过透明索引写 palette 值（264-277）→ 交错行序 8/4/2 重排（279-300）。GCE 扩展里解析透明索引与 disposal（gifdec.c:333-362）——注意 **解码器把 2 字节 delay 直接 skip 掉**（gifdec.c:344），且 GCE 作用域单帧，用完即重置（311-314）。

那么动图节奏从哪来？**三层协作**：

1. 容器层 demuxer（libavformat/gifdec.c）预扫整个文件：time_base 固定 1/100（gifdec.c:225），累加每帧 GCE delay 得总 duration 与 avg_frame_rate（gifdec.c:162-176, 231-238），同时读 NETSCAPE2.0 扩展的循环次数、0 表示无限（gifdec.c:186-199）；读到 EOF 且未到循环上限就 seek 回 0（gifdec.c:252-256）。
2. 解析层 gif parser 按 block 语法切帧并**把 GCE delay 写进 parser 的 duration**：`s->duration = g->delay ? g->delay : 10`（gif_parser.c:139-145, 194），默认 10（=0.1s），对应"浏览器把无 delay/过小 delay 的 GIF 按 ~10fps 播放"的民间事实标准（libavformat/gifdec.c:62-71 的 GIF_DEFAULT_DELAY=10、GIF_MIN_DELAY=2）。
3. demuxer 的读包只按 1024 字节切块搬运（gifdec.c:257-267），帧边界完全由 parser 决定（`need_parsing = AVSTREAM_PARSE_FULL_RAW`，gifdec.c:226）。

透明色方面：解码端透明像素"不写"画布即保留底色（gifdec.c:274-277），无法保留时用选项 `trans_color`（默认透明白 0x00ffffff，gifdec.c:33-37, 536-542）兜底。编码端（libavcodec/gif.c）每帧选 disposal：半透明帧用 GCE_DISPOSAL_BACKGROUND，否则 INPLACE（gif.c:315-321），GCE 写入 disposal<<2|透明标志 并预置 delay=5（gif.c:370-377）；**循环次数属于容器**，由 libavformat/gif.c muxer 在首个 GCE 前插入 NETSCAPE2.0 块（gif.c:127-136），并按输出帧 pts 差改写真实 delay（gif.c:77-87, 139-153，time_base 1/100 在 gif.c:45）。

### 5.2 WebP：VP8/VP8L 与动图支持程度

webp 解码（libavcodec/webp.c）是 RIFF 块循环（webp.c:1344-1580）：`VP8 ` 有损→调用内嵌 VP8 解码器（1394-1403）；`VP8L` 无损→自实现 Huffman/前缀码（vp8_lossless_decode_frame，1095 起）；`ALPH` 通道本身可再用 VP8L 压缩（1447-1454, 1257-1277）。**静态 webp 解码器遇到 ANIM/ANMF 直接跳过并警告"skipping unsupported chunk"（webp.c:1513-1518）——单帧 webp 不解动画**。动画由独立解码器 `webp_anim`（webp.c:1596 起）接管：ANMF 头解析出子矩形、flags（dispose/no-blend）、24bit duration（webp.c:2003-2028，duration 读取在 2018，写入 p->duration 在 2138），画布合成在 ARGB 或 YUVA420P 上做 alpha 混合（blend_subframe_into_canvas，webp.c:1835-1901）。demuxer 侧（libavformat/webp_anim_dec.c）检查 VP8X 的 ANIMATION 位（webp_anim_dec.c:96），读 ANIM 的循环计数（191），把 ANMF duration 钳到 [min_delay,max_delay] 后赋 pkt->duration（279-282）。TIFF/BMP/DPX/EXR/QOI 等仅列名：均为单帧 probe+解码，结构上同 PNG 而无动画层。

---

## 6. 与视频管线的差异总结表

| 维度 | 普通视频 (mp4/mkv/ts) | image2 序列 | PNG/APNG | MJPEG | GIF | WebP(anim) |
|---|---|---|---|---|---|---|
| 时间戳来源 | 容器显式 pts/dts | framerate 合成 pts=计数 (img2dec.c:489,539) / ts_from_file=mtime | demuxer 由 fcTL delay 算 duration，pts 累加 (apngdec.c:262-264,386-387) | 无原生时间，容器/解析器给 | parser 写 duration=delay，tb=1/100 (gif_parser.c:194) | ANMF duration→pkt->duration (webp_anim_dec.c:279-282) |
| 帧边界 | 容器 sample 边界 | 一个文件=一包 (img2dec.c:399-418) | fcTL..fcTL 拼包 (apngdec.c:337-388) | SOI..EOI，parser 切 (mjpeg_parser.c:41-103) | block 语法，parser 切 (gif_parser.c:54-171) | RIFF 块 (webp.c:1380-1392) |
| 像素格式 | YUV limited 为主 | 随图 | RGB/灰度/pal8/RGBA，range=JPEG (pngdec.c:844-846) | YUVJ full-range 包袱 (mjpegdec.c:694-696) | RGB32 固定 (gifdec.c:461) | YUV420P/ARGB/YUVA420P (webp.c:1835+) |
| 封装 | 索引+交错+全局头 | **文件系统即容器**（%d 展开枚举） | extradata 存静态头，帧=fcTL+fdAT (apngdec.c:182-191) | 无封装，表随帧带 (DHT/DQT) | 全局调色板+GCE 前置于帧 | RIFF 块 |
| 帧间依赖 | I/P/B | 无 | APNG 有 overlay/dispose 依赖 (pngdec.c:1812-1828) | 无 | disposal 依赖 (gifdec.c:218-244) | 画布混合依赖 (webp.c:1835) |
| 关键帧 | 周期性 | 每帧 KEY (img2dec.c:474) | is_key_frame 判定 (apngdec.c:297-302) | 每帧即 I 帧 | 首帧带签名者 (gifdec.c:479-484) | 首帧 |

---

## 7. 设计动机

1. **为什么图片不走"普通 demuxer 统一路径"？** 因为图片没有"容器"可解——除动图外，文件即一帧。FFmpeg 的选择是造一个把 I/O 层当容器的 demuxer（image2：AVFMT_NOFILE、每包一文件），而不是给每种图片造一百个真 demuxer；单文件场景再由 `image_*_pipe` 宏批量生成 37 个"内容 probe→raw_codec_id"的薄 demuxer（img2dec.c:1192-1252），probe 函数与 demuxer 同文件共存，维护成本极低。
2. **序列图片作为视频管线的工程价值**：一旦 %d 文件组被抬升成"一路 25fps 视频流"，下游的 filter/encode/mux 全部零改动复用——帧提取（视频→%04d.png）、延时摄影（序列→H.264）、转 GIF 都是同一管线的正反向。`ts_from_file`、`export_path_metadata`（pkt 侧数据带源路径，img2dec.c:342-362, 500-504）进一步让"文件元数据"冒充流元数据。
3. **像素格式的历史包袱**：JPEG 的 full-range YUV 在 FFmpeg 早期没有 color_range 元数据可用，于是物化成 YUVJ* 格式（pixfmt.h:85-87 已废弃）；GIF 用 RGB32 而非 pal8，是为让"透明保留"语义简单（不写即保留）；APNG 的 pal8 被升格 RGBA 也是同理（pngdec.c:940）。图片管线是观察"格式语义→像素格式选择"倒逼的活化石。

---

## 8. FAQ 素材

1. `ffmpeg -i 1.jpg` 和 `-i img%d.jpg` 走的是同一个 demuxer 吗？——不是：单文件命中 `image_jpeg_pipe`（probe 51 分，img2dec.c:803-804,1225），带 %d 的命中 `image2`（probe 满分，img2dec.c:156-158）。
2. 序列起始编号不是 0/1 怎么办？——`-start_number`（demuxer 默认 0，img2dec.c:600；muxer 默认 1，img2enc.c:376，两边默认值不同是常见坑），探测窗口 `-start_number_range` 默认 5（img2dec.c:601）。
3. 序列中间缺号会怎样？——find_image_range 用 avio_check 逐个试探（img2dec.c:111,132），缺号即被当作序列结束。
4. 图片输出的"帧率"是什么？——默认 25fps 的时间戳合成（img2dec.c:211-213,588），纯节奏概念，与文件内容无关。
5. 为什么导出图片要小心 `-update`？——无 %d pattern 时第二帧起直接报错（img2enc.c:237-240），加 `-update 1` 才是"持续覆盖单文件"。
6. GIF 转 mp4 速度不对？——GIF delay 语义在 parser 层（gif_parser.c:194，缺省 10cs），低于 2cs 视为无效（gifdec.c:71），浏览器与 FFmpeg 对"无 delay"的补偿策略一致（10fps，gifdec.c:62-67）。
7. APNG 的 pts 为什么全是 NOPTS？——demuxer 只给 duration，pts 由通用层累加（apngdec.c:386-387）。
8. 单个 webp 文件里带动画为什么解不出来？——静态 webp 解码器显式跳过 ANIM/ANMF（webp.c:1513-1518），须用 webp_anim 解码器。
9. JPEG 转视频后颜色发灰？——yuvj full-range vs color_range 透传问题（mjpegdec.c:694-696, pixfmt.h:85-87）。
10. `img%03d.png` 支持 glob 吗？——`-pattern_type glob`（非 Windows 构建，img2dec.c:241-256）。

## 9. 深挖题

1. **`ff_png_filter_row` 的 SUB 分支为何对 bpp==4 手写 0x7f7f7f7f 加法**（pngdec.c:272-278）？——用无符号按字节并行的加法避免逐字节进位，等价于 SIMD 化的Per-byte mod-256 加法；对照编码端 pngdsp 的 add_bytes_l2/add_paeth_prediction 体系。
2. **APNG DEMUXER 与 DECODER 各自实现了一遍 decode_fctl_chunk**（apngdec.c:238-306 vs pngdec.c:1295-1364），校验规则却不同（demuxer 还负责 is_key_frame 判定）——分析为什么这份逻辑不能共享：容器需要"拼包边界"，解码器需要"合成语义"。
3. **MJPEG 一次 decode 只消费到第一个 EOI**（mjpegdec.c:2564-2579）——推演 `-f image2pipe` 与 avi/mjpeg 容器下同一解码器如何分别靠 image2 pipe 路径（每包一图）与 mjpeg_parser（流内切帧）满足此假设。
4. **GIF 的三层时间体系**：demuxer 预扫 duration（gifdec.c:147-215）、parser 逐帧 duration（gif_parser.c:194）、muxer 按 pts 差回写 delay（gif.c:77-87）——若三者对"delay=0"处理不一致会发生什么？
5. **img2enc 的 split_planes**（img2enc.c:281-298）：按平面切割裸 YUV 写 .y/.u/.v 文件——它与 rawvideo muxer 的边界在哪里，为什么放在 image2 里？

---

## 写作要点速查表（函数:行号）

| 主题 | 位置 |
|---|---|
| %d 展开/零填充/无 %d 报错 | libavformat/utils.c:293-342（填充 325，fail 335-341） |
| 序列首号探测+倍增找尾号 | libavformat/img2dec.c:98-152（首 106-113，尾 120-145） |
| image2 probe：编号测试/扩展名分 | libavformat/img2dec.c:154-169 |
| header：is_pipe/need_parsing/framerate→tb | libavformat/img2dec.c:171-227（196-201,211-213） |
| glob/sequence/none 分支+流时长 | libavformat/img2dec.c:228-270 |
| codec 选择：probe 循环→扩展名兜底 | libavformat/img2dec.c:281-330（285-323,324-325） |
| 读包：生成文件名/io_open/KEY/pts++ | libavformat/img2dec.c:364-541（389,405,474,539） |
| pipe 读包：frame_size/4096 块 | libavformat/img2dec.c:446-459 |
| image2/image2pipe demuxer 定义 | libavformat/img2dec.c:616-627 / 641-650 |
| 37 个 image_*_pipe 自动宏 | libavformat/img2dec.c:1192-1252 |
| 扩展名→codec 表 str2id | libavformat/img2.c:29-99,110-129 |
| muxer：%d 缺失警告/同名报错 | libavformat/img2enc.c:199-242（230-240） |
| muxer：frame_pts/strftime/atomic | libavformat/img2enc.c:213-229,249-255,309-315 |
| image2 muxer 定义 NOTIMESTAMPS | libavformat/img2enc.c:393-407 |
| PNG chunk 主循环+CRC | libavcodec/pngdec.c:1493-1571（1526-1547） |
| 5 种行过滤器 | libavcodec/pngdec.c:260-313 |
| IHDR 校验/pixfmt 选择 | libavcodec/pngdec.c:690-728 / 920-954 |
| IDAT inflate 逐行 | libavcodec/pngdec.c:422-451 |
| fcTL 解析/dispose 降级 | libavcodec/pngdec.c:1295-1364（1338-1343） |
| APNG overlay 合成/背景重置 | libavcodec/pngdec.c:1388-1475,1477-1491,1812-1828 |
| png/apng decode 入口 | libavcodec/pngdec.c:1877-1931 / 1935-1980 |
| 编码端滤镜竞选(MIXED) | libavcodec/pngenc.c:205-232 |
| IDAT vs fdAT/序列号 | libavcodec/pngenc.c:255-282（267-279） |
| APNG demuxer：extradata/时长/拼包 | libavformat/apngdec.c:149-236,238-306,308-397（262-264,386-387） |
| MJPEG marker 主循环/EOI 出帧 | libavcodec/mjpegdec.c:2394-2628（2540-2579,2625-2628） |
| SOF 采样因子→pixfmt/range | libavcodec/mjpegdec.c:310-509,553-716（694-696） |
| DHT/Huffman VLC/DC 差分 | libavcodec/mjpegdec.c:251-308,840-867 |
| SOS 去填充 unescape | libavcodec/mjpegdec.c:2251-2378 |
| JFIF/Adob/Exif APP 解析 | libavcodec/mjpegdec.c:1885-1908,1923-1940,2033-2044 |
| mjpeg parser 切帧 | libavcodec/mjpeg_parser.c:41-103,132-137 |
| GIF 解码：disposal/透明/LZW | libavcodec/gifdec.c:133-317（218-244,274-277,344） |
| GIF parser：delay→duration | libavcodec/gif_parser.c:139-145,194 |
| GIF demuxer：预扫/循环/1/100 | libavformat/gifdec.c:62-71,114-244,252-256 |
| GIF 编码：disposal 选择/GCE | libavcodec/gif.c:292-377（315-321,370-377） |
| GIF muxer：NETSCAPE/delay 回写 | libavformat/gif.c:45,77-87,127-136 |
| WebP：RIFF 循环/VP8L/ALPH | libavcodec/webp.c:1344-1580（1394-1413,1427-1457） |
| WebP 静态解码跳过 ANIM/ANMF | libavcodec/webp.c:1513-1518 |
| webp_anim：ANMF duration/混合 | libavcodec/webp.c:1596-1620,2003-2028,2138,1835-1901 |
| webp_anim demuxer：loop/时长钳制 | libavformat/webp_anim_dec.c:96,131,191,279-282 |
| yuvj 废弃注记 | libavutil/pixfmt.h:85-87,107,283 |
