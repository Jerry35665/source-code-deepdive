# 第 04 章 · 选举安全与 ReadIndex:不变量清单与完整推理链

> 基线:etcd-io/raft,commit `3cbf6a74`(2026-09-02)。行号均以该版本源码为准。

## 4.0 安全性不变量清单

etcd/raft 把"安全性"拆解为可在代码中逐一指认的不变量:

| # | 不变量 | 代码锚点 |
|---|---|---|
| I1 | 一个 Term 内只投一票(内存 + 持久) | tracker.go:251-256、raft.go:1253-1257 |
| I2 | 投票必须先落盘,响应才能发出(含自票与拒绝票) | raft.go:546-592、rawnode.go:245-254 |
| I3 | 候选人日志必须不落后于投票者(isUpToDate) | log.go:442-445、raft.go:1220-1222 |
| I4 | 当选需要 quorum(单多数或联合双多数) | quorum/majority.go:169-198、joint.go:61-75 |
| I5 | 提交索引 = 各 voter Match 的中位数 | quorum/majority.go:120-163 |
| I7 | 新 Leader 先追加空 Entry,本 Term 有 commit 前不服务 ReadIndex | raft.go:961-965、1363-1368 |
| I9 | Leader 失去 quorum 活跃度一个选举超时后自动退位 | raft.go:866-877、tracker.go:208-218 |
| I10 | 成员变更:新旧配置 quorum 必须相交,一次只允许一个 pending | confchange.go:128-146、raft.go:1326-1346 |

其中 I1-I4 构成选举安全的核心推理链。

## 4.1 选举安全:完整推理链

**投票约束的精确语义**(isUpToDate,log.go:442-445):比较最后一条 Entry 的 `(term, index)`;**相等也算 up-to-date**(`>=`)——投票者只拒绝"严格落后"的候选人,符合论文措辞。

**投票决策点**(raft.go:1214-1222)同时编码四个约束:`canVote`(重复投票幂等 ∨ 本任未投且**无 leader** ∨ PreVote 面向未来任期)∧ isUpToDate;只有真 MsgVote 才记录 r.Vote。注意 `r.lead == None` 这个条件——即使还没投票,只要本地认为当前任期有 leader,就不再投票,防止任期对齐时被误拉票。

**单票不变量的三个层次**:内存层(RecordVote 首票生效)→ 持久层(投票触发 HardState 变化,MustSync 判定必须落盘)→ 复位层(Term 变更时 reset 把 Vote 归零——"单票"按任期计)。**候选人的自票同样走持久化路径**:campaign 对自己发一条 MsgVoteResp 进 msgsAfterAppend(1052-1060)——"自票必须等 Term+Vote 落盘后才计入",这是很多自研实现漏掉的细节。

**Leader Completeness 推理链**(论文 §5.4.2,六步):

1. Entry E 在任期 T 被 commit ⇒ E 被复制到 T 的某个投票多数集 Q(I5);
2. 任何当选的 T' > T leader 拿到了多数集 Q'(I4);
3. Q ∩ Q' ≠ ∅(多数集两两相交;联合配置用双多数保证);
4. 设 v ∈ 交集:v 拥有 E,且 v 对候选人的投票满足 isUpToDate(I3);
5. 单调传递 ⇒ 候选人日志含 E;
6. 结论:T' 的 leader 日志包含所有 T 之前 commit 的 Entry。

支撑链条的工程细节有两处关键:**投票者不能"谎报"**——投票者日志的 lastEntryID 含 unstable 段,但选票在 HardState 落盘后才发出(msgsAfterAppend),所以候选人见到的每张选票背后都有持久化的日志状态;**PreVote 不改任期**(1115-1117),被隔离节点反复 Pre-Vote 不会把集群任期推高(论文 §9.6 的 disruptiveness 修复)。

## 4.2 quorum 包:纯数学的三值判定

`quorum/` 与 raft 主逻辑解耦,只靠 `AckedIndexer` 接口取数——**ReadIndex 的 ack 计账与提交推进能复用同一个中位数算法**,还让 majority_test 可以做性质测试。

- **中位数提交**:`CommittedIndex` 把各 voter 的 Match 排序取第 `n-(n/2+1)` 位(0-based 升序下中位数)——右侧含自身恰有 n/2+1 个元素,即"被 quorum 覆盖的最大索引"。未确认 voter 填 0(自然落在左侧);**空配置返回 MaxUint64**,与 JointConfig 的 min 组合后"某一半为空退化为另一半"(joint.go:49-56)——联合共识过渡期两端对齐的关键技巧;≤7 节点栈上数组零分配;
- **三值合成**:VoteResult 返回 Won/Pending/Lost——`votedCnt >= q` → Won;`votedCnt+missing >= q` → Pending;否则 Lost。**"no 票不计数"**:只要 no 没构成多数拒绝,剩余票理论上还能凑成多数就必须等——这正是 Pending 的意义。JointConfig 的合成:一致取之;任一 Lost 即 Lost;否则 Pending(134-145)——**新旧配置必须同时点头**;
- 联合共识里"一半是空的"两种情况(简单配置/LeaveJoint 后)配合空配置约定,JointConfig 在非联合时期自动退化为单多数语义,代码无需特判。

## 4.3 ReadIndex:两种模式

线性一致读的核心问题:Leader 返回读结果时,必须确定"此刻没有更高任期的 leader 已经(或即将)提交我看不到的日志"。

**三道前置闸门**:单节点捷径(IsSingleton 直接应答)→ **空 Entry 闸门**(本 Term 尚无 commit 的请求暂存进 pendingReadIndexMessages)→ 广播心跳确认。闸门 2 的原因:新 leader 的 commit 可能落后于前任已提交进度;`committedEntryInCurrentTerm()` 只有在空 Entry(上任时追加)提交后才为真——空 Entry 与闸门互为表里。

**ReadOnlySafe:为什么必须等心跳确认**(raft.go:2150-2156):

```go
case ReadOnlySafe:
    r.readOnly.addRequest(r.raftLog.committed, m)
    r.readOnly.recvAck(r.id, r.readOnly.heartbeatCtx())
    r.bcastHeartbeat()
```

`Context` 被复用为单调递增的"读队列游标"(read_only.go:93-101)——一轮心跳同时确认所有 pending 读;recvAck 用 `max()` 防乱序回退;`maybeAdvance` 把 acks 经 AckedIndexer 喂给 `CommittedIndex`——**复用提交中位数算法**推进确认线,确认线之前的所有请求生成 ReadState 交给应用。

**为什么等这轮心跳就够了**:被罢黜的 leader 发出的心跳,其 Term 已低于 follower 本地 Term,follower 不会以带 Context 的心跳响应应答(只会回更高 Term 的 MsgAppResp 促其退位)。因此 **"拿到 quorum 的心跳确认"等价于"在确认时刻没有任何更高任期的 leader 已从这些节点获得选票"**;由多数相交,登记的 committed 不低于任何此刻已提交的索引。learner 的 ack 记录但不计入 Voters 中位数。

**ReadOnlyLeaseBased 的时钟假设**(2157-2160):完全跳过心跳往返,正确性押注在两条假设上——租约有效性(一个选举超时内收到过 quorum 心跳响应,就不可能有新 leader 当选;CheckQuorum 的自动退位让违反租约的 leader 最多滞后一个选举超时被纠正)+ **时钟有界**(raft.go:64-70 注释给出失效条件:时钟漂移无界时 ReadIndex 都不安全)。`Config.validate` 强制 LeaseBased 必须开启 CheckQuorum(336-338)——没有自动退位,租约就只剩"旧 leader 自我认知"。Safe 模式的代价是每读批次一次 RTT(批量确认摊薄),换来不依赖时钟的线性一致性——**默认且建议选项**。

## 4.4 Leadership Transfer:尽力而为的优化

四条消息:`MsgTransferLeader → (MsgApp 补日志) → MsgTimeoutNow → MsgVote...`。Leader 侧(1636-1666):learner 不可接任;换目标则中止旧的;限时一个选举超时;日志追平立即 sendTimeoutNow 否则先 sendAppend;**期间所有提案直接丢弃**(任期即将易主,提案会制造日志分叉)。Transferee 侧:hup(campaignTransfer) 有三个特殊语义——永不走 PreVote、MsgVote 带 force Context(使投票者在 Lease 窗口内也必须响应)、candidate 忽略重复 TimeoutNow。

**安全性论证**:transfer 不绕过任何选举约束——transferee 依然要过 quorum 选举;它只是补日志抬到等长 + force 拉票消除租约拒绝。若 TimeoutNow 丢失,机制是纯超时回退——**transfer 是尽力而为的优化,不是正确性依赖**。

## 4.5 FAQ

**Q1:两个日志完全相同的候选人会不会都当选?**
不会:当选仍需 quorum,同一任期每个投票者只投一票,多数集相交保证必有一个拿不到多数。

**Q2:投票者日志有 unstable 段,lastEntryID 会虚高吗?**
选票在 HardState 落盘后才发出(msgsAfterAppend),候选人见到的每张选票背后都有持久化日志状态。

**Q3:多个并发 ReadIndex 会发多轮心跳吗?**
不会:所有 pending 读共用同一游标,一轮心跳的 quorum ack 同时推进整条确认线;新读请求加入后的下一轮必须重新获得多数 ack。

**Q4:新 Leader 为什么不能直接用继承来的 commit 服务读?**
它的 commit 只反映自己任期内的 ack 进度;闸门保证空 Entry 在本任期提交后 commit 才覆盖前任全部提交。

**Q5:CheckQuorum 退位算"新任期"吗?**
不算:becomeFollower(r.Term) 保持同一任期退位,只是"承认现实";选举仍由其他节点的超时触发。

**Q6:联合配置里为什么一半是空的?**
简单配置与 LeaveJoint 后的形态;配合空配置约定(MinUint64/VoteWon),JointConfig 自动退化为单多数语义,无需特判。

## 4.6 小结与深挖方向

本章结论:**选举安全 = 三层单票 + isUpToDate + 持久化栅栏(机制而非约定);提交与读确认共用"排序中位数"纯函数;ReadIndex Safe 模式用一轮心跳的 quorum 确认闭合"读承诺"**。深挖:

1. msgsAfterAppend 的自引用闭环:自研 transport 必须把 To==self 的消息路由回 Step 而非网络层;
2. MsgStorageAppendResp 的 ABA 竞态(异步写管线中旧 term 完成信号晚于新 term 覆写)——"正确性问题换成活性问题再修复"的参考样本;
3. ReadIndex 确认线的批量化语义(recvAck 的 max() 改赋值会怎样);
4. LeaseBased 与 CheckQuorum 在虚拟化环境 tick 停滞时的错位;
5. 转移与 AutoLeave 的活性竞争(联合配置悬置的监控)。

> 下一章:Node/RawNode 的宿主协议——Ready 四步如何在代码里落地,etcd server 如何驱动这一切。
