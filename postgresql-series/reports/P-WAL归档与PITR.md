# WAL 归档与时间点恢复(PITR):把 WAL 变成可恢复性

> 源码版本:PostgreSQL master,commit `8c7a74c3239ce29940582643533a190721b395c0`(2026-09-12)。
> 行文约定:所有 `文件:行号` 均为仓库相对路径,已用 grep/Read 实际核对。
> 前情:卷一 03 章讲了 WAL 本体(记录格式、full_page_writes、checkpoint);本章讲 WAL 的"离岸存储"(归档)与"回到过去"(PITR)。

---

## 1. 全景:一次 PITR 的完整旅程

```text
 ┌─────────── 主库(平时)──────────────────────────────────────────────┐
 │ 后端写 WAL → pg_wal 段写满                                          │
 │   └─ XLogWrite 完成 one segment → XLogArchiveNotifySeg 写 .ready    │
 │       (xlog.c:2543;或 archive_timeout 到期,checkpointer.c:695)      │
 │ 归档器 pgarch(AuxiliaryProcess,pgarch.c:221)                       │
 │   └─ 扫 pg_wal/archive_status/*.ready → shell_archive_file()        │
 │      执行 archive_command 拷走 → .ready 改名 .done(pgarch.c:821)     │
 └──────────────────────────────────────────────────────────────────────┘
            │ archive_command(cpio/rsync/云工具…)             ▲
            ▼                                                 │ .done 回执
 ┌─── 归档仓库(磁带/S3/NFS)───┐   ┌─── 灾难:主库整个没了 ───┐
 │ 0000000100000000000000AB …  │   │ DBA 操作:               │
 │ 00000001.history(时间线历史)│   │ 1. 恢复 base backup 到 PGDATA
 └─────────────────────────────┘   │ 2. touch recovery.signal
            │ restore_command       │ 3. 配 recovery_target_time=…
            ▼                       └───────────┬──────────────┘
 ┌─────────── 新库(startup 进程)───────────────▼──────────────────────┐
 │ InitWalRecovery(xlogrecovery.c:459)                                 │
 │  ├─ read_backup_label(:1181)→ 用 backup_label 的 checkpoint 起步     │
 │  ├─ readRecoverySignalFile(:996)→ 进入 archive recovery             │
 │  └─ PerformWalRecovery(:1626)重放循环:                              │
 │      ReadRecord → XLogFileRead(:4218)→ RestoreArchivedFile          │
 │      (xlogarchive.c:55,执行 restore_command)或 pg_wal 本地文件       │
 │      每条记录:recoveryStopsBefore/After 检查恢复目标(:2564/:2717)    │
 │      到达一致性:CheckRecoveryConsistency(:2165)                     │
 │ FinishWalRecovery(:1431)→ 选新时间线 newTLI(tonumber+1,xlog.c:6437) │
 │ writeTimeLineHistory(timeline.c:305)→ 00000002.history 进归档        │
 └──────────────────────────────────────────────────────────────────────┘
```

三个角色、三条 shell 命令:`archive_command`(平时,归档器执行)、`restore_command`(恢复时,startup 进程执行)、`archive_cleanup_command`/`recovery_end_command`(恢复收尾,xlogarchive.c:296)。归档协议本体却不是命令,而是 `.ready`/`.done` 两个空文件。

---

## 2. 归档器专节:pgarch 进程与 .ready/.done 协议

### 2.1 进程模型

归档器是由 postmaster fork 的辅助进程,入口 `PgArchiverMain`(src/backend/postmaster/pgarch.c:221)。它断言自己在归档开启时才会被启动(pgarch.c:247),随后 `LoadArchiveLibrary()`(pgarch.c:272)加载归档实现,再进入 `pgarch_MainLoop`(pgarch.c:313)。主循环极简:干活(`pgarch_ArchiverCopyLoop`,pgarch.c:352)→ 睡在 latch 上,最多 60 秒被 `PGARCH_AUTOWAKE_INTERVAL` 强制醒来巡检一次(pgarch.c:64, 362-365)。后端写满一个 WAL 段时会主动 `SetLatch` 唤醒它(pgarch.c:282-295,由 `XLogArchiveNotify` 触发)。

### 2.2 .ready/.done 文件协议

协议的"生产端"不在归档器,而在写 WAL 的正常路径:当一个段被填充完毕并 fsync 后,`XLogWrite` 调用 `XLogArchiveNotifySeg`(src/backend/access/transam/xlog.c:2543),最终落到 `XLogArchiveNotify`(src/backend/access/transam/xlogarchive.c:446):

```c
/* xlogarchive.c:436-452(节选) */
/*
 * The name of the notification file is the message that will be picked up
 * by the archiver, e.g. we write 0000000100000001000000C6.ready
 * and the archiver then knows to archive XLOGDIR/0000000100000001000000C6,
 * then when complete, rename it to 0000000100000001000000C6.done
 */
void
XLogArchiveNotify(const char *xlog)
{
	...
	/* insert an otherwise empty file called <XLOG>.ready */
	StatusFilePath(archiveStatusPath, xlog, ".ready");
```

消费端在归档器:`pgarch_readyXlog`(pgarch.c:648)扫描 `pg_wal/archive_status` 目录(pgarch.c:695),只认 `.ready` 后缀(pgarch.c:714)。为减少目录扫描,一次最多收集 64 个文件名(`NUM_FILES_PER_DIRECTORY_SCAN`,pgarch.c:84)进一个小顶堆(pgarch.c:126-133),按优先级排序:`ready_file_comparator`(pgarch.c:784)让**时间线历史文件永远最优先**(pgarch.c:791-793),其余按文件名字典序=时间先后。归档成功后 `pgarch_archiveDone`(pgarch.c:821)把 `.ready` **非持久地** rename 成 `.done`(pgarch.c:830-836)——崩溃后 `.ready` 重现是允许的,因此归档命令必须容忍重复归档(幂等)。

### 2.3 archive_command 的执行链

```c
/* pgarch.c:605-606,经 sigsetjmp 包装的异常保护 */
	/* Archive the file! */
	ret = ArchiveCallbacks->archive_file_cb(archive_module_state,
											xlog, pathname);
```

`archive_file_cb` 默认指向 shell 归档模块 `shell_archive_file`(src/backend/archive/shell_archive.c:58):先把 `%f`(文件名)/`%p`(路径)占位符替换进命令(shell_archive.c:71),然后一次 `system()` 调用(shell_archive.c:81)。退出码非零且非信号 → 只记 LOG、本轮重试;被信号杀死 → FATAL 让 postmaster 重启归档器(shell_archive.c:94)。每轮循环内单文件最多重试 `NUM_ARCHIVE_RETRIES=3` 次(pgarch.c:73, 499-506),之后暂时放弃、等下一轮唤醒再试——**失败从不删除 WAL**,这是归档模型的安全底线。若 `archive_command` 为空,`shell_archive_configured` 返回 false,循环直接告警退出(shell_archive.c:47-55,pgarch.c:428-436)。

回调化的注脚:PG15 起归档实现可插拔(`archive_library`),shell 只是默认模块(pgarch.c:930-931);`archive_command` 与 `archive_library` 同时设置报错(pgarch.c:881-885),SIGHUP 改 `archive_library` 会触发归档器自我重启(pgarch.c:890-906)。

### 2.4 .done 之后的垃圾回收

`.done` 是 checkpoint 删除旧 WAL 段的许可证:`XLogArchiveCheckDone`(xlogarchive.c:567)——有 `.done` 可删;只有 `.ready` 不可删(归档还没成功,还要补建 `.ready` 重试,xlogarchive.c:605-607);确认删除时 `XLogArchiveCleanup` 移除状态文件(xlogarchive.c:714)。另有两个孤儿处理:段文件已被回收但 `.ready` 残留,归档器直接 unlink(pgarch.c:447-476);`archive_timeout` 到期时 checkpointer 强制切段以保低 RPO(src/backend/postmaster/checkpointer.c:695, 731)。

---

## 3. 恢复专节:restore_command、recovery.signal 与恢复目标

### 3.1 信号文件与参数校验

`InitWalRecovery`(src/backend/access/transam/xlogrecovery.c:459)第一步读信号文件(`readRecoverySignalFile`,xlogrecovery.c:996):发现旧版 `recovery.conf` 直接 FATAL(xlogrecovery.c:1005-1009,PG12 起废弃);`standby.signal` 与 `recovery.signal` 被 fsync 后记入状态(xlogrecovery.c:1021-1047),且 standby 优先(xlogrecovery.c:1050-1066)。随后 `validateRecoveryParameters`(xlogrecovery.c:1079):非 standby 模式必须配 `restore_command`,否则 FATAL(xlogrecovery.c:1100-1104);五个恢复目标 GUC 只许设一个,`DetermineRecoveryTargetType` 数出多个即 FATAL(xlogrecovery.c:4816, 4845-4850)。

### 3.2 RestoreArchivedFile:startup 进程里的 restore_command

```c
/* xlogarchive.c:153-178(节选) */
	/* Build the restore command to execute */
	xlogRestoreCmd = BuildRestoreCommand(recoveryRestoreCommand,
										 xlogpath, xlogfname,
										 lastRestartPointFname);
	...
	rc = system(xlogRestoreCmd);
```

`RestoreArchivedFile`(xlogarchive.c:55)关键语义:

- **只在归档恢复中生效**——崩溃恢复直接跳到 `not_available` 用 pg_wal 本地文件(xlogarchive.c:72-73)。
- 每次恢复都写到**同一个固定名字**的临时文件(如 `RECOVERYXLOG`),用完即被下一次覆盖,长恢复不会撑爆磁盘(xlogarchive.c:99-102)。
- 归档副本优先于 pg_wal 同名文件:后者可能是备份拷出来的半截旧版本(xlogarchive.c:82-90)。
- `system()` 返回 0 还要核对文件存在且尺寸正确;standby 下尺寸偏小视为"还在归档途中"降级 DEBUG1,否则 FATAL(xlogarchive.c:209-212)。
- 失败被解释为"归档里没有这个文件=WAL 结束",但如果死因是信号(尤其 SIGINT/SIGQUIT/SIGTERM)则 FATAL/退出,防止把误杀当成"恢复完成"而**悄悄提前开库**(xlogarchive.c:248-270)。
- `%r` 占位符传"最后重启点",供 restore 脚本清理归档中更早的文件(src/common/archive.c:39-60;`%r` 同样用于 `archive_cleanup_command`,xlogarchive.c:321)。

恢复到的段由 `XLogFileRead`(xlogrecovery.c:4218)安家:`RestoreArchivedFile` 成功后 `KeepFileRestoredFromArchive`(xlogarchive.c:359)做 durable rename 进 pg_wal,并强制写 `.done` 防止它被再次归档回去(xlogarchive.c:412-415)。备库/归档双源切换是 `WaitForWALToBecomeAvailable` 的状态机:归档 → pg_wal → 流复制 → 重扫时间线 → 睡 `wal_retrieve_retry_interval` 再循环(xlogrecovery.c:3550, 3562-3586;来源枚举 xlogrecovery.c:217-219)。

### 3.3 恢复目标语义与一致性

恢复目标五兄弟在重放循环里逐条检查(`PerformWalRecovery` 主循环 xlogrecovery.c:1724,入口检查 `recoveryStopsBefore` xlogrecovery.c:1770):

| 目标 | 判定点 | 行号 |
|---|---|---|
| `recovery_target=immediate` | 一到一致性点立即停 | xlogrecovery.c:2580-2588 |
| `recovery_target_lsn` | exclusive: `ReadRecPtr >= target`;inclusive 走 after | xlogrecovery.c:2594-2606, 2762-2772 |
| `recovery_target_xid` | 只看 COMMIT/ABORT 记录的 xid(inclusive 决定停在该事务前/后) | xlogrecovery.c:2609, 2650, 2826 |
| `recovery_target_time` | 取 commit/abort 记录时间戳比较 | xlogrecovery.c:2668-2680 |
| `recovery_target_name`(restore point) | 匹配 `XLOG_RESTORE_POINT` 记录 | xlogrecovery.c:2738-2754 |

约束与细节:xid/time 目标只在事务提交/中止记录上判定(xlogrecovery.c:2609),所以"停在某事务前"实际是停在它的 commit 记录前;所有目标都受 `recovery_target_inclusive` 调节;目标检查只在 `ArchiveRecoveryRequested` 时生效,崩溃恢复忽略之(xlogrecovery.c:2572-2577);配合 `recovery_min_apply_delay` 还能延迟应用(xlogrecovery.c:2973)。

**一致性(reachedConsistency)** 是 PITR 的隐形门槛,由 `CheckRecoveryConsistency`(xlogrecovery.c:2165)判定:崩溃恢复没有 minRecoveryPoint,永远不算"一致"(xlogrecovery.c:2174);归档恢复要满足 `minRecoveryPoint <= lastReplayedEndRecPtr` 且非 `backupEndRequired`,才跑 `XLogCheckInvalidPages`、置 `reachedConsistency` 并通知 postmaster(xlogrecovery.c:2218-2240)。流式备份(`BACKUP METHOD: streamed`)额外要求重放到 `XLOG_BACKUP_END` 记录:`do_pg_backup_stop` 写入该记录(src/backend/access/transam/xlog.c:9999-10004),恢复端 `xlogrecovery_redo` 核对 `backupStartPoint` 匹配后置 `backupEndPoint`(xlogrecovery.c:2091-2114),随后 `CheckRecoveryConsistency` 调 `ReachedEndOfBackup` 收尾(xlogrecovery.c:2189-2210)。一致性点是所有恢复目标允许生效的最早位置(`immediate` 便是"一到一致性就停")。停机原因会被 `getRecoveryStopReason`(xlogrecovery.c:2877)写进新时间线历史。

---

## 4. base backup 专节:pg_basebackup 服务端与 backup_label

### 4.1 服务端流程(简)

walsender 收到 `BASE_BACKUP` 命令后进入 `SendBaseBackup`(src/backend/backup/basebackup.c:997,分派点 src/backend/replication/walsender.c:2254-2257),组装 bbsink 管道(流式输出/限速/压缩/进度,basebackup.c:1041-1063)后由 `perform_base_backup`(basebackup.c:242)驱动,核心三步:

1. `do_pg_backup_start`(basebackup.c:269 → xlog.c:9549):检查 wal_level(xlog.c:9561-9565),`runningBackups++` **强制备份期间全页写**(xlog.c:9597,动机见 §4.2),强制切段(xlog.c:9628-9629)+ checkpoint(xlog.c:9653-9654),记下 checkpoint 位置作为起点。
2. 发数据:`bbsink_begin_backup`(basebackup.c:328)→ base.tar(basebackup.c:347)→ **先写 backup_label**(basebackup.c:350-352,内容由 `build_backup_content` 生成)→ 可选 tablespace_map(basebackup.c:355-359)→ `sendDir` 遍历数据文件(basebackup.c:361)→ **最后发 pg_control**(basebackup.c:368-373)。
3. `do_pg_backup_stop`(basebackup.c:385 → xlog.c:9871):写 `XLOG_BACKUP_END` 记录(xlog.c:9999-10004),再强制切段使备份随当前段归档即生效(xlog.c:10016),写 backup history file(xlog.c:10023-10050);`waitforarchive=true` 时轮询 `XLogArchiveIsBusy` 直到"最后一段 WAL + history file"都归档完成(xlog.c:10074-10121)。

### 4.2 backup_label:恢复的信任锚

```text
START WAL LOCATION: 0/2000028 (file 000000010000000000000002)   ← xlogbackup.c:46
CHECKPOINT LOCATION: 0/2000060                                  ← xlogbackup.c:60
BACKUP METHOD: streamed                                         ← xlogbackup.c:62
BACKUP FROM: primary                                            ← xlogbackup.c:63-64
START TIME / LABEL / START TIMELINE                             ← xlogbackup.c:65-67
```

为什么需要它:备份完成时 pg_control 里的 checkpoint 可能**晚于**备份实际起点(数据文件是分散读取的,而 pg_control 最后发)。若按 pg_control 重放,会跳过"checkpoint 之前、数据文件更旧"的那段 WAL,得到撕裂状态。所以恢复时 `read_backup_label`(xlogrecovery.c:1181)解析的 CHECKPOINT LOCATION **覆盖 pg_control**(xlogrecovery.c:548-583,注释在 1164-1169):

```c
/* xlogrecovery.c:1164-1169(节选) */
 * If we see a backup_label during recovery, we assume that we are recovering
 * from a backup dump file, and we therefore roll forward from the checkpoint
 * identified by the label file, NOT what pg_control says.  This avoids the
 * problem that pg_control might have been archived one or more checkpoints
 * later than the start of the dump, and so if we rely on it as the start
 * point, we will fail to restore a consistent database state.
```

三个字段各有后效:`BACKUP METHOD: streamed` 置 `backupEndRequired`(xlogrecovery.c:1246-1250),强制重放到 XLOG_BACKUP_END 才算一致;`BACKUP FROM: standby` 置 `backupFromStandby`,恢复端要求 pg_control 状态吻合并以 minRecoveryPoint 作为 backupEndPoint(xlogrecovery.c:948-957);找到 checkpoint 记录失败则 FATAL,提示里明确警告"删除 backup_label 会导致集群损坏"(xlogrecovery.c:615-621)。此外有 backup_label 即直接进 archive recovery(xlogrecovery.c:558);没有它,只有在 pg_control 提供了 minRecoveryPoint/backupEndPoint 等线索时才直接进归档恢复,否则先做崩溃恢复(xlogrecovery.c:691-717)——这正是"用文件系统快照却没调 pg_backup_start"的兜底路径。

### 4.3 full_page_writes 与 PITR(呼应卷一 03 章)

卷一讲过:FPW 保证 checkpoint 之后每页首次修改都会在 WAL 里留全页镜像,崩溃恢复可以只靠 WAL+旧页重建。PITR 把这个前提拉长:数据文件来自 base backup 时刻(可能远早于任何现存归档段),重放跨度可以是天级。两个机制保证这条长链成立:

- 备份期间强制 FPW:`runningBackups > 0` 使 `doPageWrites` 恒真(xlog.c:913),注释原文解释了"撕裂页"问题——备份进程可能读到正在写的半页,只有全页镜像能修复(xlog.c:9576-9587)。
- 起点对齐:backup 起点 = 强制 checkpoint 的 redo 位置,该位置之后的每个脏页首改都有 FPW 镜像,所以"备份文件 + 从 redo 起重放任意长 WAL"收敛到一致状态。

反例兜底:从 standby 备份时若备份窗口内出现过 FPW=off 的 WAL,直接判备份损坏(xlog.c:9974-9986)。

---

## 5. 时间线专节:history 文件与恢复分叉(简)

- 归档恢复结束,`StartupXLOG` 选新时间线:`newTLI = findNewestTimeLine(recoveryTargetTLI) + 1`(src/backend/access/transam/xlog.c:6437-6440),删除信号文件防止重启后又进恢复(xlog.c:6451-6460),然后 `writeTimeLineHistory` 写 `新TLI.history`(xlog.c:6468-6469;timeline.c:305)——内容=父历史全文+一行"switched at LSN X, reason Y"。
- history 文件经由 `RestoreArchivedFile` 取父历史(timeline.c:338-340)并**最高优先级归档**(pgarch.c:791-793;xlogarchive.c:471-483),让归档仓库尽快"占坑",防止两个 promote 出的节点选中同一条时间线。
- 重放中遇到时间线切换记录要过 `checkTimeLineSwitch` 校验(xlogrecovery.c:2368-2384);`recovery_target_timeline=latest` 沿 history 树找最新分支(validateRecoveryParameters,xlogrecovery.c:1146-1150);backup/pg_control 的 checkpoint 必须落在目标时间线的历史内,否则 FATAL(xlogrecovery.c:804-823)。
- 相关 API:`readTimeLineHistory`(timeline.c:77)、`existsTimeLineHistory`(timeline.c:223)、`tliOfPointInHistory`(timeline.c:545)、`tliSwitchPoint`(timeline.c:573)。与流复制的衔接见卷二 10 章,此处只引用不展开。

---

## 6. 设计动机

**为什么归档用 shell 命令而不是内置存储?** PG 核心团队无法内置 S3/磁带/NFS 每一种存储;`archive_command` 把"传到哪里"外包给用户的一条 shell 命令,核心只负责两件难而本质的事:①不丢——WAL 在 `.done` 之前绝不删除(xlogarchive.c:567-608),失败可无限重试;②有序——按文件名/优先级串行归档,维持恢复链(pgarch.c:634-638)。命令接口天然幂等容错(重复归档无害),代价是同步性差(整段 16MB 粒度),于是 `archive_timeout` 补刀低写入量场景。PG15 的 `archive_library` 把同一契约回调化,shell 退为默认模块(pgarch.c:916-951)。

**为什么 backup_label 是"信任锚"?** 恢复起点必须精确到"备份开始那一刻数据文件的真实状态",而这个状态只被备份发起时的 checkpoint 忠实记录;pg_control 是备份**末期**的快照,用它起步必然跳过需要重放的 WAL(§4.2)。backup_label 把这条事实从备份进程单方面"钉"进数据目录,恢复代码无条件信任它——甚至信任到"有它在就强制重放"(xlogrecovery.c:591 `InRecovery = true`)。它也是用户最容易犯的错:手工搭 PITR 后删掉 backup_label,服务器看似正常启动,数据却已撕裂,所以源码在错误提示里两次反复警告(xlogrecovery.c:607-610, 618-621)。

**PITR 与逻辑复制的恢复语义差在哪?** PITR(物理)恢复的是"集群字节级状态在 T 时刻的快照":重放幂等、可任意回退、停止点之后的一切作废,代价是必须换新时间线、旧主不能直接复活。逻辑复制(卷二 10 章)传递的是"变更流":订阅端起点是 replication slot 的确认 LSN,只能向前 apply,不能"回到昨天"——它没有停止点语义,也没有时间线分叉(时间线是物理 WAL 的概念)。一句话:物理恢复让你重写历史(然后分叉),逻辑复制只能追历史。

---

## 7. FAQ 素材

1. **归档的最小单位是什么?** 整个 WAL 段文件(默认 16MB),不是单条记录。`.ready` 在段写满时产生(xlog.c:2543),也可由 `archive_timeout` 强制切段产生(checkpointer.c:695)。
2. **archive_command 失败会怎样?** 该文件重试 3 次/轮后暂停本轮(pgarch.c:73, 499-506),WAL 保留在 pg_wal 等下轮;持续失败 → pg_wal 涨满 → PANIC。观测用 `pg_stat_archiver`。
3. **.done 文件谁负责删?** checkpoint 回收 WAL 段时经 `XLogArchiveCheckDone` 确认后由 `XLogArchiveCleanup` 一并删除(xlogarchive.c:567, 714)。
4. **忘了放 recovery.signal,只有 backup_label,会进归档恢复吗?** 会——读到 backup_label 就直接 `InArchiveRecovery = true`(xlogrecovery.c:548-558);但没有 backup_label 时,只有 pg_control 带有效 minRecoveryPoint 等线索才进,否则先崩溃恢复(xlogrecovery.c:708-717)。
5. **手工删 backup_label 会怎样?** 服务器可能"成功"启动,但从 pg_control 的较新 checkpoint 起步,跳过备份期 WAL,静默损坏;源码 errhint 明确警告(xlogrecovery.c:607-610)。
6. **restore_command 返回非零就是错吗?** 恰恰相反:非零且非信号=常规的"WAL 结束"信号;被信号杀死才 FATAL(xlogarchive.c:248-270)。所以 restore 脚本必须对"文件不存在"返回普通非零退出码。
7. **恢复目标为什么"停在某事务前"却看到它之后的别的提交?** xid/time 目标只在 COMMIT/ABORT 记录上判定(xlogrecovery.c:2609),且一致点之前的所有 WAL 必须完整重放——恢复不能停在一致性点之前。
8. **一致性点如何判定?** `minRecoveryPoint <= lastReplayedEndRecPtr`;流式备份还要等 XLOG_BACKUP_END(backupEndRequired)(xlogrecovery.c:2218-2240, 2091-2114)。在此之前即使 recovery_target_lsn 已过也不停。
9. **archive_command 和 archive_library 能同时设吗?** 不能,启动/重载均报错(pgarch.c:920-924, 881-885);SIGHUP 改 library 会重启归档器进程(pgarch.c:890-906)。
10. **恢复完成后 recovery.signal 谁删?** 恢复收尾 `durable_unlink`(xlog.c:6457-6460),防止下次崩溃又被拉回归档恢复。
11. **时间线 history 文件为什么归档最优先?** 让 promote 后的 history 尽快进仓库占坑,防止后续 standby 再选出同号时间线(xlogarchive.c:471-483, pgarch.c:791-793)。
12. **归档器多久醒一次?** 有 WAL 时被 latch 立即唤醒;空闲时 60 秒巡检(pgarch.c:64),防止漏文件。

## 8. 深挖

1. **XLOG_BACKUP_END 的闭环**:stop 时写入含 startpoint 的记录(xlog.c:9999-10004)→ 恢复端匹配 `backupStartPoint` 后置 `backupEndPoint`(xlogrecovery.c:2091-2114)→ `ReachedEndOfBackup` 清账。这条链回答"流式备份为什么必须重放到备份结束"。
2. **非持久 rename 的幂等契约**:`pgarch_archiveDone` 故意不 fsync(pgarch.c:830-836),崩溃后 `.ready` 复活、段被重复归档;同理 `XLogArchiveNotify` 也会在 checkpoint 补建丢失的 `.ready`(xlogarchive.c:605-607)。整个协议把"至少一次投递"做成了显式设计。
3. **从 standby 备份的特殊一致性**:无 end record,用 pg_control 的 minRecoveryPoint 当 backupEndPoint(xlog.c:9989-9993;xlogrecovery.c:948-957);备份中途被 promote 直接判废(xlog.c:9930-9936);FPW 缺失检测靠 `lastFpwDisableRecPtr`(xlog.c:9974-9986)。
4. **恢复时"归档优先于本地"**:即使 pg_wal 有同名段也先取归档副本,因为本地可能是备份带回来的半截文件(xlogarchive.c:82-90)——与"归档不可得再退回本地"(xlogarchive.c:274-282)共同构成双源兜底。
5. **备份起点前强制切段防旧时间线**:pg_backup_start 先 `RequestXLogSwitch`,避免紧随 PITR 之后的备份把旧时间线页面带进首段(xlog.c:9613-9629)——时间线、归档、备份三个子系统的交叉点。

---

## 9. 写作要点速查表

| 函数/机制 | 位置 | 一句话 |
|---|---|---|
| PgArchiverMain | pgarch.c:221 | 归档器入口,加载归档库后进主循环 |
| pgarch_ArchiverCopyLoop | pgarch.c:384 | 取 .ready→归档→置 .done,3 次重试(pgarch.c:499) |
| pgarch_readyXlog / ready_file_comparator | pgarch.c:648 / 784 | 64 文件堆排序;history 最优先 |
| pgarch_archiveDone | pgarch.c:821 | .ready→.done 非持久 rename |
| XLogArchiveNotify | xlogarchive.c:446 | 段满时写 .ready(xlog.c:2543 调用) |
| shell_archive_file | shell_archive.c:58 | 替换 %f/%p 后 system() 执行 archive_command |
| XLogArchiveCheckDone | xlogarchive.c:567 | checkpoint 删 WAL 段前查 .done |
| RestoreArchivedFile | xlogarchive.c:55 | 恢复端执行 restore_command(system(),:178) |
| KeepFileRestoredFromArchive | xlogarchive.c:359 | 归档段 durable rename 进 pg_wal 并置 .done |
| readRecoverySignalFile | xlogrecovery.c:996 | recovery.conf 拒绝;standby/recovery.signal(:1021/:1035) |
| read_backup_label | xlogrecovery.c:1181 | 解析 START/CHECKPOINT LOCATION,覆盖 pg_control |
| InitWalRecovery | xlogrecovery.c:459 | 恢复初始化;backupStartPoint=minRecoveryPoint(:945) |
| PerformWalRecovery | xlogrecovery.c:1626 | 重放主循环;目标检查 :1770 |
| CheckRecoveryConsistency | xlogrecovery.c:2165 | 一致性判定 + 热备开门(:2247) |
| recoveryStopsBefore/After | xlogrecovery.c:2564 / 2717 | 五种恢复目标停止语义 |
| do_pg_backup_start/stop | xlog.c:9549 / 9871 | 备份事务:XLOG_BACKUP_END(:10004)+等归档(:10089) |
| build_backup_content | xlogbackup.c:29 | backup_label 全部字段(:46-67) |
| SendBaseBackup / perform_base_backup | basebackup.c:997 / 242 | BASE_BACKUP 服务端;label 先发(:350) |
| writeTimeLineHistory | timeline.c:305 | 新时间线历史文件;调用点 xlog.c:6468 |
| XLogArchivingActive 宏 | xlog.h:115-119 | archive_mode on/always 语义 |
