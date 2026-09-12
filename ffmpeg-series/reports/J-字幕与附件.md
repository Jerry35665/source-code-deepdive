# J - 字幕与附件管线深读

> 仓库:ffmpeg master(commit 9f63b36a)。所有行号为仓库相对路径下的实际核对行号。

---

## 1. 全景:字幕的三重身份与结构性差异

字幕在 FFmpeg 中走的是一条与音视频完全不同的数据通路。音视频是"packet → AVFrame → 滤镜/编码"的流式管线;字幕则是"packet → **AVSubtitle**(非 AVFrame)→ 渲染/再编码"。一个字幕 codec 同时有三种身份:

- **demuxer 身份**:文本字幕(SRT/ASS/VTT)在 `read_header` 里把整个文件读完,排进队列,之后 `read_packet` 只是从队列里依次吐 packet;
- **decoder 身份**:字幕解码器不是把数据解成像素帧,而是填一个 `AVSubtitle` 结构(文本或位图矩形集合);
- **滤镜/编码器身份**:libass 滤镜 `subtitles` 自己打开字幕文件、自己 demux+decode;字幕编码器把 `AVSubtitle` 的 ASS 文本拆回纯文本格式。

```
         音视频通路(流式)                      字幕通路(文本字幕为"全量读+队列")
 ┌──────────────────────────────┐      ┌────────────────────────────────────────────────┐
 │ read_packet() 按需产出 packet │      │ read_header() 一次读全文件                        │
 │        │                     │      │   srtdec.c:129-215 / assdec.c:115-171           │
 │        ▼                     │      │        │                                        │
 │  decode → AVFrame            │      │        ▼                                        │
 │        │                     │      │  FFDemuxSubtitlesQueue(排序/补时长/去重)          │
 │        ▼                     │      │   subtitles.c:212 ff_subtitles_queue_finalize    │
 │  avfilter / encode           │      │        │                                        │
 └──────────────────────────────┘      │        ▼  read_packet 逐个 ref 出队               │
                                       │   subtitles.c:230 queue_read_packet              │
                                       │        │                                        │
                                       │        ▼  avcodec_decode_subtitle2               │
                                       │   decode.c:935(回调 cb.decode_sub)               │
                                       │        │                                        │
                                       │        ▼  AVSubtitle{rects[]}  ← 不是 AVFrame    │
                                       │   ┌────────────┬──────────────────┐             │
                                       │   │ SUBTITLE_ASS│ SUBTITLE_BITMAP  │             │
                                       │   │ 文本→libass │ 位图→直接叠加      │             │
                                       │   └────────────┴──────────────────┘             │
                                       │        │            编码:cb.encode_sub           │
                                       │        ▼            srtenc.c:229 / assenc.c:44  │
                                       └────────────────────────────────────────────────┘
```

命令行工具 ffmpeg 甚至用一个 hack 把 `AVSubtitle` 塞进 `AVFrame`:fftools/ffmpeg_dec.c:536 `subtitle_wrap_frame()` 把 AVSubtitle 挂到 `frame->buf[0]` 的 AVBufferRef 上,注释直言"eventually, subtitles should be switched to use AVFrames natively"(ffmpeg_dec.c:676-679)。CLI 的解码分发也按类型分流:packet_decode 里 `AVMEDIA_TYPE_SUBTITLE` 独占一条路径进 `transcode_subtitles`(ffmpeg_dec.c:698-699);后者调 `avcodec_decode_subtitle2`(660-661),再走 wrap→process_subtitle→`sch_dec_send` 送下游(680-689)。子2视频(sub2video)场景下 demuxer 还会对视频流每包向字幕流注入 heartbeat 包,用于推进 `-fix_sub_duration`(ffmpeg_demux.c:692-706;ffmpeg_dec.c:612-632;流上标记 `have_sub2video` ffmpeg_demux.c:80)。

---

## 2. 文本字幕队列模式专节:为什么必须"一次读完"

SRT/ASS/VTT 三个 demuxer 共享同一个骨架:上下文里只有一个 `FFDemuxSubtitlesQueue`(srtdec.c:30-32、assdec.c:31-34、webvttdec.c:35-39),`read_header` 全量解析,`read_packet`/`read_seek` 直接复用通用实现(srtdec.c:224-225,assdec.c:180-182,webvttdec.c:226-227)。

**核心原因一:packet 需要结束时间戳,而结束时间要看下一条事件。**
SRT 文件里每条字幕只有起止时间,但解析是逐行的:读到第 N+1 条的时间行,才能确定第 N 条内容结束了(间或夹着纯数字的行,无法区分是"序号"还是"正文")。srtdec.c 的处理是把可疑的数字行先缓存到 `line_cache`,等看到下一条时间行再决定它是 payload 还是序号(srtdec.c:175-182,注释 "we can't be sure of this yet, so we cache it");最后一条事件在文件尾强制 flush(注释:"a trailing number is more likely to be genuine",srtdec.c:201-208)。

**核心原因二:文件内事件顺序不可信,需要全局排序+补时长。**
`ff_subtitles_queue_finalize`(subtitles.c:212-228)做三件事:
1. `qsort` 按 pts(或 pos 再 pts,`sub_sort` 枚举见 subtitles.h:30-32,比较器 subtitles.c:164-183);
2. 给 `duration < 0` 的包用**下一条的 pts 减去自己的 pts** 兜底(subtitles.c:222-224)——这只有在知道"下一条"时才可能,是"必须全量读"的最直接证据;
3. 去重 `drop_dups`(subtitles.c:185-210),除非 `keep_duplicates`(assdec.c:135 特意设了 1)。

**核心原因三:seek 也依赖全局队列。**
`ff_subtitles_queue_seek`(subtitles.c:269-319)在已排序数组上二分(`search_sub_ts`,subtitles.c:247-267),再回扫处理"跨 seek 点仍在显示的重叠字幕"(subtitles.c:295-305)。这本质是内存版的索引 seek,无需读盘。

队列生命周期:`ff_subtitles_queue_insert`(subtitles.c:111-154,新事件 `av_new_packet` 并置 `AV_PKT_FLAG_KEY`)→ finalize → `read_packet` 里 `av_packet_ref` 后 `current_sub_idx++`(subtitles.c:230-245)→ `read_close` 统一 `ff_subtitles_queue_clean`(subtitles.c:321-329)。三个通用包装 `ff_subtitles_read_packet/read_seek/read_close` 在 subtitles.c:331-350。

字符编码问题也在入口解决:`FFTextReader` 自动识别 UTF-16LE/BE 与 UTF-8 BOM 并转 UTF-8(subtitles.c:28-52,ff_text_r8 逐字符转码 subtitles.c:65-84):

```c
// libavformat/subtitles.c:65-84(节选)
int ff_text_r8(FFTextReader *r)
{
    uint32_t val;
    ...
    if (r->type == FF_UTF16LE) {
        GET_UTF16(val, avio_rl16(r->pb), return 0;)
    } else if (r->type == FF_UTF16BE) {
        GET_UTF16(val, avio_rb16(r->pb), return 0;)
    } else {
        return avio_r8(r->pb);
    }
    ...
    PUT_UTF8(val, tmp, r->buf[r->buf_len++] = tmp;)
    return r->buf[r->buf_pos++];
}
```

**三个 demuxer 的"全量读"各自的做法**(同构不同细节):

- **SRT**(srtdec.c:129-215):逐行状态机。时间行由 `get_event_info`(srtdec.c:73-93,sscanf 识别 `hh:mm:ss,ms --> hh:mm:ss,ms`,毫秒精度时间基 `1/1000` 见 143 行);正文行累积进 AVBPrint;歧义数字行走 `line_cache` 二次猜测(179-182);X1/X2/Y1/Y2 坐标转 side data(115-123)。
- **ASS**(assdec.c:115-171):`read_dialogue`(assdec.c:53-97)用 sscanf `"%d:%d:%d%*c%d,..."` 解析 Dialogue,时间基 **1/100**(assdec.c:127,centisecond 精度);每条 Dialogue 前缀重写为 `readorder,layer,`(assdec.c:85),readorder 计数器消除乱序文件的二义性;**非 Dialogue 行(含 duration<=0 的隐藏事件)全部并入 header**(assdec.c:146-148 与 75-82 注释)。
- **VTT**(webvttdec.c:61-174):按"块"(空行分隔)读取——`ff_subtitles_read_chunk`(subtitles.c:445-452)/`ff_subtitles_read_text_chunk`(402-443,遇两个连续换行停);跳过 WEBVTT/STYLE/REGION/NOTE 头块(96-101);cue identifier/settings 存 side data(154-166)而非丢掉,这是 WebVTT 往返(mkv→webvtt)保真的关键。

共享工具链还有:`ff_subtitles_read_line`(subtitles.c:454-474,处理 \r\n)、SMIL 解析辅助 `ff_smil_extract_next_text_chunk`/`ff_smil_get_attr_ptr`(subtitles.c:352-395,供 SAMI/RealText 用)。另注意 sort 策略的选择:SRT/ASS/VTT 默认 `SUB_SORT_TS_POS`(按时间),VobSub(idx 文件含显式文件位置)用 `SUB_SORT_POS_TS`,比较器 `cmp_pkt_sub_pos_ts`(subtitles.c:173-183)保证同 timestamp 取最小文件偏移,注释见 subtitles.c:307-314。

---

## 3. AVSubtitle / AVSubtitleRect 解剖

结构定义都在 libavcodec/avcodec.h,这不是 AVFrame——没有完整的时间戳/时间基语义、没有滤镜管线所需的元数据,只是一个"矩形集合 + 相对显示时间"。

```c
// libavcodec/avcodec.h:2041-2057
enum AVSubtitleType {
    SUBTITLE_NONE,
    SUBTITLE_BITMAP,   ///< A bitmap, pict will be set
    SUBTITLE_TEXT,     // text 字段权威,pict/ass 是近似
    SUBTITLE_ASS,      // ass 字段权威,pict/text 是近似
};
```

- `AVSubtitleRect`(avcodec.h:2061-2086):`x/y/w/h/nb_colors` 描述位图区域(2062-2066);`data[4]/linesize[4]` 装位图,注释明确 "Can be set for text/ass as well once they are rendered"(2069-2073);`flags` 可含 `AV_SUBTITLE_FLAG_FORCED`(2059);`type`(2076)三选一;`text`(2078)与 `ass`(2085)是互斥权威字段的 0 结尾字符串。
- `AVSubtitle`(avcodec.h:2088-2095):`format`(0=graphics/1=text)、`start_display_time`/`end_display_time`(**相对 packet pts 的毫秒数**)、`num_rects`+`rects[]`、`pts`(AV_TIME_BASE 单位,同 packet pts)。

三种 type 的实际来源:
- **SUBTITLE_ASS**:ass 解码器直通 packet 字符串(libavcodec/assdec.c:56-57 `rects[0]->ass = av_strdup(avpkt->data)`);SRT/VTT/text 等解码器先把文本转成 ASS 事件再填 ass 字段(libavcodec/srtdec.c:82 `ff_ass_add_rect`,textdec.c:59-60 经 `ff_ass_bprint_text_event` 转义);统一入口是 ff_ass_add_rect2(libavcodec/ass.c:119-157,`rect->type = SUBTITLE_ASS` 在 ass.c:151)。
- **SUBTITLE_BITMAP**:DVD/PGS/DVB 解码器填位图(见第 5 节)。
- **SUBTITLE_TEXT**:如今主要作为"近似"存在,内部解码器几乎都升级为 ASS。

```c
// libavcodec/assdec.c:43-62(最简字幕解码器:packet 字符串直通 ASS rect)
static int ass_decode_frame(AVCodecContext *avctx, AVSubtitle *sub,
                            int *got_sub_ptr, const AVPacket *avpkt)
{
    ...
    sub->rects = av_malloc(sizeof(*sub->rects));
    sub->rects[0] = av_mallocz(sizeof(*sub->rects[0]));
    sub->num_rects = 1;
    sub->rects[0]->type = SUBTITLE_ASS;
    sub->rects[0]->ass  = av_strdup(avpkt->data);
    ...
    *got_sub_ptr = 1;
    return avpkt->size;
}
```

注意 assdec.c 注册了**两个同名 id 的解码器** `ssa` 与 `ass`(libavcodec/assdec.c:65-72、76-84),id 都是 `AV_CODEC_ID_ASS`,行为完全一致——历史别名。同类"一码多名"还有 `srt`/`subrip`(libavcodec/srtdec.c:93-116,注释标明前者 deprecated)。裸 text 家族(text/vplayer/stl/pjs/subviewer1)则共享 `textdec.c` 的 `text_decode_frame`(textdec.c:49-67),仅 `linebreaks="|"` 的 init 差异(textdec.c:99-104)。

公共出口 `avcodec_decode_subtitle2`(libavcodec/decode.c:935):换算 `sub->pts`(decode.c:962-964)、用 packet duration 兜底 `end_display_time`(decode.c:975-980)、按 codec descriptor 的 `AV_CODEC_PROP_TEXT_SUB/BITMAP_SUB` 强制 `sub->format`(decode.c:982-985)、对 ass 文本做 UTF-8 校验(decode.c:987-993)。codec 层回调挂载点:`FF_CODEC_DECODE_SUB_CB` 宏(libavcodec/codec_internal.h:378-381),编码侧对应 `FF_CODEC_ENCODE_SUB_CB`(codec_internal.h:390-393)。释放统一走 `avsubtitle_free`(libavcodec/avcodec.c:421-438)。

```c
// libavcodec/avcodec.h:2088-2095
typedef struct AVSubtitle {
    uint16_t format; /* 0 = graphics */
    uint32_t start_display_time; /* relative to packet pts, in ms */
    uint32_t end_display_time;   /* relative to packet pts, in ms */
    unsigned num_rects;
    AVSubtitleRect **rects;
    int64_t pts;    ///< Same as packet pts, in AV_TIME_BASE
} AVSubtitle;
```

descriptor props 是文本/位图二分的第一道闸门(与 ffmpeg_mux_init.c:847-856 的转码检查同源):`srt`/`subrip`/`webvtt`/`ass`/`ssa` 均为 `AV_CODEC_PROP_TEXT_SUB`(libavcodec/codec_desc.c:3627-3629、3690-3692、3697-3699、3725-3727、3600-3602);dvdsub/pgssub/dvbsub/hdmv 等为 `AV_CODEC_PROP_BITMAP_SUB`(codec_desc.c:3574、3581、3595、3616 附近)。字符集自动探测(`sub_charenc`)与 iconv 预转码在解码前完成:`recode_subtitle`(decode.c:855-899,`FF_SUB_CHARENC_MODE_PRE_DECODER` 定义 avcodec.h:1725-1728)。

再往下是"消费者视角"的解剖——AVSubtitle 与 AVFrame 的时间语义对齐关系:

| 字段 | 语义 | 谁写 | 行号 |
|---|---|---|---|
| pts | AV_TIME_BASE 绝对时间 | decode.c 由 packet pts 换算 | avcodec.h:2094;decode.c:962-964 |
| start/end_display_time | 相对 pts 的毫秒 | decoder;duration 兜底 | avcodec.h:2090-2091;decode.c:975-980 |
| num_rects/rects | 矩形数组,可 0 条 | decoder | avcodec.h:2092-2093 |
| rect->flags | FORCED 位 | dvdsub/pgssub | avcodec.h:2075;pgssubdec.c:562 |

ffmpeg CLI 的 `copy_av_subtitle`(ffmpeg_dec.c:449-527)是这份契约的最完整"消费者样本":逐字段深拷贝,BITMAP 的 `data[1]` 按 `AVPALETTE_SIZE` 计算而其余平面按 `h * linesize[j]`(ffmpeg_dec.c:499-505)——印证了 data[0]=索引图、data[1]=调色板的 PAL8 式布局。

---

## 4. ASS 头部协商:ff_ass_subtitle_header 与 extradata

ASS 的字体、颜色、分辨率等样式全在文件头 `[Script Info]`/`[V4+ Styles]` 里。FFmpeg 的做法:demuxer 把非 Dialogue 行全部收进 header,写进 stream 的 **extradata**(libavformat/assdec.c:146-148 收集,160 `ff_bprint_to_codecpar_extradata`);decoder 在 init 时把 extradata 原样拷给 `avctx->subtitle_header`(libavcodec/assdec.c:31-41)。`AVCodecContext.subtitle_header` 的契约见 avcodec.h:1732-1745:"应包含完整 [Script Info] 与 [V4+ Styles],加上 [Events] 的 Format 行,不含任何 Dialogue 行"。

对于没有头部的裸文本格式,SRT/text 解码器在 init 时调用 `ff_ass_subtitle_header_default`(libavcodec/srtdec.c:98/111,textdec.c:91)→ `ff_ass_subtitle_header`(ass.c:84-96)→ `ff_ass_subtitle_header_full`(ass.c:29-82)用 `av_asprintf` 现场生成一份默认 ASS 头(PlayRes 384x288,`ASS_DEFAULT_PLAYRESX` 见 libavcodec/ass.h:28)。这就是"协商":渲染端(libass 滤镜)拿 `subtitle_header` 调 `ass_process_codec_private`(vf_subtitles.c:519-521),转码端把 dec 的 header 拷给 enc(fftools/ffmpeg_dec.c:1643-1650)。

```c
// libavcodec/ass.c:37-46(生成的头模板,节选)
avctx->subtitle_header = av_asprintf(
         "[Script Info]\n"
         "; Script generated by FFmpeg/Lavc%s\n"
         "ScriptType: v4.00+\n"
         "PlayResX: %d\n"
         "PlayResY: %d\n"
         "ScaledBorderAndShadow: yes\n"
         "YCbCr Matrix: None\n"
         "\n"
         "[V4+ Styles]\n"
         ...
```

四个变体的分工:`ff_ass_subtitle_header_full`(ass.c:29,全参数)、`ff_ass_subtitle_header`(ass.c:84,九参数便捷层)、`ff_ass_subtitle_header_default`(ass.c:98-109,纯默认,供 srt/text/webvtt 等 init 使用)、以及编码器侧的 `ff_ass_get_dialog`(ass.c:111-117,拼 `readorder,layer,style,name,margin,event` 行)。配套还有转义器 `ff_ass_bprint_text_event`(ass.c:173-220):换行转 `\N`、`{` 转 `\{{}` 防伪标签注入、裸 `\` 插入 U+2060 word-joiner(ass.c:193-198)——文本字幕安全性都收敛在这一处。readorder 的 flush 语义由 `ff_ass_decoder_flush`(ass.c:166-171)配合 `AV_CODEC_FLAG2_RO_FLUSH_NOOP` 决定;`FFASSDecoderContext` 只有 `int readorder` 一个字段(libavcodec/ass.h:46-48)。

SRT 特有:时间行后可携带 `X1:.. Y1:.. X2:.. Y2:..` 坐标,srt demuxer 把它放进 side data `AV_PKT_DATA_SUBTITLE_POSITION`(libavformat/srtdec.c:115-123;side data 定义 libavcodec/packet.h:180),解码器据此合成 `{\an5}{\pos(...)}` 标签并按 DVD 720x480 假设缩放(libavcodec/srtdec.c:33-56)。VTT 的 cue identifier/settings 同样走 side data(libavformat/webvttdec.c:154-166,packet.h:193/199)。

---

## 5. 位图字幕:rect 填充差异(dvdsub / pgssub / dvbsub)

位图字幕的 `AVSubtitleRect` 里 `data[0]`= 索引位图,`data[1]`= RGBA 调色板(`AVPALETTE_SIZE`),类似 PAL8(ffmpeg_dec.c:499-505 的拷贝逻辑印证了这一约定)。三家的结构差异:

| | dvdsub | pgssub | dvbsub |
|---|---|---|---|
| rect 数 | 恒 1(dvdsubdec.c:377-380) | 每对象 1 个(531-537) | 每 region 1 个 |
| 调色板 | 4 色猜色或 256 色 yuv(393-404) | 256 色 CLUT 拷贝(543-548) | `1 << depth` 色(806) |
| FORCED 位 | is_menu 按钮(411) | composition_flag&0x40(561-562) | - |
| 时间模型 | packet 即显示区间 | **packet 只攒对象,decode 末尾按 presentation 出帧**(594 起) | 类似 PGS 的 epoch 模型 |

- **dvdsub**(libavcodec/dvdsubdec.c):`decode_dvd_subtitles`(dvdsubdec.c:220)恒单 rect;两个 RLE 偏移分别解码奇/偶场到同一 bitmap(381-389);8bit 时 `nb_colors=256` 用 yuv 调色板,4bit 时 `nb_colors=4` 走 `guess_palette` 猜色(393-404);填 `x/y/w/h`、`linesize[0]=w`、`type = SUBTITLE_BITMAP`(405-410);菜单按钮置 `AV_SUBTITLE_FLAG_FORCED`(411)。另有 `find_smallest_bounding_rectangle` 裁掉全透明边缘(442 起)与 `forced_subs_only` 选项(555)。
- **pgssub**(libavcodec/pgssubdec.c):Blu-ray PGS 是"对象+调色板分离"模型,一次 presentation 可有**多个 rect**(循环 531-590);每个 rect 先无条件分配 256 色调色板再拷 CLUT(543-548,注释解释错误路径也要交出"完整 rect"),`composition_flag & 0x40` 置 FORCED(561-562),坐标来自 presentation 对象(564-565),RLE 解码填 `data[0]`(`decode_rle` pgssubdec.c:162,`linesize[0] = object->w` 571);对象缺失时不炸流,留 0x0 空 rect(552-559)。
- **dvbsub**(libavcodec/dvbsubdec.c):region 模型,`rect->nb_colors = (1 << region->depth)`、`rect->type = SUBTITLE_BITMAP`(806-807),多 region 多 rect,与 PGS 同为多矩形。

关键理解点:**PGS/DVB 的 packet 不对应一条字幕**,decode() 是一个状态机——PCS/WDS/ECS/PDS 段更新 presentation 状态,遇到 EPOCH START 才产出 AVSubtitle;而 DVD 字幕 packet 几乎自包含(调色板可从 packet 内 PCS 段拿,缺失才猜)。这解释了为什么 dvdsub 的 rect 填充能写在一个函数里收尾(dvdsubdec.c:405-411),而 pgssub 要拆成对象缓存+展示两个阶段。

---

## 6. 附件管线:MKV attachment 与字体

**demux 侧**(libavformat/matroskadec.c):
- EBML schema:`MatroskaAttachment` 结构(matroskadec.c:301-309:uid/filename/mime/bin/description),`matroska_attachment[]` 语法表 651-657,`matroska_attachments[]` 660-661,挂在 level1 `MATROSKA_ID_ATTACHMENTS`(763)。
- 转成 AVStream:遍历附件(matroskadec.c:3508-3551)——每个附件 `avformat_new_stream` + filename/mimetype/description 写进 stream metadata(3517-3520)。之后分两路:
  - **图片附件**(mime 匹配 `mkv_image_mime_tags`,817-824):`ff_add_attached_pic`(3533)复用为封面图——该函数(libavformat/demux_utils.c:110-143)把数据挂到 `st->attached_pic` packet,置 `AV_DISPOSITION_ATTACHED_PIC` 与 `AVMEDIA_TYPE_VIDEO`(demux_utils.c:132-133)。ID3 APIC、MOV cover 走同一函数(libavformat/id3v2.c:1215,mov.c:253)。
  - **其余附件**(含字体):`codec_type = AVMEDIA_TYPE_ATTACHMENT`(3537),文件内容整体塞进 `codecpar->extradata`(3538-3541),mime 再映射 codec_id(`mkv_mime_tags` 826-832:truetype/font→`AV_CODEC_ID_TTF`,opentype→`AV_CODEC_ID_OTF`)。

**mux 侧**(libavformat/matroskaenc.c):
- `mkv_init` 校验:附件流必须有可推断的 mimetype 否则 `AVERROR(EINVAL)`;WebM 不支持附件(matroskaenc.c:3606-3616,计数 `nb_attachments` 3615;字段定义 247)。
- `mkv_write_attachments`(2513-2561):跳过无 filename 的流(2540-2544),写 `AttachedFile` 六元组——FileDesc/FileName/FileMimeType/**FileData 直接取 `st->codecpar->extradata`**(2550-2551)/FileUID;调用点在 mkv_write_header(2705-2708)。tags 里附件还可挂 AttachUID 目标(2377-2389)。`get_mimetype` 从 metadata 或 codec_id 反推(matroskaenc.c:2496)。

**字体附件如何服务 libass**:`subtitles` 滤镜 init 时自己 `avformat_open_input` 打开字幕文件(vf_subtitles.c:382),定位字幕流(av_find_best_stream,393),然后遍历所有流,**把 `AVMEDIA_TYPE_ATTACHMENT` 且 mime 命中字体列表的流,用 `ass_add_font` 从 extradata 注册进 libass**(vf_subtitles.c:417-437;mime 白名单约 325-338,判定函数 `attachment_is_font` 340-354),配合 `ass_set_extract_fonts(library, 1)`(158)与 `ass_set_fonts`(440)。这是"MKV 内嵌字体 + ASS 字幕开箱即渲染"的闭环。硬字幕渲染本体在 `overlay_ass_image`:对 `ass_render_frame` 返回的 ASS_Image 链做 `ff_blend_mask`(vf_subtitles.c:224-237);字幕事件则由滤镜自行 demux+decode 后逐条 `ass_process_chunk` 喂入(517-545)。

```c
// libavfilter/vf_subtitles.c:417-437(节选)
/* Load attached fonts */
for (j = 0; j < fmt->nb_streams; j++) {
    AVStream *st = fmt->streams[j];
    if (st->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT &&
        attachment_is_font(st)) {
        ...
        if (tag) {
            av_log(ctx, AV_LOG_DEBUG, "Loading attached font: %s\n",
                   tag->value);
            ass_add_font(ass->library, tag->value,
                         st->codecpar->extradata,
                         st->codecpar->extradata_size);
        }
    }
}
```

**附件与"普通字幕流"在 MKV 里是两种东西**:MKV 字幕轨是 TrackEntry(`codec_id` 如 S_TEXT/ASS,正常 packet 流),而 Attachments 是 level1 元素,不参与时间轴——demux 后之所以也变成"流",纯粹是 AVFormatContext 只能这样暴露。副作用:CLI 的 `-map 0` / `-c copy` 必须把 attachment 流也带上,否则 mkv muxer 的 `nb_attachments`(matroskaenc.c:247,3606-3616 计数)为 0,`mkv_write_tracks` 直接跳过(2201)。另有一处细节:tags 写出时附件可挂 `MATROSKA_ID_TAGTARGETS_ATTACHUID`(2377-2389),把 description 等元数据原样带回。

---

## 7. 设计动机

1. **为什么字幕不走 AVFrame?** AVFrame 承载"单一像素格式+固定尺寸"的帧;字幕的本质是"若干可重叠的矩形/文本事件 + 相对时间",rect 数量与类型(BITMAP/TEXT/ASS)都动态,硬套 AVFrame 需要伪像素格式与数据约定。现状折中是 ffmpeg CLI 的 wrap hack(ffmpeg_dec.c:536-567),注释承认这是过渡态(676-679)。
2. **为什么文本 demuxer 全量读?** 见第 2 节:依赖"下一条"定界与补时长、文件内顺序不可信需全局排序、内存队列 seek 即二分。字幕文件通常 KB 量级,内存换正确性划算;连 probe 都要跨行 lookahead(srtdec.c:45-63)。ASS 侧还有额外约束:duration<=0 的 Dialogue 不能作为 packet 输出(会被 compute_pkt_fields 误猜时长),只能写进 header(assdec.c:75-82)。
3. **为什么统一以 ASS 为轴心?** ASS 表达力是文本字幕的超集:SRT/VTT/text 解码后统一转 `SUBTITLE_ASS` rect,下游(libass、srt/vtt 编码器)只处理一种表示;编码器再把 ASS 事件拆回目标格式(srtenc.c:229-263 逐 rect `ff_ass_split_dialog`,assenc.c:44 直通)。文本↔位图互转不可能,所以 mux 侧显式禁止:text→text、bitmap→bitmap(fftools/ffmpeg_mux_init.c:847-856;descriptor props 见 codec_desc.c:3627/3629、3690/3692、3697/3699、3725/3727)。
4. **为什么附件伪装成流?** 复用 AVStream 的 metadata/extradata/枚举机制:CLI 的流选择、滤镜的字体加载、信息输出都无需新增 API。代价是 codec_type 多出 `AVMEDIA_TYPE_ATTACHMENT` 这一"非媒体"类型。

---

## 8. FAQ 素材

1. **Q: SRT 的 read_header 为什么把整个文件读完?** A: packet 的 duration 需要"下一条 pts"兜底(subtitles.c:222-224),数字行歧义靠上下文消解(srtdec.c:175-182);read_packet 只是 `av_packet_ref` 出队(subtitles.c:230-245)。
2. **Q: AVSubtitle 和 AVFrame 什么关系?** A: 没有关系。AVSubtitle 是独立结构(avcodec.h:2088-2095);ffmpeg CLI 用 AVBufferRef 把它挂进 `AVFrame.buf[0]` 传递(ffmpeg_dec.c:556-564)。
3. **Q: 为什么 SRT 解码出的 rect 是 ASS 类型?** A: srt 解码器先 `srt_to_ass` 再 `ff_ass_add_rect`,rect->type 恒为 SUBTITLE_ASS(libavcodec/srtdec.c:80-82;ass.c:151)。
4. **Q: subtitle_header 和 extradata 什么关系?** A: ASS demuxer 把脚本头写进 extradata(assdec.c:160),ASS decoder 的 init 把 extradata 原样拷给 subtitle_header(libavcodec/assdec.c:33-39);裸文本解码器用 ff_ass_subtitle_header_default 现造一份(ass.c:98-109)。
5. **Q: 转码时如何保留 MKV 字体附件?** A: 附件就是 codec_type=ATTACHMENT 的流,映射带上即可;mkv muxer 从 extradata 原样写出(matroskaenc.c:2550-2551),但要求 mimetype 可推断(3610)。
6. **Q: -fix_sub_duration 在修什么?** A: 某些格式只有显示开始时间,decoder 侧用"下一条 pts"回填上一条的 end_display_time(ffmpeg_dec.c:574-588),demux 侧用 heartbeat 包驱动(ffmpeg_demux.c:692-706;ffmpeg_dec.c:612-632)。
7. **Q: PGS 一条 packet 能解出几条字幕?** A: 可多个 rect——每个 presentation object 一个(pgssubdec.c:531-537);DVD 字幕恒单 rect(dvdsubdec.c:377-380)。
8. **Q: subtitles 滤镜会自动用 MKV 里的字体吗?** A: 会——滤镜自己重新打开字幕文件,遍历 attachment 流 ass_add_font(vf_subtitles.c:417-437),而非依赖外部 fontsdir。
9. **Q: 为什么 text→bitmap 转码报错?** A: new_stream_subtitle 检查输入/输出 descriptor 的 TEXT_SUB/BITMAP_SUB 属性必须一致(ffmpeg_mux_init.c:847-856)。
10. **Q: 每个字幕 packet 都带 KEY flag 吗?** A: 是,queue_insert 时统一置 `AV_PKT_FLAG_KEY`(subtitles.c:149),每条事件独立可解。

---

## 9. 深挖方向

1. **AVSubtitle→AVFrame 的历史与未来**:跟踪 subtitle_wrap_frame 的引入(新调度器时代),对比旧 ffmpeg.c 的 sub2video 机制(现残留于 ffmpeg_demux.c:80 `have_sub2video`、1252-1259 尺寸协商);这是理解"字幕为何还停在旧 API"的最佳切片。
2. **libass 集成细节**:vf_subtitles.c 的 `ass_process_codec_private`(519-521)与 `ass_process_chunk`(535-542)如何对应 subtitle_header 与 rect.ass;`ass_track_set_feature(ASS_FEATURE_WRAP_UNICODE)`(489)的版本兼容处理。
3. **webvtt 的往返保真**:demux 把 identifier/settings 放 side data(webvttdec.c:154-166),mkv/webvtt mux 与 webvttenc.c 如何还原/降级。
4. **CC(closed caption)旁路**:eia_608 属 `AV_CODEC_PROP_TEXT_SUB`(codec_desc.c:3636)却走完全不同的提取路径,可对比 dvb_teletext。
5. **性能边界**:超大字幕(10 万+事件)下队列的 `av_fast_realloc`/`qsort` 行为(subtitles.c:132-138,219-221);VobSub(idx+sub 双文件)多流复用单队列时 stream_index 的处理(subtitles.c:307-314)。

---

## 写作要点速查表

| 主题 | 函数/位置 | 文件:行号 |
|---|---|---|
| UTF16/BOM 自动转码 | ff_text_init_avio / ff_text_r8 | libavformat/subtitles.c:28 / 65 |
| 队列插入事件 | ff_subtitles_queue_insert | libavformat/subtitles.c:111 |
| 排序+补时长+去重 | ff_subtitles_queue_finalize | libavformat/subtitles.c:212(时长兜底 222-224) |
| 队列读包/seek/清理 | queue_read_packet / queue_seek / clean | libavformat/subtitles.c:230 / 269 / 321 |
| 通用 demuxer 包装 | ff_subtitles_read_packet 等 | libavformat/subtitles.c:331-350 |
| SRT 全量读头 | srt_read_header | libavformat/srtdec.c:129(行缓存 175-182) |
| ASS 头进 extradata | ass_read_header | libavformat/assdec.c:115(extradata 160) |
| VTT side data | webvtt_read_header | libavformat/webvttdec.c:61(154-166) |
| 队列结构定义 | FFDemuxSubtitlesQueue | libavformat/subtitles.h:103-110 |
| AVSubtitleType 枚举 | enum AVSubtitleType | libavcodec/avcodec.h:2041 |
| rect / sub 结构 | AVSubtitleRect / AVSubtitle | libavcodec/avcodec.h:2061 / 2088 |
| ASS 头生成 | ff_ass_subtitle_header_full | libavcodec/ass.c:29(default 98) |
| rect 追加(恒 ASS) | ff_ass_add_rect2 | libavcodec/ass.c:119(type 151) |
| ASS 解码器直通 | ass_decode_frame | libavcodec/assdec.c:43(init 31) |
| SRT→ASS 转换 | srt_to_ass / srt_decode_frame | libavcodec/srtdec.c:33 / 58 |
| 解码总入口 | avcodec_decode_subtitle2 | libavcodec/decode.c:935(回调 965) |
| DVD 位图 rect | decode_dvd_subtitles 填 rect | libavcodec/dvdsubdec.c:375-411 |
| PGS 多 rect | 循环填 rect | libavcodec/pgssubdec.c:531-590 |
| 附件→流 | matroska demux attachments | libavformat/matroskadec.c:3508-3551 |
| 附件写出 | mkv_write_attachments | libavformat/matroskaenc.c:2513(extradata 写出 2550-2551) |
| 封面图复用 | ff_add_attached_pic | libavformat/demux_utils.c:110 |
| 滤镜加载字体附件 | init_subtitles + ass_add_font | libavfilter/vf_subtitles.c:358(417-437) |
| 字幕包进 AVFrame | subtitle_wrap_frame | fftools/ffmpeg_dec.c:536(注释 676-679) |
| 转码字幕入口 | transcode_subtitles | fftools/ffmpeg_dec.c:634(分发 698-699) |
