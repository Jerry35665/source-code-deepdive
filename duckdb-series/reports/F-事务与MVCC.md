# F. 事务与 MVCC：单写者多读者的快照实现

> 系列《DuckDB 深读》报告 F。基线 commit `7e886f44428e90c8379d4d34e2afb866108ff079`。
> 所有 `文件:行号` 均在该基线上逐一核对。WAL 记录格式与 checkpoint 块布局只在入口级提及，卷二展开。

DuckDB 的事务实现可以浓缩成一句话：**时间戳是版本号，快照是一个区间，undo 是变更日志，提交是给变更打上时间戳**。读路径上没有"回滚段"，也没有 xmin/xmax 组合——每行只携带插入者/删除者的 id，一次 64 位比较完成可见性判定。

---

## 0. 两张图看懂全貌

### 0.1 并发事务下的可见性判定

```
        全局单调计数器（start_ts 与 commit_ts 同源，duck_transaction_manager.cpp:283-285）
 ts ─────────────────────────────────────────────────────────────────────────────►
      40        45                         60
      │         │                          │
      │      T1 BEGIN(读者)              T2 COMMIT(写者)
      │      start_time = 45               │
      │      view.bound = Before(45)       │  ① WriteToWAL：本地 append 合入主表 +
      │      只能看见 ts < 45 的版本         │     undo 缓冲逐条写 WAL 记录
      │                                    │  ② GetCommitTimestamp() → commit_id = 60
   T2 BEGIN(start=40)                      │  ③ UndoBuffer::Commit：undo 条目里的版本号
      (写者, 版本先标 tid=2^62+idx,          │     由 tid 改写成 60 → 对外可见
       未提交不可见)                        │  ④ FlushCommit：写 WAL flush marker，
      │                                    │     有他人事务则只记录 wal_sync_offset
      │                                    │  ⑤ SyncUpTo fsync 后才离开 active 集合
      │
      ▼  T1 扫描某行时的判定（transaction_data.hpp:34-36）
         visible ⇔ insert_id < 45 ∨ insert_id == 自己tid   （且删除者不满足同一条件）
         T2 写的行：60 ≥ 45 且 tid ≠ T1 → 不可见 → T1 读到快照旧行
```

要点：写者提交**不需要等待读者**——T1 的 bound 定格在 BEGIN 时刻，T2 之后的任何 commit_ts 都落在 bound 右侧；反过来，若 T2 先提交（commit_id=44 < 45），T1 立即可见。

### 0.2 commit 全链时序（src/transaction/duck_transaction_manager.cpp:341-571）

```
ClientContext::EndQueryInternal（autocommit 时自动提交, client_context.cpp:357-362）
 └─ TransactionContext::Commit (transaction_context.cpp:62-90)
     └─ MetaTransaction::Commit：逆序逐个 attached db 提交 (meta_transaction.cpp:119-165)
         └─ DuckTransactionManager::CommitTransaction
             1  PreFlushOptimisticBlocks：大 append 的块先落盘并 fsync（不持锁阶段）:344
             2  写事务取 WAL 锁（提交写日志全局串行的第一个点）        :387-389
             3  WriteToWAL：
                  LocalStorage::Commit —— 本地 append 合入主表/PushAppend :241
                  UndoBuffer::WriteToWAL —— catalog/DELETE/UPDATE/SEQ  :245
             4  重取 transaction_lock → GetCommitTimestamp() → commit_id :398,425
             5  DuckTransaction::Commit → UndoBuffer::Commit：逐条把版本号
                从 tid 改成 commit_id（此瞬起对外可见）                  :434
             6  FlushCommit：无他事务→就地 fsync；否则只写 flush marker    :293-299
                失败 → RevertCommit 回打 tid + WAL 截断                 :309-318
             7  last_commit = commit_id                                 :452
             8  SyncUpTo(wal_sync_offset)：组提交 fsync；成功后推进
                durable_bound 并把事务移出 active 集合                   :498-532
             9  （若可）auto-checkpoint：需排他 checkpoint 锁             :548-568
```

顺序的关键：**先写 WAL、后打 commit_ts、再 fsync**。任何被读者看到的 commit_id 版本，其 WAL 记录必然已写入（fsync 可滞后，但崩溃恢复靠 WAL 重放补齐）。

---

## 1. 事务对象：三层结构

客户端一侧是 `TransactionContext`（每连接一个）持有 `MetaTransaction`（每 SQL 事务一个），后者按 attached database 分发 `DuckTransaction`（每库一个真正带 MVCC 状态的对象）。

- `TransactionContext::BeginTransaction` 取墙钟 `start_timestamp` 与全局 `global_transaction_id`（`src/transaction/transaction_context.cpp:36-48`；全局 id 来自 `DatabaseManager::GetNewTransactionNumber`，`src/include/duckdb/main/database_manager.hpp:97-99`）。
- `MetaTransaction::GetTransaction` 在首次触达某库时才调用该库的 `TransactionManager::StartTransaction` 惰性建事务（`src/transaction/meta_transaction.cpp:60-86`）。每个 `AttachedDatabase` 自带一个 `DuckTransactionManager`（`src/main/attached_database.cpp:134`）。
- `DuckTransaction` 持有 MVCC 三元组：`start_time`（快照起点）、`view`（SnapshotView）、`commit_id`（成功提交后非零），外加 `wal_sync_offset`（提交已发布但未 durable 的 WAL 偏移）与 `catalog_version`（`src/include/duckdb/transaction/duck_transaction.hpp:44-56`）。
- 事务私有的两部分写状态：`UndoBuffer`（undo 条目链）与 `LocalStorage`（未提交 append），见 `duck_transaction.hpp:118-122` 与构造函数 `src/transaction/duck_transaction.cpp:38-44`。

```cpp
// src/transaction/duck_transaction_manager.cpp:92-99
transaction_t start_time = current_start_timestamp++;
transaction_t transaction_id = current_transaction_id++;
// snapshots must not observe commits that are not yet durable, nor a newer catalog version
auto durable = GetDurableSnapshot();
// the transaction sees its own writes, and every durable commit before its start time
SnapshotView view(transaction_id,
                  VisibilityBound::Min(VisibilityBound::Before(start_time), durable.visibility_bound));
auto catalog_version = MinValue<idx_t>(last_committed_version, durable.catalog_version);
```

基础类 `Transaction` 只剩 `active_query` 和 `is_read_only`（`src/transaction/transaction.cpp:8-26`）；没有自身 MVCC 状态的事务（如 system catalog）默认"看穿一切"，`GetSnapshotView` 返回含未提交的无限 bound（`src/include/duckdb/transaction/transaction.hpp:68-71`）。

## 2. 时间戳分配：同一个计数器，两段 id 空间

- **谁发 start_ts**：`DuckTransactionManager::StartTransaction`，在 `transaction_lock` 下 `current_start_timestamp++`（`duck_transaction_manager.cpp:85-93`）。
- **谁发 commit_ts**：同管理器的 `GetCommitTimestamp()`，**同一个计数器**再 `++`（`duck_transaction_manager.cpp:283-285`）。因此 commit_ts 一定大于所有已开始的 start_ts，"提交序"与"快照序"天然全序。
- **id 空间分离**：transaction id 从 `TRANSACTION_ID_START = 2^62` 起跳，而合法 commit id 上限是 `MAX_COMMIT_ID = 2^62 - 1`（`src/include/duckdb/common/constants.cpp:18-22`）。于是 `IsCommitted(t) = t <= MAX_COMMIT_ID` 一眼分辨版本是提交时间戳还是未提交事务 id（`src/include/duckdb/transaction/transaction_data.hpp:18-20`）。
- 单调计数器耗尽直接 InternalException（`duck_transaction_manager.cpp:86-89`）。

可见性判据本身只有一行：

```cpp
// src/include/duckdb/transaction/transaction_data.hpp:33-37
//! Below the bound, or written by this transaction
bool Sees(transaction_t timestamp) const {
    return timestamp < visibility_bound || timestamp == transaction_id;
}
```

`VisibilityBound` 是强类型独占上界，只允许 `<`/`>=` 比较，防止把 bound 与普通时间戳混用（`src/include/duckdb/common/constants.hpp:67-98`）。

### 2.1 与 PostgreSQL 的概念对照

| 概念 | PostgreSQL | DuckDB |
|---|---|---|
| 快照 | xmin/xmax/xip_list 集合 | `SnapshotView{transaction_id, visibility_bound}` 一个区间 |
| 行版本存放 | 旧版本留在堆内（回滚段式清理由 vacuum 负责） | 新值在 undo 链，旧值留在 base 段 |
| 提交状态 | 提交位图 clog | 版本号本身：`id <= 2^62-1` 即已提交（`transaction_data.hpp:18-20`） |
| 冲突处理 | 行级锁等待 | 乐观检测，冲突即异常 |
| 提交序 | commit 序号 + WAL | 同一计数器发出的 commit_id（`duck_transaction_manager.cpp:283-285`） |
| 历史清理 | autovacuum | `lowest_visibility_bound` 驱动的清理队列（`duck_transaction_manager.cpp:655-697`） |

## 3. "单写者"的准确含义与冲突检测

DuckDB 并非字面意义的同时只允许一个写事务；它采用**乐观并发 + 提交串行化**：

1. **第二个写事务开始时既不失败也不等待**——BEGIN 永远成功。冲突在两个时刻爆发：
   - **写操作时刻**：UPDATE 沿版本链查重，链上任何 `version_number >= view.visibility_bound`（即本快照后新出现的版本）且 row id 重叠即抛 `Conflict on update!`（`src/storage/table/update_segment.cpp:667-699`，抛出点 683）。DELETE 检查每行删除者 id，已被他人（含未提交者）删除则抛 `Conflict on tuple deletion!`（`src/storage/table/chunk_info.cpp:384-425`，抛出点 392/417）。
   - **commit 时刻**：undo 里每条 INSERT/DELETE/UPDATE 复查表头 catalog 版本，若表已被并发事务 ALTER/DROP 则整体回滚（`src/transaction/commit_state.cpp:356-394`）；append 合入前的 `AppendLock` 同样校验（`src/storage/data_table.cpp:1053-1071`）。
2. **表级互斥**：每表一个 `append_lock` mutex 串行化并发 append 的行号分配（`data_table.cpp:1054`）；`SharedLockTable` 让写事务在表上持共享锁，ALTER/checkpoint 需要排他（`duck_transaction.cpp:384-404`）。
3. **提交段全局串行**：写事务提交期间全程持有 WAL 锁，`WriteToWAL` 在 WAL 锁下、`transaction_lock` 临时放开（`duck_transaction_manager.cpp:387-398`）；commit_id 的分配又回到 `transaction_lock` 下（:425）。
4. **CHECKPOINT 互斥**：写事务一旦修改数据即取 `SharedCheckpointLock`（`duck_transaction.cpp:360-363`）；`CHECKPOINT` 命令要 `TryGetExclusiveLock`，失败则提示改用 FORCE CHECKPOINT（`duck_transaction_manager.cpp:237-242`）；FORCE 变体持 `start_transaction_lock` 阻止新事务后自旋等锁（:246-252）。反过来，仍有事务需要读旧版本时只能降级为并发 checkpoint（:255-258，:536-544）。
5. **一个事务只能写一个 attached database**：`MetaTransaction::ModifyDatabase` 对第二个写目标直接抛异常（`src/transaction/meta_transaction.cpp:272-281`）。

真正无并发的窗口由 `CommitInfo.active_transactions` 记录：`HasOtherTransactions` 为假时，commit 可以就地 fsync 并跳过部分索引清理工作（`duck_transaction_manager.cpp:429-433`；`src/transaction/cleanup_state.cpp:60-63`）。

## 4. UndoBuffer：变更日志，而非旧版本仓库

`UndoFlags` 共 7 类，其中 6 类真实使用（`src/include/duckdb/common/enums/undo_flags.hpp:15-23`）：

| UndoFlags | 载荷 | 写入点 |
|---|---|---|
| `CATALOG_ENTRY` | CatalogEntry 指针（+ALTER 反序列化 extra data） | `duck_transaction.cpp:73-92` |
| `INSERT_TUPLE` | AppendInfo{表, start_row, count} | `duck_transaction.cpp:134-140` |
| `DELETE_TUPLE` | DeleteInfo{版本管理器, vector_idx, 行号(可省)} | `duck_transaction.cpp:101-132` |
| `UPDATE_TUPLE` | UpdateInfo{新值数组, row ids, 链指针} | `duck_transaction.cpp:142-149` |
| `SEQUENCE_VALUE` | 序列 usage_count/counter 旧值 | `duck_transaction.cpp:151-167` |
| `ATTACHED_DATABASE` | ATTACH 的库指针 | `duck_transaction.cpp:94-99` |

条目 = 8 字节头（type + len）+ 载荷（`src/transaction/undo_buffer.cpp:22,28-39`），由 `UndoBufferAllocator` 从 BufferManager 分配的块链承载——**内存态、可被缓冲池逐出，但不落盘**（`src/include/duckdb/transaction/undo_buffer_allocator.hpp:21-32,73-82`）。

注意 DuckDB 的 undo 记录的是**新值**（UPDATE_TUPLE 存更新后的列值），旧值仍留在 base 段；读者看到"新值已提交但不在自己快照内"时，沿 UpdateInfo 链回放旧版本（`src/include/duckdb/transaction/update_info.hpp:61-87`）。这与 PostgreSQL 的"旧版本进回滚段"方向相反，WAL 里则记的是提交值 redo（UPDATE 从 base 段取已提交值写日志，`src/transaction/wal_write_state.cpp:232`）。

DELETE 在存储侧的完整管线值得单独走一遍（它是唯一"即时改可见状态"的写操作）：

```
DataTable::Delete (data_table.cpp:1349-1387)
  ├─ LocalStorage::Delete      —— 删自己未提交的 append：只改本地计数
  └─ RowGroupCollection::Delete → RowGroup → RowVersionManager::DeleteRows
       └─ ChunkVectorInfo::Delete：逐行检查删除者 id
            · 已被他人删除 → 抛 "Conflict on tuple deletion!"
            · 否则打上自己的 tid（此刻起其他事务的扫描就"看不见这次删除"，
              因为 tid ≥ 2^62 不在任何快照的 bound 内）
       └─ VersionDeleteState::Flush：真实删除数 > 0 才 PushDelete 进 undo
            (row_group.cpp:2180-2195)
commit 时：CommitDelete 把 tid 改写成 commit_id，并从索引中移除行
rollback 时：CommitDelete(NOT_DELETED_ID) 复活这些行 (rollback_state.cpp:37-42)
```

undo 缓冲的四个消费阶段各对应一个 visitor（`src/transaction/undo_buffer.cpp:176-216`）：

- **WriteToWAL**（提交时）：`WALWriteState::CommitEntry` 把 catalog 变更、DELETE 行号、UPDATE 列值、序列值写成 WAL 记录（`wal_write_state.cpp:266-310`）；
- **Commit**（发布时）：`CommitState::CommitEntry` 把每条目的版本号改写为 commit_id——INSERT 调 `CommitAppend`、DELETE 调 `CommitDelete`、UPDATE 直接 `version_number = commit_id`（`commit_state.cpp:356-395`）；
- **RevertCommit**（提交失败时）：把已打上的 commit_id 改回 tid（`commit_state.cpp:412-451`）；
- **Rollback**（显式回滚）：**逆序**重放，catalog 走 `CatalogSet::Undo`、append 调 `RevertAppend` 收缩行数、delete 把 id 重置为 `NOT_DELETED_ID`、update 从链上摘除（`src/transaction/rollback_state.cpp:22-60`）；
- **Cleanup**（GC 时）：确认无任何快照需要后，把 update 从链上摘除、清理索引的 deleted_rows_in_use（`cleanup_state.cpp:24-67`）。

## 5. 可见性判定：存储侧的 id 区间过滤

行版本信息不存于行内，而由 RowGroup 的 `RowVersionManager` 按向量维护 `ChunkVectorInfo`：每个 2048 行向量记录插入者 id 与删除者 id，二者都可在"常量 / 位图 / 数组"三态间压缩（`src/include/duckdb/storage/table/chunk_info.hpp:48-52`；`src/include/duckdb/storage/table/row_version_manager.hpp:32-48`）。选择向量先算可见性、后读数据，意味着被过滤的行根本不发生 I/O 解压——MVCC 过滤是"零行读"级别的剪枝（`row_group.cpp:962-967`，count 为 0 时整个向量跳过）。

扫描热路径：RowGroup 逐向量先问版本信息要 selection vector（`src/storage/table/row_group.cpp:962`），`TemplatedGetSelVector` 以 INSERT_OP/DELETE_OP 两个策略参数展开六种组合（`src/storage/table/chunk_info.cpp:14-43,70-212`）：

- `StandardInsertOperator::UseInsertedVersion = view.Sees(id)`——插入对我的快照可见；
- `StandardDeleteOperator::IsDeleted = view.Sees(id)`——删除可见则行不可见；
- `CommittedDeleteOperator` 只看 `id < bound`（统计等场景不区分谁删的）。

LocalStorage（事务私有 append）在扫描时并列拼接到结果流（`src/storage/data_table.cpp:275-280`），其行号从 `MAX_ROW_ID_LOCAL` 起跳，与持久行号空间不重叠（`src/include/duckdb/common/constants.cpp` 相邻常量区）。

GC 的杠杆是 `lowest_visibility_bound`：所有活跃事务 view bound 的最小值（`duck_transaction_manager.cpp:655-668`）。低于它的版本 id 对所有现在与未来的读者等价，`CompressVersionIds` 可把逐行数组折叠成常量直至整段释放（`row_version_manager.hpp:44-48`；`chunk_info.hpp:84-86`）。已提交事务先驻留 `recently_committed_transactions`，由 `SweepCommittedTransactions` 在该 bound 推进时批量送入清理队列（`duck_transaction_manager.cpp:670-697`），清理在释放锁之后由队列串行执行（:322-339）。

## 6. commit 全链与失败路径

前文 0.2 图给出 happy path。失败分支有三类，均收敛到回滚：

1. **WAL 写失败**：`WriteToWAL` 捕获后调 `commit_state->RevertCommit()`（fsync 失败绝不可重试，注释见 `duck_transaction.cpp:222-226,252-264`）。
2. **打时间戳/flush 阶段失败**：`DuckTransaction::Commit` 捕获后 `undo_buffer.RevertCommit` 把版本号退回 tid 并截断 WAL；若 Revert 本身再失败，数据库整体 invalidate（`duck_transaction.cpp:309-333`；管理器层再兜底 Rollback，`duck_transaction_manager.cpp:437-449`）。
3. **fsync 失败**：提交已发布不可回退，只能 `ValidChecker::Invalidate` 宣告库不可用（:505-512）。

`debug_force_commit_failure` 设置可强制注入 1/2 类失败（`duck_transaction.cpp:290-292,311-314`）。

一个精妙细节：需要 fsync 的提交**在 durable 之前留在 active 集合里**（`wal_sync_offset != 0`，:453-462），使 `GetDurableSnapshot` 能把新快照的 bound 压到第一个未 durable 提交之前——保证新事务不会读到"已发布但崩溃后会消失"的数据（:296-315）。

## 7. 专题补遗：catalog 的 MVCC

catalog 条目走的是版本链而非 id 区间：每个 `CatalogEntry` 带 `timestamp`，`CatalogSet` 用与行版本相同的 commit_ts/transaction id 语义判定"该事务应该看到链上哪个版本"。事务内首个 catalog 变更会把 `transaction.catalog_version` 顶到 `++last_uncommitted_catalog_version`（`src/transaction/duck_transaction_manager.cpp:706-720`）；commit 时 `CatalogSet::UpdateTimestamp(old_entry.Parent(), commit_id)` 统一改写时间戳（`src/transaction/commit_state.cpp:297-350`），而新快照拿到的 `catalog_version` 取 `min(last_committed_version, durable.catalog_version)`（`duck_transaction_manager.cpp:99`）——catalog 可见性同样受 durability 约束。catalog 写写冲突在 commit 时暴露：并发 ALTER 同一表会使后提交者的 undo 校验失败（`commit_state.cpp:283-290`），CREATE TRIGGER 与并发 ALTER 之间甚至有双向检查（:305-347）。

## 8. 没有 WAL 的库：temp 与 in-memory

`ShouldWriteToWAL` 对 system 库、显式禁用 WAL 与无 WAL 的存储（in-memory/temp）直接返回假（`duck_transaction.cpp:197-213`）。这类库的提交只剩"打 commit_id + undo 发布"；自动 checkpoint 的大小估算改用 undo 属性的 `estimated_size` 虚拟计账（`duck_transaction_manager.cpp:416-422`）。

## 9. 只读事务的零开销路径

- 只读事务 BEGIN 不取 `start_transaction_lock`（`duck_transaction_manager.cpp:81-84`）；
- `ChangesMade()` 为假时 `DuckTransaction::Commit` 第一行直接返回（`duck_transaction.cpp:272-274`），`ShouldWriteToWAL` 为假则整段 WAL 锁逻辑被跳过（`duck_transaction_manager.cpp:377-398`，注释明确"只读事务可在他人写 WAL 期间启停"）；
- 无变更的移除不进入 recently_committed 也不排清理（`duck_transaction_manager.cpp:639-643`）；
- 只读事务不触发自动 checkpoint（`duck_transaction.cpp:183-186`）；
- 读路径开销只在扫描时每向量一次 id 区间过滤，undo buffer 完全不参与；
- 兜底一致性：连接析构时若事务仍活跃，`TransactionContext` 析构函数自动回滚并吞掉二级异常（`src/transaction/transaction_context.cpp:21-34`），保证泄漏的连接不会长期钉住 `lowest_visibility_bound`；
- 显式 `ROLLBACK` 链：`TransactionContext::Rollback`（`transaction_context.cpp:103-125`）→ `MetaTransaction::Rollback` 逆序逐库（`meta_transaction.cpp:167-194`）→ `DuckTransactionManager::RollbackTransaction` 持锁回滚并立即移出 active 集合（`duck_transaction_manager.cpp:573-593`）。

## 10. Appender：绕过执行器，但不绕过事务

- 用户级 `Appender` 攒满一个 flush（默认行数/内存阈值，`src/main/appender.cpp:769-791`）后，把 ColumnDataCollection 包装成 `INSERT INTO t FROM __duckdb_internal_appended_data` 的 SQL 语句走 `ClientContext::Query` 完整执行（`appender.cpp:615-628`；`src/main/client_context.cpp:1460-1474`）。约束、索引、事务语义与手写 INSERT 完全一致——**不绕过事务**，autocommit 下每批一提交，显式事务内则并入当前事务。
- `InternalAppender`（系统表/内部使用）走真正的直连路径：`table.GetStorage().LocalAppend(...)` 直写当前事务的 LocalStorage（`appender.cpp:747-751`），仍是事务性的，只是跳过 binder/executor。
- LocalStorage 的合入发生在 commit 时：bulk append（≥整 row group 且无删除）直接把 row group collection 移交给主表（`src/storage/local_storage.cpp:576-588`），并 `PushAppend` 进 undo（:604）。大块在拿锁前预刷并 fsync（`duck_transaction.cpp:215-228`；`local_storage.cpp:612-628`）。
- Appender 构造时拒绝只读库（`appender.cpp:518-519`）。

## 11. 隔离级别：如实记录

在本基线仓库中检索 `snapshot isolation`/`serializable` 等关键词，**源码与注释中均未找到显式的隔离级别声明**（无 isolation level 枚举或设置项；官方文档位于独立的 duckdb-web 仓库，不在本克隆内）。行为证据指向"快照读 + 首提交者胜"的快照隔离语义：

- 读快照定格于 BEGIN：`VisibilityBound::Before(start_time)`（`duck_transaction_manager.cpp:97-98`）；
- 不可重复读不可能：bound 不随查询推进；脏读不可能：未提交版本 tid ≥ 2^62，不落在任何 bound 内（`constants.cpp:19-20`）；
- 丢失更新不可能：update/delete 即时冲突检测（第 3 节）；
- 写偏斜（write skew）无防止机制（无 SSI 谓词锁），理论上可能；
- 额外地，快照还叠加了 durability 约束：只含已 fsync 的提交（:296-315）。

## 12. 设计动机

1. **为什么提交段单写者（WAL 锁 + 集中分配 commit_ts）**：WAL 记录的是逻辑变更而非页镜像，重放时必须与提交序严格一致才能收敛；用一把 WAL 锁把"写日志→定 commit 序→发布"串成临界区，换来无需页级 latch 协议，也让 commit_id 分配只需一个 mutex 自增（`duck_transaction_manager.cpp:283-285`）。
2. **为什么 undo 是内存态变更日志而非回滚段**：分析型负载回滚罕见、更新以批量为主；undo 只需覆盖"未提交窗口 + 最老活跃快照"两个时刻，`lowest_visibility_bound` 一旦越过即可整体释放并压缩版本 id（`row_version_manager.hpp:44-48`）。存新值而非旧前像，使 undo 与 WAL 内容同源，省一份写入。
3. **为什么 commit 先写 WAL 后打 commit_ts**：保证任何对外可见的 commit_id 版本，其 redo 必已在 WAL 字节流中；fsync 允许滞后（flush marker + `SyncUpTo` 组提交），但顺序不允许颠倒——否则崩溃重放会出现"从未提交过的已提交数据"（0.2 图步骤 3-8 的顺序约束）。
4. **为什么读快照用 id 区间而非 xmin/xmax 集合**：判定压缩为一次 64 位比较（`transaction_data.hpp:34-36`），对列存全表扫描的每向量热路径零额外结构；且 id 即版本号使"历史 id 折叠为常量"成为可能，老数据在无读者后版本元数据趋近于零。
5. **为什么写写冲突即时抛异常而非加锁等待**：乐观并发假定冲突罕见，读不阻塞写、写不阻塞读；冲突代价是一个可重试异常，而不是锁表和死锁检测器。DuckDB 因此没有任何行级锁结构。
6. **为什么 Appender 直连存储**：批量导入是分析库第一高频路径，InternalAppender/bulk append 绕过执行器直写 LocalStorage 并以整 row group 移交合入（`local_storage.cpp:576-588`），把每行的事务开销摊销成每 row group 一次。
7. **为什么清理走队列且在锁外**：GC 依赖的 visibility bound 在 `transaction_lock` 内算好（`duck_transaction_manager.cpp:605-653`），实际释放工作在锁外由单线程队列按序执行（:699-704）——临界区内不做 I/O，提交延迟与历史长度解耦。

## 13. 写作素材清单

1. `src/include/duckdb/common/constants.cpp:18-22` —— 两段 id 空间的全部常量（2^62 分界）
2. `src/include/duckdb/transaction/transaction_data.hpp:23-37` —— SnapshotView::Sees，一行可见性判定
3. `src/include/duckdb/common/constants.hpp:67-98` —— VisibilityBound 强类型独占上界
4. `src/transaction/duck_transaction_manager.cpp:78-111` —— StartTransaction：start_ts/快照/快照目录版本
5. `src/transaction/duck_transaction_manager.cpp:341-571` —— CommitTransaction 全链（WAL 锁、组提交、durable_bound）
6. `src/transaction/duck_transaction.cpp:269-334` —— DuckTransaction::Commit 与 RevertCommit 失败路径
7. `src/transaction/duck_transaction.cpp:230-267` —— WriteToWAL：LocalStorage 合入 + undo 写日志
8. `src/include/duckdb/common/enums/undo_flags.hpp:15-23` —— Undo 六类条目
9. `src/transaction/undo_buffer.cpp:176-216` —— Cleanup/WriteToWAL/Commit/Revert/Rollback 五阶段
10. `src/transaction/commit_state.cpp:356-395` —— commit 时逐条目打 commit_id + 并发 ALTER 冲突
11. `src/storage/table/update_segment.cpp:667-699` —— "Conflict on update!" 写写冲突检测
12. `src/storage/table/chunk_info.cpp:70-212` —— TemplatedGetSelVector 六组合可见性过滤
13. `src/transaction/rollback_state.cpp:22-60` —— 逆序回滚四类条目
14. `src/transaction/duck_transaction_manager.cpp:655-697` —— lowest_visibility_bound 与 recently_committed GC
15. `src/storage/local_storage.cpp:561-641` —— 本地 append 的 bulk 合入与提交
16. `src/main/appender.cpp:615-628,747-751` —— Appender 的 SQL 路径与 InternalAppender 直连路径

---

## 14. 结语

DuckDB 用不到两千行事务层代码（src/transaction/ 目录）实现了一个完整的 MVCC 引擎，秘诀在于三处"减法"：把提交状态折叠进版本号本身（省掉 clog）、把快照折叠成一个区间（省掉活跃事务集合快照）、把旧版本留在原位只记录变更（省掉回滚段与 vacuum 线程）。代价是乐观并发的冲突异常与 WAL 锁上的提交串行——对"单机分析、少量写入端"的场景，这是一笔划算的交易。WAL 记录格式、checkpoint 如何把 undo 链固化进块布局，留待卷二。
