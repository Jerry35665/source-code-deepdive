# 报告 F · 激活器与工程文化：socket/timer/path 激活与测试纪律

基线：systemd commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`（浅克隆 + sparse 检出，含 `src/`、`man/` 与根文件；`test/` 不在本地，本报告不引用其行号）。所有 `文件:行号` 均经实际读取核对。路径以仓库根为基准。

---

## 0. 总览图：fd 传递链与 timer 双轨

```
                    SOCKET ACTIVATION：fd 的一生
 ─────────────────────────────────────────────────────────────────────
  socket.unit 启动
  socket_open_fds()  socket.c:1664
    ├─ SOCKET_SOCKET   → socket_address_listen_in_cgroup (socket.c:1551)
    │                     └─ socket_address_listen()  在 unit 的 cgroup/netns 里
    ├─ SOCKET_FIFO     → fifo_address_create   (socket.c:1728)
    ├─ SOCKET_SPECIAL  → special_address_create(socket.c:1721)
    ├─ SOCKET_MQUEUE   → mq_address_create     (socket.c:1741)
    └─ SOCKET_USB_FUNCTION → usbffs ep0        (socket.c:1750)
        │
        ▼
  socket_enter_listening → socket_watch_fds: sd_event_add_io(EPOLLIN)
        │                 (socket.c:1811, 回调 socket_dispatch_io socket.c:3188)
        ▼  连接到达
  socket_enter_running(cfd)  socket.c:2437
    ├─ Accept=yes: accept() 出 per-connection fd (socket.c:3211)
    │     └─ instance_from_socket() 生成实例名 (socket.c:855)
    │        service_set_socket_fd() → 每连接一个 service 实例 (socket.c:2550)
    └─ Accept=no: 不 accept，把【全部监听 fd】交给单个 service
          └─ service_collect_fds → socket_collect_fds (socket.c:3414)
        │
        ▼  exec 子进程内（exec-invoke.c）
  close_all_fds(keep_fds)            exec-invoke.c:6307
  pack_fds(): fcntl(F_DUPFD, i+3)    exec-invoke.c:6309 → basic/fd-util.c:409
        │                            断言 fds[0]==3 (fd-util.c:451)
  flag_fds(): 清除 FD_CLOEXEC        exec-invoke.c:6311 → :128
        │
        ▼
  环境: LISTEN_PID= / LISTEN_PIDFDID= / LISTEN_FDS= / LISTEN_FDNAMES=
                                       (exec-invoke.c:2024-2043)
  子进程按约定从 fd 3 开始读: SD_LISTEN_FDS_START=3 (systemd/sd-daemon.h:54)

                    TIMER：日历轨 × 单调轨
 ─────────────────────────────────────────────────────────────────────
  timer_enter_waiting()  timer.c:372  对每条 TimerValue 求下次触发：
    ├─ OnCalendar (TIMER_CALENDAR)          → calendar_spec_next_usec()
    │     timer.c:394-472                     (calendarspec.c:1495)
    │     实时轨：next_elapse_realtime       sd_event_add_time(CLOCK_REALTIME[_ALARM])
    │                                          timer.c:613-618
    └─ OnBootSec/OnStartupSec/OnUnitActiveSec/OnUnitInactiveSec (单调轨)
          timer.c:477-516                    sd_event_add_time(CLOCK_MONOTONIC
          next_elapse = base + value           或 BOOTTIME_ALARM) timer.c:573-578
          timer.c:526
    两条轨各取 MIN (timer.c:470,540)，谁先到点谁触发 timer_dispatch (timer.c:804)
    Persistent= → 戳文件 /var/lib/systemd/timers/stamp-<unit>  (timer.c:146)
    timer_start 读回戳文件补算 last_trigger → 开机 catch-up (timer.c:704-718)
```

---

## 1. socket unit：监听套接字的创建与五种端口类型

socket unit 的核心数据是 `SocketPort` 链表：每条 `ListenStream=`/`ListenDatagram=`/`ListenFIFO=` 等指令对应一个端口对象，携带 `fd`、类型与地址（`src/core/socket.h:47-60`）。端口类型枚举只有五种：`SOCKET_SOCKET`、`SOCKET_FIFO`、`SOCKET_SPECIAL`、`SOCKET_MQUEUE`、`SOCKET_USB_FUNCTION`（`src/core/socket.h:23-31`）——TCP/UDP/unix/netlink 都归入 `SOCKET_SOCKET`，由 `SocketAddress` 区分协议族。

统一的开号入口是 `socket_open_fds()`（`src/core/socket.c:1664`），它遍历所有端口按类型分派：socket 类先确定 SELinux 标签再调用 `socket_address_listen_in_cgroup()`（`socket.c:1711`）；FIFO、特殊文件（/dev/null、/proc/kmsg 等）、POSIX 消息队列、USB FunctionFS 各有专属 create 函数（`socket.c:1719-1771`）。

一个值得驻留的细节：监听套接字并非在 manager 进程里直接 `socket()+bind()`，而是包装在 `socket_address_listen_in_cgroup()` 中——必要时 fork 一个助手进程，进入 unit 的 cgroup 与网络命名空间后再创建套接字，从而让 BPF 防火墙、cgroup 匹配能正确关联（`socket.c:1561-1564` 注释）。是否需要 fork 由 `fork_needed()` 判定：NFTSet=cgroup、IPv4/6 + BPF 可用、或配置了网络命名空间才走这条路（`socket.c:1530-1549`），否则"Shortcut things..."直接创建（`socket.c:1566-1573`）。

`Listen=` 到的地址还支持符号链接：`socket_symlink()` 会为 unix socket/FIFO 的路径按 `Symlinks=` 建软链，且 `RemoveOnStop=` 模式下先 unlink 再重建（`socket.c:1343-1368`）。

---

## 2. Accept=yes/no：一次 IO 事件的两种分派

事件回调 `socket_dispatch_io()`（`socket.c:3188`）只在 `SOCKET_LISTENING` 状态处理 `EPOLLIN`，随后就是全文最关键的分支：

```c
/* src/core/socket.c:3207-3221 */
if (p->socket->accept &&
    p->type == SOCKET_SOCKET &&
    socket_address_can_accept(&p->address)) {

        cfd = socket_accept_in_cgroup(p->socket, p, fd);
        if (cfd == -EAGAIN) /* Spurious accept() */
                return 0;
        if (cfd < 0)
                goto fail;

        (void) socket_set_xattrs(cfd, NULL, p->socket->xattr_accept);
        socket_apply_socket_options(p->socket, p, cfd);
}

socket_enter_running(p->socket, cfd);
```

即：Accept=yes 时由 manager 代为 `accept()` 拿到连接 fd `cfd`；Accept=no 时 `cfd<0` 原样传入。分派逻辑集中在 `socket_enter_running()`（`socket.c:2437`）：

- **Accept=no（`cfd < 0`）**：检查 `Triggers` 依赖里是否有已活跃的 service，没有则 `manager_add_job(JOB_START, s->service)` 拉起目标服务，socket 自己进入 `SOCKET_RUNNING`（`socket.c:2469-2502`）。之后由 service 侧反向收集 fd——`service_collect_fds()` 遍历 `TriggeredBy` 依赖，对每个 socket 调 `socket_collect_fds()` 拿全部监听 fd（`src/core/service.c:1882-1906`；`socket.c:3414-3448`，注释明确写着 "Called from the service code for requesting our fds"）。
- **Accept=yes（`cfd >= 0`）**：先过 `max_connections` 与 `max_connections_per_source` 两道限流（`socket.c:2507-2533`），再由 `socket_load_service_unit()` 用 `instance_from_socket()`（从本机/对端地址加 SOCK_COOKIE 拼出实例名，`socket.c:855-897`）构造 `foo@N-<cookie>-<本地地址>-<对端地址>.service` 实例（`socket.c:1446-1471`），`service_set_socket_fd()` 把连接 fd 绑到实例上，fd 所有权随即移交（`TAKE_FD(cfd)`，`socket.c:2550-2559`），最后 `JOB_REPLACE` 启动该实例（`socket.c:2564`）。

**DeferTrigger=：激活也可以"等一等"**。`socket_enter_running()` 里 Accept=no 分支若 `manager_add_job` 因事务冲突（`BUS_ERROR_TRANSACTION_IS_DESTRUCTIVE`）失败，且配置了 `DeferTrigger=`，则转入 `socket_enter_deferred()`：挂一个 `DeferTriggerMaxSec= 安全网定时器、把自己加入 stop 通知队列、关掉 IO 事件源（`socket.c:2487-2495, 2412-2435`）。此后任何 unit 停止都会重试排队 job（`socket_stop_notify()`，`socket.c:2387-2410`），注释把这概括为"触发条件从 socket IO 变成了冲突依赖的消亡"（`socket.c:2418-2423`）。`socket_may_defer()` 的 YES 档只在 job 池非空时等待，PATIENT 档无条件等（`socket.c:2367-2385`）。这是观察 systemd 如何用状态机表达"暂时不能做、但别丢"的绝佳样本。

**daemon-reload 之后**：`socket_coldplug()` 从序列化状态恢复，DEFERRED 一律折回 LISTENING 交给 `socket_enter_running()` 重新决策（"This saves us the trouble of handling flipping of DeferTrigger= vs Accept= during reload"，`socket.c:1902-1914`）；fd 不再盲目重开，而是核对数量、不齐就大声告警（`socket.c:1936-1941`）。

无论哪种模式，进入服务前 fd 都要经历同一套"包装"。exec 子进程里先 `close_all_fds(keep_fds)` 只保留要传递的 fd（`src/core/exec-invoke.c:5293-5326, 6307`），随后 `pack_fds()` 把它们重排到从 3 开始的连续编号（`exec-invoke.c:6309`），再 `flag_fds()` 清掉 `FD_CLOEXEC` 并按 `NonBlocking=` 设置 O_NONBLOCK（`exec-invoke.c:6311`，实现 `exec-invoke.c:103-134`，注释直言 "We unconditionally drop FD_CLOEXEC ... since after all we want to pass these fds to our children"）。环境变量四件套在同一函数早前拼好：`LISTEN_PID`、`LISTEN_PIDFDID`（pidfd 时代防 PID 复用）、`LISTEN_FDS`、`LISTEN_FDNAMES=`（冒号连接的 fd 名单）（`exec-invoke.c:2021-2045`）。

对端约定在公共头文件里只有一行注释加一个宏：

```c
/* src/systemd/sd-daemon.h:53-54 */
/* The first passed file descriptor is fd 3 */
#define SD_LISTEN_FDS_START 3
```

库侧 `sd_listen_fds()` 据此校验并逐个 fd 加上 FD_CLOEXEC（`src/libsystemd/sd-daemon/sd-daemon.c:44-98`，循环起点 `:98`）；"打包到 3" 的算法 `pack_fds()` 用 `fcntl(F_DUPFD, i+3)` 原地重排并断言 `fds[0]==3`（`src/basic/fd-util.c:409-453`）。注意协议的正确性由两头共同保证：应用只看 `LISTEN_FDS` 计数与 `SD_LISTEN_FDS_START` 起点即可，无需知道 manager 里 fd 原本是什么号。

fd 还有第三条路：systemd PID1 自身也能作为接收方，`main.c` 启动时解析自己的 `LISTEN_PID=/LISTEN_FDS=/LISTEN_FDNAMES=` 环境并导入 fd 哈希表（`src/core/main.c:3224-3280`），manager 随后把带 `unit-id|fdname` 标签的 fd 路由进对应 unit 的 fd store，其余的分发给 socket unit（`src/core/manager.c:2243-2252`）——这是容器管理器把"预热好"的套接字直接递给 PID1 的通道。序列化侧，socket unit 在 daemon-reload/reexec 时用 `fdset_put_dup()` 把端口 fd 存入 FDSet 并以 `socket=...`/`fifo=...` 键写入序列化文件（`socket.c:2671-2718`；FDSet 实现见 `src/shared/fdset.c:23,125`）。

最后是自我保护：触发频率限流 `trigger_limit` 默认 2s 窗口，Accept=yes 允许 burst 200、Accept=no 仅 20（`socket.c:332-335`），注释解释了不对称的原因——Accept=yes 下 manager 先 accept 走了连接，而 Accept=no 依赖服务自己消费队列（`socket.c:320-330`）；超限即 `socket_enter_stop_pre(SOCKET_FAILURE_TRIGGER_LIMIT_HIT)`（`socket.c:2463-2467`）。

把控制流摊开看，socket unit 是一台多态状态机：`DEAD → START_PRE → START_CHOWN → START_OPEN → START_POST → LISTENING → RUNNING/DEFERRED`，退出侧 `STOP_PRE（含 SIGTERM/SIGKILL 子态）→ STOP_POST → DEAD`，全枚举见 `src/basic/unit-def.h:170-189`。每一步入口都是一个 `socket_enter_*()` 函数，失败统一汇入 `socket_enter_stop_pre(f)` 携带失败码——`SOCKET_FAILURE_TRIGGER_LIMIT_HIT`、`SOCKET_FAILURE_START_LIMIT_HIT` 等失败枚举与 D-Bus 的 Result 属性一一对应（`src/core/socket.h:33-45`）。控制命令有五个挂载点（StartPre/StartChown/StartPost/StopPre/StopPost，`src/core/socket.h:13-21`），`StartChown` 的存在解释了一个老问题：为什么监听套接字的属主可以在 unit 配置里指定——配置了 User=/Group= 时 manager 需要一个独立阶段在开号后、服务前跑 chown 助手（`socket_enter_start_chown()`，`socket.c:2295-2318`）。激活器三兄弟（socket/timer/path）全部遵循这套"enter_* 状态函数 + vtable 挂钩"的写法，读熟一个即可平移到另外两个。

---

## 3. timer unit：日历轨与单调轨并行

timer 是"零进程"的 unit：全部逻辑是算两个时间戳，然后把两个 `sd_event` 时间源挂到事件循环上。`timer_enter_waiting()` 开头就摆出双轨标志：

```c
/* src/core/timer.c:372-373 */
static void timer_enter_waiting(Timer *t, bool time_change) {
        bool found_monotonic = false, found_realtime = false;
```

**日历轨（OnCalendar）**：以 `last_trigger`（或 DeferReactivation 下的 `inactive_enter_timestamp`、或本 unit 上次退出时间）为基准，调 `calendar_spec_next_usec()` 求下一次匹配（`timer.c:406-455`），结果写入 `next_elapse_realtime` 并取各条最小值（`timer.c:467-472`）。`RandomizedDelaySec=` 的实现很讲究：先把基准减去随机偏移再求下一个日历点、求完加回（`timer.c:443-455`），否则"晚点火的 catch-up 会跳过下一个日程"。

**单调轨**：`timer_base_table` 列全了六个指令名（`timer.c:1043-1050`）。`OnBootSec` 基准为 0（CLOCK_MONOTONIC 即 uptime，容器内改用自身启动时刻，`timer.c:486-498`）；`OnUnitActiveSec`/`OnUnitInactiveSec` 以触发目标的进出活跃时间为基准（`timer.c:500-512`）；一次性基准触发后把 `v->disabled=true` 置废（`timer.c:528-534`）。结果取最小写入 `next_elapse_monotonic_or_boottime`（`timer.c:537-542`）。

两轨分别注册事件源：单调轨用 `CLOCK_MONOTONIC`，`WakeSystem=yes` 时升级为 `CLOCK_BOOTTIME_ALARM`（`timer.c:573-578`）；实时轨用 `CLOCK_REALTIME`/`CLOCK_REALTIME_ALARM`（`timer.c:613-618`）。到点回调 `timer_dispatch()` 直接 `timer_enter_running()`（`timer.c:804-813`）：排队 `JOB_START` 触发目标、记录 `last_trigger`、touch 戳文件（`timer.c:668-680`）。

**Persistent= 与 catch-up**：`timer_setup_persistent()` 为系统 manager 生成 `/var/lib/systemd/timers/stamp-<unit>` 戳文件路径并为此挂载点加 REQUIRES 依赖（`timer.c:131-168`）；`timer_start()` 读回戳文件的 mtime，仅当它在过去才采信为 `last_trigger.realtime`，未来时间戳（时钟错乱）拒绝（`timer.c:704-718`）。重启后 `timer_enter_waiting` 以这个 last_trigger 为基准补算日历轨，配合上面"预减随机偏移"就实现了错过日程的追火。此外 timer 序列化 `last-trigger-realtime/monotonic`（`timer.c:748-752`）保证 soft-reboot 不丢基准，`timer_time_change()`/`timer_timezone_change()`（`timer.c:863-901`）在时钟或时区跳变时整表重算——日历轨依赖墙上时钟，这是它必须自愈的原因。

**触发信息向服务侧的传递**：timer 触发时会把 `last_trigger` 打包进 ActivationDetails，被触发服务由此能在环境里读到 `TRIGGER_TIMER_REALTIME_USEC=`/`TRIGGER_TIMER_MONOTONIC_USEC=`（`timer.c:986-1004`），path unit 也有同构的 `activation_details_path_append_env()`（`src/core/path.c:953`）——被激活者知道自己为何被唤醒，这是三个激活器共享的第四层协议。`RandomizedDelaySec=` 的随机源也别有用心：`timer_get_fixed_delay_hash()` 用 machine-id + uid + unit id 做 SipHash，同一 unit 每次开机得到同一伪随机偏移（`timer.c:171-199`），散布可预期、调试可复现。

**日历解析器**：`calendar_spec_from_string_full()` 是手写递归下降解析（星期、日期链、时间链，`src/shared/calendarspec.c:870` 起）；求下一匹配点 `calendar_spec_next_usec()`（`calendarspec.c:1495`）按指定时区换算后调 `calendar_spec_next_usec_impl()`（`calendarspec.c:1464`）：localtime 后交给 `find_next()` 逐字段（年→月→日→时→分→秒→微秒）向前搜索，`MAX_CALENDAR_ITERATIONS 1000` 封顶防止永远无匹配的表达式打转（`calendarspec.c:1328,1344`）。这个解析器有专属模糊测试目标 `src/fuzz/fuzz-calendarspec.c:8-31`（解析→转回字符串的往返一致性断言）。

---

## 4. path unit：inotify 上的三种判定

path unit 的监视矩阵浓缩在 `path_spec_watch()` 顶部的一张表里（`src/core/path.c:39-45`）：

```c
/* src/core/path.c:39-45 */
static const int flags_table[_PATH_TYPE_MAX] = {
        [PATH_EXISTS]              = IN_DELETE_SELF|IN_MOVE_SELF|IN_ATTRIB,
        [PATH_EXISTS_GLOB]         = IN_DELETE_SELF|IN_MOVE_SELF|IN_ATTRIB,
        [PATH_CHANGED]             = IN_DELETE_SELF|IN_MOVE_SELF|IN_ATTRIB
                                     |IN_CLOSE_WRITE|IN_CREATE|IN_DELETE
                                     |IN_MOVED_FROM|IN_MOVED_TO,
        [PATH_MODIFIED]            = ...,同上再加 IN_MODIFY,
        [PATH_DIRECTORY_NOT_EMPTY] = IN_DELETE_SELF|IN_MOVE_SELF|IN_ATTRIB
                                     |IN_CREATE|IN_MOVED_TO,
};
```

`PathModified=` 与 `PathChanged=` 的唯一差别就是多订阅 `IN_MODIFY`（写入中的每次 flush 都触发，`path.c:43` vs `path.c:42`）。监视安装是逐路径组件进行的：对路径上每一段都挂 `IN_MOVE_SELF|IN_DELETE_SELF|IN_CREATE|IN_MOVED_TO`，这样父目录被重建时也能重新跟上；且对符号链接同时 watch 链接本体与目标（`path.c:74-153,90-96`）。不存在的前缀允许"不完整监视"安静降级（`path.c:100-104`）。

事件到达后 `path_spec_fd_event()` 只读一次 inotify 缓冲，`PATH_CHANGED/PATH_MODIFIED` 命中主 watch 描述符即返回 1（`path.c:175-199`）；`PathExists=` 系则不走 inotify 语义，而是在状态检查时用 `access(F_OK)`、`glob_first()`、`dir_is_empty()` 直接验证（`path_spec_check_good()`，`path.c:201-231`）。`path_enter_waiting()` 里有个教科书级的竞态处理：先查条件再装 watch，装完**再查一遍**——"file might have appeared/been removed by now"（`path.c:593-614`）。另外两个贴心细节：`MakeDirectory=` 对应的 `path_spec_mkdir()` 会跳过 PATH_EXISTS 系（存在性检查不必造出被检查物，`path.c:249-260`）；命中触发时把匹配到的具体路径作为 `trigger_path` 传给 `path_enter_running()`（`path.c:237-244, 512`），供实例化与 ActivationDetails 使用。

---

## 5. mount 冷插与触发关系网络

mount unit 是被动激活器：内核侧的挂载变化经 libmount 的 `/proc/self/mountinfo` 监视进入 `mount_process_proc_self_mountinfo()`（`src/core/mount.c:2195-2205`），unit 由此被"冷插"识别——别人 mount 的文件系统会让对应 mount unit 自动进入 MOUNTED（`mount.c:2258-2269`），别人 umount 的则跟随死亡（`mount.c:2237-2243`）。automount 则是它的主动孪生：不监视 mountinfo，而是在挂点上架一套内核 autofs，靠 `AUTOFS_DEV_IOCTL_*` 与 `/dev/autofs` 通信、在首次访问时才真正挂载（`src/core/automount.c:46-76`）。一句话：mount/automount 把"文件系统出现"也纳入了统一的激活语义。

触发关系由依赖图承载，且大多是隐式生成的：socket unit 加载时若无配对 service，自动加载同名 `.service` 并加 `Before= + Triggers=` 双向依赖（`socket_add_extras()`，`socket.c:344-356`）；timer（`timer.c:115-129`）与 path（`src/core/path.c:354-368`）同构。unit 侧的 `Triggers=`/`TriggeredBy=` 遍历原语（如 `UNIT_FOREACH_DEPENDENCY(..., UNIT_ATOM_TRIGGERS)`，`socket.c:2474`）就是在这张网上行走。

---

## 6. 生成单元：generator 与 getty 实例

"generator" 是在启动早期把外部配置（内核 cmdline、fstab、设备树）翻译成临时 unit 文件的短命程序约定（规范文档 `man/systemd.generator.xml:1`）。本仓库没有单一的 `src/generator/` 目录，而是每个生成器一个子目录：`debug-generator`、`environment-d-generator`、`fstab-generator`、`getty-generator`、`gpt-auto-generator`、`run-generator`、`ssh-generator`、`system-update-generator`、`xdg-autostart-generator`（`src/` 目录清单），公共骨架在 `src/shared/generator.c`。

getty 生成器是理解"生成实例"的最佳标本：它把 tty 名转义成实例串，然后往 `getty.target.wants/` 里放一条指向模板的符号链接：

```c
/* src/getty-generator/getty-generator.c:49-56 */
r = unit_name_path_escape(tty, &instance);
...
return generator_add_symlink_full(arg_dest, "getty.target", "wants",
                                  unit_path, instance);
```

串口走 `serial-getty@.service`（`getty-generator.c:59-62`），容器 console 走 `container-getty@.service`（`:64-76`），来源包括 `getty.ttys.serial` 内核命令行/凭据等多种渠道（`:25-32,136`）。这与 socket→service 的模板实例化共享同一套 `unit_name_*` 机制。

生成器之外还有两个"不依赖 PID1 的激活演练工具"：`systemd-socket-activate` 自述 "Listen on sockets and launch child on connection."（`src/socket-activate/socket-activate.c:40`），让开发者能在普通用户会话里复现 fd=3 起步协议；`systemd-socket-proxyd` 则把激活与代理解耦——socket unit 常驻、真正的服务按需启动并转发流量（`src/socket-proxy/socket-proxyd.c:53-59`）。协议的通用性使激活器本身可以整体替换，这是"约定优于实现"的又一次落地。

---

## 7. 工程文化：构建、风格、模糊测试与"给 AI 的规则"

**构建组织**：根 `meson.build` 共 3207 行，`project()` 声明只有 13 行，版本号外置在单行文件 `meson.version`（当前 `262~rc2`，根目录清单；`meson.build:3-14` 读入），测试默认 setup 就排除了 clang-tidy/coccinelle 等静态分析套件（`meson.build:16-21`）——构建文件本身就是质量门禁的清单。子模块各有 meson.build，粒度到单个生成器目录（如 `src/getty-generator/meson.build`）。

**编码约定**：完整风格指南 `docs/CODING_STYLE.md` 在 sparse 检出之外，但根 `README.md:27-33` 明确把 ARCHITECTURE/HACKING/CONTRIBUTING/CODING_STYLE 四份文档列为入口（"please follow our Coding Style Guidelines" 在 `README.md:33`）；`AGENTS.md:23-26` 同样列出了这四份"必读"。

**模糊测试**：`src/fuzz/` 共 21 个文件，覆盖 bootspec、calendarspec、json、compress、env-file、varlink 等纯解析层（目录清单），每个目标几行 `LLVMFuzzerTestOneInput`，配 OSS-Fuzz/llvm-fuzz 双后端开关（`meson.build:65-76`）。选择被 fuzz 的面 = 选择"不可信输入到达的代码面"，这是一条清晰的工程判断。

**AGENTS.md / CLAUDE.md（亮点）**：根文件 `CLAUDE.md` 整个文件只有一行内容——`AGENTS.md`（`CLAUDE.md:1`），即用指针避免双份漂移。`AGENTS.md` 自述："Only add instructions to this file if you've seen an AI agent mess up that particular bit of logic in practice"（`AGENTS.md:7-8`）——规则全部来自真实事故。内容要点：一条硬性"金丝雀"规则——改任何源码都必须先在 README.md 顶部插入 `> [!IMPORTANT]` 提示行，且只有人类作者能手动移除，作为"人审过 PR"的物理凭据（`AGENTS.md:12`）；法律面规定 commit 只能署名人类、禁止 Co-Authored-By AI（`AGENTS.md:16-17`）；构建纪律要求用 `meson compile`/`meson test` 而非手工编译单文件、不截断构建输出（`AGENTS.md:35-42`）。这是观察"上游如何制度化人机协作"的一手材料。

**man 与代码同仓**：`man/` 下 528 个文件，`systemd.socket.xml:408`（Accept= 条目）、`systemd.timer.xml:190`（OnCalendar= 条目）与本文引用的 C 实现一一对应；man 页与实现同 commit 演进，行为变更若不同步文档即视为不完整提交。

**版本与发布**：根 `NEWS` 以 "CHANGES WITH 262 in spe:" 开头（`NEWS:3`），每个版本按 "Future Feature Removals / Incompatible Changes / ..." 分节详述行为差异（`NEWS:5-60`），兼容性破坏必须提前一个版本预告。仓库根还躺着几件"元工程"工具：`TODO.md` 是按 Bugfixes/External 分节的公开愿望清单（`TODO.md:1-7`，front matter 自注 category: Contributing）、`mypy.ini`/`ruff.toml` 管住仓库里的 Python（udev 规则生成、宏展开脚本等）、`CITATION.cff` 给学术引用提供机器可读元数据——一个 C 项目对自身"可维护性资产"的界定远超源码本身。

---

## 8. 阅读路线建议

若只读六个函数，建议按以下顺序（每个都能独立成课）：

1. `socket_open_fds()`（`src/core/socket.c:1664`）——五种端口如何统一开号。
2. `socket_enter_running()`（`src/core/socket.c:2437`）——一次 IO 事件如何变成一次 job 排队。
3. `pack_fds()`（`src/basic/fd-util.c:409`）——fd=3 约定的全部机械细节。
4. `timer_enter_waiting()`（`src/core/timer.c:372`）——双轨时间计算的完整推导。
5. `path_spec_watch()`（`src/core/path.c:38`）——逐组件 inotify 与降级策略。
6. `calendar_spec_next_usec()`（`src/shared/calendarspec.c:1495`）——日历表达式求值与 1000 次迭代上限。

四个 `UnitVTable`（`socket.c:3715`、`timer.c:1087`、`path.c:1010`、`mount.c` 尾部）是各 unit 的"目录页"，与报告引用的函数一一挂钩，可作为检索索引。

---

## 9. 设计动机（编者按）

1. **为什么 socket 激活**：把"端口已监听"与"服务已就绪"解耦。启动并行化不再受依赖顺序约束（所有 socket 可在最早时刻开齐），服务崩溃重启期间连接在内核队列排队不丢；manager 还能替服务 accept 并做每源限流（`socket.c:2507-2533`）。代价是 manager 必须持有 fd 并处理 exec 传递的全部边角——`pack_fds`、CLOEXEC、`LISTEN_FDNAMES` 都是为这个决定支付的利息。
2. **为什么 fd 从 3 开始**：0/1/2 是 stdio 的 POSIX 遗产，`SD_LISTEN_FDS_START=3`（`sd-daemon.h:54`）让"约定区间"与"保留区间"天然不重叠，`pack_fds()` 用 `F_DUPFD` 就能在 close-all 之后把任意散乱的 fd 无损压进 `[3, 3+n)`（`fd-util.c:422-451`）。协议因此只需要一个计数变量，无需传输 fd 编号本身。
3. **为什么 timer 双轨**：墙上时钟（OnCalendar）面向人的日程（每天 3 点），会被 NTP/管理员拨动；单调时钟（OnBootSec 等）面向"自某事件起多久"，天然免疫跳变。双轨并行 + 时钟跳变回调重算（`timer.c:863-901`）+ Persistent 戳文件（`timer.c:131-168,704-718`），让"错过就补跑"与"拨钟不重跑"同时成立——单一时钟源做不到这三件事。
4. **为什么 path 用 inotify**：轮询目录存在延迟与功耗成本，inotify 给出事件驱动的即时触发；但 inotify 只对"已存在的 inode"有效，所以 systemd 逐组件安装 watch 并在装好后二次检查条件（`path.c:593-614`）弥补 TOCTOU，对"文件出现"这类语义实际是 inotify + access 验证的混合体。
5. **为什么 man 与代码同仓**：激活语义（Accept= 的分派、OnCalendar 的 catch-up）遍布实现细节，文档滞后一版用户就会踩坑；同仓让 man 页变更进入与代码相同的 review/commit 粒度，`docs/CODING_STYLE.md` 与 `AGENTS.md`（含 AI 规则）进一步把"惯例"变成可执行的清单。
6. **为什么把 AI 纳入工程纪律**：`AGENTS.md:7-8` 的"只记录 AI 真实犯过的错"原则 + `AGENTS.md:12` 的人工确认金丝雀，等于给 AI 贡献设计了与 CI 平行的"人工验证层"——上游没有假装 AI 不存在，而是给它立了和人类贡献者同样明确的规矩。

---

## 10. 写作素材清单（文件:行号 均已核对）

1. `src/systemd/sd-daemon.h:53-70` — `SD_LISTEN_FDS_START=3` 与协议文字约定（附 `src/libsystemd/sd-daemon/sd-daemon.c:44-98` 接收侧实现）。
2. `src/basic/fd-util.c:409-453` — `pack_fds()` 把 fd 压到 [3,3+n)，断言 `fds[0]==3`。
3. `src/core/exec-invoke.c:2021-2045` 与 `:6307-6312` — LISTEN_* 环境变量拼装 + 子进程内 close/pack/flag 三连。
4. `src/core/socket.c:1664-1780` 与 `:1551-1573` — 五种端口统一开号；cgroup/netns 内建套接字。
5. `src/core/socket.c:3188-3227` 与 `:2437-2589` — accept 分叉点；Accept=yes/no 两种激活的完整实现。
6. `src/core/socket.c:3414-3448` 与 `src/core/service.c:1847-1949` — fd 反向收集的 socket 侧与 service 侧。
7. `src/core/socket.c:316-386` — 隐式 Before+Triggers 依赖与触发限流默认值（Accept=yes 200 / no 20）。
8. `src/core/socket.c:2671-2722` 与 `src/shared/fdset.c:23,125` — fd 经 FDSet 序列化跨 reexec 存活。
9. `src/core/socket.c:2367-2435` 与 `src/basic/unit-def.h:170-189` — DeferTrigger 机制与完整 SocketState 状态机。
10. `src/core/timer.c:372-641` — `timer_enter_waiting()`：日历/单调双轨求解与双事件源注册。
11. `src/core/timer.c:131-168, 704-718, 986-1004` — Persistent 戳文件、catch-up 读回与 `TRIGGER_TIMER_*` 环境传递。
12. `src/shared/calendarspec.c:870, 1328-1344, 1464-1511` — 手写解析器、find_next 的 1000 次迭代上限与时区感知求值。
13. `src/core/path.c:39-45, 175-199, 201-231, 577-617` — inotify 标志矩阵、事件分发、三型判定与二次检查竞态处理。
14. `src/core/mount.c:2195-2269` 与 `src/core/automount.c:46-76` — mountinfo 冷插跟随与 autofs 按需挂载。
15. `src/getty-generator/getty-generator.c:25-76, 136` 与 `src/core/manager.c:2243-2252`（`src/core/main.c:3224-3280`）— 生成实例符号链接；PID1 接收 LISTEN_FDS 按 unit 路由。
16. `AGENTS.md:7-17`、`CLAUDE.md:1`、`README.md:27-33`、`NEWS:3` — AI 协作纪律、文档入口与发布纪律；附 `src/socket-activate/socket-activate.c:40`、`src/socket-proxy/socket-proxyd.c:53-59`、`src/fuzz/fuzz-calendarspec.c:8-31`。

（报告完）
