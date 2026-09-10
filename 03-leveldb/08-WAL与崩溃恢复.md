# 第 08 章 · WAL 与崩溃恢复:32KB 块的确定性

> 基线:LevelDB 1.23,commit `7ee830d0`。行号均以该版本源码为准。
> 一个结构性事实:**WAL 与 MANIFEST 共用同一套 record 格式**(log_format.h:14-31)——两者面临完全相同的问题(追加写、崩溃截断、逐条重放),复用意味着截断检测、crc 校验、块对齐逻辑全部免费获得。

## 8.0 WAL 格式:7 字节头 + 32KB 块

```
文件 = 32KB 块序列(文件尾部允许不满一块)
record = checksum: fixed32   /* crc32c, 覆盖 type 字节 + data, 存储前 Mask */
         length:   fixed16   /* 小端 */
         type:     uint8     /* 0=Zero 1=Full 2=First 3=Middle 4=Last */
         data:     uint8[length]
```

(kBlockSize=32768,kHeaderSize=7,log_format.h:27-30)

三个设计点:

1. **一个用户记录(一次 WriteBatch)装不进块剩余空间时切成 First/Middle/Last 片段链**,片段不跨块边界。切割示例(doc/log_format.md 的 A/B/C 例子):

```
块1 (32KB)                    块2 (32KB)          块3
┌──────────────┬───────┐      ┌──────────────┐     ┌──────────┐
│FULL A(1000B) │FIRST B│      │MIDDLE B(32KB)│     │LAST B    │...
└──────────────┴───────┘      └──────────────┘     └──────────┘
A=1000B 整记录;B=97270B 切成 First/Middle/Last
```

2. **crc 覆盖 type+data 但不覆盖 length**——若 length 被篡改,解析会错位,最终撞上 crc 失配或块边界,**下一块自然重新对齐**。32KB 块边界提供了免费的重同步点,把 recordio 需要的启发式扫描变成确定性行为(doc/log_format.md:59-62)。头部剩余不足 7 字节时补零 trailer;恰好剩 7 字节且记录非空时,writer 必须先发一个**空的 First 片段**占位(log_writer.cc:44-61);
3. **crc 存储前 Mask**(高位翻转 + 特征量):让合法 crc 的位模式与"全零/未初始化内存"区分开——预分配文件里的零块不会被误认成合法记录(log_writer.cc:95)。

## 8.1 Write 调度器:writer 队列与 group commit

每个并发写线程构造一个栈上 Writer(batch 指针、sync、done、CondVar),压入 `writers_` deque,然后:

```cpp
writers_.push_back(&w);
while (!w.done && &w != writers_.front()) {
  w.cv.Wait();          /* 只有队头继续,其余休眠 */
}
if (w.done) return w.status;
```
(db_impl.cc:1212-1219)

唤醒后还要再查 `w.done`——队头可能把"凑进同一 group"的 writer 直接标记 done 并回填 status。**单队头推进、其余休眠**,把并发写串行化成一个天然提交点。

### Group commit:BuildBatchGroup(db_impl.cc:1281-1327)

队头把队列中紧随其后的若干 writer 合并成一个大 batch,一次写 log、一次插 memtable。四条规则:

1. **大小上限 1MB**;若队头自身 ≤128KB,上限降为 `size + 128KB`——避免小写被同批大写拖长尾延迟,把"搭车者"总量约束在队头体量的一倍多;
2. **sync 隔离**:队头是 non-sync 时,遇到第一个 sync writer 立即截断——不能让"未落盘即返回"的语义吞掉别人的 sync;反之 sync 队头可以吞并 non-sync(语义向下兼容);
3. **零拷贝拼接**:发生拼接时底座换成常驻成员 `tmp_batch_`,避免修改调用方持有的 batch;
4. 组内各条目按顺序各占一个序号(序号在加锁状态预分配,1227-1228),解锁段只是执行——**不会乱序**。

两步写期间**释放全局锁**,只靠"我是队头"身份排除并发写(db_impl.cc:1235-1253):

```cpp
mutex_.Unlock();
status = log_->AddRecord(...);
if (status.ok() && options.sync) { status = logfile_->Sync(); ... }
if (status.ok()) status = WriteBatchInternal::InsertInto(write_batch, mem_);
mutex_.Lock();
if (sync_error) RecordBackgroundError(status);   /* sync 失败 → 永久拒写! */
```

**sync 失败被升级为 bg_error_ 是一个值得停顿的决定**:Sync 失败时这条 log 重启后在不在都不确定,内存态与持久态已分叉,唯一的补救是让 DB 从此拒绝一切写——极端保守但实现极简的 RPO 策略。而 AddRecord 本身失败(磁盘满)只返回错误给本组,不炸库。

提交完成后,队头从队首弹出直到 last_writer,给每个组员回填同一个 status 并 Signal。一次磁盘写、一次 memtable 插入,N 个线程同时返回——group commit 的全部收益。

## 8.2 MakeRoomForWrite:限流阶梯

队头专属的 `while(true)` 阶梯(db_impl.cc:1331-1405):

| 优先级 | 条件 | 行为 |
|---|---|---|
| 0 | bg_error_ 非 ok | 拒绝一切写 |
| 1 | L0 文件数 ≥ 8(slowdown) | 解锁 Sleep 1ms 一次(本调用仅一次) |
| 2 | memtable 未满(≤4MB) | break 放行 |
| 3 | imm_ 非空 | 无限等待 |
| 4 | L0 文件数 ≥ 12(stop) | 无限等待 |
| 5 | memtable 满且无阻塞 | **切 log + 切 memtable**,MaybeScheduleCompaction |

三个设计意图:**先钝刀后硬停**——slowdown 的 1ms 是"预防性限流"(即便 memtable 有空间也吃延迟),让出 CPU 给 compaction,削平尾延迟;**4/8/12 的间隔**是缓冲带设计(4 是 compaction 启动门槛,8 开始减速,12 才硬停,中间留 4 个文件让"正在跑、马上消化掉"的场景不误伤);**情形 5 之后回到 while 顶部重走阶梯**——"切完 memtable 就一定能写"不成立,若 L0 已达 12 会立即进入无限等待,**写端背压是循环而非单次判断**。整条阶梯构成 LevelDB 的背压系统:L0 堆积意味着 flush 快于 compaction,限流把写速率强制对齐到 compaction 吞吐。

失败兜底:新 log 创建失败时 `ReuseFileNumber` 归还文件号(防磁盘满时疯狂消耗号空间);旧 log 关闭失败则记 bg_error_ 后仍切换到新 log。

## 8.3 崩溃恢复:四阶段

**阶段一:文件锁与 manifest**(db_impl.cc:292-383)。`LockFile(LOCK)` 进程级互斥;无 CURRENT 则按 create_if_missing 新建(NewDB 写初始 manifest);`VersionSet::Recover` 读 CURRENT 重放 VersionEdit 重建版本——`log_number` 的含义:**小于它的 WAL 已全部落盘为 SST,回放时跳过**。

**阶段二:确定回放集合**。扫描目录把所有 `number >= log_number` 的 log 收集并**按文件号排序**——文件号单调递增,序号即提交顺序,乱序回放会让同 key 新旧颠倒(363-366)。同时用 live 集合做存在性检查:manifest 声称的 SST 缺失,直接 Corruption。

**阶段三:逐个 log 回放**(RecoverLogFile,432-466)。要点:

- **checksum 永远开启**,即使 paranoid_checks=false——注释明确:让损坏导致"整个 commit 被跳过",而不是把坏数据(如超大序号)灌进 memtable(418-422)。两层分离:checksum 决定"要不要相信这条数据"(永远不信坏的),paranoid 决定"发现坏数据后还能不能起来";
- 每条 log 记录即一个 WriteBatch,rep 直接 `SetContents` 零拷贝解析;batch 头部自带序号,恢复后精确还原每个条目的 seq;
- **中途刷盘**:重放的 memtable 超过 4MB 立即 WriteLevel0Table 落成 L0——避免把几十个 log 全堆进内存;
- `reuse_logs` 优化(默认关):最后一个 log 且未触发刷盘时,续写旧 log 并保留重放出的 memtable 为当前 memtable。

**阶段四:收尾**。分配新 log/memtable(若全刷盘了);save_manifest 则写 VersionEdit 经 LogAndApply——**这一步之后旧 log 才正式可删**;RemoveObsoleteFiles 清理陈旧 WAL。

**恢复的可能状态**:崩溃窗口内某条 Put 的结局只有三种——① 记录完整且 crc 通过 → 重放生效;② 残缺/截断 → 按 EOF 丢弃(**整条 WriteBatch 原子消失**);③ crc 失败 → 丢弃当前块跳到下一块,其后记录不受牵连。已 fsync 的写必然属于 ①。

**损坏行为矩阵**(排查线上事故用):

| 受损对象 | 行为 | 依据 |
|---|---|---|
| CURRENT 缺失/无换行结尾 | Corruption | version_set.cc:869-878 |
| manifest 记录损坏 | 报错,恢复失败(manifest 无"跳过"语义) | version_set.cc:902-946 |
| manifest 缺三个标量 | Corruption(完备性检查) | version_set.cc:950-957 |
| 活跃 SST 丢失 | Corruption,打开即失败 | db_impl.cc:344-361 |
| WAL 记录损坏 | paranoid 报错;否则记日志跳过继续 | db_impl.cc:393-398 |
| WAL 尾部截断 | 按 EOF 处理,不算损坏 | log_reader.cc:207-213 |

**manifest 与 WAL 的容错策略截然不同**:manifest 任何损坏都致命(版本状态无法部分重建);WAL 损坏只丢尾部增量,已落盘的 SST 层完好——这是 LSM"内存增量可再生成"性质的直接体现。

## 8.4 残帧处理五则(log_reader.cc)

1. 尾部截断的 7 字节头:按 EOF 处理,不报错(207-213)——writer 可能死在写头中途;
2. length 超出且已到 EOF:同样 kEof 不报 corruption(229-232);
3. **crc 失配:丢弃整个 32KB 缓冲**——length 可能已被破坏,继续信任它会"碰巧"解析出看似合法的假记录(244-256);
4. kZeroType && length==0:静默跳过(env_posix mmap 预分配的空洞)——**格式与 Env 实现存在隐式耦合**(Windows Env 无此行为);
5. EOF 时正处片段中:整条逻辑记录作废但不报错——"最后一条写了一半的 Put 在恢复时被丢弃"的原子性来源(144-151)。

## 8.5 TableCache:文件号 → TableAndFile 的 LRU

`NewLRUCache(max_open_files - 10)`(db_impl.cc:121-124)——预留 10 个 fd 给 CURRENT/MANIFEST/LOCK/log 等非 SST 文件;LRU 淘汰条目时才真正关文件描述符,**table cache 同时充当 fd 复用池**。key 是 fixed64 文件号,value 是 {RandomAccessFile*, Table*};**错误结果不缓存**——瞬态错误或文件修复后自愈(table_cache.cc:63-67)。`Evict` 仅在删 SST 时调用,防缓存句柄复活已删除文件。"table_cache 预热"并非 Open 时主动读全部 SST,而是 compaction 完成后校验产物可用性时顺带载入。

## 8.6 FAQ

**Q1:非 sync 写在崩溃后一定丢吗?**
进程崩溃(非断电)时页缓存数据仍在,通常能重放;断电则可能截断/丢弃——残帧机制保证不会读到半条 Put。

**Q2:sync 组里的 non-sync writer 会等 fsync 吗?**
会。提交点唯一:sync 队头整组一次 AddRecord+Sync 后一起唤醒;non-sync 队头会在 sync writer 处截断。

**Q3:WriteBatch 的原子性来自哪里?**
三点:批内所有条目在 log 中是同一条逻辑记录(残缺即整条丢弃);memtable 插入单线程连续;序号区间连续。恢复时 `record.size() < 12` 直接判 corruption,Iterate 末尾还校验条数与头部 count 一致。

**Q4:imm_ 存在时写会停吗?**
不一定:情形 5 会切出**新** memtable 和新 log 继续写;只有"新 memtable 又满了而 imm_ 还没刷完"才真正阻塞。极端情况内存里最多同时存在 mem + imm 两份数据。

**Q5:为什么先判断 L0 slowdown 再判断 memtable 有没有空间?**
顺序即优先级:即便有空间,L0 ≥ 8 也要先吃 1ms 延迟让 compaction 追上——预防性限流。

**Q6:MANIFEST 为什么也用 log::Writer?**
VersionEdit 是追加序列,与 WAL 问题完全相同;复用 7 字节头 + 32KB 块,截断检测、crc、块对齐全部免费,VersionSet::Recover 直接拿 log::Reader 读 manifest。

## 8.7 小结与深挖方向

本章结论:**写路径 = 单队头串行 + group commit + 两步写(解锁);WAL = 32KB 块 + First/Last 链 + 残帧分级;恢复 = manifest 权威 + WAL 可再生 + checksum 永开**。深挖:

1. 队头在情形 3/4 无限等待期间,后续 sync 写被连锁阻塞且无超时——bg_error_ 停摆时的死锁窗口验证;
2. 解锁段 InsertInto 失败时 SetLastSequence 仍推进(db_impl.cc:1257)——"已持久化但未确认"的灰区推演;
3. kZeroType 与 env_posix mmap 的隐式耦合;
4. RemoveObsoleteFiles 的解锁窗口与 pending_outputs_ 的覆盖完备性;
5. BuildBatchGroup 的 null-batch 语义在生产路径是否可达。

> 下一章离开执行:磁盘上的 SSTable 文件格式——Footer、重启点二分与 index key 的最短分隔符技巧。
