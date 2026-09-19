# 第 26 章 · 排序与 TopN:单列字节键、Merge Path 重排与动态下推

> 基线:commit `7e886f44`。核心:src/common/sort/(sort.cpp 542 / sorted_run.cpp 450 / sorted_run_merger.cpp 875)、src/function/scalar/create_sort_key.cpp(1,501 行)、physical_top_n.cpp。纠偏:**不存在 physical_sort.cpp/PhysicalSort**——ORDER BY 算子叫 PhysicalOrder,157 行薄壳,全部转手给 Sort 类(physical_order.cpp:45-53);sorted_bag/SortLayout 也已不存在。

## 26.0 全景:sink 出 run,source 重排

```
 Sink:每线程一个 SortedRun(键+payload,几乎无锁追加,超 maximum_run_size 即本地排序成 run)
 Source:partition_size = min(total,122880) 切输出分区 → K-way Merge Path 求各 run 边界
   → 边界段拼成连续缓冲"整体 vergesort 重排"(注释自认 counter-intuitive,
      sorted_run_merger.cpp:641-650)→ 按分区产出
 外排:线程数×run 大小(索引 ×4)超内存预留且无线程 Combine 时(sort.cpp:176-207)
```

纠偏:"radix 分区"与 ORDER BY **无关**——radix 分区只属于窗口路径的 HashedSort;ORDER BY 的并行靠 Merge Path 切分已排序 run。排序键也不是旧资料的"定长前缀+堆"双布局,而是 `create_sort_key` 函数产出的 **BIGINT/BLOB 单列键**(九种 SortKeyType 模板,sort_key.hpp:19-32)。

## 26.1 排序键编码:列值→可比较字节串

每值前 1 字节 validity(NULLS FIRST/LAST=字节 1/2 交换);定长数值大端+符号位翻转,IEEE-754 全序变换(NaN 排在一切非 NULL 后);**DESC=逐字节取反**,编译期模板分派热循环零分支(create_sort_key.cpp:586-629);VARCHAR 每字节+1 后补 \x00 结尾(免转义);BLOB 用 \x01 转义;LIST/STRUCT 递归。全定长且合计 ≤8B 时返回类型直接改 BIGINT 快路径(:54-71)。嵌套类型子值 NULL 序"跟随 Postgres"不跟随用户(:99-104)。DEBUG 构建带编码→解码→逐值比对的 round-trip 断言(:873-934)。

## 26.2 TopN 与 Limit 家族

TopN 是独立实现:每线程二叉堆+全局边界值,**堆顶门槛经 DynamicFilterData::SetValue 动态下推扫描端**(ASC 单列 `< 边界`,NULLS FIRST 附 IS NULL),全程内存态不落盘;LIMIT+ORDER BY 在优化器折叠为 TopN,但 `limit>5000 且 >子基数 0.7%` 时弃用改全排(topn_optimizer.cpp:49-53)。Limit 分流三算子:批式 PhysicalLimit(≤10000 且 batch 源)、可并行 StreamingLimit、百分比全物化后按 percent 截断。

## 26.3 设计动机

1. **单列字节键**:把"多列比较"塌缩成"memcmp 一个 BLOB/BIGINT",键列不重复存 payload(sort.cpp:103-128);
2. **BIGINT 快路径**:小定长键整键一个 int64,比较退化成整数比较(create_sort_key.cpp:54-71);
3. **重排序归并**:Merge Path 求边界后边界段规模小,vergesort 重排比 K 路堆归并缓存更友好(sorted_run_merger.cpp:641-650);
4. **动态下推**:TopN 边界值实时传给扫描端做 zone map 剪枝,扫得越少堆得越快;
5. **skippable bytes**:统计保证非 NULL 的列的 validity 字节直接跳过(tuple_data_layout.cpp:169-196);
6. **round-trip 断言**:DEBUG 下编码解码回环逐值比对,字节编码正确性内建(:873-934)。

## 26.4 FAQ

**Q1:PhysicalSort 存在吗?**
不存在,叫 PhysicalOrder 且是薄壳,实现在 Sort 类。

**Q2:ORDER BY 用 radix 分区吗?**
不用;radix 分区只在窗口 HashedSort。

**Q3:排序键长什么样?**
[validity 字节][大端值/转义字符串],多列拼成单列 BLOB;小定长压 BIGINT。

**Q4:NULL 排序怎么实现?**
validity 字节 1/2 交换,零额外比较逻辑(create_sort_key.cpp:79-97)。

**Q5:DESC 有运行时分支吗?**
没有,FLIP_BYTES 编译期模板参数(:621-629)。

**Q6:外排什么时候发生?**
线程数×run 大小(索引 ×4)超内存预留且无线程 Combine(sort.cpp:176-207)。

**Q7:TopN 会落盘吗?**
不会,全程内存态;优化器在 limit 过大时干脆退回全排(topn_optimizer.cpp:49-53)。

**Q8:动态 filter 推给谁?**
推给扫描端 zone map/过滤器,ASC 下推 `< 边界`。

**Q9:LIMIT 100% 之类怎么算?**
百分比 limit 全物化后按 percent/100×(count+offset) 截断。

**Q10:键比较是 memcmp 吗?**
固定键按 uint64 分量字典序 SortKeyLessThan,键不做 byte-comparable 存储,解码时再 ByteSwap(sort_key.hpp:189-192)。

## 26.5 小结与深挖方向

本章结论:**ORDER BY=create_sort_key 单列字节键+SortedRun+Merge Path 重排;TopN=堆+边界动态下推**。深挖:

1. vergesort 对已排序段的识别收益(sorted_run_merger.cpp:641-650);
2. varchar MaxStringLength 统计对 sort_width 的收缩(tuple_data_layout.cpp:169-196);
3. index sort(is_index_sort=true)与普通排序的差异(plan_create_index.cpp:89);
4. StreamingLimit 的并行保序协议(physical_streaming_limit.cpp:88);
5. decode_sort_key 变长键的堆指针内联边界(sort_key.hpp:269-277)。
