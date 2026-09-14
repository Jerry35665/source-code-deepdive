# K - runc rootless 深读:没有 root 时,哪些被砍、哪些被替换

> 仓库:runc @ commit **579be22**(版本串 `1.5.0-rc.1+dev`,dev 分支)。本文所有 `文件:行号` 均为该 commit 下仓库相对路径,并经 grep/Read 实际核对。
> 呼应:卷一 D 章(runc 全景)、E 章(cgroups 与 rootfs)、04 章(nsexec 阶段 0 的映射写入)。

---

## 1. 全景:rootless 的"能力削减表"

rootless 不是一条独立代码路径,而是同一套创建全链上散布的 **if (rootless)** 分支:runc 用两个布尔位(`RootlessEUID`、`RootlessCgroups`,libcontainer/configs/config.go:219-227)贯穿 specconv → cgroup → nsexec → rootfs → init 五个环节。削减与替代一览:

```
能力面           特权容器(卷一已讲)              rootless 的现状/替代
--------------  ------------------------------  ---------------------------------------------
用户身份        真 root,UID 0 即宿主 root      euid!=0 → 新建 userns,容器内"伪 root"
                                                (utils_linux.go:195 + nsexec.c:1093 setresuid(0,0,0))
uid/gid 映射    直接写 /proc/pid/uid_map        EPERM 时求助 setuid 工具 newuidmap/newgidmap
                                                (nsexec.c:266-294, container_linux.go:1132/1160)
mount ns        随便 unshare/pivot_root         先 unshare userns 再 unshare 其余 ns 即可
                                                (nsexec.c:1054→1107 顺序是 rootless 的命脉)
net ns          unshare + veth + 网桥           被砍:ToRootless 直接删除 netns
                                                (example.go:165-172);替代:宿主网络 + slirp4netns/pasta
cgroup 限制     cgroupfs/systemd 全权写         v2 delegation(systemd --user)可保留;
                                                无委托则忽略错误继续跑(fs2/fs2.go:71-79, ErrRootless)
overlayfs       内核原生 overlayfs 挂载         无 CAP_SYS_ADMIN 挂不了 → fuse-overlayfs(FUSE 用户态)
idmapped mount  MOUNT_ATTR_IDMAP 随便用         明确报错不支持(validator.go:396-398)
设备节点        mknod 直接造                    userns 禁 mknod → 从宿主 bind mount(rootfs_linux.go:958-963)
补充组 setgroups 随便调                        Linux 3.19 起 userns 内禁止 → 静默跳过
                                                (init_linux.go:485-496)
网络设备迁移    可挪宿主网卡进容器              直接拒绝(validator.go:96-98 "not supported for rootless")
keyring         新建 session keyring            失败仅告警,建议 --no-new-keyring
                                                (standard_init_linux.go:60-63)
cgroup 通知 OOM memory.events 监听             仅告警"可能失败"(container_linux.go:864-867)
CRIU 检查点     支持                            "untested with rootless"(checkpoint.go:54-56)
状态目录        /run/runc                       $XDG_RUNTIME_DIR/runc(main.go:95-102)
```

一句话总纲:**userns 把"特权"翻译成了"在你自己被映射的 65536 个 ID 里你是 root"**,凡内核把能力校验锚定在"当前 mount/net/cgroup 层级的属主 userns"上的操作,在新建的属主层级里都能做;锚定在初始 userns 上的(net 设备、cgroup 根、宿主 mount 源)全都要么被砍,要么外包给外部工具。

---

## 2. 判定与映射专节

### 2.1 runc 如何识别 rootless

1. **CLI 侧判定**:每次 create 时 `createContainer` 填两个布尔位——`RootlessEUID: os.Geteuid() != 0`(utils_linux.go:184-204,判定位在 195 行);`RootlessCgroups` 来自 `shouldUseRootlessCgroupManager`(rootless_linux.go:13-53):`--rootless` 显式给值 → 否则 euid!=0 即 true(24-26 行)→ euid==0 但身处 userns(由 `userns.RunningInUserNS()` 判定,27 行)时按 systemd OwnerUID/cgroupfs 情况细分(40-52 行)。`--rootless` 取值 `true/false/auto` 由 `parseBoolOrAuto` 解析(utils.go:125;flag 定义 main.go:131-134)。
2. **"在 userns 里"怎么判**:现行实现外包给 `moby/sys/userns`——先 stat `/proc/self/ns/user`,与内核初始 userns 的魔术 inode `0xEFFFFFFD` 比对,不一致即在 userns;OpenVZ/老内核回退读 `/proc/self/uid_map` 是否为全量映射(vendor/github.com/moby/sys/userns/userns_linux.go:17-53,81)。
3. **历史注脚**:老版本 runc 有 `libcontainer/rootless_linux.go` 且读 `_CONTAINERS_USERNS_CONFIGURED` 环境变量(Docker userns-remap 链路用);本 commit 中该变量与该文件均已消失(grep 全树无命中),判定收敛为"euid + 是否在 userns"两条。
4. **spec 校验关**:`rootlessEUIDCheck` 强制 RootlessEUID 时必须含 userns、且(非 join 场景)必须给 uid/gid 映射,否则报错(libcontainer/configs/validate/rootless.go:14-46);挂载选项里的 `uid=`/`gid=` 若映射不到会报 "cannot specify ... for rootless container"(同文件 50-87 行)。

### 2.2 uidmap 工具链:nsexec 阶段 0 的 EPERM 回退

映射的写入口在卷一 04 章讲过:Go 侧把配置序列化进 netlink bootstrap 数据(container_linux.go:1124-1174)——uid/gid 映射本体(`UidmapAttr`/`GidmapAttr`)、以及 RootlessEUID 时多带的两条 `newuidmap`/`newgidmap` 的**绝对路径**(container_linux.go:1132-1137、1160-1165;runc 在自己进程里 `exec.LookPath` 解析好,免得 nsexec 里再做路径查找)。同时写入 `RootlessEUIDAttr`(1184-1188;属性号定义 libcontainer/message_linux.go:19-23,与 C 侧 nsexec.c:107-109 对应)。

C 侧 stage-0 收到 `SYNC_USERMAP_PLS` 后(nsexec.c:890-913):

```c
/* nsexec.c:903-908(rootless 单条映射时先关 setgroups) */
if (config.is_rootless_euid && !config.is_setgroup)
        update_setgroups(stage1_pid, SETGROUPS_DENY);
/* Set up mappings. */
update_uidmap(config.uidmappath, stage1_pid, config.uidmap, config.uidmap_len);
update_gidmap(config.gidmappath, stage1_pid, config.gidmap, config.gidmap_len);
```

`update_uidmap` 的回退链是关键(nsexec.c:266-279):直写 `/proc/pid/uid_map`,若得到 `-EPERM` 则改调 `try_mapping_tool` fork+execve `newuidmap`(nsexec.c:200-264,把空格/换行分隔的映射串切成 argv)。这正是 setuid 辅助工具存在的意义:**内核规定非初始 userns 写映射要 CAP_SETUID 且只能写自己的映射,而 newuidmap 持有 setuid 位、按 /etc/subuid 白名单代写**。注意:本 commit 的 runc 自身不解析 /etc/subuid(subuid 解析只在 vendored 的 moby/sys/user 库里,runc 核心仅用其做 HOME 查找,libcontainer/env.go:87),范围核对完全交给外部工具。

### 2.3 映射的"倍增"语义

- **uid/gid 双份**:一份 userns 配置在内核要写两遍(uid_map+gid_map),spec 侧也要 `uidMappings`+`gidMappings` 各一份;校验器要求两者都非空(validate/rootless.go:38-43)。工具也是成对的:newuidmap 与 newgidmap 各 LookPath 一次、各写一次(container_linux.go:1127-1173)。
- **单条映射豁免**:`requiresRootOrMappingTool` 定义——当 gid 映射恰为 `{ContainerID:0, HostID:当前egid, Size:1}` 这一条时不需任何特权工具(container_linux.go:1230-1236)。这就是 `runc spec --rootless` 生成的"把自己映成容器 root"最小映射(example.go:179-189);多段映射(如 0→65536 一整段 subuid)则必须走 newuidmap/newgidmap(`SetgroupAttr` 置位,container_linux.go:1167-1172)。
- **join 已有 userns**:spec 给 `userns.path` 时跳过全部映射写入(container_linux.go:1123-1125),改由 specconv 缓存目标 ns 的现有映射供内部换算(spec_linux.go:1085-1118);path+映射并存且不一致会报错,一致则降级为警告(CRI/CRIO 历史兼容,1095-1109 行)。

---

## 3. namespace 专节:userns 之下各 ns 的可行性

内核规则:unshare/setns 某个 ns,需要**该 ns 当前属主 userns** 里的 CAP_SYS_ADMIN。runc 的破局点在 nsexec 阶段 1 的顺序:**先单独 unshare userns 并等阶段 0 写完映射,拿到"userns 内满能力"后,再 unshare 其余 ns**——此后新建的 mount/pid/ipc/uts ns 均由新 userns 属主,校验自然通过(nsexec.c:1054-1095 单独处理 userns、setresuid(0,0,0) 在 1093;剩余 ns 在 1107 行 `try_unshare(config.cloneflags, ...)`;1054 行前的大段注释解释了为何不能一次 unshare 完——mqueue SELinux 标签等内核 bug)。各 ns 结论:

| namespace | rootless 可用? | 代码依据 |
|---|---|---|
| user | 必须,且第一个 unshare | validate/rootless.go:33;nsexec.c:1054-1056 |
| mount | 可用(关键!属主随 userns 切换) | nsexec.c:1107 顺序保证;prepareRootfs 正常走 rootfs_linux.go:170-193 |
| pid | 可用 | 同上;spec 默认含 NEWPID(specconv/example.go:131-147) |
| uts/ipc | 可用 | 同上 |
| cgroup | 可用,v2 默认 spec 会加 | example.go:150-154 |
| time | 可用 | specconv/spec_linux.go:49-56 映射表含 NEWTIME |
| **network** | **被砍** | `ToRootless` 显式剔除并回填 userns(example.go:165-177);若用户仍要 private netns,runc 只能配一个 loopback(spec_linux.go:459-465,network_linux.go:89-105) |

netns 被砍的原因:宿主 net ns 属主仍是初始 userns,新建的 userns 对它没有 CAP_NET_ADMIN,`unshare(CLONE_NEWNET)` 需要 CAP_SYS_ADMIN,而 net ns 的属主 userns 永远是初始 userns——所以无特权用户**永远**造不出自己的 netns,这与 mount ns 的"随建随属主"不同。连带后果:`runc spec --rootless` 产物里 /sys 被降级为宿主 /sys 的 `rbind,ro`(example.go:194-203),资源字段整个清空 `spec.Linux.Resources = nil`(218-219 行)。

---

## 4. cgroup 委托专节:v2 delegation 的两条路

### 4.1 rootless cgroup manager 的选择

`shouldUseRootlessCgroupManager` 决定 `RootlessCgroups`(rootless_linux.go:13-53),随 `CreateOpts` 进 specconv(spec_linux.go:378-379、412-413),再进 cgroup 配置 `Cgroup.Rootless`(spec_linux.go:789)。manager 按环境分派:systemd 且 `--systemd-cgroup` → systemd UnifiedManager;cgroup v2 否则 → fs2;v1 → fs(manager/new.go:26-45,vendored github.com/opencontainers/cgroups v0.1.0)。

### 4.2 systemd --user 路径(v2 推荐)

Rootless 时 dbus 连接改拨**用户实例**总线:`newDbusConnManager(rootless)` → `newUserSystemdDbus()`,地址取 `$DBUS_SESSION_BUS_ADDRESS` 或 `$XDG_RUNTIME_DIR/bus`(systemd/dbus.go:20-75;systemd/user.go:19-51、80-96)。cgroup 路径不再是 `system.slice` 而是挂到当前用户的 `user@UID.service` 之下:

```go
/* systemd/v2.go:455-473(节选,getSliceFull) */
if c.Rootless {
        slice = "user.slice"
}
...
managerCG, err := getManagerProperty(m.dbus, "ControlGroup")
slice = filepath.Join(managerCG, slice)
/* 注释示例:/user.slice/user-1001.slice/user@1001.service/user.slice/libpod-*.scope */
```

建 scope 时带 `Delegate=true`(systemd/v2.go:299-314)——systemd 把整个子树委托给 runc,内核侧配合 chown `/sys/fs/cgroup` 下 `cgroup.procs`/`cgroup.subtree_control` 等委托文件(清单读自 `/sys/kernel/cgroup/delegate`,老内核用硬编码三件套;v2.go:392-417)。fs2 直写路径则靠逐级 `mkdir` + 写 `cgroup.subtree_control` 推控制器(fs2/create.go:70-150,subtree_control 在 83 行、137-146 行;部分控制器 rootless 下不可用,144-145 行注释明确"不在此处报错")。

### 4.3 无委托时的"带病运行"

fs2 `Apply` 里 `CreateCgroupPath` 失败且 Rootless 时:无自定义路径且不需要任何控制器 → 返回哨兵 `ErrRootless`(fs2/fs2.go:65-85,cgroups.go:12-15);v1 同理(fs/fs.go:129-140)。Go 侧对这个错误**选择性容忍**(process_linux.go:825-838):仅当容器没有私有 pid ns 时才告警——因为没有 cgroup 就没法 `signalAllProcesses` 杀干净进程(container_linux.go:851-860 给出 "Hint: enable cgroup v2 delegation")。另一处礼貌处理:rootless 下挂 /sys/fs/cgroup 失败(ENOENT)改为 maskDir 掩蔽该目录保证只读(rootfs_linux.go:423-433)。v1 在 rootless 下基本出局:各控制器目录写不动,全靠 `isIgnorableError(Rootless, ...)` 降级(fs/fs.go:129-140),等价于无 cgroup。

---

## 5. 替代品生态专节(机制各一句话)

- **fuse-overlayfs**:内核 overlayfs 挂载要求挂载者对底层目录所在 userns 有 CAP_SYS_ADMIN,rootless 拿不到;fuse-overlayfs 改用 FUSE——把"合并视图"实现在用户态守护进程里,内核只需允许普通用户挂 FUSE。runc 本身不集成它,只负责把 spec 里的 rootfs 原样处理(无任何 overlay 分支);另外 runc 明确拒绝 rootless 下使用 idmapped mounts(validator.go:393-398 "not supported for rootless containers")。新内核(5.11+)已允许在 userns 内挂原生 overlayfs,属内核侧补救。
- **slirp4netns**:rootless 没有 netns、更没有 veth 可配;slirp4netns 在宿主侧起用户态进程,把容器的 tap 设备流量在用户态翻译成宿主 socket——"用纯用户态 TCP/IP 栈顶替内核网络栈"。
- **pasta**(passt 的 runc 配套):同样思路的后来者,不再经过 tap+slirp 常驻进程模型,直接以用户态实现协议栈并接管 socket 转发,podman 新版默认换用它。
- **newuidmap/newgidmap**(上文 2.2):setuid 位的"特权外包",按 /etc/subuid、/etc/subgid 白名单替无特权用户写多段映射——runc 官方文档把它列为 rootless 前置依赖。

---

## 6. 设计动机

1. **单用户多容器隔离**:rootless 的价值不是"防容器内攻击者",而是把同一台多用户机器上不同普通用户的容器互相隔离——容器内 root 经映射只是"你的 uid 区间里的 0",宿主的 root 文件、别人的进程、别人的 cgroup 天然不可见不可写。这也是 `RootlessEUID` 与 `RootlessCgroups` 拆成两个开关的原因(configs/config.go:219-227):euid==0 但在 userns 里(如嵌套场景)时前者为假、后者可为真,`shouldUseRootlessCgroupManager` 的三分支正是为嵌套 rootless 设计(rootless_linux.go:31-52)。
2. **为什么不能全量 OCI**:OCI spec 是为特权运行时写的全集——netns、cgroup 资源、device mknod、idmapped mount、网络设备迁移等字段都以初始 userns 能力为前提。runc 的策略是"三选一":转换(`runc spec --rootless` 生成合法子集,spec.go:77-91 + example.go:158-220)、报错(idmapped mount、netdev 迁移,validator.go:96-98、393-398)、静默降级(补充组 init_linux.go:485-496、OOM 通知 container_linux.go:864-867)。上游不给 rootless 单独立 spec,而是让 `ToRootless` 充当"官方裁剪模板"。
3. **内核的 userns 边界**:内核把两类权限钉死——(a) 对"层级属主 userns"的 CAP 校验(mount/net/cgroup),runc 用 unshare 顺序把能变成属主的层级(mount/pid/ipc/uts)都变成属主,变不了的(net)砍掉;(b) 写 /proc/*/uid_map 的特权,外包给 setuid 工具。runc 的 rootless 支持史,本质上就是不断把第 (a) 类里内核新放开的层级(cgroup ns、time ns、threaded cgroup、userns 内 overlayfs)接进主链路。

---

## 7. FAQ 素材

1. **runc 怎么知道自己是 rootless?** 看 euid 与是否身处 userns 两个信号(utils_linux.go:195;rootless_linux.go:24-27),`--rootless=auto` 是默认。
2. **为什么 rootless 必须有 userns?** 校验器硬性要求,没有 userns 就没有任何"容器内 root"可言(validate/rootless.go:32-35)。
3. **为什么 uid 映射有时不需要 newuidmap?** 单条 `0→自己的euid,Size=1` 映射内核允许直写;只有多段映射才需要 setuid 工具(container_linux.go:1230-1236,nsexec.c:903-908)。
4. **为什么写 /proc/pid/setgroups?** Linux 3.19 起带映射的 userns 必须先写 `deny` 才能写 gid_map;rootless 单条映射场景 runc 主动 deny 并放弃补充组(nsexec.c:893-904;init_linux.go:492)。
5. **rootless 下 mount ns 为什么反而能建?** 因为 unshare 顺序:userns 先建,新 mount ns 的属主随之变成新 userns,能力校验自洽(nsexec.c:1054→1107)。
6. **rootless 为什么没网络?** net ns 属主永远是初始 userns,unprivileged 无法创建;`ToRootless` 直接删掉该 ns(example.go:165-172),连通性交给 slirp4netns/pasta。
7. **rootless 有没有资源限制?** v2 + systemd delegation 有(`Delegate=true`,v2.go:314);否则 fs2 返回 ErrRootless、runc 忽略之(process_linux.go:825-838)——"可以跑,但没限流"。
8. **/dev 下的设备怎么来的?** userns 禁止 mknod,runc 改为从宿主 bind mount 设备节点(rootfs_linux.go:958-963;EPERM 兜底再 bind,1004-1008)。
9. **状态目录为什么变了?** /run/runc 普通用户写不进,有 `$XDG_RUNTIME_DIR` 时用 `$XDG_RUNTIME_DIR/runc`(main.go:95-102,euid==0 in userns 有个 USER!=root 的兼容判断,rootless_linux.go:55-69)。
10. **checkpoint/restore 能用吗?** 官方明说 untested,只告警不阻止(checkpoint.go:54-56,restore.go:111-113)。

## 深挖线索

1. **`requiresRootOrMappingTool` 的演进**:它把"要不要 setuid 工具"压缩成一次 DeepEqual(container_linux.go:1230-1236),对比 1.0 时代"凡 rootless 必设 SetgroupAttr"的粗粒度——可写"单条映射豁免"专题。
2. **netlink bootstrap 的属性号带区**:27285-27289(SETGROUP/ROOTLESS_EUID/UIDMAP_PATH/GIDMAP_PATH,message_linux.go:19-23)与 nsexec.c:107-109 一一对应,是 Go↔C ABI 的活标本,可与卷一 04 章互相印证。
3. **userns fd 路线**:libcontainer/internal/userns/usernsfd_linux.go 用 `CLONE_NEWUSER`+`USERNSFD` 预建 userns 句柄池(注释提到 Go stdlib 不支持 newuidmap 语义,88 行附近),是 Linux 6.x usernsfd 特性在 runc 的落地,代表未来方向。
4. **cgroup OwnerUID 铸造**:specconv 会把容器 cgroup chown 给进程 UID 的宿主映射值,且仅在有 cgroup ns + rw cgroupfs 时启用(spec_linux.go:550-590)——解释了 podman rootless 的 cgroup 目录归属。
5. **mount 求助线程的 rootless 短路**:父进程的 `goCreateMountSources`(open_tree 式 mountfd 服务)在 RootlessEUID 下整体不启动,注释点破原因"同一用户,帮也没用"(process_linux.go:875-882;rootfs_linux.go:121-126)——mount 委托链在 rootless 的坍缩点。

---

## 写作要点速查表(函数 → 行号)

| # | 函数/位置 | 行号 | 一句话 |
|---|---|---|---|
| 1 | utils_linux.go `createContainer` | 184-204(判定位 195) | RootlessEUID = euid!=0 |
| 2 | rootless_linux.go `shouldUseRootlessCgroupManager` | 13-53 | RootlessCgroups 判定,含 userns 嵌套 |
| 3 | rootless_linux.go `shouldHonorXDGRuntimeDir` | 55-69 | 状态目录选 XDG |
| 4 | main.go `--rootless` flag / XDG root | 131-134 / 95-102 | true/false/auto;/run/runc 替代 |
| 5 | validate/rootless.go `rootlessEUIDCheck` | 14-46 | 必须有 userns+映射 |
| 6 | example.go `ToRootless` | 158-220(删 netns 165-177;单条映射 179-189;/sys→rbind 194-203;Resources=nil 219) | 官方 rootless spec 模板 |
| 7 | container_linux.go 映射写入 | 1124-1174(newuidmap 路径 1132;gid 1160;RootlessEUIDAttr 1185-1188) | netlink 下发映射 |
| 8 | container_linux.go `requiresRootOrMappingTool` | 1230-1236 | 单条 gid 映射豁免 |
| 9 | nsexec.c stage-0 写映射 | 890-913(deny setgroups 903;update_uidmap 调用 907-908) | EPERM→newuidmap |
| 10 | nsexec.c `update_uidmap`/`try_mapping_tool` | 266-294 / 200-264 | setuid 工具回退链 |
| 11 | nsexec.c stage-1 unshare 顺序 | 1054-1107(setresuid 1093) | userns 先行的命脉 |
| 12 | spec_linux.go `setupUserNamespace` | 1080-1132 | spec 映射→config;join userns 缓存 |
| 13 | init_linux.go `setupUser` | 464-510(allowSupGroups 492) | rootless 舍弃补充组 |
| 14 | rootfs_linux.go 设备 bind 兜底 | 955-970(useBindMount 958;EPERM→bind 1004-1008) | mknod 不可用 |
| 15 | rootfs_linux.go cgroup2 mask 兜底 | 410-433(ENOENT→maskDir 423-433) | rootless cgroup 只读化 |
| 16 | systemd/v2.go rootless slice/Delegate | 299-314;getSliceFull 446-474 | user@UID.service 委托 |
| 17 | systemd/user.go `newUserSystemdDbus`/`DetectUID` | 19-51 / 53-78 | 拨用户 dbus |
| 18 | fs2/fs2.go `Apply` + `ErrRootless` | 65-85(fs2.go:74;定义 cgroups.go:12-15) | 无权限时的哨兵降级 |

(全文行号核对基准:runc commit 579be22,vendored 依赖为 github.com/opencontainers/cgroups v0.1.0、moby/sys/userns v0.2.1。)
