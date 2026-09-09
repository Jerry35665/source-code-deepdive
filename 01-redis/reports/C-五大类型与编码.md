# C 篇 · 五大类型与底层编码(robj → t_string/t_list/t_hash/t_set/t_zset/t_stream)

> 调研基线:redis 仓库 unstable 分支,commit e8726d18(2025-09-15)。`src/version.h` 中 255.255.255 为 unstable 开发标记。本分支无 `src/client.c`,客户端逻辑位于 `networking.c`;另注意本分支引入了 **kvobj**(key 内嵌进 value 对象的新布局,object.c:39-85),属于 8.x 之后的实验性方向,下文单独说明。

---

## ① robj 与编码系统全景

### 1.1 robj:一个 16 字节的"类型 + 编码"头

所有键值在 Redis 内部都以 `redisObject`(robj)表示,定义在 src/server.h:1036-1045:

```c
struct redisObject {
    unsigned type:4;        // OBJ_STRING/LIST/SET/ZSET/HASH/...
    unsigned encoding:4;    // 底层编码,见下表
    unsigned lru:LRU_BITS;  // 24bit:LRU 时钟或 LFU(低8bit频率+高16bit时间)
    unsigned iskvobj : 1;   // 本分支新增:是否作为 kvobj 基座
    unsigned expirable : 1;
    unsigned refcount : OBJ_REFCOUNT_BITS;  // 30bit
    void *ptr;
};
```

- `type` 是对外命令的视图(GET/LPUSH/HSET…),`encoding` 是内存布局的实现选择。二者解耦,是整个"多态编码"体系的根:`checkType()`(object.c:795-802)只看 type,命令实现再按 encoding 分派。
- 编码常量共 13 个(server.h:1019-1031),其中 `ZIPMAP(3)`、`LINKEDLIST(4)`、`ZIPLIST(5)` 已废弃,注释明确写着 "No longer used";新增 `LISTPACK_EX(12)` 用于带字段级 TTL 的 hash。
- 引用计数是 30bit 的位域(object.h/server.h:1037),并保留两个哨兵值:`OBJ_SHARED_REFCOUNT`(2^30-1,共享对象永不算析构,object.c:577-591)与 `OBJ_STATIC_REFCOUNT`(栈对象,incr 会触发 serverPanic,object.c:583-585)。

### 1.2 类型 × 编码对照表(含当前代码阈值默认值)

| 类型 | 可能的 encoding | 初始编码 | 切换阈值(默认值) | 配置项(config.c) |
|---|---|---|---|---|
| string | int / embstr / raw | embstr(raw 按 44 字节分流) | ≤20 位可转 int;≤44 字节 embstr;否则 raw | 无(硬编码 `OBJ_ENCODING_EMBSTR_SIZE_LIMIT 44`,object.c:329) |
| list | listpack / quicklist | listpack | 单节点字节数超 `list-max-listpack-size`(默认 -2 → 8KB,config.c:3187;optimization_level 见 quicklist.c:49)转 quicklist | `list-max-listpack-size`、`list-compress-depth`(默认 0,config.c:3209) |
| hash | listpack / listpack_ex / hashtable | listpack | field 数 > 512 或任一 field/value > 64 字节转 HT | `hash-max-listpack-entries 512`、`hash-max-listpack-value 64`(config.c:3252,3258) |
| set | intset / listpack / hashtable | intset(全整数时)否则 listpack | intset 上限 `set-max-intset-entries 512`;listpack 上限 128 个 / 64 字节 | `set-max-intset-entries 512`、`set-max-listpack-entries 128`、`set-max-listpack-value 64`(config.c:3253-3255) |
| zset | listpack / skiplist(+dict) | listpack | 128 个元素或单元素 > 64 字节转 skiplist | `zset-max-listpack-entries 128`、`zset-max-listpack-value 64`(config.c:3256,3260) |
| stream | stream(radix tree + listpack) | stream | 宏节点:`stream-node-max-bytes 4096`、`stream-node-max-entries 100`(config.c:3259,3243) | 同左 |
| module | module | — | — | — |

> hash 的 `listpack_ex` 编码在本分支承担 Redis 7.4 引入的 Hash Field Expiration:一旦对某 field 设置 TTL,listpack 会升级为 `listpackEx`(t_hash.c:267-271 注释、t_hash.c:1530-1553 转换逻辑),每个 field 变为 field/value/ttl 三元组。

### 1.3 共享整数池与 refcount 语义

- `OBJ_SHARED_INTEGERS = 10000`(server.h:132),启动时在 `createSharedObjects()` 中以 `makeObjectShared(createObject(...))` 造出 0..9999 的 int 编码对象,refcount 置为 `OBJ_SHARED_REFCOUNT`(server.c:2159-2163)。
- `createStringObjectFromLongLongWithOptions()`(object.c:356-373):值落在 [0,10000) 且 flag 为 AUTO 时直接返回 `shared.integers[value]`,零分配;否则若是 long 范围内整数则造 `OBJ_ENCODING_INT` 对象——注意 `o->ptr = (void*)((long)value)`,整数直接藏在指针槽里,不指向任何内存(object.c:363-365)。
- 但共享对象不能带每键 LRU/LFU 信息,所以 `createStringObjectFromLongLongForValue()`(object.c:386-393)在 maxmemory 策略为 LRU/LFU(`MAXMEMORY_FLAG_NO_SHARED_INTEGERS`)时拒绝返回共享整数——INCR 这类"值即键值"的命令走的是它。
- `tryObjectEncodingEx()`(object.c:837-895)是 string 编码升级的总入口,三步:
  1. `refcount > 1` 直接放弃(object.c:856)——共享对象遍布"对象空间",不能原地改写;
  2. `len <= 20 && string2l()` 成功 → 释放 SDS,改为 INT 编码(object.c:862-873);
  3. `len <= 44` 且还是 RAW → 重建为 EMBSTR(object.c:879-886);最后退而求其次做 SDS 碎片回收 `trimStringObjectIfNeeded`(空闲空间 > len/10 时 `sdsRemoveFreeSpace`,object.c:820-834)。
- SET 命令在入口处就调用 `c->argv[2] = tryObjectEncoding(c->argv[2])`(t_string.c:303),即"写路径预编码",GET 侧则永远是零成本读取。

### 1.4 本分支新动向:kvobj

unstable 分支正在把 key 内嵌进 value 对象(kvobj):`kvobjCreate()` 把 robj + 可选 8 字节 expire + 1 字节 sds 头长 + key 的 SDS 连续排布(object.c:30-85),EMBSTR value 还能进一步内嵌(`kvobjCreateEmbedString`,object.c:143-198),总尺寸 ≤ `CACHE_LINE_SIZE` 时才内嵌(object.c:288)。动机是把 "key→robj→value SDS" 的三次指针追逐压成一次缓存行访问,并让 TTL 就地修改(`kvobjSetExpire`,object.c:259-273)。本文其余部分仍按经典 robj 描述。

---

## ② 逐类型解读

### 2.1 string:int / embstr / raw 三级

- **int**:`ptr` 即数值本身。INCR/DECR 的热路径 `incrDecrCommand()`(t_string.c:591-640)在 `o->refcount==1 && o->encoding==OBJ_ENCODING_INT` 时直接 `o->ptr = (void*)((long)value)` 原地加,不分配不释放(t_string.c:614-622);否则走 `createStringObjectFromLongLongForValue` 重建。
- **embstr**:robj(16B) + sdshdr8(3B: len/alloc/flags) + 数据 + '\0',一次性 `zmalloc(sizeof(robj)+val_sds_size)` 分配(object.c:209-231)。44 字节阈值让 16+3+44+1=64,恰好塞满 jemalloc 的 64 字节 bin——object.c:323-329 的注释原话:"chosen so that the biggest string object ... will still fit into the 64 byte arena of jemalloc"。旧版(≤3.0)阈值是 39,因为当时 SDS 头是 8 字节的 `{int len; int free;}`;3.2 重构 SDS 后阈值才升到 44,这就是"39/44"两代阈值的由来。
- **embstr 是只读的**:任何修改命令(SETRANGE/APPEND/INCRFLOAT)必须先 unshare。`dbUnshareStringValue`(db.c:792)把 embstr/raw 重建为可变 RAW;SETRANGE 对共享/INT 编码同样先 unshare(t_string.c:488-489)。
- GETRANGE 对 INT 编码有专门优化:把 long 格式化到栈上 32 字节缓冲再切片,不解码成新对象(t_string.c:510-516)。
- 整数比较也有捷径:`equalStringObjects()` 在双方都是 INT 时直接比指针值(object.c:990-1004)。

### 2.2 list:listpack → quicklist(双端、分片、可压缩)

list 的编码只有两种:小表整表 listpack;超过阈值后整表升级为 quicklist。**没有回退之外的部分转换**——quicklist 内部每个节点自己又是一个 listpack。

**升级(t_list.c:23-56)**:LPUSH/RPUSH 等在追加前调用 `listTypeTryConversionAppend`,把待加元素的 `sdslen` 累加进 `lpBytes + add_bytes`,超过 `quicklistNodeExceedsLimit(server.list_max_listpack_size, ...)` 就把现有 listpack 整体包成 quicklist 的第一个节点(`quicklistAppendListpack`),encoding 换为 `OBJ_ENCODING_QUICKLIST`(t_list.c:46-54)。

**降级(t_list.c:67-95)**:删除元素后(LZRANGE/LREM/LPOP 等)调用 `LIST_CONV_SHRINKING`,但只当 quicklist **只剩一个 PACKED 节点**且该节点尺寸/元素数低于限值的一半才转回 listpack(t_list.c:75-84)——半阈值滞回防止在临界尺寸上反复双向转换。

**fill 参数:一个值表达两种语义**(quicklist.c:472-482):

- `fill >= 0`:单节点最多 `fill` 个**元素**(`count_limit`);
- `fill < 0`:单节点最多 `optimization_level[-fill-1]` **字节**,即 -1→4KB、-2→8KB、-3→16KB、-4→32KB、-5→64KB(quicklist.c:49,462-468)。默认 -2 = 8KB(quicklist.c:135 与 config.c:3187 一致)。

负值(按字节)是生产默认,因为元素大小差异大时按个数填充会让节点内存极不均匀。另有安全阀 `SIZE_SAFETY_LIMIT 8192`:即使按个数限填,单元素超过 8KB 也会被拒之节点外,转而落入 PLAIN 节点(quicklist.c:69,498,508-514)——超大元素独占一个 `QUICKLIST_NODE_CONTAINER_PLAIN` 节点,不进 listpack(quicklist.c:571-577,586-589)。插入前用 `_quicklistNodeAllowInsert` 估算 `node->sz + sz + 8` 是否超限(quicklist.c:516-533),相邻节点还能合并(quicklist.c:535-550)。

**compress 参数与 LZF 布局**:`list-compress-depth N` 表示**首尾各 N 个节点保持明文**,中间节点以 LZF 压缩存放。压缩宏 `__quicklistCompress`(quicklist.c:307-378)的规则:

- 列表长度 `< compress*2` 时不压缩(两端深度区间重叠,quicklist.c:316-318);
- 从 head/tail 各走 N 步 `quicklistDecompressNode` 解压,对越界一个身位的两个节点 `quicklistCompressNode`;
- 被访问的压缩节点先经 `quicklistDecompressNodeForUse` 解压并置 `recompress=1`,操作完成后立即重压(quicklist.c:284-290,389-395);
- 压缩本身有两道门槛:节点 `< MIN_COMPRESS_BYTES(48 字节)` 不压;`lzf->sz + MIN_COMPRESS_IMPROVE(8) >= node->sz`(收益不足 8 字节)放弃,回退 zfree(quicklist.c:226-238)。

中间节点的读写路径也值得注意:`quicklistInsertAfter/Before` 与迭代器在对节点动手前会 `quicklistDecompressNodeForUse` 解压并置 `recompress=1`,操作结束后统一 `quicklistCompress` 收尾(quicklist.c:1014-1060,389-395);head/tail 的 recompress 恒为 0,因为两端必须始终可访问。LZF 压缩的是整个节点(一个 listpack),属于块级压缩而非条目级——这也是为什么 PLAIN 大元素节点永不参与压缩。

compress=2 时的内存布局:

```
      head                                                      tail
       │                                                         │
       ▼                                                         ▼
  ┌─────────┐   ┌─────────┐   ┌══════════┐   ┌══════════┐   ┌─────────┐   ┌─────────┐
  │ listpack │◄─►│ listpack │◄─►│ LZF 压缩块 │◄─►│ LZF 压缩块 │◄─►│ listpack │◄─►│ listpack │
  └─────────┘   └─────────┘   └══════════┘   └══════════┘   └─────────┘   └─────────┘
   明文(深度2)  明文(深度2)     中间全部压缩      中间全部压缩     明文(深度2)   明文(深度2)

  每个节点(quicklistNode,32B,quicklist.h:41-56):
  +--------+--------+---------+-----+--------+----------+------------+
  │ *prev  │ *next  │ *entry  │ sz  │ count:16│ enc:2 RAW/LZF │ container:2 │ recompress...│
  +--------+--------+---------+-----+--------+----------+------------+
  LZF 节点的 entry 指向 quicklistLZF{ size_t sz; char compressed[]; }(quicklist.h:58-66),
  未压缩长度仍存在 node->sz 中,解压时按它分配。
```

为什么首尾永远明文:Redis 假定 list 的读写集中在中部(LPOP/RPUSH 等都在两端),两端热、中间冷;LZF 是 O(n) 的轻量压缩,换来的是中间冷数据 2-10 倍的空间节省,代价只在访问时一次性解压。

### 2.3 hash:listpack / listpack_ex / hashtable

- 查找/写入入口先做 `hashTypeTryConversion`(t_hash.c:593-623):(a) 本次命令的 field 数 `new_fields > hash_max_listpack_entries` 直接转 HT 且 `dictExpand` 预分配(t_hash.c:603-607,多 field 命令 HMSET 一次到位避免 rehash);(b) 逐个参数检查任一 sds 长度 > 64 转 HT;(c) `lpSafeToAdd` 碎片守卫失败也转。
- 单条 HSET 路径在 `hashTypeSet`(t_hash.c:880-1002):listpack 内 `lpFind(...,stride=1)` 找 field(field,value 交替,步长 1),命中则 `lpReplace` value,未命中 `lpBatchAppend` 两项;插入后若 `hashTypeLength > 512` 转 HT(t_hash.c:922-923)。
- **listpack_ex**:设置字段 TTL 后 listpack 从二联组变三联组(field, value, ttl),`lpFind` 步长变 2(t_hash.c:653),ttl 为整数编码,`HASH_LP_NO_TTL` 表示无过期(t_hash.c:927);转 HT 后 field 用带元数据的 `hfield` + ebuckets 承接过期(t_hash.c 注释 1517 附近的 dictType 说明)。
- HT 编码的 value 一定是独立 sds,field 在本分支是 `hfieldNew` 分配的 mstr(t_hash.c:971-972)。

### 2.4 set:intset / listpack / hashtable(三种、且可"优雅降级")

set 是 7.2+ 编码最多的类型,因为 intset 与 listpack 各司其职:

- **创建**:`setTypeCreate()`(t_set.c:31-42)——值可解析为整数且 `size_hint <= set-max-intset-entries` → intset;否则 `size_hint <= 128` → listpack;否则 HT 并 `dictExpand` 预扩。
- **加元素**(`setTypeAddAux`,t_set.c:110-215)四条路:
  - intset + 整数:`intsetAdd`,成功后 `maybeConvertIntset` 检查 512 上限(t_set.c:63-67);
  - listpack:`lpFind` 判重后,若 `lpLength < 128 && len <= 64 && lpSafeToAdd` 则 `lpAppend`(整数走 `lpAppendInteger`,t_set.c:148-159),否则转 HT;
  - **intset + 非整数(亮点)**:不是无脑转 HT——先算 intset 的最大/最小元素的十进制长度与估算 listpack 体积,若 `intsetLen < 128 && len <= 64 && maxelelen <= 64` 则**先降级成 listpack 再追加**(t_set.c:176-201),只有真的放不下才转 HT。这避免了"一个字符串污染全家"的内存跃迁。
  - HT 直接 `dictFindLink`/`dictSetKeyAtLink`。
- **反向转换**:`maybeConvertToIntset`(t_set.c:72-94)在 SINTERSTORE 等结果全为整数时把 HT 整表重建为 intset——set 是唯一有"HT→紧凑编码"回退路径的类型(zset 的 skiplist→listpack 回退也存在,但 set 这条跨越两种紧凑结构)。
- 删除不降级:`setTypeRemoveAux` 在 listpack/intset 里删元素不会触发缩容转换(t_set.c:229-258),降级只发生在特定命令路径。

### 2.5 zset(重点):skiplist + dict 双结构与查找路径

**为什么是双结构**(t_zset.c:20-42 的注释):dict 提供 ele→score 的 O(1) 查(满足 ZSCORE、ZADD 判重),skiplist 提供 score 有序视图(满足 ZRANGE/ZRANGEBYSCORE/ZRANK)。关键内存技巧:**两份结构共享同一个 ele SDS**——dict 的 key 与 zsl 节点的 ele 指向同一块内存,SDS 只在 `zslFreeNode` 释放(t_zset.c:29-33),dict 的 value 是 `&node->score`(指向 skiplist 节点内 score 字段的指针,zsetAdd t_zset.c:1528 `dictAdd(zs->dict,ele,&znode->score)`)。因此删除必须**先 dict 后 skiplist**(t_zset.c:1552-1563 注释:skiplist 释放时会 free 共享 SDS)。

结构定义(server.h:1546-1565):

```c
typedef struct zskiplistNode {
    sds ele;
    double score;
    struct zskiplistNode *backward;      // 只有第1层有后退指针
    struct zskiplistLevel {
        struct zskiplistNode *forward;
        unsigned long span;              // 跨过的节点数,用于 O(logN) 求秩
    } level[];                           // 柔性数组,层高即节点大小
} zskiplistNode;
```

常量(server.h:612-614):`ZSKIPLIST_MAXLEVEL 32`(注释:"enough for 2^64 elements")、`ZSKIPLIST_P 0.25`、`ZSKIPLIST_MAX_SEARCH 10`。

skiplist 侧的完整拓扑(3 层示意,span 标在指针旁):

```
 zsl: header ────────────────────────────────┐   tail
   level[2]:  ────────(3)───► C ────(4)────► │           │
   level[1]:  ──(1)──► A ─(2)─► C ──(2)──► D │           │
   level[0]:  ─(1)─► A(1)B(1)C(1)D(1)E ─────►│           │
                ▲        ▲backward       ▲                 ▲
                └────────┴────────────────┴─────────────────┘
   · span 只存在于 forward 指针上;沿 level[i] 下降时把跨过的 span 累加,
     即得任意节点的 1-based 秩(zslGetRank,zslGetElementByRank)。
   · backward 仅 level[0] 有,且 header 的 backward==NULL、最后一个节点的
     forward==NULL 时 tail 指向它——ZREVRANGEBYSCORE 反向游标全靠它。
   · 每个节点的 level[] 是柔性数组,层高越高节点越大,内存按需分配
     (zslCreateNode:zmalloc(sizeof(*zn)+level*sizeof(zskiplistLevel)),t_zset.c:60-66)。
```

同分(score 相同)节点按 ele 字典序串联,这就是"允许重复 score 的 Pugh 变体"落点(t_zset.c:38-39):比较函数写成 `score < || (score == && sdscmp < 0)`,所有插入/删除/定位共用。

**层高随机算法**(t_zset.c:111-117):幂次定律——每层晋升概率 P=1/4,期望层高 1/(1-P)=1.33。P=1/4(而非教科书 1/2)是空间换时间的调参:层高更低、节点更小、缓存更友好,单层期望步长 4 仍保持 O(log N)。

```c
int zslRandomLevel(void) {
    static const int threshold = ZSKIPLIST_P*RAND_MAX;
    int level = 1;
    while (random() < threshold) level += 1;
    return (level<ZSKIPLIST_MAXLEVEL) ? level : ZSKIPLIST_MAXLEVEL;
}
```

**zslInsert**(t_zset.c:122-177)四步,`update[]` 记录每层待接节点、`rank[]` 记录到该位置的跨距:
1. 自 `zsl->level-1` 层向下扫,同层内 `forward->score < score || (== 且 sdscmp(ele)<0)` 前进(重复 score 按 ele 字典序破平,t_zset.c:132-139),累计 `rank[i] += span`;
2. `zslRandomLevel()` 出层高,高于现表层时补 header 指针并把新层 span 初始化为 `zsl->length`(t_zset.c:147-154);
3. 逐层接线并维护 span:`x->level[i].span = update[i]->span - (rank[0]-rank[i]); update[i]->span = (rank[0]-rank[i]) + 1`(t_zset.c:156-162)——span 让 ZRANK/ZRANGE 不用逐节点计数;未触及的高层 span++(t_zset.c:166-168);
4. 维护 backward:`x->backward = (update[0]==header) ? NULL : update[0]`(t_zset.c:170-174)。backward 只有第 0 层有,支撑 ZREVRANGE/ZREVRANGEBYSCORE 的反向遍历。

ZADD 更新分数走 `zslUpdateScore`(t_zset.c:249-291):若新分数不改变位置(`backward->score < newscore && forward->score > newscore`)只改 score 字段;否则 `zslDeleteNode + zslInsert` 并复用旧节点的 SDS(`x->ele = NULL` 后 free 旧节点,t_zset.c:284-290)。

**ZRANGEBYSCORE 的查找路径**(`genericZrangebyscoreCommand`,t_zset.c:3257-3358):
- listpack 编码:`zzlFirstInRange` 线性扫到第一个入界元素,然后沿 listpack 顺序走,limit 控制条数,出界即停(t_zset.c:3270-3322);
- skiplist 编码:入口是 `zslNthInRange(zsl, range, offset)`(t_zset.c:331-395)。它先用 O(1) 的 `zslIsInRange`(只看 tail 与第一个元素是否可能入界,t_zset.c:302-316)短路,再从最高层"出界才前进"地滑到下界,随后本分支有个新优化:offset < `ZSKIPLIST_MAX_SEARCH(10)` 时直接 level[0] 逐节点跳 `n+1` 步,offset 大时改从"最后一个最高层节点"出发用 `zslGetElementByRankFromNode` 按 span 跳位(t_zset.c:354-364)——小 offset 用逐跳避免 span 换算的 CPU,大 offset 用 span 换取 O(log N)。反向(n<0)则沿 backward 前进(t_zset.c:367-392)。定位后循环 `limit--` 逐节点 `ln->level[0].forward`(反向 `ln->backward`)输出,出界即断。

**listpack 编码的 zset**:ele、score 严格交替(zzl),且按 score→ele 有序插入(`zzlInsert`,t_zset.c:1106-1137);score 能用 `double2ll` 表示时直接以 listpack 整数编码存放(t_zset.c:1077-1094)。ZADD 更新 score = `zzlDelete(2 项) + zzlInsert` 重新有序插入(t_zset.c:1455-1458)。转 skiplist 时 `zsetConvertAndExpand` 会 `dictExpand` 预扩避免 rehash(t_zset.c:1277)。ZADD 添加新元素前在**插入前**检查三项(t_zset.c:1464-1466):`zzlLength+1 > 128 || sdslen(ele) > 64 || !lpSafeToAdd` → 先转 skiplist 再插。

### 2.6 stream(概览):rax + listpack 宏节点、消费组与 PEL

- 顶层 `stream` 结构(stream.h:16-27):主数据是 `rax *rax`,key 为 **128bit big-endian 的 streamID**(`uint64_t rax_key[2]`,t_stream.c:487),value 是一个 listpack 宏节点;另有 `cgroups` rax(name→streamCG)。本分支新增 `cgroups_ref`(消息 ID→消费组反查索引)与 `min_cgroup_last_id`(stream.h:24-26),用于加速消费组相关扫描。
- **XADD 与宏节点**(`streamAppendItem`,t_stream.c:420-663):raxSeek "$" 定位尾节点(t_stream.c:470-482),尾 listpack 达到 `stream-node-max-bytes(4096)` 或 `stream-node-max-entries(100)` 即开新宏节点(t_stream.c:525-546)。每个宏节点头部有一个 **master entry**(字段名模板):

```
 宏节点头(master entry,t_stream.c:500-520):
 +-------+---------+------------+---------+--/--+---------+---+
 | count | deleted | num-fields | field_1 | ... | field_N | 0 |
 +-------+---------+------------+---------+--/--+---------+---+
 普通条目(t_stream.c:614-632):
 +-----+--------+----------+-------+-------+-/-+-------+-------+--------+
 |flags|ms-delta|seq-delta |num-fld|field-1|val-1|...|field-N|val-N|lp-count|
 +-----+--------+----------+-------+-------+-/-+-------+-------+--------+
 flags 含 SAMEFIELDS 位时字段名全部省略(t_stream.c:618-623);ID 存相对 master 的 delta。
```

  即 stream 用"字段名字典 + 差分 ID"在 listpack 内做了第二层压缩;`lp-count` 支持从尾部反向扫描。删除不打洞,只置 `STREAM_ITEM_FLAG_DELETED` 位(t_stream.c:17-19),XLEN 用 `s->length` 计数、墓碑由 XTRIM/渐增式清理处理。
- **消费组与 PEL**:`streamCG{last_id, entries_read, pel(rax), consumers(rax)}`(stream.h:58-76)。XREADGROUP 投递时为每条消息造一个 `streamNACK{delivery_time, delivery_count, consumer}`,**同一个 NACK 指针同时插入 group->pel 与 consumer->pel 两个 rax**(t_stream.c:1864-1897),避免双份数据;若该 ID 已有 NACK(可能是别的消费者领走的)则转移所有权。ACK(XACK)从两个 PEL 摘除;XCLAIM/XAUTOCLAIM 改 NACK 的 consumer 并传播 XCLAIM 命令保证主从一致(t_stream.c:1667-1674)。PEL 的 key 也是 big-endian ID,所以 PEL 天然有序,支持按 idle/ID 范围扫描。
- `group->last_id`(last-delivered-id)是消费组的游标:XREADGROUP 以 `>` 取"大于 last_id 且未投递"的消息;`entries_read` 是组已读计数,但只有在"组游标无空洞、流无墓碑"等条件下才可信,否则用 `streamEstimateDistanceFromFirstEverEntry()` 估算(t_stream.c:1818-1830)——这是一个"尽力而为的计数器",不能当精确值用。
- stream 没有"编码切换":rax+listpack 本身就是可扩展的分层设计,`OBJ_ENCODING_STREAM` 只是占位标记。

---

## ③ 编码切换的触发条件与成本

| 切换 | 触发点(代码) | 成本 |
|---|---|---|
| raw/embstr→int | 写路径 `tryObjectEncoding`(object.c:862-873;SET 入口 t_string.c:303) | O(len) 解析一次,释放 SDS;此后读写 O(1) |
| raw→embstr | 同上(object.c:879-886) | 一次分配+拷贝,省一次解引用 |
| int/embstr→raw(unshare) | 任何修改命令(如 SETRANGE t_string.c:489,db.c:792) | 一次完整拷贝;对共享整数还会终止共享 |
| listpack→quicklist | push 前 `quicklistNodeExceedsLimit`(t_list.c:40-55) | 整表一次搬移(原 listpack 直接变成第一个节点,数据不重排,t_list.c:50) |
| quicklist→listpack | 删除后且仅剩 1 个 PACKED 节点、低于半阈值(t_list.c:75-94) | O(1)——直接把 listpack 指针从节点里"摘"出来 |
| listpack→HT(hash) | field 数 >512 / 单值 >64B / lpSafeToAdd 失败(t_hash.c:604-622,888,922) | O(N) 全量重建 + dict 扩容;HMSET 大批量时先 dictExpand 预缩成本 |
| intset→listpack / HT(set) | 512 上限 / 出现非整数(t_set.c:160-209) | O(N);intset→listpack 需逐个重编码(整数→字符串) |
| HT→intset(set) | 全整数结果集重建(t_set.c:72-94) | O(N) 但方向是省内存 |
| listpack→skiplist(zset) | ZADD 前置检查(t_zset.c:1464-1468) | O(N logN):逐个 zslInsert + dictAdd;dictExpand 预扩(t_zset.c:1277) |
| skiplist→listpack(zset) | ZADD 后 `zsetConvertToListpackIfNeeded`(t_zset.c:1333-1343,仅 ZADD_INCR 路径等少量调用) | O(N) |
| listpack→listpack_ex(hash) | 首次字段级 HEXPIRE(t_hash.c:1147) | O(N):每个 field 后插入 NO_TTL 整数 |

三条共性规律:

1. **升级是单向高压线,但有例外**:绝大多数转换不可逆(避免抖动),例外是 list↔listpack 的半阈值滞回、set 的 HT→intset、zset 的 skiplist→listpack(受限调用)。
2. **转换都发生在写入路径**,读路径只按 encoding 分派,没有任何"读时升级"。分派本身是 switch 的 O(1),真正的读成本差异来自各编码的数据结构:同样是 HGET,listpack 是 O(N) 顺序扫,HT 是 O(1) 哈希;同样是 ZRANGEBYSCORE,listpack 从头线性找,skiplist 走 span 跳跃——阈值的意义正在于让"小数据付出顺序扫的小成本、大数据付出索引的小内存"。
3. **防御性守卫**:`lpSafeToAdd` 系列(t_hash.c:620、t_set.c:150、t_zset.c:1466)在 listpack 即将超限前就主动升级,避免 listpack 重分配时的内存峰值与碎片。

另有一条隐性成本容易被忽略:**转换是"整键级"的,不在命令的摊销范围内**。把一个 12 万元素的 listpack zset 转 skiplist,意味着 12 万次 zslInsert + dictAdd,全发生在触发阈值的那一条 ZADD 里——这也是生产上"大批量导入要用 ZADD 多参数一次喂入"的原因:ZADD 会把参数个数作为 size_hint 传给 `zsetTypeCreate`(t_zset.c:1841-1843),已存在的键也会经 `zsetTypeMaybeConvert(zobj, elements)` 提前升级并 `dictExpand` 预扩(t_zset.c:1846,1239-1245),从而避免逐条 ZADD 触发"中途昂贵转换 + 反复 rehash"。SADD 同理(t_set.c:599-602)。

---

## ④ 设计动机与取舍

1. **robj 是"类型系统 + 内存策略"的合体**:type 面向协议,encoding 面向内存;4bit encoding 意味着编码数量是稀缺资源——这也解释了为什么 ZIPMAP/LINKEDLIST/ZIPLIST 的编号被废弃却从不复用(兼容 RDB 编号)。
2. **紧凑编码(listpack/intset)的本质是缓存友好 + 消除指针开销**:N 个小元素用 dict 存需要 N 次分配 + 桶数组,listpack 只需一次连续分配。阈值(128/512/64B)都是在"顺序扫描仍够快"和"内存不再占优"之间的经验平衡点——listpack 查找是 O(N) 顺序扫,512 × 平均几十字节仍在 L1/L2 内。
3. **quicklist 的哲学:用分片把"大链表"变"短链表 + 小 listpack"**,两头兼顾:双向链表的 O(1) 端点操作 + listpack 的紧凑;fill 按字节(-2→8KB)让节点大小与元素大小解耦;PLAIN 节点兜底超大元素;compress-depth 把冷数据交给 LZF。它同时回答了"linkedlist 太碎、ziplist 整体更新太贵"两个老问题。
4. **zset 双结构是"以 1.5 倍内存买两种 O(1)/O(logN) 能力"**:dict 管"是什么",skiplist 管"排哪里",共享 SDS 与 `&node->score` 把重复开销压到极限。选 skiplist 而非平衡树:实现简单、无旋转、范围查询天然链表遍历、按概率分层便于并发扩展(虽然 Redis 单线程用不上)。
5. **stream 的 rax+listpack 是对"日志型数据"的特化**:ID 前缀高度共享使 radix 极省内存;宏节点把 XADD 摊销成 O(1) 追加;master entry/SAMEFIELDS 是数据域内的"列压缩"。PEL 用共享 NACK 指针横跨两个 rax,一致性靠"先插 group 后插 consumer,半插即 panic"(t_stream.c:1893-1896)。
6. **共享整数池(10000)是个被低估的优化**:计数器、限流、ID 类值大量落在 [0,10000),读路径零分配零缓存污染;代价是 shared 对象不能改 LRU/LFU,于是有了 `ForValue` 变体与 `MAXMEMORY_FLAG_NO_SHARED_INTEGERS` 的分支(object.c:386-393)。

---

## ⑤ 容易误解的点与面试级 FAQ

1. **Q: embstr 的 44 字节阈值指什么?为什么从 39 涨到 44?**
   A: 指字符串内容的字节数(≤44 转 embstr)。16(robj)+3(sdshdr8)+44+1('\0')=64,正好一个 jemalloc bin(object.c:323-329)。旧版 SDS 头是 8 字节 `{int len,int free}`,16+8+39+1=64,所以旧阈值 39;3.2 SDS 重构后头缩到 3 字节,阈值才升 44。
2. **Q: OBJ_ENCODING_INT 的对象,它的内存里存的是什么?**
   A: `o->ptr` 本身就是数值(强制转型),不指向任何分配内存(object.c:363-365)。因此 free 时无须释放 ptr(decrRefCount 对 STRING 只 free RAW 的 sds,object.c:516-520),GETRANGE 等命令需专门分支把它 ll2string 到栈缓冲(t_string.c:510-516)。
3. **Q: list-max-listpack-size 为负数是什么意思?默认 -2 是多大?**
   A: 负数表示按字节限制单节点 listpack:-1→4KB、-2→8KB、-3→16KB、-4→32KB、-5→64KB(quicklist.c:49,462-468);非负数表示按元素个数。默认 -2 即 8KB,而非"2 个元素"。
4. **Q: list-compress-depth 1 时,两端的节点也压缩吗?**
   A: 不。首尾各 N 个节点永远明文(quicklist.c:311-318 的 assert 与注释),且当总节点数 < compress*2 时干脆不压缩;访问中间节点会先解压、用完立即重压(recompress 位,quicklist.c:284-290)。
5. **Q: 128 个元素的 zset 一定是 listpack 吗?**
   A: 不一定。任一元素 >64 字节即转 skiplist(t_zset.c:1464-1466);而且从 listpack 转 skiplist 后基本不回退(仅个别路径调 `zsetConvertToListpackIfNeeded`)。反之 130 个元素的 zset 在"先大后删"的场景也可能长期是 skiplist——删除不触发降级。
6. **Q: zset 用 skiplist 而不用红黑树/平衡树,为什么?**
   A: 官方注释(t_zset.c:35-42)给出的差异是:允许重复 score、按(score,ele)二元组比较、第 0 层带 backward 指针。工程上 skiplist 无旋转、实现/调试简单、范围遍历就是链表遍历,且层高随机使插入无需 rebalance 语义。
7. **Q: ZSKIPLIST_P 为什么是 1/4 而不是 1/2?**
   A: 期望层高 1/(1-p):p=1/4 时约 1.33 层,节点平均只多 ~0.33 个指针;每跳期望跨 4 个节点。与 p=1/2 相比,同样的 O(log N) 渐近下,常数上更省内存(约省一半的层指针),查找多走一倍层数内的节点但整体缓存局部性更好。MAXLEVEL 32 对 2^64 元素绰绰有余(server.h:612)。
8. **Q: span 字段是干什么的?没有它会怎样?**
   A: span 记录该层 forward 指针跨过的节点数,使 ZRANK/ZRANGE BYRANK 能在下降过程中累加出目标秩(t_zset.c:493-514,517-534),O(log N);没有 span 就只能 O(N) 数节点。zslInsert 中对新节点两侧的 span 维护在 t_zset.c:156-168。
9. **Q: set 里放了一个字符串,原来全整数的 intset 会直接变 hashtable 吗?**
   A: 不会那么快。代码先估算当前整数集合放进 listpack 的尺寸,若 ≤128 个且最大元素 ≤64 字节,会先转成 **listpack** 再追加该字符串(t_set.c:176-201);放不下才转 HT。HT→intset 的"升级回紧凑"也存在(SINTERSTORE 等全整数结果,t_set.c:72-94)。
10. **Q: hash 的 512/64 阈值是"任一超"还是"全部超"?**
    A: 任一超即转:HSET 单条路径检查 field 与 value 的 sdslen 任一 >64(t_hash.c:886-890),条数检查是插入后 >512(t_hash.c:922-923);HMSET 批量路径还会用参数个数预判并 dictExpand(t_hash.c:603-607)。
11. **Q: 一个 stream 的 XLEN 会因为 XDEL 而变化吗?listpack 里的数据会移动吗?**
    A: XDEL 只把条目打上 DELETED 标志(墓碑),listpack 不搬移、rax 节点不回收(t_stream.c:17-19),XLEN 减一来自 `s->length` 计数;真正的空间回收由 XTRIM/MINID 或宏节点清空完成。
12. **Q: 共享整数(0-9999)会给业务带来什么坑?**
    A: 三个:① 所有键共享同一对象,OBJECT ENCODING 都是 int、refcount 是哨兵值;② 无法对单个键做 LRU/LFU 精确计量,所以启用相关淘汰策略时 INCR 类命令会绕开共享池(object.c:386-393);③ 对它做写操作必须先 unshare(如 SETRANGE),会产生一次隐藏拷贝。

---

## ⑥ 深挖问题清单(建议进阶调研)

1. **kvobj 迁移的收敛性**:本分支 `kvobjSet/ kvobjSetExpire`(object.c:259-321)会在设置 TTL 时 realloc 整个对象——在高 TTL 翻新率(SET+EXPIRE 组合)下,这次拷贝相比旧"db 里另存 expire 表"方案的性能盈亏点在哪里?`KEY_SIZE_TO_INCLUDE_EXPIRE_THRESHOLD 128`(object.c:26)的预埋策略覆盖多少流量?
2. **quicklist 分片与 DEL 大列表的摊销**:`listTypeTryConvertQuicklist` 只处理"单节点"降级,那么 10 万元素列表删到 100 个时,是否永远停留在"多个近乎空的 8KB 节点"?合并逻辑 `_quicklistNodeAllowMerge`(quicklist.c:535-550)的触发覆盖度需要实测。
3. **zslNthInRange 的 ZSKIPLIST_MAX_SEARCH=10 阈值**(server.h:614,t_zset.c:354-364):逐跳与 span 跳位的分界为何是 10?在深度分页(ZRANGEBYSCORE ... LIMIT 100000 10)场景下与旧实现(纯 span)的对比基准缺失。
4. **hash 字段级 TTL 的三态编码演进**:listpack→listpack_ex→HT(带 ebuckets)三次转换在"灰度放量 HEXPIRE"的集群里会造成什么形状的延迟毛刺?listpack_ex 的 ebuckets 与 HT 的 ebuckets 语义差异(t_hash.c:339-359)。
5. **stream 的 cgroups_ref 反查索引**(stream.h:24):新引入的"消息 ID→消费组"映射把 XADD 从 O(1) 变成了什么复杂度?`streamLinkCGroupToEntry`(stream.h:151)在多消费组场景下的内存放大系数需要量化。

---

### 附:本报告引用的源码文件

- src/server.h(robj/编码常量/zskiplist 结构/quicklist 结构经 quicklist.h)
- src/object.c、src/t_string.c、src/t_list.c、src/quicklist.c(+src/quicklist.h)
- src/t_hash.c、src/t_set.c、src/t_zset.c、src/t_stream.c(+src/stream.h)
- src/config.c(阈值配置项)、src/db.c(unshare 路径)、src/server.c(共享对象初始化)
