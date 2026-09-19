# 报告 F · 工程与生态(BoltDB)

> 基线:fd01fc79c553a8e99d512a07e8e0c63d4a3ccfc5(master,2018-03-02,PR #748 合并)——一个约 4.1K 行实现(db.go 1037 + bucket.go 777 + tx.go 686 + cursor.go 400 + node.go 604 + page.go 197 + freelist.go 252 + errors.go 71 + doc.go 44,wc -l 实测)、5,649 行测试、1,740 行单文件 CLI 的"完工即封版"项目:README 明言 API 与文件格式已冻结、作者本人宣布停止维护并指向 CoreOS 的 bbolt 分叉作为继任者。

## 1. README:自我定位、维护状态与"继任者"指引

README 第一行即自报版本号 1.2.1(README.md:1)。定位是"纯 Go 的 KV 存储,灵感来自 Howard Chu 的 LMDB",目标是为"不需要完整数据库服务器(如 Postgres/MySQL)的项目"提供简单、快速、可靠的数据库(README.md:4-7);并强调"simplicity is key……API 只关注读写值,仅此而已"(README.md:9-11)。

**维护状态(Project Status + 作者告别信)**:
- "Project Status"一节宣称:Bolt is stable、API 固定、文件格式固定,"full unit test coverage and randomized black box testing"保证一致性与线程安全,生产环境有 1TB 规模数据库,Shopify/Heroku 每天在用(README.md:18-22)。
- 作者 Ben Johnson 的告别信以引用块写在 README:项目"complete";维护开源数据库需要海量时间与精力,"改动可能有意想不到甚至灾难性的影响,简单改动也需要数小时数小时的仔细测试";因此选择把项目留在当前稳定状态;想用更多特性的读者被明确指向 CoreOS 分叉 **bbolt**(README.md:26-39,bbolt 链接在 39 行)。
- 措辞注意:本 commit 时代 GitHub 尚无"Archived"仓库横幅,README 原文没有"archived"一词,"已归档"是仓库层面的事实(通识,未核实源码);README 内的证据就是这封告别信。

**README 的"Reading the Source"一节**是官方导览:自称"<3KLOC"(README.md:833;实测实现约 4.1K 行,见开头统计,该数字已过时),点名六个入口并逐一给出一句话导读:`Open()`(README.md:839-842)、`DB.Begin()`(README.md:843-847)、`Bucket.Put()`(README.md:849-854)、`Bucket.Get()`(README.md:856-861)、`Cursor`(README.md:863-866)、`Tx.Commit()`——其中对两阶段提交的描述与 tx.go 实现逐句对应(README.md:868-875,详见第 6 节)。

**README 的"Other Projects Using Bolt"**列了 50+ 使用方(README.md:881-935):Consul(908)、InfluxDB(905)、bleve(902)、cayley(901)、btcwallet(929)、Storm(920)、ledisdb(899)、SeaweedFS(904)、Algernon(923)等,结尾邀请"send a pull request to add it to the list"(README.md:935)。

## 2. doc.go:写在包注释里的规格书、设计动机与平台清单

doc.go 全文 44 行,是行为契约而非教程。承诺清单及实现呼应:

| doc.go 承诺 | 行号 | 实现呼应 |
|---|---|---|
| fully serializable transactions、ACID、lock-free MVCC(多读者单写者) | doc.go:2-4 | 单写者由 `db.rwlock.Lock()` 强制,注释直说 "enforces only one writer transaction at a time"(db.go:510-512);读者无锁走 mmap(db.go:466-502) |
| single-level、zero-copy、B+tree,为读优化 | doc.go:8 | `Get()` 直接返回 mmap 内切片,无分配开销(README.md:856-861) |
| 崩溃无需恢复,未提交事务自动回滚 | doc.go:9-11 | 双 meta 页互为备份:mmap 时两张都校验,"只有两张都失败才报错"(db.go:285-292) |
| 设计基于 LMDB | doc.go:13 | README 详述同源与分歧(README.md:752-767) |
| 支持 Windows/macOS/Linux | doc.go:15 | 10 个平台文件(见下表) |
| 同一时间只允许一个写事务 | doc.go:27-28 | db.go:510-512 |
| 数据文件只读映射,应用写它会 panic | doc.go:33-36 | 字段注释 `dataref []byte // mmap'ed readonly, write throws SEGV`(db.go:100) |
| 键值只在事务生命周期内有效,越界使用 panic | doc.go:38-40 | README:314-316 要求事务外使用必须 `copy()` |

**设计动机列表**(每条均有出处):
1. **简单高于性能**:API 小到只有读写值(README.md:9-11);与 LMDB 的分歧被总结为"LMDB 追求原始性能,Bolt 追求简单易用"(README.md:759-760)。
2. **拒绝一切可能损坏数据库的操作**:"Bolt opts to disallow actions which can leave the database in a corrupted state",唯一例外是 `DB.NoSync`(README.md:760-762)。
3. **用元数据设计消灭恢复流程**:双 meta 页 + 校验和 + 两阶段写入,使"崩溃即回滚"不需要任何恢复代码(doc.go:8-11;tx.go:474-567)。
4. **用内存保护防误用**:只读映射让越界写立刻 SEGV panic 而非悄悄损坏文件(doc.go:33-36;db.go:100)。
5. **测试即规格**:randomized black box testing 写进 Project Status(README.md:19-20);Makefile 的 `race` 目标专门只跑 `TestSimulate_(100op|1000op)` 加 `-race`(Makefile:7-8)。
6. **零依赖单文件分发**:无第三方 import,`go get github.com/boltdb/bolt/...` 连 CLI 一起装(README.md:78-85)。

**平台文件清单**(根目录,均实测):
- 体系结构常量:bolt_386.go(maxMapSize=0x7FFFFFFF 即 2GB,bolt_386.go:4)、bolt_amd64.go(256TB,bolt_amd64.go:4)、bolt_arm.go(2GB + 运行时探测非对齐访问的 init(),bolt_arm.go init 块)、bolt_arm64.go(256TB)、bolt_ppc.go / bolt_ppc64.go / bolt_ppc64le.go(2GB)、bolt_s390x.go(大端,`brokenUnaligned = true` 方向常量)。
- 操作系统层:bolt_unix.go(!windows/!plan9/!solaris:flock/funlock/mmap/munmap)、bolt_linux.go(真 `syscall.Fdatasync`,bolt_linux.go:9-12)、bolt_unix_solaris.go(flock 用 `syscall.Flock_t`)、bolt_openbsd.go(msync + msAsync/msSync/msInvalidate 常量,bolt_openbsd.go:11-23)、bolt_windows.go(LockFileEx 轮询)、boltsync_unix.go(其余 Unix 的 fdatasync 退化为 `file.Sync()`,boltsync_unix.go:4-7)。
- OpenBSD 特例:因无统一缓冲缓存(UBC),包常量 `IgnoreNoSync = runtime.GOOS == "openbsd"` 强制忽略 NoSync(db.go:26-30)。

**打开选项全表(Options,db.go:894-927)**——本章主题的"生命周期承诺"都挂在这几个开关上:

| 选项 | 行号 | 语义 |
|---|---|---|
| Timeout | db.go:896-899 | 等文件锁的时长;0 = 永久等;注释自称"only available on Darwin and Linux"(与 Windows/Solaris 实现矛盾,见 FAQ 4) |
| NoGrowSync | db.go:901-902 | 跳过 grow 时的 Truncate+Sync(db.go:875-884) |
| ReadOnly | db.go:904-906 | 共享锁 `flock(..., LOCK_SH \| LOCK_NB)` 打开,多进程可同时只读 |
| MmapFlags | db.go:908-909 | 透传给 mmap 的 prot/flags |
| InitialMmapSize | db.go:911-919 | 预留映射大小,避免长读事务阻塞写事务重映射;小于原库尺寸时不生效 |
| DefaultOptions | db.go:924-927 | 仅 Timeout:0——**默认行为是无限期等锁** |

## 3. 测试体系:随机化黑盒测试 + 模型检查(本 commit 无崩溃注入)

**清单与规模**(wc -l 实测):bucket_test.go 1909、db_test.go 1545、cursor_test.go 817、tx_test.go 716、simulation_test.go 329、freelist_test.go 158、node_test.go 156、page_test.go 72、quick_test.go 87,共 5,649 行;工具侧 cmd/bolt/main_test.go 356 行。全部为外部黑盒包 `bolt_test`(simulation_test.go:1),只经公共 API 驱动。

**simulation_test.go 精读(并发随机操作)**:14 个入口按"操作数 × 并行度"组合矩阵展开,从 `1op_1p` 到 `10000op_1000p`(simulation_test.go:13-28);`-short` 模式跳过(32-34)。核心 `testSimulate(t, threadCount, parallelism)`:

```go
// simulation_test.go:36-57(节选)
rand.Seed(int64(qseed))                  // 种子来自 -quick.seed,可复现
...
var threads = make(chan bool, parallelism) // 带缓冲 channel 限流并行度
for {
    threads <- true
    wg.Add(1)
    writable := ((rand.Int() % 100) < 20) // 20% 概率是写者
```

每个 goroutine 先 `db.Begin(writable)`(72),再以全局 `versions map[int]*QuickDB` 维护"每个 txid 应有的数据集":写者从 `versions[tx.ID()-1].Copy()` 起步、提交前写回 `versions[tx.ID()]`(78-95),读者只 Rollback(97)。**正确性判据是影子模型 QuickDB**——纯内存 map 版 Bolt(198-206):`simulateGetHandler` 随机取一条键路径逐层下钻,比对 `b.Get()` 与 `qdb.Get()`,不一致打印差异并 `panic("value mismatch")`(125-157);`simulatePutHandler` 随机生成 2-3 层嵌套桶路径与最长 8KB 随机值,双写 Bolt 与 QuickDB(160-193)。键长 1-1024 字节、值 0-8KB 均为随机字节(303-329)。

**纠偏①:没有"崩溃模拟"**。全测试目录 grep `crash|kill|fault` 零命中;README 所谓 randomized black box testing 指的正是上述并发随机操作 + 模型比对(README.md:19-20)。最接近故障注入的只有"改字节"级用例:TestOpen_ErrVersionMismatch 用 `unsafe` 把两张 meta 页 version++ 后期待 `ErrVersionMismatch`(db_test.go:109-143);TestOpen_ErrChecksum 改 pgid 后期待 `ErrChecksum`(db_test.go:146-180);TestOpen_ErrInvalid 往文件写一行文本期待 `ErrInvalid`(db_test.go:88-106)。

**纠偏②:没有 TestOpenTimeout**。全仓 `*.go` grep "Timeout":实现里 db.go:186/896-899、bolt_unix.go:22、bolt_windows.go:68、bolt_unix_solaris.go:22、errors.go:26-28,但 `*_test.go` 中零命中——Timeout 行为在本 commit 完全无测试覆盖,仅靠 README 文档承诺(README.md:117-124)。

**纠偏③:没有独立的 forward/backward 兼容测试**。兼容性仅由 magic=`0xED0CDAED`(db.go:24)+ version=2(db.go:20-21)的单点校验承担(meta.validate,db.go:982-992;测试侧同值镜像定义于 db_test.go:27-31),没有"旧格式文件能否被新二进制打开"的测试集。

**各文件骨架**:
- db_test.go:打开失败族(TestOpen_Err*,72-180)、文件尺寸不增长(TestOpen_Size 引 issue #291,183-240)、InitialMmapSize(369)、Close 带挂起事务的 RW/RO 两态(464-465)、Update/View 的手动 commit/rollback 与 panic 传播(559-761)、Stats/Sub(762-867)、Batch 三件套(869-1192)与 3 个 Batch benchmark(1193-1545)。
- bucket_test.go:Get/Put/Delete/嵌套桶/Sequence/NextSequence/ForEach/Stats 全 API 覆盖(共 44 个 Test);大型用例 TestBucket_Put_Large 用 200 倍递增键长的字符串对(173-207)、TestBucket_Delete_FreelistOverflow 写入 10000×1000 键后单事务全删(383-428,`-short` 跳过)、两个 quick 随机用例(1696,1756)。
- tx_test.go:错误族 Commit/Rollback ErrTxClosed、ErrTxNotWritable(15-66)、桶管理错误(106-390)、OnCommit 回调与回滚不触发(441-479)、CopyFile 及其错误注入(481-606)。
- cursor_test.go:正/反序 quick.Check(563,620)、仅桶/仅键值游标、Delete 语义。
- freelist_test.go:free/release/allocate/read/write 五步直测(12-141);node_test.go:put/read/write/split 与 split 最小键/单页特例(9-142);page_test.go:typ/dump/pgids 归并(11-50)。
- quick_test.go:定义 `-quick.count/seed/maxitems/maxksize/maxvsize` 五个 flag(24-35,默认 5 次迭代、1000 项、键值上限 1024),种子打印到 stderr 便于复现(33)。

**测试辅助设施(隐性不变量)**:所有测试经 `MustOpenDB()` 建库(db_test.go:1372-1378),包装后的 `Close()` 做**三件事**——可选打印统计(-stats flag,db_test.go:25 与 1403-1415)、对库跑一次 `MustCheck()` 一致性检查、删临时文件(1381-1393):

```go
// db_test.go:1380-1393 每个测试 teardown 都隐式做全库一致性检查
func (db *DB) Close() error {
    // Log statistics.
    if *statsFlag {
        db.PrintStats()
    }
    // Check database consistency after every test.
    db.MustCheck()
    // Close database and remove file.
    defer os.Remove(db.Path())
    return db.DB.Close()
}
```

`MustCheck()` 在 Update 事务里消费 `tx.Check()`,收集前 10 个错误,有错就拷贝出问题库、dump 现场并 panic(db_test.go:1417-1431 起始)。这意味着"每个测试结束时库必须可通过 tx.Check"是全测试套件的隐式断言。并发辅助用例 testDB_Close_PendingTx 用 goroutine + 100ms 双重 select 断言"有挂起事务时 Close 会等待"(db_test.go:469-508)。

**CI 双轨**:Makefile `test` 跑主包带覆盖率 + cmd 包(Makefile:14-16)、`errcheck` 静态检查(Makefile:11-12);appveyor.yml 在 Windows Server 2012 R2 上 `go test -v ./...`(appveyor.yml:3,17-18)。

**总览图(测试矩阵 / 工具链 / 错误面)**:

```
+---------------- 测试矩阵 (bolt_test, 5,649 行) ----------------+
| 随机模型   simulation_test.go:329   14 组 op x 并行度矩阵       |
|            QuickDB 影子模型逐值比对, panic 即失败 (:155)        |
| quick属性  quick_test.go:87 + cursor_test 正/反遍历 (:563,:620) |
|            bucket_test 补充 (:1696,:1756), flag 可调 (:24-35)   |
| 打开失败   db_test: ErrInvalid/VersionMismatch/Checksum (:88-180)|
|            (unsafe 直改 meta 页字节 = 最接近"故障注入"的手段)   |
| 布局断言   TestDB_Consistency meta/meta/free/free/leaf/freelist  |
|            (db_test.go:805-843, 硬编码页号)                     |
| 大数据     TestBucket_Put_Large(:173) / Delete_FreelistOverflow |
|            (bucket_test.go:383, 1e7 键写入后单事务全删)         |
| 竞态       Makefile: race = -race + TestSimulate_100/1000op(:8) |
| CI         appveyor.yml Windows Server 2012 R2, go test ./...   |
| 空白(纠偏) 无 Timeout 测试 / 无崩溃注入 / 无版本兼容测试集    |
+---------------- 工具链 (cmd/bolt/main.go, 1,740 行) -----------+
| bench(:901) check(:162) compact(:1558) dump(:306) info(:247)   |
| page(:433) pages(:670) stats(:764); main_test.go 仅 4 用例     |
+---------------- 错误面 (errors.go, 16 个哨兵) ------------------+
| DB级 : NotOpen / Open(死代码) / Invalid / VersionMismatch /    |
|        Checksum / Timeout                                      |
| Tx级 : TxNotWritable / TxClosed / DatabaseReadOnly              |
| KV级 : BucketNotFound / BucketExists / BucketNameRequired /     |
|        KeyRequired / KeyTooLarge / ValueTooLarge /              |
|        IncompatibleValue                                       |
+-----------------------------------------------------------------+
```

## 4. cmd/bolt:单文件 CLI 工具族(8 个子命令,带行号)

**纠偏④:cmd/bolt 没有 keys/get 子命令**(易与 bbolt 生态的浏览工具混淆);本 commit 的全部子命令由 `Main.Run` 的 switch 分发:`bench / check / compact / dump / info / page / pages / stats`(cmd/bolt/main.go:97-119),帮助文本 main.go:123-143。框架是"一命令一 struct",注入 Stdin/Stdout/Stderr(main.go:73-86),使 main_test.go 可直接测(main_test.go:20/33/73/192 仅 4 个用例:Info、Stats 空库、Stats、Compact)。

| 子命令 | 实现路径 | 做法 |
|---|---|---|
| check | main.go:162-214 | `bolt.Open` 后在 View 里消费 `tx.Check()` 通道逐行打印,计数 >0 返回 ErrCorrupt,否则 "OK"(189-213) |
| info | main.go:247-278 | 只打印一行 `Page Size: %d`(274-275),数据来自 `db.Info()` |
| dump | main.go:306-406 | 指定页号的十六进制视图;先 `ReadPageSize` 读 meta 拿页大小(334),`PrintPage`(363)输出 |
| page | main.go:433-502 | 不经 bolt.Open,直接 `os.Open` 原始文件按页号读(461-465,ReadPage:1359),按页类型分发 PrintMeta/PrintLeaf/PrintBranch/PrintFreelist(486-495,505/520/557/583)——所以能检查"打不开"的文件 |
| pages | main.go:670-730 | 在 `db.Update` 事务里循环 `tx.Page(id)`(703)打印全文件页表 ID/TYPE/ITEMS/OVRFLW,遇 overflow 页跳过其溢出块(723-726) |
| stats | main.go:764-846 | View 里对前缀匹配的所有桶 `b.Stats()` 聚合,输出页数/树深/字节利用率/内联桶占比(793-843) |
| bench | main.go:901-939 | write-mode seq/rnd/seq-nest/rnd-nest、read-mode seq/seq-nest(947-949),count 默认 1000、key 8B、value 32B(950-953),支持 cpuprofile/memprofile/blockprofile 与 `-no-sync`(954-958);非 `-work` 结束删临时库(908-913) |
| compact | main.go:1558-1686 | 源库以 **0444 只读**打开(1589),`walk` 递归遍历(1694-1722),目的库按 `-tx-max-size`(默认 64KB,1563)分批提交防内存膨胀(1619-1643,注释 1620),完成后打印 `%d -> %d bytes (gain=%.2fx)`(1614) |

工具自有错误族(main.go:26-56):ErrUsage/ErrUnknownCommand/ErrPathRequired/ErrFileNotFound/ErrCorrupt/ErrPageIDRequired/ErrPageNotFound/ErrPageFreed 等;并带一套绕过包 API 的裸页解析器 `page.Type()/leafPageElement()/key()/value()`(main.go:1480-1545)。`ReadPage` 先按 meta 页大小读一块、再看 overflow 重新整读(main.go:1359-1396);`ReadPageSize` 的注释自曝局限:"This is not transactionally safe"(main.go:1399)。main() 约定退出码:ErrUsage→2,其他→1(main.go:62-70)。

## 5. 错误面:16 个哨兵错误的分组与触发路径

errors.go 全文 71 行,三组 var 块(5-71),每个错误注释即契约。触发路径逐条核实:

| 错误 | 声明 | 触发点(非测试代码) |
|---|---|---|
| ErrDatabaseNotOpen | errors.go:9 | db.go:481、db.go:522(Begin 时未 open) |
| ErrDatabaseOpen | errors.go:13 | **无触发点(死代码,纠偏⑤)** |
| ErrInvalid | errors.go:17 | meta.validate magic 不符(db.go:984-985) |
| ErrVersionMismatch | errors.go:21 | meta.validate version!=2(db.go:986-987) |
| ErrChecksum | errors.go:24 | meta.validate 校验和不符(db.go:988-989) |
| ErrTimeout | errors.go:28 | flock 超时:bolt_unix.go:22、bolt_windows.go:68、bolt_unix_solaris.go:22 |
| ErrTxNotWritable | errors.go:35 | tx.go:149(对只读事务 Commit)、bucket.go:165/221/289/321/347/366、cursor.go:139 |
| ErrTxClosed | errors.go:39 | tx.go:147;bucket.go 各处 `b.tx.db == nil` 分支 |
| ErrDatabaseReadOnly | errors.go:43 | db.go:506-508(beginRWTx 入口) |
| ErrBucketNotFound | errors.go:50 | bucket.go:230(Bucket() 未命中) |
| ErrBucketExists | errors.go:53 | bucket.go:177(CreateBucket 已存在) |
| ErrBucketNameRequired | errors.go:56 | bucket.go:167(空名建桶) |
| ErrKeyRequired | errors.go:59 | bucket.go:291(零长键) |
| ErrKeyTooLarge | errors.go:62 | bucket.go:293(超 MaxKeySize) |
| ErrValueTooLarge | errors.go:65 | bucket.go:295(超 MaxValueSize) |
| ErrIncompatibleValue | errors.go:70 | bucket.go:179/232/304/330、cursor.go:145(桶/值身份冲突) |

```go
// bucket.go:286-296 Put 的完整校验链(KV 级错误面一览)
if b.tx.db == nil {
    return ErrTxClosed
} else if !b.Writable() {
    return ErrTxNotWritable
} else if len(key) == 0 {
    return ErrKeyRequired
} else if len(key) > MaxKeySize {
    return ErrKeyTooLarge
} else if int64(len(value)) > MaxValueSize {
    return ErrValueTooLarge
}
```

平台细节:Unix flock 是 50ms 轮询的 `LOCK_NB` 循环,超时才返回 ErrTimeout,且保证"至少尝试过一次 flock"(bolt_unix.go:14-36,注释 18-19);Linux 用真 `syscall.Fdatasync`(bolt_linux.go:9-12),其余 Unix 退化为 `file.Sync()`(boltsync_unix.go:4-7)。

## 6. 已知局限与陷阱(以源码/注释为准)

1. **单写者 + 同 goroutine 死锁**:`DB.Begin` 注释直说"opening a read transaction and a write transaction in the same goroutine can cause the writer to deadlock because the database periodically needs to re-mmap itself"(db.go:448-451);机制是 beginTx 对 mmaplock 取 RLock(db.go:475),而增长时 mmap() 需要写锁(db.go:246)。逃生门是 `Options.InitialMmapSize`(db.go:911-919;doc 注释 453-455)与"IMPORTANT: You must close read-only transactions"(db.go:457-458)。
2. **写放大/随机写慢**:README Caveats 第一条"Bolt is good for read intensive workloads……random writes can be slow",建议 DB.Batch 或外挂 WAL(README.md:775-777);根因是 B+tree 随机页访问 + COW 整页重写。
3. **长读事务膨胀**:COW 下"old pages cannot be reclaimed while an old transaction is using them"(README.md:782-783);写侧配合逻辑是 beginRWTx 找最小未关闭读事务 txid,`freelist.release(minid-1)` 只放出比它更老的 pending 页(db.go:530-539)。
4. **mmap 生命周期**:每次 mmap 先 `db.rwtx.root.dereference()` 再 munmap 旧映射、映射新尺寸、重挂 meta0/meta1(db.go:266-283);尺寸策略从 32KB 起倍增至 1GB,之后按 1GB 步进,封顶 maxMapSize(db.go:305-340;amd64 256TB=bolt_amd64.go:4,386 平台 2GB=bolt_386.go:4)。事务结束后继续用键值切片可能踩到已 unmap 的地址——README 明说会看到 `unexpected fault address` panic(README.md:785-788)。
5. **页撕裂与 fdatasync 顺序(两阶段提交)**:`Commit` 顺序为 rebalance → spill → 释放旧 freelist 并分配新 freelist 页(注释承认"会高估 freelist 尺寸",tx.go:174-176)→ grow → `tx.write()`(脏页按 pgid 排序 writeAt + **fdatasync**,tx.go:474-524)→ StrictMode 可选 Check(tx.go:205-218)→ `tx.writeMeta()`(写 meta 页 + **第二次 fdatasync**,tx.go:547-567)。README 把失效语义讲透:"部分写坏的数据页会被忽略,因为指向它们的 meta 页永远不会写;部分写坏的 meta 页因校验和而失效"(README.md:869-875)。`grow` 在非 Windows 上先 Truncate 再 Sync 以保住文件尺寸元数据(issue #284,db.go:873-884),**Windows 分支不做 Truncate**(db.go:876)。
6. **文件只增不减**:页布局决定"Bolt cannot truncate data files and return free pages back to the disk",删大数据不还磁盘,空间进 freelist 复用(README.md:819-824,官方链接 issue #308,README.md:826-828)。
7. **其他显式陷阱**:FillPercent 过高 + 随机插入劣化页利用率(README.md:793-795);桶要尽量大,超过页大小(典型 4KB)的小桶利用率差(README.md:797-798);单事务塞 10 万+ 随机键不建议,因为 spill 推迟到 commit(README.md:800-803);数据文件与端序绑定,不能跨大小端机器拷贝(README.md:814-817);mmap 意味着"高内存占用是正常的"(README.md:805-812);多进程共享被文件锁禁止(README.md:790-791;锁语义 db.go:179-189,写独占/读共享)。

## 7. 生态位:bbolt、LMDB 血统与使用方

- **LMDB 血统(源码依据)**:doc.go:13 "The design of Bolt is based on Howard Chu's LMDB database project";README 比较章:同构点为 B+tree、全可串行化 ACID、单写者多读者的 lock-free MVCC(README.md:754-756);分歧点为 LMDB 打开时要指定 mmap 上限而 Bolt 自动增量重映射、LMDB 用 flag 重载 getter/setter 而 Bolt 拆成独立函数(README.md:764-767)。
- **bbolt 分叉**:README.md:38-39 指向 CoreOS 分叉 bbolt 作为"more featureful version"(源码依据)。bbolt 后续新增能力的方向——NoFreelistSync、Mlock、Unsafe(绕过只读映射)、库内 Compact、Commit 时间统计等——属**通识,未核实源码**;本版可对照的需求痕迹:fdatasync 双次提交(tx.go:520-524,557-561)、freelist 每事务整页重写(tx.go:176-185)、compact 只存在于 CLI(cmd/bolt/main.go:1558)。
- **使用方**:README 官方列表含 Consul、InfluxDB、bleve、cayley、btcwallet、ledisdb、SeaweedFS、Storm 等 50+ 项(README.md:883-935);etcd 经 bbolt 间接使用 Bolt 格式属**通识,未核实源码**(README 列表未直接点名 etcd)。
- **周边生态**:README 还列了 ORM(Storm,920)、会话存储(BoltStore,897)、CLI 查看器(bolter,928)、封装库(buckets/stow/mbuckets,911-915)等,显示"嵌入式 KV + Go 社区"的生态位;gomobile 绑定支持 iOS/Android(README.md:627-657)。
- **与关系库/LSM 的官方对比(README 有据)**:对 Postgres/MySQL,差异是"库内嵌进程 vs 独立服务器 + 按键访问 vs SQL"(README.md:716-730);对 LevelDB/RocksDB,差异是 B+tree 单文件 vs LSM 多层 SSTable,并给出选型阈值"随机写 >10,000 w/sec 或机械盘选 LevelDB,读多/范围扫描选 Bolt"(README.md:733-744);还强调 LevelDB 无事务,而 Bolt 提供全可串行化 ACID(README.md:746-749)。RFC3339Nano 不可排序的坑也有官方提示(README.md:449)。

## 8. FAQ 候选与深挖方向

**FAQ 候选(12 条,每条一句话答案)**:
1. 为什么 Bolt 崩溃后不需要恢复日志?——双 meta 页+校验和+两阶段提交使未提交数据天然不可见,两张 meta 都坏才算库坏(db.go:285-292;README.md:869-875)。
2. 同一 goroutine 先开 View 再开 Update 会怎样?——可能死锁:写事务增长要重映射 mmap,而读事务握着 mmaplock.RLock(db.go:448-451,475)。
3. 打开被别的进程占用的库会怎样?——默认永久阻塞等文件锁,传 `Options.Timeout` 才会超时返回 ErrTimeout(db.go:896-899,924-927;bolt_unix.go:22)。
4. db.go 注释说 Timeout "only available on Darwin and Linux"(db.go:897-898)准确吗?——不完全:Windows/Solaris 的 flock 同样实现了 ErrTimeout 路径(bolt_windows.go:68;bolt_unix_solaris.go:22)。
5. 删掉一大半数据文件会变小吗?——不会,Bolt 不截断文件,空间只进 freelist 供复用(README.md:819-824)。
6. `bolt check` 都查什么?——四类:页被双引用、reachable 但已在 freelist、unreachable unfreed、越界/非法类型(tx.go:383-445;错误文案 cmd/bolt/main.go:869-873)。
7. compact 动原库吗?——不动:源库以 0444 只读方式打开、只读遍历(cmd/bolt/main.go:1589;Usage 自述 1732)。
8. bench 跑完为什么目录里没有库文件?——非 `-work` 模式下临时库在结束时被删除(cmd/bolt/main.go:908-913)。
9. NoSync 到底跳过了什么?——跳过 tx.write 与 writeMeta 各自的 fdatasync,OpenBSD 上被 IgnoreNoSync 强制无视(db.go:29-30;tx.go:520-524,557-561)。
10. 32 位平台上限是多少?——maxMapSize 2GB(bolt_386.go:4),故 README 提醒超大库在 32 位系统可能出问题(README.md:810-812)。
11. `bolt page` 为什么能看已损坏的库?——它绕过 bolt.Open,直接 os.Open 按 meta 里记录的页大小裸读页字节(cmd/bolt/main.go:461,1359,1399)。
12. 测试如何保证"每个用例结束时库仍是好的"?——包装的 Close() 对每个测试库隐式跑 MustCheck(),有错即 panic 并 dump 现场(db_test.go:1381-1393,1417-1431)。

**深挖方向(5 条)**:
1. simulation_test.go 的 QuickDB 模型检查升级为现代 property-based 测试 + 全矩阵 `-race`(现在 Makefile race 只跑 100op/1000op 两档,Makefile:7-8)。
2. tx.write() 逐页 writeAt 与 TODO "vectorized I/O"(tx.go:152)对照 bbolt 的写合并,量化写放大差异。
3. Windows 不 Truncate 的 grow 路径(db.go:875-884)在崩溃时刻的暴露面:文件尺寸元数据与 meta.pgid 不一致时会发生什么。
4. flock 50ms 轮询实现(bolt_unix.go:26-36)在容器/网络文件系统上的行为,以及 README "hang until the other process closes it" 的实测(README.md:117-120)。
5. 兼容性缺口:仅凭 version=2 单点校验(db.go:982-992)的演进策略 vs bbolt 后续格式变更,能否构造"version 仍为 2 但语义已变"的分歧文件。

## 正文蒸馏要点

1. README 自报版本 1.2.1,定位"简单、快速、可靠、无需数据库服务器",灵感来自 LMDB(README.md:1-7)。
2. 维护状态:作者告别信宣布项目 complete、停止维护,指向 CoreOS 的 bbolt 分叉(README.md:26-39);"已归档"是仓库状态,README 原文无该词。
3. Project Status 承诺 stable + API/格式冻结 + 随机化黑盒测试 + 1TB 生产规模(README.md:18-22)。
4. doc.go 是规格书:全可串行化、ACID、无锁 MVCC 单写者、零拷贝 B+tree、崩溃免恢复、只读映射防写坏(doc.go:2-40)。
5. 测试核心是 simulation_test.go 的并发随机操作 + QuickDB 影子模型比对:14 组矩阵、20% 写者、可复现种子、panic 即失败(simulation_test.go:13-28,36,57,155)。
6. 三个测试空白:无 Timeout 测试、无崩溃注入、无版本兼容测试集;兼容仅靠 magic/version 单点校验(db.go:982-992)。
7. 工程配套:Makefile race 目标专跑 TestSimulate(Makefile:7-8)+ errcheck(Makefile:11-12);appveyor 补 Windows CI(appveyor.yml:17-18)。
8. cmd/bolt 八个子命令 bench/check/compact/dump/info/page/pages/stats(main.go:97-119);page/dump 直读裸文件不经包 API(main.go:461,1359);compact 源库 0444 只读、64KB 分批提交(main.go:1589,1563,1631)。
9. ErrDatabaseOpen 是死代码(errors.go:13,全仓无返回点);ErrTimeout 只产自三个平台的 flock(bolt_unix.go:22 等);ErrCorrupt 等 10 个错误属于工具层(main.go:26-56)。
10. 两阶段提交 = 脏页 fdatasync 后再写 meta 再 fdatasync;数据页损坏因"永不指向"失效、meta 损坏因校验和失效(tx.go:474-567;README.md:869-875)。
11. 单写者死锁根源是 mmap 重映射要写锁而读事务持读锁(db.go:448-451,475);长读事务的页回收由 beginRWTx 的 minid-1 release 决定(db.go:530-539)。
12. 三大运维陷阱:文件只增不减(README.md:819-824)、Windows grow 不 Truncate(db.go:876)、数据文件绑定端序(README.md:814-817)。
