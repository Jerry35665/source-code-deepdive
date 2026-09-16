# Redis Cluster Gossip 协议与故障检测深读

> 源码版本:redis commit `e8726d1`(e8726d18e5bab24cbfcb0a0c36f21ce5a1140471,2025-09-15)。
> 本版本已将集群实现拆分:`src/cluster.c` 是对外 API 壳(1728 行),gossip 协议核心全部在 `src/cluster_legacy.c`(6518 行);结构体与协议常量在 `src/cluster_legacy.h`。文中行号均以仓库相对路径标注,已逐一 grep/Read 核对。

---

## 1. 全景:一次节点宕机如何在 gossip 网络中翻转成 FAIL

Redis Cluster 的集群总线(cluster bus,端口 = 客户端端口 + 10000,`src/cluster_legacy.h:18`)上所有节点两两之间跑同一套 gossip 消息。PING/PONG/MEET 三种消息**是同一种包**(仅 type 字段不同,`src/cluster_legacy.h:88-93` 的注释明说了这一点,消息常量见 94-105),包头携带自己的 slots 位图、currentEpoch、configEpoch,包体携带最多 N/10 条关于**其他节点**的 gossip 条目。

```
 节点M1 宕机(cluster_node_timeout 超时)
 ────────────────────────────────────────────────────────────────
 [阶段1: 各自标记 PFAIL(本地怀疑)]
   M2 cron 超时未收到 M1 PONG ──► M1.flags |= PFAIL      (本地标)
   M3 同样怀疑 M1(PFAIL)    M4 还没超时,不怀疑

 [阶段2: PFAIL 优先 gossip(加速传播)]
   M2 发 PING 给 M3,gossip 段强制携带 PFAIL 的 M1
   M3 收到:M1 失败报告 +1 ──► 达到多数?──► 是:
        M3 本地把 M1 从 PFAIL 翻成 FAIL,
        并向全网广播 FAIL 消息            ← 唯一的"强制"传播

 [阶段3: FAIL 全网收敛 + 触发选举]
   M2/M4 收到 FAIL ──► 无条件置 FAIL 标志
   M1 的从节点 R1 收到多数主投票 ──► 发起选举 ──► 提升为新主
```

要点:阶段 1、2 是**概率性** gossip(随机选节点、每包只带部分视图);阶段 3 的 FAIL 消息和 FAILOVER_AUTH 是**确定性广播**。Redis 用"gossip 收集怀疑 + 多数派确认后广播结论"这两段式,把最终一致的 gossip 和需要强一致语义的决策(谁该被切主)缝合在一起。

### 1.1 消息类型一览(`src/cluster_legacy.h:94-105`)

| type | 名称 | 用途 | 语义强度 |
|---|---|---|---|
| 0/1/2 | PING/PONG/MEET | 存活探测 + 配置 + gossip 载荷 | 最终一致 |
| 3 | FAIL | 宣告某节点 FAIL | 多数派已确认 |
| 4/10 | PUBLISH/PUBLISHSHARD | 集群内 pub/sub 复制 | 最终一致 |
| 5/6 | FAILOVER_AUTH_REQUEST/ACK | 选举拉票/投票 | Raft 式多数派 |
| 7 | UPDATE | 纠正过期 slots 配置 | configEpoch 仲裁 |
| 8 | MFSTART | 手动 failover 暂停客户端 | 特殊流程 |
| 9 | MODULE | 模块自定义消息 | — |

包头 `clusterMsg`(`src/cluster_legacy.h:230-256`)关键字段:`currentEpoch`(全局逻辑时钟)、`configEpoch`(每个 slots 配置版本号)、`offset`(复制偏移,用于选最优从节点)、`myslots[16384/8]`(2KB slots 位图)、`count`(gossip 条目数)。协议有 static_assert 锁死各字段偏移(`src/cluster_legacy.h:267-287`),保证滚动升级时 wire 兼容。

### 1.2 核心结构体速览

- `clusterNode`(远端节点视图):flags、configEpoch、slots 位图、`ping_sent`/`pong_received`/`data_received` 三时间戳、`fail_reports` 失败报告链表(`src/cluster_legacy.h:298-332`)。
- `clusterState`(本节点集群视图):`currentEpoch`、`migrating_slots_to`/`importing_slots_from`/`slots` 三个 16384 数组、选举字段 `failover_auth_*`、投票方字段 `lastVoteEpoch`(`src/cluster_legacy.h:341-390`)。
- `clusterLink`(总线连接):发送队列、接收缓冲、双向 link(`src/cluster_legacy.h:44-55`)。

---

## 2. clusterCron 专节:100ms 心跳引擎

`clusterCron` 定义在 `src/cluster_legacy.c:4674`,由 serverCron 以 100ms 周期驱动(`src/server.c:1639-1640` 的 `run_with_period(100)`)。它每跳做四件事:

### 2.1 随机选节点发 PING(`src/cluster_legacy.c:4713-4737`)

```c
/* Ping some random node 1 time every 10 iterations, so that we usually ping
 * one random node every second. */
if (!(iteration % 10)) {
    int j;
    /* Check a few random nodes and ping the one with the oldest
     * pong_received time. */
    for (j = 0; j < 5; j++) {
        de = dictGetRandomKey(server.cluster->nodes);
        clusterNode *this = dictGetVal(de);
        ...
        if (min_pong_node == NULL || min_pong > this->pong_received) {
            min_pong_node = this;
            min_pong = this->pong_received;
        }
    }
    if (min_pong_node)
        clusterSendPing(min_pong_node->link, CLUSTERMSG_TYPE_PING);
}
```

- 每 **10 个迭代**(即约 1 秒)从节点表**随机抽 5 个**,挑其中 `pong_received` 最旧(最久没消息)的那个发 PING——优先探测"最不新鲜"的节点(行 4715-4736)。
- 这只是保底;真正的间隔保证在第二个循环里:任何节点的 pong 超过 `ping_interval`(默认 `cluster_node_timeout/2`,`src/cluster_legacy.c:4797-4805`)就立即补发 PING。因此**每个节点对都会在 node_timeout/2 内至少被 ping 一次**——这是源码注释里故障检测概率推导的基础。
- 半超时无任何流量则强制断链重连(行 4778-4791),应对"连接假死但进程活着"。

### 2.2 PFAIL 判定(详见第 3 节,行 4818-4845)

`node_delay = min(now - ping_sent, now - data_received)`,超过 `cluster_node_timeout` 即置 PFAIL。

### 2.3 从节点 failover 与迁移调度(行 4862-4874)

从节点每跳调用 `clusterHandleSlaveFailover()`(行 4865);检测到 orphaned master(有 slots 但无可用从)且自己这边从节点最多时,调用 `clusterHandleSlaveMigration()`(行 4871-4873)。

### 2.4 gossip 条目如何挑选:`clusterSendPing`(`src/cluster_legacy.c:3630`)

- 每包想带的条目数 `wanted = 节点数/10,下限 3`(行 3668-3670)。源码用一段著名注释推导了 1/10 的由来(行 3642-3667):node_timeout*2 的报告有效期内,单个 PFAIL 节点期望被提及 `PROB × 10 × 2×4×N ≈ 80%N`,**必然越过多数派**,还为多节点同时故障留了余量。
- 随机循环抽取,`maxiterations = wanted*3`(行 3694-3695)防止死循环。
- **PFAIL 节点 100% 附加携带**(行 3672-3674 计数,行 3730-3749 追加)——这就是"PFAIL 加速通道"的实现:正常节点靠随机撞,疑似故障节点必上车道,让失败报告尽快凑齐多数。

---

## 3. PFAIL / FAIL 专节:两级故障判定

### 3.1 PFAIL:本地怀疑(单点视角)

`src/cluster_legacy.h:60-61` 定义两级标志:`CLUSTER_NODE_PFAIL`(4,"Failure? Need acknowledge")与 `CLUSTER_NODE_FAIL`(8)。`nodeTimedOut()`/`nodeFailed()` 宏见行 75-76。

判定在 clusterCron 主循环(`src/cluster_legacy.c:4829-4844`):

```c
mstime_t node_delay = (ping_delay < data_delay) ? ping_delay : data_delay;

if (node_delay > server.cluster_node_timeout) {
    /* Timeout reached. Set the node as possibly failing if it is
     * not already in this state. */
    if (!(node->flags & (CLUSTER_NODE_PFAIL|CLUSTER_NODE_FAIL))) {
        node->flags |= CLUSTER_NODE_PFAIL;
        update_state = 1;
        if (clusterNodeIsMaster(myself) && server.cluster->size == 1) {
            markNodeAsFailingIfNeeded(node);   /* 单主集群直接走多数(即自己) */
        } else {
            serverLog(LL_DEBUG,"*** NODE %.40s possibly failing", node->name);
        }
    }
}
```

注意"任何总线流量都算存活"(行 4826-4830 注释):`data_received` 在收到该节点任意包时刷新(`src/cluster_legacy.c:2831`),重负载下 PONG 延迟不等于节点死亡。

### 3.2 FAIL:多数派翻转

失败报告的收集在 gossip 段处理 `clusterProcessGossipSection`(`src/cluster_legacy.c:2140-2147`):只有**主节点**发来的、flags 带 FAIL/PFAIL 的 gossip 条目才计入 `clusterNodeAddFailureReport`;若对方报告该节点正常,则删除报告(行 2149-2153)。随后立即尝试翻转:

```c
void markNodeAsFailingIfNeeded(clusterNode *node) {          /* 1890 */
    int failures;
    int needed_quorum = (server.cluster->size / 2) + 1;      /* 1892 */

    if (!nodeTimedOut(node)) return;   /* We can reach it. */
    if (nodeFailed(node)) return;      /* Already FAILing. */

    failures = clusterNodeFailureReportsCount(node);
    /* Also count myself as a voter if I'm a master. */     /* 1898 */
    if (clusterNodeIsMaster(myself)) failures++;
    if (failures < needed_quorum) return;  /* No weak agreement from masters. */
    ...
    node->flags &= ~CLUSTER_NODE_PFAIL;                      /* 1906 */
    node->flags |= CLUSTER_NODE_FAIL;
    node->fail_time = mstime();
    clusterSendFail(node->name);       /* 广播 FAIL,强制全网翻转 */  /* 1915 */
```

- 多数派 = `size/2 + 1`,其中 `size` 是**持有至少一个 slot 的主节点数**(`src/cluster_legacy.h:345`,计算在 `src/cluster_legacy.c:5134-5144`)。
- 每份报告有时效:超过 `2 × node_timeout`(`CLUSTER_FAIL_REPORT_VALIDITY_MULT`,`src/cluster_legacy.h:22`)自动清除(`src/cluster_legacy.c:1401-1415`)——过期的怀疑不算数,防止陈旧报告永久污染。

### 3.3 撤销条件(FAIL 是可逆的)

- **PFAIL 自愈**:收到该节点 PONG 即清 PFAIL(`src/cluster_legacy.c:3015-3018`)——瞬时抖动不需外力即撤销。
- **FAIL 撤销** `clearNodeFailureIfNeeded`(`src/cluster_legacy.c:1922`):从节点/无 slots 主节点,重新可达即清(行 1929-1936);**有 slots 的主节点**必须同时满足"重新可达 + 已过 `2 × node_timeout` 仍无人接管它的 slots"(行 1942-1944,`CLUSTER_FAIL_UNDO_TIME_MULT`,`src/cluster_legacy.h:23`)才清——如果它的 slots 已被新主接管,FAIL 就地固化,旧主回来只能作为从节点重新加入。
- **FAIL 单向强制**:收到 FAIL 消息无条件置位(`src/cluster_legacy.c:3190-3206`),不需要自己有失败报告;黑名单机制(`CLUSTER_BLACKLIST_TTL` 60 秒,`src/cluster_legacy.c:1813`)防止被踢出的节点被 gossip 立即加回。

---

## 4. Slots 迁移专节:SETSLOT 状态机

槽状态存放在 `clusterState` 的两个数组(`src/cluster_legacy.h:349-350`):`migrating_slots_to[slot]`(我的 slot 正迁往谁)与 `importing_slots_from[slot]`(我正从谁那导入 slot)。命令入口 `CLUSTER SETSLOT` 在 `src/cluster_legacy.c:6078-6206`:

```c
} else if (!strcasecmp(c->argv[3]->ptr,"migrating") && c->argc == 5) {   /* 6093 */
    if (server.cluster->slots[slot] != myself) { ... }      /* 必须是 owner */
    server.cluster->migrating_slots_to[slot] = n;           /* 6108 */
} else if (!strcasecmp(c->argv[3]->ptr,"importing") && c->argc == 5) {   /* 6109 */
    if (server.cluster->slots[slot] == myself) { ... }      /* 不能是 owner */
    server.cluster->importing_slots_from[slot] = n;         /* 6125 */
} else if (!strcasecmp(c->argv[3]->ptr,"stable") && c->argc == 4) {      /* 6126 */
    /* CLUSTER SETSLOT <SLOT> STABLE */
    server.cluster->importing_slots_from[slot] = NULL;      /* 6128 */
    server.cluster->migrating_slots_to[slot] = NULL;
```

状态机与配套行为:

```
        STABLE ──SETSLOT n MIGRATING X──►  MIGRATING(源)
           ▲   (owner 执行;6108)          读:照常;写:KEYS 不在则 -ASK 转向目标
           │                                MIGRATE 命令逐 key 搬运(redis-cli --cluster)
           │                          ◄──SETSLOT n IMPORTING self(6125,目标执行)
           │                                写:ASKING 打标后可写;否则 -MOVED
        STABLE ◄──SETSLOT n STABLE(6126)  迁移中途放弃/清障(redis-cli 4888 自动重试)
           ▲
           └── 两端各执行 SETSLOT n NODE target(6130-6161)
               owner 侧校验槽内已无 key(6144-6150)
               clusterDelSlot + clusterAddSlot 改所有权(6160-6161)
```

几个深藏的实现细节:

- **ADDSLOTS/DELSLOTS 是"一步到位"的所有权变更,不走迁移状态机**:`CLUSTER ADDSLOTS/DELSLOTS` 入口在 `src/cluster_legacy.c:6011-6038`(区间版 ADDSLOTSRANGE/DELSLOTSRANGE 在 6039-6077),统一落到 `clusterUpdateSlots()`(`src/cluster_legacy.c:5630-5646`)——DEL 调 `clusterDelSlot`,ADD 调 `clusterAddSlot`。而 `clusterAddSlot` 只接受**当前无主**的 slot(`src/cluster_legacy.c:5011` 的 `if (server.cluster->slots[slot]) return C_ERR;`),即 ADDSLOTS 只能给**自己**认领空槽(命令里 slots 数组就是按"assigned to myself"语义构造的)。所以建集群/扩容先 ADDSLOTS 认领,而搬家必须走 SETSLOT 四步状态机;若该槽曾处 IMPORTING 状态,ADDSLOTS 会顺手清除它(行 5638-5639)。
- **手动迁移绕过选举**:`SETSLOT n NODE` 把 slot 划给自己时,若正处 IMPORTING 状态,调用 `clusterBumpConfigEpochWithoutConsensus()` 单方面抬升 configEpoch(行 6180-6194,函数定义 `src/cluster_legacy.c:1709-1726`),随后 `clusterBroadcastPong(CLUSTER_BROADCAST_ALL)` 立刻全网广播(行 6198)。注释明说:若与别的节点的 epoch 撞车,由 `clusterHandleConfigEpochCollision()` 事后仲裁(该函数在 `src/cluster_legacy.c:3179-3183` 被调用)。
- **腾空主自动降级为从**:划走自己最后一个 slot 且开启 replica-migration 时,`clusterSetMaster(n)` 把自己变成新主的从节点(行 6163-6176)。
- **收尾兜底**:nodes.conf 持久化在行 6205 `clusterDoBeforeSleep(CLUSTER_TODO_SAVE_CONFIG|...)`。
- **迁移期的客户端语义**:源节点 MIGRATING 状态下 key 缺失则回 `-ASK` 指向目标(`src/cluster.c:1281-1289`);目标 IMPORTING 状态只对带 `ASKING` 标志的请求放行(`src/cluster.c:1296-1305`);迁移中途既有 key 又缺 key 回 `-TRYAGAIN`(行 1283-1285)。状态查询经 `getMigratingSlotDest/getImportingSlotSource`(`src/cluster.h:138-139`)接入重定向判定(错误码定义 `src/cluster.h:30-37`)。

---

## 5. Failover 专节:从节点提升的投票算法

### 5.1 发起方(从节点):`clusterHandleSlaveFailover`(`src/cluster_legacy.c:4245`)

前置条件(行 4273-4283):我是从节点、我的主被标 FAIL(或手动 failover)、未禁 failover、主持有 slots。

**数据新鲜度门槛**(行 4287-4313):断连时长减去 node_timeout 后,不得超过 `repl_ping_slave_period + node_timeout × cluster-replica-validity-factor`,太旧的从节点不许参选。

**排序延迟**(行 4317-4346)——防脑裂的核心:

```c
server.cluster->failover_auth_time = mstime() +
    500 + /* Fixed delay of 500 milliseconds, let FAIL msg propagate. */
    random() % 500; /* Random delay between 0 and 500 milliseconds. */
server.cluster->failover_auth_count = 0;
server.cluster->failover_auth_rank = clusterGetSlaveRank();
/* We add another delay that is proportional to the slave rank.
 * Specifically 1 second * rank. This way slaves that have a probably
 * less updated replication offset, are penalized. */
server.cluster->failover_auth_time += server.cluster->failover_auth_rank * 1000;
```

rank 由 `clusterGetSlaveRank()`(`src/cluster_legacy.c:4113-4129`)计算:复制偏移比我新的兄弟从节点个数。数据最新的从节点 rank=0、最快发起选举;rank 之间错开 1 秒 + 随机 500ms,天然避免多从同时拉票。期间 rank 变差还会动态追加延迟(行 4353-4366)。

**拉票与计票**(行 4380-4413):到点后 `currentEpoch++`,以 `failover_auth_epoch = currentEpoch` 广播 AUTH_REQUEST(行 4382-4387,发送函数 `clusterRequestFailoverAuth` 在行 3963,手动 failover 会打 FORCEACK 标志);收到多数派 ACK(`failover_auth_count >= size/2+1`,行 4395)即获胜,把自己的 configEpoch 抬到选举 epoch(行 4402-4407),`clusterFailoverReplaceYourMaster()`(定义于 `src/cluster_legacy.c:4207`)接管 slots、广播 PONG 让全网更新拓扑。计票侧校验:ACK 只在"发送方是有 slots 的主 + 其 currentEpoch ≥ 我的选举 epoch"时有效(行 3239-3251)。

### 5.2 投票方(主节点):`clusterSendFailoverAuthIfNeeded`(`src/cluster_legacy.c:3998`)

五道否决闸门:

1. **投票资格**:自己必须是有 slots 的主(`src/cluster_legacy.c:4006-4010`)。
2. **epoch 单调**:请求 epoch < 我的 currentEpoch 则拒绝(行 4016-4023)。
3. **一 epoch 一票**:`lastVoteEpoch == currentEpoch` 说明本 epoch 已投过,拒绝(行 4026-4032)。
4. **主必须 FAIL**(或手动 failover 的 FORCEACK,行 4034-4054);同一主的两票间隔至少 `2 × node_timeout`(行 4056-4068)。
5. **slot epoch 仲裁**:请求方声称的任何 slot,其现 owner 的 configEpoch 若更大,拒绝(行 4070-4090)。

通过后 `lastVoteEpoch = currentEpoch` 并回 ACK(行 4093-4098)。`lastVoteEpoch` 持久化在 `clusterState`(`src/cluster_legacy.h:372`),重启不丢,保证"一个 epoch 只投一票"跨重启成立。

### 5.3 手动 failover 快路径

`CLUSTER FAILOVER` 命令入口在 `src/cluster_legacy.c:6293-6346`(发给从节点执行;FORCE 只置 `mf_can_start=1` 跳过 offset 协商,行 6337-6342;TAKEOVER 更激进,直接 `clusterBumpConfigEpochWithoutConsensus()` + `clusterFailoverReplaceYourMaster()`,行 6329-6336,连多数派投票都省了,是唯一的"无共识夺权"通道)。常规路径走 MFSTART 消息(`src/cluster_legacy.c:3252-3271`):主收到后暂停客户端写(pause 时长 = `CLUSTER_MF_TIMEOUT × CLUSTER_MF_PAUSE_MULT`,`src/cluster_legacy.h:24-25`),把自己的复制偏移经 PONG 带回从节点(行 2850-2862 填 `mf_master_offset`);从节点在 `clusterHandleManualFailover()`(`src/cluster_legacy.c:4584-4605`)中追平 offset 后置 `mf_can_start=1`(行 4597),**零延迟**发起选举,且投票方收到 FORCEACK 后即使主还活着也放行(行 4003、4037-4038)。这是"数据不丢换主"的受控通道。

---

## 6. 设计动机:为什么 gossip 而非 Raft?

**为什么数据面用 slots + gossip,而选举却长得像 Raft?** Redis 的取舍是"分而治之":

- **成员与拓扑信息**(谁在线、谁持有哪些 slots)是**大批量、低价值密度、容忍陈旧**的数据。16384 slots 位图 + N 个节点状态,用 gossip 概率传播即可收敛,无需逐条确认。gossip 每包固定携带 2KB slots 位图(`src/cluster_legacy.h:244`)+ N/10 条邻居摘要,带宽 O(N) 且恒定——这是 etcd(Raft 要求日志复制到每个成员)在几百节点下会先撑爆的地方。
- **故障判定与主切换**是**小批量、高价值**的决策。Redis 把这两件事从 gossip 里摘出来:PFAIL→FAIL 需要多数主确认(第 3 节),切主需要多数主投票(第 5 节)——**gossip 负责发现,多数派负责定论**。准确说法是:Redis Cluster = gossip(最终一致的成员/配置传播)+ Raft 式多数派选举(安全的 epoch 单调投票),而不是"纯 gossip"。

**为什么 PFAIL/FAIL 要分两级?**

1. **单点怀疑不可信**:网络抖动、总线拥塞都会造成假超时。PFAIL 只是本地"嫌疑",必须凑齐 `size/2+1` 份独立报告(且报告者必须是主)才翻转成 FAIL,把误判率压到需要**多数节点同时误判**的水平。
2. **翻转即广播,收敛 O(1) 跳**:一旦确认,不再靠概率 gossip 慢慢磨,而是 `clusterSendFail` 直接全网广播(行 1915)。PFAIL 阶段靠 gossip 收集报告(PFAIL 条目 100% 附带,行 3730-3749),FAIL 之后靠广播——**慢收集快结论**。
3. **可逆性分层**:PFAIL 见 PONG 即撤销(行 3015-3018);FAIL 撤销要过 `2×node_timeout` 冷却且确认无人接管 slots(行 1942-1944)。故障检测"宽进严出",避免振荡。

**gossip 收敛速度与消息量的定量直觉**(源码自带推导,`src/cluster_legacy.c:3642-3667`):node_timeout 内每对节点至少交换 4 个包(半超时保底 PING + 对方 PING 的响应),报告有效期 2×node_timeout,故每个 PFAIL 节点在有效期内被提及的期望次数 ≈ `(1/N) × (N/10) × 8N/10 ≈ 0.8N`,**必然越过多数派**,还容忍 20% 的节点不在环上(挂了一部分时剩下的也能凑多数)。

**与 etcd/Raft 的对比总结**:

| 维度 | Redis Cluster | etcd / Raft |
|---|---|---|
| 一致性模型 | slots 配置最终一致(gossip),决策多数派 | 全部经 Raft 日志强一致 |
| 心跳/成员 | gossip PING,PFAIL 本地怀疑 | leader 心跳,follower 超时 |
| 选主 | 从节点拉票,epoch 单调,一 epoch 一票 | 任意成员拉票,term 单调,一 term 一票 |
| 数据安全 | 异步复制,**可能丢最近写入** | 多数派落盘才提交,**不丢已提交** |
| 扩缩容 | 原生 slots 迁移(第 4 节) | 无内建分片,靠上层 |
| 规模上限设计 | 数百~千节点,gossip 带宽 O(N) | 通常 ≤ 7~9 投票成员 |

Redis 选举与 Raft 的同构点很直白:`currentEpoch`≈term、`lastVoteEpoch`≈votedFor、多数 ACK≈quorum;差异在投票者资格(Redis 只算有 slots 的主)、候选人按复制进度排序,以及 Redis **不保证**新主拥有全部已确认写入(异步复制),这是它与 Raft 最本质的语义鸿沟。

---

## 7. FAQ 素材

1. **PFAIL 和 FAIL 的区别?** PFAIL(4 号位)是单个节点本地超时怀疑(`src/cluster_legacy.c:4836`);FAIL(8 号位)是收到 `size/2+1` 份主节点失败报告后的翻转结论(`src/cluster_legacy.c:1890-1917`)。只有 FAIL 会广播(行 1915)并触发从节点选举(`src/cluster_legacy.c:4275`)。
2. **cluster-node-timeout 调小会怎样?** 检测更快,但 PING 间隔(默认 timeout/2,行 4797-4798)、失败报告有效期(2×timeout)、投票节流(2×timeout,行 4059)、FAIL 撤销冷却全部随之缩短,误判与振荡风险上升。
3. **为什么每包只 gossip N/10 个节点,下限 3?** 源码推导(行 3642-3667):保证 PFAIL 节点在 2×timeout 有效期内被提及次数期望 ≈ 80%N,必然过多数;下限 3 保证小集群也有基本冗余。
4. **gossip 会不会把别家集群的节点拉进来?** 不会。gossip 段只接受**已认识节点**发来的未知节点信息(`src/cluster_legacy.c:2209-2211`),且 node ID 是随机 40 字节;被移除的节点 ID 进黑名单 60 秒(行 1813)。MEET 是唯一强制加节点的入口(行 2897-2916)。
5. **MEET 和 PING 到底差在哪?** 同一种包不同 type。发起方:`CLUSTER MEET` 命令(`src/cluster_legacy.c:5974-6001`)只是创建一个带 `HANDSHAKE|MEET` 标志的占位节点(`clusterStartHandshake`,`src/cluster_legacy.c:1981-2036`,标志打在行 2026);cron 重连成功时把首包发成 MEET(行 3386-3388)并随即清掉 MEET 标志(行 3400)。接收方对未知发送者:收到 PING 不会加节点(防误入别的集群),收到 MEET 强制创建 HANDSHAKE 节点(行 2897-2916),首个 PONG 到达后用真实 node ID 转正(行 2956-2961)。
6. **一个主节点能投两票吗?** 不能。`lastVoteEpoch == currentEpoch` 直接拒绝(行 4026-4032),且 lastVoteEpoch 持久化(行 4093 + `src/cluster_legacy.h:372`),重启也不重投。
7. **多个从节点同时选举怎么办?** rank 延迟错峰:500ms 随机 + rank×1000ms(行 4318-4328),复制偏移最新的先选;同一主的两票间隔 2×timeout(行 4059)进一步保证一个 epoch 内基本只有一人获票。
8. **主从分区时集群还写吗?** 可达主节点数低于多数派(`reachable_masters < size/2+1`,`src/cluster_legacy.c:5150-5157`)或开了 require-full-coverage 且 slots 有洞(行 5114-5123)时,全局转 CLUSTER_FAIL,拒绝写入(-CLUSTERDOWN)。少数派分区自动只读。
9. **手动 failover 为什么不丢数据?** MFSTART 让主暂停写(行 3261-3263),从节点追平复制偏移才开始选举(PONG 携带 offset,行 2850-2862),本质是受控换主。
10. **slots 迁移一半时 key 请求怎么路由?** 源节点 MIGRATING 状态对不存在的 key 回 ASK;目标节点 IMPORTING 状态凭 ASKING 标志放行写(`src/cluster.h:33` 的 CLUSTER_REDIR_ASK 语义)。

## 8. 深挖线索

1. **cluster_msg 的 2KB slots 位图是 gossip 的"重"所在**:`src/cluster_legacy.h:244`。N 节点集群全互联 PING 下总线流量 ≈ O(N²) 个 2KB 包/timeout 周期,千节点规模要重新审视 cluster-ping-interval(可调,行 4797)。
2. **`clusterHandleConfigEpochCollision`**:手动迁移撞 epoch 的事后仲裁(`src/cluster_legacy.c:3179-3183` 调用点),研究"无共识 epoch 提升"如何自愈,是理解 Redis 弱共识边界的好切口。
3. **`owner_not_claiming_slot` 位图**(`src/cluster_legacy.h:382-387`):迁移中 owner 停止声称 slot 后,防止其他节点用 UPDATE 消息把错误归属"纠正"回去——slot 迁移与 gossip 冲突的微妙边界。
4. **FAIL 消息的权限模型**:任何已知节点(含从节点)发来的 FAIL 都被接受(行 3193-3206),而 PFAIL 报告只认主节点(行 2140)——因为 FAIL 本身是别人多数派确认的结果,从节点只是中继;UPDATE 消息同理(行 3272-3293)。
5. **`clusterUpdateSlotsConfigWith`**(`src/cluster_legacy.c:2330`):slot 所有权仲裁的落地点——configEpoch 大者胜(行 2379-2380),收到过期配置的一方反向回 UPDATE(行 3151-3175),输家持有脏 slot 时删 key(判断在行 2384-2390,删除落在行 2462-2463),是"最终一致收敛到谁"的最终执行者。

---

## 9. 写作要点速查表

| 主题 | 位置(仓库相对路径) |
|---|---|
| clusterCron 100ms 驱动 | `src/server.c:1639-1640` |
| clusterCron 定义 | `src/cluster_legacy.c:4674` |
| 每秒随机抽 5 选 1 发 PING | `src/cluster_legacy.c:4715-4736` |
| 半超时补发 PING / 断链重连 | `src/cluster_legacy.c:4797-4805 / 4778-4791` |
| 置 PFAIL(node_delay > timeout) | `src/cluster_legacy.c:4832-4844` |
| gossip 条目数 N/10 下限 3(概率推导) | `src/cluster_legacy.c:3642-3670` |
| PFAIL 节点 100% 随包附带 | `src/cluster_legacy.c:3672-3674, 3730-3749` |
| PFAIL→FAIL 翻转(多数派 + 广播) | `src/cluster_legacy.c:1890-1917` |
| 失败报告 2×timeout 过期清理 | `src/cluster_legacy.c:1401-1415`(`src/cluster_legacy.h:22-23`) |
| PFAIL 见 PONG 自愈 / FAIL 撤销 | `src/cluster_legacy.c:3015-3018 / 1922-1952` |
| FAIL 消息接收即置位 | `src/cluster_legacy.c:3190-3206` |
| MEET 加节点 / CLUSTER MEET 入口 | `src/cluster_legacy.c:2897-2922 / 5974-6000` |
| 消息类型常量与包头结构 | `src/cluster_legacy.h:94-105, 230-256` |
| clusterState(currentEpoch/lastVoteEpoch/迁移数组) | `src/cluster_legacy.h:341-390` |
| SETSLOT 状态机(MIGRATING/IMPORTING/STABLE/NODE) | `src/cluster_legacy.c:6078-6206` |
| ADDSLOTS/DELSLOTS → clusterUpdateSlots(空槽约束) | `src/cluster_legacy.c:6011-6077, 5630-5646, 5010-5018` |
| 迁移期 ASK/ASKING/TRYAGAIN 重定向 | `src/cluster.c:1281-1305` |
| CLUSTER MEET → clusterStartHandshake(HANDSHAKE\|MEET) | `src/cluster_legacy.c:5974-6001, 1981-2036` |
| CLUSTER FAILOVER 命令入口(FORCE/TAKEOVER) | `src/cluster_legacy.c:6293-6346` |
| 手动 failover 状态机(MFSTART→offset→can_start) | `src/cluster_legacy.c:3252-3271, 2850-2862, 4584-4605` |
| slots 仲裁与反向 UPDATE 纠错 | `src/cluster_legacy.c:3130-3131, 3151-3175, 2330-2465` |
| failover:rank 延迟 + 拉票 + 计票 | `src/cluster_legacy.c:4317-4346, 4380-4413` |
| 投票五道闸门 / lastVoteEpoch 单票 | `src/cluster_legacy.c:3998-4099` |
| 全局 FAIL 态(少数派/coverage) | `src/cluster_legacy.c:5090-5157` |
