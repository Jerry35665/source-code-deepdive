# 第五系列 · 第 2 章：词法分析与解析器——递归下降直出字节码

> 调研对象：bellard/quickjs，commit `04be246`（shallow clone，VERSION 2025-04-26 系）。
> 行号均以该 commit 的仓库相对路径核对，主力文件 `quickjs.c`（约 6.1 万行）。
> 本章回答一个问题：**不建 AST，解析器如何把源码一步编译成字节码，并且还做对了 ES2023？**

---

## 1. 全景：源码 → Token → 直出字节码

### 1.1 流水线

```
JS_Eval / js_module_loader
        │
        ▼
__JS_EvalInternal (quickjs.c:37188)
  js_parse_init ........................ quickjs.c:37130  初始化 JSParseState（单 token 缓冲）
  skip_shebang ......................... quickjs.c:37202
  js_new_function_def .................. quickjs.c:37233  顶层 JSFunctionDef（eval/module 元信息）
        │
        ▼
js_parse_program (quickjs.c:37078)
  └─ js_parse_directives ............... quickjs.c:36327  "use strict" 识别
  └─ while(!TOK_EOF) js_parse_source_element ... quickjs.c:32034
        └─ js_parse_statement_or_decl ... quickjs.c:28901   语句分派 switch（~27 个 case，28952 起）
             └─ js_parse_expr .......... quickjs.c:28313     表达式阶梯入口
                  │  （next_token quickjs.c:22829 按需拉取下一个 token）
                  ▼
             emit_op / emit_u32 / emit_atom ... quickjs.c:23864/23847/23873
                  直接 append 到 fd->byte_code（DynBuf）——没有 AST，只有线性字节码
        │
        ▼
js_create_function (quickjs.c:36024)  —— 三趟"后处理 pass"（仍无树结构）
  ├─ pass 1: resolve_variables ........ quickjs.c:34187  OP_scope_* → get_loc/get_var_ref/get_var
  ├─ pass 2: resolve_labels ........... quickjs.c:34796  label 重定位 + 窥孔 + SHORT_OPCODES
  └─ pass 3: compute_stack_size ....... quickjs.c:35753  求最大栈深（兼做死代码核查）
        │
        ▼
JSFunctionBytecode (quickjs.c:685-724)  ← 字节码+常量池+vardefs+closure_var 打包在一块内存
  （模块则另经 js_resolve_module → js_evaluate_module）
```

### 1.2 与"AST 中间层"路线（V8）对照

| 维度 | QuickJS：直出字节码 | V8（Ignition 前）等：AST 中间层 |
|---|---|---|
| 中间表示 | 无树；只有线性 `byte_code` DynBuf + `JSFunctionDef` 里的变量/label 表 | 完整 AST（每节点一个对象/指针） |
| 内存峰值 | 仅一个 token（`JSParseState.token`，quickjs.c:22137）+ 字节码缓冲 | 整棵 AST 常驻解析完成前，大文件内存陡增 |
| 遍数 | 单遍解析 + 3 趟线性 pass | 解析 → AST → 字节码生成至少两遍遍历 |
| 复用 | AST 不能复用（本来就没有）；字节码可序列化（qjsc/BCReader，quickjs.c:38615） | AST 可做宏/工具复用，再 lowering |
| 优化空间 | 无法做基于树的深度优化，只有局部窥孔（见 §6） | 可在树上做内联/逃逸分析等 |
| 错误恢复 | 报错即停（见 §6.3） | 通常也有恢复策略（reparse/容错） |

QuickJS 的目标（内存小、启动快、代码量小，约 6 万行单文件）决定了"单遍直出"是最短路径。

---

## 2. 词法专节

### 2.1 Token 结构：一个 token，双 union 承载四种载荷

`JSToken`（quickjs.c:22111-22132）：

```c
typedef struct JSToken {
    int val;               /* TOK_* 枚举或单字符 ASCII 值 */
    const uint8_t *ptr;    /* position in the source */
    union {
        struct { JSValue str; int sep; } str;          /* 字符串/模板：sep 记引号或 '`'/'${' */
        struct { JSValue val; } num;                   /* 数字 */
        struct { JSAtom atom; BOOL has_escape; BOOL is_reserved; } ident; /* 标识符/关键字 */
        struct { JSValue body; JSValue flags; } regexp; /* 正则 body 与 flags */
    } u;
} JSToken;
```

要点：

- **没有独立的"下一个 token"缓冲**：`JSParseState` 只存当前 token（quickjs.c:22137）；回看靠 `s->last_ptr`（22139）与 `s->got_lf`（22138）。向前看用 `peek_token`（quickjs.c:23755）→ `simple_next_token`（23670）做**轻量重扫**（不建 atom、不改状态），或者 `js_parse_get_pos/js_parse_seek_token`（24745/24752）做**保存/回卷**。
- `TOK_*` 枚举（quickjs.c:21785-21880）：负值/特殊值从 `TOK_NUMBER=-128` 起；运算符多字 token（如 `TOK_SHL`、`TOK_ARROW`、`TOK_DOUBLE_QUESTION_MARK`）排在中间；**单字符 token 直接用其 ASCII 码**（`def_token: s->token.val = c`，quickjs.c:23256-23259）——这是"枚举与字符共用一个 int 空间"的省内存设计。

### 2.2 next_token：一个大 switch 的手写词法器

`next_token`（quickjs.c:22829-23269）核心结构：

- 开头先查 **栈溢出保护**（`js_check_stack_overflow`，22836）——递归下降解析器深度的第一道闸。
- 空白/注释统一 `goto redo` 重扫：`\r\n` 归一（22865-22874）、`//` 行注释（22909）、`/* */` 块注释中把换行记入 `got_lf` 供 ASI 用（22894-22900）。
- Annex B HTML 注释：`<!--`（23117-23120）与行首 `-->`（23091-23098）仅在 `allow_html_comments`（非模块，37263）时识别。
- 标识符：`a-z/A-Z/_/$` 手工列出（22953-22968），`#` 私有名（22982-23005），`\uXXXX` 转义标识符（22939-22951，置 `ident_has_escape`）。
- 数字：`js_atof` 带 `ATOD_ACCEPT_BIN_OCT|UNDERSCORES|SUFFIX` 等标志（23035-23038）；并拒绝 `10in` 这类数字后紧跟标识符（23042-23047）。严格模式禁前缀八进制在**词法层**就报错（23019-23024）。

### 2.3 关键字 atom 化：TOK 枚举与 atom 表"同序差一"映射

关键字不是独立 token 扫出来的，而是**标识符扫完后二次判别**。`parse_ident`（quickjs.c:22781-22826）把字符累积到栈上 128 字节缓冲再 `JS_NewAtomLen`（22820），然后 `update_token_ident`（quickjs.c:22739-22765）：

```c
if (s->token.u.ident.atom <= JS_ATOM_LAST_KEYWORD ||
    (s->token.u.ident.atom <= JS_ATOM_LAST_STRICT_KEYWORD &&
     (s->cur_func->js_mode & JS_MODE_STRICT)) || ...
    (s->token.u.ident.atom == JS_ATOM_await && (s->is_module || ...))) {
    if (s->token.u.ident.has_escape) {
        s->token.u.ident.is_reserved = TRUE;   /* \u69cool => 保留字带转义，禁止作关键字 */
        s->token.val = TOK_IDENT;
    } else {
        /* The keywords atoms are pre allocated */
        s->token.val = s->token.u.ident.atom - 1 + TOK_FIRST_KEYWORD;  /* 22762 */
    }
}
```

- 依赖 quickjs-atom.h 中**关键字 atom 与 TOK 枚举同序**（枚举处注释"same order as atoms"，quickjs.c:21830；`JS_ATOM_LAST_KEYWORD`/`JS_ATOM_LAST_STRICT_KEYWORD` 在 quickjs.c:1107-1108）。atom 是预分配小整数，所以判关键字是一次整数比较 + 一次减法。
- 上下文敏感关键字（`yield`/`await`/`let`/`static` 等）在此处按 `func_kind`、模块/严格模式现算（22744-22756）；进入新函数时还会用 `reparse_ident_token`（22769-22778）重判已缓存的 token。

### 2.4 `/` 的歧义：不在词法层消解，而在语法层"回退重扫"

**实测定位**：QuickJS **没有** `js_parse_correct_ident`；也没有词法级正则判定。词法器总是把 `/` 扫成 `/` 或 `/=`（quickjs.c:22881-22937），由解析器在"主表达式位置"反悔：

```c
/* js_parse_postfix_expr, quickjs.c:26878-26890 */
case TOK_DIV_ASSIGN:
    s->buf_ptr -= 2;
    goto parse_regexp;
case '/':
    s->buf_ptr--;
parse_regexp: {
    ...
    if (js_parse_regexp(s))            /* quickjs.c:22603 逐字符扫描正则体 */
        return -1;
    ret = emit_push_const(s, s->token.u.regexp.body, 0);
    str = s->ctx->compile_regexp(...); /* 编译期即构建 RegExp 对象进常量池 */
    ...
    emit_op(s, OP_regexp);             /* 26910：专用 opcode，免去运行期校验 */
```

因为调用点处于"前一个 token 已被消费、主表达式开头"的语法位置，天然满足"前文不可能有完整左操作数"的 JS 正则判定规则。辅助前瞻函数 `js_parse_skip_parens_token`（24800）中另有一套显式启发：`is_regexp_allowed(last_tok)`（quickjs.c:24760-24780）——数字、字符串、`)`、`]`、`}`、`++/--`、`this` 等之后不允许正则。`js_parse_regexp` 本体（22603-22696）只做 body/flags 提取与 `[...]` 字符类内的 `/` 容忍（22629-22635），**不验证正则语法**，真正的编译交给 `ctx->compile_regexp`（26893，libregexp）。

### 2.5 模板字符串：词法切片 + 语法层重组

- `js_parse_template_part`（quickjs.c:22398-22459）：扫 `` ` `` 或 ``${`` 之间的一段，`\r\n` 归一为 `\n`（22428-22432），产出 `TOK_TEMPLATE`，`u.str.sep` 记录结束符是 `` ` `` 还是 `${`。
- `js_parse_template`（quickjs.c:24491-24599）：循环"cooked 段 emit_push_const → 解析 `${}` 内表达式（24571）→ 回到 `js_parse_template_part`（24582）"，非 tag 场景最终生成 `OP_get_field2('concat') + OP_call_method`（24559-24560、24594）。tag 调用场景则构造 template object 与 raw 数组常量（24500-24518）。

### 2.6 ASI 自动分号：集中在一个函数 + 若干 got_lf 检查

**实现位置**：主入口 `js_parse_expect_semi`（quickjs.c:22378-22388）：

```c
if (s->token.val != ';') {
    /* automatic insertion of ';' */
    if (s->token.val == TOK_EOF || s->token.val == '}' || s->got_lf) {
        return 0;                       /* 规则 1+2+3 的并集 */
    }
    return js_parse_error(s, "expecting '%c'", ';');
}
```

ECMAScript 三规则与实现的对应：

| ASI 规则 | 实现位置 |
|---|---|
| 1. 遇到不能延续语句的 token（此处以 EOF/`}` 近似） | `js_parse_expect_semi`，quickjs.c:22382 |
| 2. 有行终结符分隔（受限产生式） | `s->got_lf`（next_token 于 22843 清零、22873/22899 置位；块注释也置位 22895） |
| 3. 受限产生式（restricted productions） | return：`s->token.val != ';' && != '}' && !s->got_lf` 才接表达式（quickjs.c:28971）；throw：换行直接报错（28990-28993）；后缀 `++/--` 在 `js_parse_postfix_expr` 中要求同行；`for` 头部不受 ASI |
| 附加：指令序言里 `"..."` 后是否可省分号 | `js_parse_directives` 内一大串 case + `got_lf`（quickjs.c:36347-36399） |

另外 `has_lf_in_range`（24786-24795）用 `memchr` 直接在源码区间找 `\n`，供箭头函数参数表 `no_line_terminator` 检查用——QuickJS 同时保留了"记号级 got_lf"与"源码级 memchr"两种判定。

---

## 3. 递归下降专节

### 3.1 表达式阶梯：函数链 + level 参数两级设计

表达式自上而下的调用链（均在 quickjs.c）：

```
js_parse_expr (28313) → js_parse_expr2 (28289, 逗号表达式, OP_drop 308/313)
  → js_parse_assign_expr (28283) → js_parse_assign_expr2 (27999)
     ├─ yield (28005) / 箭头函数 (28142-28177) / 解构赋值 (28178-28182) 先行短路
     └→ js_parse_cond_expr (27970, ?:)
         → js_parse_coalesce_expr (27942, ??)
            → js_parse_logical_and_or (27900, &&/||)
               → js_parse_expr_binary (27733, level 0..8 递归下降层)
                  level 0 → js_parse_unary (27593) → js_parse_postfix_expr (26832)
```

**二元不是用 precedence 表驱动，而是把优先级硬编码为 9 个 level**：`js_parse_expr_binary(s, level)` 对每个 level 用一个内层 switch 匹配该级的运算符（27770-27888）：level 1 = `* / %`、2 = `+ -`、3 = 移位、4 = 关系（含 `in`/`instanceof`，`in` 受 `PF_IN_ACCEPTED` 门控 27830-27835）、5 = 相等、6/7/8 = `& ^ |`。每级开头递归 `js_parse_expr_binary(s, level-1)`（27764），遇到本级运算符则 `emit_op(opcode)` 后继续循环（27889-27894）。这是一个"函数式阶梯 + level 内 switch"的混合体——介于"每级一个函数"与"precedence climbing"之间。

**逻辑短路/空值合并/三元是 label 驱动**：`&&` 编译为 `OP_dup; OP_if_false(l); OP_drop; <rhs>; l:`（27915-27921 一带）；`??` 用 `OP_is_undefined_or_null`（27954-27956）；三元用两个 label（27976-27993）。

### 3.2 关键字驱动 switch 的规模

`js_parse_statement_or_decl`（quickjs.c:28901-31360，**约 2460 行**）是全解析器最大单函数：标签语句处理（28911-28950）后进入 switch（28952），共 **27 个顶层 case**（`{`、return、throw、var/let/const、if、while、do、for、break、continue、switch、try、throw、function、class、debugger、with、`;` 等）。其子函数：

- `js_parse_var`（28515）、`js_parse_for_in_of`（28665，for-in/of 用 `OP_for_of_start` 等迭代器 opcode 展开）
- `js_parse_block`（28495）负责 push/pop scope + BlockEnv

`js_parse_postfix_expr`（26832-27500 附近，约 670 行）处理调用/成员/可选链/`new`/super/模板 tag，`FuncCallType` 枚举区分普通调用、`new`、`super(...)` 与模板（26824-26829 一带）。`js_parse_unary`（27593）覆盖 `delete`（独立函数 27500）、`typeof`、`void`、`+ - ~ !`、`++/--`、`await`。

### 3.3 箭头函数与解构：靠"跳读括号"做确定性判定

- 箭头：`js_parse_skip_parens_token(s, NULL, TRUE) == TOK_ARROW`（28142-28143）——用一个 256 字节状态栈手工跳过配对括号（24800-24916），期间记录 `SKIP_HAS_SEMI/ELLIPSIS/ASSIGNMENT` 位（24782-24784），既判箭头也预判"参数表里有没有默认值"。`async` 箭头则先 `peek_token` 快测（28152-28154），失败用 `js_parse_seek_token` 回卷（28168-28172）。
- 解构：`js_parse_destructuring_element`（26338，约 500 行）同时用于声明、赋值与参数；`(x, y) => x` 这类"括号内到底是参数表还是表达式"歧义，靠 skip 后的 `=`/`=>` 判定（28178-28183）。

### 3.4 类与异步

- `js_parse_class`（quickjs.c:25274）：类体强制严格模式（25290-25291 `fd->js_mode |= JS_MODE_STRICT`，结束后恢复）；私有字段/方法的 `#x` 由 `TOK_PRIVATE_NAME` 承载；类名以 `JS_VAR_DEF_CONST` 定义（25328）；默认构造器由 `js_parse_class_default_ctor`（25109）合成；字段初始化器进 `JS_ATOM_class_fields_init` 隐藏函数（25188-25197、25702 一带）。
- 异步：`async` 在 `update_token_ident`（22749-22756）、`js_parse_function_decl2`（36521-36527）与 `js_parse_assign_expr2`（28147-28172）三处按上下文判别；`await` 表达式经 `OP_await`，模块顶层 await 记 `fd->has_await`（37258、37277）。

---

## 4. 直出字节码专节

### 4.1 emit 机制：解析即落码

解析全程往 `s->cur_func->byte_code`（DynBuf）追加指令（quickjs.c:23864-23880）：

```c
static void emit_op(JSParseState *s, uint8_t val)
{
    JSFunctionDef *fd = s->cur_func;
    DynBuf *bc = &fd->byte_code;
    fd->last_opcode_pos = bc->size;   /* 记住最后一条 opcode 的位置 */
    dbuf_putc(bc, val);
}
static void emit_u32(JSParseState *s, uint32_t val) { dbuf_put_u32(...); }   /* 23847 */
static void emit_atom(JSParseState *s, JSAtom name) { ... JS_DupAtom ... }   /* 23873 */
```

- `fd->last_opcode_pos` 是**窥孔的钥匙**：`get_prev_opcode`（23809）、`set_object_name`（24918-24927）直接改写刚发出的指令（如把 `OP_set_name` 换形），`get_lvalue`（25933）读取上一条 `OP_scope_get_var` 的操作数来决定 lvalue 形态。这是"无 AST 也要做局部优化"的典型手法——**优化对象是尾指令而非树**。
- 行号信息不存表，而是按需发 `OP_line_num` 伪指令（`emit_source_pos`，23852-23862），最终被 `add_pc2line_info`（34547）压成 `pc2line` 差分表（JSFunctionBytecode.debug.pc2line_buf，quickjs.c:721）。
- 常量（字符串/数字/正则/子函数）进 `fd->cpool`（`cpool_add`，23961）。

### 4.2 label 补丁：LabelSlot + RelocEntry 单链表（不是双向链）

数据结构（quickjs.c:21914-21933）：

```c
typedef struct RelocEntry {
    struct RelocEntry *next;
    uint32_t addr;   /* address to patch */
    int size;        /* address size: 1, 2 or 4 bytes */
} RelocEntry;

typedef struct LabelSlot {
    int ref_count;
    int pos;    /* phase 1 address, -1 = not resolved */
    int pos2;   /* phase 2 address */
    int addr;   /* phase 3 address */
    RelocEntry *first_reloc;
} LabelSlot;
```

工作方式：

1. `new_label`（23893-23920）只在 `label_slots` 数组里占一个槽（`pos=-1`，ref_count=0），**不发指令**。
2. `emit_goto`（23944-23958）发 `OP_goto/OP_if_false/...` + `emit_u32(label 编号)`，`ref_count++`。label 编号作为操作数（而非地址）——**两遍式的设计：pass 1 里跳转目标是"槽号"**。
3. `emit_label`（23931-23941）发 `OP_label` 伪指令并记录 `pos`。
4. pass 2 `resolve_labels`（34796）把字节码整体搬到新缓冲：遇到跳转时若目标 `addr` 已知则直接写相对偏移；未定义则 `add_reloc`（34620-34629）挂到该 label 的 `first_reloc` 单链表；遇到 `OP_label` 时**回扫 reloc 链**逐个回填（34919-34937）。偏移是 `ls->addr - bc_out.size` 的相对地址，天然支持前向与后向。
5. 短跳转优化：4 字节偏移可缩为 `goto8/goto16/if_false8` 等 SHORT_OPCODES（35100 附近、`put_short_code` 34737）。
6. 死代码消除与窥孔都在这一趟：`OPTIMIZE`（quickjs.c:50，=1）+ `code_match` 模式匹配，见 §6.2。

### 4.3 异常处理：没有异常表，是"栈上的 catch 标记"

与常见"exception_range 表（try_pc 区间→handler_pc）"不同，QuickJS 的 try/catch **不在字节码元数据里建区间表**，而是：

- 解析期：`case TOK_TRY`（quickjs.c:29387-29502）先 `emit_goto(s, OP_catch, label_catch)`（29401）。`OP_catch` 运行期语义是把"catch 地址"作为一个特殊 JSValue **压栈**（quickjs.c:18922-18930）：

```c
CASE(OP_catch):
    diff = get_u32(pc);
    sp[0] = JS_NewCatchOffset(ctx, pc + diff - b->byte_code_buf);
    sp++; pc += 4;
```

  `JS_TAG_CATCH_OFFSET = 5`（quickjs.h:91）。异常抛出时解释器**沿栈向下扫描**第一个 CATCH_OFFSET 标记定位 handler（20674 处判断）。
- catch 体首条再挂 `OP_catch(label_catch2)`（29461）捕获 catch 块内新异常，执行完 finally 后 `OP_throw` 重抛（29487-29490）。
- finally 用 `OP_gosub`（压返回地址，18931-18940）+ `OP_ret`（18941-18957）实现，break/continue 穿越finally 由 BlockEnv.label_finally 驱动（21898）。
- 代价与收益：省掉异常表内存；代价是异常路径上要在栈里翻找标记（以及 `compute_stack_size` 里专门追踪 `catch_pos` 的复杂逻辑，35885-35933）。

---

## 5. 闭包解析专节

### 5.1 两级变量表示：解析期 scope 编码，pass 1 才落地

- 解析期发的是 `OP_scope_get_var/put_var/make_ref`（操作数 = atom + scope_level，如 29453-29455 的 `OP_scope_put_var`+atom+u16 scope_level）。scope 以 `push_scope/pop_scope`（24106、24130 一带）维护，`JSFunctionDef.scopes[]` 记 parent 链。
- pass 1 `resolve_variables`（34187）把 `OP_scope_*` 改写为具体形态：
  - 本函数内变量 → `OP_get_loc/put_loc/get_arg/...`（栈槽下标）；
  - 外层函数变量 → `OP_get_var_ref/put_var_ref`（closure_var 下标，u16）；
  - 全局 → `OP_get_var_undef/get_var/put_var`（quickjs.c:33269-33273 一处四合一转换）；
  - `with` 对象 → `OP_with_get_var` 族（`get_with_scope_opcode`，32762-32768）。

### 5.2 栈深度回溯：沿 parent 链逐层查

核心是 resolve_variables 内的**双循环回溯**（quickjs.c:33106-33183）：外层 `for (fd = s; fd->parent;)` 逐个上溯父 JSFunctionDef；内层先沿父函数的 scope 链查词法声明（33109-33131），再 `find_var`（24011-24019，倒序线性扫 `vars[]`）查 var/arg。找不到时的补充规则依次是：`arguments`（33147）、具名函数表达式自引用 `add_func_var`（33151-33154）、arguments 对象（33158-33179）、直接 eval 的 `_var_/_with_` 变量对象（33122-33129）。

### 5.3 outter scope 的 var ref：闭包表是"逐层中转"的

`get_closure_var`（quickjs.c:32736-32760）：

```c
if (fd != s->parent) {                 /* 目标函数不是直接父级 */
    var_idx = get_closure_var(ctx, s->parent, fd, ...);   /* 递归，让父级先加 */
    if (closure_type != JS_CLOSURE_GLOBAL_REF)
        closure_type = JS_CLOSURE_REF; /* 中间层用"引用的引用" */
}
for (i = 0; i < s->closure_var_count; i++)   /* 去重 */
    ...
return add_closure_var(ctx, s, closure_type, var_idx, var_name, ...);  /* 32694 */
```

即闭包变量按**函数层级逐级中转**：孙子函数引用爷爷的变量，会在儿子函数的 closure_var 里先插一条 `JS_CLOSURE_REF`。运行期这些下标变成 `JSVarRef` 间接层（`get_var_ref` 运行时实现 quickjs.c:16997；`OP_get_var_ref0..3` 快速版 18613-18616）——`JSVarRef.pvalue` 指向被捕获槽位，这就是第 03 章闭包/作用域的入口。被内层捕获的局部变量标记 `is_captured`（js_create_function 拷贝 vardefs 时携带，quickjs.c:36164），进入闭包槽。

### 5.4 函数编译：js_parse_function_decl2 的关键步骤

`js_parse_function_decl2`（quickjs.c:36500，约 560 行）：

- 函数头：`async`/`*` 判定（36521-36534）；名字保留字检查（36536-36562）；函数表达式按 Annex B 决定是否建 `var` 名与词法名双绑定（`create_func_var`/`lexical_func_idx`，36579-36616）。
- 参数：先 `js_parse_skip_parens_token` 探测 `SKIP_HAS_ASSIGNMENT` 判 `has_parameter_expressions`（36692-36697），有则单开参数作用域（36705-36709）；剩余参数发 `OP_rest`（36727/36765）；解构参数用匿参占位（36730-36735）；默认值走 label 跳转。
- 函数体是一个**新的 JSFunctionDef**（`js_new_function_def`，36618，挂进父 `child_list`），函数体本身在 `s->cur_func` 切换下继续"直出"到子 fd 的 byte_code；函数对象在 `js_create_function` 里递归创建并存进父函数 cpool（36073-36086）。

### 5.5 直接 eval 的特殊处理

- `__JS_EvalInternal` 以 `JS_EVAL_TYPE_DIRECT` 进入时：取出**当前函数**的 JSFunctionBytecode，继承 js_mode/super/new_target 等许可（quickjs.c:37206-37244），并用 `add_closure_variables`（37254）把外层闭包表复制进 eval 的 fd——所以 eval 里的变量查找能落到 `closure_var`（33189-33233 专门处理 eval 的 closure 查找）。
- eval 程序尾部会额外定义 `_var_`/`_arg_var_`/`_with_` "变量对象"（`add_eval_variables`，quickjs.c:33610-33640），非严格模式下未声明赋值落在 `_var_` 对象上。
- 模块解析没有独立 `js_parse_module`：模块 = `eval_type==JS_EVAL_TYPE_MODULE` 的 program，强制严格模式（37230），import/export 在 `js_parse_source_element` 分派（quickjs.c:32046-32054）给 `js_parse_export`（31699）/`js_parse_import`（31899），只记录导入/导出**表**，不产生字节码；`JS_DetectModule`（23792）用启发式猜模块。

---

## 6. 设计动机与取舍

### 6.1 为什么免 AST：内存目标与单遍

- 内存：`JSParseState` 仅持有一个 token；`JSFunctionDef` 里的中间表（label_slots、vars、scopes、cpool）都随函数体生成完即被 pass 消耗，最终只剩打包好的 `JSFunctionBytecode`（js_create_function 一次性 `js_mallocz`，quickjs.c:36135，bytecode/cpool/vardefs/closure_var 连续排布 36126-36133）。对比 AST：树节点分配量 O(源码 token 数)，QuickJS 只有 O(指令数) 且随即压缩。
- 单遍：语法规则全部落成"边解析边 emit"，解析完只余 3 趟线性 pass（36100-36118）。对 CLI/嵌入式冷启动场景，这把 compile time 压到最低。
- 复用难是代价：无法在树上做范围分析、内联决策；但 QuickJS 本来不做这些（见下）。

### 6.2 优化缺席？——如实说：有"窥孔"，无"优化器"

- **没有**数据流/常量传播/内联/基于 AST 的重写。`grep "fold"` 在 quickjs.c 里没有常量折叠器。
- **有**一个 `OPTIMIZE=1` 的窥孔 + 重定位混合 pass（`resolve_labels`，quickjs.c:34796），例子（35165-35230）：
  - `OP_push_i32(v); OP_drop` → 删除（35220-35226）；
  - `OP_push_i32(v); OP_neg` → `OP_push_i32(-v)`（35206-35219）；
  - `OP_push_0/false/true` + `OP_if_false/if_true` → 直接 `OP_goto` 或整段消去（"Optimize constant tests: if (0), if (1), if (!0)"，35227-35233 与 35165-35190）；
  - 跳转链折叠 `find_jump_target`（34661-34696）；
  - `SHORT_OPCODES`：`get_loc`/`put_loc`/`goto` 等按操作数大小换 8/16 位编码（put_short_code 34737、35100 附近 goto16）。
- 另一类是**解析期尾指令改写**：`set_object_name`（24918）改写 `OP_set_name`、`can_opt_put_ref_value`（32770）支持 `get_ref_value; put_ref_value` 合并。`OP_get_field2`+`OP_set_name` 这类"读改上一条指令"完全依赖线性落码顺序，是免 AST 的独有风格。
- **取舍论证**：窥孔只在 pass 2 一趟 O(n) 内做，模式有限但覆盖了解析器自身产生的常见冗余（引擎自己最清楚自己会发什么废码）；深度优化留给"解释器足够快 + 内存足够省"的整体目标，这与 QuickJS 面向嵌入、qjsc 预编译分发（BCReader 38615）的定位自洽。

### 6.3 错误恢复策略：报错即停

`js_parse_error_v`（quickjs.c:22330-22339）抛 SyntaxError 并 `build_backtrace` 记行列号，返回 -1；所有 `js_parse_*` 沿 `__exception` 一路返回 -1，`__JS_EvalInternal` 在 fail 处直接 `js_free_function_def` 释放半成品（37269-37273）。**没有错误恢复/继续解析**——单遍直出结构下"修复后继续"成本极高，而嵌入式场景一次只编一个脚本，报错即停是最经济的策略。

---

## 7. FAQ 素材

1. **Q: QuickJS 解析器有 AST 吗？** 没有。解析的同时把 opcode 写进 `fd->byte_code`（DynBuf），中间表示只有线性字节码 + 变量/label 表（quickjs.c:23864 起）。
2. **Q: 正则字面量在哪里与除法区分？** 词法器不区分，总是返回 `/`；`js_parse_postfix_expr` 在主表达式位置遇 `/` 时把 `buf_ptr` 回退一个/两个字节重扫为正则（quickjs.c:26878-26914）；`js_parse_skip_parens_token` 的跳读里还有 `is_regexp_allowed` 启发（24760）。
3. **Q: 关键字怎么识别？** 标识符先按 atom 查表，`update_token_ident` 用"atom 序号 - 1 + TOK_FIRST_KEYWORD"一步换算成关键字 token（quickjs.c:22762），关键字 atom 与 TOK 枚举同序是前提（21830 注释）。
4. **Q: ASI 在哪实现？** 集中在 `js_parse_expect_semi`（quickjs.c:22378-22388）三个条件；受限产生式散布：return 28971、throw 28990、指令序言 36397、后缀 ++/-- 与箭头参数表用 `got_lf`/`has_lf_in_range`（24786）。
5. **Q: try/catch 有异常表吗？** 没有。`OP_catch` 把 catch 地址压栈为 `JS_TAG_CATCH_OFFSET` 特殊值（quickjs.c:18922-18930，quickjs.h:91），异常时沿栈扫描定位；finally 用 `OP_gosub/OP_ret` 模拟（18931-18957）。
6. **Q: 跳转怎么回填？** 解析期操作数是 label 槽号；pass 2 `resolve_labels` 搬码时已定义则写相对偏移，未定义则挂 `RelocEntry` 单链表、遇 `OP_label` 回扫回填（quickjs.c:34919-34937）。
7. **Q: 闭包变量怎么编码？** 解析期 `OP_scope_get_var(atom, scope_level)`；pass 1 沿 `JSFunctionDef` parent 链回溯（quickjs.c:33106-33183），外层变量经 `get_closure_var` 逐级中转成 closure_var 下标（32736-32760），运行期即 JSVarRef 间接层。
8. **Q: 有常量折叠吗？** 无传统意义上的折叠器；有 `resolve_labels` 内的窥孔：push/drop 删除、`i32 neg` 合并、常量条件折叠、跳转链与 SHORT_OPCODES（quickjs.c:35165-35230、34737）。
9. **Q: 函数声明与表达式的名字绑定差异在哪处理？** `js_parse_function_decl2` 的 `create_func_var`/`lexical_func_idx` 双轨（quickjs.c:36579-36616）；类名是 const（25328）；类体强制严格模式（25290-25291）。
10. **Q: 语句分派有多大？** `js_parse_statement_or_decl` 约 2460 行、27 个 case（quickjs.c:28901-31360），是解析器最大函数；表达式侧最大是 `js_parse_postfix_expr`（26832 起）。

## 深挖建议

1. **`js_parse_skip_parens_token` 的正确性边界**：其注释自认"no longer works if regexps are present"（quickjs.c:24798-24799）——可构造 `( /re/, x ) => ...` 类案例验证边界与 fallback 路径（`too complicated destructuring expression`，26805 一带）。
2. **`OP_scope_*` 改写的全矩阵**：在 `resolve_variables` 中逐一列出 `OP_scope_get_var/put_var/...` × {本函数、父函数、with、eval、global} 的输出 opcode 组合（quickjs.c:33000-33330），是理解作用域的最好练习。
3. **`compute_stack_size` 的 catch_pos 追踪**：解释器栈里混有 CATCH_OFFSET 标记，静态求栈深必须模拟"标记何时被消费"（quickjs.c:35885-35933），可对照 OP_catch/gosub/ret 的运行期行为。
4. **模块字节码的特殊性**：import/export 不产码、只填 `JSModuleDef` 表；对照 `js_parse_import`（31899）里 `add_import` 的 closure 注入（31858 一带 `add_closure_var` 被模块复用）与 `js_resolve_module`。
5. **qjsc 序列化往返**：`JS_ReadFunctionBytecode`（38615）如何重定位 byte_code_buf 自指针与 atom——检验"直出字节码可直接落盘"的承诺。

---

## 写作要点速查表

| 主题 | 函数/结构 | 位置（quickjs.c 除注明外） |
|---|---|---|
| Token 结构（双 union） | `JSToken` | 22111-22132 |
| 解析状态（单 token 缓冲） | `JSParseState` | 22134-22150 |
| TOK 枚举/关键字区段 | `enum TOK_*` | 21785-21880 |
| 词法主循环 | `next_token` | 22829-23269 |
| 关键字判定 | `update_token_ident` | 22739-22765 |
| 标识符扫描（Unicode） | `parse_ident` | 22781-22826 |
| 正则识别（/ 歧义消解） | `js_parse_postfix_expr` case '/' | 26878-26914（js_parse_regexp 22603） |
| 正则前置启发 | `is_regexp_allowed` | 24760-24780 |
| ASI 主入口 | `js_parse_expect_semi` | 22378-22388 |
| 模板字符串 | `js_parse_template_part`/`js_parse_template` | 22398 / 24491 |
| 程序入口 | `js_parse_program` | 37078-37128 |
| 语句分派 switch | `js_parse_statement_or_decl` | 28901-31360（switch 于 28952） |
| 表达式阶梯 | `js_parse_expr`→`js_parse_expr_binary` | 28313 / 27733-27897 |
| 赋值/箭头短路 | `js_parse_assign_expr2` | 27999-28183 |
| emit 原语 | `emit_op`/`emit_u32`/`emit_atom` | 23864 / 23847 / 23873 |
| label 机制 | `LabelSlot`/`new_label`/`emit_goto` | 21927 / 23893 / 23944 |
| 重定位回填 | `add_reloc`/`resolve_labels` | 34620 / 34796（回填 34919-34937） |
| try/catch 落码 | TOK_TRY 分支 | 29387-29502（OP_catch 运行期 18922） |
| 窥孔开关与样例 | `OPTIMIZE`/push_i32 窥孔 | 50 / 35165-35233 |
| 三 pass 编译 | `js_create_function` | 36024（pass 调用 36100-36118） |
| 字节码产物 | `JSFunctionBytecode` | 685-724 |
| 变量查找 | `find_var`/`find_lexical_decl` | 24011 / 24087 |
| 闭包中转 | `add_closure_var`/`get_closure_var` | 32694 / 32736 |
| 父链回溯改写 | `resolve_variables` | 34187（回溯 33106-33183） |
| 函数编译 | `js_parse_function_decl2` | 36500（参数 36676-36790） |
| use strict | `js_parse_directives` | 36327（36405-36408） |
| eval 入口 | `__JS_EvalInternal` | 37188（direct 37206-37256） |
| import/export | `js_parse_source_element` | 32046-32054（import 31899/export 31699） |
| Unicode 判定 | `lre_js_is_ident_first/next` | libunicode.h:169-194 |
| 栈深计算 | `compute_stack_size` | 35753（catch 追踪 35885-35933） |
