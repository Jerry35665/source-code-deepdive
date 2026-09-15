# 第 15 章 · GIN 索引:倒排索引的工程化

> 基线:commit `8c7a74c`。行号以 src/backend/access/gin/ 为准(README 必读)。GIN 是全文检索/数组/JSONB 的倒排索引——**唯一只支持位图扫描的索引**(amgetbitmap 无 amgettuple,ginget.c:1947-1957 的原因注释)。

## 15.0 全景:倒排结构与 pending list

```
metapage(blk0) + entry tree(key 的 B-tree,根 blk1)
  叶子 entry → posting list(内嵌 TID)/ posting tree(溢出树形)
pending list(fastupdate 暂存链表,ginfast.c:219 追加)
叶子 entry 的 t_tid 复用:posting list 存"偏移+TID 数";posting tree 存"根块号+魔数
GIN_TREE_POSTING"(README:149-199)——同一字段两种语义由魔数区分
```

**entry tree 永不删除 key**(词汇集变化慢,README:27-31),故叶子无独立 high key(最右 tuple 充当 :312-314)。TID 压缩:43 位整数(offset 11 位)取差值后 varbyte 编码,首 TID 明文(ginpostinglist.c:81,:115,:197)。

## 15.1 pending list:fastupdate 的代价模型

插入按 fastupdate 分叉(gininsert.c:892-905):on→ginHeapTupleFastCollect(:483)+ginHeapTupleFastInsert(ginfast.c:219)追加链表尾;off→每 key 一次 ginEntryInsert。**刷出触发**:`nPendingPages×GIN_PAGE_FREESIZE > gin_pending_list_limit×1024`(ginfast.c:458-460)——由**当前插入事务就地**调 ginInsertCleanup(:780),ConditionalLockPage 让位于并发清理者(:827),BuildAccumulator 按 key 聚合后逐 key 入主树(:929-936),先写主树后删 pending(崩溃重放幂等 :766-771)。**代价是 organic 的**:pending 刷出的延迟毛刺内生于是哪个 INSERT 撞上阈值。

**每个查询都要先线性扫 pending list**(gingetbitmap ginget.c:1928;:1835;顺序原因 :1947-1957)——pending 过大=查询变慢的直接原因(gin_pending_list_limit)。

## 15.2 查询:extractQuery 与 consistent

ginscan 的 extractQueryFn 7 参调用产出 queryValues/partial_matches/searchMode(:316-325):全文 tsquery、数组、trigram(LIKE 'abc%' 的前缀部分匹配 collectMatchBitmap :121/:193-198)各自实现;ginlogic.c 的 consistent 绑定(:226/:148):有原生 tri-consistent 用之,无则 shim 枚举 MAYBE 组合——**概率语义的接口化**。

## 15.3 VACUUM 与 B-tree 对照

ginbulkdelete **第一步强制清 pending**(:666);死 TID 过滤 ginvacuumitempointers(:48-84);posting tree 两阶段清理(:391/:471/:271,空页才删)。**VACUUM 不收缩 entry tree**(词汇集只增)。对照 B-tree:键类型(词元 vs 整行)、更新代价(GIN 需 pending 合并)、扫描(位图 vs 逐 tuple)、size(倒排 vs 序)——**全文检索选 GIN,唯一性选 B-tree**。

## 15.4 设计动机

1. **为什么只支持位图扫描**:倒排的自然输出是 TID 集合——位图与 merge 正是为此设计(与卷二 BRIN 的 amgetbitmap 同族);
2. **pending list 的经济学**:批量合并 vs 逐条插入的写放大差——fastupdate=ON 是默认,代价转嫁给查询(线性扫 pending);
3. **key 永不删除**:词汇集稳定的假设使 entry tree 免于收缩逻辑——假设破例时(高基数唯一词)GIN 膨胀;
4. **43 位 TID 压缩**:倒排的体积瓶颈是 TID 列表——差值+varbyte 是信息论的标准答案。

## 15.5 FAQ

**Q1:为什么我的 GIN 查询忽快忽慢?**
pending list 的存在:刷出后快,堆积时线性扫(:1947-1957)。gin_pending_list_limit 调优。

**Q2:GIN 插入慢的毛刺从哪来?**
撞上刷出阈值的 INSERT 就地清理(:458-460)——延迟毛刺内生于写入后端。

**Q3:GIN 能做唯一约束吗?**
不能:倒排无"每行一 entry"语义。

**Q4:LIKE '%abc%' 能走 GIN 吗?**
前缀 LIKE 'abc%' 走部分匹配(:121/:193-198);后缀/中缀需 pg_trgm。

**Q5:posting list 什么时候树化?**
放不下叶子时 createPostingTree(:309/:333):树化是不可逆的单向门。

**Q6:多列 GIN 的 key 是什么?**
(attnum,key) 复合(README:113-120):同词不同列是不同 key。

**Q7:NULL 与空数组进索引吗?**
三类占位 category(README:122-135):NULL/空/正常分开入 key。

**Q8:VACUUM 会收缩 entry tree 吗?**
不会(README 词汇集假设):只清死 TID posting——膨胀靠重建。

**Q9:fastupdate 关掉会怎样?**
每 key 即时入主树(:351):插入慢、查询零 pending 扫描——写读权衡。

**Q10:GIN 支持并行扫描吗?**
仅位图:amgetbitmap 无并行(与 B-tree 的并行不同,卷四 18 章)。

## 15.6 小结与深挖方向

本章结论:**GIN="entry tree+posting list/tree+pending list 缓冲+位图扫描"**;更新代价 organic 化是它最 controversial 的设计。深挖:

1. varbyte TID 压缩(:81-197)的解压吞吐;
2. pending 阈值(:458-460)与 autovacuum 频率的联动调优;
3. consistent 回调的 tri-state(:226/:148)在不同 opclass 的语义;
4. posting tree 的分裂策略(gindatapage.c:34 的 384B 段);
5. RUM 索引扩展(附加信息排序)与核心 GIN 的分工。

> 下一章:BRIN——极小的块范围索引。
