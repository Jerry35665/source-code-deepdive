# 第 15 章 · Join 算法深挖:选型总控、盐值探测与外置溢出

> 基线:commit `7e886f44`。核心:src/execution/operator/join/ 与 src/execution/join_hashtable.cpp。

## 15.0 全景:一个函数决定用哪种 join

```
 PlanComparisonJoin(plan_comparison_join.cpp:215-286)决策链:
 无条件            → CROSS_PRODUCT
 ≥1 等值(非 prefer_range_joins)→ HASH_JOIN
 ≥2 范围条件       → IE_JOIN(非递归 CTE)
 1 个范围条件      → PIECEWISE_MERGE_JOIN
 其余比较条件      → NESTED_LOOP_JOIN(类型受限)
 任意布尔表达式    → BLOCKWISE_NL_JOIN(兜底)
 构造前 ReorderConditions 把等值条件排最前(physical_comparison_join.cpp:58-77)
 ——哈希连接因此只需处理"前缀等值+后缀非等值"
```

纠偏:本 commit **不存在 "piecewise hash join"**——哈希连接是单一 PhysicalHashJoin;"piecewise" 只修饰 merge join,真实含义是 LHS 每个 chunk 现场排序后与已排序物化的 RHS 逐块归并,SEMI/ANTI 快路径只需比较每个 RHS 块的最大值(physical_piecewise_merge_join.cpp:335-448)。

## 15.1 哈希连接构建侧:per-thread 分区,无共享表

构建走 Sink→Combine→Finalize 三步:每线程把 [键|payload|(found 位)|hash] 行追加进**自己的 radix 分区 HT**——按行内完整 hash 低位分区,initial_radix_bits=线程数<100?4:5(physical_hash_join.cpp:331-336, 764-796);行布局由首个 chunk 经 LayoutGate 全局发布一次(:556-656)。纠偏:等值键**不做 blob 序列化**(全仓 SerializeVector 出现 0 次),直接按逻辑类型存、模板化 RowMatcher 逐列比较;复合键靠首列 Hash+逐列 CombineHash(join_hashtable.cpp:405-419)。Combine 只挂引用;指针表到 Finalize 才分配(count×load_factor 2.0,最小 16384 槽),从行内重读 hash 后 **CAS 无锁建链**(:1048-1139)。倾斜门控:单线程/行数<2^20/最大分区占比>0.33 时 finalize 退单线程(physical_hash_join.cpp:840-875)。

## 15.2 探测侧:salt 线性探测与快速路径

指针表槽是 8 字节 `ht_entry_t` = 48 位行指针+16 位 salt(取 hash 高位),仅容量>8192(超 CPU cache)才启用 salt 预过滤(ht_entry.hpp:29-33; join_hashtable.hpp:89-96)。探测主循环:hash&bitmask 定槽→salt 相等才取行→RowMatcher 精确比键→不匹配线性探测下行(:249-312)。两条快速路径:常量向量探测(TryProbeConstant)与字典向量探测(每字典槽只探一次并缓存指针,阈值 20000,:1211-1349)。build 侧可选 bloom filter 插入 hash(:699-711)。

## 15.3 外置模式:两级自救与多轮阶段机

判据:内存预留 < 构建总量(`GetReservation() < total_size`)。自救两级:先把 load_factor 降到 1.5(可能"救回"内存态),再按预算/4 加 radix bits 重分区(HashJoinRepartitionEvent,physical_hash_join.cpp:1833-1897)。探测侧溢出:probe 行若其分区不在当前构建集合,连同行尾**预计算 hash** 写入 ProbeSpill(join_hashtable.cpp:2663-2696);阶段机多轮 BUILD→PROBE→SCAN_HT(全外/右外补齐),分区按尺寸升序贪心打包(:2601-2661);溢出扫描直接用行内预计算 hash 免二次哈希(:1197-1199)。递归 CTE 复用:Reset 时 radix_bits 归 0 省每轮分区开销,布局跨轮保留(:2560-2596)。

## 15.4 IEJoin 与 merge join

≥2 范围条件走 IEJoin(4 条件排序的 Lichtblau 式算法,iejoin.cpp);1 个范围条件走 piecewise merge join(RHS 排序物化一次,LHS 逐 chunk 排序归并)。小输入压制:估计基数低于 NestedLoopJoinThreshold/MergeJoinThreshold 时禁用重排序 join(plan_comparison_join.cpp:251-263)。`PreferRangeJoins` 打开后即使有等值也强走 range 家族(:240-241)。空 build 侧且 INNER/RIGHT/SEMI 直接 NO_OUTPUT_POSSIBLE(:1953-1955)。

## 15.5 设计动机

1. **等值优先重排**:条件排序让哈希连接只处理等值前缀,非等值变残余谓词(physical_comparison_join.cpp:58-77);
2. **per-thread 分区构建**:无共享写热点,Finalize 才并行 CAS 建链(:802-834, join_hashtable.cpp:1113-1139);
3. **salt 压缩进指针槽**:8 字节槽塞下 48 位指针+16 位指纹,cache 外容量下省一次解引用(ht_entry.hpp:29-33);
4. **行内存 hash**:Finalize/溢出扫描免二次哈希,空间换重算(join_hashtable.cpp:1180-1186);
5. **外置两级自救**:先降 load_factor 再重分区,多数查询无需真正落盘(physical_hash_join.cpp:1844-1854);
6. **最小内存预留协商**:TemporaryMemoryState 让 BufferManager 提前知道 probe 侧需求(:927-937)。

## 15.6 FAQ

**Q1:有 "piecewise hash join" 吗?**
没有,哈希连接单一算子;piecewise 只修饰 merge join(physical_operator_type.hpp:56-67)。

**Q2:等值键怎么序列化?**
不序列化,按逻辑类型直存+RowMatcher 模板比较(全仓 SerializeVector=0)。

**Q3:NULL 键怎么处理?**
build 侧过滤(RIGHT/FULL 除外,置 has_null)(join_hashtable.cpp:714-742)。

**Q4:salt 什么时候有用?**
容量>8192 超 cache 时参与线性探测预过滤(join_hashtable.hpp:89-96)。

**Q5:指针表何时建?**
Finalize 阶段,load_factor 2.0、CAS 并行建链(join_hashtable.cpp:1048-1139)。

**Q6:外置的判据?**
内存预留<构建总量;先降 load_factor 1.5 自救再重分区(physical_hash_join.cpp:1833-1854)。

**Q7:探测侧溢出存什么?**
未命中分区的行+行尾预计算 hash(join_hashtable.cpp:2663-2696)。

**Q8:字典探测怎么加速?**
每字典值只探一次并缓存指针,阈值 20000 槽(:1211-1349)。

**Q9:递归 CTE 复用 join 会重建吗?**
Reset 保留布局、radix_bits 归 0;外置模式禁用复用(:2560-2596; physical_hash_join.cpp:1858)。

**Q10:finalize 何时退单线程?**
行数<2^20 或最大分区占比>0.33 倾斜(physical_hash_join.cpp:840-875)。

## 15.7 小结与深挖方向

本章结论:**join=计划期按条件形态七选一;哈希连接=per-thread radix 分区+盐值线性探测+两级自救外置;非等值=IEJoin/归并/NLJ 兜底**。深挖:

1. IEJoin 的 4 条件排序与复杂度证明(iejoin.cpp);
2. RadixPartitionedTupleData 的分区数动态增长策略(radix_partitioning.hpp:116-146);
3. bloom filter 的误报率与内存权衡开关(:699-711);
4. ASOF join 的 plan 层独立分派条件(plan_comparison_join.cpp:291);
5. POSITIONAL join(位置对齐)在文件扫描组合中的用途。
