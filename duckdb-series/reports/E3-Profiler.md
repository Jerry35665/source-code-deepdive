# 报告 E3 · 查询画像与 EXPLAIN ANALYZE(DuckDB 卷三)

> 基线:7e886f44。一句话总结:DuckDB 把"画像"做成每个连接一份的 QueryProfiler——解析前启动、物理计划建树、每线程 OperatorProfiler 按 pipeline/任务边界 Flush 合并,EXPLAIN 只渲染静态计划的 ParamsToString 树,而 EXPLAIN ANALYZE 把真执行包进 PhysicalExplainAnalyze sink,在收尾时从同一棵 ProfilingNode 树渲染出带 rows/耗时/热度的文本、JSON 或 HTML 等任意注册格式。

说明:本 commit 的 profiler 已从早期"ProfilingInfo+JSON map"重构为 `ProfilingNode(OperatorMetrics)` + `GatheredMetrics` + `QueryProfileResult` 三件套,渲染统一走 `TreeRenderer`(与 EXPLAIN 共用注册表)。行号均指仓库根相对路径。

## 一、生命周期:画像的"启动—建树—收尾"三步

每个 ClientContext 一份 profiler(`src/main/client_data.cpp:237`),经 `QueryProfiler::Get` 取用(`src/main/query_profiler.cpp:117-119`)。总开关只有两个来源:`is_explain_analyze` 标志或 `enable_profiler` 配置(默认 false,`src/include/duckdb/main/client_config.hpp:34`):

```cpp
// src/main/query_profiler.cpp:80-82
bool QueryProfiler::IsEnabled() const {
	return is_explain_analyze || ClientConfig::GetConfig(context).enable_profiler;
}
```

调用时刻表(全部已核实):
- 启动(解析前):`ClientContext::Query(query)` 惰性路径 `client_context.cpp:1119-1120`、`ParseStatementsInternal` `client_context.cpp:786`;逐语句路径在 `StatementIterator::GetStatementInternal` 里对每条语句 `StartQuery` 并 `AddParserTime`(`src/main/statement_iterator.cpp:62-96`)。
- 再启动(绑定前):`CreatePreparedStatementInternal` 以 `IsExplainAnalyze(statement)` 调 `StartQuery`(`src/main/client_context.cpp:469-478, 486-487`)。此时 profiler 已 running,`StartQuery` 只刷新 SQL 字符串不重置(`query_profiler.cpp:153-159`);`StartExplainAnalyze` 仅置标志(`query_profiler.cpp:220-222`)。
- 建树:Executor 初始化时 `profiler->Initialize(plan)`(`src/parallel/executor.cpp:240, 253`),递归 `CreateTree` 构造 ProfilingNode 树并填 `tree_map`(`query_profiler.cpp:1059-1075, 1029-1057`)。
- 运行中:每 pipeline 完成时 `pipeline.executor.Flush(thread)`(`src/parallel/pipeline_executor.cpp:718`),ExecutorTask 析构时再 Flush 一次(`src/parallel/executor_task.cpp:20-27`)。
- 收尾:`EndQueryInternal` 调 `client_data->profiler->EndQuery()`(`src/main/client_context.cpp:378`);EndQuery 里 FinalizeMetrics、写日志、按配置打印或落盘,但 `is_explain_analyze` 分支不打印不写文件(`query_profiler.cpp:224-263, 240-244`)——EXPLAIN ANALYZE 的输出由物理算子自己产出(见第五节)。
- 流式补充:流式结果关闭前记录峰值缓冲 `SetStreamingPeakBufferSize`(`client_context.cpp:411-417`)。

`StartQuery` 的幂等语义值得单独看:重复调用(解析→绑定各一次)不会重置已跑的计时,`is_explain_analyze` 则在入口提前置位;`start_at_optimizer` 形参保留但无人传 true:

```cpp
// src/main/query_profiler.cpp:138-161(节选,略去 start_at_optimizer 分支)
void QueryProfiler::StartQuery(const string &query, bool is_explain_analyze_p, bool start_at_optimizer) {
	lock_guard<std::mutex> guard(lock);
	// Always reset byte counters at the start of each query so the progress bar shows per-query values
	query_metrics.bytes_read = 0;
	query_metrics.bytes_written = 0;
	if (is_explain_analyze_p) {
		StartExplainAnalyze();
	}
	if (!IsEnabled()) {
		return;
	}
	if (running) {
		// Called while already running: this happens when statement setup follows parser timing,
		// or when we print optimizer output.
		query_metrics.query_sql = query;
		return;
	}
	Start(query);
}
```

`EndQuery` 的输出决策(本 commit 新行为):只有"非 EXPLAIN ANALYZE 且格式不是 no_output"才向终端打印或按 `profiler_save_location` 落盘(`query_profiler.cpp:240-262`);无论哪种情况 `ToLogInternal` 都把最终指标交给日志系统(`query_profiler.cpp:247, 836-846`)。

## 二、计时机制:steady_clock 墙钟,与"cpu_time"的真相

底层 `Profiler` 只是一个 `TimePoint::Tick()` 对,而 `TimePoint` 明确封装 `std::chrono::steady_clock`(`src/include/duckdb/common/time_point.hpp:16-41`),纳秒粒度:

```cpp
// src/include/duckdb/common/profiler.hpp:39-50
double Elapsed() const {
	if (!ran) {
		return 0;
	}
	int64_t elapsed_nanos = 0;
	if (finished) {
		elapsed_nanos = TimePoint::ElapsedNanos(start, end);
	} else {
		elapsed_nanos = start.ElapsedNanos();
	}
	return static_cast<double>(elapsed_nanos) / 1e9;
}
```

三层叠加结构:
1. 查询级:RAII 的 `MetricsTimer` 挂在 `QueryMetrics` 上,析构自动 `UpdateMetric(name, 纳秒)`(`src/include/duckdb/main/profiler/profiling_utils.hpp:175-232`):

```cpp
// src/include/duckdb/main/profiler/profiling_utils.hpp:210-217
void EndTimer() {
	if (!is_active) {
		return;
	}
	is_active = false;
	profiler.End();
	query_metrics->UpdateMetric(metric_name, profiler.ElapsedNanos());
}
```

`Start()` 里创建 `latency_timer = MetricQueryTotalTime`(`query_profiler.cpp:121-126`),Finalize 时停表(`query_profiler.cpp:1128-1130`)。planner/optimizer/physical_planner 各有一枚同类计时器(`client_context.cpp:497, 524, 540`)。
2. 算子级:每线程一个 `OperatorProfiler`(挂在 `ThreadContext`,`src/include/duckdb/parallel/thread_context.hpp:18-26`),构造时读一次 `IsEnabled()` 决定 enabled(`query_profiler.cpp:419-421`)。单枚 `Profiler op` + `active_operator` 严格栈式配对:`StartOperator` 首见算子时缓存 `ParamsToString` 为 extra_info(`query_profiler.cpp:423-440`);`EndOperator` 停表并累加:

```cpp
// src/main/query_profiler.cpp:483-495
void OperatorProfiler::EndOperator(optional_ptr<DataChunk> chunk) {
	if (!enabled) {
		return;
	}
	if (!active_operator) {
		throw InternalException("OperatorProfiler: Attempting to call EndOperator while no operator is active");
	}
	auto &info = GetOperatorMetrics(*active_operator);
	op.End();
	info.GatherMetrics(context, op.Elapsed(), chunk);
	active_operator = nullptr;
}
```

`GatherMetrics` 把 elapsed 累进 `time`、按 chunk 累加 `elements_returned`/`intermediate_size_bytes`,并采样 buffer manager 峰值内存与 temp 目录(`query_profiler.cpp:442-457`)。调用点:pipeline 主循环 `pipeline_executor.cpp:771-774, 195-198`、source 侧 `854-870`、sink 侧 `589-596`、ExecutorTask 小步执行 `executor_task.cpp:45-48`。
3. IO/内存:文件系统读写回调直接 `TrackBytesRead/TrackBytesWritten`(`src/common/file_system.cpp:817, 838, 854, 864`),分配器回调 `TrackTotalMemoryAllocated`(`src/main/client_data.cpp:226`);这些计数器"永远追踪",即便画像关闭也供进度条使用(`profiling_utils.hpp:39-47`)。

"采样 vs 全量":没有抽样,是**按算子边界的全量累计**;裁剪发生在两头——`profiling_coverage`(SELECT 默认/ALL,`client_config.hpp:78`)只决定"这棵树里是否出现值得画像的算子类型"(白名单 `query_profiler.cpp:173-218`),若整棵树一个都没有,`Initialize` 直接关掉本次画像(`query_profiler.cpp:1059-1075`);`tracked_metrics`(默认 `{"*"}`,`client_config.hpp:43`)再决定哪些指标被收集与展示,支持 exact/prefix/glob 三种匹配(`src/main/profiler/gathered_metrics.cpp:33-78`)。`query.cpu_time` 并非 OS CPU 时间,而是全树算子时间求和(`query_profiler.cpp:1136-1143`)。

## 三、树的构建、每线程合并与安全视图折叠

`CreateTree` 为**每个**物理算子建一个 `ProfilingNode`(不做类型过滤),名字取枚举串、参数取 `ParamsToString`,并以裸指针为键登记 `tree_map`;CTE_SCAN 把其 `cte_source` 也映射到同一节点(`query_profiler.cpp:1034-1050`):

```cpp
// src/main/query_profiler.cpp:1034-1048(节选)
auto node = make_uniq<ProfilingNode>();
auto &info = node->GetOperatorMetrics();
node->depth = depth;
info.name = EnumUtil::ToString(root_p.type);
info.operator_type = root_p.type;
auto params = root_p.ParamsToString();
info.SetExtraInfo(std::move(params));
tree_map.insert(make_pair(reference<const PhysicalOperator>(root_p), reference<ProfilingNode>(*node)));
if (root_p.type == PhysicalOperatorType::CTE_SCAN) {
	auto &cte_scan = root_p.Cast<PhysicalColumnDataScan>();
	if (cte_scan.cte_source) {
		tree_map.insert(
		    make_pair(reference<const PhysicalOperator>(*cte_scan.cte_source), reference<ProfilingNode>(*node)));
	}
}
```

并行合并:各线程的 `OperatorMetrics` 在 pipeline 结束/任务结束时经 `Executor::Flush`→`QueryProfiler::Flush(OperatorProfiler)` 按 `tree_map` 找节点合并,全程持全局 mutex:

```cpp
// src/main/query_profiler.cpp:549-564(节选)
for (auto &node : profiler.operator_metrics) {
	auto &op = node.first.get();
	auto entry = tree_map.find(op);
	// all profiled operators should be registered in the tree
	D_ASSERT(entry != tree_map.end());
	auto &tree_node = entry->second.get();
	auto &info = tree_node.GetOperatorMetrics();
	info.Merge(node.second);
	// Update extra_info from the per-thread metrics: these are set during execution (StartOperator),
	// so they capture runtime values like dynamic filters that aren't known at plan-creation time.
	if (!node.second.GetExtraInfo().empty()) {
		info.SetExtraInfo(node.second.GetExtraInfo());
	}
```

合并语义:`time/elements_returned` 求和、峰值取 max,`total_row_groups_to_scan` 走 `Merge`(取 max 而非累加,与 `Accumulate` 相对),合并后线程侧 `ResetMetrics`(`query_profiler.cpp:459-481, 566-573`)。线程排队时间单独记:`Executor::WaitForTask` 把等待微秒累进原子 `blocked_thread_time`(`src/parallel/executor.cpp:362-392`),Flush 时 `SetBlockedTime` 转秒(`executor.cpp:578-586`),对应指标 `system.blocked_thread_time`(`src/include/duckdb/main/profiler/metrics.hpp:76-82`)。

收尾时 `FinalizeMetricsInternal` 先 `CollapseSecureViews`——SECURE_VIEW(`src/include/duckdb/common/enums/physical_operator_type.hpp:135`)节点用 `SumSubtreeTime` 汇总时间后**删除全部子节点**,防止画像泄露受保护视图内部扫描了哪些行;再把全树算子测量 `Accumulate` 成 query 级指标(`query_profiler.cpp:1107-1146`)。`metrics.hpp` 由 `scripts/generate_metrics.py` 生成(`metrics.hpp:7`),分 query/system/io/storage/operator/optimizer/parser/planner 七组。

## 四、渲染:JSON 树与文本框树(附 EXPLAIN ANALYZE 输出示例)

JSON 路径:`ToResultTree` 生成 `QueryProfileResult`(OBJECT/LIST/VALUE)——query 级指标按点号分层嵌套(`gathered_metrics.cpp:118-143`),算子树由 `OperatorToResultTree` 递归挂到 `"operator"` 列表(`query_profiler.cpp:983-999, 848-860`);`ToJSON` 用 yyjson 写出,OBJECT 子键按"嵌套优先+字母序"排序保证确定性(`query_profiler.cpp:799-834, 1013-1019`)。旧键名(`operator_timing`/`operator_cardinality`/cumulative 累加)由 `LegacyMetricsFormatSetting` 分支 `ToLegacyResultTree` 兼容(`query_profiler.cpp:862-981`;设置标记 deprecated,`src/main/settings/custom_settings.cpp:1885-1886`)。

文本路径:`ProfilingNode`→`RenderTree` 时把关键测量塞进约定键(`src/common/render_tree.cpp:135-148`,完整摘录见下):

```cpp
// src/common/render_tree.cpp:135-147(节选)
static unique_ptr<RenderTreeNode> CreateNode(const ProfilingNode &op) {
	auto &info = op.GetOperatorMetrics();
	auto &node_name = info.name;
	auto result = make_uniq<RenderTreeNode>(node_name, info.GetExtraInfo());
	if (info.total_row_groups_to_scan > 0) {
		result->extra_text["Row Groups Scanned"] =
		    to_string(info.row_groups_scanned) + " / " + to_string(info.total_row_groups_to_scan);
	}
	result->extra_text[RenderTreeNode::CARDINALITY] = to_string(info.elements_returned);
	string timing = StringUtil::Format("%.2f", info.time);
	result->extra_text[RenderTreeNode::TIMING] = timing + "s";
	return result;
}
```

约定键名定义于 `src/include/duckdb/common/render_tree.hpp:26-28`(`__cardinality__`/`__estimated_cardinality__`/`__timing__`,渲染时被剥去双下划线转成显示键,`query_profiler.cpp:681-699`)。文本渲染器把它解析回 `ExplainTreeNode{name, details, rows, timing}`(`src/common/tree_renderer/text_tree_renderer.cpp:331-386`),先剥掉 EXPLAIN_ANALYZE/RESULT_COLLECTOR 包装节点(`text_tree_renderer.cpp:1386-1390`);框内左列 rows(真实行数加粗、估算值带 `~` 前缀,`text_tree_renderer.cpp:866-890, 237-239`)、右列耗时按占比着色(≥25%/10%/1% 分档,`text_tree_renderer.cpp:427-441`);占比 <1% 总时长的算子被折叠成单行(<5% 的隐藏非关键细节,`text_tree_renderer.cpp:629-632, 740-742`),≥30 节点的大计划才整体合并子树(`text_tree_renderer.cpp:1336, 1396-1399`)。画像输出即"Summary 框+算子树"(`RenderQueryTree`,`query_profiler.cpp:628-679`;`text_tree_renderer.cpp:1454-1457`),字段来源:

```text
╭─ Summary ─────────────────╮   ← query_profiler.cpp:644-674 手工画框
│ Total Time: 0.156s        │     "query.total_time" ← latency_timer(Start :125 / 停表 :1128)
│ Data Read: 2.3KB          │     ← query_metrics.bytes_read ← file_system.cpp:854
╰───────────────────────────╯
╭─ Projection ───────╮         ← name=EnumUtil::ToString(type), query_profiler.cpp:1038
│ i                  │         ← extra_info=ParamsToString(), query_profiler.cpp:1040-1041
│ 200 rows │ 0.002s  │         ← elements_returned(render_tree.cpp:144);time(render_tree.cpp:145)
╰─────────┬──────────╯
          │
╭─ Hash Join ───────────╮     ← Hash Join 由 DisplayName 转写(text_tree_renderer.cpp:256-266)
│ Condition: i = j      │     ← extra_info 运行期覆盖(Flush :562-564)
│ 1000 rows    │ 0.081s │     ← 占比≥25% 计 TIMING_CRITICAL 热色(:431-433)
╰─────────┬─────────────╯
```

格式注册表统一了 text/query_tree/query_tree_optimizer/json/html/graphviz/yaml/mermaid/no_output,`no_output` 返回 nullptr 渲染为空,扩展可经 `ProfilerExtension` 插入自定义渲染器(`src/common/tree_renderer.cpp:51-101`;`json_tree_renderer.cpp:103-105` 直接 `ss << profiler.ToJSON()`)。

## 五、EXPLAIN 与 EXPLAIN ANALYZE:同一渲染器,两条物理路径

语法上 `EXPLAIN [ANALYZE] [(FORMAT xxx, ...)]`(`src/parser/peg/grammar/statements/explain.gram:1-2`;FORMAT/ANALYZE 选项解析于 `src/parser/peg/transformer/transform_explain.cpp:14-50`),`ExplainStatement` 携带 `explain_type` 与 `format`(`src/include/duckdb/parser/statement/explain_statement.hpp:16-28`)。绑定阶段:仅普通 EXPLAIN 且非单计划格式时,才渲染未优化逻辑计划存进 `logical_plan_unopt`(`src/planner/binder/statement/bind_explain.cpp:12-24`),输出列名固定 `explain_key/explain_value`(`bind_explain.cpp:26`)。

物理规划分叉(`src/execution/physical_plan/plan_explain.cpp:12-73`)——EXPLAIN ANALYZE 不渲染任何静态计划字符串,只是包一层 sink:

```cpp
// src/execution/physical_plan/plan_explain.cpp:23-31
auto &plan = CreatePlan(*op.children[0]);
if (analyze) {
	auto &explain = Make<PhysicalExplainAnalyze>(op.types, op.format);
	explain.children.push_back(plan);
	return explain;
}

// Format the plan and set the output of the EXPLAIN.
op.physical_plan = plan.ToString(context, op.format);
```

普通 EXPLAIN 的三个值分别来自绑定前(`logical_plan_unopt`)、优化后(`logical_plan_opt`,`plan_explain.cpp:19-22`)与物理计划 `PhysicalOperator::ToString`(名+`ParamsToString` 的渲染树,`src/execution/physical_operator.cpp:28-41`),键集合受 `explain_output` 设置裁剪:

```cpp
// src/execution/physical_plan/plan_explain.cpp:32-49(节选)
vector<string> keys, values;
if (single_plan) {
	keys = {"physical_plan"};
	values = {op.physical_plan};
} else {
	switch (Settings::Get<ExplainOutputSetting>(context)) {
	case ExplainOutputType::OPTIMIZED_ONLY:
		keys = {"logical_opt"};
		values = {logical_plan_opt};
		break;
	case ExplainOutputType::PHYSICAL_ONLY:
		keys = {"physical_plan"};
		values = {op.physical_plan};
		break;
	default:
		keys = {"logical_plan", "logical_opt", "physical_plan"};
		values = {op.logical_plan_unopt, logical_plan_opt, op.physical_plan};
	}
}
```

设置定义在 `src/include/duckdb/main/settings.hpp:1415-1416`。EXPLAIN ANALYZE 则真跑子计划:`PhysicalExplainAnalyze` 是并行 sink(`ParallelSink()=true`,`physical_explain_analyze.hpp:51-53`),`Finalize`(全部输入耗尽后)立即 `profiler.FinalizeMetrics()` 并把画像渲染成字符串存入 sink 状态,`GetData` 时作为单行 `("analyzed_plan", plan)` 返回:

```cpp
// src/execution/operator/helper/physical_explain_analyze.cpp:20-27
SinkFinalizeType PhysicalExplainAnalyze::Finalize(Pipeline &pipeline, Event &event, ClientContext &context,
                                                  OperatorSinkFinalizeInput &input) const {
	auto &gstate = input.global_state.Cast<ExplainAnalyzeStateGlobalState>();
	auto &profiler = QueryProfiler::Get(context);
	profiler.FinalizeMetrics();
	gstate.analyzed_plan = profiler.ToString(format);
	return SinkFinalizeType::READY;
}
```

OPTIMIZER 阶段的展示:优化耗时是 `optimizer.total_time` 指标(`metrics.hpp:280-286`),在 `client_context.cpp:524-532` 计时;文本树 Summary 框只显示 Total Time/Data Read/Written(`query_profiler.cpp:644-654`),planner/optimizer/physical_planner 分解耗时只在 JSON 等完整指标输出里可见(`FinalizeMetrics` 把 `QueryMetrics::string_timings` 逐项写入,`query_profiler.cpp:1145`,`profiling_utils.hpp:50-52`)。

## 六、纠偏:以本 commit 源码为准

1. **"cpu_time"不是 CPU 时间**:指标名叫 `query.cpu_time`,但实现是 `MergeOperatorMeasurements` 对全树算子墙钟时间求和(`query_profiler.cpp:1136-1138`),与 `query.total_time` 同为 `steady_clock` 墙钟;并行下它可大于墙钟。
2. **profiler 默认关闭但 EXPLAIN ANALYZE 恒开**:`IsEnabled()` 被 `is_explain_analyze` 短路为真(`query_profiler.cpp:80-82`);但 EndQuery 对 EXPLAIN ANALYZE 不打印不落盘(`query_profiler.cpp:240-244`),输出完全由 PhysicalExplainAnalyze 经结果集返回。
3. **coverage 白名单不是"只测这些算子"**:`OperatorRequiresProfiling` 的类型清单只决定整条查询是否值得画像(`query_profiler.cpp:1059-1075`);树节点对全部算子建立,无逐类型跳过。
4. **`start_at_optimizer`/`query_tree_optimizer` 已是遗迹**:全仓库无调用点传 `start_at_optimizer=true`(仅声明与默认值,`query_profiler.hpp:101`),`query_tree_optimizer` 只是 TextTreeRenderer 的别名(`tree_renderer.cpp:56`);`PrintOptimizerOutput` 检查的 `"optimizer.join_order"` 键不存在于自动生成的指标表(仅靠 track_all/前缀匹配间接生效,`query_profiler.cpp:99-111`)。
5. **并行时间合并不是"最后一次性平均"**:每 pipeline 完成即 Flush 合并并清零线程侧指标(`pipeline_executor.cpp:718`,`query_profiler.cpp:572`),`time` 语义是求和、峰值才是取 max(`query_profiler.cpp:459-471`);`row_groups_to_scan` 在 Flush(`Merge`)与收尾(`Accumulate`)两个语境下语义不同(`query_profiler.cpp:473-481`)。
6. **画像树结构已重构**:旧版 `ProfilingInfo/JSON map`→现 `ProfilingNode(OperatorMetrics)`(`src/include/duckdb/main/profiler/profiling_node.hpp:16-62`)+`GatheredMetrics`+`QueryProfileResult`,EXPLAIN 与画像共用同一 `TreeRenderer` 注册表,卷一/卷二如引用旧结构需改口径。

## 七、设计动机、FAQ 候选与深挖方向

设计动机(源码佐证):
1. **一套渲染器双用**:EXPLAIN 的静态计划与 ANALYZE 的动态画像共用 `TreeRenderer::CreateRenderer` 注册表(`tree_renderer.cpp:51-101`),格式(text/json/html/graphviz/yaml/mermaid)即插件(`tree_renderer.hpp:25-27`)。
2. **零开销默认关闭**:`enable_profiler=false` 时 `OperatorProfiler.enabled=false`,`Start/EndOperator` 直接 return(`query_profiler.cpp:423-427, 483-487`);字节计数仍保留供进度条(`profiling_utils.hpp:39-47`)。
3. **细粒度指标可选**:glob 式 `tracked_metrics` 让"只看 operator.timing"成为可能,未追踪指标连收集都省(`gathered_metrics.cpp:33-78, 80-106`)。
4. **ANALYZE 输出即查询结果**:把画像渲染成字符串塞进 sink、走普通结果集返回(`physical_explain_analyze.cpp:29-44`),宿主语言无需额外 API。
5. **安全视图防泄露**:`CollapseSecureViews` 在一切输出前折叠,保证"任何格式的 EXPLAIN ANALYZE、画像输出、profile result 看到的都是折叠后的树"(`query_profiler.cpp:1107-1122`)。
6. **可读性优先的渐进折叠**:耗时占比 <1% 的算子折叠、≥30 节点才合并子树、`expand_all` 可展开全部(`text_tree_renderer.cpp:629-632, 1336, 1396-1401`)。

FAQ 候选(每条一句话答案):
1. EXPLAIN ANALYZE 会真的执行查询吗?——会,子计划被真跑一遍,画像在 sink Finalize 时渲染返回。
2. 需要 `PRAGMA enable_profiling` 才能用 EXPLAIN ANALYZE 吗?——不需要,`is_explain_analyze` 强制 IsEnabled()=true(`query_profiler.cpp:80-82`)。
3. `operator.timing` 是 CPU 时间吗?——不是,是 steady_clock 墙钟区间(`time_point.hpp:38-40`)。
4. 为什么开启 profiling 后某些查询没有任何画像输出?——树中无白名单算子(如纯 DDL)时 `Initialize` 直接关闭本次画像(`query_profiler.cpp:1059-1075`)。
5. 普通 EXPLAIN 输出哪几行?——`logical_plan/logical_opt/physical_plan` 三行,受 `explain_output` 设置裁剪(`plan_explain.cpp:37-49`)。
6. `FORMAT json` 的数据从哪来?——`ToJSON()` 经 `QueryProfileResult` 组装、键名字母序输出(`query_profiler.cpp:1013-1019`)。
7. 并行查询的时间会重复计数吗?——算子时间是各线程求和,可超过墙钟;"总时间"以查询级 latency_timer 为准(`query_profiler.cpp:125, 1136-1138`)。
8. `blocked_thread_time` 统计什么?——线程在 WaitForTask 中排队/等结果的微秒累计转秒(`executor.cpp:362-392, 578-586`)。
9. 为什么输出里看不到 EXPLAIN_ANALYZE/RESULT_COLLECTOR 节点?——渲染时包装节点被剥掉(`text_tree_renderer.cpp:1386-1390`)。
10. 旧版 JSON 键名(`operator_cardinality` 等)还能用吗?——开 `legacy_metrics_format` 走 `ToLegacyResultTree` 兼容,且设置已标废弃(`query_profiler.cpp:924`,`custom_settings.cpp:1885-1886`)。

深挖方向:
1. `CollapseSecureViews` 的权限模型:SECURE_VIEW 算子从何处生成、折叠是否覆盖 rows_returned 等旁路信号(`query_profiler.cpp:952-958`)。
2. `ProfilerExtension` 渲染器插件协议与扩展注册路径(`tree_renderer.cpp:90-101`,`src/include/duckdb/main/profiler_extension.hpp`)。
3. `scripts/generate_metrics.py` 生成流水线:指标如何进入日志(`WriteMetricsToLog`,`gathered_metrics.cpp:108-116`)与遥测。
4. CTE/递归 CTE 的画像语义:`cte_source` 双映射导致同一 ProfilingNode 承接两处计时(`query_profiler.cpp:1044-1050`)。
5. 大计划渲染算法:flatten/merge/tier 管线粗细(`TIER1/2_FRACTION`,`text_tree_renderer.cpp:633-636`)与 `expand_all` 的取舍。

## 八、正文蒸馏要点

1. profiler 每连接一份,存于 ClientData(`client_data.cpp:237`),开关 = EXPLAIN ANALYZE 标志 ∥ `enable_profiler`(`query_profiler.cpp:80-82`,默认 false,`client_config.hpp:34`)。
2. 生命周期四锚点:解析前 `StartQuery`(`statement_iterator.cpp:68,94`;`client_context.cpp:1119-1120, 786`)、绑定前再调(`client_context.cpp:487`)、执行前 `Initialize` 建树(`executor.cpp:253`)、清理期 `EndQuery`(`client_context.cpp:378`)。
3. 所有计时都是 `steady_clock` 墙钟(`time_point.hpp:16-41`),查询级 latency_timer + 每线程单枚算子秒表栈式配对(`query_profiler.cpp:423-495`);无采样,靠 coverage 白名单与 tracked_metrics glob 裁剪。
4. `query.cpu_time` = 全树算子时间求和,`total_row_groups_to_scan` 等指标在 Flush(取 max)与收尾(求和)两种合并语义间切换(`query_profiler.cpp:1131-1146, 459-481`)。
5. 树构建对全部算子建 ProfilingNode,`ParamsToString` 存 extra_info,CTE_SCAN 双映射(`query_profiler.cpp:1029-1057`);Flush 时按裸指针 tree_map 合并线程指标并覆盖运行期 extra_info(`query_profiler.cpp:544-574`)。
6. EXPLAIN = 静态渲染(`PhysicalOperator::ToString`,键值三行受 `explain_output` 控制,`plan_explain.cpp:31-49`);EXPLAIN ANALYZE = PhysicalExplainAnalyze sink 真跑,Finalize 时 `FinalizeMetrics()+ToString(format)` 经 `analyzed_plan` 列返回(`physical_explain_analyze.cpp:20-44`)。
7. 文本画像 = Summary 框 + 框树:rows 来自 `elements_returned`、timing 来自 `OperatorMetrics::time`、按占比热着色,<1% 折叠(`render_tree.cpp:135-148`,`text_tree_renderer.cpp:427-441, 629-632`)。
8. JSON 画像 = `QueryProfileResult` 树,指标按点号分层、键字母序,legacy 键名经废弃设置兼容(`gathered_metrics.cpp:118-143`,`query_profiler.cpp:799-834`)。
9. 并行合并发生在 pipeline/任务边界,持全局 mutex,合并后线程侧清零;blocked_thread_time 单独走原子累计(`pipeline_executor.cpp:718`,`executor.cpp:360-392, 578-586`)。
10. OPTIMIZER 展示仅是 `optimizer.total_time` 等 phase 指标(`client_context.cpp:524`,`metrics.hpp:280-286`),文本 Summary 框不显示 phase 分解;`start_at_optimizer`/`query_tree_optimizer` 为无调用点的遗迹(`query_profiler.hpp:101`,`tree_renderer.cpp:56`)。
11. SECURE_VIEW 子树在任何输出前被折叠、时间汇总到边界节点,防止画像泄露受保护视图内部(`query_profiler.cpp:1107-1122`)。
12. EXPLAIN 与画像共用 `TreeRenderer` 注册表(text/json/html/graphviz/yaml/mermaid/no_output + 扩展),`no_output` 渲染为 null、EXPLAIN ANALYZE 显式回退 query_tree(`tree_renderer.cpp:51-101`,`query_profiler.cpp:88-97`)。
