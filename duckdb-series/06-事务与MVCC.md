# 第 06 章 · 事务与 MVCC:单写者多读者的快照实现

> 基线:commit `7e886f44`。核心目录 src/transaction/(WAL 块格式与 checkpoint 留卷二)。

## 6.0 全景:时间戳即版本号,快照即区间

```
全局单调计数器(start_ts 与 commit_ts 同源,duck_transaction_manager.cpp:283-285)
 40        45                        60
 │      T1 BEGIN(读者,start=45)   T2 COMMIT(写者)
 │      view.bound=Before(45)      ①WriteToWAL ②取 commit_id=60
 T2 BEGIN(40,写者)                 ③UndoBuffer::Commit:版本号 tid→60(此瞬可见)
 版本先标 tid=2^62+idx             ④FlushCommit:flush marker/组提交 ⑤fsync 后移出 active
 可见性一行(transaction_data.hpp:34-36):
   visible ⇔ ts < bound ∨ ts == 自己 tid
   T2 的行:60 ≥ 45 → T1 不可见 → 读到快照旧行;写者提交无需等读者
```

**id 两段空间**:transaction id 从 `2^62` 起跳,commit id 上限 `2^62-1`(constants.cpp:18-22)——于是 `IsCommitted(t) = t <= 2^62-1` 一眼可判,提交状态折叠进版本号本身,**无需 clog**。

## 6.1 三层对象与快照的 durability 约束

TransactionContext(每连接)→ MetaTransaction(每事务,按 attached db 分发)→ DuckTransaction(每库,MVCC 状态:start_time/view/commit_id)。快照不是 xmin 集合而是一个区间;且叠加 durability 约束——新快照的 bound 被压到**第一个未 fsync 提交之前**(`GetDurableSnapshot`,duck_transaction_manager.cpp:78-99),保证不会读到"已发布但崩溃后会消失"的数据。只读事务 BEGIN 不取锁、Commit 第一行直接返回(duck_transaction.cpp:272-274)。

## 6.2 "单写者"的准确含义:乐观并发

BEGIN 永远成功。冲突在两个时刻爆发:**写操作时刻**——UPDATE 沿版本链查重,发现快照后新版本即抛 "Conflict on update!"(update_segment.cpp:667-699);DELETE 已被他人删即抛 "Conflict on tuple deletion!"(chunk_info.cpp:384-425)。**commit 时刻**——undo 复查表 catalog 版本,表被并发 ALTER/DROP 则整体回滚(commit_state.cpp:356-394)。提交段全局串行:写事务全程持 WAL 锁,commit_id 在 transaction_lock 下分配(:387-425)。CHECKPOINT 要排他 StorageLock,拿不到提示改用 FORCE(duck_transaction_manager.cpp:237-258)。一个事务只能写一个 attached database(meta_transaction.cpp:272-281)。

## 6.3 UndoBuffer:变更日志,而非旧版本仓库

undo 六类条目(CATALOG/INSERT/DELETE/UPDATE/SEQUENCE/ATTACHED_DB,undo_flags.hpp:15-23),8 字节头+载荷,内存态可被缓冲池逐出但不落盘。**与 PG 方向相反:undo 记新值**,旧值留在 base 段;读者看到"新值已提交但不在自己快照内"时沿 UpdateInfo 链回放旧版本(update_info.hpp:61-87)。undo 缓冲五个消费阶段:WriteToWAL(提交写日志)→Commit(逐条把版本号 tid 改成 commit_id,此瞬对外可见)→RevertCommit(失败退回 tid+截断 WAL)→Rollback(逆序重放)→Cleanup(GC 摘链)(undo_buffer.cpp:176-216)。

## 6.4 commit 九步与失败三档

全链(duck_transaction_manager.cpp:341-571):预刷大 append 块→取 WAL 锁→WriteToWAL(本地 append 合入主表+undo 逐条写日志)→重取锁取 commit_id→undo 打时间戳发布→FlushCommit(无他事务就地 fsync,否则只记 wal_sync_offset)→SyncUpTo 组提交→推进 durable_bound 移出 active→(可时)auto-checkpoint。**顺序是铁律:先 WAL、后打 commit_ts、再 fsync**——任何对外可见的 commit_id 版本,其 redo 必已在 WAL 字节流。失败三档:WAL 写失败→Revert;打戳失败→退回 tid+截断 WAL;fsync 失败→只能 invalidate 整库(duck_transaction.cpp:309-333)。

## 6.5 可见性过滤与 GC

行版本信息在 RowGroup 的 RowVersionManager:每 2048 行向量记录插入者/删除者 id,各在"常量/位图/数组"三态间压缩(chunk_info.hpp:48-52)。扫描热路径先问版本信息要 selection vector、后读数据(chunk_info.cpp:70-212 六种插入×删除组合)——**被过滤的行零 I/O 解压**。GC 杠杆 `lowest_visibility_bound`(最老活跃快照):低于它的版本 id 对现在与未来读者等价,可把数组折叠成常量直至整段释放(row_version_manager.hpp:44-48);清理在释放锁之后由单线程队列执行——临界区内不做 I/O。

## 6.6 Appender 与隔离级别

Appender 不绕过事务:攒满一批后包装成 `INSERT INTO t FROM __duckdb_internal_appended_data` 走完整 SQL 执行(appender.cpp:615-628);InternalAppender 直写 LocalStorage 但仍并入当前事务;bulk append(≥整 row group)在 commit 时直接移交 row group collection(local_storage.cpp:576-588)。隔离级别:源码无显式声明,行为证据(快照读+首提交者胜+写写即时冲突)指向**快照隔离**,写偏斜无防护——如实记录(F 报告第 11 节)。

## 6.7 设计动机

1. **提交状态折叠进版本号**:省掉 clog;一次 64 位比较完成可见性;
2. **undo 记新值**:与 WAL 内容同源省一份写入;清理靠 lowest_visibility_bound 整体释放,无需 vacuum 线程;
3. **commit 先 WAL 后发布**:崩溃重放不会出现"从未提交过的已提交数据";
4. **冲突即时抛异常**:乐观并发假定冲突罕见;无行级锁结构、无死锁检测器;
5. **提交段单写者**:WAL 是逻辑变更,重放须与提交序严格一致,一把锁串成临界区。

## 6.8 FAQ

**Q1:两个事务同时 UPDATE 同一行会怎样?**
后到者在写操作时刻即抛 Conflict on update,可重试;不等待不加锁。

**Q2:快照是什么?**
一个区间:{自己 tid, bound=BEGIN 时刻},再压到第一个未 durable 提交前。

**Q3:读会阻塞写吗?**
不会:读写零交互,读只在扫描时做 id 区间过滤。

**Q4:回滚怎么做?**
undo 逆序重放:catalog 撤销、append 收缩行数、delete 复活、update 摘链(rollback_state.cpp:22-60)。

**Q5:undo 在磁盘上吗?**
不在:内存态可被缓冲池逐出;磁盘上只有 WAL redo。

**Q6:为什么没有 vacuum?**
旧值留 base 段不堆积多版本;GC 把版本 id 折叠为常量直至释放。

**Q7:temp/in-memory 库有 WAL 吗?**
没有:提交只剩打 commit_id+undo 发布(duck_transaction.cpp:197-213)。

**Q8:Appender 每批都提交吗?**
autocommit 下是;显式事务内并入当前事务。

**Q9:CHECKPOINT 与写事务冲突怎么办?**
写事务持共享锁,CHECKPOINT 要排他;FORCE 变体阻止新事务后自旋等待。

**Q10:能跨库写吗?**
不能:第二个写目标直接抛异常(meta_transaction.cpp:272-281)。

## 6.9 小结与深挖方向

本章结论:**事务="区间快照+即时冲突检测+记新值的内存 undo+先WAL后发布的三段铁律",三处减法省掉 clog/活跃集合快照/回滚段**。深挖:

1. catalog 版本链与行 MVCC 的统一判定(commit_state.cpp:297-350);
2. `debug_force_commit_failure` 注入的三类失败演练(duck_transaction.cpp:290-314);
3. recently_committed_transactions 队列与清理线程的交接(duck_transaction_manager.cpp:670-697);
4. LocalStorage 行号空间 MAX_ROW_ID_LOCAL 与持久空间的隔离;
5. WAL 记录格式与 checkpoint 块布局(卷二主题)。
