# B2 · BufferManager 与 block 管理

> 基线：commit `7e886f44428e90c8379d4d34e2afb866108ff079`。所有 `文件:行号` 均已在本地仓库逐行核对。
> 核心文件：`src/storage/standard_buffer_manager.cpp`、`src/storage/buffer/{block_handle,buffer_pool,block_manager,buffer_handle}.cpp`、
> `src/storage/block_allocator.cpp`、`src/storage/temporary_file_manager.cpp`、`src/storage/temporary_memory_manager.cpp`、
> `src/storage/single_file_block_manager.cpp`（checksum）、`src/storage/block.cpp`。

DuckDB 的"缓冲池"不是传统 DB 里"页缓存 + 置换链表"的老三样，而是清晰的三层结构：

1. **BlockHandle / BlockMemory**：每个 block 一个共享句柄，集中记录状态、readers、buffer 指针与内存记账
   （`src/include/duckdb/storage/buffer/block_handle.hpp:32`、`251`）；
2. **BufferPool**：全库唯一，持有内存上限、按 MemoryTag 的记账、三组 eviction 队列与 object cache 逐出
   （`src/storage/buffer/buffer_pool.cpp:256-270`）；
3. **StandardBufferManager**：pin/unpin 的入口、托管缓冲/临时块的注册工厂、溢出文件的读写者
   （`src/storage/standard_buffer_manager.cpp:72-82`）。

一个命名事实要先澄清：本版本 `BlockState` 只有 `BLOCK_UNLOADED / BLOCK_LOADED` 两态
（`src/include/duckdb/storage/buffer/buffer_pool_reservation.hpp:15`），**没有 `BLOCK_DELETED` 枚举**。
"删除"被拆进两条路径：持久块由 `~BlockHandle` 向 BlockManager 反注册（`src/storage/buffer/block_handle.cpp:169-179`），
临时块由 `~BlockMemory` 删除溢出文件并归还记账（`src/storage/buffer/block_handle.cpp:33-64`）。
下文状态机图中我们如实画成"句柄生命周期终点"。

## 1. block 状态机与 pin 生命周期（ASCII）

```text
                ┌───────────────────────────────────────────────────────────┐
                │  BlockMemory: state | readers | buffer | memory_charge    │
                │  (mutex lock 保护全部迁移; atomic 字段供无锁读)             │
                └───────────────────────────────────────────────────────────┘

  RegisterBlock / RegisterMemory                    Pin(handle)
  (state=UNLOADED, readers=0, charge=0)   ┌──────────────────────────────────┐
       │                                  │ LOADED?      readers++ → handle  │
       ▼                                  │ UNLOADED?    先 EvictBlocks 拿预留│
 ┌────────────┐   Load(): 持久块读库文件    │  + reusable buffer, 再 Load:     │
 │  UNLOADED  │   临时块读 .tmp/.block     │  state=LOADED, readers=1,        │
 │ (无 buffer,│ ────────────────────────► │  charge=reservation              │
 │  记账=0)   │ ◄──────────────────────── └──────────────────────────────────┘
 └────────────┘   Unload(): evict 或                 │ BufferHandle 析构
       │        最后一个 reader 退出时                  ▼
       │        (CanUnload 三道闸)               Unpin: readers--
       │ Pin 再次到达                            ├ 归零 & MustAddToEvictionQueue
       └────────────► LOADED ◄─────────────────┤   → 入 eviction 队列(延迟卸载)
                                               └ 否则(UNPIN 策略) 立即 Unload
      LOADED 状态下的旁路迁移:
      · ConvertToPersistent: 暂态块落盘换 block_id → 变持久块 (block_manager.cpp:59)
      · 持久块销毁: ~BlockHandle → UnregisterPersistentBlock ──► 句柄终点
      · 临时块销毁: ~BlockMemory → DeleteTemporaryFile(.tmp/.block) ─► 句柄终点
      ("DELETED" 不是 BlockState, 而是句柄生命周期的终点)
```

关键不变量：**UNLOADED 时块仍占一个句柄（弱注册于 BlockManager）但记账归零**——
`UnloadAndTakeBlock` 先按需写临时文件，再 `memory_charge.Resize(0)`、`state=BLOCK_UNLOADED`（`src/storage/buffer/block_handle.cpp:127-145`）；
pin 回来时按保存的 `memory_usage` 重新预留（`src/storage/standard_buffer_manager.cpp:370-391`）。

## 2. BlockHandle/BlockMemory：字段即协议

`BlockMemory` 把块的全部可变状态收进一个自带互斥锁的对象（`src/include/duckdb/storage/buffer/block_handle.hpp:212-248`）：

```cpp
mutex lock;                               // 块级互斥锁
atomic<BlockState> state;                 // LOADED / UNLOADED
atomic<int32_t> readers;                  // pin 计数
unique_ptr<FileBuffer> buffer;            // 加载后的物理页
atomic<idx_t> eviction_seq_num;           // 判别队列条目是否过期
bool has_queue_entry;                     // 是否有"活"队列条目(锁保护)
atomic<int64_t> lru_timestamp_msec;       // age-based 清理用
atomic<DestroyBufferUpon> destroy_buffer_upon; // 逐出策略
atomic<idx_t> memory_usage;               // pin 时按此数预留
BufferPoolReservation memory_charge;      // 当前实际记账(RAII)
```

`DestroyBufferUpon` 三值决定 evict/unpin 时的命运（`src/include/duckdb/common/enums/destroy_buffer_upon.hpp:15-18`）：

| 取值 | 语义 | 典型使用者 |
|---|---|---|
| `BLOCK` | 逐出时必须先溢出到临时文件 | 临时列段、溢出字符串块 |
| `EVICTION` | 逐出时直接丢弃（可重建） | MANAGED_BUFFER 托管缓冲 |
| `UNPIN` | unpin 即析构、不入 eviction 队列 | 短命暂存缓冲 |

对应谓词 `MustAddToEvictionQueue()` / `MustWriteToTemporaryFile()`（`block_handle.hpp:146-152`）。
`CanUnload` 是三道闸门：已卸载？有 reader？临时块但无临时目录？——任一成立即拒绝逐出（`src/storage/buffer/block_handle.cpp:109-125`）。

持久块由 `BlockManager::RegisterBlock` 以 `weak_ptr` 注册、活句柄全局唯一（`src/storage/buffer/block_manager.cpp:40-57`）；
临时块号从 `MAXIMUM_BLOCK`（2^62 量级哨兵，`src/include/duckdb/storage/storage_info.hpp:30`）起 `++temporary_id`（`src/storage/standard_buffer_manager.cpp:73`、`162`），永不与磁盘块号冲突。

## 3. Pin/Unpin：完整路径

`StandardBufferManager::Pin` 两段式：先锁块查状态；未加载则先驱逐腾地，再二次加锁复查（防并发加载竞态），最后 `Load`：

```cpp
// evict blocks until we have space for the current block
unique_ptr<FileBuffer> reusable_buffer;
auto reservation =
    EvictBlocksOrThrow(context, block_memory.GetMemoryTag(), required_memory, &reusable_buffer, ...);
auto lock = block_memory.GetLock();
if (block_memory.GetState() == BlockState::BLOCK_LOADED) {
    reservation.Resize(0);            // 别人先加载好了: 退预留
    buf = handle->Load(context);
} else {
    buf = handle->Load(context, std::move(reusable_buffer)); // 复用被逐出块的内存
    ...
}
```

（`src/storage/standard_buffer_manager.cpp:387-403`；`reusable_buffer` 的内存过户在 `buffer_pool.cpp:409-414`。）

`BlockHandle::Load` 分流：持久块 `block_manager.Read` 读库文件（读时校验 checksum，见 §9）；临时块若 `MustWriteToTemporaryFile()` 则从溢出文件读回，否则返回**无效句柄**——数据在逐出时已按 `EVICTION` 策略销毁（`src/storage/buffer/block_handle.cpp:219-243`）。

**物理页复用**：逐出时 `EvictBlocksInternal` 传出的 `reusable_buffer` 会被下一个块接管，省一次 free+malloc；但 mmap 背书（不拥有内存）或头部尺寸不同的 buffer 不可复用，此时退回新分配（`src/storage/buffer/block_handle.cpp:181-202`）：

```cpp
static ... AllocateBlock(BlockManager &block_manager, unique_ptr<FileBuffer> reusable_buffer,
                        block_id_t block_id) {
    // A buffer that doesn't own its memory (e.g. it adopted a pointer into a memory-mapped
    // region) cannot be reused for a different block: rewriting its bytes would clobber the
    // original block on disk through the mapping.
    if (reusable_buffer && reusable_buffer->OwnsInternalBuffer() &&
        reusable_buffer->GetHeaderSize() == block_manager.GetBlockHeaderSize()) {
        // Reusable buffer: reuse it.
        ...
    }
    // Not a reusable buffer: allocate a new block.
    return block_manager.CreateBlock(block_id, nullptr);
}
```

**锁协议**：所有状态迁移都要求持有块锁，且用 `VerifyMutex` 断言传入的确实是本块的锁（`block_handle.hpp:57-60`）；`BufferPool::AddToEvictionQueue` 的注释明确记录了"锁必须全程持有"的约定与 `ConvertToPersistent` 场景下无竞争锁的例外（`buffer_pool.cpp:274-283`）。锁内只做状态迁移，`PurgeQueue` 等重活被刻意挪到锁外（`standard_buffer_manager.cpp:474-477`）。

`Unpin` 把 readers 减到 0 后二选一：`MustAddToEvictionQueue()` 为真则入队（卸载推迟到真正需要内存时），否则立即 `Unload`（`src/storage/standard_buffer_manager.cpp:454-478`）。
`BufferHandle` 是 RAII 凭证：析构即 `Unpin`（`src/storage/buffer/buffer_handle.cpp:35-42`）。Pin 的实现刻意在**返回前不持块锁**——否则调用者析构 handle 时会在锁内重入 Unpin 死锁（`standard_buffer_manager.cpp:364-367` 注释）。

分配侧入口：`Allocate` → `RegisterMemory`（默认 `MANAGED_BUFFER`，`standard_buffer_manager.cpp:171-187`）；小于一块的用 `RegisterSmallMemory` → `TINY_BUFFER`（`standard_buffer_manager.cpp:154-169`）；`RegisterTransientMemory` 按"是否凑满一个 block size"二选一（`standard_buffer_manager.cpp:140-152`）。缓冲类型与 eviction 队列的对应关系见 §6。

## 4. 内存预算：memory_limit 如何被执行

`SET memory_limit` 的执行链：`MaxMemorySetting::SetGlobal`（支持百分比，相对系统内存）→ `BufferManager::SetMemoryLimit`
（`src/main/settings/custom_settings.cpp:1150-1156`、`src/storage/standard_buffer_manager.cpp:480-482`）
→ `BufferPool::SetLimit`：先驱逐到新限额、改 `maximum_memory`、再验一遍，失败回滚旧值并抛 OOM（`src/storage/buffer/buffer_pool.cpp:525-545`）。

真正的执行点在**每一次分配之前**：`EvictBlocksOrThrow` 用 `memory_delta` 调 `buffer_pool.EvictBlocks(..., memory_limit=maximum_memory, ...)`,
失败抛 `OutOfMemoryException`（`src/storage/standard_buffer_manager.cpp:126-138`）。BufferPool 在 DatabaseInstance 初始化时以
`config.options.maximum_memory` 构造（`src/main/database.cpp:569-571`）。

记账是**按 MemoryTag 的双层原子计数器**：小额变动先落在 per-CPU 的 64 槽缓存里，攒够 32KB 才冲刷进全局计数（`src/storage/buffer/buffer_pool.cpp:587-613`，常量 `buffer_pool.hpp:132-133`），避免每次 pin/分配都打全局缓存行。tag 共 17 种（BASE_TABLE/HASH_TABLE/PARQUET_READER/CSV_READER/ORDER_BY/ART_INDEX/COLUMN_DATA/METADATA/OVERFLOW_STRINGS/IN_MEMORY_TABLE/ALLOCATOR/EXTENSION/TRANSACTION/EXTERNAL_FILE_CACHE/WINDOW/OBJECT_CACHE/UNKNOWN，`src/include/duckdb/common/enums/memory_tag.hpp:15-34`），`duckdb_memory()` 的按 tag 报表即来源于此（`standard_buffer_manager.cpp:493-503`）。

物理预留由 RAII 的 `BufferPoolReservation::Resize` 增减（`src/storage/buffer/buffer_pool_reservation.cpp:27-31`）；`Unload` 时 `Resize(0)` 归零（`block_handle.cpp:142`）。BufferPool 还有三件"兼职"：吃紧时先逐 object cache（`buffer_pool.cpp:348-378`）；超过 `allocator_bulk_deallocation_flush_threshold` 时对 BlockAllocator 做 `FlushAll` 归还物理页（`buffer_pool.cpp:400-405`）；扩展可用 `ReserveMemory/FreeReservedMemory` 纯记账（`standard_buffer_manager.cpp:761-776`）。特别地，`BufferAllocator`（ART 索引、CSV 缓冲等用的分配器）每次 malloc 也走 `EvictBlocksOrThrow(MemoryTag::ALLOCATOR)`（`standard_buffer_manager.cpp:781-789`）——**不走块的结构同样被 memory_limit 管辖**。

## 5. TemporaryMemoryManager：query 内存 vs buffer pool

BufferPool 上限是全库物理内存；"每个查询/算子能用多少"由 TemporaryMemoryManager 二次切分。它以 `0.9 × buffer pool 上限` 为可分配总量（`MAXIMUM_MEMORY_LIMIT_RATIO=0.9`，`src/include/duckdb/storage/temporary_memory_manager.hpp:89`；换算 `src/storage/temporary_memory_manager.cpp:101-102`），并同步 `query_max_memory = GetOperatorMemoryLimit()`（`temporary_memory_manager.cpp:106`；`SET operator_memory_limit` 见 `src/include/duckdb/main/settings.hpp:1982-1984`）。

每个注册的算子状态（hash join/sort/window 等）先拿最小预留：

```cpp
idx_t TemporaryMemoryManager::DefaultMinimumReservation() const {
    return MinValue(num_threads * MINIMUM_RESERVATION_PER_STATE_PER_THREAD,  // 512×256KB/线程
                    memory_limit / MINIMUM_RESERVATION_MEMORY_LIMIT_DIVISOR); // 上限/16
}
```

（`temporary_memory_manager.cpp:74-77`，常量 `temporary_memory_manager.hpp:84-86`。）随后 `UpdateState` 在三个上界里取小：剩余工作量、query 上限、`0.9 × 空闲内存`（`temporary_memory_manager.cpp:150-154`）；一旦总预留将要越界即退回下界（`temporary_memory_manager.cpp:142-144`）。多算子争抢时 `ComputeReservation` 围绕"吞吐几何平均 × 物化代价"的成本函数做多轮梯度分配（`temporary_memory_manager.cpp:228-303`，导数推导 `194-226`）。两个豁免：`PRAGMA force_external` 时只给最小值（:136-138）；无临时目录（不能溢出）时干脆不限（:139-141）。

## 6. 淘汰策略：带死节点的无锁并发队列，而非 LRU 双向链表

eviction 队列是 `duckdb_moodycamel::ConcurrentQueue`（无锁 MPMC），按 buffer 类型分三组共 8 条：
BLOCK+EXTERNAL_FILE×1（"先逐，释放即完事"）、MANAGED_BUFFER×6（"要写存储，逐得慢些"）、TINY_BUFFER×1（"最后手段"）（`src/storage/buffer/buffer_pool.cpp:15-27`、`256-270`，容量常量 `buffer_pool.hpp:118-120`）。MANAGED_BUFFER 独享 6 条是因为其块可经 `SetEvictionQueueIndex` 指定子队列优先级（`block_handle.hpp:188-199`，索引换算 `buffer_pool.cpp:303-322`）。

unpin 时才入队，并取单调递增 `eviction_seq_num`、可选打 LRU 时间戳（`buffer_pool.cpp:274-301`）。**入队顺序即近似访问顺序（FIFO→LRU）**，但队列里会积累大量"死"条目（句柄已销毁，或被同块更新条目取代）。死节点判定：`weak_ptr::lock()` 失败或 seq_num 不匹配（`buffer_pool.cpp:47-59`、`482-499`）。每 4096 次插入触发一次 Purge：批量出队、剔除死节点、活节点重排入队，按死/活比例自适应加压（常量 `buffer_pool.cpp:116-124`，主循环 `154-213`，单轮 `215-254`）。逐出执行 `IterateUnloadableBlocks`：出队 → 升级为 `shared_ptr` → 校验 seq_num → 清 `has_queue_entry` → `CanUnload` → `Unload`（`buffer_pool.cpp:468-513`）。若正在为新分配找 buffer 且目标块恰好等大，直接把物理内存"过户"，省一次 free+malloc（`buffer_pool.cpp:409-414`）。另有按时间戳的 `PurgeAgedBlocks`（扩展兼容接口，`buffer_pool.cpp:439-449`），时间戳仅当 `track_eviction_timestamps` 开启才记录（`buffer_pool.cpp:291-295`）。

## 7. UNLOAD 写回与否：temp block vs persistent block

- **持久块**（block_id < MAXIMUM_BLOCK）：Unload 直接丢内存——数据本来就在数据库文件里，pin 回来时重读并校验（`block_handle.cpp:227-230`）。唯一"写回"是 checkpoint 路径：`BlockManager::ConvertToPersistent` 把暂态块落盘、换正式 block_id、原句柄降级、新持久块入 eviction 队列（`src/storage/buffer/block_manager.cpp:93-116`）。
- **临时块**（block_id ≥ MAXIMUM_BLOCK）：由 `MustWriteToTemporaryFile()` 决定。为真则 `WriteTemporaryBuffer` 溢出后再丢内存（`block_handle.cpp:137-141`）；为假（`EVICTION`）则直接销毁。没有临时目录时 `CanUnload` 直接拒绝逐出——宁可报 OOM 也不丢数据（`block_handle.cpp:118-123`），这正是"内存库不设 temp_directory 时大查询报错"的根源。

## 8. 溢出文件：temp file 管理

`RequireTemporaryDirectory` 惰性创建 `TemporaryDirectoryHandle`（`src/storage/standard_buffer_manager.cpp:511-523`）。`WriteTemporaryBuffer` 按块大小分流（`standard_buffer_manager.cpp:529-573`）：

- **标准块（alloc 恰为 256KB）**：进 `TemporaryFileManager` 的分格文件池。块按 **8 档大小分类**（32K/64K/…/224K/DEFAULT=256K，`src/storage/temporary_file_manager.cpp:52-56`），同档块写同一个 `.tmp` 文件，文件内按 `index × (档位大小 + 加密元数据)` 直接定位（`temporary_file_manager.cpp:362-369`）；文件满（index 超容量）则换下一个；写前走 **zstd 自适应压缩**——以 per-CPU 的指数平滑写耗时决定压不压、压几级，压缩不赚就退回原大小（`temporary_file_manager.cpp:434-489`、`554-582`）。
- **变长大块（>256KB 的托管缓冲）**：每块一个独立 `.block` 文件，头存明文 `[size][header_size]`（可加密）（`standard_buffer_manager.cpp:541-572`）。

读回路径在块句柄层分流：`temporary_directory.handle->GetTempFile().HasTemporaryBuffer(id)` 命中则走 `.tmp` 池（`standard_buffer_manager.cpp:583-594`），否则按 `.block` 处理；`used_blocks`（block_id → 文件内索引）的登记与回收由 manager 独占管理（`temporary_file_manager.cpp:542-544`、`705-716`）。磁盘配额 `max_temp_directory_size` 默认取可用磁盘 90%，`IncreaseSizeOnDisk` 超限抛 OOM（`temporary_file_manager.cpp:597-609`、`633-646`）。索引回收会尝试 truncate 文件（`temporary_file_manager.cpp:349-360`）。进程崩溃残留由下一实例按"pid 是否存活"清扫（`temporary_file_manager.cpp:871-892`），文件名内嵌 `pid_instance` 归属标记（`719-728`）。

## 9. checksum：块级、写时算、读时验

校验函数是定制 64 位混合：整 8 字节部分对 `x * 0xbf58476d1ce4e5b9` 做异或累积，尾部 0-7 字节用 MurmurHash64A 变体（seed `0xe17a1465`）：

```cpp
uint64_t Checksum(const uint8_t *buffer, size_t size) {
    uint64_t result = 5381;
    size_t i;
    // for efficiency, we first checksum uint64_t values
    for (i = 0; i < size / 8; i++) {
        result ^= Checksum(Load<uint64_t>(buffer + i * 8));
    }
    if (size > i * 8) {
        // the remaining 0-7 bytes we hash using a string hash
        result ^= ChecksumRemainder(buffer + i * 8, size - i * 8);
    }
    return result;
}
```

（`src/common/checksum.cpp:67-79`，`7-9`、`14-65`。）它不是 CRC，目标是**检错**而非纠错，速度优先。

持久块写入：`ChecksumAndWrite` 把校验和存进块头前 8 字节（`DEFAULT_BLOCK_HEADER_STORAGE_SIZE=8`，`storage_info.hpp:35`），可选加密后落盘（`src/storage/single_file_block_manager.cpp:792-820`）；读取：`ReadAndChecksum` 先解密再 `CheckChecksum` 比对，不符抛 `DataCorruptionException`（`single_file_block_manager.cpp:729-750`、`776-790`）。数据库文件头（前 8KB 双副本轮替）走同一套校验（`single_file_block_manager.cpp:708-712`）。溢出的 temp 文件**没有块级 checksum**，但有长度一致性校验（`standard_buffer_manager.cpp:613-622`）与 zstd 解压后长度校验（`temporary_file_manager.cpp:261-275`）兜底。

## 10. block 大小与 BlockAllocator

常量都在 `src/include/duckdb/storage/storage_info.hpp`：`DEFAULT_BLOCK_ALLOC_SIZE = 262144`（256KB，:33）、
`DEFAULT_BLOCK_HEADER_STORAGE_SIZE = 8`（:35）、`DEFAULT_BLOCK_SIZE = 256KB−8`（:68）、`SECTOR_SIZE = 4096`（:53）、
块分配大小可调范围 `[16KB, 256KB]`（:60-62）。所有缓冲分配按 4KB 扇区对齐（`src/storage/buffer_manager.cpp:39-41`）；
块分配大小持久化于数据库头，随文件打开恢复（`single_file_block_manager.cpp:716-723`）。
`Block` 只是给 `FileBuffer` 加了一个 `block_id`（`src/storage/block.cpp:9-26`），并断言 alloc 大小按扇区对齐。

BlockAllocator 是**可选的预留式内存池**（`SET block_allocator_size` 启用，`src/main/settings/custom_settings.cpp:361-364`）：

- 启动时 `VirtualAlloc(MEM_RESERVE)/mmap` 保留一大段虚拟地址（`src/storage/block_allocator.cpp:24-37`）；
- 块首次被使用才 commit/预缺页（:51-66），归还时 decommit/`madvise(MADV_DONTNEED)` 还物理页给 OS（:68-83）；
- 块句柄是 32 位块号，`block_size` 为 2 的幂，除法用移位（:220-221、`298-313`）；
- 线程本地缓存 128 块一批，从 touched/untouched 两条全局并发队列批量补充，释放攒够 256 块才批量归还（:88-90、`194-195`、`109-137`）；
- 只接受**恰好 block_size** 的请求，其余走后备分配器（:324-329）；驱逐压力下按连续段合并 madvise 归还（`buffer_pool.cpp:400-405`，`block_allocator.cpp:378-412`）。

`FileBuffer` 的物理内存一律从 BlockAllocator 申请/释放（`src/common/file_buffer.cpp:11-31`），这就是 buffer pool 与 malloc 之间的单一通道。

## 11. 与执行层的合作

- **Row group → block**：持久列段只持 `block_id + offset`（`src/storage/table/column_segment.cpp:30-51`），扫描时 `RegisterBlock` 拿句柄再 pin，pin 生命周期 = 单段扫描（列段 pin：`column_segment.cpp:205`；各压缩函数 scan：`src/storage/compression/fixed_size_uncompressed.cpp:156`、`208`，`dictionary_compression.cpp:125`）。
- **暂态列段**：`RegisterTransientMemory` 分配、可溢出（`column_segment.cpp:62`、`78`），checkpoint 时经 `ConvertToPersistent` 变持久（`block_manager.cpp:59-118`）。
- **Prefetch**：把连续未加载块组成 run（单 run ≤32MB，`standard_buffer_manager.cpp:307`），一次大 `pread` 读进 staging buffer 再拆给各块，best-effort——内存不足就放弃、留给扫描按需 pin（`standard_buffer_manager.cpp:241-291`、`293-344`）；异步任务化于 `346-358`。列段注册 prefetch 的入口在 `column_segment.cpp:126-133`。
- **字符串 heap 不走 buffer pool**：`StringHeap` 用普通 `Allocator`（默认系统分配器）加 arena 切块（`src/include/duckdb/common/types/string_heap.hpp:17-19`、`src/common/types/string_heap.cpp:12-13`）；执行期中间字符串归进程堆、不占 buffer pool 配额。但**落库的溢出字符串**块化后由 buffer manager 分配（tag=OVERFLOW_STRINGS，`src/storage/compression/string_uncompressed.cpp:350`、`397`）。另注意 §4 的 `BufferAllocator` 通道：索引等长生命周期结构虽然不建块，仍计入配额。

## 12. DirectIO / 缓冲策略开关

I/O 模式是库级启动配置 `io_mode ∈ {BUFFERED_IO, MMAP, DIRECT_IO}`（`src/storage/storage_manager.cpp:135-139`）；DIRECT_IO 时打开数据库文件追加 `FILE_FLAGS_DIRECT_IO`（`src/storage/database_handle.cpp:35-36`，标志位 `src/include/duckdb/common/file_open_flags.hpp:23`）。它只是文件 I/O 开关，缓冲池本身永远自管理；绕开 OS page cache 防双重缓存的手段就是它。MMAP 路径的映射内存不归池管，代码多处显式防御"mmap 背书的 buffer 不可复用/不可覆写"（`src/storage/buffer/block_handle.cpp:183-187`、`src/common/file_buffer.cpp:62-65`）。调试开关方面还有 `DUCKDB_DEBUG_DESTROY_BLOCKS`（卸载时写入 0xa5 毒化内存，`standard_buffer_manager.cpp:21-36`）与 `debug_eviction_queue_sleep`（放大队列竞态，`buffer_pool.cpp:515-523`）。

## 13. 设计动机

1. **为什么是 BlockHandle 状态机而非经典 LRU 页框表？** 块元数据（readers、记账、销毁策略）必须与物理 buffer 解耦：句柄是 `shared_ptr`，物理页可随时卸载，pin 只是"临时禁止卸载"。于是 `RegisterBlock` 用 `weak_ptr` 全局唯一化句柄（`block_manager.cpp:55`），同块并发扫描天然共享，逐出只需改状态而无需通知持句柄者。
2. **为什么 eviction 队列容忍死节点而不是即时摘除？** 无锁队列无法随机删除，故用 `weak_ptr + 单调 seq_num` 把"摘除"降级为"惰性标记 + 批量清理"：每 4096 次插入清一次、按死活比例自适应加压（`buffer_pool.cpp:116-124`、`191-212`）。unpin 保持 O(1) 无锁，代价转移给后台。
3. **为什么 temp/persistent 分治？** 两类块的"数据是否已在盘上"不同：持久块逐出 = 丢内存；临时块逐出 = 先写溢出文件。差异被压进 `block_id ≥ MAXIMUM_BLOCK` 与 `DestroyBufferUpon` 两个谓词（`block_handle.cpp:137-141`、`block_handle.hpp:150-152`），BufferPool 的逐出循环对两者完全无感。
4. **为什么 checksum 放在块级（8 字节头）？** 校验要覆盖"从磁盘读回的整个 256KB"（含压缩后的位流），块正是 I/O 与校验的共同单位；8 字节固定开销换取静默腐坏在读取瞬间暴露（`single_file_block_manager.cpp:744-749`），且 checksum 计算本身是每 8 字节一次乘加的常数级操作（`checksum.cpp:71-73`）。
5. **为什么是 256KB 块？** 4KB 扇区对齐的 64 倍：单块够大以摊薄 8 字节头与 pin/锁开销、给列压缩（bitpacking/dict/fsst）留出分摊空间；又够小让 pin 粒度不浪费内存。默认 alloc 恰为溢出文件 `TemporaryBufferSize::DEFAULT`，磁盘块与溢出块同构（`temporary_file_manager.cpp:281-282`）。
6. **为什么溢出统一为 temp block，而不是各算子自管溢出？** 统一后"内存满了"只有一条出路（`EvictBlocksOrThrow`），配额、加密、压缩、孤儿清扫、`max_temp_directory_size` 全部实现一次；算子只管把自己物化成块，给谁多少内存由 TemporaryMemoryManager 决定，两层解耦（§5、§8）。
7. **为什么记账用 per-CPU 缓存？** 每次 pin/unpin/分配都会 +/- 字节，直写全局原子变量会成为缓存一致性热点；32KB 攒批（`buffer_pool.hpp:133`）把全局写频率降数个量级，代价只是限额判断的轻微滞后。

## 14. 写作素材清单（file:line）

1. `src/include/duckdb/storage/buffer/buffer_pool_reservation.hpp:15` — BlockState 仅两态（DELETED 不存在的证据）
2. `src/storage/buffer/block_handle.cpp:109-125` — CanUnload 三道闸门
3. `src/storage/buffer/block_handle.cpp:127-145` — UnloadAndTakeBlock（temp 块写回分叉）
4. `src/storage/buffer/block_handle.cpp:219-243` — BlockHandle::Load（读库文件 vs 读溢出文件）
5. `src/storage/standard_buffer_manager.cpp:364-423` — Pin 两段式全貌
6. `src/storage/standard_buffer_manager.cpp:454-478` — Unpin 的入队/立即卸载分叉
7. `src/storage/standard_buffer_manager.cpp:529-573` — WriteTemporaryBuffer（.tmp 与 .block 分流、加密）
8. `src/storage/buffer/buffer_pool.cpp:274-301` — 入队 + LRU 时间戳 + seq_num 演进
9. `src/storage/buffer/buffer_pool.cpp:468-513` — IterateUnloadableBlocks（死节点与活条目移交）
10. `src/storage/buffer/buffer_pool.cpp:587-613` — per-CPU 记账缓存
11. `src/storage/temporary_memory_manager.cpp:126-167` — 单状态预留上下界决策
12. `src/storage/temporary_memory_manager.cpp:228-303` — 多状态梯度分配
13. `src/storage/temporary_file_manager.cpp:434-489` — zstd 压缩档位自适应
14. `src/storage/block_allocator.cpp:24-83` — 虚拟内存 reserve/commit/decommit 三段
15. `src/common/checksum.cpp:67-79` — 块校验和算法
16. `src/storage/single_file_block_manager.cpp:776-790` — ReadAndChecksum（解密 + 校验时序）
