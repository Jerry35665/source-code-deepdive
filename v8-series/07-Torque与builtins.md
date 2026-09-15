# 第 07 章 · Torque 与 builtins:内置函数的三层实现

> 基线:commit `c6a1f7c2`。行号以 src/torque/、src/builtins/ 为准。

## 7.0 全景:内置函数的三种实现形态

```
Torque(.tq DSL,249 个文件)→ 构建期编译成 CSA C++
CSA(C++"伪汇编",builtins-*-gen.cc)
C++ runtime(约 699 条 RUNTIME_FUNCTION,52 个域宏,慢路径兜底)
手写汇编(JSEntry/CEntry/Call 存根)
选择依据 = 性能要求 × 复杂度;CEntry(builtins-definitions.h:1593-1597)是生成代码进 C++ 的唯一桥
```

Array/TypedArray/String 热方法、对象布局声明在 Torque 层(src/ 下 249 个 .tq,builtins 157 个,372 个 javascript builtin)。

## 7.1 Torque:领域专用语言

两遍解析(先预声明后解析,torque-compiler.cc:75-85)→ImplementationVisitor→**生成 CSA C++**;产物不止代码:内置定义头、对象布局、bitfield、调用描述符(:102-121)。类型系统:**联合类型**(`JSAny = JSPrimitive|JSReceiver`,base.tq:103)+**labels**(带参数的受控出口,生成 CodeAssemblerLabel,csa-generator.cc:390-428)+`Cast<T> otherwise L`(运行时 instance-type 检查)vs `%RawDownCast` 零检查(torque-internal.tq:438);typeswitch 被解析器脱糖为 Cast 调用链(torque-parser.cc:1743)。`extern runtime`(.tq 中 199 处)生成 CallRuntime(csa-generator.cc:713-745)。

## 7.2 贯穿例子:Array.prototype.map 的三层

入口 ArrayMap(TFJ)→species protector+`Cast<FastJSArrayForRead>` 双守卫→**FastArrayMap 快循环**(struct Vector 追踪元素种类)→`Recheck otherwise PrepareBailout` 带半成品数组+断点 k 回落通用循环 ArrayMapLoopContinuation→**去优化 continuation 三重保险**→bootstrapper 安装属性(bootstrapper.cc:2504;array-map.tq:259 入口,:221-224 label,:250-253 回退,:282-289)。JSAny 定义在 base.tq:103。内置种类表(TFJ/TFS/TFC/TFH/BCH/ASM/CPP 注释):builtins-definitions.h:40-54;总装 SetupBuiltinsInternal(:467,占位符 :402/:416,数量核验 :594)。

## 7.3 runtime 函数:慢路径兜底

约 699 条 RUNTIME_FUNCTION(runtime.cc:12-14 的 C ABI;arguments.h:162-193 的宏);52 个域宏组织(runtime.h FOR_EACH_INTRINSIC)。`--allow-natives-syntax`(:3334)暴露 % 转义给测试(09 章)。第三方对照:Math 是 pure Torque(math.tq:35);RegExp 是 .tq 外壳→CSA→C++ irregexp(regexp.cc:534);JSON 纯 C++(json-parser.h:209/:274)——**四种形态在同一引擎内共存,按数据形状与稳定性各取所需**。

## 7.4 设计动机

1. **为什么发明 Torque**:手写 CSA 的内存不安全与不可读,Torque 加类型系统+labels+自动 Cast——**DSL 是"内存安全+可读性"对汇编的胜利**;
2. **三层慢路径兜底哲学**:Torque 快循环→CSA 通用→C++ runtime,每层都比上层慢但更通用——梯度降级;
3. **Cast vs RawDownCast 的纪律**:带检查的 Cast 是默认,RawDownCast 需注释证明不变式——类型安全写成语法强制;
4. **species protector**:map 的子类语义需要 protector 检查(:221-224)——规范兼容与快路径的桥梁。

## 7.5 FAQ

**Q1:Array.prototype.map 是 C++ 吗?**
不是:Torque(.tq)编译成 CSA 再成机器码(array-map.tq:259)。

**Q2:Torque 编译产物只有代码吗?**
不止:内置定义头/对象布局/bitfield/调用描述符(:102-121)——**DSL 是多产物生成器**。

**Q3:labels 是什么?**
带参数的受控出口(:390-428):编译成"跳到 label 处并带值"——Torque 的异常机制。

**Q4:Cast 失败会怎样?**
otherwise label:走慢路径或 bailout(:221-224)——不做隐式转换。

**Q5:runtime 函数有多少条?**
约 699 条(52 个域宏);%NativesSyntaxByi18n? 调试用 % 转义经 --allow-natives-syntax(:3334)。

**Q6:RegExp 是 Torque 吗?**
外壳是(.tq),核心走 CSA 到 C++ irregexp(regexp.cc:534)——正则引擎独立维护。

**Q7:JSON 呢?**
纯 C++(json-parser.h:209/:274):解析器性能关键且稳定,无需 DSL。

**Q8:内置会 miss 吗?**
会:fast path 的 Recheck 失败走通用循环(:250-253)——不假设快条件永真。

**Q9:CEntry 是什么?**
生成代码进 C++ runtime 的唯一桥(:1593-1597):寄存器布局→C ABI 的转换器。

**Q10:三层能互相调用吗?**
能:Torque 的 extern runtime 调 C++;CSA 能 emit CallRuntime——**向下调用单向无边**。

## 7.6 小结与深挖方向

本章结论:**内置三层="Torque DSL(热方法)→CSA(胶水)→C++ runtime(兜底)+手写汇编(JSEntry)"**;选择公式=性能要求×复杂度。深挖:

1. FastArrayMap 的 Vector 追踪在 callback 改数组的防御(:221-253);
2. Torque 两遍解析(:75-85)的循环依赖处理;
3. typeswitch 脱糖(:1743)的 Cast 链优化空间;
4. 199 处 extern runtime(:713-745)的性能热点排名;
5. Torque→Turboshaft 直通(tsa-generator)的迁移进度。

> 下一章:快照与 code cache——冷启动的两级加速。
