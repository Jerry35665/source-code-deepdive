# B《配置体系与 xDS:动态控制面的实现》

> 基线:tag v1.39.1(commit b579d07d3ad7ee11d32b105e91a5a39ad24718d7)。所有 `文件:行号` 均经 Read/Grep 逐条核对。
> 核心目录:`source/common/config/`(配置基础设施)、`source/extensions/config_subscription/`(四种订阅 delivery)、`source/common/upstream/` 与 `source/common/listener_manager/`(资源落地)、`source/server/`(bootstrap 装配与 admin)。

## 0. 全景图:配置如何流进 Envoy

```
                        envoy::config::bootstrap::v3::Bootstrap (-c 配置文件)
                                     │  MainImpl::initialize()
                                     │  (source/server/configuration_impl.cc:112)
        ┌────────────────────────────┼──────────────────────────────────────┐
        │ static_resources           │ dynamic_resources                    │
        │  ├ secrets ─────────► SecretManager.addStaticSecret            │
        │  ├ clusters ────────► ClusterManager(静态,Primary/Secondary)  │
        │  └ listeners ───────► ListenerManager.addOrUpdateListener      │
        └────────────────────────────┼──────────────────────────────────────┘
                                     │
   各订阅方(CDS/LDS/RDS/EDS/SRDS/SDS/VHDS…)按各自 ConfigSource
   经 SubscriptionFactoryImpl::subscriptionFromConfigSource() 选择 delivery
   (source/common/config/subscription_factory_impl.cc:52-105):
                                     │
   path ──► FilesystemSubscriptionImpl(inotify)    REST ──► HttpSubscriptionImpl(轮询)
   gRPC ──► GrpcSubscriptionImpl(单资源类型独立流) ADS ──► 复用 ClusterManager 上的全局 mux
                                     │                          │
                        ┌────────────┴───────────┐              │
                        │ XdsManagerImpl::       │◄─────────────┘
                        │ initializeAdsConnections
                        │ (xds_manager_impl.cc:171)
                        └────────────┬───────────┘
             ┌───────────────────────┼─────────────────────────────┐
             │ ads_config 有 ads_config,DELTA_GRPC vs GRPC         │ 无 ads_config
             ▼                                                      ▼
   unified_mux=false(默认):                          NullGrpcMuxImpl 占位
     SotW ADS → GrpcMuxImpl(grpc_mux_impl.cc)         (xds_manager_impl.cc:280)
     Delta ADS → NewGrpcMuxImpl(new_grpc_mux_impl.cc)
   unified_mux=true(opt-in):
     XdsMux::GrpcMuxSotw / GrpcMuxDelta(xds_mux/grpc_mux_impl.cc,模板统一)
             └───────────────────────┬─────────────────────────────┘
                                     │ onDiscoveryResponse:按 type_url 路由
                                     ▼
              SubscriptionCallbacks.onConfigUpdate() → Manager 应用
              CDS→ClusterManager(warming)   LDS→ListenerManager(warming)
              EDS→EdsCluster(主机表)        RDS/SRDS→ConfigProvider(HCM 路由)
```

初始化时序(server.cc 自述注释):先加载 bootstrap 与 primary 集群,再用 primary 集群建 RTDS/ADS 连接,然后初始化 secondary 集群(EDS 等),最后下发其余动态配置(source/server/server.cc:757-770)。

## 1. 配置层次:Bootstrap → 静态 + 动态汇入同一套 Manager

`MainImpl::initialize()` 是静态资源的唯一汇入口,顺序固定:tracing(必须先于静态 listener,见 115-122 行注释)→ stats 配置 → 静态 secrets → ClusterManager → 静态 listeners(source/server/configuration_impl.cc:112-159)。

```cpp
// source/server/configuration_impl.cc:131-153(节选)
const auto& secrets = bootstrap.static_resources().secrets();
for (ssize_t i = 0; i < secrets.size(); i++) {
  RETURN_IF_NOT_OK(server.secretManager().addStaticSecret(secrets[i]));
}
auto manager_or_error = cluster_manager_factory.clusterManagerFromProto(bootstrap);
cluster_manager_ = std::move(*manager_or_error);
status = cluster_manager_->initialize(bootstrap);
const auto& listeners = bootstrap.static_resources().listeners();
for (ssize_t i = 0; i < listeners.size(); i++) {
  absl::StatusOr<bool> update_or_error =
      server.listenerManager().addOrUpdateListener(listeners[i], "", false);
```

关键在于:静态 listener 调用的 `addOrUpdateListener(..., added_via_api=false)` 与 LDS 动态下发是**同一个入口**(configuration_impl.cc:147-154 对照 lds_api.cc:102-103)——静态资源只是不走订阅路径的首次注入,生命周期状态机与动态资源共用。ClusterManager 侧把 cluster 分两阶段加载:非 EDS(或 EDS 走文件)为 primary,REST/gRPC EDS 为 secondary,因为 secondary 集群自身的订阅要依赖 primary 集群提供网络(source/common/upstream/cluster_manager_impl.cc:369-380)。

动态资源由各 Manager 构造时创建 Subscription:CDS 在 `CdsApiImpl` 构造函数中调 `subscriptionFromConfigSource()`(source/common/upstream/cds_api_impl.cc:36-48);LDS 在 `LdsApiImpl` 构造函数同样处理,并把订阅启动挂到 `init_target_("LDS", ...)` 上(source/common/listener_manager/lds_api.cc:29-47);SDS 动态 secret 也是同一模式,`SdsApi` 持有 `init_target_`,ready 之前阻塞所在 listener/cluster 初始化(source/common/secret/sds_api.cc:19-24;secret_manager_impl 按 SDS 配置 findOrCreate 各类 provider,source/common/secret/secret_manager_impl.cc:131-158)。

订阅工厂按 `ConfigSource.config_source_specifier_case()` 分派:path/path_config_source → `envoy.config_subscription.filesystem`,api_config_source 按枚举 → rest/grpc/delta_grpc,ads → `envoy.config_subscription.ads`,再经 `Registry::FactoryRegistry<ConfigSubscriptionFactory>` 查扩展工厂创建(source/common/config/subscription_factory_impl.cc:52-113)。gRPC 类源创建前校验 backing cluster 必须是 primary 集群(source/common/config/utility.cc:136-160),secret 类型豁免该检查(subscription_factory_impl.cc:66-70)。xdstp:// collection 走 `collectionSubscriptionFromUrl()`,支持 filesystem collection、delta_grpc_collection、aggregated_grpc_collection、ads_collection 四种(destination factory 名见 191-247 行,subscription_factory_impl.cc:162-252)。

## 2. 订阅框架:四种 delivery 的统一抽象

统一抽象在 `envoy/config/subscription.h`:`SubscriptionCallbacks` 提供两个 `onConfigUpdate` 重载(SotW 版 110-111 行,delta 版 122-125 行)与 `onConfigUpdateFailed`(133 行);`Subscription` 接口只有 `start()/updateResourceInterest()/requestOnDemandUpdate()`(212-235 行);每订阅统一统计 `init_fetch_timeout/update_attempt/update_failure/update_rejected/update_success/update_time/version/version_text/update_duration`(242-251 行)。delivery 差异全部被压缩到工厂之下:

- **filesystem**:`FilesystemSubscriptionImpl::start()` 直接读一次文件(start 即 refresh),之后靠 inotify 触发(source/extensions/config_subscription/filesystem/filesystem_subscription_impl.cc:51-55)。文件内容就是一条 `DiscoveryResponse` JSON,`refreshInternal()` 加载并解包为 `DecodedResourcesWrapper` 后回调 `onConfigUpdate`(70-81 行);解析失败计 `update_rejected_` 并回调 `onConfigUpdateFailed(UpdateRejected)`(62-68, 97-108 行)。`WatchedDirectory` 在文件级 inotify 不可靠的平台提供目录级兜底监视(source/common/config/watched_directory.cc:1-36)。
- **REST**:`HttpSubscriptionImpl` 基于 `RestApiFetcher` 周期轮询,`createRequest()` 把缓存的 DiscoveryRequest 序列化成 JSON,POST 到 gRPC 方法 `google.api.http` 注解给出的路径(source/extensions/config_subscription/rest/http_subscription_impl.cc:36-41, 71-79);`parseResponse()` 解码成功后 `request_.set_version_info(message.version_info())`,下次轮询自动携带该版本(92-103 行)。resource_names 排序保证线序稳定(53-57 行)。
- **gRPC(非聚合)**:`GrpcSubscriptionImpl` 是薄包装:`start()` 里设置 `init_fetch_timeout` 定时器(默认 15s,source/common/config/utility.cc:205-208)、`addWatch` 到 mux;仅非聚合模式由订阅自己调 `mux->start()`——"ADS 初始请求批处理依赖使用者不调 start"(source/extensions/config_subscription/grpc/grpc_subscription_impl.cc:32-52)。
- **ADS**:同一个 `GrpcSubscriptionImpl`,但 `is_aggregated=true`,mux 由 ClusterManager 统一启动;AdsConfigSubscriptionFactory 直接注入全局 `data.ads_grpc_mux_`(source/extensions/config_subscription/grpc/grpc_subscription_factory.cc:138-144)。ADS 侧工厂还有 `subscriptionOverAdsGrpcMux()` 用于指定 mux 的场景(subscription_factory_impl.cc:128-160)。

统计口径因此跨 delivery 一致:成功路径统一在订阅层 `update_success_/update_time_/version_text_` 落账(gRPC 版 grpc_subscription_impl.cc:82-95;REST 版 http_subscription_impl.cc:99-102;filesystem 版 filesystem_subscription_impl.cc:89-92)。

## 3. SotW 与 Delta 两条协议路径

**接口层分野**:`SubscriptionCallbacks` 第一重载收 `vector<DecodedResourceRef> + version_info`(全量),第二重载收 `added_resources + removed_resources + system_version_info`(增量)(envoy/config/subscription.h:110-125)。实现族谱系:

| 代际 | SotW | Delta | 备注 |
|---|---|---|---|
| legacy | `GrpcMuxImpl`(grpc_mux_impl.cc) | `NewGrpcMuxImpl` + `DeltaSubscriptionState` + `WatchMap` | 默认启用 |
| unified | `XdsMux::GrpcMuxSotw` | `XdsMux::GrpcMuxDelta` | `envoy.reloadable_features.unified_mux` 控制 |

unified 实现用模板 `GrpcMuxImpl<S,F,RQ,RS>` 把两种协议统一到一份 mux 骨架(source/extensions/config_subscription/grpc/xds_mux/grpc_mux_impl.h:57-61, 261-292)。选择开关 `envoy.reloadable_features.unified_mux` 在 v1.39.1 为 `FALSE_RUNTIME_GUARD`,即默认关闭(source/common/runtime/runtime_features.cc:13-14, 172):

```cpp
// source/extensions/config_subscription/grpc/grpc_subscription_factory.cc:66-70
if (Runtime::runtimeFeatureEnabled("envoy.reloadable_features.unified_mux")) {
  mux = std::make_shared<Config::XdsMux::GrpcMuxSotw>(grpc_mux_context);
} else {
  mux = std::make_shared<Config::GrpcMuxImpl>(grpc_mux_context);
}
```

delta 同理在 `NewGrpcMuxImpl` 与 `GrpcMuxDelta` 之间二选一(grpc_subscription_factory.cc:127-131;ADS 侧对应 xds_manager_impl.cc:216-221)。因此默认配置下 SotW → `GrpcMuxImpl`,delta → `NewGrpcMuxImpl`;unified mux 是为删除旧实现准备的过渡态(接口层留有兼容层,`UntypedConfigUpdateCallbacks` 上注明 "TODO (dmitri-d) remove this method when legacy sotw mux has been removed",envoy/config/subscription.h:155-170)。

**SotW 的资源拆包**:legacy `GrpcMuxImpl::onDiscoveryResponse()` 按 type_url 找 `ApiState`,把 response 里每个 `Any` 解码为 `DecodedResourceImpl`(心跳资源除外),`processDiscoveryResources()` 建 `name → resource` 有序映射后遍历所有 watch:空资源名的 watch(集群/监听级订阅)**无论是否为空都回调** `onConfigUpdate`,以维持"全量世界"语义并正确累计 `update_empty`;具名 watch(EDS/RDS)只在命中时回调(source/extensions/config_subscription/grpc/grpc_mux_impl.cc:417-433, 506-538)。unified 版逻辑等价,搬到 `SotwSubscriptionState::handleGoodResponse()`,成功后记录 `last_good_version_info_` 与 `last_good_nonce_`,作为下一请求的 version/nonce(source/extensions/config_subscription/grpc/xds_mux/sotw_subscription_state.cc:46-77)。

**Delta 的资源拆包**:`DeltaSubscriptionState::handleGoodResponse()` 先做协议校验——added 中重复资源名、added+removed 交集中重复、内嵌 `Any` 的 type_url 与消息级 type_url 不一致,均抛异常(158-186 行);再把心跳资源 `stable_partition` 到队尾,以 `absl::Span<const Resource* const>` 调 `callbacks().onConfigUpdate(span, removed, system_version)`(188-201 行)。真正分发在 `WatchMap::onConfigUpdate(delta)`:解码后按 `watchesInterestedIn(name)` 打包 per-watch 的 added/removed,逐 watch 回调;added 与 removed 均为空时对 wildcard watch 发"空更新"通知(source/extensions/config_subscription/grpc/watch_map.cc:236-248, 261-291)。

```cpp
// source/extensions/config_subscription/grpc/watch_map.cc:286-291(空更新通知)
// notify empty update
if (added_resources.empty() && removed_resources.empty()) {
  for (auto& cur_watch : wildcard_watches_) {
    THROW_IF_NOT_OK(cur_watch->callbacks_.onConfigUpdate({}, {}, system_version_info));
  }
}
```

delta 状态机还要维护 wildcard/显式订阅的迁移:`wildcard_resource_state_`、`ambiguous_resource_state_` 与 `requested_resource_state_` 三张表记录资源从"通配带来"到"显式请求"的流转(退订 wildcard 时清空其缓存,xds_mux/delta_subscription_state.cc:25-91);源码目录附状态图 `source/common/config/wildcard-resource-state-machine.png`。TTL 资源的过期由 `TtlManager` 回调 `ttlExpiryCallback()`,以"removed_resources 空更新"的形式通知上层(xds_mux/delta_subscription_state.cc:355-378)。心跳资源判定:无 payload 且版本与本地已知一致即 heartbeat(VHDS 明确不支持,19-21, 128-156 行)。

## 4. GrpcMux 家族:多路复用、watch、type_url 路由、ack/nack

**传输层 `GrpcStream`**。gRPC 家族共享同一传输组件:`GrpcStream` 在构造时创建 retry timer(到期重开流),`establishNewStream()` 建流、`sendMessage()` 发请求,断流回调 `onRemoteClose()` 后按 `BackOffStrategy` 退避重启,连上后 reset 退避基准(grpc_stream.h:48, 61, 84, 96-97, 112, 174)。请求限流(`rate_limit_settings`)在 mux 侧发送前检查,默认 100 token / fill rate 10(source/common/config/utility.h:54-56;解析在 source/common/config/utility.cc:210-228)。

**多路复用与订阅顺序**。所有资源类型共享一条 gRPC 流;`subscription_ordering_` 记录 type_url 加入顺序,非 ACK 请求按该顺序发送——隐式复刻 CDS→EDS→LDS→RDS 依赖序(new_grpc_mux_impl.cc:456-464;头文件注明 "Assumes that subscriptions are added in the order of Envoy's dependency ordering",grpc_mux_impl.h:228-230)。订阅方经 `addWatch(type_url, resources, callbacks, decoder)` 挂接,type_url 首次出现才懒创建订阅(new_grpc_mux_impl.cc:241-256);watch 兴趣变化经 `WatchMap::updateWatchInterest` 归并出"全订阅层"增减(watch_map.cc:313-347)。

**请求发送状态机**。`trySendDiscoveryRequests()` 循环:问 `whoWantsToSendDiscoveryRequest()`(ACK 严格优先于普通订阅变更),`canSendDiscoveryRequest()` 检查流可用与限流,然后组装请求发送(new_grpc_mux_impl.cc:381-423):

```cpp
// source/extensions/config_subscription/grpc/new_grpc_mux_impl.cc:404-420(节选)
envoy::service::discovery::v3::DeltaDiscoveryRequest request;
if (!pausable_ack_queue_.empty()) {
  // ACKs take precedence over plain requests
  request = sub->second->sub_state_.getNextRequestWithAck(pausable_ack_queue_.popFront());
} else {
  request = sub->second->sub_state_.getNextRequestAckless();
}
const bool set_node = sub->second->sub_state_.dynamicContextChanged() ||
                      !skip_subsequent_node_ || first_request_on_stream_;
if (set_node) {
  first_request_on_stream_ = false;
  *request.mutable_node() = local_info_.node();
}
grpc_stream_->sendMessage(request);
```

`node` 字段仅在流上首条请求或 dynamic context 变化时携带(受 `set_node_on_first_message_only` 控制)。暂停机制 `pause(type_url)` 返回 RAII `ScopedResume`,配合 `PausableAckQueue` 让跨类型排序成为可能:CDS 在下发 EDS 前暂停 EDS/LEDS/SDS(cluster_manager_impl.cc:225-237),LDS 在下发 listener 前暂停 RDS/SRDS/SDS(lds_api.cc:53-57)。legacy SotW 的对应实现是 `ApiState.pauses_` 计数与响应处理期间的自动 `pause(type_url)`(grpc_mux_impl.cc:336-361, 407-412)。

**ack/nack 与 version 推进**。`BaseSubscriptionState::handleResponse()` 是枢纽:nonce **总是**复制进下一请求,即使该请求是 NACK;处理抛 `EnvoyException` 时 `handleBadResponse()` 置 `error_detail=gRPC Internal` 并回调 `onConfigUpdateFailed(UpdateRejected)`(source/extensions/config_subscription/grpc/xds_mux/subscription_state.h:67-83, 116-122)。ACK 请求由 `getNextRequestWithAck()` 附 `response_nonce` 与非空才带的 `error_detail`(98-107 行);`UpdateAck` 结构只有 nonce/type_url/error_detail 三件套(source/extensions/config_subscription/grpc/update_ack.h:10-17)。SotW legacy 的 version 推进点:整包处理成功后 `api_state.request_.set_version_info(version_info)`(grpc_mux_impl.cc:564);NACK 即不推进版本——靠"异常跳过 set_version_info"自然实现,同时显式写 `error_detail`(444-457 行)。unified SotW 在 `getNextRequestInternal()` 里 `set_version_info(last_good_version_info_)`(sotw_subscription_state.cc:159-170)。delta 重连则改用 `initial_resource_versions` 告知服务器本地已知版本,免全量重发(delta_subscription_state.cc:250-296)。

**重连与失败**。gRPC 流断开由 `GrpcStream` 统一处理:retry timer 按抖动指数退避重建流(grpc_stream.h:48, 61, 112, 174;断开时 reset backoff,96-97 行)。流重建后 `onStreamEstablished()` 把所有订阅 `markStreamFresh`、清空 ack 队列并重发初始请求(new_grpc_mux_impl.cc:193-201);establishment failure 遍历通知全部订阅(203-222 行),最终驱动 `init_target_.ready()` 放行启动(第 6 节)。

**ADS 与 xdstp 多 authority**。ADS mux 创建只在 `XdsManagerImpl::initializeAdsConnections()` 一处区分 delta/SotW,注释明说"这是唯一区分点,此后只是 GrpcMux 接口"(source/common/config/xds_manager_impl.cc:189-195);无 ads_config 时装入 `NullGrpcMuxImpl` 占位(280 行)。bootstrap 的 `config_sources`/`default_config_source` 还会为每个 xdstp authority 建独立 mux(`authorities_`/`default_authority_`),`pause()` 需同时暂停所有 mux(xds_manager_impl.cc:176-187, 367-380)。ADS 依赖 Envoy 自身集群(EnvoyGrpc)时,mux 延迟到该集群初始化完成才 start:`isBlockingAdsCluster()` 识别阻塞集群(cluster_manager_impl.cc:91-112),`onClusterInit` 里 `requiredForAds()` 触发 start(1300-1303 行)。xDS failover(双 xDS 源)由 `GrpcMuxFailover` 包装 primary/failover 两条流,受默认关闭的 `envoy.restart_features.xds_failover_support` 控制(new_grpc_mux_impl.cc:68-123;runtime_features.cc:207)。关停防护:`NewGrpcMuxImpl::shutdownAll()` 全局禁止再向流写消息,server 终止时逐一调用四家 mux 工厂的 `shutdownAll()`(new_grpc_mux_impl.cc:38-48;server.cc:1110-1118)。

## 5. 一条 xDS 消息的完整路径(以 CDS 为例,LDS 同构)

1. gRPC 流回调 `onDiscoveryResponse(unique_ptr<DeltaDiscoveryResponse>)`,mux 按 `message->type_url()` 查 `subscriptions_`,未知 type_url 直接丢弃并告警(new_grpc_mux_impl.cc:157-170);
2. 记录 `control_plane.identifier` 到 admin 统计(172-180 行);
3. `sub_state_.handleResponse()` → `handleGoodResponse()`:校验 + 心跳过滤 → `WatchMap::onConfigUpdate(added, removed, system_version)`(xds_mux/delta_subscription_state.cc:158-201);
4. WatchMap 解码、执行外部 config validators、按 watch 分包逐个回调(watch_map.cc:257-285);
5. 回调先落 `GrpcSubscriptionImpl::onConfigUpdate`(订阅统计层),再落 `CdsApiImpl::onConfigUpdate`:SotW 响应在此换算成 delta 语义——"现有 active/warming 集合 减去 响应内资源"即待删除列表(cds_api_impl.cc:81-99);
6. 真正应用在 `helper_.onConfigUpdate()` → `ClusterManagerImpl::addOrUpdateCluster`,新增/变更进 `warming_clusters_`,统计 `config_reload`(cds_api_impl.cc:102-118);
7. 成功 → `kickOffAck(ack)` 入队发出 ACK;失败 → `xds_config_tracker_->onConfigRejected()` 记录后 NACK(new_grpc_mux_impl.cc:182-189, 226-229)。

LDS 应用侧是 `LdsApiImpl::onConfigUpdate()`:先 `xds_manager_.pause(RDS/SRDS/SDS)` 保序;**先删除后添加**(允许新 listener 复用被删 listener 地址,注释强调 "Do not change the order",lds_api.cc:60-69);单个 listener 失败进 `failure_state` 供 config dump 呈现而不整体回滚(71-89, 118 行);最后 `init_target_.ready()` 放行启动(123 行)。

## 6. warm / active / disposing:配置侧触发的过渡状态机

**CDS(cluster warming)**。启动完成后的更新路径:`addOrUpdateCluster()` 把新 cluster 装入 `warming_clusters_`,gauge `warming_state_` 置 1,`cluster.initialize()` 完成回调里 `onClusterInit` → `clusterWarmingToActive()` 移入 `active_clusters_`(cluster_manager_impl.cc:764-797, 802-812):

```cpp
// source/common/upstream/cluster_manager_impl.cc:788-797(节选)
cluster_entry->cluster_->info()->configUpdateStats().warming_state_.set(1);
if (!all_clusters_initialized) {
  init_helper_.addCluster(*cluster_entry);
} else {
  cluster_entry->cluster_->initialize([this, cluster_name] {
    auto state_changed_cluster_entry = warming_clusters_.find(cluster_name);
    state_changed_cluster_entry->second->cluster_->info()->configUpdateStats().warming_state_.set(0);
    return onClusterInit(*state_changed_cluster_entry->second);
  });
}
```

EDS 集群的"warm"就是等第一份 `ClusterLoadAssignment`:`startPreInit()` 才 `subscription_->start()`(source/extensions/clusters/eds/eds.cc:73);空响应计 `update_empty_` 后 `onPreInitComplete()` 放行(eds.cc:198-205)。EDS 订阅建在集群构造函数里,且 path 类 eds_config 使集群归入 Primary 相位、否则 Secondary(eds.cc:40-45;经 `subscribeToSingletonResource` 或 `subscriptionFromConfigSource` 创建,47-63 行)。启动期时序由 `ClusterManagerInitHelper` 状态机驱动:Loading → WaitingForPrimaryInitializationToComplete →(回调外部触发)→ WaitingToStartSecondaryInitialization → WaitingToStartCdsInitialization(`cds_->initialize()`)→ AllClustersInitialized(cluster_manager_impl.cc:197-264;secondary 阶段统一 pause EDS/LEDS/SDS 后再初始化,225-237 行)。删除直接移除 active/warming 两处并清理线程局部状态(814-864 行);同名 warming 更新冲突由 `blockUpdate()` 哈希比对挡下(736-760 行)。

**LDS(listener warming)**。workers 已启动时,新 listener 先进 `warming_listeners_`(listener_manager_impl.cc:666-668);其 init target(SDS/RDS 等)齐备后 `onListenerWarmed()` 把它从 warming 挪进 active,旧 listener `drainListener()` 进 `draining_listeners_`,worker 停止 accept 并等存量连接排空(865-897, 728-743 行);workers 未启动时直接进 active(669-683 行)。另有 in-place filter chain 更新捷径,不经过完整 warming(636-644 行)。

**配置侧与状态机的握手**。为避免路由先于集群就绪,`updateClusterCounts()` 在存在 warming cluster 期间持续 `pause(CDS)`——CDS 的 ACK 被扣住,ADS 看不到 CDS ACK 就不会推进依赖它的 RDS(cluster_manager_impl.cc:959-980,注释完整解释该 503 规避机制)。监听侧对应 `blockLdsUpdate()`(listener_manager_impl.cc:612-631)。

## 7. 资源名、管理服务端与 config dump

每个 xDS 资源类型由 resource name + type_url 标识(`Grpc::Common::typeUrl(...)`/`Config::getTypeUrl<T>`)。订阅可以是具名集合、空集合(全量)或 xdstp:// 通配:legacy SotW 对 xdstp 通配 watch 用 `convertToWildcard()` 前缀匹配(grpc_mux_impl.cc:514-533);xdstp 资源名在发送前会归一化并注入 node context 参数(new_grpc_mux_impl.cc:303-322)。

admin `/config_dump` 的数据源是 `ConfigTracker` 回调注册表:

| key | 注册点 |
|---|---|
| "bootstrap" | source/server/server.cc:806-808 |
| "clusters" | source/common/upstream/cluster_manager_impl.cc:336-340 |
| "listeners" | source/common/listener_manager/listener_manager_impl.cc:423-427 |
| "routes" 等 | source/common/rds/route_config_provider_manager.cc:15-22;通用机制 source/common/config/config_provider_impl.cc:76-90 |

`ConfigDumpHandler::handlerConfigDump()` 聚合回调产物为 `envoy::admin::v3::ConfigDump`,支持 `?resource=` 单类、`?mask=` 裁剪、name matcher 过滤与 `include_eds` 附加(EDS 明确不含 warming 集群,注释见 source/server/admin/config_dump_handler.cc:152-207, 195 行)。LDS 应用的失败配置也进 dump:`LdsApiImpl` 把被拒 listener 塞进 `failure_state`(lds_api.cc:80-89)。on-demand 资源(ODCDS)由 `ClusterDiscoveryManager` 管理回调等待队列,资源到达时逐个唤醒(source/common/upstream/cluster_discovery_manager.cc:43-74),mux 侧入口为 `requestOnDemandUpdate()`(new_grpc_mux_impl.cc:342-352)。

## 8. OTel / Stats / Tracing 配置的挂载(类级)

- **stats sinks**:`MainImpl::initializeStatsConfig()` 遍历 `bootstrap.stats_sinks()`,逐个 `getAndCheckFactory<StatsSinkFactory>` → `translateToFactoryConfig` → `createStatsSink`(source/server/configuration_impl.cc:162-177)。
- **tracing**:`bootstrap.tracing` 经 `initializeTracers()` 设为 server 级默认 `TracerFactory` 配置(configuration_impl.cc:179-203);动态化改造后 Tracer 实例按 HCM 逐个创建,动机注释见 115-122 行。OpenTelemetry tracer 是普通扩展工厂(source/extensions/tracers/opentelemetry/opentelemetry_tracer_impl.cc),与其他 tracer 同一挂载点。
- **动态扩展体系**:RDS/SRDS 共享的 `ConfigProvider`/`ConfigSubscriptionCommonBase` 框架(source/common/config/config_provider_impl.h,envoy/config/dynamic_extension_config_provider.h)是订阅化扩展配置的宿主;SRDS 的 `ScopedRdsConfigSubscription` 即构建其上(source/common/router/scoped_rds.h:109, 197, 209-216),其统计宏同样含 `update_empty`(scoped_rds.h:91)。

RDS 值得一提的细节:每个 route config 名对应一个 `RdsRouteConfigSubscription`,其 `local_init_target_` 启动时才 `subscription_->start({route_config_name_})`(source/common/rds/rds_route_config_subscription.cc:41-43);资源缺失计 `update_empty_` 并放行 init(79-85 行);版本变化才重建路由表并触发 HCM 侧 `route_config_provider_->onConfigUpdate()`(112-126 行)。

## 9. 失败与更新语义汇总

| 语义 | 位置 | 行为 |
|---|---|---|
| reject | `handleBadResponse`(xds_mux/subscription_state.h:116-122);legacy(grpc_mux_impl.cc:444-457) | onConfigUpdate 抛 EnvoyException → `update_rejected_`、error_detail=Internal → NACK;旧配置继续服务 |
| nack | `handleResponse`(subscription_state.h:67-83) | nonce 必回传 + error_detail 非空;版本不推进 |
| update_empty | RDS(rds_route_config_subscription.cc:79-85)、EDS(eds.cc:197-206)、SotW 订阅层(grpc_mux_impl.cc:506-513) | 资源缺失/空集是合法更新;单资源订阅视为"尚未就绪",仅放行 init |
| init fetch timeout | `GrpcSubscriptionImpl::start()`(grpc_subscription_impl.cc:33-38);默认 15s(utility.cc:205-208) | `FetchTimedout` → `init_fetch_timeout_` 计数并放行启动(server 可带空配置起来) |
| REST 失败 | http_subscription_impl.cc:117-145 | ConnectionFailure 不回调上层(靠下次轮询重试);rejected/timeout 回调 |
| 超时缓存兜底 | EDS(eds.cc:452-479) | 开启 EDS cache 时用缓存 ClusterLoadAssignment,`assignment_use_cached_` 计数 |
| on-demand | cluster_discovery_manager.cc:43-74;new_grpc_mux_impl.cc:342-352 | 未知资源先注册回调,再向控制面发 delta 订阅 |
| 协议级 reject | xds_mux/delta_subscription_state.cc:158-186 | 重复资源名 / 内嵌 Any type_url 与消息级不一致,直接抛异常 → NACK |
| control_plane 标识 | new_grpc_mux_impl.cc:172-180 | 响应携带 control_plane.identifier 时写入 stats,支持观测 xDS 服务端切换 |
| 关停防护 | new_grpc_mux_impl.cc:38-48;server.cc:1110-1118 | 析构竞态下禁止再向流写消息 |

Delta 请求的关键线上的字段与其写入点:`type_url`(每个请求必带,delta_subscription_state.cc:253)、`resource_names_subscribe/unsubscribe`(兴趣增减,289-294 行)、`initial_resource_versions`(仅流上首条,254-287 行)、`response_nonce` + `error_detail`(ack/nack,subscription_state.h:98-107)、`node`(首条或 dynamic context 变化,new_grpc_mux_impl.cc:413-418)。

## 10. 设计动机

1. **四种 delivery 统一成 `Subscription` 抽象**:文件、REST 轮询、gRPC 流、ADS 复用的差异被压缩在传输层之下;所有 Manager 只面向 `SubscriptionCallbacks` 编程,新增一种传输(xdstp collection 等)不动业务侧(envoy/config/subscription.h:212-235;subscription_factory_impl.cc:52-113 用扩展工厂注册表分派)。统一统计宏让运维口径跨 delivery 一致(subscription.h:242-251)。
2. **为什么 ADS**:无 ADS 时每类资源各开一条流、各自重连排序;ADS 一条流 + type_url 复用,把跨资源顺序转化为 mux 内 `subscription_ordering_` + pause 队列问题,且 ACK 即排序信号(CDS ACK 扣到 cluster warm 完成才发,cluster_manager_impl.cc:959-980)。ADS 还是 delta/SotW 可切换的单点(唯一分派点 xds_manager_impl.cc:189-195)。
3. **为什么 delta xDS**:SotW 下海量 EDS 集群每次全量重发;delta 用 `resource_names_subscribe/unsubscribe` 增量表达兴趣,重连用 `initial_resource_versions` 免全量(xds_mux/delta_subscription_state.cc:254-296);watch 级分发避免 O(n^2)(watch_map.cc:227-234 与 grpc_mux_impl.cc:469-474 两代实现的同款注释)。heartbeat/TTL 依赖 delta 的 per-resource 语义(delta_subscription_state.cc:128-156)。
4. **为什么 warm 状态**:配置可用性有依赖注入顺序(EDS←CDS、RDS←CDS、SDS←Listener);warming 给"已接受但不可服务"的资源明确中间态,避免半初始化对象接流量,并允许同名字段无中断换血(active→draining 保留存量连接,listener_manager_impl.cc:865-897)。`init_target_.ready()` 是配置侧(订阅就绪)驱动 server 侧(启动推进)的唯一握手(lds_api.cc:31, 123;eds.cc:73;cds_api_impl.cc:120-126 失败也要 ready 让启动继续)。
5. **为什么 version_info/nonce ack**:nonce 回传让服务器把响应对上请求(即使 NACK),version_info 维持 per-type_url 版本推进;NACK 携带 `error_detail` 使控制面拿到可观测拒绝原因而非盲目重发(subscription_state.h:67-83, 98-107;grpc_mux_impl.cc:449-451, 564)。SotW 全局 version 简单但粒度粗,delta 换成 per-resource version + ack 队列,协议演进不破坏 ack 语义(pausable_ack_queue 保证 ACK 顺序且可被 pause 扣留,new_grpc_mux_impl.cc:138-155)。
6. **为什么 legacy/new/unified 三代 mux 并存**:协议状态机(per-type_url `SubscriptionState`)与传输(`GrpcStream`/failover)解耦后,xds_mux 用模板吸收 SotW/Delta 差异,降低双实现漂移;但替换数据面核心路径风险高,故以 `envoy.reloadable_features.unified_mux`(默认 false)灰度,并在接口层保留兼容层等待旧 mux 删除(envoy/config/subscription.h:159 TODO;runtime_features.cc:172)。

## 11. 写作素材清单(文件:行号)

1. `envoy/config/subscription.h:97-134, 212-251` — 订阅抽象、双重载 onConfigUpdate 与统一统计
2. `source/common/config/subscription_factory_impl.cc:52-113` — ConfigSource 四分派与扩展工厂
3. `source/server/configuration_impl.cc:112-159` — Bootstrap 静态资源装载顺序(secrets→CM→listeners)
4. `source/server/server.cc:757-770, 1110-1118` — 初始化时序自述注释与 mux 关停
5. `source/common/config/xds_manager_impl.cc:189-283, 367-380` — ADS mux 创建唯一分派点 + NullGrpcMux + 多 authority pause
6. `source/extensions/config_subscription/grpc/grpc_subscription_factory.cc:66-70, 127-144` — unified_mux 新旧选择与 ADS 订阅工厂
7. `source/extensions/config_subscription/grpc/new_grpc_mux_impl.cc:381-466` — 请求发送状态机(ACK 优先、node 字段、限流)
8. `source/extensions/config_subscription/grpc/xds_mux/subscription_state.h:67-122` — ack/nack 枢纽与 NACK error_detail
9. `source/extensions/config_subscription/grpc/xds_mux/delta_subscription_state.cc:158-296` — delta 校验/拆包/initial_resource_versions/wildcard
10. `source/extensions/config_subscription/grpc/grpc_mux_impl.cc:363-566` — legacy SotW 响应处理、watch 分发、version 推进
11. `source/extensions/config_subscription/grpc/watch_map.cc:219-305` — delta 资源 per-watch 分包与空更新
12. `source/common/upstream/cds_api_impl.cc:81-118` — CDS SotW→delta 换算与 cluster_manager 应用
13. `source/common/listener_manager/lds_api.cc:49-128` — LDS 应用:pause RDS/SDS、先删后加、failure_state
14. `source/common/listener_manager/listener_manager_impl.cc:594-704, 865-897` — listener warming→active→draining 迁移
15. `source/common/upstream/cluster_manager_impl.cc:764-812, 959-983` — cluster warming 与 CDS pause-for-warming
16. `source/extensions/clusters/eds/eds.cc:38-73, 197-206, 452-479` — EDS 订阅建立、相位选择、update_empty 与超时缓存兜底

---

## 附:建议阅读顺序

初读按 §1(装配)→ §2(抽象)→ §4(mux)→ §5(消息路径)推进即可建立主干;§3 的 SotW/delta 对照与 §6 的 warming 状态机建议对照源码并排读。通读 bootstrap 装配后再回到 `source/server/server.cc:841`(`config_.initialize(bootstrap_, ...)`)可以看清 server 与配置体系的总接缝。若关注控制面演进,重点跟踪 `envoy.reloadable_features.unified_mux`(默认 false,runtime_features.cc:172)与 `envoy.restart_features.xds_failover_support`(默认 false,runtime_features.cc:207)两个开关的默认值变化。
