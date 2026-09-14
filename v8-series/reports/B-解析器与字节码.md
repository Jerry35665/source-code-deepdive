# B - V8 解析器与字节码生成（Parser → BytecodeGenerator → Ignition）

> 调研对象：V8 源码，commit `c6a1f7c2`（shallow clone）。所有 `文件:行号` 均为该 commit 下 grep/Read 实测。
> 本文为精简卷第 2 章。上一章（A）讲隔离与 Zone 分配，本章承接"源码文本如何变成可执行的字节码"。

---

## 1. 全景：一段 JS 是如何被执行的

V8 不再像 2017 年以前那样"全量解析→AST→直接出机器码"，而是四层渐进：

```
 源码字符串
     │  CompilationCache 命中? ──是──> 直接复用 SharedFunctionInfo/BytecodeArray
     ▼ 否
 ┌─────────────────────────────────────────────────────────────────┐
 │ Scanner 词法分析      src/parsing/scanner.cc（4-token 预读缓冲） │
 │   + Parser 递归下降   src/parsing/parser.cc                     │
 │     ├─ 顶层函数：全量解析，建完整 AST                             │
 │     └─ 内部函数：PreParser 跳过（只校验语法、不建树）─┐           │
 └──────────────────────────────────────────────────────┼─────────┘
                                                        ▼
                              preparse data 记录"函数边界/参数个数"等元数据
     │
     ▼  顶层 AST
 ┌─────────────────────────────────────────────────────────────────┐
 │ BytecodeGenerator   src/interpreter/bytecode-generator.cc       │
 │   AST → 累加器+寄存器式字节码；同时编译时登记 FeedbackVectorSpec    │
 └─────────────────────────────────────────────────────────────────┘
     │
     ▼
 Ignition 解释执行（handler 由 CSA/TSA 生成，约 194 个）
     │  执行时向 FeedbackVector 写入类型/形态反馈
     ▼  热点触发（TieringManager::MaybeOptimizeFrame）
 TurboFan / Maglev 优化编译（消费反馈向量）
     │
     ▼  函数首次被调用才编译的惰性函数：
 Compiler::Compile 补解析+补生成字节码（parser.cc 的 ParseFunction 重入）
```

关键入口行号：
- 脚本级解析入口 `ParseProgram`：src/parsing/parsing.cc:35，内部调 `parser.ParseProgram`（parsing.cc:53）。
- 函数惰性调用后的"补编译"：`Compiler::Compile` src/codegen/compiler.cc:3012（前置 DCHECK 即 `!shared_info->is_compiled()`，compiler.cc:3015）；重解析入口 `Parser::ParseFunction` src/parsing/parser.cc:1060，落到 `DoParseFunction`（parser.cc:1140）。
- Ignition 编译任务的创建：`Interpreter::NewCompilationJob` src/interpreter/interpreter.cc:298。
- 解释器 handler 总量：src/interpreter/interpreter-generator.cc 中 `IGNITION_HANDLER` 共 194 处。
- 分层触发：`TieringManager::MaybeOptimizeFrame` src/execution/tiering-manager.cc:317（调用点 tiering-manager.cc:655）。

---

## 2. 惰性解析专节：PreParser 的"校验不建树"

### 2.1 两级 laziness：先"惰性解析"，再"惰性编译"

V8 的注释说得很直白——`parser.cc:2850-2852`：

> Lazy parsing is different from lazy compilation; we need to parse more eagerly than we compile.

即：内部函数体可以**先只做语法校验（preparse）不建 AST**；编译（生成字节码）则要等到函数真正被调用。两者是独立的省钱层次。

### 2.2 决策点：这个函数要不要 preparse

`Parser::ParseFunctionLiteral`（src/parsing/parser.cc:2803）里集中了所有启发式：

- 基础提示 `EagerCompileHint`（枚举定义 src/ast/ast.h:2362：`kShouldEagerCompile / kShouldLazyCompile`）；parser.cc:2840-2848 决定：外层认为"下一个函数大概率会被调用"（`next_function_is_likely_called`，parser-base.h:480-489；外层传下来后在 parser-base.h:1864-1865 被清零）、IIFE 前有包裹括号、以及 v8 compile-hints 魔法注释（parser.cc:2843-2846，`//# allFunctionsCalledOnLoad` 之类）都会强制 eager。
- 顶层默认值：`set_default_eager_compile_hint(can_compile_lazily ? kShouldLazyCompile : kShouldEagerCompile)`（parser.cc:637-639）。
- `is_lazy` = 提示为惰性（parser.cc:2889-2890）；`should_preparse = can_preparse && (is_lazy || 应发并行编译任务)`（parser.cc:2923-2924，并行任务条件见 2907-2917）。注意：即使函数最终要并行 eager 编译，也会**先 preparse 一次**拿元数据。

### 2.3 SkipFunction：跳过函数体

主解析器遇到函数体时调 `Parser::SkipFunction`（parser.cc:3039）。两条路：

1. **有旧 preparse 数据**（`consumed_preparse_data_`，parser.cc:3056）：上次编译缓存下来的元数据直接取（`GetDataForSkippableFunction`，parser.cc:3064-3068），`scanner()->SeekForward` 直奔函数尾（parser.cc:3074），连 token 都不扫。
2. **无缓存**：调 `reusable_preparser()->PreParseFunction`（parser.cc:3102）。此处源码注释（parser.cc:3095-3096）：

```cpp
// With no cached data, we partially parse the function, without
// building an AST. This gathers the data needed to build a lazy function.
```

失败回退：PreParser 遇到它无法定位的错误（如某语法歧义需要完整语义信息）时，用 scanner 书签回退到函数头（`bookmark.Apply()`，parser.cc:3118），外层重新 eager 全解析（parser.cc:2972-2981 的 `ParseFunction`）——所以 preparse 是"尽力而为、失败可回退"的。

### 2.4 "校验不建树"的实现：哑节点

PreParser 的设计宣言在 src/parsing/preparser.h:15-21：

> Whereas the Parser generates AST during the recursive descent, the PreParser doesn't create a tree. Instead, it passes around minimal data objects (PreParserExpression, PreParserIdentifier etc.)... PreParserFactory ... provides a similar kind of interface as AstNodeFactory, so ParserBase doesn't need to care which one is used.

精妙之处：Parser 和 PreParser 共用同一套 `ParserBase` 模板递归下降骨架（src/parsing/parser-base.h），PreParser 只是换了"节点工厂"。`PreParserExpression` 本质是一个带类型标记位的字（preparser.h:83 起），创建近乎零成本。但校验是真校验：参数重复、严格模式限制、var 冲突照做（preparser.cc:91-97、163-188）。

preparse 产物：函数结束位置、参数个数、length、内部函数个数等，由 `PreParserLogger::LogFunction` 记录（preparser.cc:362-371），消费在 parser.cc:3133-3140；内部嵌套函数的数据写进 `PreparseDataBuilder`（preparser.cc:124）。逃出函数作用域的未解析变量通过 `Scope::AnalyzePartially` 迁回主 Zone（parser.cc:3145；src/ast/scopes.cc:1863）。内部函数解析统一用 `preparser_zone_`（parser.cc:2937），整批丢掉、不产生 GC 压力（呼应 A 章 Zone 机制）。

### 2.5 代价与收益

- 收益：网页脚本里 50%-90% 的函数从不被调用；跳过其 AST 构建与字节码生成，同时 preparse 数据又能让"调用时补编译"无需重新定位边界。二次编译场景（`consumed_preparse_data_`）连扫描都省（parser.cc:3056-3083）。
- 代价：若函数后来真被调用，preparse 的工时成为纯浪费（等于扫了两遍源码）；PreParser 需要与 Parser 保持语法行为一致，长期是维护税。V8 用 compile-hints 魔法注释（parser.cc:2843-2846）和内联缓存 heuristic 缓解前者。

---

## 3. AST 专节：完整节点体系 + Zone 短命分配

### 3.1 节点清单

与 quickjs"解析直出字节码"不同，V8 保留完整 AST。节点用宏列出（src/ast/ast.h）：

```cpp
// ast.h:121-127
#define AST_NODE_LIST(V)                        \
  DECLARATION_NODE_LIST(V)                      \
  STATEMENT_NODE_LIST(V)                        \
  EXPRESSION_NODE_LIST(V)
```

- 声明 2 种：VariableDeclaration/FunctionDeclaration（ast.h:45-48）
- 迭代 5 种、可跳转 2 种（ast.h:49-58）
- 字面量 3 种：RegExpLiteral/ObjectLiteral/ArrayLiteral（ast.h:92-96）
- 表达式约 35 种：BinaryOperation、NaryOperation（n 元链式优化）、Call、ConditionalChain、OptionalChain、YieldStar 等（ast.h:98-120）。

类型骨架：`class AstNode : public ZoneObject`（ast.h:145），`Statement`（ast.h:188）/`Expression`（ast.h:194）两大派生。

### 3.2 Zone 分配

所有节点出自 `AstNodeFactory`（ast.h:3087），统一 `zone_->New<T>(...)`，例如 `NewRegExpLiteral`（ast.h:3343-3345）。工厂还预建了单例节点（空语句、ThisExpression，ast.h:3091-3093）避免重复分配。AST 生命周期 = 解析+字节码生成这一次编译任务，任务结束整块 Zone 释放——这就是"有 AST 也不至于太伤"的前提。函数名推断、字符串常量内化由 `AstValueFactory` 承担（ast.h:3096）。

---

## 4. 字节码生成专节：BytecodeGenerator

### 4.1 寄存器模型：累加器 + 寄存器

Ignition 是"累加器机"：二元运算隐式读累加器，结果写回累加器；寄存器只是溢出槽。编译期对应两件套：

- `BytecodeRegisterAllocator`（src/interpreter/bytecode-register-allocator.h:15）：`NewRegister()` 就是 `next_register_index_++`（同文件:37-40），线性无回收复用细节，栈式分配。
- `BytecodeRegisterOptimizer`（src/interpreter/bytecode-register-optimizer.h:15-21）：官方自述就是"peephole 层"——

> An optimization stage for eliminating unnecessary transfers between registers. The bytecode generator uses temporary registers liberally for correctness and convenience and this stage removes transfers that are not required.

它维护"寄存器-累加器等价类"，用 `RegisterTransfer` 记账（bytecode-register-optimizer.h:57-66），遇到真实 side-effect 字节码才 `Flush()`（同文件:70）物化必要的 `Ldar/Star/Mov`。运行时帧里累加器是"虚拟寄存器"（`Register::virtual_accumulator`，src/interpreter/bytecode-register.h:70、254-256），寄存器文件从帧指针偏移定位（bytecode-register.h:124）。

结果去向由作用域对象控制：`ExpressionResultScope`（bytecode-generator.cc:824）派生 `EffectResultScope`（:888，结果丢弃）、`ValueResultScope`（:897，结果进累加器）、`TestResultScope`（:910，结果变条件跳转）。`VisitForAccumulatorValue`（bytecode-generator.h:514）是高频入口。

### 4.2 表达式编译示例：`a + b`

`VisitArithmeticExpression`（bytecode-generator.cc:7990）核心段（8033-8036）：

```cpp
TypeHint lhs_type = VisitForAccumulatorValue(expr->left());
Register lhs = register_allocator()->NewRegister();
builder()->StoreAccumulatorInRegister(lhs);        // Star r0
TypeHint rhs_type = VisitForAccumulatorValue(expr->right()); // b -> acc
// 随后 builder()->Add(lhs, feedback)               // acc = acc + r0
```

Smi 常量侧还有特化路径 `BinaryOperationSmiLiteral`（8024-8028），省一次寄存器。属性访问例子：`BuildLoadNamedProperty`（bytecode-generator.cc:5140-5145）：

```cpp
FeedbackSlot slot = GetCachedLoadICSlot(object_expr, name);
builder()->LoadNamedProperty(object, name, feedback_index(slot));
```

同名属性访问会经 `FeedbackSlotCache` 去重复用槽（bytecode-generator.h:105、555-561；缓存查找 bytecode-generator.cc:9120）。

### 4.3 主流程与跳转 patch

`GenerateBytecode`（bytecode-generator.cc:1698）→ 寄存器作用域（:1717）→ 生成器函数先发 prologue（:1724-1726）→ 建上下文（:1728-1732）→ `GenerateBytecodeBody`（:1752-1777，按函数种类分流构造器/异步生成器/普通函数体）。最后 `FinalizeBytecode`（bytecode-generator.h:59）产出 BytecodeArray。

跳转用两遍式 patch：先发 `Jump` 占位，`Bind` 时回填——`BytecodeArrayWriter::Bind` 调 `PatchJump`（bytecode-array-writer.cc:186），回填按距离选 8/16 位操作数（`PatchJumpWith8BitOperand` :379、`PatchJumpWith16BitOperand` :407）；放不下的自动加 Wide 前缀重写。`BytecodeLabels::Bind`（bytecode-label.cc:20）处理一个标签多个前向引用。

### 4.4 反馈槽埋点

- IC 类槽（加载/存储/调用）在**编译期**登记进 `FeedbackVectorSpec`：`feedback_spec()`（bytecode-generator.h:606）、`feedback_index`（:607）。调用槽 `AddCallICSlot` 遍布 VisitCall（如 bytecode-generator.cc:3389、5389、7096）；for-in 槽 :3264；typeof 槽 :7386。
- 运行时这些槽位由 IC 系统写形态（monomorphic→megamorphic），`FeedbackNexus::ConfigureMonomorphic`（src/objects/feedback-vector.h:1055）即入口；TurboFan 读同一份数据做投机优化。
- **算术/比较/一元运算的反馈已经不走向量**：本 commit 中 `Add/Sub/Mul/...` 的最后一个操作数是 `OperandType::kEmbeddedFeedback`（bytecodes.h:213-215 等），一个**直接嵌在字节码里的 1 字节类型索引**（bytecode-operands.h:46 `V(EmbeddedFeedback, OperandTypeInfo::kFixedUnsignedByte)`），由 handler 原地更新（`UpdateEmbeddedFeedback`，src/codegen/code-stub-assembler.h:3947）。解码器打印时显示为类型字符串（src/interpreter/bytecode-decoder.cc:183-190）。这是"轻反馈就地存、重反馈进向量"的分层设计。

---

## 5. 字节码格式专节：bytecodes.h

### 5.1 指令集概貌

总表 `BYTECODE_LIST_WITH_UNIQUE_HANDLERS_IMPL`（src/interpreter/bytecodes.h:60 起），宏展开共约 193 条（按 `ImplicitRegisterUse` 计数）。分组摘录：

| 组 | 代表字节码（bytecodes.h 行号） |
|---|---|
| 宽度前缀 | `Wide`/`ExtraWide`（:62-63），运行时按需放大操作数（`OperandScaleToPrefixBytecode` :678-684） |
| 累加器装载 | `Ldar`(:87) `LdaSmi`(:89) `LdaConstant` `LdaZero/Undefined/Null/TheHole/True/False` |
| 寄存器搬运 | `Star`(:110) `Mov` `PushContext/PopContext`；`Star0..Star10` 短格式省操作数字节（:30-41） |
| 属性 IC | `GetNamedProperty`(:168-170) `GetKeyedProperty`(:174) `SetNamedProperty`(:190) `SetKeyedProperty`(:196)，全部带 `kFeedbackSlot` 操作数 |
| 调用 | `CallProperty` 家族宏 `CALL_PROPERTY_BYTECODES`（:42-52），操作数 `kRegList+kRegCount+kFeedbackSlot` |
| 二元/一元 | `Add`(:213) `Sub` `Mul` `Div` `Mod` `Exp` `BitwiseOr`...，操作数 `kReg+kEmbeddedFeedback` |
| 控制 | `Jump`(:407) `JumpLoop`(:408-410，含 OSR 用的 `kFeedbackSlot`) `JumpIfFalse` 等 |
| 对象创建 | `CreateClosure`(:383) `CreateRegExpLiteral`(:362) `CreateArrayLiteral/ObjectLiteral`（常量池索引+槽） |
| 生成器 | `SwitchOnGeneratorState`(:491) `ResumeGenerator`(:496) |

操作数类型体系在 src/interpreter/bytecode-operands.h：可伸缩无符号（`UNSIGNED_SCALABLE_SCALAR_OPERAND_TYPE_LIST` :31）与寄存器类（:56）等；`kEmbeddedFeedback` 是定长 1 字节（:46）。

### 5.1.1 两条值得写的编码细节

其一，短星字节码：`Star0..Star10` 是 `Star r0..r10` 的单字节特化（bytecodes.h:30-41，宏标注 `kReadAccumulatorWriteShortStar`），高频"累加器→寄存器"搬运被压到 1 字节，这解释了 Ignition 代码为什么如此依赖累加器。其二，操作数宽度是**惰性升级**的：编译期一律按 `OperandScale::kSingle` 发码，`BytecodeArrayWriter` 在 `Bind` 回填时发现操作数放不下才整体升 Wide/ExtraWide（bytecode-array-writer.cc:379/407 + bytecodes.h:678-684 前缀映射），因此跳转 patch 与宽度选择是同一处逻辑的两面。

### 5.2 与 quickjs 字节码对照（第五系列二）

| 维度 | V8 Ignition | quickjs |
|---|---|---|
| 结果模型 | 显式累加器 + 溢出寄存器 | 栈式（sp 推拉），无累加器概念 |
| 指令形态 | 定长 opcode + 定/变宽操作数，前缀放大 | 变长，操作数多为定宽 u16/u32 |
| 常量池 | 独立 constant pool（`ConstantArrayBuilder`），`LdaConstant` 按索引取 | 原子直接嵌指令，对象字面量模板 |
| 反馈 | 内嵌 IC 槽号 + embedded 1 字节类型反馈 | 无类型反馈（靠形状缓存 + 内建快慢路径） |
| 源码级调试 | 精确 source position 表（bytecode-source-info.cc） | 行号表较粗 |
| 生成器 | 专用字节码（SwitchOnGeneratorState 等） | 重用跳转+显式状态机 |

V8 字节码更"胖"，因为它要同时喂解释器与优化编译器（槽号即契约）；quickjs 字节码只为解释器自己服务，追求紧凑。

### 5.3 编译缓存

- 同源码脚本缓存：`CompilationCacheScript`（src/codegen/compilation-cache.h:49，按源串+上下文查 SFI），eval 用 `CompilationCacheEval`（:79），正则字面量数据也有独立缓存（:109）。
- 字节码级持久缓存（code cache）：`CodeSerializer`（src/snapshot/code-serializer.h:60）把已编译字节码序列化给嵌入方（Chrome 缓存 .js 的产物）；compiler.cc:3591 起是 `kProduceCodeCache` 等缓存行为枚举。

---

## 6. 设计动机

1. **惰性解析的工程学**：JS 应用的典型画像"大量声明、少量执行"。PreParser 用"共享递归下降骨架 + 哑节点工厂"（preparser.h:15-21）把校验成本压到最低，同时保住两条硬约束——语法错误早晚要报、内部函数元数据（边界/参数）必须现在就有。回退路径（parser.cc:3118 bookmark）保证了正确性永不让位于性能。
2. **反馈向量是分层编译的桥**：Ignition 慢是设计使然——它同时是解释器和"传感器"。编译期 `FeedbackVectorSpec` 定槽位（feedback-vector.h:593，`AddLoadICSlot` :620 等），执行期 IC 填形态，运行计数驱动 tiering（feedback-vector.h:363 `kInvocationCountBeforeStableDeoptSentinel`；tiering-manager.cc:317），TurboFan/Maglev 消费同一份证据。没有这份契约，分层编译无从谈起。
3. **为什么有 AST 仍被批评慢**：对照 quickjs 直出字节码，V8 的每份源码要付 1-3 遍钱（preparse + full parse + 可能的补解析）；AST 是完整的、Zone 短命的但依然昂贵。V8 的赌注是：这些前期成本换来的是 IC 生态与优化编译器的可优化性，对长生命周期应用是正收益，对短脚本则未必——这正是 compile-hints（parser.cc:2843-2846）与并行编译任务（parser.cc:2907-2917）这些"减负阀"存在的原因。
4. **累加器 + peephole 的组合**：生成器可以"乱用"寄存器求正确（bytecode-register-optimizer.h:17-19），由后端统一消除冗余搬运，简化前端正确性论证——与 quickjs"边解析边出码、无回头路"形成方法论对照。

---

## 7. FAQ 素材

1. **Q: V8 是全量解析吗？** A: 顶层是，内部函数默认只 preparse（parser.cc:2923-2924 `should_preparse`），调用时才真解析+编译（compiler.cc:3012）。
2. **Q: PreParser 会漏报语法错误吗？** A: 会遇到"无法定位"的歧义错误，此时回退到函数头重做全解析（parser.cc:3118 `bookmark.Apply()`），不漏报。
3. **Q: IIFE 会被惰性解析吗？** A: 默认不会——`next_function_is_likely_called` 启发式把紧随 `(` 的函数表达式标为 eager（parser.cc:2840-2841，parser-base.h:489）。
4. **Q: preparse 的结果会复用吗？** A: 会，`ProducedPreparseData` 可随 SFI 保存，二次编译直接 `GetDataForSkippableFunction` 免扫描（parser.cc:3056-3082）。
5. **Q: Ignition 是寄存器机还是栈机？** A: 累加器 + 帧上寄存器文件的混合；寄存器是溢出/中转槽（bytecode-register.h:70 virtual_accumulator）。
6. **Q: 字节码里的 `FBV[12]` 是什么？** A: 调试打印的反馈槽操作数（bytecode-decoder.cc:175-181），指向函数 FeedbackVector 第 12 槽。
7. **Q: `a+b` 的类型反馈存在哪？** A: 本 commit 起直接嵌在 `Add` 字节码的 1 字节操作数里（bytecodes.h:213，bytecode-operands.h:46），不再占向量槽。
8. **Q: 正则字面量何时编译？** A: 词法只扫描边界不解析模式（scanner.cc:1064-1072，body 原样传递）；执行到 `CreateRegExpLiteral` 才 materialize（bytecode-generator.cc:4180-4184）。
9. **Q: AST 会活多久？** A: 单次编译任务内。分配在编译 Zone（ast.h:3087 工厂 `zone_->New`），生成字节码后整体释放。
10. **Q: 脚本缓存有几种？** A: 进程内 CompilationCache（compilation-cache.h:49/79）+ 持久化 code cache（code-serializer.h:60），另有 preparse 数据缓存（parser.cc:3056）。

## 深挖方向

1. `ParserBase` 模板如何同时实例化 Parser/PreParser：CRTP 分发与 `ExpressionT` 参数化（src/parsing/parser-base.h:1515 起的 ParseStatementList 签名）。
2. `BytecodeRegisterOptimizer` 等价类算法：寄存器与累加器的 union-find 式记账及 Flush 时机（bytecode-register-optimizer.h:91-101）。
3. 生成器/async 的字节码切换协议：`SwitchOnGeneratorState`/`ResumeGenerator` 与 `BuildGeneratorPrologue`（bytecode-generator.cc:1724-1726）。
4. compile-hints（`//# allFunctionsCalledOnLoad`）端到端：scanner 魔法注释（parser.cc:2843-2846）→ SFI 标记 → 启动时跳过编译的收益。
5. 嵌入式反馈的迁移史：对比旧 `AddBinaryOpSlot`/`BinaryOpFeedback` 向量槽与本 commit 的 `kEmbeddedFeedback` 接口（interface-descriptors.h:46-47），评估其对 Maglev/TurboFan 前端的影响。
6. 并行编译任务（post parallel compile tasks）如何以 preparse 元数据为界切分工作：parser.cc:2904-2917 的派发条件与 `scanner()->stream()->can_be_cloned_for_parallel_access()`（parser.cc:2909）。

---

## 写作要点速查表

| 事实 | 位置 |
|---|---|
| 解析入口 ParseProgram | src/parsing/parsing.cc:35 |
| 惰性编译触发 Compiler::Compile | src/codegen/compiler.cc:3012 |
| 函数重解析 ParseFunction | src/parsing/parser.cc:1060 |
| eager/惰性启发式 EagerCompileHint | src/parsing/parser.cc:2840-2848 |
| should_preparse 决策 | src/parsing/parser.cc:2923-2924 |
| SkipFunction 跳体 + 回退书签 | src/parsing/parser.cc:3039 / 3118 |
| PreParser "不建树"声明 | src/parsing/preparser.h:15-21 |
| PreParser 记录函数元数据 | src/parsing/preparser.cc:362-371 |
| Scanner 4-token 缓冲 | src/parsing/scanner.h:547-550 |
| 正则字面量只扫不编译 | src/parsing/scanner.cc:1064 |
| AST 节点总表 AST_NODE_LIST | src/ast/ast.h:121-127 |
| AstNodeFactory Zone 分配 | src/ast/ast.h:3087 |
| EagerCompileHint 枚举 | src/ast/ast.h:2362 |
| GenerateBytecode 主入口 | src/interpreter/bytecode-generator.cc:1698 |
| 寄存器分配 NewRegister | src/interpreter/bytecode-register-allocator.h:37-40 |
| peephole 自述 | src/interpreter/bytecode-register-optimizer.h:15-21 |
| 加法编译示例 | src/interpreter/bytecode-generator.cc:7990,8033-8036 |
| LoadNamedProperty + IC 槽 | src/interpreter/bytecode-generator.cc:5140-5145 |
| 字节码总表（约 193 条） | src/interpreter/bytecodes.h:60 |
| Add 嵌入反馈操作数 | src/interpreter/bytecodes.h:213 / bytecode-operands.h:46 |
| FeedbackVectorSpec 槽位登记 | src/objects/feedback-vector.h:593,618-644 |
| tiering 触发 MaybeOptimizeFrame | src/execution/tiering-manager.cc:317 |
| 脚本编译缓存 | src/codegen/compilation-cache.h:49,79 |
| code cache 序列化 | src/snapshot/code-serializer.h:60 |
