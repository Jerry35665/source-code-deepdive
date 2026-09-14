# D 章:反向代理 — Caddy 的旗舰模块 reverseproxy

> 调研对象:Caddy 源码,commit `56e3a88`(2026-09)。
> 模块根目录:`modules/caddyhttp/reverseproxy/`(下文行号均为该仓库相对路径下的实际行号,已逐一核对)。
> 本章是第五系列"路由与中间件"的最重要一篇:C 章讲的 handler 链里,`reverse_proxy` 是生产中使用率最高的一个。

---

## 1. 全景:一次反向代理请求的旅程

```
客户端请求
   │
   ▼
[HTTP Server] server.go: determineTrustedProxy()
   │   判定对端是否 trusted proxy,结果存入请求变量 TrustedProxyVarKey
   │   (modules/caddyhttp/server.go:1413-1461, 1373)
   ▼
[路由匹配] (C 章内容: matcher → route → handler 链)
   │
   ▼
Handler.ServeHTTP                      reverseproxy.go:485
   ├── prepareRequest()                reverseproxy.go:763
   │     克隆请求(浅拷贝+URL清洗, 1523)、rewrite(769)、
   │     可选请求缓冲(785)、剥离 hop-by-hop 头(820-836)、
   │     还原 Upgrade 头(840)、注入 X-Forwarded-*(869→889)、追加 Via(875)
   ├── websocket-over-h2/h3 降级为 h1 Upgrade(499-514)
   ▼
┌─────────── 代理重试循环 for {} ───────────────   reverseproxy.go:562-587
│  proxyLoopIteration()                     reverseproxy.go:603
│    ├── 动态 upstream 源(可选)刷新            607-634
│    ├── SelectionPolicy.Select(pool, req, w)  637   ← 负载均衡选点
│    │     过滤条件: Available() = Healthy() && !Full()   hosts.go:86-88
│    ├── fillDialInfo() 解析拨号地址             hosts.go:112
│    ├── 按上游重放请求头(重试幂等)              678-693
│    ├── reverseProxy()                       991
│    │     ├── countRequest(+1) / in-flight 计数  992-1002
│    │     ├── Transport.RoundTrip()           1046  ← 真正转发
│    │     ├── 被动健康检查打分(UnhealthyStatus/延迟) 1093-1106
│    │     ├── retry_match 表达式评估 → 换 upstream 重试  1132-1150
│    │     ├── handle_response 子路由           1153-1211
│    │     └── finalizeResponse()              1218
│    │           101 → handleUpgradeResponse(双向字节流拷贝)
│    │           否则: 复制响应头 + flush_interval 节流拷贝 body
│    ├── 失败 → countFailure(被动检查记账)       720-722
│    └── LoadBalancing.tryAgain() 决定换/弃      725 → 1342
└──────────────────────────────────────────────
   │
   ▼
statusError(): 502 默认 / 504 超时 / 499 客户端取消     reverseproxy.go:1616-1645
```

要点:prepareRequest 只做一次;重试循环里每一轮重新选 upstream、重新应用请求头(从头拷贝保证各次尝试一致,reverseproxy.go:672-693),响应回流则由 finalizeResponse 统一收尾。

---

## 2. 负载均衡专节

### 2.1 配置面与选择器接口

- `LoadBalancing` 结构:`Retries` / `TryDuration` / `TryInterval` / `RetryMatch`(retry_match)+ `SelectionPolicy`(reverseproxy.go:1648-1687)。
- `Selector` 接口只有一个方法 `Select(UpstreamPool, *http.Request, http.ResponseWriter) *Upstream`(reverseproxy.go:1690-1692)。**默认策略是 random**——Provision 时若未配置则填 `RandomSelection{}`(reverseproxy.go:380-382)。
- 12 个策略模块全部注册在 `http.reverse_proxy.selection_policies` 命名空间(selectionpolicies.go:39-52)。

### 2.2 各策略实现(均先按 `Available()` 过滤)

| 策略 | 位置 | 实现要点 |
|---|---|---|
| random(默认) | selectionpolicies.go:67-69 | `selectRandomHost` 用**蓄水池采样**,无需预知可用数(804-822) |
| random_choose | 234-258 | 先随机抽 k 个(蓄水池),再取其中活动请求最少的;`leastRequests`(829-857)是"两阶段"power-of-two-choices 思想 |
| least_conn | 282-308 | 统计的是**活动请求数**而非连接数(注释 263-268 明确解释:现代代理复用连接);并列时用 reservoir sampling 随机取一(299-304) |
| round_robin | 334-347 | `atomic.Uint32` 自增取模,不可用则跳过继续 |
| weighted_round_robin | 144-182 | 按权重区间展开的 WRR |
| first | 371-378 | 永远选第一个可用——主备部署形态 |
| ip_hash | 402-408 | 哈希客户端 RemoteAddr |
| client_ip_hash | 433-440 | 哈希经 trusted proxies 判定后的 client IP(与 C 章的 client_ip 逻辑对齐) |
| uri_hash / query / header hash | 464-466 / 513-527 / 594-607 | 哈希对应字段 |
| cookie(粘性会话) | 678-732 | 见下 |

哈希类策略的核心是 `hostByHashing`(860-879):**Rendezvous(HRW)哈希**——对每个可用上游算 `hash(upstream + key)` 取最大者,上游增减时只有 1/n 的键会迁移;散列函数是 xxhash(882-886)。

粘性 cookie(`lb_policy cookie`)不存明文:下发值是 `HMAC-SHA256(secret, upstream.Dial)`(hashCookie,794-801),回看时遍历池做 `hmac.Equal` 恒时比较(721-729);miss 则用 fallback 策略(默认 random)选新 host 并 Set-Cookie(681-712),HTTPS 场景自动加 `Secure; SameSite=None`(698-706)。

### 2.3 重试语义:哪类错误才换 upstream

`LoadBalancing.tryAgain`(reverseproxy.go:1342-1416)是重试裁判,判定顺序:

1. `retries` 与 `try_duration` 都为 0 → 直接放弃(1344-1346);两个上限任一到达也放弃(1349-1356)。
2. **错误分类决定可重试性**(1363-1396):
   - `DialError`(连接都没建立,请求必然没发出去)→ 永远可重试。DialError 在 transport 拨号失败时产生(httptransport.go:293-298)。
   - `retryableResponseError`(retry_match 按响应状态码判定要重试)→ 可重试,决定已在 reverseProxy() 里做完(1371-1373)。
   - 其余错误(连接建立后才失败,上游可能已收到请求):**默认只有 GET 才重试**——非幂等请求不可盲重(1375-1378);配置了 `retry_match` 则按匹配器决定(1388-1395),CEL 里可用 `{rp.is_transport_error}` 占位符区分传输错误与响应错误(1380-1386)。
3. 间隔:try_interval 为 0 立即重试;否则 sleep 后再试,等待期间监听 ctx 取消(1399-1415)。try_duration>0 而 try_interval=0 时 Provision 会兜底设 250ms,防止本地低延迟上游把 CPU 空转烧满(reverseproxy.go:383-389)。

另一条重试路径:`retry_match` 中含**表达式匹配器**的规则会在拿到响应后评估,命中则关闭 body、返回 `retryableResponseError` 换下一个 upstream(reverseproxy.go:1132-1150);纯请求匹配器被跳过,避免"所有匹配请求的响应都被重试"(1127-1131 注释)。重试耗尽后,`statusError` 会保留真实上游状态码而不是泛化 502(1619-1621)。

幂等性假设总结:**拨号失败=请求未送达=安全重试;响应后重试必须由用户用 retry_match 显式授权;连接后失败默认只赌 GET。** 请求体可重放的前提是配置了 `request_buffers` 把 body 完整缓冲(见 §4.3,ServeHTTP 里把缓冲体逐轮重置为 `bytes.NewReader`,reverseproxy.go:535-548, 562-570)。

---

## 3. 健康检查专节

### 3.1 数据结构:两层状态

- `HealthChecks { Active *ActiveHealthChecks; Passive *PassiveHealthChecks }`(healthchecks.go:38-68)。
- **主动检查的状态是 per-handler 的**,存在 `Upstream` 的原子字段 `unhealthy / activePasses / activeFails`(hosts.go:71-73;注释 65-70 解释为何不放共享 Host:两个 handler 对同一地址可用不同 health_uri,阈值不能互相污染)。
- **被动检查的状态是全局共享的**:`Host{numRequests, fails}` 两个原子计数(hosts.go:184-187),存放于全局 `UsagePool` `hosts`(hosts.go:316)——**跨配置重载保留健康状态**是 Caddy 的一个特色(注释 312-315)。动态上游另走 `dynamicHosts` map,按 last-seen 保活、闲置 1 小时驱逐(hosts.go:325-331)。
- 可用性判定链:`Available() = Healthy() && !Full()`(hosts.go:86-88);`Healthy()` = 主动检查未标黄(`unhealthy==0`)&& `fails < MaxFails` && 熔断器 OK(hosts.go:93-102);`Full()` = 并发数达到 `max_requests`(hosts.go:106-108)。

### 3.2 主动健康检查(后台轮询)

- 开启条件:配了 `health_uri`(或旧 `path` / `health_port`)即启用(healthchecks.go:226-228)。
- Provision 默认值:Method=GET(153-155)、timeout=5s(159-162)、interval=30s(201-203)、passes=1(213-215)、fails=1(217-219);还支持 `expect_status`、`expect_body` 正则、`max_size`、自定义 header(字段定义 73-134)。
- 触发:Provision 起 goroutine,`time.Ticker` 按 interval 遍历(healthchecks.go:271-293),每个 upstream 独立 goroutine 并发检查(297-382)。
- 判定:`doActiveHealthCheck`(391-581)——请求失败/非 2xx(或非 expect_status)/body 不匹配正则 → `markUnhealthy()`;否则 `markHealthy()`。两个闭包内部(464-506):
  ```go
  if upstream.activeHealthFails() >= h.HealthChecks.Active.Fails {
      if upstream.setHealthy(false) {           // CAS,hosts.go:266-272
          h.events.Emit(h.ctx, "unhealthy", ...)  // 479
          upstream.resetHealth()
      }
  }
  ```
  恢复对称:连续 `passes` 次成功 → `setHealthy(true)` + `Emit("healthy")`(497-505)。这就是"不健康池的恢复"路径——没有定时器探活恢复的说法,恢复由同一轮询驱动,阈值 `passes`(默认 1)控制防抖。
- 主动检查复用代理的 Transport(177-186),TLS transport 会把检查 scheme 翻成 https(httptransport.go:701-707)。

### 3.3 被动健康检查(请求流水记账)

- 配置:`PassiveHealthChecks { FailDuration, MaxFails(默认 1), UnhealthyRequestCount, UnhealthyStatus, UnhealthyLatency }`(healthchecks.go:233-257);MaxFails 默认 1 在 Provision 设定(reverseproxy.go:408-410);`UnhealthyRequestCount` 会被拷进每个 upstream 的 `MaxRequests`(1466-1471)。
- 记账点(三处):
  1. roundtrip 失败(拨错、超时等)→ `proxyLoopIteration` 里 `h.countFailure(upstream)`(reverseproxy.go:720-722);
  2. 响应状态码命中 `unhealthy_status`(reverseproxy.go:1095-1099);
  3. 响应延迟 ≥ `unhealthy_latency`(reverseproxy.go:1102-1105)。
- **衰减机制是"定时遗忘"而非指数惩罚**:`countFailure`(healthchecks.go:587-640)对 `Host.fails` +1,然后起一个 goroutine 在 FailDuration 后 -1(611-639)。即失败计数随时间线性退场,每个失败独立计时;没有像 nginx `fail_timeout` 那样的窗口重置,也没有指数退避。写作时不要把这一条写成"指数惩罚"——这是本次调研对任务前提的一处纠偏。
- 生效点:`Healthy()` 里 `Host.Fails() < MaxFails`(hosts.go:96)。fail_duration=0 时 countFailure 直接 no-op(healthchecks.go:590-596),即**被动检查默认关闭**。
- 被动检查对动态 upstream 的局限:状态挂在每请求重新拉起的 upstream 列表上,只有高并发场景下才持续有效(Handler.DynamicUpstreams 字段注释,reverseproxy.go:121-129)。
- 辅助设施:管理 API `GET /reverse_proxy/upstreams` 暴露各 host 的 num_requests/fails(admin.go:51-58);`inFlightRequests` 按地址统计在途请求(reverseproxy.go:51-73)。

---

## 4. 转发细节专节

### 4.1 X-Forwarded-\* 的信任链(安全核心)

两条信任判定,结论汇总在 `addForwardedHeaders`(reverseproxy.go:889-986):

1. **连接层判定**(server.go:1413-1461):HTTP app 按全局 `trusted_proxies`(IP 来源模块)判断对端,把布尔写进请求变量 `TrustedProxyVarKey`(server.go:1373)。
2. **handler 层判定**:reverse_proxy 自己的 `trusted_proxies` 选项在 Provision 时预解析为 `[]netip.Prefix`(reverseproxy.go:319-335),请求时再匹配一次 RemoteAddr(reverseproxy.go:931-938)。

注入逻辑(944-983):
```go
prior, ok, omit := allHeaderValues(req.Header, "X-Forwarded-For")
if !omit {
    if trusted && ok && prior != "" {
        req.Header.Set("X-Forwarded-For", prior+", "+clientIP)  // 追加
    } else if clientIP != "" {
        req.Header.Set("X-Forwarded-For", clientIP)             // 丢弃伪造,重新开始
    }
}
```

**为什么默认不信任**:函数注释写得很直白(reverseproxy.go:880-888)——这些头是 security sensitive,只有当对端是可信代理时,客户端带来的既有值才有资格被保留进链;否则直接 peer IP 覆盖,防止下游应用被伪造头欺骗。三个边界情形都做了删头防御:unix socket 对端 `"@"` 不可信时直接 `Del` 三个头(895-905);RemoteAddr 解析失败也删(908-921);X-Forwarded-Proto/Host 只取"最后一个值"(`lastHeaderValue`)且同样只在 trusted 时沿用(960-983)。另有 RFC 8470 `Early-Data: 1` 标记 TLS 握手未完成的重放请求(815-817)——同样是防伪造家族的一员。

### 4.2 websocket 与协议升级

- 入向:h1 走标准 Upgrade。prepareRequest 先剥离全部 hop-by-hop 头(826-836,hopHeaders 列表在 reverseproxy.go:1731-1742),再按原请求的 Upgrade 类型补回 `Connection: Upgrade`(840-844);websocket 强制 TLS 走 h1 only(`tlsH1OnlyVarKey`,864-866)。
- 入向 h2/h3:RFC 8441 风格的扩展 CONNECT websocket 被降级——删 `:protocol` 伪头、改回 GET + `Upgrade: websocket`、生成新的 Sec-WebSocket-Key,把原 body 存进请求变量以便回程还原(reverseproxy.go:499-514)。
- 出向 101:finalizeResponse 走 `handleUpgradeResponse`(reverseproxy.go:1243-1248 → streaming.go:60-239):校验后端返回的 Upgrade 类型与请求一致且可打印(66-80),h1 下 `Hijack()` 客户端连接(130),然后**两个 goroutine 对拷客户端与后端两条裸 TCP 流**(207-228);websocket 场景在优雅关闭时先发 Close 控制帧(194-203, writeCloseControl 463)。h2 场景不用 hijack,用 `h2ReadWriteCloser` 包 ResponseWriter 且每写必 Flush(41-58, 99-120)。`StreamTimeout` 可强制断流(216-220),`StreamCloseDelay` 让配置重载不断流、避免重连风暴(reverseproxy.go:180-187; cleanupConnections streaming.go:429-440)。

### 4.3 缓冲与流式

- **响应侧默认零缓冲流式**:拷贝 body 用 32KiB 池化 buffer(streaming.go:667-681),flush 节流由 `flushInterval` 决定(243-264):
  ```go
  if resCT == "text/event-stream" { return -1 }   // SSE 立即 flush
  if res.ContentLength == -1 { return -1 }        // 无长度=流
  if h.isBidirectionalStream(req, res) { return -1 }  // h2 双向流
  return time.Duration(h.FlushInterval)
  ```
  负值=立即,正值=每 interval 至少 flush 一次(`maxLatencyWriter`,streaming.go:577-630),0=不主动 flush。h2 双向流判定要求 req/res 都是 h2、ContentLength=-1、Accept-Encoding 为 identity/空(269-281)。
- 写失败发生在响应头已发出之后,已无错误页可回——直接 `panic(http.ErrAbortHandler)` 断流(reverseproxy.go:1291-1302)。
- **请求缓冲是显式 opt-in**:`request_buffers` 把 body 读进内存(上限截断),设 Content-Length,使重试可重放(reverseproxy.go:785-793;bodyNopCloserIfNotRead 455-483 保证拨号失败不吞 body);`-1` 表示无限缓冲,Provision 时会打 OOM 警告(274-276)。响应侧对称有 `response_buffers`(1109-1111)。

### 4.4 transport 层:到上游的 HTTP 定制

`HTTPTransport`(httptransport.go:56-167)是默认 RoundTripper,Provision 未配置时自动创建(reverseproxy.go:355-362)。`NewTransport`(207-554)的默认值就是一份"上游连接最佳实践":

- keep-alive 三默认:探测间隔 30s、空闲连接超时 2m、`MaxIdleConnsPerHost=32`(208-220,注释注明 32 是 #2805 调优结论;结构定义 914-931);
- **拨号超时默认 3s**,注释直言这是为了让 LB 重试更迅速(222-226);
- 拨号错误包成 `DialError`(293-298)供重试判定;PROXY protocol v1/v2 在拨号后写头(306-359);`read_timeout/write_timeout` 通过包装 `tcpRWTimeoutConn` 设 deadline(363-370);
- 版本默认 `["1.1","2"]`(185-187);`versions h2c` → `rt.Protocols.SetUnencryptedHTTP2(true)`(536-551,纯文本 h2 到上游);`versions 3` 实验性支持 HTTP/3 上游但不得与其他版本混用(503-533);`EnableH2C()` 是给 fastcgi 等内部调用的快捷方式(694-698);
- 自定义 DNS resolver、local_address、网络出口代理(network_proxy)均有字段(62, 144, 163)。

---

## 5. 与 nginx upstream 对照

| 维度 | Caddy | nginx |
|---|---|---|
| least_conn | `LeastConnSelection.Select`,数的是**活动请求数**(selectionpolicies.go:282-308,注释 263-268 承认命名是历史习惯),并列随机 | `least_conn` 数的是活动连接,语义按连接 |
| 哈希粘性 | ip_hash/uri_hash/cookie 全部走 Rendezvous/HRW 哈希(selectionpolicies.go:860-879),上游增减稳定 | ip_hash 按 IPv4 前三字节取模;consistent hash 是商业版能力 |
| 主动健康检查 | 内置免费:`health_uri` + interval/timeout/expect_status/expect_body,后台 goroutine 轮询(healthchecks.go:271-293) | 开源版无主动检查(可用第三方模块),主动检查在 nginx Plus |
| 被动健康检查 | max_fails 语义同源:`fails < MaxFails`(hosts.go:96)+ 每次失败 FailDuration 后独立遗忘(healthchecks.go:611-639) | max_fails + fail_timeout:失败进入惩罚期,期内不选该 server |
| 状态存续 | 全局 UsagePool,配置重载不丢健康计数(hosts.go:316) | 状态在 worker 内,reload 丢失(shared upstream zone 可部分共享) |
| 熔断 | 预留 `CircuitBreaker` 接口(healthchecks.go:263-266),核心仓库不含实现,由外部模块提供(命名空间 `http.reverse_proxy.circuit_breakers`,reverseproxy.go:109) | 无内置熔断(Plus 的 status zone 仅做观察) |
| 重试 | try_duration/try_interval/retries + retry_match 表达式,错误分类判定(reverseproxy.go:1342-1416) | proxy_next_upstream:按错误种类/超时/非幂等 method 白名单 |

---

## 6. 设计动机

1. **XFF 信任链的"默认怀疑"**:Caddy 把信任判定拆成 server 层(全局 IP 来源)+ handler 层(局部 trusted_proxies),且未受信时宁可删头也不透传(reverseproxy.go:895-921)。动机是下游应用普遍盲目信任 XFF——代理层必须替它们兜底。对比许多"默认透传"的代理,这是 Caddy 明确的安全立场。
2. **缓冲策略向流式倾斜**:默认零缓冲 + SSE/无长度/h2 双向流自动立即 flush(streaming.go:243-264),是因为现代上游(SSE、gRPC 流)越来越多;而 request_buffers 强制 opt-in 并打 OOM 警告(reverseproxy.go:274-276),把内存风险的选择权交给用户。
3. **策略模块化**:12 种策略都是独立 Caddy 模块,统一于 9 行的 Selector 接口(reverseproxy.go:1690-1692),Caddyfile 的 `lb_policy <name>` 只是 inline_key 语法糖。粘性 cookie 用 HMAC 而非明文,防篡改也防信息泄露(selectionpolicies.go:794-801)。
4. **重试的幂等性保守主义**:DialError 全放行、连接后错误默认只赌 GET、响应重试须显式 retry_match(1363-1396)——把"请求是否被上游处理过"的不确定性转化为默认安全的策略。
5. **健康状态全局化**:主动状态 per-handler(判定标准可异)、被动状态全局跨重载(hosts.go:312-316),是对"配置热重载不丢运维状态"这一 Caddy 一贯主张的延续。

---

## 7. FAQ 素材

1. `reverse_proxy` 默认负载均衡策略是什么?random(selectionpolicies.go:56-69;Provision 兜底 reverseproxy.go:380-382),不是轮询。
2. least_conn 数的是连接吗?不是,是活动请求数;命名只是历史习惯(selectionpolicies.go:263-268)。
3. 为什么我的应用拿到的 X-Forwarded-For 不是真实客户端链?因为对端不在 trusted_proxies 里,Caddy 丢弃了客户端自带的值(reverseproxy.go:944-955);显式配置 `trusted_proxies` 即可。
4. 上游挂了 Caddy 会自动重试吗?拨号失败总会;其他失败默认只有 GET,且需配置 retries/try_duration(reverseproxy.go:1363-1396);按状态码重试要用 `retry_match` 表达式(1132-1150)。
5. 被动健康检查为什么没生效?必须 `fail_duration > 0`,否则 countFailure 是 no-op(healthchecks.go:590-596);MaxFails 默认 1(reverseproxy.go:408-410)。
6. 被动检查是指数惩罚吗?不是——每个失败独立计时,FailDuration 后 -1 线性遗忘(healthchecks.go:611-639)。
7. SSE 为什么要配 flush_interval?其实不配也行:`text/event-stream` 会被自动识别为立即 flush(streaming.go:247-251);需要担心的是压缩中间层改变 Content-Type。
8. h2c 怎么开?transport 里 `versions h2c`(httptransport.go:546-550);websocket over h2/h3 入站会被降级为 h1 Upgrade 发往上游(reverseproxy.go:495-514)。
9. 配置重载会丢上游健康状态吗?静态上游不会,状态在全局 UsagePool(hosts.go:316);动态上游靠 last-seen 保活 1 小时(hosts.go:325-331)。
10. 熔断器(circuit_breaker)内置了吗?接口在,实现在外部模块(reverseproxy.go:106-109;healthchecks.go:263-266)。

## 深挖线索

1. `bodyNopCloserIfNotRead`(reverseproxy.go:455-483):一次 Close 语义的精细设计——拨号失败不能关掉共享的原始 body,否则毁掉所有重试;配合 request_buffers 的逐轮 `bytes.NewReader` 重放(535-570),可写一节"可重放请求体的工程学"。
2. Rendezvous 哈希替换简单取模 ip_hash(selectionpolicies.go:860-886):与 nginx 的差异点,适合和分布式系统经典文对读。
3. 101 升级的双向拷贝(streaming.go:60-239):hijack vs h2 `h2ReadWriteCloser` 两条路径、bufio 缓冲数据回填(174-185)、优雅关闭发 websocket Close 帧(194-203)、StreamCloseDelay 防重连风暴——一整章"代理如何搬运裸字节"。
4. 被动状态的全局 UsagePool 与动态上游的 dynamicHosts 双轨制(hosts.go:312-338):引用计数与 last-seen 驱逐的取舍,联系 Caddy 配置生命周期。
5. 1xx 信息响应透传的并发安全(reverseproxy.go:1010-1034):httptrace Got1xxResponse 与 RoundTrip 返回的竞态,用 mutex+roundTripDone 处理,小而精的并发案例。

---

## 写作要点速查表

| 主题 | 位置(仓库相对路径:行号) |
|---|---|
| Handler 结构(Upstreams/TrustedProxies/FlushInterval/缓冲) | modules/caddyhttp/reverseproxy/reverseproxy.go:100-251 |
| Provision:默认 random 策略、try_interval 兜底、CIDR 预解析 | reverseproxy.go:262-438(380-389, 319-335) |
| ServeHTTP 主流程 + 重试循环 | reverseproxy.go:485-597(562-587) |
| proxyLoopIteration:Select→fillDialInfo→reverseProxy→tryAgain | reverseproxy.go:603-730(637, 651, 720, 725) |
| prepareRequest:hop-by-hop/Upgrade/Early-Data/Via | reverseproxy.go:763-878(820-844, 815-817, 875) |
| XFF 信任链注入 | reverseproxy.go:889-986(891, 931-938, 944-955) |
| server 层信任判定 determineTrustedProxy | modules/caddyhttp/server.go:1413-1461 |
| reverseProxy:RoundTrip/被动打分/retry_match/handle_response | reverseproxy.go:991-1215(1046, 1093-1106, 1132-1150) |
| finalizeResponse:101 分支/Via/flush 拷贝/trailer | reverseproxy.go:1218-1333(1243-1248, 1284, 1301) |
| tryAgain 重试裁判 | reverseproxy.go:1342-1416 |
| statusError:502/504/499 | reverseproxy.go:1616-1645 |
| Upstream/Host 状态与 Available/Healthy/Full | modules/caddyhttp/reverseproxy/hosts.go:35-108 |
| 全局 hosts 池(跨重载) | hosts.go:312-338 |
| 主动检查:配置/轮询/判定/事件 | modules/caddyhttp/reverseproxy/healthchecks.go:73-228, 271-581(479, 502) |
| 被动检查 countFailure 定时遗忘 | healthchecks.go:587-640 |
| 策略:least_conn/cookie/HRW/蓄水池 | modules/caddyhttp/reverseproxy/selectionpolicies.go:282-308, 678-732, 860-886 |
| flush_interval/SSE/双向流判定 | modules/caddyhttp/reverseproxy/streaming.go:243-281 |
| websocket 升级双向拷贝 | streaming.go:60-239(130, 207-228) |
| transport 默认值(keepalive/3s 拨号/h2c/h3) | modules/caddyhttp/reverseproxy/httptransport.go:207-554(208-226, 536-551) |
| Caddyfile 选项入口(lb_policy 265 / health_uri 336 / fail_duration 566 / flush_interval 636 / trusted_proxies 706) | modules/caddyhttp/reverseproxy/caddyfile.go |

---
*完。行号以 commit 56e3a88 实测为准;引用时建议再跑一次 `grep -n` 抽查。*
