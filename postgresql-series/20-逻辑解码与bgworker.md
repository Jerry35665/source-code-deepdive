# 第 20 章 · 逻辑解码与后台工作者:PG 的可编程扩展面(卷五卷末)

> 基线:commit `8c7a74c`。行号以 src/backend/replication/logical/、src/backend/postmaster/bgworker.c 为准。卷二 10 章讲了逻辑复制概览——本章展开**逻辑解码的内部机制**与 **bgworker 通用框架**。

## 20.0 全景:逻辑解码与 bgworker 的定位

```
WAL → 逻辑解码(ReorderBuffer 按 xid 重排 → snapshot builder → 输出插件)
  → 订阅端 apply worker(逻辑复制)
bgworker 框架 → autovacuum worker / 并行查询 worker / 逻辑复制 apply worker
  → 任何扩展的后台任务
```

## 20.1 逻辑解码:ReorderBuffer 与 snapshot builder

**解码入口** LogicalDecodingProcessRecord(decode.c:88-124):先 ReorderBufferAssignChild 挂子事务再按 rmgr 分发。xact_decode(:213)在非 FULL_SNAPSHOT 时直接返回(:224);DecodeCommit(:688)→SnapBuildCommitTxn(:703)→ReorderBufferCommit(:755)。

**ReorderBuffer**(reorderbuffer.c 文件头注释 :14-37):WAL 序→按 commit 重排;子事务用 binaryheap 按 LSN 归并,大事务 spool 磁盘。ReorderBufferQueueChange(:811)入队后调 ReorderBufferCheckMemoryLimit(:866);超过 logical_decoding_work_mem 时流式或 spill(:3962-4001);ReorderBufferSerializeTXN(:4029);ReorderBufferFinishPrepared(:3017)处理 2PC。

**snapshot builder 四态状态机**(snapbuild.c:63-97):START→BUILDING_SNAPSHOT→FULL_SNAPSHOT→CONSISTENT(snapbuild.h:35-58)。`SnapBuildFindSnapshot`(:1244)三条路径:(a) 无运行事务直接 CONSISTENT(:1300);(b) 磁盘恢复(:1330);(c) START→BUILDING(:1350)。**"先见 commit 后见变更"难题**(:1341-1348 注释):running xacts 可能已写入 commit 记录——只能以 nextXid 为界等待。

**输出插件**:CreateInitDecodingContext(logical.c:408)取 GetOldestSafeDecodingTransactionId(:505)做 xmin horizon;LoadOutputPlugin(:815)加载 `_PG_output_plugin_init`(begin/change/commit 三回调 :828-833);pgoutput 是逻辑复制的内置插件;test_decoding 在 contrib/test_decoding/(test_decoding.c:131-139)。

## 20.2 逻辑复制 worker:订阅端

ApplyWorkerMain(worker.c:6081)→run_apply_worker(:5722:origin 建立与 walrcv_connect :5746-5763)→LogicalRepApplyLoop(:4029);apply_handle_begin(:1248)/apply_handle_commit(:1271,commit_lsn 校验 :1277);并行 apply 五态(:388-394):TRANS_LEADER_APPLY/SERIALIZE/SEND_TO_PARALLEL/PARTIAL_SERIALIZE/PARALLEL_APPLY,决策函数 get_transaction_apply_action(:6489);launcher 经 RegisterDynamicBackgroundWorker 注册(launcher.c:557),ApplyLauncherMain(:1207)。

## 20.3 bgworker 框架:通用后台任务

**BackgroundWorker 结构**(bgworker.h:96-108):bgw_name/type/flags/start_time/restart_time/library_name/function_name/main_arg/extra/notify_pid;三种启动时机(:86-88);flags(:53-75)含 BGWORKER_SHMEM_ACCESS(必需)、BGWORKER_BACKEND_DATABASE_CONNECTION(连库)、BGWORKER_CLASS_PARALLEL(并行)。

**静态注册**:RegisterBackgroundWorker(:962)仅 postmaster 内(:971),须在 shmem init 前(:997);**动态注册**:RegisterDynamicBackgroundWorker(:1068)找空槽(:1117);SanityCheckBackgroundWorker(:658):DB 连接不允许 PostmasterStart(:679),并行 worker 不可重启(:718);BackgroundWorkerStateChange(:272)由 postmaster 经 SIGUSR1 感知(postmaster.c:3827);maybe_start_bgworkers(:4293)每次最多 100 个(:4295)。

内置 worker 表 InternalBGWorkers(bgworker.c:127-170):ApplyWorkerMain/ParallelWorkerMain 等——**PG 自身的辅助进程也走 bgworker 框架**。

## 20.4 设计动机

1. **为什么逻辑解码需要 ReorderBuffer**:WAL 按 LSN 序(物理序),输出必须按 commit 序(逻辑序)——大事务的所有变更必须缓存到 commit 才能输出;**缓冲在内存不够时 spool 到磁盘**——"内存不够就落盘"的 TSDB 级自律;
2. **为什么 bgworker 不能用线程**:01 章进程公理——隔离优先于共享;bgworker 是轻量进程,共享内存通过 DSM 显式申请;
3. **为什么输出插件是动态加载**:输出格式的多样性(JSON/wal2json/自定义)——**接口与实现分离**,核心只定义回调协议;
4. **快照 builder 的四态**:从"什么都不知道"到"可以输出一致变更"是一个渐进过程——每一步都等前一步的确认,不跳。

## 20.5 FAQ

**Q1:逻辑解码为什么需要快照 builder?**
(:1341-1348):WAL 只含"变更了什么",不含"变更时哪些事务还在运行"——输出一致性需要重建快照。

**Q2:ReorderBuffer 的大事务怎么处理?**
超过 logical_decoding_work_mem 时 spool 到磁盘(:3962-4001):内存可控但延迟增大。

**Q3:逻辑解码的起点怎么定?**
(:408 CreateInitDecodingContext):从 GetOldestSafeDecodingTransactionId(:505)开始——保证输出完整事务。

**Q4:bgworker 能连数据库吗?**
能:BGWORKER_BACKEND_DATABASE_CONNECTION flag;启动时机决定数据库是否已就绪(:4247 PM_RUN 才允许 RecoveryFinished)。

**Q5:bgworker 崩溃会怎样?**
restart_time>0 则自动重启;并行 worker 不可重启(:718)。

**Q6:逻辑复制的并行 apply 怎么选?**
(:6489):大事务并行(多 worker),小事务串行——按事务大小自适应。

**Q7:2PC 的逻辑解码?**
ReorderBufferFinishPrepared(:3017):prepared 事务的 commit/abort 均可解码。

**Q8:输出插件可以动态卸载吗?**
不行:有活跃订阅槽时不可卸载——与 Git 模块(有依赖不卸)同理。

**Q9:bgworker 的注册为什么分静态与动态?**
静态=postmaster 启动前(内置),动态=运行时(扩展);安全性约束不同(:658)。

**Q10:每个 group 最多几个 bgworker?**
(:4293-4295):每次批量启动最多 100 个——防 postmaster 被注册风暴压垮。

## 20.6 小结与卷五卷末语

本章结论:**逻辑解码="ReorderBuffer 按 commit 重排+snapshot builder 四态+输出插件接口";bgworker="轻量进程+声明式 flags+postmaster 统一调度"**。

至此《PostgreSQL 深读》卷五完(19-20:全文检索与JSONB/逻辑解码与bgworker,基线 commit 8c7a74c)。PG 五卷合计 20 章+20 份报告。深挖方向:

1. SnapBuildSerialize(:1503)在磁盘快照的格式与版本兼容;
2. 并行 apply 的五态(:388-394)在超大事务的 worker 分配;
3. spill 文件(:4029)在高速写入的 IO 冲击;
4. bgworker 的 restart_time 在不同崩溃类型的重启策略;
5. 输出插件的 AAD(context)在数据加密复制的合规用途。

— 《PostgreSQL 深读》卷五完。AI 编码助手:GLM-5.3-Flash。
