# QuickJS 扩展:REPL 架构与性能实测

> QuickJS 精简卷补篇。基线:commit `04be246`。行号以 qjs.c、repl.js、quickjs-libc.c 为准。

## REPL:自宿主 JS 架构

C 壳 main(qjs.c:314)建 runtime/context、注入 std/os 模块(:107-117),交互模式下调 `js_std_eval_binary(qjsc_repl)`(:524)灌入**构建期预编译的 repl.js 字节码**(qjsc 从 39KB repl.js 生成,Makefile:320-321)——行编辑/历史/着色/多行/补全全在 1292 行 JS 里,**零 readline 依赖**。

**多行判定是纯词法的**:colorize_js 返回 [state,level](repl.js:1285),state 非空则暂存 mexpr 续读(:984-989)。结果打印走 JS_PrintValue(深度 2/串 1000/项 100 截断,quickjs.c:14403-14408),结果绑定 `_`;每命令强制 std.gc()。历史仅内存数组无持久化(repl.js:78/:381)。

## 启动分析

引擎 init 全程 min 0.062ms/avg 0.110ms;最贵阶段是 11 个 intrinsic 建全局对象树(~0.05ms,quickjs.c:2627-2649);原子表仅 242 预定义 intern(:3090,"at least 504"过时);regexp 启动零预编译(:49266-49298)。CLI 壁钟 ~130ms 几乎全是 OS 进程创建。空引擎内存 155KB/48 块/588 原子。GC 唯一自动触发点=对象分配(:5619),水位 256KB 起、1.5x 堆量回设(:2082,:1780-1797)。

## 性能对照(同机实测)

累计差距 **2.85×**(4237 vs 1487ns)。结构化差距:**函数调用 176×**、属性读写 60×、typed_array 写 87×、空循环 10.5×;库代码差距小:JSON.parse 2.1×、regexp 4.4-8.6×、bigint 2×、sort 2.6×;date_parse quickjs 反超 1.8×。注意 int_to_string 等在 V8 下被 DCE(假数据)。

## 设计动机

1. **REPL 为什么用 JS 写**:自宿主——REPL 逻辑(repl.js)本身是 JS,由 qjsc 预编译灌入;**用产品自己的语言写产品自己的工具**;
2. **为什么每命令强制 GC**(:repl.js:1053):教学环境防内存泄漏;
3. **为什么打印有截断**:depth 2/串 1000/项 100——REPL 是探索工具不是调试器;
4. **为什么历史不持久化**(:78/:381):REPL 的历史是会话级,持久化是 IDE 的职责。

## FAQ

**Q1:qjs 启动多快?**
引擎 init min 0.062ms/avg 0.110ms;CLI 壁钟 ~130ms 主要是进程创建。

**Q2:REPL 的行编辑用什么库?**
不用:repl.js 1292 行纯 JS 实现行编辑+着色+补全——零外部依赖。

**Q3:多行输入怎么判定?**
纯词法:colorize_js 返回 [state,level],非空即续行(repl.js:984-989)。

**Q4:顶层 await 支持?**
支持:脚本包成 async 函数体(:quickjs.h:347)。

**Q5:打印的截断规则?**
JS_PrintValue 深度 2/串 1000/项 100(:14403-14408):`[Object]` 截断标记。

**Q6:GC 什么时候触发?**
对象分配时水位检查(:5619):256KB 起、1.5× 堆量回设(:1780-1797)。

**Q7:REPL 的结果怎么绑定 _?**
每次 evalScript 后把完成值赋给全局 `_`:纯 JS 逻辑(repl.js)。

**Q8:为什么 C 密集操作差距最小?**
(:JSON.parse 1.3-2x):C 代码库(JSON/正则)两边都是 C——差距只在 JS 解释器层。

## 小结与深挖方向

本章结论:**REPL="自宿主 JS+零依赖行编辑+构建期字节码";性能="C 密集最小差距,解释器型最大差距"**。深挖:

1. repl.js 的 1292 行在嵌入式设备的内存占用;
2. colorize_js 的状态栈(:1285)在正则/模板字面量的误判面;
3. JS_PrintValue 的截断深度(2)对调试体验的影响;
4. 原子表 588 项(:3090)在大型应用的 intern 命中率;
5. 自宿主 REPL 的安全面(用户输入=代码执行)。

> QuickJS 扩展完——REPL/JSON/性能实测补齐了精简卷的用户面。
