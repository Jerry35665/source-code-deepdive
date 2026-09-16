# O - 集群 slots 迁移机制深读

> 源码版本：Redis unstable 分支，commit `e8726d18e5bab24cbfcb0a0c36f21ce5a1140471`（2025 年）。
> 本文所有 `文件:行号` 均以该 commit 实际 grep/Read 核对。
> 版本注意：在该 commit 的源码布局中，`MIGRATE/DUMP/RESTORE/ASKING` 已从传统的 `db.c/server.c` 移入 **src/cluster.c**；`CLUSTER SETSLOT/ADDSLOTS...` 位于 **src/cluster_legacy.c** 的 `clusterCommandSpecial()`；请求路由 `getNodeByQuery()` 位于 **src/cluster.c**。阅读旧版书籍（引用 `db.c`）时需按此映射换算。

---

## 1. 全景：一次 slot 迁移的完整流程

运维（或 `redis-cli --cluster reshard`）把 slot 1000 从节点 A 迁到节点 B，标准五步：

```text
 运维/reshard 编排器                源节点 A (当前 owner)              目标节点 B
 ==================               =========================        ========================
                                  [状态: slots[1000]=A
                                         migrating[1000]=NULL]
 1) A: CLUSTER SETSLOT 1000
      MIGRATING <B-id>     ─────► migrating_slots_to[1000]=B      (B 需已在 A 的
                                  cluster_legacy.c:6108             nodes 表中)

 2) B: CLUSTER SETSLOT 1000
      IMPORTING <A-id>     ─────────────────────────────────────► importing_slots_from[1000]=A
                                                                  cluster_legacy.c:6125

 3) 循环搬 key（编排在客户端侧，
    如 redis-cli）:
    A: CLUSTER GETKEYSINSLOT 1000 10  ──► 返回 10 个 key        (cluster.c:1020-1046)
    A: MIGRATE B_host B_port "" 0
         5000 KEYS k1..k10        ──► A 串行化 DUMP payload,
                                      同步写 64K 块到 B        (cluster.c:411,587-603)
                                      B 执行 RESTORE-ASKING ◄── (cluster.c:560-564)
                                      B 回复 +OK 后 A 才 DEL
                                      本地 key                 (cluster.c:650-660)
    ◄── 直到 GETKEYSINSLOT 返回空

 4) B: CLUSTER SETSLOT 1000
      NODE <B-id>          ─────────────────────────────────────► slots[1000]=B
                                ◄── A 收到 gossip 后也改 ──►      importing 清空
                                                                  + BUMP configEpoch
                                                                  + PONG 广播全网
                                    (cluster_legacy.c:6144-6199)

 5) A: CLUSTER SETSLOT 1000
      NODE <B-id>  (或 A 侧因
        无 key 自动清除)     ─────► slots[1000]=B (经 gossip/
                                    clusterUpdateSlotsConfigWith)
```

关键点：**步骤 3 期间整个集群照常服务**——A 上命中的 key 直接读，未命中的 key 返回 `ASK` 重定向到 B；只有步骤 4 的 `SETSLOT NODE` 才是真正的 ownership 交接点。

---

## 2. SETSLOT 状态机专节：四态转换

每个 slot 在节点本地有两个"迁移影子"数组（另加正式 owner 数组），定义在 clusterState 中：

- `server.cluster->slots[slot]` —— 正式 owner；
- `server.cluster->migrating_slots_to[slot]` —— "我的 key 正迁往谁"（源侧状态）；
- `server.cluster->importing_slots_from[slot]` —— "我在替谁收 key"（目标侧状态）。

`CLUSTER SETSLOT` 的入口在 `clusterCommandSpecial()`，src/cluster_legacy.c:6078 起，只允许 master 执行（6086-6089 "Please use SETSLOT only with masters."）。

### 2.1 四态转换条件与代码位置

| 状态 | 命令 | 前置校验 | 效果 | 行号 |
|---|---|---|---|---|
| MIGRATING | `SETSLOT s MIGRATING <id>` | 自己必须是 s 的 owner（"I'm not the owner..."）；目标必须是已知 master | `migrating_slots_to[s] = n` | 6093-6108 |
| IMPORTING | `SETSLOT s IMPORTING <id>` | 自己**不是** owner（"I'm already the owner..."）；来源必须是已知 master | `importing_slots_from[s] = n` | 6109-6125 |
| STABLE | `SETSLOT s STABLE` | 无 | 同时清空两个影子状态（迁移中止/回滚用） | 6126-6129 |
| NODE | `SETSLOT s NODE <id>` | 若自己仍是 owner 且槽内还有 key 则拒绝："Can't assign hashslot %d to a different node while I still hold keys..." | `clusterDelSlot` + `clusterAddSlot` 交接 owner；详见 2.3 | 6130-6199 |

```c
/* src/cluster_legacy.c:6126-6129 */
} else if (!strcasecmp(c->argv[3]->ptr,"stable") && c->argc == 4) {
    /* CLUSTER SETSLOT <SLOT> STABLE */
    server.cluster->importing_slots_from[slot] = NULL;
    server.cluster->migrating_slots_to[slot] = NULL;
}
```

### 2.2 各状态下的读写行为（与第 4 节路由联动）

- **STABLE（默认）**：请求按 `slots[]` 表路由，owner 不匹配就是 MOVED（cluster.c:1320-1323）。
- **MIGRATING（源侧）**：命令的所有 key 本地都在 → 正常执行；只要有 key 缺失（已迁走）→ 整条命令返回 `ASK` 指向目标；部分在部分不在 → `TRYAGAIN`（cluster.c:1281-1290）。
- **IMPORTING（目标侧）**：只有带 `ASKING` 标志的请求才被服务；带了但多 key 且不全在 → `TRYAGAIN`（cluster.c:1296-1305）。
- **NODE（收尾后）**：影子状态清空，回归 STABLE 路由表。

### 2.3 SETSLOT NODE 收尾：ownership 确认三件事

在**目标节点 B** 上执行 `SETSLOT 1000 NODE <B-id>` 时（cluster_legacy.c:6130-6199）：

1. **空槽检查/自动清迁移态**：若本地槽已无 key 且 `migrating_slots_to` 非空，顺手清掉（6155-6157）——这就是源节点 A 常常"不需要第五步"的原因：A 在 gossip 中看到 B 成为新 owner 后，`clusterUpdateSlotsConfigWith()` 会替 A 改表（cluster_legacy.c:2330，2390-2397 处 `clusterDelSlot`+`clusterAddSlot`）。
2. **bump configEpoch**：若是自己导入自己的 slot，调用 `clusterBumpConfigEpochWithoutConsensus()`（6191），该函数把 `currentEpoch++` 并赋给自己（cluster_legacy.c:1709-1729）。**不经多数派投票、单方面抬 epoch**，注释明确说明冲突由 epoch collision resolution 兜底（1725-1740 一带注释）。这是 slot 迁移与 failover 的本质区别：后者要选举，前者靠运维指令。
3. **全网广播**：`clusterBroadcastPong(CLUSTER_BROADCAST_ALL)`（6198）立刻向所有节点发 PONG 携带新 slots 配置，让全集群尽快收敛，而不是等 gossip 慢慢扩散。

另外若 A 迁走**最后一个** slot，A 会在 `SETSLOT NODE` 里把自己降级为 B 的 replica（6163-6176，`clusterSetMaster`，受 `cluster-allow-replica-migration` 开关控制）。

### 2.4 批量 slot 操作 ADDSLOTS/DELSLOTS（含 RANGE 变体）

- `CLUSTER ADDSLOTS/DELSLOTS`（cluster_legacy.c:6011-6038）：先用一个 `unsigned char slots[CLUSTER_SLOTS]` 位图**两遍扫描**——第一遍只解析参数（6021-6026），第二遍用 `checkSlotAssignmentsOrReply` 校验"槽不忙"（6027-6034），全部通过后才 `clusterUpdateSlots()` 一次性生效（6035）。**先全查后改**保证批量操作的原子语义：任一参数非法则整个命令失败、一个槽都不动。
- `ADDSLOTSRANGE/DELSLOTSRANGE`（6039-6077）：成对解析 start/end，start>end 报错（6063-6067），同样走位图统一提交。
- `clusterUpdateSlots()`（5630-5646）逐槽 `clusterAddSlot/clusterDelSlot`，并把"导入中"状态清掉（5638-5639：成为正式 owner 即不再是 importer）。
- 底层记账：`clusterAddSlot` 要求槽必须无主否则 C_ERR（cluster_legacy.c:5010-5021）；`clusterDelSlot` 顺带清理该槽的 shard channel 订阅（5023-5041）。`countKeysInSlot` 就是按槽分字典的 `kvstoreDictSize`（cluster.c:810-812）。

---

## 3. MIGRATE 专节：DUMP+RESTORE 的序列化与原子性

### 3.1 序列化格式 = "单 key 的 RDB 子集 + 尾部"

`MIGRATE` 的迁移介质不是自定义协议，而是 **DUMP 载荷**：`createDumpPayload()`（src/cluster.c:87-118）按三段拼装：

```c
/* src/cluster.c:95-104（节选） */
/* Serialize the object in an RDB-like format. It consist of an object type
 * byte followed by the serialized object. This is understood by RESTORE. */
rioInitWithBuffer(payload,sdsempty());
serverAssert(rdbSaveObjectType(payload,o));
serverAssert(rdbSaveObject(payload,o,key,dbid));
/* ... footer: 2 bytes RDB version (little endian) + 8 bytes CRC64 */
```

即：`[RDB 类型字节][rdbSaveObject 序列化的值][2 字节 RDB_VERSION][8 字节 CRC64]`——完全复用 RDB 的编码函数，等于"单条 RDB 记录"。接收端 `restoreCommand()`（cluster.c:168-293）先用 `verifyDumpPayload()` 校验版本号与 CRC64（cluster.c:121-144，校验实现 226-230 调用），再 `rdbLoadObject` 反序列化（233-238）。CRC 校验保证跨网络传输的完整性；RDB 版本号防止高版本序列化低版本无法解析。

TTL 语义：`RESTORE` 的 ttl 参数是**相对毫秒**（加 `ABSTTL` 才是绝对时间，cluster.c:245；RESTORE-ASKING 流程里 MIGRATE 发送的本身就是换算好的剩余 TTL，见 3.2）。若换算后发现已过期，目标端直接不建 key 返回 +OK（246-257）。

### 3.2 单 key 与批量：一条 MIGRATE 传输多个 key

`migrateCommand()`（src/cluster.c:411）核心流水：

1. **KEYS 选项**：`MIGRATE host port "" 0 timeout KEYS k1 k2 ...` 批量形态，要求 key 参数位必须是空串（cluster.c:454-463）。
2. **NOKEY 快速返回**：所有 key 本地都不存在（比如刚好过期）时回复 `+NOKEY` 而不是错误（494-498）——注释说明"key 过期是正常情形"。
3. **构造 RESTORE-ASKING 协议**：集群模式下向目标发送的是 `RESTORE-ASKING` 而非 `RESTORE`（cluster.c:560-564），前者自带 CMD_ASKING 标志（commands.def:11414），使目标节点绕过路由检查接收本不属于自己的槽。TTL 逐 key 换算为剩余毫秒，`ttl<1` 钳到 1（cluster.c:543-549）。LRU/LFU 元数据不在 MIGRATE 里传（RESTORE 的 IDLETIME/FREQ 选项可选传，cluster.c:181-201，但 MIGRATE 未使用）。
4. **同步传输**：整个 cmd buffer 按 **64KB 块** `connSyncWrite` 阻塞写出（cluster.c:587-603），然后同步逐 key 读一行回复（628-662）。**阻塞的是执行命令的线程**——这是 MIGRATE 只适合运维/reshard 编排、不适合业务调用的原因之一。
5. **原子性保证（两阶段）**：
   - 目标端每个 key 的 RESTORE 默认**不允许覆盖已存在 key**（cluster.c:212-215 返回 BUSYKEY），除非 MIGRATE 带 REPLACE（源端在协议里追加 REPLACE 参数，cluster.c:578-581）；
   - 源端**只有收到目标对该 key 的 +OK 确认后才删除本地 key**（cluster.c:650-660 `dbDelete`），并把整条 MIGRATE 改写为 `DEL k1..kn` 用于复制/AOF 传播（cluster.c:678-692，del_idx 只包含已确认的 key）。带 COPY 选项则不删不改写。
   - 因此单个 key 的视角是"先在目标落地、再从源删除"，不会出现双删；但**跨节点没有分布式事务**：目标写入成功、源删除前崩溃，会短暂双份（由后续 ownership 收敛解决）。
6. **失败重试与清理**：socket 错误且第一个回复都没读到（j==0）时安全重试一次（cluster.c:667-671、738-741）；重试前关闭缓存连接（732）；超时（ETIMEDOUT）不重试（738）；最终向客户端回 `-IOERR error or timeout writing/reading to target instance`（745-748）。
7. **连接缓存**：对 host:port 缓存最多 64 条连接、10 秒不用即关（cluster.c:300-301），并记忆 last_dbid 免去重复 SELECT（526-531、709）。

### 3.3 编排者视角：redis-cli --cluster reshard

reshard 不是服务端自动完成的：redis-cli 反复执行 `CLUSTER GETKEYSINSLOT <slot> <pipeline数>` 取一批 key（src/redis-cli.c:5143，循环在 clusterManagerMigrateKeysInSlot，5129 起），对每批发 MIGRATE，直到取空，再依次对目标/源发 SETSLOT NODE。**GETKEYSINSLOT + MIGRATE + SETSLOT 三件套全部在客户端编排**，服务端只提供原语。

---

## 4. ASK 重定向专节

### 4.1 判定逻辑（getNodeByQuery）

所有客户端命令在 `processCommand` 里经 `getNodeByQuery()` 路由（src/server.c:4207-4222，返回非本节点即 `clusterRedirectClient` 回错误）。迁移期的判定（src/cluster.c:1110-1324）：

```c
/* src/cluster.c:1281-1290 */
if (migrating_slot && missing_keys) {
    /* If we have keys but we don't have all keys, we return TRYAGAIN */
    if (existing_keys) {
        if (error_code) *error_code = CLUSTER_REDIR_UNSTABLE;   /* ->TRYAGAIN */
        return NULL;
    } else {
        if (error_code) *error_code = CLUSTER_REDIR_ASK;
        return getMigratingSlotDest(slot);
    }
}
```

- `migrating_slot/importing_slot` 的判定在 1202-1208（first key 所属槽处于迁移/导入态）；
- `missing_keys` 靠对命令的每个 key 做 `lookupKeyReadWithFlags` 逐个数出来（1232-1237，`LOOKUP_NOTOUCH|NOSTATS|NONOTIFY|NOEXPIRE`，不触碰缓存与统计）；
- 多 key 不同槽：CROSSSLOT（1212-1218）；槽无主：CLUSTERDOWN（1190-1195）。
- 特例：**MIGRATE 命令本身**在槽 open（迁移/导入中）时总是本地执行（cluster.c:1276-1277），否则 MIGRATE 会被自己的路由逻辑拦住。
- 错误码枚举在 src/cluster.h:29-36（`CLUSTER_REDIR_ASK=3 / MOVED=4 / UNSTABLE(TRYAGAIN) / CROSS_SLOT / DOWN_*`）。

### 4.2 为什么是 ASK 而不是 MOVED

两者从 `clusterRedirectClient` 发出的格式同为 `-ASK slot host:port` / `-MOVED slot host:port`（src/cluster.c:1350-1356），语义差别全在**客户端协议约定**上：

- **MOVED = 永久性归属变更**："slot 已经不归我，更新你的槽位映射表"。迁移中的 slot 归属**尚未变更**——`slots[1000]` 仍指向 A——如果发 MOVED，客户端会错误地永久改写本地映射，而此时槽里绝大多数 key 可能还在 A。
- **ASK = 临时性单次指路**："这一条请求里你问的那个 key 可能已经搬走了，去 B 问一次，但**别改你的映射表**"。并且要求客户端去 B 前先发 `ASKING` 命令：`askingCommand()` 给客户端打上 `CLIENT_ASKING` 标志（src/cluster.c:1570-1579），目标节点 B 在 importing 态时**只服务带该标志的请求**（cluster.c:1296-1297 检查 `CLIENT_ASKING` 或 CMD_ASKING）。标志每个命令后自动清除（src/networking.c:2309-2310），所以是"一次性通行证"。
- 正因为迁移期源/目标两侧都要"让一部分请求穿过正式路由表"，协议才需要第三个动词：ASK 的准确性由**两节点协作状态**（migrating+importing）+**ASKING 标志**共同保证，任何一侧没有进入对应状态，ASK 流程都不成立。
- 补充语义：`TRYAGAIN`（cluster.c:1300 的 UNSTABLE 分支，文案在 cluster.c:1338-1341）用于"多 key 命令但 key 部分迁移"，服务端不确定能否安全执行，让客户端重试；单 key 命令永远能给出明确 ASK/MOVED。

### 4.3 客户端处理：跟随 ASK 的标准动作

- redis-cli 交互模式：收到 `ASK` 后记录目标地址（与 MOVED 相同地切换连接），但额外置位 `cluster_send_asking`（src/redis-cli.c:2324-2327），重发命令前先执行 `cliSendAsking()`（3282-3287），并打印 "-> Redirected to slot [%d] located at ..."。
- 智能客户端（如 Jedis/Lettuce）规范做法：**不更新** slot 映射缓存，仅为本次请求换目标连接并前置 ASKING；只有 MOVED 才更新映射。
- 服务端兜底：阻塞在已迁走槽上的客户端会被超时检测主动踢一个重定向（`clusterRedirectBlockedClientBySlot`，cluster.c:1361 后的注释块说明该场景）。

---

## 5. 设计动机

**为什么迁移是手动/编排式，而非服务端自动 rebalance？**
服务端对 slot 迁移的全部内建支持只有"原子搬一个 key"（MIGRATE）与"状态标记"（SETSLOT）。选谁搬哪个 slot、并发多少、限速多少——这些策略性决策被推到客户端编排器（redis-cli --cluster reshard、各类 proxy/调度器）。好处：服务端保持简单、无内嵌调度器；迁移节奏完全可控（MIGRATE 是同步阻塞命令，天然限速）；出错时运维可以逐步回退。代价是流程繁琐、易半途而废（见 FAQ）。

**为什么需要两节点协作状态（migrating + importing），而不是单侧标记？**
迁移期不存在全局一致的"新路由表"：gossip 传播有延迟，各节点视图暂时分裂。两侧影子状态给了系统一个**局部一致的过渡协议**——A 知道"这些 key 我管但正在给 B"（于是发 ASK），B 知道"这些 key 我提前接收"（于是接受 ASKING 穿越路由检查）。任何一侧状态缺失都会退化成错误（B 无 importing → ASK 后仍被 MOVED 弹回；A 无 migrating → 全部当普通请求执行，迁走的 key 读不到）。这也解释了为什么 `SETSLOT MIGRATING/IMPORTING` 都要求目标节点已在本地 nodes 表中（cluster_legacy.c:6098-6107、6115-6124 "I don't know about node %s"）。

**ASK vs MOVED 的协议设计**
一个词的差别承载了"缓存策略"的契约：MOVED 可缓存（甚至应缓存），ASK 不可缓存且需 ASKING 认证。用两个错误码而非一个，客户端无需解析迁移上下文就能区分"该记住"与"仅本次"。`RESTORE-ASKING` 内部命令复用同一机制（commands.def:11414 带 CMD_ASKING），说明 ASKING 本质上是一个"服务端间迁移通道的握手令牌"。

**ownership 交接为什么用"单方面 bump epoch + PONG 广播"而不是选举？**
slot 迁移由运维显式发起，语义上不存在"两个候选者争一个 slot"的合法情形，因此目标节点 `clusterBumpConfigEpochWithoutConsensus()`（cluster_legacy.c:1709）直接把 currentEpoch 抬到全局最大值之上赋予自己，再广播 PONG。冲突情形（迁移同时发生 failover）交给既有的 epoch collision resolution（cluster_legacy.c:1725 起注释）。对比 failover 需要多数派投票，这里"运维指令 + 最高 epoch 胜出"是刻意选择的弱共识：快，但要求迁移期间集群大体健康、有人监督。

**为什么把 slot 拆成 per-slot 子字典（kvstore）？**
`countKeysInSlot` 是 O(1)（cluster.c:810-812），`GETKEYSINSLOT` 直接迭代槽内字典（cluster.c:1037-1046）。reshard 是全 slot 扫描驱动的，若 key 平铺在一张大表里，每次"槽里还有哪些 key"都要全表过滤。per-slot 字典把迁移的工作集降到 O(槽内 key 数)。

---

## 6. FAQ 素材

1. **迁移中 slot 归属到底算谁的？** 算源节点 A。`slots[1000]` 在全网收敛到 B 之前都指向 A；ASK/ASKING 是绕过这张表的一次性通道（cluster.h:29-36，cluster.c:1296-1305）。
2. **为什么目标端 RESTORE 报 BUSYKEY？** 迁移前目标已有同名 key（上次部分迁移残留或业务写入）。解决：MIGRATE 加 REPLACE（cluster.c:578-581；RESTORE 侧校验 cluster.c:212-215）。`redis-cli --cluster reshard` 会提示或按 --replace 处理。
3. **MIGRATE 中途断网会怎样？数据会丢吗？** 不丢：目标成功写入的 key 有确认的才被源端删除；未确认的源端保留（cluster.c:649-661）。最坏情形是目标有副本、源也有（双份），由后续 SETSLOT NODE + 路由收敛，不会双丢。
4. **`+NOKEY` 是错误吗？** 不是。源端要迁的 key 全部恰好过期时返回 NOKEY（cluster.c:494-498），编排器应跳过继续。
5. **SETSLOT NODE 报 "Can't assign hashslot ... while I still hold keys"？** 在源节点上先 `SETSLOT NODE` 且槽内还有残留 key（cluster_legacy.c:6144-6151）。说明 MIGRATE 没搬干净：继续搬或评估丢弃。
6. **TRYAGAIN 和 ASK 同时出现？** 多 key 命令部分 key 已迁走时优先 TRYAGAIN（cluster.c:1283-1285）；单 key 缺失才 ASK。客户端对 TRYAGAIN 的正确处理是原样重试。
7. **为什么 ASK 重定向后还要发 ASKING？** importing 侧只信任带 ASKING 的请求（cluster.c:1296-1297），否则 B 会把它当普通错位请求 MOVED 回 A，形成循环。ASKING 是一次性标志，每命令自动清除（networking.c:2309-2310）。
8. **迁移期间 MIGRATE 自己会不会被路由拦截？** 不会。槽处于 open 状态时 MIGRATE 强制本地执行（cluster.c:1276-1277），否则源端发往目标的搬运流会被自身路由检查弹回。
9. **迁移一半想放弃怎么办？** 两侧各 `CLUSTER SETSLOT <s> STABLE` 清影子状态（cluster_legacy.c:6126-6129），已搬走的 key 若要回迁则反向再做一次迁移；正式 owner 未变，集群路由不受影响。
10. **CLUSTER ADDSLOTS 报 "Slot X is already busy"？** 批量预检阶段发现任一槽已有主即整体失败（cluster_legacy.c:6027-6034），符合"全有或全无"语义。

## 7. 深挖方向

1. **gossip 与迁移态的交互**：`clusterUpdateSlotsConfigWith()` 对 importing 中的槽一律不自动改表（cluster_legacy.c:2372-2373 "The slot is in importing state, it should be modified only manually"）——手动迁移状态优先于 gossip 传播，防止迁移被流言"抢跑"。但拥有更高 configEpoch 的 sender 仍可夺走非导入槽并产生 dirty_slots（有 key 失主时记录，2384-2392）。
2. **nodes.conf 中的迁移状态持久化**：slot 行的 `[slot_num]-><nodeid>` / `-<nodeid>` 记号在重启时恢复 migrating/importing 状态（cluster_legacy.c:605-621），迁移是可跨重启恢复的过程，不纯是内存态。
3. **启发式自愈**：`verifyClusterConfigWithData()` 发现"本地有 key 但槽既不属于我也非导入中"时，槽无主则自认领、有主则自动置 importing（cluster_legacy.c:5240-5254）——迁移残留 key 的自愈入口。
4. **MIGRATE 的阻塞模型与替代**：MIGRATE 在调用线程内同步收发（cluster.c:587-616），大 value 会卡住该节点主线程；这正是 Redis 官方推荐 reshard 用小 pipeline 批量、以及社区出现 async 迁移方案（如 Redis Enterprise / 各云厂商）的原因。
5. **epoch 碰撞仲裁**：`clusterBumpConfigEpochWithoutConsensus` 刻意允许无共识抬 epoch（cluster_legacy.c:1709-1729），配套的碰撞解决逻辑（检测到同 epoch 时再次 bump 并传播，cluster_legacy.c:1740 后续函数）保证手动迁移与 failover 并发时仍能全局定序。

---

## 8. 写作要点速查表

| 要点 | 位置 |
|---|---|
| SETSLOT 四态入口（MIGRATING/IMPORTING/STABLE/NODE） | src/cluster_legacy.c:6078-6206 |
| MIGRATING 前置校验+置 migrating_slots_to | src/cluster_legacy.c:6093-6108 |
| IMPORTING 前置校验+置 importing_slots_from | src/cluster_legacy.c:6109-6125 |
| STABLE 清双影子状态（回滚入口） | src/cluster_legacy.c:6126-6129 |
| SETSLOT NODE：有 key 拒绝/自动清 migrating | src/cluster_legacy.c:6144-6157 |
| SETSLOT NODE：bump epoch + PONG 广播 | src/cluster_legacy.c:6191-6198 |
| clusterBumpConfigEpochWithoutConsensus 无共识抬 epoch | src/cluster_legacy.c:1709-1729 |
| ADDSLOTS/DELSLOTS 两遍扫描+位图批量提交 | src/cluster_legacy.c:6011-6038 |
| ADDSLOTSRANGE start>end 校验 | src/cluster_legacy.c:6063-6067 |
| clusterUpdateSlots 成为 owner 即清 importing | src/cluster_legacy.c:5630-5646 |
| GETKEYSINSLOT / COUNTKEYSINSLOT / countKeysInSlot | src/cluster.c:1020-1046 / 1009-1019 / 810-812 |
| MIGRATE 主流程（RESTORE-ASKING、64K 块、确认后删、改写 DEL） | src/cluster.c:411-749（关键 560-603、650-692） |
| createDumpPayload = RDB 类型+对象+版本+CRC64 | src/cluster.c:87-118（校验 121-144） |
| ASK vs TRYAGAIN 判定（missing/existing keys） | src/cluster.c:1281-1290 |
| importing 侧只服务 ASKING 客户端 | src/cluster.c:1296-1305 |
| ASKING 命令置位/每命令清除 | src/cluster.c:1570-1579；src/networking.c:2309-2310 |
| MOVED/ASK 错误串格式化 | src/cluster.c:1332-1359 |
| gossip 不覆盖 importing 槽 | src/cluster_legacy.c:2372-2373 |
| redis-cli reshard 编排（GETKEYSINSLOT 循环） | src/redis-cli.c:5129-5160 |

（完）
