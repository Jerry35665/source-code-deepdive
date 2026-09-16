# PostgreSQL 深读报告 S:逻辑解码与后台工作者框架

> 基线:commit `8c7a74c`。行号以 src/backend/replication/logical/、src/backend/postmaster/bgworker.c 为准。

## 逻辑解码

解码入口 LogicalDecodingProcessRecord(:88-124):先 ReorderBufferAssignChild 挂子事务再按 rmgr 分发。xact_decode(:213)在非 FULL_SNAPSHOT 时直接返回。DecodeCommit(:688)→SnapBuildCommitTxn(:703)→ReorderBufferCommit(:755)。

ReorderBuffer:WAL 序→按 commit 重排,子事务用 binaryheap 按 LSN 归并,大事务 spool 磁盘。ReorderBufferQueueChange(:811)入队后调 ReorderBufferCheckMemoryLimit(:866);超过 logical_decoding_work_mem 时流式或 spill(:3962-4001)。

snapshot builder 四态状态机:START→BUILDING_SNAPSHOT→FULL_SNAPSHOT→CONSISTENT。"先见 commit 后见变更"难题:running xacts 可能已写入 commit 记录。

CreateInitDecodingContext(logical.c:408)取 GetOldestSafeDecodingTransactionId(:505)做 xmin horizon。LoadOutputPlugin(:815)加载输出插件(begin/change/commit 三回调)。

## bgworker 框架

BackgroundWorker 结构(bgworker.h:96-108):bgw_name/type/flags/start_time/restart_time/library_name/function_name/main_arg/extra/notify_pid。三种启动时机;flags 含 BGWORKER_SHMEM_ACCESS(必需)等。共享内存 BackgroundWorkerSlot(generation 防串号);动态注册 RegisterDynamicBackgroundWorker(:1068);SanityCheckBackgroundWorker(:658);postmaster 经 SIGUSR1 感知新注册(:272);maybe_start_bgworkers(:4293)每次最多 100 个。

逻辑复制 worker:ApplyWorkerMain(:6081)→run_apply_worker(:5722)→LogicalRepApplyLoop(:4029);并行 apply 五态(:388-394)。

输出插件:pgoutput 注册于 pgoutput.c:261-286;test_decoding 在 contrib/test_decoding/。
