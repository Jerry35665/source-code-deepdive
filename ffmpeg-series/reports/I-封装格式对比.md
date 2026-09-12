# I. 封装格式对比:MKV(Matroska) vs MPEG-TS vs MOV/MP4

> 基于 FFmpeg master(commit 9f63b36a)。三份核心源码:`libavformat/matroskadec.c`(5050 行)、`libavformat/mpegts.c`(3902 行)、`libavformat/mov.c`(12526 行)。以下所有行号均为仓库相对路径,已用 grep/Read 实际核对。

## 1. 全景对比表

| 维度 | Matroska/MKV | MPEG-TS | MOV/MP4 |
|---|---|---|---|
| 结构哲学 | 递归 EBML 元素,静态语法表驱动 | 固定 188 字节包无限流式复用(libavformat/mpegts.h:29) | 盒子(box)树 + moov 随机访问采样表 |
| 核心解析入口 | `ebml_parse` libavformat/matroskadec.c:1259,递归下降 | `handle_packet` libavformat/mpegts.c:3201,逐包状态机 | `mov_read_default` libavformat/mov.c:10126,盒子遍历 |
| probe 打分依据 | 校验 EBML 头 + doctype 字符串 libavformat/matroskadec.c:1623 | 三种包长(188/192/204)统计 0x47 命中率 libavformat/mpegts.c:3470 | 按盒子 tag 打分,ftyp/mdat 满分 libavformat/mov.c:10248 |
| 索引 | Cues 元素,可延迟解析 libavformat/matroskadec.c:2031 | 无索引,靠 PCR/DTS 线性扫描 libavformat/mpegts.c:3783 | stco/stsc/stsz/stts/stss 采样表 libavformat/mov.c:2820/3517/3714/3807/3659 |
| seek | cues 二分 `av_index_search_timestamp` libavformat/matroskadec.c:4520 | 无 read_seek,通用层经 read_timestamp=mpegts_get_dts 扫描 libavformat/mpegts.c:3887 | `mov_seek_stream` 样本级精确跳转 libavformat/mov.c:12303 |
| 时间戳体系 | 容器内纳秒;track 时间基=scale/1e9 libavformat/matroskadec.c:3294 | 90kHz、33bit 回绕,`pts_info(st,33,1,90000)` libavformat/mpegts.c:957 | 每轨独立 media timescale,`pts_info(st,64,1,timescale)` libavformat/mov.c:5591 |
| 错误恢复 | EBML 长度跳过 + 顶层 ID 重同步 libavformat/matroskadec.c:867 | 逐字节找 0x47 `mpegts_resync` libavformat/mpegts.c:3331 | 宽松盒子校验 + 回卷重试 libavformat/mov.c:10227,11587 |
| 字幕 | 原生轨类型 SUBTITLE libavformat/matroskadec.c:3319 | DVB 字幕只是 PMT 里一种 stream_type | tx3g/movtext 作为普通 sample |
| 附件 | Attachments 元素→attachment 流 libavformat/matroskadec.c:3508 | 无 | 无(静态图走 HEIF iloc/iinf) |
| 章节 | ChapterAtom→`avpriv_new_chapter` libavformat/matroskadec.c:3557 | 无 | 章节轨 `mov_read_chapters` libavformat/mov.c:10343 |
| 流数量上限 | max_streams(默认 1000,libavformat/options_table.h:109),libavformat/matroskadec.c:1342 检查 | PID 表固定 8192 项 libavformat/mpegts.h:32 | 无显式上限,受通用 max_streams 约束 |
| 直播适配 | WebM 直播(unknown-length 元素)libavformat/matroskadec.c:1288 | 天生直播,`AVFMT_TS_DISCONT` libavformat/mpegts.c:3880 | fMP4(trun/tfdt)libavformat/mov.c:6190/6151,HLS/DASH 基石 |

---

## 2. 逐格式解读

### 2.1 Matroska:语法表驱动的递归 EBML

**入口**:libavformat/matroskadec.c:5038 注册 `ff_matroska_demuxer`,probe/header/packet/seek 四件套在 libavformat/matroskadec.c:5045-5050。probe(libavformat/matroskadec.c:1623)只认 EBML 头 ID(libavformat/matroskadec.c:1629)与 "matroska"/"webm" doctype 字符串(libavformat/matroskadec.c:841,1657-1664),命中返回满分;有 EBML 头但 doctype 未识别也给扩展名分(libavformat/matroskadec.c:1667)。

**EBML 基元**:一切从变长整数开始。`ebml_read_num`(libavformat/matroskadec.c:914)靠首字节前导 0 的个数确定字段长度(libavformat/matroskadec.c:927),这是整个格式自描述能力的根基;`ebml_read_length` 据此识别 "unknown length"(全 1 形式,libavformat/matroskadec.c:979-986)。解析主循环 `ebml_parse`(libavformat/matroskadec.c:1259)读 id+长度后查静态语法表分派:

```c
// libavformat/matroskadec.c:1481-1500(节选)
switch (syntax->type) {
case EBML_UINT:  res = ebml_read_uint(pb, length, syntax->def.u, data);  break;
case EBML_SINT:  res = ebml_read_sint(pb, length, syntax->def.i, data);  break;
case EBML_FLOAT: res = ebml_read_float(pb, length, syntax->def.f, data); break;
case EBML_STR:
case EBML_UTF8:  res = ebml_read_ascii(pb, length, syntax->def.s, data); break;
case EBML_BIN:   res = ebml_read_binary(pb, length, pos_alt, data);      break;
case EBML_LEVEL1:
case EBML_NEST:
    if ((res = ebml_read_master(matroska, length, pos_alt)) < 0)
        return res;
```

`ebml_parse_nest`(libavformat/matroskadec.c:1169)递归下钻,`EBML_STOP` 哨兵表示"回到上一层"(libavformat/matroskadec.c:470,760,804-805 的用法)。语法表把元素 ID 直接映射到 C 结构体偏移,如 TrackEntry(libavformat/matroskadec.c:647)、CuePoint(libavformat/matroskadec.c:708-709)、Block/BlockGroup(libavformat/matroskadec.c:788-806)。

**header 阶段**:`matroska_read_header`(libavformat/matroskadec.c:3420)依次:解析 EBML 头并校验版本(libavformat/matroskadec.c:3437-3456)→ 解析 Segment(libavformat/matroskadec.c:3475,失败即 `matroska_resync` 循环找回,libavformat/matroskadec.c:3477-3485)→ 执行 SeekHead 补读未见的 Level1 元素,但 **Cues 特意推迟**(libavformat/matroskadec.c:1984-1986)→ 建轨(libavformat/matroskadec.c:3504)→ 附件转流(libavformat/matroskadec.c:3508-3551)→ 章节转换(libavformat/matroskadec.c:3553-3563)→ Cues 入索引(libavformat/matroskadec.c:3565)。

**数据结构总览**:

```
文件: EBML header ─ Segment
Segment─┬─ Info(TimestampScale, 默认 1e6, libavformat/matroskadec.c:475)
        ├─ Tracks ── TrackEntry[](libavformat/matroskadec.c:647)
        │             CodecID + CodecPrivate → extradata
        ├─ SeekHead ── Level1 元素偏移表(libavformat/matroskadec.c:754)
        ├─ Cues ── CuePoint{CueTime + CueTrackPositions}(libavformat/matroskadec.c:708)
        ├─ Chapters ── EditionEntry ── ChapterAtom(libavformat/matroskadec.c:685)
        ├─ Attachments ── AttachedFile(文件名+MIME+二进制)
        └─ Cluster{Timecode}
              └─ SimpleBlock / BlockGroup>Block(libavformat/matroskadec.c:803-805)
                   Block = 轨号(EBML变长) + int16 相对时间 + flags + lacing 头
```

**读包阶段**:`matroska_read_packet`(libavformat/matroskadec.c:4481)循环 `matroska_parse_cluster`(libavformat/matroskadec.c:4427)→`matroska_parse_block`(libavformat/matroskadec.c:4273)。block 内部:EBML 轨号(libavformat/matroskadec.c:4294-4299)、有符号 16bit 块内时间 `sign_extend(AV_RB16(data),16)`(libavformat/matroskadec.c:4315),加上 cluster 时间码并扣除 codec_delay 得最终时间码(libavformat/matroskadec.c:4322-4325);关键帧回填流索引(libavformat/matroskadec.c:4329-4333);lacing 拆多帧(libavformat/matroskadec.c:3612,Xiph 前缀长度法 libavformat/matroskadec.c:3633-3648);最后 `matroska_parse_frame`(libavformat/matroskadec.c:4152)入内部队列(libavformat/matroskadec.c:4258)。

**时间戳体系**:容器内部一律纳秒。每轨声明 `avpriv_set_pts_info(st, 64, matroska->time_scale * track->time_scale, 1000*1000*1000)`(libavformat/matroskadec.c:3294-3295,注释即 "64 bit pts in ns")——默认分子 1e6×1.0,实际时间基 1/1000 毫秒精度;TimestampScale=1 的文件才真正到纳秒。块时长默认值同样从 ns 换算(libavformat/matroskadec.c:4367-4370),discard_padding 亦然(libavformat/matroskadec.c:4241-4243)。

**容错**:三道防线。(1) 未知元素按长度 `avio_skip` 跳过继续(libavformat/matroskadec.c:1520-1540);(2) 不可 seek 流上的启发式失步检测:未知元素计为 50KB 等效字节,连续未知超过 3 个再叠加距最近好点的距离,合计超 1MB 判定数据损坏(libavformat/matroskadec.c:88-93,1428-1468);(3) 彻底失步时 `matroska_resync`(libavformat/matroskadec.c:867)逐字节滑窗匹配 8 个顶层元素 ID(libavformat/matroskadec.c:885-899)。另有层级一致性检查:子元素越出父元素边界直接报错(libavformat/matroskadec.c:1368-1384)。

### 2.2 MPEG-TS:188 字节包的流水线状态机

**入口**:libavformat/mpegts.c:3877 注册 `ff_mpegts_demuxer`,标志 `AVFMT_SHOW_IDS | AVFMT_TS_DISCONT`(libavformat/mpegts.c:3880),**没有 read_seek**,只挂 `read_timestamp = mpegts_get_dts`(libavformat/mpegts.c:3887)。probe(libavformat/mpegts.c:3470)用 `analyze`(libavformat/mpegts.c:612-638)在 188/192/204 三种步长下统计"位置对齐的 0x47 + 合法 AF 字段"命中数(libavformat/mpegts.c:3485-3488),再按块命中率换算总分(libavformat/mpegts.c:3498-3510)。同步字节常量 `SYNC_BYTE` 与包长定义于 libavformat/mpegts.h:27-30。

**header 阶段**:`mpegts_read_header`(libavformat/mpegts.c:3550)先 `get_packet_size` 自适应包长(libavformat/mpegts.c:3561),在 SDT/PID 0(PAT)/EIT 三个 PID 上开 section 过滤器(libavformat/mpegts.c:3575-3577),再用 `handle_packets(ts, probesize/188)` 做首轮服务扫描(libavformat/mpegts.c:3579);随后置 `AVFMTCTX_NOHEADER`——TS 根本没有"文件头"(libavformat/mpegts.c:3586),流随着 PMT/PES 的到来动态创建(libavformat/mpegts.c:1281-1285;auto_guess 兜底 libavformat/mpegts.c:3211-3213)。

**数据流总览**:

```
包结构: 0x47 | TEI PUSI 优先级 | PID(13bit) | SCR(2) AFC CC(4) | [adaptation] | payload
           │                          │                    │
   PID 0x0000 → PAT(pat_cb,     libavformat/mpegts.c:2966)      AFC bit4=1 → PCR
   │            sid→pmt_pid 映射(libavformat/mpegts.c:2994-3007) parse_pcr(libavformat/mpegts.c:3515)
   │                                              base:33bit + ext:9bit(libavformat/mpegts.c:3535-3537)
   PMT(pmt_cb, libavformat/mpegts.c:2740) ── stream_type → mpegts_open_pes_filter
   │
   PES: 00 00 01 stream_id(libavformat/mpegts.c:1262-1265)
        → header[8] 定长头(libavformat/mpegts.c:1334)
        → PTS/DTS 各 5 字节 33bit(ff_parse_pes_pts, libavformat/mpeg.h:69;
          装配分支 libavformat/mpegts.c:1356-1364)
        → 跨包累积至 MPEGTS_PAYLOAD(libavformat/mpegts.c:1463)
        → PUSI 到来/长度收口 → new_pes_packet(libavformat/mpegts.c:1070,1477)
```

**PES 组装**是 TS demuxer 的心脏:`mpegts_push_data`(libavformat/mpegts.c:1224)是一台按 `PESContext.state` 推进的状态机(HEADER→PESHEADER→PESHEADER_FILL→PAYLOAD→SKIP)。`PES_packet_length=0` 表示无界 PES,只能靠同一 PID 下一个 PUSI 包收口(libavformat/mpegts.c:1288-1289,1236-1244)。每个 PID 有 4bit 连续计数器 cc,失配只把包标 `AV_PKT_FLAG_CORRUPT` 而不中断(libavformat/mpegts.c:3233-3248);TEI 传输错误标志同理(libavformat/mpegts.c:3251-3257)。

**时间戳体系**:流声明 33bit/90kHz(libavformat/mpegts.c:957,996)。33bit@90kHz 约 26.5 小时回绕一次,demuxer 本身不做显式展开运算,而是:标志 `AVFMT_TS_DISCONT`(libavformat/mpegts.c:3880)声明不连续可能 + 向后继承 `pts_wrap_reference/pts_wrap_behavior`(libavformat/mpegts.c:1433-1434),由通用层统一处理;无 PTS 的流可用 PCR 时间兜底(libavformat/mpegts.c:1878)。PCR 本身是 33bit 基数 + 9bit 300 倍数扩展(libavformat/mpegts.c:3535-3537),`mpegts_read_header` 的 raw 分支还用一对 PCR 估算码率(libavformat/mpegts.c:3616-3638)。

**容错**:读到的包首字节非 0x47 即进 `mpegts_resync`(libavformat/mpegts.c:3331):先按 seekback 回退,再逐字节最多 `resync_size` 次找同步字节(libavformat/mpegts.c:3347-3366),期间重新探测包长并告警切换(libavformat/mpegts.c:3358-3361);含针对个别畸形文件的 0x80/偏移 12 特例(libavformat/mpegts.c:3340-3343)。`handle_packets` 检测到外部 seek 会整体冲刷所有 PID 的 PES 状态(libavformat/mpegts.c:3425-3443)。

### 2.3 MOV/MP4:盒子树 + 精确采样表

**入口**:libavformat/mov.c:12513 注册 `ff_mov_demuxer`,扩展名一大串(libavformat/mov.c:12517),标志 `AVFMT_NO_BYTE_SEEK | AVFMT_SEEK_TO_PTS`(libavformat/mov.c:12518)。probe(libavformat/mov.c:10248)沿 size+tag 链遍历文件头:ftyp/mdat/moov/pnot/udta 给满分(libavformat/mov.c:10277-10292),free/wide/ediw/junk 等常见词给次分(libavformat/mov.c:10295-10301),还专门防"MOV 打包的 MPEG-PS"误判(hdlr/mhlr/MPEG 组合,libavformat/mov.c:10316-10337)。

**解析循环**:`mov_read_header`(libavformat/mov.c:11574)把整个文件当作一个 root atom 交给 `mov_read_default`(libavformat/mov.c:10126):

```c
// libavformat/mov.c:10140-10187(节选)
while (total_size <= atom.size - 8) {
    a.size = avio_rb32(pb);          /* 32 位 size */
    a.type = avio_rl32(pb);          /* fourcc tag */
    ...
    if (a.size == 1 && total_size + 8 <= atom.size) { /* 64 位扩展 size */
        a.size = avio_rb64(pb) - 8;
        ...
    }
    if (a.size == 0) { a.size = atom.size - total_size + 8; } /* 到父盒末尾 */
    ...
    for (i = 0; mov_default_parse_table[i].type; i++)
        if (mov_default_parse_table[i].type == a.type) { parse = ...; }
    if (!parse) { avio_skip(pb, a.size); }   /* 未注册的盒子直接跳过 */
```

解析表 libavformat/mov.c:9992 起(ctts→libavformat/mov.c:10002,mdat→10016,moov→10022);递归容器(moov/trak/minf...)递归为 `mov_read_default` 自身。盒子深度上限 10(libavformat/mov.c:10132-10135);找到 moov+mdat 即提前收工(libavformat/mov.c:10219-10226);moov 缺失时回卷重试一次(libavformat/mov.c:11587-11596)——这正是"moov 在尾部的 MP4 网络播放体验差"的代码根源。

**stbl 索引体系**:`mov_read_trak`(libavformat/mov.c:5555)为每轨建流,时间基取自 mdhd 的 timescale(libavformat/mov.c:2028,`pts_info` 在 libavformat/mov.c:5591),随后 `mov_build_index`(libavformat/mov.c:4960,调用点 libavformat/mov.c:5606)把四张表联立展开为线性 sample 索引(libavformat/mov.c:5046-5052 分配,libavformat/mov.c:5058 起按 chunk×stsc 双层循环,关键帧来自 stss libavformat/mov.c:5082-5085 与 stps libavformat/mov.c:5086-5089):

```
ftyp ─ moov ─ mvhd(全局 timescale, libavformat/mov.c:2055)
       │    ├ trak ─ tkhd / mdia ─ mdhd(轨 timescale, libavformat/mov.c:2028)
       │    │        └ minf ─ stbl:
       │    │            stco/co64  块(chunk)文件偏移   libavformat/mov.c:2820
       │    │            stsc       第 n 块含多少 sample     libavformat/mov.c:3517
       │    │            stsz       每个 sample 的大小        libavformat/mov.c:3714
       │    │            stts       sample → delta(时长)    libavformat/mov.c:3807
       │    │            stss       关键 sample 号            libavformat/mov.c:3659
       │    │            ctts       合成时间偏移(B 帧)      libavformat/mov.c:3976
       │    └ edts ─ elst(编辑列表, libavformat/mov.c:6735)
       └ mdat ────────── 媒体数据,stbl 表即指向这里的坐标 ──────────
fMP4: moof ─ trun(libavformat/mov.c:6190) + tfdt(libavformat/mov.c:6151) 逐片追加样本
```

**读包**:`mov_read_packet`(libavformat/mov.c:12059)用 `mov_find_next_sample`(定义 libavformat/mov.c:11809,调用 libavformat/mov.c:12105)在多轨间按 DTS 选最小者,然后 `avio_seek(sc->pb, sample->pos, SEEK_SET)` 直接寻址读取(libavformat/mov.c:12124)——**读包即寻址**,与 MKV/TS 的顺序解析是本质区别。

**edit list 简述**:`mov_read_elst`(libavformat/mov.c:6735)读 duration/time/rate(v1 每项 20 字节,libavformat/mov.c:6749);`mov_build_index` 用首项空编辑(time=-1)计算 `sc->time_offset` 并平移初始 DTS(libavformat/mov.c:5007-5018),AAC 的 priming 采样数转为 `initial_padding`(libavformat/mov.c:5020-5023);多项编辑需 `-advanced_editlist` 才能精确处理(libavformat/mov.c:4996-5004)。

---

## 3. Seek 三方对比专节

| 步骤 | MKV | TS | MOV |
|---|---|---|---|
| 索引来源 | Cues→`av_add_index_entry`(libavformat/matroskadec.c:2023);流中关键帧也回填(libavformat/matroskadec.c:4331) | 无 | stbl 多表→全量 sample 索引(libavformat/mov.c:5046) |
| 查找方式 | `av_index_search_timestamp` 二分(libavformat/matroskadec.c:4520) | 通用层 ff_gen_seek + `read_timestamp` 探测 | 同一二分(libavformat/mov.c:12320) |
| 物理定位 | `matroska_reset_status` seek 到 cluster(libavformat/matroskadec.c:4545) | 按包边界对齐逐包扫 DTS/PCR(libavformat/mpegts.c:3758-3777,3783) | seek 到具体 sample 的字节偏移(libavformat/mov.c:12124) |
| 后续过滤 | skip_to_keyframe 门控(libavformat/matroskadec.c:4336-4349) | 无,读到的包直接输出 | current_sample 游标递增(libavformat/mov.c:12116) |
| 复杂度 | O(log n) + 一次 cluster 解析 | O(距离),与目标位置远近成正比 | O(log n),最精确 |

**MKV**:Cues 通常在文件尾,header 阶段故意不解析(`matroska_execute_seekhead` 对 CUES 直接 continue,libavformat/matroskadec.c:1984-1986),首次 seek 才补解析(libavformat/matroskadec.c:4510-4514);索引为空或落在末项时边解析 cluster 边等(libavformat/matroskadec.c:4520-4529),彻底失败则返回 -1 退回通用 seek(libavformat/matroskadec.c:4516,4557-4566)。

```c
// libavformat/matroskadec.c:4510-4520(节选)
/* Parse the CUES now since we need the index data to seek. */
if (matroska->cues_parsing_deferred > 0) {
    matroska->cues_parsing_deferred = 0;
    matroska_parse_cues(matroska);
}
if (!sti->nb_index_entries)
    goto err;                                  /* 无索引 → 通用 seek */
timestamp = FFMAX(timestamp, sti->index_entries[0].timestamp);
if ((index = av_index_search_timestamp(st, timestamp, flags)) < 0 || ...
```

**TS**:demuxer 没有注册 read_seek(libavformat/mpegts.c:3877-3889 无此字段),由通用层用 `read_timestamp`(即 `mpegts_get_dts`,libavformat/mpegts.c:3783)做"二分逼近+线性确认":按 `raw_packet_size` 对齐后逐包读(libavformat/mpegts.c:3789-3790),失步就地 resync(libavformat/mpegts.c:3766-3771);原始流另有 `mpegts_get_pcr` 供 PCR 定位(libavformat/mpegts.c:3749-3781)。代价:seek 耗时与目标位置成正比,且结果精度只有"关键帧/PES 边界"级。

**MOV**:`mov_seek_stream`(libavformat/mov.c:12303)先把 PTS 目标换算到 DTS 时间线(libavformat/mov.c:12313,考虑 edit list 偏移),二分定位后处理"落点非关键帧"问题:用 `can_seek_to_key_sample` 判定,不行就按 `min_sample_duration` 回退时间戳重试(libavformat/mov.c:12327-12342);随后同步修正 tts/stsc 两个游标供读包循环使用(libavformat/mov.c:12347-12373)。外层 `mov_read_seek`(libavformat/mov.c:12394)在 seek_individually 模式下对每条流单独换算时间基各跳一次(libavformat/mov.c:12411-12427)。样本级精度 + O(log n),三者中最快最准。

---

## 4. 设计动机

**为什么直播行业选 TS**:
1. 固定 188 字节包 + 0x47 同步字节(libavformat/mpegts.h:29),任意字节位置接入都能 `mpegts_resync` 快速恢复(libavformat/mpegts.c:3331-3366)——丢包/换台/信号劣化的场景下这是生命线;
2. PAT/PMT/SDT 周期性重发(pat_cb 循环解析 libavformat/mpegts.c:2994-3007),中途加入的观众无需等待"文件头";
3. 无索引、无文件尾概念,`AVFMTCTX_NOHEADER` 边播边建流(libavformat/mpegts.c:3586);
4. 90kHz 33bit PCR 提供发射端统一时钟(libavformat/mpegts.c:3535-3537),解码器有绝对的音视频同步锚点,还能反推码率(libavformat/mpegts.c:3638);
5. 4bit 连续计数器让传输丢包可量化检测(libavformat/mpegts.c:3241-3248)。
广电/运营商链路对"随时接入、随时丢失"的容错要求压倒了封装开销——每包 4 字节头、无索引冗余,都是为此支付的税。

**为什么 MOV 适合剪辑**:
1. sample 表把"时间↔字节"映射做成查表:stco 定块、stsc 数样、stsz 定长、stts 累加时间、stss 标关键帧(libavformat/mov.c:2820-3976),O(log n) 精确到单个 sample——剪辑软件的拖动/裁剪即查表;
2. 每轨独立 timescale(libavformat/mov.c:2028),精确匹配媒体固有采样率/帧率,无取整漂移;
3. ctts 显式表达 B 帧合成偏移(libavformat/mov.c:3976),解码顺序与显示顺序解耦;
4. edit list 原生描述裁剪、延迟、变速(libavformat/mov.c:6735),改时间线不必重写 mdat;
5. chunk 内 sample 连续存放,对磁盘顺序读友好。
代价:索引(元数据)必须先于媒体可得,moov 在尾部则需回卷重扫(libavformat/mov.c:11587),这正是"faststart(moov 前置)"存在的理由。

**MKV 的"什么都能装"**:
1. EBML 递归元素天然可扩展——未知元素按长度跳过即可继续(libavformat/matroskadec.c:1520-1540),新版本语法对老解析器向后兼容;
2. 轨类型只是标签:视频/音频/字幕/附件/章节同构存放,附件直接嵌入文件(libavformat/matroskadec.c:3508-3551);
3. 块级压缩(zlib/lzo/头剥离)按轨可选(libavformat/matroskadec.c:1684-1747);
4. unknown-length 元素支持边写边播的直播/WebM(libavformat/matroskadec.c:1288-1296);
5. 纳秒时间基(libavformat/matroskadec.c:3294)消除取整误差,Subtitle 轨还能声明重叠但不互为关键帧(libavformat/matroskadec.c:4326-4328)。
灵活性换来的代价:解析必须携带完整语法表、seek 依赖文件尾的 Cues(libavformat/matroskadec.c:4510),流式场景索引缺位时体验劣化。

---

## 5. FAQ 素材

1. **TS 为什么是 188 字节?** `TS_PACKET_SIZE 188`(libavformat/mpegts.h:29);另有 192(DVHS,前 4 字节 TP_extra_header,读包时跳过 libavformat/mpegts.c:3380-3384)和 204(FEC)两种变体(libavformat/mpegts.h:27-28),probe 三种都试(libavformat/mpegts.c:3485-3488),运行期失步时还会重新探测并切换(libavformat/mpegts.c:3358-3361)。
2. **PES 长度为 0 怎么办?** 0 表示无界 PES(常见于视频),依赖同一 PID 下一个 PUSI 包收口(libavformat/mpegts.c:1288-1289,1236-1241)。
3. **PTS 33bit 何时回绕?怎么处理?** 90kHz 下约 26.5 小时;demuxer 只声明 33bit 时间基(libavformat/mpegts.c:957),显式回绕运算交给 `AVFMT_TS_DISCONT`(libavformat/mpegts.c:3880)与 pts_wrap_reference 继承机制(libavformat/mpegts.c:1433-1434);无 PTS 的流可用 PCR 兜底(libavformat/mpegts.c:1878)。
4. **TS 没有文件头怎么建流?** 先扫 PAT/SDT/EIT(libavformat/mpegts.c:3575-3579),PMT 到达才按 stream_type 建 PES 流;PES 已到而 PMT 未到时由 auto_guess 兜底建流(libavformat/mpegts.c:3211-3213,1281-1285)。
5. **MKV 的 seek 为什么可能慢?** Cues 通常在文件尾,header 阶段推迟解析(libavformat/matroskadec.c:1984-1986),首次 seek 才解析(libavformat/matroskadec.c:4510-4514);无 Cues 且无法回退时整体退化到通用 seek(libavformat/matroskadec.c:4557-4566)。
6. **MKV Block 的时间码为什么是有符号 16bit?** 块内时间是相对 cluster Timecode 的偏移,`sign_extend(AV_RB16(data),16)`(libavformat/matroskadec.c:4315),加上 cluster 时间再扣 codec_delay(libavformat/matroskadec.c:4324-4325)。
7. **MP4 的 moov 在文件尾会怎样?** `mov_read_header` 找不到 moov 会回卷重试一次(libavformat/mov.c:11587-11596);顺序读的网络流因此最坏要读两遍文件,催生 faststart 把 moov 挪到开头。
8. **MOV 如何知道哪帧是关键帧?** stss 表列关键 sample 号(libavformat/mov.c:3659);无 stss 视为全关键帧(`keyframe_absent`,libavformat/mov.c:3683);stps 补充 open-GOP 同步点(libavformat/mov.c:5086-5089);build_index 时统一合入 AVIndex(libavformat/mov.c:5082-5085)。
9. **三种格式各能装多少条流?** MKV 受 `max_streams`(默认 1000,libavformat/options_table.h:109)约束,超限报错(libavformat/matroskadec.c:1342-1348);TS 的 PID 过滤表固定 8192 项(libavformat/mpegts.h:32),实际受 PMT 描述限制;MOV 无专门上限,受同一通用 max_streams 约束。
10. **为什么 MOV 读包要做 seek 而 TS 不用?** MOV 的 sample 索引直接给出字节偏移,读包即 `avio_seek`(libavformat/mov.c:12124);TS 无索引只能顺序读,失步也只向前找 0x47(libavformat/mpegts.c:3347-3366);MKV 介于两者:有 Cues 时 seek 一次到 cluster,之后仍顺序解析(libavformat/matroskadec.c:4545)。
11. **probe 三家的"信心"来自哪里?** MKV 看文件结构自述(EBML 头+doctype,libavformat/matroskadec.c:1629-1664);TS 看统计规律(三种步长下 0x47 对齐命中率,libavformat/mpegts.c:3498-3510);MOV 看 magic tag(ftyp/mdat 即满分,libavformat/mov.c:10277-10292)。统计型 probe 正是"TS 无自描述头"的镜像。

---

## 6. 深挖方向

1. **fMP4 与 MKV Live 的流式语义对照**:`mov_read_trun`/`mov_read_tfdt`(libavformat/mov.c:6190/6151)如何逐片追加样本索引,对比 MKV unknown-length cluster(libavformat/matroskadec.c:1288-1296)与 Segment 场景,可整理出"两种业界流式封装"的实现对照表。
2. **edit list 全量模拟**:libavformat/mov.c:4977-5024 只处理首项空编辑,multiple_edits 提示需 `-advanced_editlist`(libavformat/mov.c:4996-5004);深挖 advanced 路径的 PTS/DTS 重映射(libavformat/mov.c:4582 附近)与音画同步陷阱。
3. **TS 条件接收(CA)链路**:PES 状态机对 ECM/EMM 等 stream_id 的跳过表(libavformat/mpegts.c:1291-1297),以及 PMT 中 CA 描述符的解析空缺,适合做一期"加扰流在 FFmpeg 里发生了什么"。
4. **MKV BlockAdditions 与杜比视界**:libavformat/matroskadec.c:4219-4231 的 block_additional 如何变成 `AV_PKT_DATA_MATROSKA_BLOCKADDITIONID` 侧数据,以及 dovi 流的独立解析(libavformat/matroskadec.c:3569)。
5. **三格式时间基在通用层的合流**:`av_index_search_timestamp`、`avpriv_update_cur_dts`(MKV 亦调用,libavformat/matroskadec.c:4555)如何统一 ns/90kHz/每轨 timescale 三种体系,以及 TS 33bit 回绕在 utils.c 的最终裁决点。

---

## 写作要点速查表(关键函数 + 行号对照)

| 函数/常量 | 位置 | 一句话 |
|---|---|---|
| ebml_read_num | libavformat/matroskadec.c:914 | EBML 变长整数,前导 0 定长(927) |
| ebml_parse / ebml_parse_nest | libavformat/matroskadec.c:1259 / 1169 | 语法表驱动的递归解析主循环 |
| EBML 元素长度上限 | libavformat/matroskadec.c:1262-1274 | 字符串 16MB、二进制 256MB |
| 轨数超 max_streams | libavformat/matroskadec.c:1342-1348 | 解析期硬限制(上限默认 1000) |
| 子元素越出父元素报错 | libavformat/matroskadec.c:1368-1384 | EBML 层级一致性检查 |
| matroska_probe | libavformat/matroskadec.c:1623 | EBML 头 + doctype 字符串(1657-1664) |
| matroska_resync | libavformat/matroskadec.c:867 | 滑窗匹配 8 个顶层 ID(885-899) |
| Cues 延迟解析 / 补解析 | libavformat/matroskadec.c:1984-1986 / 2031 | 首次 seek 才读 Cues |
| matroska_read_seek | libavformat/matroskadec.c:4501 | 二分 + reset_status(4545) + 关键帧门控(4336) |
| MKV 时间基(纳秒体系) | libavformat/matroskadec.c:3294-3295 | scale×track_scale / 1e9 |
| analyze / mpegts_probe | libavformat/mpegts.c:612 / 3470 | 188/192/204 三步长统计打分 |
| mpegts_resync | libavformat/mpegts.c:3331 | 逐字节找 0x47,上限 resync_size(3347) |
| handle_packet | libavformat/mpegts.c:3201 | PID 分发 + cc 校验(3241) + PCR(3263) |
| pat_cb / pmt_cb | libavformat/mpegts.c:2966 / 2740 | PAT 建 program(2994-3007),PMT 开 PES 过滤 |
| mpegts_push_data | libavformat/mpegts.c:1224 | PES 状态机;PTS/DTS 装配 1356-1364 |
| parse_pcr / ff_parse_pes_pts | libavformat/mpegts.c:3515 / libavformat/mpeg.h:69 | 33bit+9bit / 5 字节→33bit 时间戳 |
| ff_mpegts_demuxer | libavformat/mpegts.c:3877 | 无 read_seek;read_timestamp=mpegts_get_dts(3887) |
| mov_probe / mov_read_default | libavformat/mov.c:10248 / 10126 | tag 打分 / 盒子遍历(深度限 10:10132) |
| stco/stsc/stsz/stts/stss/ctts | libavformat/mov.c:2820/3517/3714/3807/3659/3976 | stbl 索引六件套 |
| mov_build_index | libavformat/mov.c:4960 | 多表展开为线性 sample 索引(5058 起) |
| mov_read_header | libavformat/mov.c:11574 | root atom 遍历;moov 缺失回卷重试(11587) |
| mov_read_packet / mov_find_next_sample | libavformat/mov.c:12059 / 11809 | 跨轨选 DTS 最小者;按偏移直读(12124) |
| mov_seek_stream | libavformat/mov.c:12303 | PTS→DTS 换算(12313)+二分(12320)+关键帧回退(12327) |
| mov_read_elst / edit list 应用 | libavformat/mov.c:6735 / 4977-5024 | 空编辑平移 DTS;AAC priming(5020) |
| ff_mov_demuxer | libavformat/mov.c:12513 | AVFMT_SEEK_TO_PTS(12518);read_seek=mov_read_seek(12525) |
