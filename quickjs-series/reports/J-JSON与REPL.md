# J 篇：QuickJS 的 JSON 解析器、正则执行器与 REPL 架构

> 调研对象：quickjs 仓库 commit `04be246`（run-test262: when updating errors, sort them...，2025 系列 master）。
> 所有行号均为该 commit 下仓库相对路径 `文件:行号`，经 grep -n / Read 实际核对。
> 本篇是精简卷（01-05 讲核心引擎）之后的"外围补齐"章：JSON、正则执行、REPL、调试现状与性能特征。

---

## 1. 全景：JSON 与 REPL 的数据流

JSON 两条路径共用 JS 词法器（`JSParseState` + `json_next_token`），stringify 则完全独立，走 StringBuffer：

```
JSON.parse(text, reviver)                       JSON.stringify(v, replacer, space)
  |                                                |
  v                                                v
js_json_parse (quickjs.c:49814)                 JS_JSONStringify (quickjs.c:50251)
  |  有 reviver?                                   |  replacer=函数? => replacer_func
  |  是: 先建 JSONParseRecord 源映射               |  replacer=数组? => property_list (50281)
  |      js_parse_record_add (49405)               |  space=数字n? => n 个空格 gap (50337)
  v                                                v
JS_ParseJSON3 (49670) --复用--> js_parse_init   js_json_check (50001)
  |  json_next_token (23477)                       |  toJSON? (50009)  replacer函数? (50024)
  v                                                |  循环检测: stack 数组 includes (50106)
json_parse_value (49484)  递归下降                 v
  |  { } 对象/[ ]数组/串/数/true|false|null       js_json_to_str (50059) 递归
  |  ext_json: 单引号/NaN/Infinity/尾逗号          |  写入 StringBuffer: '[' ']' '{' '}' ':' ','
  v                                                v
  返回 JSValue 对象图                          string_buffer_end => 字符串 (50369)
  |
  v  仅有 reviver 时: 第二趟
internalize_json_property (49709)
  |  按 JSONParseRecord 找回原始源文本 source (49786)
  |  调 reviver(name, val, context) 三个参数 (49802)
  v
  最终值
```

REPL 是"C 壳 + 自宿主 JS 前端"：qjs.c 只负责把预编译的 repl.js 字节码灌进引擎，行编辑、多行判定、结果打印全在 JS 里：

```
qjs main (qjs.c:314)
  |  无文件参数 => interactive=1 (qjs.c:513-515)
  v
js_std_eval_binary(ctx, qjsc_repl, ...) (qjs.c:524)   <-- 构建期 qjsc -s -c -m repl.js
  |  JS_ReadObject 读字节码 (quickjs-libc.c:4353)         生成 repl.c，随二进制发布
  v
repl.js cmd_start (943) => cmd_readline_start (949)
  |  readline_start("    "*level, cb) (779)  续行提示符 = 4*level 个空格
  v
os.setReadHandler(term_fd) 逐键 => handle_key => readline_cb(cmd)
  |
  v
handle_cmd(expr) (960)
  |  \h \x \d \t \clear \q 指令 (extract_directive:891, handle_directive:903)
  |  多行累积: mexpr = mexpr + '\n' + expr (982)
  |  词法判定完整性: colorize_js(expr) => [state, level, colors] (983, 定义 1057)
  |     level>0 或 state 非空 => 未完，存 mexpr，换个提示符继续 (986-989)
  v
std.evalScript(expr, {backtrace_barrier:true, async:true}) (1003)
  |  => js_evalScript (quickjs-libc.c:880) => JS_Eval(JS_EVAL_TYPE_GLOBAL|ASYNC) (915)
  |  脚本完成值(completion value)就是"表达式求值结果"，无需区分表达式/语句
  v
print_eval_result (1011)
  |  数字/bignum 可选十六进制显示 \x (1017-1027)
  |  std.__printObject(result) => JS_PrintValue (quickjs.c:14440, 深度2/串1000/项100)
  |  g._ = result  上一结果绑定到 `_` (1034)
  v
handle_cmd_end (1050): 每条命令后 std.gc() (1053)，回到 readline
```

正则执行器（独立子系统 libregexp.c，3448 行）：`new RegExp`/字面量 → `lre_compile`（libregexp.c:2522，语法树 → 自定义字节码）→ `js_regexp_exec`（quickjs.c:48108）→ `lre_exec`（libregexp.c:3326）→ `lre_exec_backtrack`（libregexp.c:2774，显式栈回溯机）。

---

## 2. JSON 专节

### 2.1 解析器：递归下降，且复用 JS 词法器

QuickJS 没有独立 JSON 模块目录，全部在 quickjs.c 的 `/* JSON */` 段（49317 起）。解析核心 `json_parse_value`（quickjs.c:49484）是一个标准递归下降函数：`'{'` 分支建对象（49504）、`'['` 分支建数组（49567）、字符串/数字/true/false/null 直接落到值（49605-49652），非法 token 报 "unexpected token"（49658）。顶层入口 `JS_ParseJSON3`（49670）先 `js_parse_init` 复用 JS 的解析器状态，再检查尾部无多余数据（49683-49684）。

词法层 `json_next_token`（23477）与 `json_parse_string`（23305）也在 JS 词法器旁边：JSON 只认双引号，单引号在非扩展模式下落入 def_token（23501-23505）；`\uXXXX` 严格 4 位十六进制（23337-23347）；控制字符 `c < 0x20` 直接报错（23323-23326）。

**扩展 JSON（JSON5 风）由同一个解析器承担**：`JS_PARSE_JSON_EXT` 标志（quickjs.h:864）置 `s->ext_json`（49677）后，单引号串、标识符属性名（49517）、尾逗号（49550/49597）、`NaN/Infinity`（49641-49646）全部放行。它服务三个出口：

- `import ... with { type: "json5" }`：模块加载器对 `.json` 模块按属性选 flags，quickjs-libc.c:703-716；
- `std.parseExtJSON`（quickjs-libc.c:967-980）；
- qjsc 把 JSON 模块编译进字节码（qjsc.c:280-283）。

### 2.2 循环引用与解析记录：reviver 为什么要有两趟

裸解析（无 reviver）一趟完成、零额外结构。带 reviver 时 quickjs.c:49824-49854 走两趟：

1. 第一趟照常建对象图，但同时在 `JSONParseRecord` 树（结构体定义 quickjs.c:49336-49349）里镜像记录每个值的**源文本区间** `source_pos/source_len`（49608-49610、49618-49620，相对 `s->buf_start`）；
2. 第二趟 `internalize_json_property`（49709）按规范递归"内部化"，并在原始源文本上取回 `new_el = JS_NewStringLen(text_str + pr->u.primitive.source_pos, ...)`（49786），塞进 `context.source`（49790），最后以 **三个参数** 调 reviver：`JS_Call(ctx, reviver, holder, 3, args)`（49802）。

实测（本 commit 二进制）：`JSON.parse('123', (k,v,ctx)=>{...})` 中 `ctx` 为 `{"source":"123"}`；数组元素拿到 `{"source":"4"}`。这是 JSON Parse Source Text Access 提案的实现——`JSON.rawJSON`（49887，校验首尾字符后重 parse 验证合法，49896-49906）与 `JSON.isRawJSON`（49867，检查 `class_id == JS_CLASS_RAWJSON`，49873）同属一族。

实现细节值得注意：对象属性查找在条目 `<8` 时线性扫描，≥8 才建哈希表（`json_parse_record_add` quickjs.c:49405，阈值判断 49416-49421，链表冲突法 49381-49403）；失败路径统一 `json_free_parse_record`（49459）释放镜像树。深度递归两处都有 `js_check_stack_overflow` 保护（49720、23483）。

### 2.3 stringify：toJSON、replacer、gap 与循环检测

序列化入口 `JS_JSONStringify`（50251）先做三件预处理：函数 replacer 存 `jsc->replacer_func`（50273-50274）；数组 replacer 去重后转 `property_list`（50281-50321，元素只认 String/Number/包装对象，50291-50309）；space 按 `JS_ToInt32Clamp(0,10)` 生成空格串、或截取字符串前 10 字符（50337-50347）。随后包一层 `wrapper = {"": obj}`（50351-50356）使根值也符合 holder 协议。

主递归是两个函数的接力：

- `js_json_check`（50001）：对对象/BigInt 先取 `toJSON` 调用（50009-50022，注释明言"规范只对 Object 和 BigInt 这么做"），再调 replacer 函数（50024-50032）；返回 undefined 的属性后续被跳过。
- `js_json_to_str`（50059）：包装对象拆箱（String/Number/Boolean/BigInt/RawJSON，50083-50105）；**循环引用检测**用 `js_array_includes(jsc->stack, val)`（50106-50112）——命中即 `TypeError: circular reference`，实测 `o.self=o` 正是此错；数组/对象分支（50133/50163）负责 `'['`/`'{'`、`sep`（`\n`+缩进）与 `sep1`（`": "` 对 `:`）的排版；原始值分支（50216）中 `Infinity/NaN => null`（50221-50225），BigInt 直接抛错（50234）。

字符串转义集中在 `JS_ToQuotedString`（49933）：`\t \r \n \b \f \" \\` 短转义（49951-49972），其余 `<0x20` 与孤立代理对一律 `\u%04x`（49975-49977）。顶层结果若为 undefined 则整个 `JSON.stringify(undefined)` 返回 undefined（50362-50364）。JS 层面共 4 个方法：parse/stringify/rawJSON/isRawJSON（50392-50398）。

---

## 3. REPL 专节

### 3.1 架构：C 壳极薄，REPL 本体是自宿主 JS

qjs.c 只有 568 行，交互模式的全部 C 侧工作就是：注册 std/os 模块（107-117）→ 判定"无文件参数即交互"（513-515）→ 执行 `js_std_eval_binary(ctx, qjsc_repl, qjsc_repl_size, 0)`（522-525）。`qjsc_repl` 是构建期由 `qjsc -s -c -m repl.js`（Makefile:320-321）生成的字节码数组，即 **REPL 自己也吃自己的编译产物**；repl.js 共 1292 行。

行编辑器完全自造、零外部依赖（不依赖 readline/linenoise）：raw 模式下经 `os.setReadHandler(term_fd, ...)` 逐键读入（repl.js:114-146 初始化，806-836 状态机含 ESC 序列解析），实现历史（381-425，含前缀搜索）、kill/yank、UTF-8 光标、CSI 逐字符着色回显。这也是它把语法着色做进 REPL 的原因——着色器就是多行判定的副产品。

### 3.2 多行输入判定：纯词法，而非"解析报错再回退"

`colorize_js`（1057）是一个手写 JS 词法状态机：维护 `state` 栈（字符串/模板/注释/正则）与括号 `level`（1250-1266 开括号 push+level++，闭括号 `is_balanced` 检查后 level--），并处理正则/除法歧义（`can_regex` 标志，1237-1242；关键字后禁正则，1168、1181-1182）。返回 `[state, level, r]`（1285）。

`handle_cmd`（960）拿这个结果做判定：`pstate`（state 串）非空或 `level>0` 时，把当前输入累积进 `mexpr`（981-988）并返回"未完"，提示符变成 `ps2 = "  ... "`（88，拼接逻辑 789-791）；完成时拼成 `mexpr + '\n' + expr` 一次求值。**注意这与很多 REPL 不同**：QuickJS 不靠"解析失败=继续等输入"，而是靠词法括号计数。实测 `1+`（词法完整、语法错误）立即得到 `SyntaxError: expecting ';'`，不会进入续行模式；`{`、`[`、反引号、未闭合正则则会正确续行。

### 3.3 求值与打印：完成值语义 + JS_PrintValue

REPL 不区分"表达式求值 vs 语句求值"。所有输入统一 `std.evalScript(expr, {backtrace_barrier:true, async:true})`（1003）→ `js_evalScript`（quickjs-libc.c:880）以 `JS_EVAL_TYPE_GLOBAL` 求值（910-915）。JS 脚本求值天然返回**完成值**（completion value），因此 `1+1` 得 `2`、`if (true) { 42 }` 得 `42`、`var z=5` 得 `undefined`、`1+1; var q;` 得 `2`（均实测）。`async:true` 使顶层 await 可用：evalScript 返回 promise，`result.then(print_eval_result, print_eval_error)`（1005），打印时取 `result.value`（1014）。

打印走 `std.__printObject`（1029）→ `JS_PrintValue`（quickjs.c:14440），默认选项为 `max_depth=2 / max_string_length=1000 / max_item_count=100`（14401-14407），故 `{a:[1,{b:2}]}` 显示为截断风格 `{a: [ 1, [Object] ] }` 风格的检视输出而非 `JSON.stringify`。`\x` 指令切换整数/bigint 十六进制显示（1017-1027、914-917）。上一条结果绑定为 `g._`（1034）。每条命令结束后强制 `std.gc()`（1053）——教学工具的取舍：内存确定性优先于吞吐。`backtrace_barrier` 保证 REPL 求值栈帧之后的内部帧不出现在用户报错回溯里（quickjs.h:344，quickjs-libc.c:911-912）。Ctrl-C 经 `JS_SetInterruptHandler` 转为普通异常被 REPL 捕获（quickjs-libc.c:906-924）。

指令集很小：`\h` 帮助、`\x`/`\d` 进制、`\t` 计时、`\clear`、`\q`、`\load` 文件（903-929）。

---

## 4. 性能专节

### 4.1 启动：没有 snapshot，靠什么快

QuickJS 没有任何启动快照机制（全仓库 grep "snapshot" 无命中）。它靠三件事：

1. **启动即 C 数据结构初始化**：`qjs -q -d`（空跑+内存转储，qjs.c:529-561）实测本机（64 位，gcc -O2）：runtime+context 总分配 **158,352 字节 / 50 个 malloc 块**，其中原子表 588 项 25,303 字节、内建对象 164 个。内建是逐个 C 函数挂载而非反序列化，本身就在微秒-毫秒级；qjs.c:538-561 内置了 best-of-100 的四阶段实例化计时器（NewRuntime/NewContext/Free×2），正是官方展示"实例化亚毫秒"的口径。
2. **预编译字节码随二进制发布**：REPL（qjsc_repl）、以及用户用 qjsc 嵌入的脚本（qjsc.c），启动时 `JS_ReadObject` 反序列化，跳过解析/AST。
3. **无 JIT**：省掉 V8 式基线编译和运行时类型反馈基建，首条指令即是解释执行，没有"预热"。

进程级墙钟（本 Windows 机器、同口径对比）：`qjs -q` 十次均摊约 0.33s，`node -e "0"` 约 0.08s——Windows 进程创建开销占绝对主导，此数字反映的是 exe 体积与加载（qjs 未裁剪、含符号），不代表引擎实例化成本；Linux 上的惯常量级（毫秒级冷启动）才是该设计的体现点。比较时务必区分"进程墙钟"与"引擎实例化"。

### 4.2 每操作开销：与 node（V8, v24.19.0）同机同题对比

gcc -O2 自建 qjs vs 官方 node v24.19.0，单进程内计时（os.now()/performance.now()），数字为单次采样、量级参考：

| 操作 | QuickJS | node 24 | 差距 |
|---|---|---|---|
| 1e6 次整型累加循环 | 13.9 ms | 2.0 ms | ~7x |
| push 1e5 个对象 | 15.0 ms | 4.7 ms | ~3x |
| JSON.stringify 3 属性对象 ×1e4 | 6.4 ms | 1.3 ms | ~5x |
| JSON.parse 小对象 ×1e4 | 6.6 ms | 5.2 ms | ~1.3x |
| JSON.parse 22KB/1000 元素 ×100 | 21.7 ms | 10.3 ms | ~2x |
| 正则 /ab+c/.exec ×1e4 | 1.2 ms | 0.5 ms | ~2.4x |
| 1000 元素 map ×100 | 4.7 ms | 0.7 ms | ~7x |
| 字符串拼接 ×1e4 | 0.5 ms | 0.3 ms | ~1.7x |

规律清晰：**C 层密集型操作（JSON.parse、正则匹配、字符串拼接）差距最小（1.3-2.4x）**——两侧都是原生代码；**解释器主导的通用计算（循环、map 回调）差距 3-7x**——这正是无 JIT 与多层编译（Ignition/Sparkplug/Maglev/Turbofan）的差距。注意 node 的数字含 JIT 预热，QuickJS 数字稳定无波动。内存侧，`-q -d` 显示空转态整体仅约 155KB（含 103 个 C 函数壳、115 个 shape），这是嵌入式场景的核心指标。

### 4.3 正则执行器：回溯机的代价与保险丝

`lre_compile`（libregexp.c:2522）产出自定义字节码，头部存 flags/捕获数/栈大小/码长（2549-2552）；非 sticky 正则自动外层包一个 `split_goto_first/any/goto` 循环实现"任意起点搜索"（2554-2562，注释称"为锁步线程优化留门"）。执行器 `lre_exec_backtrack`（2774）是**带回溯的虚拟机**：捕获保存走显式 `StackElem` 栈（SAVE_CAPTURE，2805-2812，带"已保存则不重复"优化 2815-2833），栈从 32 个元素的静态缓冲起步（2737）、按 1.5 倍增长（2754），耗尽返回 `LRE_RET_MEMORY_ERROR`（2797）——**回溯不烧 C 栈，不会栈溢出崩溃**。指数级最坏情形靠保险丝缓解：每 1 万条指令（`INTERRUPT_COUNTER_INIT`，libregexp.c:63）轮询一次超时回调 `lre_poll_timeout`（2740-2748），超时返回 `LRE_RET_TIMEOUT`；捕获组上限 255（`CAPTURE_COUNT_MAX`，59）。没有 irregexp/RE2 式线性时间引擎，灾难性回溯模式仍可能超时而不是快速失败。引擎经 `js_regexp_exec`（quickjs.c:48108，48159 调 lre_exec）接入，`[Symbol.replace]` 等 9 类方法复用同一字节码（49245-49249 一带）。

---

## 5. 设计动机

**为什么不做 JIT**：Bellard 在 readme 与多篇访谈口径一致——QuickJS 目标是嵌入式/低内存/快速启动场景，JIT 的代价是内存（代码缓存、类型反馈向量，通常数倍于解释器）、移植复杂度（需为每种架构写后端）与启动延迟。QuickJS 的 swap-file 式内存上限、`--stack-size` 控制（qjs.c:420-434）都只在解释器假设下成立。每操作 3-7x 的解释器开销换来的是约 600KB 级二进制、155KB 级运行态与确定性行为。同作者的 QuickJS-NG 与 quickjs-ng 社区也长期把 JIT 列为"非目标/实验"。

**REPL 的教育定位**：repl.js 有意用 JS 写行编辑器——它同时是 std/os 模块能力（终端 raw 模式、读处理器、信号）的展示窗口，也是"引擎能自宿主到什么程度"的活演示。每命令一次 `std.gc()`、结果绑定 `_`、`\t` 指令显示求值耗时，都是教学友好性设计；代价是无 readline 库的成熟手感（无多行粘贴保护、管道输入下逐键回显混乱，实测非 tty 场景体验退化）。

**单文件的可维护性**：核心引擎 quickjs.c 一文 61,424 行、加 libc 4,403 行与 libregexp 3,448 行，全仓库 C 代码不足 8 万行、无第三方依赖（连 libregexp 都是自研）。JSON、正则、REPL 三者共同印证同一哲学：能复用就不新建（JSON 复用 JS 词法器、REPL 复用 JS_Eval、正则字节码复用 dbuf），能自研就不引入（正则引擎、行编辑器、dtoa）。这使得单人可审计全文，是"单文件"而非"monolith"的选择。

**调试支持现状**：上游无调试器。`debugger` 语句被解析后直接跳过（quickjs.c:29624-29625，注释原文 "currently no debugger, so just skip the keyword"）。没有断点 API、没有 Inspector/CDP 协议。现有的可观测性工具是：中断处理器（Ctrl-C 变异常）、`-T` 分配跟踪与 `-d` 内存转储（qjs.c:400-407、529-533）、`JS_ComputeMemoryUsage/JS_DumpMemoryUsage`、回溯屏障与 `JS_PrintValue` 检视器、`JS_SetStripInfo` 裁剪调试信息（qjs.c:467）。社区有若干为 QuickJS 加 CDP/断点的 fork，均非上游。

**与 D8/node（V8 系）的架构差异汇总**：

| 维度 | QuickJS | V8 (d8/node) |
|---|---|---|
| 代码组织 | 6 个 C 文件、无依赖、单翻译单元 61k 行 | 数千文件、多组件（解析器/Ignition/编译管线/GC/API 层） |
| 执行层 | 单层字节码解释器（switch 型） | 解释器 + Sparkplug/Maglev/Turbofan 多层 |
| 正则 | 自研回溯 VM（libregexp） | irregexp，可编译为原生码 |
| 启动 | 无 snapshot，C 初始化 + 预编译字节码；实例化亚毫秒/155KB | 启动 snapshot 反序列化内建对象图 |
| REPL | JS 自宿主，词法多行判定，完成值语义 | d8 简易壳；node 另行实现完整 CLI/REPL |
| 调试 | 无（debugger 语句为 no-op） | Inspector 协议、CDP、断点/采样分析器 |
| JSON | 解析复用 JS 词法器；reviver 源文本扩展 | 独立 C++ 解析器，无 source 扩展 |
| 内存 | malloc 抽象 + 硬上限 + 每对象可审计 | 分区堆、指针压缩、大型 GC 基建 |

---

## 6. FAQ 素材与深挖方向

### FAQ（8-10 条）

1. **JSON.parse 带 reviver 时性能差多少？** 多一整趟内部化递归加一棵 JSONParseRecord 镜像树（quickjs.c:49824-49855）；无 reviver 时零开销直通（49858）。
2. **JSON.stringify 遇到循环引用会怎样？** `TypeError: circular reference`，检测方式是序列化栈数组做 includes（quickjs.c:50106-50112），O(深度×栈长)。
3. **undefined、函数、Symbol 序列化时去哪了？** 对象属性中被直接丢弃（js_json_check 返回 undefined 后 50185 跳过），数组中变 `null`（50153-50154）；NaN/Infinity 变 null（50221-50225）。
4. **replacer 数组里的非字符串元素怎么办？** 数字转字符串，String/Number 包装对象拆箱，其余丢弃并去重（50286-50321）。
5. **space 参数怎么变成缩进？** 数字 clamp 到 0-10 取前 n 个空格，字符串截前 10 字符（50337-50347）。
6. **REPL 怎么知道我还没输完？** 不靠解析错误，靠 `colorize_js` 的括号计数与字符串/模板/注释/正则状态栈（repl.js:1285 返回，986 判定）；所以 `1+` 会立刻报语法错误而非续行。
7. **REPL 打印 `1+1` 得 2，但我输 `var z=5` 怎么是 undefined？** 全部按脚本完成值语义求值（quickjs-libc.c:910-915），var 声明的完成值就是 undefined；`1+1; var q;` 仍是 2（完成值取最后一条语句）。
8. **`_` 是什么？** REPL 把上一结果赋给全局 `_`（repl.js:1034），类似 node 的 `_`。
9. **`debugger` 语句无效？** 上游无调试器，语句被跳过（quickjs.c:29624-29625）；可用的只有中断处理器、内存转储与回溯屏障。
10. **正则回溯会把进程卡死吗？** 不会永久卡死：每 1 万条指令查一次超时中断（libregexp.c:2740-2748，阈值在 63），配合 `os` 超时回调可退出；但无线性时间保证，灾难回溯会慢到超时而非快速失败。
11. **为什么 import JSON 模块不需要额外 JSON5 库？** 模块加载器对 `.json` 与 `type:"json5"` 属性分别以严格/扩展模式调 JS_ParseJSON2（quickjs-libc.c:703-716）。

### 深挖（3-5 条）

1. **JSONParseRecord 的哈希表演进**：从线性扫描到 `1 << (32-clz32(count))` 桶数的链式哈希（quickjs.c:49416-49421、49381-49403），分析它对大对象 reviver 场景的摊还成本，以及 `json_parse_record_find`（49435）在第二趟内部化时的命中路径。
2. **`source` 文本恢复的边界**：`primitive.source_pos/source_len` 直接指向原始缓冲（49608-49610），数字字面量的 `source` 保留原拼写（如 `0x10`、`1e2`）——实测并对照 RawJSON 提案讨论其规格化含义。
3. **回溯 VM 的栈布局**：`StackElem` 用 intptr 低位复用状态类型（libregexp.c:2710-2723），SAVE_CAPTURE_CHECK 的"栈上已存则免存"（2815-2833）对嵌套量词（`(a+)+` 类）回溯量的影响；可写一篇"回溯栈即时间机器"。
4. **REPL 词法判定与真实解析器的一致性**：构造 colorize_js 误判而解析器不同意的输入（如对象字面量 vs 块语句的 `{` 歧义），验证续行判定的假阳/假阴边界（repl.js:1250-1266 的 level 逻辑）。
5. **启动路径全链路计时**：用 `-q -d` 的四阶段计时器（qjs.c:538-561）+ `JS_ComputeMemoryUsage` 快照，对比"裸实例化 / +std+os / +REPL 字节码实例化"三档的分配块数与字节，量化"无 snapshot 的快"到底快在哪。

---

## 写作要点速查表

| # | 函数/结构 | 位置 | 一句话 |
|---|---|---|---|
| 1 | json_parse_value | quickjs.c:49484 | JSON 递归下降主循环，对象/数组/原始值分支 |
| 2 | json_next_token / json_parse_string | quickjs.c:23477 / 23305 | JSON 词法器，复用 JSParseState，ext_json 开关 |
| 3 | JSONParseRecord（结构体） | quickjs.c:49336-49349 | reviver 源文本镜像树：obj/array/primitive 三态 |
| 4 | json_parse_record_add | quickjs.c:49405（阈值 49417） | <8 条目线性扫描，≥8 建链式哈希 |
| 5 | internalize_json_property | quickjs.c:49709（三参调用 49802，source 49786） | 第二趟 reviver 内部化，context.source |
| 6 | JS_ParseJSON3 / js_json_parse | quickjs.c:49670 / 49814 | 顶层解析入口 / parse 实现与两趟调度 |
| 7 | js_json_check | quickjs.c:50001 | toJSON(50009)+replacer(50024) 预处理钩子 |
| 8 | js_json_to_str | quickjs.c:50059（循环检测 50106-50112） | 序列化递归；stack 数组查环 → circular reference |
| 9 | JS_JSONStringify | quickjs.c:50251（gap 50337，wrapper 50351） | stringify 入口：replacer/space/属性表预处理 |
| 10 | js_evalScript | quickjs-libc.c:880（flags 910-915） | REPL 求值后端：GLOBAL+BACKTRACE_BARRIER+ASYNC |
| 11 | handle_cmd / colorize_js | repl.js:960 / 1057（返回 1285） | 多行判定：mexpr 累积 982 + 词法 state/level |
| 12 | print_eval_result | repl.js:1011（`_` 1034，gc 1053） | 完成值打印、\x 十六进制、每命令 GC |
| 13 | readline_start | repl.js:779（ps1 87 / ps2 88） | 行编辑会话；续行提示符=4×level 空格（950） |
| 14 | JS_PrintValueSetDefaultOptions | quickjs.c:14401 | 检视器默认：深度 2 / 串长 1000 / 项数 100 |
| 15 | js_regexp_exec → lre_exec | quickjs.c:48108(48159) → libregexp.c:3326 | 正则接入点与执行入口 |
| 16 | lre_compile | libregexp.c:2522（非 sticky 外循环 2554-2562） | 正则→字节码；头 2549-2552 |
| 17 | lre_exec_backtrack | libregexp.c:2774（栈护栏 2792，超时 2740，阈值 63） | 显式栈回溯 VM；LRE_RET_MEMORY/TIMEOUT |
| 18 | TOK_DEBUGGER 跳过 / REPL 装载 | quickjs.c:29624-29625 / qjs.c:522-525 | 无调试器；qjsc_repl 字节码引导交互模式 |

*启动内存与对比数据为 commit 04be246 源码 gcc -O2 自建二进制在 Windows(x64) 单机实测，量级参考用；引擎实例化基准以 qjs.c:538-561 内置计时器口径为准。*
