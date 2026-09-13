# F — 内置库与工程:quickjs-libc、BigInt/dtoa、qjs/qjsc 与单人项目的发布纪律

> 调研对象:bellard/quickjs,commit `04be246`(VERSION 2026-06-04,shallow clone)。所有行号以该 commit 为准,经 grep/Read 实际核对。
>
> **重要更正(相对章节提纲)**:该 commit 的仓库里**没有 libbf.c**。Changelog 记载 2025-04-26 版本"removed the bignum extensions and qjscalc"、"new BigInt implementation optimized for small numbers"(Changelog:17-19)。BigFloat/BigDecimal 两个提案实现随 libbf 一并删除,BigInt 改为 quickjs.c 内置的专用实现。同理,dtoa.c **不是** David Gay 的 dtoa,而是 Bellard 2024 年为替代 libbf 的浮点打印自写的"Tiny float64 printing and parsing library"(dtoa.c:3-4)。本章按代码现状如实展开,历史 libbf 仅作背景交代。

---

## 1. 全景:嵌入 JS 的宿主义务

QuickJS 核心只提供语言引擎;文件、进程、时间、网络、worker、事件循环全部是"宿主"的事。构建产物只有 `qjs / qjsc / run-test262` 三个程序加静态库(Makefile:215, 225),核心库对象固定为 quickjs/dtoa/libregexp/libunicode/cutils/quickjs-libc 六个编译单元(Makefile:252)。qjs 这个官方宿主本身的组装顺序,就是一份"嵌入说明书"(qjs.c:453-536):

```
JS_NewRuntime() ............................. 隔离堆:GC、atom 表、内存限额的根
  │  JS_SetMemoryLimit / JS_SetMaxStackSize .. (可选)沙箱两件套   qjs.c:463-466
  │  JS_SetStripInfo ......................... 决定字节码保留哪些调试信息 qjs.c:467
  ├─ js_std_init_handlers(rt) ................ 宿主状态:timers/信号/端口/拒绝列表
  │                                           (quickjs-libc.c:4133-4163,挂到 rt opaque)
  ├─ JS_SetSharedArrayBufferFunctions ........ SAB 跨线程引用计数回调
  │                                           (quickjs-libc.c:4152-4161)
  ├─ JS_SetModuleLoaderFunc2 ................. 告诉引擎"import 时找谁"
  │                                           (qjs.c:477, quickjs-libc.c:3634)
  ├─ JS_SetHostPromiseRejectionTracker ....... 未处理 rejection 的宿主策略 (qjs.c:479-482)
  └─ JS_NewContext() ......................... 全量 intrinsics (quickjs.c:2627)
      │  或 JS_NewContextRaw + JS_AddIntrinsicXXX 按需裁剪 (quickjs.h:397-410)
      ├─ js_init_module_std(ctx,"std") ....... 文件/printf/JSON5 (qjs.c:114)
      ├─ js_init_module_os(ctx,"os") ......... 进程/终端/timer/Worker (qjs.c:115)
      └─ js_std_add_helpers ................... print/console/performance/scriptArgs
                                               (quickjs-libc.c:4098-4131)
  跑脚本 → js_std_loop(ctx) .................. 宿主事件循环 (quickjs-libc.c:4292-4312)
  退出 → js_std_free_handlers → JS_FreeContext → JS_FreeRuntime
                                               (qjs.c:534-536, quickjs-libc.c:4165-4210)
```

关键认识:**`js_std_loop` 必须由宿主手动调用**。引擎只暴露 `JS_ExecutePendingJob`(promise 微任务)与回调钩子;"到点了叫 setTimeout 回调""fd 可读了叫 setReadHandler""worker 消息到了叫 onmessage"全靠宿主循环驱动(quickjs-libc.c:4296-4311)。qjsc 生成的 C 代码同样遵守这套义务:模板里固定输出 `js_std_init_handlers → JS_SetModuleLoaderFunc2 → js_std_add_helpers → js_std_eval_binary → js_std_loop → js_std_free_handlers`(qjsc.c:373-389, 845-851, 860)。

`JS_NewContext` 与 `JS_NewContextRaw` 的分野(quickjs.h:388, 397-410)是嵌入者省内存的旋钮;qjsc `-fno-xxx` 正是把它暴露成命令行(Makefile:394-396 的 hello 示例砍掉 RegExp/JSON/Date 等,feature 清单见 qjsc.c:67-78)。

## 2. libc 专节:std/os 的绑定面、worker 消息模型、事件循环

### 2.1 std 模块:文件与格式化

std 是 libc FILE* 的薄封装。API 表在 `js_std_funcs`(quickjs-libc.c:1645-1677):`exit/gc/evalScript/loadScript/getenv/setenv/unsetenv/getenviron/urlGet/loadFile/strerror/parseExtJSON`,文件族 `open/popen/fdopen/tmpfile/puts/printf/sprintf`,errno 常量表(1630-1643),以及 FILE 原型方法 `close/tell/seek/read/write/getline/readAsString/getByte/...`(1679-1696)。`File` 对象用 JSClassDef + finalizer 管理 `FILE*`(js_std_file_finalizer,937)。

几个值得点名的实现:
- `std.urlGet`(1469):libcurl 可用走 curl,否则退化到 popen 调 wget,零依赖实现"能联网"(quickjs-libc.c:1469-1490 区域)。
- `std.parseExtJSON`(967):JSON5 超集解析,2025-09-13 起兼容 JSON5 模块(Changelog:24-26)。
- `printf/sprintf`(1127-1133):复用 cutils 的格式化引擎,把 `%d %f %s` 之外的 JS 值按 `JS_PrintValue` 处理。

### 2.2 os 模块:进程、终端、时间

API 表 `js_os_funcs`(quickjs-libc.c:3927-4010):fd 读写 `open/close/seek/read/write`,终端 `isatty/ttyGetWinSize/ttySetRaw`,文件系统 `remove/rename/mkdir/readdir/stat/lstat/utimes/realpath/symlink/readlink`,进程 `exec/getpid/waitpid/pipe/kill/dup/dup2`(仅非 win32,3997-4009),信号 `signal` + SIG 常量(3951-3970),时间 `now/setTimeout/clearTimeout/sleepAsync`(3971-3974)与 `platform` 字符串(3915-3923, 3975)。

`os.exec`(3149)是 fork+execvp 全套:支持 `block:false` 非阻塞、`stdin/stdout/stderr` 重定向到 fd 或 "pipe"、`cwd/env/usePath` 选项(3159, 3196-3236);`os.signal` 把 C 信号转成挂到 `ts->os_signal_handlers` 的 JS 回调,真实信号处理函数 `os_signal_handler` 只置 `os_pending_signals` 位图(164),由轮询循环在安全点回调(2556-2571)——典型的"信号处理只做标记"纪律。

两个模块的 API 面速览(行号均为 quickjs-libc.c 中导出表的位置):

| 模块 | 组 | 成员(节选) | 导出表 |
|---|---|---|---|
| std | 环境/求值 | exit, gc, evalScript, loadScript, getenv/setenv/unsetenv/getenviron | 1645-1655 |
| std | 网络/文件读取 | urlGet(1469, curl→wget 退化), loadFile(466), parseExtJSON(967) | 1656-1659 |
| std | FILE 族 | open/popen/fdopen/tmpfile/puts/printf/sprintf + SEEK 常量 | 1660-1677 |
| std | File.prototype | close/puts/printf/flush/tell/seek/eof/fileno/read/write/getline/readAsString/getByte/putByte | 1679-1696 |
| os | fd/终端 | open/close/seek/read/write, isatty, ttyGetWinSize, ttySetRaw | 3928-3946 |
| os | 读写/信号 | setReadHandler/setWriteHandler(2014), signal + SIG 常量 | 3949-3970 |
| os | 时间 | now(2162), setTimeout(2175), clearTimeout(2216), sleepAsync(2234) | 3971-3974 |
| os | 文件系统 | getcwd/chdir/mkdir/readdir/stat/lstat/utimes/sleep/realpath/symlink/readlink | 3976-4000 |
| os | 进程 | exec(3149)/getpid/waitpid/pipe/kill/dup/dup2(非 win32) | 4001-4008 |
| os | Worker | Worker 构造器 + proto(postMessage/onmessage) | 4016-4042;3901-3904 |

### 2.3 Worker:每个 worker 一个独立 runtime,消息走序列化管道

worker 的线程模型回答了提纲的两个问题:

1. **是 JS_NewRuntime per worker**。`worker_func` 在新 pthread 里完整重演宿主义务:

```c
static void *worker_func(void *opaque)
{
    rt = JS_NewRuntime();                       /* 独立堆,独立 GC */
    JS_SetStripInfo(rt, args->strip_flags);
    js_std_init_handlers(rt);                   /* 宿主状态逐 runtime 一份 */
    JS_SetModuleLoaderFunc2(rt, NULL, js_module_loader, ...);
    ts = JS_GetRuntimeOpaque(rt);
    ts->recv_pipe = args->recv_pipe;            /* 接上与父线程的双向管道 */
    ts->send_pipe = args->send_pipe;
    ctx = js_worker_new_context_func(rt);       /* 函数指针避免强链 */
    ...
    val = JS_LoadModule(ctx, args->basename, args->filename);
    js_std_loop(ctx);                           /* worker 也有自己的事件循环 */
```
(quickjs-libc.c:3618-3667,摘录有省略;JS_NewRuntime 在 3626)→ 之后 `JS_SetModuleLoaderFunc2`(3634)、用函数指针 `js_worker_new_context_func` 建上下文(3641-3643,避免 worker 场景强链 JS_NewContext)→ 加载模块 → `js_std_loop`(3661)→ 全套释放(3663-3665)。**没有共享堆**:两套 runtime 之间零对象共享,GC 互不干扰,也就不需要跨线程锁引擎。

2. **消息传递 = 结构化序列化 + 管道,SharedArrayBuffer 是唯一按引用传的东西**。`new Worker(url)` 建两条 `JSWorkerMessagePipe`(3742-3747);`postMessage` 用 `JS_WriteObject2(..., JS_WRITE_OBJ_SAB | JS_WRITE_OBJ_REFERENCE)` 序列化(3797-3799),因为两侧 allocator 不同还特意 `malloc+memcpy` 拷一份(3809-3814),SAB 指针表 `sab_tab` 单独携带并增加引用计数(3816-3830)。SAB 本体由 `js_sab_alloc/free/dup` 管理——头部带原子 ref_count 的 malloc 块(3478-3519),通过 `JS_SetSharedArrayBufferFunctions` 注入引擎(4152-4161)。管道是 mutex 保护的链表队列 + "waker"(POSIX 用 `pipe` 自唤醒 fd,2306-2315;win32 用 `CreateEvent`,2282-2286),这正是事件循环能统一 `poll` 它们的机关。

限制同样诚实:worker 里不能再开 worker("cannot create a worker inside a worker",3713-3716);子线程通过 `Worker.parent` 拿到回传端口(4033-4038)。接收侧 `handle_posted_message` 用 `JS_ReadObject(JS_READ_OBJ_SAB|JS_READ_OBJ_REFERENCE)` 反序列化并调 `onmessage`(2357-2405)。

### 2.4 事件循环:为什么 setTimeout 需要手动 js_std_loop

`setTimeout` 只是往 `ts->os_timers` 链表挂一个 `{timer_id, timeout, func}`(结构定义 101-106;注册 2175-2201)——**它自己不会唤醒任何东西**。唯一的驱动点是 `js_os_poll`:POSIX 版把 fd 读写处理器(2600-2615)、worker 端口的 waker fd(2617-2625)和最近一次定时器超时(2577-2598)一起交给 `poll(2)`(2627),到期后逐个调 `call_handler`(2583-2591);win32 版等价地用 `WaitForMultipleObjects`(2422-2513)。

`js_std_loop` 则是标准的"排空微任务 → 检查未处理 rejection → poll 一次"死循环(4292-4312):

```c
void js_std_loop(JSContext *ctx)
{
    for(;;) {
        /* execute the pending jobs */
        for(;;) {
            err = JS_ExecutePendingJob(JS_GetRuntime(ctx), NULL);
            if (err <= 0) { ... break; }
        }
        js_std_promise_rejection_check(ctx);
        if (!os_poll_func || os_poll_func(ctx))
            break;                          /* 无事件可等:循环终止 */
    }
}
```
(quickjs-libc.c:4292-4311,摘录有省略)`poll` 返回 -1(没有任何 handler/timer/port)即退出循环——这解释了为什么 setTimeout 之后若不进循环,回调永远不会执行。未处理 promise rejection 的宿主策略很硬:挂进 `rejected_promise_list`(4240-4269),在下一次睡眠前的检查点 `js_std_promise_rejection_check` 打印并 **exit(1)**(4275-4288)——Changelog:22 记载 2025-04-26 起这从警告升级为致命。`js_std_await`(4317-4351)是顶层 await 的手动版,嵌入者可以拿去实现自己的"run to completion"。

模块加载器 `js_module_loader`(684-735)是宿主侧另一义务:`.so` 后缀走 `dlopen` + 约定符号 `js_init_module`(498-545;示例 examples/fib.c:59-70);`.json` 或带 `type:"json"/"json5"` 导入属性(656-682,属性校验 625-653)走 `JS_ParseJSON2`;其余 `JS_Eval(COMPILE_ONLY)` 编译后 `js_module_set_import_meta` 填 `import.meta.url/main`(548-599,realpath 仅在源码在场时使用,568-571)。注意它只做"按模块名直接 load 文件",**没有 node 式的路径搜索/后缀补全**——相对解析完全依赖引擎传来的规范化模块名,这也是"libc 是示例而非标准库"气质的一部分。

## 3. 大数专节:从 libbf 到内置 BigInt

### 3.1 历史:libbf 与 bignum 扩展的退役

2025-04-26 之前的 quickjs 链接 Bellard 自写的 libbf(Bellard 常年零外部依赖传统,也用于其 LibBF/bc 项目):`JSBigFloat` 沿用 bf 的任意精度浮点,并提供 BigFloat/BigDecimal 两个 TC39 提案实现与 qjscalc 应用。该版本起"removed the bignum extensions and qjscalc",同时"new BigInt implementation optimized for small numbers"(Changelog:17-19)。现在 BigInt 是 quickjs.c 内置的 ~1.5 千行实现(quickjs.c:11264-13600 一带),dtoa.c 则补上此前由 libbf 承担的精确浮点打印。

### 3.2 分层:机器字数组 → mp_ 原语 → js_bigint_ 语义

现行实现是教科书式三层:

- **表示层**(quickjs.c:466-502):limb(机器字)数组,类型随 `JS_LIMB_BITS` 切换(468-488,64 位时用 `__int128` 做双字乘除):

```c
typedef struct JSBigInt {
    uint32_t len;      /* number of limbs, >= 1 */
    js_limb_t tab[];   /* two's complement representation, always
                          normalized so that 'len' is the minimum
                          possible length >= 1 */
} JSBigInt;
```
(quickjs.c:490-495)二进制补码 + 恒规范化,使加减/位运算无须单独符号处理。小整数走 `JS_TAG_SHORT_BIG_INT` 直接内联在 JSValue 里(quickjs.h:73, 93),避免堆分配——这正是"optimized for small numbers"的主旨;`JSBigIntBuf` 栈上缓冲承接 64 位以内临时值(498-502)。
- **mp_ 原语层**:schoolbook 加减 `mp_add/mp_sub/mp_neg`(11313-11354)、`mp_mul1/mp_add_mul1`(11357, 11385)、`mp_mul_basecase`(11401, O(n·m) 逐 limb 乘加)、除法为标准 Knuth D 风格:先按除数最高位 clz 归一化左移,再 `mp_divnorm` 逐位试商(11432-11456 的 2-by-1 商估计,11489-11556 的主循环),移位原语 11559-11590。无 Karatsuba——Bellard 判断 BigInt 场景下 schoolbook 足够,代码量减半。
- **语义层**:`js_bigint_add/neg/mul/divrem/logic/not/shl/shr/pow`(11811-12290)。乘法在补码下直接乘后修正符号 limb(11868-11874);除法先取绝对值、归一化、试商,再按补码回填(11880-11979,除零在 11887-11890);`pow` 对 `2^n` 底数走移位捷径并防溢出(12105-12145)。规模上限 `JS_BIGINT_MAX_SIZE = 1MB 内存对应 limb 数`(11266),防止 `10n**10n**6n` 类炸弹。

字符串往返:`js_bigint_from_string`(12452)按 radix 累乘;`js_bigint_to_string1`(12634)对短 BigInt 走 `i64toa_radix` 快路径(12639),长值循环 `mp_div1` 抽位。`Number`→BigInt 的转换在 `js_bigint_from_float64`(12291):要求整数值,否则 RangeError,内部拆 double 尾数/指数后 `js_bigint_set_si64` 起步再移位(12333)。入口分派在二元运算慢路径:两个操作数都是 BigInt 时按 OP_add/OP_sub/OP_mul/OP_div/OP_mod/OP_pow 分派(15014-15054),结果经 `JS_CompactBigInt` 折叠回 short 形式。构造器 `js_bigint_constructor`(56232)与 `BigInt.asUintN/asIntN`(56287)构成 JS 面。

### 3.3 dtoa.c:自写的精确浮点打印

dtoa.c(2024,Bellard,dtoa.c:3-4;1620 行)提供 `js_dtoa`/`js_atod`(dtoa.h:66-68):FREE/FIXED/FRAC 三种格式 + 指数策略开关(dtoa.h:32-46),上限 101 位有效数字(dtoa.h:28)。核心是小型多精度缓冲 `mpb_t`:乘除 2^shift 后按 `JS_RNDN`(ties-to-even)等模式舍入(295-296, 313-366),`mul_pow_round_to_d` 完成 radix 幂与 float64 的往返(1003-1012)。引擎侧 `js_dtoa2` 分配 `js_dtoa_max_len` 缓冲调用之(quickjs.c:13563-13582);`Number.prototype.toString/toFixed` 与 JSValue→字符串打印(13635, 13718)都走这条路。Changelog:20 将其记为"builtin float64 printing and parsing functions for more correctness"。

## 4. qjs / qjsc 专节:REPL 与快启动链路

### 4.1 qjs:薄壳 + JS 化的 REPL

qjs 的 main(qjs.c:314)只做选项解析(手写 getopt,为了把命令行原样传给脚本,335-337)、runtime 装配与分发:`-e` 求值、文件执行(模块自动探测 `JS_DetectModule`,90-93)、`--memory-limit/--stack-size`(420-435, 463-466)、`-T` 内存跟踪分配器(197-261)、`-d` 内存统计,以及 `-qd` 的空转基准:100 次反复 NewRuntime/NewContext 计时(538-561)。

真正的 REPL **不在 C 里**:交互模式就是把 qjsc 预编译进二进制的字节码 `qjsc_repl` 跑起来(qjs.c:46-47 声明,522-524 执行;由 Makefile:320-321 的 `repl.c: $(QJSC) repl.js` 规则生成)。repl.js(1292 行)用 std/os 自己实现终端体验:raw 模式 `os.ttySetRaw` + `os.setReadHandler(term_fd, ...)` 读键(126-137),ANSI 着色 `colorize_js` 增量重绘(217-225, 278-282),多行编辑、^P/^N/^R/^S 历史导航(388-424)与 ^I 补全(718)。注意:历史只存在内存里(`var history = []`,78),**没有跨会话磁盘持久化**。另一个工程细节:`print()` 在 2025-09-13 后用 `JS_PrintValue` 美化非字符串值(4063-4087;Changelog:24)。

### 4.2 qjsc:JS → C 字节数组 → 独立可执行

qjsc 是"快启动"的全部秘密,三档输出(help 见 qjsc.c:393-427):

1. **字节码序列化**:`compile_file` 用 `JS_Eval(COMPILE_ONLY)` 编译(346-355),`output_object_code` 调 `JS_WriteObject(JS_WRITE_OBJ_BYTECODE)`(179-209,写出于 193),`dump_hex` 打成 C 数组(158-171)。`-x` 支持 `JS_WRITE_OBJ_BSWAP` 字节序交换(191-192),跨架构交叉编译时必需(配合 host-qjsc,Makefile:217-224, 288-292)。
2. **C 代码生成**:除字节数组外还生成一段 `main()` + `JS_NewCustomContext`(模板 373-389;上下文工厂 794-835):按 `-fno-*` 位图逐个 `JS_AddIntrinsicXXX`(802-809),静态注册的 C 模块(812-822)与依赖的 JS 模块字节码(823-832)在上下文创建时即初始化/求值,主脚本再以 `js_std_eval_binary(..., 0)` 执行(853-859)。默认 `JS_STRIP_SOURCE` 剥离源码(597),`-s` 全剥调试信息(712-714)。
3. **可执行**:`output_executable` 直接拼 cc 命令行链接 libquickjs.a(449-518),临时 C 文件放 `/tmp/out<pid>.c`(740-746)。

依赖闭包由 `jsc_module_loader` 在编译期收口:遇到 `-M` 声明的 C 模块就记名并放 dummy(247-252),`.so` 则警告将运行期动态加载并置 `dynamic_export`(253-259),JS 模块递归编译进数组(260-325)。所以 qjsc 产物启动时**零解析、零源码读取**,只有 `JS_ReadObject` + 实例化——`js_std_eval_binary` 的路径(quickjs-libc.c:4353-4384:ReadObject → ResolveModule → set_import_meta → EvalFunction → await)。

`JS_WriteObject/JS_ReadObject` 的格式(quickjs.h:980-996)因此有两个消费者:qjsc 的 C 数组与 worker 的 postMessage(见 2.3),一个序列化协议服务构建与 IPC 两个场景。

## 5. 工程专节:测试、fuzz、发布与沙箱

### 5.1 test262:runner、harness 与已知失败清单

- `make test2-bootstrap` 克隆固定 commit 的 test262 并打补丁(Makefile:60-61 固定 `TEST262_COMMIT`/`TEST262_SINCE`;478-485)。补丁(tests/test262.patch)只调 harness 超时(`yield:100→40` 等)以加速原子测试——务实而不动语义。
- run-test262.c(2555 行)自建 harness:解析 frontmatter 标签(negative/strict/async/module/raw,1780-1900 一带)、按需加载 `harness/*.js`、多线程跑(默认按 CPU 数,2442),`$262.evalScript/detachArrayBuffer` 等 agent API 以 C 挂接;`$262.agent` 的多 worker 广播由独立线程承载(run-test262.c:687 的 `pthread_create(&agent->tid, ...)`)。`-T n` 控制并发度(2231),`-c test262.conf` 读配置(1172-1186 处理 harnessdir/features 等),结果写入 `reportfile=test262_report.txt`(test262.conf:39-40)。`-u` 会把实际失败写回 error file(127, 2307-2308, 1371-1377;本 commit 标题"sort them so that it gives the same result with several threads"正是给 `-u` 输出定序),另配 `-T 秒级阈值` 把慢测试单独标记(slow_test_threshold,128, 2200-2208)。
- 已知失败清单 `test262_errors.txt` 仅 **58 行**(test262o_errors.txt 为 0):集中在 annexB 的 assignment-targettype 语法错误、classic 与 strict 模式下的隐式全局赋值老用例(S11.13.1 系列)、模块歧义导出、以及 staging/sm 的少数行为差——对一个单 GB 引擎是极小的债面。`test262.conf` 用 `feature=skip` 逐项声明未实现特性(55-120,如 `Array.fromAsync=skip`)。
- 回归面还有 `make test` 的 9 个自测脚本(Makefile:455-470)、`microbench`(475-476)、`node-test` 交叉验证(521-526)与 `bench-v8`(532-534)。

### 5.2 fuzz 与 CI

fuzz/ 下 7 个 libFuzzer 目标:fuzz_eval、fuzz_compile、fuzz_regexp(+regexp_compile、json、module_export 变体),共享 fuzz_common.c。harness 标配沙箱:64MB 内存限额 + 64KB 栈(fuzz/fuzz_common.c:29-31),并用中断处理器在累计 100 次中断后杀掉死循环(18-23)。Makefile 提供 `libfuzzer` 目标与 `libquickjs.fuzz.a`(275-284, 317-318);fuzz/README 给出 `CONFIG_CLANG=y CONFIG_ASAN=y make libfuzzer` 的推荐姿势。仓库内没有 oss-fuzz 配置文件,但 fuzz_common.c 版权头为 "Copyright 2020 Google Inc.",源自 Google OSS-Fuzz 贡献(quickjs-ng 同款目录结构),由 CI 之外的 OSS-Fuzz 基建持续运行。

`.github/workflows/ci.yml` 是 2023 年复健后补上的:Linux/LTO/M32/ASAN/MSAN/UBSAN/COSMO/MinGW+Wine 八个矩阵,统一 `CONFIG_WERROR=y` 构建 + `make test` + `make test2`(ci.yml:29-42, 95-100, 225-238)——警告即错误和 sanitizer 全家桶进入了主干纪律,这在纯 Makefile 项目里相当完备。

### 5.3 单人维护的发布纪律

- **Changelog 即发布说明**:条目按日期(2026-06-04 / 2025-09-13 / 2025-04-26 / 2024-01-13 …),节奏约一年 1-3 次,每次一段要点,无语义化版本号(VERSION 就是一个日期,Makefile:156 直接注入 `CONFIG_VERSION`)。
- **release.sh** 产出四类工件:extras(unicode 表 + bench-v8/octane/cli 测试目录打包,release.sh:18-31)、win64 二进制(mingw 交叉,35 行起)、cosmopolitan 单文件二进制、源码包(9-13 的 release_list 定义)。readme-cosmo.txt 专门维护 cosmocc 构建;Makefile:42-43, 125-132 有对应 CONFIG_COSMO 分支(cosmocc 不支持 -MF 之类的规避注释可见工程磨合痕迹)。
- **删代码也是纪律**:2025-04-26 一口气移除 libbf/BigFloat/BigDecimal/qjscalc/"use strip"(Changelog:17-31),换来自建 BigInt + dtoa、更小的攻击面与更少的维护负担;TODO 文件仍在记录未竟事项。
- 构建. Properly 交叉编译是一等公民:`CONFIG_WIN32=y` mingw 交叉(Makefile:31-35, 87-101)、host-qjsc 解决"目标架构跑不了 qjsc"的鸡生蛋问题(217-224, 288-292)、`libquickjs.a` 静态库 + 可选 LTO 双产物(225-228, 309-315)、`install` 目标(377-387)。sanitizer 通过注释开关暴露(50-57, 185-200)。

### 5.4 沙箱边界

QuickJS 的沙箱定位是"资源受限的宿主内嵌",不是安全边界承诺:

- **内存**:`JS_SetMemoryLimit`(quickjs.h:372)由默认分配器强制——分配/再分配超限即拒绝(quickjs.c:2160, 2198),limit 默认 -1(2074),`JS_SetMemoryLimit` 写入于 2223。
- **栈**:`JS_SetMaxStackSize`(quickjs.h:375)+ `js_check_stack_overflow`(2048-2059)防御递归爆栈。
- **CPU**:`JS_SetInterruptHandler`(quickjs.h:926, quickjs.c:2237-2240)+ 引擎内插桩:每 `JS_INTERRUPT_COUNTER_INIT=10000` 次分支检查一次计数器(quickjs.c:512, 7864-7884),回调返回非零即抛**不可捕获**的 "interrupted"(7858-7862)。fuzz harness(2×限额+100 次中断)就是这套 API 的标准配方(fuzz_common.c:18-31)。
- **进程隔离**:worker 每线程独立 runtime(2.3 节),无共享堆;真正不信任的代码仍建议 OS 级沙箱——`os.exec`、`std.loadFile` 等绑定面本身就是全权宿主 API,引擎层没有 capability 机制。

## 6. 与前作对照

- **V8(node 宿主)vs quickjs-libc**:node 把 libuv 事件循环、stream、fs、child_process 织进一个"平台",宿主 API 是产品承诺、有 semver 与兼容性测试;quickjs-libc 则是"宿主即示例代码"——4000 行 C 把 FILE*/poll/fork 包成 JS,作者在注释里自陈 TODO"add socket calls"(quickjs-libc.c:84-86),模块加载器没有路径解析,事件循环要宿主自己写。嵌入者拿它当 cookbook 改造,而不是当 SDK 依赖。哲学差异的根源:V8 的宿主义务被 node 一次性还清,QuickJS 把义务显式留给每个嵌入者(第 1 节那张图)。
- **zstd decodecorpus(第五系列一)vs run-test262/CI**:两者共享"种子 + golden file"气质——decodecorpus 用字典生成并回归验证帧,quickjs 用固定 commit 的 test262 + 58 行已知失败清单 + `-u` 回写;差异在 zstd 的测试矩阵服务多平台交付,quickjs 的矩阵(CI 8 job + sanitizer + microbench 性能盯梢)服务单人重构的自信:敢于整体删除 libbf,正是因为 test262/自测/CI 够薄但够硬。

## 7. 设计动机

1. **为什么 libc 是示例而非标准库**:QuickJS 的定位是嵌入引擎,库的边界应由宿主定义;libc 模块用 `js_init_module_std/os` 显式注册(qjs.c:114-115),qjs 只是"第一个宿主"。保持核心零依赖(-lm -ldl -lpthread,Makefile:256-261),任何嵌入者都能整棵搬走。
2. **为什么自己写 libbf→再自写 BigInt/dtoa 而不用 GMP**:零依赖是硬约束(GPL/体积/交叉编译三重成本);libbf 时代它还要同时服务 BigFloat/BigDecimal 的任意精度上下文,当提案扩展被移除后,Spec 只要求 BigInt 整数语义,1.5 千行补码 limb 实现 + 1.6 千行 dtoa 即可覆盖,且补码表示让 `|0n` 类位运算与 asIntN 截断天然对齐。
3. **单人项目的简洁性纪律**:一个 Makefile、无子模块、无 autotools;qjsc 直接生成 C 源码而不是自定义对象格式(用户可读、可 diff、可 LTO);REPL 用自家字节码嵌进二进制(狗粮);`-u` 排序错误清单保证多线程确定性输出(本 commit 标题)。每个决定都指向"一个人也要能全年维护"。

## 8. FAQ 素材

1. qjs 里 setTimeout 为什么"不触发"?——注册只是挂链表(quickjs-libc.c:2175-2201),必须有人跑 `js_std_loop`(4292)或手动调 `JS_ExecutePendingJob`+poll;脚本跑完即退的场景定时器永远不会到期。
2. QuickJS 的 worker 共享内存吗?——不共享,每 worker 独立 `JS_NewRuntime`(3626);postMessage 走 `JS_WriteObject` 序列化(3797),唯一按引用共享的是 SharedArrayBuffer(3816-3830 + SAB 引用计数 3492-3519)。
3. worker 里能再开 worker 吗?——不能,显式 TypeError(3713-3716)。
4. BigInt 现在用什么实现?——quickjs.c 内置补码 limb 实现(490-502, 11264 起),libbf 与 BigFloat/BigDecimal 已于 2025-04-26 移除(Changelog:17-19)。
5. qjsc 的产物为什么快?——启动只做 `JS_ReadObject` 反序列化 + 实例化(quickjs-libc.c:4353-4384),无解析、默认无源码(qjsc.c:597)。
6. 怎么给固件瘦身?——`JS_NewContextRaw` + 按需 intrinsics(quickjs.h:397-410),qjsc `-fno-xxx`(qjsc.c:67-78, 646-667),Makefile:394-396 有现成组合。
7. 引擎怎么限制死循环?——`JS_SetInterruptHandler` + 每 10000 次分支检查(quickjs.c:512, 7877-7884),抛不可捕获异常(7858-7862)。
8. 未处理的 promise rejection 会怎样?——2025-04-26 起默认致命 exit(1)(quickjs-libc.c:4275-4288),`--no-unhandled-rejection` 可关(qjs.c:412-415)。
9. 模块能 require("fs") 吗?——不能;`js_module_loader` 只认文件名/`.so`/`.json`(684-735),无路径搜索。
10. REPL 历史能跨会话保存吗?——不能,内存态(repl.js:78, 381-385)。

## 9. 深挖建议

1. **mp_divnorm 的商估计与修正循环**(quickjs.c:11432-11456, 11489-11556):对照 Knuth TAOCP 4.3.1,体会 2-by-1 除法 `div1norm` 的预估-回退实现,以及为什么补码大数除法要先取绝对值(11890-11947)。
2. **JS_TaggedValue 的 short-BigInt 编码**:quickjs.h:73/93/142 与 `JS_CompactBigInt` 的折叠时机(quickjs.c:15054)——小的立即数如何避开堆与 GC,和 smi 优化对照。
3. **dtoa 的 mpb_t 舍入路径**(dtoa.c:295-366, 958-1012):FREE 模式最短表示的生成策略,以及 doc 注释"dtoa 不是最优算法但简单可读"的自白(dtoa.c:43)。
4. **waker 抽象的跨平台统一**(quickjs-libc.c:2282-2352):pipe 自唤醒 vs CreateEvent,如何让 poll(2) 与 WaitForMultipleObjects 共享同一套 `js_os_poll` 逻辑。
5. **qjsc 的 host-qjsc 交叉编译闭环**(Makefile:217-224, 288-301):`-x` BSWAP 字节序 + host 编译器如何在 x86 主机为 ARM/MCU 产出字节码。

## 写作要点速查表

| 主题 | 文件:行号 |
|---|---|
| worker 每线程独立 runtime | quickjs-libc.c:3618-3667(JS_NewRuntime 于 3626) |
| worker 禁止嵌套 / 端口创建 | quickjs-libc.c:3713-3716;3742-3747 |
| postMessage 序列化+SAB 引用 | quickjs-libc.c:3797-3799;3816-3830 |
| SAB 引用计数分配器 | quickjs-libc.c:3478-3519;注入 4152-4161 |
| 消息管道+waker 结构 | quickjs-libc.c:117-140;waker 实现 2282-2352 |
| 收消息→onmessage | quickjs-libc.c:2357-2411 |
| setTimeout/定时器结构 | quickjs-libc.c:2175-2201;101-106 |
| 事件轮询 poll(2)/WaitForMultipleObjects | quickjs-libc.c:2547-2657;2422-2513 |
| js_std_loop / await / rejection 致命 | quickjs-libc.c:4292-4312;4317-4351;4275-4288 |
| 模块加载与 import.meta / .so | quickjs-libc.c:684-735;548-599;498-545 |
| 宿主组装样板(qjs) | qjs.c:453-536;上下文工厂 107-117 |
| REPL=预编译字节码 qjsc_repl | qjs.c:46-47,522-524;Makefile:320-321 |
| REPL 行编辑/着色/内存历史 | repl.js:126-137;217-282;78,381-424 |
| qjsc 字节码→C 数组 | qjsc.c:179-209(JS_WriteObject 于 193) |
| qjsc 生成上下文/main 模板 | qjsc.c:794-861;373-389;feature 表 67-78 |
| BigInt 结构/上限 | quickjs.c:466-502;JS_BIGINT_MAX_SIZE 11266 |
| mp_ 原语与除法归一化 | quickjs.c:11313-11382;11401;11489-11556 |
| BigInt 加减乘除/幂 | quickjs.c:11811;11860;11880;12105 |
| 二元运算 BigInt 分派 | quickjs.c:15014-15054 |
| 中断检查/内存限额 | quickjs.c:512,7858-7884;2160/2198/2223 |
| dtoa 接口与舍入 | dtoa.h:28-46;dtoa.c:295-366,1003-1012 |
| test262 固定 commit/补丁/错误清单 | Makefile:60-61,478-485;tests/test262.patch;test262_errors.txt(58 行) |
| fuzz harness 沙箱 | fuzz/fuzz_common.c:18-31;Makefile:275-284 |
| bignum 移除记载 | Changelog:17-19(2025-04-26) |
