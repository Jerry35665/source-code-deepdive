# 报告 E:cgroup 集成 —— 层级构建、资源控制与真相之源

> 基线:commit 1f66b52452879b68c32d79efdb9b97e4542ae7a4(浅克隆,sparse 检出 src/ 与 man/)。
> 核心文件:`src/core/cgroup.c`(4695 行)、`src/basic/cgroup-util.c`(1801 行)、`src/core/bpf-*.c`。
> 注:任务提到的 "gitignore 的 cgroup v2 一致性要求"——已实测仓库 `.gitignore`,其中并无任何 cgroup 相关条目;
> 结合源码,本节按 "systemd 为何必须占据 cgroup v2 统一层级的根" 来考证(见 §8)。

## 0. 全景图:unit 树 = cgroup 树

```
 cgroup v2 统一层级 (/sys/fs/cgroup)              unit 树
 ─────────────────────────────────────────────────────────────────────────────
 /                                ←-.slice (根切片, cgroup_root)      -.slice
 ├── init.scope                   ← PID 1 自我安置的 scope             init.scope
 ├── system.slice                 ← 系统服务的默认切片                 system.slice
 │    ├── nginx.service           ← 每个 service 一个 cgroup           nginx.service
 │    └── backing.slice
 │         └── nfs-mount.mount    ← mount/timer 等也有 cgroup          nfs-mount.mount
 ├── user.slice                                                        user.slice
 │    └── user-1000.slice         ← "user-1000.slice" 按 '-' 折叠为路径 user@1000.service
 │         ├── user@1000.service  ← Delegate=yes:控制器开关权交给用户管理器
 │         │    ├── app.slice                                          app.slice
 │         │         └── foo.service                                   foo.service
 │         └── session-3.scope   ← logind 创建的会话 scope             session-3.scope
 └── machine.slice                ← 容器/虚拟机                        machine.slice

 控制器在层级上的启用传播(cgroup.subtree_control,写 "+cpu" 等):
   由叶子需求自底向上汇总(members_mask)→ 在每个祖先写 +ctrl(根→叶,广度优先 enable);
   撤销时反之,必须先把子孙的 -ctrl 写掉(叶→根,深度优先 disable),否则内核报 EBUSY。
   DisableControllers= 在祖先设一道"禁区"(ancestor_disable_mask),禁区以下永远不开。
   Delegate=yes 的 cgroup 是传播边界:systemd 不再代管其子树内的控制器开关。
```

unit 与 cgroup 是一一对应的:`manager->cgroup_unit` 以 cgroup 路径为键反查 unit
(src/core/cgroup.c:1989、src/core/cgroup.c:3412-3437)。PID 归属判定走 cgroup 而非进程表:
`manager_get_unit_by_pidref` 先查 `/proc/<pid>/cgroup` 再沿路径向上逐级找 unit(src/core/cgroup.c:3469-3496),
这就是"cgroup 是真相之源"的第一层含义——进程属于谁,由内核的 cgroup 成员关系说了算。

## 1. cgroup 路径的构造:slice 链推导 + 转义

路径默认推导只有一种规则:**父路径 = 父 slice 的路径,末段 = 转义后的 unit 名**:

```c
// src/core/cgroup.c:1941-1958 (unit_default_cgroup_path)
if (unit_has_name(u, SPECIAL_ROOT_SLICE))
        p = strdup(u->manager->cgroup_root);          /* -.slice 即根 */
else {
        slice = UNIT_GET_SLICE(u);
        if (slice && !unit_has_name(slice, SPECIAL_ROOT_SLICE)) {
                r = cg_slice_to_path(slice->id, &slice_path);   /* 递归交给命名规则 */
        r = cg_escape(u->id, &escaped);
        p = path_join(empty_to_root(u->manager->cgroup_root), slice_path, escaped);
```

两个命名细节:
- slice 名中的 `-` 就是目录分隔:`user-1000.slice` → `user.slice/user-1000.slice`,
  由 `cg_slice_to_path` 按 dash 逐段展开(src/basic/cgroup-util.c:1310-1376)。
- `cg_escape` 给可能撞内核保留名的 unit 名加 `_` 前缀(名字以 `_`/`.` 开头、`cgroup.*`、
  控制器名 `cpu.` 等都要转义;读回时剥掉一个下划线即可,src/basic/cgroup-util.c:1236-1308)。

`unit_set_cgroup_path` 把路径写入 `crt->cgroup_path` 并登记进 `manager->cgroup_unit` 哈希
(src/core/cgroup.c:1967-1998);重执行(serialize)后路径丢失时可用
`unit_get_cgroup_path_with_fallback` 回退到默认推导(src/core/cgroup.c:2000-2009)。

## 2. 控制器启用:mask 汇总与双向 realize

### 2.1 需求如何变成 mask

unit "自己需要哪些控制器" 由 CGroupContext 逐项推导(src/core/cgroup.c:1717-1749):
CPUWeight/CPUQuota→`cpu`,AllowedCPUs/Mems→`cpuset`,IOAccounting/IO 配置→`io`,
MemoryAccounting/内存限制→`memory`,TasksAccounting/TasksMax→`pids`,
设备策略→`BPF_DEVICES` 等 BPF 伪控制器(见 §7)。BPF 伪控制器与真实控制器同住一个
CGroupMask 枚举(src/basic/cgroup-util.h:10-67)。

三个递归 mask 把单点需求沿树汇总(src/core/cgroup.c:1806-1852):
- `members_mask`:所有子树的并(缓存,src/core/cgroup.c:1814-1837);
- `siblings_mask`:父 slice 的 members——**兄弟也要 realized**,否则 v1 下同 slice 中
  "一个 unit 有 cpu 层级、另一个没有" 会造成调度不对称(src/core/cgroup.c:2641-2646);
- `target_mask = own | members | siblings`,再与 `cgroup_supported` 求交、
  减去 `ancestor_disable_mask`(DisableControllers= 禁区,src/core/cgroup.c:1881-1900、1854-1879)。
- v2 专属 `enable_mask = members_mask`(本 cgroup 要给子树开什么,src/core/cgroup.c:1902-1915)。

### 2.2 realize:创建目录、开控制器、写属性

`unit_prepare_exec` 在 fork 前同步调用 `unit_realize_cgroup`(src/core/unit.c:6164-6172);
后者先把 slice 家族排入 realize 队列,再同步 realize 自己(src/core/cgroup.c:2688-2711)。
队列由 `manager_dispatch_cgroup_realize_queue` 在事件循环中消化(src/core/cgroup.c:2605-2632)。

核心是 `unit_update_cgroup`(src/core/cgroup.c:2110-2193):`cg_create` 建目录(2131)、
记 cgroup_id(2147-2158)、挂 inotify(2161-2162)、按需启用控制器、应用属性(2181-2182)。
关键边界:**只有 `created || !unit_cgroup_delegate(u)` 才动控制器**——delegated 子树里
systemd 不碰 `cgroup.subtree_control`,保住被委派方已开的控制器(src/core/cgroup.c:2164-2175)。

`cg_enable` 把 mask 翻译成对 `cgroup.subtree_control` 的单字节写入 `"+"ctrl`/`"-ctrl"`,
逐个控制器写(src/shared/cgroup-setup.c:399-457);关不掉且返回 EBUSY 时,视为"仍在启用",
如实记入结果 mask(src/shared/cgroup-setup.c:435-451)。

### 2.3 启用向下、禁用向上

```c
// src/core/cgroup.c:2443-2444, 2477-2478 (注释)
/* Controllers can only be enabled breadth-first, from the root of the
 * hierarchy downwards to the unit in question. */
/* Controllers can only be disabled depth-first, from the leaves of the
 * hierarchy upwards to the unit in question. */
```

`unit_realize_cgroup_now` 先对子孙做 disable、再对祖先链做 enable,最后落到自己
(src/core/cgroup.c:2565-2596);`unit_realize_cgroup_now_enable/_now_disable` 分别递归
(slice 2454-2459、2487-2516)。文件里画了一棵 8 节点的树推演 "k 想开 memory、a 有
DisableControllers=cpu" 的完整顺序(src/core/cgroup.c:2521-2563),是理解传播规则的最好入口。

v1 多层级兼容:同一套 mask 逻辑在 legacy 层级下表现为"每个控制器各挂一棵树",
`CGROUP_MASK_V1` 仍在(src/basic/cgroup-util.h:55),`cg_has_legacy` 甚至还在探测 tmpfs
挂载(src/shared/cgroup-setup.c:467-491),但主线代码只把它当历史包袱。

## 3. 属性应用:CGroupContext → 内核接口文件

`cgroup_context_apply` 按 apply_mask 逐控制器写入(src/core/cgroup.c:1477-1637),
`set_attribute_and_warn` 统一封装写文件并按 errno 分级告警(src/core/cgroup.c:128-145)。
映射(均在 src/core/cgroup.c):

| unit 属性 | 内核接口文件 | 写入点 |
|---|---|---|
| CPUWeight/StartupCPUWeight | `cpu.weight`(v1 为 `cpu.shares`) | 1090-1097 |
| CPUQuota= | `cpu.max` "quota period"(周期钳位 [1ms,1s]) | 1118-1130 |
| CPUIdle= (weight=0) | `cpu.idle` | 1099-1116 |
| AllowedCPUs/Mems、Startup… | `cpuset.cpus` / `cpuset.mems` / `cpuset.cpus.partition` | 1520-1526 |
| IOWeight/IO*Weight | `io.weight` "default N" + `io.bfq.weight` 换算 | 1466-1473、1210-1238 |
| IOReadIOPSMax 等 | `io.max` | 1285-1303 |
| MemoryMin/Low/High/Max/SwapMax/ZswapMax | `memory.min/low/high/max`、`memory.swap.max`、`memory.zswap.max` | 1570-1578 |
| MemoryOomGroup= | `memory.oom.group` | 1577 |
| TasksMax= | `pids.max`(无限制写 "max") | 1611-1619 |
| IPIngress*/IPFilter* 等 | (无文件,触发 BPF 安装) | 1622-1637 |

startup/base 权重切换:`cgroup_context_cpu_weight` 在 manager 处于
STARTING/INITIALIZING/STOPPING 时优先取 `startup_cpu_weight`,稳定运行后回落到
`cpu_weight`(src/core/cgroup.c:1023-1033;cpuset 同型 1035-1049;memory 同型 1561-1567)。
启动完成后 `manager_invalidate_startup_units` 使这些 unit 的 CPU/IO/cpuset 失效并重 realizes,
完成"启动权重 → 运行权重"的切换(src/core/cgroup.c:4073-4080;判定集合 106-126)。

根 cgroup 的特殊化:绝大多数属性在 `-.slice`(is_local_root)上不写(1507、1520、1531、1557、1611);
而 host 根上的 TasksMax 反被翻译成 `kernel.threads-max`/`pid_max` 等 sysctl 的一次性单向收放
(1583-1607),避免内核不在根上暴露 `pids.max` 的空洞。

## 4. delegated units:system/user 管理器的分界

只有 Service 与 Scope 两种 vtable 声明 `can_delegate = true`(src/core/service.c:6694、src/core/scope.c:743);
`Delegate=` 打开时,`unit_get_delegate_mask` 额外上交 `CGROUP_MASK_DELEGATE`(=全部 v2 控制器,
src/basic/cgroup-util.h:61、src/core/cgroup.c:1792-1804)。典型拓扑:logind 把
`session-<id>.scope` 直接放进 `user->slice`(src/login/logind-session.c:781-805),
`user@.service` 带 `Delegate=yes`,用户管理器在其子树内自行给 app.slice/session.slice 开控制器
(man/systemd.resource-control.xml:85-104 的层级示例)。边界两侧的协议:
- 子管理器挪进程走 bus 调 `AttachProcessesToUnit`(src/core/cgroup.c:2195-2225);
- 清理子 cgroup 走 `RemoveSubgroupFromUnit`(src/core/cgroup.c:2789-2826);
- cgroup 上打 `trusted.delegate`/`user.delegate` xattr 标记委派态(src/core/cgroup.c:917-937);
- 重启委派 unit 前,把负载残留的 `+pids` 等清掉,避免子树成内部节点导致
  `clone3(CLONE_INTO_CGROUP)` EBUSY(src/core/cgroup.c:4050-4071)。

## 5. 事件:cgroup.events / memory.events / PSI

cgroup v2 没有用户态 release agent,systemd 改用**一个 inotify fd 盯所有 unit 的两个事件文件**:

```
manager_setup_cgroup: inotify_init1 → on_cgroup_inotify_event 常驻 (src/core/cgroup.c:3338-3357)
  每个 unit realize 时: unit_watch_cgroup        → 盯 cgroup.events (IN_MODIFY)   (2011-2053)
                        unit_watch_cgroup_memory → 盯 memory.events(IN_MODIFY)   (2055-2108)
                                  ↑ 不盯 slice(内核不上报递归 oom_kill,2077-2080);
                                    且以 memory_accounting 开启为前提(2071-2075)

inotify 事件 (on_cgroup_inotify_event, 3213-3254)
  ├─ wd ∈ cgroup_control_inotify_wd_unit → unit_check_cgroup_events(u)
  │     读 cgroup.events 的 populated/frozen (3187-3207)
  │     populated=0 → unit_add_to_cgroup_empty_queue
  │     populated=1 → 移出 empty 队列;frozen 位驱动 freezer 状态机 (3206-3207)
  └─ wd ∈ cgroup_memory_inotify_wd_unit → unit_add_to_cgroup_oom_queue(u)

on_cgroup_empty_event (defer 源, 优先级低于 SIGCHLD, 2938-2972)
  ├─ unit_check_oom / unit_check_oomd_kill        ← 先补 OOM 判定
  ├─ unit 已 inactive → unit_prune_cgroup(u)      ← 顺手删 cgroup
  └─ 否则 vtable notify_cgroup_empty(u)
        → service_notify_cgroup_empty_event:按状态机决定进 stop/running/失败
          (src/core/service.c:4626-4695;scope 版 src/core/scope.c:566)
```

empty 事件只是"最后一道安全网":事件源被刻意排在 SIGCHLD/通知消息之后,
能拿到退出码就用 SIGCHLD,cgroup 变空仅兜底(src/core/cgroup.c:3325-3327、2979-2982)。

OOM 联动:`unit_check_oom` 读 `memory.events` 的 `oom_kill` 计数,与 `oom_kill_last` 比较,
增长则记 `SD_MESSAGE_UNIT_OUT_OF_MEMORY` 日志并回调 `unit_notify_cgroup_oom`
(src/core/cgroup.c:3057-3107、src/core/unit.c:3993-3998);`memory.oom.group=1` 时改读
`memory.events.local` 的 `oom_group_kill`(3068-3081)。systemd-oomd 的击杀则通过
`user.oomd_ooms`/`user.oomd_kill` xattr 检出(src/core/cgroup.c:3006-3055),这两个 xattr
由 `cgroup_oomd_xattr_apply` 按 ManagedOOMPreference= 写入/清除(src/core/cgroup.c:820-840)。
此外 systemd 会为 PID 1 建立基于 PSI 的 memory/cpu/io 压力事件源
(`sd_event_add_memory_pressure` 等,src/core/manager.c:810-842),init.scope 每次 realize 时
顺带重开这些接口(管理器先于 init.scope 存在,src/core/cgroup.c:2184-2190)。

## 6. unit 消亡与 cgroup 释放

释放链:`unit_prune_cgroup`(2828-2888)先**缓存最后一份资源统计**(CPU/内存峰值/IO,2839-2846,
unit 停止后 systemd-cgls/top 还能显示),摘除 `bpf_restrict_fs` LSM map 项(2850-2852)、
把 cgroup_id 从 NFT set 删掉(2854、1337-1374),再 `cg_trim` 删整棵子树(2858);
用户管理器删不掉时回退请系统 PID 1 代删(2860-2863)。真正"松手"由
`unit_maybe_release_cgroup` 把关:**仅当子树递归为空才释放路径并移除反查表项**
(2765-2787)——D 状态进程导致 cgroup 暂不可删时保持追踪,晚点再清(2773-2776)。
unit 对象析构时 `unit_release_cgroup` 清 `cgroup_unit` 反查与两个 inotify watch
(2713-2746),unit_free 里还会先给 slice 家族补一次 realize 队列(mask 退化,src/core/unit.c:822-832)。
根 slice 的 cgroup 永不删除(2856、2875-2876)。

## 7. BPF 家族:挂在 unit cgroup 上的六七个 prog

支持性在启动时探测并并入 `cgroup_supported`(src/core/cgroup.c:3256-3291、3376-3381);
属性阶段按 mask 安装(src/core/cgroup.c:1622-1637):

- **bpf-devices**(DeviceAllow=/DevicePolicy=):传统 devices 控制器的替代,
  cgroup 级 `BPF_CGROUP_DEVICE` prog、`BPF_F_ALLOW_MULTI`,默认闭/严格模式由指令序列表达
  (src/core/bpf-devices.c:192-256,挂载点 244)。
- **bpf-firewall**(IPAddressAllow/Deny、IPAccounting=、IP{In,E}gressFilterPath=):
  自编译 prog 挂 `cgroup/{inet_egress,inet_ingress}`,自定义 prog 以同类型叠加
  (src/core/bpf-firewall.c:714-743);父 slice 的 IP 访问列表会传染给子孙
  (src/core/cgroup.c:1659-1668);另有 NFTSet= 把 cgroup_id 塞进 nftables set(1337-1374)。
- **bpf-foreign**(BPFProgram=):把**别人** pin 在 bpffs 上的 prog 按 attach_type 原样
  attach 到本 cgroup,路径必须是 BPF_FS_MAGIC(src/core/bpf-foreign.c:94、68、143-160)。
- **bpf-socket-bind**(SocketAddressBind=/RestrictAddressFamilies 的 bind 面):
  `cgroup/bind4`+`cgroup/bind6` 两个 prog(src/core/bpf-socket-bind.c:197-203;
  src/bpf/socket-bind.bpf.c:98、106)。
- **bpf-restrict-ifaces**(RestrictNetworkInterfaces=):`cgroup_skb/{egress,ingress}`
  校验出口/入口 ifindex(src/core/bpf-restrict-ifaces.c:131-136;src/bpf/restrict-ifaces.bpf.c:42、47)。
- **bpf-bind-iface**(BindNetworkInterface=):`cgroup/sock_create` 上给套接字绑定设备
  (src/core/bpf-bind-iface.c:100;src/bpf/bind-iface.bpf.c:12)。
- **bpf-restrict-fs**(RestrictFileSystems=):**LSM** BPF `lsm/file_open`,按 cgroup_id 查
  哈希表放行/拒绝(src/core/bpf-restrict-fs.c:74;src/bpf/restrict-fs.bpf.c:37-39)。
  它不走 cgroup attach,所以在 exec 最晚期才装(src/basic/cgroup-util.h:27-29)。
  同族的 bpf-restrict-fsaccess(verity 完整性)亦为 `lsm.*` hook 集
  (src/bpf/restrict-fsaccess.bpf.c:209、221 等)。

## 8. systemd 为什么必须坐在统一层级的根上

`manager_setup_cgroup` 的八步开场(src/core/cgroup.c:3293-3389):
1. 用自身 PID 0 反查 cgroup 路径作为 `cgroup_root`,若已在 init.scope 里则截掉后缀
   (3298-3311)——**管理器的坐标系 = 它所在 cgroup 子树的根**;
2. `open("/sys/fs/cgroup", O_PATH)` 钉住 cgroupfs,防止被 umount 掉(3313-3317);
3-4. 建 empty defer 源与 inotify 源(3319-3357);
5. 在根下创建 `init.scope` 并把 PID 1 挪进去,再把散落在根 cgroup 的**其余所有用户态进程**
   一并迁入(3359-3366)——保证根目录干净、一切进程皆可归入某个 unit;
6. 以自己的根探测可用控制器 `cg_mask_supported_subtree`(3372-3374)。
这解释了 v2 一致性要求:systemd 要用"目录树=unit 树"这一唯一真相来回答"这个 PID 属于哪个
unit""还剩哪些进程""用了多少资源",前提是它看到的整棵子树里没有第三方乱开的
`+ctrl`/子 cgroup;而 v1 的每控制器多棵树让"路径→unit"的反查存在多义性,这也是
systemd 258 起在纯 v2 上才全力推进 BPF/PSI 等 v2-only 特性的根因。

## 9. 统计、防失控与默认值

- 进程数防失控:TasksMax= 写 `pids.max`(1611-1619);默认值链:`DefaultTasksMax`
  (src/core/main.c:901)→ `unit_init` 时灌入非 slice unit 的 `cc->tasks_max`
  (src/core/unit.c:182-183);读取侧 `unit_get_tasks_current`(src/core/cgroup.c:3603)。
- accounting 开关默认值:同在 `unit_init` 从 manager defaults 复制
  io/memory/tasks/ip 四项(src/core/unit.c:177-180);配置入口是
  `Default{IO,IP,Memory,Tasks}Accounting`(src/core/main.c:896-900)。
  **CPUAccounting 已被废**:gperf 表标记 DISABLED_LEGACY
  (src/core/load-fragment-gperf.gperf.in:219),因为 v2 的 `cpu.stat` 恒在,无需开关
  (MemoryAccounting=:226、IOAccounting=:245、TasksAccounting=:260、IPAccounting=:265)。
- 统计读取:CPU `cpu.stat`(3624-3685)、内存 `memory.current/peak` 等
  (3538-3601)、IO `io.stat`(3778-3905)、IP 走 BPF map(3687-3727、bpf-firewall.c:748)。
- 序列化:cgroup_runtime_serialize 把 path/mask/inotify wd/cgroup_id 存盘,
  重执行后 `unit_cgroup_catchup` 重放事件(src/core/cgroup.c:4323-4444、4020-4033)。
- freezer:`cgroup.events` 的 `frozen` 位驱动(src/core/cgroup.c:3203-3207、4082-4114)。

## 10. 设计动机

1. **cgroup 是真相之源**:进程表可撒谎(daemonize、double-fork、PID 复用),`/proc/<pid>/cgroup`
   不会;归属、存活("cgroup 非空即活着")、资源消耗、kill 目标集合全部取自内核单点,
   SIGCHLD 只是更快的先行通知(cgroup.c:3325-3327)。
2. **按 unit 一 cgroup**:控制粒度、统计粒度、生命周期粒度三者天然对齐;service 停止 =
   删目录 = 所有进程必然已死,不存在"漏网的孤儿",也无法被进程自行逃避。
3. **slice 层级**:资源是树形分配的,unit 树直接复用 cgroup 树,免去第二棵管理层级;
   slice 让"一类服务共享预算/上限"(system.slice、user-1000.slice)以及
   DisableControllers= 的子树切割成为一行配置。
4. **empty/OOM 事件联动**:把"cgroup 变空""内核 OOM""oomd 击杀"都收敛成 manager 的
   事件源,unit 状态机才可能同时具备秒级反应(SIGCHLD 优先)与完备兜底(inotify),
   并把失败原因(OOM)写进 unit 的最终状态与日志。
5. **BPF 替代旧 iptables/devices 控制器**:iptables 按包过滤无法按 cgroup 归账,
   devices 控制器在 v2 已消失;挂进 cgroup 的 prog 让"每个 unit 自己的防火墙/设备白名单/
   bind 限制"成为可能,且 BPF_F_ALLOW_MULTI 允许多层叠加、由内核保证子树不被父级绕过。
6. **委派边界 + xattr 公告**:Delegate= 把子树控制权(而不是责任)交出去,systemd 只守
   边界不越界写;用 `user.delegate` 等 xattr 在 cgroup 对象上携带元数据,让无特权客户端
   也能读出"这片子树归谁管"。
7. **根上不留人**:init.scope 收编游离进程,保证"任意 PID → 唯一 unit"的反查永远成立,
   这是把 cgroup 当数据库索引用的先决条件。

## 11. 写作素材清单(文件:行号)

1. src/core/cgroup.c:1934-1965 —— cgroup 路径默认推导(slice 链 + 转义 + root slice 特判)
2. src/basic/cgroup-util.c:1310-1376 —— `cg_slice_to_path`:`user-1000.slice` 的 dash 展开
3. src/basic/cgroup-util.c:1236-1308 —— `cg_needs_escape`/`cg_escape`:与内核文件名冲突的转义
4. src/core/cgroup.c:1717-1915 —— own/members/siblings/target/enable/disable 七种 mask 的全部推导
5. src/shared/cgroup-setup.c:379-465 —— `cg_enable`:`cgroup.subtree_control` 的 +/- 写入与 EBUSY 语义
6. src/core/cgroup.c:2443-2563 —— enable 广度优先/disable 深度优先的图解注释与实现
7. src/core/cgroup.c:2110-2193 —— `unit_update_cgroup`:create/watch/enable/apply 全流程 + delegate 边界
8. src/core/cgroup.c:1477-1637 —— `cgroup_context_apply`:属性→内核文件的完整映射(含根例外)
9. src/core/cgroup.c:1023-1049、1561-1567、4073-4080 —— Startup* 启动期权重切换闭环
10. src/core/cgroup.c:2011-2108、3213-3254 —— 两个 inotify watch 与总入口
11. src/core/cgroup.c:2938-2972、3177-3211 —— empty 事件链(populated/frozen 判定与分发)
12. src/core/cgroup.c:3057-3107、3006-3055 —— 内核 OOM 与 systemd-oomd 击杀的检出
13. src/core/cgroup.c:2828-2888、2765-2787 —— prune/释放链(先缓存统计、递归空才松手)
14. src/core/cgroup.c:3293-3389 —— `manager_setup_cgroup`:根坐标系、pin cgroupfs、init.scope 收编
15. src/core/service.c:4626-4695、src/core/scope.c:566 —— cgroup 空→服务状态机分流
16. src/core/unit.c:177-187 + src/core/main.c:895-915 —— accounting/TasksMax 默认值注入链(CPUAccounting 已废:src/core/load-fragment-gperf.gperf.in:219)
17. src/core/bpf-devices.c:244 / bpf-firewall.c:714-731 / bpf-foreign.c:94 / bpf-socket-bind.c:197-203 / bpf-restrict-ifaces.c:131-136 / bpf-bind-iface.c:100 / bpf-restrict-fs.c:74 —— 七个 BPF prog 及挂载点

(完)
