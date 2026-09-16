# K 章:并发标记与增量回收 —— V8 停顿控制的核心工程

> 源码:V8 shallow clone,commit `c6a1f7c2`(full: c6a1f7c29ac6381b8b81ff8eff55ff7587c52bf2),版本 15.5(include/v8-version.h:11-14)。所有行号以该 commit 为准。
> 本卷 E 章(《GC 与 Orinoco》)讲 GC 家族概览;本章专讲**并发标记(ConcurrentMarking)+ 增量步进(IncrementalMarking)+ 写屏障**,这三者是 V8 把 Major GC 停顿从"秒级"压到"毫秒级"的全部机关。

---

## 1. 全景:V8 GC 的并发模型

V8 的停顿控制不是单一技术,而是"并发(concurrent,后台线程干活)+ 增量(incremental,主线程切片干活)+ 并行(parallel,停顿内多线程干活)"三层叠加。一次 Major GC 的理想时间线:

```text
主线程(mutator)         后台标记线程(working set)         写屏障(每次指针写)
────────────────────────────────────────────────────────────────────────────►
 StartMarkingMajor:
   激活 marking barrier ──┐
   染黑根 + 黑分配        │→ PostJob(JobTaskMajor)         黑对象写入→标灰 value
   MarkRoots             │                                  (marking-barrier-inl.h:39)
        │                │  Pop→Visit→Push(64KB/1000obj
   [步进] Step(≤5ms)     │   检查一次 ShouldYield)          OLD→NEW 写入→SlotSet 记录
        │                │                                  (heap-write-barrier.cc:404)
   [步进] Step(≤5ms)     │  ephemeron / weak 处理
        │                │
 栈守卫 RequestGC ────────►│  FinalizeIncrementalMarkingAtomically
   ┌────────── atomic pause ──────────┐
   │ MarkLiveObjects: Stop()增量标记  │  Join() 收尾:Publish+Flush
   │ PublishAll + 重扫根 + 串行收敛    │  (concurrent-marking.cc:785,842)
   │ ── Sweep() / Evacuate()(并行) ── │
   └───────────────────────────────────┘
```

关键分工:

- **后台线程做"大头"**:对象图遍历主要由 `ConcurrentMarking::RunMajor` 在 worker 线程完成(concurrent-marking.cc:365-497);
- **主线程只做"切片"**:每个分配观察点/任务最多标 5ms/1ms(incremental-marking.cc:56-59,70-81);
- **写屏障保证并发正确性**:mutator 在标记期间把新引用的目标对象标灰(marking barrier),否则后台线程会漏标活对象;
- **最终停顿(atomic pause)只做收尾**:重扫根、ephemeron 收敛、弱引用清理、疏散与清扫(mark-compact.cc:2581-2676,531-558)。

一致性前提:并发标记要求对象字段写入是原子的,`#ifndef V8_ATOMIC_OBJECT_FIELD_WRITES` 时直接 `CHECK(!v8_flags.concurrent_marking)` 拒绝启用(concurrent-marking.cc:344-347)。

---

## 2. Scavenger 专节:半空间复制的并行化

新生代 Scavenge 是复制算法,其并行化的难点在于:**两个线程同时复制同一个对象必须只成功一次**。V8 15.5 的做法是"页为单位的 remembered set 任务 + 对象级 CAS 转发"两级并行。

### 2.1 任务拆分:ScavengerJobTask

主线程在根遍历**之前**就把 job 发出去,让后台线程先处理 OLD_TO_NEW remembered set 页:

```cpp
// src/heap/scavenger.cc:1725-1741(节选)
    // Start the parallel scavenger job before iterating roots. This allows
    // background threads to start processing old_to_new pages while the main
    // thread iterates roots in parallel.
    ...
    std::unique_ptr<JobHandle> job_handle = V8::GetCurrentPlatform()->PostJob(
        v8::TaskPriority::kUserBlocking, std::move(job));
```

- 要处理的页集在 GC 开始前一次性收集:凡有 `slot_set<OLD_TO_NEW>` / typed / background slot set 的页都进 `old_to_new_chunks`(scavenger.cc:1692-1705);
- 每个页是一个 `ParallelWorkItem`,`TryAcquire()` 抢页,抢到的线程跑 `ScavengePage` 遍历该页全部 OLD_TO_NEW 槽(scavenger.cc:807-823);
- `GetMaxConcurrency` 取 `max(剩余页数, worker数+copied+promoted 段数)`,电池模式压到 1(scavenger.cc:777-787);
- 根遍历完成后主线程 `NotifyConcurrencyIncrease()` 唤醒更多 worker(scavenger.cc:1769-1771)。

### 2.2 对象级并发:CAS 转发字

复制单个对象的原子性靠 map word 的 CAS:

```cpp
// src/heap/scavenger.cc:1972-1992(节选,TryMigrateObject)
  // This CAS can be relaxed because we do not access the object body if the
  // object was already copied by another thread. ...
  if (!source->relaxed_compare_and_swap_map_word_forwarded(
          MapWord::FromMap(map), target)) {
    // Other task migrated the object.
    allocator_.FreeLast(space, target, object_size);
    const MapWord map_word = source->map_word(kRelaxedLoad);
    UpdateHeapObjectReferenceSlot(slot, map_word.ToForwardingAddress(source));
    ...
  }
  // Copy the content of source to target. Note that we do this on purpose
  // *after* the CAS. ...
  target->set_map_word(map, kRelaxedStore);
  heap()->CopyBlock(target.address() + kTaggedSize, ...);
```

CAS 失败者直接回滚刚分配的空间并改用 forwarding address(scavenger.cc:1977-1984)——这就是"谁 CAS 成功谁复制,其他人只改槽"。

### 2.3 复制 vs 晋升决策(age mark)

`EvacuateObjectDefault` 的决策序(scavenger.cc:2112-2151):大对象走 `HandleLargeObject`(:2118);然后:

1. 对象地址**在 age mark 之上**(`!ShouldBePromoted`)→ 先尝试半空间复制(scavenger.cc:2126-2134);
2. 否则(已在 age mark 之下存活过一轮)直接晋升 `PromoteObject` 到 OLD_SPACE 或 SHARED_SPACE(scavenger.cc:2137-2141,2031-2057);
3. 复制失败(半空间满)也回退晋升;晋升失败再试另一-semispace 复制;全失败 `FatalProcessOutOfMemory`(scavenger.cc:2148)。

age mark 本身是**上一轮 scavenge 结束时的 to-space 分配顶**:`SetAgeMarkAndBelowAgeMarkPageFlags` 里 `age_mark_ = allocation_top()`(new-spaces.cc:429-455),判定就是一行比较 `address < age_mark`(new-spaces-inl.h:85-94,new-spaces.h:327/469)。效果:跨过一次 GC 仍存活的对象"二次幸存即晋升",两次复制是晋升的门票。

### 2.4 两条工作列表

每个 `Scavenger` 实例(每 worker 一个)持有本地 `local_copied_list_` / `local_promoted_list_`,段大小 256(scavenger.cc:281-292),新复制对象推入本地列表,`Process()` 循环弹出并遍历其字段(scavenger.cc:2540-2579);每处理 128 个对象(`kInterruptThreshold`,scavenger.cc:333)且全局池为空时 `NotifyConcurrencyIncrease()` 拉新 worker 进来。

---

## 3. 并发标记专节:三色的并发实现

### 3.1 markbit:三色的物理编码

V8 15.5 每对象**一个 markbit**(旧版的双 bit 方案已移除):白=0,黑=1,"灰"不是一个位,而是"位已置且还在标记 worklist 里"的状态。

位存储按页组织,bitmap 就在页 metadata 里:

```cpp
// src/heap/marking-inl.h:149-154
MarkingBitmap* MarkingBitmap::FromAddress(const Isolate* isolate,
                                          Address address) {
  Address metadata_address =
      MutablePage::FromAddress(isolate, address)->MetadataAddress();
  return Cast(metadata_address + MutablePage::MarkingBitmapOffset());
}
```

位寻址是纯移位:索引 = 页内偏移 >> kTaggedSizeLog2(marking-inl.h:184-187),cell 内掩码 `1 << (index & 63)`(marking.h:132-138)。置位的核心是 **0→1 迁移的原子 CAS 语义**,返回值即"我是不是第一个标它的人":

```cpp
// src/heap/marking.h:71-74
template <>
inline bool MarkBit::Set<AccessMode::ATOMIC>() {
  return base::AsAtomicWord::Relaxed_SetBits(cell_, mask_);
}
```

并发方用的是 `MarkingState::TryMark`(ATOMIC 访问模式,marking-state.h:23-36):返回 false 表示别人已标,直接丢弃,这是无锁去重的根基。清除只在无并发阶段(Clear 是非原子的,marking.h:86-90)。

### 3.2 worklist:分段 + 偷取

`MarkingWorklist = heap::base::Worklist<Tagged<HeapObject>, 64>`(marking-worklist.h:27)——64 个条目一段。全局池是一个带互斥锁的段链表(`Push/Pop` 整段搬运,worklist.h:101-125);每个线程持私有的 push/pop 两段,只有段满/段空才碰全局锁(worklist.h:393-411):

- `Local::Pop`:先吃自己 pop 段 → 与 push 段 swap → 再 `StealPopSegment()` 从全局池整段偷(worklist.h:402-411,462-471);
- **steal 的粒度是"一整段"而不是单元素**,锁竞争被摊薄 64 倍;
- `Publish()` 把本地两段推回全局池(worklist.h:430-439),是任务收尾动作。

三张全局列表(marking-worklist.h:118-124):`default_`(绝大多数对象)、`on_hold_`(新空间 LAB 中尚未提交的对象,注释明确说这是为了**不给新空间做黑分配**、让编译器能删掉新对象的写屏障)、`other_` 与 per-context 列表(内存测量 API 按域归属)。`MergeOnHold` 在步进的安全点把 on_hold 并回 default(marking-worklist.cc:210;incremental-marking.cc:825)。

### 3.3 后台任务:RunMajor 的中断检查

每个后台 worker 的主循环以"64KB 或 1000 个对象"为界检查一次是否该让出:

```cpp
// src/heap/concurrent-marking.cc:369-372, 418-427(节选)
  size_t kBytesUntilInterruptCheck = 64 * KB;
  int kObjectsUntilInterruptCheck = 1000;
  ...
    while (!done) {
      ...
      while (current_marked_bytes < kBytesUntilInterruptCheck &&
             objects_processed < kObjectsUntilInterruptCheck) {
        Tagged<HeapObject> object;
        if (!local_marking_worklists.Pop(&object)) { done = true; break; }
```

外层每轮 `delegate->ShouldYield()` 为真即退出(concurrent-marking.cc:469-472)——平台的 job 系统随时可抢占回收线程。收尾三件事:发布本地列表、发布弱对象列表、标记 ephemeron 需要再迭代(concurrent-marking.cc:479-488)。主线程 `Join()` 后还要 `FlushMemoryChunkData`:把每个 worker 缓存的 live-bytes(concurrent-marking.cc:67-131 的 32 项哈希缓存,避免每对象一次 CAS)和 code 页 typed slots 合并进 OLD_TO_OLD remembered set(concurrent-marking.cc:842-854)。

并发度控制也值得注意:`GetMajorMaxConcurrency` = `worker_count + max(worklist长度, ephemeron长度)`,上限为任务槽数;`ShouldOptimizeForBattery()` 时封顶 1(concurrent-marking.cc:607-620)。

### 3.4 增量步进:谁在驱动主线程

主线程的标记切片有三个驱动源:

1. **分配观察器**:新空间每 64KB、老空间每 256KB 触发 `AdvanceOnAllocation`(incremental-marking.cc:53-54,90-96);
2. **前台任务**:IncrementalMarkingJob 周期性 post 任务,`AdvanceAndFinalizeIfComplete`(incremental-marking-job.cc:53-77;incremental-marking.cc:713-721);
3. **栈守卫兜底**:标记完成但任务没跑完时,允许有限超时等待任务,超时则 `stack_guard()->RequestGC()` 强制收尾(incremental-marking.cc:749-755;超时计算 :605-681,允许 10% 标记总时长或至少 50ms 的 overshoot)。

每步该标多少字节由 `IncrementalMarkingSchedule` 决定:假设整个标记周期 500ms(`kEstimatedMarkingTime`,incremental-marking-schedule.h:51-52),则 t 时刻应已标记 `estimated_live_bytes * t / 500ms`;落后了就多标,领先了就只标最小步(incremental-marking-schedule.cc:99-130)。并发标记的字节数通过 `FetchBytesMarkedConcurrently` 非递减地喂回调度器(incremental-marking.cc:769-782)。

步的上限:任务来源 1ms、分配来源 5ms(incremental-marking.cc:56-59,70-81)。启动条件:不在 GC、反序列化完成、非 serializer(incremental-marking.cc:125-133);且老代或全局用量超过 8MB 阈值(:63-64,135-138)。

### 3.5 atomic pause 的存活工作

增量标记完成后 `FinalizeIncrementalMarkingAtomically` 只是一句 `CollectAllGarbage`(heap.cc:3790-3796)。停顿内的 `MarkLiveObjects`(mark-compact.cc:2581-2676)依次:

1. `incremental_marking->Stop()` + `MarkingBarrier::PublishAll`(把各 LocalHeap 屏障的本地 worklist 全部上缴,mark-compact.cc:2589-2591;marking-barrier.cc:370-384);
2. 重扫根(MC_MARK_ROOTS)、保守栈根(:2635-2643);
3. 并行收敛到不动点(`MarkTransitiveClosureFixpoint`,:2626-2633);weak map/ephemeron 与 CppHeap 要求最终**串行**收敛,故有 `CHECK(heap_->concurrent_marking()->IsStopped())` 后的单线程兜底(:2645-2665);
4. `MarkingBarrier::DeactivateAll` 关屏障——注释解释必须等并发标记结束,因为页标志与 evacuation candidate 位共享同一 bitmap(:2667-2672)。

注意本版流程里 `Sweep()` 在 `Evacuate()` **之前**(mark-compact.cc:556-557):清扫是并发/惰性的(sweeper.cc:357,390 post job),疏散页才是纯停顿工作,这就是"lazy sweeping"的当代形态——清扫不占停顿,停顿只 Reset 后续扫描。

---

## 4. write barrier 专节

### 4.1 组合屏障的快慢路径

所有指针写走 `CombinedWriteBarrierInternal`,快路径是两个页标志位判断:

```cpp
// src/heap/heap-write-barrier-inl.h:64-79(节选)
  MemoryChunk* host_chunk = MemoryChunk::FromHeapObject(host);
  // Fast path: Marking is off and the host objects is either in the young
  // generation or shared space, for which we don't require remembered sets.
  if (!host_chunk->PointersFromHereAreInteresting()) [[likely]] {
    return;
  }
  MemoryChunk* value_chunk = MemoryChunk::FromHeapObject(value);
  // Old to old writes can bail out when marking is off.
  if (!value_chunk->PointersToHereAreInteresting()) {
    return;
  }
  CombinedWriteBarrierInternalSlow(...);
```

两个页标志对应两个屏障:OLD 页的 `PointersFromHereAreInteresting` 管**代际屏障**(OLD→NEW 记录),`IsMarking` 管**标记屏障**。标记屏障的单行快路径:`if (!IsMarking(host)) return; MarkingSlow(host, slot, value);`(heap-write-barrier-inl.h:392-398)。

### 4.2 标记屏障:黑→白 染灰

`MarkingSlow` 最终到 `MarkingBarrier::Write` → `MarkValue` → `MarkValueLocal`(marking-barrier-inl.h:21-37,39-78,94-117):

```cpp
// src/heap/marking-barrier-inl.h:94-116(节选)
void MarkingBarrier::MarkValueLocal(Tagged<HeapObject> value) {
  if (is_minor()) {
    if (HeapLayout::InYoungGeneration(value)) {
      MarkingHelper::TryMarkAndPush(heap_, current_worklists_.get(), ...);
    }
  } else {
    const auto target_worklist = MarkingHelper::ShouldMarkObject(heap_, value);
    if (!target_worklist) return;
    MarkingHelper::TryMarkAndPush(heap_, current_worklists_.get(),
                                  &marking_state_, target_worklist.value(),
                                  value);
  }
}
```

`TryMarkAndPush` = `TryMark`(CAS 0→1,失败即已黑/灰,直接返回)+ push 本地 worklist——这就是三色不变式里"黑指向白时把白染灰"的写屏障(Dijkstra 风格,不做快照,无删除屏障,漏标由"对象死亡必须经由不可达路径"这一静态假设兜底,亦即依赖 ephemeron 补救,见 concurrent-marking.cc:169-181 的 `ProcessEphemeron`)。只读空间跳过(:41),黑分配页跳过(:57-59)。

屏障的激活/停用是全堆页标志翻转:`MarkingBarrier::ActivateAll` 遍历所有空间设 `kMajorMarking` 页标志并给每个 LocalHeap 建本地 worklist(marking-barrier.cc:272-311,303-311),客户端 isolate 也要强制 `SetIsMarkingFlag(true)` 把 RecordWrite builtin 压进标记路径(:280-291);MinorMS 版 `ActivateYoung` 同理(:295-301)。步进间主线程用 `PublishIfNeeded` 上缴 typed slots 并锁页互斥(marking-barrier.cc:393-407)。

屏障指针是 thread_local 的 `current_marking_barrier`(heap-write-barrier.cc:22,28-35),后台线程与主线程各持一份,免锁获取。

### 4.3 代际屏障:OLD→NEW 与 SlotSet 页组织

`GenerationalBarrierSlow` 把槽位记录进 host 页的 remembered set,主线程非原子、后台线程走独立的 `OLD_TO_NEW_BACKGROUND` 原子集合(heap-write-barrier.cc:404-417)。SlotSet 是两级位图:

```cpp
// src/heap/slot-set.h:127-132
class SlotSet final : public ::heap::base::BasicSlotSet<kTaggedSize> {
 public:
  static const int kBucketsRegularPage =
      (1 << kPageSizeBits) / kTaggedSize / kCellsPerBucket / kBitsPerCell;
```

- 一页 256KB、槽粒度 kTaggedSize(压缩指针 4 字节):256KB/4 = 64K 个可能槽位;每 bucket 是 32 个 uint32 cell = 1024 bit(basic-slot-set.h:277-285),故 `kBucketsRegularPage` = 64,即一页的槽集最多 64 个 bucket;
- Scavenge 时按 bucket 粒度并行:空 bucket 直接释放,`IterateAndTrackEmptyBuckets` 追踪"可能为空"的 bucket 留待复查(slot-set.h:29-31,159-184;PossiblyEmptyBuckets :26-90),因为后台晋升可能让 bucket 复活;
- Scavenger 遍历 OLD_TO_NEW 集合逐槽 `CheckAndScavengeObject`,返回 REMOVE_SLOT 即清位(scavenger.cc:2447-2462);code 页的 typed slots 分两轮遍历,把需要 JIT 内存的写操作集中到第二轮(scavenger.cc:2465-2510)。

---

## 5. evacuate 专节:页选择与并行拷贝

### 5.1 候选页选择:碎片率 + 配额

`CollectEvacuationCandidates`(mark-compact.cc:658-810)在**标记开始时**(增量模式下 `StartCompaction(kIncremental)`,incremental-marking.cc:270-271)选页。两条判据(mark-compact.cc:682-687 注释原文):

```text
* Target fragmentation: 页内存活字节/页容量的比率
* Evacuation quota: 本轮全局允许搬迁的字节上限
```

启发式:常规模式目标碎片率 70%、`kMaxEvacuatedBytes` 由 flag 给出、每页搬迁目标 0.5ms(mark-compact.cc:622-630);有足够样本后改用**实测压缩速度**反推目标碎片率(:637-650)。选择流程:过滤 `never_evacuate`/pinned 页(:700-716)→ 只留空余量 ≥ 阈值的页(:719-727)→ **按存活字节升序排序,从最空的页选起**直到配额耗尽(:775-791)→ 估算"迁入新页数"与"可释放页数",若释放不了任何页则整体放弃,避免 compact→expand 抖动(:793-801)。`AddEvacuationCandidate` 置页标志(:325-336)。

### 5.2 并行疏散:每 worker 一个 Evacuator

`EvacuatePagesInParallel`(mark-compact.cc:5178-5268)组一个页列表:新空间页先行(新空间疏散不可中止,:5186-5201),高存活新页走**整页晋升**(`ShouldMovePage`:live_bytes > `page_promotion_threshold`% 页容量且老代可扩张,mark-compact.cc:5045-5055,5048-5074),新生大对象晋升(:5226-5239)。然后 `CreateAndExecuteEvacuationTasks`(:5008-5041)为每个任务建独立 `Evacuator`(独立疏散分配器),`CreateJob(kUserBlocking)->Join()`。

每个页按状态选模式 `RawEvacuatePage`(mark-compact.cc:4878-4926):`kObjectsNewToOld`(新页整页搬迁或逐对象复制)、`kPageNewToOld`、`kObjectsOldToOld`(逐对象复制;OOM 时记下失败对象,**中止整页疏散**交给主线程善后,`ReportAbortedEvacuationCandidateDueToOOM`,:4914-4919)。并发度的算式是"每 4 页(MB/kPageSize)一个 worker",`UseBackgroundThreadsInCycle()` 为假则单线程(mark-compact.cc:4978-4991)。

### 5.3 Scavenger 与疏散的关系

新空间疏散即第 2 节的 Scavenge;老代疏散复用同样的 markbit 存活信息(`LiveObjectVisitor::VisitMarkedObjects`)。疏散后的槽更新依赖 OLD_TO_OLD remembered set + slot buffer——这正是并发标记期间屏障必须继续记 OLD_TO_OLD 槽的原因(marking-barrier-inl.h:33-36;concurrent-marking.cc:183-187)。

---

## 6. 内存削减:MemoryReducer

GC 之后何时主动发起"减内存 GC"?`MemoryReducer` 是一个小自动机(memory-reducer.h:18-25 注释原文:检测 mutator 从高分配期转入低分配期,回收高分配期产生的垃圾):

- 状态:`kUninit / kDone / kWait / kRun`(memory-reducer.h:89);事件:`kTimer / kMarkCompact / kPossibleGarbage`(:146);
- `kDone` 态收到 kMarkCompact:只有提交内存比上次增长超过 `max(因子*上次, 上次+delta)` 才进入 kWait(memory-reducer.cc:165-181);
- `kWait` 态等定时器:到期且允许增量 GC 则 `CreateRun` 启动一轮标记(:186-210);看门狗 100 秒(memory-reducer.cc:19,:152);短延迟 500ms(:18);
- `ScheduleTimer` 用前台 delayed task 落地(:232-239)。

它与增量标记的关系:MemoryReducer 决定"要不要在空闲时开一轮 GC",增量标记决定"开起来之后怎么摊"。二者合起来构成"空闲收缩堆"的完整闭环。

---

## 7. 设计动机

**为什么并发标记是 GC 的圣杯?** 追踪式 GC 的总工作量为 O(堆内活对象数),不可削减;能优化的只有"这工作量发生在哪段时间"。全停 GC 让工作堆叠成单次停顿;增量把工作摊进 mutator 的每次分配(代价是写屏障税);并发再把大头挪给空闲核。V8 的组合拳是:并发干 80%(后台),增量步进干 15%(主线程切片),atomic pause 干最后的 5%(根重扫、弱处理、疏散)。500ms 标记预算(incremental-marking-schedule.h:51-52)+ 1ms/5ms 步上限(incremental-marking.cc:56-59)+ 栈守卫兜底(:749-755),把"不可预测的秒级停顿"变成"可预算的毫级切片+一个短收尾"。

**三色与写屏障的数学不变式。** 强三色不变式:不存在黑→白边。V8 的标记屏障是 Dijkstra 式增量屏障:写黑对象时把白目标染灰(marking-barrier-inl.h:113-115),不变式立刻恢复。它不追踪删除边,因此弱于 Steele/沙致版,但对 JS 的"死亡对象必然不可达"假设已足够——唯一的例外是 ephemeron(弱表键值对,值是否存活取决于键是否存活),其语义破坏三色假设,必须靠**迭代到不动点**:标记器发现 `(key,value)` 对时若 key 未标则把 pair 丢进 `next_ephemerons` 列表,标完 key 后下一轮重试(concurrent-marking.cc:169-181),主线程在停顿内 `do…while(another_ephemeron_iteration)` 收敛(mark-compact.cc:2185-2206)。

**为什么分代是一切优化的前提?** 因为写屏障的税是按**每次指针写**征收的。若不分代,Scavenge 式的"只扫新生代"无从谈起,所有对象都得参与并发标记的 markbit 体系;分代让 90% 的 GC 只碰 10% 的堆(Scavenge 全停仅数 ms),从而允许 Major 侧慢慢做并发标记——写屏障的两个位(`PointersFromHereAreInteresting`/`IsMarking`)本质是"让绝大多数写(新生代内部写、非标记期写)零成本直通"(heap-write-barrier-inl.h:66-68)。黑分配(老代新对象直接置黑,incremental-marking.cc:372-407)+ on_hold 列表让新对象免于屏障(marking-worklist.h:120-124),也是在分代边界上把税降到最低。

**CAS 转发字的普适性。** 注意 Scavenger 复制(scavenger.cc:1975)与并发标记去重(marking.h:71-74)用的是同一个模式:用一次 CAS 把"可能重复的 N 次工作"折叠成一次。段式 worklist(worklist.h:106-125)则把锁竞争折叠 64 倍。并发 GC 的全部工程,几乎都是"用更粗的同步粒度摊薄同步成本"。

---

## 8. FAQ 素材

1. **V8 的"灰"存在哪里?** 不在 markbit 里。markbit 只有两态(marking.h:71-74);"已标但未遍历"由 worklist 成员关系表达,天然支持多线程并发灰化。
2. **并发标记期间 mutator 分配的新对象会漏标吗?** 老代新对象走黑分配(分配即黑,incremental-marking.cc:372-407);新空间对象不做黑分配,被推进 `on_hold_` 列表延迟标记(marking-worklist.h:120-124;concurrent-marking.cc:440-442)。
3. **为什么新空间不做黑分配?** 注释直说:避免新空间黑分配可以让编译器**删掉新对象的写屏障**(marking-worklist.h:120-124),而新对象写屏障是最热的路径。
4. **增量标记一步到底多长?** 分配触发最多 5ms、任务触发最多 1ms(incremental-marking.cc:56-59);步的字节数按 500ms 总预算折算(incremental-marking-schedule.h:51-52)。
5. **标记完成时任务还没收尾怎么办?** 允许等:上限为标记总时长的 10% 或 50ms 取大者(incremental-marking.cc:608-617);超时用栈守卫强制 GC(:749-755)。
6. **两个 Scavenger 线程会不会复制同一个对象两次?** 不会,map word CAS 决定唯一赢家,输家回滚分配并改用 forwarding address(scavenger.cc:1975-1984)。
7. **对象晋升要活过几次 GC?** 严格说"跨过 age mark 即晋升":age mark 是上轮 scavenge 后的分配顶,本轮开始时已在 mark 之下的对象直接晋升(scavenger.cc:2126-2141;new-spaces.cc:429-431)。通常含义是活过 2 次 minor GC。
8. **疏散会失败吗?** 会。老页疏散 OOM 时中止该页,已搬对象保留 forwarding,残余交主线程善后(mark-compact.cc:4914-4919,6087+);还有"带栈跑代码时干脆放弃老页疏散"的策略(mark-compact.cc:5184,5208-5224)。
9. **内存什么时候自动收缩?** GC 后 MemoryReducer 观察提交内存增长,确认进入低分配期后定时触发新一轮标记-清扫(memory-reducer.cc:157-230)。
10. **为什么停顿内还要串行标记一段?** 弱 map/ephemeron/CppHeap 的收敛需要全局一致的弱语义,注释明确"多线程处理弱对象有竞态,单线程完成传递闭合"(mark-compact.cc:2645-2648)。

## 9. 深挖方向

1. **incremental-marking-schedule.cc 的步长曲线**(:99-130):"恒速假设"调度在 epoch-critical 场景(如 `--predictable`)如何退化,可与 cppgc 的统一调度(incremental-marking.cc:843-850 注释)对照。
2. **sticky mark bits 实验**:`v8_flags.sticky_mark_bits` 分支下组合屏障改写(heap-write-barrier-inl.h:24-44),标志着"消灭分代边界复制"的长期方向。
3. **shared heap 屏障**:`MarkValueShared` 与 client isolate 的 `shared_heap_worklists_`(marking-barrier-inl.h:80-92;marking-barrier.cc:313-318),多 isolate 共享堆下的并发标记协议。
4. **conservative stack scanning 与 pinned/quarantined 页**:Scavenger 的对象钉住 + 疏散后补扫(scavenger.cc:838-870,1710-1716),与 `compact_with_stack` 的疏散弃权(mark-compact.cc:5184)。
5. **typed slots 与 JIT 内存两轮遍历**(scavenger.cc:2465-2510):CFI 约束下 code 页槽更新的最小写权限设计。

---

## 10. 写作要点速查表

| 事实 | 位置 |
|---|---|
| 并发标记前提:原子字段写,否则启动即 CHECK 失败 | concurrent-marking.cc:344-347 |
| 后台 worker 中断粒度:64KB 或 1000 对象 | concurrent-marking.cc:369-370 |
| worker 主循环让出:ShouldYield | concurrent-marking.cc:469-472 |
| 并发度:worker+work,电池模式封顶 1 | concurrent-marking.cc:607-620 |
| 收尾 Join+Flush(live bytes/typed slots 上缴) | concurrent-marking.cc:785-796,842-854 |
| 步上限:任务 1ms / 分配 5ms | incremental-marking.cc:56-59 |
| 启动阈值:老代或全局 8MB | incremental-marking.cc:63-64,135-138 |
| 屏障激活/黑分配启动点 | incremental-marking.cc:289-292,372-407 |
| 完成兜底:栈守卫 RequestGC | incremental-marking.cc:749-755 |
| 标记总预算 500ms;无进展步长 64KB | incremental-marking-schedule.h:51-56 |
| worklist 段 64 元素;steal=整段偷取 | marking-worklist.h:27;worklist.h:402-411,462-471 |
| on_hold 列表:新空间免黑分配免屏障 | marking-worklist.h:120-124 |
| markbit 原子置位(0→1 返回真) | marking.h:71-74 |
| bitmap 位于页 metadata | marking-inl.h:149-154,184-187 |
| 标记屏障染灰:TryMarkAndPush | marking-barrier-inl.h:94-117 |
| 代际屏障双集合:主线程/后台 | heap-write-barrier.cc:404-417 |
| SlotSet:2 级位图,页 64 bucket | slot-set.h:127-132;basic-slot-set.h:277-285 |
| Scavenge job 先于根遍历 post | scavenger.cc:1725-1741 |
| 复制原子性:CAS map word 转发 | scavenger.cc:1975-1992 |
| 晋升判定:age mark = 上轮分配顶 | scavenger.cc:2083-2091;new-spaces.cc:429-431 |
| 疏散候选:碎片率 70% + 配额,按最空优先 | mark-compact.cc:622-630,658-810 |
| 疏散并行:每 worker 一个 Evacuator | mark-compact.cc:4929-5041 |
| atomic pause 顺序:Stop→PublishAll→重扫根→串行收敛→关屏障 | mark-compact.cc:2581-2676 |
| MemoryReducer 自动机四态 | memory-reducer.h:89;memory-reducer.cc:157-230 |

*(正文论断行号均经 grep/Read 核对于 commit c6a1f7c2;与本卷 E 章对照阅读,quickjs 的"全停三遍标记"在本章视角下即是"三色不变式的零并发退化形态"。)*
