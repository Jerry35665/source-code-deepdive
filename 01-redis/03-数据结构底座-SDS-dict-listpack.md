# 第 03 章 · 数据结构底座:SDS、dict、listpack 与朋友们

> 基线:commit `e8726d18`(2025-09-15)。行号均以该 commit 为准。

## 3.0 全景:六个结构,一层哲学

本章覆盖 Redis 全部"原始数据结构层"。上层五大类型(String/List/Hash/Set/ZSet,外加 Stream)全部由它们组合而成:

| 数据结构 | 源码文件 | 直接服务的上层对象 |
|---|---|---|
| SDS(动态字符串) | `src/sds.c`、`sds.h` | 一切键名、String 值(RAW/EMBSTR)、所有内部字符串载体 |
| dict(哈希表) | `src/dict.c`、`dict.h` | 全局键空间(kvstore 分片)、Hash/Set 大编码、ZSet 的 member→score 索引、expires |
| listpack(紧凑列表) | `src/listpack.c` | List(经 quicklist 节点)、Hash/Set/ZSet 小编码、Stream 节点内的消息块 |
| intset(整数集合) | `src/intset.c` | Set 的全整数小编码(server.h:1025) |
| ziplist(遗留) | `src/ziplist.c` | 仅存兼容用途,见 3.7 |
| rax(基数树) | `src/rax.c` | Stream 的消息 ID 索引、消费组与 PEL(t_stream.c:53、225、2765-2770) |

编码常量的权威定义在 server.h:1019-1031——注意 `OBJ_ENCODING_ZIPLIST` 的注释已是 *"No longer used: old list/hash/zset encoding"*。

先立起一个架构事实:**dict 是唯一的"重型"结构,其余五个都是为小数据量设计的紧凑编码**。Redis 的内存哲学 = 小对象用自描述紧凑字节流,过了阈值再切换到以指针和链式结构为主的通用结构。

## 3.1 SDS:藏在指针前面的 header

### 内存布局

`sds` 本身只是 `typedef char *sds`(sds.h:24),真正的 header 藏在指针**前面**,通过 `s[-1]` 处的 flags 字节低 3 位识别类型:

```
SDS 布局(以 sdshdr8 为例):

      +--------+--------+--------+--------------------------+----------+
      |  len   | alloc  | flags  |  buf[] 字符串数据          | '\0'     |
      |  1B    |  1B    |  1B    |  (alloc 不含 header 和 \0) |          |
      +--------+--------+--------+--------------------------+----------+
      ^                          ^
      | header (3B)              | s 指针指向 buf 首字节

各 header 大小(sdshdr5/8/16/32/64):1 / 3 / 5 / 9 / 17 字节
```

关键 inline 函数全在 sds.h:`sdslen()` 按 flags 分派取长(sds.h:73-86)、`sdsavail() = alloc - len`(sds.h:88-111)。

### 本世代的类型选择修正

`sdsReqType()` 的边界是这一版精心修正过的点(sds.c:33-43):TYPE_8 的上限不再是 255,而是 `255 - sizeof(sdshdr8) - 1 = 251`,即"header + 数据 + \0 不超过一个字节可表达的分配尺寸",否则 `alloc` 字段会被截断。配合 `adjustTypeIfNeeded()`(sds.c:75-83)在分配后利用 jemalloc 的 usable-size 语义二次上调类型——**旧版"按逻辑长度选型导致 alloc 失配"的缺陷已系统性修复**。类型要变时因为 header 尺寸改变**不能 realloc**,必须 malloc + memcpy + free(sds.c:296-318)。

### 关键操作

- **创建**:空串强制用 TYPE_8 而非 TYPE_5,注释直说"空串通常是为了 append 而创建,type 5 不擅长此道"(sds.c:102-104)——TYPE_5 不存 alloc,`sdsavail()` 恒为 0,接近弃子;
- **扩容**:经典翻倍策略,<1MB 翻倍、≥1MB 每次加 1MB(sds.c:280-285);另有 NonGreedy 变体"只涨到刚好够"(sds.c:332-334);jemalloc 下还会用 `je_nallocx` 预判新尺寸是否落在同一 size class,是则跳过 realloc(sds.c:389-396)——分配粒度感知的微观优化;
- **拼接** `sdscatlen`(sds.c:532-541):MakeRoomFor、memcpy、setlen 三步;返回新指针,旧指针作废——这是 SDS API 的统一约定,调用方必须用返回值覆盖旧引用;
- **裁剪** `sdstrim`(sds.c:781-794):memmove 搬保留段,**只改 len 不缩容**——省下的空间留给后续 append;
- **零拷贝读入**:调用方先 MakeRoomFor,把 `read()` 直接读进 sds 尾部,再 `sdsIncrLen` 补记长度(sds.c:457-507)。

SDS 相对 C 字符串的收益:O(1) 取长、二进制安全、扩容前检查杜绝溢出、末尾必有 `\0` 保持 C 兼容。代价是 header 在数据指针**前面**,首次访问多一次 cache miss——这正是 EMBSTR(≤44B 时 robj 与 SDS 同一块分配)存在的理由(→ 第 04 章)。

## 3.2 dict:双表渐进式 rehash

### 核心结构

```c
struct dict {
    dictType *type;
    dictEntry **ht_table[2];       /* 两张哈希表 */
    unsigned long ht_used[2];
    long rehashidx;                /* -1 = 未在 rehash */
    unsigned pauserehash : 15;
    signed char ht_size_exp[2];    /* 桶数 = 1 << exp */
    int16_t pauseAutoResize;
    void *metadata[];
};
```
(dict.h:122-137)

桶数用**指数**存储(8 字节省到 2 字节);`dictType` 是回调表,包括 `resizeAllowed` 钩子(允许本次扩容吗)与 rehashingStarted/Completed——kvstore 靠这些钩子把分片 dict 的元数据聚合起来(kvstore.c:247-249)。

两个省内存的细节:① `dictEntry` 是 24 字节三指针结构,值用 union 内联(dict.c:48-57);② Set 类 dict(`no_value=1`)在桶内唯一元素时**根本不分配 entry**,把 key 指针直接存进桶,用指针低 3 位打标记(dict.c:128-138)——"把元数据藏进对齐位"的极端做法。哈希函数是带 16 字节随机种子的 SipHash(dict.c:108-126),防哈希碰撞攻击。

### 扩缩容阈值

- **扩容**:平时负载因子 ≥1 即翻倍式扩;有 fork 子进程落盘时(AVOID)要 ≥4 才放行——降低写时复制期间内存翻倍的尖峰(`updateDictResizePolicy`,server.c);
- **缩容**:平时负载 ≤1/8(12.5%)缩到 used;AVOID 下要 ≤1/32(dict.c:1644-1701);
- 目标桶数一律向上取 2 的幂,下限 4 桶(dict.c:1727-1733)。

### 渐进式 rehash:一次完整的数值演算

以"4 桶扩到 8 桶"为主线:

1. **插入触发**:`used=4 ≥ size=4` 且 `resizeAllowed` 放行(dict.c:1749-1751);
2. **建新表**:8 桶挂 `ht_table[1]`,`rehashidx = 0`,触发 rehashingStarted 钩子(kvstore 把该 dict 挂入 rehashing 链表)(dict.c:265-271);
3. **每次读写顺迁一桶**:`dictRehash(d,n)` 每次迁 n 个**非空桶**,同时限制空桶访问数 `empty_visits = n*10`(dict.c:401)——这是"工作量上限"而非下限,防止稀疏表把单次调用拖死;命中查找还会**优先迁命中的那个桶**以利用 cache(dict.c:1715-1718);
4. **迁移单桶**:扩容路径对新表掩码**重算 hash**;缩容路径直接 `idx & mask1`,**不重算 hash**(dict.c:337-344)——2 的幂掩码的数学红利,迁移成本主要是链表指针搬运而非哈希计算;
5. **收尾**:ht[0] 清空后释放,ht[1] 挪到槽 0,`rehashidx = -1`(dict.c:375-389)。

进行中的读写协议:新键只进 ht[1](dict.c:542);查找先查 ht[0] 中 `idx >= rehashidx` 的桶(已迁移桶必为空),再查 ht[1](dict.c:781-803)。**任何时刻一个键只在一表。** 服务器空闲时由 cron 补刀:`kvstoreIncrementallyRehash` 按微秒预算调用 `dictRehashMicroseconds`(kvstore.c:632-651)。

**为什么渐进**:一次性迁移百万级 entry 会造成百毫秒级卡顿,单线程扛不起;摊到每次操作 + cron 时间片,代价是常态多一张表、每次读写最多两表查找。

## 3.3 专题:SCAN 的反向二进制迭代游标

这是 Redis 源码中最精巧的十行代码,值得逐位演算。

### 算法本体

`dictScan` 每步无状态:输入游标 `v`,输出下一个 `v`。核心三行(dict.c:1585-1592):

```c
v |= ~m0;          /* Set unmasked bits so incrementing the reversed
                    * cursor operates on the masked bits */
v = rev(v);
v++;
v = rev(v);
```

即"高位补 1 → 比特反转 → 加 1 → 再反转",等价于**一个从高位开始加 1 的反向二进制计数器**。设计动机(dict.c:1457-1523 的文件级注释,Pieter Noordhuis 设计):哈希表尺寸恒为 2 的幂,桶位置 = hash 的低 log2(size) 位;**小表扩到大表时,老桶元素只会迁移到"低 n 位相同、高位任填"的新桶族**。反向计数器优先穷举高位,保证已扫过的低 n 位组合永不再回头——扩容不漏;缩容时低位组合已全覆盖也不会重扫,但元素可能"汇聚"到已扫桶,因此**可能重复**。

### 演算一:单表 4 桶的完整序列

m0 = 0b11,手工按源码三行演算:

| 输入 v | `v \|= ~m0` 后(尾部) | rev 后(尾部) | +1 后 | 再 rev → 下一个 v | 本步访问桶 |
|---|---|---|---|---|---|
| 0 | …11111100 | 0x3FFF…FFFF | 0x4000…0000 | 0b10 = **2** | bucket 0 |
| 2 | …11111110 | 0x7FFF…FFFF | 0x8000…0000 | 0b01 = **1** | bucket 2 |
| 1 | …11111101 | 0xBFFF…FFFF | 0xC000…0000 | 0b11 = **3** | bucket 1 |
| 3 | 全 1 | 全 1 | 溢出归 0 | **0** → 终止 | bucket 3 |

序列 **0 → 2 → 1 → 3 → 0**:每桶恰好一次。"高位补 1"的作用:反转后补的 1 落在低位,加 1 的进位把整段 1 清零——效果就是"增量只作用在掩码位上"。

### 演算二:rehash 中双表(4→16 桶)

`dictScanDefrag` 保证先扫小表、再 **do-while 穷举大表中该游标的全部"高位扩展"**(dict.c:1607-1621):

```c
do {
    dictScanDefragBucket(d, fn, defragfns, privdata, &d->ht_table[htidx1][v & m1]);
    v |= ~m1;
    v = rev(v); v++; v = rev(v);
} while (v & (m0 ^ m1));
```

小表 4 桶(m0=0b11)、大表 16 桶(m1=0b1111),传入 v=0b01:小表访问 bucket 2;大表循环依次访问 **1(0001)、8(1000)、4(0100)、12(1100)**——正是低位模式 `01` 在 4 位掩码下的全部 4 个扩展。**双表场景被化归为单表:大表就是小表的"高位展开"。**

### 保证与代价

- **不漏**:扩容后已扫元素的低位模式永不再成为游标(dict.c:1478-1492);
- **可能重复**:缩容时元素汇聚到已扫桶(dict.c:1516-1517 注释明示);
- 官方保证:遍历开始到结束一直存在的元素**至少返回一次**;客户端负责去重;
- 命令层 `scanGenericCommand`(db.c:1454-1602)以 `count*10` 次桶迭代为上限防稀疏表空转;
- 分片层:kvstore 把 64 位游标拆成"高 48 位 dict 内游标 + 低 16 位 dict 序号"(kvstore.c:369-373),一个 SCAN 串行扫完多个分片。

**为什么"无状态"是卖点**:游标只是一个整数——客户端断线重连可续扫、多客户端可共享游标、服务端零迭代内存。对照有状态迭代器(要么暂停 rehash 占内存,要么靠指纹断言拒绝修改),SCAN 用"可能重复"换来这一切。这与 Redis 整体"把一致性责任从服务端挪到客户端"的取舍一脉相承。

## 3.4 listpack:无级联更新的紧凑列表

### entry 布局

```
listpack:
+--------------------+----------+---------+---------+-----+
| totalBytes (4B LE) | numele   | entry 0 | entry1… | 0xFF|
+--------------------+----------+---------+---------+-----+

单个 entry(信息在【自己的尾部】记录【自己的】长度):
+---------------------------+------------------+----------------------+
| encoding(1B 或 5B)        |    data          | backlen(1~5B 变长)   |
| 7bit uint / 6bit str /    | 整数直接内联      | 本 entry 总长 varint, |
| 13/16/24/32/64bit int /   |                  | 低位在前,最高位=续传  |
| 12bit str / 32bit str     |                  |                      |
+---------------------------+------------------+----------------------+
```

字符串编码三种:6bit(≤63B)、12bit(≤4095B)、32bit(listpack.c:39-50);整数编码六种,从 7bit(0-127)到 64bit,负数用偏移技巧(如 13bit 域 `[-4096, 4095]`,`v + 2^13` 存无符号,listpack.c:256-263)。

**backlen 是理解 listpack 的钥匙**:每个 entry 在**末尾**存放**自身总长**的变长整数(listpack.c:341-376)。反向遍历 `lpPrev` 就是回退后向前连续解码 backlen(listpack.c:505-514);正向 `lpSkip` 用编码长度 + backlen 字节数跳到下一个(listpack.c:475-480)。

### 为什么没有级联更新

ziplist 的 entry 在**头部**存"**前一个** entry 的长度"(prevlen):插入会改写后继 entry 的 prevlen,可能引发 1 字节→5 字节的连锁扩位,最坏整表连锁 O(N)(`__ziplistCascadeUpdate`,ziplist.c:730-804)。listpack 把"长度"移到 entry **尾部且描述自己**:任何修改只影响被操作的 entry,后继一个字节都不用动。`lpInsert`(listpack.c:950-1097)的全部工作就是:算新字节数、按需 realloc、一次 memmove 挪后缀、写新 entry、更新计数——**复杂度只与被移动的后缀有关,不存在连锁反应**。这是空间布局上的解耦:entry 之间从"互相依赖"变为"自包含"。

### 两个 8.x 世代细节

- `numele` 只有 16 位,元素数 ≥65535 时头字段写入 UNKNOWN(0xFFFF)(listpack.c:28),此后 `lpLength()` 退化为全表扫描(listpack.c:537-554)——多数资料仍按旧语义描述此处;
- 整数元素没有"原生字符串形态":`lpGet` 要么直接返回 int64,要么用调用方缓冲区 `intbuf` 格式化(listpack.c:556-580)。

## 3.5 intset 与 rax(概览)

**intset**:三字段头 + 紧密排列的整数数组,编码 16/32/64 位。插入超范围整数时**编码升级**,从后往前原地搬迁(新占位更大,从前往后写会覆盖未读数据;新值必在边界外,负数放开头、正数放结尾,intset.c:163-179)。**只升不降**:删除大数不降级,避免"降级-再升级"抖动。

**rax(基数树)**:服务 Stream——每个 stream 的消息按 ID 存在 rax 里,节点值是装着一串消息的 listpack;消费组与 PEL 也是 rax。raxNode 头 4 个位域(iskey/isnull/iscompr + 29 位 size);**压缩节点**(iscompr=1)把"单孩子链"折叠成一个节点、只留 1 个子指针(rax.h:62-77),使树高与键前缀长度解耦——stream ID 形如 `1735687200000-5`,前缀高度共享,百万消息的树可能只有数千节点。代价是插入命中压缩节点中部时要**节点分裂**(rax.c:530-560);删除走对称的"再压缩"路径(rax.c:1057-1085)。查找内核 `raxLowWalk` 对扇出节点线性扫字符表(注释明说线性扫实测优于二分,rax.c:452-455)。`raxSeek` 支持 `> >= < <= ^ $` 六种算子,直接支撑 XRANGE 的按 ID 范围查询。

## 3.6 ziplist:一份解剖标本(遗留)

布局 `zlbytes(4B) zltail(4B) zllen(2B) entry… zlend(1B)`(ziplist.c:14-36);entry 为 `<prevlen> <encoding> <entry-data>`,带 14bit **大端**字符串长度等历史包袱(ziplist.c:80-106)。文件尾保留了一段手工字节级示例(两个元素共 15 字节的十六进制逐字节讲解,ziplist.c:112-136),是理解该格式最直观的教材。

现状:`OBJ_ENCODING_ZIPLIST` 已无运行时使用者(server.h:1024);t_zset.c 里保留的 `zzl*` 前缀函数实际调用的已是 listpack API(t_zset.c:771-790)。唯一真实用途是**旧 RDB/RESTORE 载入时的完整性校验并转换成 listpack**(rdb.c:1744-1810)。listpack 正是 antirez 为消灭级联更新而写的后继(listpack.c:3-5)。

## 3.7 设计动机十条

1. **listpack 取代 ziplist的本质**:把"描述邻居"换成"描述自己",用反向遍历多一次变长解码,换"任何修改都无连锁反应";
2. **扩容负载 1 / 缩容 1/8**:桶只是 8 字节指针,负载 1 时每元素仅摊 8 字节,内存换 CPU;缩容阈值远离扩容阈值,避免抖动;
3. **渐进 rehash 的代价核算**:常态多一张表 + 读写最多两表查找,换写入延迟的确定性;
4. **TYPE_5 边缘化**:最省 2 字节但无 alloc,"空串"与"可能再长"两条路径都避开它;
5. **no_value 指针复用**:Set 编码下每元素省一个 24B dictEntry;
6. **intset 只升不降**:避免抖动;
7. **rax 压缩节点**:适合"前缀长、分叉少"的键空间,不做通用索引;
8. **kvstore 化的键空间**:8.x 把全局 dict 换成分片 kvstore,rehash 卡顿上限被结构性压低;
9. **SCAN 重复 vs 有状态迭代器**:服务端零内存、可中断续扫,重复交给客户端去重;
10. **整数编码分层哲学**:listpack 的 7/13/16/24/32/64 位与 intset 的 16/32/64 位同出一源——"真实数据里小整数占绝对多数,多一级编码档位就多省一批内存"。24bit 这种非原生宽度也毫不犹豫,因为解码只是一次移位拼接,而内存按字节计价。

## 3.8 FAQ

**Q1:SDS 追加一定翻倍吗?**
<1MB 翻倍,≥1MB 每次只多要 1MB(sds.c:280-285);jemalloc 下 realloc 前还会判断 size class 是否已最优以跳过调用(sds.c:389-396)。

**Q2:dict 负载因子到 1 才扩容,链表会不会很长?**
负载 1 是"平均每桶 1 个元素";SipHash + 随机种子保证分布,桶数组只是指针,每元素仅摊 8 字节桶开销。

**Q3:rehash 进行中,一个键在哪张表?**
rehashidx 之前的桶已全迁;查找 ht[0] 只查 `idx >= rehashidx`,ht[1] 全查;新插入永远进 ht[1]。任何时刻一键一表。

**Q4:SCAN 会漏键吗?会重复吗?**
对"全程存在"的键不漏(反向计数器的数学保证);重复可能发生(尤其缩容期间),客户端去重。

**Q5:SCAN COUNT=10 就是每次返回 10 个吗?**
COUNT 是"扫描桶数的建议",实际返回 0~N 个;命令层最多迭代 count*10 次桶就收手(db.c:1562)。

**Q6:listpack 怎么从后往前走?**
不是链表,是单块字节缓冲;靠每个 entry 尾部的 backlen 自解出"上一个 entry 从哪开始"。

**Q7:listpack 存了元素个数,为什么 lpLength 还可能 O(N)?**
numele 16 位,≥65535 时写入 UNKNOWN 并放弃维护,退化为全扫描。

**Q8:ziplist 级联更新最坏多糟?**
最坏一次插入引发整表逐项扩 prevlen,O(N) 搬移;工程上靠"尺寸接近 254 的 entry 概率低"止损,但无法根治——这正是换 listpack 的动机。

## 3.9 小结与深挖方向

本章的自包含结论:**Redis 的底座是"一个重型结构(dict)+ 一组紧凑编码(SDS/listpack/intset)+ 一个特化结构(rax)"**,所有内存效率来自"紧凑编码 + 阈值切换",所有延迟确定性来自"渐进式"(rehash 渐进、迁移摊销)。留下的深挖问题:

1. **kvstore 分片与 rehash 协调**:rehashing 链表与 `fwTree` 尺寸索引如何支撑 cron 预算分配(kvstore.c:632-651);
2. **dictEntry 指针低位标记 × active defrag**:`dictScanDefragBucket` 的 `plink` 回填协议与 `decodeMaskedPtr` 的交互;
3. **hash 字段级 TTL 的编码扩展**:`OBJ_ENCODING_LISTPACK_EX`(server.h:3449)如何把 ebuckets 挂进 listpack 元数据;
4. **sds 的 usable-size 耦合**:非 jemalloc 构建下 `adjustTypeIfNeeded` 的退化行为;
5. **rax 分裂/合并的均摊成本**:stream 顺序追加与随机 XRANGE 删除的实测开销曲线。

> 下一章上到类型层:五大类型如何在这些底座上做编码切换,44 字节、512、128 这些阈值从哪来。
