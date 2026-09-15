# 第 17 章 · WAL 归档与 PITR:可恢复性的完整链

> 基线:commit `8c7a74c`。行号以 src/backend/postmaster/pgarch.c、src/backend/access/transam/xlogarchive.c、xlogrecovery.c 为准。卷一 03 章讲过 WAL 本体与组提交——本章讲"把 WAL 变成任意时间点可恢复性"的完整链。

## 17.0 全景:一次 PITR 的完整旅程

```
base backup(pg_basebackup)→ 持续归档(pgarch 每 60s 巡检 .ready)
  → 崩溃 → 恢复(restore.signal):
recovery.signal(xlogrecovery.c:996)→ read_backup_label(:1181)的 CHECKPOINT LOCATION 覆盖 pg_control
  → PerformWalRecovery(:1626)重放:段经 XLogFileRead(:4218)
     → RestoreArchivedFile(xlogarchive.c:55)执行 restore_command
  → 恢复目标判定(:2564/:2717)→ 一致性门槛(:2165)→ 新时间线 → 开库
```

## 17.1 归档器:.ready/.done 文件协议

辅助进程 PgArchiverMain(pgarch.c:221),60s 空闲巡检(:64);pgarch_readyXlog(:648)扫 `pg_wal/archive_status/*.ready`,64 文件堆排序、history 文件最优先(:784-793);shell_archive_file(:58)替换 %f/%p 后 **system() 执行 archive_command**(shell_archive.c:81);成功后 pgarch_archiveDone(:821)**非持久 rename 为 .done**——崩溃后 .ready 可复活,故归档须幂等;每轮单文件重试 3 次(:73,:499-506)。`.done` 是 checkpoint 删段的许可证(XLogArchiveCheckDone,xlogarchive.c:567);`.ready` 生产端在 WAL 写满的 fsync 点(XLogArchiveNotifySeg,xlog.c:2543),archive_timeout 兜底(checkpointer.c:695)。**归档命令就是一次 system()**,非信号失败仅 LOG(shell_archive.c:81)——archive_command 的可靠性完全托付给 DBA 的命令质量。

## 17.2 PITR:backup_label 与恢复目标

`recovery.signal`/`standby.signal`(readRecoverySignalFile,xlogrecovery.c:996;recovery.conf 直接 FATAL)→**read_backup_label(:1181)的 CHECKPOINT LOCATION 覆盖 pg_control**——PITR 的信任锚。恢复目标五种(immediate/LSN/xid/time/name)在 recoveryStopsBefore/After(:2564/:2717)判定:immediate/LSN 在任意记录,xid/time **只看 COMMIT/ABORT**(:2609)。一致性门槛 CheckRecoveryConsistency(:2165):minRecoveryPoint 达成;**流式备份还要等 XLOG_BACKUP_END**(:2091-2114)——卷一 03 章 FPW(:10004 写入)的兑现前提:备份期间 runningBackups>0 强制全页写(:9597,:913),这是"从 base backup 起重放"成立的物理前提。restore_command 被信号杀死必须 **FATAL**(:265-270)——防止误判"WAL 结束"开库。

## 17.3 时间线:恢复的分叉与再出发

恢复完成后选新时间线:findNewestTimeLine+1(xlog.c:6437)、writeTimeLineHistory(timeline.c:305)、删 signal 文件(:6453/:6456)——**每次 PITR 都产生新时间线分支**,旧时间线的归档保留(history 文件)使"再恢复到旧分叉"仍可行。archive_command 在 standby 上不运行(xlogarchive.c:72-73:restore_command 仅归档恢复生效,崩溃恢复只用 pg_wal)。

## 17.4 设计动机

1. **为什么归档用 shell 命令而非内置存储**:归档目标的多样性(S3/NFS/tape)——**一行 shell 的表达力**胜过 N 种内置;代价是可靠性托付给命令;
2. **backup_label 是信任锚**(:1181):它声明"从哪个 checkpoint 起重放才完整"——覆盖 pg_control 是刻意的(备份时的状态才是真相);
3. **PITR 目标只看 COMMIT**(:2609):恢复到"事务一半"是无意义的——原子性在恢复中同样成立;
4. **至少一次的归档协议**(:830-836):.done 非持久 rename=崩溃后重发,要求归档命令幂等——与 Git 归档/队列的幂等要求同族。

## 17.5 FAQ

**Q1:archive_command 失败会怎样?**
重试 3 次后跳过本轮(:499-506):.ready 保留,下轮再试——永不放弃也不阻塞写入。

**Q2:PITR 恢复到一半失败会开库吗?**
不会:restore 被信号杀死必须 FATAL(:265-270)——防"假完成"开库造成数据分歧。

**Q3:backup_label 丢了会怎样?**
(:1181):pg_control 的位置可能早于备份起点→重放缺口→数据损坏——**备份必须带 label**。

**Q4:为什么流式备份要多等 XLOG_BACKUP_END?**
(:2091-2114):备份期间修改的页被 FPW 全页写进 WAL——重放必须越过这些页的完整版本。

**Q5:恢复后还能继续归档吗?**
新时间线分支(:6437/:305):timeline history 记录分叉,归档按新 TLI 继续。

**Q6:archive_timeout=0 会怎样?**
低写入库的尾部 WAL 不归档(:695 兜底失效):恢复目标可能差最后几分钟。

**Q7:恢复目标 time 精确到什么?**
COMMIT 记录的时间(:2609):事务粒度,非语句粒度。

**Q8:standby 模式与 PITR 的入口差异?**
standby.signal→只读热备;recovery.signal→恢复到目标后开库(:996)。

**Q9:归档会阻塞写入吗?**
不会:归档器独立进程(.ready 文件异步)——写入只产生 .ready 通知。

**Q10:pg_control 与 backup_label 冲突听谁的?**
backup_label(:1181):PITR 场景备份的 checkpoint 才是真相。

## 17.6 小结与深挖方向

本章结论:**归档/PITR=".ready/.done 至少一次协议+backup_label 信任锚+恢复目标事务粒度+时间线分叉"**。深挖:

1. .ready 堆排序(:784-793)在归档积压时的顺序保证;
2. summary: 流式备份的 XLOG_BACKUP_END(:2091)与 fpw 的完备性证明;
3. timeline history 文件的格式与多级分叉(2_1.history);
4. restore_command 的 S3 实现方(外部工具)的幂等要求;
5. 恢复目标 name(restore point)的创建与命名语义。

> 下一章:并行查询——进程模型的并行化。
