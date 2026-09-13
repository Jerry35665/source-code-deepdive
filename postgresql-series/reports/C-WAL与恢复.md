# C 篇 · PostgreSQL WAL 与崩溃恢复：先写日志的艺术

> 基于源码 commit `8c7a74c`（master，2026-09-12）。所有行号均为该 commit 下仓库相对路径的实际核对结果。
> 本章是《源码深读》第四系列卷一第 3 章。前作已讲过 SQLite WAL、etcd raft、Kafka 日志，本章回答：当"单文件数据库"换成"多进程并发改缓冲池"的 PG，WAL 必须长成什么样。

---

## 1. 全景：一条 UPDATE 的 WAL 旅程

```
UPDATE t SET a=1 WHERE id=42;
│
├─ ① 执行器: heap_update 原地改共享缓冲池里的页
│      (heapam.c:2178 附近, recptr = XLogInsert(RM_HEAP_ID, info))
│
├─ ② 组装记录 xloginsert.c
│      XLogBeginInsert (:153) → XLogRegisterBuffer (:245) / XLogRegisterData (:371)
│      XLogRecordAssemble (:620)  ← FPW 决策: page_lsn <= RedoRecPtr ? 整页快照 (:693)
│      XLogInsert (:481) → XLogInsertRecord (xlog.c:814)
│
├─ ③ 预留空间并落缓冲 xlog.c
│      ReserveXLogInsertLocation (:1182)  自旋锁下 CurrBytePos += size
│      CopyXLogRecordToWAL (:1299)        拷进 wal_buffers 中对应页
│      (页未初始化 → AdvanceXLInsertBuffer :2059, 满了记 wal_buffers_full :2133)
│      返回 EndPos = 记录尾 LSN  ← 数据页的 PageLSN 就用它
│
├─ ④ 提交 xact.c
│      RecordTransactionCommit (:1345) → XactLogCommitRecord (:1484) 插 COMMIT 记录
│      synchronous_commit > off ? XLogFlush(XactLastRecEnd) (:1544)
│                              : XLogSetAsyncXactLSN (:1565) 交给 walwriter
│
├─ ⑤ XLogFlush (xlog.c:2837) —— 组提交的心脏
│      等插入完成 WaitXLogInsertionsToFinish (:1578, 8 把插入锁)
│      LWLockAcquireOrWait(WALWriteLock) (:2911) —— 拿不到锁就等别人代劳=组提交
│      可选 CommitDelay 小睡等人拼车 (:2938-2955)
│      XLogWrite (:2358) write+fsync 到 pg_wal 段文件
│
├─ ⑥ 数据页落盘时 (bufmgr.c FlushBuffer)
│      recptr = BufferGetLSN(buf); XLogFlush(recptr) (bufmgr.c:4584-4585)
│      ← WAL 规则: 描述该页的日志必须先于该页落盘
│
└─ ⑦ checkpoint 保护窗 (xlog.c CreateCheckPoint :7457)
       online checkpoint 先插 XLOG_CHECKPOINT_REDO 记录 (:7650),
       其起始 LSN 成为新 RedoRecPtr (:7658)
       此后所有 page_lsn <= RedoRecPtr 的页在下次修改时整页快照 (FPW)
       段回收 RemoveOldXlogFiles (:3953) + XLOGfileslop (:2284) 按 min/max_wal_size
```

三个位点贯穿全程：insert 位点（`Insert->CurrBytePos`）、write 位点（`LogwrtResult.Write`）、flush 位点（`LogwrtResult.Flush`），分别由 `ReserveXLogInsertLocation`、`XLogWrite`、`XLogFlush` 推进。这是前作 SQLite"单一 append 游标"在多进程下的三重裂变。

## 2. 记录格式专节：24 字节头与跨页 continuation

### 2.1 XLogRecord：固定 24 字节头

`src/include/access/xlogrecord.h:41-53`：

```c
typedef struct XLogRecord
{
    uint32      xl_tot_len;     /* 整条记录总长 */
    TransactionId xl_xid;       /* 事务 id */
    XLogRecPtr  xl_prev;        /* 前一条记录起始 LSN */
    uint8       xl_info;        /* 标志位, rmgr 自由使用高 4 位 */
    RmgrId      xl_rmid;        /* 资源管理器 id */
    /* 2 字节填充, 初始化为 0 */
    pg_crc32c   xl_crc;         /* 本记录 CRC */
} XLogRecord;                   /* SizeOfXLogRecord = 24 (xlogrecord.h:55) */
```

逐字段：
- `xl_tot_len`：跳到下一条记录的唯一依据。它是结构体第一个字段，因此**必然落在本页内**，即使记录头其余部分跨页（xlogreader.c:646-651 的注释专门强调这一点）。
- `xl_prev`：prev-link，物理反向链。组装时还不知道插到哪，先填 `InvalidXLogRecPtr`（xloginsert.c:1006），拿到 `ReserveXLogInsertLocation` 返回的旧 `CurrBytePos` 后回填（xlog.c:932-933），再补算 CRC（xlog.c:980-983）。
- `xl_info`：低 4 位归系统（`XLR_INFO_MASK`，xlogrecord.h:62），高 4 位归 rmgr；`XLR_CHECK_CONSISTENCY` 位（xlogrecord.h:91）触发恢复期逐块校验。
- `xl_rmid`：RMGR 表索引，见第 6 节。
- 记录整体 MAXALIGN 起始（xlogrecord.h:34），所以预留空间要先 `MAXALIGN(size)`（xlog.c:1190）。

头部之后是若干 `XLogRecordBlockHeader`（块引用，xlogrecord.h:103-113，含 `BKPBLOCK_HAS_IMAGE/HAS_DATA/WILL_INIT/SAME_REL` 标志）和 main data 头（短格式 2 字节 / 长格式 5 字节，xlogrecord.h:219/227），最后才是块数据与 main data——与头插法的布局一致：头、块头、块数据、主数据（xlogrecord.h:21-30 的总布局注释）。

### 2.2 跨页长记录：continuation 语义

写侧：`CopyXLogRecordToWAL` 中一条记录装不下本页时，写满本页后在**下一页头**置 `XLP_FIRST_IS_CONTRECORD` 并记 `xlp_rem_len`（xlog.c:1350-1353）。段尾同理：跨段记录会把剩余空间整段耗掉（xlog.c:1272-1278 段切换预留）。

读侧（xlogreader.c，恢复主循环的解码器）：
- 入口 `XLogReadRecord`（:396）/ 新流式 API `XLogNextRecord`（:332），记录先解码进循环缓冲队列。
- 从目标页读出后先查页头 `XLP_FIRST_IS_CONTRECORD`：若本页标注"续前页"而读的位置恰是页头后第一条记录，报错"contrecord is requested by"（:632-638）——不可能存在从页中间开始的合法新记录。
- 若 `xl_tot_len > 本页剩余`，进入重组路径：拷贝首片段进 `readRecordBuf`，逐页追加，**每页必须带 CONTRECORD 标志**，否则视为记录损坏（:719-780 一带，:778 的检查）。若下一页标志是 `XLP_FIRST_IS_OVERWRITE_CONTRECORD`（本版本 xlog_internal.h 新增的"覆盖续记录"），说明该残记录已被有意作废，回到 restart 重新定位（:770-775）。
- `xl_tot_len` 上限 `XLogRecordMaxSize`（1020MB，xlogrecord.h:74）；写侧在 xloginsert.c:991 拒绝超限，读侧在 xlogreader.c:687-694 拒绝重组超限记录。
- 两级校验：先 `ValidXLogRecordHeader`（xl_tot_len/rmgr 合法性、prev-link 链检查，:1209-1216 "torn WAL pages" 防御），重组完整后再 `ValidXLogRecord` 做 CRC：**先算记录体，最后把头部（不含 xl_crc 本身 4 字节）接进去**（:1240-1245），与写侧 xlog.c:980-983 的两次计算严格对称。

CRC 覆盖不到页头；页头自身的合法性由 `XLogReaderValidatePageHeader`（xlogreader.c:1265）单独把关。这构成"页头—记录链—记录体"三层信任锚。

## 3. FPW 专节：full_page_writes 为什么必须

**问题**：checkpoint 后 redo 从 redo 点开始。若数据页在 checkpoint 前已有部分修改、checkpoint 时未刷盘、之后又发生第二处修改且只记了增量 redo，那么崩溃恢复时 redo 无法在"半新半旧"的页面上正确应用增量——必须保证 redo 起点（RedoRecPtr）之后的第一次修改把**整页快照**写进 WAL，把页面状态"拉齐"到快照点。

**决策点**（xloginsert.c `XLogRecordAssemble`，:677-699）：

```c
if (regbuf->flags & REGBUF_FORCE_IMAGE)
    needs_backup = true;            /* 调用者强制, 如索引新建页 */
else if (regbuf->flags & REGBUF_NO_IMAGE)
    needs_backup = false;
else if (!doPageWrites)
    needs_backup = false;           /* FPW 关闭且无在线备份 */
else
{
    XLogRecPtr  page_lsn = PageGetLSN(regbuf->page);   /* :691 */
    needs_backup = (page_lsn <= RedoRecPtr);           /* :693 核心判据 */
    if (!needs_backup && page_lsn < *fpw_lsn)
        *fpw_lsn = page_lsn;       /* :696 未快照页的最小 LSN, 供竞态复查 */
}
```

- `needs_backup = (page_lsn <= RedoRecPtr)`（:693）：页 LSN 落后于 redo 点 ⇒ checkpoint 之后第一次改这页 ⇒ 带整页镜像。`PageGetLSN` 直接从页首 8 字节读——PG 假设**所有可被 WAL 的页 LSN 都在页首**（:687-690 注释）。
- `doPageWrites` 是 backend 本地缓存，来自 `GetFullPageWriteInfo`（xlog.c:7025-7029，xloginsert.c:526 调用）；由于取值时尚未持插入锁，`XLogInsertRecord` 持锁后复查：`doPageWrites = (Insert->fullPageWrites || Insert->runningBackups > 0)`（xlog.c:913）——**在线备份期间 FPW 无条件强制开启**（pg_basebackup 的理论基础）。若发现竞态（fpw_lsn <= 新 RedoRecPtr 而没带镜像），返回 `InvalidXLogRecPtr` 让 `XLogInsert` 重试整个组装（xlog.c:915-926，xloginsert.c:534 的 do-while）。
- `include_image = needs_backup || XLR_CHECK_CONSISTENCY`（:720）：一致性检查模式对每条记录都带镜像，重放时再逐块比对（xlogrecovery.c:1987-1988 调用 `verifyBackupPageConsistency`）。
- 镜像**挖洞**：标准页布局时省略 `pd_lower..pd_upper` 之间的空闲区（:733-743），记录 `hole_offset` 与 `hole_length`。

**压缩**（:761-768）：`wal_compression != NONE` 时调 `XLogCompressBackupBlock`（:1020-1050），挖洞后压缩，支持 pglz / lz4 / zstd（:1047-1057 switch），压缩失败（反而变大）则退回原样（函数注释 :1013-1017）。压缩方式记入 `bimg_info` 的 `BKPIMAGE_COMPRESS_PGLZ/LZ4/ZSTD` 位（:802-828）。GUC 枚举定义在 guc_tables.c:480-494。重放侧解压还原由 xlogreader.c `RestoreBlockImage`（:2126）完成。

恢复侧应用镜像：`XLogReadBufferForRedoExtended`（xlogutils.c:362-452）——有镜像且应施用时 `RBM_ZERO_AND_LOCK` 取零页、`RestoreBlockImage` 整页覆盖、置新 LSN、返回 `BLK_RESTORED`（:396-431）；无镜像时比较 `lsn <= PageGetLSN` 决定 `BLK_DONE / BLK_NEEDS_REDO`（:444-447）——这就是**幂等 redo**：同一记录重放两次无害。

## 4. 组提交与等待链专节

### 4.1 XLogFlush：拿不到锁 = 被拼车

xlog.c:2837-2970。核心循环：

1. 快速路径：`record <= LogwrtResult.Flush` 直接返回（:2857）。
2. `WaitXLogInsertionsToFinish(WriteRqstPtr)`（:2902；函数体 :1578-1710）：遍历 8 把 WAL 插入锁（`NUM_XLOGINSERT_LOCKS`，xlog.c:157），用 `LWLockWaitForVar` 等每把锁上的在途插入越过目标位点——插入者跨页时会用 `LWLockUpdateVar` 广播进度（xlog.c:868-874 注释）。
3. `LWLockAcquireOrWait(WALWriteLock, LW_EXCLUSIVE)`（:2911）：**拿不到锁不排队，直接回环重查**——别人刷完我们就不用刷了。注释明说这是组提交的机制（"maintain a good rate of group committing"，:2905-2909）。
4. 可选 `CommitDelay` 小睡（:2938-2956）：仅当 `enableFsync` 且活跃后端数 >= `CommitSiblings`（`MinimumActiveBackends`），给后来者时间拼车。这是 9.4 之前唯一"组提交调参"，现在更多靠 2-3 步的自然搭车。
5. 自己拿到锁则把 flush 目标放大到 `insertpos`（:2959-2960），调 `XLogWrite`（:2358）一次 write+fsync，让 `LogwrtResult.Flush` 尽可能大（:2870-2876 注释："piggyback as much data as we can on each fsync"）。

`XLogWrite` 内部按页写缓冲、跨段时 `XLogFileInit`（:2431）创建新段文件，跟踪 `ispartialpage`（:2414）避免把未写满的页写出。

### 4.2 synchronous_commit 的语义

xact.c `RecordTransactionCommit`（:1345）：

```c
if ((wrote_xlog && markXidCommitted &&
     synchronous_commit > SYNCHRONOUS_COMMIT_OFF) ||
    forceSyncCommit || nrels > 0)
{
    XLogFlush(XactLastRecEnd);                      /* :1544 */
    if (markXidCommitted)
        TransactionIdCommitTree(xid, nchildren, children);   /* CLOG 置位 */
}
else
{
    XLogSetAsyncXactLSN(XactLastRecEnd);            /* :1565 唤醒 walwriter */
    if (markXidCommitted)
        TransactionIdAsyncCommitTree(..., XactLastRecEnd);   /* :1573 */
}
if (wrote_xlog && markXidCommitted)
    SyncRepWaitForLSN(XactLastRecEnd, true);        /* :1599 同步复制 */
```

- `synchronous_commit=off`：COMMIT 记录**仍写入 WAL 缓冲**，只是不等 fsync；崩溃时可能丢已确认事务（注释 :1554-1563 明言）。CLOG 的置位被推迟到日志真正落盘之后（`TransactionIdAsyncCommitTree` 记下"刷到这才能置 CLOG"的门槛 LSN）。
- `nrels > 0` 强制同步：删除物理文件的动作绝不能先于 COMMIT 记录落盘（:1532-1538）。
- 同步复制等价于把"等待"从本地 fsync 延长到远端 flush/apply（`SYNCHRONOUS_COMMIT_REMOTE_FLUSH/APPLY`，xact.c:5919 一带的分层判断）。
- 组提交的批量语义 = **一次 fsync 服务 N 个等待者**：等待者在 WALWriteLock 上排队，刷完后大家都看到 `LogwrtResult.Flush` 前进，各自返回。这与 Kafka 的 linger.ms、etcd raft 的批量 append 是同一物理规律在不同接口上的投影。

## 5. 恢复专节

### 5.1 checkpoint 记录里有什么

`CheckPoint` 结构（pg_control.h:35-69）：`redo`（重放起点 LSN，:37）、`ThisTimeLineID/PrevTimeLineID`、`fullPageWrites`、`wal_level`、`nextXid/nextOid/nextMulti`、`oldestXid`、`time`、`oldestActiveXid`（热备快照用）等。最新一份存在 pg_control。

**redo 点怎么定**（xlog.c `CreateCheckPoint` :7457）：shutdown checkpoint 直接取当前插入位点的页边界（:7588-7604）；online checkpoint 先持全部插入锁插一条 **`XLOG_CHECKPOINT_REDO`** 记录（xlog.h:86，`RM_XLOG_ID, XLOG_CHECKPOINT_REDO` 插入点 xlog.c:7650），该记录的起始 LSN 即 redo 点（`checkPoint.redo = RedoRecPtr`，:7658；`XLogInsertRecord` 对该类型持全部锁并更新共享 RedoRecPtr，xlog.c:955-971）。这条 2026 主干的新机制让 online checkpoint 的 redo 点"贴"在确定记录边界，恢复时先跳到它（xlogrecovery.c:1676-1693 校验 redo 点处必为 CHECKPOINT_REDO 记录）。info 值一览：`XLOG_CHECKPOINT_SHUTDOWN=0x00 / ONLINE=0x10 / END_OF_RECOVERY=0x90 / OVERWRITE_CONTRECORD=0xD0 / CHECKPOINT_REDO=0xE0`（pg_control.h:72-87）。

### 5.2 恢复主循环

入口链：`StartupXLOG`（xlog.c）→ 定位起点 → `PerformWalRecovery`（xlogrecovery.c:1626）。

1. **找 checkpoint**：有 `backup_label` 则用其中记录的 checkpoint LSN（read_backup_label，xlogrecovery.c:1181-1205，调用点 :548；缺 redo 段直接 FATAL，:599-611）；否则用 pg_control 的 checkPoint。`ReadCheckpointRecord`（:383）读取并校验记录类型。
2. **redo 起点**：`RedoStartLSN`（checkpoint 记录自身位置）与 `checkPoint.redo` 不同时**先回跳**——redo 点可能在 checkpoint 记录之前（online checkpoint 的 redo 点在前，记录在后），"Find the first record that logically follows the checkpoint --- it might physically precede it"（:1673-1674，:1680 `XLogPrefetcherBeginRead(xlogprefetcher, RedoStartLSN)`）。
3. **主循环** `do { ... ApplyWalRecord(...); record = ReadRecord(...); } while (record != NULL)`（:1724-1820）。`ApplyWalRecord`（:1897）依次：推进 `nextXid`（:1911）→ 处理时间线切换（CHECKPOINT_SHUTDOWN/END_OF_RECOVERY 携带新旧 TLI，:1921-1954）→ 更新 `replayEndRecPtr`（:1960-1963，供 standby 的 XLogFlush 折算 minRecoveryPoint）→ `xlogrecovery_redo` 处理 XLOG rmgr 特殊记录（:1977）→ **`GetRmgr(record->xl_rmid).rm_redo(xlogreader)`**（:1980）表驱动分发 → 更新 `lastReplayed*` 唤醒等待者（:1997-2009）。
4. 读记录：`ReadRecord`（:3122）经 xlogprefetcher 走 xlogreader；读到无效记录时 `emode_for_corrupt_record` 降级 LOG 重试寻边，备机则等 `WaitForWALToBecomeAvailable`（:375）从 pg_wal/archive/流复制任一来源补给。
5. **收尾**：`FinishWalRecovery`（:1431）返回 endOfLog、最后半页数据（:1524-1543 拷贝 `lastPage` 供写侧续写）；随后 xlog.c:6877 `RequestCheckpoint(CHECKPOINT_END_OF_RECOVERY | ...)` 写 end-of-recovery checkpoint（`CreateCheckPoint` :7475 把它当 shutdown checkpoint 处理），此 checkpoint 之前的 XLOG 不再需要。

### 5.3 部分写页与一致性判据

- **部分写页问题**由 FPW+整页覆盖解决（第 3 节），redo 恢复单页时不信任磁盘页内容，需要镜像时从零页重建：`RBM_ZERO_AND_LOCK` 即"pageinit"语义（xlogutils.c:399-403），`BKPBLOCK_WILL_INIT` 标志的页（如新页）由 redo 例程自行初始化，且强制校验标志与模式匹配（:388-393 的 PANIC 交叉检查）。
- **一致性点**（可接受只读连接）：`CheckRecoveryConsistency`（xlogrecovery.c:2165），判据 `minRecoveryPoint <= lastReplayedEndRecPtr`（:2219）。crash recovery 无 minRecoveryPoint（直接重放到 WAL 末尾）；archive recovery/备机以 pg_control 的 minRecoveryPoint（或 backup_end_required 的 backupEndPoint，:920-956）为界。
- 记录级幂等（`lsn <= PageGetLSN` 则 `BLK_DONE`，xlogutils.c:444-445）+ 页级 CRC + 记录 CRC + prev-link 链，构成四层防线。

## 6. RMGR 专节：一张函数表驱动整个恢复

`src/backend/access/transam/rmgr.c:46-52`：

```c
#define PG_RMGR(symname,name,redo,desc,identify,startup,cleanup,mask,decode) \
    { name, redo, desc, identify, startup, cleanup, mask, decode },

RmgrData RmgrTable[RM_MAX_ID + 1] = {
#include "access/rmgrlist.h"
};
```

`rmgrlist.h` 用 X-macro 列出全部 23 个资源管理器（rmgrlist.h:28-50）：XLOG、Transaction、Storage、CLOG、Database、Tablespace、MultiXact、RelMap、Standby、Heap2、Heap、Btree、Hash、Gin、Gist、Sequence、SPGist、BRIN、CommitTs、ReplicationOrigin、Generic、LogicalMessage、XLOG2。每个贡献最多 8 个钩子：`rm_redo`（恢复重放，唯一必需语义）、`rm_desc`（人类可读描述）、`rm_identify`（info 字节名）、`rm_startup/rm_cleanup`（如 Btree/GIN/GiST/SPGist 的 incomplete-action 清理，rmgr.c:65-66/81-82）、`rm_mask`（wal_consistency_checking 的掩码函数）。

- 分发点：恢复时 `GetRmgr(rmid).rm_redo(...)`（xlogrecovery.c:1980）；未注册的 id 报 `RmgrNotFound`（rmgr.c:91-95）。
- **扩展点**：`RegisterCustomRmgr`（rmgr.c:107-146）允许扩展在 `shared_preload_libraries` 阶段占一个自定义 ID（ID 需社区保留，:100-104）——第三系列讲过的"表驱动 + 延迟注册"模式在 WAL 上的再现。
- **pg_waldump 的消费**：`GetRmgrDesc(rmid)->rm_desc(&s, record)`（src/bin/pg_waldump/pg_waldump.c:666-689），`rm_identify` 把 `0x30` 翻译成 `NEXTOID`。pg_waldump 之所以能解析任何新记录类型，只因它链接同一张表——描述函数与重放函数**必须同仓演化**，这是 PG 强制"redo 与 desc 成对维护"的工程手段。
- desc 实现集中在 `src/backend/access/rmgrdesc/`（heapdesc.c、nbtdesc.c 等 23 个文件），如 xactdesc.c 描述 commit 记录的子事务/失效消息。

## 7. 与前作对照专节

| 维度 | SQLite WAL | PG WAL | etcd raft | Kafka 日志 |
|---|---|---|---|---|
| 写者数 | 单写者（writer 锁） | 多进程并发插入（8 把插入锁 + 自旋锁预留位点，xlog.c:1182/157） | 1 leader | 多分区多生产者 |
| 全序 | 单文件追加天然全序 | LSN 显式全序（CurrBytePos 单调） | index 显式全序 | 分区内 offset |
| 并发插入口 | 无 | ReserveXLogInsertLocation 预留、CopyXLogRecordToWAL 并发拷贝（两阶段，xlog.c:858-866 注释） | 提案即追加 | 追加即入列 |
| checkpoint | 回填主库页（backfill） | 保存 redo 点 + 脏页刷盘（CreateCheckPoint） | 快照 + compaction | 无（保留期策略） |
| 日志地位 | 主库的替代品 | **缓冲的补救**：日志先行，数据页只是缓存 | **日志即状态机输入** | 日志即产品 |
| 崩溃恢复 | 读 WAL 重建页缓存 | 从 redo 点重放（xlogrecovery.c:1626） | 从快照+日志重放 | 消费者位移重置 |
| 读路径 | 读 WAL 免翻主库 | 完全不读 WAL | 状态机读 | 消费者读 |

三点深化：

1. **PG WAL 不是页缓存的一部分，而是缓冲正确性的前置条件**。SQLite WAL 与主库是"同内容的两份"，PG 则是"增量因式 vs 页面结果"：数据页丢了可以靠 WAL 重算，WAL 丢了页面就无可救药。所以 PG 对 WAL 的 fsync 策略是系统的生命线（`wal_sync_method`），而 SQLite 的 WAL fsync 只影响性能下界。
2. **raft 日志是复制的唯一真源，PG WAL 是复制的载体**。物理流复制直接把 WAL 字节流当 raft 日志用（standby 重放同一段代码 xlogrecovery.c）；但 PG 的事务语义（多事务并发、CLOG 可见性）要求 standby 重放的不是"输入"而是"输入的后果"——这是热备（hot standby）比 raft 状态机复杂得多的根源。
3. **组提交是"日志先行"的赎罪券**：先写日志的代价是每事务一次 fsync，组提交把它摊薄到 N 个事务（4.1 节机制）。SQLite 单写者无此问题（无需协调），Kafka 用 batch.size/linger.ms 在生产者侧解决——同一个批量原理，三种系统三种位置。

## 8. 设计动机：为什么是先写日志，而不是 shadow paging

- **shadow paging 的死穴是随机写与回收**：每事务复制整棵页树，提交即切换根指针。页小（8KB）树深，随机 IO 与垃圾页回收在并发负载下不可行。WAL 把"随机页写"转化为"顺序日志写 + 后台批量刷页"，这正是前作 SQLite WAL 一章的核心权衡，PG 只是把它推到多写者极端。
- **LSN 一物三用**：(a) 字节偏移——定位记录（xl_prev 链、页头 xlp_pageaddr）；(b) 单调序号——幂等 redo 判据（xlogutils.c:444 `lsn <= PageGetLSN` 则跳过）与 FPW 判据（xloginsert.c:693）；(c) 等待令牌——`SyncRepWaitForLSN`（xact.c:1599）、`WaitLSNWakeup`（xlogrecovery.c:1804-1809）、`XLogSetAsyncXactLSN` 都拿 LSN 当"已达成条件"的凭据。一个 64 位单调量同时充当位置、时钟、事件，是整个子系统最经济的抽象。
- **预留-拷贝两阶段插入**（xlog.c:858-886 注释）：自旋锁下只做 `CurrBytePos += size`（xlog.c:1205-1213），锁外并发拷贝（CopyXLogRecordToWAL），把临界区压到纳秒级——多写者全序的成本被控制在一次自旋锁。
- **组提交的批量语义**：等待即批处理。`LWLockAcquireOrWait` 失败回环重查（xlog.c:2911-2919）把"排队者"变成"搭车者"；`CommitDelay` 是给搭车者的 explicit 站台（:2938）。fsync 是纯开销，批量是唯一摊薄手段——这与 Kafka producer 攒批、raft 批量提交同构。
- **FPW 是"用空间换可恢复性"的保险**：没有 FPW，redo 只能对"完整旧页"做增量；有了 FPW，任意时刻的 redo 起点都安全。代价是 checkpoint 后首批写放大（wal_compression 缓解）。SQLite 用 checkpoint 回填规避了同一问题——两者是"补救缓冲"与"主库回填"两条路线在同一难题上的分叉。

## 9. FAQ 素材

1. **WAL 记录多大？** 头固定 24 字节（xlogrecord.h:55），加块头/镜像/主数据；单条上限 1020MB（`XLogRecordMaxSize`，xlogrecord.h:74）。
2. **wal_buffers 不够会怎样？** 缓冲环满时写入者自己动手刷页（AdvanceXLInsertBuffer，xlog.c:2127-2134，计数器 `wal_buffers_full`）——不会阻塞等待，只是变慢。wal_buffers=-1 时按 shared_buffers 自动推算（xlog.c:5108 一带），最小 4 页（:5120）。
3. **synchronous_commit=off 丢的是什么？** 仅"已确认事务的持久性"：COMMIT 记录还在 WAL 缓冲没落盘，崩溃后这些事务消失但**不损坏**（xact.c:1554-1563）；不丢一致性，丢承诺。
4. **为什么 fpw 默认开？** 关掉后崩溃恢复可能遇到"半新半旧页"，增量 redo 无法应用——主备切换/备份恢复场景 FPW 还会被强制打开（xlog.c:913 runningBackups）。
5. **checkpoint 太频繁/太稀疏的代价？** 太频繁：FPW 写放大；太稀疏：恢复重放时长。调节旋钮是 min/max_wal_size 与 checkpoint 距离估算（xlog.c:7354-7383，用 90%/10% 指数滑动估计下个 checkpoint 的 WAL 量）。
6. **pg_wal 里的文件何时删？** 每次 checkpoint 后 `RemoveOldXlogFiles`（xlog.c:3953）：归档完成才删（`XLogArchiveCheckDone`，:3998），按 XLOGfileslop（:2284）在 min/max_wal_size 之间决定保留/回收数，旧段改名复用而非重建（回收）。
7. **.partial 文件是什么？** 时间线末端未写满的段归档时改名 `.partial` 再归档（xlog.c:5802-5836），防止归档"半个段"干扰原时间线。
8. **恢复怎么知道从哪开始？** pg_control.checkPoint 或 backup_label 指向的 checkpoint 记录里的 redo 字段（pg_control.h:37）；online checkpoint 的 redo 点由先行的 XLOG_CHECKPOINT_REDO 记录确定（xlog.c:7650/7658）。
9. **同一记录重放两次会坏吗？** 不会：页 LSN 判据保证已施用记录被跳过（xlogutils.c:444-447）；这正是 LSN 作"序号"的第三用途。
10. **恢复何时可以接受读连接？** `minRecoveryPoint <= lastReplayedEndRecPtr` 达成时（xlogrecovery.c:2219，CheckRecoveryConsistency :2165）。

## 10. 深挖题

1. **8 把插入锁的缓存友好性**：`MyProcNumber % NUM_XLOGINSERT_LOCKS` 选锁（xlog.c:1463），希望后端与锁稳定绑定以减少争用；跨页插入者用 `LWLockUpdateVar` 广播进度让 flusher 不必等满全程（xlog.c:868-874）。可实测 lock 持有时间分布与 `wal_buffers_full` 的相关性。
2. **XLOG_CHECKPOINT_REDO 新机制的收益**：旧版 online checkpoint 的 redo 点 = checkpoint 记录本身的插入位（需在组装期锁住全部插入锁估算），新版把 redo 点钉在一条专用记录上（xlog.c:7429-7442 注释），既缩短 FPW 保护窗又让恢复起点精确；代价是每次 checkpoint 多一条记录与多一轮全锁。适合对比 git 老版本 `checkPoint.redo = curInsert` 的实现。
3. **wal_consistency_checking 的代价模型**：每条记录带全部块的 FPW 并在重放时逐块比对（xloginsert.c:720、xlogrecovery.c:1987-1988 verifyBackupPageConsistency）——它是开发期"rm_redo 与 rm_mask 成对正确"的证明器，产出 EXPLAIN 级别的重放差异报告。
4. **恢复期预读**：xlogprefetcher.c（1107 行）在 redo 单线程重放时按块引用预取数据页，隐藏随机读延迟——重放 CPU 与 IO 的流水线化，可对比开关 `recovery_prefetch` 的重放吞吐。
5. **逻辑解码为什么读 WAL 而不复用 redo**：逻辑解码走 xlogreader 的独立实例（复用 2.2 节解析/CRC 代码），把物理增量翻译成逻辑事件——同一字节流，两种消费者，恰是"日志是系统最诚实的历史"的注脚。

## 11. 写作要点速查表

| # | 关键点 | 文件:行号 |
|---|---|---|
| 1 | XLogRecord 24 字节头定义 | src/include/access/xlogrecord.h:41-55 |
| 2 | 记录总体布局（头/块头/主数据） | src/include/access/xlogrecord.h:21-30 |
| 3 | XLogBeginInsert / RegisterBuffer / RegisterData | xloginsert.c:153 / :245 / :371 |
| 4 | XLogInsert 主入口（组装+插入+重试循环） | xloginsert.c:481-539 |
| 5 | FPW 核心判据 needs_backup = page_lsn <= RedoRecPtr | xloginsert.c:693 |
| 6 | doPageWrites = fullPageWrites \|\| runningBackups（持锁复查） | xlog.c:913 |
| 7 | FPW 挖洞与压缩 pglz/lz4/zstd | xloginsert.c:733-768 / :1047-1057 |
| 8 | CRC 两次计算（先体后头） | xlog.c:980-983 与 xlogreader.c:1240-1245 |
| 9 | 预留位点：CurrBytePos 自旋锁推进 | xlog.c:1182-1226（:1205-1213） |
| 10 | 跨页续写置 CONTRECORD | xlog.c:1350-1353 |
| 11 | 读侧重拼长记录（逐页 CONTRECORD 校验） | xlogreader.c:719-780（:778） |
| 12 | prev-link 链校验（防撕裂页） | xlogreader.c:1209-1216 |
| 13 | XLogFlush 组提交循环 | xlog.c:2837-2970（AcquireOrWait :2911） |
| 14 | WaitXLogInsertionsToFinish（8 锁） | xlog.c:1578-1710（NUM_XLOGINSERT_LOCKS :157） |
| 15 | CommitDelay 拼车睡眠 | xlog.c:2938-2956 |
| 16 | 提交路径 XLogFlush vs 异步提交 | xact.c:1540-1574（:1544 / :1565） |
| 17 | wal_buffers_full 自刷页 | xlog.c:2127-2134 |
| 18 | checkpoint：XLOG_CHECKPOINT_REDO 定 redo 点 | xlog.c:7650-7658；info 值 pg_control.h:72-87 |
| 19 | 段回收 XLOGfileslop / RemoveOldXlogFiles | xlog.c:2284-2318 / :3953-4009 |
| 20 | 恢复主循环 PerformWalRecovery + ApplyWalRecord 表驱动分发 | xlogrecovery.c:1626-1820 / :1897 / :1980 |
| 21 | read_backup_label 定位恢复起点 | xlogrecovery.c:1181-1205（调用 :548） |
| 22 | redo 幂等判据 lsn <= PageGetLSN → BLK_DONE | xlogutils.c:444-447 |
| 23 | RmgrTable X-macro 注册表 / pg_waldump 消费 | rmgr.c:50-52 / pg_waldump.c:666-689 |
| 24 | 数据页落盘前 XLogFlush 页 LSN | bufmgr.c:4565-4585 |

（完，约 340 行）
