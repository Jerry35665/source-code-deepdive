# 第 10 章 · WAL 与 checkpoint:持久性的实现

> 基线:commit `7e886f44`。核心:write_ahead_log.cpp、wal_replay.cpp、checkpoint_manager.cpp。

## 10.0 全景:WAL 帧格式与 checkpoint 时间线

```
WAL 帧 = size(8B) + checksum(8B) + payload(首字段 WALType 枚举,24 种类型)
  数据操作是逻辑记录:INSERT 记 DataChunk 本身(非页镜像);批量 append 走 ROW_GROUP_DATA
  记"已写好的数据块指针"(重放零拷贝);USE_TABLE 设当前表,后续帧免重复表名
checkpoint 时间线:
  t1 主 WAL 追加 CHECKPOINT(meta_block)帧并关闭 ← "先立字据"
  t2 新提交改写 .wal.checkpoint(临时分叉,主 WAL 冻结为只读历史)
  t3-t5 并行写数据块+新 catalog meta 链 → fsync → 写新 header 翻转 → truncate 尾部
  t6 副 WAL 空则删主 WAL;否则等 fsync 后原子改名顶替
崩溃窗口:任意点崩溃,恢复时用 WAL 标记的 meta_block 与 header 的 meta_block 比对
  即可判定"checkpoint 是否真正完成"——一次指针比较,无需逐块校验
```

## 10.1 WAL 记录:帧化+校验+组提交

每帧经 ChecksumWriter 缓冲到 MemoryStream,End() 时整帧落地(write_ahead_log.cpp:126-136)。两级容错:长度越界=SerializationException(torn tail 容忍);checksum 不符=DataCorruptionException(真损坏不宽容)。**组提交的文件侧**:每 commit 追加空 WAL_FLUSH 帧、flush 进页缓存不 sync,登记 requested_sync_offset;SyncUpTo 一次 fsync 覆盖所有等待者,sync 失败给 WAL 打毒标记此后拒绝 sync(:585-653)。回滚=直接截断 WAL。WAL 头带 db_identifier(防拿错库,"WAL does not match database file")与 checkpoint iteration。

## 10.2 checkpoint:六个动作与并发分叉

触发三入口:自动(WAL 阈值默认 16MB,config.hpp:92)/手动 CHECKPOINT(实为 checkpoint() 表函数)/shutdown。类型裁决:有活动事务或有人读旧版本→降级 CONCURRENT(只落盘不清理);FULL 才 vacuum。流程:取排他 checkpoint_lock→**WALStartCheckpoint 写标记并分叉**→按依赖序扫描 catalog 条目序列化进 meta 链→各表 RowGroupCollection::Checkpoint 并行重写(PartialBlockManager 拼共享半空块)→flush 两支元数据笔→WriteHeader(iteration+1、先 fsync 数据再写 header、写非活跃槽翻转、再 fsync)→truncate→副 WAL 并轨。`PRAGMA checkpoint_abort` 在四个点位可注入崩溃——正是崩溃窗口边界的测试索引。

## 10.3 恢复:两遍重放与三种对账

预扫描(只反序列化不执行):定位 CHECKPOINT 标记、记录最后一个 commit 边界、探测 torn tail。对账三路(wal_replay.cpp:519-586):干净且无副 WAL→跳过全部重放;不干净→截到标记前重放;有副 WAL→干净则改名顶替、不干净则合并进 .wal.recovery。重放要点:CREATE_TABLE 走 binder 重新绑定(不直接灌 CreateInfo);INSERT 不做约束校验(数据已被检查过一次);索引先进暂存等 commit 边界统一挂载;序列值重放的是运行期计数防重启回发。重放成功到一半→记录 successful_offset,该 WAL 下次使用时先惰性截断——半条记录永不被复用为合法帧。

## 10.4 设计动机

1. **逻辑 WAL 而非页镜像**:WAL 格式与存储格式解耦(INSERT 直接序列化 DataChunk),重放走正常写入路径;ROW_GROUP_DATA 把最重的批量 append 消成"记指针";
2. **只在 checkpoint 时压缩/清理**:vacuum 要求无人读旧版本,恰是 FULL_CHECKPOINT 排他锁的前提;分析负载读多写少几乎无感;
3. **先立字据**:数据文件要写几分钟,标记只花一次顺序 append——恢复时一次指针比较区分"完成/半途";
4. **双 header 只在 checkpoint 轮换**:日常提交不翻转头,文件内容平时完全不可变,崩溃一致性简化为单比特问题;
5. **分叉而非停写**:checkpoint 可能数分钟,新提交走旁路文件,收尾一次改名原子并轨;
6. **commit 边界=空帧**:重放到哪算一个事务变成纯顺序扫描问题;空帧天然携带偏移,成为组提交记账单位;
7. **按帧校验**:torn tail 是预期输入,逐帧校验让损坏粒度天然对齐到最后一个成功帧。

## 10.5 FAQ

**Q1:INSERT 在 WAL 里记什么?**
DataChunk 本身(逻辑记录);批量 append 记 ROW_GROUP_DATA 块指针。

**Q2:checkpoint 默认什么时候触发?**
WAL 超 16MB(config.hpp:92);CHECKPOINT 语句;shutdown。

**Q3:checkpoint 期间能写吗?**
能:写进 .wal.checkpoint 分叉;主 WAL 冻结为只读历史。

**Q4:FULL 和 CONCURRENT checkpoint 差别?**
FULL 排他+vacuum 清理;CONCURRENT 只落盘已提交数据,可在有活动事务时运行。

**Q5:WAL 会主动收缩吗?**
运行中从不截断历史;清空只发生在 checkpoint 后的删除/改名。

**Q6:恢复时 torn tail 怎么处理?**
容忍:回滚未完事务,从最后成功偏移继续用,下次首用先截断。

**Q7:序列值重放的是什么?**
运行期计数(usage_count/counter/last_value),保证重启后序列不回发。

**Q8:sync 失败了会怎样?**
WAL 打毒标记拒绝再 sync;fsync 失败的提交不可回退,库 invalidate。

**Q9:USE_TABLE 帧是干嘛的?**
设定当前表,后续 INSERT/DELETE/UPDATE 帧免重复限定名——高频小帧的零成本压缩。

**Q10:重放的 INSERT 为什么不校验约束?**
数据已被检查过一次;重放建表才走 binder 重绑约束。

## 10.6 小结与深挖方向

本章结论:**持久性="逻辑 WAL+帧化校验+先立字据+双 header 轮换+分叉并轨,恢复只需一次指针比较"**。深挖:

1. sync_failed 毒标记之后的事务管理器行为(卷一 failure 三档的衔接);
2. 超大提交"跳过 WAL 直接 checkpoint"的回退路径(duck_transaction_manager.cpp:364-414);
3. VACUUM_ONLY 与内存库的估算 WAL 记账;
4. CHECKPOINT 标记"必须在文件末尾"校验的攻击面;
5. checkpoint 各阶段故障注入的演练矩阵。
