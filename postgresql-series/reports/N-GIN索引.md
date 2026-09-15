# N - GIN 索引：通用倒排索引深读

> PostgreSQL 源码 commit `8c7a74c`（shallow clone）。所有行号均以该 commit 实际核对。
> 本文是《Prometheus… PG 深读》卷四第 1 章：卷二讲过 B-tree（`src/backend/access/nbtree/`），卷三讲过 WAL/MVCC；本章讲全文检索/数组/JSONB 背后的倒排索引 GIN（`src/backend/access/gin/`）。

---

## 1. 全景：GIN 的倒排结构

GIN = Generalized Inverted Index（官方 README 开篇即言"should be considered as a genie, not a drink"，`src/backend/access/gin/README:8-9`）。倒排索引存的是 `(key, posting list)` 对：key 是从被索引项中提取的元素（数组元素、tsvector 词位、trigram），posting list 是包含该 key 的堆行 TID 集合（`README:17-19`）。

物理上，一个 GIN 索引由四类页面组成（`README:95-105`、`src/include/access/ginblock.h:52-53`）：

- **metapage**（块 0，`GIN_METAPAGE_BLKNO`）：元数据 `GinMetaPageData`（`ginblock.h:55-101`），含 pending list 的 head/tail 指针、`nPendingPages`/`nPendingHeapTuples` 计数、planner 统计 `nEntries`、格式版本 `ginVersion`（当前 `GIN_CURRENT_VERSION=2`，`ginblock.h:103`）。
- **entry tree**（B-tree，根固定块 1）：key 本身构成 B-tree。叶子 tuple = key + 内嵌 posting list 或指向 posting tree 的根块号。
- **posting tree**：某 key 的 TID 多到塞不进一个 entry 页时溢出成的独立 B-tree（key 就是 TID）。
- **pending list**（fastupdate 开启时）：单向链表页（`GIN_LIST` 标志，`ginblock.h:45`），暂存尚未合并进 entry tree 的插入。

```
                        metapage (blk 0)
        head ─────────────┐  ┌─────────── tail
                          │  │             tailFreeSize
                          ▼  ▼
   pending list:  [LIST p3]→[LIST p7]→[LIST p9]   ← fastupdate 暂存区
                                                       │ ginInsertCleanup() 合并刷出
                                                       ▼
   entry tree (B-tree over keys):                 metapage.head/tail
              root(blk 1)
             /        \
        内部页        内部页          ← (P_i, K_{i+1}) 打包 (README:218-238)
        /   \        /   \
   叶子     叶子   叶子   叶子
    │key:"cat"                │key:"dog"
    │t_tid 被滥用:             │t_tid = posting tree 根块号
    │  posting list(内嵌,      │  offset 槽位=GIN_TREE_POSTING 魔数
    │  varbyte 压缩 TID 差值)          │
    ▼                                 ▼
  TID1,TID2,TID3...            posting tree (B-tree over TID)
                                root → 内部(PostingItem: child+rightBound)
                                     → 叶子(多段压缩 posting list)
```

要点（全部来自 README 1-200 行的设计说明 + 代码核对）：

1. **entry tree 没有删除操作**：语料中不同单词集合变化极慢，从不删除 entry 极大简化并发（`README:27-31`）；叶子页也因而不需要独立 high key——最右 tuple 充当（`README:312-314`）。
2. **叶子 tuple 的 t_tid 字段被复用**（`README:149-199`）：posting list 情形下 block 号存"posting list 在 tuple 内的偏移"、offset 存"TID 个数"；posting tree 情形下 block 号存树根块号、offset 存魔数 `GIN_TREE_POSTING`。判别用宏 `GinIsPostingTree(itup)`。
3. **支持 NULL/空项占位**：null category 字节区分"普通 null key/零 key 项/null 项"三类占位 entry，保证全索引扫描等场景语义正确（`README:122-135`）。
4. **多列索引**：key tuple 里额外带 int2 列号，即 `(attnum, key)`（`README:113-120`；运行期由 `ginExtractEntries` 前的 `gintuple_get_attrnum` 解析）。

关键访问宏/结构：
- 页标志位 `GIN_DATA/GIN_LEAF/GIN_DELETED/GIN_META/GIN_LIST/GIN_LIST_FULLROW/GIN_INCOMPLETE_SPLIT/GIN_COMPRESSED`（`ginblock.h:41-49`）。
- 压缩 posting list 结构 `GinPostingList{first(未压缩首 TID), nbytes, bytes[]}`（`ginblock.h:336-341`）。
- posting tree 内部页项 `PostingItem{child_blkno, key(右边界 TID)}`（`ginblock.h:185-188`）。
- entry tuple 最大尺寸 `GinMaxItemSize`：保证每页至少放 3 个 item（`ginblock.h:249-256`）。

支持函数（amproc）共 7 个：compare/extractValue/extractQuery/consistent/comparePartial/triConsistent/options（`src/include/access/gin.h:24-31`），全部挂在 `GinState` 的 FmgrInfo 数组上（`src/include/access/gin_private.h:81-87`）。

---

## 2. 插入专节：pending list 的暂存与刷出

### 2.1 两条插入路径

`gininsert()`（`src/backend/access/gin/gininsert.c:865-918`）按 `GinGetUseFastUpdate(index)` 分叉（reloption `fastupdate`，默认 `GIN_DEFAULT_USE_FASTUPDATE=true`，`gin_private.h:34-40`）：

```c
// gininsert.c:892-905
if (GinGetUseFastUpdate(index))
{
    GinTupleCollector collector;
    memset(&collector, 0, sizeof(GinTupleCollector));
    for (i = 0; i < ginstate->origTupdesc->natts; i++)
        ginHeapTupleFastCollect(ginstate, &collector, ...);
    ginHeapTupleFastInsert(ginstate, &collector);
}
else
{
    for (i = 0; i < ginstate->origTupdesc->natts; i++)
        ginHeapTupleInsert(ginstate, ..., ht_ctid);   // 每个 key 一次 ginEntryInsert
}
```

- **slow path**：`ginHeapTupleInsert` → `ginEntryInsert`（`gininsert.c:851-862`），每个 key 一次 B-tree 下行。
- **fast path**：`ginHeapTupleFastCollect`（`ginfast.c:483-545`）为每个 key 造临时 IndexTuple（posting 信息直接放 `itup->t_tid = *ht_ctid`，`ginfast.c:539-542`），再由 `ginHeapTupleFastInsert`（`ginfast.c:219`）一次性把整行所有 key 追加到 pending list 尾部。

### 2.2 追加进 pending list（ginHeapTupleFastInsert）

- 若收集器总大小 `sumsize + ntuples*sizeof(ItemIdData)` 超过一页（`GinListPageSize`，`ginblock.h:328-329`），或尾页放不下，则先独立构造子链 `makeSublist`（`ginfast.c:145`，按 `GinListPageSize` 分页、打 `GIN_LIST_FULLROW` 标志）再拼接；否则直接写尾页（`ginfast.c:253-277`、`347-410`）。
- 元数据更新与链表拼接在同一 CRIT_SECTION 内，WAL 记录 `XLOG_GIN_UPDATE_META_PAGE`（`ginfast.c:436`）。
- 一个堆行的所有 entry 保证连续存放且按 `(attnum,key)` 排序——这是 pending list 扫描正确性的前提（`README:201-216`）。

### 2.3 刷出触发：fastupdate 的代价模型

```c
// ginfast.c:458-460
cleanupSize = GinGetPendingListCleanupSize(index);
if (metadata->nPendingPages * GIN_PAGE_FREESIZE > cleanupSize * (Size) 1024)
    needCleanup = true;
```

- 阈值 = reloption `gin_pending_list_limit`（GUC 同名，`gin.h:97`；per-index 覆盖逻辑在 `gin_private.h:41-47`；`GIN_PAGE_FREESIZE` 定义在 `ginfast.c:41`）。
- 触发后**当前插入事务自己**调用 `ginInsertCleanup(ginstate, false, true, false, NULL)`（`ginfast.c:470-471`）——这就是"更新代价 organic（内生化）"：刷出成本随机出现在某个普通 INSERT/UPDATE 后端里，造成延迟毛刺（文档明说可用 autovacuum 后台化来平滑，`doc/src/sgml/gin.sgml:604-613`）。
- 代价模型概括：fastupdate 把 N 行 × K 个 key 的 retail 插入摊销成"O(1) 追加 + 一次性批量合并"；合并收益主要来自同一 key 在多行重复时只搜索/插入一次（`README:101-105`）。刷出时用 `work_mem`（插入路径触发）或 `maintenance_work_mem`/`autovacuum_work_mem`（vacuum 强制路径）控制内存（`ginfast.c:816-829`）。

### 2.4 刷出主体：ginInsertCleanup

`ginInsertCleanup(ginstate, must_empty_list, fill_fsm, forceCleanup, stats)`（`ginfast.c:780-1028`）：

1. **互斥**：forceCleanup（来自 `[auto]vacuum` 或 `gin_clean_pending_list()`）用 `LockPage(index, GIN_METAPAGE_BLKNO, ExclusiveLock)` 死等；普通插入路径用 `ConditionalLockPage`，抢不到锁直接放弃——"指望并发清理者干完"（`ginfast.c:807-830`）。
2. **防追尾**：记录进入时的 tail（`blknoFinish`），新增页不处理，避免插入速度高于清理速度时无限循环（`ginfast.c:845-849,890-891`）。
3. **合并**：逐页 `processPendingPage` 把 entry 喂进 `BuildAccumulator`（红黑树式按键聚合 TID，`ginbulk.c:109/209/256/267`）；页耗尽或 `accum.allocatedMemory >= workMemory*1024` 时 flush（`ginfast.c:905-907`），对聚合后的每个 `(attnum,key,TID列表)` 调 `ginEntryInsert` 写入正式结构（`ginfast.c:929-936`）。
4. **删页**：已搬空的页由 `shiftList`（`ginfast.c:554`）批量摘链（每次至多 `GIN_NDELETE_AT_ONCE` 页）并归还 FSM。
5. 崩溃安全性：先把 posting 写进主索引、再从 pending list 删页；若中间崩溃，重放后重复 posting 无害（`ginfast.c:766-771` 注释）。
6. SQL 入口 `gin_clean_pending_list(oid)`（`ginfast.c:1034`）。

---

## 3. 查询专节：extractQuery 的多态与 consistent 回调

### 3.1 ginNewScanKey：把 ScanKey 翻译成 GinScanKey/GinScanEntry

`ginNewScanKey()`（`src/backend/access/gin/ginscan.c:267`）对每个 ScanKey 调用 opclass 的 **extractQueryFn**（7 参数，`ginscan.c:316-325`）：

```c
// ginscan.c:316-325
queryValues = (Datum *)
    DatumGetPointer(FunctionCall7Coll(&so->ginstate.extractQueryFn[...],
                  ..., skey->sk_argument,
                  PointerGetDatum(&nQueryValues),
                  UInt16GetDatum(skey->sk_strategy),
                  PointerGetDatum(&partial_matches),
                  PointerGetDatum(&extra_data),
                  PointerGetDatum(&nullFlags),
                  PointerGetDatum(&searchMode)));
```

一个查询条件被"提取"为多个 key（每个 key 一个 `GinScanEntry`）+ 搜索模式。searchMode 有四种（`gin.h:36-39`）：`DEFAULT`（正常）、`INCLUDE_EMPTY`（空项占位也命中）、`ALL`（排除式语义，如 `!<@`、纯否定 tsquery）、`EVERYTHING`（内部专用，零 key 时驱动全索引扫描，`ginscan.c:453-460`）。非法 searchMode 一律按 ALL 处理（`ginscan.c:332-334`）。extractQuery 返回 0 个 key 且模式为 DEFAULT ⇒ 立即空结果（`ginscan.c:343-351`）。

**extractQuery 的多态实现**：

| 类型 | extractValue | extractQuery | consistent/triConsistent | 位置 |
|---|---|---|---|---|
| 数组 anyarray | `ginarrayextract`：拆元素 | `ginqueryarrayextract`：按策略映射 searchMode（`&&`→DEFAULT；`@>` 空集→ALL；`<@`→INCLUDE_EMPTY；`=` 空数组→INCLUDE_EMPTY） | `ginarrayconsistent` / `ginarraytriconsistent` | `src/backend/access/gin/ginarrayproc.c:33/79/143/230`（策略映射 109-133） |
| tsvector | `gin_extract_tsvector`：逐词位 | `gin_extract_tsquery`：QueryItem 树提取 VAL 项 + partialmatch 数组 + operand 映射表进 extra_data；无必选正项（如 `!foo`）→ ALL | `gin_tsquery_consistent` / `gin_tsquery_triconsistent` | `src/backend/utils/adt/tsginidx.c:64/94/216/267`（ALL 判定 119-123） |
| text (pg_trgm) | — | `gin_extract_trgm`：串切成 trigram（LIKE/正则→带前缀标记） | `gin_trgm_consistent` / `gin_trgm_triconsistent` | `contrib/pg_trgm/trgm_gin.c:24/172/271` |

tsquery 的做法最能体现"多态"：查询树结构无法塞进 GIN 的 AND/OR 位图组合，于是 extractQuery 把**操作数图**塞进 `extra_data`，consistent 拿着 `check[]` 布尔回去重放布尔表达式语义。

### 3.2 consistent 回调：二值与三值逻辑

扫描时每个 entry 给出"当前候选 TID 是否在该 entry 的 posting 里"的布尔；一个 GinScanKey 的多个 entry 结果需要组合判定，即 consistent 回调（`src/backend/access/gin/ginlogic.c`）：

- 直接回调签名：`consistent(bool check[], strategy, query, nkeys, extra_data, recheck, queryKeys, nullFlags)`，`shimBoolConsistentFn`/`directBoolConsistentFn` 由 opclass 是否提供原生函数决定（`ginlogic.c:226-249`，`ginInitConsistentFunction`）。
- **三值逻辑**：`GinTernaryValue ∈ {GIN_FALSE, GIN_TRUE, GIN_MAYBE}`（`gin.h:71-79`）。MAYBE 出现在 lossy 位图或部分匹配时；opclass 未提供原生 triConsistent 时由 `shimTriConsistentFn` 兜底——对每个 MAYBE 输入枚举 TRUE/FALSE 组合调用布尔 consistent，全真则 TRUE、全假则 FALSE、否则 MAYBE（`ginlogic.c:137-179,148`）。三值版本的优势：partial-match（如 pg_trgm、tsquery 前缀）时能先排除候选再回表，减少 recheck。

**扫描执行（bitmap-only）**：GIN 只支持 `amgetbitmap`，`gingetbitmap()`（`src/backend/access/gin/ginget.c:1928-1979`）流程：

1. `ginNewScanKey`（`ginget.c:1940`）；
2. **先扫 pending list**：`scanPendingInsert`（`ginget.c:1835`；对 metapage 取谓词锁 `ginget.c:1852`；逐行组装 entryRes 后调用 consistent，`ginget.c:1884-1923`）。为什么先 pending 后主索引：主索引扫描期间并发 cleanup 可能把 pending 项搬进主树导致完全漏掉；反过来重复访问无害，位图会去重（`ginget.c:1947-1957` 注释，也是 GIN 无法支持 amgettuple 的原因）。
3. 再扫主索引：`startScan`（`ginget.c:608` 附近；`startScanEntry:319`，`startScanKey:507`）。
4. `scanGetItem`（`ginget.c:1300`）多 entry 归并推进，`entryGetItem`（`ginget.c:813`）区分三种 posting 来源：匹配位图（821-905）、entry 内嵌 posting list（911-933）、posting tree（936 起，`entryLoadMoreItems` 按页装载）。

**部分匹配（partial match）**：`partial_matches[i]=true` 的 entry 走 `collectMatchBitmap()`（`ginget.c:121`）：从 entry 定位处沿叶子右移，用 **comparePartialFn** 逐 key 判定（`ginget.c:193-198`：cmp==0 收集、cmp<0 继续、cmp>0 终止），把所有命中 key 的 posting 并进 `matchBitmap`（`tbm_create(work_mem*1024)`，`ginget.c:128`）。这正是 `text LIKE 'abc%'`、tsquery 前缀匹配的实现基础。pending list 里的部分匹配对应 `matchPartialInPendingList`（`ginget.c:1554`）。

---

## 4. posting tree 专节：长 posting list 的树形化

**触发点**：entry 的 TID 太多、压缩后仍超过 `GinMaxItemSize` 时，内嵌 posting list 升级为 posting tree。两个入口：

- 新 entry：`buildFreshLeafTuple`（`src/backend/access/gin/gininsert.c:298-340`）——先试压缩（`ginCompressPostingList`，`gininsert.c:309`），`nwritten != nitem` 即建树：`createPostingTree` + `GinSetPostingTree`（`gininsert.c:333-337`）。
- 旧 entry 扩容：`addItemPointersToLeafTuple`（`gininsert.c:216-288`）——新旧 TID 归并（`ginMergeItemPointers`，`gininsert.c:241-243`）后重压缩；放不下则**用旧 posting list 建树**（`createPostingTree`，`gininsert.c:270-274`），再把新增 TID 插进树（`gininsert.c:277-279`），entry tuple 只留根块号（`gininsert.c:282-283`）。

```c
// gindatapage.c:1775-1818 (节选)
BlockNumber
createPostingTree(Relation index, ItemPointerData *items, uint32 nitems,
                  GinStatsData *buildStats, Buffer entrybuffer)
{
    /* Construct the new root page in memory first. */
    tmppage = (Page) palloc(BLCKSZ);
    GinInitPage(tmppage, GIN_DATA | GIN_LEAF | GIN_COMPRESSED, BLCKSZ);
    ...
    while (nrootitems < nitems)
    {
        segment = ginCompressPostingList(&items[nrootitems],
                                         nitems - nrootitems,
                                         GinPostingListSegmentMaxSize,
                                         &npacked);
        ...
    }
```

**结构**（`README:247-275`）：
- 内部页：`PostingItem` 数组（child 块号 + 该子树右边界 TID，`ginblock.h:185-188`），页右边界存 `GinDataPageGetRightBound`（`README:240-245`）。
- 叶子页：**多段**（segment）压缩 posting list 顺序排布（每段上限 `GinPostingListSegmentMaxSize=384` 字节，`gindatapage.c:34`）。切段的目的：查找时先跳段再段内顺序解码，更新时只需重编码受影响段（`README:269-275`）。
- 插入：`ginInsertItemPointers`（`gindatapage.c:1908-1930`）循环 `ginFindLeafPage`+`ginInsertValue`，放不下即页分裂（`dataBeginPlaceToPageLeaf:448`、`dataPlaceToPageLeafSplit:1034`、分裂顶点边界计算 `dataSplitPageInternal:1252`）。与 entry tree 一样是 Lehman-Yao 右链 B-tree，但不支持反向扫描所以无 left-link（`README:306-316`；下行/右移/分裂完成逻辑在 `ginbtree.c:83 ginFindLeafPage`、`ginbtree.c:177 ginStepRight`、`ginbtree.c:672 ginFinishSplit`）。

**TID 压缩**（`README:277-304`、`src/backend/access/gin/ginpostinglist.c`）：TID 转成 43 位整数（offset 11 位 `MaxHeapTuplesPerPageBits=11`，`ginpostinglist.c:81`；`itemptr_to_uint64:87-97`），存与前驱的**差值**，varbyte 编码（`encode_varbyte:115`、`decode_varbyte:133`），首 TID 不压缩存 `GinPostingList.first`（`ginblock.h:336-341`）。解码 `ginPostingListDecodeAllSegments:297`。

---

## 5. VACUUM 联动专节：死 posting 的清理

### 5.1 ginbulkdelete

`ginbulkdelete()`（`src/backend/access/gin/ginvacuum.c:631-757`）被 VACUUM 回调，流程：

1. **第一步永远是强制清空 pending list**：`ginInsertCleanup(&gvs.ginstate, !AmAutoVacuumWorkerProcess(), false, true, stats)`（`ginvacuum.c:657-667`）。理由：pending list 里可能躺着 VACUUM 现在必须删的死 TID；`must_empty_list` 参数保证非 autovacuum 场景下彻底清空（autovacuum worker 允许残留，并发插入者不可能插入 VACUUM 需要删除的更老 TID）。
2. 从根（blk 1）下行到 entry tree 最左叶子（`ginvacuum.c:677-708`），沿 rightlink 顺序扫全部叶子：`ginVacuumEntryPage`（`ginvacuum.c:720`）对每个 entry 的 posting list 过滤死 TID。
3. 死活判定就一行：`gvs->callback(items+i, gvs->callback_state)` 为真则计 `tuples_removed`，否则保留（`ginVacuumItemPointers`，`ginvacuum.c:48-84`）。callback 即 heapam 的 `heapvacuum_rel` 侧传递的 TID 死亡判定（卷七 G 章 VACUUM 的 `vacuum_dead_tuples`）。
4. 扫叶子时顺手收集遇到的 posting tree 根（`rootOfPostingTree` 数组），叶子扫完后逐棵清理：`ginVacuumPostingTree`（`ginvacuum.c:740-744`）。

### 5.2 posting tree 的两阶段清理

`ginVacuumPostingTree`（`ginvacuum.c:471-510`）：
- **阶段一** `ginVacuumPostingTreeLeaves`（`ginvacuum.c:391-449`）：定位最左叶子后沿 rightlink 扫全部叶子，`ginVacuumPostingTreeLeaf` 删死 TID；记录是否存在空页（`GinDataLeafPageIsEmpty`）。
- **阶段二**：仅当存在空页才触发。对树根 `LockBufferForCleanup` 阻塞并发插入（`ginvacuum.c:494` 附近），`ginScanPostingTreeToDelete`（`ginvacuum.c:271`）DFS 删空页。该函数保持"当前路径所有左兄弟页排他锁"（`DataPageDeleteStack.leftBuffer`，`ginvacuum.c:125-137`），从而删页时更新 rightlink/downlink 所需页面全部已锁死，避免从右向左加锁死锁（`README:413-417`）。被删页打 `GIN_DELETED` 标志 + `GinPageSetDeleteXid`（`ginblock.h:136-137`）：不能立即复用，必须等可能已持有其引用的读者全部退出（`README:427-433`）；可复用判定 `GinPageIsRecyclable`（`ginblock.h:138` 声明）。

### 5.3 ginvacuumcleanup 与 autovacuum

- `ginvacuumcleanup()`（`ginvacuum.c:760`）：仅 ANALYZE 时（autovacuum worker 的 analyze_only）也调 `ginInsertCleanup(forceCleanup=true)` 清 pending（`ginvacuum.c:776-784`）；`stats==NULL`（即 bulkdelete 未跑过的全量 cleanup）同样先清 pending（`ginvacuum.c:790-796`）。
- 因此 **autovacuum 与 fastupdate 的关系**是：GUC `gin_pending_list_limit`（`gin.h:97`）决定前台插入触发的阈值；把该值调大 + 让 autovacuum 更频繁跑，可把刷出从普通 INSERT 后端挪进后台（`doc/src/sgml/gin.sgml:604-620`）；另有手动入口 `gin_clean_pending_list()`（`ginfast.c:1034`）。
- 注意 entry tree **永不收缩**：VACUUM 只从 posting 里删 TID，不删 key entry（`README:27-31,389-396`），这也是 `nEntries` 统计只增不减的根源（更新统计在 `ginvacuumcleanup` 重算 `idxStat`，`ginvacuum.c:798` 起）。

---

## 6. 与 B-tree 对照、设计动机与选型

| 维度 | B-tree (nbtree) | GIN |
|---|---|---|
| 键类型 | 标量、可比序；一索引值一 key | 复合值提取出的多 key（opclass `extractValue`）；opckeytype 可不同于 opcintype（`README:86-93`） |
| 重复 key | 同 key 多 TID 跨 tuple（deduplication） | 同 key 的全部 TID 聚在一个 entry 的 posting list/tree 里 |
| 匹配语义 | 比较（=、<、范围） | 仅等值 / 部分匹配（comparePartial，`README:543-545`）；组合语义交给 consistent 回调 |
| 插入代价 | 每 key 一次树内定位 | fastupdate=on：先 O(1) 追加 pending list，阈值触发批量合并（§2.3）；=off：每 key retail 插入 |
| 更新毛刺 | 平滑 | 有（pending 刷出内嵌在插入事务里，organic pending） |
| 扫描接口 | amgettuple/amgetbitmap 均可 | 仅 amgetbitmap（`gingetbitmap`，`ginget.c:1928`） |
| VACUUM | 删 index tuple、可收缩页 | 删 posting 内 TID；entry tree 不收缩；需先清 pending |
| 谓词锁 | 叶页 gap | 叶页 + posting tree 根 + **metapage**（fastupdate 插入可属于树上任何位置 ⇒ 等效全索引锁，`README:479-508`） |

**为什么全文检索选 GIN**：一个文档产生几十个词位，一个词位出现在几十万文档——正是"items 含大量 keys、keys 高度重复"的优化目标形态（`README:91-93`）。倒排后按词检索的代价与词频无关地低；GiST/tsvector 虽也可用但回表 recheck 代价高。代价是更新重、索引大。

**为什么更新代价高（organic pending）**：fastupdate 把写放大挪到了"将来某个倒霉的插入事务"：它要独占 metapage 锁、用 work_mem 聚合整个 pending list、对每个聚合 key 做 B-tree 插入（`ginfast.c:780-1028`）。此外每个查询都要**额外线性扫一遍 pending list**（`ginget.c:1957`），长 pending 直接拖慢所有读。

**什么时候轮不到 GIN（BRIN 留下一章）**：超大表上的自然序相关列（时间序列、block 范围查询）用 BRIN 只需极小索引；GIN 的强项是"一个值拆多 key + key 全局重复"，两者不在同一赛道。类似地，JSONB 的 `@>` 查询用 GIN（jsonb_ops/jsonb_path_ops），而简单的标量 WHERE 用 B-tree 更优。

---

## 7. FAQ 素材

1. **Q: GIN 里"key"和被索引列的值是什么关系？** A: opclass 用 extractValue 把列值拆成若干 key（数组元素/词位/trigram）；索引存的是 key，opckeytype 是 key 类型（`README:86-93`；`ginExtractEntries`，`ginutil.c:442`）。
2. **Q: fastupdate 到底快在哪？** A: 同一批多行重复 key 的搜索/插入被 `BuildAccumulator` 聚合成一次（`README:101-105`；聚合器 `ginbulk.c:209/267`），追加 pending list 只是写链表尾页。
3. **Q: pending list 多大时刷出？** A: `nPendingPages * GIN_PAGE_FREESIZE > gin_pending_list_limit(或 per-index 覆盖) * 1KB`（`ginfast.c:458-460`），由当前插入事务就地执行。
4. **Q: 为什么查询有时也会变慢？** A: 每个 bitmap 扫描先线性扫 pending list（`ginget.c:1957`），且 fastupdate=on 时谓词锁升级为 metapage 全索引锁（`README:501-508`）。
5. **Q: GIN 支持排序扫描/ORDER BY 吗？** A: 不支持，无 amcanorder；只有等值与部分匹配（`README:543-545`），且只有 amgetbitmap。
6. **Q: entry 会删吗？为什么？** A: 永不删除——词汇集变化慢，删 entry 的收益小、并发复杂度高（`README:27-31`）。
7. **Q: posting list 和 posting tree 怎么选？** A: 压缩后塞得进 `GinMaxItemSize` 就内嵌，否则建树（`gininsert.c:309-337`）；树上每段 384 字节独立解码（`gindatapage.c:34`）。
8. **Q: GIN 怎么处理 NULL/空数组？** A: 插入 null/empty 占位 entry（三类 category，`README:122-135`）；查询侧 `!<@`、`!foo` 等触发 `GIN_SEARCH_MODE_ALL`（`ginarrayproc.c:114-123`、`tsginidx.c:119-123`）。
9. **Q: recheck 什么时候需要？** A: consistent 只能做无损判定时 recheck=false；partial-match/lossy 位图等场景 opclass 自己置 `*recheck`（如 `ginarrayconsistent` 对 `@>` 置真）；三值 consistent 可在回表前先筛掉 MAYBE。
10. **Q: VACUUM 会缩小 GIN 索引吗？** A: 只会缩小 posting tree（两阶段删空页，`ginvacuum.c:471-510`）；entry tree 页不回收，key 数只增不减。

## 8. 深挖练习

1. **代价模型验证**：构造 100 万行 text[]，分别以 fastupdate=on/off、`gin_pending_list_limit=4MB/64KB` 批量插入，用 `pg_stat_statements` + `EXPLAIN (ANALYZE, BUFFERS)` 观察 INSERT 延迟毛刺与 `gin_clean_pending_list` 的摊销效应（对照 §2.3 的触发公式）。
2. **读 ginxlog.c**：对照 `XLOG_GIN_INSERT/UPDATE_META_PAGE/DELETE_LIST_PAGES/VACUUM_PAGE` 各记录的重放函数，验证"pending 重放幂等"的崩溃安全论证（`ginfast.c:766-771`）。
3. **三值逻辑推演**：为 `tsquery := !a & (b | c)` 手工推 `shimTriConsistentFn` 的 MAYBE 枚举路径（`ginlogic.c:137-179`），再对比 `gin_tsquery_triconsistent` 的原生短路实现（`tsginidx.c:267`）。
4. **并发实验**：两会话一扫一插，观察 `ginInsertCleanup` 的 `ConditionalLockPage` 放弃策略（`ginfast.c:827-829`）如何避免插入事务互相等待；用 `pg_locks` 抓 `GIN_METAPAGE_BLKNO` 的 page lock。
5. **对比 nbtree**：GIN 内部页 `(P_i, K_{i+1})` 打包 vs nbtree `(K_i, P_i)`+独立 highkey（`README:218-238`），思考为何 entry tree 无 highkey 仍正确（永不删除 ⇒ 最右 tuple 即上界，`README:312-314`）。

---

## 写作要点速查表

| # | 函数/常量 | 位置 | 一句话 |
|---|---|---|---|
| 1 | GinMetaPageData | src/include/access/ginblock.h:55-101 | 元页：pending head/tail、nPendingPages、nEntries、ginVersion |
| 2 | gininsert | src/backend/access/gin/gininsert.c:865 | 插入入口，fastupdate 分叉 892-905 |
| 3 | ginEntryInsert | gininsert.c:351 | slow path 单 key 插入；树化分支 375-388 |
| 4 | addItemPointersToLeafTuple / buildFreshLeafTuple | gininsert.c:216 / 298 | posting list→posting tree 升级点（270/333 createPostingTree） |
| 5 | ginHeapTupleFastInsert | ginfast.c:219 | 追加 pending list；触发判定 458-460；自清 471 |
| 6 | ginHeapTupleFastCollect | ginfast.c:483 | 临时 entry tuple，t_tid=堆 TID（539-542） |
| 7 | ginInsertCleanup | ginfast.c:780 | pending→主结构合并刷出；锁策略 807-830；flush 905-936 |
| 8 | shiftList | ginfast.c:554 | 批量摘除已刷出 pending 页 |
| 9 | ginNewScanKey | ginscan.c:267 | extractQueryFn 调用 316-325；searchMode 处理 332-351 |
| 10 | ginInitConsistentFunction | ginlogic.c:226 | bool/tri consistent 绑定；shim 枚举 148（shimTriConsistentFn） |
| 11 | collectMatchBitmap | ginget.c:121 | 部分匹配：comparePartialFn 193-198 |
| 12 | gingetbitmap / scanPendingInsert | ginget.c:1928 / 1835 | bitmap-only；先 pending（1957）后主索引 |
| 13 | createPostingTree / ginInsertItemPointers | gindatapage.c:1775 / 1908 | 建树（384B 段，:34）与树内批量插入 |
| 14 | GinPostingList / varbyte | ginblock.h:336-341；ginpostinglist.c:81,115,197 | 首项明文+差值 varbyte（43 位 TID，11 位 offset） |
| 15 | ginbulkdelete | ginvacuum.c:631 | 先强制清 pending（666）；叶子过滤（48 ginVacuumItemPointers） |
| 16 | ginVacuumPostingTree(Leaves) | ginvacuum.c:471 / 391 | 两阶段：删死 TID→删空页（ginScanPostingTreeToDelete:271） |
| 17 | ginarrayextract/ginqueryarrayextract/ginarrayconsistent | ginarrayproc.c:33/79/143 | 数组 opclass；策略→searchMode 109-133 |
| 18 | gin_extract_tsvector/gin_extract_tsquery | src/backend/utils/adt/tsginidx.c:64/94 | tsvector opclass；extra_data 传操作数图 |
| 19 | gin_extract_trgm/gin_trgm_consistent | contrib/pg_trgm/trgm_gin.c:24/172 | trigram opclass（LIKE/正则部分匹配） |
| 20 | GinOptions/GinGetUseFastUpdate/GinGetPendingListCleanupSize | src/include/access/gin_private.h:28-47 | reloptions fastupdate 与 pending 阈值 |

（全文完，行号核对基准：commit 8c7a74c）
