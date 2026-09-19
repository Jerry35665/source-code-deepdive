# 第 13 章 · ART 索引:10 种节点、内联 row ID 与"每索引一把锁"

> 基线:commit `7e886f44`。核心:src/execution/index/art/(node.hpp / base_node.cpp / leaf.cpp / art_operator.hpp / art.cpp)。

## 13.0 全景:10 种节点与一个 64 位指针

```
 NType: PREFIX | LEAF(废弃,仅读旧存储) | NODE_4/16/48/256
        | LEAF_INLINED | NODE_7/15/256_LEAF(嵌套叶子)     (node.hpp:22-33)
 NodePtr(64 位):bits 56-63 节点类型 | bits 32-55 段偏移 | bits 0-31 buffer id
 LEAF_INLINED:row ID 直接内联进 bits 8-63(GetRowId() = Get() & 0x00FF...FF,node.hpp:195-202)
 每 ART 9 个 FixedSizeAllocator(art.hpp:49),段大小即各节点 sizeof
 key = 保序编码的字节串:有符号/浮点翻转符号位(radix.hpp:45-47),复合 key 按列序拼接
 NULL 不生成 key(len=0 跳过)→ UNIQUE 列允许多个 NULL(art.cpp:318-327)
```

纠偏:本 commit 无 "Leis 式 SIMD Node16"——Node4/16 共享模板,**查找是线性扫描**,`src/execution/index/` 全目录 grep 无任何 SSE/AVX(base_node.hpp:72-82)。

## 13.1 节点谱系与 Grow/Shrink

Node4/16 布局 `count + key[N] + children[N]`,孩子按 key 字节有序、插入整体后移(base_node.hpp:30-33);Node48 用 256 项 `child_index` 字节表(EMPTY_MARKER=48,SHRINK<12);Node256 直查(SHRINK<36)。阈值全表:4→16(满 4)、16→48(满 16)、48→256(满 48)、256→48(≤36)、48→16(<12)、16→4(<4);嵌套叶子 7↔15↔256 同理。删除只剩一个孩子时 `Prefix::Concat` 把"父 prefix→Node4→孩子"压回前缀(base_node.cpp:78-100)。prefix 段 = key 字节+1 字节 count+9 字节元数据;`prefix_count` = min(key 总长按 8 对齐−1, 239),单列 INT32 即 7(art.cpp:1212-1241);超长前缀拆链,失配位 Split 出 Node4(prefix_handle.cpp:81-131)。

## 13.2 Leaf 三形态与 gate+嵌套 ART

leaf.hpp:17-22 是权威定义:①LEAF_INLINED——row ID 内联,唯一键**零 leaf 分配**;②LEAF——已废弃的 4 元素链表,仅 v1_0_0 存储兼容(art.cpp:1112-1141);③嵌套叶子——重复键时在 gate 后**以 row ID 为 key 建嵌套 ART**(row ID 天然唯一,永不重复)。第二个 row ID 到达时 `Leaf::MergeInlined` 合成 gate:两个 8 字节 row ID 前 7 字节相同则建 Node7Leaf 存末字节,否则 Node4 挂两个内联叶子(leaf.cpp:55-77);gate 只是 NodePtr metadata 最高位(AND_GATE=0x80,node.hpp:118-119)。纠偏:"sidecar 存储"不存在——重复键集合就在主树 gate 之后的嵌套节点里,共用同一批分配器。

## 13.3 Insert/Lookup/Delete 路径

Lookup:PREFIX 节点逐字节比 key,失配即返回;命中"任意叶子或 gate"即返回(art_operator.hpp:34-46)。Insert:树空建整键前缀+内联叶子;撞 prefix 失配 → Split 建 Node4;撞 LEAF_INLINED → 唯一索引先查 delete ART(同键同 row ID 才放行)否则 CONSTRAINT(art_operator.hpp:337-375);**chunk 内冲突回滚**:记下冲突下标,把本 chunk 已插入的 key 逐一 Delete 后抛 ConstraintException(art.cpp:591-624)。Delete 持三级引用下行,删空嵌套叶子后 Concat 拆 gate(art_operator.hpp:250-334)。索引扫描原生支持范围/批量等值:`Iterator::LowerBound`(iterator.cpp:223-309),保序 key 编码是前提。

## 13.4 并发与 MVCC:索引之外

纠偏:并发模型**极粗**——每索引一把 std::mutex,扫描/验证同样独占(index_lock.hpp:15-30; art.cpp:864, 885);ART 自身无版本管理。事务靠**本地三件套**(append ART/delete ART/rollback ART)实现"同事务删了再插同一 PK 不误报"(local_storage.cpp:24-31, 455-467);checkpoint 期间改动走**三棵 delta ART** 收尾合并(index_entry.cpp:200-276, 486-499)。

## 13.5 持久化:不是纯内存

纠偏:checkpoint 把 9 个 FixedSizeAllocator 的 buffer 经 PartialBlockManager 写进索引块,元数据只存 `allocator_infos + root`(art.cpp:1143-1192);重开库按句柄直接恢复、**不重建**(art.cpp:141-167)。磁盘懒加载路径存在(SegmentHandle 触发 LoadFromDisk,fixed_size_buffer.cpp:242-254),但主动 unpin/逐出被源码 FIXME 关闭(fixed_size_buffer.hpp:131-134)——运行期不受 memory_limit 驱逐。

## 13.6 设计动机

1. **row ID 内联**:唯一键零分配,树高更低、缓存更友好(node.hpp:195-202);
2. **嵌套 ART 代 sidecar**:重复键复用同一套节点机制,不引入第二存储(leaf.hpp:20-22);
3. **9 个定长分配器**:段大小即 sizeof,无碎片、可整体落盘恢复(art.cpp:126-136);
4. **保序 key 编码**:翻转符号位+大端+转义,让字节比较=值比较,范围扫描免解码(radix.hpp:170-194);
5. **事务本地 ART**:约束检查读"主树+本地删除集",锁粒度不用细化到节点(local_storage.cpp:455-467);
6. **delta ART 收尾**:checkpoint 期间写不阻塞,收尾一次性合并(index_entry.cpp:486-499)。

## 13.7 FAQ

**Q1:Node16 有 SIMD 查找吗?**
没有,与 Node4 共享线性扫描模板(base_node.hpp:72-82)。

**Q2:唯一键的叶子在哪?**
没有叶子,row ID 内联在 NodePtr 的 bits 8-63(node.hpp:195-202)。

**Q3:重复键怎么存?**
gate 后以 row ID 为 key 建嵌套 ART,永不重复(leaf.hpp:20-22)。

**Q4:ART 会因内存不足被逐出吗?**
不会,逐出被 FIXME 关闭;懒加载只在(fixed_size_buffer.hpp:131-134)。

**Q5:NULL 能进唯一索引吗?**
NULL 不生成 key,UNIQUE 列允许多个 NULL(art.cpp:318-327)。

**Q6:并发度多粗?**
每索引一把 std::mutex,读也独占(index_lock.hpp:15-30)。

**Q7:同事务删了再插同一 PK 会误报吗?**
不会,本地 delete ART 参与约束检查(local_storage.cpp:455-467)。

**Q8:checkpoint 期间能写索引吗?**
能,写进 delta ART,收尾合并(index_entry.cpp:486-499)。

**Q9:范围扫描怎么实现?**
Iterator::LowerBound 沿树下行,保序编码是前提(iterator.cpp:223-309)。

**Q10:prefix 最长多少?**
单节点 min(key 总长按 8 对齐−1, 239),超长拆链(art.cpp:1212-1241)。

## 13.8 小结与深挖方向

本章结论:**本 commit ART=10 种节点+内联 row ID+gate 嵌套树+9 分配器整树落盘+一把互斥锁,MVCC 在索引之外**。深挖:

1. Prefix::Concat 四种拓扑的分支正确性(prefix.cpp:70-96);
2. 并行批量构建(ParallelState?art.cpp 构建路径)与单线程插入的界限;
3. Node48 的 child_index 表在扩缩容时的重排成本(node48.cpp:8-56);
4. key 编码对复合升序/降序索引(ASC/DESC)的处理;
5. 索引块与 PartialBlockManager 的空间复用策略。
