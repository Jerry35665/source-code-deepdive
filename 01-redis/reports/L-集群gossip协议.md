# L-集群 Gossip 协议与故障检测深读

> 源码版本：redis commit `e8726d1`（e8726d18e5bab24cbfcb0a0c36f21ce5a1140471）。
> 所有 文件:行号 为仓库相对路径，已逐一 grep/Read 核对。7.x 后集群实现拆分为
> `src/cluster.c`（命令入口/重定向）与 `src/cluster_legacy.c`（gossip 核心），
> 数据结构在 `src/cluster_legacy.h`、`src/cluster.h`。

---

## 1. 全景：Gossip 消息传播与 PFAIL→FAIL 状态翻转

Redis Cluster 是无中心的 gossip 网络：没有 leader，每个节点周期性在 PING/PONG 包里
捎带（piggyback）一部分"我知道的节点状态"，接收方据此更新本地视图。PING/PONG/
MEET 是同一种包（`src/cluster_legacy.h:88-93` 注释、`:94-96` 定义），MEET 只是
"强制收下发送者"的特殊 PING。

```
 gossip 扩散（N=6 节点，每包携带 wanted = max(N/10,3) = 3 条节点信息）
   A ──PING{gossip: B,C,D}──▶ B    A 随机抽 3 个节点状态塞进包尾
   B ──PONG{gossip: E,F,A}──▶ A    B 回包再捎带自己的 3 条；概率 O(log N) 轮收敛

 节点 X 宕机后的状态翻转流水线：
   X 超时(> cluster-node-timeout 无 PONG)
        │  clusterCron 检测 (src/cluster_legacy.c:4832-4836)
        ▼ 本地标记 PFAIL（"疑似故障"，可自愈）
        │  后续 PING/PONG 优先携带 PFAIL 节点 (src/cluster_legacy.c:3730-3748)
        ▼ 其他 master 从 gossip 读到 ⇒ 记入 fail_reports (:2141-2147)
        │  任一 master 收到 ≥ size/2+1 份报告 (:1892-1900)
        ▼ 该 master 置 X 为 FAIL 并广播 FAIL 消息 (:1906-1915)
        ▼ 收到 FAIL 消息的节点无条件置 FAIL (:3201)
        ▼ X 的从节点发起选举，多数派 master 投票授权后提升为主（见第 5 节）
```

两级设计的关键：**PFAIL 是"我自己的观察"（单点、可能误判），FAIL 是"集群多数派
的共识"（权威、触发选举）**。两者是不同 flag 位：`CLUSTER_NODE_PFAIL=4`、
`CLUSTER_NODE_FAIL=8`（`src/cluster_legacy.h:60-61`），判定宏 `nodeTimedOut(n)`/
`nodeFailed(n)` 在 `src/cluster_legacy.h:75-76`。核心结构：`clusterNode` 远端节点
视图（flags、slot 位图、时间戳、fail_reports，`src/cluster_legacy.h:298-332`）；
`clusterState` 本节点集群视图（epoch、迁移数组、选举状态、lastVoteEpoch，
`src/cluster_legacy.h:341-390`）；`clusterLink` 总线连接（`:44-55`）；`clusterMsg`
包头 + 40 字节 gossip 条目（`:230-256`、`:110-120`）。

---

## 2. clusterCron 专节：100ms 心跳与随机选点

clusterCron 由 serverCron 以 **100ms 周期**驱动：`src/server.c:1639-1641`
`run_with_period(100) { if (server.cluster_enabled) clusterCron(); }`。
函数本体在 `src/cluster_legacy.c:4674`。每次做的事按序：

**(1) 链接维护**（`:4700-4711`）：超限发送队列立即释放重连（`:4705`）；握手超时
（`node_timeout`，最小 1 秒，`:4694-4695`）的节点删除。

**(2) 每 10 次迭代（≈1 秒）随机 PING 一个节点**（`:4713-4737`）——"随机选节点"
的实现：随机性保证探索，偏向最久未联系保证收敛：

```c
/* src/cluster_legacy.c:4715-4736（节选） */
if (!(iteration % 10)) {
    int j;
    /* Check a few random nodes and ping the one with the oldest
     * pong_received time. */
    for (j = 0; j < 5; j++) {
        de = dictGetRandomKey(server.cluster->nodes);
        clusterNode *this = dictGetVal(de);
        /* ... 跳过断链/已有 pending ping/MYSELF/HANDSHAKE 节点 ... */
        if (min_pong_node == NULL || min_pong > this->pong_received) {
            min_pong_node = this;
            min_pong = this->pong_received;
        }
    }
    if (min_pong_node)
        clusterSendPing(min_pong_node->link, CLUSTERMSG_TYPE_PING);
}
```

**(3) 保底 PING**（`:4797-4805`）：对"无 pending ping 且 pong 超过 `ping_interval`
（默认 `cluster_node_timeout/2`，可由隐藏配置 cluster-ping-interval 覆盖，
`src/config.c:3239`）"的节点补发 PING；半超时无任何数据则强制重连（`:4778-4791`）。

**(4) 超时检测 → 标 PFAIL**（`:4818-4844`，详见第 3 节）。

**(5) 从节点事务**（`:4862-4874`）：manual failover、自动 failover、从节点迁移
（orphaned master 检测在 `:4757-4773`）。gossip 条目如何装入包：`clusterSendPing`
（`:3630`）决定每包条目数：

```c
/* src/cluster_legacy.c:3668-3674 */
wanted = floor(dictSize(server.cluster->nodes)/10);
if (wanted < 3) wanted = 3;
if (wanted > freshnodes) wanted = freshnodes;
/* Include all the nodes in PFAIL state, so that failure reports are
 * faster to propagate to go from PFAIL to FAIL state. */
int pfail_wanted = server.cluster->stats_pfail_nodes;
```

- 常规条目 = 节点总数/10、至少 3 条，随机抽取（`:3694-3728`）；
- **所有 PFAIL 节点无条件追加在包尾**（`:3730-3748`）——疑似宕机者的状态以广播
  级别传播、不受 1/10 采样约束，这就是"加速故障发现"的机制；`stats_pfail_nodes`
  每轮 cron 开头重新统计（`:4698`）。

---

## 3. PFAIL / FAIL 专节：从单点怀疑到多数派共识

### 3.1 PFAIL：本地超时即怀疑

clusterCron 主循环里（`src/cluster_legacy.c:4829-4844`）：

```c
/* src/cluster_legacy.c:4829-4844（节选） */
mstime_t node_delay = (ping_delay < data_delay) ? ping_delay : data_delay;
if (node_delay > server.cluster_node_timeout) {
    if (!(node->flags & (CLUSTER_NODE_PFAIL|CLUSTER_NODE_FAIL))) {
        node->flags |= CLUSTER_NODE_PFAIL;
        update_state = 1;
        if (clusterNodeIsMaster(myself) && server.cluster->size == 1)
            markNodeAsFailingIfNeeded(node);   /* 单节点集群无多数派可问 */
        /* ...否则仅记日志，等待其他 master 的失败报告... */
    }
}
```

判定依据 `min(ping_delay, data_delay) > cluster_node_timeout`：任何来向的数据
（含总线 Pub/Sub 流量）都算存活证据（注释 `:4826-4828`）。**PFAIL 可自愈**：
收到该节点的 PONG 后立刻清除（`src/cluster_legacy.c:3005-3018`）。

### 3.2 失败报告的收集

gossip 解码端（`clusterProcessGossipSection`，`src/cluster_legacy.c:2097`）对每条
gossip 条目：发送者是 master 且条目带 FAIL/PFAIL 标志时，调
`clusterNodeAddFailureReport` 记账并尝试翻转 FAIL（`:2140-2147`）；报告"恢复在线"
则删报告（`:2148-2154`）。报告 `clusterNodeFailReport{node, time}`
（`src/cluster_legacy.h:81-84`）按 sender 去重、只刷新时间戳
（`src/cluster_legacy.c:1371-1394`）；过期窗口 `cluster_node_timeout *
CLUSTER_FAIL_REPORT_VALIDITY_MULT`（2 倍超时，`src/cluster_legacy.c:1401-1415`、
`src/cluster_legacy.h:22`）。

### 3.3 FAIL：多数派翻转 + 广播

```c
/* src/cluster_legacy.c:1890-1917（节选） */
void markNodeAsFailingIfNeeded(clusterNode *node) {
    int needed_quorum = (server.cluster->size / 2) + 1;
    if (!nodeTimedOut(node)) return;   /* 自己得先 PFAIL */
    if (nodeFailed(node)) return;      /* 已是 FAIL */
    failures = clusterNodeFailureReportsCount(node);
    /* Also count myself as a voter if I'm a master. */
    if (clusterNodeIsMaster(myself)) failures++;
    if (failures < needed_quorum) return;   /* 未达多数派 */
    ...
    node->flags &= ~CLUSTER_NODE_PFAIL;
    node->flags |= CLUSTER_NODE_FAIL;
    clusterSendFail(node->name);            /* 广播 FAIL 消息 */
}
```

要点：

- 法定人数 = **持槽 master 总数 size 的一半 + 1**（size 定义见
  `src/cluster_legacy.c:5134-5144`）；自己的一票仅在自己为 master 时计入。
- 翻转后清 PFAIL、置 FAIL，并 `clusterSendFail` 向全网广播
  （`:3836-3841`："forcing all the other reachable nodes to flag the node as FAIL"）。
- 接收端对 FAIL 消息**不做验证**直接置 FAIL（`src/cluster_legacy.c:3190-3206`），
  信任来自"FAIL 只由已达成多数派的节点发出"这一协议约定。
- **FAIL 撤销**：`clearNodeFailureIfNeeded`（`:1922-1952`）——slave/无槽 master
  可达即清；持槽 master 须等 `cluster_node_timeout * CLUSTER_FAIL_UNDO_TIME_MULT`
  （2 倍超时，`src/cluster_legacy.h:23`）且无人接管其槽才清，防抖动后双主。

### 3.4 1/10 条目数的概率推导（源码注释自证）

`src/cluster_legacy.c:3642-3667` 注释给出完整数学：N 节点、每包 N/10 条、
`node_timeout*2` 有效窗内两两至少交换 8 个包，单个 PFAIL 节点期望收到
`1/N × N/10 × 8N = 0.8N` 份报告——稳超多数派（N/2+1），并为多节点同时宕机留
余量。这是"消息量 vs 收敛速度"的折中：每包条目数随 N 线性增长，全网每秒约
O(N²/2) 个小包（每节点约 10 包/秒）。

---

## 4. Slots 迁移专节：SETSLOT 状态机（IMPORTING/MIGRATING/STABLE）

槽归属本身走 gossip 传播（包头 `myslots` 16384 位位图 + `configEpoch`，接收端
`clusterUpdateSlotsConfigWith`（`src/cluster_legacy.c:2330`）按"configEpoch 大者赢"
重绑 slot：`:2379-2401`）。但**在线 reshard 需要原子地搬 key**，于是每个槽还有
两个附加状态，存在 clusterState 的两个 16384 项数组：`migrating_slots_to[]`
（我是源、正迁给谁）与 `importing_slots_from[]`（我是目标、从谁导入）
（`src/cluster_legacy.h:349-350`）。

CLUSTER SETSLOT 子命令实现（`src/cluster_legacy.c:6078-6206`）构成状态机：

| 子命令 | 前置校验 | 副作用 | 行号 |
|---|---|---|---|
| `SETSLOT s MIGRATING id` | 我必须是 s 的 owner；目标是 master | `migrating_slots_to[s]=n` | :6093-6108 |
| `SETSLOT s IMPORTING id` | 我必须不是 owner；源是 master | `importing_slots_from[s]=n` | :6109-6125 |
| `SETSLOT s STABLE` | — | 两个数组槽位清 NULL（迁移失败回滚用） | :6126-6129 |
| `SETSLOT s NODE id` | 我名下还有 s 的 key 则拒绝（:6144-6150） | `clusterDelSlot(s)` + `clusterAddSlot(n,s)`；若 n 是自己则 bump configEpoch 并广播 PONG | :6130-6199 |

`SETSLOT NODE` 的收尾值得注意（`:6180-6199`）：导入方把槽划给自己时调
`clusterBumpConfigEpochWithoutConsensus`（`:1709-1726`）单方面抬高 configEpoch
——reshard 不走选举、没有多数派背书，必须让新配置 epoch 严格大于旧配置才能在
gossip 中胜出；随后 `clusterBroadcastPong(CLUSTER_BROADCAST_ALL)`（`:6198`）立刻
向全网广播，不等 gossip 慢慢扩散。`clusterAddSlot`/`clusterDelSlot`
（`:5010-5018`/`:5023-5037`）维护节点位图 + 全局 `slots[]` 数组；ADDSLOTS/
DELSLOTS 批量版走 `clusterUpdateSlots`（`:5630-5646`，顺带清 importing 状态）。

迁移期间的客户端路由（`src/cluster.c:1276-1305`）：slot 迁出且 key 不在本节点
→ **ASK** 重定向到目标；多 key 且部分已搬走 → **TRYAGAIN**（错误串
`src/cluster.c:1336-1340`）；目标节点只服务带 ASKING 标记的请求（`:1296-1305`）。

一个防脑裂细节：gossip 发现"sender 不再声称持有某槽"时不立即解绑，只打
`owner_not_claiming_slot` 位图（`src/cluster_legacy.c:2402-2411`；语义注释
`src/cluster_legacy.h:382-387`；`isSlotUnclaimed` 宏 `:116-118`）——避免迁移窗口
内把"源还在搬 key"误判成"槽无主"而把集群打成 CLUSTER_FAIL。

---

## 5. Failover 专节：从节点提升的投票算法

### 5.1 两个纪元

- `currentEpoch`：集群逻辑时钟，节点**发起选举时自增**、包间取最大值传播
  （`src/cluster_legacy.c:2833-2844`，自增点 `:4382`）；
- `configEpoch`：配置版本（slot 归属的 last-writer-wins 时间戳），当选后设为
  当选纪元（`:4402-4407`）。

### 5.2 从节点侧：发起选举（clusterHandleSlaveFailover，:4245）

前置条件（`:4273-4283`）：自己是 slave、主节点 FAIL（manual failover 除外）、
主节点持槽；数据新鲜度检查 `cluster-slave-validity-factor`（`:4304-4313`）。

**选举延迟算法**（`:4317-4345`）：

```c
/* src/cluster_legacy.c:4318-4328（节选） */
server.cluster->failover_auth_time = mstime() +
    500 + /* Fixed delay of 500 milliseconds, let FAIL msg propagate. */
    random() % 500; /* Random delay between 0 and 500 milliseconds. */
server.cluster->failover_auth_rank = clusterGetSlaveRank();
/* 1 second * rank：复制偏移越旧排名越大、延迟越久 */
server.cluster->failover_auth_time +=
    server.cluster->failover_auth_rank * 1000;
```

rank = 同主从节点中复制偏移比自己新的个数（`clusterGetSlaveRank`，`:4113-4128`）。
固定 500ms 等 FAIL 传播，0-500ms 随机打散，rank×1s 惩罚落后者——**数据最新的
从节点几乎总是先发起选举**，降低选票分裂概率；rank 变差还会动态追加延迟
（`:4353-4366`）。到点后（`:4381-4392`）：`currentEpoch++`、记录
`failover_auth_epoch`、向所有节点广播 FAILOVER_AUTH_REQUEST（`:3963-3973`）。
票数 ≥ `size/2+1`（`:4248`、`:4395`）即获胜：configEpoch 抬到当选纪元，接管旧主
全部 slot，`clusterBroadcastPong` 广播新配置（`clusterFailoverReplaceYourMaster`，
`:4207-4235`）。

### 5.3 主节点侧：投票规则（clusterSendFailoverAuthIfNeeded，:3998）

```c
/* src/cluster_legacy.c:4010-4032（节选，五道否决闸门） */
if (nodeIsSlave(myself) || myself->numslots == 0) return;      /* ① 只有持槽 master 有投票权 */
if (requestCurrentEpoch < server.cluster->currentEpoch) return;/* ② 纪元过期 */
if (server.cluster->lastVoteEpoch == server.cluster->currentEpoch)
    return;                                                    /* ③ 本纪元已投过票 */
if (clusterNodeIsMaster(node) || master == NULL ||
    (!nodeFailed(master) && !force_ack)) return;               /* ④ 候选的主必须 FAIL（手动 failover 凭 FORCEACK 豁免） */
...
if (mstime() - node->slaveof->voted_time < server.cluster_node_timeout * 2)
    return;                                                    /* ⑤ 同一主的选举 2×超时内只投一次 */
for (j = 0; j < CLUSTER_SLOTS; j++) { ... /* ⑥ 候选声称的槽，其现主 configEpoch 不得更大 */ }
server.cluster->lastVoteEpoch = server.cluster->currentEpoch;  /* 落票 */
node->slaveof->voted_time = mstime();
clusterSendFailoverAuth(node);
```

`lastVoteEpoch` 是 raft "一任期一票"的等价物（`src/cluster_legacy.h:372`）：
**同一纪元每个 master 只能授出一票**，保证同一纪元最多只有一个从节点能凑齐
多数派——防双主的核心。ACK 有效性还要求发送者是持槽 master 且
`senderCurrentEpoch >= failover_auth_epoch`（`:3239-3251`）。

### 5.4 手动 failover（CLUSTER FAILOVER）

命令入口 `src/cluster_legacy.c:6293-6347`，三种模式：

- **默认**：从节点向主发 MFSTART（`:6345`），主暂停客户端写（`:3252-3263`，时长
  `CLUSTER_MF_TIMEOUT*2`，`src/cluster_legacy.h:24-25`）并在 PING 上打 PAUSED
  标志（`:3599-3600`）；从节点拿到主的 `mf_master_offset`（`:2850-2862`）并追平
  复制流后置 `mf_can_start`（`:4584-4605`，追平判定 `:4594-4597`）——**零数据
  丢失**的先决条件。
- **FORCE**：跳过与主协调，直接置 `mf_can_start`（`:6337-6342`），可能丢最新写入。
- **TAKEOVER**：连投票都不要，自抬 epoch 后直接接管（`:6329-6336`），灾难恢复用。
投票请求带 `CLUSTERMSG_FLAG0_FORCEACK`（`:3967-3970`），使投票闸门④对"主还活着"
豁免（`:4036-4038`）。

---

## 6. 设计动机：为什么 gossip 而非 raft

**为什么用 gossip 做拓扑/故障检测**：

1. **去中心化**：加节点只需 `CLUSTER MEET` 一条边（`src/cluster_legacy.c:5974-6001`
   → `clusterStartHandshake` `:1981-2036`），其余靠 gossip 自动发现（只信任"已知节点"
   转发的条目 `:2199-2211`，黑名单防复活 `:1813`），无 etcd 式"先选举才能服务"的引导期。
2. **故障检测连续且本地化**：每个节点对自己的 TCP 链路做超时检测（PFAIL），
   无需 leader 仲裁即可第一时间感知；共识（FAIL）只在"要采取动作（选举）"时才
   需要。raft 心跳全汇聚到 leader，leader 故障反而要等重选才恢复检测。
3. **消息量可控**：每节点约 10 包/秒（100ms cron + 每 1s 随机选点），每包
   O(N/10) 条目，全网 O(N²/10) 条目/秒；raft 元数据日志复制每条变更 O(N) 且全过
   leader，元数据频繁变化时写放大明显。

**为什么 failover 又退化成 raft 式多数派投票**：slot 归属是正确性敏感状态，双主
写真丢数据，gossip 的最终一致不足以决定"谁接班"。于是 Redis 在**唯一需要强一致
的那个点**（选举）引入 raft 同构机制：单调纪元（currentEpoch ≈ term）、一纪元
一票（lastVoteEpoch）、多数派授权、当选纪元作为 configEpoch 压制旧配置；其余状态
（成员表、slot 映射、PFAIL 传闻）全部交给 gossip 最终一致。

**对比总结**：

| 维度 | Redis Cluster gossip | etcd / raft |
|---|---|---|
| 一致性模型 | 最终一致（configEpoch 冲突取大） | 线性一致（日志复制+多数派提交） |
| 角色 | 对等，无 leader | 强 leader |
| 故障检测 | 全员互检，本地 PFAIL + 多数派 FAIL | leader 心跳，租约/选举超时 |
| 元数据操作 | 管理命令+gossip 扩散，无事务 | 经 raft 日志，强一致事务 |
| 脑裂防护 | minority 侧置 CLUSTER_FAIL 拒写（`src/cluster_legacy.c:5148-5157`） | 少数派直接失去 quorum |
| 复杂度成本 | 冲突消解规则散落（epoch 碰撞 `:1774-1789`、owner_not_claiming_slot） | 单一状态机，但必须部署奇数节点 |

值得注意：Redis Cluster 并非"不能 raft"，而是**把 raft 缩小到选举一个事务**，
其余信息量大的状态（16K 位 slot 位图 × N 节点）走廉价传播。代价是正确性论证
分散：epoch 碰撞消解（`:1774-1789`）、无共识抬 epoch 的例外（`:1700-1708` 注释
明说 may violate）、dirty slot 删 key（`:2462-2463`）都是最终一致性的补丁。

**PFAIL/FAIL 两级的动机**：直接把"超时"当 FAIL 会因单点网络抖动触发无谓选举；
把"等多数派确认"当第一级又让每个节点的状态机依赖全网信息。两级把"敏感但本地"
的检测与"迟钝但权威"的共识解耦：PFAIL 免费加速 gossip 传播（`:3730-3748`），
FAIL 才有资格触发选举（`:4275`）。

---

## 7. FAQ 素材

1. **集群总线端口是多少？** 客户端端口 + 10000（`CLUSTER_PORT_INCR`，`src/cluster_legacy.h:18`；`src/cluster_legacy.c:5991`）。
2. **PING/PONG/MEET 区别？** 完全相同的包结构，MEET 是"必须收下发送者"的特殊
   PING（`src/cluster_legacy.h:88-93`）；gossip 学到的未知节点只建表不握手，
   防误入别的集群（`src/cluster_legacy.c:2200-2208`）。
3. **cluster-node-timeout 影响哪些参数？** 至少六个：PFAIL 阈值（`:4832`）、保底
   ping 间隔的一半（`:4797-4798`）、失败报告有效期×2（`:1406-1407`）、FAIL 撤销
   窗口×2（`:1942-1944`）、选举 auth_timeout×2（`:4262-4263`）、同主重复投票
   冷却×2（`:4059`）。
4. **每个 gossip 包带多少条节点信息？** 节点数/10、最少 3 条、额外全量携带 PFAIL 节点（`src/cluster_legacy.c:3668-3674,3730-3748`）。
5. **PFAIL/FAIL 能自愈吗？** PFAIL 收到 PONG 即自愈（`:3015-3018`）；FAIL 须
   `clearNodeFailureIfNeeded`：slave/无槽 master 可达即清，持槽 master 需等
   2×timeout 且无人接管其槽（`:1922-1952`）。
6. **从节点能投票吗？** 不能。只有持 ≥1 slot 的 master 有投票权
   （`src/cluster_legacy.c:4010`），quorum 基数 size 也只统计持槽 master（`:5134-5144`）。
7. **收到 FAIL 消息为什么敢直接信？** 协议约定只有达成多数派才广播 FAIL；
   若 majority 实际不存在，FAIL 会按时间窗被清掉（`src/cluster_legacy.c:1880-1888` 注释）。
8. **手动 failover 为什么不丢数据？** 主先暂停写（`:3261-3263`），从追平复制流
   （offset 相等，`:4594-4597`）才开始选举；投票请求带 FORCEACK 使主可对
   "活着的自己"豁免闸门④（`:3967-3970`、`:4036-4038`）。
9. **迁移中 key 一半在源一半在目标怎么办？** 源 ASK 重定向；多 key 部分缺失
   返回 TRYAGAIN（`src/cluster.c:1281-1305`），客户端须向目标发 ASKING。
10. **为什么 CLUSTER FORGET 后节点不会被 gossip 复活？** FORGET 把节点 ID 放入
    黑名单，TTL 60 秒内 gossip 不再重新添加（`src/cluster_legacy.c:1798-1813`）。

## 深挖话题

1. **1/10 冗余度的概率证明**：`src/cluster_legacy.c:3642-3667` 注释推导——
   2×timeout 有效窗内单个 PFAIL 节点期望收到 0.8N 份报告（>多数派），为多节点
   同时故障留余量；"最少 3 条"使 N<30 的小集群实际比例更高。
2. **configEpoch 碰撞消解**：两 master 同 epoch 时，nodeID 字典序大者永不动、
   小者 bump（`src/cluster_legacy.c:1774-1789`）；新集群全员 epoch=0 也靠它自愈。
3. **owner_not_claiming_slot 位图**：owner 停止声称某槽时观察者不解绑只记账
   （`src/cluster_legacy.c:2402-2411`、`src/cluster_legacy.h:382-387`）——gossip
   系统"不传播不确定信息"的范例。
4. **选举 rank 延迟**：`500 + rand(500) + rank×1000ms`（`:4317-4334`），数据最旧者
   被逐秒惩罚；manual failover 全免延迟。可对比 raft 的 randomized election timeout。
5. **信任边界**：gossip 新节点添加要求 sender 本身已知（`:2209-2211`），MEET 是
   唯一信任注入点——这防止 IP/端口复用时把两个独立集群意外合并（注释 `:2200-2204`）。

---

## 写作要点速查表

| 内容 | 位置 |
|---|---|
| clusterNode 结构（flags/slot位图/fail_reports） | src/cluster_legacy.h:298 |
| clusterState（epoch/迁移数组/lastVoteEpoch） | src/cluster_legacy.h:341 |
| clusterLink 总线连接 | src/cluster_legacy.h:44 |
| 消息类型枚举（PING0/PONG1/MEET2/FAIL3/...） | src/cluster_legacy.h:94 |
| PFAIL=4 / FAIL=8 标志位与判定宏 | src/cluster_legacy.h:60-61,75-76 |
| clusterCron 本体（由 100ms cron 驱动，src/server.c:1639-1641） | src/cluster_legacy.c:4674 |
| 每 1s 随机抽 5 候选 PING pong 最旧者 | src/cluster_legacy.c:4715-4737 |
| 超时标 PFAIL（node_delay>timeout） | src/cluster_legacy.c:4832-4836 |
| 每包 gossip 条目数 N/10(min3)+全量PFAIL | src/cluster_legacy.c:3668-3674,3730-3748 |
| gossip 解码/失败报告/自动加节点 | src/cluster_legacy.c:2097(2141-2147,2199-2221) |
| FAIL 翻转：quorum=size/2+1 并广播 | src/cluster_legacy.c:1890-1917 |
| 包类型分发 clusterProcessPacket | src/cluster_legacy.c:2730(2865,3190,3236,3272) |
| SETSLOT 状态机 MIGRATING/IMPORTING/STABLE/NODE | src/cluster_legacy.c:6078-6206 |
| 槽归属按 configEpoch 取大重绑 | src/cluster_legacy.c:2330(2379-2401) |
| 投票闸门 + lastVoteEpoch 一纪元一票 | src/cluster_legacy.c:3998-4099 |
| 选举 rank 延迟与发起投票 | src/cluster_legacy.c:4245(4317-4345,4381-4392) |
| CLUSTER FAILOVER FORCE/TAKEOVER | src/cluster_legacy.c:6293-6347 |
| 集群整体 FAIL 判定（minority 拒写） | src/cluster_legacy.c:5090(5148-5157) |
