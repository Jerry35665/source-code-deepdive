# R-镜像push：containerd 推送管道深读

> 调研对象：containerd 2.x 主干，commit `f6132dbe1f482cbe0aebc4bd3d8d7a184fb4a2aa`（2026-09-10）。
> 所有行号均为该 commit 下、仓库相对路径的实际核对结果。
> 姊妹篇：卷一 B 报告（pull 拉取管道）。本章讲对称的另一半——push。

---

## 1. 全景：一次 push 的数据流

containerd 的 push 是**纯 content store 出口**：镜像必须先以 blob 形式完整存在于本地
content store（commit、import、pull 都会写进去），push 只负责"从 store 读出来、发到 registry"。

```
ctr push / client.Push(ref, desc)
  │  client/client.go:522
  │
  ├─① ref += "@"+digest            client/client.go:541-544   (只按 digest 校验，tag 仅用于 PUT 路径)
  ├─② Resolver.Pusher(ref)          client/client.go:546
  │      └─► dockerPusher{dockerBase, object, tracker}
  │            core/remotes/docker/resolver.go:513-524
  ├─③ MaxConcurrentUploadedLayers>0 → semaphore  client/client.go:565-568
  │
  └─④ remotes.PushContent(pusher, desc, ContentStore, limiter, matcher, wrapper)
         client/client.go:570 → core/remotes/handlers.go:244

PushContent 三阶段编排（core/remotes/handlers.go:244-304）：
  第1轮 Dispatch(根desc)        :281  —— 推 config + 所有 layers（并行）
  第2轮 Dispatch(manifests...)  :285  —— 推每个 manifest（串行批次）
  第3轮 indexStack 反向遍历     :290  —— 子 index 先推、父 index 后推
       （注释：// parent always uploaded after child，:289）

单个对象的 push()（core/remotes/handlers.go:205-234）：
  pusher 侧 Writer/Push            ── 若 ErrAlreadyExists ⇒ 视为成功跳过 :217-223
  content store: provider.ReaderAt ── 从本地 store 读 blob      :226
  io.NewSectionReader(ra, 0, size)                            :232
  content.Copy(ctx, cw, rd, size, digest) ── 泵数据+Commit     :233

dockerPusher 侧的 HTTP 协议（core/remotes/docker/pusher.go）：
  HEAD  /v2/<repo>/blobs/<digest>            存在性预检      :125
  HEAD  /v2/<repo>/manifests/<tag|digest>    manifest 预检    :118-125
  POST  /v2/<repo>/blobs/uploads/            开启上传会话     :195
        [?mount=<digest>&from=<repo>]        跨 repo 挂载     :202-203,630-641
  ⇒ 201 Created ⇒ 已挂载，免上传                              :245-257
  PUT   <Location>?digest=<digest>    真正的数据 PUT（io.Pipe 喂 body）:297-302, 318-325
  PUT   /v2/<repo>/manifests/<tag|digest>    manifest 一次成文 :186-192
```

registry 侧的依赖约束（blob 先于 manifest、子 manifest 先于父 index）由三阶段次序天然保证；
而 config 与 layers 之间**没有**先后依赖，它们是同一轮 Dispatch 里的并行兄弟节点
（manifest 的 children 解析顺序是 `[Config] + Layers`，core/images/image.go:356，但 Dispatch 并发执行它们）。

---

## 2. pusher 专节：PUT blob 的 URL/token 与跨 repo mount

### 2.1 两个入口：Push 与 Writer

`dockerPusher` 同时实现 `remotes.Pusher` 和 `content.Ingester`（core/remotes/docker/pusher.go:41-47、49-74）：

- `Push(ctx, desc)`：直接路径，ref 由 `remotes.MakeRefKey` 生成（:72-74）；
- `Writer(ctx, opts...)`：Ingester 形态，供 `content.OpenWriter` 使用（:53-70），并能在同 ref
  正在上传时返回 `ErrUnavailable`（注释见 :49-52）。

### 2.2 token scope：push 权限怎么要

push 一开始就把 `repository:<repo>:pull,push` scope 注入 ctx（pusher.go:81 →
core/remotes/docker/scope.go:20-31、49-55），authorizer 据此向 token server 要令牌：

```go
// core/remotes/docker/scope.go:20-31
// When push is true, both pull and push are added to the scope.
s := "repository:" + strings.TrimPrefix(u.Path, "/") + ":pull"
if push {
    s += ",push"
}
```

### 2.3 状态预检与"已存在即成功"协议

每次 push 先查 tracker（pusher.go:91-105）：同 ref 已 committed ⇒ `ErrAlreadyExists`；
同 ref 正在上传（Writer 入口）⇒ `ErrUnavailable`（:96-101）。然后向 registry 发 HEAD 预检
（:125-133），HEAD 200 且 digest 匹配 ⇒ 记录 `Exists` 状态并以 `ErrAlreadyExists` 返回
（:140-164）。handler 层把这个错误**翻译成成功**（core/remotes/handlers.go:217-223）——
这就是"已有层跳过"的实现机制。

### 2.4 manifest 与 blob 的 PUT 路径

manifest 与 blob 在同一函数里分叉（pusher.go:118-123、186-192 vs 193-306）：

```go
// core/remotes/docker/pusher.go:118-123
if images.IsManifestType(desc.MediaType) || images.IsIndexType(desc.MediaType) {
    isManifest = true
    existCheck = getManifestPath(p.object, desc.Digest)   // manifests/<tag 或 digest>
} else {
    existCheck = []string{"blobs", desc.Digest.String()}
}
```

- manifest：单请求 `PUT /v2/<repo>/manifests/<tag|digest>`，`Content-Type` 即 mediaType（:186-192）。
  tag 的取舍见 `getManifestPath`（:348-365）：ref 带 `@digest` 且与 desc 一致才保留 tag 段。
- blob：两段式。先 `POST /v2/<repo>/blobs/uploads/` 拿会话（:195），从响应 `Location`
  解析上传 URL（:264-296，支持相对路径与跨 host——跨 host 时剥掉 authorizer，:284-295），
  再 `PUT <location>?digest=<digest>` 发数据（:297-302）。注释明确：
  `// TODO: Support chunked upload`（:316）——**2.x 尚无分块续传**，整 blob 一把 PUT。

数据供给用 `io.Pipe` 解耦：pushWriter 暴露给 content.Copy 写入，HTTP 请求在后台 goroutine
把 pipe 读出来当请求体（:318-325、327-343）。Commit 时等响应、校验
`Docker-Content-Digest` 头（:518-587，头校验在 :569-580）。

### 2.5 跨 repo mount：POST 阶段的 `?mount=&from=`

blob POST 时若发现可挂载来源，附加 OCI distribution 规范的挂载查询参数
（pusher.go:200-230，参数拼装 requestWithMountFrom :630-641）：

```go
// core/remotes/docker/pusher.go:202-204
if fromRepo := selectRepositoryMountCandidate(p.refspec, desc.Annotations); fromRepo != "" {
    preq := requestWithMountFrom(req, desc.Digest.String(), fromRepo)
    pctx := ContextWithAppendPullRepositoryScope(ctx, fromRepo)   // repository:<from>:pull
```

候选来源来自 content store 里 blob 的 `containerd.io/distribution.source.<host>` label
（该 label 在 pull 时由 `AppendDistributionSourceLabel` 打上，core/remotes/docker/handler.go:34-77；
常量定义 pkg/labels/labels.go:41），并在遍历继承链时由
`annotateDistributionSourceHandler` 传给子描述符（core/remotes/handlers.go:366-430）。
`selectRepositoryMountCandidate` 挑**路径前缀组件最长**的 repo（handler.go:109-137）。

registry 侧：201 Created ⇒ 已挂载，记 `MountedFrom` 并返回 `ErrAlreadyExists`（pusher.go:245-257）；
401（fromRepo 是私有仓库、token 拿到了但挂不动）⇒ 丢弃 mount 参数退回普通上传（:206-211 注释、221-225）。
注意：这套机制只是 OCI distribution 规范的标准跨仓挂载，源码中**不存在** FFDX 或任何
带外快传协议（全仓 grep 无命中）。

---

## 3. 并发专节：多层并行与依赖排序

### 3.1 三阶段流水线（核心排序设计）

`PushContent` 用 filterHandler 把镜像树"劈"成三类（core/remotes/handlers.go:250-263）：
manifest 进 `manifests` 数组、index 进 `indexStack`，并返回 `images.ErrStopHandler`
终止 handler 链（但**保留**前面 ChildrenHandler 产出的 children，core/images/handlers.go:64-84），
于是 pushHandler 在第一轮只推到 blob/config 叶子：

```go
// core/remotes/handlers.go:250-263（节选）
if images.IsManifestType(desc.MediaType) {
    manifests = append(manifests, desc)
    return nil, images.ErrStopHandler
} else if images.IsIndexType(desc.MediaType) {
    indexStack = append(indexStack, desc)
    return nil, images.ErrStopHandler
}
```

随后 :281 第一轮 Dispatch 推叶子（并行）、:285 第二轮推 manifests、:290 起用
`slices.Backward` 反向推 indexes（子先父后）。这保证了 registry 的引用完整性要求：
**config/layers ⇒ manifest ⇒ 父 index**。

### 3.2 并行度控制

并发单位是 Dispatch 的 sibling：`images.Dispatch` 用 errgroup 起 goroutine，limiter
非 nil 时先 `Acquire(1)`、handler 返回后 `Release(1)`（core/images/handlers.go:156-188，
acquire :159-163、release :169-171）。limiter 来自
`WithMaxConcurrentUploadedLayers`（client/client_opts.go:270-274），在 Push 里构造
（client/client.go:565-568）；不设即无限（transfer service 侧同样语义，
core/transfer/local/transfer.go:56-57、186-187）。同一 limiter 贯穿三轮 Dispatch。

### 3.3 pusher 侧的并发保护

多个 goroutine 同时推同一 blob 时：tracker 记录进行中状态，第二者从 Writer 入口拿到
`ErrUnavailable`（pusher.go:96-101），且 pusher 先对 ref 加锁（StatusTrackLocker，
pusher.go:77-80；锁实现 moby/locker，core/remotes/docker/status.go:95-101）。
`content.OpenWriter` 对 `ErrUnavailable` 做指数退避重试（16ms 起倍增至 2048ms，
core/content/helpers.go:149-182），把竞争者变成等待者。

---

## 4. 状态跟踪专节：进度从哪来

### 4.1 StatusTracker：pusher 内存账本

`dockerPusher.tracker` 是 `StatusTracker` 接口（core/remotes/docker/status.go:53-56），
默认实现是进程内 map（:65-93），`Status` 结构扩展了 content.Status（:29-50）：

```go
// core/remotes/docker/status.go:29-50（节选）
type Status struct {
    content.Status
    Committed  bool
    ErrClosed  error   // 关闭未完成 writer 的痕迹
    UploadUUID string
    PushStatus         // MountedFrom / Exists，:44-50
}
```

写路径实时刷新：pushWriter.Write 每写一段就 `status.Offset += n` 回写 tracker
（pusher.go:480-482）；开始时写 StartedAt/Total/Expected（:307-314）；Commit 校验
digest 后置 Committed（:582-584）。

### 4.2 CLI 进度：ctr 读 tracker 渲染

`ctr images push` 默认走 transfer service（cmd/ctr/commands/images/push.go:97-137，
`client.Transfer` 在 client/transfer.go:28）；`--local` 才回退到老管道（:139、219）。
老管道的进度方案：jobHandler 为每个遍历到的 desc 注册 job（:196-202），另一 goroutine
每 100ms 从 `commands.PushTracker`（即 `docker.NewInMemoryTracker()`，
cmd/ctr/commands/resolver.go:39-40）拉状态渲染（:224-254）：

```go
// cmd/ctr/commands/images/push.go:303-311（节选）
if status.Offset >= status.Total {
    if status.UploadUUID == "" {
        si.Status = content.StatusDone
    } else {
        si.Status = content.StatusCommitting
    }
} else {
    si.Status = content.StatusUploading
}
```

### 4.3 transfer service 进度：progressPusher 包装

daemon 侧 `localTransferService.push`（core/transfer/local/push.go:35-112）在
pusher 外包一层 `progressPusher`（:72-77、127-173）：WrapHandler 记 Add/Children（:139-146），
Push 遇 `ErrAlreadyExists` 记 `MarkExists`（:159-162），progressWriter 逐 Write 上报增量
（:245-253），最终经 `tops.Progress` 回调吐出 `transfer.Progress` 事件（:48-58、98-109），
由 gRPC streaming 推给 ctr 的 `ProgressHandler`。注意：progress 数据是**回调聚合**，
不是事件总线订阅；containerd 没有为 push 定义专门的事件 topic。

---

## 5. 设计动机

**为什么 push 不需要 unpack？** unpack 是 pull 方向的事：把 layer 展开进 snapshotter。
push 方向数据已经在 content store 里按 blob 就位（build/commit/import 的产物），
全程只用 `content.Provider.ReaderAt` 只读接口（core/content/content.go:48-60；
handlers.go:226），不触碰 snapshotter、不写 store，因此 `Client.Push` 也**不需要 lease**
（对照 pull 的 `c.WithLease`，client/client.go:508）——没有本地 ingest 就没有 GC 风险。

**跨 repo mount 省了什么？** Docker 构建链里常见 `repoA → tag 成 repoB 再 push`，
两 repo 的 layer 几乎全同。distribution.source label 让 pusher 得知 blob 首次来自哪个
同 host 仓库，`?mount=&from=` 让 registry 端做一次引用而非传输：客户端省上行带宽与时间，
registry 省存储。选最长公共前缀是为了贴近"确实是这个镜像派生"的直觉（handler.go:109-111）。

**push 与 pull 的对称性。** 两者共享同一套骨架：`ChildrenHandler` 解析镜像树 +
`Dispatch` 并发遍历 + `MakeRefKey` 生成 ref（handlers.go:80-114 两侧共用）+
`content.Copy` 泵数据。差异只在端点：pull 是 `FetchHandler→ingester`（远端→store），
push 是 `store→pusher`（store→远端）；pull 有 unpack/lease，push 有三阶段排序与
mount。理解了一侧，另一侧就是镜像翻转。

**`ErrAlreadyExists` 作为成功信号。** pull 与 push 都把"远端/store 已有"建模为错误
返回、在 handler 层吞掉（handlers.go:131-134 与 :217-223）。这让 Ingester/Pusher
接口保持"每次都开 writer"的单一语义，免上传的分支收敛在实现内部。

---

## 6. FAQ 素材与深挖

### FAQ 素材

1. **push 结束报 `content ... on remote: already exists` 却成功了？** pusher 用
   ErrAlreadyExists 表达"远端已有/已挂载"（pusher.go:163、257），handler 层翻译为成功
   （handlers.go:217-223）。这是特性不是 bug。
2. **push 前要保证什么？** 目标 manifest 及全部子对象必须已在本地 content store；
   push 只读 store，不会补拉缺失层。
3. **支持断点续传吗？** 单 blob 不支持：`// TODO: Support chunked upload`
   （pusher.go:316），失败整层重来；但 Copy 层有 `ErrReset` 管道重置后的自动重试
   （helpers.go:193-215 + pusher.go:422-441）。
4. **两个进程同时 push 同一镜像会怎样？** 同 ref 第二个 Writer 收到 `ErrUnavailable`
   （pusher.go:96-101），OpenWriter 指数退避等待（helpers.go:149-182）。
5. **跨 repo mount 何时触发、失败怎么办？** pull 时留下的 distribution.source label
   + 最长前缀匹配（handler.go:109-137）；私有源仓库 401 时自动去掉 mount 参数重发
   （pusher.go:221-225）。
6. **manifest PUT 到 tag 还是 digest？** ref 带 `@digest` 且与目标一致才保留 tag 段，
   否则落到 `manifests/<digest>`（pusher.go:348-365）。
7. **多架构镜像推送顺序？** blobs → 各 manifest → index 逆序（子先父后），
   handlers.go:281/285/290；顺序错会收到 400 并被翻译成"依赖缺失"提示（:293-298）。
8. **并发上传多少层？** `MaxConcurrentUploadedLayers`，0 表示不限（client.go:565-568）；
   它限制的是 Dispatch 并发 goroutine 数（core/images/handlers.go:159-171）。
9. **进度条数据从哪来？** `--local` 路径读内存 tracker（push.go:224-254）；
   默认 transfer 路径来自 progressPusher 的 Progress 回调（local/push.go:70-77）。
10. **Windows 基础镜像层会被推吗？** 默认跳过 non-distributable 媒体类型，
    除非显式 `--allow-non-distributable-blobs`（handlers.go:312-337、push.go:196-207）。

### 深挖

1. **ErrReset 管道复位协议**：HTTP 请求重来时 `replacePipe` 把旧 pipe 打上
   `content.ErrReset`、Offset 归零（pusher.go:422-441），content.Copy 的 for 循环捕获
   ErrReset 后 seek 回 offset 重泵（helpers.go:193-215）——理解 push 韧性的关键链路。
2. **digest 双重校验**：Commit 除比对期望 digest 外，还校验响应头
   `Docker-Content-Digest`（pusher.go:569-580）；无该头的 registry 只打日志放行（:578-580）。
3. **distribution.source label 的生命周期**：pull 时 `AppendDistributionSourceLabel`
   写入 content store label（docker/handler.go:34-77，注意 label 容量校验 :63-66）→
   push 时 `annotateDistributionSourceHandler` 沿镜像树继承给子 blob
   （core/remotes/handlers.go:366-430）→ `selectRepositoryMountCandidate` 消费。
4. **HEAD 403 的诊断增强**：HEAD 无响应体，pusher 会补一发 GET 同 URL 借用错误体，
   仅当 GET 也是 403 才采纳（withGETErrorBody，pusher.go:595-628）。
5. **两条 push 管道并存**：老 `client.Push`（进程内）与新 transfer service
   （daemon 内、gRPC 进度流）；ctr 默认后者，`--local` 回退前者（push.go:97/139），
   二者最终都收敛到 `remotes.PushContent`（local/push.go:95）。

---

## 写作要点速查表

| 主题 | 函数/结构 | 位置（仓库相对:行号） |
|---|---|---|
| push 入口 | `Client.Push` | client/client.go:522-571（limiter :565-568，PushContent :570） |
| ref 加 digest | ref 拼接 `@digest` | client/client.go:541-544 |
| Pusher 接口 | `remotes.Pusher` / `Resolver.Pusher` | core/remotes/resolver.go:83-88 / :50-54 |
| pusher 构造 | `dockerResolver.Pusher` | core/remotes/docker/resolver.go:513-524 |
| Ingester 形态 | `dockerPusher.Writer` | core/remotes/docker/pusher.go:53-70 |
| 并发锁+scope | `push`（Lock/RepositoryScope） | core/remotes/docker/pusher.go:76-84 |
| 存在性预检 | HEAD 请求 | core/remotes/docker/pusher.go:125-164 |
| manifest PUT | getManifestPath + PUT | core/remotes/docker/pusher.go:186-192、348-365 |
| blob 上传会话 | POST blobs/uploads/ + Location→PUT | core/remotes/docker/pusher.go:195、264-302 |
| 跨 repo mount | `?mount=&from=` + 401 回退 | core/remotes/docker/pusher.go:202-230、630-641 |
| mount 候选 | `selectRepositoryMountCandidate` | core/remotes/docker/handler.go:109-137 |
| 源 label | `AppendDistributionSourceLabel` | core/remotes/docker/handler.go:34-77 |
| push scope | `RepositoryScope`（pull,push） | core/remotes/docker/scope.go:20-31 |
| 推送编排 | `PushContent` 三阶段 | core/remotes/handlers.go:244-304（:281/:285/:290） |
| 单对象推送 | `push`（ReaderAt→Copy） | core/remotes/handlers.go:205-234 |
| 并发派发 | `images.Dispatch`（limiter） | core/images/handlers.go:156-188 |
| 树解析 | `Children`（config+layers） | core/images/image.go:337-381（:356） |
| 数据泵 | `content.Copy`（ErrReset 重试） | core/content/helpers.go:191-233 |
| writer 获取 | `OpenWriter`（退避重试） | core/content/helpers.go:149-182 |
| 写入器 | `pushWriter`（Write/Commit） | core/remotes/docker/pusher.go:443-484、518-587 |
| 状态账本 | `StatusTracker`/`PushStatus` | core/remotes/docker/status.go:29-101 |
| CLI 进度 | pushjobs.status | cmd/ctr/commands/images/push.go:285-317（tracker 来源 cmd/ctr/commands/resolver.go:39-40） |
| daemon 进度 | `progressPusher`/`progressWriter` | core/transfer/local/push.go:114-264（PushContent :95） |
