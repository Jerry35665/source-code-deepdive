# B2 · udevd:设备事件的处理管线

> 基线:systemd commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`。所有 `文件:行号` 均经实际 Read/Grep 核对。
> 版本说明:这一代源码里 `udevd.c` 已收缩为 91 行的薄入口;守护进程主体在 `src/udev/udev-manager.c`(管理进程)与 `src/udev/udev-worker.c`(工作进程),事件执行在 `udev-event.c`,规则引擎在 `udev-rules.c`。旧版的 `udev-ctrl.c` 私有控制协议已删除,`udevadm control` 改走 Varlink(见 §10);`HANDLED` 标记也不复存在,并发标记是 `ID_PROCESSING`(见 §5)。

## 0. 一条 udev 事件的完整路径

```
 内核 (drivers)  kobject_uevent()
        │  netlink 组播 KOBJECT_UEVENT (group=kernel)
        ▼
 ┌─────────────────────────── systemd-udevd (manager) ───────────────────────────┐
 │  sd_device_monitor → on_uevent()                          udev-manager.c:1048 │
 │        │ event_queue_insert(): 入队、按 SEQNUM 排序       udev-manager.c:857  │
 │        ▼                                                                     │
 │  Event 状态机 QUEUED ──有 blocker?──► 等待(同/父/子 devpath 串行化)           │
 │        状态枚举 udev-manager.h:82-85;找 blocker udev-manager.c:624           │
 │        ▼                                                                     │
 │  event_queue_start() → event_run(): 挑空闲 worker 或 fork 新 worker          │
 │        udev-manager.c:688 / 574 / 509(fork 于 :530)                          │
 │        │ netlink 单播把 device 发给 worker                 :584              │
 └────────┼─────────────────────────────────────────────────────────────────────┘
          ▼
 ┌────────────────────── udev-worker (子进程, 一worker一事件) ──────────────────┐
 │  worker_process_device()                                  udev-worker.c:194  │
 │    1. flock(LOCK_SH) 整盘共享锁, 忙则 TRY_AGAIN → 事件转 LOCKED  :86/:118    │
 │    2. udev_watch_end() 摘除 inotify watch                        :224        │
 │    3. udev_event_execute_rules(): 规则引擎          udev-event.c:372         │
 │         ├─ 逐文件逐行逐 token: udev_rules_apply_to_event  udev-rules.c:3293  │
 │         ├─ IMPORT{builtin} → blkid/net_id/...             udev-rules.c:2530  │
 │         ├─ NAME=/SYMLINK=/OWNER/GROUP/MODE/ATTR/ENV 写入  udev-rules.c:2935+ │
 │         ├─ rename_netif(): 网卡改名(RTM_NEWLINK)         udev-event.c:410   │
 │         └─ update_devnode(): 权限 + 软链接仲裁            udev-event.c:273   │
 │    4. udev_event_execute_run(): RUN{builtin|program}      udev-spawn.c:361   │
 │    5. 清 ID_PROCESSING 并 device_update_db() → /run/udev/data  :249-253      │
 │    6. 组播"已处理"事件 + sd_notify PROCESSED=1                 :261/:268     │
 └──────────────────────────────────────────────────────────────────────────────┘
        │ PROCESSED / group=udev 组播
        ▼
  PID 1: device_dispatch_io() 更新 .device unit   src/core/device.c:1144(详见卷一)
  注: /dev 节点本体由内核 devtmpfs 创建; udevd 负责权限/标签/软链接, 不做 mknod
      (sd_device_open + fchmod_and_chown   src/udev/udev-node.c:699/:636)
```

## 1. 事件来源:netlink 监听与入队

`udevd.c:run_udevd()` 只做初始化:`manager_new()`(src/udev/udevd.c:34)、`manager_load()`(udevd.c:38)、`must_be_root()`(udevd.c:42)、建 `/run/udev` 目录(udevd.c:56)、预加载 libblkid/libkmod/libacl 等动态库——fork 出的 worker 靠 COW 共享这些页(udevd.c:61-65)——随后 `manager_main()`(udevd.c:90)。

真正的事件源是内核 netlink 组播 socket:`manager_start_device_monitor()` 以 `MONITOR_GROUP_KERNEL` 创建 monitor(udev-manager.c:1096),`sd_device_monitor_start(..., on_uevent, ...)` 注册回调(udev-manager.c:1111),并把事件源优先级设为 `EVENT_PRIORITY_DEVICE_MONITOR`(udev-manager.c:1115),让 uevent 先于 Varlink 等控制流量被处理。这个 monitor 同时是 manager 向 worker **单播**事件的发送端(worker 侧用 `device_monitor_allow_unicast_sender()` 授权,udev-manager.c:524)。

`on_uevent()`(udev-manager.c:1048)做三件事:touch `/run/udev/queue` 标志文件——`udevadm settle` 与外部工具靠它的存在判断"udevd 还有活没干完"(udev-manager.c:1238,队列清空时在 `manager_unlink_queue_file()` 删除,udev-manager.c:1251);记录设备初始化时间戳;然后 `event_queue_insert()`(udev-manager.c:857)入队。入队时处理内核乱序:按 SEQNUM 在链表中找到正确插入点,遇到相同 SEQNUM 直接判重丢弃,必要时回退已排队事件的 blocker 引用(udev-manager.c:912-931);若设备带有 `udevadm trigger` 的合成 UUID 则回收之(udev-manager.c:868-869)。

主循环 `manager_main()`(udev-manager.c:1438)依次装配:workers cgroup(udev-manager.c:1445-1466)、事件循环、Varlink server(udev-manager.c:1479)、monitor(udev-manager.c:1483)、inotify(udev-manager.c:1487)、worker notify socket,然后 `udev_builtin_init()` + `udev_rules_load()`(udev-manager.c:1497-1503)并进入 `sd_event_loop()`(udev-manager.c:1507)。每轮循环末尾的 `on_post()`(udev-manager.c:1292)是队列的"心跳":重试 LOCKED 事件、用空闲 worker 消化积压(udev-manager.c:1306-1309)、清点残留 worker,全空时对 workers cgroup 做 `cgroup.kill` 兜底清理(udev-manager.c:1316-1319)。

## 2. 主循环与事件状态机:worker 池、串行化、超时与生命周期

事件四状态(udev-manager.h:82-85):`QUEUED → RUNNING`,被磁盘锁挡住则 `LOCKED`,处理完 `PROCESSED`(引用随即释放,udev-manager.c:102-110)。

**找 blocker(同设备串行化)**。`event_queue_start()`(udev-manager.c:688)的核心循环只有 10 行:

```c
/* src/udev/udev-manager.c:708-718 */
LIST_FOREACH(event, event, manager->events) {
        if (event->state != EVENT_QUEUED)
                continue;

        event_find_blocker(event);

        /* do not start event if parent or child event is still running or queued */
        if (event->blocker)
                continue;

        r = event_run(event);
        if (r < 0)
                return r;
```

`event_find_blocker()`(udev-manager.c:624)向前扫描未完成事件:与自己在 devpath 上有前缀包含关系(`devpath_conflict()`,udev-manager.c:611,涵盖同一设备与父子设备)、或 device id、节点名、`DEVPATH_OLD` 之一相同,即视为 blocker。它串行化的是**可能互相改写状态的设备链**,而不是整个队列——不同磁盘的事件仍然并行。

**worker 派发与 fork**。`event_run()`(udev-manager.c:574)先遍历 `manager->workers` 找 `WORKER_IDLE` 者,把设备经 manager 的 netlink socket **单播**过去(udev-manager.c:584);worker 不收直接 SIGKILL(udev-manager.c:589)。没有空闲 worker 且总数未到 `children_max`(udev-manager.c:600)则 `worker_spawn()` fork(udev-manager.c:509,`pidref_safe_fork("(udev-worker)")` 于 :530):子进程带走 rules/properties 的所有权副本、加入 `workers` cgroup(udev-manager.c:545-548)、以 `$NOTIFY_SOCKET` 指向 manager 后执行 `udev_worker_main()`(udev-manager.c:559);父进程 `worker_new()` 注册 SIGCHLD 回调并 `worker_attach_event()`(udev-manager.c:564-568)。默认 worker 数按资源算:`CPU*2+16` 与 `内存/128MiB` 取小(udev-config.c:283-299),`udev.children_max=` 可覆盖(udev-config.c:44)。

**超时杀 worker**。`worker_attach_event()` 挂两个单调时钟定时器:警告(udev-manager.c:391,`udev_warn_timeout`)与击杀(udev-manager.c:403);击杀时限在 `event_timeout` 上加余量(udev-config.c:633),给 worker 留出"自己发现子程序超时并善后"的机会。到点回调只做一件事(udev-manager.c:353-361):

```c
/* src/udev/udev-manager.c:353-361(节选) */
static int on_worker_timeout_kill(sd_event_source *s, uint64_t usec, void *userdata) {
        Worker *worker = ASSERT_PTR(userdata);
        Manager *manager = ASSERT_PTR(worker->manager);
        Event *event = ASSERT_PTR(worker->event);

        (void) pidref_kill_and_sigcont(&worker->pidref, manager->config.timeout_signal);
        worker->state = WORKER_KILLED;
        ...
}
```

worker 正常退出走 `on_worker_exit()`(udev-manager.c:428):非零退出码/信号被 `device_add_exit_status()/device_add_signal()`(src/udev/udev-error.c:31/:43)记为 `UDEV_WORKER_FAILED=1` 等属性(udev-error.c:21/:39),随事件广播给 PID 1,PID 1 据此拒绝消费脏事件。

**worker→manager 带外通知**。`on_worker_notify()`(udev-manager.c:1122)处理 worker 经 `$NOTIFY_SOCKET` 发来的消息:`INOTIFY_WATCH_ADD/REMOVE=1` 请求由 manager 代为执行并用 SIGUSR1 回传结果(udev-manager.c:1140/:1160);`TRY_AGAIN=1` 表示 worker 抢整盘 flock 失败,事件经 `event_enter_locked()`(udev-manager.c:804)转入 `LOCKED`(udev-manager.c:853),按整盘设备名挂进 `locked_events_by_disk` 哈希,由定时器每 200ms 重试、3 分钟超时放弃(udev-manager.c:48-49,:825-827)。

**生命周期与序列化**。SIGTERM → `manager_exit()`(udev-manager.c:247):停 Varlink、停 monitor、SIGTERM 全部 worker(udev-manager.c:199 `manager_kill_workers()`)。SIGHUP → `manager_reload(force=true)`(udev-manager.c:1226):3 秒限频、SIGTERM 空闲 worker(udev-manager.c:327)、重载规则;`udevadm control --revert` 对应 `manager_revert()`(udev-manager.c:342)。退出前把未处理 QUEUED 事件写进一个 netlink "存储 socket" 并 push 进 PID 1 的 fdstore(udev-manager.c:946),下次启动 `manager_deserialize_events()` 收回(udev-manager.c:983)——事件队列跨重启存活。

## 3. worker 侧:一个事件的执行管线

`udev_worker_main()`(udev-worker.c:312)发出 `DEVICE_TRACE_POINT(worker_spawned)`(udev-worker.c:319)、先处理完交付的第一个设备(udev-worker.c:334)再进入事件循环(udev-worker.c:338)——worker 长期存活以摊薄 fork 成本,单 worker 也可串行接收后续事件。核心管线 `worker_process_device()`(udev-worker.c:194)开宗明义:

```c
/* src/udev/udev-worker.c:199-206 */
/* Take a shared lock on the device node; this establishes a concept of device
 * "ownership" to serialize device access. External processes holding an
 * exclusive lock will cause udev to skip the event handling; in the case udev
 * acquired the lock, the external process can block until udev has finished
 * its event handling. */
```

依次执行:`worker_lock_whole_disk()` 对整盘 `flock(LOCK_SH|LOCK_NB)`,EAGAIN 则 `sd_notifyf("TRY_AGAIN=1\nWHOLE_DISK=...")` 让路(udev-worker.c:118-126;remove 事件与 dm/md/drbd 不加锁,udev-worker.c:45/:104);可选 `blockdev_read_only` 模式下对块设备 `BLKROSET`(udev-worker.c:148);`udev_watch_end()` 摘 watch(udev-worker.c:224);跑规则 `udev_event_execute_rules()`(udev-worker.c:228);执行 RUN(udev-worker.c:233);非 remove 事件清 `ID_PROCESSING` 后终写数据库(udev-worker.c:249-253);向 group=udev 组播"已处理"事件(udev-worker.c:261);`sd_notify("PROCESSED=1")` 让 manager 置 PROCESSED(udev-worker.c:268)。失败路径把 errno 写入设备属性后照样广播(udev-worker.c:288-305),保证监听方总能看到终态。

规则执行主体 `udev_event_execute_rules()`(udev-event.c:372)的顺序值得背下来:remove 直接短路进 `event_execute_rules_on_remove()`(udev-event.c:313:读旧库→删 tag/index(udev-event.c:322)→删库→跑规则→删链接);否则 clone 出旧数据库快照 `dev_db_clone`(udev-event.c:389,`IMPORT{db}` 与 symlink 清理的基准),跑规则(udev-event.c:401 处 `DEVICE_TRACE_POINT(rules_start)`),`add` 事件此时才改网卡名(udev-event.c:410-415),`update_devnode()`(udev-event.c:273:权限 `udev_node_apply_permissions()`(udev-event.c:306)+ 软链接仲裁 `udev_node_update()`(udev-event.c:310)),刷新初始化时间戳(udev-event.c:422),写 tag 与数据库(udev-event.c:428),最后 `device_set_is_initialized()`(udev-event.c:448)。

`RUN=` 的执行在 `udev_event_execute_run()`(udev-spawn.c:361):builtin 直接函数调用;外部程序受 `exec_delay` 约束——延迟时长若会顶掉 `event_timeout` 则干脆不执行(udev-spawn.c:373-387)。外部程序的真正 fork 在 `udev_event_spawn()`(udev-spawn.c:229)。

## 4. 规则引擎:解析(token 化)与匹配执行链

**文件发现与目录优先级**。`RULES_DIRS` 覆盖 `/etc`、`/run`、`/usr/lib`、`/usr/local/lib` 等前缀下的 `udev/rules.d`(udev-rules.c:60);`udev_rules_load()`(udev-rules.c:1822)用 `conf_files_list_strv_full()` 将全部同名文件按**字典序**串成一条解析序列(udev-rules.c:1848),后出现的同名文件追加/遮蔽前者——这就是"数字前缀定序、/etc 覆盖 /usr/lib"的机制。`udev_rules_should_reload()` 比较 stat 摘要决定重载(udev-rules.c:1869)。

**解析即编译**。行在解析期被拆为 token 链,而非事件时逐行再解释。token 类型全表(udev-rules.c:111-169,节选):

```c
/* src/udev/udev-rules.c:119-131(节选) */
TK_M_ACTION,                        /* string, device_get_action() */
TK_M_DEVPATH,                       /* path, sd_device_get_devpath() */
TK_M_KERNEL,                        /* string, sd_device_get_sysname() */
TK_M_DEVLINK,                       /* strv, sd_device_get_devlink_first() ... */
TK_M_NAME,                          /* string, name of network interface */
TK_M_ENV,                           /* string, device property ... */
TK_M_SUBSYSTEM,                     /* string, sd_device_get_subsystem() */
TK_M_DRIVER,                        /* string, sd_device_get_driver() */
TK_M_ATTR,                          /* string, ... sd_device_get_sysattr_value() ... */
TK_M_SYSCTL,                        /* string, takes kernel parameter through attribute */
```

操作符枚举 `==/!=/+=/-=/=/:=`(udev-rules.c:62-73);匹配种类含空串/纯文本/glob/`|` 多值/大小写折叠(udev-rules.c:76-93)。token 结构 `UdevRuleToken` 记 `type/op/match_type/value/data`(udev-rules.c:186-197),挂在 `UdevRuleLine` 的 token 链上;行级位标志 `LINE_HAS_NAME/DEVLINK/STATIC_NODE/GOTO/LABEL/...`(udev-rules.c:171-183)在解析期算好,供执行期整行跳过。`parse_token()`(udev-rules.c:760)是 lvalue 分发表:`ACTION`(:780)、`DEVPATH`(:787)、`KERNEL`(:794)、`SUBSYSTEM`(:871)、`ATTR`(:888)、`IMPORT`(:988)、`RESULT`(:1026)、`OPTIONS`(:1033)、`RUN`(:1167)、`GOTO`/`LABEL`(:1183/:1196)。`IMPORT{program}` 有兼容彩蛋:命令名若命中 builtin 注册表,自动改写为 `TK_M_IMPORT_BUILTIN`(udev-rules.c:1010-1015)。行解析入口 `rule_add_line()`(udev-rules.c:1441),文件入口 `udev_rules_parse_file()`(udev-rules.c:1681,处理反斜杠续行、注释、超长行);尾部 `rule_resolve_goto()` 把 GOTO 绑定为行指针(udev-rules.c:1789),悬空引用在此暴露。

**执行链**。`udev_rules_apply_to_event()`(udev-rules.c:3293)按"文件序→行序→token 序"推进;每行先做廉价预筛——行标志与设备类别(devnum/ifindex)求交,不可能命中的行直接跳过(位定义 udev-rules.c:3239,整行跳过判断 :3260)。匹配 token 归一到 `token_match_string()`(udev-rules.c:1934),核心是五种匹配类别(udev-rules.c:1947-1969):EMPTY/PLAIN/GLOB 各自 NULSTR 多值循环 + `fnmatch`。`KERNELS==` 等父设备匹配由 `udev_rule_apply_parent_token_to_event()` 沿 parent 链自底向上逐层试(udev-rules.c:3182-3229),一行含父 token 即整行变为祖先匹配;GOTO 在行匹配完成后跳转(udev-rules.c:3285-3287)。

**关键语义**。`IMPORT{builtin}` 以位图保证 `run_once` builtin 每 event 一次并缓存成败(udev-rules.c:2530-2541);`IMPORT{db}` 从 `dev_db_clone` 取回上轮属性(udev-rules.c:2561);`TK_A_RUN_*` 只把命令挂入 `run_list`,统一推迟到规则跑完后执行(udev-rules.c:3142-3161);`NAME=` 仅对网络接口生效(udev-rules.c:2935);`SYMLINK=`(`TK_A_DEVLINK`,udev-rules.c:2962)允许空格分隔多链接、`=`/`:=` 先清空;`ATTR{f}="v"` 写 sysfs、支持 `[subsys/kernel]attr` 跨设备寻址(udev-rules.c:3023);`OWNER/GROUP/MODE` 的 `:=` 置 final 位拒绝后续覆盖(udev-rules.c:2711/:2777);`ENV` 支持追加 `+=`(udev-rules.c:2862)。

## 5. 数据库:/run/udev/data、ID_PROCESSING 与 IMPORT{db}

udev 的运行时状态全部落在 tmpfs 的 `/run/udev`:`queue` 标志文件(udev-manager.c:1238)、`tag/`、`links/`、`watch/`、`static_node-tags/`,以及每设备一份的 `data/<id>`。库路径由 `device_get_db_path()` 拼出:`/run/udev/data/ + device_id`(src/libsystemd/sd-device/device-private.c:832-845)。什么设备值得建库由 `device_should_have_db()` 决定:有 devlinks/优先级/属性/tag 之一,或有 devnum/ifindex(device-private.c:811-823)。

`device_update_db()`(device-private.c:865)是原子替换:临时文件 + `rename()`;`OPTIONS=db_persist` 置 sticky 位的 01644,标记"initrd 切根时不清理"(device-private.c:895-896)。格式一行一记录(device-private.c:905-925):

```c
/* src/libsystemd/sd-device/device-private.c:905-925(节选) */
fprintf(f, "S:%s\n", devlink + STRLEN("/dev/"));   /* 软链接 */
...
fprintf(f, "L:%i\n", device->devlink_priority);    /* 链接优先级 */
fprintf(f, "I:"USEC_FMT"\n", device->usec_initialized);
fprintf(f, "E:%s=%s\n", property, value);          /* 属性 */
fprintf(f, "G:%s\n", tag);                         /* 全部 tag */
fprintf(f, "Q:%s\n", ct);                          /* 当前 tag */
...
fputs("V:" STRINGIFY(LATEST_UDEV_DATABASE_VERSION) "\n", f);
```

并发安全的钥匙是 `ID_PROCESSING=1`:规则跑完、RUN 未执行前先写库并打标(udev-event.c:357-362),RUN 全部结束后移除再终写一次(udev-worker.c:249-253);网卡改名场景还把它先写进 `dev_db_clone` 落盘,再发 RTM_NEWLINK,免得 networkd 收到半成品(udev-event.c:186-192)。这样,任何读者(下一个事件、`udevadm info`)都能凭该属性判断"上一轮是否处理完"。显式读取旧值的通道是 `IMPORT{db}="PROP"`(udev-rules.c:2561-2577),从 `dev_db_clone` 取值后写入当前设备;`OPTIONS=db_persist` 则由 token `TK_A_OPTIONS_DB_PERSIST` 落到 `device_set_db_persist()`(device-private.c:826)。

## 6. 设备节点管理:权限、链接栈与 /dev/disk/by-*

现代 udevd **不做 mknod**——节点本体由内核 devtmpfs 创建(源码树内仅测试程序调用 mknod)。udevd 的职责从 `update_devnode()`(udev-event.c:273)开始:规则未给 uid/gid/mode 时从旧数据库回退(udev-event.c:287-299),然后 `udev_node_apply_permissions()`(udev-node.c:699)打开节点 fd(`sd_device_open(O_PATH)`)、`fchmod_and_chown()`(udev-node.c:640)、应用 `SECLABEL{selinux|smack}`(udev-node.c:663-676)、兜底打 MAC 标签并 `futimens()` 刷新时间戳(udev-node.c:692);`MODE` 未设但设了 group 时自动升级 0660(udev-node.c:623)。`OPTIONS=static_node=` 的静态节点在规则加载时由 `udev_rules_apply_static_dev_perms()` 统一处理(udev-rules.c:3341),其 tag 以 `/run/udev/static_node-tags/` 符号链接导出(udev-node.c:762-772)。

软链接是"带优先级的引用计数":每个链接名对应 `/run/udev/links/` 下一个栈目录,`stack_directory_update()` 放入/取回以设备 id 命名的 symlink(udev-node.c:198);`link_update()`(udev-node.c:396)比较候选设备的 devlink priority(`OPTIONS=link_priority=`,经 `stack_directory_find_prioritized_devnode()`,udev-node.c:128)决定属主;remove 时只在自己仍是属主时才改写链接,易主后保持不动(udev-node.c:425-490)。`/dev/block|char/<maj:min>` 索引链接恒定维护:`udev_node_update()` 恒建(udev-node.c:571),`udev_node_remove()` 恒删(udev-node.c:578-598)。

`/dev/disk/by-*` 家族(by-uuid/by-label/by-partuuid/by-id)是两条规则的接力:builtin **blkid** 探测超级块并导出 `ID_FS_TYPE/UUID/LABEL、ID_PART_TABLE_*、ID_PART_ENTRY_*` 等属性(udev-builtin-blkid.c:44-122),再由发行版规则中形如 `SYMLINK+="disk/by-uuid/$env{ID_FS_UUID}"` 的 DEVLINK token 落成链接(执行逻辑即 udev-rules.c:2962-3021);同名冲突最终交给上述优先级栈仲裁。持久命名属性 `ID_PATH` 则来自 **path_id** builtin(udev-builtin-path_id.c:892-897)。

## 7. builtin 命令:注册表与代表例

builtin 是编译进 udevd 的"伪 RUN 程序"。注册表是函数指针数组(udev-builtin.c:13-38),条目结构 `UdevBuiltin{name, cmd, init, exit, should_reload, run_once}`(udev-builtin.h:5-12)。`udev_builtin_lookup()` 按首单词查表(udev-builtin.c:91),`udev_builtin_run()` 切词后直接调用对应 `cmd`(udev-builtin.c:107),属性统一经 `udev_builtin_add_property()` 写入(udev-builtin.c:128),`udev_builtin_import_property()` 提供"从旧库继承"的捷径(udev-builtin.c:170)。成员:blkid、btrfs、dissect_image、factory_reset、hwdb、input_id、keyboard、kmod、net_driver、net_id、net_setup_link、path_id、tpm2_id、uaccess、usb_id(受 HAVE_* 裁剪)。

- **blkid**(udev-builtin-blkid.c:671-676,`run_once=true`):输出 `ID_FS_*`(udev-builtin-blkid.c:44-122)。
- **kmod**(udev-builtin-kmod.c:86-94):维护 libkmod 模块索引供 `MODALIAS` 加载;`should_reload` 检测模块配置变化(udev-builtin-kmod.c:70-77),reload 时按 `UDEV_RELOAD_KILL_WORKERS` 重启全部 worker(udev-manager.c:327),builtin 自身重载于 :329。
- **path_id**(udev-builtin-path_id.c:892-897,`run_once=true`):沿 sysfs 父链合成 `ID_PATH`(供 by-path 链接),兼容路径存 `ID_PATH_ATA_COMPAT`。
- **usb_id**(udev-builtin-usb_id.c:425-430):导出 `ID_USB_*` 与型号串。
- **net_id / net_setup_link**:见 §8。

`run_once=true` 的语义:同一事件内多处引用只执行一次,结果由 `event->builtin_run/builtin_ret` 位图缓存(udev-rules.c:2532-2541)。

## 8. 网络接口命名:net_id → link_config

命名分两段。第一段 **net_id** builtin(udev-builtin-net_id.c:1472-1477)只产属性不改名:按命名方案逐项门控(`naming_scheme_has()`),从 ACPI 板载索引、PCI slot/path、USB、BCMA、CCW、devicetree alias 等来源合成 `ID_NET_NAME_ONBOARD`(udev-builtin-net_id.c:319)、`ID_NET_NAME_PATH`(:696)、`ID_NET_NAME_SLOT`(:715/:763)等。

第二段 **net_setup_link** builtin(src/udev/udev-builtin-net_setup_link.c:19):`link_get_config()` 按 `OriginalName/Driver/Type` 匹配 `.link` 文件(src/udev/net/link-config.c:449),`link_apply_config()`(link-config.c:1766)依次应用 ethtool、rtnl、命名、SR-IOV、RPS、IRQ。命名核心 `link_generate_new_name()`(link-config.c:713):仅 `add` uevent 生效;`NamePolicy=` 依序尝试,策略值直接读 net_id 的属性(udev-builtin 产出的 `ID_NET_NAME_*`,link-config.c:761-774):

```c
/* src/udev/net/link-config.c:761-774(节选) */
case NAMEPOLICY_DATABASE:
        (void) sd_device_get_property_value(device, "ID_NET_NAME_FROM_DATABASE", &new_name);
        break;
case NAMEPOLICY_ONBOARD:
        (void) sd_device_get_property_value(device, "ID_NET_NAME_ONBOARD", &new_name);
        break;
case NAMEPOLICY_SLOT:
        (void) sd_device_get_property_value(device, "ID_NET_NAME_SLOT", &new_name);
        break;
case NAMEPOLICY_PATH:
        (void) sd_device_get_property_value(device, "ID_NET_NAME_PATH", &new_name);
        break;
```

`net.ifnames=0` 整体关闭策略(link-config.c:705-716);结果写 `ID_NET_NAME`(link-config.c:1757),`.link` 文件路径写 `ID_NET_LINK_FILE`(link-config.c:1744)。真正发 `rtnl_set_link_name()` 改名的是 worker 侧规则执行后段的 `rename_netif()`(udev-event.c:114):先把 `ID_RENAMING` 写进设备与 `dev_db_clone`(udev-event.c:171/:180)并落盘(udev-event.c:192),再发 RTM_NEWLINK,免得 networkd 收到半成品状态;接口已 UP 的 EBUSY 静默保留旧名;备选名走 `assign_altnames()`(udev-event.c:241)。`NAME=` token 的取值最终也存在 `event->name`,由该函数消费。

## 9. 与 PID 1 的关系(承接卷一)

PID 1 以 group=udev 的组播——即 worker 处理完成后的"已处理"事件(udev-worker.c:261)——为输入,在 `device_dispatch_io()`(src/core/device.c:1144,monitor 启动于 src/core/device.c:1054)中把设备出现/消失换算为 `.device` unit 的 `DEVICE_FOUND_UDEV` 位(src/core/device.c:1094-1102)并触发依赖 job;worker 失败标记 `UDEV_WORKER_FAILED` 在此被拒绝消费。"udev 事件 → unit 状态 → job" 的完整推演见卷一,不赘。

## 10. 控制接口:Varlink 取代私有协议

历史上 udevd 有专用 `/run/udev/control` socket 与 UPROTO 文本协议;本代已彻底换成 Varlink:服务地址 `"/run/udev/io.systemd.Udev"`(udev-varlink.c:16),server 在 manager 主循环启动(udev-varlink.c:180-227),绑定方法(udev-varlink.c:211-224):`io.systemd.service.Ping/Reload/SetLogLevel/GetLogLevel/GetEnvironment` 与 `io.systemd.Udev.SetTrace/SetChildrenMax/SetEnvironment/Revert/StartExecQueue/StopExecQueue/Exit`(实现如 `vl_method_reload()` 于 udev-varlink.c:20)。旧路径 `/run/udev/control` 以指向 Varlink socket 的**符号链接**保留,专供 `udevadm settle`、libudev 等作存活探测(udev-varlink.c:205-207)。

客户端:`udevadm control` 经 `udev_varlink_connect()`(udev-varlink.c:237)连接后逐条发调用(src/udev/udevadm-control.c:157-221)——`--exit`→`Udev.Exit`(:166)、`--log-level`→`service.SetLogLevel`(:175)、`--start/stop-exec-queue`→`Udev.Start/StopExecQueue`(:182)、`--reload`→`service.Reload`(:189)、`--children-max`→`Udev.SetChildrenMax`(:202)。`udevadm monitor` 自建 monitor,选 `MONITOR_GROUP_KERNEL`(原始 uevent)或 `MONITOR_GROUP_UDEV`(处理后事件)(src/udev/udevadm-monitor.c:39-48/:72);`udevadm info` 绕过 daemon,直接读 sysfs 与 `/run/udev/data` 打印设备记录(`print_record()`,src/udev/udevadm-info.c:330)。

## 11. 配置面、inotify watch 与可观测性(补充)

**配置来源**`udev.conf` 与内核命令行(udev-config.c:44-48 定义键 `children_max/exec_delay/event_timeout/timeout_signal`;udev-config.c:58-60 有逐条注释;`udev.*=` 命令行解析在 udev-config.c:79-108),运行时经 Varlink `SetChildrenMax/SetLogLevel` 热改。

**inotify watch**(`OPTIONS=watch`):worker 无权持有全寿命 inotify fd,请求经 notify socket 转交 manager:`udev_watch_begin()`(src/udev/udev-watch.c:669)→ `notify_and_wait_signal()`(udev-watch.c:643,等 manager 的 SIGUSR1 应答)→ `manager_add_watch()` 在 `/run/udev/watch` 建索引并对节点 `inotify_add_watch(IN_CLOSE_WRITE)`(udev-watch.c:572)。节点被绕过 udev 直接写入时,`on_inotify()`(udev-watch.c:299)合成 change 事件重跑规则——`udevadm trigger` 之外的"自愈"通道。

**可观测性**:trace 点贯穿管线——`kernel_uevent_received`(udev-manager.c:1052)、`worker_spawned`(udev-worker.c:319)、`rules_start/rules_finished`(udev-event.c:401/:407);`OPTIONS=dump` 可在事件中途转储 UdevEvent 全状态(udev-rules.c:2640);`OPTIONS=log_level=debug` 运行时提级(udev-rules.c:2688-2689);离线侧有 `udevadm test / verify / test-builtin` 复用同一套规则解析与执行代码(`EVENT_MODE_DESTRUCTIVE` 门控破坏性操作,udev-event.h:53-55)。

**合成事件**:`udevadm trigger` 向内核写 uevent 属性触发真实 kobject 事件,并打印合成 UUID(udevadm-trigger.c:458);manager 入队时凭该 UUID 识别自己引燃的事件(udev-manager.c:868-869)。另有一类"内部合成":inotify 检测到节点被绕过 udev 写入时,manager fork 子进程向内核发 change(其存活期以 `synthesize_change_child_event_sources` 集合跟踪,退出钩子 udev-manager.c:170、队列文件清理判断 udev-manager.c:1256)——这类事件与普通 uevent 走完全相同的队列与状态机。

**规则内自省**:匹配侧除属性/环境外还有 `TEST`(udev-rules.c:2345)与 `PROGRAM`(udev-rules.c:2387,结果存 `event->program_result` 供 `RESULT==` 与 `%c` 消费,udev-rules.c:2411/:2637)两条重匹配路径;CONST token 提供 `arch/virt/cvm` 三种内建常量匹配(udev-rules.c:2287-2291)。

## 设计动机

1. **worker 池而非单线程顺序执行**:单事件可能含外部程序与磁盘 IO,串行会拖垮全部设备;进程池把慢事件隔离在独立地址空间(udev-manager.c:574-606),`children_max` 又把并发限在 `min(2*CPU+16, RAM/128MiB)`(udev-config.c:283-299)。选 fork 而非线程,还使"超时 SIGKILL"(udev-manager.c:353)成为可靠回收——卡死的只是子进程,rules/属性副本天然隔离。
2. **同设备(及父子设备)事件串行**:并发 add/remove/change 会交错改写 devlink、db 与 sysfs;`event_find_blocker()` 用 devpath 前缀包含把可能冲突的事件排成全序(udev-manager.c:611-660),只牺牲同一设备链内的并行,不同磁盘照常并发。
3. **rules 编译成 token 而非逐行解释**:解析期完成词法、GOTO 绑定(udev-rules.c:1789)与 `LINE_HAS_*` 位标注(udev-rules.c:171-183),执行期用位运算整行跳过(位定义 udev-rules.c:3239,整行跳过判断 :3260)、NULSTR+fnmatch 快速匹配(udev-rules.c:1934-1969);一次解析、每事件数千次复用,且 `udevadm verify` 能离线复用同一解析器。
4. **builtin 而非外部进程**:blkid/kmod/path_id 等高频探测若 fork+exec,每事件付出进程创建与动态链接成本,属性只能靠 stdout 文本回传;builtin 直接函数调用、结构化写属性(udev-builtin.c:107-155),`run_once` 位图去重(udev-rules.c:2532-2541);兼容层让旧 `IMPORT{program}` 自动降级为内置调用(udev-rules.c:1010-1015)。
5. **设备事件与数据库的序列化**:单库写入用"临时文件+rename"原子替换(device-private.c:865-931),`ID_PROCESSING` 显式化"规则已完、RUN 未完"窗口(udev-event.c:357-362 与 udev-worker.c:249-253);跨事件则靠 blocker 串行化保证同设备写者唯一(udev-manager.c:624)。没有这两层,`IMPORT{db}` 读到的将是任意中间态。
6. **整盘 flock 作为跨界互斥**:rules/RUN 只约束 udev 自己,mkfs/mount 等外部工具与 udevd 抢同一块盘;`LOCK_SH` 让 udev 主动让路(udev-worker.c:118-126)或让外部进程阻塞等待(udev-worker.c:199-206),把"udev 正在处理此盘"变成进程间可见的所有权语义,让路期间由 manager 的 LOCKED 队列(udev-manager.c:804-856)负责重试。

## 写作素材清单(文件:行号,均已核对)

1. `src/udev/udevd.c:28` — `run_udevd()` 薄入口;`:56` 建 /run/udev;`:61-65` 预载动态库;`:90` `manager_main()`。
2. `src/udev/udev-manager.c:1048` — `on_uevent()` 事件入口;`:857` `event_queue_insert()`(SEQNUM 排序 :902-917);`:1238` /run/udev/queue。
3. `src/udev/udev-manager.c:574` — `event_run()` 空闲 worker 单播派发(:584);`:509` `worker_spawn()`(fork :530,cgroup :545-548)。
4. `src/udev/udev-manager.c:373` — `worker_attach_event()` 双定时器(:391/:403);`:353` 超时杀 worker;`:428` `on_worker_exit()`。
5. `src/udev/udev-manager.c:624` — `event_find_blocker()` 同/父子串行化;`:611` `devpath_conflict()`;`:708-718` 派发主循环。
6. `src/udev/udev-manager.h:82-85` — Event 四状态;`udev-manager.c:804/:853` LOCKED 与磁盘锁重试(:48-49);`:1122` `on_worker_notify()`。
7. `src/udev/udev-worker.c:194` — `worker_process_device()` 全管线;`:86/:118` 整盘 flock;`:249-253` db 终写;`:261/:268` 广播与 PROCESSED。
8. `src/udev/udev-event.c:372` — `udev_event_execute_rules()` 主序;`:389` dev_db_clone;`:410` 改名;`:273/:306/:310` 节点与链接。
9. `src/udev/udev-rules.c:111-169` — token 枚举;`:760` `parse_token()`;`:3293` `udev_rules_apply_to_event()`;`:3239/:3260` 行级预筛。
10. `src/udev/udev-rules.c:1822` — `udev_rules_load()`;`:1848` 字典序合并;`:60` RULES_DIRS;`:1934` `token_match_string()`。
11. `src/libsystemd/sd-device/device-private.c:865` — `device_update_db()` 与 S/L/I/E/G/Q/V 格式(:905-925);`:832` 库路径;`:811` `device_should_have_db()`。
12. `src/udev/udev-node.c:396` — `link_update()` 优先级栈仲裁;`:533/:578` 链接增删;`:699/:636` 权限应用。
13. `src/udev/udev-builtin.c:13-38` — builtin 注册表;`:91/:107/:128` lookup/run/add_property;`udev-builtin-blkid.c:44-122` ID_FS_*。
14. `src/udev/net/link-config.c:713` — `link_generate_new_name()`;`:761-774` NamePolicy 读 net_id 属性;`:1744/:1757` ID_NET_LINK_FILE/ID_NET_NAME。
15. `src/udev/udev-varlink.c:16/:180-227` — Varlink 控制面与方法表;`:205` control 兼容符号链接;`src/udev/udevadm-control.c:157-221` 客户端。
16. `src/core/device.c:1144` — `device_dispatch_io()`:udev 事件→.device unit(承接卷一);`:1054` monitor 启动。
