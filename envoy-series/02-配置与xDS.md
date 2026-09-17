# 第 02 章 · 配置体系与 xDS:动态控制面的实现

> 基线:tag v1.39.1。核心目录 source/common/config/ 与 source/extensions/config_subscription/。

## 2.0 全景:配置如何流进 Envoy

```
Bootstrap(-c 文件)→ MainImpl::initialize(configuration_impl.cc:112)
   static_resources:secrets→SecretManager / clusters→CM / listeners→ListenerManager
   dynamic_resources:各订阅方按 ConfigSource 走 subscriptionFromConfigSource
     (subscription_factory_impl.cc:52-105)分派四种 delivery:
   path→Filesystem(inotify) / REST→轮询 / gRPC→独立流 / ADS→复用全局 mux
ADS mux 创建唯一分派点:xds_manager_impl.cc:189-195(delta vs SotW;无 ads_config 装 NullGrpcMux)
   → onDiscoveryResponse 按 type_url 路由 → SubscriptionCallbacks.onConfigUpdate → Manager 应用
```

静态与动态资源**共用同一入口**:静态 listener 调的 `addOrUpdateListener(added_via_api=false)` 与 LDS 下发是同一函数(configuration_impl.cc:147-154 对照 lds_api.cc:102-103)。初始化时序即依赖拓扑:bootstrap→primary 集群→用 primary 建 ADS/RTDS→secondary(EDS)→其余(server.cc:757-770)。

## 2.1 四种 delivery 的统一抽象

`Subscription` 接口只有 start/updateResourceInterest/requestOnDemandUpdate,`SubscriptionCallbacks` 提供 SotW 与 delta 两个 onConfigUpdate 重载(subscription.h:110-125,212-235);统一统计宏让 update_success/version_text 等口径跨 delivery 一致(:242-251)。filesystem 版 start 即读一次文件再靠 inotify(filesystem_subscription_impl.cc:51-55);REST 版把 version_info 塞回下次轮询请求(http_subscription_impl.cc:92-103);gRPC 版是薄包装,默认 init_fetch_timeout 15s(grpc_subscription_impl.cc:32-52,utility.cc:205-208);ADS 版 `is_aggregated=true`,mux 由 ClusterManager 统一启动(grpc_subscription_factory.cc:138-144)。

**重要现状**:SotW 与 delta 是两代 mux——`unified_mux` 默认 false(runtime_features.cc:172),故 SotW→`GrpcMuxImpl`、delta→`NewGrpcMuxImpl`;xds_mux 统一实现是 opt-in 的过渡态(subscription.h:155-170 留有删除 TODO)。

## 2.2 mux 的核心机制:watch、ACK 优先、pause

所有资源类型共享一条 gRPC 流;`subscription_ordering_` 按 type_url 加入顺序发送非 ACK 请求——隐式复刻 CDS→EDS→LDS→RDS 依赖序(new_grpc_mux_impl.cc:456-464)。请求发送循环 **ACK 严格优先**(ACK 从 pausable_ack_queue_ 弹出,:404-420);node 字段只在流上首条或 dynamic context 变化时携带。`pause(type_url)` 返回 RAII ScopedResume:CDS 下发 EDS 前暂停 EDS/LEDS/SDS, LDS 下发 listener 前暂停 RDS/SRDS/SDS(cluster_manager_impl.cc:225-237,lds_api.cc:53-57)。

**ack/nack 枢纽** `handleResponse`:nonce 总是复制进下一请求(即使 NACK);处理抛异常→error_detail=Internal→NACK,版本不推进(subscription_state.h:67-122);SotW 的 version 推进点=整包处理成功后 set_version_info(grpc_mux_impl.cc:564)。delta 重连用 `initial_resource_versions` 免全量重发(delta_subscription_state.cc:250-296)。

## 2.3 一条 CDS 消息的完整路径

gRPC 回调按 type_url 查订阅(未知丢弃)→ handleResponse 校验+心跳过滤→WatchMap 按 watch 分包逐个回调(watch_map.cc:236-291)→CdsApiImpl 把 SotW 响应换算成 delta 语义("现有集合减去响应集合"即删除,cds_api_impl.cc:81-99)→ClusterManagerImpl::addOrUpdateCluster 进 warming_clusters_→成功发 ACK/失败 NACK。LDS 应用侧:`xds_manager_.pause(RDS/SDS)` 保序→**先删后加**(允许新 listener 复用旧地址,注释强调"Do not change the order",lds_api.cc:60-69)→单 listener 失败进 failure_state 供 config dump 而不整体回滚。

## 2.4 warm/active/disposing 与 ACK 的握手

cluster warming:新集群先 `cluster.initialize()`,EDS 就绪回调 onClusterInit 才移入 active(cluster_manager_impl.cc:788-812)。listener warming:workers 已启动时新 listener 进 warming_listeners_,init target(RDS/SDS)齐备后先上线新的再 drain 旧的(:865-897)。精妙处:`updateClusterCounts()` 在存在 warming cluster 期间持续 pause(CDS)——**扣住 CDS 的 ACK,ADS 就不会推进依赖它的 RDS**,规避路由先于集群的 503 窗口(:959-980)。`init_target_.ready()` 是配置侧驱动 server 启动的唯一握手,失败也要 ready 让启动继续(cds_api_impl.cc:120-126)。

## 2.5 失败语义速查

| 语义 | 行为 |
|---|---|
| reject | onConfigUpdate 抛异常→update_rejected_→NACK;旧配置继续服务 |
| nack | nonce 必回传+error_detail;版本不推进 |
| update_empty | 空集是合法更新;单资源订阅视为未就绪仅放行 init |
| init 超时 | 15s 后 FetchTimedout,server 可带空配置起来 |
| on-demand | ODCDS 先注册回调再向控制面发 delta 订阅(cluster_discovery_manager.cc:43-74) |

## 2.6 设计动机

1. **统一 Subscription 抽象**:新增传输不动业务侧,统计口径一致;
2. **ADS**:一条流+type_url 复用,把跨资源顺序转化为 mux 内 ordering+pause 队列,ACK 即排序信号;
3. **delta**:海量 EDS 场景免全量,per-resource 语义支撑 heartbeat/TTL;
4. **warm 状态**:给"已接受但不可服务"的资源明确中间态,支持同名字段无中断换血;
5. **三代 mux 并存**:协议状态机与传输解耦后以模板吸收差异,默认关闭灰度替换。

## 2.7 FAQ

**Q1:xDS 有几种传输?**
四种:文件(inotify)/REST 轮询/gRPC 流/ADS 聚合;统一进 Subscription 抽象。

**Q2:SotW 和 delta 怎么选?**
ConfigSource 里 API 类型决定(GRPC vs DELTA_GRPC);实现分属两代 mux,unified mux 默认关。

**Q3:配置被拒会怎样?**
NACK+error_detail,旧配置继续服务;被拒 listener 进 failure_state 可在 config_dump 看到。

**Q4:为什么 LDS 要先删后加?**
允许新 listener 复用被删者地址,否则地址冲突(lds_api.cc:60-69 注释)。

**Q5:warming 的 listener 在等什么?**
其 init target(RDS/secrets)异步就绪;期间旧 listener 继续服务。

**Q6:ACK 为什么会被扣住?**
有 warming cluster 时暂停 CDS ACK,防止 ADS 推进依赖它的 RDS 造成 503 窗口。

**Q7:node 字段每次都发吗?**
只流上首条或 dynamic context 变化时发(set_node_on_first_message_only)。

**Q8:同配置重复下发会怎样?**
hash 比对相同则 NOP,不触发更新(cluster_manager_impl.cc:737-750)。

**Q9:xDS 服务端挂了会怎样?**
GrpcStream 按抖动指数退避重连;EDS 可开缓存兜底(eds.cc:452-479)。

**Q10:config_dump 数据从哪来?**
ConfigTracker 注册表:bootstrap/clusters/listeners/routes 四处注册回调。

## 2.8 小结与深挖方向

本章结论:**配置面="四种 delivery 一个抽象+ADS 一条流+ACK 即排序信号+warming 是配置与数据的握手"**。深挖:

1. xdstp:// 多 authority 的独立 mux 与 pause 遍历(xds_manager_impl.cc:367-380);
2. delta 的 wildcard 三状态机(wildcard-resource-state-machine.png);
3. TTL 资源与 TtlManager 的过期回调路径;
4. xds failover 双源切换(new_grpc_mux_impl.cc:68-123,默认关);
5. RDS 的 ConfigProvider 框架与 SRDS scope 路由。
