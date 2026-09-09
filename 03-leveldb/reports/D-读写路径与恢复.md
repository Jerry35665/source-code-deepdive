# D 报告:LevelDB 读写路径与崩溃恢复

> 调研对象:leveldb v1.23(commit 7ee830d0)。所有结论均标注 `文件:行号`,行号以该版本源码为准。

## ① 全景:一条 Put 的两步,一条 Get 的三查

LevelDB 的写路径可以概括为"**两步落盘、一步调度**":调用方先把操作编码进 `WriteBatch`(纯内存的二进制表示),随后进入 `DBImpl::Write` 的 writer 队列排队;轮到队头后,先经 `MakeRoomForWrite` 检查/腾挪空间,再把整个批次(可能是合并后的 group commit)**先追加写 WAL(log),再应用到 memtable**,两步期间释放全局互斥锁(`db/db_impl.cc:1230-1247`)。写 log 不保证 fsync——只有 `WriteOptions::sync=true` 时才调用 `logfile_->Sync()`(`db/db_impl.cc:1238-1243`);无论是否 sync,数据在写入 memtable 并推进 `LastSequence` 后即对后续读可见(`db/db_impl.cc:1245-1257`)。

读路径是"**三查**":`DBImpl::Get` 持锁快照当前的 memtable、immutable memtable 与 current Version 三个对象并各自加引用,然后解锁,依次查 ① mem → ② imm → ③ SST 层级(current Version),命中即返回(`db/db_impl.cc:1144-1157`)。三个对象靠引用计数在解锁后依然存活;查询若下沉到 SST,会把"为找这个 key 而付过 seek 代价的文件"记入 `Version::GetStats`,返回后由 `UpdateStats` 递减该文件的 `allowed_seeks`,耗尽则触发补偿性 compaction(`db/db_impl.cc:1159-1161`,`db/version_set.cc:402-413`)。

框架层面还需要理解三个要素(细节留给 B 报告):其一,用户 key 在查询前被包装成 `LookupKey`——内部键 `(user_key, snapshot_seq, kValueTypeForSeek)`,使得 skiplist/SST 的 Seek 定位点恰好是"该快照可见的最新版本"(构造见 `db/db_impl.cc:1147`,类定义 `db/dbformat.h:184`);其二,三查的顺序编码了"新旧优先"语义——mem 比 imm 新、imm 比 SST 新,而 SST 层级间 L0 按文件号、L1+ 按键区间划分,`Version::Get` 内部正是通过 `ForEachOverlapping` 从高层向低层逐层探测(`db/version_set.cc:281,397`);其三,快照序号来自 `options.snapshot` 或 `versions_->LastSequence()` 二选一(`db/db_impl.cc:1125-1131`),后者意味着无快照的 Get 永远看到"此刻最新"的状态。

一条 Put 的完整时序(代码位置):

```
DB::Put (db/db_impl.cc:1489-1493)
  └─ WriteBatch::Put          -- 仅编码进 rep_,不碰锁
  └─ DBImpl::Write            (db/db_impl.cc:1206)
       1. 入队 writers_        (db/db_impl.cc:1213)
       2. 等待成为队头         (db/db_impl.cc:1214-1216)
       3. MakeRoomForWrite     (db/db_impl.cc:1222)
       4. BuildBatchGroup      (db/db_impl.cc:1226)  -- group commit 合并
       5. [解锁] log_->AddRecord → (sync? logfile_->Sync) → InsertInto(mem_)
                                 (db/db_impl.cc:1235-1246)
       6. [加锁] SetLastSequence,批量唤醒同组 writer (db/db_impl.cc:1257-1274)
```

## ② Write 调度器逐段解读

### 2.1 Writer 与队列

每个并发写线程构造一个栈上的 `Writer` 对象,内含 batch 指针、sync 标志、done 标志和一个绑定全局 `mutex_` 的 `CondVar`,然后**把对象地址压入成员 `writers_`(std::deque<Writer*>)**(`db/db_impl.cc:43-52`,`db/db_impl.h:186`)。排队等待用一段极简的模式:

```cpp
// db/db_impl.cc:1212-1219
MutexLock l(&mutex_);
writers_.push_back(&w);
while (!w.done && &w != writers_.front()) {
  w.cv.Wait();
}
if (w.done) {
  return w.status;
}
```

注意两点:一是唤醒后还要再查 `w.done`——队头在执行 `MakeRoomForWrite` 或写盘过程中,可能把后面"凑进同一 group"的 writer 直接标记 done 并回填 status(见 2.3);二是只有队头才有资格继续往下走,队尾全部睡眠。这个"单队头推进、其余休眠"的设计把并发写串行化成一个天然的提交点。

### 2.2 Group commit:BuildBatchGroup

队头拿到执行权后,不会只写自己的 batch,而是把队列中紧随其后的若干 writer **合并成一个大 batch**,一次写 log、一次插 memtable,摊薄每条记录的固定开销。合并逻辑在 `BuildBatchGroup`(`db/db_impl.cc:1281-1327`):

```cpp
// db/db_impl.cc:1293-1296
size_t max_size = 1 << 20;
if (size <= (128 << 10)) {
  max_size = size + (128 << 10);
}
```

规则可以归纳为四条:
1. **大小上限**:组合上限 1MB;若队头自身很小(≤128KB),上限降为 `size + 128KB`,避免一个小写被同批的大写拖慢到极限才返回(`db/db_impl.cc:1293-1296`)。
2. **sync 隔离**:队头是 non-sync 时,遇到第一个 `w->sync` 的 writer 立即截断——不能让"未落盘即返回"的语义吞掉别人的 sync 请求(`db/db_impl.cc:1303-1305`)。反过来,队头是 sync 时可以继续吞并 non-sync writer(sync 语义向下兼容)。
3. **零拷贝拼接**:第一个 writer 的 batch 直接作底,后续 batch 通过 `WriteBatchInternal::Append` 追加;一旦发生拼接,底座换成成员 `tmp_batch_`,避免修改调用方持有的 batch(`db/db_impl.cc:1316-1322`,`db/write_batch.cc:144-148`)。
4. **记录组员**:循环推进中不断更新 `*last_writer`,它标记"本组最后一个成员",用于提交后成批唤醒。

合并后的 batch 只设一次起始序号:`SetSequence(write_batch, last_sequence + 1)`,然后 `last_sequence += Count`,组内各条目按顺序各占一个序号(`db/db_impl.cc:1227-1228`)。批内原子性由 WriteBatch 格式保证(见 ②.4 与 ④)。

关于 128KB 阈值的动机值得多说一句:队头自己的 batch 很小时,如果允许组无限膨胀到 1MB,队头的返回延迟将被同组其他线程的大批量写拖长,对"单条小写"调用方产生不可控的尾延迟;`size + 128KB` 的动态上限把"搭车者"的总量约束在队头体量的一倍多一点,是吞吐与延迟之间的一处精细权衡。`tmp_batch_` 是 DBImpl 的常驻成员(`db/db_impl.h:187`),专职充当合并底座:只有当组里真的发生了拼接,才把队头 batch 的内容拷进去,组提交结束后 `Clear()` 复用(`db/db_impl.cc:1255`),避免每次合并都堆分配。

### 2.3 两步写与组员唤醒

队头在写 log 与插 memtable 期间**释放全局锁**,只靠"我是队头"这一身份排除并发写:

```cpp
// db/db_impl.cc:1235-1253
{
  mutex_.Unlock();
  status = log_->AddRecord(WriteBatchInternal::Contents(write_batch));
  bool sync_error = false;
  if (status.ok() && options.sync) {
    status = logfile_->Sync();
    if (!status.ok()) sync_error = true;
  }
  if (status.ok()) {
    status = WriteBatchInternal::InsertInto(write_batch, mem_);
  }
  mutex_.Lock();
  if (sync_error) {
    // log 状态不确定,强制 DB 进入永久失败模式
    RecordBackgroundError(status);
  }
}
```

这里有一个值得停顿的细节:**sync 失败被升级为 `bg_error_`**。注释写明,Sync 失败时这条 log 记录重启后可能在也可能不在,内存态与持久态已经分叉,唯一的补救是让 DB 从此拒绝一切写(`db/db_impl.cc:1248-1253`,`db/db_impl.cc:660-666`)。而 `log_->AddRecord` 本身失败(如磁盘满)则只返回错误给本组 writer,不炸库。

提交完成后,队头从队首连续弹出直到 `last_writer`,给每个组员回填同一个 status 并 Signal;再唤醒新队头(`db/db_impl.cc:1260-1274`)。一次磁盘写、一次 memtable 插入,N 个线程同时返回——这就是 group commit 的全部收益。

### 2.4 时序图

```
线程A(sync)      线程B          线程C(non-sync)   后台compaction
   │入队A           │入队B          │入队C
   │A==front,继续   │等待cv         │等待cv
   │MakeRoomForWrite│               │
   │BuildBatchGroup:│               │
   │  吞并B、C(B非sync可并入A组)     │
   │  [解锁] AddRecord(A+B+C)  ───────────► WAL 一个片段
   │  [解锁] logfile_->Sync()            (A 是 sync,整组 fsync)
   │  [解锁] InsertInto(mem_)            (B、C 的数据同时进内存)
   │  [加锁] SetLastSequence(3条)
   │  弹出A、B、C:B/C 回填 status+Signal;唤醒新队头
   │返回            │返回           │返回
```

顺带说明 memtable 插入的实现:`InsertInto` 用一个 `MemTableInserter`(实现 `WriteBatch::Handler` 回调)遍历 batch,每条记录调用 `mem_->Add(sequence_, type, key, value)` 并递增 `sequence_`(`db/write_batch.cc:116-137`)。memtable 侧把 user key 扩展成 8 字节 tag `(sequence<<8)|type` 的内部键插入 skiplist(`db/memtable.cc:76-100`),因此同一 key 的多次覆盖在 memtable 中都保留,靠序号定新旧。

## ③ MakeRoomForWrite 的限流阶梯

`MakeRoomForWrite(bool force)` 只由队头调用(`force` 即 `updates == nullptr`,用于 `TEST_CompactMemTable` 强制切 memtable)。它是一个 `while(true)` 阶梯,自上而下匹配(`db/db_impl.cc:1331-1405`):

| 优先级 | 条件 | 行为 | 行号 |
|---|---|---|---|
| 0 | `bg_error_` 非_ok | 直接返回该错误,拒绝一切写 | 1337-1340 |
| 1 | L0 文件数 ≥ 8(`kL0_SlowdownWritesTrigger`) | **解锁并 Sleep 1ms 一次**,此后本调用不再 delay | 1341-1352 |
| 2 | memtable 未满(`usage ≤ write_buffer_size`,默认 4MB) | break,正常放行 | 1353-1356 |
| 3 | `imm_` 非空(上一块 memtable 还没刷完) | 在 `background_work_finished_signal_` 上无限等待 | 1357-1361 |
| 4 | L0 文件数 ≥ 12(`kL0_StopWritesTrigger`) | 同样无限等待 | 1362-1365 |
| 5 | 以上都不匹配(即 memtable 已满且无阻塞因素) | **切 log + 切 memtable**:分配新 log 文件号并建新 WAL、关闭旧 log、`imm_ = mem_`、新建 memtable、`MaybeScheduleCompaction()` | 1366-1402 |

常量定义:`kL0_CompactionTrigger=4 / kL0_SlowdownWritesTrigger=8 / kL0_StopWritesTrigger=12`(`db/dbformat.h:28-34`);`write_buffer_size` 默认 4MB(`include/leveldb/options.h:83`)。

三个设计意图值得展开:

- **阶梯是"先钝刀、后硬停"**。slowdown 分支的注释说明:与其等撞上硬限制时一次延迟几秒,不如提前对每次写加 1ms 延迟,削平尾延迟;这 1ms 同时让出 CPU 给 compaction 线程(可能同核)(`db/db_impl.cc:1343-1348`)。delay 每次调用只发生一次(`allow_delay` 置 false,行 1351),防止 memtable 满写满期间的重复睡眠。
- **情形 3 与 4 等待的是同一个条件变量**。imm 刷盘完成(`CompactMemTable`)与 compaction 推进都会 `SignalAll`(见 `db/db_impl.cc:549-580`、`db/db_impl.cc:929-937`——后台 compaction 循环里每次迭代都优先处理 imm 并唤醒等待者),所以等待被设计为可重入的循环而非单次条件判断。
- **情形 5 的失败兜底**。若新 log 文件创建失败,`ReuseFileNumber` 归还文件号并 break(`db/db_impl.cc:1372-1375`),避免磁盘满时疯狂消耗文件号空间;若旧 log 关闭失败,数据可能受损,记 `bg_error_` 后仍切换到新 log(`db/db_impl.cc:1380-1390`)。

整条阶梯实际上构成了 LevelDB 写入的"背压系统":L0 是 memtable flush 的落地处,L0 文件堆积意味着 flush 快于 compaction,于是限流从 8 个文件开始逐步加压,12 个时彻底刹车,把写速率强制对齐到 compaction 吞吐。三个触发点的间隔(4/8/12)也不是随手拍的:4 是 compaction 的启动门槛(`MaybeScheduleCompaction` 依据 `kL0_CompactionTrigger` 择优,`db/dbformat.h:26-28`),8 开始写端减速给后台让路,12 才硬停——中间留了 4 个文件的缓冲带,让"compaction 正在跑、马上就能消化掉"的场景不至于误伤正常写入。

还要注意一个容易误读的细节:情形 5 的"切 memtable"分支执行完后会回到 `while(true)` 顶部**重新走一遍阶梯**(此时 memtable 是全新的,通常在情形 2 放行;但若 L0 已达 12,会再次进入情形 4 等待),所以"切完 memtable 就一定能写"并不成立——这正是限流阶梯作为循环而非 if-else 的意义。

## ④ WAL 格式:逐字段与 32KB 块机制

### 4.1 物理格式

WAL(log)与 MANIFEST 共用同一套 record 格式(`db/log_format.h:14-31`,规范见 `doc/log_format.md`):

```
文件 = 32KB 块序列(文件尾部允许不满一块)
块   = record* trailer?
record = checksum: fixed32   // crc32c,覆盖 type 字节 + data,存储前 Mask
         length:   fixed16   // 小端,payload 长度
         type:     uint8     // 0=Zero(预分配) 1=Full 2=First 3=Middle 4=Last
         data:     uint8[length]
```

- `kBlockSize = 32768`,`kHeaderSize = 4+2+1 = 7`(`db/log_format.h:27-30`)。
- **一个用户记录(一次 WriteBatch)若装不进当前块剩余空间,被切分成 First/Middle/Last 片段链**;片段不会跨越块边界。头部 7 字节中 crc 的初值是"类型字节的 crc"(`type_crc_`,对每个类型预计算 `crc32c::Value(&t,1)`),再 Extend 上 payload(`db/log_writer.cc:16-21`,`db/log_writer.cc:94-96`),即 **type 与 data 一起受校验保护,而 length 不受**——读者可自行体会:若 length 被篡改,解析会错位,最终会撞上 crc 失配或块边界,下一块重新对齐。
- 写入端每次 `EmitPhysicalRecord` 后都 `Flush()` 到 OS 页缓存,但**不 fsync**(`db/log_writer.cc:99-104`)。
- crc 存储前经过 `crc32c::Mask`(`db/log_writer.cc:95`):Mask 把高位翻转并加上一个生成多项式特征量,目的是让合法 crc 的存储表示与"全零/未初始化内存"在位模式上区分开,这样预分配文件里的零块不会被误认成合法记录。reader 侧对应 `crc32c::Unmask` 后再比较(`db/log_reader.cc:245-247`)。

### 4.2 块切割与 trailer

writer 在 `AddRecord` 中维护 `block_offset_`:

```cpp
// db/db_impl.cc 不涉及;此处为 db/log_writer.cc:44-61
const int leftover = kBlockSize - block_offset_;
if (leftover < kHeaderSize) {
  if (leftover > 0) {
    // 剩余不足 7 字节:补 0 填满块尾(trailer)
    dest_->Append(Slice("\x00\x00\x00\x00\x00\x00", leftover));
  }
  block_offset_ = 0;
}
const size_t avail = kBlockSize - block_offset_ - kHeaderSize;
const size_t fragment_length = (left < avail) ? left : avail;
```

规则:**任何 record 头部不允许起始于块尾最后 6 字节**(7 字节头装不下),这些字节成为全零 trailer,由读者跳过(`doc/log_format.md:15-17`)。一个边界特例:恰好剩 7 字节而记录非空时,writer 必须先发一个**空的 First 片段**占住这 7 字节,数据从下一块开始(`doc/log_format.md:19-22`;代码路径:`avail=0` 时 `fragment_length=0`,`begin=true,end=false` → `kFirstType`,零长记录合法)。

切割示例(`doc/log_format.md:40-53` 的 A/B/C 例子,画成图):

```
块1 (32KB)                    块2 (32KB)          块3
┌──────────────┬───────┐      ┌──────────────┐     ┌──────────┬───────┐
│FULL A(1000B) │FIRST B│      │MIDDLE B(32KB)│     │LAST B    │FULL C │
│              │(余量) │      │              │     │+6B trailer...(示意)│
└──────────────┴───────┘      └──────────────┘     └──────────┴───────┘
A=1000B 整记录;B=97270B 切成 First/Middle/Last;C=8000B 另起一块。
```

reader 侧的状态机(`db/log_reader.cc:56-174`)按逻辑记录组织片段:`kFirstType` 置 `in_fragmented_record` 并清 scratch;`kMiddleType`/`kLastType` 只有在该标志为真时才合法拼接,否则报 "missing start of fragmented record";`kFullType` 到来时若正处于片段中,说明前一条逻辑记录残缺,报 "partial record without end"。构造时可传 `initial_offset`(用于 MANIFEST 尾部追加等场景),此时 `resyncing_` 模式允许静默跳过一串 Middle/Last 片段(`db/log_reader.h:103-106`,`db/log_reader.cc:80-89`)。

### 4.3 残帧处理与 reporter 语义

`ReadPhysicalRecord`(`db/log_reader.cc:189-271`)对"残帧"的分级处理是 WAL 可靠性的关键:

1. **文件尾部截断的 7 字节头**:writer 可能死在写头中途——按 EOF 处理,不报错(`db/log_reader.cc:207-213`)。
2. **length 超出剩余 payload 且已到 EOF**:同样假定 writer 中途死亡,返回 `kEof` 不报 corruption(`db/log_reader.cc:229-232`);未到 EOF 才报 "bad record length"。
3. **crc 失配**:丢弃**整个 32KB 缓冲**——因为 length 本身可能已被破坏,若继续信任它,可能"碰巧"解析出看似合法的假记录(`db/log_reader.cc:244-256`)。这就是 32KB 分块的好处:损坏被限制在块粒度,且**下一块自然重新对齐**,不需要任何启发式重同步(`doc/log_format.md:59-62`)。
4. **`kZeroType && length==0`**:静默跳过,这是 `env_posix.cc` mmap 预分配留下的空洞(`db/log_reader.cc:235-241`)。
5. **EOF 时正处片段中**:整条逻辑记录作废但不报错——这正是"最后一条写了一半的 Put 在恢复时被丢弃"的原子性来源(`db/log_reader.cc:144-151`)。

reporter 是一个纯回调接口 `Corruption(size_t bytes, const Status&)`(`db/log_reader.h:23-30`),由调用方决定语义:恢复 WAL 时(见 ⑤)只在 `paranoid_checks` 下置失败 status,否则仅写日志"dropping N bytes"(`db/db_impl.cc:388-399`);且只在丢弃位置 ≥ `initial_offset_` 时才上报(`db/log_reader.cc:182-187`)。

## ⑤ 崩溃恢复全流程

`DB::Open` → `DBImpl::Recover`(`db/db_impl.cc:1503-1544`、`db/db_impl.cc:292-383`)的完整链条如下。

### 5.1 阶段一:文件锁与 CURRENT/manifest

1. `CreateDir` + `LockFile(LOCK)`——进程级互斥(`db/db_impl.cc:298-303`)。
2. 无 CURRENT:按 `create_if_missing` 新建(NewDB 写一个含 comparator/log=0/next-file=2/last-seq=0 的初始 manifest,再写 CURRENT;`db/db_impl.cc:181-214`),否则报错。
3. `VersionSet::Recover`(`db/version_set.cc:861-992`):读 CURRENT 得 manifest 名,用同一个 `log::Reader` 逐条读 `VersionEdit`,经 `Builder::Apply` 增量重建出各层文件集合;同时提取四个元量 `next_file / last_sequence / log_number / prev_log_number`,并校验 comparator 一致(`db/version_set.cc:909-956`)。`log_number` 的含义是:**小于它的 WAL 已经全部落盘为 SST,回放时跳过**。若 manifest 过大或 `reuse_logs` 未开,则置 `save_manifest=true`,稍后重写新 manifest(`db/version_set.cc:980-983,994-1023`)。

### 5.2 阶段二:确定回放集合与完整性检查

回到 `DBImpl::Recover`(`db/db_impl.cc:330-361`):`min_log = versions_->LogNumber()`,`prev_log` 兼容旧格式;扫描目录把所有 `number >= min_log` 的 log 收进 `logs` 并**按文件号排序**——文件号单调递增,序号即提交顺序(`db/db_impl.cc:363-364`)。同时用 live 文件集合做存在性检查:manifest 声称存在的 SST 在目录中缺失,直接 Corruption 报错(`db/db_impl.cc:344-361`)。

### 5.3 阶段三:逐个 log 回放(RecoverLogFile)

```cpp
// db/db_impl.cc:432-453(节选)
while (reader.ReadRecord(&record, &scratch) && status.ok()) {
  if (record.size() < 12) { /* log record too small */ continue; }
  WriteBatchInternal::SetContents(&batch, record);
  ...
  status = WriteBatchInternal::InsertInto(&batch, mem);
  ...
  const SequenceNumber last_seq = WriteBatchInternal::Sequence(&batch) +
                                  WriteBatchInternal::Count(&batch) - 1;
  if (last_seq > *max_sequence) *max_sequence = last_seq;
  ...
}
```

要点:
- **checksum 永远开启**,即使 `paranoid_checks=false`——注释明确:为的是让损坏导致"整个 commit 被跳过",而不是把坏数据(如超大的序号)灌进 memtable(`db/db_impl.cc:418-422`)。reporter 的 status 指针仅在 paranoid 模式下接线,非 paranoid 时损坏只记日志并继续(`db/db_impl.cc:417`)。
- 每条 log 记录即一个 WriteBatch(rep 直接 `SetContents` 零拷贝解析),`InsertInto` 重放进临时 MemTable;**batch 头部自带序号**,所以恢复后能精确还原每个条目的 seq(`db/db_impl.cc:449-453`)。
- **中途刷盘**:重放的 memtable 超过 `write_buffer_size` 就立即 `WriteLevel0Table` 落成 L0 SST,并置 `save_manifest=true`(`db/db_impl.cc:455-466`)——避免把几十个 log 全部堆进内存。
- 读完每个 log 后 `MarkFileNumberUsed`,防止后续分配的文件号与旧 log 撞号(`db/db_impl.cc:375`,`db/version_set.cc:1025-1029`)。
- **`reuse_logs` 优化**(默认关闭):若这是最后一个 log 且中途没触发过刷盘,直接 `NewAppendableFile` 续写旧 log,并把重放出的 memtable 保留为当前 memtable,省去一次 flush+新 log(`db/db_impl.cc:472-491`)。`log::Writer(dest, dest_length)` 的第二构造参数正是为此设计,`block_offset_ = dest_length % 32KB` 让续写从正确的块位置开始(`db/log_writer.cc:27-30`)。
- 全部 log 重放完成后,`max_sequence` 回填 `versions_->SetLastSequence`(`db/db_impl.cc:378-380`)。

### 5.4 阶段四:收尾

`DB::Open` 中:若 recovery 后 `mem_ == nullptr`(所有 log 都被刷盘了),分配全新 log + memtable(`db/db_impl.cc:1512-1526`);`save_manifest` 为真则写一条新 `VersionEdit`:`PrevLogNumber=0`、`LogNumber=新 log 号`,经 `LogAndApply` 落 manifest——这一步之后旧 log 才正式可删(`db/db_impl.cc:1527-1531`)。最后 `RemoveObsoleteFiles` 按"log 号 ≥ LogNumber 才保留"的规则清理陈旧 WAL,并对删除的 SST 同步 `table_cache_->Evict`(`db/db_impl.cc:247-249`,`db/db_impl.cc:273-275`)。

**恢复的可能状态总结**:崩溃窗口任意时刻,某条 Put 的结局只有三种——① 记录完整且 crc 通过 → 重放生效;② 记录残缺/截断 → 按 EOF 丢弃(整条 WriteBatch 原子消失);③ crc 失败 → 丢弃当前块并跳到下一块边界,其后记录不受牵连。已 fsync 的写必然属于 ①;非 sync 的写属于 ①②③ 皆有可能。

把各持久化组件损坏时的行为列成矩阵(便于排查线上事故):

| 受损对象 | 检测点 | 行为 | 依据 |
|---|---|---|---|
| CURRENT 缺失/不以换行结尾 | VersionSet::Recover 入口 | 报 Corruption | `db/version_set.cc:869-878` |
| CURRENT 指向的 manifest 不存在 | 同上 | 报 Corruption | `db/version_set.cc:884-888` |
| manifest 记录损坏 | log::Reader + LogReporter | 报错,DB 恢复失败(manifest 无"跳过"语义) | `db/version_set.cc:902-946` |
| manifest 缺 next-file/log-number/last-sequence 字段 | 记录读完后的完备性检查 | 报 Corruption | `db/version_set.cc:950-957` |
| 活跃 SST 文件丢失 | 目录扫描与 live 集合比对 | 报 Corruption(打开即失败) | `db/db_impl.cc:344-361` |
| WAL 记录损坏 | RecoverLogFile | paranoid 报错失败;否则记日志跳过,继续恢复 | `db/db_impl.cc:393-398,417` |
| WAL 尾部截断 | ReadPhysicalRecord | 按 EOF 处理,不算损坏 | `db/log_reader.cc:207-213,229-232` |

注意 manifest 与 WAL 的容错策略截然不同:manifest 任何损坏都致命,因为版本状态无法"部分重建";WAL 损坏只丢尾部增量,已落盘的 SST 层完好无损——这是 LSM"内存增量可再生成"性质的直接体现。

### 5.5 TableCache:文件号 → TableAndFile 的 LRU

`table_cache_` 是一个 `NewLRUCache(max_open_files - 10)`(`db/db_impl.cc:121-124,135`),key 为 `fixed64` 编码的文件号,value 为 `{RandomAccessFile*, Table*}`(`db/table_cache.cc:14-17,32-37`)。`FindTable` 未命中时打开文件并 `Table::Open`(读 index/filter block),以 charge=1 插入(`db/table_cache.cc:41-76`);**错误结果不缓存**,瞬态错误或文件修复后自动恢复(`db/table_cache.cc:63-67`)。缓存容量与 `max_open_files` 挂钩的动机:LRU 淘汰时会 `delete tf->file`(关文件描述符),使 table cache 同时充当 fd 复用池。`Evict(file_number)` 仅在 `RemoveObsoleteFiles` 删 SST 时调用(`db/table_cache.cc:114-118`),防止通过缓存句柄复活已删除文件。`Get`/`NewIterator` 借到 Table 后用 `RegisterCleanup(UnrefEntry)` 保证迭代器析构时归还缓存句柄(`db/table_cache.cc:93`)。所谓"table_cache 预热"并非 Open 时主动读全部 SST,而是 compaction 完成后用 `table_cache_->NewIterator` 校验产物可用性(`db/db_impl.cc:864-876`)顺带载入。

## ⑥ 设计动机与取舍

1. **单队头串行化 + group commit**:用一把全局互斥锁加一个 deque 实现了无锁队列般的批量提交。代价是写吞吐受"队头单线程写 log + 插 memtable"限制(解锁窗口内实际是并行的,因为队头在写时其他线程已可入队),收益是 memtable 插入天然无竞争、批次序号连续分配无 CAS。RocksDB 后来的 `WriteThread` 流水线化正是对这个瓶颈的演进。
2. **WAL 与 memtable 的一一对应**:`MakeRoomForWrite` 情形 5 中 memtable 与 log 同步切换,使得"memtable 内容 = 对应 log 的重放结果",恢复逻辑因此可以按 log 粒度推进,`LogNumber` 一个字段就能划定"哪些 WAL 可以删"。这是结构上最漂亮的不变量。
3. **32KB 块 + crc 而非整文件校验**:块边界提供了免费的重同步点,把 recordio 需要的启发式扫描变成确定性行为;代价是无小记录打包、无压缩(`doc/log_format.md:69-76`)。
4. **非 paranoid 模式下也开 checksum**:宁可丢数据也不吞坏数据,"跳过整个 commit"保住了序号单调性这一正确性根基(`db/db_impl.cc:418-422`)。
5. **sync 失败 → 永久拒绝写**:把"内存与磁盘可能分叉"当作不可恢复状态处理,是一种极端保守但实现极其简单的 RPO 策略。
6. **限流三级阶梯(4/8/12)**:把 compaction 滞后转化为写端可感知的延迟梯度,而非用户可调参数——LevelDB 刻意不提供太多旋钮,换取行为可预测。

## ⑦ FAQ

**Q1:写路径为什么能"解锁"写 log 和 memtable?会不会乱序?**
因为同一时刻只有一个队头在做这两步,队头身份由 `writers_` 队列保证;其他线程要么在队列里睡觉,要么在排队入队。注释原话:&w "protects against concurrent loggers and concurrent writes into mem_"(`db/db_impl.cc:1230-1233`)。序号在加锁状态下预先分配好(`db/db_impl.cc:1227-1228`),解锁段只是执行,不会乱序。

**Q2:非 sync 写在进程崩溃后一定丢失吗?机器断电呢?**
`log_->AddRecord` 只 `Flush()` 到 OS 页缓存(`db/log_writer.cc:102-104`),进程崩溃(非断电)时页缓存数据仍在,重放通常能拿到;断电则取决于文件系统刷盘时机,可能拿到也可能截断/丢弃——截断由残帧机制兜底(④.3),保证不会读到半条 Put。

**Q3:sync 组里的 non-sync writer 会等 fsync 吗?**
会。group commit 的提交点是唯一的:队头为 sync 时,整组(含 non-sync 成员)一次 `AddRecord + Sync` 后才一起唤醒。反过来 non-sync 队头会在 sync writer 处截断(`db/db_impl.cc:1303-1305`),所以 sync 请求永远不会被"漏 sync"的组带走。

**Q4:WriteBatch 是原子的吗?原子性来自哪里?**
来自三点:batch 内所有条目在 log 中是**同一条逻辑记录**(一条 WriteBatch rep,切割也有 First/Last 链保护,残缺即整条丢弃);memtable 插入是单线程连续执行;序号区间连续。恢复时 `record.size() < 12`(8+4 的头)直接判 corruption(`db/db_impl.cc:433-437`),`Iterate` 末尾还校验实际条数与头部 count 一致(`db/write_batch.cc:75-77`)。

**Q5:rep_ 的"自包含性"指什么?**
12 字节头内嵌 seq(fixed64)与 count(fixed32)(`db/write_batch.cc:26-27`),记录流用 tag + varint 长度前缀自描述(`db/write_batch.cc:9-14`)。因此一个 batch 无需任何外部上下文即可:直接写入 WAL(`Contents` 原样落盘)、跨线程合并(`Append` 只拼数据段并累加 count)、恢复时零上下文重放(`SetContents` + `InsertInto`)。

**Q6:MakeRoomForWrite 里为什么先判断 L0 slowdown 再判断 memtable 有没有空间?**
顺序即优先级:即便 memtable 有空间,L0 ≥ 8 时也要先吃 1ms 延迟,让 compaction 追上来——这是"预防性限流",与 memtable 是否满无关。这也解释了为什么 slowdown 分支一次调用只 sleep 一次:它针对的是单次写的延迟整形,不是死循环等待。

**Q7:恢复时多个 log 文件的回放顺序为什么重要?**
文件号即分配序,序号随写入单调递增。按文件号升序回放(`db/db_impl.cc:363-366`)保证重放进 memtable 的内部键序号单调,与崩溃前的写入序一致;乱序回放会让同一 key 的新旧版本颠倒。

**Q8:table cache 为什么大小是 max_open_files - 10?**
预留 10 个 fd 给 CURRENT/MANIFEST/LOCK/log/INFO 等非 SST 文件(`kNumNonTableCacheFiles`,`db/db_impl.cc:40,121-124`)。table cache 淘汰条目时才真正 `delete` 文件对象、归还 fd,从而把进程 fd 消耗约束在 `max_open_files` 内(`util/cache` LRU 驱逐)。

**Q9:imm_ 存在时写会停吗?**
不一定。`MakeRoomForWrite` 情形 5 会继续切换出**新** memtable 和新 log,写可以继续;只有当"memtable 又写满了、而 imm_ 还没刷完"时才真正阻塞(情形 3)。所以极端情况下内存里最多同时存在 mem + imm 两份数据,这正是 `has_imm_` 原子标志与后台优先处理 imm(`db/db_impl.cc:929-939`)存在的原因。

**Q10:为什么 recovered log 的 checksum 校验不受 paranoid_checks 控制,而损坏是否致命受?**
两层分离:checksum 决定"要不要相信这条数据"(永远不信坏的);paranoid_checks 决定"发现坏数据后数据库还能不能起来"(non-paranoid 忽略错误继续打开,paranoid 直接失败)。见 `db/db_impl.cc:417-422` 与 reporter 实现 `db/db_impl.cc:393-398`。

**Q11:MANIFEST 为什么也用 log::Writer/Reader?**
MANIFEST 是 VersionEdit 的追加序列,与 WAL 面临完全相同的问题:追加写、崩溃截断、逐条重放。复用 7 字节头 + 32KB 块格式意味着截断检测、crc 校验、块对齐逻辑全部免费获得,`VersionSet::Recover` 直接拿 `log::Reader` 读 manifest(`db/version_set.cc:905-909`)。这也解释了 `ReuseManifest` 追加复用时为什么要用 `Writer(dest, dest_length)` 的二参构造——续写必须从旧 manifest 的块偏移继续(`db/version_set.cc:1020-1022`)。

## ⑧ 深挖问题(供后续章节/读者验证)

1. **队头在 `MakeRoomForWrite` 无限等待(情形 3/4)期间,后续 sync 写全部被连锁阻塞**,且没有超时机制;若 compaction 因 `bg_error_` 停摆,会不会出现"写永久卡死而非返回错误"的死锁窗口?(线索:`bg_error_` 置位会 `SignalAll`(`db/db_impl.cc:660-666`),但需要验证所有错误路径都走了 `RecordBackgroundError`。)
2. **`BuildBatchGroup` 只从队首向队尾线性扫描,遇到 null batch(writer 在 `MakeRoomForWrite` 中)即跳过合并但仍可能被计入 last_writer?** 实际上 `w->batch != nullptr` 判断使 null-batch writer 不会被并入,但其后的 batch 仍可继续并入(`db/db_impl.cc:1308-1324`)——null batch 只可能由 `TEST_CompactMemTable` 构造,这个语义在生产路径是否可达值得确认。
3. **`kZeroType` 的预分配洞依赖 `env_posix.cc` 的 mmap 写路径**,而 Windows/其他 Env 无此行为;若有人手工在 posix log 中混入合法的 type=0 记录,reader 会静默当 BadRecord 丢弃——格式与 Env 实现存在隐式耦合(`db/log_reader.cc:235-241`)。
4. **`LastSequence` 推进的窗口**:解锁段写 log 成功但 `InsertInto` 失败时,`SetLastSequence(last_sequence)` 仍然执行(`db/db_impl.cc:1257` 不受 status 影响),而 batch 已进了 WAL——重启会重放这些数据,但本次读不到,且返回错误。这算不算"已持久化但未确认"的灰区?值得对照 4.3 的残帧语义推演。
5. **`RemoveObsoleteFiles` 在解锁窗口删除文件**(先收集、解锁删、再加锁,`db/db_impl.cc:282-289`),与并发 `NewWritableFile` 用文件号避碰;但 `pending_outputs_` 只保护 compaction 输出与 L0 落盘,若恢复期 `WriteLevel0Table` 产生的 SST 尚未 `LogAndApply`,`AddLiveFiles` 是否完整覆盖?(线索:`pending_outputs_.insert(meta.number)` 在 `db/db_impl.cc:511`。)

---

*报告完。字数统计见最终回复。*
