# E 篇 · PromQL 查询引擎深读

> 调研对象:prometheus/prometheus,commit `b0f312b`(2025,浅克隆)。所有行号以该 commit 为准,仓库相对路径。
> 核心文件:`promql/engine.go`(5007 行)、`promql/parser/`(AST+Yacc 语法+词法)、`promql/functions.go`(2894 行)、`promql/value.go`。

---

## 1. 全景:一条 range query 的生命线

入口链:`web/api` → `Engine.NewRangeQuery`(engine.go:583)→ `query.Exec`(engine.go:267)→ `Engine.exec`(engine.go:710)→ `Engine.execEvalStmt`(engine.go:811)→ `evaluator.Eval`(engine.go:1269)→ `evaluator.eval`(engine.go:2132,按节点类型递归下降)。

```
 promql.Engine.NewRangeQuery("rate(x[5m])", start, end, step)
   │  parser.ParseExpr ──► 词法(lex.go) ──► Yacc(generated_parser.y.go) ──► AST
   │  validateOpts(engine.go:643)      校验 @ 修饰符/负 offset 是否启用
   │  PreprocessExpr(engine.go:4601)   start()/end() 折叠 + StepInvariantExpr 包裹
   ▼
 query.Exec (engine.go:267) ──► ng.exec (engine.go:710)
   │  context.WithTimeout(ng.timeout)            engine.go:718
   │  queueActive → ActiveQueryTracker.Insert    engine.go:763 / 792   (并发闸门)
   ▼
 execEvalStmt (engine.go:811)                     [准备阶段]
   │  FindMinMaxTime(engine.go:978) 算出全局最小/最大时间(含 offset/@/range)
   │  queryable.Querier(mint, maxt)              engine.go:819
   │  populateSeries(engine.go:1095):遍历 AST,对每个 VectorSelector
   │      querier.Select(ctx, false, hints, matchers...)   engine.go:1123
   │      hints = SelectHints{Start,End,Step,Range,Func,Grouping}  engine.go:1109-1115
   ▼
 evaluator{start,end,interval,maxSamples,lookbackDelta,querier}  engine.go:1217
   ▼
 eval(expr) 递归下降(engine.go:2152 的 switch)     [评估阶段]
   │  ┌───────────────── 每个 step(ts = start; ts <= end; ts += interval) ───────────┐
   │  │ rangeEval(engine.go:1473):先一次性 eval 出子表达式的整段 Matrix,          │
   │  │  再按 step 用 gatherVector(engine.go:4933) 抽出该时刻的输入 Vector;         │
   │  │  VectorSelector → evalSeries(engine.go:1911):逐 series 逐 step             │
   │  │    vectorSelectorSingle(engine.go:2811):Seek(ts)→取点→PeekPrev 回看        │
   │  │    lookbackDelta,过滤 stale NaN;                                          │
   │  │  MatrixSelector(函数矩阵参数)→ 逐 series 逐 step:                          │
   │  │    BufferedSeriesIterator 窗口滑动,matrixIterSlice(2997) 增量取 [mint,maxt];│
   │  │  每步调 funcCall(函数实现在 functions.go)→ 输出 Vector;                     │
   │  │  addToSeries(4429) 按 label-hash 追加到输出 Series → 组装输出 Matrix        │
   │  └───────────────────────────────────────────────────────────────────────────┘
   ▼
 sortMatrixResult(engine.go:940) ──► Matrix(v parser.Value) ──► JSON
```

关键心智模型:**准备阶段一次性拉取 series 引用(populateSeries),评估阶段才是逐 step 循环**。instant query 不是独立路径,而是"单步 range query":`s.Start.Equal(s.End) && s.Interval == 0` 时 evaluator 的 interval 置 1ms 只跑一步(engine.go:838-854),最后把 Matrix 摊平成 Vector/Scalar(engine.go:877-891)。

---

## 2. AST 专节:节点清单与解析器生成

### 2.1 解析器怎么生成

- 语法文件 `promql/parser/generated_parser.y`(1404 行,LALR 文法),用 `goyacc` 生成 `generated_parser.y.go`,Makefile 目标在 `Makefile:151`:`goyacc -l -o promql/parser/generated_parser.y.go promql/parser/generated_parser.y`。
- 两个起始符号:`START_EXPRESSION` 与 `START_SERIES_DESCRIPTION`(generated_parser.y:176-182,起始规则 224-227)。`parseGenerated`(parse.go:951)通过 `InjectItem`(parse.go:417)把起始符号注入词法流,再调 `p.yyParser.Parse(p)`(parse.go:954)。
- 词法器是手写的状态机:`stateFn`(lex.go:285)、`Lexer.NextItem`(lex.go:390)、主循环 `lexStatements`(lex.go:418)。
- 公共入口:`ParseExpr`(parse.go:70)→ `parseExpr`(parse.go:196):yacc 产树后若语法无错,做语义检查 `p.checkAST(expr)`(parse.go:207)。parser 实例从对象池取(`parserPool`,parse.go:171)。
- 语义检查示例:`newAggregateExpr`(parse.go:457)校验聚合参数;`newBinaryExpression`(parse.go:430)在未启用实验特性时拒绝 fill 修饰符。

### 2.2 节点类型清单(promql/parser/ast.go)

| 节点 | 行号 | 说明 |
|---|---|---|
| `Node` / `Expr` / `Statement` 接口 | 38 / 77 / 53 | 全部节点要求 `String()/PositionRange()`,Expr 另有 `Type()` |
| `EvalStmt` | 62 | 唯一被 Engine 执行的语句:Expr + Start/End/Interval/LookbackDelta |
| `AggregateExpr` | 91 | sum/avg/topk…:Op、Expr、Param、Grouping、Without |
| `BinaryExpr` | 101 | Op、LHS/RHS、`VectorMatching *VectorMatching`、ReturnBool |
| `DurationExpr` | 114 | 实验性时长运算(如 `5m*2`) |
| `Call` | 124 | Func *Function + Args |
| `MatrixSelector` | 132 | VectorSelector + Range(区间向量,`x[5m]`) |
| `SubqueryExpr` | 142 | Expr + Range/Step/Offset/Timestamp(`x[5m:1m]`) |
| `NumberLiteral` / `StringLiteral` | 163 / 178 | 标量字面量 |
| `ParenExpr` / `UnaryExpr` | 172 / 185 | 括号;一元 +/- |
| `StepInvariantExpr` | 195 | **parser 不产出**,仅 Engine 预处理阶段插入的优化包裹 |
| `VectorSelector` | 206 | Name、LabelMatchers、Offset/Timestamp、`UnexpandedSeriesSet`/`Series`(准备期填充)、Anchored/Smoothed |
| `TestStmt` | 239 | 测试钩子语句,exec 里 switch 到它(engine.go:783) |

各节点 `Type()` 集中在 ast.go:251-267;`BinaryExpr.Type()` 两边都是 Scalar 才是 Scalar,否则 Vector(ast.go:260-265)。

### 2.3 AST 工具函数

- `Walk`(ast.go:350)深度优先遍历,`ChildrenIter`(ast.go:402)用 type-switch(而非接口分发)枚举子节点;`Inspect`(ast.go:396)封装回调式遍历;`ExtractSelectors`(ast.go:370)抽出全部 VectorSelector 的 matchers——web API 就是用它从查询串提取存储选择器。

---

## 3. 评估专节:engine.go 的评估循环

### 3.1 状态与入口

`evaluator`(engine.go:1217)只带 7 个关键字段:`startTimestamp/endTimestamp/interval`(ms)、`maxSamples`、`lookbackDelta`(默认 5m,engine.go:65)、`samplesStats`、`querier`。评估全程用 panic+recover 传播错误:`errorf/error`(1240/1235)panic,顶层 `Eval`(1269)统一 `recover`(1245)转返回值;runtime panic 会打印表达式与栈但包装成普通 error(engine.go:1252-1258)。

### 3.2 rangeEval:多数节点通用的按 step 骨架(engine.go:1473)

分两段。第一段(1481-1495)**先把每个子表达式完整 eval 成 Matrix**(列式:每条 series 一行,行内是按时间排的点);第二段(1564-1634)是主循环:

```go
for ts := ev.startTimestamp; ts <= ev.endTimestamp; ts += ev.interval {   // 1564
    if err := contextDone(ctx, "expression evaluation"); err != nil {    // 1565
        ev.error(err)
    }
    for i := range exprs {                                               // 1571
        vectors[i], bh = ev.gatherVector(ts, matrixes[i], vectors[i], bh, sh)  // 1578
    }
    enh.Ts = ts
    result, ws := funcCall(vectors, nil, bufHelpers, enh)                // 1586
    ...
    for _, sample := range result {   // 1620  按 label hash 并入输出 series
        h := sample.Metric.Hash()
        ... addToSeries(&ss.Series, enh.Ts, sample.F, sample.H, numSteps)  // 1631
    }
}
```

注意方向:**不是"每个 step 重新求值子树",而是"子树各求值一次成 Matrix,step 循环只做裁剪+拼装"**。`gatherVector`(4933)在每 step 从各行 Matrix 里挑出时间戳等于 ts 的点组成 Vector。instant query 在循环里有捷径:若 `endTimestamp == startTimestamp` 直接返回单点 Matrix(1602-1617)。每步都检查 `currentSamples > maxSamples`(1597),超限报 `ErrTooManySamples`(engine.go:103)。

### 3.3 VectorSelector 的执行:select → expand → 逐点 peek

三段式:
1. **select(准备期)**:`populateSeries`(1095)对树中每个 VectorSelector 调 `querier.Select(..., hints, matchers...)`(1123),把 series 引用存进 `UnexpandedSeriesSet`;hints 由 `getTimeRangesForSelector`(1027)算:无 range 时起点多退一个 lookbackDelta(1047-1051),有 range 时按 Range/anchored/smoothed 扩窗(1055-1073)。
2. **expand(评估期惰性)**:`checkAndExpandSeriesSet`(1164)把 SeriesSet 摊开成 `[]storage.Series` 缓存到 `e.Series`,每个 selector 只做一次(span 只建一次,1164-1184)。
3. **逐 step 取点**:`evalSeries`(1911)对每条 series 用 `MemoizedSeriesIterator`(1916)在 step 网格上循环(1929),核心是 `vectorSelectorSingle`(2811):

```go
refTime := ts - durationMilliseconds(offset)          // 2814
valueType := it.Seek(refTime)                         // 2819
...
if valueType == chunkenc.ValNone || t > refTime {     // 2834
    st, t, v, h, ok = it.PeekPrev()                   // 2836 回看最近一个旧点
    if !ok || t <= refTime-durationMilliseconds(ev.lookbackDelta) {
        return 0, 0, 0, nil, false                    // 2837 超 lookback 视为无点
    }
}
if value.IsStaleNaN(v) ... { return ... false }       // 2841 stale 标记丢弃
```

即 instant vector 语义 = "≤ ts 的最近一个样本,且不能旧于 lookbackDelta(默认 5m);stale NaN 显式断流"。

### 3.4 MatrixSelector(函数矩阵参数)的执行

函数带 `[5m]` 参数时走 eval 里 `*parser.Call` 分支的另一条路(engine.go:2270-2455):**外层按 series、内层按 step** 双重循环(2339/2374),用 `storage.NewBuffer(bufferRange)`(2322)滑动窗口;`matrixIterSlice`(2997)只从 buffer 增量读取新点、丢弃滑出 `[mint,maxt]` 的旧点(3004-3017 线性 drop),所以 `rate(x[5m])` 全程每个样本只被读约一次,而不是每步重读整窗。`it.ReduceDelta(stepRange)`(2454)从第二步起收缩 buffer。取到的窗口打成单行 `inMatrix` 传给函数闭包 `call(vectorVals, inMatrix, e.Args, enh)`(2431)。

### 3.5 @ 修饰符与 offset(engine.go 简述)

- `@ ts`/`@ start()`/`@ end()`:`preprocessExprHelper`(4623)在预处理期把 start()/end() 折成具体时间戳(4627-4631);`setOffsetForAtModifier`(4741)把 `@` 换算成等效 offset 写进每个 selector 的 `Offset` 字段(4760-4767)——之后评估期只剩一种机制:取点时 `refTime = ts - offset`。带 `@` 的 MatrixSelector 整窗只取一次(`refetch` 判断,2390)。
- `offset 1h`:parser 记为 `OriginalOffset`,评估时同样进 `Offset`(evalSeries 1935 / matrixSelector 2918-2920)。
- `start()/end()/range()/step()` 查询上下文函数在 `foldQueryContextFunctions`(4554)折叠成 NumberLiteral。

### 3.6 Subquery(简述)

`x[5m:1m]` 在 `*parser.Call` 分支里被**物化为等价的 MatrixSelector**:`evalSubquery`(2083)先用子 evaluator 按子查询自己的步长把内层表达式跑完(2035 `runSubquery`,时间范围由 `subqueryTimeRange`(2005)对齐父步长网格计算),再把结果 Matrix 包装成 `VectorSelector+MatrixSelector` 挂回 AST(2088-2102,`NewStorageSeries`)。无显式 step 时用 `NoStepSubqueryIntervalFn`(默认按全局 interval,engine.go:330)。顶层直接是子查询时走 eval 的 `*parser.SubqueryExpr` 分支(2635)。

---

## 4. 二元运算匹配专节:on/ignoring/group_left/group_right

### 4.1 数据结构

`VectorMatching`(ast.go:309):`Card`(基数)、`MatchingLabels`、`On`、`Include`(group_x 的附加标签)、`FillValues`(fill() 实验)。基数四值 `CardOneToOne/CardManyToOne/CardOneToMany/CardManyToMany`(ast.go:286-291)。Yacc 里 `group_left` → `CardManyToOne`,`group_right` → `CardOneToMany`(generated_parser.y:347/353)。

### 4.2 签名(join signature)预处理(engine.go:1520-1562)

rangeEval 在进入 step 循环前,为每条 series 算一个签名序号 `sigOrdinal` 存入 `EvalSeriesHelper`(1280-1288):`on(...)` 用 `BytesWithLabels(排序后的匹配标签)`(1529-1531);ignoring 语义则是 `BytesWithoutLabels({__name__}+被忽略标签)`(1533-1537)。签名相同的 series 共享同一序号——每 step 的匹配退化为**按整数序号对位**,而不是每步重算字符串哈希。

### 4.3 VectorBinop:一对一/多对一主流程(engine.go:3272)

```go
if matching.Card == parser.CardOneToMany {   // 3284
    lhs, rhs = rhs, lhs                      // 3285 一对多翻转成多对一
    lhsh, rhsh = rhsh, lhsh
}
for i, rs := range rhs {                     // 3294 rhs("一"侧)建对位表
    sigOrd := rhsh[i].sigOrdinal
    if rightSigsPresent[sigOrd] { ... errorf("found duplicate series ... many-to-many matching not allowed") }  // 3298-3312
    rightSigs[sigOrd] = rs
}
for i, ls := range lhs {                     // 3398 lhs("多"侧)逐个查表
    sigOrd := lhsh[i].sigOrdinal
    if rightSigsPresent[sigOrd] { rs = rightSigs[sigOrd] } else { continue/fill }
    doBinOp(ls, rs, sigOrd)
}
```

要点:
- **多对一(group_left)合法、一对多先翻转、多对多 panic**(3273-3274,"many-to-many only allowed for set operators");`and/or/unless` 走独立的 `VectorAnd/VectorOr/VectorUnless`(3196/3219/3246),因为它们不合并值只做集合运算。
- **"一"侧必须唯一**:rhs 同签名出现两条直接报错(3298-3312);一对一模式下 lhs 两条匹配到同一 rhs 报 "multiple matches for labels: many-to-one matching must be explicit"(3362-3365);多对一模式下结果标签集不唯一报 "grouping labels must ensure unique matches"(3367-3381)。
- **结果标签**:`resultMetric`(3444)——一对一时保留 on 标签/删掉 ignoring 标签(3467-3473),多对一时保留 lhs 标签并从"一"侧拷入 `Include` 标签(3474-3481);比较/算术运算按 `changesMetricSchema` 决定是否删 `__name__`(3462)。结果按 (lhs,rhs) 字节串缓存避免重复构造(3445-3458)。
- `vectorElemBinop`(3569)做逐点数值运算并决定 keep(比较运算不满足则丢点);`returnBool` 时输出 0/1 且全保留(3350-3357)。`VectorscalarBinop`(3489)处理向量与标量。
- fill 值旁路:一侧无匹配时可用 `matching.FillValues.RHS/LHS` 造虚拟样本参与运算(3405-3415/3420-3437,实验特性)。

### 4.4 聚合(engine.go:1653/3701)

`sum by (job)` 类聚合先在 `rangeEvalAgg`(1653)把每条输入 series 映射到输出组:`generateGroupingKey`(4484,xxhash)分组、`seriesToResult` 定长数组记录映射(1671-1690),然后 step 循环里 `aggregation`(3701)对每组做增量累积(SUM 用 Kahan 求和 3814,AVG 用增量均值,直方图有 counter-reset hint 合并逻辑 3794-3807);topk/bottomk/limitk/limit_ratio 走 `aggregationK`(4071)。`count_values` 独立为 `aggregationCountValues`(4293)。

---

## 5. 设计动机

**为什么按 step 评估、列式(Matrix)中转?**
PromQL 的语义天然定义在"每个时间戳上的即时向量"(文档化于 EvalStmt.Interval,ast.go:68)。引擎把子表达式一次性算成整段时间序列(Matrix,列式布局,value.go:312),step 循环只做"列转行"的裁剪(gatherVector),好处:(a) 每个 selector 的 series 只在准备期 Select 一次,chunk 级迭代器可跨 step 复用(BufferedSeriesIterator 滑窗,matrixIterSlice 增量读);(b) `EvalNodeHelper`(1291)的哈希表/Builder 等缓存按节点跨 step 复用,签名计算等重活提到循环外(1520-1562);(c) 输出按 label-hash 聚成 Series,天然就是 API 要返回的矩阵。

**为什么 pull 表达式树(递归下降)而非流水线(火山/推拉)?**
`eval` 是一棵树上的普通递归函数(2152 的 switch),父节点调子节点的 `eval` 拿整段 Matrix 再加工。对比无/短流水线的收益:查询是一次性批处理,不需要逐行拉取的短路能力;树式求值让优化(prepocess 阶段包 `StepInvariantExpr`,4623)只改树结构,不用改执行协议。代价是 subquery 结果要整体物化(所以有 2225 处"subquery result takes space in the memory"的显式清理)。

**step 不变量优化**:`StepInvariantExpr`(ast.go:195)在 `PreprocessExpr` 里包裹与评估时刻无关的子树(如 `abs(metric @ 3000)`、纯标量运算),eval 时只在第一步求一次再复制时间戳(engine.go:2645-2707)。这是"先求值整段再按 step 切"模型的进一步压缩。

**超时与取消**:exec 用 `context.WithTimeout(ctx, ng.timeout)`(718)派生 ctx;树递归的每层入口、每个 step 循环、每条 series 迭代前都调 `contextDone`(278),把 `context.Canceled/DeadlineExceeded` 翻译成 `ErrQueryCanceled/ErrQueryTimeout`(285-294)。取消是协作式的:检查点足够密(ms 级),单点计算本身不可中断。`query.Cancel`(252)持有 cancel 供 API 层主动取消。

**并发控制**:`query.max-concurrency`(默认 20,cmd/prometheus/main.go:647)传入 `NewActiveQueryTracker`(query_logger.go:158)——一个 mmap 文件 + 容量为 maxConcurrent 的 channel;`Insert`(237-250)从 channel 领槽位,**满了就阻塞**(可被 ctx 取消),因此 exec 在真正评估前先 `queueActive` 排队(763/792)。mmap 文件同时充当"崩溃时活跃查询"审计日志。样本上限 `query.max-samples`(默认 5 千万,main.go:648-650)由 evaluator 在每步累加检查(maxSamples,1597 等)。

**与 TSDB 的衔接**:engine 只依赖 `storage.Queryable/Querier` 接口;`SelectHints`(storage/interface.go:209)把查询形状告诉存储层——Start/End(扩窗后的)、Step、Range、Func(外层函数名,extractFuncFromPath engine.go:1134)、Grouping/By。TSDB 据此做 chunk 裁剪与索引选择优化的提示(tsdb/querier.go:170 的 blockQuerier.Select 接收 hints),`Func == "series"` 等特殊值还能改变行为。hints 是纯提示,实现可忽略。

---

## 6. FAQ 素材与深挖线索

### FAQ(写作素材,8-10 条)

1. **instant query 是 range query 吗?** 是。Start==End 且 Interval==0 时,interval 被置为 1ms 只评估一个 step(engine.go:838-854),最后把矩阵摊平成 Vector/Scalar(877-891)。
2. **instant vector 为什么"5 分钟前的点"还能查到?** `vectorSelectorSingle` 的 PeekPrev + lookbackDelta 逻辑(2834-2840):回看最近样本,只要不旧于 lookbackDelta(默认 5m,engine.go:65)就用它。
3. **`rate(x[5m])` 86400 个点的图会读 86400×5m 的样本吗?** 不会。`matrixIterSlice`(2997)用滑动 buffer 增量取点,旧窗口的样本直接复用,每样本约读一次;统计口径上每 step 仍计"整窗"样本数(fullWindowCount,2411),`SamplesRead` 只计新点(2417-2424)。
4. **两个向量相乘是怎么对上的?** 签名(匹配标签的哈希)在 step 循环外算一次(1520-1562),每步用整数序号对位(3290-3316/3398-3418);"一"侧签名重复即报 many-to-many 错误。
5. **`group_left` 和 `group_right` 方向记不住?** 修饰符名指"哪一侧是多数侧"。group_left=左多右一(实现里翻转成 rhs 为"一"侧,3284-3287);Include 标签永远从"一"侧拷入结果(3474-3481)。
6. **为什么 `sum by (job)` 每步不用重新哈希分组?** 分组映射(seriesToResult/groupingKey)在 rangeEvalAgg 开头一次性算好(1675-1690),step 循环里 `aggregation` 只做数值累积(3708 起)。
7. **查询超时了,正在跑的 chunk 读取会被杀掉吗?** 不会立刻;是协作式取消——在树入口/step/series 粒度检查 ctx(1565、1920、2340 等), granularity 最细到 ms 级 step。
8. **并发 20 是怎么实现的?** 不是 worker 池,而是 channel 容量闸门:ActiveQueryTracker 的槽位 channel 满时 `Insert` 阻塞(237-250),查询在评估前排起队,还顺便留下 mmap 活跃查询日志。
9. **subquery `[5m:1m]` 会物化多大?** 子 evaluator 按 1m 步长把整段算完存内存,再包成内存中的 MatrixSelector(2083-2128);用完在 defer 里置 nil 释放(2223-2227)。这就是子查询吃内存的根源。
10. **promqltest 是什么?** 一门"load/eval"文本测试语言(promql/promqltest/README.md),`RunBuiltinTests`(test.go:165)把 testdata 下的 `.test` 用例跑在任何实现 `promql.QueryEngine` 的引擎上——Thanos/Mimir 等以此验证兼容性;`RunTest`(191)跑自定义脚本。

### 深挖线索(3-5 条)

1. **`StepInvariantExpr` 的包裹判定**:`preprocessExprHelper`(4623)如何沿树自底向上判定、以及 `AtModifierUnsafeFunctions`(4656 引用)这一例外清单——`timestamp()` 需要按参数递归特判(4658-4661)。
2. **点切片对象池**:fPointPool/hPointPool/matrixSelectorHPool(2847-2856)与 `reuseOrGetFPointSlices`(2729)如何让 range query 的每步输出零分配复用——性能章节的好素材。
3. **native histogram 的端到端路径**:聚合里的 counter-reset hint 合并(3794-3807)、subquery 结果强制改写 hint 为 UnknownCounterReset(2103-2125)、`detectHistogramStatsDecoding`(4778)让 histogram_count/sum 只解码统计量不解码桶。
4. **anchored/smoothed 扩展区间选择器**(实验):evalSeries/matrixSelector/getTimeRangesForSelector 三处的 mint/maxt/bufferRange 特殊分支(1052-1073、2294-2302、2928-2936)。
5. **@ 修饰符的完整偏移代数**:`subqueryTimes`(950,子查询叠加 offset/range、@ 重置累加)与 `setOffsetForAtModifier`(4741)联合推出的最终 Offset——可以出一道"求 `metric @ end() offset -1m` 在子查询内的取值时间"的计算题。

---

## 写作要点速查表(函数 → 行号,commit b0f312b)

| # | 位置 | 内容 |
|---|---|---|
| 1 | promql/parser/ast.go:62/91/101/124/132/142/206 | EvalStmt/AggregateExpr/BinaryExpr/Call/MatrixSelector/SubqueryExpr/VectorSelector |
| 2 | promql/parser/ast.go:309-334 | VectorMatching(Card/MatchingLabels/On/Include/FillValues) |
| 3 | promql/parser/parse.go:951-956 | parseGenerated:注入起始符号后调 yyParser.Parse(goyacc 产物) |
| 4 | promql/parser/generated_parser.y:347/353 | group_left→CardManyToOne / group_right→CardOneToMany |
| 5 | promql/engine.go:562/583/605 | NewInstantQuery/NewRangeQuery/newQuery(构造 EvalStmt) |
| 6 | promql/engine.go:710-788 | Engine.exec:WithTimeout(718)、queueActive(763)、语句分发(780-785) |
| 7 | promql/engine.go:811-938 | execEvalStmt:Querier(819)、instant=单步(838)、range evaluator(901-916) |
| 8 | promql/engine.go:1095-1130 | populateSeries:querier.Select + SelectHints(1109-1123) |
| 9 | promql/engine.go:1473-1651 | rangeEval:step 主循环 1564,gatherVector 1578,funcCall 1586 |
| 10 | promql/engine.go:1911/2811 | evalSeries(step 网格)/vectorSelectorSingle(Seek+PeekPrev+lookback) |
| 11 | promql/engine.go:2374-2455 | 矩阵参数函数:series×step 双循环,matrixIterSlice(2997) 增量窗口 |
| 12 | promql/engine.go:3272-3440 | VectorBinop:翻转(3284)、对位表(3294)、重复检测(3298/3362/3378) |
| 13 | promql/engine.go:3444-3486 | resultMetric:on/ignoring 标签裁剪 + Include 拷贝 |
| 14 | promql/engine.go:1653/3701/4071 | rangeEvalAgg(分组映射 1675)/aggregation/aggregationK |
| 15 | promql/engine.go:2005/2035/2083 | subqueryTimeRange/runSubquery/evalSubquery(物化为 MatrixSelector) |
| 16 | promql/engine.go:4601/4623/4741 | PreprocessExpr/preprocessExprHelper(StepInvariant)/setOffsetForAtModifier |
| 17 | promql/engine.go:278-294/302-315 | contextDone/contextErr(超时=DeadlineExceeded);QueryTracker 接口 |
| 18 | promql/query_logger.go:158/237 | NewActiveQueryTracker/Insert(容量 channel 阻塞限流,默认 20) |
