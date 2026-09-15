# O 篇 · CDI 设备注入：从 --device 到声明式设备标准

> 调研对象：containerd 主干 commit `f6132dbe1f482cbe0aebc4bd3d8d7a184fb4a2aa`（2.x 主干，下文行号均以此 commit 为准）。
> CDI 库为外部依赖 `tags.cncf.io/container-device-interface`，本文引用其 vendor 副本（`vendor/tags.cncf.io/container-device-interface/`），行号为 vendor 内文件行号。

## 1. 全景：CDI 的三段式流水线

```
 [第一段] 厂商生成 CDI Spec 文件（声明式 JSON/YAML）
 ─────────────────────────────────────────────────────
   nvidia-smi / amd 驱动等 vendor 工具
        │  扫描本机 GPU，生成
        ▼
   /etc/cdi/nvidia.yaml         ← 静态目录（手工/开机生成，优先级由目录顺序决定）
   /var/run/cdi/nvidia.yaml     ← 动态目录（运行时生成，如 device plugin）
        （文件内容 = Spec{kind: "nvidia.com/gpu", devices: [...], containerEdits}）

 [第二段] containerd 侧注册表（Cache）读取与刷新
 ─────────────────────────────────────────────────────
   CRI 启动: cdi.Configure(WithSpecDirs(...))   internal/cri/server/service_linux.go:107
        │
        ▼
   Cache: scanSpecDirs → ReadSpec → validate    vendor .../pkg/cdi/spec-dirs.go:74
          fsnotify watch 目录，文件变更触发 refresh   vendor .../pkg/cdi/cache.go:485
          设备冲突按目录优先级裁决                   vendor .../pkg/cdi/cache.go:174

 [第三段] Create 容器时注入 OCI spec
 ─────────────────────────────────────────────────────
   CRI 请求( CDIDevices[] / cdi.k8s.io 注解 )
        ▼
   WithCDI(...)          internal/cri/opts/spec_linux.go:139   ← 收集设备名、去重
        ▼
   WithCDIDevices(...)   pkg/cdi/oci_opt.go:31                 ← Refresh + InjectDevices
        ▼
   Cache.InjectDevices   vendor .../pkg/cdi/cache.go:233       ← 合并 deviceEdits
        ▼
   ContainerEdits.Apply  vendor .../pkg/cdi/container-edits.go:75
        写入 OCI spec 的 linux.devices / process.env / hooks / mounts / resources.devices
        ▼
   交给 runc：createContainer 时 mknod/bind-mount 设备节点 + devices cgroup 放行
```

三段的关键设计：**vendor 只负责"声明"**（写一份描述设备的 JSON），**runtime 负责"执行"**（把声明翻译成 OCI 编辑），二者通过文件目录解耦，通过设备全限定名 `vendor/class=deviceID`（如 `nvidia.com/gpu=0`）通信。

## 2. CDI 结构专节：Spec / Device / ContainerEdits 逐字段

### 2.1 Spec 文件的三层结构

CDI Spec 文件本身的结构定义在 `specs-go/config.go`（即磁盘上 JSON 的 schema）：

```go
// vendor/tags.cncf.io/container-device-interface/specs-go/config.go:6
type Spec struct {
	Version string `json:"cdiVersion"`   // 规范版本，如 "0.6.0"
	Kind    string `json:"kind"`         // "vendor/class"，如 "nvidia.com/gpu"
	Annotations map[string]string `json:"annotations,omitempty"`
	Devices        []Device          `json:"devices"`
	ContainerEdits ContainerEdits    `json:"containerEdits,omitempty"` // spec 级公共编辑
}
```

- `Spec.Version`（config.go:7）：加载时做最低版本校验，`Spec.validate()` 首步就是 `cdi.ValidateVersion`（`pkg/cdi/spec.go:220`）。
- `Spec.Kind`（config.go:8）：`vendor/class` 二段限定名，加载时用 `parser.ParseQualifier` 拆开存为 `spec.vendor`/`spec.class`（`pkg/cdi/spec.go:114`），vendor 名与 class 名各自过正则校验（spec.go:223-228）。
- `Spec.Devices`（config.go:12）：设备条目列表，**每个 Device 必须有自己的 ContainerEdits**；一个 spec 文件里重名设备直接报错（spec.go:242-244），一个设备都没有也报错 `invalid spec, no devices`（spec.go:247-249）。
- `Spec.ContainerEdits`（config.go:13）：spec 级公共编辑，对该文件内**所有**设备生效——注入时先 Append spec 级 edits 再 Append 设备级 edits（`pkg/cdi/cache.go:253-257`）。

```go
// vendor .../specs-go/config.go:17
type Device struct {
	Name           string            `json:"name"`
	Annotations    map[string]string `json:"annotations,omitempty"`
	ContainerEdits ContainerEdits    `json:"containerEdits"`
}
```

### 2.2 ContainerEdits：注入的"动作清单"

```go
// vendor .../specs-go/config.go:26
type ContainerEdits struct {
	Env            []string          `json:"env,omitempty"`
	DeviceNodes    []*DeviceNode     `json:"deviceNodes,omitempty"`
	NetDevices     []*LinuxNetDevice `json:"netDevices,omitempty"`  // v1.1.0
	Hooks          []*Hook           `json:"hooks,omitempty"`
	Mounts         []*Mount          `json:"mounts,omitempty"`
	IntelRdt       *IntelRdt         `json:"intelRdt,omitempty"`
	AdditionalGIDs []uint32          `json:"additionalGids,omitempty"`
}
```

逐字段含义与 Apply 时的落点（`vendor .../pkg/cdi/container-edits.go:75` 的 `Apply`）：

| 字段 | 语义 | Apply 落点（OCI spec） |
|---|---|---|
| `Env` | 追加进程环境变量 | `process.env`（container-edits.go:87-89） |
| `DeviceNodes` | 设备节点（path/hostPath/type/major/minor/permissions/uid/gid，config.go:37-47） | `linux.devices` + 块/字符设备的 `linux.resources.devices` cgroup 规则（container-edits.go:110-122） |
| `NetDevices` | 主机网卡移入容器 | `linux.netDevices`（container-edits.go:125-129） |
| `Mounts` | 额外挂载（驱动库目录等） | `mounts`，user namespace 时自动加 idmap 选项（container-edits.go:131-144） |
| `Hooks` | OCI hook（prestart/createRuntime/createContainer/startContainer/poststart/poststop 六种，container-edits.go:34-40） | 对应 `hooks.*`，未知 hook 名报错（container-edits.go:146-163） |
| `IntelRdt` | RDT 缓存/内存带宽分级 | `linux.intelRdt`（container-edits.go:166-168） |
| `AdditionalGIDs` | 补充 supplementary group | `process.user.additionalGids`（container-edits.go:170-175） |

`DeviceNode` 的细节值得注意（config.go:37-47）：`Path` 是容器内路径，`HostPath` 缺省取 `Path`；若 vendor 只写 path 不写 major/minor，`fillMissingInfo` 会 stat 宿主机节点补全 type/major/minor/fileMode（`container-edits_unix.go:80-119`）——**宿主机节点不存在且 vendor 也没写全字段时才报错**（container-edits_unix.go:94-97，错误 `failed to stat CDI host device`），这是"设备节点不存在"错误面的第一道闸。Apply 还会把 OCI spec 中进程的 UID/GID 默认成设备节属主（container-edits.go:99-108），对 rootless 友好。

### 2.3 注册表（Cache）：扫描、刷新、冲突裁决

containerd 不自己实现注册表，直接使用 CDI 库的全局默认 Cache（`vendor .../pkg/cdi/default-cache.go:40` 的 `GetDefaultCache`，包级 `Configure/Refresh/InjectDevices` 分别在 default-cache.go:47/56/62 转发到它）。

**扫描**：`scanSpecDirs`（spec-dirs.go:74-96）逐目录 `os.ReadDir`，只认 `.json`/`.yaml` 后缀、不递归子目录；**目录在列表中的下标就是该目录下 spec 的优先级**（spec-dirs.go:75、95 的 `priority` 参数），排前面的优先级高。默认目录 `/etc/cdi`（静态）、`/var/run/cdi`（动态）（spec-dirs.go:28-30、38），containerd 的 CRI 配置默认值与之相同（`internal/cri/config/config_unix.go:108`）。

**刷新**：`Cache.Refresh`（cache.go:139-156）→ `refresh`（cache.go:159-219）：重扫全部目录，按 `vendor` 分组存 `c.specs`，把每个设备以全限定名 `vendor/class=name`（`pkg/cdi/device.go:54` 的 `GetQualifiedName`）收入 `c.devices` 平铺索引。同名设备冲突时按目录优先级裁决：高优先级静默替换，同优先级则两个 spec 都记入错误并把该设备**整体删除**（cache.go:174-187 的 `resolveConflict` + 212-214 的 conflicts 清理）。

**自动刷新**：`WithAutoRefresh`（cache.go:70）开启时由 fsnotify watch（cache.go:449-471 起 watcher，cache.go:485-524 的事件循环；监听 Create/Rename/Remove/Write，非 .json/.yaml 文件事件直接忽略，cache.go:507）驱动，文件一落盘就 `refresh`。单文件加载/校验失败不会使整个注册表失败，只记入 `c.errors` 供 `GetErrors` 查询（cache.go:412）。

**注入**：`Cache.InjectDevices`（cache.go:233-270）按设备名查 `c.devices`，把命中的 spec 级 edits + 设备级 edits 依次 `Append` 成一个 `ContainerEdits`，最后一次性 `edits.Apply(ociSpec)`。查不到的名字进 `unresolved`，返回 `unresolvable CDI devices ...`（cache.go:260-263）。

## 3. CRI 集成专节：从 kubelet 请求到 OCI spec

### 3.1 配置与注册表初始化

- 配置项 `EnableCDI *bool`（`internal/cri/config/config.go:419`）与 `CDISpecDirs []string`（config.go:423）；Linux 默认 `EnableCDI=true`、`CDISpecDirs=["/etc/cdi","/var/run/cdi"]`（config_unix.go:107-108）。
- `enable_cdi` 已进入废弃流程：`deprecation.CRIEnableCDI` 定义于 `pkg/deprecation/deprecation.go:43`，文案"将在 v2.3 移除该开关、CDI 恒开启"在 deprecation.go:71；启动时若显式设 false 打警告（`internal/cri/server/service.go:289-292`），配置校验时归入 warnings（config.go:712-714）。
- CRI 服务启动时初始化全局注册表：`cdi.Configure(cdi.WithSpecDirs(c.config.CDISpecDirs...))`（`internal/cri/server/service_linux.go:106-111`），失败直接返回 `failed to configure CDI registry`。

### 3.2 注入链（container_create）

```
kubelet PodSandbox/ContainerConfig
  └─ CRI ContainerConfig.CDIDevices []*CDIDevice   ← k8s.io/cri-api，每个只有 Name 字段
       vendor/k8s.io/cri-api/pkg/apis/runtime/v1/api.pb.go:5583-5592
  └─ （旧路径）container annotations: "cdi.k8s.io/<plugin>=dev1,dev2"
       vendor .../pkg/cdi/annotations.go:29 定义 AnnotationPrefix = "cdi.k8s.io/"
       ↓
container_create_linux.go:  specOpts = append(specOpts, customopts.WithCDI(config.Annotations, config.CDIDevices))
       internal/cri/server/container_create_linux.go:103-104   （EnableCDI 关闭且请求了设备则报错 :106-112）
       ↓
opts.WithCDI（internal/cri/opts/spec_linux.go:139-179）：
  ① 遍历 config.CDIDevices，取 Name、去重（:143-153）
  ② cdi.ParseAnnotations(annotations) 解析 cdi.k8s.io/* 注解里的设备（:157-160，
     注解值逗号分隔、每个都必须是全限定名，annotations.go:63-83）
  ③ 统一交给 pkg/cdi.WithCDIDevices(devices...)（:177）
       ↓
pkg/cdi/oci_opt.go:31-56（WithCDIDevices）：
  cdi.Refresh() —— 失败仅告警不致命（:37-44），
     理由：某厂商的坏 spec 不应阻止其他厂商设备注入
  cdi.InjectDevices(s, devices...) —— 失败即创建失败（:46-48）
```

device plugin 与 CDI 的衔接发生在 **kubelet/DRA 侧**：kubelet 的 device plugin 分配设备后，把 CDI 全限定名写进 `ContainerConfig.CDIDevices`（新标准路径）或 `cdi.k8s.io/*` 注解（过渡路径，`annotations.go:85-90` 的 `AnnotationKey` 就是给 device plugin 生成唯一注解键用的）。containerd 侧只认名字、查表、翻译，不感知 device plugin 协议。

一个工程细节写在 `pkg/cdi/oci_opt.go:50-53` 的注释里：CDI 注入可能追加 env/hooks/mounts，**因此 WithCDIDevices 之后的 specOpts 不能再重置这几个字段**——这决定了它在 specOpts 序列中的位置约束（CRI 中它排在 capabilities/devices 等基础 opts 之后组装）。

## 4. nvidia 对比专节：legacy 预处理 vs CDI 模式

containerd 2.x 主干**没有** `pkg/nvidia` 这样的厂商专路，也没有任何 nvidia 魔改代码；与 NVIDIA 的关联只剩两处"通用机制"：

1. **ctr 的 `--gpus` 便利参数直接翻译成 CDI 名字**（`cmd/ctr/commands/run/run_unix.go:567-589` 的 `withCDIDeviceRequests`）：从注册表 `ListVendors()` 里探测已知 GPU 厂商 `nvidia.com`/`amd.com`（run_unix.go:520-529 的 `detectGPUVendor`），再把 `--gpus 2` 翻译成 `nvidia.com/gpu=2`（run_unix.go:532-545 的 `gpuDeviceNames`，格式 `fmt.Sprintf("%s/gpu=%d", vendor, id)`）。探不到已知厂商就报错（run_unix.go:528）。
2. **ctr 对 `--device` 的双轨解析**（run_unix.go:369-376）：参数能通过 `parser.IsQualifiedName`（形如 `vendor/class=name`）的走 CDI 注入，否则按 legacy 设备路径走 `oci.WithDevices`。

```
 legacy: docker run --runtime=nvidia
 ─────────────────────────────────────────────────────────
 kubelet/docker → 指定 nvidia-container-runtime 作为 OCI runtime
   → runc create 前由 nvidia-container-runtime 预处理（prestart hook / spec 改写）
   → 魔改 runtime 注入 libcuda、挂驱动、改 LD_LIBRARY_PATH
   → 每家厂商都要一个自己的 runtime、自己的 hook、自己的维护线
   → runtime 配置里只为 nvidia 留特例，厂商知识硬编码在运行链路上

 CDI: 无厂商 runtime
 ─────────────────────────────────────────────────────────
 nvidia-ctk cdi generate（vendor 工具，离线/开机跑一次）
   → /etc/cdi/nvidia.yaml 声明所有设备
 containerd: 查注册表 nvidia.com/gpu=0 → ContainerEdits.Apply → 标准 OCI spec
   → runc 无感知，containerd 无 nvidia 代码，厂商知识收敛在一份 JSON 里
```

架构差异的本质：legacy 把"设备知识"放进了**执行路径**（必须换 runtime/hook），CDI 把它搬进了**数据文件**（runtime 零改动）。代价是 CDI 的 hooks 字段仍保留了 prestart 等 OCI hook 逃生舱（container-edits.go:146-163），说明厂商复杂的运行时逻辑（如 persistenced 接管）仍可经 hook 注入，但那是规范内的一条通道而非整条魔改链。

## 5. legacy --device 对照：runc devices 的老路

对照 legacy 路径在 containerd 内的实现（`pkg/oci/spec_opts_linux.go:43-61`）：

```go
// pkg/oci/spec_opts_linux.go:43（节选）
func WithDevices(devicePath, containerPath, permissions string) SpecOpts {
	return func(... s *Spec) error {
		devs, err := getDevices(devicePath, containerPath) // 递归目录
		...
		s.Linux.Devices = append(s.Linux.Devices, devs...)         // OCI linux.devices
		s.Linux.Resources.Devices = append(s.Linux.Resources.Devices,
			specs.LinuxDeviceCgroup{Allow: true, Type: ..., Access: permissions}) // cgroup 规则
```

- legacy 每个设备只携带 path/type/major/minor/uid/gid，**只有设备节点语义**；CDI 的 ContainerEdits 还能带 env/hooks/mounts（对照 §2.2）。
- legacy 的权限只有 `permissions` 字符串（如 `rwm`）直接进 devices cgroup；CDI 在 Apply 里对块/字符设备默认 `rwm`（container-edits.go:113-122），同样落到 `linux.resources.devices`——所以两者在内核层面最终殊途同归：runc 都要 mknod/bind-mount 节点 + 写 devices cgroup（v1）或 eBPF devices controller（v2）。
- CRI 的老入口 `ContainerConfig.Devices`（host path + container path + permissions）由 `internal/cri/opts/spec_linux_opts.go:315-357` 的 `WithDevices` 翻译，宿主路径不存在直接 `ResolveSymbolicLink` 报错（spec_linux_opts.go:327-330）；它在 `internal/cri/server/container_create.go:801` 无条件追加，与 CDI 互不相干。可见容器内 CDI 与 `--device` 可以混用，冲突裁决交给 runc。

## 6. 设计动机：为什么 CDI 取代各厂商魔改 runtime

1. **供应商解耦**：CDI 之前，每家 GPU/FPGA/NIC 厂商要么维护自己的 OCI runtime fork（nvidia-container-runtime），要么依赖 runtime 里的厂商分支。CDI 之后 containerd 主干零厂商代码（§4 已验证：全仓库仅 ctr 探测 vendor 字符串一处），新增硬件 = 新增一份 spec 文件。
2. **声明式设备**：设备描述成为可审计、可版本化（`cdiVersion`）、可缓存（spec 文件）的数据，而不是运行时行为。kubelet device plugin/DRA 分配的只是一个名字字符串，runtime 拿名字兑现。
3. **关注点内聚**：`vendor/class=deviceID` 命名空间（device.go:54）+ 目录优先级冲突裁决（cache.go:174）+ 多目录静态/动态分层（/etc/cdi vs /var/run/cdi），把"谁声明了这台设备、以谁为准"变成纯文件系统问题。
4. **标准化时机成熟**：CRI 侧 `CDIDevices` 字段已成为一等公民（api.pb.go:5583），注解方式已标注废弃（spec_linux.go:173-174 的 TODO），`enable_cdi` 开关也进入 deprecation（deprecation.go:71）——三方（规范、CRI、containerd 配置）同步收敛。

## 7. 错误面小结（CDI 文件缺失 / 设备不存在）

- **spec 目录不存在**：扫描时 `fs.ErrNotExist` 直接跳过（spec-dirs.go:77-79），不算错误。
- **spec 文件损坏/非法**：`ReadSpec` 报错（spec.go:69-92），错误只记入 per-path 错误表（cache.go:168-172），不阻断其他设备；`WithCDIDevices` 里 `Refresh` 失败也仅告警（oci_opt.go:37-44）。
- **请求的设备名查不到**：`InjectDevices` 返回 `unresolvable CDI devices`（cache.go:260-263），`WithCDIDevices` 包装为 `CDI device injection failed`（oci_opt.go:46-48），**容器创建失败**——这是整个 CDI 链路里唯一硬失败的常规点。
- **宿主机设备节点不存在**：vendor 未写全字段时 `fillMissingInfo` stat 失败硬报错（container-edits_unix.go:94-97）；vendor 写全了 type/major/minor 则容忍节点缺失（runc 可凭 major/minor 直接创建节点）。
- **EnableCDI=false 却请求了 CDI 设备**：直接报错 `CDI devices (...) requested but CDI support is explicitly disabled`（container_create_linux.go:106-112）。

## 8. FAQ 素材

1. **CDI 文件放哪？** 默认 `/etc/cdi`（静态）与 `/var/run/cdi`（动态），顺序即优先级（spec-dirs.go:28-30、cache.go:75）。
2. **containerd 里有 nvidia 代码吗？** 没有。只有 ctr `--gpus` 探测 `nvidia.com`/`amd.com` vendor 字符串（run_unix.go:520-528）；NVIDIA 专属逻辑全在厂商侧的 `nvidia-ctk cdi generate`。
3. **CDI 设备名长什么样？** `vendor/class=name`，如 `nvidia.com/gpu=0`；ctr 里 `--device` 参数以此格式识别为 CDI 设备（run_unix.go:371），CRI 侧 `CDIDevice.Name` 也是全限定名（api.pb.go:5589）。
4. **同一设备出现在两个文件里怎么办？** 高优先级目录胜出；同级冲突则该设备被移除并记错误（cache.go:174-187、212-214）。
5. **CDI 能改环境变量/挂载/hook 吗？** 能，ContainerEdits 七类编辑全部支持（config.go:26-34），这正是它优于 --device 的地方——装驱动库、设 `NVIDIA_VISIBLE_DEVICES` 类变量都不再需要包装脚本。
6. **spec 文件热更新吗？** CRI 默认开启 fsnotify 自动刷新，文件增删改即时生效（cache.go:485-524）；ctr 命令行路径反而关掉 autoRefresh 改为一次性 Refresh（run_unix.go:550-563）。
7. **一个 spec 文件可以声明多少设备？** 至少一个（spec.go:247-249），文件内不可重名（spec.go:242-244）；`containerEdits` 公共部分对所有设备叠加。
8. **kubelet 的 device plugin 怎么把设备交给 containerd？** 新路径：CRI `ContainerConfig.CDIDevices`；旧路径：`cdi.k8s.io/<plugin>` 注解（spec_linux.go:157、annotations.go:29），注解路径已计划废弃。
9. **CDI 注入失败会怎样？** 只有"设备名解析不到"和"宿主节点缺失且未写全字段"会硬失败；spec 文件级错误都是软失败（见 §7）。
10. **user namespace 下挂 CDI Mounts 有何特殊？** 自动加 idmap 挂载选项（container-edits.go:137-141，oci.go:37 的 `withIDMapForBindMount`）。

## 9. 深挖方向

1. **spec-dirs 优先级与 DRA**：`/var/run/cdi` 动态目录优先级更高的设计，如何支撑 kubelet DRA 动态生成的 per-pod transient spec（`GenerateTransientSpecName`，spec.go:322）。
2. **devices cgroup 的 v2 演进**：CDI Apply 写的是 `linux.resources.devices`（container-edits.go:121），runc 在 cgroup v2 下翻译为 BPF 程序——可在 runc 侧继续追踪这条翻译链。
3. **注解 → CDIDevices 的迁移细节**：spec_linux.go:141 的 `seen` 去重表同时喂两条来源，重复设备静默跳过（:148、167），迁移期的语义边界值得做兼容性测试。
4. **watch 的边界情况**：目录被整体删除重建时 `markRemoved` → 重新 watch 的恢复路径（cache.go:511-512、526-535），是 fsnotify 典型坑点。
5. **与 NRI 的叠加**：NRI 也能改 OCI spec（internal/cri/nri/），CDI 注入后 NRI hook 再改 devices 的次序保证问题。

## 10. 写作要点速查表

| 事实 | 位置 |
|---|---|
| CDI 注入 SpecOpt（Refresh 软失败 + InjectDevices） | pkg/cdi/oci_opt.go:31-56（:37，:46） |
| CRI 侧 WithCDI（CDIDevices + 注解双源、去重） | internal/cri/opts/spec_linux.go:139-179（:157，:177） |
| CRI create 时挂接 WithCDI / 禁用时报错 | internal/cri/server/container_create_linux.go:103-114 |
| CRI 启动时 Configure 注册表 | internal/cri/server/service_linux.go:106-111 |
| enable_cdi 默认 true / 目录默认值 | internal/cri/config/config_unix.go:107-108 |
| enable_cdi 废弃声明与文案 | pkg/deprecation/deprecation.go:43，:71；service.go:289-292 |
| Spec/Device/ContainerEdits/DeviceNode/Hook 结构 | vendor .../specs-go/config.go:6，:17，:26，:37，:58 |
| 扫描目录、优先级=目录下标 | vendor .../pkg/cdi/spec-dirs.go:74-96（:75，:95） |
| refresh + 冲突按优先级裁决 | vendor .../pkg/cdi/cache.go:159-219（:174-187） |
| InjectDevices（合并 edits、unresolved 硬失败） | vendor .../pkg/cdi/cache.go:233-270（:260-263） |
| fsnotify 自动刷新 | vendor .../pkg/cdi/cache.go:485-524（:507） |
| ContainerEdits.Apply：OCI 合并总入口 | vendor .../pkg/cdi/container-edits.go:75-178 |
| fillMissingInfo：宿主节点缺失的容错边界 | vendor .../pkg/cdi/container-edits_unix.go:80-119（:94-97） |
| ctr --device 双轨识别 / --gpus→CDI 名 | cmd/ctr/commands/run/run_unix.go:369-376，:520-545，:567-589 |
| legacy WithDevices（devices+cgroup 规则） | pkg/oci/spec_opts_linux.go:43-61 |
| CRI legacy 设备翻译与 create 挂接点 | internal/cri/opts/spec_linux_opts.go:315-357；internal/cri/server/container_create.go:801 |
| CRI API CDIDevice（仅 Name 字段） | vendor/k8s.io/cri-api/pkg/apis/runtime/v1/api.pb.go:5583-5592 |
| cdi.k8s.io/ 注解前缀与解析 | vendor .../pkg/cdi/annotations.go:29，:63-83 |
