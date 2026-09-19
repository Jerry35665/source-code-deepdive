# 第 13 章 · nspawn:三层进程、双层挂载命名空间与 API VFS 挂载表

> 基线:commit `1f66b524`("align config PrivateUsersOwnership default with CLI")。核心:src/nspawn/(nspawn.c 6,777 行 / nspawn-mount.c 1,515 行 / nspawn-network.c / nspawn-seccomp.c / nspawn-expose-ports.c)。

## 13.0 全景:三层进程与两层 mntns

```
 父进程(监督者,sd-event 循环):收 mntns fd/UID shift/内层 PID/UUID/notify socket
   │ fork(SIGCHLD|CLONE_NEWNS)                    ← managed userns 时先 setns(userns_fd)
   ▼ 外层子进程:只 CLONE_NEWNS,归宿主 userns
   │   挂根四路径:mountfsd 的 fd(move_mount)/dissected image/.mstack overlay/目录 bind
   │   API VFS 外层部分、pivot_root、idmapped mounts/remount_idmap、copy_devnodes
   │ fork(SIGCHLD|CLONE_NEWNS|IPC|PID|UTS|USER?|NET?)
   ▼ 内层子进程(容器 PID 1):reset_uid_gid → 内层 mount_all → unshare(NET)→
     sysfs → cgroupns → boot_id/kmsg → pty=/dev/console → seccomp → 能力五元组 → exec
 Barrier #1..#5 五步握手串行化:UID map → netns → cgroup → api-fs-wipe(nspawn.c:5489-5758)
```

纠偏:nspawn 不是单 fork——是**三层进程**,且两层 mntns 归属不同 userns(内层归容器、外层归宿主),这是特权/非特权路径共存的根基(nspawn.c:5340-5355, 3333-3342 注释)。

## 13.1 无特权主线:USER_NAMESPACE_MANAGED

managed 模式先连 nsresourced 与 mountfsd 两个 Varlink 服务,申请 **64K UID 的 user namespace**(nsresource_allocate_userns_full,nspawn.c:6239-6255);目录/镜像挂载由 mountfsd 在自己名字空间完成 loop+挂载后**把 mount fd 递回来**(:6397-6407, 6548-6560);cgroup 委托走 nsresource_add_cgroup。managed 模式强制 `--private-network`(容器内要挂自己的 sysfs,:1480-1481)。UID 归属策略 `--private-users-ownership=` 支持 map/foreign/auto/chown,auto 在内核不支持 idmapped mounts 时静默回退 chown——正是本基线 commit 标题修的默认对齐点(:1493-1495, 4157-4210)。

## 13.2 API VFS 挂载表

安全模型核心是一张声明式挂载表(nspawn-mount.c:557-627):proc 挂 /proc(MOUNT_FATAL|MOUNT_IN_USERNS)、/proc/sys 先 bind 再整体 **MS_RDONLY 重挂**(APPLY_APIVFS_RO)、/proc/sys/net 仅在私有网络时另 bind(APPLY_APIVFS_NETNS);tmpfs 挂 /tmp、/sys、/dev、/run;宿主 os-release bind 到 /run/host/os-release 并转只读;/proc/kallsyms、kcore、keys、sysrq-trigger 变 inaccessible 节点。`mount_all` 被调用**两次**:外层执行 MOUNT_IN_USERNS 之外条目,内层执行 IN_USERNS 条目(nspawn.c:4257, 3370)。宿主向容器注入挂载经 "mount tunnel":/run/systemd/nspawn/propagate/<machine> 只读 bind 进容器(nspawn.c:2706-2757)。非特权场景另有"先钉住全可见 proc/sys 再由父进程跨 mntns 擦除"的戏法(pin_fully_visible_api_fs/wipe,nspawn-mount.c:1461-1515)。

## 13.3 seccomp 与能力

seccomp 是"总白名单+能力门槛":@aio/@file-system/@process 等 16 组无条件放行,@clock/@module/@raw-io 等仅当对应 capability 在保留集才放行;**默认拒绝动作是 ENOSYS**(SCMP_ACT_ERRNO(ENOSYS)),@known 中未放行者显式 EPERM(nspawn-seccomp.c:138-161, 198)——ENOSYS 让应用能优雅降级。另有独立过滤器把 NETLINK_AUDIT 改写 EAFNOSUPPORT,让容器内 audit 用户态认为内核没开 audit(:223-241)。clone 默认**不含 CLONE_NEWNET**(内层按需 unshare,:238, 3381);共享宿主网络且启用 userns 时自动收回 CAP_NET_BIND_SERVICE(6164-6168);boot 模式禁用 ambient 能力(1568-1570)。

## 13.4 网络与端口暴露

`--network-veth` 隐含 --private-network;内层 unshare 后把 netns fd 发回父进程,父进程一次 RTM_NEWLINK 建 veth 两端,peer 用 IFLA_NET_NS_PID 直接落进容器:宿主侧 `vb-`/`ve-`+机器名,容器侧固定 `host0`,MAC 由机器名哈希稳定生成(nspawn-network.c:108-204)。纠偏:`--port=` 用 **nftables DNAT 而非 iptables**——内层把 rtnl socket 发给父进程,父进程订阅 RTM_NEWADDR/DELADDR,地址变化时对每端口写 fw_nftables_add_local_dnat,退出时撤销(nspawn-expose-ports.c:111-149, 182-211)。

## 13.5 machined 注册与终端

纠偏:machined 注册**已转向 Varlink 优先**——先走 io.systemd.Machine.Register,连不上才回退 D-Bus RegisterMachineWithNetwork;默认 --register=auto 失败仅告警,共享 PID/UTS ns 时注册直接禁用(shared/machine-register.c:120-200; nspawn.c:5687-5691)。"经典 D-Bus RegisterMachine"的通行说法已过时。终端:内层分配 pty 挂为 /dev/console,master fd 交父进程 pty_forward 双向中继(支持窗口尺寸/OSC 8 标注);热键 Ctrl-] 三下 1 秒杀容器,两下+r 重启、+p 关机(nspawn.c:4727-4757)。本 commit 无 nspawn-patch-hostname.c——hostname/proc-sys 伪造已内联为 setup_hostname/patch_sysctl(:2473, 3241)。

## 13.6 设计动机

1. **两层 mntns**:外层搭挂载树归宿主 userns、内层重挂归容器 userns,挂载传播天然隔离(nspawn.c:3333-3342);
2. **Barrier 五步握手**:UID map→netns→cgroup→api-fs-wipe 的跨进程顺序化,消灭竞态(5489-5758);
3. **声明式挂载表**:API VFS 规则一张表+掩码过滤,两次 mount_all 分层执行(nspawn-mount.c:557-627);
4. **ENOSYS 优先**:未知系统调用报"不存在"而非"被拒",应用降级而非崩溃(nspawn-seccomp.c:159-161);
5. **mountfsd 代挂**:无特权用户也能挂 loop/镜像,挂载 fd 过 socket 交接(nspawn.c:6548-6560);
6. **rtnl 订阅式 DNAT**:容器地址动态变化时端口转发自动跟随(nspawn-expose-ports.c:182-211)。

## 13.7 FAQ

**Q1:容器里 PID 1 是谁?**
默认用户参数直接 execve 成 PID 1;--boot 时按序尝试 /usr/lib/systemd/systemd 等三路径(nspawn.c:3668-3703)。

**Q2:默认隔离哪些 namespace?**
IPC/PID/UTS 必带,NET/USER/CGROUP 按需(:238, 3377-3416)。

**Q3:seccomp 默认拒绝动作?**
ENOSYS;@known 内未放行才是 EPERM(nspawn-seccomp.c:159-161)。

**Q4:端口转发用什么实现?**
nftables DNAT,非 iptables(nspawn-expose-ports.c:111-149)。

**Q5:veth 命名规则?**
宿主侧 vb-/ve-+机器名,容器侧 host0,MAC 由机器名哈希(nspawn-network.c:184-204)。

**Q6:怎么向运行中的容器注入挂载?**
mount tunnel:/run/systemd/nspawn/propagate/<machine>(nspawn.c:2706)。

**Q7:machined 注册走什么协议?**
Varlink 优先,D-Bus 回退(shared/machine-register.c:120-200)。

**Q8:无特权用户能用 nspawn 吗?**
能,managed userns 模式由 nsresourced/mountfsd 代申请与挂载(nspawn.c:6218-6256)。

**Q9:如何防止同一镜像双开?**
image_path_lock:只读共享锁/可写排他锁(6298-6311)。

**Q10:Ctrl-]]] 是什么?**
三下 1 秒内杀容器;两下+r 重启、+p 关机(:4727-4757)。

## 13.8 小结与深挖方向

本章结论:**nspawn=三层进程+双层 mntns+声明式 API VFS+ENOSYS seccomp+nftables DNAT+Varlink 注册**。深挖:

1. remount_idmap 的内核 idmapped mounts 与 chown 回退判定(nspawn.c:4148-4215);
2. .mstack 分层镜像的 overlay 组合(3988-4003);
3. OCI bundle 支持的转换面(nspawn-oci.c 2,138 行);
4. setup_vol 会不会的 volatile overlay 与 tmpfs 模式差异;
5. suppress-sync 过滤器的实现与使用场景(nspawn-seccomp.c:251-255)。
