# 报告 A3 · nspawn 容器运行器(systemd 卷三)

> 基线:1f66b524("nspawn: align config `PrivateUsersOwnership` default with CLI")。一句话:systemd-nspawn 用"父进程(监督者)+ 外层子进程(挂载搭建)+ 内层子进程(容器 PID 1)"三层进程模型,在两层各自归属不同 user namespace 的 mount namespace 里搭出 /proc、/sys、/dev、/run 等 API VFS 与镜像根,再以 barrier 五步握手、veth/veth-extra、allow-list seccomp、Varlink 优先的 machined 注册和 PTY 中继,把一棵 OS 树变成受宿主 systemd 管理的"机器"。

文件基线:`src/nspawn/` 共 22 个文件,核心 nspawn.c 6777 行、nspawn-mount.c 1515 行、nspawn-network.c 1057 行、nspawn-oci.c 2138 行(行数 wc -l 实测)。以下 `nspawn.c:NNNN` 均指 `src/nspawn/` 下文件。

## 1. main 流程:参数解析 → 镜像发现 → 三层 fork

入口 `run()`(nspawn.c:6082):`parse_argv`(548)手工解析选项;`--cleanup` 直接清理传播目录后返回(6107);检测到 cgroup v1 直接拒绝(6125-6132);`cant_be_in_netns()` 要求 `--image=` 必须处于初始 netns 且有 udev,否则挂 loop 设备会挂死(6015-6043)。随后按序:`load_oci_bundle`(6142)、`pick_paths`(6146)、`determine_names`(6150)、`load_settings`(6154)。

镜像/目录发现(`determine_names`,nspawn.c:3051):只给 `--machine=` 时经 `image_find` 找到 RAW/BLOCK 镜像或 DIRECTORY/SUBVOLUME/MSTACK 目录(3068-3092);一个都没有则退化为当前目录(3099)。目录树若就是宿主根 `/` 且非 ephemeral/volatile,直接拒绝(6265-6269)。`--image=` 路径走 `loop_device_make_by_path` + `dissect_loop_device`(GPT/MBR/verity 解剖,6485-6516),verity 签名分区与 roothash 随后补齐(6518-6533);启动 boot 模式前还要求镜像里有 os-release(`path_is_os_tree`,6366-6373),非 boot 只要求有 /usr/(6386-6393)。--image 前还要通过镜像锁 `image_path_lock` 排他/共享锁防双开(6298-6311,6429-6470),只读运行取共享锁、可写取排他锁。

USER_NAMESPACE_MANAGED 是本 commit 的无特权主线:先连 nsresourced 与 mountfsd 两个 Varlink 服务,再申请一个 64K UID 的 user namespace:

```c
// nspawn.c:6239-6255
userns_fd = nsresource_allocate_userns_full(
                nsresource_link,
                userns_name,
                NSRESOURCE_UIDS_64K,
                arg_delegate_container_ranges);
...
r = userns_get_base_uid(userns_fd, &arg_uid_shift, /* ret_gid= */ NULL);
...
arg_uid_range = NSRESOURCE_UIDS_64K;
```

managed 模式下目录挂载走 `mountfsd_mount_directory`(6397-6407)、镜像挂载走 `mountfsd_mount_image`(6548-6560),由特权服务在自己名字空间里完成 loop/挂载后把 mount fd 递回来。注意 managed 模式强制要求 `--private-network`(verify_arguments,nspawn.c:1480-1481),因为容器内要挂自己的 sysfs。

真正的进程模型是两层 fork 三类进程(nspawn.c:3333-3342 注释明说):

```c
// nspawn.c:5340-5355(run_container)
bool in_child;
if (arg_userns_mode != USER_NAMESPACE_MANAGED) {
        assert(userns_fd < 0);
        /* If we have no user namespace then we'll clone and create a
         * new mount namespace right-away. */
        pid_t _pid = raw_clone(SIGCHLD|CLONE_NEWNS);
        ...
        in_child = _pid == 0;
}
```

- **外层子进程(outer child)**:只带 `CLONE_NEWNS`(5344);managed userns 模式改为先 `setns(userns_fd)` 再 `unshare(CLONE_NEWNS)`(5361-5388),使外层 mntns 归属预分配的 user namespace。
- **内层子进程(inner child)**:由外层再 fork,flags 为 `SIGCHLD|CLONE_NEWNS|arg_clone_ns_flags|CLONE_NEWUSER?|CLONE_NEWNET?`(4426-4429);`arg_clone_ns_flags` 默认 `CLONE_NEWIPC|CLONE_NEWPID|CLONE_NEWUTS`(238),可被 `SYSTEMD_NSPAWN_SHARE_NS_*` 环境变量削减(494-503)。
- **父进程**:经 socketpair 依次收回外层 mntns fd(5425)、UID shift(5430)、内层 PID(5463)、容器 UUID(5474)、notify socket(5481),之后装好网络、cgroup、scope、注册,进入 sd-event 循环当监督者(5878)。父子间用 Barrier 同步,握手点编号 #1..#5 贯穿两个子进程(5489、5504、5711、5746、5758;内层侧 3351、3354、3393、3403、3623)。

## 2. outer_child:挂载命名空间里的文件系统搭建

外层子进程的搭设顺序(nspawn.c:3902-3914 注释给出当时的 namespace 状态表):`PR_SET_PDEATHSIG`(3927)→ 清 audit loginuid(3931)→ 根树 `MS_SLAVE|MS_REC`(3937,只收宿主传播不再外传)→ 挂根。挂根有四条路径:mountfsd 给的 `mount_fd` 用 `move_mount` 直接装(3949);dissected image 先 `MOUNT_ROOT_ONLY` 挂根分区以便读 UID shift(3965-3973);`.mstack` 分层栈做 overlay/tmpfs 再 bind(3988-4003);普通目录 `MS_BIND|MS_REC`(4009)。随后 `setup_pivot_root`(4078)、`setup_volatile_mode`(4085)、`mount_custom(MOUNT_ROOT_ONLY)`(4131)、可选 `remount_idmap` 用内核 idmapped mounts 免去递归 chown,失败且为 auto 时回退 chown(4148-4215)、`recursive_chown`(4242)、`base_filesystem_create`(4246)、`copy_devnodes`(4264)、`setup_pts`(4292)。

API VFS 挂载表是整个 nspawn 安全模型的核心(nspawn-mount.c:557-627,由 `mount_all` 按掩码过滤执行):

```c
// nspawn-mount.c:559-569(mount_table 节选)
{ "proc",            "/proc",           "proc",  NULL,  PROC_DEFAULT_MOUNT_FLAGS,
  MOUNT_FATAL|MOUNT_IN_USERNS|MOUNT_MKDIR|MOUNT_FOLLOW_SYMLINKS },
{ "/proc/sys",       "/proc/sys",       NULL,    NULL,  MS_BIND,
  MOUNT_FATAL|MOUNT_IN_USERNS|MOUNT_APPLY_APIVFS_RO },   /* Bind mount first ... */
{ "/proc/sys/net",   "/proc/sys/net",   NULL,    NULL,  MS_BIND,
  MOUNT_FATAL|...|MOUNT_APPLY_APIVFS_NETNS },            /* (except for this) */
{ NULL,              "/proc/sys",       NULL,    NULL,  MS_BIND|MS_RDONLY|...|MS_REMOUNT,
  MOUNT_FATAL|...|MOUNT_APPLY_APIVFS_RO },               /* ... then, make it r/o */
```

同表还有:tmpfs 挂 /tmp、/sys、/dev、/dev/shm、/run(593-606);宿主 os-release bind 到 /run/host/os-release 并转只读(609-616);/proc/kallsyms、kcore、keys、sysrq-trigger、timer_list 变 inaccessible 节点,acpi/asound/bus/irq/scsi 等转只读(573-587)。`mount_all` 会被调用两次:外层在进 userns 前执行 `MOUNT_IN_USERNS` 之外的条目(nspawn.c:4257),内层执行 `MOUNT_IN_USERNS` 条目(3370)。

自定义挂载支持 bind/overlay/tmpfs/inaccessible/arbitrary 五类;overlay 由 `mount_overlay` 按 `--overlay=/:PATH` 的只读与否拼两种选项串(nspawn-mount.c:960-1000):

```c
// nspawn-mount.c:987-999
if (m->read_only)
        options = strjoina("lowerdir=", escaped_source, ":", lower);
else {
        ...
        options = strjoina("lowerdir=", lower, ",upperdir=",
                           escaped_source, ",workdir=", escaped_work_dir);
}
return mount_nofollow_verbose(LOG_ERR, "overlay", where, "overlay",
                              m->read_only ? MS_RDONLY : 0, options);
```

为让宿主能在运行中向容器注入挂载,外层挖"mount tunnel":宿主 `/run/systemd/nspawn/propagate/<machine>` 以只读 bind 挂进容器 `NSPAWN_MOUNT_TUNNEL`(nspawn.c:2706-2742),根切过去后将其置 `MS_SLAVE`(2745-2757);managed userns 模式无此隧道(2709-2712)。非特权场景还有一个"先钉住全可见 proc/sys 再由父进程擦除"的戏法:`pin_fully_visible_api_fs` 在 /run/host/proc、/run/host/sys 挂临时 procfs/sysfs(nspawn-mount.c:1461-1478),内层就绪后父进程 `wipe_fully_visible_api_fs` 跨 mntns 摘掉(nspawn-mount.c:1496-1515,nspawn.c:5749-5754)。

## 3. 内层子进程:从 unshare 到 exec

内层子进程按序(nspawn.c:3304 起):userns 模式下 barrier #1/#2 等 UID map 写入后 `reset_uid_gid` 成为新 namespace 的 root(3349-3360);执行内层 `mount_all`(3370);需要私有网络时 `unshare(CLONE_NEWNET)` 并把新 netns fd 发回父进程(3377-3394);`mount_sysfs`(3397);barrier #4 等 cgroup 就绪(3402-3405);有 cgns 支持则 `unshare(CLONE_NEWCGROUP)` + 挂 cgroupfs,否则 bind 自身 cgroup 层级(3407-3416);`setup_boot_id`、`setup_kmsg`(3418-3424);非根 custom mounts(3426);`setsid`(3437);分配 pty 并绑为 /dev/console(3449-3468);`patch_sysctl`(3471)、hostname(3485)、personality/rlimit(3487-3504)。

安全收尾集中在 exec 之前(seccomp 过滤器装配、能力五元组、UID/GID 切换):

```c
// nspawn.c:3506-3522
#if HAVE_SECCOMP
        if (arg_seccomp) {                      /* OCI 提供的过滤器直接装 */
                ...
                r = sym_seccomp_load(arg_seccomp);
        } else
#endif
        {
                r = setup_seccomp(arg_caps_retain, arg_syscall_allow_list,
                                  arg_syscall_deny_list, arg_restrict_address_families, ...);
        }
```

之后 `PR_SET_KEEPCAPS`(3542)、`change_uid_gid`(3546-3551)、`drop_capabilities`(3553,五元组 bounding/effective/inheritable/permitted/ambient 全由 `arg_caps_retain`/`arg_caps_ambient` 推导,nspawn.c:2629-2675)、可选 NoNewPrivileges(3557-3561)。环境变量手工拼装:`container=systemd-nspawn`(3564)、`container_uuid`(3589)、`LISTEN_FDS`(3597)、`NOTIFY_SOCKET`(3601)、`CREDENTIALS_DIRECTORY=/run/host/credentials`(3605)。barrier #5(3623)之后,`--as-pid2` 先跑 `stub_pid1`(3633-3637),再 `TIOCSCTTY` 抢控制终端(3639-3644);最后按 start mode exec:boot 模式依序尝试 `/usr/lib/systemd/systemd`、`/lib/systemd/systemd`、`/sbin/init`(3668-3674);默认模式(START_PID1)把用户参数直接 execve 成容器 PID 1,无参数则落到用户 shell(3691-3703)。

## 4. 权限与安全:userns、seccomp 与能力

user namespace 有四种模式(nspawn.c:329 `parse_private_users`):off/fixed/pick/managed。fixed/pick 由父进程在内层启动后写 `/proc/<pid>/uid_map`(`setup_uid_map`,5493,写前有 barrier #1 同步);managed 模式改向 nsresourced 服务申请 64K UID 的 userns fd 并由 mountfsd 代为挂载镜像(6218-6256),此后 cgroup 委托也走 `nsresource_add_cgroup`(nspawn-cgroup.c:111-116)。UID 归属策略 `--private-users-ownership=` 支持 map/foreign/auto/chown,auto 在内核不支持 idmapped mounts 时静默回退 chown(4157-4210)——这正是基线 commit 标题所修的配置默认对齐点(verify_arguments 内默认值推导,nspawn.c:1493-1495)。能力保留集 `arg_caps_retain` 由 `--capability=`/`--drop-capability=` 经 `parse_capability_spec` 归并(nspawn.c:409-448);两处自动削减值得注意:共享宿主网络且启用 userns 时收回 CAP_NET_BIND_SERVICE(6164-6168),boot 模式禁用 ambient 能力(1568-1570)。

seccomp 是"总白名单 + 能力门槛"模型(nspawn-seccomp.c:15-133):`@aio`、`@file-system`、`@process` 等 16 组系统调用组无条件放行;`@clock`/`@module`/`@raw-io`/`@memlock` 及 acct/ptrace/reboot/syslog/vhangup/bpf 仅当对应 capability 在保留集才放行(138-150)。默认动作 `SCMP_ACT_ERRNO(ENOSYS)`,而 `@known` 中未放行的调用显式 `SCMP_ACT_ERRNO(EPERM)`(159-161,198);大过滤器开启 libseccomp 二叉树优化(166-171)。另有第二个独立过滤器把 `socket(AF_NETLINK, *, NETLINK_AUDIT)` 改写为 `EAFNOSUPPORT`,让容器内 audit 用户态认为"内核没开 audit"(223-241)。地址族限制(未来默认只放行 inet/inet6/unix,警告见 nspawn.c:6158-6162)与 `--suppress-sync=` 追加在最后(nspawn-seccomp.c:251-255,nspawn.c:3524-3532)。

网络侧:`--network-veth` 隐含 `--private-network`(nspawn.c:956-961)。流程是内层 unshare 后把 netns fd 发回父进程(3384-3390),父进程 barrier #3 同步后用它保活 netns 并 `move_network_interfaces` 搬入 `--network-interface=` 指定的物理口(5501-5517);随后 `setup_veth` 一次 RTM_NEWLINK 同时创建 veth 两端,peer 用 `IFLA_NET_NS_PID` 直接落进容器进程(nspawn-network.c:108-158):宿主侧命名 `vb-`/`ve-` + 机器名(是否接桥决定前缀,184),容器侧固定 `host0`(204),两侧 MAC 由机器名哈希稳定生成(190-198)。接桥 `setup_bridge`(5550-5564),另有 `--network-veth-extra`、macvlan、ipvlan(5567-5583)。managed userns 模式改走 `nsresource_add_netif_veth` 让 nsresourced 代建(5527-5548)。

`--port=` 端口暴露是完整的"监听-翻译-下发"闭环:内层先把自己的容器 rtnl socket 发给父进程(`expose_port_send_rtnl`,nspawn-expose-ports.c:163-177),父进程订阅 RTM_NEWADDR/RTM_DELADDR(nspawn-expose-ports.c:182-211);地址变化时 `expose_port_execute` 用 `local_addresses` 取容器第一个非 link 域地址,对每个端口调 `fw_nftables_add_local_dnat` 写 DNAT 规则(nspawn-expose-ports.c:111-149),nftables 句柄来自 `sd_nfnl_socket_open`(nspawn.c:6651-6657);容器退出或地址消失时 `expose_port_flush` 撤销(nspawn-expose-ports.c:79 起,nspawn.c:6757-6758)。`--port=` 解析支持 `tcp:/udp:` 前缀与 `host:container` 双端口写法,host 口重复即报 EEXIST(nspawn-expose-ports.c:17-72)。

## 5. 控制台与终端:pty 中继

交互模式由内层子进程分配 pty(`openpt_allocate`,3454),以 bind 挂为容器 /dev/console(3458),master fd 经 socketpair 交给父进程(3462),自己把 stdio 接上并稍后 `TIOCSCTTY`(3466,3642)。父进程在事件循环里 `pty_forward_new` 双向中继(5828-5844),支持窗口尺寸、背景着色(terminal 220 蓝调,5852-5861)、窗口标题(5863)与 OSC 8 容器上下文标注(5816-5821)。默认模式判定:stdin/stdout 都是 tty → interactive,否则 read-only(6202-6204)。热键协议:Ctrl-] 三下 1 秒内杀容器,两下 + `r` 重启(SIGRTMIN+5)、+ `p` 关机(SIGRTMIN+4)(提示文案 6637-6640,实现 `ptyfwd_hotkey` 4727-4757)。终端托管在事件循环,SIGINT/SIGTERM 默认发 `arg_kill_signal` 给容器 PID 1(`on_orderly_shutdown`,2908-2926);boot 模式下 kill-signal 默认就是 systemd 约定的 SIGRTMIN+3(1497-1498)。

## 6. 宿主状态同步:timezone、resolv.conf、machine-id、journal

外层子进程在挂载阶段还会把宿主的几样"环境状态"投影进容器,策略全部带 AUTO 模式(nspawn.c:4323-4337 的调用序列)。时区:读宿主 `/etc/localtime`,按"是否符号链接、/etc 是否可写"在 delete/copy/symlink/bind 四种动作中选择,已经是正确符号链接则跳过(nspawn.c:1729-1785)。DNS 的 AUTO 决策链如下:

```c
// nspawn.c:1897-1905(setup_resolv_conf)
if (arg_resolv_conf == RESOLV_CONF_AUTO) {
        if (arg_private_network)
                m = RESOLV_CONF_OFF;
        else if (have_resolv_conf(PRIVATE_STUB_RESOLV_CONF) > 0 && resolved_listening() > 0)
                m = etc_writable() ? RESOLV_CONF_COPY_STUB : RESOLV_CONF_BIND_STUB;
        else if (have_resolv_conf("/etc/resolv.conf") > 0)
                m = etc_writable() ? RESOLV_CONF_COPY_HOST : RESOLV_CONF_BIND_HOST;
        else
                m = etc_writable() ? RESOLV_CONF_DELETE : RESOLV_CONF_OFF;
```

`resolved_listening` 经系统总线查 `org.freedesktop.resolve1` 的 `DNSStubListener` 属性是否为 udp/yes(nspawn.c:1864-1887);bind 一律追加 MS_RDONLY|MS_NOSUID|MS_NODEV remount(1950-1952)。machine-id:容器里已有非空 /etc/machine-id 就尊重之;否则若 `--uuid=` 指定,把 UUID 写成不带换行的 32 字符文本放进 /etc/machine-id(nspawn.c:2760-2782)。journal:`setup_journal` 以容器 UUID 在宿主 /var/log/journal/<uuid> 与容器内路径之间做 bind 或 symlink 联动,宿主与容器 machine-id 相同时拒绝以防互写;`--ephemeral` 一律跳过(2486-2511,2492-2494)。

另外外层还向容器 /run/host 写入自述文件:container-manager(即 `systemd-nspawn`)与 container-uuid,权限 0444(nspawn.c:4347-4361),并预置 `io.systemd.NamespaceResource`、`io.systemd.MountFileSystem` 两个 varlink 代理 socket(4339-4345),让容器内代码可以反向联络宿主服务。内层 exec 前的环境变量与这些文件共同构成 `$container` 语义的双通道。

## 7. 注册与生命周期:machined、scope、cgroup、重启

容器内层 PID 就绪后,父进程:匹配 systemd 的 `RequestStop` 信号(5637-5646);若无 `--keep-unit` 则 `allocate_scope` 调 `StartTransientUnit` 建带 `Delegate=1` 的 scope,属性里固定 `DevicePolicy=closed` + DeviceAllow(tun/char-pts/fuse)、`Slice=machine.slice`、Controller(nspawn-register.c:32-46,185-194);`arg_register != 0` 时向 machined 注册(nspawn.c:5671-5693)。注册路径是 Varlink 优先:`io.systemd.Machine.Register`(shared/machine-register.c:175-192),连不上才回退 D-Bus `RegisterMachineWithNetwork`(120-134);默认 `arg_register=-1` 时失败仅告警(graceful,5687-5691)。

cgroup 归置由 `create_subcgroup` 完成,注释说明了两层动机:统一层级内节点不能挂进程,以及"宿主 systemd 与容器 systemd 会争抢同一 cgroup 的属性"(nspawn-cgroup.c:63-71)。做法是在 scope 下建 `payload` 子组给容器进程、`--keep-unit` 时再建 `supervisor` 子组给 nspawn 自己(89-137);非 managed 模式把 `cgroup.procs`、`cgroup.subtree_control`、`memory.oom.group` 等九个控制文件 chown 给容器 root(22-46);managed 模式改走 `cg_fd_attach` + `nsresource_add_cgroup` 委托(100-116)。容器内一侧:有 cgroup namespace 支持时内层 `unshare(CLONE_NEWCGROUP)` 后直接挂统一层级(3407-3412);否则 `bind_mount_cgroup_hierarchy` 把自身 cgroup bind 成可写、整个 /sys/fs/cgroup 转只读(nspawn-cgroup.c:172-196)。最后 `sd_notify READY=1`(5768-5772)。

重启语义:容器 init 死于 SIGHUP → `wait_for_container` 判 `CONTAINER_REBOOTED`(2891-2894),`run_container` 返回 1,外层 `for(;;)` 循环整个重来一遍(veth 重建、注册重做;5921-5939,6712-6727);`--keep-unit`(即 systemd-nspawn@.service)时改为退出码 133,借单元的 `RestartForceExitStatus=133` 让整个服务重启以清空 cgroup 属性(5923-5931)。journal 联动 `--forward-journal=` 会 fork 一个 systemd-journal-remote 子进程,并把其 socket 只读 bind 进容器 + 写入凭证 `journal.forward_to_socket`(6660-6709),且禁止与 `--set-credential=` 重复设置同一凭证(6701-6705)。退出清理路径集中在外层 finish 标签:杀残留进程、排空 pty、撤 nftables 规则、删 veth/网桥(managed 模式除外,6760-6764)、释放 custom mounts 与 rlimit(6729-6769)。

## 8. 集成模式与 stub PID 1

三种 start mode(nspawn-settings.h:18-20):默认 `START_PID1`——用户命令就是容器 PID 1(nspawn.c:170);`--as-pid2`(`START_PID2`)先起 stub 占住 PID 1;`--boot`(`START_BOOT`)直接 exec 容器自己的 init。boot 模式还有一处"仿内核"细节:`split_boot_parameters` 把位置参数里不含点的 `KEY=VALUE`(连字符转下划线)转成容器环境变量,其余保留为 init 参数,完全模拟内核传命令行的规则(nspawn.c:1595-1630);`--notify-ready=yes` 则让父进程等容器 init 自己发 sd_notify READY 才对外报告就绪(803-807)。`stub_pid1`(nspawn-stub-pid1.c:37-202)fork 出真正的 payload(64-72,子进程 setsid 后返回),自己留下收尸:阻塞全部信号、`close_all_fds`、`TIOCNOTTY`(74-84),用 `PR_SET_MM_ENV_START/END` 把 /proc/1/environ 重写为仅含 `container=systemd-nspawn` 与 `container_uuid=...`(50-90),进程名改 `(sd-stubinit)`(92)。

```c
// nspawn-stub-pid1.c:170-183(信号→状态机)
if (si.si_signo == SIGRTMIN+3 || si.si_signo == SIGRTMIN+4 ||
    si.si_signo == SIGRTMIN+13 || si.si_signo == SIGRTMIN+14)
        state = STATE_POWEROFF;
else if (si.si_signo == SIGINT || si.si_signo == SIGRTMIN+5 ||
         si.si_signo == SIGRTMIN+6 || si.si_signo == SIGRTMIN+15 ||
         si.si_signo == SIGRTMIN+16)
        state = STATE_REBOOT;
...
r = kill_and_sigcont(pid, SIGTERM);
if (r != -ESRCH)
        (void) kill(pid, SIGHUP);
quit_usec = now(CLOCK_MONOTONIC) + DEFAULT_TIMEOUT_USEC;
```

stub 模拟 sysv/systemd 关机协议:poweroff/reboot 信号先给 payload 发 SIGTERM(再补 SIGHUP 兼容忽略 SIGTERM 的 shell),超时后若处于 REBOOT/POWEROFF 状态就亲自 `reboot(RB_AUTOBOOT/RB_POWER_OFF)`(124-134),payload 退出码透传给 nspawn(136-139)。`--ephemeral`:目录型用 `create_ephemeral_snapshot` 做 btrfs 快照(无 btrfs 则整树拷贝,nspawn.c:6271-6292),镜像型整文件 `copy_file` 后挂载并顺手删掉临时文件(6419-6455,6563-6565),退出时快照目录由 `rm_rf_subvolume` 清理(6091);`--template=` 则从模板子卷生成目标目录(6313-6341)。`.nspawn` 配置按 /etc → /run(信任)→ 镜像/目录旁(默认不信任)顺序查找,命令行选项经 `SETTING_*` 位掩码压制(nspawn.c:5135-5207,merge_settings 4759),键值表见 nspawn-gperf.gperf:22-86(Exec./Files./Network. 三节)。

### 纠偏(以本 commit 源码为准)

1. **没有 nspawn-patch-hostname.c**:本 commit 文件清单(ls 实测)无此文件;hostname 由内层 `setup_hostname()` 直接 `sethostname_idempotent`(nspawn.c:2473-2484),内核参数伪造由 `patch_sysctl()` 完成(3241-3260)。旧版独立文件已被吸收进 nspawn.c。
2. **"nspawn 总是建 netns"不成立**:clone 默认 flags 只有 `CLONE_NEWIPC|CLONE_NEWPID|CLONE_NEWUTS`(238);`CLONE_NEWNET` 是内层在 `--private-network` 时单独 `unshare`(3381),且新 netns fd 要回传父进程保活(5507-5512)。
3. **"machined 注册走 D-Bus RegisterMachine"过时**:本 commit Varlink `io.systemd.Machine.Register` 优先,D-Bus 只是回退,且 D-Bus 路径用的是带 ifindex 的 `RegisterMachineWithNetwork`(machine-register.c:120-169);默认失败不致命(graceful),共享 PID/UTS namespace 时注册被直接关闭(nspawn.c:1486-1491)。
4. **"seccomp 默认拒绝动作是 EPERM"不准确**:默认动作是 ENOSYS(只作用于 @known 之外),EPERM 只给 @known 内未放行者(nspawn-seccomp.c:159-161,198)。
5. **veth 命名易说反**:容器侧固定 `host0`,宿主侧才是 `ve-`/`vb-`+机器名(nspawn-network.c:184,204)。
6. **`--port=` 不用 iptables**:走 nftables netlink(`sd_nfnl_socket_open`,nspawn.c:6651-6657)。
7. **默认不是 boot**:无 `-b` 时用户参数直接作为容器 PID 1(START_PID1,nspawn.c:170,3677-3690);stub 只属于 `--as-pid2`。

### 启动全景图(以 `--network-veth --boot`、非 managed 为例)

```text
nspawn (父, 监督者, subreaper: make_reaper_process 6645)
│  ns: 宿主全部; 持有: 外层mntns fd, 容器netns fd, pty master, notify socket
│  事件循环: pty中继/RequestStop/信号/expose-port rtnl (5878)
│
├─ outer child  raw_clone(SIGCHLD|CLONE_NEWNS)         nspawn.c:5344
│  │  ns: NEWNS(host属主) + PDEATHSIG
│  │  MS_SLAVE / → 树 MS_PRIVATE (3937,4074)
│  │  挂根: move_mount|dissect-image|mstack|bind (3944-4012)
│  │  pivot-root/volatile/idmap/chown/devnodes/pts (4078-4292)
│  │  mount tunnel: /run/systemd/nspawn/propagate/<m> → 容器 (4296)
│  │  mount_all(外层条目): tmpfs /tmp,/dev,/run,/sys + /run/host (4257)
│  │  mount_switch_root(container, MS_SHARED) (4388)
│  │  pin_fully_visible_api_fs: /run/host/{proc,sys} (4408)
│  │
│  └─ inner child  raw_clone(SIGCHLD|NEWNS|IPC|PID|UTS)  nspawn.c:4426
│     │  ns: +NEWPID +NEWIPC +NEWUTS (+NEWUSER 固定/pick; +NEWNET 由内层 unshare 3381)
│     │  mount_all(内层条目): procfs /proc, bind+ro /proc/sys(放行 /proc/sys/net) (3370)
│     │  cgns? unshare(CLONE_NEWCGROUP)+cgroupfs : bind cgroup (3407-3414)
│     │  boot-id/kmsg/custom-mounts/pty→/dev/console (3418-3468)
│     │  seccomp(allow-list) → caps → uid/gid → execve 容器 init (3506-3674)
│     └─ (容器 PID 1: systemd)  ← barrier #1..#5 与父同步 (3351,3354,3393,3403,3623)
│
├─ veth: RTM_NEWLINK, host: vb-<m>, peer host0 → IFLA_NET_NS_PID (nspawn-network.c:140,184,204)
├─ bridge: vb-* 加入 --network-bridge/--network-zone 网桥 (5550-5564)
├─ scope: StartTransientUnit <machine>.scope Delegate=1 (nspawn-register.c:164-190)
│         └ payload/ (容器进程) + supervisor/ (nspawn) (nspawn-cgroup.c:89,130)
├─ machined: Varlink io.systemd.Machine.Register → D-Bus 回退 (machine-register.c:175,169)
└─ mount tunnel ← 宿主可后续注入 bind mount (2706-2758)
```

### 设计动机

1. **双层 CLONE_NEWNS**:外层 mntns 归宿主 userns、内层归容器 userns(nspawn.c:3333-3342),使宿主侧可做特权收尾(钉住/擦除 procfs、idmap remount),而容器侧挂载受 userns 权限管束。
2. **Barrier 编号握手**(#1..#5):把 UID map 写入、netns 建立、cgroup 归位、api fs 擦除这些跨进程强依赖操作严格串行化,避免竞态与僵尸 netns(nspawn.c:5489-5758)。
3. **allow-list seccomp + 能力门槛**:白名单按 capability 条件放行,默认 ENOSYS 让容器内应用优雅降级而非硬崩(nspawn-seccomp.c:27-161)。
4. **mount tunnel**:根树 MS_PRIVATE 之后宿主仍可经 /run/systemd/nspawn/propagate 注入挂载,兼顾隔离与运维(nspawn.c:2706-2758)。
5. **scope + machined 双注册**:容器进程进 Delegate scope 由宿主 systemd 统一管资源,machined 提供机器清单;注册失败仅降级,保证 nspawn 可独立使用(nspawn-register.c:134-263,nspawn.c:5687-5691)。
6. **managed userns 委托**:UID 分配(nsresourced)与挂载(mountfsd)剥离到特权服务,让无特权 `--private-users=managed` 成为可能(nspawn.c:6218-6256)。
7. **stub PID 1**:任意命令也能获得"会收尸的 PID 1"与正确的 /proc/1/environ 语义,复用 sysv/systemd 关机信号协议(nspawn-stub-pid1.c:54-110)。
8. **pty 中继而非直通 tty**:控制台生命周期、热键、窗口标题、OSC 标注都握在监督者手里,容器崩了终端也不脏(nspawn.c:5823-5874)。

### FAQ 候选

1. nspawn 与 Docker 最本质的差别?nspawn 面向"引导一棵完整 OS 树"并深度复用宿主 systemd(scope/machined/journald),没有镜像分层与图驱动(见 mount 表与 scope 注册,nspawn-mount.c:557, nspawn-register.c:164)。
2. 默认 clone 哪些 namespace?外层仅 CLONE_NEWNS,内层加 IPC/PID/UTS;NET/USER/CGROUP 按选项追加(nspawn.c:238,3381,4426-4429,3408)。
3. `--boot` 时容器的 PID 1 是谁?是内层子进程自身 execve 的容器 init,不是 nspawn 的 fork 体(nspawn.c:3668-3674)。
4. `--as-pid2` 的 stub 干什么?占 PID 1 收尸、重写 /proc/1/environ、把 poweroff/reboot 信号翻译成对 payload 的 SIGTERM/SIGHUP 与 reboot() 调用(nspawn-stub-pid1.c:86-134)。
5. 容器怎么拿到第一块网卡?内层 unshare netns 后把 fd 发回,父进程创建 veth 对、peer 经 IFLA_NET_NS_PID 直落容器,命名 host0(nspawn-network.c:140-204)。
6. 为什么容器里 /proc/sys 几乎全只读?mount 表先 bind 再 MS_RDONLY remount,仅私有网络时对 /proc/sys/net 网开一面(nspawn-mount.c:562-569)。
7. .nspawn 文件从哪读、可信吗?/etc 与 /run 下的默认可信,镜像/目录旁边的默认不信任,命令行掩码永远优先(nspawn.c:5167-5206)。
8. `--ephemeral` 的实现?目录走 btrfs 快照(可回退拷贝),镜像整文件拷贝并在挂载后删除原件(nspawn.c:6271-6292,6419-6455,6563-6565)。
9. 容器"重启"如何实现?init 死于 SIGHUP 即判 CONTAINER_REBOOTED,nspawn 把整个启动流程从头再跑;服务模式下以退出码 133 触发服务级重启(nspawn.c:2891-2894,5921-5931)。
10. `--port=8080` 背后是什么?nftables netlink 下发 DNAT 类规则,rtnl 监听容器地址变化动态刷新(nspawn.c:2462-2471,6651-6657)。
11. /run/host/ 里有什么?宿主 os-release、凭证目录、container-manager/-uuid 标识、mount tunnel、以及非特权模式临时钉住的 proc/sys(nspawn-mount.c:607-618,1458-1459)。
12. machined 注册失败会怎样?默认模式只告警继续跑,`--register=yes` 才硬失败;共享 PID/UTS ns 时注册被禁用(nspawn.c:1486-1491,5687-5691)。

### 深挖方向

1. Barrier 的内核机制(eventfd/futex 组合)与 #1..#5 握手的死锁/竞态边界分析(src/shared/barrier.c,本次未读,未核实)。
2. nsresourced/mountfsd 的 Varlink 协议与 managed userns 全链路授权(userns_fd 如何跨服务传递,nspawn.c:6218-6256 仅起点)。
3. `.mstack` 分层容器栈:mstack_load/mstack_make_mounts 的 overlay 组装与 OCI 镜像的关系(nspawn.c:6570-6600;src/shared/mstack-*,未读)。
4. nspawn-oci.c(2138 行)对 runtime-spec 的覆盖度:SystemCallFilter、rlimit、capabilities 如何映射进 Settings。
5. `--bind-user=` 的 owneridmap 挂载与 userdb 联动(nspawn-bind-user.c,outer_child 4094-4129 的 custom mount 生成)。
6. systemd-nspawn@.service 与 `--keep-unit` 的分工(单元文件 units/,本 sparse 检出未含,未核实)。

## 正文蒸馏要点

1. nspawn 是三层进程模型:父监督者、外层 mntns 搭建者、内层容器 PID 1;外层与内层各持一个归属不同 userns 的 mount namespace(nspawn.c:5344,4426,3333-3342)。
2. namespace 默认集只有 IPC/PID/UTS,NET 由内层按 `--private-network` 补 unshare,USER/CGROUP 可选追加(nspawn.c:238,3381,3408,4426-4429)。
3. 父子经两对 SOCK_SEQPACKET socketpair 与 Barrier 五步握手串行化 UID map→netns→cgroup→api-fs-wipe 的时序(nspawn.c:5310-5314,5489-5758)。
4. API VFS 挂载表集中声明:procfs 全量、/proc/sys bind+只读(/proc/sys/net 例外)、/tmp//dev//run//sys tmpfs、/run/host/os-release、大量 /proc 子路径 inaccessible/只读(nspawn-mount.c:557-627)。
5. 容器根可以是目录、dissected 磁盘镜像(GPT/MBR/verity)、mountfsd 转交的 mount_fd 或 .mstack 分层栈,四路挂根(nspawn.c:3944-4012)。
6. seccomp 是能力门槛白名单:默认 ENOSYS、@known 内未放行 EPERM、NETLINK_AUDIT socket 伪造 EAFNOSUPPORT(nspawn-seccomp.c:159-161,198,223-241)。
7. veth 由父进程一次 RTM_NEWLINK 创建,peer 以 IFLA_NET_NS_PID 直落容器并命名 host0,宿主侧 ve-/vb- 前缀按是否接桥区分(nspawn-network.c:140-204)。
8. machined 注册 Varlink 优先(io.systemd.Machine.Register)、D-Bus RegisterMachineWithNetwork 回退,默认失败仅降级(nspawn-register 相关逻辑在 shared/machine-register.c:120-200)。
9. scope 属性是安全边界的一部分:DevicePolicy=closed + 白名单 tun/char-pts/fuse、Delegate=1、machine.slice(nspawn-register.c:32-46,185-190)。
10. 控制台是父进程 pty 中继:openpt_allocate→/dev/console→PTYForward,热键 Ctrl-]×3 杀 / ×2+r 重启 / ×2+p 关机(nspawn.c:3454-3466,5828-5866,4727-4757)。
11. stub PID 1 用 PR_SET_MM 重写 /proc/1/environ,并实现 sysv/systemd 关机信号到 SIGTERM/SIGHUP+reboot() 的翻译(nspawn-stub-pid1.c:50-90,170-197)。
12. 容器重启 = SIGHUP 退出后整轮重跑;--keep-unit 服务模式改用退出码 133 触发单元重启(nspawn.c:2891-2894,5921-5931,6712-6727)。
