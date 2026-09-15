# 第 09 章 · Stream 与消费者组:Redis 的持久日志(扩展卷开篇)

> 基线:Redis clone commit `e8726d1`(2025 版,含 7.4+ 的 cgroups_ref/XACKDEL)。行号以 src/t_stream.c、src/blocked.c 为准。卷一(01-08)未覆盖 Stream——本章补齐 Redis 的"持久日志"。

## 9.0 全景:rax 树 + listpack 复合体

```
一个 Stream = rax 树(键=节点内首条消息 ID 的 128 位大端编码)
  → value 是 listpack(一个宏节点打包多条消息)
消费组挂 s->cgroups(rax:组名→streamCG,懒创建)
  组 PEL 与消费者 PEL 的 value 是同一个 streamNACK 对象(stream.h:95-101)
7.4+ 新增 cgroups_ref 反向索引(消息 ID→组链表,stream.h:26)支撑 ACKED 修剪
```

**节点内首部存 master entry**(count/deleted/字段名列表/0 终止符,t_stream.c:500-520),后续消息只存**与 master 的 ms/seq 差值+SAMEFIELDS 时省略字段名**(:633-652)——同字段消息的极致压缩。

## 9.1 XADD:ID 生成与节点分裂

streamAppendItem(:420):**ID 必须>last_id 否则 EDOM**(:451);自动 ID 生成 streamNextID(:130-139):**时钟回拨时沿用旧 ms、seq+1** 保证单调;节点分裂判定 stream_node_max_bytes/entries(:525-546);XADD 尾部三件事(:2182-2211):`~` 修剪参数回写精确值保复制确定性(:2186-2194)、自动 ID 回写 argv(:2201-2207)、signalKeyAsReady 唤醒阻塞读(:2211)。streamTrim 统一修剪(:724):**`~` 近似模式只删整个 rax 节点**,要进节点内部就 break(:783-785);墓碑 GC 至今是 TODO(:888-890);近似 LIMIT 默认钳 [10000,1000000](:1067-1077)。

## 9.2 消费者组与 PEL:last_id 与"已确认"双水位

**last_id 是"已投递"水位,在读取时推进**(streamReplyWithRange,:1817-1837);PEL 是"已确认"水位,交付即写(:1864-1897:raxTryInsert 组 PEL+消费者 PEL);若已被别的消费者持有,**就地夺走重置 delivery_count=1**。XACK=组 PEL 命中后删双 PEL 的共享 NACK(:3159-3176);XCLAIM 接管=minidle 校验(:3696)→旧消费者 PEL 移除→nack->consumer 改指针→新 PEL 插入+delivery_count++(:3701-3715);XAUTOCLAIM 顺序扫组 PEL(:3846),自动清理已 XDEL 死信(:3853-3867)。PEL 变更以**幂等 XCLAIM 传播到 AOF/从库**(:1667-1691);NOACK 的 last_id 推进用 XGROUP SETID 传播(:1705-1719)。

## 9.3 阻塞读与组语义

xreadCommand 同时实现 XREAD/XREADGROUP(:2301):`>` 编码为 UINT64_MAX 哨兵(:2442-2454);非 `>` 即历史读只回放消费者自己 PEL(:2479-2483);组读就绪条件=流实际尾>group->last_id(:2488-2493);阻塞前把 `$` 改写成具体 ID 防死循环(:2562-2569)。阻塞挂接 blockForKeys(:2570+blocked.c:387);**本版已无 serveClientsBlockedOnStreamKey**——唤醒统一为"重跑原命令"(unblockClientOnKey→processCommandAndResetClient,blocked.c:659,:684-699),触发点 beforeSleep(:767←server.c:1821)。XGROUP CREATE 的 `$`=当前 last_id(:2962-2996);DESTROY 主动 signalKeyAsReady 让阻塞消费者收到 -NOGROUP(:3022-3023)。ACKED 修剪判定核心:streamEntryIsReferenced+min_cgroup_last_id 缓存(:2684-2712)——"ID<全组最小 last_id 或在 cgroups_ref 中"即被引用。

## 9.4 与 Kafka 对照及设计动机

LPUSH+BRPOP 是破坏性读取(t_list.c:1293/:1298)、PubSub 离线即丢;Stream 的"持久日志+组游标+服务端 PEL"补齐两者都给不了的确认/回放/接管语义。与 Kafka 组位移对照(第五系列 Kafka 卷 03):**PEL≈Kafka 的位移提交,但 PEL 在服务端、位移在客户端提交**——服务端 PEL 使 XCLAIM 的接管成为服务端操作。设计动机:①rax+listpack 复合=大流的索引与小节点的紧凑折中;②master entry 差值编码=同构消息的列式压缩;③`~` 近似修剪=O(节点) 代替 O(消息)。

## 9.5 FAQ

**Q1:Stream ID 为什么必须递增?**
(:451):PEL/last_id/修剪全部依赖 ID 单调——乱序会破坏全部水位语义。

**Q2:消费者挂了它的 PEL 去哪?**
留在组 PEL:其他消费者可 XCLAIM/XAUTOCLAIM 接管(:3701-3715)。

**Q3:XREADGROUP 的 `>` 是什么?**
UINT64_MAX 哨兵(:2442-2454):语义="只要新消息,不回放 PEL"。

**Q4:MAXLEN 修剪精确吗?**
`~` 只删整个 rax 节点(:783-785):近似但 O(节点);精确模式进节点内部。

**Q5:删除的消息在 PEL 里怎么办?**
XAUTOCLAIM 自动清理死信(:3853-3867);cgroups_ref 反向索引支撑 O(1) 判定(stream.h:26)。

**Q6:阻塞的 XREADGROUP 怎么唤醒?**
XADD 尾部 signalKeyAsReady(:2211)→重跑原命令(blocked.c:684-699)。

**Q7:Stream 键被删,阻塞消费者会怎样?**
被唤醒收到 -NOGROUP(:417-426 键删除唤醒)。

**Q8:XGROUP DESTROY 会删消息吗?**
不会(:3022-3023):只删组与 PEL,消息保留。

**Q9:为什么 PEL 变更用 XCLAIM 传播?**
(:1667-1691):幂等——从库重放多次结果一致。

**Q10:时钟回拨会怎样?**
streamNextID 沿用旧 ms、seq+1(:130-139):单调性优先于真实时间。

## 9.6 小结与深挖方向

本章结论:**Stream="rax+listpack 复合+双水位(投递/确认)+服务端 PEL"**。深挖:

1. master entry 差值编码在字段全异消息的退化;
2. cgroups_ref(:26)反向索引的内存代价;
3. XAUTOCLAIM 顺序扫(:3846)在大 PEL 的游标分页;
4. 近似修剪 LIMIT 钳位(:1067-1077)的动态策略;
5. 与 Kafka 组位移(第五系列)的语义矩阵完整化。

> 下一章:Module 模块系统——Redis 的内核可编程扩展层。
