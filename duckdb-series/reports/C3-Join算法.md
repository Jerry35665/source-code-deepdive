# 报告 C3 · Join 算法深挖(DuckDB 卷三)

> 基线:7e886f44428e90c8379d4d34e2afb866108ff079(2026-09-17)。一句话:DuckDB 单个 Join 算子内部 = "计划期按条件形态选 7 种物理算子 + 哈希连接的 per-thread 分区构建/盐值线性探测/外置溢出 + 完美哈希与运行时过滤器旁路 + IEJoin/归并/NLJ 兜底非等值",全部实现于 src/execution/operator/join/ 与 src/execution/join_hashtable.cpp。

说明:路径均相对 `repos/duckdb/`;行号以该 commit 为准。本章只讲算子内部,不重复卷一 04(DPhyp)/05(执行器与并行)。

## 一、算法选择总控:一个函数决定用哪种 join

选择逻辑集中在 `PlanComparisonJoin`(src/execution/physical_plan/plan_comparison_join.cpp:177-287)。决策链:

```cpp
if (op.conditions.empty()) return Make<PhysicalCrossProduct>(...);        // plan_comparison_join.cpp:215-217
idx_t has_range = 0;
bool has_equality = op.HasEquality(has_range);                            // :220-221
bool can_merge  = has_range > 0;                                          // :222
bool can_iejoin = has_range >= 2 && recursive_cte_tables.empty();         // :223
...SEMI/ANTI/MARK: can_merge 需单条件; RIGHT_ANTI/RIGHT_SEMI: can_iejoin=false  // :224-237
if (has_equality && !prefer_range_joins) return Make<PhysicalHashJoin>(...);   // :242-247
if (left/right 估计基数 < NestedLoopJoinThreshold) { can_iejoin=false; can_merge=false; } // :251-256
if (can_merge && can_iejoin && 估计基数 < MergeJoinThreshold) can_iejoin = false;          // :258-263
if (can_iejoin) return Make<PhysicalIEJoin>(...);                         // :265-268
if (can_merge)  return Make<PhysicalPiecewiseMergeJoin>(...);             // :269-273
if (PhysicalNestedLoopJoin::IsSupported(...)) return Make<PhysicalNestedLoopJoin>(...); // :274-278
return Make<PhysicalBlockwiseNLJoin>(...);                                // :280-286
```

- `HasEquality` 把 COMPARE_EQUAL/NOT_DISTINCT_FROM 记为等值,>/>=/</<= 计入 `has_range`(src/planner/operator/logical_comparison_join.cpp:35-58)。
- 即:有任一等值条件→哈希连接;2 个以上范围条件→IEJoin;1 个范围条件→piecewise merge join;都不行且类型受支持→NLJ;含任意表达式→blockwise NL join(src/execution/physical_plan/plan_comparison_join.cpp:242-286)。
- 构造前 `ReorderConditions` 把等值条件排到最前(src/execution/operator/join/physical_comparison_join.cpp:58-77),哈希连接因此只需处理前缀等值、后缀非等值。
- 非比较条件的"任意条件"合成为 `predicate` 残余谓词挂在比较连接基类上(src/execution/operator/join/physical_comparison_join.cpp:14-24)。
- 物理算子家族全集:BLOCKWISE_NL_JOIN/NESTED_LOOP_JOIN/HASH_JOIN/CROSS_PRODUCT/PIECEWISE_MERGE_JOIN/IE_JOIN/LEFT|RIGHT_DELIM_JOIN/POSITIONAL_JOIN/ASOF_JOIN(src/include/duckdb/common/enums/physical_operator_type.hpp:56-67);ASOF join 在 plan 层单独分派(plan_comparison_join.cpp:291-292)。

选型速查(以源码为据):

| 条件形态 | 物理算子 | 关键门槛 |
|---|---|---|
| 无条件 | CROSS_PRODUCT | conditions.empty()(plan_comparison_join.cpp:215-217) |
| ≥1 等值(且非 prefer_range_joins) | HASH_JOIN | has_equality(:242-247) |
| ≥2 范围条件、无等值 | IE_JOIN | has_range>=2 且非递归 CTE 表(:223、265-268) |
| 1 个范围条件 | PIECEWISE_MERGE_JOIN | can_merge;SEMI/ANTI/MARK 需单条件(:222-237、269-273) |
| 其余比较条件 | NESTED_LOOP_JOIN | IsSupported:排除嵌套类型,SEMI/ANTI 限单比较(:274-278;physical_nested_loop_join.cpp:123-152) |
| 任意布尔表达式条件 | BLOCKWISE_NL_JOIN | 兜底(plan_comparison_join.cpp:280-286) |

`PreferRangeJoins` 设置为真时,即使有等值也可强行走 range join 家族(plan_comparison_join.cpp:240-241);`NestedLoopJoinThreshold`/`MergeJoinThreshold` 用估计基数压制小输入上的重排序 join(:251-263)。

## 二、哈希连接构建侧:per-thread 分区 HT + 三级 Finalize

构建走 sink 接口,三步:Sink(每线程)→ Combine(挂链)→ Finalize(建指针表)。

1. Sink:执行右键表达式,发布行布局,把 [键|payload|(found 位)|hash] 行追加进线程本地的 radix 分区集合(src/execution/operator/join/physical_hash_join.cpp:764-796)。行布局在首个 chunk 到达时由 `PublishLayoutIfFirst` 经 LayoutGate 全局发布一次,物理算子类型对应 src/execution/operator/join/physical_hash_join.cpp:623-656;布局类型序列 = conditions+payload+(RIGHT/FULL 的 found bool)+hash(src/execution/operator/join/physical_hash_join.cpp:556-575)。
2. 分区:每线程 `JoinHashTable` 内的 `sink_collection` 是 `RadixPartitionedTupleData`,按**行内最后一列(完整 hash)的低 radix_bits** 分区,initial_radix_bits = 线程数 <100 ? 4 : 5(src/execution/operator/join/physical_hash_join.cpp:331-336;src/include/duckdb/common/radix_partitioning.hpp:116-146,hash_col_idx = ColumnCount()-1 由 join_hashtable.cpp 构造传入)。
3. NULL 键:build 侧 `PrepareKeys` 过滤 NULL(除非 RIGHT/FULL OUTER 或 IS NOT DISTINCT FROM,此时置 `has_null`)(src/execution/join_hashtable.cpp:714-742;691-694)。

```cpp
// src/execution/join_hashtable.cpp:699-711(Build 尾部)
Hash(keys, *current_sel, added_count, hash_values);      // 只对等值键逐列 Hash+CombineHash :405-419
if (bloom_filter.IsInitialized()) bloom_filter.InsertHashes(hash_values);
...
sink_collection->AppendUnified(append_state, source_chunk, *current_sel, added_count);
```

4. Combine:各线程 HT(空布局的直接丢弃)以引用挂到 `gstate.local_hash_tables`,并合并各自 bloom filter(src/execution/operator/join/physical_hash_join.cpp:802-834;src/execution/join_hashtable.cpp:182-183)。
5. Finalize:先按总大小决定是否外置(见 §三);内存态则 `Merge` 各线程分区、`Unpartition` 折叠成单集合(physical_hash_join.cpp:1902-1908;join_hashtable.cpp:2461-2462),`AllocatePointerTable` 按 count×load_factor(2.0,最小 16384 槽)分配 ht_entry_t 指针表(join_hashtable.cpp:1048-1083;src/include/duckdb/execution/join_hashtable.hpp:565-577),随后 `Finalize` 从行内重读 hash 逐 chunk `InsertHashes`,用 CAS 无锁链头插入构建拉链(join_hashtable.cpp:1113-1139、859-984、756-790)。
6. 并行度门控:单线程或行数 < 1048576 或"最大分区占比 > 0.33 的倾斜"时 finalize 单线程,否则指针表 memset 与 InsertHashes 都按分区并行(physical_hash_join.cpp:840-875、940-973、1001-1041)。

内存预算在 Sink→Finalize 之间协商:每个算子在 GlobalSinkState 注册 `TemporaryMemoryState`,PrepareFinalize 时汇总各线程各分区尺寸得到 `total_size` 与最大分区,再按 `num_threads × 分区数 × 每分区块数` 估算 probe 侧 `probe_side_requirement`,并设为最小预留(physical_hash_join.cpp:329-336、884-903、905-938):

```cpp
// src/execution/operator/join/physical_hash_join.cpp:927-937(节选)
gstate.total_size = ht.GetTotalSize(gstate.local_hash_tables, gstate.max_partition_size, gstate.max_partition_count);
gstate.probe_side_requirement =
    GetPartitioningSpaceRequirement(context, children[0].get().GetTypes(), ht.GetRadixBits(), gstate.num_threads);
const auto max_partition_ht_size =
    gstate.max_partition_size + gstate.hash_table->PointerTableSize(gstate.max_partition_count);
gstate.temporary_memory_state->SetMinimumReservation(max_partition_ht_size + gstate.probe_side_requirement);
```

递归 CTE 复用:同一算子迭代重建时 `Reset` 走 `ResetForNewIterationSinglePartition`——清行数据、radix_bits 归 0(单分区,省每轮 16 分区开销),布局/字典注册表跨轮保留(physical_hash_join.cpp:377-408;join_hashtable.cpp:2560-2596);finalize 后的 build 还可被后续迭代整体保留(`preserve_build_for_reuse`,physical_hash_join.cpp:734-751),但外置模式下禁用(physical_hash_join.cpp:1858-1864)。

## 三、探测侧:salt 线性探测、RowMatcher 与外置溢出(含数据流图)

探测时每个 ht_entry_t 打包"48 位行指针 + 16 位 salt"(取自 hash 高 16 位),entry 非零即占用(src/include/duckdb/execution/ht_entry.hpp:29-33)。仅当容量 > 8192(超出 CPU cache)才启用 salt 比较(join_hashtable.hpp:89-96;join_hashtable.cpp:387-390)。

```cpp
// src/execution/join_hashtable.cpp:206-226(节选,build/probe 共用)
for (idx_t i = 0; i < count; i++) {
    salt_data.WriteValue(ht_entry_t::ExtractSalt(hashes[i]));  // 高 16 位存为 salt
    hashes[i] &= bitmask;                                       // 低位取模定位槽
}
```

探测主循环:hash&bitmask 定槽→占用且 salt 相等才把行指针加入比较集→`RowMatcher` 逐列精确比较键→不匹配则 offset+1 继续线性探测(join_hashtable.cpp:249-312、340-384、352-353)。冲突行靠行内 next 指针拉链(joined 文档:join_hashtable.hpp:51-61;链遍历 GetNextPointer :295-305)。单等值条件时另有"压缩探测"快速路径:对常量向量(`TryProbeConstant`,join_hashtable.cpp:1352+)与存储字典向量(`TryProbeDictionary`,每字典槽只探测一次并缓存指针,阈值 20000 槽,join_hashtable.cpp:1211-1349、1213-1214)。

内存不足→外置(external)哈希连接,判据与流程:

```cpp
// src/execution/operator/join/physical_hash_join.cpp:1833-1837、1858-1879(节选)
sink.external = sink.temporary_memory_state->GetReservation() < sink.total_size;
if (sink.external) {
    ht.load_factor = JoinHashTable::EXTERNAL_LOAD_FACTOR;            // 1.5,可能"救回"内存态 :1844-1854
    const auto very_very_skewed = max_partition_ht_size >= 0.8 * total_size;
    if (!very_very_skewed && (max_partition_ht_size + probe_side_requirement) > reservation) {
        ht.SetRepartitionRadixBits(...);        // 加 radix bits,目标分区 ≈ 预算/4 :join_hashtable.cpp:2465-2487
        ... HashJoinRepartitionEvent            // 各线程本地重分区再 Merge  :1194-1293
    }
}
```

外置时探测侧溢出:probe 行若其 hash 分区不在当前构建集合,连同行尾**预计算 hash**写入 `ProbeSpill`(同样 radix 分区的 ColumnDataCollection);probe_types 在构造时追加了 HASH 列(physical_hash_join.cpp:347-349;join_hashtable.cpp:2663-2701)。source 侧以阶段机驱动多轮 BUILD→PROBE→SCAN_HT(全外/右外补齐)→下一轮 PrepareBuild(src/execution/operator/join/physical_hash_join.cpp:2149、2346-2376、2378-2420;分区按尺寸升序贪心打包进本轮:join_hashtable.cpp:2601-2661)。内存态 INNER 等不传播 build 侧的 join,探测完直接 Reset 释放整张 HT(physical_hash_join.cpp:2626-2638;传播语义见 src/common/enums/join_type.cpp:14-18)。空 build 侧且 INNER/RIGHT/SEMI 直接 NO_OUTPUT_POSSIBLE(physical_hash_join.cpp:1953-1955;src/execution/operator/join/physical_join.cpp:14-26)。

外置多轮的关键环节:

```cpp
// src/execution/join_hashtable.cpp:2663-2696(节选,ProbeAndSpill)
const auto true_count = RadixPartitioning::Select(hashes, ..., radix_bits,
                                                  current_partitions, &true_sel, &false_sel);
// can't probe these values right now, append to spill
spill_chunk.data.back().Reference(hashes);        // 预计算 hash 一并存入 spill
probe_spill.Append(spill_chunk, spill_state);
// slice the stuff we CAN probe right now
hashes.Slice(true_sel, true_count); ...
```

- 重分区任务受内存约束:repartition_threads 由预留/线程内存需求推出,超出的本地 HT 先两两 Merge 再删(physical_hash_join.cpp:1228-1268)。
- 外置探测扫描溢出数据时直接用行内预计算 hash,免二次哈希(physical_hash_join.cpp:2596-2599;`precomputed_hashes` 入参走 join_hashtable.cpp:1197-1199)。
- 全外/右外的 build 侧补齐(SCAN_HT)在每轮 probe 完成后执行,`MaxThreads` 按 HT 行数估算并行度(physical_hash_join.cpp:2168-2181)。

```
            build(RHS, sink pipeline)                         probe(LHS, operator/source)
 chunk ─▶ join_key_executor 算右键                             chunk ─▶ probe_executor 算左键
        │ PublishLayoutIfFirst:首 chunk 定行布局                        │ Probe():Hash(keys)=h
        ▼                                                              ▼
 [键 | payload | (found) | hash] 行                          h&bitmask 定槽 → ht_entry.salt 比较
        ▼                                                              │ salt 命中 → RowMatcher 精确比键
 PrepareKeys 滤 NULL(RIGHT/FULL 除外)                                ▼
        ▼                                                     链表 next 指针遍历 → GatherRHS/字典发射
 RadixPartitionedTupleData(P=hash 低 radix_bits)              外置:分区未建 → ProbeSpill(附预计算hash)
        ▼                                                              ▼
 Combine:线程 HT 挂 gstate.local_hash_tables          SCAN_HT:全/右外扫 found=false 行补 NULL
        ▼                                                              ▼
 Finalize:Merge→Unpartition→分配指针表(并行 memset)      PrepareExternalFinalize 取下一批分区 → 重建再探测
           → InsertHashes(CAS 建链)→ finalized=true             (阶段机 BUILD→PROBE→SCAN_HT→…→DONE)
```

## 四、完美哈希连接与运行时过滤器(join filter pushdown)

完美哈希(PHJ)在 GlobalSinkState 构造时做静态门槛检查:恰好 1 个条件、build 侧统计有 min/max 且为整型(physical_hash_join.cpp:274-284);Finalize 时再以真实 min/max 复核:

```cpp
// src/execution/operator/join/perfect_hash_join_executor.cpp:85-89、121-130(节选)
if (op.join_type != JoinType::INNER || op.conditions.size() != 1 ||
    op.conditions[0].GetComparisonType() != ExpressionType::COMPARE_EQUAL ||
    !TypeIsInteger(key_type.InternalType())) return false;
...
static constexpr idx_t MAX_BUILD_SIZE = 1048576;   // build 键域跨度上限
if (build_range > Hugeint::Convert(MAX_BUILD_SIZE)) return false;
if (ht.Count() > perfect_join_statistics.build_range) return false;   // 重复键超域→放弃
```

- 有残余谓词(op.predicate)、build 侧含嵌套类型、min/max 提取失败均回退(perfect_hash_join_executor.cpp:74-100、111-113);运行时若 dict-surviving 已收窄槽宽也会禁用 PHJ(physical_hash_join.cpp:1925-1929)。
- 成功路径:`BuildPerfectHashTable` 为每个 build 输出列建 build_range+1 大小的可复用全局字典向量,`FullScanHashTable` 扫原 HT 把 payload Gather 进 perfect 表并用 bitmap 查重(perfect_hash_join_executor.cpp:139-194);探测退化为"下标计算 + Dictionary 向量包装",dense 且 probe 全在域内时直接 Reference 零拷贝(perfect_hash_join_executor.cpp:279-309)。
- 失败回退:`perfect_join_executor.reset()` 后走常规 `ScheduleFinalize` 建哈希表,PHJ 期间算出的 min/max 被复用为过滤器(physical_hash_join.cpp:1930-1951)。

运行时过滤器即 join filter pushdown:build 侧 Sink 时对推送列做 min/max 聚合(physical_hash_join.cpp:753-762、772-774),Finalize 后按条件选型发布:小 HT(≤ DynamicOrFilterThreshold)用 IN 列表,单等值列用 Bloom Filter(要求 build/probe 估计比 ≤1.0,且无下游过滤时 build>4M 行禁用),等值+支持类型再试 Prefix Range Filter,均作为 `DeferredRuntimeFilterType::BLOOM_FILTER/PREFIX_RANGE` 延迟到 finalize 后发布到 probe 侧扫描(physical_hash_join.cpp:1295-1364、1697-1818、1122-1146;src/include/duckdb/execution/operator/join/join_filter_pushdown.hpp:50-58)。LEFT join 推导出的 RHS 过滤则来自优化期 FilterCombiner(见 §六)。

## 五、非等值家族:IEJoin、piecewise merge join、NLJ、cross product

**IEJoin(≥2 个范围条件)**。构造时把前两个条件转成排序方向——条件 1(>≥降序/<≤升序)排 L1,条件 2 相反方向排 L2(src/execution/operator/join/physical_iejoin.cpp:28-58);两侧各自物化+排序(`GlobalSortedTable`),source 阶段机依次 SINK_L1→FINALIZE/MATERIALIZE→EXTRACT_Li→…→INNER/OUTER/ANTI(physical_iejoin.cpp:236-250)。L1∪L2 合并序列 Li(行号带符号:L 为正、R 为负)与逆置换 P 由并行任务抽取(physical_iejoin.cpp:558-632);扫描时维护位阵 B,再用 1024 位/块的 bloom 数组加速 `NextValid` 找置位点(physical_iejoin.cpp:535-538、638-647、723-776):

```cpp
// src/execution/operator/join/physical_iejoin.cpp:790-824(节选,JoinBlocks)
while (i < n) {                       // 11. for(i←1 to n)
    for (;;) {                        // 13. for (j ← pos+eqOff to n)
        while (j < n_j) {             // 14. if B[j]=1 — bloom 先跳整块
            auto bloom_begin = NextValid(bloom_filter, j / BLOOM_CHUNK_BITS, bloom_count) * BLOOM_CHUNK_BITS;
            ...
            j = NextValid(bit_mask, j, bloom_end);
            if (j < bloom_end) break;
        }
        const auto rrid = li[j]; ++j;         // 同号(同表)行跳过
        lsel[result_count] = +lrid - 1; rsel[result_count] = -rrid - 1;
        ...
```

**Piecewise merge join(恰 1 个范围条件)**。RHS 物化并排序;LHS 不物化——每个到达 chunk 现场排序(`ResolveJoinKeys`:sink→combine→finalize→materialize 一个 per-chunk 的 GlobalSortedTable,physical_piecewise_merge_join.cpp:335-362),再与 RHS 有序块做归并:SEMI/ANTI 简单版只比"当前 RHS 块最大值",LHS 小于它即全部命中(physical_piecewise_merge_join.cpp:399-448);复杂 join 类型走逐行归并状态机(:537-703)。这也是 "piecewise"(逐块)的含义。

```cpp
// src/execution/operator/join/physical_piecewise_merge_join.cpp:424-445(节选,SEMI/ANTI 快路径)
// we only care about the BIGGEST value in the RHS
const auto r_entry_idx = MinValue<idx_t>(r_idx + STANDARD_VECTOR_SIZE, rhs_not_null) - 1;
while (true) {
    if (MergeJoinBefore(lhs_itr[l_entry_idx], rhs_itr[r_entry_idx], strict)) {
        found_match[l_entry_idx] = true;
        l_entry_idx++;
        if (l_entry_idx >= lhs_not_null) return 0;   // early out:LHS 全命中
    } else {
        break;  // 后面的 LHS 更大也不会命中,移到下一个 RHS 块
    }
}
```

排序复用卷一的排序基础设施:`PhysicalRangeJoin::GlobalSortedTable` 封装 sink/combine/finalize/materialize 四步与 NULL 计数(src/include/duckdb/execution/operator/join/physical_range_join.hpp:18-90),NULL 排到末尾、参与比较的只有非 NULL 前缀(`SortedChunkNotNull`,physical_piecewise_merge_join.cpp:369-374)。

**NLJ 与 blockwise NL join**。NLJ 把 RHS payload 与条件列物化成两个 ColumnDataCollection(physical_nested_loop_join.cpp:165-171),探测时逐 LHS chunk 对全部 RHS chunk 做谓词求值;`IsSupported` 排除 STRUCT/LIST/ARRAY 条件,SEMI/ANTI 仅限单比较条件,有等值时计划层已转哈希(physical_nested_loop_join.cpp:123-152)。条件含任意表达式时改用 `PhysicalBlockwiseNLJoin` 整块谓词求值(plan_comparison_join.cpp:280-286)。

**Cross product**。无条件的退化路径:RHS 物化后,每输出 chunk = "一个常驻引用 chunk × 扫描侧单值常量引用",且让较大的 chunk 做常驻以减少扫描切换(physical_cross_product.cpp:44-69、113-121、136-159)。

## 六、谓词残余、FilterCombiner 与 mark join

- 残余谓词:合成的 `predicate` 在哈希连接里拆成 probe/build 列(`ExtractResidualPredicateColumns`,physical_hash_join.cpp:108-131),探测命中链后由 `ApplyResidualPredicate` 二次过滤(join_hashtable.hpp:162-168;ScanStructure 内 residual_executor :166-168)。为此 probe 侧 chunk 需要携带"输出列+谓词列"的超集 `lhs_probe_columns`,并用 `lhs_output_in_probe` 映射回输出(physical_hash_join.cpp:133-172;探测时 ReferenceColumns 取超集 :2136)。
- FilterCombiner 在 join 上的应用:LEFT join 下推时,把等值条件与左侧过滤器一起喂给 `FilterCombiner`,若合成出仅含 RHS 列的新过滤(如 i=a 且 i=500 ⇒ a=500)则推入 RHS(src/optimizer/pushdown/pushdown_left_join.cpp:113-124、167-180):

```cpp
// src/optimizer/pushdown/pushdown_left_join.cpp:167-176(节选)
// finally we check the FilterCombiner to see if there are any predicates we can push into the RHS
// this happens if, e.g. a join condition is (i=a) and there is a filter (i=500), we can then push the filter
// (a=500) into the RHS
filter_combiner.GenerateFilters([&](unique_ptr<Expression> filter) {
    if (JoinSide::GetJoinSide(*filter, left_bindings, right_bindings) == JoinSide::RIGHT) {
        ...
```

- mark join(ANY/ALL 相关子查询):相关型在 build 侧"外挂"一个 GroupedAggregateHashTable 统计每相关组的 count(*)/count(col) 处理空组与 NULL 三值逻辑(physical_hash_join.cpp:665-709;join_hashtable.cpp:624-648);非相关多条件等值 mark join 启用 NULL 精化(`InitializeUncorrelatedMarkJoin` 保存全部 RHS 条件行,physical_hash_join.cpp:710-721;join_hashtable.cpp:644-648)。NULL 键过滤与 `has_null` 标志共同决定 left/mark 补 NULL(join_hashtable.cpp:691-694、714-742)。
- IEJoin/piecewise/NLJ 也接同一套 filter pushdown:仅对 child==1(build 侧)收集 min/max(physical_iejoin.cpp:169-171、198-200;physical_nested_loop_join.cpp:180-187)。
- 全外/右外的 build 侧行打 found 标志位,探测命中后置位,`ScanFullOuter` 全表扫 found=false 行补齐结果(join_hashtable.cpp:676-680、2302-2347);RIGHT_SEMI 只传播命中行、RIGHT_ANTI 反向,故有 `match_propagation_value` 开关(join_hashtable.cpp:2317-2323)。
- 左外标记由 `OuterJoinMarker` 承担:探测命中的 LHS 行用 `SetMatch/SetMatches` 置位,扫描尾声统一补 NULL 行(src/include/duckdb/execution/operator/join/outer_join_marker.hpp:32-48)。

## 七、纠偏(以 7e886f44 源码为准)

1. **不存在 "piecewise hash join"**:该 commit 的 join 物理算子只有 HASH_JOIN/PIECEWISE_MERGE_JOIN/IE_JOIN/NESTED_LOOP_JOIN/BLOCKWISE_NL_JOIN/CROSS_PRODUCT/ASOF_JOIN 等(physical_operator_type.hpp:56-67);"piecewise" 仅修饰 merge join(LHS 逐 chunk 排序,physical_piecewise_merge_join.cpp:335-362)。早期文档里的"per-operator hash join"二分法对本基线不成立——哈希连接是单一算子,内/外置只改执行模式不改类型。
2. **等值键不做 blob 序列化**:行内直接按逻辑类型存键列(布局=[conditions|payload|found|hash],physical_hash_join.cpp:556-575),比较走 `RowMatcher` 模板化逐列比(join_hashtable.hpp:364-371;join_hashtable.cpp:352-353);全仓库 grep `SerializeVector` 为 0 处。旧版本"复杂键序列化后 memcmp"的印象不适用于本 commit。
3. **IEJoin 注释对应的是 IEJoin 论文伪代码,而非 "Lichtne?" 任何变体**:源码按 "1. let L1 … 16. B[pos]←1" 步骤注释(physical_iejoin.cpp:28-58、638-671、783-824),grep `Lichtne` 0 处;写正文时应称"IEJoin(双不等值排序合并)算法",排序方向规则见 :40-55。
4. **build 侧不是共享大表**:构建期每线程写自己的分区 HT,Combine 只挂引用,指针表到 Finalize 才分配(physical_hash_join.cpp:802-834、1167-1185);说"边 build 边查询的共享哈希表"是错的。
5. **salt 不是给哈希函数加盐**:它是 ht_entry 高 16 位里保存的 hash 片段,作探测前的廉价过滤,仅 capacity>8192 时启用(ht_entry.hpp:29-33;join_hashtable.hpp:89-96;join_hashtable.cpp:387-390)。
6. **"空 build 侧立刻空结果"只对部分 join 类型成立**:INNER/RIGHT/SEMI/RIGHT_SEMI/RIGHT_ANTI 才 NO_OUTPUT_POSSIBLE,LEFT/MARK 仍需发 NULL/UNKNOWN 行(physical_join.cpp:14-26;physical_hash_join.cpp:1953-1955、2082-2097)。

### 设计动机(为什么这么写)

- per-thread 分区 HT + Finalize 期统一建表:构建期各线程只写本地分区,无锁竞争;Combine 仅挂引用近乎零拷贝(physical_hash_join.cpp:802-834)。
- 分区键统一用完整 hash 低位:build 分区、repartition、probe spill 三者共用同一分区函数,外置多轮只探测"当前活动分区"即可保证不漏行(join_hashtable.cpp:2663-2701;radix_partitioning.hpp:116-146)。
- 指针+salt 打包进 8 字节 entry:探测时一次 load 同时拿到候选行与过滤位,把昂贵的键比较(cache miss gather)推迟到 salt 命中后(ht_entry.hpp:29-33;join_hashtable.cpp:249-312)。
- 首 chunk 布局发布(LayoutGate):按真实到达向量决定槽宽(dict-surviving 收窄为 1/2/4 字典索引),多源 build(UNION/递归 CTE)、SINGLE/LEFT/OUTER、PHJ 候选均保守禁用以保证正确性(physical_hash_join.cpp:301-312、577-609、623-656)。
- PHJ 旁路:整数单等值+键域 ≤1M 时把探测变成纯下标计算并以字典向量输出 build 列,省掉哈希表与指针表(perfect_hash_join_executor.cpp:139-194、296-307)。
- IEJoin 用 Li/P/位阵把双不等值 join 化为两次排序+线性扫描,bloom 分块再省掉对 B 的全查(physical_iejoin.cpp:535-538、723-776)。
- 运行时过滤器延迟到 finalize 后发布:用真实 build 数据的 min/max/bloom 过滤 probe 侧扫描,比计划期静态估计更准且零漏(physical_hash_join.cpp:1122-1146、1697-1818)。

### FAQ 候选(正文可展开)

1. 哪一侧是 build 侧?——算子不换边,join order 优化器输出的右子树即 build 侧,等值条件右表达式作 build 键(physical_hash_join.cpp:476-479)。
2. 何时转外置?——内存预留 < 构建总量,即 `reservation < total_size`(physical_hash_join.cpp:1833-1834);先降 load_factor 至 1.5 可能免于外置(:1844-1854)。
3. Finalize 何时单线程?——单线程、<100 万行、或最大分区 HT 占比 >0.33 的键倾斜(physical_hash_join.cpp:840-875)。
4. NULL 键怎么处理?——build/probe 两侧 PrepareKeys 过滤(除非 RIGHT/FULL 或 IS NOT DISTINCT FROM),过滤发生即置 has_null 供 left/mark 补语义(join_hashtable.cpp:714-742、691-694)。
5. 哈希冲突怎么解?——指针表线性探测 + 行内 next 指针拉链,RowMatcher 精确比键兜底(join_hashtable.cpp:249-312;join_hashtable.hpp:51-61)。
6. FULL OUTER 的未匹配 build 行从哪来?——found 标志位 + 探测后全表 ScanFullOuter 补齐(join_hashtable.cpp:676-680、2302-2347)。
7. PHJ 失败会浪费多少?——只浪费 perfect 表分配前的检查;建表失败(FullScanHashTable 查重冲突)返回 false 即回退常规 finalize(physical_hash_join.cpp:1930-1951;perfect_hash_join_executor.cpp:167-171)。
8. probe 侧并行吗?——是,ParallelOperator/ParallelSource 均为真,外置 probe 由 ColumnDataConsumer 按 chunk 派工(physical_hash_join.hpp:81-83、110-112;physical_hash_join.cpp:2465-2471)。
9. 复合键哈希怎么算?——首列 Hash,后续列 CombineHash 迭代混合(join_hashtable.cpp:405-419)。
10. cross product 为何不阻塞整个 RHS 常驻内存?——RHS 物化进 BufferManager 托管的 ColumnDataCollection,扫描侧逐 chunk 流式消费(physical_cross_product.cpp:44-69、107-121)。

### 深挖方向(正文未尽事项)

1. 本 fork 特有的 dict-surviving/dict-emission 全生命周期:字典索引槽宽选择、NEXT_PTR 嵌入与 aux_next_ptrs(join_hashtable.cpp:2769-2830;join_hashtable.hpp:407-424)。
2. 压缩探测 TryProbeDictionary/TryProbeConstant 的缓存失效边界与 dictionary_id 语义(join_hashtable.cpp:1211-1450)。
3. TemporaryMemoryManager 与外置 join 的内存协商:预留、probe_side_requirement、materialization penalty(physical_hash_join.cpp:884-938)。
4. ASOF join 的 AsOfHashGroup 分组 + 归并混合实现(physical_asof_join.cpp:700-770)。
5. IEJoin source 阶段机的任务图与外置排序块迭代(block_iterator/Repin 策略,physical_iejoin.cpp:236-412、466-503)。

## 正文蒸馏要点

1. 物理连接算法由 `PlanComparisonJoin` 一次定型:有等值→哈希,≥2 范围→IEJoin,1 范围→piecewise merge,否则 NLJ/blockwise NLJ,无条件→cross product(plan_comparison_join.cpp:215-286)。
2. 构造期 `ReorderConditions` 保证等值条件在前,是哈希连接"前缀等值+后缀残余"结构的先决条件(physical_comparison_join.cpp:58-77)。
3. 哈希连接构建走 Sink/Combine/Finalize 三级:每线程本地 radix 分区 HT → 挂链合并 → 统一分配指针表并行 InsertHashes 建链(physical_hash_join.cpp:764-796、802-834、1167-1185;join_hashtable.cpp:859-984)。
4. 行布局 [键|payload|found|hash] 在首个 build chunk 时经 LayoutGate 全局发布,允许按字典编码收窄 payload 槽(dict-surviving)(physical_hash_join.cpp:556-575、623-656)。
5. 指针表槽为 8 字节 ht_entry_t:48 位行指针 + 16 位 salt;capacity>8192 才启用 salt 预过滤,探测 = 线性探测 + salt 过滤 + RowMatcher 精确比键 + next 指针拉链(ht_entry.hpp:29-33;join_hashtable.hpp:89-96;join_hashtable.cpp:249-312)。
6. 外置哈希连接:预留 < 总量即触发;先降 load_factor 1.5 自救,再按预算/4 目标加 radix bits 重分区;probe 侧按同一分区函数把未命中分区行(附预计算 hash)溢出到 ProbeSpill,阶段机 BUILD→PROBE→SCAN_HT 多轮至完成(physical_hash_join.cpp:1833-1897、2149、2346-2420;join_hashtable.cpp:2601-2701)。
7. Finalize 并行度门控:<100 万行、单线程或最大分区占比 >0.33 的倾斜均单线程建表(physical_hash_join.cpp:840-875)。
8. PHJ 触发条件:INNER、恰 1 个整型等值条件、无残余谓词、build 键域跨度 ≤1,048,576 且行数 ≤ 域跨度;build 侧按 min-max 直排,探测退化为下标计算 + 字典向量输出;任何一步失败即 reset 并回退常规哈希表(perfect_hash_join_executor.cpp:85-134、139-194、279-309;physical_hash_join.cpp:1930-1951)。
9. 运行时过滤器三级:IN 列表(小 HT)、Bloom Filter(build/probe 估计比 ≤1)、Prefix Range Filter,统一在 finalize 完成后发布到 probe 侧扫描(physical_hash_join.cpp:1295-1364、1791-1814、1122-1146)。
10. IEJoin:前两条范围条件按操作符方向排 L1/L2,构造合并序列 Li(±行号)与置换 P,扫描用位阵 B + 1024 位分块 bloom 加速,输出前过滤同表行(physical_iejoin.cpp:28-58、236-250、535-538、778-835)。
11. piecewise merge join 只物化排序 RHS;LHS 每 chunk 现场排序后与 RHS 有序块归并,SEMI/ANTI 仅比较各 RHS 块最大值即可判定(physical_piecewise_merge_join.cpp:335-362、399-448)。
12. NLJ 物化 RHS 于 ColumnDataCollection 后逐块谓词求值,且仅接受非嵌套类型条件;任意表达式条件走 blockwise NL join;cross product 以"大 chunk 常驻引用 × 逐值扫描"成对输出(physical_nested_loop_join.cpp:123-171;plan_comparison_join.cpp:280-286;physical_cross_product.cpp:113-121)。
