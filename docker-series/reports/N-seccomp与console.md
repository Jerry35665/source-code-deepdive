# N 章:seccomp notify(容器内 syscall 代理)与 console/tty 处理

> 调研对象:runc 源码,commit `579be22`(1.5.0-rc.1+dev)。所有行号均以该 commit 为准,用 grep -n / Read 核对。

runc 在两件事上扮演"传话人":一是 seccomp notify——把内核裁不动的 syscall 交给容器外的 supervisor 裁决;二是 console——把容器内的 pty slave 接到进程 stdio,把 pty master 通过 Unix socket 交给外面的调用方。本章把两条"通道"各自的一次握手完整展开。

---

## 1. 全景:两条通道的参与方

### 1.1 seccomp notify 通道

```
        宿主机                                     容器内
 ┌──────────────────────────┐          ┌────────────────────────────────┐
 │ runc create/run          │          │ runc init → execve 用户程序      │
 │  监听 spec.seccomp       │          │   syscall mkdir(2)             │
 │  .listenerPath           │          │     ↓ 命中 SCMP_ACT_NOTIFY 规则 │
 │           ▲              │          │   内核 seccomp cBPF:            │
 │           │ pidfd_getfd  │          │   通知排入 listener fd 队列,     │
 │           │ 从子进程偷出  │          │   进程睡眠等裁决                 │
 │           │ seccomp fd   │          └───────────────┬────────────────┘
 │           │              │                          │ listener fd
 │  runc → net.Dial(        │◄──── SCM_RIGHTS ─────────┘(仅一次,启动时)
 │    listenerPath)         │
 │           │ fd+JSON 状态 │          ┌────────────────────────────────┐
 │           ▼              │          │ 外部 supervisor/agent           │
 │  agent 持有 listener fd  │◄─────────│  NotifReceive 读请求             │
 │                          │          │  /proc/<pid>/mem 读参数          │
 │                          │          │  代理执行 → NotifRespond:        │
 │                          │          │   CONTINUE(放行)/ errno(拒绝)  │
 └──────────────────────────┘          └────────────────────────────────┘
```

要点:**runc 自己从不裁决任何被 notify 的 syscall**。runc 只负责三步:装过滤器(带 `SECCOMP_FILTER_FLAG_NEW_LISTENER`)、把内核吐回的 listener fd 从子进程转交给 agent、然后退出舞台。之后每一次 syscall 的问答都发生在"容器进程 ↔ 内核 ↔ agent"之间,runc(此时可能早已退出)不在路径上。

### 1.2 console/tty 通道

```
 runc run/create(exec 同理,Terminal=true)
   │ specs.Process.Terminal → setupIO → process.ConsoleSocket(AF_UNIX 一对)
   ▼ ExtraFiles + _LIBCONTAINER_CONSOLE=<fd> 传给 "runc init" 子进程
 ┌── 容器内: runc init ──────────────┐   ┌── 容器外: runc 主进程/shim ──────┐
 │ setupConsole:                     │   │ recvtty(前台):                   │
 │  /dev/pts/ptmx 打开新 pty 对        │   │  RecvFile 收 SCM_RIGHTS 的 master │
 │  ioctl(TIOCGPTPEER) 取 slave      │   │  ClearONLCR; epoll 转发 stdio     │
 │  SCM_RIGHTS 发 master ────────────┼──►│  hostConsole.SetRaw()(裸模式)    │
 │  bind mount slave → /dev/console  │   └──────────────────────────────────┘
 │  dup3(slave → 0/1/2)              │
 │  ioctl(0, TIOCSCTTY, 0) 控制终端    │   ← slave 的 termios 无人改,raw 归属在外
 └───────────────────────────────────┘
```

---

## 2. seccomp notify 专节

### 2.1 装过滤器前的三道门:InitSeccomp

`InitSeccomp` 是唯一入口(libcontainer/seccomp/seccomp_linux.go:32),返回值即 notify listener fd(无 notify 时返回 -1,seccomp_linux.go:30-31):

1. **API 级别要求**:任一规则带 `configs.Notify` 就要求 libseccomp API level ≥ 6(libseccomp ≥ 2.5.0 + Linux ≥ 5.7),否则直接报错(seccomp_linux.go:44-48)。
2. **write 不可被 notify**(卷一 06 章那一行就出自这里,seccomp_linux.go:62-64):

```go
// seccomp_linux.go:50-64(节选)
// We can't allow the write syscall to notify to the seccomp agent.
// After InitSeccomp() is called, we need to syncParentSeccomp() to write the seccomp fd plain
// number, so the parent sends it to the seccomp agent. If we use SCMP_ACT_NOTIFY on write, we
// never can write the seccomp fd to the parent and therefore the seccomp agent never receives
// the seccomp fd and runc is hang during initialization.
...
if call.Name == "write" {
    return -1, errors.New("SCMP_ACT_NOTIFY cannot be used for the write syscall")
}
```

   原因:装完过滤器后 init 还要经过 `syncParentSeccomp` 把 fd 编号写给父进程,这条路的载体是 `write(2)`(经 SOCK_SEQPACKET 的 `WritePacket` → `f.Write`,libcontainer/sync_unix.go:41-43)。若 write 被拦到 notify 而 agent 还没拿到 fd,就死锁。注释同时说明 **read/close 可以被 notify**(seccomp_linux.go:56-61):父进程不受过滤器约束,能先把 fd 递给 agent,agent 放行这两条 syscall 即可,init 只是阻塞等待。
3. **默认动作不可为 Notify**(seccomp_linux.go:69-71),理由相同——默认动作兜底意味着 write 也会被 notify。

`configs.Notify` → `libseccomp.ActNotify` 的映射在 getAction(seccomp_linux.go:219-220);配置结构里 `ListenerPath/ListenerMetadata` 定义于 libcontainer/configs/config.go:46-47,由 specconv 从 OCI spec 原样搬运(libcontainer/specconv/spec_linux.go:1246-1247)。

### 2.2 ENOSYS stub:为什么要在 BPF 前面"加料"

libseccomp 生成的过滤器对"内核不认识的 syscall 号"只能落到默认动作(常见 EPERM)。但 glibc/新应用探测新 syscall 的正确语义是 **ENOSYS**("内核不支持")而非 EPERM("被禁止")——返回 EPERM 会让 musl/glibc 误判并放弃降级路径。所以 runc 把 libseccomp 导出的 cBPF 反汇编,前面拼一段自己生成的 stub,再整体装回内核。包注释一句话概括(libcontainer/seccomp/patchbpf/doc.go:1-3)。

stub 的生成与拼装链路:

- `generatePatch`(patchbpf/enosys_linux.go:604-625):默认 errnoRet 已是 ENOSYS 就不补(:607-609);默认动作是 Allow/Log/Trace 这类"放行系"也跳过(:611-614,Trace 算放行的理由在 isAllowAction 注释,enosys_linux.go:108-118)。
- `findLastSyscalls`(enosys_linux.go:247-308):按 AUDIT_ARCH 找出过滤器里出现的**最大 syscall 号**,且强制并入本机架构(:260-265,注释点名 Docker 的 profile 经常漏写 native 架构)。
- `generateEnosysStub`(enosys_linux.go:321-583):生成的 BPF 结构是三层
  - 开头 `load [4]` 取 audit 架构,逐架构 `jeq` 分发(:576-579 与 :546-573);
  - 每个架构段内 `load [0]` 取 syscall 号(:348-351),大于该架构最大号就 `ret ENOSYS`(:330-335,`retErrnoEnosys = SCMP_ACT_ERRNO(ENOSYS)` 定义于 :98,C 常量在 :30);
  - 特例:x32 靠 syscall 号第 30 位区分模式(:419-443、:446-517);s390x 用 0 号 setup(2)做多路复用,必须对它单独 ENOSYS(:103-106、:378-389)。
- `enosysPatchFilter`(enosys_linux.go:627-650):`ExportBPF` 导出 → 反汇编 → `append(patch, program...)` 前插 → 重新汇编。作者自认这是权宜之计(FIXME 注释,enosys_linux.go:310-321,close_range 这类"乱序入库"的 syscall 可能被误伤)。

### 2.3 notify fd 是怎么"长出来"的

补丁后的过滤器带着 flags 装入内核:`filterFlags` 在发现任一规则是 Notify 时打上 `SECCOMP_FILTER_FLAG_NEW_LISTENER`(enosys_linux.go:684-689);`sysSeccompSetFilter` 走 `seccomp(SECCOMP_SET_MODE_FILTER)`,**只有带 NEW_LISTENER 时 fd 才有值**,否则初始化为 -1(enosys_linux.go:694-722,尤其 :702 与 :715-717);flags 为 0 时退化为 prctl(PR_SET_SECCOMP)(:704-707)。`PatchAndLoad` 收尾(enosys_linux.go:729-758)。

### 2.4 子→父:只传编号,父进程 pidfd_getfd 来"偷"

过滤器装在 **runc init 子进程**里,listener fd 自然也在子进程的 fd 表里。子进程侧的 `syncParentSeccomp` 很别致——**不传 SCM_RIGHTS,只把 fd 编号当 JSON 参数写过去**(libcontainer/init_linux.go:443-465):

```go
// init_linux.go:453-464(节选)
// Notably, we do not use writeSyncFile here because a container might have
// an SCMP_ACT_NOTIFY action on sendmsg(2) so we need to use the smallest
// possible number of system calls here because all of those syscalls
// cannot be used with SCMP_ACT_NOTIFY as a result ...
if err := writeSyncArg(pipe, procSeccomp, seccompFd); err != nil {
    return err
}
// Wait for parent to tell us they've grabbed the seccompfd.
return readSync(pipe, procSeccompDone)
```

父进程收到 `procSeccomp` 同步消息后,用 `pidfd_open + pidfd_getfd` 直接从子进程 fd 表里复制一份(libcontainer/process_linux.go:1106-1117):

```go
// process_linux.go:1106-1117
func pidGetFd(pid, srcFd int) (*os.File, error) {
    pidFd, err := unix.PidfdOpen(pid, 0)
    ...
    fd, err := unix.PidfdGetfd(pidFd, srcFd, 0)
    ...
    return os.NewFile(uintptr(fd), "[pidfd_getfd]"), nil
}
```

拿到副本后父进程立即回 `procSeccompDone` 放子进程继续,不必等 agent 收货——注释解释:子进程真撞上 notify 时会在内核里乖乖排队等 listener(process_linux.go:956-959)。init 容器与 exec(setns)进程各有一份同样的处理逻辑:procSeccomp 分支在 initProcess.start(process_linux.go:940-982)与 setnsProcess.start(process_linux.go:532-578);后者若 `ListenerPath` 为空直接报错(process_linux.go:533-535)。整个握手协议的文档写在 libcontainer/sync.go:29-40,常量 `procSeccomp/procSeccompDone` 在 :49-50。

最后一步转交给 agent:`sendContainerProcessState` 向 `ListenerPath` 发起 Unix 连接,把 `specs.ContainerProcessState` JSON 与 listener fd 用 SCM_RIGHTS 一并发出(process_linux.go:1119-1142,:1137 调 `cmsg.SendRawFd`)。fd 名字固定为 `specs.SeccompFdName = "seccompFd"`(vendor/github.com/opencontainers/runtime-spec/specs-go/state.go:38-39)。

安装时机因 noNewPrivileges 而异:`NoNewPrivileges=false` 时 seccomp 必须在丢 capabilities 前装(libcontainer/standard_init_linux.go:191-200;setns 版 setns_init_linux.go:108-116);`true` 时尽量拖到 execve 前一刻,以减少过滤器生效后的 syscall 数(standard_init_linux.go:234-248)。而 `syncParentReady` 必须在 seccomp 之前,因为通知父进程要读写 socket(standard_init_linux.go:177-182 注释)。

### 2.5 消费者:外部 supervisor 的响应协议

runc 仓库自带的参考实现就是集成测试用的 `seccompagent`(tests/cmd/seccompagent/seccompagent.go,注释自述"example implementation of a seccomp-agent",:3-5)。这正是"你写一个 agent"的模板:

- 收 fd:监听 Unix socket,`recvmsg` 解析 SCM_RIGHTS 与 `ContainerProcessState` JSON,按 `SeccompFdName` 挑出 listener fd(handleNewMessage :82-128;parseStateFds :44-80)。
- 读请求:`libseccomp.NotifReceive` 对应内核 `ioctl(SECCOMP_IOCTL_NOTIF_RECV)`(:172)。
- 取参数:字符串参数不能直接解引用——那是**容器进程的地址空间**。agent 用 `pread(/proc/<pid>/mem)` 读出 mkdir 的路径参数(readArgString :130-147),再经 `/proc/<pid>/root|/proc/<pid>/cwd` + SecureJoin 在容器文件系统视图里代为执行 mkdir(:149-166)。
- 回裁决:`libseccomp.NotifRespond`(即 `SECCOMP_IOCTL_NOTIF_SEND`)(:228)。两种典型答案:
  - **放行**:`resp.Flags = libseccomp.NotifRespFlagContinue`(:184-189),即内核的 `SECCOMP_USER_NOTIF_FLAG_CONTINUE`,原 syscall 照常执行;
  - **模拟失败**:如 chmod 系列直接回 `ENOMEDIUM`(:221-225);mkdir 代理失败回 ENOSYS(:215-219)。
- **TOCTOU 双检**:读参数前、代执行前各做一次 `NotifIDValid`(:192、:210)——内核在目标进程被 exec/信号打断时会作废通知 ID,防止 agent 基于过期快照行动。

生产世界里的同类:oci-seccomp-bpf-hook、crun+自研 agent 等,协议完全一致——毕竟"协议"只有两条:启动时收 `ContainerProcessState + seccompFd`,之后 `NOTIF_RECV/NOTIF_SEND` 循环。集成测试从内核 5.6 起跑(tests/integration/seccomp-notify.bats:7-9,注释点名依赖 pidfd_getfd);write 被禁有专门用例断言报错文案(seccomp-notify.bats:195-201);listener 没人监听时 create/run 直接失败(:146-152),因为 `net.Dial` 打不通。

---

## 3. console/tty 专节

### 3.1 Terminal=true 如何变成一条 socket

OCI `process.terminal` 一路传到 libcontainer:`specs.Process.Terminal` → CLI 侧 `setupIO` 把一对 `SOCK_SEQPACKET` socket 的一端塞进 `process.ConsoleSocket`(utils_linux.go:110-119);libcontainer 把它作为 ExtraFiles 加一个传给 `runc init`,环境变量 `_LIBCONTAINER_CONSOLE=<fd编号>`(libcontainer/container_linux.go:592-597);子进程在 init 里按编号还原(libcontainer/init_linux.go:198-206)。是否分配 console 只由这一个字段决定:`CreateConsole: process.ConsoleSocket != nil`(container_linux.go:747;init 侧 JSON 标签 `create_console`,init_linux.go:75)。字段注释直白:`ConsoleSocket provides the masterfd console`(libcontainer/process.go:90-91)。

CLI 侧分支在 setupIO(utils_linux.go:99-159):前台模式自己起 socketpair 并 goroutine 里 `recvtty` 收 master(:110-119);detach 模式改为 `net.Dial` 到调用方(如 shim)预先监听的 `--console-socket` 路径,把客户端连接当 console socket 传给容器(:120-138,注释"the caller of runc will handle receiving the console master")。合法性检查在 checkTerminal:detach+tty 必须给 socket;不 detach 不 tty 却给 socket 也是错(utils_linux.go:342-352)。

### 3.2 容器内的一次性握手:setupConsole

容器 init 侧的 setupConsole(libcontainer/init_linux.go:370-417)在 pivot_root 之后、finalize 之前执行(注释强调顺序,:96-98 与 :370-374):

1. `safeAllocPty()` 分配新 pty 对(init_linux.go:385)。安全起见不走裸 `/dev/ptmx`,而是 O_PATH 打开 `/dev/pts/ptmx` 后验证 inode(必须是 devpts 超级块、inode 号 2、字符设备 5:2),再 reopen 触发内核分配新对(libcontainer/console_linux.go:98-136;checkPtmxHandle :22-43)。
2. slave 端获取优先用 `ioctl(TIOCGPTPEER)`(免路径竞态,Linux ≥ 4.13),老内核回退 `TIOCGPTN` 算出 `/dev/pts/$n` 并做 inode 校验(console_linux.go:51-94;ioctl 封装 internal/linux/linux.go:111-130)。两端都带 `O_NOCTTY|O_CLOEXEC`,防止 runc 自己误得控制终端(internal/linux/linux.go:115-118)。
3. **master 通过 SCM_RIGHTS 发给父进程**:`cmsg.SendRawFd(socket, pty.Name(), pty.Fd())`(init_linux.go:410)。注释说明了为什么用 socket 而不是让子进程直接继承 stdio:保证 console 按容器隔离(点名 runc#814 及一串历史问题,init_linux.go:370-374)。
4. `dupStdio` 把 slave `dup3` 到 0/1/2(console_linux.go:158-166,调用点 init_linux.go:416)。
5. 仅 create 路径(`mount=true`,standard_init_linux.go:100)额外把 slave **bind mount 到 /dev/console**,让读写 /dev/console 的程序(如内核消息)落在容器自己的 pty 上(console_linux.go:138-155,调用点 init_linux.go:404-408)。exec 的 setns 路径传 `false`(setns_init_linux.go:54),不碰 /dev/console。
6. 若 spec 给了 `ConsoleSize`,先 `pty.Resize`(init_linux.go:393-401)。

### 3.3 setsid 与 TIOCSCTTY:控制终端的会话语义

```go
// libcontainer/system/linux.go:66-71
func Setctty() error {
    if err := unix.IoctlSetInt(0, unix.TIOCSCTTY, 0); err != nil {
        return err
    }
    return nil
}
```

调用点紧跟 setupConsole:standard_init_linux.go:99-106 与 setns_init_linux.go:53-60(setns 版错误处理略简)。而 `setsid()` 在更早的 C 阶段——nsexec 最终子进程 stage-2(`runc:[2:INIT]`)里,libcontainer/nsenter/nsexec.c:1195:

```c
// nsexec.c:1194-1196
if (setsid() < 0)
    bail("setsid failed");
```

顺序即语义:先 setsid 让进程脱离父会话、成为新会话的首领(没有控制终端),随后 TIOCSCTTY 才能把这个全新 pty 立为控制终端——前台进程组机制(SIGINT 发给前台组、Ctrl-C 语义、`/dev/tty` 的指向)全部建立在这条链上。若不 setsid,ioctl 可能因"已是别的会话的控制终端"而 EPERM,或容器进程仍在宿主会话里。

### 3.4 raw mode 归属:容器外,且各归各家

容器内 slave 的 termios **runc 从不碰**;容器外驱动终端的模式由"谁在驱动 runc"决定:

- **前台 `runc run`**:recvtty 收到 master 后 `ClearONLCR`(tty.go:111,免得与外层终端换行转换叠加),再对**宿主终端** `hostConsole.SetRaw()` 进入裸模式(tty.go:133-136);宿主终端从 stderr/stdout/stdin 依次探测,都重定向了就开 /dev/tty(tty.go:72-100)。Ctrl-C 中断时恢复原状(tty.go:145-151);SIGWINCH 时 `console.ResizeFrom` 把宿主窗口尺寸同步给容器 pty(tty.go:189-194;信号循环 signals.go:61-69)。
- **docker/containerd**:shim 用 `--console-socket`(create.go:37-39)收 master,IO 转发与 raw 模式由 dockerd/containerd/CLI 这条链负责——runc 只负责把 master pty 交出去。`docker -t` 的本质即:`Process.Terminal=true` 进 OCI spec → shim 传 `--console-socket` 给 runc → shim 拿到 master 后桥接到 docker 的 attach 流;CLI 端把自己的本地终端置 raw。
- CRIU 恢复路径同样走 console socket 交还 master(libcontainer/criu_linux.go:1196),本章不展开。

---

## 4. exec 与 tty 专节

`runc exec` 走 setns 进程,console 逻辑与 init 完全同构,但有三点差异:

1. **tty 默认关**:exec 的 `--tty` 是独立 flag,`p.Terminal = cmd.Bool("tty")`,不继承 config.json(exec.go:266-267);`--console-socket` 同样提供(exec.go:40-41)。
2. **全新 pty,与主 init 无共享**:每个 exec 进程在 `setupConsole` 里重新 `safeAllocPty()`(init_linux.go:385),拿到的是容器 devpts 里**另一对**新 pty——与 init 的 console 互不相干。它们唯一的共享是同一个 /dev/pts 挂载实例(同一 mntns),所以 `docker exec -t` 后 `who`/`w` 能看到各自独立的 tty 设备名(如 pts/0 与 pts/1)。
3. **控制终端照立,但不 mount**:setns 路径同样 `Setctty()`(setns_init_linux.go:57)给 exec 出来的进程立控制终端,只是跳过 /dev/console bind mount(:54 传 mount=false)。exec 也各有一条自己的 seccomp notify 握手(process_linux.go:532-578),意味着 agent 会为每个 exec 进程再收到一个 listener fd,各自独立排队。

不申请 tty 的 exec 则退回管道方案:前台非 detach 用 `InitializeIO` 三根管道(utils_linux.go:148-158;libcontainer/process_linux.go:1171-1208,注释自嘲"TODO: should be handled by clients"),detach 直接继承 runc 的 stdio(utils_linux.go:143-145)。

---

## 5. 设计动机

- **为什么裁决放在外部进程**:机制(policy-free)与策略(policy)分离。runc 作为通用 runtime 不该理解 mkdir/chmod 的语义;内核的 seccomp notify 把"拦截"做成 fd,任何普通进程都能凭这个 fd 参与裁决,runc 只需完成 fd 的搬运(process_linux.go:940-982)。这也天然把 agent 放在**不受容器 seccomp 约束的信任域**(seccomp_linux.go:56-61 注释即依赖这一点),agent 才能自由调用被容器禁掉的 syscall 去模拟。
- **为什么子进程只报 fd 编号、父进程 pidfd_getfd**:init 已经身处过滤器之下,后续每个 syscall 都可能被 notify;能少用一个是一个。写编号只需 `write`(因此禁止 notify write),而 SCM_RIGHTS 需要 `sendmsg`(sendmsg 本身可能就是被 notify 的对象,init_linux.go:453-459)。pidfd_getfd(内核 ≥ 5.6)则让父进程在不受过滤器影响的一侧取 fd,且以 pidfd 规避 PID 复用竞态。
- **为什么 listener fd 通过 Unix socket 发 ContainerProcessState**:一次交付、无状态。runc 退出后 agent 与容器之间再无 runc 参与;JSON 里附带 pid/annotations/metadata(process_linux.go:972-978),让 agent 能把 fd 关联回容器。
- **为什么 console 用 socket 传递而非 fd 继承**:init 是 fork/exec 出来的子进程,stdio 继承意味着 master 与宿主终端纠缠、无法按容器精确配对,这正是 runc#814 系列问题的根源(init_linux.go:370-374 注释)。socket 让"容器内的 slave"与"容器外的 master"在两个进程里同时诞生又即时分离;detach 时甚至可以把交付对象换成第三方 socket(utils_linux.go:120-138),shim 架构因此成立。
- **TIOCSCTTY 的会话语义**:控制终端是会话属性而非进程属性。setsid(nsexec.c:1195)→ TIOCSCTTY(system/linux.go:66-71)两步走,保证容器 init 是自己会话的首领、前台进程组机制完整,`docker stop` 的 SIGKILL 兜底、shell 作业控制、/dev/tty 才都落在容器内部。
- **ENOSYS stub 为什么手写 BPF**:libseccomp 不暴露"每个架构最大 syscall 号"的语义,runc 只能导出→反汇编→前插→回装(enosys_linux.go:627-650);stub 以程序方式保证"未知号返回 ENOSYS 而非默认动作",同时不影响显式规则。

---

## 6. FAQ 素材

1. **卷一说 write 不可被 notify,为什么?** 装完过滤器后 init 还要用 write 通知父进程拿 fd(seccomp_linux.go:50-64),write 若被拦即死锁,故直接报错(seccomp_linux.go:62-64);默认动作也不可为 Notify(:69-71)。集成测试断言了这条报错(seccomp-notify.bats:195-201)。
2. **read/close 也被 syncParentSeccomp 用到,为什么它们可以被 notify?** 父进程不受过滤器约束,会先把 listener fd 交给 agent;agent 只要放行 read/close,init 就能走完初始化(seccomp_linux.go:56-61)。
3. **runc 会裁决被 notify 的 syscall 吗?** 不会。runc 只装过滤器、搬 fd;裁决循环 NotifReceive/NotifRespond 在外部 agent(tests/cmd/seccompagent/seccompagent.go:169-233 是参考实现)。
4. **agent 如何"放行"syscall?** 响应带 `SECCOMP_USER_NOTIF_FLAG_CONTINUE`(seccompagent.go:184-189),内核继续执行原调用;也可直接回错误码/返回值模拟失败(:215-225)。
5. **为什么需要 pidfd_getfd?什么内核版本?** 子进程在过滤器内只能报 fd 编号,父进程越过过滤器取 fd;内核 ≥ 5.6(seccomp-notify.bats:7-9),实现 process_linux.go:1106-1117。
6. **listenerPath 上没人监听会怎样?** create/run 阶段 `net.Dial` 失败、容器启动失败(process_linux.go:1119-1123;seccomp-notify.bats:146-152);没有 notify 规则时 listenerPath 会被忽略(:123-134 的 ignore 用例)。
7. **ENOSYS stub 与 notify 冲突吗?** 不冲突。stub 只在默认动作非放行系时生成(enosys_linux.go:611-614),是对"未知号"的兜底;显式 SCMP_ACT_NOTIFY 规则照常生效。
8. **noNewPrivileges 对 notify 有什么影响?** 只影响安装时机:NNP=false 在丢 cap 前装(standard_init_linux.go:191-200),NNP=true 拖到 execve 前(:239-248);两条路径都要 syncParentSeccomp。
9. **agent 读到的指针参数能直接解引用吗?** 不能,那是容器进程的虚拟地址;须 `pread(/proc/<pid>/mem)`(seccompagent.go:130-147),文件操作还要走 /proc/<pid>/root|cwd 并做 TOCTOU ID 复核(:149-166、:192、:210)。
10. **容器内 slave 的 raw 模式是谁设的?** 没人设——runc 不改容器内 termios;前台 runc run 对**宿主**终端 SetRaw(tty.go:133-136),docker 场景由 CLI/shim 链路负责。

## 7. 深挖入口

1. **手写 ENOSYS stub 的 BPF 细节**:长短跳转(>255)两套编码(enosys_linux.go:394-415)、x32 第 30 位特判(:419-443)、s390x setup(2) 复用(:378-389);debug 日志可打印整段 patch(:639-643)。
2. **写一个生产级 agent 的 checklist**:TOCTOU 双检、/proc/pid/mem 读参数、securejoin 防逃逸、metadata 清洗(seccompagent.go:287-291)、多 fd 并发(notifHandler 每 fd 一个 goroutine,:294)。
3. **SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV**:让阻塞在 NOTIF_RECV 的被 notify 进程可被 SIGKILL,flag 透传链路 seccomp_linux.go:162-166 → enosys_linux.go:675-681。
4. **pidfd 家族的第三个用途**:除 pidfd_getfd 外,runc 还支持 `--pidfd-socket` 对外暴露 init 的 pidfd(utils_linux.go:434-459),与 notify fd 交付同一个 SCM_RIGHTS 模式。
5. **TIOCGPTPEER 的安全演进**:从"猜 /dev/pts/$n 路径 + inode 校验"到内核直接给 fd(console_linux.go:51-94),可对照 libcontainer 对 ptmx inode 的偏执校验(console_linux.go:22-43)体会容器边界的攻防史。

---

## 8. 写作要点速查表

| 主题 | 文件:行号 | 内容 |
|---|---|---|
| write 禁止 notify | libcontainer/seccomp/seccomp_linux.go:62-64 | 死锁论证在 :50-61;默认动作禁止 :69-71 |
| API level ≥ 6 | libcontainer/seccomp/seccomp_linux.go:44-48 | libseccomp≥2.5.0 + Linux≥5.7 |
| Notify 动作映射 | libcontainer/seccomp/seccomp_linux.go:219-220 | configs.Notify→ActNotify |
| ENOSYS stub 生成 | libcontainer/seccomp/patchbpf/enosys_linux.go:321-583 | 跳过条件 :604-625;ret ENOSYS :98/:334 |
| NEW_LISTENER flag | libcontainer/seccomp/patchbpf/enosys_linux.go:684-689 | seccomp(2) 返回 fd :702,:715-717 |
| 子进程报 fd 编号 | libcontainer/init_linux.go:443-465 | 不用 SCM_RIGHTS 的原因 :453-459 |
| pidfd_getfd 取 fd | libcontainer/process_linux.go:1106-1117 | init/exec 两分支 :940-982 / :532-578 |
| fd 交付 agent | libcontainer/process_linux.go:1119-1142 | Dial listenerPath + SCM_RIGHTS |
| agent 参考实现 | tests/cmd/seccompagent/seccompagent.go:169-233 | CONTINUE :184-189;TOCTOU :192/:210 |
| 同步协议常量 | libcontainer/sync.go:29-50 | procSeccomp/procSeccompDone |
| console socket 传入 | libcontainer/container_linux.go:592-597 | env `_LIBCONTAINER_CONSOLE` |
| 容器内 pty 握手 | libcontainer/init_linux.go:370-417 | 发 master :410;dupStdio :416 |
| pty 安全分配 | libcontainer/console_linux.go:98-136 | TIOCGPTPEER :51-94;mount /dev/console :138-155 |
| setsid/TIOCSCTTY | libcontainer/nsenter/nsexec.c:1195;libcontainer/system/linux.go:66-71 | 调用点 standard_init_linux.go:99-106,setns :53-60 |
| 前台 tty 收取/raw | tty.go:102-143 | SetRaw :134;ClearONLCR :111;resize :189-194 |
| CLI 侧 setupIO | utils_linux.go:99-159 | detach+dial :120-138;checkTerminal :342-352 |
| exec --tty | exec.go:57,:266-267 | setns 侧 :setns_init_linux.go:53-60 |
