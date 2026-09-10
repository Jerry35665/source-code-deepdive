# D · 事件循环与网络 IO

> 调研对象:redis unstable 分支,commit e8726d18(2025-09-15,8.x 世代代码,version.h 中 255.255.255 为开发标记)。
> 本文所有结论均来自对下列文件的实际逐行阅读:`src/ae.c`、`src/ae.h`、`src/ae_epoll.c`、`src/ae_select.c`、`src/ae_kqueue.c`、`src/ae_evport.c`、`src/networking.c`、`src/iothread.c`、`src/anet.c`、`src/connection.c`、`src/socket.c`,以及 `src/server.c`/`src/server.h`/`src/config.c` 中的相关片段。

一个重要的"版本锚点"必须先说明:**unstable 分支上的网络 IO 层已经发生了代际重写**。网上大量资料(包括一些 8.0 的书籍)描述的"io-threads-do-reads、旧式多路分发 io_threads"已经不存在了:2024 年起 Redis 引入了 `src/iothread.c`,每个 IO 线程拥有**独立的事件循环**,主线程只做命令执行,IO 线程做读写与协议解析;`io-threads-do-reads` 配置项已被列入废弃列表(`config.c:437`),`io-threads` 默认仍为 1(`config.c:3183`)。本文以 unstable 实际代码为准,并在第 ⑤ 节专门梳理新旧两代设计。

---

## ① 事件模型全景:单线程为什么够快,哪些工作不在主线程

### 1.1 单线程的边界在哪里

Redis 的"单线程"指的是**命令执行 + 事件调度**发生在主线程的一个 `aeEventLoop` 上(`server.c:7665` 处 `aeMain(server.el)`)。但下列工作从来就不在主线程的事件循环里:

| 工作 | 线程 | 证据 |
|---|---|---|
| AOF fsync、lazy-free 异步释放 | BIO 后台线程 | `bio.c`(不在本文范围,仅提及) |
| RDB/AOF rewrite 子进程 | fork 子进程 | — |
| 模块后台任务 | 模块自建线程 | — |
| **网络 IO(读+写)+ RESP 解析**(可选,`io-threads>1`) | IO 线程池 | `iothread.c:707-718`(`IOThreadMain` 各跑一个 `aeMain`) |
| 命令执行、过期删除、逐出、客户端管理 | 仅主线程 | `iothread.c:145-154`(`isClientMustHandledByMainThread`)、`iothread.c:409` 注释"IO threads never free client" |

单线程之所以够快,核心原因是 Redis 的每请求 CPU 开销极小:一条 `SET` 从字节进内核到回复写回,主线程只做"一次解析 + 一次字典写入 + 组装约 7 字节回复";真正可能阻塞的 syscall(read/write)在数据已就绪时几乎不耗时。网络栈的剩余开销(协议上下文切换、TLS、大 value 拷贝)则被拆给 IO 线程或优化掉(见 ④ 的零拷贝 bulk 接管)。

### 1.2 ae 库的定位

`ae` 是一个极简事件库,源自 antirez 早年的 Jim(Tcl 解释器)事件循环(`ae.c:1-3` 的头注释)。它只有文件事件、时间事件、before/after-sleep 钩子三样东西(`ae.h:30-35` 的 `AE_FILE_EVENTS/AE_TIME_EVENTS/AE_DONT_WAIT/AE_CALL_BEFORE_SLEEP/AE_CALL_AFTER_SLEEP`)。多路复用后端通过**直接 `#include` 对应的 `.c` 文件**在编译期确定,优先级 evport > epoll > kqueue > select(`ae.c:30-44`):

```c
/* Include the best multiplexing layer supported by this system.
 * The following should be ordered by performances, descending. */
#ifdef HAVE_EVPORT
#include "ae_evport.c"
#else
    #ifdef HAVE_EPOLL
    #include "ae_epoll.c"
    ...
```

没有函数指针表、没有运行时切换——四个后端文件各自实现同名的五个静态函数(`aeApiCreate/Resize/Free/AddEvent/DelEvent/Poll/Name`),谁被 include 谁生效。

---

## ② ae 事件循环逐段解读

### 2.1 核心数据结构(`ae.h:79-93`)

```c
typedef struct aeEventLoop {
    int maxfd;   /* 当前注册的最大 fd */
    int setsize; /* 容量上限 */
    long long timeEventNextId;
    int nevents; /* events/fired 数组当前实际长度(可增长) */
    aeFileEvent *events; /* 以 fd 为下标的事件表 */
    aeFiredEvent *fired; /* 本轮 poll 的就绪事件 */
    aeTimeEvent *timeEventHead;
    int stop;
    void *apidata;          /* 后端私有状态(epfd 等) */
    aeBeforeSleepProc *beforesleep;
    aeBeforeSleepProc *aftersleep;
    int flags;
    void *privdata[2];      /* IO 线程用它反向挂 IOThread 结构 */
} aeEventLoop;
```

每个 fd 的事件是定长结构 `aeFileEvent{mask, rfileProc, wfileProc, clientData}`(`ae.h:52-57`),读/写各存一个回调,同一个 fd 读写可以是不同回调(实际上是同一个 `connSocketEventHandler`,`connection.c:395`)。

事件掩码:`AE_READABLE=1`、`AE_WRITABLE=2`、`AE_BARRIER=4`(`ae.h:22-28`)。**AE_BARRIER 是理解 AOF 一致性的关键**:它要求同一轮迭代中该 fd 的写事件不得在读事件之后触发,从而保证"先 fsync AOF,再回复客户端"(`ae.h:24-28` 注释;`networking.c:237-252` 中 fsync=always 时安装写 handler 必带 barrier)。

### 2.2 注册/注销文件事件

`aeCreateFileEvent`(`ae.c:145-179`)有几个值得注意的工程细节:

- `fd >= setsize` 直接返回 `AE_ERR`(`ae.c:148-151`),上限在 `initServer` 时由 `maxclients + CONFIG_FDSET_INCR` 决定(`server.h:203`);
- **events 数组惰性增长**:初始只分配 `min(setsize, 1024)` 个槽(`ae.c:46,54-56`),注册高 fd 时倍增扩容并初始化新槽为 `AE_NONE`(`ae.c:155-166`)——这省掉了为百万 maxclients 预分配的内存;
- 注销时若删除 `AE_WRITABLE` 则连带删除 `AE_BARRIER`(`ae.c:187-189`);
- 删事件后若 fd 恰是 maxfd,线性向下重算 maxfd(`ae.c:193-200`),这是个 O(N) 但极少触发的操作。

### 2.3 时间事件:不用堆,而是一条无序双向链表

时间事件结构 `aeTimeEvent` 是双向链表节点,带 `refcount` 防止递归回调中释放自身(`ae.h:60-70`)。`aeCreateTimeEvent` 直接**头插 O(1)**(`ae.c:232-237`),`aeDeleteTimeEvent` 只把 `id` 改成 `AE_DELETED_EVENT_ID` 做惰性删除(`ae.c:241-252`),真正的摘链发生在 `processTimeEvents` 里。

计算"距最近定时器还有多久"的 `usUntilEarliestTimer` 是 **O(N) 全表扫描**(`ae.c:263-276`),作者在注释里明说了权衡:

```c
/* Note that's O(N) since time events are unsorted.
 * Possible optimizations (not needed by Redis so far, but...):
 * 1) Insert the event in order, so that the nearest is just the head. ...
 * 2) Use a skiplist to have this operation as O(1) and insertion as O(log(N)). */
```

**为什么 Redis 不用堆**:因为 Redis 主循环里长期存在的定时器屈指可数——主线程只有 `serverCron` 一个(`server.c:2939` 的 `aeCreateTimeEvent(server.el, 1, serverCron, NULL, NULL)`),IO 线程各自只有一个 `IOThreadCron`(`iothread.c:765`)。N≈1~2 时,O(N) 扫描快过任何堆的 cache 不友好路径,还免掉堆的插入/删除开销。这是典型的"按真实规模选数据结构"。注意 Redis **没有**把每个客户端的超时检查做成定时器,而是统一塞进 serverCron 的周期扫描——如果做成 per-client timer,ae 的这个设计才会真正成为瓶颈。

`processTimeEvents`(`ae.c:279-343`)还有两道防线:`maxId` 检查防止"本轮回调中新建的时间事件"被立即执行(`ae.c:315-323`,注释自承当前实现头插使该检查冗余,保留作防御);回调返回值非 `AE_NOMORE` 则按返回的毫秒数重设 `when`(`ae.c:334-338`),`serverCron` 就是用返回值 `1000/hz` 实现周期。

### 2.4 aeProcessEvents:一轮迭代的完整骨架(`ae.c:360-468`)

```c
if (eventLoop->beforesleep != NULL && (flags & AE_CALL_BEFORE_SLEEP))
    eventLoop->beforesleep(eventLoop);          /* 1. 睡前钩子 */
...
if ((flags & AE_DONT_WAIT) || (eventLoop->flags & AE_DONT_WAIT)) {
    tv.tv_sec = tv.tv_usec = 0; tvp = &tv;      /* 2. 不等待则 timeout=0 */
} else if (flags & AE_TIME_EVENTS) {
    usUntilTimer = usUntilEarliestTimer(eventLoop);  /* 3. 睡到下个定时器 */
    ... }
numevents = aeApiPoll(eventLoop, tvp);          /* 4. 唯一阻塞点 */
...
if (eventLoop->aftersleep != NULL && flags & AE_CALL_AFTER_SLEEP)
    eventLoop->aftersleep(eventLoop);           /* 5. 睡后钩子 */
for (j = 0; j < numevents; j++) { ... }         /* 6. 逐个触发文件事件 */
if (flags & AE_TIME_EVENTS)
    processed += processTimeEvents(eventLoop);  /* 7. 时间事件 */
```

fired 事件的分发循环(`ae.c:409-461`)有 3 个精心处理过的坑:

1. **先读后写**:正常顺序是先 `rfileProc` 后 `wfileProc`,这样一条查询处理完能立刻在同一个 fd 上把回复写出去(`ae.c:415-419` 注释);
2. **BARRIER 反转**:`int invert = fe->mask & AE_BARRIER;`(`ae.c:426`)置位时先写后读——AOF fsync=always 的客户端必须先落盘再处理新读;
3. **失效事件防御**:`fe->mask & mask & AE_READABLE` 的双重与(`ae.c:434`)——前面回调可能已经删除/关闭了后面仍在本轮 fired 数组里的 fd,必须确认事件仍然注册着才调用;回调后还要 `fe = &eventLoop->events[fd]` 重新取指针,防止处理期间数组被 realloc(`ae.c:437`)。还有一个小细节:若同一 fd 的读写回调是同一个函数,只调用一次(`ae.c:441-445` 的 `fe->wfileProc != fe->rfileProc` 判断)。

`aeMain` 本体只有 4 行(`ae.c:492-499`):`while (!stop) aeProcessEvents(AE_ALL_EVENTS|BEFORE|AFTER)`。`aeWait` 则是给阻塞场景(如同步 connect)用的独立 `poll()` 封装,`POLLERR/POLLHUP` 都映射为 `AE_WRITABLE`(`ae.c:472-490`),让上层按"可写"去 `write` 拿到真实 errno。

### 2.5 四个后端的差异速览

- **epoll**(`ae_epoll.c`):`epoll_create(1024)` 只是内核提示(`ae_epoll.c:28`);ADD/MOD 按 `events[fd].mask == AE_NONE` 区分并合并旧 mask(`ae_epoll.c:59-64`);删除时若还剩 mask 则用 MOD 降权而非 DEL(`ae_epoll.c:74-86`,为兼容 kernel<2.6.9 的非空 event 指针要求);`EPOLLERR/EPOLLHUP` 映射为 `READABLE|WRITABLE`(`ae_epoll.c:105-106`),错误最终由 read/write 的 errno 收敛;`epoll_wait` 超时把微秒向上取整为毫秒(`ae_epoll.c:94`);EINTR 静默重试,其余错误直接 `panic`(`ae_epoll.c:110-112`)。
- **select**(`ae_select.c`):因为 select 会破坏传入的 fd_set,内部维护副本 `_rfds/_wfds` 每轮 memcpy(`ae_select.c:16-19,62-63`);poll 后 O(maxfd) 全表扫描(`ae_select.c:68`);`setsize >= FD_SETSIZE` 直接失败(`ae_select.c:35`)。
- **kqueue**(`ae_kqueue.c`):读/写是两个独立 filter(`EVFILT_READ/EVFILT_WRITE`,`ae_kqueue.c:102-115`);额外用一个 `char*` 按 2 bit/fd 压缩存储事件掩码以合并读写(`ae_kqueue.c:40-48`)。
- **evport**(`ae_evport.c`):Solaris 事件端口是"一次关联一次触发",poll 返回后 fd 自动解除关联,需要重新 `port_associate`;为此维护 `pending_fds/pending_masks` 处理"poll 刚返回、还没重新关联"窗口内的增删请求(`ae_evport.c:111-120,154-209`)。

### 2.6 一次 aeMain 迭代的时序(以主线程、无 IO 线程、AOF everysec 为例)

```
                         ┌─────────────── aeMain (server.c:7665) ───────────────┐
                         │                                                      │
 [一轮迭代 aeProcessEvents ae.c:360]                                             │
                         │                                                      │
 1. beforeSleep          │  clusterBeforeSleep → blockedBeforeSleep(唤醒阻塞客户端)
    (server.c:1777)      │  → activeExpireCycle(FAST) → flushAppendOnlyFile(0)
                         │  → handleClientsWithPendingWrites  ← ★回复在这里写!
                         │      │写不完的客户端 installClientWriteHandler
                         │  → freeClientsInAsyncFreeQueue → evictClients
                         │  → aeSetDontWait → moduleReleaseGIL
                         ▼
 2. 计算 timeout = min(到下个时间事件, 默认无限)   (ae.c:385-395)
                         ▼
 3. aeApiPoll = epoll_wait(...)  ◄── 唯一可能 sleep 的地方
                         ▼
 4. afterSleep           │  moduleAcquireGIL → updateCachedTime (server.c:1969)
                         ▼
 5. for fired[] 事件     │  accept 处理器(connSocketAcceptHandler,≤10 连接/轮)
    (ae.c:409-461)       │  readQueryFromClient → processInputBuffer → processCommand
                         │      (回复进 client->buf/reply,客户端挂入 pending_write)
                         ▼
 6. processTimeEvents    │  serverCron(hz 次每秒: 超时/重统计/repl 检查…)
   (ae.c:279-343)        │
                         └──────────────────── 回到 1 ─────────────────────────┘
```

注意"写回复"发生在两处:**beforeSleep 里**批量直写(绝大多数情况,免一次 epoll_ctl 注册),写不完的少数客户端才装 WRITABLE 事件等下一轮(`networking.c:2246-2283`);这正是 Redis 低延迟的关键之一。

---

## ③ 一条 SET 命令的字节级旅程

以 `redis-cli SET key value` 为例,RESP 报文:`*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n`(共 34 字节)。

**(0) 建连**。accept 发生在监听 fd 的读事件:`connSocketAcceptHandler` 一轮最多 accept `max-new-connections-per-cycle`(默认 10)个(`socket.c:301-321`,`config.c:3225`),用 `accept4(SOCK_NONBLOCK|SOCK_CLOEXEC)` 一步拿到非阻塞 fd(`anet.c:604-631`)。`acceptCommonHandler` 检查 maxclients 超限时直接写一行错误并关闭(`networking.c:1423-1442`),随后 `createClient`:**立即 `connEnableTcpNoDelay`**、按 `tcp-keepalive` 配置(默认 300)设 `SO_KEEPALIVE + TCP_KEEPIDLE/INTVL/KEEPCNT=3`(`networking.c:128-133`;`anet.c:212-252`,注释点名 Linux 默认 7200s "more or less garbage"),注册读 handler 为 `readQueryFromClient`(`networking.c:132`)。IO 线程开启时新连接在 `clientAcceptHandler` 末尾被 `assignClientToIOThread` 分给最闲的线程(`networking.c:1398-1399`,`iothread.c:158-185`)。

**(1) 读**。epoll 报 `EPOLLIN` → `readQueryFromClient`(`networking.c:3006`)。默认 `readlen = PROTO_IOBUF_LEN = 16KB`(`server.h:189`)。本命令是小命令,客户端首次读时领到的是**线程级可复用查询缓冲** `thread_reusable_qb`(一个 `__thread` 全局 sds,`networking.c:36-38`):所有客户端轮流复用同一块 16KB 缓冲,读完后若缓冲已被裁剪干净则归还(`networking.c:3042-3061`、`resetReusableQueryBuf` `networking.c:1709-1726`),把"每客户端 16KB"的内存放大器压成"每线程 16KB"。`connRead`(即 `read(2)`,`connection.c:165-180`)一次读入 34 字节,`sdsIncrLen` 收尾,`stat_net_input_bytes` 累加(`networking.c:3097-3108`)。

**(2) 解析**。`processInputBuffer`(`networking.c:2892`)进入 while 循环:首字节 `*` → `reqtype = PROTO_REQ_MULTIBULK`(`networking.c:2916-2922`)。`processMultibulkBuffer`(`networking.c:2510`)分两步:先读 `*3` 得 `multibulklen=3`——注意有两条"未认证防护":参数个数 >10 或 bulk 长度 >16384 时,未认证连接直接按协议错误断开(`networking.c:2541-2544,2627-2630`);再循环读每个 `$n` 头与 body,`string2ll` 严格校验数字(`networking.c:2622`)。body 长度还要过 `proto-max-bulk-len`(默认 512MB,`config.c:3242`)这道闸。三个参数各生成一个 `robj` 挂到 `c->argv`(`networking.c:2697-2698`)。若是 ≥32KB(`PROTO_MBULK_BIG_ARG`,`server.h:192`)的大参数且缓冲里恰好只有这一个参数,则**不再拷贝,直接把 querybuf 的 sds 接管为 argv 对象**,再新分配缓冲继续读(`networking.c:2679-2694`)——这是输入路径上最重要的零拷贝优化。

**(3) 执行**。回到循环,`processCommandAndResetClient` 置 `server.current_client` 后调 `processCommand`(`server.c:4072`;包装见 `networking.c:2766-2790`)。`setCommand → setGenericCommand`(`t_string.c:73,304`)写入字典,然后 `addReply(c,shared.ok)`——`shared.ok` 是预创建的 `"+OK\r\n"` 共享对象(`server.c:2015`)。`addReply`(`networking.c:448`)对整数编码对象还有专门的 `ll2string` 快路径(`networking.c:453-459`)。

**(4) 组装回复**。`_prepareClientToWrite`(`networking.c:281-313`)放行(非 SCRIPT/MODULE、非 CLOSE_ASAP、非 REPLY_OFF、非 MASTER),并把客户端挂入 `server.clients_pending_write` 链表(**注意:此时并未注册写事件**,`putClientInPendingWriteQueue` `networking.c:261-279`)。`_addReplyToBufferOrList`(`networking.c:393-440`)把 7 字节 `+OK\r\n` 拷进客户端的**静态回复缓冲** `c->buf`(16KB,创建时 `zmalloc_usable(PROTO_REPLY_CHUNK_BYTES)` 分配,`networking.c:135`);若 reply 链表已有节点则不能再写静态缓冲,统一走 `_addReplyProtoToList` 的 16KB 块节点(`networking.c:347-381`),每次追加后即时检查 `client-output-buffer-limit`(`networking.c:379`)。

**(5) 写回**。本轮事件处理完后进入 beforeSleep:`handleClientsWithPendingWrites`(`networking.c:2246`)摘下该客户端直接 `writeToClient(c,0)`——这是"**写直出**"优化:绝大多数小回复在进入 epoll_wait 之前就写出去了,连 WRITABLE 事件都不用注册。`_writeToClientNonSlave`(`networking.c:2083`)发现 reply 链表为空,走单次 `connWrite(c->buf + sentlen)`;只有写不完(EAGAIN)才 `installClientWriteHandler` 注册 WRITABLE 事件等下轮。若 reply 链表非空则走 `_writevToClient`(`networking.c:2010-2076`):静态缓冲与链表节点拼成 iovec(`iovmax = min(IOV_MAX, conn->iovcnt)`,`networking.c:2012`)一次 `writev` 吞掉,减少 syscall 与小包。

普通客户端单轮写入上限 `NET_MAX_WRITES_PER_EVENT = 64KB`(`server.h:130`,`networking.c:2187-2190`):超过即让出循环去服务其他客户端,防止"loopback 上的 KEYS *"饿死全场;但 replica(以及 maxmemory 已超限的内存压力场景)不受此限,尽快倒空以免缓冲无限增长(`networking.c:2155-2164` 注释)。

**(6) 关闭路径**。协议错误 → `setProtocolError` 打上 `CLIENT_CLOSE_AFTER_REPLY|CLIENT_PROTOCOL_ERROR`(`networking.c:2470-2497`),写完回复后释放;对端关闭 → `nread==0` → `freeClientAsync`(`networking.c:3091-3094`);`freeClient`(`networking.c:1728-1903`)是全量清理:IO 线程的客户端先 `fetchClientFromIOThread` 拉回主线程(`networking.c:1738-1741`,`iothread.c:105-136`),master 断连走 `replicationCacheMaster` 缓存主库状态支持部分重同步(`networking.c:1779-1786`),其余依次释放 querybuf/reply/argv/pubsub/watch,最后 `unlinkClient` 关 socket、摘除各种链表(`networking.c:1578-1645`)。

---

## ④ 输入/输出缓冲区的工程策略

Redis 在缓冲区上花的心思,比协议解析本身还多。逐条拆解:

### 4.1 输入侧:querybuf 的"三层缓存体系"

1. **线程级可复用缓冲** `thread_reusable_qb`(`networking.c:36-38`):每线程一块 16KB sds,普通小命令客户端轮流借用,读完归还。这是 unstable 上相对较新的优化,直接把海量空闲连接的缓冲内存从 per-client 降到 per-thread。
2. **客户端私有缓冲**:大参数读入(`big_arg`)、复用冲突(嵌套执行,`networking.c:3043-3049`)或未归还成功时,客户端持有私有 querybuf。
3. **峰值水位 `querybuf_peak`**:记录峰值,serverCron 周期里按 `PROTO_RESIZE_THRESHOLD`(32KB,`server.h:193`)判断收缩,避免"一次大命令永久占住大缓冲"。

尺寸闸门:单条 bulk ≤ `proto-max-bulk-len`(512MB);整缓冲 ≤ `client-query-buffer-limit`(默认 1GB,`config.c:3263`);**未认证客户端双保险 1MB**(`networking.c:3110-3122`:querybuf+MULTI 队列 >1MB 直接断,`stat_client_qbuf_limit_disconnections` 计数)。增长策略上主库客户端用 sds 贪婪扩容,普通客户端用 `sdsMakeRoomForNonGreedy` 精确扩容(`networking.c:3065-3081` 注释解释了原因)。

### 4.2 输出侧:16KB 静态缓冲 + 链表块 + replica 共享池三轨制

- **静态缓冲 `c->buf`**:16KB 定长(`networking.c:135`),小回复全部落在这里,写完后 `bufpos/sentlen` 归零,永不 realloc。监控里的 `obl/oll/omem` 字段分别对应 `bufpos`、reply 链表长度、链表内存(`catClientInfoString`,`networking.c:3279-3281`)。
- **reply 链表**:静态缓冲满或已有链表节点时,追加到 `clientReplyBlock` 节点(≥16KB,`PROTO_REPLY_CHUNK_BYTES`,`networking.c:370`);`setDeferredReply` 的延迟长度填充也依赖"链表尾节点可为 NULL"的约定(`networking.c:347-353`)。
- **replica 走全局复制积压缓冲**:`_writeToClientSlave`(`networking.c:2115-2137`)写的是 `server.repl_buffer_blocks` 共享块的引用(`ref_repl_buf_node/ref_block_pos`),多个副本共享同一份流,`c->reply_bytes` 对副本无意义(`networking.c:4417-4418`)。

### 4.3 client-output-buffer-limit 踢除机制(`networking.c:4350-4440`)

```
used_mem = getClientOutputBufferMemoryUsage(c)
若 authRequired(c) 且 used_mem > 1KB  → 直接判超限        (4354-4357)
class: master 按 normal 类处理;slave 的 hard limit 低于
       repl-backlog-size 时被抬到 backlog 大小            (4360-4373)
hard:  used_mem >= hard_limit_bytes                      → 立即踢
soft:  used_mem >= soft_limit_bytes 且持续 soft_limit_seconds → 踢
```

软限的"持续 N 秒"用 `obuf_soft_limit_reached_time` 水位时间戳实现,首次到达只记时间不踢(`networking.c:4383-4396`)。检查点有二:每次往 reply 链表追加数据后同步检查(`_addReplyProtoToList` 尾部,`networking.c:379`)和 serverCron。判定命中后 `closeClientOnOutputBufferLimitReached` 走 `freeClientAsync`(`networking.c:4414-4438`)——因为在 addReply 的调用上下文里立即 free 会破坏调用方,只能标记 `CLIENT_CLOSE_ASAP` 稍后在安全点(`beforeSleep` 的 `freeClientsInAsyncFreeQueue`,server.c:1924 / networking.c:1976)执行。默认配置(normal 0 0 0 即不限、replica 256MB 64MB 60s、pubsub 32MB 8MB 60s)见 redis.conf,机制本身如上。

### 4.4 一个反直觉的细节

`writeToClient` 对普通客户端的 64KB 单轮限制(`networking.c:2187-2190`)的判断条件包含 `server.maxmemory == 0 || zmalloc_used_memory() < server.maxmemory`——**内存已经超限时反而取消写入上限、尽力倾倒**。逻辑是:写不出去缓冲就一直占着内存,与其让内存被 reply 挤爆,不如尽快把数据送给客户端。

---

## ⑤ 设计动机与取舍

### 5.1 与 Memcached 的多线程对比

Memcached 采用"libevent + 工作线程池"模型:每个 worker 线程有自己的事件循环,监听 fd 轮转分发给 worker,**命令执行也在 worker 里并发**,线程间用内存屏障 + 细粒度锁保护哈希表(item 级锁、hash bucket 分段)。Redis 走了相反的路:**数据结构与命令执行严格单线程**(主线程),把"可并行的 syscall 密集部分"(读写 socket、解析)拆出去。这个取舍的根源:

- Redis 的核心复杂度在数据结构(SKIP LIST、dict 渐进 rehash、LPUSH 阻塞语义、事务),加锁的认知与性能成本远高于 Memcached 的 hash-item 锁;
- 单线程天然免锁免竞争,但代价是**一个慢命令阻塞所有连接**(KEYS、大 Lua),Redis 用文档纪律 + 命令级复杂度约束来兜底;
- Memcached 每个连接的处理更重(二进制协议、item 管理),并发执行收益大;Redis 单请求极轻,IO 才是可并行的部分。

### 5.2 io_threads 的两代设计(unstable 现状 = 完全重写)

**旧设计(7.0 及以前,现已删除)**:所有线程共享主事件循环,`io_threads_active` 时主线程把待读/待写客户端按 round-robin 分到各线程的原子计数 + 3 个 list,自旋等所有线程完成(`spin` 等待);读线程只负责 read 进 querybuf,解析和执行仍在主线程;`io-threads-do-reads` 控制是否并行读。

**新设计(unstable,`src/iothread.c`,2024 重写)**:

- **每个 IO 线程一个独立 `aeEventLoop`**,各跑各的 `aeMain`(`IOThreadMain`,`iothread.c:707-718`);客户端固定归属某个线程(`c->tid`),accept 时按"客户端数最少"分配(`assignClientToIOThread`,`iothread.c:158-185`)。
- **职责切分**:IO 线程做 read + RESP 解析 + write,并在解析完成后做一步轻量的 `lookupCommand` + 参数槽位计算(`c->iolookedcmd`、`getSlotFromCommand`,`networking.c:2950-2960`),然后把客户端移交主线程**执行命令**;主线程执行完再送回 IO 线程写回复(`processClientsFromMainThread`,`iothread.c:572-626`)。IO 线程永不释放客户端(`iothread.c:409` 注释)。
- **线程间通信**:每对方向一条 mutex 保护的客户端链 + `eventNotifier`(eventfd/pipe)唤醒;并有"免通知"优化——双方各有原子 `running` 标志,对方在运行时直接挂链不唤醒(`iothread.c:25-43,327-344,373-398`)。
- **主线程侧串行化**:来自 IO 线程的客户端在主线程排队逐个执行,还带 **CPU cache 预取**(逐客户端 `prefetchCommands`,按 `determinePrefetchCount` 控批量,`iothread.c:348-367`,`memory_prefetch.c:316,329`)——把解析完待执行的命令的 key 内存提前拉进 cache,降低 dict 查找的 cache miss。
- **安全上下文**:主线程要访问 IO 线程的客户端数据(CLIENT LIST、free、resize)时,用 `pauseIOThread` 系列:原子标志 + **忙等**对端在 `IOThreadBeforeSleep` 的干净点自暂停(`iothread.c:205-323`),避免加全局锁。
- **回退与例外**:`isClientMustHandledByMainThread`(`iothread.c:145-154`)列出必须回主线程的客户端:master/replica/pubsub/monitor/blocked/tracking/LUA debug——它们会被主线程"旁路写回复";`keepClientInMainThread` 把这类客户端彻底留在主线程(`iothread.c:84-100`)。
- **配置**:上限 `IO_THREADS_MAX_NUM 128`(`server.h:217`),`io-threads` 默认 1 即完全旧行为;每线程积压批阈值 `IO_THREAD_MAX_PENDING_CLIENTS 16`(`server.h:221`);客户端结构里还专门有 `deferred_objects` 数组,让 IO 线程释放 robj 时延迟到对象所属线程的 arena 做,减少跨线程 free 争用(`networking.c:1481-1493`,`iothread.c:97` 的 `freeClientDeferredObjects`)。

**为什么重写**:旧设计所有线程挤同一个 epoll + 自旋同步,扩展性差且读并行收益有限(解析没并行);新设计把"每连接一个归属线程"变成无锁的 owner-worker 模型,主线程只做纯内存计算,理论上 IO 线程数可以随连接数与带宽线性扩展,同时保持命令执行的串行一致性(这与 memcached 的区别在于:Redis 的"并行"只在 IO,不在数据)。

### 5.3 连接类型抽象:connection.c / socket.c

`connTypeRegister` 把各实现挂进全局 `connTypes[]` 表(`connection.c:30-59`);`connTypeInitialize` 强制注册 socket 与 unix,TLS 仅在 `BUILD_TLS=yes` 时存在(`connection.c:61-72`)。`ConnectionType` 是一张 30+ 项的 vtable(`connection.c:385-430`):读写、writev、读写 handler、accept/listen、sync 读写……**设计初衷是让上层代码不感知 TLS 的非阻塞握手中断**:`connSocketEventHandler` 在 `CONN_STATE_CONNECTING` 时先处理连接完成回调(`connection.c:253-268`),TLS 则通过 `has_pending_data/process_pending_data` 两个 vtable 钩子在 beforeSleep 前把缓冲里未消费的 TLS 记录强制处理掉(`connection.c:160-189`;`server.c:1806-1810` 的 `dont_sleep` 逻辑)。read/write 的错误处理规则:read 返回 0 → `CONN_STATE_CLOSED`;EINTR 不改状态;其他错误仅在已连接态置 `CONN_STATE_ERROR`(`connection.c:165-180`)。此外 `client->tid/running_tid`、`c->slot` 等 IO 线程与 cluster 字段已经织入 client 结构(`networking.c:140-142,178`),说明这套抽象未来还要承载更多传输类型。

### 5.4 anet.c 的角色变迁

anet 是 getaddrinfo/setsockopt 的朴素封装:非阻塞幂等设置(`anetSetBlock` 先查后设,`anet.c:54-80`)、FD_CLOEXEC 防 fd 泄漏进 fork+exec(`anet.c:93-111`)、keepalive 参数化(见 ③(0))、`SO_REUSEADDR` 支撑压测级建连速率(`anet.c:353-362`)、`accept4` 一步到位(`anet.c:609-613`)、accept 可安全重试的 errno 白名单 ECONNABORTED/ENETDOWN 等(`anet.c:798-813`)。**值得注意:unstable 里已检索不到任何 TCP_FASTOPEN/`anetEnableTcpFastOpen` 代码**(grep 全 src 为空)——8.x 之前存在的 TFO 支持已从 anet.c 移除,若读者基于旧资料介绍 TFO 需更正。

---

## ⑥ 容易误解的点与面试级 FAQ

**Q1:Redis 是"单线程",那 epoll_wait 挂着的时候新命令要等什么?**
要等三种之一:任意 fd 就绪(含监听 fd 的 accept)、最近的时间事件到期(如 serverCron 的 `1000/hz` 周期)、或 `AE_DONT_WAIT` 标志(有 TLS pending 数据等场景,beforeSleep 里 `aeSetDontWait` 置位后下轮 timeout=0,`server.c:1955`、`ae.c:385-387`)。

**Q2:为什么时间事件不用最小堆?**
数量太小,堆不划算。主循环常驻定时器只有 serverCron(IO 线程再各一个 IOThreadCron),O(N) 扫描就是最优解;作者在 `ae.c:257-262` 注释里明确列过有序插入/跳elist两个"暂不需要"的优化方向。Redis 的客户端超时检查也不走定时器,而是 serverCron 周期扫描。

**Q3:一条命令的回复是在哪个阶段发出的?**
两个阶段:优先在**进入 epoll_wait 之前**的 beforeSleep 里直写(`handleClientsWithPendingWrites`),此时 socket 发送缓冲通常有空位,一次 write 完成;写不完才注册 WRITABLE 事件等下一轮。所以"先读后写"在 ae 层还有一层含义:同一 fd 上读事件先于写事件触发,查询处理完立刻就能写回复(`ae.c:415-419`)。

**Q4:AE_BARRIER 是干嘛的?什么场景用?**
强制同一轮迭代里"先写后读"。用例:appendfsync=always 时,必须先 fsync AOF 再处理该客户端的新读、并把 fsync 后的回复发出去,否则可能回复了实际没落盘的数据。`installClientWriteHandler` 在 fsync=always 时带 barrier 注册写 handler(`networking.c:244-248`),connection 层也有对应的 `CONN_FLAG_WRITE_BARRIER` 反转逻辑(`connection.c:281-298`)。

**Q5:querybuf 是每个客户端固定 16KB 吗?**
不是。unstable 上普通客户端默认**共享线程级可复用缓冲**(读后归还,`networking.c:3049-3061`);大参数读入时切换为私有精确分配;峰值超阈值会被 serverCron 收缩。所以"1 万连接 = 160MB 输入缓冲"的旧算法不再成立。

**Q6:为什么解析大 bulk 时要"接管 querybuf"?**
当缓冲里恰好只剩一个 ≥32KB 的参数时,把 sds 直接变成 robj,省一次 memcpy(`networking.c:2679-2694`);随后按 `maxmemory` 约束决定新缓冲大小(继续大缓冲 or 回落 16KB)。master 客户端不享受此优化,因为它的 querybuf 还要原样转发给下级副本(`networking.c:2633-2636` 注释)。

**Q7:输出缓冲超限是立刻断开吗?**
是"标记 + 稍后断开"。检查在每次追加 reply 后同步进行,但执行的是 `freeClientAsync`:打 `CLIENT_CLOSE_ASAP` 入 `clients_to_close`,在 beforeSleep 的 `freeClientsInAsyncFreeQueue` 安全点真正释放(`networking.c:4424-4437`)。因为 free 的上下文(嵌套调用链)不安全。

**Q8:未认证连接有什么特殊限制?**
四处:multibulk 参数个数 >10 拒绝(`networking.c:2541-2544`);bulk 长度 >16384 拒绝(`networking.c:2627-2630`);querybuf 超 1MB 断开(`networking.c:3115-3116`);输出缓冲超 1KB 判超限踢除(`networking.c:4354-4357`)。这套组合拳专门防"免认证打爆内存"的 DoS。

**Q9:io-threads 开了之后命令就并发执行了吗?**
没有。命令执行仍在主线程串行(unstable 新设计里解析可以并行、执行绝不能,`iothread.c:409` 注释;主线程逐个处理 IO 线程移交的客户端,`iothread.c:424-502`)。开了 io-threads 的收益是:read/write syscall、TLS、协议解析、cache 预取并行化。

**Q10:一个 fd 同时可读可写时,处理顺序由什么决定?**
默认先读后写;`AE_BARRIER` 反转。且写回调只会在它和读回调不是同一个函数指针时才额外触发(`ae.c:441-445`)。另外每轮触发前都要用 `fe->mask & mask & ...` 重新校验,因为同轮更早的回调可能已删除该事件(`ae.c:428-433`)。

**Q11:accept 会不会一次 accept 完 backlog 里的所有连接?**
不会。`connSocketAcceptHandler` 每轮事件循环最多 accept `max-new-connections-per-cycle`(默认 10)个,`anetAcceptFailureNeedsRetry` 决定哪些 errno 可继续重试(`socket.c:301-321`、`anet.c:798-813`)。这是防止连接风暴挤占一轮循环的准入节流。

**Q12:TCP_NODELAY 是默认开的吗?keepalive 呢?**
TCP_NODELAY 在 `createClient` 里无条件开启(`networking.c:129`);keepalive 由 `tcp-keepalive` 配置(默认 300s)驱动,设 `TCP_KEEPIDLE=interval、TCP_KEEPINTVL=interval/3、TCP_KEEPCNT=3`(`anet.c:212-252`)。所以 Redis 的请求永远不依赖 Nagle 合包,延迟敏感但小包开销略增。

---

## ⑦ 深挖问题清单(建议进阶调研)

1. **eventNotifier 的实现差异**:`iothread.c` 与 pause/running 协议大量依赖 `eventnotifier.c`(eventfd vs pipe 的平台分叉)。它的缓冲满语义(`triggerEventNotifier` 可能返回错误但被有意忽略,`iothread.c:336-339`)值得单独验证。
2. **prefetch 批量策略的自适应**:`determinePrefetchCount`(`memory_prefetch.c:316`)如何按待处理客户端数/批大小动态调节?与 jemalloc 的 cache 行为配合的实际收益需要 perf 数据支撑。
3. **`c->slot` 与 per-slot 流量统计**:`net_input_bytes_curr_cmd` 的四段式计算(`networking.c:2565-2596` 的长注释)与 `clusterSlotStatsAddNetworkBytesInForUserClient` 的聚合时机,是 cluster slot 统计的精确口径问题,易漏。
4. **reusable querybuf 与嵌套执行的边界**:`thread_reusable_qb_used` 嵌套冲突时客户端私有兜底(`networking.c:3043-3049`),但 processEventsWhileBlocked 的重入路径(脚本超时)是否覆盖所有情形,值得构造用例。
5. **unstable 移除 TCP FastOpen 的时间点与动机**:本 commit 的 anet.c 已无 TFO(全文 grep 证实),对比 8.0 stable 确认移除版本与讨论(可能与 TLS 握手/内核语义有关),给读者一个"特性退役"的案例。
