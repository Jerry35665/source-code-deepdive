# G - 内存管理、过期与淘汰

> 仓库:redis unstable @ e8726d18(2025-09-15,Redis 8.x 世代)
> 涉及文件:`src/zmalloc.c` `src/zmalloc.h` `src/object.c` `src/lazyfree.c` `src/expire.c` `src/ebuckets.c` `src/ebuckets.h` `src/estore.h` `src/db.c` `src/evict.c` `src/t_hash.c` `src/server.h`

---

## ① 内存管理全景

Redis 的内存子系统是一条自下而上的分层栈,每一层都对上层隐藏一类复杂度:

1. **分配层(zmalloc)**:把 jemalloc/tcmalloc/libc 统一成 `zmalloc` 家族 API,并在分配/释放时同步维护"逻辑内存用量"计数器 `used_memory`,这是 `maxmemory` 判断的基石(src/zmalloc.c:503-516)。
2. **对象层(object.c)**:`robj` 引用计数 + 三个特殊 refcount(共享/栈上/普通);8.x 引入的 `kvobj` 把 key、expire、value(EMBSTR 时)揉进一次分配,是本世代最大的对象内存结构变化(src/object.c:143-198)。
3. **释放层(lazyfree.c)**:按"释放代价"(free effort)决定同步 `decrRefCount` 还是丢给 BIO 后台线程,阈值 64 次分配(src/lazyfree.c:181)。
4. **过期层(expire.c + ebuckets.c)**:三条路径——访问时惰性删除、serverCron 定期采样、以及 8.x 为 hash 字段级过期(HFE)新造的 ebuckets 分桶主动过期。
5. **淘汰层(evict.c)**:`maxmemory` 8 种策略,近似 LRU/LFU 用 16 槽候选池 + 采样实现,常量内存 O(EVPOOL_SIZE)。
6. **辅助机制**:active defrag(依赖 jemalloc 的 frag hint,src/zmalloc.h:79-81)、fork 期间 `MADV_DONTNEED` 降 CoW 的 dismiss 机制(src/server.c:6951-6960、src/zmalloc.c:525-545)。

三条"内存回收"主线的触发点也各不相同:过期在 `serverCron → databasesCron`(慢周期,src/server.c:1205)与 `beforeSleep`(快周期,src/server.c:1831)运行;淘汰在每条写命令前 `processCommand → performEvictions`(src/server.c:4254),放不下时由时间事件 `evictionTimeProc` 续跑(src/evict.c:427-447);惰性过期则内嵌在 `lookupKey` 里(src/db.c:219)。

一个值得记住的细节:LRU/LFU 的访问时间戳只在**没有活跃 fork 子进程时**才更新(`hasActiveChildProcess()` 判断,src/db.c:233-239),否则每个访问都会造成父进程页 CoW,save 期间 LRU 会集体"冻龄"。

---

## ② zmalloc 与 jemalloc

### 2.1 分配器抽象与前缀

`zmalloc.h` 用条件编译选择分配器:jemalloc(默认)、tcmalloc、libc。关键分水岭是 `HAVE_MALLOC_SIZE`——jemalloc/tcmalloc/glibc 都能通过 `malloc_usable_size` 类接口报出真实占用,此时 `PREFIX_SIZE=0`(src/zmalloc.c:39-40);否则要在每块内存头部塞 8 字节自己记长度(src/zmalloc.c:43-48)。这意味着在 jemalloc 上 Redis 记账用的是**分配器的真实 bin 大小**而非请求大小,比如请求 33 字节记账为 40 字节,`used_memory` 因此接近真实 RSS 的堆部分。

libc 回退路径还有一个对齐细节:`MALLOC_MIN_SIZE(x)` 把 0 字节请求抬到 `sizeof(long)`,以模仿 jemalloc "分配 0 字节不返回 NULL" 的行为(src/zmalloc.c:50-53)。

统计计数器在 8.x 已经从单一原子变量改成了 **16 槽每线程缓存行对齐数组**,避免多线程 IO 线程在同一个 long 上自旋:

```c
// src/zmalloc.c:82-92
#define MAX_THREADS 16 /* Keep it a power of 2 so we can use '&' instead of '%'. */
#define THREAD_MASK (MAX_THREADS - 1)

typedef struct used_memory_entry {
    redisAtomic long long used_memory;
    char padding[CACHE_LINE_SIZE - sizeof(long long)];
} used_memory_entry;

static __attribute__((aligned(CACHE_LINE_SIZE))) used_memory_entry used_memory[MAX_THREADS];
static redisAtomic size_t num_active_threads = 0;
static __thread long my_thread_index = -1;
```

`zmalloc_used_memory()` 遍历 `num_active_threads` 个槽求和(src/zmalloc.c:503-516)——注意它只统计前 N 个活跃线程的槽,这是一个"最多 16 线程参与记账"的近似。每次分配/释放记账的都不是请求值而是 `zmalloc_size(ptr)` 的 bin 真实值(src/zmalloc.c:142-146)。

### 2.2 分配家族与 jemalloc 特权通道

`zmalloc/zcalloc/zrealloc` 全部由 `ztry*_usable_internal` 一个内联核心派生(src/zmalloc.c:129-154):先挡掉 `SIZE_MAX/2` 以上的溢出请求,分配后回填 usable size。OOM 时调用可替换的 handler——server 启动后 `zmalloc_set_oom_handler` 换成带 panic 日志的版本(src/zmalloc.c:518-520)。

jemalloc 特有通道有三条:

- `zmalloc_with_flags/zfree_with_flags`:走 `mallocx/dallocx` 带 MALLOCX flags(src/zmalloc.c:192-237),主要供共享对象/特定 arena 场景。
- `zmalloc_no_tcache/zfree_no_tcache`:带 `MALLOCX_TCACHE_NONE`,绕过 tcache 直连 arena bin,专供 active defrag 使用——defrag 需要旧块立刻归还给 bin,不能在 tcache 里滞留(src/zmalloc.c:239-256)。
- `je_malloc_with_usize` 系列(`HAVE_ALLOC_WITH_USIZE`,src/zmalloc.h:86-88):Redis 定制版 jemalloc 在 malloc 时顺带返回 usize,省掉一次 `malloc_usable_size` 调用(src/zmalloc.c:70-79)。

### 2.3 RSS 采集与分配器画像

`zmalloc_get_rss()` 是慢路径:Linux 读 `/proc/self/stat` 第 24 字段乘页大小(src/zmalloc.c:607-615),macOS/BSD 走 sysctl。注释明确警告它**不能放在活跃循环里调**(src/zmalloc.c:547-555);`INFO memory` 里的 `used_memory_rss` 周期性采样即可。拿不到 RSS 的平台直接用 `zmalloc_used_memory()` 顶替,此时 mem_fragmentation_ratio 恒为 1(src/zmalloc.c:719-727)。

`zmalloc_get_allocator_info()`(src/zmalloc.c:799-845)通过 `je_mallctl` 取五元组:`stats.allocated`(活数据)、`stats.active`(含内部碎片)、`stats.resident`(映射页)、`stats.retained`(MADV_DONTNEED 后可复用的虚拟页)、`pmuzzy`(MADV_FREE 页,OS 回收前仍计入 RSS)。这组数据对应 INFO 的 `allocator_allocated/active/resident/retained`,是判断"内存去哪了"的第一手证据。8.x 还新增按 arena 查询的 `zmalloc_get_allocator_info_by_arena`(src/zmalloc.c:852-891),配合 cluster/多 IO 线程把碎片按 arena 归因。

最精巧的是 `zmalloc_get_frag_smallbins_by_arena()`(src/zmalloc.c:737-786):遍历所有 small bin,用 `((nregs * curslabs) - curregs) * reg_size` 算出"slab 里没被用掉的 reg 总字节数",即外部碎片;且先把 mallctl 名字转成 MIB 数组避免循环里反复 parse 字符串(src/zmalloc.c:743-753)。这就是 INFO 里 `allocator_frag_smallbins_bytes` 的来源,也是 defrag 判定碎片的量化依据。

两个运维向的入口:`set_jemalloc_bg_thread` 让 jemalloc 后台异步 purge(FLUSHDB 后无流量时也需要归还内存,src/zmalloc.c:894-899);`jemalloc_purge()` 对所有 arena 执行 purge 立即还页给 OS(src/zmalloc.c:901-912),`lazyfreeFreeDatabase` 在后台线程清空 DB 后就会调它(src/lazyfree.c:34-40)。

### 2.4 kvobj:key+value+expire 的融合分配

8.x 的 `kvobj` 在 `robj` 尾部按需内嵌两段数据:8 字节 expire 字段(可选)和 sds 编码的 key(可选)。`kvobjCreateEmbedString` 甚至把短字符串 value 一并塞进同一块分配(src/object.c:143-198),布局注释写得很清楚(robj 16B + key-hdr 1B + key sds + value sds,src/object.c:138-142):

```
+-----------+------------------+------------------------+----------------------------+
| robj (16) | key-hdr-size (1) | sdshdr5 "mykey" \0 (7) | sdshdr8 "myvalue" \0 (11)  |
+-----------+------------------+------------------------+----------------------------+
```

三个 accessor 都靠指针算术直接定位:`kvobjGetKey` 跳过 expire 字段再读 header-size 字节(src/object.c:233-245),`kvobjGetExpire` 读首字段,不可过期直接返回 -1(src/object.c:247-254)。给无 expire 字段的 kvobj 补 TTL 会触发**整体 realloc**(`kvobjSetExpire`,src/object.c:259-273),所以 `setExpireByLink` 里要小心:若 kvobj 重分配,须用 `kvstoreDictSetAtLink` 把新指针写回主 dict(src/db.c:2355-2360);反向操作是创建时"预埋"——只要 bin 剩余空间够塞 8 字节,就顺手把 expirable 置 1,避免将来 TTL 命中时重分配(src/object.c:64-68、172-177)。这是典型的"用一点空间冗余换稳态热路径零 realloc"。

---

## ③ 过期删除三条路径

### 3.0 总览

```
                          ┌────────────────────────────────────────────┐
   路径1 惰性删除          │  客户端 GET/SET → lookupKey → expireIfNeeded│  精确到 ms,主库删除+传播 DEL
   (on-access)            └────────────────────────────────────────────┘
                          ┌────────────────────────────────────────────┐
   路径2 定期采样          │  serverCron(hz,默认10) → 慢周期             │  随机采样 expires dict
   (activeExpireCycle)    │  beforeSleep → 快周期(≤1ms)                 │  每轮 20 keys/DB × effort
                          └────────────────────────────────────────────┘
                          ┌────────────────────────────────────────────┐
   路径3 ebuckets 分桶     │  HFE:activeSubexpiresCycle → estore →      │  O(桶) 直达过期数据
   (8.x 新增)             │  ebExpire(hash 内 ebuckets) → 逐字段删除    │  无采样浪费
                          └────────────────────────────────────────────┘
```

### 3.1 路径一:惰性删除 expireIfNeeded

所有 lookup 类访问都先过 `expireIfNeeded`(src/db.c:2551-2601)。判定本身很朴素:`keyIsExpired` = `now > when`(严格大于,src/db.c:2495-2504)。删除前的四个闸门依次是:

1. **副本默认不删**:`server.masterhost != NULL` 时只返回 `KEY_EXPIRED`,等主库传播 DEL 保证一致性;例外是从主库同步命令流时(`CLIENT_MASTER`)连"过期"都不承认(src/db.c:2571-2574)。
2. **嵌套命令保护**:`confAllowsExpireDel` 阻止脚本/MULTI 嵌套执行中产生 lazy-expire DEL,避免在 proxy 场景引发 CROSS-SLOT(src/db.c:2507-2515)。
3. `EXPIRE_AVOID_DELETE_EXPIRED` 显式只读不删(如 SCAN),src/db.c:2583-2584。
4. `PAUSE_ACTION_EXPIRE` 暂停期间不删(failover 排空,src/db.c:2589)。

真删时走 `deleteExpiredKeyAndPropagate`(src/db.c:2444):`dbGenericDelete` + 键空间通知 `expired` 事件 + `propagateDeletion` 把 `DEL/UNLINK` 写入 AOF 和复制流(src/db.c:2472-2489)。用 UNLINK 还是 DEL 由 `lazyfree_lazy_expire` 决定(src/expire.c:793-799)。

### 3.2 路径二:定期采样 activeExpireCycle

参数随 `active-expire-effort`(1-10,默认 1,src/config.c:3212)线性缩放(src/expire.c:275-284):

```c
// src/expire.c:94-98 + effort 缩放(276-284)
#define ACTIVE_EXPIRE_CYCLE_KEYS_PER_LOOP 20   /* Keys for each DB loop. */
#define ACTIVE_EXPIRE_CYCLE_FAST_DURATION 1000 /* Microseconds. */
#define ACTIVE_EXPIRE_CYCLE_SLOW_TIME_PERC 25  /* Max % of CPU to use. */
#define ACTIVE_EXPIRE_CYCLE_ACCEPTABLE_STALE 10/* % stale keys 后加大力度 */

effort = server.active_expire_effort - 1;               /* 0..9 */
config_keys_per_loop        = 20 + 20/4*effort;         /* 每轮采样键数 */
config_cycle_fast_duration  = 1000 + 1000/4*effort;     /* 快周期上限 us */
config_cycle_slow_time_perc = 25 + 2*effort;            /* CPU 占比上限 */
config_cycle_acceptable_stale = 10 - effort;            /* 容忍过期比 */
```

**慢周期**(hz=10 时每 100ms 一次)的骨架:最多扫 `CRON_DBS_PER_CALL=16` 个 DB(src/server.h:128),每个 DB 用 `kvstoreScan` 带游标随机扫 `expires` dict 的槽位,对采到的 kvobj 调 `activeExpireCycleTryExpire`(src/expire.c:39-52)直接删+传播。三个止损条件:

- 时间墙:`elapsed > timelimit`(慢周期 = `25% * 1s/hz` 微秒),每 16 轮检查一次,命中则 `stat_expired_time_cap_reached_count++`(src/expire.c:466-473);
- 采样有效性:桶填充率低于 1% 的 dict 干脆跳过等 rehash(src/expire.c:128-138);
- 收益判断:`expired*100/sampled > acceptable_stale` 才 repeat——过期比率高说明采样划算,降到 10% 以下就换 DB(src/expire.c:431)。

**快周期**在每次事件循环 `beforeSleep` 里跑,只做 1000us,且有两个门槛:上一个慢周期因时间墙退出,或估计 stale 比率超阈值;且距上次快周期要超过 `2*duration`(src/expire.c:302-315)。快慢互补的设计意图:慢周期保证下限吞吐,快周期在事件循环空隙里"见缝插针"压低过期键滞留时间。

副产物:`avg_ttl` 用 0.98 的指数滑动平均维护,8.x 把原来的循环展开成了预计算幂表(src/expire.c:26、436-461),`INFO` 的 `avg_ttl` 就是这么来的;整体采样统计 `stat_expired_stale_perc` 用 5%/95% 混合(src/expire.c:484-490)。

### 3.3 路径三:ebuckets 分桶过期(HFE 核心)

这是 8.x 最重要的内存结构新增。先看它要解决的问题:hash 字段级过期(HEXPIRE/HPEXPIREFIELDS)意味着**单个 key 内部**可能有百万级字段各自带 TTL。旧世界只有两条路:要么给每个字段一个 dict entry 进全局 expires(内存爆炸),要么定期随机采样 hash(几乎必然采不准)。ebuckets 的答案是"按过期时间分桶的优先队列",让主动过期**直接跳到所有已过期数据**而无需采样。

**ExpireMeta 内嵌元数据**(src/ebuckets.h:162-212):每个带 TTL 的 item(对 HFE 是 hfield 字符串,对 DB 层是整个 hash kvobj)嵌入 48 位毫秒级过期时间(够用到公元 10889 年,src/ebuckets.h:164-167)+ 一组 5 位段内计数/标志位 + 一个多态 `next` 指针——既可能指向下一个 item、下一个段头、也可能回指当前段头形成环。

**三层结构**:ebuckets(空 = NULL;≤16 项退化为单链表,指针 LSB=1 标记,src/ebuckets.c:149-167)→ rax 树(key 为 6 字节大端 `EB_BUCKET_KEY(expireTime)= expireTime >> EB_BUCKET_KEY_PRECISION`,src/ebuckets.c:52-58、173-178)→ bucket(rax 叶子挂 `FirstSegHdr`,内部是若干 ≤16 项的环形单链段):

```
  ebuckets (rax, key = bucketKey = expireTime >> EB_BUCKET_KEY_PRECISION)
  │
  ├──[key=1000]──► FirstSegHdr{head, totalItems=11, numSegs=1}
  │                     │ head (firstItemBucket=1)
  │                     ▼
  │      item(1001)→item(1005)→…→item(1099)      ← 段内按过期时间升序
  │           ▲                        │            lastInSegment=1
  │           └────────next────────────┘            回指 FirstSegHdr(环)
  │
  ├──[key=2000]──► FirstSegHdr{head, totalItems=17, numSegs=2}   ← 扩展段
  │                     │ head=item(2000)   (段内 16 项全部同刻过期)
  │                     ▼
  │      item(2000)×16 → NextSegHdr{head, prevSeg, firstSeg}
  │                          │ head=item(2000)
  │                          ▼
  │      item(2000)×1 ──next──► 回指 FirstSegHdr(环形)
  │
  └──[key=3500]──► FirstSegHdr{...}
```

要点逐条拆解:

- **段就是分桶的桶内聚合**。rax 每片叶子约 40 字节(注释原文,src/ebuckets.h:20-21),而段内多挂一个 item 只多 8 字节 next 指针 + ExpireMeta 里的标志位。EB_SEG_MAX_ITEMS=16(src/ebuckets.c:64)。
- **插入路径** `ebAddToBucket`(src/ebuckets.c:852-930)是一棵决策树:未满段 → 按时间序插入(`ebSegAddAvail`);满段 → 先尝试 `ebTrySegSplit` 按中位 bucket-key 一分为二(src/ebuckets.c:288-355);**切不开**(所有 item 同 bucket-key)→ 变成"扩展段" `ebSegAddExtended` 挂新段头(src/ebuckets.c:203-235)。官方文档里的例子(ebuckets.h:57-61):

```
      BUCKETS                             BUCKETS
     [ 00-10 ] -> size(Seg0) = 11   ==>  [ 00-10 ] -> size(Seg0) = 11
     [ 11-76 ] -> size(Seg1) = 16        [ 11-36 ] -> size(Seg1) = 9
                                         [ 37-76 ] -> size(Seg2) = 7
```

- **删除路径是 O(段) 而非 O(log n)**:`ebRemoveFromRax`(src/ebuckets.c:943-1124)完全靠 ExpireMeta 的 `firstItemBucket/lastInSegment/lastItemBucket` 标志在环上定位段头,只有"bucket 只剩这一个 item"时才 `raxSeek "<="` 找桶并删除(src/ebuckets.c:948-972),rax 树基本不被触碰。被删 item 置 `trash=1`,这样 `ebGetExpireTime` 能识别"遗留元数据"避免误报 TTL(src/ebuckets.c:2003-2009)。
- **主动过期 `ebExpire`**(src/ebuckets.c:1467-1552):从 rax 最小 key 起 `raxSeek "^"` 顺序访问,bucketKey >= nowKey 即停(比 now 新的桶不碰);`ebSegExpire` 把整桶逐段交回调 `onExpireItem` 处理,三种返回:删除/改期(`ACT_UPDATE_EXP_ITEM` 先摘下来进 updateList,循环结束后统一 re-add,src/ebuckets.c:1533-1547)/终止。扩展段甚至**不需要逐个比较时间**——同 bucket-key 意味着整段必然到期,直接批量删(src/ebuckets.c:435-441)。`ebExpireDryRun`(src/ebuckets.c:1564-1651)只扫桶头,用于 `hashExpireDryRun` 这类统计。

- **HFE 的两级组装**。字段级:每个 hfield 的地址天然是奇数(mstr 头部设计),`hashFieldExpireBucketsType.itemsAddrAreOdd = 1`(src/t_hash.c:108),ebuckets 借此区分"rax 指针 vs 链表头指针"两种复用形态(src/ebuckets.c:149-167)。hash 级:每个 hash 自己的 ebuckets 挂在 dict metadata 的 `hfe` 字段;同时把"该 hash 的最小字段过期时间"注册进 DB 级的 `db->subexpires`(一个 estore,src/server.h:1115)——estore 是"按 slot 分片的 ebuckets 数组 + Fenwick 树"(src/estore.h:40-42),负责跨 hash 的快速定位。

- **DB 级调度 `activeSubexpiresCycle`**(src/expire.c:222-269):在 activeExpireCycle 每个 DB 轮次开头与键过期**交错执行**(src/expire.c:369-371)。配额基线 `HFE_DB_BASE_ACTIVE_EXPIRE_FIELDS_PER_SEC(10000)/hz`,若连续消化不完(累计超过 100 万字段)则按比例放大配额最多 32 倍(src/expire.c:233-256);每个 hash 的回调 `activeSubexpiresCb` 调 `hashTypeActiveExpire`(src/t_hash.c:1795-1857)删字段、发 `hexpired` 通知,hash 空了连 key 一起删,还有后续字段则 `ACT_UPDATE_EXP_ITEM` 换个桶重新排队(src/expire.c:163-187)。

---

## ④ 淘汰策略逐个解读

### 4.1 八种策略与内存判定

策略位定义在 src/server.h:654-667,三组标志位 `LRU/LFU/ALLKEYS` 组合出全部行为:volatile-*(只碰带 TTL 的键,查 `db->expires`)、allkeys-*(碰 `db->keys`)、volatile-ttl、两种 random、noeviction。`performEvictions` 之前,`getMaxmemoryState`(src/evict.c:369-405)先把**复制缓冲与 AOF buf 从用量里扣除**:`freeMemoryGetNotCountedMemory`(src/evict.c:308-343)的解释是防正反馈——淘汰产生 DEL,DEL 写进复制流让缓冲变大,缓冲又触发更多淘汰,直至全库清空。复制 backlog 本身有上限、终态恒定,所以只扣"超出 backlog 的 replicas 独享部分"。dict 扩容前还有 `overMaxmemoryAfterAlloc` 预检(src/evict.c:410-420、src/server.c:508-518),避免 rehash 一次吃掉 maxmemory 空间。

### 4.2 近似 LRU:evictionPool

不是真 LRU 链表,而是"每次淘汰前随机采样 maxmemory-samples(默认 5,src/config.c:3198)个键,与 16 槽候选池合并,取池中最差者淘汰"(注释原文见 src/evict.c:83-101)。LRU 时钟 24 位、分辨率 1000ms(src/server.h:1033-1035),`estimateObjectIdleTime` 处理时钟回绕(src/evict.c:73-81)。池的核心是三条评分 + 无锁化插入:

```c
// src/evict.c:142-158(有删节)
if (server.maxmemory_policy & MAXMEMORY_FLAG_LRU) {
    idle = estimateObjectIdleTime(kv);          /* 空转越久分越高 */
} else if (server.maxmemory_policy & MAXMEMORY_FLAG_LFU) {
    idle = 255 - LFUDecrAndReturn(kv);          /* 频率取反,复用同一池 */
} else if (server.maxmemory_policy == MAXMEMORY_VOLATILE_TTL) {
    idle = ULLONG_MAX - kvobjGetExpire(kv);     /* 越早过期分越高 */
}
```

池按 idle 升序,淘汰从右端取。实现里有两个值得学的工程细节:① 候选 key 用 255 字节预分配的 `cached` sds 原地 memcpy 复用,注释直言"profile 说这块分配很贵"(src/evict.c:197-208);② 池中条目删除后不回填,可能残留幽灵键,取的时候 `kvstoreDictFind` 查无此键就顺延取下一条(src/evict.c:611-618)。采样范围是**跨所有 DB** 的,避免"局部最优"(src/evict.c:560-570);cluster 模式下槽内 dict 按公平随机选槽(src/evict.c:130)。

### 4.3 LFU:对数计数器与衰减

LFU 复用 `robj.lru` 的 24 位:高 16 位分钟级时间戳(LDT),低 8 位对数计数 LOG_C(src/evict.c:219-250)。计数不为零初始化——新键从 LFU_INIT_VAL=5 起步(src/server.h:3853),否则新键永远在淘汰序列最底端活不过一次淘汰。

```c
// src/evict.c:271-279 对数递增:计数越大越难加一
uint8_t LFULogIncr(uint8_t counter) {
    if (counter == 255) return 255;
    double r = (double)rand()/RAND_MAX;
    double baseval = counter - LFU_INIT_VAL;
    if (baseval < 0) baseval = 0;
    double p = 1.0/(baseval*server.lfu_log_factor+1);
    if (r < p) counter++;
    return counter;
}

// src/evict.c:291-298 读取时按 lfu-decay-time 折算衰减(不回写)
unsigned long LFUDecrAndReturn(robj *o) {
    unsigned long ldt = o->lru >> 8;
    unsigned long counter = o->lru & 255;
    unsigned long num_periods = server.lfu_decay_time ? LFUTimeElapsed(ldt) / server.lfu_decay_time : 0;
    if (num_periods)
        counter = (num_periods > counter) ? 0 : counter - num_periods;
    return counter;
}
```

两个语义细节:① 衰减是**读时惰性折算**,不在后台定期回写内存;② `lfu-log-factor` 控制达到 255 需要的访问量(默认因子下 255 约需百万次连续访问),`lfu-decay-time`(分钟)控制访问模式迁移速度。访问路径 `updateLFU` 先减后加再写回 LDT(src/db.c:50-54),且与 LRU 一样在 fork 期间冻结。`OBJECT FREQ` 与 `MEMORY USAGE` 都走 `LFUDecrAndReturn`,所以 `OBJECT FREQ` 显示的是衰减后的值。

### 4.4 淘汰主循环 performEvictions

```c
// src/evict.c:545-547, 650-697(骨架)
while (mem_freed < (long long)mem_tofree) {
    ... /* LRU/LFU/TTL:填池取 bestkey;random:各 DB 轮转取随机键 */
    if (bestkey) {
        deleteEvictedKeyAndPropagate(db, keyobj, &key_mem_freed);
        mem_freed += key_mem_freed;  keys_freed++;
        if (keys_freed % 16 == 0) {
            if (slaves) flushSlavesOutputBuffers();      /* 防复制流拥塞 */
            if (server.lazyfree_lazy_eviction &&
                getMaxmemoryState(...) == C_OK) break;    /* 后台还在释放 */
            if (elapsedUs(evictionTimer) > eviction_time_limit_us) {
                startEvictionTimeProc();  break;          /* 时间墙→事件续跑 */
            }
        }
    } else goto cant_free;   /* 无键可淘汰 */
}
```

三个终止出口:配额达成(`EVICT_OK`)、时间墙(注册 `evictionTimeProc` 事件循环续跑,状态 `EVICT_RUNNING`)、无可淘汰(`EVICT_FAIL`,触发对写命令的 OOM 拒绝,src/server.c:4254)。时间墙长度由 `maxmemory-eviction-tenacity`(0-100)映射:≤10 线性 0-500us,10-99 之间 15% 几何增长(99 时约 2 分钟),100 无限(src/evict.c:469-484)。`cant_free` 还有一段"体贴的忙等":若 lazyfree 队列还有活,usleep 轮询等后台释放到位再判定失败(src/evict.c:702-719)。

`key_mem_freed` 的计量在 `deleteKeyAndPropagate` 里:删除前后各采一次 `zmalloc_used_memory() - freeMemoryGetNotCountedMemory()` 作差(src/db.c:2423-2428)。lazy eviction 开启时该差值只含同步释放部分,所以每 16 键要复查一次真实水位(src/evict.c:674-684)。

### 4.5 与 lazyfree 的耦合

淘汰的执行体 `dbGenericDelete`(src/db.c:687-735)值得整段读:两阶段 unlink 摘下 entry → hash 类型先从 `db->subexpires` 摘除 → module 通知/信号 → 若有 TTL 同步删 expires dict 里的 entry → `freeObjAsync` 或 `decrRefCount`。异步分支只把 kvobj 从 dict 槽位置 NULL,真释放丢给 BIO(src/db.c:721-725),配合:

```c
// src/lazyfree.c:184-196
void freeObjAsync(robj *key, robj *obj, int dbid) {
    size_t free_effort = lazyfreeGetFreeEffort(key,obj,dbid);
    if (free_effort > LAZYFREE_THRESHOLD && obj->refcount == 1) {
        atomicIncr(lazyfree_objects,1);
        bioCreateLazyFreeJob(lazyfreeFreeObject,1,obj);
    } else {
        decrRefCount(obj);
    }
}
```

`lazyfreeGetFreeEffort`(src/lazyfree.c:129-174)按类型估价:list 数 quicklist 节点、set/zset/hash 数 dict 大小、stream 用 rax 节点数+消费组 PEL 估、module 类型可自定义 free_effort(返回 0 视为无穷大,强制异步)。阈值 64 的注释一针见血:少量分配的对象异步释放反而更慢(src/lazyfree.c:176-181)。`FLUSHDB ASYNC` 的实现是"换库"而非遍历删:直接把新 kvstore/estore 挂上,旧的整块丢给后台(src/lazyfree.c:201-215),后台释放完还会 flush tcache 并 purge 归还页(src/lazyfree.c:34-40)。

---

## ⑤ 设计动机与取舍:ebuckets 为什么出现

1. **采样式主动过期对"集中过期"场景是 O(N·miss)**。路径二对 key 级 TTL 够用,因为 key 的过期时间通常弥散;但 HEXPIRE 场景常见"一批字段同一秒到期"(比如验证码、限流窗口),随机采样命中率可以低到不可用,而 CPU 还得持续烧。ebuckets 把"找出已过期 item"变成 rax 上的顺序区间扫描:第一个未到期桶即停(src/ebuckets.c:1502-1516),工作量正比于**实际删除量**而非数据总量。expire.c 的注释也明说"releasing fields is expected to be more predictable and rewarding than releasing keys"(src/expire.c:218-221)。

2. **为什么不用现成的最小堆/时间轮**。堆是 O(log n) 且节点独立分配;时间轮槽粒度固定。ebuckets 的核心洞察是**过期时间天然聚集**:把相同 bucket-key 的 item 聚进段,树高被 EB_KEY_SIZE=6 字节锁死(src/ebuckets.c:52-58),而段内操作是纯指针手术。内存账面(rax 叶 40B vs 段内 8B/item)在大批量同 TTL 场景下显著优于逐 item 建树(src/ebuckets.h:16-23)。

3. **精度让位给树宽**。`EB_BUCKET_KEY_PRECISION` 设计值是 10(即 1 秒分桶,src/ebuckets.h:143 目前是 0,TBD 注释明示将来调 10):分桶 key 截去低 10 位后 rax key 只要 4.5 字节、分支更少;精确性由 item 内嵌的 48 位完整时间兜底——惰性删除逐 ms 精确,主动过期只接受"最多晚 1 秒"。这是用过期延迟上界换树规模的一次性交换,且交换比在大多数业务里极划算。当前代码里所有"扩展段不可枚举"的边界(ebGetNextTimeToExpire 的最坏值返回,src/ebuckets.c:1686-1699)都是为 precision>0 预留的。

4. **环形单链段是删除友好性的代价**。为了 O(1) 从段中摘 item,每个 item 记录三态标志并让段尾回指段头;代价是结构不变量多、`ebRemoveFromRax` 有六种分支场景(src/ebuckets.c:940-1121),代码把 `EB_VALIDATE_STRUCTURE` 调试钩子和 `ebValidate` 校验器(src/ebuckets.c:1801-1810)当日常保险丝。

5. **key 级 TTL 为什么不迁去 ebuckets**。key 的过期仍走 `db->expires` kvstore + 采样:① key 必须按 slot 分片、支持 SCAN/随机采样/defrag 全套 kvstore 设施;② `TTL`/`OBJECT IDLETIME` 之外,key 的 TTL 存在 kvobj 里 8 字节,expires dict 只是"有 TTL 的键名索引";③ 迁移意味着把每个 key 塞进全局 ebuckets,而 key 的 TTL 分布远比字段弥散,分桶收益小、rax 维护成本高。可以预期未来 key 级过期也会渐进切换(EB_BUCKET_KEY_PRECISION 的 TBD 即信号),但当前世代它是 HFE 专属基建。

6. **其他取舍**:LFU 用 8 位对数计数在 24 位预算内同时塞下时间与频率,牺牲精度换来零额外内存;eviction pool 用幽灵键容忍换 O(1) 摘取;lazyfree 用"对象计数"而非"字节数"作为工作量单位,虽不精确但免锁。

---

## ⑥ FAQ

**Q1:`used_memory` 和 `used_memory_rss` 为什么差一个数量级量级之外还会出现负的 fragmentation?**
前者是 zmalloc 记账的逻辑堆(分配请求 bin 对齐后的值),后者来自 `/proc/self/stat` 第 24 字段(src/zmalloc.c:607-615)。jemalloc purge/`MADV_DONTNEED` 之后 RSS 暂时低于逻辑值,rss_overhead 为负是正常瞬态。

**Q2:为什么 `zfree` 不需要传长度?**
因为 jemalloc/tcmalloc/glibc 都提供 usable-size 查询,Redis 直接 `zmalloc_size(ptr)` 反查(src/zmalloc.c:460-462);只有 libc 无此能力的平台才靠 8 字节前缀自存长度(src/zmalloc.c:463-469)。

**Q3:同一 key 反复 EXPIRE 会不会反复分配?**
首次设 TTL 可能触发一次 kvobj realloc(补 expire 字段,src/object.c:259-273);之后 kvobjSetExpire 只改首字段,断言保证不再重分配(src/db.c:2344-2347)。创建时若 jemalloc bin 有富余会预埋 expire 字段避免这次 realloc(src/object.c:64-68)。

**Q4:共享对象(refcount=1<<30-1)为什么不怕并发计数?**
`OBJ_SHARED_REFCOUNT` 是不可变哨兵,incr/decr 直接短路(src/object.c:581-583、590-591);共享对象永不销毁,也就无需计数。栈对象哨兵 `OBJ_STATIC_REFCOUNT` 被错误 incr 会 panic(src/object.c:583-585)。

**Q5:UNLINK 和 DEL 现在还有什么区别?**
命令入口 `unlinkCommand` 固定走 `dbAsyncDelete`;DEL 由 `lazyfree-lazy-server-del` 决定(src/db.c:750-751)。但**真正决定是否异步的是 free effort>64 且 refcount==1**,小对象 UNLINK 实际同步释放(src/lazyfree.c:190-195)。过期/淘汰路径也各自有 `lazyfree-lazy-expire/eviction` 开关(src/db.c:2396)。

**Q6:FLUSHDB ASYNC 后内存为什么不立刻还给 OS?**
主线程只换掉 kvstore 指针(src/lazyfree.c:210-214);BIO 线程释放完还要 `thread.tcache.flush` + `jemalloc_purge()` 才归页(src/lazyfree.c:34-40)。默认 jemalloc 后台线程可能延迟脏页清理,`set_jemalloc_bg_thread` 由此而来(src/zmalloc.c:894-899)。

**Q7:activeExpireCycle 会占多少 CPU?**
默认 effort=1 时慢周期上限为每周期 `25% * (1s/hz)` 微秒(hz=10 即 25ms),快周期 1000us;最坏 CPU 占比 ≈ 25% + 快周期实际执行比。effort=10 时 slow_time_perc=43%、stale 阈值降到 1%,过期更激进(src/expire.c:276-284)。

**Q8:为什么我的过期键 INFO 里 avg_ttl 突然变化很大?**
avg_ttl 是 0.98/0.02 指数滑动平均(src/expire.c:439-461),且只在采样到"未过期键"时更新;大量键同时过期后样本骤减,数值会跳。它只是估计值,别当精确统计。

**Q9:副本上的键到底什么时候物理消失?**
只读副本永不主动删,`expireIfNeeded` 只报 KEY_EXPIRED,等主库 DEL 传播(src/db.c:2571-2574);可写副本上"自己创建且带 TTL"的键由 `expireSlaveKeys` 单独跟踪回收(src/expire.c:532-581,位图限 DB0-63,src/expire.c:598)。

**Q10:LFU 计数会溢出或永久饱和吗?**
255 饱和是设计内(1/(baseval*factor+1) 概率递增,src/evict.c:271-279);衰减按 elapsed/lfu-decay-time 整除扣减,长尾冷却会把它拉回低区。16 位 LDT 每 45 天回绕一次,`LFUTimeElapsed` 按恰好回绕一周处理(src/evict.c:263-267)。

**Q11:淘汰为什么有时候报 OOM 但内存其实降了?**
lazy eviction 下 `mem_freed` 只统计同步部分,后台还在还债;主循环每 16 键和 `cant_free` 忙等阶段都会复查真实水位(src/evict.c:674-684、702-719),若仍不达标才返回 EVICT_FAIL。

**Q12:ebuckets 的 trash 标志是干什么的?**
item 从 ebuckets 摘除后其 ExpireMeta 仍是脏数据;`trash=1` 让 `ebGetExpireTime` 返回 EB_EXPIRE_TIME_INVALID(src/ebuckets.c:2003-2009),调用方(如 hashTypeGetMinExpire,src/t_hash.c:1914-1915)可安全区分"真实 TTL"与"残留",避免对象复用后误判。

---

## ⑦ 深挖问题

1. **`EB_BUCKET_KEY_PRECISION` 从 0 调到 10 的过渡期兼容性**:当前代码里大量分支(ebGetNextTimeToExpire/ebGetMaxExpireTime/ebExpireDryRun 的扩展段路径)只在 precision>0 时可达且标注"为完整性保留"(src/ebuckets.c:1625-1650)。一旦启用,主动过期最晚延迟 1 秒、nextExpireTime 变成区间上界,`HBLOCK`/`hashExpireDryRun` 等依赖精确 next-expire 的语义如何收敛?这是 8.x 后续版本最值得跟踪的一个未落定项。

2. **per-thread used_memory 数组的 16 上限**:MAX_THREADS=16(src/zmalloc.c:82),`init_my_thread_index` 用 atomic fetch-add 分槽,第 17 个线程会与既有线程共享槽位(`&= THREAD_MASK`),记账仍正确但退化回争用;IO 线程 + 主线程 + BIO 不开 16 条,但 module 线程池场景下 `zmalloc_used_memory()` 只扫 `num_active_threads` 个槽(src/zmalloc.c:510-514)是否可能漏加后注册线程的槽位?值得写测试验证。

3. **`mem_freed` 计量与 kvobj 融合分配的交互**:`deleteKeyAndPropagate` 用 zmalloc 差值计量单键释放量(src/db.c:2423-2428),而 kvobj 把 key/value/expire 合进一次分配;淘汰大 hash 时 value 是独立分配但 kvobj 本体可能很大,淘汰循环的 `mem_freed < mem_tofree` 停止条件在"大量小 key"场景的计量误差(每键 ±bin 对齐)是否会系统性偏早/偏晚退出?可对照 `stat_evictedkeys` 与 `mem_freed` 分布做实验。

4. **EB_SEGMENT 的 defrag 代价**:`ebScanDefrag`(src/ebuckets.c:1986-2001)逐桶逐段重分配并修复环上所有 prevSeg/firstSeg 回指(src/ebuckets.c:1844-1914),且用静态 `next` 缓存游标。在扩展段(同 key 数十万 item)场景,单桶 defrag 是无界长操作,与 defrag.c 的分片 budget 如何协调(defrag.c:1406 处每轮只处理一个 bucket)?

5. **expires dict 采样与 ebuckets 的混合稳态**:若未来 key 级过期迁到 ebuckets,`activeExpireCycle` 的快/慢周期、`stat_expired_stale_perc` 反馈回路、以及 expires kvstore 的 rehash 内存都随之消失;但 replica 依赖"主库传播 DEL"的一致性模型下,分桶过期在主从时钟偏差(PAUSE_ACTION_EXPIRE、failover 窗口)中的行为需要重新论证——对照 src/expire.c:297-300 的暂停语义与 estore 的桶推进逻辑推演一遍是最有价值的练习。

---

*报告完。所有行号基于 e8726d18(unstable, 2025-09-15)。*
