# C-HTTP 栈与路由:matcher、中间件链与请求旅程

> 系列五·第 3 章 | 源码:caddyserver/caddy @ commit `56e3a88`(56e3a88efe39be6e380496778e7b94cb97f60c00)
> 前置:A 报告已讲模块体系与生命周期(Provision→Validate→Start)。行号均为仓库相对路径,实测核对。

---

## 1. 全景:一个请求的旅程

```
客户端连接 (tcp :443)
   │
   ▼
net.Listener  ──ListenerWrapper 链(可插在 TLS 握手前/后, tlsPlaceholderWrapper 定位)
   │                      app.go:586-604
   ▼
tls.NewListener(ln, tlsCfg)          ← SNI 选证书,02 章自动 HTTPS   app.go:598
   │        (HTTP/3 走 QUIC 另一套: srv.serveHTTP3, app.go:657)
   ▼
go srv.server.Serve(ln)  ── Go 标准库 http.Server,每连接一个 goroutine   app.go:631
   │        Handler: srv  (Server 自身即 http.Handler)                 app.go:491
   ▼
Server.ServeHTTP(w, r)               请求入口                        server.go:551
   │  ├─ 恢复 r.TLS(包装过的连接)  server.go:555-559
   │  ├─ IdleTimeoutReader/Writer 防 slowloris                    server.go:588-614
   │  ├─ Server 头 + Alt-Svc(HTTP/3 广播)                        server.go:617-631
   │  ├─ PrepareRequest: 注入 replacer/vars/routeGroup 到 ctx     server.go:634-635, 1366-1390
   │  └─ ACME HTTP-01 challenge 短路                              server.go:696-699
   ▼
s.serveHTTP: 方法长度/Host 合法性/下划线头丢弃 → primaryHandlerChain  server.go:783-886
   │        (外层套 enforcementHandler: StrictSNI-Host 校验)         server.go:891-918
   ▼
RouteList(编译好的中间件栈, 顶层仅编译一次)                            app.go:366-376
   │  逐条 Route: MatcherSets.AnyMatchWithError? ──否──▶ 跳到下一条    routes.go:272-281
   │        │是
   ▼
本条 Route 的 handler 链: h1 → h2 → … → hN(请求下行)                routes.go:309-323
   │                                   ◀── 响应上行(逆序流回)
   ▼
无 handler 处理? emptyHandler 置 {http.vars.unhandled}=true          caddyhttp.go:95-98
   │
   ├─ 出错 ▶ Server 错误分支 → errorHandlerChain(用户错误路由)        server.go:708-780
   ▼
响应写回客户端(经 ResponseRecorder 记录状态码/字节数供访问日志)        responsewriter.go:65-143
```

要点:Caddy 没有自研事件循环,直接用 Go 标准库 `http.Server`;Caddy 的全部路由逻辑位于一个 `http.Handler`(`Server.ServeHTTP`,server.go:551)之内。

---

## 2. 路由模型专节:Route = 匹配组 + 处理组

### 2.1 Route 结构(routes.go:31-105)

```go
type Route struct {
    Group string                    // 同组互斥: 只执行组内第一条命中的路由   routes.go:37
    MatcherSetsRaw RawMatcherSets   // "match": 集合间 OR, 集合内 AND        routes.go:43
    HandlersRaw []json.RawMessage   // "handle": 有序 handler 列表           routes.go:92
    Terminal bool                   // 命中后截断, 不再执行后续路由           routes.go:95
    MatcherSets MatcherSets         // 解码后
    Handlers    []MiddlewareHandler
    middleware  []Middleware        // 预编译的中间件包装                     routes.go:101
}
```

匹配语义由 `MatcherSets.AnyMatchWithError` 实现:任一 matcher 集(OR)命中即命中;集内所有 matcher(AND)都必须通过(routes.go:430-438)。空 matcher 集 = 恒匹配(catch-all),`return len(ms) == 0`(routes.go:437)。

### 2.2 排序:显式顺序,不是最长匹配

Caddy 的路由表是**按配置顺序线性求值**的列表(`RouteList []Route`,routes.go:196)。`RouteList.Compile` 把每条路由包成 `Middleware`,再从后往前叠成一条链(routes.go:239-249):

```go
func (routes RouteList) Compile(next Handler) Handler {
    mid := make([]Middleware, 0, len(routes))
    for _, route := range routes {
        mid = append(mid, wrapRoute(route))
    }
    stack := next
    for _, middleware := range slices.Backward(mid) {   // 逆序包裹
        stack = middleware(stack)
    }
    return stack
}
```

- 不存在 nginx location 那种"前缀最长者优先"的隐式优先级;**先写的先匹配**,未命中才落到下一条(routes.go:278-281)。
- "最长匹配"只出现在一处自动生成逻辑:自动 HTTPS 重定向路由插入前,按"精确域名 > 通配符 > catch-all、再按长度/字母序"排序(autohttps.go:424-454)——这是为了确定性,而非通用路由规则。
- `Terminal: true` 命中后把 next 替换为 `emptyHandler`/`errorEmptyHandler`,后续路由全部短路(routes.go:299-306;终端 handler 本体 caddyhttp.go:95-112)。
- `Group` 是互斥组:命中即记入 ctx 里的 `routeGroupCtxKey` map,同组后续路由直接跳过(routes.go:286-297,ctx 键定义 routes.go:473)。

### 2.3 通配与 catch-all

- `path` matcher 的 `*`:前缀 `/foo/*`、后缀 `*.css`、子串 `*/api/*`、中部 glob `/a/*/b`(文档 matchers.go:67-107;实现 matchers.go:495-529)。整体 `*` 等价于无 matcher,Provision 时还会把 `*` 挪到列表首位提前短路(matchers.go:412-416)。
- `host` matcher 的 `*` 只匹配单个 label(`*.example.com` 不匹配 `a.b.example.com`),因为 host matcher 同时驱动自动 HTTPS 的证书名(matchers.go:55-63)。
- 真正的 catch-all = 不写 matcher(routes.go:437;自动 HTTPS 的兜底重定向路由即如此,autohttps.go:401-403)。

---

## 3. matcher 专节

### 3.1 PathMatcher:线性扫描 + glob,不是树

**关键结论:`MatchPath` 没有 trie/基数树。** 它就是 `[]string` 模式列表,逐条与请求路径比对(matchers.go:108,429-535):

```go
func (m MatchPath) MatchWithError(r *http.Request) (bool, error) {
    reqPath := normalizeWindowsPath(strings.ToLower(r.URL.Path))  // 大小写不敏感  matchers.go:436
    for _, matchPattern := range m {                              // 线性逐条      matchers.go:440
        matchPattern = repl.ReplaceAll(matchPattern, "")          // 支持占位符
        if matchPattern == "*" { return true, nil }               // 整体通配
        ...
        if strings.Count(matchPattern, "*") == 2 && ...           // 子串快路径    matchers.go:495
        if strings.Count(matchPattern, "*") == 1 { ... }          // 前缀/后缀快路径 matchers.go:506-524
        matches, _ := path.Match(matchPattern, reqPathForPattern) // 兜底: stdlib glob  matchers.go:529
    }
}
```

安全设计值得单说:匹配前强制 `CleanPath` 合并 `//`、解析 `.`/`..`,防止畸形路径绕过(注释引 #4407,matchers.go:449-455;CleanPath 实现 caddyhttp.go:279-299);模式含 `%` 时切到"转义空间"逐字节比对,防 `%2F` 语义混淆(matchers.go:471-485,状态机 matchPatternWithEscapeSequence matchers.go:537-655);Windows 上归一化反斜杠和尾点空格防绕过(matchers.go:672-685,#5613)。

### 3.2 HostMatcher 的优化:>100 条才启用二分

```go
if m.large() {                                   // large(): len(m) > 100       matchers.go:399
    pos := sort.Search(len(m), func(i int) bool { // 二分找精确匹配              matchers.go:321
        if m.fuzzy(m[i]) { return false }         // fuzzy: 含 { 或 *            matchers.go:394
        return m[i] >= reqHostLower
    })
    if pos < len(m) && m[pos] == reqHostLower { return true, nil }
}
```

Provision 时:去重报错(matchers.go:259-277)、IDNA/小写归一化;大列表按"fuzzy 排前、精确排后"字典序排序(matchers.go:279-295),精确命中走二分(注释称对大列表快 100-1000 倍,matchers.go:320),未命中再只线性扫前段 fuzzy 项,遇到精确段即 break(matchers.go:340-342)。多站点/多租户场景的针对性优化。

### 3.3 其他内置 matcher 与自定义模块

- 全部 matcher 在 `init` 注册进 `http.matchers` 命名空间(matchers.go:222-233):host/path/path_regexp/method/query/header/header_regexp/protocol/tls/not(matchers.go:65-219)。
- `MatchMethod` 只是 `slices.Contains`(matchers.go:917);`MatchHeader` 快速前缀/后缀/子串通配,无正则(matchers.go:1150-1191);`MatchNot` 内嵌嵌套 matcher 集取反(matchers.go:1553-1564)。
- 正则族 `MatchRegexp` 编译一次(matchers.go:1589-1596),命中后把捕获组写进 replacer 供 `{http.regexp.name.group}` 占位(matchers.go:1610-1640)。
- 自定义 matcher = 实现 `RequestMatcherWithError` 接口(caddyhttp.go:55-57)并注册模块;还有 CEL 表达式 matcher `MatchExpression`(celmatcher.go:61,Provision 编译于 celmatcher.go:122),所有内置 matcher 通过 `CELLibrary` 方法自动获得 CEL 函数形态(如 `host('x')`,matchers.go:374-390)。
- matcher 可返回错误,错误会短路 handler 链、进入错误路由(routes.go:272-277)。

---

## 4. 中间件链专节

### 4.1 三个基础类型(caddyhttp.go:65-92)

```go
type Handler interface { ServeHTTP(http.ResponseWriter, *http.Request) error }   // 可返回错误
type Middleware func(Handler) Handler                                            // 链节
type MiddlewareHandler interface {
    ServeHTTP(http.ResponseWriter, *http.Request, Handler) error                 // 第三参 = next
}
```

与 `http.Handler` 的差异有两点:`ServeHTTP` 带 `error` 返回值(错误沿链上抛、由服务器错误路由接管);handler 收到 `next` 而非持有它。

### 4.2 编译期:预构建 static chain

每条 Route 的 handler 链在 **Provision 阶段就预编译**好,不是请求时才组装(routes.go:180-184):

```go
// pre-compile the middleware handler chain
for _, midhandler := range r.Handlers {
    r.middleware = append(r.middleware, wrapMiddleware(ctx, midhandler))   // routes.go:182
}
```

`wrapMiddleware` 把 `MiddlewareHandler` 适配成 `Middleware`:调用 `mh.ServeHTTP(w, r, next)`,把 next 传进去(routes.go:331-341)。顶层的完整链在 app Provision 时一次性编译并缓存:

```go
err := srv.Routes.ProvisionHandlers(ctx, app.Metrics)
primaryRoute = srv.Routes.Compile(emptyHandler)          // app.go:370-374
srv.primaryHandlerChain = srv.wrapPrimaryRoute(primaryRoute)  // 再套 enforcementHandler
```

例外:**subroute(`http.handlers.subroute`)是每请求编译**——`sr.Routes.Compile(next)` 在 ServeHTTP 里调用,因为 next 因调用点而异(subroute.go:72-74);`RouteList.Compile` 的文档注释也写明子路由按请求编译(routes.go:236-238)。

### 4.3 请求期:matcher 延迟求值 + 就地叠链

`wrapRoute` 闭合每条路由(routes.go:256-326),请求到来时:

1. `route.MatcherSets.AnyMatchWithError(req)` 判定命中(routes.go:272);
2. 未命中 → 直接 `nextCopy.ServeHTTP`,滑向下一条路由(routes.go:278-281);
3. 命中 → 处理 Group/Terminal 后,**把本路由预编译的 `route.middleware` 从后往前叠到 nextCopy 上**(routes.go:309-311),然后执行。注意叠加发生在请求期、但包装器对象是 Provision 期建好的闭包,请求期只是组装指针,开销极小;
4. metrics 只在路由级包一次而非每 handler 包一次(修 #4644 的 CPU 开销,routes.go:313-321)。

### 4.4 next 语义与终端 handler

- 请求下行、响应上行:配置顺序 `[encode, templates, file_server]` 表示请求经过 encode→templates→file_server,响应按反方向流回(routes.go:45-91 的长注释用完整例子讲清了这个"谜题")。
- 内容源头(如 file_server、reverse_proxy)**不调用 next**;链尾的 `emptyHandler` 兜底,把 `{http.vars.unhandled}` 置 true,供外层判断"没有 handler 处理此请求"(caddyhttp.go:95-98)。
- 错误链的兜底是 `errorEmptyHandler`:从 ctx 取 `ErrorCtxKey` 写出对应状态码,防止错误路由没接住时响应悬空(caddyhttp.go:104-112,#3053)。
- 服务器级还有一条独立的 `errorHandlerChain`(app.go:379-385),由 `Server.ServeHTTP` 的错误分支调用,错误处理前会先还原原始请求(method/URL/RemoteAddr,#3717,server.go:708-716)。

---

## 5. 响应写入与请求日志

- **ResponseRecorder**(responsewriter.go:65-143):访问日志需要状态码和字节数,于是 Server 在日志开启时用 recorder 包住 `http.ResponseWriter`(server.go:652-654)。它支持条件缓冲:`shouldBuffer` 回调在写头前决定整包缓冲(供 reverse_proxy 的 `@error` 响应改写等)还是直接透传流式;1xx 永不缓冲(responsewriter.go:148-173)。header map 不缓冲以支持 trailer(注释引 #3236,responsewriter.go:114-117)。
- **响应占位符**:replacer 的 `http.response.header.*` 前缀(replacer.go:601)由 handler 借助 `PrepareRequest` 传入的 `w` 实现(server.go:1366-1390 把 repl、server、vars、routeGroup、OriginalRequest、ExtraLogFields 六件套塞进 ctx);请求侧占位符(`http.request.*`)全部在 `addHTTPVarsToReplacer` 里惰性求值(replacer.go:58)。
- **请求日志**:进入链前先 `r.Clone` 并用 `zap.Object` + `WithLazy` 惰性编码,注释明说比 `.With` 立即 JSON 编码快(server.go:637-645);真正落日志在 defer 的 `logRequest`(server.go:1218),是否记录由 `shouldLogRequest` 按 host 映射判定(server.go:1178);`Logs.Trace` 还能给每个 middleware 的调用打点(server.go:1208,routes.go:334-337)。

---

## 6. 静态文件服务(fileserver,简短)

- 入口 `FileServer.ServeHTTP`(staticfiles.go:321);根目录 `Root` 默认 `{http.vars.root}`(staticfiles.go:106-113)。
- 防目录穿越靠 `SanitizedPathJoin`:`path.Clean("/"+reqPath)` 后用 `filepath.IsLocal` 拒绝非本地路径,结果绝不出 root(caddyhttp.go:252-274)。文档同时明示"site root 不是沙箱":root 内的符号链接可被访问(staticfiles.go:109-112)。
- 隐藏文件:`Hide` 列表用**文件系统路径**而非请求路径(staticfiles.go:115-135);`fileHidden` 把无分隔符的条目(如 `"hidden"`)匹配到路径任意层级组件,绝对/相对条目则做全路径比对(staticfiles.go:735-757)。文档警告 hide 在大小写不敏感文件系统上不是安全边界(staticfiles.go:131-134)。
- 目录无索引文件时可开 `browse` 列目录(staticfiles.go:141-143),`Accept: application/json` 时输出 JSON 列表(staticfiles.go:66-82);browse 渲染用 bufPool(fileserver/browse.go:350)。

---

## 7. 与 02 章(自动 HTTPS)的衔接:HTTP→HTTPS 重定向路由的生成

- `App.Provision` 第一步就是 `automaticHTTPSPhase1`(app.go:210;函数体 autohttps.go:77),它扫描所有 host matcher 收集域名、建自动化策略,并**生成重定向路由注入路由表**。
- 重定向路由的构造 `makeRedirRoute`(autohttps.go:544-579):目标 `https://{http.request.host}{http.request.uri}`,非标准端口才追加端口(autohttps.go:545-558);matcher 集是 `{protocol==http}` + host 列表(autohttps.go:362-368);handler 是单个 `StaticResponse` 308 Permanent Redirect + `Close: true`(autohttps.go:565-578)。
- 注入策略:如果已有 server 监听 :80,把重定向路由插到它"最后一条带 host matcher 的路由之后、用户 catch-all 之前"(autohttps.go:469-479,引 #3212/#4829);否则新建名为 `remaining_auto_https_redirects` 的 server 承接(autohttps.go:498-502)。
- 证书管理在 `Start` 末尾的 `automaticHTTPSPhase2` 才启动(app.go:677;autohttps.go:869)——即先能服务重定向,再开始申请证书。
- 另有一个 listener wrapper `caddy.listeners.http_redirect`:在 TLS 端口上探测到明文 HTTP 请求时直接回 400/重定向,适配非标准 HTTPS 端口(httpredirectlistener.go:21-28)。

---

## 8. 性能专节

| 手段 | 位置 | 说明 |
|---|---|---|
| 顶层链只编译一次 | app.go:366-376 | `primaryHandlerChain` 缓存在 Server 上;仅 subroute 每请求 Compile(subroute.go:73) |
| 中间件预包装 | routes.go:180-184 | Provision 期建闭包,请求期只叠指针 |
| matcher 就地短路 | matchers.go:495-529 | path 单 `*` 走 HasPrefix/HasSuffix,避免完整 glob |
| host 大列表二分 | matchers.go:318-330 | >100 条启用,精确段排序+binary search |
| sync.Pool | encode/encode.go:212-216;reverseproxy/reverseproxy.go:1848;reverseproxy/streaming.go:667;fileserver/browse.go:350;templates/tplcontext.go:576;intercept/intercept.go:94 | 压缩 writer、代理缓冲、目录列表、模板渲染各自池化 |
| 惰性日志克隆 | server.go:637-645 | `r.Clone`+`WithLazy` 代替立即 JSON 编码 |
| 浅拷贝原始请求 | server.go:1392-1407 | `originalRequest` 只拷 4 个字段,url 复用栈上变量防逃逸(server.go:1379) |
| 条件缓冲响应 | responsewriter.go:88-100 | 不需要缓冲就纯流式,buffer 建议取自池 |
| 路由级 metrics | routes.go:313-321 | 每路由包一次而非每 handler(#4644) |
| 保守头部上限 | app.go:269-273 | MaxHeaderBytes 默认从 1MB 收紧到 16KB |
| 惰性超时 | server.go:588-614 | IdleTimeout 读写器只在停滞时触发,替代硬超时 |

**与 nginx 的对照**:nginx 用固定 worker + 事件驱动状态机,epoll/kqueue 自己管;Caddy 把这些交给 Go runtime 的 netpoll,每连接一个 goroutine(`go srv.server.Serve(ln)`,app.go:631,实际由 stdlib 逐 conn 起 goroutine),handler 写成同步阻塞风格即可。代价是每 conn/请求的栈与调度开销,换来的是中间件可以用普通的函数调用语义(`next.ServeHTTP`)而非回调状态机——Caddy 的"响应上行"模型正是依赖这一点。Server 甚至显式对照了 nginx 的 `sendfile_max_chunk`(`MaxWriteChunk`,server.go:113-119)。

---

## 9. 设计动机

1. **为什么路由显式排序而非最长匹配?** 显式顺序让"哪条路由生效"完全可预测、可审查,配置即真相;最长匹配会把语义藏进实现(nginx location 的 priority 规则是著名的学习难点)。Caddy 把排序权交给用户,只对自动生成的重定向路由做确定性排序(autohttps.go:424-454),并提供 Group(互斥)和 Terminal(截断)两个显式控制面。
2. **为什么 matcher 是模块?** 与 A 章模块体系一脉相承:匹配条件是不可枚举的业务需求(IP 段、CEL 表达式、TLS 状态……),开放 `http.matchers` 命名空间让第三方无侵入扩展;同时 matcher 与 handler 解耦,同一 matcher 可用于 route、rewrite、错误路由等任何需要条件的地方。代价是 matcher 间无法共享数据结构(所以 path 只能各自线性扫)。
3. **与 nginx location 的哲学差异**:nginx 把 location 组织为树并在编译期做前缀聚合,单请求匹配 O(path 长度);Caddy 的 Route 是"条件+管道"的列表,匹配 O(路由数)。Caddy 用请求内链式管道(一条请求可依次穿过多条路由直到 Terminal/内容源)换取表达力——nginx 的 rewrite/return/proxy 是离散指令,Caddy 的 handlers 是可组合的洋葱层。
4. **为什么 ServeHTTP 返回 error?** 错误处理被提升为一等公民:任何 handler(包括 matcher)随时上抛,由统一的 `errorHandlerChain` 接管,避免每个中间件手写错误响应逻辑。

---

## 10. FAQ 素材

1. **Caddy 的 path matcher 用 trie 吗?** 不用。是模式列表线性扫描 + stdlib `path.Match` glob(matchers.go:440,529),路由匹配总体 O(路由数 × 模式数)。
2. **一条请求会命中多条路由吗?** 会。未 Terminal 的路由命中后执行其 handlers,再滑向下一条路由(nextCopy 机制,routes.go:269-281);想只命中一条就配 `terminal` 或互斥 `group`。
3. **`/foo*` 和 `/foo/*` 区别?** 前者匹配 `/foobar`;后者不匹配 `/foo` 本身也不匹配 `/foobar`(matchers.go:76-78)。
4. **path 匹配大小写敏感吗?** Caddy 强制不敏感以防跨平台绕过,需敏感匹配用 path_regexp(matchers.go:430-436)。
5. **两个 server 能监听同一端口吗?** 不能,Validate 直接报错"listener address repeated"(app.go:429-444);:80 的重定向流量通过把路由注入现有 server 或建 `remaining_auto_https_redirects` 解决(autohttps.go:469-502)。
6. **300 个站点 host matcher 会慢吗?** >100 条自动切换排序+二分精确匹配(matchers.go:318-330)。
7. **中间件顺序错了会怎样?** 响应自下而上流回,`encode` 必须在 `templates` 之前,否则 templates 收到压缩二进制(routes.go:61-77 官方示例)。
8. **access log 怎么拿到状态码?** ResponseRecorder 包装 ResponseWriter 记录 status/size(responsewriter.go:65-75),仅在配置了日志时才包装(server.go:652-654)。
9. **HTTP 明文打到 HTTPS 端口会怎样?** 默认报协议错误;可配 `caddy.listeners.http_redirect` wrapper 在 TLS 前探测明文并重定向(httpredirectlistener.go:21-28)。
10. **matcher 返回错误会怎样?** 短路整条链,交给服务器错误路由处理(routes.go:272-277)。

## 11. 深挖清单

1. `wrapRoute` 中 `nextCopy := next` 的指针陷阱注释(routes.go:259-269)——闭包共享变量导致的全链污染 bug 防御,讲 Go 闭包语义的好案例。
2. 转义空间路径匹配状态机 `matchPatternWithEscapeSequence`(matchers.go:537-655)——`%*` 通配、模式先耗尽时剩余路径必须参与比对(防前缀误配,matchers.go:635-647)。
3. 多 matcher 组合的 Group 互斥实现:ctx 里的 `map[string]struct{}` 在 `PrepareRequest` 初始化(server.go:1377),路由执行时读写(routes.go:286-297)——无锁,因为单请求内串行。
4. IdleTimeoutReader/Writer 的"停滞检测 vs 硬超时"双层模型 + `MaxWriteChunk` 分块(server.go:588-614,idletimeout.go),对照 nginx slowloris 防护。
5. CEL 表达式 matcher 的编译与 CELLibrary 双轨(声明式 JSON 与表达式等价性,celmatcher.go:61-227)。

## 12. 写作要点速查表

| 事实 | 位置 |
|---|---|
| Route 结构(match/-handle/terminal/group) | routes.go:31-105(Group:37,match:43,handle:92,terminal:95) |
| 路由表编译:逆序叠链 | routes.go:239-249(`slices.Backward` 245) |
| 请求期路由判定 + Group + Terminal + 叠链 | routes.go:256-326(272 匹配,286 组,300 终端,309 叠链) |
| handler 预编译成 middleware | routes.go:180-184 |
| MiddlewareHandler/Middleware/Handler 接口 | caddyhttp.go:65-92 |
| emptyHandler 置 unhandled / errorEmptyHandler | caddyhttp.go:95-98 / 104-112 |
| PathMatcher 线性扫描 + path.Match(非 trie) | matchers.go:429-535(glob 529) |
| HostMatcher >100 条二分优化 | matchers.go:318-330;large():399;fuzzy():394 |
| matcher 模块注册(http.matchers 命名空间) | matchers.go:222-233 |
| Server.ServeHTTP 请求入口 | server.go:551(PrepareRequest 634-635;challenge 696;错误分支 708-780) |
| primaryHandlerChain 编译与包装 | app.go:366-376;enforcementHandler server.go:899-918 |
| 每个 server 独占监听地址校验 | app.go:425-456(报错 440) |
| 监听建立/TLS/go Serve | app.go:540-667(useTLS 566,tls.NewListener 598,Serve 631,h3 657) |
| 自动 HTTPS 重定向路由生成与注入 | autohttps.go:362-502;makeRedirRoute 544-579(308+Close) |
| Subroute 每请求编译 | subroute.go:72-74 |
| ResponseRecorder 条件缓冲 | responsewriter.go:65-143(WriteHeader 决策 148-173) |
| 日志惰性克隆 r.Clone+WithLazy | server.go:637-645;logRequest server.go:1218 |
| SanitizedPathJoin 防穿越 | caddyhttp.go:252-274;fileHidden staticfiles.go:735 |
| sync.Pool 群 | encode/encode.go:214;reverseproxy/reverseproxy.go:1848;browse.go:350 |
| 路由级 metrics(#4644) | routes.go:313-321 |

---
*报告完。所有行号基于 commit 56e3a88 实测(grep -n / Read)。*
