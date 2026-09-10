# Raft 核心状态机(raft.go / doc.go)——源码深读报告

> 调研对象:etcd-io/raft @ commit `3cbf6a74`(2026-09-02,v3.7/3.8 世代)
> 核心文件:`raft.go`(2162 行)、`doc.go`(399 行,作者正式设计文档);辅证:`node.go`、`rawnode.go`、`log.go`、`tracker/`、`quorum/`、`raftpb/raft.proto`、`read_only.go`、`util.go`
> 所有结论均以 `文件:行号` 标注,行号为该 commit 下的实际行号。

---

## ① 全景:一个"状态机库",不是"共识服务"

`doc.go` 开篇即给这个包定位:它以 protobuf 格式收发消息,实现"用复制日志在多节点间维持复制状态机同步"的 Raft 协议(doc.go:16-22)。**它没有网络、没有磁盘、没有时钟**——这三样恰恰是一个共识服务最重的部分,全部留给宿主(etcd server、TiKV、CockroachDB 等):

- **网络**:库只把要发的消息 append 进 `r.msgs`(raft.go:364-368),由宿主通过 `Ready.Messages` 取走并经 rafthttp/TCP 发出;收到的包由宿主调 `Node.Step()` 送回(doc.go:110-114)。
- **磁盘**:库通过 `Storage` 接口读已持久化状态(doc.go:105-108),要写的条目/HardState 打包在 `Ready.Entries/HardState/Snapshot` 里交给宿主落盘(node.go:74-87);`MemoryStorage` 只是测试用的内存实现。
- **时钟**:时间被抽象成逻辑 tick,宿主定期调 `Node.Tick()`(doc.go:116-119);库内部只有 `electionElapsed`/`heartbeatElapsed` 两个计数器(raft.go:403-411),绝不碰真实时钟。

库与宿主的协议契约由 doc.go:69-104 正式规定,即著名的 **Ready 四步**:1)先把 HardState/Entries/Snapshot 写入持久存储,注意写 Index=i 的 entry 前必须丢弃所有已持久化的 ≥i 条目(doc.go:75-77);2)再发消息,且**必须等最新 HardState 落盘后才能发消息**,同批内消息可与 entry 持久化并行(doc.go:79-86,并点名论文 §10.2.1 的 leader 并行落盘优化);3)apply 快照与 CommittedEntries,`EntryConfChange` 类型必须回喂 `ApplyConfChange`(doc.go:93-99);4)调 `Advance()` 释放下一批(doc.go:101-103)。doc.go:121-145 给出了 select 三路(Ticker/Ready/done)的参考主循环。

`Ready` 结构本体在 node.go:52-115,分 `SoftState`(lead、角色,易失,node.go:40-47)与 `HardState`(Term/Vote/Commit,必须持久化)两个层级——这正是 Raft "选期与投票要落盘、其余可丢"的工程投影。

**与"论文 Raft"的差异**,doc.go 有两处官方声明:其一,实现已与 Ongaro 博士论文最终版对齐,但**成员变更与论文第 4 章不同**——变更在 entry 被 apply 时生效而非进入日志时生效,因此以旧配置提交(doc.go:262-270);为防两条未提交变更被同一 quorum 混合提交,库强制**同时只允许一条 pending 的配置变更**(doc.go:272-276,机制是 `pendingConfIndex`,raft.go:386-392、raft.go:1326-1343)。其二,从两节点集群摘除一个节点会死锁(死一个就再也无法凑齐提交),所以官方建议集群至少三节点(doc.go:278-283)。

在此之上,实现比论文多出一组带开关的工程扩展,本章聚焦前四项:

| 扩展 | 代码锚点 | 来源 |
|---|---|---|
| PreVote 两阶段选举 | `Config.PreVote`(raft.go:228-231),MsgPreVote/MsgPreVoteResp(doc.go:348-352) | 论文 §9.6 |
| CheckQuorum(leader 主动步降) | `Config.CheckQuorum`(raft.go:224-226),MsgCheckQuorum 处理(raft.go:1281-1293) | 论文 §6.4/§9.6 |
| Leader lease(选举租约读) | `inLease` 拦截(raft.go:1101-1112),ReadOnlyLeaseBased(raft.go:64-69) | 论文 §6.3 |
| Learner 只读成员 | `isLearner`(raft.go:361-362),`promotable()`(raft.go:1944-1949) | 工程扩展 |

理解这个状态机的钥匙在 `raft` 结构体(raft.go:343-437)的三组字段:① 协议状态 `Term/Vote/state/lead`(raft.go:346-359);② 日志与进度 `raftLog`/`trk tracker.ProgressTracker`(raft.go:352-357);③ **两个函数指针 `tick func()` 与 `step stepFunc`**(raft.go:425-426)。角色切换的实质就是换这两个指针:每个 become* 函数只做"绑指针 + 重置状态"两件事,而消息处理逻辑天然按角色分派——没有一坨 if-state,这是全文最核心的设计。

另外注意两个消息队列的语义区分:`msgs` 是可立即发出的消息;`msgsAfterAppend` 存放 **MsgAppResp/MsgVoteResp/MsgPreVoteResp** 这三类"以未落盘状态为前提"的响应,必须等当前不稳定状态(Term/Vote/entry)持久化后才能发出(raft.go:369-379、raft.go:546-592)。这一点在 ⑤ 详述。

---

## ② 状态机逐段解读:四个角色与四次变轨

### 2.1 三(四)状态转移图

状态常量有四个:StateFollower/StateCandidate/StateLeader/StatePreCandidate(raft.go:50-56)。PreCandidate 是 PreVote 开启时的"零成本试探态",不占用 Term,所以可视为论文三角色外的第四态:

```
                 MsgHup(选举超时) / MsgTimeoutNow(领导权转移)
      ┌──────────┐ ─────────────────────────────────────► ┌───────────┐
      │ Follower │                                        │ Candidate │
      └────┬─────┘ ◄───────────────────────────────────── └─────┬─────┘
           │   ▲          收到更高/同 term 的 MsgApp、            │
           │   │          MsgHeartbeat、MsgSnap:                │
           │   │          becomeFollower(m.Term, m.From)        │ 赢得多数票
           │   │          (stepCandidate, raft.go:1687-1695)     │ VoteWon
           │   │                                                ▼
           │   │                                          ┌───────────┐
           │   │      QuorumActive()==false                │  Leader   │
           │   ├────(CheckQuorum, raft.go:1282-1285)────── └─────┬─────┘
           │   │      选举失败 VoteLost(raft.go:1710)            │
           │   └────────────────────────────────────────────────┤
           │                                                    │
           │    [PreVote 路径, raft.go:1033-1042]                │
           │    Follower ──MsgHup──► PreCandidate(不动 Term/Vote,│
           │               raft.go:917-931)                     │
           │    PreCandidate ──赢得 PreVote──► Candidate(此刻才  │
           │               Term+1)                              │
           └────────────── 收到 MsgApp/MsgHeartbeat ─────────────┘
```

底层公共操作是 `reset(term)`(raft.go:781-810):Term 变化时清空 Vote(782-785)、清 lead、双计数器归零并重掷随机选举超时(788-790)、中止领导权转移(792)、清空计票 `ResetVotes`(794)、把每个 peer 的 Progress 归零为 `Next=lastIndex+1, Match=0`(仅自己的 Match 设为 lastIndex,795-805)、清 pendingConfIndex 与 uncommittedSize、重建 readOnly(807-809)。`reset` 之所以在每个变轨函数里都调用,是因为无论当选、降级还是连任,**复制进度与计票状态都只对"当前 Term 的 leader"有意义**——换 Term 即作废,连任(becomeLeader 里 `reset(r.Term)`)则是刻意保留 Term、只重建进度表的"软重启"。

启动路径也值得走一遍(`newRaft`,raft.go:439-498):校验 Config → 用 Storage 构建 raftLog 并读出 `InitialState()`(HardState 与 ConfState,443-447)→ 以持久化的 ConfState 调 `confchange.Restore` 重建 ProgressTracker(471-479)→ `loadState` 装载 Term/Vote/committed(481-483)→ 若配置了 `Applied` 则标记应用位,防止重启后向应用重放已 apply 的条目(484-486,对应 Config.Applied,raft.go:147-151)→ 最后 `becomeFollower(r.Term, None)`(487):**任何节点都以 follower 身份醒来**,这是 Raft"无消息即无领导"的自然推论。

### 2.2 becomeFollower(raft.go:891-900)

行为清单:绑 `stepFollower` → `reset(term)` → 绑 `tickElection` → 记录 lead → 置 state。它是唯一显式接收 `lead` 参数的变轨:收到有效 leader 消息时传 `m.From`(如 raft.go:1127),因更高 Term 被动降级但不知谁当选时传 `None`(raft.go:1129)。`newRaft` 启动时也以 `becomeFollower(Term, None)` 收尾(raft.go:487)。

### 2.3 becomeCandidate(raft.go:902-915)

行为清单:断言非 Leader(Leader→Candidate 是非法转移,panic,903-906)→ `reset(Term+1)`(**这里才真正递增 Term**)→ 绑 tickElection → **自投票** `r.Vote = r.id`(910)→ 置 state。自投票只写了 `r.Vote` 字段,计票则通过 campaign 里发给自己的伪响应完成(见 2.6)。

### 2.4 becomePreCandidate(raft.go:917-931)

行为清单:断言非 Leader → 绑 `stepCandidate`(**与真 candidate 共用**)→ `ResetVotes()` → 绑 tickElection → 清 lead → 置 state。注释明说:**不改 Term、不改 Vote**(923-925)。这正是 PreVote 的精髓:试探性拉票不产生任何持久化副作用,失败时集群 Term 完全不动。计票响应类型靠 `r.state` 区分(raft.go:1677-1682)。

### 2.5 becomeLeader(raft.go:933-971)

行为清单(按序):

1. 断言非 Follower——**"follower → leader"是非法转移**(935-937),因为必须先经 candidate 且拿到 quorum;
2. 绑 `stepLeader`、`reset(Term)`(term 不变)、绑 `tickHeartbeat`(938-940);
3. `lead = r.id`,置 state(941-942);
4. 把自己的 Progress 置为 `StateReplicate`(reset 时已把 Match 初始化为 lastIndex,947-948),并置 `RecentActive = true`(951,CheckQuorum 语义下 leader 永远算活跃);
5. **保守地把 `pendingConfIndex` 设为 lastIndex**(953-958):新 leader 无从知晓日志尾部是否藏有未提交的配置变更,宁可延迟新提案也要保证单条 pending 约束;
6. **append 一条空 entry**(`Data: nil`,961-965)——即 noop/blank entry,动机见 ⑤.1。注意空 entry 的 payloadSize 为 0,不占用 uncommitted 配额(966-969)。

### 2.6 promotable 与 hup / campaign

`promotable()`(raft.go:1944-1949):自己的 ID 在 Progress 表中、不是 learner、且没有进行中的快照——三者同时成立才允许发起选举。learner 被明确禁止 campaign(hup 里拒掉,raft.go:979-982)。

`hup(t)`(raft.go:973-990):MsgHup 的统一入口。Leader 忽略(974-977);不可晋升忽略;**存在未 apply 的配置变更时拒绝发起选举**(983-986,`hasUnappliedConfChanges` 分页扫描 applied 与 committed 之间的条目找 EntryConfChange,raft.go:995-1021)——这防止了新旧成员视图下的混乱选举。

`campaign(t)`(raft.go:1025-1073):PreVote 分支走 `becomePreCandidate` + 发 `MsgPreVote`、term 取 `r.Term+1`(1033-1037,预投票携带的是"未来 term",不落盘);否则 `becomeCandidate` + 发 `MsgVote`、term 取当前。随后对**排序后的** voter ID 列表发拉票消息,携带自己的日志末端 `(index, LogTerm)`(1063-1071),`campaignTransfer` 用 Context 标记(1067-1070)。对 voter 列表先排序(slices.Sort,1050)再遍历,保证了多节点日志顺序的确定性,也便于测试回放对账。关键细节:**发给自己的一票也走 `send()`**,即以 `voteRespMsgType` 形式进入 `msgsAfterAppend`(1052-1060)——自投票同样必须等 Term/Vote 持久化后才计入,这与"同一 Term 不得投两票"的持久化要求严格对齐。计票本身委托给 `poll → RecordVote/TallyVotes`(raft.go:1075-1083):同一 voter 只记首票(tracker.go:251-256),learner 不入册(tracker.go:265-278),胜负判定复用 quorum 包的 `VoteResult`(Won/Lost/Pending 三值,quorum/quorum.go:51-57),joint config 下的双多数要求由 quorum 层统一表达,raft.go 完全不感知。

---

## ③ Step 消息分发表:一扇门,两层分发

`Step` 是唯一入口(raft.go:1089)。分发是两层的:**第一层按 Term 比较**做安全闸(1097-1187),**第二层按消息类型**分派(1189-1269,`default` 再进入当前角色的 `r.step`,1264-1269)。raft.proto:32-60 枚举了全部 24 种消息类型。

### 3.1 第一层:Term 闸门

- `m.Term == 0`:本地消息(MsgHup/MsgBeat/MsgProp 等不带 Term,见 ⑤.4),直接放行(1098-1099)。
- `m.Term > r.Term`:若来的是 MsgVote/MsgPreVote,先查**选举租约**:`force = Context=="CampaignTransfer"`,`inLease = checkQuorum && lead!=None && electionElapsed < electionTimeout`,在租约期内直接忽略拉票(不改 Term、不投票,1101-1112)。随后:MsgPreVote 永远不更新本地 Term(1115-1116);已授权的 MsgPreVoteResp 也不更新(1117-1122,拒绝的才会以其 Term 降级);其余类型一律 `becomeFollower` 降级——MsgApp/MsgHeartbeat/MsgSnap 顺带记录 `m.From` 为新 leader,其他消息(如 MsgVote)不知道谁当选,传 None(1123-1131)。
- `m.Term < r.Term`:默认忽略;但三个特例(1133-1187):① 开了 CheckQuorum 或 PreVote 时,收到过期 leader 的 MsgHeartbeat/MsgApp,回一条 `MsgAppResp`(send 时会盖上本地更高 Term,raft.go:542-543)——用响应把新 Term"告诉"老 leader 逼它步降(注释详述了隔离节点回归场景,1134-1156);② 过期 MsgPreVote 回 Reject(r.Term,1157-1165,注释解释了不开 PreVote 的旧集群升级后可能死锁);③ MsgStorageAppendResp 的快照部分仍然生效(快照携带的是 term 无关的已提交状态,1175-1180)。

### 3.2 第二层:公共类型(在 Step 里处理,不走角色函数)

| 消息 | 处理 | 锚点 |
|---|---|---|
| MsgHup | 触发 hup(按 preVote 选 Pre/Election 两种 campaign) | raft.go:1190-1195 |
| MsgVote/MsgPreVote | 投票裁决(下表详述) | raft.go:1212-1262 |
| MsgStorageAppendResp / MsgStorageApplyResp | AsyncStorageWrites 模式的本地回执:stableTo/appliedTo | raft.go:1197-1210 |

**投票裁决**的完整条件(raft.go:1213-1222):可投 = (重复投同一人)∨(本 Term 未投且认为无 leader:`Vote==None && lead==None`)∨(PreVote 且消息 Term 更高);**且**候选人日志 `isUpToDate`(先比最后条目 Term,再比 Index,log.go:442-445)。三个精妙点:① learner 必须被允许投票——刚被提升为 voter 的节点可能还没收到配置 entry,只有通过"被请求投票"它才能意识到自己已是 voter(1223-1240 的长注释含完整反例);② **响应携带 `m.Term` 而非本地 Term**(1243-1252):PreVote 用未来 Term 拉票,若响应盖本地旧 Term 会被对方当作过期消息丢弃;③ 只有真 MsgVote 才记录 `r.Vote` 并清 electionElapsed,PreVote 不产生持久化痕迹(1253-1257)。拒绝时才用本地 Term(1258-1261)。

### 3.3 角色层分发表

| 消息 | stepLeader(raft.go:1275-1669) | stepCandidate(1671-1716) | stepFollower(1718-1779) |
|---|---|---|---|
| MsgProp | 校验(非空/是成员/无进行中转移)→ 配置变更合法性检查 → `appendEntry` + `bcastAppend`(1294-1353) | 直接丢,返回 ErrProposalDropped(1684-1686) | 转发给 lead;`disableProposalForwarding` 或无 lead 则丢(1720-1729) |
| MsgApp | —(需 Progress) | **降级为 Follower** 再 handleAppendEntries(1687-1689) | `electionElapsed=0`、记 lead、handleAppendEntries(1730-1733) |
| MsgHeartbeat | — | 降级 + handleHeartbeat(1690-1692) | 同上(1734-1737) |
| MsgSnap | — | 降级 + handleSnapshot(1693-1695) | 同上(1738-1741) |
| MsgAppResp | 复制进度推进/回退 + maybeCommit 联动(见 3.4) | — | — |
| MsgHeartbeatResp | 置 RecentActive、解除 MsgAppFlowPaused、按需补发 MsgApp;ReadIndex ack(1579-1610) | — | — |
| MsgBeat | `bcastHeartbeat()`(1278-1280) | — | — |
| MsgCheckQuorum | quorum 不活跃 → becomeFollower 步降;然后把除己之外所有人 RecentActive=false(1281-1293) | — | — |
| MsgSnapStatus | 快照成功/失败 → BecomeProbe;MsgAppFlowPaused=true(1611-1628) | — | — |
| MsgUnreachable | StateReplicate → BecomeProbe(1629-1635) | — | — |
| MsgTransferLeader | 校验非 learner/非自指 → 记 leadTransferee → 日志已追平则立即 sendTimeoutNow,否则 sendAppend 加速(1636-1666) | — | 无 lead 丢弃,否则转发给 lead(1742-1748) |
| MsgVoteResp / MsgPreVoteResp | — | poll 计票:VoteWon→PreCandidate 升格 campaign(Election)/Candidate 升格 becomeLeader+bcastAppend;VoteLost→becomeFollower(1696-1711) | — |
| MsgTimeoutNow | — | 忽略(1712-1713) | **绕过 PreVote** 直接 hup(campaignTransfer)(1758-1763) |
| MsgReadIndex | 单成员直接答复;本 Term 尚无 commit 则挂起 pendingReadIndexMessages;否则走 readOnly(1354-1372) | — | 转发给 lead(1764-1770) |
| MsgReadIndexResp | — | — | 存入 readStates(1771-1777) |
| MsgForgetLeader | noop(1373-1374) | — | 清 lead(LeaseBased 下拒绝,1749-1757) |

### 3.4 append 处理:track 与 maybeCommit 的联动(Leader 侧)

发送端 `maybeSendAppend`(raft.go:618-662):Progress 处于 paused(IsPaused,progress.go:262-273)则不发;取 `prevIndex = pr.Next-1` 的 Term 失败则降级发快照(626-629);throttled 的 StateReplicate 只发空 MsgApp 以防 Inflights 全丢导致卡死(633-641);发出的 MsgApp 携带 `Commit=r.raftLog.committed`(651-658)。

接收端 `handleAppendEntries`(raft.go:1791-1833)三岔:`prev.index < committed` 直接回 MsgAppResp(committed)(1796-1799);`maybeAppend`(log.go:109-131:matchTerm 前缀校验 → findConflict 找冲突点 → 截断重append 冲突尾 → `commitTo(min(m.Commit, lastnewi))`)成功回 MsgAppResp(lastnewi)(1800-1802);失败则回 reject,并用 `findConflictByTerm` 在**双方日志上**做二分式探测优化(raft.go:1390-1510 有两大段图文注释,leader 侧按自身 term 表收缩探测区间,1509;follower 侧同样回跳,1823-1832),把 O(分歧长度) 次往返压到 O(分歧 term 数)。

回执端(Leader 收 MsgAppResp,raft.go:1384-1578)是 track 与 commit 的联动核心:

```go
if pr.MaybeUpdate(m.GetIndex()) || (pr.Match == m.GetIndex() && pr.State == tracker.StateProbe) {
    switch {
    case pr.State == tracker.StateProbe:      pr.BecomeReplicate()
    case pr.State == tracker.StateSnapshot && pr.Match+1 >= r.raftLog.firstIndex():
        pr.BecomeProbe(); pr.BecomeReplicate()
    case pr.State == tracker.StateReplicate:  pr.Inflights.FreeLE(m.GetIndex())
    }
    if r.maybeCommit() { releasePendingReadIndexMessages(r); r.bcastAppend() }
    ...
}
```

`maybeCommit`(raft.go:775-779)取 `trk.Committed()`——即**所有 voter 的 Match 组成的 quorum 中位数**(`Voters.CommittedIndex`,tracker.go:177-181)——再要求该位置 matchTerm 且大于当前 committed 才前移(log.go:455-464)。commit 前移后:释放被挂起的 ReadIndex 请求(本 Term 首个 commit 才能答复 ReadIndex,见 ⑤.1)、bcastAppend 广播新 commit;commit 未前移时也可能向落后 follower 单发 commit(`CanBumpCommit`,raft.go:1555-1560);最后按流控窗口连发多条 MsgApp(1568-1571);若响应来自 leadTransferee 且已追平,立即 sendTimeoutNow 完成转移(1572-1576)。

这里隐含着一台**Progress 三态小状态机**(progress.go,tracker/ 子目录),它是 leader 对每个 follower 的复制视角,与 raft 主状态机正交:

- **StateProbe**:摸索期,一次只发一条 MsgApp,收到确认前暂停(`MsgAppFlowPaused`),`Next` 逐次回退(130-143、175-181);
- **StateReplicate**:顺流期,流水线全速发送,Inflights 滑窗限流(101-113、167-174),确认后 `FreeLE` 释放窗口(1546-1547);
- **StateSnapshot**:日志被压缩追不上时发快照,期间完全停发 IsPaused 恒真(153-158、262-273),快照结果经 MsgSnapStatus 收尾(1611-1628)。

三态迁移的触发点全部落在 stepLeader 的 MsgAppResp 分支(1528-1548):probe 收到确认升 replicate;replicate 收到拒绝降 probe(1511-1517);snapshot 收到确认且快照点已进入日志范围时,经 probe 过渡回 replicate(1531-1545,注释解释为何要途经 probe)。`MaybeUpdate`(progress.go:205-213)与 `MaybeDecrTo`(226-254)分别以"乱序响应防倒退"的守卫承载升与降。

---

## ④ tick 的两个节拍与 electionTimeout 随机化

库不感知时间,宿主每个时间片调一次 `Tick()`,内部按角色绑定的 tick 函数走:

**tickElection(Follower/Candidate,raft.go:850-859)**:每拍 `electionElapsed++`;`promotable() && pastElectionTimeout()` 时清零计数并向自己 Step 一条 **MsgHup**(855)——选举超时到点即自触发拉票。candidate 也会继续走这条路:失败后再拉就是"反复选举"。

**tickHeartbeat(Leader,raft.go:862-889)**:每拍 `heartbeatElapsed++` 与 `electionElapsed++` **双计数**。electionElapsed 达到 `electionTimeout` 时(注意:**CheckQuorum 的检查周期是 electionTimeout 而非 heartbeatTimeout**,866-872):有 checkQuorum 则 Step(MsgCheckQuorum);若领导权转移在一个 electionTimeout 内没完成则 abort(874-876)。随后若此时已不是 leader(可能刚被 MsgCheckQuorum 降级)直接返回(879-881)。heartbeatElapsed 达到 `heartbeatTimeout` 时 Step(**MsgBeat**),stepLeader 收到即 `bcastHeartbeat`(1278-1280)。

**随机化**(raft.go:2046-2055):`randomizedElectionTimeout = electionTimeout + Intn(electionTimeout)`,即落在 `[E, 2E-1]` 区间,每次 reset 状态(reset,raft.go:790)时重掷,`pastElectionTimeout` 即 `electionElapsed >= randomizedElectionTimeout`(2049-2051)。这消除了多节点同时拉票的活锁。两个工程细节:① 随机源是包装了互斥锁的 `lockedRand`,底层用 `crypto/rand`——**多个 raft group 共享进程级 globalRand 时线程安全**(raft.go:90-104);② Config.validate 强制 `ElectionTick > HeartbeatTick` 并建议 10 倍关系(raft.go:130-136、305-307),即心跳频率是选举超时的 10 倍,留给网络抖动足够余量。

心跳的作用在 follower 侧只是**续约**:`electionElapsed = 0`(raft.go:1730-1741),外加把心跳携带的 commit 应用到本地日志(`handleHeartbeat`,raft.go:1835-1838)。而心跳里的 commit 是 `min(pr.Match, r.raftLog.committed)`(raft.go:694-710)——绝不能把 follower 还没复制到的 commit 告诉它。

两个容易被忽略的工程细节:其一,**MsgBeat 是 leader 发给自己的内部消息**(doc.go:301-304),它与网络消息共用 Step 通道,好处是心跳发送与所有其他事件共享同一条单线程序列化路径,不需要额外的并发保护;真正的 MsgHeartbeat 由 `bcastHeartbeat`(raft.go:724-735)逐个 peer 构造,并把 ReadIndex 的确认上下文(`heartbeatCtx`,read_only.go:93-101)捎带在 Context 字段里——**一次心跳广播同时承担了 leadership 续约、commit 通告与 ReadIndex 确认三种职责**,这是消息复用的典范。其二,`RawNode` 还提供 `TickQuiesced()`(rawnode.go:78):在无任何待处理事件的静默期跳过 tick 的开销,配合 etcd server 的 quiesce 机制降低空闲集群的 CPU 与网络噪声(库侧仅提供入口,静默判定在宿主)。

---

## ⑤ 设计动机与取舍

### 5.1 为什么 becomeLeader 要 append 一条 noop

raft.go:961-965。动机有三层:① **commit index 只能通过当前 Term 的 entry 提交来推进**——新 leader 在本 Term 没提交任何条目前,无法安全地广播 commit(论文 §5.4.2 的 commit 前向安全问题);空 entry 让 commit 立即可用,避免上一 Term 的条目"卡"在 quorum 已复制却不能宣告提交的状态。② ReadIndex 依赖它:leader 收到 MsgReadIndex 时,若 `!committedEntryInCurrentTerm()` 必须**挂起**该请求(raft.go:1363-1368、2065-2070、2127-2144),等本 Term 首个 commit 出现才答复——noop entry 让这个等待窗口最短。③ 配置变更也不能在本 Term 无 commit 时提交。代价是每次选举多一条日志与一次 fsync,这是用小额写放大换协议正确性与读线性一致性的标准取舍。另外空 entry 的 payloadSize=0,特意不算入 uncommittedSize 配额(raft.go:966-969、2098-2112)。

### 5.2 为什么 PreVote:被隔离者的"复仇性 Term"

没有 PreVote 时:一个被隔离的 follower 会不断选举失败、Term 一路膨胀;恢复网络后,它的高 Term 拉票会迫使整个集群无条件升 Term 并打断现任 leader(注释原文,raft.go:1150-1155)。PreVote 把"试探"与"正式选举"分离:试探阶段不动 Term(raft.go:917-931、1115-1116),只有确认"这一票大概率能赢"(拿到 quorum 预授权)才真正 Term+1 进入 candidate。Step 里的另一处配套防守:开启了 CheckQuorum/PreVote 的 follower,在租约期内收到过期 leader 的心跳时回一个**盖了本地高 Term 的 MsgAppResp**(1134-1156),让孤悬的旧 leader 快速知道自己已失格,而不是靠下一次拉票才能发现。开销是多一轮 RPC 延迟选举;收益是分区回归对集群零扰动。

### 5.3 CheckQuorum 的代价

MsgCheckQuorum 处理(raft.go:1281-1293)逻辑极简:`!trk.QuorumActive()`(tracker.go:206-218,即 RecentActive 集合里凑不齐 quorum)就 becomeFollower;然后把除自己外所有人 `RecentActive=false`,等下一个周期重新点亮。RecentActive 的点亮点只有两处:leader 收到 MsgAppResp(1388)或 MsgHeartbeatResp(1580)。代价与微妙之处:① **leader 主动退位会引入不必要的重选举**——若 leader 自己是 quorum 中唯一存活的(多数派故障),它退位后集群反正无法选出新 leader,只是平白多一次选举日志;② 它与选举租约耦合:`inLease` 的前提就是 checkQuorum(1103),这也是 `ReadOnlyLeaseBased` 强制要求开启 CheckQuorum 的原因(validate,raft.go:336-338)——lease 的正确性依赖"失联即让位"的活性保证;③ RecentActive 是按检查周期清零的**有界窗口**,而非滑动窗口,周期粒度是 electionTimeout(866-872),因此判活下限就是一整个 electionTimeout。

### 5.4 持久化次序:msgsAfterAppend 的保守设计

`send()` 把 MsgAppResp/MsgVoteResp/MsgPreVoteResp 三类响应放入 `msgsAfterAppend`(raft.go:546-592),注释整段引用论文 §3.8:投过票、确认过 append 都必须先落盘。妙处在 self-message:leader append 后给自己发 MsgAppResp(835-845)、candidate 给自己发 VoteResp(1052-1060),让"自确认"与"发给他人的响应"走同一条持久化栅栏,不需要任何特判。连**拒绝响应**也一并排队——注释承认 reject 大概率可以立即发,但未经形式化验证,宁可保守(raft.go:580-591)。这是整份代码"安全优先于延迟"风格的缩影。发送时 Term 的纪律同样严格:除 MsgProp/MsgReadIndex 外必须盖本地 Term;五类投票消息必须带 Term,其余带 Term 直接 panic(raft.go:518-544)。

### 5.5 两级写放大防线:Inflights 流控与 uncommitted 配额

etcd raft 在"leader 不被单个慢 follower 拖垮"上做了两级防护,都在 raft.go 的 Config 里:

- **在途消息窗口**:`MaxInflightMsgs` 限制每个 follower 未确认的 MsgApp 数量(raft.go:207-212),`MaxInflightBytes` 限制在途字节数并附有 Little's law 的量化注释——RTT 100ms、窗口 1MB 时吞吐上限即 10MB/s(raft.go:213-222)。Inflights 在 StateReplicate 下占满即 `IsPaused`,只发空 MsgApp 保活(raft.go:633-641 的注释详述了"全丢时靠心跳响应解卡"的自愈路径)。
- **未提交日志配额**:`MaxUncommittedEntriesSize` 限制 leader 日志中未提交尾部的总字节,超限直接丢弃提案并返回 ErrProposalDropped(raft.go:202-206、822-829、2098-2112)。动机注释写得很清楚:防止一台刚加入、尚在追赶快照的 learner 无限拉长 leader 日志(raft.go:396-399)。`reduceUncommittedSize` 在条目 apply 时回补配额(raft.go:2114-2125,且对欠账做饱和归零)。

两者的取舍方向一致:**宁可让客户端的提案失败(可重试),也不让 leader 的内存与恢复成本无界**。ErrProposalDropped(raft.go:88)正是为此暴露给上层的失败信号,配合 Node.Propose 让调用方 fail fast。

---

## ⑥ FAQ

**Q1:MsgProp 为什么不带 Term?**
它是"转发给 leader 的本地提案"而非共识消息:send 特意不盖 Term(raft.go:538-544),follower 收到后填 `m.To=r.lead` 原样转发(raft.go:1720-1729);Term=0 使它天然通过 Step 的本地消息通道(1098-1099)。

**Q2:candidate 收到同 Term 的 MsgApp 会怎样?**
立刻 `becomeFollower(m.Term, m.From)` 再处理 append(raft.go:1687-1689)。同 Term 存在 leader 说明本次选举已败,主动让位,不浪费一轮超时。

**Q3:leader 如何确认自己写下的 entry?**
它不发 MsgApp 给自己,而是 append 后**给自己回一条 MsgAppResp**(raft.go:845),进入 msgsAfterAppend,等 entries 落盘后回环到 stepLeader 的 MsgAppResp 分支完成 Match 自增与 maybeCommit——self-ack 与普通 ack 共用一条路径。

**Q4:follower 收到更小 Term 的心跳为什么回 MsgAppResp?**
这是"Term 反击":响应经 send 盖上本地更高 Term,老 leader 收到后走 Step 的降级分支退位(raft.go:1134-1156)。比发一条新消息类型更省:复用既有处理路径。

**Q5:learner 能投票吗?能发起选举吗?**
能投票、不能竞选。投票是因为刚提升的 voter 可能还不知道自己已是 voter,只能靠"被请求投票"参选(raft.go:1223-1240);竞选被 `promotable()` 的 `!pr.IsLearner` 挡住(raft.go:1944-1949),hup 与 campaign 双重拦截(979-982、1026-1030)。

**Q6:新 leader 为什么把 pendingConfIndex 设成 lastIndex?**
无从判断日志尾部是否藏着未提交的配置变更,保守延迟一切新配置提案直到旧变更 apply(raft.go:953-958)。代价是新 leader 短暂拒绝 ConfChange,收益是"单条 pending"不变量无条件成立。

**Q7:选举失败(candidate 计到多数反对)为什么是 becomeFollower(r.Term, None) 而不是 Term-1?**
Term 只增不减是 Raft 不变量;且 PreVoteResp 的 m.Term 是未来 Term 不能用,注释明说"reuse r.Term"(raft.go:1707-1710)。保持高 Term 还能防止再次收到同批过期拉票。

**Q8:心跳携带的 commit 为什么取 min(pr.Match, committed)?**
commit 是"多数已复制"的谓词,follower 自身 Match 之下的前缀才保证最终会被它拥有;多发只会诱导 follower commit 到一条未来可能被覆盖的位置(raft.go:694-710)。

**Q9:ReadIndex 请求什么时候会被 leader 挂起?**
本 Term 尚无已提交条目时(raft.go:1363-1368),挂进 pendingReadIndexMessages,由 maybeCommit 成功后的 releasePendingReadIndexMessages 统一释放(raft.go:1550-1554、2127-2144)。单成员集群例外,直接答复(1354-1361)。

**Q10:领导权转移为什么不走 PreVote?**
MsgTimeoutNow 到达即 `hup(campaignTransfer)`,注释:转移场景下我们确知不是分区回归,没必要多一跳(raft.go:1758-1763)。转移由 leader 主动 sendTimeoutNow(追平后,1572-1576 或 1661-1663),一个 electionTimeout 内未完成即 abort(874-876)。

---

## ⑦ 深挖问题(供下一层调研)

1. **msgsAfterAppend 与 AsyncStorageWrites 的复合时序**。同步模式下"响应等待本批 unstable 落盘"由 Ready/Advance 隐式保证;异步模式下该栅栏被显式编码进 MsgStorageAppend 携带的响应列表(doc.go:187-198、raft.go:546-559)。问题:当一批 MsgStorageAppend 尚在途、又来了新的 append(同 Term 重叠截断)时,`newStorageAppendResp` 如何防止旧响应把被覆盖的 entry 标记为 stable(raft.go:1166-1174 的注释暗示了这个 race,细节需读 log_unstable.go)?

2. **findConflictByTerm 双端优化的完备性**。leader 侧(raft.go:1404-1510)与 follower 侧(1823-1832)各自把探测次数压到"分歧内的 term 数",但两端的 hint 合成路径(MaybeDecrTo 的 `max(min(rejected, matchHint+1), pr.Match+1)`,progress.go:249)在乱序/重复 reject 下是否保持单调收敛,值得用模型检验(tla/ 目录已有 TLA+ 规约可对照)。

3. **CheckQuorum 周期内的"假死"误判**。RecentActive 只由两类响应点亮,若运输层批量丢 MsgHeartbeatResp 但 MsgApp 正常送达(反向链路拥塞),leader 会在 electionTimeout 边界误步降。etcd server 层是否有补偿(如 heartbeat resp 与 app resp 的对账)是跨层问题。

4. **`switchToConfig` 后的计票一致性**。配置变更会整体重建 Progress 表(raft.go:1979-1985),而 `Votes` 表的 key 是旧配置下的 voter ID;`TallyVotes` 对已不在配置中的 ID 仍然计数(tracker.go:258-279 特意保留 informational 计数)。处于 joint config 中途的 leader 换届时,预投/正式票跨配置的残留票是否可能凑出错误的 quorum 判定,值得专项测试(raft_test.go 中应有对应用例可查)。

5. **随机选举超时的均匀性与 crypto/rand 成本**。`resetRandomizedElectionTimeout` 每次变轨都掷 `crypto/rand`(raft.go:2053-2055,全局锁),在大规模 multi-raft(数千 group × 高频选举)下锁竞争与系统调用开销是否可观测,etcd server 是否换用了无锁实现值得对读(该库保留 lockedRand 抽象正是为了允许替换)。

---

*完。*
