# 第 04 章 · SLRU 与检查点:辅助层家族与三步锚定

> 基线:commit `8c7a74c`。行号以 src/backend/access/transam/slru.c、clog.c、subtrans.c、xlog.c、src/backend/postmaster/checkpointer.c 为准。

## 4.0 全景:WAL 旁的小缓冲层家族

| SLRU 实例 | 内容 | 单元 | 注册点 |
|---|---|---|---|
| clog(pg_xact) | 每事务 2bit 提交状态 | 4 事务/字节 | clog.c:811-825 |
| subtrans(pg_subtrans) | 子事务父 XID(4B) | 每 XID 一项 | subtrans.c:246-259 |
| multixact offsets/members | 组事务:偏移+成员(5B) | 双 SLRU | multixact.c:1785/1800 |
| commit_ts | 提交时间戳(12B,可选) | 每 XID | commit_ts.c:551-564 |

**为什么不用主缓冲池**(slru.c:12-31 官方注释):①访问偏斜到最末页(XID 单调);②XID 除法直接寻址,免哈希;③永不逐出最末页;④独立简化锁——**四个特征都指向"比通用缓冲池更简单的东西"**。master 已 bank 化:16 槽/bank(slru.c:145-151),每 bank 一把控制锁+每槽 I/O 锁(slru.h:48-102)——老版本一把全局 ControlLock 已被切分。

## 4.1 clog:2bit 里的提交语义

每事务恰好 2bit(clog.h:27-30):00 IN_PROGRESS/01 COMMITTED/02 ABORTED/03 SUB_COMMITTED;**页=÷32768 个事务,字节内低 2bit 归较小 XID**(clog.c:64-91)。跨页提交树用 SUB_COMMITTED 两阶段保原子(clog.c:191-257);组提交由队长代写(:449-661)——又一处"等待即批处理"。**截断四步防御链**(TruncateCLOG,clog.c:984-1018):确认有段可删→先推 oldestClogXid→写 CLOG_TRUNCATE WAL 并 flush→才真删——**删除的四道闸**(对照 Git prune 的双闸、卷一 09 章)。

## 4.2 subtrans:不跨崩溃的辅助层

子事务父链 4B/项;每 backend 缓存上限 64(proc.h:44),**溢出置 overflowed 强迫读方查 pg_subtrans**(varsup.c:235-271)——慢与错的分界。subtrans **崩溃即弃**(:13-20,301-342):启动清零活跃页,恢复期重放重建——"可重建性"决定持久化投入,与 Git 辅助索引(卷一 08 章)同款哲学:**丢了能算回来的东西不配拥有磁盘真相**。

## 4.3 检查点:三步锚定与崩溃窗口

`CreateCheckPoint`(xlog.c:7457)→`CheckPointGuts`(:8106-8140)的三步:

1. **先立 redo 点**:在线检查点写独立 XLOG_CHECKPOINT_REDO 记录(:7636-7659;关机版直接取插入位 :7586-7618);
2. **刷盘**:等 DELAY_CHKPT_START 事务(:7752-7770)→按 SLRU 各家(clog/commit_ts/subtrans/multixact/predicate)→BufferSync→ProcessSyncRequests 统一 fsync(:8114-8124);
3. **最后更新 pg_control**:写 XLOG_CHECKPOINT_ONLINE/SHUTDOWN 记录并 flush(:7800-7811)→pg_control 的 checkPoint(:7845-7862,fsync 经 controldata_utils.c:261)。

**顺序不变式**:恢复起点=pg_control 指向记录的 redo 点;WAL 段在 pg_control 更新后才回收(:7907-7922)。**崩溃窗口矩阵**:三步任一步断电,恢复都从旧锚重放——孤儿检查点记录在重放中被采信(xlog_redo :8918-9072:SHUTDOWN 精确采信、ONLINE 取最大)。CheckPoint 结构体在 pg_control.h:35-69;恢复起点校验 xlogrecovery.c:729-765。

**spread checkpoint**:CheckpointWriteDelay(checkpointer.c:794-854)按 completion_target=0.9 摊平写压;max_wal_size 折算 CheckPointSegments=max/(1+target)(xlog.c:2243-2247),超限触发 CHECKPOINT_CAUSE_XLOG(:2555-2560)——**检查点节奏是 IO 平滑器,不是紧急刹车**。

## 4.4 与前作对照

| | PG SLRU | Git 辅助索引 | Redis ebuckets |
|---|---|---|---|
| 地位 | 主存储旁的小专用层 | 对象库旁的可丢弃索引 | 内存元数据旁的二级索引 |
| 丢失后果 | clog 不可弃/subtrans 可弃 | 弃了变慢 | 过期变慢 |
| 寻址 | XID 除法直查 | fanout 二分 | 段式桶 |

SLRU 家族内部的**持久化分级**(clog 必须 WAL 保护截断、subtrans 崩溃即弃)是"按重建成本付费"的活样本。

## 4.5 设计动机

1. **为什么 2bit 值得独立子系统**:事务状态查询是 MVCC 每行可见性判断的热路径(卷二),必须 O(1) 且无哈希——2bit×除法寻址是极致;
2. **检查点=三步锚定**:redo 点先立、脏页中刷、pg_control 收尾——每一步的崩溃窗口都有旧锚兜底,正确性不依赖"原子地完成三件事"而依赖"顺序使中间态可恢复";
3. **spread 是 IO 平滑**:检查点的全池刷盘若集中爆发会打垮延迟——0.9 completion_target 把 10 秒的活摊到 11 秒;
4. **pg_control 是最后的真相**:512 字节小文件的 fsync 语义(找到位置更新它)支撑整个恢复起点。

## 4.6 FAQ

**Q1:clog 为什么每事务只 2bit?**
可见性判断只需四态(:27-30):进行中/提交/中止/子提交——状态的完备集合就是 2bit。

**Q2:subtrans 丢了会怎样?**
恢复期重放重建;运行中溢出 64 缓存只变慢不致错(:235-271)——可重建层的设计红利。

**Q3:检查点为什么先立 redo 点再刷盘?**
若先刷盘后立锚,崩溃窗口内"页已新而 redo 点旧"会造成重复重放风险——顺序就是正确性。

**Q4:孤儿检查点记录有害吗?**
无害:重放中被采信(SHUTDOWN 精确/ONLINE 取最大,:8918-9072)——"多写不害"靠记录间比较。

**Q5:WAL 段什么时候能回收?**
pg_control 更新后(:7907-7922):锚点已移过段尾。

**Q6:clog 截断为什么四步?**
任一步断电都不破坏:段还在→可重删;XID 推进先行→不会误删在用段(:984-1018)。

**Q7:multixact 为什么是两个 SLRU?**
偏移(定长 4B)与成员(变长)访问模式不同(:1785/1800)——一个 XID 对应不定长成员列表。

**Q8:spread checkpoint 0.9 是什么?**
completion_target:目标在 0.9×间隔内完成刷盘,留 10% 余量(:794-854)。

**Q9:SLRU 的 bank 化为什么?**
老版全局 ControlLock 是竞争热点:16 槽/bank 把锁竞争切到 1/bank 数(:145-151)。

**Q10:检查点频率谁定?**
max_wal_size 折算段数(:2243-2247)+超限强制(CHECKPOINT_CAUSE_XLOG :2555-2560)——IO 预算驱动,非定时器。

## 4.7 小结与深挖方向

本章结论:**SLRU="按重建成本分级的专用层";检查点="三步锚定使崩溃窗口全部可恢复"**。深挖:

1. clog 组提交队长代写(:449-661)在热点行提交的收益;
2. bank 数(:145-151)与 NUM_BUFFER_PARTITIONS(02 章)的锁切分哲学一致性的量化;
3. pg_control 512B 的 fsync 语义与磁盘 torn 写;
4. multixact members 的膨胀治理(SLRU 之外的真实磁盘);
5. spread checkpoint(:794-854)与 bgwriter(02 章)的写压协作。

> 下一章(卷末):锁体系——三层金字塔。
