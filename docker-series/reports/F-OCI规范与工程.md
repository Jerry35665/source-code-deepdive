# F 篇 · OCI 规范如何变成代码:runc 的规范落地与工程文化

> 源码版本:runc commit `579be22`(main 分支,VERSION 文件内容为 `1.5.0-rc.1+dev`)。
> 本文是卷一第 6 章。D/E 篇已讲过创建旅程、nsexec、cgroups 与 rootfs 挂载;本篇不复述这些流程,
> 专注两个问题:**runtime-spec 的 JSON 字段如何一步步变成内核调用**,以及 **runc 项目自身如何运转**
> (测试矩阵、CVE 响应、发布节奏、维护者模型)。

---

## 1. 全景:一个 spec 字段的旅程

runc 的命令入口从 bundle 读取 `config.json`(`utils.go:72` 的 `setupSpec`,内部 `loadSpec(specConfig)`
反序列化为 `specs.Spec`),随后在 `utils_linux.go:189` 调用 `specconv.CreateLibcontainerConfig`,
把"OCI 方言"翻译成 libcontainer 的内部方言 `configs.Config`。以 `Process.Capabilities` 和 `Mounts`
两个字段为例:

```
config.json (OCI runtime-spec, specs.Spec)          [github.com/opencontainers/runtime-spec v1.3.0, go.mod:20]
    │
    ├─ spec.Process.Capabilities ──────────────┐
    │                                          ▼
    │                     specconv.CreateLibcontainerConfig (specconv/spec_linux.go:384)
    │                     直接字段拷贝: Bounding/Effective/Permitted/Inheritable/Ambient
    │                     (spec_linux.go:597-604) → configs.Capabilities
    │                                          │
    │                                          ▼
    │                     runc init 进程内: finalizeNamespace (libcontainer/init_linux.go:300)
    │                       ├─ capabilities.New        (capabilities/capabilities.go:50)
    │                       ├─ ApplyBoundingSet        (capabilities.go:100) ← 先于 setuid 丢权
    │                       ├─ setupUser               (init_linux.go:468)
    │                       └─ ApplyCaps               (capabilities.go:110) ← setuid 之后再设全组
    │                                          │
    │                                          ▼
    │                     moby/sys/capability → capset(2)/prctl(PR_CAPBSET_DROP…) 内核调用
    │
    └─ spec.Mounts[] ──────────────────────────┐
                                               ▼
                          createLibcontainerMount (spec_linux.go:641)
                            ├─ parseMountOptions (spec_linux.go:1136): 字符串选项 → MS_* 位图
                            ├─ bind 挂载强制 Device="bind" (spec_linux.go:653-659)
                            └─ 拒绝含 NUL 字节的字段 (spec_linux.go:676-684, 防 netlink 截断)
                                               │
                                               ▼
                          configs.Mount → init 进程 prepareRootfs (rootfs_linux.go:170)
                            → mountToRootfs (rootfs_linux.go:610) → mount(2)/移动子树等内核调用
```

三个要点:

- **specconv 是唯一翻译层**:`specs.Spec`(规范词汇表)→`configs.Config`(执行词汇表),
  所有字段映射集中在一个 1327 行的文件 `libcontainer/specconv/spec_linux.go` 中,便于对照规范逐条审计。
- **翻译时校验,执行时落地**:非法值(未知命名空间、非绝对路径、含 NUL 的挂载字段、
  `[r]private + NoPivotRoot` 组合,`spec_linux.go:444-446`)在 create 阶段就报错,而不是等到 init 阶段。
- **映射表是显式的**:命名空间、挂载传播、挂载标志、mpol 模式全部是 `map[spec类型]内核常量`
  (`spec_linux.go:49-175` 的 `initMaps`,用 `sync.Once` 惰性初始化),规范新词条没有映射就报
  "does not exist",绝不静默忽略。

---

## 2. specconv 专节:主干函数与 hooks 时机

### 2.1 转换主干

`CreateLibcontainerConfig`(`specconv/spec_linux.go:384-624`)的处理顺序本身就是一份"规范字段清单":

| 行号 | 处理内容 |
| --- | --- |
| 396-399 | root.path 相对路径 → 基于 runc cwd(bundle)转绝对 |
| 416-422 | `Mounts[]` → `createLibcontainerMount`(641) |
| 424-434 | `createDevices`(1023)+ `CreateCgroupConfig`(778) |
| 439-447 | `RootfsPropagation` → `RootPropagation`,并拒绝与 NoPivotRoot 的危险组合 |
| 449-458 | `Namespaces` → `namespaceMapping`,重复条目报错 |
| 459-465 | 新 NET ns → 自动补 loopback 网络 |
| 466-483 | NEWUSER → `setupUserNamespace`(1080),idmap 挂载继承 userns 映射 |
| 484-488 | `MaskedPaths`/`ReadonlyPaths`/`MountLabel`(SELinux)/`Sysctl`/`TimeOffsets` 直拷 |
| 489-495 | `Linux.Seccomp` → `SetupSeccomp`(1195) |
| 496-547 | IntelRdt / MemoryPolicy / Personality / NetDevices |
| 550-590 | cgroup 命名空间 + 读写 cgroupfs 时,把 cgroup 属主 chown 给容器 UID(`Cgroups.OwnerUID`) |
| 592-620 | `Process.*`:OOMScoreAdj、NoNewPrivileges、Umask、**SelinuxLabel → ProcessLabel**、Scheduler、IOPriority、CPUAffinity |
| 621-622 | `createHooks`(1286);`config.Version = specs.Version` |

`CreateCgroupConfig`(`spec_linux.go:778`)单独处理 cgroups 节,systemd 属性经
`initSystemdProps`(744)生成 dbus 属性(E 篇已述,此处不展开)。

### 2.2 hooks:五个执行时机 + 一个弃用者

规范定义 6 个 hook,runc 把它们拷成 `configs.Hooks` map(`createHooks`,`spec_linux.go:1286-1314`;
每个 hook 由 `createCommandHook`(1316)转成 `configs.Command`,支持 Timeout)。hook 常量定义在
`libcontainer/configs/config.go:423-447`,统一执行入口是 `Hooks.Run`(`config.go:536`)。

| Hook | 精确执行点 | 运行命名空间 | 此刻能做什么 |
| --- | --- | --- | --- |
| `prestart`(已弃用) | `process_linux.go:1036`,与 createRuntime 同一位置、紧前执行 | runtime ns | 等价于 createRuntime,仅为兼容保留(`spec_linux.go:1289` 有 `//nolint` 注释) |
| `createRuntime` | `process_linux.go:1039`,父进程收到 init 的 `procHooks` 同步后;**之前**先做了 `p.manager.Set` 应用 cgroup 资源限制(`process_linux.go:1018`,注释明言"so that the prestart hook could apply cgroup permissions") | runtime ns | cgroup 已生效、rootfs 尚未 pivot,可配网络/NS 外资源;失败则 create 失败 |
| `createContainer` | `rootfs_linux.go:229`,在 **runc init 进程内**、已 fchdir 进新 rootfs、**pivot_root 之前**(`pivotRoot` 调用在 235 行附近) | container ns | 能看到容器文件系统视角;可改 rootfs 内文件 |
| `startContainer` | `standard_init_linux.go:285`,init 进程内、**紧贴 execve 之前**(前面刚写完 exec fifo 阻塞等 `runc start`) | container ns | 最后一次干预用户进程的机会;环境变量默认继承 init(`standard_init_linux.go:216-218`,注释承认这是"de facto 历史"而非规范) |
| `poststart` | `container_linux.go:341-361` 的 `postStart()`,由 `exec()` 读到 exec fifo 后调用(`container_linux.go:239`) | runtime ns | init 已启动;**失败会 SIGKILL 容器并 wait**(`container_linux.go:346-354`) |
| `poststop` | `state_linux.go:69-81` 的 `runPoststopHooks`,在 destroy 流程删除状态目录之后 | runtime ns | 清理外部资源(网络、卷);Status 置为 stopped |

两个工程细节值得一提:

- **checkpoint/restore 路径同样触发 createRuntime**:`criu_linux.go:1141` 在恢复时重放该 hook,
  并在 1131 行检查配置里是否同时存在 prestart/createRuntime。
- **hook 状态载荷**统一为 OCI `specs.State`(id/pid/bundle/annotations),由
  `currentOCIState` 生成;`createContainer`/`startContainer` 在 init 内执行时把 `s.Pid` 改成
  init 自身 pid、Status 置 `creating`/`created`(`rootfs_linux.go:226-228`、`standard_init_linux.go:282-284`)。

---

## 3. 安全机制落地专节

### 3.1 seccomp:libseccomp 集成 + 手改 BPF

两层结构:**spec 翻译层** `SetupSeccomp`(`spec_linux.go:1195-1284`)把 `LinuxSeccomp` 转成
`configs.Seccomp`:默认无 `DefaultAction` 且无 syscall 列表时视为禁用(1201);
flags 未显式给出时默认尝试加 `SECCOMP_FILTER_FLAG_SPEC_ALLOW`(1210-1216);
action/operator/arch 的字符串映射表在 `seccomp/config.go:15-60`。

**内核加载层** `InitSeccomp`(`seccomp/seccomp_linux.go:32-132`),构建 libseccomp filter 后
并不直接 `libseccomp.Load`,而是走 `patchbpf.PatchAndLoad`(`patchbpf/enosys_linux.go:729`):
先反汇编 filter,补丁进一段"未知 syscall 返回 ENOSYS 而非 EPERM"的 BPF stub(兼容性关键:
让旧 profile 在新内核上表现为"syscall 不存在"而不是"被拒绝"),再用裸 `seccomp(SECCOMP_SET_MODE_FILTER)`
装载(694)。规则数 >32 时启用 libseccomp 二叉树优化(`seccomp_linux.go:103-108`)。

**seccomp notify(SCMP_ACT_NOTIFY)** 一句话:action 映射在 `seccomp_linux.go:219`;要求
libseccomp API level >= 6(47);`write` 不可被 notify、notify 不可做默认 action(62-71)——否则
init 把 listener fd 写回父进程这一步自己就会被拦截,初始化死锁。父进程侧收到 `procSeccomp` 同步后
用 `pidfd_getfd` 取回 fd,再按 OCI `ContainerProcessState` 格式经 `ListenerPath` unix socket 交给
外部 agent(`process_linux.go:532-578`)。

**应用时机的双路径**(这是 runc 最著名的一处时序设计,`standard_init_linux.go:188-200` 与 239-248):

```go
// Without NoNewPrivileges seccomp is a privileged operation, so we need to
// do this before dropping capabilities; otherwise do it as late as possible
// just before execve so as few syscalls take place after it as possible.
if l.config.Config.Seccomp != nil && !l.config.NoNewPrivileges {
    seccompFd, err := seccomp.InitSeccomp(l.config.Config.Seccomp)
```

- 未开 NoNewPrivileges:装载 filter 本身需要特权,必须在丢 capabilities 之前(191);
- 开了 NoNewPrivileges(规范推荐):能拖多晚拖多晚,紧贴 execve(239),使"filter 装载之后到 execve
  之前"这段路径上的 runc 自身 syscall 尽量少,用户的 profile 就不用为它们开口子。

### 3.2 capabilities:五集合 + 精确次序

常量到内核数值的翻译交给 `moby/sys/capability`,runc 侧用 `capability.ListSupported()` 动态构建
`CAP_*` 名字表(`capabilities/capabilities.go:24-34`),不认识的 cap 只警告不报错(71-73)。
应用次序在 `init_linux.go:336-365` 的 `finalizeNamespace` 中,严格保证:

1. `ApplyBoundingSet`(`capabilities.go:100`):**setuid 之前**收窄 bounding set,防止 setuid 后
   重新获得已丢权限;
2. `system.SetKeepCaps()`:设置 keepcaps 标志;
3. `setupUser`(setuid/setgid);
4. `ApplyCaps`(`capabilities.go:110`):一次性写 effective/permitted/inheritable/bounding 四个集合
   (114-123),ambient **单独逐个设置**(133-147)——ambient 需要 permitted+inheritable 双重到位,
   且老内核 EINVAL 直接忽略以保持兼容;每颗 ambient cap 失败仅告警,保持旧行为。

`runc features` 通过 `KnownCapabilities`(`capabilities.go:38`)输出本机支持列表。

### 3.3 AppArmor 与 SELinux(简)

- **AppArmor**:runc 自带约 30 行的"极简版 libapparmor"(`libcontainer/apparmor/apparmor.go`),
  通过 `/proc/self/attr` 写入。加载点在 init 进程内、hostname/sysctl 设置之后:
  `standard_init_linux.go:131` 与 exec-in 路径 `setns_init_linux.go:120` 的 `apparmor.ApplyProfile`。
- **SELinux**:分两个 label——进程 label 来自 `Process.SelinuxLabel`,specconv 存为
  `config.ProcessLabel`(`spec_linux.go:596`),在 init 中 `selinux.SetExecLabel` 设置
  (`standard_init_linux.go:183-187`),作用于下一次 execve;挂载 label 来自 `Linux.MountLabel`
  (`spec_linux.go:486`),由 rootfs/挂载代码经 `label.SetFileLabel` 打到文件上。
  依赖是外部仓库 `github.com/opencontainers/selinux v1.15.1`(`go.mod:21`)。

---

## 4. exeseal 专节:CVE-2019-5736 与"防换绑"

**攻击模型**:容器内进程(或被攻破的应用)可通过 `/proc/<runc-pid>/exe` 这个 magic-link 拿到
宿主机 runc 二进制的可写句柄,把 runc 文件本身覆盖成恶意程序;下次任何人执行 `runc exec`
即中招。`exeseal/doc.go:2` 一句话点题:"protecting the runc binary against CVE-2019-5736-style attacks"。

**防御核心**:让 runc init 永远不引用"原始的、可被换绑的" `/proc/self/exe`。调用点在
`container_linux.go:553-575` 的 `newParentProcess`:

```go
if exeseal.IsSelfExeCloned() {
    // /proc/self/exe is already a cloned binary -- no need to do anything
    exePath = "/proc/self/exe"
} else {
    safeExe, err = exeseal.CloneSelfExe(c.stateDir)
    ...
    exePath = "/proc/self/fd/" + strconv.Itoa(int(safeExe.Fd()))
}
cmd := exec.Command(exePath, "init")
```

即:**runc init 是从一个"封印过的克隆"启动的**。克隆策略按优先级三级回退
(`exeseal/cloned_binary_linux.go:218-249` 的 `CloneSelfExe`):

1. **overlayfs 零拷贝封印**(首选,`exeseal/overlayfs_linux.go:53` 的 `sealedOverlayfs`):
   用 `fsopen("overlay")` 把原二进制所在目录作为 lowerdir、匿名 tmpfs 作为 upperdir 叠加出
   只读视图。注释明确说它"no way to unwrap"(无法像 MS_BIND+MS_RDONLY 那样被重新挂载解开),
   且几乎零开销——memfd 拷贝大二进制会让容器启动慢约 60%(219-222 行注释的实测数据)。
2. **memfd 克隆**(`cloned_binary_linux.go:65`):把 `/proc/self/exe` 拷进 memfd,再打上
   `F_SEAL_SEAL|F_SEAL_SHRINK|F_SEAL_GROW|F_SEAL_WRITE`(+可选 `F_SEAL_EXEC`,43-63 行
   `sealMemfd`)。"seal"即内核保证内容永不可写——这就是"防换绑"的本质:不是防住某条攻击路径,
   而是让 fd 本身在内核层面不可变。
3. **O_TMPFILE / 经典未链接临时文件**(`otmpfile` 85,`mktemp` 103):依次尝试多个目录、
   跳过 noexec 挂载点(124-177 的 `getSealableFile`),并 fstat 校验 `Nlink==0` 确认真的是匿名文件。

配套的**自检**:`IsSelfExeCloned`(`cloned_binary_linux.go:254`)用 `F_GET_SEALS` 检查
`/proc/self/exe` 是否带全套 seal(202-216 的 `IsCloned`);已克隆则直接复用,避免每次 exec 都克隆。
`IsCloned` 只认 memfd seal——overlayfs/tmpfile 克隆无法被等价验证,所以保守返回 false
(注释 209-215)。

**同一思想的延续**:exec fifo 关闭顺序防 CVE-2016-9962(`standard_init_linux.go:275`)、
execve 前 `UnsafeCloseFrom` 关闭所有宿主 fd 防 CVE-2024-21626(`standard_init_linux.go:288-300`)——
runc 把每一起真实逃逸都固化成一条结构性防御,而不是一次性补丁。

---

## 5. 工程文化专节

### 5.1 测试:双层结构 + 幂集矩阵

- **单元测试**:40 个 `_test.go` 文件分布在 libcontainer 各包旁(对照:非测试 Go 文件 139 个),
  覆盖 specconv/rootfs/mount 等核心翻译逻辑;另有 `tests/fuzzing`。
- **集成测试**:`tests/integration/` 下 **59 个 bats(bash)文件**,按 OCI 功能一一对应
  (seccomp.bats、seccomp-notify.bats、capabilities.bats、hooks.bats、hooks_so.bats、
  user_ns.bats、selinux.bats、apparmor.bats……),共享 `helpers.bash`。
  `tests/integration/README.md:5-14` 写明分工原则:"integration tests do **not** replace unit tests…
  code should be tested thoroughly with unit tests; integration tests test a specific feature end to end",
  运行方式是 `make integration`(容器内)/`sudo make localintegration`/裸 `bats`。
- **rootless 幂集矩阵**:`tests/rootless.sh:25` 定义 `ALL_FEATURES=("idmap" "cgroup")`
  (systemd 模式下只剩 idmap,26-29 行),174-196 行用 brace-expansion 生成**所有特征组合的幂集**
  逐一遍历,每个组合跑完整集成测试(经 ssh 进入 rootless 用户会话,systemd 场景为 user session)。
  `helpers.bash:516-537` 提供 `rootless_idmap`/`rootless_cgroup`/`rootless_no_features` 等条件
  skip 装饰器,使同一套 bats 能在 root/rootless/各特征组合下自适应。
- 还有一类"真实世界复现"测试,如 `hooks_so.bats` 用 gcc 现编带 soname 的共享库,验证 hook 与
  容器内挂载的交互。

### 5.2 CVE 响应流程

`SECURITY.md` 全文只有一条规则:"When reporting a security issue, do not create an issue or file a
pull request on GitHub",指向 OCI 组织级安全流程(opencontainers/org 的 SECURITY.md)——私密上报、
协调披露。代码侧的证据链是历届 CVE 的"结构化防腐":exeseal(CVE-2019-5736)、fd 关闭
(CVE-2024-21626)、fifo 顺序(CVE-2016-9962)如前所述;`RELEASES.md:57-70` 则规定旧分支的
安全修复门槛起步于 CVSS 7.0。发布工具有 `script/release_build.sh`/`release_sign.sh` 与仓库根的
`runc.keyring`,发行物签名可复现。

### 5.3 版本与发布策略

- **版本号来源**:`VERSION` 文件经 `//go:embed` 直接编进二进制(`main.go:27-30`),
  `Makefile:26-28` 用 `git describe` 注入 `main.gitCommit`。这正是"1.5.0-rc.1+dev"后缀的出处:
  分支上 VERSION 常驻 `X.Y.0-rc.Z+dev` 形态。
- **节奏**(`RELEASES.md:22-53`):6 个月一个 minor,4 月底/10 月底发布;rc.1 提前 2 个月冻结
  release 分支;每个 minor 通常 2-3 个 rc。文中给了一张"假想时间线"表格,把支持策略讲成日历。
- **支持窗口**(`RELEASES.md:57-70`):`latest` 只收 bug/安全回移;`latest-1` 收安全+重大 bug;
  `latest-2` 只收 CVSS >= 7.0;更老版本"无论严重程度都不再有任何修复"。
- **兼容立场**(`RELEASES.md:9-13`):semver 只承诺 **runc 二进制**的行为兼容;Go 包 API 明确
  不做保证——把"规范实现"和"代码库"切开,是所有 OCI 运行时的共同立场。
- **维护者模型**:`MAINTAINERS` 列 7 位维护者(名字+GitHub handle),配套 `MAINTAINERS_GUIDE.md`
  与 `EMERITUS.md`(荣誉退休名单)——治理文档分层到"现任/指南/退休"三件套。
  `PRINCIPLES.md` 是 13 条格言式设计准则,包括 "Less code is better"、
  ""No" is temporary; "Yes" is forever"、"Don't merge it unless you test it!"。
  `CONTRIBUTING.md:26-70` 规定 commit 50 字符祈使句摘要、合并前 squash、`Closes #XXX` 等惯例,
  并要求 DCO 签名(`Signed-off-by`)。

### 5.4 与其他 OCI 项目的接口

runc 只依赖两个 OCI 仓库:`github.com/opencontainers/runtime-spec v1.3.0`(`go.mod:20`,
specs-go 提供字段类型与 `specs.Version`)和 `github.com/opencontainers/selinux`;
cgroup 抽象也已外置为 `github.com/opencontainers/cgroups v0.1.0`(`go.mod:19`)。
image-spec 与 runc 无任何依赖关系——镜像层解包是 containerd/docker 侧的职责,runc 只吃 rootfs 目录。
`libcontainer/SPEC.md` 是规范尚未分离时代的遗物(标题"Container Specification - v1"),
如今仅存历史价值,可与 runtime-spec 仓库对照阅读。

---

## 6. 设计动机

**为什么 hooks 要五个时机?** 容器初始化存在三个"世界"和两道不可逆门槛:init 进程内的
pivot_root 和 execve,以及父进程侧的 cgroup/网络就绪。`createRuntime` 在**父进程**执行(cgroup 已
Set,`process_linux.go:1018`),给 SDN/CNI 这类需要宿主视角的工具窗口;`createContainer` 在
**init 内、pivot 前**,看得到容器根但还能读旧根;`startContainer` 在 **exec 前的最后一刻**
(标准库里那句"de facto"注释承认 env 继承是历史包袱)。三个窗口覆盖"宿主视角/容器根视角/
进程视角",prestart(=createRuntime 旧版)与 poststart/poststop 补齐生命周期两端。
每一步都是"规范为真实集成需求留出的插槽"。

**为什么 seccomp 尽量晚应用?** filter 一旦装载,之后的每条 syscall 都要过它;而 runc init 在
execve 前还要做 fifo 同步、fd 传递等"自己的"syscall。应用得越晚,需要写进用户 profile 的
runc 自身 syscall 越少——profile 越小,攻击面越小,可移植性越好。唯一的例外(reverse-order)
是未开 NoNewPrivileges 时必须先装 filter 再丢权,因为装 filter 本身是特权操作
(`standard_init_linux.go:188-190` 注释)。

**为什么 exeseal 是"防换绑"而不是"防读取"?** CVE-2019-5736 的根源是 runc 二进制作为
**共享可变状态**存在于宿主文件系统,而容器进程与 runc 之间共享这个状态。memfd seal / overlayfs
只读叠加把"可变的二进制"变成"进程私有的不可变对象",一次性消灭整类 TOCTOU 换绑攻击,
而不是逐个封堵 `/proc` 的 magic-link 路径。这与其余 CVE 防御(exec 前 fd 大扫除、fifo 时序)
一脉相承:**把事故变成不变量**。

---

## 7. FAQ 素材

1. **config.json 里一个字段要经过几层才到内核?** 三层:specs.Spec → specconv 翻译成
   configs.Config(`spec_linux.go:384`)→ init 进程按 configs 执行内核调用;翻译与执行分离。
2. **prestart 和 createRuntime 有何区别?** 执行位置完全相同(都在 cgroup Set 之后的父进程,
   `process_linux.go:1036/1039`),prestart 已弃用,仅为老规范文件兼容保留(`config.go:420-423`)。
3. **createContainer 和 createRuntime 都在 pivot 前运行,差别是什么?** 命名空间视角:
   createRuntime 在 runtime ns(宿主视角),createContainer 在容器 ns、且在 init 进程内
   fchdir 进新 rootfs 之后(`rootfs_linux.go:223-231`)。
4. **为什么开了 NoNewPrivileges 时 seccomp 反而装得更晚?** NNP 让装 filter 不再需要特权,
   于是可以推迟到 execve 前最后一刻,减少被 filter 覆盖的 runc 自身 syscall(见第 6 节)。
5. **我的 seccomp profile 在新内核上报 ENOSYS 而不是 EPERM?** 那是 runc 的 enosys 补丁
   (`patchbpf/enosys_linux.go:729` PatchAndLoad)刻意为之:未知 syscall 模拟"不存在"语义。
6. **spec 里写了内核不认识的 capability 会怎样?** 只打一行 warning 并忽略
   (`capabilities.go:71-73`),不会失败——与命名空间"不认识即报错"策略相反。
7. **runc 会碰 image-spec 吗?** 不会。runc 只依赖 runtime-spec 与 selinux 仓库(`go.mod:19-21`),
   镜像解包在高层运行时完成。
8. **VERSION 文件里的 +dev 是什么?** 开发态标记,经 go:embed 编入二进制(`main.go:27-30`);
   正式发布时由 release 流程改为干净版本号。
9. **CVE 怎么报?** 不开 issue不开 PR,走 OCI 组织级私密上报(`SECURITY.md`,全文就这一件事)。
10. **rootless 测试跑多少种组合?** 特征幂集:目前 idmap×cgroup 的全部 4 种组合各跑一遍完整
    集成测试,systemd 模式降为 idmap 单维(`tests/rootless.sh:25-29,174-196`)。

## 深挖方向

1. **`patchbpf/enosys_linux.go:321` `generateEnosysStub`**:手写 BPF 指令生成,可结合
   `golang.org/x/net/bpf` 讲清 seccomp filter 的机器码层。
2. **`seccomp/config.go` 与 `runc features`**(`features.go:43` 汇集 KnownHookNames/
   KnownCapabilities/KnownActions 等):运行时自描述能力如何服务上层编排器的能力探测。
3. **`tests/integration/helpers.bash` 的条件 skip 体系**(516-537 行装饰器):一套测试如何
   适配 root/rootless/systemd/无 idmap 等所有环境,可作为 CI 矩阵设计的范本。
4. **`exeseal/overlayfs_linux.go:53` `sealedOverlayfs`**:fsopen/fsmount 新挂载 API 的实战用法,
   以及为何 MS_BIND+MS_RDONLY 是可被卸载绕过的"伪只读"。
5. **`RELEASES.md` 的支持日历 vs 实际 CHANGELOG.md**:对照 1.0 至 1.4 的真实发布间隔,
   验证"6 个月节奏"是从哪一版开始兑现的。

---

## 写作要点速查表

| 事实 | 位置(仓库相对路径:行号) |
| --- | --- |
| spec→configs 总入口 | libcontainer/specconv/spec_linux.go:384 `CreateLibcontainerConfig` |
| 命名空间/挂载映射表 | libcontainer/specconv/spec_linux.go:49 `initMaps`;450 namespaceMapping 使用 |
| capabilities spec 字段直拷 | libcontainer/specconv/spec_linux.go:597-604 |
| 挂载翻译+null 字节校验 | libcontainer/specconv/spec_linux.go:641, 676-684 |
| seccomp spec 翻译 | libcontainer/specconv/spec_linux.go:1195 `SetupSeccomp` |
| hooks 拷贝 | libcontainer/specconv/spec_linux.go:1286 `createHooks`;1316 `createCommandHook` |
| hook 常量与统一执行 | libcontainer/configs/config.go:423-447;536 `Hooks.Run` |
| prestart/createRuntime 执行点 | libcontainer/process_linux.go:1016-1041(1018 先 Set cgroup) |
| createContainer 执行点(pivot 前) | libcontainer/rootfs_linux.go:223-231 |
| startContainer 执行点(exec 前) | libcontainer/standard_init_linux.go:282-289 |
| poststart / poststop | libcontainer/container_linux.go:341-361;libcontainer/state_linux.go:69-81 |
| seccomp 双时机(非 NNP / NNP) | libcontainer/standard_init_linux.go:191-200;239-248 |
| notify fd 移交 agent | libcontainer/process_linux.go:532-578;禁 write/default 见 seccomp_linux.go:62-71 |
| enosys BPF 补丁与装载 | libcontainer/seccomp/patchbpf/enosys_linux.go:321, 729 |
| cap 应用次序 | libcontainer/init_linux.go:336-365;capabilities/capabilities.go:100,110,133-147 |
| apparmor/selinux 加载点 | libcontainer/standard_init_linux.go:131,183-187;libcontainer/setns_init_linux.go:120 |
| exeseal 调用点 | libcontainer/container_linux.go:553-575(`IsSelfExeCloned`/`CloneSelfExe`) |
| 克隆三级回退与 seal | libcontainer/exeseal/cloned_binary_linux.go:124,180,218;overlayfs_linux.go:53 |
| rootless 幂集矩阵 | tests/rootless.sh:25-29,174-196;helpers.bash:516-537 |
| 版本嵌入与发布节奏 | main.go:27-30;Makefile:26-28;RELEASES.md:22-70;SECURITY.md:3 |
