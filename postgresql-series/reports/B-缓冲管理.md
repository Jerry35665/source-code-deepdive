# 源码深读 · 第四系列卷一 第 2 章：PostgreSQL 缓冲管理器（Buffer Manager）

> 源码：postgres master 分支，commit `8c7a74c`（`8c7a74c3239ce29940582643533a190721b395c0`，shallow clone）。
> 本文所有行号均以该 commit 实际 grep/Read 核对。注意：master 已合入异步 I/O（AIO）改造，
> 缓冲头中出现 `io_wref` 与条件变量（`src/include/storage/buf_internals.h:352`），与老版本
> （PG17 及以前用 per-buffer `io_in_progress_lock`）略有差异，文中会随时标注。

## 0. 阅读地图：先读 README

`src/backend/storage/buffer/README`（277 行）是官方设计文档，全文分四块：

- 共享缓冲访问规则（pin + 三档内容锁），README:6-111
- 缓冲管理器内部锁分层（映射分区锁 / strategy 自旋锁 / 头自旋锁），README:114-169
- 默认替换策略 clock-sweep，README:172-203
- 环形策略（ring buffer）与 bgwriter，README:206-277

一句话页格式：每个 8KB 块的内容就是一个 `PageHeaderData` + 行指针数组 + 元组
（`src/include/storage/bufpage.h:184`），缓冲管理器对页内容一无所知——它只负责"把正确的 8KB
送到内存里来"。

## 1. 全景：一次 ReadBuffer 的完整决策树

入口链：`ReadBuffer()`（`src/backend/storage/buffer/bufmgr.c:879`）→
`ReadBufferExtended()`（bufmgr.c:926）→ `ReadBuffer_common()`（bufmgr.c:1276）。
`ReadBuffer_common` 对 `P_NEW` 走扩展路径（bufmgr.c:1303-1316 → `ExtendBufferedRel`），
普通读则经 `StartReadBuffer`（bufmgr.c:1361）→ `PinBufferForBlock`（bufmgr.c:1223）：
临时表走 `LocalBufferAlloc`（bufmgr.c:1248-1249），永久/unlogged 表走
`BufferAlloc`（bufmgr.c:1251-1252）。命中直接返回；miss 拿到 victim 后由
`WaitReadBuffers()`（bufmgr.c:1759）发起/等待 I/O。

```
ReadBuffer(rel, blk)
 │
 ├─ 临时表(relpersistence == TEMP)?          bufmgr.c:1248
 │    └─ LocalBufferAlloc(): 会话私有,无锁   localbuf.c:119
 │
 └─ BufferAlloc(smgr, fork, blk, strategy)   bufmgr.c:2197
      │  1) InitBufferTag{rnode,fork,blk}     bufmgr.c:2216
      │  2) hash → 分区锁, LW_SHARED          bufmgr.c:2219-2223
      │  3) BufTableLookup                    bufmgr.c:2224
      │
      ├─ 命中(id>=0) ──→ PinBuffer(CAS refcount+usage++)  bufmgr.c:2237
      │       │            有效? → 返回 buf(共享命中)
      │       └─ 有效但 BM_VALID 未置 → 当 miss 处理等 I/O  bufmgr.c:2244-2252
      │
      └─ miss: 释放分区锁(bufmgr.c:2261)
           GetVictimBuffer(strategy)          bufmgr.c:2268
             ├─ 有 strategy → 先试 ring       freelist.c:196-204
             └─ clock sweep 扫 victim         freelist.c:240-316
                  ├─ 脏页: 条件性 share-excl 锁+FlushBuffer(可能重挑) bufmgr.c:2603-2634
                  └─ 从哈希表删旧 tag, 换新 tag
           LW_EXCLUSIVE 分区锁 + BufTableInsert  bufmgr.c:2276-2277
             └─ 插入冲突? → 别人抢先, 改用对方的 buf  bufmgr.c:2278-2317
           置 BM_TAG_VALID, usage_count=1      bufmgr.c:2336
           StartBufferIO: 置 BM_IO_IN_PROGRESS(bufmgr.c:7290)
             ├─ 抢到 → smgrread → 置 BM_VALID, TerminateBufferIO
             └─ 已有 I/O → WaitIO(): 等 io_wref 或条件变量  bufmgr.c:7188-7247
```

**BufferDesc 双状态**：每个缓冲 = 一段 8KB 数据（`BufferBlocks` 数组）+ 一个描述符
`BufferDesc`（`src/include/storage/buf_internals.h:326-359`）。描述符的核心是两样东西：

- `buf_id`（buf_internals.h:338）：固定不变的数组下标；`Buffer = buf_id + 1`（buf_internals.h:438），
  0 留给 `InvalidBuffer`。
- `state`（buf_internals.h:344）：**一个 64 位原子字打包五种信息**（buf_internals.h:34-55）：

```
| 18 bit refcount | 4 bit usage_count | 12 bit BM_ 标志 | 18 bit share-lock | 1 bit sx | 1 bit ex |
```

BM_ 标志位（buf_internals.h:106-127）：`BM_LOCKED`(0) `BM_DIRTY`(1) `BM_VALID`(2)
`BM_TAG_VALID`(3) `BM_IO_IN_PROGRESS`(4) `BM_IO_ERROR`(5) `BM_PIN_COUNT_WAITER`(7)
`BM_CHECKPOINT_NEEDED`(8) `BM_PERMANENT`(9) `BM_LOCK_HAS_WAITERS`(10) `BM_LOCK_WAKE_IN_PROGRESS`(11)。
把 refcount/usage_count/锁计数全塞进一个 `pg_atomic_uint64`，使得"加 pin 同时加使用计数"
（PinBuffer）、"clock 递减 usage 或抢 pin"（StrategyGetBuffer）都能用**一次 CAS 完成，不取
任何锁**（freelist.c:252-314）。有意思的是：master 的内容锁也不再是 LWLock，而是直接用
state 字的高位实现的读写锁（buf_internals.h:303-310 注释明说这是为了"原子地查 AIO 是否
进行中"与"解锁+解 pin 一次原子完成"）。

描述符与数据分开是刻意的：`BufHdrGetBlock` 用 `BufferBlocks + buf_id * BLCKSZ`
寻址（bufmgr.c:77-78），描述符数组按缓存行对齐（见 §7）。

## 2. Pin 语义专节：为什么不是传统 latch

**语义**（README:12-26）：pin 是缓冲上的引用计数；**未 pin 的缓冲随时可能被回收改作他页**，
所以碰它之前必须先 pin。pin 的特点是"可以持很久"：顺序扫描可以 pin 着当前页处理完所有元组
（README:18-21），因为"正常操作永远不等待别人的 pin 归零"（README:22-25）——需要排他
处理整页的场景（如 VACUUM 删元组）走的是另一条路：`LockBufferForCleanup`。
这和 Redis 用 key 级互斥、SQLite 页缓存靠 Pager 锁都不同：PG 把"长持有"（pin）
和"短互斥"（内容锁）拆成两个正交机制，长持有者之间可以完全并发。

**实现**：`PinBuffer()`（bufmgr.c:3295）对本 backend 第一次 pin 走 CAS 循环：
`refcount += 1`，默认策略同时 `usage_count` 递增到上限 5（bufmgr.c:3335-3340）；
**ring 策略下 usage_count 只从 0 提到 1**（bufmgr.c:3341-3349），避免扫描型负载把自己
摸过的页"加保护"——环里的页本来就该很快被自己复用。同一 backend 重复 pin 同一缓冲
不再碰共享计数，只加私有的 `PrivateRefCount`（bufmgr.c:3361-3383；设计说明 bufmgr.c:231-258：
"共享 refcount 只改一次"+ 事务结束时校验无泄漏）。`UnpinBuffer` 末次解 pin 用
`pg_atomic_fetch_sub_u64` 原子减（bufmgr.c:3520）。

**BM_PIN_COUNT_WAITER**：删除/压缩页内容（cleanup）要求"独占锁 + 观察到共享 pin 数为 1"
（README:83-92）。`LockBufferForCleanup()`（bufmgr.c:6693）先拿独占内容锁（6724），
锁头自旋锁后查 `refcount == 1`（6728）；不满足则登记
`wait_backend_pgprocno = MyProcNumber` 并置 `BM_PIN_COUNT_WAITER`（6741-6749，注意是
持锁期间用 `fetch_or` 发布标志，防止与并发 refcount 变更竞态），再复查一次（6757-6766）
后释放内容锁睡觉（6817 `ProcWaitForSignal`）。最后一个解 pin 的人在
`UnpinBufferNoOwner` 里 `WakePinCountWaiter`（bufmgr.c:3523-3524，函数在 3443）。
每个缓冲只允许一个此类等待者（6735-6740 直接报错；README:103-107：对 VACUUM 够用，
因为同一关系不允许并发 VACUUM）。热备时 startup 进程若等 pin 超 `deadlock_timeout`
会记 recovery-conflict 日志并触发 `ResolveRecoveryConflictWithBufferPin`（bufmgr.c:6781-6814）。

**锁顺序**（README:136-142 的规则在 buffer 层的投影）：
多个分区锁必须按分区号顺序加；持有 buffer_strategy_lock 期间不得再拿任何别的锁
（README:144-149）；持头自旋锁时只做几条指令的事（README:151-155）。
恢复场景（walredo/startup 进程读页也走 `ReadBufferWithoutRelcache`，bufmgr.c:953）
遵循同一套 pin→内容锁顺序，所以它与其他 backend 之间不需要额外排序规则——唯一的
跨子系统等待点是上面那个 cleanup-pin 冲突，由 recovery conflict 机制兜底。

## 3. Clock sweep 专节：O(1) 无锁推进的时钟

共享状态 `BufferStrategyControl`（freelist.c:32-56）只有五个字段：
`buffer_strategy_lock` 自旋锁（:35）、原子 `nextVictimBuffer` 时针（:42）、
`completePasses`（:48）、`numBufferAllocs`（:49）、`bgwprocno`（:55）。

**指针推进是原子的 fetch_add**，这是 master 相对老实现最大的简化——大部分情况下连
strategy 自旋锁都不用拿：

```c
/* freelist.c:119-127  ClockSweepTick() */
victim = pg_atomic_fetch_add_u32(&StrategyControl->nextVictimBuffer, 1);
if (victim >= NBuffers)
{
    victim = victim % NBuffers;   /* 仅回绕者持自旋锁修正+completePasses++ */
```

`StrategyGetBuffer()`（freelist.c:184）主循环（freelist.c:240-316）：每 tick 取一缓冲，
CAS 循环检查 state——pin 数非 0：跳过（freelist.c:263-277，扫满一圈全是 pin 直接报
`no unpinned buffers available`，freelist.c:274）；`usage_count != 0`：CAS 减 1 继续
（freelist.c:286-296）；否则 CAS 把自己 pin 上（freelist.c:300-312）。这就是 README:187-198
四步算法的无锁化版本。

**与真 LRU 的取舍**：精确 LRU 需要每次访问把页移到队首，在多核共享内存里意味着每次
pin/unpin 都要对全局链表加锁、改 4 个指针——PG 在 8.1 之前正是吃够了单一 BufMgrLock
的苦（README:117-121）。clock 用"访问时顺手 +1（上限 5，buf_internals.h:144），
驱逐时反向 -1"把记账摊平到 CAS 上：热页要被时针扫过 `BM_MAX_USAGE_COUNT+1` 圈
（最多 6 圈）才会被逐出（buf_internals.h:136-143 的注释算过这笔账）。
对照：Redis 的 LFU（24 位 ldec 概率衰减计数）与 PG 的 usage_count 同属"有损计数器"思想，
但 PG 把衰减做在**驱逐方**（每次被时针路过就 -1），Redis 做在**访问方**（定时衰减）；
LevelDB/InnoDB 的 LRU 则维护显式双向链表（InnoDB 还要分 young/old 子链防全表扫描污染），
并发成本都高于 clock——PG 等价地把"防污染"外包给了 §5 的 ring。
clock 的代价是近似：无全局时序、页的"年龄"只体现为计数深浅。

**与 bgwriter 的配合**：分配计数 `numBufferAllocs` 每次自增（freelist.c:237）；
bgwriter 醒来用 `StrategySyncStart`（freelist.c:331，唯一必须持 strategy 自旋锁的读者）
拿到时针位置与分配速率（bufmgr.c:3901），据此决定这次清扫多远（bufmgr.c:3854 起
`BgBufferSync`），**从时针当前位置向前**找"脏且未 pin 且 usage=0"的页提前写盘
（README:250-258）——注意 bgwriter 只读时针不推动时针。分配方还可以顺手叫醒 bgwriter：
`StrategyGetBuffer` 发现 `bgwprocno != -1` 就 `SetLatch`（freelist.c:218-230，
`StrategyNotifyBgWriter` 注册于 freelist.c:368）。

## 4. 哈希表与分区锁专节

映射结构极简：`BufferTag{RelFileLocator, ForkNumber, blockNum}` → `int id`
（`src/backend/storage/buffer/buf_table.c:28-32`），一张共享 HTAB，元素个数
`NBuffers + NUM_BUFFER_PARTITIONS`（buf_table.c:62，插入新条目先于删旧条目，
最坏每分区多挂一个）。tag 必须自含定位信息——刷盘的 backend 可能根本"看不见"这张表
（buf_internals.h:150-156）。

锁粒度：`NUM_BUFFER_PARTITIONS = 128`（`src/include/storage/lwlock.h:83`），
分区号 = hash 低位：`hashcode % NUM_BUFFER_PARTITIONS`
（buf_internals.h:250），对应 `BufMappingPartitionLock`（buf_internals.h:254）。
查表只需分区锁的 **LW_SHARED**（BufferAlloc bufmgr.c:2223-2224），改映射才要
**LW_EXCLUSIVE**（bufmgr.c:2276）。README:136-142：8.2 把单一 BufMappingLock 拆成
128 份后，普通路径的锁竞争随核数扩展；多分区按分区号排序防死锁。
命中路径的持锁窗口只有"查表 + pin"几条指令（bufmgr.c:2237-2240），miss 路径在
真正干活前就放锁（bufmgr.c:2261）。对比 Redis：全局字典一把大锁 + 分桶渐进扩容；
PG 用"读共享锁 + 128 分区写锁"，读读并发完全不互斥，这是关系库 read-mostly 负载的刚需。

碰撞处理也是一课：BufferAlloc 拿 EX 锁插入时若发现已有同 tag 条目
（`BufTableInsert` 返回冲突 id，buf_table.c:139-140），说明别的 backend 抢先一步——
放弃自己刚抢到的 victim，直接 pin 对方的缓冲（bufmgr.c:2278-2317）。

## 5. Ring buffer 专节：给大扫描一个"预算"

`BufferAccessStrategy` 是个后端私有小对象：类型 + 环大小 + 当前槽 + buffer 数组
（freelist.c:74-94）。三种尺寸（`GetAccessStrategy`，freelist.c:426-501）：

- `BAS_BULKREAD`：256KB 起（freelist.c:459），再按 `effective_io_concurrency ×
  io_combine_limit` 加读 Look-ahead（480-481）——顺序扫描用（heapam.c:410）。
- `BAS_VACUUM`：默认 2048KB（freelist.c:490-491）；实际由 `VACUUM (BUFFER_USAGE_LIMIT)`
  / GUC `vacuum_buffer_usage_limit` 决定（vacuum.c:454-461，变量默认值
  `VacuumBufferUsageLimit = 2048`，globals.c:152），设 0 表示完全不用环。
- `BAS_BULKWRITE`：16MB（freelist.c:487-488），COPY IN / CTAS 用
  （heapam.c:1943 建 `BulkInsertState`，copyfrom.c:372 挂到 COPY 状态）。
- 上限一律 `Min(NBuffers/8, ...)`（freelist.c:526）；普通策略建议最多 pin 半个环
  （`GetAccessStrategyPinLimit`，freelist.c:574-599）。

复用逻辑在 `GetBufferFromRing`（freelist.c:623）：推进槽位（632-633），空槽则回退到
正常 clock 淘汰一次并 `AddBufferToRing` 入环（freelist.c:702）；非空槽只要
`refcount==0 且 usage_count<=1` 就可直接复用（freelist.c:664-666）——usage 高说明
别人在共享池里又摸过它，此时也回退正常淘汰。**这是"扫描预算"思想在 PG 的第二次现身**
（第一次是 work_mem）：大扫描对共享池的破坏被限制在 ≤ shared_buffers/8 的环里。

WAL 交互是环的另一半故事：复用脏页前必须先刷 WAL（WAL 先行规则）。VACUUM 的选择是
"脏页留在环里，需要时自己刷 WAL"（README:233-238，避免 8.3 之前"环=1 个缓冲"时代的
过度 WAL flush）；而 bulkread 环里若某页被弄脏（典型是 hint bit），复用需刷 WAL 时干脆
**把该页踢出环、回退正常淘汰**：`StrategyRejectBuffer` 只对 BAS_BULKREAD 生效
（freelist.c:752-770，把槽置回 InvalidBuffer），判定点在 `GetVictimBuffer`——持
share-exclusive 内容锁检查 `XLogNeedsFlush(BufferGetLSN)`（bufmgr.c:2624-2631）。

## 6. 脏页与写路径：MarkBufferDirty 之后谁来写盘

`MarkBufferDirty()`（bufmgr.c:3170）只做一件事：断言已 pin + 持独占内容锁
（bufmgr.c:3187-3188），CAS 置 `BM_DIRTY`（bufmgr.c:3205）。**它不触发任何 I/O**。

写盘的角色分工（细节留 D 篇）：

1. **发起读的 backend 自己**：miss 抢 victim 时若它脏，就当场
   `FlushBuffer`（bufmgr.c:2584-2634）——先拿 share-exclusive 内容锁（2603，条件加锁防
   btree 分裂互等死锁，注释 2589-2601），刷 WAL 到页 LSN（4585 `XLogFlush`），再
   smgrwrite。
2. **bgwriter**：`BgBufferSync` 沿 clock 时针前方清扫，把"即将被淘汰的脏页"提前写掉
   （bufmgr.c:3854；策略见 §3）。
3. **checkpointer**：checkpoint 时 `BufferSync`（bufmgr.c:3575）全池扫
   `BM_DIRTY`（含 `BM_PERMANENT` 过滤，3587-3597）排序写盘，并清
   `BM_CHECKPOINT_NEEDED`。

写页必须持 share-exclusive 内容锁（README:109-111；`FlushBuffer` 断言
bufmgr.c:4534-4535）——防止写到一半页被改，破坏 checksum/Direct-IO 语义。
扩展关系另有 `LockRelationForExtension` 关系级扩展锁，但 victim 的挑选与清零被刻意
放在拿扩展锁**之前**（bufmgr.c:2816-2836），缩短临界区。

## 7. 设计动机

**为什么 8KB 页 + 缓冲池**：BLCKSZ 默认 8192，可配至 32KB 上限（受 ItemIdData 的
15 位 lp_off/lp_len 宽度限制，`src/include/pg_config.h.in:20-27`），改需 initdb。
页是 WAL 崩溃恢复、full_page_write、checksum 的最小一致性单元；缓冲池则把
"磁盘系统"抽象成"内存数组 + tag 索引"，上层 AM 永远只操作 `Buffer` 整数。

**Pin 的最小临界区**：共享 refcount 是单个 64 位字里的低 18 位，pin/unpin 就是一次
原子加减，无需任何系统级锁（README:151-155 的"每缓冲自旋锁"只用于改 tag/标志位）。
一次堆扫描的稳态是：pin（1 条 CAS）→ 内容锁 → 解锁 → 继续拿着 pin 慢慢读元组
（README:49-56）——锁的持有窗口是微秒级，pin 的持有窗口可以到毫秒级，两者互不阻塞。

**Clock 的 O(1) 无锁推进**：时针是单调递增的 `pg_atomic_uint32`（freelist.c:42,119-120），
推进者只做 fetch_add；自旋锁仅在回绕修正 `completePasses` 时出现
（freelist.c:153-161），且只被回绕的那一个进程持有。驱逐扫描（CAS 减 usage / 试 pin）
完全锁外并行——N 个 backend 可以同时扫不同缓冲。这就是"少量共享可变状态 + 原子字"
对"大锁"的完胜，与 Redis 的事件循环单线程避免锁是同构的两个极端解。

## 8. FAQ 素材

1. **Buffer 为什么从 1 编号？** `Buffer = buf_id + 1`，0 是 `InvalidBuffer`
   （buf_internals.h:438）；负数表示本地缓冲 `-buf_id - 1`（bufmgr.c:4476）。
2. **同一 backend 重复 pin 会把共享 refcount 加几次？** 一次。后续 pin 只记
   `PrivateRefCount`（bufmgr.c:231-238, 3361-3383）。
3. **usage_count 上限为什么是 5 而不是更大？** 上限逼近 LRU 语义，但最坏要扫
   `5+1` 整圈才找到 victim（buf_internals.h:136-144），值越大"一整圈全白扫"的延迟越高。
4. **miss 的页被两个 backend 同时要怎么办？** 后到者在 BufTableInsert 撞见先到者的
   条目，放弃自己的 victim 改用对方缓冲（bufmgr.c:2277-2317）；I/O 只做一次
   （`BM_IO_IN_PROGRESS` + `io_wref`，bufmgr.c:7290-7310）。
5. **为什么 pin 可以长持，内容锁必须短持？** pin 防的是"缓冲被物理回收"，无人等待
   pin 归零（README:22-25）；内容锁保护页内数据一致性，必须短持（README:38-41）。
6. **hint bits 为什么只需要 share-exclusive 锁？** 多个 backend OR 的是同一批位，
   冲突最坏丢一次更新、以后重做（README:63-78）；但 freeze 同时置两标志属关键更新，
   要独占锁 + WAL（README:79-81）。
7. **"no unpinned buffers available" 什么时候发生？** clock 扫满 NBuffers 个缓冲
   全被 pin 时（freelist.c:263-275）——通常说明 shared_buffers 相对并发太小。
8. **临时表为什么不走共享池？** 会话私有、无 WAL、无 checkpoint，localbuf 版 clock
   连原子操作都省了（`pg_atomic_unlocked_write_u64`，localbuf.c:168-171；注释
   localbuf.c:114-116 "we do not need to do any locking"）。
9. **VACUUM 的环设成 0 会怎样？** `GetAccessStrategyWithSize` 返回 NULL，
   VACUUM 退化为默认淘汰策略，整池冲刷风险回归（vacuum.c:454-461，freelist.c:521-523）。
10. **clock 扫到的脏页要写盘，但锁被人拿了？** 条件加锁失败就放弃该 victim 重挑
    （bufmgr.c:2603-2611），牺牲一点效率换死锁自由。

## 9. 深挖方向

1. **AIO 与缓冲 I/O 的新协议**（master 新增）：`StartSharedBufferIO` 三态返回
   READY/IN_PROGRESS/ALREADY_DONE（bufmgr.c:7290-7287 附近），`WaitIO` 优先
   `pgaio_wref_wait` 复用 AIO 自己的条件变量（bufmgr.c:7228-7241）——对比 PG17 的
   per-buffer LWLock 方案，写一篇"BM_IO_IN_PROGRESS 的三代演进"。
2. **PrivateRefCount 数组+哈希的混合设计**：≤REFCOUNT_ARRAY_ENTRIES 用顺排数组、
   溢出进哈希表，防止热条目卡死（bufmgr.c:243-251）——缓存友好设计的小品。
3. **checkpoint 的表空间均衡写**：`CkptSortItem` 按表空间排序 + 每表空间配额
   （buf_init.c:107-110 预分配，bufmgr.c:3575 起）。
4. **read_stream / StartReadBuffers 多块合并**：`MAX_IO_COMBINE_LIMIT`、命中块把
   I/O 一分为二（bufmgr.c:1485-1495）——PG18/19 批量读框架如何叠加在缓冲管理器之上。
5. **伪共享攻防**：`BufferDescPadded` 强制 64 字节 stride（buf_internals.h:362-381，
   buf_init.c:79-84 cache-line 对齐），而本地缓冲描述符不做对齐
   （buf_internals.h:373-375）——可用 perf c2c 复现的案例。

## 10. 写作要点速查表

| 主题 | 文件:行号 | 要点 |
|---|---|---|
| 状态字布局 | src/include/storage/buf_internals.h:34-55 | 64 位打包 refcount/usage/flags/锁 |
| BM_ 标志位 | src/include/storage/buf_internals.h:106-127 | 12 个标志一览 |
| usage 上限=5 | src/include/storage/buf_internals.h:136-144 | clock 取舍注释 |
| BufferDesc 结构 | src/include/storage/buf_internals.h:326-359 | tag/buf_id/state/io_wref |
| 描述符 64B 对齐 | src/include/storage/buf_internals.h:362-381 | BUFFERDESC_PAD_TO_SIZE |
| ReadBuffer 入口 | src/backend/storage/buffer/bufmgr.c:879,926,1276 | 三层入口链 |
| BufferAlloc 主路径 | src/backend/storage/buffer/bufmgr.c:2197-2351 | 查表/抢 victim/插表 |
| GetVictimBuffer | src/backend/storage/buffer/bufmgr.c:2548-2662 | 脏页处理+环拒绝 |
| PinBuffer | src/backend/storage/buffer/bufmgr.c:3295-3386 | CAS+usage 递增 |
| UnpinBuffer | src/backend/storage/buffer/bufmgr.c:3479-3528 | fetch_sub+唤醒 waiter |
| MarkBufferDirty | src/backend/storage/buffer/bufmgr.c:3170-3219 | 只置 BM_DIRTY |
| LockBufferForCleanup | src/backend/storage/buffer/bufmgr.c:6693-6859 | BM_PIN_COUNT_WAITER 协议 |
| FlushBuffer | src/backend/storage/buffer/bufmgr.c:4526-4585 | share-excl 锁+XLogFlush |
| BufferSync/BgBufferSync | src/backend/storage/buffer/bufmgr.c:3575,3854 | checkpoint/bgwriter 写 |
| StartSharedBufferIO/WaitIO | src/backend/storage/buffer/bufmgr.c:7290,7188 | AIO 时代 I/O 互斥 |
| ClockSweepTick | src/backend/storage/buffer/freelist.c:110-166 | fetch_add 推时针 |
| StrategyGetBuffer | src/backend/storage/buffer/freelist.c:184-317 | 扫描循环+唤醒 bgwriter |
| StrategyControl | src/backend/storage/buffer/freelist.c:32-56 | strategy 自旋锁+时针 |
| ring 尺寸 | src/backend/storage/buffer/freelist.c:459,487-491,526 | 256KB/16MB/2MB, ≤1/8 池 |
| GetBufferFromRing | src/backend/storage/buffer/freelist.c:623-693 | usage≤1 才复用 |
| StrategyRejectBuffer | src/backend/storage/buffer/freelist.c:752-770 | BULKREAD 踢脏页 |
| 哈希表结构 | src/backend/storage/buffer/buf_table.c:28-32,62,69 | tag→id, 分区数 |
| 分区锁 | src/include/storage/buf_internals.h:250-254; lwlock.h:83 | hash%128 |
| 共享池初始化 | src/backend/storage/buffer/buf_init.c:79-140 | 对齐+清零循环 |
| 本地缓冲 | src/backend/storage/buffer/localbuf.c:119-177,225 | 无锁 clock 变体 |
| 官方 README | src/backend/storage/buffer/README:12-26,114-169,172-247 | pin/锁分层/两策略 |
