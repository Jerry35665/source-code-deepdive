# Prometheus 深读 · 卷一 第 1 章：全景架构——组件组装与数据流

> 调研基线：prometheus/prometheus，commit `b0f312b`（b0f312ba48c9d31dad04e7014bfb0fa300153a07，"logging: fix rule and block fields in JSON logs (#19572)"）。以下所有 `文件:行号` 均以该 commit 实际核对。
> 本文是《Prometheus 深读》系列的总纲：只讲"组件如何拼成一台服务器、数据如何流动"。TSDB 内部留 B/C 篇，查询引擎留 E 篇，抓取细节留 F 篇。

---

## 1. 全景：一条样本的一生，与一次查询的逆旅

Prometheus 是**单体单二进制**：`cmd/prometheus/main.go`（2300 行）把服务发现、抓取、规则、告警、TSDB、HTTP API 全部组装进一个进程。核心数据流只有一条主干加一条支流：

```
                 ┌────────────────────────── 单进程：prometheus ──────────────────────────┐
                 │                                                                        │
 service discovery ──SyncCh()──▶ scrape.Manager ──▶ scrapePool(每 job 一个)                │
 (discovery.Manager)   (main.go:1350)  (manager.go:283 reload)     │ sp.sync() 分发 target │
                 │                              (scrape.go:485)    ▼                       │
                 │                                    scrapeLoop(每 target 一个)             │
                 │                                    (scrape.go:1405 run)                  │
   targets ─HTTP─│──▶ /metrics 抓取 ──▶ 解析 ──▶ slAppender.append (scrape.go:1779)         │
                 │                                    │ app.Append(ref,lset,t,v)           │
                 │                                    ▼          (scrape.go:1962)          │
                 │              fanout storage ──▶ storage.Appender (interface.go:441)      │
                 │              (fanout.go:45)        │ Commit() 事务提交                  │
                 │                        ┌───────────┴───────────┐                        │
                 │                        ▼                       ▼                        │
                 │                  TSDB Head(内存)          remote_write 出口              │
                 │                  (db.go:1338 → head)      (remote.NewStorage,main.go:955)│
                 │                        │                                                 │
                 │              WAL 先落盘，head 每 2h 切块                                  │
                 │                        ▼                                                 │
                 │              DB.run 后台循环 (db.go:1267)                                 │
                 │                ├─ reloadBlocks 发现/剔除 block                            │
                 │                └─ Compact() (db.go:1519)──▶ 分层压缩 ──▶ blocks/ 目录     │
                 │                                                          │              │
 查询反向读：     │                                                          ▼              │
 HTTP /api/v1/query ──▶ promql.Engine (main.go:1046) ──▶ Queryable ──▶ [Head] ∪ [blocks]   │
 (api.go:553)        NewInstantQuery(api.go:587)          (db.go:2579 Querier 合并两者)    │
                 │                                                                        │
 规则/告警支流：  │  rules.Manager 每 interval ──▶ promql 求值 ──▶ 结果 Append 回 storage     │
                 │  (rules/manager.go:234 Run; group.go:293 tick) ──▶ 告警 ──▶ notifier      │
                 │  (rules/manager.go:271 Update) ──▶ (notifier/manager.go:259 Send)        │
                 │                                                  │                      │
                 └──────────────────────────────────────────────────┼──────────────────────┘
                                                                    ▼
                                                        Alertmanager（进程外）
```

要点：

- **写入是单向推**：target 列表由发现模块同步给 scrape manager，scrape loop 主动拉（pull）`/metrics`，解析后经 `Appender` 接口写入 storage（cmd/prometheus/main.go:1350、scrape/scrape.go:1779）。
- **storage 是扇出的**：main.go 用 `storage.NewFanout(localStorage, remoteStorage)` 把一次写入同时交给本地 TSDB 与 remote_write 队列（cmd/prometheus/main.go:956，storage/fanout.go:45）。
- **读是反向合并**：查询时 `DB.Querier` 把 Head（内存近期数据）与磁盘 block 的结果归并（tsdb/db.go:2579），PromQL 引擎不关心数据在内存还是磁盘。
- **规则既读又写**：recording rule 的结果再走同一个 `Appender` 回写 TSDB（rules/group.go:570、731），告警则走 notifier 支流发往进程外的 Alertmanager。

---

## 2. 装配专节：main.go 的组件启动顺序与 reload 热切换

### 2.1 组件构造（先造零件，不启动）

`main()`（cmd/prometheus/main.go:377）在 flag 解析（kingpin，main.go:418 起）后，按依赖顺序构造组件：

| 顺序 | 组件 | 位置 | 依赖说明 |
|---|---|---|---|
| 1 | `localStorage = &readyStorage{}` | main.go:953 | **占位代理**：TSDB 此刻还没打开，先用一个线程安全的壳顶住 |
| 2 | `scraper = &readyScrapeManager{}` | main.go:954 | 同理，给 remote_write 引用的占位（main.go:2093） |
| 3 | `remoteStorage = remote.NewStorage(...)` | main.go:955 | 需要 scraper 占位 |
| 4 | `fanoutStorage = storage.NewFanout(localStorage, remoteStorage)` | main.go:956 | 所有写入方（scrape/rules/remote write receiver）都拿它 |
| 5 | `notifierManager = notifier.NewManager(...)` | main.go:963 | |
| 6 | `discoveryManagerScrape/Notify` | main.go:988,994 | 发现模块跑两个实例：一个喂抓取、一个喂 alertmanager |
| 7 | `scrapeManager = scrape.NewManager(..., fanoutStorage)` | main.go:1000-1006 | 注意第 5 参是 `AppendableV2`（scrape/manager.go:52） |
| 8 | `queryEngine = promql.NewEngine(opts)` | main.go:1046 | 仅 server 模式（`!agentMode`，main.go:1019） |
| 9 | `ruleManager = rules.NewManager(...)` | main.go:1048-1068 | 注入 `Appendable: fanoutStorage`、`Queryable: localStorage`、`NotifyFunc: rules.SendAlerts(notifierManager, ...)`（main.go:1050-1053）——依赖关系在构造期一次性接线 |
| 10 | `scraper.Set(scrapeManager)` | main.go:1071 | 占位就位，remote_write 从此能拿到真正的 manager |
| 11 | `cfg.web.*` 装配 + `webHandler = web.New(...)` | main.go:1073-1112 | web handler 拿到的是上面所有组件的引用：`LocalStorage`/`Storage`/`QueryEngine`/`ScrapeManager`/`RuleManager`/`Notifier`（main.go:1078-1084） |
| 12 | `reloaders := []reloader{...}` | main.go:1122-1233 | reload 的执行清单，见 2.3 |

**启动顺序的关键设计：`readyStorage`/`readyScrapeManager` 两个占位解耦了"构造"与"就绪"。** TSDB 打开要回放 WAL，可能耗时数分钟；期间 web handler 必须先起来回答 `/‑/healthy`，所以所有组件先持有壳引用，壳内部 `get()` 返回 `ErrNotReady` 直到 `Set()`（cmd/prometheus/main.go:1865）。

### 2.2 运行：oklog/run.Group 的 goroutine 编排

main.go 用一个 `run.Group`（main.go:1270）把所有常驻 goroutine 收拢，任一返回即全组退出（main.go:1655）。**加入顺序即启动顺序**：

1. 终止信号处理（SIGINT/SIGTERM + web `/-/quit`，main.go:1271-1296）
2. 发现管理器 ×2（main.go:1297-1324）
3. 规则管理器——先 `<-reloadReady.C` 等 initial config（main.go:1327-1339）
4. 抓取管理器——`scrapeManager.Run(discoveryManagerScrape.SyncCh())`，同样等 reloadReady（main.go:1342-1362，Run 调用在 1350）
5. tracing（main.go:1364-1378）
6. **reload handler**：`signal.Notify(hup, syscall.SIGHUP)` 在 main.go:1385，事件循环 main.go:1404-1455
7. **initial config load**：等 `<-dbOpen`（main.go:1470）→ `reloadConfig(...)`（main.go:1477）→ `reloadReady.Close()`（main.go:1481）→ `webHandler.SetReady(web.Ready)`（main.go:1483）
8. **TSDB 打开**（server 模式）：`openDBWithMetrics` → `tsdb.Open`（main.go:1512、1663-1670）→ `localStorage.Set(db, startTimeMargin)`（main.go:1540）→ `close(dbOpen)`（main.go:1542）
9. Web handler：`webHandler.Run(ctxWeb, listeners, *webConfig)`（main.go:1617-1629）
10. Notifier：`notifierManager.Run(discoveryManagerNotify.SyncCh())`（main.go:1636-1653，Run 在 1644）

**启动时序一句话**：TSDB 打开与 web 服务并行；配置加载等 TSDB；抓取/规则/告警等配置；`/-/ready` 在 `SetReady(web.Ready)` 之前一律返回"启动中"（WAL 回放进度可在 `/status/walreplay` 看，web/api/v1/api.go:486）。

**关闭顺序**也有讲究：scrape manager 的 interrupt 注释明说"必须在关 TSDB 之前停抓取，避免向已关闭的 storage 写入；且要等规则管理器停完，避免 absent() 误报"（main.go:1354-1358）；notifier 必须在 ruleManager 之后停，否则 panic（main.go:1634-1635）。

### 2.3 reload：配置热切换的两层机制

`reloadConfig`（cmd/prometheus/main.go:1719-1766）只有 40 行，却是全系统唯一的配置分发点：

```go
// cmd/prometheus/main.go:1719
func reloadConfig(filename string, ..., rls ...reloader) (err error) {
	...
	conf, err := config.LoadFile(filename, agentMode, logger)   // 1735：整文件重读+校验
	...
	failed := false
	for _, rl := range rls {                                     // 1747：按序调每个组件
		if err := rl.reloader(conf); err != nil {
			logger.Error("Failed to apply configuration", "err", err)
			failed = true                                        // 单个失败不中断，其余继续应用
		}
	}
	...
	logLevel.Set(string(conf.Runtime.LogLevel))                  // 1758：动态日志级别
	updateGoGC(conf, logger)                                     // 1762：动态 GOGC
	noStepSubqueryInterval.Set(conf.GlobalConfig.EvaluationInterval) // 1763
}
```

三个触发入口都汇到同一条 reload 循环（main.go:1404-1455）：

- **SIGHUP**：`case <-hup:`（main.go:1411）；
- **HTTP**：`GET /-/reload`（web/web.go:600 → `webHandler.Reload()` channel，main.go:1419），需 `--web.enable-lifecycle`；
- **auto-reload**：`--config.auto-reload` 开启后每 30s 算一次配置文件 checksum，变了才重载（main.go:1432-1449；checksum 实现在 config/reload.go:33）。

`reloader` 清单（main.go:1122-1233）的顺序即热切换顺序：`db_storage`（retention）→ `remote_storage` → `web_handler` → `query_engine`（query log）→ `scrape` → `scrape_sd` → `notify` → `notify_sd` → `rules`（main.go:1204-1228，内部 `ruleManager.Update`）→ `tracing`。其中 scrape 必须先于 scrape_sd——注释写明"它们要先拿到最新配置，再接收新 target 列表"（main.go:1174-1175）。

**热切换语义**：reload 失败不会回滚已应用的组件（逐个 best-effort），但失败时 `configSuccess` 指标置 0（main.go:1730）并在 `/notifications` 页面暴露；配置加载是"整体重读"，因此绝大多数配置项（抓取间隔、rule 文件、remote_write）都可热改——改不了的是启动期 flag（如 `--storage.tsdb.path`）。

---

## 3. Appender 接口专节：写入抽象与事务语义

`storage.Storage`（storage/interface.go:82）= 可查询（`SampleAndChunkQueryable`）+ 可追加（`Appendable`/`AppendableV2`）+ `StartTime`/`Close`。查询侧是 `Queryable → Querier → Select`（interface.go:108-135），写入侧则是本文的主角 `Appender`。

### 3.1 接口分层

```go
// storage/interface.go:441
type Appender interface {
	AppenderTransaction        // Commit/Rollback，见下
	Append(ref SeriesRef, l labels.Labels, t int64, v float64) (SeriesRef, error)  // 452
	SetOptions(opts *AppendOptions)                                                 // 456
	ExemplarAppender           // AppendExemplar（interface.go:491）
	HistogramAppender          // AppendHistogram（interface.go:510）
	MetadataUpdater            // UpdateMetadata（interface.go:539）
	StartTimestampAppender     // AppendSTZeroSample
}
```

- **事务边界**：`AppenderTransaction` 只有 `Commit() error` 与 `Rollback() error` 两个方法（storage/interface_append.go:193-203）。注释明确两条纪律：Commit 返回错误时等效于已 Rollback；Appender 用完即弃、不可复用。
- **ref 机制**：`Append` 返回的 `SeriesRef` 是"系列引用号"，跨调用传回可加速查找；且**随时可能失效**（返回错误即需从头 Append），ref==0 表示不可缓存（storage/interface.go:444-451）。这是 TSDB 无锁写入路径上避免反复算 hash 的关键。
- **调用方约束**："Operations on the Appender interface are not goroutine-safe"——每个抓取 loop、每次规则求值各开各的 Appender（storage/interface.go:433）。
- **正在进行的迁移**：`AppendableV2`（storage/interface_append.go:27，Append 签名在 189 行）把 float/histogram/ST/metadata 合并成一个方法，main.go 传给 scrape manager 的是 V2（main.go:1004），注释多处标注 V1 将移除（"ETA: Q2 2026"，storage/interface.go:87）。

### 3.2 从接口到实现的两级跳

```go
// tsdb/db.go:1338
func (db *DB) Appender(ctx context.Context) storage.Appender {
	return dbAppender{db: db, Appender: db.head.Appender(ctx)}
}
```

`DB.Appender` 只是薄封装，真正的事务落在 **Head**（内存块）上：`Head.Appender` 在 tsdb/head_append.go:172。也就是说——**Commit 之前，样本只进 Head 内存 + WAL**；磁盘 block 是 Compaction 的产物，写入路径永不直接碰 block。fanout（storage/fanout.go:126）则把一次 Commit 分发给 primary（本地 TSDB）与各 secondaries（remote_write）。

### 3.3 scrape 侧的典型用法（写路径闭环）

每个 scrapeLoop 每轮抓取：`sl.appender()` 取 Appender（scrape/scrape.go:1476）→ 解析出的每个样本 `app.Append(ref, lset, t, val)`（scrape/scrape.go:1962）→ 全部成功后 `app.Commit()`（scrape/scrape.go:1516）；target 永久消失时补写 staleness marker（StaleNaN）再 Commit（scrape/scrape.go:1758、1716）。任何一步出错则 Rollback，整轮样本丢弃——**一次 scrape 即一个事务**。

---

## 4. web/API 专节：HTTP 面与到 TSDB 的调用面（简短）

web 包组装在 web/web.go：`New()`（web/web.go:79）在第 393 行调 `api_v1.NewAPI(h.queryEngine, h.storage, app, appV2, h.exemplarStorage, ...)`——注意传进去的就是 main.go 装配好的 `promql.Engine`、fanout storage 与 exemplar 存储。路由挂载于 `/api/v1` 前缀，由 `API.Register`（web/api/v1/api.go:414）统一注册（api.go:449-497）：

| 端点 | handler | 到引擎/TSDB 的调用 |
|---|---|---|
| `/query`（GET/POST） | `api.query`（api.go:553） | `QueryEngine.NewInstantQuery(ctx, api.Queryable, ...)`（api.go:587）→ `qry.Exec` |
| `/query_range` | `api.queryRange`（api.go:710） | `NewRangeQuery`（api.go:770） |
| `/query_exemplars` | `api.queryExemplars`（api.go:822） | `ExemplarQueryable.ExemplarQuerier`（api.go:847） |
| `/labels`、`/label/:name/values` | api.go:884、961 | `Querier.LabelNames/LabelValues` |
| `/series` | api.go:1082 | `Querier.Select` |
| `/read`、`/write`、`/otlp/v1/metrics` | api.go:489-491 | remote read/write handler，write 侧同样走 Appender |

api.go 不解析 PromQL、不算表达式——它只做参数解析、超时 context（api.go:563-572）、调引擎、编解码 JSON。PromQL 求值如何经 `Queryable` 落到 `DB.Querier`（tsdb/db.go:2579，合并 Head 与 block）留 E 篇。查询面还有 `wrapAgent` 区分 agent 模式禁用查询（api.go:449 起），TSDB 未就绪时统一转 503（`setUnavailStatusOnTSDBNotReady`，api.go:406-411）。

---

## 5. 设计动机：单体、pull 与组件边界

**为什么单体单二进制？** 一台 Prometheus = 发现 + 抓取 + 存储 + 规则 + 告警 + 查询。好处是数据流全程内存内函数调用（scrape loop → Appender → Head 无队列、无 RPC），部署运维只有一个进程一份配置。代价在代码里处处可见：main.go 必须手工维护 12 个 reloader 的应用顺序（main.go:1122-1233）和三条关闭顺序约束（main.go:1354-1361、1634-1635）；TSDB 未就绪需要 `readyStorage` 占位（main.go:953）。官方的横向扩展答案不是拆进程，而是**分片 + Agent 模式**：同一份代码用 build tag 拆出 `agentOnlyFlag`，Agent 只有 WAL + remote_write、没有查询与规则（main.go:1556-1614，`agent.Open`）。

**为什么 pull？** 抓取循环由服务器端发起（scrape/scrape.go:1405），target 健康状态由"最近一次抓取是否成功"直接判定，且天然带上 `up` 指标；更关键的是 pull 让 Prometheus 自己控制采样节奏（`setOffsetSeed` 按 FQDN 哈希错峰，scrape/manager.go:320-335），避免海量 push 洪峰。代价是要靠服务发现（discovery 包，两个独立 manager 实例，main.go:988/994）动态维护 target 列表。

**组件边界为什么画在 `storage.Appender` / `Queryable` 上？** 这是全项目最重要的抽象缝：scrape、rules、remote write receiver、OTLP receiver 全部只依赖接口，不认识 TSDB；TSDB 换 Head 内部实现（如 V2 Appender 迁移）不惊动任何写入方。测试上每个 manager 都能注入 fake Appendable；生态上 Thanos/Cortex 正是靠实现 `storage.Storage`/`GetRef`（storage/interface.go:466-472）接入。`fanout` 则让"本地 + 远端双写"成为一行装配（main.go:956）。

**规则为什么内嵌而不是独立服务？** recording rule 需要低延迟读最近数据再写回——与 Head 同进程可零拷贝互访（rules.ManagerOptions 直接注入 `Appendable` 与 `Queryable`，main.go:1050-1051）。告警评估后经 notifier 的内存队列异步发 Alertmanager（notifier/manager.go:259 Send，Run 在 205），把"易失的告警状态"留在本进程、把"告警路由去重"外推给 Alertmanager，这是单体里刻意留下的一处进程外边界。

---

## 6. FAQ 素材

1. **Q: `/-/ready` 一直显示"Starting up"是在等什么？** A: 等 initial config 加载完成（main.go:1477-1483），而 config 加载又等 `<-dbOpen`（main.go:1470），即 TSDB 的 WAL 回放结束。进度看 `/status/walreplay`（api.go:486）。
2. **Q: SIGHUP 和 `/-/reload` 有区别吗？** A: 最终都进同一条 reload 循环（main.go:1404-1455），都调 `reloadConfig`；区别仅是 HTTP 方式可拿到同步的成功/失败返回值（main.go:1419-1431），且需要 `--web.enable-lifecycle`。
3. **Q: reload 失败会回滚吗？旧配置还能用吗？** A: `reloadConfig` 逐组件应用、失败仅记日志不中断（main.go:1747-1757），没有事务回滚；但 `config.LoadFile` 先整体验证，语法错的文件根本进不到应用阶段，运行中的组件保持旧配置。规则组例外：`ruleManager.Update` 加载失败会恢复旧规则集（rules/manager.go:284-289）。
4. **Q: 样本从抓取到落盘要经过几层？** A: scrapeLoop 解析 → `Appender.Append` 进 Head 内存（WAL 同步写）→ Commit 提交事务（scrape.go:1516）→ 2 小时后 Head 切块、Compaction 生成磁盘 block（db.go:1519）。查询永远先见 Head。
5. **Q: remote_write 挂了会丢数据吗？写本地会不会被拖慢？** A: 不会。fanout 里本地 TSDB 是 primary、remote 是 secondary（storage/fanout.go:45）；remote 侧只是把样本排进 WAL 队列异步发送，`RemoteFlushDeadline` 控制其节奏（main.go:955）。
6. **Q: `SeriesRef` 是什么？可以缓存吗？** A: 系列的短引用，传回 `Append` 可跳过 label→id 的查找；官方注释明确它 ephemeral、随时可能被拒、ref==0 不可缓存（storage/interface.go:444-451）。
7. **Q: 为什么有两个 discovery manager？** A: 一个喂 scrape targets，一个喂 alertmanager 地址（main.go:988、994），各自独立的 config 与 context，reload 时也分别应用（main.go:1179-1202）。
8. **Q: Agent 模式砍掉了什么？** A: 无 TSDB（只有 WAL）、无查询引擎、无规则、无告警配置（config.LoadFile 直接拒绝这些字段，config/config.go:142-154），数据全部推给远端（main.go:1556-1614）。
9. **Q: Commit 失败样本去哪了？** A: 整批丢弃。scrape loop 捕获 `Commit` 错误后本轮样本全部失效；部分样本超限（sample limit）时 TSDB 会回滚该系列并让 loop 重试追加其余样本（scrape.go:2166 checkAddError）。
10. **Q: 一个 Appender 能开多久？** A: 必须短。接口注释规定"Commit/Rollback 后不可复用"且非 goroutine-safe（storage/interface.go:431-433）；实际用法都是"一轮抓取/一次求值"级别的短事务。

## 深挖线索（后续卷的钩子）

1. **Head 内部的 stripe 与 isolation**：`Head.Appender`（tsdb/head_append.go:172）如何在无锁 stripe 里建系列、`Commit` 如何经 `writeNotified` 唤醒 remote_write（main.go:1541）——B 篇。
2. **WAL 回放与 head.Init**：`db.head.Init(minValidTime)`（tsdb/db.go:1210，Head.Init 在 head.go:738）如何从 WAL/checkpoint 重建内存索引、损坏 WAL 的自动修复（db.go:1218-1225）——B 篇。
3. **Compaction 分层与 `ExponentialBlockRanges`**：`db.run` 每 `BlockReloadInterval` 触发（db.go:1280-1330），`Compact` 先切 Head 再做 block 间归并（db.go:1519）；block 时间线 = 2h×3^n——C 篇。
4. **查询路径**：`api.query` → `NewInstantQuery`（api.go:587）→ Engine → `DB.Querier`（db.go:2579）合并 Head/block 的迭代器栈——E 篇。
5. **scrapePool.sync 的 target 对账算法**：keep/drop/resync 三路归并（scrape/scrape.go:485）与 scrapeLoop 的错峰 offset——F 篇。

---

## 写作要点速查表

| # | 内容 | 文件:行号 |
|---|---|---|
| 1 | `main()` 入口 | cmd/prometheus/main.go:377 |
| 2 | readyStorage/scraper 占位 + fanout 装配 | cmd/prometheus/main.go:953-956 |
| 3 | scrape.NewManager(..., fanoutStorage) | cmd/prometheus/main.go:1000-1006（签名 scrape/manager.go:52） |
| 4 | promql.NewEngine / rules.NewManager | cmd/prometheus/main.go:1046 / 1048 |
| 5 | web handler 拿到全部组件引用 | cmd/prometheus/main.go:1078-1084、1112 |
| 6 | reloaders 清单（热切换顺序） | cmd/prometheus/main.go:1122-1233 |
| 7 | run.Group 编排 + scrape Run(SyncCh) | cmd/prometheus/main.go:1270、1350 |
| 8 | SIGHUP 注册与 reload 事件循环 | cmd/prometheus/main.go:1385、1404-1455 |
| 9 | initial config：等 dbOpen→SetReady | cmd/prometheus/main.go:1470-1483 |
| 10 | tsdb.Open 与 localStorage.Set | cmd/prometheus/main.go:1512、1540（tsdb/db.go:908） |
| 11 | reloadConfig 本体 | cmd/prometheus/main.go:1719（LoadFile 调用在 1735） |
| 12 | Storage/Appender/Querier 接口 | storage/interface.go:82、441、127 |
| 13 | Commit/Rollback 事务语义 | storage/interface_append.go:193-203 |
| 14 | DB.Appender → Head.Appender | tsdb/db.go:1338 → tsdb/head_append.go:172 |
| 15 | DB.run 后台循环（reloadBlocks+Compact） | tsdb/db.go:1267-1335 |
| 16 | scrape Manager.Run/reload/ApplyConfig | scrape/manager.go:223、283、365 |
| 17 | scrapeLoop run→append→Commit | scrape/scrape.go:1405、1779、1516 |
| 18 | /query 入口 NewInstantQuery | web/api/v1/api.go:553、587（路由表 449-497） |
| 19 | rules Manager.Run/Update、Group.run tick | rules/manager.go:234、271；rules/group.go:208、293 |
| 20 | notifier Run/Send、config LoadFile | notifier/manager.go:205、259；config/config.go:132、294 |

（正文约 260 行；所有行号基于 commit b0f312b 核对。）
