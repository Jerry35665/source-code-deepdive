# D. HTTP 连接管理与路由：从字节流到 upstream 请求

> 基线：tag v1.39.1，commit b579d07d3ad7ee11d32b105e91a5a39ad24718d7。所有行号均以该检出为准。
> 本报告覆盖：HCM（HttpConnectionManagerImpl）→ codec → ActiveStream → decoder filter 链 → router filter → 选中 cluster 并发起连接池请求为止。连接池/LB 内部细节见报告 E。

## 0. 全景图：一条 HTTP 请求的完整路径

```
                              网络字节流 (Network::Connection)
                                        │
                    ┌───────────────────▼────────────────────┐
                    │ HCM = ConnectionManagerImpl             │  作为 Network::ReadFilter
                    │  onData()          conn_manager_impl.cc:515
                    │  onNewConnection()             :584 (仅 QUIC 建codec)
                    │  createCodec() 一次创建 codec   :494     │
                    └───────┬────────────────────┬────────────┘
              HTTP/1.1      │                    │      HTTP/2 (codec_type_ AUTO/HTTP2)
                            ▼                    ▼
        ┌───────────────────────────┐  ┌───────────────────────────────────┐
        │ Http1::ServerConnectionImpl│  │ Http2::ServerConnectionImpl        │
        │  dispatch()      :1305     │  │  dispatch() nghttp2/oghttp2 适配   │
        │  onMessageBegin → newStream│  │  onBeginHeaders → 每个 stream_id   │
        │   (ActiveRequest, 1 连接=1 │  │   newStream → ServerStreamImpl     │
        │    请求, :1268)            │  │   (多路复用, :2508)                │
        │  onHeadersComplete:1197    │  │  ServerStreamImpl::decodeHeaders   │
        │  onBody            :1293   │  │   :710 / decodeTrailers :725       │
        └───────────┬───────────────┘  └───────────────┬───────────────────┘
                    │   RequestDecoder 回调（ActiveStream 即 RequestDecoder, h:149）
                    └───────────────┬──────────────────┘
                                    ▼
              ActiveStream (conn_manager_impl.h:145, 一请求一对象)
               decodeHeaders() :1354 ── 头规范化/路由快照/建 filter 链
               decodeData() :1639 / decodeTrailers() :1656
               计时器: stream idle :968 / request :976 / headers :983 / max duration :991
                                    │
                                    ▼
              FilterManager (filter_manager.cc)
               decodeHeaders :610 → decodeData :716 → decodeTrailers :882
               按 decoder_filters_ 顺序迭代, StopIteration 缓存数据, continueDecoding 续跑
                                    │
                                    ▼
              Router Filter (router.cc Filter::decodeHeaders :477)
               routeSharedPtr 路由匹配 :508 → direct response :520
               → cluster 查找 :565 → finalTimeout/预算 :643
               → chooseHost :726 → createConnPool :971
               → UpstreamRequest + conn_pool_->newStream(this)
                       (upstream_request.cc:458)                    │
                                    │                                │ shadow/mirror
                                    ▼                                ▼ (async_client, :906)
              HttpConnPoolImplBase::newStream (conn_pool_base.cc:60)
               → onPoolReady/onPoolFailure → PoolCallbacks (报告 E 续)
```

## 1. HCM：网络过滤器形态的连接管理器

HCM 是挂在 TCP 连接上的 `Network::ReadFilter`。第一包到达时 `onData` 发现还没有 codec，先 `createCodec`，之后每个数据片都交给 `codec_->dispatch(data)` 解析（source/common/http/conn_manager_impl.cc:515-582）。codec 选择发生在 config 层：`HttpConnectionManagerConfig::createCodec` 按 `codec_type_` 直接 new 出 HTTP/1、HTTP/2 或 QUIC codec；AUTO 则调用 `autoCreateCodec`，用 ALPN/首字节嗅探判断（source/extensions/filters/network/http_connection_manager/config.cc:820-857；source/common/http/conn_manager_utility.cc:88-109）。

```cpp
// source/common/http/conn_manager_impl.cc:542
bool redispatch;
do {
  redispatch = false;
  const Status status = codec_->dispatch(data);
  ...
  // The HTTP/1 codec will pause dispatch after a single message is complete. We want to
  // either redispatch if there are no streams and we have more data.
  if (codec_->protocol() < Protocol::Http2) {
    if (read_callbacks_->connection().state() == Network::Connection::State::Open &&
        data.length() > 0 && streams_.empty()) {
      redispatch = true;
    }
  }
} while (redispatch);
```

这段 do/while 正是 HTTP/1.1 "一连接一请求"在 HCM 侧的体现：codec 每解析完一条消息就暂停，HCM 只在没有在途流且缓冲区仍有数据时才重新 dispatch；HTTP/2 一次 dispatch 即处理全部多路复用帧。

连接生命周期事件由 `onEvent` 统一处理（conn_manager_impl.cc:624-658），连接级超时有三个入口：`onIdleTimeout`（无 codec 直接关连接，有 codec 走 drain 序列，:785-796）、`onConnectionDurationTimeout`（最长连接时长，可对 HTTP/1 做 soft drain，:798-817）、`onDrainTimeout`（发出 GOAWAY 后进入 Closing，:819-824）。流级超时则挂在每个 ActiveStream 上（见 §3）。

HCM 在连接上维护 `streams_`（`LinkedObject<ActiveStream>` 链表，conn_manager_impl.h:145）。流结束统一走 `doEndStream`：判定这条流是否是连接上最后一条、是否需要延迟关闭连接，之后 `doDeferredStreamDestroy` 把流对象交给 dispatcher 延迟删除（conn_manager_impl.cc:269-331, :331+），避免栈展开期间悬挂引用——这就是"流对象随时可能被异步回调触碰"场景下的安全网。HTTP/1 还有一类连接级防护：`ServerConnectionImpl::doFloodProtectionChecks` 统计一条连接上乱序/无响应的流水线请求，超限直接协议错误关连接（source/common/http/http1/codec_impl.cc:336+, 调用点 :1278）；HCM 侧另有 `maybeDrainDueToPrematureResets`——同一条连接上过早 RST 的流过多时主动 drain 整条连接（conn_manager_impl.cc:731-778）。

## 2. Codec 抽象：解码回调如何变成 RequestDecoder

codec 的对外接口只有 `dispatch` / `newStream` / `encodeXxx`（envoy/http/codec.h），HCM 完全不感知具体协议。codec_wrappers.h 提供了解码器包装层：`ResponseDecoderWrapper` 在转发给 inner decoder 的前后插入 `onPreDecodeComplete/onDecodeComplete` 钩子，且通过 `ResponseDecoderHandle` 检查 inner decoder 存活（source/common/http/codec_wrappers.h:14-61, 107-117）——router 侧的 UpstreamRequest 正是用它包装 upstream codec 回调。`RequestEncoderWrapper` 同理在 `end_stream` 时回调 `onEncodeComplete`（同文件:131-187）。

**HTTP/1.1：连接=流。** Server 端只有单个 `active_request_`。`onMessageBeginBase` 创建 `ActiveRequest` 并向 HCM 申请流：`callbacks_.newStream(active_request_->response_encoder_)`（source/common/http/http1/codec_impl.cc:1268-1281）。解析器回调直接映射为 decoder 调用：`onHeadersCompleteBase` 规范化 method/path 后调 `decoder->decodeHeaders(headers, false)`（无 body 时延迟到 message complete，:1240-1262），`onBody` 调 `decodeData(data, false)`（:1293-1303），`onMessageCompleteBase` 发出带 end_stream 的最后一块（:1332+）。收到新请求但上一条未完成时，HTTP/1 codec 主动 `readDisable(true)` 停读 socket，形成背压（:1305-1330）。

**HTTP/2：连接≠流。** 每个 HEADERS 帧开头的 stream_id 都会独立建流：`ServerConnectionImpl::onBeginHeaders` new 出一个 `ServerStreamImpl`，并 `setRequestDecoder(callbacks_.newStream(*stream))`（source/common/http/http2/codec_impl.cc:2508-2525）。解码由 oghttp2 适配器回调驱动：`ServerStreamImpl::decodeHeaders` 调 `request_decoder->decodeHeaders(std::move(headers), sendEndStream())`，`decodeTrailers` 同理（:710-739）；响应方向 `ClientStreamImpl::decodeHeaders` 区分 1xx 与正式响应（:646-679）。客户端方向对称：`ClientConnectionImpl::newStream(ResponseDecoder&)` 返回 `RequestEncoder`（:2418），连接池正是用它把 upstream codec 与 router 的 ResponseDecoder 焊在一起。

注意两个方向的角色反转：downstream 侧 codec 实现 `ServerConnection`（解码请求、编码响应），upstream 侧的同一个 codec 类族实现 `ClientConnection`（`newStream` 消费一个 ResponseDecoder，把 encodeXxx 序列化上送）。`CodecClient`（source/common/http/codec_client.cc）再把这个 client codec 包成连接池可用的实体；连接池的 attach 点就是 `codec_client_->newStream(response_decoder)`（source/common/http/conn_pool_base.cc:220）。

## 2.1 HTTP/1.1 与 HTTP/2 差异在代码中的分布

| 维度 | HTTP/1.1 | HTTP/2 |
|---|---|---|
| 流的创建 | `onMessageBeginBase` 每连接至多一个 `ActiveRequest`（http1/codec_impl.cc:1268-1281） | `onBeginHeaders` 每个 stream_id 一个 `ServerStreamImpl`（http2/codec_impl.cc:2508-2525） |
| dispatch 节奏 | 每条消息暂停，HCM 无在途流才 redispatch（conn_manager_impl.cc:565-575） | 一次 dispatch 处理所有帧（http2/codec_impl.cc:1093+） |
| 背压 | 解析到下一条流水线请求即 `readDisable(true)`（http1/codec_impl.cc:1311-1328） | 流级水位线 + `pendingSendBufferHighWatermark`（http2/codec_impl.cc:741-753） |
| 半关闭 | 无（连接即流），响应前置完成直接置 Closing（conn_manager_impl.cc:1999-2005） | 支持请求/响应独立 end_stream（`allow_multiplexed_upstream_half_close_`，router.cc:892-894） |
| drain 表达 | 响应头加 `Connection: close`（conn_manager_impl.cc:2016-2024） | GOAWAY（onDrainTimeout `codec_->goAway()`，conn_manager_impl.cc:819-824） |
| 头处理特例 | TE 规范化、Host→:authority 由 codec/UHV 完成（http1/codec_impl.cc:1176-1196） | 丢弃重复 Host 头、reconstitute crumbled cookies（http2/codec_impl.cc:2527-2550, 755-761） |

## 3. ActiveStream：流是一等公民

每个请求/响应对对应一个 `ActiveStream` 对象，它同时是 `RequestDecoder`、`FilterManagerCallbacks`、`RouteCache`、`ScopeTrackedObject` 等（source/common/http/conn_manager_impl.h:145-154）。codec 的 `newStream` 返回的 ResponseEncoder 与 ActiveStream 配对后，所有后续解码回调都落在这个对象上。

值得说明的是：v1.39 的 HCM 已经**没有独立的 ActiveConnection 结构**——连接级状态直接内联在 `ConnectionManagerImpl` 成员里（`streams_` 流列表 conn_manager_impl.h:650、drain 状态机 h:644、计时器与水位线回调），流与连接的关联只通过 `ActiveStream::connection()`（conn_manager_impl.cc:1139-1143）与 `LinkedObject` 链表成员维持。早期版本曾用 ActiveConnection 管理连接级缓冲水位，后来职责并入 HCM/FilterManager，这本身就是"连接薄、流厚"设计取向的证据。

ActiveStream 承担的角色一览（均为同一 struct 的基类，conn_manager_impl.h:145-154）：

- `Http::RequestDecoder`：codec 解码回调的直接落点（h:188-189）；
- `FilterManagerCallbacks`：filter 链回写响应、sendLocalReply、continueDecoding 的出口（h:152）；
- `CodecEventCallbacks` / `StreamCallbacks`：编码完成、低层 reset、水位线通知（h:170-178）；
- `RouteCache`：路由缓存与刷新（h:154, 实现 conn_manager_impl.cc:1811-1833）；
- `ScopeTrackedObject`：异步回调期间在 dispatcher 上钉住流对象，防 use-after-free（h:151）。

```cpp
// source/common/http/conn_manager_impl.cc:968
if (connection_manager_.config_->streamIdleTimeout().count()) {
  idle_timeout_ms_ = connection_manager_.config_->streamIdleTimeout();
  stream_idle_timer_ = connection_manager_.dispatcher_->createScaledTimer(
      Event::ScaledTimerType::HttpDownstreamIdleStreamTimeout,
      [this]() -> void { onIdleTimeout(); });
  resetIdleTimer();
}
```

超时体系（构造于 ActiveStream 构造函数 conn_manager_impl.cc:895-1020）：

| 计时器 | 挂载点 | 触发行为 |
|---|---|---|
| stream idle | :968-974，`resetIdleTimer` 在每次 decode/encode 时刻重置（filter_manager.cc:720） | `onIdleTimeout` 发 408/504 本地响应（conn_manager_impl.cc:1061-1069） |
| request timeout | :976-981 | `onRequestTimeout` 发本地响应并记 `downstream_rq_timeout_`（:1071-1077） |
| request headers timeout | :983-989 | `onRequestHeaderTimeout`（:1079-1085），headers 到达即解除（:1368-1371） |
| max stream duration | :991-997 | `onStreamMaxDurationReached`（:1087-1094） |
| connection idle / max duration | 连接级，HCM 持有 | 见 §1（:785-817） |

统计也在流对象上归集：构造时 `downstream_rq_total_/active_` 与按协议分桶递增（conn_manager_impl.cc:958-966）；响应头到达时 `chargeStats` 记录响应码与耗时直方图（:1096-1138）；请求完成时 `completeRequest` 递减 active、收尾 tracing span（:1034-1050），access log 经 `ActiveStream::log` 输出（:1022-1033），且支持周期性 flush timer（:999-1019）。access log handler 列表由 HCM 配置与 filter 级配置合并（conn_manager_impl.h:202-215）。

## 4. decodeHeaders：入口处的头操作与 filter 链装配

`ActiveStream::decodeHeaders`（conn_manager_impl.cc:1354-1608）是整个 HTTP 栈最繁忙的函数之一，顺序为：

1. 记录 header 接收时间、判定 `Connection: close`（:1375-1381）；
2. 头校验、路由配置快照 `snapped_route_config_`（RDS 当前版本，:1394-1405）；
3. 过载保护可直接跳过 filter 链创建并 503（:1407-1429）；
4. Host/:path 合法性、路径规范化（:1448-1520）；
5. **只在非内部创建时**调用 `ConnectionManagerUtility::mutateRequestHeaders` 做一次全面的入口头处理（:1531-1549）；
6. `refreshCachedRoute()` 完成路由匹配并缓存（:1553, 1811-1833）；
7. `createDownstreamFilterChain()` 装配网络 filter 链（:1563-1564）；
8. tracing 处理后把 headers 交给 FilterManager（:1599-1604）。

`mutateRequestHeaders`（source/common/http/conn_manager_utility.cc:121-327）集中了所有入口头操作：hop-by-hop 清理（非 upgrade 时移除 Connection/Upgrade 并规范化 TE，:132-139；再清理 x-envoy-internal/Keep-Alive/Proxy-Connection/Transfer-Encoding，:141-145）、XFF 追加与可信跳数判定（:156-221）、x-forwarded-proto/port 与 :scheme 补全（:224-252）、内外部请求判定（XFF 单地址且为内部地址，:263-283）、x-envoy-external-address（:307-309）、x-request-id 生成（委托 `requestIDExtension()->set`，:311-315）、XFCC（:324）。响应方向的对称清理在 `mutateResponseHeaders`（同文件:688-740）：移除 hop-by-hop 头（受 `clear_hop_by_hop` 开关控制）、按需回写 x-request-id（:731-734）、追加 Via 与 x-envoy-proxy-status。调用点在响应编码路径 `ActiveStream::encodeHeaders`（conn_manager_impl.cc:1935-1938，1xx 在 :1903-1906）。

## 5. Filter 链迭代协议

`FilterManager::decodeData`（source/common/http/filter_manager.cc:716-845）展示了标准的迭代协议：从某个 filter 起遍历 `decoder_filters_`，每个 filter 返回 `FilterDataStatus`：

```cpp
// source/common/http/filter_manager.cc:790
FilterDataStatus status = (*entry)->handle_->decodeData(data, (*entry)->end_stream_);
if ((*entry)->end_stream_) {
  (*entry)->handle_->decodeComplete();
}
...
if (!(*entry)->commonHandleAfterDataCallback(status, data, state_.decoder_filters_streaming_,
                                             data_nonempty_before_callback) &&
    std::next(entry) != decoder_filters_.end()) {
  // Stop iteration IFF this filter is not the last one.
  break;
}
```

headers 的迭代（`FilterManager::decodeHeaders`，filter_manager.cc:610-714）与 body 略有不同：headers 总是"从下一个 filter 开始"迭代（:617-619），且引入了两个补偿机制——filter 在 decodeHeaders 里注入 body 时，用 `continue_data_entry` 记住断点并把 end_stream 推迟为"空 DATA 帧"（:695-697, 676-683）；本地回复（`decoder_filter_chain_aborted_`）会把状态强制改成 StopIteration 并走 `executeLocalReplyIfPrepared`（:638-644）。其余要点：

- `Continue` → 数据继续流向下一个 filter；`StopIteration/StopIterationAndBuffer` → `commonHandleAfterDataCallback` 返回 false，迭代停在当前 filter，数据缓存在该 filter 的 wrapper（ActiveStreamFilter）里；
- filter 异步完成后调用 `continueDecoding()`，经 `maybeContinueDecoding` 从断点恢复迭代（filter_manager.cc:598-608）；
- `StopAllIterationAndBuffer/Watermark` → `handleDataIfStopAll` 直接 return（:739），后续帧都先缓冲；
- 末尾如果某个 filter 在 decodeData 中注入了 trailers，会补跑 `decodeTrailers`（:835-837）；end_stream 到达最后一个 filter 后 `disarmRequestTimeout()` 解除请求超时（:839-840）。

encode 方向对称：`encodeHeaders/encodeData/encodeTrailers`（:1314+, :1262+），`commonDecodePrefix/commonEncodePrefix`（:1026, :992）决定迭代起点。每个 ActiveStreamFilter wrapper 同时维护缓冲与水位线，filter 返回 StopAndWatermark 时底层会 `onDecoderFilterBelowWriteBufferLowWatermark/AboveHighWatermark` 恢复/暂停读（conn_manager_impl.cc:2087-2107）。

router 之后的请求体不进入下游缓冲：router 是典型 streaming filter，`decodeData` 在无 retry/redirect/shadow 需求时对数据直接放行；需要 retry 时才缓冲，并在超过 `request_body_buffer_limit_` 时放弃 retry（router.cc:1083-1175，缓冲溢出处理 :1100-1140）。

## 6. Router filter：路由匹配与 upstream 请求发起

`Filter::decodeHeaders`（router.cc:477-770）的关键路径：

1. `callbacks_->routeSharedPtr()` 取 HCM 缓存的路由（:508），无路由直接 404（:509-517）；`directResponseEntry` 命中则本地直接应答（:520-557）。
2. `route_->routeEntry()` 得到 RouteEntry，用 `clusterName()` 查线程本地 cluster：`config_->cm_.getThreadLocalCluster(route_entry_->clusterName())`（:565-566）；找不到按配置回 404/503（:567-576）。
3. 维护模式与 DROP_OVERLOAD 检查（:601-622）；`attempt_count_` 自增并写入 streamInfo（:634-636）。
4. 超时与重试头处理：`FilterUtility::finalTimeout`（:643-645）读取 `x-envoy-upstream-rq-timeout-ms` 覆盖 route 超时后**删除该头**（router.cc:240-246；尊重下游 expected timeout 的分支 :221-238），再读 per-try 头（:248-256），若 per-try ≥ 全局则清零（:258-260）；最终把剩余预算写进 `x-envoy-expected-rq-timeout-ms`（router.cc:287-301）——这是 Envoy 逐跳超时预算传递的核心。
5. `route_entry_->finalizeRequestHeaders` 做 host/path 重写与 request_headers_to_add（:656-658）。
6. host 选择：`cluster->chooseHost(this)`（:726）。同步路径直接 `createConnPoolOrHandleFailure` → `continueDecodeHeaders`（:733-744）；DNS 异步路径则挂 `on_host_selected_` 回调并 `StopAllIterationAndWatermark`（:747-769），完成后 `onAsyncHostSelection` 续跑（:773-785）。
7. `continueDecodeHeaders`（:787-969）：取出 host、设置 upstream scheme、创建 conn pool（`createConnPool` 按 CONNECT-UDP/CONNECT/HTTP 选工厂，:971-1004），构造 `UpstreamRequest` 并 `acceptHeadersFromRouter(end_stream)`（:892-896），随后按 shadow 策略复制请求头启动镜像流（:852-961）。

UpstreamRequest 拿到 headers 后立即向连接池要流：`conn_pool_->newStream(this)`（source/common/router/upstream_request.cc:447-458）。连接池回调随后返回：`onPoolFailure` 把 PoolFailureReason 翻译成 `StreamResetReason` 并模拟 upstream reset（upstream_request.cc:616-639）；`onPoolReady` 记录 outlier 成功、恢复 CONNECT/WebSocket 暂停、把 upstream encoder 交给 UpstreamFilterManager 发送请求（:641-684）。UpstreamRequest 内部还有自己的 filter 链（`UpstreamFilterManager` + upstream_codec_filter，source/common/router/upstream_codec_filter.cc），即"upstream HTTP filters"独立于下游 filter 链运行——它甚至可以在 `notifyHostSelected` 阶段否决已选中的 host（upstream_request.cc:452-456）。自此进入报告 E 的连接池世界。

响应的回程则完全对称：upstream ResponseDecoder 回调 → UpstreamRequest → Router `onUpstreamHeaders`（router.cc:1843+，含 outlier/健康检查判定 :1890-1905）→ FilterManager encode 迭代 → `ActiveStream::encodeHeaders`（conn_manager_impl.cc:1917-2036，含 drain 判定、x-envoy-* 头清理、`chargeStats`）→ codec `response_encoder_->encodeHeaders` 写回下游。

## 7. 重试：策略与预算

重试决策在 `RetryStateImpl`：构造时按策略与 `x-envoy-max-retries` 得到 `retries_remaining_`（source/common/router/retry_state_impl.cc:75, 126）。`shouldRetry` 的三道闸门——策略允许否、`retries_remaining_ == 0` 返回 `NoRetryLimitExceeded`、cluster 资源管理器 `retries().canCreate()` 返回 `NoOverflow`（:269-286）。cluster 级 retry 预算（并发重试上限）在触发 backoff/next-loop 期间占用，`resetRetry` 释放（:257-267）。

router 侧入口：上游 reset/超时 → `Filter::onUpstreamReset` → `maybeRetryReset`（router.cc:1574-1629）：已开始下游响应、无 retry state、该 attempt 已重试过则不重试；否则 `retry_state_->shouldRetryReset` 的回调里 `doRetry`。`doRetry`（:2363-2444）重新 chooseHost（必要时 cross-cluster retry 先刷新 cluster，:2378-2402），再建新的 UpstreamRequest。响应头错误码重试走 `onUpstreamHeaders` → `shouldRetryHeaders`（router.cc:1843-1927；已重试过则只记 `wouldRetryFromHeaders` 便于诊断，:1909-1919）。

per-try timeout 是另一条触发路径：`onPerTryTimeout`（router.cc:1443-1475）先 reset 该 attempt，再 `maybeRetryReset(..., TimeoutRetry::Yes)`；若配置了 `hedge_on_per_try_timeout_`，则走 `onSoftPerTryTimeout`——不取消原请求而是并行再发一个 attempt（:1400-1435），这就是 hedging。退避策略在 RetryStateImpl 构造时确定：`upstream.base_retry_backoff_ms`（默认 25ms）与 `retry_back_off_ratio` 构成抖动指数退避（source/common/router/retry_state_impl.cc:88-100），retry 头（Retry-After / x-envoy-ratelimited）可替换为基于限速反馈的退避策略，由 `enableBackoffTimer` 定时触发重试（:158-170）。

## 8. Shadow/Mirror 流量

`decodeHeaders` 里收集命中的 `ShadowPolicy`（cluster 级优先于 route 级，router.cc:852-870），`FilterUtility::shouldShadow` 按运行时键采样判定。命中则深拷贝一份请求头（:872-878），在主请求的 UpstreamRequest 创建后，为每个 policy 调 `shadowWriter().shadow()`（一次性请求）或 `streamingShadow()`（:905-961），异步 client 会带 `mirror` 子 span、`setDiscardResponseBody(true)`，响应直接丢弃，不影响主请求（:924-942）。三个细节值得写进文章：

- 主请求若已被 upstream HTTP filter 以本地回复终止（`saw_local_reply_`），shadow 全部取消（router.cc:898-902）——镜像流量不应比主请求走得更远；
- 多个 shadow policy 时只有最后一个复用原始头拷贝，其余各自深拷贝，注释明说"copy whole headers map is not cheap"（router.cc:913-922）；
- shadow 流同样挂 watermark 回调（:958-959），主请求缓冲溢出时会被连带放弃（`retry_or_shadow_abandoned_`，router.cc:1117）。

## 9. RDS 与路由配置热更新挂点

HCM 在 `ActiveStream::decodeHeaders` 中通过 `routeConfigProvider()->configCast()` 对当前 route config 做**快照**（conn_manager_impl.cc:1394-1396），SRDS 场景额外按 scope key 重新选 scope（:1397-1402, snapScopedRouteConfig :1707）。快照的意义：配置更新只影响新请求，在途请求继续使用旧配置直到流结束。filter 修改路由头后可调 `refreshCachedRoute` 重匹配（:1811-1833）；按需加载（on-demand RDS）通过 `requestRouteConfigUpdate` 触发订阅回调（:1872-1882），其工厂名 `envoy.route_config_update_requester.default` 定义于 :891-893。RDS 订阅与 `onConfigUpdate` 细节在 source/common/router/rds_impl.cc:129 附近，配置面内容归报告 B。

## 10. drain_close 与 GOAWAY 处理点

- **被动 drain（运维信号）**：HCM 构造时持有 `Network::DrainDecision& drain_close_`（conn_manager_impl.cc:118-127, 成员 conn_manager_impl.h:652）。真正检查发生在**响应头编码时**：`ActiveStream::encodeHeaders` 若 `drain_close_.drainClose(drain_scope)`（或过载禁 keep-alive）为真，则 `startDrainSequence()` 并记 `downstream_cx_drain_close_` 统计（conn_manager_impl.cc:1940-1969）。drain 序列的推进在 `onDrainTimeout`：`codec_->goAway()` 后进入 Closing（:819-824）；HTTP/1 的 drain 表现为响应加 `Connection: close`（:2016-2024）。
- **主动 GOAWAY/关闭**：`sendGoAwayAndClose(graceful)` 被 overload load-shed 点和 filter 回调触发：优雅路径走 drain 序列（GOAWAY 分两帧），激进路径 `shutdownNotice + goAway + FlushWriteAndDelay`（:826-853）。onData 中的 overload 检查会即时触发（:528-540）。
- **收到对端 GOAWAY**：downstream 侧 HCM 目前忽略远端 GOAWAY（`onGoAway` 空实现，:780-783）；upstream 侧 codec 收到 GOAWAY 回调 `callbacks().onGoAway`（http2/codec_impl.cc:1273-1280），连接池据此把 client 转入 Draining 状态、无在途请求时直接关闭（conn_pool_base.cc:111-121）。
- **HTTP/1 语义等价物**：`shouldCloseConnection` 判定 `Connection: close` 后置 `shouldDrainConnectionUponCompletion`（conn_manager_impl.cc:1375-1381），最终在同一 encodeHeaders 中落地。

## 11. 设计动机

1. **codec 与 HCM 分离**：codec 只负责"协议帧 ↔ decode/encode 回调"的无状态翻译（http1/http2 codec 均只实现 `ConnectionImpl` 接口，HTTP/1 在 codec_impl.cc:1268-1360、HTTP/2 在 codec_impl.cc:2508-2571 各自落地），协议差异（多路复用、背压、GOAWAY）被封闭在 codec 内，HCM 只面对统一的 RequestDecoder/ResponseEncoder 抽象。因此新增 HTTP/3 只需实现 codec 并在 config.cc:836-849 加一个分支。
2. **stream 是一等对象**：连接不可信、流才承载请求语义——超时、统计、tracing、路由缓存、filter 链、水位线全部挂在 ActiveStream 上（conn_manager_impl.h:145-154），连接层状态（drain、idle、flood 保护）归 HCM。这样 HTTP/2 的 N 条流可以在同一条连接上互不干扰地拥有独立生命周期，`ScopeTrackedObject` 还保证了异步回调期间流对象存活。
3. **router 是普通 filter**：路由转发以 `Http::StreamDecoderFilter` 身份插入链条（router.cc:477），上游可以叠加 custom filter、上游 HTTP filter（upstream_codec_filter 亦是 filter，source/common/router/upstream_codec_filter.cc）；direct response、redirect、shadow 全部复用同一入口。这让"代理"本身成为 Envoy 可插拔能力之一，而非内核硬编码。
4. **retry 带预算（三层闸门）**：单请求 `retries_remaining_` 上限（retry_state_impl.cc:278-282）、cluster 并发重试资源 `retries().canCreate()`（:284-286）、全局超时预算的逐跳传递 `x-envoy-expected-rq-timeout-ms`（router.cc:287-301）。没有这些闸门，重试会在上游抖动时指数放大流量（重试风暴）；预算机制把爆炸半径限制在配置之内。
5. **header 操作集中在入口/出口**：`mutateRequestHeaders/mutateResponseHeaders`（conn_manager_utility.cc:121-327, 688-740）让 XFF、x-request-id、hop-by-hop 清理、内外部判定只发生一次且顺序确定——这是安全边界（IP 伪造、request smuggling）的关键，也避免了每个 filter 重复实现。且通过 `state_.is_internally_created_` 保证内部重试/重放不会二次清洗（conn_manager_impl.cc:1531）。
6. **"连接=流"的 HTTP/1 特例被推到边缘**：HTTP/1 的串行语义由 codec 暂停 dispatch（conn_manager_impl.cc:565-575）与 readDisable 背压（http1/codec_impl.cc:1311-1328）实现，上层 FilterManager/router 始终以流为单位编程，无需 if-HTTP/1 分支。

## 12. 写作素材清单（文件：行号）

1. source/common/http/conn_manager_impl.cc:515-582 — HCM onData 与 HTTP/1 redispatch 循环
2. source/common/http/conn_manager_impl.cc:895-1020 — ActiveStream 构造：流计时器全家桶
3. source/common/http/conn_manager_impl.cc:1354-1608 — decodeHeaders 全流程（头操作/路由/filter 链）
4. source/common/http/conn_manager_impl.cc:1917-2036 — encodeHeaders：drain_close/Connection:close 落地点
5. source/common/http/conn_manager_impl.cc:780-853 — onGoAway/onIdleTimeout/onDrainTimeout/sendGoAwayAndClose
6. source/common/http/conn_manager_impl.cc:269-331 — doEndStream 与延迟析构（流对象生命周期）
7. source/common/http/conn_manager_utility.cc:121-327 — mutateRequestHeaders（hop-by-hop/XFF/x-request-id/内外部判定）
8. source/common/http/conn_manager_utility.cc:688-740 — mutateResponseHeaders
9. source/common/http/codec_wrappers.h:14-126 — ResponseDecoderWrapper 与存活检查
10. source/common/http/http1/codec_impl.cc:1197-1330 — HTTP/1 onHeadersComplete/onBody/dispatch（连接=流）
11. source/common/http/http2/codec_impl.cc:2508-2571 — HTTP/2 onBeginHeaders（每流 newStream）与 overload GOAWAY
12. source/common/http/http2/codec_impl.cc:710-739 — ServerStreamImpl::decodeHeaders/decodeTrailers
13. source/common/http/filter_manager.cc:610-714, 716-845 — decodeHeaders/decodeData 迭代协议（Stop/continue/end_stream）
14. source/common/router/router.cc:477-770 — Filter::decodeHeaders 主路径（匹配/超时/chooseHost/shadow）
15. source/common/router/router.cc:1400-1475 — onSoftPerTryTimeout/onPerTryTimeout（hedging 与重试）
16. source/common/router/upstream_request.cc:412-458, 616-684 — conn_pool_->newStream 与 PoolCallbacks

（引用协议：`文件:行号` 均为 v1.39.1 检出实测行号。）

## 13. 与报告 E 的边界

本文止步于"`conn_pool_->newStream(this)` 发出、`onPoolReady/onPoolFailure` 回到 UpstreamRequest"这一刻（upstream_request.cc:458, 616-684）。至于连接池如何建连/复用/排队（conn_pool_base.cc:59-105）、`chooseHost` 背后的 LB 与 host 健康状态、`onPoolReady` 之后 UpstreamFilterManager 如何把请求经 upstream_codec_filter 编码上送，均归报告 E 展开。阅读本文时只需记住一条主线：**router 关心的是"哪个 cluster 的哪个 host"，连接池关心的是"用哪条连接的哪个流"**，两层以 `GenericConnPool` 接口（router.cc:971-1004）解耦。
