# 报告 D · 事务与提交管线(BoltDB)

> 基线:fd01fc79c553a8e99d512a07e8e0c63d4a3ccfc5(master,已归档 boltdb/bolt)。一句话总结:BoltDB 用"单写者互斥锁 + 只读 mmap + 双 meta 页轮流提交 + 按 txid 挂起的 pending freelist"实现了无 WAL 的影子分页事务——写者全程只碰堆内存副本,commit 时把脏页 WriteAt 落盘、fdatasync 后才改写 meta 并再 fdatasync,读事务则靠 meta 的 64 字节快照拷贝与"页释放先入 pending、待最老读事务退场才 release"的协议,在零拷贝 mmap 上获得稳定快照。

## 一、锁体系与事务开启序列

四把锁各司其职(db.go:118-121):`rwlock sync.Mutex` 保证任意时刻至多一个写事务;`metalock sync.Mutex` 保护 meta 页读取与 `db.txs` 的增删;`mmaplock sync.RWMutex` 保护重映射期间的 mmap 访问(读者持 R 锁、remap 持写锁);`statlock sync.RWMutex` 保护 Stats。写事务的句柄记录在 `db.rwtx`(db.go:108),由 beginRWTx 设置(db.go:528)、tx.close 清空(tx.go:271)。

读事务 beginTx 的加锁顺序是先 metalock 后 mmaplock(db.go:466-501),注释明确说明这与写事务的获取顺序一致(db.go:467-469):

```go
// db.go:470-493(节选)
db.metalock.Lock()
db.mmaplock.RLock()
if !db.opened { ...; return nil, ErrDatabaseNotOpen }
t := &Tx{}
t.init(db)                       // 在 metalock 临界区内拷贝 meta
db.txs = append(db.txs, t)       // 挂入读事务列表
n := len(db.txs)
db.metalock.Unlock()
db.statlock.Lock()
db.stats.TxN++; db.stats.OpenTxN = n
db.statlock.Unlock()
```

写事务 beginRWTx(db.go:504-541)的序列:readOnly 库直接拒绝(db.go:506-508, ErrDatabaseReadOnly)→ `rwlock.Lock()`(db.go:512,解锁权移交给 tx.close,tx.go:272)→ metalock(db.go:516-517)→ 建 Tx、`db.rwtx = t`(db.go:526-528)→ 顺手把已结束读事务的 pending 页 release 掉(db.go:530-539)。它不碰 mmaplock——remap 推迟到 commit 阶段 db.allocate 需要时才发生(db.go:844-850)。注意 DB.Close() 的加锁顺序是 rwlock→metalock→mmaplock.RLock(db.go:391-402),而读事务的 removeTx 是先 RUnlock mmaplock 再拿 metalock(db.go:545-565)。

"单写多读"的物理基础:mmap 以 `PROT_READ|MAP_SHARED` 映射(bolt_unix.go:48-50,另附 MADV_RANDOM, bolt_unix.go:56-58),连写者也无法原地修改页——写者的一切变更先落在内存 node 上(Put 仅 `c.node().put(...)`, bucket.go:307-309),commit 时才分配独立的堆缓冲脏页并用 `writeAt` 系统调用写文件(tx.go:500)。读者与写者共享的 mmap 永远是"已提交历史"的只读视图。

## 二、ro 事务的快照语义

快照点在 `Tx.init`(tx.go:44-62):在 metalock 保护下把当前生效 meta 整体拷贝成私有结构体(tx.go:48-50)。meta 结构共 64 字节(db.go:970-980:magic/version/pageSize/flags/root bucket{root,sequence}/freelist/pgid/txid/checksum,64 位平台恰好 64B),拷贝是一次 `*dest = *m` 结构体赋值(db.go:995-997):

```go
// tx.go:48-61
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
```

`db.meta()` 返回 txid 较高且 `validate()` 通过的那个 meta 页(db.go:803-824),两者都坏才 panic(db.go:823)。读事务的 txid 不递增(tx.go:58-61 仅 writable 分支),即 ro 快照 = 某次已提交状态。

读到的页为什么不会变,三重保障:
1. **页内容不可变**:所有修改都写往新分配的页(mmap 只读,见上节),已发布页从不被原地改写。
2. **pending 协议**:写事务释放的旧页不进可用链,而是挂到 `pending[释放者txid]`(freelist.go:111-129);只有 beginRWTx 检测到最老读事务已退场后才 `release` 进 `f.ids`(db.go:530-539, freelist.go:132-144),此后才可能被 allocate 复用。
3. **映射稳定**:ro 事务从 beginTx 起 `mmaplock.RLock`(db.go:475)直到 removeTx 才 RUnlock(db.go:547),而 remap 需要写锁(db.mmap, db.go:246-247),故读者脚下的 mmap 不会被 munmap/db.data 换掉。

溢出页也按同一规则处理:freelist.free 释放 `p.id` 到 `p.id+p.overflow` 的整段(freelist.go:118-127)。tx.page 优先查脏页缓存再回落 mmap(tx.go:571-581),因此写事务内部读到的是自己的新版本。

## 三、rw 事务 commit 全流程

Commit 入口(tx.go:144-236)先做防御:managed 事务禁止手动提交(tx.go:145),已关闭返回 ErrTxClosed(tx.go:146-147),只读事务返回 ErrTxNotWritable(tx.go:148-150)。随后是六阶段流水线:

**阶段 1 rebalance**(tx.go:156 → node.go:409-508):合并删除后过小的节点,填充阈值 25%(node.go:419-421),空节点删除、兄弟合并(node.go:451-507),被撤节点经 `node.free()` 把旧页挂入 pending(node.go:554-558)。

**阶段 2 spill**(tx.go:163 → node.go:339-405):自底向上把 node 物化成脏页,先递归子节点(node.go:348-353),按 pageSize 拆分(node.go:359),节点旧页先 free 再分配新页(node.go:362-371):

```go
// node.go:362-378(节选)
if node.pgid > 0 {
    tx.db.freelist.free(tx.meta.txid, tx.page(node.pgid))
    node.pgid = 0
}
p, err := tx.allocate((node.size() / tx.db.pageSize) + 1)
...
node.pgid = p.id
node.write(p)
node.spilled = true
```

根节点分裂上卷出新高层(node.go:399-402),随后 `tx.meta.root.root = tx.root.root`(tx.go:170)。

**阶段 3 重写 freelist**(tx.go:172-186):记录旧高水位 `opgid`(tx.go:172);旧 freelist 页挂 pending(tx.go:176);按序列化尺寸 `(size/pageSize)+1` 估算并分配新 freelist 页(tx.go:177, freelist.go:26-33);`freelist.write` 把 free+pending **全集**写进新页(freelist.go:191-209,注释言明崩溃后 pending 全部转为 free);更新 `tx.meta.freelist = p.id`(tx.go:186)。

**阶段 4 扩文件**(tx.go:189-194):pgid 高水位上移则 `db.grow`(db.go:859-888)——非 Windows 先 `Truncate` 再 `file.Sync`(db.go:875-884;Windows 免 Truncate, db.go:876-877),发生在写脏页**之前**。

**阶段 5 写脏页 + fdatasync**(tx.go:198 → tx.go:474-544):脏页按 id 升序排序(page.go:90-94)后逐页 writeAt,大页按 maxAllocSize 分块(tx.go:485-517);随后第一次 fdatasync(tx.go:520-524,NoSync 且非 IgnoreNoSync 时跳过);小页归还 pagePool(tx.go:527-541)。脏页来自 `db.allocate`(db.go:827-856):优先从 pagePool 取(db.go:830-831)→ freelist.allocate 找连续空段(db.go:839, freelist.go:67-107)→ 不够则 mmap remap(db.go:844-850)→ 推进 `rwtx.meta.pgid`(db.go:853)。

**阶段 6 写 meta + 第二次 fdatasync**(tx.go:221 → tx.go:547-567):`meta.write` 先断言 root/freelist 低于高水位(db.go:1001-1005),按 **txid 奇偶**决定写页 0 还是页 1(db.go:1008 `p.id = pgid(m.txid % 2)`),重算 FNV 校验和(db.go:1012, sum64 覆盖 checksum 前的 56 字节, db.go:1018-1022),writeAt 后第二次 fdatasync(tx.go:554-561)。最后 tx.close 解锁(tx.go:228)、执行 OnCommit 处理器(tx.go:231-233)。StrictMode 会在两阶段之间跑 Check 并 panic(tx.go:205-218)。

流水线中任何一步失败都立刻 `tx.rollback()`(tx.go:164/179/183/191/199/222)。

### commit 流水线与磁盘/meta 状态

```
 事务内(内存)            commit 流水线                     磁盘 / meta 状态
---------------------   ------------------------------   -----------------------------
 node 改动全在堆          [1] rebalance   tx.go:156        meta_old.freelist = FL_old
 tx.pages{} 脏页缓冲  --> [2] spill      tx.go:163        (旧 B 树仍完整有效)
                            旧页 -> pending[txid]
                            新页 -> tx.pages
                        [3] freelist 重写 tx.go:176-186      FL_new 页已 WriteAt(未发布)
                            旧FL页 -> pending[txid]          meta_old 未动
                        [4] grow          tx.go:189          文件 Truncate+Sync(仅增长时)
                        [5] write 脏页    tx.go:198
                            按 pgid 排序 writeAt   ------->  新数据页落盘(垃圾可回收)
                            fdatasync #1     tx.go:520  ====>  数据页持久 ✓
                        (5.5) StrictMode: Check panic
                        [6] writeMeta     tx.go:221
                            p.id = txid%2   db.go:1008 ----->  meta[txid%2] 覆盖写
                            fdatasync #2    tx.go:557   ====>  新版本发布 ✓
                        [7] close: rwlock.Unlock tx.go:272   等待读者退场后 pending 页才可复用
 崩溃于 [5] 前:meta_old 原样,新页是垃圾,重启后按盘上 freelist 恢复
 崩溃于 [6] 中:两份 meta 一新一旧,读侧取 txid 高且校验通过者(db.go:803-824)
```

**设计动机**(≥5 条,均可在源码定位):
1. **无 WAL 的影子分页**:脏页写新位置、meta 单字切换,提交点收敛为"写 meta 页"一个原子动作(db.go:1008),省掉 WAL 的双重写放大。
2. **两次 fdatasync 定序**:先持久数据页再持久 meta(tx.go:520-524 → tx.go:557-561),保证 meta 指向的页必在盘上,崩溃恢复永远自洽。
3. **双 meta 轮流写**:txid 奇偶选页(db.go:1008)+ 读侧校验择优(db.go:803-824),崩溃时写坏一份还有一份。
4. **pending freelist 按 txid 分批释放**(freelist.go:111-144):把"页可否复用"与"最老读者是否退场"解耦,读者无需任何每页引用计数。
5. **mmaplock 读写锁**(db.go:120):读者 RLock 贯穿整个事务(db.go:475/547),remap 稀少且按 2 的幂扩容(db.go:308-340),摊薄 munmap 风暴。
6. **metalock 缩略临界区**:meta 拷贝与 txs 增删是纯内存操作(db.go:470-493),读写双方仅在开启/关闭瞬间互斥,主路径完全并行。
7. **statlock 独立**(db.go:121):统计合并(tx.go:275-281, db.go:568-571)不阻塞事务主路径。

## 四、rollback 路径

`Tx.Rollback`(tx.go:240-247)对 managed 事务 panic(tx.go:241);ro 事务只能 rollback——对它调 Commit 得到 ErrTxNotWritable(tx.go:148-150),`View` 因此统一以 Rollback 收尾(db.go:636)。核心实现:

```go
// tx.go:249-258
func (tx *Tx) rollback() {
    if tx.db == nil { return }
    if tx.writable {
        tx.db.freelist.rollback(tx.meta.txid)
        tx.db.freelist.reload(tx.db.page(tx.db.meta().freelist))
    }
    tx.close()
}
```

rw 回滚的两步(freelist.go:147-155, 215-239):`freelist.rollback` 把本 txid 的 pending 页从 cache 与 pending 表中删除;`freelist.reload` **整表重读**盘上 meta.freelist 指向的 freelist 页,并剔除仍属其他事务 pending 的页。这一步不是增量撤销而是重新对齐:本 tx 的新分配页从未出现在盘上 freelist 里,撤掉 pending 后内存视图与"上次提交"完全一致,无泄漏也无误复用(盘上 B 树 + 盘上 freelist 本就自洽)。磁盘上不回写任何字节——meta 未写,WriteAt 过的数据页沦为不可达垃圾,等待未来某次 commit 的 freelist.write 重新收编。

`tx.close`(tx.go:260-291)分叉,是两把主锁真正的释放点:

```go
// tx.go:270-284(节选)
// Remove transaction ref & writer lock.
tx.db.rwtx = nil
tx.db.rwlock.Unlock()
// Merge statistics.
tx.db.statlock.Lock()
tx.db.stats.FreePageN = freelistFreeN
tx.db.stats.PendingPageN = freelistPendingN
tx.db.stats.FreeAlloc = (freelistFreeN + freelistPendingN) * tx.db.pageSize
tx.db.stats.FreelistInuse = freelistAlloc
tx.db.stats.TxStats.add(&tx.stats)
tx.db.statlock.Unlock()
} else {
    tx.db.removeTx(tx)
}
```

rw 分支在解锁前先快照 freelist 三项计数(tx.go:265-268)再入 statlock 合并;ro 分支走 `db.removeTx`(db.go:545-572):先 RUnlock mmaplock(db.go:547,读事务全程持有它的终点),再 metalock 下从 `db.txs` 尾部交换摘除(db.go:550-565),statlock 下合并 TxStats(db.go:568-571)。两条路都把 `tx.db` 置 nil 防误用(tx.go:287)。

Update 的 panic 防线(db.go:588-592)与 View 的(db.go:619-623)都靠 `defer` 里检查 `t.db != nil` 再 rollback,保证 panic 时锁必然释放。

## 五、freelist.release 与读事务最小 txid

beginRWTx 尾部的关键 10 行(db.go:530-539):

```go
// db.go:530-539
// Free any pages associated with closed read-only transactions.
var minid txid = 0xFFFFFFFFFFFFFFFF
for _, t := range db.txs {
    if t.meta.txid < minid {
        minid = t.meta.txid
    }
}
if minid > 0 {
    db.freelist.release(minid - 1)
}
```

`freelist.release(txid)` 把 pending 中 **tid <= 参数** 的所有页整体排序合并进可用链 `f.ids`(freelist.go:132-144):

```go
// freelist.go:132-144
func (f *freelist) release(txid txid) {
	m := make(pgids, 0)
	for tid, ids := range f.pending {
		if tid <= txid {
			// Move transaction's pending pages to the available freelist.
			// Don't remove from the cache since the page is still free.
			m = append(m, ids...)
			delete(f.pending, tid)
		}
	}
	sort.Sort(m)
	f.ids = pgids(f.ids).merge(m)
}
```
语义:txid=T 的写事务释放的页,只可能被 txid 严格小于 T 的读事务引用;取现存读事务的最小 txid minid,release(minid-1) 恰好放行"释放者不晚于 minid-1"的所有 pending,即引用者代际已在 minid 之前、必然全部退场的那批页——保守留出 1 的间隔。若无读事务,minid 保持最大值,release 一次放行全部积压。

**长读事务的连锁后果**:(a) pending 永不 release,写事务只能分配新页,DB 文件持续膨胀(Tx 文档原话:"A long running read transaction can cause the database to quickly grow", tx.go:20-23);(b) 文件增长触发 mmap remap,但读者持有 mmaplock.RLock,remap 的写锁(db.go:246-247)拿不到,写事务阻塞在 `db.allocate → db.mmap`(db.go:847);(c) 同一 goroutine 先开读再开写会**自我死锁**,Begin 文档明确警告(db.go:448-455),缓解手段是预设 `InitialMmapSize`(db.go:911-919)。写事务自身节点引用 mmap 指针,remap 前先整树 dereference 拷贝到堆(db.go:267-269, node.go:523-553)。

## 六、bucket 级事务语义与 tx.check

只读事务上的一切写操作被入口拦截:Put 返回 ErrTxNotWritable(bucket.go:289),其余顺序为 ErrTxClosed(bucket.go:287)、ErrKeyRequired(空 key, bucket.go:291)、ErrKeyTooLarge(bucket.go:293, 32KB, bucket.go:11)、ErrValueTooLarge(bucket.go:295, 2GB-2, bucket.go:14);键已存在且是子桶时报 ErrIncompatibleValue(bucket.go:303-305)。CreateBucket 同样先查 db/writable/空名(bucket.go:163-167),再区分 ErrBucketExists(bucket.go:177)与 ErrIncompatibleValue(占位键非 bucket, bucket.go:179)。DeleteBucket 递归删子桶(bucket.go:233-242)后 `child.free()` 把整棵子树页挂 pending(bucket.go:257 → bucket.free, bucket.go:470-481)。

`tx.check`(tx.go:383-416,由 Check 起独立 goroutine 经 channel 回传, tx.go:377-381)做四类校验:freelist 全集中无重复页(防双重释放, tx.go:385-393);meta0/meta1/freelist 页标记可达(tx.go:396-401);递归 checkBucket 检查每页越界、多重引用、可达却已释放、非法页类型(tx.go:418-454);最后线性扫描高水位以下,凡不可达且未释放即报 "unreachable unfreed"(tx.go:407-412)——这是唯一能暴露"rollback 泄漏页"的检查,也是 StrictMode 每次 commit 的附带成本(tx.go:205-218)。

## 七、写事务独占性、Update 与 Batch

**同时开两个 rw**:第二个调用者阻塞在 `db.rwlock.Lock()`(db.go:512),Go Mutex 无超时,直到前一写事务 close 时 Unlock(tx.go:272)——文档表述为"block and be serialized"(db.go:444-446)。跨进程则靠文件 flock:非 ReadOnly 排他锁(db.go:179-189),ReadOnly 共享锁,保护双进程分别写 meta 的损坏场景。rwlock 同时也是 DB.Close 的第一把锁(db.go:392)。

**Update**(db.go:581-606):Begin(true) → 标记 `managed`(db.go:595,使内部手动 Commit/Rollback 触发 panic, tx.go:145/241)→ fn 出错则 Rollback(db.go:600-603)否则 Commit(db.go:605)→ panic 被 defer 兜底回滚(db.go:588-592)。每次 Update 独占一个写事务。

**Batch**(db.go:660-683)是延迟合并:调用者在 batchMu 下发现无 batch 或已满(MaxBatchSize)则新建 batch 并挂 10ms 定时器(db.go:664-670,默认值 db.go:34-35);凑满立即 `go trigger`(db.go:672-675);随后阻塞等私有 errCh(db.go:678),收到 trySolo 哨兵则退化为单独 `db.Update(fn)`(db.go:679-681)。批量执行在 `batch.run`(db.go:704-744):先在 batchMu 下把自己摘出(db.go:705-712),然后 retry 循环——**所有 calls 在同一个 Update 事务里顺序执行**(db.go:717-725);某个 fn 失败则将其移出批次、给其提交者回 trySolo、其余重试(db.go:727-736);最终结果广播给全体(db.go:739-742):

```go
// db.go:714-743(节选)
retry:
	for len(b.calls) > 0 {
		var failIdx = -1
		err := b.db.Update(func(tx *Tx) error {
			for i, c := range b.calls {
				if err := safelyCall(c.fn, tx); err != nil {
					failIdx = i
					return err
				}
			}
			return nil
		})
		if failIdx >= 0 {
			c := b.calls[failIdx]
			b.calls[failIdx], b.calls = b.calls[len(b.calls)-1], b.calls[:len(b.calls)-1]
			// tell the submitter re-run it solo, continue with the rest of the batch
			c.err <- trySolo
			continue retry
		}
		for _, c := range b.calls {
			c.err <- err
		}
		break retry
	}
```
因为 fn 可能被执行多次,文档强制"副作用必须幂等"(db.go:649-654);panic 会被 safelyCall 转成 panicked 错误(db.go:751-769)。与 Update 的本质差异:Batch 用"单事务多函数 + 失败者重放"换取写入次数摊薄,牺牲的是 fn 的执行次数确定性。

## 八、纠偏(以本 commit 源码为准)

1. **"BoltDB 提供 Mlock 选项锁定内存"——本基线不成立**:全仓库 grep 无 mlock/MAP_LOCKED 任何实现,mmap 固定 `PROT_READ|MAP_SHARED` 加 MADV_RANDOM(bolt_unix.go:48-59),Options 仅 Timeout/NoGrowSync/ReadOnly/MmapFlags/InitialMmapSize 五项(db.go:895-920)。Mlock 是 bbolt 后期才引入的特性。
2. **"只读事务可以 Commit,等价于无操作"——错**:Commit 对 `!tx.writable` 直接返回 ErrTxNotWritable(tx.go:148-150);View 统一以 Rollback 结束(db.go:636),"Read-only transactions must be rolled back and not committed"(tx.go:238-239)。
3. **"两次落盘都是 fsync"——不准确**:Linux 下是 `syscall.Fdatasync`(bolt_linux.go:8-9),Windows 与其他 Unix 退化为 `file.Sync`(bolt_windows.go:46-48, boltsync_unix.go:6-8);且文件增长时 grow 还有一次 Truncate+`file.Sync`(db.go:875-884,Windows 免 Truncate),增长型 commit 最多三次同步调用。
4. **"meta 永远写在页 0"——错**:页号由 txid 奇偶决定(db.go:1008),两份 meta 轮流覆盖;读侧取 txid 更高且校验通过的一份(db.go:803-824),WriteTo 复制时甚至给第二份 meta 人为减 1 保持奇偶互补(tx.go:328-330)。
5. **"Batch 是把多个事务攒起来逐个提交"——错**:所有 calls 共享**同一个** Update 事务(db.go:717-725),失败者剔除重放(db.go:727-736);fn 可能多次执行,幂等是硬要求(db.go:649-654)。
6. **"读事务会阻塞写事务提交"——只对一半**:ro 事务不阻塞 commit 六阶段本身,只阻塞 pending 页 release(db.go:530-539)与 mmap remap(mmaplock, db.go:246-247);后者才让写事务卡在 db.allocate(db.go:847)。塞满 MaxBatchDelay 的直觉同款误区:Batch 的 10ms 是上限等待而非固定延迟。
7. **"freelist 上的页立即可复用"——错**:`count = free + pending`(freelist.go:36-38),pending 按释放者 txid 分组(freelist.go:117-128),且落盘 freelist 页同时持久化两者、崩溃后 pending 整体转 free(freelist.go:188-190 注释与实现)。

## 附录 A · FAQ 候选(10 条)

1. 同进程并发开两个写事务会怎样?——第二个阻塞在 `db.rwlock.Lock()`(db.go:512)直到前者 close 解锁(tx.go:272),完全串行。
2. 在 View 里调 Put 报什么错?——ErrTxNotWritable(bucket.go:289);事务已关闭则是 ErrTxClosed(bucket.go:287)。
3. 为什么 View 结束调 Rollback 而不是 Commit?——ro 事务 Commit 会返回 ErrTxNotWritable(tx.go:148-150),回滚只是走 removeTx 释放锁与列表(db.go:545-565)。
4. ro 快照的复制品是什么、何时拷?——metalock 临界区内一次性拷贝 64 字节 meta 结构体(tx.go:48-50, db.go:970-980),root bucket 随之拷贝(tx.go:52-55)。
5. 一条长读事务最坏会拖垮什么?——pending 页无法 release 导致文件膨胀(tx.go:20-23),并令 remap 等不到写锁、写事务卡死在 db.mmap(db.go:847)。
6. commit 中途失败文件会坏吗?——不会:meta 未写则旧版本仍生效,每步失败都触发 tx.rollback(tx.go:164 等),内存 freelist 经 reload 与盘面对齐(tx.go:255)。
7. txid 什么时候递增?——仅写事务 init 时 +1(tx.go:58-61);该 txid 同时决定 commit 写哪份 meta(db.go:1008)。
8. NoSync 具体省掉什么?——两次 fdatasync(tx.go:520-524, tx.go:557-561),文件增长的 Truncate+Sync 另由 NoGrowSync 控制(db.go:875-884)。
9. freelist 新页要占多大?——`(size/pageSize)+1` 页,按 free+pending 总数的序列化尺寸保守估算(tx.go:174-177, freelist.go:26-33)。
10. StrictMode 开销在哪?——每次 commit 后同步跑完 tx.Check 并在发现不一致时 panic(tx.go:205-218),大库上成本极高(db.go:46-49)。

## 附录 B · 深挖方向(5 条)

1. **spill/rebalance 与 B+ 树形态**:split 填充率 FillPercent(bucket.go:49, 默认 0.5 bucket.go:33)与 25% 合并阈值(node.go:419)对写放大的量化影响。
2. **mmapSize 增长曲线**:32KB 起倍增至 1GB、此后按 1GB 步进(db.go:308-340)与 InitialMmapSize 的取值策略对长读场景死锁规避的实测。
3. **freelist 碎片化**:`allocate` 只找连续段(freelist.go:67-107)、大事务溢出页(maxAllocSize 分块写, tx.go:491-516)下的空间利用率退化与 bbolt 后续的 flushpages 改造。
4. **Windows 差异**:独立 lockfile(bolt_windows.go flock 段)、免 Truncate 的 grow(db.go:876)、fdatasync 退化为 file.Sync 对提交延迟的影响。
5. **与 bbolt 的演进对照**:本基线之后引入的 `NoFreelistSync`、idle 读事务超时、Mlock 等,反推本 commit 设计的痛点。

## 正文蒸馏要点

正文必须保留的核心论断(均已核实行号):

1. BoltDB 是无 WAL 的影子分页:写者全程只改堆内存,commit 时统一物化;mmap 对所有人是只读的(`PROT_READ|MAP_SHARED`, bolt_unix.go:48-50),写盘走 WriteAt 系统调用(tx.go:500)。
2. 四锁分工:rwlock 单写者(db.go:118/512)、metalock 保护 meta 拷贝与 txs 表(db.go:470-493)、mmaplock 保护 remap(db.go:246-247/475/547)、statlock 保护统计(db.go:121)。
3. ro 快照 = metalock 下一次 64 字节 meta 结构体拷贝(tx.go:48-50, db.go:995-997),txid 不递增(tx.go:58-61),根 bucket 指针一并拷贝(tx.go:52-55)。
4. 页不被改写的三重保障:只写新页 + pending 协议(freelist.go:111-129)+ 读者全程 mmaplock.RLock(db.go:475/547)。
5. commit 六阶段:rebalance(tx.go:156)→ spill(tx.go:163)→ 重写 freelist(tx.go:176-186)→ grow(tx.go:189-194)→ 写脏页+fdatasync(tx.go:198/520-524)→ 写 meta(txid%2 选页, db.go:1008)+fdatasync(tx.go:221/557-561),每步失败即 rollback。
6. freelist 双链结构:`ids` 可立用、`pending[txid]` 挂起;freelist.write 把 free+pending 全集落盘,崩溃后 pending 转正(freelist.go:36-38/191-209)。
7. 页复用闸门在 beginRWTx:取现存读事务最小 txid,`release(minid-1)` 放行已无引用者的 pending 页(db.go:530-539, freelist.go:132-144)。
8. 长读事务 = 文件膨胀 + remap 阻塞(db.go:847),同 goroutine 读写互开会自我死锁(db.go:448-455),解药 InitialMmapSize(db.go:911-919)。
9. rollback 零磁盘写:rw 先 `freelist.rollback` 再 `reload` 整表重读对齐盘面(tx.go:249-258, freelist.go:147-155/215-239);ro 仅 removeTx 释放锁(db.go:545-572)。
10. ro 事务不可 Commit(tx.go:148-150),View 以 Rollback 收尾(db.go:636);managed 事务手动提交/回滚即 panic(tx.go:145/241)。
11. Batch 把并发调用合并进单个 Update 事务(db.go:717-725),失败者摘除重放(trySolo, db.go:727-736/749),fn 必须幂等(db.go:649-654);默认 1000 个/10ms(db.go:34-35)。
12. tx.check 四类校验:双重释放、可达性、多重引用、unreachable unfreed(tx.go:383-416),StrictMode 使其随每次 commit 执行并 panic(tx.go:205-218)。
