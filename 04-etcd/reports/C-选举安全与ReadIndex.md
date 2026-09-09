# C 章:选举安全性、成员变更与线性一致读(etcd/raft 源码深读)

> 调研对象:etcd-io/raft @ 3cbf6a74(2026-09-02)。所有结论均以 `文件:行号` 标注,行号以该 commit 为准。

---

## ① 全景:安全性不变量清单

etcd/raft 把"安全性"拆解为一组可以在代码中逐一指认的不变量。下表是本章涉及的全部不变量及其代码锚点:

| # | 不变量 | 代码锚点 |
|---|--------|---------|
| I1 | 一个节点在一个 Term 内只投一票(内存态:`RecordVote` 首票生效;持久态:`HardState.Vote`) | `tracker/tracker.go:251-256`、`raft.go:504-510`、`raft.go:1253-1257` |
| I2 | 投票必须先落盘,响应消息才能发出(含自票) | `raft.go:546-592`(msgsAfterAppend 路由)、`raft.go:1052-1060`(自票)、`rawnode.go:245-254` |
| I3 | 投票约束:候选人日志必须"不落后于"投票者(`isUpToDate`) | `log.go:442-445`、`raft.go:1220-1222` |
| I4 | 当选需要 quorum 同意(单多数或联合双多数) | `quorum/majority.go:169-198`、`quorum/joint.go:61-75` |
| I5 | 提交需要 quorum 确认,提交索引 = 各 voter Match 的"中位数" | `quorum/majority.go:120-163`、`tracker/tracker.go:179-181`、`log.go:455-464` |
| I6 | commit 索引单调不回退 | `log.go:322-330` |
| I7 | 新 Leader 上任先追加空 Entry,且在当前 Term 提交一条日志前不得服务 ReadIndex | `raft.go:961-965`、`raft.go:1363-1368`、`raft.go:2065-2070` |
| I8 | 有 Lease(checkQuorum)时,选举超时窗口内收到现任 Leader 心跳的 follower 拒绝响应更高 Term 的拉票(Pre-Vote/CheckQuorum 场景) | `raft.go:1100-1113`、`raft.go:1731-1741` |
| I9 | Leader 失去 quorum 活跃度一个选举超时后自动退位 | `raft.go:866-877`、`raft.go:1281-1293`、`tracker/tracker.go:208-218` |
| I10 | 成员变更:任意新旧配置 quorum 必须相交(联合共识),一次只允许一个 pending 变更 | `confchange/confchange.go:128-146`、`raft.go:1326-1346`、`raft.go:386-392` |
| I11 | Leader 在 Term T 提交的 Entry 必然出现在一切 Term > T 的 Leader 日志中(Leader Completeness,由 I1-I4 推出,非显式代码) | 见 ② |

这 11 条不变量中,I1-I4 构成选举安全的核心推理链,I5/I7 支撑线性一致读,I10 支撑成员变更安全。下面逐一展开。

---

## ② 选举安全完整推理链

### 2.1 投票约束:isUpToDate 的精确语义

`raftLog.isUpToDate` 是整个选举安全的地基,实现极简(`log/log.go:442-445`):

```go
// log.go:442
func (l *raftLog) isUpToDate(their entryID) bool {
	our := l.lastEntryID()
	return their.term > our.term || their.term == our.term && their.index >= our.index
}
```

注意三点语义,均对应论文 §5.4.1:
1. 比较"最后一条 Entry"的 `(term, index)`,先比 term 再比 index(论文中"最后一次日志条目不同 term 时 term 大者新;同 term 时 index 大者新")。
2. **相等也算 up-to-date**(`>=`,log.go:444)。也就是说投票者只拒绝"严格落后"的候选人,日志完全相同的候选人可以拿到票。这符合论文措辞 "voter denies its vote if its own log is more up-to-date than the candidate's"——相同不算"更新"。
3. entryID 的 pair 比较遵循 Raft 的日志性质:同一 index 在同一任期内日志分叉后不可能再重合,因此 `(term,index)` 的大小关系隐含了"前缀一致性"。

### 2.2 投票决策点的完整实现

投票入口在 `raft.Step` 的 `MsgVote/MsgPreVote` 分支(`raft.go:1212-1262`):

```go
// raft.go:1214
canVote := r.Vote == m.GetFrom() ||                                   // 重复投票
	(r.Vote == None && r.lead == None) ||                             // 本任未投且无 Leader
	(m.GetType() == pb.MsgPreVote && m.GetTerm() > r.Term)            // PreVote 面向未来任期
	lastID := r.raftLog.lastEntryID()
	candLastID := entryID{term: m.GetLogTerm(), index: m.GetIndex()}
	if canVote && r.raftLog.isUpToDate(candLastID) {
		r.send(&pb.Message{To: m.From, Term: m.Term, Type: voteRespMsgType(m.GetType()).Enum()})
		if m.GetType() == pb.MsgVote {
			r.electionElapsed = 0
			r.Vote = m.GetFrom()
		}
	}
```

这个决策点同时编码了 4 个约束:
- **单票不变量(内存)**:`r.Vote == m.GetFrom()` 允许重复投票幂等响应;`r.Vote == None` 才能首次投票(raft.go:1214-1216)。特别注意 `r.lead == None` 这个条件——即使还没投票,只要本地认为当前任期有 Leader,就不再投票(防止任期对齐时被误拉票)。
- **日志约束**:`isUpToDate`(raft.go:1222)。
- **Learner 也可以投票**:raft.go:1223-1240 的长注释解释了一个反直觉设计——刚被提升为 voter 的节点在收到 conf change 之前仍自认 learner,若它拒绝投票,提升场景可能导致剩余 voter 无法凑出 quorum。
- **投票落盘前不发响应**:`r.send` 内部把 `MsgVoteResp/MsgPreVoteResp/MsgAppResp` 路由进 `msgsAfterAppend` 而不是 `msgs`(raft.go:546-592),即"先持久化 Term/Vote,再让选票离开本机"。甚至拒绝票(`Reject==true`)也走这条路径——注释明确说虽然拒绝票大概率不依赖未落盘状态,但"安全性未经形式化验证,宁可保守"(raft.go:580-591)。

### 2.3 单票不变量的三个层次

1. **内存层**:`tracker.RecordVote` 只在首次记录时写入,后续重复票被忽略(`tracker/tracker.go:251-256`),保证计票不受重复响应影响。
2. **持久层**:投票后 `r.Vote` 改变触发 `HardState` 变化,`MustSync` 判定必须同步落盘(`rawnode.go:191-198`:`entsnum != 0 || st.GetVote() != prevst.GetVote() || st.GetTerm() != prevst.GetTerm()`)。重启后 `loadState` 恢复 Term/Vote/Commit(`raft.go:2037-2044`)。
3. **复位层**:Term 变更时 `reset()` 把 `Vote` 归零(`raft.go:782-785`),保证"单票"是按任期计的,而非按节点生命周期计。

候选人的自票同样走持久化路径:`campaign()` 对自己不真的发 MsgVote,而是向自己发一条 `MsgVoteResp`,进 `msgsAfterAppend`(raft.go:1052-1060)——即"自票必须等本任期 Term+Vote 已落盘后才计入"。这是很多自研 Raft 实现会漏掉的细节。

### 2.4 推理链:为什么"拥有最新日志者才能当选"

把以上机制串起来,给出完整的 Leader Completeness 证明(对应论文 §5.4.2):

1. **前提(提交规则)**:Entry E 在任期 T 被 commit,意味着 E 被复制到任期 T 的某个投票多数集 Q 上(I5)。
2. **候选人的 quorum**:任何当选任期 T' > T 的 Leader,都在 T' 拿到了某个多数集 Q' 的选票(I4)。
3. **多数相交**:Q ∩ Q' ≠ ∅(多数集两两相交;联合配置下用双多数保证,见 ③)。
4. **相交节点约束**:设 v ∈ Q ∩ Q'。v 拥有 E(v 已在 Q 上收到并持久化了 E,MsgAppResp 同样在落盘后才回,raft.go:546-558)。v 对 T' 候选人 c 的投票满足 `isUpToDate(candLast, v.last)`(I3)。
5. **单调传递**:若 v.log 比 c.log 新或相等,则 c.log 的最后 Entry ID ≥ v 的最后 Entry ID ≥ E 的 Entry ID(同任期内 index 单调;v 含 E)。于是 c.log 含 E。
6. **结论**:任期 T' 的 Leader 日志包含所有在 T 之前 commit 的 Entry。

支撑这个链条的工程细节:
- **投票者不能"谎报"**:投票者日志与候选人日志的比较用的是投票者本地 `raftLog.lastEntryID()`(log.go:443),它由 stable+unstable 两部分组成;unstable 部分对应的 HardState 尚未落盘,但这时投票响应被 msgsAfterAppend 拦住,等落盘后才发出,所以从候选人视角看,任何一张"已收到"的选票都对应持久化过的日志状态。
- **任期单调用**:Step 收到更高 Term 的 MsgVote 时先 `becomeFollower(m.Term, None)` 把本地 Term/Vote 推进并复位(raft.go:1123-1131),再进入投票分支——保证投票永远记录在新任期上,不会出现"旧任期的票计入新任期"。
- **PreVote 不改任期**:收到 MsgPreVote 不 bump 本地 Term(raft.go:1115-1117),这样被隔离节点反复 Pre-Vote 不会把集群任期推高(论文 §9.6 的 disruptiveness 修复)。
- **Lease 保护(可选)**:`checkQuorum` 开启时,follower 在收到现任 Leader 消息后的一个选举超时窗口内,直接忽略更高 Term 的 MsgVote/MsgPreVote(raft.go:1100-1113,`inLease := r.checkQuorum && r.lead != None && r.electionElapsed < r.electionTimeout`)。这不是安全性的必要条件(有 Lease 时依然正确),而是减少不必要 Leader 切换的可用性优化;唯一例外是 `campaignTransfer` 的强制拉票(raft.go:1102-1104)。
- **Leader 自我检视**:Leader 每过一个选举超时检查 quorum 活跃度,失联则主动退位(raft.go:866-877;`QuorumActive` 用 RecentActive 当选票跑一次 `VoteResult`,tracker.go:208-218)。它保证了"旧 Leader 在 LeaseBased 读或成员变更提交窗口内不会长期处于脑裂孤岛"。

---

## ③ quorum 包的算法

`quorum/` 是一个与 raft 主逻辑解耦的纯数学包,核心是三种配置抽象:`MajorityConfig`(`map[uint64]struct{}`,majority.go:26)、`JointConfig [2]MajorityConfig`(joint.go:19)和接口 `AckedIndexer`(quorum.go:34-36)。

### 3.1 中位数提交:CommittedIndex

多数派配置的提交索引计算(`quorum/majority.go:120-163`):

```go
// majority.go:156
	slices.Sort(srt)
	// The smallest index into the array for which the value is acked by a
	// quorum. In other words, from the end of the slice, move n/2+1 to the
	// left (accounting for zero-indexing).
	pos := n - (n/2 + 1)
	return Index(srt[pos])
```

算法:把各 voter 的 Match(AckedIndex)收进长度 n 的数组排序,取第 `n-(n/2+1)` 位(0-based),即**升序数组的下中位数**。为何取中位数而非"第 q 大"?等价性:数组升序排列后,`srt[pos]` 右侧(含自身)恰有 `n/2+1 = q` 个元素,即至少 q 个 voter 的 Match ≥ 该值——这正是"被 quorum 覆盖的最大索引"。

三个实现细节值得注意:
- **未确认 voter 填 0**:收集时未 AckedIndex 的 voter 留 0 且"从右往左填"(majority.go:143-155),排序后 0 落在左侧,自然等价于"Match=0";它压低中位数,确保不把未确认者算进 quorum。
- **空配置返回 MaxUint64**(majority.go:122-126),与 JointConfig 的 min 组合后语义是"联合配置中某一半为空时退化为另一半"(joint.go:49-56),这是联合共识过渡期两端对齐的关键技巧。
- **栈上 7 元素小数组优化**(majority.go:135-141),`tracker.Visit` 同样镜像了这个优化(tracker.go:189-195)——注释明说这是热路径。

主流程的调用链:`tracker.Committed()` → `Voters.CommittedIndex(matchAckIndexer)`(tracker.go:179-181)→ `raftLog.maybeCommit(entryID{term: r.Term, index: trk.Committed()})`(raft.go:775-779)。`maybeCommit` 里有一条容易被忽略的防线:commit 的 `(term,index)` 必须 `matchTerm` 且 term ≠ 0(log.go:455-464)——即 Leader 只提交"确认仍在本任期日志里"的索引,防止 Leader 日志被截断(snapshot 重放)后用过期 Match 推进 commit。

### 3.2 联合双多数:JointConfig

联合配置要求**两个多数集同时同意**(`quorum/joint.go:49-56` 取两者 CommittedIndex 的 min;投票则取两方 VoteResult 的合成,joint.go:61-75):

```go
// joint.go:61
func (c JointConfig) VoteResult(votes map[uint64]bool) VoteResult {
	r1 := c[0].VoteResult(votes)
	r2 := c[1].VoteResult(votes)
	if r1 == r2 {
		return r1
	}
	if r1 == VoteLost || r2 == VoteLost {
		return VoteLost
	}
	return VotePending
}
```

真值表合成规则:一致则取之;任一 `VoteLost` 即整体 `VoteLost`;否则(一方 Won 一方 Pending)整体 `VotePending`。这个三值合成保证了在 C_old,new 期间,任何"新配置单侧赢"都不能宣称当选——**新旧配置的 quorum 必须同时点头**,这就是成员变更期间新旧配置 quorum 相交不变量的实现载体。

`MajorityConfig.VoteResult` 本身是三值判定(majority.go:169-198):统计 yes 票 `votedCnt` 与未投 `missing`,`q = len(c)/2+1`;`votedCnt >= q` → Won;`votedCnt+missing >= q` → Pending;否则 Lost。注意"no 票不计数"——只要 no 没构成多数拒绝,剩余票理论上还能凑成多数,就必须继续等,这正是 Pending 存在的意义。空配置约定 `VoteWon`(majority.go:170-175),同样是配合联合配置的"半空退化"技巧。

### 3.3 VoteResult 在主流程中的两个用途

- **选举计票**:`poll → TallyVotes`(raft.go:1075-1083,tracker.go:260-281)。`TallyVotes` 对 learner 不计 granted/rejected(tracker.go:265-268),但 `VoteResult` 传的是完整 `p.Votes` map——多出的非 voter 票不影响判定(VoteResult 只遍历配置成员,majority.go:179-188)。
- **Leader 存活检查**:`QuorumActive` 把各 voter 的 `RecentActive` 当作 bool 票跑 `VoteResult`(tracker.go:208-218),复用同一套多数判定。

---

## ④ ReadIndex 两种模式逐段解读

线性一致读的核心问题是:Leader 返回读结果时,它必须确定"此刻没有更高任期的 Leader 已经(或即将)提交我看不到的日志"。etcd/raft 把答案编码为 ReadIndex 协议,入口是 `stepLeader` 的 `MsgReadIndex` 分支(raft.go:1354-1372)和 `sendMsgReadIndexResponse`(raft.go:2146-2161)。

### 4.1 请求的流转与三道前置闸门

一条 MsgReadIndex 到达 Leader 前,可能被 follower 转发(stepFollower,raft.go:1764-1770);到达 Leader 后经过:

1. **单节点捷径**:`trk.IsSingleton()` 直接用当前 commit 应答(raft.go:1355-1361)——只有一个 voter 时不存在分叉 Leader,无需 quorum 确认。
2. **空 Entry 闸门**:当前任期尚无任何 commit 的请求被暂存进 `pendingReadIndexMessages`(raft.go:1363-1368),等 `maybeCommit` 成功时由 `releasePendingReadIndexMessages` 放行(raft.go:1550-1553、2127-2144)。
3. **为什么需要闸门 2**:新 Leader 的 commit 索引可能落后于前任已提交的进度(它还没被 quorum 确认过 Match)。`committedEntryInCurrentTerm()` 判断 commit 位置的 term 是否等于当前任期(raft.go:2065-2070);只有本任期至少提交过一条日志(新 Leader 上任时追加的空 Entry,raft.go:961-965),其 commit 索引才可信地覆盖了前任的所有提交。这与"新 Leader 提交空 Entry"的论文技巧(§5.4.2 / 论文第 8 章)互为表里:空 Entry 让 commit 尽快推进,闸门保证读请求不会拿着陈旧 commit 出门。

### 4.2 ReadOnlySafe:为什么必须等心跳确认

Safe 模式下 Leader 不立即应答,而是登记请求并广播一轮带 Context 的心跳(raft.go:2150-2156):

```go
// raft.go:2150
	case ReadOnlySafe:
		r.readOnly.addRequest(r.raftLog.committed, m)
		// The local node automatically acks the request.
		r.readOnly.recvAck(r.id, r.readOnly.heartbeatCtx())
		r.bcastHeartbeat()
```

`readOnly` 的状态结构(read_only.go:39-47)是理解协议的关键:`acks map[uint64]uint64` 记录每个 voter 确认到的"读位置",`unconfirmedReads` 是 FIFO 请求队列,`confirmedReads` 是已确认数量。Context 被复用为一个单调递增的 uint64"读队列游标"(`heartbeatCtx`,read_only.go:93-101:`confirmedReads + len(unconfirmedReads)` 的小端编码),一轮心跳同时确认所有未决读。

follower 收到心跳后原样回填 Context(`handleHeartbeat`,raft.go:1835-1838),Leader 在 `MsgHeartbeatResp` 中记账(read_only.go:65-69 用 `max()` 防乱序回退),随后:

```go
// raft.go:1604
		r.readOnly.recvAck(m.GetFrom(), m.GetContext())
		rss := r.readOnly.maybeAdvance(r.trk.Voters)
```

`maybeAdvance`(read_only.go:79-89)把 `ro.acks` 经 `AckedIndex` 适配器喂给 `CommittedIndex`——**复用 ③ 的中位数算法**:读队列游标的中位数越过第 k 个请求时,前 k 个请求(严格说是游标之前连续的所有请求)即被确认,生成 `ReadState{Index, RequestCtx}` 通过 `Ready.ReadStates` 交给应用(rawnode.go:159;node.go:68-72 要求应用层等 applied ≥ ReadState.Index 才可服务)。

**为什么必须等这轮心跳?** 语义在 MsgHeartbeatResp 分支之前:`Step` 的任期检查会丢弃旧 Leader 的消息(raft.go:1133-1156)——被罢黜的 Leader 发出的心跳,其 Term 已低于 follower 本地 Term,follower 不会以带 Context 的 MsgHeartbeatResp 应答(只会回一条更高 Term 的 MsgAppResp 促其退位)。因此:**"拿到 quorum 的心跳确认"等价于"在确认时刻,没有任何更高任期的 Leader 已从这些节点获得选票"**;由多数相交,任何新 Leader 都尚未完成选举,故登记时记录的 `r.raftLog.committed` 不低于任何此刻已提交的索引。这就是论文第 6.4 节 ReadIndex 的两阶段实现:记录 → 广播心跳 → 等 quorum → 应答。

两个补充细节:心跳发给了包括 learner 在内的所有节点(bcastHeartbeatWithCtx 遍历全部 Progress,raft.go:728-735),learner 的 ack 也会记进 `acks`,但 `maybeAdvance` 只统计 `r.trk.Voters`(raft.go:1605),learner 票数天然无效;`acks` map 只在 `reset()` 时整体重建(raft.go:809),配合 `max()` 保证整个任期内的单调性。

### 4.3 ReadOnlyLeaseBased:时钟假设的边界

Lease 模式完全跳过心跳往返,收到请求立即用当前 commit 应答(raft.go:2157-2160)。其正确性完全押注在 **Leader Lease** 上:

- **假设 A(租约有效性)**:只要 Leader 在一个选举超时内收到过 quorum 心跳响应,就不可能有新 Leader 当选。`QuorumActive`/`MsgCheckQuorum` 的自动退位(raft.go:1281-1293)让违反租约的 Leader 最多滞后一个选举超时被纠正。
- **假设 B(时钟有界)**:raft.go:64-70 的注释给出了失效条件——"If the clock drift is unbounded, leader might keep the lease longer than it should (clock can move backward/pause without any bound). ReadIndex is not safe in that case."。更精确地说,需要(节点间时钟漂移上界 + 心跳 RTT 上界 + 消息处理时延上界) < 选举超时,否则可能出现"follower 侧租约已过期、已投了新 Leader,而旧 Leader 侧还自认为在租约内"的窗口。
- **强制约束**:`Config.validate()` 规定 LeaseBased 必须开启 CheckQuorum(raft.go:336-338)——没有 CheckQuorum 的自动退位,租约就只剩"旧 Leader 自我认知",完全失去保证。
- **配套限制**:LeaseBased 下 follower 忽略 `MsgForgetLeader`(raft.go:1749-1753)。`inLease` 判定依赖 `r.lead != None`(raft.go:1103),主动"忘记 Leader"会伪造租约失效,使 LeaseBased 的读路径在语义上不可用。

### 4.4 两种模式的取舍

Safe 模式的代价是每个读批次一次 RTT 的心跳广播(多个 pending 读共用一轮,`heartbeatCtx` 游标设计让确认是批量的),换来不依赖任何时钟假设的线性一致性——所以注释说 "It is the default and suggested option"(raft.go:62)。Lease 模式把读延迟降到本地,但要求运维方为整台集群的 NTP/时钟单调性背书,etcd 生产默认从不建议。

---

## ⑤ Leadership Transfer 全流程

Leader transfer(论文 §3.10)的目标是**在不改变任期安全语义的前提下,把 leadership 移交给指定节点**,etcd/raft 用四条消息完成:`MsgTransferLeader → (MsgApp) → MsgTimeoutNow → MsgVote...`。

### 5.1 触发与Leader侧状态机

入口有两条:`RawNode.TransferLeader` 本地直接 Step(rawnode.go:540-542),或 follower 收到后转发给 Leader(node.go:601-604 经 recvc;stepFollower raft.go:1742-1748)。Leader 侧处理(stepLeader,raft.go:1636-1666):

```go
// raft.go:1637
		if pr.IsLearner { return nil }          // learner 不可接任
		if lastLeadTransferee == leadTransferee { return nil }  // 幂等
		r.abortLeaderTransfer()                  // 换目标则中止旧的
		r.electionElapsed = 0                    // 限时一个选举超时完成
		r.leadTransferee = leadTransferee
		if pr.Match == r.raftLog.lastIndex() {
			r.sendTimeoutNow(leadTransferee)     // 日志已追平,立即发牌
		} else {
			r.sendAppend(leadTransferee)         // 先补日志
		}
```

期间 Leader 的行为约束:所有提案直接丢弃(raft.go:1304-1307)——因为任期即将易主,提案会白白制造日志分叉;当 transferee 的 MsgAppResp 报告 `Match == lastIndex` 时补发 TimeoutNow(raft.go:1572-1576);每个 tick 的心跳路径上,超过一个选举超时未完成即 `abortLeaderTransfer`(raft.go:873-876);若 transferee 被成员变更移除或降级,同样中止(raft.go:2029-2032)。

### 5.2 Transferee 侧:绕过 Pre-Vote 的选举

`MsgTimeoutNow` 到达 transferee(follower)后(raft.go:1758-1763):

```go
// raft.go:1758
	case pb.MsgTimeoutNow:
		r.hup(campaignTransfer)
```

`campaignTransfer` 有三个特殊语义:① **永不走 Pre-Vote**(注释:转移场景不可能刚从分区恢复,不需要额外往返,raft.go:1760-1762);② 发出的 MsgVote 带 `Context: campaignTransfer`(raft.go:1067-1071),使投票者在 Lease 窗口内也必须响应(raft.go:1102-1104 的 force 分支)——否则 transferee 追平日志的那一拍恰好还在旧 Leader 的租约窗口内,票会被吞掉;③ candidate 状态下收到 MsgTimeoutNow 一律忽略(raft.go:1712-1713),防止重复发牌导致二次选举。

### 5.3 收尾与安全性论证

transferee 以 `Term+1` 发起普通选举,自票走持久化(§2.3),拿到 quorum 即 `becomeLeader`(raft.go:1700-1706)。旧 Leader 收到更高 Term 的 MsgVote:`force` 越过 Lease 检查,投出选票并在 Step 前段 `becomeFollower(m.Term, ...)` 退位(raft.go:1100-1113、1123-1131)。

**安全性论证**:transfer 并不绕过任何选举约束——transferee 依然要过 quorum 选举、投票者依然执行 isUpToDate 与单票检查。它只是(1)通过补日志把 transferee 抬到与 Leader 日志等长(否则 TimeoutNow 不会发出,raft.go:1661-1663、1573-1575);(2)通过 force 拉票消除租约窗口带来的拒绝。 transferring 期间的提案丢弃(raft.go:1304-1307)保证了不会出现"新 Leader 日志反而缺旧 Leader 尾巴"的窗口,从而避免转移后立即再选。若 TimeoutNow 丢失或 transferee 竞选失败,机制是纯超时回退:一个选举超时后 Leader 恢复收提案,集群照常运转——transfer 是**尽力而为的优化**,不是正确性依赖。

### 5.4 与成员变更的相互作用

`appliedTo` 中 AutoLeave 的自动退出联合配置提案有一条注释专门讨论了转移场景(raft.go:742-763):该提案"可能因转移进行中而被丢弃",但 applied 每推进一条都会重试,最终要么新 Leader 完成转移后自己退出联合,要么转移失败由本节点补提案——保证 AutoLeave 不因转移而永久卡死。

---

## ⑥ 设计动机与取舍

1. **quorum 独立成包,纯函数化**。`quorum/` 不依赖 raft 状态,只靠 `AckedIndexer` 接口取数(quorum.go:34-36),于是 ReadIndex 的 ack 计账(read_only.go:72-75)与提交推进(tracker.go:169-181)能复用同一个中位数算法。代价是多一层间接,收益是 `majority_test.go/quick_test.go` 可以做性质测试,而且让"配置"与"进度"正交。
2. **中位数 vs 计数器**。直接维护"已确认到 k 的 voter 数"也能算 commit,但中位数算法对乱序 ack、learner、联合配置一视同仁,且 `Describe`(majority.go:48-106)能把 commit 决策画成柱状图用于调试——etcd 团队显然更看重可观测性与正确性易证,而非 O(n) 之外的最优常数。
3. **msgsAfterAppend:把持久化顺序显式化**。传统 Ready 模型靠"先写盘再发消息"的文档约定,AsyncStorageWrites 出现后约定必须升级为机制:`MsgAppResp/MsgVoteResp/MsgPreVoteResp` 被物理地放进 MsgStorageAppend 的 Responses 列表(rawnode.go:245-254),由存储线程在 fsync 后投递。连"拒绝票"也不抄近道(raft.go:580-591),注释坦承这是"未经形式化验证,宁可保守"。这是把论文 §3.8 的持久化要求从"约定"提升为"类型系统级路由"的典型案例。
4. **HardState 三字段的语义分工**。`Term/Vote` 是选举安全的持久化要求(MustSync),`Commit` 只是为了重启后少回放;因此 `MustSync` 在仅 commit 变化时返回 false(rawnode.go:191-198),Async 模式下 MsgStorageAppend 也只在携带 HardState 时才要求"响应消息前必须 durable"(raft.go:169-175 注释)。同理 HardState 无变化时不进 Ready(rawnode.go:454),避免无谓 fsync。另一处易被忽略的语义:commit 单调不回退(log.go:322-330)不仅保护 follower 心跳路径,也是 snapshot fast-forward(raft.go:1912-1918)的前提。
5. **ReadIndex 的游标复用**。把 Context 复用为"读队列游标"(read_only.go:93-101)是一次精巧的协议压缩:一轮心跳确认所有 pending 读,`max()` 保序,`CommittedIndex` 判定确认线。代价是可读性下降——Context 语义从"请求标识"变成"位置编码",这也是代码注释里 "thinking: use an internally defined context instead of the user given context"(raft.go:2147-2149)想进一步收敛的方向。
6. **Leader transfer 的保守性**。提案丢弃、一个选举超时限时、learner 排除、candidate 忽略 TimeoutNow、AutoLeave 重试,所有边界都用"退化为普通选举或普通 Leader"兜底,不存在任何"必须转移成功才能继续"的路径。与 etcd server 侧"迁移 leader 以避免慢盘拖累写"的运维场景匹配。

---

## ⑦ FAQ

**Q1:isUpToDate 用 `>=` 而非 `>`,两个日志完全相同的候选人会不会都当选?**
不会。当选仍需 quorum,且同一任期内每个投票者只投一票(raft.go:1214-1216 + tracker.go:251-256),两个候选人必然有一个拿不到多数(多数集相交)。

**Q2:投票者的日志有 unstable 段时,`lastEntryID` 会不会"虚高"?**
会包含 unstable 段,但选票在 HardState(含该日志段)落盘后才发出(raft.go:546-592),所以候选人见到的每张选票背后都有持久化的日志状态,推理链 ②-2.4 第 5 步成立。

**Q3:PreVote 为什么不影响选举安全?**
PreVote 只是预演:不改 Term、不写 Vote(raff.go:1115-1117;becomePreCandidate 不碰 Term/Vote,raft.go:923-925),真正的 MsgVote 依然走完整约束。它的价值是把"被隔离节点重新入网"造成的任期扰动提前拦截。

**Q4:`r.lead == None` 出现在 canVote 里,为什么本地认为有 Leader 就不能投票?**
防止同一任期内"自认为 Leader 的旧 Leader"仍在服务时,投票者又把票投给同任期的新候选人,制造同任期双主窗口。该条件只在 Term 相同时生效(更高 Term 会先 becomeFollower 复位 lead,raft.go:786)。

**Q5:Safe 模式下多个并发 ReadIndex 会发多轮心跳吗?**
不会。所有 pending 读共用 `heartbeatCtx()` 计算出的同一个游标(read_only.go:93-101),一轮心跳的 quorum ack 同时推进整条确认线;但新读请求加入后的下一轮心跳必须重新获得多数 ack,旧 ack 不能"透支"。

**Q6:learner 的心跳 ack 会被算进 ReadIndex quorum 吗?**
会记录进 `ro.acks`(read_only.go:65-69),但 `maybeAdvance` 只对 `r.trk.Voters` 求中位数(raft.go:1605),learner 的 ack 不参与判定;心跳仍发给 learner 是为了维持其日志追平与租约活性。

**Q7:新 Leader 为什么不能直接用继承来的 commit 索引服务读?**
它的 commit 只反映自己任期内被 ack 的进度,前任可能已提交更多条目。闸门 `committedEntryInCurrentTerm`(raft.go:2065-2070)保证:只有当空 Entry(raft.go:961-965)在本任期提交后,commit 索引才覆盖前任的全部提交。

**Q8:Leader transfer 期间新提案为什么必须丢弃而不是暂存?**
暂存会在转移完成后由新 Leader 复放,但提案的成败语义对客户端不可见;丢弃(ErrProposalDropped,raft.go:1304-1307)让上层可以明确重试,同时避免旧 Leader 在转移窗口继续制造日志尾,减少转移后再选的概率。

**Q9:CheckQuorum 开启后 Leader 失联多久会退位?退位算不算"新任期"?**
一个选举超时(raft.go:866-877 → 1281-1293),`becomeFollower(r.Term, None)` 保持在**同一任期**退位(raft.go:1284),不 bump Term;它只是"承认现实",选举仍由其他节点的超时触发。

**Q10:联合配置里为什么一半是空的?**
两种情况:C_old 进入 C_old,new 前 `Voters[1]` 为空表示"当前是简单配置";LeaveJoint 后同样如此。配合空配置 `CommittedIndex=MaxUint64`(majority.go:122-126)与 `VoteWon`(majority.go:170-175)的约定,JointConfig 的 min/双 Won 合成在非联合时期自动退化为单多数语义,代码无需特判。

---

## ⑧ 深挖问题(供后续章节/自研参考)

1. **msgsAfterAppend 的自引用闭环**:leader 的 `appendEntry` 向自己发 MsgAppResp(raft.go:845)、campaign 向自己发 MsgVoteResp(raft.go:1059),这些自寻址消息依赖存储线程在 fsync 后回投。若应用层吞掉自寻址消息,Leader 永远无法推进 Match/当选——自研 transport 时必须把 `To == self` 的消息路由回 Step,而不是网络层。
2. **MsgStorageAppendResp 的 ABA 问题**(rawnode.go:266-354):异步写管线里,旧 term 的 append 完成信号可能晚于新 term 的覆写,etcd 通过给 Resp 附带发送时 Term 并在 Term 变化后丢弃该响应来避免稳定日志被误截断;这把"正确性问题"换成了"unstable 日志可能延迟释放"的活性问题,再用"每次 Term 变化都补发一条 MsgStorageAppend"来兜底(rawnode.go:321-352)。这是异步持久化改造中最容易被忽视的竞态。
3. **ReadIndex 确认线的批量化语义**:确认线由中位数推进,确认的是"游标 ≤ 确认线的所有请求",但单个 ack 的 ctx 值只代表"该 voter 确认到游标 p";若把 recvAck 的 `max()` 改成赋值,乱序的旧心跳响应会回退确认线导致重确认(无害)或与游标推进竞争(需重新推敲)。验证此类改动建议直接以 `read_only.go` 为单位做性质测试。
4. **LeaseBased 与 CheckQuorum 的耦合是否充分**:`validate()` 强制 CheckQuorum(raft.go:336-338),但 Lease 判定 `inLease` 用的是 follower 侧 `electionElapsed`(raft.go:1103),而 Leader 侧租约的"对外承诺"靠 QuorumActive。两者都基于 tick 计数而非墙钟,假设了所有节点 tick 速率一致;在虚拟化环境 tick 停滞(steal time)时,墙钟租约与逻辑租约可能错位——这是把 etcd 部署到强实时要求场景时需要实测的边界。
5. **转移与 AutoLeave 的活性竞争**(raft.go:742-763):转移进行中 AutoLeave 提案会被反复丢弃重试,若 transferee 反复失败,联合配置可能长时间悬置(双 quorum 开销);etcd server 层是否需要监控 joint 状态持续时间,值得在《etcd server》卷中对照验证。

---

### 附:本章引用文件清单

- `quorum/majority.go`、`quorum/joint.go`、`quorum/quorum.go`
- `read_only.go`
- `raft.go`、`log.go`
- `tracker/tracker.go`
- `rawnode.go`、`node.go`
- `confchange/confchange.go`
