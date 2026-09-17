# 报告 C:SQL 解析与绑定 —— 自研 PEG 解析器与 Binder

> 基线 commit `7e886f44428e90c8379d4d34e2afb866108ff079`(下称"本主干")。所有 `文件:行号` 均经实际 Read/Grep 核对。
> 本报告聚焦"从 SQL 字符串到 BoundStatement"的完整链路;与报告 A 重叠的执行入口细节从简。

## 1. 一条 SQL 的完整流水(总览图)

```text
  "SELECT name FROM t WHERE id = ?;"
   │ NormalizeSQLString: UTF-8 校验 + Unicode 空格剥离   src/parser/parser.cpp:229-237, 67-78
   ▼
  Tokenizer ──► vector<MatcherToken>(token 文本/类型/偏移)   src/parser/peg/tokenizer/parser_tokenizer.cpp
   │ Parser::ParseQuery: 逐语句循环, 每轮剥一个 TopLevelStatement   src/parser/parser.cpp:273-291
   ▼
  PEG 文法匹配(packrat 记忆化)
   │ grammar.TopLevelStatementMatcher().MatchParseResult(state)   src/parser/peg/transformer/peg_transformer_factory.cpp:72-76
   │ 匹配器递归执行 ExecuteRecursive + packrat 缓存查询   src/parser/peg/matcher.cpp:24-31, src/parser/peg/parser_packrat.cpp:15-18
   ▼
  ParseResult 树(ListParseResult / ChoiceParseResult / OptionalParseResult / …)   src/parser/peg/transformer/parse_result.hpp
   │
   ▼
  Transformer(PEGTransformerFactory)
   │ 按 REGISTER_TRANSFORM 注册表把 ParseResult 逐规则转成 duckdb AST   src/parser/peg/transformer/peg_transformer_factory.cpp:126, 153-160
   │ 规则 → ParsedExpression / QueryNode / SQLStatement   src/parser/peg/transformer/transform_*.cpp(约 44 个文件)
   ▼
  unique_ptr<SQLStatement>(SelectStatement / InsertStatement / …)   src/include/duckdb/parser/statement/
   │ ClientContext::Query(string) → PendingQueryInternal → PendingStatementInternal   src/main/client_context.cpp:1114-1216, 961-980
   ▼
  Planner::CreatePlan → Binder::Bind(SQLStatement)   src/planner/planner.cpp:147-158, src/planner/binder.cpp:78-142
   │ 查 catalog(entry_retriever)+ bind_context:名字解析 / 类型推导 / 表发现
   │ ParsedExpression → BoundExpression;TableRef → LogicalOperator
   ▼
  BoundStatement{ plan, types, names }   src/include/duckdb/planner/bound_statement.hpp:32-37
   │ 优化器 → 物理计划 → Executor   src/main/client_context.cpp:522-543
   ▼
  PendingQueryResult
```

要点:parse 与 transform 在本主干中是**两个独立阶段**——先由匹配器对 token 流跑完整个文法、在内存里留下带类型的 ParseResult 树,再由 transformer 以"按规则名查注册表"的方式把它翻译成 AST。`TransformTopLevelStatement` 先匹配(`peg_transformer_factory.cpp:76`),失败则用最深 token 位置报语法错(`:79-94`),成功后把游标推进过已消费 token(`:99`)再进入 transformer(`:120-123`)。

## 2. PEG 解析器(src/parser/peg/)

### 2.1 目录组成

| 部分 | 文件 | 职责 |
|---|---|---|
| 文法源 | `src/parser/peg/grammar/statements/*.gram`(41 个) | 每类语句一个文法文件(select.gram、insert.gram…),common.gram 放公共规则 |
| 关键字表 | `src/parser/peg/grammar/keywords/*.list`(5 个) | reserved/unreserved/column_name/func_name/type_name 五类(README.md:129-139) |
| 生成物 | `inlined_grammar.hpp`、`keyword_map.cpp` | 由 `scripts/parser/build_grammar.sh` 调 `inline_grammar.py` 内联生成(README.md:143-162),"不要手改" |
| 词法 | `tokenizer/parser_tokenizer.cpp`、`highlight_tokenizer.cpp` | 前者服务解析,后者服务 IDE 高亮(`Parser::Tokenize`,parser.cpp:362-398) |
| 匹配 | `matcher.cpp`、`matcher_process.cpp`、`matcher_stack.cpp`、`parser_packrat.cpp` | 文法规则的运行期匹配引擎 + packrat 记忆化 |
| 文法对象 | `parsed_grammar.cpp`、`compiled_grammar.cpp`、`peg_parser.cpp` | `.gram` 文本 → ParsedGrammar → CompiledGrammar;peg_parser.cpp:8-19 里还有一个用 C++ 写的"解析文法的文法"(PEGToken/PEGExpressionParser) |
| 翻译 | `transformer/peg_transformer_factory.cpp` + 44 个 `transform_*.cpp` | ParseResult → AST |
| 扩展 | `grammar_change.cpp`、`autocomplete_core.cpp`、`sql_formatter.cpp` | 运行期增删文法规则、自动补全、SQL 格式化 |

自述见 `src/parser/peg/README.md:1-3`:"PEG (Parsing Expression Grammar) system used by DuckDB's autocomplete extension"——文法系统起源于自动补全扩展,后被扶正为主解析器。

### 2.2 文法写法:select.gram 节选

```text
# src/parser/peg/grammar/statements/select.gram:1-2, 28, 41-42
SelectStatement <- SelectStatementInternal
SelectStatementInternal <- WithClause? SelectSetOpChain ResultModifiers?
SimpleSelect <- SelectFrom WhereClause? GroupByClause? HavingClause? WindowClause? QualifyClause? SampleClause?
SelectClause <- 'SELECT' DistinctClause? TargetList?
TargetList <- List(AliasedExpression)
```

写法要点(README.md:9-115):
- `Rule <- 定义`,`'…'` 为大小写不敏感关键字字面量(README.md:19-25);
- `/` 是**有序选择**,首个成功者胜,无歧义回溯;因此"更长的候选必须放前面",如 `YEAR TO MONTH` 要先于 `YEAR`(README.md:29-36);
- `?` `*` `+` 语义同正则;`List(D)`/`Parens(D)` 是 common.gram:195-196 定义的参数化规则(宏):`List(D) <- D (',' D)* ','?`、`Parens(D) <- '(' D ')'`;
- 特殊 token(`Identifier`、`StringLiteral`、`NumberLiteral` 等)不走文法展开,由 matcher.cpp 直接识别(README.md:105-115);
- 负向前瞻 `!` 已能写进文法但**匹配器目前忽略之**,README.md:99-103 明说 "Negative lookahead is parsed but currently ignored by the matcher. TODO"。

select.gram 里还有一处体现 PEG 取舍的注释:select.gram:107-109 解释 `NEAREST BY` 为什么拆成 bare/aliased 两个候选——裸形式用"无别名目标镜像"先试,避免未别名目标把 `NEAREST` 贪婪吃成表别名。这正是有序选择文法里典型的"手工消歧"。

再看表达式文法的头部:

```text
# src/parser/peg/grammar/statements/expression.gram:1, 7, 29, 34, 40
ColumnReference <- NestedSchemaTableColumnName / CatalogReservedSchemaTableColumnName / ...
FunctionExpression <- FunctionIdentifier FunctionExpressionArguments WithinGroupClause? FilterClause? ExportClause? OverClause?
LiteralExpression <- StringLiteral / NumberLiteral / ConstantLiteral
CastExpression <- CastOrTryCast Parens(CastArguments)
StarExpression <- StarQualifierList? '*' ExcludeList? ReplaceList? RenameList?
```

注意:表达式**没有**用优先级阶梯(无 `AddExpression <- MulExpression ('+' MulExpression)*` 这类写法),`Expression` 的优先级由 expression.gram 后文的链式规则承担;`ColumnReference` 的五个候选把 catalog/schema/table 限定的各种保留字组合全部枚举出来(expression.gram:1-6)——把"名字解析"的一部分从 binder 提前到了文法层,这是与 libpg_query 文法思路很不一样的地方。

### 2.3 解析入口

入口是 `Parser::ParseQuery`(src/parser/parser.cpp:239-309):先做扩展 parser_override 抢答(`:241-269`),然后 tokenizer 全量切词(`:273-277`),再循环调 `ParseTopLevelStatement`(`:354-360`)。核心循环如下:

```cpp
// src/parser/parser.cpp:270-291(节选)
// PEG parser: tokenize, then peel one TopLevelStatement at a time. On per-statement PEG
// failure, hand the rest of the query to parse_function extensions; the extension reports
// how many bytes it consumed and we advance the token cursor past them.
auto owned_tokens = make_uniq<vector<MatcherToken>>();
ParserTokenizerBehavior behavior(query, *owned_tokens);
auto &tokenizer = GetGrammar().GetTokenizer();
tokenizer.TokenizeInput(behavior);
TokenIterator token_iterator(std::move(owned_tokens));
while (token_iterator.Current()) {
    try {
        auto stmt = ParseTopLevelStatement(token_iterator);
        if (stmt) {
            statements.push_back(std::move(stmt));
        }
    } catch (ParserException &e) {
        auto ext_stmt = TryParseExtensionStatement(token_iterator, query);
        ...
    }
}
```

每轮 `ParseTopLevelStatement`(parser.cpp:354-360)做两件事:对剩余 token 流跑一次 `TopLevelStatement` 匹配,然后立即 transform 成一条 SQLStatement——即"匹配一条、翻译一条",而不是先匹配完整脚本。注释(parser.cpp:270-272)说明了容错设计:某条语句 PEG 失败后,把剩余 token 流交给 parse_function 扩展,扩展报告消耗的 token 数,游标随之推进——这就是 `TryParseExtensionStatement`(parser.cpp:311-352)。最后统一回填每条语句的 `stmt_location` 与 `query` 文本(parser.cpp:293-308),CREATE 语句还会把原文存进 `info->sql`(`:303-306`)。

关键字分类不再走 PG 的 kwlist,而是由生成的查找表驱动:`Parser::ToKeywordCategory`(parser.cpp:542-558)依次查 reserved/unreserved/type_func/column_name 四类(`DuckDBKeywordHelper::Instance()` 封装 keyword_map.cpp 的生成表);这解释了文法里 `PlainIdentifier <- !ReservedKeyword <[a-z_]i[a-z0-9_]i*>`(README.md:99)这类"标识符 vs 关键字"的判定如何落地。

`CompiledGrammar::Create`(src/parser/peg/compiled_grammar.cpp:122, 149)负责把内联文法编译成匹配器树;扩展可在 `Create(grammar_extensions)` 时注入自己的 `.gram`(编译期),也可运行期用 `GrammarChange::AddRule/AddChoice/…`(src/parser/peg/grammar_change.cpp:7-34)动态增删规则。

### 2.4 与 libpg_query 的差异与迁移动机

本仓库已无 libpg_query:`third_party/` 无 pg_query 目录,全文 grep 仅剩一处陈旧文本 `src/README.md:4` 还写着 "DuckDB uses the parser of Postgres (libpg_query)"——该 README 未随解析器切换更新,不可作为现状依据。**未发现正式迁移说明文档**(浅克隆无 git 历史,代码注释亦无),以下为代码结构推断,依据有四:
1. 文法按语句拆成 `.gram` + 关键字 `.list`,经脚本生成(README.md:141-162),扩展(如 autocomplete)可携带自己的语法增量,而 PG 文法是单文件 LALR,外部扩展极难叠加;
2. `GrammarChange`(grammar_change.cpp:7-34)提供了运行期 ADD/REMOVE/REPLACE 规则的 API,这只有自研 PEG 才做得动;
3. parser 扩展契约改为 **token 流**:扩展收到 `simple_tokens` 并报告 `consumed_tokens`(parser.cpp:316-349),比旧 `parse_function(query string)` 的纯文本交接更精确;
4. 语法错误定位直接基于 token 迭代器的最深失败位置(peg_transformer_factory.cpp:79-94),不再依赖 PG 的 `LOCATION` 机制。

PEG vs LR 的取舍在代码里也可见代价:有序选择需要手工排候选(select.gram:107-109、README.md:36),packrat 缓存(parser_packrat.cpp:15-18)用来抑制回溯开销;换来的是文法可拆分、可扩展、匹配器与 AST 生成彻底解耦。

## 3. Transformer:ParseResult → duckdb AST

### 3.1 机制

每条文法规则对应一个 `PEGTransformerFactory::Transform<RuleName>`;`REGISTER_TRANSFORM` 宏把函数名去掉 `Transform` 前缀得到规则名并注册(peg_transformer_factory.cpp:126,README.md:227-238)。典型的手写 transformer(README.md:188-209)四步:Cast 成 `ListParseResult` → 按下标取子结果 → 递归 `transformer.Transform<T>` → 拼 AST。

本主干还引入了**生成式 typed wrapper**:`scripts/parser/generate_transformer.py` 依据 `scripts/parser/grammar_types.yml` 为规则生成强类型签名的 trampoline(transform_generated.cpp,注册表在其 :12324 附近),手写体只需实现"业务构造"函数,README.md:164-186 对此有完整说明。以 SELECT 为例,注册表声明哪些规则仍保持手写(peg_transformer_factory.cpp:153-160):

```cpp
// src/parser/peg/transformer/peg_transformer_factory.cpp:153-160
void PEGTransformerFactory::RegisterSelect() {
    // select.gram rules that remain manual after generated wrappers are registered.
    Register("SelectStatementInternal", &TransformSelectStatementInternalRule);
    REGISTER_TRANSFORM(TransformSimpleSelect);
    REGISTER_TRANSFORM(TransformTableRef);
    REGISTER_TRANSFORM(TransformWithClause);
    REGISTER_TRANSFORM(TransformWindowDefinition);
}
```

### 3.2 SELECT 的转换链

`SelectStatementInternal <- WithClause? SelectSetOpChain ResultModifiers?`(select.gram:2)对应 `TransformSelectStatementInternalRule`(transform_select.cpp:55-92):CTE 先转出并 `push_back` 到 `transformer.stored_cte_map`(`:59-62`)使其对内部子句可见,随后递归转换 select 链与结果修饰符,最后把 cte_map 挂回 `select_statement->node->cte_map`(`:67-71`)。叶子方向:`SimpleSelect`(select.gram:28)→ `TransformSimpleSelect`(transform_select.cpp:268 起)拼 `SelectNode`;`SelectClause`(select.gram:41)→ `TransformSelectClause` 把 DISTINCT 转成 `DistinctModifier`、目标列装进 `select_list`:

```cpp
// src/parser/peg/transformer/transform_select.cpp:1428-1446(节选)
unique_ptr<SelectNode>
PEGTransformerFactory::TransformSelectClause(PEGTransformer &transformer, optional<DistinctClause> distinct_clause,
                                             optional<vector<unique_ptr<ParsedExpression>>> target_list) {
    auto result = make_uniq<SelectNode>();
    if (distinct_clause && distinct_clause->is_distinct) {
        auto distinct_modifier = make_uniq<DistinctModifier>();
        ...
        result->modifiers.push_back(std::move(distinct_modifier));
    }
    ...
    for (auto &expr_ptr : *target_list) {
        result->select_list.push_back(std::move(expr_ptr));
    }
    return result;
}
```

`SelectFrom` 缺省时补 `EmptyTableRef`(transform_select.cpp:1397-1406);`FROM` 在前、`SELECT` 在后的 `FromSelectClause`(select.gram:32)由 `TransformFromSelectClause` 兜底补 `SELECT *`(transform_select.cpp:1408-1420)。产物是 `SelectStatement{node: SelectNode}`,成员均为 `ParsedExpression`/`TableRef` 族的未绑定 AST。

### 3.3 INSERT 的转换链

文法一行(insert.gram:1):`InsertStatement <- WithClause? 'INSERT' OrAction? 'INTO' InsertTarget ByNameOrPosition? InsertColumnList? InsertValues OnConflictClause? ReturningClause?`。生成的 trampoline `TransformInsertStatementInternal`(transform_generated.cpp:7580-7623)按序取出各子结果后调用手写的 `TransformInsertStatement`(transform_insert.cpp:9-54):设置 `node.qualified_name`、`column_order`、`columns`,处理 `DEFAULT VALUES` 与 select 子查询(`:25-34`),并把 `OR REPLACE|IGNORE` 归一成 `OnConflictInfo`(`:36-49`)。文法与构造函数一一对应,是 typed wrapper 思路的样板。

## 4. Statement 家族

基类 `SQLStatement`(src/include/duckdb/parser/sql_statement.hpp:26-38)携带 `type`、`named_param_map`、`has_anonymous_parameters` 等。子类头文件位于 `src/include/duckdb/parser/statement/`(30 个,另有 list.hpp 索引):select、insert、update、delete、create、drop、alter、copy、copy_database、transaction、pragma、explain、prepare、execute、call、set、load、attach、detach、export、vacuum、extension、logical_plan、merge_into、connect、disconnect、external_resource、update_extensions、relation、multi。`Binder::Bind(SQLStatement&)` 按 `StatementType` 分派到 30+ 个 `Bind(XxxStatement&)` 重载(binder.cpp:78-142)。一个有趣的归一:文法里有独立的 `CheckpointStatement <- CheckpointForce? 'CHECKPOINT' CatalogName?`(inlined_grammar.gram:800),但 transformer 把它降糖成 `CallStatement` 挂一个 checkpoint 函数表达式(transform_checkpoint.cpp:11-13),没有专门的 Statement 子类。

## 5. Binder:入口链与名字解析

### 5.1 总入口链

```cpp
// src/planner/planner.cpp:147-158(节选)
void Planner::CreatePlan(SQLStatement &statement) {
    auto parameter_count = statement.named_param_map.size();
    BoundParameterMap bound_parameters(parameter_data);
    ...
    binder->SetParameters(bound_parameters);
    auto bound_statement = binder->Bind(statement);
    ...
    this->names = bound_statement.names;
    this->types = bound_statement.types;
    this->plan = std::move(bound_statement.plan);
```

调用链:`ClientContext::Query(string)`(client_context.cpp:1114)逐语句走 `PendingQueryInternal` → `PendingStatementInternal`(client_context.cpp:961-980)→ `CreatePreparedStatement`(:548-592,含注册态请求 rebind 时的"先试绑副本"逻辑 :552-570)→ `CreatePreparedStatementInternal`(:480-546,内部 :498 调 `Planner::CreatePlan`,:541-543 生成物理计划)。注意旧版的 `PendingStatementOrPreparedStatement` 已不存在,现由 `PendingStatementInternal` + `PendingPreparedStatementInternal`(:634-684)两段组成:前者"绑计划",后者"参数落值 + 起 Executor"。

绑定失败时 Planner 还有两层兜底:参数类型未解抛 `PARAMETER_NOT_RESOLVED` 则标记 `bound_all_parameters=false` 返回(planner.cpp:169-173, :208);其他异常交给 OperatorExtension::Bind 尝试(:174-190)。绑定成功后做 dependent-join 善后:`RewriteTriggersToDependent`/`RecursiveDependentJoinPlanner::Plan`/`FlattenDependentJoins::DecorrelateIndependent`(planner.cpp:199-201)。

### 5.2 Binder 层次

`Binder::CreateBinder(context, parent, binder_type)` 构造子 binder 并从父继承:catalog 入口检索器 `entry_retriever`、宏/lambda 参数绑定 `macro_binding`/`lambda_bindings`、活动作用域 `active_binders`(binder.cpp:55-76)。深度受 `max_expression_depth` 限制(binder.cpp:41-53)。子查询作用域由 `BeginSubqueryBind/FinishSubqueryBind` 管理:子 binder 继承的 active_binders **整体替换**而非追加,避免每层嵌套让作用域链按 2^depth 膨胀(binder.cpp:271-282 的注释)。

### 5.3 名字解析(表别名/列限定/USING)

核心函数是 `ColumnQualifier::QualifyColumnName`(src/planner/column_qualifier.cpp:140-193),顺序为:
1. **USING 列**:命中 `GetUsingBinding` 时,若有 primary_binding 直接改写成该表列,否则改写成对各表该列的 `COALESCE`(column_qualifier.cpp:142-158)——USING 集合在 join 绑定时登记(bind_joinref.cpp:304-320;USING/NATURAL 的比较条件是在各自 binder 里"边绑边构造"的,见 bind_joinref.cpp:29-40 注释);
2. **lambda 参数**(列表推导/lambda 体):column_qualifier.cpp:162-165;
3. **普通列**:`bind_context.GetMatchingBinding(column_name, expr)` 找"含此列的表绑定"(column_qualifier.cpp:168);表级限定别名经 `BindContext::GetBinding(alias, column)` 匹配(src/planner/bind_context.cpp:388-416,同名歧义在 :323-386 汇报候选);
4. **宏参数**:与 `macro_binding` 冲突即报错或绑定(column_qualifier.cpp:172-182);
5. 都失败时用 `GetSimilarBindings` 给出 "did you mean" 错误(column_qualifier.cpp:190-191)。

带表限定符 `t.c` 的解析入口则是 `Binder::GetMatchingBinding(alias, column, error)`(binder.cpp:341-367):先让宏绑定抢答,再落 `bind_context.GetBinding`。

### 5.4 表绑定:CTE → catalog → replacement scan

`Binder::Bind(BaseTableRef&)`(src/planner/binder/tableref/bind_basetableref.cpp:142 起)依次:查 CTE(`GetCTEBinding`,:150-171,命中则产 `LogicalCTERef` 并 `ctebinding->Reference()` 防环)→ 查 catalog(`entry_retriever.GetEntry`,:175-182)→ EXTRACT_NAMES 模式造 dummy 表(:184-206)→ replacement scan 兜底(:207 起,"table could not be found: try to bind a replacement scan",即 `FROM 'file.csv'` 这类扩展名落地处)。CTE 上溯逻辑值得单独看:

```cpp
// src/planner/binder.cpp:198-219(节选)
optional_ptr<CTEBinding> Binder::GetCTEBinding(const BindingAlias &name) {
    reference<Binder> current_binder(*this);
    optional_ptr<CTEBinding> result;
    while (true) {
        auto &current = current_binder.get();
        auto entry = current.bind_context.GetCTEBinding(name);
        if (entry) {
            // we only directly return the CTE if it can be referenced
            // if it cannot be referenced (circular reference) we keep going up the stack
            if (entry->CanBeReferenced()) {
                return entry;
            }
            result = entry;
        }
        if (!current.parent || current.binder_type != BinderType::REGULAR_BINDER) {
            break;
        }
        current_binder = *current.parent;
    }
    return result;
}
```

`GetCTEBinding` 沿 binder 父链上溯,只返回"可引用"的 CTE,循环引用(自引用中的右侧尚未就绪)的 CTE 会被跳过继续向上找(binder.cpp:198-219);视图则靠 `AddBoundView` 在整条 binder 链上查重防无限递归(binder.cpp:221-231)。

## 6. 表达式绑定

### 6.1 分派与 BoundExpression 家族

`ExpressionBinder::BindExpression(ParsedExpression&, …)` 按 `ExpressionClass` switch 分派(src/planner/expression_binder.cpp:53-89)。产物是 `BoundExpression` 家族(src/include/duckdb/planner/expression/ 下 bound_columnref/bound_function/bound_subquery/bound_parameter 等 20+ 头文件)。各子句配了专门 binder:`src/include/duckdb/planner/expression_binder/` 下 21 个(where/group/having/order/projection/insert/update/returning/constant/lateral…),保证不同子句有各自的合法表达式校验。

### 6.2 ColumnRef → BoundColumnRef

路径:`BindExpression(ColumnRefExpression&)`(bind_columnref_expression.cpp:71-96)先 `QualifyColumnName` 做限定与改写(上一节);未命中时尝试 SELECT 别名 `TryResolveAliasReference` 与 SQL 值函数(`current_date` 等,:82-93),再 `BindInEnclosingScope` 向外层作用域找(:95,相关列机制随后把外层列记入 `correlated_columns`)。真正落到绑定的是已限定的列引用(bind_columnref_expression.cpp:120-131):

```cpp
// src/planner/binder/expression/bind_columnref_expression.cpp:127-131
if (binder.macro_binding && table_name == binder.macro_binding->GetAlias()) {
    result = binder.macro_binding->Bind(col_ref, depth);
} else {
    result = binder.bind_context.BindColumn(col_ref, depth);
}
```

`BindContext::BindColumn`(src/planner/bind_context.cpp:456-469)取别名对应 binding 后调 `binding->Bind(colref, depth)` 产出 `BoundColumnRefExpression`(表 index + 列 index),同时把列记入 `bound_columns` 供外层相关列判断(bind_columnref_expression.cpp:138-142)。

### 6.3 别名引用与 SQL 值函数

裸列名在当前作用域落空时还有两条隐蔽出路(bind_columnref_expression.cpp:80-95):一是 `IsPotentialAlias` 时尝试 `TryResolveAliasReference`(:84,SELECT 别名在同级子句如 ORDER BY/HAVING 中的复用,配套 `ColumnAliasBinder`,头文件见 expression_binder/column_alias_binder.hpp);二是 `GetSQLValueFunction`(:89-92)把 `current_date`、`current_timestamp` 这类"裸词"改写成零参函数调用——实现于 `ColumnQualifier` 的辅助(column_qualifier.cpp:22-23, :59-71),名字转成 `current_date()` 等函数后再走普通函数绑定。这两条规则决定了 `SELECT x AS y ... ORDER BY y` 与 `SELECT current_date` 都能通过 binder,而它们在文法层都只是普通 `ColumnReference`(expression.gram:1)。

### 6.4 函数名解析与重载选择

`ExpressionBinder::BindFunction`(bind_function_expression.cpp:256-277)先 `qualifier.QualifyFunction` 按 catalog search path 找函数条目;找不到时反查 table function 集合,命中则给出"这是表函数,请放到 FROM"的专属错误(:262-271)。随后按 catalog 类型分派(:296-324):scalar → `BindFunction`;macro → `BindMacro` 展开;aggregate → 特殊处理"参数所属层级"(:308-317,聚合归属最内层能解析其参数的查询层级,否则上抛到外层);window → `BindWindow`。重载选择最终交给 `FunctionBinder::BindScalarFunction` → `BindFunctionFromArguments`(src/function/function_binder.cpp:337, 380-434),按位置/命名参数与候选签名的最大公共类型打分选最优。

## 7. 子查询、CTE 与宏的绑定

**子查询**:`BindExpression(SubqueryExpression&)` 为每个子查询 `Binder::CreateBinder(context, binder)` 建子 binder(继承作用域),`SetInsideSubquery` 后 `BeginSubqueryBind` 把当前 expression binder 压入作用域栈,再 `BindNode` 绑子查询(bind_subquery_expression.cpp:62-73);depth>1 的相关列在减一后转记到外层 binder(:75-84)。产出的 `BoundSubqueryExpression` 甚至把子 binder 一起携带(`result->GetBinderMutable() = std::move(subquery_binder)`,:177),供后续 plan 阶段去相关使用。

**CTE**:transformer 阶段 CTE 已存入 `QueryNode::cte_map`(3.2 节);bind 时 `Binder::BindNode(QueryNode&)` 遍历 cte_map,对每个 CTE 调 `PrepareCTE` 并把 `child_binder` 链式下传——即每个 CTE 一层子 binder(bind_cte_node.cpp:35-54);递归 CTE 的 recurring 表靠 `GetCTEBinding(BindingAlias("recurring", ctename))` 在右侧子 binder 中引用(bind_recursive_cte_node.cpp:257-261)。带 `USING KEY` 的 CTE 列在 select.gram:33-37 定义。

**宏**:标量/表宏在 bind 期展开。`UnfoldMacroExpression`(bind_macro_expression.cpp:169-202):先 `MacroFunction::BindMacroFunction` 在重载集合中选宏并校验参数(:175-179),再 `CreateDummyBinding` 造一个"宏参数→实参"的假绑定(:182-184),把表达式整体替换成宏体拷贝(:186-192),然后用只认识 macro_binding 的 dummy binder 做限定(:194-197),`ReplaceMacroParameters` 换元后重新 `BindExpression`(:204-213)。窗口宏还要把窗口规格下推进宏体内唯一聚合(bind_macro_expression.cpp:125-167)。表宏走 `binder/query_node/bind_table_macro_node.cpp` 同套路。

## 8. Prepared statements 与参数绑定

**`?`/`$n` 的表示**:解析期是 `ParameterExpression`(AST);transformer 把命名参数登记进 `SQLStatement::named_param_map`(sql_statement.hpp:36;peg_transformer_factory.cpp:28-32 统一回填),匿名参数则置 `has_anonymous_parameters`(sql_statement.hpp:38)。bind 期 `BindExpression(ParameterExpression&)`(bind_parameter_expression.cpp:12-51):若参数值已随 EXECUTE 带入则直接产 `BoundConstantExpression`+cast(:16-33);PREPARE 模式之外还允许**回落到同名用户变量**(:35-44);否则 `parameters->BindParameterExpression(expr)` 产 `BoundParameterExpression` 占位,类型由首次约束它的表达式回填(Planner 收尾时对未定型参数置初值并进 value_map,planner.cpp:213-223)。

**PREPARE/缓存**:PREPARE 走 `Planner::PrepareSQLStatement`(planner.cpp:226-241):先以 `BindingMode::PREPARE` 复制语句完整试绑一次,把 names/types/value_map/properties 存进 `PreparedStatementData`,未绑定语句保留在 `unbound_statement`。缓存按名字挂在连接上:`ClientData::prepared_statements`(src/include/duckdb/main/client_data.hpp:39);API 层 `PreparedStatement` 析构时自动 `RemovePreparedStatement`(src/main/prepared_statement.cpp:17-24)。

**EXECUTE 的运行期 bind**:`Binder::Bind(ExecuteStatement&)`(src/planner/binder/statement/bind_execute.cpp:16-110):按名查缓存(:22-25);把实参(常量直接取类型,非常量表达式求值,:42-68)灌进 bind_values;`prepared->RequireRebind(context, bind_values)`(:73-75)判断是否需要重绑——判据包括 `always_require_rebind`、参数从未定型、**catalog 身份(版本)变化**(prepared_statement_data.cpp:107-134,对读写过的数据库逐一 `CheckCatalogIdentity`);需重绑则现绑一份新计划并让 `LogicalExecute` 带着新旧两套(:83-108)。最终 `prepared->Bind` 把实参按目标类型 cast 后 `SetValue` 写回占位符(prepared_statement_data.cpp:138-167);API 路径则由 `PendingPreparedStatementInternal` 开头统一调 `BindPreparedStatementParameters`(client_context.cpp:599-610, :640)。API 侧 `PreparedStatement::Execute` 把 values 变成 1-based 命名参数(`"1"、"2"…`,prepared_statement.cpp:125-131),并构造 `ExecuteStatement` 复用统一管道,且把 `query` 字段改回原查询以便报错定位(prepared_statement.cpp:96-106)。

## 9. 设计动机

1. **为什么自研解析器取代 libpg_query**:扩展语法(autocomplete、`FROM 'file.csv'`、`NEAREST JOIN` 等)需要能随版本演进的文法;PG 的单文件 LALR 文法无法按语句拆分、难以被扩展注入。本主干把文法做成 41 个语句/公共 `.gram` + 5 个关键字表 + 生成脚本(README.md:141-162),并提供 `GrammarChange` 运行期改文法 API(grammar_change.cpp:7-34),扩展可以自带规则增量——这些在 libpg_query 架构下基本不可行。(注:仓库内未见正式迁移说明,判断依据见 2.4 节四条;`src/README.md:4` 的 libpg_query 表述已过时。)
2. **PEG 相比 LR 的取舍**:有序选择 + 回溯换来"文法可组合、可增量扩展、报错点即最深失败 token"(peg_transformer_factory.cpp:79-94);代价是候选顺序敏感(select.gram:107-109 的 NEAREST 手工消歧、README.md:36)、指数回溯风险需 packrat 缓存压制(parser_packrat.cpp:15-18)。
3. **为什么 parse 与 transform 分离**:匹配器只负责"结构是否匹配并留下带类型的 ParseResult 树",AST 构造由按规则名注册的 transformer 承担,于是文法改动与 AST 构造解耦;typed wrapper(generate_transformer.py + grammar_types.yml)进一步把"按下标取子节点"的样板自动化,手写体只留语义构造(transform_generated.cpp:7580-7623)。
4. **为什么 bind 要 catalog/事务感知**:名字到条目的解析必须经由带事务与版本的 catalog(`Binder::entry_retriever` 继承自父 binder,binder.cpp:62-65;表查找走 `entry_retriever.GetEntry`,bind_basetableref.cpp:181-182)。prepared statement 缓存的正确性直接依赖这一点:EXECUTE 时用 `CheckCatalogIdentity` 比对所依赖数据库的版本,变了就整体重绑(prepared_statement_data.cpp:124-134, bind_execute.cpp:83-91),否则可能执行在已被 DDL 改掉的表结构上。
5. **为什么 prepared statement 缓存值得做**:解析+绑定+优化是每查询的固定开销;缓存以 `unbound_statement` + value_map 保存"半成品",EXECUTE 只需 `prepared->Bind` 落参数值即可复用物理计划(prepared_statement_data.cpp:138-167);同时用 `RequireRebind` 的多重判据(always_rebind / 参数未定型 / catalog 版本 / 参数类型漂移)在复用与正确性间取平衡(prepared_statement_data.cpp:96-136)。
6. **为什么作用域用 active_binders 栈而非仅靠 binder 父链**:聚合归属(哪个层级的列就归哪层聚合,bind_function_expression.cpp:308-317)、相关列上抛(bind_subquery_expression.cpp:75-84)都需要"最内层作用域"概念;`BeginSubqueryBind` 用整体替换防止嵌套时作用域链指数膨胀(binder.cpp:271-282 注释)。
7. **为什么宏在 bind 期而非 parse 期展开**:宏体是 AST,展开后实参的限定(`t.c` 中的 `t` 是宏外层表名)必须在外层作用域内完成——dummy binder 只带 macro_binding 参与限定(bind_macro_expression.cpp:194-197),parse 期没有 catalog 与作用域信息,做不了这件事。

## 10. 写作素材清单(文件:行号)

1. `src/parser/parser.cpp:239-309` —— ParseQuery 主循环:tokenizer、逐语句 PEG、扩展回退、stmt_location 回填;
2. `src/parser/peg/README.md:29-103` —— PEG 语义说明:有序选择、宏、负向前瞻未实现的 TODO;
3. `src/parser/peg/grammar/statements/select.gram:1-52` —— SELECT 文法全貌(含 NEAREST 消歧注释 :107-109);
4. `src/parser/peg/grammar/statements/expression.gram:1-40` —— 表达式文法头部,ColumnReference 五候选枚举;
5. `src/parser/peg/transformer/peg_transformer_factory.cpp:61-124` —— 匹配 + 语法错误定位 + transformer 启动的顶层函数;
6. `src/parser/peg/transformer/peg_transformer_factory.cpp:126-183` —— REGISTER_TRANSFORM 宏与各 Register 分区;
7. `src/parser/peg/transformer/transform_select.cpp:55-92` —— CTE 可见性与 SelectStatement 装配;
8. `src/parser/peg/transformer/transform_insert.cpp:9-54` —— typed wrapper 之下的 INSERT 构造;
9. `src/parser/peg/grammar_change.cpp:7-34` —— 运行期文法增删改 API(自研解析器的独有能力);
10. `src/README.md:4` —— 陈旧的 libpg_query 表述(写作时的"辟谣"素材);
11. `src/planner/planner.cpp:147-241` —— CreatePlan 全过程与 PrepareSQLStatement;
12. `src/main/client_context.cpp:961-980` —— PendingStatementInternal:一次普通查询的 bind→prepare→pending 链;
13. `src/planner/column_qualifier.cpp:140-193` —— 名字解析决策树(USING/lambda/表列/宏);
14. `src/planner/binder/tableref/bind_basetableref.cpp:142-171` —— CTE/catalog/replacement scan 的表发现顺序;
15. `src/planner/binder/expression/bind_subquery_expression.cpp:62-84` —— 子 binder 创建与相关列上抛;
16. `src/planner/binder/statement/bind_execute.cpp:72-108` —— EXECUTE 的 rebind 判定与 LogicalExecute 装配。
