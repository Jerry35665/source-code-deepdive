# 第 04 章 · WAL 与压缩:从易失到持久的桥梁

> 基线:commit `b0f312b`。行号以 tsdb/wlog/、tsdb/compact.go、tsdb/head.go、tsdb/db.go 为准。**勘误**:本版本压缩器在 tsdb/compact.go(无 tsdb/compact/ 子目录)。

## 4.0 全景:WAL 格式

```
段 128MB(wlog.go:41) | 页 32KB(:42) | 记录头 7B = 1B 类型+2B 大端长度+4B CRC32-Castagnoli(:751-754)
首字节:低 3 位片段类型(PageTerm0/Full1/First2/Middle3/Last4),bit3=snappy,bit4=zstd(:611-628)
记录永不跨段(:707-714);页尾补零作撕裂哨兵(flushPage :583-609)
业务类型(record/record.go:38-67):Series1/Samples2/Tombstones3/Exemplars4/MmapMarkers5/Metadata6/直方图 7-10
```

**Commit 不 fsync**:fsync 仅在切段/Close(:822-834)——掉电丢页缓存里的最近记录,进程崩溃靠"撕裂末记录丢弃"恢复(reader.go:52-55)。**这是明确的取舍**:Prometheus 的 WAL 不承诺掉电零丢失(丢的由下次抓取补回——pull 模型的自愈)。

## 4.1 Checkpoint 与恢复

truncateWAL 只收缩**前 2/3 段**(head.go:1667-1671,默认保留约 3h WAL);Checkpoint 输出 checkpoint.N 目录(格式与 WAL 相同,checkpoint.go:147,:443-445):series 按 keep(ref) 保留(Head 在用即留 :1630-1641)、样本按 T>=mint、metadata 只留最新;**checkpoint 内损坏=硬错误不可修复**(:394-398)。恢复:head.Init(head.go:738-996)按 snapshot→mmap chunks→checkpoint→逐段 WAL→WBL 顺序重放;loadWAL 单解码+按 ref%N 并行重建(head_wal.go:81-132)。**损坏自动 Repair**:删损坏段之后的段+把损坏段重写到最后完整偏移(wlog.go:400-505;db.go:1210-1225 触发)——checkpoint 与 WAL 的容错等级刻意不同。

## 4.2 compaction:Head 切块与块合并

Head 可切条件:跨度>1.5×2h(head.go:2143-2149);compactHead 三步=Write→reloadBlocks→truncateMemory(db.go:1747-1773)。**Plan 优先级**(compact.go:350-399):重叠块纵合并>selectDirs 横合并(splitByRange 对齐分桶,**最后一个块刻意排除留备份窗口**)>墓碑>5% 块重写。数据流:各块 BlockChunkSeriesSet→NewMergeChunkSeriesSet(**与查询共用 merger**,:980-985)→WriteChunks+AddSeries。原子性:块写 `ULID.tmp-for-creation`→fsync 目录→**fileutil.Replace 发布**(:761-868);删除 rename `.tmp-for-deletion` 再 RemoveAll(db.go:2332-2339);meta Parents 标记 deletable 保证崩溃后可续删(:2083-2096)。

## 4.3 与 LevelDB compaction 对照及设计动机

| | Prometheus compaction | LevelDB | Git repack |
|---|---|---|---|
| 分区维度 | **时间**(2h 块) | key 范围 | 全局对象 |
| 触发 | 时间+重叠+墓碑 | 层大小/seek | 阈值+手动 |
| 原子发布 | Replace | MANIFEST 切换 | 新 pack 文件 |

1. **时序数据按时间分区**:老数据永不修改(只有墓碑/删除)——compaction 是"时间维的归档",比 key 域 compaction 简单一个量级;
2. **最后一个块排除在合并外**(:350-399):保留它作为"崩溃后重建 Head 的原料"——备份窗口是正确性设计;
3. **Merger 复用**:查询合并与 compaction 合并用同一个 NewMergeChunkSeriesSet(:980-985)——**读写共用核心算法**是 TSDB 的一致性保证;
4. **fsync 的克制**:只 fsync 目录与切段——把"掉电丢失窗口"卖出去换吞吐,由 pull 自愈兜底(01 章)。

## 4.4 FAQ

**Q1:WAL 会无限增长吗?**
不会:checkpoint 收缩前 2/3 段(head.go:1667-1671),保留约 3h。

**Q2:掉电会丢多少数据?**
页缓存里未 fsync 的最近记录(reader.go:52-55 撕裂丢弃):秒级,由下次抓取补。

**Q3:compaction 期间能查询吗?**
能:新块 Replace 发布前查询走旧块(:761-868)。

**Q4:为什么最后一个块不参与合并?**
备份窗口(:350-399):崩溃后 Head 可从它重建。

**Q5:WAL 记录为什么不跨段?**
(:707-714):段是恢复单元,跨段让撕裂判定复杂化。

**Q6:checkpoint 为什么比 WAL 严格?**
(:394-398):checkpoint 是恢复起点,坏了无处可退;WAL 段可截断。

**Q7:2 小时块能不能改?**
能(配置):影响内存(Head 更大)/查询块数/保留粒度——三者的联动。

**Q8:重叠块怎么合并?**
纵合并优先(:350-399):时间重叠的块必须合一(否则查询合并成本永久化)。

**Q9:墓碑什么时候真正删除?**
>5% 块重写计划(:350-399)或下一次时间合并。

**Q10:WAL 的 snappy 压缩什么时候启用?**
省字节才写(:693-700):压缩不划算就用原样。

## 4.5 小结与深挖方向

本章结论:**WAL/压缩="段页格式+分级容错(checkpoint 严/WAL 宽)+时间维 compaction+原子发布"**。深挖:

1. 128MB 段(:41)在慢磁盘的切段停顿;
2. 并行 WAL 重放(:81-132)的分片均匀性;
3. Parents deletable 标记(:2083-2096)的崩溃恢复完备性;
4. ChainedSeriesMerge(:980)与堆式 merge 的选择;
5. 1.5×chunkRange 阈值(:2143-2149)与远程写的交互。

> 下一章:PromQL 引擎——查询的表达力与实现。
