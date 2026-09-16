# 第 13 章 · 集群 gossip 协议:最终一致的故障检测与拓扑传播

> 基线:commit `e8726d1`。行号以 src/cluster_legacy.c、src/cluster.h 为准。

## 13.0 全景:gossip 消息传播

```
clusterCron(server.c:1639-1641,100ms 周期)驱动:
  每 10 次迭代(≈1s)随机抽 5 候选,PING pong_received 最旧者(cluster_legacy.c:4715-4737)
  每包 gossip 条目数 = N/10(min 3)+ PFAIL 节点全量追加(:3668-3674)
clusterProcessPacket(:2730)分发:PING/MEET→回 PONG 并学习(:2865-2926)
  FAIL→直接置标志(:3190)  PUBLISH→转发(:3212)
  AUTH_REQ/ACK→投票(:3236-3251)  UPDATE→纠正旧配置(:3272)
```

**gossip 管的是"大面积、容错敏感度低"的状态传播**(拓扑/槽位/PFAIL 传闻,最终一致,消息量 O(N²/10)/秒);raft 式多数派投票只保留在"唯一不能错"的选举——与 etcd 全量元数据走 raft 日志复制对照。

## 13.1 PFAIL/FAIL:两级故障检测

PFAIL=单节点本地判定 `min(ping_delay,data_delay)>cluster-node-timeout`(:4835-4836),收 PONG 即自愈(:3015);FAIL=gossip 报告累积进 fail_reports(:2142,:1371,有效期 2×timeout),**任一 master 凑齐 size/2+1 份即翻转并广播 FAIL**(markNodeAsFailingIfNeeded :1890-1917);撤销须 2×timeout 且无人接管槽(:1922-1952)。**gossip 条目 PFAIL 节点全量追加**(:3668-3674)——加速故障发现。

## 13.2 从节点选举:raft 缩小版

发起时 currentEpoch++(:4382);投票闸门含 lastVoteEpoch **一纪元一票**(:3998-4099,防双主核心);quorum=size/2+1(:4395);当选即接管槽并广播 PONG(:4207-4235)。**选举延迟=500ms+rand(500)+rank×1000ms**(:4318-4328),rank=复制偏移排名——偏移最跟上的从最先尝试。手动 failover:主暂停写→从追平 offset 才选(:4594;CLUSTER FAILOVER :6293-6347,FORCE/TAKEOVER 免协调/免投票)。

## 13.3 slots 迁移

SETSLOT 四态(:6078-6206):MIGRATING(:6108)/IMPORTING(:6125)/STABLE(:6128)/NODE(:6160);NODE 收尾须 bump configEpoch(:6191)+全网广播 PONG(:6198);迁移期路由 ASK/TRYAGAIN(cluster.c:1281-1305)。

## 13.4 设计动机

1. **为什么 gossip 而非 raft**:Redis Cluster 的元数据变更频率低(拓扑/槽位不常变)、容错敏感度中(数据不丢只影响路由)——gossip 的最终一致够用且去中心化;
2. **为什么 PFAIL/FAIL 两级**:PFAIL 是"我自己觉得不行",FAIL 是"多数人都觉得不行"——单点误判不触发全局 failover;
3. **gossip 的收敛速度与消息量**:每包 N/10 条 gossip + PFAIL 全量——O(N²/10)/秒的消息量在 N=1000 时已是百万级,这是 gossip 的实际规模上限;
4. **一纪元一票**(lastVoteEpoch :4026/:4093):防双主的核心——与 etcd raft 的 term 语义一致,但省掉了日志复制。

## 13.5 FAQ

**Q1:gossip 消息有多大?**
每包捎带 N/10 条(min 3)+PFAIL 节点全量追加(:3668-3674);单条 gossip 含节点名/IP/端口/flags/主从关系。

**Q2:节点加入怎么发现网络?**
CLUSTER MEET→clusterStartHandshake(:5974→:1981,HANDSHAKE|MEET 标志);gossip 只信任已知 sender 转发的条目(:2209);黑名单 60s(:1813)。

**Q3:FAIL 后为什么还要等 2×timeout 才撤销?**
(:1922-1952):误判的撤销窗口——防网络抖动导致反复翻转。

**Q4:从节点选举的 rank 是什么?**
(:4113):复制偏移排名——偏移最跟上的从最先尝试选举,延迟 500ms+rand(500)+rank×1000ms。

**Q5:slots 迁移期间 ASK 是什么?**
(:1281-1305):迁移期的"临时重路由"——ASK 告诉客户端"这次去新节点,下次还来旧的"。

**Q6:投票为什么是 size/2+1?**
持槽 master 数的多数(:1892):防少数派误判多数派故障——与 raft quorum 同一数学。

**Q7:手动 failover 的 FORCE/TAKEOVER 差别?**
FORCE=免协调从从节点发起;TAKEOVER=免投票直接提为主(:6293-6347)。

**Q8:黑名单 60s 是干什么的?**
(:1813):防止已被踢出的节点通过 gossip 重新加入——拓扑的安全过滤。

**Q9:configEpoch 碰撞怎么办?**
(:1774):碰撞时 node ID 大者赢——最终一致的仲裁。

**Q10:clusterCron 为什么是 100ms?**
(server.c:1639-1641):足够快以检测故障(秒级),足够慢以控制 gossip 消息量。

## 13.6 小结与深挖方向

本章结论:**gossip="100ms 心跳+随机选目标+PFAIL/FAIL 两级+一纪元一票选举"**;概率收敛换去中心化。深挖:

1. gossip 条目 N/10(:3668-3674)在万节点集群的消息量;
2. fail_reports 的 2×timeout 有效期(:2142)与网络分区的仲裁;
3. lastVoteEpoch(:4026/:4093)在多主竞争的防双主证明;
4. SETSLOT 状态机(:6078-6206)的 ASK/TRYAGAIN 路由语义;
5. 手动 failover 的 FORCE/TAKEOVER 与 raft leader transfer 的对照。

> 下一章:Sentinel 故障检测与选举。
