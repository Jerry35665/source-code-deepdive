# A · 全景与架构：PID 1 的骨架

> 系列：《systemd 深读》卷 A ｜ 基线：commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`（2026-09-14 同步）
> 本卷只画"骨架"：PID 1 里有哪些对象、谁驱动谁、启动时序如何；依赖图/事务算法/exec 细节留给后续各卷。

## 一、定位：一句话与两种形态

README 第一行自我定位极简：`systemd System and Service Manager`（README:1）。它既是 Linux 内核拉起的第一个用户态进程（PID 1，挂 `/sbin/init`），也是每个用户会话里的 `systemd --user` 实例。两种形态在代码里由 `RuntimeScope` 枚举区分（src/basic/runtime-scope.h:7），判定规则写在 `run_systemd()` 里：**只要 `getpid() == 1` 就强制 system 形态**，否则走 user 形态（src/core/main.c:3583-3585、3698-3700）。容器里做 PID 1 也算 system 形态，只是日志与时间戳处理不同（src/core/main.c:3654-3663）。

另外 `systemd` 还是一个 multicall 二进制：以 `executor` 名字被调用时进入子进程执行器入口（src/core/main.c:4043-4047），这是近年重构中把 fork+exec 逻辑外移到独立 `executor` 程序的产物（src/core/executor.c）。

## 二、全景图：PID 1 内部对象层次

```
PID 1 (systemd, RUNTIME_SCOPE_SYSTEM)
│
├── Manager  (src/core/manager.h:183)  ← 全局单例
│     │  units:   Hashmap "名字 → Unit*"        manager.h:189
│     │  jobs:    Hashmap "id → Job*"           manager.h:191
│     │  run_queue: Prioq(按优先级)              manager.h:201
│     │  event:   sd_event * 事件循环            manager.h:244
│     │  load_queue / dbus_unit_queue / cleanup_queue / cgroup_realize_queue
│     │        / gc_unit_queue / target_deps_queue ...（十余条工作队列, manager.h:198-245）
│     │
│     ├── Unit[11 种类型]  (struct Unit, src/core/unit.h:228)
│     │     unit_vtable[_UNIT_TYPE_MAX] 虚表数组分派 (src/core/unit.c:83-95)
│     │     ├── .service  Service   src/core/service.c  (vtable @6679)
│     │     ├── .socket   Socket    src/core/socket.c   (vtable @3715)
│     │     ├── .target   Target    src/core/target.c   (vtable @174)
│     │     ├── .device   Device    src/core/device.c   (vtable @1292)
│     │     ├── .mount    Mount     src/core/mount.c    (vtable @2494)
│     │     ├── .automount Automount src/core/automount.c(vtable @1174)
│     │     ├── .swap     Swap      src/core/swap.c     (vtable @1632)
│     │     ├── .timer    Timer     src/core/timer.c    (vtable @1087)
│     │     ├── .path     Path      src/core/path.c     (vtable @1010)
│     │     ├── .slice    Slice     src/core/slice.c    (vtable @475)
│     │     └── .scope    Scope     src/core/scope.c    (vtable @730)
│     │
│     ├── Job   (struct Job, src/core/job.h:91)：Unit 上的待办动作
│     │     Unit.job 指针回指 (src/core/unit.h:281)
│     │
│     ├── Transaction (src/core/transaction.h:6)：一次依赖求解的暂存区
│     │     jobs: Hashmap "Unit → Job"; anchor_jobs: 用户点名的锚点作业
│     │     求解成功后整体"安装"进 Manager (transaction.c:800 transaction_activate)
│     │
│     └── sd_event 事件循环 (src/libsystemd/sd-event/sd-event.c, 5529 行)
│           信号/signalfd、SIGCHLD、notify fd、inotify(cgroup/时区)、
│           timer、PID 压力事件……全部注册为 event source
```

启动时序（自内核 `execve("/sbin/init")` 起）：

```
kernel → execve /sbin/init
  └─ main() = run_systemd()            main.c:4028→4047→3530
       ├─ PID1? 强制 system 形态/kmsg/挂载 API fs     main.c:3583-3696
       ├─ parse_configuration + parse_argv            main.c:3727-3733
       ├─ 动作分派: HELP/VERSION/TEST/... 或 ACTION_RUN main.c:3745-3770
       ├─ collect_fds(为反序列化收集 LISTEN_FDS)       main.c:3794
       ├─ initialize_runtime(机器 ID/主机名/凭据…)      main.c:3831 → 2647
       ├─ manager_new()                                main.c:3840 → manager.c:922
       │    └─ sd_event_default / run_queue / signals / cgroup / time_change
       │                                            manager.c:1018-1059
       ├─ manager_startup(serialization, fds)          main.c:3869 → manager.c:2168
       │    └─ generators → enumerate → deserialize → notify/bus/varlink
       │       → coldplug → vacuum → ready           manager.c:2179-2304
       ├─ do_queue_default_job(default.target)         main.c:3880 → 2817
       └─ invoke_main_loop → manager_loop(死循环)       main.c:3897 → manager.c:3621
            ├─ SIGTERM/reload/关机目标 → objective 跳出 manager.c:3333-3515
            ├─ REEXECUTE/SWITCH_ROOT → do_reexecute(execve 自己) main.c:3932→2163
            └─ 关机类 → become_shutdown(execve systemd-shutdown) main.c:3994→1743
```

## 三、源码目录分层：basic / libsystemd / shared / core

这是读码前必须建立的"海拔"概念（`docs/ARCHITECTURE.md` 有官方表述，AGENTS.md:23 也列为必读）：

- **src/basic/**（272 个文件）：不依赖 libsystemd 的最底层工具——log.c、hashmap、fileio、unit-def.h 等。注意 `UnitType` 枚举竟定义在这里（src/basic/unit-def.h:9-24），因为它被 shared 层的 unit-file 逻辑共用。
- **src/libsystemd/**：对外发布的 `libsystemd.so` 各 `sd-*` 库的**实现就在这里**——sd-event（sd-event/sd-event.c，5529 行）、sd-bus（sd-bus/ 下 40+ 文件）、sd-journal、sd-varlink 等（src/libsystemd/meson.build）。也就是说：**sd-event/sd-bus 属于 libsystemd，不属于 basic**；basic 是更低的纯工具层。
- **src/shared/**（584 个文件）：比 basic 高一级、被多个组件（core/udev/journal/nspawn…）共享、可依赖 libsystemd 的代码，如 bus-unit-util.c、unit-file.h。
- **src/core/**：PID 1 本体——manager.c（5677 行）、unit.c（7294 行）、main.c（4048 行）、job.c、transaction.c、cgroup.c、11 个 unit 类型实现，以及每个类型配套的 dbus-*.c（D-Bus API 绑定）。
- **src/udev/**：udevd 设备管理守护进程，入口 `run_udevd()`（src/udev/udevd.c:28）。
- **src/journal/**：journald 日志守护，`run()` 入口后由 `main-func.h` 宏包成 main（src/journal/journald.c:23）。二者细节留卷二。

## 四、启动链：从 main() 到 manager_startup

### 4.1 main() 与模式分派

`main()` 本体极薄：识别 multicall 名字后直接进入 `run_systemd()`（src/core/main.c:4028-4048）。真正的骨架在 `run_systemd()`（src/core/main.c:3530）：先 `early_skip_setup_check()` 判断是否为 reexec（可跳过系统初始化，src/core/main.c:3503、3561），随后按 PID 分形态初始化日志与 API 文件系统（src/core/main.c:3583-3715）。之后是**模式分派**：`--help`/`--version`/`--dump-configuration-items` 等动作各自提前返回，真正"当 init"的只有 `ACTION_RUN` 与 `ACTION_TEST`（src/core/main.c:3745-3770）。`ACTION_TEST` 会完整走 `manager_new`+`manager_startup` 但不进主循环，只打印事务摘要退出（src/core/main.c:3891-3895）——这正是 `systemd --test` 的实现。

### 4.2 manager_new：把骨架立起来

`manager_new()`（src/core/manager.c:922）用复合字面量一次性清零并填默认值（fd 全部置 `-EBADF`，src/core/manager.c:950-959），随后按依赖顺序搭骨架。关键五步：

```c
r = sd_event_default(&m->event);            /* 事件循环本体 */
...
r = manager_setup_run_queue(m);             /* 作业运行队列挂成 defer 源 */
...
r = manager_setup_signals(m);               /* 信号屏蔽 + signalfd */
...
r = manager_setup_cgroup(m);                /* 在 cgroup 层级中安家 */
...
r = manager_setup_time_change(m);           /* 时钟跳变监听 */
```
（src/core/manager.c:1018、1022、1031、1035、1039）

注意 `manager_setup_run_queue()` 的实现：run_queue 不是轮询出来的，而是注册为一个 `sd_event_add_defer` 事件源，平时 `SD_EVENT_OFF`，有作业入队时由 `manager_trigger_run_queue()` 打开（src/core/manager.c:761-779、2896-2906）。同段还注册了 SIGCHLD defer 源、时区 inotify 与 PSI 压力事件源（src/core/manager.c:1043-1059）。

### 4.3 manager_startup：九步点火

`manager_startup()`（src/core/manager.c:2168）是启动时序的核心，逐行读下来共九步：

1. **lookup paths**：确定 unit 文件搜索路径，测试模式用临时 generated 目录（src/core/manager.c:2179-2183）；
2. **generators**：跑环境生成器与 unit 生成器并打时间戳（src/core/manager.c:2185-2191）；
3. **enumerate**：`manager_enumerate_perpetual()` 建永恒 unit（如 .mount），再 `manager_enumerate()` 逐类型调 `unit_vtable[c]->enumerate` 从磁盘/内核枚举全部 unit（src/core/manager.c:2212-2213、1845、1863-1881）；
4. **deserialize**：若有序列化文件（reexec 场景），先进入 reloading 状态再 `manager_deserialize()`（src/core/manager.c:2207-2221；实现在 manager-serialize.c:563）；
5. **fd 分发**：把 `LISTEN_FDS` 传入的 fd 按标签/兜底分给 socket unit（src/core/manager.c:2246-2251）；
6. **IPC 通道**：notify fd、user-lookup fd、D-Bus（`manager_setup_bus`）、Varlink（src/core/manager.c:2254-2279）；
7. **coldplug**：对所有 unit 调 `unit_coldplug()`，把反序列化记录的"应有状态"真正生效（src/core/manager.c:2282、1883-1903；Unit 虚表 coldplug/catchup 回调见 src/core/unit.h:581-586）；
8. **vacuum + ready**：清理运行时对象，`manager_ready()` 对外宣告就绪（src/core/manager.c:2285、2304）；
9. 回到 main 后，`do_queue_default_job()` 加载 default.target（initrd 里是 initrd.target，找不到则层层回退到 rescue.target）并以 `JOB_ISOLATE` 入队（src/core/main.c:2829-2870）。

## 五、PID 1 的信号处理

systemd 不用传统 signal handler 做业务，而是"信号 → signalfd → 事件循环"。`manager_setup_signals()` 先把 SIGCHLD 以 `SIG_DFL` 挂回（src/core/manager.c:531），再把一整张信号表加入屏蔽字并创建 signalfd（src/core/manager.c:538-584）。表内注释本身就是文档：SIGTERM=重新执行、SIGHUP=重载、SIGUSR1=重连 D-Bus、SIGUSR2=dump 状态，SIGRTMIN+0..+29 映射 default/rescue/emergency/halt/poweroff/reboot/kexec/soft-reboot 等目标与日志开关（src/core/manager.c:539-580）。

```c
case SIGTERM:
        if (MANAGER_IS_SYSTEM(m)) {
                /* This is for compatibility with the original sysvinit */
                m->objective = MANAGER_REEXECUTE;
                break;
        }
        _fallthrough_;
case SIGINT:
        if (MANAGER_IS_SYSTEM(m))
                manager_handle_ctrl_alt_del(m);
```
（src/core/manager.c:3333-3341）

system 形态下 SIGTERM 竟然是 **daemon-reexec**（兼容 sysvinit 惯例），而 Ctrl-Alt-Del 走 SIGINT；SIGRTMIN 系列在 default 分支里查 `target_table` 变成一次 `manager_start_special` 作业提交（src/core/manager.c:3392-3407）。事件源优先级也有讲究：SIGCHLD 排最前（-4），信号其次（-3），run_queue 排最后（IDLE+1），保证先收尸再处理别的（src/core/manager.h:746-753、manager.c:594-600）。

## 六、reexecution：execve 自重启与序列化文件

systemd 升级、`daemon-reexec`、switch-root、soft-reboot 都不走 fork，而是**原地 execve 自己**。流程：

1. `invoke_main_loop` 返回 objective（src/core/main.c:2372-2417），main 在 finish 段识别 `MANAGER_REEXECUTE/SWITCH_ROOT/SOFT_REBOOT` 后调 `do_reexecute()`（src/core/main.c:3932-3941）；
2. exec 前 `prepare_reexecute()` 把全部状态写进一个序列化文件：`manager_serialize()` 输出 Manager/Unit/Job 状态，同时把"要带走的 fd"收进 FDSet（src/core/main.c:1334-1356；manager-serialize.c:119），并把序列化文件与 FDSet 的 CLOEXEC 关掉以便穿越 exec（src/core/main.c:1350-1356）；
3. `do_reexecute()` 收杀剩余进程、恢复 rlimit/能力集，拼出 `systemd --system --deserialize=<fd>` 参数后 `execv(SYSTEMD_BINARY_PATH, args)`（src/core/main.c:2233-2287）；失败时退 `/proc/self/exe`，再不行按 switch_root_init → `/sbin/init` → `/bin/sh` 逐级 fallback（src/core/main.c:2293-2367）；
4. 新实例启动时从 `--deserialize=` fd 读回状态：`manager_startup` 第 4 步的 `manager_deserialize()`（src/core/manager-serialize.c:563），再由 coldplug 恢复各 unit 状态（src/core/manager.c:2282）。

序列化文件是"每行一个 key=value"的纯文本，先写 Manager 级状态：

```c
(void) serialize_item_format(f, "last-transaction-id", "%" PRIu64, m->last_transaction_id);
(void) serialize_item_format(f, "current-job-id", "%" PRIu32, m->current_job_id);
...
(void) serialize_item(f, "previous-objective", manager_objective_to_string(m->objective));
(void) serialize_item_format(f, "soft-reboots-count", "%u", m->soft_reboots_count);
...
(void) serialize_dual_timestamp(f, joined, m->timestamps + q);
```
（src/core/manager-serialize.c:135-173，有删节）

随后逐 unit 调虚表的 `serialize_item` 回调、再逐 job 输出；fd 不进文本，而是编号成 `fd-store` 一类的引用写进文本、fd 本体塞进 FDSet 一起继承（src/core/main.c:1338-1356）。设计取舍：文本可读可 diff、坏行可跳过，配合"未知 key 忽略"的策略让新旧版本之间序列化格式可以平滑演化。

关机路径则相反：`become_shutdown()` execve 到独立的 `systemd-shutdown` 二进制（src/core/main.c:1743-1810），而它失败后还有 `fallback_shutdown()` 直接 sync+reboot 系统调用兜底（src/core/main.c:3994-4005）；再不行就 `freeze_or_exit_or_reboot()`（src/core/main.c:4016-4022）。"永不丢 PID 1" 是这条链的设计底线。

## 七、作业的一生：Transaction → Job → run_queue

一次 `systemctl start foo.target` 在 PID 1 内部走五站：

1. **入口**：`manager_add_jobs()` 为每个目标名新建 Transaction（src/core/manager.c:2311-2349）；
2. **展开**：`transaction_add_job_and_dependencies()` 把依赖图递归翻译成作业并记入 `tr->jobs`（src/core/manager.c:2379-2389；实现在 transaction.c）；
3. **求解**：`transaction_activate()` 做冲突合并、去环与顺序裁决，成功则把作业**安装**进 `m->jobs`，失败则整体 abort（src/core/manager.c:2406；src/core/transaction.c:800）；
4. **排队**：安装即入 `m->run_queue` 优先队列并触发 defer 事件源（src/core/manager.c:2896-2906）；
5. **执行**：`manager_dispatch_run_queue()` 弹出作业调 `job_run_and_invalidate()`——对 service 就是 fork/exec 子进程（src/core/manager.c:2880-2888；src/core/job.c:916）。子进程死后 SIGCHLD 经 defer 源回到 `manager_dispatch_sigchld()` 收尾（src/core/manager.c:3170）。

要注意第 3 站的"全有或全无"：Transaction 是图纸，Job 是施工，二者分离让依赖求解不会把 Manager 的正式作业表弄脏。

## 八、Manager 主循环：事件驱动 + 十余条工作队列

`manager_loop()`（src/core/manager.c:3621）每轮先顺序清空内部队列，任何一个非空就 `continue` 回到循环头优先消化，全部干净后 `sd_event_run()` 阻塞等待 IO/定时器（src/core/manager.c:3644-3678）：

```c
while (m->objective == MANAGER_OK) {
        if (!ratelimit_below(&m->event_loop_ratelimit)) {
                log_warning("Looping too fast. Throttling execution a little.");
                sleep(1);
        }
        (void) watchdog_ping();
        if (manager_dispatch_load_queue(m) > 0)  continue;
        if (manager_dispatch_gc_job_queue(m) > 0) continue;
        ...
        if (manager_dispatch_dbus_queue(m) > 0)  continue;
        r = sd_event_run(m->event, watchdog_runtime_wait(/* divisor= */ 2));
}
```
（src/core/manager.c:3634-3680，有删节）

作业执行在 `manager_dispatch_run_queue()`：从优先队列 `prioq_peek` 弹出已安装作业逐个 `job_run_and_invalidate()`（src/core/manager.c:2874-2894；job.c:916）。事件循环限速（每轮过快则睡 1 秒，src/core/manager.c:3636-3640）与看门狗心跳（src/core/manager.c:3642）是两个容易被忽略但关键的保命细节。

主循环外围挂着的一整圈 event source 值得点名：notify fd（服务经 `sd_notify` 发状态，src/core/manager.c:1143）、信号 fd（src/core/manager.c:588）、控制台 idle_pipe（判断"控制台上还有没有作业在跑"，src/core/manager.c:379）、cgroup inotify 与时区 inotify（src/core/manager.c:1035-1047）、PSI 压力事件（src/core/manager.c:816、1053-1056）。"所有外部事件皆 fd，皆 event source"是 Manager 保持单线程的完整答案。

## 九、Unit 类型体系：一张虚表统治 11 种类型

类型枚举 `UnitType` 定义在 src/basic/unit-def.h:9-24，共 **11 种**（service/mount/swap/socket/target/device/automount/timer/path/slice/scope；部分二手资料称"12 种"与当前源码不符）。核心泛型数据 `struct Unit`（src/core/unit.h:228）只放公共字段（id、dependencies、job 指针等），类型私有数据靠 `UnitVTable.object_size` 让 Manager 按各类型尺寸 `malloc0` 并用 `unit_vtable[u->type]` 回调分派（src/core/unit.h:529、790；src/core/unit.c:83-95、97-104）。虚表条目覆盖对象尺寸偏移、配置节名、init/done/load/coldplug/catchup/dump/start/stop/reload/clean/freezer_action 等约 30 个槽位（src/core/unit.h:529-788）。

```c
const UnitVTable * const unit_vtable[_UNIT_TYPE_MAX] = {
        [UNIT_SERVICE]   = &service_vtable,
        [UNIT_SOCKET]    = &socket_vtable,
        [UNIT_TARGET]    = &target_vtable,
        [UNIT_DEVICE]    = &device_vtable,
        [UNIT_MOUNT]     = &mount_vtable,
        [UNIT_AUTOMOUNT] = &automount_vtable,
        [UNIT_SWAP]      = &swap_vtable,
        [UNIT_TIMER]     = &timer_vtable,
        [UNIT_PATH]      = &path_vtable,
        [UNIT_SLICE]     = &slice_vtable,
        [UNIT_SCOPE]     = &scope_vtable,
};
```
（src/core/unit.c:83-95）

每种类型一个实现文件（service.c 6767 行最大，target.c 仅 208 行最小），并各配一个 dbus-<type>.c 暴露 D-Bus 属性方法；状态迁移的广播中心是 `unit_notify()`（src/core/unit.c:2738），它把 unit 状态变化扇出到依赖传播、job 完成、D-Bus 信号等队列——泛型代码与类型代码的接缝全在这条虚表 + notify 的组合上。

11 种类型的分工一句话版：

| 类型 | 职责 | 备注 |
|---|---|---|
| .service | 进程组生命周期 | 最复杂，exec/沙箱/cgroup 全在此 |
| .socket | socket 激活 | 持有监听 fd，服务按需拉起 |
| .target | 同步屏障 | 仅聚合依赖，几乎无逻辑（target.c 仅 174 行处即 vtable） |
| .device | 内核设备镜像 | 由 udev 事件合成，非用户编写 |
| .mount / .swap | 挂载/交换区 | 与 /etc/fstab、fstab generator 双向同步 |
| .automount | 按需挂载 | autofs 触发 mount |
| .timer | 时间触发 | 取代 cron，挂 timerfd 事件源 |
| .path | 路径触发 | inotify/pexist 监视文件变化 |
| .slice | cgroup 分层 | 纯资源切分，无进程 |
| .scope | 外部进程容器 | 接收已在跑的进程（如 session） |

其中 .device/.scope 是"被动容器"：它们描述的不是 systemd 要启动的东西，而是外部世界已经在跑的东西。

## 十、AGENTS.md / CLAUDE.md：根文件的工程文化信号

仓库根有 `AGENTS.md`（46 行，MIT-0 许可），自述"给 AI 编码代理的指引"，内容是硬性规则：改任何源文件必须先在 README.md 顶部加 `> [!IMPORTANT]` 人工复核标记（AGENTS.md:12）、"只有人类能出现在 commit 署名"（AGENTS.md:14-17）、以及构建/测试命令纪律（AGENTS.md:35-38）。`CLAUDE.md` 是 9 字节的转发文件，内容只有一行文本 `AGENTS.md`（CLAUDE.md:1）。上游把 AI 协作规范直接提交进仓库并要求"人工复核确认行"——这一工程文化现象留卷六展开。

## 十一、设计动机

1. **为什么单线程 event loop 而不是多线程？** PID 1 的全部状态（units/jobs/依赖图）共享在 Manager 里，`manager_loop` 用优先级排序的 event source（SIGCHLD -4、signals -3、run_queue IDLE+1，src/core/manager.h:746-753）把并发问题降维成"队列顺序"问题；连 run_queue 都做成 defer 事件源按需唤醒（manager.c:761-779）。单线程还让"信号即数据"（signalfd，manager.c:584）成为可能，避免 handler 重入。
2. **为什么 reexec 用 execve + 序列化文件，而不是热升级 IPC？** PID 1 无法重启：execve 保留 PID、cgroup、父进程与内核信任关系，`--deserialize=<fd>` 让新进程读回旧状态（main.c:2261-2287、manager-serialize.c:563）。状态走文件+继承 fd 而非 IPC，是因为 exec 后旧进程地址空间已不存在，"唯一可靠的遗产就是 fd"。关机同样 execve 到 systemd-shutdown（main.c:1765-1766），保证关机代码运行在无锁、无堆的新镜像里。
3. **为什么用 C 手工虚表而不是各自为政的类型代码？** Manager/transaction/依赖传播的算法只写一遍，面对 `Unit*` 泛型编程；11 种类型各自只填虚表槽位（unit.h:529 起、unit.c:83-95）。object_size/exec_context_offset 等条目甚至把"子类型结构体内嵌偏移"也元数据化，让 cgroup/kill 逻辑无需知道 Service 还是 Socket。
4. **为什么分层 basic / libsystemd / shared / core？** basic 不依赖 libsystemd，可被 udev 等最小二进制复用；libsystemd 是对外 ABI（sd-event/sd-bus 的家，src/libsystemd/meson.build），改动受符号版本约束；shared 服务于多守护进程内部复用；core 才是策略层。约束依赖方向后，"库稳定、策略自由"。
5. **为什么作业要经 Transaction 暂存而不是直接入队？** 一次 `start foo.service` 会牵出整张依赖图，可能出现作业冲突/环。先在 Transaction 里做 job 合并、去环与排序（manager.c:2379-2406 调 transaction_add_job_and_dependencies 与 transaction_activate），求解成功才原子安装进 Manager，失败则整体 abort——保证依赖图从不处于半更新状态。
6. **为什么 log 走 KMSG→Journal 降级链？** PID 1 启动早期 journald 还没起来，所以先 `log_set_prohibit_ipc(true)` 直写 kmsg，挂载完成后才切 `LOG_TARGET_JOURNAL_OR_KMSG`（main.c:3590-3652）——可用性优先于美观。

## 写作素材清单（文件：行号，均已核对）

1. src/core/main.c:3530 —— `run_systemd()`，PID 1 启动总控
2. src/core/main.c:3583-3700 —— PID 1 / --user 形态判定
3. src/core/main.c:3745-3770 —— HELP/VERSION/TEST 等模式分派
4. src/core/main.c:3840-3869 —— manager_new → manager_startup 调用点
5. src/core/manager.c:922-1059 —— manager_new 全过程（event/signals/cgroup/clock）
6. src/core/manager.c:2168-2308 —— manager_startup 九步点火
7. src/core/manager.c:3621-3684 —— manager_loop 主循环与十条队列
8. src/core/manager.c:2874-2906 —— run_queue 派发与按需触发
9. src/core/manager.c:521-605 —— 信号表/signalfd/优先级
10. src/core/manager.c:3333-3390 —— SIGTERM=reexecute 与 SIGRTMIN 目标表
11. src/core/main.c:2163-2370 —— do_reexecute：execve 自重启全链
12. src/core/main.c:1306-1362 + manager-serialize.c:119/563 —— 序列化/反序列化
13. src/core/unit.c:83-95 —— UnitVTable 数组；unit.h:529 虚表定义
14. src/basic/unit-def.h:9-24 —— UnitType 枚举（11 种）
15. src/core/main.c:2817-2870 —— default.target 入队与回退链
16. src/core/manager.h:183-201 —— Manager 结构体核心字段

（本报告所有行号基于基线 commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4` 实际读码核对。）
