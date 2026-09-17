# NATS 深读 · 报告 A:全景与架构

- 基线:commit `8f3f31b0366eca0d855d0750b7ca547eadd10eff`(gitcode 镜像 HEAD,2026-09-17 同步,浅克隆)
- 源码根:`repos/nats-server/`;所有 `文件:行号` 均经实际 Read/Grep 核对
- 版本:`server/const.go:69` → `VERSION = "2.15.0-dev"`

---

## 1. 定位:它是什么,不是什么

README 的自述只有一句话:"NATS is a simple, secure and performant communications system for digital systems, services and devices",隶属 CNCF,拥有 40+ 客户端语言实现,可跑在本地、云端、边缘甚至树莓派(README.md:5)。仓库内没有更长的"架构宣言";`server/README.md` 通篇只讲测试拆分约定(server/README.md:1-17),这一点本身就很"NATS":文档少,代码即文档。

与 Kafka 的一句话差异:Kafka 是**分布式提交日志**——消息持久化到磁盘、按 offset 重放、消费者主动拉取;NATS 核心是**主题发布/订阅消息总线**——默认 fire-and-forget、at-most-once、broker 不落盘,持久化是可选子系统 JetStream(`server/jetstream.go`,约 3000 行;由 `opts.JetStream` 显式开启,server/server.go:2443-2462),而非默认形态。`go.mod` 的依赖表也印证"总线优先":总共 10 个直接依赖,一半是 NATS 自家库(nats-io/jwt、nkeys、nuid、nats.go)(go.mod:7-19)。

"at-most-once"不是偷懒,而是有配套的活性检测兜底:服务端默认每 2 分钟 ping 一次客户端,允许 2 次未应答即断开(const.go:120-123),死连接、死订阅者由 TCP 层 + ping 机制收敛,不引入 broker 端确认协议。想要的语义(至少一次、恰好一次)全部上移到 JetStream 的 consumer 层(server/consumer.go),核心协议面保持极简——这是理解整个代码库分层的第一把钥匙。

## 2. 全景图

### 2.1 Server 对象层次:一个进程,七个 kind,三层网络

Go 里没有独立的 Route/Gateway/Leaf "类"——**一切连接都是 `*client`**,靠 `kind` 字段分型(server/client.go:45-60);Server 只是持有这些 client 的聚合根(server/server.go:169)。

```
                        +---------------------------------------------------+
                        |        Server  (server/server.go:169)             |
                        |   info Info(:108) | opts Options | clients map    |
                        |   sublist(按账号) | routes | gateways | leafs     |
                        +----+------------+------------+------------+-------+
                             |            |            |            |
        :4222 (const.go:78)  |   cluster  |   gateway  |  leaf :7422|  monitor :8222
        CLIENT 连接          |   ROUTER   |   GATEWAY  |  LEAF      |  (HTTP, 非NATS协议)
                             v            v            v            v
        AcceptLoop     server.go:2783  route.go:2728 gateway.go:511 leafnode.go:984  server.go:3100
        accept 入口    :2852           :2853         :590           :1071            mux :3150-3180
                             |            |            |
                             +----- 同一个 acceptConnections (server.go:2899) ------+
                                              |
                                        createXxx(conn) -> *client{kind:...}
                                        每连接 2 个 goroutine: readLoop + writeLoop
                                              |
                        同进程内部:SYSTEM / JETSTREAM / ACCOUNT 三种"无 socket"内部 client (client.go:62-65)
        跨集群:GATEWAY 桥接多个 cluster;ROUTE 组成单 cluster;LEAF 下挂子树

        三个平面:
          数据面  :4222 CLIENT + :7422 LEAF            -- 承载业务 PUB/SUB
          集群面  cluster 端口 ROUTE + gateway 端口 GATEWAY -- 承载服务器间转发与订阅传播
          运维面  :8222 HTTP 监控(server.go:3100) + pprof(server.go:2951) + $SYS 事件(events.go:49-72)
```

### 2.2 一条消息的生命周期(单机路径)

```
 客户端: "PUB foo 5\r\nhello\r\n"
   |
   v  [1] readLoop 每连接常驻读循环               client.go:1467
   |     parser 状态机逐字节解析(OP/PUB/MSG...)   parser.go:17 (parseState)
   v  [2] processPub -> processInboundClientMsg   client.go:2959 / :4364
   |     发布权限检查 / 保留前缀检查               client.go:4386-4405
   v  [3] acc.sl.Match(subject) 主题匹配          client.go:4479 -> sublist.go:532
   |     (每账号一棵 Sublist trie + 1024 条缓存)  sublist.go:49-51
   v  [4] processMsgResults -> deliverMsg         client.go:5242 / :3778
   |     对每个订阅者: queueOutbound 到对方写缓冲
   v  [5] 订阅者连接的 writeLoop 被信号唤醒        client.go:1376
         flushOutbound: 折叠缓冲, writev 一次落 socket   client.go:1729
   |
   +--> 无本地订阅时: 转发给 ROUTE(集群内)/ GATEWAY(跨集群)/ LEAF(子树)
```

## 3. 目录结构导览

| 位置 | 职责 | 证据 |
|---|---|---|
| `main.go` | 唯一入口,约 135 行,flag 解析后交给 server 包 | main.go:98-135 |
| `server/`(85 个非测试文件) | 全部核心逻辑:协议、路由、聚类、JetStream | 见下分条 |
| `server/client.go`(7065 行) | 连接抽象 + 协议处理 + 消息投递,单文件即"内核" | client.go:45-60, :1467, :1376 |
| `server/server.go`(4808 行) | Server 结构、Info、NewServer/Start/Shutdown、monitor 挂载 | server.go:108, :708, :2267, :3100 |
| `server/route.go`(3362 行) | 集群内路由连接与协议(RS+/LS+ 等) | route.go:2728, :2882 |
| `server/gateway.go`(3426 行) | 跨 cluster 网关、interest-only 模式 | gateway.go:487, :805 |
| `server/leafnode.go` | 叶子节点(注意文件名不是 leaf.go) | leafnode.go:984, :1251 |
| `server/sublist.go`(1744 行) | 主题匹配 trie(通配符 `*`/`>`) | sublist.go:5-12, :368, :532 |
| `server/jetstream*.go` | JetStream 流/消费者/RAFT 集群(约 10 个核心文件) | jetstream.go:1; jetstream_cluster.go |
| `server/mqtt.go` / `websocket.go` | MQTT 与 WebSocket 前端(复用 client,扩展类型 NATS/MQTT/WS) | client.go:70-79; mqtt.go:525; websocket.go:1265 |
| `server/monitor.go`(4383 行) | 全部监控 HTTP handler | monitor.go:740, :1508, :2020 |
| `server/parser.go` / `proto.go` | 协议解析状态机 / protobuf 辅助 | parser.go:17; proto.go:12 |
| `server/opts.go` | Options 全集 + 配置文件/flag 解析入口 | opts.go:964, :6223 |
| `server/ipqueue.go` | 单 goroutine 消费的无锁批量队列(事件、JS 内部用) | ipqueue.go;server.go:793 用例 |
| `server/filestore.go` / `memstore.go` / `stream.go` / `consumer.go` | JetStream 存储与流/消费者模型 | 文件本身 |

`server/` 下还有几个值得留意的算法子包:`avl`(平衡树)、`stree`(subject 树,服务导入映射用)、`gsl`(全局 sublist 相关)、`pse`(进程统计)、`sdm`(确定性模拟相关)以及平台相关的 `disk_avail_*.go`(按 GOOS 分文件,无需 cgo)。`archive/`、`ats/`、`certidp/`、`certstore/`、`elastic/`、`tpm/`、`thw/` 则分别承载归档、证书存证/校验、弹性存储与 TPM 支持等外围能力。

### 3.1 配置解析:自研 lexer,不做 YAML

配置格式是 NATS 自有语法(JSON 超集风格),`conf/` 包自带 lexer 与 parser,文件头注释直接给出能力清单(conf/parse.go:1-8):

```go
// conf/parse.go:1-8(摘录)
// The format supported is less restrictive than today's formats.
// Supports mixed Arrays [], nested Maps {}, multiple comment types (# and //)
// Also supports key value assignments using '=' or ':' or whiteSpace()
//   e.g. foo = 2, foo : 2, foo 2
// maps can be assigned with no key separator as well
// semicolons as value terminators in key/value assignments are optional
//
// see parse_test.go for more examples.
```

入口在 `Options.ProcessConfigFile`(opts.go:964),命令行与配置文件在 `ConfigureOptions`(opts.go:6223)汇合;`-t` 校验模式(main.go:38)只走解析不启动,`main.go:112-114` 会输出配置摘要后退出。不选 YAML 的动机与"单二进制"一脉相承:配置解析零第三方依赖,且错误信息可以精确到词法位置。
| `server/events.go`(3389 行) | 系统账号事件($SYS 主题) | events.go:49-72 |
| `conf/` | 配置文件词法与解析(自研 lexer/parser,支持 HCL 风格) | conf/parse.go:1-8; conf/lex.go |
| `internal/` | antithesis 插桩、ldap、ocsp、testhelper 等内部包 | internal/ 目录列举 |
| `test/`(38 项) | 跨模块集成测试(集群、认证、基准) | test/ 目录列举 |

## 4. 启动链:从 `main()` 到 "Server is ready"

`main.go` 极薄:解析选项(main.go:106 ConfigureOptions)→ 建服务器(main.go:121)→ 配日志(main.go:127)→ `server.Run(s)`(main.go:130,实际是 service.go:20 的薄包装,为 Windows 服务模式留钩子)→ 阻塞等退出(main.go:134)。真正的启动顺序全部在 `(*Server).Start()`(server.go:2267):

1. 打印版本/Git/集群名/服务器名/ID(server.go:2289-2299);
2. 安全告警检查,置 `running=true`(server.go:2305-2308);
3. 可选 pprof 端口(server.go:2324-2326);
4. 写 PID 文件(server.go:2374-2379);
5. 建系统账号 `$SYS`(server.go:2382-2390,默认值 const.go:244);
6. **启动监控 HTTP**(server.go:2394,注释明确"先于其他子系统,便于启动期观测");
7. 账号解析器(Operator 模式)启动(server.go:2400-2403);
8. 启用 JetStream(server.go:2443-2462);
9. **startGateways**(server.go:2514-2516,先于 route,注释:需先解析出 gateway host:port 供 INFO 通告);
10. WebSocket / LeafNode 监听与 leaf 远端外呼(server.go:2521-2535);
11. MQTT(server.go:2551-2553);
12. **StartRouting** 在 goroutine 中等待 client 端口就绪信号(server.go:2556-2560 + route.go:2882-2890,同步通道 `clientListenReady` 见 server.go:2548);
13. `close(s.startupComplete)`(server.go:2571);
14. 最后主 goroutine 进入 **AcceptLoop** 阻塞 accept 客户端(server.go:2574-2576)。

`NewServer`(server.go:708)则负责:生成服务器 NKey 身份(server.go:716)与 x25519 加密密钥(server.go:722-725)、validateOptions(server.go:738)、组装 `Info`(server.go:742-761)与 `Server` 结构(server.go:769-788)。

### 4.1 对照面:关闭链(Start 的镜像)

`Shutdown`(server.go:2588)的顺序恰好把 Start 反着走一遍,值得作为"启动链"的对照阅读:先 `signalPullConsumers`/`stepdownRaftNodes`(server.go:2598-2601),再关系统事件 `shutdownEventing`(server.go:2607),然后 `shutdownJetStream` + `shutdownRaftNodes`(server.go:2627-2630),接着把五类连接(client/routes/gateways/leafs + 未注册完的临时连接)整体抄册(server.go:2633-2658),最后逐个 Close 各监听器踢出 accept 循环:client listener(server.go:2664-2668)、websocket(server.go:2671)、MQTT(server.go:2674-2678)、leafnode(server.go:2681-2685)。每个 accept 循环退出时向 `s.done` 投递一条信号(server.go:2924),Shutdown 据此计数等待,`WaitForShutdown`(server.go:2778)阻塞 main goroutine 直到全链清空。启动与关闭共用同一张"监听器清单",这是单文件里隐藏的状态机。

## 5. 连接类型:一个 struct,七个 kind

```go
// server/client.go:44-60(摘录)
const (
    // CLIENT is an end user.
    CLIENT = iota
    // ROUTER represents another server in the cluster.
    ROUTER
    // GATEWAY is a link between 2 clusters.
    GATEWAY
    // SYSTEM is an internal system client.
    SYSTEM
    // LEAF is for leaf node connections.
    LEAF
    // JETSTREAM is an internal jetstream client.
    JETSTREAM
    // ACCOUNT is for the internal client for accounts.
    ACCOUNT
)
```

题面所说"五种"实际是**七个常量**:对外四种(CLIENT/ROUTER/GATEWAY/LEAF)+ 对内三种(SYSTEM/JETSTREAM/ACCOUNT,由 `isInternalClient` 判定,client.go:62-65)。此外 CLIENT 还细分扩展类型 NATS/MQTT/WS(client.go:70-79)。各 kind 的 accept 入口:

| kind | 监听/外呼 | accept 或 create 入口 |
|---|---|---|
| CLIENT | :4222 | `AcceptLoop`→`acceptConnections(l,"Client",createClient)` server.go:2852;createClient server.go:3255 |
| ROUTER | cluster 端口 + 隐式发现/外呼 | `StartRouting`→`startRouteAcceptLoop` route.go:2882/:2728;accept 于 route.go:2853;外呼 `connectToRoute` route.go:2923 |
| GATEWAY | gateway 端口 | `startGateways`→`startGatewayAcceptLoop` gateway.go:487/:511;accept 于 gateway.go:590;createGateway gateway.go:805 |
| LEAF | :7422 监听 + Remotes 外呼 | `startLeafNodeAcceptLoop` leafnode.go:984;accept 于 leafnode.go:1071;createLeafNode leafnode.go:1251 |
| MQTT/WS | 各自端口 | mqtt.go:559;websocket.go:1265 |
| SYSTEM/JETSTREAM/ACCOUNT | 无 socket | 进程内构造(如 JetStream 内部 client) |

### 5.1 连接建立时的 INFO 交换

四类对外连接的第一步都是交换 `Info` JSON,但同一个 `Info` 结构(server.go:108-166)按 kind 装填不同字段段:结构体尾部专门划出 Route Specific(:140-151,含 RoutePoolSize/GossipMode)、Gateways Specific(:153-160,含 GatewayNRP/GatewayIOM)、LeafNode Specific(:162-163)三段注释区。GATEWAY accept 时就预先声明"所有账号立刻切 interest-only 模式"(gateway.go:552-558);LEAF 的 Info 带 `InfoOnConnect: true`,即服务端响应 CONNECT 时回 INFO(leafnode.go:1028),叶子据此感知域名与 JS 能力。也就是说:**协议协商不需要第二套报文格式,一个 struct + omitempty 字段段服务四类连接**——省去了版本分叉,也让 `Info` 成为阅读集群协议的最佳索引。

### 5.2 订阅状态如何沿着三层传播

订阅的本地登记与跨机传播是两条独立路径:本地 `processSubEx` 校验后写入该账号的 sublist(client.go:3068,Insert 于 client.go:3136);传播侧则由 ROUTE/GATEWAY/LEAF 各自的协议把 `RS+`/`LS+` 等指令发往远端——route.go 集中了 `sendRouteSubProtos`/`sendRouteUnSubProtos` 及其共用实现(route.go:1907, :1916, :1924)。对读者而言,记住一个不变式即可:**消息永远跟着"本地匹配 + 按需转发"走:匹配不到就转发订阅状态,匹配得到才转发消息**。这正是 NATS 集群在大规模订阅数下不退化的原因,也是 gateway interest-only 模式(gateway.go:552-558)的动机。

MQTT 与 WebSocket 不是独立 kind,而是 CLIENT 之上的扩展类型(client.go:70-79),这是理解代码组织的关键:一套协议处理,多套前端。

kind 不只是个枚举,它直接改变连接的 IO 参数与集群行为:`initClient`(client.go:723)按 kind 快照不同的写超时策略——ROUTER/GATEWAY/LEAF 各自读取 Cluster/Gateway/LeafNode 的 WriteDeadline,写超时策略默认重试而非断连(client.go:733-750),因为"不能因为一次写堵塞就拆掉集群链路";而普通 CLIENT 默认策略是 Close。日志与事件里也统一用 `kindString()`(client.go:6077)输出可读名。更细一层,ROUTE 还能按账号建池:Server 持有 `accRoutes` 映射(server.go:207),为指定账号维护独立 route 连接(初始化见 server.go:981-985),默认池大小 3(const.go:159)——高吞吐账号可以独占集群链路,避免与全局流量互相踩踏。

## 6. 事件循环模型:每连接两 goroutine,条件变量驱动写

accept 侧是教科书式 Go:`acceptConnections` 一个 `for { l.Accept() }` 循环,每个新连接起一个 goroutine 执行 createFunc(server.go:2899-2922)。连接建立后,createClient 末尾拉起**两个**常驻 goroutine(server.go:3579-3582):

```go
// server/server.go:3577-3582(摘录)
// Set the Ping timer. Will be reset once connect was received.
c.setPingTimer()

// Spin up the read loop.
s.startGoRoutine(func() { c.readLoop(pre) })

// Spin up the write loop.
s.startGoRoutine(func() { c.writeLoop() })
```

- **readLoop**(client.go:1467,注释明言"Runs in its own Go routine",client.go:1465-1466):阻塞读 socket,喂给 parser 状态机,同步处理每条协议指令——发布、订阅、转发全在读 goroutine 内完成。
- **writeLoop**(client.go:1376):平时挂在 `c.out.sg.Wait()` 条件变量上休眠(client.go:1397),被 `flushSignal` 唤醒后调 `flushOutbound`(client.go:1418)——把待写缓冲折叠(`collapsePtoNB`,client.go:1760)用 writev 一次性写出。关闭时由 writeLoop 负责最后冲刷与收尾(`writeLoopStarted` 分支,client.go:2109-2117)。

accept 侧还有一道背压闸门:临时性 accept 错误不直接退出,而是按 `ACCEPT_MIN_SLEEP`(10ms)到 `ACCEPT_MAX_SLEEP`(1s)指数退避(const.go:141-144;server.go:2900, :2908,退避实现在 `acceptError` server.go:4627)。这保证了短暂 fd 耗尽时服务器"变慢"而不是"崩溃"。

### 6.1 写侧的"顺路冲刷"与预算制

写路径有一个容易被忽略的优化:发布者的 readLoop 在把消息排队进订阅者的写缓冲后,并不总是唤醒对方的 writeLoop,而是记入 `pcd`(pending clients)集合,攒一批后在本线程内"顺路"就地冲刷——`flushClients(budget)` 接受一个时间预算,预算内就直接调对方的 `flushOutbound`,超预算才退回 `flushSignal` 异步唤醒(client.go:1426-1455)。注释写明这是"budget for how much time to spend in place flushing"(client.go:1423-1425)。收益:小消息高频场景省掉一轮 goroutine 唤醒延迟;代价:读 goroutine 可能替别人干活——所以 flushOutbound 开头有 `runtime.Gosched()` 让位逻辑,防止读写两个 goroutine 自旋竞争(client.go:1730-1737)。写进文章时,这是"锁粒度与调度协作"的绝佳切片。

与 Envoy 单线程 event loop 的对比:Envoy 把 N 个连接复用在少量 worker 线程的非阻塞事件循环上,依赖回调不阻塞来保证吞吐;NATS 反其道而行——**连接数即 goroutine 数**,读写各自阻塞,靠 Go 调度器消化并发。代价是每连接约 2 个 goroutine 栈(外加 ping timer),收益是代码形态为顺序过程、无回调地狱;写侧又用条件变量+缓冲折叠弥补"每连接独立写 goroutine"的写放大(server.go:与 client.go:1729-1737 中 readLoop 也会就地抢刷,`runtime.Gosched` 让位)。这是"语言运行时补贴架构复杂度"的典型样本:Envoy 用 C++ 必须自己做事件循环,NATS 用 Go 把它外包给了 runtime。64K 默认连接上限(const.go:105)下,goroutine 模型完全够用。

## 7. 内嵌 NATS:一句话位置

NATS 支持在同一进程内嵌运行:测试里 `server.NewServer` + `DontListen`(不起监听,opts.go:420)即可;Go 客户端经 `s.InProcessConn()` 拿一条 `net.Pipe` 直连,绕过 TCP 栈(server.go:2882-2897)。分布式 server 的 `Server` 结构从设计上就允许"被当作库嵌入"——NewServer 注释专门提醒:嵌入场景下选项是手工赋值的,绕过了配置解析(server.go:734-737)。

## 8. 监控:内嵌 HTTP,函数级挂载

监控不依赖外部组件:配置了 `http_port`(默认 8222,const.go:135)后,`StartMonitoring`(server.go:3024)→ `startMonitoring`(server.go:3100)用标准库 `http.ServeMux` 在 goroutine 里 `srv.Serve`(server.go:3198-3209)。路径常量集中在 server.go:3044-3061(`/varz /connz /routez /gatewayz /leafz /subsz /stacksz /accountz /accstatz /jsz /healthz /ipqueuesz /raftz /debug/vars`),挂载点在 server.go:3150-3180,一行一个 handler:Root→HandleRoot、Varz→HandleVarz、Connz→HandleConnz……全部实现在 server/monitor.go(HandleConnz :740、HandleRoutez :927、HandleSubsz :1110、HandleRoot :1508、HandleVarz :2020、HandleGatewayz :2381、HandleLeafz :2520、HandleJsz :3424、HandleHealthz :3567、HandleRaftz :4263)。系统侧还有一套 `$SYS` 主题事件(connect/disconnect/lameduck/shutdown 等,events.go:49-72)与 `sendStatsz`(events.go:896),HTTP 给人看,$SYS 给程序消费。

两处工程细节值得写进文章:一是监控 HTTP 故意**不设 WriteTimeout**(注释:会导致 cURL/浏览器在慢查询时空响应,server.go:3182-3191),二是 `/debug/vars` 直接复用标准库 `expvar.Handler`(server.go:3180),`main.go:118` 还特意在启动前 `RedactArgs` 把命令行里的密钥参数抹掉,防止 expvar 泄漏。

## 9. 版本与发布

版本字符串硬编码在 `server/const.go:69`(`VERSION = "2.15.0-dev"`),协议级别 `PROTO = 1`(const.go:75);Git commit 不写死在源码,而是构建时经 `debug.ReadBuildInfo` 的 `vcs.revision` 注入,取前 7 位(const.go:54-65, :38-39)。版本随 `Info` 结构下发——连接时第一条协议就是 INFO JSON(server.go:742-761 构造;Info 字段全集 server.go:108-166,含 Version/GitCommit/GoVersion/Cluster/Domain/JSApiLevel 等),`Start()` 启动横幅再次打印(server.go:2289-2290)。默认参数同样是发布契约的一部分:客户端 4222、监控 8222、leaf 7422、route 池默认 3 条、单条 payload 默认 1MB(const.go:78, :135, :206, :159, :94)。

## 10. 设计动机(≥5 条)

1. **为什么每连接一个 goroutine**:把"协议解析→权限→匹配→投递"写成同步顺序代码,可读性和正确性优先;百万级连接不是设计目标(默认 64K,const.go:105),Go runtime 已把栈成本摊薄。Envoy 需要 event loop 是因为没有廉价线程,NATS 有,就不造那个轮子(server.go:2899-2922, :3579-3582)。
2. **为什么读和写各一个 goroutine**:读写解耦后,慢消费者不会阻塞生产者的读循环;写侧用条件变量聚合多次唤醒为一次 writev(client.go:1392-1419),close 竞态统一交给 writeLoop 收尾(client.go:2109-2117),把"谁负责关 socket"这个经典难题收敛到单点。
3. **为什么文本协议**:INFO/CONNECT/PUB/SUB/MSG 全是 `\r\n` 分隔的文本(const.go:126),telnet 可调试、抓包可读、各语言实现零门槛(40+ 客户端,README.md:5);二进制收益(带宽)在消息体本身远大于控制行,parser 状态机(parser.go:17)在 CPU 上也不构成瓶颈。
4. **为什么单二进制、依赖极简**:go.mod 仅 10 个直接依赖且过半自研(go.mod:7-19),无数据库、无注册中心、无第三方框架;边缘/树莓派场景(README.md:5)要求部署物就是一个静态文件,监控内嵌(server.go:3100)同理——运维面收敛为一个进程加一个端口。
5. **为什么 client/route/gateway 三层分型**:单机→集群(ROUTE,扇出订阅状态)→超级集群(GATEWAY,按账号 interest-only 惰性同步,gateway.go:552-558)→多租户边缘(LEAF,信任边界下沉到叶子)。四层拓扑用同一个 client 抽象 + kind 常量表达(client.go:45-60),新增一种连接(MQTT/WS)只是 CLIENT 的扩展类型而非新协议栈(client.go:70-79),扩展成本被压到最低。
6. **为什么匹配逻辑按账号一棵 Sublist**:权限、导出/导入都以账号为边界,per-account trie + genid 缓存失效(client.go:3136、sublist.go:532)让"百万订阅"退化为"每账号各自小 trie",匹配复杂度不随全局订阅数爆炸。
7. **为什么监控先于其他子系统启动**:Start() 里 StartMonitoring 排在 gateway/route/leaf 之前,注释明说是为了"启动期也能被观测"(server.go:2392-2394)——分布式系统的排障窗口往往就在启动那几秒,可观测性不是上线后的附加品,而是启动顺序的一部分。
8. **为什么版本分两路注入**:源码里只有 `VERSION` 常量(const.go:69)保证语义化版本始终存在,而 git commit 经 `debug.ReadBuildInfo` 在运行时读取(const.go:54-65)——同一份源码产出的二进制自证出处,不需要构建脚本写文件,天然适配 `go install` 的发行方式。

## 11. 阅读路径建议(按依赖顺序)

第一次通读建议按以下顺序,每步都有明确的问题牵引:

1. **main.go:98-135** → "一个二进制最少需要几行代码跑起来?"(答案:ConfigureOptions + NewServer + Run);
2. **server/server.go:708-788** → "Server 结构里有什么?"(身份密钥、Info、sublist、各类连接池);
3. **server/server.go:2267-2580** → "启动顺序为什么是 监控→gateway→route→client accept?"(依赖关系:INFO 要通告端口);
4. **server/server.go:2783-2925 + 3579-3582** → "连接怎么变成 goroutine?";
5. **server/client.go:1467 → parser.go → 4364 → 4479 → 5242 → 1376** → 沿第 2.2 节生命周期图走完一条 PUB 消息;
6. **server/route.go:2728 / gateway.go:487 / leafnode.go:984** → 同一套 accept 模板如何被三种 kind 复用;
7. 最后才是 **server/jetstream.go** 及其 family——没有前六步的心智模型,JetStream 的复杂度只会淹没读者。

## 12. 写作素材清单(12-16 个 `文件:行号`)

1. `README.md:5` — 官方一句话定位(CNCF、40+ 语言、树莓派)
2. `main.go:98-135` — 全部入口逻辑(121 NewServer / 130 Run / 134 WaitForShutdown)
3. `server/service.go:20-23` — Run 薄包装(Windows 服务钩子)
4. `server/server.go:2267-2580` — Start() 全序(2394 监控先启;2514 gateway 先于 route;2575 AcceptLoop)
5. `server/server.go:708-788` — NewServer:NKey/xkey 身份、Info、Server 组装
6. `server/client.go:45-60` — 七种连接 kind 常量
7. `server/client.go:1376-1421` — writeLoop 条件变量主循环
8. `server/client.go:1467` — readLoop("Runs in its own Go routine")
9. `server/client.go:1729-1760` — flushOutbound 与缓冲折叠
10. `server/server.go:2899-2925` — acceptConnections:每连接一 goroutine
11. `server/server.go:3150-3180` — 监控端点 mux 挂载(常量 :3044-3061)
12. `server/sublist.go:532` — Match:主题匹配核心
13. `server/events.go:49-72` — $SYS 事件主题全家福
14. `server/const.go:69-159` — 版本/端口/默认值契约
15. `go.mod:7-19` — 依赖面(仓库根;go 1.26.0,见 go.mod:3)
16. `server/server.go:2886-2897` — InProcessConn:内嵌 NATS 的直连入口
