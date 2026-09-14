# J 章 · Web 层与 HTTP API 全貌

> 依据 commit `b0f312b`（shallow clone）核对，行号以该版本为准。
> 卷一 A 报告只点了 API 入口；本章展开 web 层完整组装、API 全量端点、生命周期与安全面。

## 1. 全景：web 层的组装

入口在 `cmd/prometheus/main.go`：先造好"存储三件套"，再塞进 `web.Options`，最后 `web.New` 一把组装。

- `localStorage = &readyStorage{...}`（cmd/prometheus/main.go:953）——TSDB 就绪门控的壳；
- `cfg.web.Storage = fanoutStorage`（本地+远程 fanout）、`cfg.web.LocalStorage = localStorage`、`cfg.web.QueryEngine = queryEngine`（cmd/prometheus/main.go:1076-1082）；
- `webHandler := web.New(logger.With("component", "web"), &cfg.web)`（cmd/prometheus/main.go:1109）。

### 1.1 路由的三层结构

Prometheus 的 HTTP 面实际是**三条路由树**并存，理解这点就不会迷路：

1. **主 router**（`web.New` 里创建，web/web.go:337）：承载 UI、`/metrics`、`/federate`、`/consoles`、`/-/*` 健康/生命周期、`/debug/pprof`，全部硬编码在 web/web.go:486-621；
2. **api v1 子 router**（`Run` 时创建，web/web.go:761-764）：`h.apiV1.Register(av1)` 挂 `/api/v1/*`，用 `http.StripPrefix` 剥前缀后交给子 router（web/web.go:766）。它有独立的仪表化前缀 `"/api/v1"`，所以 `prometheus_http_requests_total{handler="/api/v1/query"}` 能精确到端点；
3. **federate 与 consoles 是主 router 上的"独立 API"**，不经过 api v1 的 JSON 封装（federate 走 expfmt 文本/protobuf 协商，web/federate.go:55 起）。

`--web.route-prefix` 的处理顺序值得注意：先在原 router 挂 `/` → 前缀的重定向（web/web.go:468-472），再 `router = router.WithPrefix(o.RoutePrefix)` 整体搬家（web/web.go:473）；apiPath 则在 `Run` 里拼接（web/web.go:756-763）。两条路径都改，才保证 UI 与 API 同时前缀化。

### 1.2 仪表化中间件

每个路由都过两层 `WithInstrumentation`：一层加指标（`instrumentHandler`，web/web.go:195-207，counter/duration/size 三件套 curry 了 handler 标签），一层把"带前缀的真实路径"塞进 request context（`setPathWithPrefix`，web/web.go:982-988）——这是 `route.Param` 能取到通配参数的前提。

```
main.go
  │ readyStorage(壳) ──TSDB 打开后 localStorage.Set(db)──▶ 真身 (main.go:1540)
  │ fanoutStorage = localStorage + remoteStorage
  ▼
web.New(logger, *Options)                          web/web.go:328
  │ route.New().WithInstrumentation(指标+前缀)      web/web.go:337-339
  │ api_v1.NewAPI(qe, queryable, appender, ..., )  web/web.go:393-442
  │ 注册 UI/健康/lifecycle/debug 路由               web/web.go:486-621
  ▼
Handler.Run(ctx, listeners, webConfig)             web/web.go:744
  │ mux.Handle("/", h.router)                      web/web.go:754
  │ av1 := route.New(); h.apiV1.Register(av1)      web/web.go:761-764
  │ mux.Handle("/api/v1/", StripPrefix(av1))       web/web.go:766
  │ otelhttp + withStackTracer 包住 mux             web/web.go:770-778
  ▼
toolkit_web.ServeMultiple(listeners, httpSrv,      web/web.go:782
    FlagConfig{WebConfigFile: &webConfig})   ◀── TLS/BasicAuth 在这层生效
```

要点：**API v1 不在 `web.New` 的 router 上**，而是在 `Run` 时另起一个 `av1` 子 router 挂到 mux（web/web.go:761-766）；`--web.route-prefix` 会同时改写 apiPath 与主 router 前缀（web/web.go:468-474、756-763）。主 router 自带请求指标（`prometheus_http_requests_total` 等三件套 + `prometheus_ready`，web/web.go:148-187）与 panic 栈日志（`withStackTracer`，web/web.go:126-139）。

## 2. API 面专节：端点清单

`API.Register`（web/api/v1/api.go:414-515）一次挂完。`wrap` 是统一外壳：SetCORS → TSDB 未就绪转 503（`setUnavailStatusOnTSDBNotReady`，api.go:406-411）→ `api.respond` JSON 包装 → `CompressionHandler` gzip → OpenAPI 观测包装（api.go:415-436）。`wrapAgent` 让查询类端点在 Agent 模式直接报"unavailable with Prometheus Agent"（api.go:438-445）。

响应统一封装：`Response{status,data,errorType,error,warnings,infos}`（api.go:199-207）；成功走 `respond`（api.go:2280-2309），经 `negotiateCodec` 按 Accept 头协商（api.go:2311-2326，默认 `JSONCodec`，api.go:368）；失败走 `respondError`（api.go:2328-2358），错误码映射见 `getDefaultErrorCode`（api.go:2360-2379）：bad_data→400、execution→422、canceled→499、timeout→503、internal→500、not_acceptable→406。

`wrap` 的完整外壳（所有 JSON 端点的公共路径）：

```go
wrap := func(f apiFunc) http.HandlerFunc {
    hf := http.HandlerFunc(func(w ResponseWriter, r *Request) {
        httputil.SetCORS(w, api.CORSOrigin, r)
        result := setUnavailStatusOnTSDBNotReady(f(r))
        if result.finalizer != nil { defer result.finalizer() }
        if result.err != nil { api.respondError(w, result.err, result.data); return }
        if result.data != nil { api.respond(w, r, result.data, result.warnings, ...); return }
        w.WriteHeader(http.StatusNoContent)
    })
    return api.ready(httputil.CompressionHandler{
        Handler: api.openAPIBuilder.WrapHandler(hf),
    }.ServeHTTP)
}                                                    // web/api/v1/api.go:415-436
```

注意三层嵌套语义：最内是业务函数 → CORS 与错误包装 → `api.ready`（即 web 传进来的 `testReady`，WAL 回放未完成前一律 503）→ gzip。错误类型枚举共 9 种（api.go:92-113），`apiError` 只带类型+底层 err（api.go:122-129）；promql 引擎错误经 `returnAPIError` 归类（api.go:860-882）：`ErrQueryCanceled→canceled`、`ErrQueryTimeout→timeout`、`ErrStorage→internal`，其余归 `execution`。

| 端点（/api/v1 前缀，GET/POST 双注册） | 关键参数 | 返回 data | 数据源 | 行号 |
|---|---|---|---|---|
| /query | query,time,timeout,limit,lookback_delta,stats | QueryData(resultType+result) | promql 引擎即时查询 | api.go:449,553 |
| /query_range | query,start,end,step(≤11000 点),timeout,limit | QueryData | promql 引擎范围查询 | api.go:451,710 |
| /query_exemplars | query,start,end | exemplar 列表 | ExemplarQueryable | api.go:453,822 |
| /format_query | query | 排版后表达式 | parser.Pretty | api.go:456,639 |
| /parse_query | query | AST JSON | translate_ast.go | api.go:459,648 |
| /labels | start,end,match[],limit | label 名列表 | Querier.LabelNames | api.go:462,884 |
| /label/:name/values | 同上；U__ 前缀 UTF-8 名反转义 | label 值列表 | Querier.LabelValues | api.go:464,961 |
| /series | match[](必填),start,end,limit | labels 列表 | Querier.Select(只取 labels) | api.go:466,1082 |
| /scrape_pools | - | scrape pool 名单 | scrape.Manager | api.go:469,1281 |
| /scrape_pools/config | scrapePool | pool 配置 YAML | ScrapePoolConfig | api.go:470,1288 |
| /targets | state,scrapePool | active/dropped 目标 | scrape.Manager | api.go:471,1307 |
| /targets/metadata | match_target,metric,limit | 每目标元数据 | scrape.Target | api.go:472,1403 |
| /targets/relabel_steps | scrapePool,labels(JSON) | 逐步 relabel 结果 | relabel.ProcessBuilder | api.go:473,1481 |
| /alertmanagers | - | active/dropped AM URL | notifier.Manager | api.go:474,1531 |
| /metadata | metric,limit,limit_per_metric | 指标元数据聚合 | 各 target 元数据缓存 | api.go:476,1593 |
| /status/config | - | 生效配置 YAML | web Handler 的 config 副本 | api.go:478,1946 |
| /status/runtimeinfo | - | 运行时信息 | web.runtimeInfo | api.go:479; web.go:873 |
| /status/buildinfo | - | 版本五元组 | 启动注入的 buildInfo | api.go:480,1942 |
| /status/flags | - | 启动 flags map | kingpin 导出 | api.go:481,1953 |
| /status/tsdb | limit(默认10,≤10000) | head 统计+基数 TopN | TSDBAdminStats.Stats | api.go:482,2059 |
| /status/tsdb/blocks | - | block 元数据列表 | TSDBAdminStats.BlockMetas | api.go:483,2046 |
| /status/self_metrics | metric_name_pattern | 自身指标(protojson) | prometheus Gatherer | api.go:484,2014 |
| /features | - | 特性注册表快照 | features.Registry | api.go:485,1973 |
| /status/walreplay | - | {min,max,current} | db.WALReplayStatus（无门控，回放期可查） | api.go:486,2110 |
| /notifications, /notifications/live | - | 通知列表 / SSE 流 | notifications 包 | api.go:487-488,2124 |
| /read | protobuf body | remote read 响应 | remote.ReadHandler | api.go:489,2175 |
| /write | protobuf body | 204 | remote.WriteHandler（需开 receiver） | api.go:490,2184 |
| /otlp/v1/metrics | OTLP body | 200/204 | remote.OTLPWriteHandler（需开 receiver） | api.go:491,2192 |
| /search/metric_names 等 3 个 | limit 等 | 搜索结果 | 索引搜索（--enable-feature=search-api） | api.go:494-499 |
| /alerts | - | 活动 alert | rules.Manager | api.go:501,1559 |
| /rules | type,rule_name[],rule_group[],file[],match[],exclude_alerts,group_limit+group_next_token | 规则组(带分页 token=sha256) | rules.Manager | api.go:502,1718 |
| /admin/tsdb/delete_series 等 3 个 | match[],start,end/skip_head | 204 或快照名 | TSDBAdminStats（需 --web.enable-admin-api） | api.go:505-511,2200 |
| /openapi.yaml | - | OpenAPI 3.1/3.2 文档 | OpenAPIBuilder | api.go:514 |

参数解析工具集中在文件尾：`parseTime` 支持浮点秒与 RFC3339Nano（api.go:2393-2414）、`parseDuration` 支持浮点秒与 `model.ParseDuration`（api.go:2416-2429）、`parseMatchersParam` 强制至少一个非空 matcher（api.go:2431-2447）、`parseLimitParam`+`toHintLimit`（多取 1 条以便产出截断警告，api.go:2450-2474）。query 类的会话级收尾靠 `apiFuncResult.finalizer`：qry.Close 挂在结果上，由 `wrap` defer 执行（api.go:419-421、597-601）。

## 3. 生命周期端点专节：/-/reload 与 /-/quit

权限模型一句话：**默认全关，开关只有 `--web.enable-lifecycle`，无内置鉴权**。该 flag 默认 `false`（cmd/prometheus/main.go:470-472）：

```go
if o.EnableLifecycle {
    router.Post("/-/quit", h.quit)
    router.Put("/-/quit", h.quit)
    router.Post("/-/reload", h.reload)
    router.Put("/-/reload", h.reload)
} else {
    forbiddenAPINotEnabled := func(w http.ResponseWriter, _ *http.Request) {
        w.WriteHeader(http.StatusForbidden)
        w.Write([]byte("Lifecycle API is not enabled."))
    }
    ...四条路由全部替换为 403                 // web/web.go:581-595
```

GET 则一律 405 "Only POST or PUT requests allowed"（web/web.go:596-603）。开启后：

- **reload**：`h.reload` 向 `reloadCh` 发一个应答 chan 并阻塞等待（web/web.go:962-968）；main.go 的 reload goroutine 收到后跑完整 `reloadConfig`（全部 reloader，含 webHandler.ApplyConfig，cmd/prometheus/main.go:1152、1419-1437），失败把 error 回传，HTTP 返回 500 + 错误文本。它与 SIGTERM 走同一条 reload 路径。
- **quit**：`quitOnce` 保证只关一次 `quitCh`（web/web.go:950-960）；main.go 在 `case <-webHandler.Quit()` 里 `SetReady(web.Stopping)`（cmd/prometheus/main.go:1283、1292）开始优雅退出。
- **ready/healthy**：`/-/healthy` 无条件 200（web/web.go:608-614）；`/-/ready` 经 `testReady` 门控——NotReady/Stopping 都返回 503，并带 `X-Prometheus-Stopping` 头区分两种状态（web/web.go:615-621、681-699）。`SetReady(web.Ready)` 只在"TSDB 打开 + 首次配置加载完成"后调用（cmd/prometheus/main.go:1474-1485）。

就绪门控的另一半在存储侧。TSDB 未 Set 前，`readyStorage.Querier` 直接返回哨兵错误：

```go
func (s *readyStorage) Querier(mint, maxt int64) (storage.Querier, error) {
    if x := s.get(); x != nil {
        return x.Querier(mint, maxt)
    }
    return nil, tsdb.ErrNotReady
}                                        // cmd/prometheus/main.go:1911-1917
```

于是"进程活着但 TSDB 没好"的请求有两种 503 来源：走 `/-/ready` 的 `testReady`（看 `atomic.Uint32` 状态位，web/web.go:250、663-678），和走 API 的 `setUnavailStatusOnTSDBNotReady`（看 error 链是否 `errors.Is(..., tsdb.ErrNotReady)`，api.go:406-411）。二者最终一致，因为 `SetReady(web.Ready)` 发生在 `localStorage.Set(db, ...)`（main.go:1540）之后的首次配置加载完成时（main.go:1483）。

由此可见安全边界完全在网络层：要么不开 flag，要么用反向代理/防火墙挡住 9090 的写路由——`--web.config.file` 的 basic auth 是目前唯一内置的请求级防线。

## 4. web 配置专节：TLS 与 Basic Auth 的加载

`--web.config.file`（标注 [EXPERIMENTAL]，cmd/prometheus/main.go:445-447）**不在 Prometheus 里解析**，交由 exporter-toolkit：

- 启动前先 `toolkit_web.Validate(*webConfig)` 校验（cmd/prometheus/main.go:1264）；
- 实际服务用 `toolkit_web.ServeMultiple(listeners, httpSrv, &toolkit_web.FlagConfig{WebConfigFile: &webConfig}, logger)`（web/web.go:782）——它在 net.Listener 外包一层 TLS（`tls.Config` 由配置文件 `tls_server_config` 生成）与 `basic_auth`（bcrypt 校验），因此**对所有路由生效，包括 /api/v1/write 与 /-/quit**；
- 文件支持热重载（toolkit 内部 fsnotify），Prometheus 侧无感知。

能力清单（toolkit 侧语义）：`basic_auth`（username/password_hash）、`tls_server_config`（证书/密钥、client auth、 cipher 套件）、`http_server_config`（HTTP/2、headers）、`server_name`。注意 docs 把"服务端 HTTPS 与 basic auth"列为 3.x **不稳定**特性（docs/stability.md:29），客户端用 Grafana 等反代终止 TLS 仍是社区主流。

其他传输层参数：`--web.read-timeout` 默认 5m（cmd/prometheus/main.go:449-451，落到 http.Server.ReadTimeout，web/web.go:777）、`--web.max-connections` 512（经 `netconnlimit` 共享信号量包在 listener 上，web/web.go:726-741）。

## 5. 设计动机

**API 稳定性承诺。** 官方文档明说"Prometheus promises API stability within a major version"（docs/stability.md:7），v1 HTTP API 属于 3.x 稳定面，但"显式标注实验的端点除外"（docs/stability.md:16）；remote read 端点则明确不稳定（docs/stability.md:28）。api.go 的版本策略体现在细节里：只有 `/api/v1` 一条稳定前缀（docs/querying/api.md:6），新能力靠**参数级**渐进——如 `stats` 参数非枚举值先回警告、下个大版本才拒绝（api.go:698-708），`limit` 截断也以 warnings 提示而非硬错（api.go:617-621）。这就是"v1 永远兼容"的操作化定义：不换路径、只加字段、破坏先降级为警告。

**UI 内嵌。** React 应用（新版 mantine-ui，旧版 react-app）通过 build tag 双轨进包：`builtinassets` 时 `//go:embed` 进二进制（web/ui/assets_embed.go:14-22），否则开发态直接读磁盘 web/ui/static（web/ui/ui.go:14 起）。运行时 `ui.Assets` 被 `server.StaticFileServer` 服务（web/web.go:571-575），index.html 在每次请求时做 5 处占位符替换（consoles 链接、标题、agent 模式、就绪态、lookback delta，web/web.go:525-529）。动机：单二进制分发、零静态资源部署。

**write 端点与 scrape 的分离。** `/api/v1/write` 与 `/api/v1/otlp/v1/metrics` 的 handler 仅在 `--web.enable-remote-write-receiver` / `--web.enable-otlp-receiver` 打开时才创建，否则挂 404 提示开启 flag（api.go:379-389、2184-2198）；appender 也只在 receiver 开启时注入（web/web.go:384-386，nil 则 panic，api.go:375-377）。动机：Prometheus 的主摄入路径是 pull scrape，write receiver 是给"边缘推中心"这类拓扑的可选项，默认关闭避免误开成公开写入端点（G 报告详述 write_handler 内部）。

**gzip。** 响应压缩用 klauspost 实现的 `CompressionHandler`（util/httputil/compression.go:107-115），按 Accept-Encoding 选 gzip/deflate 并去掉 Content-Length（util/httputil/compression.go:51-59、62-88）；API 端点全部包在 wrap 里（api.go:433），federate 也包（web/web.go:504-506）。大矩阵查询的 JSON 常是几十 MB，压缩收益直接体现在带宽上。

## 6. FAQ 素材

1. **为什么 503 有两种？** TSDB 未就绪时查询类端点经 `setUnavailStatusOnTSDBNotReady` 把 `tsdb.ErrNotReady` 转 errorUnavailable→503（api.go:406-411）；而 WAL 回放期间 `/-/ready` 也是 503（web/web.go:681-699），但 `/status/walreplay` 不挂 ready 门控、回放中就能轮询进度（api.go:486、2110）。
2. **`/api/v1` 会出 v2 吗？** 策略是"大版本内稳定 + 参数级演进"（docs/stability.md:7-16），历史上从未有 v2 计划；破坏性变更先以 warnings/弃用警告过渡（api.go:698-708）。
3. **Agent 模式下哪些 API 消失？** 查询/labels/series/rules/alerts 等被 `wrapAgent` 替换为固定错误（api.go:438-445）；targets/metadata/status 类仍可用。
4. **`end.Before(start)`、step=0 之类错误码是什么？** bad_data→400；查询已执行但失败（含超时/取消）分别是 422/499/503（api.go:2360-2379、860-882）。499 是 nginx 血统的非标码（api.go:77-79）。
5. **响应能要 protobuf 吗？** 可协商 codec（api.go:2311-2326），但仓库只装了 JSONCodec（api.go:368）；remote read 的 protobuf 在 `/read` 另一条路径。
6. **query 会不会把内存打爆？** 有三道闸：range query 11000 点上限（api.go:736-741）、`limit` 截断并加警告（api.go:614-621）、`--query.max-samples`（引擎层，非本章）。
7. **`match[]` 为什么必须非空？** `parseMatchersParam` 拒绝全空 matcher 集，防止全库扫描（api.go:2431-2447）。
8. **rules 分页 token 是什么？** `sha256(file;group)` 的十六进制（api.go:1924-1928），配 `group_limit` 使用；组集合变化会导致 token 失效报 400（api.go:1870-1872）。
9. **UI 是怎么进二进制的？** `builtinassets` build tag + go:embed（web/ui/assets_embed.go:14-22）；发行版默认启用。
10. **basic auth 挡得住 /-/quit 吗？** 挡得住——toolkit 层在 listener 上，先认证后路由（web/web.go:782）；但不开 `--web.config.file` 时 lifecycle 全靠 `--web.enable-lifecycle` 默认关（cmd/prometheus/main.go:470-472）。

## 7. 深挖

1. **readyStorage 是"空洞但合法"的 Storage**：Querier/ChunkQuerier 在未 Set 时返回 `tsdb.ErrNotReady`（cmd/prometheus/main.go:1911-1917），Appender 同理；TSDB 打开 goroutine 里 `localStorage.Set(db, startTimeMargin)`（main.go:1540，agent 路径 1599）原子切换真身。web 层只认接口，"就绪"语义在存储壳里实现——这是 main.go 与 web 解耦的关键一针。
2. **OpenAPI 文档是代码生成的活物**：`NewOpenAPIBuilder`（api.go:358、openapi.go:67）在 Register 的 wrap 里给每个 handler 套观测（api.go:434），`/openapi.yaml` 按 Accept 输出 3.1/3.2 两版（api.go:514、docs/querying/api.md:11-13），并有 golden test 防漂移（openapi_golden_test.go）。
3. **JSON 编码器是手写的流式 unsafe 编排**：json_codec.go:71-235 用 jsoniter `stream` 直接写 Series/Sample/Point/Labels，跳过反射与空值判断（labelsIsEmpty 等），这是 /query 大结果集吞吐的主力优化。
4. **reload 的应答链是"chan 塞 chan"**：HTTP handler 把 `chan error` 塞进 `reloadCh`，main 的 reloader 循环消费并回填（web/web.go:962-968 ↔ cmd/prometheus/main.go:1419-1437）——把异步 reload 变成同步 RPC 的最小实现，同时天然串行化了并发 reload 请求。
5. **targets 端点的 URL 改写**：`getGlobalURL` 对 localhost:本端口 的 target 换算成 `--web.external-url` 的对外地址（api.go:1237-1279），这是 UI 从集群外点开 target 链接不出错的隐秘逻辑。
6. **federate 是 api v1 之外的"第二 API"**：直接读 `h.localStorage.Querier`（web/federate.go:80），expfmt 协议协商输出文本/protobuf（web/federate.go:75-78），自带独立错误/警告计数（web/federate.go:41-48）——不经过 JSON 封装，也不走 v1 的 codec 体系。

### 7.1 web 层的可观测性清单（写图时可用）

- `prometheus_http_requests_total{handler,code}` / `prometheus_http_request_duration_seconds{handler}` / `prometheus_http_response_size_bytes{handler}`：web/web.go:150-175；
- `prometheus_ready` gauge：web/web.go:176-179，由 `SetReady` 翻转（web/web.go:663-673）；
- `prometheus_web_federation_errors_total` / `..._warnings_total`：web/federate.go:41-48；
- OTel span：mux 层 `otelhttp`（web/web.go:770-775），query/queryRange 内再起 `promqlInstantQuery`/`promqlRangeQuery` span 并写入 result_series/total_samples 属性（api.go:579-585、760-768、533-551）；
- panic 防护：`withStackTracer` 记日志后原样 re-panic 交给 net/http（web/web.go:126-139）。

### 7.2 runtimeInfo 的"凑数"技巧

`/status/runtimeinfo` 的 `ReloadConfigSuccess`、`LastConfigTime`、`CorruptionCount` 不是独立状态变量，而是现场从自身 `/metrics` Gatherer 里捞三个指标的值拼出来的（web/web.go:912-925）——避免 web Handler 与 config 加载器之间再加同步通道，代价是依赖指标名这一"内部契约"（web/web.go:916-924 的 switch 硬编码 `prometheus_config_last_reload_successful` 等）。

### 7.3 consoles：web 层里藏着的模板引擎

`/consoles/*filepath` 是唯一在 web 包内做服务端模板渲染的路由（web/web.go:794-871）：读 `--web.console.templates` 目录，注入 `$params/$rawParams/$path/$externalLabels` 四个便利变量（web/web.go:831-836），用 promql 引擎作为 `QueryFunc` 展开模板（web/web.go:850-859），并 glob `*.lib` 作为模板库（web/web.go:860-865）。console 是 pre-UI 时代的监控页方案，因"完全用户可控、无 JS 框架依赖"存活至今。

## 写作要点速查表

| 事实 | 位置 |
|---|---|
| Handler 结构体（组装的全部依赖） | web/web.go:217-251 |
| Options（含 EnableLifecycle/EnableAdminAPI/LocalStorage） | web/web.go:269-325 |
| New：router+指标仪表化 | web/web.go:337-339 |
| New 调 api_v1.NewAPI（全部实参） | web/web.go:393-442 |
| lifecycle 路由注册/默认 403 | web/web.go:581-603 |
| /-/healthy、/-/ready 注册 | web/web.go:608-621 |
| testReady：503 + X-Prometheus-Stopping | web/web.go:681-699 |
| Run：av1 子路由挂 /api/v1 + StripPrefix | web/web.go:753-766 |
| toolkit_web.ServeMultiple（TLS/basic auth 生效点） | web/web.go:782 |
| quit/reload 实现 | web/web.go:950-968 |
| Register：wrap/wrapAgent + 全端点表 | web/api/v1/api.go:414-515 |
| Response 封装与 respond/respondError | web/api/v1/api.go:199-207、2280-2358 |
| 错误码映射 | web/api/v1/api.go:2360-2379 |
| query/queryRange（11000 点闸） | web/api/v1/api.go:553-637、736-741 |
| write/otlp receiver 挂载与 404 提示 | web/api/v1/api.go:379-389、2184-2198 |
| readyStorage 壳与 ErrNotReady | cmd/prometheus/main.go:953、1911-1917、1540 |
| SetReady(Ready) 时机（dbOpen+首载配置后） | cmd/prometheus/main.go:1474-1485 |
| reload 消费端（HTTP→reloadConfig 同步应答） | cmd/prometheus/main.go:1419-1437 |
| --web.config.file / --web.enable-lifecycle flag | cmd/prometheus/main.go:445-447、470-472 |
| gzip CompressionHandler | util/httputil/compression.go:107-115 |
| UI 双轨嵌入 | web/ui/assets_embed.go:14-22、web/ui/ui.go:14 |
| 稳定性承诺原文 | docs/stability.md:7、16、28-29 |
