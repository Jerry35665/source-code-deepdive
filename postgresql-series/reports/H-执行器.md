# H — 执行器:Volcano 迭代器、表达式虚拟机与并行查询

> 源码:PostgreSQL master,commit `8c7a74c`(shallow clone)。所有行号均以该 commit 实际 grep/Read 核对。
> 核心文件:`src/backend/executor/`(约 60 个文件)、`src/backend/jit/`、`src/backend/utils/mmgr/`。

## 1. 全景:一条 SELECT 的执行

执行器吃的是规划器输出的**计划树**(只读的 `Plan` 节点),启动时镜像出一棵**状态树**(`PlanState`),执行期所有可变数据都在状态树里——这是官方 README 的第一原则(src/backend/executor/README:47-59,"plan tree is completely read-only")。计划树本质是"按需拉取的元组流水线"(README:6-11)。

一条 `SELECT name FROM dept JOIN emp ON ... WHERE ...` 的典型执行树与拉取流:

```text
        计划树(Planner 产出, 只读)          状态树(ExecInitNode 镜像, 可变)
        ------------------------------      --------------------------------
             HashJoin                            HashJoinState
            /        \                拉流         /         \
      SeqScan(dept)  Hash            <==       SeqScanState   HashState
            |          |                        |              |
      qual: name=?   来自 emp                 ExecScan       build hash table
                                     (ExecProcNode 逐层向上拉,
                                      NULL = 流结束)

  ExecutorStart → ExecInitNode 递归 Init(execProcnode.c:141-420)
  ExecutorRun   → 循环 ExecProcNode(顶层)(execMain.c:308-400, execMain.c:1725 ExecutePlan)
  ExecutorEnd   → ExecEndNode 递归清理(execProcnode.c:543)
```

四阶段生命周期对应 `ExecutorStart/ExecutorRun/ExecutorFinish/ExecutorEnd`(execMain.c:124/308/417/477),README:289-322 给出了完整的控制流草图。顶层拉取循环在 `ExecutePlan`(execMain.c:1724-1799),去掉杂项后就是:

```c
	for (;;)
	{
		/* Reset the per-output-tuple exprcontext */
		ResetPerTupleExprContext(estate);

		slot = ExecProcNode(planstate);

		/*
		 * if the tuple is null, then we assume there is nothing more to
		 * process so we just end the loop...
		 */
		if (TupIsNull(slot))
			break;
		...
	}
```

(execMain.c:1768-1783。)每轮先 `ResetPerTupleExprContext` 清每元组上下文(见 §6),再向根节点要一条——`NULL` 即流结束;`numberTuples`(LIMIT 下推,见 `ExecSetTupleBound`,executor.h:304)决定何时提前收工。注意"每行只调用一次根节点":节点间不传批量,全部同步单步推进,这就是 volcano 的字面含义。卷一 02 章讲过缓冲管理;本章关心的是:缓冲之上的**元组如何被逐个消费**——答案是 volcano 拉模型 + 每节点状态机 + 表达式虚拟机。

## 2. Volcano 专节:一次虚函数调用,一行分发

### 2.1 分发就这十行

核心调度器 `ExecProcNode` 是 `executor.h` 里的 static inline(src/include/executor/executor.h:321-328):

```c
static inline TupleTableSlot *
ExecProcNode(PlanState *node)
{
	if (node->chgParam != NULL) /* something changed? */
		ExecReScan(node);		/* let ReScan handle this */

	return node->ExecProcNode(node);
}
```

没有 switch、没有虚表:每个 `PlanState` 自带一个函数指针 `ExecProcNode`,Init 时由 `ExecInitNode` 统一包装(execProcnode.c:391 `ExecSetExecProcNode(result, result->ExecProcNode)`)。首跳 `ExecProcNodeFirst`(execProcnode.c:448-470)只做两件事:一次性栈深检查(注释明说 x86 上 check 不便宜,所以只做第一次),然后把指针换成真实节点函数或 EXPLAIN 用的 `ExecProcNodeInstr`——之后每次"分发"就是一次直接间接调用,与 02 卷 SQLite VDBE 的 `switch(op)` 单点分发相比,这里把分发成本摊到了函数指针上。

`MultiExecProcNode`(execProcnode.c:487-528)是拉模型的例外通道:Hash、Bitmap 等不逐元组输出的节点走它,一次拉回整个哈希表/位图(execProcnode.c:505-511 只列了四种支持节点)。

### 2.2 四函数约定

每个节点实现四个函数,以最简的 Seqscan 为样本(src/backend/executor/nodeSeqscan.c):

| 函数 | 行号 | 职责 |
|---|---|---|
| `ExecInitSeqScan` | nodeSeqscan.c:220 | 建状态、开表、编译 quals/投影 |
| `ExecSeqScan`(Exec 主体) | nodeSeqscan.c:119-133 | 调 `ExecScanExtended` 拉下一条合格元组 |
| `ExecEndSeqScan` | nodeSeqscan.c:303 | 关表、释放扫描描述符 |
| `ExecReScanSeqScan` | nodeSeqscan.c:347 | 重置游标,支持参数化重扫 |

真正取元组的是 `SeqNext`(nodeSeqscan.c:52-93):惰性 `table_beginscan`(67-85,注释明确"串行执行一个按并行计划的 scan"也走这里),然后 `table_scan_getnextslot` 经表 AM 取下一条(90)。通用骨架在 `ExecScanExtended`(src/include/executor/execScan.h:161-236):`ResetExprContext` → `accessMtd` 取元组 → `ExecQual` 过滤 → `ExecProject` 投影,三步每元组循环;没有 qual 和投影时直接走裸元组快路径(execScan.h:176-180)。nodeSeqscan.c 甚至按"有无 qual/投影/EPQ"编译出四个变体函数(nodeSeqscan.c:119-215),用 `pg_always_inline` 让编译器裁掉死分支——这是 PG 风格:框架不变,把常量折叠做到位。

### 2.3 为什么 30 年不改拉模型

- **计划树只读 + 状态树镜像**使 EXPLAIN、hook、扩展节点都便宜(README:47-59);
- **ReScan 协议**(executor.h:324-325 的 `chgParam` 检查;execAmi.c:78 `ExecReScan`)让参数化内表、initPlan、Limit 提前终止都能自然表达——拉模型下"上游要一条"就是最自然的背压。ReScan 不是无脑重来:Sort/Material 重读自己已物化的数据,HashJoin 单批且内参未变时直接复用哈希表(nodeHashjoin.c:1674-1713),README:22-26 专门说明这套"避免不必要重扫"的启发式。与之配套的是 `ExecShutdownNode`(execProcnode.c:753):EXPLAIN 提前结束时沿状态树发关停信号,让 Hash/Sort 尽早释放,EXPLAIN ANALYZE 才能拿到完整仪表。
- **慢路径罕见**:顺序扫描 + 简单投影的 CPU 开销大头在锁/缓冲/函数调用,不在迭代器框架本身;热点被表达式虚拟机(§4)和 JIT(§4.3)补掉。

DuckDB 等向量化引擎把"每次调用返回一批"作为替代方案,但那是重写执行器才能吃的红利;PG 的路线是不换框架,先用 `pg_always_inline` 变体(execScan.h)、特化 EEOP 快路径(execExprInterp.c:158-178)削平解释开销,再把表达式整体编译成机器码。向量化对 PG 是"可以讨论的扩展",不是"必须的救命稻草"。

## 3. Hash Join 专节:两阶段状态机与批溢出

### 3.1 状态机

`nodeHashjoin.c` 开头是 Zeller & Gray 1990 混合哈希连接的引注(nodeHashjoin.c:15-24)。串行/并行共用一个 `ExecHashJoinImpl`(nodeHashjoin.c:224-793),靠 `parallel` 形参在编译期特化(801-825 两个薄壳)。状态枚举在 182-189 行:

```c
#define HJ_BUILD_HASHTABLE		1
#define HJ_NEED_NEW_OUTER		2
#define HJ_SCAN_BUCKET			3
#define HJ_FILL_OUTER_TUPLE		4
#define HJ_FILL_INNER_TUPLES	5
#define HJ_FILL_OUTER_NULL_TUPLES	6
#define HJ_FILL_INNER_NULL_TUPLES	7
#define HJ_NEED_NEW_BATCH		8
```

build 阶段(HJ_BUILD_HASHTABLE,nodeHashjoin.c:271-433):先探测外表是否为空(318-330,省掉建表),`ExecHashTableCreate`(339)建表,再 `MultiExecProcNode` 拉 Hash 子节点把内表灌进去(348)。probe 阶段(HJ_NEED_NEW_OUTER,435-534):取外元组算哈希,`ExecHashGetBucketAndBatch`(497-498,nodeHash.c:1986)定位桶和批;若该元组属于后续批,直接写进外表批文件往后"扔"(507-529,`ExecHashJoinSaveTuple`)。命中后 `HJ_SCAN_BUCKET`(536-623)逐桶对撞,joinqual 过 `ExecQual`(580),otherqual 再过一遍(616)才 `ExecProject` 返回——joinqual 决定"是否匹配"(影响外连接补 NULL),otherqual 只决定"是否输出",这是三个 join 节点共用的语义约定。

### 3.2 批溢出:batchno、翻倍与多轮

批数 `nbatch` 恒为 2 的幂,"增长即翻倍"(nodeHashjoin.c:35-36 头注释)。计划期按统计信息估一版,执行期实测超预算再涨(nodeHashjoin.c:32-33)。内存预算来自 `ExecChooseHashTableSize`(nodeHash.c:683-880):`hash_table_bytes = get_hash_memory_limit()`(717,即 hash_mem 语义),并行时尝试所有参与者预算相加(724-732),桶数按 NTUP_PER_BUCKET 负载因子取 2 的幂(798-807)。`ExecHashIncreaseNumBatches`(nodeHash.c:1055)执行期把老批重新分区;若某批重分区后元组"全留或全走"(skew 挫败),全局关闭增长(nodeHashjoin.c:50-56 头注释,"best effort")。`HJ_NEED_NEW_BATCH`(770-786)调 `ExecHashJoinNewBatch`(1278-1413):跳过双侧皆空的批(1335-1360,带三条外连接例外规则),`ExecHashTableReset`(1370)清桶、重灌内批文件(1381-1391)。批文件是惰性创建的 BufFile,记在 `spillCxt` 里以便记账(nodeHashjoin.c:1570-1602,尤其 1592 注释"更好的统计溢出内存")。

### 3.3 并行 Hash(简)

并行版是 PG 12 的"shared hash table":所有 worker 共建一张表。三个 Barrier(build_barrier、grow_batches_barrier、grow_buckets_barrier)在 nodeHashjoin.c:85-135 头注释里列全了相位(如 PHJ_BUILD_ELECT→ALLOCATE→HASH_INNER→RUN);哪个 worker 先到谁建表(336-338 注释),批选择用原子计数器分布式轮转(1450-1452 `pg_atomic_fetch_add_u32(&pstate->distributor, 1) % nbatch`),防死锁的规则是"绝不挂在可能等不到人的 barrier 上"(146-158)。每个批自己的 barrier 相位机(ELECT→ALLOCATE→LOAD→PROBE→SCAN→FREE,nodeHashjoin.c:130-135)在 `ExecParallelHashJoinNewBatch` 中被 switch 直接消费:

```c
		switch (BarrierAttach(batch_barrier))
		{
			case PHJ_BATCH_ELECT:
				/* One backend allocates the hash table. */
				if (BarrierArriveAndWait(batch_barrier,
										 WAIT_EVENT_HASH_BATCH_ELECT))
					ExecParallelHashTableAlloc(hashtable, batchno);
				pg_fallthrough;
			case PHJ_BATCH_ALLOCATE:
				/* Wait for allocation to complete. */
				BarrierArriveAndWait(batch_barrier,
									 WAIT_EVENT_HASH_BATCH_ALLOCATE);
				pg_fallthrough;
			case PHJ_BATCH_LOAD:
				...
```

(nodeHashjoin.c:1465-1498,节选;LOAD 阶段所有参与者用 `sts_parallel_scan_next` 并行分装内批元组,PROBE 阶段返回主状态机。)晚到者按 `BarrierAttach` 返回的当前相位跳进对应分支(78-83 注释"figure out how much progress has already been made")。DSM 侧注册在 `ExecHashJoinInitializeDSM`(1849-1899)与 `ExecHashJoinInitializeWorker`(1960-1977),并用 `ExecSetExecProcNode` 把执行函数热换成 `ExecParallelHashJoin`(1863)——这是 §2 函数指针分发体系的直接红利:同一节点、两种执行形态,只换一个指针。

## 4. 表达式求值专节:EEOP 虚拟机

### 4.1 编译:表达式树 → 步骤数组

`execExpr.c` 头注释(6-15 行)就是设计说明书:表达式树在执行器启动时被"编译"成 `ExprState->steps[]`——扁平的 `ExprEvalStep` 数组,"可以看作一条程序的指令"。入口 `ExecInitExpr`(execExpr.c:143)递归走 `ExecInitExprRec`(execExpr.c:919-2874),一个 Expr 节点展开成 0..n 条步骤;`"a+b"` 展开成两条 Var 装载 + 一条函数调用,Var 结果的 `resvalue/resnull` 直接指向函数调用的 `fcinfo->args[]`,免拷贝(README:127-133)。首步统一是 `EEOP_*_FETCHSOME`,把元组列一次性 deform 出来,让每条 Var 步骤退化成数组下标(README:142-147)。

操作码全集 `enum ExprEvalOp` 在 src/include/executor/execExpr.h:66-296,到 `EEOP_LAST`(296)共约 120 个,按族摘要:

- DONE(2):`EEOP_DONE_RETURN/NO_RETURN`(69/72,尾步免判数组末);
- 取列:FETCHSOME×5(75-79)、VAR×5(82-86)、SYSVAR×5(89-93)、WHOLEROW(96);
- 投影:ASSIGN_*_VAR×5(103-107,一步完成取+赋)、ASSIGN_TMP(110);
- 函数:FUNCEXPR 六连(122-127,按 strict/参数个数/FUSAGE 特化);
- 布尔与控制流:BOOL_AND/OR/NOT 步(135 起,短路即 JUMP)、QUAL、JUMP 系(4 种)、NULLTEST/BOOLTEST 系、PARAM 系、CASE/DISTINCT/NULLIF、ARRAY/ROW/FIELD/SBSREF(下标)、DOMAIN、CONVERT;
- 聚合:AGG_SPLIT/AGG_TRANS 系(nodeAgg 的转移函数也被编译进来,见下)。

布尔短路的"跳过若干步"在扁平数组里就是 `jumpskip` 索引回填(README:175-186,adjust_jumps)。

### 4.2 解释:computed-goto 直通线程

`ExecReadyExpr`(execExpr.c:902-908)是执行方式选择点:先问 `jit_compile_expr`(904),失败再 `ExecReadyInterpretedExpr`(907)。解释器 `ExecInterpExpr`(execExprInterp.c:470-…)有两条派发路径(6-33 头注释):gcc/clang 走 **direct threading**——Init 时把每个 opcode 直接替换成代码块地址(execExprInterp.c:440-454,置 `EEO_FLAG_DIRECT_THREADED`),运行期 `goto *((void *) op->opcode)`(121);否则退回 switch 单点派发(126-129)。宏一览在 104-143:

```c
#if defined(EEO_USE_COMPUTED_GOTO)
#define EEO_CASE(name)		CASE_##name:
#define EEO_DISPATCH()		goto *((void *) op->opcode)
...
#else
#define EEO_SWITCH()		starteval: switch ((ExprEvalOp) op->opcode)
#define EEO_CASE(name)		case name:
#endif

#define EEO_NEXT()  do { op++; EEO_DISPATCH(); } while (0)
#define EEO_JUMP(stepno) do { op = &state->steps[stepno]; EEO_DISPATCH(); } while (0)
```

派发表 `dispatch_table`(484 起,注释强调"必须与 enum 同序")+ `reverse_dispatch_table`(117)供 EXPLAIN 反查。极简表达式连解释器启动都省:约 20 个 `ExecJust*` 快路径(execExprInterp.c:158-178,如"扫描列→投影"一步到位;头注释 35-38:"very simple instructions 的解释器启动开销仍可察觉")。另有细节值得一提:`ExecReadyInterpretedExpr`(252)首次执行时把 `evalfunc` 指到带合法性检查的 `ExecInterpExprStillValid`(276),只有 slot 形状确认未变才走直通快路;多态操作符(如任意类型的 `=`)编译期就特化到具体 opcode 分支,这正是"把复杂度留在 Init、把速度留给 Exec"的体现(README:101-113)。

与 SQLite VDBE 对照:VDBE 的 opcode 是**语句级**字节码(整个 SELECT 编译成一段程序,含 Btree 游标操作);PG 的 EEOP 是**表达式级**虚拟机(只虚拟"一行内的求值",元组流动仍由 volcano 节点函数承担)——所以 PG 能把整个聚合转移表达式(含参数求值)拼成一段步骤再整体 JIT(nodeAgg.c:229-238 注释,构造在 execExpr.c:3670 `ExecBuildAggTrans`),也能按调用点拼装哈希表达式 `ExecBuildHash32Expr`(execExpr.c:4295)与投影 `ExecBuildProjectionInfo`(execExpr.c:370)。qual 的编译是独立入口 `ExecInitQual`(execExpr.c:229),生成以 `EEOP_QUAL` 收尾的短路步骤链;带外部参数的表达式走 `ExecInitExprWithParams`(execExpr.c:180);跨槽引用的统一预处理在 `ExecCreateExprSetupSteps`(execExpr.c:2875,把 FETCHSOME 步集中前置)。

### 4.3 LLVM JIT:何时触发

JIT 决策在规划器收尾:planner.c:699-721——计划总代价 > `jit_above_cost` 才置 `PGJIT_PERFORM`,> `jit_optimize_above_cost` 加 `PGJIT_OPT3`,> `jit_inline_above_cost` 加 `PGJIT_INLINE`(内联 PG 自身 C 函数),再按 `jit_expressions`/`jit_tuple_deforming` 决定编译对象。默认值:`jit_above_cost=100000`、两个 500000(jit.c:40-42);本树(8c7a74c)中 `jit` 的 boot_val 为 `false`(src/backend/utils/misc/guc_parameters.dat:1453-1456),即默认关。运行期选择点就是 `jit_compile_expr`(jit.c:152-179):无 PlanState 不编(163)、缺 `PGJIT_PERFORM/PGJIT_EXPR` 不编(167/171),然后惰性加载 provider(jit.c:67-121,失败不重试)。Provider 是可插拔的(唯一内置实现 `src/backend/jit/llvm/`),编译产物含表达式函数与元组 deform 函数;`EXPLAIN ANALYZE` 会把 generation/emission 计时汇总展示(jit.c:183-191 `InstrJitAgg`)。

## 5. 并行专节:Gather 起步的并行查询

### 5.1 框架:DSM 一段、序列化计划、共享仪表

`execParallel.c` 定义了 DSM 布局:`PARALLEL_KEY_EXECUTOR_FIXED/PLANNEDSTMT/PARAMLISTINFO/TUPLE_QUEUE/INSTRUMENTATION/DSA/QUERY_TEXT` 等(execParallel.c:60-69),定长头部 `FixedParallelExecutorState` 只装 tuple bound、eflags、jit_flags(76-82)。`ExecInitParallelPlan`(652-700)三步:序列化计划(696,`ExecSerializePlan` 151-159)、`CreateParallelContext("postgres","ParallelQueryMain", nworkers)`(699)、预估算各 chunk 大小(709-749)。元组回传用每 worker 一条 64KB shm_mq(71,`PARALLEL_TUPLE_QUEUE_SIZE`),`ExecParallelSetupTupleQueues`(601-641)建好;仪表 `SharedExecutorInstrumentation` 按"节点数 × worker 数"排布共享数组(100-115)。

### 5.2 Gather:leader 也是半个 worker

`nodeGather.c` 头注释(9-23)说得直白:Gather 启动 worker 跑多份计划副本,自己也能参与跑,再把多路结果合成一路——前提是计划"并行感知"(如并行 SeqScan 不重复产出行)。关键代码:`ExecGather`(138-216)把**启动 worker 拖迟到首次 Exec**(146-151 注释:DSM 分配大,能省则省),`LaunchParallelWorkers`(182)拿多少算多少,一个没拿到就全本地跑(212-214);`gather_getnext`(263-305)在"读 worker 队列"与"本地跑计划"间轮转,worker 队列全空且本地还有活时返回 NULL 让上层再来;`gather_readnext`(311-391)对 reader **非阻塞轮询**,轮完一圈没结果且不能本地干活时 `WaitLatch` 睡眠等事件(385)。排序版 `GatherMerge` 用二叉堆归并保序:为每个 reader(含 leader 自己)建一个堆项(nodeGatherMerge.c:427 `binaryheap_allocate(nreaders + 1, …)`),按排序键比较取最小者输出,再 `binaryheap_replace_first` 补位(564-567)——本质是多路归并,代价是必须等各路头部齐了才能吐第一条(启动延迟)。

### 5.3 并行 scan:chunk 协作

并行 Seqscan 的 DSM 侧四件套(nodeSeqscan.c:23-26):`ExecSeqScanEstimate`(373)、`ExecSeqScanInitializeDSM`(391,`table_parallelscan_initialize` 建共享扫描描述符)、`ReInitializeDSM`(421)、`InitializeWorker`(437,`table_beginscan_parallel` 挂到共享游标)。块分配在表 AM(src/backend/access/table/tableam.c):把全表切成至多 2048 个 chunk(42),chunk 大小 = 表块数/2048 向上取 2 的幂、上限 8192 块(521-531);worker 用 64 位 `fetch-add` 原子计数器 `phs_nallocated` 领块(577-590 注释解释为何要 64 位防回绕),同一 chunk 内发**连续块号**给同一 worker 以保住 OS readahead(552-564);收尾时 chunk 减半的 ramp-down(44,615-624)让尾部负载均衡。这与 K8s informer 的"每个 informer 拉全量列表再 diff"不同:并行 scan 是**协作消费**同一逻辑流,工作切分由共享计数器完成,而非每副本独立拉取。

### 5.4 为什么默认不全并行

并行是纯优化而非必选:计划器只在 `max_parallel_workers_per_gather > 0`(planner.c:417)且路径允许时生成部分并行计划;运行期 `es_use_parallel_mode` 还要打开(execMain.c:1761),worker 可能一个都拿不到(nodeGather.c:177-180 注释"We might not get as many as we requested")。代价三笔:worker 启动/DSM 序列化是固定开销(小查询纯亏)、并行下 buffer pin 与快照语义要额外协调、leader 参与还要占 `parallel_leader_participation`(planner.c:70,默认 true)。所以默认策略是"代价模型确认划算才并行",而不是无条件铺开。

## 6. 内存上下文专节:每 tuple 的 reset 策略

内存上下文的骨架在 src/include/nodes/memnodes.h:117-134:`MemoryContextData` 含 `isReset`(123)、`mem_allocated`(125)、虚函数表 `methods`(126)与父子链(127-130)。每个 `ExprContext` 挂两个上下文:`ecxt_per_query_memory`(查询生命周期)与 `ecxt_per_tuple_memory`(AllocSet,execUtils.c:242-296,创建于 263-268),后者才是主角——

```c
#define ResetExprContext(econtext) \
	MemoryContextReset((econtext)->ecxt_per_tuple_memory)
```

(src/include/executor/executor.h:659-660;`MemoryContextReset` 在 mcxt.c:406,AllocSet 实现在 aset.c:546 `AllocSetReset`——只回收大块、保留 keeper 块,O(1) 摊销,和 llama.cpp 的 arena"一锅端"同思想但支持部分保留。)

执行协议是:每处理一条元组前先 `ResetExprContext` 把上一条产生的临时量清零——三个 join 节点开头都有一模一样的一句(nodeHashjoin.c:250-254,nodeNestloop.c:87-90,nodeMergejoin.c:562-566),ExecScanExtended 在取元组前 reset(execScan.h:186),顶层 `ExecutePlan` 每轮拉取前 reset 每输出元组上下文(execMain.c:1770-1771)。查询级清理则靠"销毁上下文"而非逐个 pfree:README:270-287 明说"不是零售 pfree,而是整个 context destroy"(FreeExecutorState 阶段)。三态语义:

| 态 | 入口 | 典型节奏 | 例子 |
|---|---|---|---|
| normal | `ResetExprContext` | 每元组 | join 节点每行开头(executor.h:659) |
| restart | `ReScanExprContext`(executor.h:657) | 分组/批边界 | hash agg 每批重置 hashcontext(nodeAgg.c:2711) |
| clean | `FreeExprContext` / `MemoryContextDelete`(executor.h:656;mcxt.c:475) | 查询结束 | `FreeExecutorState` 连带销毁 es_exprcontexts 链(execUtils.c:211-213) |

nodeAgg 把这个思想推到极致:每个 grouping set 一个 ExprContext、所有哈希表共用一个 `hashcontext`(nodeAgg.c:180-195),滚动 group 边界时只 reset 内层上下文而不影响外层聚合——上下文层级本身就是算法结构。

## 7. 与前作对照

| 维度 | SQLite VDBE(02 卷) | PG EEOP(本章) |
|---|---|---|
| 虚拟对象 | 整条 SELECT 的字节码程序 | 单个表达式(qual/投影/转移函数)的步骤数组 |
| 编译时机 | 语句 prepare 时一次编译 | `ExecInitExpr` 时编译(execExpr.c:143),计划可缓存 |
| 派发 | 单点 `switch(op)` 循环 | 函数指针(节点)+ computed-goto(表达式),execExprInterp.c:121 |
| 可 JIT | 否(有版本实验性扩展) | 是,同一份 steps 数组喂给 LLVM(execExpr.c:902-908 二选一) |
| 游标/元组流 | VDBE opcode 内嵌 Btree 游标指令 | volcano 节点函数自管,EEOP 不管行流 |

K8s informer(前作)的"拉"是** ReplicaSet 级别的全量 List-Watch**:每个 informer 独立拉全量再 diff,拉取粒度粗、重复度高;PG 执行器的"拉"是**元组级拉取**,且共享 buffer pool 与快照,拉取即背压。两者共同点:拉模型都把"要不要数据"的决定权交给消费者;差异在于 informer 靠 etcd 版本号对账,PG 靠 `chgParam`/`ReScan` 协议对账(executor.h:324-325)。

## 8. 设计动机

1. **Volcano 活 30 年的原因**:可控的代价模型(Limit/参数化/提前终止天然表达)、可插拔节点(EXPLAIN、hook、FDW、自定义 scan 都只需挂节点)、以及"框架开销"这个敌人早已被三个武器围剿:每节点四变体的常量折叠(nodeSeqscan.c:119-215)、EEOP 扁平化(execExpr.c:6-15)、按需 JIT。慢路径罕见,热点已各自击破。
2. **JIT 的边界**:收益 = 每行表达式开销 × 行数 − 编译延迟(几十 ms 起步)。`jit_above_cost=100000` 的量级就是"确认要跑很久";本树默认 `jit=off`(guc_parameters.dat:1453-1456)是对短查询 OLTP 场景的清醒表态。JIT 只编译表达式与 deform,不碰执行器框架——框架若想被 JIT,得先变成数据(步骤数组),这是 EEOP 设计的真正回报。
3. **并行为什么从 Gather 开始**:Gather 是唯一的"合流"点,worker 池、DSM、tuple queue 都可以在这一层收口,下层节点各自声明 `Estimate/InitializeDSM/InitializeWorker` 三件套(nodeSeqscan.c:373-452 即完整样例)即可参与;不感知并行的节点用"每 worker 一份独立副本"兜底(nodeHashjoin.c:60-68)。增量演进而非推倒重来,与 PG 一贯的"先搭骨架再补肉"一致。
4. **只读计划树的隐藏回报**:计划树可序列化、可缓存、可跨进程共享——并行查询把 `PlannedStmt` 序列化进 DSM 一次、全员反序列化(execParallel.c:151-159),预编译计划(PL/pgSQL、prepare)可反复 Init 出新状态树;这三件事都得益于"Plan 只读、状态另存"(README:47-59)。可以说 volcano 在 PG 里早已不只是执行模型,而是整个运行期扩展性的接口层。

## 9. FAQ 素材

1. **Q: ExecProcNode 里没有 switch,那"分发"发生在哪?** A: 每个 PlanState 的函数指针,Init 时包装(execProcnode.c:391,429-440),首跳自替换(execProcnode.c:448-470)。
2. **Q: Hash 节点为什么不走 ExecProcNode?** A: 它不产元组,产哈希表,走 `MultiExecProcNode`(execProcnode.c:487-528),由 HashJoin 在 build 阶段主动调用(nodeHashjoin.c:348)。
3. **Q: nbatch 增长会失败吗?** A: 会。skew 导致某批"全留或全走"时全局禁增,宁可超内存(nodeHashjoin.c:50-56)。
4. **Q: MergeJoin 的 mark/restore 是什么?** A: 内表游标打标记,外表重复键时回滚重放;`MarkInnerTuple`(nodeMergejoin.c:153)拷贝到 `mj_MarkedTupleSlot`,`ExecRestrPos` 回滚(995);inner 子节点必须支持 EXEC_FLAG_MARK(1381-1384)。
5. **Q: NestLoop 怎么把外表值传给内表索引?** A: `nestParams` 写入 PARAM_EXEC 并给内子节点标 `chgParam`,随即 `ExecReScan(innerPlan)`(nodeNestloop.c:120-142)。
6. **Q: hash agg 溢出后还能继续吗?** A: 能。溢出的元组按分区写 logical tape,之后批从"批次栈"弹出递归处理(nodeAgg.c:2681-2742,2692 注释"batch list is a stack")。
7. **Q: 并行聚合怎么合并?** A: 部分聚合用 combinefn 替代 transfn(`DO_AGGSPLIT_COMBINE`,nodeAgg.c:3939-3950),INTERNAL 状态类型的 combinefn 不得 STRICT(3992-4000)。
8. **Q: 表达式 JIT 和解释器怎么选?** A: 同一份 steps 数组,`ExecReadyExpr` 先试 JIT(execExpr.c:904),失败即解释器;代价阈值由规划器判定(planner.c:699-702)。
9. **Q: 并行 worker 拿不到怎么办?** A: `need_to_scan_locally` 兜底,leader 自己跑计划(nodeGather.c:212-214,287-301)。
10. **Q: 每 tuple reset 会不会很贵?** A: AllocSet 的 reset 只回收非 keeper 块(aset.c:546),摊销 O(1);这正是"上下文 vs 零售 pfree"的意义(README:270-287)。

## 10. 深挖方向

1. **EvalPlanQual**:READ COMMITTED 下并发更新后的重检机制,把整棵计划"换数据重跑"——README:355-410,nodeSeqscan.c 的 `es_epq_active` 分支(execScan.h:61-129)。
2. **Memoize 节点**(nodeMemoize.c):嵌套循环下对重复参数键缓存内表结果,PG 14 引入,可与 NestLoop 参数化(§9-5)连读。
3. **TupleTableSlot 的四套 ops**(TTSOpsVirtual/Minimal/Heap/BufferHeap):slot 抽象如何让 JIT deform 与 table AM 解耦(execTuples.c,execExpr.c:3056 `ExecComputeSlotInfo`)。
4. **异步执行**:Append + 异步 ForeignScan 的事件循环(README:412-449,execAsync.c)——拉模型的另一条支线。
5. **IncrementalSort / GatherMerge 的归并堆**:有序性在拉模型中的逐层传递(nodeGatherMerge.c:184 起)。

## 11. 写作要点速查表

| # | 事实 | 位置 |
|---|---|---|
| 1 | 拉模型定义:"demand-pull pipeline" | src/backend/executor/README:6-11 |
| 2 | `ExecProcNode` 内联分发(chgParam→ReScan) | src/include/executor/executor.h:321-328 |
| 3 | `ExecProcNodeFirst` 一次性栈检查+换指针 | src/backend/executor/execProcnode.c:448-470 |
| 4 | `ExecInitNode` 大 switch(计划→状态树) | execProcnode.c:141-420(包装在 391) |
| 5 | SeqNext 惰性 beginscan + getnextslot | src/backend/executor/nodeSeqscan.c:52-93 |
| 6 | HashJoin 8 状态枚举 | nodeHashjoin.c:182-189(实现 224-793) |
| 7 | 外元组跨批→写批文件 | nodeHashjoin.c:507-529;SaveTuple 1570-1602 |
| 8 | 批数恒 2 的幂、增长即翻倍 | nodeHashjoin.c:35-36;IncreaseNumBatches nodeHash.c:1055 |
| 9 | MergeJoin 11 状态 + mark/restore | nodeMergejoin.c:107-117,153,995,1106 |
| 10 | NestLoop 参数化内表(nestParams+ReScan) | nodeNestloop.c:120-142 |
| 11 | hash agg 溢出:check_limits/spill/refill | nodeAgg.c:1864,1908,2681(批次栈 2692) |
| 12 | combinefn 替换 transfn 的并行语义 | nodeAgg.c:3939-3950;ExecBuildAggTrans execExpr.c:3670 |
| 13 | EEOP 枚举(约 120 个操作码) | src/include/executor/execExpr.h:66-296 |
| 14 | computed-goto 派发 `goto *op->opcode` | src/backend/executor/execExprInterp.c:104-143,484 |
| 15 | JIT 选择点:ExecReadyExpr 先 JIT 后解释 | execExpr.c:902-908;jit.c:152-179 |
| 16 | jit_above_cost 三档阈值决策 | src/backend/optimizer/plan/planner.c:699-721;jit.c:40-42 |
| 17 | Gather 惰性启 worker + 轮询 reader | nodeGather.c:138-216,263-305(WaitLatch 385) |
| 18 | 并行 scan chunk:2048 块粒度/64 位原子领块 | src/backend/access/table/tableam.c:42-46,521-531,543-624 |
| 19 | ExprContext 双上下文(per_query/per_tuple) | src/backend/executor/execUtils.c:242-296 |
| 20 | ResetExprContext = MemoryContextReset | src/include/executor/executor.h:659-660;aset.c:546 |
