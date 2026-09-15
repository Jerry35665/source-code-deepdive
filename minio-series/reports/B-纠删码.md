# MinIO 深读 · 卷一 第 2 章 B 篇:纠删码(Erasure Coding)

> 调研对象:minio/minio,commit `7aac2a2`(shallow clone)。所有 `文件:行号` 均为仓库相对路径,并已逐一用 grep/Read 核对。

---

## 1. 全景:一个对象在 N 个盘上的纠删分布

MinIO 的纠删码单位是 **erasure set**:一个 set 内的 `setDriveCount` 个盘共同承载一个对象的 N 个分片(k 个数据分片 + m 个校验分片)。对象落哪个 set 由 `hashKey(deploymentID + object)` 决定(cmd/erasure-sets.go:692-698);分片落在 set 内哪块盘由 `hashOrder(object, N)` 决定——以对象名为种子的循环移位序列(cmd/erasure-metadata-utils.go:178-192,cmd/storage-datatypes.go:394)。

以 16 盘 set、parity=4(即 EC 12:4)写入一个 2MiB 对象为例:

```text
对象 obj (2 MiB) ──► hashOrder("obj",16) ──► 盘序: [7,8,...,16,1,...,6]
                 ──► getHashedSet(...)      ──► 命中某个 erasure set (16 盘)

按 blockSizeV2=1MiB 切块 (cmd/object-api-common.go:37),每块独立编码:

 block0 (1MiB) ─► reedsolomon.Split+Encode ─► D1..D12 | P1..P4  (每个 shard = 1MiB/12 = 87381B 对齐上取整)
 block1 (1MiB) ─► 同上

盘 1  : xl.meta (全量元数据副本) + part.1 [shard#1: HH||D7, HH||D7...]   ← 分布序第 1 个分片
盘 2  : xl.meta + part.1 [shard#2]          ← 每盘恰好一个"分片槽位"(Erasure.Index)
 ...
盘 12 : xl.meta + part.1 [shard#12]
盘 13 : xl.meta + part.1 [shard#13 = 校验 P1]
 ...
盘 16 : xl.meta + part.1 [shard#16 = 校验 P4]

读:任取 k=12 个完好分片即可重建对象(N=16,m=4 可容忍 4 盘全损/损坏)
写:writeQuorum = k = 12 盘成功即返回成功 (cmd/erasure-object.go:1338-1341)
```

每个分片在盘上不是裸写:流式 bitrot 会把 `32B highwayhash || shard` 交错写进 `part.1`(cmd/bitrot-streaming.go:44-75)。`xl.meta` 每盘一份、内容一致(cmd/erasure-object.go:1541-1551 对每盘填同一份 FileInfo),quorum 判定靠"多数盘的 xl.meta 一致"而不是单一主本。

---

## 2. 参数专节:EC 数据/校验盘数怎么推导

核心链路:`putObject` → `GetParityForSC` → `defaultParityCount` → `ecDrivesNoConfig` → `DefaultParityBlocks`。

**(1) 每个对象写入时先看存储类**

cmd/erasure-object.go:1299-1334:

```go
parityDrives := globalStorageClass.GetParityForSC(userDefined[xhttp.AmzStorageClass])
if parityDrives < 0 {
    parityDrives = er.defaultParityCount
}
if opts.MaxParity {
    parityDrives = len(storageDisks) / 2
}
...
dataDrives := len(storageDisks) - parityDrives
```

**(2) `defaultParityCount` 来自启动时的 `ecDrivesNoConfig`**

cmd/erasure-server-pool.go:122-136 依次做:取默认 parity(cmd/format-erasure.go:682-688 `ecDrivesNoConfig` → `storageclass.LookupConfig`)、`ValidateParity` 校验、传给 `newErasureSets`(cmd/erasure-server-pool.go:157)。

**(3) 默认值表(注意:不是 N/2!)**

internal/config/storageclass/storage-class.go:354-368 `DefaultParityBlocks`:

```go
switch drive {
case 1:  return 0
case 3, 2: return 1
case 4, 5: return 2
case 6, 7: return 3
default: return 4   // ≥8 盘的 set 默认 parity 固定 4
}
```

- 默认 STANDARD parity 在未配置时按上表取(≥8 盘即 EC:N-4:4);配置 `MINIO_STORAGE_CLASS_STANDARD=EC:m` 后最大只允许 `setDriveCount/2`(internal/config/storageclass/storage-class.go:226,193-204 `ValidateParity`)。只有显式要求(`opts.MaxParity`,cmd/erasure-object.go:1303-1305)或删除标记/0 字节对象(cmd/erasure-metadata.go:513-514 取 `totalShards/2`)才真正用到 N/2。
- RRS(低冗余存储类)默认 parity=1(internal/config/storageclass/storage-class.go:70-71)。
- 磁盘离线时的"可用性优先"动态加校验:cmd/erasure-object.go:1306-1333,每发现一块离线盘 parity+1,上限 N/2;若离线盘 ≥ 一半,直接报写 quorum 失败(1319-1324)。

**(4) 分片大小对齐**

- `blockSizeV2 = 1MiB`(cmd/object-api-common.go:37),写入时每次读满一块。
- `ShardSize = ceilFrac(blockSize, dataBlocks)`(cmd/erasure-coding.go:116-118)——1MiB 均匀上取整切 k 份。
- `ShardFileSize` 给出对象在每盘占用的最终字节数(cmd/erasure-coding.go:121-132);叠加流式 bitrot 后为 `ceil(size/shard)*32 + size`(cmd/bitrot.go:156-161)。
- Reed-Solomon 参数检查:data>0、parity≥0、data+parity≤256(cmd/erasure-coding.go:44-50);算法名 `rs-vandermonde`(cmd/erasure-metadata.go:40)。

---

## 3. 写路径专节:分片、每盘写入、bitrot hash

主函数 `putObject`(cmd/erasure-object.go:1254-1620),流程:

1. **定参数**:parity/data/writeQuorum(见第 2 节;writeQuorum 在 cmd/erasure-object.go:1338-1341)。
2. **建元数据骨架**:`newFileInfo` 生成 `ErasureInfo`,其中 `Distribution: hashOrder(object, dataBlocks+parityBlocks)`(cmd/storage-datatypes.go:388-397),每盘一份拷贝(1363-1365)。
3. **按分布序重排盘**:`shuffleDisksAndPartsMetadata(storageDisks, partsMetadata, fi)`(cmd/erasure-object.go:1369;实现在 cmd/erasure-metadata-utils.go:270-294)。
4. **创建编码器**:`NewErasure(dataBlocks, parityBlocks, blockSize)`,内部惰性创建 `reedsolomon.New(..., WithAutoGoroutines(ShardSize))`(cmd/erasure-object.go:1371;cmd/erasure-coding.go:61-71)。
5. **每盘一个 bitrot writer**:

cmd/erasure-object.go:1404-1423(节选):

```go
writers := make([]io.Writer, len(onlineDisks))
for i, disk := range onlineDisks {
    ...
    writers[i] = newBitrotWriter(disk, bucket, minioMetaTmpBucket,
        tempErasureObj, shardFileSize, DefaultBitrotAlgorithm, erasure.ShardSize())
}
```

   小对象走 inline:shard 不落 part.1,而是缓冲进内存、稍后塞进 `xl.meta`(cmd/erasure-object.go:1398-1401、1414-1419、1506-1510;阈值 `ShouldInline` 默认 128KiB,版本桶减半为 1/8,internal/config/storageclass/storage-class.go:278-294)。
6. **编码并写分片**:`erasure.Encode(ctx, toEncode, writers, buffer, writeQuorum)`(cmd/erasure-object.go:1440)。大文件(≥`bigFileThreshold`)先过 readahead 双缓冲(1426-1439)。`Encode` 每轮 `io.ReadFull` 一个 block → `EncodeData`(= `reedsolomon.Split` + `Encode`,cmd/erasure-coding.go:77-89)→ `multiWriter.Write` 把 `blocks[i]` 写给第 i 个盘(cmd/erasure-encode.go:69-110,34-66)。
7. **bitrot hash 的计算与存储**:默认算法 `DefaultBitrotAlgorithm = HighwayHash256S`(cmd/xl-storage-format-v1.go:158),key 是"π 前 100 位十进制"派生的固定 magic key(cmd/bitrot.go:36-37)。流式模式下每写一个 shard 就写 `hash(shard)||shard`(cmd/bitrot-streaming.go:44-75),即 **hash 与数据同文件内联**,xl.meta 的 `ChecksumInfo` 只记录算法不记录 hash(cmd/erasure-metadata.go:43-51 返回默认算法即可)。读时 `streamingBitrotReader` 逐 shard 校验,失败返回 `errFileCorrupt`(cmd/erasure-decode.go:197-198 消费该错误)。
8. **提交(原子改名)**:`renameData` 并发在每块盘上把 `tmp/uuid/dataDir/part.1` + `xl.meta` 改名进目标路径(cmd/erasure-object.go:1564;实现在 1019-1101:每盘 `RenameData` 1046 行,失败回滚已成功盘 1061-1079,quorum 判定 `reduceWriteQuorumErrs` 1059 行,版本签名一致性 `reduceCommonVersions` 1083 行)。写临时桶再整体 rename 是 MinIO 避免"读到半截对象"的关键。

---

## 4. 读路径专节:读取顺序、坏盘跳过与重建

读元数据:`GetObjectNInfo`(cmd/erasure-object.go:203-308)先拿读锁(217-237,inline 对象读出数据后即刻解锁 288-290),再 `getObjectFileInfo`(706-975):并发读所有盘的 `xl.meta`(729-774),等够 `minDisks` 个响应(824-835,`data==parity` 时 +1 防脑裂 830-835),`calcQuorum` 内做 `objectQuorumFromMeta` + `listOnlineDisks` + `pickValidFileInfo`(837-859),版本桶用 `pickLatestQuorumFilesInfo` 挑最新版本(902-905)。

读数据:`getObjectWithFileInfo`(310-432):

- 先按 `Erasure.Index` 校验并重排盘序:`shuffleDisksAndPartsMetadataByIndex`(313;实现 cmd/erasure-metadata-utils.go:222-264,不一致盘数 ≥ parity 则回退 `hashOrder` 序)。
- 每个部件构造 N 个 bitrot reader,并标记**优先读本地盘**(`prefer[index] = disk.Hostname() == ""`,cmd/erasure-object.go:369-388)。
- 调 `erasure.Decode(..., prefer)`(390)。

`Decode` 内部(cmd/erasure-decode.go:239-314)按 1MiB block 逐块 `parallelReader.Read`,关键机制在 `Read`(127-235):

```go
for i := 0; i < p.dataBlocks; i++ {
    readTriggerCh <- true      // 只发起 dataBlocks 个并发读 (148-151)
}
...
n, err := rr.ReadAt(p.buf[bufIdx], p.offset)
if err != nil {
    ...                        // errFileCorrupt → bitrotHeal 标记 (197-198)
    p.orgReaders[bufIdx] = nil // 坏 reader 置 nil,本轮不再碰它 (204-208)
    readTriggerCh <- true      // 触发下一块盘补读 (211)
    return
}
```

- `canDecode`:非空 buf ≥ dataBlocks 即可解码(116-124),凑齐立即 break——**只读 k 个盘,多一个字节都不读**。
- `preferReaders`(88-113)把 prefer 的盘(本地盘)swap 到队列头部,实现"本地优先、远程兜底";读失败的盘置 nil 后由后续盘顶上,相当于"最近失败的盘排后"。
- 解码只重建数据分片:`DecodeDataBlocks` → `reedsolomon.ReconstructData`(cmd/erasure-coding.go:94-107;`Decode` 在 cmd/erasure-decode.go:297 调用)。校验分片只在 heal 时重建(`DecodeDataAndParityBlocks` → `Reconstruct`,111-113)。
- 凑不齐 k 个 → 返回 `errErasureReadQuorum`(cmd/erasure-decode.go:234)。
- 若数据已成功写满但发现 `errFileNotFound/errFileCorrupt`,顺手把对象丢进后台修复队列(MRF):cmd/erasure-object.go:400-418 → `globalMRFState.addPartialOp`。

---

## 5. quorum 专节:写/读 quorum 的判定

**统一入口** `objectQuorumFromMeta`(cmd/erasure-metadata.go:530-564):

```go
expectedRQuorum := len(partsMetaData) / 2     // 至少一半盘的元数据可用 (532)
...
parities := listObjectParities(partsMetaData, errs)
parityBlocks := commonParity(parities, defaultParityCount)  // (548-549)
if parityBlocks < 0 {
    return -1, -1, InsufficientReadQuorum{...}              // (550-552)
}
dataBlocks := len(partsMetaData) - parityBlocks              // (554)
writeQuorum := dataBlocks                                    // (556)
if dataBlocks == parityBlocks {
    writeQuorum++                                            // (557-559) 防脑裂
}
```

- **读 quorum = dataBlocks(= N - m)**:能凑出 k 个分片就能还原对象。`commonParity` 统计各盘声称的 parity 出现次数,只有出现次数 ≥ `N-parity` 的才算数(cmd/erasure-metadata.go:460-497);删除标记/0 字节对象的读 quorum 是 `N/2+1`(479,513-514)。
- **写 quorum = dataBlocks;data==parity 时 = dataBlocks+1**。两个实现点保持一致:对象写 cmd/erasure-object.go:1338-1341,元数据规约 cmd/erasure-metadata.go:556-559。
- **元数据 quorum**:xl.meta 每盘一份,读取时 `reduceReadQuorumErrs`/`reduceErrs` 按"出现最多的错误"计数判 quorum(cmd/erasure-metadata-utils.go:104-158);modTime 多数派一致才认有效盘,否则退到 etag 多数派(cmd/erasure-healing-common.go:219-255 `listOnlineDisks`)。版本提交签名同样要求 writeQuorum 个盘一致(cmd/erasure-object.go:1083 `reduceCommonVersions`,实现 cmd/erasure-metadata-utils.go:46-72)。
- **错误出口**:`errErasureReadQuorum` / `errErasureWriteQuorum`(cmd/erasure-errors.go:22-26)映射为 S3 API `InsufficientReadQuorum` / `InsufficientWriteQuorum`(cmd/object-api-errors.go:152-172)。
- **部分盘故障下的可用性**:16 盘 EC 12:4(默认)挂任意 4 盘仍可读写;若用户把 parity 调到 N/2(EC 8:8),读容忍 8 盘损、写容忍 7 盘损(writeQuorum=9)。这就是"parity 越高可用性越高、容量开销越大"的代码出处。

**典型配置对照表**(按第 2 节代码推导,writeQuorum 见 cmd/erasure-metadata.go:556-559):

| set 盘数 | 默认 parity(未配存储类) | dataBlocks | writeQuorum | 读容忍损盘 | 写容忍损盘 | 冗余开销 |
|---|---|---|---|---|---|---|
| 4 | 2(storage-class.go:361-362) | 2 | 3(+) | 2 | 1 | 100% |
| 8 | 4(storage-class.go:365-366) | 4 | 5(+) | 4 | 3 | 100% |
| 16 | 4(同上) | 12 | 12 | 4 | 4 | 33% |
| 16(EC 8:8,手动) | 8(上限 N/2,storage-class.go:226) | 8 | 9(+) | 8 | 7 | 100% |

(+) 表示 data==parity 时 writeQuorum 额外 +1;16 盘默认 12:4 时 data≠parity,writeQuorum 恰为 12。

---

## 6. 设计动机

1. **纠删码 vs 三副本的存储效率**:三副本容忍 2 盘损的代价是 200% 冗余;EC 12:4 同样容忍 4 盘损,冗余仅 4/12≈33%。MinIO 把 set 规模与 parity 解耦,由存储类按 bucket/对象粒度选择 parity(cmd/erasure-object.go:1299-1302),同一集群可混存 STANDARD 与 RRS 对象。
2. **为什么元数据也要分布(xl.meta 每盘一份)**:任何单盘都只是"分片持有者",没有主盘;每盘带全量元数据副本,使"哪 k 个盘凑 quorum"成为纯本地读,任意 k 盘即可同时完成元数据判定与数据解码。这也是为什么版本提交要 `reduceCommonVersions` 对齐多数派的签名(cmd/erasure-object.go:1083),防止部分写入留下"僵尸版本"。
3. **bitrot 的必要性**:纠删码只能修复"知道哪个分片坏"的情形;磁盘静默损坏(silent corruption)不会报 IO 错误。每分片 highwayhash(cmd/bitrot.go:36-37)让 `ReadAt` 能返回 `errFileCorrupt`,该分片随即被丢弃并用其他分片重建(cmd/erasure-decode.go:197-208)。HH256S 的"hash 内联进数据文件"设计还避免了传统方案"元数据里存整文件 hash,读一个 shard 也要校验整个文件"的成本,实现按 shard 粒度校验。
4. **写临时目录再 rename**:分片先落 `minioMetaTmpBucket`(cmd/erasure-object.go:1393-1396),quorum 达标后 `renameData` 原子提交(1564),失败则回滚已成功盘并留待 heal(1061-1079)。对象可见性因此是原子的。
5. **启动自检**:每种算法×每组 (k,m) 组合做编码-删片-重建的自检,hash 不符直接拒绝启动(cmd/erasure-coding.go:149-206 `erasureSelfTest`),防止数学库变更悄悄写坏历史数据。

---

## 7. Healing 触发面(细节留卷二)

- **入口**:`HealObject`(cmd/erasure-healing.go:1060)→ `healObject`(295-470):读全量 xl.meta(333)→ `objectQuorumFromMeta`(344)→ `listOnlineDisks`/`pickValidFileInfo`(368-372)→ `shouldHealObjectOnDisk` 找过期盘(401-410)→ 对每个 part `erasure.Heal(readers, writers, ..., prefer)`(603;实现在 cmd/erasure-decode.go:317-364,内部 `Reconstruct` 连校验分片一起重建,writeQuorum=1 写回任意可用盘 352-356)→ 改名回原位(652-664)。
- **三类触发**:① `mc admin heal` / 全局 heal 队列(cmd/background-heal-ops.go:132);② 后台扫描器(cmd/data-scanner.go:968);③ 读写过程中的实时上报 MRF:`addPartialOp`(cmd/mrf.go:49-78,队列 10 万条 cmd/mrf.go:39;读路径 cmd/erasure-object.go:402-412,元数据路径 791-813,写路径 1607)。

---

## 8. FAQ 素材

1. **MinIO 自己实现了纠删码吗?** 没有。数学部分用 `github.com/klauspost/reedsolomon v1.12.4`(go.mod:49,仓库无 vendor 目录);MinIO 只做调用面封装:`New/Split/Encode/Reconstruct/ReconstructData`(cmd/erasure-coding.go:77-113)。
2. **默认配置是 EC:N/2 吗?** 不是。当前代码默认 parity 见 `DefaultParityBlocks`:1 盘→0,2-3 盘→1,4-5 盘→2,6-7 盘→3,≥8 盘→4(internal/config/storageclass/storage-class.go:354-368);N/2 是允许的上限(storage-class.go:226),不是默认值。
3. **为什么写 quorum 是 dataBlocks 而不是 dataBlocks+1?** 只要 k 个盘写入成功,读时就能重建完整对象;k==m 时才 +1 防双写脑裂(cmd/erasure-metadata.go:556-559)。Heal 时 writeQuorum 甚至=1(cmd/erasure-decode.go:352-356)。
4. **一个对象写几份?** N 个分片(每盘一个槽位,`Erasure.Index` 固定)+ N 份 xl.meta;无中心主本。
5. **bitrot hash 存在哪里?** 默认 HH256S 流式算法把 32B hash 内联在 part.1 内(hash||shard 交错,cmd/bitrot-streaming.go:44-75),xl.meta 只存算法名;旧 whole-file 算法才把 hash 存进 xl.meta 的 `ChecksumInfo`(cmd/xl-storage-format-v1.go:174-179)。
6. **读对象时读几个盘?** 并发只发起 dataBlocks 个读(cmd/erasure-decode.go:148-151),失败就地补读下一块盘;凑齐 k 个即停,校验分片平时根本不读。
7. **读到坏分片会 500 吗?** 通常不会:坏分片被丢弃重建,若客户端数据已完整返回,错误被转为后台 heal 请求(cmd/erasure-object.go:400-418);只有凑不齐 k 个分片才返回 InsufficientReadQuorum。
8. **对象和盘的映射会变吗?** 不会。set 选择与盘内槽位都由对象名哈希决定(cmd/erasure-sets.go:692-698;cmd/erasure-metadata-utils.go:178-192),扩展靠加 pool/set 而不是重排旧数据。
9. **盘临时离线时写入会降低可靠性吗?** 不会:availability 优化模式把离线盘数追加进 parity(上限 N/2,cmd/erasure-object.go:1306-1333),并在 xl.meta 留下 `x-minio-internal-erasure-upgraded` 痕迹(1330-1331)。
10. **为什么删除标记的 quorum 更高?** 删除标记没有数据分片,读 quorum 直接取 N/2+1 的简单多数,防止"半数盘有标记、半数没有"时复活对象(cmd/erasure-metadata.go:476-479,513-514)。

---

## 9. 深挖建议

1. **reedsolomon 调用面与性能**:`WithAutoGoroutines(shardSize)` 的 goroutine 池如何按 shard 尺寸自适应(cmd/erasure-coding.go:61-71);`erasureSelfTest` 的期望 hash 表(cmd/erasure-coding.go:160)——升级数学库时的兼容性契约。
2. **流式 bitrot 文件格式**:part.1 = `[HH(shard0)||shard0][HH(shard1)||shard1]...`,`bitrotShardFileSize` 给出盘上精确大小(cmd/bitrot.go:156-161;cmd/bitrot-streaming.go:125-130);对照 `wholeBitrotWriter` 的整文件 hash 模式。
3. **提交协议**:`renameData` 的"多数派签名 + 失败回滚 + 悬挂对象清理"(cmd/erasure-object.go:1019-1101,`deleteIfDangling` 485)——MinIO 没有分布式事务,靠 quorum + 补偿实现。
4. **读序优化全景**:`preferReaders` 本地置前(cmd/erasure-decode.go:88-113)→ 失败盘本轮置 nil(192-213)→ `filterOnlineDisksInplace` 剔除过期 meta 盘(cmd/erasure-healing-common.go:186-193),三层叠加决定一次 GET 实际碰哪几块盘。
5. **inline 小对象路径**:`ShouldInline`(internal/config/storageclass/storage-class.go:278-294)→ 写入缓冲进 xl.meta(cmd/erasure-object.go:1398-1419)→ 读时 `fi.InlineData()` 提前解锁返回(cmd/erasure-object.go:288-290、908-910)。

---

## 10. 写作要点速查表

| # | 关键函数/事实 | 位置 |
|---|---|---|
| 1 | `Erasure` 结构体 + `NewErasure`(参数检查,d+p≤256) | cmd/erasure-coding.go:35-73 |
| 2 | `EncodeData` = Split+Encode;`DecodeDataBlocks` = ReconstructData | cmd/erasure-coding.go:77-107 |
| 3 | `ShardSize` = ceil(blockSize/dataBlocks);`ShardFileSize` | cmd/erasure-coding.go:116-132 |
| 4 | reedsolomon/highwayhash 依赖声明 | go.mod:49,58 |
| 5 | `blockSizeV2 = 1MiB` | cmd/object-api-common.go:37 |
| 6 | 默认 parity 表 `DefaultParityBlocks`(≥8 盘=4) | internal/config/storageclass/storage-class.go:354-368 |
| 7 | parity 上限 N/2 校验 `ValidateParity` | internal/config/storageclass/storage-class.go:193-204,226 |
| 8 | `ecDrivesNoConfig` 默认 parity 来源 | cmd/format-erasure.go:682-688 |
| 9 | putObject 定 parity/writeQuorum(动态加校验) | cmd/erasure-object.go:1299-1341 |
| 10 | `hashOrder` 分布序 + `newFileInfo` | cmd/erasure-metadata-utils.go:178-192;cmd/storage-datatypes.go:388-397 |
| 11 | `Erasure.Encode` 循环 + `multiWriter.Write` quorum 检查 | cmd/erasure-encode.go:69-110,34-66 |
| 12 | 流式 bitrot 写 hash‖shard;默认算法 HH256S | cmd/bitrot-streaming.go:44-75;cmd/xl-storage-format-v1.go:158 |
| 13 | `renameData` 每盘提交/回滚/版本签名 | cmd/erasure-object.go:1019-1101(1046,1059,1083) |
| 14 | `parallelReader.Read`:k 个并发读、坏盘补读、读 quorum 错误 | cmd/erasure-decode.go:127-235(148-151,204-211,234) |
| 15 | `preferReaders` 本地盘优先;`Decode` 主循环 | cmd/erasure-decode.go:88-113,239-314 |
| 16 | 读路径:构造 readers+prefer、MRF 触发 | cmd/erasure-object.go:369-418 |
| 17 | `objectQuorumFromMeta`:读/写 quorum 推导 | cmd/erasure-metadata.go:530-564 |
| 18 | `commonParity`/删除标记 quorum | cmd/erasure-metadata.go:460-497,499-525 |
| 19 | quorum 错误定义与 API 映射 | cmd/erasure-errors.go:22-26;cmd/object-api-errors.go:152-172 |
| 20 | healObject 主流程 + `erasure.Heal` 写回 | cmd/erasure-healing.go:295-470,557-664(603);cmd/mrf.go:39-78 |

(全文完,调研基于 commit `7aac2a2`)
