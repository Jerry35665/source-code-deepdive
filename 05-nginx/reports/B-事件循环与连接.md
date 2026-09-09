# B 篇 · 事件循环与连接管理(nginx 1.31.5 主干,commit 231a60ee,2026-09-02)

> 调研范围:`src/event/ngx_event.c`、`src/event/modules/ngx_epoll_module.c`、`src/event/ngx_event_timer.c|h`、`src/event/ngx_event_posted.c|h`、`src/event/ngx_event_accept.c`、`src/event/ngx_event_udp.c`、`src/core/ngx_connection.c|h`、`src/os/unix/ngx_channel.c`、`src/os/unix/ngx_process_cycle.c`。所有结论均标注 `文件:行号`,行号为该 commit 下的实际行号。

---

## ① 全景:事件模块的分层

Nginx 的事件子系统是一条"核心 — 后端 — 外围"的分层结构,与 Redis ae 那种单文件事件库完全不同,它把"事件循环怎么跑"和"事件从哪来"拆成了两层:

| 层 | 文件 | 职责 |
|---|---|---|
| 事件核心 | `src/event/ngx_event.c` | worker 主循环入口 `ngx_process_events_and_timers`、accept 互斥锁状态机、与后端无关的 `ngx_handle_read/write_event`、事件模块配置 |
| 事件后端 | `src/event/modules/ngx_epoll_module.c`(及 kqueue/devpoll/poll/select/eventport/iocp) | 实现 `ngx_event_actions_t` 的九个函数指针,见 `ngx_event.h:166-183`:`add/del/enable/disable/add_conn/del_conn/notify/process_events/init/done` |
| 定时器 | `src/event/ngx_event_timer.c` + `ngx_event_timer.h` | 一棵进程级全局红黑树 `ngx_event_timer_rbtree`(`ngx_event_timer.c:13`) |
| posted 队列 | `src/event/ngx_event_posted.c|h` | 三个进程级队列:`ngx_posted_accept_events` / `ngx_posted_next_events` / `ngx_posted_events`(`ngx_event_posted.c:13-15`) |
| 连接池 | `src/core/ngx_connection.c|h` | `cycle->connections` 数组 + `free_connections` 空闲单链表、`ngx_get/free/close_connection` |
| 进程通道 | `src/os/unix/ngx_channel.c` | master↔worker 的 socketpair 消息(`sendmsg/recvmsg` + `SCM_RIGHTS` 传 fd) |

两个核心数据结构把各层缝在一起:

- `ngx_event_t`(`ngx_event.h:30-138`):内嵌红黑树节点 `timer`(:114)和队列节点 `queue`(:117),所以**一个事件可以同时在定时器树和 posted 队列里被引用,零额外分配**。关键标志位:`instance`(:38,stale 事件检测)、`active`(:44,已注册进内核)、`ready`(:49,内核已就绪)、`available`(:101,kqueue 下为可读字节数/accept 数,其余为 "accept 多个" 开关)、`posted`(:69)。
- `ngx_connection_s`(`ngx_connection.h:127-206`):`data` 字段(:128)在空闲时被复用为 free 链表的 next 指针;`read/write`(:129-130)指向两个固定配对的 `ngx_event_t`;`queue`(:170)用于 idle/reusable 连接队列。

后端注册发生在 `ngx_event_process_init`(`ngx_event.c:679-696`):按配置 `use` 找到事件模块,调 `module->actions.init`,由 `ngx_epoll_init` 把 `ngx_event_actions` 整体替换为 epoll 版本(`ngx_epoll_module.c:369`),此后 `ngx_add_event` 等宏(`ngx_event.h:400-408`)都是对 `ngx_event_actions` 的间接调用——**一次函数指针表赋值完成"编译期选择的模块 → 运行时多态"的切换**。

worker 的主循环极简(`ngx_process_cycle.c:740-778`):`ngx_process_events_and_timers(cycle)` → 检查 `ngx_terminate/ngx_quit/ngx_reopen` 信号标志 → 继续。所有业务逻辑都挂在事件回调上。

---

## ② 一轮 `ngx_process_events_and_timers` 逐段解读

函数本体在 `ngx_event.c:194-264`,每轮做七件事:

**(1) 计算 timer 与 flags——两种时钟模式**(`ngx_event.c:200-217`)

```c
if (ngx_timer_resolution) {
    timer = NGX_TIMER_INFINITE;   /* 信号模式:epoll_wait 无限等 */
    flags = 0;
} else {
    timer = ngx_event_find_timer();   /* 拉模式:睡到最近的定时器到期 */
    flags = NGX_UPDATE_TIME;          /* 返回后由后端统一 ngx_time_update */
}
```

`ngx_timer_resolution` 来自 `timer_resolution` 指令(`ngx_event.c:512`)。开启后走 SIGALRM:`ngx_event_process_init` 注册 handler 并 `setitimer(ITIMER_REAL)` 周期中断(`ngx_event.c:698-723`),中断只置 `ngx_event_timer_alarm = 1`(:622-630);epoll 后端在 `epoll_wait` 被 EINTR 打断时清标志并刷时间(`ngx_epoll_module.c:804-806, 811-815`)。代价是进程每秒被中断 `timer_resolution` 次;好处是时间精度与 `epoll_wait` 超时解耦,适合长连接大量、事件稀疏的场景。

**(2) accept 互斥锁——抢锁或退避**(`ngx_event.c:219-239`)

```c
if (ngx_use_accept_mutex) {
    if (ngx_accept_disabled > 0) {
        ngx_accept_disabled--;            /* 本轮不参与抢锁,只消耗额度 */
    } else {
        if (ngx_trylock_accept_mutex(cycle) == NGX_ERROR) return;
        if (ngx_accept_mutex_held) {
            flags |= NGX_POST_EVENTS;     /* 持锁者:事件先入队,稍后处理 */
        } else {
            if (timer == NGX_TIMER_INFINITE || timer > ngx_accept_mutex_delay)
                timer = ngx_accept_mutex_delay;   /* 未抢到:最多睡 500ms 再试 */
        }
    }
}
```

`ngx_use_accept_mutex` 的启用条件是 `master 进程 && worker_processes > 1 && accept_mutex 指令开启`(`ngx_event.c:649-656`);注意**默认值是 off**(`ngx_event.c:1369`,1.11.3 起改为默认关闭,`docs/xml/nginx/changes.xml:7497-7513`)。`ngx_accept_disabled` 在每次 accept 成功后重算:`connection_n/8 - free_connection_n`(`ngx_event_accept.c:139-140`)——空闲连接不足 1/8 时该值为正,此 worker 主动退出 accept 竞争,把名额让给有余量的 worker,这是**进程级负载反馈**而非公平锁。

**(3) flush `ngx_posted_next_events`**(`ngx_event.c:241-244`):该队列里是"要求下一轮立刻处理"的事件(写入点如 `ngx_output_chain.c:800`、`ngx_http_write_filter_module.c:335`、`ngx_event_openssl.c:2700/3563`)。若非空则 `timer = 0`,强制 `epoll_wait` 立即返回,把这些事件搬到 `ngx_posted_events` 并置 `ready=1, available=-1`(`ngx_event_posted.c:39-60`)——本质是"同一轮内拒绝重复处理、下一轮必达"的让步机制,避免短写场景在同一轮里自旋。

**(4) 执行后端事件采集**(`ngx_event.c:246-250`):`(void) ngx_process_events(cycle, timer, flags)`,即 `ngx_epoll_process_events`;随后用 `delta = ngx_current_msec - delta` 记录本轮阻塞耗时(:250-253),这是日志里 `timer delta` 的来源。

**(5) 处理 accept posted 队列 + 立刻解锁**(`ngx_event.c:255-259`)

```c
ngx_event_process_posted(cycle, &ngx_posted_accept_events);
if (ngx_accept_mutex_held) {
    ngx_shmtx_unlock(&ngx_accept_mutex);
}
```

这是整个设计最精妙的一处:epoll 循环里 accept 类事件被投递到 `ngx_posted_accept_events`,普通读写事件投到 `ngx_posted_events`(`ngx_epoll_module.c:894-899`)。于是持锁窗口 = "epoll_wait 返回 → 处理完 accept → unlock",普通业务事件全部被推迟到解锁之后,**锁的持有时间被压缩到接近裸 accept 的耗时**。

**(6) 到期定时器**(`ngx_event.c:261`,`ngx_event_timer.c:53-96`)。

**(7) 普通 posted 队列**(`ngx_event.c:263`):`ngx_event_process_posted` 从队头逐个摘下并执行 `ev->handler(ev)`(`ngx_event_posted.c:24-35`)——队头摘除保证"先到先处理",且处理中新增的 posted 事件会留到下一轮,天然防止无限循环。

**时序图(两 worker 抢同一把 accept 锁):**

```
 worker A                                 worker B
 ─────────────────────────────────────────────────────────────────
 loop N:                                  loop N:
   find_timer()=42ms │                      find_timer()=42ms
   trylock ──成功────││                      trylock ──失败(原子CAS, ngx_shmtx.c:62-66)
   flags|=POST_EVENTS││                      timer=min(42,500)=42ms, 无 POST
   epoll_wait(42ms)──││                      epoll_wait(42ms)
     accept事件→posted_accept│               (无accept事件或忽略)
     读事件→posted_events   │
   处理posted_accept: accept()×n          loop N+1..k(退避循环):
   shmtx_unlock ──────────────┬────────→   trylock ──成功(拿到锁)
   expire_timers              │            enable_accept_events()重新注册
   处理posted_events(读/写)   │            epoll_wait … accept()
   loop N+1:                  │            …
     disabled>0? 否:再trylock │            loop m: disabled>0 → 减一,让出
```

未抢到锁的 worker 并不是空转:`ngx_trylock_accept_mutex` 失败且上次持锁时,会 `ngx_disable_accept_events` 把 listening 的读事件从 epoll 摘除(`ngx_event_accept.c:370-376`);抢到锁时才 `ngx_enable_accept_events` 重新挂上(:382-404)。**所谓"抢锁"实质是"抢 listening socket 在本进程 epoll 里的注册权"**,锁本身只是一面共享内存里的原子标志(`ngx_shmtx.c:62-66`,`ngx_atomic_cmp_set(lock, 0, ngx_pid)`)。

**主循环之外:与后端无关的事件注册**。业务代码从不直接调 `ngx_add_event`,而是走 `ngx_handle_read_event` / `ngx_handle_write_event`(`ngx_event.c:267-344, 347-429`)。它们按 `ngx_event_flags` 分三种策略:epoll/kqueue(CLEAR 语义)下,只在 `!active && !ready` 时 ADD 一次(:282-294),之后完全靠用户态 `ready` 标志记账,不再碰内核;select/poll/devpoll(LEVEL 语义)下,`ready` 时要主动 DEL(:296-318),否则水平触发会疯狂重报;eventport 下按 oneshot 语义补注册(:320-339)。这段代码是"一套业务逻辑适配所有后端"的枢纽,也是理解 `active/ready` 两个标志位分工的最佳入口:`active` 表示"内核还惦记着这个事件",`ready` 表示"数据已经就绪待读"。epoll ET + GREEDY(`NGX_USE_GREEDY_EVENT`,`ngx_epoll_module.c:376`)的组合意味着读 handler 必须循环 `recv` 直到 `NGX_AGAIN`——`ngx_event_flags` 就是在这里被消费的。

---

## ③ epoll 后端逐段

### 3.1 `ngx_epoll_init`(`ngx_epoll_module.c:322-380`)

- `epoll_create(cycle->connection_n / 2)`(:330,size 参数自 2.6.8 起仅提示意义);
- 顺带初始化三个"附属 fd":
  - **notify eventfd**(:339,`ngx_epoll_notify_init` :386-428):`eventfd(0,0)` 以 `EPOLLIN|EPOLLET` 注册,`data.ptr = &notify_conn`,跨线程唤醒入口;
  - **Linux AIO eventfd**(:345,`ngx_epoll_aio_init` :249-317):`io_setup` + eventfd,完成后 `ngx_epoll_eventfd_handler` 读出 `io_event[]` 并 posted(:941-1020);
  - **EPOLLRDHUP 能力自检**(:349,`ngx_epoll_test_rdhup` :464-524):用 socketpair + 关闭对端 + `epoll_wait(5000)` 实测内核是否返回 EPOLLRDHUP,而不是靠宏猜内核版本——运行时特性探测的教科书式做法。
- 设置 `ngx_event_flags = NGX_USE_CLEAR_EVENT | NGX_USE_GREEDY_EVENT | NGX_USE_EPOLL_EVENT`(:371-377):epoll 是边缘触发(CLEAR),且要求读到 EAGAIN(GREEDY)。
- `event_list` 按 `epoll_events` 指令分配(默认 512,:1047)。

### 3.2 注册与注销:`add_event` / `add_connection`

epoll 的 fd 粒度注册带来一个其他后端没有的麻烦:读、写两个独立 `ngx_event_t` 共享同一个 fd 的一个 epoll 项。`ngx_epoll_add_event` 用"对侧事件是否 active"判断 ADD 还是 MOD 并合并掩码(`ngx_epoll_module.c:606-612`):

```c
if (e->active) { op = EPOLL_CTL_MOD; events |= prev; }
else           { op = EPOLL_CTL_ADD; }
ee.events = events | (uint32_t) flags;
ee.data.ptr = (void *) ((uintptr_t) c | ev->instance);   /* 指针低位藏 instance */
```

三点值得咀嚼:
1. `NGX_CLEAR_EVENT` 在 epoll 下就是 `EPOLLET`(`ngx_event.h:353`),"边缘触发"被抽象成通用的"清除语义"标志;
2. `data.ptr` 低位 1 bit 存 `ev->instance`(:621),不占额外内存地给每条事件盖了个"代次"邮戳;
3. `ngx_epoll_add_connection`(:700-721)一条 `EPOLLIN|EPOLLOUT|EPOLLET|EPOLLRDHUP`(:705)同时挂读写,连接型 fd 生命周期内通常只 `epoll_ctl` 这一次,后续读写开关全靠 `ready/active` 标志在用户态记账——这是 epoll ET 模式省 syscall 的关键。

注销侧的注释值得原文引用(`ngx_epoll_module.c:651-655`):"when the file descriptor is closed, the epoll automatically deletes it from its queue"——所以 `NGX_CLOSE_EVENT` 时 `ngx_epoll_del_event` 直接把 `active` 清零返回(:657-660),`ngx_close_connection` 也据此跳过 `epoll_ctl`(见 ⑤)。

### 3.3 `ngx_epoll_process_events`(`ngx_epoll_module.c:779-936`)

```c
events = epoll_wait(ep, event_list, (int) nevents, timer);      /* :800 */
...
for (i = 0; i < events; i++) {
    c = event_list[i].data.ptr;
    instance = (uintptr_t) c & 1;
    c = (ngx_connection_t *) ((uintptr_t) c & ~1);              /* :839-840 */
    rev = c->read;
    if (c->fd == -1 || rev->instance != instance) { continue; } /* :844 stale */
```

**stale 事件判定**是这段的灵魂。场景:同一批 `epoll_wait` 返回的事件里,fd X 的事件排在后面,但前面的事件处理中已经把连接关闭,fd X 又被新 accept 复用。仅凭 `c->fd == -1` 不够(指针可能已被 free 后重新分配),`instance` 提供了代次校验:`ngx_get_connection` 每次分配连接都会翻转 `rev/wev->instance`(`ngx_connection.c:1256-1262`),注册时烙进 `data.ptr`,取出时比对(:844)。1 位代次即可,因为 stale 事件只可能来自"本批次内被关闭的 fd",见 ⑧-5 的论证。

后续对 `revents` 的处理顺序:

- `EPOLLERR|EPOLLHUP` 时强制叠加 `EPOLLIN|EPOLLOUT`(:862-873),保证错误至少被一个 handler 看到(读侧会 recv 出错,写侧会 send 出错);
- 读事件(:883-903):置 `ready=1, available=-1`(available=-1 表示"长度未知",GREEDY 模式读侧需读到 EAGAIN);EPOLLRDHUP 置 `pending_eof`,让读侧不必先 recv 一次才发现对端关闭(:885-889);然后按 `NGX_POST_EVENTS` 分流——**`rev->accept ? &ngx_posted_accept_events : &ngx_posted_events`**(:894-899);
- 写事件(:905-932):额外校验一次 stale(:909-919,因为读 handler 可能已经关掉了连接),置 `ready=1`(线程池模式下还置 `complete`,:922-924),同样可 posted。

### 3.4 eventfd 通知机制(`ngx_epoll_module.c:764-777, 432-457`)

`ngx_notify(handler)` 是"把控制流从别的线程/上下文搬运回事件循环"的通道(线程池完成任务、resolver 等使用):写入端 `write(notify_fd, &inc, 8)` 每次累加 1(:764-777);读取端 handler 每被调用一次就 `++ev->index`,**累计到 `NGX_MAX_UINT32_VALUE`(约 42.9 亿次)才 `read()` 一次 eventfd 清空计数**(:439-453):

```c
if (++ev->index == NGX_MAX_UINT32_VALUE) {
    ev->index = 0;
    n = read(notify_fd, &count, sizeof(uint64_t));
    ...
}
handler = ev->data;   /* notify() 把真正的 handler 塞进 ev->data */
handler(ev);
```

这个设计的两个前提:① 每次 `write` 都会经 `eventfd_write → wake_up` 触发一次 epoll 唤醒(事件被 `epoll_wait` 取走后即可重新入队),因此**一次通知对应一次 handler 调用**;② eventfd 计数器有上限,写满会返回 EAGAIN,所以必须周期性排空——用"每 42 亿次通知一次 read"把读 syscall 摊薄到可忽略。代价是对内核 eventfd+EPOLLET 唤醒语义的强依赖,见 ⑧-1。

另外注意 `ngx_epoll_notify` 的实现细节:真正的 handler 不放在 `notify_event.handler` 里,而是塞进 `notify_event.data`(:769),通知 handler 再转发(:455-457)——因为 notify_event 本身的 handler 是固定的,而每次 `ngx_notify()` 想调度的目标不同,复用了 `data` 这个"万能指针"字段。`ngx_epoll_done`(:529-575)则按对称顺序关掉 ep、notify eventfd、AIO eventfd 并释放 event_list,`init` 里 `if (ep == -1)` 的判断(:329)说明在 reload 生成新 cycle 时旧 epoll 实例会被沿用,只有真正退出才 done。

---

## ④ 红黑树定时器 vs Redis 的时间事件链表

### 4.1 Nginx 的实现

全局一棵 `ngx_event_timer_rbtree`(`ngx_event_timer.c:13`),节点就是 `ngx_event_t.timer`(`ngx_event.h:114`),`key` 为**绝对到期时刻** `ngx_current_msec + timer`(`ngx_event_timer.h:56`)。头文件里 `ngx_event_add_timer`/`ngx_event_del_timer` 是 inline 函数(`ngx_event_timer.h:31-87`),热路径无函数调用开销。

- **查最近超时**:`ngx_event_find_timer` 只取树最左节点,算 `node->key - ngx_current_msec`,负数归零(`ngx_event_timer.c:32-50`)——O(log n) 定位 + O(1) 读值,注释直言树里允许重复 key,因为"我们只用红黑树找最小值"(:16-20)。
- **到期处理**:`ngx_event_expire_timers` 循环取 min,`node->key - ngx_current_msec > 0` 即停(:61-74);删除节点后置 `ev->timedout=1` 再调 `ev->handler(ev)`(:82-94),**让 handler 通过同一入口感知超时**,这是 Nginx"定时器只是事件的另一种就绪"的统一抽象。
- **惰性更新**:`ngx_event_add_timer` 发现已有 timer 且新旧 key 差 `|diff| < NGX_TIMER_LAZY_DELAY(300ms)` 时直接复用旧节点(`ngx_event_timer.h:58-76`),注释说明目的:"minimize the rbtree operations for fast connections"——高频读连接反复续约 60s 超时时,300ms 内的抖动不值得一次 O(log n) 删+插。
- **回绕处理**:插入比较用**有符号差** `(ngx_msec_int_t)(node->key - temp->key) < 0`(`ngx_rbtree.c:136-139`),注释指出 32 位毫秒 49.7 天回绕,有符号差恰好容忍它;同样技巧也出现在 `ngx_event_find_timer:47` 和 `expire_timers:72`。

### 4.2 对照 Redis ae(据 Redis 官方 ae 库 ae.c/ae.h 的通用实现,本仓库不含 Redis 源码,以下为对照观察)

| 维度 | Nginx | Redis ae |
|---|---|---|
| 时间事件组织 | 全局红黑树,key=绝对到期 ms,事件内嵌节点 | `aeTimeEvent` 单链表挂 `aeEventLoop.timeEventHead`,无序,`aeSearchNearestTimer` 线性扫描 O(N) |
| 到期处理 | `ngx_event_expire_timers` 只处理到期者,处理一个删一个 | `aeProcessEvents` 遍历整表,`when <= now` 触发回调 |
| 定时器数量假设 | 与连接同量级(每连接读写超时各一),可达数十万 | 极少(通常只有 serverCron 等个位数+客户端超时),链表 O(N) 不是瓶颈 |
| 读写事件 | 每连接两个 `ngx_event_t`,epoll `data.ptr` 直接回指连接 | `aeFileEvent` 数组按 fd 索引,`mask` 位图 `AE_READABLE\|AE_WRITABLE`,`fd → event` O(1) |
| 事件与连接的关系 | 事件是连接的成员,连接即上下文 | 文件事件回调参数是 fd/el/clientData,需 clientData 间接 |
| 定时精度 | 睡到最近定时器(find_timer)或 SIGALRM | `aeSearchNearestTimer` 决定 epoll timeout,另有 `aftersleep` 钩子统计睡眠 |

**观察结论**:两者的分叉是"数量级决定数据结构"。Redis 的时间事件个位数、文件事件按 fd 数组直接索引,简单结构反而 cache 更友好;Nginx 的定时器与连接同数量级且频繁增删,红黑树的 O(log n) 插删 + O(log n) 取 min 是必需品,而它不按 fd 索引事件是因为 `data.ptr` 回指已经把间接层省掉了——代价是每个连接固定付出两个 `ngx_event_t`(含内嵌 rbtree 节点)的内存。另一个有趣的共性:两者都把"超时"建模为事件回调(Nginx 的 `timedout` 标志,Redis 的 timeEvent 回调),而不是让业务轮询。

---

## ⑤ 连接池与内存策略

### 5.1 三块数组 + 一条空闲链表

`ngx_event_process_init` 一次性分配三块与 `worker_connections` 等长的数组:`cycle->connections / read_events / write_events`(`ngx_event.c:754-783`),按下标配对(`c[i].read = &cycle->read_events[i]`,:792),然后倒序把所有连接串成单链表,头挂 `cycle->free_connections`(:785-800)。**`c->data` 就是 free 链表的 next 指针**(`ngx_connection.h:128`),用连接自身的字段当链节,零额外元数据;倒序建链使最先分配到的恰是 `connections[0]`,对 cache 预热友好。初始 `rev[i].closed = 1; rev[i].instance = 1`(:769-772)保证"未使用"是合法初始态。

`ngx_get_connection`(`ngx_connection.c:1210-1273`):pop 头结点 → `ngx_memzero(c)` 与两个事件整体清零(:1249-1259)→ 翻转 `instance`(:1261-1262)→ 重建 `rev/wev->data` 回指。清理是"整块 memset"而非逐字段复位,简单且不会漏;代价是 `ngx_connection_t`(约 200+ 字节)+ 2×`ngx_event_t` 的写放大,但相对每次 accept 后要做的工作(建内存池等)可以接受。`ngx_free_connection`(:1276-1286)是 O(1) 头插。分配前还有一个动作:`ngx_drain_connections`(:1227),见 5.3。

### 5.2 `ngx_close_connection` 的完整清算(`ngx_connection.c:1289-1374`)

顺序严格:
1. 删读写定时器(:1301-1307)——先于一切,防止关闭后 handler 被 expire 触发;
2. 从 epoll 注销(:1309-1322):优先 `ngx_del_conn(c, NGX_CLOSE_EVENT)`,epoll 后端看到 CLOSE 标志直接清标志位返回(§3.2 的 close 语义),共享 fd(UDP)连 epoll 都不碰(:1309);
3. 从 posted 队列摘除(:1324-1330)——事件可能已经在本轮被 posted,不摘会悬空;
4. `closed = 1`(:1332-1333)、`ngx_reusable_connection(c, 0)` 出 idle 队列(:1335);
5. `ngx_free_connection` 归还池、`c->fd = -1`(:1339-1342),**先置 -1 再 close**——close 返回后若立刻有新连接拿到同号 fd,任何并发读 `c->fd` 的日志路径都不会看到旧值;
6. `c->shared` 连接(UDP 逻辑连接,fd 属于 listening socket)在这里直接返回(:1344-1346),不 close fd。

### 5.3 压力自愈:reusable 队列与 drain

`ngx_reusable_connection`(:1377-1405)把空闲 keep-alive 连接挂进 `cycle->reusable_connections_queue`。`ngx_drain_connections`(:1408-1462)在**每次 get_connection 时**检查:若 `free_connection_n <= connection_n/16` 且存在 reusable 连接,每轮最多关闭 `max(min(32, reusable_n/8), 1)` 个最旧连接(:1431-1446)——注意手法是 `c->close = 1; c->read->handler(c->read)` 直接调用读 handler(:1444-1445),复用协议层已有的关闭路径(HTTP 模块看到 `c->close` 会走 close),而不会在连接池里写死任何 HTTP 知识。这是"核心层不认识协议层"边界设计的又一例。

### 5.4 读缓冲:分配权在协议层,不在 accept

accept 时刻只分配连接级内存池(`ngx_event_accept.c:159`)、sockaddr/log(:169-177)与地址文本(:285-299)。`c->buffer` 由协议模块按需分配:HTTP 在第一次读时才 `ngx_create_temp_buf(c->pool, client_header_buffer_size)`(`ngx_http_request.c:408-419`);连接空闲(NGX_AGAIN 且缓冲为空)时 `ngx_pfree` 把缓冲内存还给 pool、但保留 buf 骨架以便复用(:450-460),注释直说 "We are trying to not hold c->buffer's memory for an idle connection"。UDP 则相反:每包先落进一个**静态 64KB 共享缓冲** `static u_char buffer[65535]`(`ngx_event_udp.c:40`),识别出新的五元组后拷入该"连接"的 `c->buffer`(:261-267),后续同源包经 `ngx_udp_shared_recv` 从缓冲搬出(:368-390)。

### 5.5 worker 与 master 的通道(`src/os/unix/ngx_channel.c`)

master 为每个 worker 建 socketpair(`ngx_process_cycle.c` 的 spawn 逻辑),worker 启动时关掉别人的写端、关掉自己的读端,只留 `ngx_channel` 一个 fd,并 `ngx_add_channel_event(..., ngx_channel_handler)`(:963-969)注册进同一个 epoll——**控制面与数据面共用一个事件循环**。`ngx_write_channel` 用 `SCM_RIGHTS` 附属数据传 fd(`ngx_channel.c:37-53`,典型用途是热升级时把 listening socket 传给新 master);`ngx_read_channel` 处理 EAGAIN/EMSGSIZE(:128-145);`ngx_channel_handler` 循环读到 EAGAIN,分发 `QUIT/TERMINATE/REOPEN/OPEN_CHANNEL/CLOSE_CHANNEL` 五种命令(`ngx_process_cycle.c:1079-1123`)。配置还强制 `worker_connections >= listening 数 + 1`(`ngx_event.c:447-460`),那 +1 就是给 channel 预留的连接。

---

## ⑥ 设计动机与取舍:从惊群到 reuseport

多 worker 抢同一 listening socket 的"惊群"问题,在 Nginx 里经历了四代方案,代码里三代共存:

**第一代:accept_mutex(共享内存互斥锁)。** `ngx_event_module_init` 在共享内存里分配 `ngx_accept_mutex_ptr` 并 `ngx_shmtx_create`(`ngx_event.c:541-588`,连带 `ngx_connection_counter` 等 stat 计数器,每项独占 128 字节 cache line,:550-568)。持锁者的语义如 §2 所述:listening 读事件只注册在持锁者的 epoll 里(`ngx_event_process_init` 中 `if (ngx_use_accept_mutex) continue;` 跳过初始注册,:917-919)。缺点:锁轮转粒度是 `accept_mutex_delay`(默认 500ms,:1370);所有新连接都涌向一个 worker,在 keep-alive 大量存在的现代负载下反而制造不均;Win32 上因可能死锁被无条件禁用(:658-667)。

**第二代:EPOLLEXCLUSIVE(1.11.3 起,`changes.xml:7510-7513`)。** `accept_mutex` 默认关闭后,`ngx_event_process_init` 对非 reuseport 的 listening socket 以 `NGX_EXCLUSIVE_EVENT` 注册(:921-937),内核保证一次 EPOLLIN 只唤醒一个 epoll 实例——惊群消失且无用户态锁。但 Linux "通常只通知第一个 add 的进程"(`ngx_event_accept.c:454-459` 注释),负载倾斜,于是有了第三代。

**第三代:`ngx_reorder_accept_events`(1.21.6 修复倾斜,`changes.xml:2837-2851`)。** 每 16 个请求(`c->requests++ % 16 != 0` 短路)且无连接压力时,把 listening 读事件 DEL 后重新以 EXCLUSIVE ADD(`ngx_event_accept.c:476-492`),周期性换掉"第一个 add 的进程"。

**第四代:SO_REUSEPORT(1.9.3,`changes.xml:8831`)。** 每个 worker clone 出自己的 listening socket(`ngx_event_init_conf` 调 `ngx_clone_listening`,`ngx_event.c:462-485`;`ngx_connection.c:99-125` 给每份 socket 设 `ls->worker` 编号),初始化时只注册属于本 worker 的那份(:807-811)并立即挂到 epoll(:905-913)。内核按四元组哈希分流,**既无惊群也无锁,且各 worker 的 accept 路径 cache 独立**。它还改变了锁的语义:`ngx_disable_accept_events` 只在 `all` 参数(EMFILE 场景)为真时才碰 reuseport socket(:423-434),即**reuseport socket 的 accept 不参与互斥,即使 accept_mutex 同时开着**。

取舍总结:accept_mutex 换取绝对无惊群但牺牲并行与公平;EPOLLEXCLUSIVE 无锁但依赖内核行为;reuseport 最彻底,但要求内核支持且流量分流靠哈希(对短连接均匀,对"某条 hash 桶热点"无感知)。Nginx 把三代全留在代码里,由配置组合决定路径——这是理解 `ngx_event_process_init` 那段嵌套 `#if` 的钥匙。

另外两处防御性设计也属于本章:EMFILE/ENFILE 时 `ngx_disable_accept_events(all=1)` 全量停 accept,持锁者直接放锁并把 `ngx_accept_disabled=1`(`ngx_event_accept.c:112-130`);`timer_resolution` 模式下没有定时器可用,靠 accept 事件自身的 `ev->timedout` 分支在下次触发时重新 enable(:37-43)——两条恢复路径对应两种时钟模式,缺一不可。

---

## ⑦ FAQ

**Q1:为什么持锁期间事件要 posted,而不是直接执行 handler?**
为了让"epoll_wait 返回 → accept 完 → 解锁"这段窗口尽量短。epoll 后端在 POST 模式下只做标记和入队(`ngx_epoll_module.c:894-899`),accept 队列处理完立即解锁(`ngx_event.c:255-259`),读/写业务全部排在锁外。若直接执行,一个慢 handler 会拖住所有 worker 的 accept。

**Q2:instance 位到底防什么?怎么工作?**
防"同批次 stale 事件"。注册时把 `ev->instance` 烙进 `epoll_event.data.ptr` 低位(`ngx_epoll_module.c:621`),`ngx_get_connection` 每次复用连接都翻转 instance(`ngx_connection.c:1256-1262`);处理时若 `c->fd == -1 || rev->instance != instance` 则丢弃(`ngx_epoll_module.c:844`)。覆盖两种情形:连接已关未复用(fd=-1),或 fd 已被新连接复用(instance 已翻转)。

**Q3:`timer_resolution` 开与不开,循环行为差在哪?**
开:epoll_wait 无限阻塞,SIGALRM/setitimer 周期打断刷时间(`ngx_event.c:200-203, 698-723`),epoll 侧 EINTR 时检查 `ngx_event_timer_alarm`(`ngx_epoll_module.c:811-815`)。不开(默认):epoll_wait 的 timeout 就是最近定时器的剩余毫秒,返回后统一 `ngx_time_update`(:804-806)。前者时间精度可控但多中断开销,后者零中断但时间只在事件唤醒时前进。

**Q4:为什么 `expire_timers` 排在解锁之后、普通 posted 之前?**
顺序即语义:accept(持锁)→ 解锁 → 超时 → 普通业务。超时 handler 常常关闭连接(如 keepalive 超时),若放在业务之前执行,业务 posted 事件会在下一轮自然消失;若放在业务之后,已到期连接可能多活一轮。把超时夹在"锁外、业务前"是双保险:既不持锁,又不让过期连接参与本轮业务。

**Q5:epoll 下删除事件为什么常常是空操作?**
因为 `close(fd)` 时内核自动把该 fd 从所有 epoll 实例移除(`ngx_epoll_module.c:651-655` 注释),所以 `NGX_CLOSE_EVENT` 只需清 `active` 标志(:657-660)。但代码里留了例外证据:关闭 listening socket 时若在 OpenVZ(Linux 2.6 内核)上,必须显式 DEL,否则内核仍对已 close 的共享 socket 报事件(`ngx_connection.c:1154-1160`)——抽象有裂缝时,Nginx 的做法是就地打补丁并写明原因。

**Q6:`ngx_posted_next_events` 与另外两个队列有何不同?**
它是"下一轮必达"信箱。写入点都是"本轮不宜再写"的场景(如 SSL 缓冲未清、short write 后让出,`ngx_output_chain.c:800`、`ngx_http_write_filter_module.c:335`);循环开头发现非空就 `timer=0` 并把事件整体搬入 `ngx_posted_events`、置 `ready=1, available=-1`(`ngx_event.c:241-244`,`ngx_event_posted.c:39-60`)。它不参与 accept 锁逻辑,且保证 handler 一定运行在"新的一轮"上下文里。

**Q7:UDP 的"连接"是真实连接吗?**
不是。`ngx_event_recvmsg` 对每个新五元组调 `ngx_get_connection(lc->fd, ...)` 拿到的连接 `shared = 1`(`ngx_event_udp.c:203-208`),fd 就是 listening socket 的 fd,逻辑连接按 `crc32(sockaddr)` 挂在 `ls->rbtree` 里(:446-490,`ngx_connection.h:53-54`);后续同源包先查树命中则直接复用(:152-194)。`ngx_close_connection` 对 shared 连接不关 fd(⑤-2 第 6 步)。这套"无连接协议的连接化"让上层(HTTP/QUIC)用同一套 `c->recv/c->send` 抽象。

**Q8:`multi_accept` 打开会发生什么?**
`ev->available = ecf->multi_accept`(`ngx_event_accept.c:47-49`),accept handler 变成 do-while 循环直到 EAGAIN 或 `available` 耗尽(:336)。单轮消化 backlog,减少 epoll 轮次;代价是极端突发下单 worker 独占 CPU 更久,叠加 EPOLLEXCLUSIVE 时会加剧倾斜(reorder 的 16 次计数也会被快速消耗)。

**Q9:`worker_connections` 用尽时系统怎样表现?**
`ngx_get_connection` 返回 NULL 并告警 "worker_connections are not enough"(`ngx_connection.c:1229-1236`);accept 路径上则关闭刚 accept 出来的 fd(`ngx_event_accept.c:144-151`)。但在此之前 `ngx_drain_connections` 已尝试关闭空闲 reusable 连接续命(:1227, 1408-1462),且 `ngx_accept_disabled` 机制会让该 worker 提前退出 accept 竞争(§2)——三层防线层层递进。

**Q10:为什么 `ngx_accept_disabled` 要除以 8、drain 要除以 16?**
都是经验阈值:free 低于 1/8 时停止抢 accept(留 12.5% 余量给已建立的连接继续收尾);free 低于 1/16 才强拆 idle 连接(优先让业务自然结束,drain 是最后手段)。两者错开,避免"既抢不到新连接、又不肯放旧连接"的死区。

---

## ⑧ 深挖问题(供后续验证/讨论)

1. **eventfd 通知语义的内核依赖**。`ngx_epoll_notify_handler` 的设计假设"每次 `write(eventfd)` 恰好产生一次 handler 调用"(§3.4),这依赖内核对 ET 模式下"事件被 epoll_wait 取走后,后续每次 write 都重新入队"的行为;而 `read()` 排空被推迟 2^32 次。若内核(或 eBPF/新 syscall 路径)改变 eventfd 的唤醒合并策略,通知可能丢失或重复。可写一个最小复现程序在多内核版本上验证,并评估 counter 溢出(write 返回 EAGAIN)的到达概率。

2. **`ngx_drain_connections` 的重入深度**。它在 `ngx_get_connection` 内同步调用 `c->read->handler`(`ngx_connection.c:1227, 1444-1445`),而该 handler(HTTP)可能再次 accept/读包/调 `ngx_get_connection`,形成"连接分配函数 → 业务 handler → 连接分配函数"的栈内递归。当前靠 `free_connection_n` 每轮变化收敛,但极端场景(大量 idle + 突发 accept)的栈深度与 handler 重入安全性值得压测验证。

3. **accept_mutex 与 reuseport 的组合矩阵**。两者都开时:`ngx_event_process_init` 对 reuseport socket 无条件注册(:905-913),对普通 socket 走锁路径;`ngx_disable_accept_events(all=0)` 跳过 reuseport(:423-434)。即"同一 worker 内,一部分 socket 受锁调度、一部分永续 accept"。这种混合配置的行为边界(EMFILE 全停、锁轮转期间的流量倾斜)未见文档化,值得整理成行为矩阵。

4. **instance 单位的完备性**。能否构造"一轮 batch 内同一 fd 被 get/free 两次(翻转两次回到原值)且旧事件仍在队列"的场景使 stale 事件漏检?初步论证:stale 事件仅可能来自本批次早些时候被 close 的 fd,该 fd 每被新连接复用一次 instance 翻转一次;漏检要求"close 后复用偶数次",但每次复用都会重新 `epoll_ctl` 烙上新 instance,旧事件只可能在复用发生前的那一次取值——需要严格证明或构造反例(重点看 accept 与 close 在同一 batch 且 fd 复用恰一次的窗口)。

5. **红黑树定时器在 handler 内变更的活性**。`ngx_event_expire_timers` 循环体内 `ev->handler(ev)` 可能插入新 timer(如 accept 后立刻 add_timer)、删除树中其他节点甚至自己。当前实现每轮重新取 min、先 `ngx_rbtree_delete` 再执行 handler(`ngx_event_timer.c:61-94`),对"handler 删任意节点"是安全的;但"handler 内长期不返回"会饿死 posted 队列( expire 与 posted 同轮串行)。可量化:单轮 expire 处理 N 个超时的最坏延迟对高扇出场景(如 mass keepalive 超时风暴)的影响。

---

## 附:与 Redis 卷的对照要点备忘

- 事件循环骨架:两者都是"等 I/O(带 timeout)→ 处理 I/O → 处理时间事件"的 Reactor,但 Nginx 把"时间事件"内化为连接超时红黑树,Redis 把它外化为显式 timeEvent 链表(§4);
- 掩码模型:Redis `AE_READABLE/AE_WRITABLE` 位掩码 vs Nginx `ngx_event_t.read/write` 双对象 + `data.ptr` 回指——前者省内存(index 数组),后者省间接层,各自契合自身连接规模;
- 跨线程唤醒:Redis 主循环单线程无此需求,`ngx_notify`/eventfd 是 Nginx 引入线程池(文件 AIO、thread pool)后必须补的拼图;
- accept 竞争:Redis 无多进程 accept 问题,Nginx 的 accept_mutex→EPOLLEXCLUSIVE→reuseport 演进是它作为多进程服务器独有的历史包袱与解决方案,可直接作为系列文章"架构演进"叙事的主线。
