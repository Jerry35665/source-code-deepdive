# 第 13 章 · transfer 与 diff:镜像的异步搬运与层的落地

> 基线:commit `f6132db`。行号以 core/transfer/、core/diff/、pkg/archive/ 为准。卷二 H 章说"transfer 是 streaming 头号消费者"——本章展开 transfer 框架本体与层落地的另一半 diff/apply。

## 13.0 全景:Transfer 的极简接口

```go
/* core/transfer/transfer.go:31-33 —— 整个框架只有一个方法 */
type Transferrer interface {
    Transfer(ctx context.Context, src any, dst any, opts ...TransferOpts) error
}
```

**类型约束靠一组能力接口**(ImageFetcher/ImageStorer/ImageGetter/ImagePusher/ImageImporter/ImageExporter,:35-138);本地实现按 src/dst 组合**矩阵分派 6 条路径**:pull/push/tag/import/export/echo(core/transfer/local/transfer.go:68-100);GRPC 门面遍历所有 transferrer 责任链式尝试(plugins/services/transfer/service.go:135-143)。**同步语义**:一次 Transfer RPC 即一个 job(返回即含解包完成,pull.go:247-252 显式 Wait);"异步"体现在进度走独立 streaming 事件流(300ms 轮询泵,progress.go:95-256);import/export 字节流走 32KB/64KB 滑窗流控(:35-36)。CRI 2.x 默认已切 transfer 拉镜像(internal/cri/server/images/image_pull.go:185-191),**凭据留在服务端**。

## 13.1 diff/apply:对称接口与 walking diff

Comparer.Compare / Applier.Apply 对称接口(core/diff/diff.go:57-64,:80-87)。**walking diff**:上下两层挂载后并发遍历目录树比对(differ.go:48-53,:101-102),输出 tar 经 gzip/zstd 压缩,**MultiWriter 同时产压缩层与 diffID**——未压缩 digest 存入 `containerd.io/uncompressed` label(:151-160)。

**Apply 流程**(apply.go:94-105):content ReaderAt→流处理器链(解压/解密,循环识别 MediaTypeImageLayer)→TeeReader 在解压明文上算 digest(diffID 闭环 :108-111)→单 overlay 挂载走 **upperdir 快路径**+OverlayConvertWhiteout,否则 WithTempMount 通用路径(apply_linux.go:34-73)。

**whiteout 语义**(pkg/archive/tar.go:119-137,:557-581):overlay 的 `.wh.` 文件与 `.wh..wh..opq` 不透明目录标记在 tar 流中的编解码;v2.0 起时间戳钉死 epoch0(可复现构建)。

## 13.2 unpacker:两套子系统的焊点

unpacker(core/unpack/unpacker.go:494-520)是 transfer 与 snapshotter 的焊点:`sn.Prepare(extract-key, parent=chainID)` 拿 active 快照 Mount 列表→a.Apply→**diffID 校验**→sn.Commit→打 gc.ref.snapshot label(:634-647,:741-754);支持 Rebase 能力并行解包与 staged 快照跳过 apply——卷一 B 章"chainID 去重"的执行端。

## 13.3 设计动机

1. **为什么 Transfer 只有一个方法**:src/dst 的类型组合(6+ 种)如果各写一个 API,组合爆炸;单方法+能力接口让"新增一种目的地"=实现一个接口,分派矩阵集中管理(:68-100);
2. **同步返回+异步进度**:解包完成的语义放进返回值(调用方拿到的引用必然可用),进度从副作用通道走——**正确性同步,体验异步**;
3. **diffID 双写**:压缩层给网络/存储,未压缩 digest 给校验——一次遍历两个产物(MultiWriter);
4. **upperdir 快路径**:单 overlay 时免临时挂载,直接写 upperdir——为最常见的 pull-unpack 场景开专用道。

## 13.4 FAQ

**Q1:transfer 和卷二 streaming 什么关系?**
transfer 的进度事件与 import/export 字节流跑在 streaming 服务上(:75-82 强依赖 streaming manager)。

**Q2:CRI 拉镜像走哪条?**
2.x 默认 transfer(:185-191),凭据留服务端;UseLocalImagePull 才回退 client.Pull。

**Q3:diffID 和 digest 差在哪?**
digest=压缩层哈希(网络/存储身份),diffID=解压后哈希(层语义身份)——两者由 MultiWriter 一次遍历同时产出(:151-160)。

**Q4:whiteout 的 .wh. 文件最终在哪?**
apply 时翻译成快照文件系统的删除动作(:34-73),tar 流里只是标记。

**Q5:apply 为什么区分单 overlay 与通用路径?**
(:34-73):单 overlay 可直写 upperdir 免双层挂载;通用路径兼容任意 snapshotter。

**Q6:解包的并发安全?**
extract-key 的 Prepare 三次重试,AlreadyExists 即跳过(:494-520)——卷一 B 章 chainID 去重的落地。

**Q7:tar 的时间戳为什么钉 epoch0?**
(:557-581):层可复现(同输入同 digest)——构建可复现性。

**Q8:hardlink 在层里怎么处理?**
tar 头的 linkname 引用:apply 按 tar 顺序重放链接关系。

**Q9:加密层怎么解?**
流处理器链里的 decrypt 环节(:94-105):PGP/CENC 等 containerd 加密扩展。

**Q10:echo 路径是干什么的?**
(:68-100 的组合矩阵):调试用自环——框架完备性的自检通道。

## 13.5 小结与深挖方向

本章结论:**transfer="单方法+能力接口+组合矩阵";diff="对称接口+MultiWriter 双产物+快路径分流"**。深挖:

1. 进度泵 300ms 轮询(:95-256)在高频层事件的延迟;
2. 组合矩阵新增"OCI artifact 直接传输"的扩展位;
3. walking diff 并发遍历(:101-102)的文件系统热点;
4. whiteout 与卷一 overlayfs upperdir 的等价性证明;
5. Rebase 并行解包(:634-647)在多架构 pull 的收益。

> 下一章:seccomp notify 与 console——syscall 裁决与终端控制权。
