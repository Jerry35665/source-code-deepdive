# L 卷:containerd 资源生命周期管理 —— leases 租约与 GC 调度深读

> 源码版本:containerd 2.x 主干,commit `f6132dbe1f482cbe0aebc4bd3d8d7a184fb4a2aa`(2026-09-10)。
> 本文行号均为该 commit 下"仓库相对路径:行号",全部经 grep -n / Read 实际核对。卷一 A 报告已讲 GC 主流程(三色标记+标签协议),卷一 B 报告提过 WithLease;本章把两者合并讲透:资源从"出生"到"物理消失"的完整生命周期。

---

## 1. 全景:一个 blob 的生与死

```
                    ┌──────────────────────────────────────────────────────┐
                    │                 metadata bolt DB                     │
                    └──────────────────────────────────────────────────────┘

 创建                使用/持有                 失去引用                GC 清扫
 ──────             ──────────               ──────────             ─────────
 Writer/Prepare     lease.AddResource        lease.Delete           ① 调度器 tick
     │               (client 侧自动,           (done(ctx) 触发)        │
     ▼               core/metadata/           image.Delete            ▼
 bolt 记录诞生       content.go:405           removeImageLease     scheduler.run
     │               :432/:623)               images.go:301       (plugins/gc/
     │                  │                        │                scheduler.go:236)
     │                  ▼                        ▼                    │
     │           有租约/标签引用         无 root、无 ref、            ▼
     │           → GC 视为 root         无租约,且有             DB.GarbageCollect
     │           (gc.go:570-581)        dirty 标记              (core/metadata/db.go:383)
     │                                       │                    │
     │                                       ▼                    ├─ ① mark: bolt 只读事务
     │                                 等待下一轮 GC               │    + wlock 写锁
     │                                 (scheduler.go:              │    → gc.Tricolor
     │                                  270-289)                   │      (db.go:492-536)
     │                                                  ▼
     │                                       ② sweep: bolt 写事务
     │                                          scanAll 删 bolt 桶
     │                                          (db.go:396-435)
     │                                                  ▼
     │                                       ③ 物理回收(异步):
     │                                          cleanupSnapshotter /
     │                                          cleanupContent
     │                                          (db.go:449-479)
     ▼
 磁盘文件/目录消失
```

关键分工:**bolt 元数据删除是同步的、事务性的**;**磁盘数据删除是异步的、最终一致的**。租约与标签决定"谁在 mark 阶段算 root/可达",调度器决定"何时跑",wlock+bolt 事务保证"跑的时候没人改"。

---

## 2. leases 专节:接口、持久化与过期

### 2.1 Manager 接口

`core/leases/lease.go:32-39` 定义了租约管理器的全部能力:

```go
type Manager interface {
	Create(context.Context, ...Opt) (Lease, error)
	Delete(context.Context, Lease, ...DeleteOpt) error
	List(context.Context, ...string) ([]Lease, error)
	AddResource(context.Context, Lease, Resource) error
	DeleteResource(context.Context, Lease, Resource) error
	ListResources(context.Context, Lease) ([]Resource, error)
}
```

`Lease` 本体只有三个字段:ID、CreatedAt、Labels(`core/leases/lease.go:43-47`)——**租约不是引用计数器,而是一个"带标签的命名存活凭证"**。`Resource` 只描述 `ID + Type`(content/ingest/image/snapshot,`core/leases/lease.go:51-54`,类型校验见 `core/metadata/leases.go:531-563`)。

过期不是定时器,而是一个标签:`WithExpiration` 往 lease 上写 `containerd.io/gc.expire`(RFC3339 时间戳,`core/leases/lease.go:94-103`)。同理 `SynchronousDelete` 只是设置 DeleteOptions 的同步标志(`core/leases/lease.go:64-67`)。

### 2.2 bolt 持久化

真正实现是 `core/metadata/leases.go` 的 `leaseManager`(`:38-48`),每个租约是 namespaced bolt 桶:

- `Create`:`leases/<id>` 建桶 + createdAt + labels(`core/metadata/leases.go:67-97`);
- `Delete`:删桶后 `lm.db.dirty.Add(1)`(`:123`)——**这个 dirty 计数就是喂给 GC 调度器的信号源**;
- `AddResource`:按 Resource.Type 逐级 `CreateBucketIfNotExists`(`:203-210`);
- 快捷函数 `addContentLease/addSnapshotLease/addIngestLease/addImageLease`(`:386-408`/`:337-364`/`:430-456`/`:478-509`)在 content/snapshot 的正常写入路径中被内联调用(如 `core/metadata/content.go:405,432,623`),**context 里带租约就自动把资源挂到租约上**——这是"租约保护下载"的实现根基。注意 `addImageLease` 有个例外:镜像没配过期就不加租约(`core/metadata/leases.go:485-487`),因为不过期的镜像本身就是 root。

租约还通过 gRPC header `containerd-lease` 跨进程传播(`core/leases/grpc.go:27`,写入 `core/leases/context.go:24-30`),gRPC 服务入口在 `plugins/services/leases/service.go:37-40`。

### 2.3 pull 场景的租约时序(呼应 B 卷)

```go
// client/lease.go:37-43
if len(opts) == 0 {
    // Use default lease configuration if no options provided
    opts = []leases.Opt{
        leases.WithRandomID(),
        leases.WithExpiration(24 * time.Hour),
    }
}
```

时序:pull 开始 → `c.WithLease(ctx)` 建随机 ID 租约、24h 过期(`client/pull.go:86`)→ 下载中每次 `Writer()`/`Commit` 自动 `addIngestLease`/`addContentLease` → pull 结束 `defer done(ctx)` 删租约(`client/lease.go:51-53`)。**若进程中途崩溃,租约留在 bolt 里兜底 24 小时**,期间 GC 不敢动这些半成品 blob;到期后第一轮 GC 把租约连同资源一起收掉(租约过期判定:`core/metadata/gc.go:570-581`)。

同样的模式遍布客户端:`NewContainer`(`client/client.go:343`)、`Fetch`(`:508`)、`Restore`(`:603`)、`Import`(`client/import.go:157`)、`task.Checkpoint`(`client/task.go:552`)、`Image.Unpack`(`client/image.go:315`)、`container.Checkpoint`(`client/container.go:440`)、`Transfer`(`client/transfer.go:29`)。若 ctx 已带租约则直接复用、不重复创建(`client/lease.go:30-33`)。

服务端 transfer 服务同样自建租约:`core/transfer/local/transfer.go:138-168`(同样默认 24h,`:153-156`),pull 入口 `core/transfer/local/pull.go:40`。CRI 拉镜像默认走 transfer(`internal/cri/server/images/image_pull.go:179`),因此 CRI 镜像下载也被租约保护。

### 2.4 删除租约时的同步 GC

`plugins/leases/local.go:64-84`:`Delete` 先删 bolt 记录;若传了 `SynchronousDelete`,则调 `l.gc.ScheduleAndWait(ctx)`(`:77`)阻塞等一轮 GC 完成——这就是文档说的"删镜像/删租约可同步回收"路径(镜像侧对称实现在 `plugins/services/images/local.go:181`)。

### 2.5 过期语义小结

| 对象 | 过期标签 | 判定点 | 效果 |
|---|---|---|---|
| 租约 | `gc.expire`(RFC3339) | scanRoots,`core/metadata/gc.go:570-581` | 过期租约不作为 root,整棵租约子树可被收 |
| 镜像 | `gc.expire` | `isExpiredImage`,`core/metadata/gc.go:1136-1150` | 过期镜像不当 root(`:672-697`);不过期镜像天然是 root |
| ingest | bolt 内嵌 expireAt(写入 24h) | `core/metadata/gc.go:712-719`,写入 `core/metadata/content.go:458` | 中断的上传残留 24h 后可收 |

---

## 3. GC 调度器专节:阈值算法与触发种类

`plugins/gc/scheduler.go` 注册为 GCPlugin("scheduler"),依赖 metadata 插件(`:86-125`),`go m.run(...)` 启动后台循环(`:120`)。

### 3.1 配置与默认值

`plugins/gc/scheduler.go:35-84` 定义 config,默认值在 `:94-98`:

```go
Config: &config{
    PauseThreshold:    0.02,   // GC 停顿最多占真实时间 2%
    DeletionThreshold: 0,      // 删除次数不触发立即 GC
    MutationThreshold: 100,    // 100 次写库后,下个调度点必须 GC
    ScheduleDelay:     0,      // 触发后立即跑
    StartupDelay:      100ms,  // 启动后先跑一次,建立 avg 基线
},
```

pauseThreshold 被 clamp 到 [0, 0.5](`:166-171`),防止过度调度。

### 3.2 触发种类(三种半)

run 循环消费两类事件源(`plugins/gc/scheduler.go:236-291`):

1. **手动触发**:`ScheduleAndWait → wait(ctx, trigger=true)` 往 eventC 发 `mutation=false` 事件(`:187-218`),循环里 `triggered = true`(`:276`),立即调度;
2. **阈值触发**:`DB.Update` 每次成功事务后回调 `mutationCallback(dirty)`(`core/metadata/db.go:277-280` → `plugins/gc/scheduler.go:220-229`),循环里计 deletions(`e.dirty`)与 mutations(`:270-275`)。`deletionThreshold>0 且删够` 或 `mutationThreshold 达标` 时立即/下一调度点跑(`:280-289`);
3. **定时调度**:tick 到点后若"非手动触发 && 无删除 && mutations 未超阈值"则空转、按 interval 重排(`:261-264`);
4. (半种)**启动触发**:`startupDelay` 后的首轮 GC,专门用来建立 avg 基线(`:252-254`)。

### 3.3 均耗时/pause 阈值算法

GC 成功结束后重算 interval(`plugins/gc/scheduler.go:335-347`):

```go
if s.pauseThreshold > 0.0 {
    avg := float64(gcTimeSum) / float64(collections)
    if avg < minimumGCTime {      // minimumGCTime = 5ms, :237
        avg = minimumGCTime       // 防止 avg→0 导致 interval→0
    }
    interval = time.Duration(avg/s.pauseThreshold - avg)
}
```

数学含义:GC 平均耗时 avg(即持锁停顿),interval = avg/p − avg,则 avg/(avg+interval) = p,**GC 停顿恰好占比 p(默认 2%)**。avg=10ms 时 interval≈490ms;avg 被 5ms 下限托底,所以最快也只 245ms 一轮。

失败处理也有细节:失败后按"上次计划间隔+1s"退避重试(`:300-321`),waiters 全部 close 返回 "gc failed"(`:316-319`)。指标在 `plugins/gc/metrics.go:21-27`(`containerd_gc_collections{status}` 计数器 + `containerd_gc_gc` 耗时直方图)。

---

## 4. Tricolor 深读专节:并发写下的正确性

### 4.1 两把锁 + 一个只读事务

mark 与 sweep 之间不允许世界变化。containerd 的答案在 `core/metadata/db.go:89-93` 的注释里写得明明白白:

```go
// wlock is used to protect access to the data structures during garbage
// collection. While the wlock is held no writable transactions can be
// opened, preventing changes from occurring between the mark and
// sweep phases without preventing read transactions.
wlock sync.RWMutex
```

- `GarbageCollect` 全程持 `wlock.Lock()`(排他,`core/metadata/db.go:384`,释放点 `:390/:432/:484`);
- 所有写路径走 `DB.Update`,它只拿 `wlock.RLock()`(`:272-275`)——GC 排他锁一持,写事务全被挡住;
- mark 阶段用 bolt **只读事务**(`m.db.View`,`db.go:494`)扫描 roots 并跑 Tricolor(`:526`),bolt 的 COW 机制保证该事务看到的是一致快照;读事务不受 wlock 影响,业务读不被 GC 阻塞。

所以这不是 JVM 式的增量并发标记,而是"**STW 换正确性,STW 只挡写不挡读**"。boltdb 单写者模型 + wlock,让三色不变式("黑不指白")靠事务隔离天然成立,连 write barrier 都不需要。

### 4.2 Tricolor 算法本体

`pkg/gc/gc.go:64-100`:灰色就是一个 DFS 栈(`grays`,从尾部弹出,`:78-79`),`seen` 记"已见"(非白),处理完进 `reachable`(黑)。有个精巧的位运算:`ResourceMax = 0x1F`(`:36`),高位 bit 在标记完成时被剥离(`id.Type & ResourceMax`,`:93-94`)——高 3 位是调用方的"标记位",metadata 包用 `0x20` 表达 **flat 语义**(`core/metadata/gc.go:60-64`:`resourceContentFlat = ResourceContent | 0x20`)。flat 节点在 references 里被特殊对待(见下),最终又归并回普通节点入 reachable,一套结构两种遍历深度。

包里还有个并发版 `ConcurrentMark`(`pkg/gc/gc.go:111-178`,goroutine 池 + grays channel),但 metadata GC 目前只用单线程 `Tricolor`(`core/metadata/db.go:526`),并发版留在包内备用。

### 4.3 对"死边"与图变化的容忍

- references 查不到桶时静默返回("Node may be created from dead edge",`core/metadata/gc.go:842-845,854-857,872-875`)——标签引用的悬空不会让 GC 崩溃,下一轮再清;
- roots 扫描发 channel 失败不中断,最后统一返回 cerr(`core/metadata/gc.go:507-516,828`)。

### 4.4 清扫两阶段

**阶段一(元数据清扫,同步)**:`db.Update` 写事务里 `scanAll` 全量枚举,不在 marked 集合的节点删 bolt 桶(`core/metadata/db.go:396-435`);同时记录 `dirtySS`(哪个 snapshotter 有删除)与 `dirtyCS`(content 有删除)(`:405-413`),并收集 ImageDelete/SnapshotRemove 事件(`core/metadata/gc.go:1069-1082`)。

**阶段二(物理回收,异步)**:写事务提交后,`wlock` 仍持有,起 goroutine 并行做(`core/metadata/db.go:449-479`):

- `cleanupSnapshotter` → metadata snapshotter 的 `garbageCollect`(`core/metadata/snapshot.go:862-941`):从 bolt 反查存活 key 集合 `seen`(`:880-922`),对 snapshotter 自身记录建树、`pruneBranch` 后序删除(`:949-1003`),最后若 snapshotter 实现 `Cleaner` 接口再调 `Cleanup`(`:868-873`);
- `cleanupContent` → content 的 `garbageCollect`(`core/metadata/content.go:845-961`):bolt 里 `contentSeen` 对账磁盘 Walk,不在册的 blob 直接 `Delete`,不在册的 ingest `Abort`(`:916-959`);
- GC 产生的事件在提交成功后异步发布(`core/metadata/db.go:441-443,348-368`),`dirty` 计数清零(`:447`)。

### 4.5 物理删除的"队列"与失败重试

containerd **没有显式的删除队列**——重试靠"磁盘对账"天然实现:

- overlay 的 `Cleanup` 扫 snapshots 目录,IDMap(bolt 登记的 id)里没有的目录就删(`plugins/snapshots/overlay/overlay.go:402-429`);删除失败只 Warn(`:381-383`),目录仍在盘上、仍不在 IDMap,**下轮 Cleanup 自然重试**;
- overlay `Remove` 把目录删除放在 bolt 事务提交之后(`:328-336` 注释:"failures must not return error since the transaction is committed");配置 `async_remove` 时干脆留给 Cleanup(`:343-348`);
- `pruneBranch` 遇 `FailedPrecondition`(如快照仍被挂载)容忍并 Warn(`core/metadata/snapshot.go:993-996`),记录留在 snapshotter bolt 里,下轮 GC 的 seen 对账会再试;
- content 清理失败只 Warn(`core/metadata/db.go:562-563`);孤儿 blob 要等下一次 `dirtyCS` 被置位(content 删除,`core/metadata/content.go:227-228`)后的 GC 才会对账掉——这是唯一"重试依赖后续写"的角落。

---

## 5. 标签协议专节:四类标签的语义组合

标签常量集中在 `core/metadata/gc.go:66-119`,处理逻辑在 `startGCContext` 的 labelHandlers(`:225-399`)与 `sendLabelRefs`(`:1110-1134`)。`sendLabelRefs` 对 labels 桶做**前缀 Seek 扫描**(`:1118`),且 handlers 按 key 排序保证只前进(`:437-439`)——bolt 有序桶上的多前缀匹配优雅解法。

| 标签 | 挂在谁身上 | 语义 | 处理位置 |
|---|---|---|---|
| `gc.root`(:67) | content/snapshot(用户可设) | 本对象是 root,连带其引用 | handler 无回调即触发 root 回调(:311-313);scanRoots 中 content :736-738、snapshot :785-787 |
| `gc.ref.content[.name]`(:75)/`gc.ref.image`(:76)/`gc.ref.snapshot.<ss>`(:74) | 父对象(镜像/容器/content/snapshot) | 正向引用:父活则子活 | `fn` 回调,`gc.go:276-309`;references 逐节点追:`:832-933` |
| `gc.bref.container/content/image/snapshot.<ss>`(:83-86) | 子对象 | 反向引用:子把"我要挂靠父"写在自己身上,父存在且可达则自己可达 | `bref` 回调,`gc.go:227-273`;scanRoots 收集进 backRefs(:518-524),references 开头先发(:833-838) |
| `gc.expire`(:95) | lease/镜像 | 时间一到即丧失 root 资格 | :570-581(lease)、:1136-1150(image) |
| `gc.flat`(:101) | lease | 只保引用对象本身,不追其标签引用(0x20 位实现) | :583-585;references 跳过::863-866(snap)、:887-890(image) |
| `gc.cond.snapshot`(:112)+`gc.cond.value-usedat`(:118) | snapshot | 条件反向引用:如"usedat < 24h 则视为被快照引用" | 条件对,:316-398;评估,:818-826 |

四者的组合语义:
- **ref 是"父写子"**:镜像 manifest 由客户端在 content 上打 `gc.ref.content.*` 互相串成树(B 卷讲过);
- **bref 是"子写父"**:允许子对象在父不存在/不可修改时就自证关联(`core/metadata/gc.go:78-86` 注释),典型如 sandbox 记录;
- **root 是逃生舱**:用户不想建图时,直接给对象打 `gc.root` 保活;
- **expire/flat/cond 是修饰符**:分别控制时间维度、遍历深度、条件化保活。

**用户如何给自己的对象接 GC**:① 注册 collectible 资源类型(`RegisterCollectibleResource`,`core/metadata/db.go:322-340`,仅允许 `resourceEnd` 之后的高位类型,现有用户:streaming `plugins/streaming/manager.go:52`、mount `plugins/mount/manager.go:127`);② 实现 `Collector`/`CollectionContext` 接口(`core/metadata/gc.go:127-176`),可选实现 `collectionWithReferences` 惰性发正向边(`:167-169`);③ 通过 `ReferenceLabel()` 获得 `gc.ref.<自己的标签>` 前缀(`:410-425`),handler 排序后进入统一前缀扫描。此后你的资源类型即可被租约引用、被 GC 收割。

---

## 6. 设计动机

**为什么用租约而非引用计数?** ① 计数式引用需要每个客户端 RPC 都精确配对 acquire/release,进程崩溃即泄漏或早删;租约是**有期限的命名凭证**,崩溃后由过期时间兜底自动回收(24h 默认,`client/lease.go:41`),不需要心跳续期逻辑。② 分布式场景下引用计数的"谁持有"不可见,而租约本身是 bolt 里的对象,可 List、可审计(`core/metadata/leases.go:130-183`)。③ 资源关系本就是图而非计数——containerd 把"图"交给标签协议,"临时保活"交给租约,二者正交。

**为什么 GC 异步物理删除?** ① bolt 写事务必须短:快照目录删除(可能涉及挂载点、大量 inode)是秒级操作,放进事务会拖垮所有写者;所以阶段一只删元数据、阶段二在 wlock 下并行做物理清理(`core/metadata/db.go:449-479`)。② 两阶段天然容错:元数据已删,物理删除失败只是"磁盘暂留孤儿",可重试且不影响正确性(overlay `Remove` 的 defer 注释,`plugins/snapshots/overlay/overlay.go:325-327`)。③ `GarbageCollect` 的耗时统计只算 MetaD(`GCStats.Elapsed`,`db.go:378-380`),调度器的 pause 模型据此保持稳定。

**标签协议的可扩展性?** GC 的可达图完全由"资源类型内置边"(如快照 parent、镜像 target、ingest expected,`core/metadata/gc.go:839-921`)+"标签边"拼成。containerd 核心只理解 8 种资源类型(`:35-58`),其余(流、挂载)走 collectible 插件接口,新类型不改 GC 一行代码;标签则让**客户端**——而非 daemon——定义 blob 之间的关系(OCI manifest 的 config/layers 就是客户端打的 `gc.ref.content.*`)。协议即 schema:四类前缀 + 前缀扫描,任何新关系都能在不迁移数据的情况下接入。

---

## 7. FAQ 与深挖

### FAQ

1. **Q: 租约过期是定时删除吗?** A: 不是。过期租约只是在下一轮 GC 的 scanRoots 中不再算 root(`core/metadata/gc.go:570-581`),实际删除取决于 GC 何时跑(最短 245ms,见 §3.3)。
2. **Q: pull 中途断网/杀进程,blob 会泄漏吗?** A: 不会立即清也不会永久泄漏:租约留在 bolt 兜底 24h(`client/lease.go:41`),期间 GC 不动;过期后下一轮 GC 连租约带资源一起收。ingest(上传残留)另有 24h 内嵌过期(`core/metadata/content.go:458`)。
3. **Q: ctx 已经有租约,`WithLease` 会嵌套吗?** A: 不会,直接复用并返回 nop done(`client/lease.go:30-33`);跨进程用 gRPC header `containerd-lease` 传递(`core/leases/grpc.go:27`)。
4. **Q: `SynchronousDelete` 同步到什么程度?** A: 删除方(镜像/租约)自身记录同步删除,随后 `ScheduleAndWait` 阻塞到下一轮 GC 完成(`plugins/leases/local.go:76-80`)——物理删除也是这一轮内完成(GarbageCollect 的 wg.Wait,`db.go:486`)。
5. **Q: 为什么我删了镜像,磁盘没立刻释放?** A: 若没传 SynchronousDelete,要等调度器下一轮;且物理删除是异步阶段二。可以用 `ctr namespaces … leases` 先确认没有泄漏租约。
6. **Q: 事件会被 GC 管理吗?** A: 事件不在 GC 管辖内;恰恰相反,**GC 会发布删除事件**(`/images/delete`、`/snapshot/remove`,事务提交后异步发,`core/metadata/db.go:441-443,354-363`),供订阅者感知物理回收。
7. **Q: `gc.root` 的值有语义吗?** A: GC 只判非空,不解析;约定放 RFC3339 时间戳表示打标时间(文档 `docs/garbage-collection.md:104`)。
8. **Q: mutation_threshold 为什么默认 100 且不立即触发?** A: 防止纯标签改写等"无删除写"频繁唤醒 GC;它只保证"下个调度点必跑"(`plugins/gc/scheduler.go:57-66`,config 注释)。
9. **Q: GC 跑挂了会怎样?** A: 本轮跳过、按上次间隔+1s 退避重试(`plugins/gc/scheduler.go:300-321`),指标 `containerd_gc_collections{status="fail"}` 计数;collectible 资源清理失败不拖垮整体 GC(`core/metadata/db.go:319-321` 注释)。
10. **Q: 如何给自定义资源接 GC?** A: `RegisterCollectibleResource` + 实现 Collector/CollectionContext(`core/metadata/db.go:322-340`、`core/metadata/gc.go:127-176`),参考 streaming 与 mount 插件。

### 深挖选题

1. **flat 租约的 0x20 位 tricks**:高 3 位资源类型位在 mark 收尾被 `& ResourceMax` 剥离(`pkg/gc/gc.go:93-94`),使 flat 节点最终归并普通节点;遍历时 references 对 flat snapshot 只追 parent、flat image 只追 target(`core/metadata/gc.go:863-890`)——"少拉一整棵树"的实现。
2. **条件引用 `gc.cond.snapshot` + usedat**:解析 `cond[=<>]value|key` 语法(`core/metadata/gc.go:324-350`),scanRoots 先收集条件再统一评估建 bref(`:818-826`),为"按活跃时间保活快照"提供声明式方案,可对比kubelet 镜像 GC 策略。
3. **为什么 ConcurrentMark 弃而不用?** 对比 `pkg/gc/gc.go:64-100` 与 `:111-178`,结合 metadata 只用 Tricolor(`db.go:526`)分析:wlock STW 下并发标记无收益,channel+goroutine 版本反而引入 seen 竞态复杂度。
4. **bolt 前缀扫描与 handler 排序**:`sendLabelRefs` 的 Seek+HasPrefix 循环(`core/metadata/gc.go:1118`)依赖 handlers 有序(`:437-439`),若新注册 collector 的 ReferenceLabel 打乱顺序会怎样——分析只前进扫描的正确性前提。
5. **GC 与 Close 的锁纪律**:`DB.Close` 也要拿 wlock(`core/metadata/db.go:144-152`)防止 GC 中关库;梳理 wlock 的全部持锁点,论证"读事务永不阻塞"承诺的边界。

---

## 8. 写作要点速查表

| # | 关键函数/结构 | 位置(仓库相对路径:行号) |
|---|---|---|
| 1 | leases.Manager 接口(6 方法) | core/leases/lease.go:32-39 |
| 2 | WithExpiration 写 gc.expire 标签 | core/leases/lease.go:94-103 |
| 3 | client.WithLease(默认随机 ID+24h) | client/lease.go:27-54(41) |
| 4 | pull 建租约入口 | client/pull.go:86 |
| 5 | leaseManager.Create/Delete(bolt) | core/metadata/leases.go:51-102 / 105-127 |
| 6 | addContentLease 等自动挂靠 | core/metadata/leases.go:386-408 |
| 7 | 租约删除+同步 GC | plugins/leases/local.go:64-84 |
| 8 | 调度器配置默认值 | plugins/gc/scheduler.go:94-98 |
| 9 | 触发判定与立即调度 | plugins/gc/scheduler.go:270-289 |
| 10 | pause 阈值 interval 公式 | plugins/gc/scheduler.go:335-347 |
| 11 | Tricolor 标记本体 | pkg/gc/gc.go:64-100 |
| 12 | wlock 并发正确性注释 | core/metadata/db.go:89-93 |
| 13 | GarbageCollect 主流程(两阶段) | core/metadata/db.go:383-489 |
| 14 | getMarked(只读事务+Tricolor) | core/metadata/db.go:492-536 |
| 15 | 标签协议常量(gc.root/ref/bref/expire/flat/cond) | core/metadata/gc.go:66-119 |
| 16 | scanRoots(租约/镜像/ingest 过期判定) | core/metadata/gc.go:495-829(570-581) |
| 17 | content 物理对账清理 | core/metadata/content.go:845-961 |
| 18 | 快照树剪枝+overlay Cleanup 对账 | core/metadata/snapshot.go:862-1003;plugins/snapshots/overlay/overlay.go:374-429 |
