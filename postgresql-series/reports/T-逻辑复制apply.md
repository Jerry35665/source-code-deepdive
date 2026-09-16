# PostgreSQL 逻辑复制：订阅端 Apply Worker 深读

> 源码版本：PostgreSQL master，commit `8c7a74c`（shallow clone）。
> 所有行号均以该 commit 实际 grep/Read 核对。文件路径均相对源码根目录。

---

## 1. 全景：逻辑复制完整链路

```
 发布端 (publisher)                                订阅端 (subscriber)
┌─────────────────────────────────────┐        ┌──────────────────────────────────────────┐
│ 后端进程: INSERT/UPDATE/DELETE       │        │ apply launcher (常驻 BGW)                 │
│        │ 写 WAL                     │        │   launcher.c:1207 ApplyLauncherMain       │
│        ▼                            │        │   launcher.c:336  logicalrep_worker_launch│
│ WAL (含 heap 元组级变更)             │        │        │ fork                             │
│        │                            │        │        ▼                                  │
│ walsender 进程                       │        │ apply worker (独立进程)                    │
│   walsender.c:1532                   │  libpq │   worker.c:6081 ApplyWorkerMain           │
│     StartLogicalReplication          │◄───────│   worker.c:5761 walrcv_connect            │
│   walsender.c:3695 XLogSendLogical   │  协议   │   worker.c:4029 LogicalRepApplyLoop       │
│        │ 逻辑解码                    │ START_ │        │ 收到 PqReplMsg_WALData           │
│        ▼                            │ REPLICATION│    ▼                                 │
│ reorderbuffer 组装事务/子事务        │ + 反馈  │   worker.c:3822 apply_dispatch            │
│   (logical/reorderbuffer.c)          │ send_  │        │ 按消息类型分发                    │
│        ▼                            │ feedback│       ├─ B/C  : begin/commit (spool 模式)  │
│ 输出插件 pgoutput (内置)             │(worker │       ├─ I/U/D: 行变更 → 本地执行器         │
│   pgoutput.c:261                     │ .c:4345)│      ├─ S/E/c/A: 流式大事务                  │
│   :597 begin :633 commit :1485 change│        │       └─ 'p'/'P': 两阶段 prepare 系列       │
│        ▼                            │        │        ▼                                  │
│ LOGICALREP 协议消息 (B/C/I/U/D/...)  │        │ 本地写入: ExecSimpleRelationInsert/        │
│   logicalproto.h:59-77 消息类型      │        │   Update/Delete (executor) 伪装成          │
└─────────────────────────────────────┘        │   session_replication_role=replica 的 DML  │
        初始同步另有 tablesync worker:          │   worker.c:5852 设 replica 角色            │
        COPY 全量 + 独立临时 slot               └──────────────────────────────────────────┘
```

要点：

- **两端复用同一套流复制传输底座**：订阅端 apply worker 与物理 walreceiver 共享 `libpqwalreceiver` 模块（worker.c:18-19 文件头注明 "shares libpqwalreceiver module with walreceiver"），walsender 侧 `START_REPLICATION` 也分物理/逻辑两个分支。
- **发布端解码链**：`XLogSendLogical`（walsender.c:3695）驱动 `LogicalDecodingProcessRecord` → decode.c 逐记录回调 reorderbuffer → 事务提交时按 commit 顺序输出；`CreateDecodingContext`（logical.c:577）负责 slot/快照/一致性点。物理复制完全跳过这条链，直接读 WAL 页面。
- **语义差异**：物理复制传"这个磁盘块改了哪些字节"；逻辑复制经 reorderbuffer 还原成"哪张表、哪一行、插入/更新/删除"，由订阅端用执行器重新执行（worker.c:2782/3017/3198），因此**DDL、序列值、大对象都不在复制范围内**——订阅端只会收到 RELATION/TYPE 消息用于维护"远端 schema 映射缓存"（worker.c:2603-2616 `apply_handle_relation` 只调 `logicalrep_relmap_update`，注释明确"我们不在这里对本地 schema 做校验"）。
- **协议按版本协商**：`set_stream_options` 依服务器版本选择协议 v1-v4（worker.c:5624-5628；常量定义 logicalproto.h:41-45），v2=流式、v3=两阶段、v4=并行流式。
- **反馈协议同构**：逻辑 apply worker 的 `send_feedback`（worker.c:4345）与物理 walreceiver 的 write/flush/apply 汇报格式一致，区别只在"flush 位点"的换算方式——逻辑侧必须查 (remote→local) LSN 映射（见 2.2）。

```c
/* worker.c:5624-5628 协议版本协商 */
options->proto.logical.proto_version =
    server_version >= 160000 ? LOGICALREP_PROTO_STREAM_PARALLEL_VERSION_NUM :
    server_version >= 150000 ? LOGICALREP_PROTO_TWOPHASE_VERSION_NUM :
    server_version >= 140000 ? LOGICALREP_PROTO_STREAM_VERSION_NUM :
    LOGICALREP_PROTO_VERSION_NUM;
```

---

## 2. Apply Worker 专节

### 2.1 进程生命周期与入口

| 阶段 | 位置 |
|---|---|
| launcher 常驻后台进程，扫描 pg_subscription 并拉起 worker | launcher.c:1207 `ApplyLauncherMain`，launcher.c:336 `logicalrep_worker_launch` |
| worker 数量上限 GUC：max_logical_replication_workers=4 / max_sync_workers_per_subscription=2 / max_parallel_apply_workers_per_subscription=2 | launcher.c:54-56 |
| worker 主入口 | worker.c:6081 `ApplyWorkerMain` → `SetupApplyOrSyncWorker` → `run_apply_worker` |
| 会话初始化：设为 replica 角色防触发规则触发器、锁死 search_path、强制可写 | worker.c:5849-5873 `InitializeLogRepWorker` |
| 复制源（origin）建立：origin 名 `pg_<suboid>`，崩溃后从 origin 进度续传 | worker.c:659-672 `ReplicationOriginNameForLogicalRep`；worker.c:5746-5755 `run_apply_worker` 内 `replorigin_session_setup` |
| 主循环 | worker.c:4029 `LogicalRepApplyLoop`：收 WAL 数据→`apply_dispatch`（worker.c:4141）；keepalive→`send_feedback`（worker.c:4158）；空闲时 `ProcessSyncingRelations`（worker.c:4215，定义于 syncutils.c:156） |
| 出错恢复 | worker.c:5681-5714 `start_apply` 的 PG_CATCH：先 `replorigin_xact_clear(true)` 防止 origin 被推进导致事务丢失（worker.c:5690-5696）；`disableonerr` 则 `DisableSubscriptionAndExit`（worker.c:6100-6153），否则 worker 退出后由 launcher 按重试节奏重启 |

### 2.2 事务边界分发：apply_dispatch

`apply_dispatch`（worker.c:3822-3927）是唯一的协议消息路由器，读第一个字节按 `LOGICAL_REP_MSG_*` 分发。事务边界消息配对关系：

```c
/* worker.c:3836-3856（节选） */
switch (action)
{
    case LOGICAL_REP_MSG_BEGIN:    apply_handle_begin(s);    break;
    case LOGICAL_REP_MSG_COMMIT:   apply_handle_commit(s);   break;
    case LOGICAL_REP_MSG_INSERT:   apply_handle_insert(s);   break;
    case LOGICAL_REP_MSG_UPDATE:   apply_handle_update(s);   break;
    case LOGICAL_REP_MSG_DELETE:   apply_handle_delete(s);   break;
    ...
}
```

消息类型字符常量定义于 logicalproto.h:59-77（'B'/'C'/'I'/'U'/'D'/'S'/'E'/'c'/'A' 等）。注意 apply worker 收到的是"扁平消息流"：BEGIN...n 条变更...COMMIT 由解码端保证按事务边界投递；订阅端的本地事务在第一条变更 apply 时才由 `begin_replication_step` 开启（worker.c:744-758，含 `maybe_reread_subscription`），每条变更结束 `end_replication_step` 推进命令计数（worker.c:767-773），整组变更在一个本地事务内提交。

- **BEGIN(worker.c:1248) / COMMIT(worker.c:1271)**：非流式常规事务。BEGIN 记录 remote_xid/final_lsn 并置 `in_remote_transaction=true`（worker.c:1256-1260）；COMMIT 校验 `commit_lsn == remote_ctx.finish_lsn`（worker.c:1277-1282）后调 `apply_handle_commit_internal`。
- `apply_handle_commit_internal`（worker.c:2543-2593）：跳过模式则停跳；`CommitTransactionCommand` 提交本地事务；把 origin 的 xact state 记为 end_lsn（worker.c:2570-2571，崩溃重启的位置基准）；`store_flush_position` 把 (远端 LSN→本地 LSN) 存入映射表（worker.c:2583，定义 3987），供 `get_flush_position`（worker.c:3942）在 `send_feedback` 时换算可安全汇报的 flush 点——**汇报的必须是真的已在本地落盘的位置**（worker.c:3930-3937 注释）。
- **两阶段族**：`apply_handle_begin_prepare`(worker.c:1300)/`apply_handle_prepare`(1364)/`apply_handle_commit_prepared`(1438)/`apply_handle_rollback_prepared`(1489)/`apply_handle_stream_prepare`(1551)。本地 GID 被改写为 `pg_<suboid>_<xid>`（worker.c:1337 `TwoPhaseTransactionGid`），避免多个订阅指向同一发布端时 GID 撞名死锁。
- **流式族**：STREAM START/STOP/ABORT/COMMIT（worker.c:3883-3897 分发）。

### 2.3 Spool vs Stream：切换条件

订阅端 `streaming` 选项决定大事务（发布端超出内存阈值、reorderbuffer 开始流式输出的事务）怎么 apply。三种模式的判定集中在 `get_transaction_apply_action`（worker.c:6488-6529）：

```
am_parallel_apply_worker()              → TRANS_PARALLEL_APPLY        (我是并行 worker)
pa_find_worker(xid) && serialize_changes→ TRANS_LEADER_PARTIAL_SERIALIZE(发不动了,降级写文件)
pa_find_worker(xid)                     → TRANS_LEADER_SEND_TO_PARALLEL(发给并行 worker)
in_streamed_transaction                 → TRANS_LEADER_SERIALIZE      (spool 模式)
否则                                     → TRANS_LEADER_APPLY          (常规即时 apply)
```

即五态枚举 `TransApplyAction`（worker.c:385-395）：

```c
/* worker.c:385-395 */
typedef enum
{
    /* The action for non-streaming transactions. */
    TRANS_LEADER_APPLY,

    /* Actions for streaming transactions. */
    TRANS_LEADER_SERIALIZE,
    TRANS_LEADER_SEND_TO_PARALLEL,
    TRANS_LEADER_PARTIAL_SERIALIZE,
    TRANS_PARALLEL_APPLY,
} TransApplyAction;
```

1. **TRANS_LEADER_APPLY**（worker.c:388）：非流式事务，leader（或 tablesync worker）直接 apply；
2. **TRANS_LEADER_SERIALIZE**（worker.c:391）：`streaming=on`，收到 STREAM START 后把变更写入临时 BufFile（按 toplevel xid+subid 命名，worker.c:37-40 注释），STREAM COMMIT 到达时 `apply_spooled_messages`（worker.c:2459，定义 2303）统一回放——**先收集后统一 apply**；
3. **TRANS_LEADER_SEND_TO_PARALLEL**（worker.c:392）：`streaming=parallel`，leader 通过 shm_mq 把消息原样转发给并行 worker（worker.c:851 `pa_send_data`）；
4. **TRANS_LEADER_PARTIAL_SERIALIZE**（worker.c:393）：并行 worker 忙/队列满，`pa_switch_to_partial_serialize`（applyparallelworker.c:1231）降级：leader 继续把剩余变更写文件，commit 时由并行 worker 消费（worker.c:2487-2497，文件状态机 FS_EMPTY→FS_SERIALIZE_IN_PROGRESS→FS_SERIALIZE_DONE→FS_READY 见 worker_internal.h:142-148）；
5. **TRANS_PARALLEL_APPLY**（worker.c:394）：并行 worker 自己 apply，收到消息时按 xid 判断是否给子事务建 SAVEPOINT（worker.c:869-874 `pa_start_subtrans`）。

流式事务的终点在 `apply_handle_stream_commit`（worker.c:2430-2538）：spool 模式回放文件后走同一个 `apply_handle_commit_internal`（worker.c:2462）；并行模式 leader 调 `pa_xact_finish` 等并行 worker 完成（worker.c:2476/2496），**保证提交顺序**；并行 worker 侧提交后置 `PARALLEL_TRANS_FINISHED` 并释放事务锁（worker.c:2510-2517）。中途中止走 `apply_handle_stream_abort`（worker.c:2107），spool 模式靠子事务文件偏移截断回滚已写内容（worker.c:32-35 注释）。

### 2.4 并行 apply 的另一组"五态"

`ParallelTransState`（worker_internal.h:119-124）：UNKNOWN → STARTED → FINISHED，配合 `PartialFileSetState` 四态（worker_internal.h:142-148）。关键约束：

- 并行 worker 只在所有表 READY 后才参与（`should_apply_changes_for_rel` worker.c:707-717 直接 ERROR 拦截）；
- worker 池复用，上限一半留池、超出即退出（applyparallelworker.c:33-41、583）；
- **死锁检测是设计核心**：LA（leader）与 PA（parallel）之间用 lmgr 锁制造等待边，使"PA 等 LA 的下一段流、LA 等 PA 提交"能被死锁检测器看见（applyparallelworker.c:60-116 的 Locking Considerations 注释）；错误经独立 shm_mq 错误队列回传（applyparallelworker.c:326、387-394，PA 侧 `pq_redirect_to_shm_mq` 重定向 elog 输出，applyparallelworker.c:955）。

---

## 3. 冲突专节：类型与解决策略

### 3.1 八种冲突类型

`ConflictType`（src/include/replication/conflict.h:31-62）：

| 类型 | 含义 | 检测点 |
|---|---|---|
| CT_INSERT_EXISTS | 插入违反唯一约束 | execReplication.c:882（插入后才查索引，避免每条 INSERT 额外扫描，execReplication.c:866-874 注释） |
| CT_UPDATE_ORIGIN_DIFFERS | 目标行被其他 origin 改过 | worker.c:2989-3003 |
| CT_UPDATE_EXISTS | 新值违反唯一约束 | execReplication.c:976 |
| CT_UPDATE_DELETED | 行刚被其他 origin 删除 | worker.c:3029-3034（`FindDeletedTupleInLocalRel`） |
| CT_UPDATE_MISSING | 要更新的行不存在 | worker.c:3036 |
| CT_DELETE_ORIGIN_DIFFERS | 要删的行被其他 origin 改过 | worker.c:3184-3192 |
| CT_DELETE_MISSING | 要删的行不存在 | worker.c:3206 |
| CT_MULTIPLE_UNIQUE_CONFLICTS | 同时违反多个唯一索引 | conflict.h:54-55 |

### 3.2 解决策略：没有自动仲裁

- **UPDATE/DELETE 找不到行：只记 LOG，不报错、不中断**（worker.c:3040-3046 注释 "Do nothing except for emitting a log message"；worker.c:3200-3208）——"last-write-wins"事实上等于"远端改不动本地"。
- **INSERT 唯一冲突：直接 ERROR**（经 `ReportApplyConflict` 以错误级别 ereport，conflict.c:298-304，SQLSTATE 为 unique_violation，conflict.c:346-349），apply worker 回滚、退出、launcher 重启后**从 origin 位置重放同一事务**——冲突不解开就无限循环。
- **UPDATE/DELETE 的 origin-differs 是"软冲突"**：报 LOG 后**照常执行**远端变更（worker.c:3006-3018 先报冲突再 ExecSimpleRelationUpdate）——因为订阅端最终以发布端为准，只是把"本地行被别的来源动过"这件事告知用户。

```c
/* worker.c:3029-3036 UPDATE 缺行：区分"刚被删"还是"从来没有" */
if (FindDeletedTupleInLocalRel(localrel, localindexoid, remoteslot,
                               &conflicttuple.xmin,
                               &conflicttuple.origin,
                               &conflicttuple.ts) &&
    conflicttuple.origin != replorigin_xact_state.origin)
    type = CT_UPDATE_DELETED;
else
    type = CT_UPDATE_MISSING;
```

- **用户侧三件解决工具**：
  1. 手工修数据让重放通过；
  2. `ALTER SUBSCRIPTION ... SKIP (lsn)` 跳过整个事务：`maybe_start_skipping_changes`（worker.c:6177-6199）在 BEGIN 时匹配 `subskiplsn` 置跳过标记，commit 时清掉并更新 pg_subscription（`clear_subscription_skip_lsn` worker.c:6226-6303，LSN 不匹配给 WARNING worker.c:6297-6302）；
  3. PG 18 起冲突可落到 `pg_conflict_log_<subid>` 表（conflict.c:153 建表命名；conflict.h:89-94 三种去向 LOG/TABLE/ALL）+ 统计计数 `pgstat_report_subscription_conflict`（conflict.c:296）。
- **origin 比较是"不同来源"判定的依据**：`GetTupleTransactionInfo` 读本地元组的 xmin/origin/时间戳（worker.c:2989-2991），只有与当前 origin 不同才算 origin-differs 冲突——这也是防止**复制环路**时区分"本地写入"与"远端复制来"的同一套机制。
- 唯一索引作为冲突仲裁器：`InitConflictIndexes` 只收集非延迟唯一索引（conflict.c:311-336）。

---

## 4. Table Sync 专节：同步 worker 的独立生命周期

每张新加入订阅的表由**独立的 tablesync worker** 完成全量初始化（worker 类型枚举 worker_internal.h:30-34，另有 sequencesync worker：sequencesync.c:871 `SequenceSyncWorkerMain`）。表级状态机定义在 pg_subscription_rel.h:66-78：

```
INIT(i) → DATASYNC(d) → FINISHEDCOPY(f) → SYNCWAIT(w) → CATCHUP(c) → SYNCDONE(s) → READY(r)
```

**tablesync worker 侧**（tablesync.c）：

1. 入口读表状态决定从哪续（`LogicalRepSyncTableStart` tablesync.c:1257）；已是 SYNCDONE/READY/UNKNOWN 直接 `FinishSyncWorker` 退出（tablesync.c:1292-1298）；上次死在 COPY 中（DATASYNC）就先删掉发布端可能残留的临时 slot 重来（tablesync.c:1332-1346）；COPY 已完成但 worker 挂了（FINISHEDCOPY）则从 origin 进度跳过 COPY 继续（tablesync.c:1347-1367）。
2. 在发布端开 **REPEATABLE READ 只读事务 + 建带快照的永久逻辑 slot**（`CRS_USE_SNAPSHOT`，tablesync.c:1413-1431）——保证 COPY 快照与 slot 起点一致，COPY 之后的增量由这个 slot 补。
3. `copy_table`（tablesync.c:1075）远程 COPY 到本地；完成后状态置 FINISHEDCOPY 并提交（tablesync.c:1508-1514）。
4. 置 SYNCWAIT（tablesync.c:1525-1528），阻塞等 apply worker 发令进入 CATCHUP（tablesync.c:1534 `wait_for_worker_state_change`）。
5. 切回 apply 循环追增量；追到同步点即 **CATCHUP→SYNCDONE**（`ProcessSyncingTablesForSync` tablesync.c:246-258），随后结束流复制、**删除 tablesync 临时 slot**（tablesync.c:278-297）、清理该表专属 origin（名 `pg_<suboid>_<relid>`，worker.c:662-666；tablesync.c:316-338）、`FinishSyncWorker` 退出。

**apply worker 侧**（`ProcessSyncingTablesForApply` tablesync.c:368）：

```c
/* tablesync.c:494-503 apply worker 把 SYNCWAIT 的 sync worker 推进到 CATCHUP */
if (rstate->state == SUBREL_STATE_SYNCWAIT)
{
    syncworker->relstate = SUBREL_STATE_CATCHUP;
    syncworker->relstate_lsn =
        Max(syncworker->relstate_lsn, current_lsn);
}
```

- 发现 SYNCWAIT 的 sync worker 就把它推进到 CATCHUP（tablesync.c:494-503），然后自己忙等该表变 SYNCDONE（tablesync.c:543-544 `wait_for_table_state_change`）；
- 看到某表 SYNCDONE 且自身 LSN 追上（`current_lsn >= rstate->lsn`），置 **READY** 并清 origin（tablesync.c:426-473，注意 worker.c:470 注释"先清 origin 再置 READY"的顺序保障）——从此该表回到 apply worker 正常复制；
- 同步期间 apply worker 用 `should_apply_changes_for_rel`（worker.c:699-735）跳过尚未 READY 的表，避免与 COPY 双写；两阶段订阅要等**所有表 READY** 才从 PENDING 转 ENABLED（worker.c:5805-5824）。
- 并发上限即 `max_sync_workers_per_subscription=2`（launcher.c:54-55、406）；sync worker 失败按 `wal_retrieve_retry_interval` 节流重启（tablesync.c:353-358 注释）。
- 状态读写用自旋锁 `relmutex` 保护（tablesync.c:248、1283-1286），因为 apply worker 与 tablesync worker 跨进程互查状态。
- 两 worker 之间的握手是典型的"分布式状态机协商"：任何一步崩溃都能从 pg_subscription_rel 持久化状态恢复（DATASYNC/FINISHEDCOPY 两条续传路径，tablesync.c:1332-1367）。

---

## 5. 设计动机

1. **为什么 PG 10 才有内置逻辑复制**：前提是先有逻辑解码基础设施（PG 9.4：slot、reorderbuffer、输出插件 API）。PG 10 在其上加了发布/订阅两层目录化封装（publication/subscription + pgoutput 插件 + apply worker 框架）。此前用户只能靠 Slony/Londiste 等外部触发器方案。输出插件做成接口（`_PG_output_plugin_init` 注册回调表，pgoutput.c:261；内置 pgoutput 只是一个"用户"）使同一套解码内核既服务内置复制、又服务 CDC 工具（test_decoding、wal2json），这是"逻辑"区别于"物理"的接口层价值。
2. **为什么 apply 是独立进程**：(a) 故障隔离——apply 报错只死 worker，PG_CATCH 兜底+launcher 重启（worker.c:5681-5714），服务器不受影响；(b) 事务语义独立——apply worker 在订阅端本地开事务执行 DML，与发布端事务无锁关联；(c) 天然多进程并行——每订阅一个 apply worker、每表一个 tablesync worker、每流式事务可选一个 parallel apply worker，各自独立连接、独立 slot/origin；(d) 复用后端执行器——worker 是完整后端进程，能直接跑 ExecSimpleRelation* 与触发器。
3. **为什么用 origin 而不是简单水位**：origin（pg_replication_origin）让订阅端把"我在远端流里的位置"持久化且可崩溃恢复（worker.c:5746-5755），同时给每条本地写入盖上来源戳，供冲突判定与防环（双向复制时应用侧按 origin 过滤）。
4. **为什么大事务要 spool/并行化**：发布端 reorderbuffer 流式输出让发布端不必攒整个事务，但订阅端 commit 原子性要求"要么全应用要么全不应用"。spool 模式牺牲实时性换原子性；并行模式让长事务提前开跑但 leader 仍按 commit 顺序放行（worker.c:2470-2497 + pa_xact_finish），两全。

---

## 6. FAQ 素材

1. **订阅端表必须有主键吗？** UPDATE/DELETE 需要能定位行：目标表须有 PK/REPLICA IDENTITY，或发布端表为 REPLICA IDENTITY FULL，否则 `check_relation_updatable` 直接 ERROR（worker.c:2789-2823，报错文案在 2816-2822）。
2. **UPDATE/DELETE 找不到行会怎样？** 只记 LOG 不中断（worker.c:3040-3046、3206），统计为 update_missing/delete_missing 冲突。
3. **INSERT 主键冲突会怎样？** ERROR 中止 worker → 重启重放，死循环直到人工解决或 SKIP；`disableonerr=true` 则自动停订（worker.c:5698-5699）。
4. **怎么跳过一个毒事务？** `ALTER SUBSCRIPTION ... SKIP (lsn = '...')`，只对精确 final_lsn 的那个事务生效（worker.c:6189-6190），跳完自动清 skiplsn（worker.c:6279-6295）。
5. **初始同步期间源表能写吗？** 能。COPY 用发布端 REPEATABLE READ 快照+临时 slot（tablesync.c:1413-1431），期间增量由 apply worker 正常推进，之后 CATCHUP 对齐。
6. **DDL 会不会复制？** 不会。订阅端只收到 RELATION/TYPE 消息更新映射缓存（worker.c:2603-2616、2626-2635），schema 变更须用户先在订阅端手工执行——这是逻辑复制最大的运维负担。
7. **序列、触发器呢？** 序列不实时复制（PG 18 才有 sequencesync worker，且只在初始同步阶段对齐，sequencesync.c:871 `SequenceSyncWorkerMain`）；订阅端 apply 以 `session_replication_role=replica` 会话执行（worker.c:5852-5854），replica 角色下普通用户触发器不触发、仅 ENABLE_ALWAYS/ENABLE_INTERNAL 触发器触发，因此 FK 等约束触发器不会在订阅端重复引发。
8. **worker 数量怎么规划？** 每订阅 1 apply + ≤max_sync_workers_per_subscription(2) tablesync + ≤max_parallel_apply_workers_per_subscription(2) 并行 apply，共享 max_logical_replication_workers(4) 池（launcher.c:54-56）。
9. **apply worker 崩溃会不会丢数据？** 不会丢但可能重复：flush 汇报只认本地已落盘位置（worker.c:3930-3937），出错时回滚 origin 防止"谎报进度"导致事务永久跳过（worker.c:5690-5696）。
10. **冲突去哪看？** 服务器日志 / pg_conflict_log 表（conflict.h:89-94、conflict.c:153），及 `pg_stat_subscription_stats` 的冲突计数（conflict.c:296）。

## 深挖方向

1. **LA/PA 死锁检测协议**：applyparallelworker.c:60-116 完整推演了两种死锁场景及 stream lock 的加解锁时序——适合做"并行复制为什么会死锁、PG 如何让它可被检测"专题。
2. **PARTIAL_SERIALIZE 降级路径**：发送失败即降级（worker.c:842-867、1842-1864），文件四态机（worker_internal.h:142-148）+ `pa_switch_to_partial_serialize`（applyparallelworker.c:1231）——一条典型的"乐观并行、悲观回退"工程路径。
3. **flush 位置换算与崩溃一致性**：`get_flush_position`（worker.c:3942）维护 (remote_lsn, local_lsn) 链表，只汇报本地已 fsync 的远端位置；对照物理复制 walreceiver 的反馈机制看同构性。
4. **RDT（retain dead tuples，PG 18）**：为保留冲突元组信息，apply worker 六阶段推进 oldest_nonremovable_xid（worker.c:403-449 枚举、4143/4166-4182 调用点）——vacuum 冻结与复制冲突保留的交互。
5. **两阶段 GID 改写**：`TwoPhaseTransactionGid`（worker.c:1337）规避多订阅共享发布端时的 GID 冲突死锁——分布式 2PC 命名空间设计案例。

---

## 写作要点速查表

| # | 论断 | 证据位置 |
|---|---|---|
| 1 | 消息路由唯一入口，17 种消息类型 | worker.c:3822-3927 |
| 2 | BEGIN/COMMIT 配对；commit_lsn 必须等于 begin 报的 finish_lsn | worker.c:1248、1271、1277-1282 |
| 3 | 提交公共路径：先记 origin 进度再提交，store_flush_position 存映射 | worker.c:2543-2593（2570-2583） |
| 4 | apply 主循环：WALData→dispatch；空闲时做表同步推进 | worker.c:4029（4141、4215） |
| 5 | flush 汇报只认本地已落盘位置 | worker.c:3930-3947 |
| 6 | 流式五态枚举 TransApplyAction | worker.c:385-395；判定 worker.c:6488-6529 |
| 7 | spool 模式：STREAM START 开临时文件，COMMIT 时回放 | worker.c:1719-1752、2459、2303 |
| 8 | 并行模式：shm_mq 转发，commit 按 leader 放行保序 | worker.c:2470-2497；applyparallelworker.c:53-58 |
| 9 | 冲突八类型枚举 + SQLSTATE 映射 | conflict.h:31-62；conflict.c:341-360 |
| 10 | UPDATE/DELETE 缺行只 LOG；INSERT 撞唯一约束是 ERROR | worker.c:3040-3046、3206；execReplication.c:882 |
| 11 | SKIP 事务机制（subskiplsn） | worker.c:6177-6199、6226-6303 |
| 12 | 表状态机 i→d→f→w→c→s→r | pg_subscription_rel.h:66-78 |
| 13 | tablesync：RR 事务+CRS_USE_SNAPSHOT slot 保 COPY 与增量一致 | tablesync.c:1413-1431 |
| 14 | SYNCWAIT→CATCHUP 由 apply worker 推进，SYNCDONE→READY 也由它置位 | tablesync.c:494-503、426-473 |
| 15 | worker 上限三 GUC | launcher.c:54-56 |
| 16 | 协议版本 v1-v4 协商 | worker.c:5624-5628；logicalproto.h:41-45 |
| 17 | origin 命名 pg_<suboid>[_<relid>]，防环+崩溃续传 | worker.c:659-672、5746-5755 |
| 18 | 两阶段三态 PENDING→ENABLED 需全表 READY | worker.c:5805-5824；文件头注释 79-99 |
