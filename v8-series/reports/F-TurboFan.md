# F 篇 · TurboFan：Sea of Nodes 优化管线深读

> 《V8 深读》卷二第 1 章。源码版本：V8 shallow clone，commit `c6a1f7c2`（2026-09 检出），
> 行号均以该 commit 为准，用 grep/Read 实际核对；所有路径均为仓库相对路径。
> 卷一 03 章讲的是"四层金字塔与预算触发"——什么时候进优化层；本章进入优化层内部：
> TurboFan 如何把字节码变成机器码。

---

## 1. 全景：优化管线的阶段清单

### 1.1 入口与两条前端路线

JS 函数优化入口是 `Pipeline::NewCompilationJob`（src/compiler/pipeline.cc:3434），返回
`PipelineCompilationJob`（pipeline.cc:504）。三段式生命周期：PrepareJob（收集反馈、初始化
broker）→ ExecuteJob（建图+优化）→ FinalizeJob（装 Code 对象、登记依赖，pipeline.cc:805-837）。

本 commit 有一个重要事实：**`--turbolev` 已默认开启**（src/flags/flag-definitions.h:1732，
"use Turbolev (≈ Maglev + Turboshaft combined) as the 4th tier compiler instead of
Turbofan"）。ExecuteJobImpl 里按它分叉（pipeline.cc:762-803）：
turbolev=true（默认）走 `CreateGraphWithMaglev`（pipeline.cc:777-780；Maglev 图 →
Turboshaft 图，src/compiler/turboshaft/pipelines.h:163）；turbolev=false 走经典
TurboFan 三步——`CreateGraph`（pipeline.cc:782，字节码→Sea of Nodes）、
`OptimizeTurbofanGraph`（:787，中层优化）、`CreateGraphFromTurbofan`（:790，
调度后的 TF 图 → Turboshaft 图）；随后两条路汇合：OptimizeTurboshaftGraph →
SelectInstructions → AllocateRegisters → AssembleCode。
也就是说：**经典 TurboFan 的"Sea of Nodes 前端+中层"仍在源码树里（本章主体），
但其后端（指令选择/寄存器分配/汇编）已被整体拆除；无论哪条前端路线，最后都在
Turboshaft 后端出码。** pipeline.cc:1839 与 1873 的 `DCHECK(!v8_flags.turbolev)` 也说明
经典路径只剩关 flag 才能走到。

### 1.2 经典 TurboFan 阶段清单（ASCII 图）

```
 字节码 (BytecodeArray)
    │  GraphBuilderPhase        pipeline.cc:854   BytecodeGraphBuilder 建图
    ▼
 [Sea of Nodes 图 TFGraph]                      src/compiler/turbofan-graph.h:32
    │  InliningPhase            pipeline.cc:893   JSInliningHeuristic + JSInliner(+JSCallReducer 等)
    ▼
 ── 阶段组 V8.TFLowering（pipeline.cc:1876 起）─────────────────────────
    │  EarlyGraphTrimmingPhase  pipeline.cc:1023  修剪，保证全图都被类型化
    │  TyperPhase               pipeline.cc:1035  类型推断（含归纳变量）
    │  TypedLoweringPhase       pipeline.cc:1096  JS 算子→Simplified、常量折叠
    │  LoopPeelingPhase / LoopExitEliminationPhase  pipeline.cc:1192/1216
    │  LoadEliminationPhase     pipeline.cc:1273  靠 effect 链的记忆消重复加载
    │  EscapeAnalysisPhase      pipeline.cc:1137  逃逸分析 + 标量替换
    │  SimplifiedLoweringPhase  pipeline.cc:1176  表示选择（Int32/Float64/Tagged）★
    │  GenericLoweringPhase     pipeline.cc:1224  剩余 JS 算子降为 runtime/builtin 调用
 ── 阶段组 V8.TFBlockBuilding（pipeline.cc:1964 起）───────────────────
    │  EarlyOptimizationPhase   pipeline.cc:1242  machine 层公共子表达式/化简
    │  ComputeSchedulePhase     pipeline.cc:1463  Sea of Nodes → 基本块 Schedule
    ▼
 [Schedule（基本块+块内顺序）]
    │  turboshaft::BuildGraphPhase                src/compiler/turboshaft/build-graph-phase.cc:18
    ▼
 [Turboshaft 图（块结构化的 SSA）]                                ── Turboshaft 接管 ──
    │  MachineLoweringPhase     turboshaft/pipelines.h:224
    │  LoopUnrollingPhase       pipelines.h:227
    │  LoadEliminationPhase     pipelines.h:231
    │  MemoryOptimizationPhase  pipelines.h:233   分配折叠/写屏障
    │  CodeEliminationAndSimplificationPhase  pipelines.h:248
    │  InstructionSelectionPhase  turboshaft/instruction-selection-phase.cc:367
    │  寄存器分配（线性扫描）    turboshaft/pipelines.cc:29 起
    │  AssembleCode
    ▼
 机器码（Code 对象）
```

两个贯穿性小事实：
- 每个 phase 是一个 `struct ... { void Run(TFPipelineData*, Zone*, ...) }`，由
  `PipelineImpl::Run<Phase>` 统一驱动（pipeline.cc:839-852）；`RUN_MAYBE_ABORT` 包一层取消检查。
- `UntyperPhase`（pipeline.cc:1056）只在 DEBUG 下跑：simplified lowering 之后节点上的
  Type 已不可信，"从现在起看类型是非法的"（pipeline.cc:1947-1958）。

---

## 2. Sea of Nodes 专节：图就是海

### 2.1 数据结构

图类 `TFGraph`（src/compiler/turbofan-graph.h:32，本 commit 由旧 `graph.h` 更名而来）极小：
只有 `start_`/`end_` 两个哨兵节点、一个 zone 分配器和一个装饰器列表（turbofan-graph.h:108-115）。
一切内容都靠节点的输入边挂起来：

```cpp
// src/compiler/turbofan-graph.h:32-36
class V8_EXPORT_PRIVATE TFGraph final : public NON_EXPORTED_BASE(ZoneObject) {
 public:
  explicit TFGraph(Zone* zone);
  // ...
  Node* start() const { return start_; }
  Node* end() const { return end_; }
```

节点 `Node`（src/compiler/node.h）把所有输入存在一条平铺数组里：值输入、effect 输入、
控制输入依次排布（`InputCount`，node.h:59；索引分段见 node-properties.h:34-52：
帧状态输入 → 控制输入 → effect 输入 → 值输入）。也就是说"边是什么语义"由
`Operator` 声明的输入数量和排布约定决定，而非独立的边类型（node.h:245-266 是
inline/outline 两种存储布局）。内联子图复用同一张图，靠 `SubgraphScope` 暂存并
恢复 start/end（turbofan-graph.h:41-56；js-inlining.cc:797 内联时即用此 scope）。

### 2.2 与普通 SSA-CFG 的区别
传统编译器（LLVM 式）是"CFG + 基本块内 SSA 指令"：指令属于块，顺序即代码顺序。
Sea of Nodes 把三件事全部拆成节点：**运算**=值节点，靠值边连成数据流（没有"寄存器"、
没有"变量"）；**内存/副作用顺序**=effect 边链（Load/Store/Call 串成一条链）；
**控制流**=Branch/IfTrue/IfFalse/Merge/Loop 节点，靠控制边连。
关键在于：普通运算节点不连任何控制边——它不属于任何块。"代码在哪执行"这件事被推迟到
调度阶段才决定。Phi 也不属于块头，而是 Merge 的兄弟节点；解释器帧的恢复信息
（FrameState）同样是普通节点，挂在可能 deopt 的运算上。

### 2.3 为什么 V8 选它
- **调度自由**：只要数据依赖与 effect 顺序满足，运算可以被放进任何控制域。调度器用
  ScheduleEarly（src/compiler/scheduler.cc:1482）/ScheduleLate（scheduler.cc:1855）计算
  每个节点可行的最早/最晚块，再取最小公共支配块的深处——例如循环不变的加载可以被
  移出热路径（前提是 effect 链允许）。
- **死代码消除免费**：没有用的纯运算节点从 `End` 不可达，修剪即可。建图时 liveness
  已过滤（bytecode-graph-builder.cc:859-861 按 `analyze_environment_liveness` 打 flag），
  后续 DeadCodeElimination 贯穿每个 phase。
- **副作用显式化**：effect 链让"哪些运算可以重排/消除"变成图上的可达性问题，这是
  load elimination、escape analysis、memory optimizer 都能写成"沿 effect 链状态传播"的原因。
代价同样明确：人类难以直接阅读图（需要 `--trace-turbo` 出 JSON 可视化），且任何优化在
"数据流+副作用流+控制流"三张网交汇处都容易写错——Turboshaft 重写后端的一大动机就是
回到"块结构化"的图（见第 7 节）。

---

## 3. inlining 专节：把被调者的图搬进来

### 3.1 建图后立刻内联
InliningPhase（pipeline.cc:893-976）在主图刚建好就运行，里面排了一整队 reducer：
DeadCodeElimination、JSCallReducer（把 Array.prototype.forEach 等 builtin 特化成图）、
JSNativeContextSpecialization（按反馈把属性访问特化）、以及 JSInliningHeuristic + JSInliner
（pipeline.cc:933-936 挂入）。启发式入口 `JSInliningHeuristic::Reduce`：从调用点收集候选
（js-inlining-heuristic.cc:230，`CollectFunctions(node, kMaxCallPolymorphism)`），并通过
`CanConsiderForInlining` 检查（同文件 105-145：必须有反馈向量、有字节码、且字节码
没被中途 flush）才算数。

### 3.2 内联预算（行号）

预算全部是 flag（src/flags/flag-definitions.h:1480-1501）：

| flag | 默认 | 含义 |
|---|---|---|
| max_inlined_bytecode_size | 460 | 单个函数可内联的字节码上限（flag-definitions.h:1480） |
| max_inlined_bytecode_size_small | 30 | "小函数"阈值，直接内联不排队（:1499） |
| max_inlined_bytecode_size_cumulative | 920 | 累计内联量上限（:1490） |
| max_inlined_bytecode_size_absolute | 4600 | 绝对硬上限（:1492） |
| max_inlined_bytecode_size_small_total | 30000 | 小函数合计豁免额度（:1494） |
| reserve_inline_budget_scale_factor | 1.2 | 预留预算系数（:1497） |
| min_inlining_frequency | — | 调用点频率阈值（js-inlining-heuristic.cc:322 检查） |

决策逻辑三段：
1. 小函数当场内联：`IsSmall`（js-inlining-heuristic.cc:27-29）→ 直接 `InlineCandidate`
   （:328-336），并计入 `total_ignored_bytecode_size_`（不占正式预算）。
2. 超过硬上限直接放弃：`total_inlined_bytecode_size_ >= max_inlined_bytecode_size_absolute_`
   （:339-341）。
3. 其余进 `candidates_` 集合，`Finalize` 按启发式收益序逐个内联，每轮只内联一个，
   "免得预算被冷调用点吃光"（js-inlining-heuristic.cc:351-354）；每轮还要求
   `候选大小×1.2` 之后仍在累计预算内，给"被内联者暴露出来的新小函数"留余量（:371-381）。

深度限制：`kMaxDepthForInlining = 50`（js-inlining.cc:40），靠数 frame_state 的外层
嵌套层数实现（js-inlining.cc:731-741）；直接递归 f→f 不内联，间接递归放行
（js-inlining-heuristic.cc:264-275）。参数个数也要留安全垫：离 `Code::kMaxArguments`
差 10 以内不内联（js-inlining.cc:669-674）。

### 3.3 多态内联（polymorphic inlining）
调用点反馈了多个目标（最多 `kMaxCallPolymorphism = 4` 个，js-inlining-heuristic.h:66）时，
把一次调用克隆成 N 份，前面接 dispatch。`CreateOrReuseDispatch`（js-inlining-heuristic.cc:731）：
若 callee 本来就是"若干目标经 Phi 合并"的形态且中间无副作用，则**复用**已存在的分支；
否则生成 Switch/比较分支。`InlineCandidate`（:768）：num_calls==1 走普通
`inliner_.ReduceJSCall`（:776）；多目标则克隆调用、各分支分别 `ReduceJSCall`，最后用
Merge/EffectPhi/Phi 把结果接回（:858-871）。每个分支内被调用者已知 → 各自按单态特化
（map 检查内移、直接绑死 target 等），等效于"按反馈形态手写了一条类型分派链"。
内联体本身：`JSInliner::ReduceJSCall`（js-inlining.cc:665）→ 在 `TFGraph::SubgraphScope`
里对被调字节码**再跑一遍 BytecodeGraphBuilder**（js-inlining.cc:797-813），再 `InlineCall`
把 start/end 缝回调用点（js-inlining.cc:964）；sloppy 函数补 ConvertReceiver、构造器补
kConstructInvokeStub 帧状态、实参多于形参补 kInlinedExtraArguments 帧状态
（js-inlining.cc:929-962）。

---

## 4. simplified lowering 专节：性能的核心

JS 值都是 Tagged 指针，但机器算加法得知道是 int32、float64 还是 64 位整数。
SimplifiedLoweringPhase（pipeline.cc:1176-1191，`SimplifiedLowering::LowerAllNodes`，
src/compiler/simplified-lowering.cc:5454）就是决定"每个值用什么机器表示"的地方。
V8 注释明说它必须脱离 Typer 运行，"算出的类型与表示/截断逻辑可能冲突"
（pipeline.cc:1914-1916）。

### 4.1 三阶段（PROPAGATE/RETYPE/LOWER）

```cpp
// src/compiler/simplified-lowering.cc:63-84（摘）
enum Phase {
  // 1.) PROPAGATE: 从 End 逆着推"使用方式"（截断信息），到不动点
  PROPAGATE,
  // 2.) RETYPE: 把类型反馈的信息正向传播到不动点
  RETYPE,
  // 3.) LOWER: 替换/展开/删除算子，并用 RepresentationChanger
  //     在"产出的表示"和"使用方要求的表示"之间插入转换
  LOWER
};
```

驱动者 `RepresentationSelector`（simplified-lowering.cc:306）：给每个节点配一份
`NodeInfo`（:352-360）——输出表示、累计截断、反馈类型。三个 runner：
`RunPropagatePhase`（:723，逆序遍历+revisit 队列到不动点）、`RunRetypePhase`（:741，
顺着反馈类型重算）、`RunLowerPhase`（:774，逐点 `VisitNode<LOWER>` 并落地替换）。

### 4.2 截断（Truncation）：信息就是表示

使用方对值的需求用 `Truncation` 表达（src/compiler/use-info.h:26）：
`None/Bool/Word32/Word64/OddballAndBigIntToNumber/Any`（use-info.h:29-53）。
比如 `x|0` 只需要低 32 位 → Word32 截断；`x & 1` 用作 if 条件 → Bool。
多个使用方合并取更一般的（`Truncation::Generalize`，use-info.h:55-59）。
还有一个精细维度：`IdentifyZeros`——`0 == -0` 吗？乘法结果用作下标时要区分，
用作比较时可不分（use-info.h:82-84，SpeculativeNumberLessThan 处显式传 kIdentifyZeros，
simplified-lowering.cc:2888-2893）。

### 4.3 表示选择的实例

```cpp
// src/compiler/simplified-lowering.cc:1848-1863（摘）
void VisitSpeculativeAdditiveOp(Node* node, Truncation truncation, ...) {
  if (BothInputsAre(node, Type::Integral32()) || ...) {
    if (GetUpperBound(node).Is(Type::Signed32()) ||
        GetUpperBound(node).Is(Type::Unsigned32()) ||
        truncation.IsUsedAsWord32()) {
      // => Int32Add/Sub
      VisitBinop<T>(node, UseInfo::TruncatingWord32(),
                    MachineRepresentation::kWord32);
      if (lower<T>()) ChangeToPureOp(node, Int32Op(node));
```

规则可以概括成三层（以加法/比较为例）：
1. **类型证明**：两侧类型都是 Integral32 且结果在 Signed32/Unsigned32 内，或使用方只要
   Word32 → 纯 `Int32Add`，连溢出检查都消失（simplified-lowering.cc:1852-1863）。
2. **截断允许**：结果虽可能超界，但使用方截断到 Word32 → 仍用 Int32Add
   （:1876-1880，additive-safe-integer 特判）；只当布尔用 → `Word32Equal` 即可。
3. **兜底特化**：反馈说是数 → `Float64Add` + 溢出/非数 deopt 检查；完全未知 →
   保留泛型 builtin 调用。比较类算子同理：Unsigned32 用无符号比较、Signed32 用
   带符号、Boolean 用位测试、否则 Float64Cmp（simplified-lowering.cc:2878-2893 附近）。

**为什么说它是性能核心**：这一步直接决定循环计数器是不是一根寄存器里的 int32、
数组下标比较是不是一条 `cmp`。它跑完后"节点上的类型就作废了"
（pipeline.cc:1947-1951），所以 DEBUG 下紧跟 UntyperPhase 抹掉类型（pipeline.cc:1955-1958）。

---

## 5. escape analysis 专节：让对象消失

### 5.1 虚拟对象与逃逸
EscapeAnalysisPhase（pipeline.cc:1137-1163）分两步：分析（`EscapeAnalysis`，
src/compiler/escape-analysis.cc:938）+ 改写（`EscapeAnalysisReducer`，
escape-analysis-reducer.cc）。分析器沿 effect 链做抽象解释：每个 `Allocate` 节点
建一个 `VirtualObject`（src/compiler/escape-analysis.h:125），每个字段是一个"变量"
（escape-analysis.cc:965-975，按 kTaggedSize 切字段）；变量状态沿 effect 链按控制流
汇合（`VariableTracker`，escape-analysis.cc:99）。逃逸规则
（src/compiler/escape-analysis.cc:634 起的 `ReduceNode`）：存字段到未逃逸虚对象——
把值记进变量，store 本身"标记删除"（kStoreField，:667-681）；读未逃逸虚对象字段——
直接用记录的值替换整个 LoadField（:692-703）；一旦对象被存进别处、当参数传走、
或字段访问算不出偏移——`SetEscaped` 回退为真实分配。

```cpp
// src/compiler/escape-analysis.cc:648-659（摘，例外）
case IrOpcode::kStoreField: {
  // ... TrustedHeapConstant 暂不能进虚对象（会污染 Phi 的压缩表示）
  // BoundedSize 字段 deoptimizer 物化不了，所以不许"去物化"
  if (vobject && !vobject->HasEscaped() &&
      vobject->FieldAt(OffsetOfFieldAccess(op)).To(&var) &&
      !FieldAccessOf(op).is_bounded_size_access) {
    current->Set(var, value);
    current->MarkForDeletion();
```

改写后未逃逸的 `Allocate` 被整体摘除（escape-analysis-reducer.cc:92-101），其字段值
变成散落的标量——对象"标量化"。还有个反向福利：`LoadElement` 若能证明虚对象
只有 1~2 个元素且下标必在界内，可替换成已知值或 `Select`（escape-analysis.cc:708-760），
顺带消灭边界检查。

### 5.2 与 deopt 的逆变换
对象消失了，但 deopt 回解释器时字节码要看到"真实的 JS 对象"。所以改写器把
FrameState 里对虚对象的引用替换成 `ObjectState` 节点（记录各字段当时的标量值），
身份用 `ObjectId` 节点标注（`ObjectIdNode`，escape-analysis-reducer.cc:64-73；
`ReduceDeoptState`，:149-194）。等真的 deopt，deoptimizer 再按这些描述**重新分配对象**
——这就是"逃逸分析的逆变换"，两边的表示必须严格对偶（详见第 6 节）。这也是
escape-analysis.cc:676 注释"bounded size 字段 deoptimizer 物化不了就别虚拟"的原因。

---

## 6. deopt 专节：优化帧怎么变回解释器帧

### 6.1 FrameState 的由来
建图时每个可能 deopt 的运算前都有 eager checkpoint（`PrepareEagerCheckpoint`，
src/compiler/bytecode-graph-builder.cc:1215，内嵌 `Checkpoint` 节点与字节码偏移绑定的
FrameState）；内联则叠出一条 outer frame state 链（js-inlining.cc:731-741 数的就是它）。
FrameState 节点携带：参数、上下文、locals（解释器寄存器）、栈、累加器、外层帧状态、
函数、字节码偏移——恰好是解释器帧需要的全部。

### 6.2 翻译表（translations）
指令选择阶段，每个 deopt 出口把 FrameState 编码成一段"翻译"字节码，写进
DeoptimizationData。CodeGenerator 侧：`BuildTranslation`（src/compiler/backend/
code-generator.cc:1426）→ `BuildTranslationForFrameStateDescriptor`（:1326），按帧类型
发不同起始 opcode：

```cpp
// src/compiler/backend/code-generator.cc:1372-1376（摘）
case FrameStateType::kUnoptimizedFunction: {
  int bytecode_array_id = DefineProtectedDeoptimizationLiteral(...);
  translations_.BeginInterpretedFrame(bailout_id, shared_info_id,
                                      bytecode_array_id, height,
                                      return_offset, return_count);
```

每个值再编码成"它现在在哪"：完整 opcode 表见 src/deoptimizer/translation-opcode.h:24-64：
- `REGISTER / TAGGED_STACK_SLOT`： tagged 值在寄存器/栈槽；
- `INT32_REGISTER / DOUBLE_STACK_SLOT / ...`：**未装箱**的原始值（翻译时带上表示）；
- `LITERAL`：常量直接进 literal 池；
- `CAPTURED_OBJECT(n)` / `DUPLICATED_OBJECT(id)`：逃逸分析产生的虚拟对象及其引用副本
  （translation-opcode.h:39、:50）；
- `OPTIMIZED_OUT`：解释器要但优化代码已不存在的值；`UPDATE_FEEDBACK`：回写反馈向量。
  帧本身也有类型起始码：`BEGIN_WITH_FEEDBACK / BEGIN_WITHOUT_FEEDBACK`（:31-32）、
  `INLINED_EXTRA_ARGUMENTS`、构造器 stub 帧等（translation-opcode.h:24-30）。
指令选择器遍历 FrameState 输入生成这些条目（`AddInputsToFrameStateDescriptor`，
instruction-selector.cc:885；`kDematerializedObject` 分支在 :793-813）。相同翻译可去重
（`MATCH_PREVIOUS_TRANSLATION`，translation-opcode.h:63）。

### 6.3 deopt 时的重建
触发时进入 `Deoptimizer::DoComputeOutputFrames`（src/deoptimizer/deoptimizer.cc:1656）：
读出翻译表 → `TranslatedState` 解析（translated-state.cc:825 处 `kUnoptimizedFunction` 帧）
→ 每个内联帧调 `DoComputeUnoptimizedFrame`（deoptimizer.cc:2034）按
`UnoptimizedFrameInfo::Precise` 精确算出解释器帧大小、填参数/寄存器文件/累加器 →
顶帧最后跳进解释器从 bytecode_offset 继续执行。虚拟对象在 `MaterializeHeapObjects`
（deoptimizer.cc:3165）里重建：`InitializeCapturedObjectAt`（translated-state.cc:2063）
按依赖序先物化子对象，`InitializeJSObjectAt`（translated-state.cc:2563）按 map 填字段；
重复引用的 `DUPLICATED_OBJECT` 从 `MaterializedObjectStore`（translated-state.cc:2779）
取回同一份，保证图上"同一个对象"deopt 后仍是同一个。TranslatedFrame 的全部帧类目
（kUnoptimizedFunction、kInlinedExtraArguments、kConstructCreateStub、
builtin continuation 等）见 translated-state.h:209-219——内联越深，翻译表越长，
这就是"deopt 代价与内联深度成正比"的机械原因。

---

## 7. 设计动机

### 7.1 Sea of Nodes 的取舍
选它是因为优化即图重写：每个 phase 是一组互相组合的 `Reducer`（GraphReducer 固定点驱动，
TypedLoweringPhase 一口气挂 8 个 reducer，pipeline.cc:1096-1135），phase 顺序只是
"把哪些 reducer 一起灌进固定点"的策略。数据/副作用/控制三链分离，让"消除、重排、
特化"都有统一语法。代价是可读性差、验证难，以及调度器复杂——scheduler.cc 近 2000 行
（scheduler.cc:1-1982）只为回答"节点放进哪个块、块内第几位"。

### 7.2 phase 顺序哲学
- 先内联后类型：InliningPhase 在 TyperPhase 之前（pipeline.cc:1849 vs 1884），
  类型看到的是内联后的世界，特化才能复利。
- 类型先于降级：TypedLowering 用类型删检查，SimplifiedLowering 用类型+截断选表示；
  类型一旦"消费"到不可信，立刻 Untyper 封印（pipeline.cc:1947-1958）。
- 逃逸分析放在 load elimination 之后、lowering 之前（pipeline.cc:1898-1907）：
  前者减少噪声，后者需要它把 Allocate 变成机器层表示。
- 调度必须最后：Sea of Nodes 的全部自由保留到 EarlyOptimizationPhase 结束
  （pipeline.cc:1969），然后一次性坍缩成块序（pipeline.cc:1977）。

### 7.3 Turboshaft 为什么重写后端
- **旧后端绑定 Sea of Nodes**：指令选择吃 Schedule，每个后端 phase 都要小心维护
  图/调度一致性；Turboshaft 的图天生按块组织（`Block`+显式前驱，turboshaft/graph.h:587
  的 `class Graph`），操作线性存储（`OpIndex` 索引，graph.h:628-646），phase 写起来
  接近传统 SSA 编译器。
- **CopyingPhase 范式**：Turboshaft 的 phase 是一串 reducer 顺一次图复制改写
  （src/compiler/turboshaft/copying-phase.cc），不做原地固定点改写，中间状态更少。
- **一套后端服务三个前端**：经典 TF、Turbolev（Maglev 图）、CSA/Torque builtins 共用
  OptimizeTurboshaftGraph → SelectInstructions → AllocateRegisters → AssembleCode
  （pipelines.h:200-266、:326；pipelines.cc:29、:131-141）。builtin 另有 CSA 系 phase
  （OptimizeBuiltin，pipelines.cc:107-128）。
- 已迁移清单（对 JS 等于"全部后端"）：machine lowering、循环展开、load elimination、
  memory optimization、指令选择、寄存器分配、出码；TF 侧仅剩前端与中层优化，
  且默认被 turbolev 旁路（flag-definitions.h:1732）。

---

## 8. FAQ 素材

1. **TurboFan 什么时候被触发？** 卷一 03 章的预算/热点计数决定；入口
   `Pipeline::NewCompilationJob`（pipeline.cc:3434）。注意本 commit 默认第 4 层走
   Turbolev（flag-definitions.h:1732），经典 TF 前端需 `--no-turbolev`。
2. **Sea of Nodes 的"海"到底指什么？** 运算节点不固定在任何块里；控制流本身也是
   节点（Branch/Merge/Loop），调度才给节点分配块（scheduler.cc:50-75）。
3. **为什么看不到"寄存器分配前有变量"？** 值就是节点；表示（Int32/Float64/Tagged）
   由 simplified lowering 决定（simplified-lowering.cc:63-84 三阶段）。
4. **`x + y` 最终是几条机器指令？** 类型证明到 Int32 → 一条 add
   （simplified-lowering.cc:1852-1863）；反馈是数 → Float64Add+检查；未知 → builtin 调用。
5. **内联是越大越好吗？** 四道预算闸：单函数 460、累计 920、绝对 4600、小函数豁免
   30000 字节（flag-definitions.h:1480-1501）；Finalize 每轮只放一个候选避免预算被
   冷点吃掉（js-inlining-heuristic.cc:351-354）。
6. **多态调用怎么优化？** 最多 4 个目标各克隆一份调用、各自特化，前面接 dispatch；
   callee 本身是 Phi 时复用已有分支（js-inlining-heuristic.h:66、:731、:768）。
7. **逃逸分析失败对象会怎样？** SetEscaped 后回退为真实分配，字段访问照旧
   （escape-analysis.cc:667-703）；粒度是整个对象，不做"半个对象虚拟"。
8. **deopt 后对象从哪来？** FrameState 里的 ObjectState/ObjectId 描述
   （escape-analysis-reducer.cc:149-194）→ 翻译表 CAPTURED_OBJECT/DUPLICATED_OBJECT
   （translation-opcode.h:39/:50）→ deoptimizer 现场分配（translated-state.cc:2063、:2563）。
9. **为什么内联越深 deopt 越贵？** 一条翻译为每个内联帧各编一段，帧类型还有
   extra-arguments/construct-stub 等变体（code-generator.cc:1372-1419；
   translated-state.h:209-219）。
10. **现在还有"TurboFan 后端"吗？** 没有。指令选择起全部在 Turboshaft
    （pipelines.h:326；GenerateCodeFromTurboshaftGraph，pipeline.cc:480-500）；
    经典 TF 图最后经 `BuildGraphPhase` 从 Schedule 翻译成 Turboshaft 图
    （turboshaft/build-graph-phase.cc:18）。

## 深挖练习

1. **追踪一个 SpeculativeNumberAdd**：`--trace-turbo` 分别在 typer/typed-lowering/
   simplified-lowering 后 dump 图，对照 simplified-lowering.cc:1848-1900 的三分支，
   找出用例走了哪条（Int32/Float64/泛型）。
2. **造一个逃逸/不逃逸对照**：`const p = {x:1}; return p.x` vs `globalThis.p = ...`，
   用 `--trace-turbo-escape`（flag-definitions.h:3970）观察 VirtualObject 生灭与
   FrameState 里 ObjectState 的出现（escape-analysis-reducer.cc:183-192）。
3. **读一次真实 deopt**：`--trace-deopt` 触发 eager deopt，对照
   deoptimizer.cc:1656 与翻译 opcode，手工解码一条 `BeginInterpretedFrame`
   记录（code-generator.cc:1372）。
4. **调度实验**：构造"循环内加载不变量"，比较 `--trace-turbo-scheduler` 前后 ScheduleEarly/ScheduleLate 的块选择（scheduler.cc:1482、:1855）。
5. **对比两条前端**：同一函数分别 `--turbolev` / `--no-turbolev` 跑 `--trace-turbo`，
   对比 Inlining/Typer/SimplifiedLowering phase 的存在性——经典链有而 Turbolev 链没有
   （pipelines.h:200-266）。

---

## 写作要点速查表

| 事实 | 位置 |
|---|---|
| 优化入口 NewCompilationJob；turbolev 默认开 | src/compiler/pipeline.cc:3434；flag-definitions.h:1732 |
| ExecuteJob 三分叉（turbolev/TF→TS 汇合） | src/compiler/pipeline.cc:762-803 |
| 建图/内联/中层优化各 phase | pipeline.cc:854、893、1872-1980 |
| Sea of Nodes 图类 TFGraph + 内联 SubgraphScope | src/compiler/turbofan-graph.h:32、41-56 |
| 字节码建图 CreateGraph / VisitBytecodes / eager checkpoint | bytecode-graph-builder.cc:1180、1495、1215 |
| 内联预算四闸 flag | src/flags/flag-definitions.h:1480-1501 |
| 多态上限=4；dispatch 复用；深度=50 | js-inlining-heuristic.h:66；:731；js-inlining.cc:40 |
| 内联=对被调字节码再跑建图器 | src/compiler/js-inlining.cc:797-813 |
| Typer 装饰器 / Run+归纳变量 | src/compiler/turbofan-typer.cc:497-511、471-495 |
| SL 三阶段 PROPAGATE/RETYPE/LOWER；截断种类 | simplified-lowering.cc:63-84；use-info.h:26-113 |
| 加法表示选择 VisitSpeculativeAdditiveOp | src/compiler/simplified-lowering.cc:1848-1900 |
| 逃逸规则 ReduceNode；虚对象进 deopt 状态 | escape-analysis.cc:634-703；escape-analysis-reducer.cc:149-194 |
| 翻译 opcode 全表（CAPTURED_OBJECT 等） | src/deoptimizer/translation-opcode.h:24-64 |
| 翻译生成 BuildTranslation；重建帧；物化 | code-generator.cc:1426；deoptimizer.cc:2034；translated-state.cc:2563 |
| 调度七步 ComputeSchedule | src/compiler/scheduler.cc:50-75 |
| Turboshaft 已迁 phase 清单 OptimizeTurboshaftGraph | src/compiler/turboshaft/pipelines.h:200-266 |
| TF 图→Turboshaft 图 CreateGraphFromTurbofan | src/compiler/turboshaft/pipelines.cc:181-208 |

（完）
