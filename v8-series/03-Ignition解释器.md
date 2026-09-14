# 第 03 章 · Ignition 解释器:四层金字塔与代码生成的 handler

> 基线:commit `c6a1f7c2`。行号以 src/interpreter/、src/baseline/、src/execution/tiering-manager.cc 为准。

## 3.0 全景:分层编译金字塔(本 commit 实际层级)

```
TurboFan   TURBOFAN_JS  门票 ~3000×字节码长;并发编译,峰值性能
Maglev     MAGLEV       ~400 次(Android 1000),中层优化,默认开启
Sparkplug  BASELINE     首次升级即触发(~8 次),字节码 1:1 直译
Ignition   INTERPRETED  零编译延迟,预生成 handler 的寄存器机解释器
```

(code-kind.h:28-32 硬编码顺序;门票公式统一 `N × 字节码长度`,tiering-manager.cc:244-268;预算存 FeedbackCell.interrupt_budget_,透支陷入 OnInterruptTick:559-661。)

## 3.1 handler 生成:没有解释循环的解释器

**每个 opcode 是构建期经 CSA/TurboFan 管线编译的独立 builtin 机器码**(194 个 IGNITION_HANDLER,interpreter-generator.cc:46-66),结尾 TailCallBytecodeDispatch 尾调用下一 handler(:1402-1431);**没有解释循环**——分派表 3×256 项直接存机器码地址(interpreter.h:109-113,初始化+IllegalHandler 沙箱预填 :334-374)。handler 走 TurboFan 编译 job(setup-builtins-internal.cc:370-390);正向 Turboshaft(TSA)迁移被 flag 门控,仅 BitwiseNot 有 TSA 版。调用约定四参数=累加器/字节码偏移/BytecodeArray/分派表(interface-descriptors.h:2623-2635),x64 落 rax/r9/r12/r15——**寄存器级调用约定,免内存分派**。

对照 quickjs 的 computed-goto(第五系列二 03 章):同为"表驱动 dispatch",V8 的表项是**编译生成的机器码**而非共享的 C case——每 opcode 独立优化(IC 快路径内联进 handler:GetNamedProperty 内联 LoadIC_BytecodeHandler)。

## 3.2 帧布局与 InterpreterEntryTrampoline

InterpreterEntryTrampoline(builtins-x64.cc:1075):压帧(:1139-1157)、**栈上分配寄存器文件**(push undefined 循环 :1159-1184)、扣预算(:1198-1207)、call handler(:1248)。解释器帧布局官方图(frame-constants.h:738-819):BytecodeArray/bytecode offset/FeedbackVector/寄存器文件均 FP 相对寻址——寄存器文件在线程栈上,GC 扫描帧即扫描(与 C 报告 var_refs 呼应)。帧类型四级相邻(frames.h:123-126):InterpretedFrame(:1255)/BaselineFrame(:1286)/MaglevFrame(:1313)/TurbofanJSFrame(:1339);遍历 StackFrameIterator::Advance(frames.cc:190)。

## 3.3 分层触发:预算与 OSR

**Ignition→Sparkplug**:首次升级即触发(~8 次预算);Sparkplug 是**字节码 1:1 直译**(baseline-compiler.cc:323-355 GenerateCode;VisitLdaSmi :822-825;VisitReturn :2813-2820),与解释器共用帧布局,批量编译(baseline-batch-compiler.cc:259-273)——放弃优化换"编译极快"。**中层 Maglev**:MaglevFrame(:1313)。**OSR**:JumpLoop 廉价检查(interpreter-generator.cc:2453-2524)→OnStackReplacement 三条件(interpreter-assembler.cc:1515-1609)→Runtime_CompileOptimizedOSR(runtime-compiler.cc:714-723,目标 MAGLEV);urgency 由 tiering-manager 递增(:299-303)。budget 扣减在 interpreter-assembler.cc:1179-1221。

## 3.4 设计动机

1. **Ignition 诞生的动机**(取代 Full-codegen):字节码+handler 的内存占用远低于"每函数全量机器码"——**用解释的延迟换启动内存**;
2. **为什么 handler 用 CSA 生成**:CSA(TurboFan IR 的高层封装)让 handler 拥有"编译器输出的机器码质量"且可跨架构——**用编译器写解释器**;
3. **四层的延迟-吞吐谱系**:Ignition 零延迟/Sparkplug 直译快出/Maglev 中层优化/TurboFan 峰值——每层的编译成本与峰值收益成正比,预算制(N×字节码长)自动匹配;
4. **OSR 的廉价检查**:JumpLoop 里只做一次预算扣减+标志位判断(:2453-2524),重活交给后台——热循环热路径最小化。

## 3.5 FAQ

**Q1:V8 有几个执行层?**
四层:Ignition→Sparkplug→Maglev→TurboFan(code-kind.h:28-32);层与层之间预算触发。

**Q2:Ignition 为什么叫寄存器机?**
字节码操作 FP 相对的寄存器文件(:738-819),非纯栈:减少栈操作指令。

**Q3:Sparkplug 为什么这么快编译?**
1:1 直译字节码,无图构建无优化(:323-355):"快出"层,省掉解释的反复取指。

**Q4:Maglev 是什么?**
中层优化(比 TurboFan 快编译、比 Sparkplug 强优化):填补"还没热到值得 TurboFan"的区间。

**Q5:handler 能内联 IC 吗?**
能:GetNamedProperty 内联 LoadIC 快路径——常见形态免出 handler。

**Q6:OSR 是什么?**
On-Stack Replacement:热循环的字节码帧在栈上原地替换为优化帧(:1515-1609)。

**Q7:预算为什么存 FeedbackCell?**
同一函数的多次闭包共享升级进度——函数级而非闭包级。

**Q8:dispatch 表为什么 3×256?**
宽指令(Wide/ExtraWide)前缀各一套(:109-113):前缀决定查哪张表。

**Q9:Maglev 也用 TurboFan 后端吗?**
是:共享后端基础设施,只换中端——分层共享编译器资产。

**Q10:解释器帧能被 GC 扫描吗?**
能:寄存器文件在栈上,帧布局元数据(:738-819)供精确扫描。

## 3.6 小结与深挖方向

本章结论:**Ignition="handler 即编译生成的机器码+预算制四层金字塔+OSR 原地升级"**。深挖:

1. 194 个 handler 的 CSA 代码体积与 iCache 占用;
2. Sparkplug 与解释器共用帧布局(:帧常量)的 GC 栈扫描统一性;
3. Maglev 在本 commit 的默认开关状态与产物质量;
4. OSR urgency 递增(:299-303)的收敛性;
5. dispatch 表的 r15 基址寻址对 CFI 的兼容。

> 下一章:对象模型与隐藏类——Map 与 IC 三态。
