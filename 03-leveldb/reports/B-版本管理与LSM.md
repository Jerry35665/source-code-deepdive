# B 篇 · 版本管理与 LSM 分层(Version / VersionSet / Manifest)

> 调研对象:leveldb 1.23(commit 7ee830d0)。核心文件:`db/version_set.h`(393 行)、`db/version_set.cc`(1569 行)、`db/version_edit.{h,cc}`、`db/filename.cc`、`db/snapshot.h`。所有结论均标注 `文件:行号`,行号为仓库内实际行号。

---

## ① 全景:Version / VersionSet / Manifest 三者关系

LevelDB 把"磁盘上每个层级有哪些 SSTable"这件事建模为一个**不可变快照对象 Version**。`version_set.h:5-13` 的头注释开宗明义:DBImpl 的状态由一组 Version 表示,最新者称为 current,旧 Version 为活跃迭代器提供一致视图;Version/VersionSet 线程不兼容,所有访问需外部加锁。

三者的关系:

```
CURRENT(1 个) ──指向──> MANIFEST-000005(log 格式追加文件)
                              │ 逐条重放 VersionEdit 记录
                              ▼
             VersionSet(内存元数据枢纽)
              ├─ Version 链表(dummy_versions_ 环形双向链表)
              │    v3(current) ← v2 ← v1   ← 旧版本供迭代器/compaction 持引用
              ├─ next_file_number_ / last_sequence_ / log_number_ 等全局标量
              └─ compact_pointer_[7](每层下轮 compaction 起点游标)
```

- **Version**:一份不可变的"层级 → FileMetaData 列表"映射,`files_[config::kNumLevels]`(7 层,`dbformat.h:25`),外加 seek 触发统计与 compaction 得分缓存(`version_set.h:148-164`)。
- **VersionSet**:全库唯一的版本管理器,持有 Version 环形双向链表的头 `dummy_versions_`,`current_ == dummy_versions_.prev_`(尾部即最新,`version_set.h:310-311`);同时托管文件号分配(`NewFileNumber()`/`ReuseFileNumber()`,`version_set.h:194-203`)、`last_sequence_`、`log_number_` 与每层 compaction 游标 `compact_pointer_`(`version_set.h:315`)。
- **Manifest**:物理文件 `MANIFEST-[0-9]+`,内容是 log 格式的 VersionEdit 记录流(`version_set.cc:804-831`)。`CURRENT` 文件只有一行,即当前生效的 MANIFEST 文件名(`filename.cc:51-53,123-139`)。新库第一次打开时写 `MANIFEST-000001` 并创建 CURRENT(`db_impl.cc:181-214,NewDB`)。

LSM 层级形态(7 层,常数定义于 `dbformat.h:25-45`):

| 层 | 文件键区间 | 容量上限 | compaction 触发 |
|---|---|---|---|
| L0 | **允许互相重叠**,按文件号新→旧排序读取 | 文件数 ≤ 4(kL0_CompactionTrigger) | size:文件数;write 限速:8/12 个 |
| L1..L6 | 层内文件键区间互不重叠、按 smallest 排序 | L1=10MB,此后每层 ×10(`version_set.cc:41-52`) | size:总字节 / 层容量 |
| 输出文件大小 | — | 2MB(`options.h:116` max_file_size) | — |

层次间的数据流:memtable 冻结为 imm → `WriteLevel0Table` 生成 L0 文件(`db_impl.cc:505-539`,若范围允许可借 `PickLevelForMemTableOutput` 直落 L1/L2,`version_set.cc:470-495`)→ 后台 `PickCompaction` 逐层下推。文件命名规则见 `filename.cc:20-69`:`%06llu` 六位数字编号,`.log`(WAL)、`.ldb`(新 SST)/`.sst`(旧后缀,`filename.cc:33-41` 读取时兼容,`table_cache.cc:53-57`)、`MANIFEST-xxxxxx`、`CURRENT`、`LOCK`、`LOG`、`*.dbtmp`。

---

## ② Version 不可变性与其上的查找流程

### 2.1 不可变性与引用计数

Version 构造函数私有、拷贝被 delete(`version_set.h:123-134`),一旦生成永远不改内容:任何修改都走"Builder 生成新 Version → AppendVersion"的 copy-on-write 路径。生命周期靠 `refs_` 计数:

- `Ref()` 简单加一(`version_set.cc:453`);
- `Unref()` 减到 0 时 `delete this`(`version_set.cc:455-462`);
- 析构时把自己从环形链表摘除,并对持有的每个 `FileMetaData` 减引用、归零即 delete(`version_set.cc:67-85`)。注意 `FileMetaData` 本身也被多版本共享( refs 字段,`version_edit.h:18-27`)——这就是为什么旧 Version 只需 O(1) 保留指针而非拷贝文件元数据。

`AppendVersion`(`version_set.cc:760-775`)把新版本插到链表尾并 Unref 旧 current。谁在持旧 Version?三类:活跃迭代器(`db_impl.cc:1100-1102`,NewInternalIterator 里 `current->Ref()` 并在清理回调中 Unref)、进行中的 compaction(`version_set.cc:1287-1288`,`input_version_->Ref()`,析构时 `ReleaseInputs`,`version_set.cc:1493-1497`)、以及 `DBImpl::Get` 中的临时持有(`db_impl.cc:1135-1138,1164`)。这正解释了"旧 Version 存在的意义":迭代器打开的 SSTable 迭代器必须在快照语义下稳定存活。

### 2.2 Get 的层级查找流程

入口 `DBImpl::Get`(`db_impl.cc:1121-1166`):持锁取 snapshot 序列号、Ref 住 mem/imm/current,然后**解锁**执行查找——memtable → imm → `Version::Get`。返回后再持锁调 `UpdateStats(stats)`,若返回 true 则 `MaybeScheduleCompaction()`(`db_impl.cc:1159-1161`)。

`Version::Get`(`version_set.cc:324-400`)本体是一个回调骨架:构造 `State`(内嵌 Saver 收集结果),交 `ForEachOverlapping` 按新→旧顺序逐文件查,匹配函数 `State::Match` 里调 `TableCache::Get`(`table_cache.cc:100-112`,内部 `Table::InternalGet` 二分 block + filter)。文件定位由 `ForEachOverlapping`(`version_set.cc:281-322`)完成,分两段:

**L0:线性过滤 + 按年龄排序**(`version_set.cc:285-302`)。因为 L0 文件键区间可能重叠,无法二分,只能对每个文件做 `smallest/largest` 用户键区间判断;命中的文件按 `number` 降序(`NewestFirst`,`version_set.cc:277-279`,文件号越大越新)逐个探测——保证读到的是该 key 的最新版本。

**L≥1:一次二分,至多一个候选**(`version_set.cc:305-321`)。层内文件互不重叠,`FindFile`(标准二分,`version_set.cc:87-105`)返回"第一个 largest ≥ 目标内部键"的文件下标;若目标的用户键还小于该文件的 smallest,则本层无数据,否则这一个文件就是唯一候选。

**结果语义**(`version_set.cc:361-374` 的 switch):SSTable 内部按内部键排序,Seek 命中的第一条记录就是该 user key 在序列号快照下的最新条目——`kTypeValue` 记为 kFound 终止,`kTypeDeletion` 记为 kDeleted **同样终止**(删除标记让查找短路,不必再搜更老的层)。

一个易被忽略的细节:LookupKey 构造时用 `kMaxSequenceNumber | kValueTypeForSeek` 保证"找 ≤ snapshot 的最大 seq"(seek 语义,`dbformat.h:55-60`)。

### 2.3 查找代价统计:allowed_seeks(seek 触发 compaction 的燃料)

`State::Match` 有个精巧逻辑:本次 Get 若要读**多于一个**文件,就把"第一个被读的文件"记进 `stats.seek_file`(`version_set.cc:344-349`)——它意味着"如果第一个文件里就有答案就不用花第二次 seek",所以把账记在第一个文件头上。`UpdateStats`(`version_set.cc:402-413`)对它做 `allowed_seeks--`,归零即把该文件标为 `file_to_compact_` 并返回 true。

`allowed_seeks` 在文件首次进入版本时初始化(`Builder::Apply`,`version_set.cc:650-664`):

```cpp
// We arrange to automatically compact this file after
// a certain number of seeks.  Let's assume:
//   (1) One seek costs 10ms
//   (2) Writing or reading 1MB costs 10ms (100MB/s)
//   (3) A compaction of 1MB does 25MB of IO: ...
// This implies that 25 seeks cost the same as the compaction
// of 1MB of data. ...
f->allowed_seeks = static_cast<int>((f->file_size / 16384U));
if (f->allowed_seeks < 100) f->allowed_seeks = 100;
```

即:1 次 seek ≈ 压平 40KB 数据的成本,保守取 16KB/seek,下限 100 次。

任务书中的 "file_overreaded 统计" 在 LevelDB 中并不存在该字段——它是 RocksDB 的概念;LevelDB 的对应物就是上述 `allowed_seeks`(`version_edit.h:22`)+ 迭代路径的 `RecordReadSample`(`version_set.cc:415-451`):迭代器每消费约 1MB(`config::kReadBytesPeriod`,`dbformat.h:45`)采样一次,若同一 user key 匹配到 ≥2 个文件(说明存在跨文件的同键多版本,合并有利),就按同样的 UpdateStats 扣减,由 `DBImpl::RecordReadSample`(`db_impl.cc:1180-1185`)接回调度。

### 2.4 迭代器视图与 LevelFileNumIterator

`Version::AddIterators`(`version_set.cc:229-245`):L0 每个文件一个独立迭代器全部合并;L≥1 用 `NewConcatenatingIterator`——两级迭代器:上层 `LevelFileNumIterator`(`version_set.cc:163-208`)遍历"文件元数据",其 `key()` 是文件 largest 键、`value()` 是 16 字节的 (file_number, file_size) 定长编码,下层回调 `GetFileIterator`(`version_set.cc:210-220`)拿这 16 字节去 TableCache 懒打开真实 SSTable。这个"把文件当条目"的抽象让 L≥1 层表现得像一张逻辑大表。

### 2.5 GetStats 之外的辅助查询

- `OverlapInLevel`(`version_set.cc:464-468`):L0 走全扫(L0 文件不保证有序,传 `disjoint_sorted_files = level > 0`),L≥1 走二分(`SomeFileOverlapsRange`,`version_set.cc:121-156`)。
- `GetOverlappingInputs`(`version_set.cc:498-538`):收集 [begin,end] 的重叠输入。**L0 有个扩张-重扫循环**:新增文件可能扩大键区间(`version_set.cc:522-534`),一旦扩张就 `inputs->clear(); i = 0` 从头再来,保证闭包完整——这是 L0 允许重叠在"选输入"侧的直接代价。
- `PickLevelForMemTableOutput`(`version_set.cc:470-495`):memtable 落盘时,若 L0 无重叠且逐层检查"下一层无重叠、且与 level+2 重叠字节 ≤ 10×target_file_size",最多推到 `kMaxMemCompactLevel = 2`(`dbformat.h:42`),减少昂贵的 L0→L1 compaction。

---

## ③ Manifest 格式与恢复

### 3.1 VersionEdit 编码:逐字段

MANIFEST 的每条记录就是一个 `VersionEdit` 的序列化。Tag 常量(`version_edit.cc:14-24`)写盘后不可变:

| Tag | 字段 | 载荷编码 |
|---|---|---|
| 1 | Comparator | varint32 tag + 长度前缀字符串 |
| 2 | LogNumber | varint64 |
| 3 | NextFileNumber | varint64 |
| 4 | LastSequence | varint64 |
| 5 | CompactPointer | varint32 level + 长度前缀 InternalKey |
| 6 | DeletedFile | varint32 level + varint64 文件号 |
| 7 | NewFile | varint32 level + varint64 文件号 + varint64 文件大小 + 两个长度前缀 InternalKey(smallest/largest) |
| 9 | PrevLogNumber | varint64(tag 8 曾被 large value ref 使用后废弃) |

`EncodeTo`(`version_edit.cc:42-85`)按上述顺序拼接;`DecodeFrom`(`version_edit.cc:106-204`)是循环 `GetVarint32(tag)` + switch,未知 tag 或残留字节即 Corruption。注意 tag 采用 TLV 自描述结构,天然向后兼容;每个字段都是可选的(has_* 位,`version_edit.h:93-97`),编码时只写出现过的字段。

一个 EncodeTo 不处理但 LogAndApply 依赖的事实:`LogAndApply`(`version_set.cc:777-790`)在提交前强制补齐 `log_number / prev_log_number / next_file_number / last_sequence` 四个标量,保证任意一条 MANIFEST 记录都携带恢复所需的全局状态。

### 3.2 LogAndApply:提交一条版本变更

`version_set.cc:777-859`,流程:

1. Builder 基于 current_ 生成新 Version `v`,随后 `Finalize(v)` 算得分(793-798);
2. 若 `descriptor_log_ == nullptr`(本进程首次写),创建新 `MANIFEST-<manifest_file_number_>` 并 `WriteSnapshot` 写入当前版本全量快照(804-814;WriteSnapshot 实现 `version_set.cc:1069-1097`:一条巨型 VersionEdit 记录,含 comparator、compact_pointers、全部文件);
3. **解锁**写记录并 Sync(817-840,写 MANIFEST 期间不持锁),若是新建的 MANIFEST,再 `SetCurrentFile` 原子切换 CURRENT(`filename.cc:123-139`:先写 `<db>/MANIFEST-x.dbtmp` 再 rename 成 CURRENT,借 rename 的近原子性);
4. 成功则 `AppendVersion(v)` 并推进 `log_number_`;失败则删 v、删残留 manifest(842-856)。

compact_pointer 的持久化时机在 `SetupOtherInputs`(`version_set.cc:1440-1445`):选中输入后立即更新内存游标并写入 edit,注释说明"若 compaction 失败,下次换一个键区间重试"——游标先记后做,是一种以轮转公平性换取实现简单的取舍。

### 3.3 Recover:重放与损坏容忍

`VersionSet::Recover`(`version_set.cc:861-992`):

1. 读 `CURRENT`,校验以 `\n` 结尾(875-878);指向的 MANIFEST 缺失直接 Corruption(884-888)。
2. 用 log::Reader(带校验和)逐条读记录,`DecodeFrom` 后**先比对 comparator 名**(914-919,防用不同排序读旧库)。
3. 每条记录喂给 `Builder::Apply` 增量应用,同时抓取 4 个标量的最后一次出现值(926-944)。
4. 完整性检查:`have_next_file / have_log_number / have_last_sequence` 三者缺一即 Corruption(950-957)——这就是 WriteSnapshot 必须写全量的原因。
5. `Builder::SaveTo` 生成恢复版本,Finalize + AppendVersion(967-977);`manifest_file_number_ = next_file`、`next_file_number_ = next_file + 1`(973-974,注意:**下一个 MANIFEST 直接复用 next_file 号**,而不是再分配)。
6. `ReuseManifest`(`version_set.cc:994-1023`):仅当 `options.reuse_logs` 且旧 MANIFEST < 2MB 时,以 `NewAppendableFile` 续写旧 MANIFEST,省一次快照;否则置 `*save_manifest = true`,由 `DB::Open` 补一次 LogAndApply 落新快照(`db_impl.cc:1527-1531`)。

上游 `DBImpl::Recover`(`db_impl.cc:292-383`)再加两道闸:遍历目录把所有 live 文件号与磁盘比对,缺文件直接报 Corruption(344-361);收集 `number >= log_number` 的 WAL 逐个重放进 memtable(`RecoverLogFile`),最后统一 `SetLastSequence`。CURRENT 不存在时按 create_if_missing 决定 NewDB 或报错(305-322)。

### 3.4 Builder:编辑的批量应用与损坏防御

`VersionSet::Builder`(`version_set.cc:569-731`)把一串 VersionEdit 增量应用到 base 版本上,避免中间态拷贝:

- 状态:每层一个 `std::set<FileMetaData*, BySmallestKey>`(按 smallest 内部键排序,文件号打破平局,572-586)+ `deleted_files` 号集合;
- `Apply`(629-669):记 compact_pointers、deleted、added;新增文件在此初始化 allowed_seeks;
- `SaveTo`(672-715):对每层做 base 文件与 added 文件**按 smallest 键的有序归并**;
- `MaybeAddFile`(717-730):真正落文件的地方——被 delete 集合命中的跳过;`level > 0` 时断言新文件 largest < 下一文件 smallest(层内不重叠不变量)。

SaveTo 末尾在 `#ifndef NDEBUG` 下再做一次全层重叠扫描,发现重叠直接打印并 `std::abort()`(`version_set.cc:699-713`)。这份偏执来自真实事故:leveldb 曾在 level-1..n 出现重叠文件导致读返回错误结果,该断言与 `AddBoundaryInputs`(下文)都是其补丁。

`MaybeAddFile` 里还有一个"损坏文件处理"路径值得单独说明:manifest 恢复时若记录里引用的文件实际不存在,`Recover` 本身不查(它只信 manifest),真正的校验在 `DBImpl::Recover` 的 expected 集合比对(`db_impl.cc:344-361`)与 `TableCache::FindTable` 打开失败时返回错误(`table_cache.cc:63-67`,且不缓存错误结果,修复后可自愈)。

### 3.5 快照:SnapshotList

`db/snapshot.h` 与 Version 无关但同属"一致视图"机制:`SnapshotImpl` 只封装一个 `sequence_number_`,挂在 `SnapshotList` 的环形双向链表(`snapshot.h:39-91`),New 保证 seq 单调递增(58),`oldest()`/`newest()` O(1)。它被 compaction 用来计算丢弃删除标记的安全水位:`DoCompactionWork` 中 `smallest_snapshot = snapshots_.empty() ? versions_->LastSequence() : snapshots_.oldest()->sequence_number()`(`db_impl.cc:910-914`)——所有 Version 共享同一 sequence 空间,快照挡住的只是"seq 可见性",从而间接阻止旧数据被物理删除。

---

## ④ Compaction 触发的版本侧逻辑

### 4.1 Finalize:各层得分

每次生成新 Version 都会调 `Finalize`(`version_set.cc:1031-1067`)预计算"最该压哪层":

```cpp
if (level == 0) {
  // We treat level-0 specially by bounding the number of files
  // instead of number of bytes for two reasons: ...
  score = v->files_[level].size() /
          static_cast<double>(config::kL0_CompactionTrigger);
} else {
  // Compute the ratio of current size to size limit.
  const uint64_t level_bytes = TotalFileSize(v->files_[level]);
  score = static_cast<double>(level_bytes) / MaxBytesForLevel(options_, level);
}
```

- **L0 得分 = 文件数 / 4**。注释给出两条理由(`version_set.cc:1038-1049`):大 write_buffer 下不希望频繁做 L0 compaction;L0 每次读都要合并所有文件,文件个数本身才是读放大来源(小文件、高压缩比、大量覆盖删除都会让字节数失真)。
- **L≥1 得分 = 层总字节 / 层容量**,容量 `MaxBytesForLevel`:L0/L1 都是 10MB(L0 的结果实际不用),之后每层 ×10(`version_set.cc:41-52`)。
- 最后一层(L6)不参与评分(`level < kNumLevels - 1`,1036),L6 永远不会作为"被压层"由 score 驱动。
- 取分最高的一层存入 `v->compaction_score_ / compaction_level_`。

注意"maxcompactionbytes":LevelDB 源码中**没有**该名字(RocksDB 的 `max_compaction_bytes` 对应 LevelDB 的 `MaxGrandParentOverlapBytes` = 10×target_file_size,`version_set.cc:28-32`,控制单输出文件与爷辈层的最大重叠);控制"一次 compaction 总输入上限"的是 `ExpandedCompactionByteSizeLimit` = 25×target_file_size(`version_set.cc:37-39`),用于限制输入扩张。

### 4.2 PickCompaction:size 与 seek 双触发

`VersionSet::PickCompaction`(`version_set.cc:1252-1304`),前置判断是 `NeedsCompaction()`(`version_set.h:252-255`):`score >= 1 || file_to_compact_ != nullptr`。两种触发**size 优先**(1256-1259 注释:数据量触发的 compaction 优先于 seek 触发的):

- **size 触发**:level = `compaction_level_`;起点选 `compact_pointer_[level]` 之后(largest > 游标)的第一个文件,没有则绕回键空间开头(1266-1278)——游标实现层内轮转,避免反复压同一热区间。
- **seek 触发**:直接压 `file_to_compact_`(1279-1282)。
- **L0 特判**(1290-1299):先取游标后首文件算出 [smallest,largest],再 `GetOverlappingInputs(0, ...)` **整个替换 inputs_[0]**,把所有重叠 L0 文件一网打尽(L0 允许重叠,漏文件会读出旧值)。
- 随后 `SetupOtherInputs` 补 level+1 输入(见下)。选出的输入以 `input_version_ = current_; Ref()` 钉住版本(1287-1288),期间即便新版本落地,输入集依然自洽。

`SetupOtherInputs`(`version_set.cc:1385-1446`)的三步:

1. `AddBoundaryInputs`(1360-1383)修 **boundary 文件问题**:若两个文件的最大键/最小键是同一 user key(如 `key@5` 与 `key@9` 分属两文件),只压前者会让 Get 在更上层命中后者返回**较旧数据**;算法迭代地把"smallest 与当前最大键同 user key 的文件"吸进输入集(2-3 行注释,1346-1359)。
2. 取 level+1 重叠文件为 inputs_[1];再尝试"扩容":若把 level 输入扩张后**不增加 level+1 文件数**且总字节 < 25MB(ExpandedCompactionByteSizeLimit),就扩张(1402-1431)——摊薄每次 compaction 固定的 level+1 读开销。
3. 收集 level+2 的 `grandparents_`(1435-1438),供写输出时的 `ShouldStopBefore`(`version_set.cc:1538-1560`)切分输出文件:当前输出与爷辈重叠字节超过 10×target 就提前切文件,防止制造一个未来压不动的大重叠文件。

### 4.3 Trivial move 与 IsBaseLevelForKey

`IsTrivialMove`(`version_set.cc:1499-1507`):level 输入仅 1 个文件、level+1 无输入、且爷辈总重叠 ≤ 10×target——此时不做归并,直接在 VersionEdit 里 "RemoveFile(level) + AddFile(level+1)" 改指针即可(`db_impl.cc:738-753`),零 IO。同理 `IsBaseLevelForKey`(`version_set.cc:1517-1536`,level_ptrs_ 增量游标)判断 key 之下再无更深层数据时,compaction 才能安全丢弃删除标记(`db_impl.cc:972-991`)。

### 4.4 从触发到执行再到垃圾回收

`DBImpl::BackgroundCompaction`(`db_impl.cc:708-787`)→ `DoCompactionWork`(`db_impl.cc:898-`)→ `InstallCompactionResults` → `LogAndApply`(`db_impl.cc:895`)。新版本落地后,被替换的 SSTable 并不立即删除,而是 `RemoveObsoleteFiles`(`db_impl.cc:225-290`)统一回收:live 集合 = `pending_outputs_`(正在写的文件号,防竞态)+ `VersionSet::AddLiveFiles`(**遍历所有仍被引用的 Version**,`version_set.cc:1149-1159`)逐层收集文件号;随后按文件类型裁决——kTableFile/kTempFile 不在 live 即删(并 `table_cache_->Evict`,db_impl.cc:273-275);WAL 保留 `number >= LogNumber() || == PrevLogNumber()` 的;MANIFEST 保留 `number >= ManifestFileNumber()` 的;CURRENT/LOCK/LOG 永留。删除动作特意**解锁**后批量执行(282-289)。

---

## ⑤ 设计动机与取舍

**为什么 L0 允许重叠?** L0 是 memtable 的直接落点。若强制 L0 文件不重叠,每次落盘都得与现有 L0 合并重写,写放大瞬间放大;允许重叠则 flush 是 O(memtable) 的纯追加。代价转嫁给读:Get 在 L0 退化为全扫(`version_set.cc:285-302`),因此 L0 用**文件数**而非字节做 compaction 触发(1038-1051),并用 8/12 的 slowdown/stop 阈值(`dbformat.h:31-34`)在写路径反压,保护读延迟。

**为什么层级越深越大(×10)?** 典型读路径自上而下,数据一旦沉入深层,被上层同 key 覆盖的概率骤降。10 倍容量比意味着:数据从 Ln 压到 Ln+1 后,Ln+1 中参与下次 compaction 的重叠比例约 1/10,逐层写放大收敛于 O(10);同时让 90% 的数据驻留 L6,读命中 L0-L1 的概率最大化。代价是深层数据可能长期不被重写——与"删除标记只有压到 base level 才能物理回收"(`IsBaseLevelForKey`)共同决定:对超大盘,单次全量空间回收可能要等很久。

**为什么 Version 选择 copy-on-write 而非原地改?** 一致视图需要"多版本并存":迭代器要快照、compaction 要固定的输入集、Get 要稳定候选。不可变 Version + 引用计数让这些请求各持一个 O(1) 指针;变更成本集中到 Builder 的一次有序归并(每层 O(base+added))。代价是每次提交(哪怕只动一个文件)都重建整个 `files_` 数组的 vector——文件数极大时 `LogAndApply` 的 memcpy 量可观,这是 RocksDB 后来引入 `VersionStorageInfo` 分层可变结构要解决的问题。

**为什么 MANIFEST 用 log 追加而不是整文件重写?** 提交路径只追加一条记录 + Sync,顺序写且可恢复;整文件重写会把每次 compaction 变成全量 fsync。冗余由"定期换代"控制:LogAndApply 首次调用写快照,Recover 后若 MANIFEST 过大(≥2MB 且未开 reuse_logs)就 save_manifest 换代(`version_set.cc:994-1008`),CURRENT 用 rename 切换。

**为什么 seek 也触发 compaction?** size 触发只看"量",对"少量键被疯狂点查"失明:一个 100KB 文件反复挡在某个热点 key 的读路径上,每次 Get 都多一次 seek。allowed_seeks 把 IO 成本折算成 seek 预算(16KB/seek),耗尽即压——本质是用读放大信号补写放大信号的盲区。

---

## ⑥ FAQ

**Q1:CURRENT 和 MANIFEST 是什么关系?坏一个会怎样?**
CURRENT 是指向某个 `MANIFEST-xxxxxx` 的一行指针(`filename.cc:123-139`),MANIFEST 才是元数据主体。CURRENT 缺失/未以换行结尾 → Recover 直接 Corruption(`version_set.cc:875-878`);CURRENT 指向的 MANIFEST 不存在 → Corruption(884-888)。由于 SetCurrentFile 是"写临时文件 + rename",CURRENT 本身损坏窗口极小。

**Q2:MANIFEST 记录和 WAL 记录格式一样吗?**
一样的外层封装:都是 log::Writer 的分块 record(`log_format.h`),MANIFEST 每块载荷是一个 EncodeTo 后的 VersionEdit,log 文件每块载荷是 WriteBatch。Recover 用同一个 log::Reader 带校验和重放(`version_set.cc:905-909`)。

**Q3:一个 VersionEdit 会同时包含 Add 和 Remove 吗?**
会。compaction 的 edit 同时含 `AddInputDeletions`(被压输入,`version_set.cc:1509-1515`)与新增输出文件;memtable flush 的 edit 只含 Add。Builder 的 Apply/SaveTo 保证先记录删除集合、归并时过滤,顺序无关。

**Q4:版本切换瞬间,正在执行的 Get/迭代器怎么办?**
不受影响。Get 在进入前 `current->Ref()`(`db_impl.cc:1138`),迭代器同理(1100-1102);它们钉住旧 Version,新版本照常 AppendVersion。旧 Version 要等最后一个 Unref 才析构(455-462),其文件在 RemoveObsoleteFiles 的 live 集合中,不会被误删。

**Q5:为什么 L0 score 用文件数,别的层用字节?**
见 ④.1:读 L0 要合并全部文件,文件个数才是读放大的直接度量;而字节在压缩比、小文件场景下失真。且大 write_buffer 场景下按字节触发会造成过多小 L0 compaction(`version_set.cc:1038-1049`)。

**Q6:compact_pointer_ 是干什么的?重启后会丢吗?**
它是每层 compaction 的轮转游标(PickCompaction 挑"游标后第一个文件"),实现键空间轮转、防止热点区间被反复压缩。它随 edit 的 kCompactPointer tag 持久化(`version_set.cc:1444-1445`,`version_edit.cc:64-68`),Recover 时经 Apply 恢复(`version_set.cc:630-635`),WriteSnapshot 也写(1076-1083)——不丢。

**Q7:PrevLogNumber 还有人用吗?**
已废弃但保留解析:注释明确 "PrevLogNumber() is no longer used, but we pay attention to it ... older version of leveldb"(`db_impl.cc:334-336`);缺省按 0 处理(`version_set.cc:959-961`),tag 9 仍在 DecodeFrom 中受支持(`version_edit.cc:138-144`)。

**Q8:文件号什么时候会"回收复用"?**
几乎不。`ReuseFileNumber`(`version_set.h:199-203`)只在"刚分配即放弃"时回退一格(如 WriteLevel0Table 失败后,db_impl.cc 的分配-使用间隔极小处);而 Recover 后 `next_file_number_ = next_file + 1`(`version_set.cc:974`)宁大勿小,因为文件号重置可能导致新文件覆盖旧 live 文件。

**Q9:AddBoundaryInputs 解决什么问题?为什么 Get 会读到旧值?**
同一 user key 的内部键可以恰好横跨两个文件边界(一个文件的 largest 与下一文件的 smallest 同 user key)。若只压前者,后者(更旧版本)仍留在同层,且层内二分时 Get 先命中"largest ≥ key"的后者而**提前返回旧值**——因为层内文件不重叠的假设被同键跨界打破(推理见 `version_set.cc:1346-1359`)。修复是把边界文件一并吸入 compaction 输入。

**Q10:Iterator 打开时数据库又发生 compaction,会看到中间状态吗?**
不会。迭代器持有创建时的 Version + mem/imm 引用(`db_impl.cc:1090-1103`),合并视图完全由这些不可变对象构成;新 compaction 只产生新 Version,不修改旧对象。

---

## ⑦ 深挖问题(供后续验证/实验)

1. **Builder 归并的复杂度与提交延迟**:每次 LogAndApply 都重建全部 7 层 vector(约 O(总文件数) 的指针拷贝 + set 插入 O(log n)),百万级文件的大库上,提交延迟是否成为瓶颈?可实测 `SaveTo` 耗时随文件数的曲线,并与 RocksDB 的 `VersionBuilder` 增量缓存对比。
2. **L0 重叠闭包的最坏情况**:GetOverlappingInputs 的"clear + 重扫"循环(`version_set.cc:522-534`)在 L0 全域重叠时是 O(n²);PickCompaction 选完又整体重算(1291-1298)。用随机写入 + 小 max_file_size 构造高度重叠的 L0,验证一次 compaction 输入规模是否失控(有 25×target 的扩张上限,但 inputs_[0] 本身无上限)。
3. **allowed_seeks 定价的失效模式**:模型假设 seek=10ms(机械盘);SSD 上一次 seek ≈ 0.1ms,则 16KB/seek 的换算高估了 100 倍,seek 触发的 compaction 可能几乎永不发生。可否把定价改为 options 可配?这与 RecordReadSample 的 1MB 采样周期(dbformat.h:45)同样滞后。
4. **MANIFEST 无限增长路径**:reuse_logs 关闭(默认)时,每次打开都换代,但长期运行中单个 MANIFEST 只在"重启"时压缩——若进程常驻数月、每秒多次 LogAndApply,MANIFEST 会不会涨到几百 MB 并拖慢 Recover 的全量重放?观察运行 30 天库的 MANIFEST 大小与 Open 耗时。
5. **Finalize 的"单层最优"缺陷**:score 只取最大层,PickCompaction 每次只压一层;若 L1 与 L3 同时超限,只压 L1 会推迟 L3 的回收(L1→L2→L3 的连锁要等 L1 反复触发)。对比 per-level round-robin 调度(如 RocksDB 的 compaction debt 处理)对深层数据陈旧度的影响。

---

### 附:关键代码索引

| 主题 | 位置 |
|---|---|
| Version 数据结构与不变量 | `db/version_set.h:148-165` |
| Ref/Unref/析构链 | `db/version_set.cc:67-85,453-462` |
| Get 全流程 | `db/version_set.cc:281-400`;`db/db_impl.cc:1121-1166` |
| allowed_seeks 定价 | `db/version_set.cc:650-664,402-413` |
| VersionEdit tag 编码 | `db/version_edit.cc:14-24,42-85,106-204` |
| LogAndApply / 换代 | `db/version_set.cc:777-859`;`db/filename.cc:123-139` |
| Recover / ReuseManifest | `db/version_set.cc:861-1023` |
| Builder / SaveTo / MaybeAddFile | `db/version_set.cc:569-731` |
| Finalize 得分 | `db/version_set.cc:1031-1067` |
| PickCompaction / SetupOtherInputs | `db/version_set.cc:1252-1304,1385-1446` |
| Trivial move / IsBaseLevelForKey / ShouldStopBefore | `db/version_set.cc:1499-1560` |
| obsolete 文件回收 | `db/db_impl.cc:225-290` |
| 文件命名 / CURRENT 原子切换 | `db/filename.cc:20-121,123-139` |
| SnapshotList | `db/snapshot.h:39-91` |
