# C — 对象版本模型与删除语义（MinIO 深读·卷一第 3 章）

> 调研对象：minio/minio @ commit `7aac2a2`（7aac2a2c5b7c882e68c1ce017d8256be2feea27f）。
> 本文所有 `文件:行号` 均为仓库相对路径，已在上述 commit 上逐一核对。
> 前情：B 篇讲了纠删码与写入路径；本篇讲**一个对象名下多个版本如何共存于一份 xl.meta、删除如何变成一条记录、以及谁最终回收数据**。

---

## 1. 全景：一个对象的版本生命周期

MinIO 没有"版本数据库"——**每个对象名（bucket/object）只有一份 xl.meta 文件，所有版本（含删除标记）都是这份文件内的数组元素**。数据本体则各住各的 UUID 目录（或内联在 xl.meta 里）：

```
磁盘目录（cmd/xl-storage-format-v2.go:90-102 注释原文给出）
bucket/object/
├── a192c1d5-…/part.1      ← v1 的数据目录（DataDir）
├── c06e0436-…/part.1      ← v2 的数据目录
└── xl.meta                ← 唯一的元数据文件，内含全部版本 journal
```

一个版本化对象的一生（Put v1 → Put v2 → DELETE → 过期回收）：

```
 Put "obj" v1          Put "obj" v2            DELETE obj (未带 versionID)
      │                     │                          │
      ▼                     ▼                          ▼
 versions: [v1]       versions: [v2,v1]      versions: [DM,v2,v1]      ILM/RemoveObjects
 (IsLatest=v1)        (IsLatest=v2)          (IsLatest=DM→GET 404)         │
                                                   │                        ▼
                                                   │              versions: [DM,v2,v1]
                                                   │              逐版本 DeleteVersion：
                                                   │              v1 数据目录进垃圾桶
                                                   │                      │
                                                   ▼                      ▼
                              ListObjectsV2: 最新是 DM → 对象"不存在"     versions: []
                              ListObjectVersions:                        xl.meta 整个删除，
                              DM、v2、v1 全部可见                        对象名消失
```

要点：**Put 是往数组头插一条记录**；**未带 versionID 的 DELETE 是再插一条"删除标记"记录**（不删任何东西）；**只有显式按 versionID 的删除（或 ILM）才从数组中摘除记录并回收 DataDir**；数组空了，xl.meta 与对象目录一起消失。

---

## 2. xl.meta 版本布局专节

### 2.1 文件级布局：header + 逐版本 (header, meta) + CRC + 内联数据

写入方是 `xlMetaV2.AppendTo`（cmd/xl-storage-format-v2.go:1176-1231）：

```go
dst = append(dst, xlHeader[:]...)        // "XL2 "，4 字节（:52-56 定义）
dst = append(dst, xlVersionCurrent[:]...)// major/minor 各 2 字节（:68-71 填充）
dst = append(dst, 0xc6, 0, 0, 0, 0)      // bin32 占位，回填内联数据长度
dataOffset := len(dst)
dst = msgp.AppendUint(dst, xlHeaderVersion)   // =3（:464）
dst = msgp.AppendUint(dst, xlMetaVersion)     // =3（:465）
dst = msgp.AppendInt(dst, len(x.versions))    // 版本个数
for _, ver := range x.versions {
    tmp, err = ver.header.MarshalMsg(tmp[:0]) // 每版本：紧凑 header
    dst = msgp.AppendBytes(dst, tmp)
    dst = msgp.AppendBytes(dst, ver.meta)     // 每版本：完整 msgp 元数据
}
binary.BigEndian.PutUint32(dst[dataOffset-4:dataOffset], ...) // 回填长度
// 追加 xxhash CRC（:1226-1229），最后追加内联数据 x.data（:1230）
```

读取侧 `checkXL2V1`（:221-241）校验 `"XL2 "` 魔数与主版本号；`loadIndexed`（:945-1032）按数量逐个反序列化到 `xlMetaV2ShallowVersion{header, meta []byte}`（:894-897）——**懒解码**：只解析 16 字节级的小 header，完整版本体按需 `getIdx` 解开。

### 2.2 内存结构：versions 数组 + 内联数据

```go
type xlMetaV2 struct {
    versions []xlMetaV2ShallowVersion   // cmd/xl-storage-format-v2.go:902
    data     xlMetaInlineData           // :907  小对象数据按 versionID 内联
    metaV    uint8                      // :910  元数据格式版本
}
```

**数组约定：`versions[0]` 恒为最新版本**。两处代码维持这一不变量：

- `addVersion`（:1141-1173）：新版本按 ModTime 线性查找插入点，注释直言 "we likely have to insert at front"（:1160-1171）；
- `sortByModTime`（:1327-1341）：`sortsBefore`（:294-320）以 ModTime 降序为主键，兜底 Type/Signature/VersionID 保证全序。

### 2.3 版本条目的三种类型（外加一种隐藏类型）

`VersionType`（:104-114）：`ObjectType=1`、`DeleteType=2`、`LegacyType=3`。文件头注释（:73-88）明说 journal 里可以出现三种东西：object / delete（删除标记）/ legacy（xlV1 旧格式，覆盖前保留），以及只给扫描器看的 free-version（见 §5.3）。

每个条目是带 tag 的联合体（:181-187）：

```go
type xlMetaV2Version struct {
    Type             VersionType           `msg:"Type"`
    ObjectV1         *xlMetaV1Object       // LegacyType 用
    ObjectV2         *xlMetaV2Object       // ObjectType 用
    DeleteMarker     *xlMetaV2DeleteMarker // DeleteType 用
    WrittenByVersion uint64                // 写入它的 MinIO 版本时间戳
}
```

**对象版本 `xlMetaV2Object`（:156-175）的关键字段**：`VersionID [16]byte`、`DataDir [16]byte`（数据目录 UUID）、`ErasureM/N/BlockSize/Index/Dist`（纠删参数，B 篇主题）、`PartNumbers/PartETags/PartSizes/PartActualSizes/PartIndices`（分片表）、`Size`、`ModTime`、`MetaSys map[string][]byte`（内部元数据）、`MetaUser map[string]string`（用户元数据，如 content-type、SSE 加密信息）。

**删除标记 `xlMetaV2DeleteMarker`（:149-153）只有三个字段**：`VersionID`、`ModTime`、`MetaSys`（复制状态等内部键）——删除标记没有 DataDir、没有分片表，它在磁盘上**不占数据空间**。

**每版本短 header `xlMetaV2VersionHeader`（:249-256）**：`VersionID + ModTime + Signature(4B) + Type + Flags + EcN/EcM`。列目录、合并多盘元数据（`mergeXLV2Versions` :1923）都只用 header，不必解开全量 meta。`xlFlags`（:191-197）三个位：`FreeVersion`、`UsesDataDir`、`InlineData`。

### 2.4 上层的 FileInfo / FileInfoVersions

多盘元数据汇聚后的进程内表示（cmd/storage-datatypes.go）：

- `FileInfoVersions`（:142-155）：`Volume/Name/LatestModTime/Versions []FileInfo/FreeVersions []FileInfo`；
- `FileInfo`（:191-271）：单版本全量视图。版本语义相关字段：`VersionID`(:199)、`IsLatest`(:202)、`Deleted bool`——"本条 FileInfo 是删除标记"(:204-206)、`DataDir`(:223)、`ModTime`(:230)、`NumVersions`(:256)、`SuccessorModTime`(:257，下一新版本的修改时间，ILM 非 current 判龄用)、`Versioned`(:270)。

`FileInfo.ToObjectInfo`（cmd/erasure-metadata.go:90-181）把它翻译成 S3 视角：版本化时空 VersionID 映射为 `"null"`（:93-95），`DeleteMarker: fi.Deleted`（:105），`IsLatest`、`NumVersions`、`SuccessorModTime` 直通（:104-112）。`IsValid()`（:73-87）对删除标记直接放行——因为它没有纠删信息可校验。

---

## 3. 版本化配置专节

### 3.1 配置模型与 MinIO 扩展

XML 配置解析在 internal/bucket/versioning/versioning.go：`Versioning` 结构（:50-59）只有 `Status` 与两个 MinIO 扩展：`ExcludedPrefixes`（前缀级关闭版本化）、`ExcludeFolders`。状态只有两值（:33-37）：`Enabled` 与 `Suspended`（`Disabled` 注释说明仅 MFA Delete 使用，未支持）。`Validate`（:62-84）：excluded prefixes 最多 10 个且仅 Enabled 时可用；Suspended 时不得携带。

### 3.2 Enabled vs Suspended：判定函数

```go
func (v Versioning) PrefixEnabled(prefix string) bool {   // :98-119
    if v.Status != Enabled { return false }
    if v.ExcludeFolders && strings.HasSuffix(prefix, "/") { return false }
    for _, sprefix := range v.ExcludedPrefixes {          // 命中排除前缀 → false
        if matched := wildcard.MatchSimple(sprefix.Prefix+"*", prefix); matched { return false }
    }
    return true
}
func (v Versioning) PrefixSuspended(prefix string) bool { // :128-149
    if v.Status == Suspended { return true }
    ...// Enabled 但命中排除前缀/目录对象 → true
}
```

关键语义：**`Versioned(prefix) = PrefixEnabled || PrefixSuspended`（:92-94）**——"这个前缀上的对象以版本化方式存储"（新旧版本并存），而 Enabled 与 Suspended 的差别在**写入时是否分配新 VersionID、删除时是否产生新删除标记**（见 §4）。`cmd/bucket-versioning.go:31-68` 的 `BucketVersioningSys` 把这两个判定暴露给全服务，配置本体经 `globalBucketMetadataSys.GetVersioningConfig` 热加载（:71-78）。

### 3.3 VersionID 的产生

对象写入时（cmd/erasure-object.go:1346-1350）：

```go
fi.VersionID = opts.VersionID
if opts.Versioned && fi.VersionID == "" {
    fi.VersionID = mustGetUUID()   // 服务端生成随机 UUID 作版本号
}
fi.DataDir = mustGetUUID()         // :1352 数据目录同样每次一换
```

- **Enabled**：每次 Put 都拿新 UUID，旧版本天然保留；
- **Suspended/未开启**：`fi.VersionID` 为空，盘上落为 `"null"` 版本（cmd/xl-storage.go:57 `nullVersionID = "null"`；RenameData 里空 ID 转换：:2758-2763）。Suspended 下再写同名对象，`findVersionStr` 找到旧 null 版本后**替换**它，并把被顶掉版本的分层内容记成 free-version（:2765-2779 注释与 `AddFreeVersion`）——这就是"挂起后 null 版本被真覆盖"的落地。
- multipart 完成时同样生成：cmd/erasure-multipart.go:460。

### 3.4 DeleteMarker 是什么

删除标记 = `xlMetaV2Version{Type: DeleteType, DeleteMarker: &xlMetaV2DeleteMarker{...}}`。两个构造点：`xlMetaV2.AddVersion`（cmd/xl-storage-format-v2.go:1621-1627，`fi.Deleted` 为真即造标记）与 `DeleteVersion` 内部（:1364-1378）。读回时 `xlMetaV2DeleteMarker.ToFileInfo`（:468-496）产出 `Deleted: true` 的 FileInfo，复制的状态从 `MetaSys` 还原（:487）。

---

## 4. 删除专节：物理删 vs 标记删的两条路径

### 4.1 S3 API 层：决定"删"的形状

`delOpts`（cmd/object-api-options.go:273-318）为每个删除请求定型：`opts.Versioned = PrefixEnabled(bucket, object)`（:289），`opts.VersionSuspended = Suspended(bucket)`（:294，桶级），**目录对象未带版本号时强制删 null 版本**（:296-298）。单对象入口 `DeleteObjectHandler`（cmd/object-handlers.go:2563）挂上复制评估（:2624-2642）与 Object-Lock 绕过校验（:2652-2666）；成功后按结果发 `ObjectRemoved:Delete` 或 `ObjectRemoved:DeleteMarkerCreated` 事件（:2706-2709）。

### 4.2 erasureObjects.DeleteObject：一个函数、两种结局（cmd/erasure-object.go:1885-2148）

先读现况 `getObjectInfoAndQuorum`（:1977），然后核心判定在 :2043：

```go
deleteMarker := opts.Versioned           // :2043 默认：版本化桶的删除 = 打标记
if opts.VersionID != "" {                // :2045 显式指定版本 → 通常是"真删该版本"
    ...
    if versionFound {
        if !goi.VersionPurgeStatus.Empty() { deleteMarker = false }   // :2066
        else if !goi.DeleteMarker          { deleteMarker = false }   // :2068
    }
}
```

- **标记删路径（:2092-2126）**：`markDelete && (Versioned || VersionSuspended)` 时构造 `FileInfo{Deleted: deleteMarker, MarkDeleted: markDelete, ...}`；Suspended 且未指定版本 → `deleteMarker = opts.VersionSuspended && opts.VersionID == ""`（:2096），即**以 null 版本的身份造一条删除标记**；VersionID 为空且 Versioned → `fi.VersionID = mustGetUUID()` 给标记发新 UUID（:2111-2115）；最终 `er.deleteObjectVersion(...)`（:2120）。
- **物理删路径（:2128-2147）**：其余情况（未开版本化的桶、显式 versionID purge）构造 `dfi` 直接进 `deleteObjectVersion`——注意它**删除的是元数据记录**，数据目录的回收在盘层（下节）。
- `force-delete`（`opts.DeletePrefix`，:1925-1972）走 `deletePrefix`（:1855-1880）：对每盘递归 `Delete(Recursive: true, Immediate: true)`，是唯一绕过版本语义的真·批量物理删除；Object-Lock 桶禁止（object-handlers.go:2614-2620）。
- ILM 过期触发时（`opts.Expiration.Expire`）删除前重跑 `evalActionFromLifecycle` 复核（:1947、:2015），防止规则变化后误删。

### 4.3 deleteObjectVersion 与批量 DeleteObjects

`deleteObjectVersion`（cmd/erasure-object.go:1626-1647）对每盘并发 `disk.DeleteVersion(...)`，写仲裁统一取 **N/2+1**（:1634，注释解释删除不按存储类降仲裁）。批量接口 `DeleteObjects`（:1652-1834）：

```go
if objects[i].VersionID == "" {
    if versioned || suspended {
        vr.ModTime = UTCNow(); vr.Deleted = true          // :1698-1699 打标记
        if versioned { vr.VersionID = mustGetUUID() }     // :1703-1705
    }
}
```

随后去重排序：**同对象先执行真删、最多追加一个删除标记**（:1736-1752），再按盘并发 `disk.DeleteVersions`（:1770），逐对象 `reduceWriteQuorumErrs`（:1794）；VersionNotFound/ObjectNotFound 视为成功幂等（:1797-1801）。HTTP 入口是 `DeleteMultipleObjectsHandler`（cmd/bucket-handlers.go:413），经 `deleteObjectVersions`（cmd/object-handlers-common.go:381-390）传入 `PrefixEnabledFn` 与桶级 `VersionSuspended`。

### 4.4 盘上真相：xlStorage.DeleteVersion（cmd/xl-storage.go:1304-1413）

每块盘独立完成"从 xl.meta 数组摘记录 + 回收数据目录"：

```go
buf, err := s.readAllData(...xlStorageFormatFile)          // :1324 读 xl.meta
if errors.Is(err, errFileNotFound) {
    if fi.Deleted && forceDelMarker {
        return s.WriteMetadata(ctx, "", volume, path, fi)  // :1330-1333 空对象上强制造标记
    }
    ...
}
dataDir, err := xlMeta.DeleteVersion(fi)                   // :1368 内存数组摘除
if dataDir != "" {
    xlMeta.data.remove(versionID, dataDir)                 // :1380 清内联副本
    if err = s.moveToTrash(filePath, true, false); ...     // :1390 DataDir 整目录移入垃圾桶
}
if len(xlMeta.versions) != 0 {
    return s.writeAllMeta(...)                             // :1397-1405 还有版本 → 回写 xl.meta
}
return s.deleteFile(..., xlStorageFormatFile, ...)         // :1412 一个不剩 → 删掉 xl.meta
```

`moveToTrash`（:1232-1286）是 rename 到 `minioMetaTmpDeletedBucket` 再异步 purge——物理删除是**两阶段**的。数组摘除逻辑 `xlMetaV2.DeleteVersion`（cmd/xl-storage-format-v2.go:1346-1522）按被删条目类型分派：LegacyType 直接摘（:1419-1428）；DeleteType 处理复制状态后摘除，必要时回填标记（:1429-1463）；ObjectType 摘除后若该版本有分层（tier）内容，`InitFreeVersion` 追加一条 free-version 交给扫描器异步清理（:1496-1504，实现 cmd/xl-storage-free-version.go:23-60）；若 DataDir 被其他版本共享（CopyObject 场景）则保留（:1509-1513）。

**一句话总结删除语义**：未开版本化 → 摘记录 + trash 数据目录 = 对用户视角的"真删"；开了版本化 → 仅在数组头部插入一条 DeleteType 记录，数据分毫未动；带 versionID 的删除 → 摘指定记录（复制场景先在 MetaSys 记 `VersionPurgeStatus`，全部副本确认后再摘）。

---

## 5. ILM 专节：expiry / noncurrent 的评估位置

### 5.1 规则评估：lifecycle.Eval

internal/bucket/lifecycle/lifecycle.go。输入 `ObjectOpts`（:301-318）携带版本视角字段 `IsLatest/DeleteMarker/NumVersions/SuccessorModTime`。核心 `eval`（:344-523）按对象状态出牌：

- 仅剩一个删除标记（`ExpiredObjectDeleteMarker` :323-325）→ `DeleteVersionAction`（:366-394）；
- 最新为删除标记且规则含 `DelMarkerExpiration` → `DelMarkerDeleteAllVersionsAction`（:398-410）；
- **非 current 版本 + NoncurrentVersionExpiration**：`NewerNoncurrentVersions` 条数保留与 `NoncurrentDays` 天数**同时满足**才过期（:412-434，引用 AWS 语义注释 :425-426），判定时钟锚在 `SuccessorModTime`（:421）；
- **最新版本 + Expiration(Days/Date)** → `DeleteAction`（版本化桶=打标记）或 MinIO 扩展 `DeleteAllVersionsAction`（:451-488）；
- 多事件排序，到期即执行者优先（:491-518）；`ExpectedExpiryTime` 统一"ModTime+N 天后的午夜"（:531-537）。

### 5.2 与扫描器的联动（简短）

cmd/data-scanner.go `applyActions`（:1036-1162）：扫描器逐对象读出全部版本 → `lifecycle.NewEvaluator(...).Eval`（:1095-1096）→ 按 Action 分派：`DeleteAllVersions/DelMarkerDeleteAllVersions` 整对象清空（:1120-1123）；`DeleteVersionAction`（非 current 过期）收集进 `toDel`，最终 `globalExpiryState.enqueueNoncurrentVersions` 批量入队（:1132-1142、:1158-1159）。API 删除路径复用同一评估器 `evalActionFromLifecycle`（:1164-1196），Object-Lock 生效时跳过全版本删除（:1171-1176）。版本过多的对象会触发 `alertExcessiveVersions`（:1161）。

### 5.3 free-version：分层内容的异步回收

被覆盖/删除的版本若已 transition 到远端，`xlMetaV2.DeleteVersion` 会插入一个打了 `xlFlagFreeVersion` 的伪删除标记（cmd/xl-storage-format-v2.go:1496-1504），只对扫描器可见（:85-88 注释），用来把远端对象延迟删掉——这是"元数据先行、数据异步回收"思想的又一实例。

### 5.4 加密对象一瞥

SSE 的密文材料是**版本元数据的一部分**（随 `MetaUser/MetaSys` 存进 xl.meta）：internal/crypto/metadata.go:24-65 定义 `MetaIV`、`MetaAlgorithm`、`MetaSealedKeySSEC/S3/KMS`、`MetaKeyID`、`MetaDataEncryptionKey`、`MetaSsecCRC`、`MetaContext`。这些 `X-Minio-Internal-*` 键写入时按保留前缀分流进 `MetaSys`（cmd/generic-handlers.go:68-69 定义前缀；cmd/xl-storage-format-v2.go:1681-1695 分流）。因此**每个版本独立持有自己的密钥材料**：v1 可以是 SSE-C、v2 可以是 SSE-KMS，互不干扰；读取时 `crypto.IsEncrypted(metadata)`（internal/crypto/metadata.go:131）按版本元数据判型解封（internal/crypto/sse.go:92-96）。

---

## 6. 设计动机

1. **元数据内联在每块盘（每盘一份完整 xl.meta）**：删除、读、恢复都以单盘为操作单元，仲裁错误归约即可（erasure-object.go:1646）；任何一块盘离线重启后自持全部上下文，heal 只是"对账"而非"重建"。代价是写放大，收益是运维上的无元数据服务器、任意盘可坏可换。
2. **版本数组最新在前（`versions[0]` 即最新）**：GET/LIST/删 marker 等 90% 的操作只碰最新版本；插入点几乎总在头部（addVersion 注释 :1160），短路径 O(1)；盘间一致性比对也只需先比 header（`mergeXLV2Versions`、`xlMetaV2VersionHeader.sortsBefore`）。
3. **删除标记与 S3 语义对齐**：`DELETE`（无版本号）必须幂等且不可逆地"隐藏"对象，又必须保留历史——一条 `DeleteType` journal 记录最小改动实现，读路径把它翻译成 404/405（erasure-object.go:244-255），列举路径照常可见（`ListObjectVersions`）；这是 AWS 文档语义的直接移植，也令复制（删 marker 同步）只需复制一条记录。
4. **删除 = 两阶段 rename 而非 unlink**：`moveToTrash` 保证崩溃安全与 O(1) 假删除，回收压力转移给后台 purge（xl-storage.go:1232-1286），避免删除请求阻塞在慢文件系统上。
5. **free-version 把异步回收"记在账上"**：分层/纠删参数各异的对象被删后，远端内容不能同步删，于是用一条只对扫描器可见的记录保证"最终一定有人来删"（xl-storage-format-v2.go:85-88），账本仍然内联，无需额外索引。

---

## 7. FAQ 素材

1. **Q: xl.meta 里版本顺序是什么？** A: ModTime 降序，`versions[0]` 最新（cmd/xl-storage-format-v2.go:83、:1327-1341）。
2. **Q: 一个对象名下最多多少版本？** A: 受 `MINIO_API_OBJECT_MAX_VERSIONS` 限制，默认 `math.MaxInt64`（cmd/handler-api.go:410-419；超限报 `errMaxVersionsExceeded`，xl-storage-format-v2.go:1151-1154）。
3. **Q: 版本化挂起后写同名对象，旧数据去哪了？** A: null 版本被原地替换，被顶掉版本的 tier 内容记 free-version 异步删（xl-storage.go:2765-2779）。
4. **Q: 删除标记占多少磁盘空间？** A: 只占 xl.meta 里几十字节的 journal（无 DataDir/分片表，:149-153），数据零占用。
5. **Q: GET 一个"最新版本是删除标记"的对象会怎样？** A: 未指定版本 → `errFileNotFound`；指定版本 → `errMethodNotAllowed`（erasure-object.go:244-255）。
6. **Q: DELETE 带 versionID 会打标记吗？** A: 不会，走摘除路径 `deleteMarker=false`（erasure-object.go:2065-2070），数据目录进 trash。
7. **Q: 两个版本能共享一份数据吗？** A: 能（CopyObject 复用 DataDir），删除时 `SharedDataDirCount>0` 则只摘记录不删数据（xl-storage-format-v2.go:1509-1513）。
8. **Q: 为什么删除后盘上还可能看到 xl.meta？** A: 只要数组非空就要保留其他版本；只有最后一条被摘走时 xl.meta 才删除（xl-storage.go:1397-1412）。
9. **Q: 多盘元数据不一致怎么办？** A: `mergeXLV2Versions` 按仲裁合并版本列表（:1923），不足仲裁触发 heal（MRF 队列，erasure-object.go:805-814）。
10. **Q: `"null"` 版本 ID 是特殊值吗？** A: 是，`nullVersionID="null"`（xl-storage.go:57），未开版本化/挂起期间写入的版本都是它。

## 深挖方向

1. **xl.meta 二进制逐字节剖析**：用 `AppendTo`（:1176-1231）对照 `mc admin inspect` 导出的真实文件，走一遍 header→(header,meta)*→CRC→inline。
2. **内联数据（xlMetaInlineData）与 128KiB 阈值**：`ReadVersion` 的回填/摘除逻辑（xl-storage.go:1701-1751），小对象一读一盘。
3. **删除复制的状态机**：`VersionPurgeStatus` 在 `xlMetaV2.DeleteVersion`（:1379-1412）与 DeleteObject（erasure-object.go:2045-2072）之间的流转。
4. **`DeleteAllVersionsAction` 的分批执行**：`deleteObjectVersions` 的 `maxDeleteList` 切批（object-handlers-common.go:381-390）与 `enqueueNoncurrentVersions` 的限速。
5. ** Legacy xlV1 兼容**：`loadLegacy`/`AddLegacy`（xl-storage-format-v2.go:1036-1090、:1792）如何把 JSON 老格式无损迁入 journal。

---

## 写作要点速查表

| # | 内容 | 位置（仓库相对路径:行号） |
|---|------|--------------------------|
| 1 | xl.meta 文件布局写入（header+版本数组+CRC+inline） | cmd/xl-storage-format-v2.go:1176-1231 |
| 2 | versions 三种类型与"最新在前"约定（原文注释） | cmd/xl-storage-format-v2.go:73-88 |
| 3 | 版本条目联合体 / 对象体 / 删除标记体 | cmd/xl-storage-format-v2.go:181-187 / :156-175 / :149-153 |
| 4 | xlMetaV2 内存结构（versions+data+metaV） | cmd/xl-storage-format-v2.go:901-911 |
| 5 | addVersion 头插 + max versions 限制 | cmd/xl-storage-format-v2.go:1141-1173（限制 :1151-1154） |
| 6 | FileInfo 版本字段（VersionID/Deleted/IsLatest/SuccessorModTime） | cmd/storage-datatypes.go:191-271 |
| 7 | Versioning 配置：Enabled/Suspended/排除前缀判定 | internal/bucket/versioning/versioning.go:87-149 |
| 8 | Put 生成 VersionID/DataDir（UUID） | cmd/erasure-object.go:1346-1352 |
| 9 | DeleteObject 双路径判定 `deleteMarker := opts.Versioned` | cmd/erasure-object.go:1885-2148（核心 :2043-2126） |
| 10 | 批量删除：打标记/去重/逐盘 DeleteVersions | cmd/erasure-object.go:1652-1834 |
| 11 | 盘上 DeleteVersion：摘记录+trash DataDir+回写/删 xl.meta | cmd/xl-storage.go:1304-1413 |
| 12 | 读版本选择：ReadVersion（按 ID）vs ReadXL（最新） | cmd/erasure-object.go:753-762 |
| 13 | ToFileInfo：IsLatest/SuccessorModTime 的赋值 | cmd/xl-storage-format-v2.go:1803-1881 |
| 14 | 删除标记的读语义（404/405） | cmd/erasure-object.go:244-255、:975-990 |
| 15 | ILM 评估：noncurrent/EDM/Expiration 全量逻辑 | internal/bucket/lifecycle/lifecycle.go:344-523 |
| 16 | 扫描器应用 ILM + 非 current 过期入队 | cmd/data-scanner.go:1036-1162 |
| 17 | SSE 密钥材料常量（版本内加密信息） | internal/crypto/metadata.go:24-65 |
| 18 | null 版本常量与 Suspended 覆盖语义 | cmd/xl-storage.go:57、:2758-2779 |

（完，约 2026-09 撰写，commit 7aac2a2）
