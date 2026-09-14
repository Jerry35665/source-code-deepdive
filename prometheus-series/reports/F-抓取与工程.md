# F 卷 · 抓取与工程：服务发现、scrapeLoop 与 Prometheus 的工程文化

> 调研对象：prometheus/prometheus，commit `b0f312b`（b0f312ba48c9d31dad04e7014bfb0fa300153a07，2026-09-14 主干快照）。
> 本文所有行号均以该 commit 的仓库相对路径核对（grep -n / Read 实测）。

---

## 1. 全景：从服务发现到样本入库

```text
                          ┌────────────────────────────────────────────────┐
                          │            discovery.Manager                    │
                          │  providers []*Provider (file/consul/k8s/dns…)   │
                          │  targets map[poolKey]map[src]*targetgroup.Group │
                          └───────┬───────────────────────────┬────────────┘
             每个 provider 独立跑  │ (updater, manager.go:383) │ (sender, manager.go:413)
        Discoverer.Run(ctx,ups)──┘          合并去重入库        节流后全量快照
                  │                                               │
                  │  []*targetgroup.Group                SyncCh() chan map[job][]*tg
                  ▼                                               ▼ (main.go:1350)
       ┌──────────────────────┐                    ┌──────────────────────────────┐
       │ scrape.Manager.Run   │──reloader(5s tick)─►│ scrapePool (每个 job_name 一个)│
       │ (scrape/manager.go:223)│                   │  Sync() → TargetsFromGroup    │
       └──────────────────────┘                    │  = 目标重打标(第一阶段)         │
                                                   │  sync(): 按 hash 建/停 loop   │
                                                   └──────┬───────────────────────┘
                                                          │ 每个 target 一个 scrapeLoop
                                                          ▼
   ┌────────────────────────── scrapeLoop.run (scrape.go:1405) ──────────────────────────┐
   │ getScrapeOffset = initial + (target.hash ^ offsetSeed) % interval   ← 周期打散        │
   │ 每 interval: scrapeTime 对齐(±2ms) → scrapeAndReport:                                │
   │   HTTP GET(Accept 协商) → readResponse(gzip/zstd/限长)                                │
   │   → textparse.New 按 Content-Type 分派 parser                                        │
   │   → 逐样本: 目标标签合并(honor_labels) → 指标重打标(第二阶段) → Append 入 TSDB          │
   │   → report(): 写入 up / scrape_duration_seconds / … 自监控样本                        │
   │ 目标消失 → endOfRunStaleness: 注入 stale NaN;系列消失 → updateStaleMarkers            │
   └─────────────────────────────────────────────────────────────────────────────────────┘
```

三段式拓扑：`discovery.Manager` 把"世界长什么样"聚合成按 job 分组的目标集合；`scrape.Manager` 把每个 job 变成一个 `scrapePool`；每个 target 一个长期运行的 `scrapeLoop` goroutine，独立对齐周期、独立缓存序列引用。

---

## 2. 服务发现专节：Provider 注册与 SyncCh 的合并分发

### 2.1 机制清单（一行一个）

`discovery/` 目录下约 40 种机制（`discovery/registry.go:50` 用 `RegisterConfig` 插件式注册，static_configs 是唯一内置类型，其余由各包 init 注册，见 `discovery/registry.go:54-57`）：

| 机制 | 一句话 |
|---|---|
| static | 配置里直接写死 target 列表 |
| file | 监听 JSON/YAML 文件变化，通用逃生舱口（`discovery/README.md` 明确建议一切定制需求走 file_sd） |
| http | 轮询一个返回 target group JSON 的 HTTP 端点（HTTP SD） |
| consul | 轮询 Consul catalog API |
| dns | 周期解析 A/AAAA/SRV 记录 |
| kubernetes | watch K8s API（pods/services/endpoints/endpointslices/node/ingress） |
| docker/moby、ecs | Docker/containerd 生态的容器 API |
| azure/gce/aws/openstack/oci/hetzner/digitalocean/linode/scaleway/vultr/ovhcloud/outscale/stackit/ionos | 各云厂商实例 API |
| kuma/eureka/marathon/nomad/puppetdb/uyuni/triton/zookeeper/xds | 各注册中心/调度器，其中 xds 覆盖 Envoy xDS |
| refresh 包 | 以上多数机制的公共骨架：定时器 + 单飞刷新（`discovery/refresh/refresh.go:45,82`） |

`discovery/README.md` 开篇即是一份"什么样的东西配做成 SD"的评审清单——这是工程文化的第一处体现（见第 6 节）。

### 2.2 Provider 注册与复用

`discovery/manager.go:40-54` 定义 `Provider`：一个 Discoverer 实例 + 配置 + cancel + 订阅者集合 `subs`（key 是 scrape job 名）。注册入口是 `registerProviders`（`discovery/manager.go:526-574`），关键去重：

```go
// discovery/manager.go:531-537
add := func(cfg Config) {
    for _, p := range m.providers {
        if reflect.DeepEqual(cfg, p.config) {
            p.newSubs[setName] = struct{}{}
            added = true
            return
        }
    }
```

两个 job 配置了完全相同的 consul_sd_configs？只起一个 Discoverer，两个 job 都是它的订阅者（subs）。reload 时（`ApplyConfig`，`discovery/manager.go:234-335`）没有新订阅者的 provider 被 cancel（:253-259），仍存活的 provider 则把旧订阅者的 target 快照复制给新订阅者（:300-309）。若全部 SD 配置为空或失败，补一个空的 `StaticConfig{{}}` 强制下游刷空（:565-572）。

### 2.3 更新的去重与节流：updater → targets → sender

每个 provider 启动两条 goroutine（`startProvider`，`discovery/manager.go:352-363`）：Discoverer 本体 + `updater`。`updater`（:383-411）收到增量后按 `poolKey{job, provider}` 写入 `m.targets`——**以 `tg.Source` 为键做合并**：有内容的组覆盖、空组直接删除（`updateGroup`，`discovery/manager.go:468-488`），这就是"k8s 只发单个 target group 的增量"能正确合并的原因（结构体注释 :177-179）。

真正发给 scrape 侧的是 `sender`（:413-454）——不是每条增量都发全量，而是指数退避节流：

```go
// discovery/manager.go:419-425
lastSent := time.Now().Add(-1 * m.updatert)
b := &backoff.ExponentialBackOff{
    InitialInterval:     100 * time.Millisecond,
    ...
    MaxInterval:         m.updatert,   // 默认 5s（NewManager :104）
}
```

发送的内容是 `allGroups()`（:490-523）：遍历所有 provider × 订阅 job，拼出 `map[job][]*targetgroup.Group` **全量快照**；对没有任何目标的 job 也发空列表，保证消费者把旧目标删干净（:499-504 注释引 issue #12858）。若下游 syncCh 满了，记 `DelayedUpdates` 并重新触发自己（:438-445）——不丢更新，只延迟。

### 2.4 下游接线

`cmd/prometheus/main.go:1350`：`scrapeManager.Run(discoveryManagerScrape.SyncCh())`。`scrape.Manager.Run`（`scrape/manager.go:223-242`）只把快照存下并触发 `triggerReload`；真正消费在 `reloader`（:249-281，默认 5s ticker，`DiscoveryReloadInterval` 可调），`reload()`（:283-317）为每个 job 建/复用 `scrapePool` 并并发调 `sp.Sync(groups)`。**SD 全量快照 + scrape 侧再收敛**，两层各解耦一次。

---

## 3. scrapeLoop 专节：周期对齐、协议协商、解析与自监控

### 3.1 周期对齐：hash offset，不是随机 jitter

每个 target 的首轮抓取偏移由哈希决定（`scrape/target.go:179-193`）：

```go
// scrape/target.go:183-187
var (
    base   = int64(interval) - now%int64(interval)          // 钉在绝对时间栅格上
    offset = (t.hash() ^ offsetSeed) % uint64(interval)     // 目标哈希 ^ 全局种子
    next   = base + int64(offset)
)
```

`base` 钉在绝对时间栅格，保证同一 target 无论调用多少次 offset，相位不变；`t.hash()` 是 labels 哈希 + URL 哈希（`target.go:168-175`）。`offsetSeed` 是**每台 Prometheus 一个全局种子**——由 FQDN + external_labels 哈希而来（`scrape/manager.go:319-335`），注释直说目的："spread scrape workload across HA setup"（:207）——两台 HA 副本对同一 target 在不同时刻抓取，避免同时打爆被采集端。`run()` 先等这个偏移（`scrape.go:1424-1433`），然后 `ticker.Reset` 使后续抓取对齐到 `offset + n*interval`（:1435-1436）。

另有一层微对齐：Go 定时器抖动会造成 TSDB 磁盘膨胀（issue #7846），`run()` 里若抓取时刻与理想栅格偏差在 `min(interval/100, 2ms)` 内则吸附到栅格（`scrape.go:1451-1464`；`ScrapeTimestampTolerance = 2ms` 定义于 :70）。

### 3.2 HTTP 层：Accept 头协议协商

`acceptHeader`（`scrape/scrape.go:794-810`）按配置的 `scrape_protocols` 优先级生成 q 值递减的 Accept 头，对文本 1.0.0/OpenMetrics 附加 escaping 方案参数（:800-802），最后兜底 `*/*`（:808）。请求还带 `X-Prometheus-Scrape-Timeout-Seconds` 头（:833）——超时协商走应用层而非仅 TCP。响应读取（`readResponse`，:844-908）处理 gzip/zstd（:858-897，zstd 需显式 feature flag，:876-880）、body_size_limit 截断（:899-906），并把 Content-Type 原样传给解析层。

### 3.3 解析器分派：按 Content-Type，一处收口

解析入口只有一个——`textparse.New`（`model/textparse/interface.go:190-232`）：

```go
// model/textparse/interface.go:199-219
switch mediaType {
case "application/openmetrics-text":
    if version == openMetrics2Version { ... NewOpenMetrics2Parser ... }
    else { ... NewOpenMetricsParser ... }
case "application/vnd.google.protobuf":
    return NewProtobufParser(...)
case "text/plain":
    baseParser = NewPromParser(b, st, opts.EnableTypeAndUnitLabels)
default:
    return nil, err
}
```

Content-Type 不认识时回落到目标配置的 `fallback_scrape_protocol`，否则抓取直接失败（:130-140）。若开启经典直方图转 NHCB，再包一层 `NewNHCBParser` 装饰器（:224-229）。Prometheus/OpenMetrics 两个文本 parser 由 ragel 生成的词法器驱动（`promlex.l`、`openmetricslex.l`），protobuf parser 覆盖 native histogram。scrape 侧的调用点在 `scrapeLoopAppender.append`（`scrape/scrape.go:1789-1797`），把 feature flag 一并透传。

### 3.4 样本主循环与 honor 语义

`append()`（`scrape/scrape.go:1779-2093`）要点：

- **空抓取 = 触发 stale**：`len(b)==0` 时只调 `updateStaleMarkers`（:1782-1787）；抓取失败、解析失败、超 sample_limit 时，`scrapeAndReport` 都会补一次空 append（:1611-1614 注释、:1624-1630）。
- **honor_timestamps**：目标暴露的时间戳默认被信任（`config.go:210` 默认 true）；关闭时强制抹掉解析到的时间戳用抓取时间（`scrape.go:1883-1888`）。
- **honor_labels**：系列第一次出现（缓存 miss）时 `p.Labels(&lset)` 取得暴露侧标签，交给 `sampleMutator`（:1904-1909）。`mutateSampleLabels`（:650-680）：honor=true 时目标标签不覆盖已存在的暴露标签；默认(false)时目标标签获胜，冲突的暴露标签改名 `exported_<name>` 保留（冲突消解见 :682-697，按名字长度稳定排序逐级加前缀）。随后执行第二阶段 relabel（:675）。
- 校验：无 `__name__` 即报错（:1917-1920），label 数量/长度限制（:1927-1930）。
- 缓存：`scrapeCache` 记住每个系列的 ref/labels/哈希（`scrape.go:920-928`），命中时免掉重新拼标签的哈希；staleness 跟踪集 `trackStaleness`（:1164-1167）记录"本轮见过的系列"，显式时间戳的系列默认不跟踪（:1971-1973、:1990-1994）。
- 缓存置换 `iterDone`（:1059-1107）：成功抓取才 flush，连续失败时若缓存翻倍则强制 flush 防泄漏（:1065-1072）。

### 3.5 自监控：up 与 scrape_* 是怎么来的

每次抓取结束，`report()`（`scrape/scrape.go:2297-2335`）把一组"报告样本"与业务样本一起 Append 进 TSDB——**up 不是 fake 出来的，是真实序列**：

```go
// scrape/scrape.go:2231-2233（名字带 \xff 后缀防与抓取指标撞名）
scrapeHealthMetric = reportSample{
    name: []byte("up" + "\xff"),
    ...
```

默认 5 个：`up`（1/0，:2302-2308）、`scrape_duration_seconds`、`scrape_samples_scraped`、`scrape_samples_post_metric_relabeling`、`scrape_series_added`；`extra_scrape_metrics` 再加 `scrape_timeout_seconds`、`scrape_sample_limit`、`scrape_body_size_bytes`（:2323-2333）。目标消失时这组指标同样打 stale（`reportStale`，:2337-2370）。报告样本的标签处理独立于业务样本：`mutateReportSampleLabels` 把冲突的暴露标签全部挪进 `exported_` 前缀（:699-708），保证 `up` 的标签集永远干净。

---

## 4. relabel 专节：两阶段重打标

### 4.1 引擎：model.RelabelConfigs

`model/relabel/relabel.go:86-105` 的 `Config`：source_labels + separator 拼接 → 正则匹配 → 按 action 改标签。11 种 action（:46-69）：replace/keep/drop/keepequal/dropequal/hashmod/labelmap/labeldrop/labelkeep/lowercase/uppercase。所有正则自动全锚定（`NewRegexp`，:201-204，`"^(?s:" + s + ")$"`）。`ProcessBuilder`（:274-282）顺序执行规则，任一规则返回 drop 即整体丢弃。`hashmod` 用 md5 后 8 字节取模（:339-343），是分片的标准姿势。

### 4.2 第一阶段：目标重打标（scrape config 的 relabel_configs）

发生在 target 从 target group 诞生时：`PopulateLabels`（`scrape/target.go:648-725`）。

```go
// scrape/target.go:649-650
PopulateDiscoveredLabels(lb, cfg, tLabels, tgLabels)
keep := relabel.ProcessBuilder(lb, cfg.RelabelConfigs...)
```

`PopulateDiscoveredLabels`（:608-643）先把 job/`__scrape_interval__`/`__metrics_path__`/`__scheme__`/`__param_*` 等铺进 builder；relabel 之后：`__address__` 为空即报 "no address"（:656-658），`__meta_*` 元标签全部删除（:702-706），`instance` 缺省为地址（:709-711）。这一阶段可以改写抓取的**物理参数**——因为 URL 是从标签派生的：`Target.URL()`（`target.go:234-273`）从 `__address__`（:257）、`__scheme__`（:258）、`__metrics_path__`（:270）取值，`__param_*` 标签覆盖查询参数（:244-255）。甚至 `__scrape_interval__` 也吃 relabel（`sync()` 里从标签反解 interval/timeout，`scrape.go:501-509`）。

### 4.3 第二阶段：指标重打标（metric_relabel_configs）

发生在样本入库存之前，每个 scrapeLoop 一份（`newScrapeLoop`，`scrape.go:1335-1337`）：

```go
// scrape/scrape.go:1335-1337
sampleMutator: func(l labels.Labels) labels.Labels {
    return mutateSampleLabels(l, opts.target, opts.sp.config.HonorLabels,
        opts.sp.config.MetricRelabelConfigs)
},
```

`mutateSampleLabels`（:650-680）先做 honor_labels 合并，再 `relabel.ProcessBuilder(lb, rc...)`（:675）。空标签集 = drop 该系列（:1911-1915 缓存为 dropped，后续抓取直接跳过）。

### 4.4 为什么分层：权限边界

两阶段读写的东西不同：目标重打标操作的是"内部标签空间"（`__` 前缀可自由摆弄 scheme/path/params，删除于 :702-706），决定**去哪抓**；指标重打标操作的是最终标签集，决定**存什么**，且在 sample_limit 计数之前（`appenderWithLimits` 注释，:717）。把两者合并成一套会导致：改 path 的规则会意外命中业务样本、删目标的规则会删掉样本——分层让"路由规则"与"数据规则"互不越权。

---

## 5. Stale 专节：为什么需要 stale NaN

### 5.1 标记本体

`model/value/value.go:20-34`：`StaleNaN uint64 = 0x7ff0000000000002`——一个特制的 signaling NaN，位模式区别于普通 NaN（NormalNaN `0x7ff8000000000001`），`IsStaleNaN` 按位比较识别（:32-34）。

### 5.2 三个注入点

1. **系列消失**（还在抓但少了一个系列）：`updateStaleMarkers`（`scrape.go:1754-1769`）遍历缓存中上一轮见过、本轮没见的系列，在默认时间戳写入 StaleNaN；目标闪断重连导致的乱序/重复错误被静默吞掉（:1761-1765）。
2. **抓取失败/解析失败**：`scrapeAndReport` 把失败当空抓取处理（:1611-1614 注释原文 "A failed scrape is the same as an empty scrape, we still call sl.append to trigger stale markers"）。
3. **目标消失**（end-of-run）：`endOfRunStaleness`（:1663-1729）在 loop 退出后**再等两个完整 interval + 10%**（:1676-1698）才写标记——防抖窗口：如果目标只是被 SD 重建（同标签新 loop），新样本会先落库，迟到的 stale 标记因乱序被 TSDB 忽略（:1705-1707 注释）。Prometheus Agent 与联邦等场景可显式禁用此机制（`disableEndOfRunStalenessMarkers`，`scrape.go:1738-1740`）。

### 5.3 为什么必须存在：查询正确性

PromQL 的区间选择器有 5 分钟 lookback：`vectorSelectorSingle` 取 refTime 之前最近的样本。如果没有 stale 标记，一个系列停止暴露后，**最后一次的旧值会被未来 5 分钟内的所有查询反复读到**——监控语义上这是幻觉（比如计数器已消失却还在算 rate）。查询引擎在取数时显式跳过 stale 标记：

```go
// promql/engine.go:2841-2843
if value.IsStaleNaN(v) || (h != nil && value.IsStaleNaN(h.Sum)) {
    return 0, 0, 0, nil, false
}
```

stale 标记的作用是"截断 lookback"：它本身永不作为值返回，只让引擎停止向更早回看。同时它让 `rate()`、`increase()` 等函数在目标消失处产生 gap 而不是延续旧值——这就是"查询的连续性"：数据在、语义也对。另注意被 relabel 掉的旧系列、以及 OOO append 场景下 stale 的特殊处理（:1976 后的 `checkAddError`，及 `TestScrapeLoopCreatesStaleMarkersOnOOOAppend`，`scrape_test.go:4714`）。

---

## 6. 工程文化专节

- **测试是硬门槛**。根 `Makefile:177-179` 的 `test` 目标串起 Go 测试 + 生成物校验 + UI 测试 + UI lint。仅 `scrape/scrape_test.go` 就有 107 个 Test 函数，stale 语义每个分支都有专属用例（失败抓取 :2906、解析失败 :2959、sample_limit :3018、显式时间戳不追踪 :3865、可禁用 :7994）。合成时间工具（`helpers_test.go`）让时钟可控。发现机制普遍配 `testdata` 快照。
- **生成式解析器**：promql 的 yacc 文法（`Makefile:140-168` 的 parser 目标）与文本格式的 ragel 词法器都提交生成物，CI 校验生成物新鲜度（`check-generated-parser`，:164）。
- **发布节律**：`RELEASE.md:7` 明示 "Release cadence of first pre-releases being cut is 6 weeks"，每个 minor 系列由一位志愿 release shepherd 负责（表列到 v3.16，含空缺招募）；rc.0 后要跑 3 天 benchmark 监控才转正（"Release shepherd responsibilities" 节）。主干始终保持可发布状态是该文件的显式要求。
- **文档即代码**：`docs/` 下 configuration/command-line/feature_flags/federation 等全部随主干维护，`make cli-documentation`（Makefile:204）从命令行生成文档。
- **前端**：`web/ui/README.md`——3.x 起默认 React + Mantine 的新 UI（`mantine-ui/`），2.x 的 `react-app` 保留可用 `--enable-feature=old-ui` 切回；UI 构建产物嵌入二进制（`Makefile:114-119` assets 目标）。
- **治理**：Apache License 2.0（`README.md:226-228`），CNCF 项目（`README.md:21`），另有 CODEOWNERS、MAINTAINERS.md、SECURITY.md、CODE_OF_CONDUCT.md 全套。
- **新 SD 的准入文化**：`discovery/README.md` 开篇是设计评审——新 SD 必须成熟且跨组织使用、必须有本团队 committer 背书；"无限变化的通用场景给一个通用机制（file_sd）"，不重复造轮子。
- **Agent 模式**（呼应 A 报告）：同一二进制、同一抓取/S D 语义，去掉查询/告警/规则、换成只写 WAL + remote write 的精简 TSDB（`docs/prometheus_agent.md` 开篇定义；实现上 `cmd/prometheus/main.go:175-179` 的 `agentOnlyFlag` 与 `storage.agent.path` 默认 `data-agent/`，:557-558）。

---

## 7. 设计动机

**Pull 模型的论证**。scrapeLoop 的全部细节都是 pull 语义的展开：(1) 失败语义明确——抓不到 = `up 0` + stale，推送模型里"没数据"永远歧义（是挂了还是没事发？）；(2) 目标健康由监控端裁决，不接受被监控端自证（Agent 模式文档同样强调 "Prometheus still uses a pull model… which gives us an understanding of those different failure modes"，`docs/prometheus_agent.md`）；(3) hash-offset 打散抓取相位（`target.go:177-178` 注释：让多台 Prometheus 错峰），这是 pull 特有的负载整形问题；(4) 代价是短生命周期任务需要 Pushgateway/agent 这类补丁——Agent 模式正是官方对 pull 边界的补充而非否定。

**两阶段 relabel 的分层**。见 4.4：第一阶段操作 `__` 前缀的"机器可读"标签，决定抓取的路由与物理参数，随目标生命周期重建；第二阶段操作最终标签，随样本流逐条执行。分层让目标路由逻辑可以在 SD 数据上做纯函数变换（`PopulateLabels` 无副作用、可全量重算），而数据整形规则挂载在每个样本的缓存 miss 路径上（`scrape.go:1904-1909`），两者频率、缓存策略、失败语义完全不同。

**目标是有状态对象**。`Target` 不只是一条配置：它持有 runtime 状态（lastError/lastScrape/health，`target.go:71-77`）、可热更新配置（`SetScrapeConfig`，:225-231）、以 hash 为身份（`hash()`，:168-175）参与 scrapePool 的 diff——`sync()` 用 `map[hash]loop` 对比新旧集合，只动变化的（`scrape.go:485-590`）。正因目标是长寿命对象，scrapeLoop 的缓存（series ref、staleness 跟踪集）才有意义；也正因身份是 hash 而非指针，SD 抖动时"同标签目标"能平滑继承、而"消失又回来"的目标由 endOfRunStaleness 的两-interval 窗口兜底。status 页展示的 dropped targets（`KeepDroppedTargets`，`scrape.go:460-465`）也是把"被 relabel 掉"当成一等状态存下来。

---

## 8. FAQ 素材

1. **up 指标是谁写的？** scrapeLoop 每轮抓取后随业务样本一起 Append（`scrape.go:2297-2335`），名字带 `\xff` 后缀防撞名，不是查询时合成的。
2. **多个 job 用同一个 consul SD 会重复请求 Consul 吗？** 不会。配置 `reflect.DeepEqual` 相同的 SD 只建一个 provider，多 job 共享（`discovery/manager.go:531-537`）。
3. **SD 更新多快能生效？** provider 增量经 100ms-5s 指数退避节流后发全量快照（`discovery/manager.go:419-453`），scrape 侧 reloader 默认 5s tick 消费（`scrape/manager.go:250-253`），最坏约 10s。
4. **为什么我的实例抓取时刻不在整分？** hash-offset：`(target哈希 ^ 全局种子) % interval` 的首轮相位 + 绝对时间栅格（`target.go:179-193`），目的是 HA 副本错峰、目标间均匀分布。
5. **两台 Prometheus 抓同一目标样本一样吗？** 时间戳各自独立（各自的抓取时刻），±2ms 栅格吸附只是对齐自己的 ticker（`scrape.go:1451-1464`），不做跨副本对齐。
6. **honor_labels 和 metric_relabel_configs 的顺序？** 先 honor 合并（目标标签 vs 暴露标签冲突改 `exported_`），再跑 metric relabel（`scrape.go:650-680`）。
7. **抓取失败时旧数据还能查到吗？** 能，但只在 stale 标记之前：失败立即注入 stale NaN（:1611-1614），查询 lookback 被截断（`engine.go:2841-2843`）；不会返回过期值当新值。
8. **目标删除后为什么还要等 2 个 interval 才写 stale？** 防抖：目标可能被 SD 立刻重建，早写的 stale 会与重建后的新样本竞争，晚写则因乱序被忽略（`scrape.go:1663-1707`）。
9. **sample_limit 超了会全批失败吗？** 是——本轮整体失败并按空抓取补 stale，防止"半批数据"（`scrape.go:1620-1631`；stale 标记不受 limit 影响，`target.go:385-393` 特判）。
10. **Content-Type 不认识就放弃吗？** 先回落 `fallback_scrape_protocol`，没有配置才失败（`textparse/interface.go:130-140`）。

## 9. 深挖选题

1. **scrapeCache 的三态生命周期**：seriesCur/seriesPrev 双缓冲 + `iterDone` 的强制 flush 启发式（缓存翻倍+1000，`scrape.go:1059-1107`）——一个为"失败抓取不泄漏内存"设计的缓存。
2. **yacc/ragel 生成式解析器的性能取舍**：`yoloString`（零拷贝字符串，`scrape.go:1178`）与 symbol table 共享（`scrapePool.symbolTable`，:104）如何让每样本分配趋近于零。
3. **endOfRunStaleness 的竞态正确性证明**：两 interval + 10% 窗口与 TSDB 乱序拒绝的组合为何在所有交错下安全（`scrape.go:1663-1729` + OOO 测试 :4714）。
4. **Appender 装饰链**：timeLimit→limit→bucketLimit→maxSchema 四层包装（`scrape.go:711-740`、`target.go:377-506`），以及 V1/V2 双轨（`scrapeLoopAppendAdapter`，:136-142）的迁移路径。
5. **xDS SD 的泛化设计**：`discovery/xds/` 如何把 Envoy 的资源模型抽象成 target group——SD 插件面的上限案例。

---

## 10. 写作要点速查表

| # | 事实 | 位置 |
|---|---|---|
| 1 | Provider 结构与订阅者集合（subs=newSubs 两段式） | discovery/manager.go:40-54 |
| 2 | SD 配置去重：reflect.DeepEqual 复用 provider | discovery/manager.go:531-537 |
| 3 | sender 指数退避节流（100ms→updatert 5s） | discovery/manager.go:413-454（:419-425） |
| 4 | allGroups 全量快照，空 job 也发空列表防残留 | discovery/manager.go:490-523（:499-504） |
| 5 | SyncCh→scrape.Manager 接线 | cmd/prometheus/main.go:1350；scrape/manager.go:223-242 |
| 6 | 目标 hash offset（哈希^种子 mod interval，绝对栅格） | scrape/target.go:179-193；hash :168-175 |
| 7 | 目标重打标 PopulateLabels→ProcessBuilder，`__meta_` 删除、instance 默认 | scrape/target.go:648-725（:650、:702-706、:709-711） |
| 8 | scrapeLoop.run：offset 等待 + ticker.Reset + ±2ms 对齐 | scrape/scrape.go:1405-1474（:1451-1464；容差 :70） |
| 9 | 抓取失败=空抓取=补 stale 的注释原话 | scrape/scrape.go:1611-1614 |
| 10 | 解析器按 Content-Type 分派（OM/protobuf/plain + fallback） | model/textparse/interface.go:190-232（:130-140） |
| 11 | honor_labels 合并与 `exported_` 冲突消解；第二阶段 metric relabel | scrape/scrape.go:650-680（:675）、调用点 :1335-1337 |
| 12 | honor_timestamps 抹时间戳 | scrape/scrape.go:1883-1888；默认值 config/config.go:210 |
| 13 | up/scrape_duration 等报告样本（`\xff` 防撞名） | scrape/scrape.go:2230-2295、report :2297-2335 |
| 14 | StaleNaN 位模式 0x7ff0000000000002 | model/value/value.go:20-34 |
| 15 | endOfRunStaleness 两 interval+10% 防抖窗口 | scrape/scrape.go:1663-1729 |
| 16 | 查询侧跳过 stale 截断 lookback | promql/engine.go:2841-2843（vectorSelectorSingle :2811） |
| 17 | scrapePool.sync 按 hash diff 建/停 loop，wg.Wait 防乱序 | scrape/scrape.go:485-590（:585-589） |
| 18 | 6 周发布节律 / Apache2+CNCF / React 新 UI | RELEASE.md:7；README.md:21,226-228；web/ui/README.md |

（commit `b0f312b`；报告完）
