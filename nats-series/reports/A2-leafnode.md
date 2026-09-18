# A(卷二)《LeafNode:分布式部署的信任边界》

基线:repos/nats-server @ 8f3f31b(下述 文件:行号 均经实际 Read/Grep 核对)。主文件:`server/leafnode.go`(3825 行),配合 `server/client.go`(7065 行)、`server/accounts.go`。
术语约定:主动外连(经 `leafnodes.remotes`)的一方是 **spoke(叶)**,被动 accept 的一方是 **hub(枢纽)**;一条 LeafNode 连接只绑定一对"叶侧账号 ↔ 枢纽侧账号"。

## 0. 拓扑总览

```
      spoke (edge 侧 leaf server)                hub (中心集群 A)
 +--------------------------------+          +-----------------------------------+
 |  client A1   client A2         |  solicit |  route/route/route + gateway      |
 |     \         /    outbound    | -------> |  client H1      JetStream(meta)   |
 |      \       /   (nats/tls/ws  |          |   \    |    /                     |
 |    [本地账号 "edgeA"]  /proxy)  |          |    [账号 "hubA"]  <-- accept 认证  |
 |           |  smap: 本地兴趣快照 |          |    /      \                       |
 |           v                    | inbound  |   client H2   $SYS 系统账号       |
 |   LEAF conn (kind=LEAF, spoke) | <------- |   LEAF conn (kind=LEAF, hub)      |
 +--------------------------------+          +-----------------------------------+
   线上协议(双向): INFO -> CONNECT{is_hub,cluster,domain,remote_account,...}
                    -> LS+ <subj> [queue weight] / LS- <key>   (兴趣, 不带账号字段)
                    -> LMSG/HMSG                               (数据)
   环路探测: 每账号 $LDS.<nuid>,LS+ 出去又从对面回来 => 断链 + 30s 退避
   hub->spoke 增量: updateLeafNodesEx 按需下发 LS±,可 hubOnly 只发本机 hub 连接
```

注:任务书提到的 "SPEB" 在源码中不存在(grep 无命中);leaf 链路的全部线上元素即 INFO / CONNECT / LS± / LMSG,角色由 CONNECT 的 `is_hub` 字段协商(leafnode.go:1087, 2305-2307)。

角色判定矩阵(判定函数在 leafnode.go:123-143):

| 本方行为            | 对端 CONNECT 声明 | 本方角色          | 判定函数                |
|--------------------|------------------|------------------|------------------------|
| solicit(有 remote) | is_hub=false     | spoke            | `isSpokeLeafNode`      |
| solicit             | is_hub=true      | spoke(被降级)   | 同上,置位于 1322-1324  |
| accept(无 remote)  | is_hub=false     | hub              | `isHubLeafNode`        |
| accept              | is_hub=true      | spoke            | `processLeafNodeConnect` 2305-2307 |

所以"hub/spoke"不是部署形态而是每条连接的运行期角色:同一台服务器可以只做 hub(只配 `leafnodes.listen` 不配 remotes),也可以同时持有 outbound 与 inbound leaf 连接,还可以在 leaf 集群(leaf server 也组 route 集群)时以集群为单位接入 hub。

## 1. 定位:信任边界为什么"下沉"到 leaf

- **唯一的"账号可重映射"边界**。与 route/gateway 不同,LeafNode 允许两侧账号体系完全独立:spoke 侧用本地任意账号绑定(建立时按 `LocalAccount` 查本地账号,查不到断链重试,leafnode.go:1290-1304),hub 侧用自己的认证体系(用户/口令、creds JWT 签名、nkey)完成 accept 侧绑定。本地配置模式要求该账号预先存在,operator 模式要求必须是 account nkey(leafnode.go:264-279)。
- **连接必须完成 CONNECT 才算绑定**。注释明说 "Leaf nodes will always require a CONNECT to let us know when we are properly bound to an account"(leafnode.go:1472-1474),accept 端 INFO 恒置 `AuthRequired:true`(leafnode.go:1020)。hub 侧绑定完成后才初始化 smap 并开始兴趣交换(leafnode.go:2350-2359)。
- **权限"hub 声明、spoke 执行"**。spoke 信任 hub 在 INFO 里下发的 Import/Export 权限,注释直接点题:"Only solicited leafnode connections trust permission updates from INFO"(leafnode.go:1715-1737),下发后与本地 `deny_imports/deny_exports` 合并(leafnode.go:1719-1736)。越界流量在离源最近处被拦截,不消耗骨干带宽。
- **edge 场景的代码支撑**:弱网自治(§7)、TLS-first 握手与其 fallback 探测(leafnode.go:1386-1393, 1409-1430)、WebSocket 隧道 `/leafnode` 路径(leafnode.go:63, 3618-3631)、HTTP CONNECT 代理(leafnode.go:614-673)、每 remote 可覆盖的 DialTimeout(leafnode.go:753-758;opts.go:275-280)。
- 与卷一《集群与网关》的对照:集群内节点互信(同一 operator 签发的 creds),gateway 连接甚至不交换账号明细;leaf 则是面向"不可信网络上的对端"设计,这也是它独立监听端口、独立认证超时(`LeafNode.AuthTimeout`,leafnode.go:1480-1487)的原因。

## 2. 连接管理:outbound(solicit)与 inbound(accept)

### 2.1 outbound:外连循环与重连退避

`connectToRemoteLeafNode` 是常驻 for 循环:`pickNextURL()` 轮换 URL → 拨号(可经 HTTP CONNECT 代理隧道,`establishHTTPProxyTunnel`,leafnode.go:614-673)→ 成功即 `createLeafNode` 并返回(leafnode.go:779-861)。失败退避带随机抖动,避免集群同时惊群:

```go
// server/leafnode.go:813-815
jitter := time.Duration(rand.Int64N(int64(reconnectDelay)))
delay := reconnectDelay + jitter
attempts++
```

- 基础间隔 `LeafNode.ReconnectInterval`,默认 1s(const.go:161-162;opts.go:6130-6131)。断链后的重连由 `closeConnection` 统一触发:switch 里捕获 `leafCfg`,然后 `srv.reConnectToRemoteLeafNode(leafCfg)`(client.go:6381-6384, 6440-6443),它再等一个完整 ReconnectInterval(leafnode.go:440-457)。`setNoReconnect` 可禁止重连(client.go:6448-6452)。
- 四种"惩罚性退避"常量:环路 30s、权限违规 30s、集群同名 30s、版本过低 5s(leafnode.go:49, 53, 56, 67),统一经 `setLeafConnectDelayIfSoliciting` 写回 `connDelay`(leafnode.go:3539-3555);错误识别在 `leafProcessErr`(leafnode.go:3515-3534)。
- 并发去重:`connInProgress` 标志 + `quitCh` 通知,防止 close/reload 双触发(leafnode.go:509-526);配置重载新增 remote 走同一入口(reload.go:1214)。配置里的 `Disabled` 可临时禁用某 remote 且保留 reload 语义(opts.go:325-329)。
- 共享系统账号的 remote 首连强制延迟 250ms(`sharedSysAccDelay`),等集群信息稳定(leafnode.go:612, 727-730);solicited 连接失败时还会触发 JS observer 的迁移动画(§6)。

### 2.2 多 hub URL:配置 + 动态学习

- 初始 URL 来自配置;`newLeafNodeCfg` 在 `NoRandomize=false` 时先洗牌(leafnode.go:477-484),`pickNextURL` 把刚失败的 URL 挪到队尾实现轮转(leafnode.go:548-560)。
- hub 集群的每个节点地址通过 route 建立时的 `addLeafNodeURL` 汇入 `leafNodeInfo.LeafNodeURLs` 并重生成 JSON(leafnode.go:1207-1238),再经异步 INFO 广播给所有 leaf 连接(`sendAsyncLeafNodeInfo`,leafnode.go:1242-1248)。
- spoke 侧 `updateLeafNodeURLs`/`doUpdateLNURLs` 用对端数组整体替换候选列表:去重后"收到的在前、配置的在后",并保存 TLS 主机名;`IgnoreDiscoveredServers=true` 可关闭该学习(leafnode.go:1705-1713, 1852-1901;opts.go:331-334)。这是 hub 单点宕机后 spoke 自动换节点的机制。wss 与 nats URL 不允许混配(leafnode.go:300-311)。

### 2.3 inbound:hub 侧 accept

`startLeafNodeAcceptLoop` 监听独立端口,构造专门的 `leafNodeInfo`(带 Domain/JetStream/JSApiLevel/InfoOnConnect,leafnode.go:1014-1030),accept 后同样调 `createLeafNode(conn, nil, nil, nil)`(leafnode.go:1071)。握手时序上,非 TLS-first 时 server 先发 INFO 并用其触发对端 TLS(leafnode.go:1432-1458);TLS-first 时 accept 端先嗅探 4 字节再决定走 TLS 还是回退普通 INFO(leafnode.go:1409-1430)。solicited 侧则等 INFO(带 FirstInfoTimeout 读超时,leafnode.go:1392-1393),收到后 `processLeafnodeInfo` 完成压缩协商、TLS、CONNECT 发送与注册(leafnode.go:1540-1778);spoke 侧发 CONNECT 后起 writeLoop,并给整个注册过程上 2s 的 stale 定时器(leafnode.go:3733-3747;const 3711)。
接错端口的连接会被识别:INFO 的 CID/LeafNodeURLs/ClientConnectURLs/Gateway 组合可区分四种监听端口(leafnode.go:1650-1662 的表格注释,判定在 1579-1583);客户端误连 leaf 端口靠 CONNECT 带了 `lang` 识别(leafnode.go:2220-2224),gateway 误连同理(leafnode.go:2253-2259)。其余硬校验:集群名含空格、保留集群名 `_`(leafnode.go:1664-1675, 2233-2242)、hub 与 spoke 集群同名(leafnode.go:2245-2249)、MinVersion 拒绝且回发 INFO 让对端体面退出(leafnode.go:2261-2272)。
hub 侧还有"陈旧连接顶替":同一 server 名 + 集群名 + 账号新连接进来时,旧的半开连接被 `DuplicateRemoteLeafnodeConnection` 踢掉(leafnode.go:1941-2016)——注释指出这既解决对端未察觉断链的重连竞态,也暴露误配(同账号两条连接)。

建连/注册时序(spoke 视角;行号均为 leafnode.go):

```
 dial 成功 -> createLeafNode(solicited)            1251-1338(置 isSpoke、本地账号绑定)
          -> 等 hub 的 INFO(FirstInfoTimeout)      1392-1393
          -> processLeafnodeInfo:TLS/压缩协商       1540-1640
          -> 记录 remoteServer/Cluster/Domain       1688-1703
          -> 学习 LeafNodeURLs                      1705-1713
          -> leafNodeResumeConnectProcess:发 CONNECT 3715-3749(随后才起 writeLoop)
          <- hub 回 INFO{Import/Export/RemoteAccount, ConnectInfo}  2425-2440
          -> leafNodeFinishConnectProcess           3755-3825
               registerWithAccount(ErrLeafNodeLoop 检查)  client.go:908-911
               addLeafNodeConnection(JS 域判定 §6)
               initLeafNodeSmapAndSendSubs(全量 LS+ §3)
 hub 侧对应:accept -> 发 INFO+nonce -> 等 CONNECT -> processLeafNodeConnect(§4 权限反转)
            -> addLeafNodeConnection -> sendPermsAndAccountInfo -> initLeafNodeSmapAndSendSubs
```

solicited 侧 CONNECT 字段一览(`leafConnectInfo`,leafnode.go:2174-2212):

| 字段            | 语义                                         |
|----------------|----------------------------------------------|
| `is_hub`       | 角色声明,决定对端是否降级为 spoke             |
| `cluster`      | 本方(leaf)集群名,空则按单机处理              |
| `domain`       | 本方 JetStream 域,域扩展判定依据             |
| `remote_account`| 本方绑定的本地账号名,登记到 hub 的映射表      |
| `deny_pub`     | spoke 侧 deny_imports,请 hub 代为执行        |
| `isolate`      | 请求对端对本连接启用兴趣隔离                  |
| `compress_mode`| S2 压缩协商档位                               |

### 2.4 传输变体:压缩、WebSocket

- S2 压缩经 INFO/CONNECT 的 `compress_mode` 协商(`negotiateLeafCompression`,leafnode.go:1780-1848);`auto` 模式按首包 RTT 选档(leafnode.go:1795-1802),切档时读端经 `switchToCompression` 标记、写端换 s2.Writer,已用 permessage-deflate 的 WS 连接不再叠加 S2(leafnode.go:1783-1789)。
- remote URL 带 `ws/wss` scheme 即走 WebSocket:客户端伪装成普通 WS 升级请求打到 `/leafnode` 路径,校验 101 响应、permessage-deflate 与私有的 no-masking 头(leafnode.go:3599-3709);WS 端口 accept 侧靠该路径生成 LEAF 而非 CLIENT 连接(leafnode.go:61-63)。
- TLS 配置解析在 `leafNodeGetTLSConfigForSolicit`:无显式 TLSConfig 时强制 TLS1.2 起(leafnode.go:3561-3586);hub 在首 INFO 里声明 `TLSRequired` 可把无 TLS 配置的 spoke"顶"进 TLS(leafnode.go:1555-1573, 1682-1684)。

## 3. 兴趣传播:LS+/LS- 与 smap

每条 leaf 连接维护 `smap map[string]int32`(主题+可选队列名 → 计数),`leaf` 结构注释明确它"代表所有要发给对面的兴趣"(leafnode.go:84-97);另有短期 `tsub` 防止建连快照与实时订阅竞争造成重复(leafnode.go:90-97, 2595-2605 的 5 秒清理)。

- **LS+/LS- 不携带账号**。线上格式 `LS+ <subj>`、`LS+ <subj> <queue> <weight>`、`LS- <key>`:

```go
// server/leafnode.go:2895-2921(节选)
if n > 0 {
    w.WriteString("LS+ " + key)
    // Check for queue semantics, if found write n.
    if strings.Contains(key, " ") {
        ...
    }
} else {
    w.WriteString("LS- " + key)
}
```

  账号语境由连接本身决定:spoke 的 CONNECT 带 `remote_account`(自己绑定的本地账号名,leafnode.go:1093, 2202-2203),hub 在 INFO 回带 `RemoteAccount`,spoke 将其存入 `s.leafRemoteAccounts`(leafnode.go:1751-1760)。这与 route 的 RS+ 按账号分桶完全不同——leaf 把账号维度折叠成了连接维度。
- **建连全量同步**:`initLeafNodeSmapAndSendSubs` 把账号兴趣快照进 smap 并批量写 LS+。spoke 只取 `acc.sl.localSubs`(排除来自其他 leaf 的兴趣),hub(accept 侧)取 `acc.sl.All()`;再叠加服务型 import 主题、mapping 源主题、网关回执前缀和 `$LDS` 探测主题(leafnode.go:2445-2606,关键行 2470-2474, 2481-2495, 2572-2578);每个 key 写入前都过 canSubscribe 门禁(leafnode.go:2540-2545)。
- **运行期增量**:本地任何 sub/unsub 最终汇到 `acc.updateLeafNodes`(订阅 client.go:3179-3180;退订 client.go:3577;断连清理 client.go:6303-6341;route/gateway 汇总入口 server.go:4717-4723),`updateLeafNodesEx` 遍历 `acc.lleafs`(accounts.go:1068-1078 维护,随机起点遍历避免争用,leafnode.go:2666-2674)逐连接 `updateSmap`,计数过零才发 LS±(leafnode.go:2745-2761)。`hubOnly=true` 变体只发给"本机作为 hub"的连接(client.go:3351-3360;leafnode.go:2684-2688)。
- **spoke 方向过滤**:spoke 只向 hub 传播 CLIENT/SYSTEM/JETSTREAM/ACCOUNT 及其他 hub 角色 leaf 的兴趣,不把别的 spoke 的兴趣二次外传:

```go
// server/leafnode.go:2725-2730
skind := sub.client.kind
updateClient := skind == CLIENT || skind == SYSTEM || skind == JETSTREAM || skind == ACCOUNT
if !isLDS && c.isSpokeLeafNode() && !(updateClient || (skind == LEAF && !sub.client.isSpokeLeafNode())) {
    return
}
```

  发送前再做一次 canSubscribe,但 `$LDS./$GR/_GR_` 前缀豁免(leafnode.go:2805-2827)。`isolated`(server 级 `isolate_leafnode_interest` 或 remote 级 `local_isolation/request_isolation`)完全阻断 leaf 间兴趣互通(leafnode.go:137-143, 2546-2549, 2651-2654;opts.go:319-323)。

smap 的计数收敛逻辑(过零才发协议,队列订阅恒发):

```go
// server/leafnode.go:2745-2761(节选)
key := keyFromSub(sub)
n, ok := c.leaf.smap[key]
if delta < 0 && !ok {
    return
}
// We will update if its a queue, if count is zero (or negative), or we were 0 and are N > 0.
update := sub.queue != nil || (n <= 0 && n+delta > 0) || (n > 0 && n+delta <= 0)
n += delta
if n > 0 {
    c.leaf.smap[key] = n
} else {
    delete(c.leaf.smap, key)
}
if update {
    c.sendLeafNodeSubUpdate(key, n)
}
```

另有 `forceAddToSmap/forceRemoveFromSmap` 供内部组件(如网关回执)强制占位一个主题(leafnode.go:2764-2801)。

- **权限逐条把关**(见 §4):hub 对入站 LS+ 做 `pubAllowedFullCheck`(leafnode.go:2994-3003),spoke 对出站 LS+ 做 canSubscribe(leafnode.go:2805-2827)。

### 3.1 no-echo 与环路检测

- 连接级 no-echo:CONNECT 处理时强制 `Verbose/Echo/Pedantic=false`("Leaf Nodes do not do echo",leafnode.go:2278-2281);转发侧再保底——LEAF 目标仅当 `c != sub.client` 才投递,注释 "leaf nodes are always no echo"(client.go:5360-5369)。
- 簇级 no-echo:leaf 侧 sub 打上 `origin=remoteCluster` 标记(leafnode.go:3013-3016),投递时 `leafOrigin == dc.remoteCluster()` 即跳过,"Cluster wide no echo"(client.go:5467-5468, 5721-5730);队列版在选 qsub 时剔除同簇候选(client.go:5562-5594)。集群名 `_` 为保留的无源标识(route.go:56)。
- 主动环路探测:每账号一个 `$LDS.<nuid>`(leafnode.go:59, 2498-2507),随 smap 发给对面;若它又从对面回来(`processLeafSub` 命中自身 LDS),即判定 A solicit B、B solicit A 的环,断链 + 30s 退避(leafnode.go:2975-2982, 3073-3085),或从对端收到 "Loop detected" ERR 后本地退避(leafnode.go:3515-3534)。第二道闸在注册:`registerWithAccount` 发现账号上已存在同名 leaf 集群即返回 `ErrLeafNodeLoop`(client.go:908-911;errors.go:72)。
- 备注:任务书提到的 "subject 上的 tribe" 概念在源码中不存在(grep 无命中);leaf 回环防护全部由 origin 集群标记 + `$LDS` + 集群名校验承担。

## 4. 账号语义:映射、$SYS 与权限 Gate

- **映射关系的本体是"连接"**:`addLeafNodeConnection` 把连接挂到 hub 侧账号(`acc.lleafs/nleafs` 计数,accounts.go:1066-1078);叶侧账号 ↔ 枢纽侧账号只在这条连接上生效。同账号多条 leaf 连接(多个 edge 站点)共享 hub 侧账号的兴趣池,又靠 remoteCluster 互相隔离回环。账号侧还有 MaxLeafNodes 限额(accounts.go:530-536)。
- **权限映射 Gate(hub→spoke 下行)**:hub 把 accept 认证得到的用户权限反向翻译给 spoke——"perms that it will use on the soliciting leafnode's behalf ... inside the hub need to be reversed since data is flowing in the opposite direction",直接对调 pub/sub 权限字段(leafnode.go:2316-2327);下发由 `sendPermsAndAccountInfo` 完成,同时带 `RemoteAccount` 与 `IsSystemAccount`(leafnode.go:2425-2440)。spoke 用它做三件事:限制建连快照与出站 LS+(§3)、限制入站消息(`leafReceiveAllowed`,leafnode.go:3438-3440)、以及通配符订阅的宽松匹配(leaf 的 allow 通配可反向匹配子主题,client.go:3396-3401)。
- **权限 Gate(spoke→hub 上行)**:hub 用连接的 Export 权限检查 leaf 发来的每条消息;`leafSendAllowed` 刻意读 `c.opts.Export` 而非运行时 perms,以免正常转发路径附加的 JS deny 误杀合法 JS API 请求(leafnode.go:3444-3476)。入站消息总检在 `leafMsgAllowed`:先放行 `_R_` 服务回执与 `$JS.ACK.`(leafnode.go:3396-3401),spoke 方向查 deny_imports、hub 方向查 export,最后兜底 allow_responses 的回复追踪(leafnode.go:3385-3433)。订阅违规即断链;spoke 侧则静默吸收(spoke 的权限是 hub 声明的,只需"不再发送",leafnode.go:3493-3512)。映射改写后的 ACL 按线上原始主题判定(leafnode.go:3386-3394)。
- **$SYS 特殊性**:系统账号可做 leaf 的 LocalAccount,此时 (a) 首连延迟 250ms 并对受限 creds 打告警(leafnode.go:152-198, 182-190);(b) INFO 显式告知 `IsSystemAccount`(leafnode.go:2436;server.go:136-137);(c) 系统账号连接是 JetStream 域扩展的前提(§6);(d) hub 侧 leaf 建立后发 account connect 事件并把账号切入 interest-mode(events.go:2432-2443),spoke 侧仅当配置为 Hub 角色时才发(leafnode.go:3773-3776)。

## 5. 消息路径:client→leaf→hub 与叠加场景

出站(leaf→hub):client 发布 → `processMsgResults` 命中账号子表中的 leaf 影子订阅(hub 发来的 LS+ 在 `processLeafSub` 里以 `sub.leaf=true` 插入 `acc.sl`,leafnode.go:2938, 3027-3035)→ LEAF 目标与 ROUTER 同路,经 `addSubToRouteTargets` 汇入 `sendToRoutesOrLeafs` 段写 LMSG(client.go:5348-5369, 5688-5775);入站(hub→leaf):`processInboundLeafMsg` 用每连接 L1 结果缓存 + 无兴趣短路(leafnode.go:3320-3356),再交给本机订阅与 gateways(leafnode.go:3372-3378)。spoke 有一条硬规则:来自 spoke 的消息不再借道 route 转发(client.go:5554-5557)。

```go
// server/client.go:5360-5368(节选)
case LEAF:
    // We handle similarly to routes and use the same data structures.
    // ...
    // Also leaf nodes are always no echo, so we make sure we are not
    // going to send back to ourselves here.
    if c != sub.client && (c.kind != ROUTER || sub.client.isHubLeafNode() || isServiceReply(c.pa.subject)) {
        c.addSubToRouteTargets(sub)
    }
    continue
```

网关叠加:leaf 把 gw 回执前缀 `.>`/`_GR_.>` 放进 smap 强制对端"订阅"(leafnode.go:2569-2575);spoke 侧插一个 `gwReplyPrefix+">"` 影子订阅到全局 `s.gwLeafSubs`,让网关映射回执直达 leaf 客户端,断连时摘除(leafnode.go:2529-2534, 2149-2153);gateway 处理 RS± 时经 `updateInterestForAccountOnGateway` 反向喂给 leaf(leafnode.go:2609-2617)。队列与映射的空队列过滤对 leaf/route/gw 特判(leafnode.go:3366-3371;client.go:5471-5477)。
跨 leaf 的系统请求还有一个细节:消息头里的客户端信息带的是 leaf 侧账号名,若与 hub 侧账号不同名,`$SYS` 服务按头查账号会失败,所以发往 leaf 前要换头——`checkLeafClientInfoHeader`(调用点 client.go:5732-5740,实现 5777-5789):

```go
// server/client.go:5777-5789(节选)
// Check and swap accounts on a client info header destined across a leafnode.
func (c *client) checkLeafClientInfoHeader(msg []byte) (dmsg []byte, setHdr bool) {
    if c.pa.hdr < 0 || len(msg) < c.pa.hdr {
        return msg, false
    }
    cir := sliceHeader(ClientInfoHdr, msg[:c.pa.hdr])
    if len(cir) == 0 {
        return msg, false
    }
    ...
```

## 6. JetStream over leaf:域扩展与 JS API 代理

判定集中在注册时执行一次的 `addLeafNodeConnection`(leafnode.go:2034-2136):

```go
// server/leafnode.go:2089-2104(节选)
} else if acc == sysAcc {
    // system account and same domain
    s.sys.client.Noticef("Extending JetStream domain %q ...", myRemoteDomain, ...)
    if solicited && meta != nil && !meta.IsObserver() {
        ...
        meta.setObserver(true, extExtended)
        meta.Reset()
    }
}
```

- **域匹配才放行**:`opts.JetStreamDomain` 与远端域不一致(或本机无 JS、无系统账号)→ 对系统账号 deny 整表 `denyAllJs`,对普通账号 deny `denyAllClientJs`(jetstream_api.go:371-372;leafnode.go:2064-2088)。
- **普通账号的代理路径**:域一致且本机有 JS 时,给非系统账号挂映射表 `generateJSMappingTable(domain)`——把 `$JS.<domain>.API.*`、`$JS.<domain>.API.$KV.>` 等映射回 `$JS.API.*` 空间(jetstream_api.go:374-400;挂接 leafnode.go:2116-2125)。于是 edge 应用对本地域前缀发出的 JS API 请求被 mapping 改写、穿过 leaf 连接落到 hub 的 JS API 订阅上,响应原路返回——"JS 代理"没有专用 RPC,全部由 deny 表 + subject mapping 实现。同时给账号加 `jsDomainAPI`(`$JS.<domain>.API.>`,jetstream_api.go:44)出站 deny,防止本域流量从 leaf 漏向同域名对端;注释自认这只防部分误配形态(leafnode.go:2126-2135)。
- **系统账号扩展(共享 $SYS)**:hub 与 leaf 域一致时,leaf 侧 meta raft 进入 observer 并 `Reset()` 对齐 raft 日志(注释解释了不 Reset 会导致两条 raft 日志分叉),把元数据领导权让给 hub(leafnode.go:2089-2104);域不同则关 observer、写回 peer state 并显式 Campaign(leafnode.go:2072-2083)。
- **弱网配套**:`jetstream_cluster_migrate` 在断连超时后把本机 R>1 资产的 leader 迁走(`checkJetStreamMigrate`:StepDown + SetObserver(true),leafnode.go:824-841, 906-946),恢复连接后 `clearObserverState` 复位(leafnode.go:872-904;配置 opts.go:309-317);leaf 连接建立/恢复都会重试 source/mirror 的断链同步消费者 `checkInternalSyncConsumers`(leafnode.go:2373-2413, 1774-1777)。
- 旧式向后兼容:`js_acc_default_domain` 出现空域映射即禁用扩展(leafnode.go:2039-2056)。

## 7. 断连行为:本地自治与恢复后的全量重放

- hub 不可达时,leaf 上的 client 连接、本地订阅匹配、本地 JS 资产全部照常——没有任何代码路径因 leaf 连接断开而停服;受影响的只有跨边界消息(hub 侧兴趣已撤销,匹配为空)与上述 JS leader 迁移计时。
- 断连瞬间,hub 侧清理该连接全部影子订阅并撤销兴趣:close 对 LEAF 调 `clearAccountSubs(true)`(client.go:6236-6244),撤单循环里普通订阅 -1 且 spoke 不回传 route/gateway,队列按 qw 聚合(client.go:6298-6341);`removeLeafNodeConnection` 摘除 tsub 定时器、gwSub 并清 connect-in-progress(leafnode.go:2140-2172);账号侧同步回收 `lleafs` 与 leafClusters 计数(accounts.go:1122-1164)。
- 恢复后**全量重放**:重连成功 → `leafNodeFinishConnectProcess` → `registerWithAccount` + `addLeafNodeConnection` → 重新执行 `initLeafNodeSmapAndSendSubs`,把当前账号兴趣整体快照成一批 LS+ 推给对端;注释指出 leaf 连接无 max pending 限制,直接队列化由 writeLoop 吐出(leafnode.go:3785-3806, 2586-2594)。这与集群 route 的增量 RS 修复不同:状态一次快照收敛,简单且幂等。
- 陈旧半开连接由 hub 侧 dup 检测顶替(§2.3),避免"旧连接占着兴趣、新连接进不来"。
- 重连期间的互斥:断开时 `removeLeafNodeConnection` 依据 noReconnect 标志决定 connect-in-progress 的取值,保证"断开→重连"窗口内标志语义正确(leafnode.go:2154-2162);若 remote 已被 reload 移除/禁用,`addLeafNodeConnection` 直接拒绝入表并 `setNoReconnect`(leafnode.go:1992-2004),以及 `connectToRemoteLeafNode` 退出时清理 JS observer 残留状态,防止本机 raft 资产永远停留在 observer(leafnode.go:701-711)。

## 8. 队列组与权重(qw)在 leaf 侧的表达

- hub→leaf 的 LS+ 对队列订阅带第三参数:权重 `LS+ foo bar 3`,解析进 `sub.qw`,且 delta 直接取权重:

```go
// server/leafnode.go:2944-2954(节选)
case 3:
    sub.queue = args[1]
    sub.qw = int32(parseSize(args[2]))
    // TODO: (ik) ... just overwrite `delta` if queue
    // weight is greater than 1 ...
    if sub.qw > 1 {
        delta = sub.qw
    }
```

- 权重变化走"同 key 更新"而非重建:`delta = sub.qw - osub.qw` 后 `UpdateRemoteQSub`(leafnode.go:3037-3042)。smap 键是 `subject + ' ' + queue`,**不含权重**(`keyFromSub`,leafnode.go:2836-2846;存 sid 时刻意截掉尾部权重,leafnode.go:3017-3024);权重只是计数与 delta,普通订阅 `qw==0` 计 1(leafnode.go:2553-2558)。
- 投递侧:hub 上多 leaf 同队列时偏向 leaf 候选、剔除同簇、随机均摊(client.go:5505-5533,含 issue #6040 掷币注释);断连清理按 qw 批量撤销(client.go:6317-6324)。leaf 连接还有独立写超时(client.go:737)。

## 9. 设计动机(总结)

1. **为什么信任边界在 leaf**:hub 对 edge 是不可信网络上的对端,认证必须发生在 hub 的 accept 端,而执行要下沉到 spoke——hub 只下发 Import/Export 权限声明,spoke 本地过滤出站 LS+ 与入站消息,越权流量在离源最近处被拦截,不消耗骨干带宽(leafnode.go:1715-1737, 2805-2827, 3444-3476)。
2. **为什么 hub-spoke 而非 full mesh**:N 个 edge 站点两两互连是 O(N²) 条公网链路且要解决全网回环;收敛到 hub 后每站点只维护 1 条链路,回环退化为"对端集群标记 + 单一探测主题"两个可局部解决的问题($LDS + origin cluster,leafnode.go:59, 3013-3016)。interest-only 协议也只有在树形拓扑上才有最小状态量。
3. **为什么 leaf 可以独立账号**:账号名只是本地命名空间,跨边界语境被折叠成"每连接一对账号映射"(RemoteAccount,leafnode.go:1093, 1751-1760)。edge 可自由演进本地账号/权限而不惊动中心,同时把"每条 RS+ 都带账号"的协议开销从 leaf 协议中拿掉。
4. **为什么断连本地继续**:edge 网络是间歇性的,断连即降级本地服务的话 leaf 就失去意义。实现上本地服务只依赖账号子表,leaf 影子订阅只是其中普通成员,断开随 `clearAccountSubs` 摘除,天然不阻塞本地匹配(client.go:6236-6244)。
5. **为什么 JS 走代理而非副本**:edge 通常没有条件跑 R3 元数据集群。把 JS API 请求用 subject mapping 透明转发到 hub 域($JS.<domain>.API → $JS.API,jetstream_api.go:374-400),edge 应用零改动获得中心化 JS;`jetstream_cluster_migrate` 处理"edge 自身也参与 JS 集群"的对称场景(leafnode.go:906-946)。
6. **为什么恢复靠全量重放而非日志**:断连期间 hub 的兴趣变化无法廉价增量补发(无序号/确认层),而单账号兴趣规模可控;一次快照既简单又幂等,配合 stale-connection 顶替即可收敛(leafnode.go:2445-2606, 1952-2016)。
7. **为什么 LS+/LS- 简化到"无账号、无 SID"**:计数语义(smap)替代会话语义(SID),使 leaf 连接可以像 route 一样断线即弃、重连重建;唯一需要精确的数值是队列权重,因为它影响负载分配而非存在性(leafnode.go:2751-2761, 2941-2954)。

## 写作素材清单(文件:行号,均经核对)

1. `server/leafnode.go:70-103` — leaf 结构:smap/isSpoke/isolated/tsub/gwSub
2. `server/leafnode.go:690-861` — solicit 主循环:URL 轮换、代理、抖动退避、createLeafNode
3. `server/leafnode.go:813-815` — 重连抖动:delay = ReconnectInterval + rand(ReconnectInterval)
4. `server/leafnode.go:984-1073` — hub 侧 accept 循环与 leafNodeInfo(AuthRequired/Domain/JSApiLevel)
5. `server/leafnode.go:1082-1096` — spoke CONNECT 内容:is_hub/cluster/deny_pub/remote_account/isolate
6. `server/leafnode.go:1472-1474, 1715-1737` — CONNECT 必经 + spoke 信任 INFO 权限(权限 Gate 下行)
7. `server/leafnode.go:1650-1662` — 四种监听端口的 INFO 指纹表(接错端口检测)
8. `server/leafnode.go:2058-2136` — JS 域扩展判定:denyAllJs/denyAllClientJs/mapping/observer
9. `server/leafnode.go:2316-2327` — hub→spoke 权限方向反转(import/export 对调)
10. `server/leafnode.go:2445-2606` — initLeafNodeSmapAndSendSubs:全量兴趣快照与特殊前缀
11. `server/leafnode.go:2623-2709` — updateLeafNodesEx:hubOnly、isolated、origin 集群过滤
12. `server/leafnode.go:2891-2921` — LS+/LS- 线上格式(队列权重第三参数)
13. `server/leafnode.go:2924-3068` — processLeafSub:qw、LDS 回环、origin 标记、route/gw 转发门控
14. `server/leafnode.go:3385-3433` — leafMsgAllowed:两个方向的 ACL + `_R_`/$JS.ACK 免检
15. `server/client.go:5360-5369, 5721-5730` — no-echo 双保险(连接级 + 集群级)与 LMSG 投递
16. `server/client.go:6303-6341` — 断连兴趣撤销:普通 -1、队列按 qw,spoke 不回传 route
17. `server/jetstream_api.go:371-400` — deny 表与 $JS.<domain>.API 映射表(JS 代理机制本体)
18. `server/accounts.go:1090-1116` — registerLeafNodeCluster/isLeafNodeClusterIsolated(隔离判定)

(完)
