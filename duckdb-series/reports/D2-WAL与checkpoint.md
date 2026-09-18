# D2 · WAL 与 checkpoint:持久性的实现

> 基线 commit `7e886f44428e90c8379d4d34e2afb866108ff079`。卷一(06-事务与MVCC.md)讲了 commit 九步与组提交;本篇下潜到文件侧:WAL 的字节格式、checkpoint 全流程、以及崩溃后如何把两者拼回去。除特别说明外,行号均基于该 commit 的源码树。
>
> 路线:§1 记录格式 → §2 写入与落盘时机 → §3 触发 → §4 checkpoint 主流程 → §5 恢复 → §6 truncate 安全性 → §7 设计动机。核心角色四件套:`WriteAheadLog`(写)、`SingleFileCheckpointWriter`(检查点)、`SingleFileBlockManager`(文件头与空闲块)、`WriteAheadLogReplayer`(重放)。

## 0. 一张图:WAL 记录格式与 checkpoint 时间线

```text
WAL 文件 = [header 帧] + N 个"帧"(entry),每帧自带长度与校验:

 偏移 0          +--------------------------------- 一帧 ---------------------------------+
                 | size (uint64) | checksum (uint64) | payload (BinarySerializer)         |
                 +---------------+-------------------+------------------------------------+
                                                       | field 100: WALType (uint8 枚举)    |
                                                       | field 101+: 该类型的专属字段        |

 WALType 取值(wal_type.hpp:15-64):                     专用字段示例(wal.json 生成):
   98 WAL_VERSION   99 CHECKPOINT   100 WAL_FLUSH(空帧)   CHECKPOINT  -> 101: meta_block
   1 CREATE_TABLE   2 DROP_TABLE                           INSERT_TUPLE-> 101: DataChunk
   3 CREATE_SCHEMA  4 DROP_SCHEMA    5/6 VIEW              UPDATE_TUPLE-> 101: column_indexes
   8/9/10 SEQUENCE  11-14 MACRO/TYPE                       102: chunk(数据列+rowid)
   20 ALTER_INFO    21/22 TABLE_MACRO 23/24 INDEX
   25 USE_TABLE     26 INSERT_TUPLE  27 DELETE_TUPLE
   28 UPDATE_TUPLE  29 ROW_GROUP_DATA 30/31 TRIGGER

 加密 WAL(version 3)帧变为: size(明文) | nonce | AES-GCM(checksum+payload) | tag
   (写入 write_ahead_log.cpp:167-189;读取 wal_replay.cpp:136-211)

 checkpoint 时间线(单文件存储引擎):
   t0  提交路径判定可 checkpoint,拿排他 checkpoint_lock(duck_transaction_manager.cpp:548)
   t1  主 WAL 追加 CHECKPOINT(meta_block) 帧并 flush,随后关闭主 WAL
        (storage_manager.cpp:295-299)
   t2  新提交改写到 .wal.checkpoint —— WAL"临时分叉" (storage_manager.cpp:304-312)
   t3  并行写表数据块 + 全新 catalog 元数据(meta block 链)   |
   t4  fsync 数据块 → 写新 DatabaseHeader,翻转 h1/h2        |  与写事务并发
        (single_file_block_manager.cpp:1391-1418)            |
   t5  truncate 数据文件尾部连续空闲块                        |
        (single_file_block_manager.cpp:1230-1252)            |
   t6  WALFinishCheckpoint: 等 .wal.checkpoint 落盘 → 原子改名覆盖主 WAL
        (storage_manager.cpp:316-347)                ◄───────┘
   t7  合并索引 checkpoint delta,提交 checkpoint 事务(checkpoint_manager.cpp:364-375)

   崩溃窗口分析: t1 前崩溃 → 无痕迹,主 WAL 照常重放; t1..t6 之间崩溃 → 恢复时看到
   CHECKPOINT 标记(+ 可能的 .wal.checkpoint),用 WAL 中记录的 meta_block 与文件
   header 的 meta_block 比对,即可判定这次 checkpoint 是否真正完成(wal_replay.cpp:519-587)。
```

## 1. WAL 记录格式:帧化 + 校验 + 序列化载荷

先明确三个文件名(`storage_manager.cpp:357-363`):主 WAL 是 `<db>.wal`;checkpoint 期间新提交写 `<db>.wal.checkpoint`;崩溃恢复合并两份 WAL 时先产出 `<db>.wal.recovery` 再改名顶替主 WAL。WAL 对象有惰性初始化:构造不打开文件,第一次真正写条目才 `Initialize`(`write_ahead_log.cpp:54-72`),这为"没有写入就无需落任何字节"的只读场景省掉一次文件创建。

### 1.1 三个版本号

WAL 自身有版本:明文为 2,加密为 3(`src/storage/write_ahead_log.cpp:32-33`)。v1 是无帧化的历史格式,重放时直接在文件流上反序列化,没有校验(`src/storage/wal_replay.cpp:101-104`)。

### 1.2 WAL header 帧

每个新 WAL 文件的第一个条目是 `WAL_VERSION` 帧:文件非空就跳过(`write_ahead_log.cpp:249-254`)。v1.3+ 的文件还会写入 `db_identifier`(与数据库主 header 中的随机标识配对)和 `checkpoint_iteration`(`write_ahead_log.cpp:275-286`)。header 明确不加 checksum——注释说明它本身携带版本号,用于自举(`write_ahead_log.cpp:260`)。恢复时这两样东西用来拒绝"张冠李戴"的 WAL:identifier 不匹配直接抛 "WAL does not match database file."(`wal_replay.cpp:790-793`);iteration 只容忍"恰好差 1"的两种崩溃窗口(`wal_replay.cpp:795-812`)。

### 1.3 帧格式:内存缓冲、整帧校验

写入侧每个条目经过两层。外层 `WriteAheadLogSerializer` 先确保 WAL 初始化、写 header,再以 `field 100 = WALType` 开头(`write_ahead_log.cpp:207-216`);内层 `ChecksumWriter` 把载荷缓冲进 `MemoryStream`,`End()` 时整帧落地:

```cpp
// src/storage/write_ahead_log.cpp:126-136
auto data = memory_stream.GetData();
auto size = memory_stream.GetPosition();
// compute the checksum over the entry
auto checksum = Checksum(data, size);
// write the checksum and the length of the entry
stream->Write<uint64_t>(size);
stream->Write<uint64_t>(checksum);
// write data to the underlying stream
stream->WriteData(memory_stream.GetData(), memory_stream.GetPosition());
// rewind the buffer
memory_stream.Rewind();
```

即每帧 = `size + checksum + payload`。加密版把 checksum 与 payload 一起加密,外挂 nonce 与 GCM tag(`write_ahead_log.cpp:167-189`)。读取侧逐帧读入缓冲、校验后只在内存里反序列化(`wal_replay.cpp:106-133`)。

### 1.4 记录类型清单

所有条目结构体在 `src/include/duckdb/storage/wal_entry.hpp`,其 Serialize/Deserialize 由 `src/include/duckdb/storage/serialization/wal.json` 生成(`wal_entry.hpp:25-27`)。逐个列出(类型值见 `wal_type.hpp:15-64`):

| 类型 | 写入函数 | 载荷 |
|---|---|---|
| CREATE_TABLE=1 | `WriteCreateTable` (`write_ahead_log.cpp:300-304`) | 完整 `CreateInfo`(建表语句级) |
| DROP_TABLE=2 | `:309-315` | QualifiedName(schema 路径+表名) |
| CREATE/DROP_SCHEMA=3/4 | `:320-333` / `:480-493` | QualifiedName(v2.0.0 起支持嵌套 schema) |
| CREATE/DROP_VIEW=5/6 | `:465-475` | CreateInfo / QualifiedName |
| CREATE/DROP_SEQUENCE=8/9,SEQUENCE_VALUE=10 | `:338-348`, `:350-357` | usage_count + counter + last_value |
| CREATE/DROP_MACRO=11/12,TABLE_MACRO=21/22 | `:362-384` | CreateInfo / QualifiedName |
| CREATE/DROP_TYPE=13/14 | `:434-444` | CreateInfo / QualifiedName |
| ALTER_INFO=20 | `:552-573` | `AlterInfo`;加 UNIQUE 约束时附带索引存储信息 |
| CREATE_INDEX=23 | `:413-423` | 索引 catalog 信息 + `index_storage_info` + **索引原始字节块**(`:405-410`) |
| DROP_INDEX=24 | `:425-429` | QualifiedName |
| USE_TABLE=25 | `:498-502` | QualifiedName,设定后续数据操作的"当前表" |
| INSERT_TUPLE=26 | `WriteInsert` (`:504-511`) | 一个 DataChunk(整批行) |
| DELETE_TUPLE=27 | `:527-535` | 单列 DataChunk,内容是 row_id |
| UPDATE_TUPLE=28 | `:537-547` | column_indexes + (更新列 + row_id) 的 chunk |
| ROW_GROUP_DATA=29 | `:513-525` | 整个 row group 的持久化数据(块指针),写完即把块标记为已 checkpoint(`:520-524`) |
| CREATE/DROP_TRIGGER=30/31 | `:449-460` | CreateInfo / QualifiedName+基表 |
| CHECKPOINT=99 | `WriteCheckpoint` (`:291-295`) | MetaBlockPointer(本次 checkpoint 的根元块) |
| WAL_FLUSH=100 | `FlushMarker` (`:585-606`) | 空(仅作 commit 边界) |

注意数据操作是"行组逻辑"的:INSERT 记录的是数据本身而非页镜像;而批量 append 走 `ROW_GROUP_DATA`,把已经顺序写好的数据块**指针**记进 WAL,重放时零拷贝并声明块占用(`wal_replay.cpp:1318-1368`,其中 deserialization-only 阶段就先 `MarkBlockAsUsed` 防止块被占用冲突,`:1327-1335`)。

### 1.5 迭代器与损坏处理

没有独立的 WALIterator 类:重放用 `BufferedFileReader` + `WriteAheadLogDeserializer::GetEntryDeserializer` 逐帧构造(`wal_replay.cpp:99-216`)。两级容错:

- **长度越界**:entry size 超过文件剩余字节 → `SerializationException`,被视为 torn tail(`wal_replay.cpp:113-118`);
- **校验失败**:checksum 不匹配 → `DataCorruptionException`,这是真损坏,不作容错(`wal_replay.cpp:125-131`)。

`CanSkipPayload` 支持只反序列化不执行的"预扫描"模式——帧已读过并校验过,直接跳到帧尾终结符(`wal_replay.cpp:227-231, 244-279`)。这正是恢复第一遍扫描的实现基础。

## 2. 写入侧:缓冲与落盘时机

### 2.1 文件缓冲层

`BufferedFileWriter` 持有 4KB 用户态缓冲(`src/include/duckdb/common/serializer/buffered_file_writer.hpp:17`)。小写入先攒缓冲,满 4KB 才 write 到 OS;超过两倍缓冲的大写入直接透传,避免拆成多次小 IO(`src/common/serializer/buffered_file_writer.cpp:29-61`)。`Flush()` 只是 `write(2)` 进页缓存,**不 fsync**;持久性只由 `SyncHandle()/Sync()` 保证(`buffered_file_writer.cpp:63-85`)。

### 2.2 flush marker 与组提交(文件侧视角)

卷一讲过组提交的事务侧;文件侧的机制是:每个 commit 写完数据帧后追加一个空的 `WAL_FLUSH` 帧,`writer->Flush()` 推给 OS 但不 sync,然后把自己帧尾偏移登记到 `requested_sync_offset`(`write_ahead_log.cpp:585-606`)。真正 fsync 在 `SyncUpTo` 中:一次 sync 覆盖"当前所有已 flush 的 marker",其余等待者在条件变量上坐享其成;`durable_offset` 只在 sync 成功后推进,sync 失败则给整个 WAL 打上 `sync_failed` 毒标记,此后拒绝再 sync(`write_ahead_log.cpp:608-653`,毒标记语义见 `:642-647` 与 `:616-618`)。事务管理器在锁外调用 `SyncUpTo(info.wal_sync_offset)` 完成这一步(`src/transaction/duck_transaction_manager.cpp:498-504`)。

### 2.3 回滚 = 截断

commit 失败时 `SingleFileStorageCommitState::RevertCommit` 直接把 WAL 截回事务开始前的大小(`src/storage/storage_manager.cpp:674-683`);成功路径的 `FlushCommit` 在"无其他事务"时于事务锁内直接 sync,否则只写 marker、锁外再 sync(`storage_manager.cpp:685-703`,决策点在 `duck_transaction.cpp:293-299`)。

### 2.4 写入的完整调用链(从 commit 到字节)

把卷一的 commit 九步与文件侧串起来:提交线程先在拿锁之前把批量 append 的"乐观块"flush+sync(`PreFlushOptimisticBlocks`,`duck_transaction.cpp:215-228`),这样 WAL 里的块指针引用的数据在参与提交竞争前就已持久;随后拿 WAL 锁,`storage->Commit` 写数据帧、`undo_buffer.WriteToWAL` 写行级变更帧(`WriteToWAL`,`duck_transaction.cpp:230-267`),最后按有无并发决定 sync 时机(§2.3)。

## 3. checkpoint 的触发

三个入口,最终都汇到 `StorageManager::CreateCheckpoint`:

1. **自动(提交时)**:commit 路径先问 `CanCheckpoint`(`duck_transaction_manager.cpp:140-166`)——只读事务、加载中、以及"没理由 checkpoint"都会否决;然后 `TryGetCheckpointLock` 拿排他锁(`:159-164`)。"理由"即 `DuckTransaction::AutomaticCheckpoint` → `SingleFileStorageManager::AutomaticCheckpoint`:当前 WAL 大小 + 本次提交估算字节数超过 `checkpoint_wal_size`(默认 `1<<24` = 16MB,`src/include/duckdb/main/config.hpp:92`)或条目数超限(`storage_manager.cpp:857-874`,估算来源 `duck_transaction.cpp:179-195`)。写事务从第一次修改起就持有**共享** checkpoint 锁,保证判定后没有并发写者在途(`duck_transaction.cpp:350-364`)。超大提交还可以"跳过 WAL 直接 checkpoint"(阈值判定 `duck_transaction_manager.cpp:364-376`),发现 checkpoint 做不成再回退补写 WAL(`:404-414`)。类型裁决在 `GetCheckpointType`(`:168-213`):有其他活动事务、或有人还需要读旧版本时降级为 `CONCURRENT_CHECKPOINT`(`:203-204`,以及 `storage_manager.cpp:263-267`)。
2. **手动**:SQL `CHECKPOINT` / `FORCE CHECKPOINT` 被变换成 `checkpoint()`/`force_checkpoint()` 表函数调用(`src/parser/peg/transformer/transform_checkpoint.cpp:7-21`),执行时进入 `DuckTransactionManager::Checkpoint`:要求当前事务无本地修改;非 force 拿不到排他锁就报错,force 则锁住 `start_transaction_lock` 自旋等待所有活动事务结束(`duck_transaction_manager.cpp:215-261`,锁逻辑 `:234-253`)。
3. **shutdown/detach**:`AttachedDatabase::Close` 按 `checkpoint_on_shutdown` 配置触发,且以 `CheckpointWALAction::DELETE_WAL` 运行——checkpoint 完成后允许直接删掉 WAL 文件(`src/main/attached_database.cpp:366-395`,DELETE_WAL 用法在 `:392`)。

另外 `CreateCheckpoint` 自己还有一道闸:WAL 为空且非强制时直接返回(`storage_manager.cpp:777-778`);FULL checkpoint 前还要尝试拿 vacuum 排他锁,拿不到就降级并发(`:757-769`)。

三种 checkpoint 类型的语义差异值得记住(`src/include/duckdb/common/enums/checkpoint_type.hpp:29-38`):`FULL_CHECKPOINT` vacuum 已删除行与过期更新,要求无人读旧版本;`CONCURRENT_CHECKPOINT` 只把已提交数据落盘、几乎不做清理,可在有活动事务时运行;`VACUUM_ONLY` 仅回收空间,是内存库的专用形态——内存库没有磁盘 checkpoint,`CreateCheckpointWriter` 会直接产出 `InMemoryCheckpointer`(`storage_manager.cpp:745-751`),其"WAL 大小"由提交时的估算字节数模拟累加(`duck_transaction_manager.cpp:416-422`)。

## 4. checkpoint 主流程:`SingleFileCheckpointWriter::CreateCheckpoint`

代码在 `src/storage/checkpoint_manager.cpp:199-376`,分六步:

**(1) 准备两支元数据笔**:`metadata_writer` 与 `table_metadata_writer`,并预取本次 checkpoint 的根元块指针(`checkpoint_manager.cpp:215-219`)。

**(2) 先立字据**:把根 meta block 写进主 WAL 作为 `CHECKPOINT` 帧,flush 后关闭主 WAL,把 WAL 对象换成 `.wal.checkpoint`(`storage_manager.cpp:294-313`)。关键注释值得全文引用:

```cpp
// src/storage/checkpoint_manager.cpp:221-229(节选)
// write a checkpoint flag to the WAL
// in case a crash happens during the checkpoint, we know a checkpoint was instantiated
// we write the root meta block of the planned checkpoint to the WAL
// during recovery we use this:
// * if the root meta block matches the checkpoint entry, we know the checkpoint was completed
// * if the root meta block does not match the checkpoint entry, we know the checkpoint was not completed
```

**(3) 写数据与 catalog**:按依赖序扫描全部 catalog 条目(`GetCatalogEntries`,`checkpoint_manager.cpp:117-197`;外键排序与依赖重排 `:251-253`),序列化进 `metadata_writer`(`:275-281`)。每张表在 `WriteTable` 里先拿表级 checkpoint 锁,再经 `DataTable::Checkpoint` → `RowGroupCollection::Checkpoint` 重写行数据块(`checkpoint_manager.cpp:694-713`;`src/storage/data_table.cpp:1583-1600`;`src/storage/table/row_group_collection.cpp:1712`)。未变化的表直接复用旧元数据指针(`src/storage/checkpoint/table_data_writer.cpp:137-147`)。

### 4.0 列级重写与共享 partial block

RowGroup 内部的重写由 `ColumnDataCheckpointer::Checkpoint` 决定:先扫一遍所有列是否有版本变更(`HasChanges`),整行组无变更就只把涉及块标记为 checkpointed、原样沿用(`src/storage/table/column_data_checkpointer.cpp:411-436`,标记访客在 `:400-409`);有任何变更则整行组重写——重写时重新选择压缩函数,这就是"checkpoint 时才压缩"的落点。多个行组的尾巴块通过 `PartialBlockManager` 合并共享,避免每个 row group 各自占用半空块,只有 `FULL_CHECKPOINT` 型的 partial block 才允许与 free list 交互(`src/storage/partial_block_manager.cpp:43, 71-99`;类型在 `checkpoint_manager.cpp:97` 注入)。字符串溢出块也走同一套块分配(`src/storage/checkpoint/write_overflow_strings_to_disk.cpp`)。

**(4) 元数据收口**:flush 两支笔(`checkpoint_manager.cpp:283-284`),然后写新的 `DatabaseHeader`(meta_block、block_alloc_size、vector_size,`:295-299`),由 `SingleFileBlockManager::WriteHeader` 落地:写 free list、`iteration_count++`、**先 fsync 数据再写 header**、把 header 写进非活动槽位并翻转、再 fsync 一次(`src/storage/single_file_block_manager.cpp:1328-1431`,要点分别在 `:1338`、`:1391-1392`、`:1413-1416`、`:1418`)。free list 作为元数据链的一部分写在专属块里(`FreeListBlockWriter`,`:1288-1306` 与 `:1352-1372`)。

**(5) 截断文件**:回收文件尾部的连续空闲块(`checkpoint_manager.cpp:336` → `single_file_block_manager.cpp:1230-1252`)。

**(6) 收尾 WAL**:有 WAL 时拿 WAL 锁调用 `WALFinishCheckpoint`(`checkpoint_manager.cpp:343-355`):`.wal.checkpoint` 没被写过 → 删主 WAL 重建空文件;写过 → 等它 fsync 后**改名覆盖**主 WAL(`storage_manager.cpp:316-347`)。最后合并索引在 checkpoint 期间的增量、提交 checkpoint 事务(`checkpoint_manager.cpp:364-375`)。"checkpoint 是否干净"的判定就一行:WAL 标记里的 meta block 是否等于当前文件 header 的 meta block(`storage_manager.cpp:741-743`,`IsRootBlock` 在 `single_file_block_manager.cpp:902-904`)。

### 4.1 checkpoint 期间的读写事务:WAL 的"临时分叉"

`WALStartCheckpoint` 在 WAL 锁内先 `WaitForDurability`(等所有已发布 commit 落盘),再启动 checkpoint 事务——它的 start_time 定义了可见性上界,此后新 commit 一律写进 `.wal.checkpoint`(`storage_manager.cpp:251-313`,锁序注释 `:254`,可见性设定在 `checkpoint_manager.cpp:66-77`,`SetActiveCheckpoint` 在 `duck_transaction_manager.cpp:113-115`)。也就是说主 WAL 冻结为只读历史,新写入走旁路文件;checkpoint 收尾时旁路文件整体改名为新主 WAL。恢复侧对"主 WAL + .wal.checkpoint"这对中间态有完整的对账逻辑(见 §5)。

### 4.2 元数据的 checkpoint(衔接报告 A2)

meta block 是单链表:每个 4MB 元块头部存下一块指针,`MetadataWriter::NextBlock` 负责把"下一块地址"回填进当前块尾(`src/storage/metadata/metadata_writer.cpp:43-61`);`GetMetaBlockPointer` 返回 (block, offset) 二元组(`:23-30`)。checkpoint 重写**整条链**:catalog、每张表的 row group 指针、统计、free list 全部写入新块,最终只有 header 里的 `meta_block` 与 `free_list` 两个指针指向新世界(`DatabaseHeader::Write`,`single_file_block_manager.cpp:274-289`)。旧链的块通过 `MarkBlocksAsModified` 进入 modified_blocks,本次 checkpoint 后进入 free list 复用(`single_file_block_manager.cpp:972-1007`,收编发生在 `WriteHeader` 的 `:1334` 与 `:1420-1428`)。

## 5. 恢复:`LoadDatabase` → WAL replay

加载顺序是先 catalog 后 WAL:`SingleFileCheckpointReader::LoadFromStorage` 按 header 的 meta block 读出整个 checkpoint(`storage_manager.cpp:581`,入口 `checkpoint_manager.cpp:393-413`),然后 `WriteAheadLog::Replay` 重放 WAL(`storage_manager.cpp:595-596`)。

### 5.1 两遍重放

`ReplayLog`(`wal_replay.cpp:463-668`)先做**只反序列化的预扫描**,目的有三个:找到 CHECKPOINT 标记的位置与内容、记录最后一个 WAL_FLUSH 帧尾、探测文件尾部是否有 torn write(`:479-507`)。预扫描只容忍 `SerializationException`(即 torn tail),其他异常照抛(`:508-514`)。随后才是真正执行的第二遍:每遇到 WAL_FLUSH 就 commit 一次重放事务,索引的挂载推迟到 commit 边界统一完成(`:621-644`)。第二遍出错时 ROLLBACK:序列化错误视为 torn tail 容忍,其余错误(或 `abort_on_wal_failure` 设置)直接抛(`:645-659`)。

### 5.2 CHECKPOINT 标记的三种对账

预扫描发现 CHECKPOINT 标记后,先验证它必须在文件末尾(`:519-531`),然后按文件系统现场分三种情况(`:536-586`):

- **无 .wal.checkpoint 且 checkpoint 干净**(标记的 meta block == header meta block):WAL 内容已全部落盘,连重放都不需要,返回空(`:543-546`);
- **无 .wal.checkpoint 但 checkpoint 未完成**:崩溃发生在"写标记之后、换 header 之前"。标记是逻辑末尾,**把 WAL 截断到最后一个 commit 边界**(`checkpoint_truncate_offset` 在 `:490-493` 记录,截断在 `:594-608`),防止半个 checkpoint 标记之后的空间被新写入复用;
- **有 .wal.checkpoint**:这是 t2..t6 窗口崩溃。checkpoint 干净 → 直接把 .wal.checkpoint 改名为主 WAL 并重放它(`:552-571`);不干净 → 把主 WAL(CHECKPOINT 标记之前的部分)与 .wal.checkpoint 合并进 `.wal.recovery`,同步后改名重放(`MergeIntoRecoveryWAL`,`:403-461`,合并起点 `:413`)。只读库不能改名,只能按顺序重放两个文件(`:556-557, 576, 660-665`)。

### 5.3 部分写记录的容错与修剪

torn tail(序列化异常)在预扫描与正式重放中都被容忍——抛出点分别是帧长度/校验层(§1.5)与重放循环(`:645-654`)。重放成功到一半时,返回的 WAL 对象带 `successful_offset` 与 `UNINITIALIZED_REQUIRES_TRUNCATE` 状态(`:666-667`);下次该 WAL 首次被使用时先截断到这个偏移(`write_ahead_log.cpp:64-65`,惰性截断分支 `:86-90`),保证半条记录永远不会被复用为合法帧。重放中还有数据级自检:DELETE 的 row id 越界会被当作损坏拒绝(`wal_replay.cpp:1388-1392`)。

### 5.4 重放各类型的要点

重放不是机械反演写入:它要在一个"只有 catalog 骨架"的库上重建可运行状态。

- `CREATE_TABLE` 走 binder 重新绑定约束(`BindCreateTableCheckpoint`,`wal_replay.cpp:836-852`),而不是直接灌 CreateInfo;
- `USE_TABLE` 只是设置 `state.current_table`,后续 INSERT/DELETE/UPDATE 都隐式作用于它(`:1288-1300`)——这是 WAL 中数据帧比 catalog 帧小的原因;
- `INSERT` 调 `LocalWALAppend` 且**不做约束校验**(`:1302-1316`),与正常写入路径不同:重放的数据已被约束检查过一次;
- `UPDATE` 把 chunk 里的 rowid 列拆出后走 `UpdateColumn`(`:1397-1420`);
- 索引的两阶段:重放时索引数据块被 `ConvertToPersistent` 落为新持久块(`:894-932`),但索引本体先进 `replay_index_infos` 暂存,等 WAL_FLUSH 提交时才挂到表上(`:628-632`);同一重放事务里 CREATE 又 DROP 的索引按 oid 精确摘除(`:873-881, 1274-1281`);
- 序列值:重放的不是 DDL 而是运行期计数(`usage_count/counter/last_value`,`:1169-1179`),保证重启后序列不回发。

## 6. WAL truncate 的安全条件

代码里真正调用 `WriteAheadLog::Truncate`(`write_ahead_log.cpp:81-93`)的地方只有三处,共同前提是**被截掉的尾部不存在任何需要保留的信息**:

1. commit 回滚:截回本事务开始前的大小——这段只含本事务自己写的帧(`storage_manager.cpp:680`);
2. 恢复修剪:截到重放成功的偏移——之后的内容已被判定为 torn 或属于失败的 checkpoint 标记(`write_ahead_log.cpp:64-65`);
3. 失败 checkpoint 标记清理:截到最后一个 WAL_FLUSH 帧尾,且要求标记必须位于文件末尾(`wal_replay.cpp:490-493, 528-531, 594-608`)。

`BufferedFileWriter::Truncate` 支持截进尚未 write 的用户态缓冲(`buffered_file_writer.cpp:87-103`),所以"已 Flush 未 Sync"的帧也能无损收回。而日常运行中**从不**主动截断 WAL 的历史部分:主 WAL 只能被 checkpoint 之后的一次性动作(删除或整体改名)清空——因为 WAL 中较老的帧仍承担"上一个 checkpoint 之后的全部历史"职责,没有 checkpoint 的确认,任何截断都可能丢已提交数据。

### 6.1 调试与故障注入点

源码埋了一套测试钩子,读代码时可当作"关键决策点"的索引:`PRAGMA checkpoint_abort` 在 checkpoint 各阶段(写 header 前/截断前/收尾前等)注入崩溃,分别位于 `checkpoint_manager.cpp:286-292, 331-340` 与 `single_file_block_manager.cpp:1386-1389`,恢复侧的"合并改名前/删 checkpoint WAL 前"注入在 `wal_replay.cpp:448-457`;WAL 侧有 fsync 延时与强制 fsync 失败(`write_ahead_log.cpp:610-612, 630-635`),以及 checkpoint 人为睡眠(`checkpoint_manager.cpp:239-242`)。这些钩子覆盖的正是 §0 时间线上每个崩溃窗口的边界。

## 7. 设计动机

1. **为什么是逻辑 WAL 而非页镜像**:DuckDB 的表数据是列存 + 分块压缩,物理页格式随 checkpoint 变化,页级 redo 需要冻结页布局并做页内偏移修补。记录"行 + catalog 操作"的逻辑 WAL 让 WAL 格式与存储格式解耦(INSERT 直接序列化 DataChunk,`write_ahead_log.cpp:504-511`),重放时走与正常写入相同的代码路径(`wal_replay.cpp:1302-1316`),代价是恢复慢——但 DuckDB 用 ROW_GROUP_DATA 把大 append 优化成"记指针"(`write_ahead_log.cpp:513-525`),把最重的场景消掉了。
2. **为什么只在 checkpoint 时压缩/清理**:WAL 天然只追加;删除与更新的真正回收(vacuum)要求没有任何事务还需要读旧版本,这恰好是 `FULL_CHECKPOINT` 用排他 checkpoint 锁保证的前提(`checkpoint_type.hpp:30-38`,`duck_transaction_manager.cpp:159-164`)。平时清理要么阻塞快照、要么为部分回收维护复杂引用计数;推到 checkpoint 一次性做,读多写少的分析负载几乎无感。
3. **为什么 truncate 需要以 full checkpoint 为界**:主 WAL 的每个帧都可能属于某个未 checkpoint 的提交,唯一安全的截断点是"确认这段历史已经物化进数据文件"。CHECKPOINT 帧就是这条确认边界;所以恢复中截断只发生在标记之前(`wal_replay.cpp:594-608`),运行中清空只发生在 `WALFinishCheckpoint` 的删除/改名(`storage_manager.cpp:322-344`),二者都以 meta block 对账为前提。
4. **为什么先往 WAL 写 CHECKPOINT 标记记录**:这是整个崩溃一致性方案中最便宜的一笔保险。数据文件的新版本要写很久(分钟级),而标记只花一次顺序 append;有了它,恢复时用一次指针比较就能区分"checkpoint 已完成,可跳过全部重放"与"checkpoint 半途,需重放/合并",不需要任何逐块校验(`checkpoint_manager.cpp:221-229`,`wal_replay.cpp:540-546`)。
5. **为什么双 header 只在 checkpoint 时轮换**:h1/h2 两个 DatabaseHeader 槽位 + iteration 号构成原子切换点(创建时即写好两个,`single_file_block_manager.cpp:596-629`;加载时取 iteration 大者,`:706-724`)。如果日常提交也翻转头(如传统 ARIES 式设计),每次 commit 都要同步两个扇区;DuckDB 让 header 只在 checkpoint 变——平时文件内容完全不可变,崩溃一致性简化为"读旧 header 还是新 header"的单比特问题,写入放大也最低。
6. **为什么用 `.wal.checkpoint` 分叉而不是停写**:checkpoint 可能耗时很长,阻塞写事务不可接受。让新提交走旁路文件,checkpoint 冻结的主 WAL 成为不可变输入,收尾时一次 `MoveFile` 原子并轨(`storage_manager.cpp:332-344`);恢复侧的合并逻辑(`wal_replay.cpp:403-461`)就是这个并轨在崩溃后的重放,代价是恢复代码要理解双文件状态。
7. **为什么 commit 边界是空帧而不是给每帧打提交号**:WAL_FLUSH 空帧让"重放到哪算一个事务"变成纯顺序扫描问题,预扫描可以在不执行任何副作用的情况下确定所有 commit 边界与 torn 点(`wal_replay.cpp:479-507`);同时它天然携带偏移量,成为组提交 `requested_sync_offset` 的记账单位(`write_ahead_log.cpp:592-605`)。
8. **为什么按帧校验而不是整文件校验**:WAL 是唯一"明知会读到半条"的文件,torn tail 是预期输入而不是错误。逐帧的 size+checksum(§1.3)让损坏的粒度天然对齐到"最后一次成功写的帧":尾部残帧因长度越界或校验不符被丢弃,而之前所有帧不受影响(`wal_replay.cpp:113-131`);若校验是全局的,一个 torn 尾巴会让整个文件不可判定,恢复逻辑将被迫引入二级启发式。
9. **为什么数据帧前要放 USE_TABLE**:`INSERT/DELETE/UPDATE` 帧本身不带表名,当前表由最近的 USE_TABLE 帧决定(`wal_replay.cpp:1288-1300`)。一个 `INSERT INTO t SELECT ...` 的多批次 append 只需在开头写一次表名,数十万个 chunk 帧全部免掉重复的限定名序列化——对"高频小帧"的 WAL 来说,这条压缩规则几乎零成本。

## 8. 写作素材清单(文件:行号)

1. `src/storage/write_ahead_log.cpp:126-136` — 帧格式落地:size+checksum+payload
2. `src/storage/write_ahead_log.cpp:249-289` — WAL header 帧与 db_identifier/checkpoint_iteration
3. `src/storage/write_ahead_log.cpp:585-653` — FlushMarker 与 SyncUpTo 组提交/毒标记
4. `src/include/duckdb/common/enums/wal_type.hpp:15-64` — 全部 WALType 枚举值
5. `src/include/duckdb/storage/serialization/wal.json:1-15` — 条目结构体的 schema 化定义入口
6. `src/storage/wal_replay.cpp:106-133` — 帧长度越界与 checksum 双重校验
7. `src/storage/wal_replay.cpp:479-514` — 预扫描与 torn tail 容忍
8. `src/storage/wal_replay.cpp:519-586` — CHECKPOINT 标记三路对账
9. `src/storage/wal_replay.cpp:403-461` — 双 WAL 合并进 .wal.recovery
10. `src/storage/checkpoint_manager.cpp:199-376` — CreateCheckpoint 全流程
11. `src/storage/storage_manager.cpp:251-347` — WALStartCheckpoint/WALFinishCheckpoint(分叉与并轨)
12. `src/storage/single_file_block_manager.cpp:1328-1431` — WriteHeader:free list、fsync 顺序、双 header 翻转
13. `src/storage/metadata/metadata_writer.cpp:43-61` — meta block 单链回填
14. `src/transaction/duck_transaction_manager.cpp:140-213` — CanCheckpoint/GetCheckpointType 决策树
15. `src/transaction/duck_transaction_manager.cpp:341-571` — CommitTransaction 中 WAL 写入与 checkpoint 的交织
16. `src/storage/storage_manager.cpp:857-874` — 自动 checkpoint 阈值判定(默认 16MB,config.hpp:92)
