# I - Kubernetes 服务发现：informer 驱动的目标工厂

> 源码版本：prometheus/prometheus @ commit `b0f312b`（b0f312ba48c9d31dad04e7014bfb0fa300153a07）。所有行号以该 commit 为准。
> 本章接卷二第 06 章（SD manager 通用层），深读 `discovery/kubernetes/`——所有内置 SD 中最复杂的一个实现（本目录约 9500 行，其中 6 个角色发现器共享一套 informer 骨架）。

## 1. 全景：从 K8s 对象到抓取目标

Kubernetes SD 的本质是一条**对象→标签**的转换流水线。它不直接 watch API server，而是借助 client-go 的 informer 框架：LIST 建缓存 + WATCH 增量维护，Prometheus 只消费"对象变更事件"，再把它翻译成 SD manager 能理解的 `targetgroup.Group` 全量快照。

```
                        Kubernetes API Server
                          ^        | LIST+WATCH (protobuf)
                          |        v
              +-----------------------------+
              | cache.ListWatch (每角色/每namespace 一个) |
              +-----------------------------+
                          |
                          v
              Shared(Index)Informer  ← resyncDisabled=0，禁用 informer 自带 resync
                 |  DeltaFIFO → store/indexer（本地缓存）
                 |  ResourceEventHandler(Add/Update/Delete)
                 v
              workqueue（key 去重合并：namespace/name）
                          |
                          v
              process(): 从 store 按 key 取**最新对象**
                          |
            +-------------+-------------+
            | 存在            | 不存在(已删除)   |
            v                           v
   buildPod/buildNode/...      发送空 Group{Source}（=删除该 Source 全部目标）
            |                           |
            +--------> send(): ch <- []*targetgroup.Group{tg}
                                     |
                                     v
              SD manager 通用层（卷二 06 章）：按 tg.Source 整组替换/删除
```

关键点：每个 K8s 对象对应一个 `targetgroup.Group`，其 `Source` 形如 `pod/ns/name`、`node/name`、`endpointslice/ns/name`（pod.go:494-496、node.go:158-160、endpointslice.go:286-288）。Source 是幂等键——对象变更就重发同名 Group，对象删除就发一个只有 Source 的空 Group，由 SD manager 完成替换/删除（discovery/manager.go:475-486）。

## 2. 架构专节：client 初始化与角色注册

### 2.1 三种接入方式与 RBAC

`New()`（kubernetes.go:284）按配置三分支构建 `rest.Config`：

```go
// kubernetes.go:298-336（节选）
switch {
case conf.KubeConfig != "":
    kcfg, err = clientcmd.BuildConfigFromFlags("", conf.KubeConfig)   // :300
case conf.APIServer.URL == nil:
    // Use the Kubernetes provided pod service account
    kcfg, err = rest.InClusterConfig()                                // :307
    ...
    ownNamespaceContents, err := os.ReadFile(
        "/var/run/secrets/kubernetes.io/serviceaccount/namespace")    // :313
default:
    rt, err := config.NewRoundTripperFromConfig(conf.HTTPClientConfig, "kubernetes_sd") // :325
    kcfg = &rest.Config{Host: conf.APIServer.String(), Transport: rt} // :329
}
kcfg.ContentType = "application/vnd.kubernetes.protobuf"              // :336
```

- **in-cluster 模式（默认）**：`rest.InClusterConfig()` 从 Pod 挂载的 ServiceAccount token/CA 读取凭据（kubernetes.go:307）。这就是"RBAC 授权"的落点：Prometheus 无需在配置里写任何凭据，权限完全由集群管理员绑定的 Role/ClusterRole 决定——最小权限原则由 K8s RBAC 体系承接，Prometheus 只负责按角色请求对应的资源（node 角色只 watch nodes，pod 角色只 watch pods）。
- **own_namespace**：`include_own_namespace: true` 时读取 ServiceAccount namespace 文件（kubernetes.go:312-321），把发现范围收敛到自己所在命名空间。
- **api_server 直连模式**：走 Prometheus 统一的 `HTTPClientConfig`（TLS/认证与其它 SD 一致），且与 kubeconfig_file 互斥（校验在 UnmarshalYAML，kubernetes.go:187-203）。
- **protobuf 编码**（kubernetes.go:336）：API 通信默认用 `application/vnd.kubernetes.protobuf` 而非 JSON，大集群下显著降低 LIST 带宽与反序列化 CPU。
- **client 适配层**：`clientAdapter`（client.go:39-45）把 clientset 的五个 API-group 访问器收成方法值闭包，注释明说是为了避免链接器因反射保留全部 API group 客户端、减小二进制体积（client.go:36-38）。测试可注入 fake clientset（client.go:25-33）。

### 2.2 三种角色的注册（Run 分发）

`Discovery.Run()`（kubernetes.go:389）按 role 构造各自 informer 与发现器，统一汇入 `d.discoverers` 后并发 Run（kubernetes.go:677-688）。三个典型角色：

| 角色 | 注册处 | informer 构成 | 发现器 |
|---|---|---|---|
| node | kubernetes.go:668-672 | 单个 node informer | `NewNode`（node.go:49） |
| pod | kubernetes.go:558-607 | pod 索引 informer（可选 node/namespace/RS/job 附带 informer） | `NewPod`（pod.go:63） |
| endpointslice | kubernetes.go:395-476 | endpointslice + service + pod 三个 informer（+可选附带） | `NewEndpointSlice`（endpointslice.go:62） |

每个 informer 都挂了 namespace 维度的 ListWatch，并把 label/field selector 注入 LIST 与 WATCH 两个方向（如 pod 的 ListWatch，kubernetes.go:573-584）——selector 同时作用于初始全量与后续增量，否则会出现缓存视图不一致。

所有 informer 通过 `mustNewSharedInformer`/`mustNewSharedIndexInformer` 创建（kubernetes.go:947、957），统一 `SetWatchErrorHandlerWithContext` 把 WATCH 错误计入 `kubernetes_sd_failures_total` 指标（kubernetes.go:942-945；指标定义 metrics.go:41-47）。

## 3. pod 发现专节：事件驱动的目标更新

### 3.1 事件管线：handler → workqueue → process

`NewPod` 给 pod informer 注册三个 handler，全部只是"取 key 入队"（pod.go:89-102），真正的逻辑在消费端：

```go
// pod.go:222-248（节选）
func (p *Pod) process(ctx context.Context, ch chan<- []*targetgroup.Group) bool {
    key, quit := p.queue.Get()               // key = "namespace/name"
    ...
    o, exists, err := p.store.GetByKey(key)
    if !exists {
        // 已删除：发送只带 Source 的空 Group，SD manager 据此清掉该 pod 的全部目标
        send(ctx, ch, &targetgroup.Group{Source: podSourceFromNamespaceAndName(namespace, name)}) // :239
        return true
    }
    pod, err := convertToPod(o)
    ...
    send(ctx, ch, p.buildPod(pod))           // :247
}
```

增/改/删三种事件在队列里被**合并成同一语义："重算这个 key 的最新 Group"**。这是 informer 模式的精髓：handler 不携带事件类型语义，消费时永远从本地 store 读对象的当前快照（pod.go:234）。workqueue 的去重特性还天然吸收了事件风暴——同一 pod 短时间多次变更只处理一次。

### 3.2 删除语义 = 空 Group

删除事件到达时对象已不在 store（或以 tombstone 形式，`DeletionHandlingMetaNamespaceKeyFunc` 处理，pod.go:180），于是发送 `&targetgroup.Group{Source: ...}`（pod.go:239）。Group 无 Targets，SD manager 在 `updateGroup` 中 `delete(m.targets[poolKey], tg.Source)`（discovery/manager.go:485）。**"发空组"就是 K8s SD 的目标删除协议**，所有角色一致。

### 3.3 容器端口 → 目标的展开

`buildPod`（pod.go:366）是 pod 角色的目标工厂：

- PodIP 为空（Pending/驱逐中）→ 返回空 Group，等于暂停该 pod 的所有目标（pod.go:371-373）；
- 开了 attach_metadata.node 时，校验 pod 所调度节点存在于 node store，否则跳过——保证与 node selector 过滤一致（pod.go:377-386）；
- **展开规则**（pod.go:397-437）：容器列表 = `spec.containers + initContainers`；每个容器若未声明端口，产出 1 个匿名目标（address=podIP，用户自配端口，pod.go:409-419）；否则每个 (容器， port) 组合产出一个目标，地址为 `net.JoinHostPort(podIP, containerPort)`（pod.go:422-435）。所以**一个 pod 通常产生多个目标**，但它们同属一个 Source 组、共享组级标签。

### 3.4 标签映射面（`podLabels`）

pod 角色的标签映射分两层：通用元数据层 + pod 专属层。通用层是所有角色复用的两个函数：

- `addObjectAnnotationsAndLabels`（kubernetes.go:967-978）：对象每个 label/annotation 生成两条元标签（值 + `*present`）；
- `addObjectMetaLabels`（kubernetes.go:980-983）：追加 `__meta_kubernetes_<role>_name`。

pod 专属层 `podLabels`（pod.go:292-346）：

```go
// pod.go:293-300（节选）
ls := model.LabelSet{
    podIPLabel:       lv(pod.Status.PodIP),        // __meta_kubernetes_pod_ip
    podReadyLabel:    podReady(pod),               // __meta_kubernetes_pod_ready
    podPhaseLabel:    lv(string(pod.Status.Phase)),// __meta_kubernetes_pod_phase
    podNodeNameLabel: lv(pod.Spec.NodeName),       // __meta_kubernetes_pod_node_name
    podHostIPLabel:   lv(pod.Status.HostIP),       // __meta_kubernetes_pod_host_ip
    podUID:           lv(string(pod.UID)),
}
addObjectMetaLabels(ls, pod.ObjectMeta, RolePod)   // name/label_*/labelpresent_*/annotation_*
```

随后是**owner 链回溯**（pod.go:304-343）：`GetControllerOf`（pod.go:283-290，从 ownerReferences 找 `controller: true` 的那个）给出直接控制者 → `__meta_kubernetes_pod_controller_kind/name`；若控制者是 ReplicaSet 且开了 `attach_metadata.deployment`，再向上查 RS 的 owner 拿到 Deployment 名（pod.go:313-325）；若控制者是 Job 且开了 cronjob 元数据，再查 Job 的 owner 拿 CronJob 名（pod.go:326-342）。这条链正是为了让 relabel 能按 `deployment/cronjob` 维度筛选——K8s 原生只有 pod→RS/Job 一层 owner 引用。

常量声明见 pod.go:260-279（`__meta_kubernetes_pod_container_*` 全家桶）。namespace 标签统一为 `__meta_kubernetes_namespace`（kubernetes.go:58，buildPod 中写入 pod.go:389）。

### 3.5 反向联动：node/namespace/RS/job 变更波及 pod

pod 的元数据不只依赖 pod 对象本身，所以 Pod 结构还向附属 informer 注册 handler，用**索引反查受影响的 pod 并重新入队**：

- node 变更 → `enqueuePodsForNode`：按 `nodeIndex`（`pod.Spec.NodeName` 上的索引，kubernetes.go:779-787）反查（pod.go:466-476）；
- namespace 更新 → 按 `cache.NamespaceIndex` 反查（pod.go:478-488；创建/删除由资源自身事件覆盖，见 pod.go:136-137 注释）；
- RS/job 变更 → 分别按 `replicaSetIndex`/`jobIndex` 反查（pod.go:442-464；索引定义 kubernetes.go:793-819）。

这就是 informer + 索引替代"跨对象 join 推送"的典型手法：任何元数据源变化，都把关联对象的 key 重新扔进队列，让 process 走一遍"读最新快照、重发 Group"。

## 4. node / endpointslice 专节（简短）

### 4.1 node.go

- 目标地址：`buildNode`（node.go:186-211）取节点地址 + kubelet 端口 `node.Status.DaemonEndpoints.KubeletEndpoint.Port`（node.go:197）拼成 address，并把 `instance` 直接设为节点名（node.go:201）。
- 地址优先级：`nodeAddress`（node.go:222-247）按 InternalIP → InternalDNS → ExternalIP → ExternalDNS → LegacyHostIP → HostName 取首选地址，注释注明衍生自 kubelet 源码（node.go:221）；每种地址类型另出一条 `__meta_kubernetes_node_address_<type>` 标签（node.go:204-207）。
- 标签面：`nodeLabels`（node.go:168-184）除通用 meta 外，把每个 condition 导出为 `__meta_kubernetes_node_condition_<type>`（node.go:175-179），外加 `__meta_kubernetes_node_provider_id`（node.go:172）。
- 删除语义与 pod 相同：store 查无此 key 即发空 Group（node.go:132-135）。

### 4.2 endpointslice.go

endpointslice 角色是唯一需要**多对象 join** 的角色：EndpointSlice + Service + Pod 三个 informer 缺一不可（Run 处同时等待三者 HasSynced，endpointslice.go:227）。

- **服务反查**：service 变更时按 `serviceIndex`（slice 的 `kubernetes.io/service-name` 标签建索引，kubernetes.go:876-888）反查归属的 slices 重新入队（endpointslice.go:115-131）。
- **目标展开**：`buildEndpointSlice`（endpointslice.go:308-503）三层循环 `endpoints × ports × addresses`（endpointslice.go:450-456），每个组合生成一个目标；endpoint 若 TargetRef 指向 pod，则合并 `podLabels` 并回填匹配端口的容器元标签（endpointslice.go:419-442）；**未被 service 端点覆盖的容器端口**也会补发目标（endpointslice.go:460-500）。
- **双栈去重**：`nonPrimaryIPFamilySlice`（endpointslice.go:525-546）跳过 dual-stack service 的次 IP 族 slice，避免目标重复（endpointslice.go:325-327）。
- endpoints（遗留 API）角色的结构与此同构（endpoints.go），`addNodeLabels`/`addNamespaceLabels` 两个共享辅助函数也定义在 endpoints.go:536、558。

## 5. 缓存与 resync 专节：为什么"全量重发"是安全的

### 5.1 HasSynced 门闩

每个发现器的 `Run` 都先 `cache.WaitForCacheSync`，等 informer 完成首次 LIST、本地 store 与 API server 对齐后才开始消费事件（pod.go:192-211，多 informer 时把所有 `HasSynced` 一起等；node.go:100；endpointslice.go:227-239）。这保证了 process 读 store 永远有完整视图，也保证首个 `Add` 事件风暴（LIST 回放）会为每个对象各发一次 Group——**初始全量发现就是靠 LIST 回放出的 Add 事件完成的**，无需额外的"首次全拉"代码。

### 5.2 resyncDisabled：主动关掉 informer 的周期重同步

```go
// kubernetes.go:385-386
// Disable the informer's resync, which just periodically resends already
// processed updates and distort SD metrics.
const resyncDisabled = 0
```

client-go informer 自带按周期重放 store 内容的 resync 机制，这里显式置 0（kubernetes.go:385-386），注释点明原因：它只是重发已处理过的更新，还会污染 `kubernetes_sd_events_total` 指标语义（metrics.go:33-40）。**所有 informer（含 attach metadata 的辅助 informer）一律禁用 resync**——增量靠 WATCH，一致性靠事件驱动重算，没有周期兜底。代价是：若某次事件在队列中丢失或处理出错，只能等该对象下一次真实变更或 Prometheus 重启（informer 的 watch 断线重连会重新 LIST，间接补齐）。

### 5.3 呼应卷二 06 章：全量快照消费模型

SD manager 的消费端没有"增量 diff"概念：每次收到 `[]*targetgroup.Group` 就按 `tg.Source` **整组替换或删除**（discovery/manager.go:475-486）。K8s SD 完全顺应这一模型——任何粒度的变更都重算并重发**整个对象**的 Group（pod 的全部容器端口目标一起重发），而不是只发变化的那一个目标。对象级幂等快照 + Source 键替换，让"事件乱序、重复、合并"都变得无害。

## 6. 设计动机

1. **为什么用 client-go informer 而非裸 WATCH**：裸 watch 有 resourceVersion 语义、断线重连、LIST-then-WATCH 缝隙、事件合并等诸多细节；informer 把这些封装成"本地缓存 + 事件回调"，且 SharedInformer 允许多个角色（endpointslice 角色同时挂 service 与 pod informer）复用同一份连接与缓存。对 SD 这种"只需要当前状态快照"的消费者，事件语义可以进一步简化成"key 入队、读 store 重算"。
2. **workqueue 合并**：K8s 事件风暴（滚动发布时 pod 频繁重建）下，同 key 事件入队去重，处理时读最新快照——天然把 N 次中间态折叠成 1 次终态计算（pod.go:179-186 + store 读取 pod.go:234）。
3. **标签族的命名空间设计**：统一前缀 `__meta_kubernetes_`（kubernetes.go:57），第二段是对象角色（pod/node/service/endpointslice/ingress/namespace），第三段起是字段语义（`pod_container_port_name`、`node_condition_ready`、`endpointslice_endpoint_conditions_ready`）。用户/labels/annotations 还额外生成 `*_labelpresent_*/**_annotationpresent_*` 孪生标签（kubernetes.go:970-976），让 relabel 能写"存在即匹配"的规则（值可能为空但需区分"无此标签"）。跨对象附加（attach_metadata）复用同一前缀规则：pod 目标上叠 `__meta_kubernetes_node_*`、`__meta_kubernetes_namespace_*` 标签（pod.go:390-395，endpoints.go:536-573）。
4. **RBAC 最小权限**：Prometheus 端不内置凭据逻辑，in-cluster ServiceAccount + RBAC 是官方推荐路径（kubernetes.go:304-306 注释直接给出 k8s.io 文档链接）；角色与 selector 机制（`selectors`，kubernetes.go:146-155）让用户能在 API 侧就过滤对象（如只要带某 label 的 pod），把权限面与流量面同时收窄。配置校验还限制了每个角色允许的 selector 类别（如 node 角色只允许 node selector，kubernetes.go:206-213）。
5. **protobuf 编码**（kubernetes.go:336）：大型集群 LIST 全量 pod 可达数十万对象，protobuf 相比 JSON 的编解码收益是实打实的启动时间。

## 7. FAQ 素材

1. **Q: `role: pod` 时一个 Pod 为什么会产生多个抓取目标？** A: `buildPod` 按容器端口展开，每 (容器, 端口) 一个目标；无端口容器产出一个 address=podIP 的匿名目标（pod.go:397-437）。
2. **Q: Pod 删除后目标怎么消失？** A: 事件处理发现 store 中无此 key，发送只含 Source 的空 Group，SD manager 按 Source 删除整组（pod.go:239；discovery/manager.go:485）。
3. **Q: `__meta_kubernetes_pod_deployment_name` 是直接读到的吗？** A: 不是。pod 只有 RS owner，需再查 RS 的 owner 才能得到 Deployment 名，且要开 `attach_metadata.deployment`（pod.go:313-325）。
4. **Q: 为什么修改了 Node 标签，pod 目标的 `__meta_kubernetes_node_label_*` 也会变？** A: pod 角色向 node informer 注册了 handler，node 变更会按 nodeIndex 反查其上所有 pod 重新入队重算（pod.go:107-128、466-476）。
5. **Q: informer resync 周期怎么配？** A: 不可配，被硬编码禁用（`resyncDisabled = 0`，kubernetes.go:386）；官方注释称周期重放会扭曲 SD 指标。
6. **Q: Prometheus 重启后目标会丢吗？** A: 不会。HasSynced 之前的 LIST 回放会为每个现存对象触发 Add 事件，重新产出全部 Group（pod.go:206-216）。
7. **Q: api_server 与 kubeconfig_file 能同时配吗？** A: 不能，UnmarshalYAML 显式互斥校验（kubernetes.go:187-203）；kubeconfig 也不能与自定义 http_client_config 同用。
8. **Q: endpoints 和 endpointslice 两个角色怎么选？** A: 语义相近，endpointslice 是 K8s 1.21+ 的标准 API 且信息更全（zone/topology/conditions，endpointslice.go:290-306）；实现上前者三个 informer 结构相同。
9. **Q: dual-stack 集群目标会重复吗？** A: 不会，次 IP 族的 slice 被显式跳过（`nonPrimaryIPFamilySlice`，endpointslice.go:525-546）。
10. **Q: selectors 过滤发生在哪一侧？** A: API server 侧，label/field selector 注入 LIST 和 WATCH 请求（kubernetes.go:573-584），本地缓存只含匹配对象。

## 8. 深挖方向

1. **事件合并的边界**：workqueue 去重依赖 key 相同；但 DeltaFIFO 中 Add→Update→Delete 快速连续时，store 终态为"无"，最终只发一个空 Group——验证滚动发布时目标抖动的实际观测窗口。
2. **tombstone 处理**：`cache.DeletionHandlingMetaNamespaceKeyFunc` 与 `nodeName`（kubernetes.go:994-1002）对 `DeletedFinalStateUnknown` 的兼容，讨论 WATCH 断开期间删除事件丢失的场景。
3. **endpoints 角色的 podIndex join**（endpoints.go:824-840 的索引构建）：对比 endpointslice 的 serviceIndex，两种"反向关联"索引的成本模型。
4. **clientAdapter 的二进制体积优化**（client.go:35-38）：Go 反射+链接器保留规则的实战案例。
5. **ingress/service 角色的无端口目标**：service 角色不产生 address 型目标、需 relabel 到 DNS 名（service.go:210-232），与 pod/endpointslice 的 IP 型目标的差异及 scrape 拓扑影响。

## 9. 写作要点速查表

| 内容 | 位置 |
|---|---|
| `metaLabelPrefix = "__meta_kubernetes_"` / namespace 标签 | discovery/kubernetes/kubernetes.go:57-58 |
| 六种 Role 常量（node/pod/service/endpoints/endpointslice/ingress） | discovery/kubernetes/kubernetes.go:75-82 |
| client 三分支初始化（kubeconfig/in-cluster/api_server） | discovery/kubernetes/kubernetes.go:298-333 |
| in-cluster ServiceAccount 配置（RBAC 落点） | discovery/kubernetes/kubernetes.go:307-323 |
| protobuf 编码 | discovery/kubernetes/kubernetes.go:336 |
| `resyncDisabled = 0`（禁 informer resync 及注释） | discovery/kubernetes/kubernetes.go:385-386 |
| `Discovery.Run` 角色 switch（pod :558，node :668） | discovery/kubernetes/kubernetes.go:389-690 |
| `send`（单 Group 发送原语） | discovery/kubernetes/kubernetes.go:696-704 |
| pod 索引 informer 构建（node/RS/job/namespace 索引） | discovery/kubernetes/kubernetes.go:777-822 |
| informer 工厂 + watch 错误指标 | discovery/kubernetes/kubernetes.go:942-965 |
| 通用标签函数（label/annotation 双标签） | discovery/kubernetes/kubernetes.go:967-983 |
| Pod 事件 handler（Add/Del/Update 入队） | discovery/kubernetes/pod.go:89-102 |
| pod process（删除发空 Group :239） | discovery/kubernetes/pod.go:222-249 |
| WaitForCacheSync（pod 多 informer） | discovery/kubernetes/pod.go:192-211 |
| `podLabels`（pod 标签映射面 + owner 链回溯） | discovery/kubernetes/pod.go:292-346 |
| `buildPod`（端口展开目标工厂） | discovery/kubernetes/pod.go:366-440 |
| node 反查入队 `enqueuePodsForNode` | discovery/kubernetes/pod.go:466-476 |
| `buildNode` / kubelet 端口拼接 | discovery/kubernetes/node.go:186-211 |
| `nodeAddress` 地址优先级 | discovery/kubernetes/node.go:222-247 |
| endpointslice service 反查（ByIndex） | discovery/kubernetes/endpointslice.go:115-131 |
| `buildEndpointSlice`（endpoints×ports×addresses 展开） | discovery/kubernetes/endpointslice.go:308-503 |
| dual-stack 次 IP 族跳过 | discovery/kubernetes/endpointslice.go:525-546 |
| SD manager 按 Source 整组替换/删除 | discovery/manager.go:468-488 |
