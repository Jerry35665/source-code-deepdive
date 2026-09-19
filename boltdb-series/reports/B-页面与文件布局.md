# 报告 B · 页面与文件布局(BoltDB)

> 基线:fd01fc79... 一句话总结:BoltDB 的文件就是一棵以"页"为单位的 B+ 树镜像——16 字节页头 + 类型化元素区,无任何序列化层,mmap 直读、WriteAt 直写,元数据靠双 meta 页 + FNV 校验做崩溃恢复。

## 一、page 结构与 bptr 取址技巧

`page` 是文件格式的最小单位,固定四字段 + 一个"虚"指针字段(page.go:30-36):

```go
// page.go:30-36
type page struct {
    id       pgid     // uint64,页号
    flags    uint16   // 页类型位标志
    count    uint16   // 元素个数
    overflow uint32   // 本页之后紧随的溢出页数
    ptr      uintptr  // 不落盘,仅标记元数据区起点
}
```

页头大小不是写死的常量,而是用 `unsafe.Offsetof` 取 `ptr` 的偏移算出来的——64 位平台上为 16 字节(id 8 + flags 2 + count 2 + overflow 4)(page.go:10)。`ptr` 之后就是元数据区:meta 页从这里放 `meta` 结构(page.go:53-55),叶子/分支页从这里放元素数组(page.go:58-61, 72-74)。两种元素的内存布局(page.go:97-115):

```go
// page.go:97-101
type branchPageElement struct {  // 16B: pos(4)+ksize(4)+pgid(8)
    pos   uint32
    ksize uint32
    pgid  pgid
}
// page.go:110-115
type leafPageElement struct {    // 16B: flags(4)+pos(4)+ksize(4)+vsize(4)
    flags uint32  // bit0 = bucketLeafFlag,表示该 entry 是子 bucket
    pos   uint32
    ksize uint32
    vsize uint32
}
```

key/value 取址技巧("bptr 偏移"):key 不存在元素里,`pos` 是**相对该元素自身地址**的字节偏移,key 紧随其后,value 再紧随 key(page.go:118-127):

```go
// page.go:118-127
func (n *leafPageElement) key() []byte {
    buf := (*[maxAllocSize]byte)(unsafe.Pointer(n))
    return (*[maxAllocSize]byte)(unsafe.Pointer(&buf[n.pos]))[:n.ksize:n.ksize]
}
func (n *leafPageElement) value() []byte {
    buf := (*[maxAllocSize]byte)(unsafe.Pointer(n))
    return (*[maxAllocSize]byte)(unsafe.Pointer(&buf[n.pos+n.ksize]))[:n.vsize:n.vsize]
}
```

写页时 `elem.pos = &b[0] - elem`(b 是元素数组之后的可写区起点),即先排 count 个定长元素,再连续追加所有 key/value(node.go:210-243)。`[0x7FFFFFF]T` 的巨型数组写法只是 Go 里做指针运算的惯用法,不会真的分配(page.go:59)。分支元素没有 flags/vsize,多一个 8 字节 `pgid` 直接指子页号(page.go:97-101)。

## 二、四种页类型与"无序列化"的文件格式

flags 编码只有 4 个位,可按位组合(page.go:17-26):branch=0x01、leaf=0x02、meta=0x04、freelist=0x10;元素级另有 `bucketLeafFlag=0x01` 标记"值是一个子 bucket"(page.go:24-26,bucket.go:115)。`typ()` 是按位探测的调试辅助(page.go:39-50)。

关键事实:**整个库(非测试代码)没有一处 encoding/binary**——已 grep 全仓核实,匹配仅在 *_test.go 与 cmd 工具中。所谓"序列化"就是把 Go struct 的原始内存用 `WriteAt` 原样写盘(tx.go:500),读取则是 `PROT_READ` 的 mmap 直接 cast 指针(bolt_unix.go:47,db.go:792-795):

```go
// db.go:792-795
func (db *DB) page(id pgid) *page {
    pos := id * pgid(db.pageSize)
    return (*page)(unsafe.Pointer(&db.data[pos]))
}
```

推论:文件端序 = 宿主机端序(x86/ARM 小端,s390x 大端),跨端序机器拷贝文件未做任何转换处理(未核实官方兼容性声明,仅从代码无字节序转换得出)。写事务路径:node 先 split 再 `node.write(p)` 填页(node.go:339-405, 190-246),`count` 超过 0xFFFF 直接 panic(node.go:199-202)。

## 三、meta 页:字段、双页交替与 FNV 校验

meta 结构 64 字节,落在页头 16 字节之后(db.go:970-980):

```go
// db.go:970-980
type meta struct {
    magic    uint32 // 0xED0CDAED (db.go:24)
    version  uint32 // =2 (db.go:21)
    pageSize uint32
    flags    uint32
    root     bucket // 根 bucket: {root pgid, sequence},16B (bucket.go:68-72)
    freelist pgid   // freelist 起始页号
    pgid     pgid   // 高水位:总页数
    txid     txid   // 产生本 meta 的事务 id
    checksum uint64 // FNV-1a64,不参与哈希
}
```

校验算法是 **FNV-1a 64 位**,只哈希 `meta` 起始到 `checksum` 字段之前的 56 字节(db.go:1018-1022);`validate` 检查 magic→version→checksum,且 **checksum==0 时跳过校验**(db.go:983-992)。三个对应错误:ErrInvalid / ErrVersionMismatch / ErrChecksum(errors.go:17, 21, 24)。写 meta 时页号由 txid 奇偶决定,实现双 meta 交替覆盖(db.go:1000-1015):

```go
// db.go:1007-1012
// Page id is either going to be 0 or 1 which we can determine by the transaction ID.
p.id = pgid(m.txid % 2)
p.flags |= metaPageFlag
// Calculate the checksum.
m.checksum = m.sum64()
m.copy(p.meta())
```

读取端 `db.meta()` 取 txid 较高且 validate 通过的那份,失败则回退另一份,双双失败才 panic(db.go:803-824);mmap 时也要求"两个 meta 至少一个有效"(db.go:281-294)。

## 四、溢出页(overflow)与大 value 落盘

溢出是**页级**的:页头 `overflow` 字段记录"本页之后还有几个连续页",不是 per-value 的链表(page.go:34)。分配时一次性把 `overflow = count-1` 写进页头(db.go:836);释放时按 `p.id..p.id+overflow` 逐页入 freelist(freelist.go:116-128);落盘时按 `(overflow+1)*pageSize` 整段写出,超过 `maxAllocSize`(amd64 上 0x7FFFFFFF,bolt_amd64.go)再分块(tx.go:485-516):

```go
// tx.go:485-494
for _, p := range pages {
    size := (int(p.overflow) + 1) * tx.db.pageSize
    offset := int64(p.id) * int64(tx.db.pageSize)
    ptr := (*[maxAllocSize]byte)(unsafe.Pointer(p))
    for {
        sz := size
        if sz > maxAllocSize-1 { sz = maxAllocSize - 1 }
        ...
```

释放侧与分配侧对称:free 时连同溢出区间逐页挂到当前写事务的 pending 桶里,并用 cache 拒绝双重释放(freelist.go:111-129):

```go
// freelist.go:116-127
// Free page and all its overflow pages.
var ids = f.pending[txid]
for id := p.id; id <= p.id+pgid(p.overflow); id++ {
    // Verify that page is not already free.
    if f.cache[id] {
        panic(fmt.Sprintf("page %d already freed", id))
    }
    // Add to the freelist and cache.
    ids = append(ids, id)
    f.cache[id] = true
}
```

大 value 的落盘方式:spill 阶段按 `node.size()` 估算,`tx.allocate((size/pageSize)+1)` 分配足够多的连续页(node.go:368),value 原样内联在叶子页数据区,溢出部分由后续连续页承载;单个 value 上限 `MaxValueSize = (1<<31)-2`(bucket.go:15)。`Tx.check` 会把 `freelist..freelist+overflow` 与每个可达页的溢出区间计入 reachable,防止漏检(tx.go:399-401, 431-437)。

## 五、freelist:ids/pending/cache 三件套与生命周期

freelist 是纯内存结构,三件套各司其职(freelist.go:11-15):`ids` 是当前可直接分配的空闲页(有序),`pending[txid][]pgid` 是已释放但可能仍被读事务引用的页(按事务分组),`cache` 是"空闲∪pending"的布尔式快速判重 map(freelist.go:157-160)。

分配是**首适应(first-fit)**:沿有序 `ids` 扫描,找长度恰为 n 的连续段,从头部摘走时走 slice 快路径(freelist.go:67-107):

```go
// freelist.go:78-84
// Reset initial page if this is not contiguous.
if previd == 0 || id-previd != 1 { initial = id }
// If we found a contiguous block then remove it and return it.
if (id-initial)+1 == pgid(n) {
    if (i + 1) == n { f.ids = f.ids[i+1:] } else {
        copy(f.ids[i-n+1:], f.ids[i+1:]); f.ids = f.ids[:len(f.ids)-n] }
```

释放进 pending、随读事务退出而 release 合并回 ids、回滚则从 pending/cache 删除(freelist.go:111-155)。release 的合并时机由 `beginRWTx` 驱动:每次开写事务时取所有存活读事务的最小 txid,把 `minid-1` 及更早的 pending 全部转正(db.go:530-539):

```go
// db.go:531-539
var minid txid = 0xFFFFFFFFFFFFFFFF
for _, t := range db.txs {
    if t.meta.txid < minid { minid = t.meta.txid }
}
if minid > 0 {
    db.freelist.release(minid - 1)
}
```

**重建与写回**:打开库时 `freelist.read(db.page(db.meta().freelist))` 从文件初始化,若页头 `count==0xFFFF` 则真实数量存在第一个 pgid 元素里(freelist.go:163-186);每次 commit 都把旧 freelist 页 free 掉、重新分配一页并把 ids+pending 排序合并全量写回——**pending 也落盘**,因为崩溃后它们必成空闲(tx.go:174-186,freelist.go:56-63, 191-212)。count≥0xFFFF 时同样把真实计数藏进首元素(freelist.go:199-209)。读事务结束后 `rollback`→`reload` 重读并过滤掉仍被 pending 占用的页(freelist.go:215-239,tx.go:249-258)。

## 六、pagesize 判定与 Init

页大小不是硬编码 4096:默认取 OS 页大小 `os.Getpagesize()`(db.go:40, 345);打开**已存在**文件时,先读前 0x1000 字节验 meta,有效则 `db.pageSize = int(m.pageSize)`,无效才回退 OS 页大小(db.go:202-219):

```go
// db.go:204-218(节选)
var buf [0x1000]byte
if _, err := db.file.ReadAt(buf[:], 0); err == nil {
    m := db.pageInBuffer(buf[:], 0).meta()
    if err := m.validate(); err != nil {
        db.pageSize = os.Getpagesize()   // 无法读到页大小时的兜底
    } else {
        db.pageSize = int(m.pageSize)    // 以文件自述的页大小为准
    }
}
```

新建文件的 `init()` 一次写出 4 页(db.go:343-387):

```go
// db.go:348-377(节选)
buf := make([]byte, db.pageSize*4)
for i := 0; i < 2; i++ {           // p0/p1: 双 meta,txid=0/1
    m.magic = magic; m.version = version; m.pageSize = uint32(db.pageSize)
    m.freelist = 2                 // freelist 固定从页 2 开始
    m.root = bucket{root: 3}       // 根 bucket 根页 = 页 3
    m.pgid = 4                     // 高水位 = 4 页
    m.txid = txid(i); m.checksum = m.sum64()
}
p.flags = freelistPageFlag; p.count = 0   // p2: 空 freelist
p.flags = leafPageFlag;     p.count = 0   // p3: 空根叶页
```

即最小合法文件为 4 页,且**空 freelist 页从建库起就存在于文件中**(db.go:366-370)。写盘顺序是"数据页 fdatasync → 再写 meta"(tx.go:520-524, 221-224),保证 meta 有效时数据已在盘上。

## 七、文件布局 ASCII 图与设计动机

一个含 2 个 bucket(a、b)、各带 2 个 key 的小库(4KB 页,多次提交后)逐页示意:

```
文件偏移   页   类型      内容
0x0000   p0  meta     magic=0xED0CDAED ver=2 pagesize=4096
                      root={3,seq} freelist=2 pgid=6 txid=偶 cksum=FNV1a64(前56B)
0x1000   p1  meta     上一份快照(txid 奇偶交替,db.go:1008)
0x2000   p2  freelist [hdr16B|count=k|k x 8B 排序 pgid(ids+pending 全量)]
0x3000   p3  branch   根 bucket:("a"->子bucket值{root:4,seq}) ("b"->{root:5,seq})
                        (元素16B×2,值=16B bucket 头内联;bucket.go:68-72,615-628)
0x4000   p4  leaf     bucket a 根页:
                      [hdr16|elem0 flags|pos|ksize|vsize|elem1 ...|k0|v0|k1|v1]
                      (pos = 数据区起点 - &elem[i];数据区紧随元素数组)
0x5000   p5  leaf     bucket b 根页(同构)
        p6  overflow (仅当某 value 撑爆页时,p4 头部 overflow=1 指向它)
```

leaf/branch 页内部通式:`[16B 页头][count × 16B 元素][key/value 数据区]`,元素数组从 `page.ptr` 起,数据区从元素数组末尾起顺序排(node.go:210-243)。

设计动机(源码依据):
1. **零拷贝读**:mmap 只读映射 + 指针 cast,读路径无反序列化、无缓冲区复制(bolt_unix.go:47,db.go:792-795)。
2. **pos 相对偏移**:元素与数据的相对布局固定,页数据可放在任意地址直接 cast,不需重定位(page.go:118-127,node.go:217)。
3. **双 meta 交替 + 校验和**:txid 奇偶决定写 p0/p1,崩溃后总能回退到上一份一致快照(db.go:1007-1009,803-824)。
4. **freelist 全量重写而非增量日志**:页级写放大换来格式极简,单文件无 WAL(db.go:176-186 的 Commit 每次重写 freelist 页,tx.go:174-186)。
5. **pending 按 txid 分组**:已删页在所有可能引用它的读事务退出前不可复用,支持 MVCC 长读(freelist.go:13, 131-144,db.go:530-539)。
6. **小 bucket 内联**:≤pageSize/4 且无子 bucket 的 bucket,整个作为父页一个 value 存储,省页数(bucket.go:584-612)。
7. **页大小跟 OS 页对齐**:与内核 page cache 单位一致,减少写放大(db.go:40, 345)。

## 八、纠偏记录(以本 commit 源码为准)

1. **页头是 16 字节**,不是常见误传的 8/12;且它是由 `unsafe.Offsetof(page.ptr)` 在运行期(编译期常量表达式)算出的,`ptr` 本身一个字节都不落盘(page.go:10, 30-36)。
2. **freelist 页总是存在于文件中**:建库即写空 freelist 页(page 2),此后每次 commit 释放旧页、分配新页全量重写;打开时无条件从 `meta.freelist` 读入(db.go:366-370;tx.go:174-186;db.go:236-237)。"freelist 可选/可不存在"是错的。
3. **没有任何 binary 序列化**:非测试库代码 0 处 encoding/binary(grep 核实);文件字节 = Go struct 内存原样,端序即宿主端序(tx.go:500,bolt_unix.go:47)。
4. **校验算法是 FNV-1a 64** 而非 CRC32/xxhash,且只覆盖 meta 前 56 字节;`checksum==0` 时完全跳过校验(db.go:988, 1018-1022)。数据页没有任何校验。
5. **"4KB 页"不是常量**:是 `os.Getpagesize()`,旧库以 meta.pageSize 为准,64KB 页的 OS 上会建出 64KB 页的库(db.go:40, 345, 204-218)。
6. **overflow 是页级计数而非 value 级链表**:页头一个 uint32,释放时按区间展开,不存在"下一个溢出页号"字段(page.go:34;freelist.go:118)。
7. **key/value 不内联在元素内**:集中排在元素数组之后,`pos` 是相对元素自身地址的偏移——这就是所谓 bptr 偏移技巧(page.go:118-127;node.go:217, 239-242)。

## FAQ 候选

1. 为什么有两份 meta 页?——txid 奇偶交替写 p0/p1,一份写坏用另一份回退,实现崩溃原子切换(db.go:1008, 815-819)。
2. `page.ptr` 会写进文件吗?——不会,它只是标记页头结束/元数据区起点的占位字段,页头大小即其偏移 16B(page.go:10, 35)。
3. freelist 页 count=0xFFFF 是什么意思?——表示真实条数存到数据区第一个 pgid 里,突破 16 位计数上限(freelist.go:166-170, 205-209)。
4. 页内元素为什么写成 `[0x7FFFFFF]T` 数组?——这只是 Go 做指针运算的语法,把 ptr 后内存当巨型数组切片,零实际分配(page.go:59)。
5. 一个 value 比一页大怎么办?——spill 按 node.size() 一次性分配连续多页,页头 overflow 记录额外页数,node 不拆(node.go:368;page.go:34)。
6. key/value 的最大长度是多少?——MaxKeySize=32768、MaxValueSize=(1<<31)-2(bucket.go:11-15)。
7. 读一个 key 需要几次页访问?——从 meta.root 开始逐层读 branch 页到 leaf 页,全程在 mmap 上取地址,零拷贝(db.go:792-795)。
8. 数据页有校验和吗?——没有,校验只保护 meta 56 字节;数据完整性靠"先写数据后写 meta"的顺序与 fdatasync(tx.go:198-224)。
9. 空库文件为什么是 4 页?——init 依次写 meta0、meta1、空 freelist 页、空根叶页(db.go:348-377)。
10. 文件能跨大小端机器使用吗?——格式就是宿主端序原始内存,代码无任何字节序转换,跨端序读取未在代码层处理(全仓 grep 核实;兼容性未核实)。

## 深挖方向

1. bbolt 后续把 freelist.allocate 从本版 O(n) 首适应改为 hint/hash 分配器,可对比本 commit 衡量收益(freelist.go:67-107)。
2. Windows 路径:bolt_windows.go 的 mmap/munmap 与 `grow()` 里跳过 Truncate 的分支(db.go:875-884),平台差异如何影响文件布局可靠性。
3. 端序与可移植性:s390x(bolt_s390x.go,brokenUnaligned 相关)上生成文件在 x86 上的读取行为,验证"无字节序层"的实际后果。
4. `Tx.Page()`/`freelist.freed` 如何把"free"作为第 5 种页类型暴露给 `cmd/bolt info`,以及 tx.go:601-624 的实现边界。
5. mmap 尺寸策略(32KB 倍增、1GB 步进,db.go:308-340)与读事务阻塞的相互作用(InitialMmapSize 的适用场景,db.go:911-919)。

## 正文蒸馏要点

1. 页固定四字段头部共 16 字节,由 `unsafe.Offsetof(page.ptr)` 求得;`ptr` 不落盘(page.go:10, 30-36)。
2. 四种页类型用 flags 位区分:branch 0x01 / leaf 0x02 / meta 0x04 / freelist 0x10;元素级 bucketLeafFlag 0x01 标记子 bucket(page.go:17-26)。
3. 分支/叶子元素均为 16 字节定长;leaf 元素多 flags/vsize,branch 元素以 8 字节 pgid 直指子页(page.go:97-115)。
4. key/value 存在页尾数据区,元素里只存"相对自身地址"的 pos 偏移,取值零拷贝(page.go:118-127;node.go:217)。
5. 全库无 encoding/binary:文件即 Go struct 原始内存,写靠 WriteAt、读靠只读 mmap,端序为宿主端序(tx.go:500;bolt_unix.go:47;grep 核实)。
6. meta 64 字节含 magic 0xED0CDAED、version=2、pageSize、根 bucket、freelist 页号、高水位 pgid、txid;校验为 FNV-1a64、仅前 56 字节、0 值跳过(db.go:21, 24, 970-992, 1018-1022)。
7. 双 meta 按 txid 奇偶交替写 p0/p1,读端取 txid 高且校验通过者,坏则回退另一份(db.go:1007-1009, 803-824)。
8. overflow 是页级 uint32 计数,表示紧随的连续页数;分配置位(db.go:836)、释放区间展开(freelist.go:118)、落盘按 (overflow+1)×pageSize 写(tx.go:486)。
9. freelist 三件套 ids/pending/cache:首适应找连续段,pending 按 txid 分组延迟到读事务退出后 release 回 ids(freelist.go:11-15, 67-107, 131-144)。
10. freelist 页恒存在于文件:建库写空页(page 2),每次 commit 释放旧页重写新页(ids+pending 排序合并全量),count≥0xFFFF 时真实计数藏入首元素(db.go:366-370;tx.go:174-186;freelist.go:166-170, 199-209)。
11. 页大小默认 os.Getpagesize(),旧库以 meta.pageSize 为准,校验失败才回退 OS 值;init 一次写 4 页:meta0/meta1/空 freelist/空根叶(db.go:40, 204-218, 345-377)。
12. 提交顺序:数据页写盘并 fdatasync 之后才写 meta 页,这是"meta 有效即数据一致"的全部保障(tx.go:196-224)。
