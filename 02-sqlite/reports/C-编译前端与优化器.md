# SQLite 卷二 · C 章:SQL 编译前端与查询优化器

> 调研对象:sqlite 3.54.0(commit 492e7fc0),`src/` 目录。所有结论均标注 `文件:行号`,行号以该版本源码为准。
> 涉及文件:`src/tokenize.c`(899 行)、`src/parse.y`(2163 行,经 `tool/lemon.c` 生成 parse.c)、`src/expr.c`(7826 行)、`src/resolve.c`(2367 行)、`src/select.c`(9058 行)、`src/where.c`(7906 行)、`src/analyze.c`(2012 行,概览)、`src/whereInt.h`(665 行)、`src/sqliteInt.h` 中的 Expr 定义。

---

## ① 编译流水线全景

SQLite 没有"优化后的执行计划树"这一中间层:前端在解析的同时**直接把 AST 翻译成 VDBE 字节码**,优化器内嵌在代码生成流程中。整条流水线如下:

```
SQL 文本
  │ sqlite3RunParser()                    tokenize.c:600
  ├─ sqlite3GetToken():词法(字符类表 + 关键字哈希) tokenize.c:273
  ├─ sqlite3Parser():lemon 生成的 LALR(1) 引擎   parse.y:59 (%name)
  │     归约动作直接构造 AST:Select / SrcList / Expr / ExprList / With
  │     顶层语句归约完 → sqlite3FinishCoding()     parse.y:176
  │
  ├─ SELECT 路径:cmd ::= select { sqlite3Select() }   parse.y:520-528
  │   sqlite3Select() 主流程(有编号的 tag,见 select.c:7638-7670 的自述大纲)
  │     tag-0100  SelectPrep:expand(* 展开、CTE 绑定)+ 名字解析
  │     tag-0200  FROM 逐项优化:外连接强度削减 / 去无用 ORDER BY / 子查询扁平化
  │     tag-0300  复合 SELECT → multiSelect()
  │     tag-0330  WHERE 常量传播(仅 join)
  │     tag-0400  子查询落地:协程 / 物化 / CTE 复用
  │     tag-0500  DISTINCT+ORDER BY → GROUP BY 改写
  │     tag-0700/0800  非聚合 / 聚合两条代码生成路径
  │   sqlite3WhereBegin() / sqlite3WhereEnd()      where.c:6838
  │     第一阶段:whereLoopAddAll() 枚举每张表的所有访问算法(WhereLoop)
  │     第二阶段:wherePathSolver() 束搜索选 join 顺序与扫描方式(WherePath)
  │     选定后直接吐出嵌套循环字节码:OP_Rewind/OP_Next/OP_IdxGT ...
  │
  └─ 输出:Vdbe 程序(完整 SQL → 字节码在"一次 prepare"内完成)
```

两个关键定位:

1. **where.c 不是独立的计划器,而是代码生成器的一部分**。`sqlite3WhereBegin()` 的注释明确说它生成的就是嵌套循环本身(3 张表就是三层 foreach,where.c:6764-6774),循环体内留给调用者(select.c 的 `selectInnerLoop`)填输出逻辑。
2. **没有计划缓存**。每次 prepare(包括内部语句重准备)都重新跑一遍扁平化 + 优化,因此优化器复杂度被刻意控制在毫秒级(见后文 mxChoice/iPlanLimit 的限流设计)。

---

## ② 词法与文法逐段解读

### 2.1 tokenize.c:不是经典状态机,而是"字符类 + 单趟 switch"

`sqlite3GetToken()`(tokenize.c:273)对首字节查 `aiClass[]` 字符类表(tokenize.c:29-100,共 31 类 CC_X..CC_BOM),然后 `switch` 到对应分支一次读出整个 token。注释解释了为什么用字符类而不是直接对字符 switch:小整数的 switch 会被编译器编译成跳转表,而对 0~255 的字符 switch 会退化成二分查找(tokenize.c:21-28)。ASCII 与 EBCDIC 两张表并存(tokenize.c:61-100)。

几个值得注意的实现细节:

- **关键字只识别一次入口**。只有首字母属于 CC_KYWD0/CC_KYWD 的 token 才调用 `keywordCode()`(tokenize.c:539-551),它是 `tool/mkkeywordhash.c` 生成的完美哈希(tokenize.c:137-148 include "keywordhash.h"),非关键字直接返回 TK_ID。
- **数字后跟标识符字符是语法错误**,循环吃掉这些字符并把类型改成 TK_ILLEGAL(tokenize.c:493-497);数字中可插入分隔符(SQLITE_DIGIT_SEPARATOR),出现即变成 TK_QNUMBER(tokenize.c:443-459),这是近年新增的字面量可读性特性。
- **注释不是空白而是独立 token**(TK_COMMENT),默认在驱动层跳过,仅在重解析 schema 或显式开启时被忽略(tokenize.c:696-702);UTF-8 BOM 被当作空白(tokenize.c:575-582)。
- JSON 运算符 `->`、`->>` 在 CC_MINUS 分支合成 TK_PTR(tokenize.c:294-297)。

**参数标记(question-mark / named parameter)的四类前缀**全部归并为 TK_VARIABLE:

- `?` / `?123`:CC_VARNUM,只吃数字(tokenize.c:504-508);
- `:name`、`@name`、`#name`、`$name`:CC_VARALPHA/CC_DOLLAR(tokenize.c:509-538),该分支还额外兼容两件事:TCL 风格的 `$var(index)`(遇到 `(` 且已有名字时一路吃到 `)`,tokenize.c:519-528)和 PG 风格的 `::` 类型转换(连续两个冒号则合并进 token,tokenize.c:529-531)。如果 `:` 后面没有任何合法名字字符,则整个 token 定为 TK_ILLEGAL(tokenize.c:536)。

变量编号在表达式层完成:`VARIABLE` 产生式调用 `sqlite3ExprAssignVarNumber`(parse.y:1204-1208);而 `#N` 形式只在嵌套解析(触发器/内联重写)中被当作 TK_REGISTER 直接引用 VDBE 寄存器(parse.y:1209-1222)。

**词法层唯一需要"向前看"的地方是窗口函数三个词**:WINDOW/OVER/FILTER 既可能是关键字也可能是普通标识符(`SELECT sum(x) OVER ...` 中 OVER 可能是别名)。lemon 的 `%fallback` 机制处理不了这种二义性(tokenize.c:216-228 的注释给了反例),于是 tokenizer 在驱动循环里对这三个 token 做二次前瞻判断:`analyzeWindowKeyword` 要求"下一个 token 是标识符、再下一个是 AS"(tokenize.c:246-253),`analyzeOverKeyword`/`analyzeFilterKeyword` 要求前一个 token 是 `)`(tokenize.c:254-266),实际应用点在 tokenize.c:686-695。

驱动循环 `sqlite3RunParser()` 还有两个协议细节:到达输入末尾时补发 TK_SEMI 再补发 0(两次额外调用解析器,保证语句正确归约,tokenize.c:674-684); amalgamation 编译时解析器对象直接放栈上(`sqlite3Parser_ENGINEALWAYSONSTACK`,parse.y:98-100、tokenize.c:609-611),省掉一次堆分配。SQL 总长度受 `SQLITE_LIMIT_SQL_LENGTH` 限制,在 token 级递减(tokenize.c:615、647-652)。

### 2.2 parse.y 与 lemon:为手写体验特制的 LALR(1)

lemon 与 yacc/bison 的关键差异在 parse.y 头部即可看出:没有 `%union`,语义值默认统一为 `%token_type {Token}`、`%default_type {Token}`(parse.y:36-37),按符号用 `%type select {Select*}` 逐个覆盖,并为每个非终结符配 `%destructor`(如 parse.y:531),使错误路径上的内存自动释放。栈相关指令也暴露给文法文件:初始栈 50、栈上限函数、realloc/free 钩子(parse.y:25-28),对应 `SQLITE_LIMIT_PARSER_DEPTH`(parse.y:603-605)。错误处理被完全关闭:`#define YYNOERRORRECOVERY 1`(parse.y:76),语法错即放弃,不做错误恢复。

lemon 特有的三个机制在 SQLite 文法里大量使用:

- **`%fallback ID ...`**(parse.y:272-295):把 ABORT、IF、ROW、MATERIALIZED 等几十个"非保留字"声明为可回退成标识符,词法器与解析器通过 `sqlite3ParserFallback()` 协作(tokenize.c:208)。这消灭了传统 SQL 文法里庞大的 `identifier: IDENT | non_reserved_keyword` 产生式。
- **`%wildcard ANY`**(parse.y:296):用于虚拟表模块参数的任意 token 吞噬(parse.y:1936-1945)。
- **`scanpt` 非终结符**(parse.y:374-382):归约时把"下一个 token 的起始指针"作为语义值传播,两条 scanpt 之间的原文被原样截取(例如 DEFAULT 子句保留原始文本,parse.y:390-407)。这是 lemon 文法里少见的"文本切片"技巧。

**Token 编号被当作性能调优手段**。parse.y:263-267 用前置 `%token` 声明强制把跳转类操作符(ISNULL..ESCAPE)编号靠前、EQ/NE/GT/LE 相邻,使解析表更小;同时注释指出 ISNULL/NOTNULL、NE/EQ、GT/LE、GE/LT 必须只差 1,`sqlite3ExprIfFalse()` 的代码生成依赖这个约定(parse.y:298-307)。同理,WINDOW/OVER/FILTER 的 `%token` 声明被放在文件末尾以保证编号最大,tokenizer 用 `tokenType>=TK_WINDOW` 快速分流(parse.y:1976-1982、tokenize.c:654);文件尾断言 `TK_SPAN>255` 报错(parse.y:2146-2155)。

**代表性产生式:语法 → AST 节点的映射**

1. 单个 SELECT(`oneselect`,parse.y:651-655):九个非终结符(distinct/selcollist/from/where/groupby/having/orderby/limit)按位置喂给 `sqlite3SelectNew()`,生成 `Select` 对象。`*` 被编码为 TK_ASTERISK 的 Expr(parse.y:717-721),`tbl.*` 是 TK_DOT 挂两个子节点(parse.y:722-729)。
2. 复合 SELECT(parse.y:623-644):`selectnowith ::= selectnowith op oneselect` 生成**右倾斜链**(新 Select 的 pPrior 指向左侧),再由 `parserDoubleLinkSelect()` 反向补齐 pNext 并检查"ORDER BY/LIMIT 不能出现在复合左项"(parse.y:543-569)。右侧若是复合体则先包一层 FROM 子查询再挂 op:

```c
// parse.y:623-648(节选)
selectnowith(A) ::= selectnowith(A) multiselect_op(Y) oneselect(Z).  {
  Select *pRhs = Z, *pLhs = A;
  if( pRhs && pRhs->pPrior ){
    parserDoubleLinkSelect(pParse, pRhs);
    pFrom = sqlite3SrcListAppendFromTerm(pParse,0,0,0,&x,pRhs,0);
    pRhs = sqlite3SelectNew(pParse,0,pFrom,0,0,0,0,0,0);
  }
  if( pRhs ){
    pRhs->op = (u8)Y;          /* TK_UNION/TK_ALL/TK_EXCEPT/TK_INTERSECT */
    pRhs->pPrior = pLhs;
    if( Y!=TK_ALL ) pParse->hasCompound = 1;
  }
}
```

`multiselect_op` 把 UNION/UNION ALL/EXCEPT/INTERSECT 直接映射为 TK_ 值(parse.y:646-648),非 ALL 的复合打 hasCompound 标志供后续去重逻辑使用。
3. 表达式运算(parse.y:1348-1359):`AND` 走特殊构造器 `sqlite3ExprAnd`(常量 false 短路,见 §2.3),其余二元运算统一 `sqlite3PExpr(pParse,@OP,A,Y)`,`@OP` 把终结符的 token 类型直接变成 Expr.op——这是 lemon 的 `@` 语法。
4. IN 家族(parse.y:1491-1560)是信息量最大的一组产生式:`x IN ()` 折叠为 true/false 常量(但左值含函数时保留为 AND/OR 以防聚合语义误判,parse.y:1492-1512);`x IN (单一常量)` 改写成 `x = ?`(TK_EQ,parse.y:1514-1519);`IN (SELECT)` 与 `IN (表函数)` 把 Select 挂到 `Expr.x.pSelect`(EP_xIsSelect);行向量 `(a,b) IN (SELECT...)` 经 `sqlite3ExprListToValues` 变成 VALUES 子查询(parse.y:1529-1535)。LIKE/MATCH 是"中缀函数":操作数反序进 ExprList,`NOT LIKE` 外面包 TK_NOT,并打 EP_InfixFunc 标记(parse.y:1363-1383)。

### 2.3 expr.c:Expr 结构与"克制"的常量折叠

Expr 定义在 sqliteInt.h:3071-3133:`op`(操作码,复用 TK_ 编号)、`flags`(EP_* 位)、`u.zToken/iValue`(字面值或 EP_IntValue 短整数)、`pLeft/pRight`、`x.pList|pSelect`、以及 `y.pTab/pWin/sub` 等联合体;`iTable` 存 VDBE 游标号、`iColumn` 存列号(-1 为 rowid)、`iAgg` 指向 AggInfo 条目。两个"瘦身"位值得记住:EP_TokenOnly 与 EP_Reduced 允许把 Expr 结构截断到只保留前几个字段(sqliteInt.h:3062-3102 注释),用于复制出的临时表达式节省内存。

标志位中优化器最关心的几个:EP_Agg(含聚合)、EP_HasFunc、EP_Subquery、EP_Collate 会沿树向上传播(`EP_Propagate`,sqliteInt.h:3177);EP_OuterON/EP_InnerON 标记来自 ON/USING 子句,决定谓词能否被下推/移动(sqliteInt.h:3141-3142);EP_FixedCol 是常量传播的产物。

SQLite 的常量折叠非常克制,核心是三类:

- **true/false 字面量**:`sqlite3ExprIdToTrueFalse()` 把非引号的 ID/STRING "true"/"false" 改成 TK_TRUEFALSE 并设 EP_IsTrue/EP_IsFalse(expr.c:2352-2363);
- **AND/OR 的恒真恒假消去**:`sqlite3ExprSimplifiedAndOr()` 递归消掉 `(x<10) AND true`、`(y=22 OR false)` 这类项(expr.c:2383-2403),注释里列举了四种归约形态;`sqlite3ExprAnd()` 更进一步:两侧都不是 ON 子句片段且有一侧 EP_IsFalse 时直接生成常量 0(expr.c:1158-1175);
- **IS NULL 的编译期判定**:对整型/字符串等字面量,`expr IS NULL` 在文法动作层就变成常量(parse.y:1385-1446 的 `sqlite3PExprIsNull`),resolve 阶段还有 NOT NULL 强度削减(resolve.c:1034-1059)。

**没有**通用的"3+4 折叠成 7"式求值器;数值常量表达式留给代码生成期(`sqlite3ExprCodeRunJustOnce`,expr.c:5901,把常量求一次放进 pConstExpr 列表)。判断"常量"的通用机制是 Walker 回调 `exprNodeIsConstant`(expr.c:2560-2649),用 `eCode` 区分五种口径(注释 expr.c:2541-2545):1=纯常量、2=排除外连接 ON 项、3=表常量(允许不相关子查询)、4/5=允许确定性函数(DEFAULT 子句用)。TK_VARIABLE 在口径 5 下被静默改为 NULL(容忍历史 schema 中的参数,expr.c:2631-2642)。

真正大量产出常量的地方在 select.c 的**常量传播**:`findConstInWhere()` 收集 AND 顶层 `COLUMN=常量` 项(constInsert 还有亲和性/BINARY collation/子类型四道防线,select.c:4822-4863),然后 `propagateConstantExprRewrite` 把查询里所有同列引用打上 EP_FixedCol 并把常量挂到 pLeft(select.c:4906-4938)。注释用 `b=a` vs `b=123` 的反例解释了为什么不直接改写表达式树而是打标记(select.c:4977-5011)——TEXT 亲和下两者不等价。这是一个典型的"SQLite 式"折中:语义安全优先于改写的彻底性。

---

## ③ select.c:查询编译主流程

### 3.1 两遍准备 + 主流程

`sqlite3Select()` 开头有自带大纲(select.c:7638-7670,tag 编号 0100..1000)。第一遍准备 `sqlite3SelectPrep()`(select.c:6537)做两件事:`sqlite3SelectExpand()`(select.c:6452)驱动 selectExpander(select.c:6040)展开 `*`、把 CTE 名绑定到 FROM 项(`resolveFromTermToCte`,select.c:5753,为每个引用创建临时 Table 并挂 CteUse 共享块),随后 `sqlite3ResolveSelectNames()` 完成名字解析;之后窗口函数重写 `sqlite3WindowRewrite()`(select.c:7781)把窗口函数改写成嵌套 SELECT。

### 3.2 子查询扁平化(重点)

`flattenSubquery()`(select.c:4355)在 tag-0240 被调用(select.c:7961)。动机写在函数头:避免"子查询先物化成无索引临时表、外层再扫两遍"(select.c:4186-4206)。**不再尝试扁平化聚合子查询**——注释解释:若外层不是 join,子查询会走协程,物化开销本来就不存在,扁平化无收益(select.c:7883-7890)。全部约束编号整理如下(行号为代码判定处):

| 约束 | 内容 | 判定处 |
|---|---|---|
| (4) | 子查询不得是 DISTINCT | select.c:4407 |
| (7) | 子查询必须有 FROM | select.c:4406 |
| (8)(9) | 子查询有 LIMIT 时,外层不得是 join 或聚合 | select.c:4408-4410 |
| (11) | 两层不能都有 ORDER BY | select.c:4411 |
| (13)(14)(15) | LIMIT/OVESET 组合限制(不能都有 LIMIT;子查询不能有 OFFSET;外层是复合项时子查询不能有 LIMIT) | select.c:4401-4405 |
| (16) | 外层聚合时子查询不能有 ORDER BY | select.c:4414 |
| (19)(21) | 子查询有 LIMIT 时外层不能有 WHERE / 不能 DISTINCT | select.c:4415-4418 |
| (22)(23) | 涉及递归 CTE 的两边都不扁平化 | select.c:4419-4421、4502 |
| (3a)(3d)(26) | 子查询是 LEFT JOIN 右侧时,自身不能是 join、外层不能 DISTINCT、不能是 RIGHT JOIN 右侧 | select.c:4438-4447 |
| (25) | 任一侧含窗口函数即放弃 | select.c:4391 |
| (17a-17h) | 复合子查询只允许 UNION ALL,各臂不得 DISTINCT/聚合/带窗口、不得有 ORDER BY、各臂亲和性一致;外层不得聚合/DISTINCT/LEFT JOIN | select.c:4462-4505 |
| (27) | RIGHT/FULL JOIN 相关的位置限制 | select.c:4450-4452、4485-4490 |
| 隐含 | 父查询含 MATERIALIZED CTE 项(优化屏障)由调用者先行排除 | select.c:4454-4455、7875-7881 |

另外两个触发点:复合子查询要扁平化进多表 join 时,如果 `pParse->nSelect>500` 则放弃(select.c:4507-4512,防语句爆炸);外层是"复杂结果集 + 有 ORDER BY 的第一个子查询"时故意不扁平化,让 `SELECT expensive_function(x) FROM (SELECT x FROM t ORDER BY y LIMIT 10)` 只对 10 行调用昂贵函数(select.c:7933-7958)。

### 3.3 复合 SELECT、递归 CTE 与物化策略

`multiSelect()`(select.c:2998)采用三种策略:**UNION ALL 且无 ORDER BY** → 直接顺序执行左右两段,用 LIMIT 计数器提前跳过右段(select.c:3067-3104,行数估计用 `sqlite3LogEstAdd` 累加);**有 ORDER BY 或 EXCEPT/INTERSECT/UNION** → 强制走 merge 算法 `multiSelectByMerge`,必要时凭空造一个 `ORDER BY 1`(select.c:3052-3066)。递归 CTE 由 `generateWithRecursiveQuery()`(select.c:2707)实现为经典 Queue/Current 双表循环:setup 查询灌 Queue(select.c:2828-2834),主循环每次取一行进 Current(select.c:2837-2846)再执行递归部分回灌 Queue;UNION 的去重用独立 ephemeral 表(select.c:2764-2769),并且把递归臂统一改成 TK_ALL(select.c:2819-2826)。

FROM 子查询落地(tag-0400,select.c:8033-8228)按优先级尝试四种方式:

1. **协程**:`fromClauseTermCanBeCoroutine()`(select.c:7341)通过时生成 OP_InitCoroutine,数据不落盘(select.c:8137-8156);
2. **CTTE 复用**:同 CTE 多次引用时第一次物化的子例程地址存在 `CteUse.addrM9e`,后续引用 OP_Gosub + OP_OpenDup 打开同一个临时表的副本游标(select.c:8157-8168);
3. **同 FROM 重复视图复用**:`isSelfJoinView()` 检测到先前已物化则 OpenDup(select.c:8169-8181);
4. **物化**:非相关子查询外包 OP_Once(select.c:8196-8204),结果进 SRT_EphemTab。

物化前的谓词下推 `pushDownWhereTerms()`(select.c:5208)要求:子查询非递归、不在 RIGHT/LTORJ 侧(select.c:5220-5225),复合臂全为 UNION ALL 且 collation 均为 BINARY(select.c:5227-5256),无 LIMIT(select.c:5276),谓词必须是该子查询的单表约束 `sqlite3ExprIsSingleTableConstraint`(select.c:5327);下推进聚合子查询时挂到 HAVING(select.c:5360-5361)。窗口函数子查询仅在 PARTITION 存在时放行(select.c:5259)。

### 3.4 聚合与 GROUP BY 的代码生成

非聚合路径在 tag-0700 调 `sqlite3WhereBegin()` 后,把排序索引指令置为 Noop(若优化器已能按序输出,select.c:8402-8404)。聚合路径先建 `AggInfo` 并用 `sqlite3ExprAnalyzeAggList` 把 TK_COLUMN 改写成 TK_AGG_COLUMN、函数改写为 TK_AGG_FUNCTION(select.c:8495-8525);HAVING 在有 GROUP BY 时先经 `havingToWhere` 把可用的谓词搬到 WHERE(select.c:8517-8523)。GROUP BY 需要排序时开 OP_SorterOpen,若 `sqlite3WhereIsOrdered(pWInfo)==pGroupBy->nExpr` 则说明优化器用索引交付了分组序,直接取消排序(select.c:8627-8633)。无 GROUP BY 的 `count(*)` 有专门特化 `isSimpleCount` → 一条 OP_Count 直接读最小的索引(select.c:8852-8912)。min/max 单函数查询由 `minMaxQuery()` 识别,把"聚合"退化成带 ORDER BY 的 WHERE 扫描以便走索引提前终止(select.c:8527-8531、8966-8983)。

聚合查询的行数估计也在此处修正:有 GROUP BY 时 `p->nSelectRow` 被压到 66(LogEst,即 100 行,select.c:8467-8468),无 GROUP BY 的纯聚合直接置 0(select.c:8483-8486)——这两个常数直接喂给 WhereBegin,影响 join 顺序选择时对"内层循环执行次数"的假设。分组键与输出行之间的基数关系没有任何 stat 支持,是估计误差的另一个已知来源。

---

## ④ where.c:两阶段优化器逐段解读

### 4.0 基础数据结构(LogEst 与三类对象)

- **WhereLoop**(whereInt.h:129-173):"对某张 FROM 表的一种实现算法",核心字段 `prereq`(依赖的表位图)、`rSetup/rRun/nOut`(三者都是 **LogEst**:以 10 为底的整数对数,33≈10 倍、100=10^10),`u.btree.nEq`(等值前缀列数)、`pIndex`、`aLTerm[]`(用到的 WHERE 项)。
- **WherePath**(whereInt.h:213-221):一个部分 join 计划,`maskLoop` 已含表位图、`rCost/nRow/isOrdered`。
- **WhereLevel/WhereInfo**(whereInt.h:73-113、472+):最终选出的每层循环及其代码生成锚点。
- **WhereTerm/WhereClause**(whereInt.h:274-367):WHERE 被 AND 切分后的项,`eOperator` 用 WO_* 位掩码编码以便一次匹配多操作符;OR 项挂 WhereOrInfo。

join 表数上限由 Bitmask 位数决定——64 表(whereInt.h:270-272,运行时报错 where.c:6888-6891)。

### 4.1 第〇阶段:单表捷径 whereShortCut

单表查询且无 INDEXED BY 时,若存在无前置依赖的 `rowid=?`(rRun=33,即 10)或某唯一索引全列等值(rRun=39,即 15),直接定型,跳过整个枚举(where.c:6362-6452)。注释"TUNING: Cost of a rowid lookup is 10 / unique index lookup is 15"是代价常数风格的代表。

### 4.2 第一阶段:WhereLoop 枚举(whereLoopAddAll)

`whereLoopAddAll()`(where.c:4941)从左到右逐表调用。CROSS/OUTER/RIGHT JOIN 右侧的表通过 `mPrereq |= mPrior` 禁止被重排到前面(where.c:4971-4994);虚拟表走 `whereLoopAddVirtual`;OR 项另走 `whereLoopAddOr`。为防病态 SQL,规划搜索总量有硬上限 `iPlanLimit = 20000 + 1000×表序`(whereInt.h:442-460),耗尽时打日志 "abbreviated query algorithm search" 并降级继续(where.c:5028-5031)。

**whereLoopAddBtree**(where.c:4007)对每个候选索引生成三类基本算法:

- **FULLSCAN(rowid 表全表扫)**:构造伪 IPK 索引 sPk(where.c:4046-4063),代价 `rRun = rSize + 16`(即 3.0×N;STAT4 可用时降到 2.75×N),注释明说 3.0 是"惩罚全表扫、因为索引查找的最坏情况更好"的偏置项(where.c:4158-4174)。这是优化器里最重要的一个 TUNING,代码原文:

```c
// where.c:4156-4175(节选)
/* Integer primary key index */
pNew->wsFlags = WHERE_IPK;
/* Full table scan */
pNew->iSortIdx = b ? iSortIdx : 0;
/* TUNING: Cost of full table scan is 3.0*N.  The 3.0 factor is an
** extra cost designed to discourage the use of full table scans,
** since index lookups have better worst-case performance if our
** stat guesses are wrong.  Reduce the 3.0 penalty slightly
** (to 2.75) if we have valid STAT4 information for the table. */
#ifdef SQLITE_ENABLE_STAT4
pNew->rRun = rSize + 16 - 2*((pTab->tabFlags & TF_HasStat4)!=0);
#else
pNew->rRun = rSize + 16;
#endif
```

- **INDEX SCAN(含覆盖索引全扫)**:`rRun = rSize + 1 + (15*szIdxRow)/szTabRow`——N 行 × K,K 在 1.1~3.0 之间随索引行/表行大小比例浮动(where.c:4250-4253);非覆盖时叠加回表代价 `nLookup = rSize + 16`(3×N),并用能纯索引求值的 WHERE 项逐个削减(where.c:4254-4280);
- **逐列约束扩展 whereLoopAddBtreeIndex**(where.c:3223):对索引第 nEq 列扫描 WhereTerm,匹配 EQ/IN/ISNULL/范围后**递归**到 nEq+1(where.c:3592-3600)。关键估计公式全部集中在这一函数:
  - `x IN (SELECT...)` 固定假设 25 行:`nIn = 46`(LogEst,where.c:3338-3341);`IN (值列表)` 用真实个数(where.c:3364-3366);
  - **IN 用索引还是顺序扫**的判据有完整推导:设 N=表行数、K=IN 右侧个数、M=前缀匹配行数,若 `M*log(K) < K*log(N)` 则放弃索引改全扫;为补偿估计误差加 10(LogEst,即 2 倍)的安全裕度偏向索引(where.c:3368-3411);不满足且启用 SeekScan 时生成 WHERE_IN_SEEKSCAN 跳扫计划(where.c:3399-3404);
  - 等值行数估计直接用 stat1 直方:`nOut += aiRowLogEst[nEq] - aiRowLogEst[nEq-1]`(where.c:3537),`IS NULL` 再 +10(2 倍,where.c:3538-3543);
  - 单次索引访问代价 `rCostIdx = nOut + 1 + (15*szIdxRow)/szTabRow`,IPK 特判为 `nOut + 16`(内部页小、叶子页满,不能用 szIdxRow 估扫描,where.c:3548-3564);需要回表则 `LogEstAdd(rCostIdx, nOut+16)`(where.c:3573-3576);
  - **Skip-scan**:最左列无约束但 stat1 显示其次数重复 ≥18(LogEst 42)时,跳过最左列生成计划,并对不确定性加 1.375 的惩罚系数(LogEst +5,where.c:3616-3652)。

范围估计 `whereRangeScanEst`(where.c:2087):STAT4 可用时用 iLower/iUpper 样本差;否则每个边界 `whereRangeAdjust` 减 20(1/4),**双边界再减 20**,即开区间默认 1/4 行、BETWEEN 默认 1/64 行,下限 2 行(where.c:2225-2240、1911-1921)。所有未被索引用到的 WHERE 项再由 `whereLoopOutputAdjust` 统一折减:默认每项 -1(93.75%),`x==非0/1字面量` 时封顶 1/4,LIKE/GLOB 按模式长度折减(where.c:2996-3148)。

**auto-index**(where.c:4067-4120):条件苛刻(非 OR 子句、非相关子查询、非 RIGHT JOIN 侧等),一次性建索引代价 `rSetup = rLogSize + rSize + 28`(X·N·logN,X=7;视图/子查询物化体降为 -25,鼓励为其建自动索引),每次查找估 20 行(`nOut=43`)。回报检验在路径层:外层循环预计运行不足 1.25 次(<1.25 行)不用自动索引(where.c:5961-5967),且首 28 行内建索引成本收不回来也不用(seed `nRow = MIN(nQueryLoop,48)`,where.c:5929-5932)。

**OR 多路**:whereLoopAddOr(where.c:4814)对每个 OR 项递归地为每个分支各建子 WhereLoop 集合(保优 N_OR_COST=3 组合,whereInt.h:189-193),笛卡尔合并后加 1(LogEst,≈1.07×)惩罚,避免"全表扫 OR 索引查找"这种畸形组合(where.c:4914-4930)。IN 在代码生成层展开为额外嵌套循环(WhereLevel.u.in.aInLoop,whereInt.h:96-105)。

WhereLoop 之间靠**支配剪枝**控制数量:`whereLoopCheaperProperSubset()` 判定"约束项更少且全部被包含"(where.c:2652-2682),`whereLoopAdjustCost` 保证超集代价必高于子集(where.c:2698-2723),插入时 `whereLoopInsert` 据此淘汰劣解(where.c:2827)。

### 4.3 第二阶段:WherePath 束搜索(wherePathSolver)

`wherePathSolver()`(where.c:5846)是保优束搜索而非完整 DP:

- 每层保留的路径数 **mxChoice**:1 表取 1;2 表取 5;≥3 表取 12,星型查询(≥5 表、事实表连 ≥3 个内连接维表)取 18,且维表的全表扫代价被人为抬高以保住"事实表在外层"的计划(where.c:5607-5638、5871-5888);
- 初始 seed 假设"外层输入 28 行"用于摊销 rSetup(where.c:5929-5932);
- 状态转移:一次扩展一条候选 WhereLoop,代价按 LogEst 对数域累加(LogEstAdd≈概率乘法):

```c
// where.c:5970-5998(节选)
rUnsort = pWLoop->rRun + pFrom->nRow;
if( pWLoop->rSetup ){
  rUnsort = sqlite3LogEstAdd(pWLoop->rSetup, rUnsort);
}
rUnsort = sqlite3LogEstAdd(rUnsort, pFrom->rUnsort);
nOut = pFrom->nRow + pWLoop->nOut;
maskNew = pFrom->maskLoop | pWLoop->maskSelf;
isOrdered = pFrom->isOrdered;
if( isOrdered<0 ){
  isOrdered = wherePathSatisfiesOrderBy(pWInfo, pWInfo->pOrderBy,
                pFrom, pWInfo->wctrlFlags, iLoop, pWLoop, &revMask);
}
if( isOrdered>=0 && isOrdered<nOrderBy ){
  if( aSortCost[isOrdered]==0 ){
    aSortCost[isOrdered] = whereSortingCost(
        pWInfo, nRowEst, nOrderBy, isOrdered);
  }
  rCost = sqlite3LogEstAdd(rUnsort, aSortCost[isOrdered]) + 3;
}
```

- **排序代价**:`whereSortingCost() = K·N·log(N)`,按列数缩放 `(nExpr+59)/30`,部分有序按 `(Y/X)` 折算,LIMIT 场景 ×2,DISTINCT 场景 N 减半(where.c:5539-5597);已满足 k 个 ORDER BY 项时总代价 = LogEstAdd(rUnsort, sortCost) + 3(轻微偏向免排序计划),完全免排序的计划 rUnsort 再减 2 反向偏置(where.c:5988-6006);
- 同一 maskLoop+isOrdered 等价类只保留 mxChoice 个最优(where.c:6028-6062)。

求解入口的完整次序在 `sqlite3WhereBegin()`(where.c:6838):whereShortCut 失败 → `whereLoopAddAll` → (STAT4 truthProb 被修订时整体重算一遍,where.c:7093-7112) → `wherePathSolver(pWInfo, 0)`;若带 ORDER BY,再做一次带行数估计的二次求解(`whereInterstageHeuristic` + 第二次 wherePathSolver,where.c:7115-7121)。DISTINCT 在子查询上统一再减 30(LogEst,即 ÷8,tag-20250414a,where.c:7123-7131)。

### 4.4 analyze.c 概览:stat1 如何喂给优化器

`ANALYZE` 为每张表生成一段 VDBE 程序,用 stat_init/stat_push/stat_get 三个内置聚合函数扫描每个索引(analyzeOneTable,analyze.c:977;函数本体 401/702/818),把结果写进 `sqlite_stat1(tbl, idx, stat)`。stat 列格式(analyze.c:41-65):K+1 个整数——第 1 个是索引行数,第 i+1 个是前 i 列等值时的平均重复数;可后缀 `unordered`/`noskipscan`/`sz=` 关键字(解码于 decodeIntArray,analyze.c:1559-1578)。连接时 `sqlite3AnalysisLoad`(analyze.c:1942)→ `analysisLoader`(analyze.c:1593)把它们填进 `Index.aiRowLogEst[]` 与 `Table.nRowLogEst`(analyze.c:1632-1644)。优化器侧的消费点即 §4.2 所列的 rSize/aiRowLogEst/hasStat1/szIdxRow。STAT4(可选编译)提供每索引 10~40 个样本的 nEq/nLt/nDLt 直方(analyze.c:100-140),供 whereEqualScanEst/whereInScanEst/whereKeyStats 使用。没有 stat1 时优化器全部使用默认猜测(N=1048576,CTE 临时表 nRowLogEst=200,select.c:5826)。一个有趣的反向联动:当非唯一索引被用于计划时,表被打上 TF_MaybeReanalyze 提示 stat1 过期(where.c:4297-4305)。

---

## ⑤ 设计动机与取舍

SQLite 优化器的自我定位一句话:**一个运行在 prepare 时刻、单机嵌入式的"够好"规划器**——不做计划缓存、不做重新优化(runtime re-optimization),用束搜索 + 硬限流把最坏规划时间钉死(whereInt.h:442-460),用 LogEst 整数对数避免浮点运算以保证跨平台确定性,用大量 `TUNING` 魔数(3.0×全表扫惩罚、25 行子查询、18 次 skip-scan、1.25 次 auto-index 回报线)编码工程经验而非测量模型。与 MySQL 8(基于显式 cost model + histogram,服务端常驻、计划缓存与失效机制)相比,SQLite 更像"每次 prepare 现算的精简 System R";与 PostgreSQL(GEQO 遗传搜索处理大 join、完整动态规划 + 细粒度代价参数可调)相比,SQLite 选择了"束宽 12/18 的近似 DP + 64 表硬上限"的保守路线,换来的是几 KB 内存与微秒级规划时间。前端侧同理:lemon 无错误恢复、无 %union,都是为嵌入场景的体积与确定性服务。

三处值得体会的取舍哲学:**第一,优先改写树、而不是到处特判代码生成**。扁平化、谓词下推、DISTINCT→GROUP BY、HAVING→WHERE、常量传播全部发生在 AST 层(tag-0200..0500),where.c 只面对已经化简的查询。**第二,语义正确性约束写进注释与断言而非实现**——flattenSubquery 的 20 多条约束每条都引用 ticket 号(select.c:4303-4343),说明这是二十年间被 bug 驱动逐步收紧的护栏,不是一次设计出来的。**第三,代价模型"宁可信其有"**:对没有统计的输入一律用保守默认值(子查询 25 行、CTE 临时表 100 万行、IN 用索引优先),因为嵌入式场景下"错误地放弃索引"通常比"错误地使用索引"代价大得多(where.c:3383-3389 的安全裕度注释明确表达了这一偏好)。

---

## ⑥ FAQ(10 条)

**Q1:为什么 `SELECT * FROM t WHERE rowid=5` 不需要 ANALYZE 也能秒出计划?**
走 whereShortCut 捷径:单表 + 无依赖的 rowid 等值直接定型 rRun=33(where.c:6390-6399),唯一索引全等值同样走捷径(rRun=39,where.c:6424-6425),完全绕过枚举与求解。

**Q2:`x IN (SELECT ...)` 里子查询行数为什么假设是 25?**
写死的 TUNING:`nIn=46`,assert 注明 46==sqlite3LogEst(25)(where.c:3338-3341)。没有 stat4 时 SQLite 不去估子查询基数,统一用 25 行这个保守值。

**Q3:为什么有时 IN (值列表) 反而不用索引?**
显式判据 `M*log(K) < K*log(N)`(M=索引前缀匹配行数,K=列表长度,N=表行数)成立时顺序扫更便宜,再加 10 的安全裕度偏向索引(where.c:3368-3411)。

**Q4:子查询扁平化最常"失效"的条件是什么?**
按代码出现频率排:DISTINCT 子查询(select.c:4407)、两层都有 ORDER BY(4411)、窗口函数(4391)、聚合子查询(7890,直接 continue)、MATERIALIZED CTE(7875-7881)。

**Q5:`?NNN`、`?`、`:name`、`@name`、`$name` 有区别吗?**
词法层都是 TK_VARIABLE,只是入口字符类不同(CC_VARNUM vs CC_VARALPHA/CC_DOLLAR,tokenize.c:504-538);编号在 parse.y:1204 的动作里统一分配。`::` 和 `$var(idx)` 是为了兼容 PG/TCL 语法在 tokenizer 里特判的。

**Q6:SQLite 做哪些常量折叠?**
只有布尔恒等式:true/false 字面量化(expr.c:2352)、AND/OR 恒真恒假消去(expr.c:2391)、`字面量 IS NULL` 文法级折叠(parse.y:1385-1446)、`IN ()` 折叠(parse.y:1492)。算术折叠推迟到代码生成期一次性求值(expr.c:5901);跨谓词的常量传播用 EP_FixedCol 标记而非树改写(select.c:4977-5011)。

**Q7:UNION/EXCEPT/INTERSECT 与 UNION ALL 实现有何不同?**
UNION ALL 无 ORDER BY 时顺序执行两段(multiSelect else 分支,select.c:3067-3104);其余一律走归并(multiSelectByMerge),必要时伪造 ORDER BY 1(select.c:3052-3066)。

**Q8:递归 CTE 是怎么执行的?**
Queue/Current 两张临时表循环:setup 结果进 Queue,循环体每次取一行到 Current、执行递归部分、结果回灌 Queue,直到 Queue 空(select.c:2837-2869);UNION 去重靠独立 ephemeral 表(select.c:2764-2769)。

**Q9:为什么 join 最多 64 张表?**
所有依赖/覆盖信息都编码在 Bitmask 位图里(WhereLoop.prereq/maskSelf),位宽就是上限;显式报错 "at most %d tables in a join"(where.c:6888-6891)。

**Q10:列名歧义在什么时候报错?**
lookupName 内层向外遍历 NameContext,`cnt>1` 且列不在 USING 列表中即"ambiguous column name"(resolve.c:439-448);FULL JOIN + USING 则生成 coalesce 消解(resolve.c:458-461)。内层命中即停止,外层同名列会被遮蔽。

---

## ⑦ 深挖问题(5 条)

1. **OUTER JOIN 强度削减与扁平化的交互**:`sqlite3ExprImpliesNonNullRow` 判定 WHERE 谓词保证某表非 NULL 行时,LEFT JOIN 降级为 JOIN(select.c:7824-7862)。EP_OuterON 标记如何从 ON 子句迁移、与谓词下推(pushDownWhereTerms 的 mExcludeOn 防线,select.c:4874)如何协同,值得单独走读一遍。
2. **窗口函数重写与扁平化的边界**:sqlite3WindowRewrite 在 SelectPrep 之后、扁平化之前执行(select.c:7781 vs 7961),重写生成的嵌套 SELECT 是否还有机会被 flattenSubquery 二次吸收?(25) 约束只挡住了"带窗口的原始子查询"。
3. **CteUse 的生命周期与 CTE 复用计数**:`eM10d`(MATERIALIZED 三态)、`nUse<2` 才允许谓词下推(select.c:8098-8100)、addrM9e 子例程复用(select.c:8157-8168)三者构成一个小型"CTE 使用分析",其与递归 CTE 的 zCteErr 状态机(resolveFromTermToCte,select.c:5876-5923)值得画状态图。
4. **星型查询启发式的回归史**:computeMxChoice 注释完整记录了 2024-05 引入、2024-12~2025-01 三起性能回归、后改为"只抬高维表 SCAN 代价"的演化(where.c:5645-5661),是研究"启发式优化器如何安全演进"的一手材料。
5. **IN 与 SeekScan/Skip-scan 的统一性**:IN 判据失败时 fallback 到 WHERE_IN_SEEKSCAN(where.c:3399-3404),skip-scan 由 stat1 的最左列重复度触发(where.c:3626-3652)——三者本质都是"在有序前缀上做离散跳变",可以验证其代价模型在边角数据(低基数最前列 + 高选择性第二列)下是否自洽。
