# 第 18 章 · 镜像 push:与 pull 对称的另一半

> 基线:commit `f6132db`。行号以 core/remotes/、client/client.go、core/remotes/docker/pusher.go 为准。

## 18.0 全景:一次 push 的数据流

```
Client.Push(client.go:522)→ ref 加 @digest(:541-544)→ Resolver.Pusher(:546)
  → 信号量 limiter(:565-568)→ remotes.PushContent(:570)
PushContent(handlers.go:244-304)三阶段:
  第 1 轮:filterHandler 截留 manifest/index 并 ErrStopHandler(:250-263)
  第 2 轮:Dispatch 并行推 config+layers(:281)
  第 3 轮:推 manifests(:285)→ 第 4 轮:slices.Backward 逆序推 index、子先父后(:290)
单对象 push()(handlers.go:205-234):OpenWriter→ReaderAt(:226)→SectionReader+Copy(:232-233)
  pusher 返回 ErrAlreadyExists 即"免上传"视为成功(:217-223)
```

push 全程只读 store,不解包、无 lease(对照 pull client.go:508 的 lease 保护)。

## 18.1 dockerPusher:两段式上传与跨 repo mount

- **HEAD 预检**(:125)→ manifest 单请求 PUT(:186-192)→ blob 两段式:`POST blobs/uploads/` 拿 Location(:195,:264-296)→`PUT Location?digest=`,io.Pipe 喂 body、后台 goroutine 发请求(:318-343);Commit 校验 Docker-Content-Digest(:569-580);
- **chunked 未实现**(:316 TODO):失败整层重来,仅 ErrReset 管道复位重试(:422-441+content/helpers.go:193-215);
- **跨 repo mount**:POST 时附 `?mount=<digest>&from=<repo>`(pusher.go:202-203,:630-641),候选取自 pull 时打的 `containerd.io/distribution.source.<host>` label(docker/handler.go:34-77),selectRepositoryMountCandidate 选最长路径前缀(:109-137);201=已挂载记 MountedFrom 并返回 ErrAlreadyExists(pusher.go:245-257);私有源 401 自动去参数重发普通上传(:221-225)。纯 OCI 规范机制。

## 18.2 并发与状态

多层上传的并行度由 Dispatch limiter 控制(handlers.go:159-171,client.go:565-568 构造);**层依赖排序**:config→layers→manifests→index(:281/:285/:290);同 ref 并发 push 返回 ErrUnavailable(pusher.go:96-101)。状态跟踪:PushStatus{MountedFrom,Exists}(status.go:44-50);ctr 读 PushTracker 100ms 轮询(push.go:224-254);transfer 路径 progressPusher 回调(local/push.go:70-77)。

## 18.3 设计动机

1. **为什么 push 不需要 unpack**:上传的是"原始 blob"——与 pull 的"blob→解包→快照"对称,push 就是"快照→tar→blob"的逆操作;
2. **跨 repo mount 的节省**:同 registry 内已有 blob 时 POST mount 一句话免传 GB——OCI 规范的原生优化;
3. **ErrAlreadyExists 即成功**(:217-223):上游已有时跳过上传——幂等的 push 是 CI/CD 的安全重试基础;
4. **三阶段排序的因果**:config→layers→manifest→index,因为 registry 验证 manifest 时引用必须已存在——**因果序即推送序**。

## 18.4 FAQ

**Q1:push 时哪些层可以跳过?**
ErrAlreadyExists(:217-223)+跨 repo mount(:202-204):registry 已有的免传。

**Q2:为什么 push 不加 lease?**
只读 content store(:232-233),不解包不写快照——pull 的 lease 是防 GC 收走下载中的 blob,push 无此问题。

**Q3:push 失败会部分上传吗?**
会(blob 两段式 POST+PUT :264-296),但无断点续传(:316 TODO):下次重传整层。

**Q4:跨 repo mount 的条件?**
同 registry+同 digest+有 pull 权限(:630-641):401 时自动去参数降级。

**Q5:push 的并行度怎么控制?**
Dispatch limiter(:159-171):默认无限制,可配置。

**Q6:同 ref 并发 push 会怎样?**
第二个返回 ErrUnavailable(:96-101):pusher 有状态,不支持并发。

**Q7:push 进度怎么追踪?**
PushStatus(status.go:44-50)+PushTracker 100ms 轮询(push.go:224-254)。

**Q8:manifest 和 index 的推送顺序?**
config→layers→manifests→index(逆序 :290):因果序,registry 先验引用。

**Q9:push 的错误分类?**
ErrAlreadyExists=成功;ErrUnavailable=并发冲突(:96-101);4xx(非 401)=放弃;5xx/网络=重试。

**Q10:transfer 服务和旧 push 的选择?**
ctr push 默认 transfer(:97-137),--local 走旧管道(:139/:219);两条最终收敛 PushContent。

## 18.5 小结与深挖方向

本章结论:**push="三阶段因果排序+ErrAlreadyExists 幂等+跨 repo mount+双管道收敛"**。深挖:

1. chunked push(:316 TODO)的社区进展与 OCI 分片规范;
2. 跨 repo mount 的权限泄漏(私有源 401 降级 :221-225)的安全面;
3. Dispatch limiter(:159-171)的公平性在多租户 push;
4. ErrAlreadyExists 的 race(GC 后重传)与 CAS 语义;
5. transfer 与旧 push 的进度事件格式统一。

> 下一章:V8 卷三——Torque 深读与 code cache。
