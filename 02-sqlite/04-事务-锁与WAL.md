# 第 04 章 · 事务、锁与 WAL:一份数据,两种崩溃恢复哲学

> 基线:SQLite 3.54.0,commit `492e7fc`。行号均以该版本源码为准。
> 调用栈定位:VDBE 的 OP_Transaction/OP_Commit → `sqlite3BtreeBeginTrans/Commit` → pager 的 SharedLock/Begin/CommitPhaseOne/PhaseTwo → VFS 的 xLock/xSync。**btree 层只管改内存页,持久性与并发控制全部落在 pager 与 VFS**。pager.c 开头的 13 条不变式注释(pager.c:26-110)是理解整个子系统的钥匙。

## 4.0 六种 journal 模式与七状态机

模式定义在 pager.h:78-86,数值编码有个巧妙设计:`TRUNCATE & 5 == 1`、`PERSIST & 5 == 1`、`DELETE & 5 == 0`,pager.c:7460-7465 用 assert 固化——模式切换时靠它判断"旧模式是否留下持久 journal 文件"。

| 模式 | 提交时对 -journal 的动作 | 关键源码 |
|---|---|---|
| DELETE(默认) | close + unlink | pager.c:2150-2159 |
| TRUNCATE | `xTruncate(jfd,0)`;fullSync 时再 sync 一次防"复活" | pager.c:2124-2138 |
| PERSIST | 把 journal 头 28 字节清零,文件保留 | pager.c:1436-1469 |
| MEMORY | journal 是内存文件,提交即丢弃 | pager.c:2121-2123 |
| OFF | 不开 journal;出错回滚只能进 ERROR 态 | pager.c:6847-6859 |
| WAL | 不写回滚日志,走 wal.c | pager.c:2186-2192 |

PERSIST"清零头"而非删文件,是因为删除是大文件场景下最贵的操作;清零后 `hasHotJournal` 读首字节即判定无效。

**Pager 七状态机**(pager.c:139-157、351-357):

```
OPEN → READER → WRITER_LOCKED → WRITER_CACHEMOD → WRITER_DBMOD → WRITER_FINISHED
  ↑                ↑                                                 │
  └────────────────┴───────────────(回退)←───────────────────────────┘
                   任何 WRITER_* 态出错 → ERROR → (引用清零后) → OPEN
```

各状态物理含义值得记住:WRITER_CACHEMOD = journal 已开且写了 header 但未 sync,缓存已脏、**数据库文件未动**;WRITER_DBMOD = journal header 已 sync,开始改库文件本体——**注释明确"WAL 连接永不进入此状态,因为它们不改数据库文件"**(pager.c:248-260)。状态转换函数对照:`OPEN→READER` 是 `sqlite3PagerSharedLock`,`READER→WRITER_LOCKED` 是 `sqlite3PagerBegin`,`CACHEMOD→DBMOD` 是 `syncJournal`,四条 `WRITER_*→READER` 都是 `pager_end_transaction`(pager.c:159-169)。

**savepoint**:pager 内的数组结构(pager.c:431-442),rollback 模式记"主 journal 偏移 + journal 头偏移 + 页位图 + 子 journal 起始记录号",WAL 只记 4 个 u32(mxFrame、链尾校验和、nCkpt)。关键区别:savepoint 回滚**不解锁、不终结事务**——"只把数据库内容恢复原状"(pager.c:7055-7059),语句级回滚(ON CONFLICT ABORT)正靠这层实现。

## 4.1 回滚日志:把随机写变成 undo 保护的随机写

### journal 格式与极简校验和

```
journal 头(占满一个 sector,实际 28 字节):
  8B magic | 4B nRec(0xffffffff=按文件大小推算) | 4B cksumInit(随机)
  | 4B 初始页数 | 4B sector size | 4B page size … padding 到 sector

记录 = 4B 页号 + pageSize 字节旧页内容 + 4B 校验和
```

校验和是极简方案:`cksumInit + 每 200 字节取 1 字节累加`(pager.c:2289-2297)。注释解释了为何够用:**掉电最可能破坏记录的一端而非中段**(2283-2287)。每写满一个 sector 写一个新 header(nRec 归零重新计数)。

### 提交流程与 fsync 时机

```
 BEGIN(拿 RESERVED 锁)              COMMIT
      │                               │
      ▼                               ▼
[WRITER_LOCKED]──首次写页──▶[WRITER_CACHEMOD]
      sqlite3PagerWrite: 旧页入 journal
      │
      │   CommitPhaseOne (pager.c:6527)
      │     1. pager_incr_changecounter: 改页1的 24..39 字节 (6652)
      │     2. writeSuperJournal: 多库事务写超级日志 (6660)
      │     3. syncJournal (6674):                    ── fsync ①
      │          a. RESERVED→EXCLUSIVE (4349)
      │          b. FULL 时先 fsync(journal) 再写 nRec (4409-4418)
      │          c. → 进入 WRITER_DBMOD (4446)
      │     4. 脏页写数据库文件 (6712)
      │     5. sqlite3PagerSync:                      ── fsync ②
      ▼
[WRITER_FINISHED]
      │   CommitPhaseTwo (6764) → pager_end_transaction (2090):
      │        按模式终结 journal(2117-2160);PERSIST 清头后还有 fsync ③
      ▼
[READER]  EXCLUSIVE 降回 SHARED (2209-2214)
```

**nRec 为什么先写 0 再回填**:0xffffffff(按文件大小推算)的前提是"文件尾部垃圾不可能被当成记录"。普通文件系统 append 掉电可能留垃圾,所以必须先写记录、sync、再回头把 nRec 写进头(pager.c:4398-4419);有 `SQLITE_IOCAP_SAFE_APPEND` 的设备可省这一往返(1532-1536)。

### 崩溃恢复:hot journal 回放

读事务入口 `sqlite3PagerSharedLock`(pager.c:5316-5523):

1. 拿 SHARED 锁;
2. `hasHotJournal`(5196-5287):journal 存在 && 无人持 RESERVED && 首字节非 0——注释承认与其它进程删 journal 的竞态(ticket #3883),**宁可误报交给回放例程**;
3. 若热:**直接拿 EXCLUSIVE 锁(5370)——不能途经 RESERVED**,否则其他进程会误以为可安全读(5355-5364);
4. 回放前先 sync journal(4102-4109),保证"回放中途再掉电看到的日志一致";
5. `pager_playback`(2872-3060):先 truncate 数据库回 mxPg,再逐记录校验回写,只读到第一个坏记录为止;
6. 回放后终结 journal,降回 SHARED。

回放之后还有**缓存一致性检查**(5452-5493):读偏移 24 的 16 字节(change-counter)与缓存 `dbFileVers[]` 比对,不一致则丢弃整页缓存并 unmap mmap——这就是不变式 (9)"提交必改 24..39 字节、十亿次内不重复"的消费端。只读连接遇到 hot journal 报 `SQLITE_READONLY_ROLLBACK`——**只读连接无法回放**。

## 4.2 WAL:把随机写变成追加写 + 一个内存提交点

### 文件格式与校验和链

32 字节头(magic、版本 3007000、页大小、checkpoint 序号、Salt-1/2、头校验和);帧 = 24 字节帧头(页号、nTruncate、两个 salt、两个校验和)+ 一页数据(wal.c:46-57)。**校验和链**:每帧校验和对"WAL 头前 24 字节 + 此前所有帧 + 本帧头前 8 字节 + 本页数据"做链式累计(Fibonacci 加权和 s0/s1,wal.c:70-87)。帧有效判据:salt 与当前 WAL 头一致 + 链上校验和吻合。**checkpoint 后 Salt-1 自增、Salt-2 随机化**(95-98),旧帧自然失效——这是 WAL 文件可原地覆盖复用的机制基础。

### wal-index(-shm):易失的共享内存索引

wal-index 是 mmap 的 `-shm` 文件,**易失**——崩溃后可随时从 WAL 重建(wal.c:127-146),因此允许用宿主机字节序。头部 136 字节 = 两份互为副本的 WalIndexHdr(防撕裂读)+ WalCkptInfo:

```
0..47    WalIndexHdr #1  (iVersion, iChange, isInit, szPage,
                          mxFrame, nPage, aFrameCksum[2], aSalt[2], aCksum[2])
48..95   WalIndexHdr #2  (相同副本)
96..99   nBackfill       (已回填帧数)
100..119 aReadMark[5]    (每个读槽的快照位置)
120..127 aLock[8]        (8 个锁字节)
```

哈希索引块(每块 4096 页、8192 个 u16 槽,wal.c:153-202)把"页号→帧号"从全 WAL 扫描降为期望 2-3 次探测;哈希函数 `iKey=(P*383)%NSLOT` 线性再探,写侧保证表不满半。注意哈希槽存**块内索引**而非帧号,查询要加 `sLoc.iZero` 还原(wal.c:3589-3597)。

读 wal-index 头采用"先无锁试探,失败再加锁"两段式(`walIndexReadHdr`,wal.c:2660-2763):直接校验双头之一的校验和;失败则独占 WRITE_LOCK 重试;仍失败必然损坏,跑 `walIndexRecover` 重建——逐帧 `walDecodeFrame` 验证,**只有提交帧(nTruncate≠0)才推进 mxFrame**(1515-1519),这就是"未提交帧崩溃后自动作废"的机制。

### 读路径:mxFrame 快照 + aReadMark

`walTryBeginRead`(wal.c:3020-3278)的两种结局:

- 若 `nBackfill == mxFrame`(WAL 已全部回填):尝试 `READ_LOCK(0)`,持锁者**完全忽略 WAL、直读数据库文件**;
- 否则遍历 5 个 `aReadMark[]`,挑"≤mxFrame 的最大值"槽加共享锁;没有现成槽等于 mxFrame 就独占改写某槽再降回共享(3190-3205)。

aReadMark 的精妙之处(注释 355-383):mark 只能由**独占**持锁者修改,读者持共享锁期间快照不漂移;checkpoint 只能回填"≤所有在用 aReadMark"的帧;哈希里若出现晚于快照的条目,`walFindFrame` 用 `iFrame<=快照mxFrame` 过滤(3563-3573)。

### 写路径与提交点

`sqlite3WalBeginWriteTransaction`(3703-3750):独占 `WAL_WRITE_LOCK`,然后 **memcmp 私有 WalIndexHdr 与共享头——不一致说明读事务开始后别人提交过,返回 `SQLITE_BUSY_SNAPSHOT`**(3739-3741)。它**不能靠 busy handler 重试解决**,必须结束读事务重来;btree 在外层事务刚开始时把它降级成普通 BUSY 以便兼容(btree.c:3750-3754)。

`walFrames`(4042-4270)逐脏页写帧,最后一页写 nTruncate=提交后页数即**提交帧**;然后 `walIndexAppend` 登记进 shm 哈希,提交时 `walIndexWriteHdr` 把新 mxFrame 推给所有读者(4238-4265)。**提交点就是这次 shm 头写入,不需要 fsync**——掉电后由 walIndexRecover 从 WAL 重放重建。这是 WAL 比回滚日志快的根本原因之一。`synchronous=NORMAL` in WAL 时提交位为 0 由 `walSyncFlags` 的位打包直接固化(pager.c:613-617)。

### checkpoint:回填上限是读者协商出来的

`walCheckpoint`(wal.c:2199-2395):

1. 计算 `mxSafeFrame`:逐个尝试独占读槽,拿到就把该槽 mark 置 mxSafeFrame 释放;拿不到(BUSY)说明槽上有活跃读者,**`mxSafeFrame = 该读者的 mark` 并停用 busy handler**(2233-2251);
2. 独占 `READ_LOCK(0)` 冻结系统,先 fsync(WAL) 做写屏障(2277),然后按 **WalIterator 多路归并迭代器**回填——对每个页号只写**最新**帧,checkpoint 的写量与"WAL 覆盖了多少不同页"成正比,而非帧数(2304-2323);
3. 仅当 `mxSafeFrame == 当前 mxFrame`(全量回填)才 truncate 数据库文件。

三种模式差异全在收尾(wal.c:2358-2389):PASSIVE 不阻塞任何人;RESTART 回填后独占读槽 1..4 等读者退出,迫使下一个写者从头重启 WAL;TRUNCATE 再把 WAL 文件截为 0。**WAL 无限增长的第一元凶是长读事务**:mxSafeFrame 只能收缩不能前进。

## 4.3 锁五态与 SQLITE_BUSY

五态定义在 os.h:98-102,锁落在数据库文件的**约定字节偏移**(os.h:160-166):`PENDING_BYTE=0x40000000`(1GB 处)、RESERVED/PENDING 各 +1、SHARED 区 510 字节。

`unixLock`(os_unix.c:1866-2095)的语义:

- **SHARED**:先 `F_RDLCK` PENDING_BYTE 作准入闸,再读锁整个 SHARED 区,然后释放 pending 字节 → 多进程并发;
- **RESERVED**:`F_WRLCK` 单字节 → 全库至多一个写者占位。它的作用是给 hot-journal 检测提供判据:"无人持 RESERVED"才是崩溃残留(pager.c:5214-5226);
- **RESERVED→EXCLUSIVE 途中**:先 `F_WRLCK` PENDING_BYTE——**挡住新的 SHARED、放过存量读者**,让读者自然排空(os_unix.c:1898-1906)。PENDING 不是显式请求的锁(assert,1935);
- **EXCLUSIVE**:写锁整个 SHARED 区,成功即独占。

busy handler 只在两种升级时调用(pager.c:3766-3772):`NO_LOCK→SHARED` 与 `RESERVED→EXCLUSIVE`;**`SHARED→RESERVED` 不调用**——"写者应快速失败,别压着读者排队"。SQLITE_BUSY 产生点清单(映射自 fcntl 的 EAGAIN/EACCES 等,os_unix.c:1024-1038;WAL 快照过期、checkpoint 抢锁、walTryBeginRead 重试 100 次后返回 SQLITE_PROTOCOL 等,各见上表位置)。

## 4.4 设计动机:何时选 WAL,何时选 rollback

| 维度 | rollback journal | WAL |
|---|---|---|
| fsync 次数(FULL) | ≈4 次(journal 头/DATAONLY/db/终结) | 1 次(提交帧;checkpoint 另计) |
| 提交关键路径 | journal sync → N 页覆盖写 → db fsync → 删文件 | append N 帧 → fsync WAL → 写 shm 头(内存) |
| 并发 | 读写互斥 | 读写并发,单写者 |
| 崩溃恢复 | 整库级 hot journal 回放,期间全库阻塞 | 精确到帧,只重建指针 |
| 环境约束 | 单文件自包含,网络文件系统可用 | 依赖 mmap 共享内存,仅限单机 |

**工程法则**(从代码约束直接推出):多读少写、要读写并发、单机多进程 → WAL + synchronous=NORMAL;强持久性单写、只读介质/无共享内存、要拷单文件 → rollback;写多读少的事务巨大场景,rollback 的"一次覆盖 + journal 一次 sync"可能反而比 WAL 的帧放大 + checkpoint 二次写更省 IO——大批量导入建议先关 WAL 的文档建议,源码依据就是每页 24 字节帧头 × 2(写 + 回填)。

## 4.5 FAQ

**Q1:DELETE 模式 COMMIT 时掉电,会半新半旧吗?**
不会越过事务边界:journal 在 → 回放;journal 已删 → db 已完整落盘。半新半旧只出现在 synchronous=OFF 的"合法损坏"里。

**Q2:WAL+NORMAL 真的不丢已确认事务吗?**
限定为"不丢进程崩溃";OS 崩溃/掉电后最近的提交可能丢(提交位 fsync=0,pager.c:613-617)。

**Q3:PENDING 锁为什么不允许显式请求?**
它是升级失败的"搁浅状态":挡新 SHARED、放旧 SHARED,让读者自然排空,避免 fcntl 读写锁死锁式互斥。

**Q4:为什么 WAL 文件能无限增长?何时从头覆盖?**
仅当 `nBackfill==mxFrame` 且无读者持读槽(wal.c:384-389 注释);此时 `walRestartLog` 换 salt 重置;TRUNCATE checkpoint 顺手截 0。

**Q5:SQLITE_BUSY_SNAPSHOT 怎么来的?**
WAL 写事务开始时 memcmp 私有头与共享头(3739-3741);读快照后他人提交则升级失败,必须重开读事务。

**Q6:savepoint 在两种模式下实现有何不同?**
rollback 靠"journal 偏移 + 页位图"三重书签逐页回放;WAL 只拨回 mxFrame——几乎零成本,嵌套事务/触发器在 WAL 下更快的直接原因。

**Q7:checkpoint(PASSIVE)中途来了新提交会怎样?**
mxSafeFrame 开始时已固定,超出帧直接跳过(2312-2314);新提交不影响本次,留给下次。

**Q8:cache spill 在两种模式下代价差多少?**
rollback 模式可能触发 syncJournal(含 RESERVED→EXCLUSIVE 升级,可能 BUSY);WAL 下只是写一个 commit=0 的帧,同页重复写原地覆盖帧(wal.c:4147-4167)。

**Q9:mmap 与事务安全的关系?**
共享锁重取时读 change-counter 比对 `dbFileVers`,不一致则整缓存作废并 unmap(5452-5493)——防外部进程改库后用陈旧 mmap。

**Q10:pager 出错后为何进 ERROR 态而不直接回滚?**
回放本身也可能失败;继续读写会报假 corruption 或写坏文件。ERROR 冻结一切,引用清零后丢弃缓存重建。

## 4.6 小结与深挖方向

本章结论:**rollback = "undo 保护的随机写",WAL = "追加写 + 内存提交点 + 后台回填"**;两者的 fsync 次数、并发模型、恢复粒度全部可以从不变式与状态机推导。深挖方向:

1. wal-index 双头协议在 32 位平台上的撕裂读证明与 SEH 分支;
2. `SQLITE_IOCAP_BATCH_ATOMIC` 路径能否在 NVMe 上彻底取消 journal(pager.c:6679-6708);
3. hot journal 检测 TOCTOU 窗口的多进程故障注入;
4. checkpoint 与长读者的饥饿:读者租约超时的实现切入点;
5. 自旋退避(SQLITE_PROTOCOL)与用户 busy handler 混用的优先级倒置。

> 下一章转向上层:一条 SQL 文本如何变成 VDBE 程序——词法、lemon 文法、表达式树与查询优化器。
