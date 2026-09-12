# 第 22 章 · AVCodecParser:demux 与 decode 之间的隐形层

> 基线:commit `9f63b36a`。行号以 libavcodec/parser.c、h264_parser.c 与 libavformat/demux.c 为准。17 章说过 RTP 的 H264 重组"靠 need_parsing=AVSTREAM_PARSE_FULL 交给上层 parser"——本章兑现这个坑位。纠偏:AAC ADTS 解析在 libavcodec/adts_header.c,HEVC parser 在 libavcodec/hevc/parser.c(子目录化改造后旧路径已失效)。

## 22.0 全景:parser 解决的四个问题

```
demuxer ──AVPacket(边界/时间戳可能不可信)──→ parser ──AVPacket(定界+时间戳恢复)──→ decoder
                     │                                │
              streamcopy 也走这里                  四个职责:
              (不解码仍需帧边界)                ① 帧边界判定(裸流无容器索引)
                                               ② 时间戳旁路恢复(TS 33bit/裸流无 TS)
                                               ③ 关键帧标记(seek 的物理基础)
                                               ④ 参数集抽取(SPS/PPS→extradata)
```

.parser 独立于 decoder 的原因:**streamcopy(不解码)同样需要帧边界与关键帧标记**;decoder 关心"怎么解这一帧",parser 关心"哪里是一帧"——两个正交问题。

## 22.1 框架:字节消费机与 END_NOT_FOUND

`av_parser_parse2`(parser.c:120)的契约:**每次喂任意长度字节,返回消费掉的字节数**。边界由具体 parser 的回调判定,没找到边界时返回 `END_NOT_FOUND`(=−100,parser.h:40),框架用 `ff_combine_frame`(parser.c:213)把字节累积进 ParseContext 直到边界出现:

```
输入包 ──喂──→ av_parser_parse2 ──→ parse 回调找边界
                 │ 返回消费数
        找到边界:ff_combine_frame 切出完整帧 → 输出 AVPacket
        没找到:END_NOT_FOUND → 字节留在 ParseContext,等下一包
```

**时间戳是旁路恢复而非透传**:输入包的 pts/dts 压入 4 槽环形表(parser.c:152-161),帧输出后按"帧的起始字节偏移"反查对应时间戳(`ff_fetch_timestamp`,parser.c:89)。demux 侧喂完立即把包的 pts/dts 清为 NOPTS(demux.c:1224)——**一次消费,杜绝复用**;输出包时间戳直接抄 `parser->pts`(demux.c:1288)。这是 TS 33bit 乱序、裸流无时间戳两类问题的统一解法。

## 22.2 demux 集成:need_parsing 四档

parser 惰性初始化在 demux.c:1482-1495;`AVSTREAM_PARSE_*` 四档语义:

| 档位 | 行号 | 行为 |
|---|---|---|
| NONE | 默认 | 不解析(demuxer 已可信,如 MOV) |
| HEADERS | :1491 | 翻译为 COMPLETE_FRAMES:信任边界,只抽参数集 |
| FULL_ONCE | :1493 | ONCE:解析到第一个完整帧(抽 SPS/PPS)后停 |
| FULL_RAW | :1495 | USE_CODEC_TS:完全解析,时间戳按 codec 时基 |

`parse_packet` 循环(demux.c:1220-1229)驱动 av_parser_parse2;FULL_RAW 时用 `parser->frame_offset` 当输出包 pos(:1293-1302),`key_frame==1` 或 pict_type==I 打 AV_PKT_FLAG_KEY——**seek 的关键帧标记很多格式来自这里**(13 章 TS 的索引建立正是消费这些标记)。

## 22.3 h264_parser:多信号融合的帧边界

H.264 裸流没有"帧结束"标志,parser 用三路信号投票(h264_parser.c):

- **信号 A:切片头解析**——`parse_nal_units` 读 slice header,first_mb_in_slice 与帧号比对;
- **信号 B:边界 NAL 出现**——SEI/SPS/PPS/AUD(类型 9)出现即判定上一帧结束(:124-131,AUD 定义 h264.h:43);
- **信号 C:first_mb_in_slice 单调性**——`mb <= last_mb` 即新帧(:147-152)——**无 AUD 裸流的主力信号**:新图片的切片总是从 0 开始,上帧的后续切片单调递增。

关键帧三重判定(:356,368,389):IDR NAL / SEI recovery_point / 低参考帧数启发式。裸流连 DTS 都能重建:用 `cpb_removal_delay`(:637)从参考锚点外推(:649-671)——**这是"裸 H264 文件也能 seek"的全部基础**。

## 22.4 多格式对比:帧长从哪来

| 编码 | 帧边界来源 | 行号 |
|---|---|---|
| H.264 | 多信号融合(上节) | h264_parser.c:124-152 |
| HEVC | first_slice_segment_in_pic_flag 单比特判定,比 H264 便宜 | hevc/parser.c:291-301 |
| AAC | ADTS:12bit 同步字+13bit 帧长,定长直切 | adts_header.c:37,56 |
| AC3 | 帧长查表 | ac3_parser.c:345 |
| E-AC3 | 等式 `(11bits+1)<<1` + 整帧 CRC 防误同步 | ac3_parser.c:361;aac_ac3_parser.c:122 |

规律:**容器给得起的(parser 就省)**——MOV/MKV 有明确边界→HEADERS 或 NONE;TS/裸流→FULL 全解析。

## 22.5 设计动机

1. **正交分离**:帧边界/时间戳/关键帧是容器残缺的补偿层,与"如何解码"无关——所以 TS 的 33bit 回绕(10 章)、RTP 的乱序重组(17 章)最终都汇到这层统一解决;
2. **时间戳旁路模型**:parser 不信任输入时间戳的逐帧对应,而是建立"字节偏移→时间戳"的映射——一包多帧、一帧多包都被同一个模型覆盖;
3. **惰性与档位**:FULL 解析有真实成本(逐 NAL 状态机),四档 need_parsing 让 demuxer 按容器可信度付费;
4. **AUD 与 first_mb 的冗余**:两路信号互为校验——容错场景(AUD 丢失)靠单调性兜底。

## 22.6 FAQ

**Q1:为什么 streamcopy 也会触发 parser?**
复制流仍需帧边界与关键帧标记(切割/对齐/seek),而 TS/裸流不给——need_parsing 与是否解码无关(demux.c:1482-1495)。

**Q2:MOV 为什么不需要 FULL 解析?**
stbl 索引已给出精确边界与时间戳(10 章),parser 降为 HEADERS 只抽参数集——按容器可信度付费。

**Q3:一包多帧的时间戳哪来的?**
旁路环形表:输入包 pts 按 4 槽压入(parser.c:152-161),每帧按字节偏移反查(ff_fetch_timestamp,parser.c:89)。

**Q4:H264 裸流没有 AUD 能切帧吗?**
能,信号 C:first_mb_in_slice 单调性(:147-152)——新帧切片从 0 开始是编码器契约。

**Q5:裸流的关键帧标记可信吗?**
三重判定(IDR/recovery_point/参考帧数启发式,:356-389)交叉验证,取最先命中者。

**Q6:TS 的 33bit 回绕为什么最终在这里解决?**
TS demuxer 解出 33bit 环形值,parser 的时间戳旁路表按消费序重排——回绕补偿发生在映射表这一层。

**Q7:av_parser_parse2 返回负数是什么?**
END_NOT_FOUND(−100)=本包字节全部累积,尚未出帧(parser.h:40);其他负值=错误。

**Q8:parser 与 decoder 会重复解析 slice header 吗?**
会,这是刻意的:parser 只读边界所需字段,decoder 重建完整上下文——共享解析意味着状态耦合,CBS(23 章)是另一条路。

**Q9:FULL_ONCE 用在哪?**
抽一次 SPS/PPS 写 extradata 后即停(demux.c:1493)——"只需要参数集"的格式(fMP4 over RTP)用它省成本。

**Q10:HEVC 判帧为什么比 H264 便宜?**
first_slice_segment_in_pic_flag 单比特即判新帧(hevc/parser.c:291-301),无需 first_mb 单调性推演。

## 22.7 小结与深挖方向

本章结论:**parser = "字节消费机 + 时间戳旁路表 + 多信号边界投票"**,它是容器残缺度的补偿层。深挖:

1. 4 槽环形表(parser.c:152-161)在超长 GOP 下的覆盖极限;
2. cpb_removal_delay 外推 DTS(:649-671)与 HRD 模型的一致性;
3. cbs(23 章 AV1)与 per-format parser 的统一可能;
4. E-AC3 整帧 CRC(ac3_parser.c:361)的误同步防护 vs H264 无校验的风险;
5. parse_packet(demux.c:1220)与滤镜图/BSF 的执行顺序对时间戳的影响。

> 下一章:AV1 生态——三种解码路径与三种编码 wrapper 的全景对比。
