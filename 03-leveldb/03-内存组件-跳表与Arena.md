# 第 03 章 · 内存组件:MemTable、Skiplist、Arena 与 Cache

> 基线:LevelDB 1.23,commit `7ee830d0`。行号均以该版本源码为准。
> 版本事实:1.23 中 **`db/skiplist.cc` 不存在**——Skiplist 全部实现(含模板)内联在 `db/skiplist.h` 中。
> 在 LSM 中的位置:一次 Put 的旅程是 `WriteBatch 编码 → WAL 追加 → MemTable → 冻结为 Immutable → 后台刷成 L0 SST`。内存组件就是这条链路的前半段;读路径则是 `mem_ → imm_ → Version(SST + Cache)`。

## 3.0 四个组件的角色绑定

- **MemTable = Arena + Skiplist**:持有 `Arena arena_` 与 `Table table_`(memtable.h:81-82),跳表节点全部落在 Arena 池里,析构一次性释放;
- **MemTable 以引用计数跨线程存活**:`Ref()/Unref()` 管理生命周期,Get 与迭代器可能长时间持有它;
- **Cache 与读路径并联**:TableCache(每库一个)与 block_cache 都是 `NewLRUCache` 产物,缓存 SST 文件句柄与数据块;
- **dbformat 是"键语言"**:内存组件存的是 InternalKey 编码,与 SST、compaction、WAL 共用同一套排序语义——**这是 LevelDB 各层可以无缝归并的根本原因**。

## 3.1 Skiplist:读无锁的完整论证

### 线程契约与两条不变量

`skiplist.h:8-14` 的注释就是合同:"Writes require external synchronization... reads progress without any internal locking"。支撑它的是两条不变量(skiplist.h:16-27):

1. **已分配节点永不删除**——跳表自己从不 delete 节点,读者持有指针永不悬空;
2. **节点除 next 指针外不可变**——key 链入后只读。

读者唯一可能"读到别人正在改"的东西就是 next 指针,而它的发布有内存序保护。

### 两步接链:relaxed + release 的精妙组合

```cpp
for (int i = 0; i < height; i++) {
  x->NoBarrier_SetNext(i, prev[i]->NoBarrier_Next(i));    /* 第 1 步: relaxed */
  prev[i]->SetNext(i, x);                                 /* 第 2 步: release */
}
```
(skiplist.h:360-365)

- 第 1 步设置新节点的"outgoing 边"——此时读者根本拿不到 x,不需要屏障;
- 第 2 步把 x 挂上前驱的"incoming 边",这是**发布点**:release store 保证读者 acquire 到 x 的那一刻,x 的全部字段已就绪;
- `max_height_` 用 relaxed 存是**故意的**(349-356 注释给了完整论证):读者读到旧值只是少爬几层(结果仍正确,第 0 层总能走全序);读到新值时,新层 head 指针要么是 nullptr(视为 +∞,立即下沉)要么是已发布的节点。

```
写线程                                    读线程
x = NewNode(key)                          (看不见 x)
x->NoBarrier_SetNext(0, B)   ┐ 私有准备
prev->SetNext(0, x) [release] ──发布──►   next = prev->Next(0) [acquire]
                                          读到 x ⇒ 保证 x 所有字段可见
```

查找 `FindGreaterOrEqual`(259-279)自最高层下沉,`prev[]` 数组记录每层前驱供 Insert 接链;`KeyIsAfterNode` 把 nullptr 视为 +∞。**跳表没有 prev 指针**——`Iterator::Prev` 走 `FindLessThan` 从 head 重搜(211-219),因为反向遍历会破坏"单向发布"的内存序假设。

### 为什么读无锁、写必须串行

1. 无删除 → 指针不悬空;2. 键不可变 → 读 key 无竞争;3. 单写者 + release/acquire 链 → 读者最多读到"稍旧但一致"的视图(恰好匹配快照读语义);4. 两个写者并发会在同一层丢失更新(prev 是无 CAS 的快照),且随机数生成器 `rnd_` 非线程安全——所以 DBImpl 的 writer 队列把写串行化,跳表自身零防御。

层高概率 1/4(kBranching=4),期望 1.33 个前向指针,上限 12 层;查找代价是**指针追逐**——热路径前几层节点少易驻缓存,第 0 层长链顺序分布在 arena 块中,空间局部性接近数组。这是"跳表 + arena"在缓存表现上优于"红黑树 + 全局 new"的隐性原因。

## 3.2 Arena:66 行的内存池

快路径是一次比较加一次指针加法(arena.h:55-67)。回退路径的阈值取舍(arena.cc:20-36):请求超过 `kBlockSize/4`(1024 字节)时**单独开一块精确大小的块**(避免大对象塞不进剩余空间、频繁浪费尾巴);否则**丢弃当前块剩余空间,新开 4KB 块**。对 MemTable 的小条目为主,平均浪费 <1KB/4KB,换 O(1) 分配。

记账:`memory_usage_` 用 relaxed `fetch_add` 累加(58-64)——它是唯一跨线程读的接口,因为 `MakeRoomForWrite` 在持锁路径上用它对比 `write_buffer_size`(db_impl.cc:1354)。

**生命周期 = 整块回收**:Arena 没有 free 接口,析构时逐块 delete。内存的分配与回收都以 MemTable 为单位——任何"单独释放某条目"的优化都被放弃,但 LSM 里本来就不存在这种需求。

## 3.3 InternalKey 与 LookupKey:全库的"键语言"

InternalKey = `user_key` + 8 字节小端 tag,tag = `(sequence << 8) | type`(dbformat.cc:15-19);序列号占高 56 位(`kMaxSequenceNumber = 2^56-1`),低 8 位是类型(deletion=0/value=1,已固化在磁盘格式)。

比较器定义全库统一全序(dbformat.cc:47-63):**user key 升序,同 key 时序列号降序(更新版本在前)**。这保证 Get/Seek 永远先命中最新版本,compaction 也靠这个全序做归并去重。

编码实例:`Put("foo", v)` 分到 seq=30、type=1 → tag = 0x1F01 → InternalKey = `"foo" 01 1F 00 00 00 00 00 00`(11 字节)。

**LookupKey 把"读快照"翻译成一次 Seek**(dbformat.h:184-216):tag 取 `(snapshot_seq<<8) | kValueTypeForSeek`——类型占低 8 位、同 key 按 tag 降序,探针取"最大类型值"保证**任何 seq ≤ snapshot 的条目都排在探针之后或相等**;即使恰有一条 seq==snapshot 的删除记录(tag 低 8 位为 0),也排在探针后面不被误判。于是 MemTable::Get **只比 user key 不比序列号**(memtable.cc:113-120)——编码技巧直接消灭了一整类显式比较逻辑。200 字节内联空间让绝大多数探针完全栈上化(dbformat.cc:119 "conservative")。

MemTable 条目格式:`key_size(varint) | key bytes | tag | value_size | value bytes`,**整条一次 arena 分配**,`char* buf` 直接作跳表 Key(memtable.cc:90-99)——变长设计省去中间 string。

## 3.4 引用计数如何保护无锁读

`DBImpl::Get` 的使用模式(db_impl.cc:1121-1165)值得逐句读:

```cpp
MutexLock l(&mutex_);
MemTable* mem = mem_;  MemTable* imm = imm_;
mem->Ref(); if (imm) imm->Ref();          /* 持锁摘引用 */
{ mutex_.Unlock();
  LookupKey lkey(key, snapshot);
  if (mem->Get(lkey, ...)) { ... }
  else if (imm && imm->Get(lkey, ...)) { ... }
  else s = current->Get(options, lkey, ...);   /* Version 查找 */
  mutex_.Lock(); }
mem->Unref(); ...
```

摘指针、加引用在锁内完成后,真正的 Get(含跳表无锁遍历)在**解锁状态**下进行。换表、flush、迭代器三方互不阻塞——**锁只保护指针字段的更新,不保护数据结构的遍历**,这是"读无锁跳表"能够落地的唯一上层前提。

`MemTable::Get` 的返回值语义:返回 true 表示"答案在本表"(删除标记也是有效答案,`*s = NotFound; return true`),上层据此短路磁盘查找(memtable.cc:123-131)。

## 3.5 Cache:16 分片 LRU 与引用计数

接口契约(cache.h:5-16):自带同步、可并发、可能自动驱逐;`Handle` 是空结构体(不透明),句柄是"弱持有缓存 + 强持有值"的混合语义(Erase 后 entry 保留到所有句柄释放)。

- **16 分片**(cache.cc:336-349):路由键取哈希的**最高 4 位**(与低位模式解耦);分片把锁竞争摊薄一个数量级,每个分片内部仍是一把大锁——务实折中,RocksDB 后来才演进到细粒度锁;
- **refs 语义**:包含缓存自身的引用——`refs==1 && in_cache` 表示"只有缓存持有,可驱逐";`refs>=2` 表示有客户端句柄(50-53);
- **双链**:in-use 链(refs>=2,无序)与 LRU 链(refs==1,按访问时间)——条目在两链间迁移完全由 Ref/Unref 驱动(218-238);
- **表与链正交**:`next_hash` 串哈希桶,`next/prev` 串双链;手写 HandleTable 的注释理由:比部分编译器内置哈希快约 5%(random 读),负载因子超 1 就倍增;
- **驱逐只从 LRU 链取**——正在被使用的句柄不受容量压力影响;`capacity_==0` 时完全不入缓存但仍交还句柄(290-293),支持"关掉缓存"配置。

## 3.6 设计动机五条

1. **跳表而非红黑树**:需求组合是"有序范围 + 并发读 + 无删除 + arena 分配";跳表 380 行、无旋转、FindGreaterOrEqual 天然给出 prev[],"只增不删"把并发问题简化到极致;
2. **Arena 而非 malloc**:节点 30-60 字节,malloc 元数据开销不可接受;N 次分配压成 K 次 4KB 块;MemoryUsage 还给限流提供精确水位;
3. **tag 编进键尾**:多版本成为普通有序条目,各层共用一套比较器;代价是 tag 8 字节放大所有存储;
4. **16 分片**:嵌入式定位下写路径有大锁串行,16 分片已够;RocksDB 的演进证明这是取舍点而非终点;
5. **LookupKey 的 space_[200]**:为热路径买断分配器——与 Arena 思路同源:分配策略向生命周期形状看齐。

## 3.7 FAQ

**Q1:读者会不会看到只挂了一半层的新节点?**
会,但无害:发布从第 0 层到高层逐层 release,读者沿任意层 acquire 到节点时该层 next 已就绪;最坏是查找多走几步第 0 层。

**Q2:relaxed 的 max_height_ 会撕裂吗?**
不会。atomic 只削弱顺序不削弱原子性;读到新值时新层 head 要么 nullptr 要么已发布——注释原文就是这个论证。

**Q3:两个写线程并发 Insert 一定坏吗?**
是。prev[] 是无 CAS 快照,会丢失更新;LevelDB 靠 writer 队列保证单写者,跳表零防御是刻意的。

**Q4:MemTable::Get 返回 true 还 NotFound 是什么意思?**
返回值="答案在不在本表",Status="答案是什么"。删除标记也是有效答案,据此停止查磁盘。

**Q5:缓存驱逐会把正在使用的块挤掉吗?**
不会,驱逐只从 LRU 链(refs==1)取;有客户端句柄的条目在 in-use 链。

**Q6:Release 为什么不用重算哈希?**
LRUHandle 里存了 hash,直接找回分片(cache.cc:368-371)。

## 3.8 小结与深挖方向

本章结论:**内存组件的每一处设计都指向同一原则——把并发正确性从"数据结构内部的复杂协议"转移到"上层串行化 + 引用计数"**;内存序只出现在一条边上(发布点),生命周期只有一个粒度(MemTable)。深挖:

1. Insert 无屏障变体的收益量化(x86 vs ARM 的 ldar 成本);
2. Arena 对齐缺口的形式化验证(Aligned 与 Fallback 的衔接);
3. TableCache charge=1 与 block cache 字节量纲混用,L0 爆炸时的驱逐抖动;
4. 若引入删除,现有内存序论证需全部重推——"并发模型为什么便宜"的反向练习;
5. 超大 batch 越过限流水位的内存上界(write_buffer_size + max batch)。

> 下一章离开内存:磁盘上的每一条 SSTable 长什么样——Footer、重启点二分与 index key 的最短分隔符技巧。
