# 第 05 章 · cgroup 集成:层级构建、资源控制与真相之源

> 基线:commit `1f66b524`。核心:src/core/cgroup.c(4695 行)、cgroup-util.c、bpf-*.c。

## 5.0 全景:unit 树 = cgroup 树

```
/sys/fs/cgroup                       unit 树
├ init.scope        ← PID 1 自我安置,并把根下游离进程全部收编
├ system.slice ── nginx.service …          每个 service 一个 cgroup
├ user.slice/user-1000.slice/user@1000.service(Delegate=yes)── app.slice/…
└ machine.slice     ← 容器/虚拟机
控制器传播:叶子需求自底向上汇总(members_mask)→祖先写 +ctrl(广度优先 enable);
撤销反之必须先把子孙 -ctrl 写掉(深度优先 disable),否则 EBUSY
```

进程属于谁由内核说了算:`manager_get_unit_by_pidref` 查 `/proc/<pid>/cgroup` 再沿路径逐级找 unit(cgroup.c:3469-3496)。路径推导唯一规则:父路径=父 slice 路径,末段=转义 unit 名;`user-1000.slice` 的 `-` 就是目录分隔;`cg_escape` 给可能撞内核保留名的 unit 名加 `_` 前缀。

## 5.1 控制器启用:七种 mask 与双向 realize

单点需求沿树汇总成三个递归 mask:members(子树并)、siblings(**兄弟也要 realize**——否则 v1 下同 slice 中一个 unit 有 cpu 层级另一个没有会造成调度不对称)、target=own|members|siblings 再减 DisableControllers 禁区(cgroup.c:1806-1915)。realize 顺序:先对子孙 disable、再对祖先链 enable、最后自己——注释原文:"Controllers can only be enabled breadth-first from the root; disabled depth-first from the leaves"(cgroup.c:2443-2444,2477-2478)。**Delegate= 是传播边界**:delegated 子树里 systemd 不碰 cgroup.subtree_control,保住被委派方已开的控制器(:2164-2175);挪进程/删子组走 bus 协议。

## 5.2 属性应用与事件链

`cgroup_context_apply` 逐控制器写内核文件:CPUWeight→cpu.weight、CPUQuota→cpu.max、TasksMax→pids.max、MemoryMin/Max→memory.min/max…(cgroup.c:1477-1637);Startup* 变体在启动期生效、`manager_invalidate_startup_units` 完成启动→运行权重切换。**事件链**:一个 inotify fd 盯全部 unit 的 cgroup.events(populated/frozen)与 memory.events(oom_kill)→入 empty/oom 队列→defer 源消费——empty 事件只是 SIGCHLD 之后的"最后安全网"(优先级刻意排后);OOM 与 oomd 击杀分别从 memory.events 与 user.oomd_* xattr 检出,把失败原因写进 unit 最终状态。

## 5.3 七个 BPF prog

devices 控制器在 v2 已消失,替代者是 cgroup 级 BPF:**bpf-devices**(DeviceAllow/DevicePolicy)、**bpf-firewall**(IPAddressAllow/Deny+IPAccounting,挂 inet_ingress/egress;父 slice 的 IP 列表会传染子孙)、**bpf-foreign**(挂别人 pin 在 bpffs 的 prog)、**bpf-socket-bind**(bind4/bind6)、**bpf-restrict-ifaces**(cgroup_skb 校验 ifindex)、**bpf-bind-iface**(sock_create)、**bpf-restrict-fs**(LSM file_open,不走 cgroup attach 故 exec 最晚期才装)。iptables 按包过滤无法按 cgroup 归账——挂进 cgroup 的 prog 让"每个 unit 自己的防火墙"成为可能。

## 5.4 为什么必须坐在统一层级根上

`manager_setup_cgroup` 八步开场(cgroup.c:3293-3389):反查自身 cgroup 路径作 root 坐标系→open 钉住 cgroupfs 防 umount→建 empty/inotify 源→**建 init.scope 把 PID 1 与根下所有游离进程收编**→探测可用控制器。v2 一致性的根因:"目录树=unit 树"这一唯一真相要回答"这个 PID 属于哪个 unit/还剩哪些进程/用了多少资源",前提是整棵子树没有第三方乱开的 +ctrl;v1 每控制器多棵树让"路径→unit"反查有多义性。

## 5.5 设计动机

1. **cgroup 是真相之源**:进程表可撒谎(daemonize/PID 复用),/proc/<pid>/cgroup 不会;
2. **按 unit 一 cgroup**:控制/统计/生命周期粒度天然对齐——service 停止=删目录=进程必然全死,无法逃避;
3. **slice 层级**:unit 树直接复用 cgroup 树,slice 让"一类服务共享预算"成为一行配置;
4. **empty/OOM 事件收敛成事件源**:状态机才有秒级反应(SIGCHLD)+完备兜底(inotify);
5. **委派边界**:Delegate= 交出子树控制权而不是责任,xattr 公告委派态。

## 5.6 FAQ

**Q1:进程属于哪个 unit 谁说了算?**
内核:/proc/<pid>/cgroup 查路径再反查 cgroup_unit 哈希。

**Q2:slice 名里的横杠什么含义?**
目录分隔:user-1000.slice → user.slice/user-1000.slice。

**Q3:为什么禁用控制器必须自底向上?**
内核要求子树先关 +ctrl 父级才能关,否则 EBUSY。

**Q4:Delegate=yes 后 systemd 还管这个子树吗?**
不管控制器开关;挪进程/删子组走 bus 协议。

**Q5:CPUAccounting= 还有用吗?**
已废为 legacy:v2 的 cpu.stat 恒在,无需开关。

**Q6:unit 停止后还能看资源统计吗?**
能:prune 前缓存最后一份 CPU/内存峰值/IO 统计。

**Q7:什么情况下 cgroup 删不掉?**
D 状态进程:unit_maybe_release_cgroup 仅在子树递归为空才松手。

**Q8:OOM 被杀怎么感知?**
memory.events 的 oom_kill 计数增长;oomd 击杀走 xattr。

**Q9:RestrictFileSystems 为什么 exec 最晚期装?**
它是 LSM BPF 不走 cgroup attach,必须在最终 exec 前安装。

**Q10:IPAccounting 数据从哪读?**
BPF map(cgroup.c:3687-3727)。

## 5.7 小结与深挖方向

本章结论:**cgroup 集成="unit 树即 cgroup 树+七 mask 双向 realize+inotify 事件链+BPF 七件套,根上不留人"**。深挖:

1. Startup*/base 权重切换的 invalidate 闭环;
2. freezer:frozen 位驱动的冻结状态机;
3. bpf-foreign 与外部 BPF 管理工具的协作;
4. 委派子树的 clone3(CLONE_INTO_CGROUP) EBUSY 清理;
5. 根 slice 的 TasksMax 翻译成 sysctl 的单向收放。
