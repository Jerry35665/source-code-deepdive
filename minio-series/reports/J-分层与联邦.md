# J - 分层（Tiering）与站点复制（Site Replication）

> 《MinIO 深读》卷二 · 第 4 章（卷末）
> 代码基线：minio/minio @ commit **7aac2a2**（"update README.md format and clarify state of the project"）。
> 本文所有 `文件:行号` 均为该 commit 下经 grep/Read 实际核对的结果。

**先纠正一个路径印象**：本 commit 的仓库里**没有** `internal/config/tier/` 目录——远程 tier 的配置管理在 `cmd/tier.go`（`TierConfigMgr`），四种后端在 `cmd/warm-backend-*.go`；`internal/config/ilm/` 只有 transition/expiration worker 数等运行参数（`internal/config/ilm/ilm.go:26-44`）。tier 的类型定义（`madmin.TierConfig/TierMinIO/TierS3/TierAzure/TierGCS`）在外部依赖 madmin-go 中。

---

## 1. 全景：两条"外延"链路

MinIO 集群向外延伸有两条彼此独立的链路：**分层**把冷数据的"内容"外包给对象存储、自己只留元数据；**站点复制**把"配置与身份"在多个对等集群间同步，对象数据则复用桶级复制通道。

```
                       ILM transition（分层，单向）
  ┌───────────────────────────┐        ┌──────────────────────────────┐
  │  MinIO 集群（hot tier）    │        │  远程 tier（cold，四选一）      │
  │  ┌─────────────────────┐  │  PUT   │  minio / s3 / azure / gcs    │
  │  │ xl.meta（元数据保留） │──┼───────▶│  bucket/prefix/…             │
  │  │ data 已删除=free-ver │◀─┼──GET───┤                              │
  │  └─────────────────────┘  │ restore│  (整个对象原样上传，不解 EC)   │
  └───────────────────────────┘        └──────────────────────────────┘

                       Site Replication（联邦，对等）
  ┌──────────────┐   admin API(madmin)+svcacct    ┌──────────────┐
  │   Site A     │◀──────────────────────────────▶│   Site B     │
  │ deploymentID │   IAM/策略/桶元数据/ILM到期规则   │ deploymentID │
  │      │       │───────────────────────────────▶│      │       │
  │      ▼       │   对象数据：桶复制规则 site-repl-*│      ▼       │
  │ bucket repl  │◀───────────────────────────────│ bucket repl  │
  └──────────────┘   （复用 bucket replication 队列）└──────────────┘
```

分层是"集群 → 云"的**单向内容外包**；站点复制是"集群 ↔ 集群"的**对等元数据/配置同步**。两者在 ILM 到期规则上交汇：站点复制可选地同步 ILM expiry 规则（`cmd/site-replication.go:6243-6249`、`cmd/site-replication.go:6139`）。

---

## 2. Tiering 专节：四种远程 tier 与 free-version 记账

### 2.1 tier 配置的宿主：TierConfigMgr

`TierConfigMgr` 持有全部远程 tier 配置和一份驱动缓存（`cmd/tier.go:88-95`）。配置序列化为 `tier-config.bin` 存进元数据桶，KMS 可用时加密（`cmd/tier.go:80-84`、`cmd/tier.go:426-473`）：

```go
// cmd/tier.go:88-95
type TierConfigMgr struct {
	sync.RWMutex `msg:"-"`
	drivercache  map[string]WarmBackend `msg:"-"`

	Tiers           map[string]madmin.TierConfig `json:"tiers"`
	lastRefreshedAt time.Time                    `msg:"-"`
}
```

添加 tier 的硬约束：名字必须全大写、不得重复、远程桶不能已被别的 MinIO 租户使用（`cmd/tier.go:214-249`）；`WARM` 保留名与 STANDARD/RRS 存储类名被拒（`cmd/tier-handlers.go:64-69`、`cmd/tier-handlers.go:99-104`）。Admin API `AddTierHandler` 走 `Reload→Add→Save→广播`（`cmd/tier-handlers.go:72-126`），`Save` 把配置 PUT 回元数据桶（`cmd/tier.go:505-517`），再经 `globalNotificationSys.LoadTransitionTierConfig` 通知同集群其它节点（`cmd/tier-handlers.go:123`）；另有 15 分钟周期的 `refreshTierConfig` 兜底（`cmd/tier.go:527-530`）。

### 2.2 四种后端：一个接口，四种实现

`WarmBackend` 接口只有五个方法（`cmd/warm-backend.go:39-45`）：

```go
// cmd/warm-backend.go:39-45
type WarmBackend interface {
	Put(ctx context.Context, object string, r io.Reader, length int64) (remoteVersionID, error)
	PutWithMeta(ctx context.Context, object string, r io.Reader, length int64, meta map[string]string) (remoteVersionID, error)
	Get(ctx context.Context, object string, rv remoteVersionID, opts WarmBackendGetOpts) (io.ReadCloser, error)
	Remove(ctx context.Context, object string, rv remoteVersionID) error
	InUse(ctx context.Context) (bool, error)
}
```

`newWarmBackend` 按 `tier.Type` 分派到 S3/Azure/GCS/MinIO 四种构造器（`cmd/warm-backend.go:134-146`）。配置时用探针对象做一次 Put/Get/Remove 权限体检（`cmd/warm-backend.go:51-91`）。MinIO 后端内嵌 S3 后端，只是强制了分片参数：最小分片 128MiB、最多 10000 片（`cmd/warm-backend-minio.go:40-79`），凭据用静态 AK/SK（`cmd/warm-backend-minio.go:99-136`）；S3 后端额外支持 AWS IAM role 与 WebIdentity token（`cmd/warm-backend-s3.go:109-161`）。

### 2.3 上传的是什么？"整个对象"而非"EC 分片"

这是与纠删码关系的关键事实：**transition 时把对象的完整数据流（已解出或 inline 的原始加密流）原样 PUT 到远程**，不做任何 EC 相关的切块。`erasureObjects.TransitionObject` 先取全量 FileInfo，若是旧 XL 格式先自愈升级，然后生成随机远程对象名并 `PutWithMeta`（`cmd/erasure-object.go:2350-2418`）：

```go
// cmd/erasure-object.go:2401-2418
destObj, err := genTransitionObjName(bucket)
...
pr, pw := xioutil.WaitPipe()
go func() {
	err := er.getObjectWithFileInfo(ctx, bucket, object, 0, fi.Size, pw, fi, metaArr, onlineDisks)
	pw.CloseWithError(err)
}()

var rv remoteVersionID
rv, err = tgtClient.PutWithMeta(ctx, destObj, pr, fi.Size, map[string]string{
	"name": object, // preserve the original name of the object on the remote tier object metadata.
```

远程对象名是 `hash(deploymentID+bucket)/uuid 前缀/uuid` 的随机名（`cmd/bucket-lifecycle.go:674-683`），远程元数据里带 `name` 便于反查。加密对象**不解密**——"entire encrypted stream is moved to the transition tier without decrypting or re-encrypting"（`cmd/bucket-lifecycle.go:685-688`）。上传成功后把 `TransitionStatus=complete`、远程名、tier 名、远程 VersionID 写回本地元数据，并 `deleteObjectVersion` 删除本地数据（保留元数据版本，`cmd/erasure-object.go:2424-2432`）。

### 2.4 free-version：远程回收的"待办便签"

本地版本删除时，若该版本已 transitioned，就生成一个 `TierFreeVersionID`（`cmd/erasure-object.go:2078-2107`，`renameData` 批量路径在 `cmd/erasure-object.go:1018-1025`；`DeleteObjects` 在 `cmd/erasure-object.go:1685`）。free-version 只是元数据里的两个保留键（`cmd/erasure-metadata.go:566-617`）：

```go
// cmd/erasure-metadata.go:566-570
const (
	tierFVID     = "tier-free-versionID"
	tierFVMarker = "tier-free-marker"
	tierSkipFVID = "tier-skip-fvid"
)
```

这就是 C 报告提过的 free-version 跟踪：本地只留一条"影子版本"，记住远程还有一个对象待删。扫描器在 `NSScanner` 里把扫到的 free-version 逐个入队（`cmd/xl-storage.go:679-685`），worker 收到 `freeVersionTask` 后**先删远程、成功后再删本地影子版本**（`cmd/bucket-lifecycle.go:357-390`）：

```go
// cmd/bucket-lifecycle.go:372-384
// Remove the remote object
err := deleteObjectFromRemoteTier(es.ctx, oi.TransitionedObject.Name, oi.TransitionedObject.VersionID, oi.TransitionedObject.Tier)
...
// Remove this free version
_, err = es.objAPI.DeleteObject(es.ctx, oi.Bucket, oi.Name, ObjectOptions{
	VersionID:        oi.VersionID,
	InclFreeVersions: true,
})
```

同步路径（非扫描器）则用 `objSweeper`：对象被覆盖/删除后 `Sweep()` 生成 `jentry` 入 `globalExpiryState`（`cmd/tier-sweeper.go:103-143`，`cmd/tier-sweeper.go:130-136`），jentry worker 直接 `deleteObjectFromRemoteTier`（`cmd/bucket-lifecycle.go:355-356`、`cmd/tier-sweeper.go:145-151`）。反向保险是 `SkipFreeVersion`：ILM 主动到期且远程已确认删除时，跳过生成影子版本（`cmd/bucket-lifecycle.go:634-642`，置位于 `cmd/erasure-object.go:2108-2109/2140-2141`）。

**记账口径**：扫描器统计 tier 用量时明确跳过 delete-marker 与 free-version（`cmd/xl-storage.go:659-676`），因此 free-version 不占"已用容量"统计；transition 成功即时计入 24 小时滚动统计 `lastDayTierStats`（24 个小时桶，`cmd/tier-last-day-stats.go:28-39/42-66`，写入点 `cmd/bucket-lifecycle.go:509-518/524-532`）。

---

## 3. Restore 专节：临时副本与 `x-amz-restore`

restore 语义完全对齐 AWS Glacier 的 `PostObjectRestore`（`cmd/erasure-object.go:2457-2461` 注释）。HTTP 入口是 `PostRestoreObjectHandler`（`cmd/object-handlers.go:3396-3505`）：校验对象必须 `TransitionComplete`（3440-3443 行）、解析 XML 请求（845-865 行定义 `RestoreObjectRequest`，含 `Days/Type/Tier/SelectParameters`）、然后**先用 metadata-only CopyObject 把 `x-amz-restore: ongoing-request="true"` 写进元数据**，再在后台 goroutine 里做真恢复（`cmd/object-handlers.go:3475-3516`）。重复 restore 且未过期时只刷新到期时间，返回码用 200 而非 202（`cmd/object-handlers.go:3460-3470`）。

真正的数据搬运在 `restoreTransitionedObject`（`cmd/erasure-object.go:2487-2556`）：单分片对象直接从远程 tier 拉 reader 重新 `PutObject`；多分片对象**按原 xl.meta 的分片表逐段 rehydrate**——从远程流里 `LimitReader` 出每个 part 的大小重新上传，保证本地分片布局与 transition 前一致（`cmd/erasure-object.go:2534-2551`）。PUT 的选项由 `putRestoreOpts` 构造，关键是写入完成态的 restore 头（`cmd/bucket-lifecycle.go:967-977`）：

```go
// cmd/bucket-lifecycle.go:967-975
// Set restore object status
restoreExpiry := lifecycle.ExpectedExpiryTime(time.Now().UTC(), rreq.Days)
meta[xhttp.AmzRestore] = completedRestoreObj(restoreExpiry).String()
return ObjectOptions{
	Versioned:        globalBucketVersioningSys.PrefixEnabled(bucket, object),
	VersionSuspended: globalBucketVersioningSys.PrefixSuspended(bucket, object),
	UserDefined:      meta,
	VersionID:        objInfo.VersionID,
```

到期时间由 `ExpectedExpiryTime` 计算（`internal/bucket/lifecycle/lifecycle.go:531`）。`restoreObjStatus` 的 `OnDisk()` 用"未到期即视为在盘"判定（`cmd/bucket-lifecycle.go:1049-1055`），`ObjectInfo.IsRemote()` 则是"已 transition 且盘上无 restore 头"（`cmd/bucket-lifecycle.go:993-998`）。restore 到期后的清理走 ILM 的 `DeleteRestored` 动作：只删本地临时副本，远程内容不动（`cmd/bucket-lifecycle.go:620-631`）。另外，即使不 restore，GET 也能直接透传远程 tier——`GetObject` 检测 `objInfo.IsRemote()` 后改走 `getTransitionedObjectReader`（`cmd/erasure-object.go:274-281`，实现在 `cmd/bucket-lifecycle.go:753-780`），并顺带记录 TTLB 指标（`cmd/tier.go:111-120`）。

---

## 4. 站点复制专节：对等的"元数据联邦"

### 4.1 状态与入伙

`SiteReplicationSys` 的持久化状态极小：站点名、`deploymentID→PeerInfo` 映射、共享服务账号 access key（`cmd/site-replication.go:211-229`），存于 `config/site-replication/state.json`（`cmd/site-replication.go:55-60`）。加入流程 `AddPeerClusters` 的核心校验：deploymentID 不得重复、IDP（LDAP 等）设置必须一致、**"要么全部空集群，要么只有一个集群有数据"**（`cmd/site-replication.go:397-467`）。发起方创建固定名服务账号 `site-replicator-0`（`cmd/site-replication.go:349-351`），把凭据连同完整 peers 表通过内部 admin API `PUT /site-replication/peer/join` 推给每个站点（`cmd/site-replication.go:502-507`、路由 `cmd/admin-router.go:388`）；对端 `PeerJoinReq` 落盘同构状态（`cmd/site-replication.go:614-665`）。

### 4.2 复制的对象范围

| 范围 | 触发 Hook / Handler | 位置 |
|---|---|---|
| 桶创建+版本化 | `MakeBucketHook`→`PeerBucketMakeWithVersioningHandler` | `cmd/site-replication.go:797-857`、`:891` |
| IAM 用户/组/策略/映射/STS/SvcAcct | `IAMChangeHook` + 五个 `Peer*Handler` | `cmd/site-replication.go:1207-1228`、`:1232/:1252/:1292/:1331/:1410/:1463` |
| 桶元数据（versioning/tagging/policy/SSE/lock/quota） | `BucketMetaHook` + 各 `PeerBucket*Handler` | `cmd/site-replication.go:1523-1545`、`:1547-1813` |
| ILM 到期规则（可选） | `PeerBucketLCConfigHandler` + `mergeWithCurrentLCConfig` | `cmd/site-replication.go:1784-1813`、`:6139-6241` |
| **对象数据** | 不走 peer 协议——`PeerBucketConfigureReplHandler` 为每个对端建桶复制规则 | `cmd/site-replication.go:936-1050` |

对象数据的做法值得展开：每个桶为每个对端建一条 ID 为 `site-repl-<deploymentID>` 的桶复制规则与对应 remote target（`cmd/site-replication.go:977-1006`），之后数据同步完全复用既有 bucket replication 管线。也就是说 SR 只是"配置面"的联邦，"数据面"仍是单向桶复制 × N 个对端。

### 4.3 peer 通信的复用与冲突消解

所有跨站点操作都经 `concDo` 并发扇出到全部 peers——本站执行 `selfActionFn`，远端经 madmin admin client 调 `peerActionFn`（`cmd/site-replication.go:2281-2314`）；凭据就是那个共享服务账号（`cmd/site-replication.go:1814-1848`）。协议本体是 admin API 的 `peer/iam-item`、`peer/bucket-meta`、`peer/bucket-ops` 等端点（`cmd/admin-router.go:388-395`），处理端再调对应 `Peer*Handler` 写入本地（`cmd/admin-handlers-site-replication.go:149-270`）。**没有独立二进制协议、没有 consensus**：一致性靠"每次变更全量扇出 + 时间戳仲裁 + 周期自愈"。

冲突消解的样板是"陈旧信息不覆盖本地新写"——handler 先比 `UpdatedAt`（`cmd/site-replication.go:1232-1248`）：

```go
// cmd/site-replication.go:1232-1239
func (c *SiteReplicationSys) PeerAddPolicyHandler(ctx context.Context, policyName string, p *policy.Policy, updatedAt time.Time) error {
	var err error
	// skip overwrite of local update if peer sent stale info
	if !updatedAt.IsZero() {
		if p, err := globalIAMSys.store.GetPolicyDoc(policyName); err == nil && p.UpdateDate.After(updatedAt) {
			return nil
		}
	}
```

环的打断依赖两点：(1) `Peer*Handler` 是"应用者"不是"转发者"，收到的变更只落本地、不再扇出，天然无风暴；(2) 30 秒周期的 `startHealRoutine`（leader 执行）对 IAM 与桶元数据做全量对账补差（`cmd/site-replication.go:4255-4292`、`:5239`、`:4436`）， ILRM 到期规则的合并逻辑还会刻意保留各站自己的 transition 部分、只同步 expiry 部分（`cmd/site-replication.go:6194-6208`）。此外 `SiteReplicationStatus`（`cmd/site-replication.go:2695`）能对桶元数据、策略、用户、组、ILM 到期规则逐项给出 replicated/unreplicated 判定（`:3380-3602`），供运维定位不一致；断链后的补数据走 `startResync`（`:5750`）。

---

## 5. 设计动机

**为什么分层要保留本地元数据（free-version）？**
- S3 兼容语义要求 `HEAD/LIST` 对 tiered 对象照常可见：删除一个已外迁的版本时，远程删除是**跨网络、可能失败**的操作。若同步删远程再删本地，删除路径会被远程可用性绑架。留一条 free-version 影子，把"远程删除"异步化，本地删除依然只需一次 EC 元数据写入（`cmd/erasure-object.go:2098-2122`）。
- 影子版本自带 `TierFreeVersionID`，即使节点崩溃、消息丢失，下次扫描器路过也能重拾清扫（`cmd/xl-storage.go:679-685`）——这是"用扫描器兜底一切异步任务"哲学的又一例。
- 元数据里保留 transition 状态也让 GET 可以按需透传远程（`cmd/erasure-object.go:274-281`），对象"看起来还在"。

**为什么上传整个对象而不传 EC 分片？**
- 远程 tier 是标准 S3/Azure/GCS 对象存储，没有 EC 概念；存原始流才能让远程桶被独立审计/搬移。
- 安全上原样搬运密文流，KMS 侧无需把解密能力外泄到 transition 路径（`cmd/bucket-lifecycle.go:685-688`）。

**为什么站点复制复用 admin API（madmin + svcacct）而非独立协议？**
- 复用鉴权（服务账号）、复用 TLS/传输、复用 madmin 客户端代码；peer 端 handler 就是普通本地写函数，新增一种可复制对象只需加一对 Hook/Handler。
- 对等模型下每个站点都能独立发起变更，"扇出 + 时间戳 + 周期 heal"足够最终一致，无需引入 Raft 跨站（跨站共识在 WAN 上得不偿失）。
- 数据面不发明新协议：桶复制早已解决带宽限速、排队、断点重传，SR 直接为每个对端配置一条规则即可（`cmd/site-replication.go:936-1006`）。

---

## 6. FAQ 素材

1. **Q: tier 配置存在哪？** A: 元数据桶内 `tier-config.bin`（`cmd/tier.go:84`），KMS 启用时 SSE-C 加密落盘（`cmd/tier.go:446-451`），不走 etcd/环境文件。
2. **Q: 四种 tier 有优先级或级联吗？** A: 没有。一个桶规则只指向一个 tier 名；多 tier 是"不同 ILM 规则指向不同 StorageClass"，MinIO 侧不做 tier 间自动晋升。
3. **Q: transition 后本地还占多少空间？** A: 只剩 xl.meta；数据块被 `deleteObjectVersion` 删除（`cmd/erasure-object.go:2432`），扫描器统计口径也不再计入该 tier（`cmd/xl-storage.go:659-676`）。
4. **Q: free-version 什么时候真正消失？** A: 扫描器发现后入队，worker 删远程成功→再删本地影子（`cmd/bucket-lifecycle.go:372-384`）；远程已删（SkipFreeVersion 场景）则影子根本不产生。
5. **Q: GET 一个 tiered 对象会先 restore 吗？** A: 不会，直接透传远程 reader（`cmd/erasure-object.go:274-281`），延迟计入 `tier_ttlb_seconds` 直方图（`cmd/tier.go:111-115`）；只有 POST restore 才落本地副本。
6. **Q: restore 的副本会永久存在吗？** A: 不会，`x-amz-restore` 头带 expiry-date（`cmd/bucket-lifecycle.go:967-969`）；到期后 ILM `DeleteRestored` 只删本地副本（`cmd/bucket-lifecycle.go:620-631`）。
7. **Q: restore 时本地分片布局会变吗？** A: 不会，多分片按原 part 表 rehydrate（`cmd/erasure-object.go:2534-2551`），单分片整对象重 PUT（`:2504-2517`）。
8. **Q: 站点复制复制对象数据吗？** A: 不直接复制；SR 为每个对端配 `site-repl-<deploymentID>` 桶复制规则，数据走桶复制通道（`cmd/site-replication.go:977-1006`）。
9. **Q: 两个站点同时改同一条策略会怎样？** A: 双方都会扇出，接收方按 `UpdatedAt` 丢弃陈旧方（`cmd/site-replication.go:1234-1239`）；后写者胜，最终由周期 heal 对账收敛。
10. **Q: 新站点必须为空吗？** A: 要么全空，要么恰好一个站点有数据且请求必须发给它（`cmd/site-replication.go:454-462`）。

## 7. 深挖方向

1. **`madmin-go` 侧的 TierConfig 定义**：`TierConfig/TierMinIO/TierS3/TierAzure/TierGCS` 的字段与 JSON 标签，以及 `TierType` 的 msgp 编码——tier 配置二进制格式（`cmd/tier.go:386-395`）的另一半。
2. **transition 的并发与限流**：`transitionCh` 容量 100000（`cmd/bucket-lifecycle.go:450`），worker 数可配 `ilm.transition_workers`（`internal/config/ilm/ilm.go:26-44`，`cmd/bucket-lifecycle.go:459-470`），积压计数暴露为 metrics（`cmd/bucket-lifecycle.go:474-487`）。
3. **站点 resync 的断点续传**：`SiteResyncStatus` 持久化到 `bucketMetaPrefix/site-replication/resync`（`cmd/site-replication-utils.go:31-33`、`cmd/site-replication.go:5994-6046`）。
4. **decommission 与 tier 的交互**：`DecomTieredObject` 只重写元数据不动远程（`cmd/erasure-object.go:2558-2599`）——换池不换远程对象名的证据。
5. **SR 状态查询的缓存**：`srIAMCache` 对 meta-info 查询做 `siteHealTimeInterval` 级缓存（`cmd/site-replication.go:3604-3628`）。

---

## 8. 写作要点速查表

| 主题 | 函数/类型 | 位置 |
|---|---|---|
| tier 配置管理器 | `TierConfigMgr` | cmd/tier.go:88-95 |
| 添加 tier 校验+入册 | `TierConfigMgr.Add` | cmd/tier.go:214-249 |
| 四后端分派 | `newWarmBackend` | cmd/warm-backend.go:134-159 |
| 后端接口 | `WarmBackend` | cmd/warm-backend.go:39-45 |
| MinIO 后端 Put | `warmBackendMinIO.PutWithMeta` | cmd/warm-backend-minio.go:81-93 |
| S3 后端构造（含 IAM role） | `newWarmBackendS3` | cmd/warm-backend-s3.go:109-182 |
| tier Admin API | `AddTierHandler` | cmd/tier-handlers.go:72-126 |
| scanner 触发 transition | `applyTransitionRule` | cmd/data-scanner.go:1202-1208 |
| transition 主流程（整对象上传） | `erasureObjects.TransitionObject` | cmd/erasure-object.go:2350-2455 |
| 远程对象名生成 | `genTransitionObjName` | cmd/bucket-lifecycle.go:674-683 |
| free-version 元数据键 | `tierFVID/tierFVMarker` | cmd/erasure-metadata.go:566-617 |
| free-version 清扫 worker | `expiryState.Worker` freeVersionTask 分支 | cmd/bucket-lifecycle.go:357-390 |
| 扫描器入队 free-version | `NSScanner` 内 | cmd/xl-storage.go:679-685 |
| 同步删除记账 | `objSweeper.shouldRemoveRemoteObject` | cmd/tier-sweeper.go:103-131 |
| restore 入口 | `PostRestoreObjectHandler` | cmd/object-handlers.go:3396-3600 |
| restore 数据回灌（分片 rehydrate） | `restoreTransitionedObject` | cmd/erasure-object.go:2487-2556 |
| restore 状态头 | `putRestoreOpts`/`restoreObjStatus` | cmd/bucket-lifecycle.go:935-978/1002-1055 |
| SR 状态与持久化 | `srStateV1`/`loadFromDisk` | cmd/site-replication.go:211-294 |
| SR 入伙校验 | `AddPeerClusters` | cmd/site-replication.go:397-467 |
| 扇出执行器 | `concDo` | cmd/site-replication.go:2281-2314 |
| 数据面挂接 | `PeerBucketConfigureReplHandler` | cmd/site-replication.go:936-1006 |
| 陈旧写仲裁 | `PeerAddPolicyHandler` | cmd/site-replication.go:1232-1248 |
| 周期对账 | `startHealRoutine` | cmd/site-replication.go:4257-4292 |
