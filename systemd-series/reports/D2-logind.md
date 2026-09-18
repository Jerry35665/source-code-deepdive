# D2 · logind：会话、seat 与电源策略

> 系列：《systemd 深读》卷二 ｜ 基线：commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`
> 本卷聚焦 src/login/ 的 systemd-logind 守护进程。卷一 E 报告已讲过 cgroup 集成与 Delegate；
> 本文只回答 logind 如何用它们组织"人"的层次。文中行号均经本基线 Read/Grep 核对。
>
> 命名提示——本基线有两处 API 世代交替需留意：
> (1) **v258 起 session 追踪的 FIFO 已移除**，改用 pidfd（src/login/logind-session-dbus.c:921；
> 　　旧 FIFO 字段仅在 session_load 里做 unlink 兼容，logind-session.c:677-680）；
> 　　inhibitor 的 FIFO 仍在（logind-inhibit.c:295）。
> (2) CreateSession 有了 Varlink 版 `io.systemd.Login.CreateSession`，
> 　　pam_systemd 优先走 Varlink（pam_systemd.c:1124-1126），失败再回退 D-Bus（pam_systemd.c:1240）。

## 一、全景：对象层次与 cgroup 树

logind 内存中是六张哈希表（devices/seats/sessions/users/inhibitors/buttons，logind.c:77-82），
构成 "user → seat → session → device" 四层；每层各自映射到 PID 1 维护的 cgroup 树：

```
  logind 对象层次(内存)                      PID 1 的 cgroup 树
  ─────────────────────                     ─────────────────────────────────────
  User(uid=1000) ◄─── sessions 列表          user.slice
   │  display 选举、linger                      └─ user-1000.slice   ← logind-user.c:77
   │  state_file /run/systemd/users/1000          ├─ user@1000.service  ← :85
   ▼                                              ├─ user-runtime-dir@1000.service (:81)
  Seat("seat0"...)                                └─ session-c1.scope ← logind-session.c:794
   │  udev tag master-of-seat 汇入设备                └─ 领头进程及全部子孙
   ├─ Device(drm/input, master?) ← logind-device.c:72 device_attach
   ▼
  Session(c1, VT2) ◄─ seat->positions[VTnr] (logind-seat.c:688)
   ├─ leader pidfd       ← session_set_leader_consume (logind-session.c:236)
   ├─ SessionDevice ×N   ← TakeDevice 移交的设备 fd (logind-session-dbus.c:1070)
   └─ vtfd (/dev/tty2)   ← session_prepare_vt (logind-session.c:1438)
  Inhibitor / Button：横切对象,挂在 manager->inhibitors / buttons
```

manager 主循环极简（`manager_run()`，logind.c:1325）：每圈先 `manager_gc()`
回收失去引用的 seat/session/user（logind.c:1073-1118），再 `manager_dispatch_delayed()` 检查 delay 型 inhibitor 是否到点（logind.c:1339），然后 `sd_event_run()` 阻塞（logind.c:1345）。
启动路径 `manager_startup()`（logind.c:1211）按序：连 utmp/console/udev/bus →
实例化魔法 seat0（logind.c:1245）→ 冷插枚举 devices/seats/users/sessions/fds/
inhibitors/buttons（:1254-1280）→ 逐层 start 全部对象（:1298-1318）。
运行目录在 `run()` 里最先创建（/run/systemd/{seats,users,sessions}，logind.c:1389-1391）——
其他程序以这些目录的存在判断 logind 是否可用。

**两套对外 API 的分工**：D-Bus `org.freedesktop.login1`（logind-dbus.c:3910-3964 的 vtable）
承担全部控制面与信号（PrepareForShutdown/SessionNew 等）；Varlink `io.systemd.Login`（logind-varlink.c:891-898）只提供 CreateSession/ReleaseSession 与四张表的 List* 只读查询，
监听 `/run/systemd/io.systemd.Login` 权限 0666（logind-varlink.c:912）。
CreateSession 走 Varlink 时要求**特权对端**（varlink_check_privileged_peer，
logind-varlink.c:328），且必须携带 pidfd（NoSessionPIDFD，logind-varlink.c:338-339），两路最终汇入同一个 `manager_create_session()`。

## 二、session 生命周期：CreateSession → scope → Release

入口序列（以 PAM 登录为例）：

1. **参数校验与对象就位**。`manager_create_session()`（logind-dbus.c:884）：
   拒绝已在会话中的进程（-EBUSY，:937-944）；拒绝已被占用的 VT
   （-EADDRNOTAVAIL，:951-956，greeter 类可例外以兼容 gdm 换届）；拒绝超上限
   （-EUSERS，:958）。会话 ID 优先复用 audit ID，冲突则退化为 `c<counter>`（:867-874）。
   接着 `manager_add_user_by_uid` 建 User，并按用户身份"降级"会话类：
   自动判定的 USER 类，root 的 TTY 登录升为 USER_EARLY，图形会话保持 USER，
   否则降为 USER_LIGHT（:980-993）；首个"钉住"类会话把用户 GC 模式切成 USER_GC_BY_PIN
   （:1014-1015）——这样手动拉起的 user@.service 不会阻止用户最后退场。
2. **挂 seat 并启动**。`seat_attach_session()`（logind-seat.c:716）把会话挂进链表并分配
   position（有 VT 的 seat 上 position≡VTnr，logind-seat.c:690-691）。
   `session_start()`（logind-session.c:884）先 `user_start()`（:898）再
   `session_start_scope()`（:902）。
3. **scope 创建**。`session_start_scope()`（logind-session.c:778）拼出
   `session-<id>.scope`（:794），调 `manager_start_scope()`（logind-dbus.c:4437）
   向 PID 1 发 **StartTransientUnit**（:4461）。属性清单：Slice=user-1000.slice；
   Requires+After=user-runtime-dir@1000.service；Wants=user@1000.service（按会话类，
   logind-session.c:807-816）；After=systemd-logind.service 与
   systemd-user-sessions.service（root 例外不等登录屏障，logind-session.c:810-816）；
   SendSIGHUP=true（bash 忽略 SIGTERM，logind-dbus.c:4519）；OOMPolicy=continue（:4529）；
   TasksMax=infinity 交给 slice 管（:4534）。

   **领头进程不是 logind 事后搬运的，而是把 leader 的 PID/PIDFD 属性直接写进 transient
   unit**（bus_append_scope_pidref，logind-dbus.c:4523；PID 1 不认 PIDFD 属性时整体降级重试，
   :4557-4572）。
   `AttachProcessesToUnit` 这条 PID 1 API（src/core/dbus-manager.c:3280）在这里并不出场
   ——它是给 **user manager** 把自己名下进程附加进被 Delegate 的子 cgroup 用的
   （src/core/cgroup.c:2197-2222，即卷一 E 的 Delegate 链路）；logind 只经手 scope 的"第一进程"。
4. **延迟应答**。scope/user@.service 未就绪时 CreateSession 调用先挂起，
   `session->create_message`（D-Bus）/`create_link`（Varlink，logind-varlink.c:372）暂存，
   就绪后 `session_send_create_reply()` 补发；旧 FIFO 返回值如今是个 eventfd 占位符
   （logind-session-dbus.c:924），应答串 "soshusub"（logind-session-dbus.c:942）。
5. **退出**。客户端（pam 帧进程）死亡由 leader pidfd 的事件源感知
   （session_watch_pidfd，logind-session.c:112）；`ReleaseSession` 仅允许会话自揭
   （发送者会话须匹配，logind-dbus.c:1394-1398），`session_release()` 只是装一个 20s 定时器
   （RELEASE_USEC，logind-session.c:55、:1097-1112）。到点或 GC 触发 `session_stop()`（:1002）：
   先 **AbandonScope**（logind-session.c:966，告诉 PID 1 剩余进程是"遗留物"并让它记杀进程日志），
   再按 KillUserProcesses/用户记录决定是否 StopUnit 杀 cgroup（:975-986）——不杀时会话停留在
   closing 态，与删除是两个时刻。真正移除对象在 `session_finalize()`（:1039）：
   删设备、删状态文件（:1064）、发 SessionRemoved。

## 三、user 对象：user@.service、runtime 目录与 linger

`user_new()` 为每个 UID 生成一套名字（logind-user.c:44-115）：state 文件 `/run/systemd/users/<uid>`（:70）、runtime 路径 `/run/user/<uid>`（:73）、
slice `user-<uid>.slice`（:77），以及 user-runtime-dir@（:81）、user@（:85）、systemd-pcrlogin@（:89）三个服务名。

`user_start()`（logind-user.c:536）的顺序是精心安排的：先把 state 文件**写盘**（:558-561，
pam_systemd 稍后会从 `/run/systemd/users/<uid>` 读 XDG_RUNTIME_DIR 回填环境）；
再调 SetUnitProperties 调整 slice 的 TasksMax/MemoryMax 等（:477-534）；
测量 TPM2 NvPCR（best-effort，:379-410）；启动 user-runtime-dir@（:359-377，
独立服务负责把 tmpfs 挂到 /run/user/<uid> 并配配额，src/login/user-runtime-dir.c:136）；
最后有条件启动 user@.service（:425-453）——只有存在需要服务管理器的会话类、
或该用户开了 linger 才拉起（user_wants_service_manager，:412-423）。

停止方向是反向的、且**只显式停 runtime-dir**：`user_stop_service()` 靠 unit 的 BindsTo=
关系让 user@.service 跟着退场（logind-user.c:604-606 的注释），自身只 StopUnit
user-runtime-dir@（:613）。GC 由 `user_may_gc()` 判定（logind-user.c:794）：有无 pinning 会话（:771-792）→
最后一个会话关闭后再留 user_stop_delay（默认 10s，logind-core.c:45；判定 :805-816）→
linger 用户若三个单位都死了也照样回收（:828，含 soft-reboot 后冷插场景的例外注释 :819-827）。`user_finalize()` 负责
清理 POSIX/SysV IPC（RemoveIPC，排除系统用户，logind-user.c:663-670）与删 state 文件（:672）。
linger 标志本身只是 `/var/lib/systemd/linger/` 下一个以转义用户名命名的文件
（user_check_linger_file，:717-737），启动时由 `manager_enumerate_linger_users()`
据此预先建 User 对象（logind.c:288-321）；带 linger 的用户处于 USER_LINGERING 态
（logind-user.c:892-893）。

## 四、seat 管理与设备分配

seat 完全由 udev 驱动：带 `master-of-seat` tag 的设备出现时，`manager_process_seat_device()`
（logind-core.c:268）读设备所属 seat 名（:294），非 master 设备不建未知 seat（:307），
master 设备则 manager_add_device + 必要时 manager_add_seat + device_attach + seat_start（:314-329）。
`device_attach()`（logind-device.c:72）把 master 设备排在 seat 设备链表头（:87-102）；seat 从无到有拿到 master 设备时发 CanGraphical 变更（:104-107），
失去最后一个 master 设备则把 seat 排进 GC 队列（:55-58）。
运行中的热插拔由多条 udev monitor 分诊（logind.c:957-1071）：
seat monitor（master-of-seat）、input/graphics/drm monitor、uaccess monitor、
button monitor（power-switch）与 vcsa monitor——vcsa 设备移除时重补自动 VT（logind.c:722-743）。

seat0 是唯一有 VT 的 seat：`seat_has_vts()` = 是 seat0 且成功打开过
`/sys/class/tty/tty0/active`（logind-seat.c:750-754）。多 seat（无 VT）的会话切换由
logind 自己实现：

```
/* logind-session.c:761-773 (节选) */
/* On seats without VTs, we implement session-switching in logind. We
 * try to pause all session-devices and wait until the session
 * controller acknowledged them. Once all devices are asleep, we simply
 * switch the active session and be done. */
s->seat->pending_switch = s;

/* if no devices are running, immediately perform the session switch */
num_pending = session_device_try_pause_all(s);
if (!num_pending)
        seat_complete_switch(s->seat);
```

有 VT 的 seat 则直接 `chvt()`（logind-session.c:753-758）。
`seat_switch_to/next/previous` 提供 API 级切换（logind-seat.c:468-533）。

## 五、设备与 VT：待命 watch、激活与暂停

**VT 待命 watch** 是一个文件 fd：logind 打开 `/sys/class/tty/tty0/active` 挂进
event loop（logind.c:919-934），内核前台 VT 一变就触发 `seat_read_active_vt()`——
lseek 0 再读出 tty 名（logind-seat.c:580-590），换算 VTnr 后 `seat_active_vt_changed()`
选出新活跃会话并 `manager_spawn_autovt()`（:535-567；按 n_autovts=6 与 reserve_vt=6
预留位拉 getty，logind-core.c:573-603）。

另一路是 **VT_PROCESS 同步信号**。图形式会话的 vtfd 上：

```
/* logind-session.c:1475-1481 (节选) */
/* Oh, thanks to the VT layer, VT_AUTO does not work with KD_GRAPHICS.
 * So we need a dummy handler here which just acknowledges *all* VT
 * switch requests. */
mode.mode = VT_PROCESS;
mode.relsig = SIGRTMIN;
mode.acqsig = SIGRTMIN + 1;
r = ioctl(vt, VT_SETMODE, &mode);
```

logind 对 SIGRTMIN+0 的应答在 `manager_vt_switch()`（logind.c:846-905）——
遍历会话找到持该 VT vtfd 者，先 `session_device_pause_all()` 暂停设备再
`vt_release()` 确认切换（logind-session.c:1539-1550；prepare 的前两步是
K_OFF 与 KD_GRAPHICS，:1459-1473）。

**会话激活的通知链**已从 FIFO 换代：控制器（合成器）经 TakeControl 独占
（logind-session-dbus.c:381）、TakeDevice 拿走设备 fd（:563，drm 设备顺带 drmSetMaster，
logind-session-device.c:156）；PauseDevice/ResumeDevice 信号（vtable
logind-session-dbus.c:1091/:1094）通知暂停/恢复；切换的"完成"事件由 `seat_set_active()`
触发——暂停旧会话设备（logind-seat.c:443）、对 seat 设备触发 uevent 以便 udev 改 ACL
（:447-451）、必要时恢复同一会话的设备防黑屏（:427-433）。session 设备 fd 在 logind
重启后经 fdstore 归还：fd 名编码 `session-<id>-device-<maj>-<min>`，
`deliver_session_device_fd()` 校验后重挂（logind.c:414-447）；leader pidfd 同理（:449-502）。

## 六、电源按钮与盖子事件

配置默认值在 `manager_reset_config()`（logind-core.c:38）：HandlePowerKey=poweroff（:50）、
HandleLidSwitch=suspend（:60）、外接电源/扩展坞分别可配（:61-62）；按钮配置全为 IGNORE 时干脆不建按钮 monitor（logind.c:1024）。button 对象对应一个 `power-switch` input 设备：
`button_open()` 挂 EPOLLIN（logind-button.c:583-614），`button_dispatch()` 解析 evdev
事件（:268）；电源键短按立即调 `manager_handle_action()`，长按另有一个定时器分支（:183-197）；
盖子不是边沿事件——`button_check_switches()` 用 EVIOCGSW 读初始状态（:626-644），
盖着时挂 post 事件源反复复查（:158-181）；动作按"是否在扩展坞/外接电源"三分（:141-156）：

```
/* logind-button.c:146-155 (节选) */
/* If we are docked or on external power, handle the lid switch
 * differently */
if (manager_is_docked_or_external_displays(manager))
        handle_action = manager->handle_lid_switch_docked;
else if (handle_action_valid(manager->handle_lid_switch_ep) &&
         manager_is_on_external_power())
        handle_action = manager->handle_lid_switch_ep;
else
        handle_action = manager->handle_lid_switch;

manager_handle_action(manager, INHIBIT_HANDLE_LID_SWITCH, handle_action,
                      manager->lid_switch_ignore_inhibited, is_edge, seat);
```

`manager_handle_action()`（logind-action.c:344）是统一的动作机：动作查表得
target/polkit/inhibit 位（:27-132，如 HANDLE_SUSPEND→sleep.target+INHIBIT_SLEEP，:88-96）；
**盖子有 30s holdoff 期**（开机/唤醒后忽略，:363-370 与 logind-core.c:70）；
按键被 inhibitor 屏蔽时静默放弃（:373-380）；HANDLE_LOCK 只广播锁屏（:383-390）；
真正执行在 `handle_action_execute()`：**block 型 inhibitor 直接拒绝并指认 blocker**
（:234-251），否则 `bus_manager_shutdown_or_sleep_now_or_later()`。

delay 的接力在 logind-dbus.c：有 delay 型 inhibitor 时先广播 PrepareForShutdown、
挂 inhibit_delay_max=5s 定时器延后执行（:2156-2170 与 :2096-2116），每圈主循环里
`manager_dispatch_delayed()` 检查延迟锁是否消失/超时（logind.c:1339，
logind-dbus.c:2043-2082）。执行本体就是向 PID 1 StartUnit 对应 target，
模式 replace-irreversibly（logind-dbus.c:2012-2018）。

## 七、inhibitor：分级、计数与 FIFO

`Inhibit` 一次调用创建一个 inhibitor 对象并**返回一个 FIFO 写端 fd**
（logind-dbus.c:3678-3800）。`inhibitor_create_fifo()` 在 /run/systemd/inhibit/<id>.ref
建 FIFO，logind 持读端挂 io 事件源（优先级高于 idle，logind-inhibit.c:322-326），
写端交给调用方——**进程退出 fd 关闭、读端看到 EOF，inhibitor 即刻消失**（:283-293）。
这是"存活期即抑制期"的全部机制，不需要引用计数。

分级是查询期的过滤而非存储期分类：

```
/* logind-inhibit.c:416-424 (节选) */
HASHMAP_FOREACH(i, m->inhibitors) {
        if (!i->started)
                continue;

        if (!(i->what & w))
                continue;

        if (FLAGS_SET(flags, MANAGER_IS_INHIBITED_CHECK_DELAY) != (i->mode == INHIBIT_DELAY))
                continue;
```

即 `manager_is_inhibited()`（:400）按调用标志只匹配对应模式；block-weak 可被同 UID
调用者忽略（:430-433），"最强"模式者作为 offending 报出（:440-442）；三种模式
block/block-weak/delay 见表 :593-597。按键类 inhibit（INHIBIT_HANDLE_POWER_KEY 等，
位表 :454-493）在 `manager_handle_action` 的 :373-380 生效，与 shutdown/sleep 类分开
屏蔽"按键"与"API"两条路径。重启后 inhibitor 从 state 文件冷插（logind.c:610-641），FIFO 两端重开
（logind-inhibit.c:271-278），孤儿（对端已死）直接回收
（inhibitor_is_orphan，:349-365）。

## 八、idle 管理

idle hint 的判定按会话类型分流（session_get_idle_hint，logind-session.c:1160）：
**图形会话**由合成器显式 SetIdleHint（:1219，仅图形类可设，:1224），值与时间戳随对象走
（:1174-1179）；**TTY 会话**没有显式提示，logind 读 **TTY 的 atime**——优先会话自带
tty，否则取 leader 的控制终端（:1181-1196）；不适合 idle 的会话类（manager 等）恒不空闲
（SESSION_CLASS_CAN_IDLE，logind-session.h:51；:1166-1171）。
TTY 空闲阈值取 idle_action_usec 与 stop_idle_session_usec 的较小者：
atime 距今超过它即算空闲（logind-session.c:1207-1216）。

汇总方向：seat/user/manager 逐级 OR，并取"最近的提示时间戳"；全局还要求无
INHIBIT_IDLE 抑制（manager_get_idle_hint，logind-core.c:450-490，:461）。
空闲的**后果**由一个自维护的单发定时器驱动（manager_dispatch_idle_action，
logind.c:1120）：到点执行 idle_action（默认 30min，logind-core.c:72）并记录 edge
状态避免重复触发；另外每个支持类会话可单独配 StopIdleSessionUs，到点强制关会话
（logind-session.c:832-882）。

## 九、sleep 入口

logind 不碰 /sys/power。挂起/休眠 = `execute_shutdown_or_sleep()` 对
suspend.target / hibernate.target / hybrid-sleep.target / suspend-then-hibernate.target
发 StartUnit（logind-action.c:88-123，logind-dbus.c:2012-2018）。可行性检查只做两件：

- `sleep_supported()`（dlopen 实现在 src/sleep，logind-action.c:144；判定维度见
  src/shared/sleep-config.h:45-54——内核 state/mode 支持、resume= 能否在 /proc/swaps
  找到、swap 空间是否够）；
- `HANDLE_SLEEP` 动作按 suspend-then-hibernate → hybrid → suspend → hibernate 顺序
  挑第一个可用且 target 已加载的（logind-action.c:151-156、:175-196），请求的动作
  不支持时降级为普通 suspend（:286-293）。

真正写 `/sys/power/state`、`/sys/power/disk` 的是 target 拉起的 systemd-sleep
（src/sleep/sleep.c:271-273、:303），与 logind 完全解耦——logind 只"点菜"，内核写入由
systemd-sleep 这个独立可执行完成。

## 十、持久化与冷插

logind 把"可重建的运行时状态"全部落成 /run 下的微型 env 文件：
seat → /run/systemd/seats/<id>（seat_save，logind-seat.c:101）；
user → /run/systemd/users/<uid>（logind-user.c:162，含 SESSIONS=/SEATS=/ACTIVE_SESSIONS=
等冗余列表 :211-295）；session → /run/systemd/sessions/<id>
（logind-session.c:337，含 LEADER_PIDFDID :409-414、CONTROLLER+DEVICES :426-429）；
inhibitor → /run/systemd/inhibit/<id>（FIFO= 也存，logind-inhibit.c:141）。
写入都是 O_TMPFILE + fchmod 0644 + flink_tmpfile 原子替换（如 logind-session.c:354-440）。

冷插顺序（manager_startup，logind.c:1254-1320）：先 udev 枚举设备建 seat；
读 seats/users/sessions 目录反序列化（session_load 支持 pidfd id 校验防 PID 复用，
logind-session.c:477-517）；fdstore 里的 leader pidfd 与设备 fd 按名归位
（logind.c:581-608）；inhibitors/buttons；GC 清陈货；逐层 seat_start/user_start/
session_start。也就是说 logind 重启期间**已存在的会话不断链**：scope 还在 PID 1 名下，
logind 回来后重新接管。

## 设计动机

1. **每会话一个 scope 而非 service**：会话不是被 PID 1 "管理"的单元（无 Type=/Restart=
   语义），scope 让 PID 1 只提供 cgroup 归置与存活登记，归属判定权留给 logind；
   AbandonScope 语义（"剩下的进程与我无关但请记日志"）天然契合注销时"杀或不杀残留
   进程"的策略分叉（logind-session.c:963-997）。
2. **FIFO 通知存活/激活**：inhibitor 的抑制期 == 进程存活期，用"写端关闭即 EOF"把
   liveness 委托给内核，logind 无需轮询或身份核验；旧版 session 追踪也用它，v258 换
   pidfd 是因为 pidfd 还能防 PID 复用——FIFO 只答"死没死"，不答"是谁"。
3. **inhibitor 分 block/delay（现加 block-weak）**：block 保护"挂起前必须说上话"的权益
   （Burn CD 场景），delay 给"只想拖几秒刷盘"的普通应用留出 5s 窗口后放行——把"能否
   阻止"与"能阻止多久"解耦，避免单一语义下要么全挡要么全放。
4. **seat 抽象**：把"一组共享同一物理显示/输入的设备 + 至多一个活跃会话"收拢成对象，
   才能在多显卡整机与单 VT 笔记本上用同一套代码：seat0 有 VT 就借内核 VT 调度，无 VT
   的 seat 由 logind 用 pending_switch+设备暂停协议自己调度（logind-session.c:761-775），
   上层的 TakeDevice/ACL 策略完全一致。
5. **user manager 独立进程（user@.service）**：把相当一部分 PID 1 功能按用户横切出去，
   既给用户态服务一个非特权的管理者（安全边界），也让 logind 只需 StartUnit/StopUnit
   两个动词就能启停整个用户会话环境；logind 通过 BindsTo= 借 PID 1 的依赖关系托管它
   的生命周期（logind-user.c:604），自己不维护 user manager 的状态机。
6. **状态文件 + fdstore 双轨持久化**：/run 下的 env 文件让人可读、可审计（开头就写
   "This is private data. Do not parse."），fdstore 传 fd 解决"重启后拿不回来的资源"
   （pidfd/设备 fd），两者合起来让 logind 成为可随时重启的无状态守护进程。

## 写作素材清单

- src/login/logind.c:1211 — manager_startup 总序：连接、冷插枚举、逐层 start
- src/login/logind.c:919 — /sys/class/tty/tty0/active 作为 VT 待命 watch 的 fd
- src/login/pam_systemd.c:1124 — PAM 优先 Varlink 创建会话，:1240 回退 D-Bus
- src/login/logind-dbus.c:884 — manager_create_session：ID、类降级、GC 模式切换
- src/login/logind-session.c:778 — session_start_scope：scope 命名与依赖注入
- src/login/logind-dbus.c:4437 — manager_start_scope：StartTransientUnit 属性与 PIDFD 降级
- src/login/logind-session.c:1002 — session_stop：AbandonScope 与杀留策略
- src/login/logind-user.c:536 — user_start：先落盘再启动、runtime-dir→user@ 的次序
- src/login/logind-user.c:794 — user_may_gc：pinning/stop_delay/linger 三段判定
- src/login/logind-core.c:268 — manager_process_seat_device：master-of-seat 建 seat
- src/login/logind-seat.c:413 — seat_set_active：暂停旧设备、udev ACL、防黑屏恢复
- src/login/logind-session.c:1438 — session_prepare_vt：K_OFF/KD_GRAPHICS/VT_PROCESS
- src/login/logind-button.c:626 — button_check_switches：EVIOCGSW 读盖子初态
- src/login/logind-action.c:344 — manager_handle_action：holdoff、按键 inhibit、LOCK
- src/login/logind-inhibit.c:295 — inhibitor_create_fifo；:400 manager_is_inhibited 分级
- src/login/logind-varlink.c:243 — vl_method_create_session：特权对端 + pidfd 强制
