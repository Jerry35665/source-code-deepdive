# 报告 A3 · ART 索引(DuckDB 卷三)

> 基线:commit `7e886f44`。本卷讲 ART 自适应基数树的现代实现:10 种节点类型、row ID 内联进指针、gate+嵌套 ART 处理重复键、并行批量构建、checkpoint 整树落盘,以及"每索引一把互斥锁 + 事务本地 ART"的并发模型。所有 `文件:行号` 均在基线 commit 上逐一核对;行号默认省略目录前缀 `src/`(头文件在 `src/include/` 下同名目录)。

## 1. 全景:10 种节点、一个 64 位指针、9 个分配器

ART 实现位于 `src/execution/index/art/`(17 个 .cpp),入口类 `ART : public BoundIndex`(art.hpp:41)。
本 commit 的实现已远超经典"Node4/16/48/256 + 叶子"四件套,节点枚举有 10 种(node.hpp:22-33):

```cpp
// include/duckdb/execution/index/art/node.hpp:22-33
enum class NType : uint8_t {
    PREFIX = 1, LEAF = 2,
    NODE_4 = 3, NODE_16 = 4, NODE_48 = 5, NODE_256 = 6,
    LEAF_INLINED = 7,
    NODE_7_LEAF = 8, NODE_15_LEAF = 9, NODE_256_LEAF = 10,
};
```

要点拆开:

- `NODE_7/15/256_LEAF` 是"嵌套叶子"(gate 后只存字节的叶子,见 §3);
- `LEAF` 是已废弃的旧叶子链表,仅为读旧存储文件保留(leaf.hpp:19、29);
- 节点经 `NodePtr`(继承 `IndexPointer`)寻址:64 位里 bits 56-63 存节点类型(metadata),bits 32-55 存段偏移,bits 0-31 存 buffer id(index_pointer.hpp:23-27、55-71);
- `LEAF_INLINED` 直接把 row ID 塞进 bits 8-63:`GetRowId() = Get() & 0x00FFFFFFFFFFFFFF`(node.hpp:118-121、195-202);
- 每个 ART 持有 9 个 `FixedSizeAllocator`(art.hpp:49),下标 0-8 依次对应 PREFIX、LEAF、Node4/16/48/256、Node7/15/256Leaf,段大小即各结构体 sizeof(art.cpp:126-136);类型→下标映射在 node.cpp:105-128;
- 节点内存的每次访问都要经 `NodeHandle`/`ConstNodeHandle`→`SegmentHandle` 拿到指针(node_handle.hpp:25-85;fixed_size_buffer.hpp:119-186)。

key 不是值而是字节串:

- `Radix::EncodeData` 做保序编码:有符号数与浮点翻转首字节符号位(`FlipSign = byte ^ 128`,radix.hpp:45-47、170-194),无符号整型按大端写(radix.hpp:196-215);
- 字符串对 `<= 0x01` 的字节用 `\01` 转义、末尾补 `\0` 终止符(art_key.cpp:15-48);
- 多列复合 key 按列序拼接:`TemplatedGenerateKeys` 生成第一列,`ConcatenateKeys` 续接其余列(art.cpp:309-361、413-460);
- NULL 不生成 key:生成时被置为空 key(len=0),插入循环跳过(art.cpp:318-327、592-594),因此 UNIQUE 列允许多个 NULL。

## 2. 节点谱系:容量、定位方式与 Grow/Shrink

Node4 与 Node16 共用模板 `BaseNode<CAPACITY,TYPE>`:布局是 `count + key[CAPACITY] + NodePtr children[CAPACITY]`(base_node.hpp:30-33),孩子按 key 字节**有序**存放,插入时整体后移腾位(base_node.cpp:14-30)。查找是线性扫描——Node16 也不例外(base_node.hpp:72-82):

```cpp
// include/duckdb/execution/index/art/base_node.hpp:72-82
static OptionalNodePtr GetChildNode(const BaseNode &n, const uint8_t byte) {
    for (uint8_t i = 0; i < n.count; i++) {
        if (n.key[i] == byte) { /*...*/ return n.children[i]; }
    }
    return OptionalNodePtr();
}
```

其余节点:

- Node48:256 项 `child_index` 字节表按 key 字节直接索引,`EMPTY_MARKER=48` 表示空位,真实孩子压在 48 项数组里;`SHRINK_THRESHOLD=12`(node48.hpp:27-39);
- Node256:`NodePtr children[256]` 直查,`SHRINK_THRESHOLD=36`(node256.hpp:17-24);
- 嵌套叶子侧:Node7Leaf(7 字节)、Node15Leaf(15 字节,base_leaf.hpp:81-118)、Node256Leaf(256 位掩码 + count,node256_leaf.hpp:21-33);
- Node4::DeleteChild 删到剩 1 个孩子时,用 `Prefix::Concat` 把"父 prefix → Node4 → 孩子"三合一压回前缀(base_node.cpp:78-100;Concat 分四种拓扑,prefix.cpp:70-96)。

Grow/Shrink 全部发生在 `InsertChild`/`DeleteChild` 内部,阈值汇总:

| 转换 | 触发条件 | 代码 |
|---|---|---|
| Node4→Node16 | 满 4 再插 | base_node.cpp:61-76 |
| Node16→Node48 | 满 16 再插 | base_node.cpp:124-138 |
| Node48→Node256 | 满 48 再插 | node48.cpp:8-36 |
| Node256→Node48 | 删到 ≤36 | node256.hpp:23;node48.cpp:76-96 |
| Node48→Node16 | 删到 <12 | node48.cpp:38-56(node48.hpp:29) |
| Node16→Node4 | 删到 <4 | base_node.cpp:140-151 |
| Node7Leaf↔Node15Leaf↔Node256Leaf | 满 7/15 再插;删到 <7 / <15 降型 | base_leaf.cpp:61-68、78-100、126-146;node256_leaf.cpp:40-46 |

新节点类型由 `NodePtr::GetInternalNodeType(count)` 按 count 选型(node.cpp:353-362)。

前缀存储:

- prefix 段布局 = `prefix_count` 个 key 字节 + 1 字节 count + 9 字节元数据(`METADATA_SIZE = sizeof(NodePtr)+1`,prefix.hpp:25-29);
- `prefix_count` 构造时确定:取"复合 key 总长按 8 对齐再减 1"与"上限 239"的较小者(art.cpp:1212-1241),单列 INT32 即 7、单列 BIGINT 即 15;
- 超过单节点容量的前缀拆成链:`PrefixHandle::New` 循环 `MinValue(art.PrefixCount(), 剩余)` 串接(prefix_handle.cpp:25-42;Prefix::New 同义,prefix.cpp:56-68);
- 插入撞 prefix 且失配时在失配位 `Split`:原 prefix 截短为公共部分、失配字节成为新 Node4 的分支位、失配位之后的内容成为 Node4 对应孩子的 prefix(prefix_handle.cpp:81-131);
- 删除路径的 `Prefix::Reduce` 反向缩短前缀,并在缩短后把后继前缀链拼回来(prefix.cpp:98-153)。

## 3. Leaf 三形态与 duplicate key:gate + 嵌套 ART

leaf.hpp:17-22 的注释是权威定义,三种形态:

1. `LEAF_INLINED`:row ID 内联进 NodePtr。构造只有两行——设 metadata、SetRowId(leaf.cpp:15-20);row ID 必须 < `MAX_ROW_ID_LOCAL`(≈2^56,leaf.cpp:16;constants.cpp:11);
2. `LEAF`:**已废弃**的链表,每节点 4 个 row ID(`LEAF_SIZE=4`)+ `next_leaf` 指针(leaf.hpp:29、37-39),仅在 `v1_0_0_storage` 兼容路径写出(art.cpp:1112-1141);
3. 嵌套叶子:同一 key 有多个 row ID 时,以 row ID 为 key 在 gate 后建一棵嵌套 ART——row ID 天然唯一,嵌套树永不重复(leaf.hpp:20-22)。

第二个 row ID 到达时,`Leaf::MergeInlined` 把两个内联叶子合成为 gate 结构:

```cpp
// src/execution/index/art/leaf.cpp:55-62
if (pos == Prefix::ROW_ID_COUNT) {
    // The row IDs differ on the last byte.
    Node7Leaf::New(art, left_ref);
    Node7Leaf::InsertByte(art, left_ref, left_byte);
    Node7Leaf::InsertByte(art, left_ref, right_byte);
    left.SetGateStatus(status);
    return;
}
```

- 两个 8 字节 row ID key 的前 7 字节全同时(Node7Leaf 分支),最后一个字节存进 Node7Leaf;否则建 Node4,两个孩子仍是内联叶子(leaf.cpp:64-77);
- gate 只是 NodePtr metadata 的最高位(`AND_GATE=0x80`,node.hpp:118-119;置位/清除见 204-219);
- 删除把嵌套叶子删空后,`Prefix::Concat` 会把 gate 一并拆除(art_operator.hpp:272-276、300-330 触发;prefix.cpp:224-251)。

所以"sidecar 存储"不存在:重复键的 row ID 集合就在主树 gate 之后的嵌套 ART 节点里,与其它节点共用同一批分配器;查询侧 `LookupInLeaf` 在 gate 内按 row ID 下行、末字节落到嵌套叶子查询(art_operator.hpp:62-114)。

## 4. Insert / Lookup / Delete 代码路径(含行号)

**点查 Lookup**:`ART::SearchEqual`(art.cpp:750-761)→ `ARTOperator::Lookup`(纯 header 模板,art_operator.hpp:26-60):

```cpp
// src/include/duckdb/execution/index/art/art_operator.hpp:34-46
if (current.GetType() == NType::PREFIX) {
    ConstNodeHandle handle(art, current);
    auto data = handle.GetPtr();
    NodePtr child = ConstPrefixHandle::ChildRef(art, handle);
    for (idx_t i = 0; i < data[art.PrefixCount()]; i++) {
        if (data[i] != key[depth]) { return OptionalNodePtr(); }
        depth++;
    }
    current = child;
    continue;
}
```

- 命中"任意叶子或 gate"即返回(art_operator.hpp:30-31);内部节点走 `GetChildNode` 下行,每过一个节点深度 +1(49-56)。

**插入 Insert**:

- 入口 `ART::Insert`:先 `GenerateKeyVectors` 生成 key 数组与 row-id key 数组(art.cpp:569-581),再进 `InsertKeys`(art.cpp:583-637)逐条调 `ARTOperator::Insert`(art_operator.hpp:119-219);
- 树空时:`Prefix::New` 建整键前缀 + `Leaf::New` 挂内联叶子(art_operator.hpp:126-135);
- 内部节点没有对应孩子:`InsertIntoNode`——gate 外给剩余字节建 prefix 链再挂内联叶子,末字节到达时直接挂叶子(388-399);gate 内则直接 `InsertChild` row ID 叶子(379-385);
- prefix 失配:`InsertIntoPrefix` 建分支 Node4 并 Split(402-413);
- 撞上 `LEAF_INLINED`:`InsertIntoInlined`——非唯一索引或 `INSERT_DUPLICATES` 模式直接 MergeInlined 升级 gate;唯一索引先查 delete ART,同键同 row ID 才放行,否则 `CONSTRAINT`(337-375);
- **chunk 内冲突会回滚**:InsertKeys 记下冲突下标,把此前已插入的本 chunk key 逐一 `ARTOperator::Delete`(art.cpp:591-613),最后抛 `ConstraintException`(620-624)。

**删除 Delete**:

- 入口 `ART::TryDelete` 生成 key 后进 `ARTOperator::Delete`(art.cpp:683-700;art_operator.hpp:223-334);
- Delete 持有 great-grandparent / grandparent / parent 三级引用下行,删除后支持"Node4 压回 prefix"与嵌套叶子摘除(art_operator.hpp:250-271);
- `DeleteKeys` 把结果写进 deleted / non_deleted 两个 selection vector,返回删除数(art.cpp:702-740)。

**范围扫描**:

- `TryInitializeScan` 用表达式匹配器把常量比较 / BETWEEN 归一为 EQUALITY / RANGE / BATCH_EQUALITY 三种扫描(art.cpp:195-303);
- `SearchGreater` 用 `Iterator::LowerBound` 定位下界后向右扫(art.cpp:763-780;iterator.cpp:223-309);`SearchLess` 从 FindMinimum 扫到上界(art.cpp:782-799);`SearchCloseRange` 双界(801-819);
- 输出 `RowIdVectorOutput` 带容量上限,超容量返回 `CAPACITY_EXCEEDED` 并清空重来(art.cpp:845-851;iterator.hpp:86-107);
- 批量等值(point join)走 `InitializeBatchScan` / `ScanBatch`,逐 key 调 SearchEqual(art.cpp:298-303、821-843)。

ASCII:一棵 3 层 ART 插入两个 key 的结构演化(key A=[0x01,0x02] rid=10;key B=[0x01,0x04] rid=11;单列 INT32 的 prefix_count=7,art.cpp:1224-1240,整键装得进一个 prefix 节点):

```
步骤 1:插入 A(树为空)→ Prefix::New + Leaf::New(art_operator.hpp:126-135)
        tree
         │
     PREFIX[0x01,0x02] count=2
         │
     LEAF_INLINED rid=10             ← row ID 内联在指针 bits 8-63(node.hpp:196-202)

步骤 2:插入 B,前缀在 pos=1 失配 → InsertIntoPrefix 分裂(art_operator.hpp:402-413)
        tree
         │
     PREFIX[0x01] count=1            ← Split 截短公共前缀(prefix_handle.cpp:115-121)
         │
       Node4 count=2                 ← 新建分支节点,分支位即失配字节对
       ├─ 0x02 ─ LEAF_INLINED rid=10
       └─ 0x04 ─ LEAF_INLINED rid=11 ← 末字节直达 inlined leaf(art_operator.hpp:388-399)
```

## 5. 索引与表存储:CREATE INDEX、约束强制与持久化

**建索引的三条入口**:

- CREATE TABLE 的 PK/UNIQUE:`DuckTableEntry` 构造时遍历约束,UNIQUE 建唯一 ART、PK 置 `IndexConstraintType::PRIMARY`,直接 `storage->AddIndex(...)`(duck_table_entry.cpp:174-201);FK 的引用方也建 FOREIGN 索引(duck_table_entry.cpp:202-229);
- CREATE INDEX 语句走 `PhysicalCreateIndex`(CREATE_INDEX 算子):Sink 阶段抽 key 列 + rowid 列,PRIMARY 额外检查 NOT NULL(physical_create_index.cpp:85-110);Finalize 时 Vacuum + Verify + VerifyAllocations,再挂到表存储(physical_create_index.cpp:122-189);
- ART 的构建回调注册在 `ART::GetARTIndexType()`(art_index.cpp:170-182)。

**并行构建与结构合并**:

- `bind_data->sorted = true`:排序对 VARCHAR 与复合列也有益(art_index.cpp:27-42);
- Sink 时每个线程对 chunk 内 key 排序,`ARTBuilder` 从栈上自顶向下一次性成型——公共前缀只建一次,重复键直接报 CONSTRAINT(art_builder.cpp:10-89;art_index.cpp:111-128);
- Combine 阶段 local ART 经 `ART::MergeIndexes` 结构合并进 global ART(art_index.cpp:148-155;合并器 ARTMerger,art_merger.hpp:20-70;跨线程指针重排见 art.cpp:1351-1446)。

**约束强制 = 先验证后插入**:

- INSERT 路径先 `TableIndexList::VerifyUniqueIndexes` → `ART::VerifyAppend` → `VerifyConstraint`:对每行 Lookup,命中 leaf 后用 ConflictManager 记录冲突(art.cpp:1035-1071;data_table.cpp:828);
- UPSERT 按 conflict target 匹配"唯一且列集吻合"的索引,先 SCAN 后 THROW 两轮(table_index_list.cpp:218-247);
- FK 用同一 ART:APPEND_FK 查存在性、DELETE_FK 查残余引用,错误消息模板 art.cpp:931-954;FK 快速路径假定 leaf 内联(art.cpp:994-1004)。

**checkpoint 持久化**:

- `ART::SerializeToDisk`(art.cpp:1143-1161)把 9 个分配器的每个 buffer 经 `PartialBlockManager` 写进**索引块**:每个 FixedSizeBuffer 序列化时拿 partial block 分配、记录 `(block_id, offset)`,写完 Destroy 内存句柄(fixed_size_buffer.cpp:83-147);
- 索引元数据只存 `IndexStorageInfo`:root 节点指针 + 每个 allocator 的段大小、buffer id 列表、block 指针、段数(index_storage_info.hpp:48-87);
- `table_data_writer` 在表元数据流里写入这些 info(table_data_writer.cpp:196-215),旧行内 root_block_ptr 路径仅供旧版本反序列化(art.cpp:1200-1210);
- **WAL 侧**:只有 CREATE INDEX(及 Alter)把整棵内存快照写进 WAL(`WriteCreateIndex → SerializeIndex → SerializeToWAL`,write_ahead_log.cpp:392-412);日常 INSERT/DELETE 不为索引写 WAL,靠 checkpoint 落盘;
- 重启加载:按 allocator_infos 注册 block 句柄即完成"恢复",树不重建(art.cpp:141-167、1194-1198;fixed_size_buffer.cpp:59-66)。

**checkpoint 期间的并发改动**:

- 走三条 delta ART:`DELETED_ROWS_IN_USE` / `ADDED_DATA_DURING_CHECKPOINT` / `REMOVED_DATA_DURING_CHECKPOINT`(index_entry.cpp:156-276、501-556);
- checkpoint 收尾 `MergeCheckpointDeltas` 把 delta 树合并回主树(index_entry.cpp:486-499;ART 侧 RemovalMerge / InsertMerge,art.cpp:1450-1541);
- 删除较多后可 `Vacuum` 重排:任一分配器空闲段 >10% 即触发,整树遍历把指针迁出待清理 buffer(fixed_size_allocator.hpp:28-29;art.cpp:1299-1345)。

## 6. 并发与 MVCC:每索引一把互斥锁 + 事务本地 ART

```cpp
// include/duckdb/execution/index/index_lock.hpp:15-21
struct DUCKDB_CAPABILITY("mutex") DUCKDB_SCOPED_CAPABILITY IndexLock {
public:
    explicit IndexLock(const BoundIndex &index) DUCKDB_ACQUIRE(index.lock)
        : index_guard(index.lock), locked_index(index) {}
```

- **锁粒度 = 每索引一把 std::mutex**:`IndexLock` 就是 `lock_guard<mutex>`(index_lock.hpp:15-30);Append / Insert / Delete / Scan / Verify 全部先拿它;
- **读也独占**:三个扫描入口都构造 `IndexLock l(*this)`(art.cpp:864、885;批量 835),即同一索引内读写完全串行,并发度只存在于不同索引之间;
- `IndexEntry` 外层再包一把 StorageLock:写拿 exclusive,唯一索引追加时**共享锁住同名 delete index** 做比对(index_entry.cpp:40-56);
- `ART::VerifyConstraint` 的约束检查同样在 IndexLock 内(art.cpp:1035-1037)。

**与 MVCC 的关系:ART 自身不做版本管理**,靠外围三层:

1. 事务在 `LocalTableStorage` 持有每事务的本地 delete / append ART:`InitializeLocalIndexes` 为每个 PK/UNIQUE 主索引复制两棵空树(local_storage.cpp:24-31;index_entry.cpp:106-119);
2. 事务内插入写本地 append ART,并用"主索引 + 本地 delete ART"验证唯一性——实现同事务先 DELETE 后 INSERT 同一 PK 不误报(art_operator.hpp:343-370;art.cpp:956-992);
3. 提交时本地 append ART 合并进主索引(local_storage.cpp:459-467),行删除提交时把 row ID 写进本地 delete ART 供后续比对(local_storage.cpp:455);
4. checkpoint 期间主树被独占序列化,新改动改走 §5 所述 delta 树(index_entry.cpp:270-276);
5. 唯一索引 commit 窗口允许暂时存在"gate 内双 row ID 叶子"(DELETE+INSERT 同键),其它主索引追加被 WAL 锁 / commit 锁挡住,撞见即 FatalException(art_operator.hpp:152-163)。

## 7. 纠偏(以本 commit 源码为准)与设计动机

纠偏:

1. **"ART 常驻内存、重启需重建"不成立**:树随 checkpoint 序列化进索引块,重开库按 allocator_infos 直接恢复,不重建(art.cpp:1143-1198;fixed_size_buffer.cpp:59-66);
2. **"节点被缓冲池按需换入换出"只对一半**:从磁盘懒加载路径存在(SegmentHandle 发现 buffer 不在内存即 `LoadFromDisk`,fixed_size_buffer.cpp:242-254、149-166),但访问结束后主动 unpin/逐出的路径被 FIXME 关闭(fixed_size_buffer.hpp:131-134)——运行期索引内存并不随 memory_limit 驱逐(未观察到逐出实现,未核实更进一步行为);
3. **"Node16 用 SIMD/SSE 无分支查找"不成立**:Node4/16 共用 `for` 线性扫描(base_node.hpp:72-82);`src/execution/index/` 全目录 grep `_mm*/__m128/AVX` 无命中(2026-09-19 核对);
4. **"Leaf 是 row ID 链表"是旧版认知**:现行路径唯一键的 leaf 就是 64 位指针里的内联 row ID;4 元素链表 LEAF 仅为兼容保留(leaf.hpp:17-22、29、37-39);
5. **"ART 只能等值查找"不成立**:原生支持 >、≥、<、≤、BETWEEN 与批量等值(art.hpp:188-195;art.cpp:879-909;iterator.cpp:223-309),依赖 §1 的保序 key 编码;
6. **"CREATE INDEX 单线程逐条插入"不成立**:排序 + 逐 chunk 批量成型 + 多线程 local ART 结构合并(art_index.cpp:111-155;art_builder.cpp:10-89)。

设计动机(从代码可证的动机):

1. 点查复杂度只与 key 字节长相关、与行数无关,匹配约束检查这种高频点查负载(art_operator.hpp:26-60);
2. 前缀压缩把定长单列 key 压进一个节点(INT32→7 字节、BIGINT→15 字节,art.cpp:1224-1240),省内存也省一层访存;
3. row ID 内联进指针,使"唯一键 leaf"零额外分配;重复键才升级 gate+嵌套 ART,按需付出(leaf.cpp:15-78);
4. 保序编码 + `Iterator::LowerBound` 让同一棵树既服务约束又服务范围扫描,不必再养一棵有序结构(radix.hpp:170-194;iterator.cpp:223-309);
5. 定长段 + 每类型一个分配器,使"序列化 = 整 buffer 落块、恢复 = 注册句柄",checkpoint 与重启都免遍历重放(art.cpp:1143-1198);
6. 约束即索引:PK/UNIQUE/FK 与显式 CREATE INDEX 共用同一实现与验证路径,避免两套唯一性状态(duck_table_entry.cpp:174-229;art.cpp:1035-1071)。

## 8. FAQ 候选(每条一句话,正文可直接引用)

1. DuckDB 为什么用 ART 而不是 B-tree?——key 经保序编码按字节下行,点查只依赖 key 长度,唯一键零 leaf 开销,还天然支持范围扫描(§1、§7)。
2. 一个 key 有多长?——各列保序编码后拼接,VARCHAR 转义 `<=0x01` 字节并补 `\0` 终止(art_key.cpp:15-48)。
3. NULL 进不进索引?——不进,生成 key 时置空并跳过插入,所以 UNIQUE 列可存多个 NULL(art.cpp:318-327、592-594)。
4. 删除会让节点收缩吗?——会:Node256≤36、Node48<12、Node16<4 逐级降型,Node4 剩 1 孩子时压回 prefix(§2 表)。
5. 重复键的 row ID 存在哪?——主 key 位置留 gate,gate 后以 row ID 为 key 建嵌套 ART,不是 sidecar 文件(§3)。
6. 索引扫描用什么锁?——与写同一把每索引 std::mutex,读也是独占的(index_lock.hpp:15-30;art.cpp:864)。
7. checkpoint 时索引进 WAL 吗?——不进,进索引块(partial block);只有 CREATE INDEX 快照写 WAL(write_ahead_log.cpp:392-412)。
8. UPSERT 怎么找冲突行?——ConflictManager 按 conflict target 匹配索引,VerifyAppend 只读扫描并记录命中(art.cpp:1035-1071;table_index_list.cpp:218-247)。
9. 同事务删了再插同一个 PK 为什么不冲突?——插入时比对该 key 在本地 delete ART 中的 row ID,一致即放行(art_operator.hpp:343-370)。
10. Node48 收缩阈值为何是 12?——源码未写理由(未核实);可陈述的事实是常量 12 与 Node256 的 36(node48.hpp:29;node256.hpp:23)。

## 9. 深挖方向

1. ARTMerger 结构合并的不变式与 gate 交错情形(left/right 双 gate、前缀-叶子混合的 Emplace 约束,art_merger.hpp:20-70)。
2. checkpoint 三棵 delta 树的 `ShouldUse / MergeCheckpointDeltas` 时序,与乐观写 optimistic_writer 的交互(index_entry.cpp:200-276、548-576)。
3. NodeHandle/SegmentHandle 生命周期:`FreeNode` 触发整 buffer 释放时如何保证无悬挂读者(fixed_size_buffer.cpp:68-81;prefix_handle.cpp:127-131 注释)。
4. v1.0.0 双格式兼容:`TransformToDeprecated` 把嵌套叶子转回 4 元素链表、prefix 换 15 字节段的完整变换(art.cpp:1084-1110;leaf.cpp:106-145;node.cpp:405-445)。
5. Iterator 的容量暂停/续扫(ResumeScanState)如何保证分批输出 row ID 的语义正确(iterator.hpp:147-204;iterator.cpp:310 起)。

## 10. 正文蒸馏要点

1. 节点枚举实为 10 种:经典四件套之外还有 PREFIX、LEAF_INLINED、三个嵌套叶子与废弃 LEAF(node.hpp:22-33)。
2. NodePtr 64 位 = 类型(bits 56-63)+ 段偏移(32-55)+ buffer id(0-31);LEAF_INLINED 借 bits 8-63 直接存 row ID(index_pointer.hpp:23-27;node.hpp:195-202)。
3. Node4/16 查找是线性扫描,没有 SIMD;Node48 走 256 项字节表,Node256 直查(base_node.hpp:72-82;node48.hpp:29-39)。
4. Grow/Shrink 阈值:4→16→48→256 增长;收缩 36/12/4;Node4 剩 1 孩子时 `Prefix::Concat` 压回前缀(base_node.cpp:61-151;node48.cpp:38-96;node256.hpp:23)。
5. prefix_count = min(对齐后复合 key 长 − 1,239),超长拆 prefix 链;插入撞前缀在失配位 Split 出 Node4(art.cpp:1212-1241;prefix_handle.cpp:81-131)。
6. 唯一键 leaf = 内联 row ID;第二个重复 key 触发 MergeInlined,建 gate + 以 row ID 为 key 的嵌套 ART(leaf.cpp:15-78)。
7. Insert 路径:GenerateKeyVectors → InsertKeys → ARTOperator::Insert;chunk 内冲突会把已插 key 逐条回滚(art.cpp:583-637;art_operator.hpp:119-219)。
8. Lookup 命中"叶子或 gate"即返回;gate 内改以 row ID 为 key 继续,末字节落在嵌套叶子(art_operator.hpp:26-60、62-114、144-150)。
9. 索引扫描支持等值/单边/双边范围/批量等值,`Iterator::LowerBound` 定位下界;输出超容量即清空重试(art.cpp:747-910;iterator.cpp:223-309)。
10. PK/UNIQUE/FK 在建表时即生成 ART(duck_table_entry.cpp:174-229);CREATE INDEX 经 PhysicalCreateIndex 并行构建:排序 bulk build + ARTMerger 合并(physical_create_index.cpp:85-189;art_index.cpp:111-155)。
11. checkpoint 把 9 个分配器的 buffer 写进索引块,元数据只存 allocator_infos + root;日常 DML 不为索引写 WAL,CREATE INDEX 才写快照(art.cpp:1143-1192;table_data_writer.cpp:200-215;write_ahead_log.cpp:392-412)。
12. 并发模型:每索引一把互斥锁且读也独占;事务用本地 append/delete ART 承载 MVCC 语义,commit 合并,checkpoint 期间改动走三棵 delta ART(index_lock.hpp:15-30;local_storage.cpp:24-31、455-467;index_entry.cpp:200-276)。
