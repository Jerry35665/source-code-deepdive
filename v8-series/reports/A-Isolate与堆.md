# V8 深读（一）：Isolate 与堆结构

> 系列：《源码深读》第五系列之六《V8 深读》精简卷 · 第 1 章
> 源码版本：v8/v8 镜像，commit `c6a1f7c2`（shallow clone）。所有 文件:行号 均以该 commit 核对。

V8 的 src/ 有数十万行 C++，本章只回答四个问题：**执行上下文（Isolate）聚合了什么、堆（Heap）怎么分区、句柄（Handle）为什么存在、tagged pointer 的低位是什么**。顺带讲清 Zone——编译期的"一次性堆"，它与 GC 堆的分工正好可以和 llama.cpp 的 arena 思路对照。

---

## 1. 全景：V8 的分层

```
┌─────────────────────────────────────────────────────────────┐
│ API 层 (include/v8.h)                                        │
│   v8::Isolate  ← 一台"虚拟机实例"，内含一个 C++ 巨型对象        │
│   v8::Context  ← 一个全局作用域(每个 iframe/realm 一个)        │
│   v8::HandleScope / v8::Global ← 局部/全局句柄                │
├─────────────────────────────────────────────────────────────┤
│ 执行层 (src/execution, src/interpreter, src/maglev, ...)     │
│   Ignition(字节码) → Sparkplug/Maglev/TurboFan(分级编译)      │
│   ThreadLocalTop:当前 Context、栈帧指针、异常 handler          │
├─────────────────────────────────────────────────────────────┤
│ 堆层 (src/heap)                                              │
│   Heap: RO/NEW/OLD/CODE/SHARED/TRUSTED/LO… 十余个 Space      │
│   新生代 Scavenger 复制 + 老生代 Mark-Compact(并发标记)        │
├─────────────────────────────────────────────────────────────┤
│ 对象层 (src/objects)                                         │
│   tagged value: 低位打标 → Smi(立即数) 或 HeapObject(堆指针)   │
│   HeapObject = [ map 指针 | 字段… ]，Map 描述形状              │
├─────────────────────────────────────────────────────────────┤
│ 非托管内存: Zone arena(解析/编译期 AST/IR，不走 GC)            │
└─────────────────────────────────────────────────────────────┘
```

两点先立住：

- `Isolate` 不是抽象概念，就是一个 C++ 类，且禁止拷贝、禁止 new，只能 `Isolate::New()` 工厂创建（src/execution/isolate.h:564、isolate.h:635-636；isolate.cc:4729-4738 用 `base::AlignedAlloc` 对齐分配后 placement new）。
- `Heap` 不是独立单例，而是 Isolate 的**内嵌成员** `Heap heap_;`（src/execution/isolate.h:2655）——一个 Isolate 一座堆。

---

## 2. Isolate 专节：执行上下文的聚合体

### 2.1 它聚合了什么

Isolate 类体非常大，成员几乎就是一张"虚拟机零件清单"（行号均为 src/execution/isolate.h）：

| 成员 | 行号 | 职责 |
|---|---|---|
| `IsolateData isolate_data_` | isolate.h:2645 | 供 JIT 代码直接按固定偏移访问的热数据：roots 表、外参表、HandleScopeData、ThreadLocalTop |
| `Heap heap_` | isolate.h:2655 | 堆本体 |
| `ReadOnlyHeap* read_only_heap_` | isolate.h:2656 | 跨 Isolate 共享的只读空间 |
| `string_table_` | isolate.h:2659 | 字符串驻留表 |
| `const int id_` | isolate.h:2662 | Isolate 编号 |
| `entry_stack_` | isolate.h:2663 | Enter/Exit 的栈 |
| `Bootstrapper* bootstrapper_` | isolate.h:2667 | 建造内置对象（Math、Array…） |
| `CompilationCache* compilation_cache_` | isolate.h:2669 | 源码→字节码编译缓存 |
| `GlobalHandles* global_handles_` | isolate.h:2693 | 全局句柄注册表（见 §4.3） |
| `EternalHandles* eternal_handles_` | isolate.h:2695 | 永生句柄（永不销毁，索引访问） |
| `ThreadManager* thread_manager_` | isolate.h:2696 | 线程归档/恢复 |

再配上若干缓存与桩缓存：`DescriptorLookupCache*`（isolate.h:2689）、`load_stub_cache_` 等 StubCache（isolate.h:2675-2677 附近）。**Isolate = 堆 + 运行时状态 + 各种缓存 + 编译管线状态的聚合根**。d8 里 `new Realm()`、浏览器里每个 renderer 进程的主世界，底层各是一个 Isolate。

`isolate_data_` 值得单说：它是 Isolate 的第一个成员，`isolate_root()` 取它的基址减一个 bias（isolate.h:1295-1297），JIT 生成的机器码不拿 `Isolate*`，而是拿这个根地址按固定偏移访问 roots 表（isolate-data.h:435 `roots_table_`）与外参表（isolate-data.h:436）。指针压缩（见 §5）要求所有堆对象落在一个 4GB cage 内，isolate root 正是压缩指针的解压基点之一。

### 2.2 Isolate 与 Context 的关系

- Context 是 JS 语言层的"全局作用域"对象（`V8_OBJECT class Context : public HeapObject`，src/objects/contexts.h:497；NativeContext 在 contexts.h:791）——它本身是堆对象。
- Isolate 是 C++ 层的执行容器。当前执行到哪个 Context，记录在 `ThreadLocalTop::context_`（src/execution/thread-local-top.h:108），而 ThreadLocalTop 又内嵌在 `IsolateData` 里（isolate-data.h:389）。
- 一句话：**Isolate 有堆和状态，Context 只是堆上的一个对象；一个 Isolate 依次进入多个 Context，Context 切换就是改 `thread_local_top()->context_`**。

### 2.3 Isolate 与线程

V8 的模型是"**Isolate 任一时刻至多被一个线程持有，线程可以轮流进入/退出 Isolate**"，而非"一个 isolate 绑死一个线程"：

```cpp
// src/execution/isolate.h:581 起
class PerIsolateThreadData {          // 线程 × isolate 的绑定记录
  ...
  Isolate* isolate_;
  ThreadId thread_id_;
  uintptr_t stack_limit_;
  ThreadState* thread_state_;
};
```

- "当前 Isolate"存在线程局部存储里：`g_current_isolate_`（isolate.h:558），`TryGetCurrent` 用 TLS 读取（isolate.h:661）。
- `Isolate::Enter()`（isolate.cc:6679）：给当前线程找到/创建 `PerIsolateThreadData`，压入 `entry_stack_`，然后 `SetIsolateThreadLocals(this, data)`；同线程重入只做 `entry_count++`（isolate.cc:6696-6699）。`Isolate::Exit()`（isolate.cc:6728）弹栈并恢复**上一个** isolate 的 TLS（isolate.cc:6756-6757）——所以 Enter/Exit 可以嵌套、可以换 isolate。
- 归档机制：线程退出 isolate 时，其执行状态（ThreadLocalTop 等）可被归档，`ArchiveSpacePerThread()` 返回 `sizeof(ThreadLocalTop)`（isolate.h:941）。此外注释明确：多线程同时 Enter/Exit 同一 isolate 需外部加锁（isolate.h:695-697 附近注释）。
- Worker 线程（并发 GC、后台编译）不 Enter isolate，而是走 `LocalHeap`/`LocalIsolate` 的轻量通道——这也是为什么句柄系统有主线程版和后台线程版两套（见 §4.4）。

---

## 3. 堆空间专节：分代 + 按属性分 Space

### 3.1 Space 枚举：不止四代

空间种类定义在 `enum AllocationSpace`（src/common/globals.h:1473-1490），比教科书上的"三代"多得多：

```cpp
enum AllocationSpace {
  RO_SPACE,       // 只读、不可移动、跨 isolate 共享
  NEW_SPACE,      // 新生代，Scavenger/MinorMS 回收
  OLD_SPACE,      // 老生代常规对象
  CODE_SPACE,     // 老生代代码，可执行
  SHARED_SPACE,   // 多 isolate 共享(可选)
  TRUSTED_SPACE,  // 沙箱开启时位于沙箱外的"可信"对象
  ...
  NEW_LO_SPACE,   // 新生代大对象
  LO_SPACE,       // 老生代大对象
  CODE_LO_SPACE,  // 老生代大代码
  ...
};
```

Heap 内既有逐个指针成员（src/heap/heap.h:2150-2163：`new_space_`、`old_space_`、`code_space_`、`lo_space_`……），也有按枚举索引的总表 `std::unique_ptr<Space> space_[LAST_SPACE + 1];`（heap.h:2172）。`Heap::SetUpSpaces()`（heap.cc:5986）逐一 new 出它们：SemiSpaceNewSpace（heap.cc:6005）、CodeSpace（heap.cc:6018）、OldLargeObjectSpace（heap.cc:6021）等。

### 3.2 各 Space 职责

- **NEW_SPACE（新生代）**：默认是半空间（SemiSpace）实现，from/to 两个半区，GC 时把活对象从 from 复制到 to（`from_space_`/`to_space_` 见 src/heap/new-spaces.h:297 等）；也可配成 PagedNewSpace 走 MinorMS（heap.cc:6001-6005）。
- **OLD_SPACE（老生代）**：翻越两次新生代仍活的对象晋升至此；Mark-Compact 回收（heap.cc:2551）。
- **CODE_SPACE（代码空间）**：`class CodeSpace final : public PagedSpace`，构造时传入 `EXECUTABLE` 标志（src/heap/paged-spaces.h:505-513）。单独成空间的三个理由：
  1. 页面要映射为**可执行**（CPU 不允许对普通数据页跳转执行）；
  2. 回收策略不同——代码是天然"冷"对象，且 Code 对象不可移动性要求高（已有指向它的内联缓存/内置代码引用），压缩整理代价大；
  3. 出于安全与缓存局部性，所有可执行内存集中在一个 **CodeRange** 虚拟内存 cage 里（"A code range is a virtual memory cage that may contain executable code"，src/heap/code-range.h:82）。
- **LO_SPACE（大对象空间）**：超过 `kMaxRegularHeapObjectSize` 的对象单独走 LO 空间（判定在 src/heap/heap-allocator-inl.h:112-114，派发在 heap-allocator.cc:91-135：kYoung→`new_lo_space()`、kOld→`lo_space()`、kCode→`code_lo_space()`）。阈值本身 = 半页大小：`kMaxRegularHeapObjectSize = (1 << (kPageSizeBits - 1))`（src/common/globals.h:743），普通平台 `kPageSizeBits = 18` 即 256KB 页 → 阈值 128KB（src/base/build_config.h:80）。大对象每对象独占一页、页对齐，因此**不做复制/整理，只做标记清除**——这就是单独成空间的动机。
- **RO_SPACE**：字符串表原型、内置桩代码等"永生"对象，跨 Isolate 共享一份（isolate.h:2656、heap.cc:4808 `SetUpFromReadOnlyHeap`）。
- **SHARED_SPACE**：多 Isolate 共享堆（如同一进程多个 context 的字符串），对应的 Isolate 标记 `is_shared_space_isolate_`（isolate.h:2648）。
- **TRUSTED_SPACE**：沙箱（V8 sandbox）模型下，"可信"元对象（字节码、代码元数据等）放在攻击者即使破坏沙箱内堆也无法触碰的区域（globals.h:1480-1482 注释）。

### 3.3 分配路径：AllocateRaw 的分派

统一入口是 `HeapAllocator::AllocateRaw(size_in_bytes, origin, alignment, hint)`（src/heap/heap-allocator-inl.h:90）。流程四步：

1. 若开了 `--single-generation`，kYoung 直接降级为 kOld（heap-allocator-inl.h:104-106）。
2. 判大对象：`size > MaxRegularHeapObjectSize(type)` 则走 `AllocateRawLargeInternal`（heap-allocator-inl.h:112-114、122-125）。
3. 否则按 `AllocationType` switch 到各空间的 **LinearAllocationArea**（bump-pointer）分配器（heap-allocator-inl.h:141-175）：

```cpp
// src/heap/heap-allocator-inl.h:141-157(节选)
case AllocationType::kYoung:
  allocation = new_space_allocator_->AllocateRaw(...); break;
case AllocationType::kOld:
  allocation = old_space_allocator_->AllocateRaw(...); break;
case AllocationType::kCode:
  allocation = code_space_allocator_->AllocateRaw(...); break;
```

4. 写屏障校验、分配追踪（heap-allocator-inl.h:190-201）。

关键点：**常规分配是 O(1) 的指针递增**，只有 LAA 耗尽才触发（可能内联的）GC 或向 OS 要新页——这是分代设计送给赋值函数的礼物。GC 调度上，`Heap::PerformGarbageCollection` 按收集器分派 `MarkCompact() / MinorMarkSweep() / Scavenge()`（heap.cc:2288-2293；三个函数分别在 heap.cc:2551、2584、2617）。

---

## 4. Handle 专节：GC 时代的安全指针

### 4.1 为什么需要句柄

GC 会**移动对象**（新生代复制、老生代整理压缩）。C++ 侧如果直接拿 `Object*` 裸指针，一次 Scavenge 之后全部失效。V8 的解法：C++ 里握着的不是对象地址，而是指向"槽"的指针——

```
Handle<T>  ──►  Address* (槽, 在 handle 块里)  ──►  堆对象
                    ▲ GC 移动对象时只改槽里的值
```

句柄即"堆对象的安全间接层"：GC 更新槽内容，Handle 使用者无感。另外句柄槽本身是 GC 根——遍历根时 V8 扫描所有活跃的 handle 块，所以**活跃 Handle 同时起到"别回收我"的标记作用**。

### 4.2 HandleScope：栈式批量释放

每个 handle 都要还。逐个 free 太贵，V8 用 `HandleScope` 做**栈式区间管理**：全局只有一根 `next/limit` 指针（`HandleScopeData`，定义在 include/v8-internal.h:957-968：`Address* next; Address* limit; int level; int sealed_level;`），它就放在 IsolateData 热区（isolate-data.h:390，其字段偏移还通过 isolate-data-fields.h:170-176 暴露给 JIT）。

创建 scope 只是把 `next/limit` 存档（isolate.h 上层语法糖，实现在 src/handles/handles-inl.h:176-186）：

```cpp
// src/handles/handles-inl.h:176-186
HandleScope::HandleScope(Isolate* isolate) {
  HandleScopeData* data = isolate->handle_scope_data();
  isolate_ = isolate;
  prev_next_ = data->next;
  prev_limit_ = data->limit;
  data->level++;
}
```

析构则把 `next` 拨回去（handles-inl.h:198-252 的 `CloseScope`：swap next、`level--`、若越界过则 `DeleteExtensions` 回收多余的块）。**O(1) 销毁整个 scope 里的所有句柄**，这就是"Escape?"的答案：V8 没有 Rust 式 escape 分析，而是手工 `CloseAndEscape`——销毁当前 scope 前把那**一个**值在父 scope 重建一份（handles-inl.h:257-272，声明与注释见 src/handles/handles.h:297-303）。

块的容量是 `kHandleBlockSize = KB - 2`（"fit in one page"，src/handles/handle-scope-implementer.h:128）。`next==limit` 时 `CreateHandle` 慢路径调 `Extend()`：先吃掉最后一块的剩余空间，不够就向 HandleScopeImplementer 要新块挂上（src/handles/handles.cc:176-212）。没开任何 scope 就想建句柄，直接报 "Cannot create a handle without a HandleScope"（handles.cc:183-185）。

### 4.3 Global Handles：栈外的注册表

HandleScope 里的句柄随栈帧生灭；API 用户（浏览器 DOM 绑定、Node 的 addon）需要**与栈无关**的引用，这就是 GlobalHandles——"independent of stack-state and can have callbacks and finalizers attached"（src/handles/global-handles.h:25-26）。JS 侧 `v8::Global<T>` / `v8::Persistent<T>` 最终调到：

```cpp
// src/api/api.cc:690-693
i::Address* GlobalizeReference(i::Isolate* i_isolate, i::Address value) {
  ...
  i::IndirectHandle<i::Object> result =
      i_isolate->global_handles()->Create(value);
```

内部是节点分配：`GlobalHandles::Create` 从 `regular_nodes_` 拿一个 Node，年轻对象还会挂进 `young_nodes_` 追踪（src/handles/global-handles.cc:624-631）。弱语义：`MakeWeak` 支持普通弱回调与 **phantom** 弱（回调前把槽清成 Smi，见 global-handles.h:46-60 的注释）；全部销毁用 `Destroy`（global-handles.h:46）。另有 `EternalHandles`（global-handles.h:192）——创建后永不清除、按索引取用的句柄，用于内置对象这类"和 Isolate 同寿"的引用。

### 4.4 后台线程的两套变体

主线程 HandleScope 依赖 `Isolate::TryGetCurrent()`（handles-inl.h:278 的 DCHECK）。后台（GC/编译）线程用独立的 `LocalHandles`（src/handles/local-handles.h:19）与可跨阶段交接的 `PersistentHandles`（src/handles/persistent-handles.h:25）。另有一支正在路上的 `DirectHandle`（直接持有对象指针、依赖保守栈扫描兜根，"Direct handles should not be used without conservative stack scanning"，src/handles/handles.h:383-384）——若落地，间接层成本会消失，这是值得跟踪的演进。

---

## 5. Tag 专节：Smi 与 HeapObject 的低位

### 5.1 打标方案

所有 JS 值在机器里都是一个 word（tagged value）。低位区分类型（常量定义在 include/v8-internal.h:58-77）：

```cpp
// include/v8-internal.h:58-77(节选)
const int kHeapObjectTag = 1;
const int kWeakHeapObjectTag = 3;
const int kHeapObjectTagSize = 2;
const intptr_t kHeapObjectTagMask = (1 << kHeapObjectTagSize) - 1;
const int kSmiTag = 0;
const int kSmiTagSize = 1;
```

- 最低位 **0** → Smi（小整数，值在高位，低位补 0）；
- 最低位 **1** → HeapObject，`ptr() = address() + kHeapObjectTag`（src/objects/heap-object.h:140），`Tagged<T>` 里存的是"地址+1"，使用时剥掉；
- 低两位 `11` → **弱**引用（kWeakHeapObjectTag=3），弱数组/ephemeron 里用；
- Smi 用第 0 位=0 判别，HeapObject 用第 0 位=1 判别，弱强用第 1 位区分——硬件上一条 `test` 即可分派。

对象本体的布局：`HeapObject` 第 0 字节永远是 map 指针（`using MapField = TaggedField<MapWord, 0>`，src/objects/heap-object.h:353），随后才是字段；Map 自身的注释版布局（instance_size/instance_type/bit_field3/prototype…）见 src/objects/map.h:176-235，Map 类在 map.h:255。`class Object : public AllStatic`（src/objects/objects.h:143）只是静态工具类，真正的值类型是 `Tagged<T>`。

### 5.2 32 位与 64 位为何不同

Smi 值宽度由 tagged 指针宽度决定（include/v8-internal.h:84-85 与 135-136）：

- `SmiTagging<4>`（32 位 tagged，含开启指针压缩的 64 位构建）：`kSmiShiftSize = 0, kSmiValueSize = 31`——Smi 值放在低 32 位的 bit1..31。
- `SmiTagging<8>`（未压缩的 64 位）：`kSmiShiftSize = 31, kSmiValueSize = 32`——值放在高 32 位，低位全 0。

为什么这样安排？globals.h 的 static_assert 给了线索：Smi 符号位必须落在 32 位边界上，64 位平台才能用**符号扩展指令**解码而无需额外移位（"Smi sign bit position must be 32-bit aligned so we can use sign extension instructions"，src/common/globals.h:1050-1052）。指针压缩时 tagged 只有 4 字节（`kTaggedSize = kInt32Size`，src/common/globals.h:573；未压缩为 `kSystemPointerSize`，globals.h:583），只能挤进 31 位值域。压缩位宽的差异最终收敛进断言 `(kSmiValueSize + kSmiShiftSize + kSmiTagSize) % 32 == 0`（globals.h:1052-1056）。

---

## 6. Zone 专节：编译期的 arena

堆 + GC 管 JS 对象；但解析器生成的 AST、TurboFan 的 IR 节点，**生命周期 = 一次编译**，走 GC 纯属浪费。V8 给它们配了 Zone arena：

```cpp
// src/zone/zone.h:53-70(节选)
template <typename TypeTag>
void* Allocate(size_t size) {
  size = RoundUp(size, kAlignmentInBytes);
  ...
  if (V8_UNLIKELY(size > limit_ - position_)) {
    return ExpandAndAllocate(size);      // 当前段满了再开新段
  }
  return AllocateUnchecked(size);        // 指针递增, 无逐对象释放
}
```

- 分配就是 bump pointer（zone.h:258-266 的 `position_/limit_/segment_head_`）；段大小 8KB 起步、32KB 封顶（zone.h:233-236）。
- **没有逐对象 free**（`Delete` 仅归还可复用字节，zone.h:81 起），整个 Zone 析构时 `DeleteAll()` 一把释放所有段（src/zone/zone.cc:37-39、110；段来自 `AccountingAllocator::AllocateSegment`，src/zone/accounting-allocator.cc:113）。
- 使用者：解析器全面依赖 Zone（如 `struct Parameter : public ZoneObject`，src/parsing/parser.h:47；AST 字符串专用 `ast_raw_string_zone()` 与一次性 `single_parse_zone()`，src/ast/ast-value-factory.h:367-373），编译器管线同理。
- 与 llama.cpp 的对照：两者都是"arena 归还整块内存、对象零开销分配"，区别在生命周期语义——llama.cpp 的 arena 挂在计算图/上下文上，V8 的 Zone 挂在一次 parse/compile 上；Zone 甚至常被放在栈上（`Zone zone(allocator, "name")`），作用域结束段内存整体消失，天然不可被 GC 看见。

---

## 7. 设计动机

- **分代的动机（弱分代假说）**：绝大多数 JS 对象朝生夕死（临时数组、中间字符串、闭包捕获）。把分配压在新生代、用 Scavenger 只搬活对象，GC 成本 ∝ 存活量而非堆大小；老生代低频做 Mark-Compact。V8 还用 `kPhysicalMemoryToOldGenerationRatio = 4`（src/heap/heap.h:318）按物理内存动态定老生代上限，并用 pretenuring 反馈把"活得久"的对象直接分配到老生代（heap.cc:2296-2300 的 ProcessPretenuringFeedback）。
- **Handle 的成本与必要性**：间接层不是免费的（一次访存 + 根扫描），但没有它，移动式 GC 无法与 C++ 侧共存。V8 把成本压到极限：常见路径一次读、一次写、一次指针递增（handles-inl.h:276-301）；scope 批量销毁 O(1)；热数据（HandleScopeData）放 IsolateData 供 JIT 免调用访问。方向上，保守栈扫描成熟后 DirectHandle 会逐步去掉解引用（handles.h:383-384），可见这套设计仍在权衡演进。
- **Zone 的生命周期绑定**：AST/IR 的生命周期与"一次编译"严格同构，引用计数/GC 都是不必要的复杂度；arena 把释放成本摊到整段。代价是需要纪律——Zone 对象绝不能逃逸进堆（不能被 JS 对象引用），否则悬垂。
- **空间细分（CODE/LO/TRUSTED/SHARED）的动机**：按"属性"而非仅按"年龄"切分——可执行性（CODE_SPACE + CodeRange）、页管理成本（LO 空间整页单对象）、安全边界（TRUSTED_SPACE 在沙箱外）、共享拓扑（SHARED_SPACE）。每个维度单独成空间，GC 才能对每类对象用最合适的算法。

---

## 8. FAQ 素材

1. **一个进程能有几个 Isolate？** 任意多个；每个 Isolate 有独立的 `Heap heap_`（isolate.h:2655）与 id（isolate.h:2662），浏览器每个 renderer 进程通常一个主 Isolate + Worker 各一个。
2. **Isolate 和线程是一对一吗？** 不是。线程通过 `Enter/Exit`（isolate.cc:6679/6728）轮流持有 Isolate，绑定记录在 `PerIsolateThreadData`（isolate.h:581），"当前 isolate"在 TLS 里（isolate.h:558、661）。
3. **Context 和 Isolate 谁包含谁？** Isolate 包含堆，Context 是堆上的对象（contexts.h:497）；当前 Context 记在 `ThreadLocalTop::context_`（thread-local-top.h:108）。同一 Isolate 可依次进入多个 Context。
4. **JS 里 `1+1` 的整数在堆上吗？** 不在。Smi 直接编码在 tagged word 里（kSmiTag=0，v8-internal.h:74），不分配；只有超出 Smi 位宽才装箱 HeapNumber。
5. **普通对象分配要多快？** bump pointer，`HeapAllocator::AllocateRaw` 主路径是一次 switch + 线性区递增（heap-allocator-inl.h:141-157），无锁竞争只在主线程语义下不存在（后台走 LocalHeap 的独立线性区）。
6. **多大的对象算大对象？** > `kMaxRegularHeapObjectSize` = 半个 V8 页。普通平台页 256KB（build_config.h:80），阈值 128KB（globals.h:743），进 LO 空间独占页、只做标记清除。
7. **代码为什么不能和普通对象放一起？** 页要可执行、集中进 CodeRange cage（code-range.h:82）、不宜搬移，故 CODE_SPACE/CODE_LO_SPACE 分离（paged-spaces.h:505-513）。
8. **HandleScope 忘写了会怎样？** `Extend` 里 ApiCheck 直接失败："Cannot create a handle without a HandleScope"（handles.cc:183-185）。
9. **v8::Global 和局部 Handle 差在哪？** Global 挂在 `GlobalHandles` 注册表（api.cc:690-693），跨栈帧存活、可 MakeWeak/带终结回调（global-handles.h:46-60）；局部 Handle 随 scope 整批消失。
10. **指针压缩后 Smi 只有 31 位？** 是。压缩构建 tagged 为 4 字节，`kSmiValueSize=31`（v8-internal.h:85）；未压缩 64 位构建 Smi 值 32 位、存高半字（v8-internal.h:136），用符号扩展解码（globals.h:1050-1052）。
11. **为什么还有 2 位 tag（kHeapObjectTagSize=2）？** 第 0 位分 Smi/HeapObject，第 1 位分强/弱引用（v8-internal.h:58-61），弱集合扫描时不必额外读对象头。
12. **Zone 内存会被 GC 收走吗？** 不会，Zone 与堆完全正交：段由 `AccountingAllocator` 直接从系统拿（accounting-allocator.cc:113），Zone 析构整段归还（zone.cc:110）；纪律是 Zone 对象不得进入 JS 可达图。

---

## 9. 深挖方向

1. **Scavenger 细节**：from/to 半区复制如何与写 barrier 记住的 old→new 引用配合；晋升阈值与 pretenuring 决策（heap.cc:2617 起；heap.cc:2296 起）。
2. **并发标记与三色不变式**：incremental marking 的写屏障实现（src/heap/CONCURRENT_MARKING.md 与 WRITE_BARRIER.md）、MinorMS 取代半空间的路径（heap.cc:6001 的 PagedNewSpace）。
3. **沙箱与 TRUSTED_SPACE**：外部指针表、代码指针表如何让 TRUSTED_SPACE 站到沙箱外（globals.h:1480-1482；src/sandbox/）。
4. **DirectHandle 落地路线**：conservative stack scanning 开启后间接句柄的消亡计划（handles.h:383-384、handles.h:297-303 的 TODO(42203211)）。
5. **多 Isolate 共享堆**：SHARED_SPACE 的共享串与 `is_shared_space_isolate_` 主 isolate 协议（isolate.h:2648；heap.cc:2429 附近的共享堆 GC 协调）。

---

## 写作要点速查表

| # | 事实 | 位置 |
|---|---|---|
| 1 | `class Isolate final`，禁 new，工厂 `Isolate::New()` | src/execution/isolate.h:564,635 |
| 2 | Isolate 用 `AlignedAlloc` 分配（页对齐） | src/execution/isolate.cc:4736-4738 |
| 3 | `Heap heap_` 内嵌于 Isolate | src/execution/isolate.h:2655 |
| 4 | `IsolateData isolate_data_`（JIT 热数据首成员） | src/execution/isolate.h:2645 |
| 5 | roots 表 / 外参表在 IsolateData | src/execution/isolate-data.h:435-436 |
| 6 | `isolate_root()` 与 FromRootAddress | src/execution/isolate.h:1295-1301 |
| 7 | PerIsolateThreadData（线程×isolate 绑定） | src/execution/isolate.h:581 |
| 8 | 当前 isolate 走 TLS（g_current_isolate_） | src/execution/isolate.h:558,661 |
| 9 | Isolate::Enter / Exit（嵌套 entry_stack_） | src/execution/isolate.cc:6679,6728 |
| 10 | ThreadLocalTop::context_（当前 Context） | src/execution/thread-local-top.h:108 |
| 11 | AllocationSpace 枚举（RO/NEW/OLD/CODE/SHARED/TRUSTED/LO…） | src/common/globals.h:1473-1490 |
| 12 | Heap 各 space 成员 + `space_[]` 总表 | src/heap/heap.h:2150-2163,2172 |
| 13 | SetUpSpaces 建空间（SemiSpace/PagedNewSpace 分支） | src/heap/heap.cc:5986,6001-6005 |
| 14 | AllocateRaw 按类型分派 + 大对象判定 | src/heap/heap-allocator-inl.h:90,112-114,141-175 |
| 15 | 大对象派发 new_lo/lo/code_lo_space | src/heap/heap-allocator.cc:91-135 |
| 16 | kMaxRegularHeapObjectSize = 半页；页 256KB | src/common/globals.h:743; src/base/build_config.h:80 |
| 17 | CodeSpace : PagedSpace(EXECUTABLE)；CodeRange cage | src/heap/paged-spaces.h:505-513; src/heap/code-range.h:82 |
| 18 | GC 分派 MarkCompact/MinorMarkSweep/Scavenge | src/heap/heap.cc:2288-2293,2551,2584,2617 |
| 19 | class HandleScope；CloseAndEscape 语义 | src/handles/handles.h:263,297-303 |
| 20 | HandleScope ctor 存档 next/limit；dtor→CloseScope | src/handles/handles-inl.h:176-186,198-252 |
| 21 | CreateHandle 快路径 + Extend 慢路径 | src/handles/handles-inl.h:276-301; src/handles/handles.cc:176-212 |
| 22 | kHandleBlockSize = KB-2（一页装下） | src/handles/handle-scope-implementer.h:128 |
| 23 | HandleScopeData{next,limit,level,sealed_level} | include/v8-internal.h:957-968; isolate-data.h:390 |
| 24 | GlobalHandles（栈外注册表）+ MakeWeak/phantom 注释 | src/handles/global-handles.h:25-26,46-60; .cc:624-631 |
| 25 | API 侧 GlobalizeReference（v8::Global 底座） | src/api/api.cc:690-693 |
| 26 | EternalHandles（永生句柄） | src/handles/global-handles.h:192 |
| 27 | LocalHandles / PersistentHandles（后台线程） | src/handles/local-handles.h:19; persistent-handles.h:25 |
| 28 | tag 常量：kHeapObjectTag=1, kWeak=3, kSmiTag=0 | include/v8-internal.h:58-77 |
| 29 | SmiTagging<4>=31 位 / <8>=32 位（高位）值域 | include/v8-internal.h:84-85,135-136 |
| 30 | kTaggedSize：压缩 4B / 未压缩 8B；符号扩展断言 | src/common/globals.h:573,583,1050-1056 |
| 31 | HeapObject map 在偏移 0；ptr=addr+1 | src/objects/heap-object.h:353,140 |
| 32 | Map 布局注释图（instance_size/bit_field3…） | src/objects/map.h:176-235,255 |
| 33 | Zone：bump 分配、8K/32K 段、DeleteAll 整段释放 | src/zone/zone.h:53-70,233-236; src/zone/zone.cc:37-39,110 |
| 34 | 解析器 Zone 使用（AST 字符串区/单 parse 区） | src/ast/ast-value-factory.h:367-373; src/parsing/parser.h:47 |
| 35 | V8::InitializePlatform / V8::Initialize | src/init/v8.cc:109,175 |

（行号以 commit `c6a1f7c2` 为准。）
