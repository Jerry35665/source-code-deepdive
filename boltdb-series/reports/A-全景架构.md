# 报告 A · 全景架构(BoltDB)

> 基线:fd01fc79c553a8e99d512a07e8e0c63d4a3ccfc5(boltdb/bolt master,已归档)。一句话总结:BoltDB 是一个纯 Go、单文件、只读 mmap + B+tree 的嵌入式 KV 存储,采用"单写者 + 多读者 MVCC 快照"模型——读路径零拷贝直指 mmap,写路径在堆上做 CoW 脏页并在 commit 末尾以 meta 页奇偶翻转原子生效,全程无 WAL、无后台线程。

---

## 1. 文件全景与阅读地图

核心代码约 3,953 行(不含测试,`wc -l *.go` 实测):db.go 1037 行、bucket.go 777 行、tx.go 686 行、node.go 604 行、cursor.go 400 行、page.go 197 行、freelist.go 252 行;平台适配另有约 470 行、散落在 13 个小文件中。平台适配散落在 13 个小文件中。四类核心对象的关系:`DB` 持有 mmap 与锁(`db.go:97-121`);`Tx` 持有 meta 快照与根 Bucket(`tx.go:24-41`);`Bucket` 递归嵌套(`bucket.go:36-59`);`Cursor` 沿页/node 栈遍历(`cursor.go:18-21`)。

```go
// db.go:97-121  DB 的私有状态(节选)
path     string
file     *os.File
lockfile *os.File // windows only
dataref  []byte   // mmap'ed readonly, write throws SEGV
data     *[maxMapSize]byte
datasz   int
filesz   int // current on disk file size
meta0    *meta
meta1    *meta
rwtx     *Tx
txs      []*Tx
freelist *freelist
rwlock   sync.Mutex   // Allows only one writer at a time.
mmaplock sync.RWMutex // Protects mmap access during remapping.
```

## 2. 平台层:锁、mmap、fdatasync 的系统调用差异

**锁**。Unix 用 `syscall.Flock`,`LOCK_SH|LOCK_NB` 或 `LOCK_EX|LOCK_NB`,失败(EWOULDBLOCK)后每 50ms 重试直至超时返回 ErrTimeout(`bolt_unix.go:14-40`)。Solaris 例外,用 POSIX `fcntl(F_SETLK)` 记录锁而非 flock(`bolt_unix_solaris.go:14-45`)。**Windows 最特殊**:注释明言"进程无法在同一文件上共享独占锁(WriteTo 需要)",因此对 `db.path+".lock"` 这个独立文件调 `LockFileEx`(`bolt_windows.go:51-59`),funlock 时删掉 .lock 文件(`bolt_windows.go:89-94`)。

```go
// bolt_windows.go:51-59  Windows 必须另立 .lock 文件
func flock(db *DB, mode os.FileMode, exclusive bool, timeout time.Duration) error {
	// Create a separate lock file on windows because a process
	// cannot share an exclusive lock on the same file. This is
	// needed during Tx.WriteTo().
	f, err := os.OpenFile(db.path+lockExt, os.O_CREATE, mode)
	if err != nil {
		return err
	}
	db.lockfile = f
```


**mmap**。Unix:`syscall.Mmap(fd, 0, sz, PROT_READ, MAP_SHARED|db.MmapFlags)` 后 `madvise(MADV_RANDOM)`(`bolt_unix.go:48-65`)。Windows:`CreateFileMapping(PAGE_READONLY)` + `MapViewOfFile(FILE_MAP_READ)`,且非只读打开时先 `Truncate` 到 mmap 大小(`bolt_windows.go:98-130`)——所以 `db.grow` 里 Windows 分支反而跳过 Truncate(`db.go:875-880`),截断职责被挪到了 mmap 内。所有平台的映射都是只读保护,写 mmap 直接 SEGV(`db.go:100` 注释)。

**fdatasync 与 OpenBSD 特例**。Linux 直接 `syscall.Fdatasync`(`bolt_linux.go:8-10`);OpenBSD 没有 unified buffer cache,`fdatasync` 退化为对映射区 `msync(MS_INVALIDATE)`(`bolt_openbsd.go:14-27`),并因此有包级常量 `IgnoreNoSync = runtime.GOOS == "openbsd"`——OpenBSD 上 NoSync 被强制忽略(`db.go:26-30`)。其余非 Windows/非 Linux/非 OpenBSD 平台(如 darwin)的 `fdatasync` 就是 `file.Sync()`(`boltsync_unix.go:6-8`)。

**架构差异**。`maxMapSize`(允许的最大映射)32 位平台为 2GB:`bolt_386.go:4`、`bolt_arm.go:6`、`bolt_ppc.go:6`;64 位为 256TB:`bolt_amd64.go:4`、`bolt_arm64.go:6`、`bolt_ppc64.go:6`、`bolt_ppc64le.go:6`、`bolt_s390x.go:6`。ARM(32 位)在 init 时做一次非对齐访问探测得到 `brokenUnaligned`(`bolt_arm.go:14-28`),该标志用于 `openBucket` 中值指针未对齐时先克隆再解引用(`bucket.go:135-139`)。

## 3. db.go:Open() 完整路径

`Open()` 流程(`db.go:150-241`):①按 ReadOnly 决定 `O_RDWR`/`O_RDONLY` 并 `O_CREATE` 打开文件(`db.go:165-174`);②`flock`:读写模式独占锁、只读模式共享锁(`db.go:186-189`,注释解释了独占锁防两进程各自写 meta/freelist 导致损坏);③若文件为空则 `init()` 写入 4 个初始页(`db.go:197-201`);否则读文件头 0x1000 字节探测 pageSize,第一 meta 页校验失败则退回 OS 页大小(`db.go:204-219`);④建 pagePool(`db.go:223-227`);⑤`db.mmap(options.InitialMmapSize)`(`db.go:230`);⑥**直接从 mmap 读 freelist**:`db.freelist.read(db.page(db.meta().freelist))`(`db.go:236-237`)。

注意:本 commit 的 Open() **没有**"启动读事务预热"这一步——它只调用 `db.meta()`(选有效 meta)和 `db.page(freelist)`,不经过 `beginTx`。"Open 会预热一个读 tx"的说法在本源码中不成立。`init()` 写入的初始布局:page0=meta0(txid 0)、page1=meta1(txid 1)、page2=空 freelist 页、page3=空 leaf 页(即根 bucket),meta 里 `root=bucket{root:3}`、`pgid=4`(`db.go:343-387`)。

mmap 大小策略:`mmapSize` 从 32KB 起倍增到 1GB,超过 1GB 后按 1GB 步进并对齐页大小(`db.go:308-340`)。remap 前先对 rwtx 的根 node 做 `dereference()` 防止悬挂指针(`db.go:266-269`),映射完成后保存 meta0/meta1 并 validate:**只有两份都失败才报错**,一份坏可用另一份恢复(`db.go:282-292`)。

```go
// db.go:282-292  meta 双份容错
db.meta0 = db.page(0).meta()
db.meta1 = db.page(1).meta()
// Validate the meta pages. We only return an error if both meta pages fail
// validation, since meta0 failing validation means that it wasn't saved
// properly -- but we can recover using meta1. And vice-versa.
err0 := db.meta0.validate()
err1 := db.meta1.validate()
if err0 != nil && err1 != nil {
    return err0
}
```

## 4. 事务双通道与 meta 双份校验(txid 奇偶)

**读通道 `beginTx`**(`db.go:466-502`):先 `metalock.Lock` 再 `mmaplock.RLock`(注释强调这是写事务也会采用的加锁顺序,防死锁),把 tx 挂进 `db.txs` 切片后即释放 metalock;读 tx 的"快照"只是拷贝一份 64 字节的 meta 结构(`tx.go:49-50`,字段见 `db.go:970-981`),它持有 mmaplock 读锁直到 Close/removeTx(`db.go:475,547`),从而阻止 remap。**写通道 `beginRWTx`**(`db.go:504-542`):先抢全局写者互斥 `rwlock.Lock`(每库仅一个写事务),再 metalock 下设 `db.rwtx = t`;然后扫描所有存活读 tx 取最小 txid,调 `freelist.release(minid-1)` 把不再被任何读事务引用的 pending 页转为可分配(`db.go:530-539`)。写事务 `init` 时把快照 txid 加一(`tx.go:58-61`),这就是"未来"的 txid。

meta 选择与落盘:`db.meta()` 取 txid 较大的一份,validate 通过即返回,否则回退另一份,两份都坏则 panic(`db.go:803-824`)。写入哪一页由 txid 奇偶决定:

```go
// db.go:1000-1015  meta.write:页号 = txid % 2,写前算校验和
func (m *meta) write(p *page) {
    if m.root.root >= m.pgid {
        panic(fmt.Sprintf("root bucket pgid (%d) above high water mark (%d)", m.root.root, m.pgid))
    } else if m.freelist >= m.pgid {
        panic(fmt.Sprintf("freelist pgid (%d) above high water mark (%d)", m.freelist, m.pgid))
    }
    // Page id is either going to be 0 or 1 which we can determine by the transaction ID.
    p.id = pgid(m.txid % 2)
    p.flags |= metaPageFlag
    // Calculate the checksum.
    m.checksum = m.sum64()
    m.copy(p.meta())
}
```

校验和为 FNV-64a,覆盖 checksum 字段之前的全部 meta 字节(`db.go:1018-1022`);`validate` 检查 magic 0xED0CDAED、version 2、checksum 三项(`db.go:983-992`)。这套"双 meta + 奇偶翻转 + 校验和"就是无 WAL 的崩溃安全来源:commit 未走到写 meta 那一步,旧 meta 依然完整有效(`doc.go:8-11`)。

## 5. tx.go:ro/rw 结构与 commit 主流程骨架

`Tx` 结构统一表示两种事务,靠 `writable` 区分;`pages map[pgid]*page` 是写事务的脏页缓存(`tx.go:24-41`)。`tx.page(id)` 先查脏页缓存、未命中才读 mmap(`tx.go:571-581`)——读写两侧对页的统一抽象。托管事务 `Update`/`View` 里禁止手动 Commit/Rollback(panic,`db.go:581-641`);注意 `View` 结束时执行的是 `t.Rollback()`(`db.go:636`),读事务从不 commit。读事务的"快照"成本极低,只是一次 meta 结构拷贝:

```go
// tx.go:44-62  tx.init:快照 = 拷贝 meta;写事务 txid 先自增
func (tx *Tx) init(db *DB) {
	tx.db = db
	tx.pages = nil
	// Copy the meta page since it can be changed by the writer.
	tx.meta = &meta{}
	db.meta().copy(tx.meta)
	// Copy over the root bucket.
	tx.root = newBucket(tx)
	tx.root.bucket = &bucket{}
	*tx.root.bucket = tx.meta.root
	// Increment the transaction id and add a page cache for writable transactions.
	if tx.writable {
		tx.pages = make(map[pgid]*page)
		tx.meta.txid += txid(1)
	}
}
```


**Commit 主流程骨架**(`tx.go:144-236`,细节留待后续章):
1. `tx.root.rebalance()`——删除后重平衡(`tx.go:156`);
2. `tx.root.spill()`——把 node 溢写为脏页并做页分裂(`tx.go:163`);
3. 释放旧 freelist 页、分配并重写新 freelist 页,更新 `meta.freelist`(`tx.go:176-186`);
4. 高水位上涨则 `db.grow`(Truncate+Sync,Windows 除外)(`tx.go:189-194`,`db.go:859-888`);
5. `tx.write()`——脏页按 pgid 排序顺序 WriteAt,随后 `fdatasync`(`tx.go:198,474-524`);
6. StrictMode 下跑 `Check()` 一致性校验(`tx.go:205-218`);
7. `tx.writeMeta()`——把 meta 写到 page[txid%2] 并**再次** `fdatasync`(`tx.go:221,547-567`);
8. `tx.close()` 释放 rwlock,执行 `OnCommit` 回调(`tx.go:228-233`)。

因此一次成功 commit 至少两次 fdatasync(数据页一次、meta 一次;`tx.go:520-524,557-561`),开启 NoSync 可全部跳过(OpenBSD 上被 IgnoreNoSync 强制恢复)。rollback 时写事务调 `freelist.rollback` 清 pending 再 `reload` 从盘重读(`tx.go:249-258`)。

## 6. bucket.go:bucket 树、根页号与子 bucket 存储

bucket 的磁盘表示只有 16 字节:`{root pgid, sequence uint64}`(`bucket.go:56-59`)。**bucket 树的关键设计:子 bucket 以"值"的形式存在父 bucket 的 B+tree 叶子里**——父叶子的一个元素若带 `bucketLeafFlag(0x01)`(`page.go:24-26`),其 value 就是这 16 字节头;`root` 指向子 bucket 自己的 B+tree 根页。读事务打开子 bucket 时**零拷贝**:直接把 value 的字节指针解释为 `*bucket`(`bucket.go:143-148`);写事务才复制一份。`root == 0` 表示 inline bucket:整棵子树(一个 leaf 页)紧凑排在 16 字节头之后,由父页承载(`bucket.go:53-55` 注释、`151-153`);inline 上限是 `pageSize/4` 且不得含子 bucket(`bucket.go:586-613`)。`CreateBucket` 一律先创建 inline 空桶(`bucket.go:182-192`);`Bucket.Get` 对 bucket 型 key 返回 nil(`bucket.go:270-272`),Cursor 对其返回 nil value(`cursor.go:10,44-48`)。commit 时 `Bucket.spill` 先递归处理子桶:inlineable 的子桶释放页、整体内联回父节点;否则把子桶新根页号写回父元素(`bucket.go:526-582`)。key 上限 32768 字节、value 上限 2^31-2(`page.go:11-14`)。

```go
// bucket.go:130-156  openBucket:ro 事务零拷贝指向 mmap(节选)
// If this is a writable transaction then we need to copy the bucket entry.
// Read-only transactions can point directly at the mmap entry.
if b.tx.writable && !unaligned {
    child.bucket = &bucket{}
    *child.bucket = *(*bucket)(unsafe.Pointer(&value[0]))
} else {
    child.bucket = (*bucket)(unsafe.Pointer(&value[0]))
}
// Save a reference to the inline page if the bucket is inline.
if child.root == 0 {
    child.page = (*page)(unsafe.Pointer(&value[bucketHeaderSize]))
}
```

## 7. 单文件磁盘布局总图

```go
// page.go:17-36  页头与四种页类型
const (
    branchPageFlag   = 0x01
    leafPageFlag     = 0x02
    metaPageFlag     = 0x04
    freelistPageFlag = 0x10
)
type page struct {
    id       pgid
    flags    uint16
    count    uint16
    overflow uint32   // 本逻辑页后面连续跟随的额外物理页数
    ptr      uintptr  // 元素区起点(pageHeaderSize = offsetof ptr)
}
```

```
            bolt.db 单文件布局(初始 4 页由 init() 写出,db.go:343-387)
 offset
   0 ┌────────────────────────────────────┐
     │ page 0 · META0   flags=0x04 txid=0 │  magic 0xED0CDAED / version 2
     │   root.root=3, freelist=2, pgid=4  │◄─┐  db.meta():取 txid 较大且
pgsz ├────────────────────────────────────┤  │  validate 通过的一份;
     │ page 1 · META1   flags=0x04 txid=1 │  │  两份都坏才打不开
     │   (与 META0 同构,按 txid%2 交替)─┘  │  (db.go:282-292,803-824,1008)
     ├────────────────────────────────────┤
     │ page 2 · FREELIST  flags=0x10      │  count(或 0xFFFF 外置计数)
     │   紧排 []pgid(空闲页号,有序)    │  每 commit 整页重写
     ├────────────────────────────────────┤   tx.go:176-186, freelist.go:191-212
     │ page 3 · LEAF(根 bucket 的根页) │  bucketLeafFlag 元素 →
     │   key | value(16B bucket 头)    │  子 bucket 根页号 / inline 子树
     ├────────────────────────────────────┤
     │ page 4..N · B+tree branch / leaf   │  branch 元素仅 pos+ksize+pgid
     │   (大值可 overflow 连续占多页)   │  leaf 元素 pos+ksize+vsize(+flags)
     ├────────────────────────────────────┤   page.go:97-115
     │  ...未分配空洞(freelist 可复用) │
     ├────────────────────────────────────┤
     │ meta.pgid 高水位之后的文件尾部     │  写满时 allocate 追加 + remap
     └────────────────────────────────────┘  db.go:827-856,859-888
  读路径: 用户代码 ──PROT_READ mmap──► 页直接指针引用(零拷贝,勿改,事务内有效)
  写路径: 堆上 node/dirty page ──commit──► WriteAt 新位置 ──fdatasync──► 翻转 meta 页
```

freelist 是普通页,持久化在盘上:Open 时整页读入内存(`db.go:236-237`,`freelist.go:163-186`);内存中分 `ids`(可立即分配)与 `pending`(按 txid 分组、仍被老读事务引用)(`freelist.go:11-15`);分配是"首个连续 N 页"的 first-fit 扫描(`freelist.go:67-107`);**pending 页也会随 commit 写进盘上的 freelist 页**——崩溃后它们天然变回空闲页(`freelist.go:188-190` 注释)。count 超过 0xFFFF 时把真实数量存在第一个元素位(`freelist.go:26-33,199-209`)。

## 8. 定位差异、设计动机与纠偏

**与 SQLite / LSM 的定位差异(通识,未核实源码)**:SQLite 同为 B-tree 单写多读(其 WAL 模式),但面向通用 SQL、有 journal/WAL 与页缓存等完整栈;BoltDB 只提供有序 KV,btree 页即磁盘格式、mmap 即页缓存,无 WAL、无重放恢复,用"双 meta 翻转"替代 checkpoint。LSM(Ldb/Rdb)写优化——顺序写 + compaction,读有放大;BoltDB 读优化——就地有序页 + mmap 随机读,代价是写放大:每次 commit 重写脏路径整条分支、freelist 页并做两次 fsync(`tx.go:156-221`),且空间回收依赖读事务全部退出(`db.go:530-539`)。因此它适合读多写少、单机嵌入、数据量小于内存/可整体映射的场景。

**设计动机(以源码注释为证)**:
1. 纯 Go、单文件、可完全序列化的事务,替代"重型依赖"(`doc.go:1-6`);
2. 设计蓝本是 LMDB(`doc.go:13`);读优化、零拷贝 B+tree(`doc.go:8-9`);
3. 只读 mmap 让应用层"不可能写坏数据库",越界写直接 panic(`doc.go:33-36`,`db.go:100`);
4. 无恢复逻辑:没 commit 完的事务崩溃后自然回滚(`doc.go:9-11`),靠双 meta 校验实现;
5. 写时复制 + 快照:读事务只是拷贝一份 meta(`tx.go:49-50`),读者永不见半成品写;
6. 全局单写者简化并发推理到"一把 rwlock"(`db.go:118,512`);
7. allocate 复用 pagePool、按 16MB 批量扩容以摊薄 truncate/fsync 成本(`db.go:36,113,830-834,92-95`)。

```go
// db.go:26-30  OpenBSD 无统一缓冲缓存(UBC),NoSync 在该平台被强制忽略
const IgnoreNoSync = runtime.GOOS == "openbsd"

// freelist.go:188-190  pending 页同样落盘:崩溃后自然变回空闲页
// write writes the page ids onto a freelist page. All free and pending ids are
// saved to disk since in the event of a program crash, all pending ids will
// become free.
```

**纠偏(与流行说法相反,以本 commit 为准)**:
1. **"Bolt 是零拷贝,所以写也直接改 mmap"——错**。映射为 PROT_READ,写映射区即 SEGV(`bolt_unix.go:50`,`db.go:100`);写事务在堆上分配脏页(`db.go:829-835`)、commit 时 `WriteAt` 追加/覆写到新位置(`tx.go:474-517`),旧页原样保留给读事务。
2. **"freelist 每次打开都全库扫描重建"——错**。freelist 是持久化页,Open 直接读入(`db.go:236-237`);每 commit 仅重写这一页(`tx.go:176-186`)。真正"重建"只发生在写事务 rollback 的 reload(`tx.go:255`)。
3. **"meta 页校验失败数据库就打不开"——错**。单份损坏可由另一份恢复,仅两份同时 validate 失败才报错(`db.go:288-292`);运行期 `db.meta()` 永远挑 txid 更高的有效份(`db.go:803-824`)。
4. **"Open() 会起一个读事务预热"——本 commit 无此动作**:Open 只读 meta 与 freelist 页,不创建任何 Tx(`db.go:230-240`)。
5. **"一次 commit 只 fsync 一次"——实际两次**:脏页后一次(`tx.go:520-524`)、meta 后一次(`tx.go:557-561`);文件增长时另有 `file.Sync`(`db.go:881-883`)。
6. **"读事务会一直阻塞写事务"——不准确**:读 tx 持 mmaplock.RLock,只在 mmap 需要 remap(文件增长跨过 datasz)时才挡住写者(`db.go:245-247,475`);`InitialMmapSize` 足够大即可避免(`db.go:451-455,911-919`)。
7. 小观察:`Options.Timeout` 注释称仅 Darwin/Linux 支持(`db.go:896-899`),但 unix/windows/solaris 三个 flock 实现其实都带 50ms 重试超时逻辑(`bolt_unix.go:21-23`,`bolt_windows.go:61-69`,`bolt_unix_solaris.go:19-23`)。

## 9. FAQ 候选

1. 为什么 Get 返回的 []byte 不能存到事务外?——它指向 mmap,事务结束或 remap 后指针失效(`doc.go:38-40`,`db.go:266-269`)。
2. 为什么同一进程/进程间同时只能有一个写事务?——`rwlock` 全局互斥,写事务串行化(`db.go:118,512`)。
3. 本次写 meta0 还是 meta1 由什么决定?——`p.id = txid % 2`,奇偶交替(`db.go:1008`)。
4. 进程崩溃会损坏数据吗?——不会,未写 meta 则旧 meta 校验仍通过,等价自动回滚(`doc.go:9-11`,`db.go:282-292`)。
5. freelist 从哪来,会丢吗?——盘上持久化页,Open 读入,每 commit 重写(`db.go:236-237`,`tx.go:176-186`)。
6. 被老读事务占着的页何时能复用?——下个写事务开始时 `release(minid-1)`(`db.go:530-539`)。
7. 很小的 bucket 也占一整页吗?——不,inline bucket 塞进父桶 value,阈值 pageSize/4(`bucket.go:611-613`)。
8. 为什么读事务长期不关库文件会膨胀?——pending 页不能回收,写者只能往上追加新页(`tx.go:20-23`,`db.go:530-539`)。
9. 数据库文件何时真正变大?——freelist 不够且写到高水位时 remap+grow(Truncate+Sync)(`db.go:844-856,859-888`)。
10. mmap 一次映射多大?——从 32KB 倍增到 1GB,再按 1GB 步进,上限 maxMapSize(`db.go:308-340`,`bolt_amd64.go:4`)。

## 10. 深挖方向(后续章)

1. node.go 的 `spill/split/rebalance` 全流程与 FillPercent=0.5 的分裂阈值(`node.go:250-409`)。
2. cursor.go 的页/node 双栈遍历与 seek 语义(`cursor.go:154-330`)。
3. freelist first-fit 连续分配的碎片化行为与 0xFFFF 外置计数边界(`freelist.go:67-107,199-209`)。
4. mmap remap 与 `dereference` 的悬垂指针防御(旧映射上还有无存活引用)(`db.go:266-279`)。
5. Batch 合并提交的状态机与失败重试(solo 重跑)语义(`db.go:660-744`)。
6. `Tx.Check()` 三类校验(双重释放/多重引用/不可达未释放页)的算法(`tx.go:383-454`)。

## 正文蒸馏要点

正文必须保留的核心论断(均已核实行号):

1. BoltDB 用 PROT_READ 只读 mmap 承载全部读路径,数据零拷贝、返回字节直指映射区;写路径完全绕开 mmap,在堆上做 CoW 脏页(`bolt_unix.go:48-65`,`db.go:100`,`tx.go:474-517`)。
2. 并发模型是全局单写者(rwlock)+ 多读者(txs 切片 + mmaplock.RLock 快照),锁顺序统一为 metalock → mmaplock(`db.go:118-121,466-502,504-542`)。
3. 崩溃安全不靠 WAL,靠双 meta 页 + txid 奇偶交替写入 + FNV-64a 校验和;单份 meta 损坏可恢复,两份同时坏才不可打开(`db.go:282-292,803-824,1000-1022`)。
4. 一次 commit 的骨架:rebalance → spill → 重写 freelist 页 → grow → 脏页 WriteAt → fdatasync → writeMeta → fdatasync,共两次 fdatasync(`tx.go:144-236,520-524,557-561`)。
5. Open 的关键序:开文件 → flock(读写独占/只读共享)→ 空文件 init 4 页 → 首页探测 pageSize → mmap → 直接读 freelist;**没有**读事务预热步骤(`db.go:150-241`)。
6. 磁盘布局固定为:page0/1 双 meta → page2 起 freelist 页 → 根 bucket 的 B+tree 页;初始 4 页由 init 写死(`db.go:343-387`)。
7. bucket 是递归 B+tree:子 bucket 以 16 字节 `{root,sequence}` 头作为父叶子元素的 value,`root==0` 表示 inline(整树内联在 value 里,阈值 pageSize/4)(`bucket.go:56-59,151-153,586-613`)。
8. 页类型四种(branch 0x01/leaf 0x02/meta 0x04/freelist 0x10),branch 元素只存 pos+ksize+pgid,所有真实数据都在叶子(`page.go:17-36,97-115`)。
9. freelist 持久化且内存中分 ids/pending 两级:pending 页随 commit 落盘(崩溃即成空闲),由下个写事务按最小读 txid release(`freelist.go:11-15,188-190`,`db.go:530-539`)。
10. 平台差异三处硬点:Windows 用独立 .lock 文件 + LockFileEx 且 mmap 前 Truncate;OpenBSD 无 UBC 故 IgnoreNoSync 强制 msync;maxMapSize 32 位 2GB/64 位 256TB(`bolt_windows.go:51-59,98-130`,`db.go:26-30`,`bolt_openbsd.go:14-27`,`bolt_386.go:4`,`bolt_amd64.go:4`)。
11. mmap 按 32KB→1GB 倍增、之后 1GB 步进;写满时 allocate 触发 remap,且 remap 前强制 rwtx dereference 防悬挂(`db.go:308-340,827-856,266-269`)。
12. 流行误传澄清:写不是原地改 mmap;freelist 打开时不是重算;meta 单份坏可恢复;commit 是两次 fsync——四条均见第 8 节纠偏。
