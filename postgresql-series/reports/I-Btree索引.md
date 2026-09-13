# I - B-tree 索引（nbtree）深度调研

> 源码版本：PostgreSQL master，commit `8c7a74c3239ce29940582643533a190721b395c0`（shallow clone）。
> 所有行号均已用 grep/Read 核对，路径为仓库相对路径。
> 注意：与本系列早期调研假设不同，当前 master 已把 nbtree 拆得更细：`_bt_readpage` 在 `src/backend/access/nbtree/nbtreadpage.c`（不在 nbtsearch.c）、`_bt_preprocess_keys` 在 `nbtpreprocesskeys.c`（不在 nbtutils.c）、分裂点选择独立为 `nbtsplitloc.c`、dedup 独立为 `nbtdedup.c`。行号以实际文件为准。

nbtree 是 Lehman & Yao 高并发 B-tree（简称 L&Y）加 Lanin & Shasha 删除算法的实现（src/backend/access/nbtree/README:6-12）。它是 PG 使用率最高的索引 AM，也是"多进程共享缓冲 + MVCC 感知"特化 B-tree 的教科书样本。

---

## 1. 全景：页族结构

```
                    nbtree 文件布局（每个关系一个）
 block 0            block R (root)          内部页 (level>0)         叶子页 (level 0)
+-----------+      +---------------+       +---------------+      +----------------+
| metapage  |      | [hikey 若非最右]|       | [hikey]        |      | [hikey]        |
| magic/ver |      | pivot|downlink |       | pivot|downlink |      | key|TID  (非pivot)
| btm_root  |--R-> | pivot|downlink |       | pivot|downlink |      | key|TID       |
| btm_fastroot     | ...            |       | ...            |      | key|TID|posting|
+-----------+      +---------------+       +---------------+      +----------------+
                        | btpo_prev <----+        | btpo_prev <---+    | btpo_prev <---+
                        + btpo_next ---->| 同层右链 + btpo_next --->|    + btpo_next --->|
                   （同层页用 prev/next 双链串成逻辑有序的页链；范围扫描沿右链滑行，
                     中途可"跳过" half-dead/分裂后的页——这正是 L&Y 的容错关键）
```

- metapage 固定为 0 号页，存 magic/版本/真根/快根（src/include/access/nbtree.h:104-120，149-153）。
- 每页尾部 special 区放 `BTPageOpaqueData`：左右兄弟链、层号、flag、vacuum cycle id（nbtree.h:63-70）。
- 层号从叶子的 0 向上数，因此根分裂无需重编号（README:1046-1050，nbtree.h:67）。
- 前向扫描只需右链（L&Y 原生）；后向扫描额外需要左链，代价是分裂时要顺手改右兄弟的 prev 链（README:70-86）。

## 2. 页格式专节

### 2.1 IndexTuple 与三种形态

非 pivot（指向堆元组）格式 `t_tid | t_info | key值 | INCLUDE列`，t_tid 即堆 TID；PG v4（heapkeyspace）把堆 TID 当作末位 tiebreaker 键列，同键按 TID 有序（README:42-49，nbtree.h:383-388）。

pivot（导航）格式 `t_tid | t_info | key值 | [堆TID]`，t_tid 存 downlink；被截断的属性逻辑值为负无穷（README:31-40，nbtree.h:393-407）。

posting（dedup 产物）格式 `t_tid | t_info | key值 | TID数组`。三态靠复用 t_tid：t_info 的 `INDEX_ALT_TID_MASK` 位 + t_tid offset 字段高位 `BT_PIVOT_HEAP_TID_ATTR`/`BT_IS_POSTING` 区分（nbtree.h:460-467、480-502）；pivot 的 offset 低 12 位存"键属性个数"（`BTreeTupleGetNAtts`，nbtree.h:578-586）。

关键宏：`P_HIKEY`=1、`P_FIRSTKEY`=2、`P_FIRSTDATAKEY(opaque)`——非最右页第 1 项是 high key，数据从第 2 项开始；最右页没有 high key（隐含 +∞），数据从第 1 项开始（nbtree.h:368-370）。high key 放在页首而非页尾，是为了追加数据时不用搬动它（nbtree.h:360-366，README:1061-1067）。

单页物理布局（标准 PageHeader + special 区放 opaque，行目录从前往后、元组数据从后往前）：

```
+---------------------------------------------------+ 偏移 0
| PageHeaderData (pd_lower/pd_upper/pd_special...)  |
+---------------------------------------------------+
| ItemId[1] = high key（非最右页）/ 第一个数据项     |
| ItemId[2..] = 数据项(叶子) 或 downlink(内部)       |  <- pd_lower
|              ......... 空闲空间 .........          |
|                 元组数据区（自高地址向下生长）      |  <- pd_upper
+---------------------------------------------------+ <- pd_special
| BTPageOpaqueData: prev|next|level|flags|cycleid    |
+---------------------------------------------------+ 页尾
```

尺寸红线：任一索引元组不得超过页可用空间的 1/3——保证任何页至少能容下"high key + 两个数据项"三项（`BTMaxItemSize`，nbtree.h:165-169；README:791-795）；叶子页 TID 容量上界 `MaxTIDsPerBTreePage`（nbtree.h:186-188）。填充因子：叶 90%（可调）、内部 70%、全页同值 96%（nbtree.h:200-203）。

### 2.2 BTPageOpaqueData 逐字段（nbtree.h:63-70）

| 字段 | 行 | 含义 |
|---|---|---|
| `btpo_prev` | 65 | 左兄弟块号，最左页为 P_NONE |
| `btpo_next` | 66 | 右兄弟块号，最右页为 P_NONE；也是并发分裂/删除后的恢复通道 |
| `btpo_level` | 67 | 层号，叶子=0 向上递增 |
| `btpo_flags` | 68 | 见下表 |
| `btpo_cycleid` | 69 | 最近一次分裂所属的 VACUUM 周期号，用于 bulk delete 回溯（README:213-231） |

flags（nbtree.h:77-85）：`BTP_LEAF`(1<<0)、`BTP_ROOT`(1<<1)、`BTP_DELETED`(1<<2，已摘出树)、`BTP_META`(1<<3)、`BTP_HALF_DEAD`(1<<4，空但仍在兄弟链上)、`BTP_SPLIT_END`(1<<5)、`BTP_HAS_GARBAGE`(1<<6，已弃用)、`BTP_INCOMPLETE_SPLIT`(1<<7，右页 downlink 尚未写入父页)、`BTP_HAS_FULLXID`(1<<8，页体存 safexid)。判活宏 `P_IGNORE = DELETED|HALF_DEAD`（nbtree.h:226）——搜索遇到即向右跳。

### 2.3 High Key 与"右边界"语义

high key 是本页键空间的上界；如果插入键严格大于 high key，说明页已并发分裂、必须右移（nbtree.h:349-357）。`_bt_moveright` 的比较阈值 `cmpval = nextkey ? 0 : 1`：普通情况键 > hikey 才右移，nextkey（找"严格大于"起点）时键 >= hikey 就右移（src/backend/access/nbtree/nbtsearch.c:275）。叶子 high key 可以与页内最后一项完全相等，这是全树唯一允许的键重复（README:47-49）。

### 2.4 Metapage 与 fastroot

`BTMetaPageData`：`btm_root/btm_level` 真根，`btm_fastroot/btm_fastlevel` 快根（nbtree.h:108-111）。fastroot 是"最低的单页层"：大量删除后树会变瘦，操作从 fastroot 出发避免空降冗余层；页面单独留在某层分裂、或删除使某层只剩一页时同步调整（README:362-381）。为省一次 metapage 读，root 信息缓存在 relcache 的 `rd_amcache`，用"最左+最右+层号匹配"验证缓存是否陈旧（src/backend/access/nbtree/nbtpage.c:365-404，README:774-789）。btm_version >= 3 才有 `btm_allequalimage`（dedup 前提）；当前版本 4（nbtree.h:127-151）。

## 3. 下降与蟹行专节

### 3.1 _bt_search：从根到叶的锁协议

```c
// src/backend/access/nbtree/nbtsearch.c:184-185
/* drop the read lock on the page, then acquire one on its child */
*bufP = _bt_relandgetbuf(rel, *bufP, child, page_access);
```

主循环（nbtsearch.c:102-210）每层做三件事：`_bt_moveright` 修正并发分裂（142）、`_bt_binsrch` 选 downlink（155）、把 (块号, 偏移) 压入 descent stack 供分裂/删除回溯（167-174）。要点是锁协议**不是**教科书式"持父锁再取子锁"：**每层先放掉父页读锁再去拿子页锁**（nbtsearch.c:184-185）。之所以敢放，是因为 L&Y 的右链 + high key 让"跟错链接"永远可恢复（README:17-29）；这是 crab 行走（crabbing）的乐观化——不 latching 父锁，靠 hikey 校验兜底。下降全程最多只持一把锁。

写模式细节：层号==1 时预先把 child 锁升级为写锁（nbtsearch.c:181-182）；根是叶子时读锁换写锁后还要再 move right 一次防分裂竞态（nbtsearch.c:195-207）；写模式下顺路完成 incomplete split（`_bt_moveright` 的 forupdate 分支，nbtsearch.c:288-307）。README 明确：向右/向上加锁可以"先取新再放旧"，向左/向下绝不行（会死锁）（README:106-110）。

### 3.2 _bt_moveright：分裂恢复

判定条件：`P_IGNORE(opaque) || _bt_compare(...P_HIKEY) >= cmpval` 则右移一步，循环到站（nbtsearch.c:309-317）。落入已删除页同样右移；移到最右页还 hikey 越界则直接报错"fell off the end"（nbtsearch.c:319-321）。

```c
// src/backend/access/nbtree/nbtsearch.c:275-317（节选）
cmpval = key->nextkey ? 0 : 1;
for (;;)
{
    page = BufferGetPage(buf);
    opaque = BTPageGetOpaque(page);
    if (P_RIGHTMOST(opaque))
        break;
    ... /* forupdate: 完成 INCOMPLETE_SPLIT */
    if (P_IGNORE(opaque) || _bt_compare(rel, key, page, P_HIKEY) >= cmpval)
    {
        /* step right one page */
        buf = _bt_relandgetbuf(rel, buf, opaque->btpo_next, access);
        continue;
    }
    else
        break;
}
```

注意右移时 `P_HIKEY` 恒为比较对象：对 high key 的比较结果就足以判定"该键是否已不属于本页"。

### 3.3 页内二分 _bt_binsrch

```c
// src/backend/access/nbtree/nbtsearch.c:394-406
while (high > low) {
    OffsetNumber mid = low + ((high - low) / 2);
    result = _bt_compare(rel, key, page, mid);
    if (result >= cmpval) low = mid + 1;
    else                 high = mid;
}
```

low 从 `P_FIRSTDATAKEY` 起（nbtsearch.c:365）。`_bt_compare` 规定内部页首数据项视作负无穷恒返回 1（nbtsearch.c:713-714），被截断属性当负无穷（nbtsearch.c:793-794），DESC 列翻转符号（nbtsearch.c:773-774），最后用堆 TID tiebreaker 决胜（nbtsearch.c:801-810）。叶子层结果再按方向修正：后向扫描回退一项取"最后一个 < key"（nbtsearch.c:426-429）。插入路径用变体 `_bt_binsrch_insert`（nbtsearch.c:477），把二分上下界缓存进 insertstate 供唯一性检查与定位复用。

### 3.4 范围扫描 _bt_readpage 与方向反转

`_bt_readpage`（src/backend/access/nbtree/nbtreadpage.c:134-…）一次把整页匹配项连同 TID 拷贝进后端私有 `currPos`，并记住 prevPage/nextPage（nbtreadpage.c:153-154）——扫描逻辑上停在"页之间"，之后访问堆时不持页锁（README:88-104）。翻页由 `_bt_steppage`（nbtsearch.c:1654-1731）：先 `_bt_killitems` 处理 kill_prior_tuple 标记（1663-1664），再沿**当时记录的** nextPage/prevPage 走（1715-1718）——不能跟当前页的右链，否则可能重复扫描被分裂搬走的项（README:99-101）。后向翻页走 `_bt_lock_and_validate_left`（nbtsearch.c:1982）实现 README:330-360 的 move-left 算法（左兄弟可能已分裂或被删，需右移找回右链指回原页者）。锁的放手策略见 `_bt_drop_lock_and_maybe_pin`（nbtsearch.c:57-75）：视 `dropPin` 决定只放锁还是连 pin 一起放（放 pin 是为了不挡 VACUUM 的 cleanup lock）。数组键（SK_SEARCHARRAY）把一次扫描拆成多个"primitive scan"，`_bt_advance_array_keys` 在 nbtreadpage.c:2182 就地推进数组游标或触发重新定位；`_bt_first` 里 `so->numArrayKeys && !so->needPrimScan` 直接续扫（nbtsearch.c:930）。

后向扫描的 move-left 算法（README:330-360 摘译，处理"左兄弟已分裂/已删"两个竞态）：

1. 记住当前页为"原始页"；沿其 left-link 到左邻。
2. 若左邻存活且其 right-link 指回原始页——到达。
3. 否则持续右移找"right-link 指回原始页"的存活页（原始页的右兄弟可能又分裂了几次）。
4. 回原始页：若还活着回到步骤 1（猜错了）；若已死则向右找到第一个非 deleted 页作为新的"原始页"，回到步骤 1（最右页永不删，必有终点）。

该算法的正确性依赖第 4 步找到的页与出发页有相同的左键空间边界——因此不会漏扫或重扫。

## 4. 插入与分裂专节

### 4.1 _bt_doinsert 流程

`_bt_doinsert`（src/backend/access/nbtree/nbtinsert.c:105-279）：构造插入扫描键（唯一检查前 scantid 置空，nbtinsert.c:123）→ `_bt_search_insert` 拿写锁叶页（优先命中右端 fastpath 缓存，nbtinsert.c:32、320-…、1447-1449，README:491-508）→ 唯一检查 → `_bt_findinsertloc`（829）→ `_bt_insertonpg`（1119）。冲突等待时释放锁、`XactLockTableWait` 后 `goto search` 从头再来（nbtinsert.c:216-235）。

### 4.2 唯一约束的等待语义（与 MVCC 交叉）

`_bt_check_unique`（nbtinsert.c:411-…）用 dirty snapshot 逐个等值项调 `table_index_fetch_tuple_check`（nbtinsert.c:563-565）：

```c
// src/backend/access/nbtree/nbtinsert.c:563-601（节选）
else if (table_index_fetch_tuple_check(heapRel, &htid,
                                       &SnapshotDirty,
                                       &all_dead))
{
    ...
    xwait = (TransactionIdIsValid(SnapshotDirty.xmin)) ?
        SnapshotDirty.xmin : SnapshotDirty.xmax;
    if (TransactionIdIsValid(xwait))
    {
        if (nbuf != InvalidBuffer)
            _bt_relbuf(rel, nbuf);          /* 放锁再等 */
        *speculativeToken = SnapshotDirty.speculativeToken;
        insertstate->bounds_valid = false;  /* 二分缓存作废 */
        return xwait;                       /* 调用方 XactLockTableWait + goto search */
    }
    /* 否则：确定冲突，ereport 违反唯一约束 */
}
```

- 命中**在途事务**（xmin/xmax 有效）→ 返回 xwait，调用方放锁等待后整个重查（nbtinsert.c:589-601 + 216-235）；speculative insertion 用 `SpeculativeInsertionWait`（nbtinsert.c:227-228）。
- 命中已提交元组 → 直接违反唯一约束 ereport。
- 等待期间必须放锁，因此"等待 + 重搜"是唯一性检查的固有循环；而防并发插入同键靠的是**对"该值可能所在第一页"持写锁、scantid 省略**——两个插入者必然争同一页（nbtinsert.c:190-199 注释）。
- CREATE INDEX CONCURRENTLY 场景：插入者自身元组可能已死，先查自己链再报错（nbtinsert.c:604-622）。
这正是"索引层也要理解 MVCC"的样板：可见性判断不在索引内完成，而是借助 heap 的 dirty snapshot 回表；NULL 键按核心语义跳过检查（nbtinsert.c:118-141）。

### 4.3 _bt_split 与划分点

`_bt_split`（nbtinsert.c:1489-2111）在临时缓冲构造左右两半再原子提交：
1. `_bt_findsplitloc` 选划分点：**把新元组假想已放入页内**，划分点是 lastleft/firstright 之间的缝隙，`newitemonleft` 消歧（nbtinsert.c:1543-1568，nbtsplitloc.c:119-127）。
2. 左页新 high key = 对 firstright 做后缀截断的 pivot（叶层）；内部页不能截断，直接用 firstright（nbtinsert.c:1659-1714，见 §5.2）。
3. 右页继承原页 high key（若非最右）（nbtinsert.c:1783-1802）；内部页右页首项截成"负无穷"纯 downlink（nbtinsert.c:1808-1810）。
4. 左页打 `BTP_INCOMPLETE_SPLIT` 标——右页 downlink 要等父层插入完成后才补（nbtinsert.c:1582，README:666-681）。
5. 原子段：左页内容拷回原块（nbtinsert.c:1961）、写右页、改右兄弟的 prev 链——**先按从左到右顺序锁旧右兄弟**避免死锁（nbtinsert.c:1908-1914、1977-1981，README:77-80），WAL 记 `XLOG_BTREE_SPLIT_L/R` 一条（nbtinsert.c:2082，nbtxlog.h:30-31）。
6. `_bt_insert_parent`（nbtinsert.c:2130）持左右页写锁上溯；`_bt_getstackbuf` 用**子块号匹配 downlink**（不是分隔键）重找父项，可沿途右移（nbtinsert.c:2414、2430、2446-2453，README:139-156）——这避免了 L&Y 原算法同层三锁耦合。真根分裂由 `_bt_newlevel` 造新根并改 metapage（nbtinsert.c:2492）。

**为什么分裂点从中间偏**：填充因子策略（nbtsplitloc.c:87-127）——非最右页近似对半均分字节（不是项数，README:158-164）；最右页（单调递增插入场景）按 leaf fillfactor（默认 90%）让左页只填到 fillfactor，避免"中间分裂→右页永远浪费"（nbtsplitloc.c:95-99，nbtree.h:191-203）；全页同值用 96% 的 single-value fillfactor（nbtsplitloc.c:412-414，nbtree.h:203）。候选点按 `|fillfactormult*leftfree-(1-mult)*rightfree|` 排序，取容差区间（叶子 5%、内部 7.5%，`LEAF_SPLIT_DISTANCE`/`INTERNAL_SPLIT_DISTANCE`，nbtsplitloc.c:850-851、877-921），在区间内再以"截断惩罚"挑最优（`_bt_bestsplitloc`，nbtsplitloc.c:789-848）。大组重复值倾向整组留在同一页（接受极端不均），退化时左满右空以适配 TID 递增（README:889-901）；`SPLIT_MANY_DUPLICATES` 有防单调递减插入反复分裂的守卫（nbtsplitloc.c:833-844）。

空间记账（`_bt_recsplitloc`，nbtsplitloc.c:496-546）是理解"从中间偏"的钥匙：

```c
// src/backend/access/nbtree/nbtsplitloc.c:496-535（节选）
leftfree = state->leftspace - olddataitemstoleft;
rightfree = state->rightspace - (state->olddataitemstotal - olddataitemstoleft);
/* 叶层：firstright 会成为左页新 high key，同时计入两侧；
   悲观假设后缀截断不省空间，且可能补一个 MAXALIGN 的堆 TID */
if (state->is_leaf)
    leftfree -= (int16) (firstrightsz +
                         MAXALIGN(sizeof(ItemPointerData)) - postingsz);
else
    leftfree -= (int16) firstrightsz;
if (newitemonleft) leftfree -= (int16) state->newitemsz;   /* 新元组计入一侧 */
else              rightfree -= (int16) state->newitemsz;
/* 内部层：右页首项的键数据全部丢弃（负无穷化） */
if (!state->is_leaf)
    rightfree += (int16) firstrightsz -
        (int16) (MAXALIGN(sizeof(IndexTupleData)) + sizeof(ItemIdData));
```

即：新元组尺寸必须并入某一侧（否则分裂后放不下新元组）；左页 hikey 是"重复计入"的成本；内部页右页首项键体可丢弃则是内部分裂的隐性补贴。只有 `leftfree>=0 && rightfree>=0` 的候选才合法（nbtsplitloc.c:546）。

## 5. dedup 与 suffix truncation：延缓分裂的空间经济

### 5.1 dedup（PG13+，src/backend/access/nbtree/nbtdedup.c）

dedup 把同键非 pivot 元组合并为 posting list（TID 数组）tuple，**惰性触发**：仅在插入放不下、LP_DEAD 清理与 bottom-up deletion 都救不回时作为"分裂前最后一道防线"运行（README:903-919；调用链 nbtinsert.c:2822→`_bt_bottomupdel_pass`，2827→`_bt_dedup_pass`）。`_bt_dedup_pass`（nbtdedup.c:59-…）单趟重写整页：

```c
// src/backend/access/nbtree/nbtdedup.c:143-159（节选）
if (offnum == minoff)
    _bt_dedup_start_pending(state, itup, offnum);   /* 首项作 base */
else if (state->deduplicate &&
         _bt_keep_natts_fast(rel, state->base, itup) > nkeyatts &&
         _bt_dedup_save_htid(state, itup))          /* 等值且不超 maxpostingsize */
{
    /* TID 并入 pending posting list */
}
else
    pagesaving += _bt_dedup_finish_pending(newpage, state); /* 落一个 posting */
```

等值判定用 `_bt_keep_natts_fast`（nbtutils.c:911）按"首个不等键属性位置"比较，只需 `> nkeyatts` 即"键属性全等"（nbtdedup.c:151-153）。posting list 上限 `maxpostingsize = BTMaxItemSize/2`（约 1/6 页，nbtdedup.c:80-89）——封顶后开新 posting，保证页被重复分裂时总有合理切分点。页全同值走 single-value 策略，留出页尾若干不合并的元组为将来的分裂点做准备（`_bt_do_singleval`/`_bt_singleval_fillfactor`，nbtdedup.c:781、821；第 6 个封顶 posting 出现即停止合并，nbtdedup.c:191-198）。WAL 记一条 `XLOG_BTREE_DEDUP`（nbtxlog.h:33）。unique 索引的 dedup 目的不同：不为省空间，而是给垃圾回收争取时间、阻止"版本 churn 驱动的病态分裂"，且只在插入时看到过重复项才启动（README:949-987）。经济性：内存中 TID 数组仅排序去重，无压缩（varbyte 编码被有意否决，README:930-941）。

### 5.2 suffix truncation（PG11+，nbtutils.c:692）

叶分裂时 `_bt_truncate` 用 `_bt_keep_natts` 找 lastleft/firstright 首个不等属性，把 pivot 截到该前缀（nbtutils.c:692-741）；若所有键属性都相等则补一个堆 TID 属性（nbtutils.c:743-754，nbtree.h:466 `BT_PIVOT_HEAP_TID_ATTR`）：

```c
// src/backend/access/nbtree/nbtutils.c:709-741（节选）
keepnatts = _bt_keep_natts(rel, lastleft, firstright, itup_key);
pivot = index_truncate_tuple(itupdesc, firstright,
                             Min(keepnatts, nkeyatts));
...
if (keepnatts <= nkeyatts)
{
    BTreeTupleSetNAtts(pivot, keepnatts, false);  /* 记录保留的属性数 */
    return pivot;                                  /* 无需堆 TID，完成 */
}
/* 全键相等：必须把堆 TID 塞进 pivot 才能区分左右 */
```

被截属性逻辑值为负无穷（README:51-55）。收益是**内部页变小 → 内部分裂延迟 → 更小的 pivot 更早沉积到根**：内部分裂点刻意偏向"最小 downlink 可接受区间"，出自 Prefix B-Trees 论文（README:870-887，nbtsplitloc.c:955-956 用 minfirstrightsz 作完美惩罚）。INCLUDE 列对 pivot 恒为 payload、一律截掉（README:834-837）。内部页分裂**不能**截断：父祖父层必须保持未断的"分隔键接缝"（nbtinsert.c:1687-1712）。两者合力的空间经济：dedup 压叶层重复键的存储、truncation 压内部页 pivot 的存储，一个推迟叶分裂、一个推迟内部分裂，双双降低整树的写放大。

## 6. 删除专节：half-dead 两阶段回收

入口 `_bt_pagedel`（src/backend/access/nbtree/nbtpage.c:1812-2081）。只删**全空叶子**，绝不删最右页与根（nbtpage.c:1906-1915）——最右页不删使树高只增不减，也让"向右恢复"必有终点（README:365-370）。

- **阶段一（摘父链）** `_bt_mark_page_halfdead`（nbtpage.c:2102-…）：先用目标页 high key 构造 backward 插入键重新下降找"父"（nbtpage.c:1943-1980，注意为防死锁先放叶锁 nbtpage.c:1953）；若右兄弟不是同一父的孩子则放弃（键空间并入右兄弟会连锁改上界，无法原子化，nbtpage.c:2140-2145 前置检查 + README:270-277）；否则沿链向上找到"顶父"，把指向链顶的 downlink 删掉、键空间一次性让给右兄弟，叶页标 `BTP_HALF_DEAD` 并把顶父块号藏进叶页 high key 的 t_tid（`BTreeTupleSetTopParent`，nbtpage.c:2253-2255，nbtree.h:620-631）。递归上溯期间只需持叶锁：叶不分裂，链上内部页就不可能新增孩子（README:295-301）。WAL：`XLOG_BTREE_MARK_PAGE_HALFDEAD`（nbtxlog.h:38）。
- **阶段二（摘兄弟链）** `_bt_unlink_halfdead_page`（nbtpage.c:2329-…）循环把链顶页从兄弟链上摘下、改左右兄弟互链，直到叶页自身也被标 `BTP_DELETED`（nbtpage.c:2030-2047，2644 恢复 top parent）。WAL：`XLOG_BTREE_UNLINK_PAGE(_META)`（nbtxlog.h:35-36）。

主循环骨架（每轮可能连删"右兄弟也空了"的后续页）：

```c
// src/backend/access/nbtree/nbtpage.c:2011-2047（节选）
if (!_bt_mark_page_halfdead(rel, vstate->info->heaprel, leafbuf, stack))
{ _bt_relbuf(rel, leafbuf); return; }        /* 阶段一：摘父链，标 half-dead */
...
rightsib_empty = false;
while (P_ISHALFDEAD(opaque))                 /* 阶段二：反复摘链顶 */
{
    if (!_bt_unlink_halfdead_page(rel, leafbuf, scanblkno,
                                  &rightsib_empty, vstate))
        Assert(false);
}
Assert(P_ISLEAF(opaque) && P_ISDELETED(opaque));
```

两阶段间的崩溃/中断是安全的：搜索遇 `BTP_HALF_DEAD` 页会向右跳过（`P_IGNORE`），下次 VACUUM 再遇到 half-dead 叶页会从中断处续删（nbtpage.c:1511-1520，README:688-692）。

**为什么需要"父引用"**：删除必须先断 downlink 再断 sibling 链，两步都要原子 WAL；搜索者可能正拿着旧 downlink 或兄弟链接近本页，所以已删除页必须以 tombstone 形式原地停留，靠 `BTDeletedPageData.safexid` + `GlobalVisCheckRemovableFullXid` 判定"再无扫描能看到指向它的链接"后才可入 FSM 复用（nbtpage.c 摘要 + nbtree.h:239-319；README:319-328、383-435）。本 VACUUM 新删页记入 `BTPendingFSM` 延迟到扫描结束时统一判定（`_bt_pendingfsm_init/_finalize/_add`，nbtpage.c:2971、3013、3080，README:417-424）。

## 7. VACUUM 联动：bulk delete 与死 TID 过滤

`btbulkdelete`（src/backend/access/nbtree/nbtree.c:1122-1144）注册 cycleid（`_bt_start_vacuum`，nbtree.c:1136）后进入 `btvacuumscan`（nbtree.c:1240-…）做**物理序**线性扫页。对每片叶子：升级为 cleanup lock——没有可删项也要拿，用于与 index scan 的 TID 回收互锁（nbtree.c:1533-1539，README:169-202）；逐项调回调过滤死 TID（nbtree.c:1563-1583）。G 章（heap VACUUM）的死 TID 集合即通过这个 callback（`vac_cmp_tid`/TidStore 底层）查询；posting list 元组粒度处理：部分死→重写为小 posting（`btreevacuumposting` + `_bt_delitems_update`，nbtree.c:1587-1630，nbtpage.c:1415），全死→整项删（nbtree.c:1616-1627）。每页一次 `_bt_delitems_vacuum`（nbtpage.c:1162-…）合并成一条 `XLOG_BTREE_VACUUM`（nbtpage.c:1184-1220，nbtxlog.h:39-40）：先 `PageIndexTupleOverwrite` 重写部分死的 posting（刻意不碰 LP_DEAD 位，nbtpage.c:1198-1209），再 `PageIndexMultiDelete` 整项删除（nbtpage.c:1213），并清本页 cycleid（nbtpage.c:1219-1220）。并发分裂防漏的回溯判定：

```c
// src/backend/access/nbtree/nbtree.c:1550-1555
if (vstate->cycleid != 0 &&
    opaque->btpo_cycleid == vstate->cycleid &&
    !(opaque->btpo_flags & BTP_SPLIT_END) &&
    !P_RIGHTMOST(opaque) &&
    opaque->btpo_next < scanblkno)
    backtrack_to = opaque->btpo_next;  /* 右半被搬到已扫过的低块号 → 回溯 */
```

页清空则顺势 `_bt_pagedel`（nbtree.c:1674-1679 之后路径），half-dead 残页也在此续删（nbtree.c:1511-1520）；已删除且 safexid 足够老的页由 `BTPageIsRecyclable` 判定后 `RecordFreeIndexPage` 入 FSM（nbtree.c:1496-1502，nbtree.h:291-319）。清理阶段 `btvacuumcleanup` 无删除时可用 `_bt_vacuum_needs_cleanup` 整体跳过物理扫描（nbtree.c:1171-1193），并把"未可回收的已删页数"持久化进 metapage 供下次决策（nbtree.c:1208-1210）。删除与 heap 侧衔接：LP_DEAD 即 heap 的 kill_prior_tuple（README:510-543）；bottom-up deletion 借 tableam 的 `TM_IndexDeleteOp` 批量回表定夺（README:557-618，nbtdedup.c:309 `_bt_bottomupdel_pass`）。扫描键侧，`_bt_preprocess_keys` 完成策略修正/冗余剔除与 SK_SEARCHARRAY 数组化（src/backend/access/nbtree/nbtpreprocesskeys.c:202-241、1845），数组键在 `_bt_readpage` 内由 `_bt_advance_array_keys` 原位推进（nbtreadpage.c:2182）。

## 8. 与前作对照

| 对比项 | SQLite B-tree | Git fanout 二分 | LevelDB | PG nbtree |
|---|---|---|---|---|
| 存储形态 | 单文件 4KB（可调）页 | packfile + 静态 fanout 树 | LSM：memtable+SST，无 B-tree | 8KB 页 + shared buffer 池 |
| 并发 | 单写者（writer lock） | 只读快照 | Compaction 后台合并 | 多进程共享缓冲，页级读写锁 + 蟹行 |
| 崩溃恢复 | 回滚 journal/WAL | 无需（内容寻址） | MANIFEST + log | 每步原子 WAL 记录 + incomplete-split/half-dead 惰性补全（README:620-700） |
| MVCC | 无（全库写锁） | 天然只读 | sequence 快照 | 键内嵌堆 TID tiebreaker，可见性回 heap 判定；索引侧死元组也要 VACUUM |
| 高并发关键 | 无 | 无 | 无 | L&Y 右链+hikey：下降不持父锁，右移即恢复（README:17-29） |
共性是"页=最小 I/O 单元 + 页内二分"；差异点正是 nbtree 的两个特化维度：**多进程共享缓冲下的锁协议**（不能像 SQLite 那样独占，也不能像 Git 那样只读），以及 **MVCC 感知**（索引条目生命周期与堆版本联动）。LevelDB 干脆用 LSM 换掉了原地 B-tree 的写放大与锁复杂度——两种路线的分野值得在 FAQ 展开。

## 9. 设计动机

- **MVCC 感知的索引为什么难**：heap 每个版本可能有独立索引项（非 HOT），可见性却只有 heap 知道——索引页里天然堆积死 TID，且索引侧**没有** xmin/xmax 可判，只能靠回表（dirty snapshot，nbtinsert.c:563-565）或 VACUUM 回调（nbtree.c:1579）裁决。于是 nbtree 长出一整套"分裂前先尝试删"的梯队：LP_DEAD 简单删除 → bottom-up deletion（代际假说，README:589-618）→ dedup → 分裂，本质是把 heap 的垃圾回收压力在索引侧就地摊销。
- **蟹行锁的乐观主义**：每次下降只持一把锁、父锁先放，赌的是"跟错链接"是小概率且可右移恢复；L&Y 论文的 hikey 校验把这个赌注的失败代价压到一次右移。插入上溯则保守地耦合父子锁，删除则完全依赖"tombstone + safexid"的排水技术（drain，README:389-401）。乐观与保守的分工边界清晰：**读路径乐观、写路径保守**。
- **dedup 的工程经济**：posting list 让"一个键 N 个版本"从 N 份键存储降为 1 份键 + N×6 字节 TID，且推迟分裂、保护内部页、增大 fanout；选择惰性触发让随机写几乎零开销（README:943-947），single-value 策略又与分裂点选择默契配合（留尾不合并）。没有压缩是刻意取舍：保住 TID 粒度删除与 bottom-up deletion 的效率（README:936-941）。

## 10. FAQ 素材

1. 为什么 PG 的 B-tree 页内 high key 放在第一项而不是最后一项？——避免随数据追加搬动 hikey（nbtree.h:360-366）。
2. 搜索时父锁什么时候释放？——取子锁前就释放（nbtsearch.c:184-185），靠 hikey + 右链恢复跟错。
3. 唯一索引插入遇到未提交冲突怎么办？——放锁等待对方事务终结再全量重搜（nbtinsert.c:216-235、589-601）；这可能与 MVCC 读写冲突形成等待链。
4. 索引里逻辑重复的键为什么能有序？——heap TID 是隐式末位键列（README:42-49），v4 才有（nbtree.h:127-134），所以 v12 以下索引需 REINDEX 才享 dedup。
5. 分裂为什么按字节而非项数均分？——变长键（README:158-164）；且必须计入新元组，否则可能塞不进应去的那半。
6. PG 会合并半满的页吗？——不会，只删全空页：移动数据可能让反向扫描漏项（README:235-241）。
7. 树高会降低吗？——不会（根/最右页永不删），但有 fastroot 跳过单页瘦层（README:362-381）。
8. dedup 后扫描怎么逐个 TID 判活？——`_bt_readpage`/`_bt_checkkeys`/VACUUM 回调都按 posting 内 TID 逐个展开（nbtinsert.c:454-544，nbtree.c:1587-1630）。
9. 为什么 VACUUM 要对无死元组的叶页也拿 cleanup lock？——索引扫描可能放弃 pin 后 TID 被回收复用，防错误标记/错读（README:169-202、484-489）。
10. INCLUDE 列会被二分比较吗？——不会，非键列不属于键空间，pivot 里恒被截掉（nbtree.h:375-383）。

## 深挖建议

1. `_bt_findsplitloc` 全流程（nbtsplitloc.c:130-430）：三种策略（default/many duplicates/single value）与 `_bt_strategy`（935-…）的 perfect-penalty 传导。
2. 数组键扫描状态机：`_bt_preprocess_array_keys`（nbtpreprocesskeys.c:1845）与 `_bt_advance_array_keys`（nbtreadpage.c:2182）——skip array（跳跃数组）是 PG17 起的重要演进。
3. `_bt_unlink_halfdead_page` 的逐层摘链与 top-parent 恢复（nbtpage.c:2329-2700）。
4. 备机回放语义：LP_DEAD 在 standby 恒被忽略的原因（README:702-746）；`XLOG_BTREE_SPLIT_L/R` 的 REDO 重放 `_bt_restore_page`（nbtxlog.c）。
5. bottom-up deletion 与 tableam 接口（README:557-618；`_bt_bottomupdel_pass` nbtdedup.c:309；`_bt_simpledel_pass` nbtinsert.c:2859）。

## 写作要点速查表

| 主题 | 函数/结构 | 位置 |
|---|---|---|
| 页 opaque | BTPageOpaqueData / flags | src/include/access/nbtree.h:63-85 |
| P_HIKEY/P_FIRSTDATAKEY | 宏 | src/include/access/nbtree.h:368-370 |
| metapage | BTMetaPageData（fastroot） | src/include/access/nbtree.h:104-120 |
| pivot/posting 三态 | BTreeTupleIsPivot/IsPosting | src/include/access/nbtree.h:480-502 |
| 页回收判据 | BTPageIsRecyclable | src/include/access/nbtree.h:291-319 |
| 下降 | _bt_search（放锁取子锁） | src/backend/access/nbtree/nbtsearch.c:102,184-185 |
| 右移恢复 | _bt_moveright | src/backend/access/nbtree/nbtsearch.c:244-324 |
| 页内二分 | _bt_binsrch | src/backend/access/nbtree/nbtsearch.c:346-430 |
| 比较器（-inf/TID 决胜） | _bt_compare | src/backend/access/nbtree/nbtsearch.c:691-810 |
| 扫描翻页 | _bt_steppage / _bt_readnextpage | src/backend/access/nbtree/nbtsearch.c:1654 / 1847 |
| 整页装载 | _bt_readpage | src/backend/access/nbtree/nbtreadpage.c:134 |
| 插入主流程 | _bt_doinsert | src/backend/access/nbtree/nbtinsert.c:105-279 |
| 唯一检查等待 | _bt_check_unique | src/backend/access/nbtree/nbtinsert.c:411-601 |
| 分裂 | _bt_split | src/backend/access/nbtree/nbtinsert.c:1489-2111 |
| 分裂点 | _bt_findsplitloc | src/backend/access/nbtree/nbtsplitloc.c:130 |
| 父层回溯 | _bt_getstackbuf（块号匹配） | src/backend/access/nbtree/nbtinsert.c:2351-2455 |
| 后缀截断 | _bt_truncate | src/backend/access/nbtree/nbtutils.c:692-754 |
| dedup | _bt_dedup_pass | src/backend/access/nbtree/nbtdedup.c:59-203 |
| half-dead 两阶段 | _bt_pagedel / _bt_mark_page_halfdead / _bt_unlink_halfdead_page | src/backend/access/nbtree/nbtpage.c:1812 / 2102 / 2329 |
| bulk delete | btbulkdelete / btvacuumscan / _bt_delitems_vacuum | src/backend/access/nbtree/nbtree.c:1122,1240；nbtpage.c:1162 |
| 扫描键预处理 | _bt_preprocess_keys / 数组化 | src/backend/access/nbtree/nbtpreprocesskeys.c:203,1845 |
| WAL 记录号 | XLOG_BTREE_* | src/include/access/nbtxlog.h:27-43 |
