# 第 14 章 · seccomp notify 与 console:syscall 裁决与终端控制权

> 基线:commit `579be22`。行号以 libcontainer/、libcontainer/nsenter/nsexec.c、tty.go 为准。

## 14.0 全景:两个"控制权外移"的设计

```
seccomp notify:容器内 syscall → 内核 seccomp → notify fd → 容器外 supervisor 裁决
console:      容器内 pty slave ←→ SCM_RIGHTS 送出的 master → 宿主终端
```

两者共同点:**裁决权/呈现权在容器外**,容器内只留最小机制。

## 14.1 seccomp notify:三次握手

1. **装过滤器**:InitSeccomp 在 runc init 子进程内安装带 SCMP_ACT_NOTIFY 规则的 cBPF,触发即返回 listener fd(seccomp(2) 的 SECCOMP_FILTER_FLAG_NEW_LISTENER);前置:libseccomp API level≥6(:44-48);**write 不可被 notify**(死锁论证 :50-61:装完过滤器后通知父进程要靠 write);默认动作不可为 Notify(:69-71)。
2. **子→父**:syncParentSeccomp 只把 **fd 编号当 JSON 参数**写过 SOCK_SEQPACKET 同步 socket(:443-465)——**不用 SCM_RIGHTS,因为 sendmsg 本身可能被 notify**;父进程 pidfd_getfd(:1106-1117,内核≥5.6)越过过滤器直接从子进程 fd 表复制 listener fd,立即回 procSeccompDone 放行。
3. **父→agent**:Dial(spec.listenerPath) 发 ContainerProcessState JSON+SCM_RIGHTS 的 seccompFd(:1119-1142),之后 **runc 退场**;agent 循环 NOTIF_RECV 读请求(/proc/pid/mem 读指针参数、NotifIDValid 双检 TOCTOU)、代理执行后 NOTIF_SEND 回答:SECCOMP_USER_NOTIF_FLAG_CONTINUE 放行或直接回 errno——**runc 不裁决任何 syscall**。agent 参考实现在 tests/cmd/seccompagent(:169-233)。

**ENOSYS stub**(patchbpf/enosys_linux.go:321-583):对老内核不认识的新 syscall,过滤器补 ENOSYS 返回(而非默认动作杀进程)——逐架构最大 syscall 号比较(:334),让应用可优雅降级。

## 14.2 console:pty 的传递握手

`Terminal=true` → CLI 起一对 AF_UNIX,一端作 ConsoleSocket 经 ExtraFiles+`_LIBCONTAINER_CONSOLE` 传给 runc init → 容器内 setupConsole(:370-417):safeAllocPty(校验 /dev/pts/ptmx inode 后分配新 pty 对)→**TIOCGPTPEER 取 slave**→SCM_RIGHTS 发 master 给容器外(recvtty 收取后 ClearONLCR(:111)+epoll 转发;前台 runc run 时**对宿主终端 SetRaw**(:134)——raw 模式设在容器外宿主终端,runc 从不碰容器内 termios)→slave dup3 到 0/1/2→仅 create 路径把 slave bind mount 到 /dev/console(:404-408)→`ioctl(0,TIOCSCTTY,0)` 立控制终端(:1195;其前提 setsid() 在更早的 nsexec.c C 阶段 :66-71)。exec --tty 走同一套但 mount=false,拿的是**全新 pty**,与 init console 仅共享 /dev/pts 实例。

## 14.3 设计动机

1. **为什么 notify 的裁决在外部进程**:策略与机制分离——过滤器(机制)在容器内安装,每个 syscall 的放行决策(策略)由容器外不受限的 supervisor 做出;runc 自身"不裁决任何 syscall";
2. **为什么 fd 编号走 JSON 而非 SCM_RIGHTS**:sendmsg 可被 notify 拦截(:453-459 注释)——用最原始的同步 socket 传编号,pidfd_getfd 取 fd;
3. **为什么 console 用 socket 传递**:容器内进程在 setns 后才分配 pty,宿主侧需要"随时来取"的握手——Unix socket+SCM_RIGHTS 是 fd 的标准渡船;
4. **TIOCSCTTY 的会话语义**:控制终端决定 Ctrl+C 投递——setsid(脱离继承)+TIOCSCTTY(认领)是两步,缺一不可。

## 14.4 FAQ

**Q1:seccomp notify 能拦 write 吗?**
不能:通知父进程要靠 write,拦了就死锁(:50-61)——规范强制排除。

**Q2:老内核遇到新 syscall 会怎样?**
ENOSYS stub 返回 ENOSYS(:334):应用走 fallback 而非被 SIGSYS 杀死。

**Q3:notify fd 怎么从子进程到父进程?**
fd 编号走同步 socket(:443-465)+父进程 pidfd_getfd 复制(:1106-1117)——绕过过滤器自身的拦截。

**Q4:容器内 termios 谁设置?**
runc 从不碰:raw 模式由容器外的 recvtty/tty 客户端设置(:134)——终端状态归呈现方。

**Q5:exec --tty 的 pty 和 init 的一样吗?**
不同:全新 pty(:266-267),只共享 /dev/pts 实例——exec 的终端独立会话。

**Q6:/dev/console 为什么要 bind mount slave?**
(:404-408):让容器内打开 /dev/console 的老代码也能落到当前 pty。

**Q7:supervisor 挂了会怎样?**
notify 请求无人应答:容器内 syscall 永久阻塞——agent 的可用性=容器内被拦调用的可用性。

**Q8:TIOCSCTTY 的参数是什么?**
0(强制抢占):标准_init_linux.go:99-106——在 setsid 之后调用才合法。

**Q9:pidfd_getfd 需要什么权限?**
内核≥5.6+同用户或 CAP_SYS_PTRACE(:1106-1117):父子是真实进程关系之外的通用机制。

**Q10:TOCTOU 双检是什么?**
agent 处理前 NotifIDValid 确认目标进程还活着(:192/:210):防 PID 复用后的误操作。

## 14.5 小结与深挖方向

本章结论:**notify="过滤器内装+fd 外渡+裁决外置";console="pty 生成+SCM 渡船+宿主持 raw"**——两个"控制权外移"设计。深挖:

1. ENOSYS stub(:321-583)的逐架构最大 syscall 号维护成本;
2. SCMP_ACT_CONTINUE 对 seccomp notify + 用户态 TLS 代理的性能;
3. recvtty 的 epoll 转发在窗口缩放下的吞吐;
4. TIOCSCTTY 与 PR_SET_CHILD_SUBREAPER 的会话树;
5. seccomp agent 的多容器复用架构。

> 下一章:CDI 设备注入——声明式设备的现代标准。
