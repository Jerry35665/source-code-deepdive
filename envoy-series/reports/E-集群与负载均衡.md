# E. 集群与负载均衡：从 EDS 到 host 选择的完整链路

> 基线：tag v1.39.1，commit b579d07d3ad7ee11d32b105e91a5a39ad24718d7。所有行号均以该检出为准。
> 本报告接棒报告 D：D 止于 router 侧 `createConnPool`/`conn_pool_->newStream`；本章从 cluster/host 侧展开——ClusterManager 与 thread-local 视图、PrioritySet 数据结构、EDS 应用、LB 家族、健康检查（主动+被动）、连接池本体。
> v1.39 的代码布局提示：LB 实现已插件化到 `source/extensions/load_balancing_policies/`，健康检查器移到 `source/extensions/health_checkers/`，集群类型在 `source/extensions/clusters/`；`source/common/upstream/` 保留管理面（cluster manager、PrioritySet、outlier、连接池映射）。

## 0. 全景图：ClusterManager 到 HealthyHost 的层级

```
                          CDS / 静态 bootstrap
                                 │ addOrUpdateCluster (cluster_manager_impl.cc:727)
                                 ▼
   ClusterManagerImpl (main thread, cluster_manager_impl.h:232)
    ├── active_clusters_ / warming_clusters_ (h:837 ClusterMap)
    │      ClusterData { cluster_, thread_aware_lb_ }  (h:782-826)
    │      loadCluster(): typed_lb_factory.create()     (cluster_manager_impl.cc:947-953)
    │
    │   postThreadLocalClusterUpdate ── tls_.runOnAllThreads (cc:1177, 1211)
    ▼
   ThreadLocalClusterManagerImpl（每 worker 一份, h:538）
    ├── thread_local_clusters_: name → ClusterEntry (h:757)
    │      ClusterEntry { priority_set_(TLS), lb_factory_, lb_ } (h:600-692)
    │      构造即 lb_ = lb_factory_->create({priority_set_, local_priority_set_}) (cc:1910-1921)
    │
    ├── host_http_conn_pool_map_: Host → ConnPoolsContainer (h:765)   ★连接池挂在 host 上
    │      ConnPools = PriorityConnPoolMap<hash_key, Http::ConnectionPool::Instance> (h:545)
    │
    ▼  ClusterEntry::chooseHost (cc:2131) → lb_->chooseHost
   PrioritySet（主线程 MainPrioritySetImpl, upstream_impl.h:811；TLS 侧 PrioritySetImpl, h:714）
    └── host_sets_: vector<HostSet>，下标即 priority 0..N (h:766)
           HostSetImpl（upstream_impl.h:609）
            ├── hosts_ / healthy_hosts_ / degraded_hosts_ / excluded_hosts_ (h:694-697)
            ├── hosts_per_locality_ / healthy_hosts_per_locality_（locality 维度, h:698-701）
            └── locality_weights_ + overprovisioning_factor (h:706, h:692)
                 │
                 ▼  choosePriority：healthy→degraded 两轮按百分比选 priority（load_balancer_impl.cc:68-96）
                 │  hostSourceToUse：panic / locality 加权 / zone 路由选 host source（load_balancer_impl.cc:837-930）
                 ▼
           LB 算法（Edf RR / LeastRequest / Random / RingHash / Maglev / Subset…）
                 │
                 ▼
           HostConstSharedPtr（healthy host）→ host 上取连接池 httpConnPool（cc:1029-1049）
                 │  newStream → 排队/复用/建连（conn_pool_base.cc:327）
                 ▼
           ready_clients_ 上的 ActiveClient → onPoolReady → RequestEncoder（http/conn_pool_base.cc:84-105）
```

## 1. ClusterManager：cluster 生命周期与 thread-local 视图

### 1.1 初始化：primary 先行，secondary 后动

`ClusterManagerInitHelper` 用一个显式状态机编排初始化顺序（cluster_manager_impl.h:142-164）：`Loading → WaitingForPrimaryInitializationToComplete → WaitingToStartSecondaryInitialization → WaitingToStartCdsInitialization → AllClustersInitialized`。primary（STATIC/STRICT_DNS/原始 DNS 等自足型集群）先初始化，secondary（典型是 EDS）随后；注释直言"dealing with primary clusters, secondary clusters, and CDS is quite complicated"，所以单独抽出这个 helper（h:127-130）。

### 1.2 增量更新与 warming

`addOrUpdateCluster`（cluster_manager_impl.cc:727-800）先算配置 hash：与 active/warming 中的同名配置相同则阻塞（NOP 更新，:737-750）；不同则把新 cluster 实例放进 `warming_clusters_` 并调用 `initialize()`（:790-796）。EDS/DNS 就绪后回调 `onClusterInit`，其中 `clusterWarmingToActive` 把条目从 warming 挪进 active（:802-812, :550-563）。warming 期间**新旧集群共存**：路由仍引用旧 active 集群，新集群在自己的 PrioritySet 上独立预热，直到首份 endpoint/健康检查完成。warming 未清空时 CDS 的 ACK 被暂停（`resume_cds_`，:959-980），避免 ADS 把依赖它的 RDS 先推下来。

### 1.3 为什么每个 worker 有独立 LB/HostSet 视图

主线程集群的 PrioritySet 是只读共享数据；worker 若直接读它需要锁或引用计数风暴。Envoy 的做法是**广播副本**：`postThreadLocalClusterUpdate` 把每个 priority 的 `update_hosts_params`、locality weights、`crossPriorityHostMap` 打包后 `tls_.runOnAllThreads`（cluster_manager_impl.cc:1177-1296），worker 侧 `ClusterEntry::updateHosts` 写入自己的 TLS `PrioritySetImpl`（:1512-1536，成员 h:662）。每个 ClusterEntry 构造时就地创建 per-thread LB：`lb_ = lb_factory_->create({priority_set_, parent_.local_priority_set_})`（:1910-1921），即 LB 的轮转指针、EDF 堆、zone 路由状态全部线程私有，选择路径零锁。对 thread-aware 型 LB（hash 类），主线程只重建共享的 per-priority 状态，worker LB 在 member update 时换指针（thread_aware_lb_impl.cc:152-185, 239-246）。

更新广播有三条细则值得注意：

1. **host 移除即时广播**，且要广播完整 `hosts_removed` 列表——worker 用这些 `HostSharedPtr` 作 map key，漏一条就泄漏（cc:601-612 注释引用 PR#3941）；
2. **纯健康/权重/元数据变更可合并**：`is_mergeable = hosts_added.empty() && hosts_removed.empty()`（:617），进入 `update_merge_window`（默认 1000ms，:614-615）由 `scheduleUpdate` 定时器合并后统一投递（:651-707, :709-724）；
3. 主动健康检查/outlier 判死会额外 `postThreadLocalHealthFailure`，触发对端连接池 drain 或关闭（:910-929, :1458-1462, :1855-1887）。

### 1.4 chooseHost 的入口

报告 D 的 `cluster->chooseHost(this)` 最终落在 `ClusterEntry::chooseHost`（cluster_manager_impl.cc:2131-2163）：先查 override host（`HostUtility::selectOverrideHost`，:2133-2138），否则 `lb_->chooseHost(context)`；返回空则 `upstream_cx_none_healthy_` 计数并打 "no healthy host" 日志（:2141-2152）。

## 2. Cluster 数据结构与三种基本实现

### 2.1 Host/PrioritySet/HostSet 三层

- **Host**：`HostDescriptionImplBase` 承载 hostname、address、locality、metadata（含 hash）、priority、健康监视器等（upstream_impl.h:161-265）；`HostImplBase` 增加 `health_flags_` 原子位与 EDS 健康状态（h:509-518），`coarseHealth()` 按 FAILED_ACTIVE_HC/FAILED_OUTLIER_CHECK/FAILED_EDS_HEALTH 等位归为 Unhealthy/Degraded/Healthy 三态（h:444-463）。`HealthFlag` 位定义在 envoy/upstream/upstream.h:154-182（含 `PENDING_DYNAMIC_REMOVAL`）。
- **HostSetImpl**：一个 priority 的全部视图，持有 hosts/healthy/degraded/excluded 四个向量及按 locality 分桶的 `HostsPerLocality`（h:694-706），`updateHosts()` 原子换指针后跑回调（cc:899-937 附近的 `getOrCreateHostSet`/`updateHosts`）。`partitionHosts`（h:675-677, cc:884+）把全量 host 列表按 `coarseHealth` 一次性切成 healthy/degraded/excluded 三桶及对应 per-locality 结构，是健康位变化后重建视图的统一切分器。
- **PrioritySetImpl**：`host_sets_` 向量按下标即优先级扩展、只增不减（h:763-766）；`batchHostUpdate` 用 `BatchUpdateScope` 聚合一次 EDS 推送的所有 priority 变更，最后算出净增删并只跑一次回调（cc:939-950）。`MainPrioritySetImpl` 额外维护跨 priority 的 host 地址→host 只读映射 `cross_priority_host_map_`（h:808-827, cc:973-996）。

### 2.2 静态、DNS 与 EDS

`StaticClusterImpl::startPreInit`（extensions/clusters/static/static_cluster.cc:59-79）把静态 endpoints 逐 priority 写入 PriorityStateManager；若配了主动健康检查，写入时给每个 host 打上 `FAILED_ACTIVE_HC`（health_checker_flag，:62-65），等首轮探测通过再翻绿——**"配置即健康"被显式否定**。`PriorityStateManager::updateClusterPrioritySet` 负责按 locality 稳定排序（`std::map` + `LocalityLess`，注释明说 "stable ordering for zone aware routing"，upstream_impl.cc:2291-2330）。STRICT_DNS 在每次解析回调里构造新 Host 列表并复用 `updateDynamicHostList` 做 diff（strict_dns_cluster.cc:150-190 片段），TTL 反算刷新率。

EDS 路径：`EdsClusterImpl::onConfigUpdate`（eds.cc:198-268）校验 `ClusterLoadAssignment` 后进 `update()`（:270-331），以 `priority_set_.batchHostUpdate(helper)`（:330）一次性落盘；`BatchUpdateHelper` 遍历 priority，对每个 locality 调 `updateHostsPerLocality`（:110-149），后者核心就是复用 `updateDynamicHostList`（:432）。EDS 还支持 LEDS 子订阅与 `endpoint_stale_after` 过期（:243-253, :304-321）。

### 2.3 host 复用与健康状态迁移（warming 期的真正含义）

`updateDynamicHostList`（upstream_impl.cc:2366-2509）按 **address 字符串** 匹配新旧 host：

- 命中且无需就地更新（健康检查地址、locality、hostname、active-HC 开关均未变，:2420-2443）→ **保留原 Host 对象**，就地更新权重/metadata/canary/priority（:2452-2489）；
- 命中但 `skip_inplace_host_update` → 重建 Host 对象；
- 清除 `PENDING_DYNAMIC_REMOVAL`：被标记删除但主动健康检查仍通过的 host，若出现在新配置里则撤销删除标记（:2410-2414）；
- 新建 host 若集群有健康检查器则沿用"健康检查地址未变"的旧 host 的主动健康状态（:2496-2509），而非从 unhealthy 重新起算。

这正是"host 复用迁移"的落点：**地址不变 ⇒ 对象不变 ⇒ 在途连接、健康状态、统计连续**。集群侧 `reloadHealthyHostsHelper`（cc:1963-1988 调用 :1976-1988）则在主动 HC/outlier 状态翻转时对全 priority 做 `partitionHosts` 重建 healthy/degraded 向量——EDS 版本还有特例：健康检查恰好通过、又被 EDS 标记删除的 host 会被趁机移除（eds.cc:369-407）。

## 3. priority/locality 两级选择与 panic 模式

### 3.1 priority spill（本地直连优先级溢出）

`LoadBalancerBase::recalculatePerPriorityState` + `distributeLoad`（load_balancer_impl.cc:38-64, 208-213）把 100 份流量按各 priority 的"可用度 = (healthy+degraded)/total ×100 ×overprovisioning(默认 1.4)"自上而下分配：P0 可用度够就全吃 P0，不够则**溢出**到 P1、P2……总量上限 100（`calculateNormalizedTotalAvailability`，cc:226-235）。选择时 `choosePriority` 用 `hash%100+1` 先按 healthy 负载、再按 degraded 负载两轮扫描定位（cc:68-96）。

### 3.2 panic：低于阈值全视作健康

```cpp
// source/extensions/load_balancing_policies/common/load_balancer_impl.cc:677
bool LoadBalancerBase::isHostSetInPanic(const HostSet& host_set) const {
  uint64_t global_panic_threshold = std::min<uint64_t>(
      100, runtime_.snapshot().getInteger(RuntimePanicThreshold, default_healthy_panic_percent_));
  const auto host_count = host_set.hosts().size() - host_set.excludedHosts().size();
  double healthy_percent = ...;
  double degraded_percent = ...;
  // If the % of healthy hosts in the cluster is less than our panic threshold, we use all hosts.
  if ((healthy_percent + degraded_percent) < global_panic_threshold) {
    return true;
  }
  return false;
}
```

阈值默认 50（round_robin/config.cc:21-22 的 `PROTOBUF_PERCENT_TO_ROUNDED_INTEGER_OR_DEFAULT(..., healthy_panic_threshold, 100, 50)`），可被运行时键 `upstream.healthy_panic_threshold` 覆盖（RuntimePanicThreshold，cc:31）。每个 priority 独立判 panic（cc:292-329）；若全部 priority 都 panic，进入 TotalPanic：按**总 host 数**（不分健康）重分流量（`recalculateLoadInTotalPanic`，cc:335-376）。panic 生效时 `hostSourceToUse` 直接改用 `AllHosts`，除非配了 `fail_traffic_on_panic` 宁可拒绝也不打不健康后端（cc:849-857）。

### 3.3 locality：zone aware 与 locality weighted

locality 维度全部在 `ZoneAwareLoadBalancerBase`（load_balancer_impl.h:262-495）：

- `regenerateLocalityRoutingStructures` 只对 P=0 计算（cc:513-611）：本 locality 占比 ≥ 上游同 locality 占比则 `LocalityDirect`（全部直连），否则 `LocalityResidual`——按 `local_percent_to_route_` 采样直连，残余流量按各 locality 的 `residual_capacity_` 比例外溢（`tryChooseLocalLocalityHosts`，cc:782-835）；
- `earlyExitNonLocalityRouting`（cc:621-656）：locality 少于 2、集群小于 `min_cluster_size`、local cluster 无本 locality host 等情形直接关闭 zone 路由；
- `locality_weighted_balancing_`（对应 locality_weighted_lb_config）则改走 `LocalityWrr`（EDF 调度器按 locality 权重出 locality，locality_wrr.cc:62-71），入口在 `hostSourceToUse` 的 `chooseHealthyLocality/chooseDegradedLocality`（cc:866-883, h:446-454）。

## 4. LB 家族：一次选择的多层组合

所有 LB 的公共底座是 `LoadBalancerBase`（priority/panic/健康负载，h:135-257）→ `ZoneAwareLoadBalancerBase`（host source 选择，h:262-495）。其上分两支：

**EDF 支（per-thread LB）**：`EdfLoadBalancerBase` 为每个 `HostsSource` 维护一个 EDF 调度器，deadline=当前时间+1/weight（edf_scheduler.h:60-63），实现 O(log n) 加权轮转；无权重差时退化为普通索引轮转（h:529-535, 497-509 注释）。

```cpp
// source/common/upstream/edf_scheduler.h:60
const double deadline = current_time_ + 1.0 / weight;
queue_.push({deadline, order_offset_++, entry});
ASSERT(queue_.top().deadline_ >= current_time_);
```

`EdfLoadBalancerBase::chooseHostOnce`（load_balancer_impl.cc:1145-1180）先 `hostSourceToUse` 定 source，再从 `scheduler_` 表取出该 source 的 EDF（无 EDF 则走 `unweightedHostPick`），slow start 用 `applySlowStartFactor` 折减新 host 权重（:1182+，h:541-553，round_robin_lb.h:53-58）。

- **RoundRobin**：`RoundRobinLoadBalancer` 继承 EDF 基类，无非加权时 `rr_indexes_[source]++ % size`（round_robin_lb.h:44-79）；带 slow start 权重折减（h:53-58）。
- **LeastRequest**：`hostWeight = weight / (active_requests+1)^active_request_bias`（least_request_lb.cc:14-54）；无权重模式下按 `selection_method_` 走 FULL_SCAN（全扫+蓄水池采样打破平局，:82-124）或 **N_CHOICES（power-of-two choices）**——随机抽 `choice_count_` 个 host 取 active 最少者（:126-148）。preconnect 无法确定性 peek（:56-62）。
- **Random**：`hosts_to_use[random_hash % size]`（random_lb.cc:17-30）。

**Thread-aware 支（hash 类）**：`ThreadAwareLoadBalancerBase` 主线程 `refresh()` 归一化 host/locality 权重后构建不可变 per-priority 状态，writer 锁写 factory（thread_aware_lb_impl.cc:152-185）；worker 侧 `LoadBalancerImpl` 读锁换指针（:239-246），选择时先取 hash（LB 配置的 hash_policy 或 context 的 hash，cookie 生成含 Set-Cookie 注入，:92-119, :199-215），`choosePriority` 定 priority，命中 panic 则 `lb_healthy_panic_` 计数（:217-223）。

- **RingHash**：ketama 风格二分查环（ring_hash_lb.cc:78-125），建环按权重比例生成 hash 点、`max_ring_size` 缩放（:128-223）；`use_hostname_for_hashing` 可切 hash 键（:58-61）。
- **Maglev**：查表 O(1)。三档实现 Degenerate/Compact/Original 按规模选择（maglev_lb.cc:39-61），Original 用经典 double permutation 填表（:160-199）；同属此支的 bounded-load 变体在 hash host 过载时以 hash 为种子随机跳跃换 host（thread_aware_lb_impl.cc:287-380，论文 arXiv:1608.01350/1908.08762）。
- **Subset LB**：`SubsetLoadBalancer::chooseHost` 先按 `metadata_fallback_policy` 逐级降级（subset_lb.cc:184-216），`chooseHostIteration` 用 route metadata 的 match criteria 在子集字典树里挑子集（:251-283），未命中走 selector fallback，再退 `fallback_subset_`，最后 `panic_mode_subset_`（全部 host 的兜底子集，:289-303）。子集按 `lb_subset_config` 的 selectors 在 host 增删时增量维护（构造 :59-146）。它包裹任意内层 LB——即"先选桶、再选 host"。

**LB 工厂选择**：cluster 配置的 `load_balancing_policy`（typed extension）在 `ClusterInfoImpl::configureLbPolicies` 解析出 `TypedLoadBalancerFactory`（upstream_impl.cc:1479-1530），旧 `lb_policy` 字段经各 config.cc 的 legacy 构造转换；`envoy.load_balancing_policies.cluster_provided` 表示集群自带 LB（cluster_manager_impl.cc:891-908 校验）。

## 5. 健康检查：主动探测与被动 outlier

### 5.1 主动：HealthCheckerImplBase 状态机

一个 cluster 配一个 health checker，cluster 初始化完成后经 `setHealthChecker` 注入（upstream_impl.cc:1936-1951）。每个 host 一个 `ActiveHealthCheckSession`，持有 interval/timeout 两个计时器（health_checker_base_impl.cc:252-266）。核心状态机：

- **阈值翻转**：成功需连续 `healthy_threshold_` 次才清 `FAILED_ACTIVE_HC`（首个结果立即翻绿，:295-322）；失败需连续 `unhealthy_threshold_` 次才置位，网络类失败（NETWORK/NETWORK_TIMEOUT）则**立即计一次**即走阈值流程（`setUnhealthy`，:369-417）。
- **interval 派生**：`interval(state, changed_state)` 按 host 健康与"边缘状态"选 `interval/unhealthy_interval/healthy_edge_interval/unhealthy_edge_interval`，从未有流量的 cluster 用更慢的 `no_traffic_interval`（默认 60s，构造 :28-40，逻辑 :101-138）；再加 jitter 与 runtime 上下限（:140-160）。
- **集群成员跟随**：checker 订阅 `MemberUpdateCb`，host 增删自动建/删 session（:43-46, :162-199）；被移除 session 延迟删除（:188-198）。

HTTP 检查器复用完整的 upstream HTTP 栈：`onInterval` 建 `CodecClient`、`newStream` 发 `path_/method_` 请求、可带 payload（health_checker_impl.cc:270-321），响应码区间校验 + 期望 body 匹配 + `x-envoy-immediate-health-check-fail` 头可立刻排除 host（:363-391）；收到 GOAWAY 优雅处理在途请求（:339-361）。TCP 检查器则是"发 send 字节、收 receive 字节做 payload 匹配"的最小协议（tcp/health_checker_impl.cc:64-66, 85-87, 132+）。

### 5.2 被动：outlier detection

outlier 是**纯被动**的：它订阅真实请求结果，不做探测。`DetectorImpl` 按配置持有 `consecutive_5xx`（默认 5）、`consecutive_gateway_failure`、`base/max_ejection_time`、`max_ejection_percent`（默认 10）、success rate 三件套（request_volume/stdev_factor/minimum_hosts）等（outlier_detection_impl.cc:243-292）。两类触发：

1. **连续错误逐出**：请求计费路径里 `++consecutive_5xx_ == runtime(Consecutive5xxRuntime)` 即 eject（:88-104）；`chargeError` 最终调 `ejectHost`（:717）。
2. **周期成功率逐出**：`interval` 定时器 `onIntervalTimer` 先做到期 uneject/undegrade，再跑 `processSuccessRateEjections`（:877-893）：对请求量达标（`success_rate_request_volume`）且 host 数达标的集合算 均值-标准差×因子 得逐出阈值，低于者逐出（:776-853）；另有失败百分比阈值路径（:855-874）。

`ejectHost` 强制 `ejected_percent <= max_ejection_percent`（默认 10%，永远最多踢 10% 的 host；`always_eject_one_host` 可保底踢一个），并按 `base_ejection_time` 的指数退避+抖动设置回归时间（outlier_detection_impl.cc:542+）。eject 即置 `FAILED_OUTLIER_CHECK` 位，与主动 HC 走同一健康位体系（upstream.h:156），并经 `addChangedStateCb` 触发集群 `reloadHealthyHosts`（upstream_impl.cc:1953-1961）与 TLS 侧连接池 drain（cluster_manager_impl.cc:920-929）。它与主动 HC 的区别：主动 HC 主动发探测、能在无流量时维护视图（no_traffic_interval），outlier 只在流量反馈后动作、且被"最多踢 N%"与 enforcing 比例双重限幅——**被动判据是真实流量，主动判据是合成探针，二者互补而非冗余**。

## 6. 连接池：per-host、per-thread、per-hash-key

### 6.1 挂载点与键

连接池不在 cluster 上，而在**每 worker 的 `host_http_conn_pool_map_`**（cluster_manager_impl.h:765），host 句柄由 `ConnPoolsContainer` 的 `host_handle_`（acquireHandle 计数，h:540-555）保活。池的二次键是一个 `hash_key` 字节向量：upstream protocol（HTTP/1 vs /2 vs /3 的 ALPN 池区分，cc:2038-2043）、socket options（:2057-2062）、transport socket options（SNI/ALPN，:2064-2068）、乃至每下游连接一池（`connection_pool_per_downstream_connection`，:2070-2074）。`PriorityConnPoolMap` 再按 ResourcePriority（Default/High）分桶（priority_conn_pool_map_impl.h:13-31, 85-86）。工厂 `allocateConnPool` 由 `factory_.allocateConnPool`（cc:2080-2088）按协议分发到 HTTP/1、HTTP/2、HTTP/3 或 mixed/grid 实现。

### 6.2 newStream：复用、排队与建连

```cpp
// source/common/conn_pool/conn_pool_base.cc:327
ConnectionPool::Cancellable* ConnPoolImplBase::newStreamImpl(AttachContext& context,
                                                             bool can_send_early_data) {
  if (!ready_clients_.empty()) {
    ActiveClient& client = *ready_clients_.front();
    attachStreamToClient(client, context);
    // Even if there's a ready client, we may want to preconnect to handle the next incoming stream.
    tryCreateNewConnections();
    return nullptr;
  }
  ...
  if (!host_->cluster().resourceManager(priority_).pendingRequests().canCreate()) {
    // max pending streams overflow → onPoolFailure(Overflow)
  }
  ConnectionPool::Cancellable* pending = newPendingStream(context, can_send_early_data);
  const ConnectionResult result = tryCreateNewConnections();
  ...
  return pending;
}
```

取不到 ready client 即进入 `pending_streams_` 排队并尝试建连；`attachStreamToClient` 检查 cluster 的 requests 断路器（`max streams overflow`，:242-251），流数耗尽把 client 转 Draining，容量到 1 转 Busy（:255-264）。连接就绪/失败后 `onUpstreamReady` 把 pending 队列接到新 client（:402-406）。router 侧 `onPoolFailure/onPoolReady` 的语义见报告 D §6。

### 6.3 preconnect 与连接数计算

建连判定是一个统一公式（conn_pool_base.cc:94-114）：

```cpp
return (pending_streams + active_streams + anticipated_streams) * preconnect_ratio >
       connecting_and_connected_capacity + active_streams;
```

`preconnect_ratio` 来自 cluster 的 `per_upstream_preconnect_ratio`（默认 1，即经典的 pending > 容量才建连）；全局预连接（`peekahead_ratio` > 1 时）由 `ClusterManagerImpl::maybePreconnect` 在 newStream 前驱动，最多预选 3 个池、每次先 LB `peekAnotherHost` 再 `maybePreconnect`（cluster_manager_impl.cc:996-1026, 1038-1048）。降级 host 只按需求建连不做预取（conn_pool_base.cc:121-123）。单轮 `tryCreateNewConnections` 上限 3 条（:166-183）。

**断路器打满时的保底建连**（旧版所谓 BusyCreate 语义，v1.39 中没有该符号）：`tryCreateNewConnection` 里若 `can_create_connection` 为假（connection 断路器满），但本池四类 client 全空，仍强制建一条——防止 pending 流被排到一个永远无法服务的 host 上（:205-209）。per-host 连接上限 `maxConnectionsPerHost` 在 host 层把关（resource_manager_impl.h:119, upstream_impl.h:208-213）。

### 6.4 HTTP/1、HTTP/2、HTTP/3 三种复用形态

- **HTTP/1**：`ActiveClient` 以 `effective_concurrent_stream_limit = 1` 构造（http1/conn_pool.cc:82-88）——连接池退化成"固定连接排队"：一条连接同一时刻只服务一个流，流结束由 `StreamWrapper` 析构触发 `onStreamClosed` 重新调度 pending（:40-45）；响应 `Connection: close` 或对端半关即关闭连接（:49-76）。
- **HTTP/2**：`MultiplexedActiveClientBase` 容量 = `max_concurrent_streams` 配置、server settings 实测值、`max_requests_per_connection` 三者最小（http2/conn_pool.cc:17-39）；收到 SETTINGS/GOAWAY 动态增减 cluster 级流容量并在 Busy/Ready 间迁移（http/conn_pool_base.cc:111-157）。连接是多路复用的，"排队"只发生在容量耗尽时。
- **HTTP/3**：`http3/conn_pool.cc` 的 ActiveClient 继承同一 `MultiplexedActiveClientBase`（:30-43），QUIC 复用 TCP 池逻辑；上层 `ConnectivityGrid` 把 HTTP/3 与 HTTP/2 池组成网格做 ALPN 竞速与 happy-eyeballs：首选池失败/超时自动 failover 到备用池（conn_pool_grid.h:18-31, 104-146）。

TCP 协议（如 TCP proxy）不经过 HTTP 池，走 `Tcp::ConnectionPool`（source/common/tcp/conn_pool.cc）与 cluster manager 侧独立的 `host_tcp_conn_pool_map_`/`host_tcp_conn_map_`（cluster_manager_impl.h:766-767）；`tcpConn()` 还支持非池化裸连接并挂 `CLOSE_CONNECTIONS_ON_HOST_HEALTH_FAILURE` 联动（cluster_manager_impl.cc:1464-1491）。

## 7. 设计动机

1. **per-thread cluster 视图**：LB 选择是数据面最热路径，任何锁都会被 N 个 worker 放大；Envoy 用"主线程权威副本 + 全量广播 + worker 本地重建"换来零锁选择。代价是广播顺序约束（host 移除必须全量广播，cluster_manager_impl.cc:601-612）与 thread-aware LB 的双段式刷新（thread_aware_lb_impl.cc:152-185）。主动健康检查判死、outlier 判死都还要再 post 一次 TLS 清理（:910-929），因为健康位是跨线程原子的，但连接池是线程私有的。
2. **priority + locality 两层结构**：region/zone 故障是多速率的——主机抖动是秒级，AZ 故障是分钟级。priority 把"故障域切换"编码为 spills（健康度不够就溢出到下一层），locality 把"正常态的流量摆放"编码为 zone 路由/加权；两层正交：`regenerateLocalityRoutingStructures` 的注释明说"fairness across localities within a priority is guaranteed; across priorities is not"（load_balancer_impl.cc:533-541）。
3. **panic 模式（50% 阈值）**：健康过滤的本意是别把流量打向坏后端，但当绝大多数后端"看起来坏"时，更可能是探测/网络分区误报——此时全部打向 0 容量的 P0 比打散到全集群更糟。panic 用"低于阈值则视全体为健康"把可用性从 0 拉回非零，且提供 `healthy_panic_threshold: 0` + `fail_traffic_on_panic` 两个开关让用户在"脏转发"与"干净拒绝"间选择（load_balancer_impl.cc:292-329, 849-857）。
4. **outlier 被动而非主动**：主动探测只覆盖"探测路径"，不能反映应用层真实成功率，且大规模下探测流量本身是负担；被动逐出以真实请求为信号（consecutive 5xx / 成功率标准差），用 max_ejection_percent 与指数退避抑制误杀风暴，与主动 HC（覆盖无流量 host、探测端口连通性）互补。二者都收敛到同一个 `health_flags_` 位与同一套 healthy/degraded 分区逻辑（upstream_impl.h:444-463），LB 与连接池无需感知来源。
5. **连接池 per-host（而非 per-cluster）**：TCP/TLS 握手成本、流上限、连接生命周期都是**每条物理连接**的属性，而物理连接必绑定一个 (host, protocol, options) 四元组；把它挂在每 worker 的 host map 上，删除语义天然清晰（host 移除 → drain 该 host 的池，cluster_manager_impl.cc:1538-1543），hash 键则保证不同 socket options/SNI 的连接不串池（:2057-2068）。
6. **host 复用与健康状态迁移**：EDS 推送频率远高于拓扑真实变化；若每次推送都重建 Host 对象，在途连接、健康检查计数、per-host 统计全部作废。按地址匹配复用对象（upstream_impl.cc:2404-2489）使"配置更新"与"数据面身份"解耦：只有地址、健康检查地址、locality、hostname 真变时才换对象，其余更新就地生效——这是 EDS 能以秒级频率推送的工程前提。
7. **统一建连公式**：HTTP/1 的"排队等固定连接"与 HTTP/2 的"容量内即取"被同一个 `shouldConnect` 公式描述（conn_pool_base.cc:94-114），差异只在 `currentUnusedCapacity()` 的定义（HTTP/1 恒 1、HTTP/2/3 为并发流上限）。协议差异沉入 client 容量语义后，preconnect、断路器、排队逻辑对所有协议只需写一遍。

## 8. 写作素材清单（文件：行号）

1. source/common/upstream/cluster_manager_impl.cc:727-800 — addOrUpdateCluster：hash 去重、warming 插入与初始化分流
2. source/common/upstream/cluster_manager_impl.cc:550-649 — onClusterInit：warming→active、注册 member/priority 更新回调、首广播
3. source/common/upstream/cluster_manager_impl.cc:601-631, 651-724 — 更新合并窗口（只合并纯健康/权重/元数据变更）
4. source/common/upstream/cluster_manager_impl.cc:1177-1296 — postThreadLocalClusterUpdate：TLS 广播与 deferred cluster
5. source/common/upstream/cluster_manager_impl.cc:867-957 — loadCluster：typed LB factory 创建、HC/outlier 判死回调
6. source/common/upstream/cluster_manager_impl.cc:1910-1921 — ClusterEntry 构造：per-thread `lb_factory_->create`
7. source/common/upstream/cluster_manager_impl.cc:2131-2163 — ClusterEntry::chooseHost：override host → lb → none_healthy
8. source/common/upstream/cluster_manager_impl.cc:996-1026, 1029-1049 — maybePreconnect 与 httpConnPool 的 peekahead
9. source/common/upstream/cluster_manager_impl.cc:2035-2101 — 连接池 hash_key（协议/socket options/每下游连接）与池工厂
10. source/common/upstream/upstream_impl.cc:2366-2509 — updateDynamicHostList：地址匹配、就地更新、PENDING_DYNAMIC_REMOVAL
11. source/common/upstream/upstream_impl.cc:1936-1988 — setHealthChecker/setOutlierDetector/reloadHealthyHosts
12. source/common/upstream/upstream_impl.cc:916-996 — PrioritySetImpl::updateHosts/batchHostUpdate/MainPrioritySet
13. source/extensions/clusters/eds/eds.cc:198-331, 410-450 — EDS onConfigUpdate→batchHostUpdate→updateHostsPerLocality
14. source/extensions/load_balancing_policies/common/load_balancer_impl.cc:68-96, 292-376, 677-692 — choosePriority/panic 判定/TotalPanic
15. source/extensions/load_balancing_policies/common/load_balancer_impl.cc:513-656, 782-930 — zone 路由结构重建与 hostSourceToUse
16. source/extensions/load_balancing_policies/least_request/least_request_lb.cc:14-148 — 动态权重与 FULL_SCAN/N_CHOICES
17. source/extensions/load_balancing_policies/ring_hash/ring_hash_lb.cc:78-125 — ketama 二分选 host（对应 maglev_lb.cc:160-199 填表）
18. source/extensions/load_balancing_policies/subset/subset_lb.cc:184-303 — subset 选择与 fallback/panic 子集
19. source/extensions/health_checkers/common/health_checker_base_impl.cc:101-160, 295-417, 449-467 — interval 派生、阈值翻转、计时器循环
20. source/common/upstream/outlier_detection_impl.cc:776-910, 542+ — 成功率逐出、interval 定时器、ejectHost 限幅与退避
21. source/common/conn_pool/conn_pool_base.cc:94-231, 327-391 — shouldConnect 公式、断路器保底建连、newStreamImpl 排队
22. source/common/http/http1/conn_pool.cc:40-88 vs source/common/http/http2/conn_pool.cc:17-51 — 固定连接 vs 多路复用容量

（引用协议：`文件:行号` 均为 v1.39.1 检出实测行号；行号以 Read/Grep 实际核对为准。）
