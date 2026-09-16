# 第 14 章 · Sentinel 故障检测与选举:外置仲裁的完整实现

> 基线:commit `e8726d1`。行号以 src/sentinel.c 为准。Sentinel 是**外置仲裁进程**,与 Cluster 的内嵌 gossip 故障检测(13 章)是两条完全不同的高可用路径。

## 14.0 全景:一次故障迁移的完整流程

```
MASTER_DOWN(sentinel.c:4581 +sdown 事件)
  → ODOWN(quorum 多数同意 :4600-4633)
  → 选举 Leader(Raft 简化版 :4738-4763)
  → SELECT_SLAVE(优先级/offset/runid 排序 :5023-5049)
  → SEND_SLAVEOF_NOONE(:5149)
  → WAIT_PROMOTION(INFO 确认 role:master :2672-2673)
  → RECONF_SLAVES(parallel_syncs 控并发 :5264)
  → UPDATE_CONFIG(+switch-master 事件 :5313)
```

## 14.1 SDOWN/ODOWN:两级下线判定

**SDOWN(主观下线)**:超时基准是 act_ping_time(第一个未获 pong 的 ping 起算,:3086-3089),elapsed > down_after_period 即打标并发 +sdown 事件(:4571-4584);PONG/LOADING/MASTERDOWN 都算活着(:2789-2791);master 自称 slave 超 down_after+2×INFO 周期也判 SDOWN(:4572-4575)。down_after_period 由 master 强制传播给所有 slaves/sentinels(:1666-1680)。

**ODOWN(客观下线)**:仅针对 master:自己先 SDOWN(自己算 1 票),统计其他 Sentinel 的 SRI_MASTER_DOWN 标志,≥quorum 则 +odown(:4600-4633);源码自认 **"weak quorum"**(:4596-4599):意见 5s 不刷新即作废(:4692-4696)——不是严格多数派,是"意见的时效衰减"。IS-MASTER-DOWN-BY-ADDR 一条命令复用为探活+拉票通道:runid 传 "*" 是纯探活,failover 已启动则传自己 myid(:4717-4718)。

## 14.2 选举:Sentinel 的 Raft 简化版

sentinelVoteLeader(:4738-4763):**每纪元一票**(:4746 条件),投给别人后随机退避自己的 failover_start_time(:4758)。sentinelGetLeader(:4794-4857):绝对多数(voters/2+1)且≥quorum **双门槛**才当选(:4849-4851);未投票者跟风投票多者(:4835-4838)。与 etcd raft 对照:无日志复制、无任期心跳,配置一致性靠 Hello gossip+config_epoch 仲裁;防瓜分靠 hz 随机化(:5473)。

## 14.3 failover 状态机:七状态的完整旅程

| 状态 | 行号 | 关键动作 |
|---|---|---|
| NONE→WAIT_START | :4961-4989 | ODOWN+距上次>2×failover_timeout;启动自增纪元 :4942 |
| SELECT_SLAVE | :5023-5049 | priority 小者>offset 大者>runid 字典序;priority=0 剔除 :5073 |
| SEND_SLAVEOF_NOONE | :5149/:4869-4934 | 事务化 SLAVEOF+CONFIG REWRITE+CLIENT KILL |
| WAIT_PROMOTION | :5177 | 只管超时;INFO 发现 role:master 才转进 :2672-2673 |
| RECONF_SLAVES | :5264 | parallel_syncs 默认 1 控并发 |
| UPDATE_CONFIG | :5313 | +switch-master 事件;旧主地址加回作从 :1606-1608 |

abort 只允许在 WAIT_PROMOTION 之前(assert :5351)。

## 14.4 与 Cluster failover 对照及设计动机

| | Sentinel | Cluster |
|---|---|---|
| 故障检测 | 外置进程探活 | 内嵌 gossip PFAIL/FAIL |
| 选举 | 简化 Raft(一纪元一票) | gossip 投票(一纪元一票) |
| 影响面 | 整个 master 组 | 单个 slot 拥有者 |
| 部署 | 独立 Sentinel 进程 | 无额外进程 |

1. **为什么 Sentinel 是外置进程**:Redis 主进程崩溃=数据面+控制面同时消失——外置仲裁进程的存活与数据面无关;
2. **为什么选举用简化 Raft**:Sentinel 选举只选 Leader(谁来做 failover),不需要日志复制——Raft 的子集就够;
3. **"weak quorum" 的自认**(:4596-4599):意见有时效(5s 过期),不是严格的多数派投票——**可用性与一致性的工程折中**;
4. **从节点选择的三级排序**:priority(人工干预)>offset(数据完整性)>runid(确定性的最后一道):每个排序维度对应一种运维场景。

## 14.5 FAQ

**Q1:SDOWN 和 ODOWN 的区别?**
SDOWN=我自己觉得不行(:4571-4584);ODOWN=多数 Sentinel 同意(:4600-4633)——只有 ODOWN 才触发 failover。

**Q2:quorum 配置的是什么?**
触发 ODOWN 的最低 Sentinel 数(:4600-4633);不是选举 Leader 的多数(那是 voters/2+1 :4849-4851)。

**Q3:为什么说 "weak quorum"?**
(:4596-4599):意见 5s 不刷新即作废——不是持久投票,是有 TTL 的"意见"。

**Q4:Sentinel 选举和 raft 什么关系?**
同构:一纪元一票+绝对多数+随机退避(:4738-4763);差别是不复制日志(只选 leader 不复制状态)。

**Q5:从节点优先级 0 意味着什么?**
(:5073):永远不参与 failover——纯数据副本,不提升为主。

**Q6:WAIT_PROMOTION 超时了怎么办?**
(:5177):abort 并退回 NONE——下次 ODOWN 再重试。

**Q7:parallel_syncs 是什么?**
(:5264):RECONF_SLAVES 阶段同时重配的从节点数——防全组同时从新主拉 RDB。

**Q8:+switch-master 事件给谁消费?**
(:5313):客户端(PubSub 频道)——通知应用切换连接。

**Q9:Sentinel 之间怎么发现?**
Hello gossip(:5473 hz 随机化):每 2s 发布自己的存在——自动发现+配置传播。

**Q10:abort 为什么只允许在 WAIT_PROMOTION 之前?**
(:5351):SELECT_SLAVE 之后已有从节点开始 SLAVEOF NO ONE——此时 abort 会造成数据孤岛。

## 14.6 小结与深挖方向

本章结论:**Sentinel="外置仲裁+SDOWN/ODOWN 两级+简化 Raft 选举+七状态 failover 状态机"**。深挖:

1. "weak quorum"(:4596-4599)的 5s TTL 在多 Sentinel 掉线时的误判面;
2. 从节点排序(:5023-5049)在 replica-priority 相同时的确定性行为;
3. parallel_syncs(:5264)在从节点 RDB 加载时间分布的并发调优;
4. hz 随机化(:5473)对 gossip 收敛速度的影响;
5. Sentinel 与 Cluster failover(13 章)在同规模部署的 RTO 对比。

> 下一章:RDB 格式与 AOF 重写——持久化的二进制契约。
