# H 章 · Redis Stream 与消费者组源码深读

> 调研对象:redis 源码(本仓库 clone 实际 commit:`e8726d1`,2025 年版本,含 7.4/8.x 的 cgroups_ref、XACKDEL 等新特性;行号以该 commit 为准,与旧版 6.x 有少量偏移)。
> 核心文件:`src/t_stream.c`(4566 行)、`src/stream.h`(结构定义)、`src/blocked.c`(阻塞读)、`src/rax.c`(底层有序树)。

---

## 1. 全景:Stream 的复合结构

Stream 是 Redis 唯一的"rax + listpack"复合对象。`stream` 结构(src/stream.h:16-32)包含:rax 树指针、`length`、`last_id`/`first_id`、`max_deleted_entry_id`(墓碑上界)、`entries_added`(历史累计写入数)、`cgroups`(消费组字典,懒创建)、`cgroups_ref`(7.4+ 新增:消息 ID → 消费组链表的反向索引)。

```
stream key "mystream" (OBJ_STREAM, src/stream.h:16)
│
├─ s->rax ──────────────────────────────────────────────────  有序基数树
│    key = 首条消息 ID 的 128bit 大端编码(streamEncodeID, t_stream.c:356)
│    │
│    [ms-1 seq-0] ──→ listpack 节点(宏节点, 存多条消息)
│    │                 ┌ count│deleted│num-fields│f1│f2│0 (master entry, t_stream.c:500-520)
│    │                 ├ flags│msΔ│seqΔ│field/value...│lp-count   ← entry 1
│    │                 └ flags│msΔ│seqΔ│...│lp-count             ← entry 2 ...
│    [ms-1 seq-N] ──→ listpack ...
│    ...
│
├─ s->cgroups (rax: 组名 → streamCG, 懒创建 t_stream.c:62)
│    "mygroup" ──→ streamCG (src/stream.h:58)
│                    ├─ last_id        组内已投递到的 ID
│                    ├─ entries_read   已读计数(lag 估算用)
│                    ├─ pel (rax)      组 PEL: 消息ID → streamNACK
│                    └─ consumers (rax): "alice" ──→ streamConsumer
│                                        └─ pel (rax): 消息ID → 同一个 streamNACK(共享值)
│
└─ s->cgroups_ref (rax: 消息ID → streamCG 链表, t_stream.c:2610)
     用于 O(引用数) 判断"这条消息还有没有被任何组的 PEL 引用"
```

要点:
- rax 的 key 不是"每条消息一个",而是"每个 listpack 宏节点一个",节点 key = 节点内首条消息 ID(t_stream.c:551)。
- streamNACK 是组 PEL 与消费者 PEL **共享**的同一对象(src/stream.h:95-101,注释明确"value is shared"),所以 XACK 只需从组 PEL 找到 NACK,即可顺藤摸瓜删消费者 PEL(t_stream.c:3168-3172)。
- 消息 ID 排序靠 128 位大端编码使字典序 == 数值序(t_stream.c:356-361,注释"sorted lexicographically")。

---

## 2. XADD 专节:ID 生成与 listpack 节点填充/分裂

### 2.1 ID 生成

自动 ID(`XADD key * f v`)由 `streamNextID` 生成(src/t_stream.c:130-139):

```c
void streamNextID(streamID *last_id, streamID *new_id) {
    uint64_t ms = commandTimeSnapshot();
    if (ms > last_id->ms) {
        new_id->ms = ms;
        new_id->seq = 0;          /* 新毫秒, 序号归零 */
    } else {
        *new_id = *last_id;       /* 时钟回拨: 沿用旧 ms */
        streamIncrID(new_id);     /* 并把 seq +1 */
    }
}
```

半自动 ID(`ms-*`)在 `streamAppendItem` 内处理:同一毫秒则取 `last_id.seq+1`,seq 溢出直接 EDOM(t_stream.c:432-438)。任何 ID 必须严格大于 `s->last_id`,否则 `errno=EDOM`(t_stream.c:451-454);上层 `xaddCommand` 把它翻译为 "The ID specified in XADD is equal or smaller than..."(t_stream.c:2168-2170)。`XADD ... 0-0` 在入口就被拒绝(t_stream.c:2141-2146)。

### 2.2 追加与节点分裂

`streamAppendItem`(t_stream.c:420)流程:

1. `raxSeek(&ri,"$",NULL,0)` 定位尾节点(t_stream.c:470-472);
2. **分裂判定**:尾节点字节数 `lp_bytes + totelelen >= stream_node_max_bytes` 或条目数 `count+deleted >= stream_node_max_entries` 时换新节点(t_stream.c:525-546);换节点前 `lpShrinkToFit` 收回预分配内存(t_stream.c:541);
3. **新节点 = master entry**:先写入 `count=1、deleted=0、num-fields、全部字段名、0 终止符`(t_stream.c:562-570),并把首个 entry 标记 `STREAM_ITEM_FLAG_SAMEFIELDS`(t_stream.c:574)——字段名只存一份,后续消息只存 delta;
4. **SAMEFIELDS 检测**:逐字段 memcmp 对比新消息与 master entry(t_stream.c:593-608),完全一致则该 entry 省略全部字段名;
5. **entry 编码**(t_stream.c:633-652):

```c
lp = lpAppendInteger(lp,flags);
lp = lpAppendInteger(lp,id.ms - master_id.ms);    /* 毫秒差值 */
lp = lpAppendInteger(lp,id.seq - master_id.seq);  /* 序号差值 */
if (!(flags & STREAM_ITEM_FLAG_SAMEFIELDS))
    lp = lpAppendInteger(lp,numfields);
/* ... field/value 对 ... */
lp = lpAppendInteger(lp,lp_count);  /* 反向遍历用的回跳计数 */
```

6. 收尾:`s->length++、entries_added++、last_id=id`,首条消息同时更新 `first_id`(t_stream.c:657-660)。

命令层 `xaddCommand`(t_stream.c:2124)还有三件复制相关的事:修剪后若为 `~` 近似模式,把 MAXLEN/MINID 参数**改写为精确值**保证 AOF/从库确定性(t_stream.c:2186-2194,改写函数 streamRewriteTrimArgument:2109);自动 ID 也回写进 argv 传播(t_stream.c:2201-2207);最后 `signalKeyAsReady` 唤醒阻塞的 XREAD(t_stream.c:2211)。

---

## 3. 消费者组专节:XGROUP、last_id 与 PEL 生命周期

### 3.1 XGROUP CREATE 与 last_id 语义

`xgroupCommand`(t_stream.c:2877)。CREATE 时 `$` 表示"从现在开始"——组 last_id 取 `s->last_id`,key 不存在则取 0-0(t_stream.c:2964-2973);MKSTREAM 顺带建空 stream(t_stream.c:2976-2982);重名报 BUSYGROUP(t_stream.c:2995)。组结构由 `streamCreateCG` 创建:t_stream.c:2764-2778,`pel`、`consumers` 各是一棵 rax。

last_id 的推进发生在**读取时**而非 ack 时:`streamReplyWithRange` 每发出一条消息,若 `id > group->last_id` 就更新(t_stream.c:1817-1837,经 `streamUpdateCGroupLastId`:2594,该函数同时维护全组最小 last_id 缓存的有效性)。所以 `XREADGROUP ... >` 交付即推进 last_id,不管有没有 XACK——**last_id 是"已投递"水位,PEL 才是"已确认"水位**,两者之差就是组内未确认集合。

### 3.2 PEL 的完整生命周期

| 阶段 | 命令 | 源码位置 |
|---|---|---|
| 创建 | XREADGROUP `>`(非 NOACK) | t_stream.c:1864-1897 |
| 回放 | XREADGROUP `0`/非`>`(只读自己的 PEL) | t_stream.c:1937-1972 |
| 查看 | XPENDING | t_stream.c:3300-3414 |
| 确认 | XACK | t_stream.c:3159-3176 |
| 接管 | XCLAIM / XAUTOCLAIM | t_stream.c:3651-3736 / 3838-3895 |
| 消失 | XGROUP DESTROY / DELCONSUMER | t_stream.c:3014-3026 / 3031 |

**创建**(交付时,`streamReplyWithRange` 内):

```c
streamNACK *nack = streamCreateNACK(consumer);          /* delivery_count=1 */
int group_inserted = raxTryInsert(group->pel,buf,...,nack,NULL);
int consumer_inserted = raxTryInsert(consumer->pel,buf,...,nack,NULL);
if (group_inserted == 0) {       /* 该消息已被本组别的消费者持有 */
    streamFreeNACK(nack);
    ...
    raxRemove(nack->consumer->pel,buf,...,NULL);        /* 从旧消费者夺走 */
    nack->consumer = consumer;
    nack->delivery_time = commandTimeSnapshot();
    nack->delivery_count = 1;
    raxInsert(consumer->pel,buf,...,nack,NULL);
} else if (group_inserted == 1 && consumer_inserted == 1) {
    nack->cgroup_ref_node = streamLinkCGroupToEntry(s, group, buf); /* 反向索引 */
}
```
(t_stream.c:1871-1894,摘录有删节)

**接管**:`xclaimCommand`(t_stream.c:3541)按 ID 逐个查组 PEL(t_stream.c:3658);先校验消息仍存在,已被 XDEL 的顺手清 PEL(t_stream.c:3662-3674);`min-idle-time` 不满足则跳过(t_stream.c:3696-3699);接管 = 旧消费者 PEL 移除 + `nack->delivery_time/consumer` 更新 + 新消费者 PEL 插入 + `delivery_count++`(RETRYCOUNT 可覆盖)(t_stream.c:3701-3715)。`FORCE` 允许对"不在 PEL 的现存消息"凭空造 NACK(复制场景用,t_stream.c:3682-3687)。

`xautoclaimCommand`(t_stream.c:3763)是批量自动版:直接 `raxSeek(group->pel,">=",startkey)` 顺序扫(t_stream.c:3840-3846),对不满足 idle 的条目只花扫描不交付,`attempts = count*10` 防止空转(t_stream.c:3832,3846);扫到已被 XDEL 的 PEL 条目就地清理并记入返回的第三段 deleted-ids(t_stream.c:3853-3867)。这是 XAUTOCLAIM 相比手工 XCLAIM 的核心增益:**不认识的死信不用客户端自己发现**。

**复制**:PEL 变更以幂等 XCLAIM 形式传播(`XCLAIM ... 0 <id> TIME .. RETRYCOUNT .. FORCE JUSTID LASTID ..`,t_stream.c:1667-1691);NOACK 场景 last_id 推进则用 `XGROUP SETID` 传播(t_stream.c:1705-1719)。

---

## 4. 阻塞读专节:BLOCK 的挂接与唤醒

XREAD/XREADGROUP 共用一个入口 `xreadCommand`(t_stream.c:2301,靠 `sdslen(argv[0])==10` 区分两个命令,t_stream.c:2310)。流程:先同步尝试(t_stream.c:2460-2539)→ 无数据且带 BLOCK 才挂起(t_stream.c:2550-2572)。

- **`>` 的表示法**:解析时把 `>` 写成 `UINT64_MAX-UINT64_MAX` 哨兵(t_stream.c:2442-2454),同步阶段据此判断"非 `>` 即历史读"(serve_history,t_stream.c:2479-2483);
- **组读的就绪条件**:`streamLastValidID(实际流尾) > group->last_id` 才同步交付(t_stream.c:2488-2493);普通 XREAD 则是流尾 > 客户端给的 ID(t_stream.c:2506-2513);
- **消费者自动创建**:`streamLookupConsumer` 不存在则建(t_stream.c:2495-2504);
- **`$` 改写**:阻塞前把 `$` 回写成当前 last_id 的具体值,否则唤醒重跑时会永远拿"最新之后"而死循环(t_stream.c:2558-2569);
- **挂接**:`blockForKeys(c, BLOCKED_STREAM, keys, n, timeout, xreadgroup)`(t_stream.c:2570)。注意最后一个参数:组读在 key 被删除/改型时也要被唤醒(以 -NOGROUP 报错),对应 `blocking_keys_unblock_on_nokey` 计数(src/blocked.c:417-426)。

唤醒链(与卷一 05 事件循环呼应):XADD → `signalKeyAsReady(db,key,OBJ_STREAM)`(t_stream.c:2211)→ `signalKeyAsReadyLogic` 入队 `db->ready_keys`(去重,src/blocked.c:475-511)→ 事件循环 `beforeSleep`(src/server.c:1777)调用 `blockedBeforeSleep`(src/blocked.c:752)→ `handleClientsBlockedOnKeys`(src/blocked.c:334)→ 对每个就绪 key 的阻塞客户端 `unblockClientOnKey`(src/blocked.c:659)→ **重新执行原命令**(CLIENT_PENDING_COMMAND → `processCommandAndResetClient`,src/blocked.c:684-699)。

值得注意:旧版教材里的 `serveClientsBlockedOnStreamKey`(直接替阻塞客户端构造回复)在本版已被删除——List/ZSet/Stream 统一走"唤醒即重跑命令"的 re-execution 模型,Stream 的读取逻辑只有 `xreadCommand` 一份。`processCommand` 结束路径也会就地触发一次唤醒(src/server.c:4424),保证 MULTI 外的即时性。

---

## 5. 修剪专节:MAXLEN/MINID 的精确与近似

修剪统一由 `streamTrim`(t_stream.c:724)实现,`~`(approx)与 `=`(精确)在参数解析期区分(t_stream.c:970-976)。近似模式的本质约束:**只允许删除整个 rax 节点**;一旦要进入节点内部逐条删,立即 `break`(t_stream.c:783-785,注释"we can remove a *whole* node")。

rax 正向遍历从 `raxSeek(&ri,"^")` 开始(t_stream.c:737),对每个节点:

```c
if (trim_strategy == TRIM_STRATEGY_MAXLEN) {
    node_eligible_for_remove = s->length - entries >= maxlen; /* 删完此节点也不低于上限 */
} else { /* MINID: 读节点内最后一条 ID */
    lpGetEdgeStreamID(lp, 0, &master_id, &last_id);
    node_eligible_for_remove = streamCompareID(&last_id, id) < 0;
}
if (remove_node) {
    lpFree(lp);
    raxRemove(s->rax,ri.key,ri.key_len,NULL);   /* 整节点删除 */
    ...
}
```
(t_stream.c:757-781,摘录有删节)

精确模式才进入节点内部:逐条解析 ID 并把 entry 打上 `STREAM_ITEM_FLAG_DELETED` 墓碑标记(t_stream.c:803-864),同时维护节点头的 count/deleted 计数(t_stream.c:876-881)。墓碑不释放内存,节点头注释里的 GC("marked_deleted > entries/2 时压缩")至今是 **TODO**(t_stream.c:888-890)——大量精确 XTRIM/XDEL 会让 listpack 留空洞。

LIMIT 限流:近似模式默认 `limit = 100 * stream_node_max_entries`(≈最多碰 100 个节点),钳制在 [10000, 1000000](t_stream.c:1067-1077);从 AOF/主节点回放时强制不 limit 以保确定性(t_stream.c:1054-1058)。近似修剪在 AOF/复制中回写为精确值(t_stream.c:2192-2193、4145-4152)。8.x 的 DELETE_STRATEGY(KEEPREF/DELREF/ACKED,定义见 t_stream.c:696-699)让修剪能感知 PEL:ACKED 只删被所有组确认的消息,靠 `streamEntryIsReferenced` 判定(t_stream.c:2684-2712,用 min_cgroup_last_id 缓存 + cgroups_ref 反向索引把判定做成近 O(1))。

---

## 6. 设计动机

**为什么 rax + listpack 复合,而不是 ziplist/skiplist/dict?**
- 有序性:消息按 ID 范围读(XRANGE)、阻塞读按"大于 last_id"取,需要有序容器。rax 以 128 位大端 ID 为 key(t_stream.c:484-486),`"^"/"$"/"<="/">="` 四向 seek 覆盖全部访问模式(遍历起点见 t_stream.c:1184-1201)。
- 内存:一条消息若单独成对象,robj+sds 开销远超数据本身。宏节点内 delta 编码 ID(t_stream.c:634-635)+ SAMEFIELDS 省略重复字段名(t_stream.c:607),把 n 条消息压成近乎"一份字段名 + n 份值";每个节点仍是独立 listpack,修剪可整节点 O(1) 释放(t_stream.c:774-781)。
- 前缀压缩:相邻节点 key 高位毫秒相同,rax 的压缩节点路径天然省内存。

**为什么 PEL 由服务端记?** 消费者崩溃不应丢失"投递了但没确认"的状态;XPENDING 才能观测积压;XCLAIM/XAUTOCLAIM 才能把死消费者的欠账移交。若由客户端记偏移(如某些 MQ 客户端方案),重复消费与死信处理都要客户端自建协调层。对比:**LPUSH+BRPOP 是破坏性读取**(弹出即消失,src/t_list.c:1293-1298 的 BLPOP/BRPOP 无任何回放),PubSub 无持久化、离线即丢;Stream 的"持久日志 + 组游标 + 服务端 PEL"是两者都给不了的。

**与 Kafka 消费组对照**(呼应第五系列 Kafka 卷 03):`cg->last_id` ≈ 组提交位移(但 Kafka 提交到 `__consumer_offsets` 内部主题,Redis 直接挂在内存结构 + AOF/RDB 持久化);PEL ≈ Kafka "已消费未提交"窗口,不过 Kafka 消费者本地就有位移管理,Redis 的 NACK 连 delivery_count/delivery_time 都在服务端;XAUTOCLAIM ≈ rebalance 时对孤儿分区的接管,但 Redis 没有自动 rebalance,靠客户端周期性 XAUTOCLAIM;Kafka 有 partition 并行,Redis 单 key 单日志,分片要靠多 key + 客户端路由。

---

## 7. FAQ 素材

1. **XADD 自动 ID 会不会因时钟回拨变小?** 不会。`streamNextID` 在当前毫秒 ≤ last_id.ms 时沿用旧 ms 并 seq+1(t_stream.c:130-139);手动 ID ≤ last_id 直接 EDOM 报错(t_stream.c:451-454)。
2. **rax 里到底存了多少个 key?** 每个 listpack 宏节点一个,节点 key 为节点内首条消息的 128 位大端 ID(t_stream.c:551),不是每条消息一个。
3. **同一节点里字段名重复存储吗?** 不。master entry 存一份字段名,后续消息 SAMEFIELDS 时只存值(t_stream.c:593-608,636-643)。
4. **XREADGROUP 的 `0` 和 `>` 区别?** 非 `>` = 历史读,只回放该消费者自己 PEL 里的消息(`streamReplyWithRangeFromConsumerPEL`,t_stream.c:1808-1811、1937-1972,交付会 delivery_count++);`>` = 取组从未投递的新消息并写 PEL。
5. **NOACK 下 last_id 还推进吗?** 推进(t_stream.c:1817-1837 在 noack 判断之外),只是不写 PEL;且用 XGROUP SETID 而非 XCLAIM 传播(t_stream.c:1914-1917、1705)。
6. **XDEL 会不会把消息从 PEL 拿掉?** 不会。XDEL 只打墓碑标记(t_stream.c:18、1456-1468),PEL 条目残留;XCLAIM/XAUTOCLAIM 会在发现消息不存在时清理 PEL 并回报 deleted(t_stream.c:3662-3674、3853-3867)。8.x 的 XACKDEL 提供显式三策略(t_stream.c:3194)。
7. **删除消费者,它的未确认消息去哪了?** 回到组 PEL 等待接管:DELCONSUMER 遍历消费者 PEL 只删消费者侧引用,组 PEL 的 NACK 保留(t_stream.c:2848-2866)。
8. **XGROUP DESTROY 后阻塞的消费者为什么收到 -NOGROUP?** DESTROY 主动 `signalKeyAsReady`(t_stream.c:3022-3023),配合挂接时的 unblock_on_nokey(src/blocked.c:417-426)让 XREADGROUP 重跑时报 NOGROUP。
9. **`~` 修剪为什么可能少删?** 只删整节点(t_stream.c:783-785)+ LIMIT 限流(默认最多约 100 个节点的工作量,t_stream.c:1067-1077)。
10. **XLEN 是 O(1) 吗?** 是,直接返回 `s->length`(t_stream.c:2285-2291),不数 listpack。

## 8. 深挖方向

1. **cgroups_ref 反向索引与 min_cgroup_last_id 缓存**(7.4+):为 ACKED 修剪策略服务,失效/重建逻辑在 t_stream.c:2594-2606、2684-2712;分析其在多组大流下的内存换时间取舍。
2. **阻塞读 re-execution 模型**:对比旧版 serveClientsBlockedOnStreamKey,新模型让 Stream 与 List/ZSet 共享 blocked.c 骨架;关注 `CLIENT_REEXECUTING_COMMAND` 下超时语义(src/blocked.c:390-393)与公平性(src/blocked.c:578-590 的 count 截断)。
3. **lag 估算体系**:`entries_read` 在无墓碑时精确自增、有墓碑时用 `streamEstimateDistanceFromFirstEverEntry` 重估(t_stream.c:1817-1830),XINFO 输出 lag(t_stream.c:1558-1620)——为什么"XDEL 会让 lag 变估算值"。
4. **修剪的复制确定性**:`~` 参数回写精确值(t_stream.c:2109-2121)与回放时不 limit(t_stream.c:1054-1058)如何共同保证主从一致;对照 Kafka 的 segment 删除不做此类改写的原因。
5. **墓碑 GC 缺位**:t_stream.c:888-890 的 TODO;写基准验证"精确 XTRIM 大流量后 listpack 碎片化"的实际内存代价。

---

## 写作要点速查表

| 函数/结构 | 位置 | 一句话 |
|---|---|---|
| `stream` 结构(含 cgroups_ref) | src/stream.h:16-32 | rax+元数据+组字典+反向索引 |
| `streamCG`/`streamConsumer`/`streamNACK` | src/stream.h:58/79/95 | NACK 为组 PEL 与消费者 PEL 共享值 |
| `streamNew`(cgroups 懒创建) | src/t_stream.c:51-68 | 组字典按需 raxNew |
| `streamNextID`(自动 ID) | src/t_stream.c:130-139 | 时钟回拨→seq 自增 |
| `streamAppendItem`(XADD 本体) | src/t_stream.c:420 | ID 校验 451;节点分裂 525-546;master entry 549-574;SAMEFIELDS 593-608;entry 编码 633-652 |
| `streamTrim`(修剪统一入口) | src/t_stream.c:724 | 整节点删 757-781;approx break 785;墓碑 843-864;GC TODO 888-890 |
| 近似修剪 LIMIT 默认值 | src/t_stream.c:1067-1077 | 100*node_max_entries,钳 [1e4,1e6] |
| `streamIteratorStart/GetID` | src/t_stream.c:1166/1212 | raxSeek "<=" 定位;delta 解码 1285-1288 |
| `streamReplyWithRange`(PEL 写入) | src/t_stream.c:1792,1864-1897 | last_id 推进 1817-1837;XCLAIM 传播 1902-1907 |
| 历史读(消费自己的 PEL) | src/t_stream.c:1937-1972 | 遍历 consumer->pel 再定点取消息 |
| `xaddCommand`(修剪回写/唤醒) | src/t_stream.c:2124,2182-2195,2211 | signalKeyAsReady 唤醒阻塞读 |
| `xreadCommand`(XREAD+XREADGROUP) | src/t_stream.c:2301 | `>` 哨兵 2442-2454;同步就绪判断 2488-2493;`$` 改写 2562-2569;blockForKeys 2570 |
| `streamCreateCG`/`streamCreateConsumer` | src/t_stream.c:2764/2819 | 重名返回 NULL;消费者见人即建 |
| `xgroupCommand`(CREATE/SETID/DESTROY) | src/t_stream.c:2877,2962-3026 | `$`=last_id;DESTROY 唤醒 3022-3023 |
| `xackCommand` | src/t_stream.c:3132,3159-3176 | 组 PEL 命中→双 PEL 删同一 NACK |
| `xclaimCommand` | src/t_stream.c:3541,3651-3736 | minidle 检查 3696;接管 3701-3720 |
| `xautoclaimCommand` | src/t_stream.c:3763,3838-3895 | 扫组 PEL 3846;死信清理 3853-3867 |
| `blockForKeys`/`handleClientsBlockedOnKeys`/`unblockClientOnKey` | src/blocked.c:387/334/659 | 唤醒=重跑命令 684-699 |
| `blockedBeforeSleep`(事件循环挂点) | src/blocked.c:752,767;src/server.c:1821,4424 | beforeSleep + processCommand 双入口 |
| 幂等 XCLAIM 传播 | src/t_stream.c:1667-1691 | 复制 PEL 变更的标准形式 |
