# E - V8 GC 与 Orinoco 深度调研报告

> 源码基线:V8 shallow clone,commit `c6a1f7c2`(`c6a1f7c29ac6381b8b81ff8eff55ff7587c52bf2`,ppc64: Replace r0 with TemporaryRegisterScope in TypedArrayElementOperand)。所有 `文件:行号` 均以该 commit 核实。
>
> **勘误声明(相对旧版报告)**:
> 1. 本 commit 中 **不存在 `src/heap/scavenger-inl.h`**(仅有 `scavenger.cc` / `scavenger.h`),旧报告引用的 scavenger-inl.h 坐标已并入 scavenger.cc;
> 2. `GenerationalBarrierSlow` 已不在 `heap-write-barrier-inl.h:404-417`(该区间现为 `MarkingForRelocInfo`/`SharedForRelocInfo`,见 heap-write-barrier-inl.h:400-417),实际实现移至 `src/heap/heap-write-barrier.cc:404-418`;
> 3. **`IdleNotification` 已彻底移除**(全 src/ 零命中),空闲时段 GC 节奏由 `MemoryReducer` + `IncrementalMarkingJob`(src/heap/incremental-marking-job.cc)承担;
> 4. 旧坐标 `new-spaces-inl.h:1976-1984`(map word CAS)实际位于 `scavenger.cc:1976-1977`(new-spaces-inl.h 全文仅 99 行)。

---

## 1. 全景:GC 家族与空间映射

V8 的堆按"代际 + 空间"组织,四个 GC 组件各管一段:

```
                        V8 堆布局 x GC 组件全景
 ┌───────────────────────────────────────────────────────────────────┐
 │  年轻代 (Young Generation)                                        │
 │  ┌─────────────────┐  ┌─────────────────┐                         │
 │  │ SemiSpace (From) │  │ SemiSpace (To)   │ <-- Scavenger 负责      │
 │  │ (分配发生地,     │  │ (存活者复制目标)  │   Cheney 复制算法       │
 │  │  age mark 之下   │  └─────────────────┘   STW,亚毫秒~毫秒级    │
 │  │  旧对象直接晋升)  │                                        │
 │  └─────────────────┘   [minor_ms 开启时: 单空间 + 标记-清扫,     │
 │                          由 MinorMarkSweep 负责,STW]             │
 ├───────────────────────────────────────────────────────────────────┤
 │  老年代 (Old Space)          <-- Mark-Compact (主 GC)              │
 │    增量标记 IncrementalMarking 与应用交替执行 (步进 ≤1ms/5ms)      │
 │    并发标记 ConcurrentMarking 在后台线程进行                       │
 │    最终一次原子 pause: 标记收尾 + 清扫/压缩 ( evacuation )          │
 │    停顿特征: 增量化后单次 pause 仍为全家族中最长                    │
 ├───────────────────────────────────────────────────────────────────┤
 │  大对象空间 (LO Space) / 代码空间 / 共享空间 / Trusted 空间         │
 │    分别由 Mark-Compact 兼管; 新大对象空间由 Scavenger 兼管          │
 ├───────────────────────────────────────────────────────────────────┤
 │  横切机制: 写屏障 (WriteBarrier) 维护 OLD_TO_NEW 记忆集;           │
 │            MemoryReducer 在空闲时触发压缩式 full GC 降内存          │
 └───────────────────────────────────────────────────────────────────┘
```

入口分派在 `Heap::PerformGarbageCollection` 中,三分支一目了然(src/heap/heap.cc:2287-2294):

```cpp
if (collector == GarbageCollector::MARK_COMPACTOR) {
  MarkCompact();
} else if (collector == GarbageCollector::MINOR_MARK_SWEEPER) {
  MinorMarkSweep();
} else {
  DCHECK_EQ(GarbageCollector::SCAVENGER, collector);
  Scavenge();
}
```

- `Heap::Scavenge()`:src/heap/heap.cc:2617-2628,注释直接写明 "Implements Cheney's copying algorithm"(heap.cc:2624),然后委托给 `scavenger_collector_->CollectGarbage()`。
- `Heap::MarkCompact()`:heap.cc:2551-2582,含 pretenuring 反馈评估(2572-2574)。
- `Heap::MinorMarkSweep()`:heap.cc:2584-2595,受实验旗标 `minor_ms` 控制(flag-definitions.h:3822,且 DEFINE_IMPLICATION(minor_ms, page_promotion),flag-definitions.h:3823)。

"Orinoco" 是 V8 并行/并发 GC 项目的内部代号,在当前源码里唯一残留于旗标注释 "Parallel and concurrent GC (Orinoco) related flags"(src/flags/flag-definitions.h:4267)。

## 2. Scavenger 专节:半空间复制、晋升与并行任务

### 2.1 Cheney 复制与晋升决策

新对象在 SemiSpace 顺序分配;Scavenge 时存活者被复制到 To 空间或晋升老年代。核心分派在 `EvacuateObjectDefault`(src/heap/scavenger.cc:2110-2150):

```cpp
if (!ShouldBePromoted(object.address())) {
  // A semi-space copy may fail due to fragmentation. In that case, we
  // try to promote the object.
  if (SemiSpaceCopyObject(map, slot, object, object_size, object_fields))
      [[likely]] {
    return RememberedSetEntryNeeded(heap_, slot);
  }
}
// We may want to promote this object if the object was already semi-space
// copied in a previous young generation GC or if the semi-space copy above
// failed.
if (PromoteObject<THeapObjectSlot, promotion_heap_choice>(
        map, slot, object, object_size, object_fields)) [[likely]] {
  return RememberedSetEntryNeeded(heap_, slot);
}
// If promotion failed, we try to copy the object to the other semi-space.
if (SemiSpaceCopyObject(map, slot, object, object_size, object_fields)) { ... }
heap()->FatalProcessOutOfMemory("Scavenger: semi-space copy");
```

三级降级策略:半空间复制 → 晋升老年代 → 另一半空间复制 → OOM(scavenger.cc:2126-2149)。

**晋升条件 = "age mark 之下"**。`Scavenger::ShouldBePromoted` 直接转调 `semi_space_new_space()->ShouldBePromoted`(scavenger.cc:2090);后者在 src/heap/new-spaces-inl.h:92-93:

```cpp
bool SemiSpaceNewSpace::ShouldBePromoted(Address object) const {
  return IsAddressBelowAgeMark(object);
}
```

age mark 是上次 Scavenge 结束时的分配水位线:`SetAgeMarkAndBelowAgeMarkPageFlags()` 把 `age_mark_ = allocation_top()`(src/heap/new-spaces.cc:429-431,在每轮 minor GC 收尾处调用,new-spaces.cc:687)。判定逻辑见 new-spaces-inl.h:80-89:低于 age mark 的对象已"经历"过至少一轮 GC,再次存活即晋升。这正是"两轮存活进老年代"的传统分代启发式。

### 2.2 并行 Scavenge job

Scavenge 不再是纯主线程操作。在根遍历开始**之前**就把并行 job 投递出去,让后台线程先处理 old_to_new 页(scavenger.cc:1724-1738):

```cpp
// Start the parallel scavenger job before iterating roots. This allows
// background threads to start processing old_to_new pages while the main
// thread iterates roots in parallel.
...
std::atomic<size_t> estimate_concurrency{0};
auto job = std::make_unique<ScavengerJobTask>(
    heap_, &scavengers, std::move(old_to_new_chunks), copied_list,
    promoted_list, estimate_concurrency);
...
std::unique_ptr<JobHandle> job_handle = V8::GetCurrentPlatform()->PostJob(
    v8::TaskPriority::kUserBlocking, std::move(job));
```

### 2.3 多线程复制的正确性:map word CAS

并行复制的关键是"谁先把转发指针写进去"。`TryMigrateObject` 用 relaxed CAS 抢占(scavenger.cc:1976-1977):

```cpp
// This CAS can be relaxed because we do not access the object body if the
// object was already copied by another thread. We only access the page header
// of such objects and this is safe because of the memory fence after page
// header initialization.
if (!source->relaxed_compare_and_swap_map_word_forwarded(
        MapWord::FromMap(map), target)) {
  // Other task migrated the object.
  allocator_.FreeLast(space, target, object_size);
  ...
```

CAS 失败者释放刚分配的内存,读转发指针重定向槽位(scavenger.cc:1979-1986);CAS 成功者在 CAS **之后**才拷贝对象体,避免失败路径上的无用拷贝(scavenger.cc:1985-1991 注释)。relaxed 序够用的论证就在注释里:输家只访问页头,而页头初始化后有内存栅栏(scavenger.cc:1972-1975)。

槽位是否要进记忆集,由 `RememberedSetEntryNeeded` 决定:对象落在 To 页、或落在将整页晋升的 From 页时保留槽位记录(scavenger.cc:2095-2107)。

## 3. 写屏障专节:OLD_TO_NEW 单向性、SlotSet 与组合屏障

### 3.1 为什么只需要 OLD→NEW 单方向

年轻代 GC(Scavenge)的根集合包含"老年代指向年轻代的指针"。若不做记录,每次 minor GC 都得扫描整个老年代。因此只在**宿主(host)在老年代、值(value)在年轻代**时记录。反过来 NEW→OLD 无需记录:老年代 GC 会完整标记遍历,天然覆盖从年轻代出发的指针。

入口 `WriteBarrier::ForValue` 做 SKIP 模式过滤后统一进入 `CombinedWriteBarrierInternal`(src/heap/heap-write-barrier-inl.h:124-137)。快速路径两级剪枝(heap-write-barrier-inl.h:62-76):

```cpp
MemoryChunk* host_chunk = MemoryChunk::FromHeapObject(host);
// Fast path: Marking is off and the host objects is either in the young
// generation or shared space, for which we don't require remembered sets.
if (!host_chunk->PointersFromHereAreInteresting()) [[likely]] {
  return;
}
// Either marking is on, or the host objects is in the old (non-shared)
// generation for which we record remembered sets.
MemoryChunk* value_chunk = MemoryChunk::FromHeapObject(value);
// Old to old writes can bail out when marking is off.
if (!value_chunk->PointersToHereAreInteresting()) {
  return;
}
```

- 宿主在年轻代/共享空间 → 从这里出发的指针"无趣"(minor GC 本来就会扫它),直接返回,这就是单方向性的位图级表达;
- 值也在老年代且未在标记 → OLD_TO_OLD 无需记忆集,同样剪枝。

### 3.2 组合屏障:代际 + 共享 + 标记三合一

慢路径 `CombinedWriteBarrierInternalSlow`(heap-write-barrier.cc:381-399)依次做两件事:代际/共享屏障(388-395)+ 标记屏障(397-399)。代际分支再按值的位置分流(heap-write-barrier.cc:369-378):

```cpp
void WriteBarrier::CombinedGenerationalAndSharedBarrierSlow(
    Tagged<HeapObject> object, Address slot, Tagged<HeapObject> value) {
  if (V8_LIKELY(HeapLayout::InYoungGeneration(value))) {
    GenerationalBarrierSlow(object, slot, value);
  } else {
    DCHECK(MemoryChunk::FromHeapObject(value)->InWritableSharedSpace());
    ...
    SharedHeapBarrierSlow(object, slot);
  }
}
```

`GenerationalBarrierSlow`(heap-write-barrier.cc:404-418)区分主线程与后台线程,分别写入两套记忆集:

```cpp
if (local_heap->is_main_thread()) {
  RememberedSet<OLD_TO_NEW>::Insert<AccessMode::NON_ATOMIC>(
      host_page, host_chunk->Offset(slot));
} else {
  RememberedSet<OLD_TO_NEW_BACKGROUND>::Insert<AccessMode::ATOMIC>(
      host_page, host_chunk->Offset(slot));
}
```

主线程插入无竞争可用 NON_ATOMIC;后台线程(并发标记期间的写)必须 ATOMIC——同一页可能被多线程同时插槽。

### 3.3 SlotSet:记忆集的页级组织

每个(可能持有 old_to_new 指针的)页挂一个 SlotSet,按 bucket/cell 两级位图组织(src/heap/base/basic-slot-set.h:277-285):

```cpp
static constexpr int kCellsPerBucket = 32;
static constexpr int kCellsPerBucketLog2 = 5;
static constexpr int kCellSizeBytesLog2 = 2;
static constexpr int kCellSizeBytes = 1 << kCellSizeBytesLog2;
static constexpr int kBitsPerCell = 32;
static constexpr int kBitsPerCellLog2 = 5;
static constexpr int kBitsPerBucket = kCellsPerBucket * kBitsPerCell;
```

即:1 cell = 4 字节 = 32 个槽位;1 bucket = 32 cells = 1024 个槽位,覆盖 1024 个字(约 8KB @ 64 位压缩指针桶粒度按页内偏移换算)。bucket 惰性分配、空了可释放(`EmptyBucketMode::FREE_EMPTY_BUCKETS`,basic-slot-set.h:271-273),遍历接口 `Iterate` 以 callback 回调每个已置位槽(basic-slot-set.h:265-275)。Scavenge 据此只回调老年代页上真正指向年轻代的槽,无需扫整页。

## 4. Mark-Compact 专节:单 markbit 隐式三色、增量步进与 evacuate 三模式

### 4.1 单 markbit 的隐式三色抽象

V8 每对象只有一个 `MarkBit`(src/heap/marking.h:19-61,位图 cell 常量在 marking.h:99-103),没有独立的"灰位":

- 白 = markbit 为 0;
- 黑 = markbit 已置位;
- 灰 = markbit 为 0 **且已入标记工作列表**(marking-worklist.h:156 `Push`)。

"发现即置位、置位成功才入队"是原子去重:`MarkBit::Set` 返回 "true if it succeeded to transition the bit from 0 to 1"(marking.h:33-36,NON_ATOMIC 版本实现 marking.h:64-69)。并发标记下这个 0→1 的 CAS 语义保证了每个对象恰好入队一次——三色不变式被(黑完成/灰入队)这个编码隐式维护,教科书式的 implicit tricolor。

### 4.2 增量标记步进:两条驱动线与时间预算

增量标记把 mark-slice 切碎与应用线程交替执行。步进有两个硬预算(src/heap/incremental-marking.cc:56-60):任务驱动 `kMaxStepSizeOnTask = 1ms`,分配驱动 `kMaxStepSizeOnAllocation = 5ms`(并 static_assert 不得超过单次同步 GC 操作上限)。

分配驱动的挂接点是一对 allocation observer 步长(incremental-marking.cc:53-54):

```cpp
static constexpr size_t kMajorGCYoungGenerationAllocationObserverStep = 64 * KB;
static constexpr size_t kMajorGCOldGenerationAllocationObserverStep = 256 * KB;
```

即每分配 64KB(年轻代)/256KB(老年代)就插一次 `AdvanceOnAllocation`(incremental-marking.cc:738-756):

```cpp
void IncrementalMarking::AdvanceOnAllocation() {
  ...
  const size_t max_bytes_to_process = GetScheduledBytes(StepOrigin::kV8);
  Step(GetMaxDuration(StepOrigin::kV8), max_bytes_to_process, StepOrigin::kV8);
  ...
  if (IsMajorMarkingComplete() && !ShouldWaitForTask() &&
      !heap()->always_allocate()) {
    // When completion task isn't run soon enough, fall back to stack guard to
    // force completion.
    major_collection_requested_via_stack_guard_ = true;
    isolate()->stack_guard()->RequestGC();
  }
}
```

标记完成后若 completion task 没能及时运行,则用 stack guard 中断强制收尾(incremental-marking.cc:746-755)——这是增量标记从"纯任务调度"到"急迫兜底"的第二保险。

### 4.3 Evacuate 三模式

Mark-Compact 的迁移(压缩)由并行 `Evacuator` 执行,三种模式一个枚举(src/heap/mark-compact.cc:4717-4721):

```cpp
enum EvacuationMode {
  kObjectsNewToOld,
  kPageNewToOld,
  kObjectsOldToOld,
};
```

模式选择函数明确了优先级(mark-compact.cc:4735-4745):

```cpp
static inline EvacuationMode ComputeEvacuationMode(
    const MutablePage* metadata) {
  // Note: The order of checks is important in this function.
  if (metadata->will_be_promoted()) {
    return kPageNewToOld;
  }
  if (metadata->Chunk()->InYoungGeneration()) {
    return kObjectsNewToOld;
  }
  return kObjectsOldToOld;
}
```

- `kObjectsNewToOld`:年轻代对象逐个疏散晋升(常规路径);
- `kPageNewToOld`:整页晋升——页级迁移,免逐对象拷贝(与 `minor_ms → page_promotion` 旗标联动,flag-definitions.h:3823);
- `kObjectsOldToOld`:老年代页内/页间压缩,消除碎片,这是 Mark-Compact 相对 Scavenger 独有的"整理"能力。

## 5. 触发与节奏:分配 observer、内存限额与 MemoryReducer 状态机

**年轻代**:主要由 semi-space 填满触发;分配 observer 体系在 `allocator()->AddAllocationObserver` 处统一挂接(heap.cc:1012)。

**老年代增量标记启动**:`StartIncrementalMarkingIfAllocationLimitIsReached`(heap.cc:1939-1960)在达到 `kHardLimit` 时启动增量标记(heap.cc:1946-1953);非主线程则通过 `stack_guard()->RequestStartIncrementalMarking()` 并调度 IncrementalMarkingJob 任务(heap.cc:1954-1959)。

**空闲降内存:MemoryReducer 有限状态机**。四个状态(src/heap/memory-reducer.h:89):

```cpp
enum Id { kUninit, kDone, kWait, kRun };
```

转移函数 `MemoryReducer::Step`(memory-reducer.cc:157-216):`kDone` 态收到 `kMarkCompact` 事件且提交内存超过上次运行时的 `max(1.1x, +10MB)` 才重新武装(memory-reducer.cc:167-178);`kWait` 态等定时器到期且允许启动增量 GC 时进入 `kRun` 发起一次 GC(memory-reducer.cc:190-201),次数上限用尽则回 `kDone`。

节流常量(memory-reducer.cc:18-21):

```cpp
const int MemoryReducer::kShortDelayMs = 500;
const int MemoryReducer::kWatchdogDelayMs = 100000;
const double MemoryReducer::kCommittedMemoryFactor = 1.1;
const size_t MemoryReducer::kCommittedMemoryDelta = 10 * MB;
```

500ms 短延迟防抖,100 秒 watchdog 兜底(长期空闲也强制考虑降内存)。`kRun` 触发的是带 `GCFlag::kReduceMemoryFootprint` 的 full GC(heap.cc:4035 一带路径)。它请求的是"可选的"压缩式 GC——与分配限额触发的"必需的"GC 在语义上分离。

## 6. 设计动机

1. **分代的统计学依据**:绝大多数对象朝生夕死。Scavenger 只处理存活者,成本与存活量成正比而与垃圾量无关(heap.cc:2624 Cheney 注释即此立场);age mark 两轮存活启发式(new-spaces-inl.h:92-93)用近乎零成本的地址比较近似"对象是否长寿"。
2. **Orinoco 的停顿控制目标**:代号对应的旗标族 `single_threaded_gc` 一口气关闭 background tasks / concurrent_marking / concurrent_sweeping / parallel_compaction / parallel_marking / parallel_pointer_update / parallel_gc_clearing / parallel_scavenge 等(flag-definitions.h:4269-4279)——反过来看,Orinoco 的本体就是"把每一相都尽量搬出主线程":并行 Scavenge job 先于根遍历投递(scavenger.cc:1725-1738)、并发标记、增量步进 1ms/5ms 预算(incremental-marking.cc:56-60)共同把 stop-the-world 切成小片。
3. **压缩的取舍**:疏散(拷贝存活对象)换连续内存与指针碰撞分配,但拷贝有成本。因此 Mark-Compact 只对"值得"的页做 `kObjectsOldToOld`(fragmentation 驱动),年轻代走对象级或页级晋升(mark-compact.cc:4735-4745);MinorMS 实验路线干脆放弃复制改用标记-清扫+页晋升(flag-definitions.h:3822-3823),适合存活率高的场景。
4. **写屏障的单向性是分代的杠杆**:只记录 OLD→NEW(heap-write-barrier-inl.h:63-67),minor GC 才能免扫老年代;SlotSet 的 1024 槽/bucket 位图组织(basic-slot-set.h:277-285)让"扫记忆集"的代价正比于跨代指针数,而非老年代体积。

## 7. FAQ

**Q1: Scavenge 是 stop-the-world 吗?**
是原子 pause,但工作并行化:主线程遍历根的同时后台线程已在处理 old_to_new 页(scavenger.cc:1725-1727 注释、1737-1738 PostJob)。

**Q2: 对象何时从新生代进入老年代?**
低于 age mark(即上轮 GC 前已分配且仍存活)就应晋升(new-spaces-inl.h:92-93);此外半空间复制失败也会强制晋升(scavenger.cc:2135-2141),大对象走 `HandleLargeObject` 单独路径(scavenger.cc:2120)。

**Q3: age mark 具体是什么时候更新的?**
每轮 minor GC 结束时设为当前分配水位 `allocation_top()`(new-spaces.cc:429-431、687)。

**Q4: 为什么写屏障不需要 NEW→OLD 方向?**
老年代 GC 的标记是全堆遍历,NEW→OLD 边天然被走到;而 minor GC 只扫根+记忆集,OLD→NEW 边若不记录就会漏标。快速路径以 `PointersFromHereAreInteresting` 位直接表达(heap-write-barrier-inl.h:65-67)。

**Q5: 一个 MarkBit 怎么表达三种颜色?**
白=0,黑=1,灰="0 但在工作列表中"。0→1 置位成功才入队(marking.h:33-36),天然去重,并发安全靠 ATOMIC 版本的位 CAS(marking.h:71-73)。

**Q6: 增量标记每次步进多久?**
任务驱动 ≤1ms,分配驱动 ≤5ms(incremental-marking.cc:56-60);触发频率由 64KB/256KB observer 步长控制(incremental-marking.cc:53-54)。

**Q7: IdleNotification 去哪了?**
已删除(全源码零命中)。空闲节奏由 MemoryReducer 的 500ms/100s 定时器(memory-reducer.cc:18-19)和 IncrementalMarkingJob 接管。

**Q8: MinorMS 和 Scavenger 怎么选?**
旗标 `minor_ms` 实验特性(flag-definitions.h:3822),运行时堆层在 heap.cc:2289-2290 分派;MinorMS 意味着页晋升依赖(flag-definitions.h:3823),牺牲复制收益换低拷贝开销。

**Q9: 记忆集为什么会分 OLD_TO_NEW 和 OLD_TO_NEW_BACKGROUND 两套?**
并发场景下后台线程也写堆,需要 ATOMIC 插入;主线程独占路径用 NON_ATOMIC 即可(heap-write-barrier.cc:411-417)。分集合也便于 minor GC 分相处理。

**Q10: CAS 为什么要 relaxed 序就够?**
输家线程不读对象体,只读页头,而页头初始化后有栅栏保证可见性——论证见 scavenger.cc:1972-1975 注释。

## 8. 深挖

1. **复制与 CAS 的次序优化**:`TryMigrateObject` 刻意"先 CAS 后拷贝"(scavenger.cc:1985-1991 注释),失败者免拷贝、且降低对内存序的要求;这是 lock-free 算法里"用工作顺序换同步开销"的范本。
2. **晋升失败的三级降级链**:半空间复制→晋升→对侧半空间复制→FatalProcessOutOfMemory(scavenger.cc:2126-2149),注意第二次复制可能成功——说明第一失败源自目标半空间碎片而非对象过大。
3. **组合屏障的分派树**:ForValue → CombinedWriteBarrierInternal(两级位剪枝,heap-write-barrier-inl.h:62-76)→ Slow(代际/共享 + 标记双发,heap-write-barrier.cc:381-399)→ Generational/Shared 二选一(369-378)。值得画一张决策树,每一层都有明确的剪枝谓词。
4. **MemoryReducer 的"只增不减"武装条件**:提交内存须超过 `max(1.1x, +10MB)` 才肯再跑(memory-reducer.cc:167-172)——防止"降内存 GC 自己触发降内存 GC"的自激振荡。
5. **页晋升(kPageNewToOld)为何检查顺序不可换**:mark-compact.cc:4737 注释 "The order of checks is important"——`will_be_promoted` 是更强的条件(整页搬迁),先于年轻代判断,否则会被误判为逐对象模式。

## 9. 写作要点速查表

| # | 要点 | 坐标 |
|---|------|------|
| 1 | 三收集器分派:MARK_COMPACTOR/MINOR_MARK_SWEEPER/SCAVENGER | heap.cc:2287-2294 |
| 2 | "Implements Cheney's copying algorithm" 注释 | heap.cc:2624 |
| 3 | MarkCompact 主体(pretenuring 评估在 2572) | heap.cc:2551-2582 |
| 4 | MinorMarkSweep 主体 | heap.cc:2584-2595 |
| 5 | 并行 Scavenge job 先于根遍历投递 | scavenger.cc:1724-1738 |
| 6 | EvacuateObjectDefault 三级降级复制/晋升 | scavenger.cc:2110-2150 |
| 7 | 晋升条件 = age mark 之下 | new-spaces-inl.h:92-93(判定 80-89) |
| 8 | age mark 更新为 allocation_top | new-spaces.cc:429-431、687 |
| 9 | map word relaxed CAS 抢占转发 | scavenger.cc:1976-1977(论证 1972-1975) |
| 10 | 组合屏障快速路径两级剪枝 | heap-write-barrier-inl.h:62-76(入口 124-137) |
| 11 | GenerationalBarrierSlow 双记忆集(勘误:已移文件) | heap-write-barrier.cc:404-418 |
| 12 | OLD_TO_NEW 单方向/共享屏障分流 | heap-write-barrier.cc:369-378 |
| 13 | SlotSet:32 cells/bucket、32 bit/cell | basic-slot-set.h:277-285 |
| 14 | 单 MarkBit + 工作列表 = 隐式三色 | marking.h:19-43(Set 语义 33-36) |
| 15 | 增量步进预算 1ms/5ms | incremental-marking.cc:56-60 |
| 16 | observer 步长 64KB/256KB | incremental-marking.cc:53-54 |
| 17 | AdvanceOnAllocation + stack guard 兜底 | incremental-marking.cc:738-756 |
| 18 | evacuate 三模式与优先级(检查顺序敏感) | mark-compact.cc:4717-4721、4735-4745 |
| 19 | 增量标记硬限额启动/跨线程 stack guard | heap.cc:1939-1960 |
| 20 | MemoryReducer 状态机 kUninit/kDone/kWait/kRun | memory-reducer.h:89;Step: memory-reducer.cc:157-216 |
| 21 | 节流常量 500ms/100s/1.1x/+10MB | memory-reducer.cc:18-21 |
| 22 | Orinoco 唯一出处:single_threaded_gc 旗标族 | flag-definitions.h:4266-4279(4267) |

---

### 覆盖声明

- 本报告全部论断基于 commit `c6a1f7c2` 复核;与任务给定坐标的差异(GenerationalBarrierSlow 迁移、CAS 行号归属、无 scavenger-inl.h、IdleNotification 移除)已在文首勘误声明列明。
- 未覆盖:C++ 堆(cppgc)联动、数组缓冲清扫器(ArrayBufferSweeper)、保守栈扫描细节——均属独立专题。
