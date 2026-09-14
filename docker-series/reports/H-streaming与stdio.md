# H — streaming 与 stdio:exec/attach 的第二通道

> 调研对象:containerd commit `f6132dbe1f482cbe0aebc4bd3d8d7a184fb4a2aa`(2026-09-10,2.x 主干);
> 文中 文件:行号 均基于该 commit。姊妹篇:卷一 C 报告讲容器**主 stdio**(FIFO 直通);
> 本章讲 streaming 子系统与 exec/attach"第二通道"。

---

## 1. 全景:一次 exec 的数据流

exec/attach 有两个正交维度:**控制面**(怎么把"执行这条命令"告诉 shim)与**数据面**(stdio 字节
怎么流回)。控制面永远是 task API 的 `Exec` RPC;数据面按 `io_type` 分叉:

```
kubectl exec -it app -- sh
   │ ① SPDY/WebSocket 长连接(k8s streaming server)
   ▼
containerd 内置 CRI 插件 ──Exec()──▶ streamServer.GetExec() 返回流地址
   │            (internal/cri/server/container_exec.go:28-40)
   │ kubectl 连上流服务器后,回调 streamRuntime.Exec()
   │            (internal/cri/server/streaming.go:76-96)
   │
   │ ② 建 exec 数据通道(按 ociRuntime.IOType 二选一,
   │    internal/cri/server/container_execsync.go:176-181)
   ├─ FIFO(默认):NewFifoExecIO(internal/cri/io/exec_io.go:40-55),
   │    /run/.../io/<execid>-stdout 等 FIFO 文件 ──┐
   ├─ streaming:NewStreamExecIO(exec_io.go:69-84),┤ 都"伪装"成
   │    CRI 连 shim 端点建 3 条 ttrpc/grpc 流       │ cio.FIFOSet:
   │    (internal/cri/io/streaming.go:67-118)      ─┘ 真路径或流 URL
   │                                                  (helpers.go:95-109)
   │ ③ 控制面:task.Exec RPC,stdio"地址"进请求
   │    client/task.go:443-489 → api/runtime/task/v2/shim.proto:81-89
   ▼
┌─ shim(runc-v2 或支持 streaming 的 sandbox shim)────────────────┐
│ 入口 task/service.go:385-405;真实化 execProcess(init.go:404-427)│
│ start(exec.go:181-245):                                         │
│  ├ createIO(io.go:84-132):识别 fifo/binary/file scheme;          │
│  │  streaming 型 shim 在此以服务端身份接住 streaming_id 流        │
│  ├ runc exec --detach(与 init 同 cgroup/ns,spec 独立)            │
│  └ copyPipes(io.go:134-):runc 管道 ⇄ FIFO/GRPC 流                │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼ runc exec
                exec 进程(= init 的兄弟进程,非父子)
                stdout → runc 匿名管道 → shim 拷贝 → FIFO 或 GRPC 流
                           ▲ ④ 消费端泵回 HTTP 长连接
            FIFO:CRI ExecIO.Attach(exec_io.go:92-152)
            streaming:流适配成 io.ReadCloser/WriteCloser
            (internal/cri/io/streaming.go:51-65)后同样交给 Attach
```

三段通道:①kubectl↔k8s streaming server(HTTP 长连接);②CRI↔shim(FIFO 文件或 GRPC 流,由
FIFO 路径/streaming_id 约定解耦);③shim↔exec 进程(runc 匿名管道,不变)。streaming 只改造②。

---

## 2. streaming 服务专节:Any 双向流与它的"接线板"角色

### 2.1 协议:一条 RPC,万物流

`api/services/streaming/v1/streaming.proto:25-31` 只有一个双向流:

```proto
service Streaming {
  rpc Stream(stream google.protobuf.Any) returns (stream google.protobuf.Any);
}
message StreamInit { string id = 1; }
```

载荷是 `typeurl.Any` 信封——不关心是镜像层字节还是 exec 的 stdout。ttrpc 版由
`api/services/streaming/v1/streaming_ttrpc.pb.go:37-49` 注册(`containerd.services.streaming.v1.Streaming`),
让 shim 也能在 ttrpc socket 上提供同一服务。

### 2.2 服务端:先注册,后应答

GRPC 门面 `plugins/services/streaming/service.go:46-59`(GRPCPlugin,ID="streaming"),核心
handler 同文件 72-106:

```go
func (s *service) Stream(srv api.Streaming_StreamServer) error {
        a, err := srv.Recv()                    // 第一条消息必须是 StreamInit
        ss := &serviceStream{s: srv, cc: make(chan struct{})}
        if err := s.manager.Register(srv.Context(), i.ID, ss); err != nil {
                return err                       // 同 ID 重复注册 → ErrAlreadyExists
        }
        // Send response packet after registering stream
        if err := srv.Send(typeurl.MarshalProto(emptyResponse)); err != nil { return err }
        select {
        case <-srv.Context().Done():
        case <-cc:                               // Close() 触发,handler 退出
        }
        return nil
}
```

语义:**谁对 daemon 打开 Stream RPC 并自报 ID,daemon 就把流的"服务端半边"登记到该 ID 下**;
之后持有 StreamManager 的进程内组件用 `Get(id)` 拿到同一流对象,双方互发消息。"流"由此变成
**按 ID 对接的接线板**:一端远程(GRPC/ttrpc 客户端),另一端进程内(transfer 或 shim 内部)。

### 2.3 管理器:namespace + lease + GC

- 接口 `core/streaming/streaming.go:25-47`:`StreamManager = Get + Register`;`Stream` 仅
  `Send(typeurl.Any)/Recv()/Close()` 三个方法。
- 实现 `plugins/streaming/manager.go:35-56`:StreamingPlugin(ID="manager"),依赖 metadata,
  注册为可回收资源 `md.RegisterCollectibleResource(metadata.ResourceStream, sm)`(52 行;
  常量 core/metadata/gc.go:54-55);存储 `streams map[ns]map[name]` 与 `byLease map[ns]map[lease]`
  (58-65);`Register` 67-105(重复 ID 报 ErrAlreadyExists,86-88),`Get` 107-122。
- GC:collectionContext 在 172-268。关键设计:`Active()` 对**带 lease 的流不报活跃**
  (190-205,"the lease will determine the status"),流生死由 lease 决定;`Finish()`(230-268)
  对被回收流逐个 Close;`ReferenceLabel()` 返回 "stream"(133-135)。

### 2.4 客户端代理:Create 的握手

`core/streaming/proxy/streaming.go:38-61` 的 `NewStreamCreator` 用 `any` 参数适配五种上游:
StreamingClient / grpc.ClientConnInterface / TTRPCStreamingClient / *ttrpc.Client,甚至直接复用
另一个 StreamCreator。`Create`(75-106):发 `StreamInit{id}` → 等 daemon 注册后的 ack → 返回
可用流;`clientStream`(108-135)给 Send 加互斥锁,Close 走 `CloseSend()`。

```go
stream, err := sc.client.Stream(ctx)
a, err := typeurl.MarshalAny(&streamingapi.StreamInit{ID: id})
err = stream.Send(typeurl.MarshalProto(a))
// Receive an ack that stream is init and ready
if _, err = stream.Recv(); err != nil { ... }
return &clientStream{s: stream}, nil
```

### 2.5 分帧与流控:没有环形缓冲

streaming 服务本身**没有 circular buffer**——只是 Any 消息流。把字节流装进消息的是 transfer
侧适配器(`core/transfer/streaming/`):

- 发送端 `SendStream`(stream.go:45)/`WriteByteStream`(writer.go:31-74):按 **32KB** 切块
  (`maxRead = 32*1024`,stream.go:35)打成 `transferapi.Data`;
- 接收端 `ReadByteStream`(reader.go:39)/`Read`(reader.go:75-119):整块收下、用 `remaining`
  切片零拷贝喂调用方(77-85);
- **滑窗流控**:接收端余量低于 `windowSize = 2*maxRead`(stream.go:36)回发 `WindowUpdate`
  (reader.go:107-113),发送端凭窗口配额写(writer.go:83+);消息定义
  api/types/transfer/streaming.proto:23-29。背压靠显式 WindowUpdate,与 HTTP/2 自身流控叠加。

---

## 3. exec 专节:从 client 到兄弟进程

### 3.1 client 侧:一次 RPC 真实化 process 对象

`client/task.go:443-489`:

```go
i, err := ioCreate(id)                    // 此刻就建好 FIFO/流
cfg := i.Config()
request := &tasks.ExecProcessRequest{
        ContainerID: t.id, ExecID: id, Terminal: cfg.Terminal,
        Stdin: cfg.Stdin, Stdout: cfg.Stdout, Stderr: cfg.Stderr, // 路径或 URL
        Spec: pSpec,
}
if _, err := t.client.TaskService().Exec(ctx, request); err != nil { ... }
return &process{id: id, task: t, io: i}, nil
```

要点:**stdio 以"地址字符串"进 RPC**;`process` 只是 client 侧引用,真进程对象在 shim 里。

### 3.2 daemon → shim 控制面

daemon bridge 把 tasks.Exec 转给 shim:`core/runtime/v2/bridge.go:185`(ttrpc v2)/ `:300`
(grpc v3);shim 侧客户端封装 `core/runtime/v2/shim.go:828-849`(shimTask.Exec)。runc shim
入口 `cmd/containerd-shim-runc-v2/task/service.go:385-405`:预留 exec ID → `container.Exec`
(runc/container.go:373)→ 发 `TaskExecAdded` 事件。

### 3.3 exec 进程与 init 进程:兄弟而非父子

`cmd/containerd-shim-runc-v2/process/init.go:404-427`:

```go
e := &execProcess{
        id: r.ID, path: path,
        parent: p,                 // 指回 init:复用 runtime/平台/IO uid/gid
        spec:   spec,
        stdio: stdio.Stdio{Stdin: r.Stdin, Stdout: r.Stdout,
                           Stderr: r.Stderr, Terminal: r.Terminal},
        waitBlock: make(chan struct{}),
}
e.execState = &execCreatedState{p: e}
```

`execProcess`(exec.go:42-63)持 `parent *Init`;Start 走 `runc exec --detach`(exec.go:181-245,
Detach 205-208),所以 exec 进程是 **shim(runc 父)的子进程、init 的兄弟进程**,共享 init 的
namespaces/cgroup 但 spec 独立——这就是 exec 能换 argv/env 的原因。状态机从 created 起步
(init.go:425)。

### 3.4 shim 端 stdio 接线

`cmd/containerd-shim-runc-v2/process/io.go:84-132` 的 `createIO` 按 stdout URL 的 scheme 分派:
空 scheme 视为 `fifo`(100-102),支持 fifo/binary/binary-v2/file,其余报 "unknown STDIO scheme"
(125-126)。随后 `copyPipes`(io.go:134-)开协程把 runc 管道数据拷进 FIFO;TTY 走 console
socket + `CopyConsole`(exec.go:224-238);exec 的 stdin 由 shim 在 start 后非阻塞打开
(`openStdin`,exec.go:247-255,O_WRONLY|O_NONBLOCK)。

**注意**:仓内 runc-v2 shim 并不实现 streaming 服务(全仓无 `RegisterTTRPCStreamingService` 的
业务调用方;`core/runtime/v2/shim.go:265-274` 明说旧版 runc shim "does not support the streaming
IO API")。streaming 型 shim(shim version≥3 的 sandbox shim)是仓外实现(如 kata 类),它们在
shim 内复用同一套 streaming 服务代码:按 streaming_id 注册流,再把 exec 的 stdio 与流对接。

### 3.5 exec 输出到底走 FIFO 还是 streaming?

- **默认 FIFO**:`NewFifoExecIO`(internal/cri/io/exec_io.go:40-55)建真 FIFO(newFifos,
  helpers.go:79-92,`<state>/io/` 临时目录);
- **io_type=streaming 走 GRPC 流**,选路点 `internal/cri/server/container_execsync.go:176-181`:

```go
switch ociRuntime.IOType {
case config.IOTypeStreaming:
        execIO, err = cio.NewStreamExecIO(id, sb.Endpoint.Address, opts.tty, opts.stdin != nil)
default:
        execIO, err = cio.NewFifoExecIO(id, volatileRootDir, opts.tty, opts.stdin != nil)
}
```

ExecSync 全程建在其上(execsync:112-257):`task.Exec`(162-185)→ `process.Wait/Start`
(197-203)→ `execIO.Attach`(211-220)→ select 等 exit/timeout(229-256),收尾
`Delete + WithProcessKill`(189-195);输出上限 16MB 由 `cappedWriter` 截断(42-68,73)。

---

## 4. attach 专节:回流与多路复用

### 4.1 CRI Attach 的两段式

`internal/cri/server/container_attach.go:34-46`:Attach RPC 只校验并返回流地址
(`c.streamServer.GetAttach(r)`)。kubectl 连上 k8s streaming server 后回调 `attachContainer`
(48-87):载入 task、接 resize 通道,最后 `cntr.IO.Attach(ctx, opts)`(85),CloseStdin 回调即
`task.CloseIO(ctx, containerd.WithStdinCloser)`(80-82)。

### 4.2 ContainerIO.Attach:WriterGroup 多路复用

`internal/cri/io/container_io.go:164-232`:attach 不独占输出——stdout/stderr 进
`stdoutGroup/stderrGroup`(WriterGroup),日志管道(常驻)与 attach 客户端(临时)并存:启动时
`Pipe()`(133-160)把流拷进 WriterGroup(日志文件是常驻成员);每次 attach 用随机 key
`streamKey(id, "attach-"+key, …)` 加写者(166-169,219-230),断开 `Remove(key)` 防写者堆积
(207-211);StdinOnce 语义在 182-190(对齐 kubectl/docker 行为,注释 183-185)。

streaming 模式的容器 IO 用 `WithStreams` 构造(internal/cri/server/container_create.go:352-359,
restart 恢复同选路 restart.go:494):URL 由 sandbox 端点拼出;端点来自 sandbox controller 启动
返回的 Address(internal/cri/server/sandbox_run.go:332-337),存于
internal/cri/store/sandbox/sandbox.go:47-57。

### 4.3 "路径还是 URL"的分派桥

`internal/cri/io/helpers.go:168-184` 是两种通道的合流点:

```go
func openStdin(ctx context.Context, url string) (io.WriteCloser, error) {
        ok := strings.Contains(url, "://")
        if !ok {
                return openPipe(ctx, url, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_NONBLOCK, 0700)
        }
        return openStdinStream(ctx, url)
}
```

`openStream`(internal/cri/io/streaming.go:67-118)解析
`<ttrpc|grpc>+<unix|vsock|hvsock>://<addr>?streaming_id=<id>`(69),`shim.AnonReconnectDialer`
拨号(87)后 `proxy.NewStreamCreator(...).Create(ctx, id)`(96-97,109-110);再经
`ReadByteStream/WriteByteStream` 适配成 io.ReadCloser/WriteCloser(51-65)。于是 Attach 管线
完全不感知底层是 FIFO 还是 GRPC——这就是"FIFO 的桥接":**cio.FIFOSet 的三个字符串字段从
"文件路径"泛化成"可拨号地址"**。可吐槽细节:container_io.go:82-84 与 exec_io.go:63-65 的注释
示例写 `?stream_id=`,代码实际读写 `streaming_id`(helpers.go:82,99-105),写稿以代码为准。

### 4.4 daemon 重启后的重新 attach(attach 的另一义)

FIFO 是文件系统实体,daemon 重启后可按 State 返回的路径**重新打开**:`client/container.go:479-506`
loadTask → `attachExistingIO`(513-516,从 tasks.GetResponse 恢复 FIFOSet)→ `cio.NewAttach`
(pkg/cio/io.go:163-183,按需裁掉未给的流)→ `copyIO`(pkg/cio/io_unix.go:56-108)。C 报告的
主 stdio 直通同样靠这一招。streaming 流则靠"reconnection with the same streaming ID"约定
(container_io.go:87)。

---

## 5. 其他消费者:端口转发与 transfer

- **端口转发(CRI)**:`internal/cri/server/sandbox_portforward.go:30-40` 只返回流地址;实际转发
  在 sandbox_portforward_linux.go:32-81——`s.NetNS.Do` 进沙箱网络命名空间,对 `localhost:<port>`
  先试 IPv4 再试 IPv6(72-79),与 SPDY 流双向拷贝;不经 streaming 子系统。
- **CRI streaming server 本体**:k8s.io/cri-streaming 的 Server,装配于
  internal/cri/server/service.go:251,独立 HTTP 服务随 daemon 启停(351-356);TLS 配置
  internal/cri/config/streaming.go:62+;Exec/Attach/PortForward 回调在 streaming.go:76-109。
- **transfer(镜像推拉)是 daemon 内 streaming 服务的头号消费者**:client 侧
  client/transfer.go:38-39 构造 StreamCreator,流 ID 由 core/transfer/streaming/stream.go:207
  `GenerateID` 生成;transfer 服务持 StreamManager(plugins/services/transfer/service.go:60,81);
  对端凭 Any 里的 ID `sm.Get` 取流(import:core/transfer/archive/importer.go:105-114;registry
  认证流 AuthStream:core/transfer/registry/registry.go:359-361)。**这是"exec 也走 streaming"
  传言的源头**:streaming 是通用设施,但 exec/attach 是否用它由 `io_type` 决定,默认否。
- **docker exec 对照(简短)**:dockerd 经 libcontainerd 调 containerd 的 Exec,FIFO 由 dockerd
  侧 cio 创建,dockerd 持 FIFO 一端,经 HTTP hijacked 连接(SPDY/裸流 + stdcopy 分帧)泵给
  docker CLI;全程不用 containerd 的 streaming 服务;shim 侧与 3.3 的兄弟进程模型一致。

---

## 6. 设计动机:为什么主 stdio 走 FIFO,exec/attach 可能走 GRPC 流

1. **FIFO 的强项恰好匹配主 stdio 的需求形态**:流生命周期≈容器生命周期;FIFO 是文件系统对象,
   daemon 重启可重开(4.4),shim 持端写、client 持端读,零中间层零流控开销,阻塞即背压。
2. **exec/attach 是短生命周期的"会话"**,调用方往往就是发起连接的那一端——与 GRPC 流"随连接
   生死"的语义严丝合缝;FIFO 反而要额外约定目录、清理与权限。
3. **远程 sandbox 的硬需求**:`ttrpc+unix` 之外还有 `grpc+vsock|hvsock`(streaming.go:69,76-79)
   ——shim 跑在虚机里(kata 类)时宿主机上没有可 `open()` 的 FIFO,GRPC 流是唯一通道;
   streaming 让同一套 CRI io 代码覆盖本地与远程 shim。
4. **Any 消息 + typeurl 让一条流服务多种业务**,唯一耦合点是 StreamInit 的 ID(2.2);
5. **生命周期与容器解耦靠 lease**:流可登记到 lease,由 GC collectible resource 托底(2.3),
   业务断线不泄漏流,也不因容器活着而强留流。
6. **代价**:流控要自己做(WindowUpdate)、重连要业务自证 ID——这就是 `io_type` 默认仍是
   fifo 的原因(internal/cri/config/config.go:77-80,134-138,682-686)。

---

## FAQ 素材

1. **exec 的 stdout 走 streaming 还是 FIFO?** 默认 FIFO;仅当 runtime handler 配
   `io_type="streaming"` 且 shim 支持(version≥3)才走 GRPC 流。选路 container_execsync.go:176-181。
2. **streaming 服务里有 circular buffer 吗?** 没有。它是 Any 消息双向流;字节流适配层用 32KB
   `Data` 块 + `WindowUpdate` 滑窗(core/transfer/streaming/stream.go:35-36),接收端只留一块
   `remaining` 切片缓冲(reader.go:77-85)。
3. **为什么建流要先发 StreamInit 再等空 ack?** 服务端收到 StreamInit 才把流半边注册进 manager
   并回 ack(plugins/services/streaming/service.go:74-97);客户端 Create 等 ack(proxy/streaming.go:96-101),
   保证 Create 返回后对端 Get(id) 必命中。
4. **同一 streaming_id 能接几个消费者?** 一对一,重复 Register 返回 ErrAlreadyExists
   (manager.go:86-88);多播是上层的事(CRI 用 WriterGroup,container_io.go:236-249)。
5. **exec 进程和 init 进程什么关系?** 兄弟:都是 shim(runc)的子进程;`runc exec --detach`
   (exec.go:215),共享 init 的 cgroup/ns 但 spec 独立;`parent` 指回 init 复用其 IO uid 配置
   (init.go:412-424)。
6. **containerd daemon 重启,exec/attach 会断吗?** FIFO 模式不丢:loadTask 从 State 恢复 FIFO
   路径重新 attach(client/container.go:479-516);streaming 模式靠"同 ID 重连"约定
   (container_io.go:87),前提 shim 侧流对象还在。
7. **lease 在 streaming 里干什么?** 带 lease 的流不参与 GC Active 判定,生死由 lease 决定
   (manager.go:190-205);lease 释放时 GC Finish 统一 Close(manager.go:230-268)。
8. **容器日志和 attach 输出会互相抢流吗?** 不会:stdout 进 WriterGroup,日志写者常驻,每个
   attach 客户端加临时 key,断开即 Remove(container_io.go:219-230)。
9. **ExecSync 为什么输出截到 16MB?** GRPC 响应尺寸限制;`cappedWriter` 截断后调用方(如
   kubelet)拿不到被截断内容,container_execsync.go:42-68,72-73。
10. **`bash -c "sleep 365d &"` 为什么不拖死 ExecSync?** 子进程继承 stdio 写端撑住管道;
    `drainExecSyncIO` 超时后 `Delete + WithProcessKill` 释放 IO(execsync:290-340,注释含分析)。

## 深挖方向

1. **"路径即地址"的抽象反转**:cio.FIFOSet 的三个字符串从文件路径泛化为 URL(helpers.go:95-109),
   分派只靠 `strings.Contains(url, "://")`(168-184)——用最小改动复用整个上层 Attach 管线的
   教科书案例,可与 C 报告的主 stdio 直通对照成文。
2. **双层流控叠加**:WindowUpdate 应用层滑窗(reader.go:107-113)与 HTTP/2/ttrpc 自身流控、
   FIFO 阻塞背压的行为差异,可实测各通道吞吐与内存上界。
3. **shim 版本协商**:version≥3 被当作"sandbox API + streaming IO 能力"的代理指标
   (shim_manager.go:266-272),1.7→2.x 升级对旧 runc shim 的 Downgrade 兜底(shim.go:265-274)
   ——能力协商藏在版本号里的兼容性案例。
4. **GC 可回收资源抽象**:`RegisterCollectibleResource(metadata.ResourceStream)`(manager.go:52;
   core/metadata/gc.go:54-55)如何把进程内对象纳入 bolt lease/GC 体系,可与 content/lease 合并写。
5. **ttrpc 双向流实现**:streaming_ttrpc.pb.go:37-49 中 `ttrpc.Stream` 的
   StreamingClient/StreamingServer 标记,及 ttrpc(而非 grpc)选型对 shim 内存足迹的意义。

---

## 写作要点速查表

| # | 关键点 | 位置 |
|---|--------|------|
| 1 | streaming 协议:单 RPC 双向 Any 流 + StreamInit | api/services/streaming/v1/streaming.proto:25-31 |
| 2 | 服务端 Stream handler:注册→ack→挂起 | plugins/services/streaming/service.go:72-106 |
| 3 | 流管理器:ns/lease 双 map、Register/Get;lease 回收(Active 跳过 leased / Finish Close) | plugins/streaming/manager.go:58-65,67-105,190-205,230-268 |
| 4 | 客户端 Create:发 StreamInit、等 ack | core/streaming/proxy/streaming.go:75-106 |
| 5 | 字节流分帧:32KB Data + WindowUpdate 滑窗 | core/transfer/streaming/stream.go:35-36;reader.go:75-119 |
| 6 | client Exec:ioCreate 先建通道,地址进 RPC | client/task.go:443-489 |
| 7 | shim Exec 入口 / 真实化 execProcess(兄弟进程) | cmd/containerd-shim-runc-v2/task/service.go:385-405;process/init.go:404-427 |
| 8 | shim 端 stdio:scheme 分派 fifo/binary/file | cmd/containerd-shim-runc-v2/process/io.go:84-132 |
| 9 | exec 通道选路:Stream vs Fifo ExecIO | internal/cri/server/container_execsync.go:176-181 |
| 10 | URL/路径分派桥:Contains("://") | internal/cri/io/helpers.go:168-184(URL 生成 95-109) |
| 11 | 拨号 shim 端点建流:ttrpc/grpc + vsock | internal/cri/io/streaming.go:67-118 |
| 12 | attach 回流:WriterGroup 多路复用 | internal/cri/io/container_io.go:164-232(Pipe 133-160) |
| 13 | daemon 重启重连:FIFO 路径恢复 attach | client/container.go:479-516;pkg/cio/io.go:163-183 |
| 14 | io_type 配置与默认 fifo | internal/cri/config/config.go:77-80,134-138 |
| 15 | sandbox 端点来源与存储 | internal/cri/server/sandbox_run.go:332-337;store/sandbox/sandbox.go:47-57 |
| 16 | CRI streaming server 装配与回调 | internal/cri/server/service.go:251;server/streaming.go:76-109 |
| 17 | runc shim 不支持 streaming 的版本注记 | core/runtime/v2/shim.go:265-274;shim_manager.go:266-272 |

