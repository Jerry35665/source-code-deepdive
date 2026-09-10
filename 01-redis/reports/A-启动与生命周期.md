# A 篇 · Redis 服务器启动与命令执行框架

> 调研基线:redis unstable 分支,commit e8726d18(2025-09-15),version.h 为 255.255.255 开发标记。
> 所有行号均以该 commit 为准。注明:本版本仓库中**不存在 `src/client.c`**,客户端对象生命周期全部位于 `src/networking.c`;也**不存在 `initServerSet()`**,与其语义最接近的是 `initServer()` 内的 `createSharedObjects()`(server.c:2833)与 `initServerClientMemUsageBuckets()`(server.c:2182)。

---

## ① 子系统全景:职责与边界

Redis 的"启动与命令执行框架"是整个巨石的地基,由四块组成:

| 模块 | 文件 | 职责 | 边界(不负责) |
|---|---|---|---|
| 生命周期 | src/server.c(7670 行) | `main()` 启动序列、`initServerConfig/initServer`、`serverCron`、`beforeSleep/afterSleep`、`call()/processCommand()`、shutdown | 具体数据结构实现、持久化格式 |
| 客户端 | src/networking.c(约 4000 行) | `client` 对象分配/释放、协议解析入口、读写字节、输出缓冲 | 命令语义 |
| 配置 | src/config.c(3743 行) | 配置项注册表、加载、`CONFIG GET/SET/REWRITE` | 配置项指向的业务变量由 server.c 持有 |
| 命令表 | src/commands/(409 个 JSON)→ src/commands.def(11525 行) | 命令元数据(声明式) | 命令实现函数在各业务文件(如 t_string.c) |

框架层的核心抽象只有两个:一是 `struct redisServer server` 全局单例(server.h 中定义),一切状态挂在它上面;二是 ae 事件循环(src/ae.c),主线程的整个生命周期就是 `aeMain` 里的一圈圈循环:睡眠前钩子 → `aeApiPoll` → 睡眠后钩子 → 文件事件 → 时间事件(ae.c:492-498, ae.c:360-467)。理解了这两点,其余文件都是往这两个骨架上"挂肉"。

从框架角度看,"一条命令的执行"与"一个定时任务"都被压平成两类回调:文件事件回调(readQueryFromClient/sendReplyToClient)与时间事件回调(serverCron),所有业务文件最终都通过这两个入口与事件循环对接。因此本篇的两个主线问题——"进程怎么走到 aeMain"与"字节怎么变成 proc(c) 的调用"——分别对应第②节与第③节;第④节补齐时间事件那一半,第⑤、⑥、⑦节给出取舍、陷阱与延伸问题。

另外提示一处阅读源码时的坐标修正:网络事件与客户端的绝大多数逻辑在 networking.c(约 4000 行)而非 server.c;server.c 里 processCommand/call 只负责"执行前安检 + 执行 + 执行后传播",读写缓冲、协议解析、连接管理都在 networking.c 与 connection.c(连接类型抽象)中。

---

## ② 从 main() 开始的完整启动流程

`main()` 位于 server.c:7325-7668,共 340 余行,按时间序可以分为 10 个阶段。

### 阶段 0:进程环境准备(server.c:7374-7396)

设置进程标题库、`tzset()` 填充时区、注册 OOM handler(server.c:7377-7378);用 `time^pid^tv_usec` 播种随机数(server.c:7382-7385);保存 umask(server.c:7392);**为 dict 设置随机哈希种子** `dictSetHashFunctionSeed`(server.c:7394-7396)——这是防哈希碰撞攻击的第一道防线,必须在任何 dict 创建之前完成。

### 阶段 1:核心子系统最小初始化(server.c:7400-7405)

```c
server.sentinel_mode = checkForSentinelMode(argc,argv, exec_name);
initServerConfig();
ACLInit(); /* The ACL subsystem must be initialized ASAP because the
              basic networking code and client creation depends on it. */
moduleInitModulesSystem();
connTypeInitialize();
```

`initServerConfig()`(server.c:2201-2332)只做"纯内存默认值":随机生成 runid(server.c:2208)、`server.hz` 尽早赋值为 10(server.c:2212)、默认 RDB save 策略 `3600s/1 次、300s/100 次、60s/10000 次`(server.c:2273-2275),以及**创建命令字典** `server.commands` 与 `server.orig_commands` 并调用 `populateCommandTable()`(server.c:2326-2328)。注意它必须在读配置文件之前执行,否则 `rename-command` 指令没有命令表可改(config.c:525-548 的 rename-command 逻辑依赖已填充的 `server.commands`)。

`ACLInit()` 紧随其后,源码注释明确说:网络代码与客户端创建依赖默认用户(server.c:7402-7403)——`createClient` 里的 `clientSetDefaultAuth(c)`(networking.c:182)需要 ACL 的默认用户已存在。

### 阶段 2:命令行与配置文件解析(server.c:7430-7549)

main 把三种配置来源**统一拼成一个字符串**再交给配置系统:第一个非 `-` 开头参数是配置文件路径(server.c:7461-7467);`-`(单个横杠)表示从 stdin 读(server.c:7473-7475);所有 `--port 6380` 风格参数被拼成 `"port 6380\n"` 追加到 options(server.c:7481-7543)。源码注释给出了优先级(server.c:7458):**"File, stdin, explicit options —— last config is the one that matters"**,即后出现的覆盖先出现的。

`loadServerConfig`(config.c:644-713)读文件后交给 `loadServerConfigFromString`(config.c:432):逐行 `sdssplitargs` 切词,用 `lookupConfig()`(config.c:473)在注册表里找到 `standardConfig`,直接调 `config->interface.set()`。找不到的行再走特殊指令:`include` 递归加载(config.c:523-524)、`rename-command` 改命令字典(config.c:525-548)、`user` 交给 ACL(config.c:549)、`loadmodule` 先入队(config.c:558-559)。所以 **redis.conf 的解析不是解释器,而是一张静态配置项注册表驱动的 setter 调用**。

举例:`redis-server /etc/redis.conf --port 6380 --save` 在 main 里会被拼成配置文本 `/etc/redis.conf\n`(文件路径)、`port 6380\n`、`save ""\n`(裸 `--save` 补空串以兼容 7.0 前的行为,server.c:7496-7511),最终按行进入同一个解析循环;`--sentinel` 则在参数识别阶段就改变整个启动路径(server.c:7400,7417)。

### 阶段 3:平台检查与 daemon 化(server.c:7552-7580)

Linux 上做内存告警、Xen 时钟源检查、ARM64 `madvise(MADV_FREE)` fork COW 数据损坏 bug 检测,后者若命中且未设 `ignore-warnings ARM64-COW-BUG` 会**直接 exit(1)**(server.c:7559-7574)。随后按 `daemonize` 配置 fork 进后台(server.c:7578-7580)。

### 阶段 4:initServer() —— 数据结构与事件循环(server.c:2769-2983)

这是真正的"服务器本体"初始化:

1. **信号与线程**:忽略 SIGHUP/SIGPIPE,注册 SIGTERM/SIGINT handler(server.c:2772-2774);`ThreadsManager_init()`(server.c:2775)。
2. **容器清零**:所有链表/rax(server.clients、clients_index、ready_keys、tracking_pending_keys 等,server.c:2796-2815)。
3. **共享对象**:`createSharedObjects()`(server.c:2833)预创建 `shared.ok`、`shared.czero`、各整数小对象等——命令回复时直接引用,免去反复构造 robj。
4. **事件循环**:`aeCreateEventLoop(server.maxclients+CONFIG_FDSET_INCR)`(server.c:2837),容量按 maxclients 预留额外 fd 余量。
5. **数据库**:`server.db = zmalloc(sizeof(redisDb)*server.dbnum)`(server.c:2844),每个 db 的 keys/expires 是 kvstore(cluster 模式下 16384 槽分片,`KVSTORE_FREE_EMPTY_DICTS`,server.c:2847-2855),此外还有本版本新出现的 `subexpires = estoreCreate(...)`(server.c:2856)承载 hash field 级过期,以及 blocking_keys/watched_keys 等 dict(server.c:2858-2861)。
6. **注册 serverCron**:`aeCreateTimeEvent(server.el, 1, serverCron, NULL, NULL)`(server.c:2939),首次 1ms 后触发,之后间隔由 serverCron 返回值决定。
7. **注册睡眠钩子**:`aeSetBeforeSleepProc` / `aeSetAfterSleepProc`(server.c:2954-2955)。注释强调必须在加载数据之前注册,因为加载 RDB 期间的 `processEventsWhileBlocked` 会用到(server.c:2952-2953)。
8. **32 位实例保护**:无 maxmemory 时强制 3GB + noeviction(server.c:2961-2965)。
9. 脚本引擎、Functions、慢日志、延迟监控初始化(server.c:2967-2974)。

### 阶段 5~7:监听、模块、后台线程(server.c:7598-7615)

`initListeners()`(server.c:2985-3055)把 TCP/TLS/Unix 三类 listener 统一走 `connListen()` + `createSocketAcceptHandler()`;一个都没配则 "Configured to not listen anywhere, exiting"(server.c:3051-3054)。之后依次是:`clusterInit()`(7602)、模块系统的 `moduleInitModulesSystemLast/moduleLoadInternalModules/moduleLoadFromQueue`(7605-7609)、`ACLLoadUsersAtStartup()`(7610)、`clusterInitLast()`(7613)、`InitServerLast()`(server.c:3062-3067:bio 线程、IO 线程、jemalloc 后台线程)。线程放到最后的注释写明原因:ld.so 在 dlopen 与 TLS 初始化间的竞态 bug(server.c:3057-3061)。

### 阶段 8:数据加载(server.c:7620-7627)

```c
aofLoadManifestFromDisk();
loadDataFromDisk();
aofOpenIfNeededOnServerStart();
aofDelHistoryFiles();
applyAppendOnlyConfig();
```

`loadDataFromDisk()`(server.c:7046)AOF 开启则 `loadAppendOnlyFiles`,否则 `rdbLoad`;加载过程本身就是"用假客户端逐条重放命令"(AOF 加载走 `call()`,详见 FAQ),复制偏移量从 RDB 尾部信息恢复以支持部分重同步(server.c:7071-7099)。集群实例随后校验槽位归属(server.c:7629-7631)。加载期间服务器对外的可用性由 processCommand 的 loading 分支与 `CMD_LOADING` 标志共同决定(server.c:4360-4363):只放行 INFO/SUBSCRIBE 等带 `t`/`CMD_LOADING` 标志的命令;SIGTERM 在加载期同样被优雅接住,由 `whileBlockedCron` 代行 shutdown(server.c:1745-1750)。

数据加载放最后还有一层含义:在此之前 `initListeners` 已经把监听 socket 建好、accept handler 已经注册,但因为主线程还没回到 aeMain,内核 backlog 会替 Redis 攥着已到达的连接,直到 "Ready to accept connections" 后才被真正 accept——这就是"Redis 启动日志里 Ready 之前客户端连接不报错、也不被处理"的机制解释。

### 阶段 9:进入事件循环(server.c:7662-7668)

打印 "Ready to accept connections"(server.c:7638)、systemd READY 通知(server.c:7641-7648)、CPU 亲和性与 oom_score_adj,最后:

```c
aeMain(server.el);
aeDeleteEventLoop(server.el);
return 0;
```

### 启动日志与代码行对照

排障时把日志行反查回代码,是验证启动序列最直接的手段。以下按默认输出顺序:

| 日志片段 | 代码位置 | 语义 |
|---|---|---|
| `Redis is starting` | server.c:7582 | 配置已加载完,即将进入 initServer |
| `Redis version=..., commit=..., pid=...` | server.c:7583-7589 | 版本与进程身份(含 git SHA) |
| `Warning: no config file specified...` / `Configuration loaded` | server.c:7591-7595 | 是否给了配置文件 |
| `monotonic clock: ...` | server.c:2835-2836 | initServer 内,单调时钟选型 |
| `Server initialized` | server.c:7619 | 数据结构与线程就绪,开始加载数据 |
| `DB loaded from append only file: x seconds` / `DB loaded from disk: x seconds` | server.c:7053 / 7068 | 数据加载完成 |
| `Ready to accept connections tcp` | server.c:7638 | 每类 listener 一行,之后进 aeMain |

注意顺序陷阱:`Server initialized` 在数据加载**之前**打出,而监听 socket 早在 initListeners 就已就绪(server.c:7611),所以"Ready 之前客户端能连上但无响应"是正常现象(内核 backlog 揽客)。

### 启动流程 ASCII 图

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
 │   lua/functions/slowlog/latency               2967-2974
 ├─5 pidfile/proctitle/ascii art/tcp backlog     7598-7601
 ├─6 clusterInit → modules 加载 → ACL 用户       7602-7610
 │   initListeners(listen+accept handler)        7611→2985
 │   InitServerLast(bio/IO 线程/jemalloc bg)     7615→3062
 ├─7 loadDataFromDisk(RDB/AOF 重放)             7620→7046
 ├─8 "Ready to accept connections"               7638
 └─9 aeMain(server.el)                           7665→ae.c:492
     ┌──────────── 无限循环 ────────────┐
     │ beforeSleep()                    │ server.c:1777
     │ aeApiPoll(阻塞至最近定时器)      │ ae.c:398
     │ afterSleep()                     │ server.c:1969
     │ 处理就绪文件事件(accept/read/write) ae.c:409-461
     │ 处理时间事件 → serverCron        │ ae.c:464
     └───────────────────────────────────┘
```

### 启动序列的三条设计约束(读代码时可以反复验证)

1. **依赖序优先于直觉序**:`ACLInit` 抢在一切网络初始化之前(server.c:7402-7403),`createSharedObjects` 抢在第一个命令表项被引用之前(server.c:2833),睡眠钩子注册抢在数据加载之前(server.c:2952-2955,因为加载过程会用 `processEventsWhileBlocked` 重入事件循环)。每一处"看似可以后置"的初始化,注释里都给了它必须前置的理由。
2. **失败即 fail-fast**:事件循环创建失败、监听失败、locale 设置失败、ARM64 内核 bug 检测不过,全部直接 exit(1),绝不带病运行。
3. **fork 前与 fork 后的秩序**:daemonize 在 initServer 之前(进程身份先定),而会创建子进程的能力(bio 线程等"线程态")放在 InitServerLast,模块加载又必须在 InitServerLast 之前(ld.so 竞态,server.c:3057-3061)。整个顺序是"环境 → 内存态 → 监听态 → 线程态 → 磁盘数据态"的单向流水。

---

## ②补 · 配置系统概览(config.c)

配置系统由一张静态注册表驱动。每个配置项是 `standardConfig`,内部通过 `embedConfigInterface(initfn, setfn, getfn, rewritefn, applyfn)` 宏挂上五个函数指针(config.c:1796-1802):`init` 启动时写默认值;`set` 解析字符串写入业务变量;`get` 序列化读出;`rewrite` 供 CONFIG REWRITE 重写文件;`apply` 把"改了变量"落实为"改了行为"(如重建监听、调整 hz)。类型层面再抽象出 bool/int/enum/string/size/percent 等通用 setter(如 `boolConfigSetInternal`,config.c:1821-1838,返回值约定:0 失败、1 变更、2 未变)。

**CONFIG SET 的事务化流程**(`configSetCommand`,config.c:801 起):

```
解析 key/value 对(奇数参数直接报错, config.c:814-817)
  → 逐个 lookupConfig; SENSITIVE 参数先脱敏; IMMUTABLE/PROTECTED/DENY_LOADING 检查
     (config.c:827-878, 检查失败也不中断循环, 保证敏感参数仍被 redact)
  → 备份全部旧值 (get, config.c:883-884)
  → 统一 set(不 apply, config.c:887-896); 任一失败 → restoreBackupConfig 回滚(890)
  → 统一 apply(config.c:899-910); apply 失败同样回滚
```

这解释了两个容易被忽视的行为:第一,`CONFIG SET maxmemory 1g hz 20` 这类多参数写法是**全有或全无**的;第二,"变量已改"与"行为已变"是分离的两步——比如 `CONFIG SET port` 只改了变量,apply 阶段才会重建 listener,而部分配置根本不需要 apply(configNeedsApply 判断,config.c:904)。启动路径上,`loadServerConfigFromString` 只调 `set`(config.c:496),apply 语义由 initServer 阶段的初始化代码统一兜底(例如 `server.aof_state = server.aof_enabled ? AOF_ON : AOF_OFF`,server.c:2784)。

此外 config.c 还承载三类"伪配置"指令:`rename-command`(直接操作命令字典,config.c:525-548)、`user`(ACL 用户声明,config.c:549)、`loadmodule`(先入队、等 main 后半段再真正 dlopen,config.c:558-559)——它们不是"值",而是启动动作,所以不走 standardConfig 表,而在 loadServerConfigFromString 里特判。

---

## ③ 一条命令的字节之旅:以 `SET key val` / `GET key` 为例

### 3.0 客户端对象生命周期(networking.c,原 client.c 职责)

**创建**:`createClient(conn)`(networking.c:121-235)约 110 行,几乎全是对 `client` 结构体的逐一赋零,值得记住的字段分为五组:

- 连接与 IO:`conn`(可为 NULL)、`tid/running_tid`(归属哪个 IO 线程,networking.c:140-142)、`io_flags`(读/写使能与 pending 标志,networking.c:176);
- 输入:`querybuf`(可复用缓冲指针)、`qb_pos`、`reqtype`(RESP2/3 之上再分 MULTIBULK/INLINE)、`multibulklen/bulklen`(半包解析进度);
- 命令上下文:`argv/argc`、`original_argv`(命令重写前原文,慢日志/MONITOR 用)、`cmd/lastcmd/realcmd/iolookedcmd` 四个命令指针(nested 调用与重试语义各不相同,networking.c:170);
- 输出:定长 `c->buf`(16KB,`PROTO_REPLY_CHUNK_BYTES`,networking.c:135)+ 变长 `c->reply` 链表 + `reply_bytes` 总量 + soft limit 时间戳;
- 生命周期与身份:`id`(全局原子自增)、`flags`(30+ 个状态位)、`ctime/lastinteraction`(超时判定)、`replstate`(副本握手状态机)、`bstate`(阻塞命令状态)。

**状态机**:客户端没有枚举式的"状态机"字段,状态由 flags 位组合表达(server.h:363-425)。常用的正交位:角色(CLIENT_SLAVE/MASTER/MONITOR)、事务(CLIENT_MULTI/DIRTY_CAS/DIRTY_EXEC)、阻塞(CLIENT_BLOCKED)、关闭(CLIENT_CLOSE_AFTER_REPLY/CLOSE_AFTER_COMMAND/CLOSE_ASAP 三级)、传播控制(CLIENT_FORCE_AOF/FORCE_REPL/PREVENT_PROP)、保护(CLIENT_PROTECTED,复制握手与模块回调期间免死)。

**销毁**:`freeClient`(networking.c:1728 起)是一个"善后清单":

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
... 释放 querybuf/bstate/watch/pubsub/reply/argv ...               /* 1795-1828 */
unlinkClient(c);               /* 关 socket、摘事件、摘各类链表 1842 */
```

三个关键细节:① CLIENT_PROTECTED 与 IO 线程归属都会把同步 free 降级为异步;② 主连接断开时不释放而是 `replicationCacheMaster` 缓存其状态,用于 PSYNC 部分重同步;③ 从 `server.clients`、pending write 链表、阻塞表、timeout rax、mem_usage bucket 等"到处都被引用"的摘除动作集中在 `unlinkClient`(networking.c:1578),而真正回收内存发生在 beforeSleep 的 `freeClientsInAsyncFreeQueue`(server.c:1924)。**客户端是 Redis 里被引用点最多的对象,所以它的销毁必须是两阶段的。**

### 3.1 读:socket → querybuf → argv

### 3.1 读:socket → querybuf → argv

accept 侧:`acceptCommonHandler`(networking.c:1402)先做 maxclients 准入控制(networking.c:1423-1442),再 `createClient(conn)`(networking.c:1445)。`createClient`(networking.c:121-235)设置 TCP_NODELAY/keepalive、**把读事件 handler 挂成 `readQueryFromClient`**(networking.c:132),分配固定大小输出缓冲 `c->buf`(PROTO_REPLY_CHUNK_BYTES,networking.c:135),原子递增分配全局 client id(networking.c:137-139),最后 `linkClient` 挂入 `server.clients`(networking.c:229)。conn 传 NULL 即创建"无连接客户端",供 Lua/模块/AOF 加载复用同一套命令执行框架(networking.c:124-127 注释)。

数据到达时 `readQueryFromClient`(networking.c:3006)被触发:`connRead` 读入 querybuf(networking.c:3082)。普通命令用**线程级可复用 querybuf**(16KB 的 `thread_reusable_qb`,networking.c:3050-3061)避免每客户端常驻大缓冲;只有大参数(`bulklen >= PROTO_MBULK_BIG_ARG`)才切到客户端私有缓冲并精确按需读(networking.c:3023-3036)。超过 `client-max-querybuf-len`(未认证客户端硬顶 1MB)直接异步断开(networking.c:3110-3122)。

随后 `processInputBuffer`(networking.c:2892-3004)循环消费 querybuf,循环体开头先过五道"可以继续解析吗"的短路:阻塞中、上一条命令还挂着(CLIENT_PENDING_COMMAND)、对端是 master 且忙脚本中、已决定关闭——都直接 break(networking.c:2894-2913)。然后首字节判断协议类型,`*` 为 RESP MULTIBULK 否则 INLINE(networking.c:2916-2922)。`processMultibulkBuffer` 按 `$N` 逐段解析:参数个数、每个 bulk 的长度与内容都做增量解析,一次读入的缓冲里能解析出几条完整命令就执行几条(pipeline 的框架支点就在这个 while 循环)。半包即返回等下次事件,这也解释了为什么解析状态(`multibulklen/bulklen`)必须存在 client 上而非栈上。

解析出完整命令后交给 `processCommandAndResetClient → processCommand`(networking.c:2964)。若当前线程是 IO 线程则只标记 `CLIENT_IO_PENDING_COMMAND`、预查 `iolookedcmd` 并把客户端排队回主线程(networking.c:2950-2960)。循环结束后把 querybuf 前缀裁掉(`sdsrange` 到 qb_pos,networking.c:2991-2995),master 客户端则按 `repl_applied` 裁剪——因为它的 querybuf 还兼任复制流转发缓冲(networking.c:2973-2990)。

### 3.2 查:processCommand 的"安检流水线"(server.c:4072-4427)

这是框架里最长的"门卫"函数,且必须**重入安全**:被阻塞命令中断的客户端重新执行时会二次进入,此时 `c->cmd` 非空,`client_reprocessing_command` 为真,存在性/arity/ACL 等检查被跳过,只做后续的状态类检查(server.c:4084-4105)。依次执行(全部通过才会真正执行):

1. 模块命令过滤器与请求日志(server.c:4087-4090);
2. **命令查找**:先试 `isCommandReusable` 复用上次命令(无子命令且同名,server.c:100-104),否则 `lookupCommand`(server.c:4111→3366-3380,dict 查一级命令名,有子命令再查一层,如 `CONFIG|SET`);命中 `host:`/`post` 字样触发安全警告断连(server.c:4113-4117);internal 命令对普通连接视同不存在(server.c:4122-4124);
3. 存在性与 arity 校验(server.c:4128-4135);`CMD_PROTECTED` 的 DEBUG/MODULE 需显式开启(server.c:4139-4151);
4. 未认证只放行 `CMD_NO_AUTH` 命令(AUTH/HELLO/RESET 等,server.c:4172-4179);
5. ACL 权限检查 `ACLCheckAllPerm`(server.c:4189-4196);
6. 集群槽位重定向 `getNodeByQuery`(server.c:4202-4221);
7. **客户端内存驱逐** `evictClients()`——若把自己驱逐则直接返回(server.c:4241-4245);
8. **maxmemory 数据驱逐** `performEvictions()`,OOM 时拒绝 `CMD_DENYOOM` 命令(server.c:4253-4277);GET/SET 中 SET 带 `CMD_WRITE|CMD_DENYOOM`,GET 带只读标志(commands.def:11499、11512);
9. 磁盘错误拒绝写(server.c:4286-4309)、min-replicas-to-write(server.c:4313-4316)、只读副本拒绝写(server.c:4320-4326)、RESP2 Pub/Sub 连接白名单(server.c:4330-4345)、副本断连后 stale 数据策略(server.c:4350-4356)、加载期拒绝(server.c:4360-4369)、busy 脚本期只放行 `CMD_ALLOW_BUSY`(server.c:4378-4389);
10. `CLIENT_PAUSE` 期间 `blockPostponeClient` 延后处理(server.c:4401-4407);
11. 最后分叉:MULTI 事务内命令入队(server.c:4418-4419),否则 `call(c, CMD_CALL_FULL)`(server.c:4421-4422)。

### 3.3 执行:call() 的统一收口(server.c:3711-3936)

```c
dirty = server.dirty;                       /* 执行前脏计数快照 3740 */
const long long call_timer = ustime();
c->flags |= CLIENT_EXECUTING_COMMAND;       /* 3751 */
c->cmd->proc(c);                            /* 真正执行 3757 */
exitExecutionUnit();
...
c->duration += duration;                    /* 3773 */
dirty = server.dirty-dirty;                 /* 差值=是否改了数据 3774 */
```

`c->cmd->proc(c)` 一行就是 SET/GET 的实现入口:`setCommand`(t_string.c:294-305,解析 NX/EX/GET 等扩展参数后走 `setGenericCommand`)、`getCommand`(t_string.c:336-338,`lookupKeyReadOrReply` + `addReplyBulk`)。执行之后 call 统一做六件事:

- **慢日志**(server.c:3811-3812)与 **latency 采样**(server.c:3801-3807),优先用硬件单调时钟计时(server.c:3753-3771);
- **MONITOR 广播**(server.c:3818-3824,用 `original_argv` 保留命令重写前的原文);
- **命令统计** `calls/microseconds/latency_histogram`(server.c:3833-3839);
- **传播**:以执行前后 `server.dirty` 差值判断是否改数据,结合 CLIENT_FORCE_*/CLIENT_PREVENT_* 标志决定写入 `alsoPropagate` 即 AOF + 复制流(server.c:3851-3883)——这是"写命令为何能同步到副本/AOF"的唯一出口;
- **客户端缓存 tracking** 记录只读命令访问的 key(server.c:3894-3906);
- `server.stat_numcommands++`、`updatePeakMemory`、`afterCommand(c)`(server.c:3914-3922,内部触发活跃过期推进等后续维护)。

被拒绝的命令走 `rejectCommand*`(server.c:3944-3978):给事务打脏标记、计 `rejected_calls`、回错误。

### 3.4 写回:回复如何到达 socket

命令实现里的 `addReply*` 只是把数据追加进 `c->buf`(定长 16KB)/`c->reply`(链表)两个输出缓冲,并调 `putClientInPendingWriteQueue` 把客户端挂进 `server.clients_pending_write`(networking.c:261-270)。真正写 socket 发生在**本轮事件循环的 beforeSleep**:`handleClientsWithPendingWrites()`(server.c:1915→networking.c:2246-2283)同步尽力写 `writeToClient`(networking.c:2147);写不完才安装 AE_WRITABLE handler(networking.c:2279→237-252)留待下轮。若配置 `appendfsync=always`,安装写 handler 时会加 **AE_BARRIER**(networking.c:244-248),保证同一 fd 在同一轮内"先 fsync AOF 再写回复",这就是"看应答必已落盘"语义的实现点。

### 3.5 事件循环的一轮:把所有角色放到时间轴上

```
                    ┌──────────── 主线程一轮循环(可能有 N 个客户端、M 条命令)────────────┐
 t0  beforeSleep    │ 快速过期(activeExpireCycle FAST, 仅 master)                      │
                    │ blockedBeforeSleep(唤醒等 key/等锁/等 AOF 的客户端)               │
                    │ flushAppendOnlyFile(AOF 落盘/延迟 fsync 策略)                    │
                    │ handleClientsWithPendingWrites(批量写回全部就绪回复)              │
                    │ freeClientsInAsyncFreeQueue / 增量裁剪复制积压缓冲 / evictClients │
                    │ aeSetDontWait(如有 TLS 残留/IO 线程有活,本轮不睡)                │
                    │ moduleReleaseGIL(模块线程放行)                                   │
 t1  aeApiPoll      │ 睡眠,直到任一 fd 就绪或最近时间事件到期                          │
 t2  afterSleep     │ moduleAcquireGIL(收回数据所有权) → 更新时间缓存/循环计时          │
 t3  文件事件       │ accept → createClient;read → 解析+安检+call()                    │
                    │ (一条连接一次可解析执行多条命令, 即 pipeline)                     │
 t4  时间事件       │ 到期则 serverCron(默认每 100ms 一轮)                             │
 t0' 回到 beforeSleep│                                                                 │
                    └───────────────────────────────────────────────────────────────────┘
```

这张图能同时回答三个高频问题:为什么 Redis 不需要"写线程"也能把回复写出去(t0 的批量写);为什么 pipeline 一批命令只需一次网络往返(所有命令在 t3 被同一份读缓冲消化,回复在下一个 t0 一次写完);为什么 appendfsync=always 语义可以做到"收到回复即已落盘"(t0 里 AOF flush 排在写回之前,配合 AE_BARRIER)。

```
socket 字节 → readQueryFromClient(networking.c:3006)
  → querybuf(networking.c:3082) → processInputBuffer(2892)解析 argv
  → processCommand(server.c:4072)安检流水线
  → call(3711) → c->cmd->proc(c)(3757) [setCommand t_string.c:294]
  → addReply 进输出缓冲 → beforeSleep: handleClientsWithPendingWrites
  → writeToClient(2147); 写不完 → 下轮 WRITABLE 事件
```

---

## ④ serverCron:hz 机制与定时任务清单

### 4.1 调度机制

serverCron 是 ae 的**时间事件**(server.c:2939 注册),源码自述(server.c:1406-1423):"我们的定时中断,每秒执行 server.hz 次"。它的返回值就是下次超时间隔:

```c
server.hz = server.config_hz;                    /* 1435 */
if (server.dynamic_hz) {                         /* 1438 */
    while (listLength(server.clients) / server.hz >
           MAX_CLIENTS_PER_CLOCK_TICK)
    {
        server.hz *= 2;
        if (server.hz > CONFIG_MAX_HZ) { server.hz = CONFIG_MAX_HZ; break; }
    }
}
...
return 1000/server.hz;                           /* 1689 */
```

即 `hz` 默认 10(server.h:124,间隔 100ms),允许 1~500(server.h:125-126);**动态 hz**:客户端数/hz 超过 200(server.h:127)就翻倍,保证每轮 cron 摊到每个客户端不超过 1/200 秒的检查预算。低频任务用 `run_with_period(ms)` 宏节流(server.h:766,本质是 `cronloops` 计数取模),例如 `run_with_period(1000)` 表示约每秒一次。加载 RDB/AOF 或脚本阻塞期间由 `whileBlockedCron`(server.c:1711-1751)顶替 serverCron 的部分职责:它把阻塞经历的真实时长换算成"补跑的 cron 轮数"加进 `cronloops`(server.c:1726-1729),使 run_with_period 在恢复后不会瞬间补齐执行,同时又保住两个无法推迟的职责——AOF 加载中的碎片整理与加载期内存统计(server.c:1734-1738),以及加载期收到 SIGTERM 的安全关机(server.c:1745-1750)。

### 4.2 每轮都做什么(server.c:1425-1690)

| 周期 | 任务 | 行号 |
|---|---|---|
| 每轮 | 软件看门狗 SIGALRM 调度;hz 重算;`server.lruclock` 更新 | 1433,1435,1490 |
| 100ms | 瞬时指标采样(QPS/网络吞吐/事件循环耗时) | 1455-1477 |
| 每轮 | `cronUpdateMemoryStats`:RSS/allocator 碎片率(采样本身慢,内部限 100ms 一次) | 1492→1367-1404 |
| 每轮 | SIGINT/SIGTERM → `prepareForShutdown`(信号 handler 里只置标志,安全收尾搬到这里) | 1496-1511 |
| 5s | DB/客户端信息 VERBOSE/DEBUG 日志 | 1514-1538 |
| 每轮 | `clientsCron()`:遍历客户端,超时、querybuf/replybuf 收缩 | 1541 |
| 每轮 | `databasesCron()`:**慢速主动过期** `activeExpireCycle(SLOW)`(仅 master,server.c:1200-1209)、主动碎片整理、渐进 resize/rehash | 1544 |
| 每轮 | AOF 改写排期、子进程收尸 `checkChildrenDone`(1000ms 收进度) | 1548-1559 |
| 每轮 | 按 saveparams 触发 BGSAVE;AOF 增长超 `aof_rewrite_perc` 触发重写 | 1563-1598 |
| 每轮 | AOF 延迟 flush 重试;1000ms 一次写错误后的重试 | 1606-1622 |
| 1000ms | `replicationCron`(failover 时 100ms) | 1632-1636 |
| 100ms | `clusterCron` / `modulesCron` | 1639-1641,1675-1677 |
| 每轮 | sentinelTimer(仅 sentinel 模式)、MIGRATE 超时 socket 清理(1000ms) | 1644,1647-1649 |
| 每轮 | 延迟排期的 BGSAVE(等 AOF 重写结束后补跑)、CRON_LOOP 模块事件 | 1664-1673,1680-1683 |

注意:**快速主动过期 `activeExpireCycle(FAST)` 不在 serverCron 而在 beforeSleep**(server.c:1830-1831),每轮事件循环都试,与 cron 的慢速周期互补。

serverCron 的函数头注释(server.c:1406-1423)是官方任务清单,值得整段读一遍:它把 cron 定位成"需要异步完成的大量杂事的增量执行器",并明确 run_with_period 的节流模型——直接写在函数体里的语句每 1/hz 秒执行一次,包进宏里的语句按毫秒周期执行。因此改 hz 会同时改变所有任务的绝对频率,但 run_with_period 任务之间的相对节奏不变(它的实现 `1000/server.hz` 取模,server.h:766,依赖 cronloops 计数而非墙钟)。

---

## ⑤ 设计动机与取舍

1. **单线程命令执行 + 事件循环周边**:call() 只被主线程(或持锁语境)调用,`server.executing_client` 等状态无需加锁;复杂度被推到边界——磁盘 IO 交给 bio 子进程(fork)、大 value 读写交给 IO 线程(networking.c:2950-2960 里 IO 线程只做解析与预查命令 `iolookedcmd`,执行仍回主线程)。这是吞吐与实现复杂度之间的经典折中。
2. **beforeSleep 承担"批处理尾巴"**:AOF fsync、写回 socket、快速过期、异步 free 全部集中在每轮睡眠前,把 N 条命令的收尾摊销成一次系统调用级批量操作;`aeSetDontWait`(server.c:1955)在 TLS 缓冲有残留时干脆不睡眠,避免延迟尖刺。
3. **initServerConfig 先于配置加载**:命令表必须先存在才能执行 `rename-command`;配置系统的定位是"对默认值的覆盖",因此 `initConfigValues()` 在 initServerConfig 第一行(server.c:2205),`loadServerConfigFromString` 只是 setter 回调。
4. **命令表声明式生成**:409 个 JSON(src/commands/,如 set.json 描述参数树)由 `utils/generate-command-code.py` 生成 commands.def(首行即 "Automatically generated by generate-command-code.py, do not edit",11525 行)。以 GET 为例,def 里一行 MAKE_CMD 展开后就是完整元数据(commands.def:11499):`getCommand, arity=2, CMD_READONLY|CMD_FAST, ACL_CATEGORY_STRING, GET_Keyspecs(key 位置 1, 只读+访问)`。`struct redisCommand`(server.h:2582-2633)把"声明数据"(summary/arity/flags/key_specs/acl_categories)与"运行时数据"(calls/microseconds/id/fullname/直方图/legacy_range_key_spec)分开,后者由 `populateCommandStructure`(server.c:3214,含 ACL id 分配 server.c:3235 与 legacy keyspec 回推 server.c:3160-3169)在启动时补齐。收益:ACL 位图校验、COMMAND 子命令文档、集群 key 提取、RESP3 协议请求/响应日志全部由元数据驱动,新增命令只需写一个 JSON + 一个 proc 函数。
5. **拒绝即框架能力**:processCommand 十几道安检全部走 `rejectCommand*` 统一出口(server.c:3944),保证事务脏标记、统计、错误回复三件事不被遗漏。
6. **查询缓冲与输出缓冲的分层预算**:读侧可复用 querybuf(networking.c:3050-3061)+1MB 上限,写侧定长 buf+链表+软硬上限,`maxmemory-clients` 用 mem_usage buckets(networking.c:225-226, server.c:2981-2982)——框架把"恶意/慢客户端"当成一类常态输入来设计。
7. **统计驱动而非事后推断**:命令耗时(slowlog/latency)、错误计数(`incrCommandStatsOnError` 区分 rejected_calls/failed_calls,server.c:3652-3669)、事件循环周期耗时(server.c:1937-1951 三段计时:AOF 前的 cron 段、AOF 段、写回段)都在框架路径上就地采样。代价是 call() 尾部十余行统计代码常驻热路径;收益是 INFO commandstats、LATENCY HISTOGRAM 等可观测能力无需外挂。
8. **防御性对称**:lookup 时防 `host:`/`post` 注入(server.c:4113-4117)、errorstats 防 Lua error_reply 刷爆 rax(超 128 种错误自动禁用统计,server.c:4477-4511)、tracking 槽位上限(每轮 cron 与每条命令前都收,server.c:1655, 4281)。框架层假设所有输入(含内部模块)都可能失控,校验与限额全部前置在 processCommand/beforeSleep,而不是依赖各命令实现自律。
9. **删除即延迟**:整个生命周期里没有一条"立即释放复杂对象"的路径——客户端异步 free、错误表用 `freeErrorsRadixTreeAsync`(server.c:3302-3306)、大 argv 的引用计数交由 IO 线程延迟回收(`tryDeferFreeClientObject`,networking.c:1481-1493)。单线程模型下,任何同步释放大对象都会直接变成尾延迟,框架宁可增加状态机复杂度也要把释放动作挪出关键路径。

---

## ⑥ 容易误解的点与面试级 FAQ

**Q1:Redis 是单线程吗?**
A:命令执行(含 call/proc)是主线程单线程;但 serverCron 也在主线程。bio 子线程(AOF fsync/关闭文件/lazy free)、IO 线程(io_threads_num>1 时参与读解析与写回)、模块线程、jemalloc 后台线程都存在。所以准确说法是"单命令执行线程的事件循环模型"。

**Q2:serverCron 到底多久跑一次?**
A:默认 100ms(hz=10)。返回值 `1000/server.hz` 就是下一次间隔(server.c:1689);dynamic-hz 会随客户端数翻倍至最高 500(server.c:1438-1448)。`CONFIG SET hz` 改的是 `config_hz`。

**Q3:beforeSleep 和 afterSleep 各干什么,为什么成对出现?**
A:beforeSleep 在 aeApiPoll 之前(server.c:1777):AOF flush、批量写回、快速过期、处理阻塞客户端、异步释放;afterSleep 在 poll 返回之后(server.c:1969):**先获取模块 GIL**(server.c:1974-1988,配对的 moduleReleaseGIL 在 beforeSleep 末尾且注释禁止其后再加代码,server.c:1960-1963)、更新时间缓存与事件循环计时。GIL 一放一收保证模块后台线程只在 Redis 睡眠时碰数据。

**Q4:为什么 SIGTERM 处理函数里不直接 shutdown?**
A:信号 handler 里只能做异步安全操作。handler 只置 `server.shutdown_asap` 原子标志,真正的 `prepareForShutdown` 在下一轮 serverCron(server.c:1496-1505)。

**Q5:加载 RDB/AOF 期间服务器完全不可用吗?**
A:不是完全。加载循环里周期调用 `whileBlockedCron`(server.c:1711),并通过 `processEventsWhileBlocked` 处理部分客户端事件,beforeSleep 里也有专门的重入短路分支(server.c:1787-1804),但会跳过过期等高危操作——这就是 `CMD_LOADING` 标志决定的命令白名单存在的原因(server.c:4360-4363)。

**Q6:客户端对象一定对应一条 TCP 连接吗?**
A:不一定。`createClient(conn==NULL)` 用于 Lua 脚本(`CLIENT_SCRIPT`)、模块(`CLIENT_MODULE`)、AOF 加载假客户端(`CLIENT_ID_AOF`,server.c:107-108),复用同一套 processCommand/call 框架(networking.c:124-127)。

**Q7:freeClient 可以在任何地方直接调用吗?**
A:不行。当前正在服务的 client、被 IO 线程持有的 client、带 CLIENT_PROTECTED 的 client 都必须走 `freeClientAsync`(networking.c:1909-1928):标记 CLOSE_ASAP 挂入 `server.clients_to_close`,由 beforeSleep 的 `freeClientsInAsyncFreeQueue`(server.c:1924)统一释放,避免悬垂引用。

**Q8:命令查找为什么快?每次都是 dict 查询吗?**
A:三级优化:`isCommandReusable` 直接复用 lastcmd(无子命令且同名,server.c:100-104);IO 线程解析阶段已预查 `iolookedcmd`(networking.c:2952);兜底才 `lookupCommand` 走 dict。另外同名子命令(CONFIG/MODULE)只支持一层(server.c:3377)。

**Q9:`GET` 会触发数据驱逐,OOM 时会拒绝 GET 吗?**
A:不会。OOM 拒绝只针对 `CMD_DENYOOM` 命令:SET 带 `CMD_WRITE|CMD_DENYOOM`(commands.def:11512),GET 只有 `CMD_READONLY|CMD_FAST`(commands.def:11499)。但 processCommand 里 `performEvictions()` 对读命令同样会执行(server.c:4253),只是 GET 不会被拒。

**Q10:CONFIG SET multi 参数是原子的吗?**
A:是。configSetCommand 先备份所有旧值(config.c:883-884),统一 set(不 apply,config.c:887-896),再统一 apply;任一 set/apply 失败则 `restoreBackupConfig` 回滚(config.c:890, 910)。SENSITIVE 配置(如 requirepass)即使失败也会先把参数从 slowlog/monitor 中脱敏(config.c:841-843)。

**Q11:SET 的回复一定在 SET 执行完就发出去吗?**
A:不是。执行完只进了输出缓冲;真正写 socket 在同一轮事件循环的 beforeSleep(通常同一次 syscall 批量写),仅当内核发送缓冲写不下才注册 WRITABLE 事件延迟发送(networking.c:2276-2280)。这正是 pipeline 高效的原因:多条命令的回复在 beforeSleep 一次性写出。

**Q12:rename-command 改名后,ACL 和集群内部怎么办?**
A:`server.commands` 被改名,但 `server.orig_commands` 保留原名(initServerConfig 中两者同时填充,server.c:2326-2327;改名逻辑 config.c:525-548);`lookupCommandOrOriginal`(server.c:3434)供内部按原名查找。ACL 的命令 id 在 populateCommandStructure 阶段按 fullname 分配(server.c:3235),改名发生在其后的配置加载,故 ACL 规则按新名写。

---

## ⑦ 深挖问题清单(后续章节可展开)

1. **IO 线程的 fan-in/fan-out 边界**:IO 线程解析完命令后 `enqueuePendingClientsToMainThread` 回交主线程执行(networking.c:2950-2960),`iolookedcmd`/`getSlotFromCommand` 的预计算节省了什么?`beforeSleep` 里 `processClientsOfAllIOThreads` 与 `server.running` 原子标志(server.c:1898-1912)如何防止双线程同时消费同一客户端?
2. **hash field 过期(estore)**:`server.db[j].subexpires = estoreCreate(...)`(server.c:2856)是 8.x 引入的字段级过期结构,它与 `expires` kvstore 在 `activeExpireCycle`、写命令传播(AOF/复制如何表达字段级 TTL)上的分工值得单独一章。
3. **阻塞期事件循环的精确语义**:`ProcessingEventsWhileBlocked` 重入路径下 beforeSleep 只做 4 件"低危事"(server.c:1787-1804 注释),`CLIENT_BLOCKED` 的客户端在 `blockedBeforeSleep`(server.c:1821)中如何被唤醒、其命令如何被 CLIENT_REEXECUTING_COMMAND 标记重放(server.c:3726)?
4. **连接类型抽象**:`connTypeInitialize/initListeners/connListen`(server.c:7405, 2985-3055)如何让 TCP/TLS/Unix 共享 accept 流程,`connTypeProcessPendingData`(server.c:1807)处理的"TLS 手 conducting 中间态数据"是什么?
5. **客户端驱逐(client eviction)与数据驱逐的耦合**:`evictClients` 同时出现在 processCommand(server.c:4241)与 beforeSleep(server.c:1932)两处,`client_mem_usage_buckets`(server.c:2182-2199)基数桶如何支撑 O(1) 找到大客户端?"驱逐了自己"时 processCommand 返回 C_ERR 的收尾路径(server.c:4242-4245)对 pipeline 中已解析命令意味着什么?

---

### 推荐的源码阅读路线(半小时版)

若要把本篇内容在源码上走一遍,建议按数据流顺序阅读:`main()`(server.c:7325 只看阶段注释)→ `initServer()`(2769 只看 2833-2955)→ `aeMain/aeProcessEvents`(ae.c:492/360)→ `beforeSleep/afterSleep`(server.c:1777/1969 只看任务清单)→ `readQueryFromClient`(networking.c:3006)→ `processCommand`(server.c:4072)→ `call`(server.c:3711)→ `serverCron`(server.c:1425)。全程约 1500 行有效代码,即可把"字节进、字节出、定时器跑"三条通路全部闭合;其余文件(持久化、复制、集群、阻塞)都可以在需要时从这四个入口按调用链下钻。

### 附:本篇实际核对过的关键符号索引

main(server.c:7325)、initServerConfig(2201)、initServer(2769)、initListeners(2985)、InitServerLast(3062)、serverCron(1425)、beforeSleep(1777)、afterSleep(1969)、call(3711)、processCommand(4072)、rejectCommand(3944)、lookupCommandLogic(3366)、populateCommandTable(3257)、loadDataFromDisk(7046)、whileBlockedCron(1711)、databasesCron(1200)、cronUpdateMemoryStats(1367);createClient(networking.c:121)、acceptCommonHandler(1402)、readQueryFromClient(3006)、processInputBuffer(2892)、freeClient(1728)、freeClientAsync(1909)、handleClientsWithPendingWrites(2246)、writeToClient(2147);loadServerConfigFromString(config.c:432)、loadServerConfig(644)、configSetCommand(801)、embedConfigInterface(1796);struct redisCommand(server.h:2582)、run_with_period(server.h:766)、CONFIG_DEFAULT_HZ(server.h:124);setCommand/getCommand(t_string.c:294/336);GET/SET 元数据(commands.def:11499/11512)。
