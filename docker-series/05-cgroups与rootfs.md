# 第 05 章 · cgroups 与 rootfs:资源与文件系统两个隔离面

> 基线:commit `579be22`。行号以 libcontainer/ 与 vendor/github.com/opencontainers/cgroups/ 为准。**勘误**:cgroups 包已抽为独立模块 `github.com/opencontainers/cgroups` v0.1.0(go.mod:19),libcontainer 无 cgroups 目录。

## 5.0 全景:资源隔离三面与时序

```
namespace(04 章 nsexec)+ cgroups(本章)+ rootfs(本章)= 容器三面
时序:clone(带 ns flags)→ cgroup 挂接(父进程 Apply(p.pid),process_linux.go:826
     ——先于 init 醒来,防逃逸)→ init 内 rootfs 挂载+pivot_root → exec
```

**Manager 抽象**:15 方法接口(cgroups.go:26-86);四实现矩阵 v2×{fs2,systemd}+v1×{fs,systemd}。**选择逻辑**(manager/new.go:29-55):systemd 不可用直接报错(:33)——不再静默降级;v2 判定靠 statfs 魔数 CGROUP2_SUPER_MAGIC+sync.Once(utils.go:34-51)。

## 5.1 cgroups v2:统一层级与 BPF 设备过滤

v2 的理念:**统一层级**(单棵树,进程只在叶子)。fs2 驱动:`CreateCgroupPath` 逐级 mkdir+写 `cgroup.subtree_control`(fs2/create.go:71-150,含 domain invalid/threaded 状态机);`Set` 十步资源应用链(:213-267:pids→memory→io→cpu→devices→cpuset→hugetlb→rdma→freezer→Unified 通配)。systemd 驱动:dbus 属性翻译(Delegate+Accounting)+fsMgr.Set 兜底(systemd/v2.go:290-390,:524-541);OOMPolicy 只能在建 scope 时设(:337-358)。**devices 用 eBPF**:emulator 化简规则保证与 v1 语义一致+JNE 指令链生成 `BPF_PROG_TYPE_CGROUP_DEVICE` 程序(devices/devicefilter.go:26-195;userns 下可放行失败 :30-52)——v2 砍掉了 devices controller,BPF 是替代品。时序细节:`Apply(p.pid)` 先于 init 醒来(:826)防逃逸;`Set` 在 procHooks 前(:1018)。

## 5.2 rootfs:mounts、pivot_root 与 masked

mounts **不排序、严格 spec 顺序**(specconv/spec_linux.go:416-422)——顺序是用户语义;选项→flag 翻译表(:73-108)。**pivot_root(".",".") 技巧**借 cwd 免建 oldroot 目录,旧根 rslave+MNT_DETACH(rootfs_linux.go:1147-1196);三分支:NoPivotRoot→msMoveRoot(先清场宿主 procfs/sysfs,:1198-1259)/NEWNS→pivot/chroot(:234-240)。masked/readonly paths 在 init 侧 pivot 后执行(standard_init_linux.go:138-146):文件 bind /dev/null、目录 ro tmpfs(rootfs_linux.go:1352-1448);**checkProcMount 禁盖 /proc**,仅放行 lxcfs 白名单(:840-903)。bind 挂载的二段式 MS_REMOUNT+锁定 flag 重试(:675-783)。OOM:memory.events oom_kill 判定+notify_v2 inotify(fs2/fs2.go:322-324;notify_v2_linux.go:14-92;呼应 03 章 shim 的监控);oom_score_adj 经 netlink 下发由 nsexec 写 /proc/self(container_linux.go:1176-1182;nsexec.c:296-302)。

## 5.3 与前作对照及设计动机

1. **v2 统一层级是方向**:v1 每 controller 一棵树的多进程写竞争消失;systemd 成为管理者的政治与现实(fs 驱动保留给无 systemd 环境);
2. **devices 用 BPF**:v1 的 devices controller 在 v2 被删,BPF 程序挂在 cgroup 上语义等价——**内核删能力,生态用 BPF 补**,这是 Linux 资源管理的时代转向;
3. **pivot_root 优于 chroot**:chroot 不换根设备且旧根可逃逸(mount ref);pivot_root 真正切换 mount namespace 的根,旧根 MNT_DETACH 彻底切断;
4. **mounts 不排序**:顺序即语义(bind 覆盖依赖先后)——"帮用户排序"反而制造魔法。

## 5.4 FAQ

**Q1:systemd 不可用为什么不降级 fs?**
(:33):两种驱动的 cgroup 路径语义不同,静默切换会造成资源参数错位——显式失败。

**Q2:v2 怎么限制设备访问?**
eBPF CGROUP_DEVICE 程序(:26-195):规则 emulator 化简后生成 JNE 指令链。

**Q3:cgroup 为什么父进程挂接(不在 init 里)?**
(:826):init 醒来前必须已被限制——否则有逃逸窗口。

**Q4:pivot_root(".",".") 的技巧?**
老根已在当前位置:借 cwd 免建交换目录(:1147-1196)。

**Q5:为什么 mount 不自动排序?**
(:416-422):顺序是用户语义(覆盖关系);排序会制造隐式行为。

**Q6:checkProcMount 为什么禁盖 /proc?**
(:840-903):盖 /proc 会欺骗容器内进程(runc 自己也读)——仅 lxcfs 白名单。

**Q7:masked paths 的实现?**
文件 bind /dev/null、目录 ro tmpfs(:1352-1448):使路径"存在但为空"。

**Q8:OOM 事件怎么到 shim?**
v2 memory.events 的 oom_kill 计数(fs2.go:322-324)+inotify(03 章)。

**Q9:bind 挂载为什么要二段 remount?**
(:675-783):bind 会复制旧 flag,先 bind 再 remount 锁定新 flag——内核语义。

**Q10:systemd 驱动的好处?**
Delegate+Accounting(:290-390):systemd 统一管理资源竞争(与 kubelet 的 systemd cgroup driver 对齐)。

## 5.5 小结与深挖方向

本章结论:**cgroups="Manager 抽象+v2 统一层级+BPF 设备";rootfs="严格顺序+pivot_root+masked 路径"**。深挖:

1. BPF 设备程序(:26-195)在大量规则下的指令数上限;
2. fs2 domain invalid/threaded 状态机(:71-150)对线程化容器的语义;
3. pivot_root 在 overlayfs rootfs 上的特殊路径;
4. systemd delegate(:290-390)与 kubelet driver 的版本协商;
5. oom_score_adj 的 netlink 下发(:1176-1182)为何不走文件。

> 下一章(卷末):OCI 规范落地与工程文化——spec 如何变成内核调用。
