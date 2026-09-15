# MinIO 深读 · 卷一第 1 章:全景架构(启动 / 部署模式 / Erasure Set 组织)

> 源码版本:minio/minio shallow clone,commit `7aac2a2`(RELEASE 分支主干,"update README.md format and clarify state of the project")。
> 所有行号均以 `grep -n` / `Read` 在该 commit 上实际核对。路径为仓库相对路径,主代码几乎全部位于 `cmd/`。

MinIO 是 Go 编写的 S3 兼容对象存储:一个静态编译的二进制同时充当 S3 API 服务器、纠删码数据面、节点间 RPC 总线与分布式锁仲裁器。本章以"一次 `minio server` 启动"为主线,串起部署拓扑、erasure set 组织、XL 磁盘布局、命名空间锁与节点间通信五条线索。

---

## 1. 全景:部署拓扑

### 1.1 四种部署形态

启动参数最终解析为四种 `SetupType`(cmd/setup-type.go:23-38):

| SetupType | 形态 | 典型命令 |
|---|---|---|
| `ErasureSDSetupType` | 单机单盘(SNSD) | `minio server /data` |
| `ErasureSetupType` | 单机多盘(SNMD) | `minio server /data{1...16}` |
| `DistErasureSetupType` | 分布式多节点多盘 | `minio server http://node{1...4}.example.com/mnt/export{1...8}` |
| `FSSetupType` | 旧 FS 后端(该 commit 已无 FS 对象层,仅枚举保留) | — |

server 命令的帮助文本直接给出了这三种主形态(cmd/server-main.go:208-234),其中分布式写法 `http://node{1...32}.example.com/mnt/export{1...32}` 在 230 行。

### 1.2 拓扑 ASCII 图

```text
(1) 单机单盘 SNSD                    (2) 单机多盘 SNMD
+--------------------------+         +--------------------------------------+
|      minio process       |         |            minio process             |
|  [ /data ]  1 set x 1盘  |         | [ /data1 ... /data16 ]  1 set x 16盘 |
|  EC: data=1, parity=0    |         | EC: data=12, parity=4 (默认)         |
+--------------------------+         +--------------------------------------+

(3) 分布式 4 节点 x 8 盘 = 32 盘 => 2 个 set,每 set 16 盘
node1                        node2                        node3        node4
+--------------------------+ +--------------------------+ +----+  +----+
| /mnt/export1  | set0-d0  | | /mnt/export1  | set0-d8  | | .. |  | .. |
| /mnt/export2  | set0-d1  | | /mnt/export2  | set0-d9  |      ...
| ...                       | | ...                       |
| /mnt/export8  | set0-d7  | | /mnt/export8  | set0-d15 |
|                           |                            |
| pool0: set0 = d0..d15     |  pool0: set1 = d16..d31    |
|  (跨 4 节点交错分布)      |                            |
+--------------------------+ +--------------------------+
   每节点 1 个进程监听 :9000;S3 API、storage REST、peer REST、lock grid 全走同一端口
```

要点:

- **pool > set > drive 三级结构**。`erasureServerPools` 持有多个 `serverPools`(`[]*erasureSets`,cmd/erasure-server-pool.go:86-90);每个 pool 内 `setCount` 个 set、每 set `setDriveCount` 盘(cmd/erasure-sets.go:78-79)。
- **每个 set 最多 16 盘**:`setSizes = []uint64{2,3,...,16}`(cmd/endpoint-ellipses.go:48)。16 是硬编码上限,源于 Reed-Solomon 分片数上限与运维修复成本的折中。
- **每个 set 独立成纠删码域**:一个对象的 data/parity 分片只落在同一个 set 的盘上;set 内任意 `parity` 数量的盘同时损坏仍可读。
- **盘在 set 内的排列跨节点交错**(展开顺序即命令行展开顺序),因此单个 set 天然跨机,机架级容错靠部署规划保证。

### 1.3 set 的选取与 pool 的选取

- **set 选取**:在 pool 内,按**对象名**(不含 bucket!)哈希:`set := s.getHashedSet(object)`(cmd/erasure-sets.go:734、740、746、770 等十余处)。哈希函数 `hashKey`(cmd/erasure-sets.go:679-689):新部署用 `SIPMOD`——`siphash.Hash(k0,k1, key) % setCount`,k0/k1 取自 16 字节 deploymentID(cmd/erasure-sets.go:660-669);老部署(CRCMOD)用 `crc32 % setCount`(671-677)。同一对象名永远落同一 set,无元数据表,纯计算路由。
- **pool 选取**:已存在的对象按"哪个 pool 有这个对象"定位;新对象写入按"剩余空间加权"选 pool(cmd/erasure-server-pool.go:637-657 `getPoolIdx`,625 行 `getAvailablePoolIdx`)。这是 pool 扩容后新老数据共存的关键。
- 对照本系列 Git 卷:Git 的 `.git/objects` 用**内容** SHA-1 前 2 位分目录(内容寻址),MinIO 用**名字**哈希选 set、盘上**保留原名路径**(名字寻址)。两者分目录的目的不同:Git 是为了对象去重与散列,MinIO 是为了把写压力均匀摊到所有 set。

---

## 2. 启动专节:从 `main()` 到对象层就绪

### 2.1 入口链

```text
main.go:31-33  minio.Main(os.Args)
  └─ cmd/main.go:201  Main():newApp(appName).Run(args)
       └─ cmd/main.go:141  registerCommand(serverCmd)     # 只有 server 与 fmt-gen 两个子命令
            └─ cmd/server-main.go:199-241  serverCmd 定义
                 └─ cmd/server-main.go:746  serverMain()
```

根 `main.go` 只有一行有效逻辑 `minio.Main(os.Args)`(main.go:31-33),真正的 CLI 骨架在 cmd/main.go:注册子命令(cmd/main.go:141-142)、未知命令的"Did you mean"提示(cmd/main.go:161-173)。

### 2.2 盘参数解析(serverMain 前 60 行做的事)

1. 参数来源优先级:`--config` YAML → 环境变量 `MINIO_CONFIG` / `MINIO_VOLUMES` / `MINIO_ENDPOINTS` → 命令行位置参数(cmd/server-main.go:243-271 `serverCmdArgs`;环境变量常量见 config.EnvArgs 等)。
2. `buildServerCtxt` + `serverHandleCmdArgs`(cmd/server-main.go:785-790)。
3. 核心转换:`globalEndpoints, setupType, err = createServerEndpoints(...)`(cmd/server-main.go:397)。
4. 据此设置全局模式标志(cmd/server-main.go:401-406):

```go
globalIsErasure = (setupType == ErasureSetupType)
globalIsDistErasure = (setupType == DistErasureSetupType)
if globalIsDistErasure {
    globalIsErasure = true
}
globalIsErasureSD = (setupType == ErasureSDSetupType)
```

5. 分布式模式禁止 `--address :0` 随机端口(cmd/server-main.go:407-409)。

### 2.3 省略号语法与 set 形成算法

`/data{1...64}` 这类写法由 ellipses 库展开。set 大小的自动推导(cmd/endpoint-ellipses.go:134-207 `getSetIndexes`):

1. 每个参数模式展开后得到总盘数 `totalSizes`(乘积,cmd/endpoint-ellipses.go:240-250);
2. 对所有参数的总盘数求**最大公约数** `getDivisibleSize`(cmd/endpoint-ellipses.go:52-64);
3. 取 `[2..16]` 中能整除 GCD 的候选(cmd/endpoint-ellipses.go:149-158),再按对称性过滤(cmd/endpoint-ellipses.go:95-128);
4. `commonSetDriveCount` 选择使"总盘数/setSize"比值最小的那个,即**尽量少而大的 set**(cmd/endpoint-ellipses.go:71-90);
5. 可用环境变量 `MINIO_ERASURE_SET_DRIVE_COUNT` 强制覆盖(cmd/endpoint-ellipses.go:323;167-181 校验必须是合法候选)。
6. 展开 64 盘的注释明确写着 "{1...64} is divided into 4 sets each of size 16"(cmd/endpoint-ellipses.go:278)。

`createServerEndpoints`(cmd/endpoint-ellipses.go:497-523)→ `CreatePoolEndpoints`(cmd/endpoint.go:940):单盘布局直接判 SNSD(cmd/endpoint.go:957-984);最后按"参数是否含多个主机名"二分:`erasureType := len(uniqueArgs.ToSlice()) == 1`(cmd/endpoint.go:1135 附近),Path 端点 → `ErasureSetupType`,URL 多主机 → `DistErasureSetupType`(cmd/endpoint.go:1140-1147)。每个 endpoint 都被打上 `(poolIdx, setIdx, diskIdx)` 三元坐标(cmd/endpoint.go:1002-1006)。

### 2.4 分布式启动:格式协商与 quorum 等待

- `waitForFormatErasure`(cmd/prepare-storage.go:239-327)循环重试 `connectLoadInitFormats`(cmd/prepare-storage.go:157-236):读每块盘的 `format.json`,全空且本机是"第一台"则 `initFormatErasure` 写入新格式(cmd/prepare-storage.go:193-204),否则等待 quorum 数量的盘上线(打印 "Waiting for a minimum of %d drives",cmd/prepare-storage.go:306-313)。
- `format.json` 结构 `formatErasureV3` 含 `Sets [][]string`(每 set 每盘一个 UUID)(cmd/format-erasure.go:112-120);所有 pool 必须共享同一 deploymentID(cmd/erasure-server-pool.go:146-154)。
- 对象层构建入口 `newObjectLayer` 只有一行:转给 `newErasureServerPools`(cmd/server-main.go:1199-1201;实现 cmd/erasure-server-pool.go:78-230)。其内部:加载每 pool 格式(cmd/erasure-server-pool.go:139)→ `newErasureSets`(157)→ 自动修复 `initAutoHeal`(197-199)→ `z.Init` 加载 pool 元数据(206-222)。
- 分布式节点间还做"启动一致性校验":`verifyServerSystemConfig` 比对各节点端点数、命令行、MINIO_* 环境变量哈希,不一致直接拒绝启动(cmd/server-main.go:927-934;实现 cmd/bootstrap-peer-server.go:202 起,跳过名单 `skipEnvs` 见 103-130 行)。
- 启动最后一步是等待读 quorum 健康:`newObject.Health(...)` 循环(959-973 行)。

---

## 3. XL 后端专节:一块盘上的目录布局

### 3.1 布局图

```text
/drive1/                                    <- ep.Path,newXLStorage 校验(cmd/xl-storage.go:217-244)
├── format.json                             <- 盘格式;.minio.sys/format.json(cmd/xl-storage.go:286)
├── .minio.sys/                             <- minioMetaBucket(cmd/object-api-utils.go:59)
│   ├── tmp/                                <- minioMetaTmpBucket(object-api-utils.go:65)
│   │   └── .trash/                         <- minioMetaTmpDeletedBucket(object-api-utils.go:67)
│   ├── multipart/                          <- minioMetaMultipartBucket(object-api-utils.go:63)
│   ├── buckets/                            <- dataUsageBucket + 桶元数据(cmd/data-usage.go:32)
│   ├── config/                             <- minioConfigBucket
│   └── hosts/  (healing tracker 等)
├── mybucket/                               <- 桶 = 一个普通目录(getVolDir,xl-storage.go:787-793)
│   ├── photos/
│   │   └── cat.jpg/                        <- 对象 = 以对象名为名的目录(不哈希改写!)
│   │       ├── xl.meta                     <- 元数据文件(xl-storage.go:69)
│   │       └── 3e1a...-uuid/               <- DataDir = 每版本一个 UUID(erasure-object.go:1352)
│   │           └── part.1                  <- 分片数据(checkPart 拼路径,xl-storage.go:2366)
│   └── big.bin/
│       ├── xl.meta
│       └── <uuid>/part.1 ... part.N
└── tmp-old/<uuid>/                         <- 上次残留临时目录,启动时清理(prepare-storage.go:74-112)
```

### 3.2 关键实现点

- `xlStorage` 结构体只持有一个 `drivePath` 加少量缓存字段(cmd/xl-storage.go:98-130)。`newXLStorage` 拒绝把操作系统根盘当数据盘(`errDriveIsRoot`,cmd/xl-storage.go:255-257),并探测 O_DIRECT 支持(cmd/xl-storage.go:318-324)。
- 内部桶目录在初始化时批量创建:`tmp/.trash`、`multipart`、`buckets`、`config`(cmd/xl-storage.go:201-214)。
- **对象名不做哈希分桶、不做转义**:对象路径就是 `桶目录 + "/" + 对象名`。读路径可直接验证——`ReadVersion` 把 `filePath := pathJoin(volumeDir, path)` 后直接读 `path/xl.meta`(cmd/xl-storage.go:1655-1690;`readRaw` 拼 `xl.meta` 在 1587 行)。需要说明:网上流传的"MinIO 按 dir.N 哈希分目录"是误传(那是 Ceph RGW 的做法),本仓库中不存在该机制;唯一带哈希的目录逻辑是 data-scanner 内部用于 bloom 的 `hashPath`(cmd/data-usage-cache.go:1208),只影响扫描器,不影响存储布局。唯一的名字改写是目录对象:`prefix/` 落盘为 `prefix__XLDIR__`(cmd/utils.go:895-908 `encodeDirObject`)。
- **小文件内联**:≤128KiB(cmd/xl-storage.go:60 `smallFileThreshold`)的对象数据直接内联进 `xl.meta`(`xlMetaV2.data` 字段,cmd/xl-storage-format-v2.go:901-911;写侧判定 cmd/erasure-object.go:1399-1419)。`xl.meta` 本身是二进制 protobuf-like 格式 v2,每版本记录一个 DataDir UUID(cmd/xl-storage-format-v2.go:323-331)。
- **写路径是"写临时 + 原子 rename"**:`putObject` 先把纠删码分片写到 `.minio.sys/tmp/<uniqueID>/<DataDir>/part.1`(cmd/erasure-object.go:1359-1394),全部成功后 `renameData` 整体重命名到最终位置(cmd/erasure-object.go:1564-1579)。分片数 = `dataBlocks + parityBlocks`(≤256,cmd/erasure-coding.go:42-56),写 quorum = dataDrives(均分时 +1,cmd/erasure-object.go:1338-1341)。
- 对象名到 set 的哈希、set 内盘到分片的排列是两层独立哈希:后者 `hashOrder`(cmd/erasure-metadata-utils.go:178-191)按对象名 CRC 起始点循环排列,`shuffleDisksAndPartsMetadata` 据此把第 i 个分片放到 `distribution[i]-1` 号盘(cmd/erasure-metadata-utils.go:270-295)——这让同一 set 内不同对象的"第一数据分片"散开,避免热盘。
- 默认 parity 由 set 大小决定:4/5 盘 → 2,6/7 → 3,8..16 → 4(cmd/erasure-server-pool.go:122-126 注释;计算入口 `ecDrivesNoConfig`,cmd/format-erasure.go:682-688;storage class 前缀 "EC" 见 internal/config/storageclass/storage-class.go:65)。

---

## 4. 锁专节:命名空间锁的本地与分布式实现

### 4.1 双形态同一个接口

`NewNSLock` 按 `isDistErasure` 二选一(cmd/namespace-lock.go:231-242):

```go
func (n *nsLockMap) NewNSLock(lockers func() ([]dsync.NetLocker, string),
    volume string, paths ...string) RWLocker {
    sort.Strings(paths)
    opsID := mustGetUUID()
    if n.isDistErasure {
        drwmutex := dsync.NewDRWMutex(&dsync.Dsync{
            GetLockers: lockers,
            Timeouts:   dsync.DefaultTimeouts,
        }, pathsJoinPrefix(volume, paths...)...)
        return &distLockInstance{drwmutex, opsID}
    }
    return &localLockInstance{n, volume, paths, opsID}
}
```

- **单机**:`nsLockMap.lockMap` 是 `map[string]*nsLock`,`nsLock` 内嵌自研 `lsync.LRWMutex`(读写锁,cmd/namespace-lock.go:78-90);加锁入口按 `volume/path` 拼 resource 键(cmd/namespace-lock.go:93-130),引用计数归零即从 map 删除(122-125)。
- **分布式**:`distLockInstance` 包一个 `dsync.DRWMutex`(cmd/namespace-lock.go:157-218)。`GetLockers` 闭包来自 set:`s.GetLockers(setIndex)` 返回该 set 涉及的**每个主机一个** NetLocker(cmd/erasure-sets.go:312-318;构建去重逻辑 cmd/erasure-sets.go:384-410)。即:锁仲裁者不是全局集群,而是**对象所在 set 的各节点**。

### 4.2 分布式仲裁:dsync 的多数派

`lockBlocking` 中的仲裁参数(internal/dsync/drwmutex.go:208-231):

```go
// Tolerance is not set, defaults to half of the locker clients.
tolerance := len(restClnts) / 2
quorum := len(restClnts) - tolerance
if !isReadLock {
    if quorum == tolerance {
        quorum++        // 写锁时避免 quorum == tolerance 的脑裂窗口
    }
}
```

即 N 个 locker,读锁 N/2+1、写锁 floor(N/2)+1(偶数时再 +1)。拿到锁后并非一劳永逸:`startContinuousLockRefresh` 持续刷新,一旦存活 locker 少于 quorum 触发 `lockLossCallback`(internal/dsync/drwmutex.go:276-310;`refreshLock` 判定 340-417)。这是"锁跟随数据 quorum"的设计:数据在哪个 set,锁就由该 set 的多数派仲裁,锁与数据的存活域完全重合。

### 4.3 服务端:localLocker 走 grid RPC

- 每个节点进程内有一个 `localLocker`(cmd/local-locker.go:63 起),维护 `map[string][]lockRequesterInfo`(同一资源可有多个读持有者);`Lock`/`RLock`/`Unlock`/`Refresh`/`expireOldLocks` 是它的五个动词(cmd/local-locker.go:99、193、147、367、407)。
- 远端调用方通过 `lockRESTServer` 的六个 handler 访问它(cmd/lock-rest-server.go:35-102),注册到**独立的 lock grid**(cmd/lock-rest-server.go:124-139 `registerLockRESTHandlers`,由 cmd/routers.go:44 调用)。
- 死锁防护靠租约而非超时解锁:锁有效性 1 分钟,后台 `lockMaintenance` 每分钟清掉未续期的锁(cmd/lock-rest-server.go:158-190)。客户端持锁期间自动续期,请求取消则通过 context 立即释放。
- S3 语义层再包一层:`erasureObjects.putObject` 在提交阶段拿 `er.NewNSLock(bucket, object)` 写锁(cmd/erasure-object.go:1551-1560),锁路径 = `bucket/object`。

---

## 5. 节点间通信:9000 一个端口走天下

MinIO 集群内所有 RPC 与 S3 API 共用 9000(默认端口常量 `GlobalMinioDefaultPort = "9000"`,cmd/globals.go:65;`--address` 默认值 cmd/server-main.go:68-73),靠路径前缀分流(cmd/routers.go:28-51):

| 路径前缀 | 用途 | 定义处 |
|---|---|---|
| `/minio/storage` | 盘级 REST(读 xl.meta、rename 等,每盘一个 client) | cmd/storage-rest-common.go:23-25(v63) |
| `/minio/peer` | 控制面(health、升级 verify/commit、profile、speedtest) | cmd/peer-rest-common.go:24-25;路由 cmd/peer-rest-server.go:1358-1367 |
| `/minio/grid/v1` | 二进制多路复用 RPC(对象元数据小请求) | internal/grid/manager.go:48 |
| `/minio/grid/lock/v1` | 分布式锁专用 grid | internal/grid/manager.go:51;装配 cmd/grid.go:76-107 |
| `/` 其余 | S3 API + Admin/Health/Metrics/STS/KMS router | cmd/routers.go:95-110 |

grid 是基于 WebSocket 的长连接多路复用层(internal/grid/README.md),两条 grid(grid 与 lockGrid)在 `configureServerHandler` 后由 channel 放行(cmd/server-main.go:892-899)。节点身份用根凭据派生的 `globalNodeAuthToken` 认证(cmd/server-main.go:822-826)。桶元数据等控制消息经 `S3PeerSys` 向同 pool 各节点广播(cmd/erasure-server-pool.go:88)。

---

## 6. 对象存储 / 文件存储 / 块存储的定位

- **对象存储**:MinIO 暴露的是扁平 `bucket/key` + HTTP 语义(GET/PUT/LIST + 版本/标签/锁),无目录树、无 rename、无部分写(除 multipart 组装)。盘上实现恰恰是"目录树",但它只是对象名的字面投影(第 3 节),S3 层从不暴露目录句柄。
- **对照文件存储**:文件系统提供层级 + 随机覆写 + 强一致 rename;MinIO 只借用其中两样作为实现手段——目录做命名空间、rename 做原子提交(cmd/erasure-object.go:1564),其余(随机写、锁文件、硬链接)一概不承诺。
- **对照块存储**:块存储暴露固定大小的可寻址扇区,由客户端文件系统管理布局;MinIO 的 `part.N` 分片不是扇区,寻址信息(`xl.meta` 里的 DataDir/part 表)在服务端。
- **对照本系列 Git 对象库**:Git 把同一内容永远存成同一 blob(内容寻址、天然去重);MinIO 相同内容的不同对象名各存一份(名字寻址、按 set 分片冗余)。前者优化"重复",后者优化"吞吐与可用性"。

---

## 7. 设计动机

1. **为什么纠删码而不是三副本?** 同样容忍 4 盘损坏:16 盘 set 默认 parity=4(EC 12+4),开销 1.33x;三副本要 1.67x~3x 且以副本为单位、跨 set 复制复杂。纠删码把冗余粒度从"盘"降到"分片",`parity` 还能按存储类逐对象调整(cmd/erasure-object.go:1299-1334,盘掉线时甚至动态加 parity)。代价是读放大(任一读都需凑齐 data 个分片或解码)与修复必须走解码,这正是 MinIO 把 set 上限压到 16、优先大 set 的原因——控制单对象恢复时的网络参与度。
2. **为什么对象名哈希选 set,盘上却保留原名路径?** 选 set 必须无状态(免查表、免一致性协议),哈希是唯一解;siphash 以 deploymentID 为盐(cmd/erasure-sets.go:666-668),保证不同集群即使盘数相同路由也不同,配合 pool 扩容旧对象不搬家。而盘上不哈希改写名字,是为了 LIST 直接 `Walk` 目录树即可完成,无索引、无日志、无后台 compaction——整个元数据层就是文件系统本身。
3. **为什么单二进制内嵌全部?** 客户端(minio-go、mc 的传输层)、服务端(S3)、数据面(storage REST)、锁(dsync)全在同一个 module 里,版本天然对齐:升级集群 = 替换二进制滚动重启,`/minio/peer` 的 verify/commit 二进制握手(cmd/peer-rest-server.go:1359-1360)就是为在线升级设计。没有外部元数据服务器(etcd 仅为可选联邦),部署单位只有"二进制 + 盘列表",这是它能以 Docker 命令一行起集群的根本原因。
4. **为什么锁与数据同域仲裁?** 把锁交给 set 内多数派(dsync),锁的存活条件与数据的读写 quorum 条件完全一致:数据可读写时锁必然可用,锁不可用时数据也不可用,二者不会出现"锁活着但数据读不了"的错位,免去跨子系统的一致性协调。
5. **为什么写走 tmp+rename 而不是原地追加?** 对象要么整体可见要么不存在,rename 在同一文件系统内是原子的;任何中途失败只留下 tmp 垃圾,由启动清理(prepare-storage.go:74-112)与周期 `.trash` 清理兜底,不需要 WAL。

---

## 8. FAQ 素材

1. **MinIO 集群要开几个端口?** 一个。S3、peer RPC、storage REST、锁、console 反代全在 9000(默认),按路径区分(cmd/routers.go:28-51);console UI 端口动态分配,分布式下禁止 `:0`(cmd/server-main.go:407-409)。
2. **16 这个数字哪来的?** `setSizes` 硬编码上限 2..16(cmd/endpoint-ellipses.go:48),同时 Reed-Solomon 分片上限 256 = 16 set 内盘 x 16 中间分片不冲突,更主要是恢复风暴与 EC 计算开销的工程上限。
3. **32 盘会划成几个 set?** 自动算法对所有参数总盘数取 GCD(32),在能整除的候选 {2,4,8,16} 里选让"总盘数/setSize"比值最小的尺寸,即 16——得到 2 个 16 盘 set(cmd/endpoint-ellipses.go:71-90,79 行 `prevD = divisibleSize/cnt` 即 set 数量,取最小)。64 盘同理是 4 个 set(278 行注释)。
4. **对象落在哪个 set 由什么决定?** 只由**对象名**哈希决定,bucket 不参与(cmd/erasure-sets.go:740)。同名对象在不同桶落在同一 set,这是为减少跨 set 的名字碰撞域设计的取舍。
5. **MinIO 对象在盘上按 dir.N 哈希分目录吗?** 否。对象路径就是桶目录下的字面路径(cmd/xl-storage.go:787-793、1587、1655-1690);哈希只发生在 set 选择层面。"dir.N 分桶"是 Ceph RGW 的索引做法,不是 MinIO 的。
6. **小对象会生成 part.1 文件吗?** 未必。≤128KiB 的数据内联进 `xl.meta`(cmd/xl-storage.go:60;写侧 cmd/erasure-object.go:1399-1419),盘上可能只有目录 + xl.meta 两个条目,省一次文件创建。
7. **掉了几块盘还能写吗?** 看掉线比例:写前统计 offline 数,超过半数直接拒写;否则继续写并给该对象临时提高 parity,记入 `minIOErasureUpgraded` 元数据(cmd/erasure-object.go:1306-1333)。
8. **分布式锁会死锁吗?** 不会永久持有:锁是 1 分钟租约,未续期即被后台回收(cmd/lock-rest-server.go:158-190);持有方若失去多数派,续期循环主动判负并回调(internal/dsync/drwmutex.go:276-310)。
9. **新节点加进集群会重分布数据吗?** 不。pool 是追加式的:新 pool 只接新写入(cmd/erasure-server-pool.go:637-657 按空间选 pool),旧数据靠显式 decommission/rebalance 迁移(erasure-server-pool-decom.go / -rebalance.go)。
10. **为什么启动要等 "Waiting for all MinIO sub-systems to be initialized"?** 分布式下配置/IAM 等子系统要对 config 对象走读 quorum,quorum 未齐就重试(cmd/server-main.go:585-624;可重试错误表 506-536)。

## 9. 深挖线索

1. **dsync.DRWMutex 全文精读**(internal/dsync/drwmutex.go,550 行):tolerance/quorum 推导(208-235)、锁丢失回调(276-310)、`checkFailedUnlocks` 对上一持锁者的处理(550 起)——可与 Redlock 争议对照。
2. **renameData / commitRenameDataDir 提交协议**(cmd/erasure-object.go:1564-1579;实现在 erasure-healing-common.go / xl-storage.go RenameData):两阶段 rename 如何保证部分盘失败后的可修复性,以及 oldDataDir 的清理时机。
3. **Heal 体系**:healing tracker(`xlStorage.Healing`,cmd/xl-storage.go:431-433)→ `globalBackgroundHealState`(erasure-healing.go)→ MRF 队列(cmd/erasure-object.go:1590-1616)三级流水。
4. **pool 扩容与重平衡**:decommission 的对象搬运状态机(erasure-server-pool-decom.go)与 rebalance 的 poolMeta 记账(erasure-server-pool-rebalance.go),对照第 7.2 节"不重分布"原则的例外路径。
5. **grid 多路复用层**(internal/grid/muxclient.go / muxserver.go / stream.go):单个 WebSocket 上如何做请求/流式两种复用,以及为何锁要独立 grid(cmd/grid.go:76-107 的注释动机)。

---

## 写作要点速查表

| 事实 | 位置(文件:行号) |
|---|---|
| 根入口一行转发 `minio.Main` | main.go:31-33 |
| 仅 server / fmt-gen 两个子命令 | cmd/main.go:141-142 |
| server 命令与 `{1...64}` 帮助示例 | cmd/server-main.go:199-241(示例 230) |
| 盘参数来源(ENV 优先于命令行) | cmd/server-main.go:243-271 |
| setupType 四态全局标志 | cmd/server-main.go:401-406;cmd/setup-type.go:23-38 |
| 默认端口 9000 | cmd/globals.go:65 |
| set 尺寸候选 2..16 | cmd/endpoint-ellipses.go:48 |
| set 尺寸自动推导(GCD+对称+最少 set) | cmd/endpoint-ellipses.go:52-64、71-90、95-128 |
| `MINIO_ERASURE_SET_DRIVE_COUNT` 覆盖 | cmd/endpoint-ellipses.go:323、167-181 |
| endpoint 打 (pool,set,disk) 坐标 | cmd/endpoint.go:1002-1006 |
| 对象层构建入口 | cmd/server-main.go:1199-1201;cmd/erasure-server-pool.go:78 |
| 新 pool 校验同一 deploymentID | cmd/erasure-server-pool.go:146-154 |
| format.json 含 `Sets [][]string` | cmd/format-erasure.go:112-120 |
| 启动 quorum 等待/首盘格式化 | cmd/prepare-storage.go:239-327、157-236 |
| set 选取哈希(SIPMOD/CRCMOD) | cmd/erasure-sets.go:660-694(调用 734/740) |
| 节点启动一致性校验 | cmd/bootstrap-peer-server.go:202;cmd/server-main.go:927-934 |
| 盘布局:桶=目录、对象=原名目录 | cmd/xl-storage.go:787-793;ReadVersion 1655-1690;readRaw 拼 xl.meta 1587 |
| xl.meta / 128KiB 内联阈值 | cmd/xl-storage.go:69、60;xlMetaV2 结构 cmd/xl-storage-format-v2.go:901-911 |
| part.N 路径与 DataDir UUID | cmd/xl-storage.go:2366;cmd/erasure-object.go:1352、1393-1394 |
| 写入 tmp→rename 提交 | cmd/erasure-object.go:1394、1564-1579 |
| 分片排列 hashOrder/shuffle | cmd/erasure-metadata-utils.go:178-191、270-295 |
| 默认 parity 表(4,5→2 等) | cmd/erasure-server-pool.go:122-126;cmd/format-erasure.go:682-688 |
| 本地命名空间锁 map | cmd/namespace-lock.go:66-130 |
| 本地/分布式锁二选一 | cmd/namespace-lock.go:231-242 |
| 锁 quorum 推导(写锁 +1 防脑裂) | internal/dsync/drwmutex.go:208-231 |
| 锁续期与失锁回调 | internal/dsync/drwmutex.go:276-310 |
| 锁租约回收(1 分钟) | cmd/lock-rest-server.go:158-190 |
| storage REST 前缀 /minio/storage(v63) | cmd/storage-rest-common.go:23-25 |
| peer REST 前缀 /minio/peer 及路由 | cmd/peer-rest-common.go:24-25;cmd/peer-rest-server.go:1358-1367 |
| grid 与 lock grid 路由/装配 | internal/grid/manager.go:48、51;cmd/grid.go:43-107;cmd/routers.go:28-51 |

(报告完)
