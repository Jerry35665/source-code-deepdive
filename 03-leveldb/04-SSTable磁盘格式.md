# 第 04 章 · SSTable 磁盘格式:Footer、重启点与最短分隔符

> 基线:LevelDB 1.23,commit `7ee830d0`。行号均以该版本源码为准。

## 4.0 文件布局:五段式

SSTable(内部称 Table)的顶层布局(doc/table_format.md 与 table_builder.cc:141-143 注释合并):

```
+--------------------------------------------------------------+ offset 0
| Data Block 1..N        (4KB 前缀压缩 KV,可压缩)              |
|   [entry: shared|non_shared|value_len(varint32)|key_delta|value]*
|   [restarts[]: uint32*N][num_restarts: uint32]  (块尾)        |
+--------------------------------------------------------------+
| Filter Block            (每 2KB 文件偏移一个 bloom)           |
|   [filter 0..N-1][偏移数组 4N][偏移数组起始 4][lg(base): 1]    |
+--------------------------------------------------------------+
| Metaindex Block         ("filter.<Name>" -> BlockHandle)      |
+--------------------------------------------------------------+
| Index Block             (每个 data block 一条 sep key->handle)|
+--------------------------------------------------------------+
| Footer (固定 48 字节)                                         |
|   metaindex_handle(varint64 offset+size) ≤20B                |
|   index_handle(varint64 offset+size) ≤20B                    |
|   padding 补零到 40 字节                                       |
|   magic: fixed64 LE = 0xdb4775248b80fb57                      |
+--------------------------------------------------------------+
```

三个锚点:

1. **BlockHandle 是最小寻址单元**:offset/size 各 varint64,最大编码 10+10=20 字节(format.h:26);
2. **Footer 定长 48 字节**,读取端**从文件末尾反推**——`Table::Open` 直接 `Read(size - 48)`(table.cc:47-48);解码顺序"先验 magic 再解 handle"(format.cc:48-55),错误格式被最快识别;
3. **magic 是 URL 的 SHA-1 前缀**:format.h:73-76 注释原话,`echo http://code.google.com/p/leveldb/ | sha1sum` 取前 64 位——Google 式"可追溯的魔法数"趣味。

每个 block 都带三段式 trailer:数据 + 1 字节 type + 4 字节 CRC;CRC 覆盖"数据 + type"共 n+1 字节(format.cc:93-94)——写端(table_builder.cc:202)与读端严格对偶。

## 4.1 Block:前缀压缩 + 重启点二分

### 编码端

每条 entry:`shared_bytes | unshared_bytes | value_len(varint32) | key_delta | value`;每 `block_restart_interval`(默认 16,options.h:106)条强制存全量 key 并记录偏移(block_builder.cc:71-105)。**重启点是压缩与随机访问之间的桥梁**:前缀压缩的 entry 无法单独解码,重启点提供全量 key 锚点。

### Seek 的三级查找(table/block.cc:164-227)

1. **缓存热身**:若迭代器已 Valid,用当前 key_ 与 target 的比较结果收窄二分边界——对"顺序递增 Seek"的游标型负载几乎免掉二分;
2. **重启点二分**:上取整 `mid`,要求 mid 处解码的 `shared != 0` 视为损坏(重启点必须全量 key);
3. **段内线性**:从最后一个 restart_key < target 的重启点逐条扫到第一条 ≥ target。

代价模型:16 条一重启时最坏线性比较 16 次,换来 **Prev 与 SeekToLast 的可行性**——Prev 只能"回退到上一个重启点再正向重放"(block.cc:143-162),这是前缀压缩对反向遍历的固有代价(doc/index.md 顺势提示"reverse iteration may be somewhat slower")。

解码端防御:`DecodeEntry` 有"三个 varint 都 <128"的快路径;"指针 + limit + 返回 nullptr 表失败"的风格贯穿 block 与 format 层——**没有异常、没有异常安全负担,每条路径都有界检查**,C++ 手写解码器的安全范本。

## 4.2 TableBuilder:index key 的最短分隔符技巧

写入流水线(table_builder.cc:94-123):key 严格递增断言 → 上一块的 index 条目此刻才补写 → filter 记账 → data block 未压缩尺寸 ≥ 4KB 即 Flush。

**index 不存"块内最大 key",而是存两块之间的最短分隔串**。注释的例子(table_builder.cc:50-59):块边界跨 "the quick brown fox" 与 "the who" 时,索引 key 只需 **"the r"**——它 ≥ 前块所有 key 且 < 后块所有 key,长度只有 5 字节。实现上,**新 data block 的第一条 key 到来时才定稿上一条索引项**(延迟一条记录),因此 `pending_index_entry` 为真当且仅当 data_block 为空。最末块没有"下一条",退化为 `FindShortSuccessor`("the who"→"the x")。短 key 让 index block 更常驻 cache。

index block 自身还有一个反直觉配置:`block_restart_interval = 1`——**完全不做前缀压缩**。因为每条 index 都是 seek 入口,二分定位要求 restart 点解码即得全 key(table/block.cc:194),每条都是重启点让二分零线性回退。

**压缩的保守线**:压缩结果必须**至少省 12.5%**(`compressed < raw - raw/8`),否则回退不压缩(table_builder.cc:161)——解压 CPU 成本通常不划算。

## 4.3 读端合流:Table::InternalGet 与两级迭代

点查骨架(table.cc:214-242):index block 上 Seek → **配置了 filter 且 KeyMayMatch 为假时直接判定 Not Found——一次磁盘读都不发生**(224-226)→ 否则 BlockReader 读块、Seek、回调。filter 的索引方式:`handle.offset()` 右移 base_lg 映射到 2KB 桶(第 05 章)。

`TwoLevelIterator`(two_level_iterator.cc)把"上级是索引、下级是块"抽象成工厂函数,只实现控制流;`InitDataBlock` 记住 data_block_handle_,handle 未变就不重建块迭代器——跨块扫描避免重复 IO 的关键。BlockReader 用 `cache_id + block offset` 拼缓存 key,并通过 RegisterCleanup 把 Block/cache handle 的生命周期挂在迭代器上(table.cc:194-204)。

**ReadBlock 的三态返回**(format.cc:69-162)支撑一条精妙的零拷贝路径:Env(如 mmap)把数据放在自己缓冲区时(`data != buf`),直接引用、不进 block cache,避免 OS page cache 与应用 cache 双份存储;只有 heap_allocated 的数据才 cachable。压缩块解压到新 buffer 标记可缓存;未知 type 一律 Corruption。

**ApproximateOffsetOf**(244-269):index 上 Seek 后取目标块偏移估算 key 的物理位置,失效时退化为返回 metaindex 偏移("差不多等于文件末尾")——compaction 选择输入文件与 GetApproximateSizes 的度量基础,精度刻意放宽到块级。

## 4.4 Footer 无版本号的演进哲学

Footer 无版本号,magic 永不变化;block type 字节是唯一的向前兼容机制(未知 type → Corruption);`Table::BlockReader` 甚至故意允许 index value 里带多余字段("so that we can add more features in the future",table.cc:162-164)。这套"**宽松解析 + type 字段**"策略与 RocksDB 的 format_version 字段,是格式演进哲学的对照样本——宽松换兼容,严格换可控(深挖点:ChangeOptions 中途换 filter_policy 的缝隙)。

## 4.5 FAQ

**Q1:Footer 为什么固定 48 字节?**
让"从文件尾部定位元数据"成为可能,无需任何前导信息;文件太短直接报 "file is too short to be an sstable"。

**Q2:index key 为什么不用块内最大 key?**
最短分隔串省空间且不失正确性;几千条 index 时省的字节可观,更关键的是短 key 常驻 cache。

**Q3:block 内为什么需要重启点?**
前缀压缩破坏了"任意 entry 可独立解码";重启点同时是二分锚点与 Prev/SeekToLast 的回退点。默认 16 是压缩率与随机访问延迟的折中。

**Q4:压缩块小于多少就不压缩?**
省不足 12.5% 就存原样——解压 CPU 通常不划算。

**Q5:ReadBlock 的 cachable/heap_allocated 有什么用?**
区分三种内存归宿:堆上解压结果可进 block cache;mmap 指针直接引用且不缓存(避免与 page cache 双份);调用者按 heap_allocated 决定是否 delete[]。

**Q6:CRC 为什么覆盖 type 字节?**
写端 Extend 上 trailer 的 type(table_builder.cc:202)与读端校验范围严格对偶——type 被篡改也能检出。

## 4.6 小结与深挖方向

本章结论:**SSTable = "前缀压缩 + 重启点"换"一次 IO 内的线性扫描";index key 的 sep 技巧与延迟定稿是空间与 cache 友好性的双重优化;Footer 反推 + 双端读让格式自描述**。深挖:

1. Seek 热身优化(skip_seek 路径)在 CorruptionError 后的边界正确性;
2. filter 桶与 data block 的对齐错位(Flush 后 StartBlock 的 5 字节 trailer 偏移);
3. Footer 无版本号 vs RocksDB format_version 的演进哲学对照;
4. 双哈希布隆在小 bits 下的模偏置实测;
5. ChangeOptions 换 filter_policy 的真实缝隙(见第 09 章)。

> 下一章展开 SSTable 的点查利器:bloom filter 的全部参数与"错误即放行"的降级哲学。
