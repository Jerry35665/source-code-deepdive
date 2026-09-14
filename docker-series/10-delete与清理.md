# 第 10 章 · delete 与清理:容器死亡的四条路径

> 基线:commit `579be22`。行号以 libcontainer/state_linux.go、container_linux.go、根目录 delete.go/kill.go 为准。**勘误**:本 commit 的 main 包已从 cmd/runc/ 移到仓库根(delete.go/kill.go 在根目录);cgroup 管理器在 vendor/github.com/opencontainers/cgroups/。

## 10.0 全景:四种死亡,一个终点

```
(A) init 自然退出 → 内核僵尸 → refreshState 判 stopped(:919-936)→ 等 delete
(B) runc kill     → 只发 init;私有 PID ns 内核连带杀全员(:444-471)
(C) delete --force → SIGKILL+100×100ms 探活(delete.go:17-26)+Destroy
(D) OOM/宿主重启   → 同 A;/run tmpfs 让状态目录随重启蒸发
清理终点:destroy()(state_linux.go:39-67)只有一条路,差异只在触发者
```

## 10.1 delete:固定顺序的 destroy

destroy 的顺序(state_linux.go:39-67):①共享 PID ns 杀残留→②cgroup Destroy(:52)→③intelRdt(:55)→④RemoveAll(stateDir)(:60)→⑤poststop hooks(:64)。**cgroup 删失败则提前返回,state 目录保留可重试**——清理的中间态必须可重入。`--force` 是两步:SIGKILL+探活循环(:17-26,SIGKILL 后最多等 10 秒,不强删)+Destroy;**对 stopped 容器也杀**(:72-79):共享 PID ns 下 cgroup 可能有残留进程。状态机分派:createdState.destroy 先 SIGKILL init(:160-163);pausedState 拒绝并要求 thaw(:186-194)。

## 10.2 kill:信号路由的三岔口

`runc kill` 的路由(container_linux.go:444-471):**仅"SIGKILL+私有 PID ns"杀全员**(内核 pid_namespaces(7) 的连带语义),其余信号只发 init;signalInit 防 PID 复用+冻结时 thaw(:474-488)。`cgroup.kill=1` 快路径(内核 5.14+,init_linux.go:688-717):回退链 freeze→逐杀→thaw。exec.fifo 三处删除:`runc start` 消费后即删(container_linux.go:262)、create 失败删(:382-386)、destroy 随 stateDir 整体删;fifo 存在性=Created 判据(:932)。

## 10.3 cgroup 清理与僵尸容器

v2 目录非空:RemovePath 递归删子组+EBUSY 指数退避 10 次(vendor cgroups/utils.go:254-288,:229-249);systemd 驱动先 stopUnit(30s 超时+resetFailedUnit,common.go:184-210)再补删子组(**systemd 239 bug**:v2.go:435-437)。**僵尸容器**:init 死了但 delete 没跑——收尸责任在 shim/containerd(卷一 03 章 reaper);全仓库无 flock,并发靠 mutex+state.json 原子 rename(:882-906)+运行时复核。前台 `runc run` 自清理(非 detach/出错时 defer destroy,utils_linux.go:223-231;`--keep` 关闭 :418);detach 场景清理责任移交 shim。

## 10.4 设计动机

1. **为什么 delete 是显式命令而非自动**:OCI 状态机的 Stopped 仍可被检视(退出码/日志)——**"死了"≠"可以消失"**, autopsy 窗口是产品语义;
2. **--force 的两步设计**:SIGKILL 与删除分离——kill 的传播是异步的(僵尸回收/共享 ns 连带),探活循环承认这种异步;
3. **清理可重入**:cgroup 删失败保留 state 目录(:52)——destroy 的每一步幂等,重跑无害;
4. **destroy 单点收敛**:四种死亡一个终点函数——清理逻辑写一次,触发器随意组合(与 09 章 checkpoint 的 Destroy 复用同款)。

## 10.5 FAQ

**Q1:容器退出后 cgroup 立即删除吗?**
不:等 `runc delete`(:39-67)——退出码/元数据的检视窗口。

**Q2:kill 默认杀所有进程吗?**
只发 init;SIGKILL+私有 PID ns 才连带(:444-471)——共享 PID ns 需显式全杀。

**Q3:delete --force 卡 10 秒怎么办?**
(:17-26)探活上限即 10 秒:D 状态(不可中断 IO)进程会拖满。

**Q4:v2 cgroup 删不掉(EBUSY)怎么办?**
指数退避 10 次(:254-288);子组残留递归删。

**Q5:僵尸容器谁收尸?**
runc 不自动:shim/containerd 兜底(卷一 C 的 reaper)——分层各自收各自的。

**Q6:paused 容器能直接 delete 吗?**
不能,要先 thaw(:186-194):状态机的显式转换。

**Q7:poststop hook 失败会怎样?**
destroy 继续完成((:64) 在最后):poststop 是尽力而为。

**Q8:并发 delete/kill 安全吗?**
mutex+state.json 原子 rename+运行时复核(:882-906):无 flock 的软并发控制。

**Q9:宿主重启后容器状态?**
/run tmpfs 蒸发:一切归零(与 04 章"状态属运行时"一致)。

**Q10:cgroup.kill=1 是什么?**
内核 5.14+ 的一键杀全组(:688-717):免 freeze/逐杀/thaw 三步。

## 10.6 小结与深挖方向

本章结论:**清理="四种死亡一个 destroy 终点+可重入步骤+显式检视窗口"**。深挖:

1. delete --force 探活(:17-26)对 D 状态进程的等待策略;
2. v2 EBUSY 退避(:254-288)在内核版本间的行为差;
3. cgroup.kill=1(:688)与 systemd 驱动(stopUnit)的一致性;
4. 共享 PID ns 的 signalAllProcesses(:444-471)误伤面;
5. exec.fifo 三处删除(:262/:382/:destroy)的时序图。

> 下一章:rootless——无特权容器的全链。
