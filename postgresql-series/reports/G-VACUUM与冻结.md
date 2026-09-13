# G 章：PostgreSQL VACUUM 与 XID 冻结 —— 三重债的清偿机制

> 源码基线：PostgreSQL master，commit `8c7a74c3239ce29940582643533a190721b395c0`（"Re-read standby LSN after recovery ends"）。
> 核心文件：`src/backend/commands/vacuum.c`、`src/backend/access/heap/vacuumlazy.c`、`src/backend/access/heap/pruneheap.c`、`src/backend/access/heap/heapam.c`、`src/backend/access/transam/varsup.c`、`src/backend/postmaster/autovacuum.c`、`src/backend/access/common/tidstore.c`。
> （确认：`src/backend/access/heap/` 下有 heapam.c、pruneheap.c、vacuumlazy.c、visibilitymap.c、heapam_xlog.c、heaptoast.c、README.HOT 等；`src/backend/commands/` 下有 vacuum.c、analyze.c、vacuumparallel.c 等。）
> 与前作呼应：卷一 04 章 clog 截断依赖"最老 xid"——本章 varsup.c 的 `SetTransactionIdLimit`/`vac_truncate_clog` 正是那条链的源头；F 章 MVCC 的"死元组"定义在这里被真正回收。

---

## 1. 全景：为什么需要 VACUUM —— 三重债模型

PostgreSQL 的 UPDATE/DELETE 不就地覆盖旧值，而是写新版本、旧版本原地不动（F 章）；一行"是否还存在"由 xmin/xmax × clog × 快照裁决，于是旧版本只是"对所有人不可见"，仍然占着堆页、仍然挂在索引里、它的 xmin/xmax 仍然需要 clog 作证。这些旧版本同时欠下三种债，而 VACUUM 是唯一能同时清偿三种债的机制：

```
   UPDATE / DELETE（MVCC：旧版本就地留下，F 章）
        │
        ├── 债1 空间债 ────── 死元组占据堆页 → 表膨胀；
        │                    索引中的死 TID → 索引膨胀；页满 → HOT 失效
        │                    清偿：prune(页内手术) + ambulkdelete(删索引条目)
        │                          + LP_UNUSED 回收 + truncate 尾页
        │
        ├── 债2 可见性债 ──── dead 元组的 xmin/xmax 仍要查 clog 判生死
        │                    → clog 不能截断（卷一04 的"最老 xid"）
        │                    → hot standby 回放也要用 clog → WAL 无限增长
        │                    清偿：物理删除后这些 XID 永远不再被询问，
        │                          relfrozenxid/datfrozenxid 水位推进 → clog 截断
        │
        └── 债3 wraparound 债  XID 只有 32 位（transam.h:35，约 42 亿），
                             比较走模 2^31 环形；最老 XID 绕半圈（≈21 亿）
                             追上最新 XID 时"过去"变"未来" → 数据静默丢失
                             清偿：freeze —— 把老 XID 从元组头抹掉
                                   （infomask 打 FROZEN 位、字段值作废）
        │
        ▼
 VACUUM 一趟收三样（主扫描 vacuumlazy.c:880 lazy_scan_heap）：
   ① 空间：prune 死元组 → TID 存入 TidStore → 扫索引删死条目(第二遍)
           → 堆页 LP_UNUSED → 截断尾部空页(vacuumlazy.c:3164)
   ② 可见性：全部清完后推进 relfrozenxid → datfrozenxid(vacuum.c:710,1634)
           → vac_truncate_clog(vacuum.c:1855) → clog 终于能截断(卷一04 闭环)
   ③ 冻结：xmin < FreezeLimit 的元组头打 HEAP_XMIN_FROZEN
           （读侧等价于 FrozenTransactionId = 2，transam.h:33）
```

三债在 `pg_class.relfrozenxid`（表级：本表元组头里可能残留的最老 XID）与 `pg_database.datfrozenxid`（库级：全库所有表的最小 relfrozenxid）上汇合。**一张表永远不 VACUUM，全集群的 clog 就永远不能截断，XID 就永远在消耗**——这就是"一张被遗忘的小表拖垮整个实例"的机制根源。VACUUM 结尾的 `vac_update_datfrozenxid`（vacuum.c:710）正是卷一 04 章 SLRU-clog 截断链路的上游。

## 2. 主流程专节：lazy vacuum 的两遍扫描与 TidStore

入口链：`ExecVacuum`（vacuum.c:163，解析 SQL 选项）→ `vacuum()`（vacuum.c:496）→ 每表一个独立事务的 `vacuum_rel`（vacuum.c:2032）→ 堆 AM 的 `heap_vacuum_rel`（vacuumlazy.c:624）。三个前置约束：VACUUM 禁止在事务块内运行（vacuum.c:513 `PreventInTransactionBlock`）、禁止递归调用（530-535）、VACUUM+ANALYZE 总是自建事务以尽早放锁（578-583）。ANALYZE 联动是简单并列：同一 `vacuum()` 循环里逐表调 `analyze_rel`（vacuum.c:653），采样统计进 pg_statistic，与冻结/清理互不依赖。

`heap_vacuum_rel` 的五阶段骨架（vacuumlazy.c:624-1050，行号链）：

**阶段一：算 cutoffs**。`vacuum_get_cutoffs`（vacuumlazy.c:801 → vacuum.c:1126）确定四个关键值：

```c
/* vacuum.c:1161,1219,1264-1268 */
cutoffs->OldestXmin = GetOldestNonRemovableTransactionId(rel); /* 可删除地平线 */
cutoffs->FreezeLimit = nextXID - freeze_min_age;   /* 且 ≤ max_age/2, ≤ OldestXmin */
if (TransactionIdPrecedesOrEquals(cutoffs->relfrozenxid, aggressiveXIDCutoff))
    return true;                                   /* 表太老 → aggressive 全表扫 */
```

`OldestXmin` 不是普通快照 xmin：`GetOldestNonRemovableTransactionId`（procarray.c:1944）按表类别（普通/目录/共享/临时）取不同地平线，还要被复制槽 catalog_xmin、预备事务向后压——比 F 章任何快照都保守，因为 VACUUM 删掉的元组必须对"所有可能还在看它的人"不可见，否则读错误数据。vacuum.c:1193-1199 会在 OldestXmin 被压得太老（超过 autovacuum_freeze_max_age）时先发一条 WARNING。随后 vacuumlazy.c:803 取 `vistest = GlobalVisTestFor(rel)`（prune 用的批量可见性判定器），806-807 初始化只进不退的水位 `NewRelfrozenXid = OldestXmin`。

**阶段二：分配死元组容器**。`dead_items_alloc`（vacuumlazy.c:863, 3438）：上限取 `autovacuum_work_mem`（-1 则用 `maintenance_work_mem`，vacuumlazy.c:3443-3445）；表有 ≥2 个索引时在此初始化并行 vacuum 的 DSM 共享 TidStore（vacuumlazy.c:3448-3473），否则本地创建：

```c
/* vacuumlazy.c:3497 */
vacrel->dead_items = TidStoreCreateLocal(dead_items_info->max_bytes, true);
```

**阶段三：第一遍扫堆**。`lazy_scan_heap`（vacuumlazy.c:880, 1277）。PG18 起 IO 用 read stream API（vacuumlazy.c:1296-1302），下一个读哪块由回调 `heap_vac_scan_next_block`（vacuumlazy.c:1660）决定：靠 visibility map 找到下一个"不可跳过"块，只有当连续可跳区间 ≥ `SKIP_PAGES_THRESHOLD`（=32 页，vacuumlazy.c:209）才真跳（1693-1698）——避免破坏顺序读的 OS 预读。循环体内每页的处理次序：`vacuum_delay_point` 限速点（1330）→ 每 `FAILSAFE_EVERY_PAGES` 页查一次 wraparound failsafe（1340-1344）→ TidStore 超过 max_bytes 就**中途先做一轮** `lazy_vacuum` 再继续扫（1352-1372，老版本"多轮扫描"的退化形态）→ 拿不到 cleanup lock 就降级 `lazy_scan_noprune`（只收集 LP_DEAD 不动页），拿得到则 `lazy_scan_prune`（1408-1413 → 2033，详见 §3）→ 无索引或无死项时顺手更新 FSM（1540-1575）。

**阶段四：第二遍清索引+收堆**。扫完堆后若 TidStore 非空调 `lazy_vacuum`（vacuumlazy.c:1626-1630 → 2381）：先 `lazy_vacuum_all_indexes`（2506，逐索引 `ambulkdelete`，vacuumlazy.c:3036——与 I 章 nbtree 的 `btbulkdelete` 死条目删除/页面填补呼应），成功后 `lazy_vacuum_heap_rel`（2653）按 TidStore 迭代回堆，把 LP_DEAD 改成 LP_UNUSED 并 `PageRepairFragmentation` 整理碎片；最后 `lazy_cleanup_all_indexes`（1633, 2967，`amvacuumcleanup` 收尾统计）。死元组极少时整体 bypass：`lpdead_item_pages < 2% × rel_pages 且 TidStore < 32MB`（`BYPASS_THRESHOLD_PAGES`，vacuumlazy.c:187, 2448-2450）——避免"HOT 表偶发一两个死元组也触发全索引扫"的不连续抖动。

**阶段五：收尾**。截断尾页 `lazy_truncate_heap`（vacuumlazy.c:910-911, 3164）：先 `should_attempt_truncation`（3144，可释放页 ≥ max(1000 页， 1/16 表) 才值得，169-170 两个常量），再以 AccessExclusiveLock 从尾部倒扫 `count_nondeletable_pages`（3295）找最后一个非空页，`smgrtruncate` 收回磁盘。锁拿不到（等 5 秒×重试上限）就放弃截断—— truncate 对业务是纯收益，不值得阻塞。最后 `vac_update_relstats`（vacuumlazy.c:971 → vacuum.c:1451）原子更新 pg_class 的 relpages/reltuples/relallvisible/relallfrozen/relfrozenxid（不许回退，"未来值"视为损坏重写，vacuum.c:1544-1560）。

**TidStore（radix tree）** 是 PG17 换掉老 `LVDeadItems` 定长数组的新容器：键=块号，值=页内偏移 bitmap，底层是 `lib/radixtree.h` 自适应基数树（tidstore.c:7, 99, 117-126），插入专用模式省去删除路径。同样 `maintenance_work_mem`（老实现每页最多 291 个 TID 的数组，10 亿死元组需数十 GB）现在能装数量级更多的 TID，索引扫描轮数随之骤降。

两遍之间的数据流（老教材"三阶段"在本版的落点）：

```
 阶段3 扫堆(1277)                阶段4 (2381)
 ┌─────────────────────────┐    ┌──────────────────────────────┐
 │ 每页: cleanup lock?      │    │ TidStore(块号→偏移bitmap)     │
 │  ├ yes→ lazy_scan_prune │───▶│  └→ ambulkdelete 逐索引删死TID │
 │  │     prune+冻结+记TID  │    │     (vacuumlazy.c:3036)       │
 │  └ no → lazy_scan_noprune   │  └→ 回堆: LP_DEAD→LP_UNUSED   │
 │  TID ─→ TidStore(3497)  │    │     +碎片整理(2653)            │
 └─────────────────────────┘    └───────────┬──────────────────┘
        │ 超过 max_bytes:                   ▼
        │ 中途先清一轮(1352-1372)      阶段5: FSM vacuum(1637) →
        └ bypass: <2%页且<32MB        lazy_cleanup_all_indexes(1633)
          整体跳过(2448-2450)         → truncate 尾页(910) → pg_class(971)
```

cost 延迟：`vacuum_delay_point`（vacuum.c:2481）在主循环逐页调用；累计 `VacuumCostBalance` ≥ `vacuum_cost_limit`（默认 200，vacuum.c:94）就按比例小睡：

```c
/* vacuum.c:2536-2545 */
else if (VacuumCostBalance >= vacuum_cost_limit)
    msec = vacuum_cost_delay * VacuumCostBalance / vacuum_cost_limit;
if (msec > 0) {
    if (msec > vacuum_cost_delay * 4)      /* 单次不超过 delay 的 4 倍 */
        msec = vacuum_cost_delay * 4;
    pg_usleep(msec * 1000);
}
```

默认 `vacuum_cost_delay = 0`：手工 VACUUM 不限速（vacuum.c:93），autovacuum 默认 2ms（guc_parameters.dat:219）。并行 vacuum 时改为共享配额均摊（vacuum.c:2532-2536）；failsafe 触发后立即关闭限速（vacuumlazy.c:2947-2948）。buffers 走 256KB 环形 `BufferAccessStrategy` 防 buffer pool 污染（与 B 章呼应）。

## 3. 页级 prune 专节：HOT 链的就地瘦身

VACUUM 对堆页不是逐元组删除，而是"整页 HOT 链剪枝 + 冻结"一次完成：`lazy_scan_prune`（vacuumlazy.c:2033）组装参数后调 `heap_page_prune_and_freeze`（pruneheap.c:1117），选项为 `HEAP_PAGE_PRUNE_FREEZE | HEAP_PAGE_PRUNE_SET_VM`（vacuumlazy.c:2041-2048）；无索引表再加 `HEAP_PAGE_PRUNE_MARK_UNUSED_NOW`，死项当场回收、无需第二遍（vacuumlazy.c:2057）。

**被动触发路径**（非 VACUUM）：DML 访问页时 `heap_page_prune_opt`（pruneheap.c:271）按三条件启发式判断：

```c
/* pruneheap.c:287,297,310-315 */
prune_xid = PageGetPruneXid(page);            /* 页头提示: 曾有可剪的更新链 */
if (!GlobalVisTestIsRemovableXid(vistest, prune_xid, true))
    return;                                    /* 提示 xid 还不能判死 → 不必试 */
minfree = RelationGetTargetPageFreeSpace(relation, HEAP_DEFAULT_FILLFACTOR);
minfree = Max(minfree, BLCKSZ / 10);
if (PageIsFull(page) || PageGetHeapFreeSpace(page) < minfree)  /* 页满才剪 */
```

即：页头 `pd_prune_xid` 有提示、且该 xid 已"可判定删除"、且页满或空闲低于 fillfactor 目标。拿 `ConditionalLockBufferForCleanup` 失败就放弃（不阻塞业务）；剪完若页新变 all-visible，顺手记一次 FSM（pruneheap.c:355-360），防止 VACUUM 之后跳过该页导致 FSM 过期。

**四种处置**由 `heap_prune_chain`（pruneheap.c:1511）沿 HOT 链遍历决定，先记入 `PruneState` 的三个数组（redirected/nowdead/nowunused，pruneheap.c:79-85），最后在临界区一次执行、单条 WAL 落盘：

| 处置 | 记录函数 | 行号 | 含义 |
|---|---|---|---|
| REDIRECT | heap_prune_record_redirect | pruneheap.c:1736 | 链根仍在、索引 TID 指向根：根改为指向链内最新版本（索引零维护） |
| DEAD | heap_prune_record_dead | pruneheap.c:1767 | 元组死但索引可能还引用：标 LP_DEAD，TID 交给 VACUUM 删索引后再回收 |
| UNUSED | heap_prune_record_unused | pruneheap.c:1828 | 无索引表(mark_unused_now)或索引已清：行指针立即回收复用 |
| 冻结 | （随页冻结计划） | pruneheap.c:1117 起 | 幸存元组 xid < FreezeLimit 的顺带冻结，与 prune 同一条 WAL |

可见性判据是 `heap_prune_satisfies_vacuum`（pruneheap.c:1428），基于 F 章 `HeapTupleSatisfiesVacuum`（heapam_visibility.c:1100）的五态输出：HEAPTUPLE_DEAD（删）/ LIVE / RECENTLY_DEAD（还可能有快照要读→不能删，heapam.h:138-142）等。DEAD 与 RECENTLY_DEAD 的分界线正是 OldestXmin——这就是 §2 说的"VACUUM 用什么快照"的最终答案：**不是某个快照，而是所有快照的下确界 OldestXmin**。

**与索引的关系**是本节核心：三种处置的分界完全取决于"这条死元组是否仍被索引引用"。HOT 更新（heapam.c:4068-4077：新版本落同一页 `newbuf == buffer` 且 `!bms_overlap(modified_attrs, hot_attrs)` 索引列未动；README.HOT:34-62）让整条链只有一个索引入口（链根），因此 HOT 链可以整链 REDIRECT/UNUSED，索引零维护；非 HOT 死元组才需要把 TID 交给 TidStore、去每个索引里逐条删——索引越多，第二遍越贵，这就是"I 章索引膨胀"的运维面。

WAL：`log_heap_prune_and_freeze`（pruneheap.c:2589）按调用动机发三种 opcode：`XLOG_HEAP2_PRUNE_ON_ACCESS/_VACUUM_SCAN/_VACUUM_CLEANUP`（pruneheap.c:2733-2739；heapam_xlog.h:60-62，三者内容相同只用于调试区分）。注意 **PG17 起 freeze 不再有独立 WAL 记录**：旧 `XLOG_HEAP2_FREEZE_PAGE` 被并入 PRUNE 记录的 freeze plan 结构（`xlhp_freeze_plans`，heapam_xlog.h:383-400，注释明说"as of PostgreSQL 17, ... replace the separate XLOG_HEAP2_FREEZE_PAGE records"）。

## 4. 冻结专节：把 XID 从元组头抹掉

**relfrozenxid 语义**：pg_class 里的"本表所有元组头中可能存在的最老（未冻结）XID"。VACUUM 的冻结产出就是推进它：aggressive VACUUM 必须保证扫完后 NewRelfrozenXid ≥ FreezeLimit（vacuumlazy.c:923-935 断言），否则——比如跳过了 all-visible 页区间——只能把 NewRelfrozenXid 置回 InvalidTransactionId 放弃推进（vacuumlazy.c:924-935）。datfrozenxid 是全库各表最小值，由 `vac_update_datfrozenxid`（vacuum.c:1634）顺序扫 pg_class 取 min 后更新 pg_database。

冻结判据在 `heap_prepare_freeze_tuple`（heapam.c:7271，调用方先保证该元组不是 HEAPTUPLE_DEAD）：

```c
/* heapam.c:7294-7300 (xmin 部分) */
if (TransactionIdPrecedes(xid, cutoffs->relfrozenxid))
    ereport(ERROR, ... "found xmin %u from before relfrozenxid %u"); /* 数据损坏 */
/* Will set freeze_xmin flags in freeze plan below */
freeze_xmin = TransactionIdPrecedes(xid, cutoffs->OldestXmin);
```

即 **xmin < OldestXmin（已提交到人人可见）就值得冻结**；而"这页是否必须冻结"由 `heap_tuple_should_freeze`（heapam.c:8090）按 **xid < FreezeLimit** 判定（任一元组命中即 `pagefrz->freeze_required = true`，heapam.c:7529-7536）。两个 cutoff 的关系由 vacuum.c:1213-1222 保证：`freeze_min_age ≤ autovacuum_freeze_max_age/2` 且 `FreezeLimit ≤ OldestXmin`——冻一次管很久，避免同一页反复重写。xmin/xmax 若早于 relfrozenxid 直接报数据损坏（heapam.c:7294-7297, 7465-7468）：说明水位管理出了 bug。

**infomask 变化**（这是现代冻结与"老教材"最大的差异）：冻结并不把 xmin 存储值改成 2，而是：

1. freeze plan 设置 `frz->t_infomask |= HEAP_XMIN_FROZEN`（heapam.c:7449-7452）；`HEAP_XMIN_FROZEN` 定义为 `HEAP_XMIN_COMMITTED|HEAP_XMIN_INVALID` 两位置 1（htup_details.h:206）。
2. freeze_xmax 路径把 xmax 字段重写为 `InvalidTransactionId`、清掉全部 HEAP_XMAX_BITS 与 HEAP_KEYS_UPDATED/HEAP_HOT_UPDATED（heapam.c:7491-7502, 7514）。
3. `heap_execute_freeze_tuple`（src/include/access/heapam.h:533-543）在持有排他页锁的临界区里一次性落盘：`HeapTupleHeaderSetXmax(tuple, frz->xmax)` + 整体替换 t_infomask/t_infomask2。
4. 读侧 `HeapTupleHeaderGetXmin` 看到 FROZEN 位就返回常数 `FrozenTransactionId`（=2，htup_details.h:329-333；transam.h:33）——存储字段实际是什么已无关紧要。

**MultiXact 冻结的特殊性**（`FreezeMultiXactId`，heapam.c:6915，出路枚举注释 6871-6890）：xmax 是 MultiXactId 时不能清零了事——多事务共享锁/更新语义必须保真。四条出路：

- `FRM_INVALIDATE_XMAX`：纯锁 multi 且全员结束 → 清 xmax、强制本页冻结（heapam.c:6939, 6967）；
- `FRM_RETURN_IS_XID`：提取 updater 成员 XID 作为新 xmax（锁成员可丢、更新语义不能丢，heapam.c:6990-7010 附近）；
- `FRM_RETURN_IS_MULTI`：仍有 ≥2 个幸存成员 → **分配新 MultiXactId** 携带他们。注释强调 VACUUM 里应尽量避免分配新 multi——relminmxid 只有 VACUUM 能推进，在这里分配新 multi 有自噬风险（heapam.c:6862-6865）；
- `FRM_NOOP`：还没到 MultiXactCutoff，暂不动，但要回拨"no freeze"水位跟踪。

任何非 NOOP 路径都强制 `freeze_required`（heapam.c:6939-7015 多处）——因为 relminmxid 推进的前提是页内再无老 MXID。MultiXact 有独立水位 `autovacuum_multixact_freeze_max_age = 4 亿`（guc_parameters.dat:193）与成员表空间水位 `MULTIXACT_MEMBER_LOW_THRESHOLD = 20 亿`（multixact.c:99）——2013 年 PG 9.3 的成员表膨胀事故（版本停更引发的全网 VACUUM 灾难）催生了这一整套机制。

CLUSTER 等自带 WAL 的调用方走免 WAL 的 `heap_freeze_tuple`（heapam.c:7626-7661）；VACUUM 的 freeze 则并入 §3 的 PRUNE WAL 记录，一条记录同时完成 prune+freeze+VM 更新。

## 5. wraparound 专节：32 位 XID 的三级防御

XID 是 uint32（transam.h:35 `MaxTransactionId 0xFFFFFFFF`），比较是模 2^31 的环形比较。XID 空间是**循环使用的**：只要所有"过去的 XID"都冻结了，绕圈回来重用的序号不会与历史冲突。防线由四个水位构成（`SetTransactionIdLimit`，varsup.c:367，每次 `vac_update_datfrozenxid` 后重算）：

```c
/* varsup.c:384,400,414,437 */
xidWrapLimit = oldest_datfrozenxid + (MaxTransactionId >> 1); /* 危险半圈 ≈21亿 */
xidStopLimit = xidWrapLimit - 3000000;    /* 拒绝分配线: 留 300 万给 DBA 抢救 */
xidWarnLimit = xidWrapLimit - 100000000;  /* 大声警告线: 剩 1 亿(油表 5% 比喻) */
xidVacLimit  = oldest_datfrozenxid + autovacuum_freeze_max_age; /* 强制AV线: 2亿 */
```

环形空间上四个水位的位置关系（值随 oldest_datfrozenxid 漂移，间距恒定）：

```
        ◀── 2 亿 ──▶◀──── 8 亿 ────▶◀──── 11 亿 ───▶◀─ 300 万 ─▶
 xidVacLimit      xidWarnLimit            xidStopLimit   xidWrapLimit
 (强制AV)          (大警告)                 (拒发XID)      (数据丢失点)
    │                                                              │
 oldest_datfrozenxid ────── MaxTransactionId>>1 ─────────────────▶┤
        └── 只要这里随每次 VACUUM 前进，整条防线就跟着前进 ──────────┘
```

三级防御全部落在发号器 `GetNewTransactionId`（varsup.c:63）里：

1. **warning**：xid ≥ xidWarnLimit 后，每次分配 XID 打 WARNING "database must be vacuumed within N transactions" 并给出剩余百分比（varsup.c:168-185）。注释明说这个阈值故意不可配置——"你若懂配置就不会落到这一步"（varsup.c:409-414）。
2. **anti-wraparound autovacuum**：xid ≥ xidVacLimit（默认落后 2 亿，guc_parameters.dat:159）即触发。`SetTransactionIdLimit` 检测到已越线就 `SendPostmasterSignal(PMSIGNAL_START_AUTOVAC_LAUNCHER)`（varsup.c:455-459）；运行期发号器每 65536 次分配重发一次信号（varsup.c:148-150），autovacuum 每清完一个最老库就再拉起下一轮。autovacuum 的调度器也独立比较：`relfrozenxid < recentXid - freeze_max_age` 即强制 vacuum，无视 reloptions 开关与死元组阈值（autovacuum.c:3149-3155），此类任务带 `is_wraparound` 标记、用 VACOPT_SKIP_LOCKED 跳过锁冲突表、不参与 cost 均摊（autovacuum.c:2932, 3088-3092）——救命优先于礼貌。
3. **拒绝生成 XID**：xid ≥ xidStopLimit 直接 ERROR "database is not accepting commands that assign new transaction IDs to avoid wraparound data loss"（varsup.c:152-167）。只读查询尚可，写事务全部失败；单用户模式是最后的逃生通道（varsup.c:107-109 注释）——300 万余量就是为 DBA 手工抢救准备的。

水位源头是 `pg_database.datfrozenxid`：VACUUM 收尾 `vac_update_datfrozenxid`（vacuum.c:1634）扫本库 pg_class 取最小 relfrozenxid → 更新 pg_database → `vac_truncate_clog`（vacuum.c:1855）扫全部 pg_database 取最小值，依次调 `SetTransactionIdLimit`（varsup.c:367）刷新四水位、`AdvanceOldestClogXid`（varsup.c:350）放行 clog 截断（卷一 04 章闭环）。**任何一个库、任何一张表不 VACUUM，三级防线就整体前移**；"未来值"（pg_upgrade bug 曾产生）会让整个流程直接放弃（vacuum.c:1794-1800, 1905-1920），宁可不绝不冒险错截 clog。

## 6. 自动化专节：autovacuum launcher/worker 与 cost 配额

autovacuum 是 postmaster 之下的 **launcher/worker 双进程模型**（autovacuum.c:30-60 头注释）：launcher 常驻、不连用户库；worker 每次连一个库、逐表事务化工作。worker 启动失败只可能是暂时性的（fork 失败等），launcher 收到通知后按计划重试；worker 干完发 SIGUSR2 唤醒 launcher 派下一个（autovacuum.c:38-42）。

- **launcher**（`AutoVacLauncherMain`，autovacuum.c:406）：维护按库排班的数据库链表 `rebuild_database_list`（autovacuum.c:926），把 `autovacuum_naptime`（默认 60s，guc_parameters.dat:210）**均摊**到各库的下一次触发时间（autovacuum.c:1076，`1000.0 * naptime / nelems`），保证 N 个库在 naptime 内轮询一遍；主循环 `launcher_determine_sleep` 算小睡时长（autovacuum.c:842, 852/874）→ `WaitLatch` → 醒来 fork worker（605-610 应急模式：autovacuum 被关时仍会派 worker 处理 wraparound 紧急事务）。
- **worker**（`AutoVacWorkerMain`，autovacuum.c:1413）：强制关闭 statement_timeout 等超时、锁隔离级别 read committed（1419-1439 的覆盖设置）→ `do_autovacuum`（autovacuum.c:1962）遍历 pg_class → 逐表 `table_recheck_autovac`（autovacuum.c:2804）重新确认（防与其他 worker 撞车）→ `autovacuum_do_vac_analyze`（autovacuum.c:2535, 3328）调 `vacuum()`。单表失败不终止：PG_CATCH 里 abort 后继续下一张表（2503-2520）。
- **触发公式**（`relation_needs_vacanalyze`，autovacuum.c:3050；公式在 3251-3271，`vactuples` 取自 pgstat 的 dead_tuples）：

```c
/* autovacuum.c:3251-3253,3263 */
vacthresh = (float4) vac_base_thresh + vac_scale_factor * reltuples;
if (vac_max_thresh >= 0 && vacthresh > (float4) vac_max_thresh)
    vacthresh = (float4) vac_max_thresh;          /* 上限封顶, 防大表永不触发 */
...
if (av_enabled && vactuples > vacthresh) *dovacuum = true;
```

默认即 `50 + 0.2 × reltuples`（autovacuum_vacuum_threshold=50、scale_factor=0.2，guc_parameters.dat:271,287）。insert-only 表另有 insert threshold（默认 1000+0.2×reltuples，按 relallfrozen 折算"活跃区"占比，autovacuum.c:3237-3253, 3266-3271）。relfrozenxid 年龄 > freeze_max_age 则 `force_vacuum=true` 绕过一切开关（3149-3161）。PG18 还引入调度评分（scores->vac/xid/mxid 加权取 max，3199-3260）供 launcher 跨表排序优先级。

- **cost 限速与 IO 配额**：worker 默认 delay 2ms（guc_parameters.dat:219）、limit 继承 vacuum_cost_limit=200；表级 reloptions（autovacuum_vacuum_cost_delay/limit）覆盖时退出全局均摊 `at_dobalance=false`（autovacuum.c:3088-3092）。buffers 用环形策略限 IO；failsafe 触发后放弃 ring 用满 shared buffers、停止限速（vacuumlazy.c:2903-2950），这是"宁快勿死"的兜底。
- **failsafe**：扫描中每 `FAILSAFE_EVERY_PAGES` 页查 `vacuum_xid_failsafe_check`（vacuumlazy.c:1340-1344 → vacuum.c:1294）：relfrozenxid 落后超过 `Max(vacuum_failsafe_age=16 亿, freeze_max_age×1.05)`（vacuum.c:1309；默认 guc_parameters.dat:3387）就警告、放弃索引清理/截断，一门心思赶冻结。autovacuum 调度侧配合地用幂律放大"最老表"的优先分（autovacuum.c:3180-3199）。

## 7. 与前作对照

- **LevelDB compaction vs VACUUM**：两者都在还"空间债"，但 LevelDB compaction 是 LSM 的结构性例行公事（memtable 满即触发、无用户语义），VACUUM 还额外还**可见性债**（clog 截断、standby 回放）与 **wraparound 债**（32 位环形序号）——后两债在 LevelDB 中根本不存在（无跨事务 XID 语义、序号 64 位单调）。另一差异：compaction 重写 SST 时顺路丢墓碑、代价摊平；lazy VACUUM 原地整理但不搬活元组（避免整表重写的缓存污染），整表重写的活留给 VACUUM FULL/CLUSTER。
- **Git gc 的宽限删除 vs PG 的保守冻结**：git gc 删除 unreachable 对象前有 `gc.pruneExpire`（默认 2 周）宽限期，与 PG 等 OldestXmin 走光是同构的 grace-period 思想：都拒绝"立刻回收可能仍被引用的东西"。差别在宽限的度量：git 用**墙钟时间**，PG 用**事件水位**（XID/快照地平线），且 PG 的冻结还必须维护环形序的数学性质——不能像 git 那样物理删除，只能改写元数据（FROZEN 位）使 XID 序号可安全绕圈复用。
- **Redis 惰性删除 vs 页级 prune**：Redis 的 lazy free 与 PG 的 on-access prune（pruneheap.c:271，访问页时顺带剪枝）都是"把回收代价摊进日常读写"。差异：Redis 面向键整体删除、无并发可见性判定；PG 面向页内 HOT 链做局部手术，且必须为此写 WAL（XLOG_HEAP2_PRUNE_*）保证副本一致——standby 还会按记录里的 latestRemovedXid 推迟回放以保护本机查询。Redis 的实时性换掉的是这份严谨。

## 8. 设计动机

- **为什么旧版本就地留？** 就地 MVCC 的收益是读不加锁、回滚零代价：旧版本本身就是 undo 日志。代价是空间债必须有人还。PostgreSQL 选择"独立后台进程异步还债"，而不是 Oracle 式回滚段同步还债（把写放大塞进写路径关键区，且回滚段耗尽会让大事务直接报错失败）；异步方案的代价就是把"还债失败"变成 wraparound 停机这种运维事故——两种毒药选一种，PG 选了可运维的那杯。
- **为什么 freeze 要重写元组头？** 32 位 XID 的"年龄"没有绝对零点，唯一永不过期的值是"非 XID"（FrozenTransactionId=2/Invalid=0，transam.h:31-33）。把"这行永远可见"从"查询 clog"改写成"元组头内自描述"（HEAP_XMIN_FROZEN 位），等价于把判定信息从共享资源（clog 页）搬进行数据——此后 clog 页可截断、序号可安全重用。本质是：用一次性的页重写（冻结），买断整个集群 32 位序号的无穷寿命。
- **为什么 autovacuum 是进程而不是后台线程？** 沿袭卷一 01 章 process 架构的三个硬理由：(1) worker 需要独立快照、内存上下文与信号处理，postmaster 的 fork/监管/崩溃隔离天然按进程设计（worker 崩溃不影响 launcher 与其他 worker，autovacuum.c:30-38）；(2) 每个 worker 自持 BufferAccessStrategy 环与 cost 配额，进程边界让隔离成为默认而非约定；(3) 历史上 Windows 线程化路线被评估后放弃——postmaster 的 SIGQUIT 全家桶与 per-thread 状态在跨平台上并不划算。
- **为什么死元组收集换成 TidStore/radix tree？** 老实现按"每页一个 291 槽数组"记账，存储密度极低，10 亿死元组远超 maintenance_work_mem，只能靠"收集→清理→再收集"多轮循环（每轮多一次全索引扫描）。radix tree 按块号前缀压缩、每块一个偏移 bitmap（tidstore.c:7），同内存容量提升数量级，使"一次扫描一轮清完"成为常态，索引重复扫描退化为兜底路径（vacuumlazy.c:1352-1372）。

## 9. FAQ 素材与深挖

FAQ 素材：
1. VACUUM 会锁表吗？lazy VACUUM 只持 ShareUpdateExclusiveLock，DML 可并发；仅截断尾页时要短暂 AccessExclusiveLock，拿不到就放弃（vacuumlazy.c:3164-3210）。VACUUM FULL 才是整表重写。
2. autovacuum 何时触发？`threshold + scale_factor × reltuples`，默认 50+0.2×reltuples（autovacuum.c:3251-3263）；insert-only 表另有 insert threshold；relfrozenxid 年龄超限则无条件强制。
3. 长事务为什么危险？它的 xmin 抬高所有人的 OldestXmin（procarray.c:1944）——死元组删不掉（债1）、clog 不能截（债2）、冻结水位不动（债3），三重债同时停止还款。
4. "database is not accepting commands..."怎么救？xidStopLimit 触发（varsup.c:152-167）；单用户模式对最老库跑 VACUUM，或处理老的 prepared tx / 弃用复制槽。
5. relfrozenxid/datfrozenxid 是什么？表内/全库最老未冻结 XID（vacuum.c:1634,1855）；它们是 clog 截断与 wraparound 水位的共同输入，监控年龄是 PG 运维第一要务。
6. frozen 行的 xmin 为什么显示 2？读侧看到 HEAP_XMIN_FROZEN 位就返回 FrozenTransactionId（htup_details.h:329-333），存储字段已是 InvalidTransactionId。
7. HOT 是什么、为什么重要？同页更新且未动索引列（heapam.c:4068-4077）；HOT 链整链 prune、索引零维护；fillfactor 留白就是为 HOT 留的。
8. vacuum_cost_delay 手工为什么默认 0？手工 VACUUM 假设 DBA 自排期；autovacuum 默认 2ms 限速保护业务（guc_parameters.dat:219），且表级可覆盖。
9. failsafe 是什么？16 亿年龄兜底（vacuum.c:1294,1309）：宁可留着死索引条目也要赶完冻结，避免撞 xidStopLimit 停机。
10. MultiXact 为什么也要防 wraparound？MXID 同样 32 位、relminmxid 只有 VACUUM 能推进（heapam.c:6915 起）；9.3 时代成员表膨胀事故后有独立水位 4 亿（guc_parameters.dat:193）与 20 亿成员上限（multixact.c:99）。

深挖：
1. aggressive 与否的本质：能否跳过 all-visible 页（SKIP_PAGES_THRESHOLD=32，vacuumlazy.c:209, 1693-1698）。跳过省 IO 但卡住 relfrozenxid，因此 `skippedallvis` 时放弃推进水位（vacuumlazy.c:924-935）——"省下的 IO 用冻结进度偿还"。
2. eager scanning（PG18 新增）：对 all-visible-but-not-all-frozen 页按失败率上限顺带扫描冻结（vacuumlazy.c:1490-1545；`vacuum_max_eager_freeze_failure_rate` 默认 0.03，guc_parameters.dat:3408-3417），把 aggressive vacuum 的出现频率摊薄到日常。
3. 并行 vacuum 的 cost 均摊：多 worker 共享 VacuumSharedCostBalance，`compute_parallel_delay` 按份额 sleep（vacuum.c:2532-2536）；autovacuum 也可配 parallel workers（autovacuum.c:2948-2968），但 ≥2 个索引才启用（vacuumlazy.c:3449-3452）。
4. prune 与 FPI：开 checksums 后改动页前必须发全页镜像；`did_tuple_hint_fpi` 追踪可见性提示位引发的 FPI（pruneheap.c:1183-1186），冻结计划据此决定是否值得整页冻结。
5. standby 可见性：PRUNE 记录携带 latestRemovedXid，standby 据此判断本机查询是否可能读到被回收元组、必要时推迟回放（pruneheap.c:1767 记录链路；heapam_xlog.c:67 起回放逻辑）——vacuum 与长查询在备机的冲突在此调和。

## 10. 写作要点速查表

| 事实 | 位置 |
|---|---|
| vacuum() 入口/禁事务块 | src/backend/commands/vacuum.c:496（513） |
| OldestXmin = GetOldestNonRemovableTransactionId | vacuum.c:1161；procarray.c:1944 |
| FreezeLimit/减半规则/≤OldestXmin | vacuum.c:1213-1222 |
| aggressive 判定(relfrozenxid vs 0.95×max_age) | vacuum.c:1249-1268 |
| failsafe 检查(16 亿/1.05×max_age) | vacuum.c:1294,1309 |
| vac_update_datfrozenxid → vac_truncate_clog | vacuum.c:1634,1855；vacuum() 末尾调用 vacuum.c:710 |
| vacuum_delay_point/单次≤4×delay | vacuum.c:2481,2536-2545；delay=0/limit=200 vacuum.c:93-94 |
| heap_vacuum_rel 五阶段行号链 | vacuumlazy.c:624（cutoffs 801/803/806-807，容器 863，扫描 880，截断 910-911，pg_class 971） |
| lazy_scan_heap 主循环/每 N 页查 failsafe | vacuumlazy.c:1277（1340-1344） |
| TidStore 超限中途清理 | vacuumlazy.c:1352-1372 |
| 跳页回调/阈值 32 页 | vacuumlazy.c:1660,1693-1698；209 |
| lazy_scan_prune→dead_items_add | vacuumlazy.c:2033,2119 |
| lazy_vacuum 两遍/bypass(2%页+32MB) | vacuumlazy.c:2381,2448-2450；187 |
| truncate 条件(1000 页或 1/16) | vacuumlazy.c:3144,3164,169-170 |
| dead_items_alloc/TidStoreCreateLocal(radix) | vacuumlazy.c:3438,3497；tidstore.c:7,162 |
| heap_page_prune_opt 触发三条件 | pruneheap.c:271,287,297,310-315 |
| heap_prune_and_freeze/WAL 三 opcode | pruneheap.c:1117,2589,2733-2739；heapam_xlog.h:60-62 |
| REDIRECT/DEAD/UNUSED | pruneheap.c:1736,1767,1828 |
| HOT 判定(同页+索引列未动) | heapam.c:4068-4077；README.HOT:34-62 |
| heap_prepare_freeze_tuple(xmin<OldestXmin) | heapam.c:7271,7300；HEAP_XMIN_FROZEN 7449-7452 |
| heap_tuple_should_freeze(xmin<FreezeLimit) | heapam.c:8090；freeze_required 7529-7536 |
| heap_execute_freeze_tuple(xmax 置 Invalid) | src/include/access/heapam.h:533-543 |
| HEAP_XMIN_FROZEN=COMMITTED\|INVALID；GetXmin→2 | htup_details.h:206,329-333；transam.h:31-35 |
| FreezeMultiXactId 四出路(FRM_*) | heapam.c:6915,6871-6890 |
| wraparound 四水位(半圈/300 万/1 亿/max_age) | varsup.c:384,400,414,437 |
| 发号器三级防御(强制AV/警告/拒绝) | varsup.c:63,114,148-150,152,168 |
| launcher/worker/naptime 60s | autovacuum.c:406,1413,842；guc_parameters.dat:210 |
| 触发公式 50+0.2×reltuples | autovacuum.c:3050,3251-3263 |
| freeze_max_age=2 亿/mx=4 亿/failsafe=16 亿 | guc_parameters.dat:159,193,3387 |
| PRUNE WAL 取代 FREEZE_PAGE(PG17) | src/include/access/heapam_xlog.h:399-400 |
