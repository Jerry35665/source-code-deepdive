# E-SSTable 磁盘格式与工程文化(LevelDB 源码深读·第三卷·第 E 章)

> 调研基线:leveldb 1.23,commit `7ee830d`(CMakeLists.txt:7 `project(leveldb VERSION 1.23.0)`)。
> 本报告所有结论均逐行核对源码,标注 `文件:行号`(相对仓库根目录)。

---

## ① SSTable 全景:一个 .ldb 文件的物理布局

SSTable(内部称 Table)是 LevelDB 的核心磁盘数据结构。官方格式文档 `doc/table_format.md:4-15` 给出了顶层布局;`table/table_builder.cc:141-143` 的注释明确了每个 block 的三段式结构:`block_data: uint8[n]` + `type: uint8` + `crc: uint32`。把两者与源码合并,得到完整的字节视图:

```
+--------------------------------------------------------------+  offset 0
| Data Block 1            (4KB 前缀压缩 KV,可压缩)              |
|   [entry: shared|non_shared|value_len(varint32)|key_delta|value]*
|   [restarts[]: uint32*N][num_restarts: uint32]  (block 尾部)  |
+--------------------------------------------------------------+
| Data Block 2          ...                                     |
| Data Block N                                                  |
+--------------------------------------------------------------+
| Filter Block (meta block, 仅配置 filter_policy 时存在)         |
|   [filter 0][filter 1]...[filter N-1]   <- 每 2KB 偏移一个     |
|   [filter 偏移数组: 4*N][偏移数组起始: 4][lg(base): 1]          |
+--------------------------------------------------------------+
| Metaindex Block        ("filter.<Name>" -> BlockHandle)       |
+--------------------------------------------------------------+
| Index Block            (每个 data block 一条 sep key -> handle)|
+--------------------------------------------------------------+
| Footer (固定 48 字节)                                          |
|   metaindex_handle: varint64 offset + varint64 size  (<=10B)  |
|   index_handle:     varint64 offset + varint64 size  (<=10B)  |
|   padding:          0 填充到 40 字节                           |
|   magic:            fixed64 LE = 0xdb4775248b80fb57           |
+--------------------------------------------------------------+
```

三个锚点值得记住:

1. **BlockHandle 是最小寻址单元**:`offset`/`size` 均为 varint64,最大编码长度 `10+10=20` 字节(table/format.h:26,`enum { kMaxEncodedLength = 10 + 10 };`),编码在 table/format.cc:16-22(`BlockHandle::EncodeTo` 用两个 `PutVarint64`)。
2. **Footer 定长 48 字节**:`kEncodedLength = 2*BlockHandle::kMaxEncodedLength + 8`(table/format.h:53)。写入时两个 handle 后 `resize(2*kMaxEncodedLength)` 补零到 40 字节再写 magic(table/format.cc:36-38),因此读取端可以**从文件末尾反推**——`Table::Open` 直接 `file->Read(size - Footer::kEncodedLength, ...)`(table/table.cc:47-48)。
3. **magic number 是 URL 的 SHA-1 前缀**:table/format.h:73-76 的注释写明 `echo http://code.google.com/p/leveldb/ | sha1sum` 取前 64 位得 `0xdb4775248b80fb57`,这是 Google 式的"可追溯的魔法数"趣味。

footer 的解码顺序是"先验 magic,再解 handle":`Footer::DecodeFrom` 把指针跳到 `input + kEncodedLength - 8` 处读两个 fixed32 拼成 magic,不匹配立即返回 `Corruption("not an sstable (bad magic number)")`(table/format.cc:48-55),随后才从头部开始解码两个 handle,并把剩余 padding 切掉(table/format.cc:57-65)。这个"双端读"设计让一个错误格式的文件能被最快速度识别。

### 压缩与读路径的三态返回

`ReadBlock`(table/format.cc:69-162)一次读出 `n + kBlockTrailerSize` 字节(数据 + 1 字节 type + 4 字节 CRC,kBlockTrailerSize 见 table/format.h:79),CRC 校验范围是"数据 + type 字节"共 n+1 字节(table/format.cc:93-94),且仅在 `options.verify_checksums` 为真时执行。返回的 `BlockContents` 三字段(`data/cachable/heap_allocated`,table/format.h:81-85)支撑一条精妙的零拷贝路径:

```cpp
case kNoCompression:
  if (data != buf) {
    // File implementation gave us pointer to some other data.
    // Use it directly under the assumption that it will be live
    // while the file is open.
    delete[] buf;
    result->data = Slice(data, n);
    result->heap_allocated = false;
    result->cachable = false;  // Do not double-cache
```
(table/format.cc:102-116)

当 Env(如 mmap 实现)把数据放在自己的缓冲区时(`data != buf`),直接引用、不进 block cache,避免 OS page cache 与应用 cache 双份存储;只有 `heap_allocated` 的数据才是 `cachable` 的。压缩块则必须解压到新 buffer 并标记可缓存(table/format.cc:120-155),Snappy 与 Zstd 各一个 case,未知 type 一律 `Corruption("bad block type")`(table/format.cc:156-158)。

---

## ② Block 格式与重启点二分:前缀压缩换一次 IO 内的线性扫描

### 2.1 BlockBuilder:共享前缀 + 每 K 条重启

`table/block_builder.cc:5-27` 的头注释是理解 block 格式的最佳说明书:每条 entry 编码为 `shared_bytes(varint32) | unshared_bytes(varint32) | value_length(varint32) | key_delta | value`;块尾追加 `restarts: uint32[N]` 与 `num_restarts: uint32`。`Add` 的核心逻辑(table/block_builder.cc:71-105):

```cpp
size_t shared = 0;
if (counter_ < options_->block_restart_interval) {
  // See how much sharing to do with previous string
  const size_t min_length = std::min(last_key_piece.size(), key.size());
  while ((shared < min_length) && (last_key_piece[shared] == key[shared])) {
    shared++;
  }
} else {
  // Restart compression
  restarts_.push_back(buffer_.size());
  counter_ = 0;
}
```

即:每 `block_restart_interval`(默认 16,include/leveldb/options.h:106)条 key 强制存全量 key(`shared==0`)并记录偏移。`Finish` 把重启点数组追加到块尾(table/block_builder.cc:61-69),`CurrentSizeEstimate` 把 buffer、restart 数组、计数三项都算进去供 builder 判断是否达到 `block_size`(table/block_builder.cc:55-59)。一个工程细节:`last_key_` 的更新用 `resize(shared)` + `append`,在已持有前缀时避免整串拷贝(table/block_builder.cc:101-102)。

### 2.2 Block 解码端:防御性构造

`Block` 构造函数做两级完整性防御:块长不足 4 字节置 `size_=0` 作错误标记;`NumRestarts()` 若超过 `(size-4)/4` 的上限同样置零(table/block.cc:25-40),`NumRestarts` 本身就是从**最后一个 fixed32** 读出(table/block.cc:20-23)。`restart_offset_ = size_ - (1 + NumRestarts()) * sizeof(uint32_t)`(table/block.cc:37)标定数据区结束位置。

entry 解码函数 `DecodeEntry` 有一条针对"三个 varint 都 < 128"的快路径:先按 3 个单字节解出,若任一字节高位为 1 才回退到逐个 `GetVarint32Ptr`(table/block.cc:58-69)。这利用了小 value(几乎全是真实 KV)最常见的事实。函数签名注释里写明"Will not dereference past limit"(table/block.cc:51):所有越界判断都集中在 `limit - p` 的算术比较上,先检查剩余空间至少 3 字节,再在末尾用 `non_shared + value_length` 一次性验证 value 不越过数据区(table/block.cc:71-74)。这种"指针 + limit + 返回 nullptr 表失败"的解析风格贯穿整个 block 与 format 层,是 C++ 手写解码器的安全范本——没有异常、没有异常安全负担,每条路径都有界检查。

### 2.3 重启点二分:Seek 的三级查找

`Block::Iter::Seek`(table/block.cc:164-227)是全文件最精致的算法段:

1. **缓存热身**:若迭代器已 Valid,先用当前 `key_` 与 target 比较缩小二分边界(`current_key_compare < 0` 则 `left = restart_index_`,否则 `right = restart_index_`,table/block.cc:171-185)——对"顺序 Seek 递增 target"的游标型负载几乎免掉二分。
2. **重启点二分**:`while (left < right)` 用上取整 `mid = (left+right+1)/2`,解码 mid 处 restart 的 key,要求 `shared != 0` 视为损坏(重启点必须全量 key,table/block.cc:194),小于 target 收 `left = mid`,否则 `right = mid - 1`。
3. **段内线性**:定位到最后一个 restart_key < target 的区间后,从该重启点 `ParseNextKey` 逐条扫到第一条 >= target 的 key(table/block.cc:219-226)。

代价模型很清晰:16 条一重启时,最坏线性比较 16 次,但换来 **Prev() 与 SeekToLast 的可行性**——前缀压缩的 entry 无法单独反向解码,`Prev()` 只能"先回退到当前条所在重启点之前的一个重启点,再正向重放到原位置"(table/block.cc:143-162);`SeekToLast` 也只能到最后一个重启点一路扫到底(table/block.cc:234-239)。doc/index.md:169-170 顺势提示用户"reverse iteration may be somewhat slower than forward iteration"。

`ParseNextKey`(table/block.cc:250-277)在前进的同时用 while 循环维护 `restart_index_`,使后续 Seek 的热身猜测依然准确(table/block.cc:271-274)。任何解码失败统一走 `CorruptionError()` 设置 `Status::Corruption("bad entry in block")` 并失效迭代器(table/block.cc:242-248),错误被封装进 iterator 的 `status()` 而非抛异常。

---

## ③ TableBuilder:五段写入与 index key 的"最短分隔符"选择

### 3.1 写入流水线

`TableBuilder::Add`(table/table_builder.cc:94-123)的每一步都短小且幂等:

- 断言 key 严格递增(table/table_builder.cc:98-99);
- 若上一个 data block 刚 flush(`pending_index_entry`),此刻才补写 index 条目:先 `FindShortestSeparator(&r->last_key, key)` 再 `index_block.Add`(table/table_builder.cc:102-109);
- filter 记账 `filter_block->AddKey(key)`(table/table_builder.cc:111-113);
- data block 未压缩尺寸 `>= options.block_size`(默认 4KB,options.h:101)即 `Flush()`(table/table_builder.cc:119-122)。

`WriteBlock`(table/table_builder.cc:141-190)把 BlockBuilder 序列化后按 `options.compression` 压缩,但有一条保守线:压缩结果必须**至少省 12.5%**(`compressed->size() < raw.size() - (raw.size() / 8u)`,table/table_builder.cc:161,179),否则回退不压缩并改写 type 字节。`WriteRawBlock`(table/table_builder.cc:192-209)落盘时构造 trailer:type 字节 + `crc32c::Mask(crc)`,其中 CRC 覆盖"内容 + type"(`crc = crc32c::Extend(crc, trailer, 1)`,table/table_builder.cc:202)——与 ② 中 `ReadBlock` 的校验范围严格对偶。

`Finish()` 按固定顺序收尾(table/table_builder.cc:213-268):**filter block(不压缩)→ metaindex → index block → footer**。metaindex 的 key 是 `"filter." + policy->Name()`(table/table_builder.cc:232-236),value 是 filter block 的 BlockHandle。析构函数 `assert(rep_->closed)` 强制调用者显式选择 `Finish()` 或 `Abandon()`(table/table_builder.cc:72-76),`ChangeOptions` 只允许在构建中途改非 comparator 选项(table/table_builder.cc:78-92)。

### 3.2 index key:延迟一条记录的 sep 技巧

index 不存"块内最大 key",而是存一个介于两块之间的**最短分隔串**。Rep 构造时的注释把动机讲得极清楚(table/table_builder.cc:50-59):块边界跨 "the quick brown fox" 与 "the who" 时,索引 key 只需 `"the r"`——它 >= 前块所有 key 且 < 后块所有 key,而长度只有 5 字节。实现上,新 data block 的**第一条 key 到来时**才 `FindShortestSeparator(&r->last_key, key)` 定稿上一条索引项(table/table_builder.cc:102-108),因此 `pending_index_entry` 为真当且仅当 `data_block` 为空(不变式注释在 table/table_builder.cc:58)。

最末一块没有"下一条 key",退化为 `FindShortSuccessor(&r->last_key)`(table/table_builder.cc:245-251):按字节序找第一个可 +1 的字节截断,如 "the who" → "the x"。两个函数的 Bytewise 实现在 util/comparator.cc:31-67,均带 `assert(Compare(*start, limit) < 0)` 自证。

index block 自身还有一处反直觉配置:`index_block_options.block_restart_interval = 1`(table/table_builder.cc:35),即**完全不做前缀压缩**。因为 index 条目数少(每 4KB 一条),省空间收益小,而每条都是 seek 入口、二分定位时要求 restart 点解码即可得全 key——`restart_interval=1` 让每条都是 restart 点,Binary search 一步到位。

### 3.3 读端合流:Table::InternalGet 与两级迭代

`Table::InternalGet`(table/table.cc:214-242)是点查的骨架:index block 上 `Seek(k)` → 若配置了 filter 且 `!filter->KeyMayMatch(handle.offset(), k)` 直接判定 Not Found(table/table.cc:224-226,**一次磁盘读都不发生**)→ 否则 `BlockReader` 读块、`Seek`、回调。filter 的索引方式是把 `handle.offset()` 右移 `base_lg_` 映射到 2KB 桶(table/filter_block.cc:90-97)。而 `Table::NewIterator` 直接把 index block 迭代器与 `BlockReader` 函数指针喂给 `NewTwoLevelIterator`(table/table.cc:208-212)。

`TwoLevelIterator`(table/two_level_iterator.cc:18-69)把"上级是索引、下级是块"抽象成 `Iterator* (*BlockFunction)(void*, const ReadOptions&, const Slice&)`(table/two_level_iterator.cc:16),只实现控制流:`Next` 推进 data 迭代器,越界后 `SkipEmptyDataBlocksForward` 换下一个 index 项并 `SeekToFirst`(table/two_level_iterator.cc:103-126);`InitDataBlock` 记住 `data_block_handle_`,handle 未变就不重建块迭代器(table/two_level_iterator.cc:146-161)——这是跨块扫描时避免重复 IO 的关键。`status()` 融合 index/data 两层错误(table/two_level_iterator.cc:40-49)。BlockReader 一侧还用 `cache_id + block offset` 拼缓存 key(table/table.cc:169-172),并通过 `iter->RegisterCleanup` 把 Block 或 cache handle 的生命周期挂在迭代器上(table/table.cc:194-204)。

与点查并行的另一个入口是 `Table::ApproximateOffsetOf`(table/table.cc:244-269):在 index block 上 Seek 后取目标块的 `handle.offset()` 来估算 key 的物理位置;index 迭代器失效(说明 key 越过文件尾)或 handle 解码失败时,退化为返回 metaindex 偏移——"差不多等于文件末尾"。注释直白地承认这是近似:"Approximate the offset by returning the offset of the metaindex block"(table/table.cc:261-265)。这个函数是 compaction 选择输入文件与 `GetApproximateSizes` 的度量基础,精度要求刻意放宽到"块级"。

---

## ④ Bloom Filter 全参数解读

### 4.1 FilterPolicy 接口:策略模式的教科书样本

include/leveldb/filter_policy.h:27-52 只有三个纯虚函数:`Name()`、`CreateFilter(keys, n, dst)`(追加语义,注释明确禁止改写 `*dst` 已有内容)、`KeyMayMatch(key, filter)`。`Name()` 的注释要求"编码不兼容地变化时必须改名"(filter_policy.h:31-35)——这是 **metaindex 按 `filter.<Name>` 寻址**的格式级演进机制;bloom 内置策略的现名是 `"leveldb.BuiltinBloomFilter2"`(util/bloom.cc:26),后缀 2 就是历史上编码变更的痕迹。头注释还开宗明义点出收益:"a filter can cut down the number of disk seeks form a handful to a single disk seek per DB::Get() call"(filter_policy.h:8-11)。

### 4.2 布隆参数:k = round-down(bits_per_key × ln2),clamp 到 [1, 30]

`BloomFilterPolicy` 构造(util/bloom.cc:19-24):

```cpp
// We intentionally round down to reduce probing cost a little bit
k_ = static_cast<size_t>(bits_per_key * 0.69);  // 0.69 =~ ln(2)
if (k_ < 1) k_ = 1;
if (k_ > 30) k_ = 30;
```

`CreateFilter`(util/bloom.cc:28-54)的参数链条:总位数 `bits = n * bits_per_key`,但**最小 64 位**(防小 n 时误判率爆炸,注释在 util/bloom.cc:32-34);字节数 `(bits+7)/8` 后 `bits` 回升为字节的整数倍;数组尾部 `push_back(k_)` 把探测次数**随 filter 一起持久化**(util/bloom.cc:41),因此读端 `KeyMayMatch` 用的是**存进 filter 的 k** 而非本进程配置的 k(util/bloom.cc:63-65)——同一 SSTable 由不同参数版本生成后仍可正确读。`k > 30` 时直接返回 true(util/bloom.cc:66-70),这是给未来"短 filter 新编码"留的逃生门,宁可多读磁盘也不误判不存在。

**误判率推导**:标准布隆模型下,位数组 m 比特、n 个 key、k 个独立哈希,某一位未被置 1 的概率为 `(1 - k/m)^n ≈ e^{-kn/m}`。误判率

```
p = (1 - e^{-kn/m})^k
```

代入 LevelDB 的配置:m/n = bits_per_key(记作 b),k = b·ln2(理论最优),得经典闭式:

```
p_opt = (1/2)^{b·ln2} = (0.6185)^b ≈ e^{-0.4805·b}
```

b=10、k 理论值 6.93,`static_cast<size_t>(6.9)=6`(向下取整),实测 `p = (1 - e^{-0.6})^6 = 0.4512^6 ≈ 0.84%`,即文档宣称的 "~ 1% false positive rate"(filter_policy.h:54-57)。向下取整以"略增误判"换"每次查询少一次探测",注释直言这是故意的(util/bloom.cc:20)。b=16 时 p≈0.04%;b=32 时 p≈2e-4。

### 4.3 Double Hashing:两个哈希替代 k 个

```cpp
uint32_t h = BloomHash(keys[i]);
const uint32_t delta = (h >> 17) | (h << 15);  // Rotate right 17 bits
for (size_t j = 0; j < k_; j++) {
  const uint32_t bitpos = h % bits;
  array[bitpos / 8] |= (1 << (bitpos % 8));
  h += delta;
}
```
(util/bloom.cc:46-53)

只算一次 `BloomHash = Hash(data, size, 0xbc9f1d34)`(util/bloom.cc:13-15),探测序列用 `h + j·delta` 等差生成,delta 是把 h 循环右移 17 位——引用 [Kirsch, Mitzenmacher 2006] 的结论:双哈希模拟 k 哈希的渐近误判率不变。哈希本体 `Hash` 是类 murmur 的 32 位函数(util/hash.cc:22-53)。工程上要注意 `h % bits` 在 `bits` 非 2 的幂时有轻微模偏置,bits 恰好因字节对齐补齐而通常非 2 的幂,这是理论 purity 换单次除法的取舍。

### 4.4 Filter Block:按文件偏移分桶

`FilterBlockBuilder` 的调用序列被注释约束为正则 `(StartBlock AddKey*)* Finish`(table/filter_block.h:28-29)。粒度参数 `kFilterBaseLg = 11` → 每 **2KB 文件偏移**一个 filter(table/filter_block.cc:15-16),而非每个 data block 一个——多个 2KB 内的小块共享一个布隆,offset 数组才不会膨胀。`StartBlock(offset)` 算出目标桶号,`while (filter_index > filter_offsets_.size()) GenerateFilter()` 追平间隔,中间产生的空 filter 只登记偏移不写数据(table/filter_block.cc:21-27,空桶快速路径在 51-57)。

内存结构上,FilterBlockBuilder 是一个"两次摊平"的追加式设计(table/filter_block.h:45-49):AddKey 阶段只把 key 追加进共享的扁平字符串 `keys_` 并在 `start_` 记录偏移(table/filter_block.cc:29-33),每 key 零对象分配;GenerateFilter 时才构造 `tmp_keys_` 的 Slice 数组喂给 `policy_->CreateFilter`(table/filter_block.cc:60-70),用完即清。对一次写入几十万 key 的 flush 流程,这避免了为每个 key 建独立 std::string 的分配风暴——与 memtable/arena 的思路同源:**构建期热路径消灭小对象分配**。

`Finish` 布局(与 doc/table_format.md:75-90 逐字对应):N 个 filter 数据、N 个 fixed32 偏移、fixed32 "偏移数组起始位置"、最后 1 字节 `lg(base)`(table/filter_block.cc:35-49)。把 `lg(base)` 编进数据尾部,读取端 `FilterBlockReader` 就能独立解析:`index = block_offset >> base_lg_`(table/filter_block.cc:91)。防御规则是**错误即放行**:索引越界或布局异常返回 true"当作可能命中",宁可退化为多读磁盘也不返回错误(table/filter_block.cc:90-104,末行注释 "Errors are treated as potential matches");唯独 `start == limit` 的空 filter 明确匹配失败(table/filter_block.cc:98-100)。filter block 整体不压缩(table/table_builder.cc:223)、`Table::Open` 时经 metaindex 定位读入内存(table/table.cc:111-132),metaindex 解码失败会被静默忽略——注释:"meta info is not needed for operation"(table/table.cc:94-97)。

---

## ⑤ 代码风格与接口哲学

### 5.1 Slice:零拷贝的所有权契约

include/leveldb/slice.h:27-94,16 字节(`const char* data_; size_t size_;`)的非持有视图,`"Intentionally copyable"`(slice.h:41-43)。构造函数故意接受 `const std::string&` 与 `const char*`(slice.h:35-39)制造隐蔽的悬垂风险,因此在 doc/index.md:229-243 用整段反例警告:"it is up to the caller to ensure that the external byte array ... remains live"。Iterator 的 `key()/value()` 注释进一步限定生命周期:"valid only until the next modification of the iterator"(iterator.h:60-70)——**所有权靠注释与约定,不靠类型系统**,这是 2011 年 C++ 的务实主义:用最薄的抽象换取 memchr/memcmp 级别的效率,同时支持含 `\0` 的二进制 key(doc/index.md:204-210)。Block 迭代器是受益者:整块解压一次,key_ 只在共享前缀上增量拼接(table/block.cc:268-270),value_ 永远指向块内(table/block.cc:270)。

### 5.2 Status:一个指针的代价表达五种错误

include/leveldb/status.h:24-101。OK 状态就是 `state_ == nullptr`(status.h:57);错误状态是一个 `new[]` 数组,布局手工管理:`state_[0..3]` 消息长度、`state_[4]` code、`state_[5..]` 消息(status.h:95-100)。五种 code(kOk/kNotFound/kCorruption/kNotSupported/kInvalidArgument/kIOError,status.h:79-86)配合六个具名构造器(status.h:40-54)。这是**用堆分配换 Ok 路径零开销**的方案——错误是冷路径,Success 是热路径。移动构造只交换指针(status.h:115-118),拷贝赋值一个条件同时处理自赋值与两个 OK(status.h:106-114)。更重要的哲学在用法上:所有底层错误都被压缩为 `Corruption` + 人类可读短句(如 "bad block handle",table/format.cc:28;"block checksum mismatch",table/format.cc:97),错误沿调用链**只上抛不吞并**——`TwoLevelIterator::status()` 先报 index 错再报 data 错(table/two_level_iterator.cc:40-49),而 filter/metaindex 这类"可降级"的错误则明确允许被忽略(table/table.cc:94-97)。

### 5.3 Options:三层拆分与"持久格式常量"

Options 的分层是 API 设计课:`Options`(DB 生命周期级,options.h:34-148)、`ReadOptions`(单次读级:verify_checksums/fill_cache/snapshot,options.h:151-165)、`WriteOptions`(单次写级:仅 sync,options.h:168-186)。热路径参数刻意少,且都可动态改。最见功力的注释在 `CompressionType` 上:"NOTE: do not change the values of existing entries, as these are part of the persistent format on disk"(options.h:26-27)——枚举值就是磁盘字节,kNoCompression=0/kSnappy=1/kZstd=2(options.h:28-30),与 block trailer 的 type 字节同源。`paranoid_checks` 语义也在文档中有精确预期:"a corruption of one DB entry may cause ... the entire DB to become unopenable"(options.h:55-59)。

### 5.4 Iterator:统一抽象与 Cleanup 链

`Iterator`(iterator.h:24-102)是全项目唯一的核心抽象,memtable/sstable/db/MemEnv 全部收窄到 `Valid/SeekToFirst/SeekToLast/Seek/Next/Prev/key/value/status` 十个方法。它显式禁拷贝(iterator.h:28-29),`RegisterCleanup` 提供析构回调,让 BlockReader 能把"释放 Block / Release cache handle"挂到迭代器上而不必引入 shared_ptr(table/table.cc:197-201)。实现上,清理项存成侵入式单链表,头节点内联在 Iterator 对象里以省一次分配("Cleanup functions are stored in a single-linked list. The list's head node is inlined in the iterator",iterator.h:84-101)。资源追踪方向值得注意:**不是迭代器持有资源引用,而是资源销毁挂在迭代器销毁上**,于是 cache 语义(Release handle)与堆语义(delete Block)能以同一机制表达,调用方只需无脑 `delete iter`。`table/iterator_wrapper.h` 再包一层 `IteratorWrapper`,把"缓存 key()/value() 指针"的微优化做在迭代器交接处;`table/merger.cc` 的 MergingIterator 用同一接口把多个层级的迭代器合成一个 k 路归并——从 Block 到 DB 的整条迭代链因此全是同一抽象的组合,这是"接口先行"设计文化的最佳证据。错误表达走"失效 + status() 查询"而非异常(CMake 强制 `-fno-exceptions`,CMakeLists.txt:73),`NewErrorIterator` 甚至允许把 Status 本身变成一个迭代器(iterator.h:108)。

### 5.5 通用小工程学

- varint 编码:EncodeVarint32 用 if-else 展开五档(util/coding.cc:21-47),EncodeVarint64 用 while 循环(util/coding.cc:55-64);GetVarint32Ptr 在头文件内联了单字节快路径(util/coding.h:108-118),多字节回退到 `shift <= 28` 的循环(util/coding.cc:86-102)。Fixed 编码显式按字节组装并注释"optimize this to a single mov / str instruction"(util/coding.h:57-62),字节序中立、无对齐要求。
- CRC32C(Castagnoli 多项式)三件套:256 项字节表 + 4 个 stride 表按 16 字节 swath 展开(util/crc32c.cc:20-243),`kCRC32Xor` 前后取反(crc32c.cc:245-246);CPU 加速能力用已知向量 `0xdcbc59fa` 运行时探测(util/crc32c.cc:267-274),可用则走 `port::AcceleratedCRC32C`(SSE4.2/ARM)。`Mask/Unmask`(crc32c.h:29-38)用"循环右移 15 位 + 加 0xa282ead8"打乱存储的 CRC,注释点明动机:**防止"CRC 本身也被 CRC 覆盖"的嵌套自洽**("it is problematic to compute the CRC of a string that contains embedded CRCs")。
- 注释文化:几乎每个 .cc 开头 20-40 行散文注释描述格式与不变式(block_builder.cc:5-27、filter_block.h:5-8),关键 trade-off 都在决策点旁(12.5% 压缩阈值 table_builder.cc:164、向下取整 k bloom.cc:20、double-caching format.cc:104-111)。

---

## ⑥ 测试组织与 doc/ 体系

### 6.1 30 个 *_test.cc:一文件一模块,与被测物同目录

仓库共 30 个 `*_test.cc`(db/ 12 个、util/ 11 个、table/ 2 个、helpers/ 1 个、issues/ 3 个、benchmarks 侧另有)。布局原则是**测试与被测代码同目录同名**:`table/block.cc` 的行为由 `table/table_test.cc` 覆盖,`util/bloom.cc` 对 `util/bloom_test.cc`。规模差异反映风险等级:`db/db_test.cc` 2360 行为最大,而 `util/crc32c_test.cc` 只有 56 行。三个 issue 回归测试(issues/issue178/200/320)以问题编号命名,是"用户 bug 报告即测试用例"的标本。

三个组织样本:

1. **统计式测试**(`util/bloom_test.cc:109-150`):对 1 到 10000 递增的 key 数量建 filter,断言三条:filter 大小 ≤ `length*10/8+40`、真 key 全命中、**1 万次探测的误判率 ≤ 2%**;更进一步统计"超过 1.25% 的 mediocre filter 数量不得超过 good 的 1/5"(bloom_test.cc:140-149)——对概率结构做统计验收而非单点断言。
2. **向量式测试**(`util/crc32c_test.cc:12-39`):RFC 3720 B.4 的标准 CRC32C 测试向量,另测 Extend 的流式等价与 Mask 的可逆性(crc32c_test.cc:43-53)。
3. **跨实现参数化测试**(`table/table_test.cc:374-403`):一套 `Harness` 把同一 KV 操作序列同时打到 TABLE/BLOCK/MEMTABLE/DB 四种实现上,并按 `{compression on/off} × {restart_interval 1/16/1024}` 笛卡尔积跑(table_test.cc:383-403)——用行为等价性同时验证四个层次,防止某层单独走样。

测试装配在 CMakeLists.txt:293-405:googletest 从 `third_party/googletest` 子目录引入(CMakeLists.txt:303),单个 `leveldb_tests` 可执行文件聚合多数测试,`c_test.c` 与 env 测试因需要独立进程单独成 target(`leveldb_test` 函数,CMakeLists.txt:367-392);注意 shared library 构建下跳过大部分测试(CMakeLists.txt:327-352)。

共享测试基建集中在 `util/testutil.h`:gmock 匹配器 `IsOK` 与 `EXPECT_LEVELDB_OK` 宏把 Status 断言标准化(util/testutil.h:17-22),`RandomString/RandomKey` 生成含 `\x00`/`\xff` 等边界字节的随机键(util/testutil.h:34-40),配合 `helpers/memenv`(内存 Env,CMakeLists.txt:227-232 注释直言 "MemEnv is not part of the interface")让绝大多数测试完全脱离真实文件系统。值得一提的是 `db/corruption_test.cc`:它通过故障注入 Env 对文件**按区域随机打洞**(截断/翻转),然后断言 Repair 后能恢复到预期的记录数(corruption_test.cc:193-263 的 TableFileRepair、TableFileIndexData 等用例)——格式文档里的 CRC、magic、Footer 冗余设计都有对应的失效注入验证闭环。`db/db_test.cc` 则以 2360 行覆盖 GetLevel0Ordering、快照可见性等 LSM 语义,SSTable 格式正确性最终在这层被端到端兜底。

### 6.2 doc/:给"读者"与"维护者"分册

- **doc/index.md(525 行)是用户手册**:按 Opening/Status/Reads/Writes/Iteration/Snapshot/Slice/Comparator/Performance/Filter/Checksums/Env 组织,示例代码全部可编译;关键性能建议如"异步写比同步写快一千倍以上"(index.md:112)、block size"小于 1KB 或大于几 MB 都没有好处"(index.md:319-321)。
- **doc/impl.md(173 行)是维护者笔记**:Log/Sorted tables/MANIFEST/CURRENT 四类文件、level 尺寸公式 `10^L MB` 与 2MB 文件阈值(impl.md:33-42)、compaction 最坏 IO 推算"读 26MB 写 26MB,约 0.5 秒"(impl.md:110-119),甚至附 2011-02-04 ext3 上 10 万文件打开 16μs 的实测表(impl.md:146-156)——用数据支撑"是否需要分目录"的开放问题,末尾 Solution 1/2/3 直接记录未决方案(impl.md:127-137)。这种"把设计推演与待办写进仓库"的做法本身就是文化。
- **doc/table_format.md(108 行)是格式规范**:文件布局、BlockHandle、filter block 布局,以及一个诚实的 "stats" meta block TODO(table_format.md:95-108,至今未实现,只有 metaindex 的 `// TODO(postrelease): Add stats` 在 table_builder.cc:239 呼应)。

### 6.3 CMakeLists 的第三方依赖策略:全部可选、探测式链接

核心库**零强制第三方依赖**(CMakeLists.txt:120-232 的源列表全是 .cc/.h):crc32c、snappy、zstd、tcmalloc 四个库用 `check_library_exists` 探测(CMakeLists.txt:41-44),找到才链接(CMakeLists.txt:271-282),找不到则回退纯软件路径(如 CRC 的表驱动实现、`port::Snappy_Compress` 返回 false 时存原样,table_builder.cc:158-168)。googletest 与 google benchmark 是仅有的源码内嵌依赖(third_party/,CMakeLists.txt:303、411),且只进测试/benchmark target。对比性 benchmark 直接外挂 sqlite3 与 kyotocabinet(CMakeLists.txt:444-468)。编译纪律同样鲜明:禁异常、禁 RTTI、MSVC 下 `/EHs-c-` `/GR-`(CMakeLists.txt:56-78),clang 下开启 `-Wthread-safety` 并配 `-Werror`(CMakeLists.txt:265-269)。移植层收敛到 `port/port.h` + 生成的 `port_config.h`(CMakeLists.txt:99-105),doc/index.md:508-515 明示平台扩展点。

---

## ⑦ FAQ

**Q1:Footer 为什么是固定 48 字节?**
让"从文件尾部定位元数据"成为可能,无需任何前导信息:`kEncodedLength = 2*20+8`(format.h:53),两个 handle 各预留 20 字节、不足处补零(format.cc:36),magic 固定 8 字节读自 `kEncodedLength - 8` 偏移(format.cc:48)。文件损坏到尾部读不出来时,`Table::Open` 直接报 "file is too short to be an sstable"(table.cc:41-43)。

**Q2:index key 为什么不直接用块内最大 key?**
省空间且不失正确性。`FindShortestSeparator` 在两条块边界 key 之间取最短中间串("the r"),作为索引仍然 >= 前块全部 key 且 < 后块全部 key(table_builder.cc:50-59);compare 语义要求 `FindShortestSeparator` 产出严格 `start' < limit`(comparator.h:45-49)。index 有几千条时省下的字节可观,更关键的是短 key 让 index block 更常驻 cache。

**Q3:block 内为什么需要重启点?只有 Seek 的话前缀压缩不是更好吗?**
前缀压缩破坏了"任意 entry 可独立解码"的性质:`Prev()` 与 `SeekToLast` 无法从中间反向走,只能"回退到上一个重启点再正向重放"(block.cc:143-162, 234-239)。重启点同时是二分锚点——省掉对压缩 entry 的逐条解码。默认 16(options.h:106)是"压缩率 vs 随机访问延迟"的折中。

**Q4:CRC 为什么要 Mask?**
存储的 CRC 可能恰好等于内容里(另一个)CRC 的值时,校验会"内容与存储值一起变"而漏检。Mask 用"循环右移 15 + 加常数 0xa282ead8"打乱(crc32c.h:22-32),保证嵌套 CRC 情况下错误仍可检出;读写两端对称调用(crc32c.h:35-38,table_builder.cc:203,format.cc:93)。

**Q5:`verify_checksums` 默认 false 不危险吗?**
读路径默认信任 page cache/磁盘,换取点查零额外 CRC 开销;真正的防线在写入端(每 block 必算 CRC,table_builder.cc:201-203)和 `paranoid_checks`(打开后 index/metaindex 读取强制校验,table.cc:57-60, 89-92)。这与 doc/index.md:451-466 的两层说明一致:verify_checksums 是按读的,paranoid_checks 是按库的。

**Q6:filter 为什么按 2KB 文件偏移分桶而不是按 data block?**
块大小是可配的(且 index/其他 meta 也可能落进同一 2KB),按**物理偏移**分桶让 `KeyMayMatch(block_offset)` 只需一次移位寻址(filter_block.cc:91),不依赖任何逻辑块号;`StartBlock` 的 while 循环自动为大块补空 filter(filter_block.cc:21-27)。2KB 折中:桶太细 → 偏移数组与 filter 头开销大;太粗 → 一次误判要读整个大区间。

**Q7:bloom 的 k 为什么要存进 filter?上限 30 又是什么?**
允许同一 SSTable 被不同参数/版本的策略正确读取——读端用存的 k(bloom.cc:63-65)。k 存 1 字节,>30 的值域保留给未来编码(bloom.cc:66-70 注释 "Reserved for potentially new encodings for short bloom filters"),此时宁可误判(返回 true)也不假阴性。

**Q8:index block 为什么 `block_restart_interval = 1`?**
index 条目数少、key 已经由 sep 技巧压短,前缀压缩收益小;而每条 index 都是二分入口,`Block::Iter::Seek` 要求 mid 处解码出全量 key(`shared != 0` 即 Corruption,block.cc:194)。interval=1 让每条 entry 都是重启点,二分零线性回退(table_builder.cc:35)。

**Q9:压缩块小于多少就干脆不压缩?**
省不足 12.5%(`raw.size()/8`)就存原样并改 type 为 kNoCompression(table_builder.cc:158-169)——解压 CPU 成本通常不划算,同时 doc/index.md:328-331 声称"uncompressible data 自动禁用压缩"即指此机制。

**Q10:ReadBlock 里的 `cachable`/`heap_allocated` 有什么用?**
区分三种内存归宿:堆上解压结果 → 可进 block cache;Env 自带缓冲(如 mmap 指针,`data != buf`)→ 直接引用且不缓存,避免与 OS page cache 双份(format.cc:102-116);调用者依 `heap_allocated` 决定是否 `delete[]`(format.h:84)。filter block 就是靠它记住 `filter_data` 以便析构(table.cc:128-130)。

---

## ⑧ 深挖问题(供后续章节或复验)

1. **`Block::Iter::Seek` 热身优化的边界正确性**。`current_key_compare` 缩界后 `assert(current_key_compare == 0 || Valid())`(block.cc:213),`skip_seek = left == restart_index_ && current_key_compare < 0`(block.cc:214)允许不重置到重启点、直接从当前位置继续 `ParseNextKey`。需要形式化验证:当 `key_` 是上一 Seek 遗留、且中间发生过 CorruptionError 时,`restart_index_/current_` 的组合是否仍能保证不漏 key?(可对照 table_test.cc 的 Randomized 系列。)

2. **Filter 桶与 data block 的对齐错位**。filter 桶按"块起始偏移"分桶(filter_block.cc:22 `block_offset / kFilterBase`),但 `Flush()` 在写入后调用 `StartBlock(r->offset)`(table_builder.cc:136-138),`r->offset` 已含 5 字节 trailer。若一个 4KB data block 跨两个 2KB 桶,AddKey 归属哪个桶?空桶(第三个 filter)测试(filter_block_test.cc:109-113)只覆盖了跨桶,未覆盖 5 字节 trailer 造成的桶号偏移边界。

3. **Footer 无版本号,格式演进全靠约定**。magic 永不变化,block type 字节是唯一的向前兼容机制(未知 type → Corruption,format.cc:156-158);`Table::BlockReader` 甚至故意允许 index value 里带多余字段:"We intentionally allow extra stuff in index_value so that we can add more features in the future"(table.cc:162-164)。这套"宽松解析 + type 字段"策略 vs RocksDB 的 format_version 字段,是两种演进哲学的对照样本。

4. **双哈希布隆的理论缺口**。Kirsch-Mitzenmacher 证明的是渐近等价,`h % bits` 的模偏置与 `delta=rot17` 的碰撞相关项在 bits 较小时(强制 64 位下限,bloom.cc:34)误差多大?bloom_test 的统计断言只到 2%,能否在 bits_per_key=2(k=1)与 b=32(k=22)两端实测差距?

5. **`pending_index_entry` 与 `ChangeOptions` 的交互**。构建中途换 `filter_policy` 时,已写入的 filter 数据按旧 policy 生成,而 metaindex key 用 `options.filter_policy->Name()`(table_builder.cc:230-236)取的是**新值**——mid-build 更换 policy 会造成 metaindex 指向错误编码的 filter。`ChangeOptions` 只挡了 comparator(table_builder.cc:82-84),filter_policy 未挡,读端 `ReadMeta` 又静默忽略失败(table.cc:94-97),最终表现为"无 filter 降级"而非报错。这是接口约定上的一个真实缝隙。

---

### 附:本章核对过的文件清单

table/{format.cc,format.h,block.cc,block_builder.cc,table_builder.cc,table.cc,filter_block.cc,filter_block.h,filter_block_test.cc,two_level_iterator.cc};util/{coding.cc,coding.h,crc32c.cc,crc32c.h,bloom.cc,hash.cc,comparator.cc,bloom_test.cc,crc32c_test.cc};include/leveldb/{slice.h,status.h,options.h,iterator.h,comparator.h,filter_policy.h,table_builder.h};doc/{index.md,impl.md,table_format.md};CMakeLists.txt;NEWS。
