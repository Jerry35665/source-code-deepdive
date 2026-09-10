# 第 02 章 · 执行框架:从 Open 到 Get/Put

> 基线:LevelDB 1.23,commit `7ee830d0`。行号均以该版本源码为准。
> 与前两卷的对照:Redis 是"一个事件循环吃掉一切",SQLite 是"编译与执行严格两段";LevelDB 的框架是**一条 Put 的两步落盘 + 一条 Get 的三查**,所有并发正确性都建立在这两个骨架上。

## 2.0 一条 Put 的两步,一条 Get 的三查

```
Put: WriteBatch 编码(纯内存) → writer 队列排队 → MakeRoomForWrite
     → [解锁] log_->AddRecord → (sync? Sync) → InsertInto(mem_)
     → [加锁] SetLastSequence → 批量唤醒同组 writer
     (db_impl.cc:1206-1274)

Get: 持锁摘 mem_/imm_/current 并 Ref → 解锁
     → ① mem->Get → ② imm->Get → ③ Version::Get(SST 层级)
     → 加锁 Unref → UpdateStats(可能触发 seek compaction)
     (db_impl.cc:1121-1166)
```

三查的顺序编码了"新旧优先"语义——mem 比 imm 新、imm 比 SST 新;三查的键是统一的 LookupKey `(user_key, snapshot_seq, kValueTypeForSeek)`(第 03 章)。快照序号来自 `options.snapshot` 或 `versions_->LastSequence()` 二选一(db_impl.cc:1125-1131),后者意味着无快照的 Get 永远看到"此刻最新"。

贯穿两条路径的资源管理模式与 Redis 卷、SQLite 卷一致:**持锁只摘指针 + Ref,真正的活儿在解锁状态下干**(memtable 引用计数、Version 引用计数、table cache 句柄三种引用各司其职)。

## 2.1 DB::Open 的完整链条

`DB::Open`(db_impl.cc:1503-1544)→ `DBImpl::Recover`(292-383),五步:

1. `LockFile(LOCK)` 进程级互斥(298-303)——一个目录同一时刻只有一个 DB 实例;
2. 无 CURRENT 则按 create_if_missing 新建(NewDB 写初始 manifest,181-214);
3. `VersionSet::Recover`:重放 manifest 重建各层文件集合(第 06 章);
4. 收集 `number >= log_number` 的 WAL **按文件号排序**逐个重放进 memtable(第 08 章),重放超 4MB 中途刷盘;
5. save_manifest 则写新 VersionEdit 提交——**这一步之后旧 log 才正式可删**;最后 `DeleteObsoleteFiles`。

## 2.2 写路径的三个角色

写路径的完整角色分工(细节分见第 08 章):

- **WriteBatch**:纯内存的二进制表示,12 字节头(seq + count)+ 自描述记录流——"自包含性"让它无需外部上下文即可写 WAL、跨线程合并、恢复时零上下文重放;
- **writer 队列**:单队头推进 + group commit,把 N 个并发写变成一次磁盘写;
- **MakeRoomForWrite**:限流阶梯,把 compaction 滞后转化为写端可感知的延迟梯度(4/8/12 三级)。

一个关键的设计协同:**memtable 与 log 在情形 5 同步切换**,使"memtable 内容 = 对应 log 的重放结果"成为不变量——恢复逻辑因此可以按 log 粒度推进,`LogNumber` 一个字段就能划定"哪些 WAL 可以删"。这是 LevelDB 结构上最漂亮的不变量。

## 2.3 读路径的三个组件

- **MemTable::Get**(第 03 章):跳表 Seek + 只比 user key,返回值表达"答案在不在本表";
- **Version::Get**(第 06 章):L0 线性过滤按新→旧探测,L≥1 二分;删除标记让查找短路;
- **TableCache / BlockCache**(第 04、08 章):文件句柄与数据块的两级 LRU。

读的副作用只有一个:`allowed_seeks` 记账与 `RecordReadSample` 采样——**读放大信号反过来驱动 compaction**(第 06、07 章),这是 LSM 闭环的自我调节。

## 2.4 后台线程:单一 compaction 泵

`MaybeScheduleCompaction`(db_impl.cc:668-683)四个 if 短路:**同一时刻至多一个后台 compaction 线程**;BackgroundCall 做完一次立即再次自检,形成"能干就继续干"的泵。优先级:imm_ 落盘 → manual compaction → size/seek 触发的 PickCompaction(第 07 章)。

bg_error_ 是全局熔断:任何后台错误(尤其 sync 失败升级而来)都会让调度永不再发生、MakeRoomForWrite 拒绝一切写——**把"状态可能不一致"的灰区统一收敛成"库进入只读",而不是带病运行**。

## 2.5 FAQ

**Q1:Put 为什么先写 log 再写 memtable?顺序能反吗?**
不能。log 是持久性来源,memtable 是可见性来源;先 memtable 后 log 的话,写 memtable 成功而 log 失败时,数据已可见却可能丢失。两步都在解锁窗口内由队头串行执行,天然有序。

**Q2:多条 Put 并发会乱序吗?**
不会:序号在加锁状态预分配,解锁段只是执行;队头身份由 writers_ 队列保证。

**Q3:Get 的三次查找可以并行吗?**
框架上是串行短路(命中即返回);真正并行的收益在 Version::Get 内部的 L0 多文件探测——代码选择顺序探测(按新→旧),因为多数命中发生在前几个文件。

**Q4:snapshot 是怎么实现的?**
一个 seq 数字挂在 SnapshotList 环形链表上(snapshot.h);它的作用是钉住 compaction 的丢弃水位(第 07 章的 smallest_snapshot)——快照既是读一致性工具,也是 GC 障碍。

**Q5:LevelDB 的写是原子的吗?**
单批原子:WriteBatch 在 log 中是同一条逻辑记录(残缺即整条丢弃)、memtable 插入单线程连续、序号区间连续(第 08 章)。

**Q6:打开数据库时旧 log 什么时候可以删?**
save_manifest 的 LogAndApply 提交之后——在那之前它们是唯一可能"尚未落盘"的数据。

## 2.6 小结

本章结论:**执行框架 = 两步写(队列串行化)+ 三查(引用计数解锁读)+ 单泵后台 + 全局熔断**。所有并发正确性都建立在"不可变快照 + 引用计数 + 单写者"三个要素上,没有任何一处依赖细粒度锁。

> 下一章开始下沉:内存组件——跳表的内存序论证与 Arena 的 66 行。
