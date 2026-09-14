# 第 06 章 · OCI 规范落地与工程文化:spec 如何变成内核调用(卷末)

> 基线:commit `579be22`。行号以 libcontainer/specconv/、libcontainer/exeseal/、tests/ 为准。**勘误**:本 commit 的 cgroups 已外置为 opencontainers/cgroups 模块;依赖面只有三个 OCI 系仓库(go.mod:19-21:opencontainers/cgroups、runtime-spec v1.3.0、selinux)——image-spec 零依赖(镜像解包在 containerd 侧)。

## 6.0 全景:config.json 的字段旅程

```
config.json(specs.Spec)→ specconv.CreateLibcontainerConfig(spec_linux.go:384-624)
  → configs.Config(内核可执行形态)→ 各安全子系统加载(05 章/本章)
```

runc 唯一翻译层是 CreateLibcontainerConfig:映射表显式化(initMaps :49);**未知命名空间报错、未知 capability 仅告警**(capabilities.go:71)——两种策略刻意相反:ns 错=语义崩,cap 错=保守缺。翻译期即校验:NoPivotRoot+rootfsPropagation=private 组合拒绝(spec_linux.go:444);挂载字段含 NUL 字节拒绝(:676-684,字段走 netlink 序列化会被截断)——**校验靠近翻译,不留给内核**。

## 6.1 hooks:五个时机的精确语义

| hook | 执行点 | 行号 | 进程内/外 | 能做什么 |
|---|---|---|---|---|
| prestart(弃用) | 父进程,与 createRuntime 同点 | process_linux.go:1036 | 容器 ns 外 | 旧兼容 |
| createRuntime | 父进程,cgroup Set 之后 | :1039(:1018 先 Set cgroup) | ns 外 | K8s 的 CNI 类操作 |
| createContainer | init 进程内,pivot_root 前 | rootfs_linux.go:229 | 新 ns 内 | ns 内视角操作 |
| startContainer | 紧贴 execve | standard_init_linux.go:285 | ns 内 | 最后一刻干预 |
| poststop | 容器退出后 | container_linux.go:341-361 | 任意 | 清理(失败则 SIGKILL 容器) |

常量与统一执行 Hooks.Run(configs/config.go:423-447,:536);env 默认继承 init 是 "de facto" 非规范(:216-218 注释)。**五个时机对应五个"谁的视角、什么隔离状态"**——hook 系统的正确性全在时机语义。

## 6.2 安全机制落地:四件套与双时机

- **seccomp 双时机**:无 NoNewPrivileges 时先装 filter 再丢权(:191,装 filter 本身需特权);有 NNP 则拖到 execve 前最后一刻(:239)——最小化 profile 需覆盖的 runc 自身 syscall;seccomp notify 要求 libseccomp API≥6(:47),**write 不可被 notify、不可做默认 action**(:62-71,否则 fd 回传死锁);父进程经 pidfd_getfd 取 fd 后发给 ListenerPath agent(process_linux.go:532-578);加载走 patchbpf.PatchAndLoad(:729),手工补 **ENOSYS stub** 的 BPF(未知 syscall 返回 ENOSYS 而非杀进程);
- **capabilities 次序**:ApplyBoundingSet(先于 setuid)→SetKeepCaps→setupUser→ApplyCaps(init_linux.go:336-365);ambient 单独逐颗设、EINVAL 忽略(capabilities.go:133-147);
- **apparmor/SELinux**:加载点 :131/:183-187(setns 路径 :120)。

## 6.3 exeseal:CVE-2019-5736 的防御标本

攻击模型:容器进程经 `/proc/<pid>/exe` **换绑宿主 runc 二进制**——下次 runc 启动即执行恶意代码。防御:runc init 从封印克隆启动(container_linux.go:553-575):已克隆复用,否则 CloneSelfExe。**三级回退**(cloned_binary_linux.go:218):

1. overlayfs 零拷贝只读叠加(overlayfs_linux.go:53,无法 unwrap、零开销);
2. memfd+全套 F_SEAL(:43,约 60% 启动开销);
3. O_TMPFILE/mktemp(:85/:103,校验 Nlink==0、跳过 noexec)。

IsSelfExeCloned 用 F_GET_SEALS 验证(:254)。同思想延续:**CVE-2016-9962**(fifo 时序)、**CVE-2024-21626**(exec 前 UnsafeCloseFrom :275/:288-300)——runc 的 CVE 史=exec 次序的边界史。

## 6.4 工程文化:rootless 幂集与 CVE 流程

测试:40 个单测文件 vs **59 个 bats 集成文件**;README 明言集成测试不替代单测;**rootless.sh 用特征幂集**(idmap×cgroup 全组合)跑完整套件(:25-29,:174-196)——rootless 是矩阵不是开关。CVE 流程:SECURITY.md 仅一条规则——**不开 issue 走 OCI 组织级私密上报**;旧分支修复门槛 CVSS≥7.0(RELEASES.md)。发布:6 个月 minor、提前 2 个月 rc+冻结、latest/latest-1/latest-2 三级支持;**semver 只承诺二进制不承诺 Go API**;VERSION 经 go:embed 入二进制(main.go:27-30)。PRINCIPLES.md 13 条格言(如 "No is temporary; Yes is forever")。

## 6.5 设计动机

1. **为什么 hooks 要五个时机**:容器生命周期中"谁的视角+什么隔离状态"有五种组合——hook 语义=时机语义,含糊即漏洞;
2. **为什么 seccomp 尽量晚**:filter 对 runc 自身同样生效——**应用顺序与能力递减必须同步规划**;
3. **exeseal 的分层防御**:三级回退按"开销从零到高"排列,环境自适应——安全机制的部署友好性;
4. **"No is temporary; Yes is forever"**:PRINCIPLES.md 的格言直指 API 演进:拒绝的功能可以再给,给出去的收不回——与 FFmpeg/Git 的 ABI 纪律同源(系列公理 6)。

## 6.6 FAQ

**Q1:prestart 弃用了,我该用什么?**
createRuntime(同执行点,:1036/:1039)——语义更准确的改名。

**Q2:未知 capability 为什么只告警?**
(:71):保守缺一颗 cap 只影响功能;报错则新内核 cap 直接崩——可用性优先。

**Q3:seccomp notify 为什么 write 不能被拦截?**
(:62-71):notify 的 fd 回传本身要走 write——自指死锁。

**Q4:ENOSYS stub 是什么?**
未知 syscall 返回 ENOSYS(而非默认 action):应用可优雅降级(:729 的 BPF 补丁)。

**Q5:exeseal 三级回退会都用吗?**
环境自适应:overlayfs 最优(:53),非 overlay 落 memfd(:43)/tmpfile(:85)。

**Q6:rootless 测试为什么是幂集?**
(:174-196):idmap×cgroup 的组合各有坑——特性组合测试而非特性测试。

**Q7:旧分支什么情况才修?**
CVSS≥7.0(RELEASES.md):维护带宽的显式预算。

**Q8:semver 不承诺 Go API,用户怎么办?**
runc 定位是二进制工具:调用方走 CLI;库用户自己锁版本。

**Q9:hooks 失败会怎样?**
poststart 失败 SIGKILL 容器(:341-361)——hooks 是承诺不是尽力而为。

**Q10:NUL 字节校验为什么在翻译期?**
(:676-684):netlink 截断是静默的——错误必须在能报错的地方报。

## 6.7 小结与卷末语

本章结论:**OCI 落地="显式翻译层+五时机 hooks+安全机制的应用次序纪律+CVE 驱动的防御演进"**。

至此《Docker 深读》卷一完(containerd 01-03 + runc 04-06,基线 f6132db/579be22,6 章+6 报告)。容器栈的全链:插件 DAG→bolt 元数据→pull 管道→overlayfs→shim→runc 两阶段→namespace/cgroups/rootfs→OCI 落地。深挖方向:

1. plugin DAG 的运行时动态注册(:114-135);
2. overlayfs 三分支(:555-618)在 zfs/btrfs 后端的对等实现;
3. shim Pod 复用(:200-233)与 systemd cgroup driver 的组合;
4. exeseal overlayfs 路径(:53)的 unwrappability 论证;
5. rootless 幂集矩阵(:174-196)的 CI 成本与覆盖收益。

— 《Docker 深读》卷一完。AI 编码助手:GLM-5.3-Flash。
