# L 章 分区：一张逻辑表 = N 张物理表

> 基于 PostgreSQL master, commit `8c7a74c` (Re-read standby LSN after recovery ends)。
> 卷二讲了堆存取(06/07)与执行器(08)；本章讲"逻辑统一、物理分散"：一张分区表如何把 INSERT 路由到叶子、把 SELECT 剪枝成少量叶子。
> 勘误：partprune.c 在 master 上位于 `src/backend/partitioning/`（不在 optimizer/path/）；list 分区定位用**排序+二分**，不是哈希查找。

---

## 1. 全景：路由与剪枝的两条流水线

写入侧（INSERT/路由 tuple routing）与读取侧（剪枝 pruning）共用同一份数据结构：`PartitionBoundInfo`（分区边界的规范化表示，src/include/partitioning/partbounds.h:79-96）。

```
                 CREATE TABLE mt (...) PARTITION BY RANGE (k)
                 ┌────────────────────────────────────────────────┐
   INSERT row    │  relcache: rd_partkey + rd_partdesc + boundinfo│
  ─────────►  根表 (relkind='p', 不存数据)
                 │      │ FormPartitionKeyDatum 提取分区键值        │
                 │      ▼ get_partition_for_tuple                  │
                 │   ┌─hash: rowHash % nindexes → indexes[]        │
                 │   ├─list: 排序 datums 二分 → indexes[]          │
                 │   └─range: bounds 二分 → indexes[offset+1]      │
                 │      │ 仍是分区表？→ 下一层 dispatch(带列映射)   │
                 │      ▼                                          │
                 │   叶子表(普通堆) → ExecInsert 写堆+索引          │
                 └────────────────────────────────────────────────┘

   SELECT ... WHERE k BETWEEN .. AND ..
  ─────────► 规划期初剪: prune_append_rel_partitions (常量条件)
                 │  剩下的分区展开为 Append/MergeAppend 子计划
                 │  启动期初剪: ExecDoInitialPruning (stable 非常量)
                 │  每次扫描重剪: ExecFindMatchingSubPlans (PARAM_EXEC)
                 ▼
              只初始化/扫描幸存叶子
```

要点：
- 分区父表是 `RELKIND_PARTITIONED_TABLE`，本身没有存储；数据全在叶子。传统继承的父表可以有存储，这是两者的本质差别（见第 6 节）。
- 每个分区层次由 `PartitionDispatch` 驱动，它持有该层的 `PartitionDesc` 与 `PartitionKey`（src/backend/executor/execPartition.c:117-155）。
- 分区键定义存 `pg_partitioned_table`，由 `RelationGetPartitionKey` 首次访问时构建进 relcache（`PartitionKeyData` 结构见 src/include/utils/partcache.h:25-47，含 partnatts/partattrs/partexprs/partopfamily/partsupfunc 等）。

---

## 2. 三种策略的边界结构与定位算法（partbounds.c）

三种策略共享 `PartitionBoundInfoData`（src/include/partitioning/partbounds.h:79-96）：`datums[]` 是边界值数组，`indexes[]` 把边界槽位映射为分区序号，`null_index`/`default_index` 记录 NULL 与默认分区。

### 2.1 hash：模运算直接映射

构建（create_hash_bounds, src/backend/partitioning/partbounds.c:347）：把各分区的 (modulus, remainder) 按 modulus 排序，取最大 modulus 作 `nindexes`（:387），然后对每个分区**铺满**它负责的所有余数槽位：

```c
/* partbounds.c:403-418 */
for (i = 0; i < nparts; i++)
{
    int     modulus = hbounds[i].modulus;
    int     remainder = hbounds[i].remainder;
    ...
    while (remainder < greatest_modulus)
    {
        /* overlap? */
        Assert(boundinfo->indexes[remainder] == -1);
        boundinfo->indexes[remainder] = i;
        remainder += modulus;      /* stride = modulus */
    }
}
```

定位（execPartition.c:1605-1620）：调用 `compute_partition_hash_value`（partbounds.c:4710，用各列哈希函数 + 固定种子 `HASH_PARTITION_SEED=0x7A5B22367996DCFD`，src/include/catalog/partition.h:20，`hash_combine64` 合并）后一步取模：

```c
/* execPartition.c:1610-1619 */
rowHash = compute_partition_hash_value(...);
/* HASH partitions can't have a DEFAULT partition ... */
return boundinfo->indexes[rowHash % boundinfo->nindexes];
```

O(1) 定位，所以代码注释明说"hash partitioning is too cheap to bother caching"（execPartition.c:1609）。modulus 扩容规则（新 modulus 必须是已有最大 modulus 的因子）在 DDL 阶段校验（partbounds.c:2926-3005）。

### 2.2 list：排序去重 + 二分（不是哈希）

构建（create_list_bounds, partbounds.c:460）：收集所有非 NULL 值，NULL 单独记入 `null_index`（:511-519，重复 NULL 报错 :517-518），整体排序（:527，`qsort_partition_list_value_cmp`）。定位（execPartition.c:1641-1669）：`partition_list_bsearch`（partbounds.c:3594）在排序值上二分找 ≤ value 的最大边界，`is_equal` 判定是否命中；未命中落 default。

为什么 list 不用哈希表？因为 `boundinfo` 要支持：①规范化比较（partition_bounds_equal, partbounds.c:886，用于 relcache 失效判断）；②分区级 join 的边界合并（partition_bounds_merge, partbounds.c:1107）；③剪枝时"值不属于任何 IN 列表但可能属于 default"的区间式推理（get_matching_list_bounds, partbounds.c:2781）。有序数组同时满足这些诉求，单列二分 O(log n) 也足够。master 还引入 `interleaved_parts` 位图标记"可能与其他分区交错"的 list 分区（partbounds.h:66-73），供 join 合并走保守路径。

### 2.3 range：上界数组 + 二分

构建（create_range_bounds, partbounds.c:673）：每个分区的上下界展开成 `PartitionRangeBound`（:64-70，带 `kind[]`：MINVALUE/VALUE/MAXVALUE），共 2×nparts 个边界排序（:730，比较器 `partition_rbound_cmp` :3476：先逐列比 kind（enum 序即 MIN<VALUE<MAX），再调用该列 opfamily 的比较函数；相等时**排他界排在前** :3527-3528）。去重后（:739-788），`indexes[]` 的语义是：**槽位 i 是某个分区的上界 ⇒ indexes[i]=该分区；是下界 ⇒ indexes[i]=-1**（:844-855），末尾补一个 -1（:868-870），所以 `nindexes = ndatums + 1`（:807）。

定位（execPartition.c:1735-1748）：`partition_range_datum_bsearch`（partbounds.c:3682，比较器 `partition_rbound_datum_cmp` :3543 逐列比元组值与边界）找到 ≤ 元组的最大边界，分区号取 `indexes[offset+1]`：

```c
/* execPartition.c:1742-1748 */
/*
 * The bound at bound_offset is less than or equal to the
 * tuple value, so the bound at offset+1 is the upper bound of
 * the partition we're looking for, if there actually exists one.
 */
part_index = boundinfo->indexes[bound_offset + 1];
```

range 必须二分而 hash 不用的原因：range 的"分区"不是键空间的等价类而是有序区间，成员资格判定本质是**比较**而非映射；二分把每行路由从 O(n) 降为 O(log n)。任何两列 MINVALUE/MAXVALUE 的参与都会让"范围"退化成前缀比较，`partition_rbound_cmp` 返回值的绝对值恰好编码了"第一列不同的列号"（partbounds.c:3530），供调用方区分。

> 路由热路径缓存：连续 PARTITION_CACHED_FIND_THRESHOLD=16 次（execPartition.c:1535）命中同一 datums 槽位后，改为"先验缓存槽位，失败再回退二分"（execPartition.c:1645-1661 list、:1695-1733 range），针对时间戳单调流入的场景。default/NULL 分区不缓存（:1571-1575）。

---

## 3. 路由专节：ExecFindPartition 的逐层下降

### 3.1 下降循环

入口 `ExecSetupPartitionTupleRouting`（execPartition.c:221）只建根的 `PartitionDispatch`；真正的查找在 `ExecFindPartition`（execPartition.c:268）：

1. 先检查根自身的分区约束（若根也是别人分区，:293-294，调 `ExecPartitionCheck`，execMain.c:1925）。
2. `while (dispatch != NULL)` 每层：`FormPartitionKeyDatum` 从 slot 求分区键值（:317，定义 :1481，支持列与表达式键）。
3. `get_partition_for_tuple` 定位（:324）；找不到且无 default → 报 `no partition of relation ... found for row`（:331-338）。
4. 是叶子（`partdesc->is_leaf[partidx]`，:341）：复用或新建该叶子的 `ResultRelInfo`（:348-387），出循环。
5. 是中间层：懒初始化子 `PartitionDispatch`（:420-424），并且**如果下一层列序/列集与上一层不同，做槽位转换**：

```c
/* execPartition.c:436-446 */
if (dispatch->tupslot)
{
    AttrMap    *map = dispatch->tupmap;
    TupleTableSlot *tempslot = myslot;

    myslot = dispatch->tupslot;
    slot = execute_attr_map_slot(map, slot, myslot);
    ...
}
```

`tupmap` 在建立 dispatch 时由 `build_attrmap_by_name_if_req` 按名字匹配生成（execPartition.c:1339-1342）；叶子层的"根→叶"转换同理，`ExecInitRoutingInfo` 里为需要转换的叶子创建专属 `ri_PartitionTupleSlot`（execPartition.c:1199-1211）。default 分区被路由到时还要现场重查约束，防止并发新增分区后 default 范围已变化（:457 及其后注释）。

### 3.2 UPDATE 跨分区移动：delete + insert

UPDATE 若使行不再满足所在分区的分区约束，执行器把它翻译成"从旧分区 DELETE + 从根重新路由 INSERT"。判定点在 `ExecUpdateAct`（nodeModifyTable.c:2458）：分区约束检查失败即触发（nodeModifyTable.c:2489-2491），进入 `ExecCrossPartitionUpdate`（nodeModifyTable.c:2215）：

- `ON CONFLICT DO UPDATE` 直接拒绝跨分区移动（nodeModifyTable.c:2241-2245）；
- 在叶子上直接 UPDATE 出界时报分区约束错（:2251-2252）；
- 先 `ExecDelete(... changingPart=true ...)`（:2284-2289），DELETE 若因并发更新没删成，走重试槽位（:2309-2343——CTID 链不能跨关系，EvalPlanQual 无法覆盖，只能放弃移动以防一行变两行，注释 :2298-2307）；
- 把新行用 `ExecGetChildToRootMap` 转回根的列布局（:2350-2354），再 `ExecInsert(context, mtstate->rootResultRelInfo, slot, ...)` 从根重新路由（:2356-2359）；
- 跨分区移动后，由根表上排队的 AR-UPDATE 触发器 + `ExecCrossPartitionUpdateForeignKey`（:2546-2553）兜底检查外键。

---

## 4. 剪枝专节：同一套 steps，两个执行时机

核心思想：把 WHERE 子句编译成**剪枝步骤链**（`PartitionPruneStep`：单键比较 step 或 AND/OR 组合 step），对步骤链求值得到幸存分区位图。生成在 `gen_partprune_steps`（partprune.c:744），子句分类匹配在 `match_clause_to_partition_key`（partprune.c:1827）。

三种时机的分工（execPartition.c:1937-1952 的权威注释）：

| 时机 | 条件 | 入口 |
|---|---|---|
| 规划期初剪 | 与常量比较（PARAM_EXEC 之外） | planner: `prune_append_rel_partitions`（partprune.c:780），由 `expand_partitioned_rtentry` 调用（src/backend/optimizer/util/inherit.c:350），幸存分区决定哪些子 RelOptInfo 会被创建 |
| 启动期初剪 | 非常量但 stable（不含 PARAM_EXEC） | executor 启动：`ExecDoInitialPruning`（execPartition.c:2006），由 InitPlan 统一调用（execMain.c:882）；被剪掉的子计划**根本不初始化**（execPartition.c:1951-1952） |
| 每扫描重剪 | 含 PARAM_EXEC（如 nestloop 参数） | 每次扫描前 `ExecFindMatchingSubPlans`（execPartition.c:2678）；Append 在 rescan 时调用（nodeAppend.c:584/651/727） |

规划期剪枝流程：`prune_append_rel_partitions` 用 `PARTTARGET_PLANNER` 生成 steps（partprune.c:805），自相矛盾（contradictory）直接返回空集（:807-808），否则 `get_matching_partitions`（:846）跑步骤链。逐策略求值：`get_matching_hash_bounds`（:2704，只有全键等值才能剪）、`get_matching_list_bounds`（:2781）、`get_matching_range_bounds`（:2992，按 =/</>/... 调整二分得到的 [minoff,maxoff] 区间）。单键 step 求值在 `perform_pruning_base_step`（:3458），组合 step 在 `perform_pruning_combine_step`（:3606，AND 取交集/OR 取并）。

计划传递：CreatePlan 时 Append/MergeAppend 携带剪枝条件，`make_partition_pruneinfo`（partprune.c:225）把步骤序列化进计划（createplan.c:1428 Append、:1610 MergeAppend）；执行器端 `ExecInitPartitionExecPruning`（execPartition.c:2062，nodeAppend.c:151）取出并决定"初始剪掉的子计划不进 as_valid_subplans"。启动期生成 steps 用 `PARTTARGET_INITIAL`（partprune.c:95，生成点 :549）。

一个重要边界：规划期剪枝的对象是**每个分区层次的 RelOptInfo**，多级分区自顶向下逐层剪（子层还能继承父层的剪枝结论）；运行期剪枝的对象是 **Append/MergeAppend 的子计划索引**，二者通过映射表连接（make_partitionedrel_pruneinfo, partprune.c:446）。

---

## 5. DDL 专节：绑定校验与 ATTACH/DETACH 并发

### 5.1 CREATE TABLE ... PARTITION OF 的绑定

DefineRelation 中：`transformPartitionBound`（tablecmds.c:1203）把 SQL 文本转成 `PartitionBoundSpec`，随即 `check_new_partition_bound`（tablecmds.c:1209 → partbounds.c:2884）做**重叠检查**——重叠是硬错误而非警告：

- default 已存在 → `partition ... conflicts with existing default partition`（partbounds.c:2902-2911）；
- hash：新 modulus 必须整除/被整除相邻 modulus（:2944-3005），余数槽位重叠 → 走 range 类似的重叠报错（:3225 `partition ... would overlap partition ...`）；
- range：新边界与既有边界构成区间相交 → 同 :3225 报错；
- 新分区落地后，default 分区的约束会收窄，其**存量数据**必须仍满足新约束：`check_default_partition_contents`（tablecmds.c:1219-1226 → partbounds.c:3239）。

随后 `StorePartitionBound`（tablecmds.c:1229）写 pg_partitioned_table/pg_class，`StoreCatalogInheritance`（:1234）写 pg_inherits。

### 5.2 ATTACH PARTITION

`ATExecAttachPartition`（tablecmds.c:20963）：加 AccessExclusiveLock 后复用同一 `check_new_partition_bound`（:21193），然后对 attach 进来的表**逐行扫描验证**新推导的分区约束（`QueuePartitionConstraintValidation`，:21252、机制 :20880-20950；attach 到含 default 的父表时还要反向验证 default 的存量数据 :21282）。索引侧要逐个 match/attach 子索引（:21315 起）。

### 5.3 DETACH PARTITION 与两阶段并发拆离（PG14+）

普通 DETACH：`ATExecDetachPartition`（tablecmds.c:21662）持 AccessExclusiveLock 删 pg_inherits 行。`DETACH CONCURRENTLY` 拆成两阶段：

1. 第一事务：只对子表加 ShareUpdateExclusiveLock（:21701-21704），置 `inhdetachpending`（`MarkInheritDetached`，tablecmds.c:18528；同时强制同一父表**只允许一个 pending**，:18551-18556）。此时该分区对普通查询仍可见，但规划器/路由不再选它，且不能再 ATTACH 其它分区。
2. 第二事务（`ATExecDetachPartitionFinalize`，tablecmds.c:22169）：`WaitForOlderSnapshots` 等旧快照全部退出（:22183），再真正删 pg_inherits 行。

限制：父表存在 default 分区时禁止并发 DETACH（tablecmds.c:21693-21700）——default 约束必然要改，而改约束必须锁全表，两阶段反而更糟（注释 :21685-21691 论证）。

---

## 6. 与前作对照

- **MySQL 分区（同类）**：MySQL 的分区对优化器基本不可见（单表句柄内按分区函数路由，无跨分区唯一索引、无分区级 join/剪枝计划）。PG 把分区做成"优化器一等公民"：每个分区是独立 RelOptInfo，可参与 partitionwise join（partbounds.c:1107 的 bounds 合并就是为此）与并行 Append。
- **Kafka 分区（消息路由）**：Kafka 的分区是"生产者算 hash/轮询 → 固定分区号"，分区号即物理副本单位；PG 路由的落点不是"编号"而是"哪个子表"，且允许 default 分区兜底、允许运行中增删分区（boundinfo 是 relcache 内可失效重建的数据，不是集群元数据）。
- **LevelDB（无分区）**：单库内用 memtable/L0-L6 分层代替"按行分布"，没有"逻辑表=N 物理表"的概念；PG 的分区则是用户显式声明键空间的切分契约。
- **传统继承（ONLY/inheritance）**：旧机制父表可有存储，子表无绑定约束，读取靠 `expand_inherited_rtentry`（inherit.c:88）枚举全部子表 + constraint_exclusion 事后剔除；写入**不路由**（直接写父表就真的写在父表里）。新分区的差别：父表无存储（relkind 'p'）、绑定边界强制互斥（第 5.1 节）、写入自动路由（第 3 节）、剪枝是结构化的而非逐子表试约束。`src/backend/catalog/partition.c`（392 行）只留小工具：`get_partition_parent`（:53，可要求连 pending-detach 的父也算）、`map_partition_varattnos`（:222，把约束表达式列号映射到父）、`has_partition_attrs`（:255）；树形遍历的 SQL 接口 `pg_partition_tree` 在 src/backend/utils/adt/partitionfuncs.c:62。

---

## 7. 设计动机

1. **为什么分区键必须是主键/唯一约束的前缀**（indexcmds.c:993-1127）：PG 没有全局索引，唯一性由"每个分区各自的本地索引"拼出来；若唯一列不含分区键，两行同一键值可路由到不同分区各自"唯一"。检查逻辑：对分区键的每一列，要求它出现在索引列里（:1055-1057），且相等语义同源（hash 策略用 HTEqualStrategyNumber，其余用 BTEqualStrategyNumber，:1028-1031）；分区键含表达式时直接不支持（:1046-1052）。这是"本地索引换取分布式唯一性"的经典折衷。
2. **为什么路由/约束要用 `satisfies_hash_partition` 函数表达式**（partbounds.c:4759，get_qual_for_hash 生成 :3971-4049）：hash 边界无法写成普通比较谓词，于是把"该行是否归我"编译成一个 SQL 可见函数放进分区约束，触发器/外键/attach 校验全部复用同一套约束机制。
3. **为什么两阶段 DETACH**：单事务 DETACH 要拿父表 AccessExclusiveLock 并改 default 约束，长查询必然阻塞或被阻塞；两阶段让"退出分区树"（影响路由）与"删除继承关系"（影响元数据）解耦，期间读写不中断，代价是 pending 期间该分区对查询可见但不可路由（见第 5.3 节）。
4. **路由 vs UNION ALL 视图**：UNION ALL 把"切分契约"交给规划器枚举，写入端用户必须自己选子表，且每加一张子表都要改视图文本；分区把契约内化到 relcache 的 boundinfo——一条 INSERT 的目标解析是 O(log n)（或 hash O(1)）的比较，SELECT 的剪枝直接在计划/执行结构上减子计划，而非多生成一个子查询。
5. **为什么 indexes[] 与 datums[] 分离**：同一套"边界数组 → 分区号"结构让三种策略、剪枝、路由、join 合并共用一个规范化形态（partition_bounds_equal 可直接比较，:886），新增策略只需重写 create_*_bounds 与 get_matching_*_bounds 两端。

---

## 8. FAQ 素材

1. INSERT 报 "no partition of relation ... found for row"（execPartition.c:331-338）：该层 bound 没命中且无 default；range 键含 NULL 也算未命中（execPartition.c:1679-1693，NULL 永远不进任何 range 分区）。
2. list 定位为什么不是哈希表：boundinfo 要做规范化比较、join 合并、剪枝区间推理，有序数组一体满足；单列二分已够快（partbounds.c:3594-3626）。
3. 热路径缓存何时生效：同一 datums 槽位连续命中 16 次后启用，hash/default/NULL 不参与（execPartition.c:1535、1571-1575）。
4. 跨分区 UPDATE 为什么不走 EvalPlanQual：CTID 链不能跨关系，只能"删不成就不插"（nodeModifyTable.c:2298-2307）。
5. 为什么 ON CONFLICT 不能跨分区移动（nodeModifyTable.c:2241-2245）：冲突仲裁发生在旧分区的本地索引上，移动后新行的唯一性约束体系完全不同，语义无法自洽。
6. 一次路由跨多级时行会被转换几次：每个"列序不同的中间层"一次（execPartition.c:436-446），到达叶子后若与根不同再一次（execPartition.c:1199-1211）；按名字匹配建映射（execPartition.c:1339）。
7. 启动期剪枝省的不仅是扫描：被剪的子计划根本不初始化（execPartition.c:1951-1952），几百个分区时省掉的是几百次 ExecInit*。
8. hash 分区数量怎么扩：只能 modulus 整除扩容（partbounds.c:2926-3005），模 4→8 时旧分区边界不动、新分区接管偶数余数槽位（indexes[] stride 填充，partbounds.c:412-418）。
9. default 分区为什么让并发 DETACH 失效：default 约束必须随分区增删收窄/放宽，约束校验需要全表锁（tablecmds.c:21685-21700）。
10. 剪枝和 constraint_exclusion 的区别：剪枝基于 boundinfo 的结构化推理（步骤链+位图），对分层区间比较精确到界；constraint_exclusion 是逐子表试谓词的旧机制，仅传统继承仍在用。

## 9. 深挖清单

1. **分区级 join**：`partition_bounds_merge`（partbounds.c:1107）+ merge_list/range_bounds（:1187/:1495）如何把两侧边界合并出"逐分区配对"，及其对 `interleaved_parts`（partbounds.h:87-89）的保守处理。
2. **剪枝步骤链的代数**：`gen_prune_steps_from_opexps`（partprune.c:1411）对多列键生成前缀化 step 组合（get_steps_using_prefix, :2479），等价于"比较谓词 → 边界区间"的区间代数。
3. **relcache 生命周期**：partdesc 专用内存上下文与引用计数约定（partdesc.c:62-68 注释），两份 partdesc（含/不含 pending-detach）按 pg_inherits.xmin 与活跃快照判断可否复用（partdesc.c:83-107）。
4. **分区目录**：`CreatePartitionDirectory`/`PartitionDirectoryLookup`（partdesc.c:422/:455）在一条查询内统一 rel 缓存，避免规划期反复 open 同一分区。
5. **初始化分区消除与并行**：es_part_prune_states/es_part_prune_results 的统一 InitPlan 流水（execMain.c:882 上下文，execPartition.c:1983-2039）如何影响 as_valid_subplans 与并行 worker 的子计划选择。

---

## 写作要点速查表

| 事实 | 位置 |
|---|---|
| 三种边界结构 PartitionHashBound/ListValue/RangeBound | src/backend/partitioning/partbounds.c:49-70 |
| PartitionBoundInfoData（datums/indexes/null_index/default_index） | src/include/partitioning/partbounds.h:79-96 |
| hash 构建取最大 modulus 为 nindexes，stride 铺 indexes[] | partbounds.c:347-421（387、412-418） |
| hash 定位：indexes[rowHash % nindexes]，不缓存 | src/backend/executor/execPartition.c:1605-1620 |
| list 定位：排序+二分 partition_list_bsearch | partbounds.c:3594-3626；调用 execPartition.c:1663 |
| range 上界数组：lower→-1、upper→分区号、nindexes=ndatums+1 | partbounds.c:844-855、:807 |
| range 定位：datum 二分 + indexes[offset+1] | partbounds.c:3682-3717；execPartition.c:1735-1748 |
| 路由热路径缓存阈值 16 | execPartition.c:1535 |
| 逐层下降 + 层间列映射 execute_attr_map_slot | execPartition.c:268-447（映射 :436-446、建映射 :1339） |
| 跨分区 UPDATE：ExecUpdateAct 检查→ExecCrossPartitionUpdate=delete+root insert | src/backend/executor/nodeModifyTable.c:2489-2559、:2215-2370（:2284/:2358） |
| 规划期剪枝入口 prune_append_rel_partitions（调用点 inherit.c:350） | src/backend/partitioning/partprune.c:780-833 |
| 启动期初剪 ExecDoInitialPruning（InitPlan 调用 execMain.c:882） | execPartition.c:2006-2039 |
| 运行期重剪 ExecFindMatchingSubPlans（Append rescan） | execPartition.c:2678；nodeAppend.c:584/651/727 |
| 剪枝条件进计划：make_partition_pruneinfo（Append/MergeAppend） | src/backend/optimizer/plan/createplan.c:1428、:1610 |
| CREATE...PARTITION OF 绑定校验 check_new_partition_bound | partbounds.c:2884；调用 tablecmds.c:1209 |
| 重叠即错误 "would overlap" | partbounds.c:3225 |
| ATTACH：校验+排队逐行验证约束 | src/backend/commands/tablecmds.c:20963、:21193、:21252 |
| 并发 DETACH 两阶段：inhdetachpending→Finalize 等快照 | tablecmds.c:21662、:18528、:22169（:22183） |
| 唯一约束须含分区键（前缀）检查 | src/backend/commands/indexcmds.c:993-1127 |
| hash 约束函数 satisfies_hash_partition / 种子 | partbounds.c:4759、get_qual_for_hash :3971；src/include/catalog/partition.h:20 |
