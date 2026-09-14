# 第 10 章 · web 层与 API:面向用户的最外层(卷末)

> 基线:commit `b0f312b`。行号以 web/web.go、web/api/v1/api.go、cmd/prometheus/main.go 为准。

## 10.0 全景:web 层组装

```
main.go 三件套:localStorage=&readyStorage{}(:953)
  → cfg.web.Storage/LocalStorage/QueryEngine 注入(:1076-1082)
  → webHandler := web.New(:1109;NewAPI 收 40+ 实参 :393-442)
  → Handler.Run:av1 子路由挂 /api/v1+StripPrefix(:753-766)
  → otelhttp+withStackTracer 包裹(:770-778)→ toolkit_web.ServeMultiple(:782)
     (--web.config.file 的 TLS/basic auth 唯一生效点)
```

**就绪门控双保险**:readyStorage.Querier 未 Set 返回 tsdb.ErrNotReady(main.go:1911-1917),API 层转 503(api.go:406-411);SetReady(web.Ready) 在 TSDB 打开+首载配置后才调(main.go:1483)。testReady(:681-699):503+`X-Prometheus-Stopping` 头区分未就绪/停止中。**/status/walreplay、/notifications 是仅有的无 ready 门控端点**(:486-488)——WAL 回放期间可轮询进度。

## 10.1 API 面:35 个端点与统一封装

`API.Register`(api.go:414-515)一次挂约 35 个端点(query/query_range/series/labels 家族/targets/rules/alerts/metadata/status…);wrap 统一 CORS→错误包装→api.ready→gzip→OpenAPI 包装(:415-436);wrapAgent 在 Agent 模式禁查询类(:438-445)。响应统一 `Response{status,data,errorType,error,warnings,infos}`(:199-207);错误码映射 bad_data→400/execution→422/canceled→499/timeout→503(:2360-2379);JSONCodec 用 **jsoniter 手写流式编码**(json_codec.go:71-235)。query_range 硬闸 **11000 点/序列**(:736-741);/write、/otlp/v1/metrics 仅在 receiver flag 开启时创建否则 404(:490,:379-389,呼应 G 报告)。

## 10.2 生命周期端点与配置

`--web.enable-lifecycle` 开则注册 /-/quit、/-/reload(web.go:581-603),关则 403;**reload 消费端"chan 塞 chan"把 HTTP reload 变成同步 RPC**,串行化并发 reload(main.go:1419-1437)。UI 经 builtinassets build tag **go:embed 进二进制**(web/ui/assets_embed.go:14-22),index.html 请求时做 5 处占位符替换(web.go:525-529)。稳定性承诺(docs/stability.md):大版本内稳定(:7)、v1 API 稳定但排除显式实验端点(:16)、remote read 与服务端 HTTPS/basic auth 不稳定(:28-29);破坏性变更以警告过渡(stats 参数弃用警告 api.go:698-708)。

## 10.3 设计动机

1. **API 稳定性承诺是产品合同**:stability.md 把"稳定/实验/不稳定"分级显式化——调用方(Alertmanager/Grafana/kubelet)依赖这份合同;
2. **就绪双门控**:存储未开(503+可轮询 walreplay)与停止中(503+Stopping 头)是两种"不可用"——K8s 的 liveness/readiness 探针各取所需;
3. **lifecycle 端点默认关**:/-/quit 等于给网络一个"杀进程"按钮——默认关闭是安全默认;
4. **jsoniter 手写流式编码**:查询结果可能巨大,流式编码避免全量物化——API 层的性能自觉。

## 10.4 FAQ

**Q1:/-/reload 返回 403?**
--web.enable-lifecycle 未开(web.go:581-603);用 SIGHUP 替代。

**Q2:查询返回 503 是故障吗?**
区分:未就绪(TSDB 打开中)/停止中(Stopping 头)/真错误——三态(:681-699)。

**Q3:query_range 为什么限 11000 点?**
(:736-741):响应矩阵的内存上界;需要更多就分段或降步长。

**Q4:UI 是怎么进二进制的?**
go:embed(web/ui/assets_embed.go:14-22):单二进制分发包含完整 UI。

**Q5:OTLP 端点是什么?**
/opentlp/v1/metrics(:379-389):OpenTelemetry 直写的接收端,flag 开启才存在。

**Q6:API 的错误码怎么映射?**
(:2360-2379):bad_data 400/execution 422/canceled 499/timeout 503。

**Q7:TLS/basic auth 配置在哪生效?**
toolkit_web.ServeMultiple 的 listener 层(:782):API handler 无感知。

**Q8:并发 reload 会冲突吗?**
"chan 塞 chan"串行化(main.go:1419-1437):HTTP 调用变成同步 RPC。

**Q9:v1 API 永远不变吗?**
大版本内稳定(:7);实验端点排除;破坏性变更以警告过渡(:698-708)。

**Q10:Agent 模式的 API 少什么?**
wrapAgent 禁查询类(:438-445):Agent 无本地数据可查。

## 10.5 小结与卷二卷末语

本章结论:**web 层="统一响应封装+就绪三态+生命周期端点默认关+稳定性分级承诺"**。

至此《Prometheus 深读》卷二完(G-J 报告+07-10 正文,基线 commit b0f312b)。两卷合计:卷一 7 章(全景/Head/磁盘/WAL/查询/抓取/工程)+ 卷二 4 章(remote_write/rules/K8s SD/web),11 章+10 份报告。Prometheus 的全链:发现→抓取→WAL→内存→磁盘→查询→告警→remote 读写,与系列前作(LevelDB 的 LSM、Git 的引用图、PG 的 WAL)形成监控领域的完整对位。深挖方向:

1. otelhttp 包裹(:770-778)的 trace 上下文传播到抓取;
2. jsoniter 流式编码(:71-235)在 10 万 series 响应的分块;
3. Stopping 头(:681-699)与 K8s preStop hook 的配合;
4. /write 的 OOO 400(:115-118)与发送端重试的博弈;
5. React UI 的 embed 更新与版本错位。

— 《Prometheus 深读》卷二完。AI 编码助手:GLM-5.3-Flash。
