# E — Healing(自愈)与 Data Scanner(数据扫描器)

> 《MinIO 深读》卷一 第 5 章背景材料
> 源码:minio/minio @ commit `7aac2a2`(2026-02-12)
> 本文所有行号均以该 commit 的仓库相对路径标注,并经 grep/Read 逐一核对。

MinIO 有两个常驻后台子系统:**data scanner**(数据扫描器)负责"巡查"——统计对象数/大小、执行 ILM 生命周期、按概率抽样触发 heal;**healing**(自愈)负责"治疗"——比对各盘元数据与分片,重写缺失/损坏的数据。两者通过 MRF(most recently found,最近发现队列)与后台 heal 序列衔接。

---

## 1. 全景:两个后台子系统如何协作

```
                        ┌──────────────────────────────────────────────────┐
                        │              runDataScanner (每 cycle)            │
                        │  cmd/data-scanner.go:155  (持 leader.lock :156)  │
                        └───────────────┬──────────────────────────────────┘
                                        │ objAPI.NSScanner(..., scanMode)  :205
                    ┌───────────────────┴────────────────────┐
                    │      erasureServerPools.NSScanner      │ erasure-server-pool.go:735
                    │   每个 erasure set 一个 goroutine 并发   │
                    └───────┬────────────────────────────────┘
                            │ disk.NSScanner → scanDataFolder  data-scanner.go:307
                            ▼
              ┌───────────────────────────────┐
              │  folderScanner.scanFolder:399 │  逐盘遍历目录树(readDirFn :441)
              │  每个条目前先睡(dynamicSleeper) │  :435-437 / :489-492
              └──────┬───────────────┬────────┘
      ① 统计/ILM     │               │  ② heal 线索(三条路)
                     ▼               ▼
   ┌─────────────────────────┐   ┌───────────────────────────────────────┐
   │ scannerItem.applyActions │   │ a. 抽样: 1/1024 对象做 heal check      │
   │ data-scanner.go:1036     │   │    item.heal.enabled  :506             │
   │  · ILM Eval      :1095   │   │ b. 消失目录: abandonedChildren         │
   │    → enqueueByDays:1309  │   │    → queueHealTask    :723/:781/:797   │
   │    → queueTransition:1206│   │ c. bitrot 抽查(deep scan cycle)       │
   │  · 抽样 heal: applyHealing│   │    getCycleScanMode   :89              │
   │    → HealObject  :968    │   └──────────────┬────────────────────────┘
   │  · replication heal:1318 │                  │
   └──────────┬──────────────┘                  ▼
              │                     ┌───────────────────────────────┐
              ▼                     │  MRF 队列 mrfState.opCh       │ cmd/mrf.go:73
   ┌─────────────────────┐          │  容量 100000      :39         │
   │ .usage.json(统计落盘)│          │  非阻塞,满即弃    :94-97      │
   │ data-usage.go:58     │          └──────────────┬────────────────┘
   └─────────────────────┘                          │ healRoutine :218
                                                    ▼
   ┌────────────────────────────────────────────────────────────────┐
   │              healRoutine workers(tasks channel)                │
   │   background-heal-ops.go:113 AddWorker → objAPI.HealObject:132 │
   │   worker 数 = GOMAXPROCS/2(MINIO_HEAL_WORKERS 可覆盖):157      │
   └──────────────────────────────┬─────────────────────────────────┘
                                  ▼
   ┌────────────────────────────────────────────────────────────────┐
   │      erasureObjects.healObject   erasure-healing.go:295        │
   │  读全部盘 xl.meta(:333)→ 选 quorum 最新元数据(:368/:372)      │
   │  → 逐盘判定 heal 需求(:404 shouldHealObjectOnDisk)            │
   │  → 用健康分片 erasure.Heal 重写(:603)→ RenameData 回填(:663)  │
   └────────────────────────────────────────────────────────────────┘

   第四个触发源:换盘/掉盘 → initAutoHeal + monitorLocalDisksAndHeal
   cmd/background-newdisks-heal-ops.go:373 / :559 → healFreshDisk :415
```

统计与 ILM 是 scanner 的"产出",heal 是 scanner 与读写路径共同投递给 heal worker 池的"工单"。ILM 的评估与执行入口在 scanner,但真正的删除由 `globalExpiryState`(按天过期)与 `globalTransitionState`(冷转)两个独立 worker 池异步完成(data-scanner.go:1308、:1206)。

---

## 2. Scanner 专节:一次"全集群慢速普查"

### 2.1 cycle 调度与单实例约束

`initDataScanner` 在 server-main.go:1053 被拉起(`_MINIO_SCANNER=off` 可整体关闭),死循环执行 `runDataScanner`,两轮之间随机睡 0~1 个 cycle(data-scanner.go:79-85)。cycle 长度由配置 `scanner speed` 决定,默认 `default` = delay 2 / maxWait 1s / cycle 1min(internal/config/scanner/scanner.go:163-164),共五档 fastest→slowest(scanner.go:159-168)。

```go
// cmd/data-scanner.go:155-157, :205
func runDataScanner(ctx context.Context, objAPI ObjectLayer) {
	ctx, cancel := globalLeaderLock.GetLock(ctx)   // 全集群只有一把 leader.lock
	defer cancel()
	...
	err := objAPI.NSScanner(ctx, results, uint32(cycleInfo.current), scanMode)
```

`globalLeaderLock` 是基于对象层的分布式锁 `"leader.lock"`(erasure-server-pool.go:192),保证**整个集群同一时刻只有一个 scanner 在跑**(注释见 data-scanner.go:154)。cycle 编号持久化在 `buckets/.bloomcycle.bin`(data-usage.go:37)——文件名是 bloom 时代遗留,如今只存 8 字节 cycle 计数器加 msgpack 元信息(data-scanner.go:162-170、:221-225),**并不再有 bloom 全量索引**;真正的"索引"是增量维护的 `dataUsageCache` 树(`.usage-cache.bin`,data-usage.go:41)。

### 2.2 深浅扫描:bitrot 什么时候查

每轮 cycle 开始时用 `getCycleScanMode` 决定本轮是 `HealNormalScan` 还是 `HealDeepScan`(data-scanner.go:89-107):

- `heal bitrotscan = off`(默认)→ 永远 Normal;`= on` → 永远 Deep;
- 配置为时间间隔时,若距上次 deep 不足 `healObjectSelectProb=1024` 个 cycle,或距 deep 开始时间超过配置间隔,则进入 Deep(data-scanner.go:98-104)。

Normal 扫描只比对元数据与文件存在性;Deep 扫描额外把 `item.heal.bitrot` 置真(data-scanner.go:507),落到 heal 侧就是对每个分片做 bitrot 校验(见 3.3)。

### 2.3 遍历:目录树 + 压缩缓存 + 16-cycle 分摊

`scanDataFolder`(data-scanner.go:307)→ `folderScanner.scanFolder`(data-scanner.go:399)用 `readDirFn` 逐层列目录(:441),对每个文件条目构造 `scannerItem` 并调用 `getSize` 回调。erasure 模式下找到对象即 `break`,不再下钻数据目录(:541-544)。

扫描器真正的"省力"设计是把缓存树**按子树压缩(compaction)**:叶子里对象数 < 500、单目录子目录数 ≥ 2500(或强制 250000)、或纯对象目录,都会被压缩成一个带总量叶子(data-scanner.go:52-55、:266-301 注释、:842-878)。已压缩分支并非每轮都重扫,而是按路径哈希分摊到 **16 个 cycle**(data-scanner.go:51 `dataUsageUpdateDirCycles=16`,判定在 :656-661):

```go
// cmd/data-scanner.go:656-668
if !into.Compacted && f.oldCache.isCompacted(h) {
	if !h.mod(f.oldCache.Info.NextCycle, dataUsageUpdateDirCycles) {
		// 未轮到:直接把上一轮的统计搬过来
		f.newCache.copyWithChildren(&f.oldCache, h, folder.parent)
		into.addChild(h)
		continue
	}
	// 轮到了:heal 概率相应放大 16 倍
	folder.objectHealProbDiv = dataUsageUpdateDirCycles
}
```

`mod`/`modAlt` 都是 xxhash 路径名取模(data-usage-cache.go:314-330),所以哪些目录本轮被扫描是**确定性伪随机**的,不依赖任何状态。另外 bucket 顺序每轮洗牌(erasure.go:410-416),避免各 set 总以相同顺序扫同样的 bucket;单盘扫描并发数不超过 GOMAXPROCS(erasure.go:472-476)。

### 2.4 速率控制:dynamicSleeper(呼应"bucket 限速"思想)

扫描器几乎每个动作前都问一句 `weSleep()`——它的实现是"集群非空闲就睡"(xl-storage-disk-id-check.go:247-249,`scannerIdleMode==0`,即 `scanner idle_speed` 默认开启)。睡眠本身由 `dynamicSleeper` 完成(data-scanner.go:1365-1468):

```go
// cmd/data-scanner.go:1410-1426(节选)
func (d *dynamicSleeper) Sleep(ctx context.Context, base time.Duration) {
	for {
		...
		wantSleep := time.Duration(float64(base) * factor) // base×倍率
		if wantSleep <= minWait { return }                 // <100µs 不睡
		if maxWait > 0 && wantSleep > maxWait { wantSleep = maxWait }
		timer := time.NewTimer(wantSleep)
		select {
		case <-ctx.Done(): ...
		case <-timer.C:    ...
		case <-cycle:      // 配置热更新时,中断旧睡眠按新参数重睡
		}
	}
}
```

默认 factor=2、maxWait=1s(data-scanner.go:66);目录间固定睡 `1ms×2`(:50、:435-437),对象级则用 `Timer()` 把"处理耗时"本身也乘倍率补睡(:1400-1406)。`mc admin config set` 改 speed 后调用 `Update()`,SafeClose cycle channel 让所有等待者立刻按新参数重睡(:1456-1468)。这些让出的时间都被记进 `scannerMetricYield` 指标(:1432、:1438),可通过 `/minio/v3/metrics/scanner` 观测(data-scanner-metric.go:52、:289)。

heal 侧有一个独立 sleeper:`healSleeper = newDynamicSleeper(5, time.Second, false)`(mrf.go:213),MRF 重试每个对象之间睡 5 倍处理时长;管理员 API 发起的整盘 heal 还有第三层闸门 `waitForLowHTTPReq`:HTTP 在途请求 ≥ `heal max_io`(默认 100)时按 100ms 步进等待(background-heal-ops.go:63-100,调用点 global-heal.go:505、admin-heal-ops.go:915)。

### 2.5 产出一:统计(.usage.json)

getSize 回调(cmd/xl-storage.go:594-685)只认 `xl.meta/xl.json` 文件(:596-600),读元数据(:608)、拆出所有版本成 `[]ObjectInfo`(:619-630),然后交给 `applyActions`。统计累加发生在其 accounting 回调里(:649-677):totalSize、versions、deleteMarkers、按 storage class/tier 分桶等。聚合链路是:set 内合并 → `erasureServerPools.NSScanner` 每 30s merge 一次全池结果并输出 `DataUsageInfo`(erasure-server-pool.go:796-834)→ `storeDataUsageInBackend` 写成 `buckets/.usage.json`(data-usage.go:45-63,每 10 次写一个 `.bkp`)。`mc admin usage`、控制台 dashboard、`dui()`(data-usage-cache.go:425-443)读的都是这个对象。

### 2.6 产出二:ILM 评估

`applyActions` 里,若 bucket/prefix 有活跃 ILM 规则,则调用 `lifecycle.NewEvaluator(...).Eval(objOpts)`(data-scanner.go:1095-1096)逐事件分发(:1119-1148):

- `DeleteAllVersionsAction` → `applyExpiryRule` → `globalExpiryState.enqueueByDays`(:1122、:1308-1310);
- `DeleteVersionAction`(非当前版本过期)→ 收集进 `toDel`,最后 `globalExpiryState.enqueueNoncurrentVersions`(:1132-1141、:1158-1160);
- `TransitionAction` → `applyTransitionRule` → `globalTransitionState.queueTransitionTask`(:1144-1145、:1202-1208);
- `NoneAction`(无需 ILM 动作)→ 顺便做 heal/replication 检查(:1147-1148)。

这就是 C 报告"ILM 由扫描器驱动"的代码落点:**过期不是定时器,而是等扫描器扫到才评估**;评估结果也只是入队,真正的删除/转冷由独立 worker 池执行并自带限速。

### 2.7 产出三:heal 线索

三条路,全部汇入后台 heal 序列(`bgHealingUUID = "0000-0000-0000-0000"`,global-heal.go:44):

1. **抽样 heal check**:erasure 模式下 `healObjectSelect = healObjectSelectProb = 1024`(data-scanner.go:59、:353-356),每个对象被 `modAlt(cycle/概率除数, 1024/除数)` 选中后走 `applyHealing → HealObject`(:506、:968),即**平均每个对象每 1024 个 cycle 被完整体检一次**;deep 轮还会带上 bitrot。
2. **消失条目回查**:上一轮存在、本轮没扫到的 `abandonedChildren`,用 `listPathRaw` 跨盘确认(:677-733):要么是删了,要么是"这台盘错过了写"——后者通过 `bgSeq.queueHealTask` 找回(:723、:781、:797),这就是 scanner→MRF 之外的直接 heal 投递通道。
3. **dangling 清理**:heal check 通过后还会 `CheckAbandonedParts` 删除不再被 xl.meta 引用的残留 data-dir(:1047-1054,实现 erasure-healing.go:689-721)。

### 2.8 产出四:告警事件

版本数 ≥ 100(`scanner alert_excess_versions`)或单对象累计版本体积 ≥ 1TB 时发 `ObjectManyVersions/ObjectLargeVersions` 事件与审计日志(data-scanner.go:975-1028,阈值 :69-70);单目录子前缀 ≥ 50000 发 `PrefixManyFolders`(:551-572)。

---

## 3. Healing 专节:healObject 的比对与修复

### 3.1 触发四源与队列

| 触发源 | 入口 | 投递方式 |
|---|---|---|
| 管理员 `mc admin heal` | admin-heal-ops.go:474 `newHealSequence` → :716 `queueHealTask` | tasks channel,带 respCh 同步等结果 |
| scanner 抽样/回查 | data-scanner.go:968 / :723 | queueHealTask(MRF 类,带 respCh) |
| 读写路径报错(MRF) | erasure-object.go:403(GET 重建成功但发现损坏)、:806(删除时缺块)、:2153 `addPartial`;erasure-multipart.go:1473;peer-s3-client.go:269(启动时 bucket 丢 quorum) | `globalMRFState.addPartialOp`,非阻塞 |
| 换盘/重启 | background-newdisks-heal-ops.go:373 `initAutoHeal`、:559 `monitorLocalDisksAndHeal` | `healFreshDisk`(:415)整 set 遍历重写 |

MRF 是核心的"用户流量驱动"通道。写对象时有盘离线/丢 quorum,只要满足读 quorum 就照常返回成功,同时把 (bucket, object, versionID) 塞进 `opCh`;等盘回来后由 `healRoutine` 补写。队列容量 **100000**(mrf.go:39),**满即丢弃**——新操作继续覆盖 MRF 语义:反正下次读写还会再发现(mrf.go:94-97 用 `select/default` 丢弃):

```go
// cmd/mrf.go:218-278(节选)
func (m *mrfState) healRoutine(z *erasureServerPools) {
	for {
		select {
		...
		case u, ok := <-m.opCh:
			...
			if now.Sub(u.Queued) < time.Second {
				time.Sleep(time.Second)   // 给刚断的网络 1s 重连窗口
			}
			wait := healSleeper.Timer(context.Background()) // 5× 处理时长
			scan := madmin.HealNormalScan
			if u.BitrotScan { scan = madmin.HealDeepScan }   // 损坏→深度扫
			...healObject(u.Bucket, u.Object, u.VersionID, scan)
			wait()
		}
	}
}
```

MRF 还会**持久化**:shutdown 时把队列 msgpack 序列化写进任一本地盘的 `buckets/.heal/mrf/list.bin`(mrf.go:102-153),重启后 `startMRFPersistence` 回放并删除(mrf.go:155-211)。GET 读路径的触发点值得一看——数据能从其余盘重建时照样服务客户端,同时静默排队 heal(erasure-object.go:400-417),`errFileCorrupt` 会带上 `BitrotScan: true` 要求深扫。

### 3.2 healObject 主流程(cmd/erasure-healing.go:295-684)

注:仓库中**没有** `cmd/heal-object.go`;对象 heal 的实现就是 `erasure-healing.go` 的 `healObject`,对外入口是 `HealObject`(:1060)。

1. **加锁**(:322-330):对 bucket/object 取 NSLock,防止与用户写并发(除非 `opts.NoLock`)。
2. **读全部盘元数据**(:333):`readAllFileInfo` 拉取每个盘的 `xl.meta`;全部 NotFound 直接返回(:334-342)。quorum 算不出来则 `deleteIfDangling` 处理悬挂对象(:344-361)。
3. **选最新元数据**:`listOnlineDisks` 按 modtime+ETag 选 quorum 版本(:368),`pickValidFileInfo` 得到 `latestMeta`(:372)。
4. **校验分片**(:380):`checkObjectWithAllParts`(erasure-healing-common.go:291-440)逐盘比对——元数据 modtime/DataDir/ETag 与 latest 不一致即 `errFileCorrupt`(:342-353);内联数据直接 `bitrotVerify`(:398-406);盘上 part 文件,Normal 扫描用 `CheckParts`(存在性+大小),Deep 扫描用 `VerifyFile`(逐 shard bitrot 校验)(:414-422)。
5. **逐盘判定**(每盘调 `shouldHealObjectOnDisk`,erasure-healing.go:178-205):`errFileNotFound/errFileVersionNotFound/errFileCorrupt` → 重写元数据+数据;`XLV1`(旧格式)→ 一律重写升级;`latestMeta.Equals(meta)` 不成立 → 过期元数据;part 缺失/损坏 → 只重写数据。
6. **不可修复判定**(:438-453):需要修的 xl.meta 数超过 parity,或某 part 缺失数超过 parity → 修不了,转 `deleteIfDangling`(:458)。dry-run 在此之前返回(:434-436)。
7. **重写**(:557-646):对每个 part,健康盘用 `newBitrotReader` 读分片(:578),目标盘写到 `.minio.sys/tmp/<uuid>/`(:587-597),`erasure.Heal` 纠删码重建(:603);成功后 `RenameData` 原子改名回最终位置并 `SetHealing()`(:652-663),最后清理 tmp(:649)。

`HealObject` 包装层(:1060-1108)还有个细节:目录对象走专门的 `healObjectDir`(:1073,实现 :725);Normal 扫描如果撞到 `errFileCorrupt`,**自动升级为 Deep 再 heal 一次**(:1101-1106)——这就是"bitrot 校验失败重写"的兜底:平时不校验内容,一旦读出损坏,单对象就地深扫修复。

### 3.3 并发与优先级

- **worker 池**:`newHealRoutine` 默认 `GOMAXPROCS/2` 个 worker(background-heal-ops.go:157),`MINIO_HEAL_WORKERS` 可调;tasks channel 无缓冲(:172),`queueHealTask` 的 `noWait` 模式在打满时直接放弃(admin-heal-ops.go:732-743),不反压用户路径。
- **整盘 heal(healErasureSet,global-heal.go:152)**:worker 数 `max(4, 请求数/4 或核数/4)`,`MINIO_HEAL_DRIVE_WORKERS` 可覆盖(:195-208);用 `workers` 包做有界并发(:212),每个对象 heal 前都要过 `waitForLowHTTPReq`(:505)。
- **优先用户流量**:三层限速——MRF 的 healSleeper(5×)、扫描器 dynamicSleeper(2×,idle 才睡)、admin heal 的 max_io 闸门;heal 写入走 tmp+rename,不阻塞正常读写锁路径。

---

## 4. 设计动机

**为什么扫描器要"慢"?** MinIO 把 scanner 定位成"空闲时间的背景普查":所有睡眠都乘上倍率、有上限、且集群有请求时(`idle_speed` 默认 on)才生效。省下的是 IO/CPU,换来的是"最终一致"的统计与 ILM。它的每项产出都能容忍滞后:usage 数字晚几分钟、ILM 晚几个 cycle、heal 线索晚几个 cycle 都不影响正确性——一旦不能容忍(用户在读损坏对象),就走 MRF 实时通道,两种通道互补。

**为什么 heal 要"按需 + 巡检"双触发?** 按需(读写 MRF、换盘)保证**已感知的损坏被尽快修复**且修复的是用户真正访问的数据,天然带热度优先级;巡检(scanner 1/1024 抽样 + 16-cycle 目录分摊 + 周期性 deep bitrot 轮)保证**无人访问的冷数据**也不会烂在盘上。抽样率(1024)与分摊周期(16)是错误发现速度与巡检成本的折中:全量 bitrot 巡检在大集群上代价不可接受,概率采样让期望发现时间有界。

**为什么统计靠扫描而不是实时计数?** 对象元数据(xl.meta)分散在 erasure set 各盘上,实时维护全局计数要么引入跨盘事务/聚合锁,要么需要集中式计数器(可用性牺牲)。MinIO 选择"每个 cycle 用扫描器增量重算 + usage.json 快照":实现零新增状态、崩溃自愈(重扫即可),代价是数字有最长约一个 cycle 的滞后。`dui()`、admin usage、配额告警都消费同一快照,口径统一。

**为什么缓存树要压缩 + 16-cycle 分摊?** 让 scanner 的内存与 IO 开销与"目录结构复杂度"而非"对象总数"成正比:压缩叶子只存总量,绝大多数 cycle 只做 O(目录数) 的搬运而非 O(对象数) 的 IO。这是它敢承诺"default 速度下扫描不影响业务"的根本。

---

## 5. FAQ 素材

1. **Q: heal-object.go 在哪?** A: 不存在。对象 heal 实现在 `cmd/erasure-healing.go:295`(`healObject`),入口 `HealObject`(:1060)。
2. **Q: `.bloomcycle.bin` 里是 bloom 过滤器吗?** A: 不是。文件名是历史遗留(data-usage.go:37),现在只存 8 字节 cycle 计数 + 少量元信息(data-scanner.go:162-170),bloom 索引方案早已移除。
3. **Q: scanner 会在多节点重复跑吗?** A: 不会。`runDataScanner` 先取全局 `leader.lock`(erasure-server-pool.go:192 / data-scanner.go:156),整集群单实例;但扫描的"读盘"动作分布在各节点本地盘上。
4. **Q: 一个对象多久被完整 heal 体检一次?** A: 期望每 1024 个 cycle 一次(`healObjectSelectProb`,data-scanner.go:59);被压缩目录里的对象概率被 `objectHealProbDiv=16` 补偿(:668),所以无论目录大小,抽样率一致。默认 cycle 1min 时约 17 小时/对象,deep bitrot 轮另行配置。
5. **Q: MRF 队列满了会怎样?** A: 丢弃(mrf.go:94-97)。语义是安全的:该对象下次读写仍会触发 addPartialOp;队列容量 100000(:39),shutdown 时落盘 `.heal/mrf/list.bin` 重启回放(:147、:199)。
6. **Q: Normal heal 会发现数据内容损坏吗?** A: 不主动校验 bitrot,但读路径读到 `errFileCorrupt` 会触发 MRF(带 `BitrotScan: true`,erasure-object.go:410);且 `HealObject` 在 Normal 扫描撞到 corrupt 时自动升级 Deep 再修(erasure-healing.go:1101-1106)。
7. **Q: heal 修复会覆盖刚写入的新版本吗?** A: 不会。healObject 先取 NSLock(:322),且只重写 `latestMeta` 所在 quorum 版本;`SetHealing()` 标记(:661)让写路径识别 heal 写入。
8. **Q: 修不过来怎么办(parity 都不够)?** A: `cannotHeal` 判定后走 `deleteIfDangling`(erasure-healing.go:438-458),按悬挂对象策略删除或保留可读版本,不会无限重试。
9. **Q: ILM 过期是定时任务吗?** A: 不是,由 scanner 在 `applyActions` 里逐对象评估(data-scanner.go:1095);评估后入 `globalExpiryState`/`globalTransitionState` 队列异步执行,所以 ILM 生效延迟与扫描周期直接相关。
10. **Q: `mc admin heal --dry-run` 做什么?** A: 完整执行 1-5 步(读元数据、比对、判定),在真正写盘前返回(erasure-healing.go:434-436),`Before.Drives` 已填好各盘状态。

## 6. 深挖方向

1. **`mod` vs `modAlt` 的哈希错位设计**(data-usage-cache.go:314-330):两者取 xxhash 的低/高 32 位,故意不同步——目录轮转调度(`mod`)与对象 heal 抽样(`modAlt`)互不相关,避免"同目录对象总在同一轮被抽中"。
2. **MRF 持久化格式**(mrf.go:112-139):4 字节头(format+version)+ msgp 流式编码的 `PartialOperation`;多盘冗余写(任一本地盘成功即止,:145-152),读时任一盘可用即回放(:195-210)——用存储自身保证 MRF 不因重启丢失。
3. **erasure.Heal 的读写不对称**(erasure-healing.go:557-646):reader 只建在 `checkPartSuccess` 的盘上,writer 建在 outdated 盘上,`prefer` 局部盘优先;写坏( writers[i]==nil / closeErrs)会动态削减 `disksToHealCount`,全部失败才报错(:612-645)。
4. **scanner 指标体系**(data-scanner-metric.go:35-86):每种操作计数 + 最近一分钟延迟直方图,ILM 动作单独计数(`actions [lifecycle.ActionCount]`),yield 时间单列——是调 `scanner speed` 的观测依据。
5. **换盘 heal 的断点续传**(background-newdisks-heal-ops.go:47-110 `healingTracker`):进度持久化在 `.healing.bin`,重试时 `resume()` 从上次 bucket/object 继续(global-heal.go:274-284),失败自动重试至多 3 次(:496-506)。

---

## 7. 写作要点速查表

| # | 内容 | 位置 |
|---|---|---|
| 1 | 扫描器常量:1ms/目录、16-cycle 分摊、压缩阈值、启动延迟 | cmd/data-scanner.go:50-56 |
| 2 | heal 抽样概率 1/1024 与 dangling 删除开关 | cmd/data-scanner.go:58-59 |
| 3 | scannerSleeper(2×,1s 上限)、cycle、idle 等原子配置 | cmd/data-scanner.go:66-71 |
| 4 | runDataScanner:leader.lock + NSScanner 调度 | cmd/data-scanner.go:155-232(:156/:205) |
| 5 | deep/normal 扫描轮换判定 | cmd/data-scanner.go:89-107 |
| 6 | 压缩目录跳过 + heal 概率除数 16 | cmd/data-scanner.go:656-669 |
| 7 | 对象 heal 抽样命中表达式 modAlt | cmd/data-scanner.go:506 |
| 8 | ILM Eval 分发(删除/版本删/转冷/None→heal) | cmd/data-scanner.go:1119-1148 |
| 9 | dynamicSleeper.Sleep(倍率睡眠,热更新) | cmd/data-scanner.go:1410-1452 |
| 10 | MRF 队列容量 100000、非阻塞丢弃 | cmd/mrf.go:39、:94-97 |
| 11 | MRF healRoutine:1s 重连窗 + 5× sleeper + BitrotScan 升级 | cmd/mrf.go:218-281(:213/:248/:259) |
| 12 | heal worker 数 GOMAXPROCS/2 | cmd/background-heal-ops.go:156-175 |
| 13 | healObject 主流程(读元数据→比对→重写→rename) | cmd/erasure-healing.go:295-684 |
| 14 | 逐盘 heal 判定 shouldHealObjectOnDisk | cmd/erasure-healing.go:178-205 |
| 15 | 分片校验 CheckParts/VerifyFile(深扫) | cmd/erasure-healing-common.go:414-422 |
| 16 | Normal 撞 corrupt 自动升级 Deep | cmd/erasure-healing.go:1101-1106 |
| 17 | 读写路径 MRF 投递点(读修复) | cmd/erasure-object.go:403-417、:806、:2153 |
| 18 | 换盘自动 heal + 监控循环 | cmd/background-newdisks-heal-ops.go:373-387、:559 |
