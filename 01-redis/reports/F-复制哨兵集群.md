# F 篇 · 复制、哨兵与集群:源码深读报告

> 调研基线:Redis unstable 分支,commit `e8726d18`(2025-09-15),`version.h` 显示 255.255.255(开发标记)。本篇覆盖 `src/replication.c`、`src/sentinel.c`、`src/cluster.c`、`src/cluster_legacy.c` 及相关头文件。所有结论均标注 `文件:行号`,行号以该 commit 为准。
>
> 值得注意的一处代码考古:三个核心文件的版权头均同时保留了 "Redis Ltd." 与 "Valkey contributors"(replication.c:3-7、cluster_legacy.c:2-6),说明这条分支在 2024 年 license 变更后仍持续吸收了 Valkey 侧的修改——例如 rdb-channel 双连接全量同步就带有明显的 Valkey 血统。

---

## ① 高可用全景:三种形态的边界与演进关系

Redis 的高可用能力由三个相互独立又层层叠加的子系统构成,三者在源码里的耦合点极少量、且关系是"复用"而非"包含":

| 形态 | 核心文件 | 解决的问题 | 故障决策者 |
|---|---|---|---|
| 主从复制 | replication.c(5130 行) | 数据冗余 + 读扩展,提供 replid/offset 这套"复制时钟" | 无(手动 SLAVEOF/promote) |
| 哨兵 Sentinel | sentinel.c(5474 行) | 监控 + 自动故障转移,复用主从复制的全部机制 | 哨兵节点之间(基于 Pub/Sub 与投票) |
| 集群 Cluster | cluster.c + cluster_legacy.c(8246 行) | 数据分片(16384 slot)+ 分片内自动故障转移 | 数据节点之间(基于 cluster bus gossip) |

三者的演进关系可以概括为:**复制是地基,哨兵和集群是两套互斥的"地基之上的自动化"**。

1. **复制层只负责"字节流的对齐"**。主库维护全局递增的复制偏移量 `master_repl_offset` 和两个复制 ID `replid/replid2`(replication.c:1862-1893),从库通过 `PSYNC <replid> <offset>` 表达"我拥有哪个历史、断在哪里",主库据此决定增量续传(backlog)或全量(RDB)。这套机制对上层一无所知。

2. **哨兵是外置的观察者**。它不参与数据面,而是用 hiredis 异步连接向 master/replica 发 PING/INFO/PUBLISH(sentinel.c:3099-3163),靠 `__sentinel__:hello` 频道互相发现(sentinel.c:79、3000-3040),发现 master 客观下线后走一个六状态故障转移机(sentinel.c:90-96)。它的"写操作"只有一条:对目标实例发 `SLAVEOF`(sentinel.c:4869 起)。哨兵模式里,故障转移的合法性由**哨兵多数派**保证,复制链路本身的脑裂防护靠 `min-replicas-to-write` 这类主库侧参数。

3. **集群把故障检测内置到数据节点**。每个数据节点有两条 TCP 通道:客户端口(port)与集群总线口(port+10000,cluster_legacy.c:5991 的 `CLUSTER_PORT_INCR`)。总线走二进制 gossip 协议(cluster_legacy.h:94-105 定义了 11 种消息),故障转移由带 slot 的 master 投票完成(cluster_legacy.c:3998-4099),不再需要哨兵进程。复制机制被完整复用:master 故障时,replica 就是拿着自己同步到的 replid/offset 去 `clusterFailoverReplaceYourMaster()`(cluster_legacy.c:4207 起)接管 slot。

边界上最容易混淆的一点:**集群节点之间的故障检测(FAIL 投票)与 Redis 的复制完全解耦**——一个 replica 是否有资格发起选举,取决于它 master 的 FAIL 标记与自身数据年龄(cluster_legacy.c:4273-4313),而它到底落后多少字节,仍然由第①节的 replid/offset 体系回答。这就是"集群 = 分片 + 哨兵式自动化,但把哨兵去进程化"的准确含义。

---

## ② 主从复制全流程逐段解读

### 2.1 复制时钟:replid / replid2 / offset

整个复制体系的地基是三个全局量:

- `server.replid`:当前复制历史链的 40 字节随机 ID,由 `changeReplicationId()` 生成(replication.c:1862-1865)。
- `server.replid2` + `server.second_replid_offset`:**次级历史**。当实例从 slave 升为 master 时,`shiftReplicationId()` 把旧 replid 存入 replid2,并把 `second_replid_offset` 定为 `master_repl_offset+1`(replication.c:1881-1893)。注释里把 +1 的语义讲得很清楚:别人索要的是"它还没收到的第一个字节",所以我们只能对 `旧offset+1` 以前的历史背书。
- `server.master_repl_offset`:复制流的全局写位置。

主库判定 PSYNC 的完整条件在 `masterTryPartialResynchronization()`:replid 必须等于 `replid` 或(`replid2` 且 `offset <= second_replid_offset`)(replication.c:836-838),同时 offset 必须落在 backlog 现存区间 `[repl_backlog->offset, +histlen]` 内(replication.c:862-874)。任何一条不满足,走全量。

### 2.2 握手时序(全量同步,磁盘式)

```
 Replica                                          Master
    |  connect()                                     |
    |----------------------------------------------->|   repl_state=CONNECTING
    |  PING                                           |  syncWithMaster 状态机
    |----------------------------------------------->|   (replication.c:2871)
    |  <+PONG>                                        |
    |<-----------------------------------------------|
    |  AUTH <user> <pass>          (有 masterauth 时) |
    |----------------------------------------------->|   SEND_HANDSHAKE (2914)
    |  REPLCONF listening-port <p>                    |
    |----------------------------------------------->|
    |  REPLCONF ip-address <ip>    (有 announce-ip 时)|
    |----------------------------------------------->|
    |  REPLCONF capa eof capa psync2 [capa rdb-channel-repl]
    |----------------------------------------------->|   (2958-2960)
    |  PSYNC <replid|?> <offset|-1>                   |
    |----------------------------------------------->|   SEND_PSYNC (3039)
    |                                                 | masterTryPartialResync
    |                                                 |   失败→startBgsaveForReplication
    |  +FULLRESYNC <replid> <offset>                  |   (779-817, 回复延迟到 bgsave 启动后)
    |<-----------------------------------------------|
    |  $<len>\r\n 或 $EOF:<40字节随机场>\r\n           |  RDB 传输
    |<===============================================|   readSyncBulkPayload (2044)
    |  (加载期间每秒发一个 '\n' 保活)                   |   replicationSendNewlineToMaster (1925)
    |  <RDB 结束>                                     |
    |  MASTER <-> REPLICA sync: Finished with success |
    |<----------------------------------------------->|  增量流开始 (2454-2487)
```

几个容易漏看的细节:

- **PING 是握手第一步**,且只接受 `+PONG` 或认证类错误(replication.c:2886-2908),目的是尽早暴露"连错了端口/连到了非 Redis 服务"。
- **`+FULLRESYNC` 是延迟回复的**。因为回复里的 offset 必须是"将要生成的 RDB 快照对应的流位置",只有 bgsave 真正 fork 出去那一刻,`getPsyncInitialOffset()`(replication.c:759-761)的值才有效(replication.c:915-920 的注释明确写了这一点)。
- **REPLCONF capa 是能力协商**:eof 支持无盘 `$EOF:` 流式结束标记,psync2 支持 `+CONTINUE <newreplid>`,rdb-channel-repl(仅当主库开启 `repl-rdb-channel` 且 `repl-diskless-sync`,replication.c:1313-1316)触发双连接全量同步。

### 2.3 全量同步的三种 CASE 与主库状态机

`syncCommand()`(replication.c:1025-1237)把等待全量的 slave 置为 `SLAVE_STATE_WAIT_BGSAVE_START` 后分三种情况:

- **CASE 1**:磁盘式 bgsave 进行中,且已有另一个 slave 在 `WAIT_BGSAVE_END` 累积差异——若新 slave 的能力/需求是旧 slave 的子集(`(c->slave_capa & slave->slave_capa) == slave->slave_capa` 且 `slave_req` 完全一致,replication.c:1191-1192),直接挂到这次 bgsave 上,连输出缓冲都复制过来(`copyReplicaOutputBuffer`)。这是"一次 bgsave 服务多个 slave"的复用逻辑。
- **CASE 2**:socket(无盘)式 bgsave 进行中,新 slave 只能等下一次(replication.c:1206-1213),因为子进程直写的 socket 集合无法中途加人。
- **CASE 3**:没有 bgsave——若 `repl-diskless-sync` 开启且配置了 delay,先只登记、等 `replicationCron()` 里凑够 `repl-diskless-sync-max-replicas` 再 fork(replication.c:1217-1223;默认 delay=5 秒,config.c:3197),否则立刻 `startBgsaveForReplication()`。

`startBgsaveForReplication()` 里选磁盘还是 socket 的条件是一行布尔式:`socket_target = (server.repl_diskless_sync || req & SLAVE_REQ_RDB_MASK) && (mincapa & SLAVE_CAPA_EOF)`(replication.c:950)。

### 2.4 无盘同步与 EOF 标记

磁盘式传输走 `$<len>` 定长协议;无盘式走 `$EOF:<40 字节随机串>`,slave 用滑动窗口比对末尾 40 字节判定结束(readSyncBulkPayload,replication.c:2100-2109、2148-2160)。无盘模式下 master 在 fork 出的子进程与 slave 之间还要经过一个管道转发(`rdbPipeReadHandler/rdbPipeWriteHandler`,replication.c:1638-1766),使主进程能感知"子进程已死"并及时止损。

### 2.5 复制积压缓冲区(backlog):块链表,不是环形缓冲区

7.0 之后 backlog 的实现是**全局复制缓冲块链表 + 引用计数**:

- `feedReplicationBuffer()`(replication.c:391-491)把每个字节追加进 `server.repl_buffer_blocks` 链表尾块;块大小下限 `PROTO_REPLY_CHUNK_BYTES`、上限 `repl_backlog_size/16`(replication.c:427-428)。**同一个链表同时服务 backlog 和所有在线 slave**——每个 slave 用 `ref_repl_buf_node` 指向自己还没发完的第一个块并对其 `refcount++`(replication.c:460-465),backlog 自身也持有从头块的引用。
- 修剪在 `incrementalTrimReplicationBacklog()`(replication.c:318-371):只有当头块 `refcount == 1`(即仅 backlog 引用、没有慢 slave 拖着)且裁掉后仍不小于 `repl_backlog_size` 时才释放。因此**慢 slave 会把实际内存顶到 repl-backlog-size 之上**,这是"backlog 大小"与"复制缓冲内存"不能划等号的根源(内存记账在 `server.repl_buffer_mem`)。
- 部分重同步的查找走 `blocks_index`(rax 树,每 64 块建一个索引,server.h:584),`addReplyReplicationBacklog()` 先 rax 定位近似块再线性走链表(replication.c:709-742)。
- 默认 1MB(config.c:3244),下限 16KB(server.h:140);`repl-backlog-ttl` 空闲后释放 backlog 时会**同时换 replid**——否则会出现"旧主被提升的从库用 replid2 认亲、但自己期间又写过数据"的数据错乱,这段推理完整写在 replicationCron 的注释里(replication.c:4749-4772)。

### 2.6 命令传播与级联复制

`replicationFeedSlaves()`(replication.c:499-592)只有两件事值得特别注意:一是**第一行就短路**——`if (server.masterhost != NULL) return;`(replication.c:512):中间层 slave 不自己合成复制流,而是把 master 发来的原始字节流原样灌进自己的 backlog(`replicationFeedStreamFromMasterStream`,replication.c:629-639),保证**全链路共享同一份 replid 和 offset 空间**,这是 PSYNC2 能跨层级续传的前提。二是 `dictid == -1` 表示 PING/REPLCONF 这类不落库的命令,跳过 SELECT 合成(replication.c:505、535)。

心跳双向各有一条路:master 每隔 `repl-ping-replica-period` 向 slave 的复制流里塞 PING(replication.c:4660-4678);slave 周期性向 master 回 `REPLCONF ACK <offset>`(replication.c:4644-4646、4146-4165),这个 ACK 同时喂饱三件事:master 侧的 slave 超时检测(replication.c:4720)、`WAIT` 命令的 `replicationCountAcksByOffset()`(replication.c:4386)、以及 min-slaves 写保护。

### 2.7 rdb-channel:8.x 世代的全量同步新形态

当双方都支持 `rdb-channel-repl` 且部分重同步失败时,主库不回 `+FULLRESYNC` 而回 `+RDBCHANNELSYNC <client-id>`(replication.c:1118-1143);slave 据此**新开第二条连接**,在上面重新走 AUTH/REPLCONF 并发 `PSYNC ? -1`(rdbChannelSendHandshake,replication.c:3513-3555)。此后 RDB 从 rdb-channel 流入,而**主连接从 RDB 开始投递时就并行转发增量流**(`SLAVE_STATE_SEND_BULK_AND_STREAM`,replication.c:793-808),增量先缓存在 `replDataBufBlock` 链表里,等 RDB 加载完再回放(`rdbChannelStreamReplDataToDb`,replication.c:3838 起)。逻辑上主库把两条连接算作一个 replica(`replicationLogicalReplicaCount`,replication.c:86-98)。收益:全量期间的增量堆积从"主库输出缓冲"转移到"从库可控的磁盘外内存块",且增量不必等 RDB 发完才同步流动,大幅降低全量期间主库输出缓冲暴涨 OOM 的风险。

### 2.7b 两个状态机,一图流

把整条链路的两个状态机放在一起看会更清楚。主库视角,一个从属连接的生命周期是:`WAIT_BGSAVE_START → WAIT_BGSAVE_END → ONLINE`(syncCommand 里依次设置,replication.c:1157、784;`replicaPutOnline` 置 ONLINE,replication.c:1446 起),磁盘式在 bgsave 结束后由 `updateSlavesWaitingBgsave` 放行,无盘式则靠收到第一个 `REPLCONF ACK` 确认对端活着再上线(replconfCommand 内,replication.c:1335-1352)——用 ACK 而不是"连接关闭"来判定 EOF,是少盘同步里非常聪明的一笔:EOF 标记可能被截断,而 ACK 一定来自完整加载后的客户端。从库视角则是第二节握手图中的 `REPL_STATE_*` 枚举链:`CONNECT → CONNECTING → RECEIVE_PING_REPLY → SEND_HANDSHAKE → (AUTH/PORT/IP/CAPA 四次应答) → SEND_PSYNC → RECEIVE_PSYNC_REPLY → TRANSFER → CONNECTED`(syncWithMaster,replication.c:2850-3154)。两个状态机靠字节流上的四类事件对齐:RDB 尺寸行、`\n` 保活字节、ACK、以及复制流本身。读源码时建议始终双线并进,只盯一侧会漏掉大量防御逻辑(比如主库给预同步从库每秒发 `\n`,replication.c:4694-4706,正是为了不让对端在读 RDB 前就超时)。

### 2.8 手动故障转移:CLUSTER-无关的 `FAILOVER` 命令

replication.c 末尾藏着一个常被忽略的状态机:`FAILOVER [TO host port] [FORCE] [TIMEOUT ms]`(failoverCommand,replication.c:4954-5059)。流程:主库 `pauseActions(PAUSE_DURING_FAILOVER, ...)` 暂停客户端写 → cron 里 `updateFailoverStatus()` 等"某个 slave 的 ACK offset 追平复制流" → 主库 `replicationUnsetMaster()` 自降为从 → 从库侧在 `slaveTryPartialResynchronization` 里检测到 `FAILOVER_IN_PROGRESS`,发出 `PSYNC <replid> <offset> FAILOVER`(replication.c:2686-2690);收到该命令的主库(实为目标 slave)比对 replid 一致后直接变 master(replication.c:1031-1055)。这是**零数据丢失**的受控切主,与哨兵的"尽量少丢"不同。

---

## ③ 哨兵故障转移全流程

### 3.1 发现与数据结构

每个被监控对象是 `sentinelRedisInstance`(SRI_MASTER/SRI_SLAVE/SRI_SENTINEL 三类标志,sentinel.c:44-46)。哨兵对 master/slave 各维持命令连接 cc 与 Pub/Sub 连接 pc 两条 hiredis 异步连接;**对同一 master 的所有 sentinel 对等体做连接共享**(instanceLink 注释,sentinel.c:121-134:5 哨兵 × 100 master 场景从 500 条连接降到 5 条,PING 也从 500 份降为 5 份)。

发现协议是纯 Pub/Sub:每个哨兵每 2 秒(`sentinel_publish_period`,sentinel.c:68)向被监控实例的 `__sentinel__:hello` 频道 PUBLISH 一条 8 元组消息 `sentinel_ip,port,runid,epoch,master_name,master_ip,master_port,master_config_epoch`(sentinelSendHello,sentinel.c:3000-3040)。收到 HELLO 后(sentinelProcessHelloMessage,sentinel.c:2842-2954):

1. 不认识的 runid → 新增 SRI_SENTINEL 实例并落盘配置(2864-2914);
2. 对方的 `current_epoch` 更大 → 抬升本地 epoch 并 `+new-epoch`(2916-2922);
3. 对方携带的 **master config_epoch 更大且地址不同** → 说明别的哨兵已完成过一次故障转移,本地 `+switch-master` 改写被监控地址(2924-2946)。**这是哨兵集群配置收敛的最终仲裁:config_epoch 大者赢。**

### 3.2 sdown → odown → leader 选举

```
 [定时器 10Hz, sentinelTimer 5460]  (hz 随机化防哨兵同步:5467-5473)
        |
        v
 每个 master: 重连+周期命令(PING 1s / INFO 10s / PUBLISH 2s)
        |
        v
 sentinelCheckSubjectivelyDown (4526)
   超时依据 = act_ping_time 距今 > down_after_period
   或: 自称 master 的实例长期报告 role:slave (4571-4577)
        |  +sdown
        v
 sentinelAskMasterStateToOtherSentinels (4680)
   SENTINEL is-master-down-by-addr <ip> <port> <epoch> <myid|*>
        |  收集 SRI_MASTER_DOWN (4637-4672)
        v
 sentinelCheckObjectivelyDown (4600)
   自身 sdown 且 票数(含自己) >= quorum  →  +odown (4620-4626)
        |  ★ odown 只针对 master;slave 永远只有 sdown
        v
 sentinelStartFailoverIfNeeded (4961)
   条件: odown && 无进行中故障转移 && 距上次失败转移 > 2*failover_timeout
        |  failover_epoch = ++current_epoch (4937-4948)
        v
 [SENTINEL_FAILOVER_STATE_WAIT_START]  等选举结果
```

**quorum 与多数派是两个不同的数**。odown 判定用 `quorum`(弱法定人数,允许跨时间窗的消息延迟,sentinel.c:4596-4599 注释特意强调"no strong guarantees");而 leader 选举要求**绝对多数**:获得 `voters/2+1` 票**且**不低于 `master->quorum` 票(sentinelGetLeader,sentinel.c:4849-4851)。voters 的口径是"自从上次 SENTINEL RESET 以来见过的所有哨兵 +1"(4807)。

投票规则在 `sentinelVoteLeader()`(sentinel.c:4738-4763):每个 epoch 每个哨兵只能投一票(`master->leader_epoch < req_epoch` 守卫);**先到先得**;且如果投给了别人(不是自己),把自己的 `failover_start_time` 加上 `rand()%SENTINEL_MAX_DESYNC`(1000ms)随机延迟(4757-4758)——加上 `sentinelTimer` 里对 `server.hz` 的随机抖动(5467-5473),两处随机化共同避免"所有哨兵同时发起选举、互相分裂"的死循环。这是教科书 Raft 的 randomized timeout 在哨兵里的两个落点。

### 3.3 故障转移状态机

```
 WAIT_START ──(我是该 epoch leader, 5097-5128)──► SELECT_SLAVE
     │                                              │ 按序挑选: ①priority≠0
     │ 非leader且超10s: -failover-abort-not-elected  │ ②offset大者 ③runid小者
     ▼                                              ▼
 (abort)◄──无合格slave── ◄ ─ ─ ─ ─ ─ ─ ─ ─   SEND_SLAVEOF_NOONE (5149)
                                                    │ SLAVEOF NO ONE 已发
                                                    ▼
                                              WAIT_PROMOTION (5177)
                                                    │ INFO 观察到 role:master
                                                    │ (sentinelRefreshInstanceInfo 驱动)
                                                    ▼
                                              RECONF_SLAVES (5249)
                                                    │ 以 parallel-syncs 并发度
                                                    │ 向其余 slave 发 SLAVEOF <newmaster>
                                                    ▼
                                              (sentinelFailoverDetectEnd 5186)
                                                    │ 全部 RECONF_DONE 或超时
                                                    ▼
                                              UPDATE_CONFIG (5309-5318)
                                                +switch-master, 重置监控目标
```

**新主挑选规则**(`sentinelSelectSlave` + `compareSlavesForPromotion`,sentinel.c:5023-5094)先过滤:非 sdown/odown、连接活着、5×PING 周期内有响应、`slave-priority != 0`(priority 0 = 永不提升)、INFO 未过期、`master_link_down_time <= (now - master->s_down_since_time) + down_after*10`(5058-5083,注释自嘲"pretty much black magic"——含义是从库断链时间不能早于 master 故障太久,否则数据太旧)。再按三元组排序:**priority 小者优先 → 复制 offset 大者优先 → runid 字典序小者**。

**提升确认是间接的**:哨兵不依赖 `SLAVEOF NO ONE` 的返回值,而是等该实例 INFO 里 `role` 变为 master(sentinel.c:5163-5176 注释)。后续把其余 slave 指向新主也用同一命令对 `SLAVEOF + CONFIG REWRITE`(sentinelSendSlaveOf,4869 起),按 `parallel-syncs`(默认 1)限流逐个放行(5263-5299)。

**TILT 模式**是哨兵的自保机制:定时器间隔为负或超过 2 秒(`sentinel_tilt_trigger`)时进入 TILT,30 秒内"只采集不行动"(sentinelCheckTiltCondition,5447-5458;sentinelHandleRedisInstance 里的分叉,5378-5382),用于抵御时钟跳变或进程长时间冻结造成的全局误判。

---

## ④ 集群 gossip 与故障检测逐段解读

### 4.1 总线与消息

集群总线是二进制协议,消息类型共 11 种(cluster_legacy.h:94-105):PING/PONG/MEET/FAIL/PUBLISH/FAILOVER_AUTH_REQUEST/FAILOVER_AUTH_ACK/UPDATE/MFSTART/MODULE/PUBLISHSHARD。所有包头部携带 `currentEpoch` 与 `configEpoch` 两个全局时钟(cluster_legacy.h:237-238):**currentEpoch 是集群逻辑时钟,configEpoch 是 slot 配置版本号**,后者的比较决定 slot 归属仲裁。

连接拓扑上,每对节点之间保持**两条单向发起的连接**(各一条入站、一条出站,`link->inbound` 区分,cluster_legacy.c:2935 的分支即是按此处理)。只有出站连接的 PONG 才会刷新 `pong_received`(cluster_legacy.c:3005-3007),超时、握手、地址纠偏等判断也几乎都挂在出站链路上;入站连接主要承担响应与转发。这种"双向各一条"的设计让防火墙单侧放开时仍能工作,也让节点能以 socket 对端地址反向学习自己的公告地址(收到 MEET 时从 `connAddrSockName` 反推 myself->ip,cluster_legacy.c:2878-2891)。

**MEET 与 PING 的唯一区别是信任级别**:收到 MEET 时若发送者未知,无条件建 HANDSHAKE 节点并处理其 gossip 段(cluster_legacy.c:2897-2922);普通 PING 对未知节点不做任何事。`CLUSTER MEET ip port` 本身只是在本节点记一个 HANDSHAKE 节点并发 MEET(clusterStartHandshake,cluster_legacy.c:1981-2036;命令入口 5974-6001),**入队即返回**,真正的成员关系靠后续 PONG 握手完成:HANDSHAKE 节点收到对端真实 node id 后 `clusterRenameNode` 并清 HANDSHAKE 标志(2954-2961)。所以 MEET 是单向引导,双方最终各自把对方加入节点表。

### 4.2 gossip 段:11 种消息里最重要的载荷

PING/PONG/MEET 都携带 gossip 段。条目数为 `max(3, 节点数/10)`(clusterSendPing,cluster_legacy.c:3668-3670),注释里有一段完整的概率推导:在 2×node_timeout 的 failure report 有效窗内,每个节点大约交换 8 个包,按 1/10 采样率可保证**一个 PFAIL 节点能收到约 80% master 的失败报告**,足以凑出多数派(3642-3667)。**处于 PFAIL 的节点被无条件追加到 gossip 末尾**(3672-3674、3730-3749),加速失败状态扩散。

接收端对 gossip 条目做四类事(clusterProcessGossipSection,cluster_legacy.c:2097-2227):

1. **失败报告收集**:仅当发送者是 master、条目带 FAIL/PFAIL 标志时,`clusterNodeAddFailureReport()` 记一条(FIFO,窗口 2×node_timeout,1371-1401),然后 `markNodeAsFailingIfNeeded()`(2141-2147);
2. **pong 时间借力**:对已知且无失败嫌疑的节点,可以用 gossip 里"第三方看到的 pong_received"刷新本地时间戳,条件是不早于本地、且不超前本机时钟 500ms(2161-2177)——这让间接可达性也能传播;
3. **地址纠偏**:本地认为 FAIL/PFAIL 的节点若 gossip 显示他人正用新地址与它通信,则更新地址重连(2184-2198);
4. **成员扩张**:未知节点只有在"gossip 发送者本身是本集群已知节点"且不在黑名单(clusterBlacklistExists,防 MEET 后又被踢出的节点回流)时才被添加(2199-2222)。

### 4.3 PFAIL → FAIL:两阶段故障检测

```
 clusterCron (每100ms):
   node_delay = min(now-ping_sent, now-data_received)
   node_delay > cluster-node-timeout
        → 置 CLUSTER_NODE_PFAIL           (cluster_legacy.c:4829-4843)
          (特例: 集群只有一个 master 时直接升级 FAIL, 4838-4839)
        |
        v  PFAIL 是本地判断, 不影响任何路由决策
 markNodeAsFailingIfNeeded (1890):
   失败报告数(含自己) >= cluster->size/2 + 1
        → PFAIL 升级为 FAIL, clusterSendFail 广播全集群 (1906-1915)
        |
        v
 收到 FAIL 消息的节点: 直接置 FAIL 标志       (3190-3211)
        |
 恢复: 重新收到 PONG 时
   PFAIL → 直接清除 (3015-3018)
   FAIL  → clearNodeFailureIfNeeded: replica/无slot master 立即清;
           有slot master 需超过 node_timeout*CLUSTER_FAIL_UNDO_TIME_MULT
           且无人接管其 slot                 (1922-1952)
```

关键差异:PFAIL 是"我怀疑",**不触发任何客户端侧行为**;FAIL 是"多数派确认",才允许 replica 启动选举、才让 `clusterUpdateState` 在算 reachable_masters 时把它排除(cluster_legacy.c:5141)。

### 4.4 replica 选举:Raft 风格投票

master 被标 FAIL 后,其 replicas 在 `clusterHandleSlaveFailover()`(cluster_legacy.c:4245-4414)中竞选:

1. **资格**:自身是 replica、master 为 FAIL(或 manual failover)、master 有 slot、未被 `cluster-require-no-failover` 禁止(4273-4283);
2. **数据年龄门槛**:`cluster-slave-validity-factor` 存在时,断链时长不得超过 `repl_ping_slave_period + node_timeout × factor`(4300-4313);
3. **rank 延迟选举**:rank = 同 master 下复制 offset 比自己新的 replica 数(clusterGetSlaveRank,4113 起)。发起选举的定时为 `500ms 固定 + rand()%500 + rank×1000ms`(4318-4328)——**rank 越大越晚开票,让数据最新的 replica 几乎必然先拿到选票**;期间若 offset 追上别人导致 rank 变化,延迟会动态修正(4353-4366);
4. **拉票**:`currentEpoch++`,广播 FAILOVER_AUTH_REQUEST(4381-4392);
5. **投票约束**(clusterSendFailoverAuthIfNeeded,3998-4099):只有**持有 ≥1 个 slot 的 master** 有投票权(4010,注释点明集群法定人数的"size"就是持 slot master 数);每 epoch 只投一票(lastVoteEpoch,4026);同一 master 的 replicas 在 2×node_timeout 内只投一票(4059-4068);**候选 replica 声称的 slot,其现任主 configEpoch 不得大于请求者的 configEpoch**(4073-4090)——防止给持有陈旧 slot 视图的节点放行;
6. **过半即胜**:`failover_auth_count >= size/2+1` 后,把自身 `configEpoch` 提为选举 epoch 并接管 master 的 slot(4395-4410),随后 `clusterBroadcastPong(ALL)` 把新配置 ASAP 扩散(3782-3779 注释)。

Manual failover(`CLUSTER FAILOVER`)走 MFSTART 消息:master 收到后暂停客户端写,把自己的 `repl_offset` 通过带 PAUSED 标志的 PING 发给发起 replica(3252-3271);replica 在 `clusterProcessPacket` 里记录 `mf_master_offset`(2848-2862),等 ACK 追平后无延迟、无需 FAIL 前提地启动选举(4249-4250、4329-4334)——与 replication.c 的 `FAILOVER` 命令同理,是零丢失切主。

### 4.5 MOVED/ASK 与 resharding

slot 判定在 `keyHashSlot()`(cluster.h:57-76):CRC16(key) 的低 14 位;**`{...}` 内的内容优先参与哈希**(hash tag;无 `}` 或 `{}` 为空则回退整 key)。

请求路由在 `getNodeByQuery()`(cluster.c:1110-1324),把 MULTI/EXEC 也折叠进统一代码路径(1134-1149),产出七种裁决(cluster.h:30-37):

- **MOVED**:slot 现任主不是自己(1322)——永久性指路,smart client 应更新本地 slot 表;
- **ASK**:slot 正从本节点迁出(`migrating_slot`)且请求的 key 不在本地(1281-1290)——若同请求已有一部分 key 在本地,则只能回 TRYAGAIN(1284);
- **ASKING 的一次性豁免**:目标节点对导入中的 slot,只接受带 `CLIENT_ASKING` 标志的请求(cluster.c:1296-1305;askingCommand 置位后一个命令即失效,cluster.c:1570-1577)。**ASK 永远不该更新客户端的 slot 表**,因为它描述的是"这一次"的例外;
- 其余为 CROSSSLOT、TRYAGAIN、CLUSTERDOWN 三态(全局 FAIL 时的写拒绝,cluster.c:1251-1262)。

**multi-hop resharding 是三个命令的编排**,不涉及任何专用迁移协议:

1. 源节点 `SETSLOT <s> MIGRATING <dst>`、目标节点 `SETSLOT <s> IMPORTING <src>`(cluster_legacy.c:6093-6125),slot 进入"两边都有责任"的过渡态;
2. 逐 key `MIGRATE host port key db timeout [COPY REPLACE]`,传输时目标端使用 `RESTORE-ASKING` 语义(cluster.c:562),原子地在源删除、目标重建;
3. 目标节点 `SETSLOT <s> NODE <self>` 收尾:此时源节点必须已无该 slot 的 key(6144-6150 检查),目标端 `clusterBumpConfigEpochWithoutConsensus()` 自增 configEpoch(6180-6195,注释解释了为何可以不经投票自增——config epoch 冲突有专门的碰撞解决例程 `clusterHandleConfigEpochCollision`,1774 起)并 `clusterBroadcastPong(ALL)` 扩散新配置(6198)。

过渡态下 `clusterUpdateSlotsConfigWith()` 负责在收到携带新 slot 位图的 PING/PONG 时做权威 slot 表切换(2330 起),并把 slot 属主变化以 UPDATE 消息推给那些还拿着旧视图的节点(3133-3175 的反向纠正逻辑)。

### 4.6 新特性概览:ping 扩展与 shard-id

7.x 起 gossip 包支持 TLV 式 ping 扩展(cluster_legacy.c:2544-2633),当前五类:hostname、human_nodename、forgotten-node(黑名单 TTL 扩散,2653-2664)、**shard_id**(同分片标识,replica 直接继承 master 的 shard_id,2694-2698)、internal_secret(取双方最小值做集群内密钥对齐,2668-2672)。`CLUSTER SHARDS`、按 shard 聚合的运维视图都构建在 shard_id 之上;扩展兼容性通过 `CLUSTERMSG_FLAG0_EXT_DATA` 标志协商(2823-2825),旧节点不受影响。

---

## ⑤ 设计动机与取舍

**为什么哨兵与集群并存?** 三条源码证据支持"定位不同"的解释:

1. 集群的故障转移粒度是 **shard**,决策者是持 slot 的 master 多数派(cluster_legacy.c:4010、4248),它要求集群拓扑本身成立;哨兵的粒度是**单组主从**,只要求 ≥1 个哨兵进程,quorum 甚至可以低到 1(弱保证)。哨兵面向"单机多实例/中小规模"与"客户端不支持 cluster 协议"的世界;
2. 集群的数据模型有硬约束:多 key 操作必须同 slot(cluster.c:1096-1101 的 CROSSSLOT/UNSTABLE),事务与 Lua 被限制在单 slot。哨兵+主从没有这一约束,是"全量数据在每一台机器上"的复制语义;
3. 代码复用方式也印证了分层:cluster replica 的自动 failover 直接调用 `replicationSetMaster` 挂到新主(cluster_legacy.c:4851-4857),`FAILOVER` 手动切主逻辑在 replication.c 与 cluster_legacy.c 里各实现一份但语义对齐——复制层从未感知上层是谁。

**为什么是 16384 个 slot?** 源码内没有直接注释,但两处实现给出可复算的依据:(a) gossip 条目数按节点数 1/10 采样(cluster_legacy.c:3642-3667),slot 归属表用 16384 位位图随心跳传播(cluster_legacy.h 的 `myslots` 位图与 cluster_legacy.c:3122 的 `memcmp(sender_master->slots, hdr->myslots,...)`),位图开销 = 2KB/包;(b) 取 CRC16 低 14 位(cluster.h:64)。antirez 本人在博客中给出的经典论证是:若用 65536 slot,心跳中 slot 位图将达 8KB,gossip 在大集群下带宽不可接受;而 16384 在"集群上限约 1000 主节点"的推荐规模下既够分片又省带宽。结合本次阅读,可以补充一个源码视角:slot 位图出现在**每一条** PING/PONG/FAILOVER 请求里(cluster_legacy.c:4002 直接引用 `request->myslots` 位图做投票校验),头部体积对 gossip 频率(每节点每 node_timeout/2 至少一轮,cluster_legacy.c:4797-4805)做乘法,16384 是带宽与粒度的折中点。

**其他值得记录的取舍**:

- 复制是**异步**的,强一致的代价被显式做成可选 API:`WAIT`/`WAITAOF`(replication.c:4420-4498)把"等多少从库追到多少 offset"交给调用方,而不是内建同步复制;
- 故障检测处处使用"弱多数 + 时间窗"而非强一致:哨兵 odown 注释明言消息延迟导致无同时性保证(sentinel.c:4596-4599);cluster 的 failure report 窗口是 2×node_timeout(cluster_legacy.c:1401);
- 心跳里塞业务(PUBLISH/PUBLISHSHARD 走总线广播,cluster_legacy.c:3212-3235)换取无第三方依赖的发布订阅,代价是总线带宽与数据面耦合——`data_received` 甚至被纳入存活判定(2827-2831)。

---

## ⑥ 容易误解的点与面试级 FAQ

**Q1:PSYNC 的 offset 为什么处处 +1?**
因为 offset 语义是"已收到并处理到的最后一个字节的下一个位置"。从库重连时发 `cached_master->reploff+1`(replication.c:2675);主库升 replid2 时记录 `master_repl_offset+1` 为有效边界(replication.c:1890);backlog 起点也是 `master_repl_offset+1`(replication.c:173)。

**Q2:replid2 是备份吗?什么时候被用到?**
不是备份,是**历史交接凭证**。故障转移后新主的 replid 必然改变,它把旧主的 replid 存进 replid2 并声明"该历史有效到 offset X";旧主和其他从库用 replid2 向新主发起 PSYNC 才能命中部分重同步(replication.c:836-838、1881-1893)。从库收到 `+CONTINUE` 且主库 replid 变化时,同样要自己做一次 replid2 迁移并断开下级从库让他们重新协商(replication.c:2783-2804)。

**Q3:repl-backlog-size=1MB 意味着复制缓冲最多占 1MB?**
错。backlog 是共享块链表的"逻辑长度",慢 slave 会以 refcount 钉住头块,阻止修剪(replication.c:328-337),实际 `server.repl_buffer_mem` 可以远超 backlog 配置。repl-backlog-size 只保证"没有慢从库拖累时,能部分重同步的历史长度"。

**Q4:全量同步期间主库的新写入会丢吗?**
不会,但要分阶段:bgsave fork 之前的新写命令由主进程继续写入共享复制缓冲(fork 后的修改进系统 page cache 由子进程继承,故 RDB 是一致的 fork 时点快照);fork 之后 slave 处于 `WAIT_BGSAVE_END`,与在线 slave 一起继续接收流(replication.c:779-788 注释);RDB 发完后把累积部分发给 slave(`updateSlavesWaitingBgsave`)。

**Q5:哨兵 quorum=2、部署 5 个哨兵,几个哨兵同意才切换?**
两步答案:odown 需要 ≥2 个(含自己)认为 master 不可达(sentinel.c:4605-4617);但**执行**故障转移的 leader 需要 >5/2 即 3 票,且不少于 quorum(sentinel.c:4849-4851)。所以 quorum=2 时实际切换仍需 3 个哨兵参与投票。

**Q6:odown 状态可以出现在 slave 上吗?**
不能。`sentinelCheckObjectivelyDown` 只对 master 调用(sentinelHandleRedisInstance,sentinel.c:5393-5394 只在 SRI_MASTER 分支执行);slave 的不可达只产生 sdown,不会触发选举。集群侧对应物是:replica 超时也不会被投票 FAIL——只有 master 才进入故障检测主流程,replica 的 FAIL 标记甚至可被任意一次可达性确认直接清除(cluster_legacy.c:1929-1936)。

**Q7:哨兵选举为什么有时要 10 秒+才出结果?**
三层随机/等待:发起方 `failover_start_time` 带 0-1000ms 随机偏移(sentinel.c:4946);投票者先到先得使后发起者大概率落选,落选者等 `min(election_timeout=10s, failover_timeout)` 才 abort(sentinel.c:5109-5119);所有哨兵的定时器 hz 每轮随机化(sentinel.c:5473)防止周期性撞车。极端情况下需要多个 epoch 才能产生多数派。

**Q8:MOVED 和 ASK 的本质区别?**
MOVED 说"slot 已永久归我,更新你的路由表";ASK 说"slot 正在搬迁,这一次去问那台机器,且必须先发 ASKING"(cluster.c:1281-1305、1570-1577)。ASK 不更新客户端 slot 表;ASKING 标志只对下一条命令生效,因为它只该为"导入中的 slot"开一次性后门,防止把过渡态例外固化成路由。

**Q9:集群里所有节点都参与故障投票吗?**
否。投票权要求"是 master 且持有 ≥1 slot"(cluster_legacy.c:4010),quorum 的分母 `cluster->size` 也只数持 slot 的 master(cluster_legacy.c:5130-5146)。无 slot 的 master 和所有 replica 只传播失败报告,不投票(1898-1899 的注释说明 replica 也能帮忙转发 FAIL)。

**Q10:PFAIL 状态的节点会被客户端路由拒绝吗?**
不会直接因为 PFAIL 被拒。PFAIL 纯属本地怀疑;只有升级成 FAIL 后,`clusterUpdateState` 才会把它从 reachable_masters 里扣除,可能触发少数派判定进入 CLUSTER_FAIL(cluster_legacy.c:5141-5157)。另外 slot 未被覆盖/未绑定会在 getNodeByQuery 里直接回 CLUSTERDOWN(cluster.c:1190-1195)。

**Q11:从库会自己过期 key 吗?与复制一致性有什么关系?**
主库是唯一权威:主库对 key 的过期/驱逐会合成为 DEL/UNLINK 走 replicationFeedSlaves 传播;从库收到的是同一份字节流。复制层对此的贡献是"从库不自己产生写命令"——`replicationFeedSlaves` 在 `masterhost != NULL` 时直接 return(replication.c:507-512),从库仅转发 master 流,保证同链路 offset 单调一致。(过期机制的主动/惰性删除细节属于 db.c/expire.c 范畴,本篇不展开。)

**Q12:rdb-channel 全量同步是两条连接,主库怎么防串号?**
slave 在主连接收到 `+RDBCHANNELSYNC <client-id>`(replication.c:2750-2767),随后在 rdb-channel 上用 `REPLCONF main-ch-client-id <id>` 关联(replication.c:1413-1426),主库以 `lookupClientByID` 校验该 id 确实处于 `WAIT_RDB_CHANNEL` 才接受配对;两条连接在主库的 `server.slaves` 里各占一个 client,统计时用 `replicationLogicalReplicaCount` 去重(replication.c:86-98)。

---

## ⑦ 深挖问题清单(后续章节候选)

1. **共享复制缓冲的内存上界与 OOM 边界**:refcount 钉块机制下,`client-output-buffer-limit replica` 与 `repl_buffer_mem` 的相互作用;`closeClientOnOutputBufferLimitReached` 只在 add_new_block 时检查(replication.c:467-468)是否会漏杀超大块场景?可与 Valkey 的相关修复对照。
2. **clusterUpdateSlotsConfigWith 的完整正确性论证**(cluster_legacy.c:2330 起):configEpoch 仲裁、migrating/importing 过渡态与 UPDATE 消息三方交互,是否覆盖了"目标节点在 SETSLOT NODE 后立刻宕机"的窗口?碰撞解决(clusterHandleConfigEpochCollision,1774)的补票机制值得单独成节。
3. **哨兵 connection sharing 的失效路径**:`sentinelTryConnectionSharing`(sentinel.c:1089)与 `sentinelDropConnections`(1144)在地址变更、TLS 切换时的正确性;实例 link 的 `pending_commands` 上限(SENTINEL_MAX_PENDING_COMMANDS=100,sentinel.c:82)对故障检测延迟的影响。
4. **cluster 总线认证的演进**:`internal_secret` 扩展取双方最小值对齐(cluster_legacy.c:2668-2672)的语义与安全边界;与 `cluster-announce-*`、`CLUSTER MEET` 黑名单(forgotten-node TTL)共同构成的新成员准入协议是否有形式化验证空间。
5. **两套手动 failover(replication.c 的 FAILOVER 命令 vs CLUSTER FAILOVER)的一致性模型**:前者靠 REPLCONF ACK 追平(replication.c:5068 起 updateFailoverStatus),后者靠 mf_master_offset + PAUSED PING(cluster_legacy.c:2848-2862);二者的丢数据窗口与 abort 语义差异,可作为"零丢失切换"专题的对照实验。

---

### 附:本篇实际阅读的源码位置索引

- replication.c:161-491(backlog 与 feed)、688-1022(PSYNC 判定与 bgsave 启动)、1025-1434(syncCommand/replconfCommand)、1862-1958(replid 管理)、2044-2511(readSyncBulkPayload)、2513-2532(同步应答原语)、2659-2846(slaveTryPartialResynchronization)、2850-3213(syncWithMaster 状态机)、3513-3661(rdb-channel 握手)、4146-4262(ACK/主客户端缓存)、4420-4601(WAIT/ack 统计)、4603-4798(replicationCron)、4865-5130(手动 FAILOVER)
- sentinel.c:44-119(标志/周期/状态常量)、121-150(instanceLink)、1268-1364(实例创建)、2842-3040(HELLO 收发)、3079-3163(周期命令)、4526-4633(sdown/odown)、4637-4722(is-master-down-by-addr)、4738-4857(leader 选举)、4869-5094(SLAVEOF/选从)、5097-5360(故障转移状态机)、5368-5474(timer/TILT)
- cluster_legacy.c:1890-1952(PFAIL→FAIL/恢复)、1981-2036(handshake)、2097-2227(gossip 处理)、2730-3307(clusterProcessPacket)、3630-3784(PING 构造/PFAIL 优先)、3998-4152(投票与 rank)、4245-4414(replica failover)、4562-4613(manual failover 状态)、4674-4878(clusterCron)、5090-5185(clusterUpdateState)、5973-6040(MEET/ADDSLOTS)、6079-6206(SETSLOT/resharding)
- cluster.c:411-570(migrateCommand)、1080-1324(getNodeByQuery)、1333-1360(clusterRedirectClient)、1570-1589(ASKING/READONLY)
- cluster.h:22-76(slot 常量与 keyHashSlot);cluster_legacy.h:94-105(消息类型)、237-274(包头部);config.c:3096-3197、3244(复制相关默认值)
