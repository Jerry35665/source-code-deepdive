# K — QuickJS 的 REPL 架构与性能特征

> 调研对象:quickjs @ commit `04be246` (VERSION 2026-06-04,2026-06-16)。
> 所有行号均为仓库相对路径 `文件:行号`,经 grep/Read 实际核对。
> 实测环境:Windows x64,gcc 16.2 (w64devkit,`make` 默认 `-O2`,非 LTO)构建;qjs 与 node v24.19.0 同机对比。

---

## 1. 全景:REPL 架构

QuickJS 的交互式解释器是一个**自宿主 (self-hosting) 设计**:C 壳只负责把引擎跑起来,行编辑、着色、多行判定、结果打印全部写在 `repl.js` 里,由 `qjsc` 预编译成字节码数组 `qjsc_repl` 链进可执行文件。

```
        终端 (raw mode tty)
   stdin │ 字节流(UTF-8)        ▲ ANSI CSI 转义序列(光标/清行/颜色)
         ▼                       │
┌───────────────── qjs.exe:C 壳 ────────────────────────┐
│ main (qjs.c:314)                                       │
│  ├─ JS_NewRuntime          原子表+50 个类 (qjs.c:2067) │
│  ├─ JS_NewCustomContext    11 个 intrinsic (qjs.c:107) │
│  ├─ js_std_add_helpers     print/console/scriptArgs    │
│  │                         (quickjs-libc.c:4098)       │
│  └─ 交互模式: js_std_eval_binary(qjsc_repl)           │
│       (qjs.c:524 → quickjs-libc.c:4353)                │
│         │  JS_ReadObject 反序列化 14347 字节字节码     │
│         │  (repl.c:5,由 qjsc 从 repl.js 预编译,       │
│         │   Makefile:320-321)                          │
│         ▼                                              │
│  ┌───────── repl.js:纯 JS 的 REPL ─────────────┐      │
│  │ termInit   raw tty+SIGINT+读句柄 (repl.js:114)│      │
│  │ handle_byte→handle_char→handle_key           │      │
│  │            ESC/CSI 状态机   (repl.js:803)     │      │
│  │ handle_cmd  \指令分发+多行判定 (repl.js:960)  │      │
│  │ eval_and_print_start → std.evalScript         │      │
│  │   {backtrace_barrier, async:true} (repl.js:1003)     │
│  │ print_eval_result → std.__printObject→g._     │      │
│  │                            (repl.js:1029-1034)│      │
│  └───────────────────────────────────────────────┘      │
│  js_std_loop: 轮询 job 队列与读句柄 (qjs.c:526)        │
└─────────────────────────────────────────────────────────┘
```

进入交互模式有两条路:无参数启动时 `optind >= argc` 置 `interactive = 1` (qjs.c:513-515);或显式 `-i` (qjs.c:384-387)。真正启动 REPL 的是这一行:

```c
/* qjs.c:522-526 */
if (interactive) {
    JS_SetHostPromiseRejectionTracker(rt, NULL, NULL);
    js_std_eval_binary(ctx, qjsc_repl, qjsc_repl_size, 0);
}
js_std_loop(ctx);
```

注意 REPL 之前 `js_std_add_helpers` (qjs.c:485) 已注入 `print`/`console.log`/`scriptArgs`/`performance.now` (quickjs-libc.c:4098-4130),而 `std`/`os` 模块在 `JS_NewCustomContext` 里初始化 (qjs.c:114-115),repl.js 顶部 `import * as std/os` 后立刻挂回 `globalThis` (repl.js:25-31)。

每条输入的生命周期:`handle_key` 识别回车 → `accept_line` 返回 -1 → `readline_cb(cmd)` → `handle_cmd` (repl.js:953-995):先处理 `\` 指令,再做 `colorize_js` 判定是否多行,单行则 `eval_and_print_start` → `std.evalScript` → promise 回调打印 → `handle_cmd_end` 强制 `std.gc()` 后重新起提示符 (repl.js:1050-1055)。

## 2. REPL 专节

### 2.1 行编辑:不用任何外部库

没有 readline/ncurses/libuv。C 侧只提供两个原语:`os.ttySetRaw` 把终端置 raw 模式 (repl.js:126-129,实现在 quickjs-libc.c:1861/1909),`os.setReadHandler` 注册 stdin 可读回调 (repl.js:137,quickjs-libc.c:2014)。其余全在 JS:每字节经 `handle_byte` 做 UTF-8 增量解码 (repl.js:152-168),解码成字符后走 `handle_char` 的 ESC/CSI 小状态机 (repl.js:803-839),查 `commands` 哈希表分发:

```js
/* repl.js:709-723(节选) */
var commands = {        /* command table */
    "\x01":     beginning_of_line,      /* ^A - bol */
    "\x03":     control_c,              /* ^C - abort */
    "\x04":     control_d,              /* ^D - delete-char or exit */
    "\x09":     completion,             /* ^I - tab 补全 */
    "\x0e":     next_history,           /* ^N - down */
    "\x10":     previous_history,       /* ^P - up */
    "\x1b[A":   previous_history,       /* ^[[A - up */
    ...
```

共约 50 个键位 (repl.js:709-758),包括 emacs 风格的 kill/yank (`kill_region`/`yank`,repl.js:505-540)、单词跳转、转置、历史前缀搜索 (repl.js:407-425)。Ctrl-C 是 SIGINT 处理器转投 `handle_byte(3)` (repl.js:133,140-143),连按两次退出 (repl.js:542-550);Ctrl-D 空行时返回 -3 退出循环并卸载处理器 (repl.js:454-461,858-862)。屏幕刷新 `update()` 有个常见情形优化:光标前缀未变时只增量补打印 (repl.js:272-275),否则 `move_cursor` 用 CSI 序列回退后整行重画 (repl.js:234-265)。

### 2.2 多行判定与提示符

多行不是数括号计数器那么简单,而是复用了语法着色器:`colorize_js(str)` 是一个单遍词法扫描器,返回 `[state, level, r]` ——state 是未闭合结构栈(字符串/正则/块注释/括号),level 是未闭合括号深度,r 是逐字符样式数组 (repl.js:1057-1286,返回点 1285)。`handle_cmd` 拿到非空 `pstate` 就把输入暂存 `mexpr` 并返回 false 继续读:

```js
/* repl.js:983-991 */
colorstate = colorize_js(expr);
pstate = colorstate[0];
level  = colorstate[1];
if (pstate) {
    mexpr = expr;
    return false;      /* 继续多行输入 */
}
mexpr = "";
```

因此 `function f() {`、未闭合的模板串、甚至跨行的块注释都会正确续行;续行提示符是 `ps2 = "  ... "` (repl.js:88),由 `readline_start` 按 `mexpr` 是否非空切换 (repl.js:787-797),且 `level` 个未闭合括号被渲染成 4 空格缩进 `dupstr("    ", level)` (repl.js:950)。正则/除号的歧义由 `can_regex` 启发式处理:关键字后不能是正则、标识符后是除号 (repl.js:1168,1201,1237-1242)。

### 2.3 颜色着色

色表是硬编码的 ANSI 序列:16 色 `colors` (repl.js:42-61) 加 12 种语义 `styles`(keyword/string/regex/number/function/type/comment/error/result 等,repl.js:63-76),`show_colors` 默认开 (repl.js:91)。`colorize_js` 输出每字符样式下标,`print_color_text` 把连续同样式段包上 `\x1b[..m ... \x1b[0m` 打印 (repl.js:217-227)。结果行用 `styles.result`(bright_white),错误行 `styles.error_msg`(bright_red)。着色不仅服务显示,还服务多行判定与缩进(见上),一份解析三处消费。

### 2.4 结果打印:值序列化、截断与 `_`

打印走 `std.__printObject(result)` (repl.js:1029),C 侧薄封装直接调 `JS_PrintValue` (quickjs-libc.c:1209-1216)。序列化器在 quickjs.c,默认截断参数:

```c
/* quickjs.c:14403-14408 */
void JS_PrintValueSetDefaultOptions(JSPrintValueOptions *options)
{
    memset(options, 0, sizeof(*options));
    options->max_depth = 2;              /* 嵌套深度 2 层 */
    options->max_string_length = 1000;   /* 字符串截到 1000 */
    options->max_item_count = 100;       /* 每层最多 100 项 */
}
```

超限呈现:更深时打印 `[ClassName]` (quickjs.c:14374-14380,硬上限 `JS_PRINT_MAX_DEPTH`=8,quickjs.c:13678);循环引用 `[circular N]` (quickjs.c:14368);长字符串 `"... N more characters"` (quickjs.c:13825-13828);多余项 `"... N more items"` (quickjs.c:13922)。数字/函数/BigInt 各有专用格式(如 bigint 超短路径直接打 limb 十六进制,quickjs.c:14322-14337)。每次求值结果同时绑定到 `globalThis._` 供回看 (repl.js:1034)。`\x`/`\d` 切换整数十六进制/十进制显示 (repl.js:914-917,1017-1027)。

### 2.5 历史、补全与指令

**历史没有持久化**:`history` 只是模块级数组 (repl.js:78),`history_add` 仅 `push` (repl.js:381-386),进程退出即丢——对比 bash/node 的 `~/.xxx_history` 落盘,这是明确的功能留白。补全 `completion` (repl.js:650-707) 沿原型链取 `Object.getOwnPropertyNames`(最多 10 层,repl.js:613),下划线开头的排后去重 (repl.js:625-643);二次 Tab 列表时函数自动补 `(`、对象补 `.` (repl.js:671-681)。反斜杠指令集:`\h` 帮助、`\load file`、`\x`/`\d` 进制、`\t` 计时开关、`\clear`、`\q` (repl.js:903-941),`\t` 打开后提示符前缀显示上次求值毫秒数 (repl.js:791-794,计时源 `os.now()`,repl.js:1001,1015)。

### 2.6 REPL 里的引擎协议细节

每条命令用 `std.evalScript(expr, { backtrace_barrier: true, async: true })` 求值 (repl.js:1003)。两个开关都有讲究:`JS_EVAL_FLAG_ASYNC` (quickjs.h:347) 让普通脚本允许顶层 await——实现上是解析期把整个程序包成 async 函数体 (`fd->func_kind = JS_FUNC_ASYNC`,quickjs.c:37258-37261),`JS_Eval` 返回 promise,JS 侧 `.then(print_eval_result, print_eval_error)`;`backtrace_barrier` 让错误栈不带 `<evalScript>` 帧。此外 `js_evalScript` 在进入时挂 SIGINT 中断处理器、退出时把不可捕获的 "interrupted" 转成普通异常,这样 Ctrl-C 打断长循环才能被 REPL 的 try/catch 接住 (quickjs-libc.c:906-931)。每条命令后强制 `std.gc()` → `JS_RunGC` (repl.js:1053,quickjs-libc.c:853-857),保证交互会话内存可观测、不漂移。

## 3. 启动分析专节

### 3.1 启动路径与分解实测

C 壳路径:`JS_NewRuntime`→`JS_NewRuntime2` (quickjs.c:2067-2123):初始化 malloc 记账、`JS_InitAtoms` (quickjs.c:2091)、`init_class_range` 注册 50 个内置类 (quickjs.c:2096,类表 js_std_class_def 在 quickjs.c:1971-2023,JS_CLASS_OBJECT=1 至 JS_CLASS_RAWJSON=50)。随后 `JS_NewContext` 依序调 11 个 `JS_AddIntrinsic*` (quickjs.c:2627-2649):BaseObjects/Date/Eval/StringNormalize/RegExp/JSON/Proxy/MapSet/TypedArrays/Promise/WeakRef。

用 QueryPerformanceCounter 写探针对同一进程内各阶段计时(300 次,每次完整 init+free):

| 阶段 | 平均 ms | 最小 ms |
|---|---|---|
| JS_NewRuntime(原子表+类表) | 0.011 | 0.005 |
| JS_NewContextRaw | 0.017 | 0.006 |
| 11 个 JS_AddIntrinsic*(建全局对象树) | 0.050 | 0.035 |
| JS_FreeContext | ~0 | ~0 |
| JS_FreeRuntime | 0.031 | 0.016 |
| **合计** | **0.110** | **0.062** |

结论:**引擎冷启动不足 0.1 ms,最慢的一步是 intrinsic 全局对象树构建**(约占总耗时一半)——它要 new 出几百个 C 函数对象并逐个定义属性。原子表初始化只是对静态表 `js_atom_init` (quickjs.c:1108-1111) 逐项 intern 242 个预定义原子(实测枚举值;quickjs.c:3090 注释 "at least 504 predefined atoms" 已过时)+ 首次哈希表 512 槽分配 (quickjs.c:3089-3090);**regexp 启动零预编译**——`JS_AddIntrinsicRegExp` 只创建 RegExp 构造器、原型和两个 shape (quickjs.c:49266-49298),正则字节码都延迟到首次 `new RegExp`。

### 3.2 那 qjs.exe 的壁钟时间花在哪?

同机 20 次 `qjs -e ''` 平均 ~130 ms、`node -e ''` ~82 ms;而空进程创建基线也在百毫秒级(Windows CreateProcess+加载 5.6 MB 二进制)。即:**qjs 的"启动慢"完全是 OS 进程模型的开销,引擎本身只占千分之一量级**。qjs 自带的分段计时器反证了这一点:`qjs -q -d` 走 100 轮取各阶段最小值的逻辑 (qjs.c:538-561) 在 Windows 上全部打印 0.000——`clock()` 粒度 1 ms,而每个阶段都小于 0.5 ms。

### 3.3 内存足迹与内部分析工具

`qjs -d` 调 `JS_ComputeMemoryUsage`/`JS_DumpMemoryUsage` (qjs.c:529-533,实现在 quickjs.c:6928/7224)。实测空跑引擎(`-q -d`)即 `qjs.c:538` 分支前的一次完整 init:

- malloc 总量 158,352 B、50 个块(裸引擎 init 后 155,408 B/48 块);
- 588 个原子(裸 init 515,差额来自 std/os/helpers 注册)、164 个对象、103 个 C 函数、115 个 shape;
- 结构体尺寸:JSRuntime 1440 B、JSContext 472 B、JSObject 64 B、JSString 20+4 B。

`JS_DumpMemoryUsage` 还会按类统计存活 JSObject、打印每种结构的 usable-size 开销 (quickjs.c:7236-7267)。另有 `-T` 全量分配跟踪:`trace_mf` (qjs.c:256-261) 把每次 malloc/free/realloc 打成 `A size -> H+offset.size` / `F` / `R` 行 (qjs.c:207,220,237),可离线重放分析;`--memory-limit n`/`--stack-size n` 直接落到 `JS_SetMemoryLimit`/`JS_SetMaxStackSize` (qjs.c:463-466)。qjs 没有 V8 式 heap snapshot,但这套 dump+trace 覆盖了"泄漏在哪、谁最大"两个基本问题。

### 3.4 运行期 GC 触发

`JS_RunGC` 是四遍标记清除:清弱引用 → `gc_decref` → `gc_scan` → `gc_free_cycles` (quickjs.c:6815-6837)。自动触发只有一个入口:`js_trigger_gc`,而它只在 `JS_NewObjectFromShape` 里被调 (quickjs.c:5619)——**每次对象分配**时检查堆量,超过阈值就 GC 并按 `size + size>>1` 重设水位:

```c
/* quickjs.c:1780-1797(节选) */
static void js_trigger_gc(JSRuntime *rt, size_t size)
{
    force_gc = ((rt->malloc_ctx.malloc_state.malloc_size + size) >
                rt->malloc_gc_threshold);
    if (force_gc) {
        JS_RunGC(rt);
        rt->malloc_gc_threshold = rt->malloc_ctx.malloc_state.malloc_size +
            (rt->malloc_ctx.malloc_state.malloc_size >> 1);
    }
}
```

初始阈值 256 KB (quickjs.c:2082)。策略偏保守(阈值 1.5 倍堆量),对分配密集代码会周期性付出 O(堆) 的停顿;REPL 干脆每条命令手动 GC 换取干净状态。

## 4. 性能对照专节:qjs vs node (V8)

同机运行仓库自带 `tests/microbench.js`(两种引擎通吃:qjs 用 `os.now`,node 用 `performance.now`,d8 用 `arguments`,microbench.js:88-105,1579-1589)。单位 ns/操作,取两者各自最优采样:

| 项目 | qjs | node | 倍数 |
|---|---|---|---|
| empty_loop(空循环) | 3.68 | 0.35 | 10.5x |
| prop_read / prop_write | 5.37 / 5.47 | 0.09 / 0.09 | ~60x |
| prop_create(对象分配+10 属性) | 31.05 | 5.21 | 6.0x |
| array_push | 29.33 | 1.45 | 20x |
| typed_array_write | 9.59 | 0.11 | 87x |
| func_call(单参函数调用) | 19.40 | 0.11 | 176x |
| int_arith / float_arith | 9.22 / 12.55 | 0.34 / 0.44 | 27-29x |
| regexp_ascii / regexp_utf16 | 123.8 / 130.6 | 27.8 / 27.4 | 4.4-4.8x |
| regexp_replace | 534.2 | 62.2 | 8.6x |
| map_set_int | 107.9 | 13.4 | 8.1x |
| string_build1(1000 次 +=) | 48.19 | 2.72 | 17.7x |
| string_to_int / int_to_string* | 50.0 / 24.3 | 0.43 / 0.09 | 116-270x |
| float_toString | 193.4 | 38.3 | 5.0x |
| **date_now** | **48.19** | **48.15** | **1.0x** |
| **date_parse** | **406.7** | **724.0** | **0.56x(qjs 反超)** |
| bigint64_arith | 23.21 | 11.81 | 2.0x |
| sort_bench(万级字符串排序) | 14.38 | 5.54 | 2.6x |

\* `int_to_string`/`float_to_string` 在 node 下结果未被消费,V8 JIT 死代码消除后只剩循环骨架,0.09 ns 是测量假象;换 `toString()` 方法调用后差距收敛到 5x (193 vs 38)。**带该保留意见的总体印象:microbench 全表累计 qjs 4236.7 vs node 1487.1,几何差距约 2.85x**,其中"解释器型操作"(调用、属性、控制流)差距 30-170x,"库函数型操作"(regexp/JSON/排序/bigint/Date)差距 1-9x——后者是 C 对 C 的比较,前者才是解释器 vs JIT 的真实鸿沟。

补充自测基准(153 KB / 2000 元素 JSON,200 次平均):

| 项目 | qjs | node | 倍数 |
|---|---|---|---|
| JSON.parse | 8.61 ns/B | 4.16 ns/B | 2.1x |
| JSON.stringify | 13.16 ns/B | 2.99 ns/B | 4.4x |
| 对象字面量分配 | 95 ns | 15 ns | 6.3x |
| 累加循环 5e6 次 | 15.4 ns/iter | 1.2 ns/iter | 12.8x |

对 d8 的说明:本机无 d8,但 d8 与 node 同为 V8(JIT 特性一致),microbench.js 显式支持 d8 (microbench.js:1583-1585),上表数字可直接代表与 D8 的量级差距。

**启动对比**:node 冷启动 ~80-100 ms 里有解释器初始化+内置模块快照加载;qjs 引擎部分 <0.1 ms,`repl.js` 字节码 (14347 B,repl.c:5) 反序列化同样亚毫秒。两者 CLI 壁钟差异主要是各自的进程与 I/O 开销,引擎侧 qjs 反而显著更轻——这正是它面向嵌入/短命进程场景的设计点。

## 5. 设计动机

**为什么 REPL 用 JS 写**:其一,行编辑器要频繁做"JS 语法感知"(多行判定、着色、补全上下文对象求值 `get_context_object` 甚至直接 `eval`,repl.js:585-594),用宿主语言写在引擎之上最自然;其二,自宿主是引擎的免费冒烟测试——repl.js 每次启动都在 exercising 模块加载、异步、Uint8Array、正则;其三,C 侧几乎零维护:终端协议(ANSI/UTF-8)全部在 39 KB 的 repl.js 里,C 壳只暴露 `ttySetRaw`/`setReadHandler` 两个系统调用。代价是 REPL 依赖 std/os 模块与异步作业循环,且行编辑器无法在引擎崩溃时自救。

**为什么性能差距可以接受**:QuickJS 的目标场景是嵌入式脚本、配置/插件解释、CLI 工具、短命进程——特征是"启动一次、跑少量逻辑、退出"。这些场景下启动延迟和内存足迹(空引擎 155 KB)远比吞吐重要;而计算密集的库代码(JSON/regexp/sort)是 C 实现,差距只有个位数倍。解释器形态换来的确定性收益:无 JIT 预热、无后台编译线程、内存上界可静态承诺、`--memory-limit` 硬配额即可靠 (quickjs.c:463-464)。

**为什么不做 JIT**:JIT 需要可写可执行内存 (W^X 冲突,被 iOS/多数沙箱禁止)、数倍于解释器的代码体积、以及指数级增长的移植面——QuickJS 明确以"最小依赖、可审计、到处能跑"为约束。作者选择的替代是极致的解释器工程:扁平字节码+直接线程化 dispatch、短字符串内联 (JSValue 标签打包)、shape 隐藏类、以及 `JS_EVAL_FLAG_ASYNC` 这类零成本语法级特性。实测中 qjs 输给 V8 的主要是"每条指令的派发成本"(函数调用 176x),这不是微调能弥合的量级,只能靠架构换——项目选择了不换。

## 6. FAQ 素材

1. **qjs 的行编辑用的是 readline 库吗?** 不是。零外部依赖,行编辑器整个用 JS 写在 repl.js,键位表 `commands` 覆盖约 50 个键 (repl.js:709-758),终端 raw 模式靠 `os.ttySetRaw` (repl.js:126-129)。
2. **命令历史会存盘吗?** 不会。`history` 是内存数组 (repl.js:78),`history_add` 只 push (repl.js:381-386),退出即失。
3. **REPL 怎么判断该续行?** 复用语法着色器:`colorize_js` 返回未闭合结构栈 state 与括号深度 level (repl.js:1285),`handle_cmd` 见 state 非空就暂存 `mexpr` 续读 (repl.js:984-989);level 同时渲染为续行缩进 (repl.js:950)。
4. **表达式结果是怎么打印出来的?** REPL 侧 `std.__printObject` (repl.js:1029) → 引擎侧 `JS_PrintValue`,默认深度 2 层、字符串 1000 字符、每层 100 项 (quickjs.c:14403-14408),更深显示 `[Object]`,循环显示 `[circular N]` (quickjs.c:14368)。
5. **REPL 支持顶层 await 吗?** 支持。`evalScript` 传 `async:true` (repl.js:1003) 映射 `JS_EVAL_FLAG_ASYNC` (quickjs.h:347),整个脚本被包成 async 函数体 (quickjs.c:37258-37261),求值返回 promise。
6. **`qjs -e '1+2'` 为什么什么都不输出?** `eval_buf` 只在异常时 dump 错误 (qjs.c:49-76);隐式打印是 repl.js 的逻辑,只有交互模式或 `-i` 才有。
7. **REPL 每条命令后都发生什么?** 打印结果绑到 `globalThis._` (repl.js:1034),然后强制 `std.gc()` (repl.js:1053 → quickjs-libc.c:853) 再重新出提示符。
8. **引擎启动到底要多久?** 实测同一进程内 init+free 全程最小 0.062 ms、平均 0.110 ms;最贵阶段是 11 个 intrinsic 建全局对象树 (~0.05 ms)。CLI 的百毫秒壁钟几乎全是 OS 进程创建。
9. **有没有 malloc_stats 类工具?** 有三件套:`-d` 内存 dump (quickjs.c:7224)、`-T` 逐次 A/F/R 分配跟踪 (qjs.c:207)、`--memory-limit` 硬配额 (qjs.c:463)。运行期 GC 只在对象分配处按 256 KB 起步、1.5 倍堆量回水位触发 (quickjs.c:2082,1780-1797)。
10. **`qjs -q -d` 的 Instantiation times 为什么全是 0.000?** 它用 `clock()` 计时 (qjs.c:543-551),Windows 粒度 1 ms,而各阶段真实耗时 <0.5 ms,取 100 次最小值全被截成 0;要可信数字需 QueryPerformanceCounter 级时钟。

## 7. 深挖线索

1. **GC 与分配的单点耦合**:`js_trigger_gc` 全仓库唯一调用点是 `JS_NewObjectFromShape` (quickjs.c:5619),意味着只有"新对象"驱动 GC——纯字符串/数组缓冲膨胀不触发,极端程序可绕过阈值;解释它为何还需要 REPL/脚本尾部的手动 `std.gc()`。
2. **REPL 的 Ctrl-C 协议**:`js_evalScript` 进入时挂中断处理器、退出时把不可捕获 "interrupted" 异常转普通异常 (quickjs-libc.c:906-931),与 repl.js 的 SIGINT→`handle_byte(3)` (repl.js:140-143) 和连按两次退出 (repl.js:542-550) 三层配合,是跨 C/JS 的完整中断链路,值得单独拆解。
3. **着色器即解析器**:`colorize_js` 的 `can_regex` 启发式 (repl.js:1168-1201) 与引擎真实 tokenizer 的 regex 判定并不完全一致(如 `if(x)/re/` 边界),它是多行判定的事实来源——构造让着色器误判的多行输入即可制造"REPL 认为没写完"的假象。
4. **原子表的生命周期**:预定义 242 原子 → intrinsics 期间涨到 515 → qjs 全量启动 588 (实测);`JS_InitAtoms` 首哈希 512 槽 (quickjs.c:3090) 与过时注释 "at least 504" 的历史演化可作代码考古素材。
5. **microbench 方法学陷阱**:node 下 `int_to_string`/`float_to_string` 被 DCE(0.09 ns/iter 假数据),`bench()` 用最短采样+`global_res` 防 DCE 但没覆盖所有用例 (microbench.js:135-162,167)——引用微基准数字前先核对每项是否真的逃逸。

## 8. 写作要点速查表

| 主题 | 位置 | 要点 |
|---|---|---|
| REPL 字节码入口 | qjs.c:522-526 | `js_std_eval_binary(qjsc_repl)`;无文件参数时 interactive=1 (qjs.c:513-515) |
| 字节码本体 | repl.c:5-6;Makefile:320-321 | 14347 B,`qjsc -s -c -m repl.js` 生成 |
| C 壳上下文 | qjs.c:107-117 | `JS_NewCustomContext`:`JS_NewContext`+std/os 模块 |
| 全局助手 | quickjs-libc.c:4098-4130 | print/console.log/scriptArgs/performance.now |
| 终端初始化 | repl.js:114-138 | ttySetRaw+SIGINT+setReadHandler |
| 键位表 | repl.js:709-758 | ~50 键,纯 JS 行编辑 |
| 多行判定 | repl.js:983-991;1285 | `colorize_js`→`[state,level,r]`,state 非空续行 |
| 着色 | repl.js:42-76;217-227 | colors+styles 两级表;print_color_text |
| 截断默认值 | quickjs.c:14403-14408;13678 | depth 2/string 1000/items 100;硬上限 8 |
| 循环引用/超限显示 | quickjs.c:14368;13825;13922 | `[circular N]` / more characters / more items |
| 结果绑定 `_` | repl.js:1034 | `g._ = result` |
| 每命令 GC | repl.js:1050-1055 | `handle_cmd_end`→`std.gc()` |
| evalScript 语义 | quickjs-libc.c:880-933 | backtrace_barrier/async/中断处理器安装 |
| 顶层 await | quickjs.h:347;quickjs.c:37258-37261 | 脚本包成 async 函数体 |
| 运行时构造 | quickjs.c:2067-2123 | 原子表(2091)+50 类表(2096);GC 阈值 256KB(2082) |
| Context intrinsics | quickjs.c:2627-2649 | 11 个 AddIntrinsic,启动最贵阶段 |
| 原子初始化 | quickjs.c:3078-3103 | 242 预定义(实测),首哈希 512 槽 |
| GC 触发 | quickjs.c:1780-1797;5619 | 唯一触发点=对象分配;水位 size*1.5 |
| 启动自测计时 | qjs.c:538-561 | clock() 在 Windows 全 0,粒度陷阱 |
| 内存 dump | quickjs.c:6928;7224;qjs.c:529-533 | 空引擎 155 KB/48 块/588 原子(实测) |
| 微基准 | tests/microbench.js:1435-1504 | 66+ 项;qjs 累计 2.85x 慢;date_parse 反超 |
