# Q - 并行查询框架：进程 + DSM 的并行哲学

> 源码版本：PostgreSQL master 分支，commit `8c7a74c`（shallow clone）。
> 本文所有 `文件:行号` 均以该 commit 实际 grep/Read 核对。
> 前置：卷二 08 章执行器提过 Gather 节点，本章展开并行框架本体。

---

## 1. 全景：一次并行查询的完整生命周期

PG 没有线程，worker 是完整的一号进程（backend）。并行 = leader 进程 fork 出 N 个
worker 进程，通过**动态共享内存（DSM）**传递计划/快照，worker 各自跑一份计划子树，
把元组写回共享内存环形队列（shm_mq），leader 用 Gather 节点汇聚。

```
 leader backend (并行组组长, lock group leader)
 |
 Gather (num_workers=2)                      nodeGather.c:53 ExecInitGather
 |  首次 ExecProcNode 时才真正启动 worker     nodeGather.c:152-216
 |-- ExecInitParallelPlan(序列化计划+建DSM)   execParallel.c:651
 |-- LaunchParallelWorkers (bgworker)         parallel.c:577
 |
 |== DSM 段（本次查询生命周期）====================================
 |  [FixedParallelState] 用户/数据库/快照时间戳   parallel.c:83-105
 |  [PlannedStmt 序列化串]                       execParallel.c:819-822
 |  [GUC/库/事务状态/快照] 各 worker 恢复用       parallel.c:380-451
 |  [ParallelBlockTableScanDesc] 共享扫描游标      tableam.c:414-429
 |  [tuple queue x N] 每个 worker 64KB            execParallel.c:71,600-645
 |  [error queue x N]  每个 worker 16KB           parallel.c:56,463-477
 |  [DSA area] 共享分配器(parallel hash 用)       execParallel.c:887-895
 |==================================================
 |            |              |
 |        worker 0        worker 1        (还有 leader 自己,可选)
 |            |              |
 |      Parallel Seq Scan  Parallel Seq Scan   <- 各自的 TableScanDesc
 |      但共享一个 POS:    原子领取 block chunk  tableam.c:543 nextpage
 |            |              |
 |        worker 0        worker 1        (还有 leader 自己,可选)
 |      [shm_mq]----写元组--[shm_mq]
 |            \             /
 |          TupleQueueReader 轮询读取
 |          (round-robin)                    nodeGather.c:310 gather_readnext
 |
 结果集 ---> 客户端
```

worker 数量的三个闸门（全部默认收紧）：

- `max_worker_processes`（默认 8，重启级）——整个实例 bgworker 槽位总数，`guc_parameters.dat:2211`
- `max_parallel_workers`（默认 8）——并行 worker 并发上限，`guc_parameters.dat:2070`
- `max_parallel_workers_per_gather`（默认 2）——单个 Gather 节点的 worker 上限，`guc_parameters.dat:2079`

 planner 侧按表大小以 **3 倍对数** 递增建议 worker 数（`allpaths.c:4963` compute_parallel_worker，
表 ≥ `min_parallel_table_scan_size` 默认 8MB 才考虑并行，`guc_parameters.dat:2253`）。

---

## 2. DSM 专节：共享内存段里到底放了什么

### 2.1 两层布局：框架层 + 执行器层

DSM 段不是裸内存，而是用 `shm_toc`（table of contents）做 key→offset 索引的
"小文件系统"。key 分两层：

**框架层 key**（`parallel.c:66-80`，接近 0xFFFF... 的保留段）：

```c
#define PARALLEL_KEY_FIXED					UINT64CONST(0xFFFFFFFFFFFF0001)
#define PARALLEL_KEY_ERROR_QUEUE			UINT64CONST(0xFFFFFFFFFFFF0002)
#define PARALLEL_KEY_LIBRARY				UINT64CONST(0xFFFFFFFFFFFF0003)
#define PARALLEL_KEY_GUC					UINT64CONST(0xFFFFFFFFFFFF0004)
...
#define PARALLEL_KEY_ENTRYPOINT				UINT64CONST(0xFFFFFFFFFFFF0009)
```

**执行器层 key**（`execParallel.c:60-69`，0xE000... 段）：

```c
#define PARALLEL_KEY_EXECUTOR_FIXED		UINT64CONST(0xE000000000000001)
#define PARALLEL_KEY_PLANNEDSTMT		UINT64CONST(0xE000000000000002)
#define PARALLEL_KEY_PARAMLISTINFO		UINT64CONST(0xE000000000000003)
#define PARALLEL_KEY_BUFFER_USAGE		UINT64CONST(0xE000000000000004)
#define PARALLEL_KEY_TUPLE_QUEUE		UINT64CONST(0xE000000000000005)
...
#define PARALLEL_KEY_DSA				UINT64CONST(0xE000000000000007)
```

### 2.2 InitializeParallelDSM：估算 → 创建 → 填充

三步走的教科书式流程（`parallel.c:208-499`）：

1. **估算**：各子系统报尺寸 `shm_toc_estimate_chunk/keys`（`parallel.c:234-311`）——
   库状态、GUC、combo CID、事务快照、活动快照、事务状态、pending syncs、
   relmapper、未提交枚举、客户端连接信息共 12 个 chunk + 错误队列 16KB x N + 入口点。
2. **创建**：`dsm_create`（`parallel.c:326`）；若 DSM 段数达上限则**优雅降级**——
   `nworkers=0`，整段退回后端私有内存（`parallel.c:331-337`），查询仍可跑，只是不并行。
3. **填充**：FixedParallelState 记录数据库 OID、四类用户 ID、leader 的 PGPROC/pid、
   事务/语句时间戳、`last_xlog_end`（原子 u64，worker 上报 WAL 写入位置用于
   正确 commit 时机，`parallel.c:339-358`）。

`FixedParallelState` 全文（`parallel.c:83-105`）——这就是"把一个 backend 的身份
压缩进 100 来字节"：

```c
typedef struct FixedParallelState
{
	Oid			database_id;
	Oid			authenticated_user_id;
	Oid			session_user_id;
	Oid			outer_user_id;
	Oid			current_user_id;
	...
	PGPROC	   *parallel_leader_pgproc;
	pid_t		parallel_leader_pid;
	TimestampTz xact_ts;
	TimestampTz stmt_ts;
	/* Maximum XactLastRecEnd of any worker. */
	pg_atomic_uint64 last_xlog_end;
} FixedParallelState;
```

**关键设计：不传函数指针**。入口点是"库名+函数名"字符串（`parallel.c:486-491`），
worker 侧 `LookupParallelWorkerFunction` 查内部表（ParallelQueryMain、并行建索引等 5 个，
`parallel.c:134-156`）或 `load_external_function` 动态加载（`parallel.c:1643-1665`）。
原因是 EXEC_BACKEND 平台（Windows）各进程加载地址不同（`parallel.c:1632-1637` 注释）。

### 2.3 执行器追加的段（ExecInitParallelPlan）

`execParallel.c:651-934` 在框架层之上再塞进去：序列化的 PlannedStmt（819-822）、
查询文本（815-817）、ParamListInfo（825-827）、每 worker 一份的 BufferUsage/WalUsage
统计槽（830-839）、64KB x N 元组队列（841-843）、EXPLAIN ANALYZE 的
instrumentation 矩阵（num_plan_nodes × num_workers，857-867）、以及一个
**DSA 共享分配区**（887-895）——parallel hash join 的共享哈希表就建在 DSA 里，
因为它的尺寸运行时才知道，不能预留在 DSM 布局里。

序列化计划时有个隐蔽手术：`ExecSerializePlan` 把 targetlist 的 resjunk 列强制
清零（`execParallel.c:169-174`），否则 worker 侧执行器会插 junk filter，
把 leader 还需要的列丢掉；同时**只传 parallel-safe 的子计划**，unsafe 位置留 NULL
洞以保持下标对齐（`execParallel.c:206-214`）。

---

## 3. Worker 专节：启动、状态恢复、错误传播

### 3.1 启动：就是 bgworker

`LaunchParallelWorkers`（`parallel.c:577-662`）逐个注册 bgworker：

```c
	worker.bgw_flags =
		BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION
		| BGWORKER_CLASS_PARALLEL;
	worker.bgw_start_time = BgWorkerStart_ConsistentState;
	worker.bgw_restart_time = BGW_NEVER_RESTART;
	sprintf(worker.bgw_library_name, "postgres");
	sprintf(worker.bgw_function_name, "ParallelWorkerMain");
	worker.bgw_main_arg = UInt32GetDatum(dsm_segment_handle(pcxt->seg));
```
（`parallel.c:603-610`）

三个细节：`bgw_extra` 塞的是 worker 编号 i（`parallel.c:623`）——这是
`ParallelWorkerNumber` 的来源（`parallel.c:1333`），决定它用第几条错误队列/元组队列；
注册失败即撞上 `max_worker_processes`，后续直接跳过不再尝试（`parallel.c:634-647`）；
**worker 数可以少于请求数，查询照样正确**——调用方必须容忍（`parallel.c:613-620` 注释）。
启动前 leader 先 `BecomeLockGroupLeader()`（`parallel.c:590`），worker 侧对称地
`BecomeLockGroupMember`（`parallel.c:1398-1400`）——组锁机制保证"leader 等的锁
不会被子进程握着"，消灭组内假死锁。

### 3.2 ParallelWorkerMain：逐项"变成 leader"

worker 入口（`parallel.c:1297-1584`）按严格顺序恢复状态：attach DSM（1349）→
认领错误队列并 **重定向全部协议输出** `pq_redirect_to_shm_mq`（1375-1380，此后
 ereport 全部变成发往 leader 的消息）→ 加入锁组（1398）→ 恢复时间戳（1407）→
解析入口点（1414-1418）→ 免鉴权连库（1437-1440，`BGWORKER_BYPASS_ALLOWCONN`，
注释明确说这是为了让并行对应用透明）→ 恢复库/GUC/快照/用户（1457-1545）→
`EnterParallelMode()`（1563）→ 调真正的入口 `entrypt(seg, toc)`（1568）。
查询场景的 entrypt 即 `ParallelQueryMain`（`execParallel.c:1511-1614`）：
反序列化 PlannedStmt → ExecutorStart → ExecutorRun → 把统计写回 DSM。

### 3.3 错误传播：一个 worker 报错，全组失败

错误队列是每 worker 一条 16KB 的 shm_mq（`parallel.c:56`），worker 把
ErrorResponse/NoticeResponse 等**前端协议消息**原样写进队列
（README.parallel:39-46 描述了 PROCSIG_PARALLEL_MESSAGE 信号机制）。leader 侧
在 `CHECK_FOR_INTERRUPTS()` 时触发 `ProcessParallelMessages` 逐条消费
（`parallel.c:1053-1137`），`ProcessParallelMessage` 解析后重新抛出：

```c
			/* Death of a worker isn't enough justification for suicide. */
			edata.elevel = Min(edata.elevel, ERROR);
			...
				edata.context = psprintf("%s\n%s", edata.context,
										 _("parallel worker"));
			...
			ThrowErrorData(&edata);
```
（`parallel.c:1167-1196`）

所以：**任何 worker 抛 ERROR，leader 立即重抛同一错误**，事务进入 abort，
`AtEOXact_Parallel`（`parallel.c:1280-1292`）遍历销毁所有 ParallelContext，
`DestroyParallelContext` 逐个 `TerminateBackgroundWorker` 并等它们死透
（`parallel.c:968-1011`，`HOLD_INTERRUPTS` 保证提交/回滚前 worker 必须全退）。
这就是"一个 worker 报错 = 整条查询失败"的机制闭环。错误 context 会追加一行
"parallel worker" 方便定位（`parallel.c:1178-1185`）。

还有一个兜底：worker 退出钩子 `ParallelWorkerShutdown` 给 leader 发一次信号，
防止 worker 异常退出（没发错误消息）时 leader 死等（`parallel.c:1615-1623`）。

---

## 4. Scan 分发专节：块级 chunk 的原子领取

### 4.1 共享扫描描述符（Parallel "POS"）

并行 seq scan 没有中央调度器——只有一个挂在 DSM 里的原子计数器。
`ParallelBlockTableScanDescData`（`relscan.h:96-107`）：

```c
typedef struct ParallelBlockTableScanDescData
{
	ParallelTableScanDescData base;
	BlockNumber phs_nblocks;		/* # blocks in relation at start of scan */
	pg_atomic_uint32 phs_startblock;	/* starting block number */
	pg_atomic_uint32 phs_numblock;	/* # blocks to scan, or InvalidBlockNumber */
	pg_atomic_uint64 phs_nallocated;	/* blocks allocated to workers so far */
} ParallelBlockTableScanDescData;
```

接线流程（execParallel 的三次树遍历）：leader 估算空间 `ExecSeqScanEstimate`
（`nodeSeqscan.c:373-382`）→ 初始化 `ExecSeqScanInitializeDSM` 调
`table_parallelscan_initialize` 并把 pscan 按 plan_node_id 存进 toc
（`nodeSeqscan.c:391-413`）→ 每个 worker `ExecSeqScanInitializeWorker` 用
`table_beginscan_parallel` 挂上同一份 pscan（`nodeSeqscan.c:437-452`）。

### 4.2 chunk 领取：fetch-add + 本地 chunk 剩余计数

每次要下一个块时走 `table_block_parallelscan_nextpage`（`tableam.c:543-660`）。
新版本（对比旧行级分发）不再"每次原子加 1"，而是**一次 fetch-add 领一整段连续块**：

```c
		if (pbscanwork->phsw_chunk_remaining > 0)
		{
			/* 本地计数，无原子操作 */
			nallocated = ++pbscanwork->phsw_nallocated;
			pbscanwork->phsw_chunk_remaining--;
		}
		else
		{
			...
			nallocated = pbscanwork->phsw_nallocated =
				pg_atomic_fetch_add_u64(&pbscan->phs_nallocated,
										pbscanwork->phsw_chunk_size);
			pbscanwork->phsw_chunk_remaining = pbscanwork->phsw_chunk_size - 1;
		}
```
（`tableam.c:603-635`）

chunk 尺寸在扫描开始时定：全表分成约 2048 份取 2 的幂（`tableam.c:521-522`），
上限 8192 块（`tableam.c:530-531`）；常量 `PARALLEL_SEQSCAN_NCHUNKS=2048`、
`PARALLEL_SEQSCAN_RAMPDOWN_CHUNKS=64`、`PARALLEL_SEQSCAN_MAX_CHUNK_SIZE=8192`
（`tableam.c:42-46`）。剩余不足 64 个 chunk 时每轮**减半 ramp-down**（`tableam.c:622-625`），
让最后几个块摊到所有 worker、避免长尾。计数器必须 64 位：worker 会"越界加"
（都想领下一块但块已发完），32 位会回绕（`tableam.c:578-586` 注释）。

- 实际取块调用点：heap AM 的流式读回调 `heap_scan_stream_read_next_parallel`
  （`heapam.c:254-287`），首块时惰性 `startblock_init`（支持 synchronized seqscan
  起点协商，`tableam.c:489-503`）。
- 对照系列：这与 ffmpeg 的"任务队列切片"同一思想——**无锁工作窃取的简化版**；
  区别是 PG 的 chunk 粒度是 8KB 页的连续段（块级），且 ramp-down 是为 I/O 尾延迟
  特意设计的。worker 各自持有私有的 TableScanDesc，只共享这 40 来字节的游标。

---

## 5. Gather / GatherMerge：leader 的汇聚点

### 5.1 Gather：轮询 + 本地执行

`ExecGather` 首次调用时才初始化并行计划并发射 worker（`nodeGather.c:152-216`）——
注释明确说"DSM 段可能很大，确认真需要再分配"。之后 `gather_getnext`
（`nodeGather.c:262-305`）在"worker 队列"与"本地计划副本"间取元组；
`gather_readnext`（`nodeGather.c:310-391`）对存活 reader 做**轮询**：读不到就
换下一个 reader，一圈空转且 leader 不参与本地执行时才 WaitLatch 睡眠
（`nodeGather.c:369-388`）。同队列连续读（避免频繁切换）是实测出来的优化
（`nodeGather.c:362-368` 注释）。readerdone（worker 干完退出）时把 reader 从
数组摘除、归零即触发 ramp-down `ExecShutdownGatherWorkers`（`nodeGather.c:340-356`）。

**Leader participation**：`need_to_scan_locally = !single_copy &&
parallel_leader_participation`（`nodeGather.c:72-73, 212-214`）——leader 自己也
执行一份子计划、领自己那份 chunk，等于"白送一个 worker"。GUC
`parallel_leader_participation` 默认开（`guc_parameters.dat:2336`）。

### 5.2 GatherMerge：有序输出的堆归并

并行排序输出时用 GatherMerge：每个 worker 输出本身有序，leader 用**二叉堆做 K 路
归并**——`binaryheap` 以 reader 编号为元素（`nodeGatherMerge.c:427,513`），
每次弹出堆顶 reader 的元组，再从该 reader 补一个、`binaryheap_replace_first`
回堆（`nodeGatherMerge.c:564-571`）。每个 reader 还带一个小元组缓冲
`GMReaderTupleBuffer` 摊平队列抖动。这就是"并行 Sort = N 路局部排序 + leader 归并"
的全部实现。

### 5.3 为什么 Gather 是"屏障"

Gather 是并行子树与外层串行世界的**唯一边界**：外层节点（Sort/Agg/Hash 的串行版）
只通过 Gather 拿元组，完全不感知 worker 存在。 therefore：

- 查询结束/早停（Limit tuple bound 下传 `ExecSetTupleBound`，`execProcnode.c:829`）
  时，`ExecShutdownNode` 树遍历到 Gather/GatherMerge 调 `ExecShutdownGather`
  （`execProcnode.c:783-793`），在这里统一等 worker 收工、聚合 BufferUsage
  （`execParallel.c:1252-1260`）。
- 真正的多方屏障（所有人等所有人）只在 parallel hash join 内部用 `Barrier`
  原语实现（`barrier.h:25-36`：phase 计数 + condition variable）；Gather 本身
  不需要屏障——它只是多生产者单消费者的汇聚。

---

## 6. 并行 Join 与并行 Agg（简）

**Parallel Hash Join**（`nodeHashjoin.c:58-158` 的大注释是最佳读物）：共享哈希表
建在 DSA 上（`ParallelHashJoinState`，`hashjoin.h:257-277`），用四个 Barrier
编排阶段机：build_barrier 走
`PHJ_BUILD_ELECT → ALLOCATE* → HASH_INNER → (HASH_OUTER) → RUN → FREE*`
（`hashjoin.h:280-284`，带 `*` 的阶段由"当选"的单一进程执行）——ELECT 阶段
各进程抢一个原子 distributor 决定谁建表，其余人 `BarrierArriveAndWait`
（`nodeHashjoin.c:370-373`）。probe 阶段每个 batch 一把 batch_barrier，
参与者领 batch 干活、不够就"抱团"共扫同一 batch。所有人共享 `hash_mem`
建**一张**大表（`nodeHashjoin.c:141-144`），这是并行 hash 相对每进程各建
一张表的并行无关（parallel-oblivious）hash 的核心收益。

**Parallel Agg**：两阶段聚合。worker 侧 `AGGSPLIT_INITIAL_SERIAL`
（跳过 finalfn + 序列化 state，`nodes.h:381`）产出部分态，经 Gather 传回，
leader 侧 `AGGSPLIT_FINAL_DESERIAL`（combinefunc + 反序列化，`nodes.h:383`）
合并出最终值。HashAgg 还有共享哈希版（Partial HashAgg 各 worker 插同一张
DSA 哈希表）。每个节点的每 worker 统计也经 DSM 回传
（如 `ExecAggInitializeDSM`，`nodeAgg.c:4795-4812`）。

---

## 7. parallel_safe 判定：为什么你的函数挡住了并行

三级标记存在 `pg_proc.proparallel`：`s`afe / `r`estricted / `u`nsafe。
优化器在 `max_parallel_hazard`（`clauses.c:812-821`）对整棵 parse tree 求最差
级别并缓存到 PlannerGlobal；单条表达式用 `is_parallel_safe`（`clauses.c:831-868`）
复查——全库皆 safe 且无 PARAM_EXEC 时直接短路返回 true（843-845）。
`max_parallel_hazard_test`（`clauses.c:872-896`）实现升级规则：遇 unsafe 立即
判死，遇 restricted 记录但不致命。restricted 的含义是"在 worker 里跑结果
可能不同"（如依赖 sequence 状态、临时表），unsafe 是"根本不能并发跑"（有副作用）。
查函数标记的入口是 `func_parallel`（`lsyscache.c:2111-2125`），读的正是
proparallel 字段。

其它常见拦路虎：写操作/DDL（并行模式强制只读，README.parallel:84-86；
xact.c 在并行模式禁止命令计数推进 `xact.c:651`）、游标、
`max_parallel_workers_per_gather=0`、表小于 `min_parallel_table_scan_size` 等。
`debug_parallel_query`（`guc_parameters.dat:694`）可强制走并行计划以利测试。

---

## 8. 设计动机：三个为什么

**为什么进程模型下并行用 DSM，而不是线程池？**
PG 一进程一连接，进程间没有共享地址空间，线程化要动整个后端的内存上下文/
错误处理模型——不可行。DSM（`dsm_create`，基于 `min_dynamic_shared_memory`
预留的 POSIX shm）是折中最优：worker 是**干净的普通 backend**（复用全部
隔离/鉴权/资源管理语义，连 pg_stat_activity 都能看到），只共享这一段刻意
构造的内存。对照系列：V8 用线程池（ isolates 共享进程地址空间 + 锁）、
ffmpeg 用线程/进程池共享帧缓冲；PG 的对应物是"进程 + 显式共享区 +
shm_mq 消息传递"，代价是 worker 启动要完整恢复 GUC/快照/事务状态
（`parallel.c:1457-1545`），收益是崩溃隔离与零历史包袱。

**为什么默认不全并行？**
三层成本都在收紧默认值：worker fork + 状态恢复是毫秒级
（`parallel_setup_cost` 默认 1000）、tuple 要经 shm_mq 复制一次
（`parallel_tuple_cost` 默认 0.1）、以及 DSM/bgworker 槽是全局稀缺资源
（max_worker_processes=8）。8MB 的 `min_parallel_table_scan_size` +
3 倍对数递增 worker 数（`allpaths.c:5001-5008`）保证小表永远串行、
大表 worker 数温和增长。这也是为什么很多人"设置了并行却不生效"。

**为什么 Gather 是屏障而 hash join 需要真 Barrier？**
Gather 是汇点（sink）：它消费完子树输出即可关断，无需多方同步。
parallel hash join 的 build 阶段是集体操作（一张共享表、一次 repartition），
必须所有人到齐才能进下一阶段——所以需要 `Barrier`（`hashjoin.h:271-273`），
且要小心"不在持屏障时吐元组"的死锁规避规则（`nodeHashjoin.c:146-158`）。

---

## 9. FAQ 素材

1. **Q: leader 自己干活吗？** A: 默认干。`parallel_leader_participation=true`
   时 leader 以 participant 身份跑一份子计划（`nodeGather.c:212-214`），
   EXPLAIN 里的 "Workers Planned: 2" 实际并发是 3 份。
2. **Q: worker 数为什么总是 2？** A: `max_parallel_workers_per_gather` 默认 2
   （`guc_parameters.dat:2079`），单查询多 Gather 会复用全局 8 个槽位
   （`max_parallel_workers`）。
3. **Q: 一个 worker 出错，其它 worker 的白干了吗？** A: 是。leader 重抛错误
   （`parallel.c:1196 ThrowErrorData`）→ 事务 abort → `AtEOXact_Parallel`
   强杀全组（`parallel.c:1271-1291`）。并行只有"全成功"或"全失败"。
4. **Q: 为什么 DSM 建不起来也能跑？** A: 降级为私有内存 + 0 worker
   （`parallel.c:331-337`），计划是同一份，只是串行执行。
5. **Q: 并行 seq scan 会不会扫重、扫漏？** A: 不会。块分配由单个原子计数器
   决定（fetch-add），每块恰好分给一个 worker；MVCC 快照在 leader 定好、
   序列化传给所有 worker（`parallel.c:406-409`），可见性判断全局一致。
6. **Q: EXPLAIN ANALYZE 怎么显示 worker 的行？** A: DSM 里有
   num_plan_nodes × num_workers 的 instrumentation 矩阵
   （`execParallel.c:100-112`），结束时 leader 逐节点聚合
   （`execParallel.c:1091-1173`），每 worker 一行显示。
7. **Q: 并行能加速 UPDATE/DELETE 吗？** A: 不能。并行模式强制只读
   （README.parallel:84-86），写只能作为并行子查询的 Gather 之外部分。
   并行红利在 SELECT 聚合、大表扫描、并行建索引/VACUUM。
8. **Q: parallel_setup_cost 调成 0 会怎样？** A: 优化器会对小查询也生成
   Gather 路径，但运行时仍有 fork+状态恢复的真实开销，通常更慢；
   `min_parallel_table_scan_size` 仍会挡住小表。
9. **Q: worker 与 leader 的快照一定相同吗？** A: 是。活动快照（以及 RR/SER
   隔离级的事务快照）被序列化进 DSM 并在 worker 恢复（`parallel.c:1499-1505`），
   低隔离级时把活动快照安装为事务快照以抬高 TransactionXmin（1490-1498 注释）。
10. **Q: 错误消息里为什么有时出现两份日志？** A: worker 本地写一份服务器日志，
    leader 重抛可能再写一份——这是已知未解问题（README.parallel:48-53）。

## 10. 深挖方向

1. **组锁（lock group）**：`BecomeLockGroupLeader/Member`（`parallel.c:590,1398`）
   如何把 leader+workers 绑成一个死锁检测单元——见 src/backend/storage/lmgr/README，
   是并行读一致性和无死锁的底层保证。
2. **shm_mq 环形队列本体**：`shm_mq.c:73-84` 的 `mq_bytes_read/written` 原子
   游标 + mutex + 条件变量，以及"大消息跨环回绕"的拼接路径（README.parallel:39-40）。
3. **流式读与 chunk 的协同**：`heap_scan_stream_read_next_parallel`
   （`heapam.c:254-287`）把 chunk 领取接入 read stream 预读管线——
   chunk 尺寸直接影响预读效率，这正是 MAX_CHUNK_SIZE 存在的原因。
4. **DSM 之外的 DSA**：为什么 parallel hash 建在 DSA（可增长、可 free）而不是
   shm_toc 固定段——`execParallel.c:887-909` 的注释给出参数重序列化的理由。
5. **worker 复用**：`ReinitializeParallelDSM/ReinitializeParallelWorkers`
   （`parallel.c:506-572`）+ `ExecParallelReinitialize`（`execParallel.c:968-1011`）
   支持 Gather 的 rescan（如 LATERAL 子查询）重发一批 worker 而不重建 DSM。

---

## 写作要点速查表

| # | 主题 | 函数/结构 | 位置 |
|---|------|-----------|------|
| 1 | ParallelContext（worker 数/DSM 段/toc/worker 数组） | struct ParallelContext | src/include/access/parallel.h:33-50 |
| 2 | 创建并行上下文 | CreateParallelContext | src/backend/access/transam/parallel.c:170 |
| 3 | DSM 布局：12 个状态块+错误队列+入口点 | InitializeParallelDSM | parallel.c:208（key 表 :66-80） |
| 4 | leader 身份压缩包/WAL 上报位 | FixedParallelState | parallel.c:83-105（last_xlog_end :357） |
| 5 | worker=bgworker，槽位不足优雅缩编 | LaunchParallelWorkers | parallel.c:577（bgw_flags :603，注册 :621-648） |
| 6 | worker 主入口：恢复状态→EnterParallelMode→entrypt | ParallelWorkerMain | parallel.c:1297（错误队列重定向 :1375-1382） |
| 7 | 错误传播：解析→降级→重抛 | ProcessParallelMessage | parallel.c:1142（ThrowErrorData :1196） |
| 8 | 等 worker 收工 + 取回 last_xlog_end | WaitForParallelWorkersToFinish | parallel.c:799（:895-904） |
| 9 | 执行器 DSM：计划/参数/元组队列/DSA | ExecInitParallelPlan | src/backend/executor/execParallel.c:651（key :60-69，64KB 队列 :71） |
| 10 | 计划序列化：resjunk 清零、只传 safe 子计划 | ExecSerializePlan | execParallel.c:151（:169-174，:206-214） |
| 11 | worker 侧查询主函数 | ParallelQueryMain | execParallel.c:1512（ExecutorRun :1581） |
| 12 | Gather 汇聚：轮询+本地执行+ramp-down | gather_readnext / gather_getnext | src/backend/executor/nodeGather.c:310 / :262 |
| 13 | leader 参与 GUC 消费点 | need_to_scan_locally | nodeGather.c:72-73、:212-214 |
| 14 | GatherMerge 堆归并 | gather_merge_getnext | src/backend/executor/nodeGatherMerge.c:543（replace_first :567） |
| 15 | 并行扫描共享游标 | ParallelBlockTableScanDescData | src/include/access/relscan.h:96-107 |
| 16 | scan 接线三步 | ExecSeqScan{Estimate,InitializeDSM,InitializeWorker} | src/backend/executor/nodeSeqscan.c:373/:391/:437 |
| 17 | chunk 原子领取+ramp-down | table_block_parallelscan_nextpage | src/backend/access/table/tableam.c:543（fetch-add :627-629，常量 :42-46） |
| 18 | worker 数规划（3 倍对数） | compute_parallel_worker | src/backend/optimizer/path/allpaths.c:4963（:5001-5008） |
| 19 | parallel hash 阶段机（Barrier） | ParallelHashJoinState / PHJ_BUILD_* | src/include/executor/hashjoin.h:257-284；nodeHashjoin.c:58-158 |
| 20 | 两阶段聚合标记 | AGGSPLIT_INITIAL_SERIAL/FINAL_DESERIAL | src/include/nodes/nodes.h:379-383 |
| 21 | 函数并行安全判定 | max_parallel_hazard / is_parallel_safe | src/backend/optimizer/util/clauses.c:812 / :831（proparallel 读取 lsyscache.c:2111） |
| 22 | GUC 默认值速查 | per_gather=2 / workers=8 / table 8MB / leader 参与=true | src/backend/utils/misc/guc_parameters.dat:2079/:2070/:2253/:2336 |
