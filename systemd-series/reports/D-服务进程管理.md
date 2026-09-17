# D · 服务进程管理：从 fork 到 cgroup 化的生命周期

> 基线：commit 1f66b52（nspawn: align config `PrivateUsersOwnership` default with CLI）。
> 所有 `文件:行号` 均已逐一 Read/Grep 核对；行号以仓库根相对路径给出。

service 单元是 systemd 中最复杂的状态机之一：`src/core/service.c`（6767 行）维护 30 个低层状态，向上层 `unit_notify()` 只暴露 `UNIT_ACTIVATING/ACTIVE/RELOADING/DEACTIVATING/...` 等高层状态（`src/core/service.c:75-106` 的 `state_translation_table`，其中 `SERVICE_RUNNING → UNIT_ACTIVE` 在 :81）。本文沿"启动→跟踪→通知→超时→停止→重启→善后"的生命周期逐段拆解。

## 0. 六种 Type：何时视为 started（ASCII 时序对比）

```text
Type=simple   PID1 fork ──execve(主进程)──┤→ 立即 START_POST → RUNNING
                                          （spawn 成功即视为 started，startup 超时=∞）
Type=idle     等待任务分发 ──fork ──execve ─┤→ 同 simple（但延迟到 job 队列空）
Type=exec     fork ──executor 初始化──execve┤→ exec_fd 收到 EOF（execve 成功）→ START_POST → RUNNING
Type=forking  fork(作为 control)──exit──────┤→ 读 PIDFile/猜主 PID → START_POST → RUNNING
Type=oneshot  fork(作为 main) ──进程退出───┤→ 退出码成功 → START_POST →（EXITED 或停止）
Type=dbus     fork ──主进程存活─────────────┤→ 总线出现 BusName= 属主 → START_POST → RUNNING
Type=notify   fork ──sd_notify(READY=1)────┤→ 收到 READY=1 → START_POST → RUNNING
              时间轴 ──────────────────────────────────────────►
              |<--------- TimeoutStartSec 生效区间（simple/idle 除外）--------->|
```

六种 Type 的枚举定义见 `src/core/service.h:35-46`；未写 `Type=` 时按 BusName/凭据/命令行自动推断（`src/core/service.c:1213-1223`）。判定点的统一入口是 `service_enter_start()` 末尾的 switch（`src/core/service.c:3005-3031`）与各自事件回调，见第 2 节。

图中"管理器视角"与"进程视角"的差异值得强调：simple/oneshot 等类型的业务进程本身就是 `systemd-executor` 经 `execve` 换身后得到的（第 1 节），因此"fork 时刻"对管理器而言实为"posix_spawn executor 时刻"；simple 在 executor 尚未 execve 时就已宣告 started，这正是 Type=exec 被引入的原因——把"started"推迟到 execve 真正成功，让管理器能捕获"可执行文件不存在/沙箱设置失败"这类错误并以启动失败呈现，而不是带着一个 RUNNING 状态下的空 cgroup。

## 1. service_spawn 链：不再是"双 fork"，而是"序列化 + executor 进程"

`service_spawn` 只是审计宏，实际是 `service_spawn_internal`（`src/core/service.c:69`、:2108）。它在管理器进程中完成：

1. `unit_prepare_exec()` 落实 cgroup（:2130）；
2. 控制进程若配 `PermissionsStartOnly=`/`RootDirectoryStartOnly=` 则屏蔽沙箱/chroot 标志（:2136-2141）；
3. 收集 socket 传递的 fd（:2144-2170）、为 `Type=exec` 分配 exec_fd 管道（:2172-2176）；
4. 挂启动超时定时器 `service_arm_timer()`（:2178-2180）;
5. 拼 `$NOTIFY_SOCKET`、`$MAINPID`、`$SERVICE_RESULT` 等环境变量（:2186-2301）；
6. 调 `exec_spawn()`（:2350-2356），随后 `unit_watch_pidref()` 挂 SIGCHLD 监视（:2363）。

关键事实：**当前版本已不再由 PID1 直接 fork 出业务进程**。`exec_spawn()`（`src/core/execute.c:465`）先把整个执行上下文序列化到临时文件（:532-546），再以 `posix_spawn_wrapper()` 拉起**钉死路径的 `systemd-executor` 二进制**（:579-588）：

```c
/* src/core/execute.c:525-530（摘录） */
/* In order to avoid copy-on-write traps and OOM-kills when pid1's memory.current is above the
 * child's memory.max, serialize all the state needed to start the unit, and pass it to the
 * systemd-executor binary. clone() with CLONE_VM + CLONE_VFORK will pause the parent until the exec
 * and ensure all memory is shared. ... If glibc 2.39 is available pidfd_spawn() is used in order to
 * get a race-free pid fd and to clone directly into the target cgroup (if we booted with cgroupv2). */
```

`posix_spawn_wrapper`（`src/basic/process-util.c:2080`）注释明确：fork 语义由 `CLONE_VM|CLONE_VFORK` 实现（:2092-2101），内核 5.7+ 时经 `posix_spawnattr_setcgroup_np`/`pidfd_spawn` 直接 clone 进目标 cgroup（:2116-2148）。控制进程会放进 `.control` 子 cgroup，以满足 cgroup v2 "无内层进程"规则（`src/core/execute.c:500-523`）；子侧与父侧各 attach 一次，双保险（:600-608）。

安全上下文的真正应用全部发生在 executor 进程内，即 `exec_invoke()`（`src/core/exec-invoke.c:5172`，函数级顺序）：

- 前置：CVE-2021-4034 式参数检查（:5227-5229）、`reset_signal_mask`/关多余 fd/`setsid()`、TTY 复位；
- 用户解析与 DynamicUser 落地、`setup_keyring()`（:5931）、PAM 会话 `setup_pam()`——内部再 fork 出 `(sd-pam)` 伴生进程（:5980，fork 点 :1380）；
- 判定三个开关：`needs_sandboxing`（:5496）、`needs_mount_namespace`（:5855）、`needs_setuid`（:5939）；
- 各类命名空间准备：`(sd-bpffs)`（:2332）、`(sd-userns)`（:2548）、mountns/PIDns 辅助子进程（:2607、:2676）；
- 收尾序列：`apply_root_directory()`（:6404）→ `enforce_user()`（setresuid/gid，:6410）→ `apply_working_directory()`（:6454）→ SELinux/SMACK 标签（`setup_smack()` :3306-3327，MLS 标签 :6285）→ seccomp 族 `apply_address_families`（:6532）、`apply_protect_kernel_modules`（:6568）、`apply_private_devices`（:6586）、`apply_lock_personality`（:6598）、`apply_restrict_filesystems`（:6612）、`apply_syscall_filter`（:6622）→ 能力集收尾；
- 最后 `exec_fd_mark_hot()` 声明即将 exec（:6738）、发送 handoff 时间戳（:6743），`fexecve_or_execve()`（:6754）。

传统意义的"双 fork 安全化"仅残留在辅助路径：`safe_fork()` 在 `FORK_DETACH` 且自身非 reaper 时先 fork 中间子进程再由其 fork 真正子进程（`src/basic/process-util.c:1485-1490`）。

### 1.1 装载期约束（service_verify）

状态机能保持简单，部分归功于装载期就掐掉非法组合（`service_verify()`，`src/core/service.c:1039-1083`）：非 oneshot 必须有 ExecStart（:1050）；oneshot 禁止 `Restart=always/on-success`（:1059）与 `ExitType=cgroup`（:1062）；`Type=dbus` 必须配 `BusName=`（:1065）；`Type=forking` 禁止 `PrivatePIDs=yes`（:1068-1070，错误信息直言 "Service of Type=forking does not support PrivatePIDs=yes"）；`RuntimeMaxSec=` 禁配 oneshot（:1077）；而 `Type=simple` + ExecStartPost= + 凭据的组合只给警告不拒绝（:1083-1084，"This could lead to race conditions. Continuing."）。

## 2. 六种 Type 的 started 判定点与状态机

`service_enter_start()` 按类型把新 PID 记到不同角色（`src/core/service.c:2955-2965`）：forking 把 ExecStart 记为 control 命令，其余类型记为 main 命令。启动超时对 simple/idle 关闭（`timeout = USEC_INFINITY`，:2986-2991）；oneshot 干脆默认无启动超时（:1226-1227）。随后的 switch：

```c
/* src/core/service.c:3005-3027（摘录） */
switch (s->type) {
case SERVICE_SIMPLE:
case SERVICE_IDLE:
        /* For simple services we immediately start the START_POST binaries. */
        (void) service_set_main_pidref(s, TAKE_PIDREF(pidref), &c->exec_status.start_timestamp);
        return service_enter_start_post(s);
case SERVICE_FORKING:
        /* For forking services we wait until the start process exited. */
        s->control_pid = TAKE_PIDREF(pidref);
        return service_set_state(s, SERVICE_START);
case SERVICE_ONESHOT: /* ... we wait until the start process exited, too, but it is our main process. */
case SERVICE_EXEC:
case SERVICE_DBUS:
case SERVICE_NOTIFY:
case SERVICE_NOTIFY_RELOAD:
        (void) service_set_main_pidref(s, TAKE_PIDREF(pidref), &c->exec_status.start_timestamp);
        return service_set_state(s, SERVICE_START);
}
```

各自的"started"事件源：

- **simple/idle**：spawn 即成功，直接 `service_enter_start_post()`（:3010-3011）。oneshot 若没有 ExecStart，仅伪造 `SERVICE_START` 状态迁移以保证 SuccessAction 等仍触发（:2976-2983）；
- **exec**：exec_fd 管道。子进程在 execve 前写一个非 0 字节" arm"，execve 成功时 O_CLOEXEC 关闭管道产生 EOF，父进程 `service_dispatch_exec_io()` 收到 EOF 且 `exec_fd_hot` 才判定成功（`src/core/service.c:4581-4612`）；
- **notify/notify-reload**：收到 `READY=1` 且处于 `SERVICE_START` 时 `service_enter_start_post()`（:5569-5571）；若 notify 类型的主进程未通知就退出，按协议错误处理（:4882-4891）；
- **dbus**：总线属主变化回调 `service_bus_name_owner_change()`，`START` 状态下出现属主即 `service_enter_start_post()`（`src/core/service.c:5965-5986`）；运行期属主消失还有 2 秒宽限重验态 `SERVICE_RUNNING_REVALIDATING`（:2838-2861，宽限常量 `SERVICE_BUS_NAME_GRACE_USEC` :73）；
- **forking**：ExecStart 进程（control）退出后读 `PIDFile=` 或启发式猜主 PID：`service_load_pid_file()`（:1543-1621，可疑 PID 仅当 PID 文件属 root 才接受，:1595-1601）、`service_search_main_pid()`（:1623-1640），然后才 `service_enter_start_post()`（:5023-5041）。

主进程退出后是否进入 `SERVICE_EXITED` 由 `ExitType=` 决定：main（默认）只看主 PID，cgroup 等待整个 cgroup 清空（`src/core/service.h:48-53`；判定 `src/core/service.c:4849`）。oneshot 多条 ExecStart 逐条串行执行（`service_run_next_main`，:4834-4842）。

## 3. 副进程跟踪：main_pid 猜测 + notify 修正，cgroup 双 PID 组

`main_pid_good()` 返回三态：死亡 0、存活 >0、未知 <0（`src/core/service.c:2371-2389`）；`cgroup_good()` 用 `cg_is_empty()` 判断（:2402-2418）。`service_set_main_pidref()` 负责登记并检测"非我子进程"（alien，无法收 SIGCHLD，:249-314）。

**notify 修正主 PID**：服务可通过 `MAINPID=`/`MAINPIDFD=`/`MAINPIDFDID=` 让管理器改主进程。解析在 `service_notify_message_parse_new_pid()`（:5436-5500）：`MAINPIDFD=1` 携带 pidfd 优先（:5450-5460），`MAINPIDFDID=` 用于校验 PID 未被复用（:5473-5495）；新 PID 须经 `service_is_suitable_main_pid()` 检查（:1511-1541：不得是管理器/control 进程/僵尸，且最好属于本服务 cgroup），特权发送方可豁免（:5639-5650）。

cgroup 视角下单元内有两类受管进程组：主进程与控制进程分别被 `unit_watch_pidref()` 监视（spawn 处 :2363，notify 换主 PID 处 :5652），而控制命令（ExecStartPre/Post/Reload/Stop*）在合适阶段放入 `.control` 子 cgroup（`service_exec_flags()` 的 `EXEC_CONTROL_CGROUP`，`src/core/service.c:2092-2094`；子 cgroup 创建 `src/core/execute.c:508-519`）。cgroup 空事件兜底：连 PID 都不知道时，`service_notify_cgroup_empty_event()` 依据空 cgroup 推进状态（`src/core/service.c:4626-4640`）。

## 4. sd_notify 处理：标签解析与状态推进

入口 `service_notify_message()`（:5604），先鉴权 `service_notify_message_authorized()`（:5390-5434）：`NotifyAccess=none/main/exec/all` 四级，main 只认主 PID（:5404-5413），exec 认主+控制 PID（:5415-5429）。随后依序处理：

- `MAINPID*`（见上节，:5631-5658）；
- `STOPPING=1`/`READY=1`/`RELOADING=1`（优先级 STOPPING > READY > RELOADING，:5515-5600）；`RELOADING=1` 必须携带不早于发送 SIGHUP 时刻的 `MONOTONIC_USEC=` 才被认可（:5586-5595）；
- `STATUS=`（限长 16 KiB，`STATUS_TEXT_MAX` :67，处理 :5663-5684）、`NOTIFYACCESS=`（:5688）、`ERRNO=`（:5707）、`BUSERROR=`/`VARLINKERROR=`（:5721-5743）；
- `EXTEND_TIMEOUT_USEC=` 延长当前定时器（:5746-5753 → `service_extend_timeout()` :447-459）；
- `WATCHDOG=1` 喂狗、`WATCHDOG=trigger` 主动触发看门狗（:5757-5764 → `service_force_watchdog()` :5378-5388）、`WATCHDOG_USEC=` 运行期改阈值（:5767-5773）。

`READY=1` 的三个去向：启动期 → `service_enter_start_post()`；重载期 `SERVICE_RELOAD_NOTIFY` → `service_enter_reload_post()`；排队中的 STOPPING/RELOADING 意图会在 `service_enter_running()` 里重放（:2812-2816）。

```c
/* src/core/service.c:5568-5575（摘录） */
/* Type=notify(-reload) services inform us about completed initialization with READY=1 */
if (IN_SET(s->type, SERVICE_NOTIFY, SERVICE_NOTIFY_RELOAD) &&
    s->state == SERVICE_START)
        service_enter_start_post(s);

/* Sending READY=1 while we are reloading informs us that the reloading is complete. */
if (s->state == SERVICE_RELOAD_NOTIFY)
        service_enter_reload_post(s);
```

## 5. 超时体系：一个定时器，多种语义

服务只有一个 `timer_event_source`，`service_arm_timer()`（:1033-1037）按状态重新解释。进入终态以外的状态时定时器保持，`service_set_state()` 离开"有定时器状态表"时统一撤下（:1666-1676）。

- **TimeoutStartSec**：覆盖 CONDITION/START_PRE/START/START_POST（spawn 时挂载 :2178；冷Plug重建 :1750）；超时后按 `TimeoutStartFailureMode=`（terminate/abort/kill，`src/core/service.h:95-101`）三分支（:5162-5186）；oneshot 默认 ∞（:1226-1227）。
- **RuntimeMaxSec**：进入 RUNNING 时挂 `service_running_timeout()`（= active_enter + runtime_max + 随机抖动，:1018-1031；挂载 :2827-2830）；到点**不 kill 而是发起正常停止**并记 `SERVICE_FAILURE_TIMEOUT`（:5189-5192）。
- **TimeoutStopSec**：覆盖 STOP/STOP_SIGTERM/STOP_SIGKILL/STOP_POST/FINAL_*（冷Plug :1761）；`TimeoutAbortSec` 用于 watchdog 态（`service_timeout_abort_usec()`，`src/core/service.h:284-287`；挂载 :2688-2689）。
- **RestartSec**：AUTO_RESTART 态同一枚定时器倒数（触发 `service_enter_restart`，:5330-5340）。
- **WatchdogSec**：独立 `watchdog_event_source`（`service_start_watchdog()` :333-373），喂狗即 `service_reset_watchdog()` 刷新 `watchdog_timestamp`（:461-472，冻结中的服务跳过）；只有 `SERVICE_STATE_WITH_WATCHDOG` 命中的状态才持有看门狗，离开即撤（`service_set_state()` 内 ：1701-1702）；超时受管理器 `service_watchdogs` 开关门控，未开启仅告警（:5366-5373）。看门狗定时器被刻意放在 sd-event 的 IDLE 优先级（`EVENT_PRIORITY_SERVICE_WATCHDOG = SD_EVENT_PRIORITY_IDLE`，`src/core/manager.h:752`），让喂狗消息等其他事件先行处理，避免"活着的进程被误判死亡"（`service.c:367-369` 的注释与 set_priority 调用）。

定时器触发集中分发于 `service_dispatch_timer()`（:5151-5350），逐状态给出 SIGTERM→SIGKILL→终态的完整升级链。管理器重启（daemon-reload）期间，序列化的状态经 `service_coldplug_timeout()` 按状态反推绝对截止时刻并重建定时器（:1734-1777），START 期用 `state_change_timestamp + timeout_start_usec`（:1750），AUTO_RESTART 用 `inactive_enter_timestamp + jittered 退避`（:1768-1769）——保证"死等半程的服务"重载后不会重置整个超时。

### 5.1 service_set_state 的统一善后

`service_set_state()`（:1651-1732）是所有状态迁移的咽喉：撤定时器（:1676）、撤总线名宽限定时器（:1678-1679）、离开"带主进程/控制进程的状态"时解除对应 PID 监视并清空命令指针（:1681-1690）、终态解除全部 PID 监视（:1692-1696）、离开 START 撤 exec_fd 源（:1698-1699）、离开看门狗状态停狗（:1701-1702），最终把两个高层状态交给 `unit_notify()`（:1731）触发依赖管理。一个状态 = 一组资源约定，这是理解 service.c 的钥匙。

## 6. 停止路径：KillMode 三级实现与 SIGTERM→SIGKILL 升级

停止链条：`service_enter_stop()`（ExecStop，:2730-2758）→ `service_enter_signal(STOP_SIGTERM)`（:2672）→ 超时则 `STOP_SIGKILL` → `service_enter_stop_post()`（:2619-2646）→ `FINAL_SIGTERM` → `FINAL_SIGKILL` → `service_enter_dead()`。重启用 Job 会把第一段信号换成 `RestartKillSignal`（`state_to_kill_operation()` 的 `KILL_RESTART`，:2648-2670）。

`service_enter_signal()` 有一处常被忽略的短路逻辑：`unit_kill_context()` 返回 0（没打到任何该等的进程）时，不必按部就班等 SIGCHLD，直接沿链条快进（:2696-2703）：

```c
/* src/core/service.c:2696-2703（摘录） */
} else if (IN_SET(state, SERVICE_STOP_WATCHDOG, SERVICE_STOP_SIGTERM) && s->kill_context.send_sigkill)
        service_enter_signal(s, SERVICE_STOP_SIGKILL, SERVICE_SUCCESS);
else if (IN_SET(state, SERVICE_STOP_WATCHDOG, SERVICE_STOP_SIGTERM, SERVICE_STOP_SIGKILL))
        service_enter_stop_post(s, SERVICE_SUCCESS);
else if (IN_SET(state, SERVICE_FINAL_WATCHDOG, SERVICE_FINAL_SIGTERM) && s->kill_context.send_sigkill)
        service_enter_signal(s, SERVICE_FINAL_SIGKILL, SERVICE_SUCCESS);
else
        service_enter_dead(s, SERVICE_SUCCESS, /* allow_restart= */ true);
```

发信号本体在 `unit_kill_context()`（`src/core/unit.c:5081`）：

```c
/* src/core/unit.c:5106-5116 与 5148-5153（拼接摘录） */
PidRef *main_pid = unit_main_pid_full(u, &is_alien);
r = unit_kill_context_one(u, main_pid, "main", is_alien, sig, send_sighup, log_func);
...
r = unit_kill_context_one(u, unit_control_pid(u), "control", false, sig, send_sighup, log_func);
...
if (crt && crt->cgroup_path &&
    (c->kill_mode == KILL_CONTROL_GROUP || (c->kill_mode == KILL_MIXED && k == KILL_KILL))) {
        ...
        r = cg_kill_recursive(crt->cgroup_path, sig,
                              CGROUP_SIGCONT|CGROUP_IGNORE_SELF, pid_set, log_func, u);
```

三种 KillMode 的实现差异正在这一条 if（KillMode 枚举含 `none` 共 4 种，`src/core/kill.c:41-46`）：

- **control-group**：主 PID、控制 PID 先各发一次（:5107-5112），再**遍历整个 cgroup 树** `cg_kill_recursive()`（读 `cgroup.procs` 并递归子组，`src/basic/cgroup-util.c:353-407`），排除已在 PID 集里的 main/control 防重复（:5143-5146）；
- **mixed**：SIGTERM 阶段只打 main+control；只有升级到 `KILL_KILL`（SIGKILL）阶段才 cgroup 级扫射；
- **process**：永不走 cgroup 分支，只有 main+control 两个 PID；
- SIGKILL 阶段还会先把 `pids.max` 写 0 阻止垂死进程 fork，返回前恢复（:5124-5141）。内核 5.14+ 的原子杀另有 `cgroup.kill` 写 1 的 `cg_kill_kernel_sigkill()`（`src/basic/cgroup-util.c:409-443`，注释强调"完全原子" :414-415）。

单进程发送封装在 `unit_kill_context_one()`（`src/core/unit.c:5014-5050`）：`pidref_kill_and_sigcont()` 发信号并伴随 SIGCONT（唤醒被冻结的进程让其处理 SIGTERM，:5036）；对已消失的进程返回 `-ESRCH`，此时只有非 alien 子进程才算"值得等待 SIGCHLD"（:5037-5038）；`SendSIGHUP=yes` 时补发 SIGHUP（:5046-5047）。函数返回值即"是否需要等 SIGCHLD"，`service_enter_signal()` 据此决定进入信号等待态还是直接跳下一阶段（:2687-2703）。

`SendSIGKILL=no` 的服务（典型是数据库）在启动前若 cgroup 有残留进程且 KillMode 是 mixed/control-group，直接拒绝启动（`service_adverse_to_leftover_processes()`，`src/core/service.c:2914-2934`）。

### 6.1 通知驱动的优雅停止

服务主动发 `STOPPING=1` 时走 `service_enter_stop_by_notify()`（:2714-2728）：不再发 SIGTERM，仅挂 TimeoutStopSec 定时器并把状态置为 `STOP_SIGTERM`——注释直言"服务告知我们在停，视同我们已发过 SIGTERM"。此后 ExecStop= 仍会执行，退出路径与普通停止完全合流。主进程退出后的收尾由 `service_enter_exited_or_stop()` 决定：`RemainAfterExit=` → `SERVICE_EXITED`，否则进入正常停止链（:2787-2796）。

## 7. 重启语义与 crash 处理

`Restart=` 七种取值（`src/core/service.h:23-33`）。`service_enter_dead()` 是判定枢纽（:2495-2617）：先按 result 分流终态（成功→DEAD*，跳过→不重启，失败→FAILED，:2509-2521），随后 `service_shall_restart()`（:2420-2476）——`RestartPreventExitStatus=`/`RestartForceExitStatus=` 优先于策略表（:2431-2447），再查策略（:2450-2475）。重启采用两段状态（`DEAD_BEFORE_AUTO_RESTART`→`AUTO_RESTART`）让外部观察者能看到"短暂 inactive"（:2540-2548）；退避延迟按指数曲线 `service_restart_usec_next()`（:375-407）加随机抖动（:409-414、:2550-2556）。手动 stop 置 `forbid_restart` 压制自动重启（:2424-2428）。

crash 路径有三条汇入 `service_enter_signal(STOP_WATCHDOG, SERVICE_FAILURE_WATCHDOG)`：真看门狗超时（:5358-5376）、`WATCHDOG=trigger`（:5761-5762）；此外 main PID 消失本身走 SIGCHLD 事件（第 9 节），按其退出码/信号归类 result 后再由 Restart= 决定是否拉起；OOM 被杀经 `unit_check_oom` 补记 `SERVICE_FAILURE_OOM_KILL`（`src/core/manager.c:3220`；service 侧 :4747）。

## 8. exit 码与信号 → result 映射

SIGCHLD 到达后，`service_sigchld_event()` 第一件事就是把 `(code,status)` 归一为 `ServiceResult`（`src/core/service.c:4777-4786`）：

```c
/* src/core/service.c:4777-4786（摘录） */
if (is_clean_exit(code, status, clean_mode, ...))
        f = SERVICE_SUCCESS;
else if (code == CLD_EXITED)
        f = SERVICE_FAILURE_EXIT_CODE;
else if (code == CLD_KILLED)
        f = SERVICE_FAILURE_SIGNAL;
else if (code == CLD_DUMPED)
        f = SERVICE_FAILURE_CORE_DUMP;
```

"干净退出"的定义在 `is_clean_exit()`：退出码 0 或命中 `SuccessExitStatus=`；被信号杀死时，daemon 类进程的 SIGHUP/SIGINT/SIGTERM/SIGPIPE 也算干净（`src/shared/exit-status.c:140-154`）。控制命令与主进程分别适用 `EXIT_CLEAN_COMMAND`/`EXIT_CLEAN_DAEMON`（:4769-4774）。result 全集 11 项：success/resources/protocol/timeout/exit-code/signal/core-dump/watchdog/start-limit-hit/oom-kill/exec-condition（`src/core/service.c:6588-6600`，枚举 `src/core/service.h:79-93`）。result 随后被 `$SERVICE_RESULT`/`$EXIT_CODE`/`$EXIT_STATUS` 环境变量传给 ExecStopPost= 等后续命令（spawn 处 ：2268-2301）。`exit_status_set_test()` 同时接受退出码位图与信号位图，供 RestartPrevent/Force 用（`src/shared/exit-status.c:168-176`）。`ExecCondition=` 特殊：退出码 (0,254] 视为"跳过"而非失败（`SERVICE_SKIP_CONDITION`，:4951-4961）。

## 9. 进程退出收割：SIGCHLD → waitid → sigchld_event

管理器把 SIGCHLD 做成 sd-event 源，优先级高于普通 IO（`EVENT_PRIORITY_SIGCHLD = SD_EVENT_PRIORITY_NORMAL-4`，`src/core/manager.h:746`；挂接点 `src/core/manager.c:794`）。回调 `manager_dispatch_sigchld()` 用两段式 waitid：先 `WNOWAIT` 偷看但不收尸（保留读 /proc 的能力，:3177-3186），反查所属单元后逐个调 `service_sigchld_event()`（:3212-3229），最后才真正 `waitid(P_PID)` 收尸（:3234-3237），无子进程时关事件源（:3241-3246）。通知消息的处理被刻意排在 SIGCHLD 之前（`src/core/manager.c:1147` 注释），否则主进程"READY=1 后立刻退出"的场景里，管理器会先看到死亡而丢掉最后一条状态通知。

`service_sigchld_event()`（`src/core/service.c:4760-5100+`）按死亡者身份分派：主分支先撤 exec_fd 源（:4792），**forking 服务主 PID 变更**时尝试读新 PIDFile，读到就当无事发生（:4794-4798）；`ExitType=cgroup` 且 cgroup 未空时忽略主进程退出（:4849）；再按当前状态 switch 决定下一步（:4851-4927，如 START+oneshot → `service_enter_start_post()`，:4875-4881）。控制分支处理 ExecCondition 跳过语义（:4952-4961）与命令串推进，最终在 `SERVICE_START` 态为 forking 服务读 PIDFile/猜 PID 后进入 START_POST（:5013-5042）。

值得注意的两个细节：其一，`IGNORE_FAILURE=` 只对"该条命令自身"豁免 result，主/控制两分支各查一次（:4812-4821、:4947-4948）；其二，`ExecStartPost=` 等控制命令失败时 result 记入后走 `service_enter_signal(STOP_SIGTERM)` 而非直接 dead——已经跑起来的主进程仍要被体面地停掉（:5045-5047）。

## 10. 设计动机

1. **为什么 Type=notify 优于 forking**：forking 依赖守护进程自觉写 PIDFile，管理器只能"猜"主 PID（:1623-1640）并容忍 PID 复用风险；notify 让主进程显式举手，`READY=1` 直接消除 guess，`MAINPIDFD=` 更用 pidfd 从根上封死 PID 复用竞态（:5450-5495）。就绪语义也从"父进程退出"（仅是约定）变为"服务自证初始化完成"。
2. **为什么 cgroup 是真相之源而非 PID 表**：PID 表（main/control）只覆盖"我们知道的角色"，守护进程派生的所有子孙只有 cgroup 能兜住——`KillMode=control-group` 的全树遍历（`unit.c:5148`）、`cgroup_good()` 的存活判断（`service.c:2402-2418`）、`ExitType=cgroup`（:4849）、cgroup 空事件兜底（:4626-4640）都以 cgroup 为准；`exec_spawn` 甚至保证"任何用户代码绝不在 cgroup 外执行"（`execute.c:600-602` 注释）。
3. **为什么把 fork 安全化移进独立 executor 进程**：PID1 与业务进程共享 libc 状态，长期以来靠双 fork/精心清理规避锁与副作用；序列化 + `CLONE_VM|CLONE_VFORK` + 独立 `systemd-executor` 二进制（`execute.c:525-530`）一并解决了 COW 内存翻倍（pid1 memory.current 超 memory.max 时的 OOM 陷阱）、安全上下文代码膨胀拖累 PID1、升级期行为漂移（executor 二进制被钉死，`execute.c:579` 注释）三个问题，且 `CLONE_INTO_CGROUP` 让进程出生即入 cgroup。
4. **为什么 KillMode 要分级**： control-group 是唯一能杀死"孤儿孙进程"的完备选项；process/mixed 照顾"不想让管理器误杀协作者/希望 SIGTERM 只给主进程"的遗留守护进程，mixed 把 cgroup 扫射推迟到 SIGKILL 阶段作为最后手段（`unit.c:5116`）；`SendSIGKILL=no` 服务干脆拒绝在脏 cgroup 上启动（`service.c:2927-2931`），把"可能杀不干净"提前变成显式错误。
5. **为什么 result 码要细分到 11 种**：粗粒度"failed"无法支撑 `Restart=on-watchdog/on-abnormal`（`service.c:2464-2471`）、`RestartForce/PreventExitStatus=`（:2431-2443）、`$SERVICE_RESULT` 驱动的 ExecStopPost 清理（:2277-2290）以及 oom-kill 的专门告警——每一项细分都对应一个可编程决策点。
6. **为什么超时是一个定时器多种语义**：服务任一时刻只处一个状态，状态本身已蕴含"在等什么"，单定时器 + 按状态解释（`service.c:5151-5350`）避免多个定时器互相竞争，也让 `EXTEND_TIMEOUT_USEC=`（:447-459）和 daemon-reload 后的 coldplug 重建（:1734-1777）只需对准一个事件源。
7. **为什么 dead 之前要插入 `*_BEFORE_AUTO_RESTART` 过渡态**：自动重启若一步从 RUNNING 跳回 ACTIVATING，外部监控将永远看不到 inactive 瞬间，"服务其实死过"这一事实对依赖其故障通知的软件不可见（`service.c:2540-2546` 注释给出正面论证）；过渡态让 `systemctl`/总线观察者能区分"永久 inactive"与"重启途中"，又不必为此新增高层状态。

## 10.1 阅读路线图

建议按数据流读：先 `service_spawn_internal`（:2108）看"管理器给了孩子什么"，再进 `exec_spawn`（`execute.c:465`）与 `exec_invoke`（`exec-invoke.c:5172`）看"孩子如何自我改造"；随后回到 `service_enter_start`（:2936）对照第 0 节时序图理解六种 Type 分岔；事件侧按 `manager_dispatch_sigchld`（`manager.c:3170`）→ `service_sigchld_event`（:4760）与 `service_notify_message`（:5604）两条主线阅读；最后以 `service_dispatch_timer`（:5151）+ `unit_kill_context`（`unit.c:5081`）+ `service_enter_dead`（:2495）收束停止/重启闭环。整个过程中始终对照 `service_set_state`（:1651）检查"当前状态约定了哪些资源"。

## 11. 写作素材清单

| # | 文件:行号 | 内容 |
|---|---|---|
| 1 | src/core/service.h:35-46 | 八种 ServiceType 枚举（含 notify-reload/exec/idle 注释） |
| 2 | src/core/service.c:3005-3031 | service_enter_start 末尾按 Type 分派（started 判定总入口） |
| 3 | src/core/execute.c:525-530 | CLONE_VM+CLONE_VFORK / pidfd_spawn / CLONE_INTO_CGROUP 动机注释 |
| 4 | src/basic/process-util.c:2080-2148 | posix_spawn_wrapper：clone3 进 cgroup、pidfd 竞态消除 |
| 5 | src/core/exec-invoke.c:5172-5232 | exec_invoke 签名与 CVE-2021-4034 检查 |
| 6 | src/core/exec-invoke.c:6404-6454 | apply_root_directory → enforce_user → apply_working_directory 顺序 |
| 7 | src/core/exec-invoke.c:6738-6754 | mark_hot → handoff 时间戳 → fexecve_or_execve |
| 8 | src/core/service.c:4576-4624 | Type=exec 的 exec_fd EOF 协议 |
| 9 | src/core/service.c:5568-5575 | READY=1 推进 START→START_POST 与 reload 收尾 |
| 10 | src/core/service.c:5390-5434 | NotifyAccess 四级鉴权 |
| 11 | src/core/service.c:5436-5500 | MAINPIDFD=1 / MAINPID= / MAINPIDFDID= 解析与 PID 复用校验 |
| 12 | src/core/service.c:5151-5192 | 启动超时三分支（terminate/abort/kill）与 RuntimeMaxSec 到点即停 |
| 13 | src/core/unit.c:5081-5178 | unit_kill_context：main/control 先行 + KillMode 条件 + pids.max=0 |
| 14 | src/basic/cgroup-util.c:353-407 | cg_kill_recursive 的 cgroup.procs 读取与子组递归 |
| 15 | src/core/service.c:2420-2476 | service_shall_restart：ExitStatus 覆盖 + 七种 Restart 策略 |
| 16 | src/core/manager.c:3170-3246 | SIGCHLD 两段式 waitid（WNOWAIT 偷看→处理→收尸） |

（附：result 枚举与字符串表 `src/core/service.h:79-93`、`src/core/service.c:6588-6600`；is_clean_exit `src/shared/exit-status.c:140-154`；停止 fallback 链 `src/core/service.c:2696-2703`。）
