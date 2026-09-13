# 源码深读 · QuickJS 系列之二 —— 第 1 章:全景

> 调研对象:bellard/quickjs,shallow clone,commit **04be246**(run-test262 排序修复),VERSION 文件值为 **2026-06-04**(VERSION:1)。
> 本版核心 quickjs.c 共 **61424 行**(另有 quickjs.h 1180 行、quickjs-atom.h 283 行、quickjs-opcode.h 366 行)。
> 所有行号均为仓库相对路径 `文件:行号`,已逐一 grep/Read 核对。

---

## 1. 全景:一个 JS 程序的执行旅程

```
 qjs.c main (qjs.c:314)
   │  JS_NewRuntime ──────────► JSRuntime(堆/atom 表/GC/shape 哈希)
   │  JS_NewContext ──────────► JSContext(全局对象/类原型/已加载模块)
   ▼
 源码字符串 "1+2*3"
   │  JS_EvalInternal (quickjs.c:37304)
   │    ├─ next_token 词法分析        (quickjs.c:22829)
   │    ├─ js_parse_program 语法分析  (quickjs.c:37078)
   │    │    └─ 生成 JSFunctionDef, emit 字节码 (dbuf_putc, quickjs.c:33000 附近)
   │    │       resolve_variables (34187) → resolve_labels (34796)
   │    │       → compute_stack_size (35753) → js_create_function (36024)
   │    └─ JS_EvalFunctionInternal (37148)
   ▼
 字节码 JSFunctionBytecode (结构体 quickjs.c:685)
   │  JS_CallInternal 解释执行 (quickjs.c:17746)
   │    ├─ alloca 出 arg/var/stack 三段帧 (17834-17868)
   │    ├─ goto *dispatch_table[opcode] 直接线程化 (17761-17785)
   │    └─ 遇 OP_call 递归进入下一层 JS_CallInternal
   ▼
 运行期副作用
   ├─ 新对象:JS_NewObjectFromShape (5613) ── shape 共享/转移(第 4 节)
   ├─ 属性增删:add_property (9181) / delete_property (9311)
   └─ 内存增长触发 js_trigger_gc (1780):malloc_size 超阈值 → JS_RunGC
        GC = 引用计数 + 环回收:gc_decref(6697)→gc_scan(6736)→gc_free_cycles(6756)
   ▼
 退出:JS_FreeContext (2765) → JS_FreeRuntime (2405)
      (逆序释放 module/job/atom 表/class 表/shape 哈希, 并断言 atom 只剩内置项)
```

要点:QuickJS **没有 JIT、没有解释前的中间 IR 二次 lowering**——解析器直接把 AST"顺手"发射(dbuf)成字节码,三个后端 pass(变量解析、跳回修补、栈深计算)完成后即交给一个直接线程化(direct-threaded)的 switch 解释器。理解全景就是理解这条 6 万行直线上的十个分区。

### quickjs.c 行号分区地图(61424 行)

| 行号区间 | 分区 | 关键锚点 |
|---|---|---|
| 1-240 | 配置宏/调试开关/常量 | DUMP_* 81-100;rope 阈值 214-219 |
| 241-317 | **小块 arena 分配器数据结构** | JSMallocBlockHeader 270;arena 4096B 244 |
| 319-391 | struct JSRuntime | atom 表 323-329;shape_hash 386-389 |
| 393-401 | struct JSClass | finalizer/gc_mark/call/exotic |
| 407-464 | JSStackFrame、GC 头、JSVarRef | JSGCObjectHeader 435 |
| 466-512 | bigint limb 与缓冲 | JSBigInt 490 |
| 514-559 | struct JSContext | class_proto 528;global_obj 541 |
| 567-609 | atom 类型枚举、JSString、rope | JSString 583 |
| 611-1240 | 闭包变量/JSFunctionBytecode 等 | JSFunctionBytecode 685 |
| 1240-1415 | 类枚举与前向声明 | JS_CLASS_OBJECT=1 124 |
| 1416-1778 | **js_malloc 实现(arena 分层)** | __js_free 1600 附近 |
| 1780-2065 | GC 触发/栈限制检查 | js_trigger_gc 1780 |
| 2067-2260 | **Runtime 生命周期 + 默认分配器** | JS_NewRuntime2 2067;def_malloc_funcs 2209 |
| 2262-2380 | 微任务 job 执行 | JS_ExecutePendingJob 2303 |
| 2384-2590 | js_free_string、JS_FreeRuntime | JS_FreeRuntime 2405 |
| 2593-2866 | Context 生命周期/JS_MarkContext | JS_NewContext 2627 |
| 2868-3814 | **JSAtom 子系统** | __JS_AtomFromUInt32 2891;JS_InitAtoms 3078 |
| 3816-4000 | JSClass 注册 | JS_NewClassID 3822 附近 |
| 4002-5117 | string_buffer/字符串/rope | rope 平衡 4934,5002 |
| 5119-5610 | **JSShape 支持** | find_hashed_shape_prop 5533 |
| 5611-6157 | 对象构造/原型/属性可见性 | JS_NewObjectFromShape 5613 |
| 6159-6506 | free_object(环内释放) | 6159 |
| 6508-6850 | **垃圾回收(环回收)** | JS_RunGCInternal 6815 |
| 6852-7350 | 内存统计 JSMemoryUsage | 6852 |
| 7354-8200 | 异常抛出与回溯/中断轮询 | build_backtrace 7538;js_poll_interrupts 7877 |
| 8210-11600 | 属性访问/描述符/快数组转换 | JS_GetPropertyInternal 8210;JS_DefineProperty 10350 |
| 11600-17740 | 类型转换/运算/比较/ToNumber… | JS_ToNumber 13083 |
| 17746-22130 | **解释器 JS_CallInternal** | dispatch 表 17767 |
| 22134-29900 | **词法+语法分析** | next_token 22829;js_parse_class 25274 |
| 29913-31600 | 模块系统(加载/异步求值) | JS_SetModuleLoaderFunc 29913 |
| 31600-37100 | 字节码发射与三个后端 pass | resolve_variables 34187 |
| 37100-37820 | js_create_function/Eval 入口 | js_parse_program 37078;JS_Eval 37338 |
| 37824-38720 | 字节码序列化(写) | JS_WriteFunctionTag 37826 |
| 38725-39510 | 字节码序列化(读) | JS_ReadObjectRec 39312 |
| 39511-61424 | **内置对象与全部 JS_AddIntrinsic** | banner 39510;Object 40098;WeakRef 收尾至 EOF |

---

## 2. 双层运行时:JSRuntime 与 JSContext

QuickJS 是"一个堆、多个 realm"的架构,与 V8 的 isolate/context 对应关系几乎一一映射:

| QuickJS | V8 对应 | 持有内容 |
|---|---|---|
| JSRuntime(quickjs.c:319) | Isolate | 分配器、atom 表、class 表、GC 对象链、shape 哈希、微任务队列、模块加载器、栈限制 |
| JSContext(quickjs.c:514) | Context(=ES Realm) | 全局对象、各类原型、内置构造器、已加载模块、eval/regexp 编译函数指针 |

- **JSRuntime 侧的状态**(quickjs.c:319-391):`malloc_ctx`(320,内嵌分配器上下文)、`atom_hash/atom_array`(327-328)、`class_array`(332)、`context_list`(334)、`gc_obj_list` 与 `gc_phase`(337-341)、`weakref_list`(343)、`job_list`(366,微任务队列在 runtime 上)、module loader 函数指针(368-375)、`shape_hash`(389)。
- **JSContext 侧的状态**(quickjs.c:514-559):五个预置 shape——`array_shape`/`arguments_shape`/`mapped_arguments_shape`/`regexp_shape`/`regexp_result_shape`(522-526);`class_proto[]` 按 class_id 索引的原型数组(528);`global_obj` 与 `global_var_obj`(541-542,后者是全局 let/const 的词法层);`loaded_modules`(549);甚至把 `compile_regexp`/`eval_internal` 做成函数指针(552-557)以便关闭 eval/正则时解绑(见第 7 节模块化)。
- **一 runtime 多 context**:`JS_NewRuntime2` 初始化列表与 atom 表(2085-2096),`JS_NewContextRaw` 把 context 挂进 `rt->context_list`(2608)并注册为一个 GC 对象(2602);GC 扫描时经 `JS_MarkContext`(2717-2763)把每个 context 的全局对象/原型/预置 shape 全部作为根标记——所以 context 之间不共享对象可达性,只有 runtime 级的 atom/class/shape 三张表共享。
- **realm 随函数走**:`JSFunctionBytecode.realm`(quickjs.c:712)记录函数所属 realm;解释器每进入一个字节码函数就 `ctx = b->realm`(quickjs.c:17871),跨 realm 调用自动切换。这正是 V8 中 "每个函数闭包绑定创建它的 context" 的等价物。
- **销毁顺序**:`JS_FreeRuntime`(2405)先释放 job、跑一次不清理弱引用的 `JS_RunGCInternal(rt, FALSE)`(2423),再逐层释放 class 名 atom(2471)、context 列表、shape 哈希、atom 表——并在 2477 断言"只剩 JS_InitAtoms 预定义的 atom",这是排查泄漏的内置探针。

对照与差异:V8 的 Isolate 里还有 JIT 代码空间、编译管线、IC 系统;QuickJS 的 runtime 极薄——去掉分配器/atom/GC 四件套后几乎没有别的状态。双层的实质是:**进程级共享的"名称系统"(atom/class/shape)与 realm 级共享的"对象系统"(global/proto/module)分账管理**。

---

## 3. JSValue 表示:NaN-boxing 与 64 位 tag 两种模式

入口在 quickjs.h:

- **模式选择**(quickjs.h:56-65):指针 64 位(`JS_PTR64`)时**不启用** NaN-boxing;只有 32 位平台 `#ifndef JS_PTR64 → #define JS_NAN_BOXING`(63-65)。另有 `CONFIG_CHECK_JSVALUE` 调试模式用指针低位存 tag(105-143)。
- **NaN-boxing 模式**(quickjs.h:145-214):`typedef uint64_t JSValue`(147)。
  - `JS_VALUE_GET_TAG(v) = (int)(v >> 32)`(151):**tag 占高 32 位**,负数 tag 表示带引用计数的指针型;低 32 位是 int 值或指针载荷(指针被截断到 32 位,所以仅限 32 位平台可用)。
  - `JS_MKVAL(tag,val) = ((uint64_t)tag << 32) | (uint32_t)val`(157):null/undefined/bool/exception 等即时值一个字节常量搞定。
  - double 直接"裸放"进 64 位字:float64 判定用区间法 `JS_TAG_IS_FLOAT64(tag) = (unsigned)(tag - JS_TAG_FIRST) >= (JS_TAG_FLOAT64 - JS_TAG_FIRST)`(191)。`JS_FLOAT64_TAG_ADDEND = 0x7ff80000 - JS_TAG_FIRST + 1`(160,即 quiet-NaN 高位到 tag 区间的补偿);取值时 `u.v += ADDEND<<32`(169),构造时 `u.u64 - ADDEND<<32` 并把各种 NaN 归一为 `JS_NAN`(175-189)。
- **64 位模式**(quickjs.h:216-282):`struct JSValue { JSValueUnion u; int64_t tag; }`(229-232),16 字节,tag 与载荷分开;`JS_VALUE_GET_FLOAT64` 直读 `u.float64`(241)。
- **tag 布局**(quickjs.h:75-96):`JS_TAG_FIRST=-9`,BIG_INT(-9)、SYMBOL(-8)、STRING(-7)、STRING_ROPE(-6)、MODULE(-3)、FUNCTION_BYTECODE(-2)、OBJECT(-1)为负(带引用计数,注释 76 行"all tags with a reference count are negative");INT=0、BOOL=1、NULL=2、UNDEFINED=3、UNINITIALIZED=4、CATCH_OFFSET=5、EXCEPTION=6、SHORT_BIG_INT=7、FLOAT64=8 为非负。`JS_VALUE_HAS_REF_COUNT(v)` 用一次无符号比较判"负 tag"(287)。
- SHORT_BIG_INT(7):小 BigInt 就地存单个 limb,免堆分配——与 `JSBigIntBuf`(quickjs.c:498-502)配合,是 2025-04-26 版"新 BigInt 实现,小数值优化"(Changelog:31)的底层支撑。

**为什么选 NaN-boxing(32 位下)**:值即一个机器字,寄存器传值、压栈、写 prop 数组都不需要二次解引用;tag 提取是一次移位,float64 判定是一次无符号区间比较。代价是指针必须能塞进 32 位载荷。64 位平台 Bellard 反而选了 16 字节 struct 而非流行的 45 位指针 tag 方案——换取 `JS_VALUE_GET_PTR` 无需掩码运算,放弃值占两个字的缓存密度,这是"解释器足够快、实现足够简单"取向下的典型 QuickJS 式取舍。

---

## 4. 对象模型:JSShape 共享 + prop 数组 + JSClass 回调

### 4.1 JSShape 与 JSObject

```c
/* quickjs.c:974-988(节选) */
struct JSShape {
    JSGCObjectHeader header;
    uint8_t is_hashed;         /* 是否已插入 runtime 级 shape 哈希表 */
    uint32_t hash;             /* 由 proto+各 (atom,flags) 递进哈希 */
    uint32_t prop_hash_mask;
    int prop_size, prop_count, deleted_prop_count;
    JSShape *shape_hash_next;  /* 哈希桶内链表 */
    JSObject *proto;
    uint32_t hash_table[];     /* 变长尾:哈希表 + JSShapeProperty 数组 */
};
```

- `JSShapeProperty` 只有三个字段:`hash_next:26 + flags:6 + atom`(quickjs.c:968-972)——**shape 只记录"名字+属性标志",不存值**;值在对象自己的 `prop[]` 数组里与 shape 下标平行存放(`JSObject.shape`(1013) + `JSObject.prop`(1014),struct JSObject 990-1077)。
- **共享**:shape 本身是 GC 对象(`JS_GC_OBJ_TYPE_SHAPE`,quickjs.c:425),带引用计数;`js_dup_shape`(5294)只加计数。runtime 级 `shape_hash` 表(初始 16 桶,5132-5136)把全堆的形状按 `hash(proto)` 与 `hash(父shape, atom, flags)` 索引,哈希乘数借用 Linux 内核的 `0x9e370001`(5144-5148)。
- **转移(transition)**:加属性走 `add_property`(9181)→`find_hashed_shape_prop`(5533,先比哈希再逐 prop 全比,5546-5558):命中就把对象切到目标 shape(必要时 realloc prop 数组,9212-9219);未命中且 shape 被共享(`ref_count != 1`)则先 `js_clone_shape`(9223-9233,写时复制);最后 `add_shape_property`(5469)先把旧 shape 从哈希表摘下(5480),追加 `(atom,flags)` 后用新哈希挂回(5494-5497)——**正是"哈希表里挂转移后 shape"的 hidden-class 思路**。
- **对象创建**:`JS_NewObjectFromShape`(5613)从(共享的)空 shape 出发;数组类用 `ctx->array_shape`,首个数组真实补出 `length` 首属性(5662-5672);快数组走 `u.array.values/count` 旁路(`fast_array` 位,1003),溢出为慢属性时 `convert_fast_array_to_array`(9244)。
- 删除属性会把 shape 里槽位标 `JS_ATOM_NULL` 累计 `deleted_prop_count`,`resize_properties` 时压缩(5441-5457)。

### 4.2 与 V8 hidden class 的对照

| 维度 | QuickJS JSShape | V8 Hidden Class(Map) |
|---|---|---|
| 存储 | shape 表 + 对象侧 prop 值数组,下标对齐 | descriptor 数组在 Map 内,字段值在对象槽位 |
| 转移复用 | `find_hashed_shape_prop` 全堆哈希索引(5533) | transitions 树,从 Map 回退指针 |
| 回退(删除) | 原位标记删除,扩容时压缩 | back-pointer 链回退 |
| 与执行器耦合 | 无内联缓存,解释器每次查 shape 哈希 | IC:load/store 站点缓存 handler |
| 原型 | `JSShape.proto` 指针 + 对象位图 `is_std_array_prototype`(998) | prototype validity cell |

结论:**QuickJS 做 shape 共享不是为 JIT,而是省内存**——同形状的 1 万个对象只共享一份"名字表",每对象只多 8 字节 shape 指针加一个值数组;没有 IC,意味着属性访问每次都要走 `JS_GetPropertyInternal`(8210)的哈希查找。

### 4.3 JSClass:C 侧回调表

`struct JSClass`(quickjs.c:393-401)只有五项:`class_id/class_name/finalizer/gc_mark/call/exotic`。注册发生在 runtime 级 `init_class_range`(2024,`JS_NewRuntime2` 里挂 2100-2111);`JSClassDef`(quickjs.h:531-544)定义:

- `finalizer` / `gc_mark`:环回收的两个必须回调(gc_mark 在 `mark_children` 中被调,quickjs.c:6605-6609);
- `call`:使对象可调用(区分构造调用靠 `JS_CALL_FLAG_CONSTRUCTOR`,quickjs.h:526);
- `exotic`:`JSClassExoticMethods`(quickjs.h:482-521)11 个回调(get_own_property/define_own_property/get_prototype…),Proxy、字符串、模块 namespace、typed array 的下标行为全靠它;注释直言该指针"只为省内存"而多一层间接(541-543)。

内置类的 exotic 挂接点:`JS_NewRuntime2` 里 arguments/string/module_ns 四类(quickjs.c:2103-2106)。类 id 从 `JS_CLASS_OBJECT=1` 起连续编号(124)。

---

## 5. Atom 子系统:字符串驻留与弱引用

atom = runtime 级唯一化的字符串句柄(32 位),对象属性名、字节码里的名字全部用 atom。

- **整型小 atom 免分配**:`JS_ATOM_TAG_INT = 1<<31` 位直接把 `0..2^30-1` 编码成 atom(quickjs.c:2870-2894),数组下标字符串 `arr["5"]` 永不进哈希表;`is_num_string`(2907)负责把字符串判回数字。
- **驻留表**:runtime 的 `atom_hash`(桶内存 atom 下标)与 `atom_array`(下标到 JSString)(quickjs.c:327-328);初始 512 桶(3088),计数达桶数 2 倍即 rehash(`JS_ATOM_COUNT_RESIZE(n)=2n`,2875;rehash 循环 3055-3073)。哈希函数 `h*263+c`(2942-2959)。
- **X-macro 内置 atom**:quickjs-atom.h 以 `DEF(name,"str")` 定义 **242 个**内置 atom(grep -c 统计),`JS_InitAtoms`(3078-3105)从 `JS_ATOM_END` 循环注入;`null` 必须第一(quickjs-atom.h:41 附近注释),`JS_ATOM_Private_brand` 起是私有名、`JS_ATOM_Symbol_toPrimitive` 起是 symbol 类型(quickjs.c:3093-3098)。
- **生命周期与"freeze"**:`JS_DupAtom/JS_FreeAtom`(3107-3129, 3724)对 `__JS_AtomIsConst`(2877-2884,即下标 < JS_ATOM_END)的内置 atom 不做任何计数——**内置 atom 永生,这是本版唯一意义的"冻结"**;运行期 atom 引用归零时 `JS_FreeAtomStruct`(3374-3410)从哈希链摘除并把槽位挂进 `atom_free_index` 空闲链(3306-3308),atom 下标可复用。
- **字符串双格式与驻留载体**:`JSString`(583-599)`len:31 + is_wide_char:1`,`hash:30 + atom_type:2`(8 位/16 位两种存储,前缀判等快路径);普通字符串与 atom 共用同一 JSString,`atom_type != 0` 即是 atom(2384-2397 的 `js_free_string` 按此分流)。
- **symbol 弱引用**:`atom_type==JS_ATOM_TYPE_SYMBOL` 的 JSString 由 `hash` 字段改存 `weakref_count`(586-588 注释),Symbol 不被强引用时在 GC 的 `gc_remove_weak_objects`(6510-6538)中清理;Map/WeakMap/FinalizationRegistry 三类弱引用同样在该步处理(6518-6532)。
- 长字符串拼接用 rope(601-609),超阈值或过深才折叠成连续字符串(`JS_ConcatString` 一线,平衡算法在 5002)。

---

## 6. 工程面:单文件哲学、test262、发布节奏

### 6.1 分层构建与零依赖

- 目录即依赖清单:`quickjs.c/h`(引擎核心)、`quickjs-atom.h`/`quickjs-opcode.h`(两个 X-macro,242 atom / 244+19 opcode)、`libregexp`(3448 行)、`libunicode`(2124 行+5206 行表)、`cutils`(641 行)、`dtoa`(1620 行);宿主层 `quickjs-libc.c`(4403 行)、REPL `qjs.c`(568 行)、字节码编译器 `qjsc.c`(876 行)、测试器 `run-test262.c`(2555 行)。
- 全部 MIT,无第三方库(quickjs.h:1-30 许可头;doc/quickjs.texi:31 宣称 "few C files, no external dependency, 210 KiB of x86 code")。
- `qjs` REPL 本身是 **JS 写的**(repl.js,3.9 万字节),经 qjsc 预编译成 C 数组 `qjsc_repl` 内嵌,`main` 里 `js_std_eval_binary` 启动(qjs.c:524)。
- Makefile 关键目标:README 级有 `all`(250)、`install`(377)、`test`(452-469)、`stats`(472,跑 `qjs -qd` 内存统计)、`microbench`(475)、`test2-bootstrap`(478-484,固定 test262 commit 浅克隆+打补丁)、`test2`(503)/`test2o`(ES5.1 旧套件,494)/`test2-check`、`bench-v8`(532,`node --jitless` 对照跑)、`build_doc`(431,texi→pdf/html)、fuzz 系列(275-284)。

### 6.2 test262 基建

- run-test262 是**多线程 C runner**(pthread,run-test262.c:36-57),支持 `--harnessdir/--harnessexclude/harness_features` 等 test262.conf 指令(1172-1181);agent 机制支持 async 测试与 shared memory。
- test262.conf:`style=new`、`mode=default`、`async=yes`、`module=yes`(test262.conf:5-31);已知失败白名单 `test262_errors.txt` 仅 **58 行**(test262_errors.txt:1-58,集中在 annexB assignmenttargettype 与 S11.13.x 赋值作用域)。
- 官方口径(doc/quickjs.texi:38-39):选择 ES2025 特性后"Passes nearly 100% of the ECMAScript Test Suite";性能口径(texi:34-35):单核 2 分钟跑完全套,runtime 完整生命周期 < 300 微秒。
- CI(.github/workflows/ci.yml):Linux/macOS/Windows 三平台 `make CONFIG_WERROR=y` + 基本测试。

### 6.3 单人节奏

- Changelog 频率:2024-01-13 → 2025-04-26 → 2025-09-13 → 2026-06-04,**每年 1-3 个版本**,单版本携带一大包特性(2026 版:自研小块 malloc 快 11%、微优化 30%、resizable ArrayBuffer、Iterator helpers、Set methods 等,Changelog:1-15)。
- release.sh 按包分发:extras/binary/win_binary/cosmo_binary/quickjs(release.sh:15-18),文档只有 doc/quickjs.texi(readme.txt:1)。
- 这是 Bellard + Charlie Gordon 双署名、以 Bellard 为主导的单仓库(quickjs.c:4-5),没有开源基金会式的多维护者结构——社区分支 quickjs-ng 承担了部分快速迭代需求。

---

## 7. 设计动机

1. **为什么不上隐藏类 JIT**:内存与启动目标是硬约束(texi:31 "210 KiB"、34 "<300 microseconds");JIT 需要代码空间、编译队列与 IC 元数据,与"运行时生命周期 300 微秒"直接冲突。解释器用直接线程化 dispatch 表(quickjs.c:17767-17785)+ 短操作码(quickjs-opcode.h 19 条 `def`,push_0/push_1/get_loc0 等)已把 dispatch 开销压到较低水平;性能敏感点(字符串拼接、BigInt 小值、快数组)都用数据结构优化而非代码生成解决。
2. **那为什么还要 shape**:收益不在执行速度而在**内存密度与属性查找路径统一**——共享名字表省掉每对象哈希表;写时复制(9223-9233)保证共享无代价;`find_hashed_shape_prop` 把"同序列添加属性"的对象收敛到同一 shape,哈希桶本身就是廉价的转移缓存。
3. **零依赖目标**:libregexp/libunicode/libbf/dtoa 全部自带,连 Unicode 表都由 unicode_gen.c 从官方数据生成;好处是可交叉编译到任何平台(CI 里 Windows 是 MinGW 交叉,Makefile:31-34),代价是 bellard 要自己维护三个子库。
4. **GC 为什么是"引用计数+环回收"混合**:引用计数提供确定性与低内存峰值(无标记位图),环回收(`gc_decref/gc_scan/gc_free_cycles`,6697-6794)补足循环引用;弱引用统一在 `gc_remove_weak_objects` 一步(6510)。相比分代复制 GC,暂停时间不可控但平均开销小,契合嵌入式场景。
5. **模块化初始化**:`JS_NewContext` 由 11 个 `JS_AddIntrinsic*` 组合而成(2635-2645),而 `JS_NewContextRaw` 只给空 realm(2622);`ctx->eval_internal`/`compile_regexp` 是函数指针(552-557)——宿主可裁掉 eval/正则以缩小体积或满足安全需求(qjsc 静态编译时相应放弃这些 intrinsic)。

---

## 8. FAQ 素材

1. **QuickJS 有 JIT 吗?** 没有。只有 switch/goto 混合的字符串化解释器(quickjs.c:17761-17785),`DIRECT_DISPATCH` 时用 GCC label 地址表。
2. **JSValue 多大?** 32 位平台 8 字节(NaN-boxing,quickjs.h:147);64 位平台 16 字节 struct(quickjs.h:229-232)。
3. **为什么 64 位反而不 NaN-boxing?** 32 位载荷放不下 64 位指针;与其做 48 位指针压缩,不如直接用 16 字节结构换实现简单(quickjs.h:216-282)。
4. **对象和 V8 一样有 hidden class 吗?** 机制同源不同实现:JSShape 全堆哈希共享+写时复制(quickjs.c:5533,9223),无转移回退链、无内联缓存。
5. **数组怎么存?** `fast_array` 位(quickjs.c:1003)+ `u.array.values/count` 连续存储(1050-1072),溢出/空洞时一次性转普通属性(9244)。
6. **内存上限怎么实现?** 默认分配器每次分配前比对 `malloc_limit`(quickjs.c:2160),`usable_size` 用 `_msize/malloc_usable_size/malloc_size`(2139-2150);`JS_SetMemoryLimit`(2221)运行时可改。
7. **一个小块分配器为什么值得写?** 2026 版把 16-512B 的 GC 对象放进 4KB arena、31 个尺寸类(quickjs.c:243-247),8 字节头顺带承载 ref_count/GC 标记(270-280),Changelog 称 bench-v8 提速 11%(Changelog:3)。
8. **atom 会被回收吗?** 用户 atom 引用归零即回收并复用下标(quickjs.c:3374-3410);内置 242 个 atom 是常量、永不回收(2877-2884)。
9. **test262 真的 100%?** 官方说"nearly 100%"(doc/quickjs.texi:38),仓库内置失败清单 58 行(test262_errors.txt),主要是 annexB 与赋值求值顺序。
10. **怎么静态编译 JS 成可执行文件?** qjsc 把源码编译成字节码再生成 C 数组(quickjs.c:37824 起的 BCWriter 对应 qjsc.c),链接 libquickjs 即无外部依赖(texi:40)。

## 深挖入口(后续章节的路标)

1. **解释器逐条 opcode**:JS_CallInternal 的帧布局与 `OP_call*` 家族——quickjs.c:17746-22000;配合 quickjs-opcode.h 的 DEF/def 双层表。
2. **三个后端 pass 各自修什么**:resolve_variables(闭包变量改写,34187)→ resolve_labels(跳转/短操作码裁剪,34796)→ compute_stack_size(栈深验证,35753)。
3. **环回收的正确性论证**:gc_decref/gc_scan 的两遍计数如何等价于"外部引用数"(6697-6754),finalizer 期间僵尸对象可见性(JS_IsLiveObject,6843)。
4. **字节码序列化格式**:BCWriter/BCReader 的版本与原子表重映射(37824-39510),qjsc 产物兼容性来源。
5. **exotic 对象全景**:Proxy/字符串/typed array/arguments 四套 JSClassExoticMethods 如何实现 `[[GetOwnProperty]]` 语义(quickjs.h:482-521;挂接 quickjs.c:2103-2106)。

---

## 写作要点速查表

| # | 主题 | 位置 |
|---|---|---|
| 1 | 版本/commit | VERSION:1 = 2026-06-04;commit 04be246;quickjs.c 共 61424 行 |
| 2 | JSRuntime 结构体 | quickjs.c:319-391(atom 323-329,gc 337-343,job 366,shape_hash 386-389) |
| 3 | JSContext 结构体 | quickjs.c:514-559(预置 shape 522-526,class_proto 528,global_obj 541) |
| 4 | JSValue NaN-boxing / 64 位 | quickjs.h:145-214 / 216-282;tag 枚举 75-96;32 位才启用 63-65 |
| 5 | JSShape / JSShapeProperty | quickjs.c:974-988 / 968-972;JSObject 990-1077(shape 1013,prop 1014) |
| 6 | shape 查找/克隆/转移 | quickjs.c:find_hashed_shape_prop 5533;js_clone_shape 5268;add_shape_property 5469;add_property 写时复制 9181-9238 |
| 7 | 对象创建 | JS_NewObjectFromShape 5613;数组 length 首属性 5662-5672 |
| 8 | JSClass 与 exotic | quickjs.c:393-401,挂接 2103-2111;JSClassDef quickjs.h:531-544;ExoticMethods 482-521 |
| 9 | atom:小整数/驻留/初始化/回收 | quickjs.c:2886-2898 / 2942-2959 / JS_InitAtoms 3078 / JS_FreeAtomStruct 3374;内置 242 个(quickjs-atom.h) |
| 10 | 分配器:arena/8 字节头/默认 malloc | quickjs.c:241-317(JSMallocBlockHeader 270);def_malloc_funcs 2136-2214;SetMemoryLimit 2221 |
| 11 | GC 触发与环回收 | js_trigger_gc 1780;gc_decref 6697;gc_scan 6736;gc_free_cycles 6756;JS_RunGCInternal 6815 |
| 12 | 生命周期 API | JS_NewRuntime2 2067/JS_NewRuntime 2216;JS_FreeRuntime 2405;JS_NewContextRaw 2593/JS_NewContext 2627(11 个 intrinsic 2635-2645);JS_FreeContext 2765 |
| 13 | 解释器入口 | JS_CallInternal 17746;dispatch 表 17767;帧 alloca 17834-17868;ctx=b->realm 17871 |
| 14 | 解析/求值链 | next_token 22829;js_parse_program 37078;js_create_function 36024;JS_EvalFunctionInternal 37148;JS_EvalInternal 37304 |
| 15 | 模块系统 | JS_SetModuleLoaderFunc 29913(/2 29924);JS_GetScriptOrModuleName 30854 |
| 16 | 字节码读写 | BCWriter JS_WriteFunctionTag 37826;BCReader JS_ReadObjectRec 39312 |
| 17 | 常量与统计 | opcode 244+19(quickjs-opcode.h);test262_errors.txt 58 行;doc/quickjs.texi:31-42(210KiB/300us/nearly 100%) |
| 18 | Makefile 工程 | TEST262_COMMIT Makefile:60;test 452;microbench 475;test2 503;bench-v8 532;testall 517 |
| 19 | qjs REPL | qjs.c:main 314;REPL 内嵌字节码 524;loader 477;quickjs-libc.c:js_module_loader 684 |
| 20 | 版本节奏 | Changelog:1/21/29/49(2026-06-04、2025-09-13、2025-04-26、2024-01-13) |
