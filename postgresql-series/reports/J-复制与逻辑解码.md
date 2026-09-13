# J 篇 · 复制与逻辑解码：WAL 的消费者们

> 源码版本：PostgreSQL master，commit `8c7a74c`（shallow clone）。本文所有 `文件:行号` 均为仓库相对路径，已逐条 grep/Read 核对。
> 前作对照：卷一 03 章《WAL 与恢复》讲的是 WAL 作为**本地日志**的写入与崩溃恢复；本章讲的是**同一份 WAL 的三类外部消费者**：物理 standby（字节流原样复制）、逻辑订阅（解码为逻辑变更流）、以及本地恢复之外的反馈回路（同步复制、槽回收边界）。

---

## 1. 全景：一份 WAL，三类消费者

```
                          +---------------------------+
   后端 commit  ──XLogInsert──▶  WAL buffer / pg_wal 段  │
                          +-------------+-------------+
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        │(1) 本地崩溃恢复                 │(2) 物理流复制                   │ (3) 逻辑解码
        │   xlogrecovery.c               │   walsender.c                 │   logical/decode.c
        │   startup 进程逐条 redo         │   walsender 进程              │   walsender 进程 + reorderbuffer
        │   ReadRecord→ApplyWalRecord     │   XLogSendPhysical            │   XLogSendLogical
        │   minRecoveryPoint 兜底          │   原样字节流('w' 消息)          │   Decode→重排→输出插件
        │   (卷一 03 章)                  │   walreceiver.c 落盘            │   worker.c 订阅端回放
        │                               │   + replay 反馈('r')           │   + flush 反馈('r')
        ▼                               ▼                               ▼
   本地一致性                       standby 副本(块级镜像)              逻辑变更流(begin/change/commit)
   crash-safe                      可读/可 failover                    跨版本、跨 schema、可过滤
```

三类消费者共享一个事实：**发送端只发送已在本机 fsync 的 WAL**（`XLogSendPhysical` 以 `GetFlushRecPtr()` 为发送上限，src/backend/replication/walsender.c:3489）。这保证了 primary 崩溃后从控制文件 redo 点重放不会"丢"任何已发给 standby 的字节——复制正确性完全建立在卷一 03 章的 WAL 刷盘纪律之上。

---

## 2. walsender 专节：一条连接就是一个小状态机

### 2.1 状态机与行号链

walsender 共享内存状态五值：`WALSNDSTATE_STARTUP/BACKUP/CATCHUP/STREAMING/STOPPING`（枚举见 src/include/replication/walsender.h，切换函数 `WalSndSetState` 定义于 src/backend/replication/walsender.c:4218，各 case 注释 4241-4249）。行号链：

1. 进程认领共享槽位，置 `STARTUP`（walsender.c:3247，`WalSndErrorCleanup` 里兜底回 STARTUP:406）。
2. `exec_replication_command`（walsender.c:2105）解析复制协议命令；收到 STOPPING 信号后新命令一律拒绝（walsender.c:2120-2131）。
3. `START_REPLICATION ... PHYSICAL`（`StartReplication`，walsender.c:860）：校验时间线与起始点后置 `CATCHUP`（walsender.c:991），回 `CopyBothResponse` 进入双向 COPY（walsender.c:994-998），拒绝从"本机尚未 flush 的未来 WAL"开始流（walsender.c:1004-1010），然后进入主循环 `WalSndLoop(XLogSendPhysical)`（walsender.c:1025）。
4. `CREATE_REPLICATION_SLOT ... LOGICAL` + `START_REPLICATION ... SLOT x LOGICAL`（`StartLogicalReplication`，walsender.c:1532）：`ReplicationSlotAcquire`（1542）→ `CreateDecodingContext`（1563-1569）→ 置 `CATCHUP`（1572）→ CopyBoth（1575-1579）→ `WalSndLoop(XLogSendLogical)`（1601）。
5. **CATCHUP→STREAMING 的切换**在主循环内完成：只有当 `WalSndCaughtUp && 输出缓冲已清空` 才切换（walsender.c:3124-3140）。注释明说这个状态切换对**同步复制**是关键分界——在此之前提交流出的 standby 若 primary 崩溃可能丢数据（walsender.c:3127-3132）。
6. `BACKUP` 状态用于 base backup：`exec_replication_command` 的 `T_BaseBackupCmd` 分支调用 `SendBaseBackup`（walsender.c:2253→2257），实现在 src/backend/backup/basebackup.c:997，走独立的 bbsink 管道，本章不展开。
7. 时间线历史回放：若客户端要的是本机已离开的旧 timeline，`sendTimeLineIsHistoric=true`，流到分叉点 `sendTimeLineValidUpto` 即发 CopyDone 停止（`XLogSendPhysical`，walsender.c:3532-3548），随后返回单行结果集告知 next_tli/next_tli_startpos（walsender.c:1042-1078）——这就是级联/提升场景里"换时间线续传"的协议出口。

### 2.2 流式协议（消息类型）

物理与逻辑复制复用同一套 CopyData 子消息（src/include/libpq/protocol.h:75-84）：

| 字节 | 方向 | 含义 |
|---|---|---|
| `'w'` PqReplMsg_WALData | P→S | WAL 数据：dataStart/walEnd/sendTime 头 + WAL 字节 |
| `'k'` PqReplMsg_Keepalive | P→S | 心跳：walEnd/sendTime/是否要求回复 |
| `'r'` PqReplMsg_StandbyStatusUpdate | S→P | 进度反馈：write/flush/apply 三个 LSN + 时间 |
| `'h'` PqReplMsg_HotStandbyFeedback | S→P | xmin/catalog_xmin 反馈（防 vacuum 前进） |

`XLogSendPhysical` 每次最多发 `MAX_SEND_SIZE`，并在页边界截断——**绝不把一条 WAL 记录拆进两条消息**，这是 walreceiver 依赖的隐含协议（walsender.c:3558-3587）；读数据时优先从 WAL buffer 直接读（`WALReadFromBuffers`，walsender.c:3610-3614）。消息头三字段在 walsender.c:3596-3600 打包，walreceiver 侧在 `XLogWalRcvProcessMsg` 解包（src/backend/replication/walreceiver.c:921-985）。

### 2.3 心跳与超时

- `WalSndKeepaliveIfNecessary`（walsender.c:4466）：半个 `wal_sender_timeout` 没收到回复就发要求回复的 keepalive（walsender.c:4485-4489），消息构造在 `WalSndKeepalive`（walsender.c:4443）。
- `WalSndCheckTimeOut` 超时杀连接；`WalSndLoop` 每圈依次检查超时→shutdown 超时→心跳→睡眠（walsender.c:3153-3208）。
- 延迟量化：`LagTrackerWrite` 在发送 WAL 时把 (LSN, 时间) 记入环形缓冲（walsender.c:4504-4546），收到 `'r'` 反馈后 `LagTrackerRead` 算出 write/flush/apply 三种滞后（walsender.c:2588-2590）。

### 2.4 接收端反馈回路：write/flush/apply 三指针

walreceiver 的 `XLogWalRcvWrite` 把 `'w'` 数据原样追加进 pg_wal 段文件（walreceiver.c:992-1014）；`XLogWalRcvFlush` 对其 fsync，把 `LogstreamResult.Flush` 写入共享内存 `flushedUpto`，唤醒 startup 进程与级联 walsender（walreceiver.c:1093-1134）。`XLogWalRcvSendReply`（walreceiver.c:1216）上报 write（已写内核）/flush（已 fsync）/apply（已重放，`GetXLogReplayRecPtr`，walreceiver.c:1257-1258）三指针。

walsender 侧 `ProcessStandbyReplyMessage`（walsender.c:2545）做三件事：
1. 写入共享内存供 pg_stat_replication 与同步复制使用（walsender.c:2619-2634）；
2. 若自身不是级联节点，调用 `SyncRepReleaseWaiters()` 放行同步等待者（walsender.c:2636-2637）；
3. 若持有槽，按槽类型推进 `restart_lsn/confirmed_flush`（walsender.c:2642-2648，物理走 `PhysicalConfirmReceivedLocation` walsender.c:2512，逻辑走 `LogicalConfirmReceivedLocation`）。

standby 上的只读查询（hot standby）还需要防 vacuum 破坏：`XLogWalRcvSendHSFeedback`（walreceiver.c:1289）周期取 `GetReplicationHorizons()` 把 xmin/catalog_xmin 连同 epoch 发回 primary（walreceiver.c:1337-1371），primary 侧 walsender 校验回绕后写入槽或进程 xmin（`ProcessStandbyHSFeedbackMessage` walsender.c:2733 → `PhysicalReplicationSlotNewXmin` walsender.c:2653-2689）。

### 2.5 standby 恢复侧：minRecoveryPoint

startup 进程的 standby 重放主循环就是卷一 03 章 `ApplyWalRecord`（src/backend/access/transam/xlogrecovery.c:1897，调用点 1796）的延续，差异在**边界**：
- `minRecoveryPoint` 是"一致性最低要求"：只有重放到它之后才允许打开读服务（`reachedConsistency`，xlogrecovery.c:290-304）；恢复目标若在一致性点之前直接 FATAL（xlogrecovery.c:1826-1830）。
- standby 持续运行期间，`XLogFlush` 通过 `UpdateMinRecoveryPoint`（src/backend/access/transam/xlog.c:2759）不断把控制文件的 minRecoveryPoint 推进到已重放位置（xlogrecovery.c:1956-1963 的注释说明该配合），因此 standby 崩溃重启至少重放到上次读服务看到的位置。
- 时间线切换有专门安检 `checkTimeLineSwitch`（xlogrecovery.c:2370-2405）：新 TLI 必须在历史内、不得在到达 minRecoveryPoint 之前跨到更高时间线（xlogrecovery.c:2395-2402）。
- 时间线基础设施在 src/backend/access/transam/timeline.c：`readTimeLineHistory`（timeline.c:77）读 `_history` 文件、`tliSwitchPoint`（timeline.c:573）求分叉点、`tliOfPointInHistory`（timeline.c:545）判断某 LSN 属于哪条时间线；提升时 `writeTimeLineHistory`（timeline.c:305）落盘新历史文件。TLI 是复制的"代"，物理流复制跨 TLI 续传全靠它（walsender.c:3310-3347 的段文件打开逻辑即处理跨 TLI 段名）。

---

## 3. 同步复制专节：SyncRepWaitForLSN 的队列语义

### 3.1 等待路径（backend 进程）

`SyncRepWaitForLSN(lsn, commit)`（src/backend/replication/syncrep.c:149）在 XLogFlush 之后、commit 返回之前被调用（衔接卷一 03 章 `XLogFlush`：先本地落盘，再等远端）：

```c
/* src/backend/replication/syncrep.c:184-188 */
/* Cap the level for anything other than commit to remote flush only. */
if (commit)
    mode = SyncRepWaitMode;          /* remote_write/flush/apply 由 GUC 定 */
else
    mode = Min(SyncRepWaitMode, SYNC_REP_WAIT_FLUSH);
```

- 快速退出：未配置同步 standby 或该 LSN 已被更早的反馈覆盖（syncrep.c:179-182, 208-227）——每次 commit 都走这里，所以无锁快路径刻意最短。
- 入队：`MyProc->waitLSN = lsn` 后按 LSN 有序插入三条队列之一（write/flush/apply）（syncrep.c:251-253，`SyncRepQueueInsert` syncrep.c:382-410，从尾向前找插入点维持升序）。
- 睡眠：latch 等待、**无超时**（syncrep.c:341-342）；SIGTERM/查询取消也不能让事务"回滚"——本地已提交，只能 WARNING 后放弃等待（syncrep.c:301-335）。这是同步复制的核心语义：**等待中的提交已经落盘，只是不能向客户端确认**。

### 3.2 释放路径（walsender 进程）

每条 `'r'` 反馈触发 `SyncRepReleaseWaiters`（syncrep.c:484，调用点 walsender.c:2636）。仅当本 walsender 的 standby 有同步优先级、且状态已是 STREAMING/STOPPING 才继续（syncrep.c:502-505）——**CATCHUP 状态的 standby 不放行同步提交**，呼应 2.1 的状态机。

`SyncRepGetSyncRecPtr` 汇总当前"合格同步 standby 集合"（syncrep.c:613 调 `SyncRepGetCandidateStandbys`），并按配置语义取指针（syncrep.c:649-659）：

- **优先级模式**（`FIRST n (name, ...)` 或不带关键字）：取所有同步 standby 的 write/flush/apply 的**最老值**（`SyncRepGetOldestSyncRecPtr` syncrep.c:669-695）——最慢的一个决定放行水位；
- **quorum 模式**（`ANY n (name, ...)`）：取**第 n 新的值**（`SyncRepGetNthLatestSyncRecPtr` syncrep.c:702-729，排序后取倒数第 n）。

语法在 src/backend/replication/syncrep_gram.y:68-71：裸列表=1 个优先级、`ANY n`=quorum、`FIRST n`=优先级；`check_synchronous_standby_names`（syncrep.c:1064）把解析结果存进 `SyncRepConfig`。候选数不足 `num_sync` 时整体不放行（syncrep.c:629-634）——quorum 的 "n" 是硬下限。

### 3.3 失败模式：standby 全挂会怎样？

- 所有同步 standby 掉线 → 队列无人放行 → **primary 上等待的 commit 无限期挂起**（syncrep.c:341 无超时），新写事务被同步 GUC 波及。这是设计立场：同步复制的承诺（确认=已复制）优先于可用性；解法是运维侧把 synchronous_standby_names 改空（checkpointer 置 SYNC_STANDBY_DEFINED 位后各 backend 自行退出等待，syncrep.c:160-182）。
- 若配置了 `ANY 1 (a,b)`，单台挂掉不影响（quorum 的意义正是容忍 n-1 台故障）。
- 管理员 kill 正在等待的 backend 是安全的：事务仍会本地提交，只是连接收到 WARNING（syncrep.c:301-319）。

---

## 4. 复制槽专节：回收边界的"活锚点"

### 4.1 两种槽、两组锚点

槽是**持久化的消费者进度对象**（src/backend/replication/slot.c，结构见 src/include/replication/slot.h）。锚点字段分工：

- **物理槽**：只关心 `restart_lsn`。创建时锚到当前 redo 点（`ReplicationSlotReserveWal`，slot.c:1709：物理槽取 `GetRedoRecPtr()`，slot.c:1751）；walreceiver 每次反馈推进它（`PhysicalConfirmReceivedLocation`，walsender.c:2512-2531 直接把 restart_lsn = 反馈 flush LSN）。
- **逻辑槽**：双锚点。`restart_lsn` = 还需读取的 WAL 起点（重放目录/构建快照用），`confirmed_flush` = 客户端已确认消费的逻辑位置（下次续传起点）。二者由 `LogicalIncreaseRestartDecodingForSlot`/`LogicalConfirmReceivedLocation`（src/backend/replication/logical/logical.c:1826/1902）以"candidate 两阶段"方式推进——只有当反馈 LSN ≥ candidate 生效 LSN 时才真正前移（logical.c:1864-1895），且 `confirmed_flush` 只进不退（logical.c:1930-1931）。`StartLogicalReplication` 从 restart_lsn 开始读 WAL、从 confirmed_flush 开始发变更（walsender.c:1582-1593）。

### 4.2 与 WAL 回收的相互作用（呼应卷一 04 章）

卷一 04 章讲过：checkpoint 决定可回收段的下界。槽就是这个下界的**第三个来源**（前两个是 redo 点与归档）：

```c
/* src/backend/access/transam/xlog.c:8571-8580  (KeepLogSeg) */
/* Calculate how many segments are kept by slots. */
keep = XLogGetReplicationSlotMinimumLSN();
...
/* Account for max_slot_wal_keep_size to avoid keeping more than
 * configured. */
if (max_slot_wal_keep_size_mb >= 0 && !IsBinaryUpgrade)
```

- `ReplicationSlotsComputeRequiredLSN`（slot.c:1306）扫全部在用槽取最小 restart_lsn（持久槽用 `last_saved_restart_lsn` 兜底防崩溃间隙，slot.c:1337-1349），`XLogGetReplicationSlotMinimumLSN`（xlog.c:2738）暴露给 checkpoint。
- 逻辑槽还有 xmin 侧：`ReplicationSlotsComputeRequiredXmin`（slot.c:1224）把 catalog_xmin 汇入 vacuum 的 xmin 下界——逻辑槽同时锁 WAL 和行版本。
- 但回收不受槽**无限**钳制：`max_slot_wal_keep_size_mb` 是闸门；一旦 WAL 真被删到槽需要的位置之下，槽进入**失效**流程（见 4.3），而不是让主库磁盘爆炸。注意：**standby 同样需要槽**——hot_standby_feedback 只保护行版本，standby 上的物理槽 restart_lsn 在 `CreateRestartPoint` 中同样参与回收下界（xlog.c:8382）。

### 4.3 槽失效：防御性自愈

失效原因五类（slot.c:116-120）：`wal_removed`（WAL 已被回收）、`rows_removed`（xmin horizon 冲突）、`wal_level_insufficient`、`idle_timeout`、`none`。执行者 `InvalidateObsoleteReplicationSlots`（slot.c:2218）在四个时机被调用：`CreateCheckPoint` 删段前（xlog.c:7909）、`CreateRestartPoint`（xlog.c:8382）、standby 重放到 primary 关闭逻辑解码记录时（xlog.c:9280）、冲突解决（src/backend/storage/ipc/standby.c:506）。

单槽处理在 `InvalidatePossiblyObsoleteSlot`（slot.c:1978）：槽空闲则直接标记 `data.invalidated`（slot.c:2059-2073，wal_removed 时顺手把 restart_lsn 置空，使 pg_wal 立刻可继续回收）；槽正被 walsender 使用则先 SIGTERM 其进程再重试。失效后的槽 acquire 会报错（slot.c:733），`ReportSlotInvalidation`（slot.c:1788）负责留一条带原因的日志。设计取向清晰：**宁可让订阅者重建，不可让 primary 卡死或磁盘写满**。

---

## 5. 逻辑解码专节：把内部日志升格为公共 API

### 5.1 总骨架

- 建解码上下文：`CreateDecodingContext`（src/backend/replication/logical/logical.c:577）——校验逻辑槽（logical.c:597-600 物理槽不可用）、起始 LSN 钳到 `confirmed_flush`（logical.c:630-654）、加载输出插件（`LoadOutputPlugin` logical.c:815，dlopen 符号 `_PG_output_plugin_init`）。
- 找起点：`DecodingContextFindStartpoint`（logical.c:713）从 `restart_lsn` 开始逐条 `LogicalDecodingProcessRecord`，直到快照状态到 CONSISTENT（`DecodingContextReady` logical.c:704-707），然后把 `confirmed_flush` 定格在当前 EndRecPtr（logical.c:745-749）——槽创建（`CREATE_REPLICATION_SLOT ... LOGICAL`）路径走这里。
- 分发：`LogicalDecodingProcessRecord`（src/backend/replication/logical/decode.c:89）先按 top-xid 把子事务挂到 reorderbuffer（`ReorderBufferAssignChild`，decode.c:106-112），再按资源管理器分发 `rm_decode`（decode.c:114-117）。
- 事务记录：`xact_decode`（decode.c:213）处理 commit/abort/prepare/assignment/invalidations；不到 FULL_SNAPSHOT 一概不看（decode.c:224-225）。`DecodeCommit`（decode.c:688）是主通道：先 `SnapBuildCommitTxn`（decode.c:703）更新快照，不关心的用 `ReorderBufferForget` 丢弃（decode.c:724-733），关心的把子事务合并后交给 `ReorderBufferCommit`（decode.c:753-757）。

### 5.2 snapbuild：解码快照的一致性问题（最难的部分）

**问题**：WAL 里每个变更记录只有 xmin（可能只是子事务 id），没有"这条变更发生时哪些其他事务已提交"。要判断一个 tuple 变更对某个快照是否可见，解码器必须重建"当时"的全局快照。但它是在**回放历史 WAL**——先见到 commit 记录，变更记录却可能在几页之前；且解码器启动点可以是任意 LSN，之前已提交的事务不会再出现 commit 记录。

解法是让 primary 定期写 `xl_running_xacts`（standby 快照记录，卷一 03 章的 `LogStandbySnapshot`），解码器用它做状态机（状态图注释 snapbuild.c:70-96，原理说明 98-113）：

```c
/* src/backend/replication/logical/snapbuild.c:1350-1361 (START→BUILDING_SNAPSHOT) */
else if (builder->state == SNAPBUILD_START)
{
    builder->state = SNAPBUILD_BUILDING_SNAPSHOT;
    builder->next_phase_at = running->nextXid;
    /* Start with an xmin/xmax that's correct for future, when all the
     * currently running transactions have finished. */
    builder->xmin = running->nextXid;   /* < are finished */
    builder->xmax = running->nextXid;   /* >= are running */
```

`SnapBuildFindSnapshot`（snapbuild.c:1244）四条路：
- (a) `oldestRunningXid == nextXid`：写记录瞬间无运行事务，直接 CONSISTENT（snapbuild.c:1300-1323）；
- (b) 磁盘上有本槽/他槽序列化好的快照可恢复（snapbuild.c:1330-1336，`SnapBuildRestore` snapbuild.c:1847，文件格式 magic/version snapbuild.c:1480-1481）；
- (c) START→BUILDING_SNAPSHOT（snapbuild.c:1350-1373）→BUILDING→FULL_SNAPSHOT（snapbuild.c:1384-1397）→FULL→CONSISTENT（snapbuild.c:1408-1418），每一级都等"上一代的运行事务全部终结"。

**为什么不能直接用 running_xacts 里的 xids 数组当快照**？snapbuild.c:1345-1348 的注释给出答案：事务被标记为 running 时，它的 commit 记录可能已经写入 WAL（无锁无法避免这个交错），所以只能以 `nextXid` 为界、等所有 `< nextXid` 的事务真正终结（从 WAL 里见到 commit/abort），而**不能**信数组内容本身。此外 `SnapBuildProcessRunningXacts`（snapbuild.c:1142）还要过滤 xmin horizon 太老的记录（snapbuild.c:1275-1289，太老则必需的 catalog 行可能已被 vacuum）。CREATE_REPLICATION_SLOT 时导出给客户端的快照即 `SnapBuildInitialSnapshot`（snapbuild.c:444）——这是"先建槽、再用一致快照做初始数据拷贝"这套流程的理论支点。

### 5.3 reorderbuffer：按提交序重排、溢出与 top-subxact 归并

- **重排的必要性**：WAL 按记录写入序排列，长事务的变更散布其中；订阅端需要的是**提交序**的完整事务。`ReorderBufferCommit`（src/backend/replication/logical/reorderbuffer.c:2893）在见到 commit 记录时才触发 `ReorderBufferReplay`，用 `ReorderBufferIterTXNNext` 把 top 事务与其全部子事务的变更按 LSN 归并输出（`ReorderBufferProcessTXN`，reorderbuffer.c:2214-2300；归并迭代器 2270-2271；顺序断言 2297-2299）。top-subxact 归并靠 `ReorderBufferAssignChild`/`ReorderBufferCommitChild`（reorderbuffer.c:1100/1220），每个 WAL 记录都先走一遍子事务归属（decode.c:106-112）。
- **溢出（spill）**：未提交事务不能无限堆内存。内存水位 = `logical_decoding_work_mem`（reorderbuffer.c:226）。每加一条变更检查 `ReorderBufferCheckMemoryLimit`（reorderbuffer.c:3928，调用点 866）：超限就反复挑**最大**的事务驱逐（`ReorderBufferLargestTXN` reorderbuffer.c:3837）。驱逐去向二选一（reorderbuffer.c:3970-4001）：可流式（插件声明 stream 支持）则 `ReorderBufferStreamTXN`（reorderbuffer.c:4374）边收边发给订阅端；否则 `ReorderBufferSerializeTXN`（reorderbuffer.c:4029）把变更序列化到 `pg_replslot/<slot>/` 下磁盘文件，commit 时再读回重放。
- **输出回调链**：`ReorderBufferProcessTXN` 依次调 `rb->begin`（reorderbuffer.c:2262-2268）→ 逐 change 分发（2312 起）→ 插件层包装。输出插件通过 `OutputPluginPrepareWrite`/`OutputPluginWrite`（logical.c:772/785）把行缓冲拼进 CopyData；walsender 侧的 prepare/write 回调由 `StartLogicalReplication` 注入（walsender.c:1568-1569）。
- 逻辑解码只解**目录**可见性所需的最小信息：变更 tuple 的可见性判断用历史快照（`SetupHistoricSnapshot` reorderbuffer.c:2233），catalog 变更事务靠 `catalog_xmin` 保护行版本（4.2）。

### 5.4 输出插件：pgoutput 与协议

内置插件 pgoutput（src/backend/replication/pgoutput/pgoutput.c）注册 `pgoutput_startup/begin_txn/change/truncate/commit_txn/...` 回调（声明 pgoutput.c:51-75 附近，选项解析含 `streaming`/`two_phase`，pgoutput.c:380-386）。它把 change 翻译成逻辑复制协议消息——src/backend/replication/logical/proto.c 的 `logicalrep_write_begin`（proto.c:49）/`write_commit`（78）/`write_origin`（374）/`write_insert`（403）/`write_update`（450）/`write_delete`（528），再由订阅端镜像函数解包。

### 5.5 发布订阅：apply 侧（worker.c）

每个订阅 `max_replication_slots/2` 以内的表起一个 apply worker：主循环 `LogicalRepApplyLoop`（src/backend/replication/logical/worker.c:4029）收 `'w'`，按消息字分发 `apply_dispatch`（worker.c:4141-4144）；`apply_handle_begin/commit`（worker.c:1248/1271）驱动本地事务，行级处理在 `apply_handle_insert/update/delete`（worker.c:2674/2831/3060）。

反馈由 `send_feedback`（worker.c:4345）承担：**flush 位置只在事务本地提交后前移**（`get_flush_position` worker.c:4369），没有在途事务时才允许 flush=write=recv 直接上报（worker.c:4375-4376）——注释明说这是给同步复制用的（跨库同步复制的确认到达订阅端 apply 之后）。大事务流式模式下，`apply_handle_stream_start/stop/commit`（worker.c:1758/1922/2431）配合并行 apply：超过阈值的流式事务交给独立进程（src/backend/replication/logical/applyparallelworker.c，进程池 237、共享结构 242），leader 在 commit 时等待其完成，避免单事务 apply 串行阻塞。

---

## 6. 物理复制 vs 逻辑复制对比

| 维度 | 物理流复制 | 逻辑复制（解码+订阅） |
|---|---|---|
| 复制单元 | WAL 字节流（页/记录级，`'w'` 原样转发，walsender.c:3596） | 逻辑变更（表/行/事务，begin/change/commit 回调链） |
| 副本形态 | 块级镜像，schema/物理布局完全一致 | 仅发布表数据；订阅端 schema 独立 |
| 延迟语义 | write/flush/apply 三指针反馈（walreceiver.c:1216） | 仅 apply/flush 两级反馈（worker.c:4345），以事务为粒度 |
| 消费端 | 同版本 PostgreSQL（startup 进程 redo） | 任意 PG 版本、可接外部系统（插件自由输出） |
| schema 演进 | 必须主从同步（DDL 经 WAL 复制） | 支持一定差异；DDL 不复制，需自行协调 |
| 槽锚点 | restart_lsn 一个（walsender.c:2522） | restart_lsn + confirmed_flush 双锚（logical.c:1902） |
| 回收保护 | 锁 WAL 段（slot.c:1306） | 锁 WAL 段 + catalog 行版本（slot.c:1224） |
| 典型用例 | HA/failover、只读扩展、备份源 | 升级、汇聚、CDC、部分表订阅 |
| 同步复制支持 | 原生（syncrep.c） | 端到端可达（同步 commit 等 apply 反馈，worker.c:4375） |

---

## 7. 与前作对照

- **etcd/Raft（卷一对照）**：Raft 的日志本身就是共识对象——复制日志的多数派确认即提交，日志位置（Index）= 提交序。PG 物理复制里日志只是**字节备份**：LSN 排列即物理写入序，standby 重放不参与任何"确认"，同步语义靠旁路的 LSN 反馈（syncrep.c）补挂上去。这解释了为何 PG 同步复制粒度粗（提交级、无自动 failover 共识）而 Raft 细（每条日志）。
- **MySQL binlog**：row 格式 binlog 与 PG 逻辑解码是同类物——都把"数据变更"从物理页操作中抽出来。差异在 MySQL 的 binlog 是**独立于存储引擎 redo 的第二套日志**（双写两份），而 PG 用**同一份 WAL** 兼做物理与逻辑两种消费：逻辑解码是 WAL 的只读视图加解码器（decode.c），没有任何"逻辑日志"落盘。代价就是 5.2 节那一整套快照重建与重排。
- **Kafka MirrorMaker**：按 topic/partition 复制"已提交消息"，语义上是逻辑复制 + 消费位点（offset）≈ confirmed_flush。PG 逻辑槽把位点做成**主库持久化对象**（slot.c）而非消费端本地文件，换来的是主库能主动保护位点之前的 WAL/行版本——这是"服务端管理消费进度"与"客户端自管进度"两种流派。
- **PG 逻辑解码的独特性**：把内部恢复日志升格为公共 API（`_PG_output_plugin_init`、logical.c:815 动态加载），物理日志格式未做任何逻辑化改造，全靠 reorderbuffer 在读侧重排。对比"为逻辑复制单独记一份逻辑日志"的方案，PG 选择省写放大、付解码复杂度。

---

## 8. 设计动机

1. **为什么流复制不改 WAL 格式**：WAL 是唯一可信的崩溃恢复边界（卷一 03 章）。让 standby 重放完全复用 `ApplyWalRecord`（xlogrecovery.c:1897）同一条代码路径，恢复正确性与复制正确性互为验证，零格式漂移成本。发送端唯一的纪律是"只发已 fsync 的 WAL"（walsender.c:3489）。
2. **为什么同步复制挂在 XLogFlush 之后**：等远端的先决条件是本地已落盘——否则崩溃后可能既没远端副本也没本地日志。`SyncRepWaitForLSN` 只在 commit 路径工作（非 commit 的 LSN 等待被钳到 flush 档，syncrep.c:184-188），且等待不可被"取消"成回滚（syncrep.c:290-299），维护了"确认过的提交绝不消失"这一承诺。
3. **为什么槽是对象而不是内存标记**：消费进度必须在主库崩溃后幸存——否则重启后 WAL 已按旧下界回收，订阅者永远追不上。所以锚点落在共享内存+定期落盘（ReplicationSlotMarkDirty/Save），并与 checkpoint 的回收计算（slot.c:1306/1224）和失效机制（slot.c:2218）联动，形成"进度→保护→超限自愈"闭环。
4. **为什么逻辑解码必须有 reorderbuffer**：提交序 ≠ WAL 序（长事务）；可见性判断又需要事务粒度的快照（snapbuild）。两者都要求"凑齐一个事务再输出"，内存有限则 spill/stream 兜底（reorderbuffer.c:3928-4023）。这本质是用读时重排换掉写时双日志（对照 7 的 MySQL）。
5. **为什么 hot_standby_feedback 是消息而不是配置**：xmin 保护必须由**数据持有方**（standby 的读查询）动态上报，primary 被动记下限——与槽的 catalog_xmin 共用一条 `'h'` 通道（walreceiver.c:1337-1371 → walsender.c:2653），主从两套 vacuum 界限就此打通。

---

## 9. FAQ 素材（8-10 条）

1. **Q: standby 重放用的代码和崩溃恢复一样吗？** A: 是，同一 `ApplyWalRecord`（xlogrecovery.c:1897）；区别只在 WAL 来源（archive/stream）与 minRecoveryPoint 语义（xlogrecovery.c:270-304）。
2. **Q: walsender 什么时候从 catchup 变 streaming？** A: 输出缓冲清空且已追上 flush 点的那一刻（walsender.c:3124-3140）；这对同步复制是硬分界（STREAMING 才放行等待者，syncrep.c:502-505）。
3. **Q: 为什么 standby 磁盘上没写完的 WAL 不能直接给读服务用？** A: 读服务要等 reachedConsistency（xlogrecovery.c:290-304），且 hot standby 的 xmin 保护依赖 `'h'` 反馈链路建立。
4. **Q: 同步复制下 primary 会被 standby 拖死吗？** A: 优先级模式会（全部同步 standby 掉线则 commit 挂起，syncrep.c:341 无超时）；quorum `ANY n` 容忍 n-1 台故障（syncrep_gram.y:70，水位取第 n 新值 syncrep.c:702-729）。
5. **Q: 槽会不会让 pg_wal 无限增长？** A: 会膨胀到 `max_slot_wal_keep_size_mb` 闸门处，然后槽被 invalidate（xlog.c:8571-8583 → slot.c:2218），订阅者需重建。
6. **Q: confirmed_flush 可以倒退吗？** A: 不能，代码显式防倒退（logical.c:1930-1931），防止客户端迟到 ack 导致重复数据。
7. **Q: 为什么逻辑槽建槽要等一段时间？** A: 在等 snapbuild 状态机走完（等启动时正在运行的事务终结，snapbuild.c:1340-1373）；如果 primary 此刻无运行事务则瞬间完成（snapbuild.c:1300-1323）。
8. **Q: 大事务会撑爆解码内存吗？** A: 不会，超过 logical_decoding_work_mem 就挑最大事务 spill 到磁盘或流式发出（reorderbuffer.c:3928-4023）。
9. **Q: 订阅端的 flush 反馈为什么不能立刻上报收到的 LSN？** A: 必须等事务本地 apply 完（get_flush_position，worker.c:4369）；端到端同步复制正是依赖这个语义（worker.c:4375-4376 注释）。
10. **Q: 时间线（timeline）在协议里怎么体现？** A: START_REPLICATION 带 TLI，历史 timeline 流到分叉点自动 CopyDone 并返回下一 TLI（walsender.c:3532-3548, 1042-1078），standby 据此换时间线重连。

## 深挖方向（3-5 条）

1. **snapbuild 的 catalog 变更追踪**：`SnapBuildCommitTxn` 如何标记"碰过 catalog 的事务"并影响 catalog_xmin（snapbuild.c:649-657 附近）；与 SLRU（卷一 04 章）的 clog 依赖。
2. **流式（streaming）事务的并行 apply 一致性**：leader/parallel worker 的锁与 flush 位点协商（applyparallelworker.c:218-255，worker.c:2431）。
3. **槽的崩溃恢复语义**：`candidate_restart_lsn/candidate_restart_valid` 两阶段推进为何必须"先落盘再生效"（logical.c:1919-1949 注释）。
4. **two-phase 逻辑复制**：`FilterPrepare`/`ReorderBufferFinishPrepared`（decode.c:250-252, 746-751）与 `two_phase_at` 的槽持久化（logical.c:677-686）。
5. **复制槽故障切换（failover slots）**：slotsync.c 在 standby 上同步槽，以及 `synced` 槽禁用解码的限制（logical.c:618-624）。

---

## 10. 写作要点速查表（函数:行号）

| # | 内容 | 位置 |
|---|---|---|
| 1 | `WalSndLoop` 主循环；CATCHUP→STREAMING | src/backend/replication/walsender.c:3071；切换 3134-3139 |
| 2 | `StartReplication`（物理）：置 CATCHUP/CopyBoth/主循环 | walsender.c:860；991；994-998；1025 |
| 3 | `StartLogicalReplication`：槽+解码上下文+主循环 | walsender.c:1532；1542；1563；1601 |
| 4 | `XLogSendPhysical`：只发已 flush WAL、MAX_SEND_SIZE 页边界 | walsender.c:3385；3489；3558-3587 |
| 5 | `XLogSendLogical` / `WalSndWaitForWal`（逻辑侧等 WAL） | walsender.c:3695；1926 |
| 6 | keepalive：半个超时即 ping | walsender.c:4443；4466；4485-4489 |
| 7 | `ProcessStandbyReplyMessage`：三指针→共享内存/同步放行/槽推进 | walsender.c:2545；2619-2634；2637；2642-2648 |
| 8 | 复制协议消息常量 'w'/'k'/'r'/'h' | src/include/libpq/protocol.h:75-84 |
| 9 | `XLogWalRcvWrite/Flush`：落盘+fsync+唤醒+反馈 | src/backend/replication/walreceiver.c:992；1093 |
| 10 | `XLogWalRcvSendReply/SendHSFeedback` | walreceiver.c:1216；1289 |
| 11 | minRecoveryPoint/reachedConsistency | src/backend/access/transam/xlogrecovery.c:283；290-304 |
| 12 | `ApplyWalRecord` / `UpdateMinRecoveryPoint` | xlogrecovery.c:1897；src/backend/access/transam/xlog.c:2759 |
| 13 | `SyncRepWaitForLSN`：入队/等待/不可回滚语义 | src/backend/replication/syncrep.c:149；251-253；341；301-335 |
| 14 | `SyncRepQueueInsert`（LSN 有序）/`SyncRepReleaseWaiters` | syncrep.c:382；484 |
| 15 | 优先级取最老 vs quorum 取第 n 新 | syncrep.c:649-659；669；702（语法 syncrep_gram.y:68-71） |
| 16 | 槽锚点：`ReplicationSlotReserveWal`/ComputeRequiredLSN/Xmin | src/backend/replication/slot.c:1709（物理 1751/逻辑 1755）；1306；1224 |
| 17 | 槽失效五因与执行器 | slot.c:116-120；2218；单槽 1978；调用点 xlog.c:7909/8382/9280 |
| 18 | 逻辑槽双锚推进：confirmed_flush 只进不退 | src/backend/replication/logical/logical.c:1826；1902；1930-1931 |
| 19 | `DecodingContextFindStartpoint`（建槽找起点） | logical.c:713；745-749 |
| 20 | snapbuild 状态机 `SnapBuildFindSnapshot` | src/backend/replication/logical/snapbuild.c:1244；四路 1300/1330/1350/1384/1408 |
| 21 | reorderbuffer：ProcessTXN/内存上限/spill/stream | src/backend/replication/logical/reorderbuffer.c:2214；3928；4029；4374 |
| 22 | apply 侧：`LogicalRepApplyLoop`/`send_feedback` | src/backend/replication/logical/worker.c:4029；4345（flush 语义 4369-4376） |
| 23 | timeline：读历史/分叉点 | src/backend/access/transam/timeline.c:77；573 |
| 24 | base backup 入口 | walsender.c:2253-2257 → src/backend/backup/basebackup.c:997 |
