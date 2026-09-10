# C 篇 · Compaction 全流程与迭代器体系

> 本篇基于 leveldb v1.23(commit 7ee830d0)逐行调研。所有结论均以 `文件:行号` 标注;除非特别说明,`db_impl.cc` 指 `db/db_impl.cc`,其余同理。
>
> **路径勘误**:任务书中提到的 `db/merger.cc` 与 `util/iterator.cc` 在该仓库中并不存在——`MergingIterator` 实际位于 `table/merger.cc`,`Iterator` 基类实现(EmptyIterator 等)实际位于 `table/iterator.cc`。另:任务书中 "deformation" 应为 "smallest_snapshot(快照)判定" 之笔误,本篇按快照语义展开。

---

## ① 全景:compaction 的三种入口

LevelDB 把 compaction 分为两类:**minor compaction**(memtable → L0 sstable)与 **major compaction**(L n → L n+1 的多路归并)。三条入口最终都汇聚到 `BackgroundCompaction()`。

### 入口 1:写路径触发 memtable flush(minor compaction)

写满 `write_buffer_size`(默认 4MB)即触发,发生在 `MakeRoomForWrite` 与恢复路径中:

- `RecoverLogFile` 回放日志时 memtable 超限,直接调 `WriteLevel0Table`(db_impl.cc:455-458);
- 正常写路径 `MakeRoomForWrite` 在 L0 文件数达到 `kL0_SlowdownWritesTrigger=8` 时故意 sleep 降速、达到 `kL0_StopWritesTrigger=12` 时挂起写线程(db_impl.cc:1342,1362;常量见 dbformat.h:31-34),随后切换日志、把 `mem_` 转为 `imm_`,并 `MaybeScheduleCompaction()`(db_impl.cc:1401 附近)。

`WriteLevel0Table`(db_impl.cc:505-547)是 minor compaction 的核心:分配文件号、取出 memtable 迭代器、**解锁**后调 `BuildTable`(db_impl.cc:517-521),之后按 key 范围决定落盘层级——`base->PickLevelForMemTableOutput`(db_impl.cc:536;version_set.cc:470-495)允许在不与 L0/L1 重叠、且 L2 重叠字节有限时一路下沉,但最深只到 `kMaxMemCompactLevel=2`(dbformat.h:42),目的是绕开昂贵的 L0→L1 compaction(version_set.cc:37-41 注释)。

`CompactMemTable`(db_impl.cc:549-580)则是对 `imm_` 的后台落盘:写 L0 文件 → `LogAndApply` 提交 manifest → 释放 `imm_` → `RemoveObsoleteFiles`。注意它把 `LogNumber` 推进到当前日志(db_impl.cc:567),此后旧日志才可删除。

### 入口 2:后台调度(size/seek compaction)

调度入口 `MaybeScheduleCompaction`(db_impl.cc:668-683)是四个 if 的短路判断:已调度 / 正在关闭 / 已有 bg_error / (`imm_` 为空 && 无 manual && `!versions_->NeedsCompaction()`)都不满足才 `env_->Schedule(&BGWork)`——即**同一时刻至多一个后台 compaction 线程**(db_impl.cc:670-671)。`BackgroundCall`(db_impl.cc:689-706)做完一次 compaction 后把 `background_compaction_scheduled_` 置回 false 并**立即再次自检**(db_impl.cc:702-704 注释:"上一次 compaction 可能又产生了过多文件"),形成"能干就继续干"的泵。

`BackgroundCompaction`(db_impl.cc:708-787)的优先级:

1. `imm_ != nullptr` → 先做 `CompactMemTable()` 并返回(db_impl.cc:711-714);
2. manual compaction(见入口 3)→ `versions_->CompactRange(level, begin, end)` 选文件(db_impl.cc:721);
3. 否则 `PickCompaction()`(db_impl.cc:732;version_set.cc:1252-1304):优先 size compaction(`compaction_score_ >= 1`,即 level 文件字节数超限),其次 seek compaction(读请求打穿到某层的次数超阈值,由 `DB::Get` 的 `UpdateStats`/`RecordReadSample` 驱动,db_impl.cc:1159-1161);用 `compact_pointer_[level]` 轮转选文件保证负载均匀(version_set.cc:1267-1278);L0 会把所有与所选文件 key 范围重叠的文件全部拉进来(version_set.cc:1291-1299)。

若 `IsTrivialMove()`(单文件、L+1 层无重叠文件、grandparent 重叠字节不超限,version_set.cc:1499-1507),则只改 manifest 把文件从 L 挪到 L+1,零读写(db_impl.cc:738-753)。

### 入口 3:用户手动 compaction

`DB::CompactRange`(db_impl.cc:582-597)先算出 `[begin,end]` 涉及的最高层,然后强制落盘 memtable,再对 level 0..max_level_with_files 逐层调 `TEST_CompactRange`(db_impl.cc:599-641)。后者把栈上的 `ManualCompaction` 挂到 `manual_compaction_` 单槽指针上(db_impl.h:80-86),循环等待后台线程消费;若槽被占用则等条件变量。大范围手动 compaction 无法一次做完:`BackgroundCompaction` 每轮只做 `input(0)` 最后一个文件的 largest 之前的范围,完成后把 `manual_end` 写回 `m->begin = &m->tmp_storage` 作为下一轮起点(db_impl.cc:724,782-783),直到 `m->done`。这意味着**手动 compaction 是分片串行的,期间普通写入仍可进行**。

三种入口的关系一句话概括:*写压力推动 memtable 下沉,score/seek 推动 sstable 逐层下沉,CompactRange 由用户强制拉平*。

---

## ② DoCompactionWork 主循环逐段解读

`DoCompactionWork`(db_impl.cc:898-1057)是 major compaction 的心脏。`CompactionState` 携带输出文件列表与 `smallest_snapshot`(db_impl.cc:54-86)。

### 2.1 准备阶段

- **快照水位**:`smallest_snapshot` 取最老快照的 seq;无快照时取 `LastSequence`(db_impl.cc:910-914)。语义见 db_impl.cc:73-77 注释:seq < smallest_snapshot 的同 key 旧条目永远无人可见,可安全丢弃。
- **输入归并迭代器**:`versions_->MakeInputIterator(compact->compaction)`(db_impl.cc:916;version_set.cc:1219-1250,详见 ③)。
- **释放互斥锁**:`mutex_.Unlock()`(db_impl.cc:919)——归并读写磁盘期间不阻塞前台读写,这是整个主循环并发设计的前提。

### 2.2 主循环骨架

```cpp
while (input->Valid() && !shutting_down_.load(std::memory_order_acquire)) {
  if (has_imm_.load(std::memory_order_relaxed)) {          // 929
    mutex_.Lock();
    if (imm_ != nullptr) { CompactMemTable(); ... }        // 933
    mutex_.Unlock();
  }
  Slice key = input->key();
  if (compact->compaction->ShouldStopBefore(key) &&        // 942
      compact->builder != nullptr) {
    status = FinishCompactionOutputFile(compact, input);
  }
  ... // drop 判定,见 2.3
  if (!drop) { ... builder->Add(key, input->value()); ... } // 995-1017
  input->Next();                                            // 1019
}
```

三个穿插点值得注意:

- **imm 优先**(db_impl.cc:928-939):归并过程中用 `has_imm_`(atomic,免锁读)探测是否有待落盘 memtable;有则抢锁做一次 minor compaction 并唤醒被 `MakeRoomForWrite` 挂起的写线程。这是 L0 堆积时的"边做大事边清小事",避免写停顿;`imm_micros` 被单独统计、不计入 compaction 耗时(db_impl.cc:900,1035)。
- **输出切分(前置)**:`ShouldStopBefore`(version_set.cc:1538-1560)统计当前输出文件与 **grandparent(L+2)** 层的重叠字节数,超过 `MaxGrandParentOverlapBytes` 就先收尾当前输出文件,避免产生一个与 L+2 大量重叠、导致后续 compaction 代价爆炸的"超级文件"。
- **输出切分(后置)**:`builder->FileSize() >= MaxOutputFileSize()`(按层递增,db_impl.cc:1010-1011)时收尾并靠 `OpenCompactionOutputFile` 惰性开新文件(db_impl.cc:997-1002)。

`FinishCompactionOutputFile`(db_impl.cc:831-878)做 `builder->Finish() → Sync → Close`,然后用 table_cache 重新打开做一次可用性验证(db_impl.cc:864-876)。`OpenCompactionOutputFile` 一开始就把新文件号塞进 `pending_outputs_`(db_impl.cc:813),防止 `RemoveObsoleteFiles` 误删正在写的文件。

### 2.3 drop 判定:完整决策树

每条内部键 `(user_key, seq, type)` 依次经过(代码 db_impl.cc:950-984):

```
ParseInternalKey 失败?
├─ 是 → 重置 current_user_key / last_sequence_for_key,原样保留
│        (注释 "Do not hide error keys", db_impl.cc:952-956)
└─ 否
   ├─ user_key 与上一条不同?
   │    └─ 是 → 记录新 user_key,last_sequence_for_key = kMaxSequenceNumber
   │            (db_impl.cc:958-965;首个条目永不因规则A被丢)
   ├─ 规则A: last_sequence_for_key <= smallest_snapshot?
   │    └─ 是 → drop(db_impl.cc:967-969,"Hidden by a newer entry
   │              for same user key":同 user_key 的上一个(更新)条目
   │              已进入任何快照可见范围,本条必被它遮蔽)
   ├─ 规则B: type==kTypeDeletion && seq<=smallest_snapshot
   │          && IsBaseLevelForKey(user_key)?
   │    └─ 是 → drop(db_impl.cc:970-981,删除标记冗余,论证见 ⑤)
   └─ 否 → 保留
   最后(无论 drop 与否):last_sequence_for_key = ikey.seq   // 983
```

三个易被忽略的细节:

1. **`last_sequence_for_key` 的更新在 if/else 之外**(db_impl.cc:983),所以被丢弃的删除标记同样参与遮蔽后续更旧条目——正是规则B注释第 (3) 点"将被本循环随后按规则A丢弃"(db_impl.cc:976-979)。
2. **利用了内部键排序**:同 user_key 内 seq 递减排列(`InternalKeyComparator::Compare`:user key 升序、seq 降序,dbformat.cc:44-49),所以"上一个条目"就是最新版本,一次线性扫描即可完成遮蔽判定,无需哈希表。
3. **保留路径**记录本输出文件的 `smallest/largest` 内部键(db_impl.cc:1003-1006),供 manifest 与后续 compaction 使用。

### 2.4 收尾:InstallCompactionResults

循环结束后(db_impl.cc:1022-1030):关机则报 IOError;还开着输出文件则 Finish;**必须检查 `input->status()`**——归并迭代器的 IO 错误不会中断 Valid() 循环,只能事后取。然后重新拿锁、累加 `CompactionStats`,成功则 `InstallCompactionResults`(db_impl.cc:1048-1049;880-896):

```cpp
compact->compaction->AddInputDeletions(compact->compaction->edit());
// 把 L 与 L+1 的全部输入文件登记为删除 (version_set.cc:1509-1515)
for (...) compact->compaction->edit()->AddFile(level + 1, out.number, ...);
return versions_->LogAndApply(compact->compaction->edit(), &mutex_);
```

即:一个 VersionEdit 同时包含"删输入文件 + 加输出文件",经 `LogAndApply` 原子写入 manifest 并安装为新 Version。失败则 `RecordBackgroundError`,之后 `MaybeScheduleCompaction` 永不再调度(db_impl.cc:674-675)。

---

## ③ MergingIterator 与迭代器组合体系

### 3.1 接口契约(include/leveldb/iterator.h)

`Iterator` 是八个纯虚方法的抽象:定位三件套 `SeekToFirst/SeekToLast/Seek`,移动 `Next/Prev`,读取 `key/value`,错误 `status`,加 `Valid`(iterator.h:35-73)。三条隐式契约贯穿全库:

- **REQUIRES: Valid()**:`Next/Prev/key/value` 只在 Valid 时可调(iterator.h:52,57,63,69),`EmptyIterator` 干脆 `assert(false)`(table/iterator.cc:52-57);
- **Slice 临时性**:`key()/value()` 返回的内存在"下一次修改迭代器"之前有效(iterator.h:60-62)——上层如 `DoCompactionWork` 中 `current_user_key.assign(...)`(db_impl.cc:962)、`DBIter::SaveKey`(db_iter.cc:91-93)都在拷贝;
- **错误延后**:`status()` 是唯一的错误通道,调用方循环结束后必须检查(`builder.cc:70-72`、`db_impl.cc:1028-1030`)。

析构钩子 `RegisterCleanup`(iterator.h:80-101;table/iterator.cc:26-39)用侵入式单链表保存回调,是迭代器持有外部资源(Versions、memtable 引用)的机制。

### 3.2 组合图(读路径与 compaction 输入同构)

```
用户视图 NewIterator (db_impl.cc:1083-1108 组装)
│
└─ DBIter (db/db_iter.cc:39)                     [seq过滤+删除翻译, 见④]
   └─ MergingIterator (table/merger.cc:14)
      ├─ MemTableIterator (db/memtable.cc:46)    ← mem_  (SkipList, memtable.h:75)
      ├─ MemTableIterator                        ← imm_ (存在时)
      └─ Version::AddIterators (version_set.cc:229-246)
         ├─ L0: 每文件一个 table_cache 迭代器    (L0文件互相重叠, 必须归并)
         └─ Ln(n≥1): 每层一个 TwoLevelIterator   (层内文件不重叠, 可拼接)
            ├─ index_iter = LevelFileNumIterator (version_set.cc:163)  二分找文件
            └─ data_iter  = GetFileIterator → Table::BlockReader (table.cc:153)
               └─ Table::NewIterator 本身也是 TwoLevelIterator (table.cc:208-211)
                  ├─ index_iter = 索引块的 Block::Iter
                  └─ data_iter  = 数据块的 Block::Iter (table/block.cc:77)
```

compaction 的输入 `MakeInputIterator`(version_set.cc:1219-1250)复用同一套积木:L0 每文件一个子迭代器、L≥1 每层一个 `TwoLevelIterator(LevelFileNumIterator, GetFileIterator)`,外层 `NewMergingIterator(&icmp_, ...)`(version_set.cc:1247)。

### 3.3 各层实现要点

**IteratorWrapper**(table/iterator_wrapper.h:17-88):在子迭代器外缓存 `valid_` 与当前 `key_`(每次 Next/Seek 后 `Update()`,iterator_wrapper.h:78-83),归并时 FindSmallest 的比较直接读缓存,省虚调用并改善局部性(iterator_wrapper.h:13-16 注释)。

**MemTableIterator**(db/memtable.cc:46-74):直接持有 `SkipList::Iterator`,`key()/value()` 都从跳表结点的 length-prefixed 编码中现场解码(db/memtable.cc:61-65);`Seek` 需先把 target 编码成 memtable 内部格式(db/memtable.cc:39-44,56)。`status()` 恒 OK(db/memtable.cc:67)——内存结构无 IO 错误。

**Block::Iter**(table/block.cc:77-278):在重启点(restart)数组上二分、在重启区间内线性。`Seek` 有一个精妙优化:若已 Valid 且目标在当前位置之后,用 `restart_index_` 收窄二分下界,甚至完全跳过 `SeekToRestartPoint`(block.cc:171-185,214-217)。`Prev` 只能回退到上一个重启点再向前线性扫(block.cc:143-162),这是前缀压缩对反向遍历的固有代价。空块/坏块分别返回 `NewEmptyIterator`/`NewErrorIterator`(block.cc:280-290)。

**TwoLevelIterator**(table/two_level_iterator.cc:18-161):"索引迭代器 + 工厂函数"的通用二级结构。`InitDataBlock`(two_level_iterator.cc:146-161)惰性构建 data 迭代器,并用 `data_block_handle_` 缓存当前 block 句柄,同一 block 反复访问不重建(151-154);跨块移动由 `SkipEmptyDataBlocksForward/Backward` 处理空块(115-139)。

**MergingIterator**(table/merger.cc:14-146):多路归并的核心。

- 归并本身是最朴素的线性扫描:`FindSmallest/FindLargest` 遍历全部子迭代器取最值(merger.cc:148-176),作者注释明说"子迭代器数量很少,不值得上堆"(merger.cc:138-140);
- `n==0` 返回空迭代器、`n==1` 直接返回唯一子迭代器(merger.cc:179-189),消除一层包装;
- **方向切换(SkipForward/SkipBackward 语义)**是本类的难点。约定:正向时所有子迭代器都位于 `key()` 之前已消费、当前 `current_` 是最小者;反向对称。切换时用 `Seek(key())` 重新对齐:

```cpp
void MergingIterator::Next() override {           // merger.cc:55-79
  if (direction_ != kForward) {                   // 刚从反向切来
    for (...) {
      IteratorWrapper* child = &children_[i];
      if (child != current_) {
        child->Seek(key());                       // 定位到第一个 >= key()
        if (child->Valid() && Compare(key(), child->key()) == 0)
          child->Next();                          // 恰在 key() 上则再跳一步
      }
    }
    direction_ = kForward;
  }
  current_->Next();  FindSmallest();
}
```

`Prev`(merger.cc:81-108)对称:先 `Seek(key())`,Valid 则 `Prev()` 退到 `< key()` 的最后一个条目,否则 `SeekToLast()`。这样保证切换后"所有 child 都严格在 key() 之后/之前",归并序不被反向遍历中已回退的 child 破坏。单次换向代价 O(n·log N)(n 个 child 各做一次 Seek),交替换向会反复触发。

### 3.4 生命周期:谁保证子迭代器活着?

`DBImpl::NewInternalIterator`(db_impl.cc:1083-1108)在持锁状态下对 `mem_/imm_/current Version` 各做一次 `Ref()`,组装完成后 `RegisterCleanup(CleanupIteratorState, ...)` 注册回调(db_impl.cc:1102-1103);迭代器析构时回调重新拿锁 Unref(db_impl.cc:1071-1078)。这解释了为什么清理钩子是 Iterator 接口的一部分:**组合迭代器的存活期可能远超创建时的临界区**。

---

## ④ DBIter 的语义翻译与方向优化

`DBIter`(db/db_iter.cc:39-120)包在 MergingIterator 外面,把内部键视图翻译成用户视图。它的输入是按 `(user_key asc, seq desc)` 有序的 `(userkey,seq,type)=>value` 条目流,输出是"每 user_key 至多一条、跳过删除"的用户键值流。

### 4.1 基本翻译规则

- **快照过滤**:任何定位/移动中,`ikey.sequence <= sequence_`(构造时固定的快照 seq)之外的条目直接视为不存在(db_iter.cc:183,243);
- **正向:`FindNextUserEntry`**(db_iter.cc:177-207)。
  - 遇到 `kTypeDeletion` → 把该 user_key 存入 `skip`,置 `skipping=true`,后续所有 `user_key <= *skip` 的条目全部隐藏(db_iter.cc:185-189)——一次删除遮蔽同 key 的全部旧版本,无需再看到具体的旧条目;
  - 遇到 `kTypeValue`:若 `skipping && ikey.user_key <= *skip` 则隐藏,否则命中返回(db_iter.cc:192-199);
- **Seek 的构造**:把用户 target 包装成 `(target, sequence_, kValueTypeForSeek)` 的内部键再 `iter_->Seek`(db_iter.cc:282-284)。`kValueTypeForSeek = kTypeValue` 是必要的:内部键按 seq 降序、type 打包在 seq 低 8 位(dbformat.h:55-61),用最大 type 才能定位到"该 seq 下的第一个条目"。

### 4.2 方向反转的优化与代价

`key()/value()` 依赖方向:正向直接透传内部迭代器;反向返回缓存的 `saved_key_/saved_value_`(db_iter.cc:64-71)。原因在 `Prev` 的实现:

```cpp
void DBIter::Prev() override {                     // db_iter.cc:209-234
  if (direction_ == kForward) {                    // 刚从正向切来
    SaveKey(ExtractUserKey(iter_->key()), &saved_key_);
    while (true) {
      iter_->Prev();
      if (!user_comparator_->Compare(ExtractUserKey(iter_->key()),
                                     saved_key_) < 0 ... ) break;
    }                                              // 先跳过同 user_key 的全部旧版本
    direction_ = kReverse;
  }
  FindPrevUserEntry();                             // 236-276
}
```

正向时内部迭代器停在**当前 user_key 的最新条目**上;要取"上一个用户键",必须先越过当前 user_key 的所有历史版本(db_iter.cc:216-229),再进入 `FindPrevUserEntry` 反向扫描。`FindPrevUserEntry`(db_iter.cc:236-276)维护 `(value_type, saved_key_, saved_value_)` 三元组:向回扫,遇到"更旧的 user_key 且已缓存了一个有效值"即停(244-247);中途遇到删除标记则清空缓存(250-252)——即**反向也要正确处理"删除标记藏在更后面"的情况**。反向方向上无法使用正向那种"skip 一段"的技巧,只能把整个 key 的版本链扫完,这就是 `DBIter` 注释里两种方向定位方式的差异(db_iter.cc:41-45)。

反向切换回正向同样有专门处理:`iter_` 停在"该 user_key 全部条目之前",所以先 `iter_->Next()` 跨进这个 key 的条目区间,再交给 `FindNextUserEntry`(db_iter.cc:144-158)。

### 4.3 顺带机制:读采样

`DBIter::ParseKey` 统计读过的 key/value 字节,每约 `kReadBytesPeriod`(1MB)调用一次 `db_->RecordReadSample(k)`(db_iter.cc:122-131;常量 dbformat.h:45),这是 seek-compaction 触发数据的来源——长迭代会主动"投票"让拖后腿的文件参与 compaction。

---

## ⑤ 设计动机与取舍

### 5.1 为何删除标记必须"到底层"才能丢(规则B)

反证法:假设 compaction 在 L2 归并时无条件丢弃 K 的删除标记,而 K 的旧值还在 L3。此后读 K:L2 查不到、L3 命中——**已删除的数据复活**。因此只有确认"level+2 及以下再也不可能有这个 user_key"时,删除标记才冗余。`IsBaseLevelForKey`(version_set.cc:1517-1536)正是检查 `input_version_->files_[level+2 .. 6]` 是否有文件范围覆盖该 key。同时代码注释(db_impl.cc:973-979)给出另外两个安全条件:本次 compaction 的两个输入层已含所有更高优先级数据;输入中 seq 更小的同 key 条目会被规则A随后丢掉——所以删除标记不需要"挡住"任何东西了。规则B还要求 `seq <= smallest_snapshot`(db_impl.cc:970-972):若删除标记本身比最老快照新,可能仍有快照依赖它遮蔽旧值,不能丢。

### 5.2 IsBaseLevelForKey 的代价与摊还

朴素实现要对每个 drop 候选做"逐层逐文件二分",最坏 5 层 × log(文件数)。实现用了两个技巧:只查 level+2 起(version_set.cc:1520),且每层维护游标 `level_ptrs_[lvl]`——随着输出 key 单调前进,游标只进不退,单次调用均摊 O(1)(最坏把某层剩余文件扫完,但全过程总计 O(总文件数));注释里仍留了二分优化 TODO(version_set.cc:1518)。这里有个前提:compaction 输出 key 是单调前进的——`ShouldStopBefore`、`IsBaseLevelForKey`、`SetupOtherInputs` 都依赖这一遍历顺序。

### 5.3 smallest_snapshot:空间回收 vs 快照长寿

规则A/B 都以 `smallest_snapshot` 为水位。无快照时取 `LastSequence`(db_impl.cc:911),一切旧版本立即可回收;一旦应用创建快照并长期持有,水位被钉死在最老快照处,所有比它新的同 key 版本都无权丢弃规则A(因为旧快照可能还需要看它们?——准确说:比水位旧的条目才可能被丢弃;水位之上(更新)的同 key 条目链必须保留,因为某快照可能正好需要其中某一条)。极端情况下一个被遗忘的快照会让 deleted/overwrite 数据无限堆积。这是 LevelDB 与用户之间的显式契约:**快照既是读一致性工具,也是 GC 障碍**。

### 5.4 输出切分的两个维度与 trivial move

输出文件大小受两把尺子约束:自身字节(`MaxOutputFileSize`,随层级放大)与 grandparent 重叠字节(`ShouldStopBefore`)。后者动机与 `IsTrivialMove` 的禁用条件同源(version_set.cc:1501-1506):如果一个输出文件与 L+2 大量重叠,它落盘后下次 L+1→L+2 compaction 就要吞下巨大的输入;同理,单文件 trivial move 若与 grandparent 重叠过多,等于把"零成本移动"变成"未来昂贵的归并",宁可现在多花一次真正的 compaction。`ShouldStopBefore` 切分后 `overlapped_bytes_` 清零重来(version_set.cc:1553-1556),是一个工程上够用的启发式。

### 5.5 MergingIterator 不用堆、L0 特殊处理

子迭代器数量 = 2 个 memtable + 7 层迭代器 ≈ 个位数(读路径),compaction 输入最多 2 项或"L0 文件数+1"。线性扫描常数极小、无堆的 sift 开销与指针追逐,作者在 merger.cc:138-140 明确记录了这一取舍(留了堆的 TODO)。L0 的特殊性在于**文件间 key 范围任意重叠**(写 flush 不做区间划分),所以无论读路径(version_set.cc:233-236)还是 compaction 输入(version_set.cc:1227,1232-1237),L0 都要逐文件开子迭代器归并,而 L≥1 用"拼接"迭代器即可;这也是 L0→L1 compaction 必须把所有重叠 L0 文件拉进输入的原因(version_set.cc:1291-1299)。

---

## ⑥ FAQ

**Q1:为什么 compaction 期间要释放 mutex(db_impl.cc:919),哪些数据结构仍需要锁?**
释放锁让前台读写不被磁盘 IO 阻塞。compaction 操作的三样东西都是不可变快照:`Compaction` 持有 `input_version_`(已 Ref,version_set.cc:1287-1288)、输出文件私有(`CompactionState`),写 manifest 时才短暂重新加锁(`InstallCompactionResults` 在 mutex_.Lock() 之后调用,db_impl.cc:1045-1049)。`imm_` 例外:主循环探测到后要抢锁做 minor compaction(db_impl.cc:931-937)。

**Q2:规则A中 `last_sequence_for_key` 初始化为 `kMaxSequenceNumber` 有何作用?**
它保证每个 user_key 的第一个(最新)条目永远不满足规则A(水位必小于等于 kMaxSequenceNumber-1,dbformat.h:67)。若误初始化为 0,首条会被误丢。

**Q3:被 drop 的条目为何还要更新 `last_sequence_for_key`(db_impl.cc:983)?**
考虑 [PUT k@5, DELETE k@7] 且 7>snapshot≥5:DELETE 按…不,看反例 [DELETE k@9(被规则A丢?不会,它是首条)]。正确场景:K 有 DELETE@10 与 PUT@5,snapshot≥10 时 DELETE 保留(或按规则B丢),PUT@5 依赖 last_sequence_for_key=10(或删除标记产生的值)被规则A丢掉。若 drop 路径不更新该变量,PUT@5 的判定会看到再上一条(可能不存在),导致误保留。一句话:遮蔽链必须贯穿被丢弃的条目。

**Q4:`ParseInternalKey` 失败的损坏条目为什么要原样输出(db_impl.cc:952-956)?**
"不掩盖错误":把损坏数据原封不动带到输出层,让上层工具(`leveldbutil`/repair)仍能发现它;同时重置 user_key 状态,避免损坏 key 污染后续判定。

**Q5:为什么 compaction 输出还要重新验证可读(FinishCompactionOutputFile,db_impl.cc:864-876)?**
写路径(NewWritableFile/TableBuilder)不保证介质无错;生成后立即经 table_cache 读一次元数据,把"写坏了"当场变成 compaction 错误,而不是留到未来某次读才爆。

**Q6:`NewMergingIterator` 对 n=1 直接返回子迭代器本身(merger.cc:184-186),调用方会因此少掉哪类 bug 或多出哪类坑?**
省掉一层虚调用与对象;坑在于所有权转移——调用方 delete 返回值即 delete 子迭代器,不能再用原始指针。LevelDB 全库按"delete 返回的 Iterator"约定使用。

**Q7:MergingIterator 交替 Next/Prev 会怎样?**
每次换向触发对全部非当前 child 的一次 `Seek(key())`(merger.cc:63-75,89-104),O(n·logN);锯齿形遍历(Next/Prev 交替)性能显著退化。应用层应尽量单向扫描。

**Q8:DBIter::Seek 之后 `skipping` 传 false,Next 之后传 true(db_iter.cc:286,174),差别是什么?**
Seek 时 saved_key_ 只是临时缓冲,目标 key 本身是合法命中(若首条是 value);Next 时 saved_key_ 是刚返回过的 user_key,必须整段跳过(传 true),否则会重复返回同一 user_key。

**Q9:手动 CompactRange 为什么对每一层循环调用而不是一次做完(db_impl.cc:594-596)?**
单层 compaction 只把数据下沉一层;要把 `[begin,end]` 推平到"不再有重叠"的层,必须逐层驱动,且每层结束后的 manifest 状态决定下一层的输入选择。`max_level_with_files` 避免对之下无数据的层做无用功(db_impl.cc:587-591)。

**Q10:memtable flush 的结果为什么会落到 L1/L2 而不总是 L0(db_impl.cc:531-537)?**
`PickLevelForMemTableOutput`(version_set.cc:470-495)在 L0/L+1 无重叠、L+2 重叠字节受限时逐级下沉(最深到 2)。减少 L0 文件数(读写都要线性扫 L0)与 L0→L1 compaction 频率;代价是可能提前占用下层空间。

---

## ⑦ 深挖问题(供下一轮调研)

1. **规则A的保守性边界**:当存在 seq > smallest_snapshot 的大量覆盖写时,规则A对"被更老快照需要"的判定是全保留——能否利用快照链(SnapshotList 有序)精确计算"下一个更老快照的 seq"来细化水位?RocksDB 的 bottommost/序列号裁剪走的就是这条路,LevelDB 未做。
2. **`ShouldStopBefore` 的低估**:切分输出时 `overlapped_bytes_=0`(version_set.cc:1555),而 `grandparent_index_` 不回退——已越过、且新输出仍可能重叠的 grandparent 字节不再计入,后续输出可能再度与同一 grandparent 严重重叠。验证 db_test 中 `Boundaries` 相关用例如何覆盖此行为,以及是否应改为"减去已计部分"。
3. **MergingIterator 的 O(n) FindSmallest 与换向成本**:children≈9 时线性扫描最优,但若把读路径扩展(如多层 L0、更多 memtable)或实现分层压缩变体,堆/loser tree 的临界点在哪?可写 microbenchmark 验证 merger.cc:138 注释的经验区间。
4. **DBIter 反向遍历的复杂度上界**:`FindPrevUserEntry` 对每个 user_key 都要扫完其全部历史版本(db_iter.cc:236-264);在"单 key 万次覆盖"负载下 Prev 的摊还代价与正向的差距,以及 saved_value 的 1MB 容量释放策略(db_iter.cc:95-102,255-258)在多大 value 下的实际收益。
5. **手动 compaction 与前台写的公平性**:`TEST_CompactRange` 占用 `manual_compaction_` 单槽(db_impl.cc:625-630),期间 `MaybeScheduleCompaction` 仍会调度普通 compaction(判空条件 676 行含 manual),两者在 BackgroundCompaction 中 manual 优先(717-721);大规模 CompactRange 对前台 P99 写延迟的影响值得压测。

---

### 附:本篇覆盖文件清单

| 文件 | 关注点 |
| --- | --- |
| db/db_impl.cc | 三入口、DoCompactionWork、InstallCompactionResults、NewInternalIterator |
| db/db_impl.h | CompactionState/ManualCompaction/CompactionStats 定义 |
| db/builder.cc | BuildTable:迭代器→单个 sstable |
| db/db_iter.cc | DBIter 全部定位/移动逻辑 |
| db/memtable.cc(.h) | MemTableIterator、SkipList 表项编码 |
| table/merger.cc | MergingIterator(任务书所写 db/merger.cc 的真实位置) |
| table/iterator.cc | Iterator 基类、EmptyIterator(任务书所写 util/iterator.cc 的真实位置) |
| include/leveldb/iterator.h | 接口契约、CleanupNode |
| table/iterator_wrapper.h | key 缓存包装 |
| table/two_level_iterator.cc | 索引/数据二级惰性迭代 |
| table/block.cc | Block::Iter 的 restart 二分与 Prev |
| table/table.cc | Table::NewIterator/BlockReader(组合图引用) |
| db/version_set.cc(.h) | PickCompaction、MakeInputIterator、IsBaseLevelForKey、ShouldStopBefore、IsTrivialMove、PickLevelForMemTableOutput、LevelFileNumIterator |
| db/dbformat.h(.cc) | 内部键排序、config 常量、kValueTypeForSeek |
