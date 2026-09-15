# J - 活动碎片整理(Active Defrag)

> 仓库:redis unstable @ e8726d18e5bab24cbfcb0a0c36f21ce5a1140471(2025-09-15 快照,Redis 8.x 世代)
> 涉及文件:`src/defrag.c` `src/dict.c` `src/kvstore.c` `src/ebuckets.c` `src/zmalloc.c` `src/server.c` `src/config.c` `src/module.c` `deps/jemalloc/`(Redis 定制版)
> 姊妹篇:卷一 08 章《G - 内存管理、过期与淘汰》讲过 zmalloc/lazyfree/expire/ebuckets/evict,本篇补上它留白的 defrag 一角。

---

## ① 全景:碎片从哪来,defrag 怎么救

Redis 是"分配密集型"程序:一个 zset 元素至少 3 块小内存(dictEntry、sds、skiplistNode)。频繁的 DEL/SETRANGE/HSET 更新会让 jemalloc 的 slab(bin 复用页)内部千疮百孔——**逻辑上 used_memory 不高,RSS 却居高不下**,这就是外部碎片(external fragmentation)。jemalloc 按 size class 分 bin,只有整个 slab 空了才能归还 OS,空洞永远填不平。

active defrag 的思路是"搬家"而不是"压缩":把住在**低利用率 slab** 里的对象重新分配一次——分配器会优先挑更满的 slab 或现成空洞——旧块释放后,原来那块千疮百孔的 slab 引用计数归零,整块归还 OS。

```
 搬家前(jemalloc slab 视角)              搬家后
 ┌─────────────────────┐                ┌─────────────────────┐
 │ slaba ■■□■□■■□ (62%)│  ← 判定为      │ slaba □□□□□□□□ 空了  │ → madvise 还给 OS
 │ slabB ■■■■■■■■ (100%)│   "值得搬"    │ slabB ■■■■■■■■       │
 │ slabC ■■■□■■■□ (81%)│ ────对象→      │ slabC ■■■□■■■■■ (94%)│ ← 新分配落在这里
 └─────────────────────┘                └─────────────────────┘
        used_memory 不变;RSS 下降一整个 slab
```

每一次"搬家"(relocate)= 三步,**src/defrag.c:151-182**:

```c
void* activeDefragAllocWithoutFree(void *ptr) {
    size_t size;
    void *newptr;
    if(!je_get_defrag_hint(ptr)) {          // 问 jemalloc:这块值得搬吗?
        server.stat_active_defrag_misses++;
        return NULL;
    }
    /* make sure not to use the thread cache. so that we don't get back the same
     * pointers we try to free */
    size = zmalloc_usable_size(ptr);
    newptr = zmalloc_no_tcache(size);       // 1) 新块绕过 tcache 分配
    memcpy(newptr, ptr, size);              // 2) 逐字节拷贝
    server.stat_active_defrag_hits++;
    return newptr;
}
void activeDefragFree(void *ptr) {
    zfree_no_tcache(ptr);                   // 3) 旧块也绕过 tcache 释放
}
```

要点:分配与释放都走 `MALLOCX_TCACHE_NONE`(src/zmalloc.c:243-256),否则刚释放的旧块会立刻从 tcache 里"发还"给自己,搬家等于没搬;`je_get_defrag_hint` 是 Redis 定制 jemalloc 才有的接口(src/defrag.c:142-144 声明;deps/jemalloc/src/jemalloc.c:4509-4513 导出)。

---

## ② 主循环专节:Stage 框架、游标推进与逐对象 relocate

### 2.1 Stage 框架:一次 defrag 周期扫什么

defrag 被拆成一串可中断的 stage(`defragStageFn`,src/defrag.c:48-56),由独立时间事件 `activeDefragTimeProc` 作为"泵"逐个驱动(src/defrag.c:1632-1690)。`beginDefragCycle` 注册全部 stage(src/defrag.c:1714-1786):

- 每个 db 三个 stage:**keys**(defragStageDbKeys,src/defrag.c:1296)、**expires**(defragStageExpiresKvstore,src/defrag.c:1316)、**subexpires**(hash 字段级过期的 db 级 estore,src/defrag.c:1364-1411;字段见 src/server.h:1115)(注册于 src/defrag.c:1723-1745);
- pubsub 与 pubsubshard 频道 kvstore(src/defrag.c:1747-1757);
- Lua 脚本字典(src/defrag.c:1424-1429,注册 1759)、各 module 全局数据(src/defrag.c:1433-1457,注册 1761-1773)。

### 2.2 游标推进:db → slot → bucket → 键

kvstore 扫描由 `defragStageKvstoreHelper` 统一驱动(src/defrag.c:1245-1294),三级游标全部持久化在 ctx 里(`kvstoreIterState`,src/defrag.c:85-89),断点续扫零遗漏:

1. **LUT 阶段**:先把 kvstore 的字典查找表(dict* 数组)本身整理掉,`kvstoreDictLUTDefrag` 每次只处理一个 dict 并返回 +1 游标(src/defrag.c:1256-1263;实现 src/kvstore.c:760-777,顺带更新 rehashing 链表里的指针 768-772);
2. **slot 阶段**:cursor 归零时跳到下一个非空 dict(非 cluster 时也有 1 个 slot)(src/defrag.c:1277-1286);
3. **bucket 阶段**:`kvstoreDictScanDefrag` 复用 dictScan 的**反向二进制递增游标**(rehash 安全),每次只碰一个 bucket(src/defrag.c:1289-1290;src/kvstore.c:742-748;src/dict.c:1566-1626,进入前 `dictPauseRehashing` 1578)。

限流检查嵌在循环里:每 16 次迭代、或新增 512 次 relocate、或新扫 64 个对象,才看一次时钟(src/defrag.c:1266-1271)——`getMonotonicUs()` 本身有开销,不能每对象查一次。

### 2.3 defragKey:单键 relocate 分派

`dbKeysScanCallback → defragKey`(src/defrag.c:1036-1044、949-1033)是主战场:

```c
long long expire = kvobjGetExpire(ob);
/* We can't search in db->expires for that KV after we've released
 * the pointer it holds ... Search it before, if needed. */
 if (expire != -1) {
     exlink = kvstoreDictFindLink(db->expires, slot, kvobjGetKey(ob), NULL);   // 先找好 expires 位置
     serverAssert(exlink != NULL);
 }
 if (!(ob->type == OBJ_HASH && hashTypeGetMinExpire(ob, 0) != EB_EXPIRE_TIME_INVALID)) {
     kvnew = activeDefragStringOb(ob);          // 搬 robj(+EMBSTR 内嵌 sds)
 }
 if (kvnew) {
     kvstoreDictSetAtLink(db->keys, slot, kvnew, &link, 0);      // 改写 keys 表引用
     if (expire != -1)
         kvstoreDictSetAtLink(db->expires, slot, kvnew, &exlink, 0);  // 同步改写 expires 表
     ob = kvnew;
 }
```

(src/defrag.c:957-977,摘录有删节)。之后按 type/encoding 分派到 defragQuicklist / defragSet / defragZsetSkiplist / defragHash / defragStream / defragModule(src/defrag.c:979-1032)。注意带 HFE 的 hash 被跳过(968 行条件),留到 subexpires stage 再搬,因为它还要同步改 ebuckets 里的引用。

### 2.4 defragLater:大 value 延后,防延迟毛刺

元素数超过 `active-defrag-max-scan-fields`(默认 1000,src/config.c:3232)的大对象不就地整理,只把**键名**塞进 `defrag_later` 链表(src/defrag.c:563-571;判定点 705、725、744、757、924)。每轮 kvstore 扫描开始前,`defragLaterStep` 先按键名重新 find,用 `scanLaterList/Zset/Set/Hash/StreamListpacks` 增量消化(src/defrag.c:1158-1196、1128-1151)。游标各显神通:

- list 用 quicklist 自带的 bookmark "_AD" 记住上次停在哪,bookmark 被删说明扫完了(src/defrag.c:581-613);
- stream/ebuckets 在退出前多 `raxNext` 一步,把下一个 key 存进 static 缓冲,下轮 `raxSeek(">=", next)` 续位(src/defrag.c:795-806;src/ebuckets.c:1941-1955)。

### 2.5 引用更新:容器内指针如何改写

relocate 拷贝后地址变了,**所有指向旧块的引用必须改写**,这是 defrag 真正的难点,按容器分四类:

1. **dict 桶内链**:dictDefragBucket 先 defragKey/defragVal,再把新 entry 直接写回桶头链 `*bucketref = newde`,沿着 next 链逐个走(src/dict.c:1373-1402)。key/val 的改写由调用方在 `dictDefragFunctions` 里注入(src/defrag.c:489-497)。
2. **多表共享引用**:db->keys 与 db->expires 指向同一 kvobj,见上文 `kvstoreDictSetAtLink` 双写(src/defrag.c:973-975;src/kvstore.c:839);zset 的 sds 元素被 dict 和 skiplist 同时引用——`activeDefragZsetEntry` 先搬 sds 并 `dictSetKey`,再由 `zslDefrag` 按 score+指针定位 skiplist 节点(查找时用 `forward->ele != oldele` 的**指针比较**避免触碰已释放内存,src/defrag.c:409-416),`zslUpdateNode` 修好各层 forward、backward、tail(src/defrag.c:377-391),dict 的 score 指针也可能换成新节点里的 `&newx->score`(src/defrag.c:427-446)。
3. **ebuckets(HFE)内引用**:无 TTL 的 hfield 在 dict 扫描时直接搬(src/defrag.c:472-484);带 TTL 的字段由 `activeDefragHfieldAndUpdateRef` 处理——释放前先 `dictFindLink` 拿到链位,搬完 `dictSetKeyAtLink` 写回(src/defrag.c:263-278),ebuckets 链表/段内的 prev/next 指针由 ebDefragList/ebDefragRaxBucket 修补(src/ebuckets.c:1825-1841、1844-1914)。
4. **跨对象引用**:pubsub channel 名 refcount=dictSize(clients)+1,搬完后还要遍历每个 client 的频道字典 `dictSetKey` 同步(src/defrag.c:1089-1117);stream 的 NACK 记录 consumer/cgroup 双向指针,`defragStreamConsumerPendingEntry` 里先改 `nack->consumer`、`cgroup_ref_node->value`,再 `raxInsert` 用新指针顶替旧值(src/defrag.c:872-885)。

robj 层面还有一道保险:`activeDefragStringObEx` 只搬 refcount 等于期望值(通常 1)的对象,共享对象直接放弃(src/defrag.c:287-297)。

---

## ③ 判据专节:jemalloc 碎片率估算

两个问题:整体"要不要整理"(宏观碎片率)与单个指针"值不值得搬"(微观 hint)。

### 3.1 宏观:mallctl 统计

`getAllocatorFragmentation`(src/defrag.c:1053-1079)调用 `zmalloc_get_allocator_info`(src/zmalloc.c:799-845):先 `mallctl("epoch")` 强制刷新缓存统计(807-810),再取 `stats.resident / stats.active / stats.allocated`(815-821);"碎片字节"来自 `zmalloc_get_frag_smallbins`(843)——逐 bin 用 `mallctlbymib` 查 `curslabs/curregs/nregs`,碎片 = `(nregs*curslabs - curregs) * reg_size`(src/zmalloc.c:737-786,核心 782)。最终(src/defrag.c:1070):

```c
float frag_pct = (float)frag_smallbins_bytes / allocated * 100;
```

只统计 **small bins**(可 defrag 的部分)却除以全部 allocated——注释解释:若内存大头是 large bin,再按 resident 算会虚高(src/defrag.c:1066-1069)。Lua 自己独占一个 arena,数字先扣掉(src/defrag.c:1057-1064)。文件头注释很直白:误判会让 defrag 空转烧 CPU(src/defrag.c:1047-1052)。

### 3.2 微观:je_get_defrag_hint

每次 relocate 前问分配器。Redis 定制 jemalloc 的实现(deps/jemalloc/include/jemalloc/internal/jemalloc_internal_inlines_c.h:343-391):通过 emap 找到指针所在 slab,**slabcur(正在服役的新分配页)不搬**(358);其余 slab 若有空位,统计该 bin 所有 shard 的非满 slab 数与空闲 reg 数,判定式(384):

```c
defrag = (bin_info->nregs - free_in_slab) * curslabs <= curregs + curregs / 8;
```

即"本 slab 利用率低于全体非满 slab 均值(外推比较,避免除法)"才搬,再给 12.5% 权重防止全体同利用率时原地停滞(注释 378-383)。

---

## ④ 节奏专节:CPU 上限与渐进

### 4.1 触发链与阈值

```
serverCron(100ms 级) → databasesCron(src/server.c:1544、1200) → activeDefragCycle(src/server.c:1212)
```

`computeDefragCycles`(src/defrag.c:1202-1240):未运行且 `frag_pct < threshold_lower(默认10)` 或碎片字节 < `ignore-bytes(默认100MB)` 直接退出(src/defrag.c:1207,默认值 src/config.c:3192、3257);否则用 INTERPOLATE 把碎片率线性映射到 CPU 百分比(src/defrag.c:1213-1217,宏 1198):10% 碎片 → cycle-min(默认 1%),100% 碎片 → cycle-max(默认 25%)(src/config.c:3190-3193)。总开关 `activedefrag` **默认关闭**(src/config.c:3112),非 jemalloc 编译时 CONFIG SET 直接报错(src/config.c:2341-2349)。

### 4.2 百分比如何变成"跑一阵歇一阵"

defrag 不再依赖 serverCron 的 5% 精度,而是注册独立时间事件,自算占空比(src/defrag.c:1548-1602):

```c
/*     D          P          D = duty time, W = wait time
 *  -----   =  -----
 *  D + W       100         D = P * W / (100 - P)                        */
dutyCycleUs = targetCpuPercent * waitedUs / (100 - targetCpuPercent);
```

- 标准 duty 周期 500 微秒(src/defrag.c:27),单次最长放大到 10 倍(5ms)防延迟毛刺(src/defrag.c:1594-1599);
- 实际跑超了(overage)记账进下次等待,跑少了按比例加到 delay 上(src/defrag.c:1586-1592、1609-1624);
- timer 之间频繁短跑,"Frequent short calls provides low latency impact"(src/defrag.c:1630-1631),并采样延迟监控 `active-defrag-cycle`(1681-1682);
- 有 bgsave/AOF 子进程时整体暂停轮询(src/defrag.c:1646-1650、1793),AOF 载入等阻塞期靠 `defragWhileBlocked` 手动泵一步(src/defrag.c:1695-1712;调用点 src/server.c:1735)。

### 4.3 自适应降速

一轮周期结束后按效果调 `decay_rate`:碎片率变化超过 2 个百分点、或命中率不低于 1% 时保持全速,否则 ×0.9 逐轮减速(src/defrag.c:1490-1507),下一轮 `cpu_pct *= decay_rate`(src/defrag.c:1218)。改配置时置 `active_defrag_configuration_changed` 立即生效(src/config.c:2484-2488;src/defrag.c:1226-1229)。INFO stats 里的 `active_defrag_hits/misses/key_hits/key_misses/total_active_defrag_time` 全部来自这套统计(src/server.c:6213-6218)。

---

## ⑤ 与卷一 08 章对照:淘汰是"减法",defrag 是"整理"

| | 淘汰 evict(08 章) | 碎片整理 defrag(本篇) |
|---|---|---|
| 目标 | used_memory 压回 maxmemory 以内 | 不动 used_memory,压 RSS |
| 手段 | 丢数据(近似 LRU/LFU 采样) | 搬数据(重新分配+改引用) |
| 触发 | 写命令前同步检查(src/server.c:4254 附近) | databasesCron 异步渐进(src/server.c:1212) |
| 数据损失 | 有 | 无 |
| 依赖 | 自研采样池 | jemalloc 定制版 |

两者正交:内存紧张靠淘汰,内存"虚胖"靠 defrag,可以同时开。defrag 与 08 章的 ebuckets 也正面呼应——**defrag 会遍历两层 ebuckets**:db 级 `subexpires` estore 逐桶扫带 HFE 的 hash 对象(src/defrag.c:1364-1411),hash 内部 HFE ebuckets 逐字段搬带 TTL 的 hfield(src/defrag.c:684-697、519-530);`ebScanDefrag` 按 list/rax 两种桶形态分别修补链指针(src/ebuckets.c:1986-2001、1825-1841、1918-1974)。主动过期(`activeExpireCycle`,08 章路径三)与 `activeDefragCycle` 同在 databasesCron 里排队(src/server.c:1203-1212)。

与 lazyfree 的关系:思想同源(都用"代价估计"决定轻重处理,module 还直接复用 `moduleGetFreeEffort`,src/module.c:14502),但 defrag **不走** BIO 后台释放——旧块是小块,同步 `zfree_no_tcache` 即可(src/defrag.c:168-170);真正的交集是子进程:fork 期间(RDB/AOF)defrag 暂停,理由与 08 章 CoW 分析一致——搬家会额外弄脏父进程页,放大 fork 代价(src/defrag.c:1646-1650、1793)。

---

## ⑥ 设计动机

1. **为什么不用重启解决?** Redis 的定位是常驻在线服务;重启意味着缓存全冷、连接重建、副本切换。碎片又是渐进型问题(长尾增长),等它疼了再重启属于"手术成功病人没了"。defrag 用 1%-25% 的 CPU 税把 RSS 平滑压回去,全程在线。
2. **为什么要耦合 jemalloc?** 判定"这块内存搬了值不值"只有分配器自己知道(slab 利用率是 jemalloc 内部状态)。Redis 选择 fork 一份修改版 jemalloc,导出 `je_get_defrag_hint`(jemalloc_macros.h.in:151 明说 "This version of Jemalloc, modified for Redis"),换来每个指针 O(1) 的搬家决策。代价:依赖 libc malloc/tcmalloc 的平台直接没有这个功能(src/config.c:2342-2348),`activedefrag` 开关也默认关闭——这是一笔"拿可移植性换在线整理能力"的明确取舍。
3. **为什么改引用而不是改指针表?** C 里没有对象图,Redis 手工维护了每个容器的引用点(dict 桶链、skiplist 层链、rax node、ebuckets 段链),defrag 的每一个 `activeDefragXxx` 函数本质上是一张"该容器引用点清单"的执行器。这也是为什么每个新容器(8.x 的 kvobj、HFE、listpackEx)都要补对应的 defrag 代码(src/defrag.c:984-1025)。

---

## ⑦ FAQ 素材

1. **开了 activedefrag 为什么 RSS 不降?** 先看 INFO `mem_fragmentation_ratio` 的构成:frag_pct 只统计 small bins(src/defrag.c:1066-1070),若 RSS 大头在 large allocation 或 libc allocator(非 jemalloc 编译根本无 defrag),开了也白开。
2. **defrag 会丢数据吗?** 不会。每次搬家是 memcpy + 引用改写,不释放对象本身;失败的 relocate(hint 不通过)原样保留(src/defrag.c:154-157)。它和淘汰最大的区别就在这里。
3. **`active_defrag_cycle_min/max` 到底控制什么?** 不是"单次跑多久",而是占空比目标:碎片率在 lower/upper 阈值之间线性插值出 CPU 百分比(src/defrag.c:1213-1217),时间事件按 D=P·W/(100-P) 自算 duty/delay(src/defrag.c:1583)。
4. **为什么每个对象要 `hits/misses` 两个统计?** hint 不通过记 miss(问了 jemalloc 但不值得搬),通过记 hit(真搬了);key 级另有 key_hits/key_misses(src/defrag.c:1036-1044)。命中率还会反过来给下轮降速(src/defrag.c:1490-1507)。
5. **defrag 运行时能正常读写吗?** 能。扫描用与 SCAN 相同的反向二进制游标 + `dictPauseRehashing`,bucket 处理是原子的;大 value 走 defragLater 延后,单次 duty 上限 5ms(src/defrag.c:1594-1599)。
6. **expires 表为什么也要整理?** 它是独立 kvstore,和 keys 表一样占 dict 结构+表数组内存;所以有专门的 stage(src/defrag.c:1316-1331),且 keys 表搬 kvobj 时要同步双写(src/defrag.c:973-975)。
7. **Cluster 模式下 16384 个 slot 怎么扫?** kvstore 每 slot 一个 dict,helper 沿 `kvstoreGetFirst/NextNonEmptyDictIndex` 只跳非空 slot(src/defrag.c:1279-1285),LUT 整理也按游标逐 dict 推进(src/kvstore.c:760-777)。
8. **bgsave 时 defrag 停不停?** 停。`hasActiveChildProcess` 时 timer 只轮询 100ms(src/defrag.c:1646-1650),新周期也拒绝启动(1793),避免加剧 CoW。
9. **scanLaterList 里的 "_AD" 是什么?** quicklist bookmark,defrag 专用的"书签":每处理 128 个节点看一次时钟,超时就把当前位置存成书签退出(src/defrag.c:598-605),下轮从书签继续。
10. **怎么观测 defrag 效果?** INFO stats 的 `active_defrag_hits` 等 5 个指标(src/server.c:6213-6218)+ 日志一行总结(src/defrag.c:1531-1533);latency 监控采样 `active-defrag-cycle`(1682)。

## ⑧ 深挖

1. **`iget_defrag_hint` 的 12.5% 松弛**:判定式 `usage*curslabs <= curregs + curregs/8`(deps/jemalloc/.../jemalloc_internal_inlines_c.h:384)本质是把"本 slab 利用率 ≤ 全体非满 slab 平均利用率"变成纯整数外推比较;+curregs/8 防止所有 slab 同利用率时互相不搬导致系统饱和停摆——一个分布式思想在单进程分配器里的微缩版。
2. **两套防跳过的 static 缓冲技巧**:stream(listpacks)与 ebuckets(rax)都遇到同一个问题——`raxSeek` 遍历路径上的 node 不会触发 node_cb,下次 `>= next` 续扫会漏掉这些节点;解法都是"退出前多走一步,把下一个 key 存进函数级 static 数组"(src/defrag.c:780、795-806;src/ebuckets.c:1923、1941-1955)。static 在单线程 Redis 里是安全的,但这层隐含契约值得写测试盯住。
3. **zslDefrag 的"指针比较"查找**:找 skiplist 节点时先用 `forward->ele != oldele`(指针相等)短路,防止对已释放的旧 sds 做 sdscmp(src/defrag.c:409-416)——释放后使用(use-after-free)在此处是**设计内**的,靠比较顺序规避,是理解 defrag 代码危险性的最佳样本。
4. **decay_rate 的经济学**:CPU 是固定成本,hit/miss 比是边际收益;`decay_rate *= 0.9` 每轮复利衰减(下限 cycle-min 兜底,src/defrag.c:1219-1221),等价于给 defrag 加了个负反馈环路,防止"碎片率卡在 11%"时永远用 max 档空转。
5. **kvobj(8.x)对 defrag 的重塑**:旧版主 entry 是 robj,8.x 换成 kvobj 后 defragKey 要同时维护 keys/expires/subexpires 三处引用(src/defrag.c:949-977、1334-1362);带 HFE 的 hash 甚至不能在 keys 扫描期搬(968 行条件),必须等 subexpires stage——对象模型每复杂一层,defrag 的引用改写矩阵就多一行。

---

## 写作要点速查表

| 主题 | 函数 | 位置 |
|---|---|---|
| relocate 三步(hint+新块+拷贝+释放) | activeDefragAllocWithoutFree / activeDefragAlloc | src/defrag.c:151-182 |
| 绕过 tcache 的分配/释放 | zmalloc_no_tcache / zfree_no_tcache | src/zmalloc.c:243-256 |
| kvobj 双表引用改写(keys+expires) | defragKey | src/defrag.c:949-1033(关键 957-977) |
| 大对象延后清单 | defragLater / defragLaterStep / defragLaterItem | src/defrag.c:563-571 / 1158-1196 / 1128-1151 |
| list 游标续位 | scanLaterList(bookmark "_AD") | src/defrag.c:574-614 |
| dict 桶链改写 | dictDefragBucket / dictScanDefrag | src/dict.c:1373-1402 / 1566-1626 |
| skiplist 引用改写 | zslDefrag / zslUpdateNode | src/defrag.c:400-433 / 377-391 |
| HFE 字段搬运+改引用 | activeDefragHfieldAndUpdateRef | src/defrag.c:263-278 |
| hash 两阶段(dict→ebuckets) | scanLaterHash / activeDefragHfieldDict | src/defrag.c:655-698 / 507-531 |
| db 级 subexpires stage | defragStageSubexpires | src/defrag.c:1364-1411 |
| ebuckets 扫描(list/rax) | ebScanDefrag / ebDefragList / ebDefragRax | src/ebuckets.c:1986-2001 / 1825-1841 / 1918-1974 |
| 宏观碎片率(frag_pct 公式) | getAllocatorFragmentation | src/defrag.c:1053-1079(公式 1070) |
| 逐 bin 碎片字节(mallctlbymib) | zmalloc_get_frag_smallbins_by_arena | src/zmalloc.c:737-786(核心 782) |
| 微观搬家判据 | iget_defrag_hint(判定式) | jemalloc_internal_inlines_c.h:343-391(式 384) |
| 触发与 CPU 插值 | computeDefragCycles(INTERPOLATE) | src/defrag.c:1202-1240(1213-1217);server.c:1212 |
| 占空比计算 | computeDefragCycleUs(D=P·W/(100-P)) | src/defrag.c:1548-1602(式 1583) |
| timer 主泵/子进程暂停 | activeDefragTimeProc | src/defrag.c:1632-1690(1646-1650) |
| stage 注册(key/expiry/pubsub/module) | beginDefragCycle | src/defrag.c:1714-1786 |
| 配置默认值(min1/max25/lower10/upper100/100MB/1000) | createIntConfig 等 | src/config.c:3190-3193、3232、3257、3112 |
