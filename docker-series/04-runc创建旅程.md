# 第 04 章 · runc 创建旅程:从 bundle 到 execve

> 基线:commit `579be22`(1.5.0-rc.1+dev)。行号以 cmd/runc/、libcontainer/ 为准。runc 是 OCI runtime 参考实现——**create 与 start 是两个独立命令**,两阶段设计是理解一切的钥匙。

## 4.0 全景:create/start 旅程

```
runc create → main.go:88 分派 → create.go:67 startContainer(CT_ACT_CREATE)
  → setupSpec 读 bundle/config.json → specconv 翻译(06 章)
  → libcontainer.Create(factory_linux.go:35-103):建 /run/runc/<id>/ 状态目录
  → container.Start(container_linux.go):
      mkfifo exec.fifo → 克隆自身为安全 exe(exeseal)→ exec.Command(exe,"init") 自我重执行
      → initProcess.start:netlink bootstrap → 收双 pid → 发 initConfig JSON
      → sync 管道握手:procHooks/procReady/procRun
      → procReady 时父进程设 rlimits 并落盘 state.json → 状态 created
runc start → Load state.json → 往 exec.fifo 写一字节 → init 进程 execve 用户程序
```

**create 天然 detach**(utils_linux.go:224)——这就是 state.json 必须落盘的原因:父进程走了,状态要活着。

## 4.1 init 重执行:nsexec 三级跳

**为什么自我重执行**:容器配置要求"进入 namespace 之后再初始化 Go runtime",而 Go 无法在运行中途 unshare——所以 runc 以 `/proc/self/exe` 重新执行自己,带 `init` 参数走 C 阶段。nsenter 包用 **C constructor 在 Go runtime 之前跑 nsexec()**(nsenter/nsenter.go:13);无 `_LIBCONTAINER_INITPIPE` 环境变量则直接返回(普通 runc 命令不受影响)。

nsexec 三级跳(顺序有论证):
- **stage-0**:写 uid/gid map 并转发 pid(user namespace 的 map 必须在外部写);
- **stage-1**:setns 加入已有 ns——**先 unshare userns**(特权判定上下文),且必须分步防 mqueue/SELinux 标签错乱→setresuid(0)→一次 unshare 其余 ns;
- **stage-2**:因 **PID ns 只对子进程生效**而再次 fork,setsid/setuid(0) 后唯一返回 Go runtime。

join_namespaces 按"非 user→user→剩余"三段排序(D 报告 :107-140 区段)。**通道全部用环境变量指路**:`_LIBCONTAINER_{INITPIPE,SYNCPIPE,LOGPIPE,FIFOFD,INITTYPE}`,fd 从 3 起编号(container_linux.go:30,:599-620)。

## 4.2 init 子进程与 final exec 次序

bootstrap 是自定义 netlink 消息(cloneFlags/nsPaths/uidmap/oom_score_adj,container_linux.go:1088-1203);initConfig JSON 走同一条 init pipe 二次投递,子进程 **Decode 后 os.Clearenv() 在前**(process_linux.go:904;init_linux.go:220,:233)。**final exec 前的次序铁律**(standard_init_linux.go:51-303):apparmor(:131)→sysctl→procReady→capabilities(bounding→setuser→**verifyCwd 防 CVE-2024-21626**→ApplyCaps,:336-365)→seccomp 尽量晚(:191 无 NNP 时先装 filter 再丢权,:239 有 NNP 拖到 execve 前)→写 fifo "0"→UnsafeCloseFrom→`linux.Exec`(:303)。**次序即安全**:每一步的前置条件都是上一步的产物。

**安全 exe**:自我重执行前先经 exeseal 克隆防 CVE-2019-5736(container_linux.go:566-582;exeseal/cloned_binary_linux.go:218——06 章展开)。

## 4.3 状态同步:exec.fifo 与握手

`exec.fifo` 的存在性=created/running 的判定依据(container_linux.go:930-934):init 进程阻塞在读 fifo,`runc start` 写一字节即放行——**两个命令的同步点是文件系统**。sync 管道握手(procHooks/procReady/procRun)让父进程在精确的时点介入(设 rlimits/跑 hooks/落盘 state.json:procReady 才落盘,临时文件+rename 原子写,process_linux.go:983-1015;container_linux.go:882-906)。bootstrap 的 netlink 消息(:1088-1203) carrying cloneFlags——**netlink 而非环境变量传结构化配置**:环境变量在 setns 后可能被污染。

## 4.4 设计动机

1. **为什么 create/start 分离**:OCI 语义要求"容器可检视后再启动"(hooks/上层介入),分离让 shim/containerd 能在 created 状态挂接——**两阶段是生态位,不是历史包袱**;
2. **为什么 init 用 C 写阶段逻辑**:setns/unshare 必须发生在 Go runtime 启动前(Go 的线程模型与 namespace 不兼容);nsenter 的 constructor 技巧(C 编译进二进制自动执行)是 Go 与内核操作之间的标准桥;
3. **为什么状态在 /run**:运行时状态属于 tmpfs(重启即清)——与 09 章 state 语义一致;
4. **netlink bootstrap**:结构化+无污染——环境变量通道只留"指路"用途。

## 4.5 FAQ

**Q1:为什么 runc create 后要单独 start?**
OCI 语义:created 状态允许上层(runtime hooks/监控)介入后再放行——生态需要。

**Q2:init 进程是 Go 程序吗?**
是 runc 自身(重执行),但走 nsexec C 阶段完成 namespace 进入后才回 Go(:13)。

**Q3:exec.fifo 为什么能当状态机?**
init 阻塞读 fifo:文件存在=created;被写入=running(:930-934)——文件系统即同步原语。

**Q4:PID namespace 为什么要在 stage-2 再 fork?**
PID ns 只对"之后创建的子进程"生效(:107-140 论证):当前进程不在新 PID ns 里。

**Q5:userns 为什么要最先 unshare?**
特权判定要在 userns 隔离后重新评估(mqueue/SELinux 标签错乱问题):分步是正确性要求。

**Q6:config.json 怎么传给 init?**
fd 通道 JSON(:904):不走命令行(参数表长度与转义)。

**Q7:seccomp 为什么"尽量晚"装?**
装 filter 后 runc 自身也被限制:越晚装需要覆盖的自身 syscall 越少(:191/:239)。

**Q8:state.json 记什么?**
init pid/状态/ bundle 路径/创建时间(:983-1015):`runc start/kill/delete` 靠它重建对象。

**Q9:exeseal 防的是什么攻击?**
CVE-2019-5736:容器进程换绑宿主 runc 二进制(:566-582)——06 章展开。

**Q10:verifyCwd 防什么?**
CVE-2024-21626:工作目录指向已关闭 fd 的泄漏(:336-365 区段)——runc 的 CVE 史即 exec 次序史。

## 4.6 小结与深挖方向

本章结论:**runc="两阶段命令+C 自我重执行+netlink bootstrap+文件系统同步点"**;exec 次序是安全史。深挖:

1. nsexec stage-1 的 userns 分步(:107-140)在无 userns 内核的降级;
2. netlink bootstrap(:1088-1203)的消息长度上限;
3. procHooks 用户代码在容器内执行的权限面;
4. state.json 的 rename 原子写在崩溃窗口的完整性;
5. exeseal 的 overlayfs 路径(:218)在不同文件系统的回退实测。

> 下一章:cgroups 与 rootfs——资源与文件系统两个隔离面。
