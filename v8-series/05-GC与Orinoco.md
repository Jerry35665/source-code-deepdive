# 第 05 章 · GC 与 Orinoco:并发标记与停顿控制(卷末)

> 基线:commit `c6a1f7c2`。行号以 src/heap/ 为准。**勘误**:本 commit 无 scavenger-inl.h(并入 scavenger.cc);IdleNotification 已移除(空闲 GC 由 MemoryReducer+IncrementalMarkingJob 承担)。

## 5.0 全景:GC 家族与分派

```
heap.cc:2288-2293 三收集器分派:
Scavenger      新生代半空间 Cheney 复制(并行,停顿 1ms 级)   heap.cc:2624 注释明言
MinorMS        新生代标记-清除+页晋升(实验 flag --minor_ms :3822-3823)
Mark-Compact   老生代:三色并发/增量标记 + evacuate 滑动压缩
组件:IncrementalMarking/ConcurrentMarking(major 的分步执行)
```

## 5.1 Scavenger:半空间复制与晋升

Cheney 复制算法(heap.cc:2624 注释):新生代两半空间,活对象从 from-space 复制到 to-space。**并行 scavenger**:扫根前 PostJob 页队列(scavenger.cc:1732-1738);EvacuateObjectDefault(:2110-2150):半空间复制→晋升→降级复制链;**晋升条件=地址低于 age mark**(≈活过两次 scavenge,new-spaces-inl.h:92-93;scavenger.cc:2083-2091);并行复制的唯一性靠 **map word CAS 转发**(:1976-1984)。大对象不搬,整页转正(:1603-1624)。

## 5.2 写屏障:只需记录 OLD→NEW

**为什么只需一个方向**:scavenge 从根遍历,老生代自身不扫——老→新的引用漏记即漏活(新→老自然被老扫到)。组合屏障(heap-write-barrier-inl.h:51-79)同时负责 generational 记录与标记屏障(增量标记防漏标,marking-barrier-inl.h:21-37);记录集为**页级 SlotSet 位图**:bucket(1024 槽)→32 个 32bit cell→bit(basic-slot-set.h:277-284);GenerationalBarrierSlow 双记录集插入(:404-417),主线程/后台线程分记 OLD_TO_NEW 与 OLD_TO_NEW_BACKGROUND 两套。

## 5.3 Mark-Compact:并发三色与 evacuate

**并发标记三色的实现**:单一 markbit+worklist 隐式三色——TryMark 置位=白→灰、入队;出队遍历完=黑(与 bolt 显式三色对照:V8 靠**增量写屏障**(黑→白染灰)维持强不变式,而非 SATB)。增量步进由分配 observer 驱动(新生代 64KB/老生代 256KB 一步,incremental-marking.cc:53-54,:738-756 AdvanceOnAllocation);启动软/硬限(heap.cc:1939-1978)。**evacuate 压缩**三模式(mark-compact.cc:4717-4746):new→old 复制/整页晋升/old→old 压缩,可 abort——碎片治理的滑动式回收。

## 5.4 触发与节奏

分配压力驱动(增量步进)+MemoryReducer 状态机(memory-reducer.cc:18-21,:92-94,空闲后收缩堆)+IncrementalMarkingJob。Orinoco 旗标区(flag-definitions.h:4265-4277):并发/增量的历代开关——**GC 参数的化石层**。

## 5.5 设计动机

1. **为什么分代**:弱分代假说(01 章)——新生代复制(对高死亡率最优)+老生代标记(对高存活率最优);
2. **Orinoco 的目标=主线程停顿控制**:并发标记(后台线程)+增量步进(主线程切片)+lazy sweep——把 major GC 的停顿从"全堆一次"拆成主线程可感知阈值的碎片;
3. **写屏障的单方向**:老→新单向记录是分代模型的数学推论——屏障成本被压到最低;
4. **markbit+worklist 的隐式三色**:不维护颜色字段,置位即灰、遍历完即黑——状态编码进数据结构。

## 5.6 FAQ

**Q1:Scavenger 为什么是复制不是标记?**
新生代死亡率高:复制活者(少)比标记死者(多)便宜——死亡率决定算法。

**Q2:什么时候对象晋升?**
活过两次 scavenge(地址低于 age mark,:2083-2091)。

**Q3:为什么写屏障只记老→新?**
新生代收集不扫老生代:老对新的引用必须补记为根(:51-79)——单方向是分代的推论。

**Q4:并发标记时应用在写对象,会漏标吗?**
增量写屏障把黑→白的新引用染灰(marking-barrier):强不变式靠屏障维持。

**Q5:压缩(evacuate)为什么必要?**
标记-清除留碎片:滑动压缩还整页(:4717-4746)。

**Q6:大对象怎么回收?**
不搬:LO 页整页转正/直接释放(:1603-1624,:5237-5253)。

**Q7:空闲时 GC 吗?**
MemoryReducer 空闲后收缩堆(:18-21);IncrementalMarkingJob 推进增量——IdleNotification 已移除。

**Q8:MinorMS 是什么?**
新生代标记-清除替代复制(实验 flag :3822-3823):避免复制的搬运成本。

**Q9:GC 触发的信号?**
分配压力(observer 步进)+内存 reducer+手动——无定时器。

**Q10:什么在 GC 里最贵?**
evacuate(复制+修指针)与标记扫描——所以并发化/增量化都先动它们。

## 5.7 小结与卷末语

本章结论:**GC="分代分工+单方向写屏障+并发增量标记+两阶段压缩"**;Orinoco 的全部工程都为一条 KPI:主线程停顿。

至此《V8 深读》精简卷完(01-05,基线 commit c6a1f7c2,5 章+5 报告):堆→解析→解释→对象→回收。与 QuickJS 卷(第五系列二)对读,即为"脚本引擎的最小实现与最大实现"的完整光谱。深挖:

1. Scavenger 页队列(:1732-1738)的负载均衡在倾斜存活率的退化;
2. 组合屏障(:51-79)与 JIT 内联屏障的代码路径;
3. evacuate 三模式(:4717-4746)的选择启发式;
4. MemoryReducer 状态机(:18-21)的参数在移动端;
5. MinorMS 转正路径(flag :3822-3823)的社区数据。

— 《V8 深读》精简卷完。AI 编码助手:GLM-5.3-Flash。
