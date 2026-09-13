# D — SLRU 家族与检查点:WAL 旁边的辅助缓冲层与同步锚点

> 系列:《源码深读》第四系列 卷一 第 4 章
> 源码版本:PostgreSQL master,commit `8c7a74c`(shallow clone;行号以该提交为准)
> 本文所有行号均为仓库相对路径,如 `src/backend/access/transam/slru.c:549`。

---

## 1. 全景:WAL 之外的"小缓冲层"家族

WAL 记录的是"发生了什么",但很多高频查询需要的是事务元数据的**随机点查**:这个 XID 提交了吗?它的父事务是谁?这组行锁的成员有哪些?这些数据如果放进主缓冲池,要付 relation/fork/block 三元组寻址的复杂度,而它们的寻址其实是一个纯算术问题——XID 除法。PostgreSQL 为此保留了一族独立的简易 LRU 缓冲(SLRU,Simple LRU),每个实例对应 `PGDATA` 下一个目录,由通用层 `slru.c` 统一管理(头注释见 `src/backend/access/transam/slru.c:6-10`)。

| SLRU 实例 | 磁盘目录 | 每事务/条目大小 | 存什么 | 跨崩溃保留? | 注册位置 |
|---|---|---|---|---|---|
| clog(名 "transaction") | `pg_xact` | **2 bit** | 提交/中止/子提交状态 | 是(WAL 重放重建) | `src/backend/access/transam/clog.c:811-825` |
| subtrans | `pg_subtrans` | 4 B(父 XID) | 子事务→直接父事务 | **否**,启动即清零 | `src/backend/access/transam/subtrans.c:246-259` |
| multixact offsets | `pg_multixact/offsets` | 4 B(偏移) | MXID→成员数组起点 | 是 | `src/backend/access/transam/multixact.c:1785-1798` |
| multixact members | `pg_multixact/members` | 5 B(4B XID+1B 标志,按 20B 组打包) | 多事务锁同一行的成员及锁模式 | 是 | `src/backend/access/transam/multixact.c:1800-1813` |
| commit_ts | `pg_commit_ts` | 12 B(8B 时间戳+4B 节点号) | 提交时间戳(可选功能) | 是 | `src/backend/access/transam/commit_ts.c:551-564` |
| notify | `pg_notify` | 变长 | NOTIFY 队列页 | 否 | `src/backend/commands/async.c:810-820` |
| serial | `pg_serial` | 定长 | 可串行化隔离的已提交事务 | 否 | `src/backend/storage/lmgr/predicate.c:1218-1226` |

**为什么不用主缓冲池?** `slru.c` 文件头给出了三个理由(`src/backend/access/transam/slru.c:12-31`):

1. 访问高度偏斜——"写流量几乎总是打在最末页和次末页",读流量跨度大但数量少;
2. 页号由 XID 算术直接得出,不需要哈希表,按页号低位分 bank 后线性扫描即可,且**永远不逐出最末页**;
3. 锁结构更简单:每 bank 一把控制锁 + 每槽一把 I/O 锁,最末页号用原子变量读写。

另外 SLRU 页是定长定格式的"整体重写"页,不需要主缓冲池那套 per-page LSN 互锁与整页写(FPW)机制;但它仍要遵守 **WAL 先行**规则——clog/commit_ts/multixact 三家带 `group_lsn` 数组,刷页前先 `XLogFlush` 到该页最大异步提交 LSN(`src/backend/access/transam/slru.c:937-976`)。

---

## 2. SLRU 通用层:槽、锁与寻址链

### 2.1 共享结构与两级锁

每个 SLRU 有一份 `SlruSharedData`:槽数组 `page_buffer[]/page_status[]/page_dirty[]/page_number[]/page_lru_count[]`,每槽一把 `buffer_locks[]`,每 bank 一把 `bank_locks[]`,外加可选的 `group_lsn[]` 和原子变量 `latest_page_number`(`src/include/access/slru.h:48-102`)。bank 大小固定 16 槽(`src/backend/access/transam/slru.c:145-146`),槽号右移 4 位即 bank 号(`slru.c:151`)。要检视/修改某 bank 内的共享状态必须持该 bank 的控制锁;做 I/O 时释放 bank 锁、只持槽锁(`slru.c:25-31`)。控制锁不应该是老版本里的"一把全局 ControlLock"——本提交(master)已改为**分 bank 控制锁**,这是近年把 SLRU 拆锁降争用的成果(`shmem_slru_init`, `src/backend/access/transam/slru.c:266-356`;`SimpleLruGetBankLock` 见 `src/include/access/slru.h:213`)。

注册接口在本提交中名为 `SimpleLruRequest(...)`(宏,展开到 `SimpleLruRequestWithOpts`,`src/backend/access/transam/slru.c:246-263`):传目录名、槽数、`PagePrecedes` 回调、sync handler 等;缓冲区数量支持按 shared_buffers 自动整定(`SimpleLruAutotuneBuffers`,`slru.c:234-240`,clog 用"512 分之一、上限 1024 槽",`src/backend/access/transam/clog.c:775-783`)。

### 2.2 寻址链:XID → 页号 → 槽

以 clog 为例,一条完整寻址链是:

```
xid ──/32768──> 页号 pageno ──/32──> 段号 segno(文件名 %04X,src/backend/access/transam/slru.c:93-118)
                  │                      (32 页/段:src/include/pg_config_manual.h:30)
                  ├──bank = pageno % nbanks ──> bank 锁(slru.h:213)
                  └──SlruSelectLRUPage 在本 bank 16 槽内线性找:已在内存?直接用;
                     否则选受害者(EMPTY 优先,其次 LRU 最大 delta),脏则先写出再重试
```

- clog 页内:字节号 `TransactionIdToByte`,字节内位移 `TransactionIdToBIndex`(`src/backend/access/transam/clog.c:89-91`)。
- subtrans 页内:条目号 `TransactionIdToEntry = xid % 2048`(`src/backend/access/transam/subtrans.c:55,67`)。
- 槽选择核心在 `SlruSelectLRUPage`(`src/backend/access/transam/slru.c:1218-1363`):先在 bank 内找目标页(1240-1245);有空槽直接用(1280-1281);否则在合法页里选 `cur_count - page_lru_count` 最大者,平手时用 `PagePrecedes` 回调偏向更"老"的页(1307-1318);**最末页永不逐出**(1302-1305,`latest_page_number` 由 `SimpleLruZeroPage` 维护,`slru.c:431`);选中脏页则先 `SlruInternalWritePage` 再从头重试(1349-1362)。

### 2.3 读缺失路径与 I/O 协议

`SimpleLruReadPage`(`src/backend/access/transam/slru.c:549-636`)是写路径用的读缺失入口(可等或可不等 I/O):发现目标页正被读写时 `SimpleLruWaitIO` 后重来(575-582);否则标记 `SLRU_PAGE_READ_IN_PROGRESS` → 拿槽锁 → **释放 bank 锁做物理读**(`SlruPhysicalReadPage`,852-908)→ 重拿 bank 锁置 `SLRU_PAGE_VALID`(597-634)。只读查询走 `SimpleLruReadPage_ReadOnly`(653-687):先持共享 bank 锁快扫一遍,未命中才升级为排他锁走常规路径——这是锁协议里唯一允许共享态持控制锁的地方。物理读的一个经典容错:恢复期间目标 clog 段可能已被截断,文件不存在时**读成全零并打 LOG**(`slru.c:871-886`),对应 `SlruPhysicalWritePage` 注释里"red重放可能引用已截断段"的说明(`slru.c:1000-1006`)。

写出侧 `SlruInternalWritePage`(700-774)同样"置 WRITE_IN_PROGRESS → 放 bank 锁 → 写 → 重拿锁收尾";写失败把 dirty 位置回去(756-758)。刷盘不在此处同步做,而是向 checkpointer 注册 sync 请求,排满才退化为同步 `pg_fsync`(`slru.c:1056-1076`)。

### 2.4 截断:通用边界

`SimpleLruTruncate(ctl, cutoffPage)`(`slru.c:1457-1544`)先清共享内存中所有"老于 cutoff"的干净槽(1506-1519),再扫目录删段;`SlruMayDeleteSegment` 要求段的**首尾页都老于 cutoff** 才整段可删(`slru.c:1652-1661`,四象限注释见 1646-1650)。防回绕的最后防线:若 `PagePrecedes(latest_page_number, cutoffPage)` 成立,直接拒绝并 LOG "apparent wraparound"(`slru.c:1480-1487`)。

---

## 3. clog 专节:2 bit 的工程学

### 3.1 2 bit 编码与页内布局

四种状态占两 bit(`src/include/access/clog.h:27-30`):

```
0x00 IN_PROGRESS  0x01 COMMITTED  0x02 ABORTED  0x03 SUB_COMMITTED
```

关键宏(`src/backend/access/transam/clog.c:64-91`):每事务 2 bit、每字节 4 事务、每页 `BLCKSZ*4 = 32768` 事务(BLCKSZ=8K 时);页号 = `xid / 32768`,字节号 = `(xid % 32768) / 4`,bit 位移 = `(xid % 4) * 2`。一页 32K 事务、一段 32 页(约 100 万事务/段)意味着 clog 极其省空间:**100 万次事务约 128 KB**。写位操作在 `TransactionIdSetStatusBit`(`clog.c:668-725`),读在 `TransactionIdGetStatus`(742-766,经 `SimpleLruReadPage_ReadOnly`)。

页内一个字节(4 个连续 XID)的位图:

```
       bit7  6 | 5  4 | 3  2 | 1  0
byte  [xid+3  ][xid+2][xid+1][xid+0]      每格 2 bit,低 2 bit 属于较小 XID
        ABORTED  COMMIT  SUBCOM  IN_PROGRESS(示例)
```

`clog` 还为每页维护 **组 LSN**:每 32 个事务一组(`clog.c:94-98`),异步提交时把 commit 记录的 LSN 记进所属组(`clog.c:718-724`);SLRU 刷页前取全页最大组 LSN 执行 `XLogFlush`,保证"先 WAL 后 clog"(`slru.c:937-976`)。这就是为什么 clog 注册时 `nlsns = CLOG_LSNS_PER_PAGE`(`clog.c:817`)。

### 3.2 提交的原子性:跨页事务树与组提交

`TransactionIdSetTreeStatus`(`clog.c:191-257`)处理"顶层 XID + 子事务树"的提交:全在一页就一次锁内写完;跨页时先把这些页上的子事务标成 **SUB_COMMITTED**(236-239),再原子写主页,最后回头把子事务页升为 COMMITTED——对并发读者而言顶层提交仍然原子(注释 169-183)。锁争用优化是著名的 **group clog update**:抢不到 bank 锁时把自己挂进 `ProcGlobal->clogGroupFirst` 无锁链表,由队首"组长"一次持锁代全体成员写位(`TransactionGroupUpdateXidStatus`,`clog.c:449-661`;入口条件 `nsubxids <= 5`,`clog.c:105,330-335`)。

### 3.3 截断与"最老必须保留"的边界

`TruncateCLOG(oldestXact, ...)`(`clog.c:984-1018`)的顺序是一条防御链:

1. `SlruScanDirCbReportPresence` 先确认确有可删段(996-997);
2. **先** `AdvanceOldestClogXid(oldestXact)` 推进全局最老 clog 边界,使并发查询不会再碰将被删除的页(1000-1006);
3. 写 `CLOG_TRUNCATE` WAL 记录并**当场 flush**(1069-1083),让备机和崩溃恢复都知道截断点(1009-1014);
4. 才执行 `SimpleLruTruncate`。

`CLOGPagePrecedes`(`clog.c:1039-1052`)用回绕安全的 XID 比较定义"更老":同时要求页首 XID 与页尾 XID 都早于对方页。边界细节:真正的边界是 `oldestXact - 2^31`(XID 半径),但代码只按"包含 oldestXact 的页"切段,牺牲半页以换取简单(注释 1030-1037)。运行期锚点:`StartupCLOG` 以 `nextXid` 重置 `latest_page_number`(`clog.c:860-870`);`TrimCLOG` 在恢复结束后清零当前页残余位(875-915);分配新 XID 时 `ExtendCLOG` 持 XidGenLock 对新页清零并写 `CLOG_ZEROPAGE` WAL(`clog.c:942-966`;调用点 `src/backend/access/transam/varsup.c:199-201`)。

---

## 4. subtrans / multixact / commit_ts(简短)

**subtrans**:每事务 4 字节存"直接父 XID",只能自底向上走链(`SubTransGetParent`,`subtrans.c:128-155`;`SubTransGetTopmostTransaction`,`subtrans.c:169-198`)。文件头明言它与 clog 鲁棒性要求完全不同:**只服务当前打开的事务,崩溃后不需要保留**(`subtrans.c:13-20`),所以注册时 `sync_handler = SYNC_HANDLER_NONE`(`subtrans.c:253`),启动时把活跃页区间直接清零(`StartupSUBTRANS`,`subtrans.c:301-342`),checkpoint 时刷盘"仅为让 checkpointer 而非后端做 I/O"(`CheckPointSUBTRANS` 注释,`subtrans.c:347-360`)。64 层上限:`PGPROC_MAX_CACHED_SUBXIDS = 64`(`src/include/storage/proc.h:44`,注释自称"guessed-at value")。每个顶层事务的 PGPROC 只缓存 64 个子 XID;超出即置 `overflowed` 标志,"强迫读方去查 pg_subtrans"(`src/backend/access/transam/varsup.c:235-244,264-271`)——这正是 subtrans 的运行期地位:一旦快照标记 `suboverflowed`(`src/include/utils/snapshot.h:178`;置位点 `src/backend/storage/ipc/procarray.c:2452`),可见性判断必须逐个查 clog/subtrans,性能显著劣化;而若 subtrans 数据缺失,轻则 `SubTransGetTopmostTransaction` 被 `TransactionXmin` 钳制而"撒谎"(无害,`subtrans.c:176-183`),重则报 "could not access status of transaction"。

**multixact**:多事务对同一元组加共享锁时,把成员事务打包成一个 MultiXactId 写进 xmax。用**两个 SLRU**的技巧存变长数组:offsets SLRU 存每个 MXID 在 members 区的起始偏移,members SLRU 存成员本体(`src/backend/access/transam/multixact.c:19-25`);成员布局为"4 字节标志 + 4 个 XID"的 20 字节组(`src/include/access/multixact_internal.h:54-67`),`MultiXactMember = {xid, status}`(`src/include/access/multixact.h:55-59`)。分配新 MXID 时有与 XID 同款的回绕三级防线(vacuum 促发/告警/拒绝分配,`GetNewMultiXactId`,`multixact.c:1005-1065`)。它必须跨崩溃保留:WAL 里每个新 MXID 都有 CREATE_ID 记录,checkpoint 前 flush 并 sync 全部脏页(`multixact.c:27-41`;`CheckPointMultiXact`,`multixact.c:2039`)。

**commit_ts**:`track_commit_timestamp` 开启后(`src/backend/access/transam/commit_ts.c:121`),每事务记 12 字节(8B 时间 + 4B origin 节点,`commit_ts.c:62-66`,每页 682 条),同样走 WAL-before-data 互锁,主要用于逻辑复制溯源与 `pg_last_committed_xact()`。

---

## 5. 检查点专节:三步舞与分散压力

### 5.1 CheckPointGuts:一个固定顺序

`CheckPointGuts(checkPointRedo, flags)`(`src/backend/access/transam/xlog.c:8106-8140`)是常规检查点与恢复重启点共用的"刷盘全家桶",顺序固定:

```c
CheckPointRelationMap();
CheckPointReplicationOrigin();
/* 写出所有脏页:先 SLRU 各家,再主缓冲池 */
CheckPointCLOG();
CheckPointCommitTs();
CheckPointSUBTRANS();
CheckPointMultiXact();
CheckPointPredicate();
CheckPointBuffers(flags);
/* 统一 fsync(处理积压的 sync 请求) */
ProcessSyncRequests();
/* 之后才是复制槽/逻辑解码/2PC */
CheckPointReplicationSlots(...); CheckPointSnapBuild();
CheckPointLogicalRewriteHeap(); CheckPointTwoPhase(checkPointRedo);
```

要点:SLRU 与主缓冲池的"写"都通过 `RegisterSyncRequest` 把 fsync 交给 checkpointer 排队(`slru.c:1056-1076`),`ProcessSyncRequests` 统一执行(`src/backend/storage/sync/sync.c:287`);目录 fsync 已在 `SimpleLruWriteAll` 尾部保证新文件可见(`slru.c:1441-1443`)。

### 5.2 CreateCheckPoint 的完整时序

`CreateCheckPoint`(`src/backend/access/transam/xlog.c:7457-7954`)的骨架:

1. **确定 redo 点**。关机检查点直接取当前插入位置(7586-7618);在线检查点先写一条独立的 `XLOG_CHECKPOINT_REDO` 记录,以其 LSN 为 redo 点(7636-7659;`XLOG_CHECKPOINT_REDO = 0xE0`,`src/include/catalog/pg_control.h:86`)——先立锚、后干活,期间其他事务可继续写 WAL。
2. **采集计数器**:nextXid/oldestXid/oldestXidDB(7688-7692)、nextOid(7699-7703)、nextMulti/nextMultiOffset/oldestMulti/oldestMultiDB(7707-7711)、TLI(7564-7568)。
3. **等待跨界事务**:`GetVirtualXIDsDelayingChkpt(DELAY_CHKPT_START)` 轮询等待正处提交临界区、其 commit 记录恰在 redo 点之前的事务——否则"从 redo 重放不含其 commit 记录,而 clog 的提交位必须被本次刷盘覆盖"(7752-7770);`CheckPointGuts` 之后还有对称的 `DELAY_CHKPT_COMPLETE` 等待(7774-7787)。
4. **写 checkpoint 记录进 WAL 并 flush**:`XLOG_CHECKPOINT_ONLINE/SHUTDOWN`(7800-7811)。
5. **更新 pg_control**:`ControlFile->checkPoint = ProcLastRecPtr`、`checkPointCopy = checkPoint`、`minRecoveryPoint` 置无效(7845-7862);`UpdateControlFile` → `update_controlfile` 里 `pg_fsync`(`xlog.c:4672-4676`;`src/common/controldata_utils.c:261`)。
6. **善后**:`RemoveOldXlogFiles` 回收 redo 之前的 WAL 段(7907-7922)、`PreallocXlogFiles` 预分配(7928-7929)、`TruncateSUBTRANS`(7938-7939)。

### 5.3 为什么是这个顺序?三步的崩溃窗口分析

不变式是:**恢复起点 = pg_control.checkPoint 指向的 checkpoint 记录的 redo 点**;且 WAL 段只会在 pg_control 指向新检查点之后才删除。由此:

- **缓冲先刷、记录后写**:redo 点在刷盘**之前**就已锚定(在线检查点靠 XLOG_CHECKPOINT_REDO),因此刷盘动作无论完成多少,落在 redo 点之后的页改动都能从 WAL 重放重建(配合整页写)。顺序反过来(先写记录后刷盘)会让"记录声称 redo 之前、实际未落盘"的页成为洞。
- **pg_control 最后更新**:它是唯一非 WAL 的持久状态,写它之前崩溃 = 世界仍停留在上一个检查点,WAL 一段不缺,重放更长而已;写它之后崩溃 = 从新 redo 起步,重放最短。
- WAL 记录里 `XLOG_CHECKPOINT_ONLINE/SHUTDOWN` 与 pg_control 的 `checkPointCopy` 是同一结构 `CheckPoint`(`pg_control.h:35-69`),恢复端两种来源统一处理(见下节)。

### 5.4 CheckPoint 结构体与恢复侧

`CheckPoint`(`src/include/catalog/pg_control.h:35-69`):`redo`、`ThisTimeLineID/PrevTimeLineID`、`fullPageWrites`、`wal_level`、`nextXid/nextOid/nextMulti/nextMultiOffset`、`oldestXid/oldestXidDB`、`oldestMulti/oldestMultiDB`、`oldestCommitTsXid/newestCommitTsXid`、`oldestActiveXid`(热备用,仅在线检查点计算,59-65)、`dataChecksumState`。恢复侧:`StartupXLOG` 从 `ControlFile->checkPoint` 定位记录并校验 redo 可读(`src/backend/access/transam/xlogrecovery.c:729-765`);有 `backup_label` 时改信其 STARTPOINT(`xlogrecovery.c:1181-1233`)。重放途中每遇 checkpoint 记录,`xlog_redo` 应用于计数器——SHUTDOWN 型**精确采信**(8918-9021),ONLINE 型对 nextXid/nextMulti 只做"取最大"单调推进(9022-9072)——并 `RecoveryRestartPoint` 暂存供 `CreateRestartPoint` 使用(`xlog.c:8152-8179`)。这解释了截断为何总能自愈:回放 `CLOG_TRUNCATE` 会重放删除(`clog.c:1088-1115`)。

### 5.5 spread checkpoint:把 I/O 摊平

默认 `checkpoint_timeout=300s`、`checkpoint_completion_target=0.9`(`src/backend/postmaster/checkpointer.c:168-170`)。`CheckpointWriteDelay(flags, progress)`(`checkpointer.c:794-854`)由 `BufferSync` 每写完一页调用一次(`src/backend/storage/buffer/bufmgr.c:3820`):若"进度落后于时间表"(`IsCheckpointOnSchedule`,进度 × 0.9 与已流逝时间比,`checkpointer.c:864-905`)就睡 100ms(835-838),把写压力摊到 timeout×0.9 的时间窗内;急检点(CHECKPOINT_FAST/关机)不睡。同时每 1000 次写吸收一次 fsync 请求队列(`WRITES_PER_ABSORB`,`checkpointer.c:157,840-849`)。WAL 量驱动:`max_wal_size` 默认 1GB(`src/backend/access/transam/xlog.c:121`),`CheckPointSegments = max_wal_size/(1+completion_target)`(`xlog.c:2243-2247`),WAL 写入跨过该距离即 `RequestCheckpoint(CHECKPOINT_CAUSE_XLOG)`(`xlog.c:2333-2342,2555-2560`);两次触发间隔短于 `checkpoint_warning=30s` 会打"checkpoints are occurring too frequently"提示(`checkpointer.c:471-479`)。请求通道:`RequestCheckpoint` 把 flags **OR** 进共享的 `CheckpointerShmemStruct.ckpt_flags`(`checkpointer.c:1096-1102`;结构定义 119-144),checkpointer 主循环取走并递增 `ckpt_started`(431-435),完成时推进 `ckpt_done`(512-516),等待方用这对计数器 + 条件变量确认成败。

---

## 6. 崩溃窗口矩阵:三个断点,三条恢复路径

以在线检查点为对象,断电点取三个阶段(A=刷盘中途,B=checkpoint 记录已 flush、pg_control 未更新,C=pg_control 已更新、WAL 未回收):

| 断电阶段 | pg_control 指向 | 脏页状态 | 恢复路径 | 代价 |
|---|---|---|---|---|
| A:`CheckPointGuts` 中(xlog.c:7772) | 上一检查点 | 部分新页已落盘 | 从**旧** redo 重放全部 WAL(旧 redo 之后段一个不少,因为回收发生在 C 之后,xlog.c:7907-7922) | 重放最长;已落盘页被 WAL 幂等覆盖(FPW 兜底) |
| B:记录已写 WAL(xlog.c:7811),未到 7862 | 上一检查点 | 同上;WAL 中多了一条"孤儿"检查点记录 | 同 A;重放**路过**新 checkpoint 记录时采用其计数器(xlog.c:8918-9021/9022-9072)并登记重启点(xlog.c:8152-8179) | 与 A 相同;孤儿记录无害且可利用 |
| C:pg_control 已更新(xlog.c:7862),旧段未删 | **新**检查点 | 全部落盘 | 从新 redo 重放,redo 点落在 XLOG_CHECKPOINT_REDO 处(xlogrecovery.c:729-765) | 重放最短;最坏情形是 pg_control 更新后、WAL 删除前再断电,只是多留几个旧段 |

SLRU 侧的两条辅线:其一,任何时刻 clog 页都不得先于其 WAL 落盘——同步提交天然满足,clog 页靠 group_lsn 在刷页前 `XLogFlush`(`slru.c:937-976`),所以 A/B 阶段"多写的提交位"背后必有已落盘的 commit 记录;其二,若极端情况下恢复引用了已截断段,物理读按全零处理(`slru.c:871-886`)、写出容忍文件不存在(`slru.c:1000-1019`),配合 `CLOG_ZEROPAGE/CLOG_TRUNCATE` 重放(`clog.c:1088-1115`)自愈。

对照第 09 章 git fsck 的"完整性分层":git 是**事后体检**——对象库内容寻址、天生不可变,fsck 扫描引用图找悬空对象,损坏可以修;PostgreSQL 是**事前不变式**——pg_control/WAL/数据页三方时钟由检查点协议对齐,任何一方落后都通过"从更老的锚点重放"兜底,正确性不依赖事后检查,`pg_checksums`/checksum 只是可选的侦测层。

---

## 7. 与前作对照

- **SLRU vs Git 辅助索引**:两者都是主存储旁的"小而热"加速层。SLRU 之于 WAL+堆,如同 commit-graph/packed-refs 之于对象库——主数据是权威,加速层可由主数据重建(clog 可由 WAL 重放重建,subtrans 干脆不重建);区别在 git 辅助索引是冗余缓存(丢了变慢),而 clog 是**必需的真数据**(丢了语义不明),只是"必需"到可以用 WAL 重放再造。subtrans 则是最纯粹的"可丢弃加速层"。
- **checkpoint vs Kafka HW/etcd snapshot/SQLite checkpoint**:Kafka high watermark 是"消费者可见位标",解决的是**读端一致性**;etcd snapshot 是 raft 状态机周期性快照,解决"日志无限增长+重放慢",与 PG 检查点同构(快照点=redo 点,日志截断=WAL 回收);SQLite `wal_checkpoint(PASSIVE/FULL/RESTART/TRUNCATE)` 把 WAL 内容回填主库再复位 WAL,与 PG 的"刷缓冲+回收 WAL"是同一动作,但 SQLite 没有独立的 pg_control"最后真相"——它的锚点直接是 WAL 头里的 mxFrame/salt,协议上依赖单写者。PG 的 spread checkpoint(completion_target=0.9)在四者中最讲究**速率整形**;Kafka/etcd 通常靠容量/条数触发,不做速率摊平。
- 另一处可做对照:clog 组提交(`clog.c:449-661`)与 git 无对应物,倒更接近 Kafka 的"批量拉取合并"——都是用"一个执行者替一群等待者干活"换锁的吞吐。

---

## 8. 设计动机

1. **2 bit 值得一个子系统吗?** 值得,理由是乘法:clog 是每次可见性判断都要摸的组件(每行每快照),2 bit 让 8K 页覆盖 32K 事务,把"查状态"从 IO 问题变成内存算术;而组提交、跨页子事务原子性、回绕安全比较、截断边界这些复杂性全部收敛在一个 1100 行的文件里。反过来 subtrans 每事务 4 字节却"待遇"更差(不保留、不同步),因为它只在活跃事务窗口内被查——**存储格式与寿命跟着访问模式走**,这是 SLRU 家族最核心的设计纪律。
2. **检查点频率是 IO 与恢复时间的兑换率**:检查点越勤,恢复重放越短,但每次刷盘扰动越大。PG 的答案是把兑换率拆成两个旋钮(时间 `checkpoint_timeout` 与量 `max_wal_size`)加一个整形器(completion_target),并且让"量"的旋钮按 `max_wal_size/(1+target)` 自动折算(`xlog.c:2243-2247`)——回归测试意义上的不变式是:**两次检查点之间产生的 WAL,不超过 max_wal_size 减去检查点自身要写的量**。
3. **pg_control 是"最后的真相"**:所有计数器(nextXid/OID/MultiXact)在 WAL 与 pg_control 里各存一份,恢复时 WAL 版本胜出(ONLINE 取最大、SHUTDOWN 精确采信,`xlog.c:9028-9033/8924-8931`);pg_control 唯一独立裁决的是**从哪开始重放**(xlogrecovery.c:729-734)。把它设计成单页、单写者、fsync 原子小文件,正是为了让"系统上次停在哪"这个问题只有一个答案。
4. **最老 XID 锚定防回绕**:clog/multixact 的截断边界由检查点采集的 `oldestXid/oldestMulti` 下传(clog 真正的删除指令还带 TRUNCATE WAL 记录,`clog.c:1014`),配合 `SimpleLruTruncate` 的"apparent wraparound"保险(`slru.c:1480-1487`)与 `GetNewTransactionId` 的 2^31 半径告警/拒绝(`varsup.c:147-178`;MultiXact 同款 `multixact.c:1023-1037`)。XID 回绕细节留给卷二 MVCC 章,这里只记它与 SLRU 截断的耦合。

---

## 9. FAQ 素材(8-10 条)

1. **clog 为什么叫 pg_xact?** 目录名是 `pg_xact`(9.4 前 clog 曾指内存结构),SLRU 内部名 "transaction"(`clog.c:813`)。
2. **一个 clog 页能存多少事务?** 8K 页 ×4 事务/字节 = 32768 个;一段 32 页约百万事务(`clog.c:66`、`pg_config_manual.h:30`)。
3. **为什么查一个事务状态要拿 bank 锁?** 位写在共享页里,并发位更新需互斥;只读路径可用共享 bank 锁快扫(`slru.c:653-687`)。
4. **SUB_COMMITTED 存在的意义?** 跨页提交树的中间态:先全网子提交、再原子顶层提交、最后升级,保证读者不会看到"子已提交而父未提交"的假象(`clog.c:169-183`)。
5. **subtrans 丢了会怎样?** 正常崩溃后无需恢复(启动清零,`subtrans.c:301-342`);运行期若 64 个缓存槽溢出被迫查 subtrans 而数据被截断,才会出 "could not access status of transaction" 类错误(`varsup.c:235-244`)。
6. **检查点记录为什么在 master 上有两种?** 在线检查点先写 `XLOG_CHECKPOINT_REDO` 锚定 redo 点、完成时写 `XLOG_CHECKPOINT_ONLINE` 收尾;关机检查点只有 `XLOG_CHECKPOINT_SHUTDOWN` 一条两职兼任(`xlog.c:7436-7451,7636-7659,7805-7809`)。
7. **max_wal_size 是硬上限吗?** 不是。它是"何时该触发检查点"的目标(CheckPointSegments 折算),大事务/慢盘都可超;`checkpoints are occurring too frequently` 告警即由此而来(`xlog.c:2231-2247`、`checkpointer.c:471-479`)。
8. **SLRU fsync 谁做?** 后端只排队,checkpointer 在 `ProcessSyncRequests` 统一做;队列满才同步 fsync(`slru.c:1056-1076`、`sync.c:287`)。
9. **pg_control 损坏/丢失呢?** 备份 `backup_label` 可提供替代起点(`xlogrecovery.c:1181-1233`);否则 FATAL "could not locate a valid checkpoint record"(750-752)。
10. **扩展能造自己的 SLRU 吗?** 能,头注释明言扩展可定义(`slru.c:9-10`),经同一注册接口进共享内存。

## 10. 深挖(3-5 条)

1. **bank 化改造**:老版本 SLRU 是一把全局 ControlLock,bank 拆分(16 槽/bank)+ 原子 `latest_page_number` 是近年并发改造的核心(`slru.c:17-31,145-151`);可顺 `LWTRANCHE_XACT_SLRU` 等跟踪各实例 tranche 命名。
2. **组提交的唤醒协议**:`TransactionGroupUpdateXidStatus` 的无锁入队 + 组长代写 + 信号量唤醒,含 `extraWaits` 吸收(542-559)与 `pg_write_barrier`(652)的内存序论证。
3. **XLOG_CHECKPOINT_REDO 的引入**:把"确定 redo 点"与"宣告检查点完成"拆成两条记录,让检查点期间 WAL 插入不被长时间排他;对照 `RecoveryRestartPoint` 与 WAL summarizer 的边界(`xlog.c:7870-7887`)。
4. **SlruPagePrecedesUnitTests**:回绕比较函数的单元测试,用"对跖 XID"构造 RFC 1982 序缺陷的对抗用例(`slru.c:1663-1757`)——工程上如何测试模 2^32 序,极佳素材。
5. **multixact member 20 字节组**:4 标志+4 XID 的打包规避对齐,代价每页 12 字节浪费(`multixact_internal.h:54-67`)——空间换简单性的又一例。

---

## 11. 写作要点速查表

| 主题 | 文件:行号 |
|---|---|
| SLRU 设计动机(偏斜访问/免哈希/不逐出最末页) | src/backend/access/transam/slru.c:12-31 |
| bank 大小 16 / 槽号→bank | src/backend/access/transam/slru.c:145-151 |
| 共享结构(槽数组/双锁/group_lsn/latest_page_number) | src/include/access/slru.h:48-102 |
| 读缺失主路径 SimpleLruReadPage | src/backend/access/transam/slru.c:549-636 |
| 只读快路径 SimpleLruReadPage_ReadOnly | src/backend/access/transam/slru.c:653-687 |
| WAL 先行互锁(group_lsn→XLogFlush) | src/backend/access/transam/slru.c:937-976 |
| LRU 选槽 SlruSelectLRUPage(最末页不逐出) | src/backend/access/transam/slru.c:1218-1363(1302-1305) |
| 截断防回绕保险 | src/backend/access/transam/slru.c:1480-1487;整段可删判定 1652-1661 |
| clog 2bit 宏与寻址(页/字节/位移) | src/backend/access/transam/clog.c:64-91 |
| 四种状态码 | src/include/access/clog.h:27-30 |
| 跨页提交树原子性 | src/backend/access/transam/clog.c:191-257 |
| 组提交 | src/backend/access/transam/clog.c:449-661(阈值 :105) |
| 置位/读位 | src/backend/access/transam/clog.c:668-725 / 742-766 |
| TruncateCLOG 防御链 | src/backend/access/transam/clog.c:984-1018 |
| subtrans 不保留+清零;64 上限;溢出后果 | src/backend/access/transam/subtrans.c:13-20,301-342;src/include/storage/proc.h:44;src/backend/access/transam/varsup.c:235-271 |
| multixact 双 SLRU 与成员布局 | src/backend/access/transam/multixact.c:19-25;src/include/access/multixact_internal.h:32,54-67 |
| CheckpointerShmem 请求协议 | src/backend/postmaster/checkpointer.c:119-144,1063-1200 |
| spread checkpoint(节流/时间表) | src/backend/postmaster/checkpointer.c:794-854,864-905 |
| max_wal_size→CheckPointSegments→触发 | src/backend/access/transam/xlog.c:2243-2247,2333-2342,2555-2560 |
| CreateCheckPoint 时序(REDO 记录/等待/记录/控制文件) | src/backend/access/transam/xlog.c:7636-7659,7752-7787,7800-7811,7845-7862 |
| CheckPointGuts 固定顺序 | src/backend/access/transam/xlog.c:8106-8140 |
| CheckPoint 结构体 | src/include/catalog/pg_control.h:35-69 |
| 恢复起点与 redo 校验 | src/backend/access/transam/xlogrecovery.c:729-765 |
| 重放采信规则(SHUTDOWN 精确/ONLINE 取最大) | src/backend/access/transam/xlog.c:8918-9021,9022-9072 |

*(完,基于 commit 8c7a74c)*
