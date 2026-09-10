# 第 05 章 · Node 协议与 etcd 集成:从状态机库到生产系统

> 基线:raft 库 commit `3cbf6a74`、etcd commit `e9e56564`(2026-09-03)。行号均以该版本源码为准。

## 5.0 三层 API 的分工

| 层 | 载体 | 并发模型 | 角色 |
|---|---|---|---|
| Node 接口 | node.go:132-243 | 单个 run() 协程 + 8 条 channel | 给应用的并发安全门面 |
| RawNode | rawnode.go:34-42 | 无锁,单线程调用 | 给高级应用/测试框架的裸状态机 |
| raft 结构体 | raft.go | 由 RawNode 独占 | Raft 核心算法 |

RawNode 的注释只有一句:"RawNode is a thread-unsafe Node"。etcd 侧通过 `raftNode` 适配器(etcdserver/raft.go:81)消费 Node 接口,采用 Go 结构体嵌入:`raftNodeConfig` 直接内嵌 `raft.Node`,raftNode 自身即满足 Node 接口。一个最容易被误解的间接层:**etcd 只把 raft.MemoryStorage 用作"raft 视角的稳定存储缓存",真正的磁盘写交给 WAL**(raft.go:113)。

## 5.1 node.go 协程主循环

通道拓扑:

```
应用协程                          node.run() 协程                  RawNode/raft
   │ Propose/ProposeConfChange ──▶ propc (msgWithResult,带回执)
   │ Step/ReadIndex ─────────────▶ recvc (网络消息)
   │ ApplyConfChange ────────────▶ confc ──(回执)──▶ confstatec
   │ Tick(定时器) ──────────────▶ tickc (缓冲 128)
   ◀── readyc (chan Ready) ─────── HasReady→组装 rd
   │ Advance() ──────────────────▶ advancec
   │ Stop() ─────────────────────▶ stop ──▶ close(done)
```

两个设计点:**tickc 的 128 缓冲**让 raft 忙于处理消息时缓存 tick、空闲后补处理,溢出时告警 "A tick missed to fire. Node blocks too long!"(node.go:458-465)——tick 丢失往往意味着落盘路径已病态;**propc 单独一条通道**承载 msgWithResult(Propose 默认走 stepWait 带回执,把 Step 的同步错误返回调用方),而 Step/ReadIndex 走 recvc 不等待。

run() 每轮三件事:武装 readyc(仅当 HasReady,注释解释"绕一圈重新组装可产出更大的 Ready 批次,也简化测试"——吞吐与延迟的显式权衡)、propc 闸门(`lead != r.lead` 时按有无 leader 决定 propc 是否为 nil——follower 无 leader 时提案天然背压)、select 分发。

**Ready 交付-回收握手的最小实现**:

```go
case readyc <- rd:
    n.rn.acceptReady(rd)
    if !n.rn.asyncStorageWrites {
        advancec = n.advancec
    } else {
        rd = Ready{}
    }
    readyc = nil          /* 摘除通道:Advance 之前不会交付第二个 Ready */
case <-advancec:
    n.rn.Advance(rd)
```
(node.go:435-446)

`MustSync` 的判定逐字引用论文持久化清单:有新条目或 term/vote 变化才为真(rawnode.go:189-198)——commit 推进-only 的心跳批次可以省一次 fsync。

**异步写管线(AsyncStorageWrites)是本版最重的演进**:Ready 的 Entries/HardState/Snapshot 被打包进 MsgStorageAppend 消息、CommittedEntries 打包进 MsgStorageApply,与网络消息同走 rd.Messages。两条关键注释:①**顺序即性能**——msgsAfterAppend 挂为 Responses 且自环 MsgAppResp 先于 MsgStorageAppendResp 被处理,"使 MsgAppResp 处理能命中 raftLog.term() 的 fast-path"(rawnode.go:249-253);②**ABA 竞态九步论证**(280-354):异步 append 在途时 leader 可能易主、日志被覆写,stableTo 若不校验 term 就会摘错 unstable 日志——响应必须携带发送时 Term;为避免"term 变化丢响应导致 unstable 永不收缩"的活性问题,选择在所有 AppendResp 上尝试 truncate,testdata 有专门回归 `async_storage_writes_append_aba_race.txt`。**etcd server 至今未启用 AsyncStorageWrites**(server/ 全目录 grep 零命中),仍走同步 Ready/Advance——两仓库处于该特性的不同采纳阶段。

## 5.2 raftNode 适配器:etcd 如何驱动

数据流:`time.Ticker` → tick;rafthttp → EtcdServer.Process → Node.Step;主循环消费 Ready 拆给 WAL/transport/apply 三条下游。

Ready 消费循环(etcdserver/raft.go:177-341)的**顺序不变量全部有"事故注释"背书**:

1. **applyc 先行**:toApply 打包 CommittedEntries 先塞 applyc,raft 循环与 apply 循环并行,靠 notifyc 两次握手同步;
2. **leader 先发消息**:`if islead { transport.Send(...) }` 在写盘**之前**——论文 10.2.1,leader 可并行写自己盘和复制(237-243);
3. **快照必须最先落盘**:"Must save the snapshot file and WAL snapshot entry before saving any other entries... to ensure that recovery after a snapshot restore is possible"(245-246);
4. **#10219 的教训**:snapshot 场景下在 Release 旧 WAL 段之前强制 Sync,否则重启 panic "tocommit(107) is out of range"(264-271)——注释直接引用当年 panic 文案;
5. **follower 的对称顺序**:先处理完入向消息再通知 notifyc,含 EntryConfChange 时额外等 applyAll 完成(避免用已被移除节点的投票)(297-324)。

processMessages 的裁剪(357-402):倒序丢弃重复 MsgAppResp(一批只发最后一条);MsgSnap 绕过 transport 转投 msgSnapC——etcd 有 v2 store 与 v3 KV 两套数据,必须合并快照后再发;对每条 MsgHeartbeat 用 TimeoutDetector 检测"是否在 2 个心跳内发出"——**etcd 定位"慢盘拖垮 leader"的经典观测点**。maxSizePerMsg=1MB(注释:100MB 吞吐/10ms RTT 足够)。

## 5.3 WAL 与持久化概览

- **段文件**:`%016x-%016x.wal` = (seq, 起始 raft index);预分配 64MB;Save 越阈值即 cut():旧 tail truncate + fdatasync,经 filePipeline 预创建 tmp、写 crc 头 + HardState、**os.Rename 原子改名后对目录 fsync**(wal.go:785-867)——与 Redis/SQLite 的"temp+rename+dirfsync 三件套"同源;
- **Record 格式**:8 字节长度帧 + 记录,**8 字节对齐**(padBytes 编码进长度字段最高位)——长度字段永不 torn write,WAL 才能区分"撕裂写"与"逻辑损坏",坏尾可由 repair.go 修复;CRC 用 Castagnoli 链式累积,段头记录断点;
- **hardstate 落点**:空 HardState 直接跳过不写;是否 fdatasync 由 raft.MustSync 决定——**提交路径唯一的 fsync 点**,>1s 的慢盘打警告;
- **快照与 WAL 的分工演进**:快照数据本身不进 WAL,SaveSnap 只写一条 SnapshotType 索引记录;注释与实现已不一致("快照文件职责已迁向 backend db",server.go:292 的 v3.7 TODO 自证)——演进地层可直接从代码读出。

## 5.4 测试与验证体系:三层放大

**rafttest 事件驱动仿真(datadriven)**:InteractionEnv 把 n 个 RawNode、在途消息池装进单线程沙盘;`Stabilize` 是灵魂——循环"ProcessReady → 投递消息 → AppendWork → ApplyWork"直到不动点,**把并发时序确定化**。测试语法是"指令 + ---- + 期望输出"纯文本,rewrite 时整体刷新,评审 diff 即评审行为变化。testdata 里 probe_and_replicate.txt 复刻论文 Figure 7 的日志分叉场景。

**TLA+ 两段式论证**:tla/ 三件套——etcdraft.tla(规约)、MCetcdraft.tla(TLC 模型检查,建议跑数小时)、Traceetcdraft.tla(**把 NDJSON 轨迹作为状态空间约束重放**);实现侧 `-tags=with_tla` 启用埋点。"模型检查保证算法正确 + 轨迹验证保证实现贴合模型"。

**etcd robustness(原 linearizability)+ Antithesis**:故障注入下跑流量 → 校验 KV/watch API 保证;README 的 track record 表格列出 **17 个由该框架发现的真实缺陷**(如 defrag 期间崩溃致 revision 不一致、进程暂停致 stale read)。与 raft.go 里密布的 `gofail:` failpoint 点位衔接——**生产代码即测试观测面**。三层从算法(rafttest)到系统(robustness)到长时运行(Antithesis)逐级放大。

## 5.5 FAQ

**Q1:Propose 返回 nil 就代表会提交吗?**
否。提案可能丢失且无通知,重试是应用的责任;propc 回执只返回 Step 的同步错误。

**Q2:Ready.CommittedEntries 能跳过吗?**
不能:下一批的 committed 不得在上批全部应用完之前开始应用;etcd 的 FIFOScheduler 严格保序。

**Q3:etcd 为什么 follower 在写盘前不发消息,leader 却可以?**
leader 依据论文 10.2.1 可并行;follower 必须先处理完入向消息并等 confchange 应用完,否则可能错误计票。

**Q4:WAL 段为什么 64MB 且预分配?**
避免运行时增长引发的元数据更新与碎片;平衡段切换频率与句柄内存。

**Q5:AsyncStorageWrites 下 Advance 为什么必须禁止?**
"落盘完成"改由 MsgStorageAppendResp 驱动,Advance 无事可做,误用 panic 拦截。

**Q6:rafttest 与 e2e 如何分工?**
单进程确定性仿真(协议交互)→ 真实进程故障注入 + 线性一致校验(robustness)→ 确定性仿真平台长时运行(Antithesis)。

## 5.6 小结与深挖方向

本章结论:**Node = 通道门面(把并发问题从应用侧收走);etcd 集成 = 顺序不变量 + 事故注释 + failpoint 观测面;验证 = datadriven 仿真 × TLA+ 轨迹重放 × 故障注入框架的三层放大**。深挖:

1. propc 闸门的健全性(节点被移除又重新加入且 leader 未变的序列);
2. MsgStorageApply/ApplyResp 的 term 恒为 0 能否用 TLA+ 形式化;
3. etcd 启用 AsyncStorageWrites 的迁移成本估算;
4. WAL 空 HardState 短路与 MustSync 判定的联合性质测试;
5. tick 缓冲 128 的上界与选举抖动的关联观测。

> 下一章(卷末):全景收束与三卷对照。
