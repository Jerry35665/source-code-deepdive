# C · 网络与监听:从 accept 到 connection 的管线

> 系列:《Envoy 深读》报告 C
> 基线:tag **v1.39.1**,commit `b579d07d3ad7ee11d32b105e91a5a39ad24718d7`
> 所有 `文件:行号` 均在上述基线上逐一 Read/Grep 核对(相对仓库根)。线程/TLS/worker 模型见报告 A,本章聚焦网络层本体;配置侧(xDS/三态判定)见报告 B,本章只写网络侧动作。

## 1. 全链路图:一次 TCP 连接的完整路径

```
main 线程(配置面)                                     worker 线程 ×N(数据面,每线程一个 event loop)
──────────────────                                    ─────────────────────────────────────────────
LDS / bootstrap
  │ ListenerManagerImpl::addOrUpdateListenerInternal
  │   (listener_manager_impl.cc:594)
  ├─ ListenerImpl::create → createListenSocketFactory (1262)
  │    └─ ListenSocketFactoryImpl ctor (listener_impl.cc:93)
  │         socket[0] 创建+bind+PREBIND/BOUND 选项;
  │         reuse_port → 每个 worker 独立 socket[i](133-141)
  │         否则       → socket[0]->duplicate() 共享
  ├─ 放入 warming_listeners_,等 RDS/secrets 初始化
  │   完成 → onListenerWarmed (listener_manager_impl.cc:865)
  │     ├─ doFinalPreWorkerListenerInit:listen(backlog)+STATE_LISTENING 选项
  │     │   (listener_impl.cc:208-244)
  │     └─ addListenerToWorker ×N (843) ──post──────────▶ WorkerImpl::addListener (worker_impl.cc:72)
  │                                                        └─ ConnectionHandlerImpl::addListener (40)
  │                                                             └─ new ActiveTcpListener(
  │                                                                 getListenSocket(worker_index)) (98)
  │                                                                  └─ TcpListenerImpl 注册
  │                                                                     Level 触发 Read 事件
  │                                                                     (tcp_listener_impl.cc:164-171)
内核完成三次握手,连接进入 accept 队列(reuse_port 时每个 fd 一个独立队列)

  ▼ worker event loop 唤醒
TcpListenerImpl::onSocketEvent (tcp_listener_impl.cc:63)
  ├─ accept() 循环,上限 max_connections_to_accept_per_socket_event
  ├─ 全局连接上限 → 直接 close,downstream_global_cx_overflow++ (83-87)
  └─ cb_.onAccept(AcceptedSocketImpl) (136-138)
        ▼
ActiveTcpListener::onAccept (active_tcp_listener.cc:80)
  ├─ listener 级 open_connections 限额 → downstream_cx_overflow++ (81-87)
  └─ onAcceptWorker (109):connection_balancer 挑 worker(跨线程则 post 回目标线程)
        ▼
ActiveTcpSocket(active_tcp_socket.cc:12)──listener filters 在此运行
  ├─ continueFilterChain:tls_inspector / original_dst / proxy_proto 的
  │   onAccept()/onData() 逐个推进,可 StopIteration 等更多数据 (124-186)
  └─ newConnection (196):use_original_dst 命中则移交其他 listener;否则
        ▼
ActiveStreamListenerBase::newConnection (active_stream_listener_base.cc:27)
  ├─ FilterChainManagerImpl::findFilterChain (filter_chain_manager_impl.cc:550)
  │    dport → dip(LcTrie) → SNI → transport_proto → ALPN → direct_src → src_ip/port
  ├─ transportSocketFactory().createDownstreamTransportSocket() (45)
  ├─ dispatcher().createServerConnection → ServerConnectionImpl (46-47)
  ├─ setBufferLimits(per_connection_buffer_limit_bytes,默认 1MiB) (53)
  └─ createNetworkFilterChain:tcp_proxy / HCM 等 L4 filter 定型 (59-60)
        ▼
ActiveTcpConnection 挂入 per-filter-chain 链表,downstream_cx_active++ (78-99)
此后:ConnectionImpl::onFileEvent → onReadReady/onWriteReady → FilterManager → 业务 forever
```

左列(配置面)只发生一次;右列(accept→connection)在 worker 线程内全速运行,main 从不参与。

## 2. ListenerManager:三态与 socket 创建

ListenerManager 持有 `active_listeners_ / warming_listeners_ / draining_listeners_` 三个列表,状态枚举即 `ACTIVE | WARMING | DRAINING`(envoy/server/listener_manager.h:205-210)。报告 A 说的"三态"在网络侧的真实含义:warming=已建配置未上线,active=正在 accept,draining=不再 accept 但存量连接仍在排空。worker 构造发生在 ListenerManager 构造函数里,按 `--concurrency` 一次建齐(listener_manager_impl.cc:429-434)。

`addOrUpdateListenerInternal`(listener_manager_impl.cc:594-704)是所有变更的入口,三条分支决定去向:已有 warming 就地替换(661);已有 active 且 workers 已启动则进 warming(666-668),否则直接替换 active(670-671);全新监听则按 workers_started_ 二选一(677-683)。若新旧配置"仅 filter chain 不同"则走 in-place 路径(636-644,详见 §9)。是否允许同地址共存由 `hasListenerWithDuplicatedAddress` 把关(706-726,判定逻辑 listener_impl.cc:1284-1306)。

socket 的创建收拢在 `createListenSocketFactory`(listener_manager_impl.cc:1262-1300):`BindType` 由 `bind_to_port` 与 `reuse_port` 组合出 ReusePort/NoReusePort/NoBind(1264-1268)。真正造 socket 的是 `ListenSocketFactoryImpl` 构造函数(listener_impl.cc:93-143):

```cpp
// listener_impl.cc:122-141(节选)
auto socket_or_error = createListenSocketAndApplyOptions(factory, socket_type, 0);
...
// Now create the remainder of the sockets that will be used by the rest of the workers.
for (uint32_t i = 1; i < num_sockets; i++) {
  if (bind_type_ != ListenerComponentFactory::BindType::ReusePort && sockets_[0] != nullptr) {
    sockets_.push_back(sockets_[0]->duplicate());
  } else {
    auto socket_or_error = createListenSocketAndApplyOptions(factory, socket_type, i);
    ...
  }
}
```

即:**NoReusePort = 所有 worker 共享同一个 fd**(dup 出 N 份句柄,内核只有一个 accept 队列,epoll 唤醒竞争);**ReusePort = N 个独立 bind 的 fd**,内核按哈希把连接分到各自队列。reuse_port 的默认值解析在 `getReusePortOrDefault`(listener_impl.cc:1214-1254):`enable_reuse_port` > 旧字段 `reuse_port` > server 默认(Linux 上 TCP 默认开,1236;非 Linux 强制关并告警,1239-1248);选项本体 `SO_REUSEPORT` 由 `buildReusePortOptions` 以 PREBIND 态打上(source/common/network/socket_option_factory.cc:170-175)。热重启场景优先从父进程 `duplicateParentListenSocket` 继承 fd(listener_manager_impl.cc:375-390);更新/重加监听若与 draining 监听同地址,则克隆其 socket factory 而非重新 bind(listener_manager_impl.cc:1204-1260,克隆点 1254-1258)。

backlog 默认值 `ENVOY_TCP_BACKLOG_SIZE` 在非 Windows 为 128、Windows 为 -1(envoy/common/platform.h:329-332),可被 `tcp_backlog_size` 覆盖(listener_impl.cc:348-349)。`listen()` 不在构造时调用,而是推迟到 worker 启动前的 `doFinalPreWorkerInit`(listener_impl.cc:208-244):对每个 socket `listen(tcp_backlog_size_)` 并应用 STATE_LISTENING 态选项(216-227)。Windows 只在第一个 socket 上 accept,靠 ExactConnectionBalancer 均衡到其他 worker(233-242,与 listener_impl.cc:904-916 呼应)。

ListenerImpl 构造函数里的构建顺序本身就是一张依赖图(listener_impl.cc:471-497):FilterChainManager(471-472)→ access log(474)→ UDP listener 工厂 **先于** listen socket 选项(479-481,注释解释 UDP 工厂会追加选项)→ listener filter 工厂(482)→ filter chain 校验与构建(483-484)→ TCP 专属的 TFO 选项与内置 original_dst/proxy_proto listener filter(485-489)。异步依赖(RDS/secrets)经 `listener_init_target_` 挂到 server init manager(358-361,491-497)。

§2 值得记住的几个默认值:

- `per_connection_buffer_limit_bytes` 默认 1MiB(listener_impl.cc:342-343),它同时就是读写缓冲的水位线阈值(§7);
- `listener_filters_timeout` 默认 15s,可用 `continue_on_listener_filters_timeout` 放行兜底(listener_impl.cc:363-365);
- `tcp_backlog_size` 默认 128,Windows 下为 -1(envoy/common/platform.h:329-332);
- `max_connections_to_accept_per_socket_event` 控制单次 socket 事件的最大 accept 数(listener_impl.cc:350-352)。

## 3. 播发给 worker:ConnectionHandler::addListener

worker 起来之前,`startWorkers`(listener_manager_impl.cc:1065-1141)把每个 active listener 通过 `addListenerToWorker`(843-863)交给全部 worker;worker 侧只是 post 回自己的 dispatcher(worker_impl.cc:72-81),保证"listener 只在自己线程被物化"。全部 worker 跑起来由 `BlockingCounter` 把关(1072-1075,1134);可选的 worker CPU 亲和在此一并下发(1106-1119,`workers_pinned` gauge),它与 reuse port BPF CPU steering 共用同一份 CPU 分配(listener_manager_impl.cc:1040-1063)。ConnectionHandlerImpl::addListener(connection_handler_impl.cc:40-159)在 worker 线程内为每个地址创建 `ActiveTcpListener`,并把 **本 worker 下标对应的 socket** 交给它(`getListenSocket(worker_index)`,connection_handler_impl.cc:98;admin 等无 worker 下标的场景取 0 号,93 注释);`createListener` 工厂方法造出 `TcpListenerImpl`(395-403)并以 **Level 触发** 注册 Read 事件——注释明确说 Level 是为了防 accept 瞬时错误或达到单次 accept 上限后丢事件(tcp_listener_impl.cc:163-171)。per-address 的 listener 索引表(含 IPv4-mapped IPv6 的双向注册)在 connection_handler_impl.cc:116-158,`getBalancedHandlerByAddress` 靠它支持 original_dst 的精确/通配查找(405-440)。

若带 `overridden_listener`(in-place 更新),则只原地替换 config 指针,不重建 listener(connection_handler_impl.cc:43-52;active_tcp_listener.cc:75-78)——新连接即刻看到新配置,存量连接继续引用旧 filter chain。

## 4. accept 路径:限额、过载与均衡

`TcpListenerImpl::onSocketEvent`(tcp_listener_impl.cc:63-145)是一次"批量 accept":

```cpp
// tcp_listener_impl.cc:67-96(节选)
uint32_t connections_accepted_from_kernel_count = 0;
for (; connections_accepted_from_kernel_count < max_connections_to_accept_per_socket_event_;
     ++connections_accepted_from_kernel_count) {
  ...
  IoHandlePtr io_handle = socket_->ioHandle().accept(...);
  if (io_handle == nullptr) { break; }
  if (rejectCxOverGlobalLimit()) {
    io_handle->close();
    cb_.onReject(TcpListenerCallbacks::RejectCause::GlobalCxLimit);
    continue;
  } else if ((listener_accept_ != nullptr && listener_accept_->shouldShedLoad()) ||
             random_.bernoulli(reject_fraction_)) {
    releaseGlobalCxLimitResource();
    io_handle->close();
    cb_.onReject(TcpListenerCallbacks::RejectCause::OverloadAction);
    continue;
  }
```

单次事件上限 `max_connections_to_accept_per_socket_event`(默认值 listener_impl.cc:350-352),接受数记入 `connections_accepted_per_socket_event` 直方图(tcp_listener_impl.cc:141-143)。每个被接受的 fd 要过两道闸:

- **全局连接上限** `rejectCxOverGlobalLimit`(tcp_listener_impl.cc:21-54):优先用 OverloadManager 的 `GlobalDownstreamMaxConnections` 资源分配(42-43),否则回退到 runtime key `overload.global_downstream_max_connections` 与进程级原子计数 `AcceptedSocketImpl::acceptedSocketCount()` 比较(50-52)。命中即 `io_handle->close()` 并 `onReject(GlobalCxLimit)`(83-87)。计数在 AcceptedSocketImpl 构造/析构中增减(listen_socket_impl.h:204-221)。
- **主动负载规避**:LoadShedPoint `tcp_listener_accept` 或按 `reject_fraction_` 伯努利采样拒绝(88-96),对应 OverloadManager 的 RejectIncomingConnections 动作(经 `setListenerRejectFraction` 下发,tcp_listener_impl.cc:190-192;worker 注册动作见报告 A §6)。

listener 自身还有 `open_connections_` 资源限额(runtime key `envoy.resource_limits.listener.<name>.connection_limit`,listener_impl.cc:371-375),检查点在 `ActiveTcpListener::onAccept`(active_tcp_listener.cc:80-92,active_tcp_listener.h:41-45),溢出计 `downstream_cx_overflow`。两类拒绝的计数都落在 `onReject`(active_tcp_listener.cc:94-103)。accept 前还会尽力取一次 RTT 存入 StreamInfo(active_tcp_listener.cc:113-117)。

accept 之后连接仍可能**换 worker**:`onAcceptWorker` 先问 connection_balancer(active_tcp_listener.cc:119-126),Exact/Extend 平衡器可把 socket post 到别的线程(168-186,用 shared_ptr 包住 unique_ptr 跨线程传);`use_original_dst` 恢复出原始目的地后,`newConnection` 也会按地址找到另一 listener 移交(active_tcp_socket.cc:202-229)。一旦落定,连接终身固定在该 worker。

## 5. listener filters:ActiveTcpSocket 阶段

ActiveTcpSocket 是"已 accept、未成为 connection"的中间态,构造即计 `downstream_pre_cx_active`(active_tcp_socket.cc:22),并启动 `listener_filters_timeout`(默认 15s,listener_impl.cc:363-364)看门狗(active_tcp_socket.cc:66-71;超时按 `continue_on_listener_filters_timeout` 决定放行还是放弃,53-64)。listener filter 的协议是 `onAccept(ListenerFilterCallbacks&)`(envoy/network/filter.h:456)加可选的 `onData(ListenerFilterBuffer&)`(467),`maxReadBytes()`(481)声明需要 peek 的字节数;`addAcceptFilter` 保证 FIFO 顺序(filter.h:489-501)。

`continueFilterChain`(active_tcp_socket.cc:124-186)就是这些 filter 的调度器:filter 返回 StopIteration 时创建 `ListenerFilterBuffer` 阻塞式 peek 等待更多数据(85-122,147-169),容量按各 filter 的 maxReadBytes 动态扩(150-156);数据到位或对端关闭时从断点继续(98-121 的两个回调)。全部通过后 `newConnection()`(174-175)。socket 若中途被 filter 关闭,access log 依然会发出——`unlink()` 里对未建成连接 `emitLogs`(73-83,日志实现 active_stream_listener_base.cc:19-25)。这一阶段采集的 SNI(tls_inspector)、ALPN、proxy protocol、原始目的地,正是第 6 节 filter chain 匹配的输入;若无 filter 设置传输协议,默认补 `raw_buffer`(active_tcp_socket.cc:231-234)。

## 6. filter chain 选择与连接定型

定型的完整链路在 `ActiveStreamListenerBase::newConnection`(active_stream_listener_base.cc:27-67):找不到匹配 chain 则 `no_filter_chain_match`++ 并关连接(31-40);找到则实例化下游 transport socket,经 `dispatcher().createServerConnection` 造出 `ServerConnectionImpl`(46-47;dispatcher 侧 dispatcher_impl.cc:147-154),随后 `createNetworkFilterChain`(59-60)——它转回 ListenerImpl 的实现(listener_impl.cc:1061-1071),最终由 `FilterChainUtility::buildFilterChain` 逐个执行工厂并 `initializeReadFilters()`(configuration_impl.cc:32-45,即对每个 ReadFilter 调 `onNewConnection`,envoy/network/filter.h:273)。L4 filter 的数据协议就是 `onData(Buffer&, bool end_stream)` / `onWrite(...)`(filter.h:265, 146)。链上任何一个 filter 在构造/回调里同步关连接都会中断定型(空链时显式 NoFlush 关闭,active_stream_listener_base.cc:61-65)。

匹配本身在 `FilterChainManagerImpl::findFilterChain`(filter_chain_manager_impl.cc:550-583):优先用 xDS matcher 树(553-554),否则按 **目的端口(562-572)→ 目的 IP(LcTrie,599-614)→ SNI 精确/通配/catchall(616-645)→ 传输协议(647-665)→ ALPN(667-685)→ 直连源 IP(687-702)→ 源类型/源 IP/源端口(704-770)** 的漏斗收窄,全部落空回退 default_filter_chain(579-582);重复匹配规则在建链时即被拒绝(175-207),IP/源条件最终编译成 LcTrie 加速前缀匹配(772-833)。chain 的构建在 `ListenerFilterChainFactoryBuilder::buildFilterChainInternal`(filter_chain_manager_impl.cc:873-936):未配 transport socket 时默认补 raw_buffer(881-886),然后 transport socket 工厂 + network filter 工厂列表 + connect 超时打包成 `FilterChainImpl`(921-935);in-place 更新时未变化的 chain 直接复用(`findExistingFilterChain`,835-849,在 addFilterChains:143-150 调用)。关键在于:**chain 与 filter 实例的决策发生在连接建立时刻,之后这条连接的过滤管线不可更换**——只有 in-place 更新会让"新连接"看到新配置。

## 7. ConnectionImpl:读写事件与水位线

ConnectionImpl 构造时创建一对带水位线回调的缓冲区,并注册文件事件(source/common/network/connection_impl.cc:69-112;触发类型取平台默认 94,事件注册 98-104):

```cpp
// connection_impl.cc:75-82(节选)
write_buffer_(dispatcher.getWatermarkFactory().createBuffer(
    [this]() -> void { this->onWriteBufferLowWatermark(); },
    [this]() -> void { this->onWriteBufferHighWatermark(); }, ...),
read_buffer_(dispatcher.getWatermarkFactory().createBuffer(
    [this]() -> void { this->onReadBufferLowWatermark(); },
    [this]() -> void { this->onReadBufferHighWatermark(); }, ...)),
```

事件分发 `onFileEvent`(719-763):Write 先行(连接建立/可写,869-891 处理 connect 完成),Read 后行;`Closed` 位代表对端早期关闭(739-752)。读路径 `onReadReady`(765-847)→ transport socket `doRead` 进 read_buffer_(800-802)→ `onRead`(447-479)→ `filter_manager_.onRead()` 推入 filter 链(478);写路径 `write()`(594-639)先过 `filter_manager_.onWrite()`(613),再把数据 move 进 write_buffer_(630)并激活 Write 事件(636-637)。

水位线的阈值在 `setBufferLimits`(641-660)设置:读/写缓冲共用 `per_connection_buffer_limit_bytes`(默认 1MiB,listener_impl.cc:342-343);`WatermarkBuffer::setWatermarks` 取 `low = high/2`(watermark_buffer.cc:127-129),并且注释解释了为何故意"超一点才触发"(connection_impl.cc:644-658)——common case 一次搬运恰好 limit 字节,不希望每个 chunk 都打穿水位线。传导方向有两条:

- **读侧**:read_buffer_ 越 high watermark → `readDisable(true)`(687-693),把内核 epoll 的 Read 位摘掉、只留 Write/Closed(504-525),背压落在内核接收队列;低于 low watermark → `readDisable(false)`(679-685)恢复。`read_disable_count_` 支持嵌套(490-560),恢复时若缓冲仍有数据会主动激活假读事件(542-556)。
- **写侧**:write_buffer_ 越 high watermark → `onFilterAboveHighWatermark`(703-709)→ 计数归一后向 ConnectionCallbacks 广播 `onAboveWriteBufferHighWatermark`(connection_impl_base.cc:89-98);filter 内部(如 HCM)再把信号沿 L7 链上传(filter_manager_impl.h:197-202),最终让上游停止写入。低于 low 时对称恢复(100-110)。另外 `per_connection_buffer_high_watermark_timeout` 提供兜底:长期高于水位线的连接被强杀(260-294,配置入口 listener_impl.cc:344-345)。

## 8. 关闭语义:NoFlush / FlushWrite / FlushWriteAndDelay / Abort / AbortReset

五种 close 类型定义于 envoy/network/connection.h:80-89。分发逻辑在 `close()`(connection_impl.cc:154-181):

```cpp
// connection_impl.cc:162-180(节选)
if (type == ConnectionCloseType::AbortReset) {
  setDetectedCloseType(StreamInfo::DetectedCloseType::LocalReset);
  closeSocket(ConnectionEvent::LocalClose);
  return;
}
if (type == ConnectionCloseType::Abort || type == ConnectionCloseType::NoFlush) {
  closeInternal(type);
  return;
}
// Only FlushWrite and FlushWriteAndDelay are managed by the filter manager, since the above
// status will abort data naturally.
ASSERT(type == ConnectionCloseType::FlushWrite ||
       type == ConnectionCloseType::FlushWriteAndDelay);
closeThroughFilterManager(ConnectionCloseAction{ConnectionEvent::LocalClose, false, type});
```

`closeInternal`(183-258)的决策表:无待写数据、NoFlush/Abort、或 transport 不支持 flush-close → 尽力 `doWrite` 后立即关(193-203);否则进入 **delayed close** 状态机:CloseAfterFlush(写完即关)或 CloseAfterFlushAndWait(写完再等 `delayed_close_timeout`,定时器建在 connection_impl_base.cc:55-61,超时强关并计 `delayed_close_timeouts_`,79-87)。重复 close 只是降级状态(233-243),等待期间只监听对端关闭位(215,256-257)。真正的 fd 关闭与事件上抛在 `closeSocket`(346-399):transport 关闭(361)→ 缓冲统计清零(364-365)→ 丢弃残余写数据(371)→ `raiseEvent(LocalClose/RemoteClose)`(398)。RST 检测(`DetectedCloseType::RemoteReset`)在读/写两条路径均有特判(805-819,899-905);下游 transport socket 连接超时是 Server 侧专属兜底(1046-1059,1074-1084)。

## 9. warming → drain 与 in-place 更新(网络侧动作)

**常规迁移**:`ListenerImpl::initialize` 在 workers 已启动时改用 per-listener init manager(listener_impl.cc:1112-1123);本地初始化完成后 `local_init_watcher` 触发 `onListenerWarmed`(376-385 → listener_manager_impl.cc:865-897)——先对全部 worker `addListenerToWorker`(875-877,新 listener 已可 accept),再置换 active 列表并把旧 listener 交给 `drainListener`(883-891)。`drainListener`(728-779)依次:`stopListener` 停 accept(740;完成回调里 `maybeCloseSocketsForListener` 关 fd,1302-1321——TCP 立即关 socket 让 accept 队列里的连接快速失败)→ 对存量连接广播 `onDrain`(751-753,最终逐连接调用 active_stream_listener_base.cc:179-192)→ 启动 drain sequence,超时后各 worker `removeListener`,完成计数 post 回 main 线程递减(757-776)。admin 触发的整体停机(`stopListeners`,InboundOnly/All)走同一原语并计 `listener_stopped`(1156-1189,计数 1178)。

**in-place filter chain 更新**:判定条件 `supportUpdateFilterChain`——workers 已启动、非 FCDS、新旧配置除 filter_chains/default_filter_chain/matcher 外完全一致且 reuse_port 未变(listener_impl.cc:1146-1181)。命中则 `newListenerWithFilterChain` 克隆出仅 chain 不同的新 ListenerImpl(1183-1195;克隆构造复用 origin 的 socket_factory/context/balancer,500-566),warming 完成后 `inPlaceFilterChainUpdate`(listener_manager_impl.cc:899-927)对每个 worker 以 `overridden_listener` 触发原地 `updateListenerConfig`(connection_handler_impl.cc:43-52);被替换的 chain 逐个 `startDraining` 并走 `drainFilterChains`(929-984):对存量连接 onDrain、超时后 `removeFilterChains` 强关(worker 侧 `removeFilterChain` NoFlush 逐个关闭,active_stream_listener_base.cc:194-210)。整个过程 listen socket 与 listener 对象零重建,`listener_in_place_updated`++(listener_manager_impl.cc:644)。

## 10. UDP 监听路径(类级)

UDP 与 TCP 分叉点在 `ListenerImpl::buildUdpListenerFactory`(listener_impl.cc:685-739):`concurrency>1 且未开 reuse_port` 直接配置报错(691-697);按是否配 `quic_options` 选 QUIC 的 ActiveQuicListenerFactory(714-716)或 raw UDP 的 `ActiveRawUdpListenerFactory`(731-734,创建入口 active_raw_udp_listener_config.cc:15-23);发包侧可插拔 writer 工厂,QUIC 下还可启用 GSO 批量写(700-706,723-726,735-737)。同时为每个地址建 per-worker 的 `UdpListenerWorkerRouter`(671-683),把"四元组会话 → worker"固定下来。worker 侧 ConnectionHandler 走 UDP 分支创建 ActiveUdpListener(connection_handler_impl.cc:102-113);底层 `UdpListenerImpl` 构造时注册文件事件并支持"父进程未排空前暂停收包"(udp_listener_impl.cc:33-59,unpause 61-71),`onSocketEvent → handleReadCallback` 里用 `readPacketsFromSocket`(recvmmsg/GRO)批量收包交给 UdpListenerFilters 与 udp_proxy,并跟踪 `packets_dropped_`(91-115)。socket 选项侧 UDP 额外要求 IP_PKTINFO、RXQ_OVFL、UDP_GRO、Do-Not-Fragment 等(listener_impl.cc:776-802)。

## 11. socket 选项:三态生命周期与免费抽象

Envoy 把 setsockopt 抽象成"选项对象 + 生效状态":`SocketOptionImpl::setOption` 只在 `in_state_` 匹配时真正调用 syscall,选项名不受平台支持时优雅跳过或告警(source/common/network/socket_option_impl.cc:17-47)。三个状态按 socket 生命周期依次应用:PREBIND(NetworkListenSocket 构造内 `setPrebindSocketOptions` + `setupSocket`=选项→bind,listen_socket_impl.h:46-69 与 listen_socket_impl.cc:50-53)、BOUND(`createListenSocketAndApplyOptions` 在 bind 后 applyOptions 再把选项挂回 socket 备用,listener_impl.cc:182-197)、LISTENING(`doFinalPreWorkerInit` 里 listen() 之后,listener_impl.cc:220-227)。`transparent`/`freebind` 分别生成 IP_TRANSPARENT/IP_FREEBIND 的 v4+v6 双族选项(socket_option_factory.cc:52-61,44-50),与 `tcp_keepalive`、用户字面 socket_options、TFO 一起在 `buildListenSocketOptions` 汇总(listener_impl.cc:741-804)。这套抽象的副产品:每个选项可携带 `hashKey`/`getOptionDetails`(socket_option_impl.cc:49-68),从而参与 filter chain 等价比较与 /config_dump 展示;"免费"指的是扩展作者声明选项即可,热重启继承、克隆、dup 都由框架代劳。

## 12. 生命周期杂项:销毁、日志与计数

- **连接移除**:`ActiveTcpConnection::onEvent` 收到 Local/RemoteClose 即从 per-chain 链表摘除并 `deferredDelete`(active_stream_listener_base.cc:116-144);链表空则连 ActiveConnections 容器一起延迟销毁(132-143)——延迟删除贯穿整个销毁路径,保证回调安全。
- **listener 销毁**:`ActiveTcpListener` 析构时把未进展成 connection 的 socket 逐个 deferredDelete,再对存量连接 NoFlush 强关(active_tcp_listener.cc:43-73);handler 级连接计数 `numConnections` 由 ListenerManager 汇总供 admin/调试(listener_manager_impl.cc:986-993)。
- **chain 移除完成回调**:worker 侧 `removeFilterChains` 触发 `onFilterChainDraining` 后,完成回调经 `deferredRun` 推迟一拍执行,确保引用该 chain 的活跃连接先于删除收尾(connection_handler_impl.cc:239-254)。
- **停止 accept 不等于销毁**:stopListeners 只摘 Read 位(`shutdownListener` 把 Network::Listener 置空,active_tcp_listener.h:65-67),监听对象与存量连接仍在,等 drain 计时结束后才由 removeListener 链路拆除。
- **日志**:连接正常结束由析构触发 `emitLogs`(active_stream_listener_base.cc:101-114);连 filter chain 都没匹配上的 socket 也有一份访问日志(§5),保证"进来过的连接都有据可查"。

## 13. stats:计数器的增减点

- **per-listener**:`listener.<address>.` scope 在 ListenerImpl 构造时创建,支持 per-listener StatsMatcher 裁剪(listener_impl.cc:249-297);指标全集 `ALL_LISTENER_STATS`(source/server/listener_stats.h:11-24),scope 挂载点在 source/server/active_listener_base.h:17-24。`downstream_cx_total/active` 在 ActiveTcpConnection 构造 ++(连同 per-worker 前缀计数,active_stream_listener_base.cc:89-98),析构 `active--`、`destroy++`、时长直方图 complete(101-114);`downstream_pre_cx_active` 对应 ActiveTcpSocket 阶段(active_tcp_socket.cc:22,38);`downstream_cx_overflow`(active_tcp_listener.cc:86)、`downstream_global_cx_overflow`(97)、`downstream_cx_overload_reject`(100)、`no_filter_chain_match`(active_stream_listener_base.cc:35)如前文各节。
- **listener_manager**:add/remove/warming 等计数与 gauge 定义在 listener_manager_impl.h:152-165,`updateWarmingActiveGauges` 在每次列表变动后刷新(301-306);`listener_create_success` 在 worker 完成回执中 ++(listener_manager_impl.cc:855-857),失败集中在 `incListenerCreateFailureStat`(315-320)。
- **connection 级**:read/write_total/current 由 `updateBufferStats` 在每次 IO 后维护(connection_impl.cc:964-982)。

## 14. 设计动机

1. **为什么 per-worker 独立 accept(SO_REUSEPORT)?** 每个 worker 一个独立内核队列,accept 无跨线程竞争、无惊群;同时 fd 队列彼此隔离要求更新时必须 clone 旧 fd 而非新 bind——否则关闭旧 socket 会 RST 队列中的存量连接(listener_impl.cc:152-165 的长注释),这也是"reuse_port 不能热改"(listener_manager_impl.cc:581-584)与"地址兼容才能克隆 socket factory"(listener_manager_impl.cc:1254-1258)的根本原因。
2. **为什么水位线而不是背压消息?** 数据面的生产者-消费者都在同一线程的 event loop 里,per-chunk 通知只会增加调度;水位线把"该停了/该续了"压缩成两个阈值事件,读侧直接下沉到内核 epoll 状态(摘掉 Read 位,connection_impl.cc:504-525),写侧沿 filter 链上传一次计数广播(connection_impl_base.cc:89-98)。`low = high/2` 的滞回(watermark_buffer.cc:127)避免在阈值附近抖动;这正是 TCP 滑动窗口背压在用户态的延伸,而不是一套自定义消息协议。
3. **为什么 filter 链在连接建立时定型?** findFilterChain 的输入(SNI/ALPN/原始目的地)只在 listener filter 阶段可测;定型后每个连接只需一张静态管线,数据路径零查表、零条件分支,per-filter-chain 分组的连接表(active_stream_listener_base.cc:146-153)也让 drain 可以按 chain 精确进行。配置变更通过"in-place 换 chain + 存量连接 drain"达成灰度,而不是让运行中的连接重新协商。
4. **为什么 overflow 直接拒绝而不排队?** accept 队列(哪怕是用户态 ActiveTcpSocket 列表)里的连接已经消耗内核内存与 fd;Envoy 的选择是在最早可判点(TcpListenerImpl 全局限、ActiveTcpListener 局部限)直接 close,把排队交还内核 backlog,把"拒绝"变成可观测的 `downstream_cx_overflow`/`downstream_global_cx_overflow`,配合 OverloadManager 的 RejectIncomingConnections 形成分级降级。
5. **为什么 listener 要 warming/active/drain 三态?** listener 依赖异步资源(RDS、secret、动态 filter);若先停旧再建新,会有窗口期无人 accept。warming 让新 listener 在后台备妥,`onListenerWarmed` 先上线新的再排空旧的(listener_manager_impl.cc:865-891),实现零中断;drain 期只关 accept 不杀存量连接,把连接生命周期与配置生命周期解耦。
6. **为什么 in-place 更新只换 filter chain?** 绝大多数 LDS 变更只是证书/路由级 chain 调整,ListenerImpl/socket/balancer 全部可以复用(listener_impl.cc:500-566);把 diff 收敛到 chain 一层,网络侧动作就只剩"worker 原地换 config 指针 + 对消失的 chain 广播 drain",避免了整套 listener 重建带来的 accept 抖动与端口重绑定。
7. **为什么 socket 选项要建模成三态对象?** 同一选项在不同阶段语义不同(如 IP_TRANSPARENT 需 PREBIND+BOUND 两次,socket_option_factory.cc:52-61),而 listen() 必须推迟到 worker 启动前(listener_impl.cc:208-244);状态化对象让"创建于 main、生效于 worker 前后"的时序由框架保证,扩展作者只声明状态,不必理解热重启/克隆/dup 流程。

## 15. 三个常见误解的澄清

- "accept 发生在 main 线程"——错。main 线程只负责创建/bind socket(listener_manager_impl.cc:1262-1300)与 listen(208-244);accept 的文件事件注册在每个 worker 自己的 dispatcher 上(tcp_listener_impl.cc:164-171),谁的事件循环醒来谁 accept。
- "水位线触发会丢数据/暂停回调"——错。读侧只是摘掉 epoll 的 Read 位、把背压留给内核(connection_impl.cc:504-525),已缓冲数据照常推进 filter 链;写侧只是广播 onAboveWriteBufferHighWatermark(connection_impl_base.cc:89-98),不丢弃任何字节。
- "NoFlush = 不写任何数据"——不准确。NoFlush 仍会先尽力 `doWrite` 一次再立即关连接(connection_impl.cc:193-199);真正一个字节都不写的是 Abort/AbortReset。
- "in-place 更新会重建监听 socket"——错。克隆构造直接复用 origin 的 socket factory、connection balancer 与 factory context(listener_impl.cc:500-566,540-543),网络侧只有 worker 上的 config 指针替换与 chain 级 drain。

## 16. 初读路线(追一条路径)

- accept→connection 全程:tcp_listener_impl.cc:63 → active_tcp_listener.cc:80 → active_tcp_socket.cc:124 → active_stream_listener_base.cc:27。
- 一次 LDS 变更的网络侧动作:listener_manager_impl.cc:594(入口)→ 865(warming 完成)或 899(in-place)→ 728(drain)。
- 一次写路径水位线传导:connection_impl.cc:594(write)→ 703(high watermark)→ connection_impl_base.cc:89(广播)→ filter_manager_impl.h:197(filter 侧回调)。
- 一次排空:listener_manager_impl.cc:728 → active_stream_listener_base.cc:179(onDrain 广播)→ 194(chain 移除强关)。

## 17. 写作素材清单(文件:行号)

1. source/common/listener_manager/listener_impl.cc:122-141 — reuse_port 与 NoReusePort 的 per-worker socket 分叉
2. source/common/listener_manager/listener_impl.cc:152-165 — SO_REUSEPORT 队列隔离与克隆 fd 的长注释(必引)
3. source/common/listener_manager/listener_impl.cc:208-244 — doFinalPreWorkerInit:listen(backlog)+STATE_LISTENING 选项
4. source/common/listener_manager/listener_impl.cc:471-497 — ListenerImpl 构造的组件构建顺序(UDP 工厂先于选项)
5. source/common/listener_manager/listener_manager_impl.cc:865-897 — onListenerWarmed:先上线新 listener 再 drain 旧的
6. source/common/listener_manager/listener_manager_impl.cc:899-984 — inPlaceFilterChainUpdate + drainFilterChains 全流程
7. source/common/listener_manager/connection_handler_impl.cc:83-101 — worker 侧 ActiveTcpListener 创建与 per-worker socket 选择
8. source/common/network/tcp_listener_impl.cc:63-145 — onSocketEvent:批量 accept、全局限、load shed、onAccept
9. source/common/listener_manager/active_tcp_listener.cc:109-132 — onAcceptWorker:balancer 挑选与跨线程 post
10. source/common/listener_manager/active_tcp_socket.cc:124-186 — continueFilterChain:listener filter 的暂停/续跑状态机
11. source/common/listener_manager/active_stream_listener_base.cc:27-67 — newConnection:findFilterChain→transport→Connection→filters
12. source/common/listener_manager/filter_chain_manager_impl.cc:550-583 — findFilterChain 匹配漏斗与 default 兜底
13. source/common/listener_manager/filter_chain_manager_impl.cc:873-936 — buildFilterChainInternal:transport 工厂 + filter 工厂列表定型
14. source/common/network/connection_impl.cc:641-660 — setBufferLimits 及"为何超一点才触发水位线"注释
15. source/common/network/connection_impl.cc:183-258 — closeInternal:NoFlush/FlushWrite/delayed close 决策表
16. source/common/buffer/watermark_buffer.cc:119-131 — setWatermarks:low=high/2 与 overflow 乘子
