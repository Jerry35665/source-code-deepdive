# 第 06 章 · TurboFan 与 Turboshaft:优化编译管线(卷二开篇)

> 基线:commit `c6a1f7c2`。行号以 src/compiler/ 为准。**重大基线事实:turlev 默认开启**(flag-definitions.h:1732)——默认优化路径已是 **Maglev 图→Turboshaft**,经典 TurboFan 前端仅在 --no-turbolev 时使用;且**后端已全部易主 Turboshaft**(调度后从 TF 图翻译,build-graph-phase.cc:18)。

## 6.0 全景:管线阶段

```
经典链(pipeline.cc:1872-1980 OptimizeTurbofanGraph 编排):
字节码 → GraphBuilderPhase(:854,Sea of Nodes 建图)
  → InliningPhase(:893)→ EarlyGraphTrimming(:1023)→ Typer(:1035)
  → TypedLowering(:1096)→ LoopPeeling(:1192)→ LoadElimination(:1273)
  → EscapeAnalysis(:1137)→ SimplifiedLowering(:1176)→ GenericLowering(:1224)
  → EarlyOptimization(:1242)→ ComputeSchedule(:1463)
  → [Turboshaft 接管:MachineLowering/指令选择/寄存器分配]
```

ExecuteJobImpl 按 --turbolev 分叉(pipeline.cc:762-803,:777)。Turboshaft 侧:pipelines.h:200-266/:326。

## 6.1 Sea of Nodes:控制与数据边分离

TFGraph(turbofan-graph.h:32,旧 graph.h 已更名)只有 start/end 两个哨兵;节点输入平铺一条数组,值/effect/控制三种边按 Operator 声明排布(node.h:59;node-properties.h:34-52)。**普通运算节点不属于任何基本块**——调度器用 BuildCFG→特殊 RPO→支配树→ScheduleEarly/Late 七步才坍缩成块序(scheduler.cc:50-75)。三个免费收益:调度自由(不变量外提免费)、死代码消除免费(End 不可达即删)、effect 链让各消除类优化统一成状态传播。

## 6.2 inlining:预算与多态特化

内联预算四闸:单函数 460/累计 920/绝对 4600/小函数豁免 30000 字节(flag-definitions.h:1480-1501);**多态内联上限 4 个目标**(js-inlining-heuristic.h:66,按反馈形态各特化一份+分发);内联实现=对被调字节码**再跑一遍建图器**(js-inlining.cc:797-813 SubgraphScope);内联深度 50(:40)。

## 6.3 SimplifiedLowering 与逃逸分析

SL 三阶段 PROPAGATE/RETYPE/LOWER(simplified-lowering.cc:63-84;截断种类 use-info.h:26-113)。**加法的表示选择三分支**(:1848-1900):Int32 快路径/截断/Float64+deopt——性能的核心决策点;SL 后类型作废(pipeline.cc:1947-1958)。Typer 装饰器让新节点即时定型(turbofan-typer.cc:497-511)。**逃逸分析**(:667-703):存/读虚对象字段记变量并删 store/load——对象消失标量化;虚对象写进 deopt 状态(ObjectState/ObjectId,escape-analysis-reducer.cc:149-194)。

## 6.4 deopt:优化的逆变换

FrameState 由建图期 eager checkpoint 生成(bytecode-graph-builder.cc:1215),内联叠成外层链。指令选择把每个 deopt 出口编码成**翻译字节码**(code-generator.cc:1426/:1326;BeginInterpretedFrame :1372):值标成 REGISTER/INT32_REGISTER/DOUBLE_STACK_SLOT 或 CAPTURED_OBJECT/DUPLICATED_OBJECT(translation-opcode.h:24-64)。触发时 DoComputeOutputFrames(deoptimizer.cc:1656)→DoComputeUnoptimizedFrame(:2034)重建解释器帧;**逃逸分析消失的对象在此物化回真实 JS 对象**(translated-state.cc:2063/:2563)——优化期"去物化"与 deopt 期"再物化"严格对偶。

## 6.5 设计动机

1. **为什么 Sea of Nodes**:控制与数据边分离给调度器最大自由——代价是"看不懂"(业界著名的难读图);Turboshaft 换成更传统的块结构后端,前端的自由保留;
2. **turbolev 默认化的意义**:Maglev 图→Turboshaft 的路径编译更快且质量够——**分层金字塔的中层正在吞并顶层前端**;
3. **deopt 翻译的对偶性**:优化期每一步"假设"都留了逆变换记录——激进优化的安全网;
4. **表示选择是性能核心**:Int32/Float64/Tagged 的选择错了就是反复装箱——SL 的三阶段传播是全局解。

## 6.6 FAQ

**Q1:turbolev 是什么?**
Maglev 图喂给 Turboshaft 后端的新路径(:1732 默认开):编译快、质量接近经典 TF。

**Q2:Sea of Nodes 好在哪?**
调度自由+死代码免费(:50-75 七步调度):节点不属于块,自然外提。

**Q3:多态内联为什么限 4 个?**
(:66):每个形态一份特化,超过则分发开销与代码膨胀失控。

**Q4:加法什么时候走 Float64?**
SL 三分支(:1848-1900):int 域放不下且结果用于非 int 上下文时——附带 deopt 检查。

**Q5:逃逸分析失败的对象呢?**
留在堆上正常分配;成功则标量化,deopt 时按 ObjectState 物化(:149-194)。

**Q6:deopt 会丢进度吗?**
不会:translation 字节码完整重建解释器帧(:2034)——包括寄存器/累加器/栈。

**Q7:Turboshaft 替换了什么?**
调度后的全部后端(pipelines.h:200-266):指令选择/寄存器分配/出码。

**Q8:内联的 30000 字节豁免?**
(:1501):小函数无条件内联——预算闸对小函数不设限。

**Q9:Typer 的类型是精确类型吗?**
是区间/集合近似(:497-511):用于范围分析与 SL,不是 JS 类型系统。

**Q10:effect 链是什么?**
有副作用的节点的顺序约束边:消除类优化沿它传播(node-properties.h:34-52)。

## 6.7 小结与深挖方向

本章结论:**TurboFan="Sea of Nodes 前端+phase 管线+Turboshaft 后端+deopt 对偶翻译"**;turbolev 默认化是 V8 执行架构的世代交替。深挖:

1. turbolev 与经典 TF 在 JetStream 的分项得分差;
2. 内联预算四闸(:1480-1501)对大型 bundled JS 的行为;
3. SL 表示选择(:1848-1900)在 Int53 边界的选择;
4. 逃逸分析在 closure 捕获下的恢复率;
5. Turboshaft 的 Block 结构对寄存器分配质量的影响。

> 下一章:Torque 与 builtins 三层。
