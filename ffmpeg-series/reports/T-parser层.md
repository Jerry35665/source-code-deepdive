# T 章 · AVCodecParser：demux 与 decode 之间的隐形层

> 仓库: ffmpeg @ 9f63b36a (master)。所有行号均为仓库相对路径，已用 grep/Read 实际核对。
> 呼应第 17 章：RTP 的 H264 重组靠 `need_parsing = AVSTREAM_PARSE_FULL` 交给上层 parser（libavformat/rtpdec_h264.c:416），本章把这层讲透。

---

## 1. 全景：demux → parser → decoder 管道

```
                        ┌────────────────────────────────────────────────────────┐
 网络字节流 / 文件        │                   libavformat (demux)                  │
        │               │                                                        │
        ▼               │  avio_read ──► demuxer(mpegts/rtp/mov…) ──► AVPacket   │
        └──────────────►│      (TS: 188B PES→pkt, RTP: NAL 重组,      pts/dts    │
                        │       mov: sample 表直接切)                 pos        │
                        └───────────────────────┬────────────────────────────────┘
                                                │ read_frame_internal()
                                                │ sti->need_parsing ? (demux.c:1482)
                                                ▼
                        ┌────────────────────────────────────────────────────────┐
                        │              libavcodec parser 层 (隐形层)              │
                        │  parse_packet()  (demux.c:1178)                        │
                        │    └─ av_parser_parse2()  (parser.c:120)               │
                        │         ├─ 记录 pts/dts 到 4 槽环形表  (parser.c:152)    │
                        │         ├─ parse 回调: h264_parse 等   (parser.c:171)   │
                        │         │    ├─ find_frame_end  → 帧边界               │
                        │         │    ├─ ff_combine_frame → 累积/切分 (parser.c:213)│
                        │         │    └─ parse_nal_units → 参数集/关键帧/POC      │
                        │         └─ next_frame_offset = cur_offset+index (:191) │
                        │  输出: out_pkt.pts = parser->pts   (demux.c:1288)      │
                        │        out_pkt.flags |= KEY (parser 判定)(demux.c:1296)│
                        └───────────────────────┬────────────────────────────────┘
                                                │ parse_queue → AVPacket 流
                                                ▼
                        ┌────────────────────────────────────────────────────────┐
                        │      decoder (h264dec/hevcdec/…) 或 streamcopy 直接 mux │
                        └────────────────────────────────────────────────────────┘
```

parser 层解决四个 decoder 不做、demuxer 不愿做的事：

| 问题 | 谁需要 | parser 侧落点 |
|---|---|---|
| ① 帧边界（一个输入包 ≠ 一帧） | 裸流(raw ES)、RTP、TS | `h264_find_frame_end` (h264_parser.c:82)、`ff_combine_frame` (parser.c:213) |
| ② 时间戳恢复/对齐 | TS（PES 带 pts 但包边界≠帧边界）、裸流(完全无 ts) | 4 槽环形表 + `ff_fetch_timestamp` (parser.c:89) |
| ③ 关键帧标记（ seek/快进/丢帧） | streamcopy、播控 | `s->key_frame`（IDR h264_parser.c:356、recovery_point :368） |
| ④ 参数集/流信息预读 | `avformat_find_stream_info`、探测宽高 | `parse_nal_units` 填 `s->width/pict_type/format`（h264_parser.c:394-421），回填 avctx (parser.c:174-183) |

关键点：**streamcopy 路径同样过 parser**。`-c copy` 时 decoder 从不打开，但帧边界、关键帧 flag、pts 全靠 parser 层供给——这就是它必须独立于 decoder 存在的根本原因（见 §6）。

---

## 2. 框架专节：av_parser_parse2 的缓冲累积模型

### 2.1 为什么输入包 ≠ 输出包

TS 里一个 PES 包可能含半帧 H264；RTP 重组后的包也可能是 1.7 帧。`av_parser_parse2`（libavcodec/parser.c:120）的契约是：喂进任意长度 `buf`，可能吐出 0 个、1 个或多个完整访问单元，返回值 `index` 是**本次消费掉的字节数**（parser.c:199 `s->cur_offset += index`），可以为负?不——API 规定不允许返回 AVERROR，只断言 `index > -0x20000000`（parser.c:173），负值在 :197-198 被钳到 0。

每个 parser 私有数据第一字段都是 `ParseContext pc`（h264_parser.c:56、aac_ac3_parser.h:32），这就是累积缓冲（parser.h:28-38）：

```c
// libavcodec/parser.h:28-40
typedef struct ParseContext{
    uint8_t *buffer;
    int index;                 // 已累积字节数
    int last_index;
    unsigned int buffer_size;
    uint32_t state;            // 最近几字节(MSB序), 供 startcode 状态机跨包续用
    int frame_start_found;
    int overread;              // 从下一帧"多读"的字节数
    int overread_index;
    uint64_t state64;
} ParseContext;
#define END_NOT_FOUND (-100)
```

`ff_combine_frame`（parser.c:213-298）是所有"字节流型" parser 的共用拼帧器，协议极简：

- `next == END_NOT_FOUND(-100)`：本包内没有帧尾 → 把数据 memcpy 进 `pc->buffer` 累积（:237-251），返回 -1，上层（如 h264_parse :619-623）随即输出空包；
- `next >= 0`：帧尾在偏移 next 处 → 把累积缓冲+新数据拼成完整帧从 `*buf` 交还（:256-277），`pc->index` 清零；
- `next < 0`（小负数）：parser 的状态机"多读"了下一帧的 `-next` 字节 → 记入 `overread`，下一轮回填（:279-288 与 :223-225），这是 h264 状态机 `return i - (state & 5)` 回看 startcode 的配套机制。

### 2.2 pts/dts 旁路恢复：parser 给出"下一个包"的 pts

demuxer 的 pts 挂在**容器包**上，而 parser 输出的是**帧**，两者边界错位。框架的解法是一个 4 槽环形时间戳表：

1. `av_parser_parse2` 每收到一个新容器包，就把它的 (offset, pts, dts, pos) 压入环形表（parser.c:152-161，槽位数 `AV_PARSER_PTS_NB = 4`，avcodec.h:2645）；
2. 帧输出后 `s->fetch_timestamp = 1`（parser.c:192），下一次调用开头用 `ff_fetch_timestamp(s,0,0,0)`（parser.c:163-169）按**帧在容器包内的字节偏移**去环形表里取"覆盖该偏移的那个容器包的 pts/dts"（parser.c:99-117）；
3. 结果写入 `s->pts/s->dts/s->pos`，demux 侧直接抄走：`out_pkt->pts = sti->parser->pts`（demux.c:1288-1290）。

这就是"pts 旁路"：**parser 不是透传输入包的 pts，而是按输出帧的字节位置从时间戳环形表中重新归属**。一个 RTP 包横跨两帧时，两帧各自拿到的都是正确的那个 PES/RTP 时间戳。注意 demux 侧喂完一次就立刻把 `pkt->pts = pkt->dts = AV_NOPTS_VALUE`（demux.c:1224-1225），防止同一时间戳被第二个循环 iteration 重复消费——剩下的帧只能靠环形表。

`AVCodecParserContext` 的核心字段（libavcodec/avcodec.h:2618-2775）：`cur_offset/next_frame_offset`（:2622-2624，输出游标）、`pts/dts`（:2637-2638）、`key_frame`（:2667，-1=未判定）、`dts_sync_point/dts_ref_dts_delta/pts_dts_delta`（:2679/:2694/:2708，H264 DTS 重建三件套）、`repeat_pict`（:2636）、`duration`（:2732）。

### 2.3 AVCodecParser 抽象

公共结构只剩 `codec_ids[7]`（avcodec.h:2777-2779）；真正的回调在内部布局 `FFCodecParser`（libavcodec/parser_internal.h:27-36）：`init/parse/close`，经 `PARSER_CODEC_LIST` 宏声明最多 7 个 codec id（parser_internal.h:54-55），ac3 parser 就复用它同时服务 AC3+EAC3（ac3_parser.c:482）。`av_parser_init` 线性遍历已注册 parser 按 codec id 匹配（parser.c:46-54），并初始化 `fetch_timestamp=1`、`key_frame=-1`、`dts_sync_point=INT_MIN`（parser.c:67-78）。

---

## 3. h264_parser 专节：帧边界判定的多信号融合

`h264_parse` 主流程（libavcodec/h264_parser.c:595-676）：

```
extradata → is_avc/nal_length_size (605-612)
  ↓
h264_find_frame_end (617) ──next──► ff_combine_frame (619) ──未凑齐──► 返回空
  ↓ 凑齐完整 AU
parse_nal_units (631)  → 关键帧/pict_type/尺寸/POC/SEI
  ↓
cpb_removal_delay → dts_sync_point 三件套 (635-643)
  ↓
reference_dts DTS 重建 (649-671)
```

### 3.1 find_frame_end：一个状态机吃三种信号

`h264_find_frame_end`（h264_parser.c:82-171）用 `pc->state` 做字节级状态机：

- **信号 A ·NAL 边界扫描**：state==7 时调 `h264dsp.startcode_find_candidate`（:113-114，SIMD 加速）跳到候选 startcode；state≤2 按 `00 00 01` 前缀逐字节收敛（:117-123）。AVC(长度前缀)模式则直接按 `nal_length_size` 读长度跳 NAL（:99-111）。
- **信号 B ·"新 AU 起始"型 NAL**：识别到 SEI(6)/SPS(7)/PPS(8)/AUD(9) 且 `frame_start_found` 已置位 → 上一帧到此为止（:124-131，`goto found`）。AUD 是编码器显式的访问单元分隔符，是最可靠的信号。
- **信号 C ·slice 头 first_mb_in_slice 单调性**：遇到 slice(1)/DPA(2)/IDR(5) 进入 state>8 的深度解析：累积最多 6 字节到 `parse_history`（:141），ue_golomb 解出 `first_mb_in_slice`（:144）；**同一帧内 first_mb 递增，新帧的第一片必然 ≤ 上一片**，于是 `mb <= last_mb` 即判帧边界（:147-152）。这是在没有 AUD 的裸流里切帧的主力启发式。

三条信号融合的意义：只靠 startcode 会把一帧的多片切成多帧；只靠 slice 序号会被丢包打乱；AUD/SEI/参数集提供权威切点。`found` 出口返回 `i - (state & 5)`（:170），把 startcode 的 3 字节前缀留在本帧内，负值部分交给 `ff_combine_frame` 的 overread 机制（parser.c:279）。

### 3.2 parse_nal_units：一帧之内的属性提取

凑齐一帧后 `parse_nal_units`（h264_parser.c:262-593）逐 NAL 走一遍：

- SPS/PPS/SEI 入库（:345-354，复用 `ff_h264_decode_seq_parameter_set` 等 decoder 同款函数——parser 不解码图像，但完全解码语法层）；
- 关键帧三重判定：
  1. IDR NAL → `s->key_frame = 1` 并复位 POC 基准（:355-361）；
  2. SEI recovery_point：`recovery_frame_cnt >= 0` → 关键帧（:368-371；SEI 解析置位在 h264_sei.c:151-158）；
  3. 启发式：参考帧数≤1 且 pict_type 为 I 也算关键帧（:389-390，对付不打 IDR 标记的裸流）；
- slice 头：跳过 `first_mb_in_slice`、解 `slice_type` 映射 pict_type（:365-367）；
- 尺寸/像素格式/profile/level（:394-424）→ 由框架回填 avctx（parser.c:175-183 的 `FILL` 宏），这是 `find_stream_info` 免开 decoder 拿宽高的来源；
- POC 计算 `ff_h264_init_poc`（:459）写 `s->output_picture_number`；非 IDR 帧还要 `scan_mmco_reset`（:468-472，定义 :173-252）向前扫 MMCO 重置——参考队列重置等价于新 GOP 起点；
- repeat_pict/field_order 从 picture_timing SEI 的 pic_struct 推出（:497-524）。

### 3.3 DTS 重建：parser 自己当"码率时钟"

裸 H264 完全没有 DTS。h264_parser.c:635-643 把 SEI 的 `cpb_removal_delay/dpb_output_delay` 写入 `dts_sync_point/dts_ref_dts_delta/pts_dts_delta`；:649-671 用 `reference_dts` 锚点做差值外推：

```c
// h264_parser.c:653-659
if (s->dts != AV_NOPTS_VALUE)      // 流里来了真 DTS → 校准锚点
    p->reference_dts = av_sat_sub64(s->dts, av_rescale(s->dts_ref_dts_delta, num, den));
else if (p->reference_dts != AV_NOPTS_VALUE)  // 否则按锚点+delay 外推
    s->dts = av_sat_add64(p->reference_dts, av_rescale(s->dts_ref_dts_delta, num, den));
```

时间基来自 SPS VUI timing info 折算的 `avctx->framerate`（:572-578，`num_units_in_tick*2`，x264 老版本的 `den *= 2` 兼容 :574-575）与 `avctx->pkt_timebase` 的换算（:650-652）。

---

## 4. 多格式对比： AAC(定长头) / AC3(帧长表+等式) / HEVC

### 4.1 AAC：ADTS 定长头，一查帧长

共用骨架 `ff_aac_ac3_parse`（libavcodec/aac_ac3_parser.c:32-172）：先逐字节滚 `state` 找 sync 回调认可的头（:57-61），`sync()` 返回帧长 → `remaining_size` 记账（:67-68），`ff_combine_frame` 按"下一帧头的出现位置"切帧。AAC 的 sync 只是 `ff_adts_header_parse_buf`（aac_parser.c:38）；ADTS 头解析（libavcodec/adts_header.c:30-74）：

```c
// adts_header.c:37-38, 56-58, 69-73
if (get_bits(gbc, 12) != 0xfff)          // 12bit 同步字
    return AAC_PARSE_ERROR_SYNC;
...
size = get_bits(gbc, 13);                // aac_frame_length: 帧总长(含头)
if (size < AV_AAC_ADTS_HEADER_SIZE)
    return AAC_PARSE_ERROR_FRAME_SIZE;
hdr->samples     = (rdb + 1) * 1024;     // 每帧采样数
hdr->bit_rate    = size * 8 * hdr->sample_rate / hdr->samples;
return size;                             // ← 帧长即返回值
```

帧长写死在头的 13 bit 里，所以 `need_next_header = 0`（aac_parser.c:41）——拿到头就无需再找下一个头，按长度走即可。AAC 分支还把 `s1->key_frame = 1` 硬置（aac_ac3_parser.c:158，音频帧皆"关键帧"），并注释了 ADTS 的采样率/声道不可信（HE-AAC 兼容原因，:94-98）。

### 4.2 AC3：帧长表 + E-AC3 等式 + CRC 防误判

AC3 复用同一骨架，`ac3_sync`（libavcodec/ac3_parser.c:444-469）返回 `hdr.frame_size`：

- 普通 AC3：`frame_size = ff_ac3_frame_size_tab[frame_size_code][sr_code] * 2`（ac3_parser.c:345），6bit 码查表；
- E-AC3：等式 `frame_size = (get_bits(gbc, 11) + 1) << 1`（:361，帧长字以字为单位）；
- `need_next_header/new_frame_start` 由帧类型决定（:466-467）：E-AC3 的 DEPENDENT 帧不算新帧起点——独立帧/依赖帧的成对结构是音频 parser 里少有的"帧≠AU"情况。

防误同步：syncword 0x0B77 太弱，`ff_aac_ac3_parse` 的 AC3 分支还要整帧 CRC16 校验（aac_ac3_parser.c:122，A/52 §6.1.2），并顺带识别 `bitstream_id > 10 → EAC3` 改写 codec_id（:129-130）。

### 4.3 对比表

| 维度 | AAC (ADTS) | AC3/E-AC3 | H264 | HEVC |
|---|---|---|---|---|
| 帧边界来源 | 头内 13bit 帧长 (adts_header.c:56) | 查表 :345 / 等式 :361 | startcode+AUD+first_mb 状态机 (h264_parser.c:82) | startcode+NAL type+first_slice flag (hevc/parser.c:259) |
| 关键帧 | 恒 1 (aac_ac3_parser.c:158) | 恒 -1 (:43) | IDR/recovery_point/启发式 (:356,:368,:389) | IRAP NAL (hevc/parser.c:75-78) |
| 时间戳贡献 | 无（duration 走 samples） | `duration = num_blocks*256` (:141) | DTS 全套重建 (:649) | POC→output_picture_number (hevc/parser.c:153-158) |
| 参数集 | 头内自带 | 头内自带 | SPS/PPS 缓存 ps (:345-351) | VPS/SPS/PPS (:210-218) |
| 复用骨架 | ff_aac_ac3_parse | ff_aac_ac3_parse | 自写 find_frame_end+combine | 自写 find_frame_end+combine |

HEVC 与 H264 的结构性差异：HEVC 切帧多了一条**NAL 语义信号**——AU 起始型 NAL（VPS..EOB/SEI_PREFIX，hevc/parser.c:281-288）与 slice 的 `first_slice_segment_in_pic_flag`（:291-301，取 buf[i] 最高位，比 H264 的 golomb 解析便宜得多），不需要 first_mb 单调性启发式；关键帧直接用 `IS_IRAP_NAL`（type 16-23，:38）。

---

## 5. demux 集成专节：parse_packet 如何插在 demux 与 decode 之间

### 5.1 挂接点与调用位置

- 声明意愿：demuxer 通过 `ffstream(st)->need_parsing = ...` 声明，公共入口 `avpriv_stream_set_need_parsing`（libavformat/demux_utils.c:41-44）；RTP 动态 handler 的 `need_parsing` 字段在 `init_rtp_handler` 里抄到流上（libavformat/rtsp.c:255）。
- 实例化：`read_frame_internal` 收到包时惰性建 parser：`sti->parser = av_parser_init(...)`（libavformat/demux.c:1482-1483），并把 need_parsing 语义翻译成 parser flag：HEADERS→`PARSER_FLAG_COMPLETE_FRAMES`（:1490-1491，不切包只取头）、FULL_ONCE→`PARSER_FLAG_ONCE`（:1492-1493）、FULL_RAW→`PARSER_FLAG_USE_CODEC_TS`（:1494-1495）。找不到 parser 则降级 `need_parsing = AVSTREAM_PARSE_NONE` 原样出包（:1488-1489）。
- 插入执行：`parse_packet(s, pkt, stream_index, flush)`（demux.c:1178，调用点 :1509）循环调 `av_parser_parse2`（:1220-1222），每产出一帧 `ff_packet_list_put` 进 `parse_queue`（:1306），之后 `read_frame_internal` 再从队列取——对上层完全透明。EOF flush 时 `av_parser_close` 收尾（:1313-1316，EOF 触发点 :1404-1409）；codec_id/extradata 变化会拆掉重建 parser（:209-214、:1436-1441）。

### 5.2 AVSTREAM_PARSE_* 语义与设置点

枚举定义在 libavformat/avformat.h:609-618。典型设置点：

| 值 | 语义 | 例子 |
|---|---|---|
| `FULL` | 全解析+重新切包 | rtpdec_h264.c:416、mpegts.c:961、matroskadec.c:2893 |
| `HEADERS` | 只解析头，不重切包(COMPLETE_FRAMES) | mov.c:3295/3687、flvdec.c:438、av1dec.c:82 |
| `TIMESTAMPS` | 切包+按字节位置内插时间戳 | avidec.c:919（AVI 的帧边界在索引里，pts 需按帧内偏移修正） |
| `FULL_ONCE` | 只完整解析第一帧 | asfdec_f.c:463 |
| `FULL_RAW` | 裸流：时间戳/文件位置全由 parser 生成 | rawdec.c:61、aacdec.c:118、flacdec.c:69 |

`FULL_RAW` 的两处配套：demux 抄位置 `out_pkt->pos = sti->parser->frame_offset`（demux.c:1293-1294）；`PARSER_FLAG_USE_CODEC_TS` 让 `compute_pkt_fields` 信任 codec 层时间基（demux.c:1495、find_stream_info 里同样 :2659）。

### 5.3 TS 的 33bit 时间戳恢复：demux 给原料，parser 精加工

TS 侧 `avpriv_set_pts_info(st, 33, 1, 90000)`（mpegts.c:957）声明 33bit/90kHz 时基；PES 头的 5 字节时间戳由 `ff_parse_pes_pts` 解包（mpeg.h:69-73，`(*buf&0x0e)<<29 | (AV_RB16(buf+1)>>1)<<15 | AV_RB16(buf+3)>>1`，mpegts.c:1357-1362 使用）。但 PES 包边界≠帧边界：一个 PES 可能装 1.5 帧，或一帧横跨两个 188B 包。于是 mpegts 对所有流默认 `need_parsing = AVSTREAM_PARSE_FULL`（mpegts.c:961），把"pts 归属到帧"的最后一公里交给 §2.2 的环形表机制。例外：TS 里封装的是 mp4 式 extradata（`mp4a-40-2` 等）时码流本身自带边界信息，直接 `need_parsing = 0` 免解析（mpegts.c:1841-1845）。

### 5.4 compute_pkt_fields：parser 信息的第二消费者

parser 输出的包还要过 `compute_pkt_fields`（demux.c:983）补时间戳逻辑：H264/HEVC/VVC 被排除在 onein_oneout 之外（:993-995）；`pc->pict_type == B` 反推 `has_b_frames`（:1025-1028）；`AVSTREAM_PARSE_TIMESTAMPS` 时按 `pc->offset`（帧内字节偏移）线性修正 pts/dts（:1078-1085）；帧 duration 计算消费 `pc->repeat_pict`（:727-732，pull-down 补帧），隔行流没 parser 就干脆不算 duration（:733-738）。

---

## 6. 设计动机

1. **为什么独立于 decoder**：帧边界/关键帧/时间戳是**容器语义**需求，decoder 是可选组件。`-c copy`、`avformat_find_stream_info`、seek 的 keyframe 索引（AVFMT_GENERIC_INDEX 路径，demux.c:1501-1506 只在无 parser 时走）都必须在不开 decoder 的情况下工作。所以 parser 只解语法（SPS/PPS/SEI/slice 头），从不解像素，二进制体积和 CPU 都远小于 decoder；且 `ff_h2645_extract_rbsp`、PS/SEI 代码与 decoder 直接共用（h264_parser.c:331/346-353）。
2. **为什么有 pts 旁路（环形表）**：容器时间戳密度与帧边界密度天然错位。与其要求 demuxer 保证"一包一帧"（TS/RTP 做不到），不如让 parser 记录"哪段字节属于哪个容器包"，按输出帧的字节区间反查。这也解释了 demux.c:1224 消费后立即清空 pts——时间戳是"一次性原料"，重复消费必然错。
3. **为什么 parse 回调约定"返回消费字节数而非错误码"**：parser 处于数据管道中间，坏数据必须被跳过而不是中断；`av_assert0(index > -0x20000000)`（parser.c:173）硬性禁止 AVERROR 穿透，坏帧的代价只是边界判定退化到 END_NOT_FOUND。
4. **为什么 H264/HEVC parser 这么重**：它们承担了半个 `find_stream_info`：宽高、pix_fmt、profile/level、帧率、field order、POC 全部要在 demux 阶段拿到（h264_parser.c:394-424、572-578），否则每次探测都要开真 decoder。

---

## 7. FAQ 素材

1. **Q: RTP H264 重组后为什么还要 parser？** h264_handle_packet 只做 FU-A/STAP-A 分片合并成 NAL 序列（rtpdec_h264.c:420），AU 边界、IDR 标记、时间戳归属仍需 `AVSTREAM_PARSE_FULL`（rtpdec_h264.c:416）交给 h264_parser。
2. **Q: av_parser_parse2 返回负数是错误吗？** 不是。返回值是消费字节数（parser.c:199），-1 语义由各 parser 内部约定（ff_combine_frame 的"未凑齐"），API 层禁止 AVERROR（parser.c:173）。
3. **Q: 为什么 TS 流里 AVPacket 的 size 和解码帧对不上？** 需要看 need_parsing：mpegts.c:961 默认 FULL，出来的是切好的帧；但 mp4 式 extradata 场景 mpegts.c:1842-1845 关掉解析，包保持 PES 原样。
4. **Q: parser 的 key_frame 和 decoder 的一致吗？** parser 只有语法级判定（IDR/recovery_point/启发式，h264_parser.c:356-390），demux 侧 `key_frame == -1` 时退化为 `pict_type == I`（demux.c:1296-1302）。
5. **Q: AUDIO parser 怎么算 duration？** `s1->duration`（如 AC3 的 `num_blocks*256` 采样，aac_ac3_parser.c:141）由 demux 侧换算 `1/sample_rate → st->time_base`（demux.c:1273-1279）。
6. **Q: AVSTREAM_PARSE_HEADERS 和 FULL 差在哪？** HEADERS 加 `PARSER_FLAG_COMPLETE_FRAMES`（demux.c:1490-1491）：parser 每包直接 `next = buf_size` 整包放行（h264_parser.c:614-615），只薅参数集不切帧。
7. **Q: 裸 H264 文件的 DTS 是谁生成的？** parser。cpb/dpb delay + reference_dts 锚点外推（h264_parser.c:649-671），时间基取 SPS VUI 折算的 framerate（:572-578）。
8. **Q: 一个输入包里两帧，pts 会复制吗？** 不会。第二帧从环形表按字节偏移取到下一个容器包的 pts；环形表只有 4 槽（avcodec.h:2645），极端碎片化的流可能取空，返回 AV_NOPTS_VALUE（parser.c:93-98 先清 NOPTS）。
9. **Q: extradata 变了 parser 会怎样？** 拆掉重建（demux.c:1436-1441），因为 is_avc/nal_length_size 等状态来自旧 extradata（h264_parser.c:605-612）。
10. **Q: E-AC3 为什么走 AC3 parser？** `PARSER_CODEC_LIST(AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3)`（ac3_parser.c:482），且运行时把 bsid>10 的流改写成 EAC3 codec_id（aac_ac3_parser.c:129-130）。

## 深挖线索

1. **overread 机制**：h264 状态机回看 startcode 返回 `i - (state & 5)`（h264_parser.c:170）产生小负数，`ff_combine_frame` 把多读字节存进 `pc->state/overread` 并下轮回填（parser.c:279-288、223-225）——跨包边界状态保持的教科书实现。
2. **PARSER_FLAG_ONCE 生命周期**：demux 请求"只解析第一帧"（demux.c:1492-1493），h264 在第一次成功后自删 COMPLETE_FRAMES 之外的所有 flag（h264_parser.c:645-647）。
3. **find_stream_info 的平行 parser**：`avformat_find_stream_info` 自己也建一份 parser 实例喂包（demux.c:2647-2661），与 read_frame_internal 的那份互不共享——同一份码流可能被解析两遍。
4. **AUD 缺失流的切帧退化**：无 AUD 时全靠 first_mb 单调性（h264_parser.c:147-152）；实验：对丢失片的 TS 流观察 `mb <= last_mb` 误切——这就是"TS 不发完整 PES 也要 parser 兜底"的成本（parser.c:103-104 的注释即为此而写）。
5. **dashenc/mux 侧反用 parser**：`av_parser_parse2` 不止 demux 用，dashenc 在 mux 前解析 AAC 估时长（dashenc.c:2042），oggparseflac 用 parser 拉元数据（oggparseflac.c:139）——parser 是公共语法解析设施而非 demux 私产。

---

## 写作要点速查表

| 函数/结构 | 位置 | 要点 |
|---|---|---|
| `av_parser_init` | libavcodec/parser.c:35 | 按 codec_ids[7] 匹配；fetch_timestamp=1 (:67), key_frame=-1 (:74) |
| `av_parser_parse2` | parser.c:120 | 压环形表 :152-161；parse 回调 :171；next_frame_offset :191；消费字节 :199 |
| `ff_fetch_timestamp` | parser.c:89 | 按 cur_offset+off 在 4 槽表反查 pts/dts/pos (:99-117) |
| `ff_combine_frame` | parser.c:213 | END_NOT_FOUND 累积 :237-251；切帧 :256-277；overread :279-288 |
| `ParseContext`/`END_NOT_FOUND` | parser.h:28-40 | 累积缓冲 + 跨包状态机 |
| `FFCodecParser` | parser_internal.h:27-36 | init/parse/close 真回调；PARSER_CODEC_LIST :54 |
| `AVCodecParserContext` | avcodec.h:2618-2775 | 环形表 :2645-2649；key_frame :2667；dts 三件套 :2679-2708 |
| `AVSTREAM_PARSE_*` | libavformat/avformat.h:609-618 | 五种语义 |
| `h264_find_frame_end` | h264_parser.c:82 | AUD/SEI/SPS/PPS 切点 :124-131；first_mb 单调 :147-152；found :165-170 |
| `parse_nal_units`(h264) | h264_parser.c:262 | IDR :356；recovery_point :368；启发式 :389；宽高 :394 |
| `h264_parse` DTS 重建 | h264_parser.c:649-671 | reference_dts 锚点外推 |
| `hevc_find_frame_end` | hevc/parser.c:259 | first_slice flag :291-301；IRAP :38/:75 |
| `ff_aac_ac3_parse` | aac_ac3_parser.c:32 | sync 扫描 :57-61；AC3 CRC :122；duration :141 |
| `ff_adts_header_parse` | adts_header.c:30 | 12bit 同步 :37；13bit 帧长 :56；samples :69 |
| `ac3_sync` | ac3_parser.c:444 | 查表 :345 / 等式 :361；帧类型 :466-467 |
| `parse_packet` | libavformat/demux.c:1178 | 循环 :1215；pts 一次性消费 :1224；抄 parser->pts :1288；KEY flag :1296 |
| parser 惰性初始化 | demux.c:1482-1496 | need_parsing→parser flag 翻译 |
| `compute_pkt_fields` | demux.c:983 | B帧反推 :1025；TIMESTAMPS 修正 :1078 |
| TS 挂接 | mpegts.c:957-961 | 33bit 声明 + 默认 FULL |
| RTP 挂接 | rtpdec_h264.c:416 / rtsp.c:255 | handler.need_parsing → 流 |
