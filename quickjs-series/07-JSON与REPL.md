# QuickJS 扩展:JSON、REPL 与性能实测

> QuickJS 精简卷补篇。基线:commit `04be246`。行号以 quickjs.c、qjs.c、quickjs-libc.c 为准。

## JSON:复用词法器的递归下降

json_parse_value(:49484)是递归下降主体,**复用 JS 词法器**(js_parse_init+json_next_token)——一套 token 基础设施服务 JS 解析与 JSON 解析;`ext_json` 标志让同一解析器承担 JSON5(单引号/尾逗号/NaN/Infinity)。带 reviver 时走**两趟**:第一趟建 JSONParseRecord 镜像树记录源文本区间;第二趟 internalize_json_property 以**三参数**调 reviver `(key,val,context)`,`context.source` 还原原始拼写(如 `0x10`)——JSON Parse Source Text Access 提案实现。镜像树查找:**<8 条目线性扫描,≥8 才建链式哈希**(:49417)。stringify:js_json_check(先 toJSON 再 replacer)+js_json_to_str 递归;循环引用用**序列化栈数组 includes** 查环→TypeError(:50106-50112)。

## REPL:薄 C 壳+自宿主 JS

qjs.c 仅在启动时 `js_std_eval_binary(qjsc_repl)` 灌入**构建期预编译的 repl.js 字节码**(qjsc -s -c -m 生成)——行编辑/历史/着色/续行全部在 1292 行 JS 里,零 readline 依赖。**多行判定是纯词法的**:colorize_js 返回 [state,level](括号计数+字符串/模板/正则状态栈),非空即累积进 mexpr 续行;`1+` 这类词法完整输入直接报 SyntaxError。**不区分表达式/语句求值**:统一 std.evalScript(GLOBAL+BACKTRACE_BARRIER+ASYNC),靠脚本**完成值**出结果——`if(x){42}` 得 42、`var z=5` 得 undefined;打印走 JS_PrintValue(深度 2/串 1000/项 100 截断),结果绑定 `_`,每命令强制 std.gc()。

## 性能:同机实测(gcc -O2 自建 vs node v24)

**启动**:无 snapshot,靠 C 初始化即启动(空转 runtime+context 仅 **158KB/50 个 malloc 块**)+qjsc 预编译字节码。**每操作差距规律**:C 密集型最小(JSON.parse 1.3-2x、正则 exec 2.4x、串拼接 1.7x),**解释器型最大**(整型循环 ~7x、map ~7x、对象分配 ~3x)。正则是**自研回溯 VM**:显式 StackElem 栈(不烧 C 栈,耗尽返 MEMORY_ERROR)、每 1 万指令轮询超时(LRE_RET_TIMEOUT)、捕获组上限 255;无 irregexp/RE2 式线性时间保证。调试现状:**上游无调试器**,`debugger` 语句被注释明言跳过。

## 设计动机

1. **为什么不做 JIT**:内存/复杂度/目标场景(嵌入式)——158KB 启动+亚毫秒 runtime 生命周期是产品定义;
2. **REPL 的教育定位**:qjs 是"学 JS 的最小完整环境"——不需要 IDE 级调试;
3. **JSON 复用 JS 词法器**:JSON 是 JS 的子集(加约束),共用词法器=零维护成本;
4. **单文件的可维护性**:6 万行 quickjs.c 的分区靠注释+顺序——Bellard 单人维护的极限组织方式。

## FAQ

**Q1:JSON.stringify 循环引用会怎样?**
TypeError: circular reference(:50106-50112)——栈数组 includes 检测。

**Q2:JSON.parse 支持 JSON5 吗?**
支持:ext_json 标志让同一解析器承担单引号/尾逗号/NaN/Infinity(:49484)。

**Q3:reviver 的三参数是什么?**
(key,val,context):context.source 还原原始拼写(:49709-49802)——JSON Parse Source Text Access 提案。

**Q4:REPL 的多行怎么判定?**
纯词法:colorize_js 的括号计数+状态栈(:repl.js:960/:982/:1285)。

**Q5:启动 158KB 是怎么算的?**
(:空转 runtime+context 的 malloc 统计):原子表 588 项+少量对象——qjs.c 内置计时器实测。

**Q6:为什么每条 REPL 命令强制 GC?**
(:29624-29625):教学环境防内存泄漏——学生看不到的自动清理。

**Q7:debugger 语句为什么跳过?**
上游无调试器:debugger 被注释明言跳过(:29624-29625)——REPL 的 print 就是调试。

**Q8:正则回溯栈溢出怎么办?**
显式 StackElem 栈(:libregexp):不烧 C 栈,耗尽返 MEMORY_ERROR。

## 小结与深挖方向

本章结论:**QuickJS 外围="JSON 复用词法器+REPL 自宿主 JS+启动零快照"**;性能差距(C vs JIT)在每个操作 1.3-7× 之间。深挖:

1. JSONParseRecord 的 <8 阈值(:49417)与真实 JSON 大小的匹配;
2. reviver 三参调用(:49709)在深层嵌套的栈深度;
3. REPL 的 colorize_js(:repl.js:1285)在正则/模板字面量的状态恢复;
4. 正则回溯的超时保险丝(LRE_RET_TIMEOUT)在生产 embedder 的调参;
5. 启动 158KB 的进一步压缩空间(原子表惰性化)。

> QuickJS 扩展完——JSON/REPL/性能实测补齐了精简卷的外围面。
