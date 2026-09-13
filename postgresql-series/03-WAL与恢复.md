# 第 03 章 · WAL 与恢复:一条 UPDATE 的保命旅程

> 基线:commit `8c7a74c`。行号以 src/backend/access/transam/xlog*.c、xloginsert.c、xact.c 为准。WAL 是 PG 最大的子系统(曾上万行的 xlog.c 已拆分)。对照:SQLite WAL(单写者+checkpoint 回填)、etcd raft(日志即状态机输入)、Kafka(日志是产品)——**PG WAL 是"缓冲池的补救"**:页可半写,日志不可。

## 3.0 全景:一条 UPDATE 的 WAL 旅程

```
heap_update 改缓冲页 ──XLogInsert(RM_HEAP_ID)(heapam.c:2178)
   ↓ xloginsert 组装:BeginInsert(:153)→Register(:245,371)→Assemble(:620)→Insert(:481)
xlog.c:预留位点(ReserveXLogInsertLocation :1182,自旋锁下 CurrBytePos+=size)
   → 锁外并发拷贝进 wal_buffers(CopyXLogRecordToWAL :1299)
事务提交:插 COMMIT 记录(xact.c:1484)
   → XLogFlush(XactLastRecEnd)(:1544)或异步(:1565,synchronous_commit=off)
XLogFlush(xlog.c:2837):等在途插入(WaitXLogInsertionsToFinish :1578)
   → LWLockAcquireOrWait(WALWriteLock) 失败即回环"拼车"(:2911,组提交)
   → XLogWrite(:2358)落盘
铁律:数据页写盘前必先 XLogFlush 页 LSN(bufmgr.c:4584-4585)
```

**预留-拷贝两阶段**是并发设计的支点:自旋锁内只做"指针推进",锁外拷贝——临界区最小化(02 章 Pin 哲学的 WAL 版)。

## 3.1 记录格式:24 字节头与跨页续接

XLogRecord 头 24 字节(xlogrecord.h:41-55):xl_tot_len/xl_xid/xl_prev(前一条记录位置,组成链)/xl_info/xl_rmid(资源管理器)/xl_crc。**xl_prev 是单链**——恢复时可从后向前校验连续性。长记录跨页:xlog.c 写侧置 CONTRECORD(:1350-1353),读侧 xlogreader.c 重组并逐页校验(:719-780);**CRC 先体后头**(:1240-1245,与写侧 xlog.c:980-983 对称)——先验内容再验头,半写的头才不会误通过。

## 3.2 FPW:full_page_writes 为什么必须

问题:磁盘上可能存在**半新半旧的页**(torn page)。解法:checkpoint 之后**每页首次修改时把整页快照写进 WAL**——恢复时先还原整页再重放增量。判据一行(xloginsert.c:693):

```c
needs_backup = (page_lsn <= RedoRecPtr);  /* :677-699 */
```

页 LSN 不晚于恢复起点 RedoRecPtr,说明"这页的旧版本可能不在 WAL 覆盖内"——必须拍快照。REGBUF_FORCE_IMAGE/NO_IMAGE 可覆盖;doPageWrites 持锁后复查(xlog.c:913);竞态时返回 Invalid 让 XLogInsert 重试(:915-926);镜像**挖洞**省略 pd_lower..pd_upper 空闲区(:733-743);wal_compression 支持 pglz/lz4/zstd(:761-768,XLogCompressBackupBlock :1020)。在线备份强制 FPW(runningBackups>0)。**关闭 FPW=接受 torn page 风险**——这就是它默认开启的原因。

## 3.3 组提交:等待即批处理

XLogFlush 的循环(:2837-2970):等在途插入完成→`LWLockAcquireOrWait(WALWriteLock)`(:2911)——**拿不到锁说明别人正在写盘,回环等待后被"拼车"**(同一批 flush);CommitDelay(:2938-2956)提供刻意的凑批窗口。synchronous_commit=off 时提交走异步 XLogSetAsyncXactLSN(xact.c:1565)——**只丢持久性不坏一致性**(崩溃丢最近事务,不产生半事务)。组提交思想对照:Kafka producer 批量、etcd Ready 聚合——**"等待者是免费的批"**。

## 3.4 恢复:表驱动的重放

`PerformWalRecovery`(xlogrecovery.c:1626-1820):从 checkpoint 记录取 redo 点(新版在线 checkpoint 先插 XLOG_CHECKPOINT_REDO 立锚,xlog.c:7650-7658;redo 点可物理先于 checkpoint 记录 :1676-1693)→逐记录重放→分发是**表驱动**:`GetRmgr(rmid).rm_redo`(:1980)——23 个资源管理器注册在 RmgrTable X-macro(rmgr.c:50-52,rmgrlist.h:28-50),pg_waldump 复用同一张表(:666-689)。**redo 幂等判据**:`lsn <= PageGetLSN → BLK_DONE`(xlogutils.c:444-447)——页已新则跳过;整页镜像 RBM_ZERO+RestoreBlockImage(:399-403)。

## 3.5 与前作对照

| | PG WAL | SQLite WAL | etcd raft | Kafka |
|---|---|---|---|---|
| 角色 | 缓冲补救 | 备份页+提交标记 | 状态机输入 | 产品本身 |
| 写者 | 多(8 把插入锁+预留) | 单 | 领导者追加 | 分区唯一 leader |
| 顺序性 | LSN 全序 | 文件序 | index 序 | offset 序 |
| 截断 | checkpoint 后回收段 | checkpoint 回填 | snapshot 后 compaction | 保留期 |

**PG 的独特性:多写者日志**。8 把 WALInsertLock 预留并行位点+组提交落盘——这是 SQLite(单写)与 Kafka(分区单写)都没有的复杂度,也是"多进程公理"的直接产物。

## 3.6 设计动机

1. **为什么先写日志而非 shadow paging**:随机小日志 vs 整页副本的 IO 量;shadow paging 的引用计数在多进程下成本失控——WAL 把"页的任意修改"压成"字节流追加";
2. **LSN 一物三用**:字节位置/全局序号/等待令牌(XLogFlush 等到 LSN 即知落盘)——一个单调数统一三种需求;
3. **FPW 是"格式级"的正确性**:判据只有一行(:693)却能覆盖 torn page——把复杂不变式压进一个比较;
4. **表驱动 RMGR**:23 个资源管理器各自实现 redo/desc——新索引类型接入 WAL=注册一行(rmgrlist.h)。

## 3.7 FAQ

**Q1:synchronous_commit=off 会丢数据吗?**
会丢最近 ~wal_writer_delay 的已提交事务,但一致性不破(:1565 异步链)——持久性与一致性的正交。

**Q2:FPW 的整页快照什么时候发生?**
checkpoint 后(RedoRecPtr 之后)每页首改(:693);页 LSN 已新则只记增量。

**Q3:组提交是怎么"拼车"的?**
拿不到 WALWriteLock 的等待者回环,等持锁者写完自己一并 flush(:2911)——等待即批处理。

**Q4:恢复从哪里开始?**
pg_control 指向的 checkpoint 记录的 redo 点(D 章);redo 点可能早于记录本身(:1676-1693)。

**Q5:重放会不会重复执行?**
不会:`lsn <= PageGetLSN` 即 BLK_DONE(xlogutils.c:444-447)——幂等由页上 LSN 保证。

**Q6:WAL 记录多大?跨页吗?**
可跨页:写侧置 CONTRECORD(:1350-1353),读侧重拼(:719-780)——记录与页布局解耦。

**Q7:为什么 CRC 先体后头?**
半写场景:先验体,头(含长度)最后验——xlogreader.c:1240-1245。

**Q8:wal_compression 用什么算法?**
pglz/lz4/zstd(xloginsert.c:761-768):只压整页镜像,增量记录不压。

**Q9:PG WAL 和 raft 日志本质差在哪?**
raft 日志是状态机输入(必须全序复制);PG WAL 是本地缓冲的补救(无需复制,复制是另一层,卷二)——**用途决定结构**。

**Q10:checkpoint 时 WAL 段什么时候能删?**
pg_control 更新之后(:7907-7922,D 章)——锚点先移,旧日志才可弃。

## 3.8 小结与深挖方向

本章结论:**WAL = "预留-拷贝两阶段 + FPW 一行判据 + 组提交拼车 + 表驱动重放"**;多写者全序日志是 PG 区别于所有前作的核心复杂度。深挖:

1. 8 把 WALInsertLock 在高并发提交的排队水位;
2. FPW 竞态重试(:915-926)的触发频率与争用;
3. wal_compression zstd 对恢复时间的反向影响(解压成本);
4. redo 点早于 checkpoint 记录(:1676-1693)的窗口成因;
5. 组提交拼车(:2911)与 synchronous_commit 混合负载的公平性。

> 下一章:SLRU 与检查点——WAL 旁的辅助层与同步锚点。
