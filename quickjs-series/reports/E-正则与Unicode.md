# E - 正则与 Unicode：libregexp 与 libunicode 深读

> bellard/quickjs，commit `04be246`（"run-test262: when updating errors, sort them so that it gives the same result with several threads"）。本文所有 `文件:行号` 均为该 commit 下仓库相对路径实测核对。
>
> 涉及文件行数：`libregexp.c` 3448 行、`libregexp-opcode.h` 73 行、`libregexp.h` 65 行、`libunicode.c` 2124 行、`libunicode-table.h` 5206 行、`libunicode.h` 196 行。

## 1. 全景：一个正则从字面量到匹配的旅程

```
源码 "/ab+c/g"
   │  词法: 遇 '/' → js_parse_regexp() 原样抠出 body+flags     quickjs.c:22603
   │  解析期直出: ctx->compile_regexp(...) 即 js_compile_regexp  quickjs.c:26893
   ▼
js_compile_regexp: 字符串 flags → LRE_FLAG_* 位掩码            quickjs.c:47582-47617
   │  lre_compile()  libregexp.c:2522
   │   ├─ 递归下降解析 re_parse_disjunction/term   libregexp.c:2406/1845
   │   ├─ 边解析边向 DynBuf 发射 REOP 字节码(直出风格)
   │   ├─ compute_register_count 线性扫描分配寄存器  libregexp.c:2444
   │   └─ 头部 8 字节: flags|capture_count|reg_count|bc_len   libregexp.c:111-116
   ▼
字节码(存进 JSString!) → OP_regexp 造 RegExp 对象, lastIndex=0  quickjs.c:18426,47657
   │
   │  运行期: re.exec(str)
   ▼
js_regexp_exec: 读 lastIndex → lre_exec(capture, bc, ...)      quickjs.c:48138-48161
   │  lre_exec_backtrack: 显式栈回溯 VM, for(;;) 大 switch      libregexp.c:2774-3321
   ▼
capture[2i]/capture[2i+1] = 匹配起止指针 → 组装 Array 结果对象
   成功且 g/y → lastIndex = capture[1]                         quickjs.c:48181-48185
```

两点值得先说破：**正则不在运行期才编译**——字面量在解析阶段就被 `lre_compile` 成 REOP 字节码并作为字符串常量嵌入函数字节码（quickjs.c:26892-26903，`emit_push_const` 后接专用 `OP_regexp`，quickjs.c:26910，理由见注释 quickjs.c:26907-26909）；**libregexp/libunicode 是零依赖可移植组件**——对宿主只有三个回调要求：栈溢出检查、超时检查、realloc（libregexp.h:59-63），quickjs.c:48000-48019 给出实现。

## 2. REOP 指令集专节

### 2.1 指令清单

37 条指令由 X-macro 定义于 libregexp-opcode.h:27-71，`#include "libregexp-opcode.h"` 生成枚举（libregexp.c:52-57）与长度表 `reopcode_info`（libregexp.c:101-109）。按功能分组：

| 组 | 指令 | 说明 |
|---|---|---|
| 字符 | `char`(3B)/`char_i`/`char32`(5B)/`char32_i` | 16/32 位码点，`_i` 为忽略大小写版，执行时对输入做 `lre_canonicalize`（libregexp.c:2939-2941） |
| 通配 | `dot`/`any`/`space`/`not_space` | `any` 是 dotall 版 dot（libregexp-opcode.h:33）；`\s` 有专用指令是发射期特判（libregexp.c:2176-2179） |
| 断言 | `line_start(_m)`/`line_end(_m)`/`word_boundary(_i)`/`not_word_boundary(_i)` | `_m` 为 multiline 版（发射于 libregexp.c:1857-1864） |
| 控制流 | `goto`(5B)/`split_goto_first`/`split_next_first` | **回溯骨架**，跳转均为相对偏移（发射 libregexp.c:631-638） |
| 量词 | `loop`(6B)/`loop_split_goto_first`/`loop_split_next_first`/`loop_check_adv_split_*`(10B) | 计数循环 + 条件分裂混合指令（libregexp-opcode.h:49-53） |
| 捕获 | `save_start`/`save_end`(2B)/`save_reset`(3B) | `save_reset` 区间性清零捕获（发射 libregexp.c:2277-2283） |
| 引用 | `back_reference(_i)`/`backward_back_reference(_i)`(2B+变长) | 变长：后跟 n 个组号（libregexp.c:3182-3184） |
| 区间 | `range(_i)`/`range32(_i)`(3B+变长) | 16/32 位区间表，0xffff 表示无穷（libregexp.c:1240-1248） |
| 环视 | `lookahead`/`negative_lookahead`(5B)/`lookahead_match`/`negative_lookahead_match` | 成对出现：头+尾标记（libregexp.c:1970-1981） |
| 前进检查 | `set_i32`/`set_char_pos`/`check_advance` | 防零宽死循环的寄存器指令（libregexp.c:2265-2310） |
| 方向 | `prev`(1B) | 后向匹配时把 cptr 前移一个码点（libregexp.c:3308-3313） |

字节码头部 8 字节：`u16 flags | u8 capture_count | u8 register_count | u32 bc_len`（libregexp.c:111-116），其后可拖挂命名组名表（每项 `name\0 + 1 字节 scope`，`LRE_GROUP_NAME_TRAILER_LEN 2`，libregexp.h:44；追加于 libregexp.c:2599-2604）。

### 2.2 split/jmp：回溯骨架的搭法

`split_goto_first`/`split_next_first` 语义：先推一个"另一条路"的还原帧，再走优先路。两个 opcode 用 `REOP_split_goto_first + greedy` 这种**算术翻转**表达贪婪/懒惰（发射处 libregexp.c:2302-2303、2334，量化器 greedy 标志 libregexp.c:2249-2253）：

```c
// libregexp.c:2945-2966
case REOP_split_goto_first:
case REOP_split_next_first:
    val = get_u32(pc); pc += 4;
    if (opcode == REOP_split_next_first) pc1 = pc + (int)val;
    else { pc1 = pc; pc = pc + (int)val; }
    CHECK_STACK_SPACE(3);
    sp[0].ptr = (uint8_t *)pc1;      /* 另一条路的 pc */
    sp[1].ptr = (uint8_t *)cptr;     /* 另一条路的输入位置 */
    sp[2].bp.val = bp - s->stack_buf; sp[2].bp.type = RE_EXEC_STATE_SPLIT;
    sp += 3; bp = sp;
```

选择分支 `a|b` 在解析时通过 **dbuf_insert 回填**实现：每遇 `|` 就在第一个备选前面插一条 `split_next_first`，末尾 `goto` 汇合（libregexp.c:2416-2438）。贪婪 `a*` 生成 `split_goto_first→body` + 尾部 `goto` 回起点；懒惰则翻转为 `split_next_first`（libregexp.c:2298-2312）。`a{2,5}` 编成 `set_i32 r0,5` + `loop_split_*` 计数循环（libregexp.c:2336-2358），`{n}` 精确重复用纯 `loop`（libregexp.c:2352-2354）。寄存器不是运行期分配的：`compute_register_count` 静态模拟"寄存器即栈"的分配，把寄存器号回填进指令（libregexp.c:2442-2505，上限 `REGISTER_COUNT_MAX 255`，libregexp.c:60）。

零宽循环防护：编译期用 `re_need_check_adv_and_capture_init` 扫描 atom 字节码，判断"是否保证前进"（libregexp.c:1557-1628），不保证就在循环里插 `set_char_pos r` / `check_advance r`，执行期发现位置没动则 no_match（libregexp.c:3099-3105、3132-3137），对应规范"量化 atom 若不前进则失败"。

## 3. 回溯专节：lre_exec_backtrack

### 3.1 栈模型：单函数 + 显式栈，非 C 递归

`lre_exec_backtrack`（libregexp.c:2774-3321）是一个约 550 行的 `for(;;) switch`——**执行期没有 C 递归**，所有回溯状态放在堆/静态混合的显式栈上。C 递归只出现在**解析期**（`re_parse_disjunction` → `re_parse_term` 互调，栈溢出检查挂在 libregexp.c:2410 与嵌套字符类 libregexp.c:1390，经宿主回调 quickjs.c:48000-48004 接 `js_check_stack_overflow`，quickjs.c:2059-2064）。

栈元素是 3 字槽帧：`{另一路 pc, 另一路 cptr, {bp 恢复点, 帧类型}}`，`bp.type` 用指针低位 bitfield 编码（libregexp.c:2710-2723）。帧类型三态（libregexp.c:2704-2708）：`SPLIT`/`LOOKAHEAD`/`NEGATIVE_LOOKAHEAD`。栈初始用 32 元素的 `static_stack_buf` 免分配（libregexp.c:2737、3345-3346），不够时 `stack_realloc` 按 3/2 扩容（libregexp.c:2750-2771）——所以回溯深度**只受内存限制**，没有 `LRE_STACK_SIZE` 这类常量（grep 证实不存在）；失败路径一律返回 `LRE_RET_MEMORY_ERROR`。

失败回退集中在唯一标签 `no_match`（libregexp.c:2852-2873）：先把 `sp` 到 `bp` 之间的捕获撤销记录逐条还原，再弹一个决策帧，若帧类型是 `LOOKAHEAD` 则继续外弹（环视失败要一路剥到环视帧）。

### 3.2 捕获的保存/恢复：undo 日志，不是帧快照

这是本引擎最巧妙的设计。capture 数组是**平铺可变数组**（`capture[2i]`=组 i 起点、`capture[2i+1]`=终点，由调用方分配，`lre_get_alloc_count = capture_count*2 + register_count`，libregexp.c:3366-3370）。每次写捕获前把旧值压栈成 undo 记录（libregexp.c:2805-2812）：

```c
// libregexp.c:2805-2812
#define SAVE_CAPTURE(idx, value)            \
    {                                       \
        CHECK_STACK_SPACE(2);               \
        sp[0].val = idx;                    \
        sp[1].ptr = capture[idx];           \
        sp += 2;                            \
        capture[idx] = (value);             \
    }
```

`no_match` 回溯时（libregexp.c:2857-2861）按栈逆序恢复，成本与实际发生过的捕获写入成正比，避免了"每帧拷贝整个 capture 数组"的 O(n) 开销。`SAVE_CAPTURE_CHECK`（libregexp.c:2815-2833）进一步做峰值去重：若当前帧内同一 idx 已存过旧值就不再重复保存。量词迭代需要清空组时，`save_reset` 在发射期插入（libregexp.c:2276-2295），执行期对区间内每个 capture 槽做 SAVE_CAPTURE(idx, NULL)（libregexp.c:3038-3054）。

### 3.3 贪婪/懒惰与环视的栈语义

- **贪婪 vs 懒惰**：区别只在编译期选 `split_goto_first`（先试 body，贪婪）还是 `split_next_first`（先试出口，懒惰），执行器无差别（libregexp.c:2332-2335）。
- **前向环视 `(?=...)`**：发射 `lookahead` 头 + body + `lookahead_match` 尾（libregexp.c:1970-1981）。执行 `lookahead` 压 `LOOKAHEAD` 帧并推进到 body（libregexp.c:2967-2978）；body 匹配到 `lookahead_match` 时，**弹出至环视帧为止的决策栈，但保留其中捕获 undo 记录**——所以 `(x)=(?=(y))` 中 y 的捕获能存活（libregexp.c:2874-2906）。失败则沿 `no_match` 外弹。
- **否定环视 `(?!...)`**：body 匹配到 `negative_lookahead_match` 时**撤销全部捕获并强制 no_match**（libregexp.c:2907-2925），成功路径才继续。
- **后行环视 `(?<=...)`**：解析期传 `is_backward_lookahead` 递归编译，body 各 term 在字节码里**整段倒序排列**（memmove 搬移，libregexp.c:2389-2401），逐 atom 前后包 `REOP_prev` 使 cptr 反向行走（libregexp.c:2171-2172），backref 也有 backward 变体（libregexp.c:3209-3223）。`lre_exec` 起点若落在代理对中间会回退对齐到高代理（libregexp.c:3352-3357）。
- **超时**：`lre_poll_timeout` 每 10000 条 goto/loop/split 计数指令调一次宿主 `lre_check_timeout`（libregexp.c:2740-2748、`INTERRUPT_COUNTER_INIT` libregexp.c:63），quickjs 接到 interrupt_handler（quickjs.c:48006-48012），exec 侧以 `LRE_RET_TIMEOUT` 逃逸（quickjs.c:48170-48171）。**这是灾难性回溯唯一的运行期防线**——见第 6 节。

## 4. Unicode 支撑专节：libunicode

### 4.1 表的压缩：三层结构逐字段

`libunicode-table.h` 是 `unicode_gen.c` 从 UCD 17.0.0（libunicode.h:30-32；下载脚本 unicode_download.sh:4）生成的静态表。核心套路是"**3 字节索引 + 块内 RLE**"：

- **索引表**：每项 3 字节 = 21 bit 码点 + 11 bit 块偏移，源码里直接带可读注释（libunicode-table.h:479-491，如 `// 003F6 at 33`）。查找 `get_index_pos` 二分到所在块，返回 `(idx+1)*32 + 低位偏移`（libunicode.c:271-302，`UNICODE_INDEX_BLOCK_LEN 32` libunicode.c:268）。
- **RLE 位图/区间表**：`lre_is_in_table` 解码，注释即文档（libunicode.c:316-323）：`0x00-0x3F` 两段 3+3 bit 长度、`0x40-0x5F` 5 bit+1 字节、`0x60-0x7F` 5 bit+2 字节、`0x80-0xFF` 7 bit 长度，区间真假交替。
- **大小写转换**：`case_conv_table1[378]`（u32，libunicode-table.h:6）一个字打包四字段：高 17 bit `code`、7 bit `len`、4 bit `type`（RUN_TYPE_*，libunicode.c:34-49）、4 bit 附加 data 与 `case_conv_table2[378]`（u8）拼出 12 bit 数据指针（解码 libunicode.c:63-65）。首项 `0x00209a30` 解出 code=0x41('A')、len=26、type=RUN_TYPE_UL——A-Z 交替大小写一个 entry 搞定。多字符映射（如 ß→SS）走 `case_conv_ext[58]` 与 LF_EXT2/UF_EXT3 类型（libunicode.c:115-145），结果最多 3 字符（`LRE_CC_RES_LEN_MAX 3`，libunicode.h:37）。
- **属性区间**（General_Category/Script/各种 prop）：`unicode_gc_table[4122]`、`unicode_script_table[2818]` 等（libunicode-table.h:2456、3334），各自带一段手写 RLE 解码循环（libunicode.c:1398-1457、1276-1394、1459-1504）。复合属性用小型栈机 `unicode_prop_ops` 做 UNION/INTER/XOR/INVERT 组合（libunicode.c:1519-1593），例如 `Math = Sm ∪ Other_Math`（libunicode.c:1652-1658）。

### 4.2 u flag 语义差异与规范化支持

- **大小写规范化**：`lre_canonicalize(c, is_unicode)`（libunicode.c:227-261）。u 模式走 case folding（等价 toLower 微调，特例 0xfb06→0xfb05 等三处硬编码，libunicode.c:204-210）；非 u 模式沿用 ES5 遗留规则——ASCII 转大写、≥0x80 的单字符也转大写（libunicode.c:213-221）。执行期所有 `_i` 指令与 `range_i` 查表前都对输入调用它。
- **字符类与 v flag**：字符类编译成 `REStringList` = CharRange + 多字符字符串哈希集（libregexp.c:139-148）。u/v 模式下 `\p{...}` 属性类（libregexp.c:1123-1131、869-987）、v 模式的集合运算 `&&`/`--`（libregexp.c:1476-1514）与字符串字面量 `\q{...}`（libregexp.c:1133-1140、993-1039）。含字符串的类编译为"按长度降序 split 链"（最长优先匹配，libregexp.c:1276-1352）；忽略大小写时对整个集合先做 `cr_regexp_canonicalize`（libunicode.c:660-742：交出"会变大小写的字符"逐个折叠再并回）。发射时按区间最高值选 16 位 `range` 或 32 位 `range32`（libregexp.c:1225-1259）。
- **执行期码点宽度**：`cbuf_type` 0/1/2 = 8bit/16bit/16bit+UTF-16 语义；u flag 时自动升到 2（libregexp.c:3340-3341），GET_CHAR 宏在 type=2 下自动合并代理对（libregexp.c:2621-2636）——**u 模式以码点为单位步进，非 u 模式以 UTF-16 码元为单位**，这就是 `.` 与量词在 u 下行为不同的根源。
- **字符串规范化**：libunicode 提供完整 NFC/NFD/NFKC/NFKD（`unicode_normalize`，libunicode.c:1171-1243；Hangul 算法式分解 libunicode.c:1136-1143、组合 libunicode.c:1156-1169），quickjs 的 `String.prototype.normalize` 即其包装（quickjs.c:46580-46643）。注意它服务于 String API，**正则引擎本身不做规范化匹配**。
- **词法复用（呼应 B 报告）**：标识符判定 `lre_is_id_start/continue`（libunicode.c:746-759，基于 ID_Start/ID_Continue1 表）经 `lre_js_is_ident_first/next` 内联门（libunicode.h:169-194，ASCII 走 256 项位表 `lre_ctype_bits` libunicode.c:1835-1875，ZWNJ/ZWJ 特判 libunicode.h:186-187）被主解析器大量调用（quickjs.c:22685、22943、23247 等）——词法器与正则 `\w`/标识符共享同一套 Unicode 基础设施。`lre_is_cased`/`lre_is_case_ignorable`（libunicode.c:347-377）同理服务于大小写折叠的边界规则。

## 5. 集成专节：quickjs 主引擎走线

- **编译点**：`js_parse_regexp`（quickjs.c:22603）在词法层抠出 `/body/flags`（字符类内 `/` 不终止、LS/PS 视为行终止符，quickjs.c:22631、22663）；主表达式在 `parse_regexp` 标签处调 `ctx->compile_regexp`（quickjs.c:26887-26903）——该函数指针由 `JS_AddIntrinsicRegExpCompiler` 单独注入（quickjs.c:49261-49264），所以 qjsc 编译器可以**不带正则编译器**（字面量已在编译期变成字节码常量）。`js_compile_regexp`（quickjs.c:47565-47641）解析 flags 位掩码（u/v 互斥 quickjs.c:47622-47625）、调 `lre_compile`、把字节码存成 JSString（quickjs.c:47638）。`OP_regexp` 指令（quickjs-opcode.h:121）在解释器里就是 `JS_NewRegexp(sp[-2], sp[-1])`（quickjs.c:18426-18435），构造时 lastIndex 固定初始化 0（quickjs.c:47657）。
- **lastIndex 状态机**：lastIndex 被优化为对象第一个属性槽（quickjs.c:48076-48090 注释"always the first property"）。`js_regexp_exec`（quickjs.c:48108）：非 g/y 强制 last_index=0（quickjs.c:48143-48145）；`last_index > str->len` 时 rc=2（quickjs.c:48156-48157），rc==2 或 g/y 失败后重置为 0（quickjs.c:48163-48168）；成功且 g/y 则写回 `capture[1]`（quickjs.c:48181-48185）。`js_regexp_replace` 的直连快路径（quickjs.c:48328-48460，条件：标准 RegExp 且替换串非函数，入口判断 quickjs.c:48881-48885）同样走 lastIndex 循环，但**命名组未支持、直接放弃快路径**（quickjs.c:48348-48350），慢路径才支持 `$<name>`（经 js_string_GetSubstitution，quickjs.c:45888）。
- **split**：`js_regexp_Symbol_split`（quickjs.c:49102）按规范克隆 splitter 并强制附加 y flag（quickjs.c:49128-49132），循环 `JS_RegExpExec` 切分；u/v 时按码点推进。
- **flags/属性**：`d/g/i/m/s/u/v/y` 八个 getter 用同一 `js_regexp_get_flag` 带 magic 实现（quickjs.c:47921、49237-49244）。

## 6. 设计动机

1. **为什么独立成库**：libregexp/libunicode 只依赖 cutils 的 DynBuf 与三个用户回调（libregexp.h:59-63），无 GC、无 JSValue 概念，capture 用裸 `uint8_t*` 指针对。这使它们可单独发布（Bellard 历史上曾单独发布 libregexp 压缩包），也被 quickjs 以外的项目（如 quickjs-ng 之外的各种嵌入式）复用。同样设计也方便 qjsc 把"正则编译器"从运行时剥离（quickjs.c:49261）。
2. **为什么回溯而非线性引擎**：libregexp.c:40-43 的 TODO 明说："Add a lock step execution mode (=linear time execution guaranteed)…The opcodes are designed for this execution model"——REOP 的 split/loop 指令形状本来就是为 Thompson 式并行模拟预留的，只是还没实现。现状选择回溯是体积/兼容折衷：线性引擎（RE2/DFAM）无法支持 backreference 与任意环视捕获语义（ Irregexp 实际是"回溯 VM + DFA 加速"混合，纯 DFA 方案必须放弃 backref）。QuickJS 作为教学级引擎选择了 3.4k 行的回溯 VM，代价是 `(a+)+b` 类输入指数回溯，唯一防线是 interrupt_handler 超时（libregexp.c:2740-2748）。
3. **Unicode 表的体积取舍**：全量表比裁剪版大约 40KB（libunicode.h:34-35 `#define CONFIG_ALL_UNICODE` 注释"40KB larger"）。关掉后 `lre_is_id_start` 退化为"非空白"近似（libunicode.h:176-177）。压缩三板斧（3 字节索引+块内 RLE+u32 位打包的 case 表）把整个 Unicode 17 支撑压进 ~250KB 源码表；代价是每个谓词都是"二分+RLE 线性扫"，而非 O(1) 位图——对解释器整体性能这是正确取舍。

## 7. FAQ 素材

1. **Q: QuickJS 正则是 NFA 还是 DFA？** 回溯型 NFA VM（pike/Thompson 混合风格但单线程顺序回溯），非 DFA；libregexp.c:40-43 留有线性执行模式的 TODO。
2. **Q: 有灾难性回溯保护吗？** 没有自动线性化，只有两层保险：interrupt_handler 超时回调（每 10000 条指令检查一次，libregexp.c:63、2740-2748）与回溯栈 OOM 返回 `LRE_RET_MEMORY_ERROR`（libregexp.h:40）。
3. **Q: 编译期有没有 `LRE_COMPILE_STACK_SIZE`？** 没有。编译期预算是：捕获组 ≤255（`CAPTURE_COUNT_MAX` libregexp.c:59）、寄存器 ≤255（libregexp.c:60）、字节码 ≤2GB（libregexp.c:2507-2516）、解析递归深度由宿主 `lre_check_stack_overflow` 把关（libregexp.c:2410；quickjs 实现 quickjs.c:48000）。
4. **Q: 回溯栈是 C 递归吗？** 不是。执行期单函数 + 显式栈（初始 32 元素静态数组，libregexp.c:2737，3/2 扩容 libregexp.c:2750-2771）；递归只在解析期。
5. **Q: capture 数组怎么组织？** 调用方分配 `2*capture_count + register_count` 个指针槽（libregexp.c:3366-3370），组 i 占 `[2i],[2i+1]`，寄存器排在其后；匹配结果是相对输入缓冲的字节指针，quickjs 再换算为索引（quickjs.c:48237-48238）。
6. **Q: 命名组怎么实现？** 编译期把 `name\0 + scope` 追加到字节码尾部（libregexp.c:1994-1997），`\k<name>` 与同名多义组解析为**多个组号列表**的 back_reference（变长指令，libregexp.c:2083-2088）；执行期 backref 取"第一个非空捕获"（libregexp.c:3192-3193）。
7. **Q: 后行环视怎么实现？** 不是反向执行 VM，而是把 body 的字节码**整段反序排列**并在每 atom 两侧插 `REOP_prev` 让读指针倒走（libregexp.c:2389-2401、2171-2172）。
8. **Q: 贪婪/懒惰差别在哪？** 只差一个 opcode 选择：`split_goto_first`（先试循环体）vs `split_next_first`（先试出口），由 `REOP_split_goto_first + greedy` 算术得出（libregexp.c:2302-2303）。
9. **Q: u flag 具体改变了什么？** 输入以码点为单位（代理对自动合并，libregexp.c:2621-2636、3340-3341）；大小写折叠走 case folding 而非 legacy toUpperCase（libunicode.c:227-261）；`\p{...}`、码点转义 `\u{...}` 可用（libregexp.c:779-792）。
10. **Q: v flag（unicodeSets）额外做什么？** 字符类内集合运算 `&&`/`--` 与字符串字面量 `\q{}`（libregexp.c:1476-1514、1133-1140），字符类升级为"区间+多字符串"集合（libregexp.c:139-148），大小写折叠顺序也与 u 不同（libregexp.c:961-982 注释）。

## 8. 深挖题目

1. **REOP 到线性引擎的距离**：对照 libregexp.c:40-43 TODO，评估 split/goto 骨架若改为 Thompson NFA 模拟（bitstate/lockstep）还需要改哪些指令（backref/lookahead/loop 计数器如何处理），并估算与 RE2 one-pass 的差距。
2. **SAVE_CAPTURE_CHECK 的去重边界**：libregexp.c:2815-2833 只向 `bp` 方向扫描去重，构造一个"跨帧同 idx 重复保存"用例验证正确性与最坏栈深。
3. **非 u 模式 casefold 的规范符合性**：libunicode.c:213-221 的 legacy 规则（≥0x80 单字符转大写）与 test262 的历史偏差，对照 `test262_errors.txt` 中 regexp 相关残留。
4. **`lre_exec` 起点 cindex 的代理对齐**（libregexp.c:3352-3357）与 `String.prototype.replace` 在 u 模式空匹配推进（quickjs.c:48929-48935"always advance of at least one char"）联合构成的码点安全网是否完备。
5. **表体积实验**：注释掉 `CONFIG_ALL_UNICODE` 重编译，对比 `lre_is_id_start` 退化路径（libunicode.h:173-177）对词法器非 ASCII 标识符判定的影响，量化"40KB"。

---

## 写作要点速查表

| 主题 | 位置 |
|---|---|
| REOP 37 指令 X-macro 清单 | libregexp-opcode.h:27-71 |
| 字节码 8 字节头 flags/captures/regs/len | libregexp.c:111-116 |
| split 执行语义（回溯帧入栈） | libregexp.c:2945-2966 |
| no_match 回溯+捕获撤销 | libregexp.c:2852-2873 |
| SAVE_CAPTURE undo 日志宏 | libregexp.c:2805-2833 |
| lookahead/lookahead_match 捕获保留 | libregexp.c:2874-2906 |
| 量词编译（greedy 翻转/loop/check_adv） | libregexp.c:2196-2358 |
| lre_compile 总入口（含非 sticky 前导 split） | libregexp.c:2522-2614（2554-2562） |
| compute_register_count 静态寄存器分配 | libregexp.c:2442-2505 |
| lre_exec_backtrack 主循环（显式栈非递归） | libregexp.c:2774-3321 |
| lre_exec 入口/cbuf_type=2 码点模式 | libregexp.c:3326-3364（3340-3341） |
| 超时检查 lre_poll_timeout（10000 步） | libregexp.c:2740-2748 |
| lre_canonicalize u/非u 折叠分叉 | libunicode.c:227-261 |
| case_conv_table1 u32 位打包解码 | libunicode.c:59-65；libunicode-table.h:6 |
| 3 字节索引+块内 RLE（get_index_pos/is_in_table） | libunicode.c:271-345 |
| ID_Start/Continue 表及词法复用 | libunicode-table.h:332,479；libunicode.c:746-759；libunicode.h:169-194 |
| 字面量解析期编译 + OP_regexp | quickjs.c:26883-26913；18426-18435；22603 |
| js_compile_regexp/flags→掩码/字节码存 JSString | quickjs.c:47565-47641（47630,47638） |
| lastIndex 状态机（exec 内 g/y 语义） | quickjs.c:48138-48185 |
| replace 快路径（命名组退回慢路径） | quickjs.c:48328-48350 |
