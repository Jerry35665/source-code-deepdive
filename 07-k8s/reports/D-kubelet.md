# D-kubelet:节点上的 Pod 生命周期管理

> 调研基线:kubernetes master,commit `517a94ff`(2026-09-04)。所有行号均对应该版本。
> 注:调研提纲中提到的 `kubelet_pods_bridge` 在当前代码中不存在;Pod 级同步入口是 `Kubelet.SyncPod`(pkg/kubelet/kubelet.go),Pod 级销毁入口是 `SyncTerminatingPod`/`HandlePodCleanups`(pkg/kubelet/kubelet_pods.go)。

## ① 全景:节点代理 = 期望状态调和器

kubelet 是运行在每个节点上的"控制器的控制器"。它不编排(调度决策属于 kube-scheduler,期望状态归属 apiserver),只做一件事:**把本节点的实际容器状态,持续调和(reconcile)成 apiserver 中记录的期望状态**。代码注释对此有明确表述:"SyncPod is the transaction script for the sync of a single pod... expected to converge a pod towards the desired state of the spec"(pkg/kubelet/kubelet.go:2007-2018)。

启动主干在 cmd/kubelet/app/server.go:`NewKubeletCommand`(server.go:142)→ `run`(server.go:656,完成 kubelet 配置动态加载、鉴权 `BuildAuth`(server.go:790)等)→ `RunKubelet`(server.go:1286)→ `createAndInitKubelet` → `NewMainKubelet`(server.go:1368)构造巨型 Kubelet 结构体 → `startKubelet`(server.go:1342)以 4 个 goroutine 分别启动主循环 `k.Run` 与 10250 只读/资源/ Pod 三组 HTTP server。

`Kubelet.Run`(pkg/kubelet/kubelet.go:1925 起)按依赖顺序拉起各子系统:先 `initializeModules`(不依赖运行时,如 metrics、目录, kubelet.go:1774)与 `initializeRuntimeDependentModules`(cAdvisor → containerManager → evictionManager,kubelet.go:1831-1858,注释明确"eviction decisions are based on the allocated pod resources"),再启动 allocationManager(1938)、volumeManager(1943)、节点状态上报(1955-1969)、nodeLeaseController(1969)、PLEG(1994),最后进入 `kl.syncLoop(ctx, updates, kl)`(2004)——这就是主循环。

核心组件分工:

- **podManager**(pkg/kubelet/pod/pod_manager.go):期望状态的内存缓存,合并 file/http/apiserver 三个来源,并维护静态 Pod ↔ mirror Pod 映射;
- **podWorkers**(pkg/kubelet/pod_workers.go):每个 Pod UID 一个 goroutine(worker),`UpdatePod` 把更新合并为 `pendingUpdate`(pod_workers.go:989-998),保证同一 Pod 的同步串行化;
- **PLEG**(pkg/kubelet/pleg/generic.go):通过周期 relist(1s,kubelet.go:216)对比缓存生成容器级事件;
- **kuberuntime**(pkg/kubelet/kuberuntime/):CRI 客户端封装,`computePodActions` + `SyncPod` 是调和算法本体;
- **prober / statusManager / evictionManager / GC**:探针、状态上报、驱逐与垃圾回收。

还有一条容易被忽略的旁路是状态回写:SyncPod 全程只更新 statusManager 的内存缓存(`SetPodStatus`,pkg/kubelet/status/status_manager.go:485),真正的 apiserver PATCH 由 statusManager 自己的后台 goroutine 批量完成(`syncBatch`,status_manager.go:1168),并借助 `apiStatusVersions`(status_manager.go:80)做资源版本比较防止旧状态覆盖新状态。这个"同步调和、异步上报"的分离让容器操作的耗时(如拉镜像数分钟)不会阻塞状态写入路径,但也意味着 `kubectl get pod` 看到的状态天然滞后于节点实际状态一到两个上报周期。

## ② syncLoop 逐段解读

`syncLoop`(kubelet.go:2674-2715)是永不返回的 for 循环:每轮先检查 `runtimeState.runtimeErrors()`(运行时/网络/存储未就绪则指数退避跳过,2698-2705),然后进入 `syncLoopIteration`。三个 ticker:syncTicker 1s(2680)、housekeepingTicker 2s(kubelet.go:184)、PLEG watch channel(2684)。

`syncLoopIteration`(kubelet.go:2749-2869)是一个多路 select。注释特别提醒:select 多个 case 就绪时是**伪随机选择**,因此各事件源之间没有优先级保证(kubelet.go:2732-2737)。channel 分派全景:

```
                        +------------------------- syncLoop (kubelet.go:2749) -----+
  file/http/apiserver   |                                                         |
  (PodConfig.Updates) --+-> configCh ---- ADD/UPDATE/REMOVE/RECONCILE/DELETE      |
                        |                  |  HandlePodAdditions/Updates/Removes  |
                        |                  v  (kubelet.go:2761-2784)              |
                        |             podWorkers.UpdatePod  (每个Pod串行goroutine)|
                        |                                                         |
  PLEG relist(1s) ------+-> plegCh ------ isSyncPodWorthy(排除ContainerRemoved)   |
                        |                  GetPodByUID -> HandlePodSyncs          |
                        |                  (2787-2797); ContainerDied 触发        |
                        |                  cleanUpContainersInPod (2799-2803)     |
                        |                                                         |
  1s ticker ------------+-> syncCh ------ getPodsToSync -> HandlePodSyncs         |
                        |                  (2804-2811, 周期性兜底调和)             |
                        |                                                         |
  livenessManager ------+-> Updates() --- Failure => handleProbeSync              |
  readinessManager -----+-> Updates() --- SetContainerReadiness + sync            |
  startupManager --------+-> Updates() --- SetContainerStartup + sync              |
                        |                  (2812-2833)                            |
  containerManager -----+-> Updates() --- 设备等变更 -> HandlePodSyncs (2834-2849)|
                        |                                                         |
  2s ticker ------------+-> housekeepingCh -> HandlePodCleanups                    |
                        |                  (2850-2866, sources未ready则跳过)      |
                        +---------------------------------------------------------+
```

几个要点:

1. **ADD 即准入**:configCh 的 ADD 走 `HandlePodAdditions`(kubelet.go:2886)。每个 Pod 先 `podManager.AddPod`(2896,注释称 podManager 是"desired state 的 source of truth"),再经 `kl.allocationManager.AddPod` 准入(2924,含资源预留检查);失败则 `rejectPod`(2925,直接把 Pod phase 置 Failed 回写 apiserver);成功则 `podWorkers.UpdatePod`(2947)。
2. **DELETE 被当作 UPDATE 处理**,因为优雅删除依赖 DeletionTimestamp 而非立即消失(kubelet.go:2778-2781)。
3. **PLEG 事件只触发"值得同步"的 Pod**:`isSyncPodWorthy` 过滤掉 `ContainerRemoved`(kubelet.go:3536-3538),避免删除事件引发无效 sync;`ContainerDied` 额外触发 `cleanUpContainersInPod` 清理死容器(2799-2803)。
4. **三探针的回流点**就在主循环:liveness 失败经 `handleProbeSync` 重新入队同步(2812-2815),readiness/startup 先更新 statusManager 再触发 sync(2816-2833)。
5. **housekeeping(2s)是全局对账**:`HandlePodCleanups`(kubelet_pods.go:1224)执行 `podWorkers.SyncKnownPods` 对齐 worker 集合(1257)、清理孤儿探针(1307)、孤儿状态(1311)、孤儿目录(1328)、孤儿 mirror pod(1339-1348)等,注释里强调"所有清理任务都应执行,即使其中一个失败"(1330-1332)。

事件到达 `podWorkers.UpdatePod` 之后并未直接执行:worker 把更新塞进单槽的 `pendingUpdate`(pod_workers.go:989),正在运行的 sync 结束后才取出最新一份——同一 Pod 排队的一百次变更会被合并成一次重新调和。sync 失败时通过 workQueue 以 `backOffPeriod = 10s`(kubelet.go:224)加抖动重新入队(pod_workers.go:1061);无事件时也周期性入队形成兜底 resync(pod_workers.go:1531)。这组机制共同保证:**syncLoop 是事件驱动的触发器,收敛性由"每轮全量 diff + 周期性重试"兜底**,而不是依赖事件不丢——即便 PLEG 漏报或 apiserver 推送中断,1s syncTicker 与 2s housekeeping 也会把系统拉回期望状态。

## ③ SyncPod 与 computePodActions 决策树

每个 Pod worker 的 goroutine 最终调用 `Kubelet.SyncPod`(kubelet.go:2056)。它的执行序列:

1. `generateAPIPodStatus` 汇总运行时状态生成 API status(2111);若 phase 已是 Succeeded/Failed 直接 `isTerminal` 返回(2124-2128);
2. 网络未就绪且非 hostNetwork 则报错返回(2141-2144);
3. 注册 secret/configMap 追踪(2147-2154);
4. QoS cgroup 检查:若 pod cgroup 不存在且非首次 sync,先杀掉所有容器再用新 cgroup 拉起(2178-2188,注释解释这是 cgroups-per-qos 开关切换后的收敛行为);`pcm.EnsureExists` 确保 pod cgroup 存在(2210);
5. `tryReconcileMirrorPods`(2223,静态 Pod 补建/重建 mirror);
6. `makePodDataDirs`(2226)→ `volumeManager.WaitForAttachAndMount`(2233,阻塞等挂载)→ `probeManager.AddPod`(2253,确保探针 worker 存在);
7. 终于调用运行时层的 `kl.containerRuntime.SyncPod`(2270),这是真正的容器调和。

kuberuntime 层的 `SyncPod`(pkg/kubelet/kuberuntime/kuberuntime_manager.go:1580)第一步就是 `computePodActions`(1583),产出 `podActions` 决策。决策树如下:

```
computePodActions (kuberuntime_manager.go:1276)
|
+-- sandbox 是否需要(重)建? PodSandboxChanged (1280)
|   +-- 是: RestartPolicy==Never 且曾建过容器? -> 只杀不建 (1307-1318)
|   |        否则: 过滤掉已成功容器后 InitContainersToStart=[0] 或 ContainersToStart (1320-1364)
|   +-- 否(已有Running sandbox)继续
+-- EphemeralContainers 未存在 -> 加入待启动(不重启) (1368-1375)
+-- computeInitContainerActions -> 初始化未完成/失败? -> 返回(不动常规容器) (1384-1389)
+-- 遍历 pod.Spec.Containers (1394):
|   +-- 容器不存在/未运行: ShouldContainerBeRestarted? -> ContainersToStart (1409-1426)
|   |     (状态Unknown则先记入ContainersToKill防双实例, 1413-1424)
|   +-- 容器在运行, 依次判断是否该杀 (1439-1459):
|       (1) spec hash 变了            -> 必杀必重启 (1439-1443)
|       (2) liveness 探针 Failure     -> 杀, reason=reasonLivenessProbe (1444-1447)
|       (3) startup 探针 Failure      -> 杀, reason=reasonStartupProbe (1448-1451)
|       (4) 需要 resize 重启          -> computePodResizeAction (1452-1454)
|       (5) 否则 keepCount++ 保留容器 (1455-1458)
+-- keepCount==0 且无待启动 -> KillPod=true, 清空 InitContainersToStart (1481-1486)
```

关键代码(spec 变化与探针击杀,1439-1447):

```go
var message string
var reason containerKillReason
restart := shouldRestartOnFailure(pod) // != RestartPolicyNever (675-677)
if _, _, changed := containerChanged(&container, containerStatus); changed {
    message = fmt.Sprintf("Container %s definition changed", container.Name)
    // Restart regardless of the restart policy because the container spec changed.
    restart = true
} else if liveness, found := m.livenessManager.Get(containerStatus.ID); found && liveness == proberesults.Failure {
    // If the container failed the liveness probe, we should kill it.
    message = fmt.Sprintf("Container %s failed liveness probe", container.Name)
    reason = reasonLivenessProbe
}
```

拿到决策后,运行时 `SyncPod` 按 Step 2→9 执行(kuberuntime_manager.go:1597-1961):`KillPod` 为真先 `killPodWithSyncResult` 杀全部容器再停 sandbox(1605);否则逐个 `killContainer` 杀掉 `ContainersToKill`(1617-1626)。随后才进入创建路径(见 ④)。注意"先杀后建"的顺序保证了同一时刻不会出现两份同名容器实例。

对 `podActions` 结构本身有几点值得展开。其一,`Attempt` 字段记录的是 sandbox 的第几次尝试(PodSandboxChanged 返回),sandbox 每重建一次编号加一,这也是 `kubectl describe` 里 sandbox 命名后缀的来源;其二,`ContainersToKill` 是 map[kubecontainer.ContainerID]containerToKillInfo,杀容器必须带 reason 与 message,这些信息最终以事件形式暴露给用户,是排障的第一手材料;其三,决策树对 sidecar(restartable init container)做了专门处理:常规初始化失败会中断整条 init 链,但 sidecar 启动失败仅跳过继续(kuberuntime_manager.go:1924-1927),且 `keepCount==0` 时会清空 `InitContainersToStart` 防止 sidecar 单独把 Pod"续命"(1483-1486);其四,in-place 垂直伸缩(InPlacePodVerticalScaling)的 resize 动作也挂在同一棵决策树上——能原地更新的资源进入 `ContainersToUpdate`,需要重启容器的 resize 才进入 kill/start 路径(1452-1454),这是近期版本把"改规格即重建"逐步演进为"原地生效"的代码痕迹。

Pod 级 kill 入口在 kubelet 层:`Kubelet.killPod`(kubelet_pods.go:1064-1074)调用 `containerRuntime.KillPod` 后顺带 `UpdateQOSCgroups`;底层 `killPodWithSyncResult`(kuberuntime_manager.go:2119-2138)先杀容器再逐个 `StopPodSandbox`,注释注明"sandbox 将由 GC 移除"(2126)。

回看 SyncPod 开头的几道闸门也有讲究。网络未就绪检查(kubelet.go:2141)只拦非 hostNetwork 的 Pod——hostNetwork Pod 不依赖 CNI,是引导类组件(CNI 插件自身常以 hostNetwork 静态 Pod 部署)能存活的前提,这是鸡生蛋问题的代码解法。cgroup 那段看似冗余的"不存在就全杀重建"(2178-2188)同样有明确动机:当管理员修改 cgroups-per-qos 开关并重启 kubelet 后,存量容器位于旧层级之下,与其在不正确的 cgroup 层级里继续运行,不如整只 Pod 重来,把层级纠正收敛为一次普通的 Pod 重建。这类"用重建代替修补"的思路贯穿 kubelet 全文。

## ④ CRI 编排顺序:Sandbox → 容器

创建侧的 CRI 调用序列(全部为 gRPC 到 containerd/CRI-O):

```
RunPodSandbox (kuberuntime_sandbox.go:71)
  |-- 运行时拉起 pause/sandbox 容器, CNI 分配 Pod IP
PodSandboxStatus (kuberuntime_manager.go:1754)   # 取回 PodIP
OnPodSandboxReady 回调: 置 PodReadyToStartContainers=True (1778-1786)
对每个容器(ephemeral -> init -> regular, 1901-1959):
  EnsureImageExists        # 拉镜像 (kuberuntime_container.go:215)
  CreateContainer          # 创建容器, 不启动 (kuberuntime_container.go:277)
  StartContainer           # 启动 (kuberuntime_container.go:292)
  PostStart hook           # 失败则杀掉该容器并返回错误 (320-337)
```

销毁侧顺序恰好相反:先杀所有业务容器(`killContainersWithSyncResult`),再 `StopPodSandbox`(kuberuntime_manager.go:2121-2135)。sandbox 移除交给 GC 而非同步执行(2126)。

init 容器严格串行:一次 sync 只会放 `InitContainersToStart = [idx]` 的下一批(kuberuntime_manager.go:1914-1934),某个 init 容器启动失败则整体 abort;但 restartable init container(sidecar)失败仅跳过继续(1924-1927)。常规容器之间则相互独立,某个失败不影响其他容器继续启动(1952-1959)。

镜像失败被映射为面向用户的事件错误码:`ErrImagePullBackOff`/`ErrCreateContainerConfig`/`ErrCreateContainer`(kuberuntime_container.go:1828-1852),对应 `kubectl describe pod` 里看到的那些 reason。CrashLoopBackOff 由 kubelet 侧实现而非运行时:`doBackOff`(kuberuntime_manager.go:2074-2106)以 `podUID/containerName` 为 key,用容器上次退出时间做指数退避判定,退避中直接跳过 `startContainer`(1815-1819),并发出 "Back-off restarting failed container" 事件(2095-2096)。

为什么要先建 sandbox 再建容器?CRI 把"Pod 的网络与命名空间"折叠进 sandbox(pause 容器)这一层:所有业务容器共享 sandbox 的 network namespace 与 IPC,业务容器崩溃重建时网络身份不变;反之 sandbox 死亡意味着 IP 失效,所以 `PodSandboxChanged` 判定 sandbox 不在了就必须 `KillPod` 全量重建(kuberuntime_manager.go:1280-1282),这正是"Pod IP 变了 Pod 就算换了"语义的实现根基。另外 `RunPodSandbox` 是同步的:它返回成功时 CNI 已完成 IP 分配,因此 kubelet 紧接着调用 `PodSandboxStatus` 取回 IP 并把 `PodReadyToStartContainers` 条件置真(kuberuntime_manager.go:1754-1786),之后才开始镜像拉取,让用户能尽早看到"网络就绪、正在拉镜像"的状态区分。

## ⑤ 探针与重启语义

`prober_manager` 为每个 (container, probe) 派生一个 worker goroutine(pkg/kubelet/prober/worker.go:97),`doProbe`(worker.go:215-392)是核心:

1. Pod 已是 Failed/Succeeded 则 worker 退出(229-233);
2. 容器 ID 变化(重启后)则重置结果缓存并解除 onHold(250-288);
3. `InitialDelaySeconds` 未到就跳过(331-333);
4. startup 探针成功后停止探测;startup 未成功前其他探针挂起(335-346);
5. 连续 `FailureThreshold`/`SuccessThreshold` 次同向结果才翻转状态(366-377);
6. liveness/startup 失败后置 `onHold`,直到看到新容器 ID 才继续探测(381-390,注释引用 issue #21751)。

探测的执行层 `prober.probe`(pkg/kubelet/prober/prober.go)按 spec 分派四种实现:exec 探针经 CRI `ExecSync` 在容器内执行命令(prober.go:157-159);http 探针直接由 kubelet 进程向 Pod IP 发起 HTTP 请求,因此能获得响应码与 body 细节;tcp 探针只验证端口可连通(prober.go:193);grpc 探针支持 TLS 与 service 校验(prober.go:204)。值得注意的取舍是:exec 探针走 CNI 之外容器内路径,不受网络插件影响,但注释明确"exec probe does NOT have access to pod environment variables or downward API"(worker.go:348);http/tcp 探针则占用 kubelet 自身的连接资源,大规模 Pod 密度下需要关注探测风暴。

阈值语义上,worker 维护 `resultRun` 连续计数,只有连续 `FailureThreshold`/`SuccessThreshold` 次同向结果才写回 resultsManager(worker.go:366-377),单次抖动不会翻转状态;而写回的动作通过三个 manager 的 Updates channel 汇入 syncLoop(见 ②),形成"探测结果 → 事件 → 重新调和 → 决策树消费"的闭环,而不是探测 worker 直接杀容器——所有破坏性动作仍然收口在 computePodActions 一处,便于审计与测试。

三探针的反馈路径完全不同,这正是 kubelet 语义设计的精妙处:

- **readiness**:只改 status(`SetContainerReadiness`,kubelet.go:2818)影响 Endpoints/Service 流量,**永不重启容器**;
- **liveness/startup**:失败会被 `computePodActions` 读到(1444-1451)从而杀容器;杀掉之后**是否重建由 restartPolicy 决定**:`shouldRestartOnFailure(pod)` 即 `RestartPolicy != Never`(kuberuntime_manager.go:675-677)。也就是说 `RestartPolicy: Never` 的 Pod,liveness 失败只杀不重建;
- **是否该重启死亡容器**由 `ShouldContainerBeRestarted`(pkg/kubelet/container/helpers.go:90-126)判定:Pod 已标记删除则不重启;从未启动过则启动;`OnFailure` 时退出码为 0 不重启(118-124)。

优雅删除期间探针还有特殊处理:Pod 带 DeletionTimestamp 时 liveness/startup 直接置 Success 并停止 worker(worker.go:317-328),避免删除过程中探针失败产生噪音事件或干扰终止流程。

## ⑥ 节点上报与驱逐、GC 概览

### 节点状态与 lease 心跳

两套心跳并存(kubelet.go:1945-1969 的注释解释了分工):

- **Node 对象 status PATCH**:`wait.JitterUntil(syncNodeStatus, nodeStatusUpdateFrequency, 0.04, ...)`(1959)。`syncNodeStatus`(kubelet_node_status.go:452-467)先 `registerWithAPIServer` 再 `updateNodeStatus`,后者最多重试 `nodeStatusUpdateRetry` 次(474)。为降低 apiserver 压力做了两个优化:tryNumber==0 时从本地 lister 读 Node,冲突时才打 etcd(kubelet_node_status.go:490-504);状态无变化且上报期未到则跳过 PATCH(513),并在状态变化时给上报周期加随机抖动错峰(528-532)。
- **Lease 心跳**:`nodeLeaseController.Run`(kubelet.go:1969),续租间隔 = leaseDuration × 0.25(1158-1159,238)。lease 是轻量的"我还活着"信号,apiserver 的 node lifecycle controller 据此判定节点 NotReady;status 上报频率更低,两者解耦后心跳不再受 status 体积影响。

Node conditions 由 `defaultNodeStatusFuncs`(kubelet_node_status.go:731-759)组装:MemoryPressure/DiskPressure/PIDPressure 直接读取 evictionManager 的判断(746-748),ReadyCondition 综合运行时状态、网络、存储、containerManager 与节点关闭管理器(749-750)。除常规循环外,kubelet 启动初期还有一条快速路径 `fastStatusUpdateOnce`(kubelet.go:1964):节点刚变 Ready 时做一次即时上报后即退出,避免新节点注册后要等一个完整上报周期才可调度;镜像 pod 也有一条类似的快速注册路径 `fastStaticPodsRegistration`(kubelet.go:1976,3590-3609),让调度器尽早感知静态 Pod 的资源占用。

### 驱逐(eviction)

`evictionManager`(pkg/kubelet/eviction/eviction_manager.go)是 10s 周期(kubelet.go:198 `evictionMonitoringPeriod`)的控制循环,内存压力还可走 memcg 内核通知路径提前触发(eviction_manager.go:194-206)。`synchronize`(256 起)对比各 signal(available memory、allocatable memory、imagefs/nodefs 可用量等)与 threshold;超阈值时先尝试节点级回收(删镜像等,`signalToNodeReclaimFuncs`),仍不满足则按 rank 杀 Pod。内存压力排序规则一眼可见(helpers.go:816-820):

```go
// rankMemoryPressure orders the input pods for eviction in response to memory pressure.
// It ranks by whether or not the pod's usage exceeds its requests, then by priority, and
// finally by memory usage.
func rankMemoryPressure(pods []*v1.Pod, stats statsFunc) {
	orderedBy(exceedMemoryRequests(stats), priority, memory(stats)).Sort(pods)
}
```

即:用量超 requests 的先驱逐 > priority 低的先驱逐 > 用量大的先驱逐。被驱逐 Pod 调 `evictPod`(eviction_manager.go:637)以本地 kill 而非 apiserver eviction API 完成。驱逐同时把 pressure condition 上报为 Node condition,进而参与 kubelet 准入:`Admit`(eviction_manager.go:146-184)在压力下拒绝新 Pod,但 Critical Pod 直接放行(157-159),仅内存压力时非 BestEffort 也放行(162-177)。

驱逐阈值分软硬两档,语义差异值得记住:软阈值(如 `memory.available<1.5Gi` 配合 grace period)只有持续超限到宽限期才会触发,信号在 `thresholdsFirstObservedAt` 里记录首次观测时间(eviction_manager.go:89-90);硬阈值立即生效。信号覆盖 memory.available、nodefs/imagefs 可用量、pid.available 及本地存储容量隔离等,容器/镜像/日志分盘(同一块盘还是独立 imagefs)会让同一阈值映射到不同的 rank 与 reclaim 函数(synchronize 里构建 `signalToRankFunc` 的分支,eviction_manager.go:267-298)。这套设计的本质是把"节点自保"做成声明式的阈值系统:运维通过 KubeletConfiguration 声明水位,kubelet 负责观测、排序、执行与状态外显的全闭环,不依赖任何外部决策者。

### GC

两条独立 goroutine(kubelet.go:1721-1770):容器 GC 每 1 分钟(`ContainerGCPeriod`,230),镜像 GC 每 5 分钟(232)。容器 GC(kuberuntime_gc.go:229-279)按 (podSandboxID, containerName) 归并"可驱逐单元",先执行 `MaxPerPodContainer`(每单元最多保留的死容器数,247-248),再全局执行 `MaxContainers`(252-269),都按创建时间从旧到新删除;且只考虑超过 `MinAge` 的死容器(192-199)。sandbox 的清理由 `evictSandboxes`(281)处理已退出 Pod 的 sandbox。镜像 GC 是阈值驱动(images/image_gc_manager.go:393-394):磁盘使用率超过 `HighThresholdPercent` 时删未被任何容器引用的旧镜像,删到 `LowThresholdPercent` 为止,配置校验见 194-202。

死容器为什么要保留而不即死即删?因为退出的容器是排障与状态生成的数据源:`kubectl logs --previous`、退出码、`generateAPIPodStatus` 拼装 ContainerStatuses 都依赖运行时里尚存的 exited 容器记录。因此 GC 采用"每 Pod 保底 N 个 + 全局总量上限"的两级策略:既保证单个 Pod 最近几次崩溃可查,又防止高密度节点被死容器日志撑爆磁盘。删除粒度上 `removeOldestN` 总是同一单元内从最旧的开始(kuberuntime_gc.go:129),配合 `MinAge` 避免"刚退出就被删"导致状态错乱——kubelet_pods.go:1247-1253 的 TODO 注释承认,若容器退出后立刻被删,kubelet 可能拼不出正确状态,这正是目前缺乏 checkpointing 的已知短板。

## ⑦ 设计动机与取舍:kubelet 为什么不做编排决策

1. **期望状态权威在 apiserver,kubelet 只收敛**。podManager 保存 desired state,注释直说"pods 不在 manager 里就意味着 apiserver 已删除,除清理外不需要任何动作"(kubelet.go:2892-2895)。这使 kubelet 可以随时重启、断网、乱序接收事件而不破坏正确性——每轮 sync 都是全量对比实际与期望,而非应用增量日志。
2. **每 Pod 串行、全局并行**。podWorkers 为每个 UID 开 goroutine 并合并 pending 更新(pod_workers.go:955-998),既避免同一 Pod 两个 sync 竞争运行时,又让数千 Pod 的同步互不阻塞。代价是 goroutine 数量与 Pod 数线性相关。
3. **决策与执行分离**:`computePodActions` 是纯函数式的 diff 计算,`SyncPod` 只负责执行(Step 2-9)。这让"该做什么"可以被单测穷举,也让 RestartAllContainersOnContainerExits 等新特性只需扩 decisions(kuberuntime_manager.go:1290-1302)。
4. **探测/重启/驱逐责任全部下沉到节点**:liveness 击杀、CrashLoopBackOff、驱逐排序都在 kubelet 本地闭环,即使 apiserver 完全失联,节点仍能自稳。代价是这些语义(如 BackOff 时长)在集群视图里不可见,只能靠 status/events 外显。
5. **不做调度决策的边界感**:kubelet 在准入阶段只做"本节点装不装得下"(allocationManager.AddPod,kubelet.go:2924)与压力准入拒绝,一旦资源紧张宁可驱逐存量 Pod 也绝不越权重新分配其他节点的负载——调度全局最优是 scheduler 的事,kubelet 只保证"本节点不崩"。
6. **轮询与事件的双轨制**:PLEG 选择"1s 全量 relist 对比缓存"而非纯事件订阅,是为了对抗 CRI 事件流不可靠、kubelet 错过事件的现实(1s 周期的 CPU 代价写在 kubelet.go:208-215 的注释里);Evented PLEG 作为事件驱动的补充路径在旁待命。这与控制系统的经典取舍一致:轮询保证最终一致与实现简单,事件保证低延迟,两者叠加才能同时满足正确性与实时性。

## ⑧ FAQ

**Q1:syncLoop 的多个 case 就绪时,处理顺序?**
Go select 伪随机评估,代码注释明确说明不可依赖顺序(kubelet.go:2732-2737)。兜底逻辑由 1s syncTicker 的周期调和保证最终一致。

**Q2:容器挂了,多久被发现?**
Generic PLEG 每 1s relist(kubelet.go:216),发现差异后生成事件(generic.go:249-268),事件经 plegCh 触发该 Pod 的 sync。极端情况下 PLEG 健康检查超时 3 分钟(genericPlegRelistThreshold,kubelet.go:217)会把节点标记为 NotReady。

**Q3:为什么 DELETE 事件会走 HandlePodUpdates?**
优雅删除靠 DeletionTimestamp 表达,apiserver 侧 Pod 不会立即消失,因此按更新处理,由 podWorkers 走 SyncTerminatingPod 路径(kubelet.go:2778-2781)。

**Q4:CrashLoopBackOff 是谁实现的?运行时吗?**
kubelet。`doBackOff` 用 flowcontrol.Backoff 以 pod/container 为 key 做指数退避(kuberuntime_manager.go:2074-2106),运行时只负责如实报告退出状态。

**Q5:readiness 失败会重启容器吗?**
不会。readiness 只调用 `statusManager.SetContainerReadiness` 改状态(kubelet.go:2816-2824);`computePodActions` 只消费 livenessManager 和 startupManager(1444-1451)。

**Q6:重启计数 RestartCount 怎么来的?**
启动容器时取旧状态 RestartCount+1(kuberuntime_container.go:224-227);节点重启后运行时状态丢失时,通过扫描日志文件名 `{restartCount}.log` 反推(229-245)。

**Q7:静态 Pod 为什么需要 mirror pod?**
apiserver 看不到 file/http 来源的静态 Pod,无法展示状态、统计资源。mirror pod 与静态 Pod 同 fullname 但不同 UID,podManager 维护 UID 翻译表(pod_manager.go:174-196),状态上报时用 fullname 对齐。kubelet 会删除与静态 Pod 语义不一致的 mirror 并重建(kubelet.go:3555-3588),孤儿 mirror 也在 housekeeping 清理(kubelet_pods.go:1339-1348)。

**Q8:删除静态 Pod 的 YAML 文件后 Pod 会怎样?**
静态 Pod 消失,对应 mirror 成为孤儿被删除(mirror_client.go:116 起,GracePeriodSeconds=0 直接删,kubelet_pods.go:1339-1348)。手动 `kubectl delete mirror pod` 则会被重建,因为静态源还在,`tryReconcileMirrorPods` 发现 mirror==nil 就重新 CreateMirrorPod(kubelet.go:3575-3587)。

**Q9:节点内存吃紧时 kubelet 的第一反应?**
若启用 KernelMemcgNotification,memcg 事件会在 OOM 前主动触发 synchronize(eviction_manager.go:194-206);否则等 10s 轮询。先 reclaim(删镜像),再按"超用>低优先级>大用量"排序驱逐。

**Q10:node status 和 lease,谁决定节点 NotReady?**
lease 是主心跳(每 leaseDuration/4 续一次,kubelet.go:238),apiserver 的 node controller 依 lease 过期与 NodeReady condition 共同判定;status PATCH 是低频完整状态同步,二者解耦(kubelet.go:1945-1969 注释)。

## ⑨ 深挖问题

1. **In-place resize 的状态一致性**:SyncPod 中 resize 逻辑横跨 `IsPodResizeInProgress`(kubelet.go:2096-2104)、`computePodResizeAction`(kuberuntime_manager.go:1452)与 actuatedState,代码自己承认存在 race:"There is a race condition here... allocation manager may allocate a new resize and unconditionally set the condition"(kubelet.go:2105-2107)。值得跟踪 allocation manager 与 pod worker 的收敛协议。
2. **RestartAllContainersOnContainerExits 的 requeue 循环**:`SyncPod` 完成容器 reset 后会主动 `podWorkers.UpdatePod` 再触发一次 sync(kubelet.go:2285-2294),注释论证了"不会无限循环"依赖 UpdatePod 合并与条件翻转;这一不变量值得验证。
3. **PLEG relist 的扩展性瓶颈**:1s 全量 ListPodSandbox/ListContainers 在万级容器节点上的 CPU 开销是 Evented PLEG(CRI 事件流,worker.go/evented pleg watcher,kubelet.go:219-220 `eventedPlegMaxStreamRetries = 5`)要解决的问题,两个实现的事件语义差异值得深挖。
4. **驱逐与 pod worker 终止的配合**:evictPod 本地 kill 后 `waitForPodsCleanup`(eviction_manager.go:214-217)以 `PodIsFinished`(kubelet_pods.go:1140-1142,即 SyncTerminatedPod 完成)为完成判据;磁盘压力下的多轮驱逐如何避免与优雅终止的 grace period 死锁值得分析。
5. **节点重启后的 RestartCount 反推**:依赖日志文件名 `calcRestartCountByLogDir`(kuberuntime_container.go:239-244),若日志目录被清理或使用非文件日志驱动,journald 场景下 `legacyLogSymlink` 的悬挂链接问题(311)对 RestartCount 正确性的影响值得实验验证。
