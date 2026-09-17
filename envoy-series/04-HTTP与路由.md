# 第 04 章 · HTTP 连接管理与路由:从字节流到 upstream 请求

> 基线:tag v1.39.1。核心目录 source/common/http/ 与 source/common/router/。

## 4.0 全景:一条 HTTP 请求的完整路径

```
字节流(Network::Connection)
 → HCM(conn_manager_impl.cc:515 onData→createCodec:494→codec_->dispatch)
    ├ HTTP/1.1:ServerConnectionImpl 连接=流,每消息暂停,HCM 无在途流才 redispatch(:565-575)
    └ HTTP/2:每个 stream_id 建 ServerStreamImpl(http2/codec_impl.cc:2508),一次 dispatch 处理全部帧
 → ActiveStream(一请求一对象,即 RequestDecoder;流计时器全家桶 :895-1020)
 → FilterManager 迭代协议(Stop 缓存/continueDecoding 断点续跑,filter_manager.cc:610-845)
 → Router Filter(router.cc:477 decodeHeaders):路由匹配→cluster 查找→finalTimeout 预算
    →chooseHost→createConnPool→conn_pool_->newStream(upstream_request.cc:458)
```

## 4.1 HCM 与 codec:协议差异被封闭

HCM 是挂在 TCP 连接上的普通 Network::ReadFilter;codec 只做"协议帧↔回调"的无状态翻译,HTTP/1/HTTP/2/QUIC 各自实现 ConnectionImpl 接口,新增协议只需加一个 createCodec 分支(config.cc:836-849)。HTTP/1 的"连接=流"由两处边缘机制实现:codec 每解析完一条消息暂停 dispatch + 收到下一条流水线请求时 readDisable(true) 背压(http1/codec_impl.cc:1311-1328)——上层 FilterManager/router 始终以流为单位编程,无需 if-HTTP/1 分支。HTTP/2 的背压则是流级水位线+pendingSendBufferHighWatermark。

v1.39 已无独立 ActiveConnection 结构——连接状态内联于 HCM(streams_ 链表,conn_manager_impl.h:650),"连接薄、流厚"。

## 4.2 ActiveStream:流是一等公民

超时全家桶挂在流构造:stream idle(每次 decode/encode 重置)/request/request-headers/max stream duration(conn_manager_impl.cc:968-997);连接级 idle/max-duration 归 HCM(:785-817)。`ScopeTrackedObject` 让异步回调期间流对象被 dispatcher 钉住防 use-after-free;`doDeferredStreamDestroy` 把流对象交给 dispatcher 延迟删除(:269-331)。HTTP/1 还有 flood 保护:单连接乱序流水线请求超限直接协议错误关连接(http1/codec_impl.cc:336+)。

## 4.3 头操作集中在入口/出口

`mutateRequestHeaders`(conn_manager_utility.cc:121-327)一次性完成:hop-by-hop 清理(非 upgrade 时移除 Connection/Upgrade 并规范化 TE)、XFF 追加与可信跳数、x-forwarded-proto/port、内外部请求判定、x-request-id 生成、XFCC。响应对称清理在 mutateResponseHeaders(:688-740)。顺序确定+只发生一次,是 IP 伪造与 request smuggling 防护的关键;`is_internally_created_` 保证内部重试不二次清洗。

## 4.4 Router:预算制重试与影子流量

`Filter::decodeHeaders` 主路径:路由匹配→`getThreadLocalCluster`→**finalTimeout 消费 x-envoy-upstream-rq-timeout-ms 后删除该头**,剩余预算写进 `x-envoy-expected-rq-timeout-ms` 逐跳传递(router.cc:240-301)→chooseHost→建 UpstreamRequest。**重试三道闸门**:单请求 retries_remaining_、cluster 并发重试资源 `retries().canCreate()`、全局超时预算——没有这些,上游抖动时重试会指数放大流量(retry_state_impl.cc:269-286)。per-try 超时触发 reset+retry;配 hedge 则不取消原请求并行再发(:1400-1475)。退避=25ms 基数×抖动指数;Retry-After 可替换为限速反馈退避。

Shadow/Mirror:按运行时键采样,深拷贝请求头走一次性/流式镜像,响应直接丢弃;主请求被本地回复终止则全部取消;"拷贝整个 header map 不便宜"——多 policy 时只有最后一个复用拷贝(router.cc:913-922 注释)。

## 4.5 设计动机

1. **codec 与 HCM 分离**:协议差异(多路复用/背压/GOAWAY)封闭在 codec 内;
2. **流是一等对象**:连接不可信,超时/统计/tracing/路由缓存全挂流上;HTTP/2 的 N 条流互不干扰;
3. **router 是普通 filter**:代理本身成为可插拔能力,direct response/redirect/shadow 复用同一入口;
4. **retry 带预算**:三道闸门把重试风暴的爆炸半径限制在配置内;
5. **头操作集中**:安全边界只实现一次,顺序确定。

## 4.6 FAQ

**Q1:AUTO codec 怎么选协议?**
ALPN/首字节嗅探(conn_manager_utility.cc:88-109)。

**Q2:GOAWAY 收到了会怎样?**
downstream 侧目前忽略(onGoAway 空实现,:780-783);upstream 侧连接池转入 Draining。

**Q3:drain 怎么传导到 HTTP?**
encodeHeaders 时检查 drainClose→HTTP/2 发 GOAWAY,HTTP/1 加 Connection: close(:1940-2024)。

**Q4:路由配置热更新影响在途请求吗?**
不影响:decodeHeaders 做配置快照,更新只影响新请求(:1394-1405)。

**Q5:per-try 超时和 hedge 的区别?**
per-try:reset 该 attempt 再重试;hedge:不取消,并行再发一个 attempt。

**Q6:x-envoy-upstream-rq-timeout-ms 谁能设?**
下游调用方;Envoy 消费后删除并把剩余预算写入 expected-rq-timeout 传给上游。

**Q7:请求头会在每个 filter 重复清洗吗?**
不会:集中在 mutateRequestHeaders 一次完成。

**Q8:上游请求还有 filter 链吗?**
有:UpstreamRequest 内部有独立的 UpstreamFilterManager+upstream_codec_filter,甚至能否决已选 host。

**Q9:流对象会 use-after-free 吗?**
防线:ScopeTrackedObject 钉住+deferredDelete 延迟析构。

**Q10:shadow 流量会影响主请求吗?**
不会:异步独立 client、丢弃响应;主请求缓冲溢出时连带放弃。

## 4.7 小结与深挖方向

本章结论:**HTTP 层="codec 封闭协议差异+流承载全部语义+router 即 filter+预算制重试"**。深挖:

1. HTTP/1 UHV(URL host 规范化)与 TE 规范化的 smuggling 防线;
2. ScaledTimerManager 与过载时全局缩时(ReduceTimeouts action);
3. maybeDrainDueToPrematureResets:过早 RST 过多时主动 drain 整条连接;
4. on-demand RDS 的 requestRouteConfigUpdate 路径;
5. upstream codec filter 否决 host 的实际用途(如升级 CONNECT)。
