# O - BRIN 索引(块范围索引)深读

> 源码版本:PostgreSQL master,commit `8c7a74c`(shallow clone)。所有行号基于该 commit,仓库相对路径标注为 `文件:行号`。
> BRIN = Block Range Index(块范围索引)。官方 README:`src/backend/access/brin/README`(全文仅约 190 行,是理解 BRIN 的最佳入口)。

---

## 1. 全景:BRIN 的存储结构

BRIN 不存"每行一个索引项",而是**每 pages_per_range 个连续堆页存一条摘要元组**(默认 128 页,`src/include/access/brin.h:40`)。索引由三类页组成:元页、revmap(反向映射)页、regular(摘要)页。页类型标识存在页尾 special space(`src/include/access/brin_page.h:51-53`:0xF091 META / 0xF092 REVMAP / 0xF093 REGULAR)。

```
堆表(按块号物理连续)
 block 0..127     block 128..255    block 256..383
   [range 0]        [range 1]         [range 2]
      |                 |                 |
      |  revmap: 块号/128 -> 摘要TID 的定长数组(O(1)算术定位)      |
      v                 v                 v
+---------------- BRIN 索引文件 ----------------+
| blk 0      | blk 1 .. N   | blk N+1 ...      |
| 元页       | revmap 页     | regular 页       |
| magic/版本  | rm_tids[]     | BrinTuple 摘要   |
| pagesPerRange| 每项6字节TID  | (min,max,null位图)|
| lastRevmapPage| 指向摘要元组 | 按需扩展/迁移     |
+-----------------------------------------------+
        ^ revmap 项 (blk,off) 直接寻址 regular 页里的摘要元组
```

- 元页(`BrinMetaPageData`):`brinMagic`、`brinVersion`、`pagesPerRange`、`lastRevmapPage`,位于块 0(`src/include/access/brin_page.h:64-75`)。
- revmap 页:内容就是一整页定长 `ItemPointerData` 数组 `rm_tids[]`,最大项数 `REVMAP_PAGE_MAXITEMS`(`src/include/access/brin_page.h:78-94`;8kB 页约 8160B/6B ≈ 1360 项)。
- regular 页:普通 PageLayout 存放 `BrinTuple` 摘要;revmap 需要扩页时,占用该块号的 regular 页会被"疏散"到别处(`src/backend/access/brin/brin_pageops.c:521-620`)。
- AM 特征:无 amgettuple、只有 amgetbitmap;`amsummarizing = true`、`amcanunique = false`、`amcanmulticol = true`(`src/backend/access/brin/brin.c:254-313`)。

### BrinTuple:每 range 一条的摘要元组

摘要元组极简:4 字节 `bt_blkno`(对应堆起始块)+ 1 字节 `bt_info`(高位起:hasnulls/placeholder/empty_range + 5 位数据偏移),后接双倍长 NULL 位图与操作符类定义的 Datum 数组(`src/include/access/brin_tuple.h:63-93`)。

```c
// src/include/access/brin_tuple.h:63-78(节选)
typedef struct BrinTuple
{
    BlockNumber bt_blkno;   /* 该摘要覆盖的堆起始块号 */
    uint8       bt_info;    /* 7th:hasnulls 6th:placeholder 5th:empty 4-0:data offset */
} BrinTuple;
```

序列化时若任一列出现过 NULL,就写一张 **2 倍列数长度** 的位图:前半是 allnulls 位、后半是 hasnulls 位(`src/backend/access/brin/brin_tuple.c:270-279`);allnulls 列完全不存数据(`src/backend/access/brin/brin_tuple.c:144-152`)。内存态 `BrinMemTuple`/每列 `BrinValues` 与磁盘态通过 `brin_form_tuple` / `brin_deform_tuple` 互转(`src/backend/access/brin/brin_tuple.c:99,552`)。

---

## 2. revmap 专节:块号 → 摘要的 O(1) 反向映射

revmap 是 BRIN 的核心创新:因为摘要元组可能因变大而搬家,需要一个"哪个 range 的摘要在哪"的目录。由于每 range 恰好一个定长 TID 条目,定位只需两次除法/取模——**不需要任何树搜索**。

```c
// src/backend/access/brin/brin_revmap.c:40-43
#define HEAPBLK_TO_REVMAP_BLK(pagesPerRange, heapBlk) \
    ((heapBlk / pagesPerRange) / REVMAP_PAGE_MAXITEMS)
#define HEAPBLK_TO_REVMAP_INDEX(pagesPerRange, heapBlk) \
    ((heapBlk / pagesPerRange) % REVMAP_PAGE_MAXITEMS)
```

**物理布局**:revmap 紧跟元页,占据块 1..lastRevmapPage;块号 = 逻辑 revmap 页号 + 1(`src/backend/access/brin/brin_revmap.c:447,505`)。若目标 revmap 页尚未分配,返回 InvalidBlockNumber ⇒ 该 range 未摘要(`src/backend/access/brin/brin_revmap.c:441-454`)。

**读取路径** `brinGetTupleForHeapBlock`(`src/backend/access/brin/brin_revmap.c:193-313`):
1. 把堆块号归一化到 range 起点:`heapBlk = (heapBlk / pagesPerRange) * pagesPerRange`(:208);
2. 算出 revmap 页与槽位,读到 invalid TID 就返回 NULL(未摘要,:244-248);
3. 依 TID 读 regular 页,校验 `BRIN_IS_REGULAR_PAGE` 且 `tup->bt_blkno == heapBlk` 才返回(:278-303)——这是因为 revmap 扩展可能把 regular 页整体搬家;
4. 若并发期间 revmap 被改,循环重试;两次拿到相同 TID 会报"corrupted BRIN index: inconsistent range map"(:256-259)。

**写入路径**:插入/更新摘要时,先 `brinRevmapExtend`(不够长就物理扩展),再 `brinLockRevmapPageForUpdate` 排他锁住 revmap 页,最后 `brinSetHeapBlockItemptr` 按槽位直接改 TID(`src/backend/access/brin/brin_revmap.c:111-142,154-174`;WAL 重放也复用此函数)。

**扩页疏散**:revmap 物理扩展 `revmap_physical_extend`(`:521-645`)锁元页串行化并发扩展;若目标块被 regular 页占用,先 `brin_start_evacuating_page` 打上 `BRIN_EVACUATE_PAGE` 标志(`src/include/access/brin/brin_page.h:60`),`brin_evacuate_page` 把上面所有摘要迁走并改写各自 revmap 项(`src/backend/access/brin/brin_pageops.c:521-620`),然后才把该块初始化为 revmap 页(`:602-618`)。

**desummarize**:`brinRevmapDesummarizeRange` 把 revmap 项置 invalid 并删除摘要元组(`src/backend/access/brin/brin_revmap.c:322-434`,WAL 记录 XLOG_BRIN_DESUMMARIZE :409-425);SQL 入口 `brin_desummarize_range(regclass, bigint)`(`src/backend/access/brin/brin.c:1495-1580`)。

---

## 3. summarization 专节:摘要生成与"失真"

### 3.1 插入时的增量维护:brininsert

每次堆插入都会回调 `brininsert`(`src/backend/access/brin/brin.c:348-511`):定位 range → 取摘要 → `add_values_to_range` 逐列调 addValue 支持函数 → 若摘要被修改则 `brin_doupdate`。**没有摘要的 range 什么都不做**(:430-432)——这是 BRIN 写放大低的根源。

摘要"只扩不缩":minmax 的 addValue 只会把 min 调小、max 调大(`src/backend/access/brin/brin_minmax.c:94-122`)。所以:

- **更新/删除不会收紧摘要**:删除了 min 那一行,min 依旧留在摘要里(README `src/backend/access/brin/brin.c` 同目录 `README:108-114` 承认此优化未实现;`brinbulkdelete` 是纯 no-op,`src/backend/access/brin/brin.c:1307-1316`,注释 :1303-1305 提到"将来可给 brintuple 加 dirty 标志")。
- **乱序插入一个离群值就把区间撑爆**:README 之外,`brin_minmax_multi.c:12-26` 给了具体例子——[1000,2000] 插入 1000000 后变成 [1000,1000000],区间宽了 1000 倍,2001..999999 的查询全部失去剪枝能力。这正是 minmax-multi/bloom 操作符类出现的动机。
- 唯一的"重新收紧"手段是 desummarize 后重新 summarization(见 3.3)。

更新路径 `brin_doupdate`(`src/backend/access/brin/brin_pageops.c:52-316`):能塞下就同页覆写 `PageIndexTupleOverwrite`(:175-218);塞不下就写到新页、删除旧元组、**顺带把 revmap 项改指向新位置**(:228-315)。并发校验:旧元组内容若已变化则返回 false 让调用者重来(:151-164),`brininsert` 外层的 `for(;;)` 因此存在(:384-502)。

### 3.2 事后补摘要:全扫该 range

`brinsummarize(index, heapRel, pageRange, include_partial, ...)`(`src/backend/access/brin/brin.c:1888-1980`)线性走 revmap,凡 `brinGetTupleForHeapBlock` 返回 NULL 的 range 调 `summarize_range`(:1942-1954)。默认(VACUUM 路径)跳过表尾的 partial range(:1934-1936)。

`summarize_range`(`src/backend/access/brin/brin.c:1762-1875`)三步:
1. 先插一个 **placeholder 占位元组**(allnulls+empty_range 标志,`brin_form_placeholder_tuple`,`src/backend/access/brin/brin_tuple.c:387-427`),防止并发插入错过(:1775-1779);
2. `table_index_build_range_scan` **只扫这 pages_per_range 个堆块**(any-visible 模式,注释强调不能漏在途事务插入的元组,:1808-1821);
3. 循环 `brin_doupdate` 用扫描结果覆盖 placeholder;失败(被并发改过)就重读并 `union_tuples` 合并后重试(:1829-1872)。

这就是"摘要更新=全扫该 range"的含义:range 一旦漏摘,补摘要的代价是 O(pages_per_range × 每页行数),但**被 range 边界严格限定**,与表大小无关。并行建索引时 worker 不生成空 range,由 leader 用 `brin_fill_empty_ranges` 统一补齐空 range 摘要(`src/backend/access/brin/brin.c:3009-3034`;callback :1063-1099)。

### 3.3 入口与触发

| 入口 | 位置 | 说明 |
|---|---|---|
| VACUUM(末段 brinvacuumcleanup) | `brin.c:1322-1347` | `brin_vacuum_scan` 清页 + `brinsummarize(..., BRIN_ALL_BLOCKRANGES, include_partial=false)`(:1341) |
| SQL `brin_summarize_new_values(idx)` | `brin.c:1370-1378` | 等价于对 BRIN_ALL_BLOCKRANGES(=InvalidBlockNumber,`brin.c:213`)调 summarize_range |
| SQL `brin_summarize_range(idx, blkno)` | `brin.c:1385-1490` | autovacuum 后台工作项也走这里;要求表 owner 权限、ShareUpdateExclusive 锁(:1420,1445) |
| autosummarize 触发 | `brin.c:393-425` | 插入落在"新 range 的第一个块第一行"且前一 range 无摘要时,`AutoVacuumRequestWork(AVW_BRINSummarizeRange, ...)`(:413)请求 autovacuum 稍后执行 |
| autovacuum 执行工作项 | `src/backend/postmaster/autovacuum.c:2739-2743` | `DirectFunctionCall2(brin_summarize_range, ...)` |

autosummarization 的意义:追加型负载(时间序列)中,新 range 产生时旧 range 已"定型",此刻摘要最紧;若等 VACUUM 才补,期间该 range 对查询完全不可剪枝(bringetbitmap 对未摘要 range 只能整段放进位图,见第 5 节)。它以 reloption `autosummarize=on` 开启(`brin.c:1352-1364`;默认关,`src/include/access/brin.h:47-52`)。

---

## 4. 操作符类专节:summary 的四种形态

操作符类只需实现 4 个必选支持函数:opcinfo(1)/addValue(2)/consistent(3)/union(4)(`src/include/access/brin_internal.h:70-78`;README `src/backend/access/brin/README:26-47`)。

**minmax**(`src/backend/access/brin/brin_minmax.c`):每列存 2 个 Datum(min/max,`oi_nstored=2`,:46)。addValue 对新值做两次比较、必要时替换 min/max(:86-122);consistent 按 btree 策略号判断:`<`/`<=` 拿 min 比,`>`/`>=` 拿 max 比,`=` 要求 min<=key 且 max>=key(:158-198);union 取两摘要的更宽边界(:207-252)。策略函数经 `minmax_get_strategy_procinfo` 惰性查 pg_amop 并缓存(:260-314)。

**inclusion**(`src/backend/access/brin/brin_inclusion.c`):每列存 3 个 Datum(union、unmergeable、contains_empty,`oi_nstored=3`,:110),面向几何/网络类型等"可以合并的集合值"。addValue 依次:unmergeable 早退(:174-175)→ empty 标志(:182-192)→ 已包含则不加(:198-203)→ 不可合并则置 unmergeable 旗(:213-221)→ 否则 MERGE 进 union(:224-235)。语义是"range 摘要 ⊇ range 内所有值",对 box/range 类型天然贴合。

**minmax-multi**(`src/backend/access/brin/brin_minmax_multi.c`):摘要为**多个小区间列表**(内存态、磁盘序列化经 `bv_serialize` 回调,:2378-2486)。离群值单独成区间而不是撑大整个区间(:12-26);区间数超限时贪心合并"距离最近"的两项(需要 distance 支持函数,:34-51),上限由 `values_per_range` reloption 控制(默认 32,:29-31)。是对经典 minmax 失真问题的官方补丁。

**bloom**(`src/backend/access/brin/brin_bloom.c`):摘要为布隆过滤器(1 个 Datum,:463),只支持等值;先对值做类型哈希再二次入过滤器(:19-27),双哈希 h1+i*h2 方案(:39-46)。适合"无序但低基数?"场景——准确说是等值点查的 range 剪枝。

目录中的默认 opclass:`*_minmax_ops` 为各类型默认,`minmax_multi`/`bloom` 均为非默认可选项(`src/include/catalog/pg_opclass.dat:269` 起的 BRIN 段)。

---

## 5. 查询专节:bringetbitmap 的摘要过滤

BRIN 只有 amgetbitmap(`brin.c:301`),整表剪枝在 `bringetbitmap`(`src/backend/access/brin/brin.c:571-958`)一次完成:

1. 取堆表页数 nblocks 作为循环上界(:606-609);
2. 扫描键按属性拆箱:regular 键与 IS [NOT] NULL 键分开,consistent 函数惰性查(:636-725);
3. **顺序走 revmap**:`for (heapBlk = 0; heapBlk < nblocks; heapBlk += pagesPerRange)`(:745),每 range 取摘要、deform(:757-776);
4. 判定是否收下整个 range:
   - 无摘要(revmap 返回 NULL)⇒ **整个 range 无条件加入位图**(:770-773,注释:未摘要 range 必须全返回,否则漏行);
   - placeholder ⇒ 同样全收(:777-784);
   - 空 range 直接剪掉(:817-821);allnulls 遇 strict 运算符剪掉(:860-864);
   - 否则逐列调 consistent——支持多键一次传入的(fn_nargs>=4,如 minmax-multi)就批量,:883-893;否则逐键短路,:906-917;
5. 命中则把 range 内每一页 `tbm_add_page`(:929-943)。返回值是 `totalpages * 10` 的近似行数(:952-957,注释自认"只有页数近似,没有精确元组数")。

代价估计 `brincostestimate`(`src/backend/utils/adt/selfuncs.c:9128-9345`)完全围绕"物理相关性"建模:用 pg_statistic 的 correlation(`STATISTIC_KIND_CORRELATION`,:9263-9273)推 `estimatedRanges = minimalRanges / correlation`(:9297-9300)——**correlation 越接近 ±1,剪枝越狠,成本越低**;startup cost = 顺序读全部 revmap 页(:9320-9322),total cost 再加随机读其余索引页(:9329-9330)。

---

## 6. 与前作对照

**BRIN vs B-tree**(对照 `I-Btree索引.md`):
- 大小:B-tree 每行一个索引项、随行数增长;BRIN 每 128 页一条,1TB 表(约 1.3 亿页)按默认配置仅约 100 万条摘要、索引本身通常只有几十 MB——缩小约 5 个数量级。代价是**有损**:只能到页,必须走 BitmapHeapScan recheck(README:19-24)。
- 更新:B-tree 插入要沿树下行、可能分裂/写 WAL 放大;BRIN 插入多数情况是"比较后不动"或同页覆写摘要(`brin_doupdate`),没有逐行写。但 B-tree 摘要(键序)永不失真,BRIN 摘要会单调变宽。
- 排序:B-tree 天然支持 order by/unique;BRIN `amcanorder=false`、`amcanunique=false`(`brin.c:261-267`),只能当"粗筛器"。
- 适用:B-tree 看选择性,BRIN 看**物理相关性**:correlation≈0 时 planner 直接退化为全 range 命中(`selfuncs.c:9297-9298`)。

**BRIN vs GIN**(对照上一章):GIN 是倒排(值→行),为多值/全文/数组设计,有 pending list 累积写入;BRIN 是摘要(页区间→min/max),为巨型单值表设计,没有 pending list,写入几乎零成本。两者都只出位图,但 GIN 剪枝粒度是行,BRIN 是页区间。GIN 适合"找 few rows among many values",BRIN 适合"skip most pages of a huge table"。

**vs TimescaleDB 的分区剪枝(概念级)**:TimescaleDB 的 chunk 排除(chunk exclusion)在 hypertable 的 chunk 级别用 chunk 约束(通常是时间 min/max)做计划期/执行期剪枝;BRIN 把同样的思想下推到**物理块区间粒度**,且约束不是 DDL 声明而是从数据自动摘要而来。两者共享同一前提:数据按时间自然追加,物理顺序与键序一致。区别在粒度(chunk = 数十万页 vs BRIN range = 128 页)、元数据存放(目录表 vs 索引文件)与更新模型(chunk 冻结不再变 vs BRIN 摘要持续变宽)。

---

## 7. 设计动机

**为什么只适合自然有序列**:剪枝有效性 = 查询键与堆物理顺序的相关性。`bringetbitmap` 对每个 range 做 min/max 包含判断;若表内值与块号无关(随机主键、频繁更新),几乎每个 range 的 [min,max] 都覆盖查询值,位图≈全表,索引只剩开销。planner 用 correlation 量化这一点(`selfuncs.c:9188-9300`)。时间序列/只追加日志是最优场景:块号与时间戳同向单调,每个 range 的 [tmin,tmax] 窄而互不重叠。

**为什么摘要更新是"全扫该 range"**:摘要语义是聚合(min/max/union),无法从"删了一个值"做增量逆运算(min 被删后新 min 是次小值,必须重看全 range)。所以系统选择:删除不管(错误方向只会让摘要偏宽,不影响正确性),真正要收紧时 desummarize + 重新 summarization,而重新 summarization 天然就是"占位 + 重扫这 128 页 + 覆盖占位元组"(`summarize_range`,`brin.c:1762-1875`)。placeholder 元组保证扫描期间并发插入的值不会丢失(:1770-1779 的设计意图)。

**autosummarization 的意义**:追加负载下,表尾 range 未满不会摘要,而 VACUUM 周期可能远长于数据灌入周期;期间的查询对该 range 只能全扫。autosummarize 在"跨入新 range 第一行"这个精确时机把**刚封口的旧 range** 排队给 autovacuum(`brin.c:393-425`),以最低成本保住"最新数据也可剪枝"。它复用 autovacuum 的 `AutoVacuumRequestWork` 机制而非专用进程,失败(排队失败)仅 LOG 不阻断插入(:416-421)。

---

## 8. FAQ 素材与深挖线索

**FAQ(8-10 条)**:
1. BRIN 索引到底多小?默认 pages_per_range=128(`brin.h:40`),每 range 一条摘要元组;`brinGetStats` 返回 pagesPerRange 与 revmap 页数(`brin.c:1653-1668`)。
2. 为什么 BRIN 查询永远走 Bitmap Heap Scan?因为 amgettuple 为 NULL、只有 amgetbitmap(`brin.c:300-301`),结果是有损页位图,须 recheck。
3. 未摘要的 range 查询会漏数据吗?不会——bringetbitmap 把无摘要 range 全部收进位图(`brin.c:770-773`),正确性优先于性能。
4. UPDATE 会让摘要收紧吗?不会。bulkdelete 是 no-op(`brin.c:1307-1316`);摘要单调变宽,只增不减(minmax addValue :94-122)。
5. 删除 min/max 所在行后摘要失真怎么办?手动/重建:`brin_desummarize_range`(`brin.c:1495`)+ `brin_summarize_range`(`brin.c:1385`),或 REINDEX。
6. pages_per_range 怎么选?越小剪枝越细但索引越大(revmap 条目数 = 堆页数/pages_per_range);越大越省空间但区间越宽。README:164-175 讨论了变长 range 的未来方向。
7. 什么时候用 minmax_multi 替代 minmax?列有离群值、或更新在旧区间插入大值导致区间爆炸时(`brin_minmax_multi.c:12-26` 的 1000 倍区间例子)。
8. bloom opclass 能替代 b-tree 等值查询吗?只能做 range 级粗筛(可能误报、须 recheck),不支持唯一性,但支持无序列的等值剪枝(`brin_bloom.c:1-17`)。
9. autosummarize 为什么默认关闭?它把摘要代价从批量装载移到前台插入路径(触发判断在 brininsert 内),且依赖 autovacuum 可用(`brin.c:393-425`)。
10. BRIN 的 WAL 量如何?摘要不匹配才写;同页覆写 XLOG_BRIN_SAMEPAGE_UPDATE,搬家 XLOG_BRIN_UPDATE,扩展 revmap XLOG_BRIN_REVMAP_EXTEND(`brin_pageops.c:186-300`、`brin_revmap.c:622-638`)。

**深挖线索(3-5 条)**:
1. revmap 扩页时的 regular 页疏散协议(`brin_pageops.c:521-620` + `brin_revmap.c:588-596`):BRIN_EVACUATE_PAGE 标志如何阻止并发写入者继续用旧页,以及 `brinGetTupleForHeapBlock` 重试循环如何与之配合。
2. placeholder 元组的并发正确性:summarize_range 先插 placeholder 再扫堆的理由(`brin.c:1770-1779` 注释),以及 `bt_placeholder` 在 bringetbitmap 中"永远全收"的处理(`brin.c:777-784`)。
3. minmax-multi 的贪心区间合并算法与 distance 支持函数(`brin_minmax_multi.c:34-51` 起,实现约 2900 行,是 brin 目录最大的文件)。
4. 并行建索引:worker 把摘要写入 tuplesort 而非索引、leader 汇聚并补空 range(`brin.c:1050-1104,3009-3034`),以及 `brin.c:1170-1175` 关于 BRIN 内存需求远小于 btree 的 XXX 注释。
5. 代价模型与统计:`brincostestimate` 对 correlation 的取法(取各列 |correlation| 最大者,`selfuncs.c:9196-9280`)及其对"跨列混合查询"可能高估/低估的影响。

---

## 写作要点速查表

| 主题 | 位置 |
|---|---|
| AM 例程表(仅 amgetbitmap/amsummarizing) | src/backend/access/brin/brin.c:254-313 |
| 默认 pages_per_range=128 / reloptions | src/include/access/brin.h:40-52;brin.c:1352-1364 |
| 页类型 0xF091/92/93、元页结构 | src/include/access/brin_page.h:51-75 |
| revmap 定位宏(两次除法) | src/backend/access/brin/brin_revmap.c:40-43 |
| revmap 逻辑块号计算 | src/backend/access/brin/brin_revmap.c:441-454 |
| revmap 查摘要(重试+校验 bt_blkno) | src/backend/access/brin/brin_revmap.c:193-313 |
| revmap 扩页+疏散 | src/backend/access/brin/brin_revmap.c:521-645 |
| desummarize 置 invalid | src/backend/access/brin/brin_revmap.c:322-434 |
| BrinTuple/bt_info 位布局 | src/include/access/brin_tuple.h:63-93 |
| 摘要序列化(双倍 NULL 位图) | src/backend/access/brin/brin_tuple.c:270-279 |
| 插入维护 brininsert(autosummarize 触发 :393) | src/backend/access/brin/brin.c:348-511 |
| 摘要更新(同页/搬家+改 revmap) | src/backend/access/brin/brin_pageops.c:52-316 |
| add_values_to_range(逐列 addValue) | src/backend/access/brin/brin.c:2220-2312 |
| summarize_range(placeholder+扫range) | src/backend/access/brin/brin.c:1762-1875 |
| brinsummarize 找未摘要 range | src/backend/access/brin/brin.c:1888-1980 |
| VACUUM 入口(bulkdelete no-op :1307) | src/backend/access/brin/brin.c:1322-1347 |
| SQL 控制函数 summarize/desummarize | src/backend/access/brin/brin.c:1370-1580 |
| bringetbitmap 主循环(未摘要全收 :770) | src/backend/access/brin/brin.c:571-958 |
| minmax addValue/consistent | src/backend/access/brin/brin_minmax.c:63-201 |
| minmax-multi 动机(离群值例) | src/backend/access/brin/brin_minmax_multi.c:9-51 |
| inclusion 三 Datum 摘要 | src/backend/access/brin/brin_inclusion.c:93-238 |
| bloom 摘要动机 | src/backend/access/brin/brin_bloom.c:1-27 |
| 代价模型(correlation 驱动) | src/backend/utils/adt/selfuncs.c:9128-9330 |
| autovacuum 工作项执行 | src/backend/postmaster/autovacuum.c:2739-2743 |
