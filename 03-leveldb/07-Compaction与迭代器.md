# 第 07 章 · Compaction 与迭代器:LSM 的心脏

> 基线:LevelDB 1.23,commit `7ee830d0`。行号均以该版本源码为准。
> 路径勘误:MergingIterator 在 `table/merger.cc`(不是 db/merger.cc);Iterator 基类实现在 `table/iterator.cc`。

## 7.0 三种入口

**minor compaction**(memtable → L0)与 **major compaction**(Ln → Ln+1 归并)最终都汇聚到 `BackgroundCompaction()`:

1. **写路径触发 flush**:写满 write_buffer_size(默认 4MB)即触发;`WriteLevel0Table`(db_impl.cc:505-547)**解锁**后调 BuildTable,之后按范围决定落盘层级——`PickLevelForMemTableOutput` 允许在不与 L0/L1 重叠、L2 重叠字节有限时直落 L1/L2(最深到 kMaxMemCompactLevel=2),绕开昂贵的 L0→L1 compaction;
2. **后台调度**:MaybeScheduleCompaction 四个 if 短路(已调度/关闭中/bg_error/无事可做)——**同一时刻至多一个后台 compaction 线程**;BackgroundCall 做完一次后立即再次自检,形成"能干就继续干"的泵。BackgroundCompaction 的优先级:imm_ 优先 → manual compaction → PickCompaction(size 优先于 seek);IsTrivialMove 则零 IO 挪文件;
3. **手动 CompactRange**(582-597):强制落盘 memtable 后逐层驱动;**分片串行**——每轮只做 input(0) 最后一个文件的 largest 之前的范围,期间普通写入仍可进行。

## 7.1 DoCompactionWork 主循环

```cpp
while (input->Valid() && !shutting_down_.load(...)) {
  if (has_imm_.load(...)) {          /* 边做大事边清小事 */
    mutex_.Lock();
    if (imm_ != nullptr) { CompactMemTable(); ... }
    mutex_.Unlock();
  }
  Slice key = input->key();
  if (compact->compaction->ShouldStopBefore(key) && builder) {
    status = FinishCompactionOutputFile(compact, input);   /* grandparent 重叠超限先收尾 */
  }
  ... /* drop 判定 */
  if (!drop) { ... builder->Add(key, input->value()); }
  input->Next();
}
```
(db_impl.cc:898-1057)

三个穿插点:**imm 优先**(归并中用原子 has_imm_ 探测待落盘 memtable,抢锁做 minor compaction 并唤醒被挂起的写线程,避免写停顿);**输出切分前置**(ShouldStopBefore 统计输出与 grandparent(L+2) 层的重叠字节,超限提前切文件——防止制造未来压不动的"超级文件");**输出切分后置**(自身字节超限)。`OpenCompactionOutputFile` 一开始就把新文件号塞进 `pending_outputs_`,防 RemoveObsoleteFiles 误删正在写的文件。

准备阶段两件事:`smallest_snapshot` = 最老快照 seq(无快照取 LastSequence,910-914);`mutex_.Unlock()`(919)——**归并读写磁盘期间不阻塞前台读写**,这是整个主循环并发设计的前提(compaction 操作的三样东西都是不可变快照:input_version_ 已 Ref、输出文件私有、manifest 提交时才短暂加锁)。

## 7.2 drop 判定:完整决策树

每条内部键依次经过(db_impl.cc:950-984):

```
ParseInternalKey 失败? → 原样保留("Do not hide error keys")
├─ user_key 与上一条不同? → 记录新 key,last_sequence_for_key = kMaxSequenceNumber
│                          (首个条目永不因规则A被丢)
├─ 规则A: last_sequence_for_key <= smallest_snapshot? → drop
│         ("Hidden by a newer entry for same user key")
├─ 规则B: type==kTypeDeletion && seq<=smallest_snapshot
│          && IsBaseLevelForKey(user_key)? → drop
└─ 否 → 保留
最后(无论 drop 与否): last_sequence_for_key = ikey.seq   /* 983 */
```

三个易被忽略的细节:

1. **`last_sequence_for_key` 的更新在 if/else 之外**(983)——被丢弃的删除标记同样参与对后续更旧条目的遮蔽,"遮蔽链必须贯穿被丢弃的条目";
2. 整个状态机依赖内部键排序 `(user_key asc, seq desc)` **一次线性扫描完成**,无需哈希表;
3. 规则A的初始化值 kMaxSequenceNumber 保证每个 key 的第一条(最新)永不误丢。

**为什么删除标记必须"到底层"才能丢**(规则B):反证——若在 L2 无条件丢弃 K 的删除标记而 K 的旧值还在 L3,此后读 K 会**复活已删除的数据**。`IsBaseLevelForKey`(version_set.cc:1517-1536)检查 level+2 及以下是否覆盖该 key;规则B还要求 `seq <= smallest_snapshot`(更老的快照可能依赖它遮蔽旧值)。

**IsBaseLevelForKey 的摊还设计**:用只进不退的 `level_ptrs_[7]` 游标把逐 key 的"下层覆盖检查"摊还为全程 O(文件数)——正确性依赖 compaction 输出 key 单调前进这一全局遍历序(ShouldStopBefore、SetupOtherInputs 同样依赖)。

**smallest_snapshot 是空间回收与快照长寿的显式契约**:一个被遗忘的快照会让 deleted/overwrite 数据无限堆积——快照既是读一致性工具,也是 GC 障碍。

收尾:`InstallCompactionResults` 把"删输入文件 + 加输出文件"塞进一个 VersionEdit,经 LogAndApply 原子写入 manifest 并安装为新 Version;失败则 RecordBackgroundError,**之后 MaybeScheduleCompaction 永不再调度**。还有个防御细节:`FinishCompactionOutputFile` 生成后立即经 table_cache 读一次元数据——把"写坏了"当场变成 compaction 错误,而不是留到未来某次读才爆(864-876)。

## 7.3 迭代器组合体系

**接口契约**(iterator.h:35-73):八个纯虚方法 + 三条隐式契约——`REQUIRES: Valid()`(Next/key/value 只在 Valid 时可调)、**Slice 临时性**(key/value 的内存在"下一次修改迭代器"之前有效,上层必须拷贝)、**错误延后**(status() 是唯一错误通道,循环结束后必须检查)。析构钩子 `RegisterCleanup` 是迭代器持有外部资源(Versions、memtable 引用)的机制。

组合图(读路径与 compaction 输入同构):

```
用户视图 NewIterator (db_impl.cc:1083-1108)
└─ DBIter (db_iter.cc)                     [seq 过滤 + 删除翻译]
   └─ MergingIterator (table/merger.cc)
      ├─ MemTableIterator ← mem_ (SkipList)
      ├─ MemTableIterator ← imm_(存在时)
      └─ Version::AddIterators
         ├─ L0: 每文件一个 table_cache 迭代器(L0 互相重叠,必须归并)
         └─ Ln(n≥1): 每层一个 TwoLevelIterator(层内不重叠,可拼接)
            ├─ index_iter = LevelFileNumIterator(其 value 是 16 字节 (file#, size))
            └─ data_iter = GetFileIterator → Table(本身又是 TwoLevelIterator:
                 索引块 Iter → 数据块 Iter)
```

各层要点:**IteratorWrapper** 缓存 valid/key 省虚调用;**MemTableIterator** status() 恒 OK(内存结构无 IO 错误);**Block::Iter** 在重启点数组上二分、区间内线性,Prev 只能回退到重启点再前扫(前缀压缩对反向遍历的固有代价);**TwoLevelIterator** 惰性构建 data 迭代器并缓存 block 句柄;**MergingIterator** 的归并是朴素线性扫描——"子迭代器数量很少,不值得上堆"(merger.cc:138-140 注释),n==1 直接返回唯一子迭代器消除包装。

**MergingIterator 的方向切换**是难点:约定"正向时所有子迭代器都在 key() 之前已消费";从反向切来时对每个非当前 child `Seek(key())` 重新对齐,恰在 key() 上再跳一步(merger.cc:55-79)。单次换向代价 O(n·log N),**锯齿形遍历(Next/Prev 交替)性能显著退化**。

生命周期:NewInternalIterator 持锁对 mem/imm/current 各 Ref 一次,RegisterCleanup 注册回调,迭代器析构时重新拿锁 Unref(db_impl.cc:1071-1078)——**组合迭代器的存活期可能远超创建时的临界区**,这就是清理钩子成为接口一部分的原因。

## 7.4 DBIter:把内部视图翻译成用户视图

输入是 `(user_key asc, seq desc)` 的条目流,输出是"每 user_key 至多一条、跳过删除":

- **快照过滤**:`ikey.sequence <= snapshot` 之外的条目直接视为不存在;
- **正向 FindNextUserEntry**:遇 kTypeDeletion → 把该 user_key 存入 skip,后续所有 ≤ skip 的条目全部隐藏——一次删除遮蔽同 key 全部旧版本;
- **反向的代价**:Prev 必须先越过当前 user_key 的所有历史版本,再 FindPrevUserEntry 反向扫,且**反向也要处理"删除标记藏在更后面"**(遇到删除清空已缓存值,250-252)——反向无法用正向的 skip 技巧,只能扫完整个 key 的版本链。单 key 万次覆盖的负载下 Prev 与正向的差距是深挖点;
- **Seek 的构造**:user target 包装成 `(target, snapshot, kValueTypeForSeek)` 的内部键——用最大 type 才能定位到"该 seq 下的第一个条目"。

顺带机制:DBIter 统计读过的字节,每约 1MB 调用一次 `RecordReadSample`(db_iter.cc:122-131)——**长迭代会主动"投票"让拖后腿的文件参与 compaction**(第 06 章 seek 触发的另一数据源)。

## 7.5 FAQ

**Q1:compaction 为什么要释放 mutex?**
释放锁让前台读写不被磁盘 IO 阻塞;操作对象都是不可变快照,manifest 提交时才短暂加锁。imm_ 例外:主循环探测到后要抢锁做 minor compaction。

**Q2:被 drop 的条目为何还要更新 last_sequence_for_key?**
遮蔽链必须贯穿被丢弃的条目,否则更旧的条目判定会"跳过"这条而被误保留。

**Q3:损坏条目为什么原样输出?**
"不掩盖错误":让上层工具(leveldbutil/repair)仍能发现;同时重置状态避免污染后续判定。

**Q4:交替 Next/Prev 会怎样?**
每次换向触发全部 child 的 Seek,O(n·logN);应用层应尽量单向扫描。

**Q5:memtable flush 为什么可能落到 L1/L2?**
PickLevelForMemTableOutput 逐级下沉(最深到 2),减少 L0 文件数与 L0→L1 compaction 频率。

**Q6:grandparent 重叠字节为什么也限制输出切分?**
与 IsTrivialMove 的禁用条件同源:输出文件与 L+2 大量重叠,等于"今天省一次 IO,明天付出巨大归并"。

## 7.6 小结与深挖方向

本章结论:**compaction = 解锁的线性归并 + 一个依赖排序的状态机(drop)+ 不可变快照上的原子提交;迭代器 = 组合模式 + 三条契约(Valid/临时性/错误延后)**。深挖:

1. 规则A的保守性边界:能否用快照链精确计算水位(RocksDB 的 bottommost 裁剪之路);
2. ShouldStopBefore 切分后 overlapped_bytes_ 清零、grandparent_index_ 不回退的系统性低估;
3. MergingIterator 堆/loser tree 的临界点(children≈9 时的经验区间);
4. DBIter 反向遍历在"单 key 万次覆盖"下的摊还代价;
5. 手动 compaction 单槽与前台写的公平性(P99 压测)。

> 下一章回到写路径:writer 队列、限流阶梯、WAL 的 32KB 块与崩溃恢复。
