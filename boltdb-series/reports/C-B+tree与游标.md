# 报告 C · B+tree 与游标(BoltDB)

> 基线:fd01fc79c553a8e99d512a07e8e0c63d4a3ccfc5(master HEAD)。一句话总结:BoltDB 的 B+tree 是"页上有序元素数组"的双态结构——读路径零拷贝直读 mmap 页,写路径把被触碰的页物化为 node、在 inode 上即插即序地增删,分裂(spill/split)与合并(rebalance)整体延迟到 tx.Commit 的两个全局阶段,游标则用一叠 elemRef(page/node 双态)承载从根到叶的路径完成 seek/遍历。

## 一、双态模型:page(磁盘态)与 node(内存态),inode 作为公共元素

node 是"已反序列化的页"(node.go:10-21),字段极简:isLeaf、pgid、key(本节点首 key,供父定位)、parent/children、inodes。inode 是统一的内存元素(node.go:594-604),叶态带 value/flags,分支态带 pgid:

```go
// node.go:11-21
type node struct {
	bucket     *Bucket
	isLeaf     bool
	unbalanced bool      // 有删除,待 rebalance
	spilled    bool      // 本次事务已写页
	key        []byte    // 首个 inode 的 key,spill 时写进父节点
	pgid       pgid
	parent     *node
	children   nodes     // 仅用于 spill 追踪
	inodes     inodes
}
```

page 侧,分支元素只有 pos/ksize/pgid,叶元素多 flags/vsize(page.go:97-101、110-115),两者都是"定长头 + 尾部变长数据"的紧凑布局(page.go:104-127)。

- **node.read(page→node)**:按 p.count 线性展开成 inodes;叶元素直接把 key/value 切片指进 mmap,零拷贝(node.go:166-179),并把首个 inode 的 key 存为 n.key 以便 spill 时向父节点登记(node.go:182-187):

```go
// node.go:161-179(节选)
func (n *node) read(p *page) {
	n.pgid = p.id
	n.isLeaf = ((p.flags & leafPageFlag) != 0)
	n.inodes = make(inodes, int(p.count))
	for i := 0; i < int(p.count); i++ {
		inode := &n.inodes[i]
		if n.isLeaf {
			elem := p.leafPageElement(uint16(i))
			inode.flags, inode.key, inode.value = elem.flags, elem.key(), elem.value()
		} else { // 分支:inode.key 指向 mmap,inode.pgid 指向孩子
			elem := p.branchPageElement(uint16(i))
			inode.pgid, inode.key = elem.pgid, elem.key()
		}
	}
```

注意 read 不清空 inodes 以外的任何字段,unbalanced/spilled 标志与 parent/children 关系均由调用方(bucket.node)维护——同一页反复 pageNode 不会重复反序列化,因为有 b.nodes 缓存(bucket.go:647-649)。
- **node.write(node→page)**:先落 flags/count(node.go:193-207),再正序把每个 inode 的 key/value 依 ` 拷到页尾数据区,elem.pos 记录数据区偏移(node.go:210-243);分支元素额外校验 pgid != 自身页号防环(node.go:226)。inode 数超过 0xFFFF 直接 panic(node.go:199-201)。
- **物化入口 bucket.node(pgid, parent)**:先查 b.nodes 缓存(bucket.go:647-649),未命中才建 node 并 read,根节点记为 b.rootNode(bucket.go:652-672)。inline 桶用内嵌假页 b.page 代替 tx.page(bucket.go:660-663)。
- **读优先级 pageNode(id)**:根为 0(inline 桶)返回 rootNode 或假页;否则先查 node 缓存,最后落回 tx.page(bucket.go:705-727)。tx.page 又优先脏页缓存 tx.pages,再落 mmap(tx.go:571-579;db.go:792-795)。
- **dereference**:mmap 可能因扩容重映射,node 里指向旧映射的 key/value 引用必须整体拷贝到堆(node.go:523-551,由 Bucket.dereference 递归触发,bucket.go:693-701)。这是"返回值仅在事务期内有效"承诺(bucket.go:264-265)的实现基础。

## 二、写路径:bucket.Put → node.put,排序时机与重复 key 语义

Put 的完整链条(bucket.go:285-312):校验 tx 可写/非空 key/长度上限(MaxKeySize=32768、MaxValueSize=2^31-2,bucket.go:11-14)→ `b.Cursor().seek(key)` 定位(bucket.go:299-300)→ 若命中键带 bucketLeafFlag(是子桶)报 ErrIncompatibleValue(bucket.go:303-305)→ **只 clone key 不 clone value**(bucket.go:308-309,故文档要求 value 在事务期内保持有效,bucket.go:283-284)→ `c.node().put(...)`。

```go
// node.go:126-140
index := sort.Search(len(n.inodes), func(i int) bool { return bytes.Compare(n.inodes[i].key, oldKey) != -1 })
exact := (len(n.inodes) > 0 && index < len(n.inodes) && bytes.Equal(n.inodes[index].key, oldKey))
if !exact {
	n.inodes = append(n.inodes, inode{})
	copy(n.inodes[index+1:], n.inodes[index:])
}
inode := &n.inodes[index]
inode.flags = flags; inode.key = newKey; inode.value = value; inode.pgid = pgid
```

- **排序时机**:不存在任何"攒一批再 sort"的时机——每次 put 用 sort.Search 二分定位 + copy 后移,插入即有序,node.go 全文没有对 inodes 的 sort.Sort;唯一的 sort.Sort(n.children) 在 spill 里(node.go:348),排的是子节点列表(按各自首 key,node.go:592),仅用于确定性遍历。
- **重复 key**:exact 命中时不扩容、直接覆盖原槽位四个字段(node.go:129-139)——同一事务内对同一 key 反复 Put,后写胜,旧 value 引用被丢弃。
- **防串位**:put 前校验 pgid 不得高于 meta.pgid 高水位、oldKey/newKey 非零长(node.go:117-123),零长 key 会 _assert 拦截(node.go:140)。
- **删除**:node.del 同样二分定位,未命中静默返回(Bucket.Delete 对不存在 key 是 no-op 的根源),命中则切除并标 `unbalanced=true`(node.go:144-158);Put 不置任何脏标,靠 spill 阶段的 children 追踪。

## 三、spill 与 split:分裂全部发生在 Commit,阈值由 FillPercent 决定

提交管线是全局两段式:先 `tx.root.rebalance()`(tx.go:156),后 `tx.root.spill()`(tx.go:163),之后才轮到 freelist 重写与脏页落盘(tx.go:176-198)。**Put/Delete 期间树可以暂时超页或欠键,结构性调整被整体推迟到提交点。**

spill 是后序遍历:先 sort.Sort(n.children) 再逐个递归 spill(node.go:348-353),子节点 spill 中可能因 split 反向"材料化"出兄弟节点,所以不能用 range(node.go:345-347 注释明说);然后 `nodes := n.split(tx.db.pageSize)`(node.go:359),对每个产物:旧页号非 0 则先 freelist.free(node.go:362-365),`tx.allocate((node.size()/pageSize)+1)` 分配连续页组(node.go:368),write 落页并置 spilled(node.go:377-379),再把首 key 作为分支元素插回父节点(node.go:382-391)。若本次分裂造出了新父( pgid==0),递归 spill 父节点直到新根拿到页号(node.go:399-402)。

```go
// node.go:273-287(splitTwo)
if len(n.inodes) <= (minKeysPerPage*2) || n.sizeLessThan(pageSize) {
	return n, nil                    // 键数<=4 或整节点不足一页:不拆
}
var fillPercent = n.bucket.FillPercent
if fillPercent < minFillPercent { fillPercent = minFillPercent }        // 0.1
else if fillPercent > maxFillPercent { fillPercent = maxFillPercent }   // 1.0
threshold := int(float64(pageSize) * fillPercent)   // 默认 0.5*pageSize
```

- **不拆条件**:键数 ≤ minKeysPerPage*2(=4,page.go:12)或序列化后整页装得下(node.go:276)。
- **拆分位置**:splitIndex 从页头累加元素尺寸,首次超过 threshold 且已给第二页留足 2 个 key 时停(node.go:315-335);叶元素的 value 计入尺寸(node.go:322),拆分永远发生在 inode 边界。
- **新节点**:next 复制 n.isLeaf、挂到同一 parent(node.go:299-300);n 无父则就地造新父(node.go:294-296),随后由 spill 尾部递归把新父推成新根(node.go:399-402)。统计 tx.stats.Split++(node.go:307)。
- **切割点选择** splitIndex(node.go:315-335):

```go
// node.go:319-332(节选)
sz = pageHeaderSize
for i := 0; i < len(n.inodes)-minKeysPerPage; i++ {   // 给第二页保底 2 个 key
	index = i
	inode := n.inodes[i]
	elsize := n.pageElementSize() + len(inode.key) + len(inode.value) // 叶子含 value
	if i >= minKeysPerPage && sz+elsize > threshold {
		break                                          // 首次越过阈值即切割
	}
	sz += elsize
}
```

- **大 value 与 overflow**:分配页数 = size/pageSize+1(node.go:368),db.allocate 把 count-1 写进页头 overflow 字段(db.go:836),freelist 不够就地扩 mmap(db.go:839-849);写盘按 (overflow+1)*pageSize 连续写出(tx.go:486)。即一个逻辑叶页可横跨大量物理页,value 本体没有任何二级索引,就是一段连续字节(node.go:239-242)。

## 四、rebalance:25% 大小阈值,只有整体合并、没有借位

rebalance 在 Commit 开头按 bucket 自顶向下递归执行所有 unbalanced 节点(bucket.go:633-640;tx.go:156)。单节点判定(node.go:419-421):

```go
// node.go:419-421
var threshold = n.bucket.tx.db.pageSize / 4
if n.size() > threshold && len(n.inodes) > n.minKeys() {
	return                          // 大小>25% 且键数达标(叶1/支2)才安全
}
```

两个条件是 AND:序列化尺寸 ≤ pageSize/4(node.go:419)**或**键数 ≤ minKeys(叶 1、支 2,node.go:32-37)任一成立即触发合并。分支处理只有三条路:

1. **空节点直接摘除**:numChildren==0 时从父节点 del 本 key、移出 children、释放页,并递归 rebalance 父(node.go:451-458)。
2. **与一个兄弟整体合并**:目标兄弟只由自身位置决定——自己是第 0 个孩子就并给右兄弟,否则并给左兄弟(node.go:462-469);把 target(或自己)的 inodes 整体 append、父分支项删除、children 重挂、页释放(node.go:472-504),再递归 rebalance 父(node.go:507)。**代码不检查目标兄弟是否也过小**,只要自己欠键/欠大小就合并(node.go:420 只看 n);教科书 B 树的"从富兄弟借一个 key"分支在此不存在:

```go
// node.go:472-487(并入右兄弟分支,节选)
if useNextSibling {
	for _, inode := range target.inodes {          // 重挂孙节点父指针
		if child, ok := n.bucket.nodes[inode.pgid]; ok {
			child.parent.removeChild(child)
			child.parent = n
			child.parent.children = append(child.parent.children, child)
		}
	}
	n.inodes = append(n.inodes, target.inodes...)  // 整体并入
	n.parent.del(target.key)                       // 父分支项删除
	n.parent.removeChild(target)
	delete(n.bucket.nodes, target.pgid)
	target.free()
}
```

3. **根收缩**:根是分支且只剩 1 个孩子时,把唯一孩子的 inodes/children 上提、重挂父指针、删旧子(node.go:427-445),树高减一;根不会因欠键被删(node.go:425-448 直接 return)。

## 五、cursor.go:显式 ref 栈、seek 二分与栈回退遍历

Cursor 只有两个字段:所属 bucket 与 `stack []elemRef`(cursor.go:18-21);elemRef 是 {page, node, index} 三元组,双态取值——node 非空用 node.inodes,否则读 page(cursor.go:380-399)。栈天然就是"从根到当前叶"的路径。

- **seek**:清空栈,从 bucket.root 起 search 逐层下压(cursor.go:158-159);search 每层 append 一个 elemRef 并经 pageNode 取页/节点(cursor.go:253-272)。分支层用 sort.Search 找"最高命中 index":比较函数命中相等时记 exact,未精确命中则 index-- 落到前驱分支项(cursor.go:274-315);叶层 nsearch 只做普通二分定位(cursor.go:318-337)。seek 停在页尾(index>=count)时返回 nil(cursor.go:163-165),Seek 公开方法对此补一次 next()(cursor.go:121-123)。
- **first/last**:从栈顶向下,分支层取 index 处 pgid 继续压栈,直到叶层;first 压 index=0,last 压 count()-1(cursor.go:172-214)。
- **next 的栈回退**:从栈顶向上找第一个 index 未到顶的层,该层 index++,截断其上所有层,再 first() 下钻到最左叶(cursor.go:218-240);落点是空叶则 continue 重来——这是 issue#450 的修复(cursor.go:243-246),First() 里也有同样的空页补 next(cursor.go:40-42),Last() 没有此处理(空桶时靠 keyValue 的 count==0 判 nil,cursor.go:342):

```go
// cursor.go:219-248(节选)
for {
	var i int
	for i = len(c.stack) - 1; i >= 0; i-- { // 自顶向上找未到顶的层
		elem := &c.stack[i]
		if elem.index < elem.count()-1 {
			elem.index++
			break
		}
	}
	if i == -1 { return nil, nil, 0 }          // 全栈到顶:遍历结束
	c.stack = c.stack[:i+1]                    // 截断栈
	c.first()                                  // 下钻到该子树最左叶
	if c.stack[len(c.stack)-1].count() == 0 { continue } // 空页:重来(issue#450)
	return c.keyValue()
```

- **prev 是 next 的镜像**:从栈顶向上找第一个 index>0 的层减一,否则截栈;栈空返回 nil,否则 last() 下钻(cursor.go:85-111)。
- **Delete**:取栈顶当前元素,若带 bucketLeafFlag(子桶)报 ErrIncompatibleValue,只读事务/已关闭事务分别报错,最后 `c.node().del(key)`(cursor.go:135-150)。c.node() 在栈顶已是叶 node 时直接返回,否则从 stack[0] 起沿 childAt(ref.index) 把整条路径物化成 node 链(cursor.go:358-377)——即**删除动作总是落在可写 node 上,即使该叶页从未被写过**。
- 文档明示:遍历过程中修改数据可能使游标失效,变更后必须重新定位(cursor.go:15-17);返回的 key/value 仅在事务期内有效(cursor.go:13)。

## 六、bucket 入口调用链与子桶写路径(inline 条件)

- **Get**:Get(bucket.go:266)→ 新建 Cursor().seek(key)(bucket.go:267)→ flags 带 bucketLeafFlag 返回 nil(bucket.go:270-272)→ bytes.Equal 不等(即 seek 落在更大的键上)返回 nil(bucket.go:275-277)。Get 不做任何缓存,每次全价一次树搜索。
- **Put/Delete**:同链定位后分别调 c.node().put / c.node().del(bucket.go:309、334);Put 定位命中已有子桶键时报 ErrIncompatibleValue(bucket.go:303-305)。
- **ForEach**:纯 First/Next 循环(bucket.go:384-395),回调出错即中断;注释要求回调不得修改桶(bucket.go:380-383)。
- **Cursor()**:只递增统计并返回空栈游标(bucket.go:89-98)。
- **CreateBucket**:新桶初始即 inline——rootNode 是 `&node{isLeaf: true}`、root=0,write() 成 16B bucket 头 + 内联页的 value 塞进父桶(bucket.go:182-192);随后 `b.page = nil` 把父桶降级为普通桶,禁止 inline 桶再套子桶(bucket.go:194-197)。
- **子桶写路径 Bucket.spill**(bucket.go:526-582):先遍历 b.buckets 缓存(仅本事务打开过的子桶)——`child.inlineable()` 为真则 child.free() 释放旧页、write() 成内联 value(bucket.go:533-535);否则递归 child.spill() 后把 16B 的 {root, sequence} 头作为父桶 value(bucket.go:537-544)。子桶 rootNode 为 nil(未被改动)则跳过写回(bucket.go:548-550);否则 seek 定位后以 bucketLeafFlag put 回父节点(bucket.go:553-561)。最后自身 rootNode.spill 并把 b.root 更新为新根页号(bucket.go:570-579)。

```go
// bucket.go:586-608(节选)inline 条件
if n == nil || !n.isLeaf { return false }            // 只允许单叶
for _, inode := range n.inodes {
	size += leafPageElementSize + len(inode.key) + len(inode.value)
	if inode.flags&bucketLeafFlag != 0 { return false }        // 有子桶:不行
	else if size > b.maxInlineBucketSize() { return false }    // 超 pageSize/4:不行
}
// bucket.go:611-613
func (b *Bucket) maxInlineBucketSize() int { return b.tx.db.pageSize / 4 }
```

inline 的精确语义:内联**页体**(页头起算、逐元素累加)≤ pageSize/4、无任何子桶元素、根必须是单叶;最终写入的 value 还要再加 16 字节 bucket 头前缀(bucket.write,bucket.go:616-630),因此落盘值可以略超 1/4 页。

## 七、纠偏(以本 commit 源码为准)

1. **"分裂阈值是 pageSize/4"不成立**。pageSize/4 只出现在 rebalance(node.go:419)和 inline 上限(bucket.go:612);分裂的填充阈值是 `pageSize × FillPercent`(默认 0.5,bucket.go:33;限幅 [0.1,1.0],bucket.go:27-29、node.go:281-287),且先要过"键数>4 且超一整页"的门槛(node.go:276)。
2. **"rebalance 会向兄弟借位"不成立**。实现只有"并入左/右兄弟"两种整体合并(node.go:472-504),没有任何 redistribute/借位分支;且代码只检查自己不检查目标兄弟的大小,与 node.go:471 注释"If both this node and the target node are too small"不符——注释撒了半个谎。
3. **"存在批量排序时机"不成立**。inode 有序性由 put 的二分+后移插入逐次维护(node.go:126-133),全库从未对 inodes 排序;spill 里的 sort.Sort 只作用于 children 列表(node.go:348)。
4. **"Put 时拆树/删时合并"不成立**。Put/Delete 只改内存 node;合并统一在 Commit 开头的 rebalance 阶段(tx.go:156),分裂统一在随后的 spill 阶段(node.go:359),两阶段之间树形可以暂时不满足任何 B 树不变量。
5. **"大 value 会把叶子撑爆/单独成键"不成立**。大 value 不会触发特殊键结构:叶页在 spill 时按 size/pageSize+1 申请连续 overflow 页组(node.go:368;db.go:836),value 连续拷入(tx.go:486 落盘),逻辑上仍是一个页;单 value 上限 2^31-2 字节(bucket.go:14)。
6. **"inline 桶严格 ≤1/4 页"不严谨**。判定的 1/4 页不含 16 字节 bucket 头(bucket.go:596-603 vs 619),且阈值检查是逐元素提前退出,存在"加上当前元素才越界"的边界。

## 八、设计动机

1. **page/node 双态 + 惰性物化**:读事务永远只碰 mmap 页(keyValue 直接切页内字节,cursor.go:353-354),写事务只为被游标/put 触碰的路径建 node——把写放大压到"被改的页",也让只读路径完全零分配。
2. **inode 即插即序**:内存态与磁盘态同构(都是有序元素数组),read/write 只是线性互转;省掉批量排序,也让 splitIndex 能按字节精确选切割点。
3. **分裂/合并集中到提交点**:单写者模型下,把所有结构调整收敛为 Commit 里"先全局 rebalance、再全局 spill"两个可测试的纯阶段,遍历期间树形暂时失真也无并发读者可见。
4. **FillPercent 暴露为桶级参数**:顺序追加型负载把填充率调高可显著省页(bucket.go:44-48 注释明说),这是对"50% 分裂浪费一半空间"这一 B+ 树经典缺口的运营级补偿。
5. **rebalance 只合并不借位**:借位同样要改写两页,COW 体系下省不了写放大,却多出一倍分支复杂度;整页合并换来极短的代码路径和"删除后空间以页为单位奉还 freelist"的简单语义。
6. **游标显式栈**:栈即路径,seek 是 O(log n × 树高) 重搜,next/prev 回退均摊 O(1);elemRef 双态让同一套遍历代码无缝覆盖"纯读(页)"与"写后(节点)"两种存储。
7. **inline 子桶**:海量小桶场景免去每桶一页(4KB 粒度)的浪费,16B 头+内联页直接嵌进父桶 value。

## ASCII:B+ 树一层分支 + 两个叶子页,与 cursor 栈指向

```go
//        bucket.root = pgid 7(branch)                  Seek("r") 后的 cursor 栈
//  ┌───────────────────────────────────┐        ┌──────────────────────────────────────┐
//  │ branch pg7  count=2               │◄─stack[0] elemRef{node=nil, page=pg7, index=1}│
//  │  [0] k="m" → child pgid 12        │        └──────────────────┬───────────────────┘
//  │  [1] k="t" → child pgid 13        │                           │ searchNode 取 inodes[1].pgid
//  └─────────┬─────────────────┬───────┘        ┌──────────────────▼───────────────────┐
//            │                 │                │ elemRef{node=可写时非nil, page=pg13, │◄─stack[1]
//  ┌─────────▼────────┐ ┌──────▼───────────┐    │            index=0}                  │
//  │ leaf pg12        │ │ leaf pg13        │◄───┘(keyValue() 读 stack[1] 当前元素)      │
//  │  "a" → "v1"      │ │  "t" → "v7"      │    └──────────────────────────────────────┘
//  │  "c" → "v2"      │ │  "w" → "v8"      │
//  │  "m" → "v3"      │ │  (末元素)        │    next():  stack[1] 到顶 → 弹掉 → stack[0]
//  └──────────────────┘ └──────────────────┘            index++ → 截栈 → first() 下钻 pg13
//  分支层:branchPageElement{pos,ksize,pgid}   叶层:leafPageElement{flags,pos,ksize,vsize}
//  写事务中被改过的层,elemRef.node 非 nil(物化节点优先);纯读时 node=nil 直读页。
```

## FAQ 候选

1. 为什么 Get 也要临时建一个 Cursor?——因为 seek 一次就同时给出 key/value/flags 和可写的 c.node(),Put/Delete/Get/建桶全部复用这一条定位链(bucket.go:267、300、326、172)。
2. 游标返回的 key/value 能留到事务结束后用吗?——不能,它们指向 mmap 或 node 内存,事务结束/重映射即失效,长活引用要靠 dereference 拷贝(node.go:521-522;bucket.go:264-265)。
3. 遍历中途 Put/Delete 会怎样?——官方文档警告游标可能失效并返回意外的键值,变更后必须重新定位(cursor.go:15-17)。
4. Seek 一个不存在的 key 返回什么?——返回第一个 ≥ seek 的键值,没有更大的键则返回 nil,cursor 停在页尾时会自动补一次 next(cursor.go:114-131)。
5. Cursor.Delete 能删子桶吗?——不能,当前元素带 bucketLeafFlag 时返回 ErrIncompatibleValue,删桶必须走 DeleteBucket(cursor.go:142-146;bucket.go:217-261)。
6. next() 里那个 continue 是干什么用的?——修复 issue#450:下一个叶页可能是空的,此时回退栈重试而不是停在空页上(cursor.go:243-246、40-42)。
7. 树会因删除而变矮吗?——会,根为分支且只剩一个孩子时唯一孩子被上提,树高减一(node.go:427-445)。
8. FillPercent 是持久属性吗?——不是,它不落盘、每个事务都要重设(bucket.go:47-48),且被限幅在 [0.1,1.0](node.go:281-286)。
9. 同一事务内对同一 key Put 两次结果如何?——node.put 精确命中原槽原地覆盖,后写胜出,不产生重复元素(node.go:129-139)。
10. 小桶写多了超过 1/4 页会当场分裂吗?——不会,它只是失去 inline 资格:下次 spill 时释放内联页、按普通桶递归写真实页(bucket.go:533-539)。

## 深挖方向

1. nodes.Less 直接取 s[i].inodes[0].key(node.go:592),若某 child 的 inodes 为空(空页被物化)此处是否可能越界 panic——需要构造 rebalance 空节点与 spill 排序的竞态场景验证。
2. spill 注释提到的"split-merge 材料化兄弟"(node.go:345-347):children 切片为何会在子节点 spill 期间增长,具体触发链值得用 tx.stats.Split/Rebalance 做实验复现。
3. spill 对每个旧页调用 freelist.free(node.go:362-365)与 tx.pages 脏页缓存(tx.go:457-463)的一致性:同一 pgid 在一事务内先 free 再 allocate 的页号复用窗口。
4. dereference 的触发时机与代价:db.mmap 扩容(node.go:521 注释;db.go:847)时所有写事务 node 的 O(数据量) 拷贝,对大写事务的尾延迟影响。
5. c.node() 沿栈 childAt 物化路径(cursor.go:358-377)与 bucket.nodes 缓存(bucket.go:643-673)的交互:Delete 后同一游标继续 next 时,node 与 page 双态是否始终给出一致视图。

## 正文蒸馏要点

1. node 是页的内存镜像,inode 双态复用(叶带 value、支带 pgid),node.read 把页线性展开、node.write 把 inode 紧凑回填,两者是同一有序数组的两种编解码(node.go:161-188、191-246)。
2. 读路径零拷贝:keyValue 直接从 mmap 页切字节返回,仅在 mmap 重映射时由 dereference 整体搬到堆,这是"返回值仅事务期有效"的根因(cursor.go:340-355;node.go:523-551)。
3. Put/Delete 只改内存 node:put 用 sort.Search 二分 + copy 后移实现"插入即有序",精确命中则原地覆盖(后写胜),全库不存在对 inodes 的批量排序(node.go:126-140)。
4. 结构调整全部集中在 Commit:先 tx.root.rebalance() 再 tx.root.spill(),遍历/写入期间树形允许暂时违反 B 树不变量(tx.go:154-167)。
5. 分裂条件是"键数>4 且序列化后超一页"(node.go:276),切割点由 pageSize×FillPercent(默认 0.5)决定,split 后新父会被递归 spill 推成新根(node.go:287、399-402)。
6. 大 value 走 overflow 页组:spill 按 size/pageSize+1 申请连续页,overflow 存页头,写盘按 (overflow+1)×pageSize,无任何二级索引(node.go:368;db.go:836;tx.go:486)。
7. rebalance 的触发是"尺寸≤pageSize/4 或键数≤minKeys(叶1/支2)",只有并入左/右兄弟两种整体合并,没有借位分支,根收缩靠唯一孩子上提(node.go:419-421、472-504、427-445)。
8. 游标是显式 elemRef 栈:seek 清栈重搜、分支层二分取"最高命中 index"并回退到前驱,叶层普通二分;next/prev 靠上行截栈+first/last 下钻,空页靠 issue#450 补丁重试(cursor.go:154-169、274-315、218-250、40-42)。
9. Cursor.Delete 通过 c.node() 强制物化当前叶页为 node 再 del,且拒绝删除子桶(ErrIncompatibleValue)(cursor.go:135-150、358-377)。
10. Get/Put/Delete/CreateBucket 共用"Cursor().seek + c.node()"定位骨架,Get 每次全价搜索、不做任何缓存(bucket.go:266-279、285-312、161-200)。
11. 子桶在 spill 时二选一:inlineable(单叶、无子桶、页体≤pageSize/4,不含 16B 头)则释放旧页内联回父桶,否则递归 spill 并只把 16 字节 {root,sequence} 头写回父项(bucket.go:526-582、586-613、616-630)。
12. CreateBucket 出生的桶天然 inline(rootNode=&node{isLeaf:true}, root=0),父桶随之 b.page=nil 永久降级为普通桶,保证 inline 桶永无子桶(bucket.go:182-197)。
