# F 章：PostgreSQL MVCC 与快照 —— 可见性判定深读

> 源码基线：PostgreSQL master，commit `8c7a74c3239ce29940582643533a190721b395c0`（"Re-read standby LSN after recovery ends"）。
> 前作对照：卷一 01 进程 / 02 缓冲 / 03 WAL / 04 SLRU-clog / 05 锁。本章核心文件：`src/backend/access/heap/heapam_visibility.c`、`src/backend/utils/time/snapmgr.c`、`src/backend/storage/ipc/procarray.c`、`src/include/access/htup_details.h`、`src/include/utils/snapshot.h`。
> （确认：`src/backend/access/heap/` 下有 heapam.c、heapam_visibility.c、pruneheap.c、vacuumlazy.c、visibilitymap.c 等；`src/backend/utils/time/` 下只有三个文件：combocid.c、snapmgr.c 与构建文件。）

---

## 1. 全景：一行数据的可见性判定

PostgreSQL 的 UPDATE 不覆盖旧值，而是写新版本行；一行是否"存在"，由 **元组头里的两个 XID（xmin/xmax）× clog 提交状态 × 快照** 三元输入共同裁决：

```
                          ┌──────────────────────────────────────────┐
                          │  堆页中的元组头 HeapTupleHeaderData       │
                          │  t_xmin (插入者XID)   t_xmax (删除者XID)  │
                          │  t_infomask: HEAP_XMIN/XMAX_COMMITTED…   │
                          │  t_cid / t_ctid                          │
                          └───────────┬──────────────────────────────┘
                                      │ ①先查 infomask 提示位(hint bits)
                                      ▼
        ┌───────────────── 未设提示位 → 逐位判定 ─────────────────┐
        │ xmin: IsCurrentTransactionId?  (本事务自己插的→查 cmin/curcid)
        │       XidInMVCCSnapshot?       (快照认其在跑→不可见,不查 clog)
        │       TransactionIdDidCommit?  (→查 clog,顺手埋 hint bits)
        │       否则                     (→已中止/崩溃,不可见)
        ▼
 ┌─────────────────────────────────────────────────────────────┐
 │ ② xmax 分支同理:没删过(0/INVALID/仅锁)→可见;                 │
 │   删除者已提交且不在快照内→不可见;删除者未决→可见            │
 └─────────────────────────────────────────────────────────────┘
        │                                    ▲
        ▼                                    │ 支撑数据
  输出: live / dead / in-progress            │
   · live      → 对本快照可见                │
   · dead      → xmin/xmax 组合判负          │
   · in-progress → 插入或删除事务仍运行      │
                                      ┌──────┴───────┐
                                      │ 三份旁证材料  │
                                      │ clog(卷一04) │
                                      │ procarray 快照│
                                      │ subtrans 父XID│
                                      └──────────────┘
```

判定入口是 `HeapTupleSatisfiesVisibility()`，按 `snapshot->snapshot_type` 分派到 8 个 Satisfies 函数（heapam_visibility.c:1731-1749，函数族清单注释见 38-56 行）。每个函数的判据只有三类共享内存/磁盘事实：本事务 ID（xact.c:943）、procarray 是否在跑（procarray.c:1393）、clog 状态（transam.c:52 `TransactionLogFetch` → transam.c:126 `TransactionIdDidCommit`）。

---

## 2. 元组头专节：24 字节逐字段

结构定义 `HeapTupleHeaderData`（src/include/access/htup_details.h:153-181），定长部分 23 字节（注释见 175 行），`SizeofHeapTupleHeader` 为 23（185 行）——对齐到 24 字节起步，其后是 NULL 位图与用户数据：

| 字段 | 类型 | 作用（行号） |
|---|---|---|
| t_choice.t_heap.t_xmin | TransactionId(4B) | 插入事务 XID（htup_details.h:124） |
| t_choice.t_heap.t_xmax | TransactionId(4B) | 删除/更新/锁定事务 XID（125 行） |
| t_field3.t_cid / t_xvac | 联合(4B) | 插删命令号 cmin/cmax 复用；旧式 VACUUM FULL 的 t_xvac（127-131 行） |
| t_ctid | ItemPointer(6B) | 本元组或"更新后新版本"的 TID（161 行，语义注释 86-112 行） |
| t_infomask2 | uint16 | 属性数(低 11 位)+HEAP_KEYS_UPDATED/HOT_UPDATED/ONLY_TUPLE（167、291-296 行） |
| t_infomask | uint16 | 提示位与锁标志（170 行，位定义 190-219 行） |
| t_hoff | uint8 | 头部总长（含位图、对齐），指向用户数据（173 行） |
| t_bits[] | 柔性数组 | NULL 值位图，无 NULL 时不存（178 行，114-118 行） |

**五个虚拟字段压进三个物理字段**（htup_details.h:73-84）：Xmin/Xmax 恒存；Cmin/Cmax/Xvac 共用 t_field3——因为 cmin 只在"本事务后续命令"里有用、cmax 只在"本事务删除后"有用，同一事务又插又删时存"组合 CID"，由 `src/backend/utils/time/combocid.c:12-18,80` 的本地哈希/数组还原。

**infomask 可见性关键位**（htup_details.h:204-219）：

```
#define HEAP_XMIN_COMMITTED   0x0100  /* t_xmin 已提交            */  (204)
#define HEAP_XMIN_INVALID     0x0200  /* t_xmin 无效/已中止        */  (205)
#define HEAP_XMIN_FROZEN      (HEAP_XMIN_COMMITTED|HEAP_XMIN_INVALID)     (206)
#define HEAP_XMAX_COMMITTED   0x0400  /* t_xmax 已提交            */  (207)
#define HEAP_XMAX_INVALID     0x0800  /* t_xmax 无效/已中止        */  (208)
#define HEAP_XMAX_IS_MULTI    0x1000  /* t_xmax 是 MultiXactId     */  (209)
#define HEAP_UPDATED          0x2000  /* 被 UPDATE 的版本          */  (210)
#define HEAP_XACT_MASK        0xFFF0  /* 可见性相关位总掩码        */  (219)
```

没有所谓 "HEAP_XMIN_BLACK" 位：两个 COMMITTED/INVALID 位的三种组合即"已提交 / 已中止 / 冻结"（9.4 起 freeze 不再改写 xmin 值，只设两位，见 `HeapTupleHeaderGetRawXmin` 注释 htup_details.h:315-321）。锁相关位 `HEAP_XMAX_LOCK_ONLY`/`HEAP_XMAX_EXCL_LOCK`/`HEAP_XMAX_KEYSHR_LOCK`（194-203 行）让"SELECT FOR UPDATE 只加锁不删行"与真删除在 infomask 层可区分，`HEAP_XMAX_IS_LOCKED_ONLY()` 内联函数在 229-234 行。t_infomask2 侧 `HEAP_HOT_UPDATED`/`HEAP_ONLY_TUPLE`（295-296 行）标记 HOT 链。

**ctid 的版本链角色**：新行写入时 t_ctid 指向自己；被 UPDATE 后改指新版本（htup_details.h:86-94）。写链点在 heap_update 里：先清旧 XMAX 位（src/backend/access/heap/heapam.c:4209-4212），设 xmax/cmax（4212-4215），最后一行把旧元组的 t_ctid 指向新元组（heapam.c:4217-4218 `oldtup.t_data->t_ctid = heaptup->t_self;`）。反向追链（找最新版）见 heapam.c:1810-1892 的循环，htup_details.h:96-103 提醒追链时要校验"被指者的 xmin == 指者 xmax"，防 VACUUM 复用了槽位。

---

## 3. 可见性判定专节：HeapTupleSatisfiesMVCC 分支矩阵

### 3.1 分派器

```
HeapTupleSatisfiesVisibility()                    heapam_visibility.c:1731
  switch (snapshot->snapshot_type)                (1734-1749)
    SNAPSHOT_MVCC            → HeapTupleSatisfiesMVCC          (939)
    SNAPSHOT_SELF            → HeapTupleSatisfiesSelf          (297)
    SNAPSHOT_ANY             → HeapTupleSatisfiesAny           (430, 恒 true)
    SNAPSHOT_TOAST           → HeapTupleSatisfiesToast         (452)
    SNAPSHOT_DIRTY           → HeapTupleSatisfiesDirty         (759)
    SNAPSHOT_HISTORIC_MVCC   → HeapTupleSatisfiesHistoricMVCC  (1504, 逻辑解码)
    SNAPSHOT_NON_VACUUMABLE  → HeapTupleSatisfiesNonVacuumable (1345)
```

VACUUM 用另一套 `HeapTupleSatisfiesVacuum`（1112 行）返回四态：LIVE / DEAD / RECENTLY_DEAD / INSERT/DELETE_IN_PROGRESS（Horizon 版在 1146-1329 行，`dead_after` 与 OldestXmin 比较在 1121-1127 行）。

### 3.2 MVCC 判定矩阵（xmin × xmax）

`HeapTupleSatisfiesMVCC`（heapam_visibility.c:938-1096）的两段式结构：先裁 xmin（956-1024），xmin 可见再裁 xmax（1028-1095）。记 snapshot 数组判定 `XidInMVCCSnapshot()`（snapmgr.c:1902）为"in-snap"。完整组合如下（"可见"指本快照能读到该行）：

| xmin 状态 | xmax = 0/INVALID | xmax 仅锁 | xmax in-progress | xmax 已提交 | xmax 已中止 |
|---|---|---|---|---|---|
| 本事务，cmin≥curcid | 不可见 (965-966) | 不可见 | 不可见(删于扫描后→可见 1000-1001) | — | — |
| 本事务，cmin<curcid | 可见 (968-969) | 可见 (971-972) | 见 992-1003 | — | — |
| in-snap（快照认为在跑） | 不可见 (1005-1006) | 同左 | 同左 | 同左 | 同左 |
| 已提交（且不在快照内） | **可见** (1028-1029) | 可见 (1031-1032) | 可见 (1071-1072) | **不可见** (1095) | 可见 (1074-1079) |
| 已中止 | 不可见 (1010-1016) | 同左 | 同左 | 同左 | 同左 |

三个代表性分支：

- **xmin 未决但快照不含它**：`XidInMVCCSnapshot(xmin, snapshot)` 为真 → 直接不可见，**不去查 clog**（1005-1006）。这正是 MVCC 快照的核心语义："快照认为是未决的，就当未决"。
- **xmin 已设提示位但晚于快照**：提示位说提交了、但该 XID 仍在快照 xip 里 → "当作仍在跑"，不可见（1018-1024）。解释了 READ COMMITTED 下老快照为何看不见新提交。
- **xmax 已提交提示位但在快照内**：旧版本对老快照仍可见（1086-1091）。

此外 `HeapTupleSatisfiesMVCC` 开头断言快照必须注册（951 行 `Assert(snapshot->regd_count > 0 || snapshot->active_count > 0)`），防止快照在悬空指针状态下被并发失效。

### 3.3 其余 Satisfies 家族

- **HeapTupleSatisfiesUpdate**（510-736 行）：UPDATE/DELETE/SELECT FOR UPDATE 专用，返回多值结果码 TM_Invisible/TM_Ok/TM_SelfModified/TM_Updated/TM_Deleted/TM_BeingModified（注释 489-508 行）。典型分支：本事务 cmin≥curcid→TM_Invisible（528-529）；本事务 cmax≥curcid→TM_SelfModified（599-600）；他人已提交更新→TM_Updated（627-628，靠 `t_ctid != t_self` 区分"被更新"与"被删除"）；他人未决→TM_BeingModified（710-711）。EPQ 判断走 TM_Updated 的 t_ctid 路径。
- **HeapTupleSatisfiesSelf**（296-423 行）：即时快照+当前命令，无 xip 判定，纯 clog，给 DDL/系统表内部访问用。
- **HeapTupleSatisfiesDirty**（758-914 行）：连"他人未提交的插入"也可见（811-829 返回 true 并把 xmin 回填进 `snapshot->xmin` 作输出参数，767-768 行先清零），speculative insertion token 也在 819-825 行透传——供 ON CONFLICT 探测。
- **HeapTupleSatisfiesHistoricMVCC**（1504-1671 行）：逻辑解码的时间旅行版。不再查 clog，改查"已知提交列表"：xmin 在 `subxip`（本事务 ID 集合）→ 用 `ResolveCminCmaxDuringDecoding` 解 cmin/cmax（1521-1558）；`xip` 语义反转，装的是"已提交"集合（snapshot.h:156-160 注释）。

---

## 4. 快照专节：SnapshotData 与 GetSnapshotData

### 4.1 SnapshotData 结构（src/include/utils/snapshot.h:138-210）

```
TransactionId xmin;      /* XID < xmin 的一切已了结,必定可见     */ (153)
TransactionId xmax;      /* XID >= xmax 一切视为在跑,不可见      */ (154)
TransactionId *xip;      /* [xmin,xmax) 之间的在跑 XID 列表      */ (164)
uint32          xcnt;                                            (165)
TransactionId *subxip;   /* 子事务 XID 列表(溢出后可能不全)      */ (176)
int32           subxcnt;                                         (177)
bool            suboverflowed;                                   (178)
bool            takenDuringRecovery; /* 热备快照形状          */ (180)
CommandId       curcid;      /* 本事务内 CID < curcid 才可见       */ (183)
uint32  active_count, regd_count;  /* 活跃栈/注册 两份引用计数    */ (200-201)
uint64  snapXactCompletionCount;   /* 免重算快照的复用依据        */ (209)
```

xip[] 数组在首次取快照时按 `GetMaxSnapshotXidCount()` 一次性 malloc，之后复用（procarray.c:2145-2172）；子事务数组按 `GetMaxSnapshotSubxidCount()` = `TOTAL_MAX_CACHED_SUBXIDS` 分配（procarray.c:2019-2021、410-411）。

### 4.2 GetSnapshotData：热路径全扫描（src/backend/storage/ipc/procarray.c:2113-2466）

持 **ProcArrayLock 共享锁**（2178 行）执行：

1. **复用快路径** `GetSnapshotDataReuse`（procarray.c:2033-2079）：距上次以来 `TransamVariables->xactCompletionCount` 未变（2040-2045 行），说明带 XID 的事务集合没变，直接改 curcid 返回——这是 2021 年加入的延迟优化，避免空跑全表。
2. **xmax** = `latestCompletedXid + 1`（procarray.c:2194-2196）；**xmin** 初始化为 xmax，再取自身 XID（2202-2204 行）。
3. **遍历 proc 数组**（2220-2311 行）：跳过无 XID 的（2232-2233）、跳过自己（2240-2241）、跳过 ≥xmax 的（2256-2257）、跳过逻辑解码与 VACUUM 的（2263-2265）；`xmin = min(xmin, xid)`（2267-2268），然后 `xip[count++] = xid`（2271 行）。能尽量拷贝子事务 XID（memcpy proc->subxids.xids，2304-2307 行）；某后端子事务溢出（`subxidStates[pgxactoff].overflowed`）则整快照标 `suboverflowed`（2291-2292）。
4. **热备分支**：从 KnownAssignedXids 全部塞进 subxip（2344-2348 行，注释解释为何复用大数组 2316-2332）。
5. 安装 `MyProc->xmin = TransactionXmin = xmin`（2360-2361 行）后放锁（2363 行），随后在锁外更新四个 GlobalVisState 视界（2366-2443 行），最终 `RecentXmin = xmin`（2445 行）、填 snapshot（2448-2455 行）。

xmin/xmax 的"夹逼"意义：XID < xmin 一律可见；≥ xmax 一律不可见；中间区间的看 xip。事务结束端 `ProcArrayEndTransaction`（procarray.c:663，内部 725 行）在独占锁下清 XID 并 `xactCompletionCount++`（768 行），这是复用快路径的失效信号。

### 4.3 查询语义：XidInMVCCSnapshot（snapmgr.c:1902-1990）

先做范围裁剪：`xid < snapshot->xmin` 必不在跑（1914-1915），`>= xmax` 必在跑（1917-1918）；快照未溢出时线性查 subxip（1936 行 `pg_lfind32`，SIMD 优化见 src/include/port/pg_lfind.h:84-103）再查 xip（1958 行）；**溢出时改走 subtrans**：`SubTransGetTopmostTransaction`（1947 行调用；实现在 src/backend/access/transam/subtrans.c:170）把子 XID 折算成顶层 XID 再查 xip——这就是子事务缓存溢出的运行时代价。

### 4.4 注册与活性管理（snapmgr.c）

快照是"活物"：必须让 procarray 知道它存在，xmin 才能不被 VACUUM 推进。机制有三层：

- **ActiveSnapshot 栈**：`PushActiveSnapshot`（snapmgr.c:682）/`PopActiveSnapshot`（775 行），每条语句执行期套一层。
- **注册堆**：`RegisterSnapshot`（824 行）/`UnregisterSnapshot`（866 行），加入按 xmin 排序的 pairingheap `RegisteredSnapshots`（snapmgr.c:190，比较函数 910 行），使 O(1) 找到最小 xmin。
- **xmin 归还**：全部失效后 `SnapshotResetXmin`（937-953 行）把 `MyProc->xmin` 清空，交还视界。

快照结构虽多字段但存在"序列化+恢复"形态（并行 worker / 两阶段事务），只搬 7 个字段（`SerializedSnapshotData`，snapmgr.c:251-260；`RestoreTransactionSnapshot` 1886-1890 行）。逻辑解码另用独立的 `HistoricSnapshot`（snapmgr.c:152、1708 行赋值）。

---

## 5. hint bits 专节：谁先读谁埋

**设置点**：`SetHintBitsExt`（heapam_visibility.c:141-192）。任何可见性函数发现"该 XID 不在跑、去 clog 查到了结论"，就地回写 infomask——xmin 分支的回写在 1007-1016 行（COMMITTED/INVALID 各一处），xmax 分支在 1074-1084 行。原则是"谁先读到谁埋"，于是后续读者连 clog 都不用碰。

**LSN 互锁（安全性的全部秘密）**，heapam_visibility.c:152-166：

```c
if (BufferIsPermanent(buffer))
{
    /* NB: xid must be known committed here! */
    XLogRecPtr commitLSN = TransactionIdGetCommitLSN(xid);
    if (XLogNeedsFlush(commitLSN) &&
        BufferGetLSNAtomic(buffer) < commitLSN)
    {
        /* not flushed and no LSN interlock, so don't set hint */
        return;
    }
}
```

只有当事务 commit 记录的 WAL 已刷盘（或页面 LSN 已晚于 commit LSN），才敢在**只持共享锁的页**上写数据页：否则崩溃恢复时可能出现"页上有 committed 提示、clog 记录却随 WAL 一起丢了"的幽灵行。这段注释（101-139 行）还解释了页校验和时代的保留理由：写提示位必须绕开校验和破坏问题，因此新代码用 `BufferBeginSetHintBits/BufferFinishSetHintBits`（heapam_visibility.c:181-191）申请页级"写提示权"，批量扫描时用 `SetHintBitsState`（91-99 行：SHB_INITIAL/SHB_DISABLED/SHB_ENABLED）摊薄开销，批处理入口 `HeapTupleSatisfiesMVCCBatch`（1689-1719 行）整页只 Finish 一次。中止事务的提示位则随时可写（125 行注释）。旧式 VACUUM FULL 的 HEAP_MOVED 清理路径固定同步提交，可无条件埋位（128-133、231-273 行）。

**什么场景白做**：`HeapTupleSatisfiesMVCC` 的注释（922-936 行）解释了"延迟埋位"策略——插入/删除事务还在跑时，新快照读者只做 `XidInMVCCSnapshot`，**不**主动 `TransactionIdIsInProgress`（后者要抢 ProcArrayLock， contention 高且结果也不会变）；等第一个"快照足够新"的读者顺手埋位。代价只是未决期间每行多一次范围判断。VACUUM 侧的廉价路径 `HeapTupleIsSurelyDead`（1380-1425 行）更进一步：只信提示位，绝不查 procarray/clog（1370-1377 行注释）。

**分工总结**：clog 是"事实源"（永久、SLRU 缓存、卷一 04 章），hint bits 是"页内缓存"（可丢失、可重建、不进 WAL）。

---

## 6. 隔离级别专节：两级快照与 SSI

**选择点只有一个函数**：`GetTransactionSnapshot()`（snapmgr.c:271-346）。判断谓词在 src/include/access/xact.h:52-53：

```c
#define IsolationUsesXactSnapshot() (XactIsoLevel >= XACT_REPEATABLE_READ)
#define IsolationIsSerializable()   (XactIsoLevel == XACT_SERIALIZABLE)
```

- **READ COMMITTED**：每条语句都取新快照——事务首访走 294-334 行的"首快照"分支，后续语句每次都重新 `GetSnapshotData(&CurrentSnapshotData)`（343 行）；语句层的 Push 调用在 src/backend/tcop/postgres.c:1186/1541/1824。
- **REPEATABLE READ**：首快照复制为 `FirstXactSnapshot` 并注册到事务结束（snapmgr.c:316-329：CopySnapshot → regd_count++ → 入堆），后续语句一律返回 `CurrentSnapshot`（337-338 行）——"事务快照"由此实现，不需要每语句重取。
- **SERIALIZABLE**：在 RR 快照之上叠 SSI。`GetSerializableTransactionSnapshot`（src/backend/storage/lmgr/predicate.c:1611）包裹普通取快照并注册rw-依赖结构（1693 行 `GetSerializableTransactionSnapshotInt`）；执行期由 `CheckForSerializableConflictOut`（predicate.c:3952，读侧发现 rw 依赖）与 `CheckForSerializableConflictIn`（4265 行，写侧登记）驱动"谓词锁"。谓词锁不走行锁：对无索引扫描退化为页面/关系级 SIReadLock，靠事务结束后释放（predicate.c:160-181 的 API 总览注释）。

---

## 7. 与前作对照

| 系统 | 一致性单元 | 机制 | 与 PG 的差别 |
|---|---|---|---|
| SQLite（卷七） | 单写者、库级锁 | 无 MVCC 需求：写者独占，读者依赖 WAL 快照读 | PG 允许任意多并发读写，把判定成本摊到每行 |
| LevelDB（卷九） | LSN 序列 | 无事务可见性判定，读即"最新已写值" | PG 的 dead 元组必须显式 VACUUM 回收 |
| etcd MVCC store | revision | key 带 creation/revision 版本号，读按 revision 过滤 | PG 的"revision"就是 xmin/xmax 两个 XID + clog，但物理上就地存元组头而非集中索引 |

PG 的行级 MVCC 是三者中最重的：版本链（t_ctid）、hint bits、clog、procarray 快照、MultiXact、VACUUM 全部为它服务；换来的是读不加锁、写不阻塞读。

---

## 8. 设计动机

1. **为什么把可见性放进元组头而非中央表**（对照 etcd 的 revision 表/Oracle 的回滚段）：行自带 xmin/xmax/infomask，判定只需读该页，无中央热点；代价是每行 23+ 字节头与页内版本链。中央方案省空间但读写都要碰全局结构——PG 反其道把"热"的东西（提示位）也搬进行内。
2. **快照成本与 64 子事务缓存**：快照本质是"在跑 XID 列表"的一次性拷贝，`PGPROC_MAX_CACHED_SUBXIDS = 64`（src/include/storage/proc.h:44，注释自嘲 "XXX guessed-at value"）。每后端只在 proc 里缓存 64 个子 XID（proc.h:56），超过即 `overflowed`，快照退化为"记溢出标志 + 查询时走 subtrans 顶层化"（procarray.c:2291-2292；snapmgr.c:1941-1956）。全局容量按 `(64+1)*PROCARRAY_MAXPROCS` 预算（procarray.c:410-411），热备场景恰好够拷贝全部 KnownAssignedXids（400-408 行注释）。**写报告时可呼应卷一 D 报告**：savepoint 深层嵌套的直接代价不在锁、不在 clog，而在把所有读者的可见性判定从 O(数组) 变成 O(SLRU 访问)。
3. **hint bits 的写放大取舍**：读操作会写页（标脏、可能触发 WAL-less 全页镜像、参与校验和），这是 PG 少有的"读放大变写放大"设计；用 LSN 互锁（heapam_visibility.c:152-166）换取只持共享锁即可写的安全，用延迟埋位（922-936 行）换取热路径不抢 ProcArrayLock。
4. **组合 CID**：cmin/cmax 挤进一个字段（htup_details.h:73-84），本事务"插了又删"的组合命令号由 backend 本地 combocid.c 还原——元组头 23 字节的预算是一寸一寸抠出来的。

---

## 9. FAQ 素材与深挖方向

**FAQ 候选（8-10 条）**：
1. 一行到底"存不存在"？——由 xmin 可见 ∧ xmax 未删 的组合决定，无全局"存在表"（heapam_visibility.c:938-1096）。
2. 为什么 PG 删除行后磁盘占用不降？——UPDATE/DELETE 只标记 xmax，物理回收靠 VACUUM，判死标准是 OldestXmin（heapam_visibility.c:1106-1110）。
3. hint bits 会不会丢？丢了怎么办？——可随时从 clog 重建，本质是页内缓存（heapam_visibility.c:101-139）。
4. 快照的 xmin 和 procarray 的 xmin 有何区别？——snapshot->xmin 是本快照视角；MyProc->xmin 是本后端对外宣称的最低可见界，决定 VACUUM 能回收多老（procarray.c:2360-2361）。
5. READ COMMITTED 与 REPEATABLE READ 实现差异在哪一行？——snapmgr.c:316-329（RR 复制首快照）对 343（RC 每语句重取）。
6. SELECT FOR UPDATE 为什么不产生死元组？——HEAP_XMAX_LOCK_ONLY 位 + `HEAP_XMAX_IS_LOCKED_ONLY()`（htup_details.h:197、229-234）。
7. 长事务为什么阻塞 VACUUM？——注册堆里最小 xmin 的快照压住 GlobalVis 视界（snapmgr.c:190、937-953；procarray.c:314-317）。
8. 并行查询的 worker 怎么拿到主进程的快照？——SerializedSnapshotData 7 字段序列化（snapmgr.c:251-260）。
9. 子事务上限 64 溢出后正确性如何保证？——suboverflowed 标志 + SubTransGetTopmostTransaction 运行时折算（procarray.c:2291-2292；snapmgr.c:1947）。
10. 备库（热备）的可见性为什么走另一套？——xip 空置、全塞 subxip、查询 KnownAssignedXids（procarray.c:2316-2348）。

**深挖方向（3-5 条）**：
1. HOT 链与 pruneheap：同页更新不建索引项，HEAP_HOT_UPDATED/HEAP_ONLY_TUPLE（htup_details.h:295-296）+ `src/backend/access/heap/pruneheap.c` 的页内剪枝。
2. MultiXact：xmax 记"一组并发锁者+更新者"，`HeapTupleGetUpdateXid` 解出真更新者（htup_details.h:388）；结合卷一 05 锁章节。
3. GlobalVisState 近似视界：四张表（shared/catalog/data/temp）各一套 maybe/definitely 界（procarray.c:184、314-317、2366-2443），VACUUM 判死的现代实现。
4. SSI 完整机制：predicate.c 的 SIReadLock 与 rw 依赖图（入口 predicate.c:160-181、1611、3952、4265）。
5. 批量可见性：HeapTupleSatisfiesMVCCBatch 的页级摊销与 hint-bit 批量提交（heapam_visibility.c:1689-1719）。

---

## 写作要点速查表（关键函数 + 行号，基于 commit 8c7a74c）

| 主题 | 位置 | 要点 |
|---|---|---|
| 元组头结构 | src/include/access/htup_details.h:153-181 | 23 字节定长头，xmin/xmax/cid/ctid/infomask |
| 虚拟字段折叠 | htup_details.h:73-84 | cmin/cmax/xvac 共用 t_field3，组合 CID |
| 提示位定义 | htup_details.h:204-219 | XMIN/XMAX COMMITTED/INVALID、FROZEN、XACT_MASK |
| infomask2 位 | htup_details.h:291-298 | KEYS_UPDATED/HOT_UPDATED/ONLY_TUPLE |
| ctid 版本链写入 | src/backend/access/heap/heapam.c:4212-4218 | heap_update 末尾 t_ctid 指向新版本 |
| hint bits 核心 | heapam_visibility.c:141-192 | SetHintBitsExt + LSN 互锁(152-166) |
| 分派器 | heapam_visibility.c:1731-1749 | snapshot_type → 8 个 Satisfies |
| MVCC 主判 | heapam_visibility.c:938-1096 | xmin 段 956-1024 / xmax 段 1028-1095 |
| 延迟埋位动机 | heapam_visibility.c:922-936 | 不在热路径抢 ProcArrayLock |
| UPDATE 判定 | heapam_visibility.c:510-736 | TM_* 结果码；627-628 用 ctid 区分更/删 |
| Dirty 快照回传 | heapam_visibility.c:758-830 | snapshot->xmin/xmax 作输出参数 |
| VACUUM 判定 | heapam_visibility.c:1112-1329 | RECENTLY_DEAD 与 OldestXmin |
| 逻辑解码判定 | heapam_visibility.c:1504-1671 | xip 语义反转，cmin/cmax 外部解析 |
| 快照结构 | src/include/utils/snapshot.h:138-210 | xmin/xmax/xip/subxip/curcid/引用计数 |
| 取快照 | src/backend/storage/ipc/procarray.c:2113-2466 | 2178 取锁、2220-2311 扫 proc、2445 RecentXmin |
| 快照复用快路径 | procarray.c:2033-2079 | xactCompletionCount 不变即免扫 |
| 子事务 64 缓存 | src/include/storage/proc.h:44-56 + procarray.c:2291-2292 | 溢出 → suboverflowed |
| 顶层事务折算 | snapmgr.c:1941-1956 → subtrans.c:170 | XidInMVCCSnapshot 溢出路径 |
| 快照两级选择 | snapmgr.c:271-346 + xact.h:52-53 | RC 每语句(343) vs RR 首快照(316-329) |
| 快照注册/归还 | snapmgr.c:824/866/937-953 | pairingheap 保最小 xmin |
| SSI 入口 | src/backend/storage/lmgr/predicate.c:1611/3952/4265 | 序列化快照包装 + 冲突检查 |
| clog 查询 | src/backend/access/transam/transam.c:52/126 | TransactionLogFetch / DidCommit |
