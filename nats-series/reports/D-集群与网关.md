# D · 集群路由与网关:无共识协议的扇出网络

> 《NATS 深读》系列调研报告 D
> 基线:nats-server @ 8f3f31b0366eca0d855d0750b7ca547eadd10eff(2.15.0-dev,server/const.go:69)
> 行号均为该 commit 下的实测行号;专题核心文件:`server/route.go`、`server/gateway.go`、`server/const.go`。

## 0. 拓扑与两条路径

```
        Gateway 域 A (cluster "alpha", 3 节点全互联)           Gateway 域 B (cluster "beta")
  ┌────────────────────────────────────────────────┐      ┌─────────────────────────────────┐
  │      route 池(每对服务器默认 3 条 TCP,按账号哈希分片) │      │                                 │
  │   ┌────┐ ═════════════════════════ ┌────┐          │      │            ┌────┐               │
  │   │ S1 │                           │ S2 │          │      │            │ S4 │               │
  │   └────┘ ═══════════╗              └────┘          │      │            └────┘               │
  │     ▲  ╲═══════╗    ╚══════════▶ ┌────┐          │      │    GW-in ▲      ▲ client C      │
  │     │           ╚═══════════════ │ S3 │          │      │          ║      SUB foo         │
  │  client P               订阅者 ─▶ └────┘          │      │  RS+/RS-(beta 兴趣)║            │
  │  PUB foo                                          └──────┼────────────────╫───────────────┘
  └─────────────▲────────────────────────────────────────────┼────────────────║
                ╚══════════ GW outbound(每对集群域每服务器 1 条)═════════════╝
                        S1 ──RMSG──▶ S4 ;S4 ──RS+/RS-──▶ S1(双向、异步)
```

- **跨节点消息**(A 域内):P 在 S1 `PUB foo`,S3 上有订阅者。S1 在账号 sublist 中命中"来自 route 的兴趣条目"(client.kind==ROUTER,server/client.go:5351-5355),构造 `RMSG <account> <subject> ...`(server/client.go:3628-3630 经 msgHeaderForRouteOrLeaf),发给 S3;S3 侧 `processInboundRoutedMsg` 二次匹配本地 sublist 后投递(server/route.go:462-502)。
- **订阅传播**:S3 的客户端 `SUB foo` → `processSubEx` 调 `updateRouteSubscriptionMap`(server/client.go:3172-3174),在 `acc.rm` 计数并在 0→1 边沿向所有 route 发 `RS+ <account> <subject>`(server/route.go:2609-2622、2716-2722);S1/S2 收到后把该远端兴趣插入各自 `acc.sl`(server/route.go:1710-1727)。**每个节点的账号 sublist 因此是"全局兴趣的投影"**:本地订阅 + 所有 route/gateway 侧登记的远端兴趣。
- **跨域消息**:S1 `sendMsgToGateways` 先问 `gatewayInterest`(server/gateway.go:2164-2206),仅当 beta 域兴趣已知(经 S4 入站连接回传的 RS+/A+ 登记)才发;消息仍用 `'R'` 开头的 RMSG 形式(server/gateway.go:2686-2691),S4 的 `processInboundGatewayMsg` 收尾(server/gateway.go:3107-3177)。
- **interest-only vs full(乐观)模式**:cluster(route)从设计上**只有**"显式兴趣"一条路——没有兴趣就没有 route 目标,不存在洪泛;gateway 才有三态(Optimistic/Transitioning/InterestOnly,server/gateway.go:97-111):Optimistic 是"先洪泛、收到 RS- 再拉黑"的 full 模式,InterestOnly 是"先同步全部兴趣、只往有订阅者的方向发"。

## 1. ROUTE 协议:一条"复用客户端语法"的信令通道

route 连接使用与客户端相同的文本协议骨架:CONNECT/INFO/PING/PONG/OK/ERR,外加集群私有操作。协议字节常量集中定义(server/route.go:47-54):

```go
var (
	aSubBytes   = []byte{'A', '+', ' '}   // ← 账号级兴趣(网关用)
	aUnsubBytes = []byte{'A', '-', ' '}
	rSubBytes   = []byte{'R', 'S', '+', ' '} // ← 格式:RS+ <account> <subject>[ <queue> <weight>]
	rUnsubBytes = []byte{'R', 'S', '-', ' '}
	lSubBytes   = []byte{'L', 'S', '+', ' '} // ← 叶子集群兴趣(带 origin cluster)
	lUnsubBytes = []byte{'L', 'S', '-', ' '}
)
```
(摘录自 server/route.go:47-54,行尾注释为本报告所加;RS+ 完整格式见 server/route.go:1822 的注释 `RS+ [<account name> ]<subject>[ <queue> <weight>]`。)

解析端与客户端共用同一个 parser 状态机,`R`/`RS`/`L`/`LS` 只是新增的分支(server/parser.go:114-117);参数上限同样受 4KB 控制行约束(server/const.go:88-90,RMSG 6 参数 server/const.go:176-177)。CONNECT 里携带服务器 ID 与 cluster 名(server/route.go:113-128、505-534),INFO 则交换 host/port/gateway URL/权限/压缩等(server/server.go:108-166;route 专有字段 server.go:140-151)。首次 INFO 会协商 s2 压缩,双方模式取交集(server/route.go:758-807、906-913)。

INFO 交换在 `processRouteInfo`(server/route.go:552-904)里完成注册语义:首条 INFO 走 `addRoute` 登记(server/route.go:894),之后再到 INFO 就是"增量通知"——比如远端进入 Lame Duck 时撤回其 client connect URLs(720-742)、import/export 权限变更重算(726-732)、gateway/leafnode URL 变更委托给对应子系统(688-700)。cluster 名冲突时的处理很能体现"无共识"气质:如果自己是动态名就接受对方的,或者字典序大者胜,然后断开除对方以外的所有 route 重建(server/route.go:583-595)——这是字符串比较,不是选举。

`RS+` 帧的拼装在 `addRouteSubOrUnsubProtoToBuf`(server/route.go:1745-1797):有叶子集群来源时改用 `LS+ <origin> <account> <subject>`(1748-1759),per-account 专用 route 上连账号名都省掉(1775-1778),队列订阅在 RS+ 上附当前聚合权重、RS- 上不带(server/route.go:1780-1793)。

**隐式订阅(implicit interest)是集群的核心**:一条 route 上的全部远端兴趣以"账号+主题(+队列+权重)"为粒度保存在 route 连接的 `c.subs` 中(key 前缀 `R `/`L ` 区分来源,server/route.go:1511-1548),并插入账号 sublist(server/route.go:1710-1727)。注释里专门解释了为什么 key 要带 `R`/`L` 前缀:`RS+ foo bar baz`(routed 队列订阅)与 `LS+ foo bar baz`(leaf 兴趣)的参数可能拼出相同的中间串,不加类型前缀会撞 key(server/route.go:1512-1528)。这些兴趣条目**不带 sid**、按计数收敛,队列订阅带权重 `qw`,权重变化会触发重发(server/route.go:1571-1598、1722-1727)。

**隐式订阅不等于"转发 SUB"**——这是 cluster 协议最容易误读的点:客户端的 `SUB foo 1`(带 sid)与 `UNSUB 1` 在进入服务器后就终止了,跨网传播的是**去 sid 化的聚合兴趣**(`processSubEx` 只调 `updateRouteSubscriptionMap`/`gatewayUpdateSubInterest`,server/client.go:3168-3178;UNSUB 对称,server/client.go:3568-3575)。每台服务器看到的 `RS+` 永远是"远端还有没有人要"的投影,而不是某个具体连接的状态;连接级语义(如 `UNSUB <sid> <max>` 的自动退订)由各服务器自行消化。本地订阅变化则由 `updateRouteSubscriptionMap` 折算成 RS+/RS-:

```go
	if n, ok = rm[key]; ok {
		n += delta
		if n <= 0 {
			delete(rm, key)
			delete(lws, key)
			update = true // Update for deleting (N->0)
		} else {
			rm[key] = n
		}
	} else if delta > 0 {
		n = delta
		rm[key] = delta
		update = true // Adding a new entry for normal sub means update (0->1)
	}
```
(摘录自 server/route.go:2609-2622;`acc.rm`/`acc.lws` 定义见 server/accounts.go:82-83——`lws` 记录"上次发给 route 的值"用于去重。)

值得注意的是入口过滤:函数开头就排除 `sub.client.kind == ROUTER || GATEWAY`——"We only store state on local subs for transmission across all other routes"(server/route.go:2553-2565)。也就是说,从 route 收到的远端兴趣只进账号 sublist 用于本地匹配,**不会被再广播回其他 route**;再广播的义务由最初的兴趣源节点承担。这从根上斩断了"兴趣回声"循环。

只有 0→1 与 N→0 两个边沿才会产生协议流量(server/route.go:2603-2628),发送时以 `acc.smu` 串行化保证顺序(server/route.go:2688-2710)。新 route 接入时,`addRoute` 会一次性把**全量兴趣**灌给它:`sendSubsToRoute` 遍历所有(按池索引筛选的)账号的 `a.rm`,逐条拼 `RS+` 批量帧(server/route.go:1805-1900,格式注释见 1822;调用点 server/route.go:2252、2430)。这条"重放当前全量"的路径正是断线重连后兴趣视图能够收敛的原因——不需要日志,只需要快照。UNSUB/RS- 的对称路径在 `processRemoteUnsub`(server/route.go:1415-1500,网关联动在 1489)。

**权限是兴趣流的第二道闸**。route 连接上的 `Cluster.Permissions` 定义 import/export 双向主题许可,注释直白:`canImport` 决定"要不要把兴趣发出去",`canExport` 决定"要不要接受对端的兴趣登记"(server/route.go:1232-1252)。两个方向都生效:灌全量时逐条过滤(`route.canImport`,server/route.go:1887),登记远端兴趣时也逐条过滤(`canExport`,server/route.go:1681-1685);每次发送时的 `importFilter` 是同一语义的闭包包装(server/route.go:2544-2549)。也就是说权限不只拦消息,还从兴趣源头"剪枝",被剪掉的方向连 RS+ 都不存在,带宽为零。

**消息与兴趣共用账号定位**:入站 RMSG 第一参数是账号名,`getAccAndResultFromCache` 直接在对应账号 sublist 上匹配;无兴趣则整体短路丢弃:

```go
	// Check for no interest, short circuit if so.
	// This is the fanout scale.
	if len(r.psubs)+len(r.qsubs) > 0 {
		c.processMsgResults(acc, r, msg, nil, c.pa.subject, c.pa.reply, pmrNoFlag)
	}
```
(摘录自 server/route.go:497-501。注释自称这就是"扇出的规模感"所在:一次 map 查找 + 一次 sublist 匹配,决定这条跨网消息是否还有存在的意义。)队列消息用 `'+'`(带回复)/`'|'`(仅队列)指示符携带队列过滤(server/route.go:423-444),收到方据此只投递指定队列,避免同一队列消息在每台机器上都随机选一次人。

## 2. gossip 与 seeds:全互联是如何长出来的

- **显式 seed**:`cluster.routes` 配置的 URL 由 `StartRouting → startRouteAcceptLoop → solicitRoutes` 逐条 `connectToRoute(..., Explicit, ...)` 永久重试(server/route.go:2882-2892、3036-3049);接受端在 route 监听口 accept 后按 `Implicit` 处理(server/route.go:2853)。
- **gossip 扩散**:任一 server 学到新邻居后,`forwardNewRouteInfoToKnownServers` 把它的初始 INFO 转发给所有已知远端,并用 `GossipMode`(default/disabled/override)控制扩散方向,防止 gossip 风暴(server/route.go:1148-1230,关键判断 1150-1154);收到"第三方 INFO"的 server 调 `processImplicitRoute` 主动去连那个新邻居(server/route.go:702-714、1052-1108)。隐式连接只重试 `Cluster.ConnectRetries` 次,显式连接才永久重试(server/route.go:2928-2930、2980-2987)。`processImplicitRoute` 的防重入检查覆盖三层:已连接、已配置(`hasThisRouteConfigured`,server/route.go:1113-1142)、是自己——三者任一命中就直接放弃(server/route.go:1066-1083)。
- **网关侧的对应物**:route INFO 捎带 `info.Gateway`,由 `processGatewayInfoFromRoute` 委托给网关代码(server/route.go:688-700、gateway.go:1393-1400);`processImplicitGateway` 用同样的思路按名字去重、聚合 URL 后发起隐式网关连接(server/gateway.go:1452-1497);入站网关再用 gossip INFO 把自己知道的其他网关回赠给对方,注释直言目标是 "full mesh"(server/gateway.go:1249-1252、1252-1276)。
- **防环与去重**:
  - 自己连自己:`info.ID == s.info.ID` 直接关闭(server/route.go:568-575);
  - 双向同时拨号导致的重复连接:`handleDuplicateRoute` 保留一条、给另一条 `retry=true`,注释明说是为了缓解"两边都在对侧连接上 add route,导致两条都被关"的死锁(server/route.go:2502-2541,尤其 2536-2539);重连侧再加 0-100ms 随机抖动(server/route.go:2894-2911);
  - solicited 仲裁:连接池里已有拨号方时,accept 方被"升级"为 solicited(`hasSolicitedRoute`/`upgradeRouteToSolicited`,server/route.go:2464-2500,调用点 2302-2317);
  - 同名服务器拒绝(JetStream 需要唯一名,server/route.go:745-752)、cluster 名冲突以字典序仲裁动态名(server/route.go:583-595)。
- **"子网探测"**:connect 阶段显式 URL 的主机名先经 DNS 解析成多个 IP,`getRandomIP` 随机挑一个,并剔除 `routesToSelf`——启动时枚举本机全部接口地址与 route 端口拼出的"自身地址表"(server/route.go:2836-2850),从而避免在 NAT/多网卡环境下自己拨回自己;全部 IP 被剔除则放弃(server/server.go:4649-4681)。gossip 侧则用 INFO 里的 `info.IP`(优先 `Cluster.Advertise`)回连(server/route.go:859-872)。

## 3. 消息扇出:兴趣匹配即路由

发布端核心在 `processMsgResults`:匹配账号 sublist 后,普通订阅本地投递,ROUTER/GATEWAY/LEAF 类型的"订阅"被收进 `c.in.rts` 延后批量处理:

```go
		for _, sub := range r.psubs {
			// Check if this is a send to a ROUTER. We now process
			// these after everything else.
			switch sub.client.kind {
			case ROUTER:
				if (c.kind != ROUTER && !c.isSpokeLeafNode()) || (flags&pmrAllowSendFromRouteToRoute != 0) {
					c.addSubToRouteTargets(sub)
				}
				continue
			case GATEWAY:
				// Never send to gateway from here.
				continue
```
(摘录自 server/client.go:5348-5359。GATEWAY 分支直接 `continue` 是因为跨域发送根本不走 sublist——发布路径上另起 `sendMsgToGateways`,用自己的 outsim 兴趣表做闸门;这里能命中 GATEWAY 类型的 sub 只是网关侧登记的兴趣残影。)route 队列订阅有"本地优先、远端兜底"的挑选逻辑,候选里 LEAF 与 ROUTER 之间甚至掷硬币平衡(server/client.go:5505-5533)。最终 `sendToRoutesOrLeafs` 逐目标发送,并按目标是否支持头部改写 `R`/`H`/`L` 前缀(server/client.go:5688-5774;前缀选择 server/client.go:3605-3634)。gateway 消息则在发布路径上直接调 `sendMsgToGateways`(server/gateway.go:2539-2768)。

## 4. 网关:跨账号域的聚合层

三种"横向通道"一页速览(均为代码实测):

| 维度 | route(集群内) | gateway(跨集群域) | leafnode( spoke) |
| --- | --- | --- | --- |
| 连接对象 | 同 cluster 名,全互联 | 不同 gateway 名,每对域每服务器 1 条出站 | hub-spoke |
| 兴趣粒度 | 账号+主题(+队列权重) | 账号域(A±)/主题(RS±)聚合 | 账号+主题 |
| 兴趣同步 | 双向全量(注册即灌) | 乐观→interest-only 渐进 | 按需 |
| 消息头 | `R`/`H`/`L`(带 origin) | `R`/`H` + `$GNR` 回复前缀 | `L` |
| 连接数规模 | N(N-1)/2 × 池 3 | N×M(每服务器级) | 1 hub 对多 spoke |

**route 与 gateway 的分工**(代码证据):
- route 连接要求 CONNECT 带 `cluster` 且必须与本集群同名(server/route.go:583-595);gateway CONNECT 带 `gateway` 名(server/gateway.go:958-986),且网关端口显式拒绝 client/route 误连(server/gateway.go:994-1027,错误分支 1001-1005)。
- route 兴趣是**subject 级**且双向全量同步(第 1 节);gateway 兴趣是**账号域级聚合**:入站侧用 `pasi`(per-account subject interest tally,`sitally{n,q}`,server/gateway.go:187-192、2390-2446)把整个集群的订阅折算成 first/last 事件,只有首末才发 RS+/RS-(server/gateway.go:2471-2477),账号整体无兴趣时降级为一条 `A-`(server/gateway.go:2777-2811、1874-1898)。每对集群域之间,一个服务器只维持一条出站连接(server/gateway.go:139-146 的 `out`/`in`/`outsim`/`insim` 结构,207-259),对端入口收到后再借集群内 route 扇出——所以网关消息的"入口"收敛到单台,集群内再借 route 的全互联扩散,避免 N×M 连接爆炸。
- 跨域请求-回复靠 `$GNR.<cluster hash>.<server hash>.<subject>` 前缀把回复**定向**送回源集群(server/gateway.go:43-54、2483-2502、2586-2594;`handleGatewayReply` server/gateway.go:2963-2971),前缀在发送回复时按远端是否支持新前缀选择(server/gateway.go:2657-2674)。发送方只有当本地近期见过对该 reply 的订阅兴趣时才做映射(`shouldMapReplyForGatewaySend`,server/gateway.go:2506-2521),映射关系带 TTL 定期清理(server/gateway.go:3324-3346 起的 `trackGWReply`)。
- 服务引入(service import)有一个专门的"豁免":入站网关消息即使 sublist 命中的全是服务引入影子订阅,也会被识别为"无真实兴趣"并发 RS-,防止 `_R_` 服务回复主题被误当普通兴趣(server/gateway.go:3144-3175)。

**GW/RSUB+ 协议与三态切换**。`GatewayInterestMode` 三值及语义(server/gateway.go:97-111):Optimistic(默认,发消息除非被告知无兴趣)/Transitioning/InterestOnly(不发除非确认有兴趣)。出站侧 `outsie.ni` 是"远端无兴趣"黑名单,`outsie.sl` 是 InterestOnly 下的远端兴趣表(server/gateway.go:228-246);入站侧 `insie.ni` 记录"已对哪些 subject 发过 RS-"(server/gateway.go:248-259)。发送前的一票否决在 `gatewayInterest`(server/gateway.go:2164-2206):

```go
	ei, accountInMap := c.gw.outsim.Load(acc)
	// If there is an entry for this account and ei is nil,
	// it means that the remote is not interested at all in
	// this account and we could not possibly have queue subs.
	if accountInMap && ei == nil {
		return false, nil
	}
	// Assume interest if account not in map, unless we support
	// only interest-only mode.
	psi := !accountInMap && !c.gw.interestOnlyMode
```
(摘录自 server/gateway.go:2165-2174。三层判断依次是:A- 整账号拉黑 → 不在表里就乐观假设有兴趣 → interestOnlyMode 下不许假设。)命中后再查 `outsie.sl` 的队列兴趣,拼出带队列名的 RMSG(server/gateway.go:2611-2655)。

切换条件(如实):
- 历史机制:同一账号累计发出的 RS- 达到 `gatewayMaxRUnsubBeforeSwitch=1000`(server/gateway.go:41)即触发 `gatewaySwitchAccountToSendAllSubs`,以 INFO 命令 `GatewayCmd` 2/3(start/complete,server/gateway.go:87-91)包裹一次全量 RS+ 重放(server/gateway.go:2844-2857、3249-3314;对端置 Transitioning→InterestOnly,server/gateway.go:3183-3237);

```go
				if _, alreadySent := e.ni[string(subject)]; !alreadySent {
					// TODO(ik): pick some threshold as to when
					// we need to switch mode
					if len(e.ni) >= gatewayMaxRUnsubBeforeSwitch {
						// If too many RS-, switch to all-subs-mode.
						c.gatewaySwitchAccountToSendAllSubs(e, string(accName))
					} else {
						e.ni[string(subject)] = struct{}{}
						sendProto = true
					}
				}
```
(摘录自 server/gateway.go:2844-2857。)
- **现状(2.9.0 起)**:网关 INFO 一律携带 `GatewayIOM=true`("所有账号立即切 InterestOnly",server/server.go:160;置位点 server/gateway.go:552-558),入站连接注册后直接把**所有账号**切到 interest-only,除非测试旗标 `gwDoNotForceInterestOnlyMode` 介入(server/gateway.go:1199-1245,尤其 1236-1245)。出站连接在握手时看到对端的 `GatewayIOM` 也会置 `interestOnlyMode`,从此不再"假设有兴趣"(server/gateway.go:220-223、2174)。所以"cluster 默认是什么"的如实回答是:**route(集群内)从来没有乐观模式,天然 interest-only;gateway 名义上的默认 Optimistic 自 2.9.0 起在实际部署中被 IOM 立即切换为 InterestOnly**,阈值路径仅剩历史/测试意义。
- 求证说明:任务书提到的 "RSUB/B/P/C 标志" 在本 commit 代码中不存在名为 B/P/C 的标志位;"RSUB 前缀 `$RWS`" 同样查无此处(全仓 grep 无 `$RWS`)。实际存在的是 RS+/RS-、LS+/LS-、A+/A- 三组前缀,RMSG 参数中的 `'+'`/`'|'` 回复指示符(server/route.go:423-444;gateway 侧同构 server/gateway.go:2692-2699),以及 `GatewayCmd` 1/2/3 三个命令码(server/gateway.go:87-91)。报告如实按代码记录。
- 队列订阅是例外:无论模式,队列兴趣(QSub)总是即时以带权重的 RS+ 登记到网关(server/gateway.go:2334-2383;连接建立时先补发全部队列兴趣 server/gateway.go:1200、1310-1387)——因为队列消息投给"任何一个成员"即算成功,漏发一条就意味着整个队列空转,负反馈模型无法弥补。
- 全量兴趣重放(`sendSubsToGateway`)与 route 侧 `sendSubsToRoute` 同构:在 `pasi` 锁下遍历账号计数表拼 RS+ 批量帧,完成后把该账号的 `insie.mode` 置为 InterestOnly(server/gateway.go:1314-1387,尤其 1354-1365)。

## 5. 大规模参数清单(代码实测)

| 参数 | 值/位置 | 说明 |
| --- | --- | --- |
| `DEFAULT_ROUTE_POOL_SIZE` | 3,server/const.go:158-159 | 每对服务器 3 条 route,按账号 FNV 哈希分片保证两端一致(server/route.go:541-549) |
| route 拨号/重连节奏 | 1s/30s/1s/1s,server/const.go:146-156 | `Cluster.ConnectBackoff` 指数退避(server/route.go:2993-2999) |
| `Cluster.ConnectRetries` | 默认需显式配置 | 仅约束隐式(gossip)route 的重试次数(server/route.go:2980-2987) |
| route PING | 2min/最多 2 次未答即断,server/const.go:119-123 | 压缩模式下缩短到 30s 以支撑 RTT 采样(server/route.go:140-144) |
| 池化补位 | 首个 PONG 之后才建下一条,server/route.go:2435-2444 | 确保认证成功后再扩张 |
| 网关 PING | 最小 15s,server/gateway.go:56-58 | |
| 网关 RS- 阈值 | 1000,server/gateway.go:41;recent-sub 2s,server/gateway.go:40 | 后者见 server/gateway.go:2460-2462 |
| 网关出站排序 | 按 RTT 升序,server/gateway.go:1760-1766 | 多出站时优先低延迟域 |
| 显式 vs gossip | `routes:` 显式 + INFO gossip,server/route.go:3036-3049、1148-1230 | gossip 可经 `GossipMode` 关闭/覆盖(server/route.go:107-111) |
| 网关重连 | 1s 起/30s 封顶,server/gateway.go:37-39 | `Gateway.ConnectRetries`/backoff 同 route 语义(server/opts.go:156-157) |
| 网关连接补拨 | 入站注册后若缺出站即自动补建,server/gateway.go:1202-1204 | `processImplicitGateway` 幂等,按名字去重 |
| 自身地址黑名单 | `routesToSelf`,server/route.go:2836-2850 | 全接口枚举 + route 端口,防自连 |

## 6. 脑裂与一致性:如实记录"无共识"语义

- **没有共识协议**。route/gateway 层只有 gossip(INFO)、启发式仲裁(重名/重复连接/cluster 名字典序,server/route.go:569-595、745-752、2502-2541)和 ping 判死(server/const.go:119-123)。Raft 只存在于 JetStream(server/jetstream_cluster.go,如 leadership 相关注释 4909、11171),与本报告的消息路径无关。
- **at-most-once**:消息只在"此刻有连接且有兴趣"时投递。入站 route 消息无兴趣即丢(server/route.go:497-501);gateway 收到 RS- 的注释直接写明目的是 "prevent further messages being sent"(server/gateway.go:1926-1931),黑名单命中后消息不再补发(server/gateway.go:2013-2018)。分区两侧行为:PING 超时互删 route(`removeRoute`,server/route.go:3161-3279)、`removeRemoteSubs` 撤销全部远端兴趣(server/route.go:1309-1358,关闭路径 server/client.go:6229-6231)——**期间发布的消息没有任何缓冲与重放**;重连后同步的只是"现在"的兴趣(`sendSubsToRoute`/`sendSubsToGateway`)。
- **最终一致的订阅视图**:乐观网关故意在兴趣未知时先发消息(server/gateway.go:97-101);interest-only 下的"近期订阅"缓存 2 秒后过期删除(server/gateway.go:40、2460-2462);队列权重用 `lws` 做"上次已发值"比对去重(server/accounts.go:82-83、route.go:2694-2710);RS+/RS- 只保证边沿可达,不保证与消息流的全序——这正是"每个节点 sublist 是全局兴趣投影"而非"全局共识副本"的含义。
- **脑裂后果**:分区两侧各自继续服务本地客户端,互不感知;不存在 quorum/leader 阻断写入的问题,也不存在跨分区去重——同一条消息可能经不同入口重复进入同一集群(queue 挑选时甚至掷硬币平衡两条 leaf/route 路径,server/client.go:5520-5527)。这些是有意取舍:扇出网络把"不丢"的义务上移给 JetStream/应用层。
- **"重连即追赶"的收敛窗口**:断线期间两端各自积累的订阅变化,靠重连注册时的全量重放一次性对齐(route:server/route.go:2430;gateway:server/gateway.go:1200),而窗口内的消息两侧都认为是"发了没兴趣"或"有兴趣没收到"——代码不为这个窗口做任何对账。网关侧唯一类似"补偿"的机制是 2 秒近期订阅缓存(server/gateway.go:2460-2462),它只是把"订阅刚建立、RS+ 还没到"的竞态窗口变宽了一点点。
- **动态 cluster 名仲裁**(server/route.go:583-595)是另一个"无共识但可运行"的样本:双方都可能是动态名,规则是"我是动态而对方不是,听对方的;都是动态,字典序大者胜",随后 `removeAllRoutesExcept` 断开其他邻居重建。最坏情形是两侧同轮各改各的名(网络来回窗口内),代码没有为此提供更强保证——它接受短暂的拓扑震荡,而不是阻止它。

## 7. 断连清理(兴趣撤销)路径

1. TCP 断/协议错/认证超时 → `closeConnection`;`kind == ROUTER` 时 `removeRemoteSubs()`(server/client.go:6229-6231)。
2. `removeRemoteSubs` 遍历该 route 的 `c.subs`(即当初 RS+ 登记的远端兴趣),按账号分桶后从账号 sublist 批量删除,并同步 `gatewayUpdateSubInterest(-delta)` 与叶子节点撤销(server/route.go:1309-1358):

```go
	// Now remove the subs by batch for each account sublist.
	for _, ase := range as {
		c.Debugf("Removing %d subscriptions for account %q", len(ase.subs), ase.acc.Name)
		ase.acc.mu.Lock()
		ase.acc.sl.RemoveBatch(ase.subs)
		ase.acc.mu.Unlock()
	}
```
(摘录自 server/route.go:1351-1357。批量删除正是为了大集群抖动时把 O(订阅数) 次 sublist 锁压缩成 O(账号数) 次。)
3. `removeRoute` 把连接从 `s.routes[remoteID][poolIdx]`/`s.accRoutes` 摘除,撤回其贡献的 client connect URLs、gateway URL、leafnode URL,并按需触发重连(server/route.go:3161-3279)。
4. 对端 RS- 主动撤销:`processRemoteUnsub` 从 sublist 删除并联动网关计数(server/route.go:1415-1500,1489);per-account route 迁移期间还会整体清掉该账号的旧远端兴趣(server/route.go:653-663)。
5. gateway 侧对称:出站连接断开即丢弃整个 `outsim` 视图(随 client 生命周期回收);账号整体无兴趣时入站侧发 `A-`、兴趣恢复发 `A+`(server/gateway.go:1874-1924、2777-2811)。

## 8. 设计动机(从代码反推)

1. **为什么无共识**:核心 NATS 的契约是"投递给此刻存在的订阅者"(server/route.go:497-501 无兴趣即弃、无存储无重传),共识只能保证"状态一致",对"消息必达"没有帮助却引入多数派延迟与选主停顿;需要"不丢"时由 JetStream 的 Raft 层接管。订阅拓扑用 gossip 最终一致即可,因为订阅是低频、可收敛、可重放(重连时全量重灌 `sendSubsToRoute`,server/route.go:1805-1900)的。
2. **为什么传播兴趣而不是消息**:SUB 是低频事件,MSG 是高频事件;在源端按"对端兴趣投影"过滤,把跨网流量从 O(消息总量) 压到 O(有订阅者的方向)。边沿触发(0→1/N→0,server/route.go:2603-2628)让稳态下订阅信令接近零;队列用权重而非逐条 SUB 折叠了 N 个成员(server/route.go:1571-1598)。
3. **为什么 gateway 按账号聚合**:跨域链路少而贵,`A-/A+` 一条协议就能开关整个账号域(server/gateway.go:2777-2811),`pasi` 计数把集群内 N 份订阅折叠成 1 条 RS+(server/gateway.go:2390-2477);乐观模式的"负反馈"设计让 B 域即使什么都不配,消息也能先到——代价只是几条被丢弃的洪泛消息。
4. **为什么 interest-only 可切换(且默认切)**:RS- 数量是该账号"远端几乎无兴趣"的在线度量,超阈值即改用全量订阅同步摊平成本(server/gateway.go:2844-2857);切换是每账号、每连接的局部决策(Transitioning 两阶段,server/gateway.go:3249-3314),无需全局协调。2.9.0 后干脆在 INFO 握手声明 IOM 直接全量切换(server/gateway.go:552-558、1236-1245)——实践中"先洪泛再学习"的窗口被证明弊大于利。
5. **为什么 route 明文复用 client 协议**:CONNECT/INFO/PING 与文本解析器整套复用(server/parser.go:114-117 同一状态机;route.go:505-534 的 CONNECT 就是 JSON 化的 connectInfo),带来可 telnet 调试、可向后兼容地增删 INFO 字段(server/server.go:140-160 全是 `omitempty` 可选字段)、滚动升级协议协商(`info.Proto`,server/route.go:812-814)三重红利;代价是 4KB 控制行上限与解析开销(server/const.go:88-90)。
6. **为什么集群是全互联 + 连接池**:路由只需一跳;池化 3 条 TCP 摊薄单连接锁竞争,账号 FNV 分片让两端独立计算出一致的落点(server/route.go:541-549),避免中央分配。
7. **为什么防环靠启发式而非协议**:gossip 建图必然出现双向拨号,用"ID 自检 + solicited 升级 + 随机抖动"三招消解(server/route.go:568-575、2464-2541、2894-2911),比引入分布式 leader 简单得多,坏情形只是断掉多余连接后重试。
8. **为什么 per-account route/pool 与"no pool"兼容并存**:大租户给专用 route、小账号共享 3 连接池,而握手时通过 `RoutePoolSize`/`RoutePoolIdx` 协商,遇到不支持池化的旧 server 就退化为单连接并标记 `noPool`(server/route.go:2162-2192、641-650)——扩展性参数全部设计成"可协商降级",这是滚动升级友好型协议的通用套路。
9. **为什么网关的入口要收敛到单条出站连接**:集群 A 的每个服务器对集群 B 只挂一条出站,B 侧接受后用集群内 route 全互联二次扇出(server/gateway.go:139-146)。若按服务器两两互联,跨域连接数是 N×M 且每条都要维护一份兴趣视图;收敛后兴趣视图只存在于"入口对"上,聚合(`pasi` 计数)也有了唯一的汇聚点。代价是入口单点,于是用 RTT 排序多 URL(server/gateway.go:1760-1766)和 gossip URL 池做冗余。

## 9. 写作素材清单(文件:行号,均已实测核对)

1. server/route.go:47-54 — RS+/RS-/LS+/LS-/A+/A- 协议字节常量(注释含 RS+ 完整格式)
2. server/route.go:113-128 + 505-534 — route CONNECT 的 connectInfo(Cluster/LNOC 等字段)与发送
3. server/route.go:552-575 — processRouteInfo:自连检测、cluster 名冲突仲裁
4. server/route.go:1052-1108 + 1148-1230 — gossip 隐式建链与 INFO 转发(GossipMode 三值 107-111)
5. server/route.go:1502-1742 — processRemoteSub:远端兴趣入账号 sublist(1710-1727),队列权重 1571-1598
6. server/route.go:1745-1797 — RS+/RS-/LS+ 帧拼装,队列权重 1780-1793
7. server/route.go:1805-1900 — sendSubsToRoute:新 route 的全量兴趣灌入(格式注释 1822)
8. server/route.go:2464-2541 — 重复连接仲裁/升级(handleDuplicateRoute 注释 2536-2539)
9. server/route.go:2553-2723 — updateRouteSubscriptionMap:边沿检测与向全 route 广播
10. server/route.go:462-502 — 入站 RMSG:无兴趣短路的"fanout scale"(497-501)
11. server/route.go:1309-1358 + client.go:6229-6231 — route 断连兴趣撤销
12. server/gateway.go:97-111 + 228-259 — 三态兴趣模式与 outsim/insim 数据结构
13. server/gateway.go:2844-2857 + 3249-3314 — RS- 阈值触发全量订阅重放(start/complete 命令)
14. server/gateway.go:2390-2477 — gatewayUpdateSubInterest:账号-主题计数聚合(first/last 才发)
15. server/gateway.go:2539-2768 — sendMsgToGateways:按 gatewayInterest 过滤 + $GNR 回复映射(2657-2674)
16. server/gateway.go:552-558 + 1236-1245 + server.go:160 — 2.9.0 起 GatewayIOM 强制全账号 interest-only

(另备三个补充素材:server/route.go:381-459 与 server/client.go:3605-3634,RMSG 参数解析、`'+'`/`'|'` 队列指示与 `'R'`/`'L'` 消息头拼装;server/client.go:5348-5370 与 5688-5774,processMsgResults 中 ROUTER/GATEWAY 分流与 sendToRoutesOrLeafs 的批量出口;server/gateway.go:2164-2206,出站网关发送前的兴趣一票否决。)

## 10. 结论:一句话版本

集群与网关是同一套思想在两个尺度上的展开:**把"订阅"当作要全网收敛的低频控制面,把"消息"当作只在有订阅者的方向上流动的高频数据面**。route 用全量兴趣同步 + 边沿触发增量做到集群内零洪泛;gateway 用账号聚合 + 乐观/interest-only 两档做到跨域带宽可控;两者都不需要共识——因为它们只承诺"投递给此刻在场且有兴趣的人"(at-most-once),而把"承诺必达"留给 JetStream 的 Raft 层。理解了 `acc.sl` 是全局兴趣的投影、`acc.rm/lws` 是发送边沿的去重账本,route.go 与 gateway.go 合计六千余行就只剩工程细节了。

## 11. 备注

- 本报告所有行号基于 commit 8f3f31b03 实测(Grep/Read 逐条核对),未做任何编译或运行。
- gateway 侧"乐观模式已被 IOM 覆盖"的结论对 2.9.0+ 成立;若读者考古更早版本,阈值 1000(server/gateway.go:41)的路径仍然完整保留在代码中。
- 报告 D 与 A《全景架构》的分层图、B《协议与解析》的 parser 状态机直接衔接;leafnode 的 hub/spoke 兴趣语义(`updateInterestForAccountOnGateway`,server/leafnode.go:2608)建议留待独立篇章展开,本篇仅引用其与 gateway 的联动点。
