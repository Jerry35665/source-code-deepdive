# E · PostgreSQL 三层锁体系:spinlock / LWLock / heavyweight lock

> 源码版本:postgres master,commit `8c7a74c`(浅克隆)。所有行号均以该 commit 实测核对(grep -n / Read)。
> 涉及目录:`src/backend/storage/lmgr/`(s_lock.c、lwlock.c、lock.c、deadlock.c、proc.c、predicate.c)与 `src/include/storage/`。

lmgr/ 目录清单(13 个文件):`condition_variable.c`、`deadlock.c`、`lmgr.c`(面向上层的关系/元组锁 API)、`lock.c`(heavyweight 锁)、`lwlock.c`、`predicate.c`(谓词锁)、`proc.c`(等待队列与信号量)、`s_lock.c`(自旋锁)、`generate-lwlocknames.pl` + Makefile/meson.build,另有 README、README-SSI、README.barrier。

---

## 1. 全景:三层锁金字塔

官方自述见 `src/backend/storage/lmgr/README:8-37`:进程间锁共四类——自旋锁(8 行)、LWLock(20 行)、常规锁/重锁(32 行)、SIReadLock 谓词锁(37 行)。前三层构成金字塔:

```
                ▲  数据库语义层:表/行/事务/咨询锁
                │  8 种锁模式 × 冲突矩阵 × 等待队列 × 死锁检测
   ┌────────────────────────────────────────────┐
   │  heavyweight lock (lock.c, ~4900 行)        │  等待策略:信号量/latch 睡眠
   │  LOCK/PROCLOCK 哈希表(16 分区)             │  + deadlock_timeout 超时后 DFS 找环,
   │  对象可枚举、用户可见(pg_locks)、事务结束自动释放│  发现死锁→杀事务报错
   ├────────────────────────────────────────────┤
   │  LWLock (lwlock.c, ~1900 行)                 │  等待策略:无冲突时 CAS 原子直取;
   │  保护共享内存数据结构:state 原子字 + waiter 链 │  有冲突时挂到锁的 waiter 链上,
   │  共享/独占两模式,不出错时无死锁问题           │  阻塞在每后端一个的信号量上,由释放者唤醒
   ├────────────────────────────────────────────┤
   │  spinlock (s_lock.c, 300 行)                 │  等待策略:纯 CPU 自旋 + 指数退避
   │  指令级,TAS 一条原子指令;只保护"几十条指令"   │  pg_usleep 1ms→1s;NUM_DELAYS 次后
   │  的临界区;是 LWLock 内部的"锁中锁"           │  判定 stuck → PANIC(整机重启)
   └────────────────────────────────────────────┘
        持有时间:纳秒级 ──→ 微秒/毫秒级 ──→ 不定(用户事务时长)
```

分层的本质是**持有时间谱系**。README:8-10 明确告诫:临界区超过几十条指令、或含内核调用,就不得用自旋锁;README:33-36 指出 LWLock 等待可能超过几秒的场景不该用 LWLock,应上移到重锁。三层各自把"等待开销"与"持锁时长"匹配:

- 自旋锁:忙等 + 随机指数退避(`s_lock.c:104-107` 主循环、`s_lock.c:125-166` 退避),超限 `s_lock_stuck` 报 PANIC(`s_lock.c:134-135`、`s_lock.c:89-91`)。
- LWLock:CAS 直取失败后睡在 `PGPROC->sem`(`lwlock.c:1267-1273` PGSemaphoreLock;`lwlock.c:1006-1008` 唤醒时 PGSemaphoreUnlock)。每个后端恰一个信号量(`proc.c:129-136`)。
- 重锁:等在 latch 上(`proc.c:1518-1519` WaitLatch),持 `deadlock_timeout` 后醒来做死锁检测;锁对象进 `pg_locks` 视图,事务结束由 ResourceOwner 自动释放。

第四类谓词锁(`predicate.c`,4993 行)一句话:为可串行化隔离(SSI)服务的 SIREAD 锁,跟踪"读先于写"的 rw-冲突,只做标记从不阻塞,粒度可在元组/页/关系间合并收缩(`predicate.c:1-60` 头注释)。

---

## 2. spinlock 专节:TAS 平台抽象与"为什么不用 pthread"

### 2.1 宏层级(s_lock.h 的抽象栈)

`src/include/storage/s_lock.h` 定义了清晰的两级抽象:上层 API 是 `S_LOCK/S_UNLOCK/S_INIT_LOCK/SPIN_DELAY`(s_lock.h:12-25),其下再拆出 `TAS`/`TAS_SPIN` 两条底层原语(s_lock.h:31-47,并注明二者"不是 API,禁止直接调用",s_lock.h:46-47)。默认组合:s_lock.h:665-668 —— `S_LOCK` 先试一次 `TAS`,失败才进入平台无关的 `s_lock()` 自旋循环;`TAS_SPIN` 缺省等同 `TAS`(s_lock.h:707-709)。

平台实现一览(全部在 s_lock.h 内,以 `#if defined(__cpu__)` 分层):

| 平台 | 原语 | 行号 |
|---|---|---|
| i386 | `lock xchgb`,先 cmpb 非锁定预检 | s_lock.h:133-159 |
| x86_64 | `lock xchgb`;`TAS_SPIN` 先普通读再 TAS | s_lock.h:212, 214-226 |
| ARM/ARM64 | `__sync_lock_test_and_set`;ARM64 用 ISB 作 SPIN_DELAY | s_lock.h:250-290 |
| S/390 | `cs`(compare-and-swap) | s_lock.h:294-314 |
| SPARC | `ldstub` + membar 屏障按 v7/v8/v8+ 分档 | s_lock.h:317-390 |
| PowerPC | `lwarx/stwcx.` LL/SC 环 + lwsync | s_lock.h:394-452 |
| MIPS | `ll/sc` + sync | s_lock.h:455-523 |
| 兜底 | gcc `__sync` 内建(int 优先于 char) | s_lock.h:534-568 |
| MSVC | `InterlockedCompareExchange` + `_mm_pause` | s_lock.h:597-649 |

x86_64 的 `TAS_SPIN` 是经典的"先无锁读"优化:`#define TAS_SPIN(lock) (*(lock) ? 1 : TAS(lock))`(s_lock.h:212),注释引 Intel 论文说明只在自旋路径使用(s_lock.h:203-211)。`SPIN_DELAY` 在 x86 上是 `rep; nop`(即 PAUSE 指令,s_lock.h:189-191,其注释 166-188 大段引用 IA-32 手册解释流水线冲刷问题)。没有 TAS 的平台直接 `#error`(s_lock.h:655-658)。

### 2.2 锁自由退避与自适应 spins_per_delay

`SpinDelayStatus` 记录一次自旋等待的状态(s_lock.h:727-735:spins/delays/cur_delay/file/line/func)。退避参数见 `s_lock.c:57-61`:每 `spins_per_delay` 次尝试后睡眠一次,延迟 1ms 起随机增长到 1s 再归零(`s_lock.c:157-162`,增长因子 `1X+U(0,1)`);累计 `NUM_DELAYS=1000` 次即判 stuck(s_lock.c:134-135)。文件头注释(s_lock.c:21-31)解释了随机退避的必要性:若固定 1ms,被 nice 降权的持锁者可能永远抢不到调度,造成饿死。

更妙的是**自适应**:抢到锁后按"是否睡过"调整进程本地的 `spins_per_delay`(s_lock.c:185-199:没睡过 +100,睡过 -1),后端退出时用 15/16 指数滑动平均汇入共享估计值(s_lock.c:217-231)。单核机器收敛到最小值 10,多核收敛到最大值 1000(s_lock.c:10-13、168-177 注释)。

### 2.3 为什么自研而不用 pthread/OS 互斥量

- **进程模型**:PG 是每连接一个 fork 出的进程而非线程,后端间只能靠共享内存+信号量通信;pthread 互斥量的"线程"语义不适配跨进程场景。等待原语因此选了 SysV/POSIX 信号量,每后端一个(`proc.c:129-136`)。
- **临界区契约**:spin.h:24-27 规定"自旋锁内不得超过几条指令、不可能发生 CHECK_FOR_INTERRUPTS",这是 pthread 锁不提供的强约定;破坏它就是 stuck PANIC。
- **内存序责任内置**:s_lock.h:54-63 明确要求 TAS/S_UNLOCK 宏自己阻止编译器重排(9.5 之前靠调用者加 volatile,被评价为"记着难、容易错、妨碍优化");弱内存序平台还要硬件栅栏(s_lock.h:65-71)。SPARC 的 S_UNLOCK 按 v7/v8/v8+ 三档插 stbar/membar(s_lock.h:363-388)就是典型。
- **可观测与可诊断**:`s_lock()` 带 file/line/func(s_lock.h:715),stuck 时 PANIC 打印精确位置(s_lock.c:89-91);等待事件 `WAIT_EVENT_SPIN_DELAY` 上报让睡眠在 pg_stat_activity 里可见(s_lock.c:148)。
- 诚实地讲,s_lock.h:73-75 也承认"等价的 OS 互斥例程亦可使用"——不用的根本理由是控制力:退避策略、自适应、错误定位、与信号/LWLock/错误恢复路径的深度耦合,都需要自己握住这 300 行。

---

## 3. LWLock 专节:一个原子字上的状态机

### 3.1 结构与 state 位布局

```c
typedef struct LWLock
{
    uint16          tranche;    /* tranche ID */
    pg_atomic_uint32 state;     /* state of exclusive/nonexclusive lockers */
    proclist_head   waiters;    /* list of waiting PGPROCs */
} LWLock;                       /* src/include/storage/lwlock.h:41-50 */
```

state 是一个 32 位原子字承担全部信息(lwlock.c:96-108):最高 3 位是标志——bit31 `LW_FLAG_HAS_WAITERS`、bit30 `LW_FLAG_WAKE_IN_PROGRESS`、bit29 `LW_FLAG_LOCKED`(waiter 链自身的互斥位);低 18 位当共享持有者计数(`LW_SHARED_MASK = MAX_BACKENDS`),独占则置哨兵 `LW_VAL_EXCLUSIVE = MAX_BACKENDS + 1`。`MAX_BACKENDS = 2^18 - 1`(`src/include/storage/procnumber.h:38-39`),三组静态断言保证位域互不重叠(lwlock.c:111-118)。三种模式定义于 lwlock.h:102-109:`LW_EXCLUSIVE / LW_SHARED / LW_WAIT_UNTIL_FREE`(第三种只用于 PGPROC->lwWaitMode,不作 Acquire 参数)。等待进程的三态机 `LW_WS_NOT_WAITING/WAITING/PENDING_WAKEUP` 见 lwlock.h:28-34。

每个 LWLock 按缓存行对齐填充(`LWLOCK_PADDED_SIZE = PG_CACHE_LINE_SIZE`,lwlock.h:62-72),避免伪共享。头文件注释(lwlock.h:52-61)明说主数组中热点锁"宁可整行独占"。

### 3.2 acquire 的 CAS 状态机(两阶段协议)

核心尝试函数 `LWLockAttemptLock`(lwlock.c:763-824):读一次 state,循环做 `pg_atomic_compare_exchange_u32`(lwlock.c:807-808)——独占模式仅当 `(state & LW_LOCK_MASK)==0` 才加哨兵,共享模式仅当无独占才 `+LW_VAL_SHARED`;CAS 总是回写原值,一举兼作内存栅栏(注释 lwlock.c:797-806)。

但 CAS 只解决"拿",不解决"等"。头注释(lwlock.c:60-75)指出了朴素方案的竞态:排队期间持锁者可能早已释放,导致白睡一场。解法是**两阶段(先排队再重试)**:

```c
mustwait = LWLockAttemptLock(lock, mode);   /* Phase 1: 直接 CAS */
...
LWLockQueueSelf(lock, mode);                /* Phase 2: 挂入 waiter 链 */
mustwait = LWLockAttemptLock(lock, mode);   /* Phase 3: 再 CAS 一次 */
if (!mustwait) { LWLockDequeueSelf(lock); break; }
...                                          /* Phase 4: PGSemaphoreLock 睡眠,醒来回到 Phase 1 */
```
(对应 `LWLockAcquire` lwlock.c:1215/1235/1238/1245 与 1267-1273;协议描述 lwlock.c:66-75)

入队 `LWLockQueueSelf`(lwlock.c:1017-1051)要先拿 wait 链互斥:`LWLockWaitListLock` 用 `pg_atomic_fetch_or_u32(state, LW_FLAG_LOCKED)` 一发 CAS 直接试(lwlock.c:852-854),失败才落到带退避的自旋(lwlock.c:856-871)——注释特意说明"先裸试一次"是为避免配置 SpinDelayStatus 的 profiling 开销(lwlock.c:846-851)。共享/普通等待者排尾,`LW_WAIT_UNTIL_FREE` 者插队头(lwlock.c:1039-1043)。

**唤醒协议**在 `LWLockWakeup`(lwlock.c:903-1010):持链锁遍历 FIFO,连续唤醒所有共享等待者,一旦唤醒过独占者就停止(lwlock.c:920-921、954-955);被唤醒者先标 `LW_WS_PENDING_WAKEUP` 防止重入竞态(lwlock.c:946-948);随后一次 CAS 把 WAKE_IN_PROGRESS/HAS_WAITERS/Locked 三个标志一并收拾(lwlock.c:961-986);最后设 `pg_write_barrier()` 后置 `LW_WS_NOT_WAITING` 并 `PGSemaphoreUnlock`(lwlock.c:1006-1008)——屏障配对注释解释了链表损坏风险(lwlock.c:996-1005)。释放方 `LWLockRelease`(lwlock.c:1766-1834)用 `sub_fetch` 原子减计数(lwlock.c:1797-1800),仅在"仍有等待者+无唤醒进行中+锁位已清零"时才付出拿链锁的代价调 LWLockWakeup(lwlock.c:1812-1827)。

说明:任务书中提到的 `LWLockUpdateWaiters` 在本 commit 并不存在;相近角色由静态 `LWLockWakeup`(唤醒等待者)与 `LWLockUpdateVar`(lwlock.c:1701-1756,持锁者原子更新 64 位变量并唤醒 `LW_WAIT_UNTIL_FREE` 等待者,WALInsertLock 等使用)承担。同族变体还有 `LWLockAcquireOrWait`(lwlock.c:1377-1493,"拿到或等到释放即返回",注释点名 WALWriteLock 场景,lwlock.c:1364-1376)。

### 3.3 tranche 注册表:又一次表驱动

tranche = 一组同源 LWLock 的"命名分片",ID 存在锁结构第一个字段里。注释(lwlock.c:120-136)把 tranches 分三类:

1. **个体命名锁**:`src/include/storage/lwlocklist.h:36-91` 用 `PG_LWLOCK(id, name)` 罗列 OidGen/XidGen/ProcArray/WALWrite 等 50 余把内置单锁(0/1/10/11…等号位注释保留历史,如 "0 is available; was formerly BufFreelistLock",lwlocklist.h:34)。
2. **内置分组 tranche**:lwlocklist.h:101-142 的 `PG_LWLOCKTRANCHE(XACT_BUFFER, XactBuffer)` 等 40 余组(BufferMapping 128 把、LockManager 16 把等)。
3. **扩展 tranche**:共享内存注册表 `LWLockTrancheShmemData`(lwlock.c:175-193,含 256 上限与自旋锁保护),`LWLockNewTrancheId`(lwlock.c:561-605)/`RequestNamedLWLockTranche`(lwlock.c:619-664)登记,`GetLWTrancheName` 查名(lwlock.c:708-741,常用路径免锁读本地计数)。

名字表本身就是**表驱动**:`BuiltinTrancheNames[]` 用 X-macro 从 lwlocklist.h 生成(lwlock.c:137-147),静态断言查漏。任务书提到的 `lwlocknames.txt` 在本 commit 已不存在——名单迁入 `lwlocklist.h`,由 `generate-lwlocknames.pl:3` 生成 `lwlocknames.h`(供 DTrace 等),并与 wait_event_names.txt 交叉校验(generate-lwlocknames.pl:31、113-121)。tranche 名即 pg_stat_activity 的等待事件名(`GetLWLockIdentifier`,lwlock.c:746-752)。

### 3.4 一次历史教训

lwlock.c:29-45 的 NOTES 记载:旧实现是"自旋锁保护的读写锁",共享模式太热时开销不可接受("常常在自旋锁里自旋,而想拿的共享锁其实是空闲的"),于是 9.x 重构为上述无锁共享获取。这是"为什么 LWLock 不用自旋锁"的第一手答案(详见 §7)。

---

## 4. heavyweight 专节:LOCK/PROCLOCK、冲突矩阵与 fast path

### 4.1 数据结构

```c
typedef struct LOCK {
    LOCKTAG      tag;         /* 哈希键:锁定对象标识 */
    LOCKMASK     grantMask;   /* 已授予模式位图 */
    LOCKMASK     waitMask;    /* 等待中模式位图 */
    dlist_head   procLocks;   /* 关联 PROCLOCK 链 */
    dclist_head  waitProcs;   /* 等待队列(FIFO+优先,见下) */
    int requested[MAX_LOCKMODES]; int nRequested;
    int granted  [MAX_LOCKMODES]; int nGranted;
} LOCK;                          /* src/include/storage/lock.h:139-153 */
```

每"对象×持有者"一条 `PROCLOCK`(lock.h:193-211,tag 为 LOCK* + PGPROC* 指针对);每后端本地再有一份 `LOCALLOCK` 记重复加锁计数与 ResourceOwner 归属(lock.h:257-272,fastpath 拿到的锁 lock/proclock 指针为 NULL,lock.h:225-231)。对象类型由 `LOCKTAG` 区分:关系/元组/事务/虚拟事务/对象/咨询锁等(locktag.h:37-47)。

### 4.2 八种锁模式与冲突矩阵

模式定义 `lockdefs.h:36-48`;冲突表是一张**常量表** `LockConflicts[]`(lock.c:68-108),与模式名数组、`LockMethodData`(lock.h:111-119)一起构成表驱动语义,DEFAULT/USER 两种锁方法共用(lock.c:128-157)。矩阵(bit=1 冲突):

| 请求模式 \ 已持模式 | 1 AS | 2 RS | 3 RX | 4 SUE | 5 S | 6 SRE | 7 E | 8 AE | 行号 |
|---|---|---|---|---|---|---|---|---|---|
| 1 AccessShare(SELECT) | · | · | · | · | · | · | · | ✕ | lock.c:71-72 |
| 2 RowShare(FOR UPDATE) | · | · | · | · | · | · | ✕ | ✕ | lock.c:74-75 |
| 3 RowExclusive(DML) | · | · | · | · | ✕ | ✕ | ✕ | ✕ | lock.c:77-79 |
| 4 ShareUpdateExclusive(VACUUM) | · | · | · | ✕ | ✕ | ✕ | ✕ | ✕ | lock.c:81-84 |
| 5 Share(CREATE INDEX) | · | · | ✕ | ✕ | · | ✕ | ✕ | ✕ | lock.c:86-89 |
| 6 ShareRowExclusive | · | · | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | lock.c:91-94 |
| 7 Exclusive | · | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | lock.c:96-100 |
| 8 AccessExclusive(ALTER/DROP) | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | lock.c:102-106 |

注意自冲突:模式 4 与模式 7 各与自己冲突(对角线上 4、7 为 ✕)。

### 4.3 锁表与分区

锁表 = 共享内存哈希:LOCK 哈希按 max_locks_per_transaction×(MaxBackends+max_prepared_xacts) 预留(`NLOCKENTS`,lock.c:59-60;`LockManagerShmemRequest` lock.c:444-485),PROCLOCK 按"平均每锁 2 持有者"翻倍(lock.c:467-478)。两张表共用**16 个分区 LWLock**(NUM_LOCK_PARTITIONS=16,lwlock.h:86-87;分区锁宏 lock.h:355-361),由 `LockTagHashCode` 的高位决定归属,进入 `LockAcquireExtended` 后先拿分区锁再动表(lock.c:1100-1102)。

### 4.4 grant 策略:公平 + 插队 + 早死锁

`LockAcquireExtended`(lock.c:860-1316)的授予顺序:(a) 本地已有→仅计数(lock.c:975-982);(b) fastpath(见 4.5);(c) `waitMask` 预检——若请求模式与**队列中等待者的请求**冲突,直接排队(lock.c:1140-1141,防插队饿死);(d) `LockCheckConflicts` 对照已授予集合(lock.c:1143,实现 1573-1688:先查 grantMask,再扣除自己/锁组持有的,lock.c:1595-1625);无冲突即 `GrantLock`(lock.c:1149,实现 1701-1713:granted/grantMask/holdMask 三处落账)。

等待队列是"FIFO + 优先插队":`JoinWaitQueue`(proc.c:1202-1356)发现"我已持的锁与队首某等待者冲突"时,把自己插到它前面(proc.c:1314-1316,注释 1253-1269 说明"死锁检测反正会把我移过去,不如现在就做");插队过程中若发现互绕死锁,当场 `RememberSimpleDeadLock` 报早死锁(proc.c:1300-1302、1327-1328);若插队点之前再无障碍,甚至直接自授(proc.c:1305-1312)。释放侧的 `ProcLockWakeup`(proc.c:1833-1870)按队列序扫描,被唤醒者须"不与更早的不可唤醒者的请求冲突"(aheadRequests,proc.c:1852-1867)——README:383-391 总结为规则 (b) 保证同模式按到达序授予,这正是公平性来源。授予采用"唤醒后自旋重试"而非"授予者直接移交",理由见 ProcSleep 旧注释(lwlock.c 同思路:进程切换代价高于偶发空醒)。

### 4.5 fast path:本地缓存免锁路径(乐观思想再证)

动机:弱关系锁(SELECT/DML 的 AccessShare/RowShare/RowExclusive)频率极高而几乎不冲突,即使 16 分区也会在双核上量出瓶颈,核数越多越糟(README:257-296)。自 PG 9.2 起,合格锁**不进共享锁表**,直接记在 PGPROC 的私有数组里:

```c
/* lock.c:270-275 */
#define EligibleForRelationFastPath(locktag, mode) \
    ((locktag)->locktag_lockmethodid == DEFAULT_LOCKMETHOD && \
     (locktag)->locktag_type == LOCKTAG_RELATION && \
     (locktag)->locktag_field1 == MyDatabaseId && \
     MyDatabaseId != InvalidOid && \
     (mode) < ShareUpdateExclusiveLock)
```

存储:PGPROC 内 `fpInfoLock + fpLockBits + fpRelId + fpVXIDLock`(proc.h:330-336);每后端 `FP_LOCK_SLOTS_PER_GROUP=16` 槽 × 若干组(proc.h:102-105),关系 OID 经乘素数 49157 散到组(lock.c:220-221);槽内每关系 3 bit 模式位(lock.c:244-260)。授予 `FastPathGrantRelationLock`(lock.c:2812-2848)、释放 `FastPathUnGrantRelationLock`(lock.c:2855-2882),全程只碰自己的 `fpInfoLock`(lock.c:1036-1042),不动共享分区—— contention 从根上消失。

防冲突靠 **1024 个原子强锁计数器** `FastPathStrongRelationLocks[]`(10 bit 分区,lock.c:303-309;数组于 lock.c:480-484 共享内存初始化):强锁(≥ShareLock)请求者先 `pg_atomic_fetch_add_u32` 占坑(`BeginStrongLockAcquire` lock.c:1868-1876),再把所有后端 fastpath 数组中的匹配锁搬回主表 `FastPathTransferRelationLocks`(lock.c:2891-2929,逐个拿他人 fpInfoLock);fastpath 侧先检查计数器非零则放弃(lock.c:1037-1041),内存序安全性论证见 README:305-315 与 lock.c:1030-1035 注释。释放同样先走 fastpath(lock.c:2236-2255)。VXID 锁也有 fastpath:本事务首次加锁免检直接置 `fpVXIDLock`(lock.c:4618-4627,论证 README:317-324),提交时若已被物化则回主表释放(lock.c:4636-4672)。死锁检测完全不用看 fastpath 结构——凡可能成环的锁早已被搬进主表(README:331-333)。

---

## 5. 死锁检测专节:超时触发 + 等待图 DFS

### 5.1 为什么是"检测"而非"预防"

预防(全序加锁)要求应用预知全部锁序,对 SQL 引擎不现实;PG 选择惰性检测,代价被死锁超时摊薄:进入 `ProcSleep` 时才挂定时器,注释直言"把检查推迟到等了一会儿之后,多数情况下可避免运行相当昂贵的死锁检查代码"(proc.c:1408-1410;挂定时器 proc.c:1417-1432)。`deadlock_timeout` 默认 1000ms(proc.c:61;GUC 注册于 `guc_parameters.dat:626-634`,PGC_SUSET,防用户设过小自找麻烦)。太小→频繁全表分区锁定;太大→真死锁拖一秒才解。权衡本质:死锁是罕见事件,检测成本应按事件概率而非加锁频率支付。

### 5.2 触发与软/硬阻塞

超时到点,信号处理器 `CheckDeadLockAlert` 置标志并 SetLatch(proc.c:1971-1988),`ProcSleep` 主循环醒来调 `CheckDeadLock`(proc.c:1880-1964):**按分区号顺序**拿全部 16 把分区锁(proc.c:1896-1897,防 LWLock 层死锁),先复查是否其实已被唤醒(proc.c:1909-1913),再跑 `DeadLockCheck`。

等待图(WFG)的边分两种(README:408-426;结构 `EDGE` deadlock.c:47-54):

- **硬边**:等待者 → 已持冲突锁的持有者。`FindLockCycleRecurseMember` 扫 `lock->procLocks`,holdMask 与请求模式按位相交即硬阻塞(deadlock.c:561-624)。
- **软边**:等待者 → 同队列中排在其前、请求冲突的等待者(队列序造成的阻塞,deadlock.c:627-767;若同时满足硬边条件则只算硬边,deadlock.c:630-633)。

### 5.3 DFS 找环与软解

`FindLockCycle`(deadlock.c:443-452)从起始进程向外递归(`FindLockCycleRecurse` deadlock.c:454-528):用 `visitedProcs[]` 去重(deadlock.c:473-499),**回到起点即死锁**(deadlock.c:477-488),回到中间节点则"死锁与我无关"放弃(deadlock.c:490-495);非等待进程还要沿锁组成员再探(并行查询场景,deadlock.c:511-528)。锁组以 leader 为节点归属(deadlock.c:467-469)。

找到环后先尝试**软解**:把环中每条软边作为"队列重排约束"递归搜索(`DeadLockCheckRecurse` deadlock.c:309-358),每组约束经 `ExpandConstraints`+`TopoSort` 生成假想队列序,再 `TestConfiguration`(deadlock.c:375-423)重跑找环验证。无解→`DS_HARD_DEADLOCK`,把起点进程踢出队列报错(`DeadLockCheck` deadlock.c:217-243;执行于 proc.c:1920-1938,`RemoveFromWaitQueue`);有解→把 `waitOrders` 应用回真实队列并 `ProcLockWakeup`(deadlock.c:246-271),返回 `DS_SOFT_DEADLOCK`——**不杀任何事务,只调队**。特例 `DS_BLOCKED_BY_AUTOVACUUM`:起点被 autovacuum 直接硬阻塞时记下其 PGPROC(deadlock.c:617-619),ProcSleep 给它发取消信号(proc.c:1541-1573,防 wraparound 的 vacuum 豁免)。

---

## 6. 对照专节:四种系统的锁哲学

| 系统 | 锁形态 | 粒度/模式 | 等待策略 | 死锁 |
|---|---|---|---|---|
| Git(.lock,见本系列 09/02 章) | 对象库文件改名占位 `.lock` | 整仓库级、仅独占 | 失败即重试/放弃 | 无(靠重试与人工) |
| SQLite | DB 文件 POSIX advisory 锁 + WAL 的 shm 锁 | 库级 5 态;页级写独占 | 忙等/阻塞文件锁 | 无检测,超时报 SQLITE_BUSY |
| Redis | 无(单线程事件循环天然串行) | 命令级隐式 | 排队即执行 | 结构性不可能 |
| K8s | etcd resourceVersion 乐观 CAS | 对象级 | 失败→冲突→重试 | 无;靠 version 冲突暴露 |
| PostgreSQL | 三层锁栈(本章) | 指令~元组~库级;8 模式 | 自旋/信号量/latch | 超时+DFS,软解或杀事务 |

- **Git**:锁的对象是"文件是否存在",语义是独占写;PG 则证明当并发粒度到"行"、模式到 8 种时,必须有冲突矩阵与队列。Git 的 rename 原子性 ≈ PG 的 TAS,但止步于此。
- **SQLite**:同为"文件上的锁",但 SQLite 把并发推给文件系统;PG 把并发收进进程内共享内存,才能做出 16 分区锁表与 fastpath 这类纯内存优化。
- **Redis**:单线程让"锁"退化为队列;PG 多进程必须显式管理互斥,但换来真正的并行读(MVCC+共享 LWLock)。
- **K8s 乐观并发**:K8s 的"先改后提交,版本冲突再重来"与 PG fastpath 的乐观假设同源——都是"大概率无冲突,于是免全局仲裁"。区别:K8s 冲突由 etcd 串行化揭示,fastpath 由 1024 个强锁计数器揭示(lock.c:303-309);而 PG 的主路径(冲突矩阵+等待队列)仍是悲观并发,这在现代系统中已相当罕见。

由此可以说:PG 是"传统数据库完整锁栈"(多模式语义锁+死锁检测+锁管理器视图)的最后活标本之一——同时保留了 System R 时代的表级锁语义与 2010 年代的无锁 CAS 优化(9.2 fastpath、原子 state LWLock),新旧层叠在一个进程模型里。

---

## 7. 设计动机:三层为何缺一不可

1. **持有时间决定等待机制**。自旋锁持有时长以指令计(spin.h:24-27 的编码铁律),忙等最便宜;重锁持有以事务计,忙等等于烧 CPU,必须睡。若只有两层:让 LWLock 场景全走自旋,任意长临界区会让系统在 contention 下雪崩;全走重锁,则每次保护一个哈希桶都要哈希+队列+死锁位图,纯开销。
2. **LWLock 为什么不用自旋锁**:等待时间不可控——持有者可能在等 I/O 或另一个 LWLock(README:33-36 甚至警告 LWLock 等待都可能超秒)。lwlock.c:29-45 的重构笔记给出实证:旧版"自旋锁保护的 rw 锁"在共享热点上"明明锁空闲还在自旋排队",因此改造成共享路径 wait-free 的 CAS 实现。同时 LWLock 保留了临界区禁中断语义(`HOLD_INTERRUPTS`,lwlock.c:1184-1189)与错误恢复(`LWLockReleaseAll`,lwlock.c:1865-1876),这是自旋锁给不了的。
3. **重锁为什么不能并进 LWLock**:它要的是数据库语义——8 模式冲突表(lock.c:68-108)、队列公平与插队(proc.c:1253-1321)、用户可见性(pg_locks)、事务结束自动回收、死锁检测与软解(§5)。README:32-36 明确"所有用户驱动的锁请求都应使用常规锁管理器"。
4. **fastpath 的乐观思想再证**:与 K8s CAS 同构(§6)。它的前提是"能用 1024 个计数器廉价证伪冲突存在"(README:298-315),失败了就回退慢路径并搬锁(lock.c:1072-1093)——乐观是有底座的乐观,不是赌博。
5. **死锁检测的惰性**(proc.c:1408-1410)与**检测者只杀自己**(README:390-400 的情形 3)共同体现:昂贵操作按小概率事件定价,解决方案取最小暴力。

---

## 8. FAQ 素材

1. **Q: pg_locks 里 fastpath=true 的锁在哪?** A: 不在共享锁表,在 PGPROC 私有数组(fpLockBits/fpRelId,proc.h:330-336);strong 锁到来才被搬入主表(lock.c:2891-2929)。
2. **Q: 为什么 LWLock 等待事件名是 BufferContent/LockManager 这些?** A: tranche ID 即等待事件 ID,名字查自内置表或扩展注册表(lwlock.c:746-752、137-147)。
3. **Q: LWLock 是公平锁吗?** A: 基本公平:等待链 FIFO,唤醒连续放行共享、遇独占即止(lwlock.c:916-956);但被唤醒者要重新 CAS 竞争,不保证严格先到先得。
4. **Q: heavyweight 锁队列为什么允许插队?** A: 持有冲突锁者插到被它挡住的等待者之前,否则二者互绕必死锁,晚一秒死不如当场插(proc.c:1253-1269)。
5. **Q: deadlock_timeout 调小会怎样?** A: 每次锁等待超时都会锁定全部 16 个分区做图搜索(proc.c:1896-1897),开销大且期间所有锁操作阻塞;默认 1s 是刻意的(proc.c:61)。
6. **Q: 死锁报错为什么杀的是我而不是对方?** A: 检测由超时的等待者发起,只回退自己的请求即破环(README:390-400;proc.c:1923-1938)。
7. **Q: 自旋锁会永久等下去吗?** A: 不会,约 2 分钟(NUM_DELAYS×最大延迟)后 PANIC "stuck spinlock",整机重启(s_lock.c:33-37、89-91)。
8. **Q: SELECT FOR UPDATE 的行锁走锁管理器吗?** A: 走。heap_acquire_tuplock→LockTupleTuplock→LockTuple 以 LOCKTAG_TUPLE 加重锁(heapam.c:169-176、5457-5486;lmgr.c:562-567;locktag.h:117-124)。但普通 MVCC 行更新不进锁表,只改 tuple 的 xmax/infomask,等待事务结束走 LOCKTAG_TRANSACTION(XactLockTableWait,lmgr.c:663)。
9. **Q: spinlock、LWLock 期间能被 pg_cancel_backend 取消吗?** A: 不能:两种锁的获取都 HOLD_INTERRUPTS(lwlock.c:1184-1189),错误恢复时统一 LWLockReleaseAll;重锁等待期间则可以(README:39-44)。
10. **Q: 一个后端能同时等两把 LWLock 吗?** A: 不能,QueueSelf 检测到已等待直接 PANIC(lwlock.c:1028-1029)。

## 深挖方向

1. **AIO 时代的 LWLock**:新代 IO 子系统的 tranche(AioWorkerSubmissionQueue/AioUringCompletion,lwlocklist.h:87、141)显示锁名单仍在随 IO 模型演化。
2. **锁组(lock group)与并行查询**:FindLockCycleRecurse 对 lockGroupMembers 的二次遍历(deadlock.c:511-528)与 LockCheckConflicts 的组内扣除(lock.c:1646-1683)是死锁检测里最精巧的扩展。
3. **等待队列从 dlist 到"等待即无锁"**:对比 9.5 前 LWLock(自旋锁+计数)与当前原子字实现的演进,可复现 lwlock.c:29-45 注释中描述的性能问题。
4. **fastpath 容量经济学**:max_locks_per_transaction 如何折算成每后端槽数(`InitializeFastPathLocks`,lock.c:203 引用;FastPathLockGroupsPerBackend,lock.c:205),以及"槽满即整体弃用 fastpath"的策略(lock.c:1013-1021、1056-1063)。
5. **两阶段提交中的锁**:LockAcquireExtended 的 WAL 准备/落账(lock.c:1003-1010、1304-1313)与 lock_twophase_recover 系列(lock.h:429-436)——锁状态如何跨崩溃恢复。

---

## 写作要点速查表

| # | 事实 | 位置(仓库相对路径:行号) |
|---|---|---|
| 1 | S_LOCK = 一次 TAS + 平台无关 s_lock 自旋循环 | src/include/storage/s_lock.h:665-668;src/backend/storage/lmgr/s_lock.c:97-112 |
| 2 | 退避 1ms→1s 随机翻倍,1000 次判 stuck PANIC | src/backend/storage/lmgr/s_lock.c:57-61,157-162,134-135,89-91 |
| 3 | spins_per_delay 自适应(+100/-1)与 15/16 EMA 汇共享 | src/backend/storage/lmgr/s_lock.c:185-199,217-231 |
| 4 | x86_64 TAS_SPIN 先无锁读;PAUSE 即 rep;nop | src/include/storage/s_lock.h:212,189-191 |
| 5 | LWLock = tranche(16b)+state(32b 原子)+waiters 链 | src/include/storage/lwlock.h:41-50 |
| 6 | state 位:3 高位标志+18 位共享计数+独占哨兵 MAX_BACKENDS+1 | src/backend/storage/lmgr/lwlock.c:96-118;src/include/storage/procnumber.h:38-39 |
| 7 | acquire 两阶段:CAS→排队→再 CAS→睡眠 | src/backend/storage/lmgr/lwlock.c:1215,1235,1238,1267-1273(协议注释 66-75) |
| 8 | wait 链互斥用 fetch_or LW_FLAG_LOCKED 单发 CAS | src/backend/storage/lmgr/lwlock.c:852-854 |
| 9 | 唤醒协议:连续共享、独占即止、一次 CAS 清 3 标志 | src/backend/storage/lmgr/lwlock.c:916-956,961-986,1006-1008 |
| 10 | tranche 名单表驱动(原 lwlocknames.txt 已并入 lwlocklist.h) | src/backend/storage/lmgr/lwlock.c:137-147;src/include/storage/lwlocklist.h:36-142 |
| 11 | 八模式冲突矩阵常量表 | src/include/storage/lockdefs.h:36-48;src/backend/storage/lmgr/lock.c:68-108 |
| 12 | 锁表 16 分区;分区锁宏 | src/include/storage/lwlock.h:86-87;src/include/storage/lock.h:355-361 |
| 13 | fastpath 判定宏与 1024 强锁计数器 | src/backend/storage/lmgr/lock.c:270-275,303-309 |
| 14 | fastpath 授予/释放/搬移 | src/backend/storage/lmgr/lock.c:2812-2848,2236-2255,2891-2929 |
| 15 | 队列插队/早死锁/自授 | src/backend/storage/lmgr/proc.c:1253-1321 |
| 16 | ProcLockWakeup 公平规则(aheadRequests) | src/backend/storage/lmgr/proc.c:1833-1870 |
| 17 | deadlock_timeout 默认 1000ms;超时才挂检测器 | src/backend/storage/lmgr/proc.c:61,1408-1432 |
| 18 | 检测锁全部 16 分区再跑 DeadLockCheck | src/backend/storage/lmgr/proc.c:1896-1897,1920-1938 |
| 19 | 硬边=持锁冲突;软边=队列序;回起点即环 | src/backend/storage/lmgr/deadlock.c:561-626,627-767,477-488 |
| 20 | 软解:重排约束递归+拓扑排序,无解才杀事务 | src/backend/storage/lmgr/deadlock.c:309-358,375-423,246-279 |
