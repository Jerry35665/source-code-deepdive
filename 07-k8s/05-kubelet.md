# 第 05 章 · kubelet:节点上的期望状态调和器

> 基线:commit `517a94ff`。行号均以该版本源码为准。
> 定位:kubelet 是"控制器的控制器"——不编排(调度归 scheduler,期望归 apiserver),只做一件事:**把本节点的实际容器状态,持续调和成 apiserver 记录的期望状态**(kubelet.go:2007-2018 注释原话)。

## 5.0 组件分工

- **podManager**:期望状态的内存缓存(合并 file/http/apiserver 三来源,维护静态 Pod ↔ mirror Pod 映射);
- **podWorkers**:每 Pod UID 一个 goroutine,`pendingUpdate` 单槽合并——同一 Pod 排队的一百次变更合并成一次重新调和,串行化保证;
- **PLEG**:周期 relist(1s)对比缓存生成容器级事件——**选择"1s 全量 relist"而非纯事件订阅,是为了对抗 CRI 事件流不可靠的现实**(轮询保证最终一致,事件保证低延迟,双轨叠加);
- **kuberuntime**:CRI 客户端封装,`computePodActions` + `SyncPod` 是调和算法本体;
- prober/statusManager/evictionManager/GC。

**同步调和、异步上报的分离**:SyncPod 全程只更新 statusManager 内存缓存,真正的 apiserver PATCH 由后台 goroutine 批量完成——容器操作耗时(拉镜像数分钟)不阻塞状态写入;代价是 `kubectl get pod` 看到的状态天然滞后一到两个上报周期。

## 5.1 syncLoop:多路 select 触发器

主循环是永不返回的 for:每轮检查运行时就绪(不就绪则指数退避),进入 syncLoopIteration 的多路 select。**注释特别提醒:select 多就绪时是伪随机,事件源之间没有优先级保证**(kubelet.go:2732-2737)。

channel 分派全景:configCh(ADD/UPDATE/REMOVE)→ podWorkers;plegCh(只触发"值得同步"的 Pod,isSyncPodWorthy 过滤 ContainerRemoved);1s syncTicker(周期性兜底调和);三探针 manager 的 Updates(readiness 改 status 触发 sync,liveness 失败重新入队);2s housekeepingCh(全局对账:对齐 worker 集合、清孤儿探针/状态/目录/mirror pod)。

**收敛性不依赖事件不丢**:pendingUpdate 合并 + 10s 退避重试 + 1s/2s 双 ticker 兜底——即便 PLEG 漏报或 apiserver 推送中断,系统也会被拉回期望状态。这与第 03 章的控制器哲学完全一致,但多了一层"每 Pod 串行"的物理隔离。

## 5.2 SyncPod 与 computePodActions 决策树

`Kubelet.SyncPod` 的前置闸门:网络未就绪只拦非 hostNetwork(**hostNetwork 是引导类组件(CNI 插件自身)存活的前提——鸡生蛋问题的代码解法**);cgroup 层级不对就全杀重建("用重建代替修补"的思路贯穿全文)。

运行时层 `computePodActions`(kuberuntime_manager.go:1276)的决策树:

```
sandbox 需要重建? → 是: KillPod 全量重建(sandbox = Pod 网络身份, IP 变了 Pod 就算换了)
init 容器未完成? → 一次只放下一批, 失败整体 abort
遍历常规容器:
  不存在/未运行 → ShouldContainerBeRestarted? → 加入待启动
  在运行 → 依次判断:
    (1) spec hash 变了 → 必杀必重启(不看 restartPolicy)
    (2) liveness 探针失败 → 杀
    (3) startup 探针失败 → 杀
    (4) resize → 原地更新或重启
keepCount==0 → KillPod=true
```

**先杀后建**的顺序保证同一时刻不会出现两份同名容器实例。sidecar(restartable init)专门处理:常规 init 失败中断整条链,sidecar 失败仅跳过;keepCount==0 时清空 InitContainersToStart 防 sidecar 单独"续命"。

## 5.3 CRI 编排顺序

创建:RunPodSandbox(CNI 分配 Pod IP)→ PodSandboxStatus 取 IP → 置 PodReadyToStartContainers → 每容器 EnsureImageExists → CreateContainer → StartContainer → PostStart hook(失败杀容器)。销毁恰好逆序;**sandbox 移除交给 GC 而非同步执行**。

**为什么先建 sandbox**:CRI 把"Pod 的网络与命名空间"折叠进 pause 容器——业务容器崩溃重建时网络身份不变;sandbox 死亡意味着 IP 失效,必须 KillPod 全量重建。CrashLoopBackOff 是 **kubelet 侧实现而非运行时**:以 podUID/containerName 为 key 指数退避,退避中跳过 startContainer 并发 "Back-off restarting failed container" 事件。

## 5.4 探针与重启:解耦的两段语义

- **readiness 只改 status**(影响 Endpoints/Service 流量),**永不重启容器**;
- **liveness/startup 失败进入决策树杀容器**;杀掉之后是否重建由 restartPolicy 决定(`shouldRestartOnFailure` = `!= Never`)——RestartPolicy: Never 的 Pod,liveness 失败只杀不重建;
- probe worker 自身从不直接杀容器——**所有破坏性动作收口在 computePodActions 一处**,便于审计与测试;
- 连续 Threshold 次同向结果才翻转状态(单次抖动不翻转);liveness 失败后 worker 置 onHold 直到看到新容器 ID。

优雅删除期间探针直接置 Success 并停止 worker——避免删除过程中产生噪音事件。

## 5.5 节点上报与驱逐

**双心跳并存**:Node status PATCH(带抖动错峰,状态无变化跳过)+ **Lease 心跳**(续租间隔 = leaseDuration × 0.25,轻量"我还活着"信号)——两者解耦后心跳不再受 status 体积影响。conditions 直接读 evictionManager 的判断。

**驱逐**:10s 周期控制循环(内存压力可走 memcg 内核通知提前触发);内存压力排序规则一眼可见(helpers.go:816-820):**用量超 requests 的先驱逐 > priority 低的先驱逐 > 用量大的先驱逐**。软阈值(配 grace period)持续超限才触发,硬阈值立即生效。压力下 `Admit` 拒绝新 Pod 但 Critical Pod 直接放行。

**GC 保留死容器的原因**:`kubectl logs --previous`、退出码、状态拼装都依赖运行时里尚存的 exited 容器记录——"每 Pod 保底 N 个 + 全局总量上限"的两级策略。

## 5.6 FAQ

**Q1:容器挂了多久被发现?**
PLEG 每 1s relist;极端情况下 PLEG 自身超时 3 分钟会把节点标记 NotReady。

**Q2:syncLoop 多事件就绪的顺序?**
Go select 伪随机,不可依赖;兜底由 1s ticker 的周期调和保证。

**Q3:liveness 失败一定重启吗?**
杀容器是一定的;是否重建由 restartPolicy 决定——Never 时只杀不重建。

**Q4:为什么 Pod IP 变了算"换了 Pod"?**
sandbox(pause 容器)承载网络命名空间;sandbox 死亡即 IP 失效,决策树判 KillPod 全量重建。

**Q5:kubelet 会做调度决策吗?**
不会。准入只做"本节点装不装得下"与压力拒绝;资源紧张宁可驱逐存量 Pod 也绝不越权重新分配——全局最优是 scheduler 的事,kubelet 只保证"本节点不崩"。

## 5.7 小结与深挖方向

本章结论:**kubelet = "每 Pod 串行 worker + 纯函数决策树 + 先杀后建不变量 + 双轨心跳"**;它把"节点自保"做成声明式的阈值系统,即使 apiserver 完全失联也能本地自稳。深挖:

1. podWorkers goroutine 数与 Pod 数线性相关的规模上限;
2. PLEG relist 的 CPU 代价与 Evented PLEG 的事件可靠性;
3. InPlacePodVerticalScaling 的 resize 决策树分支;
4. 驱逐排序在 Guaranteed 但超限的 Pod 上的行为;
5. 死容器 GC 与状态拼装的已知短板(kubelet_pods.go:1247 的 TODO)。

> 下一章(卷末):总结与跨卷对照。
