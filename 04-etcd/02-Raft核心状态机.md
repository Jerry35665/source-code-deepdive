# 第 02 章 · Raft 核心状态机:两个函数指针构成的角色系统

> 基线:etcd-io/raft,commit `3cbf6a74`(2026-09-02,v3.7/3.8 世代)。行号均以该版本源码为准。

## 2.0 全景:一个"状态机库",不是"共识服务"

`doc.go` 开篇即定位:以 protobuf 格式收发消息、用复制日志在多节点间维持复制状态机同步。**它没有网络、没有磁盘、没有时钟**——这三样恰恰是共识服务最重的部分,全部留给宿主(etcd server、TiKV、CockroachDB):

- **网络**:库只把要发的消息 append 进 `r.msgs`(raft.go:364-368),宿主经 Ready.Messages 取走发出;收到的包由宿主调 `Node.Step()` 送回(doc.go:110-114);
- **磁盘**:库通过 Storage 接口读已持久化状态,要写的条目打包在 Ready.Entries/HardState/Snapshot 里交给宿主落盘(node.go:74-87);
- **时钟**:时间被抽象成逻辑 tick,宿主定期调 `Node.Tick()`(doc.go:116-119);库内部只有两个计数器,绝不碰真实时钟。

库与宿主的契约由 doc.go:69-104 正式规定,即著名的 **Ready 四步**:1)先写 HardState/Entries/Snapshot 到持久存储(写 Index=i 前必须丢弃所有已持久化的 ≥i 条目);2)再发消息,**必须等最新 HardState 落盘后才能发消息**(doc.go:79-86,点名论文 §10.2.1 的 leader 并行落盘优化);3)apply 快照与 CommittedEntries,EntryConfChange 必须回喂 ApplyConfChange;4)调 Advance() 释放下一批。

**与论文 Raft 的两处官方差异**(doc.go):其一,成员变更在 entry 被 **apply** 时生效而非进入日志时生效,为防两条未提交变更被同一 quorum 混合提交,库强制同时只允许一条 pending 配置变更(pendingConfIndex 机制,raft.go:386-392);其二,两节点集群摘除一个会死锁,官方建议至少三节点(doc.go:278-283)。

在此之上是实现比论文多出的工程扩展:PreVote 两阶段选举、CheckQuorum(leader 主动步降)、Leader lease(选举租约读)、Learner 只读成员。

## 2.1 状态机:四个角色与四次变轨

状态有四个:StateFollower/StateCandidate/StateLeader/StatePreCandidate(raft.go:50-56)。PreCandidate 是 PreVote 开启时的"零成本试探态",不占用 Term。

```
                MsgHup(选举超时) / MsgTimeoutNow(领导权转移)
     ┌──────────┐ ─────────────────────────────────► ┌───────────┐
     │ Follower │                                    │ Candidate │
     └────┬─────┘ ◄────────────────────────────── └─────┬─────┘
          │   ▲      收到更高/同 term 的 MsgApp/          │
          │   │      MsgHeartbeat/MsgSnap:becomeFollower │ 赢得多数票
          │   │                                          ▼
          │   │      CheckQuorum 不活跃 → 步降     ┌───────────┐
          │   └────────────────────────────────  │  Leader   │
          │    [PreVote 路径] Follower ─MsgHup─► PreCandidate(不动 Term)
          │    PreCandidate ─赢得 PreVote─► Candidate(此刻才 Term+1)
```

理解状态机的钥匙在 `raft` 结构体的三组字段:协议状态 Term/Vote/state/lead、日志与进度(raftLog/tracker)、以及**两个函数指针 `tick func()` 与 `step stepFunc`**(raft.go:425-426)。**角色切换的实质就是换这两个指针**:每个 become* 函数只做"绑指针 + 重置状态",消息处理天然按角色分派——没有一坨 if-state。这是全文最核心的设计。

底层公共操作 `reset(term)`(781-810):Term 变化时清空 Vote、双计数器归零并**重掷随机选举超时**、清空计票、把每个 peer 的 Progress 归零。每个变轨函数都调它——因为无论当选、降级还是连任,复制进度与计票只对"当前 Term 的 leader"有意义;连任(becomeLeader 里 `reset(r.Term)`)是刻意保留 Term 的"软重启"。

四个 become* 的行为清单:

- **becomeFollower**(891-900):绑 stepFollower → reset → 绑 tickElection → 记 lead。唯一显式收 lead 参数的变轨;
- **becomeCandidate**(902-915):断言非 Leader → `reset(Term+1)`(**这里才真正递增 Term**)→ 自投票;
- **becomePreCandidate**(917-931):与真 candidate 共用 stepCandidate,但**不改 Term、不改 Vote**(923-925)——试探失败时集群 Term 完全不动;
- **becomeLeader**(933-971):断言非 Follower → 绑 stepLeader、`reset(Term)`、绑 tickHeartbeat → 自己的 Progress 置 StateReplicate → **保守地把 pendingConfIndex 设为 lastIndex**(新 leader 无从知晓日志尾部是否藏着未提交的配置变更)→ **append 一条空 entry(noop)**。

启动路径(newRaft,439-498):校验 Config → Storage 构建 raftLog 读 InitialState → confchange.Restore 重建 ProgressTracker → loadState → 最后 `becomeFollower(r.Term, None)`——**任何节点都以 follower 身份醒来**。

## 2.2 Step 消息分发:一扇门,两层分发

`Step` 是唯一入口(1089)。**第一层按 Term 比较**做安全闸(1097-1187),**第二层按消息类型**分派(1189-1269),default 进入当前角色的 `r.step`。

**Term 闸门**的关键分支:更高 Term 的 MsgVote 先查**选举租约**(`inLease = checkQuorum && lead != None && electionElapsed < electionTimeout`,1101-1112,租约期内忽略拉票);MsgPreVote 永远不更新本地 Term;其余一律 becomeFollower 降级。更低 Term 的默认忽略,但有一个精妙的特例:开了 CheckQuorum/PreVote 的节点收到过期 leader 的心跳时,**回一条盖上本地更高 Term 的 MsgAppResp**——用响应把新 Term"告诉"老 leader 逼它步降(1134-1156),复用既有处理路径而非新消息类型。

**投票裁决**(1213-1222):可投 = 重复投同一人 ∨ (本 Term 未投且认为无 leader) ∨ (PreVote 且消息 Term 更高);**且**候选人日志 isUpToDate(先比最后条目 Term 再比 Index,log.go:442-445)。三个精妙点:learner 必须被允许投票——刚被提升的 voter 可能还没收到配置 entry,只有通过"被请求投票"才能意识到自己已是 voter(1223-1240 的长注释含完整反例);**响应携带 m.Term 而非本地 Term**(PreVote 用未来 Term 拉票,盖本地旧 Term 会被丢弃);只有真 MsgVote 才记录 r.Vote,PreVote 不产生持久化痕迹。

## 2.3 tick 的两个节拍与随机化

**tickElection**(Follower/Candidate,850-859):每拍 electionElapsed++,超过随机选举超时即向自己 Step 一条 **MsgHup** 自触发拉票。

**tickHeartbeat**(Leader,862-889):双计数。electionElapsed 达到 electionTimeout 时(**CheckQuorum 的检查周期是 electionTimeout 而非 heartbeatTimeout**)Step(MsgCheckQuorum);heartbeatElapsed 达到 heartbeatTimeout 时 Step(MsgBeat)——**MsgBeat 是 leader 发给自己的内部消息**,与网络消息共用 Step 通道,心跳发送因此共享同一条单线程序列化路径。

**随机化**:`randomizedElectionTimeout = electionTimeout + Intn(electionTimeout)`,落在 [E, 2E-1],每次 reset 重掷(2046-2055)。随机源是包装了互斥锁的 lockedRand,底层 crypto/rand。Config.validate 强制 ElectionTick > HeartbeatTick 并建议 10 倍。

一个消息复用的典范:心跳广播同时承担**三种职责**——leadership 续约(follower 侧 electionElapsed=0)、commit 通告(心跳携带 commit,取 `min(pr.Match, r.raftLog.committed)`,绝不能把 follower 还没复制到的 commit 告诉它)、ReadIndex 确认(heartbeatCtx 捎带,read_only.go:93-101)。

## 2.4 append 处理:track 与 maybeCommit 的联动

发送端 maybeSendAppend(618-662):Progress paused 则不发;prevIndex 的 Term 取失败则降级发快照;throttled 的 StateReplicate 只发空 MsgApp 以防 Inflights 全丢卡死。

接收端 handleAppendEntries 三岔:prev.index < committed 直接回;maybeAppend 成功回 lastnewi;失败回 reject 并用 `findConflictByTerm` 在双方日志上做**二分式探测优化**(raft.go:1390-1510 有两大段图文注释)——把 O(分歧长度) 次往返压到 O(分歧 term 数)。

回执端(Leader 收 MsgAppResp)是核心:

```go
if pr.MaybeUpdate(m.GetIndex()) || ... {
    switch {
    case pr.State == tracker.StateProbe:      pr.BecomeReplicate()
    case pr.State == tracker.StateReplicate:  pr.Inflights.FreeLE(m.GetIndex())
    }
    if r.maybeCommit() { releasePendingReadIndexMessages(r); r.bcastAppend() }
}
```

`maybeCommit`(775-779)取 `trk.Committed()`——**所有 voter 的 Match 组成的 quorum 中位数**——再要求 matchTerm 且大于当前 committed 才前移。这里隐含一台 **Progress 三态小状态机**(与 raft 主状态机正交,第 03 章详述):Probe 摸索期 / Replicate 流水线期 / Snapshot 追赶期,三态迁移全部落在 MsgAppResp 分支。

## 2.5 设计动机五条

1. **为什么 becomeLeader 要 append noop**(961-965):三层动机——commit index 只能通过当前 Term 的 entry 推进(论文 §5.4.2 的 commit 前向安全问题);ReadIndex 依赖它(本 Term 无 commit 时必须挂起 ReadIndex 请求);配置变更同样不能在无 commit 的 Term 提交。代价是每次选举多一条日志与一次 fsync;
2. **为什么 PreVote**:被隔离者的"复仇性 Term"——没有 PreVote 时,隔离恢复后的高 Term 拉票会迫使全集群升 Term 打断现任 leader;PreVote 把"试探"与"正式选举"分离,分区回归对集群零扰动;
3. **CheckQuorum 的代价**:leader 主动退位在多数派故障时引入不必要的重选举;与选举租约耦合(ReadOnlyLeaseBased 强制要求开启,raft.go:336-338);RecentActive 是按周期清零的有界窗口,判活下限即一整个 electionTimeout;
4. **持久化次序:msgsAfterAppend 的保守设计**(546-592):MsgAppResp/VoteResp/PreVoteResp 三类响应必须等 Term/Vote/entries 落盘才发出——**自确认消息也走同一条栅栏**(leader append 后给自己回 MsgAppResp,candidate 给自己发 VoteResp),无需任何特判即满足论文 §3.8;连 reject 响应也一并排队(未经形式化验证,宁保守);
5. **两级写放大防线**:MaxInflightMsgs/Bytes 限制每 follower 在途消息(附 Little's law 量化注释:RTT 100ms、窗口 1MB 时吞吐上限 10MB/s)+ MaxUncommittedEntriesSize 限制未提交尾部总字节(防刚加入的 learner 拉长 leader 日志)——**宁可让客户端提案失败,也不让 leader 的内存与恢复成本无界**。

## 2.6 FAQ

**Q1:MsgProp 为什么不带 Term?**
它是"转发给 leader 的本地提案"而非共识消息;Term=0 使它天然通过 Step 的本地消息通道,follower 收到后原样转发给 lead。

**Q2:candidate 收到同 Term 的 MsgApp 会怎样?**
立刻 becomeFollower 再处理——同 Term 存在 leader 说明本次选举已败,主动让位不浪费一轮超时。

**Q3:leader 如何确认自己写的 entry?**
append 后给自己回一条 MsgAppResp,进入 msgsAfterAppend,等落盘后回环到 stepLeader 完成自增与 maybeCommit——self-ack 与普通 ack 共用一条路径。

**Q4:learner 能投票吗?能发起选举吗?**
能投票、不能竞选:刚提升的 voter 只能靠"被请求投票"参选;竞选被 promotable() 挡住,hup 与 campaign 双重拦截。

**Q5:选举失败为什么是 becomeFollower(r.Term) 而不是 Term-1?**
Term 只增不减是不变量;保持高 Term 还能防止再次收到同批过期拉票。

**Q6:ReadIndex 请求什么时候被挂起?**
本 Term 尚无已提交条目时,等 maybeCommit 成功后统一释放——noop entry 让这个等待窗口最短。

**Q7:领导权转移为什么不走 PreVote?**
转移场景确知不是分区回归,MsgTimeoutNow 到达即绕过 PreVote 直接拉票;一个 electionTimeout 内未完成即 abort。

## 2.7 小结与深挖方向

本章结论:**状态机 = 两个函数指针 + reset 的"软重启"语义 + 单入口两层分发**;安全性 = 持久化栅栏(msgsAfterAppend)+ Term 闸门 + 随机化超时。深挖:

1. msgsAfterAppend 与 AsyncStorageWrites 复合时序:同 Term 重叠截断时旧响应如何防止把被覆盖 entry 标记 stable;
2. findConflictByTerm 双端优化的单调收敛性(TLA+ 规约可对照,tla/ 目录);
3. CheckQuorum 周期内的"假死"误判(反向链路拥塞场景);
4. switchToConfig 后计票表跨配置残留的 quorum 判定;
5. crypto/rand 全局锁在数千 multi-raft group 下的开销。

> 下一章下沉日志层:raftLog 三段式、Progress 三态机与 flow control。
