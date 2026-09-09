# B 篇 · Redis 底层数据结构子系统调研报告

> 系列第一卷《Redis》原始材料。基线:unstable 分支,commit `e8726d18`(2025-09-15),Redis 8.x 世代源码(`version.h` 为 255.255.255 开发标记)。所有结论均标注 `文件:行号`,行号对应该 commit 的源码。

---

## 1. 结构全景:六个结构分别服务谁

本报告覆盖的六个模块是 Redis 全部"原始数据结构层",上层五大类型(String/List/Hash/Set/ZSet,另有 Stream)全部由它们组合而成:

| 数据结构 | 源码文件 | 直接服务的上层对象 / 场景 |
|---|---|---|
| SDS(动态字符串) | `src/sds.c`、`src/sds.h` | 一切键名、String 值(RAW/EMBSTR 编码)、所有结构内部的字符串载体 |
| dict(哈希表) | `src/dict.c`、`src/dict.h` | 全局键空间(kvstore 内每个分片是一个 dict)、Hash/Set 的大编码、ZSet 的 member→score 索引、expires 过期字典 |
| listpack(紧凑列表) | `src/listpack.c` | List(经 quicklist 节点)、Hash/Set/ZSet 的小数据编码、Stream 中每个 radix 树节点内的一批消息 |
| intset(整数集合) | `src/intset.c` | Set 的全整数小编码(`OBJ_ENCODING_INTSET`,server.h:1025) |
| ziplist(遗留) | `src/ziplist.c` | 仅存留兼容用途,见 §7 |
| rax(基数树) | `src/rax.c` | Stream 的消息 ID 索引、消费组与 PEL(t_stream.c:53、225、2614、2765-2770) |

编码常量的权威定义在 server.h:1019-1031,注意 `OBJ_ENCODING_ZIPLIST` 的注释已是 *"No longer used: old list/hash/zset encoding"*。小编码到大数据结构的转换阈值由 config.c 控制:`hash-max-listpack-entries` 默认 512(config.c:3252)、`set-max-listpack-entries` 默认 128(config.c:3254)、`zset-max-listpack-value` 默认 64(config.c:3260)。

一个值得注意的架构事实:**dict 是唯一的"重型"结构,其余五个都是为小数据量设计的紧凑编码**。Redis 的内存效率哲学 = 小对象用自描述紧凑字节流,过了阈值再切换到以指针和链式结构为主的通用结构。

---

## 2. SDS:带 header 的二进制安全字符串

### 2.1 内存布局

`sds` 本身只是 `typedef char *sds`(sds.h:24),真正的 header 藏在指针**前面**,通过 `s[-1]` 处的 flags 字节低 3 位识别类型(sds.h:62-71)。五种 header 全部 `__attribute__((__packed__))`(sds.h:28-55):

```
SDS 一级布局(以 sdshdr8 为例):

      +--------+--------+--------+--------------------------+----------+
      |  len   | alloc  | flags  |  buf[] 字符串数据          | '\0'     |
      |  1B    |  1B    |  1B    |  (alloc 不含 header 和 \0) |          |
      +--------+--------+--------+--------------------------+----------+
      ^                          ^
      | header (3B)              | s 指针指向这里 (buf 首字节)

sdshdr5(仅文档化,实际空串也不会用它):
      +--------+-----------------+
      | flags  |      buf[]      |     flags: 高 5 位 = 长度, 低 3 位 = 类型
      +--------+-----------------+

各 header 大小(sdshdr5/8/16/32/64):1 / 3 / 5 / 9 / 17 字节
```

关键 inline 函数全部在 sds.h 内:`sdslen()` 按 flags 分派取 len(sds.h:73-86)、`sdsavail() = alloc - len`(sds.h:88-111)、`sdsalloc() = sdsavail() + sdslen()`(sds.h:160-175,即 alloc 语义)。

### 2.2 类型选择与"可用尺寸"修正

`sdsReqType()` 的边界是本版本一个精心修正过的点(sds.c:33-43):

```c
char sdsReqType(size_t string_size) {
    if (string_size < 1 << 5) return SDS_TYPE_5;
    if (string_size <= (1 << 8) - sizeof(struct sdshdr8) - 1) return SDS_TYPE_8;
    if (string_size <= (1 << 16) - sizeof(struct sdshdr16) - 1) return SDS_TYPE_16;
    ...
}
```

TYPE_8 的上限不是 255,而是 `255 - 3 - 1 = 251`,即"header + 数据 + \0 不超过一个字节可表达的分配尺寸",否则 `alloc` 字段会被截断。文件头注释(26-32 行)明确说明这是修复:过去只按逻辑长度选型,分配器返回更大缓冲时会造成 alloc 与实际尺寸失配。`adjustTypeIfNeeded()`(sds.c:75-83)在分配后利用 jemalloc 的 usable-size 语义(`s_malloc_usable` 返回真实可用字节数,sds.c:109-111)二次上调类型。分配器经 sdsalloc.h 映射到 zmalloc 全家(sdsalloc.h:21-31)。

### 2.3 关键操作逐段解读

**创建 `_sdsnewlen`**(sds.c:98-116):一个隐蔽细节——空字符串强制用 TYPE_8 而非 TYPE_5,注释直说"空串通常是为了 append 而创建,type 5 不擅长此道"(sds.c:102-104),因为 TYPE_5 不存 alloc、`sdsavail()` 恒为 0(sds.h:90-92)。`sdsnewplacement()` 是新抽出的 placement 构造函数(sds.c:132-186),供对象头内嵌 SDS(EMBSTR 风格)复用;String 的 EMBSTR 阈值 44 字节在 object.c:329。

**扩容 `_sdsMakeRoomFor`**(sds.c:264-323):空间足够直接返回(sds.c:274);greedy 模式下经典的翻倍策略——

```c
if (greedy == 1) {
    if (newlen < SDS_MAX_PREALLOC)
        newlen *= 2;
    else
        newlen += SDS_MAX_PREALLOC;
}
```
(sds.c:280-285,`SDS_MAX_PREALLOC = 1MB`,sds.h:17)

这里有个新版独有的分支:类型不变时走 `realloc`,类型要变时因为 header 尺寸改变**不能 realloc**,必须 malloc + memcpy + free(sds.c:296-318,注释"can't use realloc")。同时 `sdsMakeRoomForNonGreedy()`(sds.c:332-334)提供"只涨到刚好够"的变体,给确定不会再追加的调用方省内存。

**拼接 `sdscatlen`**(sds.c:532-541):标准三步——MakeRoomFor、memcpy、`sdssetlen` + 补 `\0`。返回新指针,旧指针作废,这是 SDS API 的统一约定。

**裁剪 `sdstrim`**(sds.c:781-794):两头双指针扫过 cset 字符集,`memmove` 把保留段搬回头部,只改 len 不缩容——省下的空间留给后续 append。

**收缩 `sdsResize` / `sdsRemoveFreeSpace`**(sds.c:342-426):`would_regrow=1` 时拒绝降级到 TYPE_5(sds.c:370-374);JEMALLOC 下先用 `je_nallocx` 预判新尺寸是否落在同一个 size class,若是则直接跳过 realloc(sds.c:389-396)——这是"分配粒度感知"的微观优化。

### 2.4 其他值得记录的操作

- **零拷贝追加模式**:`sdsIncrLen` 的注释给出标准范式——调用方先 `sdsMakeRoomFor` 腾空间,把 `read()` 直接读进 sds 尾部,再用 `sdsIncrLen(s, nread)` 补记长度(sds.c:457-507)。它同时维护 `\0` 和负增量右裁剪语义。
- **`sdsgrowzero`**(sds.c:514-525):把字符串"撑"到指定长度并全部填零,SETRANGE 位图式写入依赖它。
- **`sdscpylen`**(sds.c:561-570):覆盖式赋值,复用已有 alloc,不缩容—— SDS 作为可复用缓冲的另一半能力。
- **`sdscatfmt` vs `sdscatprintf`**(sds.c:656-672):前者手写解析 `%s %S %i %I %u %U` 子集,绕开 libc 的 vsnprintf,热路径(如生成协议响应)专用。
- **`sdssplitargs`/`sdssplitlen`**(sds.c:896、1054):引号转义感知的命令行切分,redis.conf 与 redis-cli 共用。

### 2.5 SDS 相对 C 字符串的收益

O(1) 取长度(header 存 len)、二进制安全(数据可含 `\0`,sds.c:90-97 注释)、扩容前主动检查杜绝缓冲区溢出、同时保留 C 字符串兼容(末尾必有 `\0`,可直接传给 `printf`/`strchr`)。代价是每次拼接返回新指针的"所有权转移"式 API 约定——调用方必须用返回值覆盖旧引用,否则在 realloc 后立即悬垂。

---

## 3. dict:双表渐进式 rehash 的链式哈希表

### 3.1 核心结构

```c
struct dict {
    dictType *type;
    dictEntry **ht_table[2];       /* 两张哈希表 */
    unsigned long ht_used[2];      /* 各自元素数 */
    long rehashidx;                /* -1 = 未在 rehash */
    unsigned pauserehash : 15;     /* 暂停 rehash 计数 */
    unsigned useStoredKeyApi : 1;
    signed char ht_size_exp[2];    /* 桶数 = 1 << exp,-1 表示空表 */
    int16_t pauseAutoResize;       /* 暂停自动扩缩容 */
    void *metadata[];
};
```
(dict.h:122-137)

桶数用**指数**存储(`signed char`,dict.h:134),8 字节省到 2 字节;`DICTHT_SIZE(exp)` 宏(dict.h:119-120)还原尺寸。`dictType` 是回调表(dict.h:53-117),包括 hashFunction、keyCompare、`resizeAllowed`(允许本次扩容吗,供主线程负载控制)、rehashingStarted/Completed 等钩子——kvstore 正是靠这些钩子把 16384 个分片 dict 的元数据聚合起来(kvstore.c:247-249)。

dictEntry 是三指针结构,值用 union 内联(dict.c:48-57),24 字节;Set 类 dict(`no_value=1`)更进一步:桶内唯一元素时**根本不分配 entry**,把 key 指针直接存进桶,用指针低 3 位打标记区分(dict.c:128-138 的 `ENTRY_PTR_NORMAL/IS_ODD_KEY/IS_EVEN_KEY` 与 dict.c:545-560 的插入逻辑)。哈希函数是带 16 字节随机种子的 SipHash(dict.c:108-126),防哈希碰撞攻击。

### 3.2 扩缩容触发阈值

三个全局开关(dict.c:44-45):

```c
static dictResizeEnable dict_can_resize = DICT_RESIZE_ENABLE;
static unsigned int dict_force_resize_ratio = 4;
#define HASHTABLE_MIN_FILL 8   /* dict.h:28,即 1/8 = 12.5% */
```

触发条件在 `dictExpandIfNeeded`(dict.c:1644-1668)与 `dictShrinkIfNeeded`(dict.c:1681-1701):

- **扩容**:ENABLE 下 `used >= size`(负载因子 1)即翻倍式扩容;AVOID 下要 `used >= 4*size` 才放行;FORBID 下不自动扩。
- **缩容**:ENABLE 下 `used * 8 <= size`(负载 ≤ 12.5%)缩到 `used`;AVOID 下要 `used * 32 <= size`(≤ 1/32)。
- 目标桶数一律向上取 2 的幂:`_dictNextExp` 用 `__builtin_clzl` 算指数,下限 4 桶(`DICT_HT_INITIAL_EXP = 2`,dict.h:171)(dict.c:1727-1733)。

`dict_can_resize` 的运行时切换由 `updateDictResizePolicy()` 驱动(server.c):有 fork 子进程在落盘时 AVOID、自己是 fork 子进程时 FORBID、平时 ENABLE——目的是降低写时复制(CoW)期间内存翻倍的尖峰。

### 3.3 rehash 状态机(简述,演算见 §5)

`_dictResize`(dict.c:231-296)分配新表挂到 `ht_table[1]` 并置 `rehashidx = 0`;若是首次初始化或空表则直接"完成"(把新表挪到槽 0,dict.c:276-287)。`dictRehash(d, n)`(dict.c:400-429)每次迁移 n 个**非空桶**,同时限制空桶访问数 `empty_visits = n*10`(dict.c:401)防止稀疏表把调用方拖死;单桶迁移在 `rehashEntriesInBucketAtIndex`(dict.c:329-372)——**扩容时对新表掩码重算 hash,缩容时直接 `idx & mask1` 即可,不重算 hash**(dict.c:337-344,2 的幂掩码的数学红利)。

rehash 进行中的读写协议:插入一律进 ht[1](dictInsertKeyAtLink,dict.c:542);查找先查 ht[0] 中 `idx >= rehashidx` 的桶(已迁移过的桶必然为空),再查 ht[1](dictFindLinkInternal,dict.c:781-803;dictGenericDelete,dict.c:639-663)。每一次增删改查都会顺手推一步 rehash(`_dictRehashStepIfNeeded`,dict.c:1711-1724,优先 rehash 命中的那个桶以利用 cache)。服务器空闲时由 cron 补刀:`kvstoreIncrementallyRehash` 按微秒预算调用 `dictRehashMicroseconds`(kvstore.c:632-651;server.c:1236-1243)。

### 3.4 随机采样与 RANDOMKEY

`dictGetSomeKeys`(dict.c:1290-1364)是 `RANDOMKEY`/`SRANDMEMBER` 底层:在大表掩码范围内随机起点线性游走,连续空桶超过阈值(≥5 且 >count)就换随机起点;桶内链表超过配额时用**蓄水池采样**继续走完链表,保证长链尾部元素也有公平概率入选(dict.c:1344-1355 注释)。取键前还会顺手按 count 推进 rehash 步数(dict.c:1300-1305)。公平版 `dictGetFairRandomKey` 在 rehash 时按两表 used 加权选表,修正"小表元素被过度抽中"的偏差。

### 3.5 迭代器与指纹

普通迭代器用 64 位"指纹"(表指针、尺寸、元素数 XOR 混合,dict.c:1110-1140)在释放时断言 dict 未被改动;安全迭代器则 `dictPauseRehashing`。`dictNext` 在 rehash 中会从 `rehashidx - 1` 开始扫 ht[0] 跳过已迁移桶,再续扫 ht[1](dict.c:1192-1205)。

---

## 4. listpack:无级联更新的紧凑列表

### 4.1 整体与 entry 布局

头部 6 字节(`LP_HDR_SIZE`,listpack.c:27):4 字节总字节数 + 2 字节元素数,后接若干 entry,以单字节 `0xFF` 结尾(listpack.c:76)。

```
listpack:
+--------------------+----------+---------+-------+---------+-----+
| totalBytes (4B LE) | numele   | entry 0 | entry1|  ...    | 0xFF|
|                    | (2B LE)  |         |       |         | EOF |
+--------------------+----------+---------+-------+---------+-----+

单个 entry(信息在【自己的尾部】记录【自己的】长度):
+---------------------------+------------------+----------------------+
| encoding(1B 或 5B)        |    data          | backlen(1~5B 变长)    |
| 7bit uint / 6bit str /    | 整数直接内联;     | 本 entry 总长的 varint,|
| 13/16/24/32/64bit int /   | 字符串前置长度     | 低位在前,最高位=续传   |
| 12bit str / 32bit str     |                  |                      |
+---------------------------+------------------+----------------------+
```

字符串编码三种(listpack.c:39-50、72-74):6bit(≤63B,1B 头)、12bit(≤4095B,2B 头)、32bit(5B 头)。整数编码六种,从 7bit(0-127,1B 总 entry 前缀)到 64bit(9B entry)(listpack.c:34-70);负数用偏移技巧编码,如 13bit 编码域 `[-4096, 4095]`,负值 `v + 2^13` 存无符号(listpack.c:256-263)。

**backlen** 是理解 listpack 的钥匙:每个 entry 在**末尾**存放**自身总长**的变长整数(`lpEncodeBacklen`,listpack.c:341-376),1~5 字节,7 位一组、高位组在前、低 7 位组把最高位置 1 当"继续读"标志。于是反向遍历 `lpPrev` 就是:回退 1 字节读到 backlen 的最后一个字节,向前连续解码(listpack.c:505-514);正向遍历 `lpSkip` 用当前 entry 的编码长度 + `lpEncodeBacklenBytes` 跳到下一个(listpack.c:475-480)。

### 4.2 为什么没有级联更新

ziplist 的 entry 在**头部**存"**前一个** entry 的长度"(prevlen),插入元素会改写后继 entry 的 prevlen,可能引发 1 字节 → 5 字节的连锁扩位,即级联更新(见 §7)。listpack 把"长度"移到 entry **尾部且描述自己**:任何一次插入/删除/替换只影响被操作的那个 entry,后继 entry 一个字节都不用动。`lpInsert`(listpack.c:950-1097)的全部工作就是:算出新字节数、按需 realloc(先扩后 memmove,先 memmove 后缩,listpack.c:1022-1043)、一次 memmove 挪动后缀、写入新 entry、更新头两个计数字段——**复杂度只与"被移动的后缀长度"有关,与 encoding 边界条件无关,不存在连锁反应**。

### 4.3 遍历、查找与批量接口

- `lpFind`(listpack.c:912 起)支持从任意 `p` 开始、带跳过个数(`skip`),内部比较经 `lpFindCb` 回调注入类型特定的等值判断(如 zset 的 member 比较),整数元素在比较前经 `lpGet` 的 intbuf 机制现转字符串——**listpack 中的整数元素没有"原生字符串形态"**,`lpGet(p,&count,intbuf)` 对整数编码要么直接返回 int64(传 NULL intbuf),要么用调用方缓冲区格式化后返回指针(listpack.c:556-580 注释)。
- 批量接口 `lpBatchInsert`/`lpBatchAppend`(listpack.c:1103、1288)把多次插入合并为一次 realloc + 一次 memmove,`LPUSH` 多元素与 RDB 载入路径受益。
- 头部插入有专门快捷路径 `lpPrepend`(listpack.c:1251):定位到首元素后仍走 `lpInsert(LP_BEFORE)`,省去的是调用方自己找指针的遍历。

### 4.4 两个 8.x 世代的细节

- 元素数上界:`numele` 只有 16 位,超过 65534 个元素时头字段写入 `LP_HDR_NUMELE_UNKNOWN (0xFFFF)`(listpack.c:28),此后 `lpLength()` 退化为全表扫描并尽量回填(listpack.c:537-554)。
- 安全上限:`LISTPACK_MAX_SAFETY_SIZE = 1GB`(listpack.c:123),`lpInsert` 里还有 `> UINT32_MAX` 即返回 NULL 的硬检查(listpack.c:1012)——4 字节 totalBytes 的必然约束。

---

## 5. 专题一:渐进式 rehash 全流程

以"键空间 dict 从 4 桶扩到 8 桶"为主线走一遍完整状态机(数字为演算虚构,机制完全按源码):

1. **插入触发**:`dictAddRaw → dictFindLinkForInsert → _dictExpandIfNeeded`(dict.c:1749-1751)。此时 used=4 ≥ size=4(dictExpandIfNeeded 判据,dict.c:1658-1659),且 `resizeAllowed` 钩子放行。
2. **建新表**:`_dictResize(d, 5)` → `_dictNextExp(5) = 3` → 新表 8 桶挂 ht[1],`rehashidx = 0`,触发 `rehashingStarted` 钩子(kvstore 把该 dict 挂入 rehashing 链表,kvstore.c:167-180)(dict.c:265-271)。
3. **从此每次读写顺迁一桶**:如 `dictFind` 命中 ht[0] 的 idx=6 且 ≥ rehashidx,则 `_dictRehashStepIfNeeded` 优先把**第 6 桶**整体迁走(cache 友好分支,dict.c:1715-1718);否则按 rehashidx 顺序迁。`dictRehash(d,1)` 遇到空桶最多连跳 10 个(dict.c:401、419-422)。
4. **迁移单桶**:`rehashEntriesInBucketAtIndex` 把该桶整条链搬到 ht[1];扩容路径 `h = dictHashKey(...) & mask1`,即**同一把 SipHash 的更多低位**(dict.c:337-338)。旧桶置 NULL,`rehashidx++`。
5. **收尾**:`ht_used[0] == 0` 时 `dictCheckRehashingCompleted` 释放 ht[0],把 ht[1] 挪到槽 0,`rehashidx = -1`,触发 `rehashingCompleted`(dict.c:375-389)。
6. **进行中的读写规则**:新键只进 ht[1](dict.c:542);查找/删除按 §3.3 的双表协议;`pauserehash > 0`(安全迭代器、SCAN 回调期间,dict.c:1578)时暂停。

**为什么渐进**:一次性迁移 N 百万个 entry 会造成毫秒-百毫秒级卡顿,Redis 单线程扛不起;把迁移摊到每次操作 + cron 时间片(`dictRehashMicroseconds` 每次 100 步为一批、按 `INCREMENTAL_REHASHING_THRESHOLD_US` 预算退出,kvstore.c:643-648)里,代价是平时多一张表、每个读写多一次双表查找。

**两个容易忽略的工程细节**:其一,`empty_visits = n*10`(dict.c:401)是"工作量上限"而非"下限"——rehash 一个非空桶的成本与链长成正比,不设空桶上限的话,一张 2^20 桶、只剩零星元素的表可能让单次调用跑很久;其二,缩容路径不重算哈希(dict.c:337-344),意味着**迁移成本主要是链表指针搬运而非哈希计算**,Redis 对此的利用是彻底的。

**缩容流程与扩容对称**:删除键后 `_dictShrinkIfNeeded`(dict.c:1703-1709)检查负载,`dictShrink` 目标桶数同样取 `1 << _dictNextExp(used)`(dict.c:319-325)。因此一个"先膨胀后清空"的键空间会经历多次逐级缩容;cron 的 `kvstoreTryResizeDicts` 每轮轮询若干分片补漏(server.c:1231-1232,kvstore.c:607-620),避免冷分片长期占着大表。

---

## 6. 专题二:SCAN 的反向二进制迭代游标(重点)

### 6.1 算法本体

`dictScan` 的每步调用是无状态的:输入游标 `v`,输出下一个 `v`。核心三行(dict.c:1585-1592):

```c
/* Set unmasked bits so incrementing the reversed cursor
 * operates on the masked bits */
v |= ~m0;

/* Increment the reverse cursor */
v = rev(v);
v++;
v = rev(v);
```

即"高位补 1 → 整体比特反转 → 加 1 → 再反转",等价于**一个从高位开始加 1 的反向二进制计数器**。`rev()` 是并行位反转(dict.c:1430-1438)。设计动机的完整推导写在 dictScan 的文件级注释里(dict.c:1457-1523,Pieter Noordhuis 设计):哈希表尺寸恒为 2 的幂,桶位置 = hash 的低 log2(size) 位;**从小表扩到大表时,老桶的元素只会迁移到"低 n 位相同、高位任填"的新桶族**。反向计数器优先穷举高位,保证已扫过的低 n 位组合永不再回头——扩容不用重启扫描;缩容时低位组合若已全覆盖也不会重扫(dict.c:1478-1498 注释)。

### 6.2 数值演算一:单表 4 桶的完整游标序列

取 64 位视角,m0 = 0b11。手工按源码三行演算(仅列低位):

| 输入 v | `v \|= ~m0` 后(尾部) | rev 后(尾部) | +1 后 | 再 rev → 下一个 v | 本步访问桶 |
|---|---|---|---|---|---|
| 0 | …11111100 | 0x3FFF…FFFF | 0x4000…0000 | 0b10 = **2** | bucket 0 |
| 2 | …11111110 | 0x7FFF…FFFF | 0x8000…0000 | 0b01 = **1** | bucket 2 |
| 1 | …11111101 | 0xBFFF…FFFF | 0xC000…0000 | 0b11 = **3** | bucket 1 |
| 3 | 全 1 | 全 1 | 溢出归 0 | **0** → 终止 | bucket 3 |

序列 **0 → 2 → 1 → 3 → 0**:每个桶恰好一次。注意"高位补 1"的作用:反转后这些补的 1 落在低位,加 1 的进位把整段 1 清零,效果就是"只反转的增量作用在掩码位上"。

### 6.3 数值演算二:rehash 中双表(扩容 4→16 桶)

`dictScanDefrag` 在 rehashing 时先保证 htidx0 是**小表**、htidx1 是大表(dict.c:1598-1602),先扫小表 `v & m0` 桶,然后 **do-while 穷举大表中该游标的全部"高位扩展"**(dict.c:1607-1621):

```c
do {
    dictScanDefragBucket(d, fn, defragfns, privdata, &d->ht_table[htidx1][v & m1]);
    v |= ~m1;
    v = rev(v); v++; v = rev(v);
    /* Continue while bits covered by mask difference is non-zero */
} while (v & (m0 ^ m1));
```

演算:小表 4 桶(m0=0b11),大表 16 桶(m1=0b1111),传入 v = 0b01:

- 小表:访问 bucket 01(2)。
- 大表循环:访问 0001(1);游标推进 0001→rev4→1000(+1 前后)…最终依次访问 **1、8(1000)、4(0100)、12(1100)**——正是低位模式 `01` 在 4 位掩码下的全部 4 个扩展;当 `v & (m0^m1) = 2 & 1100 = 0` 时退出。

这与 dict.c:1500-1507 注释的例子完全一致:"游标 101 配 16 桶大表,则同时测 (0)101 与 (1)101"。**双表场景被化归为单表场景:大表就是小表的"高位展开"**。

### 6.4 扩缩容时的保证与重复

- 扫过 bucket 1100(16 桶表)后表扩到 64 桶:这些元素的新位置只可能是 ??:1100(12/28/44/60),它们的低 4 位都是 1100——而反向计数器此后**永不产生**以 1100 结尾的游标,所以已扫过的元素挪了窝也不会再漏(dict.c:1478-1492)。相反方向的迁移(缩容 16→8 桶)元素会**汇聚**到已扫或未扫的桶,因此可能重复返回(dict.c:1494-1498、1516-1517)。
- 官方保证:遍历开始到结束一直存在的元素**至少返回一次**;可能返回多次,由客户端去重。
- 命令层:`scanGenericCommand`(db.c:1454-1602)以 `maxiterations = count*10` 防止稀疏表空转(db.c:1562),小编码对象(listpack/intset)一次返回全部、游标直接置 0(db.c:1521-1527 注释)。
- Cluster/分片层:kvstore 把 64 位 SCAN 游标拆成"高 48 位 dict 内游标 + 低 16 位 dict 序号"(kvstore.c:221-224、369-373、`getAndClearDictIndexFromCursor`),一个 SCAN 串行扫完多个分片 dict。

### 6.5 为什么"无状态"是这套设计的核心卖点

SCAN 游标只是一个整数,服务端不保存任何迭代上下文:客户端断线重连可以拿着旧游标继续、多个客户端可共享同一游标空间、服务端重启(前提是数据还在)也不影响游标语义。对照 §3.5 的 `dictIterator`,有状态迭代器要么暂停 rehash(占用内存),要么靠指纹断言拒绝修改(限制并发语义);SCAN 用"可能重复"换来了这三者。这个交换在 Redis 的使用模式下几乎总是划算的——SCAN 的典型消费方是增量统计、大 key 清理、迁移工具,都天然容忍重复。

命令层还有一处衔接值得注意:整棵键空间在 8.x 是 kvstore(每分片一个 dict),`kvstoreScan` 把 48 位 dict 内游标与 16 位分片序号拼成一个 64 位对外游标(kvstore.c:369-373),对客户端而言仍然是"一个整数走天下",分片调度被完全封装。

---

## 7. ziplist:遗留兼容(概览)

布局 `zlbytes(4B) zltail(4B) zllen(2B) entry… zlend(1B)`(ziplist.c:14-36)。zltail 存"最后一个 entry 的偏移",使 LPUSH/RPUSH 风格的双端弹出不必遍历;zllen 溢出 65534 后置 65535 表示"个数未知,需全扫"(ziplist.c:29-31)。entry 为 `<prevlen> <encoding> <entry-data>`:prevlen ≤ 253 用 1 字节,否则 `0xFE + 4 字节小端`(ziplist.c:55-69);编码字节与 listpack 思路同源但有 4bit 立即整数 `|1111xxxx|`(0-12 的立即数,值域 1-13,因为 0000/1111 被 EOF 与前缀占用)、14bit **大端**字符串长度等历史包袱(ziplist.c:80-106)。文件尾还保留了手工字节级示例(两个元素 "2" "5" 共 15 字节的十六进制逐字节讲解,ziplist.c:112-136),是理解该格式最直观的教材。

致命伤在 `__ziplistCascadeUpdate`(ziplist.c:730-804):插入后后继 entry 的 prevlen 可能从 1 字节撑到 5 字节,又使更后一个 entry 的 prevlen 撑大……最坏整表连锁,每次插入 O(N);源码还刻意**不做反向收缩**,防止"伸-缩-伸"抖动(ziplist.c:741-746)。

现状:ziplist.c 仍在编译(Makefile REDIS_SERVER_OBJ 含 ziplist.o),但 `OBJ_ENCODING_ZIPLIST` 已无运行时使用者(server.h:1024);t_zset.c 里保留的 `zzl*` 前缀函数实际调用的已是 `lpGetValue` 等 listpack API(t_zset.c:771-790)。唯一真实用途是**旧 RDB/RESTORE 载入时的完整性校验并转换成 listpack**(rdb.c:1744-1810 的 `ziplistPairsConvertAndValidateIntegrity`)。listpack 正是 antirez 为消灭级联更新而写的后继(文件头自指 listpack 规格,listpack.c:3-5)。

---

## 8. rax:基数树(概览)

rax 服务 Stream:每个 stream 的消息按 ID 存在一棵 rax 里,节点值是装着一串消息的 listpack;消费组字典与每组 PEL(待确认消息表)也都是 rax(t_stream.c:53、225、2765-2770)。

### 8.1 raxNode 布局与压缩

头 4 个位域:iskey/isnull/iscompr + 29 位 size(rax.h:54-60)。数据段布局(rax.h:62-77 注释):

```
非压缩节点(iscompr=0,size=3,扇出节点,字符在父节点的边上):
+--------+---------+--------+--------+--------+------------+------------+
| header |  'a' 'b' 'c'(pad) | a-ptr  | b-ptr  | c-ptr      | (value-ptr)|
|  4B    |  size 字节按字节对齐 |  子指针按 void* 对齐,字符-指针一一对应    |
+--------+-------------------+--------+--------+------------+------------+

压缩节点(iscompr=1,size=3,单链节点,整个字符串是通向唯一孩子的路径):
+--------+---------+-------+------------+------------+
| header | 'x' 'y' 'z'(pad) | z-ptr      | (value-ptr)|
+--------+-----------------+------------+------------+
  → 只有 1 个子指针,指向路径最后一个字符对应的节点
```

压缩节点把"单孩子链"折叠成一个节点(rax.h 顶部注释的 foo/foobar/footer 示例,rax.h:17-49),使树高与键前缀长度解耦;代价是插入命中压缩节点中部时要做**节点分裂**——rax.c 用 ANNIBALE/ANNIENTARE 的例子把分裂归纳为"插入一个双孩子非压缩节点 + 重建左右压缩段"(rax.c:530-560)。查找内核 `raxLowWalk`(rax.c:437-478)逐节点匹配,压缩节点逐字符比、非压缩节点线性扫字符表(注释明说线性扫实测优于二分,rax.c:452-455)。`raxSeek`(rax.c:1519+)支持 `> >= < <= ^ $` 六种定位算子,直接支撑 XRANGE/XREVRANGE 的按 ID 范围查询。树级 `rax` 结构只有 head/numele/numnodes 三个字段(rax.h:79-84)。

### 8.2 删除与再压缩

`raxRemove`(rax.c:1001-1090)展示了对称的另一半:删除叶子后沿父链回溯,把"非 key 且单孩子"的断链向上回收,直到遇到分叉节点或 key 节点(rax.c:1026-1039);随后若某节点降为单孩子非 key 状态,则把它的孩子链重新折叠成一个压缩节点(rax.c:1057-1085,trycompress 路径)。上游遍历依赖 `raxStack`(静态数组 32 项,溢出转堆,rax.c:67-120)保存父指针;OOM 时栈不完整会主动放弃再压缩以保证正确性优先(rax.c:1068-1070)。插入与删除都维持"压缩节点表示非分叉链"这一不变式,这正是 rax 内存开销逼近前缀共享理论下界的原因。

---

## 9. 设计动机与取舍

1. **listpack 取代 ziplist 的本质**:把"描述邻居"的 prevlen 换成"描述自己"的 backlen(§4.2),用"反向遍历多算一次变长解码"换来"任何修改都无连锁反应"。这是空间布局上的解耦:entry 之间从"互相依赖"变为"自包含"。
2. **dict 扩容阈值取负载 1、缩容取 1/8**:桶只是 8 字节指针,负载 1 时平均链长也只有 1,内存换 CPU;缩容到 1/8 才做,避免在阈值附近来回 rehash(抖动)。而 12.5%/32 分之一这些"奇怪"数字全来自 2 的幂约束。
3. **渐进式 rehash 的代价核算**:常态多 16 字节/桶 × 2 张表 + 每次查找最多两表;换来写入延迟的确定性。Redis 甚至允许 rehash 暂停(安全迭代器、`DEBUG` 场景,dict.h:192-194)与全量强制(`force_full_rehash` 标志,dict.h:89)。
4. **TYPE_5 的边缘化**:最省 2 字节,但无 alloc 字段导致 append 必扩容;于是"空串"和"可能再长"两个路径都避开它(sds.c:102-104、371-374)。它只剩"确定不再长的短只读串"这一个理论用途——工程上接近弃子。
5. **no_value 指针复用**:Set 编码下省一个 dictEntry(24B)/元素,靠指针对齐的低位冗余(分配器保证 8 字节对齐)打标(dict.c:128-138)。这是"把元数据藏进对齐位"的极端做法。
6. **intset 只升不降**:编码升级路径 int16→int32→int64 单向(intset.c:158-182);删除大数不降级,避免"降级-再升级"抖动,反正 set-max-intset-entries(默认 512 档位之外由配置控制)超限就转 dict。
7. **rax 的压缩节点**:stream ID 形如 `1735687200000-5`,前缀高度共享,压缩节点使一棵百万级消息的树可能只有数千个节点;但扇出节点 O(size) 线性查找限定了它适合"前缀长、分叉少"的键空间,不适合做通用索引。
8. **kvstore 化的键空间**:8.x 把全局 dict 换成分片 kvstore(非 cluster 模式也可能多分片),rehash 的影响被切到单分片粒度——底层结构未变,但"单次 rehash 卡顿上限"被结构性压低。
9. **SCAN 重复 vs 有状态迭代器**:无状态游标使服务端零内存、客户端可中断续扫,代价是重复元素交给调用方去重;这是一次典型的"把一致性责任从服务端挪到客户端"的取舍,与 Redis 整体(无事务回滚、弱一致持久化)一脉相承。
10. **整数编码的分层哲学**:listpack 的 7/13/16/24/32/64 位整数与 intset 的 16/32/64 位编码同出一源——"统计真实数据里小整数占绝对多数,多一级编码档位就多省一批内存"。24bit 这种非原生宽度也毫不犹豫地引入,因为解码只是一次移位拼接,而内存是按字节计价的。

---

## 10. 容易误解的点与面试级 FAQ

**Q1:SDS 一定比裸 C 字符串多一次内存访问吗?取长度呢?**
A:取长度 O(1),读 header 即可(sds.h:73-86),不需要 strlen 扫描;但 header 在数据指针**前面**,首次访问通常多一次 cache miss——这正是 EMBSTR(≤44B 时 robj 与 SDS 同一块分配,object.c:329)存在的理由。

**Q2:SDS 追加一定翻倍吗?**
A:greedy 路径:newlen < 1MB 翻倍,≥1MB 每次只多要 1MB(sds.c:280-285);且还有 NonGreedy 变体只涨到刚好(sds.c:332-334)。JEMALLOC 下 realloc 前还会用 je_nallocx 判断 size class 是否已最优以跳过调用(sds.c:389-396)。

**Q3:扩容时 SDS 的 header 类型会变吗?**
A:会。比如 251 字节的 TYPE_8 长到 300 就要变 TYPE_16;此时不能 realloc,必须 malloc+拷贝+free(sds.c:296-318)。新分配返回的 usable 更大时 `adjustTypeIfNeeded` 还会再上调类型(sds.c:75-83)。

**Q4:dict 负载因子到 1 才扩容,链表不是会很长吗?缩容阈值为什么是 12.5%?**
A:负载 1 是"平均每桶 1 个元素";链长只在该桶内冲突链上累积,且 SipHash + 随机种子保证分布。桶数组本身只是指针,负载 1 时每元素仅摊 8 字节桶开销,内存压力远小于"值 0.75 就扩"的通用哈希表。缩容线取 12.5%(`HASHTABLE_MIN_FILL = 8`,即"最小填充率 100/8",dict.h:28)同样是为了避开抖动区间;AVOID 模式下缩容强阈值再乘以 4 变成 1/32(dict.c:405-410、1691-1694)。

**Q5:rehash 进行中,一个键到底在哪张表?**
A:rehashidx 之前的桶已全迁到 ht[1];查找时 ht[0] 只查 idx ≥ rehashidx 的桶,ht[1] 全查(dict.c:781-784);新插入永远进 ht[1](dict.c:542)。所以任何时刻一个键只在一张表里。

**Q6:SCAN 会不会漏键?会不会重复?**
A:对"全程存在"的键不漏;重复可能发生(尤其缩容/迁移期间)。机制上反向二进制游标保证扩容不漏(§6.4),重复来自元素从"已扫区域"迁入"将扫区域"或双表遍历的交叠(dict.c:1516-1517 注释明示"possible some elements get returned multiple times")。

**Q7:SCAN COUNT=10 就是每次返回 10 个吗?**
A:COUNT 是"每次调用扫描的桶数建议",实际返回 0~N 个;命令层最多迭代 count*10 次桶就收手返回(db.c:1562、1602),所以稀疏表可能一次几乎不返回元素。

**Q8:listpack 是双向链表吗?怎么从后往前走?**
A:不是链表,是单块字节缓冲;反向遍历靠每个 entry 尾部的 backlen 自解出"上一个 entry 从哪开始"(listpack.c:505-514)。

**Q9:listpack 存了元素个数,为什么 lpLength 还可能 O(N)?**
A:numele 只有 16 位;元素数 ≥ 65535 时写入 UNKNOWN(0xFFFF)并放弃维护,lpLength 退化为全扫描(listpack.c:28、537-554)。8.x 之前是一直维护、溢出即停,语义有差异。

**Q10:intset 插入一个超范围整数为什么要"从后往前"搬迁?**
A:升级编码后每个元素占位变大,若从前向后写会覆盖未读的旧数据;从后往前原地展开不冲突,且新值必在边界外,用 prepend 标志把它放到开头(负数)或结尾(正数)(intset.c:163-179)。

**Q11:ziplist 的级联更新最坏有多糟?Redis 怎么止损?**
A:最坏一次插入引发整表逐项扩 prevlen,O(N) 搬移;工程上靠"entry 尺寸接近 254 的概率低"止损,但没法根治——这就是换 listpack 的动机(ziplist.c:730-746)。

**Q12:rax 压缩节点为什么只允许一个子指针?**
A:压缩节点代表"单孩子链"折叠,size 字节是路径字符串,最后一个字符才需要指向真实孩子(rax.h:62-71);这使节点大小公式里指针数与字符串长度解耦(`raxNodeCurrentLength`,rax.c:150-155),是压缩收益的来源,代价是插入可能分裂节点(rax.c:530-560)。

---

## 11. 深挖问题清单(后续章节可展开)

1. **kvstore 分片与 rehash 协调**:rehashing 链表、`fwTree` 尺寸索引(kvstore.c:263、632-651)如何支撑 `INFO` 的 `overhead_hashtable_rehashing` 与 cron 预算分配;cluster 模式下 16384 分片 vs 非 cluster 默认分片数的差异对 SCAN 游标空间(16 位 dict 序号)的挤占。
2. **dictEntry 指针低位标记 × active defrag**:`dictScanDefragBucket` 里 `plink` 的回填协议(dict.c:1536-1555)与 `decodeMaskedPtr` 的交互——defrag 搬移 entry 时如何保证 no_value 编码的桶首指针一致。
3. **OBJ_ENCODING_LISTPACK_EX 与 hash 字段级 TTL**:server.h:3449 起的扩展编码如何把 ebuckets/fwtree 挂进 listpack 元数据,是否会侵蚀 backlen 的"自描述"性质。
4. **sds 的 usable-size 耦合**:`s_malloc_usable` 依赖分配器(仅 jemalloc 精确),libc/tcmalloc 下 `adjustTypeIfNeeded` 的行为与 `alloc` 字段可信度;`sdsResize` 中 `je_nallocx` 直调对非 jemalloc 构建的退化路径。
5. **rax 分裂/合并的均摊成本**:stream 顺序追加(几乎全是压缩节点尾部插入)与随机 XRANGE 删除(触发链合并)的实测开销曲线;`RAX_STACK_STATIC_ITEMS` 静态栈深度阈值的影响。

---

*报告完。所有行号基于 commit e8726d18;`sds.c`、`dict.c` 全文精读,`listpack.c`/`intset.c`/`ziplist.c`/`rax.c` 按关键路径精读+全文浏览,`db.c`/`kvstore.c`/`server.c`/`t_zset.c`/`t_stream.c`/`object.c`/`rdb.c` 仅取交叉引用点。*
