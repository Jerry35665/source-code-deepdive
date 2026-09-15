# M - transfer 服务与 diff/apply:镜像搬运与层解包的深水区

> 调研对象:containerd 2.x 主干,commit `f6132db`(Merge PR #14090)。
> 本章合并《Docker 深读》卷三第 1-2 章。卷一 B 讲过 snapshotter/overlayfs 挂载,卷二 G 讲过 CRI PullImage,卷二 H 讲过 streaming 管道——transfer 是 streaming 的头号消费者,diff/apply 是 snapshotter 的头号生产者。所有行号以该 commit 为准。

---

## 1. 全景:transfer 异步框架

### 1.1 为什么需要一个独立的 transfer 服务

1.x 时代 pull 逻辑分散在 client 库(`client.Pull`)与 CRI 插件里,守护进程只是被动提供 content/snapshot 服务。2.x 把"搬运"抽成守护进程侧的服务:同一套 `Transfer(ctx, src, dst)` 接口可以表达 pull(Registry→ImageStore)、push(ImageStore→Registry)、import/export(tar 流→ImageStore)、tag(ImageStore→ImageStore)四种操作,并且进度以流式事件外发。CRI 侧 2.x 默认已切到 transfer(`internal/cri/server/images/image_pull.go:185-191`,`UseLocalImagePull` 为 true 时才回退 `client.Pull`)。

### 1.2 ASCII 全景:一次 transfer pull 的完整链路

```
client(如 CRI/ctr)                     containerd daemon
────────────────────                    ─────────────────────────────────────────────
transfer.NewStore(ref, WithUnpack)  \
registry.NewOCIRegistry(ref)         \  typeurl 序列化(any)
transfer.WithProgress(cb)            /
        │                            /
        ▼                           ▼
proxyTransferrer.Transfer ──gRPC──▶ plugins/services/transfer.service.Transfer
  core/transfer/proxy/                  │ convertAny: typeurl → Go 对象
  transfer.go:88-100                    │ (core/transfer/plugins/plugins.go:54)
  创建 progress stream,                 │ 遍历 transferrers 试跑
  传 stream id 给服务端      ◀─────────┘  (service.go:135-143)
        │                                  │
        │ streaming(独立 gRPC 流)          ▼
        │ ◀──── Progress 事件 ──── local.localTransferService.Transfer
        │                          = 矩阵分发 (local/transfer.go:68-100)
        │                                  │
        │                          pull(fetcher, storer)  local/pull.go:39
        │                                  │
        │                          ┌───────┴──────────────────────────┐
        │                          │ withLease: 24h 租约防 GC          │
        │                          │ resolver.Resolve: 拿 manifest     │
        │                          │ image verifier 检查              │
        │                          │ images.Dispatch(handler 链)      │
        │                          │   ├ fetchHandler → content store │
        │                          │   ├ unpacker.Unpack(h) 包装      │
        │                          │   │   └ goroutine: apply 每层    │
        │                          │   │      a.Apply → snapshotter   │
        │                          │   └ is.Store → image 元数据       │
        │                          └──────────────────────────────────┘
        │                                  │
        ▼                                  ▼
Progress{Event,Name,Parents,       ProgressTracker 300ms 轮询
Progress,Total,Desc}                content 状态 + 解包进度
(transfer.go:171-178)              (local/progress.go:95-256)
```

### 1.3 Job 生命周期与 08 章 streaming 的关系

transfer 没有显式的 "Job" 结构体:一次 `Transfer` RPC 就是一个 job,生命周期由调用方 context 控制("创建"=构造 src/dst 对象,"运行"=服务端 `Transfer` 返回即完成,是同步阻塞语义;"状态查询"=不是查询接口,而是进度事件持续推送)。这与 Docker daemon 的 layer download job 模型不同,是"无状态 RPC + 事件流"。

进度与 import/export 的字节流都走卷二 H 讲的 streaming 插件:

- 服务端要 streaming `manager` 插件才能启动:`plugins/services/transfer/service.go:75-82`(`ic.GetByID(plugins.StreamingPlugin, "manager")`);
- 进度流:客户端用 `streamCreator.Create` 建 stream( `core/transfer/proxy/transfer.go:94-100`),服务端用 `streamManager.Get` 取回并包装成 `ProgressFunc`(`service.go:93-124`);
- 字节流(import/export 的 tar 数据)在 `core/transfer/streaming/stream.go` 实现了滑动窗口流控:`maxRead = 32KB`、`windowSize = 2*maxRead`(`stream.go:35-36`),接收方每收一批发 `WindowUpdate`(`stream.go:150-165`),发送方按窗口配额读源(`stream.go:88-131`)。

managedStream 本身注册进 GC:streaming manager 实现 `ReferenceLabel`/`StartCollection`(`plugins/streaming/manager.go:124-135`),卷二 J 的 GC 体系因此能回收无人认领的流。

---

## 2. transfer 专节:接口、传输对象与进度事件

### 2.1 Transfer 接口:any + 能力接口的"矩阵"

核心接口只有一个方法,参数是 `any`(`core/transfer/transfer.go:31-33`):

```go
type Transferrer interface {
    Transfer(ctx context.Context, source any, destination any, opts ...Opt) error
}
```

真正的类型约束由一组小能力接口表达:`ImageResolver`(Resolve 出 name+desc,`transfer.go:35-37`)、`Fetcher`/`Pusher`(`transfer.go:84-90`)、`ImageStorer`(`transfer.go:100-102`)、`ImageGetter`/`ImageLookup`(`transfer.go:105-113`)、`ImageExporter`/`ImageImporter`(`transfer.go:116-123`)、`ImageImportStreamer`/`ImageExportStreamer`(`transfer.go:128-134`)、`ImageUnpacker`(`transfer.go:136-138`)。本地实现的组合矩阵在 `core/transfer/local/transfer.go:75-98`:

| source ↓ \ dest → | ImageStorer | ImagePusher | ImageExporter | ImageExportStreamer |
|---|---|---|---|---|
| ImageFetcher(Registry) | **pull** | - | - | - |
| ImageGetter(ImageStore) | tag | **push** | **export** | - |
| ImageImporter(tar 流) | **import** | - | - | echo(测试用回环) |

不匹配则返回 `ErrNotImplemented`,`plugins/services/transfer/service.go:135-143` 据此遍历所有已注册 Transferrer 尝试下一个——这是插件化的"责任链"。

### 2.2 两类传输对象:registry 侧与 image 侧

**Registry 源/目标**(`core/transfer/registry/registry.go`):`OCIRegistry` 同时实现 `ImageFetcher`(Resolve/Fetcher,`:214-228`)与 `ImagePusher`(Pusher,`:228`),内部包的是 1.x 就有的 `remotes` docker resolver;`NewOCIRegistry`(`:118`)接收 headers/凭据 helper/hostDir。**它同时实现了 `MarshalAny`/`UnmarshalAny`**——被序列化到 gRPC 请求里的只是"引用描述",真正的 resolver 在服务端重建(凭据不穿越客户端进程,这是 transfer 相对 client.Pull 的一个安全收益)。

**Image 目标/源**(`core/transfer/image/imagestore.go`):`Store` 结构携带imageName/labels/platforms/manifestLimit 以及 `unpacks []transfer.UnpackConfiguration`(`:46-58`)。三个关键方法:

- `Store()`(`:217`):pull 结束后把 manifest 写进 image metadata store,支持 `WithNamedPrefix`/`WithDigestRef`/`WithExtraReference` 多引用(`:124-164`);
- `UnpackPlatforms()`(`:383`):把 `WithUnpack(platform, snapshotter)`(`:167-174`)配置交回 pull 流程;
- `MarshalAny`/`UnmarshalAny`(`:392-420`):跨进程时把 unpack 配置一并序列化。

**tar 流对象**(`core/transfer/archive/`):`ImageImportStream.Import`(`importer.go:63`)把 OCI/Docker tar 解开写入 content store 并返回 index descriptor;`ImageExportStream.Export`(`exporter.go:90`)复用 `core/images/archive` 的 export 逻辑写多平台 tar。两者的"流"本体由 `ImageImportStreamer.ImportStream`(`io.Reader` + mediaType)提供——调用方通常是远端 stream 对象(`UnmarshalAny(ctx, streamGetter, ...)` 反解出流)。

### 2.3 pull 主流程(带行号)

`local/pull.go:39` 起,关键节点:

1. **租约**:`withLease`(`local/transfer.go:138-168`)无租约则创建,默认 24 小时过期(`:155-156`)——下载中途失败,已下载 blob 不会立刻被 GC;
2. **限流注入**:若 resolver 支持 `SetResolverOptions`,把服务端配置的并发数/下载信号量传下去(`pull.go:52-58`);
3. **Resolve**:拿到 name+manifest desc(`:60`);schema 1 直接拒绝(`:64-67`);
4. **image verifier**:遍历配置的验证器,`!jdg.OK` 即阻断 pull(`:70-93`)——这是 2.x 新增的镜像准入钩子;
5. **进度跟踪**:`NewProgressTracker(name, "downloading")` + goroutine 跑 `HandleProgress`(`:127-130`);
6. **handler 链组装**(`:183-188`):`fetchHandler`(下载 blob 入 content store,AlreadyExists 视为命中并 `MarkExists`,`:281-299`)+ children 层级跟踪 + `AppendDistributionSourceLabel`(记录 blob 来源仓库,支持 mirror 回退);
7. **unpack 注入**(`:192-234`):若 ImageStorer 带 unpack 配置,逐个与守护进程 `UnpackPlatforms` 白名单比对(`getSupportedPlatform`,`:303-332`,空 snapshotter 时优先默认),然后 `unpacker = unpack.NewUnpacker(...); handler = unpacker.Unpack(handler)`(`:228-232`);
8. **Dispatch**:`images.Dispatch(ctx, handler, nil, desc)` 广度遍历 manifest DAG(`:236`);**unpacker.Wait()** 等待后台解包完成(`:247-252`)——"先写 image 元数据"被推迟到解包之后;
9. **写 image 记录**:`is.Store(ctx, desc, ts.images)`(`:260`),发 "saved"/"Completed pull" 事件(`:265-276`)。

### 2.4 push 主流程

`local/push.go:35`:取 image(`ig.Get`,`:43`)→ `p.Pusher(ctx, img.Target)`(`:61`)→ `remotes.PushContent`(复用 1.x 推送器,传入上传信号量 `limiterU` 与平台匹配器,`:95`)。进度通过装饰器模式:`progressPusher` 包装 Pusher 与 handler(`:114-146`),`progressWriter.Write` 累加 offset(`:245-253`),Push 返回 AlreadyExists 时 `MarkExists`(跳过层,`:159-163`)。

### 2.5 进度事件:ProgressTracker 状态机

`transfer.Progress` 五字段(`transfer.go:171-178`,`Desc` 自 v2.0 新增,直接携带 OCI descriptor 免去客户端反查)。`ProgressTracker.HandleProgress`(`local/progress.go:95-256`)是单 goroutine 事件泵:300ms ticker(`:99`)轮询 content store 的 `ListStatuses`,把 job 状态机(added→inProgress→complete / extracting→extracted,状态常量 `:47-53`)翻译成事件:

- `waiting`:blob 进队列但还没轮到下载(`:197-204`);
- `downloading`/`uploading`:Offset/Total 从 `content.Status` 读出(`:110-125`);
- `already exists`:层命中(`:206-216`);
- `extracting`/`extracted`:来自 `ExtractProgress`(即 apply 的 `diff.WithProgress` 回调,pull.go:205 注入,`progress.go:299-311`)。

Parents 字段由 `AddChildren` 维护的 digest 父子图生成(`:287-297`),客户端因此能画出"manifest→config/layer"树状进度条。

---

## 3. diff/apply 专节:层差异的生成与解包

### 3.1 diff 抽象:Comparer 与 Applier

`core/diff/diff.go` 定义两个镜像对称的接口:

```go
// diff.go:57-64
type Comparer interface {
    Compare(ctx context.Context, lower, upper []mount.Mount, opts ...Opt) (ocispec.Descriptor, error)
}
// diff.go:80-87
type Applier interface {
    Apply(ctx context.Context, desc ocispec.Descriptor, mount []mount.Mount, opts ...ApplyOpt) (ocispec.Descriptor, error)
}
```

`Config` 支持自定义 MediaType/Compressor(`diff.go:30-51`)——`WithCompressor` 允许调用方换成任意压缩函数(如 zstd 或 nydus 的自定义格式),`WithSourceDateEpoch` 控制可重现性(`:152-162`,注释明确:自 v2.0 起 whiteout 时间戳固定为 0 而非 epoch)。`ApplyConfig` 有 `SyncFs`(apply 后 syncfs)与 `Progress` 回调(`:67-74`)。

### 3.2 walking diff:Compare 怎么算差异

唯一内置实现是 `plugins/diff/walking/differ.go`(插件 id "walking",`plugin/plugin.go:38-42` 装配,同时把 `NewFileSystemApplierWithMountManager` 装成 Applier,`:58-61`)。注释说得直白(`differ.go:48-53`):把 upper/lower 两组 mount 都挂起来并发遍历目录树,靠文件比对或存在性比对得出变化,不依赖任何文件系统特性——这就是"walking diff"名字的由来,也是 Docker `docker diff`/commit 的通用底座。

`Compare`(`differ.go:62-207`)流程:

1. 压缩决策(`:78-98`):未指定 MediaType 时默认 gzip;显式支持 uncompressed/gzip/zstd 三种,自定义 Compressor 必须同时给 MediaType;
2. 双侧临时挂载:`mount.WithTempMount(lower)` 套 `WithReadonlyTempMount(upper)`(`:101-102`,upper 只读挂载,避免 commit 过程污染);
3. 打开 content writer,`archive.WriteDiff` 输出 tar,经 `compression.CompressStream` 压缩,同时 `io.MultiWriter(compressed, dgstr.Hash())` 顺带算**未压缩** tar 的 sha256(`:137-160`)——这个 digest 存进 label `containerd.io/uncompressed`(`:160`,即 diffID 的来源);
4. `cw.Commit` 提交内容(`:172-178`),若 digest 已存在(AlreadyExists)视为成功;若 label 缺失则补写(`:186-193`)。

WriteDiff 的实体在 `pkg/archive/tar.go:79-95`:可插拔 `writeDiffFunc`,默认 `writeDiffNaive`(`:104-117`)——`continuity/fs.Changes` 做目录树 diff(产 add/modify/delete/unmodified 四类变化),`ChangeWriter` 把变化流翻译成 tar 流。

### 3.3 ChangeWriter:变化 → tar(含 whiteout 生成)

`pkg/archive/tar.go:518-525` 定义结构(含 `inodeSrc/inodeRefs` 硬链接映射)。`HandleChange`(`:557` 起)核心分支:

```go
// tar.go:561-575(删节)
if k == fs.ChangeKindDelete {
    whiteOutDir := filepath.Dir(p)
    whiteOutBase := filepath.Base(p)
    whiteOut := filepath.Join(whiteOutDir, whiteoutPrefix+whiteOutBase)
    // Since containerd v2.0, the whiteout timestamps are set to zero (1970-01-01)
    whiteOutT := time.Unix(0, 0).UTC()
    hdr := &tar.Header{Typeflag: tar.TypeReg, Name: whiteOut[1:], Size: 0,
        ModTime: whiteOutT, AccessTime: whiteOutT, ChangeTime: whiteOutT}
```

即"上层删除了下层文件" → 写一个 `dir/.wh.file` 零字节 regular 文件头。其余变化:`FileInfoHeaderNoLookups` 生成头(不带宿主机 uid/gid 名,`:598-599`);PAX 格式 + 时间截断到秒(`:607-611`);atime/ctime 清零(`:612-613`)保证跨层可重现;`security.capability` xattr 走 SCHILY PAX 记录(`:658-665`);socket 直接跳过(`:590-591`)。

### 3.4 apply:解包主流程(带行号)

`core/diff/apply/apply.go:62` 的 `fsApplier.Apply`:

1. `s.store.ReaderAt(ctx, desc)` 从 content store 读层 blob(`:82`);需要进度时包一层 `progressReader`(每 Read 报告已处理字节数,`:175-198`)——pull.go 的 `extracting` 事件就来自这里;
2. **处理器链**:`diff.NewProcessorChain(mediaType, r)` 起头,循环 `GetProcessor` 直到 `MediaType() == MediaTypeImageLayer`(`:94-105`)。链上每个节点把一种 mediaType 变换成下一种:`compressedHandler`(`core/diff/stream.go:91-113`)查 `images.DiffCompression` 后用 `compression.DecompressStream` 解压;外部二进制处理器(`BinaryHandler`,`stream.go:176-190`)支持如 OCICrypt 解密、erofs 转换——这就是"流式可扩展处理"设计;
3. **digest 校验位置**:`io.TeeReader(processor, digester.Hash())`(`:108-111`)——注意 digester 挂在**解压后**的明文流上,apply 结束时返回的 Descriptor 的 Digest 即 diffID(`:149-153`)。压缩层自身的 sha256 校验由 content store 在写入时完成,两层校验各司其职;
4. 若挂载点多于 1 且配置了 mount manager,先 `s.mount.Activate` 把 `{{mount N}}` 模板挂载真挂上再 apply(`:116-128`,2.x 新增,服务于 snapshotter 模板挂载);
5. 调包内 `apply(ctx, mounts, rc, config.SyncFs)`(`:130`);
6. `io.Copy(io.Discard, rc)` 读尽尾流(`:135-137`,防止压缩流未排干导致 digest 不对);检查处理器链上的 `Err()`(`:139-147`,如 gzip 的粘性错误)。

平台分派 `apply_linux.go:34-73`:单 overlay 挂载走快路径——解析 `upperdir=`/`lowerdir=` 选项(`getOverlayPath`,`:75-91`),直接对 upperdir 应用,whiteout 转换用 `archive.OverlayConvertWhiteout`(删文件时创建 overlay 合法的 mknod char 0:0 设备);user namespace 里 mknod 不可用,落到通用路径(`:39-41`,issue #3762)。其余一律 `mount.WithTempMount` 挂上再 `archive.Apply`(`:69-72`)。`SyncFs` 为真时 `unix.Syncfs`(`:93-105`)——CRI 的 `ImagePullWithSyncFs` 落在这。

### 3.5 whiteout 的应用侧处理

`pkg/archive/tar.go:141-158` 的 `Apply` → `applyNaive`(`:163-341`)。默认 `convertWhiteout`(`:179-227`):

- `dir/.wh..wh..opq`(opaque dir):把该目录下**本层未解包的**既有子项全部 RemoveAll(`:184-216`)——`unpackedPaths` map(`:171`)记录本轮已写的路径,避免把本层刚放进去的东西也删了(2.x 还加了 `opaqueDirs` 去重,`:174-188`);
- `dir/.wh.name`:直接 `os.RemoveAll(dir/name)`(`:218-223`)。

写入前的安全检查 `validateWhiteout`(`:809-830`)拒绝 `.wh..` 之类解析后逃出父目录的名字。解包主循环(`:229-328`)值得注意的细节:`filepath.Clean` 归一化名字(`:249`)+ `fs.RootPath` 限制在 root 内(`:266`,防路径穿越);目标已存在时"非目录即删,目录则合并元数据"(`:307-313`);目录 mtime 在全部条目写完后统一回设(`:324-337`,否则写文件会刷新目录时间)。

---

## 4. tar 层专节:头解析、OCI whiteout 规范与 hardlink

### 4.1 tar 头解析

容器层是标准 tar 流,解析靠标准库 `tar.Reader`(`applyNaive` 里 `tr.Next()`,`tar.go:237`)。写侧的头部工程在 `ChangeWriter`:`tarheader.FileInfoHeaderNoLookups`(`:599`)避开 passwd/group 查表;`setHeaderForSpecialDevice`(`tar_unix.go:42`)回填设备号;`chmodTarEntry` 处理 setuid 位映射(`tar_unix.go:38`)。读侧 `createTarFile`(`tar.go:343-446`)按 Typeflag 分派:TypeDir 合并(`:350-357`)、TypeReg 写内容(`:360-372`)、块/字符设备与 FIFO 走平台特化(`:374-384`,`handleTarTypeBlockCharFifo`)、符号链接 `os.Symlink`(`:396-399`)、PAX Global Header 忽略并记日志(`:401-403`)。写完文件后的顺序有讲究:Lchown(`:409-417`,userns 中 subuid 不足会给出提示)→ SCHILY.xattr PAX 记录逐个 setxattr(`:419-438`,`user.*` 命名空间在非普通文件上 EPERM 则降级为警告)→ lchmod(`:441`,必须在 chown 后,因为 chown 可能清 suid)→ chtimes(`:445`)。

### 4.2 .wh. 语义与 OCI 规范

常量定义(`tar.go:119-137`):

```go
whiteoutPrefix     = ".wh."                        // 删除下层文件
whiteoutMetaPrefix = whiteoutPrefix + whiteoutPrefix // ".wh." 前缀的元标记
whiteoutOpaqueDir  = whiteoutMetaPrefix + ".opq"   // 不透明目录
```

注释直接引用 OCI image-spec layer.md。历史:这套标记源自 AUFS 的 whiteout 惯例(Docker 时代继承,`tar.go:54` "This style is based off AUFS whiteouts"),OCI 规范将其标准化:删除=零字节 `.wh.<name>` 文件,opaque=`.wh..wh..opq` 目录标记。而 overlayfs 内核态用的是另一套(char 0:0 设备 + trusted.overlay.opaque xattr),两种表示法的转换点就在 apply:读侧 `convertWhiteout` 把 `.wh.` 翻译成 RemoveAll;写侧(对 overlay upperdir 打 diff 时)`OverlayConvertWhiteout`(`tar_opts_linux.go`)把 upperdir 里出现的 char 0:0 设备翻译回 `.wh.` 文件。卷一 B 讲的"overlayfs 挂载靠白名单 xattr"在这里闭环:containerd 选择在用户态搬运 whiteout 语义,layer 格式因此与具体快照器解耦。

### 4.3 hardlink 处理

tar 的 hardlink 是"引用流内另一路径"。写侧:ChangeWriter 用 inode→名字映射(`inodeSrc`)记录首个出现的路径,后续同 inode 文件写成 `TypeLink` 指向它(`tar.go:637-652`);若 hardlink 目标是**未变化的**文件(`ChangeKindUnmodified`),先挂起引用(`inodeRefs`),等首本体出现时补写(`:645-651`)。读侧 `createTarFile` 的 `tar.TypeLink` 分支(`:386-394`)调 `hardlinkRootPath`(`:795-807`)把 linkname 限制在 root 内(symlink 穿越防护),再 `link()`;注释特别说明允许"硬链接指向软链接"——链接到软链接本身而非其目标(`:788-794` 的示例)。父目录缺失时 `includeParents` 自动补写父目录条目(`:718`)。

---

## 5. 衔接专节:apply → snapshotter Prepare → Mount 列表

unpack 调度器 `core/unpack/unpacker.go`(由 pull 的 `unpacker.Unpack(handler)` 注入 handler 链)是 transfer 与快照器的焊点:

- **调度模型**(`unpacker.go:205-324`):handler 遇到 manifest 时把 layers 挂到 config digest 下排队(`:276-283`);遇到 config 时才启动 goroutine 真正 unpack(`:311-315`)——因为 diffID 列表在 image config 的 rootfs 里,必须先拿到 config。共享同一 config 的多个 manifest(压缩变体)只解一次包(`:289-309`);
- **延迟取层**:层下载被推迟到 apply 前(`startFetch`,`:591`),快照已存在(chainID 命中)的层干脆不取(`fetchOnly` 分支,`:397-400`)——省流量的关键设计;
- **Prepare**(`:494-520`):对第 i 层,`parent = chainIDs[i-1]`(chainID 由 diffIDs 逐层哈希,`:447-450`),`sn.Prepare(ctx, "extract-<unique> <chainID>", parent, WithLabels(...))` 拿到 active 快照的 Mount 列表;AlreadyExists 时 Stat chainID 判断是否可直接跳过;失败清理 `sn.Remove`(`abort`,`:530-534`);
- **标签**:`containerd.io/snapshot.ref`(GC 保护)、`containerd.io/snapshot/diff`(diffID)、`containerd.io/snapshot/parent-chain-id`(`:474-482`)——后者是 2.x 并行解包的依赖记录;
- **Apply**:第 i 层 `a.Apply(ctx, desc, mounts, ApplyOpts...)`(`:634`)——即第 3 节的 fsApplier,mounts 正是 Prepare 返回的(active 快照,overlay 类型时是 upperdir 挂载);
- **校验闭环**:apply 返回的 diff digest 与 config 里的 diffID 比对(`:642-647`),不符则 abort 快照;通过后 `sn.Commit(ctx, chainID, key)` 把 active 转为 committed(`:549`),并给 config blob 打 `containerd.io/gc.ref.snapshot.<sn>=<chainID>` 标签(`:741-754`)——卷一 B 的"GC 引用链"与卷二 J 的 GC 由此贯通;
- **并行解包**:`supportParallel`(`:855-864`)要求快照器声明 `Rebase` 能力;并行时各层 Prepare 不带 parent(拿 bind mount),apply 前把 overlayfs 返回的 bind mount 重写为 overlay 挂载以保证 whiteout 转换正确(`bindToOverlay`,`:892-910`,issue #13030 的临时方案),commit 时再按序 rebase 回真 parent(`:546-548`)。2.x 还引入 `isStaged`:若 Prepare 返回的最后一个挂载是只读的(快照器直接把层内容预置进了 active 快照,如内容缓存型快照器),整个 apply 可跳过(`:885-890`,消费于 `:522-527`)。

一句话串联全链路:**transfer.pull → images.Dispatch → unpacker → sn.Prepare(active) → diff.Applier.Apply(tar 流→文件系统操作)→ sn.Commit(chainID) → gc.ref**——这就是"镜像变成容器 rootfs"的全部机关。

---

## 6. 设计动机

**为什么 transfer 独立成服务?** (a) *异步与进度*:1.x 的 pull 是客户端库函数,Docker/k8s 场景下拉镜像的调用方(如 kubelet)与守护进程之间只有一个同步 RPC;transfer 把进度做成流式事件,客户端无需轮询 content store。(b) *可恢复/防 GC*:租约由服务端持有(24h),网络断开不丢已下载内容;DuplicationSuppressor(`plugins/transfer/plugin.go:105`,`kmutex`)按 blob digest 和 chainID 去重并发 pull,两个 Pod 同时拉同一镜像只下载/解包一次。(c) *多用途*:一个接口四种操作,import/export 也吃同一套进度与流控;CRI 切换后凭据留在服务端,客户端只见引用。(d) *插件化*:service 层遍历多个 Transferrer(`service.go:135-143`),未来可插 P2P、镜像中心代理等实现——typeurl 注册表(`core/transfer/plugins/plugins.go:33-68`)允许任意进程用 gRPC 描述"从什么到什么"。并发去重器 kmutex 在插件装配时注入(`plugins/transfer/plugin.go:97`)。

**为什么 diff 抽象成接口?** Compare/Apply 两侧各有真实变体:Compare 除 walking 外,Windows 有 lcow/windows 专用实现,erofs 有 `contrib` 侧实现;Apply 除 fsApplier 外,还可指向外部二进制处理器(解密、转码)。daemon 层不关心 tar 细节,只约定"desc 进、desc 出",压缩格式/加密都退化为流处理器链上的节点(`core/diff/stream.go:44-59` 的注册表 + `BinaryHandler`)。walking diff 走"通用但慢"的挂载遍历路线,正是为了不绑定文件系统——快照器可以继续换。

**whiteout 的历史?** AUFS 是 Docker 第一代存储驱动,`.wh.` 前缀文件是它向用户态暴露删除语义的方式;Docker→OCI 标准化时保留了这套表示(改名为 "whiteouts" 写进 layer.md),overlayfs 则用内核原生机制(char 0:0 + xattr)。containerd 的 archive 包是两套世界的翻译层:`convertWhiteout` 选项(`tar_opts.go:43,59`)把转换策略做成注入点——目录场景用 RemoveAll,overlay 场景用 OverlayConvertWhiteout 生成设备文件,从而让同一份 tar 层能落到任何快照器。v2.0 把 whiteout 文件时间戳钉死为 Unix 零点(`tar.go:108-109,565-567`),diffID 从此与构建时间无关,可重现构建(至层级别)成立。

---

## 7. FAQ 素材

1. **Q: transfer 的 Transfer RPC 是异步的吗?** A: 调用语义上是同步的(返回即全部完成,含解包,pull.go:247-252 显式 Wait);"异步"体现在进度通过独立 streaming 推送,且层下载/解包在服务端并行进行。没有 job 列表/查询接口——job 生命周期=一次 RPC。
2. **Q: 2.x 里 kubelet 的 pull 到底走哪条路?** A: 默认 transfer service(`internal/cri/server/images/image_pull.go:190`),配置 `UseLocalImagePull=true` 才回退 `client.Pull`(`:188-191`);transfer 路径尚不支持 DisableSnapshotAnnotations 等 CRI 选项(同文件 `:180-182` 注释)。
3. **Q: 进度条里的 "waiting" 和 "downloading" 分别是什么?** A: waiting=已发现未轮到(progress.go:197-204);downloading=content store 的 Status.Offset 在涨(:110-125);extracting=apply 正在写文件系统(:143-164)。
4. **Q: 为什么解压后的 digest 比对发生在 apply 而不是下载时?** A: 下载时 content store 校验的是压缩 blob 的 sha256(manifest 里的 digest);apply 时 TeeReader 算的是解压明文的 diffID,与 config.rootfs.diffIDs 比对(unpacker.go:642-647)。两个校验对象不同,缺一不可。
5. **Q: .wh. 文件会留在容器 rootfs 里吗?** A: 不会。apply 时 convertWhiteout 把它翻译成 RemoveAll 后直接跳过写入(tar.go:296-302),文件系统里只有"删除"这个效果,没有 .wh. 实体。
6. **Q: opaque 目录(.wh..wh..opq)和逐文件 whiteout 有什么区别?** A: opaque 声明"整个目录与下层断开",apply 时删除目录下所有非本层文件(tar.go:184-216);逐文件只删单个目标(:218-223)。
7. **Q: 并发 pull 同一镜像会重复下载吗?** A: 下载层靠 content store 的 AlreadyExists + DuplicationSuppressor(kmutex 按 digest 锁)去重;解包靠 chainID 锁(unpacker.go:825-834)。两层防重。
8. **Q: 为什么 unpack 前必须先拿到 config?** A: 层的 chainID 由 diffIDs 推导,而 diffIDs 在 config JSON 里;unpacker 把 manifest 的 layers 挂到 config digest 下排队,见 config 才调度(unpacker.go:205-324)。
9. **Q: gzip 和 zstd 层怎么区分?** A: 读头部魔数:1f 8b 08 = gzip,28 b5 2f fd(及 skippable frame)= zstd(compression.go:140-185);DecompressStream 先 Peek 10 字节再分派(:188-201)。mediaType 只是提示,魔数才是事实。
10. **Q: walking diff 为什么要把 upper 挂成只读?** A: Compare 遍历两个目录树做比对,upper 若可写,遍历过程可能改变 mtime 等,污染 diff 结果(differ.go:101-102 WithReadonlyTempMount)。

## 深挖线索

1. **并行解包与 Rebase 能力**:snapshotter 声明 `RebaseCap` 后,层 Prepare 无 parent、apply 用 bind→overlay 重写、commit 时 rebase(unpacker.go:546-548, 630-632, 855-864);issue #13053 是正式方案,#13030 是动机。
2. **staged snapshot**:Prepare 返回只读挂载=快照器已预置内容(如 SOFU/内容缓存快照器),apply 整体跳过但仍走 commit 与父链(unpacker.go:522-527, 576-589, 885-890)。
3. **流处理器的进程外扩展**:`BinaryHandler` 允许把某一 mediaType 的变换交给外部二进制(传 payload 如解密密钥),OCICrypt/nydus/erofs 由此接入而无需改 core(core/diff/stream.go:176-190;注册见 `core/diff/stream_unix.go` 的 init)。
4. **transfer 的类型路由**:typeurl TypeURL→reflect 构造对象(core/transfer/plugins/plugins.go:33-68),带流的类型实现 `streamUnmarshaler` 由 streamManager 反解(service.go:154-161)——跨进程对象模型的完整拼图。
5. **import 的 verifier 位置**:pull 有 image verifier 把关(:70-93),import 流程的 TODO(`local/transfer.go:95` "verify imports with ImageVerifiers?")说明准入检查尚未覆盖 docker load 场景——安全审计的好抓手。

---

## 写作要点速查表

| # | 内容 | 位置(仓库相对路径:行号) |
|---|---|---|
| 1 | Transferrer 接口(any 进 any 出) | core/transfer/transfer.go:31-33 |
| 2 | Progress 事件结构(Desc 为 v2.0 新增) | core/transfer/transfer.go:171-178 |
| 3 | 源/目标组合矩阵(pull/push/tag/import/export/echo) | core/transfer/local/transfer.go:68-100 |
| 4 | withLease:24h 租约防 GC | core/transfer/local/transfer.go:138-168 |
| 5 | transfer GRPC 服务:进度流绑定 + transferrer 责任链 | plugins/services/transfer/service.go:90-143 |
| 6 | streaming manager 依赖注入 | plugins/services/transfer/service.go:75-82 |
| 7 | local transfer 插件装配(kmutex 去重器) | plugins/transfer/plugin.go:41-108(:97) |
| 8 | pull 主流程(verifier/handler 链/unpacker 注入) | core/transfer/local/pull.go:39,70-93,183-234 |
| 9 | schema1 显式拒绝 | core/transfer/local/pull.go:64-67 |
| 10 | 进度状态机(300ms 轮询,waiting/complete/extracting) | core/transfer/local/progress.go:95-256 |
| 11 | tar 流滑窗流控(32KB/64KB 窗口) | core/transfer/streaming/stream.go:35-36,45-205 |
| 12 | CRI 默认走 transfer(UseLocalImagePull 回退) | internal/cri/server/images/image_pull.go:185-191,304-356 |
| 13 | Comparer/Applier 接口定义 | core/diff/diff.go:57-64,80-87 |
| 14 | walking diff:双挂载+遍历,diffID label | plugins/diff/walking/differ.go:62-207(151-160) |
| 15 | diff 插件装配(walking + fsApplier) | plugins/diff/walking/plugin/plugin.go:38-61 |
| 16 | apply 主流程:处理器链+TeeReader 校验 diffID | core/diff/apply/apply.go:62-154(94-111) |
| 17 | overlay 快路径与 OverlayConvertWhiteout | core/diff/apply/apply_linux.go:34-73 |
| 18 | whiteout 常量与默认转换(.wh./.wh..wh..opq) | pkg/archive/tar.go:119-137,179-227 |
| 19 | applyNaive 主循环(路径清洗/目录 mtime 回设) | pkg/archive/tar.go:229-338 |
| 20 | ChangeWriter 生成 .wh. 头(epoch0 时间戳) | pkg/archive/tar.go:557-581(565-575) |
| 21 | 解压魔数探测 gzip/zstd | pkg/archive/compression/compression.go:140-242 |
| 22 | unpacker:Prepare→Apply→Commit→gc.ref | core/unpack/unpacker.go:494-520,634-647,741-754 |
