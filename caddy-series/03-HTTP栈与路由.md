# 第 03 章 · HTTP 栈与路由:显式顺序与预编译链

> 基线:commit `56e3a88`。行号以 modules/caddyhttp/ 为准。**勘误**:Caddy 的路由**不是最长匹配树**——是显式顺序的线性列表;PathMatcher 也不是 trie——是模式列表线性扫描+glob(matchers.go:429-529)。

## 3.0 全景:一个请求的旅程

```
连接 → TLS(SNI 查证书缓存,02 章)→ Server.ServeHTTP(:551)
  → enforcementHandler(SNI-Host 校验 :899-918)
  → 顶层路由链(Provision 期一次编译 app.go:370-376)
  → 逐 Route:matcher 评估→命中则预编译 handler 链执行(:309-311)
  → 未 Terminal 继续下一条 → errorHandlerChain(错误分支 :708-780)
```

路由模型:RouteList=[]Route 的**显式顺序线性列表**。Route=matcher 组(集合间 OR、集内 AND,AnyMatchWithError :430-438)+有序 handler 组+group(互斥)/terminal(截断)两个控制面;catch-all=空 matcher 集(:437)。**唯一隐式排序**在自动 HTTPS 重定向注入前(精确>通配>catch-all,autohttps.go:424-454)。

## 3.1 matcher:线性扫描与二分阈值

PathMatcher **不是 trie**:模式列表线性扫描+stdlib path.Match glob(:429-529);HostMatcher >100 条启用排序+二分精确匹配(large() :399,二分 :318-330)——**host 基数大(多租户)才值得二分,path 需要通配所以线性**。matcher 是 `http.matchers` 命名空间模块(:222-233),可自定义或 CEL 表达式(celmatcher.go:61)。

## 3.2 中间件链:Provision 期预编译

每条 Route 的 handler 链在 **Provision 期预编译**为 []Middleware 闭包(routes.go:180-184);顶层完整链在 app Provision 一次编译缓存(routes.go:239-249,逆序叠链 slices.Backward :245);仅 subroute 每请求 Compile(subroute.go:73)。请求期 wrapRoute(:256-326)先评估 matcher,命中后把预编译链**从后往前叠到 next 上**(:309-311)再执行;`MiddlewareHandler.ServeHTTP(w,r,next)` 收 next 为参、**可返回 error 上抛**给服务器级 errorHandlerChain;链尾 emptyHandler 置 `{http.vars.unhandled}`。路由级 metrics 只包一次(:313-321,#4644)。

## 3.3 性能与自动 HTTPS 衔接

监听:每个 server 独占监听地址(app.go:425-456);TLS 建立 tls.NewListener(:598),`go srv.server.Serve(ln)`(:631)——**Go 标准库 http.Server+goroutine per conn**(与 nginx 事件模型的根本分野:并发模型语言级内建);自动 HTTPS 重定向路由 makeRedirRoute 生成 308+Close(autohttps.go:544-579),注入现有 :80 server 或建 `remaining_auto_https_redirects`(:469-502)。sync.Pool 遍布 encode/reverseproxy/browse/templates;ResponseRecorder 条件缓冲供访问日志(:65-173);日志 r.Clone+WithLazy 惰性编码(:637-645);防穿越 SanitizedPathJoin(caddyhttp.go:252-274)+fileHidden(staticfiles.go:735)。

## 3.4 设计动机

1. **为什么显式顺序而非最长匹配**:顺序是用户可推理的确定性(写在前先生效);最长匹配树是 nginx/location 的魔法——**可预测性 vs 便利性的哲学分野**;
2. **预编译链**:matcher 评估与 handler 调用的分离发生在配置装载期——请求期零构造(对照 FFmpeg 预编译描述符链);
3. **handler 可返回 error**:错误统一上抛到 errorHandlerChain——错误处理是链的一部分而非散落各处;
4. **goroutine per conn**:Go 的并发模型让"每连接一协程"免费——nginx 的事件模型是 C 语言约束的产物。

## 3.5 FAQ

**Q1:两条路由都匹配谁执行?**
按显式顺序都执行(除非 terminal/group)(:309-311)——与 nginx 的"选一个 location"根本不同。

**Q2:PathMatcher 是树吗?**
不是:线性扫描+glob(:429-529);HostMatcher 大于 100 条才二分(:399)。

**Q3:中间件链每次请求重建吗?**
顶层链编译一次缓存(:370-376);只有 subroute 每请求编译(subroute.go:73)。

**Q4:路由怎么写"否则"?**
catch-all=空 matcher(:437);或 group 互斥。

**Q5:HTTP→HTTPS 重定向哪来的?**
自动生成 308 路由(:544-579),注入 :80 server。

**Q6:错误怎么统一处理?**
handler 返回 error 上抛到 errorHandlerChain(:708-780):错误路由也可配置。

**Q7:静态文件的穿越防护?**
SanitizedPathJoin(:252-274)+fileHidden(:735)。

**Q8:两个 server 能共享端口吗?**
不能,必须独占(:425-456):端口级 server 隔离。

**Q9:性能靠什么?**
预编译链+sync.Pool+goroutine per conn:解释型开销用 Go 运行时摊平。

**Q10:matcher 能自定义吗?**
能:http.matchers 命名空间模块或 CEL 表达式(celmatcher.go:61)。

## 3.6 小结与深挖方向

本章结论:**HTTP 栈="显式顺序线性路由+Provision 期预编译链+error 链统一"**;与 nginx 的对照是"可推理 vs 魔法"的哲学分野。深挖:

1. HostMatcher 二分阈值 100(:399)的实测拐点;
2. subroute 每请求 Compile(:73)的热路径成本;
3. ResponseRecorder 缓冲(:65-173)对大响应的内存;
4. enforcementHandler(:899-918)与自动 HTTPS 的握手契约;
5. CEL matcher(celmatcher.go:61)的表达力边界。

> 下一章:反向代理——最重要的 handler 模块。
