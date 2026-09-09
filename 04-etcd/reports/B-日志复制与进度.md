# B 篇 · 日志、复制与进度追踪(etcd/raft 源码深读)

> 调研对象:etcd-io/raft @ commit `3cbf6a74`(2026-09-02),v3 模块 `go.etcd.io/raft/v3`。
> 涉及文件:`log.go`、`log_unstable.go`、`storage.go`、`types.go`、`raft.go`(调用链佐证)、`tracker/{progress,tracker,inflights,state}.go`、`quorum/{majority,joint}.go`、`confchange/confchange.go`。
> 所有结论均以 `文件:行号` 标注,行号对应该 commit 的工作区源码。

---

## ① 全景:日志的三段式视图

etcd/raft 把"一条日志条目在某个节点上的生命周期"切成三段:已经落盘的 **Storage**、尚未落盘(或落盘确认中)的 **unstable**,以及若干个在内存里推进的游标(committed / applying / applied)。`raftLog` 是这三段唯一视图的组装者(`log.go:25-64`):

```
             索引轴 ─────────────────────────────────────────────►
 storage:   [ ...已 compact... | dummy | e1 | e2 | e3 ──────────]│
                                                  ▲            │
 unstable:                                        [ e4 | e5 ───]│   offset = storage.LastIndex()+1
                                                  ▲     ▲       │   offsetInProgress(写入中,双缓冲)
 游标:  firstIndex                committed ≤ lastIndex          │
                applied ≤ applying ≤ committed                    │
```

三段的分工:

1. **Storage**(`storage.go:48-96`):应用实现的持久层接口。raft 库只读它(Entries/Term/FirstIndex/LastIndex/Snapshot),从不直接写——写动作全部经由 `Ready` 结构交还应用。`storage.go:42-47` 写明契约:任何 Storage 方法报错,raft 实例将"不可操作并拒绝参与选举",善后是应用的责任。
2. **unstable**(`log_unstable.go:37-54`):内存中尚未(确认)落盘的条目与快照。两个关键下标:`offset`(entries[0] 的 raft 索引)与 `offsetInProgress`(已交给应用写入、尚未确认的最大边界,不变式 `offset <= offsetInProgress`,`log_unstable.go:50-51`)。这本质上是一个**双缓冲**:条目从"待写"翻转到"写入中",再由 `stableTo` 清空。
3. **游标组**(`log.go:33-49`):`committed`(quorum 已持久化的最高索引)、`applying`(已下发给应用状态机但未必 apply 完,注释写明不变式 `applied <= applying && applying <= committed`,`log.go:41`)、`applied`(应用已确认 apply 完成)。

注意一个与"教科书 Raft"不同的设计:**committed 不要求本地已持久化**。`nextCommittedEnts` 的注释(`log.go:215-219`)直说 "entries can be committed even when the local raft instance has not durably appended them to the local raft log yet",由 `allowUnstable` 参数决定是否把 unstable 区间内已提交的条目交给应用:`maxAppliableIndex`(`log.go:267-273`)在不允许时把上界压到 `unstable.offset-1`。

驱动三段合拢的是 `Ready` 循环:`nextUnstableEnts` → 应用写盘 → `stableTo`(`log.go:367`);`nextCommittedEnts` → 应用 apply → `appliedTo`(`log.go:332`)。unstable 区间因此不断左移,条目最终全部归入 Storage。

---

## ② raftLog 逐段解读

### 2.1 初始化:从存储恢复游标

`newLogWithSize`(`log.go:75-100`)启动时读 Storage 的 FirstIndex/LastIndex,把三个游标全部初始化为 `firstIndex - 1`(即"最后一条快照的位置"),并把 unstable.offset 定为 `lastIndex + 1`——内存视图从存储的尾部无缝续接。`maxApplyingEntsSize` 同时初始化,它是应用侧 apply 流控的配额上限(`log.go:53-63`)。

### 2.2 Append 流程:maybeAppend 的三步走

follower 收到 MsgApp 后,入口是 `raft.go:1800` 调用的 `raftLog.maybeAppend`。它现在接收一个 `logSlice`(`types.go:67-74`,携带 leader term、prev entryID、连续条目,并声明了 4 条良构不变式)而非裸参数——这是该库近年持续重构的方向(见 `log.go:113-114` 的 TODO:要把 logSlice 一路传到 unstable 做安全校验)。

```go
// log.go:109-131(节选)
func (l *raftLog) maybeAppend(a logSlice, committed uint64) (lastnewi uint64, ok bool) {
	if !l.matchTerm(a.prev) {
		return 0, false             // 1) prev (index,term) 对不上 → 拒绝
	}
	lastnewi = a.prev.index + uint64(len(a.entries))
	ci := l.findConflict(a.entries) // 2) 找第一处同 index 不同 term 的冲突
	switch {
	case ci == 0:                   // 无冲突:给定条目是已有日志的前缀/延伸
	case ci <= l.committed:
		l.logger.Panicf(...)        // 与已提交条目冲突 = 安全性被破坏
	default:
		offset := a.prev.index + 1
		l.append(a.entries[ci-offset:]...) // 3) 从冲突点截断并追加
	}
	l.commitTo(min(committed, lastnewi)) // 4) 推进 commit,但不超过 lastnewi
	return lastnewi, true
}
```

四个要点:

- **match 语义**即"指定索引处 term 相等":`matchTerm`(`log.go:447-453`)查 `term(id.index)` 与期望比较,任何错误(ErrCompacted/ErrUnavailable)都算不匹配。
- **findConflict**(`log.go:154-167`)逐条用 `pbEntryID` 比对,返回第一处冲突索引;若给定条目全是已有日志前缀则返回 0,若给定的更长则返回第一条新条目的索引——这一返回值同时承担"截断点"与"续接点"两种语义。
- **append**(`log.go:133-142`)只做一道防线检查(`after < l.committed` 即 panic:不允许覆盖已提交区间),然后委托 `unstable.truncateAndAppend`。
- **commit 上界**:`min(committed, lastnewi)`(`log.go:129`)——follower 只能 commit"自己确实拥有"的部分。

### 2.3 unstable.truncateAndAppend 的三种情形

`log_unstable.go:191-213` 按新条目首索引 `fromIndex` 与现有区间的相对位置分派:等于末尾则直接 append;`fromIndex <= offset` 说明本地多出的日志要整体回退( leader 告知权威日志后),整体替换并把 `offset`/`offsetInProgress` 一起重置;介于两者之间则保留 `[offset, fromIndex)` 再拼接,并把 `offsetInProgress` 收缩到 `min(offsetInProgress, fromIndex)`——**写入中的前缀仍然算数,尚未写入的残段作废**,这正是崩溃恢复语义在内存侧的镜像。

### 2.4 commit 的 quorum 计算

leader 侧的 commit 推进只有一行(`raft.go:775-778`):

```go
func (r *raft) maybeCommit() bool {
	...
	return r.raftLog.maybeCommit(entryID{term: r.Term, index: r.trk.Committed()})
}
```

quorum 计算链:`tracker.Committed()`(`tracker.go:179-181`,以各 Progress 的 `Match` 为 acked index,`tracker.go:169-175`)→ `JointConfig.CommittedIndex`(`quorum/joint.go:49-56`,取两个多数派结果的 min)→ `MajorityConfig.CommittedIndex`(`quorum/majority.go:120-163`)。后者不是遍历计数,而是**把每个 voter 已 ack 的 Match 排序后取第 n-(n/2+1) 位**:

```go
// quorum/majority.go:156-162(节选)
slices.Sort(srt)
// 从右往左数 n/2+1 个,即为被多数派覆盖的最大索引
pos := n - (n/2 + 1)
return Index(srt[pos])
```

一次排序 O(n log n) 同时解决"谁没回话"(缺席者填 0,自然排在左侧)与"多数派下界"两个问题;联合共识时两个多数派各算一次取 min,即"双多数派同时提交"的语义。leader 拿到该索引后,`raftLog.maybeCommit`(`log.go:455-464`)要求 `at.term != 0 && at.index > l.committed && l.matchTerm(at)` 才 `commitTo`——**term 0 不算匹配**,因为 commit 的前提是"本 term 知道该条目存在"。

### 2.5 isUpToDate:选票时的日志比较

选举投票比较的是 `(term, index)` 二元组而非仅 index(`log.go:442-445`):

```go
func (l *raftLog) isUpToDate(their entryID) bool {
	our := l.lastEntryID()
	return their.term > our.term || their.term == our.term && their.index >= our.index
}
```

term 大者优先;term 相同才比 index,且取 `>=`(相等也算 up-to-date,避免等长日志互拒造成平票僵局)。`lastEntryID`(`log.go:378-385`)由 lastIndex 及其 term 组成,term 查询出错即 panic——投票路径上日志必须自洽。

### 2.6 游标推进与边界防护

- `commitTo`(`log.go:322-330`):只进不退;若 `tocommit > lastIndex()` 直接 panic("Was the raft log corrupted, truncated, or lost?")。
- `appliedTo`(`log.go:332-345`):校验 `i ∈ [applied, committed]`,同时回收应用侧流控配额 `applyingEntsSize`。
- `acceptApplying`(`log.go:347-365`):接受一批待 apply 条目时累加字节数,并在两种情况下置 `applyingEntsPaused` 暂停下一批:配额用尽(`applyingEntsSize >= maxApplyingEntsSize`),或"返回的条目被 maxSize 截断过"(`i < l.maxAppliableIndex(allowUnstable)`,即本可返回更多)。这是**应用侧 apply 的 flow control**,与复制侧 Inflights 是两套独立限速。
- `term(i)` 的合法区间是 `[firstIndex-1, lastIndex]`(`log.go:395-400`):`firstIndex-1` 那条已被 compact 掉的"哨兵"条目,其 term 仍保留用于 Append 匹配。
- `slice`(`log.go:499-548`)横跨 storage 与 unstable 两段拼接:边界校验在 `mustCheckOutOfBounds`(`log.go:551-565`,lo < firstIndex 返回 ErrCompacted,hi 越界 panic);跨界处对 maxSize 的切分有快慢两条路径(`log.go:526-547`),返回切片用三索引表达式防止调用方 append 污染底层数组(`log.go:508-510`)。
- `unstable.stableTo(id entryID)`(`log_unstable.go:138-164`)做了三重容忍:条目已不在 unstable、索引命中的是快照、term 不匹配(unstable 期间被覆盖),都只打日志并忽略而非报错——落盘确认与日志覆盖之间存在竞态是合法的。

### 2.7 compact 与 allEntries 的边界

compaction 发生在 Storage 侧:`MemoryStorage.Compact`(`storage.go:268-288`)丢弃 `compactIndex` 之前的条目,但**保留一条复制被删首条 (Index,Term) 的 dummy 条目**,维持 `ents[i]` 的索引 = `ents[0].Index + i` 这一全局不变式(`storage.go:112-113`);注释同时强调由应用保证 `compactIndex <= raftLog.applied`。`MemoryStorage.Append`(`storage.go:293-326`)负责覆盖式写入:对"已 compact 的旧条目"静默截断,对中间缺口则 panic。`allEntries`(`log.go:422-433`)遇到 ErrCompacted 会递归重试以容忍并发 compaction;而 `maybeAppend` 里冲突点若落在 committed 之内则直接 panic(`log.go:120-121`),因为那意味着安全性已被破坏,静默修复反而危险。

---

## ③ Progress 三态机与 flow control

### 3.1 状态定义与转移图

leader 为每个 follower 维护一个 `Progress`(`tracker/progress.go:30-117`)。三态语义见 `tracker/state.go:20-34`:StateProbe(下一条目位置未知,周期性探测)、StateReplicate(稳态,乐观推进)、StateSnapshot(所需条目已被 leader compact,只能靠快照追赶)。

```
                      收到 MsgAppResp 且 MaybeUpdate 成功
        ┌──────────────────────────────────────────────────────┐
        │                                                      ▼
  ┌────────────┐  MaybeUpdate 成功(含 Match==Index 的探测命中) ┌───────────────┐
  │ StateProbe │ ───────────────────────────────────────────► │ StateReplicate │
  └────────────┘                                              └───────────────┘
        ▲    ▲  MaybeDecrTo 后仍在 Replicate → BecomeProbe      │      ▲
        │    └─────────────────────────────────────────────────┘      │
        │ 拒绝(raft.go:1511-1517)                        Match+1 ≥ firstIndex
        │                                                     (raft.go:1531-1545)
        │  log.term(Next-1) 查不到 → maybeSendSnapshot            │
        │                                                      │
  ┌───────────────┐  BecomeProbe:Next=max(Match+1, PendSnap+1)  │
  │ StateSnapshot │ ◄───────────────────────────────────────────┘
  └───────────────┘  (Next=PendSnap+1, IsPaused 恒 true)
```

三个入口函数是 `BecomeProbe/BecomeReplicate/BecomeSnapshot`(`progress.go:130-158`),共同点是都先 `ResetState`(清 `MsgAppFlowPaused`、`PendingSnapshot` 并 `Inflights.reset()`,`progress.go:121-126`)。`BecomeProbe` 有一处细节:从 StateSnapshot 回来时 `Next = max(Match+1, pendingSnapshot+1)`(`progress.go:134-138`)——快照已确认送达,至少要从快照之后开始探测。

### 3.2 发送侧:SentEntries 与两个状态的分野

`SentEntries`(`progress.go:165-185`)按状态分流:

```go
// tracker/progress.go:167-181(节选)
case StateReplicate:
	if entries > 0 {
		pr.Next += uint64(entries)      // 乐观推进
		pr.Inflights.Add(pr.Next-1, bytes)
	}
	pr.MsgAppFlowPaused = pr.Inflights.Full() // 窗口满 → 暂停
case StateProbe:
	if entries > 0 {
		pr.MsgAppFlowPaused = true      // 每轮探测只发一条
	}
```

StateReplicate 的 flow control 本质是**滑动窗口**:不等待 ack 连续发送,Next 一步推到"已发出的最后一条 +1",窗口由 Inflights 界定;StateProbe 则退化为停等式,每心跳周期至多一条 MsgApp,直到收到响应解除暂停。`IsPaused`(`progress.go:262-273`)统一暴露"还能不能发":Probe/Replicate 看 `MsgAppFlowPaused`,Snapshot 恒 true。发送点在 `raft.maybeSendAppend`(`raft.go:620` 先查 IsPaused,`raft.go:659-661` 发完调 SentEntries/SentCommit);还有一个活性细节:Replicate 状态下若 Inflights 已满,只发**空 MsgApp**以传递 commit 索引,保证全量 inflight 丢包时窗口仍能靠 ack/拒绝自清空(`raft.go:636-643` 的注释完整推演了这个自恢复路径)。

### 3.3 接收侧:MaybeUpdate 与 MaybeDecrTo

`MaybeUpdate(n)`(`progress.go:205-213`)处理 ack:单调提升 Match、`Next = max(Next, n+1)`(维持 `Match < Next` 不变式)、解除暂停;`n <= Match` 视为过期消息直接丢弃。`MaybeDecrTo(rejected, matchHint)`(`progress.go:226-254`)处理拒绝,两个状态的防伪逻辑不同:

- Replicate:`rejected <= Match` 即过期,否则无条件回退到 `Match+1`(丢弃全部乐观推进);
- Probe:要求 `rejected == Next-1` 才认(探测一次只发一条,使防伪成为可能),回退量取 `min(rejected, matchHint+1)` 但不低于 `Match+1`。

matchHint 的来源是 `findConflictByTerm`(`log.go:182-194`):从 follower 给的 reject 位置向后逐条找"我方 term <= 对方 term"的最大索引,读不到(被 compact 或不存在)时保守返回原索引、term 记 0。它与 `raft.go:1478-1510` 的长注释(过期拒绝导致错误回退的具体场景)合起来读,才能体会 Probe 回退的微妙。

### 3.4 Snapshot 态与 needSnapshotAbort 的去向

进入 Snapshot 态的时机是 `maybeSendAppend` 里 `raftLog.term(prevIndex)` 失败(`raft.go:625-629`),随后 `maybeSendSnapshot` 取 `raftLog.snapshot()` 发 MsgSnap 并 `BecomeSnapshot(snapIndex)`。旧版(v3.5 及之前)Progress 上有个 `needSnapshotAbort()` 方法判断"快照已过时,应中止";**本 commit 中该方法已不存在**(全库 grep 无命中)——等价逻辑搬进了 `raft.handleAppendResp`:`case pr.State == tracker.StateSnapshot && pr.Match+1 >= r.raftLog.firstIndex()` 时经 `BecomeProbe(); BecomeReplicate()` 复活(`raft.go:1531-1545`)。这标志着重构完成:Progress 不再回指 raftLog(旧代码里 Progress 持有 raftLog 指针),追踪器与日志彻底解耦。`PendingSnapshot` 上的长注释(`progress.go:64-85`)还解释了为何恢复时不看它:快照可能由旁路数据源制造,实际索引可前可后,只要能从日志续上即可。

### 3.5 Inflights:环形缓冲窗口

`tracker/inflights.go:28-40` 的结构是教科书级环形缓冲:`start`(窗口左沿)+ `count`(在途条数)+ `bytes`(在途字节数)+ 定长上限 `size`(MaxInflightMsgs)与软上限 `maxBytes`。

```go
// tracker/inflights.go:65-80(节选)
func (in *Inflights) Add(index, bytes uint64) {
	if in.Full() { panic("cannot add into a Full inflights") }
	next := in.start + in.count
	if next >= size { next -= size }        // 环回
	if next >= len(in.buffer) { in.grow() } // 按需倍增,上限 size
	in.buffer[next] = inflight{index: index, bytes: bytes}
	in.count++; in.bytes += bytes
}
```

释放用 `FreeLE(to)`(`inflights.go:98-128`):从 `start` 起把 index ≤ to 的在途消息逐个弹出(对应 MsgAppResp 携带的最后一条索引),count 归零时把 `start` 归零以免 buffer 无谓增长(`inflights.go:123-127`)。`Full()`(`inflights.go:131-133`)是双条件 `count == size || (maxBytes != 0 && bytes >= maxBytes)`,maxBytes 是**软限制**——允许最后一条消息把字节数顶过线(`inflights.go:43-45` 注释),避免单条大条目造成死锁。buffer 从 1 起按倍增扩到 size(`inflights.go:85-95`),是为"单进程数千个 raft group"的内存足迹考虑。窗口与 leader 的关系还体现在注释里(`progress.go:101-113`):它同时限制了在途消息条数与每条 Progress 可占用的带宽。

### 3.6 tracker 层:quorum active 与选举

`ProgressTracker`(`tracker/tracker.go:117-126`)聚合 Config(联合投票人、learners)、ProgressMap 与 Votes。`QuorumActive()`(`tracker.go:208-218`)把每个非 learner 的 `RecentActive` 当作一张选票交给 `Voters.VoteResult` 判定——这是 CheckQuorum 的底座:leader 失去多数派联络应主动退位。`TallyVotes`(`tracker.go:260-281`)同理,把选举票喂给同一个 `VoteResult`。`RecentActive` 在新加入节点上初始化为 true,防止 CheckQuorum 在节点来得及通信前把 leader 踢下台(`confchange/confchange.go:266-269`)。此外本版新增 `sentCommit` 字段(`progress.go:43-49`)与 `CanBumpCommit`(`progress.go:187-195`):ack 到达时若 follower 的 commit 无需推进就不再补发空 MsgApp(`raft.go:1555-1560`),减少心跳噪声。

---

## ④ confchange:联合共识的线性化实现

### 4.1 Changer:纯函数式的两阶段状态转移

`confchange.Changer`(`confchange/confchange.go:31-34`)只有两个字段:Tracker(当前配置+进度)与 LastIndex。它是一个**值语义的变换器**:每次 `checkAndCopy()` 深拷贝配置与进度(`confchange.go:337-347`,Progress 只浅拷贝,因为只会改 IsLearner 字段),在副本上应用变更,返回前 `checkAndReturn` 重跑不变量检查(`confchange.go:349-356`)。任何一步失败都返回零值+error,**原配置毫发无损**——"线性化"的含义即:校验先行,拒绝发生在配置生效之前(文件头注释 `confchange.go:27-30`)。

与 Raft 论文(thesis §4.3)的对应:`EnterJoint` 把 `C_old` 变成 `C_{old,new}`,`LeaveJoint` 把 `C_{old,new}` 变成 `C_new`。

```go
// confchange/confchange.go:51-77(节选)
func (c Changer) EnterJoint(autoLeave bool, ccs ...*pb.ConfChangeSingle) (...) {
	cfg, trk, err := c.checkAndCopy()
	if joint(cfg) { return c.err(errors.New("config is already joint")) }
	// 清空 outgoing,再把 incoming 复制过去:C_old → (C_old)&&(C_old)
	*outgoingPtr(&cfg.Voters) = quorum.MajorityConfig{}
	for id := range incoming(cfg.Voters) { outgoing(cfg.Voters)[id] = struct{}{} }
	if err := c.apply(&cfg, trk, ccs...); err != nil { return c.err(err) }
	cfg.AutoLeave = autoLeave            // C_{new,old} 的变更只打在 incoming 上
	return checkAndReturn(cfg, trk)
}
```

`LeaveJoint`(`confchange.go:94-121`)做三件事:把 `LearnersNext` 里暂存的降级节点正式转正为 learner;删除既非 voter 也非 learner 的节点进度;清空 outgoing。`Simple`(`confchange.go:128-145`)是单步变更捷径,但用 `symdiff`(对称差计数,`confchange.go:384-398`)强制"变更聚合后至多改变一个 voter",且禁止在联合状态下调用——超出即必须改走联合共识,这正是论文"一次一变"的安全性边界在代码里的落点。

### 4.2 apply 与三类操作

`apply`(`confchange.go:150-174`)逐个执行 `ConfChangeSingle`:AddNode→`makeVoter`、AddLearnerNode→`makeLearner`、RemoveNode→`remove`、UpdateNode 空操作;NodeId==0 的条目被跳过(etcd 下游否决某变更时的约定,`confchange.go:152-157`)。所有投票人变更**只落在 incoming**(`confchange.go:147-149` 的约定注释),outgoing 在联合期内冻结,保证两个多数派各自稳定。最后兜底"不能删光所有 voter"(`confchange.go:170-172`)。

- `makeVoter`(`confchange.go:178-189`):不存在则 `initProgress`;存在则摘掉 learner 标记、从两个 learner 集合删除、加入 incoming——提升(learner→voter)一步到位。
- `makeLearner`(`confchange.go:204-228`):关键分支在"该节点是否仍在 outgoing 担任 voter"。是,则先 remove 再把 Progress 存回(`trk[id] = pr`),并把身份记入 `LearnersNext` 暂存区,等 LeaveJoint 时转正;否则直接进 `Learners`。暂存的原因写在 `tracker.go:43-77`:若直接加入会违反"voters 与 learners 不相交"不变量(节点会同时是 outgoing 的 voter 和 learner)。
- `remove`(`confchange.go:231-244`):从 incoming 与两个 learner 集合删除;只有当节点也不在 outgoing 时才删其 Progress——**联合期内被移出的节点仍被追踪**,其 Match 还计入 joint quorum,这正是联合共识"任何阶段都不丢多数派"的实现根基。

### 4.3 initProgress 与不变量清单

新节点进度初始化(`confchange.go:253-270`):`Match=0, Next=max(LastIndex,1)`,注释自嘲 "awfully optimistic"——假设 follower 拥有全量日志,而实际大概率需要快照,用 firstIndex 反而更准(TODO 原文承认);独立分配 Inflights 窗口;`RecentActive=true` 如前述保护 CheckQuorum。

`checkInvariants`(`confchange.go:276-332`)在进入与返回时各跑一遍:每个 voter/learner 必有 Progress;`LearnersNext` 里的成员必须在 outgoing 且尚未标记 learner;`Learners` 与两半 voters 均不相交且成员标记一致;非联合状态下 outgoing、LearnersNext 必须为 nil 且 AutoLeave 为 false。这份清单就是"联合共识中间态"的形式化边界。

### 4.4 与日志复制系统的衔接

配置变更作为一条普通日志被复制,应用侧 applied 该条目后调用库的接口,经 Changer 产出新 `tracker.Config` + `ProgressMap` 写回。而提交门槛天然由联合配置把关:`tracker.Committed()` 取两个多数派 committed 的 min(`quorum/joint.go:49-56`),在 `C_{old,new}` 期间一条配置变更日志必须被**新旧两个多数派同时持久化**才算提交——论文中"联合配置上任何日志条目都可安全提交"的不变式在这里不是靠规则约束,而是靠 quorum 函数的算术直接保证。

---

## ⑤ 设计动机与取舍

1. **unstable 双缓冲(offset / offsetInProgress)**:把"写盘请求已下发"与"写盘确认已返回"分开表达。若无此区分,Ready 会重复吐出同一批条目导致应用重复写;若提前清空,写盘失败/乱序确认时会丢失内存视图。代价是 `stableTo` 需要三重竞态容忍(`log_unstable.go:138-164`)。
2. **committed / applying / applied 三游标而非两游标**:`applying` 是为支持**异步 apply**引入的(`log.go:36-42` 的注释明确区分 accepting Ready 与 advancing 两个时机)。配合 `maxApplyingEntsSize` 字节配额(`log.go:53-63`),应用可以流水线式 apply 而不淹没状态机。这是"库把流控做厚、把并发自由让给应用"的取舍。
3. **quorum = 排序取第 n/2 位,而非遍历计数**:`MajorityConfig.CommittedIndex`(`quorum/majority.go:128-162`)用栈上数组(≤7 节点零分配)一次排序得到答案,还免费处理了缺席 voter;代价是每次 MsgAppResp 都重算 O(n log n)。对常见 3/5 节点,这点开销换来无状态、可单测的纯函数,划算。
4. **Progress 与 raftLog 解耦**:旧版 `needSnapshotAbort` 依赖 Progress 内嵌 raftLog 指针;新版把判断挪回 `raft.go:1531`,Progress 变成纯数据状态机。`progress.go:27-29` 的 NB 也承认状态转移散落在 raft.go 中 "not ideal"——解耦至少让 Progress 可独立构造与测试。
5. **Probe 停等、Replicate 开窗**:探测期一次一条,使 `MaybeDecrTo` 能用 `rejected == Next-1` 做廉价的乱序防伪(`progress.go:242-247`);Replicate 期开窗吞吐,防伪退化为 `rejected <= Match`(Match 单调,乐观推进只向前,真实拒绝只可能来自比 Match 新的区间)。两种状态各自选择了最便宜的正确性检查。
6. **Changer 值语义 + 前置校验**:配置变更一旦半途生效就难以回滚(Progress 已建、票已投),因此选择"副本上试算、成功才整体替换",错误输入被挡在活性影响之外。缺点是每次变更深拷贝整个 ProgressMap,但配置变更频率极低,不构成瓶颈。
7. **Inflights 字节软上限**:只限条数会把"单条巨大条目"与"多条小条目"同等对待,大条目场景窗口利用率极低;软字节上限允许压线消息通过,兼顾带宽公平与活性。

---

## ⑥ FAQ

**Q1:committed 在本地还没落盘时就能推进,不会不安全吗?**
不会。committed 的定义是"quorum 个节点上已知持久化"的水位,本地是否落盘只影响本节点崩溃后能否恢复到该位置;保守的应用走 `allowUnstable=false` 路径(`log.go:267-273`),apply 上界被压在稳定存储范围内。

**Q2:maybeAppend 返回 (0,false) 之后会发生什么?**
follower 回带 Reject=true 的 MsgAppResp(携带 reject index 与 hint);leader 在 `handleAppendResp` 中先经 `findConflictByTerm` 算出 `nextProbeIdx`,再调 `MaybeDecrTo` 收缩 Next,若原本在 Replicate 则 `BecomeProbe` 并立即重发一条探测(`raft.go:1511-1517`)。

**Q3:为什么 findConflict 命中 committed 区间要 panic 而不是静默截断?**
Raft 安全性保证已提交条目永不被覆盖;若新 leader 的条目与本地已提交条目冲突,说明选举或日志恢复出了根本性错误,继续运行会扩大破坏,`log.go:120-121` 选择 fail-fast。

**Q4:isUpToDate 为什么用 (term,index) 二元组而不是只比 index?**
term 优先保证"持有更高 term 日志的候选人不会被拒票"——已提交条目只可能出现在更高 term,这样选出 leader 后绝不会覆盖它们;同 term 才比 index 且相等即通过(`log.go:442-445`),避免等长日志互拒造成选举僵局。

**Q5:Inflights 的 maxBytes 为什么是软限制?**
硬限制会死锁:一条超过剩余配额的消息永远无法发出,窗口永远无法释放。软限制允许"最后一条压线消息"通过(`inflights.go:131-133`),窗口在 ack 后照常回收。

**Q6:StateSnapshot 态下 IsPaused 恒 true,leader 还会理这个 follower 吗?**
不再发复制消息,但心跳仍会广播到达;恢复只能靠 follower apply 完快照后回的 MsgAppResp 把 Match 推过 `firstIndex-1`(`raft.go:1531-1545`),或上层调 `ReportSnapshot(SnapshotFinish)` 显式汇报(`progress.go:79-84`)。

**Q7:MaybeDecrTo 在 Probe 态为什么要求 rejected == Next-1?**
Probe 态一次只发一条 MsgApp(只探测 Next 这一条),正常拒绝必然对应 Next-1;不满足即说明是乱序/重复的旧拒绝。注释也承认这只是 "best effort"(`progress.go:242-244`)——误判的后果只是多探测几轮,不影响正确性。

**Q8:联合共识期间被移除节点的 Progress 为什么不删?**
它的 Match 仍是 outgoing 多数派计票的输入;删了它,`C_{old,new}` 的 committed 计算会把它当缺席(quorum/majority.go 中填 0),可能使配置变更日志在新旧多数派都未确认时被误判为已提交,破坏联合共识的核心保证(`confchange.go:240-243`)。

**Q9:Simple 变更为何限制对称差 ≤1?**
多处 voter 变化可能造出与旧配置互不共享多数派成员的新配置(丢多数派窗口);限制后新旧配置必有公共多数派成员,论文 §4.1 的安全性论证成立。超限时调用方必须改走 EnterJoint(`confchange.go:140-142`)。

**Q10:MemoryStorage 为什么用 dummy 条目而不是直接删除头部?**
`Compact` 后保留一条复制被删首条 (Index,Term) 的哨兵(`storage.go:283-286`),使 `ents[i].Index = ents[0].Index + i` 的换算恒成立,且 `Term(firstIndex-1)` 仍可查询——这正是 raftLog.term 合法区间含 `firstIndex-1`(`log.go:395-400`)的存储侧支撑。Append/Entries 里多处 `ents[:len:len]` 全切片表达式(`storage.go:165,318`)则防外部 append 污染内部数组。

---

## ⑦ 深挖问题

1. **logSlice 不变式的下沉尚未完成**:`log.go:113-114` 与 `log_unstable.go:220-222` 的 TODO 表明,作者计划把 `logSlice` 一路传入 unstable 做构造期校验(`valid()`,types.go:93);当前仅在消息边界校验,unstable 与 raftLog 之间的大量 panic 分支(`log.go:125,138,326`)本质是"不变式被破坏后的最后一道闸"。追踪这条重构线可以预判后续版本的 API 演化。
2. **apply 侧配额与复制侧配额的相互作用**:`applyingEntsPaused`(`log.go:363-364`)暂停的是 Ready 中 committed 条目的下发,而 MsgApp 复制照常进行——极端情况下 leader 持续提交、follower 持续追平,但本地 apply 停滞。值得实验测出 `maxApplyingEntsSize` 与 MaxInflightBytes 的配比对端到端 tail latency 的影响,以及 `acceptApplying` 里 `i < maxAppliableIndex` 的截断探测条件在何种负载下误触发。
3. **sentCommit 优化与乱序消息的边界**:`sentCommit` 在 `BecomeProbe`/`MaybeDecrTo` 时回退(`progress.go:142,238,251`),注释(`progress.go:45-47`)承认它会 "con regress in some cases"。MsgApp 乱序到达 follower 时 follower 的 commit 只增不减故无害,但 `CanBumpCommit`(`progress.go:189-195`)的判断在 Snapshot→Probe 转移、联合配置变更导致 Next 跳变等场景下是否始终保守,需要构造测试验证。
4. **Probe 回退的收敛速度**:follower 用过期日志回复拒绝时,`findConflictByTerm` 只能给出"猜测",可能多轮探测(每轮一个 RTT)才能定位冲突点(`raft.go:1478-1510` 的注释给出了一个需要 4 步的实例)。可否在 MsgAppResp 中携带多个 (term,index) 对照点加速收敛?以及 `MaybeDecrTo` 在 Probe 态的 `rejected == Next-1` 防伪在何种乱序分布下会失真。
5. **AutoLeave 的时序空洞**:`AutoLeave=true` 时联合配置日志提交后 leader 会自动补写 LeaveJoint(`tracker.go:32-34`);但若该条日志因 leader 更迭而丢失,新 leader 是否会重复补写、`LeaveJoint` 的幂等性由谁保证(Changer 对非联合态调用 LeaveJoint 会直接报错,`confchange.go:99-102`)?这条链路横跨 raft.go 的 ConfChange 处理与本文件,值得沿 AutoLeave 的全部引用做一次数据流审计。

---

### 附:引用文件与行号速查

| 文件 | 关键位置 |
|---|---|
| log.go | raftLog 25-64;newLogWithSize 75-100;maybeAppend 109-131;findConflict 154-167;findConflictByTerm 182-194;nextCommittedEnts 220-244;maxAppliableIndex 267-273;commitTo 322-330;appliedTo 332-345;acceptApplying 347-365;term 387-413;allEntries 422-433;isUpToDate 442-445;maybeCommit 455-464;slice 499-548;mustCheckOutOfBounds 551-565 |
| log_unstable.go | 结构 37-54;maybeFirstIndex 58-63;maybeLastIndex 67-75;maybeTerm 79-96;acceptInProgress 122-130;stableTo 138-164;truncateAndAppend 191-213;slice 223-229 |
| storage.go | Storage 接口 48-96;MemoryStorage 104-116;Entries 145-166;ApplySnapshot 218-237;CreateSnapshot 243-263;Compact 268-288;Append 293-326 |
| tracker/progress.go | 结构 30-117;ResetState 121-126;BecomeProbe 130-143;SentEntries 165-185;CanBumpCommit 189-195;MaybeUpdate 205-213;MaybeDecrTo 226-254;IsPaused 262-273 |
| tracker/tracker.go | Config/LearnersNext 27-78;Committed 179-181;QuorumActive 208-218;TallyVotes 260-281 |
| tracker/inflights.go | 结构 28-40;Add 65-80;FreeLE 98-128;Full 131-133;reset 139-143 |
| tracker/state.go | 三态定义 20-34 |
| confchange/confchange.go | Changer 31-34;EnterJoint 51-78;LeaveJoint 94-121;Simple 128-145;apply 150-174;makeVoter 178-189;makeLearner 204-228;remove 231-244;initProgress 247-271;checkInvariants 276-332;symdiff 384-398 |
| raft.go(佐证) | maybeSendAppend 608-663;maybeCommit 775-778;handleAppendResp 1511-1569;follower append 1800 |
| quorum/{joint,majority}.go(佐证) | JointConfig.CommittedIndex joint.go:49-56;MajorityConfig.CommittedIndex majority.go:120-163 |
