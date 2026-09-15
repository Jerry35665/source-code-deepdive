# G 章：Torque 语言与 builtins 体系

> 调研对象：V8 源码（shallow clone，commit `c6a1f7c2`，2026-09-14）。
> 所有行号均以该 commit 的仓库相对路径核对得出。

你调用的 `Array.prototype.map` 并不是一段 C++ 代码。V8 的内置函数（builtins）按实现语言分成三个层次：**Torque**（DSL，编译成 CSA/C++）、**CSA**（CodeStubAssembler，C++ 写的"汇编生成器"）与**手写汇编**；真正"慢"的部分再兜底到 **C++ runtime 函数**。本章沿 `Array.prototype.map` 一条线把这套体系拆开。

---

## 1. 全景：内置函数的三种实现形态

### 1.1 形态图

```
                        JS 调用 Array.prototype.map
                                  |
        bootstrapper 安装属性: "map" -> Builtin::kArrayMap
        (src/init/bootstrapper.cc:2504 SimpleInstallFunction)
                                  |
    +-----------------------------+------------------------------------+
    |     内置函数本体（Builtin 表中的一个 Code 对象）                    |
    |                                                                  |
    |  形态 A: Torque (.tq)      形态 B: CSA (builtins-*-gen.cc)        |
    |  src/builtins/array-map.tq src/builtins/builtins-regexp-gen.cc   |
    |  领域专用语言               用 C++ API 手写"伪汇编"               |
    |  编译为 CSA C++ 代码        直接调用 CodeStubAssembler            |
    |         \                  /                                     |
    |          \                /                                      |
    |           v              v                                       |
    |        构建期生成 C++ 代码 -> 编译进 V8 二进制                     |
    |        (torque-generated/*.cc, CodeStubAssembler/Turboshaft)     |
    |                                                                  |
    |  形态 C-1: 手写汇编 (ASM)                                         |
    |     JSEntry、CEntry、解释器 trampoline、Call/Construct 存根        |
    |     builtins-definitions.h:40 "ASM: platform-dependent assembly" |
    |                                                                  |
    |  形态 C-2: C++ runtime (RUNTIME_FUNCTION, src/runtime/*.cc)      |
    |     慢路径兜底、启动期逻辑、复杂罕见分支                            |
    +------------------------------------------------------------------+
                                  |
                        Builtins 表 (isolate 内)
                    builtins.h:322 set_code / kBuiltinCount
```

### 1.2 内置函数的"种类"在一张表里声明

`src/builtins/builtins-definitions.h:40-54` 用注释定义了每个内置的种类（这是理解整个体系的钥匙）：

```cpp
// CPP: Builtin in C++. Entered via BUILTIN_EXIT frame.
// TFJ: Builtin in Turbofan, with JS linkage (callable as Javascript function).
// TFS: Builtin in Turbofan, with CodeStub linkage.
// TFC: Builtin in Turbofan, with CodeStub linkage and custom descriptor.
// TFH: Handlers in Turbofan, with CodeStub linkage.
// BCH: Bytecode Handlers, with bytecode dispatch linkage.
// ASM: Builtin in platform-dependent assembly.
```

- **TFJ**（JS 链接）= 可以像 JS 函数一样被调用的内置，`ArrayMap` 就是 TFJ。
- **TFS/TFC**（stub 链接）= 内部辅助内置，被生成的代码直接调用。
- **ASM** = 手写汇编：`Call_ReceiverIsAny`、`JSEntry`、`CEntry` 等（builtins-definitions.h:288-359、1593-1597）。
- 其中 `CEntry`（builtins-definitions.h:1593-1597）是生成代码进入 C++ runtime 的唯一桥梁。

内置总数量是编译期常量：`kBuiltinCount = 0 BUILTIN_LIST(ADD_ONE, ...)`（src/builtins/builtins.h:146-149），列表由 `BUILTIN_LIST` 组合而成，其中 Torque 内置来自生成头文件 `BUILTIN_LIST_FROM_TORQUE`（builtins-definitions.h:16，在 :2036 与 :2050 被拼入总表）。

### 1.3 选择依据：性能要求 × 复杂度

| 场景 | 形态 | 理由 |
|---|---|---|
| Array/TypedArray/String 的热方法 | Torque | 要 GC/越界安全的热路径，又要接近手写代码的密度 |
| 对象 IC handler、正则执行胶水 | CSA | 高度定制的控制流，直用 assembler API 更顺手 |
| 调用序列、栈切换、去优化入口 | 手写汇编 | 寄存器级控制，编译器无法代劳 |
| 罕见分支、反射、调试器、启动 | C++ runtime | 表达力优先，性能不敏感 |

---

## 2. Torque 语言专节

### 2.1 Torque 是什么

Torque 是 V8 自研的领域专用语言：源文件 `.tq`，由构建期运行的 `torque` 编译器（src/torque/torque.cc:22 `WrappedMain`）翻译成 **C++ 写的 CSA 代码**，再随 V8 一起编译。仓库内共 249 个 `.tq` 文件（`find src -name "*.tq"`），其中 `src/builtins/` 下 157 个，共含 372 个 `javascript builtin` 声明。

编译器本体结构（src/torque/）：

- 解析：`torque-parser.cc`（手写解析，辅以 `earley-parser.cc`）
- 两遍声明解析：`torque-compiler.cc:75-85`——"Two-step process of predeclaration + resolution allows to resolve type declarations independent of the order they are given"（预声明→解析→`DeclarationVisitor::Visit`→`TypeOracle::FinalizeAggregateTypes()`）
- 执行/生成：`implementation-visitor.cc`（4375 行，把类型检查过的语句翻译为指令图）
- 后端：`csa-generator.cc`（产出 CSA C++ 代码）、`cc-generator.cc`（产出 C++ class 定义）、`tsa-generator.cc`（实验性 Torque→Turboshaft）

生成哪些文件一目了然（src/torque/torque-compiler.cc:102-121）：

```cpp
implementation_visitor.GenerateInstanceTypes(output_directory);
implementation_visitor.BeginGeneratedFiles();
// ...
implementation_visitor.GenerateBuiltinDefinitionsAndInterfaceDescriptors(
    output_directory);   // torque-generated/builtin-definitions.h
implementation_visitor.GenerateBitFields(output_directory);
implementation_visitor.GenerateClassDefinitions(output_directory);
implementation_visitor.GenerateClassDebugReaders(output_directory);
// ...
implementation_visitor.GenerateExportedMacrosAssembler(output_directory);
implementation_visitor.GenerateCSATypes(output_directory);
// ...
implementation_visitor.GenerateImplementation(output_directory);
```

也就是说 Torque 不只生成内置函数，还生成**对象布局**（class 定义、instance type、bitfield）与**调用描述符**——整个 objects 体系已经 Torque 化。

### 2.2 构建集成

`BUILD.gn` 中定义 `torque_files` 列表（BUILD.gn:2183 起），模板 `run_torque`（BUILD.gn:2755 起）在构建期执行：

```
./torque -o $destination_folder -v8-root . <torque_files...>
```

产物汇入 `torque_generated_definitions` 目标（BUILD.gn:2937），每个 `.tq` 对应输出 `-tq.cc/-tq.h`（BUILD.gn:2724-2746 逐文件声明），并支持 32/64 位双重生成比对（`v8_verify_torque_generation_invariance`，BUILD.gn:2783 起）。另有实验性 `-output-tsa` 直接生成 Turboshaft 图（torque.cc:50，torque-compiler.cc:87-97）。

### 2.3 类型系统：联合、标签与"otherwise"

Torque 的类型系统在 src/torque/types.h：类型基类 `TypeBase` 的 `Kind` 枚举给出全部形态（types.h:33-41）——抽象类型 `AbstractType`（types.h:268）、联合 `UnionType`（types.h:390）、结构体 `StructType`（types.h:620）、类 `ClassType`（types.h:676）、位域结构、函数指针类型与 `TopType`。

JS 值宇宙是用**联合类型**叠出来的（src/builtins/base.tq:97-110）：

```
type JSPrimitive = Numeric|String|Symbol|Boolean|Null|Undefined;   // base.tq:100
type JSAny = JSPrimitive|JSReceiver;                               // base.tq:103
type JSAnyNotNumber = BigInt|JSAnyNotNumeric;                      // base.tq:106
type JSAnyNotSmi = JSAnyNotNumber|HeapNumber;                      // base.tq:110
```

机器类型则用 `generates` 直接映射到 CSA 的 TNode（base.tq:116 起）：

```
type int32 generates 'Int32T' constexpr 'int32_t';
```

关键的"标签"（labels）机制：函数签名可以带若干 label，每个 label 是一个带参数的**受控跳转出口**。`array-map.tq:224` 的 `labels Bailout(JSArray, Smi)` 就是典型。生成的 CSA 层面上，每个 label 变成 `compiler::CodeAssemblerLabel` + 参数绑定（src/torque/csa-generator.cc:390-428，在 `CallCsaMacroInstruction` 发射处逐个创建 label）。

标签联合的"分解"靠 `typeswitch`，它被解析器脱糖成一串 `Cast` 调用（src/torque/torque-parser.cc:1743）；类类型的 `Cast<T>` 也是解析器为每个 class 合成的特化声明（torque-parser.cc:1204），其函数体调用 `DownCastForTorqueClass`（src/builtins/torque-internal.tq:381-382）——**运行时真正做 instance-type 检查**。与之相对，`%RawDownCast` 是零检查的原语（torque-internal.tq:438）：

```
// %RawDownCast should *never* be used anywhere in Torque code except for
// in Torque-based UnsafeCast operators preceeded by an appropriate
// type dcheck()
intrinsic %RawDownCast<To: type, From: type>(x: From): To;   // :438
intrinsic %RawConstexprCast<To: type, From: type>(f: From): To;  // :439
```

`Cast<T>(x) otherwise L` 编译为"类型谓词失败即跳 L"，这就是 Torque 内存安全故事的核心语法。

### 2.4 调外部世界：extern macro 与 extern runtime

Torque 通过 `extern macro` 复用已有 CSA 宏，通过 `extern runtime` 直接调 runtime（.tq 中共 199 处 `extern runtime` 声明，如 base.tq:72 `extern runtime IncrementUseCounter(...)`）。生成端对应 `CSAGenerator::EmitInstruction(CallRuntimeInstruction...)`：发射 `CodeStubAssembler(state_).CallRuntime(Runtime::kFoo, ...)`（src/torque/csa-generator.cc:713-745）；调内置则发射 `CodeStubAssembler(state_).CallBuiltin(Builtin::kBar, ...)`（csa-generator.cc:525-560）。

一个 pure-Torque 的典型小样本——`Math.abs`（src/builtins/math.tq:35-56）：

```
transitioning javascript builtin MathAbs(
    js-implicit context: NativeContext)(x: JSAny): Number {
  try {
    ReduceToSmiOrFloat64(x) otherwise SmiResult, Float64Result;  // :38
  } label SmiResult(s: Smi) {
    // TrySmiAbs 失败走溢出 label，返回 2^31
  } label Float64Result(f: float64) {
    return Convert<Number>(Float64Abs(f));
  }
}
```

`transitioning` 关键字标注"该函数可能触发用户代码/去优化"；`js-implicit context` 声明 JS 链接内置隐式接收 NativeContext。

---

## 3. 三层对照专节：`Array.prototype.map` 的完整一生

`src/builtins/array-map.tq`（302 行）里同时存在"快路径 Torque"与"慢路径回退"两个世界，层进关系如下（行号即出处）：

**第一层：入口（Torque TFJ）**。`ArrayMap`（array-map.tq:259-301）按规范逐条执行：`RequireObjectCoercible`（:262）→ `GetLengthProperty`（:268）→ 校验回调可调用（:271-273）。

**第二层：快路径（Torque 宏）**。protector + 类型守卫全部通过才进入（array-map.tq:282-289）：

```
if (IsArraySpeciesProtectorCellInvalid()) goto SlowSpeciesCreate;   // :282
const o: FastJSArrayForRead = Cast<FastJSArrayForRead>(receiver)
    otherwise SlowSpeciesCreate;                                    // :283-284
const smiLength: Smi = Cast<Smi>(len) otherwise SlowSpeciesCreate;  // :285-286
return FastArrayMap(o, smiLength, callbackfn, thisArg)
    otherwise Bailout;                                              // :288-289
```

`FastArrayMap`（:221-256）用一个 `Vector` 结构体（struct，:96-206）累积结果，并在 `StoreResult` 里用 typeswitch 追踪元素种类 `onlySmis/onlyNumbers/onlyNumbersAndUndefined`（:172-199），据此决定输出数组是 PACKED_SMI / PACKED_DOUBLE / PACKED（:101-124 `CreateJSArray`）。循环里每次回调后 `fastOW.Recheck() otherwise goto PrepareBailout(k)`（:233）防止回调改写了数组。

**回退层（仍在 Torque，但用通用原语）**。bailout 时 `PrepareBailout` 把半成品装进 JSArray 并带着断点 `k` 跳出（:250-253），落回 `ArrayMapLoopContinuation`（:62-94），它用 `HasProperty_Inline`/`GetProperty`/`FastCreateDataProperty`（:74-86）这些会触发 getter、proxy 的通用路径逐元素重做。

**兜底层（C++ runtime）**。规范中真正"魔法"的部分——属性访问与调用——由 `GetProperty`/`Call` 等 extern 宏走 IC/内置，未内联的罕见分支最终落到 `Runtime_*`（如异常构造 `ThrowCalledNonCallable`，array-map.tq:299）。

**去优化协作**。文件开头三个 continuation 内置（array-map.tq:8、:22、:36）是给优化编译器（Turbofan/Maglev 内联 map 后）用的去优化续点：`ArrayMapLoopLazyDeoptContinuation` 的注释写明 "custom lazy deopt point is right after the callback"（:46-49）——回调刚返回、还没写回结果数组时发生去优化，就用它把 `result` 写入再续跑循环（:52-59）。

最后的注册一环在启动期：`SimpleInstallFunction(isolate_, proto, "map", Builtin::kArrayMap, 1, ...)`（src/init/bootstrapper.cc:2504）把 Torque 生成的 `Builtin::kArrayMap` 挂到 `Array.prototype.map` 属性上。

### 3.1 生成什么、何时变机器码？

对每个 `javascript builtin`，Torque 产出（经 `GenerateBuiltinDefinitionsAndInterfaceDescriptors`，src/torque/implementation-visitor.cc:3597）一个 `TFJ` 条目进 `torque-generated/builtin-definitions.h`，以及一份 CSA C++ 实现（`-tq.cc`）。启动时这些 TFJ 条目经 `BUILD_TFJ_WITH_JOB` / `BUILD_TFJ_TSA_WITHOUT_JOB` 宏编译成机器码（src/builtins/setup-builtins-internal.cc:509-520），`Builtins::Generate_##Name` 即生成的 CSA 函数；全部内置装完后 `CHECK_EQ(Builtins::kBuiltinCount, ...)`（setup-builtins-internal.cc:594-595）核验数量，最后统一装入 Builtins 表并 `ReplacePlaceholders`（:603-609）。

---

## 4. runtime 函数专节

### 4.1 清单规模

`src/runtime/runtime.h` 用 52 个 `FOR_EACH_INTRINSIC_<域>` 宏按域分组（ARRAY、ATOMICS、BIGINT、CLASSES、COLLECTIONS、COMPILER、DATE、DEBUG、FORIN、FUNCTION、GENERATOR、INTL、INTERNAL、LITERALS、MODULE、NUMBERS、OBJECT、OPERATORS、PROMISE、PROXY、REGEXP、SCOPES、SHADOW_REALM、STRINGS、SYMBOL、TEST、TYPEDARRAY、WASM、WEAKREF……定义于 runtime.h:49-843），在总宏里汇合（runtime.h:909-916）。全表 `F()`/`I()` 条目约 699 条（awk 统计），其中 inline 内联函数仅 22 条（`kNumInlineFunctions`，runtime.h:960-963）。

### 4.2 调用约定

runtime 函数的 C++ ABI 由 runtime.cc 头部宏写死（src/runtime/runtime.cc:12-14）：

```cpp
#define F(name, number_of_args, result_size, ...)               \
  Address Runtime_##name(int args_length, Address* args_object, \
                         Isolate* isolate);
```

要点：参数不在寄存器/栈签名里，而是**打包在 argv 数组**；返回 `Address`（或 `ObjectPair`，result_size=2）；`-1` 表示变参（runtime.h:980-981 注释 "nargs is -1 if the function takes a variable number of arguments"）。定义处用 `RUNTIME_FUNCTION(Name)` 宏（src/execution/arguments.h:191-193，展开自 arguments.h:162-186 的 `RUNTIME_FUNCTION_RETURNS_TYPE`），它包一层 RCS 重入统计、`DisallowGarbageCollection` 断言与结果校验。全部函数的描述符填进静态表 `kIntrinsicFunctions`（runtime.cc:42-45），inline 函数名带下划线前缀 `"_name"`（runtime.cc:29-36 的 `I` 宏）。名字反查入口 `Runtime::FunctionForName`（runtime.cc:342）。runtime 函数描述符本身是四元组 `{FunctionId, IntrinsicType, name, entry, nargs, result_size}`（runtime.h:970-986）。

生成代码进入 runtime 走 `CEntry` 汇编存根（builtins-definitions.h:1593-1597），按"参数放寄存器还是栈、返回 1/2 个值"分成多个变体；Torque/CSA 侧则是上文 `CallRuntime`。

### 4.3 `%` 转义与调试用途

字节码/测试脚本里 `%Foo(...)` 这种 natives syntax 由 `--allow-natives-syntax` 开关控制（src/flags/flag-definitions.h:3334 `DEFINE_BOOL(allow_natives_syntax, false, ...)`），解析后按名字查 `Runtime::FunctionForName` 调用——这是 d8 测试与调试的主力入口（如 `%DebugPrint`、`%OptimizeFunctionOnNextCall`，均来自 FOR_EACH_INTRINSIC_TEST，runtime.h:546 起）。`%_Foo` 形式对应 inline intrinsic（现仅剩 22 个）。调试内置 `Runtime_AbortCSADcheck`（runtime.h:548）供 CSA 生成的断言失败时报告。

### 4.4 与第三方的边界：Math / RegExp / JSON

- **Math 层**：几乎 pure Torque（src/builtins/math.tq），`MathAbs`（:35）等直接内联为几条机器指令，无 runtime 参与。
- **RegExp**：`.tq` 只是外壳（src/builtins/regexp.tq），快路径判断 `BranchIfFastRegExp_*`（regexp.tq:9-31）；引擎执行经 `extern macro RegExpBuiltinsAssembler::RegExpExecInternal_Single`（regexp.tq:76，调用点 :106/:117，CSA 实现在 src/builtins/builtins-regexp-gen.cc:753），最终进入 C++ 的 `RegExp::Exec`（src/regexp/regexp.cc:534）——irregexp（V8 自带正则引擎，src/regexp/ 全家桶）负责真正匹配，还有 experimental 引擎分支（regexp.cc:549）。
- **JSON**：纯 C++。`builtins-json.cc` 提供入口，解析主体是手写递归下降的 `JsonParser`（src/json/json-parser.h:209，`ParseJson` 在 :274）与 stringifier（src/json/json-stringifier.cc）——因为 JSON 解析是数据结构密集的长流程，生成代码无益。

---

## 5. 设计动机

**为什么发明 Torque？** 早期内置大量由 CSA 宏拼成（`builtins-array-gen.cc` 至今保留此类代码），CSA 本质是"C++ 伪汇编"——变量是 TNode、控制流手工接 label，写长就难读易错，且**没有类型检查**：错误的对象布局假设要到运行时崩溃才暴露。Torque 在其上加了：真实的类型系统（联合 + 子类型 + `Cast` 强制检查）、`labels` 显式异常出口、struct/class 与对象布局声明、两遍解析（torque-compiler.cc:75-85）、lint 与"未使用宏"告警（torque-compiler.cc:108 `ReportAllUnusedMacros`）。收益是**编译期安全 + 规范文本可逐条对照**（array-map.tq:73 的 "// 7b. Let kPresent be ? HasProperty(O, Pk)" 规范编号注释直接贴在代码旁）。

**为什么不全用 CSA？** 可读性与维护性：Torque 的 for 循环/typeswitch/struct 对人友好；且 Torque 生成的不只是代码，还有对象布局头文件——CSA 没有这个角色。反过来 CSA 仍保留，因为 IC handler、正则胶水等需要直接操纵 assembler 底层（Torque `extern macro` 的实现就住在 CSA 里）。

**为什么不全用 C++？** 内置函数处于解释器/优化编译器的调用热路径上：C++ 调用约定（栈帧、无尾调用、不能被内联进 JIT 代码）代价太高；生成代码能与字节码/IC 无缝互调，可被 Turbofan 直接内联（快路径宏在编译期可见）。

**"慢路径兜底"哲学**：同一个语义写两遍——快路径假设最好情况（packed Smi 数组、protector 有效、长度是 Smi），任何假设失败就走 `labels Bailout` 带着进度落回通用实现（array-map.tq:250-253）。正确性由慢路径保证，性能由快路径提供，两层不重复实现"语义"，只重复实现"假设"。去优化 continuation（array-map.tq:8-60）是第三重保险：当更上层的 JIT 内联了这些内置，就需要显式续点从优化代码"滑回"内置实现。

---

## 6. FAQ 素材

1. **Q: `Array.prototype.map` 是 C++ 写的吗？** A: 不是。是 Torque（src/builtins/array-map.tq:259），编译为 TFJ 内置 `Builtin::kArrayMap`，启动时由 bootstrapper 安装（src/init/bootstrapper.cc:2504）。
2. **Q: Torque 代码什么时候运行？** A: 两阶段——构建期 `torque` 编译器把 `.tq` 翻成 CSA C++（BUILD.gn:2755 模板）；运行期这些 C++ 随 V8 启动被 `SetupBuiltinsInternal` 编译成机器码（src/builtins/setup-builtins-internal.cc:467）。
3. **Q: `.tq` 文件有多少？** A: src/ 下 249 个，builtins 目录 157 个，共声明 372 个 `javascript builtin`。
4. **Q: Torque 的 `Cast` 和 C++ 的 `static_cast` 一样吗？** A: 不一样。Torque `Cast<T>(x) otherwise L` 是运行时检查 + 失败跳 label；`%RawDownCast` 才是无检查版（src/builtins/torque-internal.tq:438），且注释明令禁止滥用。
5. **Q: `labels` 是什么？** A: 带参数的多出口跳转，等价于受控的"局部异常"。生成 CSA 后是 `CodeAssemblerLabel`（src/torque/csa-generator.cc:390-428）。
6. **Q: runtime 函数有多少个？** A: `FOR_EACH_INTRINSIC` 全表约 699 条 F/I 条目，分 52 个域宏；其中 inline intrinsic 仅 22 个（runtime.h:960）。
7. **Q: runtime 函数怎么传参？** A: 打包成 `(int args_length, Address* args_object, Isolate*)` 三元组（runtime.cc:12-14），返回 Address；result_size=2 时返回 ObjectPair（runtime.h:843 `FOR_EACH_INTRINSIC_RETURN_PAIR_IMPL`）。
8. **Q: `%Foo()` 语法哪来的？** A: `--allow-natives-syntax`（src/flags/flag-definitions.h:3334），按名查 `Runtime::FunctionForName`（runtime.cc:342），仅用于测试/调试。
9. **Q: 内置的启动流程为什么有占位符阶段？** A: 内置之间存在循环引用，先 `PopulateWithPlaceholders`（setup-builtins-internal.cc:402）再全量生成、最后 `ReplacePlaceholders` 重定位（:416）。
10. **Q: 生成内置可以并发吗？** A: 可以。TFJ/TFC/TFS/BCH 走 `BuiltinCompilationScheduler` 后台编译（setup-builtins-internal.cc:574-579 的 WITH_JOB 系列），CPP/ASM 仍主线程直建。

## 深挖方向

1. **Torque→Turboshaft 直通**：`tsa-generator.cc` 与 `-output-tsa` 选项（torque.cc:50，torque-compiler.cc:87-97）正在把 Torque 从"生成 CSA"迁到"直接生成 Turboshaft 图"，builtins-definitions.h:28-33 的 TFJ_TSA/TFC_TSA/BCH_TSA 种类就是过渡痕迹。
2. **对象布局同源**：`GenerateClassDefinitions`/`GenerateInstanceTypes`（torque-compiler.cc:102、113）使 `.tq` 中的 class 声明成为 C++ 对象布局的单一事实源——改布局 = 改 .tq。
3. **内置哈希与并发确定性**：`dump_builtins_hashes_to_file`（setup-builtins-internal.cc:477）与"先无 job 后有 job"的两段构建顺序（:571-573 注释）是可复现构建的细节样本。
4. **正则的完整栈**：从 regexp.tq 的 `RegExpPrototypeExecBodyWithoutResult`（regexp.tq:97-125）→ CSA `RegExpExecInternal`（builtins-regexp-gen.cc:753）→ `RegExp::Exec`（regexp.cc:534）→ irregexp 字节码/原生码，可整链成文。
5. **language server**：Torque 编译器内置 LSP 数据收集（`collect_language_server_data`，torque-compiler.cc:57-59；src/torque/ls/ 目录），V8 团队用自家 DSL 工具链养 IDE 体验。

---

## 写作要点速查表

| 事实 | 位置 |
|---|---|
| `map` 属性安装到 `Builtin::kArrayMap` | src/init/bootstrapper.cc:2504 |
| ArrayMap 入口（TFJ） | src/builtins/array-map.tq:259 |
| 快路径宏 FastArrayMap + `labels Bailout` | src/builtins/array-map.tq:221-224 |
| 快→慢带进度回退（PrepareBailout） | src/builtins/array-map.tq:250-253 |
| 慢路径通用循环 ArrayMapLoopContinuation | src/builtins/array-map.tq:62-94 |
| 懒去优化续点（回调后） | src/builtins/array-map.tq:36-60 |
| `JSAny` 联合类型定义 | src/builtins/base.tq:103 |
| `%RawDownCast` 零检查原语 | src/builtins/torque-internal.tq:438 |
| 内置种类注释（TFJ/TFS/TFC/TFH/BCH/ASM/CPP） | src/builtins/builtins-definitions.h:40-54 |
| `kBuiltinCount` 编译期求和 | src/builtins/builtins.h:146-149 |
| Torque 内置并入 BUILTIN_LIST | src/builtins/builtins-definitions.h:16, 2036 |
| SetupBuiltinsInternal（构建全部内置） | src/builtins/setup-builtins-internal.cc:467 |
| 占位符替换（循环引用） | src/builtins/setup-builtins-internal.cc:402/416 |
| Torque 编译两遍解析 | src/torque/torque-compiler.cc:75-85 |
| 生成产物清单 | src/torque/torque-compiler.cc:102-121 |
| label → CodeAssemblerLabel | src/torque/csa-generator.cc:390-428 |
| Torque 调 runtime 的发射 | src/torque/csa-generator.cc:713-745 |
| runtime 函数 C ABI | src/runtime/runtime.cc:12-14 |
| intrinsic 描述符表 kIntrinsicFunctions | src/runtime/runtime.cc:42-45 |
| `RUNTIME_FUNCTION` 宏 | src/execution/arguments.h:162-193 |
| natives syntax 开关 | src/flags/flag-definitions.h:3334 |
| CEntry（生成代码→C++ 桥） | src/builtins/builtins-definitions.h:1593-1597 |
| irregexp 入口 RegExp::Exec | src/regexp/regexp.cc:534 |
| JSON 解析器（纯 C++） | src/json/json-parser.h:209, 274 |
| MathAbs（pure Torque 样本） | src/builtins/math.tq:35 |
