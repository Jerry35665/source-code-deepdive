# 第 07 章 · QUIC 与 HTTP/3 数据面(卷二)

> 基线:tag v1.39.1(commit `b579d07d`)。纠偏:卷一提示的旧路径 quic_listeners/ 已不存在——QUIC 核心在 source/common/quic/,扩展在 source/extensions/quic/。

## 7.0 全景:分层与 quiche 桥接

```
per-worker UDP socket(SO_REUSEPORT 强制;内核 cBPF 按 CID 首字 mod worker 分流)
 → ActiveQuicListener:UdpListenerImpl 收包(GRO 默认关)→ quic_dispatcher_->processPacket
   每轮 loop 限 16 个新建会话,多余 CHLO 缓冲(QUIC 版 accept 限速)
 → EnvoyQuicDispatcher:伪 ConnectionSocket(SNI 来自 CHLO,ALPN 硬编码 "h3")
   →listener filter chain→findFilterChain→建 EnvoyQuicServerSession+HCM
 → EnvoyQuicSession = quic::QuicServerSessionBase + Network::Connection(双重身份)
 → QuicHttpServerConnectionImpl("Http3CodecLayer"薄壳):控制流/QPACK 全在 QUICHE
quiche 桥接四胶水类:EnvoyQuicAlarm(→Event::Timer)/Clock/PacketWriter/ConnectionHelper,
每个都极薄——集成 quiche 而非自研,让互操作与安全修复跟进行业
```

## 7.1 关键机制

**CID→worker 路由**:QUIC 没有 accept 队列,包必须按连接 id 稳定归属 worker。官方路径是内核 cBPF(取 CID 首字 mod worker 数选 SO_REUSEPORT socket,envoy_deterministic_connection_id_generator.cc:52-90);用户态跨 worker post 仅作降级(注释明言性能差)。**会话适配**:EnvoyQuicServerSession 同时是 QUICHE 会话与 Network::Connection;FilterManager 挂在 session 上(HCM 是最后 read filter),SendBufferMonitor 聚合各 stream 缓冲用模拟水位。TCP 语义缺席的接口(readDisable/write/bufferLimit)全部 IS_ENVOY_BUG/PANIC 硬保护——**与其给出错误语义的近似实现,不如立即暴露**。**与 TCP 复用同一 HCM**:配置校验强制 QUIC listener 只配 HTTP3 codec;访问日志延迟到 ACK(QuicStatsGatherer 挂 ack_listener)。

## 7.2 支持现状(如实)

下行 0-RTT 依赖 resumption 开关;上游支持端口迁移与 server preferred address;被动接受连接迁移(校验后更新对端地址);**mTLS 不支持**(transport socket 显式拒绝 client certificate);drain 只到 GOAWAY 通知级;**下行不发 alt-svc**(发现责任在部署侧;上游经 alternate_protocols_cache filter+conn pool 做 H3→TCP 回退);`num_server_migration_detected` 统计留了钩子未接线。

## 7.3 设计动机

1. **集成 quiche**:QUIC+TLS1.3+QPACK 互操作矩阵太大;约 10 个薄适配类换持续跟进行业;
2. **H3 走同一 HCM**:差异压缩到 codec 一层,新 HTTP filter 天然对 H3 生效;
3. **UDP per-worker+CID 内核分流**:会话状态要求稳定归属,分流下沉内核避免用户态搬包;
4. **每轮 loop 限 16 建连**:UDP 下伪造 CHLO 可耗握手 CPU,切片保证既有连接延迟有上界;
5. **受限能力显式化**:H3 没有"字节流连接"概念,流控在 stream 级拥塞在 QUICHE 内。

## 7.4 FAQ

**Q1:不用 reuse_port 能跑 QUIC 吗?**
不能:concurrency>1 且 UDP 未开 reuse_port 直接配置报错。

**Q2:H3 的流控谁管?**
QUICHE 内(stream 级);Envoy 只聚合缓冲字节数模拟连接级水位。

**Q3:0-RTT 支持吗?**
下行支持(依赖 resumption);上游握手到 ZERO_RTT 即发 ConnectedZeroRtt 事件。

**Q4:为什么访问日志要等 ACK?**
H3 流完成不等于数据送达;QuicStatsGatherer 在最后包 ACK 后记录。

**Q5:能对客户端广播 alt-svc 吗?**
不能:服务端无发送路径;上游可用 alternate_protocols_cache filter 发现。

**Q6:QUIC 的证书怎么配?**
工厂名 envoy.transport_sockets.quic 只提供 TLS context;握手期按 SNI 重新 findFilterChain 索证(SDS 热更新同路径)。

**Q7:过载时能甩 QUIC 连接吗?**
两个 LoadShedPoint 可在每包 dispatch 触发 GOAWAY;CloseIdleHttpConnections 动作入表批量关空闲会话。

**Q8:GRO 默认开吗?**
默认关;OS 支持 UDP GSO 时自动选 GSO batch writer。

**Q9:mTLS 呢?**
不支持:QUIC transport socket 拒绝 client certificate。

**Q10:连接迁移呢?**
被动支持(服务端);上游支持端口迁移与 preferred address 探测。

## 7.5 小结与深挖方向

本章结论:**QUIC="quiche 薄桥+CID 内核分流+同一 HCM+缺席接口硬保护"**。深挖:

1. QUIC-LB 扩展的连接 id 生成与前端 LB 分片协商;
2. preferred address 的扩展配置与命中计数;
3. qpack 的 disable 选项(关 Huffman/cookie crumbling/动态表 0);
4. connection_debug_visitor 扩展发布 QUICHE 内部计数;
5. filter chain drain 时批量关会话的防 UAF 细节。
