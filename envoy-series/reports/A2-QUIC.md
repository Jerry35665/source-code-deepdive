# A(卷二) QUIC 与 HTTP/3 数据面

> 基线:envoy tag v1.39.1,commit b579d07d3ad7ee11d32b105e91a5a39ad24718d7。
> 说明:任务指定的旧路径 `source/extensions/quic_listeners/` 与 `source/extensions/transport_sockets/quic/`
> 在 v1.39 已不存在。QUIC 集成核心在 `source/common/quic/`,可插拔扩展在 `source/extensions/quic/`,
> transport socket 工厂在 `source/common/quic/quic_*transport_socket_factory*`。本文按实际布局取证。

## 0. 分层全景图

```
                    worker 线程 (每 worker 一个 event loop / Dispatcher)
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │  per-worker UDP socket (SO_REUSEPORT 组内一份; kernel BPF 按 CID 分流)          │
  │      source/common/listener_manager/connection_handler_impl.cc:105-114        │
  │      source/common/quic/envoy_deterministic_connection_id_generator.cc:52-90  │
  └───────────────┬───────────────────────────────────────────────────────────────┘
                  │ recvmsg/recvmmsg(+GRO)  UdpListenerImpl
                  ▼
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │ ActiveQuicListener : Server::ActiveUdpListenerBase   (Envoy 的 UDP 回调适配)    │
  │   onReadReady/onDataWorker/onWriteReady → quic_dispatcher_->processPacket      │
  │   source/common/quic/active_quic_listener.cc:154-188,190-223                   │
  └───────────────┬───────────────────────────────────────────────────────────────┘
                  ▼
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │ EnvoyQuicDispatcher : quic::QuicDispatcher   (CHLO 缓冲/连接 id 路由/建会话)     │
  │   CreateQuicSession → listener filter chain → findFilterChain → HCM            │
  │   source/common/quic/envoy_quic_dispatcher.cc:95-166                           │
  └───────────────┬───────────────────────────────────────────────────────────────┘
                  ▼
  ┌──────────────────────────────────┐   ┌──────────────────────────────────────────┐
  │ EnvoyQuicServerSession           │   │ QUICHE 平台适配层 (event loop 桥接)        │
  │  = quic::QuicServerSessionBase   │   │  EnvoyQuicAlarm→Event::Timer  (alarm.cc) │
  │  + QuicFilterManagerConnectionImpl│  │  EnvoyQuicClock→Dispatcher  (clock.h)    │
  │  = Network::Connection + FilterManager│ EnvoyQuicPacketWriter→UdpPacketWriter │
  │  source/common/quic/envoy_quic_server_session.cc │ (packet_writer.cc:25-48)    │
  └───────────────┬──────────────────┘   └──────────────────────────────────────────┘
                  │ newStream(stream)  (每个 QUIC bidi stream 一个请求)
                  ▼
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │ QuicHttpServerConnectionImpl : Http::ServerConnection  ("Http3CodecLayer")     │
  │   控制 stream(SETTINGS/GOAWAY)与 QPACK 编解码由 QUICHE 内建;Envoy 只暴露       │
  │   Http::Connection/Http::Stream 接口  server_codec_impl.cc:18-37               │
  └───────────────┬───────────────────────────────────────────────────────────────┘
                  ▼
           HCM (ConnectionManagerImpl) —— 与 HTTP/1、HTTP/2 共用同一套 filter 链
```

## 1. quiche 如何被包进 Network::Listener 抽象(event loop 桥接)

Envoy 不重写 QUIC,而是把 Chromium 的 quiche 作为库嵌入,并用四个"胶水类"把 quiche 对
宿主环境的全部假设替换为 Envoy 抽象:

- 时钟:`EnvoyQuicClock` 实现 `quic::QuicClock`,直接从 `Event::Dispatcher` 取时间
  (`source/common/quic/envoy_quic_clock.h:12-18`)。
- 定时器:`EnvoyQuicAlarm` 把 `quic::QuicAlarm` 映射为 `Event::Timer`,构造时即创建
  timer,`SetImpl()` 用 `enableHRTimer` 设置微秒级到期;注释解释了为何要向上取整 1us
  (`source/common/quic/envoy_quic_alarm.cc:8-24`)。
- 随机数与发送缓冲分配器走 `EnvoyQuicConnectionHelper`
  (`source/common/quic/envoy_quic_connection_helper.h:14-32`)。
- 写路径:`EnvoyQuicPacketWriter` 是 `quic::QuicPacketWriter` 到 Envoy
  `UdpPacketWriter` 的适配器,把 quic 写结果翻译为 `WRITE_STATUS_OK/BLOCKED/ERROR`
  (`source/common/quic/envoy_quic_packet_writer.cc:13-48`)。注意 `ActiveQuicListener`
  构造时先向 listener 的 packetWriterFactory 要 writer,若它本身就是
  `quic::QuicPacketWriter`(如 GSO batch writer)则直接 `InitializeWithWriter`,否则包一层
  适配器(`source/common/quic/active_quic_listener.cc:108-123`)。

QUICHE 的"线程假设"被简化为:每个 session 只在创建它的 worker 线程上活动;alarm/timer
全部走该 worker 的 Dispatcher,因此不需要锁。

## 2. QuicListener / ActiveQuicListener:UDP 收包与建连

每个 worker 在 `ConnectionHandlerImpl` 中用 `socket_factory->getListenSocket(worker_index)`
拿到自己的 socket,再由 `udpListenerConfig()->listenerFactory().createActiveUdpListener(...)`
创建 per-worker 的 `ActiveQuicListener`
(`source/common/listener_manager/connection_handler_impl.cc:105-114`)。

`ActiveQuicListener` 继承 `Server::ActiveUdpListenerBase`,内部持有一个 `UdpListenerImpl`
负责真正的 socket 事件(`source/common/quic/active_quic_listener.cc:47-52`)。收包路径:

- 底层一次事件调用 `Utility::readPacketsFromSocket(..., prefer_gro_, /*allow_mmsg=*/true, ...)`,
  GRO 默认关闭(`prefer_gro` 默认 false,`source/common/network/udp_listener_impl.cc:35-37`,
  读包调用在 `:103-113`)。
- 每个 `UdpRecvData` 进入 `onDataWorker`:转成 `quic::QuicReceivedPacket`(携带时间戳、
  saved cmsg、ECN codepoint),交给 `quic_dispatcher_->processPacket`;若还有缓冲的 CHLO
  则 `udp_listener_->activateRead()` 让下轮 loop 继续
  (`source/common/quic/active_quic_listener.cc:154-188`)。
- 连接建立被限速:`kNumSessionsToCreatePerLoop = 16`,每轮 loop 至多处理
  `max_sessions_per_event_loop`(可配)个 CHLO,处理不完 `activateRead()` 排队
  (`source/common/quic/active_quic_listener.h:29-30`,`active_quic_listener.cc:141-143`,
  `:209-218`)。这是 QUIC 版的 `max_connections_to_accept_per_socket_event`。
- 监听 socket 上设置 `IPV6_RECVTCLASS`/`IP_RECVTOS` 以接收 ECN 标记
  (`source/common/quic/active_quic_listener.cc:79-97`);`quic_options.save_cmsg_config`
  可让内核把指定 cmsg 随包保存(`:125-139`)。
- runtime 开关 `envoy.reloadable_features.quic_reject_all` 每轮 loop 采样,用于紧急拒绝
  全部 QUIC 流量(`active_quic_listener.cc:190-219`)。

### 连接 id → worker 路由

`destination()` 决定一个包属于哪个 worker:若内核 BPF 路由生效(`kernel_worker_routing_`),
包已由内核送到正确 worker,只用本地 CID 选择器校验,不一致仅打日志并留在本 worker;
否则在用户态用 CID 选择器算出目标 worker 并跨 worker 投递
(`active_quic_listener.cc:237-253`;跨 worker 投递由
`source/server/active_udp_listener.cc:35-57` 的 worker router 完成)。
BPF 程序由 CID 生成器扩展提供:确定性生成器内嵌一段 cBPF,取 QUIC 头中连接 id 首字
mod worker 数作为 SO_REUSEPORT socket 索引
(`source/common/quic/envoy_deterministic_connection_id_generator.cc:52-90`);
QUIC-LB 扩展则另带 `route.bpf`/`compile_bpf.sh`
(`source/extensions/quic/connection_id_generator/quic_lb/`)。工厂构造时,concurrency>1 且
生成器不兼容 BPF 会降级并警告性能受损(`active_quic_listener.cc:390-409`)。

### 会话创建(EnvoyQuicDispatcher)

`CreateQuicSession` 中:构造伪 `ConnectionSocket`(SNI 来自 CHLO,ALPN 硬编码 "h3",
注释承认是待办)→ 跑 QUIC listener filter chain → `findFilterChain` → 创建
`EnvoyQuicServerConnection` + `EnvoyQuicServerSession` → 在 session 上建 network filter
chain(即 HCM)→ 计数(`source/common/quic/envoy_quic_dispatcher.cc:95-166`,
"quic.listener_filters"路径在 `:110-131`,硬编码 ALPN 注释 `:101-104`)。
找不到 filter chain 则直接关闭(`:157`)。

## 3. EnvoyQuicSession:与 Network::Connection 的适配

`EnvoyQuicServerSession` 同时继承 `quic::QuicServerSessionBase` 与
`QuicFilterManagerConnectionImpl`(后者继承 `Network::ConnectionImplBase` + `SendBufferMonitor`),
因此它"既是 QUIC 会话又是 Envoy 连接"
(`source/common/quic/envoy_quic_server_session.h:53-55`,
`source/common/quic/quic_filter_manager_connection_impl.h:31-33`)。要点:

- FilterManager 挂在 session 上,HCM 是最后一个 read filter;其后数据不再走
  `onData`,因为 QUICHE 已完成 stream 解复用(`quic_filter_manager_connection_impl.h:227-230`
  的注释;HCM 侧对应 `source/common/http/conn_manager_impl.cc:584-593`。
- 流控/水位:QUICHE 不在连接级缓冲,数据都在各 stream 发送缓冲里,所以
  `SendBufferMonitor` 聚合所有 stream 的 buffered 字节数,用
  `EnvoyQuicSimulatedWatermarkBuffer` 模拟连接级水位
  (`quic_filter_manager_connection_impl.h:236-243`,`:161-167`)。
- stream 数/头部限制:`setMaxIncomingHeadersCount`、
  `set_max_inbound_header_list_size`(KB→字节)由 codec 构造时传入
  (`source/common/quic/server_codec_impl.cc:30-32`)。
- H3 参数落地:`setHttp3Options` 把 keepalive ping、`memory_reduction_timeout`、
  `allow_extended_connect`、`disable_qpack`(关 Huffman/cookie crumbling、动态表容量 0)
  翻译成 QUICHE 调用(`source/common/quic/envoy_quic_server_session.cc:227-253`)。
- 握手完成时 `OnTlsHandshakeComplete` 填 `downstreamTiming` 并 raise `Connected` 事件
  (`:276-281`),0-RTT 与 1-RTT 由此区分。
- ALPN 选择:优先使用 transport socket 配置的 ALPN 列表匹配(`:305-325`),即
  `QuicServerTransportSocketFactory::supportedAlpnProtocols()`。
- overload:两个 LoadShedPoint 可在每包 dispatch 时触发 HTTP/3 GOAWAY(可选带关闭)
  (`:275-304`);overload `CloseIdleHttpConnections` 动作启用 session idle list,
  无活跃 stream 的会话入表,可被批量关闭
  (`source/common/quic/envoy_quic_dispatcher.cc:215-220`,
  `envoy_quic_server_session.cc:349-376`)。
- 漂移(drift)/生命周期:连接按 filter chain 归档到 `connections_by_filter_chain_`,
  filter chain drain 时成批关闭并同步销毁 session 防止 use-after-free
  (`envoy_quic_dispatcher.cc:186-208`);但 drain 开始时的"仅 GOAWAY 不关连接"仍是 TODO
  (`source/common/quic/active_quic_listener.cc:275-284`)。

Network::Connection 适配中的"缺席"接口(如实列举,均为硬性保护而非静默失败):
`addBytesSentCallback`→`IS_ENVOY_BUG`(TCP proxy 专用)、`readDisable`/`detectEarlyCloseWhenReadDisabled`
→`IS_ENVOY_BUG`、`write`/`rawWrite`→`IS_ENVOY_BUG`、`bufferLimit()`/`getSocket()`→`PANIC`
(`quic_filter_manager_connection_impl.h:51-55,77-85,130-139,151-159`)。

## 4. Http3CodecLayer:HTTP/3 stream → Envoy stream

`QuicHttpConnectionImplBase` 是"薄 codec":`dispatch()` 直接 `PANIC`(数据早已由 QUICHE
分发到 stream),`protocol()` 返回 `Http::Protocol::Http3`,`wantsToWrite()` 用
`bytesToSend()>0` 表达
(`source/common/quic/codec_impl.h:13-30`)。SETTINGS/GOAWAY/QPACK 等控制流都由 QUICHE 的
`QuicSpdySession` 内建处理,Envoy 层看不到"控制流"对象。工厂名
`quic.http_server_connection.default`(`source/common/quic/server_codec_impl.h:55`)。

每个入站 bidi stream 创建 `EnvoyQuicServerStream`(= QUICHE stream + `EnvoyQuicStream`
(继承 `Http::MultiplexedStreamImplBase`)+ `Http::ResponseEncoder`)
(`source/common/quic/envoy_quic_server_stream.h:19-23`,
`source/common/quic/envoy_quic_stream.h:30-31`)。`CreateIncomingStream` 中若 HCM 尚未
初始化(`codec_stats_`/`http3_options_` 缺失)直接拒绝建流
(`envoy_quic_server_session.cc:116-131`);随后 `http_connection_callbacks_->newStream(stream)`
把 stream 交给 HCM 成为 ActiveStream(`:147-155`)。头部校验(下划线、伪头白名单、
:path 唯一性)在 `validateHeader`(`envoy_quic_server_stream.cc:511-550`);
METADATA 默认不支持,`allow_metadata` 关闭时计数丢弃
(`source/common/quic/envoy_quic_stream.cc:147-152`)。
升级与 extended CONNECT:Envoy 内部统一用 H1 形式表示,发出去前 H1→H3 变换
(`envoy_quic_server_stream.cc:63-82`,变换调用在 `:78`)。

## 5. 与 TCP 路径的复用:同一 HCM

HCM 配置校验强制:QUIC listener 上只允许 `codec_type: HTTP3`,反之 HTTP3 只允许出现在
QUIC listener(`source/extensions/filters/network/http_connection_manager/config.cc:719-734`)。
`createCodec` 的 HTTP3 分支按名字取 `quic.http_server_connection.default` 工厂,并使用与
H1/H2 同构的 `Http::Http3::CodecStats`(`config.cc:820-846`)。ActiveStream 生命周期、
filter 链、路由、统计框架(`downstream_cx_http3_*`/`downstream_rq_http3_*`)全部复用
(`source/common/http/conn_manager_impl.cc:240-243,494-510,584-593,950-975`)。

H3 下缺席或受限的 HCM 能力(代码证据):
- 数据不再经过 `ConnectionManagerImpl::onData`,codec 在 `onNewConnection` 即创建
  (`conn_manager_impl.cc:584-593`)——因此依赖"首包数据"的 H1/H2 行为不适用。
- 访问日志延迟到 ACK:H3 流完成后不立即 log,而是把 headers/trailers+stream info 交给
  `QuicStatsGatherer`,在最后一个包被 ACK 后记录(可用 runtime flag 回退)
  (`conn_manager_impl.cc:360-395`,
  `source/common/quic/quic_stats_gatherer.h:18-44`,
  `envoy_quic_server_stream.cc:47-63,478-487`)。
- 连接级读暂停/写回调缺失(见第 3 节的 IS_ENVOY_BUG 列表);`dumpState` 为空实现
  (`envoy_quic_server_session.h:73-75`)。
- mTLS:QUIC transport socket 明确拒绝 client certificate
  (`source/common/quic/quic_server_transport_socket_factory.cc:27-30`)。
- codec 统计中 `incMessagingError` 为空 TODO(`source/common/http/http3/codec_stats.h:49-50`)。
- 下行 drain:shutdown 走 GOAWAY(`server_codec_impl.cc:55-62`),但 listener 级
  drain-start 只发通知不关连接的路径仍是 TODO(`active_quic_listener.cc:281-284`)。

## 6. QUIC transport socket 配置入口与证书提供

QUIC 没有"真正的 transport socket"(L4 全由 QUICHE 处理),工厂名
`envoy.transport_sockets.quic` 只提供 TLS context 配置
(`source/common/quic/quic_transport_socket_factory.h:35-39,62-67`)。服务端工厂在配置期就
创建 `Ssl::ServerContextImpl`,并把证书链/私钥转成 QUICHE 需要的 PEM+`CertificatePrivateKey`
挂在 context 上(`quic_server_transport_socket_factory.cc:15-48,51-107`)。握手期
`EnvoyQuicProofSource` 按对端地址+SNI 重新 `findFilterChain`,再向对应 filter chain 的
工厂索要 `getTlsCertificateAndKey`(SNI 匹配、SDS 未就绪计数)
(`source/common/quic/envoy_quic_proof_source.cc:88-112`,
`quic_server_transport_socket_factory.cc:160-187`)。SDS 更新通过
`setSecretUpdateCallback`→`onSecretUpdated` 原子换 context 并计数
(`quic_server_transport_socket_factory.cc:150-158,189-202`)。
keylog 与 session ticket 回调在 `OnNewSslCtx` 挂上
(`envoy_quic_proof_source.cc:119-127`)。早期数据/会话恢复开关在 transport socket 配置上,
`enable_early_data` 默认 true 但要求 resumption 同时开启
(`quic_server_transport_socket_factory.cc:32-40`;session 侧消费见
`envoy_quic_server_session.cc:258-273`)。上游侧 `QuicClientTransportSocketFactory`
持有 fallback TLS 工厂,供 conn pool 从 H3 回退 TCP 时直接产出 SSL socket
(`source/common/quic/quic_client_transport_socket_factory.h:23-39`)。

## 7. UDP 监听与 worker 模型

- 必须开 `reuse_port`:`concurrency>1` 且 UDP 未开 reuse_port 直接配置报错
  (`source/common/listener_manager/listener_impl.cc:691-696`);reuse_port 开启时给每个
  worker socket 加 `SO_REUSEPORT`(及可选 BPF CPU steering,但仅限 TCP stream
  listener,`:755-765,885-900`)。
- `udp_listener_config.quic_options` 的存在把工厂从 raw UDP 换成
  `ActiveQuicListenerFactory`,并禁止 connection_balance_config;若 OS 支持 UDP GSO 则
  自动选 `UdpGsoBatchWriterFactory`(`listener_impl.cc:707-724`)。
- per-worker socket + 内核 BPF 分流(第 2 节)是官方推荐路径;用户态跨 worker 投递
  (`post`→dispatcher)仅作为降级,注释明言性能较差
  (`active_quic_listener.cc:249-252`,`source/server/active_udp_listener.cc:35-57`)。

## 8. 0-RTT / 连接迁移 / alt-svc 支持现状

- 0-RTT(下行):支持,由 TLS session resumption 承载,`GetSSLConfig` 按 transport
  socket 配置置 `early_data_enabled`/`disable_ticket_support`
  (`envoy_quic_server_session.cc:258-273`)。0-RTT(上游):客户端握手到
  `ENCRYPTION_ZERO_RTT` 即 raise `ConnectedZeroRtt` 事件供 conn pool 使用
  (`source/common/quic/envoy_quic_client_session.cc:341-352`)。
- 连接迁移(下行/服务端):被动接受迁移——QUICHE 校验后回调
  `OnEffectivePeerMigrationValidated`,Envoy 通知 listener filter 并更新对端地址
  (`source/common/quic/envoy_quic_server_connection.cc:95-103`);可配置
  `send_disable_active_migration` 让服务端建议客户端不要迁移
  (`active_quic_listener.cc:315-317`,
  `api/envoy/config/listener/v3/quic_config.proto:84`)。统计
  `quic.connection.num_server_migration_detected` 已声明但全库未见自增点(核实:
  `envoy_quic_server_session.h:22-24` 唯一出现处),属"留了钩子未接线"。
- 连接迁移(上游/客户端):支持 port 迁移与 server preferred address 探测迁移,均可配
  (`source/common/quic/client_connection_factory_impl.cc:24-27,50-68`;
  `envoy_quic_client_session.cc:354-361`);服务端 preferred address 广播由扩展配置
  (`source/common/quic/active_quic_listener.cc:376-388,417-450`),
  命中计数 `num_packets_rx_on_preferred_address_` 在
  `envoy_quic_server_session.cc:297-300`。
- alt-svc:下游(服务端)完全不发 alt-svc——`source/common/quic/` 中无任何发送路径;
  上游通过 `alternate_protocols_cache` http filter 解析响应头 `alt-svc` 写入缓存
  (`source/extensions/filters/http/alternate_protocols_cache/filter.cc:36-59`),
  conn pool 依缓存决定是否尝试 H3(`source/common/http/conn_pool_grid.cc:575-610`,
  文档 `source/docs/http3_upstream.md:29,47`)。即:Envoy 作为服务器不会告诉客户端
  "我也有 HTTP/3",发现责任在部署侧(DNS/外部广告或客户端预置)。

## 9. 统计与 observability

- 连接关闭错误分布:`QuicStatNames` 按 `http3.{downstream|upstream}.{tx|rx}.
  quic_connection_close_error_code_<ERR>` 动态符号化计数
  (`source/common/quic/quic_stat_names.h:18-30`,触发点
  `envoy_quic_dispatcher.cc:78-88`);stream reset 错误同理
  (`quic_stat_names.h:24-25`,`server_codec_impl` 之外的
  `quic_filter_manager_connection_impl.h:183-184`)。
- dispatcher 级:`quic.dispatcher.stateless_reset_packets_sent`
  (`envoy_quic_dispatcher.h:22-26`,`envoy_quic_dispatcher.cc:40-48`)。
- codec 级:`http3.*`(goaway_sent、tx/rx_reset、下划线头拒绝、quic_version_*、
  tx_flush_timeout 等,`source/common/http/http3/codec_stats.h:16-25`)。
- ACK 延迟日志与 retransmit 计数:`QuicStatsGatherer` 挂在每个 stream 的
  ack_listener 上(`envoy_quic_server_stream.cc:44-53`,
  `quic_stats_gatherer.h:34-44,78-86`)。
- 调试钩子:`connection_debug_visitor_config` 可注入 QUICHE 连接级 debug visitor,
  内置 `envoy.quic.connection_debug_visitor.quic_stats` 扩展把 QUICHE 内部计数发布为
  Envoy stats(`active_quic_listener.cc:346-355`;
  `source/extensions/quic/connection_debug_visitor/quic_stats/quic_stats.h:42-43`)。
- 传输层字节统计:`EnvoyQuicServerConnection::OnWritePacketDone` 累加
  `write_total_`(`envoy_quic_server_connection.cc:69-76`)。

## 10. 设计动机

1. **集成 quiche 而非自研**:QUIC+TLS1.3+HPACK/QPACK 的互操作矩阵太大;quiche 是
   Chromium 生产实现,Envoy 只需实现约 10 个小适配类(clock/alarm/writer/helper/
   proof source/crypto stream),就能持续跟进行业互操作与安全修复。代码里几乎每个
   适配类都极薄(如 `envoy_quic_alarm.cc` 全文 44 行),集成成本被压到最低。
2. **H3 走同一 HCM**:HTTP/3 的差异被压缩到 codec 一层(QUICHE 负责),stream 之上
   的 filter 链、路由、可观测性完全复用,新 HTTP filter 天然对 H3 生效;代价是少数
   依赖 TCP 连接语义的能力(readDisable、bytesSent 回调、bufferLimit)必须显式
   `IS_ENVOY_BUG`/`PANIC`,把"静默错误行为"变成"立即暴露"。
3. **UDP per-worker + CID 级内核分流**:QUIC 连接没有 accept 队列,包必须按连接 id
   稳定归属同一 worker 才能维持会话状态;SO_REUSEPORT 保证多 socket 可绑同端口,
   cBPF 取 CID 首字 mod worker 数把分流下沉到内核,避免用户态跨线程搬包。CID 生成器
   做成扩展(QUIC-LB)则让前端 LB 也能按同一算法分片。
4. **每轮 loop 限 16 个新建会话 + CHLO 缓冲**:UDP 下攻击者可用伪造 CHLO 消耗
   握手 CPU;把建连切片到每轮事件循环并让剩余 CHLO 排队(`HasChlosBuffered`→
   `activateRead`)保证既有连接的包处理延迟有上界,等价 TCP listener 的
   `max_connections_to_accept_per_socket_event` 语义。
5. **部分 HCM 能力受限是刻意的**:H3 没有"字节流连接"概念,readDisable/半关闭/
   连接级缓冲在 QUIC 语义里无对应物(流控在 stream 级,拥塞在 QUICHE 内);与其给出
   错误语义的近似实现,不如让调用点崩溃/计数。同理 drain 只到 GOAYA 通知级别,
   "等连接自然迁走"的完整 drain 仍是 TODO。
6. **alt-svc 现状**:服务端发 alt-svc 意义有限(客户端需要先有一次能到达 Envoy 的
   请求,通常即 H1/H2 over TCP 同源),Envoy 选择把发现机制做成上游侧的
   alternate_protocols_cache filter + conn pool(H3→TCP 自动回退、h3 broken 追踪),
   下游广告交给部署者的前置 LB/CDN;这也是 `docs/http3_upstream.md` 只讨论上游的
   原因。
7. **证书经由 filter chain 而非静态 context**:QUIC 握手期按 SNI 重新
   `findFilterChain`,使 H3 与 TCP 共享同一套 filter chain/证书/SNI 匹配规则与 SDS
   热更新路径(工厂缓存 `ssl_ctx_` 并用读写锁保护)。

## 11. 写作素材清单(文件:行号)

1. `source/common/quic/active_quic_listener.cc:47-52` — ActiveQuicListener=UdpListenerImpl+UDP 回调
2. `source/common/quic/active_quic_listener.cc:154-188` — onDataWorker→processPacket、activateRead
3. `source/common/quic/active_quic_listener.cc:209-218` — 每轮 loop 限流建连(ProcessBufferedChlos)
4. `source/common/quic/active_quic_listener.cc:237-253` — destination():CID→worker 路由
5. `source/common/quic/active_quic_listener.cc:390-409` — BPF 分流装配与降级警告
6. `source/common/quic/envoy_quic_dispatcher.cc:95-166` — CreateQuicSession 全流程(listener filter→HCM)
7. `source/common/quic/envoy_quic_dispatcher.cc:186-208` — 按 filter chain 批量关连接+防 UAF
8. `source/common/quic/envoy_quic_alarm.cc:8-24` — quiche alarm→Event::Timer 桥
9. `source/common/quic/envoy_quic_packet_writer.cc:25-48` — quic writer→UdpPacketWriter 桥
10. `source/common/quic/envoy_quic_server_session.cc:116-155` — 入站 stream 创建与 newStream
11. `source/common/quic/envoy_quic_server_session.cc:275-304` — GOAWAY LoadShedPoint 与 preferred address 计数
12. `source/common/quic/quic_filter_manager_connection_impl.h:51-85,130-139` — Network::Connection 适配的缺席接口
13. `source/common/quic/server_codec_impl.cc:18-37` — H3 codec 构造:参数/头部限制/GOAWAY shed
14. `source/common/quic/quic_server_transport_socket_factory.cc:27-48` — mTLS 拒绝、early data/resumption 校验
15. `source/common/quic/envoy_quic_proof_source.cc:88-127` — 握手期 filter chain 匹配、keylog/ticket 回调
16. `source/common/http/conn_manager_impl.cc:584-593` — HCM 对 QUIC 的 codec 捷径(bypass onData)
17. `source/common/listener_manager/listener_impl.cc:691-724` — reuse_port 强制与 quic_options 工厂选择
18. `source/common/quic/envoy_deterministic_connection_id_generator.cc:52-90` — cBPF CID 分流程序
19. `source/common/quic/quic_stats_gatherer.h:18-44` — ACK 延迟访问日志收集器
20. `source/common/http/conn_pool_grid.cc:575-610` — 上游 alt-svc→H3 尝试判定(另配 `alternate_protocols_cache/filter.cc:36-59`)

(正文之外:本报告单一文件产出,未改动仓库任何文件。)
