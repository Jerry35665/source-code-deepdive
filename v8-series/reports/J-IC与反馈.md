# J 章：内联缓存（IC）与反馈向量 —— 把动态属性访问变成静态快路径

> 源码版本：V8 shallow clone, commit `c6a1f7c29ac6381b8b81ff8eff55ff7587c52bf2`（下文简称 c6a1f7c2）。
> 所有 `文件:行号` 均在该 commit 上用 grep/Read 实际核对。注意：该版本的状态机比经典"四态"更细
> （新增 HOMOMORPHIC / MEGADOM / RECOMPUTE_HANDLER 等），本文以源码为准并说明与经典四态的对应。

---

## 1. 全景：一次属性加载的 IC 旅程

```
  obj.x  ──编译──▶  字节码 GetNamedProperty <obj> <name_index> <slot>
                          │            (interpreter-generator.cc:598-631)
                          ▼
        Ignition 处理器：LoadFeedbackVector()，把 slot/name/context 打包成
        LazyLoadICParameters，进入 AccessorAssembler::LoadIC_BytecodeHandler
                          (interpreter-generator.cc:602-624; accessor-assembler.cc:3392)
                          ▼
┌─────────────────── AccessorAssembler（CSA 生成的机器码快路径）───────────────────┐
│ ① 读反馈槽 slot：[feedback, extra] 两个槽位                                     │
│    TryMonomorphicCase：feedback(weak) == receiver_map ?                        │
│    (accessor-assembler.cc:71-102，弱比较在 :93，handler 在槽位+1 :95-97)         │
│        命中 ──▶ HandleLoadICHandlerCase：handler 是 Smi 编码                    │
│                  └▶ kField：解码 offset → LoadObjectField 直接取字段             │
│                     (accessor-assembler.cc:868-872 → 600-631)                  │
│        未命中 ─▶ ② feedback 是 WeakFixedArray？→ HandlePolymorphicCase          │
│                  线性反向扫描 (map,handler) 二元组表 (:104-145)                  │
│        未命中 ─▶ ③ feedback == megamorphic_symbol？                             │
│                  → TryProbeStubCache：主表/次表两表哈希探测                       │
│                     (accessor-assembler.cc:3708,3716-3718; 3355-3388)          │
└───────────────────────────────────────────────────────────────────────────────┘
        全部 miss ──▶ Runtime::kLoadIC_Miss（accessor-assembler.cc:3456-3463）
                          ▼
        C++ 运行时 Runtime_LoadIC_Miss（ic.cc:3238-3270）
        → LoadIC ic(...); ic.Load(receiver, key)（ic.cc:416-491）
        → LookupIterator 全量属性查找（ic.cc:456-460：LookupIterator + LookupForRead）
        → LoadIC::UpdateCaches(lookup)：按 lookup->state() 生成 handler
          （ic.cc:1061-1114：ACCESS_CHECK→LoadSlow :1063-1064；NOT_FOUND→LoadNonExistent
            :1065-1072；正常路径→ComputeHandler :1104）
        → IC::SetCache：按当前状态升级反馈槽（ic.cc:1000-1059 状态机）
        → megamorphic 时同步写入全局 StubCache（UpdateMegamorphicCache, ic.cc:1130-1144）
                          ▼
        下一次执行同一字节码：反馈槽里已是 (weak map, handler)，
        机器码第①步直接命中 —— "自修改"完成，慢路径只跑一次。
```

要点：解释器本身不做属性查找，它只是 IC 的"装载器"。真正的查找只发生在 miss 时的
LookupIterator（`src/ic/ic.cc:456-460`），结果被"记忆"在反馈槽里。

---

## 2. 状态机专节：从 UNINITIALIZED 到 MEGAMORPHIC

### 2.1 状态全集

状态枚举 `InlineCacheState` 定义在 `src/common/globals.h:1896-1915`，共 9 态：
`NO_FEEDBACK / UNINITIALIZED / MONOMORPHIC / RECOMPUTE_HANDLER / POLYMORPHIC / MEGADOM /
HOMOMORPHIC / MEGAMORPHIC / GENERIC`。经典"四态"是其中主干；`HOMOMORPHIC`（多个 map、
同一个 Smi handler，用小型哈希数组缓存，实验性 flag `homomorphic_ic`，
flag-definitions.h:3317）与 `MEGADOM`（大量 DOM 接收者共享同一 accessor，globals.h:1907-1908）
是后加的旁路。

### 2.2 槽内编码如何映射到状态

`FeedbackNexus::ic_state()`（feedback-vector.cc:698-770）纯靠槽内容判态，对
`kLoadProperty` 类槽位（feedback-vector.cc:721-760）：

```cpp
if (feedback == UninitializedSentinel())   return UNINITIALIZED;   // :731-733
if (feedback == MegamorphicSentinel())     return MEGAMORPHIC;     // :734-736
if (feedback == MegaDOMSentinel())         return MEGADOM;         // :737-740
if (feedback.IsWeakOrCleared())            return MONOMORPHIC;     // :741-744
if (IsWeakFixedArray(heap_object))         return POLYMORPHIC;     // :747-751
if (IsWeakHomomorphicFixedArray(...))      return HOMOMORPHIC;     // :752-754
```

即：一个弱 Map 指针 = 单态；`(map,handler)` 对的 WeakFixedArray = 多态；
两个哨兵 Symbol = 超多态/超单态变体。槽的物理布局见第 4 节。

### 2.3 状态迁移主入口 IC::SetCache

`IC::SetCache(name, handler)`（ic.cc:1000-1059）是一张显式的 fallthrough 迁移表：

- `UNINITIALIZED` → `UpdateMonomorphicIC`：写 (weak map, handler)（ic.cc:1007-1015, 918-922）。
- `MONOMORPHIC`/`RECOMPUTE_HANDLER` → `UpdatePolymorphicIC` 尝试并入（ic.cc:1016-1031）。
- `POLYMORPHIC` → `UpdatePolymorphicIC`；失败则尝试 `UpdateMegaDOMIC`（ic.cc:1025-1032）。
- `HOMOMORPHIC` → `UpdateHomomorphicIC`；失败则把现有条目**倒进全局 StubCache**
  （`CopyICToMegamorphicCache`, ic.cc:924-930, 1041-1043）。
- `MEGADOM`/任意 → `ConfigureVectorState(MEGAMORPHIC, name)`（ic.cc:1045-1046），
  槽内只留 megamorphic 哨兵（feedback-vector.cc:674-687，extra 记录 kProperty/kElement）。
- `MEGAMORPHIC` → 每次 miss 只做 `UpdateMegamorphicCache` 刷新 StubCache（ic.cc:1048-1055）。

### 2.4 多态的准入条件（UpdatePolymorphicIC）

`IC::UpdatePolymorphicIC`（ic.cc:731-842）决定"还能不能再塞一个 map"：

- 同一 map + 同一 handler 再次出现 = 状态不再前进，返回 false → 终将
  `ConfigureVectorState(MEGAMORPHIC)`（ic.cc:758-779，注释在 :760-763）。
- 字典 map 且 handler 变了（rehash）：直接放弃并 go megamorphic，防 deopt 循环
  （ic.cc:788-793）。
- 同 map 但 handler 不同（原型链查找失败）：**覆盖**旧 handler 而不是新增
  （ic.cc:795-798）；`IsTransitionOfMonomorphicTarget`（elements-kind 更泛化迁移，
  ic.cc:932-947）同样触发覆盖（:799-802）。
- 容量上限 `v8_flags.max_valid_polymorphic_map_count`（默认 10，
  flag-definitions.h:3286-3287；判断在 ic.cc:813-818，keyed 侧 :1611-1615）。
- 弃用 map（deprecated）会被过滤以便实例迁移（ic.cc:755-757）。
- key 型 IC 要求名字一致才可并入（ic.cc:734-736, 827）。

### 2.5 RECOMPUTE_HANDLER：原子链变化时的降半态

原型链或 map 弃用可能让旧 handler 失真。`IC::UpdateState` 在每次进入 IC 时检查
`ShouldRecomputeHandler`（ic.cc:316-318, 266-292），命中则把内存中的 IC 置为
`RECOMPUTE_HANDLER`（ic.h:49-53，只改 IC 对象状态不改槽）。该态下允许"同 map 换新
handler"而不判死（ic.cc:762-765），避免过早 megamorphic。

### 2.6 megamorphic 的全局 StubCache：两表哈希（名字+map→handler）

```
Entry { key(Name), value(handler), map(Map) }        // stub-cache.h:34-43
Primary 表:   2^12 项  (kPrimaryTableBits=12)        // stub-cache.h:88-89
Secondary 表: 2^10 项  (kSecondaryTableBits=10)      // stub-cache.h:90-91

PrimaryOffset   = (map.ptr ^ (map.ptr>>12) + name.hash) & ((2^12-1)<<hashShift)
                                                  // stub-cache.cc:32-44
SecondaryOffset = (map.ptr + name.ptr); + (>>10 折叠)
                                                  // stub-cache.cc:50-56
```

- Get：先查主表、键+map 都全等才返回 handler；否则查次表（stub-cache.cc:121-134）。
- Set：**主表旧条目退休到次表，次表直接覆盖**——无探测链、无失效（旧的被挤走），
  注释见 stub-cache.h:102-107，实现 stub-cache.cc:89-119。
- 两表散列函数刻意不同，避免短名字（压缩后代码）同时碰撞（stub-cache.cc:46-48）。
- handler 内含原型链有效性检查，所以原型链修改无需主动失效缓存
  （stub-cache.h:15-18）。
- load/store/has 各有独立 cache 实例（ic.cc:1116-1128）。
- CSA 侧探测在 `TryProbeStubCacheTable`（accessor-assembler.cc:3319-3353，键比较
  :3335-3337、map 比较 :3340-3343）与 `TryProbeStubCache`（:3355-3388）。
- 优化代码的兜底 builtin `GenerateLoadIC_Megamorphic` 也走它
  （accessor-assembler.cc:4818-4863，探测 :4851）。

---

## 3. handler 编译专节：CSA 快路径与"数据化"的 handler

### 3.1 handler 不是生成的机器码，而是数据

现代 V8 的 IC handler 大多数是一个 **Smi 位域**（`LoadHandler`/`StoreHandler`，
src/ic/handler-configuration.h:28 与 :259），由共享的 CSA builtin"解释执行"。
`LoadHandler::Kind`（handler-configuration.h:35-53）枚举：
`kElement / kElementWithTransition / kIndexedString / kField / kAccessorFromPrototype /
kNativeDataProperty / kSlow / kProxy / kNonExistent / kModuleExport` 等。
真正的"编译"发生在构建期：AccessorAssembler 用 CSA 把整棵 handler 分派树生成为
builtin 机器码；运行期只是**换数据（槽内容），不生成代码**。

少数 handler 仍是 Code 对象（如 `LoadIC_StringLength`，ic.cc:1154-1159），
在 `HandleLoadICHandlerCase` 中以 `call_code_handler` 兜底调用
（accessor-assembler.cc:507, 542-548）。另有 `MegaDomHandler` 小对象（ic.cc:700-704）
与弱引用 AccessorPair（getter 直接调用，accessor-assembler.cc:522-540）。

### 3.2 字节码处理器内联版：LoadIC_BytecodeHandler

解释器专用的入口刻意"免栈帧"（注释：hand-tuned to omit frame construction，
accessor-assembler.cc:3396-3398）：单态 Smi handler（字段/常量加载）与前两项命中的
多态都不建帧。整体结构（accessor-assembler.cc:3392-3464）：

```cpp
TNode<HeapObjectReference> feedback = TryMonomorphicCase(
    p->slot(), CAST(p->vector()), weak_lookup_start_object_map,
    &if_handler, &var_handler, &try_polymorphic);          // :3420-3422
BIND(&if_handler);
HandleLoadICHandlerCase(p, var_handler.value(), ...);       // :3425
BIND(&try_polymorphic);
... GotoIfNot(IsWeakFixedArrayMap(...), &stub_call);
HandlePolymorphicCase(..., &if_handler, ...);               // :3431-3433
BIND(&stub_call);   // megamorphic/homomorphic/megadom → LoadIC_Noninlined :3442
BIND(&miss);        // ReturnCallRuntime(Runtime::kLoadIC_Miss) :3460-3462
```

### 3.3 TryMonomorphicCase：两次内存读定生死

反馈槽就放在 FeedbackVector 的尾数组里，handler 紧跟 map 之后：
先 `Load(feedback_vector, header + slot*8)` 得 weak map 指针做指针比较
（accessor-assembler.cc:80-93），命中再读 +kTaggedSize 处的 handler（:95-99）。
没有分支树、没有哈希——**单态命中成本 ≈ 1 次比较 + 2 次读**。

### 3.4 HandlePolymorphicCase：倒序线性扫描

`(map, handler)` 二元组、kEntrySize=2（accessor-assembler.cc:112），从后往前扫、
只在末尾判 0（手工优化，:118-121），命中即取 handler 走 `if_handler`（:134-138）。
数组本身由 `ConfigurePolymorphic` 写入（feedback-vector.cc:1181-1212，非弃用 map 排前
:1188-1204——倒序扫描即先查"新鲜"map）。

### 3.5 Smi handler 的执行：map 检查 → 偏移加载

`HandleLoadICHandlerCase` 先分派 handler 形态（Smi/弱引用 getter/Code/原型链 handler，
accessor-assembler.cc:502-520）。Smi 路径 `HandleLoadICSmiHandlerCase` 解码
`KindBits`（:652-654）后按 kind 跳转（`HandleLoadICSmiHandlerLoadNamedCase`
:825-872 的 if 链：kField/kConstantFromPrototype/kNonExistent/kNormal/... :840-866）。
kField 的核心就是"偏移加载"（accessor-assembler.cc:600-631）：

```cpp
TNode<IntPtrT> offset_in_words =
    Signed(DecodeWordFromWord32<LoadHandler::StorageOffsetInWordsBits>(handler_word));
TNode<IntPtrT> offset = IntPtrMul(offset_in_words, IntPtrConstant(kTaggedSize)); // :606-610
TNode<BoolT> is_inobject = IsSetWord32<LoadHandler::IsInobjectBits>(handler_word); // :612
property_storage = is_inobject ? holder : LoadFastProperties(holder, true);        // :614-616
TNode<Object> value = LoadObjectField(property_storage, offset);                   // :619
// double 字段需 rebox：GotoIf(IsSetWord32<IsDoubleBits>) → LoadHeapNumberValue :620-630
```

注意：receiver map 检查已由 `TryMonomorphicCase` 完成，Smi handler 路径不再查 map；
只有"handler 在原型上"的 `HandleLoadICProtoHandler` 才会补 holder 侧的 map 检查链。

### 3.6 Sparkplug Plus：真正的代码级自修改

开启 `sparkplug_plus` 后，baseline 代码把 IC 各态做成独立 builtin（如
`kLoadICUninitializedBaseline`），miss 时直接**改写 call 目标地址**完成"自修改"：
`CalculatePatchingTarget`/`MaybePatchCode`（ic.cc:844-916，static_assert handler 区间
:848-850），并有自愈逻辑 `TryHealMonomorphicIC`（ic.cc:970-994：反馈已是单态但
baseline 还停在未初始化 builtin，就把 call 补丁到位）。

---

## 4. 反馈向量专节：槽类型、二进制反馈与 Nexus

### 4.1 对象布局

`FeedbackVector`（feedback-vector.h:303-572）：头域含 `length_ / invocation_count_ /
invocation_count_before_stable_ / osr_state_ / flags_ / shared_function_info_ /
closure_feedback_cell_array_ / parent_feedback_cell_`（:555-565），尾部是变长槽数组
`FLEXIBLE_ARRAY_MEMBER(..., raw_feedback_slots)`（:571），每槽一个 MaybeObject，
多数槽占 2 个物理单元（feedback+extra，NexusConfig::GetFeedbackPair
feedback-vector.cc:503-511）。槽的个数与"每槽尺寸"由编译期 `FeedbackMetadata` 决定
（feedback-vector.cc:264-266）。

### 4.2 槽类型清单（FeedbackSlotKind）

`src/objects/feedback-vector.h:46-83`：

| kind | 行号 | 用途 |
|---|---|---|
| kStoreGlobalSloppy/Strict | :53,:65 | 全局写（cell） |
| kSetNamedSloppy/Strict | :54,:66 | 具名写 |
| kSetKeyedSloppy/Strict | :55,:69 | keyed 写 |
| **kCall** | :59 | 调用目标（target/receiver 频次） |
| **kLoadProperty** | :60 | 具名读（本章主角） |
| kLoadGlobalNotInsideTypeof / InsideTypeof | :61-62 | 全局读（属性 cell） |
| kLoadKeyed / kHasKeyed | :63-64 | keyed 读 / `in` |
| kDefineNamedOwn / kDefineKeyedOwn | :67-68 | 类字段定义 |
| kStoreInArrayLiteral | :70 | 数组字面量展开写 |
| **kBinaryOp** | :71 | 二元运算类型反馈 |
| **kCompareOp** | :72 | 比较运算类型反馈 |
| kLiteral | :74 | 数组/对象字面量预算 |
| kForIn | :75 | for-in 枚举缓存 |
| kInstanceOf | :76 | instanceof |
| kCloneObject | :78 | `{...obj}` |
| kStringAddAndInternalize | :79 | 字符串拼接 |
| kJumpLoop | :80 | 循环回边预算（OSR/tier-up） |

生成端 API 一一对应：`AddCallICSlot` :618、`AddLoadICSlot`(kLoadProperty) :620-621、
`AddBinaryOpSlot` :680、`AddCompareOpSlot` :684、`AddForInSlot` :687、`AddLiteralSlot`
:695 等。

### 4.3 初始化与清除

`FeedbackVector::New` 把每槽按 kind 填 `uninitialized_symbol` 哨兵
（feedback-vector.cc:276-300；`ConfigureUninitialized` 的逐 kind 版本
:543-581）。`FeedbackNexus::Clear` 默认**不清** kBinaryOp/kCompareOp/kForIn/kTypeOf
（feedback-vector.cc:587-598，注释 "We don't clear these, either"），只有
`ClearBehavior::kClearAll` 才清；调试器 restart 会调 `ClearSlots`（debug.cc:1960，
声明 feedback-vector.h:499-505）。

### 4.4 BinaryOp 反馈：位集合而非状态机

二元运算反馈是**位或（OR-累积）**的位集，`BinaryOperationFeedback`
（src/common/globals.h:2511-2526）：

```cpp
kNone=0x0, kSignedSmall=0x1, kSignedSmallInputs=0x3, kAdditiveSafeInteger=0x7,
kNumber=0xF, kNumberOrOddball=0x1F, kBigInt64=0x20, kBigInt=0x60,
kString=0x80, kStringWrapper=0x100, kStringOrStringWrapper=0x180, kAny=0x1FF
```

演进是"位逐渐点亮"：只见过 Smi → `kSignedSmall`；出现 double → OR 上
`kOtherNumber` 得 `kNumber`；出现 oddball → `kNumberOrOddball`；一旦含
`kAny=0x1FF` 位就无法再特化。CSA 侧写入口在 binary-op-assembler.cc
（如 Smi 快路径记 `kSignedSmall` :844、:873，双 Smi 输入但 double 结果记
`kSignedSmallInputs` :904），最后经 `UpdateFeedback` 写回槽（:421-428）。
读出端把位集翻译成枚举 `BinaryOperationHint`
（src/objects/type-hints.h:18-30：kNone/kSignedSmall/kSignedSmallInputs/
kAdditiveSafeInteger/kNumber/kNumberOrOddball/kString/kStringOrStringWrapper/
kBigInt/kBigInt64/kAny），翻译器 `BinaryOperationHintFromFeedback` 由
`FeedbackNexus::GetBinaryOperationFeedback` 调用（feedback-vector.cc:1470-1475）。
比较运算同理：`CompareOperationHint`（type-hints.h:39-54）与
`GetCompareOperationFeedback`（feedback-vector.cc:1477-1480）。

### 4.5 Nexus：槽的 C++ 读写门面

`FeedbackNexus` 封装 (vector, slot) 二元组：写单态 =
`SetFeedback(MakeWeak(map), handler)`（feedback-vector.cc:1163-1179，具名 keyed 槽
把 name 放 feedback、数组放 extra）；写多态 = 2*n WeakFixedArray
（:1181-1212）；写 megamorphic = 哨兵 + `Smi(kProperty|kElement)`
（:674-687）；`ic_state()` 判态（:698-770）；`GetFirstMap`（:689-696）、
`ExtractMapsAndHandlers` 供 IC 遍历。后台编译用 `NexusConfig` 的
BackgroundThread 模式加锁读写（:490-511）。

---

## 5. deopt 互动专节：反馈降级、软 deopt 与重新热身

### 5.1 反馈不足 → 优化代码里的"预埋 deopt"

优化编译时若某槽仍是 UNINITIALIZED（函数首次热编译就上优化是可能的），TurboFan
不放弃，而是埋一个**立即 deopt**：`JSTypeHintLowering::BuildDeoptIfFeedbackIsInsufficient`
为属性/kelled/二元/比较等节点生成 `Deoptimize(reason)` 节点
（src/compiler/js-type-hint-lowering.cc:757-772；二元/比较的 hint==kNone 判定
:774-800）。属性访问侧在 `ReducePropertyAccess`：`kInsufficient →
ReduceEagerDeoptimize(kInsufficientTypeFeedbackForGenericNamedAccess)`
（js-native-context-specialization.cc:2782-2786）；调用侧 `ReduceJSCall` 的
`NoChangeOrSoftDeopt`（js-call-reducer.cc:5164-5174）落到
`ReduceForInsufficientFeedback`（:6451-6472）。deopt 原因族
`InsufficientTypeFeedbackFor*` 见 src/deoptimizer/deoptimize-reason.h:34-56。
这类 deopt 俗称 **soft deopt**：代价是丢掉优化代码回到解释器继续收集反馈——
"现场退回、重新热身"，等预算再次攒够才会重编译。
`bailout_on_uninitialized` 目前对 TurboFan 无条件开启
（src/compiler/pipeline.cc:707-709，TODO 注明"should always be true"）。

### 5.2 deopt 发生后：预算重置 + "曾经 deopt 过"烙印

真正的 deopt 结算在 `Deoptimizer`（src/deoptimizer/deoptimizer.cc:1885-1916）：
把 `cached_tiering_decision` 降级（早优化 maglev 失败 → `kDelayMaglev`，:1887-1898）、
`SetInterruptBudget(kReset)`（:1906-1907）并给 FeedbackVector 打上
`set_was_once_deoptimized()`（:1908）。该烙印的实现是把
`invocation_count_before_stable` 写成哨兵 0xff
（feedback-vector-inl.h:259-262；常量 feedback-vector.h:361-363，注释
"In case a function deoptimizes we set invocation_count_before_stable to this
sentinel"）。被打烙印的函数在分层策略上会被区别对待（如 profile-guided
optimization 读取它，tiering-manager.cc:500-513）。

### 5.3 IC 变化反过来推动分层：NotifyICChanged

IC 每次改写反馈槽都会 `isolate->tiering_manager()->NotifyICChanged(vector)`
（ic.cc:334-351）。TieringManager 据此重算 interrupt budget：IC 还在变说明
"反馈未稳定"，用 `minimum_invocations_after_ic_update`（默认 500，
flag-definitions.h:1081）× 字节码长度重置预算，推迟优化、让反馈先长熟
（tiering-manager.cc:475-520；记录 `interrupt_budget_reset_by_ic_change`
标志 feedback-vector.h:314-315）。

### 5.4 反馈的"降级"三形态

1. **槽级降级**：RECOMPUTE_HANDLER（原型链变化，ic.cc:316-318, 266-292）→
   同 map 换 handler；弃用 map 过滤迁移（ic.cc:755-757；编译器侧
   MapUpdater::TryUpdateNoLock，js-heap-broker.cc:512-531）。
2. **态级降级**：反复同 map miss、字典 rehash、超 polymorph 上限 → MEGAMORPHIC
   （ic.cc:758-779, 788-793, 813-818）。
3. **全局清空**：仅调试器 `ClearSlots`（debug.cc:1960）与 `ClearBehavior::kClearAll`
   （feedback-vector.cc:583-647）；正常 deopt **不清空反馈**，只重置预算——
   反馈是跨"优化代码版本"存续的资产。

---

## 6. 设计动机

**为什么 IC 是"自修改代码"？** 经典 Self/Smalltalk IC 直接改写调用点的机器码。
V8 把"修改"从代码搬到了数据：字节码/baseline 调用的 builtin 不变，变的是反馈槽里
(weak map, handler)（feedback-vector.cc:1163-1176）。这既保留了"热路径零查找"的
本质，又让代码可共享（一份 CSA builtin 服务所有站点）、可并发读写、可被 GC 弱回收
（map 死 → 弱槽清空 → ic_state 自动降级）。sparkplug_plus（ic.cc:844-916）则
演示了字面意义的代码补丁仍可作为增量优化存在。

**为什么 megamorphic 用全局两表 StubCache（空间换时间）？** 超多态站点的
(ma­p,handler) 集合不可枚举，塞进槽里既无界又慢。全局 StubCache 用固定 4K+1K 项
（stub-cache.h:88-91）覆盖整个 isolate 的热点：O(1) 哈希探测、直接覆盖式更新、
无需失效（handler 自验原型链，stub-cache.h:15-18）。它故意**有损**——碰撞即 miss，
miss 才回 LookupIterator——用"最坏情况退化为慢路径"换"平均情况一次哈希"。

**为什么反馈是"分层编译的桥"？** Ignition 写、Sparkplug/Maglev/TurboFan 读，
且写入与消费解耦：优化器从不内联"当前 map 集合"本身，而是内联**反馈描述的概率
分布 + 依赖**（编译时经 JSHeapBroker::GetFeedbackForPropertyAccess 读取并去重缓存，
js-heap-broker.cc:913-921；消费端 js-native-context-specialization.cc:2751-2800、
maglev-graph-builder.cc:6436 等）。IC 还反向控制分层节奏（NotifyICChanged → 预算
重置，tiering-manager.cc:475），构成"收集→消费→再调节收集"的闭环。

---

## 7. FAQ 素材

1. **Q: 反馈槽里到底存了什么？** A: 一对 MaybeObject：`[feedback, extra]`。属性槽
   常见形态：weak Map + handler（单态）、WeakFixedArray（多态）、megamorphic
   哨兵 Symbol、uninitialized 哨兵 Symbol（feedback-vector.cc:698-760）。
2. **Q: handler 是机器码吗？** A: 通常是一个 Smi 位域（handler-configuration.h:28-259），
   由 CSA 预先编译好的共享 builtin 解释；个别是 Code 对象（ic.cc:1154-1159）或
   MegaDomHandler（ic.cc:700-704）。
3. **Q: 为什么单态命中这么快？** A: `TryMonomorphicCase` 只做一次弱指针比较加两次
   定长读（accessor-assembler.cc:85-99），无哈希无分支树。
4. **Q: POLYMORPHIC 最多几个 map？** A: `max_valid_polymorphic_map_count` 默认 10
   （flag-definitions.h:3286-3287；ic.cc:813-818）。
5. **Q: 同一个对象反复访问为什么不会变 megamorphic？** A: 同 map+同 handler 视为"无进展"，不升级（ic.cc:758-779）；仅 handler 失配（原型链变了）才覆盖 handler。
6. **Q: megamorphic 后反馈还有用吗？** A: 对 IC 只剩 StubCache 加速；对优化器，MEGAMORPHIC 槽仍会作为"无 map 信息"的反馈被读取（js-heap-broker.cc:579-590 的不变式），但不再产生 map 特化。
7. **Q: deopt 会清空 IC 吗？** A: 不会。deopt 只重置 interrupt budget 并打
   `was_once_deoptimized` 烙印（deoptimizer.cc:1906-1908），反馈跨版本存续；只有调试器等才 ClearSlots（debug.cc:1960）。
8. **Q: 二元运算为什么用位集而不是枚举状态？** A: 多输入类型可同时为真，OR 累积
   （globals.h:2511-2526）天然表达"见过 Smi 也见过 double"，且一次写回。
9. **Q: 全局变量访问走 IC 吗？** A: 走 LoadGlobalIC，但单态化为"属性 cell"模式：槽里存 cell 而非 map（ic.cc:1091-1103）。
10. **Q: 为什么 keyed IC 要求 name 一致才并入多态？** A: keyed 槽以 name 为 feedback 主字（feedback-vector.cc:1172-1177），强并会互相覆盖（ic.cc:734-736, 827）。

## 深挖方向

1. **HOMOMORPHIC 旁路**：同 handler 多 map 时用 `(map.ptr>>kTaggedSizeLog2) % len`
   哈希进 WeakHomomorphicFixedArray（accessor-assembler.cc:147-190，哈希 :168-176；
   写入 ic.cc:568-608；消费 js-native-context-specialization.cc:1946-2029），
   对照 MEGADOM（accessor-assembler.cc:309；ic.cc:640-706）看两种"多 map 单 handler"的取舍。
2. **Sparkplug Plus 的 IC 补丁协议**：`CalculatePatchingTarget` 的 static_assert
   把 handler builtin 与 baseline IC builtin 排成同构区间（ic.cc:844-860），
   自愈路径 `TryHealMonomorphicIC`（ic.cc:970-994）与 `Runtime_LoadIC_Miss_FromBaseline`（ic.cc:3272-3287）。
3. **并发与写屏障**：NexusConfig 主线程/后台线程两种模式（feedback-vector.cc:482-511）
   与 IC 弱槽的 GC 交互（FeedbackIterator 跳过 cleared handler，ic.cc:748-750）。
4. **优化代码的 megamorphic 兜底**：`GenerateLoadIC_Megamorphic` 为何要先 CSA_DCHECK
   槽处于 megamorphic/homomorphic/slow（accessor-assembler.cc:4818-4846）——优化代码把"非特化"统一降级到该 builtin。
5. **属性 cell 与全局 IC**：`ConfigurePropertyCellMode`（feedback-vector.cc:952 附近
   的 SetFeedback(MakeWeak(cell))；安装点 ic.cc:1091-1103）与 `ConfigureLexicalVarMode`
   （ic.cc:520-529）展示 IC 反馈的第二形态——非 map 型单态。

---

## 写作要点速查表

| 事实 | 出处 |
|---|---|
| 状态枚举 9 态定义 | src/common/globals.h:1896-1915 |
| SetCache 状态迁移总入口 | src/ic/ic.cc:1000-1059 |
| UNINITIALIZED→MONOMORPHIC 写槽 | src/ic/ic.cc:1007-1015, 918-922 |
| 同 map 同 handler 不升级判定 | src/ic/ic.cc:758-779 |
| 多态容量上限=10 | src/flags/flag-definitions.h:3286-3287; src/ic/ic.cc:813-818 |
| 槽内容→状态映射 | src/objects/feedback-vector.cc:698-770 |
| 单态快路径（弱比较+handler 读） | src/ic/accessor-assembler.cc:71-102 |
| 多态倒序扫描 kEntrySize=2 | src/ic/accessor-assembler.cc:104-145 |
| 字段偏移加载（Smi handler） | src/ic/accessor-assembler.cc:600-631 |
| 字节码 GetNamedProperty→LoadIC_BytecodeHandler | src/interpreter/interpreter-generator.cc:598-631; accessor-assembler.cc:3392-3464 |
| megamorphic 哨兵写槽 | src/objects/feedback-vector.cc:674-687 |
| StubCache 两表（2^12/2^10）与退休策略 | src/ic/stub-cache.h:86-91,102-107; src/ic/stub-cache.cc:89-134 |
| CSA 探测 StubCache | src/ic/accessor-assembler.cc:3319-3388 |
| miss 运行时入口 + LookupIterator | src/ic/ic.cc:3238-3270, 456-465, 1061-1114 |
| BinaryOp 反馈位集 | src/common/globals.h:2511-2526; src/objects/type-hints.h:18-30 |
| 反馈不足→预埋 deopt（soft） | src/compiler/js-type-hint-lowering.cc:757-772; js-call-reducer.cc:6451-6472 |
| deopt 后预算重置+烙印 | src/deoptimizer/deoptimizer.cc:1900-1908; feedback-vector-inl.h:259-262 |
| IC 变化重置 tier-up 预算 | src/execution/tiering-manager.cc:475-520; flag-definitions.h:1081 |
| 优化器读反馈入口 | src/compiler/js-heap-broker.cc:913-921, 494-584 |
| FeedbackVector 槽布局 | src/objects/feedback-vector.h:303-339, 555-571 |
