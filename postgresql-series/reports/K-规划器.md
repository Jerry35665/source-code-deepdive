# K - PostgreSQL 查询规划器：从关系代数到代价最优计划树

> 源码版本：PostgreSQL master, commit `8c7a74c`（8c7a74c3239ce29940582643533a190721b395c0）。
> 所有行号均为该 commit 下仓库相对路径的实际核对结果。
> 前作衔接：卷二 08 章（H-执行器）讲的是火山模型如何"跑"计划树；本章讲计划树是"怎么来的"。

---

## 1. 全景：从 SQL 到计划树的流水线

```
 SQL 文本
   │  解析        flex/bison → 原始语法树
   ▼
 ParseTree
   │  分析        parse/analyze.c → 查询树 Query（名字解析、类型定型）
   ▼
 Query（关系代数树）
   │  重写        rewrite/rewriteHandler.c（视图展开、规则）
   ▼
 Query（规范化）
   │  规划  ◄──────────────────── 本章
   │     planner()                       src/backend/optimizer/plan/planner.c:328
   │      └─ standard_planner()                 planner.c:346
   │          └─ subquery_planner()（子查询逐层递归） planner.c:770
   │              ├─ 预处理：CTE 物化 SS_process_ctes()   planner.c:843
   │              ├─ grouping_planner()（GROUP/LIMIT/窗口）planner.c:1692
   │              │    └─ query_planner()               plan/planmain.c:54
   │              │         ├─ join 简化 restart 循环     planmain.c:78,285,300
   │              │         ├─ make_one_rel()           path/allpaths.c:183
   │              │         │    ├─ set_base_rel_pathlists（扫描路径） allpaths.c:384
   │              │         │    └─ make_rel_from_joinlist（join 搜索） allpaths.c:3837
   │              │         └─ 返回最终 RelOptInfo（内含"好路径集合"）
   │              └─ create_plan()：Path 树 → Plan 树      planner.c:539
   ▼
 PlannedStmt（含 Plan 树）
   │  执行  ◄──────── 卷二 08 章：火山模型逐算子拉取元组
   ▼
 Executor
```

规划器面前有两个自由度，其余问题都已被前几层消化：

1. **join 顺序**：N 张表有 N! 种两两结合的顺序（还有内/外交换）；这是规划复杂度的主战场，动态规划与 GEQO 都为此而生（`src/backend/optimizer/path/allpaths.c:3837` 的 `make_rel_from_joinlist`）。
2. **每个关系的访问方法**：顺序扫描、索引扫描、位图扫描、参数化扫描、并行扫描……由 `set_rel_pathlist` 按关系类型分发（`src/backend/optimizer/path/allpaths.c:520`）。

规划器的产出不是单一的 Plan 树，而是每个 RelOptInfo 上挂着的**候选路径集合**；只有最后一步 `create_plan`（`planner.c:539`，入口前先 `get_cheapest_fractional_path`，`planner.c:537`）才把最优路径"实体化"为 Plan 树，再经 `set_plan_references` 做变量重定位（`planner.c:643`）。

---

## 2. Path 与 RelOptInfo：规划器的中间层

### 2.1 Path 结构：代价五元组

Plan 树一旦生成就基本不可改；规划器在"生米煮成熟饭"之前用更轻量的 **Path**（路径）节点做穷举比较。`Path` 的核心字段（`src/include/nodes/pathnodes.h:1964`）：

```c
typedef struct Path
{
    NodeTag     type;
    NodeTag     pathtype;         /* 对应的扫描/join 方法 (pathnodes.h:1971) */
    RelOptInfo *parent;           /* 这条路径构建哪个关系 */
    PathTarget *pathtarget;       /* 输出表达式列表 + 代价 + 宽度 */
    ParamPathInfo *param_info;    /* 参数化信息，NULL=非参数化 (pathnodes.h:1995) */
    bool        parallel_aware;   /* ...并行三兄弟 (pathnodes.h:1998-2002) */
    Cardinality rows;             /* 估计输出行数 (pathnodes.h:2005) */
    int         disabled_nodes;   /* 被禁用节点数：enable_* GUC 的软惩罚 (pathnodes.h:2006) */
    Cost        startup_cost;     /* 吐出第一行前要花的代价 (pathnodes.h:2007) */
    Cost        total_cost;       /* 取完所有行的总代价 (pathnodes.h:2008) */
    List       *pathkeys;         /* 输出排序键 (pathnodes.h:2011) */
} Path;
```

这实际上是一个**五元组**：(startup_cost, total_cost, rows, width, pathkeys)，外加参数化集合 `PATH_REQ_OUTER`（宏定义 `pathnodes.h:2015`）。"最优"不再是单一标量：cursor 场景关心 startup，ORDER BY 场景关心 pathkeys，参数化场景关心 req_outer——所以每个 RelOptInfo 要同时维护多条"好路径"。

### 2.2 add_path：支配淘汰

`add_path`（`src/backend/optimizer/util/pathnode.c:459`）是"好路径集合"的唯一守门人。两个先行的策略决定（注释在 `pathnode.c:420-429`）：参数化路径一律视 pathkeys 为空（`pathnode.c:473`），避免保留过多参数化变体；startup 代价只在 `consider_startup`/`consider_param_startup` 为真时才值得关注（字段在 `pathnodes.h:1033,1035`）。

比较基于**模糊代价** `compare_path_costs_fuzzily`（`pathnode.c:181`），标准模糊因子 `STD_FUZZ_FACTOR = 1.01`（`pathnode.c:43`）——差 1% 以内的代价视为相等，防止浮点噪声导致计划抖动。新旧路径"支配关系"的判定（`pathnode.c:518-526`）：

```c
case COSTS_EQUAL:
    outercmp = bms_subset_compare(PATH_REQ_OUTER(new_path),
                                  PATH_REQ_OUTER(old_path));
    if (keyscmp == PATHKEYS_BETTER1)
    {
        if ((outercmp == BMS_EQUAL ||
             outercmp == BMS_SUBSET1) &&
            new_path->rows <= old_path->rows &&
            new_path->parallel_safe >= old_path->parallel_safe)
            remove_old = true;    /* new dominates old (pathnode.c:526) */
    }
```

新路径淘汰旧路径的条件是**全维度不劣**：代价（模糊相等时）不劣、排序键不劣、参数化集合是子集、行数不多、并行安全性不低。被淘汰的旧路径直接 `pfree` 回收（`pathnode.c:630-631`，唯独 IndexPath 豁免——它可能同时是某个 BitmapHeapPath 的子节点，`pathnode.c:447-451`）。

pathlist 本身按 (disabled_nodes, total_cost) 有序维护，新路径按序插入（`pathnode.c:639-642,654-658`）；这既是加速 hack，也让前置检查 `add_path_precheck`（`pathnode.c:686`）能提前失败。

`set_cheapest`（`pathnode.c:268`）在路径收集完毕时挑出 cheapest_total / cheapest_startup / cheapest_parameterized 三类代表，在 `set_rel_pathlist` 尾部调用（`src/backend/optimizer/path/allpaths.c:611`）。

---

## 3. 代价模型：cost_seqscan 与 cost_index

### 3.1 可调的底座：GUC 代价参数

所有代价都是相对数，锚点是"顺序读一页"= 1.0。五个全局变量（`src/backend/optimizer/path/costsize.c:131-135`）与默认值（`src/include/optimizer/cost.h:24-28`）：

| 参数 | 默认 | 含义 |
|---|---|---|
| seq_page_cost | 1.0 | 顺序读一页的基准代价 |
| random_page_cost | 4.0 | 随机读一页（SSD 上常调低到 1.1） |
| cpu_tuple_cost | 0.01 | 处理一个元组的 CPU 代价 |
| cpu_index_tuple_cost | 0.005 | 处理一个索引条目 |
| cpu_operator_cost | 0.0025 | 执行一次操作符/函数 |

GUC 注册在 `src/backend/utils/misc/guc_parameters.dat:553`（cpu_tuple_cost）、`:2437`（random_page_cost）、`:2652`（seq_page_cost）。表空间级覆盖用 `get_tablespace_page_costs` 读取（`costsize.c:293`）。

### 3.2 cost_seqscan：两条相加

`cost_seqscan`（`costsize.c:271`）的公式出奇地直白（`costsize.c:300-310`）：

```c
disk_run_cost = spc_seq_page_cost * baserel->pages;          /* 页数 × 顺序页代价 */
get_restriction_qual_cost(root, baserel, param_info, &qpqual_cost);
startup_cost += qpqual_cost.startup;
cpu_per_tuple = cpu_tuple_cost + qpqual_cost.per_tuple;      /* 每元组 CPU */
cpu_run_cost  = cpu_per_tuple * baserel->tuples;             /* × 全表元组数 */
startup_cost += path->pathtarget->cost.startup;
cpu_run_cost  += path->pathtarget->cost.per_tuple * path->rows;  /* 目标列表按输出行算 */
...
path->total_cost = startup_cost + cpu_run_cost + disk_run_cost;  /* costsize.c:339 */
```

注意两个不对称：过滤条件 CPU 代价按**扫描的**元组数（tuples）计，目标列表按**输出的**行数（rows）计——过滤发生在投影之前。并行路径用 `get_parallel_divisor` 折算 CPU 并缩小 rows（`costsize.c:313-332`）。

### 3.3 cost_index： Mackert-Lohman 缓存模型 + 相关性修正

`cost_index`（`costsize.c:546`）先问索引访问方法本身：`amcostestimate` 回调（btree 实现在 selfuncs.c）给出 indexStartupCost / indexTotalCost / **indexSelectivity** / **indexCorrelation**（`costsize.c:617-621`）。前者直接进代价，后者两个用于堆访问估计：

- 需要取回的元组数 `tuples_fetched = indexSelectivity × tuples`（`costsize.c:636`）；
- 无序相关时，取多少个堆页由 **Mackert-Lohman 公式**估计（考虑缓存命中率，`index_pages_fetched`，`costsize.c:898`，调用点 `costsize.c:720`）；此时每页按 random_page_cost 计，得 `max_IO_cost`（`costsize.c:731`）；
- 完全有序相关（刚 CLUSTER 过）时，页数 = 选择率 × 表页数，且除第一页外全是顺序读：`spc_random + (pages-1) × spc_seq`（`costsize.c:741-743`），得 `min_IO_cost`；
- 真实情况用 **correlation 的平方线性插值**（`costsize.c:785-787`）：

```c
csquared = indexCorrelation * indexCorrelation;
run_cost += max_IO_cost + csquared * (min_IO_cost - max_IO_cost);
```

这就是"按索引列范围扫描为什么快"的数学表达：correlation 接近 1 时 I/O 成本塌缩到顺序读。索引-only 扫描再用可见性地图打折扣：`pages_fetched × (1 - allvisfrac)`（`costsize.c:686,726`）。另外 amcostestimate 的结果被缓存在 IndexPath 上供位图扫描复用（`costsize.c:628-629`）。

### 3.4 行数与选择率：pg_statistic 的下游

行数估计是所有代价的乘数。基础关系的行数在 `set_baserel_size_estimates`（`costsize.c:5607`）中计算（`costsize.c:5614-5618`）：

```c
nrows = rel->tuples *
    clauselist_selectivity(root,
                           rel->baserestrictinfo,
                           0, JOIN_INNER, NULL);
rel->rows = clamp_row_est(nrows);
```

`clauselist_selectivity`（`src/backend/optimizer/path/clausesel.c:100`）逐条求选择率再组合，能合并的走扩展统计（多列 MCV/依赖，`clausesel.c:117` 的 `_ext` 版本）。单条选择率的终点是 `eqsel` 等 SupportRequestSelectivity 函数（`src/backend/utils/adt/selfuncs.c:302`），经由 `examine_variable`（`selfuncs.c:5652`）从 **pg_statistic** 槽位（MCV、直方图、distinct 数）插值——这正是 J 报告（pg_statistic / ANALYZE）数据的消费端。选择率烂，代价全烂；这是理解一切"计划突然变慢"问题的钥匙。

---

## 4. Join 搜索：动态规划、剪枝与 GEQO

### 4.1 joinlist 的生成与"塌缩上限"

`query_planner` 先经 restart 循环做 join 简化（外连接消除 `remove_useless_outer_joins`、半连接消除、自连接消除，`src/backend/optimizer/plan/planmain.c:285,293,300`），然后 `deconstruct_jointree` 把 FROM 树展平成 joinlist（`src/backend/optimizer/plan/initsplan.c:1418`）。子 FROM 块是否被拍平进同一层搜索，受两个启发式上限控制：`from_collapse_limit`（`initsplan.c:1568`）管子查询，`join_collapse_limit`（`initsplan.c:1754`）管显式 JOIN——两者默认都是 8（`guc_parameters.dat:1107,1535`）。超过上限的子问题**不再参与全局 join 排序搜索**，而是先局部规划成一个整体再进入上层，把搜索空间从指数压到可控。

### 4.2 动态规划逐层进

`make_rel_from_joinlist`（`allpaths.c:3837`）统计 joinlist 深度，`levels_needed > 1` 时三选一：插件 hook → GEQO → 标准动态规划（`allpaths.c:3903-3908`）：

```c
if (join_search_hook)
    return (*join_search_hook) (root, levels_needed, initial_rels);
else if (enable_geqo && levels_needed >= geqo_threshold)
    return geqo(root, levels_needed, initial_rels);
else
    return standard_join_search(root, levels_needed, initial_rels);
```

`standard_join_search`（`allpaths.c:3942`）是教科书式 DP：第 1 层是基表；`join_search_one_level`（`src/backend/optimizer/path/joinrels.c:78`）在第 k 层用"1×(k-1)、2×(k-2)、…"的全部划分组合出候选 joinrel（`allpaths.c:3977`），每层结束即 `set_cheapest`（`allpaths.c:4014`）——**劣路径当层即死，不会传染到高层**，这是 DP 在这里可行的前提。合法性由 `join_is_legal`（`joinrels.c:355`）把关（外连接左右匹配），代价由 `make_join_rel`（`joinrels.c:725`）填充：尝试 nestloop/hash/merge 三族路径后 add_path 淘汰。

### 4.3 GEQO：超过阈值就"进化"

触发条件：`enable_geqo && levels_needed >= geqo_threshold`（`allpaths.c:3905`），默认阈值 12（`guc_parameters.dat:1190`）。机制（`src/backend/optimizer/geqo/geqo_main.c:75`）：

- **染色体 = join 顺序**：`typedef int Gene`（`src/include/optimizer/geqo_gene.h:33`），一条 tour 就是基表的排列，解码成 join 树的工作交给 `gimme_tree`（`geqo_eval.c:163`）。
- **适应度 = 代价**：`geqo_eval` 对一条 tour 走一遍 mini 规划，取 `cheapest_total_path->total_cost`（`geqo_eval.c:115`）；非法 join 序返回 DBL_MAX（`geqo_eval.c:118`）。
- **种群规模**：`gimme_pool_size`（`geqo_main.c:329`）按 2^(N+1) 计算再用 Geqo_effort 截断到 [10×effort, 50×effort]（`geqo_main.c:339-345`，effort 默认 5）；代数默认等于种群规模（`geqo_main.c:362-366`）。
- **循环**：随机初始化（`geqo_main.c:128`）→ 按适应度排序（`geqo_main.c:131`）→ 每代选择-交叉-变异，默认交叉算子为边重组 ERX（`src/include/optimizer/geqo.h:46`），选择用线性偏置（`geqo_main.c:195`）→ 最后把最优 tour 再解码一次得到 RelOptInfo（`geqo_main.c:279-281`）。

GEQO 是**实用主义的妥协**：它不保证最优，只保证在表数 ≥12 时规划时间不爆炸。代价是同一个查询每次规划可能给出不同计划（受 `geqo_seed` 控制），且子规划相互独立、可能丢失 DP 层面的全局洞察。

---

## 5. 参数化路径：把 join 条件"推"进内表扫描

参数化路径是 nestloop 的燃料。`ParamPathInfo` 记录"这条路径要求外层提供哪些 rel 的值"（`PATH_REQ_OUTER`，`pathnodes.h:2015`）。构造入口：

- 基表：`get_baserel_parampathinfo`（`src/backend/optimizer/util/relnode.c:1756`）——把可移动到该关系的 join 条件收进 `ppi_clauses`，行数随之变小；
- join：`get_joinrel_parampathinfo`（`relnode.c:1897`）——**required_outer 由内外两侧的参数化并上本层要求的集合传播**（`relnode.c:1934-1939`），同时把"只能在本次 join 求值"的子句降为参数化子句；
- appendrel：`get_appendrel_parampathinfo`（`relnode.c:2120`）。

扫描端，最简单的顺序扫描也可能因 LATERAL 引用而参数化（`required_outer = rel->lateral_relids`，`allpaths.c:837`；随后 `add_path(rel, create_seqscan_path(root, rel, required_outer, 0))`，`allpaths.c:851`）。索引端，参数化子句在 `cost_index` 里既压低选择率又计入 qpquals（`costsize.c:587-594`）。

join 端，`match_unsorted_outer`（`src/backend/optimizer/path/joinpath.c:61`）负责 nestloop：它检查内路径是否带有能引用外 rel 的参数化子句（`joinpath.c:840-842` 遍历 `inner_path->param_info->ppi_clauses`），随后 `try_nestloop_path`（`joinpath.c:881`）用 `PATH_REQ_OUTER` 校验内外兼容（`joinpath.c:896-897`）并 `create_nestloop_path`（`joinpath.c:971`）。执行形态正是 08 章讲的样子：**外表每吐一行，内表参数化扫描重执行一次**——内路径的 `rows` 变小、cost_index 的 `loop_count > 1` 分支（`costsize.c:670`）还把跨次缓存的收益算进 I/O。一条好的参数化索引路径，就是"嵌套循环突然变快"的全部秘密。

---

## 6. plancache：通用计划 vs 定制计划

预处理语句（PREPARE/扩展协议）会缓存计划，核心在 `src/backend/utils/cache/plancache.c`。`GetCachedPlan`（`plancache.c:1306`）每次先 `RevalidateCachedQuery`（`plancache.c:693`）核对依赖，再由 `choose_custom_plan`（`plancache.c:1184`）二选一：

```c
/* Generate custom plans until we have done at least 5 (arbitrary) */
if (plansource->num_custom_plans < 5)
    return true;                                  /* plancache.c:1212 */
avg_custom_cost = plansource->total_custom_cost / plansource->num_custom_plans;
...
if (plansource->generic_cost < avg_custom_cost)
    return false;                                 /* 选 generic */
return true;                                      /* plancache.c:1227 */
```

策略：前 5 次一律定制计划（带具体参数值，选择率准）；之后比较**通用计划代价**与**定制计划平均代价**（后者含重规划开销，按 `1000 × cpu_operator_cost × (nrelations + 1)` 粗估，`cached_plan_cost`，`plancache.c:1280`）。可被 `plan_cache_mode` 强制覆盖（`plancache.c:1200-1203`；GUC 在 `guc_parameters.dat:2379`）。

**失效（invalidation）**：查询树的依赖（relcache 条目 + `invalItems`）在创建时登记（`plancache.c:458,914`），后端通过 `CacheRegisterRelcacheCallback(PlanCacheRelCallback, ...)`（`plancache.c:156`）订阅 syscache 失效；DDL 一旦触碰依赖表，缓存查询树作废，下次 `GetCachedPlan` 走重解析-重规划。通用计划还做"按代价失效"：若定制计划平均便宜得多，会丢弃通用计划回到定制（`plancache.c:937` 附近注释说明 generic_cost 的保守维护）。

经典陷阱在此章定位：参数 sniffing——通用计划平均主义害了极端参数的查询，`plan_cache_mode = force_custom_plan` 是止血阀。

---

## 7. 与前作对照：代价模型的可信度决定优化器形态

| 系统 | 优化器形态 | Join 搜索 | 代价模型 |
|---|---|---|---|
| PostgreSQL | 模块化 Path/RelOptInfo，支配淘汰 | DP → GEQO（>12 表） | 完整代价模型，GUC 可调，pg_statistic 驱动 |
| SQLite（卷一） | 小而全，单文件 | NTM 启发式（贪心 + 局部调整） | 简化代价，"估计保守即可" |
| MySQL | 启发式为主 + 代价修正 | 贪心/有限穷举 | 代价精度长期是短板（直方图 8.0 才补上） |
| etcd | 无查询规划器 | — | —（KV 接口，range 树即"计划"） |

PostgreSQL 的选择是：**既然代价模型是所有决策的公理，就把它做成可审计、可调参、可观测的**（EXPLAIN 直接展示代价与行数）。SQLite 的小优化器在它的规模下反而更稳健；MySQL 证明了没有好统计就没有好优化器；etcd 则划出边界——没有关系代数就没有规划器问题。PG 处在"模型复杂到必须模块化"的节点：Path 层就是为此而生的解耦层。

---

## 8. 设计动机

- **为什么"路径支配淘汰"优于穷举**：枚举所有计划是 N！；DP 已把层内选择降为多项式，但一个 RelOptInfo 上仍可能积累大量路径。支配淘汰把"保留所有好路径"限制在**帕累托前沿**（startup/total/pathkeys/req_outer 四维互不支配者），代价差 1% 以内视为相同（fuzz 1.01）以止抖动。被淘汰者立即 pfree（`pathnode.c:630-631`），内存也省。
- **为什么代价参数是 GUC**：代价模型的每个常数（随机 vs 顺序读比、CPU 指令当量）都与硬件强相关。PG 不假设硬件，而是把这些常数暴露成 GUC（`guc_parameters.dat:553,2437,2652`），让 DBA 用 SSD/内存配置校准模型；`random_page_cost=1.1` 一句话就能让规划器拥抱索引。`enable_*` 开关则退化为 disabled_nodes 软惩罚（`costsize.c:336-337`），禁用的方法参与比较但带罚分，保留"计划仍合法"的兜底。
- **GEQO 的实用主义**：DP 是 O(3^N) 量级，12 表已到百万级组合。GEQO 用固定预算的随机化搜索换"不会更坏"，并且用 `geqo_seed` 保证可复现。它不是学术最优解，而是"大查询也能在可预期时间内出计划"的工程承诺——宁要次优的确定性，不要最优的不可预测性。
- **generic/custom 双轨**：重规划不是免费的（估算公式 `plancache.c:1280`），但参数相关的选择率诱惑难以拒绝。PG 的答案是用代价模型自己来仲裁两种模式的性价比——优化器连"要不要优化"都优化。

---

## 9. FAQ 素材

1. **Q: EXPLAIN 里 cost=0.00..358.10 两个数是什么？** A: startup/total（`pathnodes.h:2007-2008`）。前者是吐第一行前的代价（排序节点很高，索引扫描很低），LIMIT 优化和 cursor 优化靠它。
2. **Q: rows 估计为什么这么不准？** A: 行数 = tuples × 选择率（`costsize.c:5614-5618`），选择率来自 pg_statistic 的抽样（N 报告）。统计过期、多列相关、跨类型比较都会放大误差；扩展统计（`clausesel.c:117`）可救多列相关。
3. **Q: 表多了以后规划很慢/计划随机变，怎么回事？** A: 超过 `geqo_threshold`（默认 12，`guc_parameters.dat:1190`）走遗传算法，结果受 `geqo_seed` 影响；关掉 GEQO 或调大阈值可回到确定性 DP。
4. **Q: enable_seqscan=off 为什么计划里还有 Seq Scan？** A: enable_* 只是给路径加 disabled_nodes 罚分（`costsize.c:336-337`），不是硬禁令——没有替代路径时它仍是"最优"。
5. **Q: PREPARE 的语句为什么有时快有时慢？** A: 前 5 次定制计划，之后 `choose_custom_plan`（`plancache.c:1184`）按代价在通用/定制间摇摆；极端分布用 `plan_cache_mode` 钉死。
6. **Q: random_page_cost 应该调吗？** A: SSD 阵列上 1.1~2.0 是常见值（默认 4.0，`cost.h:25`）；它直接决定 cost_index 的 max_IO（`costsize.c:731`）。
7. **Q: correlation 是什么？在哪里生效？** A: 索引序与物理堆序的相关系数，平方后线性插值 max/min IO（`costsize.c:785-787`）；CLUSTER 后接近 1，范围扫描代价大降。
8. **Q: join 顺序可以手工控制吗？** A: 调低 `join_collapse_limit`/`from_collapse_limit`（默认 8，`guc_parameters.dat:1107,1535`）= 1 可让 planner 严格按书写顺序连接；PG 不支持 Oracle 风格的 ordered hint。
9. **Q: 参数化路径是什么？和 LATERAL 什么关系？** A: 路径要求外部 rel 提供参数（`PATH_REQ_OUTER`，`pathnodes.h:2015`）；LATERAL 是它最显式的来源（`allpaths.c:845`），但 join 条件下推产生的参数化索引扫描才是性能主力（`joinpath.c:840-842`）。
10. **Q: 为什么视图/子查询展开后有时计划更好有时更糟？** A: 展开与否受 collapse 限额约束；被拍平的子问题进全局 DP，没被拍平的先局部规划再当黑盒——两边代价模型视角不同。

## 深挖建议

1. **等价类与 pathkeys**：`equivclass.c` 与 `pathkeys.c` 如何从 `a=b` 推出免费排序，是理解"去掉 ORDER BY 仍有序"的钥匙。
2. **createplan.c 的 Path→Plan 实体化**：路径阶段按"形状"选择，实体化阶段才决定 scan 方法名（`planner.c:539` 之后的 `create_plan`，7381 行的大文件）。
3. **位图扫描的代价拼装**：`cost_bitmap_tree_scan` 系列复用 amcostestimate 缓存的 indexselectivity（`costsize.c:628-629`），对比索引扫描与位图方案的临界点。
4. **分区裁剪与 appendrel 参数化**：`get_appendrel_parampathinfo`（`relnode.c:2120`）+ 运行时裁剪，是分区表性能章节的前置。
5. **GEQO 的重组算子谱系**：geqo.h 里 ERX/PMX/CX/PX/OX1/OX2 六种交叉（`geqo.h:39-46`），默认 ERX 的边重组如何保序，可做一章 TSP 视角的读书笔记。

---

## 写作要点速查表

| 要点 | 位置 |
|---|---|
| 规划入口 planner() / hook 分发 | src/backend/optimizer/plan/planner.c:328,333-338 |
| 标准流程 standard_planner | planner.c:346（create_plan :539，set_plan_references :643） |
| 子查询递归 subquery_planner / CTE | planner.c:770,843 |
| 查询级流程 grouping_planner / query_planner 调用点 | planner.c:1692,1912 |
| query_planner 与 restart join 简化 | plan/planmain.c:54,78,285,300,377 |
| make_one_rel / 基表路径 / joinlist 规划 | path/allpaths.c:183,239,244 |
| set_rel_pathlist 分发（顺序扫描等） | allpaths.c:520,550（hook :589，set_cheapest :611） |
| set_plain_rel_pathlist（seqscan+index） | allpaths.c:828,851,858 |
| join 搜索三选一（hook/GEQO/DP） | allpaths.c:3837,3903-3908 |
| DP 标准搜索 standard_join_search | allpaths.c:3942,3977,4014 |
| join_search_one_level / make_join_rel | path/joinrels.c:78,355,725 |
| GEQO 主函数 / 种群 / 适应度 | geqo/geqo_main.c:75,329,339-345; geqo_eval.c:57,115,163 |
| Path 五元组 / PATH_REQ_OUTER | include/nodes/pathnodes.h:1964,2005-2011,2015 |
| add_path 支配淘汰（含 1.01 fuzz） | util/pathnode.c:43,181,459,491,518-526,630-631,686 |
| cost_seqscan 公式 | path/costsize.c:271,300,306-310,339 |
| cost_index / amcostestimate / 相关性插值 | costsize.c:546,618,636,731,741-743,785-787,898 |
| 代价参数默认值 | include/optimizer/cost.h:24-28; utils/misc/guc_parameters.dat:553,2437,2652 |
| 行数 = tuples × clauselist_selectivity | costsize.c:5607,5614-5618; path/clausesel.c:100 |
| 选择率来源 eqsel / pg_statistic 槽位 | utils/adt/selfuncs.c:302,5652 |
| 参数化路径构造 / nestloop 配合 | util/relnode.c:1756,1897,1934-1939,2120; path/joinpath.c:61,840-842,881,971 |
| generic vs custom 决策 | utils/cache/plancache.c:1184,1212,1227,1280,1306 |
| plancache 失效注册 | plancache.c:156,458,693 |

（全文完，约 340 行）
