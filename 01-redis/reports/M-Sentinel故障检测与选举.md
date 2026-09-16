# M - Sentinel 故障检测与选举：从 ping 超时到 +switch-master

> 源码版本：redis commit `e8726d1`（主分支快照）。所有行号均以 `src/sentinel.c`（全文 5474 行）为准，Cluster 对比部分引自 `src/cluster_legacy.c`。
> 前置阅读：卷一 07 章已讲过 Sentinel 的角色与部署拓扑，本文只讲内部机制。

---

## 1. 全景：一次故障迁移的完整流程

Sentinel 是一个跑在 Redis 服务器骨架上的独立进程模式（`initSentinel()` 会替换掉普通 Redis 的命令表，src/sentinel.c:471-493）。它的"心脏"是一个 100ms 级别的定时器 `sentinelTimer()`（src/sentinel.c:5460-5474），每 tick 做五件事：TILT 检查 → 遍历实例做监测/判决 → 跑通知脚本 → 回收脚本 → **随机化 server.hz**（5473，故意让各 Sentinel 节拍错开，防止同时发起选举导致选票瓜分）。

对每个实例的定期处理在 `sentinelHandleRedisInstance()`（src/sentinel.c:5368-5400）："监测半区"每 tick 都跑（重连 5371、发周期命令 5372），"行动半区"在 TILT 模式下跳过（5378-5382）。

```
                    ┌──────────────────────────────────────────────────┐
                    │  sentinelTimer() 每 ~100ms   (sentinel.c:5460)    │
                    └──────────────────────────────────────────────────┘
                                        │ 对每个实例
   ┌────────────────────────────────────┼─────────────────────────────────────┐
   │ ① 监测半区                         │                                     │
   │   重连 + 周期命令(PING/INFO/PUBLISH)│  sentinel.c:5371-5372               │
   └────────────────────────────────────┴─────────────────────────────────────┘
                                        │
   ┌────────────────────────────────────┼─────────────────────────────────────┐
   │ ② 行动半区(非TILT)                 │                                     │
   │   SDOWN 判定(所有实例)  :45385      │  → +sdown 事件                      │
   │   仅 MASTER:                       │                                     │
   │     ODOWN 投票汇总      :45394     │  → +odown (quorum x/y)              │
   │     若 ODOWN → 竞选故障迁移         │                                     │
   │       sentinelStartFailoverIfNeeded│  :5395  (+try-failover, 新纪元++)   │
   │     状态机推进                      │  :5397                              │
   │     询问其他 Sentinel 投票/下线     │  :5398  (IS-MASTER-DOWN-BY-ADDR)    │
   └────────────────────────────────────┴─────────────────────────────────────┘
                                        │
  MASTER_DOWN ──► 投票选 leader ──► 选从 ──► SLAVEOF NO ONE ──► 等晋升 ──► 改从 ──► 换配置
  (SDOWN/ODOWN)   (WAIT_START)     (SELECT_  (SEND_SLAVEOF_ (WAIT_      (RECONF_  (UPDATE_
                   纪元+1,拉票)     SLAVE)    NOONE)          PROMOTION) SLAVES)   CONFIG)
                                                                                  │
                                        ┌─────────────────────────────────────────┘
                                        ▼
                        +switch-master 事件 (sentinel.c:5313)
                        Pub/Sub 广播 + notification_script
                        + client-reconfig-script ("start")
```

时间基线（src/sentinel.c:63-77）：PING 周期 1s（63）；INFO 周期 10s（65）；互相询问下线 1s（67）；Hello 发布 2s（68）；默认 down-after 30s（69）；重配从节点超时 10s（72）；选举超时 10s（74）；failover 总超时默认 180s（77）。

---

## 2. SDOWN/ODOWN 专节：两级下线判定链

### 2.1 判定链总览

```
PING/PONG (act_ping_time, sentinel.c:3074-3092, 回调 :2776-2818)
        │ elapsed > down_after_period ?
        ▼
   SRI_S_DOWN  (单 Sentinel 的主观判断)      sentinel.c:4571-4584
        │ 每秒向其他 Sentinel 发 IS-MASTER-DOWN-BY-ADDR   :4680-4722
        │ 对方 S_DOWN 则置 SRI_MASTER_DOWN               :4655-4656
        ▼
   quorum 个 "同意票" → SRI_O_DOWN            sentinel.c:4616, 4624
        │ (仅 ODOWN 才允许启动 failover)                  :4963
        ▼
   竞选 leader → 状态机 (见第 4 节)
```

### 2.2 SDOWN：从 ping 超时到打标

`sentinelCheckSubjectivelyDown()`（src/sentinel.c:4526-4592）每 tick 对每类实例（主/从/Sentinel）执行一次。超时基准不是"最后一次 pong"，而是 **act_ping_time**：只有上一条 ping 得到回应后才更新为新 ping 的发送时间（src/sentinel.c:3086-3089），因此它是"从第一个未获回应的 ping 起算"的连续等待时长。计算逻辑在 4529-4532：有挂起 ping 用 `mstime() - act_ping_time`；断连则用 `mstime() - last_avail_time`。

判 SDOWN 的三个条件（4571-4577）：

```c
if (elapsed > ri->down_after_period ||
    (ri->flags & SRI_MASTER &&
     ri->role_reported == SRI_SLAVE &&
     mstime() - ri->role_reported_time >
      (ri->down_after_period+sentinel_info_period*2)) ||
      (ri->flags & SRI_MASTER_REBOOT &&
       mstime()-ri->master_reboot_since_time > ri->master_reboot_down_after_period))
```

- 条件 1：超时无有效回应。注意"有效回应"很宽：`PONG`、`LOADING`、`MASTERDOWN` 都算活（src/sentinel.c:2789-2791）——从节点还在加载或处于 `replica-read-only` 拒写状态都不误判；而 `-BUSY` 回复则会触发 Sentinel 发 `SCRIPT KILL` 抢救（2802-2814）。
- 条件 2：一个"master"持续报告自己是 slave 超过 `down_after + 2×10s`——说明它被降级了（可能正被别的 Sentinel 迁移），按不可用处理。
- 条件 3：`SENTINEL SIMULATE-FAILURE` 相关的重启窗口（runid 变化检测在 2514-2529）。

命中即打 `SRI_S_DOWN` 标志并发出 `+sdown` 事件（4580-4584）；恢复则发 `-sdown` 并清标志（4587-4590）。

**down-after-milliseconds 的语义**：这是每个实例的 `down_after_period` 字段（src/sentinel.c:177），配置入口在 1854-1859，创建实例时继承默认 30s（1316），且 master 的值会强制向下传播给所有 slaves 和 sentinels 实例（`sentinelPropagateDownAfterPeriod`，1666-1680）——所以它实际是"以 master 配置为准的组级参数"。它同时是 PING 的节流上限：ping_period = min(down_after, 1s)（3137-3138）。

辅助机制：链路"半超时"预重连——挂起 ping 超过 down_after/2 且 15s 未重建连接，就主动断开命令链路（4540-4550）；Pub/Sub 链路 3×2s 无活动也重连（4557-4563）。

### 2.3 ODOWN：多数确认的"弱 quorum"

只有 master 需要 ODOWN。`sentinelCheckObjectivelyDown()`（src/sentinel.c:4600-4633）：

```c
if (master->flags & SRI_S_DOWN) {
    quorum = 1; /* the current sentinel. */
    /* Count all the other sentinels. */
    dictInitIterator(&di, master->sentinels);
    while((de = dictNext(&di)) != NULL) {
        sentinelRedisInstance *ri = dictGetVal(de);
        if (ri->flags & SRI_MASTER_DOWN) quorum++;
    }
    dictResetIterator(&di);
    if (quorum >= master->quorum) odown = 1;
}
```

关键点：
- **前提是自己先 SDOWN**（4605），自己的 1 票直接计入（4607）。
- 别人的意见来自 `SRI_MASTER_DOWN` 标志，该标志由 `IS-MASTER-DOWN-BY-ADDR` 的回复驱动（4655-4658），且回复超过 `5×1s` 未刷新就作废（4692-4696）——源码注释明说这是"weak quorum"：只表示"一段时间窗内足够多的 Sentinel 报告过不可达"，不保证它们同时刻一致（4596-4599）。
- ODOWN 可以撤销：票数回落即 `-odown`（4628-4631）。
- 询问的发送条件很苛刻：自己认为 SDOWN（4703）、链路活着（4704）、距上次回复 ≥1s（4705-4707）。请求第 4 个参数是 runid：正常下线探测传 `"*"`；一旦 failover 已启动（`failover_state > NONE`）就传自己的 myid（4717-4718）——**同一条命令复用为"拉票"通道**，这是理解 Sentinel 选举的钥匙。

---

## 3. 选举专节：Sentinel 的 Raft 变体

### 3.1 纪元与投票状态

- 全局纪元：`sentinel.current_epoch`（src/sentinel.c:237），启动为 0（473，initSentinel 内）。
- 每个 master 记录 `leader`（被投给的 runid）与 `leader_epoch`（src/sentinel.c:214-218）。
- 纪元的三个推进点：收到 Hello 里更大的 epoch（2913-2919）；收到投票请求里更大的 epoch（4739-4744）；自己启动 failover 时 `failover_epoch = ++current_epoch`（4942）。

投票函数 `sentinelVoteLeader()`（src/sentinel.c:4738-4763）：

```c
if (master->leader_epoch < req_epoch && sentinel.current_epoch <= req_epoch)
{
    sdsfree(master->leader);
    master->leader = sdsnew(req_runid);
    master->leader_epoch = sentinel.current_epoch;
    ...
    /* If we did not voted for ourselves, set the master failover start
     * time to now, in order to force a delay before we can start a
     * failover for the same master. */
    if (strcasecmp(master->leader,sentinel.myid))
        master->failover_start_time = mstime()+rand()%SENTINEL_MAX_DESYNC;
}
```

三个语义：① 每个纪元只投一票（投过 `leader_epoch` 就不再变，4746 的条件）；② 只投"请求纪元不小于本地纪元"的候选（4746）；③ 投给别人的同时**推迟自己的 failover_start_time**（4757-4758，加 0~1000ms 随机，SENTINEL_MAX_DESYNC 定义在 84 行）——投了别人就意味着本轮自己不打算当 leader，主动让路。

### 3.2 计票与当选条件

`sentinelGetLeader()`（src/sentinel.c:4794-4857）在 WAIT_START 状态被调用（5102）。当选需要**两个条件同时满足**（4818-4820 注释、4849-4851 代码）：

1. 绝对多数：`max_votes >= voters/2 + 1`，voters = 已发现的 Sentinel 数 + 自己（4807）；
2. 至少配置的 `master->quorum` 票。

自己还没投票时，会"跟风"投给当前票数最多的候选人，没有候选人则投自己（4835-4838）——这加快了收敛。注意未当选者会在 `sentinelFailoverWaitStart` 里等 `min(election_timeout, failover_timeout)` 后放弃（5109-5119）。

### 3.3 与 etcd raft 的对比：为什么说 Sentinel 是"简化版"

| 维度 | Sentinel | etcd/raft |
|---|---|---|
| 载体 | 借用 Redis 命令通道：`SENTINEL IS-MASTER-DOWN-BY-ADDR` 一条命令同时问"主挂了吗"+"投我一票"（3934-3950、4711-4718） | 专用 RPC（RequestVote / Heartbeat） |
| 任期心跳 | 无 leader 任期续约，纪元只在事件时推进 | leader 周期性心跳维持权威 |
| 日志复制 | 无。选举只决定"谁来改配置"，配置本身经 Hello gossip + config_epoch 仲裁（2922-2938） | 选举与日志复制强绑定，只有日志最新的节点能当选 |
| 候选人自举 | 谁先发现 ODOWN 谁自增纪元发起（4942） | 随机选举超时触发 |
| 防瓜分 | 节拍随机化（hz 随机，5473）+ 投票后随机退避（4758） | 随机化选举超时 + PreVote |
| 持久化 | 投票/纪元写入 sentinel 配置文件（sentinelFlushConfig，2265 起；`+vote-for-leader` 事件 4752） | WAL |

也就是说 Sentinel 只保留了 Raft 的"单纪元单票 + 多数派当选"骨架，把日志一致性换成了"配置纪元 config_epoch 谁大听谁的"——副作用是它不保证不丢已确认的写（本来主从异步复制也不保证）。

### 3.4 Cluster 内嵌选举对照

Redis Cluster 的故障迁移是数据节点自己做的：候选从节点自增 `currentEpoch` 发 `FAILOVER_AUTH_REQUEST`（src/cluster_legacy.c:4382-4385），masters 投票入口 `clusterSendFailoverAuthIfNeeded()`（3998）做三查：请求纪元不小于本地（4016）、本纪元未投过（`lastVoteEpoch == currentEpoch` 则拒，4026）、投票后记录 `lastVoteEpoch = currentEpoch`（4093）；票数达到 `size/2+1`（4248）即当选（4395）。机制同源（一纪元一票+多数派），差别在于**投票人资格**：Cluster 只有 master 投票、且会偏向 slot 覆盖完整的候选；Sentinel 是所有 Sentinel 都投票且不看数据新鲜度（选从时才看 offset）。

---

## 4. failover 状态机专节

### 4.1 七个状态与转换条件

状态定义在 src/sentinel.c:90-96；分发器 `sentinelFailoverStateMachine()`（5320-5342）只有五个 case——**UPDATE_CONFIG 不在状态机内推进**，而是由 `sentinelHandleDictOfRedisInstances()` 扫描到后统一执行切换（5418-5424）。

```
NONE ──start──► WAIT_START ──当选──► SELECT_SLAVE ──选到从──► SEND_SLAVEOF_NOONE
 (4940)          (5097)    超时未当选   (5130)   无从可选         (5149)
                            │abort      │abort        │从节点断连且超时
                            ▼           ▼             ▼
                           NONE        NONE          NONE      (5349-5360)
                                        SEND_SLAVEOF_NOONE ──发出──► WAIT_PROMOTION
                                        (5149-5173)    SLAVEOF NO ONE  (5177)
                                                                     │INFO 发现 role:master
                                                                     │ (2659-2684)
                                                                     ▼
                                        UPDATE_CONFIG ◄──全部从节点完成/超时── RECONF_SLAVES
                                        (5309-5318)       (5186-5245)          (5249-5304)
```

各状态要点（行号均为 src/sentinel.c）：

1. **启动**：`sentinelStartFailoverIfNeeded()`（4961-4989）三个前置：ODOWN（4963）、无进行中迁移（4966）、距上次尝试超过 `2×failover_timeout`（4969-4970，默认 180s×2）。`sentinelStartFailover()`（4937-4948）置 WAIT_START、打 `SRI_FAILOVER_IN_PROGRESS`（4941）、**自增纪元**（4942）、发出 `+try-failover`（4945）、failover_start_time 加 0~1000ms 随机抖动（4946）。
2. **WAIT_START**（5097-5128）：反复调 `sentinelGetLeader` 确认自己是否当选；未当选且超时则 `-failover-abort-not-elected` + abort（5116-5119）；当选发 `+elected-leader`（5122）进 SELECT_SLAVE。`SENTINEL FAILOVER` 强制迁移时凭 `SRI_FORCE_FAILOVER` 跳过选举（5108）。
3. **SELECT_SLAVE**（5130-5147）：调 `sentinelSelectSlave`；选不到则 `-failover-abort-no-good-slave`（5136）；选到则给从节点打 `SRI_PROMOTED`（5140）、记 `promoted_slave`（5141）。
4. **SEND_SLAVEOF_NOONE**（5149-5173）：候选从断连则原地等，超过 failover_timeout abort（5155-5160）；否则发事务化的 SLAVEOF NO ONE（见 4.3），进 WAIT_PROMOTION。
5. **WAIT_PROMOTION**（5177-5184）：状态机自己只管超时；真正的转换在 INFO 回调里——`sentinelRefreshInstanceInfo()` 发现被标 PROMOTED 的从节点报告 `role:master` 且 master 处于 WAIT_PROMOTION，就：`config_epoch = failover_epoch`（2672，**这就是新配置的权威纪元**）→ 置 RECONF_SLAVES（2673）→ `+promoted-slave`（2676）→ 调 client-reconfig-script "start"（2682-2683）→ 强制立刻发 Hello 通告新地址（2684；地址通告规则见 `sentinelGetCurrentMasterAddress`，1648-1662：RECONF_SLAVES 之后 Hello 里就报新主地址）。
6. **RECONF_SLAVES**（5249-5304）：以 `parallel_syncs`（默认 1，81 行）为并发上限逐个发 `SLAVEOF <新主>`（5292，5264-5265 控并发）；单从 10s（72 行）无进展则视为 DONE（5277-5284）。从节点侧的状态推进同样在 INFO 回调：SENT→INPROG（2729-2738，从报告的 master_host/port 指向新主）、INPROG→DONE（2741-2747，与新主的链路 up）。
7. **UPDATE_CONFIG**（5309-5318）：`+switch-master` 事件（5313）+ `sentinelResetMasterAndChangeAddress()`（1578-1633）——重置 master 实例（保留 Sentinel 列表，1611）、把旧主地址**当作从节点加回**（1606-1608，老主回来后自动降级）。

结束判定 `sentinelFailoverDetectEnd()`（5186-5245）：所有可达从节点 DONE 即 `+failover-end` 进 UPDATE_CONFIG（5216-5219）；超时则 `+failover-end-for-timeout` 强制收尾（5210-5214），并对漏网从节点 best-effort 补发 SLAVEOF（5225-5243）。**abort 只允许发生在 WAIT_PROMOTION 及之前**（5351 的 assert）——从节点真正成为主之后就"开弓没有回头箭"，只能走完（可能以超时方式）。

### 4.2 从节点选择：筛选条件与排序权重

`sentinelSelectSlave()`（src/sentinel.c:5051-5094）先做**硬性过滤**：

- 非 S_DOWN/O_DOWN 且链路未断（5070-5071）；
- 5×PING 周期内有响应（5072）；
- `slave_priority != 0`（5073，priority 0 = 永不提升）；
- INFO 新鲜（主 SDOWN 时放宽为 5s 窗口，否则 30s：5078-5082）；
- `master_link_down_time` 不超过 `(now - master.s_down_since_time) + 10×down_after`（5060-5062、5083）——即从节点不能断连太久以致数据缺口不可接受，源码自嘲这是"black magic"（5001）。

幸存者按 `compareSlavesForPromotion()`（5023-5049）排序，取第一个（5088-5090）：

```c
if ((*sa)->slave_priority != (*sb)->slave_priority)
    return (*sa)->slave_priority - (*sb)->slave_priority;   /* 1) priority 小者胜 */
if ((*sa)->slave_repl_offset > (*sb)->slave_repl_offset)
    return -1;                                              /* 2) offset 大者胜 */
...
return strcasecmp(sa_runid, sb_runid);                      /* 3) runid 字典序小者胜 */
```

优先级体现运维意志，offset 体现数据新旧（减少丢数据），runid 只是确定性的决胜票（保证所有 Sentinel 独立计算也能得出同一答案）。注意比较的是 `slave_repl_offset` 而非 master_repl_offset 差值，属于"近似最优"。

### 4.3 SLAVEOF 的原子下发

`sentinelSendSlaveOf()`（src/sentinel.c:4869-4934）不是裸发 SLAVEOF，而是一个 MULTI 事务：`SLAVEOF x y` + `CONFIG REWRITE`（持久化到磁盘，4907-4911）+ `CLIENT KILL TYPE normal/pubsub`（4900-4925，踢掉旧客户端触发 client 重连后走 ask-master 协议）。命令名经 `sentinelInstanceMapCommand()`（1689-1695）映射，兼容被 rename 过的实例。

---

## 5. 设计动机

**为什么 Sentinel 是外置进程？** 故障检测器必须独立于被检测者：主进程挂掉时检测逻辑必须还活着。外置还带来零侵入（老版本 Redis 无需内置集群代码即可获得 HA）与解耦（客户端只需会查 `SENTINEL get-master-addr-by-name`，4000）。代价是配置必须靠 gossip 对齐：Hello 消息（`__sentinel__:hello` 频道，79 行；payload 8 字段，2843-2846、3025-3032）承担了自动发现 Sentinel（+sentinel 事件，2890）、同步纪元（2913-2919）、传播新主配置（config_epoch 更大者胜，2922-2938）三件事。

**为什么选举用简化 Raft？** Sentinel 选举要决定的只是"谁来执行一个 7 步配置变更"，没有日志需要复制，多数派竞选的全部价值在于**防止两个 Sentinel 对同一个主并行做迁移**。为此单纪元单票 + 绝对多数 + quorum 双门槛（4849-4851）已经足够，引入完整 raft（心跳、日志匹配、PreVote）只会增加运维面。防抖动靠三处随机：hz 随机（5473）、failover_start_time 抖动（4946）、投票后随机退避（4758）。

**为什么需要 ODOWN 多数确认？** SDOWN 是单点观察，网络分区下"我看不见主"可能只是"我看不见"。但注意 ODOWN 本身也是弱共识（4596-4599 注释自认"weak quorum"），它的作用是把"误判导致切主"的概率压到需要 quorum 个独立观察者同时出错——而**最终切不切还取决于 leader 竞选**，那是第二个多数派。两层多数派（quorum 定事实，绝对多数定执行人）是 Sentinel 可靠性的核心结构。quorum 的另一个用途是权限下放：小 quorum 部署可以让部分 Sentinel 只做观察者（它们拿不到多数票就永远选不上 leader，但仍然参与 gossip）。

**为什么 master 自称 slave 也判 SDOWN？**（4572-4575）这处理的是"旧主重新上线但已被 SLAVEOF 降级"的场景：此时它对客户端来说就是不可写的主，应视为 down 并走迁移/重配置，而不是傻等它恢复 master 身份。对应的另一侧逻辑：非 PROMOTED 的从节点若自封 master 且"老主看起来正常"，Sentinel 会把它掰回从（+convert-to-slave，2691-2698），避免手工误操作留下双主。

---

## 6. FAQ 素材

1. **PING 超时就一定 SDOWN 吗？** 不一定。`LOADING`/`MASTERDOWN` 回复都算"活着"（2789-2791）；且超时基准是第一个未应答的 ping（act_ping_time，3086-3089），不是每个 ping 各算各的。
2. **down-after-milliseconds 配在从节点上有用吗？** 没用，master 的值会覆盖式传播给全部 slaves/sentinels（1666-1680）。
3. **ODOWN 达成后一定会切主吗？** 不一定，还要赢下 leader 竞选（绝对多数 + quorum 双门槛，4849-4851），输了等 10s abort（5116-5119）。
4. **为什么我的 Sentinel 日志有 +odown 又变 -odown？** ODOWN 是弱 quorum，别人的意见 5 秒不刷新就作废（4692-4696），票数回落即撤销（4628-4631）。
5. **从节点选择是"offset 最大"吗？** 不对，第一排序是 slave-priority（5028），offset 只是 priority 相同时的次级排序（5033-5037），priority=0 直接出局（5073）。
6. **failover 中途 leader Sentinel 宕机怎么办？** abort 只允许在 WAIT_PROMOTION 之前（5351）；晋升一旦发生就无法回滚，其他 Sentinel 会通过 Hello 的 config_epoch 仲裁接受新配置（2922-2938）。若 leader 死在晋升前，2×failover_timeout 后别的 Sentinel 可重新发起（4969-4970）。
7. **旧主恢复后会脑裂双主吗？** 不会自动双主：切主时旧主地址被登记为新主的从（1606-1608）；旧主回来若自称 master，Sentinel 会发 SLAVEOF 把它掰回去（2691-2698）。但**分区期间的旧主仍在服务写请求**，这部分写入会丢——Sentinel 不能阻止脑裂写，只能事后收敛。
8. **每个从节点是同时切新主的吗？** 不是，`parallel-syncs`（默认 1，81 行）控制并发，逐个发（5264-5265），单从卡住 10s 就跳过（5277-5284）。
9. ** SENTINEL FAILOVER 强制迁移为什么不需要主挂？** 它带 `SRI_FORCE_FAILOVER` 标志跳过"必须 ODOWN"与"必须当选"两个检查（5108、4963）。
10. **客户端怎么感知切主？** 三个通道：Pub/Sub 订阅 `+switch-master` 等事件频道（sentinelEvent 统一发布，688-695）、notification-script（698-705）、client-reconfig-script（984-996，leader 与 observer 都会收到，2682、2941）。

## 深挖素材

1. **一条命令的复用设计**：`IS-MASTER-DOWN-BY-ADDR` 同时是下线投票和 leader 竞选通道——第 4 参传 `"*"` 是纯探活，传 runid 是拉票（4717-4718）；回复是 `[is_down, leader, leader_epoch]` 三元组（3982-3985）。对比 Cluster 的 PONG 消息里内嵌 FAILOVER_AUTH_REQUEST/ACK。
2. **TILT 模式**：定时器间隔异常（<0 或 >2s，5451）说明时钟跳动或进程被冻结，此时一切超时都不可信，Sentinel 进入"只收集不行动"（5378-5382）；tilt 时 `is-master-down-by-addr` 恒答 0（3968），防止污染别人的 ODOWN。
3. **连接共享**：同一 Sentinel 对多个 master 的监测共用 hiredis 连接（instanceLink refcount，121-134、1089-1120），100 master×5 sentinel 只需 5 条出站连接——这是 sentinel 端扩展性的关键。
4. **配置纪元的仲裁链**：failover_epoch（4942）→ 晋升确认时赋给 config_epoch（2672）→ Hello gossip 传播（3032）→ 各 Sentinel 按 config_epoch 大小接受新地址（2923-2938）→ `get-master-addr-by-name` 返回仲裁后的地址（1648-1662）。这条链等价于一个"最后写者胜"的 CRDT 寄存器。
5. **与服务端的联动**：`MASTERDOWN` 回复来自实例处于 `replica-serve-stale-data no` 且断连的状态——Sentinel 把它当活着的证据，体现了"可用性判定"与"可写性"的刻意的分离。

---

## 写作要点速查表

| # | 函数/常量 | 行号 (src/sentinel.c) | 一句话 |
|---|---|---|---|
| 1 | SRI_S_DOWN/O_DOWN/MASTER_DOWN 等标志 | 44-59 | 实例状态位图 |
| 2 | SENTINEL_FAILOVER_STATE_* 七状态 | 90-96 | 状态机枚举 |
| 3 | 周期/超时常量(ping 1s, down-after 30s, failover_timeout 180s) | 63-77 | 时间基线 |
| 4 | sentinelTimer / hz 随机化 | 5460-5474 / 5473 | Sentinel 心跳入口 |
| 5 | sentinelHandleRedisInstance | 5368-5400 | 单实例每 tick 处理 |
| 6 | sentinelCheckSubjectivelyDown | 4526-4592 | SDOWN 判定(+sdown 在 4581) |
| 7 | sentinelCheckObjectivelyDown | 4600-4633 | ODOWN 汇总(+odown 在 4622) |
| 8 | sentinelAskMasterStateToOtherSentinels | 4680-4722 | 探活+拉票(传 runid 4717-4718) |
| 9 | sentinelVoteLeader | 4738-4763 | 一纪元一票(4746),投票退避(4758) |
| 10 | sentinelGetLeader | 4794-4857 | 绝对多数+quorum 双门槛(4849-4851) |
| 11 | sentinelStartFailover(IfNeeded) | 4937-4948 / 4961-4989 | ODOWN→自增纪元→WAIT_START |
| 12 | sentinelSelectSlave + compareSlavesForPromotion | 5051-5094 / 5023-5049 | priority>offset>runid |
| 13 | WAIT_START/…/RECONF 五个状态函数 | 5097/5130/5149/5177/5249 | 状态机各态 |
| 14 | INFO 回调中的晋升确认与 RECONF 推进 | 2659-2684 / 2725-2748 | WAIT_PROMOTION→RECONF_SLAVES(2673) |
| 15 | sentinelFailoverStateMachine + Abort | 5320-5342 / 5349-5360 | 分发器;abort 只在晋升前(5351) |
| 16 | sentinelFailoverSwitchToPromotedSlave | 5309-5318 | +switch-master(5313) |
| 17 | sentinelEvent(通知三通道) | 651-706 | 日志+Pub/Sub+notification-script |
| 18 | cluster_legacy.c 选举对照 | 4245/4248/3998/4026/4382/4395 | Cluster 内嵌选举关键行 |
