# AA 章:三大 muxer 写出端深读 —— movenc / matroskaenc / mpegtsenc

> 源码基线:FFmpeg master commit 9f63b36a。所有行号均以 `grep -n` / Read 实际核对。
> 本文与第 10 章(demux 三方)严格镜像:10 章讲"读的时候元数据预算怎么花",本章讲"写的时候索引怎么生产"。
> 第 05 章已讲过 mux 框架层的交织与 faststart 全流程,本文只在各 muxer 内部实现处回指,不重复框架内容。
> MKV 附件写出见 11 章,本文不涉及。

---

## 1. 全景:三种写出策略

```
=== MP4/MOV (movenc):增量采样表 + 最后总装(可两遍搬移) ===
偏移  0                    mdat_pos                    EOF
      | ftyp | free/wide+mdat占位 | mdat: <packet><packet>... | moov(stbl 四表) |
              ^只写 8 字节头,trailer 回填 mdat 大小      ^全部样本写完后才生成
      每收一个 packet: 追加一条 MOVIentry{pos,size,dts,cts,...} 到 track->cluster 数组
      faststart: trailer 时把 mdat 整体后移 moov 大小,moov 写到文件头(ff_format_shift_data)

=== MKV (matroskaenc):顺序流 + 预留位/尾部回填 ===
偏移  0                                                          EOF
      | EBML头 | Segment(未知长度) | SeekHead=Void占位 | Info | Tracks | Chapters |
      | Tags | [Cues=Void占位或留到尾部] | Cluster{TimeCode,SimpleBlock...} x N |
                每收一个 packet: 直接顺序写 block,同时把关键帧 cue 点记进内存数组
      trailer: 组装 Cues 写入(预留位或尾部);seek 回 Segment 长度/Duration 回填

=== TS (mpegtsenc):纯流式 + 周期广播(零回填) ===
      | TS188B | TS | TS | ... |   (没有文件头、没有 trailer、没有任何事后修改)
        每 ~100ms 重发 PAT/PMT,每 ~500ms 重发 SDT,每 ~20ms(CBR)插 PCR
        码率不足处插 PID=0x1FFF 的 null 包;接收方"随时接入,周期内重建节目表"
```

三者的分野本质上是一个问题:**随机访问索引(stbl/Cues)什么时候能定下来?**

- MOV 的索引是**绝对文件偏移**(stco 的 chunk offset),而 moov 要么在尾部(faststart 前要么预留要么搬移),要么根本不知道总大小——所以 FFmpeg 选择"每包记一条内存索引,收尾合成"。
- MKV 的 CuePoint 引用的是**Cluster 起点 + 段内偏移**,Cluster 一旦落盘就不再动,所以索引可以在收尾时一次性补写,甚至可以预留一块 Void 等 Cues 来住。
- TS 干脆没有索引:广播场景里" Seek"由消费端周期性收到的 PCR/PAT/PMT 契约承担(对应 10 章读端 `NOHEADER`/流式解析的镜像——写端根本不给"再读一次开头"的机会)。

---

## 2. movenc 专节(libavformat/movenc.c, 9632 行)

### 2.1 增量维护的不是四表,而是"采样数组"

每个包进入 `ff_mov_write_packet`(libavformat/movenc.c:7009)后,被格式化(AnnexB→AVCC 等)写进 mdat,同时在 per-track 的 `MOVIentry` 数组(movenc.h:49-64,成员见 movenc.h:130 `cluster`)追加一条记录:

```c
// libavformat/movenc.c:7312-7330
if (trk->entry >= trk->cluster_capacity) {
    unsigned new_capacity = trk->entry + MOV_INDEX_CLUSTER_SIZE;   // 1024, movenc.h:32
    ...av_realloc_array...
}
trk->cluster[trk->entry].pos              = avio_tell(pb) - size;  // 采样绝对偏移
trk->cluster[trk->entry].samples_in_chunk = samples_in_chunk;
trk->cluster[trk->entry].dts              = pkt->dts;
trk->cluster[trk->entry].pts              = pkt->pts;
```

这条记录就是日后 stbl 四表的**唯一数据源**。其余增量维护量:
- `trk->track_duration = pkt->dts - trk->start_dts + pkt->duration`(movenc.c:7401);
- `cts = pts - dts`,一旦不等则置 `MOV_TRACK_CTTS`(movenc.c:7408-7410)——ctts 表是否存在在写包时就已定;
- 关键帧置 `MOV_SYNC_SAMPLE` 并累计 `has_keyframes`(movenc.c:7428-7438)——stss 表的数据源;
- `mov->mdat_size += size`(movenc.c:7453),供 mdat 大小回填与 fragment 切分判断。

### 2.2 四表的"收尾合成"

四表全部在 `mov_write_moov_tag`(libavformat/movenc.c:5372)触发时生成。写 moov 前先 `build_chunks`:

```c
// libavformat/movenc.c:5245-5266 (节选)
static void build_chunks(MOVTrack *trk) {
    MOVIentry *chunk = &trk->cluster[0];
    chunk->chunkNum = 1;
    for (i = 1; i < trk->entry; i++) {
        if (chunk->pos + chunkSize == trk->cluster[i].pos &&       // 物理连续
            chunk->stsd_index == trk->cluster[i].stsd_index &&
            chunkSize + trk->cluster[i].size < (1 << 20)) {        // 单 chunk < 1MB
            chunkSize += ...; chunk->samples_in_chunk += ...;      // 并入当前 chunk
        } else { trk->cluster[i].chunkNum = chunk->chunkNum + 1; ... }
    }
}
```

调用点在 mov_write_moov_tag 内(libavformat/movenc.c:5389)。之后:
- **stco/co64**(movenc.c:201-222):只输出 `chunkNum != 0` 的项(214-215),偏移 = `cluster[i].pos + data_offset`;是否 64 位由 `co64_required`(177-182,最后一采样超 UINT32_MAX)决定;
- **stsc**(movenc.c:261-289):仅在 `samples_in_chunk` 或 `stsd_index` 变化处写一条(273-274),条目计数用"先占位后回写"(283-286)完成;
- **stsz**(movenc.c:225-258):先扫一遍判断等长(236-241),等长则只写 24 字节头(242-246),否则逐样本;
- **stss/stps**(movenc.c:292-313)、**sdtp**(movenc.c:316-337)同理,遍历 flags 数组合成。

stbl 装配点见 movenc.c:3462-3464(stsc 在 stco 前)。

### 2.3 moov 写出时机:三档

1. **默认**:mdat 先占位(`mov_write_mdat_tag`,movenc.c:6213-6221,写 `free/wide + 8字节 mdat 头`),trailer 时 `mov_write_mdat_size` 回填真实大小(movenc.c:9074-9094,超 4GB 时回写 64 位扩展 size 到 `wide` 占位,9086-9093),然后 moov 追加在文件尾(9200-9201)。
2. **`-movflags faststart`**:见 2.4。
3. **fragment 系(delay_moov/empty_moov)**:`mov_flush_fragment` 中首簇前写首个 moov(movenc.c:6776-6805),且要求所有 track 都有数据才写(6781-6786);此后每个 fragment 是 `moof+mdat` 对(6868-6910)。DASH/CMAF/ISMV 自动开启相应 flag 组合(8256-8265)。注意 empty_moov 会主动关掉框架的自动 bsf(8267-8270)——因为 init segment 已经定型,事后修正码流为时已晚。

### 2.4 faststart:movenc 侧的两遍(moov 不落盘、直接搬数据)

第 05 章讲了框架层"第二遍"的语义,这里看 movenc 怎么实现"moov 到底多大"这个先有鸡还是先有蛋的问题:

```c
// libavformat/movenc.c:9019-9042 (节选)
static int compute_moov_size(AVFormatContext *s) {
    moov_size = get_moov_size(s);            // 在 null buffer 里空跑一遍 mov_write_moov_tag
    for (i = 0; i < mov->nb_tracks; i++)
        mov->tracks[i].data_offset += moov_size;
    moov_size2 = get_moov_size(s);           // 再跑一遍
    /* if the size changed, we just switched from stco to co64 */
    if (moov_size2 != moov_size)
        for (...) mov->tracks[i].data_offset += moov_size2 - moov_size;
    return moov_size2;
}
```

`get_moov_size`(movenc.c:8988-8999)把 moov 写进 null sink 量尺寸;**必须跑两遍**,因为把 moov 挪到头部后采样偏移整体平移,32 位 stco 可能越界翻成 64 位 co64,表变大,moov 自身也变大(注释在 9013-9018)。真正的搬移由 `shift_data`(movenc.c:9059-9072)调 `ff_format_shift_data` 从后向前拷贝完成,最后 trailer 回到 `reserved_header_pos` 正式写 moov(9178-9185)。faststart 会自动启用 `-moov_size` 的自动估算模式(`reserved_moov_size = -1`,movenc.c:8277-8278);若用户手动给了 `moov_size`,则在头部预留 free 原子,不够时直接报错(9190-9193)。

### 2.5 fragmented MP4:moof/mfhd/tfhd/tfdt/trun

fragment 模式下数据先进 per-track 动态缓冲 `trk->mdat_buf`(movenc.c:7048-7052);`frag_interleave` 选项(85)会把多轨缓冲汇入全局 mdat_buf 并给采样 pos 加累计偏移(`mov_flush_fragment_interleaving`,movenc.c:6587-6610)。

每个 fragment 落盘:`mov_write_moof_tag` → `mov_write_moof_tag_internal`(movenc.c:5943-5965),结构为 `moof{ mfhd, traf{ tfhd, tfdt, trun... } }`:
- **mfhd**:sequence number = `mov->fragments`(movenc.c:5630-5637);
- **tfhd**(movenc.c:5645-5709):base-data-offset 默认指向 moof 起点(5680-5681);default sample flags 取"第二个采样"的属性做默认(5696-5705)——首采样异常可用 first-sample-flags 单独表达;
- **tfdt**(movenc.c:5889-5897):`baseMediaDecodeTime = track->cluster[0].dts - track->start_dts`,即片段内时间轴;
- **trun**(movenc.c:5711-5762):只在采样属性偏离 tfhd 默认值时才带对应字段(5719-5729),CTTS 由 `MOV_TRACK_CTTS` 决定(5730-5731);traf 内若采样在物理上不连续,则拆成多个 trun(movenc.c:5913-5919)。

每写完一个 fragment,`mov_finish_fragment`(movenc.c:6674-6704)清空 `track->entry`,下一个 fragment 的索引重新从 0 计——**fragment 模式下 stbl 四表被 trun 取代,内存占用从 O(总样本) 降到 O(单片段样本)**。fragment 长度触发条件在 `mov_write_single_packet`(movenc.c:7527-7553):max_fragment_duration / max_fragment_size / frag_keyframe / frag_every_frame。

### 2.6 edit list(elst)写出

`mov_write_edts_tag`(movenc.c:4166-4272):
- `delay = start_dts + start_ct`(换算到 movie timescale,4190-4191);首包 dts>0 时写**两条 elst**:第一条空编辑(duration=delay, media_time=-1)把呈现整体后推,第二条承载真实内容(4218-4231);
- 首包 dts<0 时用 `start_ct = -FFMIN(start_dts, 0)` 把负时间裁掉(4232-4238);
- fragment 模式不知道总长,duration 直接写 0 表示"到文件尾"(4258-4260)。
是否使用 elst 由 `use_editlist` 选项控制;fragment 且非 delay_moov、`avoid_negative_ts` 为 AUTO/MAKE_ZERO 时自动关闭(movenc.c:8281-8290)。

---

## 3. matroskaenc 专节(libavformat/matroskaenc.c, 3800 行)

### 3.1 写出序:一切元素都可能是"暂缓的 dyn buffer"

`mkv_write_header`(libavformat/matroskaenc.c:2662)顺序:EBML 头(2684)→ Segment 且**长度写 unknown**(2685-2687,记录 `segment_offset`)→ SeekHead 占位(2691)→ Info(2693)→ Tracks(2697)→ Chapters(2701)→ Attachments(2706)→ Tags(2713)。关键点:**Info/Tracks/Tags 都不是直接落盘**,而是写进各自 `AVIOContext` 动态缓冲(mkv_deinit 里可见 `mkv->info.bc / track.bc / tags.bc`,matroskaenc.c:884-887),trailer 时才 seek 回各自 `pos` 正式 flush——因为 duration、codecprivate、DURATION tag 都要等数据写完才知道。Info 里的 Duration 空间在 header 时就留好:已知 duration 直接写,未知则 `put_ebml_void(pb, 11)`(matroskaenc.c:2640-2656,11 字节 = 双精度 float)。

### 3.2 SeekHead:预留 Void、回填、再 Void

```c
// libavformat/matroskaenc.c:901-909
static void mkv_start_seekhead(MatroskaMuxContext *mkv, AVIOContext *pb) {
    mkv->seekhead.filepos = avio_tell(pb);
    // 21 bytes max per Seek entry, 6+6 for ID/size, 6 for CRC32, 2 for a Void
    mkv->seekhead.reserved_size = MAX_SEEKHEAD_ENTRIES * MAX_SEEKENTRY_SIZE + 14;  // 7*21+14
    put_ebml_void(pb, mkv->seekhead.reserved_size);
}
```

`MAX_SEEKHEAD_ENTRIES = 7`(matroskaenc.c:77)、`MAX_SEEKENTRY_SIZE = 21`(271)。写包过程中只往内存数组 `mkv_add_seekhead_entry` 登记;trailer 时 `mkv_write_seekhead`(matroskaenc.c:921-960)seek 回 `filepos` 重写真实 SeekHead,剩余空隙用 Void 填满保证后续元素偏移不变(953-954)。非 seekable 输出(管道)时 header 阶段就立即写(matroskaenc.c:2717-2721)——此时各 level-1 元素刚好都已写完,顺序成立。

### 3.3 Cues 的延迟生成:写包记账,trailer 结账

- **记账**:每个关键帧块写完后,若可 seek 且属于(video / 字幕 / 无视频轨时的每轨首个音频 cue)(matroskaenc.c:3181-3191),调 `mkv_add_cuepoint`(matroskaenc.c:962-991)——**按 pts 排序插入**内存数组(977-981,处理交织器吐出的乱序);
- **结账**:trailer 里 `mkv_assemble_cues`(matroskaenc.c:3325-3339 调用,实现在 994-1041)把数组合成 Cues:相同 pts 的多轨条目合并进同一个 CuePoint(1004-1022)。

预留技巧与 SeekHead 同款:`-reserve_cues_space` 在 header 阶段记下 `mkv->cues_pos` 并 Void 占位(matroskaenc.c:2729-2739);trailer 把 Cues 写进预留位,不够时优先 `ff_format_shift_data` 平移(3346-3367),再不够则放弃 Cues 并告警(3352-3357);`move_cues_to_front` 变体允许把 Cues 挪到 Segment 最前(3347-3350 的 redo 循环重算偏移)。

### 3.4 Cluster 分裂条件

```c
// libavformat/matroskaenc.c:3232-3237 (非 DASH)
} else if (!mkv->is_dash &&
           (cluster_size > mkv->cluster_size_limit ||      // 默认 5MB(seekable)
            cluster_time > mkv->cluster_time_limit ||      // 默认 5s(seekable)
            (codec_type == AVMEDIA_TYPE_VIDEO && keyframe &&
             cluster_size > 4 * 1024))) {                  // 视频关键帧且已 >4KB
    start_new_cluster = 1;
}
```

默认值:seekable 5MB/5s,非 seekable 32KB/1s(matroskaenc.c:2745-2755)。另外两个隐性分裂:(1) 块的相对时间超出 int16 表示域时强制开新 Cluster(3146-3154,SimpleBlock 的 relative timestamp 只有 16 位);(2) WebM DASH 下视频只在关键帧分簇、音频按 time_limit(3223-3231)。Cluster 本体也是先写进 `mkv->cluster_bc` 动态缓冲(3157-3168,带头部 ClusterTimeCode),`mkv_end_cluster`(3033-3050)带 CRC 落盘——这样 EBML master 的长度字段能以最小编码写出。音频包会被缓存一个(`mkv->cur_audio_pkt`,3254-3270),保证紧随视频关键帧时间码的音频块进同一个 Cluster。块级选择:仅含 Block 的 BlockGroup 降级为 SimpleBlock(3014-3021),非关键帧才需要 BlockGroup+BlockReference(3022-3024)。

### 3.5 延迟回填清单(trailer, matroskaenc.c:3292-3493)

1. Segment 真实长度:seek 回 `segment_offset - 8` 补 8 字节 length(3397-3401);
2. SeekHead 回填(3403);
3. Info.Duration:seek 进 `mkv->info.bc` 的 `duration_offset` 写 double,再整块 CRC 落盘(3407-3416);时长来自增量维护的 `mkv->duration = FFMAX(..., ts + duration)`(3194);
4. Tracks(可能被运行时 codecprivate 更新过,3418-3450)与 Tags 里的 per-stream DURATION 字符串 tag(3453-3488)。

---

## 4. mpegtsenc 专节(libavformat/mpegtsenc.c, 2471 行)

### 4.1 没有 header 的 muxer

AVOutputFormat 里 `.init = mpegts_init` 而没有 `.write_header`,trailer 只是 `mpegts_write_end` 做收尾 flush(mpegtsenc.c:2455-2471)。文件就是从第一个字节起、无限长的 188 字节包序列——与 10 章读端 TS "纯流式、无长度预算" 完全互为镜像。

### 4.2 PES 打包链:bytes → PES → 188 字节 TS

入口 `mpegts_write_packet_internal`(mpegtsenc.c:1914):
- 视频/字幕:一个 AVPacket 直接打成一个 PES(2261-2268);
- 音频:先攒进 `ts_st->payload` 缓冲(2271-2279),触发 flush 的条件(2250-2253):攒够 `pes_payload_size`(默认 `(16-1)*184+170 = 2930`,142-143)/ dts 间隔超过 `max_delay/2` / Opus 累计 120ms;
- 打包前先过码流整形:H.264/HEVC/VVC 补 AUD、关键帧前插 SPS/PPS(1952-2016);AAC 非 ADTS 且无 extradata 直接报错(2026-2028);H.264 裸流没有 start code 会提示挂 `h264_mp4toannexb`(1822-1836),`mpegts_check_bitstream`(2355-2379)则按 extradata 首字节自动挂上该 bsf。

`mpegts_write_pes`(mpegtsenc.c:1513)是 188 字节循环:

```c
// libavformat/mpegtsenc.c:1621-1632 (节选)
q    = buf;
*q++ = SYNC_BYTE;                 // 0x47
val  = ts_st->pid >> 8;
if (is_start) val |= 0x40;        // PUSI: PES 包起始
*q++ = val; *q++ = ts_st->pid;
ts_st->cc = (ts_st->cc + 1) & 0xf;      // 连续性计数器, per-PID mod 16
*q++ = 0x10 | ts_st->cc;                // payload-only + CC
```

- 每个 188B 包:先按需在 adaptation field 写 PCR(1647-1655,`write_pcr_bits` 6 字节,movenc 侧对应 1368-1380),再在 PUSI 包写 PES 头(`00 00 01 stream_id` + PTS/DTS,1656-1777,`write_pts` 五字节编码 1431-1443),最后塞满载荷;
- 剩余空隙用 stuffing 填充:优先扩展 AFC 长度、否则插入 0xFF(1785-1806);
- 视频默认 `omit_video_pes_length=1`(2433-2434),PES 长度字段写 0(1722-1724)——直播流长度不可知的标准做法。

### 4.3 PCR:语义与插入周期

PCR 是 **27 MHz** 时基(`PCR_TIME_BASE`,mpegtsenc.c:45),低 9 位以 300 Hz 为除数(`write_pcr_bits`,1368-1380)。取值方式(mpegtsenc.c:1544-1548):
- **CBR(`mux_rate > 1`)**:PCR 完全由**字节位置**决定——`get_pcr = (total_size + 11) * 8 * 27M / mux_rate + first_pcr`(970-973),解码端可据此缓冲;
- **VBR**:PCR = `dts - max_delay`,跟随数据。

选择哪个 PID 载 PCR:`select_pcr_streams`(1076-1109)优先视频流(1087-1091);`-mpegts_pcr_pid` 指定专用 PCR PID(≥0x0020,1092-1101)时用 adaptation-only 包发 PCR,且 CC 不递增(1398-1422,1410 注释引用 ITU H.222.0)。插入周期(`enable_pcr_generation_for_stream`,1049-1074):
- CBR 或显式 `-pcr_period`:默认 `PCR_RETRANS_TIME = 20ms`(249,1050-1053);
- VBR 默认:**取不超过 100ms 的帧周期最大整数倍**(1058-1067),使 PCR 与帧对齐;
- VBR 下只在 PUSI 包(新 PES 起点)插 PCR(1614-1618)。

### 4.4 PAT/PMT/SDT 周期重发与 null 包

`retransmit_si_info`(mpegtsenc.c:1335-1366)在**每个 188B 包写出前**检查:距上次发送是否超过 `pat_period`(默认 100ms,248/2440)、`sdt_period`(500ms,247)、`nit_period`(500ms,250)。除周期外还有两个强制重发:视频关键帧且上一帧非关键(1526,`force_pat`),以及 `-mpegts_flags resend_headers`(1535-1540,管道重连场景)。

CBR 时的带宽守恒:若数据 dts 领先 PCR 超过 `max_delay`,说明"欠字节"了,插 null 包或 PCR-only 包补齐,且 **PCR 插入优先于 null 包**(1590-1607)。null 包 = PID 0x1FFF + 全 0xFF 填充(mpegtsenc.c:1383-1395,`NULL_PID` 定义于 libavformat/mpegts.h:70)。收尾时 m2ts 模式还会把最后凑满 32 包(2304-2308)。

### 4.5 为什么 TS muxer 天然适合直播

三个结构性原因,全部可在行号处验证:
1. **无 trailer、无回填**:trailer 只 flush PES(mpegtsenc.c:2286-2309),任何时刻输出都是合法流,进程被杀也不产生坏文件;
2. **周期广播 = 随时接入**:新观众在 100ms 内等到 PAT/PMT、20ms 内等到 PCR(247-250)——解码器不依赖文件开头,这是把"索引"按时间维广播出去,恰是 10 章读端"NOHEADER 照样读"的供给侧原因;
3. **恒定字节时钟**:CBR 模式 PCR 由字节数唯一决定(970-973),null 包补齐(1590-1607),对发射端/机顶盒是硬实时契约。
代价:零随机访问索引(快进全靠持续解码)、约 4% 的包封开销(188B/184B)加周期性 SI 重复。

---

## 5. 三方对比表

| 维度 | MOV/MP4 (movenc) | MKV (matroskaenc) | TS (mpegtsenc) |
|---|---|---|---|
| 时间戳转换 | 统一到 per-track timescale(video 默认 `video_track_timescale`),cts=pts-dts 增量记(movenc.c:7408-7410) | 直接用流 time_base 写块时间戳,Cluster 只存基准 TimeCode(matroskaenc.c:3162) | 转 90kHz PES 时基 + 27MHz PCR;`dts+=max_delay`(mpegtsenc.c:1922,1939-1944) |
| 索引生成时机 | trailer:build_chunks + 四表合成(movenc.c:5389,201-313) | 写包记账、trailer 组装(matroskaenc.c:3185,3335) | **无索引**;SI 周期广播替代(1335-1366) |
| 文件头/尾回填 | mdat 大小回填(9074-9094);faststart 整体两遍(9019-9072) | Segment 长度、Duration、SeekHead、Tracks/Tags 五处回填(3397-3416,3403,3445,3483) | 无任何回填 |
| 可流式性 | 需 faststart/moov_size 预留或 fragment 模式才真正可流 | 顺序写即流式(unknown-length Segment);Cues 尾置不阻塞播放 | 天生流式 |
| seek 支持的写出端代价 | 全量内存采样表 O(总样本)(movenc.c:7312);fragment 模式降为 O(片段) | 每关键帧一条 cue 内存记录(977-981);可预留空间免搬移(2735) | 无代价,也无 seek 元数据 |
| 播放器接入成本 | moov 在尾部则需全文件下载(faststart 解决) | 头部 Info/Tracks 即刻可播,Cues 可后置 | 周期 SI 内接入(≤100ms) |
| extradata 就绪策略 | header 拷贝,缺则首包补建 stsd(7089-7119) | 预留空间 + NEW_EXTRADATA 原地更新(3052-3119) | 不需要(AnnexB/ADTS in-band;靠自动 bsf,2355-2379) |

---

## 6. 设计动机

**为什么 MOV 索引必须增量、MKV 可以回填?** MP4 的 stco 存的是**文件绝对偏移**,而 moov 在头部方案(faststart)出现前写不出"最终偏移"——每个后续字节的写入都可能改变答案。两条出路:把采样偏移全部记在内存里最后合成(FFmpeg 的选择,内存换一次 O(N) 收尾),或 fragment 化把索引切碎进 moof(流式,代价是索引冗余)。MKV 的 CuePoint 只依赖 **Cluster 相对位置**,Cluster 落盘即定,所以"记账-结账"即可,还衍生出 reserve_cues_space 这种零搬移优化(matroskaenc.c:2735,3387-3389)。MOV 里对应物是 `reserved_moov_size`(8892-8896),但 MP4 的 free 原子没有 EBML Void 那种"任意长度、语义为空"的优雅性,超了只能报错(9191-9193)。

**TS 的"广播周期"是消费端契约**:10 章讲读端可以假设"随时从任意字节开始扫,第一个 0x47 之后等 PAT/PMT 就能重建节目"。这个假设由写端 `retransmit_si_info` 的 100ms/500ms 硬周期直接供给(mpegtsenc.c:247-250,1335-1366)。它不是优化而是**协议义务**——DVB 规范要求 SI 重复率,FFmpeg 把它实现成写包路径上的定时器。同理 PCR 20ms 周期是解码器 STC 逐出漂移的锚。

**流式 vs 随机访问的取舍谱系**:TS(零索引,无限流式)→ MKV(索引后置,一次遍历流式,收尾一次 seek 窗口)→ fragmented MP4(索引按片段前置,流式且支持 trun 增量)→ 传统 MP4(索引后置 + 整文件两遍搬移)。FFmpeg 在同一 mux 框架(05 章)上让三种哲学共存,说明框架层只承诺"包交织后的顺序回调",索引生产完全是各 muxer 的内政。

---

## 7. FAQ 素材

1. **Q: stco 和 co64 谁说了算?** A: 最后一个采样的 `pos + data_offset` 是否超过 UINT32_MAX(movenc.c:177-182);faststart 时因偏移整体平移,compute_moov_size 要空跑两遍确认尺寸(movenc.c:9031-9039)。
2. **Q: 为什么写包时不直接生成 stbl 四表?** A: chunk 的定义依赖"物理连续 + <1MB"(movenc.c:5255-5257),而交织后的相邻样本物理连续性直到收尾才稳定;且 stsz 等长压缩(242-246)需要全量样本比较。
3. **Q: faststart 慢在哪?** A: `ff_format_shift_data` 把 mdat 从后向前整体搬移 O(文件大小),与是否 SSD 无关,是 CPU+IO 双密集(movenc.c:9071)。
4. **Q: -movflags +faststart 和 -moov_size 同时用会怎样?** A: faststart 自动把 reserved_moov_size 置 -1(自动两遍估算,movenc.c:8277-8278);手动 moov_size 则走"预留 free + 尾部补写"路径,预留不足直接 EINVAL(9191-9193)。
5. **Q: fMP4 的 tfdt 为什么是 version 1(64 位)?** A: 写死 version=1,movenc.c:5894,media time 直接 64 位,避免片段累积后 32 位回绕。
6. **Q: MKV 的 Cues 会写不下吗?** A: `-reserve_cues_space` 不足时先 shift_data 平移,再不足就**不写 Cues**(文件仍合法可播,只是没 seek 表),matroskaenc.c:3352-3357。
7. **Q: MKV 一个 Cluster 的 16 位限制是什么?** A: SimpleBlock 相对 ClusterTimeCode 的时间差用 int16 编码,溢出即强制开新簇(matroskaenc.c:3146-3154)。
8. **Q: TS 的 PCR 插在音频包上会怎样?** A: select_pcr_streams 优先视频(1087-1091);纯音频流才选音频,周期按音频帧时长取 <100ms 的整数倍(1058-1066)。
9. **Q: 为什么 TS 视频包 PES 长度写 0?** A: `omit_video_pes_length` 默认开(mpegtsenc.c:1722-1724,2433-2434),直播场景帧大小不可预知,0 表示"由下一 PUSI 界定"。
10. **Q: 三个 muxer 谁在 write_header 阶段写的东西最多?** A: MKV(Info/Tracks 全在 header,只是暂存 dyn buffer);MOV 只写 ftyp+mdat 占位;TS 什么都不写(mpegtsenc.c:2455-2471)。

## 深挖题

1. **`build_chunks` 的 1MB 上限与播放器兼容性**:chunkSize < 1<<20(movenc.c:5257)是兼容性防线(部分播放器对超大 chunk 的 stsz/stco 内存假设),试着构造一个 2MB 连续音频帧流,观察 stsc 条目数变化。
2. **`mov_flush_fragment_interleaving` 的 pos 平移**:fragment+frag_interleave 时样本 pos 在汇入全局 mdat_buf 后统一加 offset(movenc.c:6606-6607),思考为什么 trun 的 data_offset 公式(`moof_size + 8 + data_offset + cluster[first].pos`,5747-5748)在这两种模式下都能成立。
3. **`move_cues_to_front` 的 redo 循环**:Cues 前置会改变 Cluster 的 CueClusterPosition,FFmpeg 用 offset 重试(matroskaenc.c:3347-3350)而非重算 cue 点,评估该方案与"两遍组装"的复杂度权衡。
4. **CBR TS 的 PCR-vs-null 优先级**:1590-1607 处"PCR 插入优先于 null 包",推导若顺序反了对解码器缓冲模型的影响(PCR 抖动放大)。
5. **hybrid_fragmented 模式**:trailer 时把所有 fragment 的 cluster 拼回全量索引并重写 moov(movenc.c:9153-9168),对比 faststart 与它的 IO 模式差异(搬移 vs 原地)。

---

## 写作要点速查表

| 主题 | 函数/位置 | 行号 |
|---|---|---|
| 采样记录结构 MOVIentry | movenc.h:49-64;cluster 数组 movenc.h:130 | movenc.h:49 |
| 采样表增量扩容(1024/批) | ff_mov_write_packet | movenc.c:7312-7321 |
| 采样 pos/cts/duration 记录 | ff_mov_write_packet | movenc.c:7323,7401,7408-7410 |
| chunk 合成(1MB 上限) | build_chunks,调用点 mov_write_moov_tag | movenc.c:5245-5267,5389 |
| stco/co64 / stsc / stsz / stss | mov_write_stco/stsc/stsz/stss_tag | movenc.c:201,261,225,292 |
| faststart 两遍量尺寸 | compute_moov_size / get_moov_size | movenc.c:9019-9042,8988 |
| faststart 数据搬移 | shift_data → ff_format_shift_data | movenc.c:9059-9072 |
| mdat 大小回填(含 4GB) | mov_write_mdat_size / mov_write_mdat_tag | movenc.c:9074-9094,6213 |
| moof 结构(mfhd/tfhd/tfdt/trun) | mov_write_moof_tag_internal 等 | movenc.c:5943,5630,5645,5889,5711 |
| elst 双条目/负 dts 裁剪 | mov_write_edts_tag | movenc.c:4166-4272 |
| 首个 moov 需全轨有数据 | mov_flush_fragment | movenc.c:6776-6786 |
| MKV SeekHead Void 预留(7×21+14) | mkv_start_seekhead / mkv_write_seekhead | matroskaenc.c:901-909,921-960 |
| MKV cues 记账/结账 | mkv_add_cuepoint / mkv_assemble_cues | matroskaenc.c:962-991,994-1041,3335 |
| MKV cluster 分裂(5MB/5s/4KB) | mkv_write_packet | matroskaenc.c:3232-3237,2745-2755 |
| MKV duration/Segment 长度回填 | mkv_write_trailer | matroskaenc.c:3397-3416 |
| MKV 运行时 extradata 更新 | mkv_check_new_extra_data | matroskaenc.c:3052-3122 |
| TS PES/TS 包循环(含 CC 递增) | mpegts_write_pes | mpegtsenc.c:1513,1621-1632,1656-1806 |
| TS PCR 计算(CBR=字节时钟) | get_pcr / write_pcr_bits | mpegtsenc.c:970-973,1368-1380 |
| TS PCR 周期(20ms/帧对齐) | enable_pcr_generation_for_stream | mpegtsenc.c:1049-1074,249 |
| TS SI 周期(100/500ms)+null 包 | retransmit_si_info / mpegts_insert_null_packet | mpegtsenc.c:1335-1366,1383-1395,247-250 |
| TS 音频 PES 攒包条件 | mpegts_write_packet_internal | mpegtsenc.c:2250-2279 |
| TS 无 header/无 trailer | ff_mpegts_muxer 定义 | mpegtsenc.c:2455-2471 |
