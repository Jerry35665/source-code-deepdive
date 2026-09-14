# C 篇 · Ignition 解释器与 V8 分层编译入口

> 调研对象:V8 源码,commit `c6a1f7c2`(完整 hash `c6a1f7c29ac6381b8b81ff8eff55ff7587c52bf2`,2026-09-14)。
> 所有 文件:行号 均以该 commit 为准,行号经 grep/Read 实际核对。
> 本文承接 B 篇(解析器与字节码生成):B 篇讲"字节码从哪来",本篇讲"字节码怎么跑、跑热了怎么办"。

---

## 1. 全景:分层编译金字塔

本 commit 的 V8 是**四层执行体系**(层级顺序由 CodeKind 枚举硬编码,`src/objects/code-kind.h:28-32`;枚举顺序即层级高低,`src/objects/code-kind.h:46-48` 有 static_assert):

```
                      ┌──────────────────────┐
                      │      TurboFan        │  CodeKind::TURBOFAN_JS
                      │  顶层优化编译器       │  海量内联 + 类型推测 + 消除
                      │  编译慢(并发) / 峰值最快 │
                      └──────────▲───────────┘
                     tier-up: ~3000 次调用          │ deopt(假设失败)
                                 │                 │ 回退到下层帧
                      ┌──────────┴───────────┐
                      │       Maglev         │  CodeKind::MAGLEV
                      │  中层优化(SSA 图)     │
                      │  快速出码 / 中等峰值   │  默认开启 (flag maglev=true)
                      └──────────▲───────────┘  src/flags/flag-definitions.h:522
                     tier-up: ~400(非 Android)次
                                 │
                      ┌──────────┴───────────┐
                      │      Sparkplug       │  CodeKind::BASELINE
                      │  基线编译:字节码 1:1 直译│
                      │  编译极快 / 略快于解释  │
                      └──────────▲───────────┘
                     tier-up: ~8 次(invocation_count_for_feedback_allocation)
                                 │
                      ┌──────────┴───────────┐
                      │       Ignition       │  CodeKind::INTERPRETED_FUNCTION
                      │  寄存器式字节码解释器   │
                      │  零编译延迟 / 吞吐最低 │
                      └──────────────────────┘
```

各层职责一句话:

| 层 | 本质 | 编译延迟 | 峰值性能 | 关键源文件 |
|---|---|---|---|---|
| Ignition | 寄存器机解释器,handler 是预生成的机器码 | 0(启动即有) | 最低 | `src/interpreter/interpreter.cc` |
| Sparkplug | 逐条字节码直译成机器码,不做优化 | 微秒级(可批量/并发) | 略高于 Ignition | `src/baseline/baseline-compiler.cc` |
| Maglev | 中层 SSA 图优化编译器 | 毫秒级(并发) | 中高 | `src/maglev/maglev-graph-builder.cc`(约 1.8 万行) |
| TurboFan | 顶层优化(内联/类型反馈/逃逸分析) | 十毫秒级(并发) | 最高 | `src/compiler/` |

四层共用一套"解释器帧布局"(见第 3 节):Sparkplug 帧与 Ignition 帧布局完全一致(`src/execution/frame-constants.h:738-741` 的注释明说 Unoptimized frame "interpreted and baseline-compiled" 通用),这是 OSR 和 deopt 能在层间平滑搬运栈状态的地基。

---

## 2. handler 生成专节:CSA/TurboFan 编译 opcode 机器码

### 2.1 分派表:函数指针数组,不是 switch

Ignition 没有 `switch(opcode)` 大循环。每个 Isolate 有一张 `dispatch_table_`:

- `src/interpreter/interpreter.h:109-113`:`static const int kDispatchTableSize = kNumberOfWideVariants * (kMaxUInt8 + 1);` 即 3×256 项(单倍/双倍/四倍操作数宽度各 256 槽),存的是**机器码入口地址**。
- `src/interpreter/interpreter.cc:117-124` `GetDispatchTableIndex`:索引 = opcode + 操作数宽度档位×256。
- `src/interpreter/interpreter.cc:108-115` `SetBytecodeHandler`:`dispatch_table_[index] = handler->instruction_start();` —— 表里就是裸机器码地址。

`Interpreter::Initialize()`(`src/interpreter/interpreter.cc:334-374`)做了三件事:
1. 记下 `InterpreterEntryTrampoline` 内置的入口地址(339-342 行);
2. 先把整张表填成 `IllegalHandler`(350-354 行)——注释明说:遇到非法 opcode 直接按 sandbox 违规上报,因为"攻击者控制的字节码执行是逃逸沙箱的典型症状";
3. `ForEachBytecode`(319-332 行)对每个 (bytecode, operand_scale) 组合,经 `BuiltinIndexFromBytecode`(73-98 行)查到对应 builtin,填表(356-372 行)。

### 2.2 关键机制:handler 本身是 TurboFan 编译出的机器码

V8 的 opcode handler 不是手写汇编,而是 **用 CodeStubAssembler(CSA,TurboFan 后端的前端 DSL)写、构建期经 TurboFan 管线编译成 builtin 的机器码**:

- 每个 handler 在 `src/interpreter/interpreter-generator.cc` 里用宏 `IGNITION_HANDLER(Name, BaseAssembler)` 定义(46-66 行):宏展开出一个 `Name##Assembler` 类,`GenerateImpl()` 里写 CSA 代码。全文件共 **194 个 `IGNITION_HANDLER`**。
- 构建入口:`src/builtins/setup-builtins-internal.cc:370-390` `CompileBytecodeHandler`,创建 `compiler::Pipeline::NewBytecodeHandlerCompilationJob`(381-386 行)——**走 TurboFan 编译管线**,再经 `scheduler.CompileCode` 出码。
- 总分派:`src/interpreter/interpreter-generator.cc:3581-3602` `GenerateBytecodeHandler`,一个大 switch 把每个 `Bytecode::kXxx` 路由到 `Name##Assembler::Generate`。
- 该 commit 里还有一条**正在迁移的 Turboshaft(TSA)路径**:`CompileBytecodeHandlerTSA`(`setup-builtins-internal.cc:347-368`)与 `GenerateBytecodeHandlerTSA`(`interpreter-generator.cc:3562-3579`),目前只有 `BitwiseNot` 等极个别 handler 有 TSA 版本(`src/interpreter/bytecodes.h:277` 的 `V_TSA(BitwiseNot,...)`),且整体切换被 `V8_ENABLE_EXPERIMENTAL_TSA_BUILTINS` 门控(`src/interpreter/bytecodes.h:509-520`)。

看三个典型 handler 的 CSA 实现有多"汇编味":

```cpp
// src/interpreter/interpreter-generator.cc:80-84
IGNITION_HANDLER(LdaSmi, InterpreterAssembler) {
  TNode<Smi> smi_int = BytecodeOperandImmSmi(0);
  SetAccumulator(smi_int);
  Dispatch();
}
```

```cpp
// src/interpreter/interpreter-generator.cc:658-670(GetKeyedProperty,键在累加器)
IGNITION_HANDLER(GetKeyedProperty, InterpreterAssembler) {
  TNode<Object> object = LoadRegisterAtOperandIndex(0);
  TNode<Object> name = GetAccumulator();
  TNode<TaggedIndex> slot = BytecodeOperandFeedbackSlot(1);
  TNode<HeapObject> feedback_vector = LoadFeedbackVector();
  TNode<Context> context = GetContext();
  TVARIABLE(Object, var_result);
  var_result = CallBuiltin(Builtin::kKeyedLoadIC, context, object, name, slot,
                           feedback_vector);
  SetAccumulator(var_result.value());
  Dispatch();
}
```

```cpp
// src/interpreter/interpreter-generator.cc:3111-3114
IGNITION_HANDLER(Return, InterpreterAssembler) {
  TNode<Object> accumulator = GetAccumulator();
  Return(accumulator);
}
```

`GetNamedProperty`(602-631 行)更进一步:它不是"调 IC builtin",而是把 `AccessorAssembler::LoadIC_BytecodeHandler` **内联展开进 handler 体内**(624 行),即 IC 的快路径(monomorphic map 检查、直接读字段)被 TurboFan 一并编译进 handler 机器码,慢路径才 lazy 跳到运行时。`LdaGlobal` 同理(214-219 行,`InterpreterLoadGlobalAssembler::LdaGlobal`,205 行内联 `LoadGlobalIC`)。

算术 handler 走 `InterpreterBinaryOpAssembler`(957 行起),如 `Add`(1033-1035 行)委托给 `src/ic/binary-op-assembler.cc` 的 `Generate_AddWithFeedback`:Smí+Smi 快路径内联,字符串/通用路径按 FeedbackVector 槽里的反馈分派——**内联缓存直接焊死在 handler 机器码里**。

### 2.3 Dispatch:尾调用链,没有中央循环

`Dispatch()` 是每个 handler 的收尾动作:

```cpp
// src/interpreter/interpreter-assembler.cc:1402-1408
void InterpreterAssembler::Dispatch() {
  Comment("========= Dispatch");
  TNode<IntPtrT> target_offset = Advance();
  TNode<WordT> target_bytecode = LoadBytecode(target_offset);
  DispatchToBytecodeWithOptionalStarLookahead(target_bytecode);
}
```

最终落到 `DispatchToBytecodeHandlerEntry`(1426-1431 行):**`TailCallBytecodeDispatch` 尾调用**下一个 handler,调用约定由 `InterpreterDispatchDescriptor` 定义(`src/codegen/interface-descriptors.h:2623-2635`),恰好四个参数:

```
kAccumulator(累加器) / kBytecodeOffset(字节码偏移)
kBytecodeArray(字节码数组) / kDispatchTable(分派表)
```

x64 上这"解释器虚拟机状态"就是 4 个物理寄存器(`src/codegen/x64/register-x64.h:364-367`):

```cpp
constexpr Register kInterpreterAccumulatorRegister = rax;
constexpr Register kInterpreterBytecodeOffsetRegister = r9;
constexpr Register kInterpreterBytecodeArrayRegister = r12;
constexpr Register kInterpreterDispatchTableRegister = r15;
```

所以"解释器"在 x64 上的真实形态是:**一串 builtin 机器码互相尾调用,rax 传累加器、r9 传 PC、r12 传字节码、r15 传分派表**——没有 `while(true){switch}` 的解释循环本体(入口 trampoline 只在 handler 返回时兜底推进 PC,见 2.4)。

两个细节:
- **Wide/ExtraWide 前缀**:`DispatchWide`(interpreter-assembler.cc:1433-1461)把前缀 opcode 当基址,索引到 256..511 / 512..767 槽,即宽操作数版本共用另一张逻辑表。
- **Star 前瞻**:`DispatchToBytecodeWithOptionalStarLookahead`(1410-1416 行)对 `Star` 做 lookahead(`StarDispatchLookahead`,1344 行):连续 `Star r0..rN`(ShortStar,共 kShortStarCount 个,见 `src/interpreter/interpreter.cc:77-82` 的索引调整)合并处理,省一次往返分派。

### 2.4 入口跳板 InterpreterEntryTrampoline

每次进入未优化的 JS 函数,先进这个 ASM 手写 builtin(`src/builtins/x64/builtins-x64.cc:1075`,在 `src/builtins/builtins-definitions.h:380` 注册为 `ASM(InterpreterEntryTrampoline, JSTrampoline)`):

1. 从 closure 取 SharedFunctionInfo,再取 BytecodeArray;若已被刷掉则转 `CompileLazy`、若已有 baseline 代码则转 baseline(x64 builtins-x64.cc:1091-1094,`GetSharedFunctionInfoBytecodeOrBaseline` 定义在 723 行);
2. sandbox 下校验 dispatch handle 的参数个数与 BytecodeArray 一致(1096-1110 行);
3. `FeedbackVector.invocation_count++`(1126-1127 行);
4. **压解释器帧**(1139-1157 行):rbp、context、JSFunction、argc、初始字节码偏移、BytecodeArray、FeedbackVector 依次入栈;
5. **在线程栈上分配寄存器文件**(1159-1184 行):从 `BytecodeArray.frame_size_` 读出寄存器个数,做栈限检查后循环 `Push(undefined)` 逐槽初始化;
6. 扣减 interrupt budget:把字节码总长从 `FeedbackCell.interrupt_budget_` 里减掉,透支则调 `Runtime::kBytecodeBudgetInterrupt_Ignition`(1198-1207、1274-1276 行);
7. 装载分派表到 r15,取当前 opcode,`call` 对应 handler(1220-1248 行);
8. handler 尾调用链最终 `ret` 回 trampoline 时(1250-1267 行),重新读帧上的 bytecode array/offset,`AdvanceBytecodeOffsetOrReturn`(958 行定义)决定是继续分派还是返回——这就是 2.3 说的"兜底推进"。

### 2.5 与 switch 解释器(quickjs 等)对照

| 维度 | switch/计算 goto 解释器(quickjs) | Ignition(代码生成 handler) |
|---|---|---|
| opcode 语义实现位置 | C 函数里的 case 分支 | 独立的 builtin 机器码(CSA→TurboFan 编译) |
| 分派 | computed goto / switch 跳转表 | 内存分派表取址 + 尾调用(间接跳转) |
| 值传递 | C 局部变量/虚拟寄存器数组 | 物理寄存器(rax 等)+栈上寄存器文件 |
| IC 快路径 | C 代码内 if 判断 | IC 代码**内联进 handler 机器码**(2.2) |
| 优化机会 | 受限于 C 编译器对整个循环的优化 | 每个 handler 独立走 TurboFan:类型特化、Smi 快路径、消寄存器 |
| 代价 | 一处修改全量重编 | 构建期代码生成复杂(194 个 handler 各自编译) |

本质差异:switch 解释器"解释循环是 C 代码,opcode 语义也是 C 代码";Ignition"没有解释循环,opcode 语义就是各自独立的优化机器码"。分派成本(间接尾调用)换来的是每个 opcode 内部达到接近手写汇编的执行效率,且与上层编译器共享同一套 CSA/IC 基础设施。

---

## 3. 帧布局专节:解释器帧

### 3.1 官方 ASCII 图(源码自带)

`src/execution/frame-constants.h:738-778` 的注释给出了权威布局(节选):

```
//  slot      JS frame
//   0   |   return addr   |   ^
//   1   | saved frame ptr | Fixed Header <-- frame ptr (rbp)
// 2+cp  | [Constant Pool] |
// 3+cp  |     Context     |
// 4+cp  |      argc       |
// 5+cp  |  BytecodeArray  |   ^  Unoptimized 专用头
// 6+cp  |  offset / cell  |   |  (解释器存 offset,Sparkplug 存 FeedbackCell)
// 7+cp  |      FBV        |   v  FeedbackVector
// 8+cp  |   register 0    |   ^
// 9+cp  |   register 1    |   |  Register file(寄存器文件)
//  ...  |  register n-1   |   |  ←就在线程栈上, callee 帧槽之内
```

对应的 C++ 常量(`src/execution/frame-constants.h:780-819`):

- `kBytecodeArrayFromFp`(783 行)、`kBytecodeOffsetOrFeedbackCellFromFp`(785 行)、`kFeedbackVectorFromFp`(787 行)——rbp 之下三个固定槽;
- `kRegisterFileFromFp = -kFixedFrameSizeFromFp - kSystemPointerSize`(793-794 行)——寄存器文件从 rbp 负方向延伸;
- `InterpreterFrameConstants::kBytecodeOffsetFromFp`(817 行):解释器帧里该槽存**字节码偏移**(Smi);`BaselineFrameConstants::kFeedbackCellFromFp`(frame-constants.h:824-830):Sparkplug 帧同一槽存 FeedbackCell——一个槽的语义区分两种帧。

### 3.2 关键推论:寄存器文件 = 栈上内存

- "寄存器"不是物理寄存器,是栈槽。`LoadRegister`/`StoreRegister` 就是相对帧指针的寻址(interpreter-assembler.cc:318-331,`LoadFullTagged(GetInterpretedFramePointer(), reg.ToOperand() * kSystemPointerSize)`);
- `BytecodeRegister` 的 index 被刻意设计成**负的栈偏移换算**:`OffsetFromFPToRegisterIndex`(`src/interpreter/bytecode-register.h:20-22`),参数、receiver、以及 context/closure/bytecode array 等伪寄存器都是统一的寄存器编号空间(bytecode-register.h:120-145);
- 累加器例外:**不占栈槽**,在 handler 机器码里是 SSA 值(`GetAccumulator` 返回 CSA TNode,interpreter-assembler.cc:180-191),分派时经 rax 传递;只有跨调用(critical path)才 `SaveBytecodeOffset` 等写回帧(interpreter-assembler.cc:60-65 的构造逻辑);
- 分配即 `InterpreterEntryTrampoline` 的 push 循环(2.4 第 5 步,x64 builtins-x64.cc:1159-1184),所以寄存器文件**与调用者帧同栈、随帧生灭**,GC 直接把整个解释器帧当对象图扫描——这是"寄存器文件在线程栈上"的完整含义。

### 3.3 帧类体系与遍历

帧类型总表 `STACK_FRAME_TYPE_LIST`(`src/execution/frames.h:119-154`),JS 执行相关四级相邻排布(123-126 行):

```cpp
V(INTERPRETED, InterpretedFrame)     // Ignition
V(BASELINE, BaselineFrame)           // Sparkplug
V(MAGLEV, MaglevFrame)               // 中层优化帧
V(TURBOFAN_JS, TurbofanJSFrame)      // 顶层优化帧
```

类继承(`src/execution/frames.h`):

```
StackFrame(159) → CommonFrame(653) → CommonFrameWithJSLinkage(727)
  → JavaScriptFrame(771)
      → OptimizedJSFrame(1171)  → MaglevFrame(1313), TurbofanJSFrame(1339)
      → UnoptimizedJSFrame(1213)→ InterpretedFrame(1255), BaselineFrame(1286)
```

辅助谓词:`is_optimized_js()` 覆盖 MAGLEV..TURBOFAN_JS(frames.h:245-247)、`is_unoptimized_js()` 覆盖 INTERPRETED..BASELINE(249-250 行,static_assert 保证枚举相邻)。

遍历:`StackFrameIterator::Advance`(`src/execution/frames.cc:190` 起)沿 fp 链向调用者推进(含 wasm 栈切换分支);上层封装 `JavaScriptStackFrameIterator::Advance`(frames.cc:371)。解释器状态的读取接口:

- `UnoptimizedJSFrame::ReadInterpreterRegister(register_index)`(frames.cc:3509-3512):`GetExpression(kRegisterFileExpressionIndex + register_index)`,即从 rbp 负方向取栈槽;
- `InterpretedFrame::GetBytecodeOffset()`(frames.cc:3528-3535)与 `PatchBytecodeOffset`(3537 行):读写帧上那个 Smi 化的偏移槽,异常处理/调试器靠它改写继续执行点。

---

## 4. 分层触发专节:TieringManager 与 interrupt budget

### 4.1 计数载体:interrupt_budget

V8 不数"调用次数",而是**预扣预算**:每个函数的 `FeedbackCell.interrupt_budget_` 是 int32 预算,执行路径按"开销"扣减,透支(减到负)时陷入运行时。

- Ignition 侧:`InterpreterAssembler::UpdateInterruptBudget`(interpreter-assembler.cc:1179-1193)从 closure 拿 FeedbackCell、减 weight、写回;`DecreaseInterruptBudget`(1195-1221 行)在预算 <0 时调 `Runtime::kBytecodeBudgetInterruptWithStackCheck_Ignition` 或 `kBytecodeBudgetInterrupt_Ignition`;
- 触发点:进入函数时按字节码总长扣(trampoline,x64 builtins-x64.cc:1198-1206)、**向后跳转(循环回边)按跳距扣**(`JumpBackward` → `DecreaseInterruptBudget`,interpreter-assembler.cc:1252-1254)、Return 时把"函数末尾到开头的字节数"折算成模拟回边补扣(`UpdateInterruptBudgetOnReturn`,interpreter-assembler.cc:1463;Sparkplug 的 `VisitReturn` 以 `-profiling_weight` 尾调 `BaselineLeaveFrame` 完成同一件事,baseline-compiler.cc:2813-2820);
- 运行时入口:`RUNTIME_FUNCTION(Runtime_BytecodeBudgetInterrupt_Ignition)`(`src/runtime/runtime-internal.cc:482`;同族还有 `_Sparkplug`/`_Maglev`,491/495 行),最终走进 `TieringManager::OnInterruptTick`。

### 4.2 预算大小 = 层级门票

预算初始值由 `TieringManager::InterruptBudgetFor`(`src/execution/tiering-manager.cc:244-268`)决定,公式一律是 `N × 字节码长度`:

| 去向 | N(flag) | 默认值 | 位置 |
|---|---|---|---|
| 分配 FeedbackVector/首次 Sparkplug | `invocation_count_for_feedback_allocation` | 8 | flag-definitions.h:1049 |
| → Maglev | `invocation_count_for_maglev` | 400(Android 1000) | 1054-1059 |
| Maglev OSR | `invocation_count_for_maglev_osr` | 100 | 1060 |
| → TurboFan | `invocation_count_for_turbofan` | 3000 | 1074 |
| TF OSR | `invocation_count_for_osr` | 500 | 1076 |
| IC 变更后的最短等待 | `minimum_invocations_after_ic_update` | 500 | 1081 |

`tiering-manager.cc:180-240` 的内部 `InterruptBudgetFor` 体现策略细节:正在 tiering 时返回 `INT_MAX/2` 防抖(197-199 行);OSR 等待期把预算放大 3 倍(202-205 行,`invocation_count_for_osr_factor_while_tiering_in_progress`);开 `profile_guided_optimization` 时按上次缓存的分层决策(`CachedTieringDecision`)给 kEarlyMaglev/kEarlyTurbofan 减票、kDelayMaglev 加票(216-236 行)——**跨执行的分层学习**。

### 4.3 OnInterruptTick:升级状态机

`TieringManager::OnInterruptTick`(tiering-manager.cc:559-661)按序:

1. 没有反馈向量就先造一个(581-597 行)——"Ignition 无向量"本身被当作一个亚层(564-567 行注释);
2. **Ignition→Sparkplug**:`compile_sparkplug` 条件(`CanCompileWithBaseline` + 当前还在 Ignition,576-578 行)成立时,批量入队 `baseline_batch_compiler()->EnqueueFunction`(611-614 行)或同步 `Compiler::CompileBaseline`(616-619 行);
3. 首次升 Sparkplug 就 return(627-640 行),重新抬高预算等下一轮;
4. 否则 `MaybeOptimizeFrame`(655 行)决定是否请求 Maglev/TurboFan。

`MaybeOptimizeFrame`(317-410 行)里:`ShouldOptimize`(412-452 行)给出 `OptimizationDecision`——Maglev 开启且函数合格则 `OptimizationDecision::Maglev()`(419-428 行,决策定义在 63-67 行,并发模式);否则 TurboFan(430-451 行,含 60KB 字节码上限 447-449 行,flag `max_optimized_bytecode_size` 在 flag-definitions.h:1504)。已排队/编译中则直接返回并冻结进一步 tiering(319-339 行)。

### 4.4 Sparkplug:字节码的 1:1 直译

Sparkplug 的设计约束是"编译必须极快",做法是**放弃优化,逐条字节码翻译,保持解释器帧布局不变**:

- 总控:`BaselineCompiler::GenerateCode`(`src/baseline/baseline-compiler.cc:323-355`)——先 PreVisit 一遍(332-336 行,为每个字节码偏移绑 Label、标记异常处理为间接跳转目标),再逐条 `VisitSingleBytecode`(350-353 行);
- `VisitSingleBytecode`(544 行起)是 `switch (bytecode)` → `Visit##name()`,但**每条 case 只发射直译机器码**,例如:

```cpp
// src/baseline/baseline-compiler.cc:822-825
void BaselineCompiler::VisitLdaSmi() {
  Tagged<Smi> constant = Smi::FromInt(iterator().GetImmediateOperand(0));
  __ Move(kInterpreterAccumulatorRegister, constant);
}

// src/baseline/baseline-compiler.cc:1098-1103
void BaselineCompiler::VisitGetKeyedProperty() {
  CallBuiltin<Builtin::kKeyedLoadICBaseline>(
      RegisterOperand(0),               // object
      kInterpreterAccumulatorRegister,  // key
      FeedbackSlotAsTagged(1));         // slot
}
```

- **零优化**:没有内联、没有类型推测;`kInterpreterAccumulatorRegister` 在 Sparkplug 里退化成专用的物理寄存器角色,寄存器读写直接在帧上的寄存器文件(baseline 复用解释器布局,frame-constants.h:738-741);
- 入口资格 `CanCompileWithBaseline`(`src/baseline/baseline.cc:22-54`):有字节码、调试器不打断点(42-48 行)、过 filter;
- 产物:`GenerateBaselineCode`(baseline.cc:56-68)→ `Build()`(baseline-compiler.cc:357-380)以 `CodeKind::BASELINE` 出码并附**字节码偏移表**(363-367 行,供 OSR/deopt/采样按偏移回查);
- 批量编译 `BaselineBatchCompiler`(`src/baseline/baseline-batch-compiler.cc:259-273` EnqueueFunction):攒队列,估算代码尺寸累计到预算就整批编译(`ShouldCompileBatch`,337 行起),配合 concurrent_sparkplug 在后台线程做(flag 1207/1215 行)——**把逐函数的编译停顿摊平成低优先级批任务**。

### 4.5 Maglev 现状(本 commit)

- 存在且默认开启:`DEFINE_BOOL(maglev, true, ...)`(flag-definitions.h:522);`IsMaglevEnabled` 即读该 flag(`src/codegen/compiler.h:58`);
- 实现规模:SSA 图构建器 `src/maglev/maglev-graph-builder.cc` 约 1.78 万行,后端 `src/maglev/maglev-compiler.cc` 386 行,各架构目录齐备(arm/arm64/loong64 等);
- 在分层里的位置:tiering-manager.cc:171-174 `TiersUpToMaglev` 把它作为 Ignition/Sparkplug 之上的默认升级目标;`InterpretedFrame` 帧类型表中的 `MaglevFrame`(frames.h:1313);OSR 一节还会看到 "Maglev 无 OSR 语义,OSR 进 Maglev 靠 deopt 回 Ignition" 的注释(runtime-compiler.cc:760 附近)。

---

## 5. OSR 专节:热循环的在栈替换

函数整体 tier-up 等不及一个长循环,OSR(on-stack replacement)让**正在解释执行的循环体中途切换到已优化代码**,栈上的解释器帧被替换为优化帧。

触发链(从内到外):

1. `JumpLoop` handler(interpreter-generator.cc:2453-2524):每次循环回边先做廉价检查——比较循环嵌套深度 `loop_depth`(JumpLoop 的立即数操作数)与 FeedbackVector 的 `osr_state`(2477-2489 行),不及格就直接 `JumpBackward`;
2. 深度达标则进入 `InterpreterAssembler::OnStackReplacement`(interpreter-assembler.cc:1515-1609),注释列出三种触发:(1) 已有缓存的 OSR 优化码(1531-1552 行);(2) osr_urgency 超过当前循环深度 → 发起 OSR 编译(1554-1570 行);(3) 已有缓存 baseline 码 → 仅 OSR 到 Sparkplug(1600-1608 行,尾调 `InterpreterOnStackReplacement_ToBaseline`);
3. 换码builtin:`Builtins::Generate_InterpreterOnStackReplacement`(x64 builtins-x64.cc:3050-3056)→ 共享助手 `OnStackReplacement`(2947 行起):有缓存码直接跳,否则 `CallRuntime(Runtime::kCompileOptimizedOSR)`;
4. 编译请求:`RUNTIME_FUNCTION(Runtime_CompileOptimizedOSR)`(`src/runtime/runtime-compiler.cc:714-723`)——注意它请求的目标码是 **CodeKind::MAGLEV**(722 行);从 Maglev 再往 TF 的 OSR 走 `Runtime_CompileOptimizedOSRFromMaglev`(770 行,目标 TURBOFAN_JS)。concurrent_osr 默认开(flag-definitions.h:1539);
5. **urgency 从哪来**:`TieringManager::MaybeOptimizeFrame` 在"函数已被决定 tier-up 但还困在低层帧的长循环里"时调 `TryIncrementOsrUrgency`(tiering-manager.cc:299-303、376-383 行)——即 OSR 是 tier-up 决策的衍生品,不是独立计数;`always_osr` 等极端 flag 走 `TryRequestOsrAtNextOpportunity`(305-308 行,直接拉满 urgency);
6. 替换本体:OSR 编译产物带 `osr_offset`,进入时优化码从解释器帧的寄存器文件里"接管"活值(优化码入口按 BytecodeArray 的寄存器布局读栈),然后控制流跳入优化码的循环头——解释器帧从此废弃。入口跳板在进入前还会重置 `osr_urgency`(x64 builtins-x64.cc:1123 `ResetFeedbackVectorOsrUrgency`)。

---

## 6. 设计动机

**(1)Ignition 为什么诞生:取代 Full-codegen,省内存。**
Full-codegen(旧基线编译器)对每个函数立刻生成完整机器码,内存开销与代码量成正比;Ignition 用紧凑字节码 + 预生成 handler,把"首次执行"成本降到接近零,机器码只在函数变热后按需生成。字节码长度直接参与预算公式(tiering-manager.cc:249-250 取 `bytecode->length()`),可见整个分层体系就是围绕"字节码是冷代码的唯一形态"设计的。

**(2)寄存器机(累加器+寄存器文件)而非栈机。**
累加器让多数指令省一个操作数(B 篇已讲);寄存器文件放栈上则换来:帧就是现成的值容器(GC 扫描、异常展开、调试器求值都直接按 `kRegisterFileFromFp` 寻址,frames.cc:3509-3512),OSR/deopt 时"解释器状态"有稳定的物理落点;Sparkplug 能与解释器共用帧布局,本质是因为两者操作同一块栈内存。

**(3)为什么要"代码生成的 handler"而不是 switch。**
三点:一是**每个 opcode 独立享受 TurboFan**——Smi 快路径、map 检查、甚至整个 IC 快路径(GetNamedProperty,interpreter-generator.cc:602-631)被特化成无分支或少分支机器码,C 编译器对 switch 循环做不到这种按 opcode 的定制;二是**分派极简**——handler 结尾一个间接尾调用(interpreter-assembler.cc:1426-1431),VM 状态走物理寄存器,无需中央循环保存/恢复;三是**代码复用**——CSA 让 handler 与 builtin、IC 共享同一套抽象,Sparkplug 甚至直接复用 `*ICBaseline` builtin(baseline-compiler.cc:1099)。代价是构建复杂(194 个 handler 全部过一遍 TurboFan)与间接跳转的分支预测压力——后者正是引入 Sparkplug 的动机之一(给 CPU 一个真实的线性指令流)。

**(4)多层 = 延迟-吞吐的阶梯。**
四层每上一级,编译开销约贵一个数量级、峰值性能也高一截;interrupt budget 按"字节码长度 × 次数"计价,让小函数和大函数以相近的真实工作量为门票;Sparkplug 以近零成本垫平"解释器太慢、优化编译又没好"的窗口(同时改善启动延迟与代码体积,还能给上层优化充当 inline 源)。Maglev 填补"Sparkplug 不够快、TurboFan 编译太贵/易 deopt"的中段。IC 变更会重置预算(`NotifyICChanged`,tiering-manager.cc:475-552):反馈刚被推翻就急着优化是浪费,`minimum_invocations_after_ic_update`(500)让反馈"稳定"后才升级——`ShouldOptimize` 命名里的 stable 即此意。

**(5)CSA/TSA 的战略意义。**
handler、builtin、IC 全部用 CSA(TurboFan IR 的 DSL)书写,意味着一份语义实现可以喂给不同后端(TurboFan/Turboshaft),架构移植只换后端;本 commit 正在把 handler 从 CSA 迁往 Turboshaft(`interpreter-generator-tsa.cc`、`bytecodes.h:509-520` 的实验门控),方向是统一到单一 IR。

---

## 7. FAQ 素材

1. **Ignition 有解释循环吗?** 没有中央 `switch` 循环。每个 opcode 是一段独立 builtin 机器码,结尾尾调用下一个 handler(interpreter-assembler.cc:1402-1431);`InterpreterEntryTrampoline` 只负责建帧和 handler `ret` 回来时兜底推进 PC(x64 builtins-x64.cc:1253-1267)。
2. **累加器存在哪?** handler 机器码里是 SSA 值,跨 handler 分派时经 `kInterpreterAccumulatorRegister`(x64 为 rax)传递;不占寄存器文件栈槽。
3. **"寄存器"是什么?** 解释器帧内的栈槽(`kRegisterFileFromFp`,frame-constants.h:793),进入函数时按 `BytecodeArray.frame_size_` 压 undefined 初始化(x64 builtins-x64.cc:1159-1184);context/closure/bytecode array 等也伪装成寄存器编号(bytecode-register.h:120-145)。
4. **分派表多大?** 3×256 项(kDispatchTableSize,interpreter.h:109),单/双/四倍操作数宽度各占 256;未定义槽预填 IllegalHandler 以便沙箱拦截(interpreter.cc:344-354)。
5. **函数怎么被判定"热"?** 不数调用次数,扣 `FeedbackCell.interrupt_budget_` 预算:进函数扣字节码总长、回边按跳距扣(interpreter-assembler.cc:1179-1193、1252-1254),透支进 `OnInterruptTick`(tiering-manager.cc:559)。
6. **升级路径一定逐层走吗?** Sparkplug 首次升级后即返回(627-640 行),下一轮预算透支才评估 Maglev/TurboFan;Maglev 关闭或函数不合格时 ShouldOptimize 直接给 TurboFan(tiering-manager.cc:419-451)。
7. **Sparkplug 为什么快(编译快)?** 逐条直译不优化(baseline-compiler.cc:544 起的 Visit 全是直译),还能批量/并发编译摊平停顿(baseline-batch-compiler.cc:259-273、337)。
8. **Sparkplug 与解释器帧什么关系?** 布局相同(frame-constants.h:738-741),`offset/cell` 槽一槽两义:解释器存字节码偏移、Sparkplug 存 FeedbackCell(809-830 行),所以两者间切换/OSR 无需翻译栈。
9. **OSR 到哪层?** 解释器热循环默认 OSR 进 Maglev(runtime-compiler.cc:714-723 目标是 CodeKind::MAGLEV),Maglev 内的循环再 OSR 进 TurboFan(770 行);有缓存的 Sparkplug 码时可先 OSR 到 baseline(interpreter-assembler.cc:1600-1608)。
10. **为什么 IC 一变就不急着优化?** 反馈被推翻说明类型假设不稳,`NotifyICChanged` 重置预算并强制再等 ≥500 次调用(tiering-manager.cc:475-552、flag-definitions.h:1081),避免编出马上 deopt 的码。

## 深挖线索

1. **TSA 迁移**:handler 从 CSA 转向 Turboshaft Assembler 的进行时状态——`GenerateBytecodeHandlerTSA`(interpreter-generator.cc:3562)目前仅覆盖极少数 opcode(bytecodes.h:277 只有 `BitwiseNot` 带 `V_TSA`),`V8_ENABLE_EXPERIMENTAL_TSA_BUILTINS` 门控全量切换(bytecodes.h:509-520);跟踪 `src/interpreter/interpreter-generator-tsa.cc` 可看到迁移战术。
2. **Star 前瞻分派**:`StarDispatchLookahead`(interpreter-assembler.cc:1344)把 `Star` 后紧跟的 ShortStar 合并成单次分派,是"handler 生成"特有的指令选择优化;Sparkplug 侧如何等价处理(baseline 无 lookahead)可对照。
3. **profile-guided 分层学习**:`CachedTieringDecision` 如何在函数上一次执行的分层表现(kEarlyMaglev/kDelayMaglev 等)写回 SharedFunctionInfo 并影响下次预算(tiering-manager.cc:216-236、497-538)。
4. **沙箱加固**:分派表全量预填 IllegalHandler(interpreter.cc:344-354)与 trampoline 里的参数个数 SbxCheck(x64 builtins-x64.cc:1096-1110)——字节码分派路径的攻击面治理。
5. **Jitless 模式**:同一套代码在 `V8_JITLESS` 下剥掉 budget/OSR(trampoline 的 1121-1137 行、JumpLoop 的 2459-2499 行条件编译),可对比嵌入式无 JIT 配置的解释器行为。

---

## 写作要点速查表

| # | 内容 | 文件:行号 |
|---|---|---|
| 1 | 分派表 3×256、存 handler 机器码地址 | src/interpreter/interpreter.h:109-113 |
| 2 | 分派表初始化 + IllegalHandler 预填 | src/interpreter/interpreter.cc:334-374 |
| 3 | handler 索引换算(bytecode×宽度档) | src/interpreter/interpreter.cc:73-98,117-124 |
| 4 | IGNITION_HANDLER 宏(CSA 类包装) | src/interpreter/interpreter-generator.cc:46-66 |
| 5 | GetNamedProperty 内联 LoadIC | src/interpreter/interpreter-generator.cc:602-631 |
| 6 | Add 委托 BinaryOpAssembler(带反馈) | src/interpreter/interpreter-generator.cc:1033-1035 |
| 7 | Dispatch=尾调用下一 handler | src/interpreter/interpreter-assembler.cc:1402-1431 |
| 8 | 分派调用约定(累加器/偏移/数组/表) | src/codegen/interface-descriptors.h:2623-2635 |
| 9 | x64 解释器专用寄存器 rax/r9/r12/r15 | src/codegen/x64/register-x64.h:364-367 |
| 10 | InterpreterEntryTrampoline 建帧+寄存器文件 | src/builtins/x64/builtins-x64.cc:1075-1248(帧 1139-1157,寄存器文件 1159-1184,扣预算 1198-1207) |
| 11 | handler 编译入口(TurboFan job) | src/builtins/setup-builtins-internal.cc:370-390 |
| 12 | 解释器帧布局图 + FP 相对常量 | src/execution/frame-constants.h:738-819 |
| 13 | 帧类型四级排布 INTERPRETED..TURBOFAN_JS | src/execution/frames.h:119-154 |
| 14 | 帧类继承(OptimizedJS/UnoptimizedJS) | src/execution/frames.h:1171,1213,1255,1286,1313,1339 |
| 15 | 帧遍历 Advance / 读寄存器 / 改偏移 | src/execution/frames.cc:190,3509-3512,3528-3541 |
| 16 | interrupt budget 扣减与透支陷入 | src/interpreter/interpreter-assembler.cc:1179-1221 |
| 17 | OnInterruptTick 升级状态机 | src/execution/tiering-manager.cc:559-661 |
| 18 | 层级门票默认值(8/400/3000) | src/flags/flag-definitions.h:1049,1054-1059,1074 |
| 19 | Sparkplug 直译(VisitLdaSmi/GetKeyedProperty/Return) | src/baseline/baseline-compiler.cc:822-825,1098-1103,2813-2820 |
| 20 | OSR 三条件判定 / OSR 编译请求 | src/interpreter/interpreter-assembler.cc:1515-1609;src/runtime/runtime-compiler.cc:714-723 |
