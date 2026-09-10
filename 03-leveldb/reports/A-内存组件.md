# A 篇 · 内存组件:MemTable、Skiplist、Arena、Cache

> 调研基线:LevelDB 1.23,commit `7ee830d0`。仓库路径 `repos/leveldb`。
> 注意一个事实:1.23 版本中 **`db/skiplist.cc` 并不存在**,Skiplist 的全部实现(含模板)都内联在 `db/skiplist.h` 中,本文以 `skiplist.h` 为准。

---

## ① 全景:内存组件在 LSM 中的位置

LevelDB 是典型的 LSM-Tree 写优化存储引擎。一次 `Put` 的完整旅程是:`WriteBatch 编码 → WAL 追加 → 写入 MemTable(Skiplist)→ MemTable 写满后冻结为 Immutable MemTable → 后台 compaction 刷成 Level-0 SST`。内存组件正是这条链路的"前半段":

```
写路径:  WAL(持久化) ──► MemTable ──► Immutable MemTable ──► L0 SST
                │              │
              Arena          Skiplist(节点全部由 Arena 分配)

读路径:  DBImpl::Get ──► mem_->Get ──► imm_->Get ──► Version::Get(SST + Block Cache)
                                                    │
                                              TableCache / BlockCache(LRU Cache)
```

几个关键的角色绑定关系:

- **MemTable = Arena + Skiplist**。`MemTable` 持有 `Arena arena_` 与 `Table table_` 两个成员(`db/memtable.h:81-82`),构造顺序上 `table_(comparator_, &arena_)` 先初始化 `arena_` 再把它的指针交给跳表(`db/memtable.cc:21-22`),保证跳表节点全部落在 Arena 的内存池里,MemTable 析构时一次性释放。
- **MemTable 以引用计数跨线程存活**。`Get` 与迭代器可能长时间持有 MemTable,而后台 compaction 会切换 `mem_`/`imm_`,所以用 `Ref()/Unref()` 管理生命周期(见 ④ 的交叉引用)。
- **Cache 与读路径并联**。`TableCache`(每个 DB 一个)和 `block_cache`(按 `options.block_cache` 配置)都是 `NewLRUCache` 的产物(`db/table_cache.cc:37`),缓存打开的 SST 文件句柄与数据块,避免重复 open/decode。
- **dbformat 是"键语言"**:MemTable 里存的不是裸 user key,而是 `user_key + (seq<<8|type)` 的 InternalKey 编码,这套编码同时贯穿 SST 块、compaction、WAL——内存组件的排序语义与磁盘组件完全一致,这是 LevelDB 各层可以无缝归并的根本原因。

---

## ② Skiplist 无锁读逐段解读

### 2.1 线程契约:读不加锁、写外部串行

`skiplist.h` 开头的注释就是这个数据结构的"合同"(`db/skiplist.h:8-14`):

> Writes require external synchronization, most likely a mutex. Reads require a guarantee that the SkipList will not be destroyed while the read is in progress. Apart from that, reads progress without any internal locking or synchronization.

支撑这份合同的是两条不变量(`db/skiplist.h:16-27`):

1. **已分配节点永不删除**——Arena 管理内存,跳表自己从不 `delete` 节点(`skiplist.h:18-20`)。读线程拿到节点指针后,节点内存永远有效,不存在 use-after-free。
2. **节点除 next/prev 指针外不可变**——`key` 在节点链入链表后只读(`skiplist.h:22-26`,成员声明 `Key const key` 在 `skiplist.h:147`)。读线程读 `key` 不需要任何同步。

也就是说:读线程唯一可能"读到别人正在改"的东西就是 next 指针,而 next 指针的发布是有内存序保护的。

### 2.2 Node 与两级指针访问接口

```cpp
// db/skiplist.h:151-172(节选)
Node* Next(int n) {
  // Use an 'acquire load' so that we observe a fully initialized
  // version of the returned Node.
  return next_[n].load(std::memory_order_acquire);
}
void SetNext(int n, Node* x) {
  // Use a 'release store' so that anybody who reads through this
  // pointer observes a fully initialized version of the inserted node.
  next_[n].store(x, std::memory_order_release);
}
// No-barrier variants ...  relaxed load/store
Node* NoBarrier_Next(int n);
void NoBarrier_SetNext(int n, Node* x);
```

`next_` 是 `std::atomic<Node*> next_[1]` 的变长数组(`skiplist.h:176`),实际长度由 `NewNode` 按层高多分配 `height-1` 个指针(`skiplist.h:179-185`),用 placement new 构造。**release/acquire 成对出现在"写者发布新节点 / 读者遍历"这条最关键的同步边上**;NoBarrier 版本则服务于 Insert 内部的私有中间状态(见 2.5)。

### 2.3 查找:FindGreaterOrEqual 与 prev 数组

```cpp
// db/skiplist.h:259-279(节选)
Node* x = head_;
int level = GetMaxHeight() - 1;
while (true) {
  Node* next = x->Next(level);          // acquire load
  if (KeyIsAfterNode(key, next)) {
    x = next;                           // 在本层继续右移
  } else {
    if (prev != nullptr) prev[level] = x;  // 记录每层的前驱
    if (level == 0) return next;        // 第 0 层返回 >= key 的第一个节点
    level--;                            // 下沉一层
  }
}
```

三个细节:

- `KeyIsAfterNode` 把 `nullptr` 视为 +∞(`skiplist.h:252-256`),所以走到链尾(next 为空)自然下沉。
- `GetMaxHeight()` 是 relaxed load(`skiplist.h:102-104`),`max_height_` 被注释明确说明"仅由 Insert() 修改,读者竞态读它,陈旧值无害"(`skiplist.h:134-136`)。读者看到偏小的 `max_height_` 只是少爬几层,结果仍正确(从第 0 层总能走全序);看到偏大的值也安全(见 2.5)。
- `prev` 数组只在 `Insert` 时传入(容量 `kMaxHeight=12`,`skiplist.h:100,338`),为"逐层打洞接链"做准备;读者调用时传 `nullptr`(如 `Iterator::Seek`,`skiplist.h:222-224`)。

同族函数 `FindLessThan`(`skiplist.h:281-300`)服务于 `Iterator::Prev`——跳表**没有 prev 指针**,倒退是重新从 head 查找"最后一个 < key 的节点"(`skiplist.h:211-219`);`FindLast`(`skiplist.h:302-320`)服务于 `SeekToLast`。

### 2.4 随机层高

```cpp
// db/skiplist.h:239-250
static const unsigned int kBranching = 4;
int height = 1;
while (height < kMaxHeight && rnd_.OneIn(kBranching)) height++;
```

每多一层概率 1/4(`Random::OneIn`,`util/random.h:53`),期望每个节点 1.33 个前向指针;上限 12 层足以支撑 4^11 ≈ 419 万个节点的查找路径收敛。注意 `rnd_` 是跳表成员且"Read/written only by Insert()"(`skiplist.h:138-139`)——它是**非线程安全的** LCG,这是写必须外部串行的现实原因之一。

顺带量化一下查找成本:层高分布是几何分布(每次 +1 概率 1/4),平均每个节点 1 + 1/3 ≈ 1.33 个前向指针,期望查找路径长度 O(log₄ n)。更实际的代价模型是**指针追逐**:每一步都要解引用一个跨 cache line 的指针,跳表的 12 层结构让热路径(前几层)节点数少、易驻留缓存,第 0 层长链则顺序分布在 arena 块中,空间局部性接近数组——这是"跳表 + arena 池化"组合在缓存表现上优于"红黑树 + 全局 new"的隐性原因。

### 2.5 插入:两步接链与内存序的正确性

```cpp
// db/skiplist.h:334-366(节选)
Node* prev[kMaxHeight];
Node* x = FindGreaterOrEqual(key, prev);
int height = RandomHeight();
if (height > GetMaxHeight()) {
  for (int i = GetMaxHeight(); i < height; i++) prev[i] = head_;
  max_height_.store(height, std::memory_order_relaxed);   // 故意 relaxed
}
x = NewNode(key, height);
for (int i = 0; i < height; i++) {
  x->NoBarrier_SetNext(i, prev[i]->NoBarrier_Next(i));    // 第 1 步
  prev[i]->SetNext(i, x);                                 // 第 2 步(release)
}
```

**第 1 步用 relaxed、第 2 步才用 release,这是全文最精妙的一处。** 逐条解释:

- 新节点 `x` 的 next 指针此时只被写者自己可见,读者根本拿不到 `x`,所以第 1 步不需要屏障。
- 第 2 步把 `x` 挂进 `prev[i]` 的 next,这是**发布点**:release store 保证在此之前对 `x` 的一切初始化(构造 + 第 1 步的全部 relaxed store)对读者可见。读者从 `prev[i]->Next(i)` 的 acquire load 读到 `x` 的那一刻,`x->next_[0..height-1]` 必然已就绪。
- `max_height_` 用 relaxed 存是**故意的**(`skiplist.h:349-356` 注释):并发读者要么看到旧值(此时新层的 head 指针还是 `nullptr`,而 `nullptr` 排在所有键之后,读者在该层立即下沉,不会出错);要么看到新值(此时走到的 head 新层指针要么是 `nullptr` 要么是已 release 发布的节点)。relaxed 的 `max_height_` 与 release 的节点指针之间存在数据依赖路径——读者必须先通过某层的 acquire load 才能触达新节点,层次提升本身不引入撕裂。

用一幅图总结"发布-观察"的时序(单层视角):

```
写线程                                    读线程
-------                                   -------
x = NewNode(key)                          (看不见 x)
x->NoBarrier_SetNext(0, B)   ┐ 私有准备
prev->SetNext(0, x) [release] ──────发布──► next = prev->Next(0) [acquire]
                                           读到 x ⇒ 保证 x 的所有字段可见
                                           compare(x->key, target) 安全
```

### 2.6 为什么读不需要锁、写必须串行

把 2.1-2.5 拼起来,答案就完整了:

1. **没有删除** → 读者持有的指针不会悬空(唯一要求是跳表活得比读操作久,由上层 MemTable 引用计数保证,见 ④)。
2. **键不可变** → 读者与写者对同一节点的 `key` 读不存在竞争。
3. **单写者 + release/acquire 链** → 任意时刻链上每条边要么是完整的旧边,要么是完整的新边;读者可能读到"稍旧"的视图(新节点还没被看到),但绝不会读到半成品。这也意味着跳表的读是**线性一致于某一次 Insert 完成时刻**的,弱化一点说:搜索结果要么包含新节点要么不包含,二者都合法。
4. **写的中间态会破坏不变量** → `Insert` 的 `prev` 数组只反映计算时刻的快照,两个写者并发会在同一层产生丢失更新;`rnd_` 也非线程安全。所以 LevelDB 在 `DBImpl::Write` 层用一个 `writer` 队列把写线程串行化(每个 MemTable 逻辑上单写者),跳表内部零锁。

还要指出这套模型的**边界条件**:它默认"读只遍历 next、写只追加",所以不适用任何"边读边写"的场景;`Iterator::Prev` 走 `FindLessThan` 重搜(`skiplist.h:211-219`)而不是维护反向指针,正是因为反向遍历会破坏"单向发布"的内存序假设——每加一条可变的边,就要多论证一条 happens-before 链。LevelDB 选择把设计约束压到最少可证明的状态,而不是把数据结构做得更通用。

---

## ③ Arena 分配策略

Arena 是极简的 bump-pointer 内存池,全部实现不足 70 行(`util/arena.cc` 一共 66 行)。

### 3.1 快路径与回退

```cpp
// util/arena.h:55-67
inline char* Arena::Allocate(size_t bytes) {
  assert(bytes > 0);
  if (bytes <= alloc_bytes_remaining_) {
    char* result = alloc_ptr_;
    alloc_ptr_ += bytes;                    // 指针直接前移,零元数据开销
    alloc_bytes_remaining_ -= bytes;
    return result;
  }
  return AllocateFallback(bytes);
}
```

快路径就是一次比较加一次指针加法。回退路径 `AllocateFallback`(`util/arena.cc:20-36`)有个明确的阈值取舍:**请求超过 `kBlockSize/4`(即 1024 字节)时单独开一块精确大小的块**,避免"大对象塞不进剩余空间→频繁浪费尾巴";否则**丢弃当前块剩余空间,新开 4KB 块**(`kBlockSize=4096`,`util/arena.cc:9`)。对 MemTable 来说小条目占多数,平均浪费 < 1KB/4KB,换来 O(1) 分配。

### 3.2 对齐与记账

`AllocateAligned`(`util/arena.cc:38-56`)按 `max(sizeof(void*), 8)` 对齐(`util/arena.cc:39`),计算当前 `alloc_ptr_` 的模余补齐 `slop` 后再走同样的快/慢路径;注释强调"AllocateFallback 返回的内存总是对齐的"(`util/arena.cc:51`)——因为底层是 `new char[]`。这里有个不易察觉的陷阱:`AllocateAligned` 遇到大块回退后,`alloc_ptr_` 指向新块**内部偏移 0** 的位置,天然对齐,不需要额外处理。

记账方面,`AllocateNewBlock` 用 relaxed 的 `fetch_add` 把 `block_bytes + sizeof(char*)`(块本身 + `blocks_` vector 里一个指针槽)累加进 `memory_usage_`(`util/arena.cc:58-64`)。`MemoryUsage()` 是唯一用原子量的接口(`util/arena.h:33-35`),因为它会被写线程之外的路径"竞态地"调用——`DBImpl::MakeRoomForWrite` 在持锁路径上用它对比 `write_buffer_size`(`db/db_impl.cc:1354`),恢复路径在 `db/db_impl.cc:455` 同样如此。头文件里甚至留了一条 TODO 质疑其他成员无锁访问是否安全(`util/arena.h:50-51`)——事实上 Arena 的 `alloc_ptr_/alloc_bytes_remaining_/blocks_` 只被持 DB 锁的写路径触碰,唯一跨线程的读就是 `MemoryUsage()`,这个设计是自洽的。

### 3.3 生命周期:整块回收,不分片释放

Arena 没有任何 free 接口;析构时遍历 `blocks_` 逐块 `delete[]`(`util/arena.cc:14-18`)。这是与 MemTable 生命周期的精确耦合:一个 MemTable 冻结 → 落盘为 L0 SST → 所有引用者 `Unref` 之后,整片内存(可能几十 MB,即 `write_buffer_size`)一次性归还。**粒度对齐**:内存的分配与回收都以 MemTable 为单位,跳表节点、varint 编码的键值条目全部随之湮灭,不存在内部碎片回收问题。

---

## ④ InternalKey 与 LookupKey:全库的"键语言"

### 4.1 InternalKey 的编码与比较

InternalKey = `user_key` 原样拼接 + 8 字节小端 tag,tag = `(sequence << 8) | type`(`db/dbformat.cc:15-19` 的 `PackSequenceAndType`)。序列号占高 56 位,`kMaxSequenceNumber = 2^56 - 1`(`db/dbformat.h:65-67`);低 8 位是类型 `kTypeDeletion=0x0 / kTypeValue=0x1`(`db/dbformat.h:54`,注释警告这些值已固化在磁盘格式中)。

比较器 `InternalKeyComparator::Compare` 定义了全库统一的全序(`db/dbformat.cc:47-63`):

```cpp
int r = user_comparator_->Compare(ExtractUserKey(akey), ExtractUserKey(bkey));
if (r == 0) {
  const uint64_t anum = DecodeFixed64(akey.data() + akey.size() - 8);
  const uint64_t bnum = DecodeFixed64(bkey.data() + bkey.size() - 8);
  if (anum > bnum) r = -1;      // 同 user key:tag 大者(更新的版本)排在前
  else if (anum < bnum) r = +1;
}
```

即:**user key 升序,同 key 时序列号降序(更新版本在前)**。这保证 Get/Seek 永远先命中最新版本,旧版本自然被"挡"在后面,compaction 也靠这个全序做归并去重。

### 4.2 编码实例

以 `Put("foo", v)`、分配到 `seq=30`、`type=kTypeValue(1)` 为例:

- tag = `(30 << 8) | 1` = `0x1F01`,8 字节小端编码(EncodeFixed64/DecodeFixed64 均为小端,`util/coding.h:64,90-97`)为:`01 1F 00 00 00 00 00 00`
- InternalKey = `66 6F 6F 01 1F 00 00 00 00 00 00 00`(`"foo"` + tag),共 11 字节 = 3 + 8(`InternalKeyEncodingLength`,`db/dbformat.h:81-83`)。
- `ParseInternalKey` 反向解析:取末 8 位字节,`sequence = num >> 8`,`type = num & 0xff`(`db/dbformat.h:171-181`)。

### 4.3 MemTable 条目:一次分配,变长存储

`MemTable::Add` 把键值打成一个连续 buffer 存进跳表(`db/memtable.cc:76-100`),格式注释见 `db/memtable.cc:78-83`:

```
key_size(varint32) | key bytes | tag(uint64) | value_size(varint32) | value bytes
```

关键实现是**整条一次 `arena_.Allocate(encoded_len)`**(`db/memtable.cc:90`),然后把 `char* buf` 直接作为跳表 Key 插入(`db/memtable.cc:99`)。`KeyComparator::operator()` 收到两个 `const char*`,各自 `GetVarint32Ptr` 解出长度前缀再比较(`db/memtable.cc:28-34`)——跳表模板的 `Key` 类型只是 `const char*`,真正的键语义完全委托给比较器。变长设计省去中间 string,arena 保证节点与键内存同生命周期。

### 4.4 LookupKey:把"读快照"翻译成一次 Seek

`LookupKey` 是 `DBImpl::Get` 的探针(`db/dbformat.h:184-216`),内存布局注释在 `db/dbformat.h:205-211`:

```
klength(varint32) | userkey | tag((snapshot_seq<<8)|kValueTypeForSeek)
    ↑start_          ↑kstart_                              ↑end_
```

构造代码很短(`db/dbformat.cc:117-134`):`needed = usize + 13` 的保守估计,≤200 字节就落在内联的 `space_[200]` 里避免堆分配(`db/dbformat.h:215`)。tag 特意取 **`kValueTypeForSeek = kTypeValue`**(`db/dbformat.h:55-61`):因为类型占 tag 低 8 位、同 user key 内按 tag 降序,构造探针时使用"最大类型值",可以保证**任何 seq ≤ snapshot 的真实条目都排在探针之后或相等**——即使恰好有一条 `seq==snapshot` 的删除记录,它的 tag 是 `seq<<8|0`,比探针 `seq<<8|1` 小,排在探针后面,不会被误判为可见版本。

`Get` 的完整语义由此闭环(`db/memtable.cc:102-136`):

1. `memkey = key.memtable_key()`(带 klength 前缀的完整编码,`db/dbformat.h:196`),对跳表做一次 `Seek`;
2. 命中后**只比对 user key,不比对序列号**(`db/memtable.cc:113-115` 注释):因为探针的 tag 已经把"所有 seq > snapshot 的条目"跳过去了,第一个同 user key 的条目必然是可见的最新版本;
3. 按 `tag & 0xff` 分派:`kTypeValue` → 拷出 value 返回 true;`kTypeDeletion` → `*s = NotFound` 且**返回 true**(`db/memtable.cc:123-131`)。返回 true 表示"答案在 MemTable 里,不必再查磁盘",这层布尔语义让上层 `DBImpl::Get` 能正确短路(`db/db_impl.cc:1148-1155`)。

### 4.5 引用计数如何保护无锁读

跳表要求"读期间列表不销毁",这由 MemTable 引用计数兑现。初值 0、调用方必须至少 `Ref` 一次(`db/memtable.h:22-24`);`Unref` 减到 0 即 `delete this`(`db/memtable.h:33-39`);析构函数私有且 `assert(refs_ == 0)`(`db/memtable.cc:24`),强制一切删除走 `Unref`。

上层的使用模式(`db/db_impl.cc:1121-1165`)值得逐句读:

```cpp
MutexLock l(&mutex_);
MemTable* mem = mem_;  MemTable* imm = imm_;
mem->Ref(); if (imm != nullptr) imm->Ref();      // 持锁摘引用
{ mutex_.Unlock();
  LookupKey lkey(key, snapshot);
  if (mem->Get(lkey, value, &s)) { ... }
  else if (imm != nullptr && imm->Get(lkey, value, &s)) { ... }
  else s = current->Get(options, lkey, value, &stats);
  mutex_.Lock(); }
mem->Unref(); ...
```

摘指针、加引用在锁内完成后,真正的 `Get`(含跳表无锁遍历)在**解锁状态**下进行。写路径在 `MakeRoomForWrite` 中换表时(`imm_ = mem_; mem_ = new MemTable(...); mem_->Ref();`,`db/db_impl.cc` 1396-1400 附近),旧表的存活完全由这些引用兜底——后台 flush、并发读、迭代器(`NewInternalIterator` 同样对 `mem_/imm_` Ref,`db/db_impl.cc:1091-1096`)互不阻塞。这就是"Skiplist 读无锁"的工程闭环:**锁只保护指针字段的更新,不保护数据结构的遍历**。

---

## ⑤ Cache:ShardedLRU、引用计数与双链

### 5.1 接口设计意图(include/leveldb/cache.h)

`cache.h` 的类注释定义了契约(`include/leveldb/cache.h:5-16`):Cache 是"内部自带同步、可并发访问、可能自动驱逐"的 key→value 映射;value 通过 `charge` 计入容量(如变长字符串可用其长度);内置 LRU 实现,但**接口刻意抽象**,客户端可以替换为带扫描抵抗、自定义驱逐等策略的实现。几个接口决策很有代表性:

- `Handle` 是空结构体(`cache.h:46`)——句柄对客户端完全不透明,强制走 `Value(handle)` 取值(`cache.h:76`),实现可以随意改内部布局。
- `Insert` 返回的句柄要求调用方 `Release`(`cache.h:51-58`),`Erase` 的注释明确"entry 会保留到所有既有句柄释放为止"(`cache.h:78-81`)——即句柄是弱持有缓存 + 强持有值的混合语义。
- `NewId()`(`cache.h:83-87`)服务多客户端共享同一 Cache 实例的场景:各自拿到 id 前缀拼进 key,避免互相驱逐。`TableCache` 就是这样隔离不同 file number 的。
- `Prune()` 默认空实现并预告未来可能改为纯虚(`cache.h:89-94`),是接口演进中向后兼容的典型处理。

### 5.2 16 分片:锁竞争与哈希高位

```cpp
// util/cache.cc:336-349(节选)
static const int kNumShardBits = 4;
static const int kNumShards = 1 << kNumShardBits;   // 16
static uint32_t Shard(uint32_t hash) { return hash >> (32 - kNumShardBits); }
```

`ShardedLRUCache` 持有定长数组 `LRUCache shard_[16]`(`util/cache.cc:341`),容量均分向上取整(`util/cache.cc:352-357`)。路由键是 `Hash(data, size, 0)` 的**最高 4 位**(`util/cache.cc:345-349`)——取高位是因为低位已被哈希函数内部用于桶内散列的细节,高位分布同样均匀且与键内容的低位模式(如 varint 长度前缀)解耦。Lookup/Insert/Erase 各算一次哈希,`Release` 则直接用句柄里缓存的 `h->hash` 找回分片(`util/cache.cc:368-371`),不再重算。

分片把 16 个独立 mutex 摊开锁竞争;每个分片内部仍然是一把大锁(`port::Mutex mutex_`)保护全部状态(`util/cache.cc:182-195`)。这是一个务实的折中:LevelDB 没有做细粒度无锁 LRU(那需要 Hazard Pointer 或分段锁链),16 分片在多核读放大下已够用。

### 5.3 LRUHandle、HandleTable 与双链

`LRUHandle` 是变长堆对象,尾部 `char key_data[1]` 柔性存储键(`util/cache.cc:43-63`),`Insert` 时按 `sizeof(LRUHandle)-1+key.size()` malloc(`util/cache.cc:273-274`),键值与元数据一次分配,无二次寻址。`refs` 语义:**包含缓存自身的引用(如果 `in_cache==true`)**——`refs==1 && in_cache` 表示"只有缓存持有,可驱逐";`refs>=2` 表示有客户端句柄(`util/cache.cc:50-53` 及 `186-193` 的注释)。

两个链表(`util/cache.cc:29-39` 注释):

- **in-use 链**:`refs>=2` 且在缓存中的条目,无特定顺序;
- **LRU 链**:`refs==1` 的条目,按访问时间排序,`lru_.prev` 最新、`lru_.next` 最旧(`util/cache.cc:186-189`)。

条目在两条链之间迁移完全由 `Ref/Unref` 驱动(`util/cache.cc:218-238`):

```cpp
void LRUCache::Ref(LRUHandle* e) {
  if (e->refs == 1 && e->in_cache) {       // 从 LRU 链"晋升"到 in-use
    LRU_Remove(e);  LRU_Append(&in_use_, e);
  }
  e->refs++;
}
void LRUCache::Unref(LRUHandle* e) {
  e->refs--;
  if (e->refs == 0) { (*e->deleter)(e->key(), e->value); free(e); }
  else if (e->in_cache && e->refs == 1) {   // 降级回 LRU 链
    LRU_Remove(e);  LRU_Append(&lru_, e);
  }
}
```

`HandleTable` 是手写的拉链哈希表(`util/cache.cc:70-148`),注释给出理由:自带实现避免移植 hack、比部分编译器的内置哈希表更快(random 读快约 5%)。`Insert` 返回被覆盖的旧条目,负载因子超过 1(平均链长 ≤1)就倍增 `Resize`(`util/cache.cc:84-90`)。**表与链是正交的两套指针**:`next_hash` 串起哈希桶,`next/prev` 串起 LRU/in-use 双链;同一对象同时挂在两套结构上,驱逐时 `FinishErase` 先从表中摘除、再摘链、减 usage、`Unref`(`util/cache.cc:308-317`)。

### 5.4 Insert 的一条冷路径

`LRUCache::Insert` 有一个容易被忽略的分支:`capacity_==0` 时**完全不入缓存**,但仍然把句柄交还给调用方(`util/cache.cc:290-293`)——这支持"关掉缓存"的配置语义(如 `block_cache` 置空容量),句柄 `refs==1` 由调用方 `Release` 归零后走 deleter 释放。驱逐循环则只在 `usage_ > capacity_` 时从 `lru_.next` 摘最旧条目(`util/cache.cc:294-301`),且**只驱逐无客户端引用的条目**,正在被使用的句柄不受容量压力影响——这正是引用计数与 LRU 协同的核心。

---

## ⑥ 设计动机与取舍

**为什么跳表而不是红黑树/HashMap?** 需求组合是:有序范围扫描(迭代器 + `Seek`)、并发读、无删除、arena 分配。跳表实现约 380 行模板代码,无旋转、无再平衡;`FindGreaterOrEqual` 天然给出 `prev[]` 数组,插入即接链;并发模型只需 release/acquire。红黑树要处理删平衡,而 LevelDB 的键永远不删(靠版本叠加 + compaction 物理删除),跳表的"只增不删"反而把并发问题简化到极致。

**为什么读无锁是安全的?** 三个不变量(节点不删、载荷不可变、发布有序)+ 上层引用计数。代价是:旧版本条目在 compaction 前一直占内存;读可能看到"过时但一致"的视图,这恰好匹配快照读语义。

**为什么 Arena 而不是直接 malloc?** 每个跳表节点 30-60 字节,直接 malloc 的元数据开销(16B+/次)与碎片不可接受;arena 把 N 次分配压成 K 次 4KB 块分配,`MemoryUsage()` 还给写入限流提供了精确的内存水位。代价是生命周期绑定 MemTable——任何想"单独释放某条目"的优化都被放弃,但这在 LSM 里本来就不存在。

**为什么 InternalKey 把 tag 编进键尾?** 它让"同一 user key 的多版本"成为普通有序条目,MemTable/SST/compaction 共用一套比较器,归并排序天然按 (user_key, seq) 聚簇。代价是每次比较都要解 8 字节 tag、`LookupKey` 需要精心挑选 `kValueTypeForSeek`;此外 tag 占 8 字节放大了所有存储。

**为什么 Cache 用 16 分片 + 全局锁,而不是更细的并发?** LevelDB 的定位是单机嵌入式引擎,写路径有 DB 大锁串行,读路径的缓存命中通常微秒级;16 分片已把锁竞争摊薄一个数量级。RocksDB 后来演进到细粒度锁/无锁哈希,证明这是明确的取舍点而非终点。

**LookupKey 的 space_[200]**:把最常见键长(≤185 字节 user key)的探针完全栈上化,`DBImpl::Get` 每次调用省一次堆分配——典型的"为热路径买断分配器"手法,与 Arena 思路同源:分配策略向生命周期形状看齐。

---

## ⑦ FAQ

**Q1:跳表读者会不会看到只挂了一半层的新节点?**
会看到"层不全"的节点,但无害。发布顺序是从第 0 层到第 height-1 层逐层 release(`skiplist.h:360-365`),读者若先在第 0 层看到新节点,向上层找 prev 时走的是旧链;而"上层先于下层可见"不可能发生——更准确地说,读者沿任意层 acqire 到节点时,该节点该层的 next 已就绪,且查找算法只依赖"到达节点的那一层"的边。最多结果是查找多走几步第 0 层,不影响正确性。

**Q2:读 MaxHeight 时 relaxed 会不会读到"写入中"的撕裂值?**
不会。`max_height_` 是 `std::atomic<int>`,relaxed 只削弱顺序不削弱原子性,读到的要么是旧值要么是新值(`skiplist.h:134-136,356`)。读到新值时,对应新层 head 指针要么还是 `nullptr`(视为 +∞,下沉),要么已 release 发布——注释 `skiplist.h:349-356` 原文就是这个论证。

**Q3:Insert 里为什么先 NoBarrier_SetNext 再 SetNext?顺序反过来行吗?**
反了就错。第 1 步是把新节点的" outgoing 边"指到旧后继;第 2 步才把新节点挂上前驱的" incoming 边"(发布点)。若先发布再补 next,读者可能 acquire 到新节点却读到未初始化的 next,遍历直接炸掉。

**Q4:两个写线程并发 Insert 一定坏吗?**
是。`prev[]` 是无 CAS 的快照,并发插入会丢失更新;`rnd_` 也非线程安全(`skiplist.h:138-139`)。LevelDB 靠 `DBImpl` 的 writer 队列保证同一 MemTable 逻辑单写者,跳表自身零防御是刻意的。

**Q5:MemTable::Get 为什么返回 true 还要区分 NotFound?**
返回值含义是"答案在不在本表",`Status` 才是"答案是什么"。删除标记(`kTypeDeletion`)也是有效答案——上层据此停止向 imm/SST 继续查找(`db/memtable.cc:129-131` 的 `*s = NotFound(...); return true;`)。

**Q6:MemTable 里的 key_size 前缀存的是 internal key 大小还是 user key 大小?**
是 internal key 的大小(`key_size + 8`,`db/memtable.cc:86`),即含 8 字节 tag;`Get` 里比较 user key 时用 `key_length - 8` 截断(`db/memtable.cc:118-120`)。

**Q7:为什么 Cache 的 Release 不需要重新算哈希?**
`LRUHandle` 里存了 `hash`(`util/cache.cc:53`),`Release` 直接 `shard_[Shard(h->hash)]`(`util/cache.cc:368-371`),省一次哈希也保证句柄必然回到正确的分片。

**Q8:缓存驱逐会把正在使用的块挤掉吗?**
不会。驱逐只从 `lru_` 链取,该链条目 `refs==1`(仅缓存持有,`util/cache.cc:294-296` 的 assert);有客户端句柄的条目在 in-use 链,等最后一个句柄 `Release` 后才降级回 LRU 链参与驱逐。

**Q9:Arena 的 MemoryUsage 是精确值吗?**
是"块级精确、条目级近似":它统计所有 `new[]` 块加 vector 指针开销(`util/arena.cc:61-62`),但当前块内已被分配的部分即使没用满也计入,`alloc_ptr_` 位置之前的浪费不单列。对写入限流这个用途足够。

**Q10:LookupKey 为什么要 200 字节内联空间?13 字节余量怎么来的?**
13 = varint32 最长 5 字节 + tag 8 字节的保守估计(`db/dbformat.cc:119` 注释 "conservative")。200 字节内联覆盖绝大多数键,避免每次 Get 都 new/delete;超长键才退化为堆分配(析构时按 `start_ != space_` 判断释放,`db/dbformat.h:218-220`)。

---

## ⑧ 深挖问题(留给下一轮调研)

1. **`Insert` 的 barrier-free 优化**:TODO 注释提到 FindGreaterOrEqual 在 Insert 内可用无屏障变体(`skiplist.h:336-337`)。量化收益需要 benchmark:acquire load 在 x86 上本就是普通 mov,真正省的是 ARM 上的 load-acquire/ldar 成本。可以对比 RocksDB 的 inline skiplist 改动。
2. **Arena 的对齐缺口**:`AllocateAligned` 只对当前 `alloc_ptr_` 做对齐计算,若上一个请求走 `AllocateFallback` 单独开块,当前 `alloc_ptr_` 仍指向旧块尾部;下一次对齐请求的 slop 逻辑是否覆盖所有路径?`util/arena.cc:38-56` 的 `needed <= alloc_bytes_remaining_` 分支与新块回退分支的衔接值得形式化验证。
3. **Cache charge 的单位失真**:TableCache 用 `charge=1`(`db/table_cache.cc:72`)计"文件数"而 block cache 用字节,同一 `NewLRUCache` 抽象承载两种量纲;`usage_ > capacity_` 的驱逐时机对 file-number 型缓存意味着什么,L0 文件爆炸时 TableCache 会不会抖动?
4. **`max_height_` relaxed 读与内存回收的交互**:若未来把跳表改成支持删除(如 RocksDB 的 timing/hazard 方案),`skiplist.h:18-20` 的不变量 1 失效,现有全部内存序论证需要重推——这是理解"LevelDB 并发模型为什么便宜"的反向练习。
5. **WriteBatch → MemTable 的序列点**:同一批次的多条记录先全量 `InsertInto` 再检查 `write_buffer_size`(`db/db_impl.cc:444-455`),超大 batch 可能一次越过限流水位;`MakeRoomForWrite` 在写前只保证"写入前水位"(`db/db_impl.cc:1354`),这个间隙的内存上界 = write_buffer_size + 最大 batch 大小,可结合 `max_batch_size` 选项评估。

---

### 附:引用文件清单

| 文件 | 本篇涉及的关键行 |
| --- | --- |
| `db/skiplist.h` | 8-27(线程契约)、100-104(kMaxHeight/GetMaxHeight)、134-140(max_height_/rnd_)、144-185(Node/NewNode)、239-250(RandomHeight)、258-279(FindGreaterOrEqual)、334-366(Insert) |
| `util/arena.cc` / `util/arena.h` | arena.cc:9(kBlockSize)、20-36(Fallback)、38-56(Aligned)、58-64(NewBlock);arena.h:33-35(MemoryUsage)、50-52(TODO)、55-67(Allocate) |
| `db/memtable.cc` / `db/memtable.h` | memtable.cc:21-34(构造/比较器)、46-72(迭代器)、76-100(Add)、102-136(Get);memtable.h:22-39(引用计数)、75-82(成员) |
| `db/dbformat.cc` / `db/dbformat.h` | dbformat.cc:15-24(Pack/Append)、47-63(Compare)、117-134(LookupKey);dbformat.h:54-67(ValueType/seq)、102-117(比较器)、184-216(LookupKey) |
| `util/cache.cc` / `include/leveldb/cache.h` | cache.cc:43-63(LRUHandle)、70-148(HandleTable)、218-238(Ref/Unref)、267-304(Insert)、336-395(ShardedLRUCache);cache.h:5-16(意图)、46-98(接口) |
| `db/db_impl.cc`(交叉引用) | 441-466(恢复写路径)、1091-1096(迭代器 Ref)、1133-1164(Get 的 Ref/Unlock/Unref)、1354(水位检查)、1396-1400(换表) |
