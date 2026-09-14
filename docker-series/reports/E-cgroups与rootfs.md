# E — runc 的 cgroups 管理与 rootfs 挂载：容器隔离的"资源面"与"文件面"

> 源码：runc commit `579be22`（`579be222cf3ea2c79786eb107a75796c0b782040`，1.5.0-rc.1+dev）。
> 本文所有 `文件:行号` 均为该 commit 下仓库相对路径，行号经 grep/Read 实际核对。
> **重要路径说明**：该版本中 cgroups 管理代码已抽成独立模块 `github.com/opencontainers/cgroups`（v0.1.0），以 vendor 形式存在于 `vendor/github.com/opencontainers/cgroups/`（见 `go.mod:19`）；libcontainer 下不再有 `cgroups/` 目录。v1/v2 文件布局为：接口 `cgroups.go`、选择逻辑 `manager/new.go`、v2 fs 驱动 `fs2/`、v1 fs 驱动 `fs/`、systemd 驱动 `systemd/`、设备过滤 `devices/`。
> 前情提要：D 报告已讲 `runc create/start` 旅程与 nsexec 重执行，本文不再重复；本章聚焦两个"面"——cgroups（资源上限）与 rootfs（文件视图）。

---

## 1. 全景：资源隔离的三个面与创建时序

一个运行中的容器由三个正交的机制撑起：

```
                    ┌─────────────────────────────────────────────┐
                    │              Linux 容器 = 三层面              │
                    └─────────────────────────────────────────────┘

  ① namespace 视角面(D章)      ② cgroups 资源面(本章)      ③ rootfs 文件面(本章)
  ┌──────────────────┐        ┌──────────────────┐        ┌──────────────────┐
  │ pid/mnt/net/uts  │        │ cpu  cpu.max     │        │ overlayfs 挂载    │
  │ ipc/user/time/ns │        │ mem  memory.max  │        │ /proc /sys 重挂   │
  │ "你能看见什么"     │        │ pids pids.max    │        │ bind 卷与设备节点  │
  │                  │        │ io   io.max      │        │ pivot_root 换根   │
  │                  │        │ devices: eBPF过滤 │        │ masked/readonly   │
  └──────────────────┘        └──────────────────┘        └──────────────────┘
   回答"进程在哪里"              回答"能用多少"                回答"世界长什么样"
```

创建时序（`runc create` 一侧，坐标对齐 D 报告的旅程图）：

```
 runc create
   │ factory_linux.go:58   manager.New(config.Cgroups)      ← 创建 Manager 对象(未落盘)
   │ factory_linux.go:69   检查目标 cgroup 不存在或为空
   ▼
 [cgroup 落盘 + PID 挂接]  process_linux.go:826  Apply(p.pid())
   │                       （写 cgroup.procs，早于向 init 发 bootstrap 数据）
   ▼
 [nsexec 三阶段重执行 → runc init 进程进入新 namespace]        (D 章, 略)
   ▼
 [rootfs 挂载]            standard_init_linux.go:91  prepareRootfs()
   │                       rootfs_linux.go:170  逐条挂 mounts → /dev → hooks
   │                       rootfs_linux.go:1147 pivot_root 换根
   │                       standard_init_linux.go:116 finalizeRootfs() 只读化
   │                       standard_init_linux.go:138 readonlyPaths/maskPaths
   ▼
 [resources 应用]          process_linux.go:1018 procHooks 阶段 manager.Set()
   ▼
 [exec 用户进程]           (容器进入 created → running, C 章已述)
```

两处顺序刻意为之：**Apply 先于 init 醒来**（`libcontainer/process_linux.go:823-826` 注释："Do this before syncing with child so that no children can escape the cgroup"——进程一出生就在 cgroup 里，不存在先入 namespace 再被挪进 cgroup 的空窗）；**Set 晚于 cgroup 创建、早于 prestart hook**（`process_linux.go:1017` 注释："Setup cgroup before prestart hook, so that the prestart hook could apply cgroup permissions"）。

---

## 2. Manager 抽象：一个接口、四个实现

### 2.1 接口方法表

`vendor/github.com/opencontainers/cgroups/cgroups.go:26-86` 定义 `Manager` 接口：

| 方法 | 行号 | 语义 |
|---|---|---|
| `Apply(pid)` | :30 | 创建 cgroup 并把 pid 放入；`-1` 表示仅创建 |
| `AddPid(sub, pid)` | :35 | 向已有 cgroup（或其子组）加进程，exec 场景用 |
| `GetPids` / `GetAllPids` | :38/:42 | 直属进程 / 含子组的全部进程 |
| `GetStats` / `Stats` | :45/:48 | 统计；`Stats` 可按 controller 位掩码过滤 |
| `Freeze(state)` | :51 | freezer（v2 即 `cgroup.freeze`） |
| `Destroy` | :54 | 删除 cgroup |
| `Path(subsys)` | :58 | v1 按 controller 名取路径；v2 忽略参数 |
| `Set(r)` | :63 | 应用资源限制；nil 表示沿用上次 |
| `GetPaths` | :73 | v1 返回 {controller: path}，v2 返回 {"": 统一路径}（持久化进 state.json） |
| `Exists` / `OOMKillCount` | :82/:85 | 存在性；OOM 击杀计数 |

接口上方有两个可注入钩子 `DevicesSetV1`/`DevicesSetV2`（`cgroups.go:22-23`）：cgroups 库本身不实现设备规则，由 `devices` 包的 `init()` 注入（`devices/devices.go:12-15`），这样"不需要设备管理的使用者可以零 BPF 依赖"。

### 2.2 v1/v2 与 systemd/fs 的选择逻辑

选择点在 `vendor/github.com/opencontainers/cgroups/manager/new.go:29-55`：

```go
func NewWithPaths(config *cgroups.Cgroup, paths map[string]string) (cgroups.Manager, error) {
        ...
        if config.Systemd && !systemd.IsRunningSystemd() {        // :33
                return nil, errors.New("systemd not running on this host, ...")
        }
        // Cgroup v2 aka unified hierarchy.
        if cgroups.IsCgroup2UnifiedMode() {                       // :38
                ...
                if config.Systemd {
                        return systemd.NewUnifiedManager(config, path)   // :44
                }
                return fs2.NewManager(config, path)                      // :46
        }
        // Cgroup v1.
        if config.Systemd {
                return systemd.NewLegacyManager(config, paths)           // :51
        }
        return fs.NewManager(config, paths)                              // :54
}
```

判别 v2 的依据是**文件系统魔数**而非内核版本：`IsCgroup2UnifiedMode()` 对 `/sys/fs/cgroup` 做 `statfs`，`CGROUP2_SUPER_MAGIC` 即统一层级，结果用 `sync.Once` 缓存（`cgroups/utils.go:34-51`）；hybrid 模式则探测 `/sys/fs/cgroup/unified`（`utils.go:53-69`）。2×2 矩阵即四种实现：

| | 直接写 cgroupfs | 经 systemd dbus |
|---|---|---|
| **v2** | `fs2.Manager` | `systemd.UnifiedManager` |
| **v1** | `fs.Manager` | `systemd.LegacyManager` |

`Manager` 在 `factory_linux.go:58`（Create 时 `manager.New`）与 `factory_linux.go:129`（Load 时 `NewWithPaths`，复用 state.json 里存的路径）两处构造，随后存入 `Container.cgroupManager`（`factory_linux.go:98`）。

Create 时还有两道前置体检：目标 cgroup 要么不存在要么为空（`factory_linux.go:69-78`），且未处于 Frozen 态（`factory_linux.go:82-88`）——后者防止把新容器挂进一个被 `runc pause` 冻住的旧 cgroup。

---

## 3. cgroups v2 专节：统一层级下的两种驱动

### 3.1 统一层级的落地：CreateCgroupPath

v2 的"统一"意味着只有一个挂载点 `/sys/fs/cgroup`（`fs2/defaultpath.go:31`），所有 controller 挂在同一棵树下，靠 `cgroup.controllers` / `cgroup.subtree_control` 逐级"放行"。`fs2/create.go:71-150` 的 `CreateCgroupPath` 就是这个逐级放行的实现：

```go
ctrs := strings.Fields(content)
res := "+" + strings.Join(ctrs, " +")                    // :85-86  "+cpu +memory +pids ..."
elements := strings.Split(path, "/")
...
        if i < len(elements)-1 {                          // :137
                if err := cgroups.WriteFile(current, cgStCtlFile, res); err != nil {
                        // try write one by one           // :139-142  逐个 controller 兜底
                }
        }
```

它还处理 v2 特有的 domain/threaded 纠缠：若途经的 cgroup 因"组内还有进程"而处于 `domain invalid`，配置了 domain controller（memory/io/cpu/hugetlb，见 `create.go:66-68`）则直接报错，否则降级写 `threaded`（`create.go:107-134`）。默认路径推导在 `fs2/defaultpath.go:33-56`：显式 `Cgroups.Path` 优先；否则解析 `/proc/self/cgroup` 的 `0::` 行（`defaultpath.go:68-80`），并**上跳一级**（`defaultpath.go:53`）——因为当前 cgroup 里已有 runc 自己的进程，v2 禁止"有进程的组再开 subtree_control"，父目录才是安全落点。

### 3.2 fs 驱动（fs2）：Set 的应用链

`fs2/fs2.go:65-85` 的 `Apply` = `CreateCgroupPath` + `WriteCgroupProc`（把 pid 写进 `cgroup.procs`），rootless 且无显式路径时返回可忽略的 `ErrRootless`（`fs2.go:71-79`）。资源应用全在 `Set`（`fs2/fs2.go:213-267`），顺序固定：

```
pids(:221) → memory(:225) → io(:229) → cpu(:233) → devices(:241)
→ cpuset(:247) → hugetlb(:251) → rdma(:255) → freezer(:259) → Unified 通配 map(:262)
```

每个 setXXX 只在对应字段非零时写文件，例如 memory（`fs2/memory.go:35-78`）：`memory.swap.max` → `memory.max` → `memory.low`；`-1` 统一翻译成 v2 的 `"max"`（`numToStr`，`memory.go:21-29`）。注意两点 v1/v2 语义差异都做了兼容：v2 的 swap 不含 memory（统计时重新合并，`memory.go:120-131`），且 v2 天然层级化（`UseHierarchy=true` 硬编码，`memory.go:100-102`）。`Resources.Unified` map 是逃生舱：任意 `CONTROLLER.PARAMETER` 原样写入（`fs2.go:279-302`），controller 不存在时报"controller not available"而非模糊 EPERM。

更新前还有一道 `CheckMemoryUsage`（`fs2/fs2.go:335-365`）：读 `memory.current`，若新 limit ≤ 当前用量直接拒绝——防止把运行中容器改小内存后立刻 OOM。

### 3.3 systemd 驱动（v2）：dbus 属性翻译 + fs 兜底

`systemd/v2.go:27-34` 的 `UnifiedManager` 内嵌一个 `fsMgr`（`NewUnifiedManager` 于 `v2.go:36-53` 组装），形成"systemd 管单位属性、fs2 管剩余 cgroupfs 文件"的双层结构：

- **Apply**（`systemd/v2.go:290-390`）：拼一个 `.scope` 单元（默认命名 `ScopePrefix-Name.scope`，`systemd/common.go:100-106`；rootless 落 `user.slice`，`v2.go:297-300`），带 `Delegate=true`（`v2.go:314`）、`PIDs=[pid]`（`v2.go:319`）、四个 `*Accounting=true`（`v2.go:324-329`，注释明言为了与 fs 驱动行为对齐）；dbus `startUnit` 之后**仍要** `fs2.CreateCgroupPath`（`v2.go:360-366`）——scope 的目录由 systemd 建，但 subtree_control 放行仍需 runc 自己做。OwnerUID 场景还按 `/sys/kernel/cgroup/delegate` 清单 chown（`v2.go:368-414`）。
- **Set**（`v2.go:524-541`）：先 `genV2ResourcesProperties` 把资源翻成 systemd 属性（`MemoryMax/MemoryLow/MemorySwapMax`：`v2.go:221-237`；`CPUWeight`/`CPUQuota`：`v2.go:241-256`；`TasksMax`：`v2.go:258-269`；`AllowedCPUs`/`AllowedMemoryNodes` 需 systemd ≥244：`v2.go:133-151`），`setUnitProperties` 下发后再调 `fsMgr.Set` 兜底——凡是 systemd 不认识的键都留给 cgroupfs（`v2.go:190-193`）。
- `Resources.Unified` map 也会尽力翻译：`unifiedResToSystemdProps`（`v2.go:72-198`）认得 `cpu.max`、`memory.max`、`pids.max` 等，未知键 debug 日志后跳过。
- **Destroy**（`v2.go:426-443`）：`stopUnit` + `fsMgr.Destroy`，注释点出 systemd 239 不回收子 cgroup 的坑（`v2.go:435`）。

版本门控常量在 `v2.go:22-25`：`cpu.idle` 需 systemd ≥252、`OOMPolicy` 需 ≥253。

### 3.4 devices：v2 用 eBPF，v1 用文件

v2 没有 devices controller，runc 改用挂到 cgroup 上的 `BPF_PROG_TYPE_CGROUP_DEVICE` 程序。注入点 `devices/v2.go:54-73`：

```go
func setV2(dirPath string, r *cgroups.Resources) error {
        if r.SkipDevices { return nil }
        insts, license, err := deviceFilter(r.Devices)                  // :58  生成 BPF 指令
        ...
        dirFD, err := unix.Open(dirPath, unix.O_DIRECTORY|unix.O_RDONLY|unix.O_CLOEXEC, 0o600)
        ...
        if err := loadAttachCgroupDeviceFilter(insts, license, dirFD); err != nil {
                if !canSkipEBPFError(r) { return err }                  // :67-70
        }
        return nil
}
```

`deviceFilter`（`devices/devicefilter.go:26-68`）先过一遍 **emulator**（`devicefilter.go:32-38`）把 OCI 规则化简成最小规则集——注释明言这是为了让 v2 的设备过滤行为与 v1 **完全一致**（包括防止在通配规则里"打洞"的安全加固）；再逐条编译成指令：`init` 从 `bpf_cgroup_dev_ctx` 取 type/access/major/minor 到 R2-R5（`devicefilter.go:76-101`），`appendRule` 生成 `JNE` 比较链，命中即返回 allow/deny（`devicefilter.go:107-180`），末尾 fallback 返回 `defaultAllow`（`devicefilter.go:182-195`）。加载附着在 `devices/ebpf_linux.go:335-340`。userns 内通常无 bpf(2) 权限，`canSkipEBPFError`（`devices/v2.go:30-52`）允许在"全为 allow+rwm 规则"时容忍失败——因为 rootless 也 mknod 不了危险设备。

**v1 对照**：同一个 `r.Devices` 规则集在 v1 走 `DevicesSetV1`（`devices/devices.go:13`），写 `devices.deny`/`devices.allow` 文件；v1 fs 驱动把 devices 列为强需求——路径不存在直接报错（`fs/devices.go:33-36`："devices cgroup is a hard requirement for container's security"），而 `fs.Manager.Exists()`/`GetPids()` 也都以 devices 子系统的路径为准（`fs/fs.go:271-277, 299-301`）。systemd 驱动下 systemd 自己也会挂一份设备 eBPF 程序，runc 再挂自己的（`systemd/v2.go:210-219`，注释承认"两份相同规则的程序不算灾难但值得担忧"）。

### 3.5 v1 简短对照

v1 的世界是"每 controller 一个层级"：`fs/fs.go:17-33` 硬编码 15 个 subsystem 顺序表，`initPaths` 为每个 controller 算出独立路径（`fs/paths.go:17-46`），`Apply`/`Set` 就是双重循环遍历写文件（`fs/fs.go:111-144, 220-251`）。hybrid 模式会追加一个名为 `""` 的伪 controller 以便同时加入 v2（`fs/fs.go:37-43`）。systemd v1 驱动 `LegacyManager` 不支持 rootless、不支持 `Unified` map（`systemd/v1.go:24-31`），资源设置大部分仍委托给 fs 包，仅少数属性走 dbus。

---

## 4. rootfs 专节：libcontainer/rootfs_linux.go

文件共 1544 行，主体是 init 进程内执行的 `prepareRootfs`/`finalizeRootfs`（调用点 `libcontainer/standard_init_linux.go:91, 116`）。

### 4.1 mounts 的顺序：不排序，就是 spec 顺序

runc 自己**不做 mount 排序**：`specconv.CreateLibcontainerConfig` 按 `spec.Mounts` 出现顺序逐条转换（`libcontainer/specconv/spec_linux.go:416-422`），`prepareRootfs` 再按 `config.Mounts` 顺序逐条挂（`rootfs_linux.go:192-196`）。OCI runtime-spec 规定必须按列表顺序挂载，因此"`/proc`、`/sys` 先于 bind 卷"是 spec 生成者（Docker/containerd）的责任。唯一内建的顺序敏感性在 `/dev`：`needsSetupDev` 检查用户是否把别的东西 bind 到了 `/dev` 上，若是则跳过 runc 的默认 `/dev` 布置（`rootfs_linux.go:90-98`）。

每条 mount 的翻译在 `specconv/spec_linux.go:641-684` 的 `createLibcontainerMount`：`parseMountOptions`（`:1136`）把 OCI 选项字符串翻成 syscall flag——`mountFlags` 映射表（`spec_linux.go:73-108`，`"ro"→MS_RDONLY`、`"nosuid"→MS_NOSUID`……布尔取反项如 `"rw"` 带 `clear:true` 记入 `ClearedFlags`）、传播选项表（`:62-70`，`rprivate`→`MS_PRIVATE|MS_REC` 等）、`idmap/ridmap` 复杂选项（`:144`）。bind 类型强制 `Device="bind"`（`spec_linux.go:653-657`），并拒绝含 null 字节的字段（`:677-681`，netlink 序列化无 null 终止，这是注入防御）。

### 4.2 挂载主循环与 procfs 防线

`mountToRootfs`（`rootfs_linux.go:610-792`）按 `Device` 分派：

- **proc/sysfs 特判**（`rootfs_linux.go:620-652`）：先 `checkProcMount` 再挂，防止"穿过 symlink 挂载"这一历史攻击面。`checkProcMount`（`rootfs_linux.go:840-903`）禁止任何挂载盖住 `/proc`（唯一例外是源本身为 procfs 的 bind，`:850-876`），`/proc` 子树仅放行 lxcfs 类白名单文件（`:880-891`：cpuinfo/meminfo/stat/swaps/uptime/loadavg/slabinfo/ns_last_pid/fips_enabled 等 10 项）。
- **bind**（`rootfs_linux.go:675-783`）：先 `mountPropagate` 完成 bind，再单独 `MS_BIND|MS_REMOUNT` 应用用户 flag（`:690-718`）——内核语义是初始 bind 不改 mount 选项；失败时回退读 `statfs` 取"锁定 flag"重试（`:730-778`），无法清除锁定 flag 则报错而非静默偏离用户请求。
- **tmpfs copyup**（`rootfs_linux.go:436-492`）：`EXT_COPYUP` 时在宿主 `/tmp` 建私有 bind（`prepareTmp`，`:307-319` 设为 private 以便 MS_MOVE）、把容器内目录内容拷上去、`MS_MOVE` 移入容器。
- **cgroup 挂载进容器**（`:784-788` 分派）：v2（`rootfs_linux.go:398-434`）直接挂 `cgroup2`；userns 且未隔离 cgroupns 时会 EPERM/EBUSY，退化为 bind `/sys/fs/cgroup`（`:407-422`，cgroupns 开启时 bind 的正是容器自己的 cgroup 路径 `c.cgroup2Path`，该值来自父进程 `libcontainer/container_linux.go:782`）；rootless 再失败就 `maskDir` 盖掉（`:423-432`）。v1（`:326-397`）先垫一层 tmpfs，再逐 controller bind，合并挂载的 controller 做符号链接（`:385-395`）。

安全基建：所有挂载经 `mountViaFds`（`libcontainer/mount_linux.go:158`）以 fd 对操作，避免 /proc 路径竞态；idmapped 或宿主侧无法 stat 的 bind 源由 init 经 socket 向父进程 runc 请求 `open_tree` 风格的 mountfd（`rootfs_linux.go:114-165` 的 `procMountPlease`/`procMountFd` 握手）。设备节点在 userns 下不可 mknod，自动降级为 bind mount 宿主节点（`rootfs_linux.go:957-1012`，EPERM 同样降级）。

### 4.3 换根三部曲：pivot_root 为主

三分支选择在 `rootfs_linux.go:234-240`：`NoPivotRoot → msMoveRoot`；有 mount namespace → `pivotRoot`；都没有 → `chroot`。

**prepareRoot 的铺垫**（`rootfs_linux.go:1107-1121`）：先把 `/` 重挂为 `MS_SLAVE|MS_REC`（或用户指定 `RootPropagation`），再把 rootfs 的父挂载设为 private/slave——`rootfsParentMountPropagation`（`:1082-1105`）沿目录向上找 mountpoint 逐个设置；注释给出两条硬理由（`:1077-1082`）：`pivot_root()` 遇 shared 父挂载会失败；bind rootfs 时若父挂载 shared，新挂载会传播"泄漏"回宿主命名空间。最后把 rootfs 自身 `MS_BIND|MS_REC` 一遍（`:1120`）。

**pivotRoot**（`rootfs_linux.go:1147-1196`）用了经典的 `pivot_root(".", ".")` 技巧（注释致谢 LXC 开发者，`:1152`）——无需在 rootfs 里预建 `oldroot` 目录：

```go
oldroot, err := linux.Open("/", unix.O_DIRECTORY|unix.O_RDONLY|unix.O_PATH, 0)  // :1154
...
unix.PivotRoot(".", ".")                        // :1165  新根=容器, 旧根只活在 cwd 里
unix.Fchdir(oldroot)                            // :1174  防御性回到旧根
mount("", ".", "", unix.MS_SLAVE|unix.MS_REC, "") // :1183  旧根 rslave：umount 不外溢宿主
unmount(".", unix.MNT_DETACH)                   // :1187  摘掉旧根(懒惰卸载)
unix.Chdir("/")                                 // :1192  回到新根
```

旧根的处置要点是 **rslave 而非 rprivate**（`:1178-1182` 注释）：rprivate 下的卸载传播曾与 devicemapper 在宿主侧并发操作发生竞态。**msMoveRoot**（no-pivot 兜底，`:1198-1259`）因 chroot 不隔离 mount namespace、宿主 procfs 仍可达，需先把命名空间内所有"全量" procfs/sysfs 挂载逐个 `MNT_DETACH`（无权限则 tmpfs 盖住，`:1229-1252`），再 `mount(rootfs, "/", MS_MOVE)` + `chroot`（`:1255-1258`）。`rootfsPropagation` 由 specconv 映射（`spec_linux.go:441-445`），且 `NoPivotRoot + private` 组合被判不安全直接拒绝（`:444-445`）；pivot 之后若用户指定了 shared 等传播旗标，会在新根上补挂（`rootfs_linux.go:252-256`，注释解释为何必须在 pivot 之后：过早设置会污染宿主 mount namespace）。

### 4.4 finalize：只读化与 masked paths

`finalizeRootfs`（`rootfs_linux.go:277-304`）在 pivot 前由 init 调用（`standard_init_linux.go:115-119`）：tmpfs 与 `/dev` 此前被刻意以 rw 挂（`mountPropagate` 里剥掉 MS_RDONLY，`rootfs_linux.go:1499-1501`，因为还要建设备节点），此刻统一 `remountReadonly`（`rootfs_linux.go:1294-1317`，利用内核 `MS_REMOUNT|MS_BIND` 允许无特权改 flag 的特性，EBUSY 重试 5 次）；`Readonlyfs` 则对 `/` 整体 `setReadonly`（`:1123-1136`）。**readonlyPaths/maskPaths 的执行点在 init 侧、pivot 之后**（`standard_init_linux.go:138-146`）：

- `readonlyPath`（`rootfs_linux.go:1272-1291`）：bind 自身再 remount ro，保留原 nosuid/nodev/noexec。
- `maskPaths`（`rootfs_linux.go:1352-1448`）：文件用 `/dev/null` bind 盖住（`:1435-1439`，先 `verifyDevNull` 校验确是真 /dev/null），目录盖只读 tmpfs（`maskDir`，`:1334-1345`，`nr_blocks=1,nr_inodes=1`，Ubuntu 5.4 内核需退到 2）；多个目录共享同一份 tmpfs 源以省开销（`:1405-1434`），配合 `reopenAfterMount`（`:1450-1486`）在重开后校验 inode 未被调包。masked/readonly 的默认清单来自 OCI spec 的 `linux.maskedPaths`/`readonlyPaths`，这就是容器里"看不到宿主 `/proc/acpi`、`/proc/kcore`"的机制。

---

## 5. OOM 专节：从 memory.events 到 shim 的事件流

**判定源**：v2 是 `memory.events` 里的 `oom_kill` 计数——`fs2.Manager.OOMKillCount` 经 `GetValueByKey(path, "memory.events", "oom_kill")` 读取（`fs2/fs2.go:322-324`）；v1 对应 `memory.oom_control` 的 `oom_kill`（`fs/fs.go:303-305`）。

**事件监听**（runc 内建）：`notifyOnOOMV2`（`libcontainer/notify_v2_linux.go:83-85`）用 inotify 盯两个文件（`registerMemoryEventV2`，`notify_v2_linux.go:14-81`）：`memory.events` 有 IN_MODIFY 就读 `oom_kill`，非零即向 channel 发信号；`cgroup.events` 的 `populated` 归零则退出（v2 文件系统没有 IN_DELETE，只能这样感知容器死透）。v1 走 `cgroup.event_control` + eventfd（`libcontainer/notify_linux.go:65`）。`Container.NotifyOOM` 按 v1/v2 分派（`container_linux.go:849-859`）。这正是 C 报告所述 shim 侧 OOM 监控的底层：containerd-shim 经 runc 的这个 channel 得知 OOM，再上报 containerd 事件。

**oom_score_adj 的设置路径**（与 memory limit 互补的"优先被杀"调权）：spec 的 `process.oom_score_adj` 进入 `config.OomScoreAdj`（`specconv/spec_linux.go:593`），Create 时随 bootstrap 数据以 netlink 属性 `OomScoreAdjAttr` 下发（`container_linux.go:1176-1182`，属性号定义 `libcontainer/message_linux.go:20`），由 nsexec 阶段的 C 代码 `update_oom_score_adj` 写 `/proc/self/oom_score_adj`（`libcontainer/nsenter/nsexec.c:296-302`）——在 exec 用户进程前生效，对整个 pid namespace 继承。

**systemd 侧**：`memory.oom.group`（整组同杀）在 v2 只能在建单元时设，因此 runc 把它放进 `Apply` 而非 `Set`，翻译为 systemd `OOMPolicy=kill`（`systemd/v2.go:337-358`，注释明言"systemd 不允许对运行中的 scope 改这个"，需 systemd ≥253，`v2.go:24`）。启动失败若因 OOM，父进程还会给出专门错误前缀（`process_linux.go:800-808`）。

---

## 6. 与前作对照

- **K8s 资源模型（第一系列 07 卷）落在 cgroup 的哪里**：Pod 的 `resources.limits.cpu` → CRI → runc spec 的 `cpu.quota/cpu.period`（`specconv/spec_linux.go:898` 附近），最终写 v2 `cpu.max`；`requests.cpu` 不进 cgroup（调度器专用），仅当节点开启 `--cgroup-driver=systemd` 时以 `cpu.shares`→`cpu.weight` 的折算落地——转换函数 `ConvertCPUSharesToCgroupV2Value`（`vendor/github.com/opencontainers/cgroups/utils.go:417-425`，specconv 调用点 `spec_linux.go:892-895`）。`limits.memory` → `Memory.Max` → v2 `memory.max`（specconv `:869`）。kubelet 的 cgroup-driver=systemd 正对应本文 2.2 节矩阵的右列。
- **与 LXC/LXD**：一句即可——runc 的 `pivot_root(".",".")` 技巧直接取经自 LXC（`rootfs_linux.go:1152` 注释致谢），crun 的 eBPF 设备过滤实现也是 runc devicefilter 的注释来源（`devices/devicefilter.go:3-6`），容器运行时家族在这个层面高度同源。
- （docker 相关的卷映射、systemd 与 etcd 等无实质交集，不硬扯。）

## 7. 设计动机

1. **为什么 v2 统一层级是方向**：v1 一容器十几个层级，`Apply`/`Set`/`Destroy` 都是 N 层循环（`fs/fs.go:111-144, 220-251`），"container 是否存在"只能抽查一个 controller（`fs/fs.go:64-68` 注释承认 v1 的 `Exists()` 检查不彻底）；v2 一棵树一个路径（`GetPaths` 只有一项，`fs2/fs2.go:304-308`），删除是原子 `rmdir`，freezer 从内核 hack（v1 freezer 是独立 controller）变成通用 `cgroup.freeze` 伪 controller（`fs2/fs2.go:258`，kernel ≥5.2）。runc 甚至把 cgroups 包整体抽出为独立模块（`go.mod:19`），方便 containerd 等直接复用同一套 v2 语义。
2. **为什么 devices 用 BPF**：v2 刻意不收编 v1 的 devices controller（它需要为每次规则变更改链表并持全局锁）。`BPF_PROG_TYPE_CGROUP_DEVICE` 把判定变成挂在 cgroup 上的纯函数程序，规则更新=换程序，语义可精确复刻 v1（emulator 保证，`devicefilter.go:27-31`）；代价是 rootless/userns 下 bpf(2) 常不可用，故有 `canSkipEBPFError` 的灰度放行（`devices/v2.go:30-52`）。
3. **为什么 pivot_root 优于 chroot**：chroot 不换 mount namespace 视角下的根挂载，旧根仍可经 `/proc/self/root` 等句柄逃逸，且 msMoveRoot 兜底路径需要先"爆破"所有宿主 procfs/sysfs 挂载才能勉强安全（`rootfs_linux.go:1199-1215` 长注释）；`pivot_root(".", ".")` 让旧根只存在于 cwd 这一个句柄上，`MNT_DETACH` 一步摘净（`rootfs_linux.go:1165-1192`），不需要在 rootfs 里预建目录，也不给容器留任何指向宿主树的挂载点。而 pivot 对父挂载的 non-shared 要求，正是 `prepareRoot` 先做 rprivate/rslave 的原因（`rootfs_linux.go:1077-1082`）。
4. **为什么 Apply 要赶在 init 醒来之前**：pid 写入 `cgroup.procs` 是唯一入组手段，若 init 先跑起来，任何它 fork 的子进程都可能落在 cgroup 之外（`process_linux.go:823-826`）；配套地，`runc kill` 依赖 `GetAllPids` 枚举补刀（`init_linux.go:684` `signalAllProcesses`，调用点 `container_linux.go:453`），cgroup 就是 runc 追杀进程的"花名册"。

---

## 8. FAQ 素材

1. **`runc create` 时 cgroup 目录什么时候真正出现？** fs 驱动在 `Apply`（`process_linux.go:826` 触发）里 `CreateCgroupPath` 逐级 mkdir + 写 subtree_control（`fs2/fs2.go:66`）；systemd 驱动则在 dbus `startUnit` 时由 systemd 建 scope 目录，runc 随后补 subtree_control（`systemd/v2.go:360-366`）。`manager.New` 本身不落盘。
2. **`--systemd-cgroup` 但主机没跑 systemd 会怎样？** 直接报错 "systemd not running on this host"（`manager/new.go:33-35`），不会静默降级到 fs 驱动。
3. **rootless 能设 memory limit 吗？** 不能在"无 cgroup 权限 + 无显式 cgrouppath"时设——`Apply` 返回带指导性的错误（`fs2/fs2.go:71-79`）；devices 相关错误在 rootless 下整体忽略（`fs2.go:241-245`）。
4. **v2 下 `memory.swap` 和 v1 一样吗？** 不一样：v2 `memory.swap.max` 只计 swap（`memory.go:120-131` 统计时为兼容 v1 重新合并）；`memory+swap 相等` 表示禁 swap（`memory.go:49-52`）。
5. **`runc update` 缩小内存会立刻 OOM 吗？** runc 先读 `memory.current` 比对，新 limit ≤ 当前用量直接拒绝（`CheckMemoryUsage`，`fs2/fs2.go:335-365`；systemd 路径在生成属性前先查，`systemd/v2.go:200-206`）。
6. **容器里 `/sys/fs/cgroup` 是什么？** v2 直接挂 `cgroup2`；userns+无 cgroupns 时内核拒绝挂载，退化为 bind `/sys/fs/cgroup`（开了 cgroupns 则只 bind 容器自己的 cgroup 子树）（`rootfs_linux.go:398-422`）；rootless 彻底失败就 mask 成只读 tmpfs（`:423-432`）。
7. **为什么 bind 卷的 `ro` 有时"不生效"？** 初始 MS_BIND 继承源挂载 flag，runc 需要第二次 `MS_BIND|MS_REMOUNT`；源上被内核"锁定"的 flag（ro/nodev/nosuid/atime 族）无法清除，runc 校验后带锁重试而非静默偏离（`rootfs_linux.go:681-782`）。
8. **`--no-pivot` 为什么被 docs 警告？** chroot 后宿主 procfs/sysfs 挂载仍在同一 mount namespace 内可达，runc 只能 best-effort 地 umount/tmpfs 盖掉全部"全量" proc/sys 挂载（`rootfs_linux.go:1198-1252`），且 `rootfsPropagation=private` 与 no-pivot 组合被直接拒绝（`spec_linux.go:444-445`）。
9. **shim 怎么知道容器 OOM 了？** `NotifyOOM` → v2 inotify 盯 `memory.events`（`notify_v2_linux.go:14-92`）；另可主动轮询 `OOMKillCount`（`fs2/fs2.go:326-333`）。
10. **`oom_score_adj` 写在谁身上？** 经 netlink bootstrap 下发，由 nsexec 阶段写 `/proc/self/oom_score_adj`（`nsexec.c:296-302`），随后 exec，值被用户进程继承；与 cgroup OOM 判定无关，只影响内核选杀优先级。

## 深挖清单

1. **emulator 规则化简**（`devices/devices_emulator.go`）：v1 语义中"先 deny a 再 allow 某设备"与"直接 allow"的等价化简算法，BPF 程序体积直接取决于它——可对照 v1 `devices.list` 的增量语义写一篇。
2. **`reopenAfterMount` 与 mount fd 竞态**（`rootfs_linux.go:1450-1486` 注释）：老 mount API 下重开挂载点的 TOCTOU 窗口与 `move_mount(2)` 的根治方案，是 runc 安全演进的活样本。
3. **domain/threaded 状态机**（`fs2/create.go:107-134`）：v2 "组内有进程则不能开 subtree_control" 的根治（kernel 4.14+ threaded cgroup）在容器嵌套（rootless + systemd 用户代理）里的表现。
4. **procMountPlease 握手**（`rootfs_linux.go:114-165` + `process_linux.go:871-879` 的 mount source 服务 goroutine）：runc 1.4+ 用 open_tree 从宿主侧递 fd 解决"userns 内打不开 bind 源"与 idmapped 挂载的双问题。
5. **no-pivot 的宿主 procfs 清场**（`rootfs_linux.go:1198-1259`）：内核 `mount_too_revealing` 保护（挂 proc 前禁止被遮蔽的全量挂载存在）与 runc 侧 umount/tmpfs 兜底的攻防对应关系。

---

## 写作要点速查表

| # | 内容 | 位置 |
|---|---|---|
| 1 | Manager 接口 15 方法 | `vendor/github.com/opencontainers/cgroups/cgroups.go:26-86` |
| 2 | v1/v2+systemd/fs 四实现选择 | `vendor/github.com/opencontainers/cgroups/manager/new.go:29-55` |
| 3 | v2 判别：statfs 魔数 + sync.Once | `vendor/github.com/opencontainers/cgroups/utils.go:34-51` |
| 4 | 逐级 mkdir + `+controller` 写 subtree_control | `vendor/github.com/opencontainers/cgroups/fs2/create.go:71-150` |
| 5 | fs2 Apply（含 rootless 分支） | `vendor/github.com/opencontainers/cgroups/fs2/fs2.go:65-85` |
| 6 | fs2 Set 十步应用链 | `vendor/github.com/opencontainers/cgroups/fs2/fs2.go:213-267` |
| 7 | systemd v2 Apply（scope/Delegate/Accounting/OOMPolicy） | `vendor/github.com/opencontainers/cgroups/systemd/v2.go:290-390` |
| 8 | systemd v2 Set：dbus 属性 + fsMgr.Set 兜底 | `vendor/github.com/opencontainers/cgroups/systemd/v2.go:524-541` |
| 9 | 设备 eBPF：emulator + JNE 指令链 | `vendor/github.com/opencontainers/cgroups/devices/devicefilter.go:26-195` |
| 10 | setV2 挂 BPF（含 userns 放行） | `vendor/github.com/opencontainers/cgroups/devices/v2.go:54-73` |
| 11 | v1 subsystem 表与双重循环 | `vendor/github.com/opencontainers/cgroups/fs/fs.go:17-33, 111-144` |
| 12 | Apply 先于 init 醒来 | `libcontainer/process_linux.go:823-826`；Set 在 procHooks `:1016-1020` |
| 13 | prepareRootfs 总流程 + 换根三分支 | `libcontainer/rootfs_linux.go:170-273`（分支 :234-240） |
| 14 | pivot_root(".",".") + rslave + MNT_DETACH | `libcontainer/rootfs_linux.go:1147-1196` |
| 15 | checkProcMount 白名单 | `libcontainer/rootfs_linux.go:840-903` |
| 16 | bind 二段 remount + 锁定 flag 处理 | `libcontainer/rootfs_linux.go:675-783` |
| 17 | masked/readonly 执行点（init 侧） | `libcontainer/standard_init_linux.go:138-146`；`rootfs_linux.go:1272-1291, 1334-1448` |
| 18 | mounts 按 spec 顺序、选项翻译表 | `libcontainer/specconv/spec_linux.go:416-422, 73-108, 641-684` |
| 19 | cgroup 挂进容器（v2 bind 退化） | `libcontainer/rootfs_linux.go:398-434` |
| 20 | OOM：memory.events 读取与 inotify | `fs2/fs2.go:322-333`；`libcontainer/notify_v2_linux.go:14-92`；`container_linux.go:849-859`；oom_score_adj `nsexec.c:296-302` |
