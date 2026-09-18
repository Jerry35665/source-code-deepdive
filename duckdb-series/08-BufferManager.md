# 第 08 章 · BufferManager 与 block 管理

> 基线:commit `7e886f44`。核心:src/storage/standard_buffer_manager.cpp、buffer/ 目录。

## 8.0 全景:三层结构与块状态机

```
BlockHandle/BlockMemory(每块一个共享句柄:状态|readers|buffer|记账)
BufferPool(全库唯一:内存上限+17 种 MemoryTag 记账+8 条 eviction 队列)
StandardBufferManager(pin/unpin 入口+临时块注册+溢出文件读写)
状态机(纠偏:只有两态,无 BLOCK_DELETED):
 UNLOADED(记账=0)─Pin→LOADED(readers++)─Unpin 归零→入 eviction 队列(延迟卸载)或立即卸载
 "删除"= 句柄生命周期终点:持久块 ~BlockHandle 反注册;临时块 ~BlockMemory 删溢出文件
```

## 8.1 Pin/Unpin:两段式与物理页过户

Pin 两段式:锁块查状态→未加载则先 `EvictBlocksOrThrow` 驱逐腾地→二次加锁复查(防并发加载竞态)→Load(standard_buffer_manager.cpp:387-403)。逐出时传出的 reusable_buffer 会被下一个等大块接管——省一次 free+malloc;mmap 背书(不拥有内存)的 buffer 不可复用,否则覆写会穿透映射毁掉磁盘原块(block_handle.cpp:183-187)。Unpin 归零后由 `DestroyBufferUpon` 三值定命运:**BLOCK**(逐出前须写溢出文件)、**EVICTION**(直接丢,可重建)、**UNPIN**(立即卸载不入队)。CanUnload 三道闸:已卸载/有 reader/临时块但无临时目录——最后一道正是"内存库大查询报 OOM"的根源(block_handle.cpp:118-123)。

## 8.2 内存预算:三层记账

①`SET memory_limit` 在**每次分配前**经 EvictBlocksOrThrow 强制执行,失败抛 OOM;记账是按 MemoryTag(17 种:BASE_TABLE/HASH_TABLE/PARQUET_READER/…)的双层原子计数——per-CPU 32KB 攒批再冲全局,避免缓存行热点(buffer_pool.cpp:587-613)。②算子内存由 TemporaryMemoryManager 二次切分:可用量=0.9×池上限,每算子先拿最小预留(512×256KB/线程 与 上限/16 取小),多算子争抢按"吞吐几何平均×物化代价"成本函数梯度分配(temporary_memory_manager.cpp:228-303)。③连不走块的结构(ART 索引的 BufferAllocator)每次 malloc 也走 EvictBlocksOrThrow——**memory_limit 无死角**。

## 8.3 淘汰:无锁队列+死节点惰性清理,而非 LRU 链

eviction 队列是 moodycamel 无锁 MPMC,按类型分 8 条(BLOCK×1/MANAGED_BUFFER×6/TINY_BUFFER×1);unpin 入队取单调 seq_num,**入队顺序即近似访问顺序**。死节点(句柄已销毁或被更新条目取代)无法随机摘除,降级为"惰性标记+批量清理":每 4096 次插入 Purge 一次,按死活比例自适应加压(buffer_pool.cpp:116-213)。unpin 保持 O(1) 无锁,代价转移给后台。

## 8.4 溢出文件与 BlockAllocator

UNLOAD 写回分叉:持久块直接丢内存(数据本来就在库文件里);临时块按策略写 `.tmp` 分格池(8 档大小、同档同文件、文件内 index×档位直接定位)或独立 `.block`(变长托管缓冲);写前 zstd 自适应压缩——per-CPU 指数平滑写耗时决定压不压、压几级,不赚就退回(temporary_file_manager.cpp:434-489)。`BlockAllocator` 是可选的虚拟内存预留池:VirtualAlloc 预留、首次使用 commit、归还时 madvise 还物理页;线程本地 128 块一批。块 256KB(可调 16-256KB),头部 8 字节校验和——定制 64 位乘加混合算法,读盘必验(checksum.cpp:67-79)。

## 8.5 设计动机

1. **句柄状态机而非 LRU 页框表**:块元数据与物理 buffer 解耦,句柄 weak_ptr 全局唯一化,同块并发扫描天然共享;
2. **容忍死节点而非即时摘除**:无锁队列无法随机删除;unpin O(1),清理交给后台批量;
3. **temp/persistent 分治**:差异压进 `block_id ≥ MAXIMUM_BLOCK` 与 DestroyBufferUpon 两个谓词,逐出循环对两者无感;
4. **块级 checksum**:校验覆盖整个 256KB 压缩位流,静默腐坏在读取瞬间暴露;
5. **溢出统一为 temp block**:配额/加密/压缩/孤儿清扫只实现一次;算子只管物化成块。

## 8.6 FAQ

**Q1:BlockState 有几态?**
两态 UNLOADED/LOADED(buffer_pool_reservation.hpp:15);"DELETED"是句柄终点不是状态。

**Q2:同块被两个线程扫描会加载两次吗?**
不会:句柄 weak_ptr 全局唯一,pin 共享同一 buffer。

**Q3:内存库会溢出吗?**
没设 temp_directory 就不会:CanUnload 拒绝逐出,报 OOM;设了则写 .tmp。

**Q4:溢出文件有校验吗?**
无块级 checksum,但有长度一致性+zstd 解压后长度校验兜底。

**Q5:query 内存和池上限什么关系?**
TemporaryMemoryManager 以 0.9 比例二次切分;多算子梯度分配。

**Q6:prefetch 是怎么做的?**
连续块组成 run(≤32MB)一次大 pread;内存不足就放弃留给按需 pin。

**Q7:io_mode=DIRECT_IO 影响缓冲池吗?**
不影响:池永远自管理;它只是绕 OS page cache 防双重缓存。

**Q8:字符串 heap 占池配额吗?**
执行期 StringHeap 走系统分配器不占;落库的溢出字符串块占(OVERFLOW_STRINGS tag)。

**Q9:逐出顺序是 LRU 吗?**
近似:入队序≈访问序;死节点清理后仍近似;可选 LRU 时间戳需开 track_eviction_timestamps。

**Q10:temp 文件残留谁清?**
下一实例按文件名内嵌 pid 是否存活清扫(temporary_file_manager.cpp:871-892)。

## 8.7 小结与深挖方向

本章结论:**缓冲层="句柄状态机+tag 记账+无锁淘汰队列+溢出分格池,memory_limit 无死角"**。深挖:

1. TemporaryMemoryManager 梯度分配的成本函数推导(:194-226);
2. ConvertToPersistent 的锁豁免场景(buffer_pool.cpp:274-283);
3. zstd 自适应档位的指数平滑参数;
4. PrefetchScanIO 与 zonemap 裁剪的配合(尾部注定裁掉的 vector 不预取);
5. DUCKDB_DEBUG_DESTROY_BLOCKS 的 0xa5 毒化调试。
