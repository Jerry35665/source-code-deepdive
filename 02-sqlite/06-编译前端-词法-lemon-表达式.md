# 第 06 章 · 编译前端:词法、lemon 文法与"克制"的常量折叠

> 基线:SQLite 3.54.0,commit `492e7fc`。行号均以该版本源码为准。
> 全局定位:SQLite **没有"优化后的执行计划树"这一中间层**——前端在解析的同时直接把 AST 翻译成 VDBE 字节码,优化器内嵌在代码生成流程中(第 07 章)。每次 prepare(含内部语句重准备)都重新跑一遍优化,因此没有计划缓存,优化器复杂度被刻意控制在毫秒级。

```
SQL 文本
  │ sqlite3RunParser()                          tokenize.c:600
  ├─ sqlite3GetToken(): 词法(字符类表 + 完美哈希)  tokenize.c:273
  ├─ lemon 生成的 LALR(1) 引擎                    parse.y
  │     归约动作直接构造 AST: Select/SrcList/Expr/With
  │     顶层语句归约完 → sqlite3FinishCoding()     parse.y:176
  ├─ SELECT 路径 → sqlite3Select() 主流程(带编号大纲, select.c:7638-7670)
  │     SelectPrep(展开*/CTE) → 名字解析 → FROM 优化(外连接削减/扁平化)
  │     → 复合 SELECT → 常量传播 → 子查询落地 → 聚合/非聚合代码生成
  └─ 输出: Vdbe 程序(一次 prepare 内完成全部编译)
```

## 6.1 词法:字符类 + 单趟 switch

`sqlite3GetToken()`(tokenize.c:273)对首字节查 `aiClass[]` 字符类表(31 类),再 switch 到对应分支一次读出整个 token。**为什么用字符类而不是直接对字符 switch**:小整数的 switch 会被编译成跳转表,对 0~255 的字符 switch 会退化成二分查找(tokenize.c:21-28)。

四个细节:

1. **关键字只识别一次入口**:首字母属 CC_KYWD 类才调 `keywordCode()`——由 `tool/mkkeywordhash.c` 生成的完美哈希(tokenize.c:137-148);非关键字直接返回 TK_ID;
2. **数字后跟标识符字符是语法错误**(循环吃掉并改 TK_ILLEGAL,493-497);数字可插入分隔符(SQLITE_DIGIT_SEPARATOR),出现即成 TK_QNUMBER(443-459)——近年新增的字面量可读性特性;
3. **注释不是空白而是独立 token**(TK_COMMENT,696-702),JSON 的 `->`/`->>` 在 CC_MINUS 分支合成 TK_PTR;
4. **参数标记四类前缀全归 TK_VARIABLE**:`?`/`?123`(CC_VARNUM)与 `:name`/`@name`/`#name`/`$name`(CC_VARALPHA/CC_DOLLAR,509-538)。该分支还特判两件兼容事:TCL 风格 `$var(index)` 一路吃到 `)`,PG 风格 `::` 合并进 token。

**词法层唯一的"向前看"是窗口函数三词**:WINDOW/OVER/FILTER 既可能是关键字也可能是普通标识符,lemon 的 `%fallback` 处理不了这种二义性(tokenize.c:216-228 注释给了反例),于是 tokenizer 对这三个 token 做二次前瞻:`OVER`/`FILTER` 要求前一个 token 是 `)`,`WINDOW` 要求"下一个是标识符、再下一个是 AS"(246-266)。

驱动循环 `sqlite3RunParser()` 两个协议细节:输入末尾补发 TK_SEMI 再补发 0(保证语句正确归约,674-684);amalgamation 编译时解析器对象直接放栈上(`ENGINEALWAYSONSTACK`),省一次堆分配。

## 6.2 parse.y 与 lemon:为嵌入场景特制的 LALR(1)

lemon 与 yacc/bison 的关键差异在 parse.y 头部一览无余:没有 `%union`,语义值默认统一为 Token,按非终结符用 `%type select {Select*}` 逐个覆盖,并配 `%destructor` 使错误路径内存自动释放(parse.y:36-37、531)。**错误处理被完全关闭**:`#define YYNOERRORRECOVERY 1`(parse.y:76)——语法错即放弃,不做错误恢复,为嵌入场景的体积与确定性服务。

lemon 特有的三个机制在文法里大量使用:

- **`%fallback ID ...`**(parse.y:272-295):把 ABORT、IF、ROW、MATERIALIZED 等几十个"非保留字"声明为可回退成标识符——消灭了传统 SQL 文法里庞大的 `identifier: IDENT | non_reserved_keyword` 产生式;
- **`%wildcard ANY`**(parse.y:296):虚拟表模块参数的任意 token 吞噬;
- **`scanpt` 非终结符**(parse.y:374-382):归约时把"下一个 token 的起始指针"作为语义值传播,两条 scanpt 之间的原文被原样截取(DEFAULT 子句保留原始文本,parse.y:390-407)——lemon 文法里少见的"文本切片"技巧。

**Token 编号被当作性能调优手段**:parse.y:263-267 用前置 `%token` 声明强制把跳转类操作符编号靠前、EQ/NE/GT/LE 相邻(注释指出 ISNULL/NOTNULL、NE/EQ、GT/LE、GE/LT 必须只差 1——`sqlite3ExprIfFalse()` 的代码生成依赖这个约定);WINDOW/OVER/FILTER 的声明放文件末尾保证编号最大,tokenizer 用 `tokenType>=TK_WINDOW` 快速分流。

**代表性产生式**:复合 SELECT 生成**右倾斜链**(新 Select 的 pPrior 指向左侧,parse.y:623-648),右侧若是复合体则先包一层 FROM 子查询;`@OP` 语法把终结符的 token 类型直接变成 Expr.op。信息量最大的是 IN 家族(parse.y:1491-1560):`x IN ()` 折叠为 true/false 常量(左值含函数时保留为 AND/OR 以防聚合语义误判);`x IN (单一常量)` 改写成 `x = ?`;行向量 `(a,b) IN (SELECT...)` 变成 VALUES 子查询;LIKE/MATCH 是"中缀函数"——操作数反序进 ExprList,NOT LIKE 外面包 TK_NOT。

## 6.3 Expr 结构与克制的常量折叠

Expr 定义在 sqliteInt.h:3071-3133:`op`(复用 TK_ 编号)、flags(EP_* 位)、`u.zToken/iValue`、`pLeft/pRight`、`x.pList|pSelect` 联合体;`iTable` 存 VDBE 游标号、`iColumn` 存列号(-1 为 rowid)。两个"瘦身"位:EP_TokenOnly/EP_Reduced 允许把结构截断到只保留前几个字段——复制出的临时表达式省内存。

**SQLite 的常量折叠非常克制**,核心三类:

- true/false 字面量化(`sqlite3ExprIdToTrueFalse`,expr.c:2352-2363);
- AND/OR 恒真恒假消去(`sqlite3ExprSimplifiedAndOr`,2383-2403;`sqlite3ExprAnd` 有一侧 EP_IsFalse 时直接生成常量 0,1158-1175);
- `字面量 IS NULL` 的文法级折叠(parse.y:1385-1446)。

**没有**通用的"3+4 折叠成 7"式求值器——数值常量表达式留给代码生成期一次性求值(`sqlite3ExprCodeRunJustOnce`,expr.c:5901)。判断"常量"的通用机制是 Walker 回调 `exprNodeIsConstant`(2560-2649),用 eCode 区分五种口径(纯常量/排除外连接 ON 项/表常量/允许确定性函数)。

真正大量产出常量的地方在 select.c 的**常量传播**:`findConstInWhere()` 收集 AND 顶层 `COLUMN=常量` 项(四道防线:亲和性/BINARY collation/子类型等),然后给查询里所有同列引用打 **EP_FixedCol** 标记而非改写表达式树。注释用 `b=a` vs `b=123` 的反例解释了为什么(select.c:4977-5011)——TEXT 亲和下两者不等价。**语义安全优先于改写的彻底性**,这是典型的 SQLite 式折中。

名字解析(resolve.c):`lookupName` 内层向外遍历 NameContext,`cnt>1` 且列不在 USING 列表中即"ambiguous column name"(resolve.c:439-448);内层命中即停止,外层同名列被遮蔽——这与多数数据库的作用域直觉一致。

## 6.4 FAQ

**Q1:SQLite 用递归下降还是 LALR?**
LALR(1),由自研的 lemon 生成(tool/lemon.c → parse.c)。lemon 比 yacc 多了归约冲突消解规则与 `%fallback` 机制。

**Q2:`?NNN`、`?`、`:name`、`@name`、`$name` 有区别吗?**
词法层都是 TK_VARIABLE,只是入口字符类不同;编号在 parse.y:1204 统一分配。`::` 与 `$var(idx)` 是为兼容 PG/TCL 在 tokenizer 特判的。

**Q3:SQLite 做哪些常量折叠?**
只有布尔恒等式与 `IS NULL` 文法级折叠;算术折叠推迟到代码生成期;跨谓词常量传播用 EP_FixedCol 标记而非树改写。

**Q4:窗口函数的关键字歧义怎么解决?**
tokenizer 对 WINDOW/OVER/FILTER 三个词做二次前瞻(前一个 token 是 `)` 等),因为 lemon 的 %fallback 表达不了上下文二义性(tokenize.c:216-266)。

**Q5:语法错误后会继续找错误吗?**
不会。YYNOERRORRECOVERY 关闭了错误恢复,第一个语法错误即终止——嵌入场景要的是确定性而非教学性报错。

**Q6:列名歧义何时报错?**
lookupName 向外层遍历时 cnt>1 且不在 USING 中即报 ambiguous;内层命中即停止,外层同名被遮蔽。

## 6.5 小结与深挖方向

本章结论:**前端 = 字符类词法 + lemon LALR + 归约即建 AST;常量折叠克制到"布尔恒等式"级别,复杂度让位给代码生成期与优化器**。深挖方向:

1. `%fallback` 与 tokenizer 的协作协议(sqlite3ParserFallback);
2. EP_TokenOnly/EP_Reduced 截断结构在触发器重写中的实际占比;
3. 常量传播四道防线(亲和性/collation/子类型)的反例构造;
4. `scanpt` 文本切片在 DEFAULT 子句保真中的边界情形。

> 下一章是查询编译的心脏:select.c 的主流程、子查询扁平化的 28 条约束,以及 where.c 两阶段优化器的全部代价公式。
