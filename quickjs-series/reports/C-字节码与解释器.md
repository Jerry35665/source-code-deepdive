# C 篇：QuickJS 字节码格式与解释器（JS_CallInternal）

> 系列：QuickJS 源码深读 · 第五季第 3 章
> 仓库：bellard/quickjs，commit `04be246`（"run-test262: when updating errors, sort them so that it gives the same result with several threads"）
> 所有行号均以该 commit 实测核对；`quickjs.c` 约 61424 行，`quickjs-opcode.h` 366 行。

承接 B 篇：解析器直出字节码，经 `resolve_variables`（quickjs.c:34187）→ `resolve_labels`（:34796）→ `compute_stack_size`（:35753）三趟正规化后装入 `JSFunctionBytecode`（:685-724）。本篇进入运行时：字节码在磁盘/内存里长什么样、`JS_CallInternal`（:17746，到 :20711 结束，约 3000 行主函数）如何解释它。

---

## 1. 全景：一次函数调用的字节码执行旅程

```
JS_Call(ctx, f, this, argc, argv)                    quickjs.c:20717
   │  (JS_CALL_FLAG_COPY_ARGV)
   ▼
JS_CallInternal(caller_ctx, f, this, new_target, argc, argv, flags)   :17746
   │
   ├─ func_obj 不是对象 ──► "not a function"          :17789-17821
   ├─ func_obj 是 JS_TAG_INT 指针(生成器/async 恢复) ──► 取 JSAsyncFunctionState
   │      直接复用堆上已保存的帧 sf, goto restart/exception          :17790-17810
   ├─ class_id != BYTECODE_FUNCTION ──► 走 C 函数/生成器/async 的
   │      class call 回调(它们最终又递归回 JS_CallInternal)          :17816-17825
   │
   ├─ 计算 alloca_size = (arg补齐 + var_count + stack_size)*sizeof(JSValue)
   │                    + var_ref_count*sizeof(JSVarRef*)             :17834-17836
   ├─ js_check_stack_overflow(rt, alloca_size)? ──► StackOverflow     :17837-17838
   │
   ├─ local_buf = alloca(...)        ◄─ 一块 alloca,四段复用        :17846
   │      [ arg_buf 补齐区 ][ var_buf ][ stack_buf ][ var_refs[] ]
   │      :17849        :17856      :17863        :17864
   ├─ sf 入栈: rt->current_stack_frame 链                            :17869-17870
   └─ pc = b->byte_code_buf; 进入 dispatch 主循环  restart:          :17868-17878
          for(;;) { SWITCH(pc) { CASE(OP_xxx): ... BREAK; } }        :17777/:17874
          │
          ├─ OP_get_loc0 等: 直取 var_buf[i], *sp++                  :18589
          ├─ OP_add/mul: int 快路径, 溢出转 double                   :19696/:19830
          ├─ OP_call: call_argv=sp-argc; sf->cur_pc=pc;
          │      ret=JS_CallInternal(...)   ◄─ C 递归,帧即 C 栈帧    :18189-18192
          │      尾调用 OP_tail_call 直接 goto done(复用本帧语义)     :18195-18196
          ├─ OP_yield/OP_await: ret=FUNC_RET_*, goto done_generator
          │      帧指针保存在堆上 JSAsyncFunctionState, 本层 C 帧弹出 :20592-20607
          │
          ├─ 异常: goto exception(:20662)
          │      从 sp 向栈底扫描 JS_TAG_CATCH_OFFSET 哨兵值,
          │      找到则弹异常值 goto restart;没找到则继续回退         :20670-20688
          │
          └─ done: close_var_refs()(栈变量值拷进 JSVarRef)          :20698-20703
                 free 局部/栈值, rt->current_stack_frame 弹链, return :20704-20710
```

关键认知：QuickJS 的"JS 栈帧"不是独立的运行时数据结构堆，而是 **C 栈上的一块 alloca**（:17846）；嵌套调用就是 C 递归调用 `JS_CallInternal`。`JSStackFrame`（:407-420）只是随 C 栈帧存在的链表节点 + 指针组。

---

## 2. 操作码体系：一个 X-macro，三种展开

### 2.1 三用途

`quickjs-opcode.h` 用两条宏 `DEF(id, size, n_pop, n_push, fmt)`（正式操作码）与 `def(...)`（临时操作码，小写）驱动同一份表（quickjs-opcode.h:59-66），展开出：

1. **枚举**：`enum OPCodeEnum`，quickjs.c:1124-1144。正式操作码枚举到 `OP_COUNT`（:1132）；临时操作码从 `OP_TEMP_START = OP_nop + 1`（:1134）起，**故意与 SHORT_OPCODES 的编号区间重叠**（:1133 注释 "temporary opcodes : overlap with the short opcodes"），因为临时码只存在于 pass1/pass2 的中间产物，最终字节码里绝不会出现。
2. **格式枚举**：`FMT(none) ... FMT(label_u16)` 共 28 种（quickjs-opcode.h:27-56），决定操作数编码宽度。
3. **元信息表**：`opcode_info[]`，quickjs.c:22164-22174，每项是 `JSOpCode{ size; n_pop; n_push; fmt; }`（:22152-22162）。读端/写端/栈深计算都靠它逐指令游走：`short_opcode_info(op)`（:22181-22183）对 `op >= OP_TEMP_START` 的码把索引平移 `OP_TEMP_END - OP_TEMP_START`，从而命中重叠区间里的 SHORT_OPCODES 描述。

格式本身即文档：每个 DEF 的注释写明栈语义，如 `DEF(nip, 1, 2, 1, none) /* a b -> b */`（quickjs-opcode.h:83）、`DEF(insert2, 1, 2, 3, none) /* obj a -> a obj a */`（:89）。这正是一门**栈机**语言：绝大多数指令只动 `sp`，没有寄存器编号。

### 2.2 操作码规模

实测（commit 04be246）：正式 `DEF` 178 条（含 `OP_invalid` :65 与收尾 `OP_nop` :260），临时 `def` 19 条（:264-287），`SHORT_OPCODES` 区 `DEF` 66 条（:289-362）。分派表按 256 项建（quickjs.c:17767），越界一律 `&&case_default`（:17775），运行期落到 `OP_invalid/DEFAULT` 时报 "invalid opcode"（:20655-20659）。

### 2.3 SHORT_OPCODES：字节省到底

`#define SHORT_OPCODES 1`（quickjs.c:51）。三档压缩（quickjs-opcode.h:289-362）：

- **常量**：`push_minus1/push_0..push_7` 各 1 字节（:290-298）；`push_i8` 2 字节、`push_i16` 3 字节（:299-300）；`push_const8`/`fclosure8` 用 1 字节常量池索引（:301-302）。
- **局部变量**：`get_loc8/put_loc8/set_loc8` 2 字节（:305-307），`get_loc0..3` 等 **1 字节零操作数**（:309-344），连 `get_var_ref0..3` 都有（:333-344）。
- **跳转**：`if_false8/if_true8/goto8` 2 字节、`goto16` 3 字节（:348-351）；调用 `call0..call3` 1 字节（:353-356）。

对应解释器侧：`OP_push_0..push_7` 直接 `opcode - OP_push_0` 当立即数（quickjs.c:17892-17902）；`OP_get_loc0..3` 单行展开为 `*sp++ = JS_DupValue(ctx, var_buf[0..3])`（:18589-18600）。压缩的**选择**发生在 pass3 `resolve_labels`：跳转距离落进 int8 就降为 `goto8`（quickjs.c:35075-35081），`OP_goto` 落进 int16 降为 `goto16`（:35082-35088），正向未定标签则预留小槽位再回填重定位（:35053-35072）。而 `put_short_code()` 在 pass2 就把 `OP_get_loc/get_arg/...` 降为 8 位或 0 位形式（`resolve_labels` 序言里给 this/new.target 等初始化赋值处大量使用，:34837/:34859）。

### 2.4 quickjs-atom.h 的角色

`OP_FMT_atom*` 格式里的操作数是 **JSAtom（32 位整数索引）**，不是字符串。atom 表本身由 `quickjs-atom.h:26-283` 的 X-macro 定义：前 57 个是语言关键字（:29-76，注释 "first atoms are considered as keywords in the parser"），其后是引擎内置的属性名/类名/私有符号（如 `Symbol_iterator` :270、`<brand>` :267）。序列化时字节码里的 atom 被替换成动态 atom 表索引：写端 `bc_atom_to_idx`（quickjs.c:37740-37743），读端 `JS_ReadFunctionBytecode` 扫描每条 atom 格式指令、`bc_idx_to_atom` 换回 atom 并 `put_u32` 原地回填（:38643-38662）。

---

## 3. JSFunctionBytecode 的内存/二进制布局

### 3.1 结构体（quickjs.c:685-724）

```
JSGCObjectHeader header;   /* 必须在首, GC 对象 */          :686
uint8_t js_mode;           /* strict/async 位 */            :687
...11 个位域(func_kind 2bit, has_debug, read_only_bytecode...) :688-701
uint8_t *byte_code_buf; int byte_code_len;                  :702-703
JSAtom func_name;                                           :704
JSBytecodeVarDef *vardefs;   /* args+vars, 自指针 */        :705
JSClosureVar *closure_var;   /* 自指针 */                    :706
uint16_t arg_count/var_count/defined_arg_count/stack_size/var_ref_count; :707-711
JSContext *realm;                                           :712
JSValue *cpool; int cpool_count;   /* 常量池, 自指针 */      :713-714
struct { JSAtom filename; int source_len, pc2line_len;
         uint8_t *pc2line_buf; char *source; } debug;       :716-723
```

`JSBytecodeVarDef`（:654-670）是压到 16 位索引的紧凑版 `JSVarDef`：`var_name/scope_next/var_kind/is_captured/var_ref_idx`（:669），其中 `var_ref_idx` 指向帧内 `var_refs[]` 槽位（:665-668 注释）。

### 3.2 变长 struct + 自指针

`js_create_function`（:36024）三趟 pass 后一次性分配整个函数对象（:36135-36142）：按 `strip_debug` 决定是否带 debug 尾巴（:36103-36110），布局顺序为 `JSFunctionBytecode 本体 → cpool → vardefs → closure_var → byte_code`，全部用 `(uint8_t*)b + offset` 自指针（:36140/:36150/:36195/:36242）。源码注释自嘲 debug 信息应挪到尾部省内存（:36207-36209），但未做。pc2line 是差分压缩表：编码常量 `PC2LINE_BASE=-1, PC2LINE_RANGE=5`（:673-676），解码在 `find_line_num`（:7435）。

### 3.3 序列化：BC_VERSION、字节序与对齐

- 版本号 `#define BC_VERSION 5`（quickjs.c:37505），读端在 `JS_ReadObjectAtoms` 校验（:39431-39435），不匹配直接 SyntaxError。
- 写端 `JS_WriteFunctionBytecode`（:37717-37761）：把每条 atom 格式指令的 atom 换成索引，**大端机**上先 `bc_byte_swap` 再落盘（:37751-37752）。
- `bc_byte_swap`（:37657-37715）按 fmt 逐指令游走：u16 类换 2 字节，i32/u32/const/label/atom 类换 4 字节，`atom_u16` 等复合格式拆成 4+2（:38688-38692），`atom_label_u16` 则 4+4+2 三段换——**长度与对齐语义全部由 opcode 表驱动**，读端 `JS_ReadFunctionBytecode` 同样逐指令扫描回填 atom（:38615-38671）。
- 读端 `JS_ReadFunctionTag`（:38744）先读 flags16+js_mode+counts（:38758-38795，count 全部用 LEB128），再按与 `js_create_function` 完全相同的偏移公式算 `function_size`（:38797-38811），一次 `js_mallocz` 复刻内存布局（:38816-38829）；随后依次读 vardefs（:38845-38869）、closure_var（:38870-38892）、字节码（:38893-38898）、debug 的 pc2line/source（:38899-38927）。`qjsc` 预编译产物之所以能直接 mmap 使用，靠的正是这份布局镜像。

---

## 4. 帧布局专节：一块 alloca，四段复用

### 4.1 内存图（quickjs.c:17834-17868）

```
alloca_size = sizeof(JSValue)*(arg_allocated_size + var_count + stack_size)
            + sizeof(JSVarRef*) * var_ref_count          :17834-17836

local_buf ▼                                              :17846
┌─────────────────────────┬──────────────────┬────────────────────┬──────────────────┐
│ arg_buf (仅当需要补齐)   │ var_buf          │ stack_buf          │ var_refs[]       │
│ arg_allocated_size 项    │ var_count 项     │ stack_size 项      │ var_ref_count 项 │
│ 缺参补 JS_UNDEFINED      │ 全部初始化为      │ sp 的活动窗口      │ 全 NULL 初始化   │
│ :17847-17855            │ JS_UNDEFINED     │ :17863, sp=:17867  │ :17864-17866     │
└─────────────────────────┴──────────────────┴────────────────────┴──────────────────┘
     :17849-17853            :17860-17861
```

四段各有讲究：

1. **arg_buf**：调用方传的 `argv` 若长度足够（`argc >= b->arg_count`）就直接 **零拷贝借用调用方的数组**（`arg_buf = argv` :17841）；只有参数不足或带 `JS_CALL_FLAG_COPY_ARGV` 时才在 alloca 里补齐并 `JS_DupValue`（:17828-17855）。API 入口 `JS_Call` 恒带 COPY_ARGV（:20717-20722），内部 `OP_call` 则不带（:18191），省一次拷贝。
2. **var_buf**：`var_count` 个局部变量，全部置 `JS_UNDEFINED`（:17860-17861）；`this`、`arguments`、`new.target`、home_object 等特殊槽也是普通局部变量，由 pass3 生成的序言码在运行期填入（:34833-34896）。
3. **stack_buf**：表达式求值栈，深度上界就是 pass3 算出的 `b->stack_size`（:36201）。**解释器运行期没有逐指令的 push 溢出检查**——正确性完全由 `compute_stack_size` 的静态深度保证；运行期只查一层：`js_check_stack_overflow`（:17837）看 **C 栈**（`__builtin_frame_address` 对比 `rt->stack_limit`，:2053-2063），`rt->stack_limit = stack_top - stack_size`（:2841-2846）。上限 `JS_STACK_SIZE_MAX = 65534`（:211）在编译期兜底。
4. **var_refs[]**：`var_ref_count` 个 `JSVarRef*` 槽位，见第 5 节。

`JSStackFrame sf_s` 在 C 栈上（:17754），只存链表指针、cur_func、四段指针、cur_pc（:407-420），挂在 `rt->current_stack_frame` 链上（:17869-17870）。每条会回调 JS 的指令前都要 `sf->cur_pc = pc`（如 :18190/:18226/:18254），供异常回溯与 `JS_GetActiveFunction` 观察到正确位置。

### 4.2 生成器/async 的帧则在堆上

`JSAsyncFunctionState` 尾部跟同一份四段布局（:784-795，注释 "arg_buf, var_buf, stack_buf and var_refs follow"），`async_func_init` 用同一公式分配（:20907-20927）。`JS_CallInternal` 开头识别 `JS_CALL_FLAG_GENERATOR` 分支（:17790-17810）：func_obj 伪装成 `JS_MKPTR(JS_TAG_INT, s)`（:20967-20969），取回堆上帧、把 `rt->current_stack_frame` 重新接上后 `goto restart`——**C 栈释放了，JS 帧还活着**，这是 async 能"暂停"的全部秘密（详见第 7 节）。

---

## 5. 闭包 var_ref 专节：栈变量何时上堆

### 5.1 JSVarRef 的双形态（quickjs.c:450-464)

```c
typedef struct JSVarRef {
    JSGCObjectHeader header;
    uint8_t is_detached;
    ...
    JSValue *pvalue;   /* 指向栈上 var_buf[i] 或自身 value */
    union {
        JSValue value;                  /* detached: 值搬进自己体内 */
        struct { uint16_t var_ref_idx; JSStackFrame *stack_frame; };
    };
} JSVarRef;
```

- **attached 态**（`is_detached=FALSE`）：`pvalue` 指向某个活动帧的 `var_buf[i]`/`arg_buf[i]`（:17052）。读 `OP_get_var_ref` 即 `*var_refs[idx]->pvalue`（:18633）。
- **detached 态**（`is_detached=TRUE`）：值拷进 `var_ref->value`，`pvalue = &var_ref->value`（:17527-17530）。

### 5.2 时机一：closure 创建时（函数对象诞生）

`js_closure2`（:17262-17339）为函数对象的 `u.func.var_refs[]` 逐个绑定 `b->closure_var[i]`：内层局部变量走 `get_var_ref(ctx, sf, cv->var_idx, ...)`（:17315/:17319），后者按 `JSBytecodeVarDef.var_ref_idx` **惰性创建** JSVarRef 并指向当前帧（:17029-17052），已有则 `ref_count++` 复用（:17021-17026）。注意：**此刻栈变量并没有搬走**，JSVarRef 只是"指向栈上"的指针；被捕获的变量仍以原速读写（`OP_get_loc` 走 var_buf，捕获与否不影响本函数内访问）。B 篇提到的 `is_captured` 位与 `capture_var`（:32907）在编译期决定分配 `var_ref_idx`。

### 5.3 时机二：帧退出时（detach）

`JS_CallInternal` 的 `done:` 标签：只要 `b->var_ref_count != 0` 就 `close_var_refs(rt, b, sf)`（:20700-20703），对每个已创建的 var_ref 执行 `var_ref->value = JS_DupValue(*pvalue); pvalue = &var_ref->value; is_detached = TRUE`（:17527-17530）——**栈内存随 alloca 消失前，把值抄进堆上的 JSVarRef**。此后外部闭包照常通过 `*pvalue` 读写，无感知。

### 5.4 提前 detach：OP_close_loc

`let/const` 块作用域退出（循环每轮创建新绑定）走 `OP_close_loc` → `close_lexical_var`（:17545-17557），在**块结束时**就 detach 并把槽位清 NULL，下一轮迭代再建新 var_ref——这是 `for (let i...)` 每轮独立绑定的运行时机制。

### 5.5 活性与 GC 标记

- 引用计数与 GC 并存：`free_var_ref`（:6164-6184）`ref_count--` 归零时，attached 态要从 `sf->var_refs[idx]` 反向摘除自己，detached 态释放 `value`。
- 标记阶段 `mark_children`：`JS_GC_OBJ_TYPE_VAR_REF` 在 detached 时标记 `*pvalue`（:6628-6629）；attached 时只标记**宿主 JSStackFrame**（async 堆帧，:6630-6636），栈上的值由 `JS_GC_OBJ_TYPE_ASYNC_FUNCTION` 分支统一扫 `arg_buf..cur_sp`（:6654-6655），并注明运行中的函数不会成为可回收环（:6650-6653 注释）。
- async 特例：attached var_ref 若指向 async 堆帧，创建时要 `js_rc(async_func)->ref_count++`（:17040-17051），防 GC 期间堆帧被独立回收（长注释解释了为何不能在销毁时 close）。

---

## 6. 异常与 finally 专节：CATCH_OFFSET 栈值扫描

### 6.1 异常值的表示

QuickJS 只有一个 `rt->current_exception`（JS_EXCEPTION 只是信号值）。try/catch 编译成：`OP_catch label`（quickjs-opcode.h:181）执行时把**重定位后的目标 pc 偏移**压栈为哨兵：

```c
CASE(OP_catch):
    diff = get_u32(pc);
    sp[0] = JS_NewCatchOffset(ctx, pc + diff - b->byte_code_buf);   :18926
    sp++;
```

哨兵是一个特殊 tag 的 JSValue（`JS_TAG_CATCH_OFFSET`），B 篇在 :18922 亦提及。`for...of` 也用 `JS_NewCatchOffset(ctx, 0)` 的 **0 值哨兵**标记"迭代器协议在栈上，异常时要 close"（:18975/:18998）。

### 6.2 抛出与回退

`OP_throw` 把栈顶弹给 `JS_Throw` 后 `goto exception`（:18328-18330）。`exception:` 标签（:20662）做三件事：

1. 需要的话补 backtrace（:20663-20669）；
2. **栈扫描**：从 `sp` 向 `stack_buf` 逐个弹值并 `JS_FreeValue`，遇到 `JS_TAG_CATCH_OFFSET`：偏移非 0 则把 `current_exception` 压回栈顶、`pc = byte_code_buf + pos`、`goto restart` 进入 catch 块（:20670-20687）；偏移为 0 则调用 `JS_IteratorClose(..., TRUE)` 关闭迭代器后继续向外扫（:20676-20681）；
3. 扫到栈底仍无 handler：`ret_val = JS_EXCEPTION` 返回给上一帧（:20690），上一帧的 call 点 `goto exception` 继续自己的扫描——**多帧回退 = C 递归自然展开 + 每帧扫描**。这就是"无 unwind 表的零成本异常"：正常路径零开销，异常路径 O(帧内栈深)。

`rt->current_exception_is_uncatchable`（模块化 top-level await 场景）可跳过整个扫描（:20670）。

### 6.3 finally 的 gosub/ret：一次受控的栈上跳转

finally 不内联复制，而是靠两条指令模拟"子例程"：

```c
CASE(OP_gosub):                                  :18931-18940
    diff = get_u32(pc);
    /* XXX: should have a different tag to avoid security flaw */
    sp[0] = JS_NewInt32(ctx, pc + 4 - b->byte_code_buf);   /* 返回地址压栈 */
    sp++;
    pc += diff;                                  /* 跳进 finally */
CASE(OP_ret):                                    :18941-18957
    op1 = sp[-1];
    if (tag != JS_TAG_INT) goto ret_fail;        /* 只认 INT */
    pos = JS_VALUE_GET_INT(op1);
    if (pos >= b->byte_code_len) goto ret_fail;
    sp--; pc = b->byte_code_buf + pos;           /* 跳回 gosub 之下 */
```

正确性论证：
- **正常路径**：`gosub L` 压 INT 返回地址 → finally 体 → `OP_ret` 精确回位。
- **异常穿过 finally**：异常扫描把 INT 返回地址当普通值释放（不是 CATCH_OFFSET，不会被误当 handler），但 finally 自己有一条 `OP_catch`（编译器为带 finally 的 try 生成的内部 catch），所以 finally 体得以带着异常先执行，再由 `OP_throw` 重抛继续向外扫。`compute_stack_size` 对 `OP_gosub` 按 `stack_len + 1` 探索（:35863-35867），保证返回地址占的槽位计入深度。
- **return/break 穿过 finally**：编译器用 `OP_gosub` + 恢复后重新 `OP_return/goto` 的方式编排（B 篇的 emit 侧），`ret_fail`（:18950-18952）把"ret 遇到非 INT"防御成 InternalError，源码注释里那句 `XXX: should have a different tag`（:18935）是 Bellard 自留的安全提示：INT tag 理论上可被用户栈值伪造，只是 `pos >= byte_code_len` 的界检查（:18949）兜住了乱跳。
- pass2 还会顺带删掉空 finally 的 gosub：`code_match(&cc, ls->pos, OP_ret, -1)` 命中即整个 `OP_gosub` 消失（:34304-34319）。

### 6.4 顺手的两条清理指令

`OP_nip_catch`（:19026-19042）：`catch_offset ... ret_val -> ret_val`，从栈顶向下扫到哨兵为止清掉中间残留（eval/apply_eval 用）。`OP_iterator_close`（:19013-19025）先 `sp--` 弹掉 catch_offset "避免被异常捕获"再清理 next 方法——迭代器协议在栈上的三方（iter_obj/next/catch_offset）布局贯穿 for-of 全程。

---

## 7. async/生成器专节：状态机与帧的保存/恢复

### 7.1 两类对象，一套机制

`func_kind` 决定闭包对象类别（func_kind_to_class_id，:17362-17367）：NORMAL→BYTECODE_FUNCTION、GENERATOR→GENERATOR_FUNCTION、ASYNC→ASYNC_FUNCTION、复合→ASYNC_GENERATOR_FUNCTION。生成器对象再包一层 `JSGeneratorData`（js_generator_function_call :21159-21192）；纯 async 函数则直接由 `JSAsyncFunctionState` 驱动（js_async_function_call :21319-21341）。

### 7.2 暂停点：一条指令返回一个 int

解释器侧的暂停指令惊人地薄（:20592-20607）：

```c
CASE(OP_await):        ret_val = JS_NewInt32(ctx, FUNC_RET_AWAIT);        goto done_generator;
CASE(OP_yield):        ret_val = JS_NewInt32(ctx, FUNC_RET_YIELD);        goto done_generator;
CASE(OP_yield_star):   ret_val = JS_NewInt32(ctx, FUNC_RET_YIELD_STAR);   goto done_generator;
CASE(OP_return_async): ret_val = JS_UNDEFINED;                            goto done_generator;
CASE(OP_initial_yield):ret_val = JS_NewInt32(ctx, FUNC_RET_INITIAL_YIELD);goto done_generator;
```

`FUNC_RET_*` 是 0..3 的枚举（:17735-17739）。`done_generator`（:20694-20697）只做两件事：`sf->cur_pc = pc; sf->cur_sp = sp`——**把解释器位置和栈顶存回堆帧**——然后恢复 `current_stack_frame` 链并 return。注意注释（:20691-20693）：normal 函数绝不会走到 done_generator，因为"局部变量由调用者释放"的前提在生成器场景不成立。

`async_func_resume`（:20951-20987）把 `JS_MKPTR(JS_TAG_INT, s)` 传回 `JS_CallInternal` 触发 :17790 的重入分支：取回 `sf->cur_sp`（:17802）、置 `cur_sp = NULL` 表示"运行中"（:17803）、按 `s->throw_flag` 决定 `goto exception` 还是 `restart`（:17807-17810）——reject 重入时异常值已由 resolve 函数塞进 `rt->current_exception`（:21308-21314）。返回值若为 JS_UNDEFINED 表示真正执行完，此时 `is_completed=TRUE`、`close_var_refs`、释放帧内容（:20973-20984）。

### 7.3 await 的另一半：promise 接线

`js_async_function_resume`（:21238-21291）从 `s->frame.cur_sp[-1]` 取出被 await 的值（:21263），包成 promise，创建一对 resolve/reject 函数对象（`js_async_function_resolve_create` :21215-21236，它们 `ref_count++` 持有 `JSAsyncFunctionState`），`perform_promise_then` 挂回（:21282-21284）。当 job 派发 resolve 时，`js_async_function_resolve_call`（:21293-21317）把实参写进 `cur_sp[-1]`（await 表达式的值位）或 `JS_Throw` 后重入。async 函数首次调用即建 promise 并 `async_func_resume` 跑到第一个 await（:21330-21336）。

### 7.4 job 队列（简）

`promise_reaction_job`（:53386-53426）是微任务本体：调 handler（或直通），结果/异常再喂给下游 resolve/reject（:53408-53419，undefined 回调是 async await 的免分配优化，:53414-53416 注释）。队列是 `rt->job_list` 链表（`JS_EnqueueJob2` :2263-2285，`JS_ExecutePendingJob` :2303 逐个弹出执行）。宿主通过反复调 `JS_ExecutePendingJob` 驱动（qjs.c 事件循环）。

---

## 8. 调用分派与数值快路径补充

### 8.1 调用指令族

- `OP_call/OP_tail_call`：`call_argv = sp - call_argc`，被调方实参**直接躺在调用方表达式栈顶**（:18189-18192）。参数够时被调方零拷贝引用（:17828-17831），返回后调用方统一 `JS_FreeValue` 再把返回值压栈（:18197-18200）。
- `OP_call_method`：栈上多一个 this（:18227）。`OP_call_constructor`：走 `JS_CallConstructorInternal`（:18209）。
- **尾调用**：`resolve_labels` 在 pass3 检测 `OP_call 后紧跟 OP_return` 的模式，改写成 `OP_tail_call` 并吞掉死代码（:34941-34957）。运行期 `OP_tail_call` 拿到返回值后 `goto done`（:18195-18196）——因为外层本就只剩 return，效果等价于调用方帧提前收摊，C 栈深度不再增长。
- 非 bytecode 函数（native/bound/proxy）在入口 :17816-17825 转 class call 回调；native 的 `js_call_c_function` 自己再管异常与参数转换。

### 8.2 数值运算：int 快路径 + 溢出转 double

`OP_add`（:19696-19730）：双 int 时用 `int64_t` 做和，`(int)r != r` 即溢出转 `__JS_NewFloat64`（:19700-19704）；任一 double 则直接浮点加；双字符串连接；其余落 `add_slow_case`（ToPrimitive 全流程）。`OP_mul`（:19830-19880）：`int64` 乘积溢出转 double，且专门处理 `-0` 结果（`r==0 && (v1|v2)<0`，:19843-19847）。JSValue 的 NaN-boxing/64 位布局（B 篇/首篇）让这两条分支大多数时候只要 tag 比较。

### 8.3 属性访问快路径

`GET_FIELD_INLINE` 宏（:19107）为 `OP_get_field/get_field2/get_length` 生成内联快路径：shape 命中 `find_own_property` 直取 `p->prop[prs->value.getter_setter...]`；`OP_get_array_el` 的 `GET_ARRAY_EL_INLINE`（:19434-19441）对"对象+int 下标+Array 类+越界检查"四连后直读 `p->u.array.u.values[idx]`（:19454-19460），慢路径才走 `JS_GetPropertyValue`。`OP_define_field`（:19269-19280）直接 `JS_DefinePropertyValue(..., JS_PROP_C_W_E|JS_PROP_THROW)`。

---

## 9. 设计动机：栈机 + computed-goto，为什么没有 JIT

1. **栈机 vs 寄存器机**：QuickJS 是纯栈机——opcode 表的 `n_pop/n_push` 就是全部栈效应（:22157-22160 注释），没有 Lua/(Register VM) 那样的寄存器槽。代价是 `dup/insert/perm/rot` 家族的高频洗栈指令（quickjs-opcode.h:85-100，共 16 条）；收益是**编码短**（1 字节操作码 + 0~2 字节操作数为常态）、`compute_stack_size` 只需线性/广度优先推断而无需数据流分析（:35781 "breadth-first graph exploration"）、以及为 `eval` 生成的代码天然可栈式验证。Bellard 的取舍明显偏向"最小内存 + 最小编译器复杂度"。
2. **DIRECT_DISPATCH**：`#define DIRECT_DISPATCH 1`（:55，仅 Emscripten 降级为 switch :53）。`dispatch_table[256]` 存 label 地址，`SWITCH(pc)` 展开为 `goto *dispatch_table[opcode = *pc++]`（:17777）；`BREAK` 宏就是"跳下一条"（:17784），整个主循环没有 switch 边界检查。gcc/clang 下 computed-goto 把热点循环的分派从"比较跳转表"变成"一次间接寻址"，对解释器通常有 20-40% 提升。`OPCODE_ASM_LABEL`（:17778-17779）还预留了给 PROFILER 取函数内 label 地址的钩子。
3. **分派缓存与指令缓存局部性**：没有 superinstruction、没有 inline caching（属性快路径是**通用内联**而非按 site 特化），每个字节码对象只读共享（`read_only_bytecode` 位 :699 支持放 rom）。解释开销主要在：a) 每条指令的 `goto *` 与 `pc` 推进；b) 栈顶洗牌；c) refcount 的 Dup/Free（`OP_get_loc` 都要 `JS_DupValue`，:18536）。相比 V8 的 Ignition(寄存器机+accumulator+feedback vector)/Sparkplug/Maglev，QuickJS 少了所有分层执行设施——这是它 210KB wasm 体积与"慢一个数量级"的直接来源，但换来完全可预测的单层执行模型。
4. **为什么不做 JIT**：a) 目标平台常禁 W^X 或无 mmap 权限（嵌入式/ iOS）；b) JIT 内存成本与 QuickJS 的定位（CLI 脚本、游戏脚本、沙箱）冲突；c) Bellard 在 readme/访谈中的口径是"极小体积、确定性启动时间、无 JIT 合规问题"。社区分支（quickjs-ng）与部分商用 fork 有实验性 JIT，主线至 commit 04be246 仍无。
5. **异常机制不建 unwind 表**：栈扫描式 handler 查找（:20671-20688）把成本移到异常路径，正常路径零表查询，与"编译期只做三趟线性 pass"呼应。

---

## 10. FAQ（素材）

1. **QuickJS 的字节码是栈机还是寄存器机？** 栈机。opcode 元组 `(size, n_pop, n_push, fmt)` 完整描述栈效应（quickjs.c:22152-22162），无寄存器/累加器概念；表达式中间值全在 `stack_buf` 段（:17863）。
2. **为什么有 OP_get_loc 又有 OP_get_loc0..3、OP_get_loc8？** `SHORT_OPCODES`（quickjs.c:51）在 pass3 按索引大小/跳转距离降级编码（quickjs.c:35075-35088），1 字节 `get_loc0` 与 3 字节 `OP_get_loc` 语义相同（:18589 vs :18531），省的是最终字节码体积。
3. **临时操作码（OP_enter_scope/OP_label/OP_scope_get_var 等）为什么要与 short 码共享编号？** 它们只在 pass1/pass2 存在，pass2/pass3 后必然消失，与最终字节码编号重叠可让枚举总数 ≤256，正好塞进单字节与 256 项 dispatch 表（quickjs.c:1132-1144, :17767-17776）。
4. **栈溢出怎么防？** 双保险：编译期 `compute_stack_size` 保证 `stack_len_max <= JS_STACK_SIZE_MAX=65534`（:35820-35826, :211）；运行期每帧 `alloca` 前用 `__builtin_frame_address` 对比 `rt->stack_limit`（:2040-2063, :17837）。表达式栈本身**不逐指令查界**，信任编译期上界。
5. **catch 是表驱动还是栈扫描？** 栈扫描。`OP_catch` 压 `JS_TAG_CATCH_OFFSET` 哨兵入 JS 栈（:18926），异常时从 sp 向栈底扫（:20671-20688）；没有异常表，正常路径零开销。
6. **finally 是怎么实现的？** `OP_gosub` 压 INT 返回地址跳进 finally，`OP_ret` 校验 INT tag 与界后跳回（:18931-18957）；空 finally 在 pass2 即被删除（:34304-34319）；源码自注 INT tag 有理论伪造风险（:18935 XXX 注释）。
7. **闭包变量什么时候从栈搬到堆？** 两次：函数对象创建时 `js_closure2/get_var_ref` 建立指向栈的 var_ref（:17297-17332, :16997-17054）；帧退出时 `close_var_refs` 把值抄进 var_ref 自身（:20698-20703, :17521-17531）。let/const 块退出走 `OP_close_loc` 提前 detach（:18768-18775, :17545-17557）。
8. **async/await 怎么"暂停"解释器？** 暂停 = 保存 `cur_pc/cur_sp` 进堆上 `JSAsyncFunctionState` 后从解释器正常 return（:20694-20697）；恢复 = 用伪 func_obj 指针重入 `JS_CallInternal` 的 GENERATOR 分支（:17790-17810），C 栈深不随 await 次数增长。
9. **pc2line 是什么编码？** 差分 LEB128：`PC2LINE_BASE=-1, PC2LINE_RANGE=5`，一个字节可表达"pc 前进 N 条、行号 ±k"（:673-676），解码在 `find_line_num`（:7435）。
10. **字节码文件格式跨平台吗？** 有版本号 BC_VERSION=5（:37505）与 atom 索引化；多字节数字按小端写入，大端机读写端各做一次 `bc_byte_swap` 逐指令换序（:37657-37715, :38636-38637），因此字节码可在不同大小端机器间交换，但**不跨版本**。

## 11. 深挖方向

1. **`resolve_scope_var`（quickjs.c:32916-33486）**：B 篇 pass2 的核心——`OP_scope_get_var` 如何按作用域链距离分别改写成 `OP_get_loc/get_arg/get_var_ref/get_var/make_*_ref/put_var`，是理解"作用域→帧偏移→闭包"完整映射的最佳入口。
2. **`compute_stack_size` 的 catch/gosub 并行状态（:35753-35900+）**：`stack_level_tab` 与 `catch_pos_tab` 双表、`ss_check` 剪枝（:35782），以及 `OP_with_*` 需要手工加/减栈深的特例（:35868-35884），可对照验证"类型化栈效应推断"的最小实现。
3. **`build_backtrace` 与 async 栈**（:7660-7680 附近，`JS_GetFunctionBytecode(sf->cur_func)` :7672）：`rt->current_stack_frame` 链如何跨 await 断点拼接（async 重入时链的重建点在 :17805-17806）。
4. **异步生成器**：`JSAsyncGeneratorData`（:21345 起）在 async 状态机之外再叠一个请求队列（SUSPENDED_YIELD_STAR 等状态），是 QuickJS 里最复杂的状态机，适合作为第 8 节的续篇。
5. **`qjsc` 端到端**：`JS_WriteObject/JS_ReadObject` 往返 + `read_only_bytecode`/rom 数据路径（`s->is_rom_data` :38623-38628），可实测零拷贝加载对启动时间的影响。

---

## 写作要点速查表

| 主题 | 位置 | 内容 |
|---|---|---|
| 编译开关 | quickjs.c:51-55 | `OPTIMIZE=1, SHORT_OPCODES=1, DIRECT_DISPATCH=1`(Emscripten 除外) |
| 操作码枚举 | quickjs.c:1124-1144 | `enum OPCodeEnum`；临时码与 short 码重叠 :1133-1134 |
| opcode 元表 | quickjs.c:22152-22186 | `JSOpCode{size,n_pop,n_push,fmt}` + `short_opcode_info` 平移宏 |
| FMT 列表 | quickjs-opcode.h:27-56 | 28 种操作数格式 |
| SHORT_OPCODES | quickjs-opcode.h:289-362 | push_0..7/get_loc0..3/goto8/16/call0..3 等 66 条 |
| JSFunctionBytecode | quickjs.c:685-724 | 结构体；变长分配 js_create_function :36135-36244 |
| 序列化 | quickjs.c:37657-37761 / 38744-38927 | `bc_byte_swap` / `JS_ReadFunctionTag`(BC_VERSION :37505, 校验 :39431) |
| JSStackFrame | quickjs.c:407-420 | prev_frame/cur_func/arg_buf/var_buf/var_refs/cur_pc/cur_sp |
| 帧分配 | quickjs.c:17828-17871 | 四段 alloca；参数零拷贝借用 :17841 |
| dispatch | quickjs.c:17761-17785, 17873-17878 | computed-goto 表 + `SWITCH(pc)` |
| 调用族 | quickjs.c:18182-18238, 18363-18424 | call/tail_call/call_method/eval/apply_eval |
| 尾调用改写 | quickjs.c:34941-34957 | pass3 匹配 `call+return` |
| get/put_loc 族 | quickjs.c:18531-18624 | 含 8 位与 0 操作数变体 |
| var_ref 结构 | quickjs.c:450-464 | attached/detached 双态 |
| get_var_ref/closure | quickjs.c:16997-17054, 17262-17339 | 惰性建 ref；closure_var 绑定 |
| close_var_refs | quickjs.c:17521-17557 | 帧退出/块退出 detach |
| GC 标记 | quickjs.c:6615-6661 | VAR_REF/ASYNC_FUNCTION/FUNCTION_BYTECODE 三类 |
| goto/if 族 | quickjs.c:18822-18920 | 含 js_poll_interrupts 节流 :7877-7885 |
| catch/gosub/ret | quickjs.c:18922-18957 | CATCH_OFFSET 哨兵与 INT 返回地址 |
| 异常回退 | quickjs.c:20662-20689 | 栈扫描+restart；uncatchable :20670 |
| 收帧 | quickjs.c:20694-20710 | done_generator vs done(close_var_refs+free) |
| 暂停指令 | quickjs.c:20592-20607, 17735-17739 | FUNC_RET_* 四态 |
| async 驱动 | quickjs.c:20893-20987, 21238-21317 | init/resume/resolve_call |
| 生成器调用 | quickjs.c:21159-21192 | initial_yield 预跑 |
| 栈深计算 | quickjs.c:35753-35826 | 广度优先；上限 :211 |
| pc2line | quickjs.c:673-676, 34547-34559, 7435 | 编码常量/收集/解码 |
| promise job | quickjs.c:53386-53426, 2263-2330 | reaction_job 与 FIFO 队列 |
| 数值快路径 | quickjs.c:19696-19730, 19830-19880 | add/mul int 溢出转 double、-0 特判 |

（全文完，约 340 行）
