# D - QuickJS 对象模型属性系统与垃圾回收

> bellard/quickjs,commit `04be246`("run-test262: when updating errors, sort them so that it gives the same result with several threads")。以下行号均指仓库根的 `quickjs.c` / `quickjs.h`(本 commit 实测 grep/Read 核对;quickjs.c 共 61424 行)。
>
> 与 A 报告的衔接:A 报告给出的锚点(JSShape :974-988、Shape 代码区 :5119-5610、GC 区 :6508-6850、js_trigger_gc :1780、arena :241-317)全部核对无误;本文在此基础上展开,并纠正三个常见误解(见 §6 开头的"纠正框")。

---

## 1. 全景:一次属性读写 + 一层 GC 兜底

### 1.1 属性读决策树(JS_GetPropertyInternal,quickjs.c:8210-8364)

```
JS_GetPropertyInternal(obj, prop, this_obj)          :8210
│
├─ obj 不是 JS_TAG_OBJECT?                            :8219-8262
│   ├─ null/undefined → TypeError                     :8222-8225
│   ├─ String/Rope:tagged-int 索引<len → 单字符;      :8228-8255
│   │   "length" → len  (★原始字符串的索引读是"读前特化",不走对象)
│   └─ 其他原始值 → 换成其原型对象继续                  :8260
│
└─ for(;;) 沿 p = p->shape->proto 向上爬               :8267-8358
    ├─ find_own_property(p, prop) 命中?               :8268 (实现 :6135-6155)
    │   ├─ 普通 value     → JS_DupValue 直接返回        :8293
    │   ├─ JS_PROP_GETSET → 调 getter                  :8272-8280
    │   ├─ JS_PROP_VARREF → 解引用(可能未初始化报错)    :8281-8285
    │   └─ JS_PROP_AUTOINIT → 实例化后 continue 重试    :8286-8290
    ├─ 未命中且 p->is_exotic?                          :8296
    │   ├─ fast_array:tagged-int 在界内 → 重入快速读    :8298-8307
    │   │             typed array OOB/数字键 → undefined:8304-8316
    │   └─ 否则查 class_array[class_id].exotic:
    │       get_property(Proxy 用) / get_own_property  :8318-8352
    └─ p = p->shape->proto;为 null 则终止               :8355-8357
         └─ throw_ref_error ? ReferenceError : undefined :8359-8363
```

要点:**原型链就是 shape->proto 指针链**(:8355),没有单独的 proto 槽;`find_own_property` 用 shape 的内嵌哈希表(`atom & prop_hash_mask` 链表头插,:6122-6144)在 O(1) 期望时间内定位,同时给出属性值槽位 `p->prop[h-1]`——**属性名表(JSShape)与属性值数组(JSObject.prop)按下标平行**。

### 1.2 属性写决策树(JS_SetPropertyInternal,quickjs.c:9663-9932)

```
JS_SetPropertyInternal(obj, prop, val, this_obj, flags)   :9663
│
├─ this_obj 不是对象:沿 obj 原型链只找 setter             :9676-9697
├─ 快路径 obj==this_obj:find_own_property 命中            :9706-9737
│   ├─ flags 恰为 WRITABLE(无 TMASK/LENGTH)→ set_value 覆盖 :9709-9713
│   ├─ JS_PROP_LENGTH          → set_array_length          :9714-9717
│   ├─ GETSET / VARREF / AUTOINIT → setter/闭包槽/重试      :9718-9733
├─ 沿原型链逐层:is_exotic 分支
│   ├─ fast_array:界内数字键 → JS_SetPropertyValue         :9741-9748
│   │   typed array OOB/numeric-index:数值转换后静默丢弃   :9749-9779
│   └─ exotic 方法表:set_property(Proxy) 或
│       get_own_property(writable 判定)                   :9781-9832
├─ 新建属性(this_obj 自己身上):
│   ├─ !extensible → TypeError                            :9862-9865
│   ├─ Array+fast_array+idx==count → add_fast_array_element :9868-9874
│   ├─ GLOBAL_OBJECT / 其他 exotic → JS_CreateProperty      :9879-9883
│   └─ 普通对象 → add_property(C_W_E) 后直接赋值            :9884-9890
└─ this_obj!=obj 的泛化路径 → JS_GetOwnPropertyInternal 判定
    + JS_DefineProperty / JS_CreateProperty                :9893-9922
```

int 索引写另有更短的前置快路 `JS_SetPropertyValue`(:9947-10070):ARRAY 界内直接 `set_value(&values[idx])`(:9961-9972),idx==count 时 `add_fast_array_element` 追加(:9964-9970);MAPPED_ARGUMENTS 写进闭包 `var_ref->pvalue`(:9979-9982);typed array 按元素类型转换后写裸内存,OOB 静默(:9984-10051,注释强调**界检查必须在值转换之后**,因为 ToNumber 可能 detach buffer,:9987-9988)。

### 1.3 GC 两层结构

```
第 0 层  引用计数(主回收器)
  JS_DupValue/JS_FreeValue 内联宏:quickjs.h:687-723
  → __JS_FreeValueRT:quickjs.c:6432-6501
  特点:确定性;GC 对象计数归零并不立即 free,而是
  list_add 到 rt->gc_zero_ref_count_list 再统一析构      :6471-6484

第 1 层  cycle removal(兜底,全停)
  JS_RunGC → JS_RunGCInternal(rt, TRUE):quickjs.c:6815-6838
    (可选)gc_remove_weak_objects   :6510-6538
    gc_decref(:6697) → gc_scan(:6736) → gc_free_cycles(:6756)
  特点:把"从 GC 堆外不可达"的环整体切掉,详见 §5。
```

一个容易忽略的细节:本 commit 中 `JSGCObjectHeader` 只有 `struct list_head link`(:435-437)。`ref_count`、`mark`、`gc_obj_type` 全部放在**分配器 block header** 里——`JSMallocBlockHeader`(quickjs.c:270-280:free 链指针、block_size_idx、gc_obj_type:7、mark:1、int ref_count)。`js_rc(ptr)` 用 `container_of(ptr, JSMallocBlockHeader, user_data)` 从任意分配块反查(:1492-1495);quickjs.h:99-102 定义 `JSRefCountHeader { int ref_count; }`,注释"must match the layout of JSMallocBlockHeader",于是公开 API 的 `JS_FreeValue` 用 `(uint32_t*)ptr - 1`(quickjs.h:682-684)减的正是同一个 4 字节。**GC 元数据搭了 malloc 头的便车**,对象本体因此省一个头。

---

## 2. shape 专节:同 layout 共享,而非 transition tree

### 2.1 结构与存储

```
JSShapeProperty :968-972   hash_next:26 | flags:6 | JSAtom atom
struct JSShape  :974-988
  header(GC 对象,JS_GC_OBJ_TYPE_SHAPE :425)
  is_hashed:1   :978  在 shape_hash 表里才有效
  hash          :979  累积哈希(初始值只由 proto 决定 :5156-5163)
  prop_hash_mask/prop_size/prop_count/deleted_prop_count :980-983
  shape_hash_next :984 全局 shape_hash 表的链指针
  proto         :985  ★原型指针存在 shape 里(整条链共享)
  uint32_t hash_table[];          :986 柔性数组
  /* followed by JSShapeProperty prop[prop_size]; */ :987
```

shape 是一次 `js_malloc(get_shape_size(...))` 出来的连续内存:头 + hash_table + prop 数组(:5121-5125),与 A 报告的"三段一体的内存块"结论一致。

### 2.2 共享的精确边界:什么时候去 hash 表找,什么时候新建

全局表 `rt->shape_hash`(初始 16 桶,:5132-5141;负载因子超过 0.5 翻倍重建,:5245-5247 / :5165-5189)。唯一查表/入表的入口是 **`add_property`(:9179-9239)**,新建属性时的三种走向:

```c
// quickjs.c:9205-9237 (节选)
sh = p->shape;
if (sh->is_hashed) {
    new_sh = find_hashed_shape_prop(ctx->rt, sh, prop, prop_flags); // :9208
    if (new_sh) {                     /* ① 表里有同前缀+同新属性的 shape */
        if (new_sh->prop_size != sh->prop_size)      /* 值数组对齐 */
            p->prop = js_realloc(...);               // :9212-9219
        p->shape = js_dup_shape(new_sh);             // :9220
        js_free_shape(ctx->rt, sh);
        return &p->prop[new_sh->prop_count - 1];     // :9222
    } else if (js_rc(sh)->ref_count != 1) {          /* ② 共享中→先克隆 */
        new_sh = js_clone_shape(ctx, sh);            // :9225
        new_sh->is_hashed = TRUE;
        js_shape_hash_link(ctx->rt, new_sh);         // :9229-9230
        ...
    }
}
/* ③ 独占的未哈希 shape:直接原地加 */
add_shape_property(ctx, &p->shape, p, prop, prop_flags); // :9236
```

匹配条件在 `find_hashed_shape_prop`(:5533-5564):先比 32 位 hash——`h = shape_hash(shape_hash(sh->hash, atom), prop_flags)`(:5539-5541,hash 多项式把"属性序列+flags"编进去,Linux kernel 乘数 0x9e370001,:5144-5148)——再比 `proto`、`prop_count == n+1`,**最后逐项比对 n 个既有 atom/flags 加新 atom/flags**(:5546-5558)。也就是说:必须"同一原型、同一属性序列、同一 flags"才算同 layout;哈希命中只是预筛。

三个边界情形:
- **is_hashed=FALSE 的 shape 不参与查表**:克隆产物(:5284)、`js_new_shape_nohash`(:5233)、以及 unlink 后的 shape 都不在表里。
- **"哈希命中但形状不同"只靠 hash 预筛,逐项比较兜底**,最坏 O(链长×属性数)(:5549-5558)。
- **空 shape 有专门的 `find_hashed_shape_proto`**(:5514-5529,只比 proto+prop_count==0),给 `JS_NewObjectFromShape` 建对象用。

### 2.3 写时复制:两条 COW 触发线

| 触发线 | 函数 | 行为 |
|---|---|---|
| 加新属性且 shape 被共享 | `add_property` :9223-9232 | `js_clone_shape` → 新 shape **挂回 hash 表**(`is_hashed=TRUE`,:9229-9230)——因为"旧 shape+新属性"这个 layout 值得被后人复用 |
| 修改/删除已存在属性 | `js_shape_prepare_update` :10302-10327 | 共享则克隆且**不挂表**(:10313-10318,注释 "the resulting one is no longer hashed");独占则摘表置 `is_hashed=FALSE`(:10321-10324) |

理由:改属性 flags、删属性产生的是"退化"形状,别的对象几乎不可能再长成这样,入表只亏不赚;而"追加属性"是热路径,layout 会重复出现,入表才有收益。`js_clone_shape` 本体(:5268-5292)是除 GC 头外的整块 memcpy(:5280-5281)+ ref_count=1 + proto/atom 各自 dup(:5285-5290)。

### 2.4 add_shape_property 的"摘表-扩容-重挂"

```c
// quickjs.c:5478-5497 (节选)
if (sh->is_hashed) {
    js_shape_hash_unlink(rt, sh);                    /* ① 先摘表 :5480 */
    new_shape_hash = shape_hash(shape_hash(sh->hash, atom), prop_flags);
}
if (unlikely(sh->prop_count >= sh->prop_size)) {     /* ② 扩容 :5484 */
    if (resize_properties(ctx, psh, p, sh->prop_count + 1)) {
        if (sh->is_hashed) js_shape_hash_link(rt, sh); /* 失败重挂 :5488 */
        return -1;
    }
    sh = *psh;                                       /* 扩容可能换块 */
}
if (sh->is_hashed) {
    sh->hash = new_shape_hash;                       /* ③ 新 hash 挂回 :5494 */
    js_shape_hash_link(rt, sh);
}
```

先摘表再扩容的原因:扩容期间可能出现"内容与 hash 不符"的中间态,别的查找者如果此刻命中就会错配。`resize_properties`(:5334-5398)先 realloc 值数组再分配新 shape(注释:失败时不能出现大小不一致,:5345-5346),hash 表扩了才重散,没扩就原样拷贝。配套的还有 `compact_properties`(:5401-5467):`delete_property` 删除只是把 atom 置 `JS_ATOM_NULL` 并 `deleted_prop_count++`(:9345, :9357),墓碑攒到 ≥8 且过半才压缩(:9361-9363)。

### 2.5 与 V8 hidden class 的异同

- **相同**:都用"属性序列+属性类型标志"做 layout 指纹;都靠"同 layout 复用同一个元对象"省内存。
- **根本差异**:V8 的 Map 有 transition 树/环——从 `{}` 加 `x` 加 `y` 是一条可沿"上一状态"回溯的边,还能 back-pointer 回退、做 property tracking。QuickJS **没有 transition 边**,只有一张"结果集"哈希表:`find_hashed_shape_prop` 只能回答"有没有对象恰好长成 旧shape+新属性 这样",不能从旧 shape 走一步到新 shape。快速路径因此便宜(一次哈希+逐项比),代价是"同样加属性顺序"的对象只有当先例已入表才能共享——先例的入表时机是它自己第一次走 `add_property` 的分支①②(:9229-9230)。
- 另一处差异:quickjs 把 **proto 放进 shape**(:985),即"原型不同的两个对象 layout 必不同";V8 的 Map 同样编码 prototype(通过 prototype validity cell 关联),但获取原型是 O(1) 读对象槽,quickjs 是 O(1) 读 shape 槽,语义等价。

---

## 3. fast_array 专节:紧凑数组的进出

### 3.1 表示

`JSObject.fast_array`(:1003)为真时,数字下标不走 shape:`u.array`(:1050-1072)里 `u.values`(JSValue 数组,ARRAY/ARGUMENTS)、`u.var_refs`(MAPPED_ARGUMENTS)或类型化裸指针(typed array),`u1.size` 是容量,`count` 是元素数(:1071 注释:"0 for a detached typed array")。进入条件在 `JS_NewObjectFromShape`:ARRAY 置 `is_exotic=1; fast_array=1`(:5657-5658),ARGUMENTS/MAPPED_ARGUMENTS/typed array 同样(:5694-5695)。**length 永远是 prop[0]**(:5664-5666 注释),打上 `JS_PROP_LENGTH` flag(:5670-5671);`ctx->array_shape` 是所有普通数组共享的初始 shape(:5665)。写 length 的分发靠 `prs->flags & JS_PROP_LENGTH`(:9714-9717),不是靠 class_id 判断。

### 3.2 退出(稀疏化):convert_fast_array_to_array(:9244-9286)

触发点:删非末尾元素(:9389-9391)、`JS_CreateProperty` 写洞(:10160)、`JS_DefineProperty` 对界内下标重定义(:10586)、arguments 对象重定义数字下标(:16140-16143)等。过程:先 `js_shape_prepare_update`(:9251),一次性把 prop 数组扩到 `prop_count + len`(:9254-9260),然后逐元素 `add_property(__JS_AtomFromUInt32(i))`——MAPPED_ARGUMENTS 搬 `var_ref`(:9262-9269),普通数组搬 value(:9270-9278)——最后 free 掉 values、`count=0; values=NULL; size=0; fast_array=0`(:9279-9284)。**注意:转换后 length 的 `JS_PROP_LENGTH` flag 仍在 shape 里,只是下标不再是 u.array 而是 prop 槽。**

### 3.3 exotic length 写语义

- **追加**:`add_fast_array_element`(:9542-9570)顺带维护 length——新 count 大于当前 length 且 length 可写就把 prop[0] 拨到新值(:9551-9558);length 不可写(冻结的数组)→ TypeError(:9554-9557);容量不够按 1.5 倍 `expand_fast_array`(:9524-9538,`js_realloc2` 顺带拿 slack,:9531-9534)。前置门槛 `can_extend_fast_array`(:9935-9944):extensible 且原型为空或就是标准 Array.prototype——否则走慢路径,保证改了 Array.prototype 的对象行为正确。
- **缩容**:`set_array_length`(:9433-9521):fast_array 下从尾部 free 再 `count=len`,prop[0] 直接写新值(:9447-9455);慢数组下小差距逐个 `delete_property`(:9467-9481),大差距两遍扫(先查 non-configurable 边界、再删,:9482-9511),若因不可配置属性截不动,报 "not configurable"(:9516-9518)。
- **范围检查**:`JS_DefineProperty` 里凡是带 `JS_PROP_LENGTH` 的属性,先做 uint32 范围归一(:10368-10380)。

---

## 4. exotic 全家福

注册点:`js_arguments_exotic_methods`(:2103-2104)、`js_string_exotic_methods`(:2105)、`js_proxy_exotic_methods`(:51543);`is_exotic` 置位:类定义有 exotic 表的类(:5719-5722)+ ARRAY/typed array/arguments(:5657, :5694)。`JSObject.is_exotic`(:1002)/`fast_array`(:1003)两个 bit 决定读写循环里的特殊分支。

| 类 | 机制 | 读 | 写/重定义 | 关键行 |
|---|---|---|---|---|
| **String 对象**(JS_CLASS_STRING) | exotic 表 | `get_own_property`:tagged-int<len → ENUMERABLE 单字符 | `define_own_property`:只许写回"同一个字符",否则 "not configurable";`delete_property`:界内数字下标一律 FALSE | :45178-45200 / :45207-45245 / :45247-45259 |
| **原始字符串** | 读路径特化(非对象) | GetPropertyInternal 顶部直接切字符/length | 走原型(将 Number/String.prototype 的方法当 this 为原始值调) | :8228-8255 |
| **TypedArray** | fast_array 内建(不注册 exotic 表) | int 快路按元素类型直读(:9050-9083);atom 路径:界内→重入读,:8298-8307;OOB→undefined;numeric-index 键→undefined(:8308-8316) | int 快路:转换后写裸内存,OOB 静默;atom 路径:OOB/numeric-index "仍做 ToNumber 转换再丢弃"(:9763-9779) | :9029-9083, :9984-10051 |
| **ArrayBuffer/TypedArray detach** | JSTypedArray 结构(buffer 回指+offset/length,:771-778) | detach 后 `u.array.count=0, u.ptr=NULL`(:1071 注释)——**读 OOB 自然变成 undefined,不用特判** | `JS_DetachArrayBuffer` 清 buffer 并群发更新所有关联视图(:57064-57076;update :57021-57055) | :771-778, :57021-57076 |
| **Proxy**(JS_CLASS_PROXY) | 全套 12 个 exotic 方法(:51437-51449) | `js_proxy_get`:取 handler.get;**未定义则原样转发** `JS_GetPropertyInternal(target)`(:50822-50823);定义了则调用并做 target 不变量校验(inconsistent get,:50836-50854) | `js_proxy_set` 对称(:50859-50915,未定义转发 :50870-50874);define/delete/has/proto/extensible 各有转发 | :50809-50915 |
| **Arguments / Mapped Arguments** | 仅 `define_own_property`(:16150-16152) | mapped 读走 var_ref 解引用(:9047-9049) | 对界内数字下标重定义 → **先稀疏化**再走普通 DefineProperty(:16131-16148);mapped 写=写闭包槽(:9979-9982) | :16131-16152 |
| **Module NS** | exotic 表(:30351) | 属性多为 `JS_PROP_VARREF` 且不可写 | 写路径显式拒绝(:9723, :9907-9908) | :30351 |

Proxy 的转发语义值得强调:quickjs 没有给 proxy 建 shadow 属性,所有操作都即时转发到 target/handler;`JS_GetPropertyInternal` 的 exotic 分支在**原型链每一层**都会试探(:8296-8353),所以 proxy 出现在原型链上也能生效。

---

## 5. GC 专节:三遍 cycle removal 的不变式

### 5.1 为什么引用计数不能独立存活

普通 JSValue 的生死由 `JS_FreeValue`(quickjs.h:687-695)决定,计数归零进 `__JS_FreeValueRT`(:6432)。但对象间的引用也是计数,`A↔B` 互指时两者的计数都 ≥1,永远到不了 0。quickjs 的答案:所有 GC 对象(对象/字节码/模块/shape/var_ref/context/async 状态,枚举 :421-430)常驻 `rt->gc_obj_list`(:337-339),GC 时把**堆内互引**整体减掉,剩下的计数就只代表**堆外(栈、C 侧)引用**,为 0 即垃圾。

### 5.2 三遍流程(JS_RunGCInternal :6815-6833)

```c
// quickjs.c:6815-6833
static void JS_RunGCInternal(JSRuntime *rt, BOOL remove_weak_objects) {
    if (remove_weak_objects) gc_remove_weak_objects(rt);   // :6817-6822
    gc_decref(rt);      // 第一遍:把每个对象的子引用各减 1    :6826
    gc_scan(rt);        // 第二遍:恢复"外部可达"者的计数      :6829
    gc_free_cycles(rt); // 第三遍:仍为 0 的即环内垃圾,整体析构 :6832
}
```

**第一遍 gc_decref**(:6697-6717):遍历 gc_obj_list,对每个对象调 `mark_children(rt, p, gc_decref_child)`(:6710),把它的每个孩子 ref_count-1;孩子计数归零且 mark==1 的挪进 `tmp_obj_list`(:6691-6694)。自己标 mark=1(:6711),计数为 0 也进 tmp(:6712-6715)。
→ **不变式①:此遍后 `ref_count == 来自 GC 堆外的引用数`。** 计数不会变负——`gc_decref_child` 开头有 `assert(ref_count > 0)`(:6689),且每个父对孩子的减操作恰好一次(每条边只被其源遍历一次)。

**第二遍 gc_scan**(:6736-6754):遍历 gc_obj_list 里还活着的对象(assert ref_count>0,:6744),同样调 mark_children 但换成 `gc_scan_incref_child`(:6719-6729):孩子计数 +1,**从 0 变 1 的孩子从 tmp_obj_list 搬回 gc_obj_list 尾部**(:6722-6728)。`list_for_each` 遍历中扩链表,可达性因此传递。tmp 里剩下的就是"只被死人引用"的对象。
→ **不变式②:第二遍结束时,tmp_obj_list 中的对象,其外部引用数为 0,且其引用者全部同样在 tmp 里**——它们构成若干个纯内部环/环簇。
→ 第二遍的后半(:6750-6753)用 `gc_scan_incref_child2`(:6731-6734,**只加不减**)把死人引用的孩子的计数恢复原值,这样第三遍 free 时沿边减回去才平衡。

**第三遍 gc_free_cycles**(:6756-6813):`gc_phase = JS_GC_PHASE_REMOVE_CYCLES`(:6764),逐个取 tmp_obj_list 头:JS 值类(JS_OBJECT/FUNCTION_BYTECODE/ASYNC_FUNCTION/MODULE)调 `free_gc_object`(:6787),其余挂 `gc_zero_ref_count_list`(:6789-6792)。`free_object`(:6340-6392)在 REMOVE_CYCLES 相位下的落点很讲究:属性值照常 free(:6352-6355)、shape 立即销毁(:6359)、跑 finalizer(:6365-6367),但对象壳**只有 `ref_count==0 && weakref_count==0` 才真正 js_free**,否则挂到 gc_zero_ref_count_list 等 finalizer 链上的引用消化(:6376-6383)——这就是 finalizer 里"僵尸对象"的来源(`JS_IsLiveObject` 用 `free_mark` 位识别,:6840-6850)。收尾再清一遍 gc_zero_ref_count_list,weakref_count!=0 的对象壳保留(:6797-6810)。

### 5.3 JS_MarkValue 的覆盖面

`JS_MarkValue`(:6553-6566)只对带计数的 tag(OBJECT/FUNCTION_BYTECODE/MODULE)调 mark_func。真正的遍历在 `mark_children`(:6568-6685):

- JS_OBJECT:shape(:6579)、每个非删除属性的 value/getter+setter/var_ref/autoinit(:6582-6603)、类自定义 gc_mark(:6605-6609,typed array 标 buffer、Map 标 records、bound function 标 func_obj 等,:6020/:6204/:6310-6313);
- FUNCTION_BYTECODE:cpool(模板对象可成环,注释 :6614)+ realm(:6613-6623);
- VAR_REF:detached 的值或所属 async 帧(:6625-6637);
- ASYNC_FUNCTION:未完成帧的 this/参数栈/resolving funcs(:6639-6660;注释:运行中的函数不可能处于可删环中,:6650-6653);
- SHAPE:proto(:6662-6668);JS_CONTEXT:JS_MarkContext(全局对象、各 proto、模块表,:2725-2747);MODULE:js_mark_module_def(:6676-6680)。

**mark 位与计数同住 malloc 头**(:277);`add_gc_object` 入表时清 mark(:6540-6546),gc_decref 用它做"已访问"标记(:6711),`__JS_FreeValueRT` 也借 mark=1 表达"正在析构"(:6479)。

### 5.4 弱引用

`rt->weakref_list` 挂三类头:WeakMap/WeakSet(JS_WEAKREF_TYPE_MAP)、WeakRef、FinalizationRegistry(:439-448)。`JS_RunGC`(公开入口)先跑 `gc_remove_weak_objects`(:6510-6538):在 DECR phase 里遍历 weakref_list,清 Map 条目/断 WeakRef/排队 finrec 回调,随后 `free_zero_refcount` 清尸。对象壳的存活要同时看 `weakref_count`(:1009-1012 注释、:6385-6390、:6803-6806)。`JS_FreeRuntime` 跑的是 `JS_RunGCInternal(rt, FALSE)`,注释:不清弱引用,避免 FinalizationRegistry 又生成新 job(:2421-2423)。

---

## 6. 触发与节奏

> **纠正框**(对照调研提纲):本 commit 的三处事实与常见说法不同——
> ① `js_trigger_gc` **不是** object_count 翻倍策略,而是按 malloc 字节数;
> ② 本 commit **不存在 `JS_MallocUSizable`**(全仓库 grep 无此符号),对应能力是 `js_realloc2` 的 slack 参数(:1871-1884)与 `js_malloc_usable_size`(:1699-1718, :1815-1818);
> ③ **没有 GC-on-OOM**:malloc 失败直接 `JS_ThrowOutOfMemory`(:1845-1849, :1856-1860),不重试、不触发 GC。

`js_trigger_gc`(:1780-1798):

```c
// quickjs.c:1783-1797
force_gc = ((rt->malloc_ctx.malloc_state.malloc_size + size)
            > rt->malloc_gc_threshold);        // 按总分配字节数
if (force_gc) {
    JS_RunGC(rt);
    rt->malloc_gc_threshold = rt->malloc_ctx.malloc_state.malloc_size
        + (rt->malloc_ctx.malloc_state.malloc_size >> 1);  // 新阈值=当前×1.5
}
```

- 初始阈值 256 KB(:2083),可用 `JS_SetGCThreshold` 调(:2227-2230)。
- **唯一调用点是 `JS_NewObjectFromShape`(:5619)**,即"每新建一个 JSObject 前问一句"。字符串/属性数组扩容等纯 malloc 不触发。
- 节奏:GC 后阈值抬到当前用量的 1.5 倍 → 分配量每多 50% 才再跑一次;若 GC 收效甚微(泄漏/常驻大),阈值自动随水位上浮,避免高频空转。

`JS_FreeRuntime` 的关停顺序(:2405-2591):① 异常值(:2410)→ ② job 队列(:2412-2419)→ ③ `JS_RunGCInternal(rt, FALSE)`(:2423)→ ④ class 数组(:2468-2474)→ ⑤ **断言双清**:`assert(list_empty(&rt->gc_obj_list)); assert(list_empty(&rt->weakref_list))`(:2464-2465)→ ⑥ atoms(:2534-2545)→ ⑦ shape_hash 表(:2546)→ ⑧ DUMP_LEAKS 时的对象/atom/string/内存泄漏盘点(:2476-2584)→ ⑨ 释放 rt 本体(:2587-2590)。顺序的本质:先让 GC 把循环垃圾切完,再断言无残留,最后才敢拆 atom 表和 shape 表——因为 shape 的 atom、对象的 atom 都引用着 atom 数组。

arena 分配器小结(:241-317, :1497-1634):≤512 字节的分配走 arena(4096 字节一块,:244,切 31 档 size class,:1419-1449,free 链单链表复用 block 头前 2 字节 :270-273);更大的块直接 host malloc(`js_malloc_large` :1535-1547);arena 空了整块归还 host(:1628-1632)。GC 元数据(ref_count/mark/gc_obj_type)寄生在 8 字节 block 头里(:262-280),`JS_MALLOC_USE_ITER` 注释还预留了"遍历分配块以进一步消灭 JSGCObjectHeader 开销"的可能(:255-257)。

---

## 7. 与前作对照

- **V8**:分代、增量标记 + 并发/并行标记与清扫(major GC)、Scavenger(minor GC)。为的是交互式页面的**停顿时间**。代价:写屏障、三色不变式维护、每个对象携带 Map 指针+Marking 位等更重的头。
- **quickjs**:引用计数即时回收 + 全停三遍 cycle removal(单线程、一次到底)。为的是**内存占用与实现简单**:malloc 头即 GC 头、mark 复用、无写屏障、无增量状态机。停顿不可分片,但嵌入式/CLI 场景的 JS 任务短且允许毫秒级全停;阈值按内存水位(+50%)自适应,长期摊销下来 GC 频率可控。
- **Lua 一句话**:Lua 5.4 是纯增量三色标记-清除(带分代 assist),把"停顿"摊进 mutator;quickjs 反过来把"简单"押在引用计数上,只给环留一条全停后路——两者是同一问题在"暂停预算 vs 实现复杂度"上的相反解。

## 8. 设计动机

1. **为什么引用计数为主**:JS 没有用户定义析构,但 finalizer(C 类、Proxy revoke、Module 生命周期)和确定性内存释放是嵌入式的刚需;引用计数让对象死在"最后一个引用消失"的那一行(`JS_FreeValue` 内联,quickjs.h:687-695),峰值内存≈活跃内存,不需要标记前的滞留区。
2. **为什么 cycle removal 可以全停**:quickjs 的目标场景(qjs CLI、嵌入式解释器、单请求脚本)任务以毫秒/秒计,全停一次三遍线性扫描(g_decref/gc_scan/gc_free_cycles 都是 O(对象+边))完全可接受;换取的是核心 GC 不到 400 行、无任何并发不变式。
3. **为什么 shape 只做"同 layout 共享"不做 transition 树**:解释器的属性访问走哈希查找,没有 JIT 内联缓存对"稳定 transition 链"的强需求;全局哈希表一把抓,内存管理退化成普通 malloc/free(js_free_shape0 :5300-5318),不需要 Map 的生命周期协调。
4. **为什么 GC 元数据塞进 malloc 头**:对象头越短,小对象越省;而自定义 arena 本来就要 8 字节头记 size class,顺手装 ref_count/mark/gc_obj_type(:262-280)等于零边际成本,quickjs.h 的 `JSRefCountHeader` 布局注释(:99-102)明说了这层共谋。

## 9. FAQ 素材

1. **Q: quickjs 读 `arr[i]` 比读 `obj.x` 快吗?** A:是的,路径不同:`JS_GetPropertyValue`(:9029-9102)对 int 索引直接切 `u.array.u.values[idx]`,而 `obj.x` 至少要 `find_own_property` 哈希查找一次(:6135-6155);字节码层面 `OP_get_array_el` 也走前者(:19416 附近的内联宏)。
2. **Q: `arr[100000] = 1` 会立刻炸内存吗?** A:会先走 `JS_SetPropertyValue` → idx∉[0,count] → slow_path → `JS_CreateProperty` 触发 `convert_fast_array_to_array`(:10160)稀疏化,属性逐个挂 shape——是"变慢"而非"分配 100000 槽",但转换本身要为每个既有元素建属性条目。
3. **Q: 数组的 length 是怎么被特殊对待的?** A:flag 而非硬编码:prop[0] 打 `JS_PROP_LENGTH`(:5670-5671),写路径见 flag 走 `set_array_length`(:9714-9717),DefineProperty 做范围归一(:10368-10380)。
4. **Q: 对象的 prototype 存在哪?沿原型链查找为什么不会断?** A:存在 shape->proto(:985),整条读链每步 `p = p->shape->proto`(:8355-8357);换 proto 会走 shape 更新。
5. **Q: 循环引用会泄漏吗?** A:不会:三遍 cycle removal 保证"堆外不可达的环"整体析构(§5.2);但 finalizer 执行时可能见到半死的同伴对象(`free_mark` 位,:6347-6348, :6840-6850)。
6. **Q: WeakRef/WeakMap 条目什么时候清?** A:`JS_RunGC` 起手先 `gc_remove_weak_objects`(:6510-6538);`JS_FreeRuntime` 特意跳过(:2421-2423)。
7. **Q: 一个 JSObject 到底多大?** A:结构本体 `sizeof(JSObject)`(:5620),加 shape 指针与 prop 数组(prop_size × sizeof(JSProperty),随属性数 1.5 倍增长 :5344);GC/引用头寄生在分配器里不占对象本体(:270-280)。
8. **Q: 删除属性有 tombstone 吗?** A:有:atom 置 JS_ATOM_NULL + deleted_prop_count++(:9357, :9345),攒够 8 个且过半才 compact(:9361-9363)。
9. **Q: 为什么往 `Object.prototype` 加数字属性会"弄坏"数组优化?** A:`add_property` 检测到后把所有 context 的 `Array.prototype.is_std_array_prototype` 清位(:9184-9203),`can_extend_fast_array`(:9935-9944)从此拒绝快路追加——一次修改,全局降级。
10. **Q: TypedArray detach 后为什么不用特判?** A:detach 统一做 `u.array.count=0, u.ptr=NULL`(:57044-57045,:1071 注释),所有界检查自然失败,读 OOB 返回 undefined(:8304-8307)。

## 深挖建议

1. **trial deletion 算法源流**:gc_decref/gc_scan/gc_free_cycles 是 Bacon-Rajan "trial deletion" 的列表化变体,可对照论文验证不变式①②;tmp_obj_list 的进出条件(:6691-6694, :6722-6728)是理解正确性的全部。
2. **shape 哈希碰撞成本**:find_hashed_shape_prop 的逐项比较(:5549-5558)在最坏(大量同 hash 异 layout)时退化,可写脚本用 `JS_DumpShapes`(:5582-5609)实测 shape_hash_count 与链长。
3. **弱引用三协议**:map_delete_weakrefs / weakref_delete_weakref / finrec_delete_weakref 在 REMOVE_CYCLES 与 DECR 两个 phase 下的不同行为(对象壳保留逻辑 :6376-6392 vs :6803-6806)。
4. **分配器成本模型**:31 档 size class(:1419)对 JSValue 数组(16B 对齐)与 JSShape 的 fit 率;`js_realloc2` 的 slack 回收(:9531-9534)避免了多少次拷贝。
5. **与 fastjs/其他 fork 的差异**:本 commit 的 malloc 头即 GC 头(:270-280)是相对旧版 quickjs(独立 JSRefCountHeader + JSGCObjectHeader 内 ref_count)的最大重构,可对比旧 tag 的内存占用。

---

## 写作要点速查表

| 主题 | 函数/结构 | 行号(quickjs.c 除注明) |
|---|---|---|
| GC 元数据所在 | JSMallocBlockHeader(ref_count/mark/gc_obj_type) | :270-280 |
| JSRefCountHeader 布局共谋 | quickjs.h | quickjs.h:99-102 |
| 引用计数内联宏 | JS_FreeValue / JS_DupValue | quickjs.h:687-723 |
| GC 触发 | js_trigger_gc(malloc_size×1.5 阈值) | :1780-1798(初始阈值 :2083) |
| arena 分配 | __js_malloc / __js_free / js_malloc_new_arena | :1549-1593 / :1595-1634 / :1497-1533 |
| 计数归零入队 | __JS_FreeValueRT(gc_zero_ref_count_list) | :6432-6501(:6471-6484) |
| 对象析构 | free_object(shape 立毁/finalizer/僵尸保留) | :6340-6392 |
| 弱引用清理 | gc_remove_weak_objects | :6510-6538 |
| 标记覆盖 | JS_MarkValue / mark_children | :6553-6566 / :6568-6685 |
| 三遍 GC | JS_RunGCInternal(g_decref→gc_scan→gc_free_cycles) | :6815-6833(声明 :1393) |
| 三遍本体 | gc_decref / gc_scan / gc_free_cycles | :6697-6717 / :6736-6754 / :6756-6813 |
| shape 结构 | JSShape / JSShapeProperty / JSObject.u.array | :974-988 / :968-972 / :1050-1072 |
| 共享查找 | find_hashed_shape_prop / find_hashed_shape_proto | :5533-5564 / :5514-5529 |
| 加属性(查表/克隆/原地) | add_property | :9179-9239 |
| 摘表-扩容-重挂 | add_shape_property / resize_properties | :5469-5510 / :5334-5398 |
| 写时复制 | js_clone_shape / js_shape_prepare_update | :5268-5292 / :10302-10327 |
| 稀疏化 | convert_fast_array_to_array | :9244-9286 |
| length 语义 | set_array_length / add_fast_array_element | :9433-9521 / :9542-9570 |
| 读全链 | JS_GetPropertyInternal(find_own_property :6135) | :8210-8364 |
| 写全链 | JS_SetPropertyInternal / JS_SetPropertyValue | :9663-9932 / :9947-10070 |
| exotic 表 | js_proxy/js_string/js_arguments_exotic_methods | :51437-51449 / :45261-45265 / :16150-16152 |
| Proxy 转发 | js_proxy_get / js_proxy_set | :50809-50857 / :50859-50915 |
| detach | JS_DetachArrayBuffer / update_typed_arrays | :57064-57076 / :57021-57055 |
| 关停断言 | JS_FreeRuntime(gc_obj_list/weakref_list 清空断言) | :2405-2591(断言 :2464-2465) |
