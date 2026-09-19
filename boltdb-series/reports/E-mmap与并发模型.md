# 报告 E · mmap 与并发模型(BoltDB)

> 基线:fd01fc79c553a8e99d512a07e8e0c63d4a3ccfc5(master HEAD)。一句话总结:BoltDB 用一把 `mmaplock` RWMutex 把"读事务存活"直接编码为映射的生命周期——读事务全程持读锁,写事务在页分配触及映射尾部时以 `mmaplock` 写锁做 unmap+remap,remap 前先深拷贝写事务节点里指向旧映射的 key/value,防悬挂指针;文件增长(grow)与映射增长(remap)是两条独立管线。

## 1. db.mmap 全流程与 remap 触发点

`db.mmap(minsz)` 是全库唯一的(重)映射入口,第一件事就是拿 `mmaplock` 写锁(db.go:245-247)。全仓 grep 证实 `db.mmap(` 只有 **两个调用点**:Open 时的首次映射(db.go:230)与 `allocate` 尾部的扩容 remap(db.go:847)——**事务提交本身不触发 remap**(commit 里的 `grow` 只改磁盘文件大小,tx.go:188-191)。

```go
// db.go:245-292(节选)
func (db *DB) mmap(minsz int) error {
	db.mmaplock.Lock()
	defer db.mmaplock.Unlock()
	info, err := db.file.Stat()          // 文件必须 >= 2 页
	...
	} else if int(info.Size()) < db.pageSize*2 {
		return fmt.Errorf("file size too small")
	}
	var size = int(info.Size())
	if size < minsz { size = minsz }     // InitialMmapSize 只是下限
	size, err = db.mmapSize(size)
	...
	// Dereference all mmap references before unmapping.
	if db.rwtx != nil { db.rwtx.root.dereference() }
	if err := db.munmap(); err != nil { return err }
	if err := mmap(db, size); err != nil { return err }
	db.meta0 = db.page(0).meta()         // 重新指向"新"映射里的 meta 页
	db.meta1 = db.page(1).meta()
	err0 := db.meta0.validate(); err1 := db.meta1.validate()
	if err0 != nil && err1 != nil { return err0 }  // 双 meta 全败才报错
	return nil
}
```

要点逐条:
- `db.rwtx.root.dereference()`(db.go:267-269):写事务的 node 其 key/value 切片可能直接指向旧映射内的页数据,unmap 后即悬挂;`dereference` 递归把它们深拷贝到堆(node.go:523-545)。读者不会有此问题——锁保证 remap 时无任何读者存活(见 §4)。
- `munmap` 在 unix 上以保存的 `dataref` 切片为句柄并清零 `dataref/data/datasz`(bolt_unix.go:68-80);Windows 版不清零(见 §7 纠偏)。
- remap 完成后 `meta0/meta1` 指针重新落位,且**只有两份 meta 同时校验失败才报错**(db.go:285-292),单份损坏可靠另一份恢复。
- `db.meta()` 每次调用都现场校验并返回 txid 较高且有效的那份(db.go:803-824)。新提交的 meta 能被后续读者看到,依赖的是 MAP_SHARED 只读映射与 `WriteAt` 共享同一份页缓存(机制推断,标准 OS 语义;源码未明说)。

## 2. mmapSize 算法逐行;InitialMmapSize 与 maxMapSize 约束

```go
// db.go:308-340(拆两段)
func (db *DB) mmapSize(size int) (int, error) {
	// Double the size from 32KB until 1GB.
	for i := uint(15); i <= 30; i++ {     // 从 2^15=32KB 起
		if size <= 1<<i { return 1 << i, nil }  // 向上取 2 的幂
	}
	// Verify the requested size is not above the maximum allowed.
	if size > maxMapSize { return 0, fmt.Errorf("mmap too large") }
	// If larger than 1GB then grow by 1GB at a time.
	sz := int64(size)
	if remainder := sz % int64(maxMmapStep); remainder > 0 {
		sz += int64(maxMmapStep) - remainder   // 向上取整到 1GB 倍数
	}
	pageSize := int64(db.pageSize)
	if (sz % pageSize) != 0 { sz = ((sz / pageSize) + 1) * pageSize }
	if sz > maxMapSize { sz = maxMapSize }     // 封顶
	return int(sz), nil
}
```

- 算法:≤1GB 时按 2 的幂从 32KB(2^15,db.go:306 注释)倍增;超过 1GB 后按 `maxMmapStep = 1<<30 = 1GB` 步进(db.go:18、322-325)。倍增循环里的 `1<<30` 与 `maxMmapStep` 是两个独立常量的巧合相等(未核实是否存在历史关联)。
- `maxMapSize` 按架构编译期确定:64 位 256TB(`0xFFFFFFFFFFFF`,bolt_amd64.go:4;arm64/s390x/ppc64 同),32 位 2GB(`0x7FFFFFFF`,bolt_386.go:4;arm/ppc 同)。
- `InitialMmapSize`:文档明确"若小于现有数据库尺寸则无效"(db.go:917-919),在 Open 时作为 `minsz` 传入 db.mmap(db.go:230)。它的全部约束是:①作为 `size` 下限参与 mmapSize(db.go:257-261);②换算后超过 `maxMapSize` 则 Open 直接报 `mmap too large`(db.go:317-319)。官方测试用 `1<<31 = 2GB` 的初值来避免读者卡写者(db_test.go:369-377)。
- **datasz vs filesz**:`datasz` 是 mmap 长度,由平台 mmap 写入(bolt_unix.go:63、bolt_windows.go:127、bolt_unix_solaris.go:73);`filesz` 是当前磁盘文件大小,只在 `grow` 末尾更新(db.go:886)。unix 上允许 `datasz > filesz`(映射可覆盖稀疏区);Windows 的 mmap 会先把文件 Truncate 到映射大小(bolt_windows.go:99-104),两边语义在此分叉。`allocate` 拿 `minsz` 比 `datasz`(db.go:846),`grow` 拿 `sz` 比 `filesz`(db.go:861),互不串门。

## 3. allocate:pagePool 复用、16MB 批量扩容、grow 的 Truncate+Sync

```go
// db.go:827-856(节选)
func (db *DB) allocate(count int) (*page, error) {
	var buf []byte
	if count == 1 {
		buf = db.pagePool.Get().([]byte)   // 单页走 sync.Pool
	} else {
		buf = make([]byte, count*db.pageSize) // 多页不进池
	}
	p := (*page)(unsafe.Pointer(&buf[0]))
	p.overflow = uint32(count - 1)
	if p.id = db.freelist.allocate(count); p.id != 0 {
		return p, nil                       // 优先吃 freelist
	}
	p.id = db.rwtx.meta.pgid                 // freelist 未命中:追加到高水位
	var minsz = int((p.id+pgid(count))+1) * db.pageSize
	if minsz >= db.datasz {
		if err := db.mmap(minsz); err != nil { ... }  // 唯一的运行期 remap 点
	}
	db.rwtx.meta.pgid += pgid(count)
	return p, nil
}
```

- pagePool 是按页大小的 `sync.Pool`(db.go:113、222-227);归还发生在 `tx.write` 写盘之后,且**逐字节清零**再 Put,只回收无溢出的单页(tx.go:522-540)。
- freelist 命中判断与连续块扫描见 freelist.go:67-107;未命中才走高水位追加,注意 **remap 先于 pgid 高水位推进**(db.go:846-853),因此一个写事务期间 `datasz` 可以领先 `filesz`。
- **纠偏:不存在 `db.ops.pendingOps`**。全仓 grep `pendingOps` 为空;`db.ops` 结构体只有 `writeAt` 一个函数指针(db.go:123-125)。题设中的"16MB 批量扩容"实际是 `DefaultAllocSize = 16MB`(db.go:36),在 `grow` 里生效(db.go:867-871),与 `db.ops` 无关。
- `grow` 只被 `tx.Commit` 调用一次(tx.go:188-191),仅当本次事务推高了 `meta.pgid`:

```go
// db.go:859-888(节选)
func (db *DB) grow(sz int) error {
	if sz <= db.filesz { return nil }
	if db.datasz < db.AllocSize { sz = db.datasz } else { sz += db.AllocSize }
	// Truncate and fsync to ensure file size metadata is flushed.
	if !db.NoGrowSync && !db.readOnly {
		if runtime.GOOS != "windows" {          // Windows 免 Truncate
			if err := db.file.Truncate(int64(sz)); err != nil { ... }
		}
		if err := db.file.Sync(); err != nil { ... }
	}
	db.filesz = sz
	return nil
}
```

- Windows 豁免 Truncate 是因为其 `mmap()` 内部已先把文件截到位(bolt_windows.go:99-104),但 **Sync 仍然保留**(db.go:881-883)。issue #284 是这段逻辑的出处注释(db.go:69、874)。

## 4. 锁矩阵、标准加锁顺序与同 goroutine 自我死锁

```go
// db.go:118-121
rwlock   sync.Mutex   // Allows only one writer at a time.
metalock sync.Mutex   // Protects meta page access.
mmaplock sync.RWMutex // Protects mmap access during remapping.
statlock sync.RWMutex // Protects stats access.
```

| 锁 | 加点 | 释点 | 实际保护的临界区 |
|---|---|---|---|
| rwlock | beginRWTx(db.go:512);Close(db.go:392) | tx.close 写分支(tx.go:272) | 全库唯一写事务;写事务整个生命周期 |
| metalock | beginTx(db.go:470)、beginRWTx(db.go:516)、removeTx(db.go:550)、Close(db.go:395) | 各自 defer/显式 Unlock | db.txs 的增删(db.go:489、553-561)、db.rwtx 赋值(db.go:528)——注意 119 行注释"Protects meta page access"并不精确,meta 指针读取靠 mmaplock.RLock 保护 |
| mmaplock | 读事务 beginTx(470 先 metalock 后 475 RLock);remap db.mmap(db.go:246);Close 取 RLock(db.go:398) | removeTx(db.go:547);db.mmap defer | 读事务存活期 = 映射有效期;remap 独占 |
| statlock | beginTx(db.go:496)、removeTx(db.go:568)、tx.close 写分支(tx.go:275)、Stats()(db.go:780) | 各自 Unlock | db.stats 全部字段 |

标准顺序:**rwlock → metalock → mmaplock(RLock)**(beginRWTx 取前两把;beginTx 取后两把且注释声明"先 meta 后 mmap,因为这是写事务获取它们的顺序",db.go:467-475);`db.mmap` 只单取 mmaplock、从不取 metalock,因此无环。`removeTx` 先 `mmaplock.RUnlock` 再 `metalock.Lock`(db.go:547-550),释放顺序与获取相反以避免 RWMutex 升级死锁。

**自我死锁(文档 db.go:448-455)**:同一 goroutine 里先手动 `Begin(true)` 再 `Begin(false)`(两个事务同时存活),写事务提交时 `allocate` 触发 `db.mmap` → `mmaplock.Lock`,而读者(同 goroutine)持 RLock——RWMutex 不可重入,永久阻塞自己;若进程无其他 goroutine,Go 运行时直接报 fatal deadlock。托管的 `Update` 内调 `View` 不会中招:managed View 在返回前已 Rollback 读事务(db.go:636),提交发生在 View 返回之后(db.go:581-606)。解法即文档 db.go:453-455 与 Options 注释(db.go:911-919):预估库尺寸设大 `InitialMmapSize`。

## 5. 页复用闸门:release(minid-1) 的精确语义与长读事务双重后果

```go
// db.go:530-539(beginRWTx 内)
	// Free any pages associated with closed read-only transactions.
	var minid txid = 0xFFFFFFFFFFFFFFFF
	for _, t := range db.txs {           // db.txs 只装"打开的读事务"
		if t.meta.txid < minid { minid = t.meta.txid }
	}
	if minid > 0 {
		db.freelist.release(minid - 1)
	}
```

```go
// freelist.go:131-144
// release moves all page ids for a transaction id (or older) to the freelist.
func (f *freelist) release(txid txid) {
	m := make(pgids, 0)
	for tid, ids := range f.pending {
		if tid <= txid {
			m = append(m, ids...)
			delete(f.pending, tid)
		}
	}
	sort.Sort(m)
	f.ids = pgids(f.ids).merge(m)
}
```

精确语义:写事务 T 提交时把废弃页挂到 `pending[T]`(freelist.go:111-129);`beginRWTx` 取当前打开读事务的最小 txid `minid`,把 **`tid ≤ minid-1` 整代的 pending 一次性搬入可用 `ids`**;`tid = minid` 这一代按住不放。若无读者,`minid` 保持初值 `0xFFFF...FF`,release(Max-1) 等于全量放行(db.go:531-538)。推断(源码无说明,按引用可达性分析):`pending[minid]` 一代的页其实已不被任何存活快照引用,代码保守地多扣了一代,留待下轮 beginRWTx 放行——此论断标注"分析推断,未核实官方说明"。

长读事务的双重后果:
1. **库膨胀**:被 T 代释放的页迟迟进不了 `ids`,写者只能持续在高水位追加(db.go:844-853);tx.go:18-21 的 Tx 文档原话——"A long running read transaction can cause the database to quickly grow"。
2. **写者卡 remap**:膨胀终将触发 `db.mmap`(db.go:846-850),它需要 `mmaplock` 写锁,而每个读事务从 begin 持到 rollback(取得 db.go:475,释放 db.go:547)——写者必须等**所有**读事务结束;这正是 §4 自我死锁与 `InitialMmapSize` 存在的根因。

## 6. Stats:全部计数点

- `Stats` 结构:FreePageN/PendingPageN/FreeAlloc/FreelistInuse + TxN/OpenTxN + TxStats(db.go:930-942)。
- 自由页四项:**仅在写事务 tx.close 时**在 statlock 下整体覆写——`FreePageN=freelist.free_count()`、`PendingPageN=pending_count()`、`FreeAlloc=(free+pending)*pageSize`、`FreelistInuse=freelist.size()`(tx.go:262-281;计数本体在 freelist.go:36-52)。
- TxN/OpenTxN:读事务开启时 `TxN++; OpenTxN=len(db.txs)`(db.go:496-499);读者退出时 `OpenTxN=n` 刷新(db.go:569)。
- TxStats 汇合点:写事务在 tx.close 的 statlock 段 `add`(tx.go:280);读事务在 removeTx 的 statlock 段 `add`(db.go:568-571)。逐项来源示例:`PageCount/PageAlloc` 在 tx.allocate(tx.go:467-468),`Write` 在 tx.write(tx.go:505、564)。
- `db.Stats()` 只在 statlock.RLock 下快照返回(db.go:779-783);`Stats.Sub` 对四个 freelist 字段是**直接拷贝不差分**,只有 TxN 与 TxStats 做减法(db.go:952-957)。
- `Tx.Stats()` 原样返回本事务计数器(tx.go:93-95),与 `tx.check` **无任何调用或数据关系**:check 是 freelist 双重释放 + 不可达页的可达性遍历(tx.go:383-419),由公开的 `Tx.Check()`(tx.go:377-380)和 StrictMode 提交路径(tx.go:202-213)使用;本 commit 没有 DB 级 `Check()`(全仓仅 tx.go:206 一处调用)。

## 7. 平台差异与纠偏清单

- **unix**(bolt_unix.go:48-65):`syscall.Mmap(PROT_READ, MAP_SHARED|MmapFlags)` + `madvise(MADV_RANDOM)`(db.go:56-58 调用点),保留 `dataref`;munmap 清零三件套(bolt_unix.go:76-78)。solaris 同构(bolt_unix_solaris.go:57-79)。
- **Windows**(bolt_windows.go:98-130):先 `Truncate(sz)` 再 `CreateFileMapping(PAGE_READONLY)`+`MapViewOfFile(FILE_MAP_READ)`;无 madvise;**完全忽略 MmapFlags**(全文件无引用);munmap **不复位** `db.data/datasz`(134-144,与 unix 不对称)。
- **fdatasync 四象限**:Linux 真 fdatasync(bolt_linux.go:9);其余 unix 退化为 `file.Sync()`(boltsync_unix.go:7);OpenBSD 必须 `msync(MS_INVALIDATE)`(bolt_openbsd.go:24-27,对应 db.go:26-30 的 IgnoreNoSync 注释:无统一缓冲缓存);Windows `file.Sync()`(bolt_windows.go:47)。
- **flock**:unix `syscall.Flock(LOCK_EX/LOCK_SH|LOCK_NB)` 50ms 轮询超时(bolt_unix.go:14-40);Windows 因无法共享排他锁,改用独立 `path+".lock"` 文件 + LockFileEx(bolt_windows.go:19、51-94)。
- **纠偏一:本 commit 不存在 mlock/MAP_LOCKED**——全仓 grep `mlock|Mlock|MAP_LOCKED` 零命中;`Mlock`/`MmapFlags` 之外的锁页是 bbolt 后期特性,正文不得提及。
- **纠偏二:不存在 `db.ops.pendingOps`**,16MB 来自 `DefaultAllocSize`(db.go:36、867-871),`db.ops` 仅 `writeAt`(db.go:123-125)。
- **纠偏三:"InitialMmapSize 最小 4 页"不成立**——源码唯一的页数下限检查是**文件** ≥ 2 页(db.go:252-254);mmap 的真实最小值是 32KB(2^15,db.go:310-311),与"4 页"无对应关系。
- **纠偏四:"提交触发 remap"是误述**——remap 仅在 Open(db.go:230)与 allocate 触底(db.go:847)两点发生;commit 的 `grow` 只动文件(tx.go:188-191)。

## 8. ASCII 图:mmap remap 时刻的锁 / 映射 / 事务状态

```
              db.mmap(minsz)(db.go:245-295)在写事务 allocate 中被调用
  goroutine W(写者)                                  goroutine R1 / R2(读者)
  ============                                       ========================
  rwlock      = W 持有(beginRWTx db.go:512)          (与 rwlock 无关)
  事务状态    = db.rwtx = W(tx.go 提交中)            db.txs = [R1,R2] 读快照存活
  ────────────────────────────────────────────────────────────────────────────
  [1] mmaplock.Lock() ◄── 若 R1/R2 仍持 RLock(db.go:475,释放于 547)则 W 在此阻塞
  [2] Stat:文件 >= 2 页              (db.go:249-254)
  [3] size = max(文件, minsz) → mmapSize 倍增/1GB 步进   (db.go:257-261)
  [4] rwtx.root.dereference()        (db.go:267-269)
      └ W 的 node.key/value 深拷出旧映射(node.go:523-545),防 unmap 后悬挂
  [5] munmap 旧映射                  (db.go:272 → bolt_unix.go:68-80)
  [6] mmap 新映射,datasz = sz       (db.go:277 → bolt_unix.go:48-65)
  [7] meta0/meta1 重新指向新映射     (db.go:282-283)
  [8] 双 meta validate,全败才失败   (db.go:288-292)
  [9] mmaplock.Unlock → 排队中的 beginTx(持 metalock→RLock,db.go:470-475)
      从"新"映射建立快照;旧映射物理消失,无任何指针再指它
  ────────────────────────────────────────────────────────────────────────────
  不变量:RLock 存活数 > 0  ⇒  remap 停在 [1];进入 [5] 时持有者必为 W 独占
          同 goroutine 的 读者RLock + 写者[1] = 永久自锁(db.go:448-451 文档)
```

## 9. 设计动机列表

1. **读 = 免锁免拷贝的 mmap 快照**:PROT_READ 共享映射 + 双 meta 校验切换(db.go:282-292、803-824),读者开销趋近于零,写者用 COW 保证其视图稳定。
2. **用 RWMutex 编码"读者存活 = 映射有效"**:与其管理引用计数,不如让读事务全程持 RLock(db.go:475→547),remap 天然被推到无读者窗口。
3. **倍增 + 1GB 步进摊销 remap 成本**:remap 次数 O(log size),大库退化为线性步进避免映射尺寸指数爆炸(db.go:310-337)。
4. **dereference 换取 unmap 安全**:与其让写事务节点全部堆化,不如只在 remap 前一次性深拷贝(db.go:267-269、node.go:523-545),常态路径零拷贝。
5. **pending/freelist 两级回收闸门**:页释放先按写事务代挂起,等"最老读者之前"的代整体放行(freelist.go:131-144、db.go:530-539),用空间上限换 MVCC 正确性。
6. **文件增长与映射增长解耦**:grow(Truncate+Sync,一次性 16MB)在 commit 做,remap 在 allocate 触底时做(db.go:847、tx.go:190),把慢系统调用挡在写事务边界而非每次分配。
7. **pagePool 复用单页缓冲并清零归还**(db.go:830-832、tx.go:522-540),压低分配器/GC 压力,清零防跨事务数据泄漏。

## 10. FAQ 候选

1. 为什么写事务会被读事务卡住?——remap 需要 mmaplock 写锁,而每个读事务从 begin 持 RLock 到退出(db.go:475、547)。
2. `Update` 里调 `View` 会死锁吗?——不会,托管 View 在返回前已 Rollback(db.go:636);死锁需要手动 `Begin(true)+Begin(false)` 同时存活(db.go:448-451)。
3. datasz 和 filesz 谁大?——unix 允许 mmap 领先文件(稀疏),Windows 则在 mmap 前把文件 Truncate 到映射大小(bolt_unix.go:63 vs bolt_windows.go:101)。
4. InitialMmapSize 设小了有副作用吗?——没有,它只是下限,小于现有文件时完全无效(db.go:257-261、917-918)。
5. 为什么最小映射是 32KB?——mmapSize 的 2 的幂循环从 i=15 起步(db.go:310-311)。
6. 32 位平台上库最大多大?——maxMapSize = 0x7FFFFFFF 即 2GB(bolt_386.go:4)。
7. remap 后读者手里的旧页指针会崩吗?——不会,锁保证 remap 时刻无读者;写者自己的引用已在 unmap 前 dereference(db.go:267-269)。
8. pending 页何时真正可复用?——下一次 beginRWTx 时 release(minid-1),tid ≤ 最老读者 txid-1 的整代搬入可用列表(db.go:538、freelist.go:132-144)。
9. Tx.Stats 和一致性检查有关系吗?——没有,check 是独立的可达性遍历(tx.go:383-419),仅 StrictMode 在 Commit 中调用它(tx.go:202-213)。
10. NoGrowSync 到底省了什么?——省掉 grow 时的 Truncate+Sync 两次系统调用,但注释警告仅在非 ext3/ext4 上安全(db.go:64-70、875-884)。

## 11. 深挖方向

1. **MAP_SHARED 页缓存一致性实证**:writeAt 更新的 meta 页(db.go:554)如何立即被只读映射读到——Linux 统一页缓存语义 vs OpenBSD 强制 msync(bolt_openbsd.go:16-27)的对比实验。
2. **remap 的实测代价曲线**:1GB→2GB 倍增时的缺页风暴与页缓存复制,量化 InitialMmapSize 调优收益(db_test.go:369 的 2GB 场景复现)。
3. **release(minid-1) 保守一代的形式化证明**:按本文 §5 推断给出不变式,并与 bbolt 后续 freelist 分组演进做 diff 考古。
4. **Windows munmap 不复位 db.data/datasz 的风险审计**(bolt_windows.go:134-144):close 后误用 db.data(如 Info(),db.go:787-789)是否构成悬垂句柄。
5. **dereference 成本模型**:每次 remap 前对整个写集的 O(bytes) 深拷贝(node.go:523-545)与 spill 写放大的叠加效应,寻找 remap 风暴工作负载。

## 12. 正文蒸馏要点

1. remap 全库仅两个触发点:Open(db.go:230)与 allocate 触底(db.go:847);commit 不 remap,grow 只扩文件(tx.go:188-191)。
2. mmap 流程铁序:mmaplock 写锁 → 文件 ≥2 页校验(db.go:252)→ 尺寸取 max 后过 mmapSize(db.go:257-261)→ rwtx dereference(db.go:267-269)→ munmap → mmap → 重挂 meta → 双校验全败才报错(db.go:288-292)。
3. mmapSize:32KB 起 2 的幂倍增至 1GB,之后按 1GB 步进、按页对齐、封顶 maxMapSize(db.go:310-337);64 位上限 256TB,32 位 2GB(bolt_amd64.go:4、bolt_386.go:4)。
4. InitialMmapSize 只是 minsz 下限且小于现文件则无效(db.go:917-919、257-261);"最小 4 页"的说法在本 commit 无出处,真实最小映射 32KB(db.go:310-311)。
5. datasz=映射长、filesz=磁盘长,两套比较互不越界:allocate 比 datasz(db.go:846),grow 比 filesz(db.go:861);Windows 在 mmap 内对齐两者(bolt_windows.go:99-104)。
6. allocate:单页走 pagePool(db.go:830-832),归还前逐字节清零(tx.go:522-540);freelist 优先(db.go:839),未命中在高水位追加并先 remap 再推 pgid(db.go:844-853);16MB 批量在 grow 而非 allocate(db.go:36、867-871),db.ops 无 pendingOps(db.go:123-125)。
7. 锁矩阵:rwlock=写者互斥(db.go:512/tx.go:272),metalock=实际守 db.txs/rwtx 而非注释所称 meta 页(db.go:119 vs 489、528、553-561),mmaplock=读者存活期 vs remap 窗口(db.go:475/547/246),statlock=stats(db.go:496、568、tx.go:275、db.go:780);顺序 rwlock→metalock→mmaplock。
8. 自我死锁唯一场景:同 goroutine 手动写事务+读事务并存且写路径触发 remap(db.go:448-455);托管 Update+View 安全(View 先 Rollback,db.go:636)。
9. 页复用闸门精确语义:beginRWTx 以最老读事务 minid 调 release(minid-1),tid≤minid-1 的 pending 整代放行,tid=minid 扣住(db.go:530-539、freelist.go:131-144);无读者时全量放行(db.go:531)。
10. 长读事务双重后果:pending 堆积致高水位扩张、库膨胀(tx.go:18-21),膨胀终致 remap 阻塞写者(db.go:846-475 交叉);官方逃生门是 InitialMmapSize(db.go:911-919、db_test.go:369-377)。
11. Stats 计数点:freelist 四项仅在写 tx.close 覆写(tx.go:275-280),TxN/OpenTxN 在 beginTx/removeTx(db.go:496-499、569),TxStats 两路汇合(tx.go:280、db.go:570);Stats.Sub 对 freelist 字段只拷贝不差分(db.go:952-957)。
12. 本 commit 无 mlock/MAP_LOCKED(全仓 grep 空),无 db.ops.pendingOps;MmapFlags 仅 unix 生效(bolt_unix.go:50),Windows 忽略(bolt_windows.go 无引用),unix 还附加 MADV_RANDOM 建议(bolt_unix.go:56)。
