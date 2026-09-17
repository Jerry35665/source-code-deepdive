# C 订阅匹配:subject 通配、sublist 与队列组

> 《NATS 深读》系列报告 C
> 基线:commit `8f3f31b0366eca0d855d0750b7ca547eadd10eff`
> 核心文件:`server/sublist.go`(1744 行);配套 `server/client.go`、`server/route.go`、`server/gateway.go`
> 本文所有 `文件:行号` 均在该基线上逐一核对。

---

## 0. 全景图:sublist 树与一次 Match

以两个订阅为例:`S1 = "foo.*.bar"`(普通订阅)、`S2 = "foo.>"`(尾通配订阅)。
树由 `level`(一层 token 的节点集合)与 `node`(具体 token 的挂载点)交替构成,`pwc`/`fwc` 是每层的 `*`/`>` 专用指针(`server/sublist.go:87-99`):

```text
订  S1 = "foo.*.bar"   S2 = "foo.>"

root(level){ nodes:{foo}, pwc:nil, fwc:nil }
  |
  +-- nodes["foo"] --> node{ psubs:{}, qsubs:nil }
         next = level{ nodes:{}, pwc:nodeA, fwc:nodeB }
           |
           +-- pwc --> nodeA(*)                      <-- 承载 "foo.*"
           |          next = level{ nodes:{bar} }
           |                     |
           |                     +-- nodes["bar"] --> node{ psubs:{S1} }
           |
           +-- fwc --> nodeB(>){ psubs:{S2} }        <-- 承载 "foo.>"

Match("foo.baz.bar")  tokens = [foo, baz, bar](栈上 [32]string,sublist.go:576-591)

  i=0  l=root        : l.fwc 无; l.pwc 无; n=nodes[foo] 命中  -> l = foo.next
  i=1  l=foo.next    : l.fwc = nodeB     -> addNodeToResults  收集 S2
                       l.pwc = nodeA     -> 递归 matchLevel(nodeA.next, [bar])
                                            i=0: nodes[bar] 命中 -> 收集 S1
                       n=nodes[baz] 不存在 -> l = nil
  i=2  l=nil         : return
  结果: r.psubs=[S1,S2], r.qsubs=[]
```

要点:`fwc` 在进入某层时先行判定(`sublist.go:777-779`),等价于"前缀 + `>`";`pwc` 走递归分支(`sublist.go:780-782`)。单 token 主题 `foo` 不会命中 `foo.>`——`foo.next` 这层的 `fwc` 永远不会被访问,因为循环在最后一个 token 处已结束。

---

## 1. Subject 语法与非法判定

通配符常量定义在 `server/sublist.go:32-39`:`pwc='*'`(单层)、`fwc='>'`(多层尾)、`tsep='.'`。

- `*` 只能独占一个 token,匹配恰好一层;`>` 同样只能独占 token,且必须是最后一个 token(`sfwc` 标志之后不允许再有 token),插入与删除路径都执行该检查(`sublist.go:380-383`、`sublist.go:874-876`)。
- 订阅侧合法性由 `IsValidSubject -> isValidSubject` 判定(`sublist.go:1205-1246`):空串、空 token(`a..b`)、`>` 之后还有 token、token 内含空白符(`\t\n\f\r `)均非法;`checkRunes` 变体还会拒绝内嵌 NUL 与 UTF-8 替换符(`sublist.go:1213-1225`)。SUB 协议在 `server/client.go:1100` 对 subject 与 queue 都调用此检查。
- 发布侧额外要求字面量:`IsValidPublishSubject = IsValidSubject && subjectIsLiteral`(`sublist.go:1200-1202`)。
- `subjectIsLiteral`(`sublist.go:1187-1197`)与 `subjectHasWildcard`(`sublist.go:1172-1183`)只在"`*`/`>` 独占 token"时才算通配,因此 `foo.a*b` 是合法字面量 token——按普通字符参与树的哈希查找。
- 缓存层专用的逐字节匹配 `matchLiteral`(`sublist.go:1499-1566`)不校验合法性,只按"通配符独占 token"的约定工作,注释明确说明这是为速度优化过的热点函数。

| subject | 订阅合法? | 发布合法? | 说明 |
|---|---|---|---|
| `foo.bar` | 是 | 是 | 纯字面量 |
| `foo.*.bar` | 是 | 否 | `*` 独占 token,单层 |
| `foo.>` | 是 | 否 | `>` 必须为最后 token |
| `foo..bar` | 否 | 否 | 空 token(`isValidSubject` 长度 0 拒绝) |
| `foo.>.bar` | 否 | 否 | `>` 后仍有 token(`sfwc` 拒绝) |
| `foo.a*b` | 是 | 是 | 通配符未独占 token,按字面量字符处理 |

注意 `foo.a*b` 这类 token 在树中走普通 `nodes[t]` 哈希槽,只有独占 token 的 `*`/`>` 才进 `pwc/fwc` 指针(`sublist.go:385-397`)。

## 2. Sublist 数据结构:树 + 结果 + 两级缓存

```go
// server/sublist.go:87-99
type node struct {
	next  *level
	psubs map[*subscription]struct{}
	qsubs map[string]map[*subscription]struct{}
	plist []*subscription
}
type level struct {
	nodes    map[string]*node
	pwc, fwc *node
}
```

- 每层是一个 `map[string]*node` 加两个通配指针,token 命中是 O(1) 哈希查找。
- 节点上普通订阅放 `psubs` 集合;队列订阅按队列名二次分桶 `qsubs[队列名]=成员集合`(`sublist.go:90`),**队列组在匹配层就已聚合**,而非交给投递层再分组。
- `SublistResult` 用 `psubs []*subscription` 与 `qsubs [][]*subscription` 表达结果,注释明确"不要用 map,迭代太贵"(`sublist.go:58-62`)。
- 大扇出优化:单节点普通订阅超过 `plistMin=256` 时构建快照切片 `plist`(`sublist.go:55`、`421-430`),`addNodeToResults` 优先 `append(n.plist...)` 免去 map 迭代(`sublist.go:721-727`);删除订阅时将其置 nil 等待重建(`sublist.go:1013-1018`)。

缓存在工程上是**两级**的:

| 层 | 位置 | 键 | 失效机制 |
|---|---|---|---|
| L1 | 每连接 `c.in.results` | 发布 subject | account sublist 的 `genid` 变化即整体作废 |
| L2 | `Sublist.cache` 共享 map | 发布 subject | 订阅/退订时的增量修补或删除,容量驱动的清扫 |

L1 逻辑在 `server/client.go:4465-4494`:记录 `genid := atomic.LoadUint64(&acc.sl.genid)`(`client.go:4383`),genid 未变且缓存命中则直接用;否则整表重建并回退到 `acc.sl.Match`。上限 `maxResultCacheSize=512`、随机裁剪 `pruneSize=32`(`client.go:474-477`、`4482-4490`)。L2 上限 `slCacheMax=1024`,超过后由后台 goroutine 随机清到 `slCacheSweep=256`(`sublist.go:49-56`、`629-631`、`688-699`),用 `ccSweep` 的 CAS 保证只有一个清扫者。

## 3. Match 主循环:缓存命中 vs 树遍历

```go
// server/sublist.go:559-619(节选)
func (s *Sublist) match(subject string, doLock bool, doCopyOnCache bool) *SublistResult {
	atomic.AddUint64(&s.matches, 1)
	if doLock { s.RLock() }
	r, ok := s.cache[subject]                    // L2 读
	if doLock { s.RUnlock() }
	if ok {
		atomic.AddUint64(&s.cacheHits, 1)
		return r                                 // 命中:O(1) 返回共享结果
	}
	/* ... 栈上切 token ... */
	result := &SublistResult{}
	if cacheEnabled { s.Lock() } else { s.RLock() }   // 未命中:有缓存则持写锁
	matchLevel(s.root, tokens, result)
	if len(result.psubs) == 0 && len(result.qsubs) == 0 {
		result = emptyResult                     // 共享的空结果单例(sublist.go:528)
	}
	s.cache[subject] = result
```

- `Match`/`MatchBytes` 是 `match(subject, true, ...)` 的封装(`sublist.go:532-540`);`MatchBytes` 在写缓存前 `copyString` 拷贝 subject,避免缓存键引用协议缓冲区(`sublist.go:613-617`)。
- 树遍历核心只有十几行,是整个 server 被调用最频繁的函数之一:

```go
// server/sublist.go:771-796(节选)
func matchLevel(l *level, toks []string, results *SublistResult) {
	var pwc, n *node
	for i, t := range toks {
		if l == nil {
			return
		}
		if l.fwc != nil {
			addNodeToResults(l.fwc, results)          // 前缀 + ">" 命中
		}
		if pwc = l.pwc; pwc != nil {
			matchLevel(pwc.next, toks[i+1:], results) // "*" 递归分支
		}
		n = l.nodes[t]                                // 字面量下沉
		if n != nil {
			l = n.next
		} else {
			l = nil
		}
	}
```

  逐 token 检查 `fwc`、递归 `pwc`、字面量下沉;循环结束后补收最后一个字面量节点与最后一层 `pwc` 节点(`sublist.go:790-795`)。
- 命中路径返回的是**共享** `*SublistResult`;发布侧对它只读,唯一需要改写结果的场景会走 `addSubToResult` 的深拷贝(`sublist.go:461-485`)。

**并发安全**:`Sublist` 内嵌 `sync.RWMutex`(`sublist.go:66`)。读缓存用 `RLock`;未命中后若启缓存则升级为**写锁**做整棵树遍历 + 写缓存,源码注释解释这是为避免 match 与 store 之间的竞争(`sublist.go:596-605`)——代价是并发 miss 会串行。`matches/cacheHits/genid/count` 走 atomic,统计读用 `atomic.LoadUint64`(`sublist.go:1101-1102`)。禁用缓存(`NoSublistCache`)时全程只需 RLock,这是高 churn 场景的逃生门(`sublist.go:111-114` 引用 issue #941,`126-134` 按服务器选项决定)。

## 4. 缓存失效语义:订阅修补、退订作废

- **Insert 时**(写锁内,`sublist.go:449-450`):调用 `addToCache` 后 `genid++`。`addToCache`(`sublist.go:490-506`)不整体失效:新订阅是字面量则查 L2 是否恰好有该 subject 的条目,有则**深拷贝追加**;是通配订阅则用 `matchLiteral` 扫全部缓存键,把命中条目逐一修补。所以线上热点 subject 的 L2 在订阅到来时依然可用,不会出现全量抖动。
- **Remove 时**(`sublist.go:915-918`):字面量退订直接 `delete(s.cache, subject)`;通配退订则删除所有被它命中的键(`sublist.go:510-525`)。退订选择"作废"而非"修补",因为从共享结果切片里摘除单个成员需要定位与搬移,作废后由下一次 Match 重建更简单。
- **RemoveBatch**(连接关闭,`client.go:6301` 调用):批量期间**整个关掉缓存**再重建空表(`sublist.go:946-961`),注释直言这是"quick and dirty"但测试证明最优。
- **权重更新**:`UpdateRemoteQSub` 对远端队列订阅改权重时,作废 L2 并 `genid++` 冲掉各连接 L1(`sublist.go:708-716`)。
- genid 是 L1 的"时代戳":任何 L2 层面的兴趣变化都 `atomic.AddUint64(&s.genid, 1)`(`sublist.go:450`、`917`、`958`、`714`),使所有连接的 L1 一轮内失效。

## 5. insert/remove 与 server 侧 sub 的对应

`Insert`(`sublist.go:368-458`)与 `remove`(`sublist.go:856-925`)逐 token 下行(用 `strings.SplitSeq` 零分配迭代),定位到叶节点后:

- 普通订阅:`n.psubs[sub]=struct{}{}`,首次出现记 `isnew`(供通知判断);`count++/inserts++`(`sublist.go:419-430`、`446-447`)。
- 队列订阅:懒建 `n.qsubs`,按 `string(sub.queue)` 入桶,新桶名才记 `isnew`(`sublist.go:431-444`)。
- 删除时 `removeFromNode` 返回 `(found, last)`(`sublist.go:1006-1033`);队列组以 `len(qsub)==0` 判定"最后一个兴趣",而非整个节点为空(`sublist.go:1026-1031`)。随后自底向上回收空节点:`levels` 栈记录路径,`isEmpty` 判空后 `pruneNode` 摘除(`sublist.go:869-870`、`909-914`、`965-988`)。
- server 侧一个 `subscription`(`client.go:647-664`,含 `subject/queue/sid/qw` 等字段)经 `c.subs[sid]` 登记(`client.go:3136` 调 `acc.sl.Insert`)进入某 account 的 sublist;客户端退订/断连经 `Remove`/`RemoveBatch` 精确移除。权限子系统的 allow/deny 各自也用一张 Sublist 做匹配(`client.go:1120`、`1133`)。
- 兴趣通知:`RegisterNotification` 只接受字面量 subject,首个兴趣出现发 `true`、全部消失发 `false`,内部维护 insert/remove 两个通知表并在 `chkForInsert/RemoveNotification` 间迁移(`sublist.go:154-221`、`315-365`)——这是 leafnode/系统账户做"按需订阅"的基石。发送用 `select+default` 非阻塞投递(`sublist.go:265-270`),阻塞风险由调用方保证。

### 5.1 反向匹配与冲突判定:sublist 的"配菜"算法

`sublist.go` 还承载了一组服务端配置校验用的匹配原语,它们不进消息热路径,但复用同一套 token 化思想:

- **`SubjectsCollide`**(`sublist.go:1341-1387`):判断两个(可含通配的)subject 是否可能同时命中同一条发布消息。两侧都字面量则直接字符串比较;一侧字面量走 `isSubsetMatchTokenized`;双侧带通配时先按 token 数与 `fwc` 位置快速排除,再逐 token 判 `tokensCanMatch`(`sublist.go:1329-1338`)。调用方:stream import 重叠校验(`accounts.go:1716`、`1776`)、订阅权限 deny 检查(`client.go:3439`)、JetStream filter 重叠检查(`jetstream_api.go:1826-1831`)等。
- **`SubjectMatchesFilter` / `isSubsetMatchTokenized`**(`sublist.go:1437-1445`、`1460-1495`):token 级子集匹配,`>` 吞掉一切剩余、`*` 只对 `*`,文档注释里给了 `foo.*` 是 `["<", "*.*", "foo.*"]` 子集的例子。
- **`ReverseMatch`**(`sublist.go:1665-1728`):方向对调——拿一个**通配**查询去树上找会被它命中的**字面量**订阅,典型用途是订阅权限检查:新 SUB 到来时用 `c.perms.sub.allow.ReverseMatch(subject)` 反查允许集(`client.go:3399`),`reverseMatchLevel` 遇查询中的 `>` 直接 `getAllNodes` 收割整个子树(`sublist.go:1694-1710`)。
- 小工具族:`numTokens`/`tokenAt`(1 基索引)/`tokenizeSubjectIntoSlice`(`sublist.go:1389-1433`),被 JetStream 与映射等模块复用。

## 6. 兴趣快速判定:Match 之前的"判空"通道

```go
// server/sublist.go:544-553
func (s *Sublist) HasInterest(subject string) bool {
	return s.hasInterest(subject, true, nil, nil)
}
func (s *Sublist) NumInterest(subject string) (np, nq int) {
	s.hasInterest(subject, true, &np, &nq)
	return
}
```

`hasInterest`(`sublist.go:636-684`)复用 L2 缓存,未命中走 `matchLevelForAny`(`sublist.go:798-846`):遇到 `fwc` 节点**立即返回 true**(`804-812`),不继续收集,比完整 Match 便宜。调用方遍布"只关心有没有兴趣"的路径:

- 发布主路径的短路:`len(r.psubs)+len(r.qsubs) > 0` 不满足则跳过全部投递(`client.go:4500-4514`)。
- `Account.Interest` 汇总 `NumInterest`(`accounts.go:1036-1045`);service import 回复清理前先 `HasInterest(reply)`(`accounts.go:2066`)。
- JetStream consumer 判断 deliver subject 是否有兴趣(`consumer.go:1466`、`2013`);gateway 回复路由(`gateway.go:2515`)。
- **gateway interest-only 模式**:两簇协商进入 `modeInterestOnly` 后不再传播订阅列表,发布时逐条查对端 account 的 sublist——`e.sl.MatchBytes(subj)` 决定是否转发(`gateway.go:107-110`、`2164-2200`)。这正是"兴趣统计必须精确"的极端体现:此时兴趣判定直接决定消息发不发。

## 7. 队列组:匹配层分桶、投递层选一

匹配层(`addNodeToResults`,`sublist.go:719-752`)把同一队列名的成员聚合进 `results.qsubs` 的同一个桶,`findQSlot` 线性比对桶首成员的 queue 名(`sublist.go:758-768`)。**权重语义**:来自 leaf/route 的远端队列订阅按 `sub.qw` 影子复制多次塞进桶里(`sublist.go:741-746`):

```go
// server/sublist.go:741-746
if isRemoteQSub(sub) {
	ns := atomic.LoadInt32(&sub.qw)
	// Shadow these subscriptions
	for n := 0; n < int(ns); n++ {
		results.qsubs[i] = append(results.qsubs[i], sub)
	}
}
```

投递层(`processMsgResults`,`client.go:5479-5660`)对每个桶选一个成员:

1. **队列过滤器**:协议层的 `$SYS`/服务调用场景可携带 `qf`(queue filter),桶名线性比对不命中则整桶跳过——源码注释解释"队列组通常很小,线性搜索比 map 更省更缓存友好"(`client.go:5451`、`5480-5493`)。
2. **随机起点**:`sindex = rand % lqs`(`client.go:5535-5539`),从随机下标环形遍历——这是纯随机负载均衡,影子副本使权重大的成员被选中概率正比于 `qw`;**没有**显式优先级或最少连接策略。
2. **来源偏好**:消息来自 ROUTER 时,先把桶过滤成"本地 CLIENT/JETSTREAM 等"成员,远端(ROUTE/LEAF)成员只留作兜底 `rsub`,多个 LEAF 候选间掷硬币(`client.go:5505-5533`,issue #6040);一般来源遇到 LEAF/ROUTER 目标则记录 `rsub` 后继续找本地成员(`client.go:5556-5594`),优先本簇/本地交付。
3. 选中即 `c.deliverMsg(...)` 单发一条(`client.go:5652`),失败会沿环形序列尝试下一个候选。若发布来自 gateway 启用场景且桶名需要回传远端簇(避免远端把同消息再投给同名队列组),会置 `pmrCollectQueueNames` 收集交付过的队列名(`client.go:4509-4511`、`5674-5676`),随 RMSG 协议帧带给对端。

权重的产生与传播:leafnode/route 协议的 SUB 帧携带队列权重参数并写入 `sub.qw`(`leafnode.go:2946`、`route.go:1590`);服务器聚合本簇兴趣后,`updateRouteSubscriptionMap` 在向其它 server 通告前把计数写进副本 `nsub.qw = n`(`route.go:2625-2636`);权重变化会触发 `UpdateRemoteQSub` 失效缓存(`leafnode.go:3039-3041`)。连接关闭时 LEAF 连接按 `num = sub.qw` 扣减聚合兴趣而非按 1(`client.go:6317-6331`)。

## 8. 统计指标

`SublistStats`(`sublist.go:1050-1063`)暴露:`NumSubs/NumInserts/NumRemoves`、`NumMatches`、`NumCache`、`CacheHitRate = cacheHits/NumMatches`(`sublist.go:1101-1105`)、`MaxFanout/AvgFanout`——fanout 靠**遍历整个 L2 缓存**统计每条目的 `len(psubs)+len(qsubs)`(`sublist.go:1109-1127`),注释提醒别高频调用。监控出口:`/varz` 的 subsz 聚合各 account 的 `sl.Stats()`(`monitor.go:1047-1068`),账户详情携带 `Sublist: a.sl.Stats()`(`monitor.go:2987`)。多 account 聚合时 `SublistStats.add` 重新由总量算比率,避免平均的平均(`sublist.go:1065-1086`)。

## 9. 性能设计:为什么不能"每条消息都遍历"

朴素实现 = 每条消息线性比对全部 N 个订阅 × T 个 token,O(N·T)。sublist 的三层递进:

1. **树遍历**:每层一次 map 查找 + 两个指针判断,代价只与**主题长度和分支**相关,与订阅总数解耦;切 token 用栈上 `[32]string` 零分配(`sublist.go:576-591`)。
2. **L2 共享缓存**:真实负载中发布 subject 高度重复,命中后整次匹配退化为一次 map 查找 + 一次原子计数;`emptyResult` 单例连空结果的分配都省了。
3. **L1 连接缓存**:`genid` 不变时连跨连接的锁与 L2 竞争都省掉(`client.go:4467-4469`)。

因此**缓存命中率是 NATS 吞吐的第一指标**(`CacheHitRate` 也因此在监控中一等公民)。失效侧的工程取舍同样围绕它:订阅用修补、退订用作废、批量退订干脆整表重建、权重更新只作废——各按"改动波及面"选择最小正确动作。若订阅变化极度频繁使修补/重建成本反超收益,可用 `NoSublistCache` 直接关掉 L2(`sublist.go:111-114`),让系统退回纯树遍历模式运行。

---

## 10. 设计动机

1. **两级缓存而非一级**:L1(每连接)消除热点连接的重复加锁,L2(每 account)在连接间共享结果;`genid` 时代戳让失效只需一个原子加法,不必逐连接通知——读路径 scalability 与失效正确性解耦。
2. **树而非哈希表**:通配订阅无法以 subject 全串为键;trie 让 `*` 成为"每层一个额外指针"、`>` 成为"每层一个哨兵节点",匹配复杂度只随主题长度增长,且字面量订阅的插入/删除天然按 token 定位,空节点回收可精确剪枝。
3. **`>` 只允许在尾部**:`>` 语义是"剩余全部层",若允许出现在中间,树每层都要为"匹配零或多层"做回溯,`matchLevel` 的线性递归结构(每 token 一次分派)就不成立;尾部限定使 `fwc` 检查退化为"进层时顺带看一眼常量指针",近零开销。
4. **队列组在匹配层聚合**:`qsubs [][]*subscription` 的桶结构使投递层拿到"每队列一个成员集合"而非混在一起的平铺列表,分桶一次完成;权重以影子副本表达,匹配结果自身就编码了选择概率,投递层只需随机下标,无需额外权重数据结构。
5. **兴趣统计必须精确**:gateway interest-only、JetStream deliver subject 判空、service import 回复清理都拿 `HasInterest` 的布尔结果直接决定"发不发/删不删";漏判丢消息,误判则退化为广播。这要求 insert/remove 维护的 `isnew/last`(以及队列组的 `len(qsub)==0`)在并发与权重语境下都严丝合缝。
6. **缓存失效动作按波及面分级**:订阅修补(保持热点命中)、单条退订作废(简单正确)、批量退订整表重建(实测最优)、权重更新仅作废——正确的粒度选择让高频 churn 不至于把命中率打穿;打穿时还有 `NoSublistCache` 的确定性退路。

## 11. 写作素材清单(文件:行号)

1. `server/sublist.go:32-39` — 通配符与分隔符常量
2. `server/sublist.go:87-99` — node/level 结构体(含 qsubs 二级分桶)
3. `server/sublist.go:49-56` — slCacheMax=1024 / slCacheSweep=256 / plistMin=256
4. `server/sublist.go:368-458` — Insert 全过程(校验、入树、plist、缓存修补、genid)
5. `server/sublist.go:490-525` — addToCache(修补)与 removeFromCache(作废)的不对称
6. `server/sublist.go:559-634` — match 主循环(缓存命中/树遍历/写锁升级/清扫触发)
7. `server/sublist.go:771-796` — matchLevel 递归遍历(fwc/pwc/字面量三分支)
8. `server/sublist.go:719-768` — addNodeToResults 与 qw 影子副本、findQSlot
9. `server/sublist.go:856-988` — remove、levels 剪枝栈、isEmpty/pruneNode
10. `server/sublist.go:933-963` — RemoveBatch 整表关缓存策略
11. `server/sublist.go:544-553, 798-846` — HasInterest/NumInterest 与 matchLevelForAny 快速判空
12. `server/sublist.go:1089-1129` — Stats():命中率与 fanout 统计
13. `server/sublist.go:1205-1246` — isValidSubject(`>` 尾部限定、空白符、空 token)
14. `server/client.go:4465-4494` — 连接级 L1 结果缓存与 genid 时代戳
15. `server/client.go:5479-5594` — 队列组分发:过滤、路由偏好、随机起点、rsub 兜底
16. `server/route.go:1590, 2625-2636` — 队列权重的协议解析与跨 server 传播
