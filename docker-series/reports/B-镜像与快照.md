# B 卷:containerd 镜像与快照机制 —— content store、snapshotter 与 pull 管道

> 源码版本:containerd shallow clone,commit `f6132dbe1f482cbe0aebc4bd3d8d7a184fb4a2aa`(v2 主干,2025 年末)。
> 本文所有行号均为该 commit 下的仓库相对路径:行号。v2 已将 v1 根目录的包收入 `core/`:`content/store.go`(接口)现为 `core/content/content.go`,`snapshots/snapshot.go` 现为 `core/snapshots/snapshotter.go`,`gc.go` 拆为 `pkg/gc/gc.go`(算法)+ `core/metadata/gc.go`(引用图),blob 落盘实现在 `plugins/content/local/store.go`。

---

## 1. 全景:一次 docker pull 的数据流

```
docker pull nginx:latest
   │
   ▼
containerd client.Pull (client/pull.go:43)
   │  1. WithLease 建 GC 租约(client/pull.go:86)
   │  2. 若 --unpack:创建 Unpacker 并 wrap 进 handler 链(client/pull.go:137-154)
   ▼
Resolver.Resolve ── HEAD /v2/library/nginx/manifests/latest ──► registry
   (core/remotes/docker/resolver.go:245)
   │  401 → token 认证(authorizer.go:153 AddResponses → doBearerAuth:275)
   │  返回 Docker-Content-Digest → ocispec.Descriptor{Digest,MediaType,Size}
   ▼
Fetcher(ctx, ref)  (resolver.go:502)
   │
   ▼
images.Dispatch 按 manifest→config→layer 递归派发  (client/pull.go:282)
   │
   ├─ remotes.FetchHandler:HTTP GET blob → content.Writer ingest
   │    (core/remotes/handlers.go:119,139;ref 由 MakeRefKey:80 生成 "layer-<digest>")
   │    落盘:blobs/sha256/<hex>(plugins/content/local/store.go:646 blobPath)
   │
   └─ Unpacker.Unpack 拦截 layer(core/unpack/unpacker.go:205)
        │  config 读完 → 算 diffIDs/ChainIDs(unpacker.go:374,450)
        ▼
      snapshotter.Prepare(key, parent) → overlay 挂载参数(unpacker.go:497)
        │   workdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/
        │         snapshots/<id>/work   upperdir=.../snapshots/<id>/fs
        │   lowerdir=各父层 .../fs(:拼接)(plugins/snapshots/overlay/overlay.go:586-608)
        ▼
      applier.Apply:tar 解包进挂载点 + whiteout 处理(unpacker.go:634;
      core/diff/apply/apply.go:62)→ 校验 diffID(unpacker.go:642)
        ▼
      snapshotter.Commit(chainID, key)(unpacker.go:549)
        ▼
content(blob 层)              snapshot(层叠态)           Mount 列表
sha256 寻址、可去重      →    chainID 命名的 committed 快照 → overlay mount
                             (去重:同名 chainID 直接跳过,unpacker.go:499-509)
```

镜像的元数据模型极简:`images.Image{Name, Labels, Target ocispec.Descriptor}`(`core/images/image.go:35-56`),Target 指向 manifest blob,其余内容全部靠 blob 内嵌的 descriptor 树表达;"镜像就是 content store 里一条指向 manifest 的引用"。

---

## 2. content store 专节:digest 寻址与可恢复 ingest

### 2.1 接口分层

`content.Store` 由四个小接口组合:Manager(查/列/删)、Provider(ReaderAt 读)、IngestManager(Status/Abort 进行中的写)、Ingester(开 Writer)(`core/content/content.go:41-46`)。生命周期注释明确:ingest 完成前对 Provider/Manager 不可见,完成后不再出现在 IngestManager(`content.go:38-40`)。

Info 结构只有 digest、size、时间戳和 Labels(`content.go:90-96`)——**Labels 是整个 GC 与分发生源追踪的唯一可变挂点**。

### 2.2 digest 命名:路径即校验

本地 blob store 按 `blobs/<算法>/<hex>` 双层目录存储(`plugins/content/local/store.go:646-652`):

```go
func (s *store) blobPath(dgst digest.Digest) (string, error) {
	if err := dgst.Validate(); err != nil { ... }
	return filepath.Join(s.root, "blobs", dgst.Algorithm().String(), dgst.Encoded()), nil
}
```

写完成时 Commit 做三重校验:size 一致(`writer.go:111`)、digest 一致(算法不符时重哈希,`writer.go:116-136`)、目标已存在则报 ErrAlreadyExists(天然去重,`writer.go:148-154`);随后 `os.Rename(ingest/data → blobs/sha256/<hex>)` 原子转正(`writer.go:156`),chmod 掉写位变只读(`writer.go:198-202`),支持 fsverity 的文件系统还会开完整性校验(`writer.go:165-169`)。

### 2.3 ingest 的 resumable 设计

一次 ingest 是 `<root>/ingest/<sha256(ref)>/` 目录,内含 `ref`、`data`、`startedat`、`updatedat`、`total` 五个文件(`store.go:666-674` ingestPaths;`store.go:589-605` 初始化)。ref 被 hash 成目录名是刻意为之:"取 ref 的 digest 使 ingest 路径定长"(`store.go:654-658`)。

恢复的关键在 `Writer()` 重复打开同一 ref:若 ingest 目录已存在(Mkdir 报 EEXIST),调 `resumeStatus` 重放已有 data 到哈希器,得出可信 offset(`store.go:567-581`;`store.go:501-529`):

```go
// store.go:524-525(resumeStatus 内)
p := bufPool.Get().(*[]byte)
status.Offset, err = io.CopyBuffer(digester.Hash(), fp, *p)
```

注释自嘲 "slow slow slow!!"——重放是 O(已下字节),但换来了断点续传语义:调用方拿 `Status().Offset` 后 seek 到该处继续写(`core/remotes/handlers.go:159-166` 在 offset==size 时直接 Commit;`core/content/helpers.go:205-209` Copy 前 seekReader 到 offset)。写侧单写者靠进程内锁保证("Only one writer may be in use per ref",`store.go:470-475`、`store.go:488` tryLock),并发争抢时 `OpenWriter` 指数退避重试(`core/content/helpers.go:149-179`)。

### 2.4 labels 的存放与 GC 标记

local store 自身只管字节;labels 经 `LabelStore` 接口外置(`store.go:50-61`),在 daemon 里由 metadata bolt store 实现——所以 content 的 GC 标签和镜像/容器元数据在同一个事务库里(与 A 报告的 metadata 呼应)。pull 过程写入的关键标签:

- `containerd.io/gc.ref.content.l.<n>`:父 blob 指向子 blob(manifest→layer 等),由 `SetChildrenMappedLabels` 在 handler 链里回写(`core/images/handlers.go:245-284`;键名生成见 `core/images/mediatypes.go:218-234`);
- `containerd.io/distribution.source.<host>`:记录 blob 来自哪个 registry(`pkg/labels/labels.go:41`;写入 handler `core/remotes/docker/handler.go:34` AppendDistributionSourceLabel);
- `containerd.io/uncompressed`:layer 压缩 blob → 其 diffID,unpack 成功后写入(`core/unpack/unpacker.go:564-571`)。

---

## 3. snapshotter 专节:接口与 overlayfs

### 3.1 Snapshotter 接口

接口注释本身就是一篇设计文档:active 由 Prepare/View 创建,committed 由 Commit 创建,二者互不可逆(`core/snapshots/snapshotter.go:179-197`)。核心五方法:

| 方法 | 行号 | 语义 |
|---|---|---|
| `Prepare(key,parent)` | `snapshotter.go:325` | 建可写 active 快照,返回挂载参数 |
| `View(key,parent)` | `snapshotter.go:340` | 只读视图(mount 带 ro) |
| `Mounts(key)` | `snapshotter.go:309` | 恢复/重建挂载参数(容器启动走这里) |
| `Commit(name,key)` | `snapshotter.go:350` | 把 active 固化为 committed,name 可再作 parent |
| `Remove(key)` | `snapshotter.go:358` | 删除;若被引用须先删子 |

Importing a Layer 的官方范例即 pull unpack 的原型:Prepare(带 `containerd.io/gc.root` 防回收)→ mount.All → 解 tar → Commit 为 digest 名(`snapshotter.go:201-263`)。标签仅 `containerd.io/snapshot/` 前缀者会被继承(`snapshotter.go:35-36,409-421`);`LabelSnapshotRef = containerd.io/snapshot.ref` 是 remote snapshot 协议的钩子(`snapshotter.go:38-42`)。

快照元数据(父子链)在 bolt metastore:`CreateSnapshot` 校验 parent 必须是 committed(`core/snapshots/storage/bolt.go:240-242`),分配自增数字 ID,写 parent 反向链接,并用 `parents()` 一次性收回整条祖先链填进 `s.ParentIDs`(`bolt.go:269-284`)。**ParentIDs 顺序即 overlayfs lowerdir 顺序的来源。**

### 3.2 overlayfs 实现:目录结构与挂载参数组装

每个快照对应 `snapshots/<id>/` 两个目录:`fs`(upperdir)与 `work`(仅 active,`plugins/snapshots/overlay/overlay.go:536-553` prepareDirectory)。创建走临时目录 + rename 原子化(`overlay.go:523-527`)。

`mounts()` 是挂载参数组装的全部逻辑(`overlay.go:555-618`):

```go
if s.Kind == snapshots.KindActive {
	options = append(options,
		fmt.Sprintf("workdir=%s", o.workPath(s.ID)),
		fmt.Sprintf("upperdir=%s", o.upperPath(s.ID)),
	)
} else if len(s.ParentIDs) == 1 {
	return []mount.Mount{{Source: o.upperPath(s.ParentIDs[0]),
		Type: "bind", Options: append(options, "ro", "rbind")}}
}
parentPaths := make([]string, len(s.ParentIDs))
for i := range s.ParentIDs { parentPaths[i] = o.upperPath(s.ParentIDs[i]) }
options = append(options, fmt.Sprintf("lowerdir=%s", strings.Join(parentPaths, ":")))
```

三个分支:无父层 → bind mount 顶目录(overlay 不支持零 lower,`overlay.go:567-584`);active 且有父 → 完整 `workdir+upperdir+lowerdir` overlay 挂载;只有 View 且单父 → 退化为 ro bind。upperPath/workPath 即 `<root>/snapshots/<id>/{fs,work}`(`overlay.go:620-626`)。默认追加 `index=off` 与按内核探测 `userxattr`(`overlay.go:150-165`)。

层叠链的运转:unpacker 对第 i 层 `Prepare(key_i, chainIDs[i-1])`(`core/unpack/unpacker.go:458-461,497`),apply 解包进挂载点(写的就是该层 upperdir),再 `Commit(chainIDs[i], key_i)`(`unpacker.go:549`)——committed 快照以 chainID 命名,下一层以它为 parent,于是 committed 快照链 = 镜像 rootfs 链。容器启动时 `Mounts(snapshotKey)` 重新产出同一组 overlay 参数交 runc(`client/container.go:344-363`)。

`Mount` 结构体只有 Type/Source/Target/Options 四字段(`core/mount/mount.go:35-53`),Options 兼容 mount(8) 语法,与 OCI spec 的 mounts 数组几乎一一对应,交接时仅附加 SELinux `context=` 选项(`client/container.go:352-362`)。

其他 snapshotter 一瞥:`native`(每层直接 `fs.CopyDir` 物理复制、bind mount 暴露,`plugins/snapshots/native/native.go:258-261,286-312`)、`btrfs`(subvolume 快照,`plugins/snapshots/btrfs/btrfs.go`)、另有 devmapper/erofs/lcow/windows/blockfile。

---

## 4. pull 管道专节

### 4.1 Resolve 与 Docker Hub token 认证流

`DefaultHost` 把 docker.io 翻成 registry-1.docker.io(`core/remotes/docker/resolver.go:141-146`)。`Resolve` 先 HEAD manifests;未带 digest 时信任响应头 `Docker-Content-Digest` 组装 descriptor(此处是"唯一信任 registry 的点",`resolver.go:393-405`),头缺失则降级 GET 并自算 digest(`resolver.go:406-459`);schema1 直接拒绝(`resolver.go:447-450`);manifest 大小超 `MaxManifestSize` 弃用(`resolver.go:461-467`)。

认证是标准的 401-challenge 模型:请求失败后 registry 返回 `WWW-Authenticate`,`AddResponses` 解析 challenge,凭 credentials 构造 authHandler 缓存于 host 维度(`core/remotes/docker/authorizer.go:153-213`)。后续每个请求发出前 `request.authorize` 注入 Authorization 头(`resolver.go:614-623,695`),重定向亦复授权(`resolver.go:703-712`)。

Bearer 流程(`authorizer.go:275-348`):按 scope 维护 token 缓存 `scopedTokens`(`authorizer.go:240,288-299`,同 scope 并发只发一次请求);有凭据先走 OAuth2 POST(`authorizer.go:316` FetchTokenWithOAuth),registry 不支持(405/404/401/400,GCR/JFrog/ACR 被点名)退回 GET token 端点(`authorizer.go:323-330`);无凭据则匿名取 token(`authorizer.go:342-347`);带 `expires_in` 本地判过期(`authorizer.go:289,350-356`)。

### 4.2 fetcher:并发分块下载

`Fetch` 按描述符 GET blob(`core/remotes/docker/fetcher.go:252`);当 layer 较大且 `MaxConcurrentDownloads>1` 时,`open` 用 Range 请求把 body 切成 `ConcurrentLayerFetchBuffer` 大小的 chunk 并行拉取,经 bufferPool + pipe 汇聚成单个 Reader(`fetcher.go:488-560`);registry 忽略 Range 时自动降并发为 1(`fetcher.go:516-519`)。

### 4.3 handler 链与 unpack 时机

`Client.Pull` 的主线(`client/pull.go`):WithLease(86)→ 组 Unpacker(137)→ `c.fetch`(157)。fetch 组 handler 链(`client/pull.go:264-271`):

```
remotes.FetchHandler(下载入库) → convertibleHandler → childrenHandler(平台过滤+打 gc.ref 标签)
→ appendDistSrcLabelHandler(记录分发源)
```

`Fetch` 每个描述符:OpenWriter(ref 由 MakeRefKey 按媒体类型定为 `manifest-/index-/layer-/config-` 前缀,`core/remotes/handlers.go:80-114`)→ 已有 offset 则续传/直接 Commit(`handlers.go:148-166`)→ `content.Copy` 边下边哈希(`handlers.go:187`)。

**unpack 与下载并行**是 unpacker 的精髓:manifest 阶段把 layer 从 children 中摘出、挂到 config 名下延后处理(`core/unpack/unpacker.go:256-284`);config 下载完成才触发 `u.unpack` goroutine(`unpacker.go:285-321`,diffID 只能从 config 拿)。unpack 内部对每层:topHalf 立即 Prepare(占位挂载)并 `startFetch(i)` 启动该层下载,等 `fetchC[i]` 信号后 `a.Apply`;串行模式逐层 apply+commit(`unpacker.go:683-716`),并行模式(`supportParallel`,需 snapshotter 有 rebase 能力)先全部 Prepare/apply、再按序 Commit/rebase(`unpacker.go:719-730`)。层未下完不会白等前层:第 i 层只等自己的 fetch 完成信号(`unpacker.go:612-618`)。

去重:Commit 前 `sn.Prepare` 若撞上已存在的 chainID 快照,直接跳过该层 unpack(`unpacker.go:499-509`);多 manifest 共享 config 时只 unpack 一次,其余仅 fetch 入库(`unpacker.go:289-309`)。最后给 config blob 打 `containerd.io/gc.ref.snapshot.<snapshotter>=<chainID>` 标签,把快照挂进 GC 图(`unpacker.go:745-751`)。全部完成后才创建 image 记录(`client/pull.go:162-177`,注释说明"unpacker 延迟了 blob 下载,须等 unpack 含下载全完成")。

---

## 5. GC 专节:标签引用图

### 5.1 标签协议

`core/metadata/gc.go:66-101` 定义全部标签:根 `containerd.io/gc.root`(67);正向引用 `containerd.io/gc.ref.{content,snapshot.,image}`(73-76,子随父活);反向引用 `containerd.io/gc.bref.*`(83-86,子挂父);`gc.expire`(95)/`gc.flat`(101)用于 lease 与 image;条件引用 `gc.cond.snapshot`(112,如 snapshotter 的 usedat)。

### 5.2 标记-清除的落地

算法是教科书三色标记(`pkg/gc/gc.go:64-100` Tricolor:灰栈 + seen + reachable),daemon 侧由 `DB.GarbageCollect` 驱动(`core/metadata/db.go:383-435`):`getMarked`(db.go:492)先 `scanRoots` 收集根,再 `gc.Tricolor(nodes, refs)` 求可达集,最后 `scanAll` 全量遍历把不可达节点 `remove`。

根的来源(`core/metadata/gc.go:495-829` scanRoots):

- 未过期的 **images**(665-702,isExpiredImage:1136 检查 gc.expire);
- **containers**(749-766);
- 带 `gc.root` 标签的 **content blob / snapshot**(727-746,781-791:`root` 回调仅在命中 root 标签时触发);
- 未过期的 **leases**(563-663,flat lease 只保直接引用);
- 未过期 **ingest** 与 active 对象(704-724,813 c.active)。

边仅由标签推导:`references` 按 Node 类型查 bolt bucket 并 `sendLabelRefs`(`gc.go:832-934`;标签扫描 gc.go:1110-1134 用 bolt cursor 前缀匹配)。关键三类边:image→target content(gc.go:870-882);content→`gc.ref.content.*` 各子 blob;snapshot→parent bolt 链 + 标签引用(gc.go:848-866)。容器→snapshot 通过 container bucket 的 snapshotter/snapshotKey 字段(gc.go:908-920)。pull 期间防误删靠 lease(`client/pull.go:86`)与提取快照上的 `gc.root`(`core/snapshots/snapshotter.go:213-216` 文档示例)。

触发由调度器完成:`plugins/gc/scheduler.go` 监听元数据变脏(mutationCallback:220),按"平均 GC 耗时 / pause 阈值"自适应排期(236-350),而非固定周期。

### 5.3 与 content/snapshot 删除的闭环

清除分两阶段:meta 事务内删 bolt 记录(`gc.go:1034` remove),再把 content/snapshotter 标脏(`db.go:400-413` dirtyCS/dirtySS),提交后异步调各 store 的真实删除并发布 `/snapshot/remove`、`/images/delete` 事件(`db.go:440-455`;`db.go:348-368` publishEvents)。

---

## 6. 设计动机

1. **content 与 snapshotter 分离**:blob 层是内容寻址、全局去重、跨 snapshotter 复用的"事实";快照层是文件系统状态,依赖本地内核能力(overlayfs/btrfs/devmapper),同一份 blob 可同时喂多个 snapshotter、多个平台。去重发生在两层:blob 按 digest 天然去重(`writer.go:148-154`),快照按 chainID 命名去重(`unpacker.go:499-509`)——镜像共享层只存一份字节、一份展开态。
2. **ingest 为何可恢复**:layer 动辄数百 MB,断网重下代价高;ref 定长哈希目录 + data 文件偏移 + 哈希重放,让"写了一半"成为一等公民状态。代价是 resume 的 O(n) 重哈希,换取 crash-safe 与多 worker 续写同一 ref 的统一语义。
3. **overlayfs 的 upperdir 语义**:committed 快照的 `fs` 目录是"该层相对父层的差异";lowerdir 串联全部父差异,upperdir+workdir 提供写时复制。层不可变(只读 lowerdir)、容器写全部落在最上 active 的 upperdir,这与镜像层只读模型严格同构;`index=off` 则避免 inode 索引导致从容器内再触发 copy_break/镜像层校验问题。
4. **GC 用标签而非外置图**:引用关系分散写入各对象的 labels(bolt 内),标记时集中读取——写路径零额外协调(任何组件打标签即建边),读路径一次全库扫描。三色标记与 bolt 读事务配合,在单写者锁下天然一致性。
5. **镜像 = 一条引用记录**:image 记录不含层级数据,只存 Name+Target;这让 pull/unpack/export 天然解耦,也为多平台(index)与 referrers(证明、attestation)留了同一套 descriptor 递归模型。

---

## 7. FAQ 素材

1. **Q: pull 时 manifest/config/layer 的下载顺序?** A: Dispatch 按描述符树递归:index→manifest→config→layer;但 layer 下载被 unpacker 延迟到 config 读完、算出 diffIDs 之后(core/unpack/unpacker.go:285-321)。
2. **Q: 断点续传存在哪一级?** A: 两级。HTTP 层 fetcher 用 Range 并行/续传(需要 Seekable body);落盘层 ingest 目录按 ref 保存 data+offset,重启后 Writer() 重放哈希续写(plugins/content/local/store.go:567-581)。
3. **Q: 为什么同一镜像第二次 pull 几乎瞬时?** A: Resolve 后每个 blob Writer 打开时命中 blobs 目标即 ErrAlreadyExists(handlers.go:131-133 吞掉),unpack 阶段 chainID 快照已存在直接跳过(unpacker.go:499-509)。
4. **Q: 镜像删了,层文件什么时候消失?** A: 不立即。删 image 记录只删引用;GC 跑完后才扫出无根 blob/snapshot 并分两阶段删除(db.go:383-455)。
5. **Q: chainID 是什么?** A: diffIDs 的前缀累加哈希(identity.ChainIDs,unpacker.go:448-450);同一起点相同层序列必有相同 chainID,因此可作为快照去重键与 committed 快照名。
6. **Q: whiteout 在哪处理?** A: apply 阶段。fsApplier.Apply 解包时由 archive 层把 OCI whiteout 转成 overlayfs 字符设备或删除操作(core/diff/apply/apply.go:62-144;并行 unpack 时 unpacker 还要把 bind mount 重组为 overlay 形式以便正确处理 whiteout,unpacker.go:626-632)。
7. **Q: 容器 runc 拿到的 rootfs 是什么?** A: 不是目录路径,而是 snapshotter.Mounts 生成的挂载参数数组,直接进 CreateTaskRequest.Rootfs 交 runtime 挂载(client/container.go:344-363)。
8. **Q: pull 能限速/限并发吗?** A: 能。MaxConcurrentDownloads、ConcurrentLayerFetchBuffer、下载 limiter 从 RemoteOpt 注入 resolver(client/pull.go:55-61);unpack 另有独立 unpackLimiter(unpacker.go:593)。
9. **Q: 多个容器同时 pull 同一镜像会冲突吗?** A: ingest 单 ref 单写者 + OpenWriter 退避等待(content/helpers.go:149-179);unpack 按 chainID/blob 加 kmutex 锁去重(unpacker.go:463,786)。
10. **Q: schema1 镜像还能拉吗?** A: 不能,Resolve 与 fetch 两处都直接报错并提示重建为 schema2/OCI(resolver.go:447-450;client/pull.go:223-227)。

## 深挖方向

1. **remote snapshot(延迟加载)协议**:`LabelSnapshotRef` 让 snapshotter 返回 ErrAlreadyExists 即跳过下载解包(core/snapshots/snapshotter.go:38-42),结合 NRI/代理 snapshotter 可实现按需拉取——对照 unpacker.go:494-520 的三重重试逻辑。
2. **并行 unpack + rebase 能力**:RebaseCap(UNPACK 与 snapshotter 能力协商,snapshotter.go:62-66)如何让各层独立 Prepare/apply、按序 Commit,以及 overlay 场景 bindToOverlay workaround(unpacker.go:893;issue #13030)。
3. **lease 的 flat 语义与条件引用**:`gc.flat` 与 `gc.cond.snapshot`(usedat)如何支撑 kernel 模块/sandbox 的精细生命周期(core/metadata/gc.go:97-118,526-552)。
4. **fsverity 内容完整性**:local store Commit 时 Enable(writer.go:165-169)与 internal/fsverity 的探测,对比采信 digest 之外的第二道防线。
5. **GC 调度自适应算法**:interval = avg/pauseThreshold - avg 的推导与抖动(plugins/gc/scheduler.go:305-350),对比 JVM 并发标记周期的设置经验。

---

## 写作要点速查表

| # | 事实 | 位置 |
|---|---|---|
| 1 | content.Store 四接口组合 Manager/Provider/IngestManager/Ingester | core/content/content.go:41-46 |
| 2 | blob 路径 = blobs/<alg>/<hex> | plugins/content/local/store.go:646-652 |
| 3 | ingest 目录含 ref/data/startedat/updatedat/total | plugins/content/local/store.go:589-605,666-674 |
| 4 | resume 时重放 data 求出 offset | plugins/content/local/store.go:501-529 |
| 5 | Commit:校验→rename 转正→去只读 | plugins/content/local/writer.go:111-156,198-202 |
| 6 | 镜像记录仅 Name+Labels+Target | core/images/image.go:35-56 |
| 7 | Snapshotter 五方法接口与生命周期文档 | core/snapshots/snapshotter.go:281-377 |
| 8 | overlay 目录: snapshots/<id>/{fs,work} | plugins/snapshots/overlay/overlay.go:536-553,620-626 |
| 9 | workdir/upperdir/lowerdir 组装三分支 | plugins/snapshots/overlay/overlay.go:555-618 |
| 10 | 快照父子链 bolt 实现,ParentIDs 回收 | core/snapshots/storage/bolt.go:217-293 |
| 11 | docker.io → registry-1.docker.io | core/remotes/docker/resolver.go:141-146 |
| 12 | Resolve 信任 Docker-Content-Digest 头 | core/remotes/docker/resolver.go:393-405 |
| 13 | 401 challenge → OAuth POST→GET 退避→匿名 token | core/remotes/docker/authorizer.go:153-213,275-348 |
| 14 | layer 并行分块下载(Range + bufferPool) | core/remotes/docker/fetcher.go:488-560 |
| 15 | unpack 时机:config 读完才触发;Prepare/Apply/Commit 与下载流水线 | core/unpack/unpacker.go:285-321,452-653 |
| 16 | chainID 快照去重 + gc.ref.snapshot 回链 | core/unpack/unpacker.go:499-509,745-751 |
| 17 | GC 标签协议(root/ref/bref/expire) | core/metadata/gc.go:66-118 |
| 18 | scanRoots 根:images/containers/leases/gc.root 标记 | core/metadata/gc.go:495-829 |
| 19 | 三色标记 + Sweep | pkg/gc/gc.go:64-100,182-194 |
| 20 | Mount 结构体与 runc 交接(client 侧) | core/mount/mount.go:35-53;client/container.go:328-367 |

*(报告完,全文行号基于 commit f6132db)*
