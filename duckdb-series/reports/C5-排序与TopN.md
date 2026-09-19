# 报告 C5 · 排序与 TopN(DuckDB 卷四)

> 基线:7e886f44(2026-09-17)。一句话:此 commit 的 ORDER BY 已重构为「`create_sort_key()` 标量函数产出单列字节键 → 每线程本地排好的 SortedRun → Merge Path 切分分区后"重排序"归并」的流水线,TopN 则是独立的「多线程二叉堆 + 全局边界值 + 动态 filter 下推」实现,Limit 按"是否保序/是否 batch index/是否百分比"分流为三个算子。

## 1. 文件地图与三条纠偏

排序栈文件(`ls src/common/sort/`,行数为 wc -l 实测):

| 文件 | 行数 | 角色 |
|---|---|---|
| sort.cpp | 542 | `Sort` 类主体:sink/source 接口、内存预算、外排决策 |
| sorted_run.cpp | 450 | 单条 run:追加、本地排序(vergesort/ska_sort)、外排重排、扫描解码 |
| sorted_run_merger.cpp | 875 | Merge Path 分区归并:边界计算/拼接重排/扫描/物化四步任务机 |
| full_sort.cpp / hashed_sort.cpp / natural_sort.cpp / partitioned_sort.cpp | 369/835/217/322 | 窗口 SortStrategy 家族(卷四窗口章已出现) |
| sort_strategy.cpp | 62 | SortStrategy 工厂:按 partition_by/order_by 有无选四种策略 |
| partition_key_tracker.cpp | 280 | 单键分组的旁路跟踪(HashedSort 免排序路径) |

算子侧:`src/execution/operator/order/physical_order.cpp`(157)与 `physical_top_n.cpp`(642);Limit 家族在 `src/execution/operator/helper/` 下 physical_limit.cpp(263)/physical_limit_percent.cpp(183)/physical_streaming_limit.cpp(88);计划生成 `src/execution/physical_plan/plan_limit.cpp`(195)、plan_order.cpp(23)、plan_top_n.cpp(23)。

- **纠偏 1:不存在 `physical_sort.cpp`/`PhysicalSort`**(全仓 grep 无命中)。ORDER BY 物理算子叫 `PhysicalOrder`,且只是 157 行的薄壳,Sink/Source 全部转手给 `src/common/sort/sort.cpp` 里的 `Sort` 类(physical_order.cpp:45-53、117-123)。`Sort` 是公共组件:索引创建(plan_create_index.cpp:89,`is_index_sort=true`)与 range join 头文件(`src/include/duckdb/execution/operator/join/physical_range_join.hpp`)也引用它;窗口章的 SortStrategy 内部同样持有 `unique_ptr<Sort>`(full_sort.hpp:62,hashed_sort.hpp:91)。
- **纠偏 2:不存在 `sorted_bag` 与 `SortLayout`**(grep 无命中)。run 的载体是 `TupleDataCollection`,排序键布局字段在 `TupleDataLayout` 里:`sort_key_type/sort_width/sort_skippable_bytes`(src/include/duckdb/common/types/row/tuple_data_layout.hpp:140,150-152)。
- **纠偏 3:「radix 分区」与 ORDER BY 无关**。ORDER BY 的并行靠 Merge Path 切分已排序 run(见 §3);radix 分区只出现在窗口路径的 `HashedSort`,其 sink 用 `RadixPartitionedTupleData` 按 PARTITION BY 键哈希分组(hashed_sort.cpp:119-124,132-152)。另注:`ska_sort` 是本地排序内部的基数排序实现(见 §3 末),与"radix 分区"是两回事。
- 顺带:排序键也不是旧资料的「定长前缀+堆」双布局。现行布局是 `SortKeyType` 九种模板定长/变体键(sort_key.hpp:19-32),由 `create_sort_key` 函数产出的 BIGINT/BLOB 单列驱动(tuple_data_layout.cpp:165-166)。

与卷四窗口章的衔接:窗口函数不走 `Sort` 类本身,而走 `SortStrategy::Factory` 的四选一——需要分区列用 `PartitionedSort`、有 PARTITION BY 用 `HashedSort`、仅 ORDER BY 用 `FullSort`(内部持有 `Sort`)、都没有用 `NaturalSort` 直通(sort_strategy.cpp:33-49):

```cpp
// src/common/sort/sort_strategy.cpp:39-48
if (partition_info.RequiresPartitionColumns()) {
    return make_uniq<PartitionedSort>(client, order_bys, payload_types, partition_info, require_payload);
} else if (!partition_bys.empty()) {
    return make_uniq<HashedSort>(client, partition_bys, order_bys, payload_types, partitions_stats,
                                 estimated_cardinality, require_payload);
} else if (!order_bys.empty()) {
    return make_uniq<FullSort>(client, order_bys, payload_types, require_payload);
} else {
    return make_uniq<NaturalSort>(payload_types);
}
```

## 2. 排序键:把列值编码成可比较的字节串

`Sort` 构造时把所有 ORDER BY 列拼成一个 `create_sort_key` 标量表达式,再配一个 `decode_sort_key` 用于扫描期还原(sort.cpp:23-79);随后按"投影列是否同时也是键列"拆出 payload 布局,键列不重复存储:

```cpp
// src/common/sort/sort.cpp:103-128(节选)
for (idx_t output_col_idx = 0; output_col_idx < projection_map.size(); output_col_idx++) {
    const auto &input_col_idx = projection_map[output_col_idx];
    const auto it = input_column_to_key.find(input_col_idx);
    if (it != input_column_to_key.end()) {
        // Projected column also appears as a key, just reference it
        output_projection_columns.push_back({false, it->second, output_col_idx});
    } else {
        // Projected column does not appear as a key, add to payload layout
        output_projection_columns.push_back({true, payload_types.size(), output_col_idx});
        payload_types.push_back(input_types[input_col_idx]);
        input_projection_map.push_back(input_col_idx);
    }
}
...
key_layout->Initialize(orders, create_sort_key->GetReturnType(), !payload_types.empty());
```

编码规则(src/function/scalar/create_sort_key.cpp,1501 行):
- **每个值前 1 字节 validity**:`NULL_FIRST_BYTE=1 / NULL_LAST_BYTE=2`,NULLS LAST 时两者交换(create_sort_key.cpp:79-97)。嵌套类型的子值 null 序不跟随用户,而是「ASC→子值 NULLS LAST,DESC→NULLS FIRST」,注释两处明言「don't blame me this is what Postgres does」(create_sort_key.cpp:99-104,1084-1089)。
- **定长数值**:大端字节序 + 首字节符号位翻转(`FlipSign = ^0x80`),即经典 radix 字节序(radix.hpp:166-173);float/double 做 IEEE-754 全序变换:正数置符号位、负数按 1 取反,+0 编为 `0x80000000`,NaN 编为 UINT_MAX/ULLONG_MAX(排序在一切非 NULL 值之后)、±∞ 特判(radix.hpp:49-78,103-130)。
- **DESC = 逐字节取反**:`flip_bytes = (order_type == DESCENDING)`,经模板参数 `FLIP_BYTES` 在编译期分派,热循环零分支(create_sort_key.cpp:586,621-629)。
- **VARCHAR**:每字节 +1 后写键,再补 `\x00` 结尾符,天然免转义、按 8 字节 SWAR 词处理;注释说明「+1 使任何字节都不与分隔符冲突」(create_sort_key.cpp:220-235)。**BLOB** 则把 `\x00/\x01` 两字节用 `\x01` 前缀转义再加结尾符,转义少见故先按 4 词块无脑快拷(create_sort_key.cpp:295-351)。LIST 每个非 NULL 列表补结束分隔符、ARRAY/STRUCT 递归编码(create_sort_key.cpp:649-713)。
- **BIGINT 快路径**:bind 期判定所有列定长且「1 字节 validity + 值宽」合计 ≤8 字节时,返回类型直接改成 `BIGINT`(create_sort_key.cpp:54-71);写完后统一 `BSwapIfLE` 保证字节序比较语义(create_sort_key.cpp:836-842)。`Sort` 构造时也按返回类型决定解码入参是 BIGINT 还是 BLOB(sort.cpp:62-71)。

示意(非实测字节,标注为示意):`ORDER BY a INT NULLS LAST, b VARCHAR DESC` 的键 ≈ `[a 的 validity][a 大端4B][b 的 validity取反][b 逐字节取反+1][\xFF 结尾]`;`ORDER BY x SMALLINT` 则整键 3 字节 → 压入一个 int64。

**SortLayout 的来源**:`TupleDataLayout::Initialize(orders, type, has_payload)` 逐列累加 `sort_width`——定长类型加「1+值宽」,varchar 若统计有 `MaxStringLength` 加「1+最大长+1」,任何一列不可知则整键退化为变长;同时把「统计保证非 NULL 且尚未越过 7 字节」的列的 validity 字节记入 `sort_skippable_bytes`(tuple_data_layout.cpp:169-196)。最后按 8/16/24/32 阈值(有 payload 加 8 字节指针)落到 `NO_PAYLOAD/PAYLOAD × FIXED_8..32`,放不下就用 `*_VARIABLE_32`(tuple_data_layout.cpp:198-236)。固定键把整行内存当 `SortKey` 结构体:比较是按 `uint64` 分量的字典序 `SortKeyLessThan`(sort_key.hpp:148-156,223-225);且有个反直觉注释——**键不做 byte-comparable 存储**以换取 int64 语义比较,解码时再 ByteSwap(sort_key.hpp:189-192)。

**解码侧对称还原**:`decode_sort_key` 按同样的 validity 字节判定 NULL,再按列类型调 `OP::Decode`;变长键长度超过内联部分时直接指向堆指针,不再 ByteSwap(sort_key.hpp:269-277):

```cpp
// src/function/scalar/create_sort_key.cpp:1166-1174(节选)
for (idx_t i = 0; i < count; i++) {
    const auto result_idx = result_offset + i;
    auto &decode_data = decode_data_arr[i];
    auto validity_byte = decode_data.ReadByte("reading validity byte");
    if (validity_byte == null_byte) {
        // NULL value
        result_validity.SetInvalid(result_idx);
        continue;
    }
    auto remaining = decode_data.size - decode_data.position;
    idx_t increment = OP::template Decode<FLIP_BYTES>(decode_data.data + decode_data.position, remaining, ...);
```

DEBUG 构建下还会对每个键做「编码→解码→逐值比对」的 round-trip 断言(create_sort_key.cpp:873-934)。

## 3. PhysicalOrder 的并行:sink 侧 SortedRun,source 侧 Merge Path

**Sink 阶段**每线程持一个 `SortedRun`(键 TupleDataCollection + 可选 payload 集合,sorted_run.cpp:142-153);追加键的同时把 payload 行地址写进键内的 payload 槽(sorted_run.cpp:192-201)。`Sort::Sink` 每个 chunk 后检查 run 是否超 `maximum_run_size`(= 内存预留额/线程数,sort.cpp:171-174):

```cpp
// src/common/sort/sort.cpp:268-307(节选)
lstate.key_executor.Execute(chunk, lstate.key);
lstate.payload.ReferenceColumns(chunk, input_projection_map);
lstate.sorted_run->Sink(lstate.key, lstate.payload);
// Try to finish this call to Sink
unique_lock<mutex> guard;
if (TryFinishSink(gstate, lstate, guard)) { return SinkResultType::NEED_MORE_INPUT; }
// Grab the lock, update the local state, and see if we can finish now
guard = unique_lock<mutex>(gstate.lock);
gstate.UpdateLocalState(lstate);
if (TryFinishSink(gstate, lstate, guard)) { return SinkResultType::NEED_MORE_INPUT; }
// Still no, this thread must try to increase the limit
gstate.TryIncreaseReservation(context.client, lstate, is_index_sort, guard);
```

内存预算与外排决策(`TryIncreaseReservation`):所需量 `required = num_threads × 当前 run 字节数`(索引排序 ×4,"pretty intense, so we are very conservative");先向 `TemporaryMemoryManager` 翻倍申请,批不下来且**尚无线程 Combine 过**(`any_combined==false`)才置 `external=true`——运行中途不再回退(sort.cpp:176-207,317-328)。外排即 spill:键/数据块本就由 BufferManager 分配(tuple_data_allocator.cpp:14-16);external 时 `SortedRun::Finalize` 排完序会把变长键与 payload 物理重排(`Reorder`)并 `UNPIN_AFTER_DONE`,交还缓冲池按需落盘(sorted_run.cpp:396-423,155-161);归并期用 `BlockIteratorStateType::EXTERNAL` 逐块重钉,注释自称"larger-than-memory"迭代器(block_iterator.hpp:143-147)。线程退出时 `Combine` 无锁完成本地排序再挂到全局(sort.cpp:309-329);`Finalize` 汇总行数并取 `partition_size = min(total, 122880)`,`verify_parallelism` 调试时恒为 2048(sort.cpp:331-349;storage_info.hpp:26)。

**Source 阶段**由 `SortedRunMerger` 把输出切成 `partition_size` 行的分区,每个分区走四步任务机(sorted_run_merger.cpp:72-83,335-374):`COMPUTE_BOUNDARIES → ACQUIRE_BOUNDARIES → MERGE_PARTITION → SCAN_PARTITION`;若分区前界尚未被邻居算出,当前线程会代算上一分区再回来(merger 里的协作等待,sorted_run_merger.cpp:559-579)。边界算法即 Merge Path:目标取全局第 `(p+1)×partition_size` 小,对仍活跃的各 run 每轮各取 `ceil(remaining/k)` 步长、以比较选出最小的游标前进,直至耗尽配额(sorted_run_merger.cpp:494-557);`MaxThreads = 分区数`(sorted_run_merger.cpp:192-194)。分区合并的实现出人意料:

```cpp
// src/common/sort/sorted_run_merger.cpp:641-650
if (active_runs == 1 || gstate.merger.is_index_sort) {
    return; // Only one active run, no need to sort (or index sort, which is approximate sorting)
}
// Seems counter-intuitive to re-sort instead of merging, but modern sorting algorithms detect and merge
static const auto fallback = [](SORT_KEY *begin, SORT_KEY *end) {
    duckdb_pdqsort::pdqsort_branchless(begin, end);
};
duckdb_vergesort::vergesort(merged_partition_keys, merged_partition_keys + merged_partition_count,
                            std::less<SORT_KEY>(), fallback);
```

即:把各 run 的边界段**拼进一块 `partition_size × sizeof(SortKey)` 连续缓冲后整体重排**,而不是 K 路堆归并——vergesort 会检测已排序段从而退化为近似归并。扫描时按 2048 行取键指针,经 `decode_sort_key` 表达式还原键列、其余列从 payload 集合按键内指针 gather(sorted_run.cpp:76-137)。外排场景已扫分区延迟销毁,且要落后在忙线程数 `num_threads` 个分区以上,防止销毁他线程正用的块(sorted_run_merger.cpp:196-259)。本地单 run 排序用 vergesort + `ska_sort`(基数排序)兜底,radix 键取 `key.part0` 前 8 字节;`is_index_sort` 时 `requires_next_sort=false`(近似排序即可)(sorted_run.cpp:231-256;third_party/{vergesort,ska_sort,pdqsort} 均为内嵌源码)。sink 进度还按"一半时间在排序"估算(sort.cpp:351-361)。

分区序对下游可见:扫描结果以 `partition_idx` 作为 batch index 上报(merged 序=全局序,sorted_run_merger.cpp:817-822;physical_order.cpp:125-134),这既让下游 pipelined 算子按批消费,也让 TopN 之前的 Limit 能"保序截断"。MaterializeSortedRun/MaterializeColumnData 两条非标准出口则服务于 range join 与物化需求(sort.cpp:455-540;sorted_run_merger.cpp:836-873)。

## 4. TopN:多线程堆 + 全局边界值 + 动态 filter 下推

`TopN::CanOptimize` 要求 LIMIT 为常量、offset 非表达式、子树穿过 PROJECTION 后是 ORDER BY(topn_optimizer.cpp:22-64);`TopN::Optimize` 完成 LIMIT+ORDER BY → `LogicalTopN` 的折叠并回挂投影(topn_optimizer.cpp:159-202)。这是「ORDER BY+LIMIT 折成 TopN」,而非 TopN 之上再叠 Limit 的二次折叠;若 `limit > 5000 且 limit > 子基数×0.7%` 则放弃 TopN 改走全排,注释直言"sorting the whole table is faster"(topn_optimizer.cpp:49-53)。动态 filter 的方向是 **TopN 把边界下推进 table scan**,不是把 filter 推进 TopN:优化期仅支持首排序列、且为数值/varchar 的裸列引用,沿子树找 pushdown 目标,把 `ExpressionFilter` 塞进 `table_filters`(topn_optimizer.cpp:66-81,104-155)。

执行期每个线程一个 `TopNHeap`,堆元素是 `{string_t sort_key, idx_t index}` 的二叉堆(`std::push_heap/pop_heap`),容量 `heap_size = limit + offset`(physical_top_n.cpp:28-35,176);堆满后仅当新键 `sort_key < heap.front()`(当前门槛,即保留集中的最大键)才替换堆顶:

```cpp
// src/execution/operator/order/physical_top_n.cpp:140-166(节选)
inline bool EntryShouldBeAdded(const string_t &sort_key) {
    if (heap_size == 0) { return false; }            // LIMIT 0 - no entry can ever be added
    if (heap.size() < heap_size) { return true; }
    if (sort_key < heap.front().sort_key) { return true; } // smaller than current max
    return false;
}
inline void AddEntryToHeap(const TopNEntry &entry) {
    if (heap.size() >= heap_size) { std::pop_heap(heap.begin(), heap.end()); heap.pop_back(); }
    heap.push_back(entry);
    std::push_heap(heap.begin(), heap.end());
}
```

工程细节:堆容量 ≤100(`SMALL_HEAP_THRESHOLD`)走 `AddSmallHeap`——先只记键,胜出行最后才拷 payload,减少无效拷贝;否则 `AddLargeHeap` 边入堆边拷(physical_top_n.cpp:354-381,207-272)。`heap_data` 超过 `ReduceThreshold() = max(5×2048, 2×heap_size)` 就按堆内行压缩重排(physical_top_n.cpp:131-133,427-454)。**TopN 不用 Sort 类、不落盘**——键是 BLOB 字节串直接比,数据全在内存 DataChunk 中(physical_top_n.cpp:186-194)。并行协作靠 `TopNBoundaryValue`:线程把堆顶门槛发布到全局(加锁取更小者),且第一列边界同时解码并 `op.dynamic_filter->SetValue` 推给扫描端,扫描过滤随执行收紧:

```cpp
// src/execution/operator/order/physical_top_n.cpp:64-76(节选)
void UpdateValue(string_t boundary_val) {
    unique_lock<mutex> l(lock);
    if (!is_set || boundary_val < string_t(boundary_value)) {
        boundary_value = boundary_val.GetString();
        is_set = true;
        if (op.dynamic_filter) {
            CreateSortKeyHelpers::DecodeSortKey(boundary_val, boundary_vector, 0, boundary_modifiers);
            auto new_dynamic_value = boundary_vector.GetValue(0);
            l.unlock();
            op.dynamic_filter->SetValue(std::move(new_dynamic_value));
        }
    }
}
```

其他线程 Sink 前先按边界做逐列比较预筛(`CheckBoundaryValues`,按 NULLS/ASC/DESC 选四种 `Distinct*` 向量化比较,相等则继续看下一排序列,physical_top_n.cpp:274-389)。`Combine` 时本地堆先 `Finalize()` 排好序再并入全局堆,可提前 break(「since we sorted the heap」,physical_top_n.cpp:391-421,528-538)。Source 端全局扫描序按 `TUPLES_PER_BATCH = 60×2048` 行批次分发只读并行扫描,OFFSET 靠扫描起点 `pos = offset` 跳过(physical_top_n.cpp:456-467,567-609)。

## 5. Limit 家族:batch / streaming / percent

`plan_limit.cpp:138-192` 分流:百分比 LIMIT → `PhysicalLimitPercent`;否则在保序(`PreserveInsertionOrder`,plan_insert.cpp:38-54)时——子计划支持 batch index 且 `UseBatchLimit` 成立 → `PhysicalLimit`,否则非并行 `PhysicalStreamingLimit`;不保序 → 可并行 `PhysicalStreamingLimit`(plan_limit.cpp:160-192)。`UseBatchLimit` 仅在「复杂查询」(子树含带 filter 的 TABLE_SCAN 等)且常量 `limit+offset ≤ 10000` 时启用批式 Limit,注释直言纯扫描上批式"只是多扫行再扔掉"(plan_limit.cpp:16-60)。`GROUP BY/DISTINCT + LIMIT ≤ 100000` 可改写 `PhysicalLimitedDistinct`,LIMIT 节点仍留在外面兜底语义(plan_limit.cpp:150-158)。LIMIT/OFFSET 上限 `1ULL << 62`(physical_limit.hpp:22);表达式 LIMIT/OFFSET 在首个 chunk 上只求值一次,NULL 视为无界(physical_limit.cpp:83-113,229-244)。

- **PhysicalLimit**(批式):每线程按 batch index 缓冲到 `BatchedDataCollection`,达到 `limit+offset` 即 `FINISHED`,Source 端按批回放并 `HandleOffset` 切 offset/limit(physical_limit.cpp:115-136,173-227)。
- **PhysicalStreamingLimit**:零物化,全局 `current_offset` 用原子 `fetch_add` 抢行号,越界即截断;`parallel` 标志决定是否多线程(physical_streaming_limit.cpp:42-69):

```cpp
// src/execution/operator/helper/physical_streaming_limit.cpp:48-58(节选)
idx_t current_offset = gstate.current_offset.fetch_add(input.size());
idx_t max_element;
if (!PhysicalLimit::ComputeOffset(context, input, limit, offset, current_offset, max_element, limit_val,
                                  offset_val)) {
    return OperatorResultType::FINISHED;
}
if (PhysicalLimit::HandleOffset(input, current_offset, offset.GetIndex(), limit.GetIndex())) {
    chunk.Reference(input);
}
```

注意 offset 语义仍精确:各行号连续分配,HandleOffset 在跨 offset 边界的 chunk 上做 SelectionVector 切片(physical_limit.cpp:194-227)。

- **PhysicalLimitPercent**:先全量物化(Sink 期先应用 offset),Source 期一次性算 `limit = percent/100 × (count + offset)` 后截断;百分比 NaN/负/>100 抛 `OutOfRangeException`(physical_limit_percent.cpp:94-99,131-154,142-144)。

## 6. ASCII:一次 ORDER BY 的分区排序→归并数据流

```text
查询: SELECT * FROM t ORDER BY a, b DESC;      (4 线程, 内存充足)
================================================================================
 Sink 阶段 (并行)                          Source 阶段 (Merge Path 归并)
================================================================================
 T0: chunks ──create_sort_key──┐           输出分区(每分区 partition_size 行,
 T1: chunks ──create_sort_key──┤            = min(total,122880)):
 T2: chunks ──create_sort_key──┤            P0  P1  P2  P3 ...
 T3: chunks ──create_sort_key──┘                 │ 逐分区指派任务
     │  键=BLOB/BIGINT 单列                      ▼
     ▼                                        [COMPUTE_BOUNDARIES]
 run0:[key|payload] ←每线程一份                Merge Path: 在各 run 内以
 run1:[key|payload]   SortedRun               ceil(remaining/k) 步长竞速,
 run2:[key|payload]                           求第 k×partition_size 小的边界
 run3:[key|payload]                                │
     │ run 满额/线程退出(Combine)                 ▼
     ▼ Finalize(): vergesort(+ska_sort 兜底)  [MERGE_PARTITION]
 run0 排好 / run1 排好 / ...                   各 run 边界段拼成一块连续键缓冲
     │ AddSortedRun                               vergesort 重排(检测有序段)
     ▼                                             │
 global: [run0,run1,run2,run3] ────────────► [SCAN_PARTITION]
   partition_size = min(total, 122880)         按序取键指针 → decode_sort_key
                                               还原 a,b → payload 按指针 gather
                                               → 2048 行 chunk 给上游(带 batch)
 内存不足时: external=true → 键+payload 物理重排后 UNPIN,
             BufferManager 淘汰落盘; 归并以 EXTERNAL 块迭代器按需重钉,
             已扫分区延迟销毁(落后 num_threads 个分区)
================================================================================
 同一输入的 TopN 完全另一套: 每线程二叉堆(≤limit+offset 项)
 → 全局边界值预筛 + dynamic filter 下推 scan → Combine 有序归堆
 → Finalize 排序 → 按 60×2048 行批次并行吐出(offset 靠扫描起点跳过)
================================================================================
```

## 7. 设计动机、FAQ 候选与深挖方向

**设计动机(≥5)**:
1. 键统一为单列字节串(必要时压成 int64),排序主循环与类型系统解耦,固定键可当 `SortKey` 结构体做整字比较;九种布局在 SMALLER_BINARY 下还要裁剪,注释给出省 297KB、换 1.26-1.56x 的实测权衡(sort_key.hpp:34-77;create_sort_key.cpp:54-71)。
2. 固定键内嵌 payload 行指针:排序只搬运 16-32 字节键,行数据不动,external 时才物理 `Reorder`(sorted_run.cpp:411-420;sort_key.hpp:27-31)。
3. sink 几乎无锁:每线程独立 run,收尾排序在线程本地做,`Combine` 仅挂链表;`external` 决策要求"没有任何线程 Combine 过",避免执行中途回退(sort.cpp:180-186,317-328)。
4. 归并阶段"重排而非堆归并":依赖 vergesort 的预排序检测、pdqsort 兜底,连续内存对缓存与向量化更友好,代码也更薄(sorted_run_merger.cpp:645-650)。
5. 全局边界值 + 动态 filter 让 TopN 的剪枝随执行收紧并下沉到扫描端,而不是让每行都进堆(physical_top_n.cpp:46-77,274-389;topn_optimizer.cpp:104-155)。
6. NULL/DESC/嵌套类型全部编码进字节键,比较器收敛为单一 `operator<`,Sort 与 TopN 共享同一套键语义(create_sort_key.cpp:79-104;physical_top_n.cpp:32-35)。
7. 内存预算走 `TemporaryMemoryManager` 统一记账,索引构建 ×4 保守系数,欠账即外排(sort.cpp:171-207)。

**FAQ 候选(10,每条一句话答案)**:
1. ORDER BY 的排序键长什么样?——每列 1 字节 validity 前缀加定长大端值(数值首字节翻转符号位)或 VARCHAR 逐字节 +1 加 `\x00` 结尾,多列串联成 BLOB;全定长且 ≤8 字节则压成 BIGINT(create_sort_key.cpp:79-97,220-235,54-71)。
2. NULLS FIRST/LAST 如何实现?——编码为 validity 字节的 1/2 两个取值并按 null 序交换,解码时据此还原 NULL(create_sort_key.cpp:93-97,1169-1174)。
3. DESC 呢?——编码时逐字节取反,比较与升序共用同一 `operator<`(方向差异被吸收进键)(create_sort_key.cpp:586,621-629)。
4. 什么时候转外排?——所需内存 `num_threads × run 大小`(索引排序 ×4)超过临时内存管理器批准额,且尚无线程 Combine 时置 `external`(sort.cpp:176-207)。
5. 归并用堆吗?——不用,分区内把各 run 边界段拼接后 vergesort 整体重排,靠排序算法自身检测有序段(sorted_run_merger.cpp:641-650)。
6. 分区多大、并行度多少?——分区 `min(总行数, 122880)`(`verify_parallelism` 时 2048),归并并行度=分区数(sort.cpp:342-346;sorted_run_merger.cpp:192-194)。
7. TopN 的堆顶是什么?——当前保留集的最大排序键即入围门槛,新行只有小于它才入堆(physical_top_n.cpp:140-155)。
8. TopN 有多省、有没有上限?——堆和 payload 压缩到 `max(5×2048, 2×堆容)` 量级、全程内存态不落盘;limit 过大(>5000 且 >子基数 0.7%)时优化器直接弃用改全排(physical_top_n.cpp:131-133;topn_optimizer.cpp:49-53)。
9. LIMIT 如何并行/保序?——保序且 batch 源用批式 `PhysicalLimit`(每线程按 batch 缓冲),否则 streaming limit(可并行零物化),百分比单独全物化后截断(plan_limit.cpp:160-192)。
10. TopN 下推的动态 filter 是什么比较?——ASC 单列 `col < 边界`、多列 `<=`(DESC 反向),NULLS FIRST 额外包 `OR col IS NULL` 防止 NULL 行被滤掉(topn_optimizer.cpp:106-116,141-150)。

**深挖方向(5)**:
1. `BlockIteratorStateType::EXTERNAL` 块迭代与 `DestroyScannedData` 滞后销毁的内存上界/下界分析(block_iterator.hpp:143-190;sorted_run_merger.cpp:196-259)。
2. 索引构建的"近似排序":`is_index_sort` 下 vergesort 不做后续精排、内存 ×4,与 ART 构建链路的耦合(plan_create_index.cpp:89;sorted_run.cpp:243-244;sort.cpp:189-192)。
3. TopN 与 late materialization 优化器的交互及 heap_data Slice/Flatten 的成本(optimizer/late_materialization.cpp:98-100,295-349)。
4. `sort_key_layouts` 裁剪(9→6 布局)的代码体积/性能权衡与"re-measure before trimming further"(sort_key.hpp:44-57)。
5. 窗口 SortStrategy 家族(HashedSort 自适应 radix bits、`can_bypass_single_key_sort` 免排序、NaturalSort 直通)与本章 `Sort` 的复用边界(sort_strategy.cpp:33-49;hashed_sort.cpp:101-152)。

## 8. 正文蒸馏要点

1. ORDER BY 算子是 `PhysicalOrder`(physical_order.cpp:7-11),本体在公共类 `Sort`(sort.cpp:19-129);`physical_sort.cpp`、`sorted_bag`、`SortLayout` 在本 commit 均不存在(grep 无命中)。
2. 排序键由 `create_sort_key` 函数编码为单列 BIGINT/BLOB:1 字节 validity + 大端定长值(符号位翻转)或 VARCHAR 逐字节 +1 加 `\x00` 结尾,DESC 逐字节取反(create_sort_key.cpp:79-97,166-173,220-235)。
3. 全定长且 ≤8 字节的键压进 int64 走整数快路径,写完统一 `BSwapIfLE`(create_sort_key.cpp:66-70,836-842)。
4. 键布局 `SortKeyType`(9 种定长/变体)由 `TupleDataLayout::Initialize(orders, type, has_payload)` 依据列类型与统计(含 varchar 最大长度、非 NULL 跳过字节)决定(tuple_data_layout.cpp:150-237)。
5. 固定键内嵌 payload 行指针,排序只移动键;external 时才把变长键与 payload 物理重排并解除常驻 pin(sorted_run.cpp:192-201,396-423)。
6. sink 阶段每线程一个 SortedRun;转外排的条件是 `num_threads × run 大小`(索引 ×4)超过内存预留且尚无线程 Combine(sort.cpp:176-207)。
7. source 阶段按 `partition_size = min(total, 122880)` 分区,四步任务机:计算 Merge Path 边界 → 获取边界 → 拼接重排(vergesort+pdqsort,非堆归并)→ 扫描解码(sort.cpp:342-346;sorted_run_merger.cpp:72-83,641-650)。
8. 本地排序 = vergesort(检测有序段)+ ska_sort 基数排序兜底,以键前 8 字节为 radix 键(sorted_run.cpp:231-256)。
9. LIMIT(常量)+ ORDER BY 在优化器折叠为 TopN;`limit>5000 且 >子基数×0.7%` 时弃用 TopN 改全排(topn_optimizer.cpp:49-53,159-202)。
10. TopN 是每线程二叉堆(容量 limit+offset),全局边界值预筛 + 动态 filter 下推进 table scan(ASC 单列 `< 边界`,NULLS FIRST 附 `IS NULL`)(physical_top_n.cpp:140-166,46-77;topn_optimizer.cpp:104-155);TopN 全程内存态,不落盘、不经 `Sort` 类。
11. LIMIT 分流三算子:批式 `PhysicalLimit`(保序+batch 源+limit+offset≤10000)、`PhysicalStreamingLimit`(可并行零物化)、`PhysicalLimitPercent`(全物化后按 `percent/100×(count+offset)` 截断)(plan_limit.cpp:160-192;physical_limit_percent.cpp:145)。
12. LIMIT/OFFSET 上限 `2^62`,表达式值在首 chunk 求值一次;`DISTINCT/GROUP BY + LIMIT≤100000` 可改写为 `PhysicalLimitedDistinct`(physical_limit.hpp:22;physical_limit.cpp:83-113;plan_limit.cpp:150-158)。
