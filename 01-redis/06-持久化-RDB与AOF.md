# 第 06 章 · 持久化:RDB 的 fork 快照与 AOF 的三条流水线

> 基线:commit `e8726d18`(2025-09-15)。本章行号是笔者逐行核对过的源码位置(rdb.c/rdb.h/aof.c/bio.c),不是转述。

## 6.0 全景:一份快照、一份日志、一个清单

Redis 的持久化由三部分组成,加载时的组合关系是"清单说了算":

| 组件 | 本质 | 文件 |
|---|---|---|
| RDB | 某一时刻的**内存快照**(二进制全量) | `dump.rdb` 或 AOF 的 BASE 文件 |
| AOF | 写命令的**追加日志**(文本协议) | `*.incr.aof`(可多段) |
| Manifest | 7.0+ 的**文件清单**,串起 BASE+INCR | `appendonlydir/*.manifest` |

**混合持久化**(`aof-use-rdb-preamble`,默认开)不是第三种机制,而是重写时 BASE 文件的内容选择:用 `rdbSaveRio` 写 RDB 格式(rewriteAppendOnlyFile,aof.c:2520-2525),之后的增量才是 AOF 文本。加载端先按 RDB 解析前导,再重放 INCR。

## 6.1 RDB 文件格式:两比特前缀的长度编码

RDB_VERSION 当前为 12(rdb.h:21)。整个格式只有两种"词":**长度编码**与**类型字节**。

**长度编码**(rdb.h:23-42)用首字节最高 2 位分四种:

```
00|XXXXXX                      → 6 位长度(≤63,绝大多数键值)
01|XXXXXX XXXXXXXX             → 14 位长度
10|000000 [32bit]              → 32 位长度(网络序)
10|000001 [64bit]              → 64 位长度
11|OBKIND                      → 特殊编码对象:低 6 位指定
                                  INT8/INT16/INT32(0/1/2)或 LZF 压缩(3)
```

**类型字节**(rdb.h:55-98):值类型 0-25 逐代累加——0/1/2/3/4 是最老的 string/list/set/zset/hash,14 起是 quicklist 时代,16-21 是 listpack 时代,22-25 是 7.4 的 hash 字段级过期。**废弃类型的编号永不复用**(要兼容旧 RDB 文件)。控制类 opcode 在 244-255:`AUX`(元数据)、`RESIZEDB`(扩容提示)、`EXPIRETIME_MS`、`SELECTDB`、`EOF` 等。

**文件组织**(rdbSaveRio,rdb.c:1459-1497):

```
REDIS00xx(9B magic) → AUX 字段 → 模块 AUX(before) → Functions 库
→ 逐 DB:[SELECTDB → RESIZEDB → (EXPIRETIME → key → value)* → SLOT_INFO(集群)]
→ 模块 AUX(after) → EOF(255) → CRC64(8B;关闭校验时写 0,加载端跳过检查)
```

细节:`rdbSaveKeyValuePair`(rdb.c:1195)先写 expire(若有)再写 key/value;集群模式有 `SLOT_INFO` opcode 记录槽归属;`aof-timestamp` 等注解走 AUX。

## 6.2 写盘路径:temp + rename + 目录 fsync

`rdbSave`(rdb.c:1600-1641)的流程藏着四个工程细节:

1. **先写 `temp-<pid>.rdb`**,成功后 `rename()` 原子替换(rdb.c:1605-1627)——崩溃时绝不会留下半个损坏的 dump.rdb;
2. `rdbSaveInternal`(rdb.c:1553-1556)在 rio 上设 `rioSetAutoSync(REDIS_AUTOSYNC_BYTES)`——**增量 fsync**,每写 32MB(flush 策略)同步一次,避免最后一次性 fsync 造成延迟尖刺;同时 `rioSetReclaimCache` 回收 page cache,防止大文件把系统缓存挤爆;
3. rename 后还要 **`fsyncFileDir()`(rdb.c:1628-1633)——对目录 fsync**:ext4 等文件系统上,rename 本身的元数据也需落盘才能保证"重启后文件确实在那"。这是极易被自研存储忽略的一步;
4. 失败路径全部 `unlink` + 还原 errno,不留垃圾。

BGSAVE 走 `rdbSaveBackground`(rdb.c:1643-1677):`hasActiveChildProcess()` 守卫保证同一时刻只有一个子进程;`redisFork(CHILD_TYPE_RDB)` 后子进程改进程标题 `redis-rdb-bgsave`、绑核、保存、`sendChildCowInfo(CHILD_INFO_TYPE_RDB_COW_SIZE)` 上报**实际 COW 内存**,然后 `exitFromChild`。父进程记录 `rdb_save_time_start` 与 `rdb_child_type`。

**fork 与写时复制的内存账**:fork 瞬间父子共享全部物理页,子进程写 RDB 期间父进程继续服务写命令——每个被写的页触发一次复制。最坏情况(RDB 保存期间所有页都被改)内存翻倍;实际膨胀由写比例决定,INFO 的 `mem_fragmentation_ratio` 突增与 `RDB_COW_SIZE` 上报可见。代码层的三个配合(第 02、03 章都埋过伏笔):

- fork 期间 `dict_can_resize` 切 AVOID——避免 rehash 翻倍复制页(server.c 的 `updateDictResizePolicy`);
- ARM64 上 `madvise(MADV_FREE)` 有 fork COW 数据损坏的内核 bug,启动时检测并 fail-fast(第 02 章);
- 大页(THP)会放大 COW 粒度(一次复制 2MB),这也是 Redis 启动告警要求 `transparent_hugepage=never` 的根源——fork 的页表复制成本与 COW 粒度都受它影响。

**无盘复制**是同一套代码的变体:`rdbSaveRioWithEOFMark`(rdb.c:1508-1527)在流前后包上 `$EOF:<40 字节随机hex>`,接收端无需解析内容即可判断流结束——细节留到第 07 章。

## 6.3 AOF 写入流水线:从 call() 到页缓存

写命令的传播出口在 call()(第 02 章),它最终调 `feedAppendOnlyFile`(aof.c:1408-1447):

1. 可选的时间戳注解(`aof-timestamp`);
2. **db 切换时插一条 `SELECT`**(aof.c:1424-1431)——AOF 是纯命令流,没有 db 上下文;
3. `catAppendOnlyGenericCommand`(aof.c:1356)把 argv 重编码为 RESP 文本——**AOF 与复制流共用同一种格式**,注释原话:"All commands should be propagated the same way in AOF as in replication";
4. 追加进 `server.aof_buf`,**"在重新进入事件循环之前、客户端收到肯定回复之前"刷盘**(aof.c:1437-1443 注释)——落盘点在 beforeSleep。

真正的落盘在 `flushAppendOnlyFile`(aof.c:1146-1354),这是全章最值得精读的函数:

### always:主线程内联 fdatasync

```
write(aof_buf) → redis_fsync()(Linux 即 fdatasync, 避免刷元数据, aof.c:1330-1334)
→ fsync 失败直接 exit(1)
```

fsync 失败也退出,注释给出契约依据(aof.c:1278-1285):"we have a contract with the user that on acknowledged or observed writes are synced on disk, we must exit"——**回复已经进了输出缓冲,无法回滚,与其假称成功不如立即死**。配合第 05 章的 AE_BARRIER,形成"看到回复必已落盘"的完整语义。

### everysec:后台 fsync + 最多 2 秒的写延迟

- fsync 交 bio 线程(`aof_background_fsync`,aof.c:1349),主线程只管 write;
- **fsync 未完成时,write 最多推迟 2 秒**(aof_flush_postponed_start 机制,aof.c:1189-1204):先记时间戳直接返回;<2s 继续推迟;超时则放弃等待强行写入并 `aof_delayed_fsync++`——这个计数器是磁盘慢的直接报警;
- 逻辑依据:同一 fd 上 write 与 fsync 并发是安全的(不同锁域),但 write 等待 fsync 会把磁盘延迟传染给所有命令。

### 三种策略的丢失窗口(崩溃恢复)

| 策略 | write 时机 | fsync 时机 | 最多丢什么 |
|---|---|---|---|
| always | beforeSleep | beforeSleep,内联 | 已确认的命令不丢(磁盘自身缓存除外) |
| everysec | beforeSleep(最多推迟 2s) | bio 线程,≥1s 间隔 | 约 1-2 秒 |
| no | beforeSleep | 内核决定 | 未被内核回写的全部 |

### 写失败的自愈

**短写**(write 部分成功)时 `ftruncate` 到 `aof_last_incr_size` 把半截命令裁掉(aof.c:1262-1275)——AOF 里绝不能留半条命令,否则加载端拒载。非 always 策略下写失败置 `aof_last_write_status = C_ERR` 并保留剩余缓冲重试;主循环会因这个状态**拒绝一切写命令**(processCommand 检查,server.c:4286-4309)直到恢复成功并打 "AOF write error looks solved"(aof.c:1302-1308)。

缓冲复用是个小而美的细节:总尺寸 <4000B 时 `sdsclear` 复用 sds,否则释放重建(aof.c:1315-1320)。

## 6.4 AOF 重写与 Multi-Part AOF

重写的老问题:文件越写越大但只有小部分是"活数据"。重写流程(aof.c:2563-2576 的官方注释,逐行对应代码):

```
1) BGREWRITEAOF
2) fork():
   2a) 子进程把当前数据集重写成 temp 文件(rewriteAppendOnlyFile)
   2b) 父进程立即打开新 INCR AOF 继续追加(openNewIncrAofForAppend)
3) 子进程退出
4) 父进程收尸(backgroundRewriteDoneHandler):
   4a) 分配新 BASE 文件名,旧 BASE/INCR 标记为 HISTORY
   4b) rename temp → BASE
   4c) 旧 INCR 标记 HISTORY
   4d) 持久化 manifest
   4e) 用 bio 删除 HISTORY 文件
```

**7.0 的 Multi-Part AOF 解决的是"重写期间数据往哪放"**:旧版用一个内存里的 aof_rewrite_buf 缓冲双写(重写期间增量既写旧文件又写缓冲,结束后拼回去),内存翻倍且拼接慢;新版干脆让增量写进**新的 INCR 文件**,manifest 记录文件序列:

```
file appendonly.aof.2.base.rdb seq 2 type b      ← 至多 1 个 BASE
file appendonly.aof.1.incr.aof seq 1 type h      ← HISTORY(等待删除)
file appendonly.aof.3.incr.aof seq 3 type i      ← 活跃 INCR
```
(aof.c:62-70 的注释示例;命名后缀与 manifest 键定义在 aof.c:72-85)

四个值得注意的实现点:

1. **fork 前先 flush 并置 `aof_selected_db = -1`**(aof.c:2589-2592),强制新 INCR 文件以 SELECT 开头——文件是独立加载单元,不能依赖上一个文件的 db 上下文;
2. **子进程重写走 RDB 前导**(aof-use-rdb-preamble,aof.c:2520-2525):BASE 是 RDB 格式,只有 INCR 是文本;
3. 重写期同样有增量 fsync + page cache 回收(aof.c:2513-2516);
4. `AOF_WAIT_REWRITE` 状态下要 `bioDrainWorker(BIO_AOF_FSYNC)` 排空上一个 AOF 的 fsync 任务,防止 `fsynced_reploff_pending` 在新旧文件间错乱、复制 ACK 偏移回跳(aof.c:2598-2610 注释)——**持久化与复制在偏移量上耦合**,这是极易忽视的一致性细节。

## 6.5 bio:三个 worker 与一条完成通知管道

bio.c(445 行)管三件事:关文件、AOF fsync、lazy free。结构(bio.c:51-117):

- **3 个 worker 线程**,每个有自己的 mutex/cond/任务链表;**任务→worker 的映射表**写死(bio.c:59-67)——注意 `BIO_CLOSE_AOF` 也走 fsync worker(同一文件的关闭必须排在 fsync 后,天然保序);
- 任务是 **union bio_job**:fd_args(fd + need_fsync/need_reclaim_cache 位)、free_args(函数指针 + 变长参数数组,给 lazy free 用)、comp_rq(完成回调);
- 每线程 4MB 栈(REDIS_THREAD_STACK_SIZE,bio.c:124)——lazy free 释放深嵌套结构可能递归很深;
- **完成通知**(较新机制,bio.c:75-86、144-159):worker 完成任务后把回调挂进 `bio_comp_list`,通过一条 **pipe 唤醒主事件循环**(注册为 AE_READABLE 事件),由主线程执行回调——后台线程永远不直接碰事件循环与数据结构。

## 6.6 加载:假客户端与截断容忍

AOF 加载构造一个假客户端(aof.c:1455-1475):`createClient(NULL)`、id 固定 `CLIENT_ID_AOF`、**`CLIENT_DENY_BLOCKING`**——注释解释:阻塞 AOF 客户端可能死锁(没人来唤醒它),且会打乱命令执行顺序;`replstate = WAIT_BGSAVE_START` 让执行框架不为它发回复。**RDB、AOF、复制、模块用的是同一个 call() 执行内核**——这是 Redis 框架统一性的最佳例证。

`aof-load-truncated yes`(默认):加载遇尾部不完整命令时打日志、`ftruncate` 裁掉并继续——对应 6.3 的 everysec 崩溃场景;`no` 则遇错即退,适合把完整性置于可用性之上。

## 6.7 设计动机与取舍

1. **RDB 换确定性延迟,AOF 换持久性粒度**:RDB 的成本集中在 fork 瞬间(页表复制,与内存大小成正比)与 COW 膨胀;AOF 的成本摊在每次写(beforeSleep 的 write/fsync)。两者是"checkpoint + WAL"的经典组合,Redis 只是把 checkpoint 做成了 COW 快照;
2. **fdatasync 而非 fsync**(aof.c:1330 注释):不刷元数据,省一次元数据日志写;
3. **每 32MB 增量 fsync**(REDIS_AUTOSYNC_BYTES):把 fsync 成本摊匀,避免"最后一步巨大延迟";
4. **Multi-Part AOF 用文件系统替代内存缓冲**:重写期增量落新文件,牺牲一点文件管理复杂度(manifest),换掉重写缓冲的内存峰值与拼接停顿——典型的"用磁盘目录状态换内存状态";
5. **写失败时的策略不对称**:always 宁死不骗;everysec 宁拒不写。两种都是"契约优先于可用性"的选择,但契约内容不同;
6. **temp+rename+dirfsync 三件套**:原子替换、目录元数据、增量刷盘——自研存储照抄即及格。

## 6.8 FAQ

**Q1:BGSAVE 期间内存最多涨多少?**
理论最坏翻倍(所有页都被改);实际等于"保存期间被写脏的页总量",由 `RDB_COW_SIZE` 上报可见。fork 本身的耗时与页表规模成正比,内存 10GB 级实例 fork 可达百毫秒——这是"Redis 实例不要太大"建议的源码依据。

**Q2:everysec 最多丢几秒数据?**
约 1-2 秒:fsync 由 bio 每秒尝试一次,加上 write 最多推迟 2 秒的上限(aof.c:1195)。

**Q3:为什么 always 策略下 fsync 失败要 exit(1)?**
回复已进输出缓冲,无法回滚;契约是"确认过的写已落盘",继续运行等于撒谎(aof.c:1278-1285)。

**Q4:AOF 半条命令怎么办?**
写失败走 ftruncate 回退到 `aof_last_incr_size`(aof.c:1262);加载失败在 `aof-load-truncated yes` 时裁掉尾部继续、`no` 时拒绝启动。

**Q5:重写期间的新写入在哪?**
独立的 INCR 文件(7.0+),manifest 按序号串联;旧版是内存 aof_rewrite_buf 双写。

**Q6:混合持久化的"混合"在哪?**
BASE 文件内容是 RDB 格式(`aof-use-rdb-preamble`),INCR 是 RESP 文本。加载 = RDB 快照 + 命令重放。

**Q7:为什么重写要先 fork?子进程看到的是什么?**
fork 瞬间的内存快照(COW),子进程把它全量序列化;期间的新写进 INCR,两者在 manifest 层拼接,子进程不需要知道增量。

**Q8:目录 fsync 是必须的吗?**
是。rename 的元数据变更若未落盘,断电后可能"文件内容在、目录项没了"。`fsyncFileDir`(rdb.c:1628)处理它。

**Q9:AOF 加载期间能响应命令吗?**
部分能:加载循环重入事件循环,只放行 CMD_LOADING 白名单命令(第 02 章);加载本身走假客户端 + call()。

**Q10:bio 为什么是 3 个线程而不是 1 个队列?**
fsync 慢会饿死 lazy free,分类保序:同一 worker 内 FIFO(关闭排在 fsync 后),worker 之间互不阻塞(bio.c:59-67)。

## 6.9 小结与深挖方向

本章结论:**RDB = fork + COW + 原子替换;AOF = beforeSleep 刷盘 + 三策略 fsync + Multi-Part 文件组织;两者在偏移量上与复制耦合**。深挖方向:

1. `rioSetAutoSync` 的 32MB 阈值与增量 fsync 在 NVMe/机械盘上的不同收益曲线(rio.c);
2. `fsynced_reploff_pending` 的完整同步协议:WAITAOF 命令如何依赖它(aof.c:1152-1160);
3. fork 页表复制耗时与 THP 的量化关系(需 perf 实验);
4. manifest 的原子持久化实现(temp+rename 同款?)与损坏恢复(aofLoadManifestFromFile);
5. `SLOT_INFO` opcode 与集群 slot 迁移中 RDB 增量快照的关系(rdb.c 的集群路径)。

> 下一章把视野扩到多机:PSYNC 的部分重同步、哨兵的选举随机化、集群的 16384 个槽。
