# 第 05 章 · PromQL 引擎:两阶段评估与向量匹配

> 基线:commit `b0f312b`。行号以 promql/engine.go、promql/parser/ 为准。

## 5.0 全景:一个 range query 的执行

```
解析(parser:手写词法 lex.go:418 + goyacc 生成,Makefile:151)
  → AST(12 类节点,ast.go:62-239)
  → 准备期:populateSeries 每选择器 querier.Select(带 SelectHints :1109-1115,调用 :1123)
  → 评估期:rangeEval 的 step 主循环(engine.go:1473 起,:1564)
      每 step:gatherVector 列转行 → 函数闭包/运算 → 按 label-hash 并入输出
```

**两阶段**:准备期一次性选定所有 series(带时间提示),评估期才逐 step 循环——IO(选 series)与 CPU(算点)分离。**instant query 不是独立路径**:Start==End && Interval==0 时 interval 置 1ms 单步执行再摊平(:838,:1564)。

## 5.1 向量选择器与滑动窗口

`vectorSelectorSingle`(:2811-2844):Seek(ts)+PeekPrev+lookbackDelta(5m)+**stale NaN 过滤**——instant vector 语义的全部(06 章 stale 的消费端)。带区间参数的函数(rate 等)走 **series×step 双循环+BufferedSeriesIterator 滑动窗口**,matrixIterSlice 增量取点(:2997)——每样本约只读一次(统计口径每步计整窗)。subquery 物化为内存中的 MatrixSelector(:2083)——**内存开销的根源之一**。StepInvariantExpr 在预处理期包裹 @ 修饰符子树只算一次。

## 5.2 二元运算的向量匹配

签名(on 标签/__name__+ignoring 标签的哈希)**在 step 循环外算一次**,每步按整数序号对位。`VectorBinop`(:3272):"一"侧(rhs)建对位表且签名必须唯一(重复即 many-to-many 报错 :3298);**group_right(一对多)先翻转为多对一**(:3284);resultMetric 一对一时 on 保留/ignoring 删除匹配标签,多对一时从"一"侧拷入 Include 标签(:3444);and/or/unless 走独立集合运算,many-to-many 仅限集合运算。

## 5.3 并发与超时

`query.max-concurrency`(默认 20,main.go:647)由 **ActiveQueryTracker.Insert 的容量 channel 阻塞**实现(query_logger.go:237);超时经 context.WithTimeout(:718)翻译为 ErrQueryTimeout/ErrQueryCanceled(:285-294)。

## 5.4 设计动机

1. **为什么按 step 评估**:range query 的语义就是"每个时间点各算一次 instant"——按步评估是语义的直接翻译,优化(滑动窗口/StepInvariant)是局部加速不改模型;
2. **pull 表达式树而非流水线**:每步从子节点"拉"矩阵——简单可调试;代价是子查询物化内存(:2083);
3. **签名循环外置**:匹配哈希与 step 无关——一次计算每步复用;
4. **并发上限用 channel**:容量 channel 的阻塞即限流(对照 PG ActiveQueryTracker 思路同族)——Go 惯用法。

## 5.5 FAQ

**Q1:instant query 会比 range 快吗?**
同表达式走同一 range 路径(:838),只是 1 步——快在步数少。

**Q2:lookbackDelta 是什么?**
5 分钟:instant vector 找"最近样本"的回看窗(:2811-2844);stale NaN 截断它。

**Q3:group_left/group_right 怎么选?**
多对一 group_left/一对多 group_right(:3284 翻转):方向即"多"侧的位置。

**Q4:两个向量有重复标签组合会怎样?**
many-to-many 报错(:3298):除非用集合运算。

**Q5:@ 修饰符为什么快?**
StepInvariantExpr 包裹只算一次——预处理期的公共子表达式消除。

**Q6:rate() 为什么用滑动窗口?**
(:2997):窗口内样本增量读取,每样本只碰一次。

**Q7:查询并发 20 的排队行为?**
容量 channel 阻塞(query_logger.go:237):第 21 个查询等待而非失败。

**Q8:子查询的内存问题?**
物化为 MatrixSelector(:2083):大范围+高分辨率=内存爆炸。

**Q9:SelectHints 的作用?**
(:1109-1115):给 TSDB 的时间范围提示,减少无关块打开(03 章)。

**Q10:PromQL 解析器为什么手写词法?**
lex.go:418: PromQL 词法含嵌套括号/字符串转义的特殊性——手写更可控;yacc 只做语法。

## 5.6 小结与深挖方向

本章结论:**PromQL="两阶段评估+step 语义直接翻译+向量匹配签名制+反馈给 TSDB 的 hints"**。深挖:

1. StepInvariantExpr 的识别(:预处理)在嵌套函数的覆盖;
2. matrixIterSlice(:2997)在窗口>样本间隔的重复读;
3. many-to-many 报错(:3298)的用户体验与文档;
4. 查询 channel 阻塞对 web handler 池的传导;
5. subquery 物化(:2083)的流式化改造前景。

> 下一章(卷末):抓取流水线与工程文化。
