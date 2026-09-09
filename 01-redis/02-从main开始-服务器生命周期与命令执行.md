# 第 02 章 · 从 main() 开始:服务器生命周期与命令执行框架

> 基线:`redis` unstable 分支,commit `e8726d18`(2025-09-15)。本章行号均以该 commit 为准。
> 一个阅读前须知:这个世代的源码里**不存在 `src/client.c`**——客户端对象的全部生命周期都在 `src/networking.c` 中;也不存在 `initServerSet()`,其语义由 `initServer()` 内的 `createSharedObjects()`(server.c:2833)等函数承担。网上大量资料仍按旧版文件布局描述,读代码时请以你手上的版本为准。

## 2.0 为什么从 main() 读起

读懂一个 C 项目,最省力的入口永远是 `main()`:它把所有子系统的初始化顺序一次性摊开给你看,而初始化顺序本身就写满了设计约束。Redis 的 `main()` 位于 server.c:7325-7668,340 余行,信息密度极高——读完它,你就同时拿到了三样东西:全局状态挂在哪(`struct redisServer server` 单例)、事件循环怎么转(`aeMain` 的 beforeSleep → poll → afterSleep → 文件事件 → 时间事件)、一条命令从字节到执行的完整链路。

框架层只有两个核心抽象:

1. **全局单例** `struct redisServer server`(server.h)——一切状态都挂在它上面,没有隐藏的上下文对象;
2. **事件循环** src/ae.c——主线程的一生就是 `aeMain` 里一圈圈的循环(ae.c:492-498, ae.c:360-467)。

其余所有业务文件,本质上都是往这两个骨架上"挂肉":一条命令的执行和一个定时任务,都被压平成两类回调——文件事件回调(`readQueryFromClient`/`sendReplyToClient`)与时间事件回调(`serverCron`)。

## 2.1 启动十阶段:main() 的完整解剖

```
main() server.c:7325
 ├─0 环境: 随机种子/umask/dict哈希种子            7374-7396
 ├─1 initServerConfig(默认值+命令表)             7401→2201
 │   ACLInit → moduleInitModulesSystem → connTypeInitialize   7402-7405
 ├─2 解析 argv: 文件/stdin/--opts 拼接           7430-7543
 │   loadServerConfig → loadServerConfigFromString(逐行 setter) config.c:644→432
 ├─3 平台检查(Linux/arm64) + daemonize          7552-7580
 ├─4 initServer                                  7597→2769
 │   信号→线程→容器→shared obj→aeCreateEventLoop  2772-2837
 │   redisDb[](kvstore+estore)→eviction pool      2844-2865
 │   aeCreateTimeEvent(serverCron)               2939
 │   aeSet{Before,After}SleepProc                2954-2955
 ├─5 pidfile/proctitle/tcp backlog               7598-7601
 ├─6 clusterInit → modules 加载 → ACL 用户       7602-7610
 │   initListeners(listen+accept handler)        7611→2985
 │   InitServerLast(bio/IO 线程/jemalloc bg)     7615→3062
 ├─7 loadDataFromDisk(RDB/AOF 重放)             7620→7046
 ├─8 "Ready to accept connections"               7638
 └─9 aeMain(server.el)                           7665→ae.c:492
```

### 阶段 0:进程环境(server.c:7374-7396)

设置进程标题、`tzset()`、注册 OOM handler;用 `time^pid^tv_usec` 播种随机数。最关键的一行是**为 dict 设置随机哈希种子** `dictSetHashFunctionSeed`(server.c:7394-7396)——这是防哈希碰撞攻击的第一道防线,必须在任何 dict 创建之前完成。

### 阶段 1:最小化核心初始化(server.c:7400-7405)

```c
server.sentinel_mode = checkForSentinelMode(argc,argv, exec_name);
initServerConfig();
ACLInit(); /* The ACL subsystem must be initialized ASAP because the
              basic networking code and client creation depends on it. */
moduleInitModulesSystem();
connTypeInitialize();
```

`initServerConfig()`(server.c:2201-2332)只做"纯内存默认值":随机生成 runid、`server.hz` 尽早赋值为 10(server.c:2212)、默认 RDB save 策略 `3600s/1 次、300s/100 次、60s/10000 次`(server.c:2273-2275),并**创建命令字典** `server.commands` 与 `server.orig_commands`(server.c:2326-2328)。

注意依赖序:它必须在读配置文件之前执行,否则 `rename-command` 指令没有命令表可改(config.c:525-548);`ACLInit()` 紧随其后,注释明说网络代码与客户端创建依赖默认用户——`createClient` 里的 `clientSetDefaultAuth(c)`(networking.c:182)需要 ACL 的默认用户已存在。

### 阶段 2:配置解析(server.c:7430-7549)

main 把三种配置来源**统一拼成一个字符串**:第一个非 `-` 开头参数是配置文件路径;`-` 表示从 stdin 读;所有 `--port 6380` 风格参数被拼成 `"port 6380\n"` 追加(server.c:7481-7543)。注释给出优先级(server.c:7458):**"File, stdin, explicit options —— last config is the one that matters"**,后出现的覆盖先出现的。

`loadServerConfigFromString`(config.c:432)逐行 `sdssplitargs` 切词,用 `lookupConfig()` 在注册表里找到 `standardConfig`,直接调 `config->interface.set()`。找不到的行走特殊指令:`include` 递归、`rename-command` 改命令字典、`user` 交给 ACL、`loadmodule` 先入队(config.c:523-559)。

**redis.conf 的解析不是解释器,而是一张静态配置项注册表驱动的 setter 调用。** 这也解释了 `CONFIG SET` 为什么能复用同一套代码:两者最终调的都是同一个 setter 接口。

### 阶段 3:平台检查与 daemon 化(server.c:7552-7580)

Linux 上做内存告警、Xen 时钟源检查,以及 ARM64 `madvise(MADV_FREE)` fork 写时复制数据损坏 bug 的检测——命中且未设 `ignore-warnings ARM64-COW-BUG` 时**直接 exit(1)**(server.c:7559-7574)。这是一处很能体现 Redis 工程文化的地方:宁可拒绝启动,绝不带已知的数据损坏风险运行。

### 阶段 4:initServer():服务器本体(server.c:2769-2983)

1. 信号处理:忽略 SIGHUP/SIGPIPE,SIGTERM/SIGINT 的 handler 只置标志(server.c:2772-2774);
2. 容器清零:clients、clients_index、ready_keys 等链表与 rax(server.c:2796-2815);
3. **共享对象** `createSharedObjects()`(server.c:2833):预创建 `shared.ok`、`shared.czero`、各整数小对象——命令回复时直接引用,免去反复构造 robj;
4. `aeCreateEventLoop(server.maxclients+CONFIG_FDSET_INCR)`(server.c:2837);
5. **数据库**:`server.db` 数组(server.c:2844),每个 db 的 keys/expires 是 kvstore(cluster 模式下按 16384 槽分片,server.c:2847-2855);本世代新增 `subexpires = estoreCreate(...)`(server.c:2856)承载 **hash field 级过期**;
6. 注册 `serverCron` 时间事件,首次 1ms 后触发(server.c:2939);
7. 注册 beforeSleep/afterSleep 钩子(server.c:2954-2955)——注释强调必须在数据加载之前,因为加载 RDB 期间的 `processEventsWhileBlocked` 会用到;
8. 32 位实例保护:无 maxmemory 时强制 3GB + noeviction(server.c:2961-2965)。

### 阶段 5-7:监听、模块、线程、数据(server.c:7598-7627)

`initListeners()`(server.c:2985-3055)统一处理 TCP/TLS/Unix 三类 listener;一个都没配则退出。之后是 `clusterInit`、模块加载、ACL 用户加载、`InitServerLast()`(server.c:3062-3067:bio 线程、IO 线程、jemalloc 后台线程)。

线程放到最后的原因注释里写得很清楚:规避 ld.so 在 dlopen 与 TLS 初始化之间的竞态 bug(server.c:3057-3061)。

数据加载放在最后(`loadDataFromDisk`,server.c:7046):AOF 开启则 `loadAppendOnlyFiles`,否则 `rdbLoad`。加载过程本身是"用假客户端逐条重放命令"(详见第 06 章),复制偏移量从 RDB 尾部信息恢复以支持部分重同步(server.c:7071-7099)。

**一个值得记住的推论**:监听 socket 在 `initListeners` 就已建好并注册了 accept handler,但主线程还没回到 aeMain,所以内核 backlog 会替 Redis 攥着已到达的连接,直到 "Ready to accept connections" 后才被真正 accept。这就是"启动日志 Ready 之前客户端能连上但不响应"的机制解释——连接不报错,也不被处理,是正常现象。

启动日志与代码行的对照表(排障时反查用):

| 日志片段 | 代码位置 | 语义 |
|---|---|---|
| `Redis is starting` | server.c:7582 | 配置已加载完,即将 initServer |
| `Redis version=..., commit=..., pid=...` | server.c:7583-7589 | 版本与进程身份 |
| `Server initialized` | server.c:7619 | 数据结构与线程就绪 |
| `DB loaded from append only file: x seconds` | server.c:7053 | AOF 加载完成 |
| `DB loaded from disk: x seconds` | server.c:7068 | RDB 加载完成 |
| `Ready to accept connections tcp` | server.c:7638 | 每类 listener 一行,之后进 aeMain |

### 阶段 8-9:就绪与进入循环(server.c:7638-7668)

打印就绪日志、systemd 通知、设置 CPU 亲和性与 oom_score_adj,最后 `aeMain(server.el)`——main() 的余生都交给了它。

## 2.2 配置系统:注册表 + 事务化的 CONFIG SET

config.c(3743 行)的核心是 `standardConfig` 注册表,每个配置项通过 `embedConfigInterface` 宏挂五个函数指针(config.c:1796-1802):`init`(启动写默认值)、`set`(解析字符串写变量)、`get`、`rewrite`(供 CONFIG REWRITE)、`apply`(把"改了变量"落实为"改了行为",如重建监听)。

`CONFIG SET` 的事务化流程(config.c:801 起)值得单独记:

```
解析 key/value 对(奇数参数直接报错)
  → 逐个 lookupConfig; SENSITIVE 参数先脱敏; IMMUTABLE/PROTECTED/DENY_LOADING 检查
     (检查失败也不中断循环, 保证敏感参数仍被 redact, config.c:827-878)
  → 备份全部旧值 (config.c:883-884)
  → 统一 set(不 apply, config.c:887-896); 任一失败 → restoreBackupConfig 回滚(890)
  → 统一 apply(config.c:899-910); apply 失败同样回滚
```

两个容易被忽视的行为:**多参数 `CONFIG SET` 是全有或全无的**;"变量已改"与"行为已变"是分离的两步——`CONFIG SET port` 只改了变量,apply 阶段才会重建 listener。即使最终回滚,SENSITIVE 参数(如 requirepass)也会先把值从 slowlog/MONITOR 中脱敏(config.c:841-843)——安全边界不因事务失败而失守。

## 2.3 一条命令的字节之旅:`SET key val`

### 客户端对象:五组字段,两阶段销毁

`createClient(conn)`(networking.c:121-235)约 110 行,字段分五组:

- **连接与 IO**:`conn`、`tid/running_tid`(归属哪个 IO 线程)、`io_flags`;
- **输入**:`querybuf`(可复用缓冲)、`qb_pos`、`reqtype`(MULTIBULK/INLINE)、`multibulklen/bulklen`(半包解析进度);
- **命令上下文**:`argv/argc`、`original_argv`(重写前原文,慢日志/MONITOR 用)、`cmd/lastcmd/realcmd/iolookedcmd` 四个命令指针;
- **输出**:定长 `c->buf`(16KB)+ 变长 `c->reply` 链表 + 软硬上限;
- **生命周期**:`id`(原子自增)、30+ 个 `flags` 状态位、`ctime/lastinteraction`、复制握手状态、阻塞状态。

客户端是 Redis 里**被引用点最多的对象**(出现在 clients 链表、pending write 链表、阻塞表、timeout rax、内存驱逐桶……),所以它的销毁必须是两阶段的(`freeClient`,networking.c:1728 起):

```c
if (c->flags & CLIENT_PROTECTED) { freeClientAsync(c); return; }   /* 1733 */
if (c->running_tid != IOTHREAD_MAIN_THREAD_ID)
    fetchClientFromIOThread(c);                                    /* 1739 */
...
if (server.master && c->flags & CLIENT_MASTER) {
    ...
    replicationCacheMaster(c);   /* 与主失联: 缓存成 cached master 1783 */
    return;
}
```

CLIENT_PROTECTED 或 IO 线程归属都会把同步 free 降级为异步(标记 CLOSE_ASAP,由 beforeSleep 的 `freeClientsInAsyncFreeQueue` 在安全点真正释放,server.c:1924);与主库失连的连接甚至不释放,转成 cached master 支持部分重同步。

另外 `createClient(conn==NULL)` 创建的是"无连接客户端",供 Lua 脚本、模块、AOF 加载复用同一套命令执行框架(networking.c:124-127)——**客户端 ≠ TCP 连接**。

### 读:socket → querybuf → argv

`readQueryFromClient`(networking.c:3006)把字节读进 querybuf(networking.c:3082)。本世代一个重要演进:普通客户端默认用**线程级可复用 querybuf**(16KB 的 `thread_reusable_qb`,读完归还,networking.c:3050-3061),避免每客户端常驻大缓冲;只有大参数(`bulklen >= PROTO_MBULK_BIG_ARG`)才切到私有缓冲。所以"1 万连接 = 160MB 输入缓冲"的旧算法已经不成立。

`processInputBuffer`(networking.c:2892-3004)循环消费 querybuf:首字节 `*` 走 RESP MULTIBULK,否则 INLINE;`processMultibulkBuffer` 按 `$N` 逐段**增量解析**,一次读入的缓冲里能解析出几条完整命令就执行几条——pipeline 的框架支点就在这个 while 循环。半包即返回等下次事件,解析状态(`multibulklen/bulklen`)因此必须存在 client 上而非栈上。

### 查:processCommand 的十几道安检(server.c:4072-4427)

这是框架里最长的"门卫"函数,且必须**重入安全**(被阻塞命令中断的客户端重新执行时会二次进入,部分检查被跳过,server.c:4084-4105)。依次:

1. 模块命令过滤器;
2. 命令查找:先试 `isCommandReusable` 复用上次命令(server.c:100-104),否则 `lookupCommand` 走 dict(子命令支持一层,如 `CONFIG|SET`);命中 `host:`/`post` 字样触发安全警告断连(server.c:4113-4117);
3. 存在性与 arity;
4. 未认证只放行 `CMD_NO_AUTH` 命令(server.c:4172-4179);
5. ACL 权限;
6. 集群槽位重定向(server.c:4202-4221);
7. **客户端内存驱逐** `evictClients()`——若把自己驱逐则直接返回(server.c:4241-4245);
8. **数据驱逐** `performEvictions()`,OOM 时只拒绝 `CMD_DENYOOM` 命令(server.c:4253-4277)——SET 带 `CMD_WRITE|CMD_DENYOOM`(commands.def:11512),GET 只有 `CMD_READONLY|CMD_FAST`(commands.def:11499),所以 OOM 不拒读;
9. 磁盘错误/min-replicas/只读副本/加载期/busy 脚本等一系列状态检查(server.c:4286-4389);
10. `CLIENT_PAUSE` 期间延后处理;
11. 分叉:MULTI 事务内命令入队(server.c:4418-4419),否则 `call(c, CMD_CALL_FULL)`。

### 执行:call() 的统一收口(server.c:3711-3936)

```c
dirty = server.dirty;                       /* 执行前脏计数快照 3740 */
c->cmd->proc(c);                            /* 真正执行 3757 */
dirty = server.dirty-dirty;                 /* 差值=是否改了数据 3774 */
```

`c->cmd->proc(c)` 一行就是 `setCommand`(t_string.c:294)的实现入口。执行后 call 统一做六件事:慢日志与 latency 采样、MONITOR 广播(用 `original_argv`)、命令统计、**传播**(以 dirty 差值 + FORCE/PREVENT 标志决定写入 AOF 与复制流——这是写命令同步到副本的唯一出口,server.c:3851-3883)、tracking 记录、`afterCommand()`(触发活跃过期等后续维护)。

被拒绝的命令走 `rejectCommand*` 统一出口(server.c:3944-3978),保证事务脏标记、统计、错误回复三件事不被遗漏。

### 写回:回复如何到达 socket

`addReply*` 只是把数据追加进输出缓冲,并把客户端挂进 `server.clients_pending_write`(networking.c:261-270)。真正写 socket 发生在**本轮事件循环的 beforeSleep**:`handleClientsWithPendingWrites()` 批量尽力写(networking.c:2246-2283),写不完才安装 AE_WRITABLE handler 留待下轮。若 `appendfsync=always`,安装写 handler 时会加 **AE_BARRIER**(networking.c:244-248),保证同一 fd 同一轮内"先 fsync AOF 再写回复"——"看到回复必已落盘"语义的实现点。

## 2.4 serverCron:hz 机制与定时任务清单

serverCron 是 ae 的时间事件,自述是"我们的定时中断,每秒执行 server.hz 次"(server.c:1406-1423)。它的返回值就是下次超时间隔:

```c
server.hz = server.config_hz;                    /* 1435 */
if (server.dynamic_hz) {
    while (listLength(server.clients) / server.hz >
           MAX_CLIENTS_PER_CLOCK_TICK)
    {
        server.hz *= 2;
        if (server.hz > CONFIG_MAX_HZ) { server.hz = CONFIG_MAX_HZ; break; }
    }
}
return 1000/server.hz;                           /* 1689 */
```

默认 hz=10(100ms 一轮),允许 1~500;**动态 hz** 保证客户端数/hz 不超过每轮预算,客户端暴涨时自动加密 cron。低频任务用 `run_with_period(ms)` 宏节流(server.h:766,本质是 cronloops 计数取模,不依赖墙钟)。

每轮任务清单(节选,行号 server.c:1425-1690):

| 周期 | 任务 |
|---|---|
| 每轮 | 看门狗调度、hz 重算、`lruclock` 更新、内存统计(RSS/碎片率)、SIGTERM 收尾、`clientsCron`(超时/缓冲收缩)、`databasesCron`(**慢速主动过期** + 碎片整理 + 渐进 rehash) |
| 1s | 子进程收尸、按 saveparams 触发 BGSAVE、AOF 重写排期、`replicationCron` |
| 100ms | 瞬时指标采样、`clusterCron`、`modulesCron` |

注意:**快速主动过期 `activeExpireCycle(FAST)` 不在 serverCron 而在 beforeSleep**(server.c:1830-1831),每轮事件循环都试,与 cron 的慢速周期互补(机制详见第 08 章)。

## 2.5 事件循环的一轮:把所有角色放到时间轴上

```
                    ┌──────────── 主线程一轮循环 ────────────┐
 t0  beforeSleep    │ 快速过期(activeExpireCycle FAST)      │
                    │ blockedBeforeSleep(唤醒阻塞客户端)     │
                    │ flushAppendOnlyFile(AOF 落盘)         │
                    │ handleClientsWithPendingWrites(写回)   │
                    │ freeClientsInAsyncFreeQueue(异步释放)  │
 t1  aeApiPoll      │ 睡眠,直到 fd 就绪或最近时间事件到期    │
 t2  afterSleep     │ moduleAcquireGIL → 更新时间缓存        │
 t3  文件事件       │ accept → read → 解析+安检+call()       │
 t4  时间事件       │ 到期则 serverCron                      │
 t0' 回到 beforeSleep                                       │
                    └────────────────────────────────────────┘
```

这一张图能同时回答三个高频问题:

1. **为什么 Redis 不需要"写线程"也能把回复写出去**——t0 的批量写,写不完才注册 WRITABLE 事件;
2. **为什么 pipeline 一批命令只需一次网络往返**——所有命令在 t3 被同一份读缓冲消化,回复在下一个 t0 一次写完;
3. **为什么 `appendfsync=always` 能做到"收到回复即已落盘"**——t0 里 AOF flush 排在写回之前,配合 AE_BARRIER。

## 2.6 设计动机:启动序列的三条约束与框架的四个取舍

**启动序列的三条约束**(读代码时可反复验证):

1. **依赖序优先于直觉序**:ACL 抢在网络初始化前、共享对象抢在命令表被引用前、睡眠钩子抢在数据加载前——每处"看似可以后置"的初始化,注释里都给了必须前置的理由;
2. **失败即 fail-fast**:事件循环创建失败、监听失败、ARM64 内核 bug 检测不过,全部 exit(1);
3. **单向流水**:整个顺序是"环境 → 内存态 → 监听态 → 线程态 → 磁盘数据态",daemonize 在 initServer 前,线程在模块加载后(ld.so 竞态)。

**框架层的四个取舍**:

1. **单线程命令执行**:call() 无需加锁,复杂度推到边界——磁盘 IO 交给 fork/bio,大 value 读写交给 IO 线程(IO 线程只做解析与预查命令,执行仍回主线程,iothread.c:409);
2. **beforeSleep 承担"批处理尾巴"**:N 条命令的收尾摊销成一次批量系统调用;
3. **命令表声明式生成**:409 个 JSON(src/commands/)由 `utils/generate-command-code.py` 生成 commands.def(11525 行)。ACL 位图校验、COMMAND 文档、集群 key 提取全部由元数据驱动——新增命令只需写一个 JSON + 一个 proc 函数;
4. **删除即延迟**:客户端异步 free、错误表异步回收、大 argv 延迟回收——单线程模型下,任何同步释放大对象都会直接变成尾延迟,框架宁可增加状态机复杂度也要把释放动作挪出关键路径。

## 2.7 FAQ:本章高频疑问

**Q1:Redis 是单线程吗?**
命令执行(含 call/proc)是主线程单线程;serverCron 也在主线程。但 bio 子线程(AOF fsync/关闭文件/lazy free)、IO 线程、模块线程、jemalloc 后台线程都存在。准确说法是"**单命令执行线程的事件循环模型**"。

**Q2:serverCron 到底多久跑一次?**
默认 100ms(hz=10),返回值 `1000/server.hz` 就是下次间隔(server.c:1689);dynamic-hz 随客户端数翻倍至最高 500。

**Q3:为什么 SIGTERM handler 里不直接 shutdown?**
信号 handler 里只能做异步安全操作。handler 只置 `server.shutdown_asap`,真正的 `prepareForShutdown` 在下一轮 serverCron(server.c:1496-1505)。

**Q4:加载 RDB/AOF 期间服务器完全不可用吗?**
不是。加载循环周期调用 `whileBlockedCron`(server.c:1711),并通过 `processEventsWhileBlocked` 处理部分事件;只放行带 `CMD_LOADING` 标志的命令(server.c:4360-4363)。SIGTERM 在加载期同样被优雅接住(server.c:1745-1750)。

**Q5:OOM 时 GET 会被拒绝吗?**
不会。OOM 拒绝只针对 `CMD_DENYOOM` 命令;GET 只有 `CMD_READONLY|CMD_FAST`。但 `performEvictions()` 对读命令同样会执行——驱逐与拒绝是两件事。

**Q6:SET 的回复在 SET 执行完就发出去了吗?**
不是。执行完只进了输出缓冲;真正写 socket 在同一轮的 beforeSleep,写不下才注册 WRITABLE 事件延迟发送。这是 pipeline 高效的根源。

**Q7:`CONFIG SET` 多参数是原子的吗?**
是。先备份全部旧值,统一 set(不 apply),再统一 apply,任一失败整体回滚(config.c:883-910)。

**Q8:rename-command 后 ACL 规则按哪个名字写?**
`server.commands` 被改名,`server.orig_commands` 保留原名(config.c:525-548);ACL 的命令 id 在改名前按 fullname 分配,故 ACL 规则按**新名**写。

## 2.8 小结与深挖方向

本章把"进程怎么走到 aeMain"与"字节怎么变成 `proc(c)` 的调用"两条通路闭合了。留下的深挖问题,对应后续章节或独立课题:

1. **IO 线程的 fan-in/fan-out 边界**:IO 线程解析完命令后如何回交主线程、`iolookedcmd` 预查节省了什么(server.c:1898-1912 的 `server.running` 原子标志如何防双线程消费同一客户端);
2. **hash field 过期(estore)**:`server.db[j].subexpires`(server.c:2856)与 `expires` kvstore 的分工,以及 AOF/复制如何表达字段级 TTL(→ 第 08 章);
3. **阻塞期事件循环的精确语义**:`processEventsWhileBlocked` 重入时 beforeSleep 只做 4 件"低危事"(server.c:1787-1804),`CLIENT_BLOCKED` 的唤醒与重放路径;
4. **客户端驱逐与数据驱逐的耦合**:`client_mem_usage_buckets` 如何 O(1) 找到大客户端,"驱逐了自己"对 pipeline 中已解析命令意味着什么(server.c:4242-4245)。

> 下一章我们下沉一层:这些命令操作的键与值,在内存里究竟长什么样——SDS、dict、listpack 三大底座的逐字节解读。
