# D — 分布式协作面：grid 网格、peer RPC 与 quorum 锁

> 本系列基于 minio/minio commit `7aac2a2`（2025 年内 master）。行号以该 commit 为准。
> 卷一 A 报告（`A-全景架构.md`）已给出结论：每节点一个进程只监听 9000，S3 API、盘 RPC、peer 控制面、锁四类流量同端口分流。本章展开分布式协作面的实现细节。

## 1. 全景：一个端口上的四个平面

9000 端口按**路径前缀**分流到四个平面（cmd/routers.go:31-50，`registerDistErasureRouters` 统一注册）：

```
                     客户端 S3 流量 (PUT/GET 对象)
                            │
                    ┌───────▼────────┐   每节点 1 个进程, 1 个端口
                    │   :9000 mux    │
                    └───┬────┬────┬──┘
        ┌───────────────┘    │    └───────────────────┐
        │(1)S3 API           │(2)(3) grid WebSocket    │(4) peer HTTP
        │对象读写             │  /minio/grid/v1          │  /minio/peer/v39/*
        │                   │  /minio/grid/lock/v1     │  (仅升级/profiling/
        │                   │                          │   speedtest 等 10 个)
        │                   │                          │
   ┌────▼────┐      ┌───────▼────────┐        ┌────────▼───────┐
   │对象层    │      │ grid Manager   │        │ peerRESTServer │
   │纠删码写读│      │ globalGrid     │        │ GetLocks/Signal│
   └────┬────┘      │ globalLockGrid │        │ LoadUser ...   │
        │           └───┬────────┬───┘        └────────────────┘
        │ 盘 RPC(grid    │        │ 锁 RPC(独立
        │ 子路由,同一条   │        │ grid manager)
        │ WS 内复用)     │        │
   ┌────▼─────────┐  ┌───▼────┐  ┌─▼──────────┐
   │storageREST   │  │peerREST│  │lockREST +  │
   │Handler(每盘一 │  │grid侧  │  │localLocker │
   │个子路由)      │  │handler │  │N 台=NetLocker│
   └──────────────┘  └────────┘  └────────────┘
        磁盘 I/O        控制面      dsync quorum 锁
```

要点：
- **两条 WebSocket 骨干**：`globalGrid`（数据/控制混合）与 `globalLockGrid`（专用锁面），路径分别为 `/minio/grid/v1` 与 `/minio/grid/lock/v1`（internal/grid/manager.go:45-52）。二者都是完整的 grid Manager 实例，在 cmd/grid.go:43-107 初始化，cmd/server-main.go:882-889 启动——先注册全部 handler，再 `close(globalGridStart)` 放行建连（cmd/server-main.go:897-899）。
- **peer REST 没有消失**：cmd/peer-rest-common.go:23-26 定义 `/minio/peer/v39`，HTTP 面只留 10 个方法（profiling、二进制升级校验、speedtest 等大流量/启动期操作，cmd/peer-rest-common.go:30-39）；其余控制面调用已全部迁到 grid。
- **盘 RPC 也走 grid**：每块远端盘对应 grid 上的一个子路由 `Connection(endpoint.GridHost()).Subroute(endpoint.Path)`（cmd/storage-rest-client.go:998），RenameData/WriteMetadata/ReadVersion 等 20+ 个 handler 以盘路径为子路由注册（cmd/storage-rest-server.go:1377-1388）。

## 2. grid 专节：单条 WebSocket 上的双向多路复用

### 2.1 连接的建立：谁拨号由哈希决定

N 节点集群中每个节点持有到其余 N-1 个节点的 `Connection`（internal/grid/manager.go:117-139，本地节点跳过，本地不在列表直接报错 manager.go:141）。每对节点之间只需要一条连接，由**对称哈希**决定谁来当客户端（internal/grid/connection.go:552-560）：

```go
func (c *Connection) shouldConnect() bool {
    // The remote should have the opposite result.
    h0 := xxh3.HashString(c.Local + c.Remote)
    h1 := xxh3.HashString(c.Remote + c.Local)
    if h0 == h1 {
        return c.Local < c.Remote
    }
    return h0 < h1
}
```

双方对同一对地址算出相反结论，一端拨号、另一端 `handleIncoming` 接收；接错了方向会被拒绝（connection.go:791-796）。拨号端是无限重连循环（connection.go:640-732），失败后退避 `defaultDialTimeout`(2s)+随机抖动（connection.go:660）。握手是应用层的 `OpConnect` 消息（connection.go:679-688），服务端在此校验主机名、**时钟差不得超过 5 分钟**（internal/grid/manager.go:255）和 JWT token（manager.go:259）。WebSocket 升级请求本身带 `Authorization: Bearer` 与 `X-Minio-Time` 头（internal/grid/grid.go:219-221）。

### 2.2 一条连接承载成千上万个并发调用：MuxID 复用

协议的最小单位是 21 字节左右的 msgpack `message` 头（internal/grid/msg.go:130-138）：

```go
//msgp:tuple message
type message struct {
    MuxID      uint64    // Mux to receive message if any.
    Seq        uint32    // Sequence number.
    DeadlineMS uint32
    Handler    HandlerID // ID of handler if invoking a remote handler.
    Op         Op        // Operation. Other fields change based on this value.
    Flags      Flags
    Payload    []byte
}
```

每次调用（`Connection.Request`，connection.go:348）分配一个自增 `MuxID`（connection.go:313-333），读写两侧各用一张 xsync.Map 按 MuxID 路由（connection.go:91-94）；单请求-响应走 `OpRequest/OpResponse`（connection.go:1294-1295, 1446-1459），双向流走 `OpConnectMux/OpMuxClientMsg/OpMuxServerMsg` 加每方向独立的流控 `OpUnblock*Mux`（msg.go:56-98；分发中心 `handleMsg`，connection.go:1274-1305）。单请求无 deadline 时默认 1 分钟（internal/grid/grid.go:68；handler 侧同样兜底，internal/grid/handlers.go:553）。

### 2.3 消息合并与保活：吞吐的关键

- **写侧合并**：写 goroutine 从 `outQueue`（容量 65535，connection.go:196）取消息，若队列里还有积压，最多凑 50 条（`maxMergeMessages`，internal/grid/grid.go:60）、总大小 32KiB-1KiB 以内，打包成一条 `OpMerged` 帧一次写 socket（connection.go:1178-1267，合并帧构造在 1240-1252）。读侧拆包对应 connection.go:1033-1063。
- **保活**：连接级 ping 每 10s（`connPingInterval`，connection.go:200），连续 2 个周期无 pong 即断开（connection.go:1150-1157）；流上每个 mux 另有 15s 的应用层 ping（`clientPingInterval`，grid.go:62-64）。
- **完整性**：明文链路自动附加 xxh3 CRC（`FlagCRCxxh3`，connection.go:256-261 设置、597-600 追加；接收端校验 msg.go:214-225）。
- **断线语义**：重连成功即清空全部在途 mux 并以 `ErrDisconnected` 唤醒等待者（`reconnected`，connection.go:831-883；`disconnected`，connection.go:734-750）。grid 不重试、不缓存——重试语义留给上层业务调用方。

### 2.4 handler 注册与类型安全封装

HandlerID 是 `uint8` 枚举，编译期静态检查上限 255（internal/grid/handlers.go:214-220），锁的 6 个 handler 排在最前（handlers.go:41-46），其后是盘 RPC、peer 控制面共 70 余个（handlers.go:39-126）。服务端注册用 `RegisterSingleHandler`/`RegisterStreamingHandler`（internal/grid/manager.go:285-310, 330-352）；调用侧由泛型 `SingleHandler[Req,Resp].Call` 负责序列化与对象池回收（handlers.go:554-589），`Register` 完成类型化包装（handlers.go:511-544）。子路由用 `sha256(subroute)` 的 32 字节作 key（handlers.go:346-353），因此一块盘一个命名空间互不冲突。

### 2.5 与 gRPC 的取舍

同样的"每对节点一条长连接、多路复用、双向流"用 gRPC/HTTP2 也能做，MinIO 自研 grid 的动机在代码里可见：
1. **零依赖、零反射**：gobwas/ws（裸 WebSocket 帧读写）+ msgp（生成式 msgpack），无 protobuf 运行时；handler 是 `[]byte→([]byte, err)`，编解码由代码生成器静态展开（handlers.go:297, 320）。
2. **极致的缓冲区复用**：三级字节池 1KiB/4KiB/32KiB~96KiB（grid.go:41-57, 89-123），读写热路径几乎零分配（connection.go:996 注释 "Keep reusing the same buffer"）。gRPC 的 per-call 元数据与 header 开销在此场景是纯浪费——节点间调用双方都是自己人，不需要跨语言 IDL。
3. **消息合并可控**：写侧按队列状态自适应合并（2.3），这是 HTTP/2 需要内核或代理层配合才能拿到的行为。
4. **两条独立网格**：锁流量单独一张 grid，锁的队头阻塞不波及数据面；用 gRPC 则要起两套 server。

## 3. peer RPC 专节：控制面调用清单

`peerRESTClient` 每个 peer 一个（cmd/peer-rest-client.go:629-649，`hostsSorted()` 保证全簇顺序一致），内部持有 HTTP rest client 和**懒加载**的 grid 连接（cmd/peer-rest-client.go:78-104）。

**走 grid 的（`xxxRPC.Call(ctx, client.gridConn(), ...)`）**，服务端定义在 cmd/peer-rest-server.go:73-118，注册在 1351-1424：

| 类别 | 调用 | 客户端 | 服务端 handler |
|---|---|---|---|
| 锁诊断 | GetLocks 拉远端锁表 | peer-rest-client.go:152-159 | peer-rest-server.go:128-131（`globalLockServer.DupLockMap()`） |
| 存储/节点信息 | LocalStorageInfo / ServerInfo / GetCPUs / GetMemInfo / GetOSInfo / GetPartitions / GetNetInfo / GetSysConfig / GetSysErrors | 162-228 | 356-466 |
| 元数据缓存 | GetMetacacheListing / UpdateMetacacheListing | 441-459 | 560-570 |
| IAM 广播 | Load/DeleteUser、ServiceAccount、Policy、PolicyMapping、LoadGroup | 321-385 | 134-300 |
| 桶元数据 | Load/DeleteBucketMetadata、Get(All)BucketStats | 276-318 | 467-556 |
| S3 对等操作 | ListBuckets / MakeBucket / HeadBucket / DeleteBucket / HealBucket | cmd/peer-s3-client.go:333-491 | cmd/peer-s3-server.go:36-283 的 local 实现经 peer-rest-server.go:1396-1409 暴露 |
| 运维 | SignalService（重启/停衡再平衡等）、ReloadPoolMeta、LoadRebalanceMeta、StopRebalance、ReloadSiteReplicationConfig、LoadTransitionTierConfig、BackgroundHealStatus、DeleteUploadID | 387-508 | 693-1023 |
| 长驻流 | Trace（OutCapacity=100000，peer-rest-server.go:1418-1423）、ConsoleLog、Listen、各类实时 metrics | 510-623 | 762-1018 |

**仍走 HTTP rest client 的（`callWithContext`）**：StartProfiling/DownloadProfileData（253-273）、VerifyBinary/CommitBinary（升级，398-420）、SpeedTest/DriveSpeedTest/Netperf/DevNull（725-816）、GetReplicationMRF（819-847）。共同点：请求或响应是**流式大块**（升级包、perf 数据），或发生在 grid 尚未就绪的启动期。

**启动期一致性校验**走 bootstrap 面：`HandlerServerVerify` 返回二进制 md5、全部命令行与 MINIO_* 环境变量哈希（cmd/bootstrap-peer-server.go:122-148），`ServerSystemConfig.Diff` 逐项比对，任何不一致（二进制版本、endpoint 数、环境变量）都会让启动失败（54-106）。这就是 MinIO "所有节点必须跑同一版本同一配置" 的强制执行点。

## 4. 分布式锁专节：dsync 的 quorum 算法

### 4.1 三层结构

- **接口**：`NetLocker`（internal/dsync/locker.go:23-67）：Lock/RLock/Unlock/RUnlock/Refresh/ForceUnlock。
- **算法**：`DRWMutex`（internal/dsync/drwmutex.go:113-123）——Distributed RW Mutex，按"资源名列表"加锁。
- **服务端**：`localLocker` 是每节点的本地锁表（cmd/local-locker.go:63-74，`lockMap map[string][]lockRequesterInfo`）；远端访问经 `lockRESTClient` 打到 peer 的独立 grid（cmd/lock-rest-client.go:101-111，`globalLockGrid.Load().Connection(ep.GridHost())`）；6 个 handler 注册在 cmd/lock-rest-server.go:124-139。

### 4.2 quorum 计算：N/2 起步，偶数写锁 +1

核心在 `lockBlocking`（internal/dsync/drwmutex.go:218-231）：

```go
// Tolerance is not set, defaults to half of the locker clients.
tolerance := len(restClnts) / 2

// Quorum is effectively = total clients subtracted with tolerance limit
quorum := len(restClnts) - tolerance
if !isReadLock {
    // ...to avoid split brains we make sure to acquire
    // quorum + 1 when tolerance is exactly half...
    if quorum == tolerance {
        quorum++
    }
}
```

- 读锁 quorum = ⌈N/2⌉；**写锁在偶数 N 时取 N/2+1**（4 节点：读 2、写 3）。
- 加锁是**广播到全部 N 个 locker**再数票（internal/dsync/drwmutex.go:453-482），拿到超过 `tolerance` 个拒绝就提前放弃并回滚已获准的部分（493-520），最终 `checkQuorumLocked` 判定（522, 576-585）；不足则 `releaseAll` 释放（526, 588-606），释放不掉的部分依赖租约过期兜底（527 行日志明言 "these locks will expire automatically"）。
- **单点授予的互斥性**由 locker 本地保证：资源已被占用即拒绝（cmd/local-locker.go:89-97 `canTakeLock`，写在持有中拒绝读，cmd/local-locker.go:222）。quorum 交集论证：两个写锁各需 >N/2 个节点批准，而单节点对同一资源只批一个写锁，鸽笼原理保证不相交；偶数 +1 消除 2-2 分裂。

### 4.3 租约与续期：呼应 A 报告的"1 分钟"

- 锁的**有效期 1 分钟**：`lockValidityDuration = 1 * time.Minute`（cmd/lock-rest-server.go:158-164），后台 `lockMaintenance` 每分钟扫一次，把 `TimeLastRefresh` 超过 1 分钟没续上的锁直接删掉（cmd/lock-rest-server.go:168-190 → cmd/local-locker.go:407-436 `expireOldLocks`）。
- 持锁方每 **10 秒**续期一次（`drwMutexRefreshInterval`，internal/dsync/drwmutex.go:84；循环在 276-309）。续期时统计"还活着"的 locker 数，**低于 quorum 即判负**：本地 `forceUnlock` + 触发调用方注册的 `lockLossCallback`（internal/dsync/drwmutex.go:293-303）。`refreshLock` 的判定条件是 `lockNotFound > len(restClnts)-quorum`（416）。
- **解锁是异步的**：`Unlock`/`RUnlock` 起 goroutine 广播释放，不阻塞调用方（internal/dsync/drwmutex.go:639-650, 684-694），释放失败在 30s 预算内重试；反正租约 1 分钟必过期，不会永久泄漏。
- 各超时常量：加锁容忍 1s、续期调用 5s、解锁调用 30s（internal/dsync/drwmutex.go:70-87）。

### 4.4 脑裂防护清单

1. 写锁 quorum 在偶数 N 时强制 +1（drwmutex.go:222-231），2-2 分区两边都拿不到写锁。
2. 分区期间持锁方失去多数派 → 续期失败 → 主动放弃并回调（293-303），另择节点可在多数派侧重获锁。
3. 锁请求带 `Quorum` 指针下发给服务端存档（cmd/local-locker.go:51, 134），锁表可诊断（GetLocks）。
4. 网络抖动下 locker 本地排队超 1000 直接拒绝（`lockMutexWaitLimit`，cmd/local-locker.go:33-39），防止锁服务自身被打垮。

## 5. 一致性专节：没有共识协议，凭什么一致？

MinIO 集群里**没有 Raft/Paxos、没有 leader、没有复制日志**。一致性靠"纠删码 quorum + 分布式锁串行化 + 版本化写入"三个机制拼出来：

### 5.1 写路径：quorum 提交

一次 PutObject 在 set 内 N 盘上并行写 erasure 分片和 `xl.meta`，成功数由 writeQuorum 把关（cmd/erasure-object.go:1117-1124）：

```go
// we now know the number of data drives on this object...
// writeQuorum is dataBlocks + 1
writeQuorum := dataDrives
if dataDrives == parityDrives {
    writeQuorum++
}
```

写入经 `renameData` 原子改名提交，错误容忍上限是 `len(disks) - writeQuorum`（cmd/erasure-object.go:1019-1098；`reduceWriteQuorumErrs` 在 1059）。写 quorum 的语义：**至少 dataBlocks 份 xl.meta + 数据分片落盘，对象才可见**。

### 5.2 读路径：quorum 验证

读元数据时收集 N 盘的 `xl.meta`，`objectQuorumFromMeta` 要求**至少一半盘的元数据可用且一致**（cmd/erasure-metadata.go:530-541），并按 parity 推出本次读的 read/write quorum（548-563）；版本选择在 quorum 支持的公共版本上做（`reduceCommonVersions`，cmd/erasure-object.go:1083）。所以"最新写入"的判定标准不是时间戳，而是**写成功时多数盘上已经存在的那个版本**——读不到 quorum 的版本宁可报 `InsufficientReadQuorum`。

### 5.3 版本与并发：UUID 版本 ID + 锁串行化

每个对象版本有客户端生成的 UUID versionID（无序、无冲突），同一对象的并发写入由 dsync 锁串行化（第 4 节）：任一时刻最多一个写者持有某资源的写锁 quorum。因此**不存在需要仲裁的"双主写入"**——这不是靠共识协议选出主，而是靠 quorum 锁在数学上保证写者唯一。

### 5.4 时钟的角色：只管认证和租约，不管排序

跨节点时钟在 MinIO 只有三个用途，全部与数据排序无关：
1. **节点间认证防重放**：REST/WS 请求带 `X-Minio-Time`，偏差超 `DefaultSkewTime = 15 分钟` 拒绝（cmd/storage-rest-server.go:110, 141-158）；grid 握手消息里的时间偏差超过 5 分钟拒连（internal/grid/manager.go:255）。JWT 用根密钥签名（113-125）。
2. **锁租约过期**：`expireOldLocks` 比较的是 locker 节点**本地**记录的 `TimeLastRefresh`（续期到达时打点，cmd/local-locker.go:393）与本地当前时间（415），不存在跨节点时钟比对。
3. 元数据里的 `ModTime` 仅作展示与 heal 辅助，不作为一致性依据。

结论：MinIO 的一致性 = **quorum 写可见 + quorum 读验证 + quorum 锁串行化**，三者都是"多数派交集"论证，代价是**丢多数派即降级**——这正是 A 报告 availability 模式的另一面：写需要 writeQuorum、读需要 readQuorum、锁需要 lockQuorum，任何一项不满足立即失败而不是等待恢复（无 leader 就没有"等"的对象）。

## 6. 设计动机

**为什么不用 etcd/consul？**
- 锁的规模问题：MinIO 的锁粒度是"对象级"（bucket/object/version），大集群每秒锁请求数以万计，etcd 的 raft 日志写入是持久化的、有界的，根本扛不住这个量级；dsync 的锁授予只动内存 map（cmd/local-locker.go:99-141），持久态就是租约过期语义本身，零 fsync。
- 可用性模型一致：MinIO 本来就是 quorum 系统，etcd 反而引入第二套故障域（etcd 自身失 quorum 会让整个存储集群瘫痪，而存储集群明明还有多数盘活着）。
- 部署简单是硬需求：二进制单文件、一个端口起步，引入第三方协调服务直接破坏产品形态。

**为什么单端口多协议？** A 报告已述运维面（防火墙、k8s Service 只暴露一个端口）；实现面看，WS 升级走的是同一个 mux 与同一套认证中间件（cmd/routers.go:46-49），`guessIsRPCReq` 靠路径前缀区分（cmd/generic-handlers.go:245-256），无额外 listener、无额外 TLS 证书管理。

**为什么 quorum 锁而不是强共识锁？** quorum 锁是"租约式"的：牺牲分区期间的绝对互斥时限（失去多数派的持锁者最多在 1 分钟租约 + 续期检测窗口内仍自认为持有），换取无 leader 的全对称架构与极高吞吐。MinIO 用 `lockLossCallback`（drwmutex.go:299）把"锁丢了"显式通知业务层补救，把风险面收窄到可接受。这是与它"对象存储天然按 set 分区、单 set 内自治"的架构自洽的选择——它从不假装自己是 CP 元数据系统。

## 7. FAQ 素材与深挖线索

**FAQ（8-10 条）**
1. 集群内部要开几个端口？一个 9000。四条路径：`/minio/grid/v1`、`/minio/grid/lock/v1`（两条 WS）、`/minio/peer/v39/*`（HTTP）、`/minio/storage/<pool>/v63/*`（盘 RPC 的 HTTP 兜底）。
2. 为什么有两条 grid？数据/控制面与锁面分离（cmd/grid.go:32-35），锁的队头阻塞不波及盘 RPC。
3. grid 断线会怎样？全部在途调用立即以 `ErrDisconnected` 失败（connection.go:831-883），不重试；连接自动重建，重试由业务层决定。
4. 节点间时钟允许差多少？认证 15 分钟（storage-rest-server.go:110）、grid 握手 5 分钟（manager.go:255）；超了整个集群拒绝互联。时钟不参与数据排序。
5. 锁会死锁吗？不会永久持有：1 分钟租约（lock-rest-server.go:158-190）+ 10s 续期；持锁方失 quorum 会主动放弃并回调。
6. 偶数节点写锁为什么 quorum+1？防止 2-2 分区双写（drwmutex.go:222-231）。
7. peer REST 和 grid 什么关系？v39 HTTP 面是迁移残留，只剩升级/profiling/benchmark 等 10 个大流量端点；其余全是 grid RPC。
8. 集群如何保证所有节点同版本同配置？启动期 bootstrap Verify 比对二进制 md5、命令行、MINIO_* 环境变量（bootstrap-peer-server.go:54-106）。
9. handler 数量有上限吗？HandlerID 是 uint8，255 封顶，超了编译期 panic（handlers.go:214-220）；语义不兼容必须新增 ID 而不是改旧 ID（handlers.go:120-123 注释）。
10. 一台节点宕机，锁和读写怎么办？宕机节点 ≤ tolerance 时一切照旧（锁、读写 quorum 仍满足）；超过则新锁/新写失败、已持锁在租约到期后被回收，读在 readQuorum 内仍可用（呼应 A 报告 availability 模式）。

**深挖（3-5 条）**
1. 写侧自适应消息合并：`writeStream` 的 50 条/32KiB 合并窗口与 `runtime.Gosched()` 让路技巧（connection.go:1178-1188），可用 benchmark_test.go 复现吞吐差异。
2. 流控协议：`OpUnblockSrvMux/OpUnblockClMux` + 每方向 Seq 确认（muxclient.go/muxserver.go），对照 HTTP/2 WINDOW_UPDATE 的简化版。
3. `shouldConnect` 的对称哈希选边（connection.go:552-560）：为什么不能简单用"字典序小的一端拨号"（提示：`h0==h1` 的回退分支暴露了边界情况）。
4. storage REST 的双协议残留：HTTP `call/callGet`（storage-rest-client.go:176-199）与 grid 子路由并存，哪些路径还在走 HTTP、为什么保留（健康检查与过渡兼容）。
5. 无共识下的一致性边界实验：人为把 set 内盘数打到 readQuorum 与 writeQuorum 之间，观察读到的版本与 `InsufficientReadQuorum` 行为（erasure-metadata.go:530-563）。

## 8. 写作要点速查表

| 关键事实 | 位置 |
|---|---|
| grid/lock 两条 WS 路径 `/minio/grid[/lock]/v1` | internal/grid/manager.go:45-52 |
| 每对节点一条连接、xxh3 对称哈希选边 | internal/grid/connection.go:552-560 |
| message 头（MuxID/Seq/DeadlineMS/Handler/Op/Flags） | internal/grid/msg.go:130-138 |
| 写侧合并：maxMergeMessages=50、OpMerged 帧 | internal/grid/grid.go:60；connection.go:1240-1252 |
| 单请求默认 1 分钟 deadline | internal/grid/grid.go:68；handlers.go:553 |
| HandlerID uint8 上限 255 静态检查 | internal/grid/handlers.go:214-220 |
| grid 握手拒绝 >5 分钟时钟差 | internal/grid/manager.go:255 |
| 两张 grid 初始化（globalGrid/globalLockGrid） | cmd/grid.go:43-107；server-main.go:882-899 |
| peer REST 仅 10 个 HTTP 方法，v39 | cmd/peer-rest-common.go:23-39 |
| peer 控制面 RPC 清单（46 个）注册 | cmd/peer-rest-server.go:73-118, 1351-1424 |
| bootstrap 校验二进制/参数/env 一致 | cmd/bootstrap-peer-server.go:54-106, 144-154 |
| 锁 quorum：N/2 起步、偶数写锁 +1 | internal/dsync/drwmutex.go:218-231 |
| 锁租约 1 分钟 + 每分钟回收 | cmd/lock-rest-server.go:158-190 |
| 续期 10s，失 quorum → forceUnlock+回调 | internal/dsync/drwmutex.go:276-309, 416 |
| locker 本地锁表与互斥 | cmd/local-locker.go:89-97, 99-141 |
| writeQuorum = dataBlocks（均衡时 +1） | cmd/erasure-object.go:1117-1124 |
| readQuorum 至少一半元数据一致 | cmd/erasure-metadata.go:530-541 |
| 节点间认证 15 分钟时钟容忍 + JWT | cmd/storage-rest-server.go:110-158 |
| 盘 RPC 走 grid 子路由（每盘一个） | cmd/storage-rest-client.go:998 |
