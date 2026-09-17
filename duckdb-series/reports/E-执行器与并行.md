# E · 执行器与并行：push-based pipeline 与线程调度

> 基线：commit 7e886f44428e90c8379d4d34e2afb866108ff079（2026-09 主干）。
> 所有 `文件:行号` 均已在该基线上逐一 Read/Grep 核对。
> 核心目录：`src/parallel/`（Executor/Pipeline/Event/线程池），`src/execution/`（算子基类与具体算子），
> 头文件在 `src/include/duckdb/execution/` 与 `src/include/duckdb/parallel/`。

DuckDB 执行层把一条物理计划切成若干条 **pipeline**：每条 pipeline 有唯一的 **source**、
零到多个中间 **operator**、唯一的 **sink**。数据以 `DataChunk`（向量化批）为单位，从 source
被"拉"出一次，随后沿算子链被"推"进 sink——这就是 push-based 执行。pipeline 之间以 DAG
表达依赖（join 的 build 先于 probe），由 Event/Task 状态机投递到全局线程池并发执行。

## 1. 全景图：一条聚合查询如何被切块并行

以 `SELECT region, sum(amount) FROM orders GROUP BY region;` 为例，结果收集器（RESULT_SINK）挂在计划根部：

```
物理计划:                       切成 pipeline (BuildPipelines, physical_operator.cpp:245-275)

  RESULT_SINK                        ┌─ Pipeline P2 (root) ────────────────┐
      ^ sink           ^ source      │ source : HASH_AGGREGATE (物化后的HT)│
      │                │             │ sink   : RESULT_SINK                │
  HASH_AGGREGATE ───────┘             └──────────▲──────────────────────────┘
      ^ sink      ^ source                       │ 依赖: P1 的 Finalize 全部完成
      │           │                              │ (pipeline_schedule.cpp:196-206)
  TABLE_SCAN                                      │
                                                  │
                                      ┌─ Pipeline P1 ───────────────────────┐
                                      │ source : TABLE_SCAN                 │
                                      │ ops    : (filter/projection…)       │
                                      │ sink   : HASH_AGGREGATE             │
                                      └──────────▲──────────────────────────┘
                                                 │ TryGetMaxThreads 定并行度
       线程池 (默认=核数)                        │ (pipeline.cpp:118-157)
   T0      T1      T2      ...      Tn-1         │ max_threads 个 PipelineTask
    │       │       │               │            │ (pipeline.cpp:321-335)
    ▼       ▼       ▼               ▼            ▼
  [P1.task0][P1.task1][P1.task2]…[P1.taskn]   各任务各自建 PipelineExecutor
    │        │       │               │          (pipeline_executor.cpp:31-77)
  source拉chunk→算子链push→Sink()          每线程一份 LocalSinkState
    └────────┴───────┴───────┬────────┘
                       全部线程 Combine (pipeline_executor.cpp:685-721)
                             │
                       PipelineFinishEvent → sink->Finalize → PipelineCompleteEvent
                             │           → executor.CompletePipeline (executor.hpp:97-99)
                             ▼
                       P2 依依赖被调度: HASH_AGGREGATE 作 source 吐结果 → RESULT_SINK
```

要点：P1 是 P2 的"生产者"，但两者不是靠数据队列衔接，而是靠 **Finalize 完成即依赖满足**
的事件图衔接；P1 内部是**多线程共享同一个 sink**（各写各的 LocalSinkState，Combine 时合并）；
P2 把聚合 HT 当作新 source 再次并行扫描。注意 HASH_AGGREGATE 出现两次角色：在 P1 里是 sink，
在 P2 里是 source——这正是 `BuildPipelines` 中 `IsSink()` 分支同时做 `SetPipelineSource`
与"为子计划开新 MetaPipeline"两件事的原因。

## 2. Executor：物理计划 → pipeline 列表 → Event 图

入口链路从客户端开始：`ClientContext::PendingPreparedStatementInternal` 为每条查询创建一个
`Executor`（src/main/client_context.cpp:643），先取结果收集器作为计划根（client_context.cpp:663-675），
再调用 `Executor::InitializeInternal` 完成切块与调度（src/parallel/executor.cpp:234-276）：

```cpp
// src/parallel/executor.cpp:244-251
PipelineBuildState state;
auto root_pipeline = make_shared_ptr<MetaPipeline>(*this, state, nullptr);
root_pipeline->Build(*physical_plan);

// Resolve graph-dependent input modes after every pipeline and dependency has been constructed.
vector<shared_ptr<MetaPipeline>> to_schedule;
root_pipeline->GetMetaPipelines(to_schedule, true, true);
```

`MetaPipeline` 是"一组写向同一个 sink 的 pipeline"的打包（一个 MetaPipeline 对应一个 sink 算子；
内部可能因 join/union 等产生多条 Pipeline）。`root_pipeline->Build` 直接转调算子的虚函数
`BuildPipelines`（src/parallel/meta_pipeline.cpp:93-97）。切块规则在
src/execution/physical_operator.cpp:245-275，只有三条：叶子且非 sink 的算子 `SetPipelineSource`
后收尾；`IsSink()` 的算子把自己定为当前 pipeline 的 source，同时为子计划 `CreateChildMetaPipeline`、
自己当子 pipeline 的 sink（physical_operator.cpp:259-269）；其余算子 `AddPipelineOperator` 挂进
当前 pipeline 后向唯一孩子递归（physical_operator.cpp:272-275）。

join 等复合算子覆写切块：`PhysicalJoin::BuildJoinPipelines` 先把本算子挂为 probe 侧 operator
（src/execution/operator/join/physical_join.cpp:38），再为 RHS（build 侧）开子 MetaPipeline
（physical_join.cpp:47-50）；build 侧若能喂饱全部线程，还会把依赖递归传播到 probe 的子树，
避免"广度优先"执行（physical_join.cpp:51-57 与 meta_pipeline.cpp:159-224 的
`PipelineExceedsThreadCount` 判定）；若 join 自身 `IsSource()`（RIGHT/OUTER 或外存哈希连接），
再补一条以 join 为 source 的子 pipeline（physical_join.cpp:79-82）。

切块完成后 `ScheduleEventsInternal` 把 MetaPipeline 图编译成 **Event 图**（executor.cpp:81-114）：
每条 pipeline 展开为五个调度阶段（src/parallel/pipeline_schedule.cpp:108-120）：
INITIALIZE → EXECUTE → PREPARE_FINISH → FINISH → COMPLETE，五种 Event 类型由
`CreatePipelineScheduleEvent` 逐一实例化（executor.cpp:59-79）。
pipeline 间依赖被翻译成"我的 EXECUTE 依赖你的 COMPLETE"（pipeline_schedule.cpp:196-206，
注释明言：依赖只有在对方 sink finalize 后才算完成）；dataflow 依赖则只要求对方 INITIALIZE 完成
（pipeline_schedule.cpp:207-215）。构建完毕先做无环校验（executor.cpp:86-88），
再把无依赖的事件立即 `Schedule()`（executor.cpp:106-113）。

## 3. Pipeline：source / sink / operators 三段结构

`Pipeline` 对象只有三个算子槽位：`sink`、`source`、`operators`（src/parallel/pipeline.cpp:74-76）。
构建期 `operators` 按"自根向叶"顺序收集，`Ready()` 时一次性**反转**为执行期顺序
（pipeline.cpp:583-589）。

**什么算子断开 pipeline**：即第 2 节 `IsSink()` 分支命中的算子——一切需要"看完所有输入才能产出"
的算子（聚合、排序、hash join build 侧、insert/update、结果收集器、递归 CTE 工作表等）。
断点两侧的数据流天然阻塞，因此以"上一条 pipeline 的 sink + 下一条 pipeline 的 source"
双角色衔接。sink 侧接口还带一个分批钩子 `NextBatch`：当 sink 声明 `RequiredPartitionInfo`
要求 batch index（保序输出/外存落盘）时，执行器在每次源批号变化处回调它
（接口见 src/include/duckdb/execution/physical_operator.hpp:216-220；执行侧判定在
src/parallel/pipeline_executor.cpp:226-243 与 pipeline.cpp:167-173）。

管道内的 operator 分两类：普通算子实现 `Execute(input, chunk)` 逐 chunk 流过；实现
`RequiresFinalExecute()` 的"缓存算子"（如缓存了小 chunk 的过滤器）会在 source 枯竭后由
`TryFlushCachingOperators` 逐个"放水"，把残留 chunk 继续向 sink 推
（src/parallel/pipeline_executor.cpp:159-224；FinalExecute 调用点在 pipeline_executor.cpp:196-198）。

## 4. PipelineExecutor：push-based 主循环

每条 pipeline 的每个并行任务各持一个 `PipelineExecutor`。构造时为当前线程创建 sink 的 `LocalSinkState`、source 的 `LocalSourceState`（src/parallel/pipeline_executor.cpp:33-55），并**一次性预分配**算子链每级的中间 chunk（按前一级输出类型初始化）与 per-thread `OperatorState`（pipeline_executor.cpp:57-75）。若某个中途算子已知"不可能有输出"（`SinkFinalizeType::NO_OUTPUT_POSSIBLE`），整个 pipeline 直接跳过执行（pipeline_executor.cpp:70-74）。

主循环 `Execute(max_chunks)` 的"常规路径"（pipeline_executor.cpp:377-412）：

```cpp
// src/parallel/pipeline_executor.cpp:379-396 (节选)
if (!next_batch_blocked) {
    // "Regular" path: fetch a chunk from the source and push it through the pipeline
    source_chunk.Reset();
    source_result = FetchFromSource(source_chunk);
    ...
    if (source_result.result == SourceResultType::FINISHED) {
        exhausted_source = true;
        exhausted_pipeline = true;
    }
}
...
result = ExecutePushInternal(source_chunk, chunk_budget);
```

`ExecutePushInternal`（pipeline_executor.cpp:558-610）是 push 语义的本体：循环条件写在注释里——只要算子返回 `HAVE_MORE_OUTPUT`、sink 不阻塞、chunk 预算未耗尽，就持续推进（pipeline_executor.cpp:565-569）。链上部分先把 `input` 逐级 `Execute` 进 `final_chunk`（无算子时 `final_chunk.Reference(input)` 零拷贝，pipeline_executor.cpp:574-576），随后把 `final_chunk` 喂给 `pipeline.sink->Sink()`（pipeline_executor.cpp:587-603）。sink 返回 `BLOCKED` 时把现场记进 `remaining_sink_chunk` 并返回 `INTERRUPTED`，任务整体被 deschedule，恢复后从断点续推（pipeline_executor.cpp:417-421 与 612-647）。

算子链内部是"从当前下标向后走"的循环 `Execute(input, result, initial_idx)`（pipeline_executor.cpp:736-809）：某级输出为空就退回 source 再取数；某算子返回 `HAVE_MORE_OUTPUT` 则把下标压入 `in_process_operators` 栈（pipeline_executor.cpp:775-778），下一轮从栈顶恢复而不是从头拉数——`GoToSource` 的注释举例：join 里还有剩余 tuples 时必须先吐完（pipeline_executor.cpp:723-734）。

**与旧 pull-based 的区别与残留**：当前代码中唯一真正的 pull 是 `FetchFromSource` 对 source 的 `GetData`（pipeline_executor.cpp:850-873）；一切中间算子的签名都是 `(input_chunk, output_chunk)` 的推入式（physical_operator.hpp:105-106），不存在"上层算子反复向下层要 chunk"的旧执行器路径。`in_process_operators` 栈可视为迭代器语义的局部残留，但它只作用于单条 pipeline 内部的算子链恢复，不构成跨算子的 pull。

收尾分两级。**每线程级**：`PushFinalize` 调 `sink->Combine` 把本线程 `LocalSinkState` 并入 `GlobalSinkState`，随后刷新 profiler（pipeline_executor.cpp:685-721，Combine 调用点在 700 行）。**全局级**：sink 的 `Finalize` 在所有线程 Combine 完成后由 `PipelinePrepareFinishEvent`/`PipelineFinishEvent` 触发（事件创建于 executor.cpp:70-73），例如 hash 聚合在这里物化最终 HT。

任务切片与中断：`PipelineTask::ExecuteTask` 惰性创建 PipelineExecutor，`PROCESS_PARTIAL` 模式每次最多推 `PARTIAL_CHUNK_COUNT = 50` 个 chunk，未完返回 `TASK_NOT_FINISHED` 让任务重新排队（src/parallel/pipeline.cpp:39-72；常量在 src/include/duckdb/parallel/pipeline.hpp:49）。查询出错时 `Executor::PushError` 置中断标记并对所有 pipeline 调 `FinishSourceAndPreventBlocking`/`PreventSinkBlocking`，让阻塞中的任务尽快解除泊车（executor.cpp:555-564；解除泊车实现 pipeline.cpp:462-503）；`CancelTasks` 则彻底排干并丢弃所有任务（executor.cpp:278-326）。

## 5. Event 与 Task：状态机和线程池

Event 是最小同步单元：`FinishTask` 原子递增（`++finished_tasks`），最后一个任务完成即 `Finish()`，
进而通知所有父事件 `CompleteDependency`；依赖计数归零的父事件才 `Schedule()`
（src/parallel/event.cpp:14-64,56-64）。`Event::SetTasks` 把任务批量投递到调度器（event.cpp:79-85）。
`PipelineCompleteEvent::FinalizeFinish`
回调 `executor.CompletePipeline()` 给完成 pipeline 计数（src/parallel/pipeline_complete_event.cpp:13-17；
executor.hpp:97-99），计数到达 `total_pipelines` 即 `ExecutionIsFinished()`（executor.cpp:428-430）。

Task 是线程池的调度单位（src/include/duckdb/parallel/task.hpp:21-37，定义 `PROCESS_ALL`/
`PROCESS_PARTIAL` 与四种执行结果）。基类 `ExecutorTask` 统一包异常并打点 profiler，
`PROCESS_ALL` 模式下以小步循环驱动直到完成（src/parallel/executor_task.cpp:39-63）。

线程池**每数据库一个** `TaskScheduler`（src/parallel/task_scheduler.cpp:50-56）。worker 主循环
`ExecuteForever`：信号量等待（空闲 0.5s 后顺手 flush 分配器缓存）、出队、执行；`TASK_BLOCKED`
的任务 `Deschedule` 挂起等待回调唤醒（task_scheduler.cpp:160-214；出队处理
`TryDequeueAndProcessTask` 在 124-158，BLOCKED 分支在 145-149）。任务队列按 producer token
隔离，保证一条查询的任务只被它自己及空闲 worker 消费（task_scheduler.cpp:58-82）；客户端线程
也能通过 `Executor::WorkOnTasks` 认领本查询任务，无 worker 空闲时仍能推进
（executor.cpp:328-342）。pending 驱动模式下，主线程用 `Executor::ExecuteTask(PROCESS_PARTIAL)`
推进任务，持有半成品任务时 `HasTaskInProgress` 避免无谓等待
（executor.cpp:432-512；executor.hpp:60-62）。

## 6. 并行度从哪来：线程数与扫描切分

**全局线程数**默认取机器核数：`DBConfig::GetSystemMaxThreads` 用
`std::thread::hardware_concurrency()`，Linux 上再被 SLURM 环境变量与 cgroup CPU 配额修正
（src/main/config.cpp:648-665）；用户可用 `SET threads` 覆盖（`TaskScheduler::SetThreads`，
task_scheduler.cpp:307-322），实际起/停线程在 `TaskSchedulerPool::RelaunchThreads`
（src/parallel/task_scheduler_pool.cpp:159-223，含 AUTO 模式下线程数 ≥64 才绑核的阈值，
task_scheduler_pool.cpp:31,144-149）。

**单条 pipeline 的并行度**由 `Pipeline::TryGetMaxThreads` 协商：

```cpp
// src/parallel/pipeline.cpp:118-128 (节选)
bool Pipeline::TryGetMaxThreads(idx_t &max_threads) {
    // check if the sink, source and all intermediate operators support parallelism
    if (!sink->ParallelSink()) {
        return false;
    }
    if (!source->ParallelSource()) {
        return false;
    }
    auto source_state = GetSourceState();
    max_threads = source_state->MaxThreads();
```

随后每个中间算子的 `op_state->MaxThreads` 与 sink 的 `sink_state->MaxThreads` 逐级收窄，
最终夹到池线程数（pipeline.cpp:130-155）。任一环节不支持并行，整条 pipeline 退化为单任务
`ScheduleSequentialTask`（pipeline.cpp:112-116,307-319）。

表扫描的并行度来自表函数侧：`GlobalTableFunctionState::MaxThreads()` 默认 1，返回
`MAX_THREADS = 999999999` 表示"能开多少开多少"（src/include/duckdb/function/table_function.hpp:70-92）；
`PhysicalTableScan` 在构造 global 状态时转调 `init_global` 产物取值（
src/execution/operator/scan/physical_table_scan.cpp:41-52）；`ParallelSource` 只要求是普通表函数
而非 in-out 函数（physical_table_scan.cpp:400-407）。终端算子另有按基数估算的兜底：
`EstimatedThreadCount = cardinality / (2×row_group_size)`（physical_operator.cpp:63-80）。

**chunk 批如何分给线程**：调度时 `Pipeline::LaunchScanTasks` 直接为每个线程发一个 `PipelineTask`
（pipeline.cpp:321-335）；线程执行到 source 时**互斥领取下一批**。以物化集合扫描（CTE/聚合结果
再扫描）为例：全局状态按 batch_size 预估 `max_threads`
（src/execution/operator/scan/physical_column_data_scan.cpp:23-39,73-92）；每个线程的 local state
在 `AssignTask` 里持锁领一段 chunk 区间并分配递增 batch_index（106-129 行）：

```cpp
// src/execution/operator/scan/physical_column_data_scan.cpp:112-128 (节选)
idx_t task_count = 0;
lock_guard<mutex> l(gstate.global_scan_state.lock);
while (task_count < gstate.batch_size) {
    ...
    entries.emplace_back(chunk_index, segment_index, row_index);
    task_count += ...count;
}
if (entries.empty()) {
    return false;
}
batch_index = gstate.next_batch_index++;
```

动态领取而非静态均分，天然抗数据倾斜；`batch_index` 经 `GetPartitionData` 传给 sink，供保序结果
按批归并（pipeline_executor.cpp:226-254 的 batch 映射与 `BATCH_INCREMENT` 段间隔离，
段常量在 src/include/duckdb/parallel/pipeline.hpp:69）。

## 7. 算子侧并行：聚合与 join 的状态分相

**三类接口与状态**（src/include/duckdb/execution/physical_operator.hpp）：Operator
（`GetOperatorState`/`Execute`/`FinalExecute`，96-116 行）、Source（`GetGlobalSourceState`/
`GetLocalSourceState`/`GetData`，127-171 行）、Sink（197-223 行）。头文件注释把并发约定写得很明确：
`Sink` 可被多线程并发调用，需注意对 `GlobalSinkState` 加锁；`Combine` 在单线程完成自己那部分后调用，
是 `LocalSinkState` 的最后访问时机，可与其它 `Sink`/`Combine` 并行；`Finalize` 在**所有**线程结束后
调用，每 pipeline 仅一次、完全单线程（physical_operator.hpp:200-215）。另有两个资源钩子：
`PrepareFinalize`（finalize 前汇报内存）与 `GetMaxThreadMemory`（每线程内存 = 总限/线程数/4，
physical_operator.cpp:212-218）。

**PhysicalHashAggregate**（src/execution/operator/aggregate/physical_hash_aggregate.cpp）：
`Sink` 把每 chunk 的聚合子列**按引用**装进 `aggregate_input_chunk`（439 行），再对每个 grouping
压入 radix 哈希表的线程局部分区（457-467 行）；`Combine` 把每个线程的局部 HT 合入全局
（503-523 行，合并点 519 行）；`Finalize` 单线程触发 `table_data.Finalize` 物化（838-860 行）。
聚合算子随后成为下一条 pipeline 的 source：全局 source state 的 `MaxThreads` 按 HT 分区数给出
并行度（890-904 行），`GetData` 用原子 `state_index` 在 grouping 之间动态分工（958-998 行）。
**finalize 确实跨 pipeline**：它不属于 P1 的任何执行任务，而是挂在 P1 的 FINISH 事件阶段；
含 DISTINCT 聚合时还会插入两级 finalize 事件——先并行把 distinct radix 表并回主 HT，
再插入常规 finalize 事件（HashAggregateDistinctFinalizeEvent::FinishEvent 里 `InsertEvent`，
584-689 行；分派逻辑 842-847 行）。

**PhysicalHashJoin**：build 侧是独立 MetaPipeline（physical_join.cpp:47-50）。build 的 sink 阶段
各线程把 join key+payload 建进线程局部 HT（src/execution/operator/join/physical_hash_join.cpp:764-796，
建表调用在 793 行 `hash_table->Build`）；`Combine` 把各局部 HT 收进全局列表
（physical_hash_join.cpp:802-834，816-820 行）。finalize 决定是否并行构造全局 HT：默认超过
100 万行（`PARALLEL_CONSTRUCT_THRESHOLD`，840 行）才并行，key 高度倾斜时回退单线程
（843-872 行）。probe 侧沿用原 pipeline：join 作为中间 operator 用共享 HT 探测；只有
RIGHT/OUTER/外存场景才追加一条以 join 为 source 的子 pipeline（physical_join.cpp:79-82）。
外存（external）模式由 source 侧状态机 `INIT→BUILD→PROBE→SCAN_HT→DONE` 分相推进
（physical_hash_join.cpp:2149-2209，`MaxThreads` 在 2168-2181 行）。兄弟 build pipeline 之间还有
PrepareFinalize/Finalize 级的全局排序约束，让 `TemporaryMemoryManager` 在所有内存需求已知后再做
决策（pipeline_schedule.cpp:234-275，注释 234-239 行）。

## 8. 与向量化协作：DataChunk 的复用与拷贝

一次 push 的单位就是一个 `DataChunk`。执行器在构造期为算子链每级预分配一个中间 chunk，按
**前一级算子的输出类型**初始化（pipeline_executor.cpp:57-65）；任务重入（partial 执行后的续跑）时
显式保留这些 chunk 的内存、只重置内容，注释原文 "Keep intermediate chunks — reuse their allocated
memory"（pipeline_executor.cpp:132-148）。

链上传值尽量零拷贝：无算子时 `final_chunk.Reference(input)` 只挪引用
（pipeline_executor.cpp:574-576）；聚合 `Sink` 对聚合子列也是 `Reference`
（physical_hash_aggregate.cpp:439）。真正复制发生在"窄化"场景：`CachingPhysicalOperator`
会把过滤后的小 chunk 缓存并合并成满 chunk 再下发，`SelectExecutionMode` 状态机枚举
`RETURN_CACHED/APPEND_CHUNK/RETURN_CACHED_THEN_CHUNK_VIA_CONTINUATION` 等全部组合
（physical_operator.cpp:352-434），执行入口在 566-651 行——这是 push 模型下抑制"高选择性过滤
产生大量小 chunk"的工程补丁。每 chunk 进出算子都有 `StartOperator/EndOperator` 打点与
`Verify` 校验（pipeline_executor.cpp:880-891）。

## 9. Result 收尾：从 sink 回到客户端

结果收集器本身就是一个 sink：`PhysicalResultCollector::GetResultCollector` 按"计划是否保序 /
是否有 batch index"选择 `PhysicalResultSink` 的三种 `ResultOrdering`
（UNORDERED / SOURCE_ORDERED / BATCH_INDEX_ORDERED，
src/execution/operator/helper/physical_result_collector.cpp:23-37）；其中 SOURCE_ORDERED 时
sink 强制单线程以保持输入序（src/execution/operator/helper/physical_result_sink.cpp:269-272）。
它的 `BuildPipelines` 同样走"自己是 sink、为子计划开新 MetaPipeline"的路径
（physical_result_collector.cpp:43-56）——这就是 P2 的来源。

执行结束后：pending 循环 `PendingQueryResult::ExecuteInternal` 反复驱动 `ExecuteTask`，
`BLOCKED` 时 `WaitForTask`（src/main/pending_query_result.cpp:73-94）；完成后
`ClientContext::FetchResultInternal` 直接向 executor 要结果（src/main/client_context.cpp:450-466），
`Executor::GetResult` 转给收集器（executor.cpp:633-638）。`PhysicalResultSink::GetResult`
按生命周期二选一：RETAINED 打包 `ColumnDataCollection` 成 `MaterializedQueryResult`，
流式返回持有缓冲的 `StreamQueryResult`（physical_result_sink.cpp:214-252）。客户端逐批取数经
`QueryResult::Fetch` → `FetchRaw` → `Flatten()`（src/main/query_result.cpp:131-142）。
流式结果被消费端背压时，producer 任务可"泊车"（parked producer，physical_result_sink.cpp:254-260），
唤醒由 `Executor::WaitForTask`/`ResultCollectorIsBlocked` 协调（executor.cpp:362-391,617-631）。

## 10. 设计动机

1. **为什么 push-based**：source 一次拉取、沿链推送，避免 pull 模型中每个算子都要实现可重入
   迭代器，且天然表达"一个输入批在算子内膨胀成多批"（`HAVE_MORE_OUTPUT` +
   `in_process_operators` 栈，pipeline_executor.cpp:775-778）。push 还让 sink 成为天然汇聚点：
   多线程各自推送线程局部状态即可，无需算子间队列与调度。
2. **为什么 pipeline 按 sink 断开**：断点必须落在"看完全部输入才能产出"的算子上。以 sink 为界
   切 DAG，把阻塞边界显式化为事件依赖（pipeline_schedule.cpp:196-206），段内纯流水可任意并行，
   段间一个 Finalize 栅栏即可，不需要复杂的跨段数据队列与反压协议。
3. **为什么 local/global state 分离 + Combine**：把"每线程私有、无锁写入"的部分隔离进
   LocalSinkState/LocalSourceState，把跨线程共享收敛到 Global*State；
   `Sink→Combine→Finalize` 三相把并发面压到最小，同时给内存规划一个明确挂点
   （PrepareFinalize 上报，pipeline_schedule.cpp:234-244）。
4. **为什么线程数可配且默认按核**：查询可并行度取决于扫描批数（MaxThreads 协商链，
   pipeline.cpp:118-157），池大小取决于部署环境——容器/cgroup/SLURM 里"物理核数"未必正确
   （config.cpp:648-665）。默认按核开箱即用，`SET threads` 覆盖以适配部署，两者解耦。
5. **为什么 finalize 单独成阶段**：全局 HT 物化、并行构造决策、内存汇总是"一次且单线程"或
   "全 barrier 后"才能做的事。从 Combine 拆出 finalize，既缩短临界区，又允许插入多级事件
   （DISTINCT 两级 finalize，physical_hash_aggregate.cpp:642-689）和兄弟 pipeline 的交叉排序约束
   （pipeline_schedule.cpp:269-273）。
6. **为什么动态领批而非静态均分**：持锁领批（physical_column_data_scan.cpp:112-128）让慢线程
   不拖累整体，倾斜数据自动再平衡；`batch_index` 同时承担保序归并与乱序容忍
   （`min_batch_index` 追踪，pipeline_executor.cpp:274-326）。

## 11. 写作素材清单

- src/parallel/executor.cpp:244-251 —— MetaPipeline 构建：计划→pipeline 的起点
- src/execution/physical_operator.cpp:245-275 —— BuildPipelines：source/sink/operator 三分叉（断 pipeline 的判定）
- src/parallel/pipeline.cpp:118-157 —— TryGetMaxThreads：并行度在 source/算子/sink 间协商
- src/parallel/pipeline.cpp:321-335 —— LaunchScanTasks：每线程一个 PipelineTask
- src/parallel/pipeline_executor.cpp:558-610 —— ExecutePushInternal：push 主路径与 sink 推入
- src/parallel/pipeline_executor.cpp:736-809 —— 算子链循环与 in_process_operators
- src/parallel/pipeline_executor.cpp:685-721 —— PushFinalize：每线程 Combine 收尾
- src/parallel/event.cpp:14-64 —— Event 依赖计数与 Finish 状态机
- src/parallel/task_scheduler.cpp:160-214 —— worker 线程 ExecuteForever 主循环
- src/main/config.cpp:648-665 —— 默认线程数=核数（cgroup/SLURM 修正）
- src/execution/operator/scan/physical_column_data_scan.cpp:106-129 —— 持锁动态领批 + batch_index 分配
- src/execution/operator/aggregate/physical_hash_aggregate.cpp:503-523 —— Sink/Combine 两相合并局部 HT
- src/execution/operator/aggregate/physical_hash_aggregate.cpp:838-860 —— Finalize 单线程物化（跨 pipeline 阶段）
- src/execution/operator/join/physical_join.cpp:31-83 —— build/probe 两条 pipeline 的构建与递归依赖
- src/execution/operator/helper/physical_result_sink.cpp:214-252 —— 流式/物化两种 QueryResult 的诞生
- src/parallel/pipeline_schedule.cpp:108-120 —— 每条 pipeline 的五阶段事件展开
