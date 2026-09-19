# 第 03 章 · B+tree 与游标:双态结构、提交点分裂与显式栈遍历

> 基线:commit `fd01fc79`。核心:node.go / cursor.go / bucket.go。

## 3.0 全景:page/node 双态与 cursor 栈

```
        bucket.root = pgid 7(branch)              Seek("r") 后的 cursor 栈
 ┌─────────────────────────────────┐      ┌─────────────────────────────────────┐
 │ branch pg7  count=2             │◄─stack[0] elemRef{page=pg7, index=1}        │
 │  [0] k="m" → child pgid 12      │      └──────────────────┬──────────────────┘
 │  [1] k="t" → child pgid 13      │                         │ search 取 inodes[1].pgid
 └────────┬────────────────┬───────┘      ┌──────────────────▼──────────────────┐
   ┌──────▼──────┐  ┌─────▼─────────┐    │ elemRef{page=pg13, node=写后非nil,  │◄─stack[1]
   │ leaf pg12   │  │ leaf pg13     │◄───┘            index=0}                   │
   │ "a"→"v1"    │  │ "t"→"v7"      │      next(): 栈顶到顶 → 弹栈 → 上层
   │ "c"→"v2"    │  │ "w"→"v8"      │      index++ → 截栈 → first() 下钻
   └─────────────┘  └───────────────┘
 写事务中被触碰的页物化为 node(inode=统一内存元素);纯读时直读 mmap 页,零拷贝。
```

纠偏:分裂阈值与"pageSize/4"**无关**——不拆条件是键数 ≤4 或整节点装得下一页,切割点由 `pageSize × FillPercent`(默认 0.5,限幅 [0.1,1.0])决定(node.go:276, 281-287);pageSize/4 只出现在 rebalance 阈值与 inline 桶上限两处(node.go:419; bucket.go:611-613)。

## 3.1 双态互转:read/write 是同一有序数组的两种编解码

node 是"已物化的页"(node.go:11-21),inode 双态复用:叶态带 value/flags,支态带 pgid(node.go:594-604)。`node.read` 按页 count 线性展开,叶元素的 key/value 切片直接指进 mmap(node.go:161-188);`node.write` 反向把 inode 紧凑回填页尾数据区、`elem.pos` 记相对偏移,分支元素还校验 pgid≠自身页号防环(node.go:193-246)。物化入口 `bucket.node(pgid)` 先查 `b.nodes` 缓存,未命中才 read(bucket.go:647-672);mmap 可能重映射,所以写事务的 node 引用要靠 `dereference()` 整体拷回堆——这就是"返回值仅事务期内有效"承诺的实现(node.go:523-551; bucket.go:264-265)。

## 3.2 写路径:插入即有序,重复 key 后写胜

Put 链条:校验可写/长度上限(MaxKeySize=32768)→ `Cursor().seek(key)` 定位 → 命中子桶键报 ErrIncompatibleValue → **只 clone key 不 clone value** → `c.node().put(...)`(bucket.go:285-312)。put 用 sort.Search 二分 + copy 后移,**不存在批量排序时机**;精确命中原槽覆盖,后写胜(node.go:126-140)。Delete 命中切除并标 `unbalanced`,未命中静默返回(这是 Bucket.Delete 对不存在键是 no-op 的根源,node.go:144-158)。纠偏:全库唯一的 sort.Sort 是 spill 里对 children 列表(按首 key)排序,node.go 从未对 inodes 排序(node.go:348)。

## 3.3 分裂与合并:全部推迟到 Commit 两阶段

Put/Delete 期间树可以暂时超页或欠键——`tx.root.rebalance()`(tx.go:156)与 `tx.root.spill()`(tx.go:163)是仅有的两个结构调整点。spill 后序遍历先递归子节点再 `split(pageSize)`(node.go:348-359),每个产物:旧页号非 0 则先 free,`tx.allocate(size/pageSize+1)` 分配(大 value 由此得到连续 overflow 页组,node.go:368; db.go:836),落页后把首 key 作为分支元素插回父节点;分裂造出新父则递归 spill 直到新根拿到页号(node.go:399-402)。切割点 splitIndex 累加元素尺寸、首次越过阈值即停,且永远在 inode 边界、给第二页保底 2 个 key(node.go:315-335)。

rebalance 触发条件是"序列化尺寸 ≤ pageSize/4 **或** 键数 ≤ minKeys(叶 1/支 2)"(node.go:419-421)。纠偏:实现**只有**"并入右兄弟/并入左兄弟"两种整体合并,**没有教科书式的借位分支**——代码只检查自己、不检查目标兄弟是否过小,node.go:471 的注释"If both this node and the target node are too small"描述的逻辑并不存在(node.go:472-504);根为分支且只剩一个孩子时唯一孩子上提,树高减一(node.go:427-445)。

## 3.4 游标:显式栈即路径

Cursor 只有 bucket + `stack []elemRef` 两字段,elemRef 是 {page, node, index} 三元组——node 非空用 node.inodes,否则直读 page(cursor.go:18-21, 380-399)。seek 清栈从根逐层 sort.Search 下压,分支层取"最高命中 index"、未精确命中回退到前驱分支项(cursor.go:253-315);next 从栈顶向上找第一个未到顶的层,index++、截断其上所有层、first() 下钻到最左叶,空叶则重来(issue#450 补丁,cursor.go:218-250)。Delete 经 `c.node()` 沿栈把路径物化成 node 链再 del,**拒绝删子桶**(bucketLeafFlag → ErrIncompatibleValue,cursor.go:135-150)。文档明示:遍历中修改数据可能使游标失效,变更后必须重新定位(cursor.go:15-17)。

## 3.5 子桶写路径:inline 二选一

CreateBucket 出生的桶天然 inline:rootNode 是空叶节点、root=0,写回时就是父桶 value 里的 16 字节头+内联页;父桶随之 `b.page=nil` 永久降级,保证 inline 桶永无子桶(bucket.go:182-197)。commit 时 Bucket.spill 对每个打开过的子桶二选一:`inlineable()`(单叶、无子桶元素、页体 ≤ pageSize/4,不含 16B 头)则释放旧页整体内联回父桶;否则递归 spill、只把 16 字节 {root,sequence} 头写回父项(bucket.go:526-582, 586-613)。纠偏:inline 阈值判定不含 bucket 头,落盘 value 加上 16B 前缀可以略超 1/4 页(bucket.go:596-630)。

## 3.6 设计动机

1. **双态+惰性物化**:读路径零分配零拷贝,写放大压到"被触碰的页"(cursor.go:353-354);
2. **inode 即插即序**:内存/磁盘同构,read/write 线性互转,splitIndex 可按字节精确选点(node.go:315-335);
3. **结构调整集中到提交点**:单写者下"先全局 rebalance 再全局 spill"成为两个可测试的纯阶段(tx.go:154-167);
4. **FillPercent 桶级可调**:顺序追加负载调高填充率显著省页,补偿 B+ 树 50% 分裂的经典浪费(bucket.go:44-48);
5. **只合并不借位**:COW 下借位省不了写放大却翻倍分支复杂度(node.go:472-504);
6. **游标显式栈**:栈即路径,next/prev 均摊 O(1),elemRef 双态无缝覆盖读写两种存储(cursor.go:218-250)。

## 3.7 FAQ

**Q1:为什么 Get 也要建 Cursor?**
seek 一次同时给出 key/value/flags 和可写 node,Get/Put/Delete 全复用这条定位链(bucket.go:267-312)。

**Q2:游标返回值能留到事务外吗?**
不能,指向 mmap 或 node,事务结束/重映射即失效(cursor.go:13)。

**Q3:Seek 不存在的 key 返回什么?**
第一个 ≥ seek 的键值;没有则 nil,停在页尾时自动补 next(cursor.go:114-131)。

**Q4:同一 key Put 两次?**
原槽覆盖,后写胜,不产生重复元素(node.go:129-139)。

**Q5:树会因删除变矮吗?**
会,根只剩一个孩子时上提,树高减一(node.go:427-445)。

**Q6:FillPercent 持久吗?**
不落盘,每事务重设,限幅 [0.1,1.0](bucket.go:47-48; node.go:281-286)。

**Q7:Cursor.Delete 能删子桶吗?**
不能,报 ErrIncompatibleValue,删桶走 DeleteBucket(cursor.go:142-146)。

**Q8:小桶写超 1/4 页会当场分裂吗?**
不会,只是失去 inline 资格,下次 spill 释放内联页转普通桶(bucket.go:533-539)。

**Q9:大 value 有二级索引吗?**
没有,就是连续 overflow 页组上的一段字节,逻辑上仍是一个页(node.go:368; tx.go:486)。

**Q10:next() 里那个 continue 是什么?**
issue#450 修复:下一叶页可能为空,回退栈重试而不是停在空页(cursor.go:243-246)。

## 3.8 小结与深挖方向

本章结论:**B+tree="页/节点双态+提交点两阶段重构+显式栈游标",分裂看 FillPercent、合并只整并不借位**。深挖:

1. nodes.Less 取 child.inodes[0].key,空页被物化时是否可能越界(node.go:592);
2. spill 注释的"split-merge 材料化兄弟"触发链复现(node.go:345-347);
3. 同一 pgid 一事务内先 free 再 allocate 的页号复用窗口(node.go:362-368);
4. dereference 在 mmap 扩容时对大写事务尾延迟的影响(node.go:521-551);
5. Delete 后同一游标继续 next 的双态一致性(cursor.go:358-377)。
