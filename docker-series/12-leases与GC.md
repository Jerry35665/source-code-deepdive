# 第 12 章 · leases 与 GC:资源生命周期管理(卷末)

> 基线:commit `f6132db`。行号以 core/leases/、plugins/gc/、pkg/gc/、core/metadata/gc.go、core/metadata/db.go 为准。卷一 A 报告讲了 GC 主流程——本章把"资源生命周期"讲透:租约+调度器+标签协议。

## 12.0 全景:资源生命周期的状态

```
创建(引用/租约保护)→ 使用(引用链 gc.ref.* 维护)→ 无引用 → GC 清扫(元数据→物理两阶段)
lease = bolt 里一个带标签的桶(leases/<id>):ID/CreatedAt/Labels
     = "有期限的命名存活凭证",不是引用计数
```

## 12.1 lease 机制:过期即无根

租约过期即打 `containerd.io/gc.expire` 标签(RFC3339)——**无定时器**,过期租约在下轮 GC scanRoots 中不再算 root(core/metadata/gc.go:570-581 整棵租约子树可收)。context 带租约时,content/snapshot/ingest/image 的正常写入**自动挂资源到租约**(addContentLease);客户端 WithLease 默认随机 ID+**24h 过期**(client/lease.go:37-43;pull 入口 :86);pull/Import/Checkpoint/Unpack/Transfer 全套使用;跨进程走 gRPC header `containerd-lease`。**进程崩溃后租约兜底 24h**,到期被 GC 收。删除租约可传 SynchronousDelete→ScheduleAndWait 阻塞等一轮 GC(含物理清理)。

## 12.2 GC 调度器:三种触发与自适应间隔

调度器是独立插件、后台单 goroutine。触发三类:**手动**(ScheduleAndWait)、**阈值**(deletion/mutation 回调计数,默认 mutation 100 次/删除阈值 0)、**定时**(startup 100ms 首轮+自适应 interval 空转跳过)。核心算法:.interval = avg/pauseThreshold − avg(avg=均耗锁时间,下限 5ms,plugins/gc/scheduler.go:335-347,:237)——**使 GC 停顿恰占 p(默认 2%,clamp ≤0.5)**;失败按上次间隔+1s 退避;指标 containerd_gc_collections。GC 全程持有 wlock 排他写锁(db.go:89-93 注释:mark/sweep 之间世界不变)+bolt 只读事务一致快照+单线程 DFS Tricolor(:64-100)——**无需 write barrier 的秘诀:排他窗口**。

## 12.3 标签协议与清扫两阶段

四类标签组合(gc.go:66-119):gc.root(**逃生舱保活**)、gc.ref.*(父→子正向边)、gc.bref.*(子→父反向边,**允许子自证挂靠**)、gc.expire/flat/cond(时间/遍历深度/条件修饰)。**新资源类型经 RegisterCollectibleResource+Collector 接口接入,不改 GC 代码**。清扫两阶段:①写事务删 bolt 桶②wlock 下异步物理回收(snapshotter 树剪枝+Cleanup 磁盘对账;content Walk 对账删 blob+Abort ingest,:845-961)。**无显式删除队列**:重试语义由"磁盘对账"隐式实现——不在对账集合的孤儿下轮再删(overlay.go:381-383 失败仅 Warn)。

## 12.4 设计动机

1. **为什么用租约而非引用计数**:分布式场景引用者可能崩溃,计数泄漏;租约的"期限+续约"是天然容错的存活声明——**心跳式存活优于指针式存活**;
2. **为什么 GC 异步物理删除**:元数据(快、事务)与物理(慢、无事务)分离;失败重试靠对账而非队列;
3. **标签协议的可扩展性**:四种标签的组合表达任意引用图,Collector 接口让新资源零改 GC——**协议先行,代码退后**;
4. **排他窗口的正确性**:GC 期间拒写(而非复杂并发标记)——容量换正确性,与 bolt 的事务模型严丝合缝。

## 12.5 FAQ

**Q1:lease 和 GC.ref 什么区别?**
lease=时间维的存活凭证(谁都没引用也活 24h);gc.ref=图维的引用边——两种正交的保活机制。

**Q2:过期租约的资源马上被删吗?**
不是"马上":下轮 GC scanRoots 不再把它当 root,引用图清空后清扫(:570-581)。

**Q3:GC 期间容器还能写吗?**
不能:GC 全程持 wlock 排他写(db.go:89-93)——停顿=调度器预算(默认 2%)。

**Q4:物理删除失败怎么办?**
无重试队列:对账机制下轮再删(overlay.go:381-383)——最终一致。

**Q5:pull 中途挂了,blob 会永久泄漏吗?**
不会:24h 租约到期,GC 收(:37-43)。

**Q6:新资源类型怎么接 GC?**
RegisterCollectibleResource+Collector:不改 GC 代码——扩展即注册。

**Q7:调度器的 2% 怎么调?**
pauseThreshold GUC 类配置(:335-347):停顿占比=业务可接受度。

**Q8:gc.bref 的用途?**
子→父反向边:子对象自证"我被父需要"(:66-119)——处理"父不存在于扫描起点"的场景。

**Q9:跨进程怎么带租约?**
gRPC header containerd-lease:租约是进程间协议。

**Q10:content 对账删什么?**
bolt 在册集合 vs 磁盘 Walk 的差集(:845-961):孤儿 blob 与 Abort 的 ingest。

## 12.6 小结与卷末语

本章结论:**资源生命周期="租约(时间维)+标签引用图(图维)+三色标记(算法)+对账(兜底)"**;四种机制各管一段,组合出分布式存储的完整 GC。

至此《Docker 深读》卷二完(G-L 6 章:07 CRI/08 streaming/09 CRIU/10 delete/11 rootless/12 leases;基线 f6132db/579be22)。两卷合计 13 篇正文+12 份报告,容器栈从"docker pull 一条命令"到"进程树复活"的全链闭合。全系列横向对照的新证据(lease 的时间维保活=模式 5、cfilter 洋葱=模式 6、cpool/labels=模式 1)可在下版特刊更新。深挖方向:

1. lease 24h 默认对长下载(模型镜像)的续约策略;
2. GC 排他窗口在高 churn(千容器频繁启停)的停顿实测;
3. Collector 接口的自定义资源实践;
4. transfer streaming 与 lease 的结合(断点+保活);
5. CRI 的 image GC(07 章)与 containerd GC 的协同正确性。

— 《Docker 深读》卷二完。AI 编码助手:GLM-5.3-Flash。
