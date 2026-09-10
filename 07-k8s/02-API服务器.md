# 第 02 章 · API 服务器:声明式 API 的机制

> 基线:Kubernetes master,commit `517a94ff`(2026-09-04)。行号以 `staging/src/k8s.io/` 为根。

## 2.0 声明式 = 存储 + watch + 校验的三层咬合

"声明式"之所以成立,靠三个正交机制:

1. **统一对象模型**:`runtime.Object` 只有 `GetObjectKind()` 与 `DeepCopyObject()` 两个方法(interfaces.go:337-340);Scheme 维护 GVK→Go 类型的双向映射。**GVK 是逻辑类型,GVR 是 HTTP 路径**,经 RESTMapper 换算;所有外部版本 ⇄ `__internal` hub 的星型转换(installer.go:682)把 N 版本兼容从 N² 降为 2N;
2. **带乐观锁的存储**:resourceVersion(RV)直接等于 etcd 的 MVCC revision,写路径用 etcd 事务做 CAS;通用 `registry.Store` 把全部资源的 Create/Update/Get/Watch 骨架抽出(store.go:101-250),每种资源只注入 Strategy 与键函数;
3. **事件流**:List 拿快照 + RV,再 `watch?resourceVersion=X` 增量消费。**RV 一物两用:乐观锁令牌 + watch 游标**——整个声明式模型最关键的设计。

```
HTTP → DefaultBuildHandlerChain(认证/鉴权/APF/audit)
     → createHandler/updateHandler → 解码(GVK)+ 默认值 + mutating admission
     → registry.Store(通用骨架:校验、key、重试)
     → cacher/etcd3 store(编解码 + 加解密 + etcd Txn)
     → etcd(quorum 写,全局 revision+1)
     → watchCache 广播事件 → 所有 informer
```

## 2.1 一条 kubectl apply 的服务端旅程

**中间件链**(DefaultBuildHandlerChain,config.go:1036-1116)的顺序是艺术:认证在 tracing 之前(未认证流量不得影响采样);RequestInfo 靠内(GVR/verb 是鉴权/审计/APF 的共同输入);watch 属 long-running 豁免普通超时;**APF 排队在鉴权之前**——先排队后鉴权看似浪费,实则避免鉴权器被洪峰打垮。APF 的 work estimator 把"该资源的 watch 数与对象总数"折算成请求 seats,大 List 与新 watch 占更多席位。

**Update 的关键装配**(update.go):解码为 internal 版本 → `DefaultUpdatedObjectInfo(obj, transformers...)` 把 mutating admission 与 managedFields 更新**封装成延迟执行的 transformer**——拿到 existing 之后才触发 → 进入 Store.Update,把 validating admission 作为回调传入 → etcd CAS → 全局 revision+1,事件广播是响应之外的独立路径。

## 2.2 通用 registry:Create/Update 骨架

**Create**(store.go:545-626):填系统字段(仅 creationTimestamp 与 UID)→ generateName 冲突则换随机后缀重试(**把"分配唯一名"退化成"重试 CAS"**,与全系统"只有冲突重试、没有分布式锁"的哲学一致)→ `rest.BeforeCreate` 五步(断言系统字段、ns 一致、`strategy.PrepareForCreate` 默认值与 generation=1、`ValidateCreate` 转 422)→ validating admission → KeyFunc 落库。**策略校验是纯函数式的:不访问存储**——这是它区别于 admission 的根本特征。

**Update 的乐观锁核心**(store.go:825-835):

```go
if newResourceVersion == 0 {
    return nil, nil, apierrors.NewInvalid(qualifiedKind, name,
        field.ErrorList{field.Invalid(field.NewPath("metadata").Child("resourceVersion"),
            newResourceVersion, "must be specified for an update")})
}
if newResourceVersion != existingResourceVersion {
    return nil, nil, apierrors.NewConflict(qualifiedResource, name, fmt.Errorf(OptimisticLockErrorMsg))
}
```

每个用过 kubectl 的人都见过的 409 就出自这里。两个豁免:`AllowUnconditionalUpdate` 策略(如 Service)允许无 RV 覆盖;create-on-update(server-side apply)在 existing 不存在时走 Create。

**etcd 事务**已抽进 vendor 的 etcd client 封装(vendor/.../kubernetes/client.go:84-105):

```go
txn := k.KV.Txn(ctx).If(
    clientv3.Compare(clientv3.ModRevision(key), "=", expectedRevision),
).Then(
    clientv3.OpPut(key, string(value), clientv3.WithLease(opts.LeaseID)),
)
```

事务失败时 Else 分支把最新值带回——apiserver 无需再发 Get,直接进下一轮循环。字节级相同则短路返回(no-op 检测,不写 etcd)。

## 2.3 watch 与 resourceVersion

**RV 的七种语义**(全部有行号依据,报告 4.3 表):

| 场景 | 取值 | 含义 |
|---|---|---|
| watch RV="" | 从"当前状态"合成 ADDED 再增量 | etcd3/watcher.go:124-126 |
| watch RV="0" | 允许 watch cache 服务 | cacher.go:1313-1320 |
| watch RV=X | 精确续传;被 compaction 则 410 Gone | watcher.go:421-423 |
| list RV="" | quorum 读穿透 etcd | reflector.go:1120-1124 |
| list RV="0" | cache 优先(reflector 默认,防 etcd 热点) | reflector.go:1126-1130 |
| update body RV | 乐观锁 | store.go:833-835 |

**Cacher 就是 apiserver 内置的一个 informer**(cacher.go:441-447 直接用 client-go reflector 喂 watchCache)——单一 etcd watch 流经内存索引扇出给任意多 HTTP watcher,**etcd watch 数与客户端数解耦**;命中索引 trigger(如 spec.nodeName)时分发退化为索引直取,这是 Node 级大规模 watcher 的性能支点。bookmark 事件(只有 RV)推进客户端游标,配合 etcd progressNotify 与 WatchList 的 initial-events-end 标记。

## 2.4 admission 两层:为什么分立而不是一个拦截器

- mutating 在处理器层(update.go:169-190 包成 transformer);validating **被下推进 etcd 乐观重试循环内**(store.go:865-869)——**每次 RV 冲突重试都基于最新 existing 重跑校验,消除 TOCTOU**;
- 分立的原因:mutating 是"函数变换"天然幂等于乐观循环(重跑即可);validating 是"谓词",必须在提交前最后一刻对"真实的 existing + 变换后的 new"求值。**这是本子系统最值得借鉴的结构决策**;
- 代价:webhook 可能被多次调用(ReinvocationContext 显式管理);每个命中 webhook 都是一次完整 TLS 往返,mutating webhook 数量直接吃掉写延迟预算。

**finalizer 没有独立机制**:寄宿在 Update 骨架的条件分支上——"新对象无 finalizer、旧对象已标 deletionTimestamp 且 grace=0"时更新即触发删除(store.go:871-875)。

## 2.5 FAQ

**Q1:RV 到底是什么?**
etcd 全局 MVCC revision(单键维度即 ModRevision),全集群单调递增、不分资源;同时是乐观锁与 watch 游标。

**Q2:PUT 不带 RV 有时不报错?**
AllowUnconditionalUpdate 策略(如 Service)等价于"以最新为基线覆盖";多数资源报 must be specified。

**Q3:410 Gone 怎么来的?**
watch RV 已被 etcd compaction 回收;client-go 收到后放弃续传、下一次 relist 自动改用 RV="" 直读 etcd——**任何情况下不会用可能已不存在的 RV 无限重试**。

**Q4:Get 是强一致读吗?**
是,etcd3 Get 未启用 serializable(过 quorum);且校验不返回比客户端已知 RV 更旧的数据。

**Q5:apiserver 是 etcd 的代理队列吗?**
不是。它是一致性读缓存 + 事件扇出层,把读放大从 etcd 挪到 apiserver 内存。

## 2.6 小结与深挖方向

本章结论:**API 服务器 = "通用 Store 骨架 + 策略注入 + RV 一物两用 + admission 下推"**;它自身不编排任何业务,这就是任意 CRD 免费获得全部机制的原因。深挖:

1. WatchList 端到端一致性(initial-events-end bookmark 与 watch 建立的窗口);
2. no-op 短路与 generation 递增对 watch 事件的共同决定;
3. APF 对 watch 的 seats 量化;
4. cacher 历史窗口外慢消费者的终止策略;
5. etcd client 的 kubernetes.Client 封装重构动机。

> 下一章:控制器模式——Informer、工作队列与"控制循环"的通用骨架。
