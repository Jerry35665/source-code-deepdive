# 第 21 章 · 逻辑复制 apply worker:订阅端的事务重放

> 基线:commit `8c7a74c`。行号以 src/backend/replication/logical/worker.c、launcher.c 为准。卷二 10 章讲了逻辑解码——本章专讲**订阅端的 apply worker**。

## 21.0 全景:apply 的完整链

```
launcher(launcher.c:1207)→ ApplyWorkerMain(worker.c:6081)
  → walrcv_connect(:5746-5763)→ LogicalRepApplyLoop(:4029)
  → apply_dispatch(:3822,17 种消息按首字节分发)
  → 行变更 ExecSimpleRelation*(worker.c:2782/:3017/:3198)
  → commit:先记 origin 进度再提交+store_flush_position(:2570-2583)
  → send_feedback(:4345)只报本地已落盘的远端 LSN
```

## 21.1 并行 apply:五态

TransApplyAction 五态(worker.c:385-395):LEADER_APPLY/SERIALIZE/SEND_TO_PARALLEL/PARTIAL_SERIALIZE/PARALLEL_APPLY;get_transaction_apply_action(:6488-6529)是**spool/stream/并行的唯一判定点**。stream_commit 分态收尾(:2430-2538):spool 回放(:2459)/leader 放行保序(:2476/:2496)/PA 置 FINISHED(:2516)。

## 21.2 冲突处理:无自动仲裁

冲突八类型(conflict.h:31-62);**UPDATE/DELETE 缺行只记 LOG 照常继续**(worker.c:3040-3046/:3206);INSERT 撞唯一约束直接 ERROR→worker 重启重放死循环(execReplication.c:882,插入后才查索引省开销);origin-differs 是软冲突(:2989-3003)。解法三件套:修数据、ALTER SUBSCRIPTION SKIP(:6177-6199+:6226-6303)、PG18 的 pg_conflict_log 表(conflict.c:153)。

## 21.3 table sync:独立 worker

表状态机 i→d→f→w→c→s→r(pg_subscription_rel.h:66-78);tablesync 用 RR 快照+CRS_USE_SNAPSHOT slot 保 COPY 与增量一致(tablesync.c:1413-1431);SYNCWAIT→CATCHUP 与 SYNCDONE→READY 由 apply worker 侧推进(:494-503/:426-473)。两阶段三态 PENDING→ENABLED 需全表 READY(worker.c:5805-5824)。

## 21.4 设计动机

1. **为什么 apply 是独立进程**:隔离解码/应用与发布端的故障域——apply worker 崩溃不影响发布端;独立连接(独立 walrcv)独立重连;
2. **为什么冲突不自动仲裁**:冲突是业务语义(唯一约束冲突可能是业务正确)——**仲裁权交给 DBA**(SKIP/修数据/pg_conflict_log);
3. **origin 进度先于提交**(:2570-2583):崩溃后 origin 告诉 apply"从哪重放"——与 04 章 commit 进度的模式呼应;
4. **v1-v4 协议版本协商**(logicalproto.h:41-45):新旧 PG 版本间的逻辑复制兼容——与 Git 传输协议的版本协商同族。

## 21.5 FAQ

**Q1:apply worker 冲突了怎么跳过?**
ALTER SUBSCRIPTION SKIP(:6177-6199):跳过出错的事务 LSN。

**Q2:并行 apply 的锁死锁怎么检测?**
LA/PA 间 lmgr stream lock 制造等待边(applyparallelworker.c:60-116)。

**Q3:表同步期间目标表可写吗?**
不可:COPY 阶段表锁——大表的初始同步阻塞写入。

**Q4:两阶段提交的逻辑复制?**
支持:PENDING→ENABLED 需全表 READY(worker.c:5805-5824)。

**Q5:apply worker 的错误传播?**
PG_CATCH 回滚 origin(:5690-5696);disable_on_error 则停订。

**Q6:物理复制和逻辑复制共享什么?**
libpqwalreceiver(:18-19)与反馈协议;差异在解码链(walsender.c:3695→reorderbuffer→pgoutput :261)。

**Q7:逻辑复制支持 DDL 吗?**
不支持:DDL 不产生行变更——用户的运维负担(卷二 10 章)。

**Q8:并行 apply 的错误回传?**
独立 shm_mq 回传(:387-394):并行 worker 错误经队列给 leader。

## 21.6 小结与深挖方向

本章结论:**apply worker="17 种消息分发+五态并行+冲突不自动仲裁+origin 进度先于提交"**。深挖:

1. stream_commit 的 spool 回放(:2459)在大事务的磁盘 IO;
2. 冲突检测(:882)在复合唯一索引的行为;
3. tablesync 的 CRS_USE_SNAPSHOT(:1413-1431)与 VACUUM 的竞态;
4. 并行 apply 的 LA/PA 锁(:60-116)在跨事务的死锁;
5. pg_conflict_log 表(:153)的查询接口与自动化工具前景。

> PG 卷五完——全文检索/JSONB/逻辑解码/bgworker/逻辑复制 apply 五个扩展面全部闭合。
