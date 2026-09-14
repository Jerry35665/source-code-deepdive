# 第 09 章 · CRIU 检查点与恢复:容器的冻结与复活

> 基线:commit `579be22`。行号以 libcontainer/criu_linux.go 为准。容器生命周期的"暂停/复活":checkpoint 把进程树转成镜像文件,restore 在(可能另一台)机器上按原 PID 复活。

## 9.0 全景:字节流两端

```
checkpoint:进程树 → CRIU 冻结(runc 只递 freezer 路径 :385-392,不可用退 ptrace)
           → 内存/fd/进程树 → CRIU 镜像目录 + descriptors.json(:488-497)
restore:镜像目录 → 重建挂点/命名空间 → 按原 PID 复活进程树 → Running
```

`runc checkpoint`(checkpoint.go:50-83)→Container.Checkpoint(criu_linux.go:294-506)把 CriuOpts(criu_opts_linux.go:13-39)翻成 CRIU protobuf,经 socketpair 发给 **`criu swrk 3` 子进程**(criuSwrk,criu_linux.go:900-1078)——**CRIU 是外部进程而非库**,rpc 走 socketpair+NOTIFY 应答循环(:924 启动,:1032-1048 ack)。

## 9.1 checkpoint:dump 后即 stopped

dump 后容器即 stopped(CLI 调 Destroy,checkpoint.go:75-81;**OCI 无 "checkpointed" 状态**)。runc 额外写 descriptors.json(:488-497)记录 fd 语义;声明外部 net/pid ns 为 `extRoot<Type>NS` 引用(:203-223)、bind mount 为 ExtMountMap 引用——**容器外的状态用引用,容器内的状态进镜像**。pre-dump:`--pre-dump` 走 PRE_DUMP+MemTrack 检查(:402-421),只转储内存、容器继续跑;后续轮用 `--parent-path`(强制相对路径,checkpoint.go:96-115)+TrackMem 只写脏页——**live migration 的核心:迭代到停机窗口≈最后轮脏页+网络切换**。

## 9.2 restore:不走 nsexec 的复活

`runc restore` 复用创建骨架但分流到 Container.Restore(:633-814):rootfs bind 到 criu-root 满足挂点约束(:665-684)、重建挂点(tmpfs 跳过 :593-597)、**ns 重进三路**:net/pid 外部 ns 走 InheritFd(fd 从 4 起 :263-292)、其余走 JoinNs(:225-261)、cgroup 应用到 criu 进程(:866-898)。**restore 完全不走 nsexec/runc init**(04 章):进程本就"存在",CRIU 在重建的 pid ns 里按原 PID 复活进程树;runc 只在 post-restore notify(:1145-1176)把 cmd.Process 换成 restored init 并认领为 restoredState(:919-952)→状态即 Running(:196-222)。

## 9.3 能力边界(如实)

外部 TCP 需 --tcp-established(repair,对端无感知但路由需上层切换);跨容器 unix socket 需 --ext-unix-sk 且对端不在镜像则难重接;netns 默认 EmptyNs 不入镜像;timens 需 CRIU≥3.14 掩盖时钟跳变;bind mount 只引用不拷贝(目标机须同源路径);**rootless 明确 untested**;file locks/终端作业需显式选项。Created/Stopped 状态拒绝 checkpoint(:67-81)。`runc_nocriu` 构建下 C/R 直接返回 ErrNoCR(criu_disabled_linux.go:7-15)。

## 9.4 containerd 对接

shim 的 Init.checkpoint 经 go-runc 拉起 `runc checkpoint` CLI(containerd f6132db init.go:437-470),失败拷 dump.log 回 bundle;"**从检查点创建**"伪装成 task Start→`runc restore`(init.go:192-209;init_state.go:147)——containerd 的 task 模型把 restore 抽象成另一种 Start。

## 9.5 设计动机

1. **为什么用外部 CRIU 进程**:CRIU 需要_ptrace 全树+读写 /proc+自身不被快照——进程边界是最干净的隔离;rpc 走 socketpair 让 CRIU 的进度/询问(notify)可编程;
2. **pre-dump 是迁移的关键**:迭代 dump 让"停机窗口"收敛到最后轮脏页——与数据库的增量备份同构;
3. **restore 不走 init 路径**:nsexec 解决"从零进入 ns",restore 解决"进程已在 ns 里复活"——两个问题,两条路径;
4. **容器快照 vs 虚拟机快照**:容器快照的是"进程树+内存",外部依赖(TCP 对端/bind 源)全是引用——**引用密集型的快照天然受限**(9.3 的边界全源于此)。

## 9.6 FAQ

**Q1:checkpoint 后容器还能跑吗?**
不能:dump 即 Destroy(:75-81),OCI 没有 checkpointed 状态;LeaveRunning 选项除外。

**Q2:restore 为什么不走 nsexec?**
(:633-814):进程按原 PID 被 CRIU 复活,不需要"从零进入 ns"——两条路径两个问题。

**Q3:TCP 连接能快照吗?**
--tcp-established 可(repair 模式):对端无感知,但路由切换要上层(:343)。

**Q4:跨机器迁移的完整链路?**
迭代 pre-dump(容器跑)→最终 dump(停机)→镜像传目标机→restore+网络切换。

**Q5:pre-dump 多少轮合适?**
(:402-421):脏页率收敛即停——每轮窗口递减,收益递减。

**Q6:rootless 容器能 C/R 吗?**
明确 untested——userns 的映射恢复是深水区。

**Q7:containerd 怎么发起 checkpoint?**
shim 转发 `runc checkpoint`(:437-470):runc 仍是执行者。

**Q8:"从检查点创建"是什么 API?**
task Start 伪装 restore(:192-209):上层无需知道 CRIU。

**Q9:哪些状态不可快照?**
外部 unix socket 对端/时间强依赖/file locks——引用与时间的边界(:9.3)。

**Q10:dump 的产物多大?**
进程树内存+fd 元数据:与 RSS 同量级;pre-dump 链只存增量。

## 9.7 小结与深挖方向

本章结论:**CRIU="外部进程冻结进程树+引用式外部状态+pre-dump 收敛停机窗口"**。深挖:

1. LazyPages(:351)按缺页从镜像补的按需路径;
2. memory.events 与 CRIU 冻结的交互(冻结期间 OOM);
3. restore 的 cgroup 应用(:866-898)在 v2 delegation 下的约束;
4. live migration 的网络切换方案(CNI 层面);
5. criuSwrk 的长连接复用(:900-1078)与多容器并发。

> 下一章:delete 与清理——容器死亡的四条路径。
