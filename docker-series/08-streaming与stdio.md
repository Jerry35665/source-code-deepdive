# 第 08 章 · streaming 与 stdio:通道的选择

> 基线:commit `f6132db`。行号以 core/streaming/、plugins/streaming/、internal/cri/io/ 为准。**勘误(与流行说法相反)**:exec/attach **默认走 FIFO 而非 GRPC 流**(io_type 决定,internal/cri/server/container_execsync.go:176-181);streaming 服务的头号消费者是 **transfer(镜像推拉)**,不是 exec。

## 8.0 全景:exec 的三段通道

```
kubectl ↔ k8s streaming server(HTTP 长连接)
   ↔ CRI ↔ shim(数据面按 io_type 二选一:默认 FIFO,io_type="streaming" 走 GRPC/ttrpc 流)
   ↔ exec 进程(runc 匿名管道,不变)
```

CRI 把通道"伪装"成 `cio.FIFOSet`——字段从文件路径**泛化为 `ttrpc+unix://…?streaming_id=<id>` URL**,Attach 管线零改动兼容两种通道(internal/cri/io/helpers.go:168-184 的分派就是 `strings.Contains(url,"://")`)。

## 8.1 streaming 服务:一条 rpc 的极简协议

proto 只有一条 `rpc Stream(stream Any)`+`StreamInit{id}` 握手(api/services/streaming/v1/streaming.proto:25-31);客户端 Create 发 ID 等 ack(plugins/services/streaming/service.go:72-106),服务端把流的半边按 ID 注册进 streamManager(带 namespace/lease,**注册为 GC 可回收资源** :190-205,:230-268),`Get(id)` 取同一流对象互发 typeurl.Any(core/streaming/proxy/streaming.go:75-106)。字节流适配用 32KB Data 块+WindowUpdate 滑窗(core/transfer/streaming/stream.go:35-36)。连 shim 端点建流在 internal/cri/io/streaming.go:67-118。

## 8.2 exec 的真身

client task.Exec(:443-489)把地址进 RPC;shim 真实化 execProcess(cmd/containerd-shim-runc-v2/process/init.go:404-427)——**exec 进程与 init 进程是兄弟**(runc exec --detach);shim 端 scheme 分派 :84-132 与主 stdio 同一套。attach 回流用 WriterGroup 多路复用(internal/cri/io/container_io.go:164-232);daemon 重启重连按 State 恢复 FIFO(client/container.go:479-516)。

## 8.3 transfer:streaming 的头号消费者

镜像推拉(pull/push)在 2.x 走 transfer service(07 章 :187-191):**镜像层的数据流经 GRPC streaming 在 daemon 与客户端间搬运**——这是 streaming 服务真正的吞吐大户,exec/attach 只是可选通道。

## 8.4 设计动机

1. **exec 为什么默认 FIFO**:FIFO 零序列化、经内核管道,延迟最低;GRPC 流是为"客户端与 shim 不同机"的场景(exec 在 K8s 里需要跨网络)——**io_type 让场景选通道**;
2. **流注册为 GC 资源**:断连的流不泄漏(lease 回收 :190-205)——与 12 章租约体系合流;
3. **URL 伪装**:FIFOSet 的路径字段泛化成 URL,Attach 管线零改——**接口泛化优于分支特判**;
4. **32KB 块+滑窗**:GRPC 流上的背压——流控不从传输层白拿。

## 8.5 FAQ

**Q1:exec 默认走 GRPC 吗?**
不:默认 FIFO(:176-181),io_type="streaming" 才走——流行说法以讹传讹。

**Q2:streaming 服务的最大用户是谁?**
transfer(镜像推拉):镜像层数据经 GRPC 流搬运——不是 exec。

**Q3:流断了怎么办?**
注册带 lease(:190-205):断连后回收,客户端重连重建。

**Q4:为什么用 32KB 块+WindowUpdate?**
GRPC 无内建流控:应用层滑窗做背压(:35-36)。

**Q5:exec 进程和 init 是父子吗?**
兄弟(runc exec --detach,:404-427):exec 死不影响主容器。

**Q6:daemon 重启后 attach 还能用吗?**
FIFO 通道可以(按 State 恢复 :479-516);streaming 通道重建。

**Q7:K8s 的 kubectl exec 全链?**
kubectl→streaming server(HTTP)→CRI→shim→exec:第一段才是 HTTP(:io helpers)。

**Q8:FIFO 通道的路径会冲突吗?**
每 exec 独立目录:FIFOSet 按执行 ID 组织。

**Q9:类型 Any 是什么?**
typeurl 的类型化打包:流的载荷可以是任意注册类型(:75-106)。

**Q10:streaming 型 shim 是什么?**
version≥3 的 sandbox shim 实现 streaming 服务:仓内 runc-v2 不实现——仓外扩展位。

## 8.6 小结与深挖方向

本章结论:**通道选择=场景决定(FIFO 默认/streaming 跨机);接口泛化(FIFOSet→URL)让通道可插**。深挖:

1. WindowUpdate 滑窗(:35-36)参数在长肥管道的表现;
2. streaming 型 sandbox shim 的仓外实现(谁在做);
3. transfer 流的断点续传语义;
4. URL 分派(:168-184)对非 TCP socket 的覆盖;
5. WriterGroup 多路复用(:164-232)的 fanout 上限。

> 下一章:CRIU——容器的冻结与复活。
