# C · 事件驱动底座：sd-event 与管理器调度

> 系列：《systemd 深读》卷 C ｜ 基线：commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`
> 卷 A 已讲完 manager_loop 骨架，本卷下沉一层：把 `src/libsystemd/sd-event/sd-event.c`（5529 行）这颗"所有 systemd 守护进程共用的心脏"拆开看，再回到 `src/core/` 数一数 PID 1 挂在它上面的每一个事件源。

## 一、总图：事件源谱系与一轮分发的顺序

```
                    sd-event 事件源谱系（EventSourceType, event-source.h:14-33）
                                           │
   ┌─────────────┬────────────────┬────────┴───────┬────────────────┬─────────────┐
   │ io 类        │ timer 类(5时钟) │ signal 类       │ child 类        │ inotify 类   │ 纯内部类
   │ SOURCE_IO    │ TIME_REALTIME  │ SOURCE_SIGNAL   │ SOURCE_CHILD   │SOURCE_INOTIFY│ DEFER
   │ 每源一个 fd,  │ TIME_BOOTTIME  │ 每优先级共用     │ 优先 pidfd       │ 每优先级共用  │ POST
   │ 独立 epoll   │ TIME_MONOTONIC │ 一个 signalfd   │ (epoll 成员),   │ 一个 inotify │ EXIT
   │ 成员         │ TIME_REALTIME_ │ (sd-event.c:    │ 退化 SIGCHLD+   │ fd          │
   │ (sd-event.c: │ ALARM/         │  1479)          │ waitid 选路     │ (sd-event.c: │
   │  1245)       │ BOOTTIME_ALARM │                 │ (sd-event.c:   │  2600)       │
   │              │ 每时钟共用      │                 │  1610)         │              │
   │              │ 1 个 timerfd   │                 │                │              │
   │              │ (sd-event.c:   │                 │                │              │
   │              │  1390)         │                 │                │              │
   └─────────────┴────────────────┴─────────────────┴────────────────┴─────────────┘
   + PSI 三种：SOURCE_MEMORY/CPU/IO_PRESSURE（pipe fd，sd-event.c:1930 起）
   + SOURCE_WATCHDOG：内部 timerfd，.data.ptr = INT_TO_PTR(SOURCE_WATCHDOG)（sd-event.c:5136）

   一轮 sd_event_run(e, timeout)（sd-event.c:4936；状态机枚举 sd-event.h:53-59）
   ─────────────────────────────────────────────────────────────────────────────
   ① sd_event_prepare (4553)：
      iteration++ (4576) → 跑 .prepare 回调队列 (4375，序：enabled > 非限速 > 本轮未跑 >
      priority，比较函数 sd-event.c:225-251) → arm 五个时钟 timerfd (4588-4606) →
      已有 pending 则跳过睡眠 (4610-4611)
   ② sd_event_wait (4785)：
      epoll_wait 一次 (4668 process_epoll) → io/pidfd 源标 pending；signalfd 每优先级
      只读 1 条；timerfd 到期源标 pending；inotify 读缓冲并按 wd 匹配源标 pending；
      waitid 扫 child；阈值循环保证高优先级事件不被低优先级遮挡 (4800-4834)；喂 watchdog
   ③ sd_event_dispatch (4895)：
      从 pending 堆弹 1 个（序：enabled > 非限速 > priority > pending_iteration，
      sd-event.c:199-223）→ source_dispatch (4197)：先查 ratelimit (4216) → ONESHOT
      自关 (4251) → 用户回调 (4262-4339) → 回调后把所有 post 源标 pending (4237)
```

## 二、sd_event 对象：一个 epoll、五个时钟、六条队列

`struct sd_event` 的字段清单就是设计说明：一个 `epoll_fd`（sd-event.c:119）复用所有 fd 类事件；`pending`/`prepare` 两条全局优先队列（sd-event.c:122-123）；五个 `struct clock_data`（realtime/boottime/monotonic/realtime_alarm/boottime_alarm，sd-event.c:128-132，覆盖 timerfd_create 目前仅支持的五种时钟，注释 sd-event.c:125-127）；按信号号索引的 `signal_sources` 数组 + 按优先级索引的 `signal_data` 哈希（sd-event.c:136-137）；`child_sources` 哈希（sd-event.c:139）；`post_sources` 集合（sd-event.c:142）；`exit` 优先队列（sd-event.c:144）；`inotify_data` 哈希（sd-event.c:146）。

```c
struct sd_event {
        unsigned n_ref;

        int epoll_fd;
        int watchdog_fd;

        Prioq *pending;
        Prioq *prepare;
        ...
        struct clock_data realtime;
        struct clock_data boottime;
        struct clock_data monotonic;
        struct clock_data realtime_alarm;
        struct clock_data boottime_alarm;
        ...
        uint64_t iteration;
        triple_timestamp timestamp;
        int state;
```
（src/libsystemd/sd-event/sd-event.c:116-161，有删节）

创建时 `epoll_fd` 立即被 `fd_move_above_stdio()` 挪出 0-2 区间，防止后来加载的外部代码把 stderr 关掉后误占（sd-event.c:433-439；src/basic/fd-util.c:641-668）。整个对象绑定创建线程：default 事件循环在 prepare 时断言 `e->tid == gettid()`（sd-event.c:4562-4565）——这就是"单线程多路复用"在代码里的执行点。设 `SD_EVENT_PROFILE_DELAYS` 环境变量可打开迭代延迟直方图，每 5 秒打一条 debug 日志（sd-event.c:441-445、4952-4966）。

事件源本体 `sd_event_source`（event-source.h:50-151）：公共头放类型、使能位、优先级、pending/prepare 堆索引、ratelimit 字段（event-source.h:62-85），类型私有部分是 union（event-source.h:87-150）。分配按 type 查 `size_table` 只取 union 用到的那一段（sd-event.c:1184-1219），注释估算最大最小相差 144 字节、超过两条 cache line（sd-event.c:1186-1188）。引用计数：源持 `n_ref`、事件持 `n_ref`，另有 floating 模式（源不持事件引用，sd-event.c:1230-1231）；每个对象带 `origin_id` 溯源戳，跨"事件循环代际"的引用直接判死（sd-event.c:456-477）。

## 三、优先级如何变成三张堆

sd-event 的"分发顺序"不是遍历，而是堆序。一个源最多同时挂在三张（组）二叉堆上（堆算法本身只有 `shuffle_up/shuffle_down` 两个函数，src/basic/prioq.c:87-106；`prioq_reshuffle` 是 O(log n) 的原地重排，src/basic/prioq.c:256-269）：

1. **pending 堆**（每事件一条）：比较序为 enabled 在前、非限速在前、priority 小者在前、`pending_iteration` 小者在前（sd-event.c:199-223）。最后一条保证同优先级"先标 pending 先服务"；defer/exit 源派发时也会把自己推到队尾重排（sd-event.c:4224-4229）。
2. **prepare 堆**：多一个 `prepare_iteration` 维度——本轮已跑过的源沉底，`event_prepare()` 一看到本轮跑过的就可以停（sd-event.c:4384-4388），避免同一批 prepare 反复执行。
3. **时间双堆**：每时钟两张，`earliest` 按"最早可能到期"排、`latest` 按"最晚必须到期"排。结构体注释原文写明设计意图：

```c
struct clock_data {
        WakeupType wakeup;
        int fd;

        /* For all clocks we maintain two priority queues each, one
         * ordered for the earliest times the events may be
         * dispatched, and one ordered by the latest times they must
         * have been dispatched. The range between the top entries in
         * the two prioqs is the time window we can freely schedule
         * wakeups in */

        Prioq *earliest;
        Prioq *latest;
        usec_t next;

        bool needs_rearm;
};
```
（src/libsystemd/sd-event/event-source.h:153-169）

改优先级不是改个数字了事：signal 源要把自己挪到新优先级的 signalfd 上（sd-event.c:2887-2903），inotify 源要在新优先级的 inotify fd 上重建 watch（sd-event.c:2828-2885）；为此 InodeData 会把原始 fd 多保留一轮迭代（event-source.h:190-196；统一在下一轮开始前关闭，sd-event.c:4488-4505），否则"改优先级"会因拿不到 inode 句柄而失败。

## 四、各类事件源的实现要点

**io**：`sd_event_add_io()` 直接 `epoll_ctl(ADD)`，`data.ptr` 指向源，ONESHOT 编译成 `EPOLLONESHOT`（sd-event.c:508-530）；事件到达时 revents 按 OR 合并，以兼容 ONESHOT 下读、写独立触发（sd-event.c:3647-3664）。注意：io 源之间**没有**"同 fd 多源合并"——每个源独立占一个 epoll 成员；真正做"多源并一 fd"的是 timer/signalfd/inotify 三类聚合器（见第五节）。

**timer**：每时钟惰性创建一个 timerfd 并挂入 epoll（sd-event.c:1306-1335），该时钟全部源进 earliest/latest 双堆（sd-event.c:1365-1388）；arm 时只 set timerfd 一次（sd-event.c:3589-3645）。精度窗口由 `accuracy` 控制：默认 250ms（`DEFAULT_ACCURACY_USEC`，sd-event.c:48；调用者传 0 时在 `sd_event_add_time()` 里兜底，sd-event.c:1431），`latest = next + accuracy`（sd-event.c:274-290）；被限速的源首尾相等、不再放大误差（sd-event.c:277-283）。改到期时间会先清 pending 再重排堆（sd-event.c:3162-3172）。

**signal**：每个优先级一个 signalfd（结构体注释原文："For each priority we maintain one signal fd, so that we only have to dequeue a single event per priority at a time"，event-source.h:173-176）。`event_make_signal_data()` 把信号并入该优先级掩码并重建 signalfd（sd-event.c:764-793）；`sd_event_add_signal()` 要求信号必须已屏蔽，否则用 `SD_EVENT_SIGNAL_PROCMASK` 标志让库代为 `pthread_sigmask(SIG_BLOCK)`，并记下"拆源时要不要解开"（sd-event.c:1500-1557）。源断开/离线时 `event_gc_signal_data()` 反向收敛掩码、掩码空则销毁 signalfd（sd-event.c:807-878）。

**child**：现代内核走 pidfd——`(pid, WEXITED)` 型源把 pidfd 注册成 epoll 成员（判定 `EVENT_SOURCE_WATCH_PIDFD`，sd-event.c:50-55；注册 sd-event.c:550-569），进程退出 EPOLLIN 即到，全程不占信号路径；其余组合（WSTOPPED/WCONTINUED）退回 SIGCHLD+waitid 路线并设 `need_process_child`（sd-event.c:1668-1675）。每次 add 强制 `pidfd_open()` 钉住 PID 防复用（sd-event.c:1647-1654），同 PID 重复注册返回 `-EBUSY`（sd-event.c:1640-1641）。waitid 扫描的取舍写在注释里：

```c
/* So, this is ugly. We iteratively invoke waitid() + WNOHANG with each child process we shall wait for,
 * instead of using P_ALL. This is because we only want to get child information of very specific
 * child processes, and not all of them. We might not have processed the SIGCHLD event
 * of a previous invocation and we don't want to maintain a unbounded *per-child* event queue,
 * hence we really don't want anything flushed out of the kernel's queue that we don't care
 * about. Since this is O(n) this means that if you have a lot of processes you probably want
 * to handle SIGCHLD yourself.
 *
 * We do not reap the children here (by using WNOWAIT), this is only done after the event
 * source is dispatched so that the callback still sees the process as a zombie. */
```
（src/libsystemd/sd-event/sd-event.c:3754-3763）

派发回调之后才真正收尸，保证回调里看到的还是僵尸（sd-event.c:4277-4287）。对持有现成 pidfd 的调用方另有 `sd_event_add_child_pidfd()`（sd-event.c:1691-1766）；PID 1 之外常用封装是 `event_add_child_pidref()`（src/libsystemd/sd-event/event-util.c:167-212）。

**defer/post/exit**：defer 创建即 pending（sd-event.c:1799）；post 平时沉睡，靠"任何一个非 post 源派发后统一标 pending"驱动（`maybe_mark_post_sources_pending()`，sd-event.c:4178-4195、调用点 4237；回调执行完还会补一轮，sd-event.c:4366-4370）；exit 源挂独立堆，仅在 `sd_event_exit()` 后由 `dispatch_exit()` 消费，堆空或堆顶离线即进入 FINISHED（sd-event.c:4414-4434）。回调返回负数的通用后果：默认禁用该源，设了 `exit_on_failure` 则令整个循环带码退出（sd-event.c:4350-4359）。

**inotify**：每个优先级一个 inotify fd（event-source.h:221-223），InodeData 按 dev+ino 归并同一 inode 的全部订阅（event-source.h:184-216），实际 add watch 时把所有订阅掩码按位或成 `combined_mask`（sd-event.c:2447-2485）。读侧一次 read 整缓冲；只要该优先级还有 pending 源就不再读新事件——没有本地排队合并策略（sd-event.c:3923-3929、event-source.h:231-234），`source_set_pending()` 里同步增减 `n_pending` 计数（sd-event.c:1168-1179）。处理侧逐条匹配 wd→inode→订阅源（sd-event.c:3965-4040）；IN_Q_OVERFLOW 时广播该 inotify 下全部源，宁可误报不可丢事件（sd-event.c:3986-4001）。

**事件源生命周期**：enable/offline 是唯一的注册/注销路径——`event_source_offline()`（sd-event.c:2938-3012）负责摘 epoll 成员、GC signalfd、递减 `n_online_child_sources`；`event_source_online()`（sd-event.c:3014-3120）反向操作。被限速的源按"离线"参与排序（`event_source_is_online`，sd-event.c:57-65）。PSI 源比较特殊：必须先把 watch 字符串写进 PSI fd 才能 epoll 注册，写不完时挂 write_list 稍后再试（sd-event.c:3084-3092、4507-4529）。

## 五、"并集"与功耗：accuracy + perturb 的合谋

一个 epoll 集里放五类成员：每源 fd（io/pidfd/PSI）、每时钟 1 个 timerfd、每优先级 1 个 signalfd、每优先级 1 个 inotify fd，外加 watchdog timerfd；`WakeupType` 标记 data.ptr 区分回落对象（event-source.h:37-45；分派 sd-event.c:4716-4774）。timerfd/signalfd/inotify 三类是真正的"N 源并 1 fd"：一千个定时器也只有一个 timerfd 能唤醒 epoll。

醒来选哪一刻大有讲究。`event_arm_timer()` 在 earliest 堆顶与 latest 堆顶之间选点，并把选出的绝对时间一次性写进 timerfd：

```c
        a = prioq_peek(d->earliest);
        assert(!a || EVENT_SOURCE_USES_TIME_PRIOQ(a->type));
        if (!a || a->enabled == SD_EVENT_OFF || time_event_source_next(a) == USEC_INFINITY) {
                ...
                /* disarm */
                if (timerfd_settime(d->fd, TFD_TIMER_ABSTIME, &its, NULL) < 0)
                        return -errno;
                ...
        }

        b = prioq_peek(d->latest);
        assert(!b || EVENT_SOURCE_USES_TIME_PRIOQ(b->type));
        assert(b && b->enabled != SD_EVENT_OFF);

        t = sleep_between(e, time_event_source_next(a), time_event_source_latest(b));
```
（src/libsystemd/sd-event/sd-event.c:3605-3627，有删节；选点后 `timerfd_settime` 在 3640）

`sleep_between()` 把唤醒对齐到整分/整 10s/整 1s/整 250ms 边界（sd-event.c:3542-3586），偏移量取自 boot ID 哈希出的 `perturb`（sd-event.c:1288-1304）——注释明说目标是"全系统的事件合并成一次 CPU 唤醒"，而机器之间又因 perturb 互错开（sd-event.c:3524-3540）。accuracy 因此不只是容差，而是用户向内核定时器合并与省电让渡的空间；Timer unit 的 `AccuracySec` 直接透传该参数（src/core/timer.c:573-578、613-618；默认值来自 manager defaults，src/core/timer.c:45）。

等待本身也有细节：`epoll_wait_usec()` 优先尝试 `epoll_pwait2`，不支持再退 `epoll_wait`（sd-event.c:4626-4666）；返回事件数打满缓冲会扩容重收，上限 10 倍（sd-event.c:4699-4710）。

## 六、循环内时间、prepare 两阶段与事件源限速

**循环内时间**：epoll 回来后取一次 `triple_timestamp_now()` 缓存进 `e->timestamp`（sd-event.c:4712-4714），此后整轮的 `sd_event_now()` 都返回这份缓存时间（sd-event.c:5051-5068）——同一轮内所有定时器判定、超时计算用同一把尺，消除派发过程中的时间漂移。

**prepare 两阶段**：`.prepare` 回调让源在"开睡之前"最后刷新一次条件。执行顺序见总图①；关键性质是 prepare 里可以把新源标 pending，使本轮直接跳过睡眠（sd-event.c:4610-4611）。核心循环很短：

```c
        for (;;) {
                sd_event_source *s;

                s = prioq_peek(e->prepare);
                if (!s || s->prepare_iteration == e->iteration || event_source_is_offline(s))
                        break;

                s->prepare_iteration = e->iteration;
                prioq_reshuffle(e->prepare, s, &s->prepare_index);

                assert(s->prepare);
                s->dispatching = true;
                r = s->prepare(s, s->userdata);
                s->dispatching = false;
```
（src/libsystemd/sd-event/sd-event.c:4380-4393）

重设定时器的惯用法封装在 `event_reset_time()`：已存在的源只改时间/精度/使能而不重建（src/libsystemd/sd-event/event-util.c:23-98），Timer unit 与 job 定时器都靠它避免反复分配。

**限速建在事件源层**：`sd_event_source_set_ratelimit(interval, burst)` 只对可限速类型开放（sd-event.c:5246-5262；类型白名单 `EVENT_SOURCE_CAN_RATE_LIMIT`，sd-event.c:96-109）。检查点在 `source_dispatch()` 入口：

```c
/* Check if we hit the ratelimit for this event source, and if so, let's disable it. */
assert(!s->ratelimited);
if (!ratelimit_below(&s->rate_limit)) {
        r = event_source_enter_ratelimited(s);
        if (r < 0)
                return r;

        return 1;
}
```
（src/libsystemd/sd-event/sd-event.c:4214-4222）

进入限速态的技巧是"把源假装成 CLOCK_BOOTTIME 定时器"：先从原生时钟堆摘下、挂进 boottime 双堆（到期点=限速窗口终点）、再正式离线（sd-event.c:3395-3441）；窗口结束后 `process_timer()` 经 `event_source_leave_ratelimit()` 复活它，可选触发 `ratelimit_expire_callback`（sd-event.c:3443-3507、3711-3723）。触发后果即"该源整个窗口静默"，其余源照常——与 manager_loop 的全循环级 `event_loop_ratelimit`（过快则睡 1 秒，src/core/manager.c:3636-3640）和 unit 的 `start_ratelimit`（StartLimitBurst，超限走 emergency_action，src/core/unit.c:1873-1897；字段 src/core/unit.h:375）构成三层不同的闸门。manager 还示范了限速与定时器的缝合：auto start/stop 被限速时用 `sd_event_add_time(CLOCK_BOOTTIME, ratelimit_end(...))` 排一个"解禁重试"定时器（src/core/manager.c:1499-1523）。

**高优先级遮蔽的修补**：`sd_event_wait()` 里有个阈值重试循环——process_epoll/process_child 记录本轮实际入队的最低优先级，下一轮只收比它更优先的事件，直至无新货（sd-event.c:4800-4834）；注释给出出处：上游 issue 18190（新到 IO 事件与 child 事件竞争时的漏报，sd-event.c:4803-4809）。

## 七、PID 1 挂了哪些事件源

管理器侧优先级表本身就是文档（src/core/manager.h:737-754，数值越小越先）：

| 事件源 | 类型 | 优先级 | 注册点 |
|---|---|---|---|
| cgroup inotify（cgroup.events/memory.events） | io | NORMAL-10 | src/core/cgroup.c:3346 |
| cgroup OOM（defer 扇出） | defer | NORMAL-9 | src/core/cgroup.c:3156 |
| pidref 传输 / handoff 时间戳 | io | NORMAL-8/-7 | src/core/manager.c:1298/1249 |
| exec fd（服务启动失败回传） | io | NORMAL-6 | src/core/service.c:1964 |
| notify fd（sd_notify） | io | NORMAL-5 | src/core/manager.c:1143 |
| SIGCHLD 收尸（defer） | defer | NORMAL-4 | src/core/manager.c:790 |
| 信号表 signalfd | io | NORMAL-3 | src/core/manager.c:588 |
| cgroup empty（defer 安全网） | defer | NORMAL-2 | src/core/cgroup.c:3321 |
| 时钟跳变（TFD_TIMER_CANCEL_ON_SET） | io | NORMAL-1 | src/core/manager.c:407 |
| 时区变化（/etc/localtime inotify） | inotify | NORMAL-1 | src/core/manager.c:465 |
| D-Bus/Varlink 总线（sd_bus_attach_event） | sd-bus 内建 io | NORMAL(IPC) | src/core/dbus.c:714,906,969 |
| 私有总线监听 | io | NORMAL | src/core/dbus.c:1035 |
| service watchdog | timer | IDLE | src/core/service.c:354-369 |
| run_queue 派发（defer） | defer | IDLE+1 | src/core/manager.c:767 |

未列入表的还有：用户查找应答 fd（src/core/manager.c:1200）、作业进度动画定时器（src/core/manager.c:178）、ask-password inotify（src/core/manager.c:342）、控制台 idle pipe（src/core/manager.c:379）、PSI 三种压力源（src/core/manager.c:814-841）。其余按类型散布在 unit 实现里：socket 监听 fd（src/core/socket.c:1811）、automount 的 autofs pipe（src/core/automount.c:389,729）与 expire 定时器（src/core/automount.c:826）、path 的 inotify fd（src/core/path.c:63）、mount/swap 的 /proc 表 EPOLLPRI（src/core/mount.c:2111、src/core/swap.c:1374）、service 的 fdstore io（src/core/service.c:707）、job 的 start/timeout 定时器（src/core/job.c:1187,1400）。

cgroup 空检测是"inotify + defer"两级：watch 挂在 `cgroup.events`（IN_MODIFY，src/core/cgroup.c:2038）与 `memory.events`（src/core/cgroup.c:2093）上；事件回读 populated/frozen 后入队（src/core/cgroup.c:3187-3201），由 cgroup-empty defer 源消费并 `unit_prune_cgroup`（src/core/cgroup.c:2938-2972）。旧式 cgroup v1 release 代理已不存在，空 cgroup 的释放全部由这条事件链驱动（src/core/cgroup.c:2765-2789）。时区监听还有个细节：`/etc/localtime` 不存在时退订 /etc 目录等创建（src/core/manager.c:467-480）。

run_queue 的"按需唤醒"模式值得再看一眼：defer 源平时 OFF，入队时 `manager_trigger_run_queue()` 置 ONESHOT，派发时把队列抽干：

```c
        while ((j = prioq_peek(m->run_queue))) {
                assert(j->installed);
                assert(j->in_run_queue);

                (void) job_run_and_invalidate(j);
        }

        if (m->n_running_jobs > 0)
                manager_watch_jobs_in_progress(m);
```
（src/core/manager.c:2880-2888）

```c
r = sd_event_source_set_enabled(
                m->run_queue_event_source,
                prioq_isempty(m->run_queue) ? SD_EVENT_OFF : SD_EVENT_ONESHOT);
```
（src/core/manager.c:2901-2903）

## 八、走通一条路：SIGCHLD 从内核到回调

PID 1 的服务进程收尸**不用** `sd_event_add_child`，而是走"信号 + defer"的 manager 级路线（`src/core/` 无任何 `sd_event_add_child` 调用）。先画时间线：

```
子进程 exit()
  │ 内核投递 SIGCHLD（已在屏蔽字中, manager.c:538-584 → 排队进 signalfd）
  ▼
epoll_wait 返回: signal_fd EPOLLIN            [io 源, 优先级 NORMAL-3]
  │ manager_dispatch_signal_fd()              manager.c:3292
  │ case SIGCHLD: sigchld defer 源置 ON       manager.c:3326-3331
  ▼
pending 堆弹出 sigchld defer 源               [defer, 优先级 NORMAL-4, 更先]
  │ manager_dispatch_sigchld()
  │ waitid(P_ALL, WNOHANG|WNOWAIT) 窥视       manager.c:3180
  │ manager_get_units_for_pidref() 找 unit    manager.c:3212
  │ manager_invoke_sigchld_event() 扇出        manager.c:3229
  │ waitid(P_PID) 真收尸                       manager.c:3234
  │ 无更多孩子 → 源关回 OFF                    manager.c:3241-3248
  ▼
Service 状态机推进 → unit_notify() → 可能入 run_queue → run_queue defer 源(IDLE+1)
```

关键步骤的细节：

1. SIGCHLD 在 `manager_setup_signals()` 里进屏蔽字、进 signalfd 掩码（src/core/manager.c:538-584）；
2. 子进程退出，signalfd 可读，epoll 唤醒 io 源 `manager_dispatch_signal_fd()`（src/core/manager.c:3292）；
3. `case SIGCHLD:` 分支把 sigchld defer 源置 ON（src/core/manager.c:3326-3331）——处理被推迟到优先级更高的独立源（NORMAL-4 早于 NORMAL-3，同轮 pending 堆先弹它）；
4. `manager_dispatch_sigchld()` 先 `waitid(P_ALL, WNOHANG|WNOWAIT)` **窥视**不收（僵尸保持可查 /proc），按 PidRef 找回所属 unit 扇出 `manager_invoke_sigchld_event()`，最后才 `waitid(P_PID)` 真收尸（src/core/manager.c:3180、3204-3229、3234）；
5. 没有更多孩子则把源关回 OFF（src/core/manager.c:3241-3248）。

对照 cgroup inotify 路径：内核改写 cgroup.events → manager 的 inotify fd EPOLLIN（NORMAL-10，最先处理）→ `on_cgroup_inotify_event()` read 循环、wd→unit 查表（src/core/cgroup.c:3213-3254）→ 入 empty 队列并点亮 NORMAL-2 的 defer 源（src/core/cgroup.c:2974-2991）——注释明言它是 SIGCHLD 之后的"最后安全网"，专收非亲生进程的 scope unit（src/core/cgroup.c:2976-2979）。两条路径在同一轮 pending 堆里按优先级自然排出次序：先 inotify 读、再 SIGCHLD 收尸、最后 cgroup-empty 清场。

## 九、watchdog 一句话

`manager_loop` 每轮 `watchdog_ping()`（src/core/manager.c:3642），而 sd-event 内建 `sd_event_set_watchdog()` 用 timerfd 在半周期自动发 `WATCHDOG=1`（sd-event.c:5107-5157、4451-4486）——事件循环一旦卡死（某回调长眠不返），timerfd 无人消费、心跳即停，监督者据此重启 PID 1；这也是 loop 睡眠上限取 `watchdog_runtime_wait(2)` 的原因（src/core/manager.c:3678）。

顺带一提：`sd_event_run()` 检测到协程环境时整体委派给 `event_run_suspend()`（sd-event.c:4949-4950；实现 src/libsystemd/sd-event/event-future.c:239），同一套 prepare/wait/dispatch 原语也可驱动 fiber 化的调用方——库的内核仍是那个单线程 epoll。

## 十、设计动机

1. **为什么自研 sd-event 而不用 libev/libuv？** 需要的全是 Linux 专属原语：pidfd 等待子进程（sd-event.c:1650）、PSI 压力通知（sd-event.c:1930 起）、per-priority signalfd/inotify 聚合（event-source.h:173-176、221-223）、`TFD_TIMER_CANCEL_ON_SET` 时钟跳变（src/basic/time-util.c:1853-1861）；跨平台抽象层反而是纯负担。且"源即对象"的引用计数/优先级/限速语义要与 sd-bus 和 PID 1 的十余条队列严丝合缝，通用库给不了。
2. **为什么单线程？** 一个 epoll 收敛全部并发（sd-event.c:119），把竞争降维成 pending 堆的排序键（sd-event.c:199-223）；default loop 的线程断言（sd-event.c:4562-4565）让违规者当场爆掉。PID 1 的 units/jobs 图因此全程免锁。
3. **为什么 timer 需要 accuracy？** earliest/latest 双堆夹出的窗口（event-source.h:157-162）加上 `sleep_between()` 的边界对齐（sd-event.c:3542-3586），允许成百上千个定时器合并成一次 CPU 唤醒——accuracy 是用户向内核让渡的调度自由，直接换续航；boot ID 派生的 perturb 又保证多机不同步唤醒（sd-event.c:1288-1304）。
4. **为什么要有 post 源？** "本轮所有别的活干完后跑一次"（sd-event.c:4237 的集中标 pending）给状态广播、GC 这类收尾工作一个确定时点；`event_loop_idle()` 判空闲时显式豁免未决的 post 源（sd-event.c:4531-4551）——没有它，"循环是否空闲"都无法定义。
5. **为什么 ratelimit 建在事件源层？** 疯狂循环的元凶总是"某一个源被事件风暴反复点亮"；把闸门放在派发入口（sd-event.c:4216）并让源"静默一个窗口"（转成 boottime 假定时器，sd-event.c:3400-3420），可外科手术式掐掉风暴而循环其余部分照常；manager 层的 unit start limit 与 loop 级节流只是它的补充。
6. **为什么 defer 源无处不在？** inotify/signalfd/PSI 只能说"有事"，不携带业务语义；defer 源（run_queue、sigchld、cgroup-empty/oom，见第七节表）把"事件→队列→批量消费"的扇出统一成事件循环原语，天然带优先级与 ONESHOT 语义。

## 写作素材清单（文件：行号，均已实际读码核对）

1. src/libsystemd/sd-event/event-source.h:14-33 —— 16 种事件源类型枚举；:37-45 WakeupType 鉴别
2. src/libsystemd/sd-event/event-source.h:50-151 —— sd_event_source 结构（公共头+类型 union）
3. src/libsystemd/sd-event/event-source.h:153-182 —— clock_data 双堆与 per-priority signal_data
4. src/libsystemd/sd-event/sd-event.c:116-186 —— struct sd_event 全字段
5. src/libsystemd/sd-event/sd-event.c:199-251 —— pending/prepare 两堆比较函数
6. src/libsystemd/sd-event/sd-event.c:253-290 —— time_event_source_next/latest（accuracy 窗口）
7. src/libsystemd/sd-event/sd-event.c:716-805 —— event_make_signal_data：signalfd 协商
8. src/libsystemd/sd-event/sd-event.c:1390-1446 —— sd_event_add_time（默认 accuracy、ONESHOT）
9. src/libsystemd/sd-event/sd-event.c:1610-1689 —— sd_event_add_child：pidfd/SIGCHLD 选路
10. src/libsystemd/sd-event/sd-event.c:3395-3507 —— 事件源限速进入/离开（boottime 假定时器）
11. src/libsystemd/sd-event/sd-event.c:3509-3645 —— sleep_between 对齐与 event_arm_timer
12. src/libsystemd/sd-event/sd-event.c:4553-4624 + 4785-4921 —— prepare/wait/dispatch 三段状态机
13. src/libsystemd/sd-event/sd-event.c:4197-4373 —— source_dispatch：限速检查、post 标记、收尸时机
14. src/core/manager.c:761-805 + 2874-2906 —— run_queue/sigchld defer 源与按需触发
15. src/core/manager.c:3170-3249 + 3292-3331 —— SIGCHLD 窥视/收尸与"信号→defer"接力
16. src/core/cgroup.c:2038 + 3177-3254 + 3293-3357 —— cgroup.events inotify 全链与两级优先级

（本报告所有行号基于基线 commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4` 实际读码核对；test/ 目录不在本地，未引用任何测试文件。）
