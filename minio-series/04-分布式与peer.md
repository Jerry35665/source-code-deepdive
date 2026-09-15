# 第 04 章 · 分布式与 peer:grid 网格与 quorum 锁

> 基线:commit `7aac2a2`。行号以 internal/grid/、internal/dsync/、cmd/peer-rest-server.go、cmd/storage-rest-server.go 为准。**核心事实:MinIO 没有共识协议**——一致性靠 quorum 写读+版本签名论证,而非 raft/consul。

## 4.0 全景:grid 通信层

```
每对节点一条 WebSocket(internal/grid/manager.go:48/:51 两条路径:
  /minio/grid/v1 数据+控制 /minio/grid/lock/v1 锁专用——锁面独立防队头阻塞)
谁拨号由 shouldConnect() 的 xxh3 对称哈希决定(:552-560):双方结论必然相反,杜绝双拨号
拨号端无限重连(2s+抖动);握手拒绝时钟差>5 分钟的对端
```

传输单位是 21 字节级 msgpack message{MuxID,Seq,DeadlineMS,Handler,Op,Flags,Payload}(msg.go:130-138):每次调用分配自增 MuxID,读写按 MuxID 路由;**写侧自适应合并最多 50 条/32KiB 打成 OpMerged 帧**(:1240-1252)摊薄 syscall;明文链路自动附 xxh3 CRC;断线即取消全部在途 mux(ErrDisconnected),**不缓存不重试**。HandlerID 是 uint8 枚举,255 封顶编译期 panic 检查,锁的 6 个 handler 排最前;无 deadline 默认 1 分钟。选型逻辑:gobwas/ws+msgp 零依赖、三级字节池零分配、可控的消息合并——**这些是 gRPC 给不了或给不好的**。

## 4.1 peer 控制面与盘 RPC

peer REST v39(/minio/peer/v39)HTTP 面只剩 **10 个大流量/启动期端点**(升级、profiling、speedtest);其余 **46 个 RPC**(GetLocks、IAM 广播、bucket 元数据、Trace/Listen 长驻流)全走 grid(peer-rest-server.go:73-118,:1351-1424);盘 RPC 也走 grid 子路由(**每盘一个 Subroute=盘路径**,storage-rest-client.go:998)。启动期 bootstrap Verify 强制**全簇二进制 md5+命令行+MINIO_* 环境变量一致,否则拒绝启动**(bootstrap-peer-server.go:54-106);节点间认证:JWT+15 分钟时钟容忍(:110-158)。

## 4.2 quorum 锁:无共识的互斥

internal/dsync/drwmutex.go:218-231:**读锁 quorum=⌈N/2⌉,写锁在偶数 N 强制 N/2+1**(消除 2-2 脑裂);广播 N 个 locker 数票,单节点互斥由本地 map 保证,**quorum 交集论证保证写者唯一**;**1 分钟租约**(lockValidityDuration)+每分钟后台回收+10s 续期;续期失去 quorum 即 forceUnlock 并触发 lockLossCallback(:219-231);解锁异步,释放失败靠租约兜底。lock-rest-server.go:158-190 的回收与 cmd/lock-rest-server.go:158-190 的租约同源。

## 4.3 一致性:无共识协议的论证

一致性 = **quorum 写可见**(writeQuorum=dataBlocks,均衡 EC 时+1,02 章)+ **quorum 读验证**(至少一半盘元数据一致才选版本)+ **quorum 锁串行化**;版本 ID 是客户端 UUID,**锁保证无并发写者,因此无需仲裁时间戳**;时钟只用于认证(15 分钟防重放)与本地租约判定,**不参与数据排序**;丢多数派即降级失败(A 章 availability 模式互为表里)。

## 4.4 设计动机

1. **为什么不用 etcd/consul**:对象存储的"共识需求"只有锁与配置——为它们引入一个强共识集群是部署负担;quorum 锁的"锁丢失"场景由租约+版本签名兜底;
2. **为什么 grid 用 WebSocket**:单条连接双向多路复用+自定义帧(合并/池化/CRC)——gRPC 的 HTTP/2 开销在盘 RPC 这种高频小消息下过重;
3. **锁面独立一张 grid**:锁的队头阻塞不拖累数据面(:48/:51 双路径)——**隔离即性能**;
4. **bootstrap 的一致性校验**:全簇二进制 md5 一致才启动(:54-106)——异版本混布是事故源,启动即挡。

## 4.5 FAQ

**Q1:MinIO 没有 raft,数据会不一致吗?**
quorum 写+quorum 读+quorum 锁三重约束下,可读即可信;丢 quorum 即降级失败——一致性由多数派保证,与共识的区别在"没有日志复制"。

**Q2:两节点脑裂怎么办?**
偶数 N 写锁强制 N/2+1(:218-231):2-2 分裂时双方都拿不到多数——拒绝服务优于双写。

**Q3:锁 1 分钟租约,长操作怎么办?**
每 10s 续期(:219-231);失去 quorum 触发 lockLossCallback 强制解锁。

**Q4:grid 断线重连后消息丢了怎么办?**
不缓存不重试:上层(调用方)靠超时重试——grid 只保证"在途的可靠送达"。

**Q5:时钟差 5 分钟为什么被拒?**
认证 token 防重放窗口(:110-158):时钟差过大=重放攻击面。

**Q6:盘 RPC 为什么每盘一个 Subroute?**
按盘路径路由(:998):单盘操作的寻址零查表。

**Q7:46 个 RPC 走 grid,10 个走 HTTP 的分界?**
大流量/启动期走 HTTP(可被 LB),控制/长驻流走 grid(peer-rest-server.go 注释)。

**Q8:版本 ID 是客户端 UUID,时钟不同步有影响吗?**
无:排序靠锁串行化与 ModTime 记录,版本 ID 只是标识(:530-563 的 quorum 判定不依赖时钟)。

**Q9:bootstrap 校验哪些一致性?**
二进制 md5/命令行/MINIO_* 环境变量(:54-106):异版本混布启动即拒。

**Q10:节点间认证用什么?**
JWT+15 分钟时钟容忍(storage-rest-server.go:110-158)。

## 4.6 小结与深挖方向

本章结论:**分布式="grid 双 WebSocket 网格+quorum 锁(租约制)+无共识的一致性论证"**——用最少的协作机制撑起分布式存储。深挖:

1. xxh3 选边(:552-560)在对等重启时序的双拨号残余;
2. OpMerged 合并帧(:1240-1252)在锁高频竞争的延迟;
3. 写锁 +1 规则(:218-231)在奇偶 N 的 quorum 推导;
4. 1 分钟租约(:158-190)与 GC 长停顿的锁丢失面;
5. bootstrap md5 校验(:54-106)在滚动升级的窗口策略。

> 下一章:healing 与扫描器——静默损坏的自愈闭环。
