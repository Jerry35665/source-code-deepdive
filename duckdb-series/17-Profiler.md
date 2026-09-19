# 第 17 章 · 查询画像与 EXPLAIN ANALYZE:墙钟求和与"输出即结果"

> 基线:commit `7e886f44`。核心:src/main/query_profiler.cpp / src/main/profiler/ / src/execution/physical_explain_analyze.cpp。

## 17.0 全景:画像三步与 EXPLAIN ANALYZE 的特殊性

```
 启动(解析前)──► CreatePreparedStatementInternal 再启动(幂等)
   ▼ Executor 初始化:profiler->Initialize(plan) 递归建 ProfilingNode 树(executor.cpp:240)
   ▼ 运行中:每 pipeline 完成 Flush 线程本地 OperatorProfiler(pipeline_executor.cpp:718)
     OperatorProfiler:StartOperator/EndOperator 严格栈式配对,累进 time/elements_returned
   ▼ EndQuery:FinalizeMetrics → 打印/落盘 —— 但 EXPLAIN ANALYZE 分支不打印不落盘
 PhysicalExplainAnalyze:子计划并行 sink 真跑一遍,Finalize 时
   profiler.ToString(format) 存 sink 状态 → GetData 返回单行 ("analyzed_plan", plan)
```

纠偏:EXPLAIN ANALYZE 的输出**是一条查询结果,不是打印**——`IsEnabled()` 被 `is_explain_analyze` 短路,所以 profiler 默认关闭但 ANALYZE 恒开(query_profiler.cpp:80-82; physical_explain_analyze.cpp:20-44)。

## 17.1 计时:steady_clock 墙钟,cpu_time 的真相

底层 `TimePoint` 封装 `std::chrono::steady_clock`,纳秒粒度(time_point.hpp:16-41);三层叠加:查询级 RAII `MetricsTimer`(latency/planner/optimizer/physical_planner 各一枚)、算子级每线程 OperatorProfiler(StartOperator 首见时缓存 ParamsToString 为 extra_info,EndOperator 停表累加,query_profiler.cpp:423-495)、IO/内存回调恒追踪(file_system.cpp:817-864——**画像关闭也计数**,供进度条用)。纠偏:**query.cpu_time 不是 CPU 时间**——是 `MergeOperatorMeasurements` 对全树算子墙钟时间求和,并行下可大于墙钟(:1136-1138);同一指标 total_row_groups_to_scan 在 Flush(取 max)与收尾(求和)两种语境合并语义不同(:473-481)。

## 17.2 全量累计与两头裁剪

没有抽样,是**按算子边界的全量累计**;裁剪在两头:profiling_coverage(SELECT 默认/ALL)只决定"树里是否出现值得画像的算子类型"(白名单 :173-218,一个没有就整体关闭画像);tracked_metrics(默认 `{"*"}`)决定哪些指标被收集展示,支持 exact/prefix/glob 三种匹配(gathered_metrics.cpp:33-78)。CreateTree 为每个物理算子建节点、以裸指针为键登记 tree_map,CTE_SCAN 把 cte_source 映射到同一节点(:1034-1050)。

## 17.3 渲染:一个注册表服务两种命令

纠偏:profiler 已整体重构——旧 "ProfilingInfo/JSON map" 变为 `ProfilingNode(OperatorMetrics)` + `GatheredMetrics` + `QueryProfileResult`(键字母序 JSON);EXPLAIN 与画像**共用同一 TreeRenderer 注册表**:text/json/html/graphviz/yaml/mermaid/no_output+扩展插件(tree_renderer.cpp:51-101)。`start_at_optimizer`/`query_tree_optimizer` 等参数是**无实际生效路径的遗迹**(query_profiler.hpp:101 全仓无 true 调用点)。安全特性 `CollapseSecureViews`:SECURE_VIEW 子树在一切输出前折叠,防画像泄露受保护视图内部(query_profiler.cpp:1107-1122)。

## 17.4 设计动机

1. **输出即结果**:ANALYZE 走结果集而非 stdout,客户端 API 无需解析文本(physical_explain_analyze.cpp:20-44);
2. **幂等 StartQuery**:解析/绑定各启动一次不重置计时(query_profiler.cpp:138-161);
3. **恒开的字节计数**:进度条与画像解耦,画像关了进度条照转(file_system.cpp:817-864);
4. **glob 式指标裁剪**:默认 `*` 全收,可精确裁剪到关心的指标(gathered_metrics.cpp:33-78);
5. **渲染注册表**:新增一种输出格式=注册一个 renderer,EXPLAIN/画像同享(tree_renderer.cpp:51-101);
6. **SECURE_VIEW 折叠**:画像不成为旁路泄露点(query_profiler.cpp:1107-1122)。

## 17.5 FAQ

**Q1:profiler 默认开吗?**
关;但 EXPLAIN ANALYZE 恒开(is_explain_analyze 短路)(query_profiler.cpp:80-82)。

**Q2:cpu_time 是 CPU 时间吗?**
不是,是全树算子墙钟求和,并行下可大于墙钟(:1136-1143)。

**Q3:用的什么时钟?**
steady_clock,纳秒粒度(time_point.hpp:16-41)。

**Q4:有采样吗?**
没有,按算子边界全量累计;裁剪靠 coverage 白名单与 tracked_metrics。

**Q5:画像输出有哪些格式?**
text/json/html/graphviz/yaml/mermaid/no_output+插件(tree_renderer.cpp:51-101)。

**Q6:CTE 扫描显示在哪?**
CTE_SCAN 与其 cte_source 映射到同一 ProfilingNode(:1034-1050)。

**Q7:画像会泄露 secure view 吗?**
不会,SECURE_VIEW 子树输出前折叠(:1107-1122)。

**Q8:字节读写在画像关闭时还计数吗?**
恒计数,供进度条使用(file_system.cpp:817-864)。

**Q9:多线程计时怎么合并?**
每 pipeline 完成即 Flush 合并清零,ExecutorTask 析构再补一次(pipeline_executor.cpp:718)。

**Q10:start_at_optimizer 有效吗?**
遗迹参数,全仓无 true 调用点(query_profiler.hpp:101)。

## 17.6 小结与深挖方向

本章结论:**画像=每连接一个 QueryProfiler+线程本地 OperatorProfiler+墙钟求和;EXPLAIN ANALYZE=包一层 sink 真跑并把树渲染成结果集**。深挖:

1. GatheredMetrics 的 glob 匹配实现与指标名全集(gathered_metrics.cpp:33-78);
2. TREE 渲染的 operators/optimizer 卡片分层逻辑(tree_renderer);
3. CollapseSecureViews 对视图套视图的递归折叠(:1107-1122);
4. MetricsTimer 在流式长查询下的中间态输出(profiling_utils.hpp:175-232);
5. 进度条与画像共用的计数器生命周期(client_data.cpp:226)。
