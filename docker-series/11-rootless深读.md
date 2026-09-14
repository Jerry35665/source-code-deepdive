# 第 11 章 · rootless 深读:无特权容器的全链

> 基线:commit `579be22`。行号以 libcontainer/rootless_linux.go、utils_linux.go、libcontainer/nsenter/nsexec.c 为准。**勘误**:老版本的 `_CONTAINERS_USERNS_CONFIGURED` 环境变量检测已不存在,判定收敛为 euid+RunningInUserNS(moby/sys/userns,按 /proc/self/ns/user inode 0xEFFFFFFD 比对)。

## 11.0 全景:能力削减表

| 面 | 特权容器 | rootless 的替代 |
|---|---|---|
| 身份 | 真 root | euid!=0→新建 userns,容器内"伪 root"(utils_linux.go:195) |
| uid 映射 | 直写 uid_map | 外包 setuid 工具 newuidmap/newgidmap(:903-908) |
| net ns | 可建 | **彻底被砍**(ToRootless 删除);替代 slirp4netns/pasta 用户态网络栈 |
| cgroup | 可建 | v2 systemd delegation 可保留;否则 ErrRootless 降级"无限制照跑" |
| overlayfs | 原生 | fuse-overlayfs(FUSE 用户态合并) |
| 设备节点 | mknod | userns 禁 mknod→从宿主 bind mount |
| 其他 | — | 补充组静默跳过/idmapped mount 报错/netdev 迁移报错/CRIU untested |

## 11.1 映射机制:newuidmap 工具链

Go 侧把 uid/gid 映射+newuidmap 绝对路径**序列化进 netlink bootstrap**(container_linux.go:1124-1174)→C 侧 nsexec stage-0 收到 SYNC_USERMAP_PLS 后(:1054→:1107):rootless 单条映射先写 `setgroups=deny`,再直写 /proc/pid/uid_map,**EPERM 时 fork+execve newuidmap**(按 /etc/subuid 白名单代写,runc 自身不解析 subuid)——setuid 辅助工具是内核权限模型下的必要外包。映射成对成倍:uid/gid 各一份、工具各一个;**单条 {0,egid,1} 映射可豁免工具**(requiresRootOrMappingTool,:1230;container_linux.go:1230-1236)。

## 11.2 namespace 与 cgroup 委托

**rootless 能建 mount/pid ns 的命脉是"先 unshare userns"**(nsexec.c:1054→:1107):userns 内的进程"重新是 root",后续 unshare 才被允许。cgroup 委托:v2 的 systemd 路径挂 `user@UID.service`+`Delegate=true`(systemd/v2.go:299-314,:446-474)——**用户被 systemd 授权一段 cgroup 子树**;无委托时 fs2 返回 ErrRootless,runc 选择性忽略(fs2/fs2.go:65-85+process_linux.go:825-838:无私有 pidns 时告警照跑)。ToRootless(example.go:158-220):删 netns、加单条映射、/sys 降 rbind ro、清空 Resources——**把特权 spec 自动降级成 rootless 可运行的等价物**。

## 11.3 替代品生态与设计动机

fuse-overlayfs(FUSE 用户态层合并)/slirp4netns+pasta(用户态网络栈:tap 设备+用户态 TCP/IP)——**内核不给的能力,用户态补**。设计动机:

1. **rootless 的安全意义**:单用户多容器隔离(同一 uid 的多租户)——userns 把"容器内 root"与"宿主 root"解耦,越狱也只到映射 uid;
2. **为什么不能全量 OCI**:spec 的 devices/mounts 隐含 CAP_SYS_ADMIN;userns 边界=内核能力边界;
3. **newuidmap 的存在理由**:uid_map 写入要求"映射的宿主 uid 必须是自己的或持 CAP_SETUID"——subuid 白名单把"分配权"交给 setuid 小工具;
4. **ErrRootless 的选择性忽略**(:825-838):没有 cgroup 也能跑(资源不限)——功能降级而非功能失败。

## 11.4 FAQ

**Q1:rootless 容器里的 root 是谁?**
userns 映射后的宿主普通用户(:903-908):容器内权限大,宿主面小。

**Q2:为什么需要 newuidmap?**
多条映射超出"自写"权限:setuid 工具按 subuid 白名单代写。

**Q3:rootless 能有自己的网络吗?**
没有 netns:slirp4netns/pasta 在用户态实现 TCP/IP——内核不放行,生态补位。

**Q4:cgroup 在 rootless 下完全没用吗?**
v2+systemd 委托下有用(:299-314):user@UID.service 的子树可自由控制。

**Q5:subuid/subgid 文件在哪?**
/etc/subuid、/etc/subgid:newuidmap 的授权源(runc 不解析,工具解析)。

**Q6:rootless 下 overlayfs 怎么办?**
fuse-overlayfs:FUSE 用户态实现层合并——性能换可行。

**Q7:设备节点怎么给?**
mknod 被 userns 禁:宿主 bind mount 进容器——硬件面靠宿主预置。

**Q8:rootless 容器能 CRIU 吗?**
明确 untested(卷二 I 章):userns 映射恢复是深水区。

**Q9:判定"已在 userns 里"的方法?**
/proc/self/ns/user 的 inode 与 0xEFFFFFFD 比对(moby/sys/userns)。

**Q10:docker/podman 的 rootless 与 runc 的关系?**
上层负责配 userns+选 fuse/slirp;runc 只管"拿到合法 spec 后落地"。

## 11.5 小结与深挖方向

本章结论:**rootless="userns 为根基的削减与替代体系"**;每一项被砍能力都有一个用户态替代品,生态补位的完整度决定 rootless 的可用性。深挖:

1. newuidmap(:903-908)的 setuid 面最小化审计;
2. nsexec 先 userns(:1054-1107)在 SELinux 环境的标签约束;
3. systemd --user delegation 在无登录会话(纯容器宿主)的可用性;
4. fuse-overlayfs 与原生 overlay 的性能差距曲线;
5. userns 嵌套(runc in runc)的映射叠加。

> 下一章(卷末):leases 与 GC——资源生命周期管理。
