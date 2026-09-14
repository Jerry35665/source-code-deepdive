# 第 01 章 · Isolate 与堆:句柄、分代与 Zone

> 基线:commit `c6a1f7c2`。行号以 src/execution/isolate.h/.cc、src/heap/、src/handles/、src/zone/ 为准。

## 1.0 全景:V8 的分层

```
API 层:v8::Isolate / Context / HandleScope
执行层:ThreadLocalTop / Ignition → TurboFan
堆:Heap(十余个 Space 分代)
对象:tagged 指针(低位打标:Smi/HeapObject)
Zone arena:解析/编译期的非托管内存
```

**Isolate 就是一个禁 new 的 C++ 类**(isolate.h:564),只能工厂创建(isolate.cc:4736);**Heap heap_ 内嵌其中**(:2655)——一个 Isolate 一座堆。IsolateData(:2645)是 JIT 热数据的首成员(isolate_root 基点 :1295),聚合 roots/外参表;编译缓存(:2669)、global handles(:2693)、string_table(:2659)。线程关系不绑死:PerIsolateThreadData(:581)记录线程×isolate 绑定,Enter/Exit(isolate.cc:6679/:6728)压弹 entry_stack_ 并设 TLS(:558/:661);当前 Context 存 ThreadLocalTop::context_(thread-local-top.h:108),Context 本身是堆对象(contexts.h:497)。

## 1.1 堆空间:分代与分配路径

AllocationSpace 枚举(src/common/globals.h:1473-1490):RO(只读)/NEW(新生代)/OLD/CODE/SHARED/TRUSTED+各自 Large Object 变体。分配分派 `HeapAllocator::AllocateRaw`(heap-allocator-inl.h:90,:141-175):kYoung/kOld/kCode 走各空间的 **bump 分配**(线性分配器);**大对象阈值=半页 128KB**(页 256KB,globals.h:743;base/build_config.h:80),LO 派发 heap-allocator.cc:91-135;CodeSpace 是 PagedSpace(EXECUTABLE)+CodeRange 可执行笼(paged-spaces.h:505-513;code-range.h:82)——代码单独空间为权限与 IC 补丁服务。

## 1.2 Handle:GC 移动世界的安全间接层

GC 会移动对象,直接持指针会在压缩后悬空——句柄=**槽指针的间接层**。HandleScopeData{next,limit,level}(v8-internal.h:957)放 IsolateData 热区(isolate-data.h:390);HandleScope ctor 存档 next/limit(handles-inl.h:176),dtor→CloseScope **O(1) 批量回收**(:198-252);每块 1022 个槽(handle-scope-implementer.h:128);逃逸用手工 CloseAndEscape(:257);Global Handles 是栈外注册表带弱回调(global-handles.h:46-60;api.cc:693)。**模式纪律**:临时对象的句柄进当前 scope,scope 退出批量作废——C++ 里模拟"代际生命周期"。

## 1.3 tag 与 Zone

tag 常量:kHeapObjectTag=1、kWeak=3(2 位 tag)、kSmiTag=0(include/v8-internal.h:58-77);Smi 位宽:压缩模式 31 位/未压缩 64 位存高半字(:84-85,:135-136);HeapObject 的 **map 恒在偏移 0**,ptr=addr+1(heap-object.h:353,:140)。Zone:bump 分配、8-32KB 段、DeleteAll 整段归还(zone.h:53-70,:233-236;zone.cc:110)——解析/编译期 AST/IR 专用,**生命周期绑定"一次编译"**,与 GC 堆完全正交(呼应 llama.cpp arena,第一系列)。

## 1.4 设计动机

1. **分代的动机**:弱分代假说(对象朝生夕死)——新生代复制收集、老生代标记压缩,各自最优;
2. **Handle 的成本与必要性**:每对象访问多一次间接;没有它,GC 压缩时需要全栈扫描修指针——**间接层买回收集自由**;
3. **Zone 与 GC 正交**:编译期对象生命周期确定(一次编译),不需要 GC——arena 是"已知生命周期的免费午餐";
4. **IsolateData 热区**:JIT 代码要快速访问 roots/句柄栈——数据布局为机器码访存优化(放对象首成员=root 基址偏移固定)。

## 1.5 FAQ

**Q1:Isolate 和 Context 什么区别?**
Isolate=堆+执行状态(重);Context=全局对象+内置(轻,可多个)。

**Q2:Handle 泄漏会怎样?**
scope 不退出→句柄堆积→老生代假性存活→内存涨——HandleScope 纪律是嵌入第一课。

**Q3:Smi 是什么?**
Small integer 直接编码在指针里(tag 0),无需堆分配(v8-internal.h:58-77)。

**Q4:为什么代码空间单独?**
可执行权限页+IC 写补丁+紧凑缓存:权限与生命周期都不同。

**Q5:大对象的阈值?**
半页 128KB(globals.h:743):复制/搬动成本超页管理的临界。

**Q6:Zone 会泄漏吗?**
生命周期绑定编译任务:DeleteAll 整段归还(zone.cc:110)。

**Q7:Isolate 能跨线程共享吗?**
不能直接共享(每线程 Enter/Exit 串行进入):V8 的并发靠后台任务(编译/GC)而非共享执行。

**Q8:Global Handle 与 WeakRef?**
global-handles 的弱回调(:46-60)是 WeakRef/FinalizationRegistry 的底层。

**Q9:map 为什么在偏移 0?**
所有内建/JIT 代码热访问 Map:固定偏移=单次加载。

**Q10:压缩指针是什么?**
31 位 Smi+堆 cage 内 32 位指针:省一半内存(tag 体系容纳)。

## 1.6 小结与深挖方向

本章结论:**V8 地基="Isolate 聚合+分代堆+Handle 间接+tag 指针+Zone 正交"**。深挖:

1. AlignedAlloc 工厂(:4736)对 Isolate 对齐的要求来源;
2. HandleScope 块链(1022 槽)在深递归的扩展成本;
3. TRUSTED 空间(沙箱外可信代码)的访问控制;
4. Smi 31 位在 int64 语义的装箱时机;
5. Zone 段大小(8-32KB)的调优实测。

> 下一章:解析器与字节码——惰性两层与反馈向量。
