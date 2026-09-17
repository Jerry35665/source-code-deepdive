# D | 优化器:规则引擎、Join Order 与统计传播

> 系列:《DuckDB 深读》 · 基线 commit `7e886f44428e90c8379d4d34e2afb866108ff079`
> 核心目录:`src/optimizer/`、`src/include/duckdb/optimizer/`;节点类型头文件 `src/include/duckdb/planner/operator/`
> 文中所有 `文件:行号` 均经实际 Read/Grep 核对;路径相对仓库根。

---

## 0. 全景:Optimizer::Optimize 的执行顺序

DuckDB 优化器不是 cascade/memo 那种"规则搜索框架",而是**一条固定顺序的流水线**:先跑强制的 aggregate 下沉,再跑一个只改表达式树的 ExpressionRewriter(规则引擎),最后按硬编码顺序跑约 45 个结构性 pass。入口在 `Optimizer::Optimize`(`src/optimizer/optimizer.cpp:555`):

```
Optimizer::Optimize (optimizer.cpp:555)
 │
 ├─ LowerMandatoryAggregateRewrites (optimizer.cpp:545)   ← GroupingSets + 强制多阶段聚合(在优化开关之前)
 ├─ extension pre_optimize (optimizer.cpp:571-578)
 ├─ RunBuiltInOptimizers (optimizer.cpp:229)  ——  主体流水线,顺序如下:
 │
 │   [表达式层 ExpressionRewriter:改表达式树,不动 plan 结构]
 │    ┌ ConstantOrderNormalization → ConstantFolding → StructExtractStructPackFolding
 │    ├ Distributivity → ArithmeticSimplification → LeastGreatest → Case → Conjunction
 │    ├ DatePart / DateTrunc / Comparison / RowComparison / InClause / InEnum / EnumCompare
 │    ├ EqualOrNull → MoveConstants → MoveUnaryMinus → MonotonePreimage
 │    ├ Like → StringPrefix → InstrPrefix → OrderedAggregate / DistinctAggregate / DistinctWindowed
 │    ├ Regex / RegexpReplaceExtract → EmptyNeedle / NoopReplace → EnumComparison
 │    └ JoinDependentFilter → TimeStampComparison → PredicateFactoring → ListComprehension
 │       → ContainsToInClause → NotComparison → NotConjunction   (注册见 optimizer.cpp:71-107)
 │
 │   [结构层:每个 pass 一行,行号为 optimizer.cpp 中 RunOptimizer 调用处]
 │    1. CTE_INLINING                :255  CTE 内联进主查询(引用少/廉价时)
 │    2. AGGREGATE_FUNCTION_REWRITER :261  AVG→SUM/COUNT 等函数改写
 │    3. FILTER_PULLUP               :267  谓词先上提(穿过 project 等)
 │    4. FILTER_PUSHDOWN             :273  谓词下推家族(先 CheckMarkToSemi:276)
 │    5. FilterStatistics(非 pass)   :280  用统计修剪 filter(DML-CTE 时跳过)
 │    6. CTE_FILTER_PUSHER           :286  谓词推进 materialized CTE
 │    7. REGEX_RANGE                 :291  regexp_matches → 范围过滤
 │    8. IN_CLAUSE                   :296  大 IN → MARK join
 │    9. DELIMINATOR                 :302  删除冗余 DelimGet/DelimJoin
 │   10. GROUPING_SETS               :308  GROUPING SETS 展开为显式聚合
 │   11. MultiStageAggregate(无条件) :314  聚合拆分/去 DISTINCT 依赖
 │   12. CTE_INLINING(第二轮)       :319
 │   13. EMPTY_RESULT_PULLUP         :325  空结果上提
 │   14. WINDOW_SELF_JOIN            :331  部分 window → 自连接
 │   15. PROJECTION_PULLUP           :337  把 project 从 join 下方拉起
 │   16. OUTER_JOIN_SIMPLIFICATION   :343  FULL→LEFT→INNER 化简
 │   17. JOIN_ORDER                  :350  ★ DPhyp DP + 贪心,顺带 cross product→join
 │   18. AGGREGATE_REUSE             :356  SEMI join 暴露的聚合 payload 复用
 │   19. PARTIAL_AGGREGATE_PUSHDOWN  :365  星型模型下预聚合下推
 │   20. JOIN_ELIMINATION            :370  PK-FK join 消除
 │   21. UNNEST_REWRITER             :376  DelimJoin 中的 UNNEST 移到 projection
 │   22. UNUSED_COLUMNS              :382  剪掉未引用列
 │   23. DUPLICATE_GROUPS            :388  聚合去重 group
 │   24. COMMON_SUBEXPRESSIONS       :394  ★ CSE 提取到新 projection
 │   25. COLUMN_LIFETIME             :400  生成 projection map,早裁列
 │   26. BUILD_SIDE_PROBE_SIDE       :407  决定 hash join build/probe 侧
 │   27. COMMON_SUBPLAN              :416  公共子计划 → materialized CTE
 │   28. LIMIT_PUSHDOWN              :423  LIMIT 下穿 PROJECTION
 │   29. ROW_GROUP_PRUNER            :428  filter→row group 剪枝
 │   30. SAMPLING_PUSHDOWN           :434
 │   31. TOP_N                       :440  ORDER BY+LIMIT → TopN
 │   32. LATE_MATERIALIZATION        :446
 │   33. STATISTICS_PROPAGATION      :457  ★ 统计传播(有改写能力)
 │   34. MultiStageAggregate(成本制) :466  基于统计图决定聚合拆分
 │   35. PROJECTION_PLACEMENT        :474  把 projection 放回最优位置
 │   36. TOP_N_WINDOW_ELIMINATION    :481  row_number+filter → 聚合
 │   37. COMMON_AGGREGATE            :487  去重相同聚合
 │   38. UNUSED_COLUMNS(条件重跑)   :494  统计 pass 删了表达式时
 │   39. COLUMN_LIFETIME(重跑)      :503
 │   40. REORDER_FILTER              :509  启发式重排 filter 顺序
 │   41. PARTITIONED_EXECUTION       :515  流水线切分 + union 回接
 │   42. JOIN_FILTER_PUSHDOWN        :521  join filter 下推(尘埃落定后)
 │   43. ROW_NUMBER_REWRITER         :527  row_number() → 虚拟列
 │   44. TYPE_PUSHDOWN :533 / SCALAR_FN_PUSHDOWN :539  投影裁剪推进文件读取器
 │
 └─ extension optimize (optimizer.cpp:582-589) → Planner::VerifyPlan (:591)
```

每个 pass 由 `RunOptimizer(OptimizerType, callback)` 包裹(`optimizer.cpp:134-151`):检查中断、按 `disabled_optimizers` 集合可单独关闭(`optimizer.cpp:125-132`,枚举定义 `src/include/duckdb/common/enums/optimizer_type.hpp:16-61`)、接 profiler 计时,DEBUG 下每个 pass 后跑 `LogicalPlanVerifier`(`optimizer.cpp:148-150`)。

## 1. 规则引擎:Rule 抽象与 ExpressionRewriter

规则基类极简(`src/include/duckdb/optimizer/rule.hpp:17-32`):一条规则 = 一个 `root` 表达式匹配器(`rule.hpp:27`)+ 一个 `Apply` 回调(`rule.hpp:30-31`)。匹配器家族在 `src/optimizer/matcher/`(FunctionExpressionMatcher、ConstantExpressionMatcher、SetMatcher 等)。

驱动循环 `ExpressionRewriter::ApplyRules`(`src/optimizer/expression_rewriter.cpp:52-81`)是显式栈的**自底向上**遍历,注释明确说"Rewrite the subtree bottom-up so parent rules see already-simplified children"(`expression_rewriter.cpp:64`);某条规则改写成功后重新进入该节点(`expression_rewriter.cpp:73-77`),直到定住。注意它**不做全局搜索**:顺序即优先级,返回即重试。单节点上的规则匹配代码:

```cpp
// src/optimizer/expression_rewriter.cpp:20-44 (节选)
static unique_ptr<Expression> ApplyRule(LogicalOperator &op, const vector<reference<Rule>> &rules,
                                        unique_ptr<Expression> expr, bool &changes_made, bool is_root) {
	for (auto &rule : rules) {
		vector<reference<Expression>> bindings;
		if (rule.get().root->Match(*expr, bindings)) {
			// the rule matches! try to apply it
			bool rule_made_change = false;
			auto alias = expr->GetAlias();
			auto result = rule.get().Apply(op, bindings, rule_made_change, is_root);
			if (result) {
				changes_made = true;
				...
				return result;      // 改写成功:返回新表达式,外层会对它重新跑规则
			}
			...
```

FILTER 算子还有特殊处理:改写可能新增谓词,因此循环调用 `SplitPredicates` 直到不再分裂(`expression_rewriter.cpp:106-116`)。

### 精读一条典型规则:LikeOptimizationRule

```cpp
// src/optimizer/rule/like_optimizations.cpp:14-24
LikeOptimizationRule::LikeOptimizationRule(ExpressionRewriter &rewriter) : Rule(rewriter) {
	// match on a FunctionExpression that has a foldable ConstantExpression
	auto func = make_uniq<FunctionExpressionMatcher>();
	func->matchers.push_back(make_uniq<ExpressionMatcher>());
	func->matchers.push_back(make_uniq<ConstantExpressionMatcher>());
	func->policy = SetMatcher::Policy::ORDERED;
	// we match on LIKE ("~~"), NOT LIKE ("!~~"), GLOB ("~~~"), and NOT GLOB ("!~~~")
	func->function = make_uniq<ManyFunctionMatcher>(
	    identifier_set_t {Identifier("!~~"), Identifier("~~"), Identifier("!~~~"), Identifier("~~~")});
	root = std::move(func);
}
```

`Apply`(`like_optimizations.cpp:132-171`)对常量 pattern 做四分类:无通配符 → 直接变等值/不等比较(`:155-159`);尾部 `%` → `prefix`(`:160-162`);头部 `%` → `suffix`(`:163-165`);两端 `%` → `contains`(`:166-168`)。判定函数 `PatternIsPrefix/Suffix/Contains` 在 `:41-130`。改写由 `ApplyRule`(`:173-192`)换成绑定的专用函数并把通配符从常量里剥掉(`:180-181`)。同族还有 RegexOptimizationRule(`src/optimizer/rule/regex_optimizations.cpp`)。

## 2. Filter Pushdown 家族:按算子拆分的谓词搬运

`FilterPushdown::Rewrite` 是一个按 `LogicalOperatorType` 分派的状态机(`src/optimizer/filter_pushdown.cpp:108-163`):聚合→`PushdownAggregate`,filter→`PushdownFilter`,cross product→`PushdownCrossProduct`,各类 join→`PushdownJoin`,projection→`PushdownProjection`,set 操作/distinct/limit/window/unnest/get 各有专属函数,未列出的走 `FinishPushdown`(`filter_pushdown.cpp:355-363`,对子树各开一个新 FilterPushdown 递归,再把剩余 filter 挂回顶部)。每个子文件一个 `PushdownXxx`,即"pushdown 家族"。

- **收集与静态短路**:`PushdownFilter` 把 filter 表达式收进集合,`AddFilter` 返回 `UNSATISFIABLE` 时整棵子树换成 `LogicalEmptyResult`(`src/optimizer/pushdown/pushdown_filter.cpp:16-23`)。
- **穿 project**:`PushdownProjection`(`pushdown_projection.cpp:149-195`)把 filter 里的列引用替换成 projection 的表达式后下传(`ReplaceProjectionBindings`,`:44-57`);volatile 和可能抛错的表达式**留下**(`:163-170`);`ProjectionMode::PRESERVE_COMPUTED_EXPRESSIONS` 时改为把 projection 拆成两层、filter 夹在中间(`SplitProjection`,`:98-147`)。
- **穿 aggregate**:`PushdownAggregate`(`pushdown_aggregate.cpp:38-104`)只下推**引用 group 列**的谓词:引用聚合值(`:47-49`)或 GROUPINGS(`:51-53`)的不动;还要求谓词列出现在**所有** grouping set 里(`:70-84`),volatile 不动(`:85-87`);随后把 group 绑定替换回原始表达式(`ReplaceGroupBindings`,`:23-31`)。
- **inner join 先拆再并**:`PushdownInnerJoin` 把 join 条件全部并入 filter 集合(`src/optimizer/pushdown/pushdown_inner_join.cpp:29-44`),然后把 join **临时降级为 cross product**,交给 `PushdownCrossProduct`(`:43-52`)。
- **cross product → join**:`PushdownCrossProduct`(`pushdown_cross_product.cpp:11-91`)按 `JoinSide::GetJoinSide` 把 filter 分到左/右;横跨两侧的变成 join 条件(`:43-45`),有条件则重建 `LogicalComparisonJoin`(`:54-64`),没有就保持 cross product。这就是 optimizer.cpp:349 注释"join order 也会把 cross product + filter 重写成 join"的上半场(下半场在 JoinOrderOptimizer 的图构建里)。
- **MARK→SEMI/ANTI**:`PushdownMarkJoin`(`pushdown_mark_join.cpp:28-109`)发现 filter 只引用 marker 列时把 MARK join 改成 SEMI(`:59-68`);filter 为 `NOT(marker)` 且 join 条件全是 null 值相等比较时改成 ANTI(`:74-99`);转成 SEMI 后还会把 null-safe 等值化简为普通等值以解锁 runtime filter(`SimplifyNullSafeSemiJoinConditions`,`:10-26`)。上游先用 `CheckMarkToSemi` 自顶向下判断 marker 是否真的无人引用,有人引用就打上 `convert_mark_to_semi=false`(`filter_pushdown.cpp:33-75`)。
- **外连接**:`PushdownOuterJoin`(`pushdown_outer_join.cpp:174-197`)只处理 FULL OUTER,且仅当谓词落在 coalesced 等值 join 键上才推进两侧(`PushDownFiltersOnCoalescedEqualJoinKeys`,`:183-185`),否则 `FinishPushdown` 原地不动;`PushdownLeftJoin`(`pushdown_left_join.cpp:107`)处理 LEFT(以及被当作 LEFT 的 ASOF,见 `filter_pushdown.cpp:189-193`);SEMI/ANTI 走 `PushdownSemiAntiJoin`(`pushdown_semi_anti_join.cpp:12-19`,当前 filter 全归 probe 侧,且按空子树短路:右空时 ANTI 直接返回左孩子,`:37-48`);SINGLE 走 `pushdown_single_join.cpp:8`。
- **window/unnest**:`PushdownWindow`(`pushdown_window.cpp:33`)只下推"落在**每个** window 表达式 partition by 列集合上"的谓词(判定函数 `CanPushdownFilter`,`:11-31`);`PushdownUnnest`(`pushdown_unnest.cpp:9-52`)凡引用 `unnest_index` 的谓词一律留下,其余下穿。
- **集合操作**:`PushdownSetOperation`(`pushdown_set_operation.cpp:27-59`)把每个谓词**复制**进 UNION/EXCEPT/INTERSECT 的每个分支并改写绑定(`ReplaceSetOpBindings`,`:38`);`PushdownDistinct`(`pushdown_distinct.cpp:7`)与 `PushdownLimit`(`pushdown_limit.cpp:9`)默认阻断(行数/去重语义);`PushdownGet`(`pushdown_get.cpp:87`)把剩余谓词经 combiner 生成 `TableScanFilters` 挂到 `get.table_filters`(`:160`),带 barrier 的谓词被扣住不进扫描(`:94-104`)。
- 下推途中的公共设施在 `filter_pushdown.cpp`:`AddFilter` 按 AND 拆分后喂给 `FilterCombiner`(`:245-260`),`GenerateFilters` 让 combiner 产出(可能已合并/推导出)的谓词(`:262-273`);谓词带 `ExpressionBarrier`(可能抛错等)时不能越过删行算子,由 `BarrierCanPassThrough`/`ExtractBarrierFilters` 兜住(`:82-117`)。
- **pullup 前置**:`FilterPullup::Rewrite`(`src/optimizer/filter_pullup.cpp:13-116`)支持的算子分派:FILTER/PROJECTION(:15-17)、cross product 与各类 join(:19-24)、INTERSECT/EXCEPT(:26-27)、DISTINCT(:29)、ORDER_BY(:31);join 侧分 `PullupFromLeft`(:51)/`PullupFromRight`/`PullupBothSide`(:75,:116)。它的产出是上提到树顶的 filter 集合,交给随后的 pushdown 重新分配。

## 3. Join Order:DPhyp 动态规划 + 贪心兜底

结构拆分(`src/optimizer/join_order/`):`JoinOrderOptimizer::Optimize` 只做编排(`join_order_optimizer.cpp:60-130`);`QueryGraphManager::Build` 负责把 plan 抽成超图(`query_graph_manager.cpp:170-204`:先 `ExtractJoinRelations` 抽关系,再 `ExtractEdges` 抽边,再建冲突检测/谓词模型/inner 伴随集,最后 `CreateHyperGraphEdges`);`PlanEnumerator` 做 DPhyp 枚举(`plan_enumerator.hpp:29-88`);`CostModel` 与 `CardinalityEstimator` 供价。

- **DP 状态**:`DPJoinNode`(`src/include/duckdb/optimizer/join_order/join_node.hpp:17-48`)记录关系集 `set`、左右子集、选中的谓词、是否 cross product、cost 与 cardinality。DP 表就是 `plans: JoinRelationSet → DPJoinNode`(`plan_enumerator.hpp:82`)。`JoinRelationSet` 由 `JoinRelationSetManager` 去重管理(`src/include/duckdb/optimizer/join_order/join_relation_set.hpp:19,36-55`)。
- **EmitPair**:枚举一对子图,`CreateJoinTree` 后按 cost 更新 DP 表(`plan_enumerator.cpp:192-235`);等价 cost 时用"右基数更大者胜"的 tiebreaker,减少 LEFT 被翻转成 RIGHT(`:218-232`)。成本函数 = join 基数 + 左右子代价,LEFT join 额外计 RHS 输入代价(`src/optimizer/join_order/cost_model.cpp:40-48`)。
- **DPhyp 枚举**:`SolveJoinOrderExactly`(`plan_enumerator.cpp:385-406`)按 "Dynamic Programming Strikes Back"(Moerkotte & Neumann)实现,出处注释在 `:565-567`;`EmitCSG/EnumerateCmpRecursive` 做 connected-subgraph 枚举(`:253-303`,含论文遗漏的去重补丁,注释 `:275-278`)。
- **DP→贪心切换**:`TryEmitPair` 计数,超过 10000 对就放弃精确 DP(`:237-251`);此外关系数 ≥ `approximate_join_order_threshold`(默认 12,`src/include/duckdb/main/settings.hpp:320-332`)时直接走近似。贪心 `SolveJoinOrderApproximately`(`:408-507`)每轮选最小 cost 的可连接对,O(r^3)(注释 `:417-419`)。入口 `SolveJoinOrder`(`:568-616`)汇总:精确失败或无完整计划时回退贪心(`:578-587`),贪心也失败则**原样返回原 plan**(`join_order_optimizer.cpp:96-100`)。
- **cartesian 产品**:图未连通时 `ActivateRequiredCrossProducts` 打开必需的 cross product 边、清缓存重跑(`plan_enumerator.cpp:518-526`);贪心里的 `CanCreateCrossProduct` 分支还会把允许的组合物化为 cross product 边(`:453-493`)。
- 重建阶段:`query_graph_manager.plans = plan_enumerator.GetPlans()` 后 `Reconstruct`(`join_order_optimizer.cpp:92-95`),并自底向上调 `EstimateCardinality` 回填基数(`:120-123`)。
- **基数估计器**:`CardinalityEstimator` 无真统计时用保守启发:SEMI/ANTI 的 selectivity 常数为 5(`src/include/duckdb/optimizer/join_order/cardinality_estimator.hpp:28`),兜底 selectivity 用 `RelationStatisticsHelper::DEFAULT_SELECTIVITY`(`cardinality_estimator.cpp:917`);核心接口是模板 `EstimateCardinalityWithSet<T>(JoinRelationSet&)`(`cardinality_estimator.hpp:42`)。join order 期间的统计来自 planning 时收集的 `RelationStats`(含每列 distinct count,传递给 optimizer.cpp:77 的 `GetRelationStats`)。
- **关系集管理**:`JoinRelationSetManager` 保证同一关系组合对应唯一 `JoinRelationSet` 对象,`Union` 生成合并集(`src/include/duckdb/optimizer/join_order/join_relation_set.hpp:36-55`),这是 DP 表能用指针做 key 的前提(`plan_enumerator.cpp:542-545` 的注释明说了这一点)。

## 4. 统计传播:BaseStatistics 沿树流动 + 顺手改写

`StatisticsPropagator`(`src/optimizer/statistics_propagator.cpp:29-171`)自底向上递归:按算子类型分派到 `PropagateStatistics(XxxOp&, node_ptr)`(`:47-114`),表达式侧按 `ExpressionClass` 分派到 `PropagateExpression`(`:139-161`)。载体是 `column_binding_map_t<unique_ptr<BaseStatistics>> statistics_map`,优化器入口处创建并在传播后交给 `ProjectionPlacement`/`TopNWindowElimination` 复用(`optimizer.cpp:453-478`)。算子/表达式处理器按目录拆在 `src/optimizer/statistics/operator/` 与 `.../expression/`。

- **入口注入**:LogicalGet 把表统计放进 map,并把与统计矛盾的 table filter 直接删掉(`src/optimizer/statistics/operator/propagate_get.cpp:155-215`)。
- **投影**:`PropagateStatistics(LogicalProjection&)` 先传播孩子,再对每个表达式求统计并存入 map(`src/optimizer/statistics/operator/propagate_projection.cpp:6-23`);孩子变 `LOGICAL_EMPTY_RESULT` 则整个节点跟着变空(`:10-13`)。
- **filter 改写**:恒真 → 删条件、删空整个 filter(`propagate_filter.cpp:328-342`);恒假/恒假或 null → `ReplaceWithEmptyResult`(`:343-348`,这就是"filter 恒假剪枝 empty_result")。比较会把 min/max 边界写回两侧统计(`UpdateFilterStatistics` 两栏版本,`:89-160`:列-列等值取交集边界,`<` 收紧上界等)。
- **join 改写**:`HandleJoinNeverMatches`(`propagate_join.cpp:16-47`)在条件恒假时按 join 类型剪枝:SEMI/INNER 整节点变空,ANTI 直接取左孩子,LEFT/RIGHT 把另一侧变空。`HandleJoinAlwaysMatches`(`:49-81`)在唯一条件恒真时:SEMI 降为 limit-1 + cross product(`:52-67`),INNER 降为 cross product(`:69-75`)。条件间的统计还会互相收紧并**反向下推成 filter**(`CreateFilterFromJoinStats`,`:348-392`,仅整型列,生成后立刻过一遍 FilterPushdown)。
- 外连接语义通过给被补 null 的一侧打 `CAN_HAVE_NULL_VALUES` 传播(`propagate_join.cpp:272-289`)。传播过程中删掉的条件会置 `removed_expressions`,触发 optimizer.cpp:494-500 的 `UNUSED_COLUMNS` 二次清理。
- **处理器全景**:算子侧 `src/optimizer/statistics/operator/` 一算子一文件:aggregate(`propagate_aggregate.cpp:475`,含 MIN/MAX/DISTINCT 等聚合的统计推导)、cross_product(`propagate_cross_product.cpp:6`)、CTE(`propagate_cte.cpp:7,34`,materialized CTE 的统计注册进 map、CTE_REF 查回)、filter/get/join/limit(`propagate_limit.cpp:6`,limit 直接给出基数上界)/order(`propagate_order.cpp:7`)/projection/set_operation(`propagate_set_operation.cpp:77`,union 取 max、except/intersect 特判)/secure_view/window(`propagate_window.cpp:10`)。表达式侧 `src/optimizer/statistics/expression/`:constant、columnref、comparison(比较输出 BOOLEAN 统计并顺带收紧输入边界)、conjunction、case、function、aggregate、between、operator 共 10 个文件。
- **派生消费者**:传播产物 `statistics_map` 随后被 `MultiStageAggregateRewriter`(COST_BASED,optimizer.cpp:466)和 `ProjectionPlacement`(optimizer.cpp:474-477)复用,后者依赖"传播后的统计"决定 projection 放置;DEBUG 下可用 `debug_verify_stats` 给表达式挂验证统计(`statistics_propagator.cpp:165-167`)。

统计传播的整体数据流(一个"边传播边改写"的单次后序遍历):

```
LogicalGet 表统计 ──► statistics_map[TableIndex,ColumnIndex]
        │ (propagate_get.cpp:155-215,同时修剪矛盾 table filter)
        ▼
   子算子逐层后序传播 ──► 每层可做的改写:
        ├ FILTER   : 恒真删 / 恒假→LogicalEmptyResult   (propagate_filter.cpp:328-348)
        ├ JOIN     : 恒假→按类型剪枝;恒真→降级 cross product (propagate_join.cpp:16-81)
        │           条件间统计互收紧 + 反向下推 filter      (:164-192, :348-392)
        ├ AGGREGATE: 聚合函数推导 group/agg 统计           (propagate_aggregate.cpp:475)
        ├ LIMIT    : 基数上界                              (propagate_limit.cpp:6)
        └ PROJECTION: 表达式统计写回 statistics_map         (propagate_projection.cpp:15-21)
        ▼
   statistics_map 交给 MultiStageAggregateRewriter / ProjectionPlacement (optimizer.cpp:466-477)
```

## 5. 其他重点规则精读

**CommonSubExpressionOptimizer**(`src/optimizer/cse_optimizer.cpp`):只处理 PROJECTION 和 AGGREGATE 两个挂点(`:37-47`)。两遍法:`CountExpressions` 用 `expression_map_t` 数出现次数(`:49-95`),CASE/CONJUNCTION 因短路语义只允许最左子树提取 CSE(`:78-89`);`PerformCSEReplacement` 把出现 >1 次的子表达式移进新建 projection、原位换成列引用(`:97-140`),最后把 projection 插为该算子的孩子(`:168-174`)。它之所以单独立 pass 而不进 ExpressionRewriter:它改的是**算子的表达式集合结构**(要新建 projection、分配 table index),超出了"单表达式进单表达式出"的 Rule 模型。

**InClauseRewriter**(`src/optimizer/in_clause_rewriter.cpp`):阈值 6(`src/include/duckdb/optimizer/in_clause_rewriter.hpp:31`)。少于阈值折成 OR/AND 链(`:92-104`),两个元素直接折成等值(`:84-91`);达到阈值且右侧全可折叠时,把常量列表物化为 `LogicalColumnDataGet`(ChunkGet),并在原 plan 上方生成 **MARK join**(`:105-144`),IN 表达式替换为指向 marker 的列引用(`:159-161`)——即"大 IN → mark join",后续 FILTER_PUSHDOWN 的 mark→semi 逻辑可能再接力。

**TopN**(`src/optimizer/topn_optimizer.cpp`):`CanOptimize` 要求 LIMIT 为常量、child 链尽头是 ORDER BY(`:22-64`);并有成本守门:limit > 5000 且超过子基数 0.7% 时放弃,认为全排序更快(`:49-53`)。命中后换成 `LogicalTopN`,还会把排序键下界做成 dynamic filter 推给扫描(`PushdownDynamicFilters`,`:66-120`)。

TopN 与 LIMIT 折叠的守门条件对比(两者都怕"过早上切流水线/改变语义"):

| | 触发前提 | 主动放弃条件 | 行号 |
|---|---|---|---|
| TopN | LIMIT 常量 + OFFSET 非表达式 + 底下是 ORDER BY | limit>5000 且 > 子基数 0.7% | `topn_optimizer.cpp:26-53` |
| Limit 下穿 | LIMIT 常量 < 8192 + 下一层是 PROJECTION | OFFSET 为表达式;带 OFFSET 时 projection 含 volatile | `limit_pushdown.cpp:13-32` |


**Limit 折叠**(`src/optimizer/limit_pushdown.cpp`):仅处理 LIMIT+PROJECTION 相邻;limit 常量 < 8192 才下穿,理由是 physical_limit 会切断并行流水线,小 limit 下的剩余算子不值得并行(`:19-22`);带 offset 时若 projection 含 volatile 表达式则放弃(offset 行提前丢弃会改变 volatile 取值序列,`:23-32`)。

**Deliminator**(`src/optimizer/deliminator.cpp`):related cluster——`IN (SELECT ...)`/相关子查询被 binder 压成 DelimJoin+DelimGet 后,这里负责清理。入口 `Deliminator::Optimize`(`deliminator.cpp:56`)找 DelimCandidate 并按深度排序(`:68-70`);RHS 带 selection 时保留最深的 join(裁剪收益大,`:73-78`);其余 `RemoveJoinWithDelimGet` 逐个拆除(`:81-85`);当所有重复消除列都不再需要时把 DelimJoin 降级为普通 COMPARISON_JOIN(`:88-91`),SINGLE join 在 RHS 被聚合去重后可降为 LEFT(`:93-95`)。

**CTE 与递归 CTE**:
- 非递归 CTE:优化器侧。`CTEInlining::TryInlining`(`src/optimizer/cte_inlining.cpp:148-233`)按引用数决策:0 引用且无副作用直接删除(`:151-158`);1 引用直接内联(`:175-182`);多引用时看 `CTE_MATERIALIZE_NEVER`/含 LIMIT/基数启发(`base_table_references * ref_count > 10` 放弃,`:215-217`)决定拷贝内联或保留物化;副作用 CTE 永不内联(`:160-164`)。CTE_FILTER_PUSHER(:286)、COMMON_SUBPLAN(:416)补齐其余 CTE 优化。
- **递归 CTE 在 planner,不在 optimizer**:`LogicalRecursiveCTE` 由 binder 生成(`src/planner/binder/query_node/bind_recursive_cte_node.cpp`,节点定义 `src/planner/operator/logical_recursive_cte.cpp`),依赖 `recursive_dependent_join_planner`(`src/planner/planner.cpp:23`);优化器对它只做保守保护(如 optimizer.cpp:201-214 的 `CTEContainsDML` 检查会让统计传播/子计划提取整体跳过)。

## 6. LogicalOperator 家族(计划节点清单)

与优化器/执行器衔接的接口(`GetOperandTypes` 等)留给报告 E,这里只列节点。头文件目录 `src/include/duckdb/planner/operator/` 共约 60 个:

- 扫描/取数:`logical_get`(表扫描)、`logical_column_data_get`(ChunkGet)、`logical_dummy_scan`、`logical_delim_get`、`logical_expression_get`、`logical_external_resource`、`logical_positional_join` 之外的样本/读文件由 get 承担;
- 关系代数:`logical_filter`、`logical_projection`、`logical_aggregate`、`logical_distinct`、`logical_order`、`logical_limit`、`logical_top_n`、`logical_sample`、`logical_window`、`logical_unnest`、`logical_pivot`;
- join:`logical_join`(基类)、`logical_comparison_join`、`logical_any_join`、`logical_cross_product`、`logical_unconditional_join`、`logical_dependent_join`(子查询 flattern 的侧产物)、`logical_positional_join`;
- 集合与 CTE:`logical_set_operation`(UNION/EXCEPT/INTERSECT)、`logical_cte`、`logical_cteref`、`logical_materialized_cte`、`logical_recursive_cte`、`logical_empty_result`;
- DDL/DML/杂项:`logical_insert/update/delete/merge_into`、`logical_create*`、`logical_alter/drop/attach/detach/transaction/pragma/set/reset/execute/prepare/explain/copy_to_file/export/vacuum/extension_operator` 等(完整列表见 `list.hpp` 汇总头)。

## 7. EXPLAIN 可见性:树渲染而非"计划序列化快照"

本基线中没有名为 `PlanSerializable` 的组件;EXPLAIN 的可见性来自两条通道:

1. **逻辑计划的树渲染**:`LogicalOperator::ToString`(`src/planner/logical_operator.cpp:181-189`)把 plan 包成 `RenderTree` 再交给 `TreeRenderer`/`StringTreeRenderer` 输出;每个节点的参数行由虚函数 `ParamsToString` 提供(`src/include/duckdb/planner/logical_operator.hpp:70`)。
2. **物理计划的 `Serialize`**:每个 LogicalOperator 可序列化(`logical_operator.hpp:82`),物理计划同理;EXPLAIN 输出在 `PhysicalPlanGenerator::CreatePlan(LogicalExplain&)` 组装(`src/execution/physical_plan/plan_explain.cpp:12-73`):优化前 plan 存在 `LogicalExplain` 里,优化后 plan 在物理规划前用 `ToString` 抓下来(`:19-22`),按 `explain_output` 设置输出 `logical_plan / logical_opt / physical_plan` 三行(`:37-49`);EXPLAIN ANALYZE 则换成 `PhysicalExplainAnalyze`(`:24-28`)。join order 优化器还专门把 EXPLAIN 自身的估计基数固定为 3(`src/optimizer/join_order/join_order_optimizer.cpp:125-127`)。

## 7.5 调试与可观测性钩子

- 单 pass 开关:`SET disabled_optimizers='...'` 写进 `disabled_optimizers` 集合,`OptimizerDisabled` 逐 pass 查询(`optimizer.cpp:121-132`);总开关 `enable_optimizer` 关闭时 `Optimize` 直接返回原 plan(`optimizer.cpp:557-559`)。
- 计时:每个 pass 在 `QueryProfiler` 里以 `optimizer.<小写名>` 为键计时(`optimizer.cpp:143-147`),EXPLAIN ANALYZE 可见。
- DEBUG 断言:表达式规则注册后检查每条规则的 `root` 匹配器非空(`optimizer.cpp:109-114`);每个 pass 后跑 `LogicalPlanVerifier`(`optimizer.cpp:148-150`,入口 `:153-155`)。
- join order 专用:`PRAGMA force_no_cross_product` 强制含 cross product 的计划报错,检查点在 SolveJoinOrder 出口三处(`plan_enumerator.cpp:569,599-614`);`approximate_join_order_threshold` 可调 DP/贪心切换点(`settings.hpp:320-332`)。
- 统计验证:`debug_verify_stats` 开启时把传播得到的统计挂到表达式的 verification stats 上(`statistics_propagator.cpp:165-167`)。

## 8. 设计动机(选读)

1. **为什么规则固定顺序而非 cascade/memo?** DuckDB 定位嵌入式 OLAP,优化要在毫秒级完成。ExpressionRewriter 的规则列表顺序即优先级、命中即重试(`expression_rewriter.cpp:22-44`),结构性 pass 更是一次单向流水线(`optimizer.cpp:229-543`),没有分支搜索与 memo 状态;代价是改 pass 顺序需谨慎(如 CSE 在 join order 之后、统计传播之前),收益是行为可预测、易调试(每个 pass 独立开关 + verifier)。
2. **为什么 DP+贪心混合?** DPhyp 虽是最先进的 DP,但最坏仍是指数;`pairs >= 10000` 强制退出(`plan_enumerator.cpp:243-247`)加关系数 ≥12 直走近似(`settings.hpp:320-332`),保证大查询编译时间有上界;而贪心失败时还能"原样返回原 plan"(`join_order_optimizer.cpp:96-100`),把正确性兜底做到极致。
3. **为什么统计内嵌 BaseStatistics 而非独立统计目录?** 统计沿 `statistics_map`(列绑定→BaseStatistics)与算子同步传播(`statistics_propagator.cpp:47-114`),min/max/null 能力直接随 filter/join 条件收紧(`propagate_filter.cpp:89-160`)。挂在同一棵树上传,免维护独立 catalog 快照,也天然兼容无统计的对象(返回 nullptr 即"不知道",改写自动退化为保守)。代价是统计对象生命周期与计划绑定(见 optimizer.cpp:453-464)。
4. **为什么 pushdown 家族按算子拆文件?** 每个算子的"谓词能否穿过、怎么改写列绑定"都是独立知识:aggregate 要查 grouping set 覆盖(`pushdown_aggregate.cpp:70-84`),projection 要处理 volatile/抛错/计算表达式保留(`pushdown_projection.cpp:163-176`),join 要按 join type 分七个子情形(`filter_pushdown.cpp:184-212`)。一算子一文件让每个文件只回答一个问题,新增算子只加一个 `PushdownXxx` + 一个 case。
5. **为什么 CSE 单独成 pass?** Rule 模型是"单表达式→单表达式"的纯函数改写;CSE 要在**兄弟表达式之间**共享结果,必须新建 projection、生成 table index、改写多个绑定(`cse_optimizer.cpp:161-174`),且与列生命周期(COLUMN_LIFETIME 紧随其后,:400)有明确的先后契约。
6. **为什么 filter 先 pullup 再 pushdown 两个 pass?** 先 `FILTER_PULLUP`(:267)把谓词拉出 projection/union 分支,合并后由 `FILTER_PUSHDOWN`(:273)统一按全局最优路径下放;pullup 让 "WHERE 套子查询" 与 "ON 条件" 归一成同一份 filter 集合,避免每个算子各自实现合并逻辑。
7. **为什么 join order 排在 pushdown/CSE 之前、统计传播之后仍能成立?** JoinOrderOptimizer 自带图内 filter 分配(`query_graph_manager.cpp:179-181` 的 `ExtractEdges`)与基数估计(`join_order_optimizer.cpp:120-123`),不依赖后置 pass;而统计传播被刻意放很晚(optimizer.cpp:457),因为 join 重排会整棵重建子树,过早传播的统计会失效——重排后再做一轮"能改写计划"的传播,收益最大、浪费最小。
8. **为什么统计改写要二次清理列?** 统计传播删条件、删 join 条件是"顺手"行为,会在扫描里留下无人引用的列;optimizer.cpp:492-500 的注释明确说"statistics propagation removes filters, join conditions and aggregate children that it proves redundant",因此 `removed_expressions` 为真时重跑 `UNUSED_COLUMNS` + `COLUMN_LIFETIME`,保证交给物理规划器的计划最小。

## 9. 写作素材清单(文件:行号)

1. `src/optimizer/optimizer.cpp:71-107` — ExpressionRewriter 全部表达式规则注册顺序
2. `src/optimizer/optimizer.cpp:229-543` — 结构性 pass 流水线全文(逐 pass 行号见本文 §0)
3. `src/include/duckdb/optimizer/rule.hpp:17-32` — Rule 抽象(root 匹配器 + Apply)
4. `src/optimizer/expression_rewriter.cpp:52-81` — 自底向上规则应用循环
5. `src/optimizer/rule/like_optimizations.cpp:14-24` + `:132-171` — LIKE→prefix/contains/等值 改写
6. `src/optimizer/filter_pushdown.cpp:108-163` — FilterPushdown::Rewrite 分派状态机
7. `src/optimizer/pushdown/pushdown_projection.cpp:149-195` — 穿 project 下推(含 volatile 例外)
8. `src/optimizer/pushdown/pushdown_aggregate.cpp:38-104` — 穿 aggregate/grouping set 下推
9. `src/optimizer/pushdown/pushdown_mark_join.cpp:59-99` — MARK→SEMI/ANTI 转换
10. `src/optimizer/pushdown/pushdown_cross_product.cpp:43-64` — filter 合并成 join 条件
11. `src/optimizer/join_order/plan_enumerator.cpp:237-251` — DP 对数预算(10000)与退出
12. `src/optimizer/join_order/plan_enumerator.cpp:568-616` — SolveJoinOrder:精确/近似/兜底
13. `src/optimizer/join_order/query_graph_manager.cpp:170-204` — 超图构建五步
14. `src/include/duckdb/main/settings.hpp:320-332` — approximate_join_order_threshold 默认 12
15. `src/optimizer/statistics/operator/propagate_join.cpp:16-81` — 恒真/恒假 join 剪枝与降级
16. `src/optimizer/statistics/operator/propagate_filter.cpp:315-352` — filter 恒真删除/恒假 empty_result
17. `src/optimizer/cse_optimizer.cpp:142-175` — CSE 两遍法与 projection 注入
18. `src/optimizer/in_clause_rewriter.cpp:105-144` — 大 IN → ChunkGet + MARK join
19. `src/execution/physical_plan/plan_explain.cpp:19-49` — EXPLAIN 的 logical_opt/physical_plan 组装
