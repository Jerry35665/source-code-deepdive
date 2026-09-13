# N — 统计信息与 ANALYZE：规划器的"感官"是如何生产与消费的

> 基于 PostgreSQL master（commit `8c7a74c`）源码调研。前作 K 报告讲到选择率（selectivity）的
> 计算入口后"撞墙"——所有代价估算最终都要读 `pg_statistic`。本章把这条链补完：
> 统计如何被采样生产（ANALYZE）、如何存储（pg_statistic 双层结构）、如何被消费（selfuncs）、
> 如何触发（autovacuum）与失效。

## 1. 全景：生产 → 存储 → 消费

```
  生产端                      存储端                       消费端
┌──────────────────────┐  ┌────────────────────────┐  ┌──────────────────────────┐
│ ANALYZE  analyze.c   │  │ 系统目录                │  │ 规划器（K 报告的终点）    │
│                      │  │                        │  │ selfuncs.c               │
│ do_analyze_rel :307  │  │ pg_statistic           │  │                          │
│  ├ examine_attribute │  │  每列一行，5 个槽位     │  │ eqsel         :302       │
│  │   :1081 选列/派发  │  │  (stanullfrac/stadist  │  │ scalarineqsel :655       │
│  ├ acquire_sample_   │─▶│   + stakind1..5 数组)  │─▶│ var_eq_const  :370       │
│  │  rows :1266 采样  │  │  单列统计               │  │  (MCV查找+非MCV摊分)     │
│  ├ compute_scalar_   │  │                        │  │ ineq_histogram_select.   │
│  │  stats :2464      │  │ pg_statistic_ext_data  │  │  :1117 (直方图二分插值)  │
│  │  MCV/直方图/相关性 │  │  扩展统计(ndistinct/   │  │                          │
│  ├ update_attstats   │  │   依赖/多列MCV)        │  │ 扩展统计消费              │
│  │   :1717 写目录    │  │                        │  │ statext_clauselist_      │
│  └ BuildRelationExt  │  │ pg_class.reltuples     │  │  selectivity ext:2024    │
│     Statistics :112  │  │  (行数由采样外推)       │  │                          │
└──────────────────────┘  │ 脱敏出口 pg_stats :190  │  └──────────────────────────┘
                          └────────────────────────┘
  触发：autovacuum.c relation_needs_vacanalyze :379（死元组→vacuum；改动→analyze）
  计数：pgstat_relation.c :947 mod_since_analyze 累加；ANALYZE 后清零 :396
```

一条 SQL 的 `WHERE x = 5` 选择率，物理路径是：规划器经 syscache `STATRELATTINH`
（pg_statistic.h:145 定义，缓存 128 条）读出该列的 pg_statistic 元组（selfuncs.c:6072），
在 MCV 数组里找 5，找到则直接用采样频率；找不到则把"非 MCV 剩余份额"除以估计的
distinct 数。而这一切的源头，是 ANALYZE 的一次 300×target 行采样。

## 2. 采样专节：两阶段"块采样 × 蓄水池"

### 2.1 为什么既不全扫、也不纯随机

- **不全扫**：ANALYZE 是高昂的维护命令，大表全扫会挤占缓存与 I/O；而规划器只需要
  "统计上无偏"的样本，不需要精确值。
- **不逐行纯随机**：逐行跳随机页会打碎 I/O 局部性（每行一次随机读）。源码注释
  （analyze.c:1244-1257）给出的方案是两阶段同时进行：第一阶段随机选 targrows 个块，
  第二阶段在这些块内用 Vitter 算法蓄水池留行——**第一层保住 I/O 局部性**（读流走
  readstream 批量预读，analyze.c:1307），**第二层保住行级无偏**。代价是样本组合
  不完全均匀，大表上覆盖页数偏少，注释自嘲 "We can live with that for now"
  （analyze.c:1253-1257）。

### 2.2 阶段一：块级 —— Knuth Algorithm S（不是 Vitter）

块采样在 `src/backend/utils/misc/sampling.c`。因为表的总块数已知，可以直接用 Knuth 3.4.2
的 Algorithm S，而无需 Vitter 的更复杂版本（sampling.c:32-34）：

```c
/* sampling.c:38-55 */
BlockSampler_Init(BlockSampler bs, BlockNumber nblocks, int samplesize, uint32 randseed)
{
    bs->N = nblocks;            /* measured table size */
    bs->n = samplesize;
    bs->t = 0;                  /* blocks scanned so far */
    bs->m = 0;                  /* blocks selected so far */
    ...
    return Min(bs->n, bs->N);   /* 要读的块数 */
}
```

`BlockSampler_Next`（sampling.c:63-116）有一个漂亮的优化：朴素算法每个块要掷一次骰子
决定跳不跳；这里把连续跳过的块数合并成一次随机数——把 V（0~1 随机数）重解释为 0~p
区间内的均匀数，p 每跳一步按比例缩小（sampling.c:100-111）。analyze.c:1290-1291 用
全局随机种子初始化，1317 行的外层循环 `table_scan_analyze_next_block` 逐个消费选中的块。

### 2.3 阶段二：行级 —— Vitter Algorithm Z 蓄水池

行采样是经典的 reservoir sampling（Vitter 1985 论文的 Algorithm Z，sampling.c:119-124 给出
完整引用）。蓄水池的好处是**无需预知表的总行数**——ANALYZE 恰恰在采样前不知道行数：

```c
/* analyze.c:1335-1361（节选） */
if (numrows < targrows)
    rows[numrows++] = ExecCopySlotHeapTuple(slot);   /* 前 targrows 行直接入池 */
else
{
    if (rowstoskip < 0)
        rowstoskip = reservoir_get_next_S(&rstate, samplerows, targrows);
    if (rowstoskip <= 0)
    {
        int k = (int) (targrows * sampler_random_fract(&rstate.randstate));
        heap_freetuple(rows[k]);  rows[k] = ExecCopySlotHeapTuple(slot);
    }
    rowstoskip -= 1;
}
```

`reservoir_get_next_S`（sampling.c:147）按 Vitter 原文：t ≤ 22n 时用 Algorithm X 逐个
处理，t 更大后切换到 Algorithm Z（跳过数 S 用对数公式一次算出，避免每行一次随机数）。
analyze.c:1345 就是调用点。**两个算法在代码里分工明确：块级 Algorithm S（sampling.c），
行级 Algorithm Z（reservoir_\*，sampling.c:146 起）**——中文社区常混称"Vitter 算法 S/Z"，
准确说法是：块选择用 Knuth S，行选择用 Vitter Z（Algorithm X 是其小 t 时的前奏）。

### 2.4 采样行数怎么定：300 × target

`std_typanalyze`（analyze.c:1953）是所有标量类型的默认统计派发器：有"="和"<"算子走
`compute_scalar_stats`，只有"="走 `compute_distinct_stats`，都没有走 `compute_trivial_stats`
（analyze.c:1979-2017）。关键常数 300 来自一篇 SIGMOD 论文的定理推论
（analyze.c:1983-2002）：

```c
/* analyze.c:1992-2002（注释摘录 + 代码） */
/*   r = 4 * k * ln(2*n/gamma) / f^2      （直方条最大相对误差 f、错误概率 gamma）
 *   取 f = 0.5, gamma = 0.01, n = 10^6  =>  r = 305.82 * k               */
stats->minrows = 300 * stats->attstattarget;
```

即每列需要 300×直方条数 的样本才能保证直方条误差 ≤ 0.5（置信 99%），且这个数对表大小
不敏感（n=10^12 也只需 300k）。`default_statistics_target` 默认 100（analyze.c:71，
GUC 定义在 guc_parameters.dat:749-756，上限 `MAX_STATISTICS_TARGET` 10000，vacuum.h:358），
所以**默认每列采样目标 30000 行**。do_analyze_rel 取所有列（含索引列、扩展统计要求，
analyze.c:506-531）的最大值作为 targrows，下限 100 行（防 Vitter 算法溢出，analyze.c:502-503）。

采样结束后按物理位置排序（analyze.c:1383-1385，qsort by itempointer）——这个"物理有序"
是后面算相关性统计的前提。活/死行数按抽样块密度线性外推全表（analyze.c:1394-1398），
结果写入 pg_class.reltuples。

## 3. 统计量专节：五个数字和五个槽位

### 3.1 pg_statistic 的双层结构

`pg_statistic` 每列一行：固定头部 stanullfrac / stawidth / stadistinct +
**5 个槽位**（`STATISTIC_NUM_SLOTS = 5`，pg_statistic.h:131），每槽由
stakindN（槽位类型编号）、staopN、stacollN、stavaluesN（任意类型数组）、stanumbersN
组成。类型编号：1=MCV，2=直方图，3=相关性，4=MCELEM，5=元素计数直方图
（pg_statistic.h:194/214/226/255）。这个"kind+数组"的开放设计让每种类型的 typanalyze
函数可以自由定义自己的槽位语义（数组类型甚至可以不等于列类型）。

**双层结构指**：pg_statistic 本体 `REVOKE ALL ... FROM public`（system_views.sql:278），
普通用户不可读（stavalues 里就是真实数据，等于把表内容泄露给能读它的人）；对外只提供
`pg_stats` 视图（system_views.sql:190），把 stakind 数字翻译成可读列名
（most_common_vals、histogram_bounds、correlation……），且带双重脱敏条件
（system_views.sql:274-276）：

```sql
WHERE NOT attisdropped
  AND has_column_privilege(c.oid, a.attnum, 'select')          -- 列级 SELECT 权限
  AND (c.relrowsecurity = false OR NOT row_security_active(c.oid));  -- RLS 未激活
```

同一思想在规划器内部也有镜像：即使用户能执行查询，只要列不可读或有安全屏障，统计里的
值只允许喂给 **leakproof** 函数（`statistic_proc_security_check`，selfuncs.c:6685-6700，
核心是 `get_func_leakproof`）；这是防止"用恶意算子探测统计内容"侧信道的第一道闸。

### 3.2 MCV 与直方图的分工

`compute_scalar_stats`（analyze.c:2464）一次扫描算齐所有统计量。先把非空样本排序
（analyze.c:2575，排序比较器顺手用 tupnoLink 数组记住"与自己相等的最大 tupno"，
让去重不用再比一次，analyze.c:2586-2596）。然后：

- **nullfrac / 平均宽度**：直接计数（analyze.c:2644-2648）。
- **stadistinct（去重数）**：三种情形（analyze.c:2650-2711）——样本无重复则按唯一列记
  `-1×(1-nullfrac)`（负数表示"随表行数缩放的比例"）；样本中每个值都重复出现则按小基数
  枚举列直接记整数；否则用 Haas-Stokes 的 Duj1 估计器
  `n*d / (n - f1 + f1*n/N)`（f1=只出现一次的值的个数，analyze.c:2672-2700）。
  估计值超过总行数 10% 就转成负的比例形式（analyze.c:2719-2720）。
- **MCV**：排序时顺便维护前 num_mcv 高频值的 track 数组（analyze.c:2614-2636）。
  若 MCV 可"完整覆盖"列的全部取值（bool/枚举型小集合），全部保留
  （analyze.c:2738-2744）；否则用 `analyze_mcv_list`（analyze.c:3042）**从最不常见的
  候选开始裁剪**：保留条件是样本频率显著高于"若不进 MCV 它会被摊到的平均选择率"，
  显著性用超几何分布 2 个标准差 + 0.5 连续性校正（analyze.c:3127-3133）。
  最后写槽位 kind=1（analyze.c:2786-2792），频率存 stanumbers。
- **直方图**：**只覆盖 MCV 之外的长尾**——先把 MCV 对应的样本值从数组中"挖掉"
  （analyze.c:2830-2863），再等距取 num_hist 个边界（含最小最大值，
  analyze.c:2872-2898），写槽位 kind=2（analyze.c:2902-2906）。边界数最多
  num_bins+1（analyze.c:2806-2808），且要求 MCV 之外还有 ≥2 个 distinct 才建
  （否则直方图会塌缩成空或单点，analyze.c:2801-2809）。

**分工的意义**：高频值（如"状态=active"占 40%）在直方图里会把大量 bin 质量压在极少
几个点上，插值会严重失真；把 MCV 单列出来后，等值查询对高频值**精确读频率**
（不用插值），直方图只需对长尾近似。`var_eq_const` 与 `scalarineqsel` 的组合逻辑
（见第 5 节）正是围绕这个分工写的。
- **相关性**：样本按物理位置有序，i 是逻辑序号、tupno 是采样时的物理序号，
  `corr_xysum` 累加 i×tupno（analyze.c:2605），最后套简化后的相关系数公式
  （analyze.c:2937-2944，因为 x、y 都是 0..n-1，sum 和 sum² 都有闭式），
  写槽位 kind=3。这个 [-1,1] 的数字直接决定 K 报告里的索引扫描代价修正：
  corr≈±1 表示物理序与逻辑序一致，indexscan 顺序读，随机访问代价打折。

### 3.3 写入与行级计算插件机制

算完由 `update_attstats`（analyze.c:1717）写入 pg_statistic：5 个槽位的 stakind/staop/
stacoll/stanumbers/stavalues 逐个打包成 Datum 数组（analyze.c:1759-1814），按
`(starelid, staattnum, stainherit)` 三元组查旧行——有则更新、无则插入
（analyze.c:1817-1842）。类型可自带 typanalyze 函数替代 std_typanalyze
（analyze.c:1158-1162，如 tsvector、range 类型）；索引表达式列也走同一套统计
（compute_index_stats，analyze.c:876），让规划器能估计 `WHERE lower(name) = 'x'`。
ANALYZE 还会把采样外推的行数刷进 pg_class.reltuples（vac_update_relstats，analyze.c:654）。

## 4. 扩展统计专节：CREATE STATISTICS 三件套

单列统计的盲区是**列间相关性**：`WHERE a=1 AND b=2` 在 a、b 完全同涨同跌时，
 planners 用 `sel(a) × sel(b)` 会低估一个数量级。PG 10 引入扩展统计，代码在
`src/backend/statistics/`。构建入口 `BuildRelationExtStatistics`（extended_stats.c:112，
analyze.c:623 在主统计写完后调用），按统计对象的类型开关分别构建
（extended_stats.c:201-227）：

| 类型 | 代码 | 存什么 | 怎么用 |
|---|---|---|---|
| ndistinct | mvdistinct.c:85 `statext_ndistinct_build` | 每个列组合(≥2列)的去重数 | 防止 join/group-by 把组合 distinct 当独立相乘 |
| dependencies | dependencies.c:343 `statext_dependencies_build` | 函数依赖 a→b 及"度"（0~1） | 削弱独立假设的乘法 |
| mcv | mcv.c:178 `statext_mcv_build` | 多列组合值的频率清单 | 直接查组合频率 |

函数依赖的"度"计算很直观：把样本按前 k-1 列排序分组（dependencies.c:280-301），
组内最后一列取值唯一则整组算"支持"，出现不同值算"违反"，度 = 支持行数 / 总行数
（dependencies.c:322-323）。消费时按 `P(a,b) = f·P(a) + (1-f)·P(a)·P(b)` 组合
（dependencies.c:1333-1348），f 是依赖度——f=1 时退化为只用 P(a)，完全修正了独立性
假设。

扩展统计的采样行数可独立设置（`ComputeExtStatisticsRows`，extended_stats.c:297，
analyze.c:528 会取 max），存储走 `statext_store`（extended_stats.c:808）写
`pg_statistic_ext_data`，序列化成 bytea。消费入口 `statext_clauselist_selectivity`
（extended_stats.c:2024）：先试多列 MCV，剩余子句再用函数依赖修正
（extended_stats.c:2031-2057，注释解释了为何依赖放最后——MCV 更精确）。
`ndistinct` 的列组合是 2..n 的全组合枚举（mvdistinct.c:100）。
注意扩展统计**只支持等值类子句**（函数依赖对范围条件不生效），这是它与单列直方图的
互补边界。

## 5. 消费专节：selfuncs 如何读统计

K 报告讲了入口（`restriction_selectivity` 按 pg_proc.prosupport/内建函数派发），本章只看
统计的读法。统计元组的获取统一走 syscache（selfuncs.c:6072）：

```c
/* selfuncs.c:6072-6075 */
vardata->statsTuple = SearchSysCache3(STATRELATTINH,
                                      ObjectIdGetDatum(rte->relid),
                                      Int16GetDatum(var->varattno),
                                      BoolGetDatum(rte->inh));
```

### 5.1 eqsel：MCV 精确 + 非 MCV 摊分

`var_eq_const`（selfuncs.c:370）是最典型的消费路径：

1. 常量为 NULL 直接返回 0（严格算子恒假，selfuncs.c:383-384）；
2. 命中唯一索引或 DISTINCT 则 `1.0 / rel->tuples`（selfuncs.c:405-408）；
3. 从 pg_statistic 槽位 1 取出 MCV 值数组，**逐个调用真正的"="函数**比较常量
   （selfuncs.c:424-465）——命中则直接用该值的采样频率作选择率
   （selfuncs.c:472-478，"尽可能精确"）；
4. 不在 MCV 里：先算 `1 - sumcommon - nullfrac`（MCV 之外的剩余质量，
   selfuncs.c:487-492），再除以 `distinct - MCV 个数` 摊分
   （selfuncs.c:500-503），最后钳制到不超过最小的 MCV 频率
   （selfuncs.c:509-510）。

**无统计时的兜底**：`1 / DEFAULT_NUM_DISTINCT`（=200，selfuncs.h:52；
代码在 selfuncs.c:517-522）。范围条件的默认值 `DEFAULT_INEQ_SEL = 1/3`
（selfuncs.h:38，scalarineqsel 无统计路径 selfuncs.c:744-745），范围对
`DEFAULT_RANGE_INEQ_SEL = 0.005`，LIKE 默认 `DEFAULT_MATCH_SEL = 0.005`。

### 5.2 range：直方图二分插值

`scalarineqsel`（selfuncs.c:655）同样先做 MCV 部分：`mcv_selectivity` 把满足
`MCV op CONST` 的频率加总（selfuncs.c:757），同时累计 sumcommon。直方图部分
`ineq_histogram_selectivity`（selfuncs.c:1117）在 bin 边界上**二分查找**
（selfuncs.c:1187-1218）定位 CONST 所在 bin，边界外做线性插值。合并公式
（selfuncs.c:769-777）：

```
selec = (1 - nullfrac - sumcommon) × hist_selec
```

即"直方图只代表非 MCV 非空 population，按比例缩放"。一个精妙的补丁：二分碰到直方图
第一个/最后一个 bin 边界时，会尝试用**索引实时扫描出的当前 min/max** 替换它
（`get_actual_variable_range`，selfuncs.c:1160-1210）——缓解"最大值一直在增长、统计过时"
的经典误差（时序表按天查询的场景）。

### 5.3 LIKE/前缀

LIKE/正则的选择率在 `like_support.c`：先提取模式中的固定前缀
（pattern_fixed_prefix，like_support.c:632），前缀是精确串则退化为 eqsel
（like_support.c:648-654）；否则用直方图上逐 bin 应用前缀比较 + MCV 部分精确计算
（like_support.c:656-680）。对 `col LIKE 'abc%'`，等价于估计 `col >= 'abc' AND col < 'abd'`
的两个直方图插值之差——**这就是前缀匹配能吃上 btree 统计的原因**。

## 6. 触发与失效专节

### 6.1 autovacuum 的 analyze 分支（与 G 报告衔接）

autovacuum 对每张表调用 `relation_needs_vacanalyze`（autovacuum.c:379），一次判定同时
产生两个独立决策：**死元组触发 vacuum**、**数据变化触发 analyze**，阈值公式相同、
计数源不同（autovacuum.c:3238-3240 从统计系统读三组计数；autovacuum.c:3263-3269
套 `基础阈值 + 比例系数 × reltuples` 公式）：

```c
/* autovacuum.c:3287-3299（节选） */
/* Determine if this table needs analyze...  we don't analyze
 * TOAST tables and pg_statistic. */
if (relid != StatisticRelationId &&
    classForm->relkind != RELKIND_TOASTVALUE)
{
    scores->anl = (double) anltuples / Max(anlthresh, 1);
    scores->anl *= autovacuum_analyze_score_weight;
    scores->max = Max(scores->max, scores->anl);
    if (av_enabled && anltuples > anlthresh)
        *doanalyze = true;
}
```

`anltuples` 即 `mod_since_analyze`，由 pgstat 在事务提交时累加
（`tabentry->mod_since_analyze += changed_tuples`，pgstat_relation.c:947——
insert/update/delete 的"净改动行数"，与 vacuum 关心的 dead_tuples 是两条独立账本；
这就是 G 报告中 pg_stat_user_tables 里 `n_mod_since_analyze` 列的来源，
system_views.sql:736）。ANALYZE 完成后由 `pgstat_report_analyze` 清零
（pgstat_relation.c:396-401），且**只分析部分列时不清零**（analyze.c:703-708），
让 auto-analyze 后续接着干。死元组多但没改值（纯 delete）会触发 vacuum 却不触发
analyze——这正是两种触发器分开的意义。

### 6.2 陈旧性与失效

- **统计写入即普通目录更新**：update_attstats 走 CatalogTupleUpdate（analyze.c:1835），
  MVCC 提交后**跨会话立即可见**——下一个用新快照的查询就会读到新统计，无需任何
  "刷新统计"命令。
- **syscache 失效**：heap_update 会登记 CacheInvalidateHeapTuple（heapam.c:2205），
  STATRELATTINH 等相关 syscache 条目随提交广播失效，各会话下次查找即重读。
- **relcache 侧**：单列统计内容不进 relcache；但**扩展统计对象列表**缓存于 relcache
  （rd_statlist，rel.h:158），`RelationGetStatExtList`（relcache.c:4985）注释明确：
  shared cache inval 会作废旧列表并清 rd_statvalid，覆盖 CREATE/DROP STATISTICS
  （relcache.c:4968-4974）。DDL 经 SI 消息广播 relcache 失效，因此**"结构变化"跨会话
  即时生效，而"数据变化"只能等下一次 ANALYZE**——统计陈旧是常态，规划器按"近似值"
  使用它（第 8 节动机 4）。
- **重要反例**：统计更新**不会**使缓存的执行计划失效——plancache/generic plan 继续用
  旧统计算出的形状，直到其它原因触发重规划。这是"刚 ANALYZE 了为什么计划没变"的
  常见答案。

## 7. 与前作对照：各家"感官"的设计取舍

- **MySQL（InnoDB）**：统计由存储引擎持有，持久化程度可配
  （`innodb_stats_persistent`，默认存 `mysql.innodb_table_stats` / `innodb_index_stats`），
  采样由 `innodb_stats_persistent_sample_pages` 控制页数。差异：统计聚焦索引级
  cardinality，没有 per-column MCV/直方图体系，直方图是 8.0 后以
  `ANALYZE TABLE ... UPDATE HISTOGRAM` 的补充形式出现。
- **SQLite**：`PRAGMA optimize` / `ANALYZE` 只写 **sqlite_stat1**（可选 sqlite_stat4）
  一张小表：每行"表或索引名 + 平均每键行数"，stat4 才有样本向量，没有槽位体系——
  正好反衬 PostgreSQL 五槽位设计在"零维护成本"与"专业统计"之间的工程定位。
- **Git**：内容寻址 + 确定性操作，不存在"计划"，也就不需要代价模型和统计。
  没有不确定的查询计划，就没有统计的立足点——统计是**规划器的感官**这一比喻
  在此凸显。

## 8. 设计动机

1. **为什么采样要两阶段？** 单阶段行级蓄水池要逐行访问，I/O 局部性差；纯块采样则块内所有行进样本，样本间不独立。两阶段用"随机块 × 块内蓄水池"同时近似两个目标，代价只是"样本组合不完全均匀"的二阶误差（analyze.c:1253-1257 官方承认）。
2. **为什么 300×target 与表大小无关？** Chaudhuri-Motwani-Narasayya 的直方图采样定理里样本量只依赖 ln(n)（analyze.c:1992-1999 注释明说 "no real need to scale for n"）——亿级表和千行表用同一采样预算，这是统计"够用即可"哲学的定量依据。
3. **为什么 MCV 单列、直方图吃长尾？** 等值查询是最高频谓词，MCV 给精确频率；直方图等宽分桶在高频值处会失真。两者合起来，`x = c` 与 `x < c` 各取所长（selfuncs.c:769-777 的合并公式就是分工契约）；`analyze_mcv_list` 的显著性裁剪还保证"不值得单列的值不占槽位"。
4. **为什么统计不精确也要存？** 规划器比较的是**候选计划的相对代价**，系统性偏差在比较中大多抵消；±30% 的行数估计足以区分 seq scan 和 index scan，而得到它只需 3 万行采样——"花最小代价买最够用的信息"。
5. **为什么统计可脱敏（pg_stats 视图）？** stavalues 就是数据本身（MCV 存原值），能读它的人等于能"看到"表内容。视图层脱敏 + 规划器内 leakproof 检查（selfuncs.c:6693）双层防线，让"能优化查询"和"能读数据"两个权限解耦。
6. **为什么开放 stakind 槽位而不是固定列？** 槽位机制让类型作者（tsvector、range、数组）以插件方式贡献领域统计（MCELEM 等），selfuncs 按 kind 检索——目录结构定型至今不改 schema 就能扩展统计类型。

## 9. FAQ 素材

1. **ANALYZE 到底读多少行？** 每列目标 300×attstattarget（analyze.c:2002），全表取各列及扩展统计的最大值，下限 100 行（analyze.c:506）；默认 target=100 即 3 万行，与表大小无关。
2. **采样用的什么算法？** 块级 Knuth Algorithm S（sampling.c:38），行级 Vitter Algorithm Z 蓄水池（sampling.c:146，analyze.c:1345 调用）；两阶段同时进行。
3. **n_distinct 为什么有负数？** 负数表示"占表行数的比例"（随表增长），正数是绝对值（唯一列写 -1×(1-nullfrac)，analyze.c:2656）。
4. **correlation 对查询有什么用？** 物理行序与逻辑列序的相关系数（analyze.c:2943），决定索引扫描随机访问代价的折扣；±1 时索引扫描几乎顺序 I/O。
5. **为什么 ANALYZE 后计划没变？** 统计更新不失效已缓存的计划（第 6.2 节）；且采样有随机性，两次 ANALYZE 结果可能不同。
6. **pg_stats 和 pg_statistic 什么关系？** pg_stats 是脱敏视图：过滤列 SELECT 权限和 RLS（system_views.sql:274-276），pg_statistic 本体对 public 全部撤销（system_views.sql:278）。
7. **auto-analyze 何时触发？** `mod_since_analyze > analyze_threshold + analyze_scale_factor × reltuples`（autovacuum.c:3269,3297）；只分析部分列不清零计数（analyze.c:703-708）。
8. **扩展统计解决什么问题？** 列间相关性导致的独立性假设误差：函数依赖修正 `P(a,b)=f·P(a)+(1-f)·P(a)·P(b)`（dependencies.c:1337），多列 MCV 直接给组合频率。
9. **统计里会不会泄露数据？** 会（MCV 存原值），所以有 pg_stats 脱敏 + 规划器 leakproof 门禁（selfuncs.c:6685）双层控制。
10. **为什么 ANALYZE 也要采索引列？** 表达式索引谓词（`lower(x)='a'`）需要表达式上的统计才能估选择率（compute_index_stats，analyze.c:876）。

## 10. 深挖入口

1. `analyze_mcv_list` 的超几何置信区间裁剪（analyze.c:3042-3152）——样本频率多高才"显著"更常见，可对照理论复算。
2. `get_actual_variable_range`（selfuncs.c，ineq_histogram_selectivity 内调用）——用索引 min/max 修正陈旧直方图端点，"统计陈旧性"的运行时补丁。
3. 扩展 MCV 的构建算法（mcv.c:178 起，样本分组 + 组合频率估计 + prune），与单列 MCV 裁剪思想对比。
4. 统计目标覆盖链：列 attstattarget → 类型 typanalyze → `statext_compute_stattarget`（extended_stats.c:379）的优先级合并。
5. `vac_update_relstats`（vacuum.c）如何把外推 reltuples 写回 pg_class——行数本身也是统计，是 join 估算的基数起点。

## 附：写作要点速查表

| 主题 | 位置 | 要点 |
|---|---|---|
| 默认统计目标 | analyze.c:71; guc_parameters.dat:749 | boot=100；上限 10000（vacuum.h:358） |
| 300×target / targrows | analyze.c:1992-2002; 506-531 | minrows=300×target；下限 100，各列取 max |
| 两阶段采样 | analyze.c:1244-1257; 1266 | 块随机(Knuth S, sampling.c:38) × 行蓄水池(Vitter Z, sampling.c:146；调用 analyze.c:1345) |
| 行数外推 | analyze.c:1394-1398 | liverows/抽样块数 × totalblocks |
| scalar 派发 | analyze.c:1979-2017 | "=<"→scalar；仅"="→distinct；否则 trivial |
| 去重估计 | analyze.c:2672-2700 | Haas-Stokes Duj1：n*d/(n-f1+f1*n/N) |
| MCV/直方图/相关性 | analyze.c:2786; 2902; 2943 | MCV 裁剪见 3042（超几何 2σ+0.5）；直方图挖洞 2830-2898 |
| 写目录 | analyze.c:1717,1817-1842 | 按 (relid,attnum,inh) upsert pg_statistic |
| 扩展统计构建 | extended_stats.c:112,205-210 | ndistinct(mvdistinct.c:85)/依赖(dependencies.c:343)/MCV(mcv.c:178) |
| 依赖度与公式 | dependencies.c:322-323,1337 | 度=支持行/总行；P=f·P(a)+(1-f)·P(a)·P(b) |
| 扩展消费 | extended_stats.c:2024-2057 | 先多列 MCV，后函数依赖 |
| 统计获取 | selfuncs.c:6072 | SearchSysCache3(STATRELATTINH) |
| eqsel 主路径 | selfuncs.c:370,424-510 | MCV 命中即精确；否则 (1-sumcommon-nullfrac)/其余 distinct |
| 直方图插值 | selfuncs.c:1117,1187-1218 | 二分；端点实时修正 get_actual_variable_range |
| 默认选择率 | selfuncs.h:38-52 | 1/3、0.005、DEFAULT_NUM_DISTINCT=200 |
| LIKE 前缀 | like_support.c:632,648-654 | 固定前缀→eqsel；否则直方图逐 bin |
| 自动触发/计数 | autovacuum.c:3269,3287-3299; pgstat_relation.c:947,396-401 | mod_since_analyze > base+scale×reltuples；ANALYZE 全列后清零 |
| 脱敏与缓存 | system_views.sql:190,274-278; relcache.c:4968-4985; pg_statistic.h:131,145 | pg_stats 权限+RLS 过滤；rd_statlist relcache 失效；5 槽位 |
