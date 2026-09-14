# 第 02 章 · Head 内存块:Append 热路径与 XOR 编码

> 基线:commit `b0f312b`。行号以 tsdb/head.go、head_append.go、chunkenc/xor.go 为准。

## 2.0 全景:一次 Append 的旅程

```
Append()(head_append.go:444):快速越界拒绝(t<minValidTime)
  → getByID 查 series / miss 则 getOrCreate(:455,乐观创建+postings.Add)
  → appendable() 判序(:694:in-order/重复/OOO/拒绝;OOO 窗口判定 :722)
  → appendBatch 暂存(:517)
Commit()(:1769):先 log() 写 WAL(:1783,顺序 series→samples→histograms)
  → 逐 series 加锁 commitFloats(:1373):in-order 走 memSeries.append(:1904)
     [appendPreprocessor :2038 决定是否 cutNewHeadChunk :2191]
     OOO 走 memSeries.insert(:1867),最后写 WBL(:1863)
```

**Append 只做校验与暂存,真正的写入全在 Commit**——WAL 先于内存(:1783 先于 :1837),崩溃一致性由此保证。

## 2.1 stripe 分片锁:取模分片的并发设计

`stripeSeries`(head.go:2403)按 ref 和 label hash 双索引,同一套锁数组**取模分片**:`ref & (size-1)`(:2779),默认 16384 分片(:2394),**40 字节填充防伪共享**(:2415)。hash 表用 unique+conflicts 两级结构(:2327),hash 只做索引、labels.Equal 做裁决;插入先后拿 hash 锁与 ref 锁两把(:2822)。对照 PG 缓冲的 128 分区锁(卷一 02 章):同一问题("大哈希表的并发")的 Go 与 C 答案。

## 2.2 XOR chunk:Gorilla 论文的落地

chunkenc/xor.go 的 `xorAppender.Append`(:161)三段式:首样本 varint t+64bit v;第二样本 uvarint tDelta;后续 **delta-of-delta 前缀码**(dod=0 一个 bit;14/17/20/64bit 四档,:186-207——毫秒精度比 Gorilla 论文的秒级分桶更宽)。value 在 xorWrite(:466):值不变 1 bit;有效位落在上次前导零窗口内 1bit+载荷;否则 1+5bit 前导零+6bit 有效位长+载荷。迭代器对"dod=0 且值不变"做**双 bit 快速路径**(:330-341)。切 chunk:目标 120 样本(head.go:245),1/4 处按速率预测切割点(:2183),超 1005 字节硬切。

## 2.3 OOO 乱序窗口与 truncate

**乱序(OOO)**:appendable 的窗口判定 `t >= headMaxt-oooTimeWindow`(:722);OOOChunk 未压缩切片+二分插入(ooo_head.go:27/:37),攒满 32 个编码 mmap 落盘并写 WBL(head.go:243)。truncateMemory 把 minValidTime 原子前移(head.go:1250/:1299)——写入下界,配合 GC(:1988/:2010:postings.Delete+walExpiries)。

## 2.4 设计动机

1. **为什么自研 TSDB**:标签模型的基数爆炸需要"倒排索引+列式 chunk"的原生设计,通用数据库 Either 不匹配或成本失控;
2. **stripe 取模分片**:16384 片把 16 核的锁竞争切到 1/16384——40 字节填充是防伪共享的物理意识;
3. **Append/Commit 两阶段**:WAL 顺序化+内存并发化的解耦点;
4. **XOR 的毫秒分桶**:论文算法在工程里放宽一档(14-20bit)换实现简单——学术到工程的保真损耗是自觉的。

## 2.5 FAQ

**Q1:Append 和 Commit 为什么分开?**
一批样本要原子可见:校验/暂存后统一 WAL+落内存(:1769 起)。

**Q2:乱序样本默认接受多久的?**
oooTimeWindow 窗口内(:722);默认关闭,开 OOO 特性后生效。

**Q3:一个 chunk 多少样本?**
目标 120(:245);按速率预测切割点在 1/4 处(:2183)。

**Q4:XOR 编码平均多少 bit/样本?**
Gorilla 论文 ~1.37 bytes/样本;温度类平稳信号更低。

**Q5:16384 个 stripe 锁会不会太多?**
每把 40B+填充(:2415):总共 ~640KB,换几乎零竞争。

**Q6:series 创建的竞态?**
乐观创建+postings.Add 是完成标志(:2201/:2223):并发创建同一 series 只有一个成功入索引。

**Q7:WAL 为什么先写?**
(:1783 先于 :1837):崩溃后重放必须覆盖内存态——04 章铁律。

**Q8:head chunk 什么时候落盘?**
2 小时切块后 compactHead 写盘(04 章);内存只保最近。

**Q9:histogram 样本走哪条路?**
独立 NHCB/histogram chunk(:1783 的 WAL 顺序里单列)。

**Q10:minValidTime 是什么?**
写入下界(:1250):truncate 前移,早于它的样本拒绝。

## 2.6 小结与深挖方向

本章结论:**Head="校验暂存+Commit 两阶段+stripe 分片+XOR 编码+OOO 窗口"**。深挖:

1. 16384 分片在高核(128C)机器的争用残余;
2. XOR 双 bit 快速路径(:330-341)的真实占比;
3. OOO 32 片聚合(:243)对高频乱序的退化;
4. 1005 字节硬切(:2183 区段)与压缩率的权衡;
5. markPendingCommit(:2966)的两阶段提交语义。

> 下一章:磁盘块——不可变的时序档案。
