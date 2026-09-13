# 卷一第 1 章 进程架构:postmaster 与 fork-per-connection

> 系列:《源码深读》第四系列(PostgreSQL)卷一第 1 章。前作系列已覆盖 Redis/Nginx 多进程、FFmpeg 多线程调度,本章将继续沿用"并发模型对照"视角。
> 源码版本:PostgreSQL master,commit `8c7a74c`(shallow clone)。行号均以该 commit 实际 grep/read 核对。

PostgreSQL 是"一个 postmaster 进程 + N 个 fork 出来的 backend 进程 + 若干辅助进程"的多进程架构。postmaster 只做三件事:监听端口、fork 子进程、监管子进程生死;所有真正的工作(解析、执行事务、写 WAL、刷脏页)都在子进程里完成。子进程之间不共享任何私有内存,唯一的真通信介质是 System V 共享内存段——理解这句话,就理解了 PostgreSQL 进程架构的全部设计取舍。

## 1. 全景:进程拓扑

```
                          客户端 (libpq)
                psql / JDBC / pg_dump / 备份工具 ...
                             │ TCP/Unix socket
                             ▼
  ┌────────────────────────────────────────────────────────────┐
  │  postmaster (pid=PostmasterPid)                            │
  │  PostmasterMain → ServerLoop 主循环                         │
  │  只做: accept → fork / waitpid 收尸 / 发信号 / 状态机        │
  │  自身不碰共享内存中的数据结构、不做事务                        │
  └───┬────────────────────────────────────────────────────────┘
      │ fork() (地址空间整段拷贝时已含 shmem 映射)
      │
      ├── client backend × N        BackendMain → PostgresMain 主循环
      │                             (每连接一个进程,上限 MaxBackends)
      ├── walsender × N             复制连接,由 backend 转型而来
      ├── startup process ×1        崩溃恢复/WAL redo,完成后退出
      ├── checkpointer ×1           CheckpointerMain,刷脏页+checkpoint
      ├── bgwriter ×1               BackgroundWriterMain
      ├── walwriter ×1              WalWriterMain,异步刷 WAL
      ├── autovacuum launcher ×1    指挥 autovacuum worker
      ├── autovacuum worker ×N      实际执行 VACUUM/ANALYZE
      ├── archiver ×1               归档 WAL
      ├── walsummarizer ×1          WAL 摘要
      ├── walreceiver ×1            流复制下游
      ├── io worker ×N              AIO 轮询 worker(新)
      ├── syslogger ×1              日志收集(唯一不挂 shmem 的进程)
      └── background worker ×N      扩展注册的任意逻辑
                 │
                 ▼  所有进程(除 syslogger)共同 mmap 同一段
      ╔═══════════════════════════════════════════╗
      ║  System V 共享内存 + POSIX 信号量           ║
      ║  shared buffers / WAL buffer / 锁表 /      ║
      ║  ProcGlobal(PGPROC 数组) / ShmemIndex ...  ║
      ╚═══════════════════════════════════════════╝
```

关键事实:每个进程类型在 `src/include/postmaster/proctypelist.h:34-53` 有一张登记表,写明类型、名字、Main 函数、是否挂共享内存——这是读进程架构源码的总入口。进程类型枚举 `BackendType` 在 `src/include/miscadmin.h:340-385`,其中注释明确:B_LOGGER "不连共享内存、没有 PGPROC"(src/include/miscadmin.h:380-384)。

## 2. postmaster 主循环专节

### 2.1 启动流程与进入主循环

`PostmasterMain`(src/backend/postmaster/postmaster.c:496)做完参数解析、加载控制文件、注册各子系统 shmem 需求、创建共享内存(src/backend/postmaster/postmaster.c:1017 调 `CreateSharedMemoryAndSemaphores`)、打开监听 socket 之后,先 fork 出第一批判决进程再进入死循环(src/backend/postmaster/postmaster.c:1393-1414):

```c
	UpdatePMState(PM_STARTUP);                     /* :1393 */
	/* Start bgwriter and checkpointer so they can help with recovery */
	if (CheckpointerPMChild == NULL)
		CheckpointerPMChild = StartChildProcess(B_CHECKPOINTER);  /* :1400 */
	if (BgWriterPMChild == NULL)
		BgWriterPMChild = StartChildProcess(B_BG_WRITER);         /* :1402 */
	StartupPMChild = StartChildProcess(B_STARTUP);                /* :1407 */
	...
	status = ServerLoop();                         /* :1414 */
```

注意顺序:checkpointer/bgwriter 在 PM_STARTUP 阶段就启动,因为崩溃恢复要靠它们;startup process 负责 WAL redo,它退出(恢复完成)后系统才进入 PM_RUN。

### 2.2 ServerLoop:事件驱动的 accept 与收尸

`ServerLoop`(src/backend/postmaster/postmaster.c:1676-1827)是一个无 return 的 for(;;) 循环,核心骨架(src/backend/postmaster/postmaster.c:1691-1735):

```c
		nevents = WaitEventSetWait(pm_wait_set,
								   DetermineSleepTime(),   /* :1691-1695 */
								   events, lengthof(events), 0);

		for (int i = 0; i < nevents; i++)
		{
			if (events[i].events & WL_LATCH_SET)
				ResetLatch(MyLatch);
			if (pending_pm_shutdown_request)     /* 信号只置 latch/标志位, */
				process_pm_shutdown_request();   /* :1713 真正处理在主循环 */
			if (pending_pm_reload_request)
				process_pm_reload_request();     /* :1715 */
			if (pending_pm_child_exit)           /* :1717 SIGCHLD 收尸 */
				process_pm_child_exit();
			if (pending_pm_pmsignal)             /* :1719 子进程 pmsignal */
				process_pm_pmsignal();
			if (events[i].events & WL_SOCKET_ACCEPT)   /* :1722 */
			{
				ClientSocket s;
				if (AcceptConnection(events[i].fd, &s) == STATUS_OK)
					BackendStartup(&s);          /* :1727 fork 一个 backend */
			}
		}
		LaunchMissingBackgroundProcesses();      /* :1742 补齐辅助进程 */
```

要点:
- postmaster 的并发模型是**电平触发的事件循环 + 同步 fork**。信号处理函数只做"置 volatile 标志 + SetLatch"(src/backend/postmaster/postmaster.c:2249-2254 的 `handle_pm_child_exit_signal`),所有实质工作都推迟到主循环里串行做——这保证了 postmaster 自身无锁、无重入。
- 每轮循环末尾调 `LaunchMissingBackgroundProcesses()`(定义 src/backend/postmaster/postmaster.c:3337-3451):谁不在就补谁——walwriter 仅 PM_RUN 时启动(:3376),autovacuum launcher 依 `AutoVacuumingActive()`(:3384-3391),archiver 依 `XLogArchivingActive()`(:3397-3401),walsummarizer 依 `summarize_wal`(:3443-3446)。**辅助进程的"常驻"是 postmaster 主循环每轮补种出来的**,而不是 daemon 自生自灭。
- 收尾杂务:SIGQUIT 后 5 秒还没死透的子进程升级为 SIGKILL/SIGABRT(src/backend/postmaster/postmaster.c:1780-1792,常量 `SIGKILL_CHILDREN_AFTER_SECS` :370);每分钟检查 postmaster.pid 是否被人删了(:1804-1813);每 58 分钟 touch socket 文件防 /tmp 清理(:1820-1825)。
- 有趣的断言:postmaster 必须保持单线程,编译期支持的平台会周期性检查 `pthread_is_threaded_np() == 0`(src/backend/postmaster/postmaster.c:1752-1758)。

### 2.3 fork 一个 backend:BackendStartup

连接到来时 `BackendStartup`(src/backend/postmaster/postmaster.c:3588-3668)分四步:

1. `canAcceptConnections(B_BACKEND)`(:3607)检查状态机是否允许;不是 PM_RUN/PM_HOT_STANDBY 时返回 CAC_STARTUP/CAC_RECOVERY/CAC_SHUTDOWN 等拒接码(定义 src/backend/postmaster/postmaster.c:1835-1867,关键判断 :1847 `pmState != PM_RUN && pmState != PM_HOT_STANDBY`)。
2. 分配 PMChild 槽位(:3611);槽位耗尽则改派 "dead-end child"(:3618-3623)——fork 一个只给客户端回一句错误就退出的进程。
3. `postmaster_child_launch(...)`(:3640-3642)真正 fork。
4. fork 失败则释放槽位、给客户端报错(:3643-3653,`report_fork_failure_to_client` :3678-3698)。

canAcceptConnections 的判断码会被带到子进程里,由 `BackendInitialize` 决定是正常服务还是礼貌拒绝(src/backend/tcop/backend_startup.c:110)。

### 2.4 子进程拿到什么:launch_backend 与 fork_process

`postmaster_child_launch`(src/backend/postmaster/launch_backend.c:204-273)是所有子进程的统一出生地。非 EXEC_BACKEND(即常规 Unix)路径就是一次 fork(src/backend/postmaster/launch_backend.c:222-268):

```c
	pid = fork_process();
	if (pid == 0)                    /* child */          /* :223 */
	{
		MyBackendType = child_type;                        /* :225 */
		...
		ClosePostmasterPorts(child_type == B_LOGGER);      /* :238 */
		InitPostmasterChild();                             /* :241 */
		if (!child_process_kinds[child_type].shmem_attach)
		{
			dsm_detach_all();                              /* :246 */
			PGSharedMemoryDetach();                        /* :247 */
		}
		MemoryContextSwitchTo(TopMemoryContext);           /* :256 */
		...
		child_process_kinds[child_type].main_fn(startup_data, startup_data_len);
		                                                   /* :268 */
	}
```

这里回答了"监听 socket 和共享内存怎么传给子进程":**不传,靠 fork 天然继承**。listen socket 由子进程主动 `ClosePostmasterPorts` 关掉(src/backend/postmaster/postmaster.c:1879-1924);shmem 映射留在地址空间里,不需要 shmem_attach 的进程(如 syslogger)才显式 detach(src/backend/postmaster/launch_backend.c:244-248)。`startup_data`(如 ClientSocket、CAC 状态)随 fork 一并带过去。EXEC_BACKEND 平台(Windows)没有 fork,才走 `internal_forkexec`:把进程参数序列化进临时文件,fork+execv `postgres --forkchild=...`(src/backend/postmaster/launch_backend.c:284-378),子进程从 `SubPostmasterMain`(:576)读回参数重建状态。

`fork_process`(src/backend/postmaster/fork_process.c:32-126)是 fork 的薄包装:fork 前 `fflush(NULL)` 防止 stdio 缓冲双写(:46);fork 期间阻塞所有信号、子进程装好 handler 再解锁,避免竞态(:59-65 注释写明动机);子进程里重设 `MyProcPid`(:70)并按 `PG_OOM_ADJUST_FILE` 调整 OOM score,防止 Linux OOM killer 先杀 postmaster(:75-114)。

`InitPostmasterChild`(src/backend/utils/init/miscinit.c:96-168)做"脱离 postmaster 身份"的收尾:on_exit_reset 丢弃父进程的退出回调(:123)、setsid(:141-144)、**给 SIGQUIT 装默认 crash handler 并从阻塞集中解锁 SIGQUIT**(:146-156)——每个子进程必须随时能响应 SIGQUIT,这是崩溃级联协议的接线。

### 2.5 收尸与崩溃级联:为什么一个 backend 崩溃要重启整个集群

SIGCHLD 到来后在 `process_pm_child_exit`(src/backend/postmaster/postmaster.c:2259-2594)用 `waitpid(-1, ..., WNOHANG)` 轮询收尸(:2270),按死者的 PMChild 身份分流:

- **startup process** 正常退出(exit 0)→ `FatalError = false; UpdatePMState(PM_RUN)`,打印 "database system is ready to accept connections"(:2360-2375)。异常退出则 `HandleChildCrash`(:2352)。
- **辅助进程**正常退出忽略,主循环下一轮自动补种;异常退出按崩溃处理(bgwriter :2391-2399、checkpointer :2404-2434、walwriter :2441-2449、autovacuum launcher :2488-2496 等)。
- **backend/bgworker** 走 `CleanupBackend`(:2602)。判据是退出码:exit 0(正常)或 exit 1(FATAL)都算"体面退出",**其余一律算 crash**(:2631-2632 `if (!EXIT_STATUS_0(exitstatus) && !EXIT_STATUS_1(exitstatus)) crashed = true;`)。

崩溃处理的核心在 `HandleChildCrash`(src/backend/postmaster/postmaster.c:2830-2852)→ `HandleFatalError`(:2745-2819):

```c
	if (FatalError || Shutdown == ImmediateShutdown)   /* :2840 */
		return;    /* 已在崩溃态,只更新账本,不再刷屏 */
	LogChildExit(LOG, procname, pid, exitstatus);
	ereport(LOG, (errmsg("terminating any other active server processes")));
	HandleFatalError(PMQUIT_FOR_CRASH, true);          /* :2851 */
```

`HandleFatalError` 给**其余全部子进程**发 SIGQUIT(默认;GUC `send_abort_for_crash` 打开时改发 SIGABRT 以便抓 core,src/backend/postmaster/postmaster.c:2754-2765),置 `FatalError = true`,状态切到 PM_WAIT_BACKENDS,并启动 5 秒 SIGKILL 倒计时(:2817-2818)。

**为什么一个 backend 崩溃要连坐所有进程?** 因为崩溃意味着该进程死在任意指令边界,共享内存里它的锁表项、buffer pin、缓冲区状态都可能是脏的,而其他进程可能正阻塞在等它持有的锁上——共享状态已不可信,唯一安全的做法是全员退出、重放 WAL 重建一致状态。子进程侧配合的正是 quickdie:backend 收到 SIGQUIT 后**跳过一切清理、直接 `_exit(2)`**,注释明说"共享内存可能已损坏,不要试图清理事务"(src/backend/tcop/postgres.c:3092-3106)。

等所有子进程死绝(PM_NO_CHILDREN)后,`PostmasterStateMachine` 进入重初始化分支(src/backend/postmaster/postmaster.c:3248-3288):删除临时文件(:3254)、`shmem_exit(1)` + `ResetShmemAllocator` + 重建共享内存(:3260-3273)、重新 fork startup process(:3280)、重新打开 accept(:3287)。由 startup process 重放 WAL,成功退出后再次 PM_RUN。若 GUC `restart_after_crash = off` 则直接退出(:3236-3241)。

### 2.6 PM 状态机简览

状态枚举在 src/backend/postmaster/postmaster.c:336-353,大注释 :293-335 是官方讲解:

| 状态 | 含义 | 关键行号 |
|---|---|---|
| PM_INIT | postmaster 初始化中 | :338 |
| PM_STARTUP | 等 startup process 完成恢复 | :339,入口 :1393 |
| PM_RECOVERY / PM_HOT_STANDBY | 归档恢复中 / 可只读接客 | :340-341 |
| PM_RUN | 正常服务,唯一可正常接连接的状态 | :342,进入点 :2363 |
| PM_STOP_BACKENDS → PM_WAIT_BACKENDS | 关停:发 SIGTERM 再等退场 | :343-344,处理 :2950-3109 |
| PM_WAIT_XLOG_SHUTDOWN → ... → PM_WAIT_CHECKPOINTER | 等 shutdown checkpoint 逐层收尾 | :345-350,:3118-3153 |
| PM_WAIT_DEAD_END → PM_NO_CHILDREN | 等 dead-end 子进程排空 → 全灭 | :351-352,:3160-3188 |
| (无状态) | 崩溃重初始化分支 | :3248-3288 |

三个开关量叠加在状态机之上: Shutdown(No/Smart/Fast/Immediate,src/backend/postmaster/postmaster.c:284-289)、FatalError(:291)、connsAllowed(:363)。三种关停语义:smart 等客户端走完(`connsAllowed=false` :2153-2154)、fast 给所有活跃 backend 发 SIGTERM 回滚走人(:2169-2208)、immediate 直接全员 SIGQUIT(:2210-2245)。正常关停的最后一站是 checkpointer 写 shutdown checkpoint(:3079-3086 发 SIGINT 触发)。

## 3. backend 生命周期专节

### 3.1 出生:BackendMain

backend 的入口是 `BackendMain`(src/backend/tcop/backend_startup.c:75-125):`BackendInitialize` 处理启动包与认证(:110)→ `InitProcess()` 在共享内存的 PGPROC 数组里占一个坑(:116)→ 进入 `PostgresMain`(:124)。walsender 不单独 fork:它生来就是 B_BACKEND,在处理启动包时发现是复制请求才改类型 `MyBackendType = B_WAL_SENDER`(src/backend/tcop/backend_startup.c:886)。

### 3.2 主循环:PostgresMain

`PostgresMain`(src/backend/tcop/postgres.c:4363)先装信号(SIGINT→StatementCancelHandler :4398、SIGTERM→die :4399、SIGQUIT→quickdie :4409-4410),然后立一个**常驻的 sigsetjmp 锚点**再进 for(;;) 循环(:4696)。每轮迭代(:4696-5020):

```c
	for (;;)                                            /* :4696 */
	{
		MemoryContextSwitchTo(MessageContext);
		MemoryContextReset(MessageContext);             /* :4718-4719 */
		if (send_ready_for_query)                       /* :4745 */
			...
			ReadyForQuery(whereToSendOutput);           /* :4863 */
		DoingCommandRead = true;                        /* :4873 */
		firstchar = ReadCommand(&input_message);        /* :4878 阻塞在这 */
		...
		CHECK_FOR_INTERRUPTS();                         /* :4908 */
		switch (firstchar)                              /* :4928 */
		{
			case PqMsg_Query:                           /* 简单查询 'Q' */
				query_string = pq_getmsgstring(&input_message);
				...
				exec_simple_query(query_string);        /* :4946 */
				send_ready_for_query = true;            /* :4950 */
				break;
			case PqMsg_Parse: ...                       /* 扩展协议 :4954 */
			case PqMsg_Bind: ...
			case PqMsg_Execute: ...
		}
	}
```

每轮开头 `MemoryContextReset(MessageContext)` 是 backend 的内存卫生学:上一条命令的全部解析/执行垃圾在上下文 reset 时一次性释放(:4715-4721 注释)。

### 3.3 简单查询路径与事务边界

`exec_simple_query`(src/backend/tcop/postgres.c:1030-1420)是"一条 Query 消息 = 一个事务命令块"的实现:

1. `start_xact_command()`(:1064;定义 :2874-2910,内部 `StartTransactionCommand` :2878)——懒启动事务。
2. `pg_parse_query`(:1083)得到裸语法树列表;**多条语句默认绑成一个事务**,用"隐式事务块"表达(:1107-1114 `use_implicit_block = (list_length(parsetree_list) > 1)`)。
3. 逐棵树:解析分析→重写→规划→`PortalRun` 执行(:1297-1302);被 ROLLBACK 之外的语句撞上 aborted 状态会被拒(:1158,aborted 后只认 COMMIT/ROLLBACK)。
4. 事务边界:最后一条语句 `finish_xact_command()`(:1319-1321);遇到显式 BEGIN/COMMIT 语句则当场提交再开新块(:1323-1330);否则每条语句后仅 `CommandCounterIncrement()`(:1344)。
5. `finish_xact_command`(定义 :2913-2935)调 `CommitTransactionCommand()`(:2920)。

### 3.4 sigsetjmp/longjmp 错误恢复模型

PostgreSQL 没有 C++ 异常,用 setjmp 模拟:`ereport(ERROR)` 最终在 errfinish 里 `PG_RE_THROW()` 即 longjmp 回最近的 `PG_exception_stack`(src/backend/utils/error/elog.c:528-552)。异常栈底不在别处,正是 PostgresMain 的主循环锚点(src/backend/tcop/postgres.c:4573-4684):

```c
	if (sigsetjmp(local_sigjmp_buf, 1) != 0)            /* :4573 */
	{
		error_context_stack = NULL;                     /* :4584 */
		HOLD_INTERRUPTS();                              /* :4587 */
		disable_all_timeouts(false);                    /* :4600 */
		...
		EmitErrorReport();       /* 把错误发给客户端/日志 */   /* :4612 */
		AbortCurrentTransaction();  /* 回滚,恢复事务状态 */  /* :4629 */
		...
		MemoryContextSwitchTo(MessageContext);
		FlushErrorState();                              /* :4655-4656 */
		if (doing_extended_query_message)
			ignore_till_sync = true;   /* 扩展协议:吞到 Sync */ /* :4663 */
		...
		if (pq_is_reading_msg())                        /* :4677 */
			ereport(FATAL, ...);   /* 协议失步,只能断开连接 */
	}
	PG_exception_stack = &local_sigjmp_buf;             /* :4687 */
```

语义分级(elog.h 级别定义 src/include/utils/elog.h:33-58):
- **ERROR**(:53,"user error - abort transaction; return to known state"):longjmp 回主循环,回滚当前事务,**进程活着、连接活着**,客户端收到错误后可继续下一条查询。
- **FATAL**(:56):不走 longjmp,直接 `proc_exit(1)`(src/backend/utils/error/elog.c:577-608)——进程退出但 postmaster 视为体面,不级联。
- **PANIC**(:58,"take down the other backends with me"):直接 `abort()`(src/backend/utils/error/elog.c:611-622),以异常退出码被 postmaster 收尸,触发 2.5 节的崩溃级联。另外在临界区(CritSection)内任何 ERROR 都会被升格为 PANIC(src/backend/utils/error/elog.c:369-373)。

事务/子事务的内存上下文配合(简):每条命令活在 MessageContext 下,语句级 per-parsetree 上下文执行完即删(src/backend/tcop/postgres.c:1362-1364);出错时 `AbortCurrentTransaction` + `FlushErrorState` 把上下文栈与错误状态复位(:4629、:4656)。错误与长跳转的完整闭环是:ERROR → longjmp → AbortCurrentTransaction → MemoryContextReset → ReadyForQuery('Z') → 等下一条命令,进程零重启。

## 4. 共享内存专节

### 4.1 创建与绑定

postmaster 启动路径:`PostmasterMain` 先调 `RegisterBuiltinShmemCallbacks()`(src/backend/tcop/postgres.c:4272 是单用户模式对应物;postmaster 路径见 src/backend/postmaster/postmaster.c:1017 附近)遍历 subsystemlist.h 登记各子系统回调(src/backend/storage/ipc/ipci.c:167-180),扩展则经 `process_shared_preload_libraries` / `ShmemCallRequestCallbacks` 登记;随后 `CreateSharedMemoryAndSemaphores`(src/backend/storage/ipc/ipci.c:119-160):

```c
	size = CalculateShmemSize();                        /* :129 */
	seghdr = PGSharedMemoryCreate(size, &shim);         /* :135 */
	InitShmemAllocator(seghdr);                         /* :147 */
	ShmemInitRequested();                               /* :150 */
	dsm_postmaster_startup(shim);                       /* :153 动态共享内存 */
	if (shmem_startup_hook)
		shmem_startup_hook();                           /* :158-159 */
```

`PGSharedMemoryCreate`(SysV 实现 src/backend/port/sysv_shmem.c:702)创建 OS 级共享段;因为随后所有子进程都由 postmaster fork 而来,**映射关系(含各子系统全局指针)直接写时复制继承**,子进程无须任何"attach 恢复指针"的动作——shmem.c 顶部注释明说:非 EXEC_BACKEND 下 "individual backends do not need to re-establish their local pointers ... they inherit correct values via fork()"(src/backend/storage/ipc/shmem.c:96-103)。只有 EXEC_BACKEND 平台要在每个 backend 里重放 request/attach 流程(`ShmemAttachRequested`,src/backend/storage/ipc/shmem.c:481-518)。

崩溃后重建也走同一函数:2.5 节的 `shmem_exit(1)` → `ResetShmemAllocator()` → `CreateSharedMemoryAndSemaphores()`(src/backend/postmaster/postmaster.c:3260-3273)。

### 4.2 分配器与 ShmemIndex:"名字→地址"目录

共享段内部是一个**只增不减的 bump 分配器**:`ShmemAllocRaw` 拿自旋锁、对齐到 cache line、前移 `free_offset`(src/backend/storage/ipc/shmem.c:840-885,锁 :864)。没有 free-list,没有回收——因为共享内存的生命周期=postmaster 的生命周期,重初始化时整段重来。

`ShmemIndex` 是全局目录:一个存在共享内存里的哈希表,条目 `ShmemIndexEnt` 为 48 字节名字 + 位置/大小/分配大小/initialized 标志(src/backend/storage/ipc/shmem.c:259-279,键宽 :262)。注册新流程(2026 主线重构后):子系统在 request 阶段报尺寸(`ShmemGetRequestedSize` 汇总 :403-427),段建成后 `ShmemInitRequested`(:436-473)逐个 `InitShmemIndexEntry`:

```c
	index_entry = (ShmemIndexEnt *)
		hash_search(ShmemIndex, name, HASH_ENTER_NULL, &found);  /* :539-540 */
	if (found)
		elog(ERROR, "shared memory struct \"%s\" is already initialized", name);
	...
	structPtr = ShmemAllocRaw(request->options->size,
							  request->options->alignment, &allocated_size); /* :556 */
	...
	index_entry->location = structPtr;                  /* :571 */
	if (request->options->ptr)
		*(request->options->ptr) = index_entry->location;        /* :582-583 */
```

即:**名字哈希进 ShmemIndex → bump 分配器切出内存 → 把地址写进全局指针变量**。legacy 接口 `ShmemInitStruct(name, size, &found)`(src/backend/storage/ipc/shmem.c:1099-1135)是扩展仍在用的"名字→地址"查找/创建二合一:持 `ShmemIndexLock` 独占锁(:1114),`AttachShmemIndexEntry` 查到即返回既有地址(:1120-1121),查不到就 `InitShmemIndexEntry` 新建(:1126)。查看全局目录可用 SQL:`pg_get_shmem_allocations`(:1138-1187)。

## 5. fork-per-connection 专节:并发模型对照

| 维度 | PostgreSQL fork-per-connection | Redis 单线程事件循环 | Nginx 多进程(固定 worker) | FFmpeg 多线程池 |
|---|---|---|---|---|
| 并发单元 | 每连接 1 个进程 | 1 个进程,io 多路复用 | 预 fork N 个 worker 抢 accept | 任务队列 + 线程 |
| 连接状态 | 全在进程私有内存 | 全在单循环局部状态 | worker 私有 | 任务上下文 |
| 故障爆炸半径 | 单连接崩溃→整个集群级联重启 | 单逻辑出错可能带崩全部连接 | worker 崩溃仅丢其上连接 | 线程崩溃带崩整个进程 |
| 共享状态介质 | System V shmem + 锁 | 无(进程内) | 极少(shm 级 stats/锁) | 全靠锁/原子 |
| 创建成本 | fork+继承高,靠 Copy-on-Write 摊薄 | 无 | 启动时一次 | pthread 创建低 |
| 内存隔离 | 天然完全隔离 | 不适用 | 隔离 | 同地址空间,隔离靠纪律 |

PostgreSQL 选 fork 的硬约束有三:

1. **崩溃域=地址空间**。数据库允许任意扩展 C 代码、任意算子栈深,进程级隔离让"一段有 bug 的内存写坏"最多害死一个连接;结合 2.5 节的级联协议,系统对"任何进程可能随时死亡"有完备的恢复脚本。这与 FFmpeg 形成鲜明对比:解码线程段错误=整个转码任务死亡,没有"回滚重放"一说。
2. **错误恢复模型依赖栈回滚**。3.4 节的 sigsetjmp 体系要求每个事务状态(锁、buffer pin、内存上下文)都能在单进程内 unwind 干净;而单线程多路复用(Redis 式)要求每个连接在任意命令边界都保存完整可恢复状态机,这与"事务任意中途出错"的复杂度不匹配。
3. **fork 免去了传输共享状态**。postmaster 已把 shmem 映射、已打开的数据文件 fd、GUC、监听 socket 全部备好,fork 一次全部继承(launch_backend.c:222-268),子进程出生即"懂业务"。Nginx 预 fork 固定 worker 是为了摊掉这个成本;PG 的连接数(数百~数千)与连接生命周期(秒~天)使得 fork 的一次性成本可接受,这也是 pgbouncer 这类连接池器存在的理由。

代价同样写进代码:每轮连接建立要 fork+认证,`log_connections=setup_durations` 可以打出 fork 耗时(src/backend/tcop/postgres.c:4836-4861);进程数上限由 MaxBackends 决定,PGPROC 数组在 shmem 里预分配;且如 2.2 节所述,postmaster 必须永远单线程(:1752-1758),否则 fork 语义被破坏。

## 6. 设计动机小结

- **崩溃域=地址空间**:内存错误、扩展 bug、恶意输入的伤害被 OS 边界截断;恢复策略"全员退出+WAL 重放"简单且可证明正确(postmaster.c:294-295 注释直言 crash recovery "rather like shutdown followed by startup")。
- **辅助进程为什么也是 fork**:统一基础设施。出生流程(child_process_kinds 一张表,launch_backend.c:179-184)、信号协议(SIGQUIT 随时可杀,miscinit.c:146-156)、监管协议(postmaster 统一 waitpid 分流,postmaster.c:2270-2587)完全共用;差别只在 Main 函数与是否挂 shmem。监管成本恒定:postmaster 只需要 waitpid + 查表 + 发信号。
- **共享内存为什么是命脉**:buffer、锁、WAL 插入点、PGPROC 全在里面。它既是数据通路也是"信任根"——正因如此,任何进程异常死亡都等于"shmem 可能被污染",必须全部推倒重来(quickdie 注释,postgres.c:3092-3106);也正因如此,postmaster 每分钟检查数据目录锁文件防两个 postmaster 共管一份 shmem(postmaster.c:1794-1813)。postmaster 自身则刻意"不懂业务":它从不解释 shmem 内容,只认退出码与信号,这使监管逻辑极难出错。

## 7. FAQ 素材

1. **Q: postmaster 接到连接后,listen socket 怎么给子进程?** 不用给。fork 天然复制 fd 表,子进程反过来调 `ClosePostmasterPorts` 关掉不用的 listen socket(launch_backend.c:238;postmaster.c:1879-1924),客户端 socket 则留在自己手里。
2. **Q: 为什么 backend 崩溃后所有连接都断了?** 共享内存可能已被污染(锁没释放、buffer pin 悬空),无法局部止损;postmaster SIGQUIT 全员 → WAL 重放 → 恢复服务(postmaster.c:2830-2888、:3248-3288)。
3. **Q: ERROR 和 FATAL 的区别,用进程语言说?** ERROR=longjmp 回主循环回滚事务,进程与连接都活着(postgres.c:4573-4684);FATAL=proc_exit(1),进程死但体面,不级联(elog.c:577-608);PANIC=abort(),触发级联(elog.c:611-622)。
4. **Q: 事务在哪开始?** 懒启动:ReadCommand 拿到消息后 start_xact_command 才 StartTransactionCommand(postgres.c:2874-2881);简单协议里多条语句默认一个事务(:1107-1114)。
5. **Q: 共享内存怎么知道该建多大?** 两段式:先让所有子系统/扩展报需求(ShmemRequest 回调),`ShmemGetRequestedSize` 求和(shmem.c:403-427),再创建段并初始化。
6. **Q: ShmemIndex 是什么?** 共享内存自己的目录:驻留在共享段内的哈希表,名字→地址/大小(shmem.c:259-279);`ShmemInitStruct` 是它的 legacy 查找接口(:1099-1135)。
7. **Q: walsender 是独立进程类型吗?** 半是:生为 B_BACKEND,处理启动包时认出复制协议才改 `MyBackendType = B_WAL_SENDER`(backend_startup.c:886),proctypelist 里它的 main_fn 为 NULL(proctypelist.h:51)。
8. **Q: Windows 怎么办?没有 fork。** EXEC_BACKEND 路径:参数序列化到临时文件,`fork+execv postgres --forkchild=...`,子进程在 SubPostmasterMain 重建全部状态(launch_backend.c:284-378、:576);shmem 指针也要逐个重挂(shmem.c:481-518)。
9. **Q: 关闭时谁最后死?** 状态机依次等 backends→辅助进程→walsender/archiver→checkpointer 写 shutdown checkpoint→dead-end→只剩 syslogger,靠管道 EOF 自灭(postmaster.c:3060-3219 注释 :3199-3201)。
10. **Q: 为什么 Linux OOM killer 老杀 postmaster?** 内核按"进程 + 其 shmem 页"估算 postmaster 内存占用;所以子进程出生时会按 `PG_OOM_ADJUST_FILE` 调低自己的保护等级(fork_process.c:75-114)。

## 8. 深挖方向

1. **崩溃恢复端到端演练**:kill -9 一个正在跑长事务的 backend → 观察日志链(LogChildExit → "terminating any other active server processes" → "all server processes terminated; reinitializing" → "database system is ready"),对照 postmaster.c:2843-2851、:3250-3280、:2374-2375。
2. **EXEC_BACKEND 之痛**:对比 launch_backend.c 两条 fork 路径的参数集(save_backend_variables 序列化了什么,:707-786),体会 fork 继承"白拿"了多少状态。
3. **pmsignal/dead-man switch**:postmaster_alive_fds 管道(postmaster.c:4708-4735;pmsignal.c:361)如何让子进程在 postmaster 意外死亡时自杀,补全"谁是看门人"的另一半。
4. **信号协议全景**:SIGQUIT/SIGTERM/SIGINT/SIGUSR1/SIGUSR2 在 postmaster 与各子进程的语义矩阵(postmaster.c:2754-2765、:3044、:3084;postgres.c:4398-4412)。
5. **内存上下文与事务生命周期**:TopTransactionContext/TransactionContext/MessageContext 的创建与 reset 时机(postgres.c:4531-4546、:4718-4719;memutils),解释"为什么 PG 查询泄漏只撑到事务结束"。

## 写作要点速查表

| 主题 | 函数/对象 | 文件:行号 |
|---|---|---|
| 进程类型总表 | child_process_kinds | src/backend/postmaster/launch_backend.c:179-184(+proctypelist.h:34-53) |
| 进程类型枚举 | BackendType / B_LOGGER 特殊性 | src/include/miscadmin.h:340-385 |
| postmaster 主函数 | PostmasterMain | src/backend/postmaster/postmaster.c:496(建 shmem :1017,进主循环 :1414) |
| 主循环 | ServerLoop | src/backend/postmaster/postmaster.c:1676-1827(accept+fork :1722-1727,补种 :1742) |
| fork 启动 backend | BackendStartup | src/backend/postmaster/postmaster.c:3588-3668(dead-end :3618-3631) |
| 统一 fork 出口 | postmaster_child_launch | src/backend/postmaster/launch_backend.c:204-273 |
| fork 包装(信号/OOM) | fork_process | src/backend/postmaster/fork_process.c:32-126 |
| 子进程身份切换 | InitPostmasterChild(SIGQUIT 接线) | src/backend/utils/init/miscinit.c:96-168(:146-156) |
| backend 入口 | BackendMain | src/backend/tcop/backend_startup.c:75-125 |
| backend 主循环 | PostgresMain(sigsetjmp 锚 :4573,循环 :4696,ReadCommand :4878) | src/backend/tcop/postgres.c:4363-5020 |
| 简单查询 | exec_simple_query(start_xact :1064,PortalRun :1297) | src/backend/tcop/postgres.c:1030-1420 |
| 事务边界 | start_xact_command / finish_xact_command | src/backend/tcop/postgres.c:2874-2935 |
| 崩溃退场 | quickdie(_exit(2)) | src/backend/tcop/postgres.c:3017-3107 |
| 收尸分流 | process_pm_child_exit(waitpid :2270) | src/backend/postmaster/postmaster.c:2259-2594 |
| 崩溃级联 | HandleChildCrash → HandleFatalError | src/backend/postmaster/postmaster.c:2830-2852 / :2745-2819 |
| 状态机 | PMState 枚举 + PostmasterStateMachine | src/backend/postmaster/postmaster.c:336-353 / :2924(重初始化 :3248-3288) |
| 辅助进程补种 | LaunchMissingBackgroundProcesses | src/backend/postmaster/postmaster.c:3337-3451 |
| 建共享内存 | CreateSharedMemoryAndSemaphores | src/backend/storage/ipc/ipci.c:119-160 |
| shmem 分配器 | ShmemAllocRaw(bump+自旋锁) | src/backend/storage/ipc/shmem.c:840-885 |
| shmem 目录 | ShmemIndex / InitShmemIndexEntry / ShmemInitStruct | src/backend/storage/ipc/shmem.c:259-279 / :529-595 / :1099-1135 |
| 错误级别语义 | ERROR/FATAL/PANIC | src/include/utils/elog.h:53-58;elog.c:528-622 |
| 各 Main 函数 | CheckpointerMain:206(bgwriter.c:89,walwriter.c:90,autovacuum.c:406/1413,bgworker.c:741,walsummarizer.c:223,startup.c:216,pgarch.c:221,walreceiver.c:155,syslogger.c:172) | 各自文件 |
