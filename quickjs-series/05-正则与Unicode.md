# 第 05 章 · 正则与 Unicode:REOP 回溯引擎与区间表

> 基线:commit `04be246`。行号以 libregexp.c、libregexp-opcode.h、libunicode.c、libunicode-table.h 为准。这两个库是 Bellard 的独立可复用组件。

## 5.0 全景:一个正则的旅程

```
正则字面量/RegExp 构造 → lre_compile(:2522-2614,解析+REOP 编译)
  → REOP 字节码(头 8 字节:u16 flags+u8 capture_count+u8 register_count+u32 bc_len,:111-116)
  → lre_exec_backtrack(:2774-3321,显式栈回溯)
```

非 sticky 正则自动包 split+any+goto 前导(:2554-2562);正则字面量在**解析期编译成常量**(quickjs.c:26883-26913),OP_regexp 运行期只做对象构造(lastIndex=0 :47657);编译器可独立裁剪(JS_AddIntrinsicRegExpCompiler,:49261-49264)。

## 5.1 REOP 指令集:37 条与回溯骨架

libregexp-opcode.h:27-71 共 37 条指令(X-macro 生成枚举 :52-57):字符类(char/char32±_i)、区间(range/range32,16 位版用 0xffff 表无穷)、捕获(save_start/save_end/save_reset)、backref(含 _i 与 backward 变体)、断言(line/word boundary)、控制流(goto/split_goto_first/split_next_first)、计数循环(loop/loop_split_*/loop_check_adv_split_*,10 字节混合指令)、环视(lookahead+lookahead_match 成对)、寄存器(set_i32/set_char_pos/check_advance,防零宽死循环)。**split 指令就是回溯的骨架**(:2945-2966:回溯帧入栈,bp=sp)。

## 5.2 回溯:显式栈与 capture undo 日志

`lre_exec_backtrack` 是约 550 行单函数 for(;;) switch,**执行期零 C 递归**:全部回溯状态在显式栈上(初始 32 元素静态数组 :2737,3/2 扩容,仅受内存限制——不存在 LRE_STACK_SIZE)。每帧 3 字槽{另一路 pc,cptr,bp+类型},类型三态 SPLIT/LOOKAHEAD/NEGATIVE_LOOKAHEAD(:2704-2708)。**捕获不是帧快照而是 undo 日志**:SAVE_CAPTURE 写前压旧值(:2805-2812),no_match 处逆序还原(:2857-2861)——比"整组寄存器快照"省。贪婪/懒惰只是编译期选 split_goto_first vs split_next_first(`REOP_split_goto_first+greedy` 算术翻转,:2302-2303);前向环视成功时保留捕获 undo(:2874-2906),否定环视撤销捕获并强制失败(:2907-2925);**后行环视=body 字节码整段倒排+REOP_prev 倒走**(:2389-2401,:2171-2172)。寄存器即栈的静态分配,上限 255(:2444-2505,:59-60);backref 取"第一个非空捕获"(:3172-3228,:3192-3193)。**灾难性回溯无自动防线**,仅 interrupt_handler 每 10000 步查超时(:63,:2740-2748)。冷知识:libregexp.c:40-43 的 TODO 明说 REOP 指令形状本来就为"lock step 线性执行"预留,但从未实现——**"为什么不用线性引擎"的第一手答案:预留了,没做**。

## 5.3 Unicode:位打包区间表

libunicode-table.h 的体积纪律:case_conv_table1[378] u32 位打包(17bit code|7bit len|4bit type),libunicode.c:63-65 解码(:6/:104);A-Z 一个 entry。3 字节索引(21bit 码点+块号,表内自带注释 :479-491)+块内 RLE;**ID_Start 表仅 1146 字节**(:332)——B 报告的词法复用就靠它。大小写规范化:lre_canonicalize 的 u flag 走 case folding(特例硬编码 :204-210),非 u 走 legacy toUpper(:227-261)。GET_CHAR 宏族(:2621-2702):cbuf_type=2 时自动合并代理对,u flag 以码点步进(:3340-3341)。

## 5.4 集成:lastIndex 状态机

js_regexp_exec(:48138-48185)维护 lastIndex(y flag sticky 语义);replace 快路径遇命名组即退回通用路径(:48348-48350)。主解析器的标识符判定(libunicode.h:169-194)与正则的字符类共享同一套表——**一个 Unicode 基础设施服务两个子系统**。

## 5.5 与 PCRE/Irregexp 对照及设计动机

| | libregexp | PCRE | V8 Irregexp |
|---|---|---|---|
| 模型 | 回溯(REOP 字节码) | 回溯(NFA+JIT) | 自动生成+DFAM/JIT |
| 灾难回溯 | 无自动防线(仅超时) | 有选项 | 线性化避免 |
| 体积 | 极小 | 大 | 大 |

1. **为什么独立成库**:Bellard 的组件化习惯(libregexp/libunicode 单独发布,被 ffmpeg? 被 qcachegrind? 被 tcc 生态复用)——正则是独立于 JS 的通用能力;
2. **为什么回溯不换线性引擎**:体积与 JS 语义兼容(lookbehind/捕获),且 REOP 已预留线性形态(:40-43 TODO)——"预留不实现"的克制;
3. **undo 日志 vs 快照**:捕获组的平均数量小,日志逆放更省——按数据形状选结构(系列老主题);
4. **区间表位打包**:Unicode 全表 MB 级→KB 级,靠 17/7/4 位字段切分——嵌入式场景的表压缩教科书。

## 5.6 FAQ

**Q1:正则会有灾难性回溯吗?**
会(无自动线性化):靠 interrupt_handler 超时兜底(:2740-2748)——JS_SetInterruptHandler 是宿主的盾。

**Q2:后行环视怎么实现?**
body 字节码整段倒排+REOP_prev 倒走(:2389-2401):同一引擎复用。

**Q3:捕获在回溯时怎么恢复?**
undo 日志逆序还原(:2857-2861):不整组快照。

**Q4:u flag 改变什么?**
码点 vs UTF-16 单元步进(:3340-3341)+大小写走 full folding(:227-261)。

**Q5:命名组怎么编译?**
可编译成多组号变长指令(:2083-2088):backref 取第一个非空(:3192)。

**Q6:寄存器为什么上限 255?**
静态分配+1 字节计数(:2444-2505):正则复杂度的硬顶。

**Q7:零宽死循环怎么防?**
loop 的 check_advance 指令(:27-71)+解析期 save_reset 插入(:2276-2295)。

**Q8:正则字面量何时编译?**
解析期(:26883-26913):编译错误在 parse 时报——与 JS 规范一致。

**Q9:能去掉正则功能吗?**
能:JS_AddIntrinsicRegExp 系列可裁剪;甚至编译器单独裁(:49261-49264)。

**Q10:Unicode 表多大?**
ID_Start 1146B(:332)+case 表 378 项(:104):KB 级——全 Unicode 的压缩极限演示。

## 5.7 小结与深挖方向

本章结论:**libregexp="REOP 字节码+显式栈回溯+capture undo 日志";libunicode="位打包区间表"**;两者的体积纪律是嵌入式 JS 的地基。深挖:

1. 显式栈(:2737)在病态正则的膨胀上界;
2. 后行环视倒排(:2389-2401)与捕获交互的正确性;
3. case folding 特例表(:204-210)的版本更新策略;
4. lock step TODO(:40-43)的可行性评估;
5. libregexp 脱离 quickjs 的独立用户(tcc/其他)生态。

> 下一章(卷末):内置库与工程——宿主义务与单人纪律。
