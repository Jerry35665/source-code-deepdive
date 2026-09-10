# B 篇 · 事务、锁与 WAL —— 基于 sqlite 3.54.0(commit 492e7fc0)源码逐段调研

> 本文所有行号均对应仓库 `repos/sqlite/src/` 下的源码文件,版本 3.54.0。核心文件:`pager.c`(7896 行)、`wal.c`(4649 行)、`os_unix.c`(8582 行,仅锁部分)。

---

## ① 事务体系全景:journal 模式 × 锁 × 状态机

SQLite 的事务原子性全部落在 pager 层:btree 层只管改内存页,持久性与并发控制由 pager 与 VFS 共同完成。调用栈自上而下是:VDBE 的 OP_Transaction/OP_Commit/OP_AutoCommit 操作码 → `sqlite3BtreeBeginTrans`/`sqlite3BtreeCommit`(btree.c:3741-3755 可见它把 `SQLITE_BUSY_SNAPSHOT` 降级为 `SQLITE_BUSY` 的逻辑)→ pager 的 SharedLock/Begin/CommitPhaseOne/PhaseTwo → VFS 的 xLock/xSync。pager.c 开头的 13 条不变式注释(pager.c:26-110)是理解整个子系统的钥匙,例如不变式 (1):数据库页永远不能被覆盖,除非"原内容已写入回滚日志并 sync"(a)、该页事务开始时是 freelist 叶子页(b)、或页号超过事务开始时的文件大小(c)(pager.c:37-47);不变式 (12)/(13) 则把"写库必持 EXCLUSIVE、读库必持 SHARED"钉死(pager.c:104-108)。WAL 模式反过来:先写日志(WAL),再由 checkpoint 回填数据库。

### 1.1 六种 journal 模式的文件语义

模式定义在 pager.h:78-86,数值编码有个巧妙设计:`TRUNCATE & 5 == 1`、`PERSIST & 5 == 1`,而 `DELETE & 5 == 0`,pager.c:7460-7465 用 assert 固化了这一关系,供模式切换时判断"旧模式是否留下持久 journal 文件"(pager.c:7468)。

| 模式 | 提交时对 -journal 文件的动作 | 关键源码 |
|---|---|---|
| DELETE(默认) | close + unlink,删目录时可选 extraSync | pager.c:2150-2159 |
| TRUNCATE | `xTruncate(jfd, 0)`;fullSync 时再 sync 一次,防止 power-loss 后 journal "复活" | pager.c:2124-2138 |
| PERSIST | 把 journal 头 28 字节清零(zeroJournalHdr),文件保留 | pager.c:1436-1469, 2139-2143 |
| MEMORY | journal 是内存文件(memjournal.c),提交即丢弃 | pager.c:2121-2123, 5914-5915 |
| OFF | 根本不开 journal;出错回滚只能进 ERROR 态报 SQLITE_ABORT | pager.c:6847-6859 |
| WAL | 不写回滚日志,走 wal.c;`pager_end_transaction` 只释放 WAL 写锁 | pager.c:2186-2192 |

PERSIST 模式"清零头"而不是删文件,是因为删除是大文件场景下最贵的操作;清零后 hot-journal 检测(`hasHotJournal` 读首字节判断,pager.c:5254-5267)会认为它无效。注意 zeroJournalHdr 在 `doTruncate || journalSizeLimit==0` 时会退化为直接 truncate(0)(pager.c:1444-1448),sync 用 `SQLITE_SYNC_DATAONLY`(pager.c:1450-1452)。

### 1.2 Pager 七状态机

状态与转换图在 pager.c:139-157,状态常量在 pager.c:351-357:

```
OPEN → READER → WRITER_LOCKED → WRITER_CACHEMOD → WRITER_DBMOD → WRITER_FINISHED
  ↑                ↑                                                  │
  └────────────────┴────────────────(回退)←──────────────────────────┘
                    任何 WRITER_* 态出错 → ERROR → (引用清零后) → OPEN
```

各状态的物理含义:

- **OPEN**(pager.c:172-181):锁状态未知,dbSize 不可信。
- **READER**(pager.c:182-205):持有 SHARED 锁,dbSize 可信;保证文件系统里没有 hot-journal。
- **WRITER_LOCKED**(pager.c:206-233):回滚模式下持有 RESERVED(或 BEGIN EXCLUSIVE 直接拿 EXCLUSIVE),journal 尚未打开;WAL 模式下是 `sqlite3WalBeginWriteTransaction()` 成功。
- **WRITER_CACHEMOD**(pager.c:235-246):journal 已打开且写了第一个 header,但 header 未 sync;缓存已脏,数据库文件未动。
- **WRITER_DBMOD**(pager.c:248-260):journal header 已 sync,开始改数据库文件本体。注释明确:"WAL 连接永不进入此状态,因为它们不改数据库文件"。
- **WRITER_FINISHED**(pager.c:262-278):所有 journal/db 写入与 sync 完成,提交 = "终结 journal 文件"这一个动作。
- **ERROR**(pager.c:280-335):仅三种路径进入——rollback 出错、CommitPhaseTwo 终结 journal 出错、pagerStress 落盘出错(pager.c:309-320);此后所有读写报错,直到引用清零后丢弃缓存回 OPEN 重建。

状态转换的执行函数对照表(pager.c:159-169)值得背下来:`OPEN→READER` 是 `sqlite3PagerSharedLock`,`READER→WRITER_LOCKED` 是 `sqlite3PagerBegin`,`CACHEMOD→DBMOD` 是 `syncJournal`,四条 `WRITER_*→READER` 都是 `pager_end_transaction`。

### 1.3 savepoint 与嵌套事务

savepoint 是 pager 内的数组结构 `PagerSavepoint`(pager.c:431-442),每个 savepoint 记录主 journal 偏移 `iOffset`、journal 头偏移 `iHdrOffset`、页位图 `pInSavepoint`、子 journal 起始记录号 `iSubRec`,以及 WAL 专用的 `aWalData[WAL_SAVEPOINT_NDATA]`。

- 建立时(pagerOpenSavepoint,pager.c:6981-7026)记录当前 `journalOff` 与 `nSubRec`,WAL 下调 `sqlite3WalSavepoint()` 存 4 个 u32:mxFrame、aFrameCksum[2]、nCkpt(wal.c:3822-3828)。
- 回滚时(`sqlite3PagerSavepoint` + `pagerPlaybackSavepoint`,pager.c:3460-3566)分三段回放:先主 journal 中该 savepoint 之后的部分(用 pDone 位图防重复回放),再遍历后续 journal header 段,最后回放子 journal;WAL 下则是 `sqlite3WalSavepointUndo()` 把 mxFrame 拨回(wal.c:3836-3850)。
- 关键区别:savepoint 回滚**不解锁、不终结事务**——"这与 sqlite3PagerRollback() 不同,它不终止事务也不解锁,只把数据库内容恢复原状"(pager.c:7055-7059)。语句级回滚(ON CONFLICT ABORT)正是靠这层在写事务内部实现局部撤销。

---

## ② 回滚日志的事务流程逐段解读

### 2.1 journal 文件格式

格式描述在 pager.c:2819-2839(pager_playback 注释)与 writeJournalHdr 注释(pager.c:1476-1484):

```
journal 头(占满一个 sector,实际 28 字节):
  8B  aJournalMagic(pager.c:757)   4B nRec(0xffffffff=按文件大小推算)
  4B  cksumInit(随机)              4B 初始页数 dbOrigSize
  4B  sector size                  4B page size   … padding 到 sector

记录 = 4B 页号 + pageSize 字节旧页内容 + 4B 校验和(8+pageSize 字节)
```

nRec 写 0xffffffff 的两个安全前提:no-sync 模式(掉电本来就可能坏)或设备有 `SQLITE_IOCAP_SAFE_APPEND`(追加垃圾不可能出现)(pager.c:1518-1539)。校验和是极简方案:`cksumInit + 每 200 字节取 1 字节累加`(pager.c:2289-2297),注释解释了为何够用——掉电最可能破坏记录的一端而非中段(pager.c:2283-2287)。每换一个 sector 写一个新 header(nRec 归零重新计数),这就是 `newHdr` 参数与 `journalHdrOffset()` 的用途。

### 2.2 写路径:从 BEGIN 到第一笔修改

`sqlite3PagerBegin`(pager.c:5984-6048)只做一件事:拿锁。回滚模式调 `pagerLockDb(RESERVED_LOCK)`(pager.c:6018),`exFlag`(BEGIN EXCLUSIVE)时立即 `pager_wait_on_lock(EXCLUSIVE_LOCK)`(pager.c:6020)。真正的 journal 延迟到第一次 `sqlite3PagerWrite()` 才打开:`pager_write` 发现在 `WRITER_LOCKED` 态就调 `pager_open_journal`(pager.c:6136-6139),后者建页位图 pInJournal、打开 journal 文件并写入第一个 header,状态推进到 WRITER_CACHEMOD(pager.c:5951-5961)。

每次改页前,pager 把**旧内容**追加进 journal(含页号与校验和,pager.c:6053-6100),同时把页号登记进 `pInJournal` 位图和所有 savepoint 的位图(`addToSavepointBitvecs`,pager.c:6098)。

### 2.3 提交流程与 fsync 时机(ASCII 图)

```
 BEGIN(拿 RESERVED 锁)              COMMIT
      │                               │
      ▼                               ▼
[WRITER_LOCKED]──首次写页──▶[WRITER_CACHEMOD]
      sqlite3PagerWrite:旧页入 journal
      │                               │
      │   sqlite3PagerCommitPhaseOne (pager.c:6527)
      │     1. pager_incr_changecounter: 改页1的 24..39 字节计数器 (6652)
      │     2. writeSuperJournal: 多库事务写超级日志指针 (6660)
      │     3. syncJournal (6674):                 ── fsync ①
      │          a. sqlite3PagerExclusiveLock: RESERVED→EXCLUSIVE (4349)
      │          b. fullSync 时: 先 fsync(journal) 再写 nRec (4409-4418)
      │          c. 非 SEQUENTIAL 设备: fsync(journal, DATAONLY@FULL) (4421-4428)
      │          d. → 进入 WRITER_DBMOD (4446)
      │     4. pager_write_pagelist: 脏页写数据库文件 (6712)
      │     5. sqlite3PagerSync:                    ── fsync ②
      │          FCNTL_SYNC + fsync(db, syncFlags) (6462-6471)
      ▼
[WRITER_FINISHED]
      │   sqlite3PagerCommitPhaseTwo (6764)
      │   → pager_end_transaction (2090):
      │        DELETE/PERSIST/TRUNCATE 按模式终结 journal (2117-2160)
      │        (PERSIST 清头后还有 fsync ③, pager.c:1450-1452)
      │        db 文件过长则 truncate (2193-2201)
      ▼
[READER]  EXCLUSIVE 降回 SHARED (2209-2214)
```

**fsync 时机与 synchronous 参数**:`syncFlags` 只有 `SYNC_NORMAL(0x02)` 与 `SYNC_FULL(0x03)` 两值(pager.c:609-618)。synchronous=OFF 时 `noSync=1`,syncJournal 与 PagerSync 全部短路——此时不变式里"已 sync"退化为"已写入"(pager.c:32-34 的约定)。FULL 模式比 NORMAL 多出的成本主要在 syncJournal 的 DATAONLY sync 与 journal 头的二次 sync;WAL 模式下 `walSyncFlags` 把两套标志打包:低 2 位给 checkpoint,第 0x04/0x08 位给事务提交,pager.c:613-617 明确 synchronous=NORMAL in WAL 时提交位为 0(即**WAL 提交不 fsync**)。

### 2.4 子 journal(sub-journal)与语句级回滚

当事务内存在 savepoint 时,savepoint 之后**第二次**写的页除了进主 journal 还要进子 journal(条件由 `subjRequiresPage` 判定:该页在事务中已被写过、主 journal 里那份已是旧版)。`subjournalPage`(pager.c:4600-4635)把"当前内容"以"4B 页号 + pageSize"格式追加到子 journal(无校验和,见 pager.c:2305 注释),并登记进各 savepoint 位图(pager.c:4632)。`subjInMemory` 标志(pager.c:539-544)决定子 journal 是内存文件还是临时文件。release savepoint 时只对内存型子 journal 做 truncate 以回收空间(pager.c:7095-7105)。这一层配合 `PGHDR_WRITEABLE` 标志(pager.c:6301-6303:页已写过且有 savepoint 时 `sqlite3PagerWrite` 只需补子 journal 记录)实现了"事务内多次修改同一页,语句回滚只回退到 savepoint 点"的语义。

### 2.5 cache spill(pagerStress)

缓存超限时 pcache 回调 `pagerStress()` 落盘脏页(pager.c:4663-4735)。三个 `doNotSpill` 位控制行为(pager.c:446-449):`SPILLFLAG_OFF`(用户 pragma 禁止)、`SPILLFLAG_ROLLBACK`(savepoint 回放期间绝不能写,否则 journal 边读边写)、`SPILLFLAG_NOSYNC`(同 sector 多页 journal 期间允许写但禁止 sync,pager.c:531-535)。回滚模式下的 spill 代价很高:若 journal 未 sync 过,要触发 `syncJournal(pager.c:4715-4719)`(含 RESERVED→EXCLUSIVE 升级,可能 SQLITE_BUSY),然后把页直接写进数据库文件;WAL 模式下 spill 只是"单页写一个 commit 标志为 0 的帧"(pager.c:4699-4704),非常便宜,且同页重复写会原地覆盖帧并记录 `iReCksum` 延迟重算校验和(wal.c:4147-4167, 3993-3996)。

### 2.6 回滚路径与 pager_unlock

显式 ROLLBACK(`sqlite3PagerRollback`,pager.c:6830-6874)分三种情形:WAL 模式走 savepoint 机制整体回滚(`pagerRollbackWal` 把 dbSize 还原为 dbOrigSize 后经 `sqlite3WalUndo` 逐帧调 xUndo 恢复缓存,pager.c:3201-3222);journal 未打开或还在 WRITER_LOCKED 态,只需 `pager_end_transaction`(6847-6849)——journal_mode=OFF 且已有脏页时会进 ERROR 态报 SQLITE_ABORT(6850-6858);其余直接 `pager_playback`(6861)。回放路径(pager.c:2872-3060)按 journal 头逐段回放,`needPagerReset` 在 hot 回放首段前清空缓存(2974-2977),回放结束统一 `pager_end_transaction` 终结 journal 并尝试删除超级日志(3040-3047)。

`pagerUnlockAndRollback`(pager.c:2240-2268)是关闭连接/出错收尾的兜底:ERROR 态不再回滚(避免在坏缓存上再写盘),直接 `pager_unlock` 丢弃一切、把恢复责任交给下一个发现 hot journal 的连接(2230-2233 注释)。`pager_unlock`(pager.c:1890)同时负责 journalMode=DELETE 时 unlink 残留 journal 与位图释放,并在 EXCLUSIVE 降级失败时把 eLock 置 UNKNOWN_LOCK(pager.c:360-406 的长注释解释了 UNKNOWN_LOCK 如何防止 hot-journal 被误判为"别人正在写")。

### 2.7 崩溃恢复:hot journal 回放

读事务开始于 `sqlite3PagerSharedLock`(pager.c:5316-5523),流程:

1. `pager_wait_on_lock(SHARED_LOCK)`(5334)——这里会调 busy handler;
2. `hasHotJournal`(5196-5287):journal 存在 && 无人持 RESERVED && 首字节非 0(5267)。注释指出了与其它进程删除 journal 的竞态(5217-5224,ticket #3883),宁可误报交给回放例程处理;
3. 若热:**直接拿 EXCLUSIVE 锁**(5370)——注释特意说明不能途经 RESERVED,否则其他进程会误以为可安全读(5355-5364);
4. `pagerSyncHotJournal`:回放前先 sync journal(pager.c:4102-4109),保证回放中途再掉电看到的日志一致;
5. `pager_playback`(2872-3060):逐 header 段读 nRec(nRec=0 时按 #2565 的规则从文件大小推算,2951-2954),先 `xTruncate` 数据库回 mxPg(2960-2964),再逐记录校验回写;只读到第一个坏记录为止(2982-2992);
6. 回放完成后 `pager_end_transaction` 终结 journal,降回 SHARED。

这一段还藏着只读连接的报错分支:`SQLITE_READONLY_ROLLBACK`(5350-5352)——只读连接无法回放 hot journal。

回放之后、进入 READER 之前,pager 还要做**缓存一致性检查**(pager.c:5452-5493):读偏移 24 起的 16 字节(change-counter 加编码/加密时的随机字节),与缓存的 `dbFileVers[]` 比对,不一致则 `pager_reset()` 丢弃整页缓存并 unmap mmap 区域(pager.c:5480-5492)。这就是不变式 (9)/(10)(pager.c:93-99)——"提交必改 24..39 字节、十亿次内不重复"——的消费端:`hasHeldSharedLock` 标志保证首次访问不浪费这次读(pager.c:5454-5458)。

---

## ③ WAL 格式与读写路径逐段解读

### 3.1 WAL 文件格式与校验和链

格式总述在 wal.c:34-98。32 字节头:Magic(0x377f0682,LSB=1 表示大端校验)、版本 3007000、页大小、checkpoint 序号、Salt-1/Salt-2、头校验和(wal.c:491-500 有 WAL_MAGIC 与 walFrameOffset 宏)。帧 = 24 字节帧头 + 一页数据;帧头 6 个 u32:页号、nTruncate(提交帧才有值)、两个 salt、两个校验和(wal.c:46-57, 956-993)。

**校验和链**是 WAL 一致性的核心:每帧的校验和 = 对"WAL 头前 24 字节 + 此前所有帧 + 本帧头前 8 字节 + 本页数据"做链式累计(wal.c:59-68)。算法是两条 Fibonacci 加权累加和 s0/s1(wal.c:70-87)。由此得出帧有效判据(walDecodeFrame,wal.c:1000-1030):salt 必须与当前 WAL 头一致 + 链上校验和必须吻合。**检查点后 Salt-1 自增、Salt-2 随机化**(wal.c:95-98),旧帧(溢出到文件后部的残留)自然失效——这是 WAL 文件可以原地覆盖复用的机制基础。

### 3.2 wal-index(-shm 文件)结构

wal-index 是共享内存,unix 下是 mmap 的 `-shm` 文件(wal.c:127-146)。它是**易失**的:崩溃后可随时从 WAL 重建,VFS 要求最后一个连接关闭时清零其头部(wal.c:139-146),因此允许用宿主机字节序。

头部 136 字节 = 两份 `WalIndexHdr`(互为副本,防止撕裂读)+ 一份 `WalCkptInfo`(wal.c:308-401,布局图 404-466):

```
0..47    WalIndexHdr #1   (iVersion,iChange,isInit,szPage,mxFrame,nPage,
                           aFrameCksum[2],aSalt[2],aCksum[2])
48..95   WalIndexHdr #2   (完全相同的副本)
96..99   nBackfill        (已回填到 db 的帧数)
100..119 aReadMark[5]     (每个读槽的快照位置, 0xffffffff=未用)
120..127 aLock[8]         (8 个锁字节, 位于偏移 120, wal.c:288-292)
128..131 nBackfillAttempted
```

`mxFrame` 是"最后一个有效帧号",`aFrameCksum` 是链尾校验和——读者拿到的就是这两项的快照。哈希索引块(`HASHTABLE_NPAGE=4096` 页/块,首块 4062,槽位 8192 个 u16,wal.c:153-202)把"页号→帧号"查询从全 WAL 扫描降为每块期望 2-3 次探测:哈希函数 `iKey=(P*383)%NSLOT`(wal.c:204-207),线性再探,写侧 `walIndexAppend` 保证表不满半(wal.c:1340-1344)。注意哈希槽存的是**块内 1-based 索引**而非帧号,查询时要加 `sLoc.iZero` 还原(walFindFrame 的 `iFrame = iH + sLoc.iZero`,wal.c:3589-3597)。

### 3.3 读路径:mxFrame 快照 + aReadMark

`sqlite3WalBeginReadTransaction` → `walBeginReadTransaction`(wal.c:3374-3477)→ 循环 `walTryBeginRead`(wal.c:3020-3278)直到非 WAL_RETRY:

1. 读/重建 wal-index 头(walIndexReadHdr;需要时独占 RECOVER 锁跑 `walIndexRecover`,wal.c:1390-1520,逐帧 `walDecodeFrame` 校验重建 mxFrame);
2. **若 `nBackfill == mxFrame`**(WAL 已全部回填):尝试 `WAL_READ_LOCK(0)`,持锁者完全忽略 WAL、直读数据库文件(3134-3167);拿到锁后还要复查 shm 头没变,变了就 RETRY(3145-3161);
3. 否则遍历 5 个 `aReadMark[]`,挑"≤mxFrame 的最大值"槽,加该槽共享锁;若没有现成槽等于 mxFrame,则独占拿某槽、把它的 aReadMark 改写成 mxFrame、降回共享(3190-3205)。

aReadMark 的精妙之处(注释 wal.c:355-383):mark 值只能由**独占**持锁者修改,所以读者持共享锁期间快照不会漂移;checkpoint 只能回填"≤所有在用 aReadMark"的帧;若哈希表里出现晚于快照的新条目,`walFindFrame` 用 `iFrame<=iLast`(快照的 mxFrame)过滤(wal.c:3563-3573)。读帧本身很简单:算偏移 `walFrameOffset(iRead, szPage)+24` 直接读文件(wal.c:3658-3677)。

### 3.4 wal-index 的读取协议与重建

读 wal-index 头采用"先无锁试探,失败再加锁"的两段式(`walIndexReadHdr`,wal.c:2660-2763):先直接 `walIndexTryHdr` 校验双头之一的校验和(两个副本互为备份,谁校验和通过用谁);失败则**独占 WRITE_LOCK 后重试**(2712-2721,`writeLock=2` 是个特殊值,表示"因重建而临时持有的写锁"),仍失败则必然是损坏,直接跑 `walIndexRecover` 重建(2724-2732)。重建(wal.c:1390-1520)在 `WAL_RECOVER_LOCK` + 除写锁外全部字节独占(1406-1407)下进行:校验 WAL 头 magic/页大小/头校验和(1445-1467),版本不符报 SQLITE_CANTOPEN(1471-1475),然后逐帧 `walDecodeFrame` 验证并把**提交帧**(nTruncate!=0)才推进 `hdr.mxFrame`/`nPage`(1515-1519)——这就是"未提交帧崩溃后自动作废"的机制。索引块按 `walIndexAppend` 逐帧登记,页号数组与哈希表先清零再填(1321-1325),发现上一次写者崩溃残留的记录时先 `walCleanupHash` 清理(1327-1336)。

只读 shm 的兜底也在这条路径:连 shm 都无法写入且无法确认有其他可写连接时,置 `bShmUnreliable` 并退化为 `WAL_HEAPMEMORY_MODE`(私有堆内存 wal-index,wal.c:2672-2684),由 `walBeginShmUnreliable` 单独走"读 WAL 文件自建索引"的流程(2792 起)。

### 3.5 写路径

写事务 = `sqlite3WalBeginWriteTransaction`(wal.c:3703-3750):独占 `WAL_WRITE_LOCK`(3783-3732),然后 memcmp 私有 WalIndexHdr 与共享头——**不一致说明读事务开始后别人提交过,返回 `SQLITE_BUSY_SNAPSHOT`**(3739-3741),这就是 WAL 模式下"快照过期无法升级为写"错误码的出处。

帧写入在 `walFrames`(wal.c:4042-4270):

- 若本地 mxFrame==0(本连接看到的是空/重启后的 WAL),写 32 字节 WAL 头并按 `syncHeader` 决定是否 fsync(4092-4128;除非 SEQUENTIAL 设备或 synchronous=OFF);
- 逐脏页 `walWriteOneFrame`;列表最后一页写 nTruncate=提交后页数,即**提交帧**(4171);
- `isCommit && sync_flags!=0` 时:synchronous=FULL 且无 POWERSAFE_OVERWRITE 会把最后一帧重复填充到 sector 边界,先 sync 边界前数据再写溢出部分(`walWriteToLog` 的 iSyncPoint 拆写,4199-4217 与 3942-3962);
- 最后 `walIndexAppend` 把帧登记进 shm 哈希,提交时 `walIndexWriteHdr` 把新 mxFrame 推给所有读者(4238-4265)。**提交点就是这次 shm 头写入,不需要 fsync**——掉电后由 `walIndexRecover` 从 WAL 重放重建 shm,这是 WAL 比回滚日志快的根本原因之一。

WAL 重启(从头覆盖):`walRestartLog`(wal.c:3879-3919)在读者全走 READ_LOCK(0) 且 nBackfill==mxFrame 时,独占全部读槽、`walRestartHdr` 重置 shm 头并换 salt,之后新帧从帧 1 开始覆盖。

### 3.6 checkpoint 三种模式

`sqlite3WalCheckpoint`(wal.c:4305-4436)先独占 `WAL_CKPT_LOCK`(4346,任何 checkpoint 都拿,防并发 checkpoint);PASSIVE 到此为止。FULL/RESTART/TRUNCATE 再用 busy handler 版 `walBusyLock` 独占 `WAL_WRITE_LOCK`(4361-4370),拿不到就**降级为 PASSIVE**并把返回值改成 SQLITE_BUSY(4435)。

核心 `walCheckpoint`(wal.c:2199-2395):

1. 计算 `mxSafeFrame`:从 mxFrame 向下收缩——逐个尝试独占读槽 i,拿到就把 `aReadMark[i]` 置 mxSafeFrame 释放;拿不到(BUSY)说明槽上有活跃读者,`mxSafeFrame = 该读者的 mark` 并停用 busy handler(2233-2251);
2. 独占 `READ_LOCK(0)` 冻结系统(2260),先 `fsync(WAL)`(2277,写屏障,见 wal.c:89-93),然后按 WalIterator(按页号归并排序,每个页只回填**最新**帧)把帧逐页拷进 db 文件(2304-2323)。迭代器由 `walIteratorInit` 以多路归并方式构造(wal.c:1817-1954):对每个哈希块内的帧按页号做归并排序(`walMergesort`,1874 起),再跨块归并,保证整轮回填对每个 db 页只写一次、且写的是最新版本——这使 checkpoint 的写量与"WAL 覆盖了多少不同页"成正比,而非与帧数成正比;
3. 若 `mxSafeFrame == 当前 mxFrame`(全量回填完成):`xTruncate(db)` 收缩 + `fsync(db)`(2328-2335),否则不 truncate;
4. 更新 `nBackfill`(2337)。

三种模式的差异全在收尾(wal.c:2358-2389):

- **PASSIVE**:不阻塞任何人,busy handler 永不调用(4325-4328 有 EVIDENCE-OF 标注);
- **RESTART**:回填后独占 `READ_LOCK(1..4)` 等所有读者退出(2363-2368),迫使下一个写者从头重启 WAL;
- **TRUNCATE**:RESTART + `walRestartHdr(salt1)` + `xTruncate(wal, 0)`(2369-2385)。

自动 checkpoint 由 `sqlite3WalCallback` 返回的帧数触发(pager.c:7603),阈值默认 1000 页(SQLITE_DEFAULT_WAL_AUTOCHECKPOINT)。

---

## ④ 锁五态与 SQLITE_BUSY

### 4.1 POSIX byte-range 锁实现

五态定义在 os.h:98-102:`NO_LOCK=0, SHARED_LOCK=1, RESERVED_LOCK=2, PENDING_LOCK=3, EXCLUSIVE_LOCK=4`。锁落在数据库文件**约定字节偏移**上(os.h:160-166):`PENDING_BYTE = 0x40000000`(1GB 处)、`RESERVED_BYTE = +1`、`SHARED_FIRST = +2`、`SHARED_SIZE = 510`。选 1GB 高处是为了不与真实数据页冲突;改它 = 隐性格式不兼容(os.h:152-156)。

`unixLock`(os_unix.c:1866-2095)的语义(注释 1867-1906 写得极清楚):

- **SHARED**:先 `F_RDLCK` PENDING_BYTE(1975-1991)作为准入闸,再 `F_RDLCK` 整个 SHARED 区(2003-2005),然后释放 pending 字节(2011-2013)→ 多进程可并发持有;
- **RESERVED**:`F_WRLCK` RESERVED_BYTE 单字节(2051-2053)→ 全库任意时刻至多一个 RESERVED;
- **RESERVED→EXCLUSIVE 途中**:先 `F_WRLCK` PENDING_BYTE,成功即停在 PENDING 态(1987-1990)——挡住新的 SHARED 但放过存量读者;拿不到 PENDING 也要一直握着重试;
- **EXCLUSIVE**:`F_WRLCK` 整个 SHARED 区(2054-2057),由于所有其他锁都是该区间的读锁,写锁成功即独占。

注意 unixLock 只升不降,"PENDING 不是显式请求的锁"(assert,os_unix.c:1935);同进程内多线程通过 `unixInodeInfo` 计数协调,EXCLUSIVE 时若本进程还有别的线程持 SHARED 直接返回 BUSY(2030-2033)。

**降级(unixUnlock,os_unix.c:2135-2274)**同样有讲究:EXCLUSIVE→SHARED 时先在整个 SHARED 区**加读锁再解写锁**(2211-2225),普通路径一次完成;NFS 专用 `handleNFSUnlock` 则按 `[WWWWW]→[....W]→[RRRRW]→[RRRR.]` 四步分段降级,避免网络文件系统上读写锁切换的空窗(2157-2208)。随后解锁 PENDING+RESERVED 两个字节(`l_len=2`,2230-2231),最后 NO_LOCK 时只有**本进程最后一个线程**释放才真正调 fcntl 全解锁(2245-2257),并顺带 close 之前因持锁而延迟关闭的描述符(2264-2266)。pager 层的降级点在 `pager_end_transaction` 尾部:`pagerUnlockDb(pPager, SHARED_LOCK)`(pager.c:2209-2214),锁定模式(EXCLUSIVE)下则跳过解锁直接停在 READER 态。

### 4.2 busy handler 的接线

busy handler 注册链:`sqlite3_busy_timeout`/`sqlite3_busy_handler`(main.c:1816-1889)→ `sqlite3PagerSetBusyHandler`(pager.c:3777-3789)→ pager 只在两种锁升级时调用它(pager.c:3766-3772 的表):

```
NO_LOCK → SHARED      调用
SHARED → RESERVED     不调用(立即 BUSY:写者应快速失败,别压着读者排队)
SHARED → EXCLUSIVE    不调用(hot journal 回滚路径)
RESERVED → EXCLUSIVE  调用(pager_wait_on_lock, pager.c:4000-4017)
```

`pager_wait_on_lock` 就是 `do { xLock } while (rc==SQLITE_BUSY && xBusyHandler())`(pager.c:4013-4016)。默认超时 handler `sqliteDefaultBusyCallback` 按 1 秒粒度睡眠(main.c:1780-1789)。

### 4.3 SQLITE_BUSY 的产生点清单

| 来源 | 位置 | 说明 |
|---|---|---|
| POSIX fcntl 返回 EAGAIN/EACCES/ETIMEDOUT/EBUSY/EINTR/ENOLCK | os_unix.c:1024-1038 | 映射为 SQLITE_BUSY,其余映射为 IOERR |
| SHARED→RESERVED 冲突 | pager.c:6018 | 不经 busy handler |
| RESERVED→EXCLUSIVE / hot 回滚抢 EXCLUSIVE | pager.c:4015, 5370 | 经 busy handler |
| WAL 写锁被占 | wal.c:3728 | 不调 handler(上层 btree 会重试) |
| WAL 快照过期 | wal.c:3740 | SQLITE_BUSY_SNAPSHOT;btree 在无事务时降级为普通 BUSY(btree.c:3750-3754) |
| WAL 读启动竞态 | wal.c:3112-3114 | SQLITE_BUSY_RECOVERY(recovery 进行中) |
| walTryBeginRead 重试 100 次 | wal.c:3042-3055 | 返回 SQLITE_PROTOCOL(锁协议故障,总等待 <10s) |
| checkpoint 抢 CKPT/WRITE 锁、读槽 | wal.c:4346-4348, 2244, 2362 | PASSIVE 不调 handler;FULL 失败降级 PASSIVE 并返回 BUSY(4435) |
| pagerStress/写库升级 EXCLUSIVE 失败 | pager.c:4461 注释, 6495 | 返回 BUSY 且不落任何页 |

一个常被忽略的细节:WAL 模式下 `walTryBeginRead` 的重试内部自带指数退避(第 5 次起 sleep,第 100 次放弃),它不经过用户 busy handler(3134 之前的 3042-3077)。

---

## ⑤ 设计动机与取舍:何时选 WAL,何时选 rollback

**rollback journal 的本质是"把随机写变成undo 保护的随机写"**:先 sync 旧页(保证可撤销),再原地覆盖 db 文件,提交时 fsync db、删日志。代价是(1)每页写两次级别的工作量+多次 fsync;(2)写事务全程持 EXCLUSIVE,读写彻底互斥;(3)读事务期间的缓存一致性靠 change-counter 检测失效重置(pager.c:5452-5493,不变式 (9):提交必改 24..39 字节,pager.c:93-99)。收益是**单文件自包含**:崩溃后任何进程都能凭 -journal 恢复,不需要共享内存,因此可用在网络文件系统、只读介质和嵌入式平台,`noLock`/`memVfs` 等退化场景也只走这条路。

**WAL 的本质是"把随机写变成追加写 + 一个共享内存提交点"**:提交只 = append 帧 + (可选)fsync WAL + 更新 shm 头;读不加数据库文件锁(只锁 shm 的读槽),读者与写者完全并发;checkpoint 把回填压力转移到后台。代价是:(1)依赖 mmap 共享内存 → 不支持网络文件系统(wal.c:130-133);(2)-shm 与 -wal 两个伴生文件及进程间的锁协议复杂度(8 个锁字节 + aReadMark 协议);(3)checkpoint 需要独占 WRITE 锁,长读事务会推迟 checkpoint 使 WAL 无限增长(`wal_checkpoint` PRAGMA 与 busy handler 的意义所在);(4)所有进程必须同一宿主机。

**从源码直接推出的单次提交 IO 对比**(假设提交修改 N 个不同页,FULL 持久级):

| 维度 | rollback journal | WAL |
|---|---|---|
| fsync 次数(FULL) | journal 头 sync + journal DATAONLY sync + db sync + journal 终结 sync ≈ 4 次 | WAL 头 sync(仅首个事务)+ 提交帧 sync = 1 次;checkpoint 另计 |
| 写放大 | 每页写 2 次(journal 旧页 + db 新页) | 每页写 2 帧(提交帧 + checkpoint 回填),另有帧头 24B/页开销 |
| 提交关键路径 | journal sync → N 页覆盖写 → db fsync → 删文件 | append N 帧 → fsync WAL → 写 shm 头(内存) |
| 并发 | 读写互斥(不变式 12/13) | 读写并发,单写者(WAL_WRITE_LOCK) |
| 崩溃恢复单位 | 整库级:hot journal 回放,恢复期间全库阻塞于 EXCLUSIVE | 精确到帧:walIndexRecover 只重放 WAL 头部指针 |

**工程经验法则**(从代码约束直接推出):

- 多读少写、要求读写并发、单机多进程 → WAL + synchronous=NORMAL(提交不 fsync,持久性由 checkpoint 的 fsync 保证,掉电最多丢最近若干提交但不损坏);
- 强持久性单写场景、只读介质/无共享内存环境、数据库要拷单文件 → rollback journal;
- `journal_mode=TRUNCATE/PERSIST` 是"删文件太贵"的折中,SSD + 小 journal 场景常优于 DELETE;
- 写多读少且事务巨大时,rollback 的"一次覆盖 + journal 一次性 sync"可能反而比 WAL 的帧放大 + checkpoint 二次写更省 IO——这也是大批量导入文档建议先关 WAL 的原因(源码层面对应:WAL 每页都要写帧头 24 字节且 checkpoint 再写一遍 db)。

---

## ⑥ FAQ

**Q1:journal_mode=DELETE 下 COMMIT 时掉了电,数据会不会半新半旧?**
不会越过事务边界。COMMIT 的次序是:journal sync → db 写+sync → 删 journal(pager.c:6527-6746)。掉电后若 journal 还在,任何连接下次 `sqlite3PagerSharedLock` 会检测到 hot journal 并回放(hasHotJournal:存在 + 无 RESERVED 锁 + 首字节非 0,pager.c:5254-5267);若 journal 已删,说明 db 已完整落盘。半新半旧只会出现在 synchronous=OFF 的"合法损坏"里。

**Q2:synchronous=NORMAL 和 FULL 在两种模式下的差别到底是什么?**
回滚模式:NORMAL 只在提交点 fsync 一次 db(syncJournal 里 journal 的 sync 仍要,但 FULL 额外做 DATAONLY 与 nRec 前置 sync,pager.c:4409-4428);WAL 模式:NORMAL 连提交都不 fsync WAL(walSyncFlags 提交位为 0,pager.c:613-617),FULL 才在每个提交 fsync。所以"WAL+NORMAL 不丢已确认事务"的说法要限定为"不丢进程崩溃,只防 OS 崩溃后最近提交丢失",掉电可能丢最近的 COMMIT 返回。

**Q3:为什么 RESERVED 锁能被多个连接"看到"却只有一个能持有?它有什么用?**
`xCheckReservedLock` 可查询(pager.c:387-393)。它的作用是给"我要写"一个占位声明:hot journal 检测靠它区分"崩溃残留"(无人持 RESERVED→需要回放)和"正在进行的写"(有人持→journal 会正常终结,别动)(pager.c:5214-5226);模式切换删旧 journal 前也要先拿 RESERVED 防误删(pager.c:7477-7493)。

**Q4:PENDING 锁为什么不允许显式请求?**
它是 RESERVED→EXCLUSIVE 升级失败时的"搁浅状态":挡新 SHARED、放旧 SHARED(os_unix.c:1898-1906)。若让 EXCLUSIVE 直接请求,fcntl 写锁会与存量读锁死锁式互斥;先拿 PENDING 让读者自然排空。assert 在 os_unix.c:1935。

**Q5:WAL 模式下读事务为什么不会阻塞 checkpoint,checkpoint 又为什么不破坏读者快照?**
读者锁的是 shm 里自己的 `READ_LOCK(i)` 槽;checkpoint 只把 `mxSafeFrame` 收缩到所有在用 aReadMark 的最小值(wal.c:2233-2251),超过它的帧一个都不回填。回填期间独占 READ_LOCK(0) 再加 fsync WAL 做写屏障(wal.c:2260-2277),保证"读到的 db 页要么是旧的、要么是完整回填后的"。

**Q6:为什么 WAL 文件能无限增长?writer 什么时候从头覆盖?**
只有两个条件同时满足:`nBackfill == mxFrame`(全部回填)且没有任何读者持 READ_LOCK(i>0)(注释 wal.c:384-389)。此时 writer 在 `walRestartLog` 里换 salt 重置 shm 头(wal.c:3879-3919);TRUNCATE checkpoint 会顺手把文件截为 0(wal.c:2384)。长读事务是 WAL 膨胀的第一元凶。

**Q7:SQLITE_BUSY_SNAPSHOT 是什么?为什么升级写会失败?**
WAL 写事务开始时 memcmp 私有 WalIndexHdr 与共享头(wal.c:3739-3741):读快照建立后若有他人提交(mxFrame 变了),继续写会让同一 WAL 出现分叉。它**不能**靠 busy handler 重试解决——必须结束读事务重新开始;btree 在外层事务刚开始(TRANS_NONE)时把它降级成普通 BUSY(btree.c:3750-3754)以便兼容。

**Q8:savepoint 在 WAL 和 rollback 模式下实现有何不同?**
rollback 模式靠"主 journal 偏移 + 子 journal 记录号 + 页位图"三重书签,回放时逐页反向覆盖(pager.c:3460-3566);WAL 模式只存 4 个 u32(mxFrame、链尾校验和、nCkpt,wal.c:3822-3828),回滚=把写指针拨回去 + `walCleanupHash` 清哈希表(wal.c:3808)。WAL 的 savepoint 几乎零成本,这就是嵌套事务/触发器在 WAL 下更快的直接原因。

**Q9:mmap(iov)与事务安全有什么关系?dbFileVers 是干嘛的?**
共享锁重新获取时 pager 读偏移 24 的 16 字节(change-counter+版本号)与缓存值比对,不同则整缓存作废并 unmap(pager.c:5452-5493)——防止外部进程修改数据库后本进程用陈旧 mmap。不变式 (9)/(10) 保证该区域每事务必变且十亿次内不重复(pager.c:93-99)。

**Q10:journal header 的 nRec 为什么先写 0 再回填?**
0xFFFFFFFF(按文件大小推算)的前提是"文件尾部垃圾不可能被当成记录"。普通文件系统 append 掉电可能留垃圾,所以必须先写记录、sync,再回头把 nRec 写进头(pager.c:4398-4419);SAFE_APPEND 设备可省略这一往返(pager.c:1532-1536)。这是 FULL/NORMAL 与优化设备间的主要 sync 差异点。

**Q11:checkpoint(PASSIVE)中途来了新提交会怎样?**
`mxSafeFrame` 已在开始时固定,回填循环里 `iFrame>mxSafeFrame` 的帧直接跳过(wal.c:2312-2314);新提交把 mxFrame 推大不影响本次。若结束时 `mxSafeFrame == live mxFrame` 恰好成立才做 db truncate;否则不 truncate、nBackfill 停在 mxSafeFrame,剩下的留给下次。

**Q12:为什么 pager 出错后要进入 ERROR 态而不是直接回滚?**
回放本身也可能失败,此时缓存内容与磁盘已无法对应;继续让读者读会报假"corruption",升级写则可能写坏文件。ERROR 态冻结一切操作,引用清零后走 `pager_unlock` 丢弃缓存、回到 OPEN,下次读事务重新从磁盘(必要时含 hot journal 回放)构建(pager.c:280-330)。

---

## ⑦ 深挖问题(供后续章节/实验)

1. **wal-index 撕裂读与双头协议的证明**:两份 WalIndexHdr 靠 `walIndexTryHdr` 校验和轮换使用(walIndexReadHdr),但 32 位读的原子性假设仅注释保证(wal.c:391-393)。在 64 位读不原子的 32 位平台上,`aReadMark[]` 的 AtomicLoad 序列是否存在可观察的中间态?可结合 `SQLITE_ENABLE_SEH` 分支(wal.c:2437-2468)研究 shm 失效页异常后的锁清理正确性。

2. **POWERSAFE_OVERWRITE 与 sector 假设的演进**:setSectorSize 在有 PSOW 时强制 sectorSize=512(pager.c:2790-2809),walFrames 的 pad-to-sector 同样受其影响(wal.c:4192-4197)。现代 NVMe(FUA、atomic write 128B+)下,`SQLITE_IOCAP_BATCH_ATOMIC` 路径(pager.c:6679-6708)能否彻底取消 journal?实测 F2FS/ext4 的 xMap 区域行为值得写对比实验。

3. **hot journal 检测的 TOCTOU 窗口**:hasHotJournal 承认的竞态(ticket #3883,pager.c:5217-5226)依赖"误报无害",但 pagerOpenWalIfPresent 里"非空 db + 残留 -wal 文件"的判定(pager.c:3400-3417)与删除该文件的 EXCLUSIVE 锁配合是否存在类似窗口?可用多进程故障注入验证。

4. **checkpoint 与长读者的饥饿**:mxSafeFrame 只能收缩不能前进的规则意味着一个永不结束的读者会同时阻止 FULL/TRUNCATE checkpoint 与 WAL 重启。`sqlite3WalSnapshotCheck/Unlock`(wal.c:4601-4633)为快照 API 增加的阻塞点,是否可以作为实现"读者租约超时"的切入点?

5. **BUSY 协议的退化路径**:WAL 读启动失败 100 次 → SQLITE_PROTOCOL(wal.c:3042-3057),而 pager 的 RESERVED→EXCLUSIVE 重试则完全交给用户 handler。两个等待模型(自旋+退避 vs 用户回调)在同进程混用时,是否会出现"shm 自旋耗尽、handler 还没睡着"的优先级倒置?`SQLITE_ENABLE_SETLK_TIMEOUT` 的阻塞锁(wal.c:3058-3074)能否统一两者,值得在 Linux OFD 锁上实验。

---

### 附:关键函数速查

| 功能 | 函数 | 位置 |
|---|---|---|
| 读事务入口/热日志回放 | sqlite3PagerSharedLock / hasHotJournal / pager_playback | pager.c:5316 / 5196 / 2872 |
| 写事务入口 | sqlite3PagerBegin / pager_open_journal | pager.c:5984 / 5893 |
| 提交 | sqlite3PagerCommitPhaseOne / PhaseTwo / pager_end_transaction | pager.c:6527 / 6764 / 2090 |
| journal sync | syncJournal | pager.c:4340 |
| 缓存落盘 | pagerStress | pager.c:4663 |
| WAL 读写 | sqlite3WalBeginReadTransaction / walTryBeginRead / walFindFrame | wal.c:3493 / 3020 / 3525 |
| WAL 写与提交 | sqlite3WalBeginWriteTransaction / walFrames | wal.c:3703 / 4042 |
| checkpoint | sqlite3WalCheckpoint / walCheckpoint | wal.c:4305 / 2199 |
| POSIX 锁 | unixLock / unixUnlock / sqliteErrorFromPosixError | os_unix.c:1866 / 2284 / 1024 |
