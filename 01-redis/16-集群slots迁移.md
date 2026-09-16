# 第 16 章 · 集群 slots 迁移:运维最高频操作

> 基线:commit `e8726d1`。行号以 src/cluster_legacy.c、src/cluster.c 为准。卷一 13 章讲了 gossip 协议——本章专讲 **slots 迁移**(扩缩容的核心操作)。

## 16.0 全景:一次 slots 迁移的完整流程

```
① 源 A: CLUSTER SETSLOT <slot> MIGRATING <B-id>  → 置 migrating_slots_to
② 目标 B: CLUSTER SETSLOT <slot> IMPORTING <A-id> → 置 importing_slots_from
③ 循环: A 上 CLUSTER GETKEYSINSLOT <slot> <count> 取批
          → MIGRATE(host B port key 0 timeout) — RESTORE-ASKING 落地 B
          → 确认后删 A 本地 + 改写为 DEL 传播
④ B: CLUSTER SETSLOT <slot> NODE <B-id>  → 交接 owner
     + clusterBumpConfigEpochWithoutConsensus + PONG 全网广播
⑤ A: gossip 收敛或显式 SETSLOT NODE;放弃迁移用 SETSLOT STABLE 清双影子
```

(SETSLOT 四态全在 cluster_legacy.c:6078-6206;NODE 收尾三件事:有 key 拒绝 :6144-6151、clusterBumpConfigEpochWithoutConsensus :6191、clusterBroadcastPong(CLUSTER_BROADCAST_ALL) :6198)

## 16.1 ASK vs MOVED:迁移期的临时指路

**迁移期 slots[] 仍指向 A(归属未变)**——客户端请求 A 收到 ASK 重定向(cluster.c:1281-1290):missing_keys→ASK,部分缺失→TRYAGAIN。**ASK 意味"单次临时指路+前置 ASKING"**,B 只服务带 CLIENT_ASKING 的请求(每命令自动清除 :2309-2310);**MOVED 意味"永久更新映射"**。多 key 部分迁移时返回 TRYAGAIN 而非 ASK——**协议精确区分了"全在"与"部分在"**。MIGRATE 自身强制本地执行(:1276-1277);RESTORE-ASKING 自带 CMD_ASKING(commands.def:11414),MIGRATE 集群模式下发它而非 RESTORE(:560-564)。

## 16.2 MIGRATE 的原子性

按 64K 块同步传输(cluster.c:587-603);**逐 key 收到 +OK 才删本地并改写为 DEL 传播**(:650-692)——部分成功不回滚但也不丢(DEL 保证了源端清理);目标端 RESTORE 默认拒绝覆盖(BUSYKEY :212-215)。DUMP 格式=RDB 子集:createDumpPayload(cluster.c:87-118,rdbSaveObjectType+rdbSaveObject+2B 版本+8B CRC64),verifyDumpPayload(:121-144)。

## 16.3 ADDSLOTS/DELSLOTS

**两遍扫描+位图批量提交**(先全查后改的原子语义,cluster_legacy.c:6011-6038);RANGE 版 start>end 校验(:6063)。gossip 不覆盖 importing 中的槽("modified only manually" :2372-2373);nodes.conf 用 `[slot]-><id>`/`-<id>` 持久化迁移态(:605-621)。

## 16.4 设计动机

1. **为什么迁移是手动而非自动 rebalance**:自动化 reba lance 需要共识+迁移期间的 IO 竞争控制——MinIO/Kafka 的自动 rebalance 是产品差异化,Redis 选择让运维者控制节奏;
2. **为什么需要两节点协作状态**:A 和 B 必须同时知道"这个 slot 正在迁移"——否则 ASK 的目标端会拒绝;IMPORTING/MIGRATING 是协作协议的状态;
3. **ASK vs MOVED 的协议设计**:ASK 是"单次指路"(不改客户端路由表),MOVED 是"永久更新"(改路由表)——**临时性与永久性的协议级区分**;
4. **逐 key 确认+DEL 传播**:每个 key 独立确认后才删源端——部分失败不丢数据(与卷二 04 章 EC 的逐分片确认同族)。

## 16.5 FAQ

**Q1:迁移期间客户端会报错吗?**
可能:TRYAGAIN(多 key 部分在 A)或 ASK 重定向(:1281-1290)——智能客户端自动跟随。

**Q2:为什么 ASK 不是 MOVED?**
(:1281-1290):ASK=单次临时,MOVED=永久——迁移期的临时性必须区分。

**Q3:MIGRATE 的原子性如何?**
逐 key:收到 +OK 才删本地(:650-692)——key 级原子,slot 级最终一致。

**Q4:目标端 BUSYKEY 怎么办?**
(:212-215):RESTORE 默认拒绝覆盖——需 REPLACE 参数或手动处理。

**Q5:迁移中断了怎么办?**
SETSLOT STABLE 清双影子状态(:6126-6129):已迁移的 key 在 B,未迁移的在 A——数据不丢但路由需要修。

**Q6:SETSLOT NODE 为什么要 bump configEpoch?**
(:6191):让全网知道"这个 slot 的新 owner 是 B"——configEpoch 是权威的仲裁。

**Q7:ADDSLOTS 为什么用两遍扫描?**
(:6011-6038):先查全合法再批量改——避免部分成功的中间态。

**Q8:IMPORTING 状态下能读吗?**
能:IMPORTING+ASKING 可服务(:1296-1305)——迁移中的数据仍在目标端可用。

## 16.6 小结与深挖方向

本章结论:**slots 迁移="两节点协作状态+逐 key 确认+ASK/MOVED 协议区分+configEpoch 仲裁"**。深挖:

1. MIGRATE 的 64K 块传输(:587-603)在大 value 的分块策略;
2. TRYAGAIN(:1281-1290)与 MGET 的组合语义;
3. SETSLOT NODE 的全网广播(:6198)在万 key slot 的收敛;
4. nodes.conf 的 `[slot]-><id>` 持久化格式与 gossip 的互相验证;
5. Redis Cluster 的 auto-rebalance(社区方案 RedisClusterManager)与手动迁移的对比。

> 集群 slots 迁移完——运维最高频操作的全链解剖。
