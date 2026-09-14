# D - V8 对象模型与隐藏类(Map / Properties / ElementsKind / IC)

> 调研对象:V8 源码(shallow clone),commit `c6a1f7c2`(ppc64: Replace r0 with TemporaryRegisterScope in TypedArrayElementOperand)。
> 所有行号均为该 commit 下仓库相对路径的实测行号(grep -n / Read 核对)。
> 前置:A 篇已讲 Tag(Smi/HeapObject)与堆布局;B 篇已讲 FeedbackVector 的分配。本文聚焦对象模型本体。

---

## 1. 全景:一次 `obj.x` 属性读的完整旅程

V8 里"读属性"有两条路径:解释器/编译代码先撞**内联缓存(IC)**,IC miss 才落到**运行时的统一状态机 LookupIterator**。Map(隐藏类)是两条路径共同依赖的元数据。

```text
  obj.x   (字节码 GetNamedProperty, feedback slot 已随 FeedbackVector 分配, 见 B 篇)
    │
    ├─① tag 判定: obj 是 Smi? Smi 无属性 → 直接走慢路径报错/原型链 (map 不存在)
    │
    ├─② 取 obj 的 Map(对象头第一个指针槽, 恒指向 meta map)
    │     map->instance_type() 判定是不是 JSObject/JSProxy/String wrapper…
    │
    ├─③ IC 快路径(热点时 99% 走这里, 无运行时调用):
    │     feedback[slot] == megamorphic 符号?
    │        └─ 是 → 查 StubCache(hash(name,map) → handler)   src/ic/stub-cache.h:88
    │     否则 → 槽内 (map,handler) 对比: map 相同?
    │        └─ 是 → handler 是 Smi 编码: kField + 偏移 + 是否 inobject + 是否 double
    │                  直接 *(obj + offset) 读出, 连函数都不用进 (内联在代码里)
    │        └─ 否 → 记录新 map (mono→poly→(homo)→megamorphic, 见 §5)
    │
    ├─④ IC miss → Runtime/LookupIterator 慢路径状态机 (src/objects/lookup.cc:34 Start):
    │     NOT_FOUND ─→ ACCESS_CHECK ─→ INTERCEPTOR ─→ JSPROXY ─→ ACCESSOR ─→ DATA
    │     每个 holder(对象)按 map 分类推进:
    │       快对象: descriptors->SearchWithCache(name)        lookup.cc:1456
    │       慢对象: SwissNameDictionary/NameDictionary FindEntry lookup.cc:1461
    │       元素:   ElementsAccessor::GetEntryForIndex          lookup.cc:1443
    │     沿原型链 NextInternal 逐 holder 推进                  lookup.cc:99
    │
    └─⑤ 读值:
          DATA + kField   → 按 FieldIndex 从对象体内(in-object)或 PropertyArray 读
          DATA + 常量     → 从 DescriptorArray 的 value 槽读
          ACCESSOR        → 调 AccessorPair getter / AccessorInfo 回调
          NOT_FOUND       → undefined(或 strict 下 ReferenceError)
```

要点:Map 本身不存值,它存"结构"。值的物理位置由三处协同描述:Map 的 DescriptorArray(每个属性的位置/类型)、对象的 `properties_or_hash`(PropertyArray,超出的属性)、对象的 `elements`(按 ElementsKind 组织)。

---

## 2. Map 专节:隐藏类的物理形态

### 2.1 Map 的内存布局(逐字段)

`src/objects/map.h:176-253` 有一段权威的布局注释(摘录):

```cpp
// | TaggedPointer | map - Always a pointer to the MetaMap root      |
// | Int           | The first int field                             |
//   | Byte     | [instance_size]                                   |
//   | Byte     | inobject properties start offset / ctor fn index  |
//   | Byte     | [used_or_unused_instance_size_in_words]           |
//   | Byte     | [visitor_id]                                      |
// | Int           | [instance_type] | [bit_field] | [bit_field2]    |
// | Int           | [bit_field3]                                    |
// | TaggedPointer | [prototype]                                     |
// | TaggedPointer | [constructor_or_back_pointer_or_native_context] |
// | TaggedPointer | [instance_descriptors] (if JS object)           |
// | TaggedPointer | [prototype_validity_cell]                       |
// | TaggedPointer | [prototype_info] 或 [raw_transitions]           |
```
(map.h:180-253;类声明在 map.h:255)

- `instance_size`:实例字节数,单字节 → 上限 `kMaxInstanceSize = 255 * kTaggedSize`(src/objects/js-objects.h:971)。变长对象用 `kVariableSizeSentinel`(map.h:259-262)。
- `inobject_properties_start_or_constructor_function_index`:JSObject 时是"属性区从第几个字开始"(map.h:267-275),于是 `GetInObjectProperties() = instance_size_in_words - start`(src/objects/map-inl.h:455-458)。
- `used_or_unused_instance_size_in_words`:双关字段——值 ≥ `kFieldsAdded(3)` 时表示"已用到的尺寸",否则表示 PropertyArray 的剩余 slack(src/objects/map-inl.h:507-522)。

### 2.2 三个位域逐项

**bit_field(8 bit)** — map.h:341-349:`IsCallable / HasNamedInterceptor / HasIndexedInterceptor / IsUndetectable / IsAccessCheckNeeded / IsConstructor / IsExtendedMap`。布局注释见 map.h:203-211。

**bit_field2(8 bit)** — map.h:357-361:

```cpp
struct Bits2 {
  using NewTargetIsBaseBit = base::BitField<bool, 0, 1, uint8_t>;
  using IsImmutablePrototypeBit = NewTargetIsBaseBit::Next<bool, 1>;
  using ElementsKindBits = IsImmutablePrototypeBit::Next<ElementsKind, 6>;
};
```
**ElementsKind 直接编码在 Map 里(6 bit)**——这是"元素种类是隐藏类的一部分"的字面证据。

**bit_field3(32 bit)** — map.h:379-393(注释 map.h:217-229):

| 位域 | 位 | 含义 |
|---|---|---|
| EnumLengthBits | 0..9 | for-in 枚举长度缓存 |
| NumberOfOwnDescriptorsBits | 10..19 | **自有属性数**(DescriptorArray 可被多个 Map 共享,靠它截断) |
| IsPrototypeMap | 20 | 该 Map 是某原型的 Map |
| IsDictionaryMap | 21 | **慢属性(字典)模式开关** |
| OwnsDescriptors | 22 | 是否拥有(可写)DescriptorArray |
| IsDeprecated | 24 | 已被字段泛化淘汰,实例需迁移 |
| IsMigrationTarget | 26 | 是迁移的目标 Map(加速 Deprecated→新 Map) |
| IsExtensible | 27 | preventExtensions/seal/freeze 相关 |
| ConstructionCounter | 29..31 | **in-object slack tracking 计数器** |

Descriptor 索引位宽 10 bit → `kMaxNumberOfDescriptors = (1<<10) - 4 = 1020`(src/objects/property-details.h:242-249)。

### 2.3 Slack tracking(构造期预留)

构造函数首次调用后,初始 Map 的 ConstructionCounter 从 7 开始递减(map.h:403-407,算法注释 map.h:409-425):新对象先给 in-object 属性区留富余(未用槽填 one_pointer_filler),计数到 0 时把初始 Map 收缩到实际用量,存量对象经 `MigrateToMap` 换小 Map。

### 2.4 DescriptorArray:结构描述表

```cpp
// A DescriptorArray is a custom array that holds instance descriptors.
//   Header: number_of_all_descriptors(含 slack) | number_of_descriptors | enum cache
//   Elements: [key][details][value] * 3 slots per entry
//   Slack: 预留给后续 Append
```
(src/objects/descriptor-array.h:54-77;类声明 :78;每项 3 槽 kEntrySize=3,:223-227)

- `details` 是 `PropertyDetails` 位打包(src/objects/property-details.h:475-496):kind(1b: kData/kAccessor)、constness(1b: kConst/kMutable)、attributes(3b)、location(1b: **kField=在对象里 / kDescriptor=常量在表里**)、representation(3b: Smi/Double/HeapObject/Tagged)、descriptor pointer(10b)。
- `value` 槽双关:kDescriptor 时存常量值;kField 时存 **FieldType**(None/Any/弱引用到某个 Map——用于字段类型反馈)(descriptor-array.h:68-72)。
- 查找:`SearchWithCache` 带 isolate 级缓存(src/objects/descriptor-array-inl.h:194),小于 32 项线性查,否则二分。
- **相邻 Map 共享 DescriptorArray**:`bit_field3.NumberOfOwnDescriptors` 限定各 Map 只看前 N 项;`ShareDescriptor` 路径(new Map 直接 Append 一项到同一个数组)见 map.cc:1580-1628;不再共享时 `OwnsDescriptors=false` 转移所有权(`ConnectTransition`,map.cc:1621-1645)。

### 2.5 Transition 树:添加属性 = 沿树走

**方向**:父 Map(属性少)→ 子 Map(多一个属性),边以 (属性名, kind, attributes) 索引。注意方向是"少→多",很多科普写反了。

存储在 Map 的最后一个槽 `raw_transitions`(map.h:542-552),由 `TransitionsAccessor` 封装三种编码(src/objects/transitions.h:226-231,注释 :57-73):

```cpp
// Internal details: a Map's field either holds an in-place weak reference to a
// transition target, or a StoreIC handler for a transitioning store (which in
// turn points to its target map), or a TransitionArray for several target maps
// and/or handlers as well as prototype and ElementsKind transitions.
```
即:0/1 条边→内联弱引用;多条→TransitionArray(线性查 ≤32,否则二分,transitions.h:320);上限 `kMaxNumberOfTransitions = 1024 + 512`(transitions.h:149)。边是**弱引用**:目标 Map 没人用了会被 GC 清掉,树自动"剪枝"。

**写路径全貌**(`Map::TransitionToDataProperty`,src/objects/map.cc:2113-2152):

```cpp
MaybeHandle<Map> maybe_transition = TransitionsAccessor::SearchTransition(
    isolate, map, *name, PropertyKind::kData, attributes);      // map.cc:2126
if (maybe_transition.ToHandle(&transition)) {                   // 沿树命中 → 复用
  InternalIndex descriptor = transition->LastAdded();
  return UpdateDescriptorForValue(isolate, transition, descriptor,
                                  constness, value);            // map.cc:2136
}
...
if (!map->TooManyFastProperties(store_origin)) {                // map.cc:2144
  ... maybe_map = Map::CopyWithField(isolate, map, name, type, ...); // map.cc:2150
}
// 超限则退字典模式:
const char* reason = "TooManyFastProperties";                   // map.cc:2156
result = Map::Normalize(isolate, map, CLEAR_INOBJECT_PROPERTIES, reason); // map.cc:2175
```

`TooManyFastProperties` 判定(src/objects/map-inl.h:319-328):没有空闲字段、且 out-of-object 字段数超过 `max(fast_properties_soft_limit, in-object 数)` 且 store 来源是 kMaybeKeyed(keyed 写容忍更低)时退字典。`kFieldsAdded = 3`(js-objects.h:980)解释了为什么 out-of-object 属性用 PropertyArray 每次扩 3 格。

旧 Map 因字段表示泛化(如 Smi→Double)失效时置 `IsDeprecated`,实例通过 `Map::Update` → `MapUpdater` 迁到最新形态(src/objects/map.cc:904-912;MapUpdater 的免锁快路径 `TryUpdateNoLock` 在 src/objects/map-updater.cc:368)。

---

## 3. 属性存放专节:三种模式与迁移触发

### 3.1 三种存放

| 模式 | 位置 | 查找 | Map 状态 |
|---|---|---|---|
| in-object(最快) | 对象体内固定偏移 | 基址+偏移一次读 | 快 Map,`GetInObjectProperties()` 计数 |
| out-of-object(OutObject) | `properties_or_hash` → PropertyArray | 属性索引+基址 | 快 Map,索引来自 DescriptorArray |
| dictionary(慢) | `properties_or_hash` → SwissNameDictionary(默认)或 NameDictionary | 哈希表 FindEntry | `IsDictionaryMapBit=1`(map.h:383) |

对象头(src/objects/js-objects.h):JSReceiver 只有 `map + properties_or_hash_`(:44,:375);JSObject 追加 `elements_`(:1033)。取值接口三分:`property_array()` / `property_dictionary()` / `property_dictionary_swiss()`(js-objects.h:58-69)。in-object 上限 255 字节内:`kMaxInObjectProperties = (kMaxInstanceSize - kHeaderSize) >> kTaggedSizeLog2`(js-objects.h:1040-1041)。

### 3.2 快→慢(Normalize)的触发点

统一入口 `JSObject::NormalizeProperties`(js-objects.cc:3967)→ `MigrateFastToSlow`(js-objects.cc:3418,把每个字段连同值搬进字典);`MigrateToMap` 里发现新 Map 是字典 Map 时调用(js-objects.cc:3577)。触发清单:

1. **属性太多**:`TooManyFastProperties`(map.cc:2144-2175)。
2. **删除属性**:LookupIterator 删除路径直接 `NormalizeProperties(..., "DeletingProperty")`(src/objects/lookup.cc:841-848)——fast 模式靠 DescriptorArray 前缀共享,删除中段属性会破坏共享,所以一次性转字典。
3. **覆盖非最后属性的 accessor**:`TransitionToAccessorProperty` 一串 `"AccessorsOverwritingNonLast"` 等理由退字典(map.cc:2198,2239-2294)。
4. **preventExtensions 无法建 transition 边时**:`"SlowPreventExtensions"`(js-objects.cc:4668)。
5. **对象被用作原型**:`OptimizeAsPrototype` 先 Normalize 再视情况 `MigrateSlowToFast` 回快模式(js-objects.cc:5090-5115);`MakePrototypesFast`(js-objects.cc:5040)在每次 IC miss 时被调用(ic.cc:453)催促原型转快。
6. Normalize 走 **NormalizedMapCache** 复用字典 Map(map.cc:1364-1458,cache 于 :1379)。

### 3.3 慢→快

`JSObject::MigrateSlowToFast`(js-objects.cc:3982):把字典内容重建成 DescriptorArray + PropertyArray/in-object 字段。原型对象在被频繁读后借此回到快车道。

### 3.4 SwissNameDictionary:为什么重造字典

```cpp
// A property backing store based on Swiss Tables/Abseil's flat_hash_map.
//   Data table:  2*capacity*kTaggedSize; Ctrl table: capacity+7bit hash/tag;
//   PropertyDetails table: capacity 个 uint8;  Meta table: 元素数+枚举序表
```
(src/objects/swiss-name-dictionary.h:23-40)

动机:旧 NameDictionary 是"开链 + 每 entry 存 details"的哈希表,内存局部性差、缓存不友好;Swiss 布局用 SIMD 友好的 128-bit group 控制字节并行比较,查找/插入显著更快更省。开关 `V8_ENABLE_SWISS_NAME_DICTIONARY_BOOL` 在 src/common/globals.h:256-258(现代构建默认 true)。查找入口 `FindEntry`(swiss-name-dictionary.h:96 附近声明)被 LookupIterator 在字典模式调用(lookup.cc:1461-1465)。

---

## 4. ElementsKind 专节:元素种类的格(lattice)

### 4.1 枚举即格

`src/objects/elements-kind.h:92-170` 定义枚举,顺序**精心排列**:

```cpp
enum ElementsKind : uint8_t {
  PACKED_SMI_ELEMENTS,       // :95  必须排第一(配合快速 map 检查)
  HOLEY_SMI_ELEMENTS,        // :96
  PACKED_ELEMENTS,           // :101 必须排第二(PACKED_SMI 与之可一次比较)
  HOLEY_ELEMENTS,            // :102
  PACKED_DOUBLE_ELEMENTS,    // :105 未装箱 double
  HOLEY_DOUBLE_ELEMENTS,     // :106
  PACKED/HOLEY_NONEXTENSIBLE/SEALED/FROZEN_ELEMENTS,   // :109-118
  SHARED_ARRAY_ELEMENTS, DICTIONARY_ELEMENTS,           // :122-125
  FAST/SLOW_SLOPPY_ARGUMENTS_ELEMENTS,                  // :128-129
  FAST/SLOW_STRING_WRAPPER_ELEMENTS,                    // :133-134
  <全部 TypedArray kinds + RAB/GSAB 变体>,               // :136-140
  WASM_ARRAY_ELEMENTS, NO_ELEMENTS,                     // :144-147
};
```

格的三个维度(枚举序 = 偏序):packed < holey(+`kFastElementsKindPackedToHoley`,elements-kind.h:177-178);Smi < Double < Tagged;快 < 非 extensible < sealed < frozen < 字典。派生常量:`FIRST/LAST_FAST_ELEMENTS_KIND` 等(elements-kind.h:150-162)。

**升级(only-more-general)判定**(src/objects/elements-kind.cc:184-212):

```cpp
bool IsMoreGeneralElementsKindTransition(ElementsKind from_kind,
                                         ElementsKind to_kind) {
  ...
  case PACKED_SMI_ELEMENTS:
    return to_kind != PACKED_SMI_ELEMENTS;          // 任何变化都算升级
  case HOLEY_DOUBLE_ELEMENTS:
    return to_kind == PACKED_ELEMENTS || to_kind == HOLEY_ELEMENTS;
  case HOLEY_ELEMENTS:
    return false;                                   // 终点, 不再变化
}
```
`GetMoreGeneralElementsKind` 取二者更一般的(elements-kind.h:533-540)。**格只升不降**:数组一旦出现洞就永远 holey;一旦混入 double 就永远回不去 Smi。

### 4.2 packed→holey / smi→double 的降级动作

写越界或 `a[100]=1` 稀疏化时:`TransitionElementsKindImpl`(src/objects/elements.cc:1061-1104):

```cpp
if (IsHoleyElementsKind(from_kind)) to_kind = GetHoleyElementsKind(to_kind);
...
if (object->elements() == empty_fixed_array ||
    IsDoubleElementsKind(from_kind) == IsDoubleElementsKind(to_kind)) {
  JSObject::MigrateToMap(...);            // 仅换 Map, 不动 backing store
} else {
  // Smi→Double 或 Double→Object: 整体重建 FixedArray↔FixedDoubleArray
  elements = ConvertElementsWithCapacity(...);
  JSObject::SetMapAndElements(isolate, object, to_map, elements);  // :1096
}
```
Smi→Double 是真实的内存重排(Smi 槽 → 未装箱 double);Double→Object 又重排回 tagged。这类转换 + 巨大容量增长是常见性能坑。

### 4.3 Accessor 分发表:表驱动再证

每个 ElementsKind 一个 C++ accessor 类,`ELEMENTS_LIST` 宏按**枚举同序**铺表(src/objects/elements.cc:115-167),初始化时一次填入:

```cpp
// elements.cc:6114-6138 (InitializeOncePerProcess)
// 数组故意开 256 项: ElementsKind 从沙箱内读出, 须视为攻击者可控
static ElementsAccessor* accessor_array[256] = {
#define ACCESSOR_ARRAY(Class, Kind, Store) new Class(),
      ELEMENTS_LIST(ACCESSOR_ARRAY) ...
};
static_assert(IsIdentityMapping(elements_kinds_from_macro, 0)); // 序必须一致
```
运行期 `ElementsAccessor::ForKind(kind)` 就是 O(1) 下标(elements.cc:6184)。LookupIterator 的元素分支(lookup.cc:1441-1448)正是通过它拿到 `GetEntryForIndex/GetDetails`。这就是与 Map/DescriptorArray 同构的"**表驱动**"套路:枚举序即分派序。

---

## 5. IC 专节:三态与反馈槽

### 5.1 状态全集

```cpp
enum class InlineCacheState {
  NO_FEEDBACK, UNINITIALIZED, MONOMORPHIC, RECOMPUTE_HANDLER,
  POLYMORPHIC, MEGADOM, HOMOMORPHIC, MEGAMORPHIC, GENERIC,
};
```
(src/common/globals.h:1896-1915;HOMOMORPHIC=多 map 同 handler,MEGADOM=大量 DOM 接收者)

反馈槽种类(消费端视角,B 篇的生产端):`kLoadProperty / kLoadGlobalNotInsideTypeof / kSetNamed...` 等(src/objects/feedback-vector.h:46-61)。**槽的反馈字布局**:UNINITIALIZED=0;MONO=(弱 map, handler);POLY=(弱固定数组, 空);MEGAMORPHIC=**megamorphic 符号哨兵**(`FeedbackVector::MegamorphicSentinel`,feedback-vector.h:512)。`nexus.ic_state()` 从槽内容反推状态(feedback-vector.h:1001-1017)。

### 5.2 miss 时的状态推进(IC::SetCache,src/ic/ic.cc:1000-1059)

```cpp
case UNINITIALIZED:      UpdateMonomorphicIC(handler, name); break;   // :1007
case MONOMORPHIC:        // :1017
  if (UpdatePolymorphicIC(...)) /* 扩 poly */;
  [[fallthrough]];
case POLYMORPHIC:        // :1025
  if (UpdatePolymorphicIC(name, handler)) break;
  [[fallthrough]];
case HOMOMORPHIC:
  if (UpdateHomomorphicIC(...)) break;
  if (...) CopyICToMegamorphicCache(name);                            // :1041
  [[fallthrough]];
case MEGADOM:
  ConfigureVectorState(MEGAMORPHIC, name);                            // :1046
  [[fallthrough]];
case MEGAMORPHIC:
  UpdateMegamorphicCache(map, name, handler);                         // :1049
```

**megamorphic 的退化是双层的**:① 槽里写 megamorphic 符号,此后编译代码直接去查全局 **StubCache**——两张哈希表(primary 2^12 项、secondary 2^10 项,键为 (name,map) 对,src/ic/stub-cache.h:88-91,134-135,Entry 见 :34-41);② `UpdateMegamorphicCache` 把 handler 塞进 StubCache(ic.cc:1130-1144)。命中同 map+handler 重复出现时反而提前推 MEGAMORPHIC 防止 poly 无限膨胀(ic.cc:761-765);字典 map 因 rehash 会使 handler 失效,直接判 MEGAMORPHIC 防止 deopt 循环(ic.cc:787-791)。

### 5.3 LoadIC::Load 主流程(src/ic/ic.cc:416-491)

```cpp
bool use_ic = (state() != NO_FEEDBACK) && v8_flags.use_ic && update_feedback; // :419
if (MigrateDeprecated(isolate(), object)) UpdateState(object, name);          // :449
JSObject::MakePrototypesFast(object, kStartAtReceiver, isolate());            // :453
LookupIterator it = LookupIterator(isolate(), receiver, key, object);         // :457
LookupForRead(&it, IsAnyHas());                                               // :460
if (use_ic) UpdateCaches(&it);                                                // :465
```
StoreIC::Store 同构(ic.cc:2269 起),写路径多一步 `StoreIC::LookupForWrite`(ic.cc:2032,调用点 :2400)——若属性不存在且能沿 transition 树加属性,就装 **transitioning store handler**(handler 内嵌目标 Map,这正是 transitions.h:67-68 提到的第二种 transition 编码)。

### 5.4 handler 的编码与原型链校验

快路径 handler 常是纯 Smi(`LoadHandler`,src/ic/handler-configuration.h:28),kField 时编码"字段偏移 + 是否 inobject + 是否 double + 描述符索引"(:100-105);复杂 handler 是 `DataHandler` 堆对象:`smi_handler + validity_cell + data1..5`(src/objects/data-handler.h:34-36,67)。

**原型链缓存 = validity cell**:`Map::GetOrCreatePrototypeChainValidityCell`(src/objects/map.cc:2599-2656)在每个"原型链上的 holder"所属 Map 上挂一个 Cell,handler 记住它;任何原型对象增删属性会使 cell 失效,所有引用它的 handler(以及 TurboFan 代码)一次性全体失效——O(1) 失效代替 O(n) 扫描。Map 的 `prototype_validity_cell` 槽见 map.h:247,783-799。

---

## 6. 设计动机

1. **为什么隐藏类要 transition 树而不是每对象一张表?** 同构对象("先 a 后 b"与"先 b 后 a"除外)在真实程序里高度重复;树把"对象形状"变成**可共享、可弱剪枝(GC 清弱边)、可增量**的结构:新对象只需沿已有边走,无边的形状才付创建钱;同时 transition 边顺带成为 StoreIC 的 transitioning handler(ic.cc:2400),一处结构两处消费。
2. **为什么属性分 in-object / out-of-object 两级?** in-object 读是"基址+常量偏移",与字段数解耦;但对象大小在分配时就固定(255 字节硬上限,js-objects.h:971),所以属性超过预算时溢出到 PropertyArray,用 slack tracking(js-objects.h:980 的 kFieldsAdded=3)摊平增长成本。
3. **为什么 elements 分这么多 kind?** 每多一种 kind,编译器就多一种可特化的内存布局:Smi/Double 免除装箱与类型检查(packed double 可直接 SIMD/浮点load),TypedArray kinds(含 RAB/GSAB 可调长变体)每种绑定元素宽度(elements-kind.cc:33-46 的 shift/size 表),frozen/sealed 让"只读"成为 map 可见事实、从而支持省略写屏障与检查。代价由"格只升不降 + 表驱动 accessor"控制(elements.cc:6114)。
4. **IC 与 TurboFan 的协同**:TurboFan 不自己猜类型,它**读 FeedbackVector**:槽是 MONO 就按该 map 内联字段偏移;POLY 就生成 map 比较链;MEGAMORPHIC 就承认现实走通用代码。而 validity cell / protector(lookup.cc:244 起的 InternalUpdateProtector)给"假设被打破时整体作废"提供 O(1) 机制——IC 收集的事实因此可以安全地固化进优化代码。
5. **为什么删除属性退字典而不是"搬尾巴"?** DescriptorArray 在相邻 Map 间共享前缀(map.cc:1580),中段删除会让所有共享者语义复杂化;真实程序删属性远少于加属性,把罕见操作路由到慢路径(lookup.cc:841)是便宜的取舍。

---

## 7. FAQ 素材

1. **Map 是 ES 的 Map 吗?** 不是。这是 V8 内部"隐藏类/形状"对象,类名撞车;内部常叫 hidden class / shape。
2. **两个对象 Map 相同意味着什么?** 属性集合、添加顺序、字段表示、ElementsKind、原型都一致——差别只在值。`bit_field3.NumberOfOwnDescriptors` + DescriptorArray 共同定义形状(map.h:381)。
3. **添加属性一定创建新 Map?** 不一定:transition 树已有该边就直接复用目标 Map(map.cc:2126-2138);因此"按相同顺序添加相同属性"的对象收敛到同一 Map。
4. **删除属性后 Map 会"删回去"吗?** 不会。删除直接 Normalize 成字典模式(lookup.cc:841-848),再 `MigrateSlowToFast` 回快模式时得到的是**新的** Map,不会复用旧形状。
5. **holey 一定慢吗?** holey 读要多做"有没有洞"的检查并可触发原型链查找(elements-kind.h:422-431 的 `IsHoleyElementsKindForRead`),但优化代码可用 hole-check 消除;真正贵的是反复在格上升级引发的整体重排(elements.cc:1090-1096)。
6. **`undefined` 读到的是什么?** LookupIterator NOT_FOUND 后沿原型链,最终 `undefined`(strict 赋值/读取未声明变量则是 ReferenceError,ic.cc:490)。
7. **字典模式对象还有 Map 吗?** 有,Map 永远存在,只是 `IsDictionaryMapBit=1` 且属性细节改存字典 entry(lookup.cc:1459-1471)。
8. **MEGAMORPHIC 还能回 MONOMORPHIC 吗?** 常规不能(IC::SetCache 里 MEGAMORPHIC 只更新 StubCache,ic.cc:1048-1055);例外是 `TryHealMonomorphicIC` 对 baseline 代码的修复(ic.cc:970-994)与 RECOMPUTE_HANDLER 态。
9. **为什么 `const` 字段也有意义?** PropertyConstness=kConst(property-details.h:93)让编译器可把读折叠为常量;后续写同值保持 const,写不同值触发泛化(字段表示/常量性泛化 = MapUpdater 的主要工作)。
10. **prototype 与 `__proto__` 修改会怎样?** 改 `Object.prototype` 上的属性会使对应 validity cell 失效(map.cc:2599),所有依赖该原型链的 IC handler 与优化代码作废重收集。

## 深挖方向

1. **MapUpdater**(src/objects/map-updater.cc):字段表示泛化(Smi→Double→Tagged)如何沿已弃用 Map 链重算目标形状,`TryUpdateNoLock`(:368)如何让 IC 线程免锁更新。
2. **Torque 生成的字段访问层**:map-inl.h/js-objects-inl.h 中 `TaggedMember` 与压缩指针下 offset 访问的实现,验证 A 篇堆布局。
3. **AccessorAssembler**(src/ic/accessor-assembler.cc):`LoadIC_...` 内建如何用汇编消费 Smi handler(kField 分支的偏移解包),这是"快路径"的机器级真相。
4. **Protectors 体系**(lookup.cc:244 起 `InternalUpdateProtector`):Array.species / iterator 链等全局"一次性假设"的失效广播。
5. **NormalizedMapCache**(map.cc:2725 起):字典 Map 的复用如何避免重复建表,弱引用数组如何参与 GC。

---

## 写作要点速查表(函数 → 文件:行号)

| # | 内容 | 位置 |
|---|---|---|
| 1 | Map 内存布局注释(全字段) | src/objects/map.h:176-253 |
| 2 | bit_field2 含 ElementsKindBits(6b) | src/objects/map.h:357-361 |
| 3 | bit_field3 全位域(字典位/描述符数/slack 计数) | src/objects/map.h:379-393 |
| 4 | slack tracking 常量与算法注释 | src/objects/map.h:403-425 |
| 5 | TooManyFastProperties 判定 | src/objects/map-inl.h:319-328 |
| 6 | GetInObjectProperties / UnusedPropertyFields | src/objects/map-inl.h:455-458 / :507-522 |
| 7 | Map::Update(deprecated→MapUpdater) | src/objects/map.cc:904-912 |
| 8 | ShareDescriptor(相邻 Map 共享 DescriptorArray) | src/objects/map.cc:1580-1628 |
| 9 | Map::TransitionToDataProperty(沿树/建边/退字典) | src/objects/map.cc:2113-2152 |
| 10 | GetOrCreatePrototypeChainValidityCell | src/objects/map.cc:2599-2656 |
| 11 | TransitionsAccessor 三种编码 + 上限 1024+512 | src/objects/transitions.h:226-231 / :149 |
| 12 | LookupIterator 状态枚举(NOT_FOUND…TRANSITION) | src/objects/lookup.h:70-118 |
| 13 | LookupInRegularHolder(快/慢/元素三分查找) | src/objects/lookup.cc:1432-1482 |
| 14 | PrepareTransitionToDataProperty(写=转移动作) | src/objects/lookup.cc:668-716 |
| 15 | MigrateFastToSlow / MigrateSlowToFast | src/objects/js-objects.cc:3418 / :3982 |
| 16 | kFieldsAdded=3 与 kMaxInObjectProperties | src/objects/js-objects.h:980 / :1040 |
| 17 | ElementsKind 枚举 + packed→holey 步长 | src/objects/elements-kind.h:92-186 |
| 18 | IsMoreGeneralElementsKindTransition(格) | src/objects/elements-kind.cc:184-212 |
| 19 | TransitionElementsKindImpl(重排 backing store) | src/objects/elements.cc:1061-1104 |
| 20 | ELEMENTS_LIST 表 + 256 项 accessor 数组 | src/objects/elements.cc:115-167 / :6114-6138 |
| 21 | InlineCacheState 全集 | src/common/globals.h:1896-1915 |
| 22 | LoadIC::Load(挂 LookupIterator→UpdateCaches) | src/ic/ic.cc:416-491 |
| 23 | IC::SetCache(mono→poly→homo→mega 推进) | src/ic/ic.cc:1000-1059 |
| 24 | UpdateMegamorphicCache→StubCache(2^12/2^10 表) | src/ic/ic.cc:1130-1144 / stub-cache.h:88-91 |
| 25 | LoadHandler kField 的 Smi 编码 | src/ic/handler-configuration.h:100-105 |
