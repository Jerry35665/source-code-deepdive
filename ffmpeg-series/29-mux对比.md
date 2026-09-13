# 第 29 章 · mux 侧对比:增量索引、尾部回填与周期广播

> 基线:commit `9f63b36a`。行号以 libavformat/movenc.c、matroskaenc.c、mpegtsenc.c 为准。10 章对比过 demux 三方,05 章讲过 mux 框架(交织/faststart)——本章讲**具体 muxer 如何生成各自的容器结构**,与 10 章 demux 侧严格镜像。

## 29.0 全景:三种写出策略

```
MOV = 增量索引 + 最后总装    每包记元数据→收尾合成 stbl 四表→moov 总装
MKV = 顺序流 + 尾部回填      顺序写 cluster→Cues/Duration 记账→trailer 回填
TS  = 纯流式 + 周期广播      无头无尾无回填;PAT/PMT/PCR 按周期广播
```

**写出策略是 demux 哲学(10 章)的镜像**:MOV 的坐标系需要全量索引所以写出端增量记账;TS 的"随时接入"契约要求元数据周期广播;MKV 的自描述允许"先写数据后补目录"。

## 29.1 movenc:增量索引与 moov 总装

每包在 per-track 的 cluster 数组记一条 `MOVIentry{pos,dts,cts,chunkNum}`(movenc.c:7312-7330),容量按 `MOV_INDEX_CLUSTER_SIZE=1024` 扩容(movenc.h:32)。**stbl 四表在写 moov 时才由 `build_chunks` 一次性合成**(:5245-5267,调用点 :5389)——chunk 合并条件:物理连续+同 stsd_index+**单 chunk<1MB**。这就是 05 章"交织算法"下游的数据落点:交织决定包的物理顺序,movenc 的记账决定索引怎么描述这个顺序。

**faststart 的两遍在 movenc 侧的形态**(:9019-9042):用 null buffer 空跑一遍量出 moov 尺寸——**必须空跑,因为偏移平移可能触发 stco→co64 翻转**(超 4GB);搬移用 `shift_data`(:9059-9072);mdat 大小 trailer 回填,超 4GB 时覆写 `wide` 占位转 64 位扩展 size(:9074-9094)。

**fragmented MP4**(fMP4):stbl 被 moof/tfhd/tfdt/trun 取代,内存从 O(总样本) 降为 O(单片段)——直播场景的必然选择。细节:首个 moov 要求**所有 track 都有数据**才写(:6776-6786);empty_moov 会**关闭框架 auto-BSF**(:8267-8270,init segment 已定型);tfdt 写死 version=1,`baseMediaDecodeTime = cluster[0].dts - start_dts`(:5889-5897);trun 按物理连续性拆段(:5913-5919)。

## 29.2 matroskaenc:Void 预留与延迟组装

MKV 的两个回填技巧:

- **SeekHead 预留**:写头时预留 `7 项×21 字节+14` 的 Void 元素(:901-909),trailer 回填后余隙再补 Void(:953-954)——预留不足时先 `shift_data` 再放弃 Cues(:3346-3357)。对照 MOV 的 free 预留:超限只能报错(movenc.c:9191-9193)——**MKV 的 Void 可伸缩,MOV 的 free 是死预留**;
- **Cues 延迟组装**:写包时只记账(按 pts 排序插入内存数组,:3181-3191,:3335;仅 video/字幕/无视频轨的首音频,同 pts 合并进同一 CuePoint,:994-1041),trailer 阶段才组装落盘。

Cluster 分裂三条件(:3232-3237):5MB/5s/视频关键帧 4KB;外加**int16 相对时间戳溢出强制分簇**(:3146-3154)——SimpleBlock 的 relative timestamp 只有 16bit,这是格式约束直接变成分簇策略的样本。

## 29.3 mpegtsenc:周期广播的供给侧

TS muxer **无 write_header、无 trailer、零回填**——纯流式。它的"索引"是按时间广播的:PAT 100ms/SDT 500ms/PCR 20ms(CBR)周期重发(:1335-1366,:247-250),视频关键帧强制提前发 PAT(:1526)。PCR 的生成有两种:CBR 下 **PCR 由字节位置唯一决定**——`(total_size+11)×8×27MHz/mux_rate`(:970-973),VBR 则 `pcr = dts - max_delay`(:1547-1548),周期取"<100ms 的帧周期整数倍"(:1058-1067)。

两个协议细节:null 包(PID 0x1FFF)补码率且**PCR 插入优先于 null 包**(:1590-1607);连续性计数器每 payload 包 +1 mod 16,AF-only 的 PCR 包不递增(:1631,:1410)。**TS muxer 天然适合直播**的代码依据:无回填=无延迟堆积,广播=消费者随时接入(10 章契约的供给侧兑现)。

## 29.4 共同点:extradata 状态机三分

三 muxer 处理"写头时 extradata 还没就绪"各有一套:movenc 首包补建 stsd(:7089-7119);MKV 预留+NEW_EXTRADATA 原地更新(:3052-3119);TS 靠 muxer 自动挂 BSF 转 AnnexB(:2355-2379,呼应 24 章 check_bitstream)。时长则都增量维护(movenc.c:7401 / matroskaenc.c:3194 / TS 无)。

## 29.5 对比表与设计动机

| | MOV | MKV | TS |
|---|---|---|---|
| 索引生成 | 增量记账+总装 | 记账+trailer 组装 | 无(周期广播) |
| 回填 | mdat 大小/wide | SeekHead/Duration/Cues | 零 |
| 可流式写 | 需 fMP4 | 需 live 标志 | 天生 |
| seek 支持 | 全量索引 | Cues | 边播边建(13 章) |

1. **MOV 索引必须增量而 MKV 可以回填**:MP4 的 stbl 需要精确 offset(MOV 是"坐标系"格式,10 章),MKV 的 Cues 只到 cluster 级——**索引精度要求决定回填余度**;
2. **TS 的广播是消费端契约**:decoder 随时接入、随时丢失——写端每 100ms 发 PAT 不是优化而是协议义务;
3. **格式约束直通实现**:SimpleBlock 的 int16 时间戳溢出强制分簇(:3146-3154)、stco→co64 翻转(:9019-9042)——**容器字段宽度是上游的物理常数**,muxer 的策略围绕它们设计;
4. **fMP4 是 MOV 的流式救赎**:把"全量索引"拆成 per-fragment 小索引,牺牲文件级 seek 换直播能力——同一格式内部的哲学切换。

## 29.6 FAQ

**Q1:为什么 MP4 转 TS 不用改码流,MP4→MKV 却可能要 BSF?**
TS 要求 AnnexB(mpegtsenc.c:2355-2379 自动挂转换);MKV 与 MP4 同用 length-prefixed——容器对码流形态的要求不同。

**Q2:faststart 为什么必须空跑一遍?**
偏移平移会改变所有 stco 条目,且可能触发 32→64 位翻转(:9019-9042)——不先量尺寸无法决定写哪种。

**Q3:MKV 的 Cues 为什么可能丢失?**
预留空间不足时先 shift_data 再放弃(:3346-3357)——网络写入场景 shift 代价过高,Cues 可牺牲。

**Q4:TS 的 PCR 每 20ms 一次是不是太频?**
CBR 下 PCR 由字节位置唯一决定(:970-973):不只是时钟,还是"字节↔时间"标尺——频率即精度。

**Q5:fMP4 的 tfdt 为什么写死 version=1?**
32bit 的 baseMediaDecodeTime 在长直播会回绕(:5889-5897),version=1 用 64bit。

**Q6:为什么 empty_moov 会关闭 auto-BSF?**
init segment 已定型(:8267-8270):参数集必须在 moov 前就绪,BSF 转换无意义。

**Q7:MKV cluster 为什么有 4KB 关键帧条件?**
按 seek 粒度设计(:3232-3237):Cues 指向 cluster,关键帧边界=cluster 边界使 seek 落点即解码起点。

**Q8:stsz 表为什么不能省?**
MOV 的"读包即寻址"(10 章)依赖逐样本大小;CBR 变体(constantsize)可省但 FFmpeg 写通用路径。

**Q9:三 muxer 的时长哪来的?**
都增量维护(movenc.c:7401/matroskaenc.c:3194):最后一个包的 dts+duration——TS 干脆没有 duration 字段。

**Q10:录像文件为什么推荐 MKV?**
顺序流+可回填+Void 伸缩(:901-909):崩溃时最多丢尾部,MOV 的 mdat/size 不回填则整文件不可读。

## 29.7 小结与深挖方向

本章结论:**mux 写出策略 = demux 哲学的镜像(MOV 增量/MKV 回填/TS 广播)+ 容器字段宽度决定的硬约束**。深挖:

1. build_chunks 的 1MB chunk 上限(:5245-5267)在 4K 高码率的适用性;
2. mpegtsenc CBR 的 PCR 公式(:970-973)与真实广播编码器的 PCR jitter 容差;
3. fMP4 tfdt 64bit(:5889-5897)与 HLS 插播(SCTE-35)的时间轴对齐;
4. matroskaenc SeekHead 7 项预留(:901-909)在附件/字幕多轨下的不足;
5. 三 muxer 的 extradata 状态机(29.4)与 24 章 BSF 的时序耦合。

> 下一章(卷末):Vulkan 计算——GPU 平行管线与 avfilter 框架的兼容。
