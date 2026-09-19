# 第 05 章 · mmap 与并发模型:用一把读写锁编码"读者存活=映射有效"

> 基线:commit `fd01fc79`。核心:db.go / bolt_unix.go / bolt_windows.go。

## 5.0 全景:remap 时刻的锁与事务状态

```
 db.mmap(minsz)(全库唯一重映射入口,db.go:245-295)
 [1] mmaplock.Lock() ◄── 还有读者持 RLock(db.go:475)则写者在此阻塞
 [2] 校验文件 ≥2 页;size=max(文件,minsz) → mmapSize 取幂
 [3] rwtx.root.dereference():写者 node 里的 key/value 深拷出旧映射(db.go:267-269)
 [4] munmap 旧映射 → mmap 新映射(datasz=sz)
 [5] meta0/meta1 重新指向新映射;双校验全败才报错(db.go:282-292)
 [6] mmaplock.Unlock → 排队的新读者从"新"映射建快照
 不变量:进入[4]时映射必为写者独占;同 goroutine 的读者 RLock + 写者[1] = 永久自锁(db.go:448-455)
```

纠偏:remap 全仓 grep 只有**两个触发点**——Open(db.go:230)与 allocate 触底(db.go:847);**commit 本身不触发 remap**(提交里的 grow 只 Truncate+Sync 扩文件,tx.go:188-191),"提交触发 remap"是常见误述。

## 5.1 mmapSize:32KB 倍增,1GB 步进

`mmapSize` 从 2^15=32KB 起按 2 的幂倍增到 1GB,超过后按 `maxMmapStep=1GB` 步进并按页对齐、封顶 maxMapSize(db.go:308-340)。上限编译期定:64 位 256TB(bolt_amd64.go:4),32 位 2GB(bolt_386.go:4)。`InitialMmapSize` 只是 minsz 下限、小于现有文件则完全无效(db.go:917-919);纠偏:"最小 4 页"的说法在本 commit 无出处——唯一的页数检查是**文件** ≥2 页(db.go:252-254),映射真实最小值 32KB(db.go:310-311)。`datasz`(映射长)与 `filesz`(磁盘长)是两条独立账:allocate 比 datasz(db.go:846),grow 比 filesz(db.go:861);Windows 在 mmap 内先把文件 Truncate 到映射大小,两边语义分叉(bolt_windows.go:99-104)。

## 5.2 allocate:页从哪来

```go
// db.go:827-856(节选)
if count == 1 {
    buf = db.pagePool.Get().([]byte)      // 单页走 sync.Pool
} else {
    buf = make([]byte, count*db.pageSize) // 多页不进池
}
p.overflow = uint32(count - 1)
if p.id = db.freelist.allocate(count); p.id != 0 { return p, nil }  // 优先吃 freelist
p.id = db.rwtx.meta.pgid                  // 未命中:高水位追加
var minsz = int((p.id+pgid(count))+1) * db.pageSize
if minsz >= db.datasz { db.mmap(minsz) }  // 唯一的运行期 remap 点(db.go:847)
db.rwtx.meta.pgid += pgid(count)          // 注意:remap 先于高水位推进
```

pagePool 归还发生在写盘之后且**逐字节清零**,防跨事务数据泄漏(tx.go:522-540)。纠偏:16MB 批量扩容来自 `DefaultAllocSize` 且只在 grow 生效(db.go:36, 867-871),`db.ops` 里只有 writeAt 一个函数指针,不存在 pendingOps(db.go:123-125);grow 的 Truncate 在 Windows 被豁免(因为其 mmap 已先截到位)但 Sync 保留,出处是 issue #284(db.go:874-884)。

## 5.3 锁矩阵与自我死锁

| 锁 | 保护的临界区 |
|---|---|
| rwlock | 全库唯一写事务的整个生命周期(db.go:512; tx.go:272) |
| metalock | db.txs 增删 + db.rwtx 赋值——注释"Protects meta page access"并不精确,meta 读取实际靠 mmaplock.RLock(db.go:119 vs 489, 528) |
| mmaplock | 读事务存活期 vs remap 窗口(db.go:475/547/246) |
| statlock | db.stats 全部字段(db.go:496, 568, 780) |

标准顺序 rwlock→metalock→mmaplock(RLock);`db.mmap` 只单取 mmaplock,无环。**自我死锁唯一场景**:同一 goroutine 手动 `Begin(true)`+`Begin(false)` 并存,写路径触发 remap → mmaplock.Lock 撞上自己的 RLock(db.go:448-455);托管 `Update` 内调 `View` 安全——托管 View 返回前已 Rollback(db.go:636)。解药是预估库尺寸设大 InitialMmapSize(官方测试直接用 2GB 初值,db_test.go:369-377)。

## 5.4 Stats:计数点全表

freelist 四项(FreePageN/PendingPageN/FreeAlloc/FreelistInuse)**仅在写事务 close 时**于 statlock 下整体覆写(tx.go:275-280);TxN/OpenTxN 在 beginTx/removeTx 刷新(db.go:496-499, 569);TxStats 两路汇合(写 tx.close、读 removeTx)。纠偏:`Stats.Sub` 对 freelist 四项是**直接拷贝不差分**,只有 TxN/TxStats 做减法(db.go:952-957);`Tx.Stats()` 与 tx.check 无任何调用或数据关系——check 是独立的可达性遍历,仅 Check()/StrictMode 使用(tx.go:93-95, 377-419)。

## 5.5 平台差异四象限

mmap:unix `PROT_READ|MAP_SHARED`+`MADV_RANDOM` 且保留 dataref(bolt_unix.go:48-65);Windows `CreateFileMapping`+先 Truncate、**完全忽略 MmapFlags**、munmap 不复位 data/datasz(与 unix 不对称,bolt_windows.go:98-144)。fdatasync:Linux 真 fdatasync(bolt_linux.go:8-9);其余 unix 退化 file.Sync(boltsync_unix.go:7);OpenBSD 必须 msync(MS_INVALIDATE)(bolt_openbsd.go:24-27);Windows file.Sync(bolt_windows.go:47)。flock:unix 50ms 轮询超时;Windows 独立 `.lock` 文件(bolt_windows.go:51-94)。

## 5.6 设计动机

1. **读=免锁免拷贝的 mmap 快照**:PROT_READ 共享映射+双 meta 切换,读者开销趋近于零(db.go:282-292);
2. **RWMutex 编码"读者存活=映射有效"**:免引用计数,remap 天然被推到无读者窗口(db.go:475→547);
3. **倍增+1GB 步进摊销 remap**:次数 O(log size),大库线性步进防映射尺寸指数爆炸(db.go:310-337);
4. **dereference 换 unmap 安全**:常态路径零拷贝,只在 remap 前一次性深拷贝写集(db.go:267-269);
5. **文件增长与映射增长解耦**:grow 在 commit、remap 在 allocate 触底,慢系统调用挡在事务边界(db.go:847; tx.go:190);
6. **pagePool 清零归还**:压 GC 压力且防数据泄漏(db.go:830-832; tx.go:522-540)。

## 5.7 FAQ

**Q1:写事务为什么会被读事务卡住?**
remap 需要 mmaplock 写锁,读事务从 begin 持 RLock 到退出(db.go:475, 547)。

**Q2:Update 里调 View 会死锁吗?**
不会,托管 View 返回前已 Rollback;死锁需要手动两事务并存(db.go:636, 448-451)。

**Q3:datasz 和 filesz 谁大?**
unix 允许映射领先文件(稀疏);Windows 在 mmap 前把文件截到位(bolt_unix.go:63 vs bolt_windows.go:101)。

**Q4:InitialMmapSize 设小有副作用吗?**
没有,只是下限,小于现文件时无效(db.go:257-261)。

**Q5:32 位平台库最大多大?**
maxMapSize=2GB(bolt_386.go:4)。

**Q6:remap 后旧页指针会崩吗?**
读者不会(锁保证 remap 时无读者);写者已在 unmap 前 dereference(db.go:267-269)。

**Q7:pending 页何时真正可复用?**
下次 beginRWTx 的 release(minid-1),tid≤minid-1 的整代放行(db.go:538)。

**Q8:Tx.Stats 与一致性检查有关吗?**
无关,check 独立,仅 StrictMode 在 commit 中调用(tx.go:202-213)。

**Q9:NoGrowSync 省了什么?**
grow 的 Truncate+Sync;注释警告非 ext3/ext4 才安全(db.go:64-70, 875-884)。

**Q10:本版有 mlock 吗?**
没有,全仓 grep 为空;Mlock 是 bbolt 后期特性(bolt_unix.go:48-59)。

## 5.8 小结与深挖方向

本章结论:**并发模型=RWMutex 把读事务存活编码为映射有效期+两触点 remap+dereference 防悬挂**。深挖:

1. MAP_SHARED 页缓存一致性:writeAt 的 meta 页如何立即被只读映射看到(bolt_openbsd.go:16-27 对照);
2. 1GB→2GB 倍增时的缺页风暴与 InitialMmapSize 收益实测(db_test.go:369);
3. release(minid-1)"保守扣一代"的形式化与 bbolt freelist 分组演进对照;
4. Windows munmap 不复位 data/datasz 的悬垂句柄风险审计(bolt_windows.go:134-144);
5. dereference 的 O(写集) 深拷贝与 spill 写放大的叠加效应(node.go:523-545)。
