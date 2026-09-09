# D 篇 · Node/RawNode 协议、etcd server 集成与测试验证

> 调研基线:raft 库 commit `3cbf6a74`,etcd commit `e9e56564`(2026-09-03)。所有行号均以该版本为准。

## ① 全景:Node / RawNode / raft 三层 API 的分工

go.etcd.io/raft 库对外暴露三层 API,自上而下分别是「并发安全的通道封装」「线程不安全的裸状态机」「核心算法」:

| 层 | 载体 | 并发模型 | 角色 |
|---|---|---|---|
| Node 接口 | `node.go:132-243` | 单个 `run()` 协程 + 8 条 channel | 给应用(如 etcd)的并发安全门面 |
| RawNode | `rawnode.go:34-42` | 无锁,单线程调用 | 给高级应用/测试框架的裸状态机 |
| raft 结构体 | `raft.go` | 由 RawNode 独占 | Raft 核心算法(选举/复制/成员变更) |

`doc.go` 的包注释把 Node 的使用契约写成了一份「规范」:使用者必须读 Ready 通道、按四步处理(1. 写 HardState/Entries/Snapshot 到持久化;2. 发送 Messages;3. 应用 CommittedEntries;4. 调 Advance),并定期调 `Tick()`(doc.go「Usage」一节)。RawNode 的注释只有一句:"RawNode is a thread-unsafe Node"(rawnode.go:31-33),方法与 Node 一一对应但去掉了 channel。

`node` 结构体就是 RawNode 外面套的一层协程外壳:`newNode(rn)` 持有 propc/recvc/confc/readyc/advancec/tickc/status/stop 等 10 条通道(node.go:297-310),`StartNode/RestartNode` 最后一行都是 `go n.run()`(node.go:271-289)。etcd 侧则通过 `raftNode` 适配器(etcdserver/raft.go:81)消费 Node 接口,再把 Ready 中的内容拆给 WAL、rafthttp 与 EtcdServer.apply 三条下游。适配器与库的对接采用了 Go 的结构体嵌入:`raftNodeConfig` 直接内嵌 `raft.Node`(raft.go:112),于是 raftNode 自身即满足 Node 接口,raft 循环里 `r.Ready()`/`r.Advance()`/`r.Tick()` 都是对内嵌接口的直接调用;同时 etcd 只把 `raft.MemoryStorage` 用作"raft 视角的稳定存储缓存"(raftNodeConfig.raftStorage,raft.go:113),真正的磁盘写交给 WAL——这是 etcd 集成里最容易被误解的一层间接。bootstrap.go 提供 `Bootstrap(peers)`:在空 Storage 上伪造 len(peers) 条 EntryConfChange 并置 `committed = len(ents)`,让应用能立即 Campaign(bootstrap.go:52-80);注释同时建议生产应用改为手工构造 Storage 初始状态而非调用它(bootstrap.go:29-31)。

## ② node.go 协程主循环逐段解读

### 2.1 通道拓扑

```
应用协程                          node.run() 协程                        RawNode/raft
   │ Propose/ProposeConfChange ──▶ propc (msgWithResult,带 result 回执)
   │ Step/ReadIndex/ForgetLeader ▶ recvc (网络来的消息)
   │ ApplyConfChange ────────────▶ confc ──(回执)──▶ confstatec
   │ Tick(定时器) ──────────────▶ tickc (缓冲 128,node.go:320-323)
   │ Status() ───────────────────▶ status (chan chan Status)
   ◀── readyc (chan Ready) ─────── HasReady→readyWithoutAccept 填充 rd
   │ Advance() ──────────────────▶ advancec
   │ Stop() ─────────────────────▶ stop ──▶ close(done)
```

tickc 特意做成 128 缓冲:newNode 注释解释是让 raft 在忙于处理消息时"缓存一些 tick,空闲后再补处理"(node.go:320-323);`Tick()` 用 select-default 实现非阻塞,溢出时打警告 "A tick missed to fire. Node blocks too long!"(node.go:458-465)。propc 之所以单独一条通道,是因为它承载 `msgWithResult`:Propose 默认走 `stepWait` 携带 result 回执通道,把 `r.Step` 的落盘/拒绝错误同步返回给调用方(node.go:471-473、508-551);而 Step/ReadIndex 等 fire-and-forget 消息走 recvc 不等待(node.go:514-524)。

### 2.2 run() 主循环:readyc 的"武装"与 propc 的"闸门"

run()(node.go:343-454)每轮做三件事:

1. **武装 readyc**:仅当 `advancec == nil && n.rn.HasReady()` 时才调 `readyWithoutAccept()` 组装 Ready 并把 readyc 指针置回非 nil(node.go:354-365)。注释解释了为什么不在发出后就清空:"可能服务其他通道后绕一圈重新组装,产出更大的 Ready 批次,也简化测试"(node.go:355-362)——这是一个吞吐与延迟的显式权衡。
2. **propc 闸门**:`lead != r.lead` 时打印选举日志并按有无 leader 决定 propc 是否为 nil(node.go:367-380)。propc=nil 后 select 不再命中该 case,提案被背压在调用方——follower 无 leader 时天然拒绝提案。
3. **select 分发**:propc 直接 `r.Step` 并回写 err(node.go:386-393);recvc 过滤"未知来源的响应消息"(node.go:394-399);confc 调 `applyConfChange`,若本节点被移出配置则置 `propc = nil` 阻断后续提案(node.go:400-428),并通过 confstatec 把 ConfState 送回 ApplyConfChange 调用方(往返同步,node.go:429-432、562-573)。

### 2.3 Ready 四步在 run() 里的落点

doc.go 规范的四步对应关系:

| doc.go 四步 | node.go 落点 |
|---|---|
| 1. 持久化 HardState/Entries/Snapshot | 使用方拿到 readyc 里的 rd 后自己做(run 只负责交付) |
| 2. 发送 Messages | 同上,顺序约束写在 Ready 字段注释(node.go:98-110) |
| 3. 应用 CommittedEntries | 同上,ConfChange 须回 ApplyConfChange(doc.go「Usage」) |
| 4. Advance | `case readyc <- rd` 成功后若非异步写模式则武装 advancec(node.go:435-442);`case <-advancec` 调 `n.rn.Advance(rd)` 并清空(node.go:443-446) |

`case readyc <- rd` 是唯一向应用"交付"的出口:发送成功即 `acceptReady(rd)`(登记 prevSoftSt/prevHardSt、清空 msgs、acceptUnstable,rawnode.go:400-438),然后按 `asyncStorageWrites` 决定是否等待 Advance(node.go:437-442)。异步写模式下 run 不再武装 advancec,Advance() 甚至会 panic(rawnode.go:481-483)——应用改用 MsgStorageAppend/Apply 的响应消息驱动。

### 2.3.1 select 分发核心(代码原文摘录)

```go
case readyc <- rd:
    n.rn.acceptReady(rd)
    if !n.rn.asyncStorageWrites {
        advancec = n.advancec
    } else {
        rd = Ready{}
    }
    readyc = nil
case <-advancec:
    n.rn.Advance(rd)
    rd = Ready{}
    advancec = nil
```

(node.go:435-446)

这段是"Ready 交付-回收"握手的最小实现:`readyc = nil` 把通道从 select 集合中摘除,保证在应用方 Advance 之前不会组装/交付第二个 Ready;异步模式则把 rd 置零、readyc 置 nil 后直接进入下一轮,Advance 分支永久失活。注意 `rd` 是循环外变量被 case 反复覆盖——"重复组装无害"正是靠每次重新调 `readyWithoutAccept()` 取最新快照实现的。

### 2.4 rawnode.go:Ready 组装与异步写管线

`readyWithoutAccept()`(rawnode.go:139-187)是一次纯读快照:Entries 取 `nextUnstableEnts`,CommittedEntries 取 `nextCommittedEnts(applyUnstableEntries())`,Messages 直接搬 `r.msgs`,SoftState/HardState 仅在与 prev 不等时填入(避免空拷贝,rawnode.go:147-154),最后算 `MustSync`。`MustSync` 的注释逐字引用 Raft 论文的持久化状态清单(currentTerm/votedFor/log entries),条件是"有新条目或 term/vote 变化"(rawnode.go:189-198)。

异步写(AsyncStorageWrites)是本版最重的演进:Ready 的 Entries/HardState/Snapshot 被打包进 `MsgStorageAppend` 消息、CommittedEntries 打包进 `MsgStorageApply`,与网络消息同走 `rd.Messages`,目标是虚拟的 `LocalAppendThread`/`LocalApplyThread`(rawnode.go:223-260、372-382)。两条关键工程注释值得整段引用的:

- **顺序即性能**:newStorageAppendMsg 把 msgsAfterAppend 挂为 Responses,并特意让自环 MsgAppResp 先于 MsgStorageAppendResp 被处理,"这使 MsgAppResp 处理能在 unstable log 尚未摘除时命中 r.raftLog.term() 的 fast-path"(rawnode.go:249-253)。
- **ABA 竞态**:newStorageAppendRespMsg 的注释用九步时序(rawnode.go:280-354)论证为什么响应必须携带 Term——异步 append 在途时 leader 可能易主、log 被覆写,`stableTo` 若不校验 term 就会摘错 unstable 日志;同时为避免"term 变化丢响应导致 unstable 永不收缩"的活性问题,选择在**所有** AppendResp(含仅更新 HardState 的)上尝试 truncate(rawnode.go:320-345)。testdata 下专门有 `async_storage_writes_append_aba_race.txt` 回归此场景。

同步模式下 Ready 契约是"Messages 必须在 Entries 落盘后才能发送"(node.go:100-101),实现上是 acceptReady 把自环 msgsAfterAppend 暂存 `stepsOnAdvance`,等 Advance() 时才 Step 回状态机(rawnode.go:410-427、484-488)。另一个反直觉设计:`applyUnstableEntries()` 在同步模式下为 true,即允许"已提交但未落本地盘"的条目先应用,靠 Ready 消费顺序约束保证安全;异步模式下必须等 append 线程确认(rawnode.go:443-445)。

## ③ raftNode 适配器:etcd 如何驱动 tick / ready / apply

### 3.1 数据流图

```
                       ┌────────────────────────────────────────────────┐
 time.Ticker ──tick──▶ │ raftNode.start() 主循环 (etcdserver/raft.go:177)│
 rafthttp ──Process──▶ EtcdServer.Process(server.go:699) ──Step──▶ raft.Node
                       │                                                │
                       │ rd := <-r.Ready()                              │
                       │  ├ SoftState → metrics/updateLead/updateLeadership (raft.go:186-207)
                       │  ├ ReadStates → readStateC (raft.go:209-217)    │
                       │  ├ toApply{entries,snapshot,notifyc} ──▶ applyc ─┼──▶ EtcdServer.run()
                       │  ├ islead: transport.Send(processMessages)      │    (server.go:839)
                       │  │   (leader 可与写盘并行,raft.go:237-243)        │     →FIFOScheduler
                       │  ├ SaveSnap / Save(HardState,Entries)→WAL       │     →applyAll
                       │  ├ snapshot: Sync→notifyc→MemoryStorage         │      (server.go:968)
                       │  │   .ApplySnapshot→Release (raft.go:264-285)   │
                       │  ├ follower: 先收发消息→notifyc→(confChange 等应用)│
                       │  │   再 Send (raft.go:297-324)                  │
                       │  └ r.Advance() (raft.go:331)                    │
                       └────────────────────────────────────────────────┘
```

### 3.2 Ready 消费循环的骨架(代码原文摘录)

```go
for {
    select {
    case <-r.ticker.C:
        r.tick()
    case rd := <-r.Ready():
        // ...SoftState/ReadState/toApply 处理...
        if islead {
            r.transport.Send(r.processMessages(rd.Messages))
        }
        if !raft.IsEmptySnap(raftSnap) {
            if err := r.storage.SaveSnap(raftSnap); err != nil { ... }
        }
        if err := r.storage.Save(rd.HardState, rd.Entries); err != nil { ... }
        // ...snapshot 后续/raftStorage.Append...
        r.Advance()
    case <-r.stopped:
        return
    }
}
```

(节选自 etcdserver/raft.go:181-339,省略号处见 3.3 的顺序说明)

### 3.3 逐段解读

**启动装配**。bootstrap.go 按"无 WAL/新集群/有 WAL"三分支决定从成员列表还是 WAL 恢复(bootstrap.go:514-526);`raftConfig` 固定 `HeartbeatTick:1`、`CheckQuorum:true`、`PreVote` 可配(bootstrap.go:564-576);`newRaftNode` 按 peers 是否为空选 StartNode/RestartNode(bootstrap.go:578-584),并把 `n.Status` 挂到 expvar(raft.go:44-64)。`EtcdServer.run` 构造 `raftReadyHandler`(四个回调:getLead/updateLead/updateLeadership/updateCommittedIndex),其中 updateLeadership 里做了 lessor.Demote/compactor.Pause 等业务降级(server.go:762-799),随后 `s.r.start(rh)`(server.go:800)。

**tick 驱动**。`time.Ticker` 按 heartbeat 周期触发 `r.tick()`,后者持 `tickMu` 调 Node.Tick 并刷新 latestTickTs(raft.go:159-164)——锁只为 getLatestTickTs 读取(活性监控),不与 Node 内部竞争。tickc 的 128 缓冲在此兜底:apply/网络再慢,tick 也只是堆积而非丢失。

**Ready 消费循环**(raft.go:177-341),这是 etcd 集成的核心,注意几个顺序不变量:

1. **applyc 先行**:`toApply` 打包 CommittedEntries 与 snapshot 后先塞进 applyc(raft.go:231-235),EtcdServer.run 消费后交 FIFOScheduler 调 applyAll(server.go:837-851)。raft 循环与 apply 循环从此并行,靠 `notifyc` 两次握手同步(见下)。
2. **leader 先发消息**:`if islead { r.transport.Send(...) }` 在写盘**之前**,注释引用论文 10.2.1——leader 可以并行写自己的盘和复制给 follower(raft.go:237-243)。
3. **快照必须最先落盘**:"Must save the snapshot file and WAL snapshot entry before saving any other entries or hardstate to ensure that recovery after a snapshot restore is possible"(raft.go:245-246)。
4. **#10219 的教训**:snapshot 场景下在 `storage.Release` 释放旧 WAL 段之前强制 `storage.Sync()`,否则重启会panic "tocommit(107) is out of range [lastIndex(84)]"(raft.go:264-271)。
5. **follower 的对称顺序**:follower 必须先处理完入向消息再通知 notifyc,且若本批含 EntryConfChange,要额外等 applyAll 完成(避免用已被移除节点的投票)(raft.go:297-324)。confChanged 场景还引入 `raftAdvancedC`,让 server 侧 applyConfChange 知道 raft 已 Advance(raft.go:333-336、toApply 定义 66-79)。
6. 最后统一 `r.Advance()`(raft.go:331)。

**processMessages 的裁剪**(raft.go:357-402):倒序遍历并丢弃重复 MsgAppResp(一个批次只发最后一条,`sentAppResp` 去重);MsgSnap 不走 transport 而是转投 `msgSnapC`,由 server 主循环把 v2 store 快照与 v3 KV 快照合并后再发(raft.go:373-384、server.go:984-988);对每条 MsgHeartbeat 用 `contention.TimeoutDetector` 检测"是否在 2 个心跳内发出",超时告警并计 `heartbeatSendFailures`(raft.go:385-398)——这是 etcd 定位"慢盘拖垮 leader"的经典观测点。maxSizePerMsg=1MB(注释:100MB 吞吐/10ms RTT 足够)、maxInflightMsgs=4096/8 对齐 rafthttp 缓冲(raft.go:35-42)。

**停止路径与加速路径**。`raftNode.stop()` 与 raft.Node.Stop 同构:先发 stopped 信号,再等 done 确认(raft.go:408-418);onStop 依次停 Node、停 ticker、停 transport、关 storage,任何一步失败即 Panic(raft.go:420-428)——停机顺序保证 WAL 关闭前所有在途写已完成。此外暴露了一个小众接口 `advanceTicks`:一次补发 n 个 tick,注释说明用于多数据中心部署"快进选举 tick、加速选出新 leader"(raft.go:441-449)。

**apply 侧闭环**:applyAll 先 applySnapshot/applyEntries,再 `VerifyBackendConsistency`、`applyWait.Trigger`(线性一致读等待点),然后等 `<-apply.notifyc`(确认 raft 侧写盘完成才触发快照,防 applied > raft last index,server.go:976-981),最后 snapshotIfNeededAndCompactRaftLog(SnapshotCount 阈值,server.go:1200-1217)。

## ④ WAL 与持久化概览

**文件与命名**。WAL 目录由多个段文件组成,文件名 `%016x-%016x.wal` = (seq, 起始 raft index)(wal/util.go:parseWALName/walName)。段文件预分配 64MB(`SegmentSizeBytes`,wal.go:51-55);`Save` 时若游标越过阈值即 `cut()`:旧 tail truncate 到实际长度并 fdatasync,经 filePipeline 预创建 tmp 文件、写入 crc 头 + metadata + 当前 HardState,`os.Rename` 原子改名后对目录 fsync(wal.go:785-867)。

**Record 格式**(walpb/record.proto):

```proto
message Record { optional int64 type = 1; optional uint32 crc = 2; optional bytes data = 3; }
message Snapshot { optional uint64 index = 1; optional uint64 term = 2; optional raftpb.ConfState conf_state = 3; }
```

type 枚举按 iota 顺序为 MetadataType=1/EntryType/StateType/CrcType/SnapshotType(wal.go:39-45)。物理层是"8 字节长度帧 + 记录":`encodeFrameSize` 强制 8 字节对齐,padBytes 编码进长度字段最高位 `0x80|padBytes)<<56`(encoder.go:112-118);decoder 侧 `frameSizeBytes = 8`、`minSectorSize = 512`(decoder.go:34-37)。对齐的目的写在注释里:长度字段永不 torn write,WAL 才能区分"撕裂写"与"普通数据损坏",坏尾可由 repair.go 修复。CRC 用 Castagnoli 表(wal.go:65)链式累积,每个 Record 的 Crc 基于前文,saveCrc 在每个段头显式记录断点(wal.go:1063-1065)。

**hardstate 落点与 fsync 策略**。`WAL.Save`(wal.go:995-1037)是 raftNode `storage.Save` 的实现:先逐条 saveEntry(顺带维护 enti),再 saveState——**空 HardState 直接跳过不写**(wal.go:985-993);是否 fdatasync 由 raft.MustSync 决定(wal.go:1010),非 mustSync 且未到段尾时完全跳过 sync(wal.go:1026-1033),这是提交路径唯一的(也是最贵的)fsync 点,`sync()` 用 Fdatasync 并对 >1s 的慢盘打警告(wal.go:869-894)。**恢复路径**。`ReadAll` 从 snapshot 指定的段开始重放,"decodeRecord 检测到零记录时返回 io.EOF"被当作正常结尾处理(wal.go:557,该注释位于 ReadAll 内);`openAtIndex → selectWALFiles` 按 walpb.Snapshot 的 Index 用 `searchIndex` 定位起始段,`isValidSeq` 校验段号连续(wal/util.go)。坏尾(撕裂写)由 repair.go 修复——依赖前述 8 字节对齐帧才能区分"半条记录"与"逻辑损坏"。启动时的严格性可在 server 侧看到:applyEntries 若发现 committed index 出现空洞直接 Panic("unexpected committed entry index",server.go:1174-1182),即 etcd 选择 fail-fast 而非带病运行。快照与 WAL 的分工值得单独说明:快照数据本身不进 WAL,SaveSnap 只向 WAL 写一条 SnapshotType 索引记录(storage.go:68-83 的注释自称"saves the snapshot file to disk and writes the WAL snapshot entry",但当前实现只剩 WAL 入口——快照文件职责已向 backend db 文件迁移,server.go:292 "TODO: Replace with flush db in v3.7 assuming v3.6 bootstraps from db file" 是这一演进的自白);`storage.SaveSnap` 把 raft 快照映射为 walpb.Snapshot(含 ConfState,3.5.0 起必填,见 walpb.ValidateSnapshotForWrite)再写入。

## ⑤ 测试与验证体系

**rafttest 事件驱动仿真(datadriven)**。`InteractionEnv` 把 n 个 RawNode、在途消息池和输出缓冲装进一个单线程沙盘(rafttest/interaction_env.go:37-55);`TestInteraction` 用 cockroachdb/datadriven 跑 testdata/*.txt,失败时提示 `go test ./raft -rewrite` 审阅 diff(interaction_test.go:34-41)。指令集覆盖 add-nodes/campaign/propose/stabilize/deliver-msgs/tick/process-ready 等 20+ 个 handler。`Stabilize` 是灵魂:循环执行"各节点 ProcessReady → 按接收者投递消息 → 处理 AppendWork → 处理 ApplyWork"直到不动点(interaction_env_handler_stabilize.go:49-115),从而把并发时序确定化;`ProcessReady` 同时支持同步模式(直接 processAppend/processApply/Advance)与异步模式(AppendWork/ApplyWork 队列,interaction_env_handler_process_ready.go:37-79)。testdata 里 `probe_and_replicate.txt` 复刻论文 Figure 7 的日志分叉场景,注释里画了七个节点的日志矩阵。测试文件的语法是"指令 + ---- + 期望输出"的纯文本,例如:

```
add-nodes 7 voters=(1,2,3,4,5,6,7) index=10
----
ok

campaign 1
----
ok
```

(testdata/probe_and_replicate.txt 节选)

每条指令就是 InteractionEnv 的一个 handler 名加参数,期望输出默认是 ok,实际返回的日志(节点状态变化、消息收发)在 rewrite 时整体刷新进文件,评审 diff 即评审行为变化。旧式 goroutine 沙盘(rafttest/node.go:startNode,5ms ticker)仍保留供 `TestNetwork` 类测试。

**diff_test.go 与 paper 测试**。`ltoa` 把 raftLog 序列化为 lastIndex/applied/applying/stable/unstable 等多行文本,`diffu` 调系统 diff 生成可读差异(diff_test.go:20-56);raft_paper_test.go:669 在每个 paper 用例后断言 `ltoa(lead) == ltoa(follower)`,即"领导者与跟随者收敛后日志视图逐字节一致"。

**TLA+ 规约与轨迹验证**。tla/ 目录三件套:`etcdraft.tla`(规约本体,含成员重配置等 etcd 特化行为)、`MCetcdraft.tla`(TLC 模型检查入口,validate-model.sh 建议跑数小时)、`Traceetcdraft.tla`(把 NDJSON 轨迹作为状态空间约束重放)。实现侧通过 `go build -tags=with_tla` 启用 state_trace.go 的 TracingEvent 埋点(无 tag 时编译 state_trace_nop.go 空实现),应用提供 TraceLogger 采集事件(tla/README.md「Enable TLA+ Trace Validation」一节)。这是"模型检查保证算法正确 + 轨迹验证保证实现贴合模型"的两段式论证。

**etcd 侧:robustness(原 linearizability)+ Antithesis**。当前 etcd 仓库中 `tests/linearizability` 已演进为 `tests/robustness`(目录存在性即证据:tests/ 下只有 robustness 与 antithesis,无 linearizability)。README 的"track record"表格列出 17 个由该框架或 Antithesis 发现的正确性缺陷(如 #14370 单节点崩溃丢写、#14685 defrag 期间崩溃致 revision 不一致、#20418 进程暂停致 stale read),并明确说明 Antithesis 平台在其确定性仿真环境里持续跑同一套测试。方法学是:故障注入(failpoint/网络分区)下跑流量 → 校验 KV/watch API 保证(model/ + validate/)。这正与 ③ 节 raft.go 里密布的 `gofail:` 注释点位(raftBeforeSave/raftAfterSync/raftBeforeApplySnap 等十余处)衔接——生产代码里的 failpoint 就是这套验证体系的观测面。

## ⑥ 设计动机与取舍

1. **通道门面 vs 裸状态机**:Node 用单协程串行化一切输入输出,把"何时能并发、何须加锁"从应用侧收走;代价是每条消息一次 channel 交接。RawNode + AsyncStorageWrites 为吞吐敏感者(CockroachDB 等)预留了绕过通道化落盘的路径,etcd 至今未启用(整个 server/ 无 AsyncStorageWrites 引用,grep 证据),维持同步 Ready/Advance——稳重优先。
2. **Ready 批次化**与"重复组装也无害"的设计(node.go:355-362),换来大 IO 批与确定的可测性。
3. **文件即规范**的注释文化:ForgetLeader 的 25 行注释(node.go:192-216)论证了 forget-leader + PreVote/CheckQuorum 的活性场景;newStorageAppendRespMsg 的 75 行 ABA 论证;MustSync 引用论文原文。接口注释是可执行的规格。
4. **同步顺序即正确性**:etcd raft.go 循环里的每一行顺序都有注释背书(快照先落盘、follower 先收完再通知、confchange 等 apply),并被 gofail failpoint + robustness 框架反复攻击验证;raft.go:264-271 的 #10219 注释直接引用了当年 panic 文案,是"用注释保存事故现场"的范例。
5. **遗留痕迹的坦诚**:Advance 保留无用参数只为兼容(rawnode.go:477-481 "In earlier versions of this library, they were computed from the provided Ready struct");run() 里对 propc 被移除节点后置 nil 的机制自我评价 "This isn't very sound and likely has bugs"(node.go:408-411);TickQuiesced 标注 DEPRECATED(rawnode.go:77)。这些未删除的旧设计是代码考古的可靠地层。

## ⑦ FAQ

**Q1:Propose 返回 nil 就代表提案会提交吗?**
否。doc.go 明确"提案可能丢失且无通知,重试是应用的责任"(Node.Propose 注释,node.go:138-140)。propc 的 result 回执只返回 `r.Step` 的同步错误(如 leader 无权提出、成员变更冲突),提交与否取决于后续复制。

**Q2:Ready.CommittedEntries 能跳过吗?**
不能。Node.Ready 注释:"下一批 Ready 的 committed entries 不得在上批全部应用完之前开始应用"(node.go:162-163);etcd 的 toApply/FIFOScheduler 严格保序消费(server.go:837-851)。

**Q3:tickc 为什么要 128 缓冲,丢了 tick 会怎样?**
缓冲让 raft 在忙于处理消息/落盘时不丢心跳节奏(选举超时是按 tick 计数的);缓冲满时 Tick() 直接告警"Node blocks too long"而非阻塞调用方(node.go:458-465),因为这往往意味着落盘路径已病态。

**Q4:etcd 为什么 follower 在写盘前不发消息,leader 却可以?**
leader 侧依据论文 10.2.1:leader 与 follower 的写盘、复制可并行(raft.go:237-243)。follower 则必须先处理完入向消息并等待可能存在的 confchange 应用完,否则可能错误计数选票(raft.go:304-310)。

**Q5:MustSync=false 时 HardState 可以不落盘吗?**
可以非持久化写(Ready.MustSync 注释,node.go:112-114),MustSync 只在有新条目或 term/vote 变化时为真(rawnode.go:191-198);commit 推进-only 的心跳批次可以省一次 fsync,WAL.Save 同样复用该判定(wal.go:1010)。

**Q6:WAL 段文件为什么 64MB 且预分配?**
预分配(`fileutil.Preallocate`,wal.go:147)避免运行时文件增长引发的元数据更新与碎片;64MB 在段切换频率与旧段持有句柄内存间取平衡,导出为变量仅为测试可调(wal.go:51-55 注释)。

**Q7:快照恢复后 WAL 旧段什么时候删?**
由 `storage.Release` → `WAL.ReleaseLockTo(snap.Index)` 释放旧段文件锁(wal.go:904-945),且前置条件是强制 fsync HardState,否则会出现 #10219 的 lastIndex 回退 panic(raft.go:264-271)。

**Q8:AsyncStorageWrites 下 Advance 为什么必须禁止?**
此时"落盘完成"由 MsgStorageAppendResp 消息驱动,acceptReady 不再暂存 stepsOnAdvance,Advance 无事可做;误用会被 panic 拦截(rawnode.go:481-483),doc.go「Usage with Asynchronous Storage Writes」给了完整改写模板。

**Q9:MsgSnap 为什么绕过 transport 直达 server 主循环?**
因为 etcd 有 v2 store 与 v3 KV 两套数据,MsgSnap 只带 store 快照,必须与当前 KV 快照合并后才能发(raft.go:373-384 注释;合并逻辑在 snapshot_merge.go/createMergedSnapshotMessage,server.go:984-988)。

**Q10:rafttest 与集成测试(e2e)如何分工?**
rafttest 是单进程确定性仿真(无真实 IO/网络,datadriven 可 rewrite 快照对比),覆盖协议交互;etcd tests/robustness 在真实 etcd 进程上做故障注入+线性一致性校验;Antithesis 再提供确定性仿真平台的长时运行。三层从算法到系统逐级放大。

## ⑧ 深挖问题

1. **propc 闸门的健全性**:run() 中节点被移除后置 `propc=nil`,注释自认"仅在得知 leader 变化时才会复位,机制未必可靠"(node.go:408-411)。若构造"节点被移除又重新加入且 leader 未变"的序列,提案闸门是否可能永久关闭或错误开启?可用 rafttest 构造复现。
2. **异步写管线的 term 校验完备性**:MsgStorageAppendResp 靠携带 term 防 ABA,但 MsgStorageApply/ApplyResp 的 term 恒为 0(rawnode.go:378-394)。apply 是"已提交"条目,理论上不受 leader 更迭影响——能否用 TLA+ 规约在 Traceetcdraft 中形式化这一断言,而非只依赖注释论证?
3. **etcd 对 AsyncStorageWrites 的迁移成本**:etcd 的 raft.go 循环深度耦合"先 applyc 后落盘"的顺序与 notifyc 握手(raft.go:218-336);若启用异步写,Ready 四字段语义改变、Advance 消失,整个 raftNode 状态机需要重排——值得估算收益(leader 落盘与复制并行度)与回归风险。
4. **WAL Save 的空 HardState 短路**:saveState 跳过空 HardState(wal.go:986-988)依赖 raft.MustSync 的判定正确性;若上游某次改动使"commit-only 更新"被误判为 mustSync=false 但 HardState 非空,WAL 恢复后 commit 是否可能回退?可对照 ReadAll 的重放逻辑做性质测试。
5. **tick 缓冲 128 的上界**:tickc 容量 128 是经验值;election timeout 由 ElectionTick×tick 间隔决定,etcd 默认 heartbeat=100ms、ElectionTicks=10,若单次 Ready 处理阻塞超过 12.8s,后续 tick 全部丢失并告警——慢盘 + 大快照场景下是否观测到过该告警与选举抖动的关联?
