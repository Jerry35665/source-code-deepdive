# A 篇 · API 服务器:声明式 API 的机制

> 仓库:kubernetes @ 517a94ff(2026-09-04,master)
> 核心路径:`staging/src/k8s.io/apiserver/`、`staging/src/k8s.io/apimachinery/`、`staging/src/k8s.io/client-go/`
> 所有结论均标注 `文件:行号`(相对 `staging/src/k8s.io/`)。

## ① 全景:声明式 API = 存储 + watch + 校验的分层

Kubernetes 的"声明式"之所以成立,靠的是三个正交的机制互相咬合,而不是某个单点设计:

1. **统一的对象模型与编解码(apimachinery/runtime)**。任何 API 对象都实现 `runtime.Object` 接口(仅两个方法:`GetObjectKind()` 与 `DeepCopyObject()`,`apimachinery/pkg/runtime/interfaces.go:337-340`),由 `Scheme` 维护 `GVK(GroupVersionKind)→ Go 反射类型` 的双向映射:`Scheme.gvkToType`/`typeToGVK`(`apimachinery/pkg/runtime/scheme.go:50-63`)。GVK 是"逻辑类型",HTTP 路径里的 GVR(GroupVersionResource)是"逻辑资源",二者通过 RESTMapper 换算。`Scheme.New(kind)` 就是一次 `reflect.New`(`scheme.go:306-315`)。
2. **带乐观锁的持久化存储(generic registry + etcd3 store)**。`resourceVersion`(RV)直接等于 etcd 的 MVCC revision(modRevision),写路径用 etcd 事务 `Compare(ModRevision(key),"=",expectedRev)` 做 CAS。通用 `registry.Store` 把所有资源共享的 Create/Update/Get/Watch 骨架抽出来(`apiserver/pkg/registry/generic/registry/store.go:101-250`),每种资源只注入策略(Strategy)与键函数。
3. **事件流(watch)**。客户端 List 拿到快照 + RV,再用 `watch?resourceVersion=X` 增量消费,从而在本地维护一份最终一致的缓存(client-go Reflector/Informer)。RV 同时是乐观锁令牌和 watch 的游标,这是整个声明式模型最关键的"一物两用"。

校验分层为:**Schema/Strategy 校验(确定性)→ mutating admission(可改写)→ 存储 CAS → validating admission(只读裁决)**。其中 validating admission 被"下推"进存储层的乐观重试循环里执行(见 ③),保证"校验所见的 existing"与"真正写入前的 existing"一致。

把这三层放在一起看,"声明式"的定义就落地了:用户只声明期望状态(一个 GVK 对象),apiserver 负责(1)把声明持久化为带全局版本号的记录(存储层),(2)让任何Interested 方可以按版本号订阅状态变迁(watch 层),(3)在(1)与(2)之间插入策略与安全边界(校验层)。控制器的收敛循环 = "读快照 → 计算差异 → 乐观写回 → 收听事件",所有部件都由这三层提供原语,apiserver 自身不编排任何业务逻辑——这就是它能为任意 CRD"免费"获得全部机制的原因。

GVK 与 GVR 的分工值得多说一句:GVK(`apps/v1.Deployment`)标识"这是什么类型",GVR(`apis/apps/v1/deployments`)标识"资源在 HTTP 路径上叫什么"。一个 GVK 可以对应多个 GVR(比如 status 子资源 `/deployments/x/status` 的 kind 仍是 Deployment,`admission/interfaces.go:41-43` 的注释专门解释了这一点)。Scheme 之所以维护**双向**映射,是因为两个方向各有用途:`gvkToType` 供 `Decoder.Decode` 按报文里的 apiVersion/kind 实例化对象(`interfaces.go:104-113` 的 Decoder 契约:`Decode(data, defaults, into)` 返回对象及其 GVK);`typeToGVK` 供 `ObjectKinds` 反查、供编码器决定写出哪个版本(`interfaces.go:283-292`)。编解码器是分层组装的:最内层是 JSON/Protobuf/CBOR 序列化器,外层套 `versioning.codec` 负责版本转换与默认值(`apimachinery/pkg/runtime/serializer/versioning/versioning.go:42-79`,`NewCodec` 接收 `encodeVersion`/`decodeVersion` 两个 GroupVersioner),再外层由 `codecFactory` 按媒体类型协商(`interfaces.go:144-190` 的 `SerializerInfo`/`NegotiatedSerializer`,支持 strict 模式拒绝未知字段,`interfaces.go:159-161`)。存储层另有一条独立的编解码链:对象写进 etcd 前要再过一次 `StorageSerializer` + 加解密 transformer(`etcd3/store.go:270,323`),因此"线格式""内部格式""存储格式"三者解耦,存储格式可以独立演进(如启用 CBOR 存储特性门控)。

一次写请求的完整栈:

```
HTTP → DefaultBuildHandlerChain(认证/鉴权/APF/audit…)
     → go-restful 路由(installer.go) → createHandler/updateHandler(endpoints/handlers)
     → 解码(GVK)+ 默认值 + mutating admission
     → registry.Store(通用骨架:校验、key、重试)
     → DryRunnableStorage → cacher/etcd3 store(编解码 + 加解密 + etcd Txn)
     → etcd(quorum 写,全局 revision +1)
     → watchCache/etcd watcher 广播事件 → 所有 informer 收到通知
```

值得强调:`Store.Storage` 字段声明为 `DryRunnableStorage`(`store.go:219-222`),它在真实存储外再包一层——dry-run 请求只走"编码、校验、模拟事务"而不落库,这使得 `kubectl apply --dry-run=server` 与真实写共享同一份代码路径,差异被收敛到存储装饰器的最后一步。

## ② 一条 kubectl apply 的服务端旅程

`kubectl apply`(客户端 apply)实际是 GET + PATCH/PUT;`kubectl apply --server-side` 是 `PATCH, Content-Type: application/apply-patch+yaml`。二者都走 `UpdateResource`(`apiserver/pkg/endpoints/handlers/update.go:51`),这条路径最能串起所有机制。

**第 0 步:HTTP 中间件链。** `DefaultBuildHandlerChain`(`apiserver/pkg/server/config.go:1036-1116`)由内向外包裹(注册顺序即执行顺序的逆序,下图自上而下为请求到达顺序):

```
请求 ──► WithAuditInit                      config.go:1114  初始化 audit 上下文
      ──► WithPanicRecovery                 config.go:1113  兜底 500
      ──► WithMuxAndDiscoveryComplete       config.go:1112  等待路由装配完成
      ──► WithRequestReceivedTimestamp      config.go:1111
      ──► WithRequestInfo                   config.go:1110  解析 GVR/verb 进 ctx
      ──► [WithRoutine]                     config.go:1107  APIServingWithRoutine 特性门
      ──► WithLatencyTrackers / HTTPLogging config.go:1102-1103
      ──► WithRetryAfter / HSTS / CacheControl / Goaway  config.go:1094-1101
      ──► WithWatchTerminationDuringShutdown config.go:1091  优雅关闭保护 watch
      ──► WithWaitGroup                     config.go:1090  计入 NonLongRunningWaitGroup
      ──► WithRequestDeadline               config.go:1088  整请求 deadline(RequestTimeout)
      ──► WithTimeoutForNonLongRunningReq   config.go:1086  60s 超时(watch 除外)
      ──► WithWarningRecorder               config.go:1082
      ──► WithCORS                          config.go:1078
      ──► WithAuthentication                config.go:1075  认证 → user.Info 进 ctx
      ──► WithTracing                       config.go:1072  认证后才允许采样控制
      ──► WithAudit                         config.go:1064  audit 事件落地
      ──► WithImpersonation                 config.go:1055-1060  模拟用户
      ──► WithPriorityAndFairness           config.go:1048  APF 排队(watch 计入 workEstimator)
      ──► WithAuthorization                 config.go:1040  RBAC 等 authorizer 链
      ──► TrackCompleted → go-restful 路由 → updateHandler
```

注意三点顺序的艺术:认证在 tracing 之前(避免未认证流量影响采样,`config.go:1070-1072` 注释);`WithRequestInfo` 在最外层靠内,后续所有 filter 都能从 ctx 拿到 GVR/verb;watch 属于 long-running,被 `LongRunningFunc` 从普通超时与 APF 计数中豁免(`config.go:1086`、`endpoints/handlers/metrics` 相关设计)。

并发控制层(`config.go:1043-1052`)是双保险结构:配置了 APF(`c.FlowControl != nil`)时走 `WithPriorityAndFairness`,请求按 priorityLevel/flowSchema 排队,work estimator 会把"该资源的 watch 数与对象总数"折算成请求工作量的预估(seats),一条大 List 或新 watch 会占用更多席位;未启用 APF 时退化为 `WithMaxInFlightLimit` 的硬阈值计数(读写分离:普通与 mutating 各自限额)。二者都布置在认证之后、鉴权之前——**先排队后鉴权**看似浪费,实则避免了鉴权器被洪峰打垮,鉴权链(RBAC/webhook authorizer)本身也是要花钱的。

**第 1 步: negotiate 与解码。** `updateHandler` 读取 body(`limitedReadBodyWithRecordMetric`)、解码 UpdateOptions,然后 `decoder := scope.Serializer.DecoderToVersion(...)` 把请求体解码为**内部版本(internal)**对象(`endpoints/handlers/create.go:125-127` 同构,update.go 同理)。`scope.HubGroupVersion` 就是 `__internal`(`endpoints/installer.go:682`):所有外部版本(v1、v1beta1…)在服务端统一转换到 internal hub 再分发,新版本只需实现与 hub 的双向转换。

**第 2 步:准备 objInfo。** `rest.DefaultUpdatedObjectInfo(obj, transformers...)`(`update.go:211`)把"如何从 existing 计算新对象"封装成 `UpdatedObjectInfo`;transformers 里塞入了 managedFields 更新和 **mutating admission**(`update.go:169-190`)——它们被延迟到拿到 existing 之后才执行。

**第 3 步:进入通用 Store.Update。** `r.Update(ctx, name, objInfo, createValidation, updateValidation, false, options)`(`update.go:208-221`),其中两个 admission 回调:
- `withAuthorization(rest.AdmissionToValidateObjectFunc(...))` —— create-on-update 时补一次 create 校验+鉴权(`update.go:212-215`);
- `rest.AdmissionToValidateObjectUpdateFunc(...)`(`update.go:216-218`)—— validating admission,实现在 `registry/rest/update.go:285-286`,被下推进存储事务回调(见 ③)。

**第 4 步:etcd CAS。** `GuaranteedUpdate` 用 etcd 事务比较 ModRevision 提交(见 ③ 第 3 段)。成功后全局 revision +1,`watchCache`/`etcd3 watcher` 把 PUT 事件转成 `MODIFIED` watch 事件推给所有订阅者——**写请求的返回和事件广播是两条独立路径**,这正是"控制器最终一致"的根源。

**第 5 步:响应写出。** `UpdateResource` 拿到结果后按 `wasCreated` 决定 200/201(`update.go:247-250`),经 `transformResponseObject` 把 internal 对象转回客户端请求的版本与媒体类型写出。若序列化后体积超限,还有一次移除 `managedFields` 后重试的机会(`update.go:227-239`,create 侧同构 `create.go:212-217`)——server-side apply 会把字段归属关系存在对象里,大对象场景下这一"瘦身重试"能救回不少本会失败的写入。

顺带补全 apply 场景的特有分支:server-side apply 走 PATCH 处理器时以 `forceAllowCreate=true` 调用 `Store.Update`(`update.go` 的调用参数第 5 位),从而在对象不存在时直接在乐观循环内完成创建(`store.go:732` 的 `ignoreNotFound`);同时 managedFields 由 `scope.FieldManager` 在 transformer 中计算字段归属(`update.go:162-167`)。

最后给一条延迟预算的直觉:一次 PUT 的耗时 = 中间件(认证/鉴权/APF 排队)+ 解码与默认值 + **全部 mutating webhook 的 TLS 往返之和** + etcd quorum 写(跨可用区 RTT)+ validating admission;watch 事件广播在响应之后异步发生。因此"写慢了"要先分清是排队(APF 指标)、webhook(审计事件里的 webhook 耗时)还是 etcd(etcd3 请求延迟指标)——三条路径在代码里是三段独立的 span(`create.go:57` 的 `Create` span、`etcd3/store.go:484` 的 `GuaranteedUpdate etcd3` span),tracing 会把它们串成一条链。

## ③ 通用 registry 的 Create/Update 骨架

### 3.1 Create:`store.go:545-626`

`Store` 结构体(`store.go:101-250`)是典型的"模板方法"模式:函数字段 `NewFunc/KeyFunc/CreateStrategy/BeginCreate/AfterCreate…` 由每种资源的 registry 注入。Create 骨架(`store.go:545-626`):

1. `FillObjectMetaSystemFields`:只填 `creationTimestamp` 与 `UID`(`apiserver/pkg/registry/rest/meta.go:39-42`)——注意连 generation 都交给策略,系统字段被 `WipeObjectMetaSystemFields` 清空(`endpoints/handlers/create.go:171`);
2. `generateName` 且无 name 时生成随机后缀名(`store.go:553-555`),冲突则整对象重试最多 `maxNameGenerationCreateAttempts` 次(`store.go:535-543`);
3. `rest.BeforeCreate`(`registry/rest/create.go:103-140`)依次做五件事:① 断言系统字段(UID/creationTimestamp)已初始化,否则报内部错误(`create.go:110-112`)——调用顺序上的"先填后查"是防呆设计;② 断言 generateName 已生成出 name;③ 校验对象命名空间与请求命名空间一致(`create.go:120-126`);④ `strategy.PrepareForCreate`(各资源的默认值、字段清洗、`generation=1` 等都写在这一个函数里);⑤ `ValidateCreate` 收集 field.ErrorList 转成 422 Invalid;最后还挂了 `WarningsOnCreate` 与 `Canonicalize` 两个扩展点。**策略校验是纯函数式的:同输入同输出,不访问存储**——这是它区别于 admission 的根本特征。
4. 调用 `createValidation` —— 即 validating admission(`store.go:574-578`);
5. `KeyFunc(ctx, name)` 算出 etcd key,`e.Storage.Create` 落库(`store.go:584-594`);
6. AlreadyExists 时回读现有对象,若带 deletionTimestamp 则把报错改成 "object is being deleted"(`store.go:597-611`)。

### 3.2 键设计:资源前缀 + 命名空间 + 名字

etcd key 形如 `/registry/pods/<ns>/<name>`。通用实现(`store.go:269-308`):

```go
func NamespaceKeyFunc(ctx context.Context, prefix string, name string) (string, error) {
    key := NamespaceKeyRootFunc(ctx, prefix)   // prefix + "/" + ns(store.go:269-276)
    ns, ok := genericapirequest.NamespaceFrom(ctx)
    if !ok || len(ns) == 0 { return "", apierrors.NewBadRequest("Namespace parameter required.") }
    ...
    key = key + "/" + name
    return key, nil
}
```

较新代码把前缀拆成 `prefix + resourcePrefix` 两段,`etcd3 store.New` 强制 `resourcePrefix` 非空、以 `/` 开头且不为 `/`(`apiserver/pkg/storage/etcd3/store.go:149-165`)。list/watch 用 `KeyRootFunc`(整个集合前缀)做范围扫描;WatchPredicate 还会把 `fieldSelector metadata.name=X` 收敛成单 key、关掉 Recursive(`store.go:1567-1574`)。

### 3.3 Update:乐观锁核心代码

`Store.Update`(`store.go:711-920`)把全部逻辑塞进一个回调,交给 `Storage.GuaranteedUpdate` 做乐观重试。RV 冲突判定的原文(`store.go:756-835` 摘录,≤15 行):

```go
// store.go:760
doUnconditionalUpdate := newResourceVersion == 0 && e.UpdateStrategy.AllowUnconditionalUpdate()
...
} else {
    // store.go:825-835
    if newResourceVersion == 0 {
        return nil, nil, apierrors.NewInvalid(qualifiedKind, name,
            field.ErrorList{field.Invalid(field.NewPath("metadata").Child("resourceVersion"),
                newResourceVersion, "must be specified for an update")})
    }
    if newResourceVersion != existingResourceVersion {
        return nil, nil, apierrors.NewConflict(qualifiedResource, name, fmt.Errorf(OptimisticLockErrorMsg))
    }
}
```

`OptimisticLockErrorMsg = "the object has been modified; please apply your changes to the latest version and try again"`(`store.go:263`)——每个用过 kubectl 的人都见过的 409。两个重要豁免:① 对象无 RV 且策略 `AllowUnconditionalUpdate`(如 Service)则改为"无条件更新",写前把新对象 RV 刷成 latest(`store.go:815-818`);② create-on-update(含 server-side apply 的 `forceAllowCreate`)在 `existingResourceVersion == 0` 分支走完整 Create 流程(`store.go:762-811`)。validating admission 在此回调内执行:`updateValidation(ctx, obj.DeepCopyObject(), existing.DeepCopyObject())`(`store.go:865-869`),所以**每次乐观重试都会基于最新 existing 重跑校验**,不会出现"校验旧状态、写入新状态"的 TOCTOU。

### 3.4 etcd3 事务:GuaranteedUpdate 与 OptimisticPut

`etcd3/store.go:477-641` 的 `GuaranteedUpdate` 是个无限 for 循环:取当前状态 → 检查 Preconditions(UID/RV)→ 执行 tryUpdate 回调 → 若回调报错且缓存数据可能过期则重拉重试(`store.go:533-557`)→ 编码比对,若字节级相同则直接短路返回(no-op 检测,`store.go:566-590`)→ 最后用 etcd 事务提交:

```go
// vendor/go.etcd.io/etcd/client/v3/kubernetes/client.go:84-105(由 etcd3/store.go:610 调用)
txn := k.KV.Txn(ctx).If(
    clientv3.Compare(clientv3.ModRevision(key), "=", expectedRevision),
).Then(
    clientv3.OpPut(key, string(value), clientv3.WithLease(opts.LeaseID)),
)
if opts.GetOnFailure {
    txn = txn.Else(clientv3.OpGet(key))
}
txnResp, err := txn.Commit()
```

`expectedRevision` 就是对象上那个 RV(读路径 `store.go:277` 用 `ModRevision` 回填 RV)。事务失败时 Else 分支把最新值带回(`GetOnFailure: true`),apiserver 无需再发一次 Get,直接进入下一轮循环(`etcd3/store.go:621-630`)。Create 走同一个事务原语,只是 `expectedRevision=0`(语义:键必须不存在),失败返回 `NewKeyExistsError`(`etcd3/store.go:331-341`)。TTL>0 的对象(如 Event、Node lease 心跳之外的过期对象)通过 `leaseManager` 复用 etcd lease(`etcd3/store.go:599-605`)。

### 3.5 Get 与 quorum 读

`etcd3/store.go:239-285` 的 Get 调 `client.Kubernetes.Get`(未设 `WithSerializable`,即 etcd 默认**线性一致读**,需 quorum);随后 `validateMinimumResourceVersion`(`etcd3/store.go:1290-1301`)在客户端给的 min-RV 大于当前 revision 时返回 `TooLargeResourceVersion` 错误,触发 client-go 重新 relist。List 的 `ResourceVersion`/`ResourceVersionMatch` 语义声明在 `apiserver/pkg/storage/interfaces.go:305-312`:"结果不老于所给 RV 即可"——这给了 watch cache 服务 List 的合法性。

### 3.6 List 与单对象 Get 的通用骨架

`Store.Get`(`store.go:945-960`)的模式值得记背:`out := e.NewFunc(); key, _ := e.KeyFunc(ctx, name); e.Storage.Get(ctx, key, opts, out)`——**先造空对象再让存储层解码填充**,这是全 K8s 代码里最典型的"类型由 NewFunc 携带"的模式,配合 `NewFunc/NewListFunc`(`store.go:102-112`),通用 Store 不需要在任何地方写 `switch kind`。List 走 `ListPredicate`(`store.go:450-512`),把 label/field selector 编译成 `storage.SelectionPredicate` 下推到存储层(etcd3 侧边扫边过滤,甚至支持流式分块 `etcd3/store.go:941`),返回前还会经 `startObservingCount` 周期采样对象总数喂给 APF 的 work estimator(`store.go:1755-1777`)——读写两条路径都与限流联动,这个设计常被忽略。

## ④ watch 机制与 resourceVersion

### 4.1 服务端:从 HTTP 到事件流

watch 与 list 共用同一路由,由 `restfulListResource → ListResource` 分流(`endpoints/installer.go:840/1016/1295`,`endpoints/handlers/get.go:168-200`):`opts.Watch || forceWatch` 则 `handleWatch`。超时规则(`get.go:271-282`):`?timeoutSeconds=` 优先;否则取 `minRequestTimeout × (1+rand)` 的抖动值——**随机化是为了打散大量 watcher 的同时断连/重连**。随后 `ctx.WithTimeout` + `serveWatchHandler`(`get.go:281-287`)。

`WatchServer.HandleHTTP`(`endpoints/handlers/watch.go:362-481`)是事件泵:chunked 传输(可选 gzip,`watch.go:334-346`),每个事件经 `watchEncoder` 编码后按帧写出,`len(ch)==0` 时才 Flush(`watch.go:452-457`)以合批。select 四路退出:server 关闭 / ctx done / timeoutCh / channel 关闭(`watch.go:423-441`)。支持 WebSocket(`watch.go:186-189`);请求 `application/cbor` 的 watch 会切换为 `application/cbor-seq`(`watch.go:98-110`)。

事件模型在 apimachinery:`Event{Type, Object}`,类型 `ADDED/MODIFIED/DELETED/BOOKMARK/ERROR`(`apimachinery/pkg/watch/watch.go:56-83`)。DELETED 携带"删除前一瞬"的对象;BOOKMARK 的 Object 只填 RV(`watch.go:76-79`)。

etcd 事件到 K8s 事件的翻译发生在 `etcd3/watcher.go`:watch 订阅时带 `WithPrevKV()`(`watcher.go:472`),Put 事件解出 curObj 即 `MODIFIED`(若此前键不存在则合成 `ADDED`),Delete 事件用 prevValue 还原"删除前对象"发 `DELETED`(`watcher.go:838-856` 附近);解码前先过解密 transformer,过滤(标签/字段选择器)也在这一层完成——**过滤在 apiserver 内部逐层做:etcd3 watcher 一遍、cacher 一遍、decorated watcher 一遍**,保证每一层都只向上游泄漏匹配事件。`Watch` 接口的消费契约也定义得很谨慎:消费者必须持续读取直到 channel 关闭,`Stop()` 只能由消费方调用(`watch/watch.go:29-51`)。

### 4.2 bookmark 与 timeout 的配合

Cacher 内部维护 `bookmarkWatchers`(每 `defaultBookmarkFrequency=1min` 一拍,外加"watch 到期前必发一个 bookmark",`apiserver/pkg/storage/cacher/cacher.go:71-78,341,417`)。bookmark 让 client-go 在长连接静默期也持续刷新 `lastSyncResourceVersion`,重连时能从足够新的 RV 续传,避免退化成全量 relist。WatchList(feature)下还有一个带 `k8s.io/initial-events-end: "true"` 注解的特殊 bookmark,标记"初始 LIST 事件发送完毕"(`apiserver/pkg/storage/util.go:92-106`;`apimachinery/pkg/apis/meta/v1/types.go:508`),服务端在 etcd3 watcher 与 cacher 两层都会生成它(`apiserver/pkg/storage/etcd3/watcher.go:465-471`;`handlers/watch.go:443-478` 以它统计 watchlist 初始延迟)。

### 4.3 resourceVersion 语义汇总

| 场景 | 取值 | 含义 | 依据 |
|---|---|---|---|
| watch RV="" | 无 SendInitialEvents | 从"当前状态"开始:先发现有对象(合成 ADDED)再从 maxRev+1 增量 | `etcd3/watcher.go:124-126,184-191` |
| watch RV="0" | cache 优先 | 允许 watch cache 用任意不老于缓存的位置服务 | `cacher.go:1313-1320` |
| watch RV=X | 精确 | 从 >X 的事件开始;X 已被 compaction 则 410 Gone | `etcd3/watcher.go:185-187,421-423` |
| list RV="" | quorum read | 直接打 etcd,线性一致 | `reflector.go:1120-1124` 注释 |
| list RV="0" | cache 优先 | reflector 首次 list 的默认值,防 etcd 热点 | `reflector.go:1126-1130` |
| list RV=X (非0) | ≥X | 不关分页以便走 watch cache | `reflector.go:689-700` |
| update body RV | 乐观锁 | 不等则 409 | `store.go:833-835` |

### 4.4 Cacher 内部:apiserver 自己也是一个 informer

Cacher 的启动参数里直接内置了一个 client-go reflector:`cache.NewNamedReflector(reflectorName, listerWatcher, nil, watchCache, 0)`(`cacher.go:441-447`)——watchCache 实现了 client-go 的 store 接口,把全量 List 与增量事件组织成带 RV 的时间窗口(watchCacheInterval),单一 etcd watch 流在此被复制给 N 个 HTTP watcher。每个 watcher(`cacheWatcher`)有独立的有界 channel,channel 大小由 `suggestedWatchChannelSize` 依"是否命中索引 trigger"动态决定(`cacher.go:570-577` 附近);若命中 `indexedTrigger`(如 `spec.nodeName`),事件分发从全量遍历退化为索引直取,这是 Node 级大规模 watcher 的性能支点。写路径上,`watchCache.SetOnReplace/SetOnEvent` 回调把事件灌进 `Cacher.incoming` channel(`cacher.go:407,491`),由分发 goroutine 统一编号、过滤、投递——**apiserver 用一套单生产者多消费者的内存扇出,把 etcd watch 数与客户端 watcher 数解耦**,这是"etcd 连接数不随客户端数增长"的答案。

### 4.5 与 etcd 的衔接:compaction 与 progress notify

etcd MVCC 保留历史,由 apiserver 侧的 compactor 周期性压缩(`apiserver/pkg/storage/etcd3/compact.go:47-95,153`,`StartCompactorPerEndpoint` 保证每 endpoint 单例)。压缩后,拿旧 RV 来 watch 的客户端会收到 `mvcc: required revision has been compacted`,etcd3 watcher 将其降级为 warning 并断开重连(`watcher.go:421-423`),client-go 收到 410 后 relist 重建。另一衔接是 `RequestWatchProgress`(`etcd3/store.go:104-108`)→ etcd `WithProgressNotify`(`watcher.go:476-478`):etcd 周期性发 progress 事件,apiserver 转成 bookmark(`watcher.go:499-502`),用于证明"该 RV 之前无事件遗漏",这是 WatchList 一致性快照的前提。

### 4.6 客户端:Reflector 的 ListWatch

client-go `Reflector.ListAndWatchWithContext`(`client-go/tools/cache/reflector.go:470-509`):优先 WatchList(`watchList`,`reflector.go:804`,依赖 initial-events-end bookmark 判定快照完整),失败回退 `list()`;`list()` 用 pager 分页,RV 由 `relistResourceVersion()` 决定(`reflector.go:1111-1132`):上次 RV 不可用(410/too-large)→ `""`(quorum 打 etcd);首次 → `"0"`(允许走 watch cache);否则用 `lastSyncResourceVersion` 续传。之后进入 watch 循环,从 `LastSyncResourceVersion` 重连(`reflector.go:590-599`)。`Lister` 接口的契约写得直白:"Items 字段会被取出,ResourceVersion 用于在正确位置启动 watch"(`client-go/tools/cache/listwatch.go:29-36`)。

## ⑤ admission 与 webhook:两层准入

### 5.1 接口与链

admission 插件可实现两个正交接口(`apiserver/pkg/admission/interfaces.go:130-145`):`MutationInterface.Admit`(可改对象)与 `ValidationInterface.Validate`(只读)。`chainAdmissionHandler.Admit` 顺序执行、首个错误即返回(`admission/chain.go:31-44`);`Validate` 同理(`chain.go:47-60`)。`Attributes`(`interfaces.go:32-78`)携带 operation/name/namespace/GVR/新旧对象/userInfo/dryRun 等。**同一个插件可以同时实现两个接口**——因此 kube-apiserver 的启动参数把 mutating 与 validating 拆成两条链、按序各跑一遍。

### 5.2 调用点:mutating 在处理器层,validating 在存储循环内

- **Create**:mutating 在 `FinishRequest` 内、`Store.Create` 之前(`endpoints/handlers/create.go:202-206`);validating 经 `rest.AdmissionToValidateObjectFunc`(`create.go:183-191`;`registry/rest/create.go:217-218`)作为 `createValidation` 传下去,在 `store.go:574-578` 执行。
- **Update**:mutating 被包成 transformer,在 `GuaranteedUpdate` 拿到 existing 后经 `objInfo.UpdatedObject()` 触发(`endpoints/handlers/update.go:169-190` + `store.go:747`)——因此 mutating webhook 看到的 oldObj 一定是本轮重试的最新对象;validating 同样在事务回调内执行(见 3.3)。

这个布局的含义:**任何一次乐观重试都会重跑(mutating 变换 + validating 裁决)**,代价是 webhook 可能被多次调用,K8s 用 reinvocation 策略(`admission/reinvocation.go`,`interfaces.go:107-121` 的 `ReinvocationContext`)显式管理这一点。

### 5.3 Webhook 插件

mutating/validating webhook 是普通 admission 插件,只是把决策外包给 HTTPS 端点:`validatingDispatcher.Dispatch`(`admission/plugin/webhook/validating/dispatcher.go:88`)按远端配置逐个调用,每个 hook 用其 `TimeoutSeconds` 做 ctx 超时(`dispatcher.go:279`),失败包装成 `ErrCallingWebhook`(`dispatcher.go:311`),再按 `failurePolicy`(fail-open/fail-closed)决定放行或拒绝;mutating 侧同构(`mutating/dispatcher.go:278`)。webhook 响应可带 `status.code`,patch 以 JSONPatch 返回给 mutating。audit 侧,`admission.WithAudit` 在 create/update 处理器入口统一包装(`create.go:160`,`update.go:140`)。

webhook 的匹配规则(`matchPolicy`、`namespaceSelector`、`objectSelector`、`rules.scope`)在 `ValidatingWebhookConfiguration` 对象里声明,由 apiserver 内置的 informer 持续同步并按 GVK 索引,Dispatch 前先做 O(规则数) 的规则匹配只把命中的 hook 发给 dispatcher。工程上必须记住三个坑:**每个被命中的 webhook 都要一次完整的 TLS 往返**,所以 mutating webhook 的数量直接吃掉写请求延迟预算;`TimeoutSeconds` 之和必须小于请求级 deadline(`config.go:1088` 的 RequestTimeout),否则超时先在中间件层爆炸;fail-open 的 validating webhook 等于给集群开了一个旁门,审计里专门有 `failed-open` 注解供追溯(`dispatcher.go:44-46` 的 `ValidatingAuditAnnotationFailedOpenKeyPrefix`)。

### 5.4 为什么两层分立,而不是一个"拦截器"?

因为二者对重试的语义要求不同:mutating 是"函数变换",输入 existing、输出新对象,天然幂等于乐观循环(重跑即可);validating 是"谓词",必须在**提交前的最后一刻**对"真实的 existing + 变换后的 new"求值,放早了就会有 TOCTOU 窗口。把它们塞进同一个线性拦截器(像大多数 Web 框架那样)做不到"validating 紧贴 CAS",K8s 的做法是把两层显式拆成两个接口、在通用 Store 骨架的两个不同位置调用——这是本子系统里最值得借鉴的结构决策。

## ⑥ 设计动机与取舍

1. **internal hub 版本模式**:所有外部版本 ⇄ internal 的星型转换(`installer.go:682` 的 `HubGroupVersion`),把 N 个版本的兼容问题从 N² 降为 2N,代价是每次请求多一次对象拷贝与转换。
2. **RV 一物两用**(乐观锁令牌 + watch 游标):省掉独立的"事务号"系统,让"读-算-写"与"订阅增量"共享同一全局序。代价是 RV 与 etcd revision 强耦合,watch 的可用性受制于 compaction 策略。
3. **validating admission 下推进存储循环**:换取"校验所见即写入所对"的强一致语义;代价是 webhook 调用次数与重试成本(以及随之而来的 reinvocation 复杂度)。
4. **watch cache(Cacher)默认开启**:apiserver 自己就是个 informer(`cacher.go:441-447` 用 `cache.NewNamedReflector` 喂 watchCache),把 List/watch 的读放大从 etcd 挪到 apiserver 内存;只有 RV="" 的 list 才穿透到 etcd quorum(`cacher.go:1313-1320`,`reflector.go:1120-1124`)。Events 等低价值资源可绕过 cache。
5. **etcd 事务而非锁**:`Compare(ModRevision)=rev` 的 CAS 把并发控制完全下推到存储,apiserver 无状态可水平扩容;代价是高竞争 key 上的 409 风暴(如 lease/endpoint),由上层(Backoff、leader 选举)消化。
6. **watch 的 HTTP/chunked 而非 gRPC**:让 watch 能穿过普通 L7 负载均衡,并自然复用认证/审计/APF 中间件链;代价是断连检测粗糙,需要 bookmark + 随机超时(`get.go:276-278`)对抗羊群效应。
7. **用"`__internal` hub"而非"最新稳定版"做版本中枢**:hub 永不对外暴露(`interfaces.go:26-31` 把 `APIVersionInternal = "__internal"` 定义为纯约定),好处是 hub 字段可以容纳所有版本的超集而不必顾忌 API 兼容承诺;代价是每个请求至少多一次深拷贝转换,以及新增版本要写全套 conversion 函数(由 code-generator 生成)。
8. **`generateName` 的乐观重试而非唯一名锁**:名字冲突就是一次普通的 AlreadyExists,重试换随机后缀(`store.go:535-543`),把"分配唯一名"退化成"重试 CAS",与整个系统"只有冲突重试、没有分布式锁"的并发哲学一致。

### 6.1 补充:delete 与 finalizer 的位置

虽然本篇聚焦 Create/Update,但 Update 骨架里藏着删除语义的一半:`ShouldDeleteDuringUpdate`(`store.go:633-654`)规定"新对象无 finalizer、旧对象已有 deletionTimestamp 且 grace period 为 0"时,更新即触发删除(`store.go:871-875` 返回 `errEmptiedFinalizers` 后转 `deleteWithoutFinalizers`,`store.go:678-706`)。这就是"控制器摘掉最后一个 finalizer 才真正删除"的实现位置——finalizer 协议没有独立的存储机制,完全寄生在通用 Update 骨架的条件分支上,这是理解 GC 与自定义控制器协作的关键入口。

### 6.2 补充:两层准入的全局顺序

虽然 mutating 与 validating 各自成链,但它们的相对顺序由调用点布局隐式保证:任一请求里,所有 mutator 的 `Admit`(`chain.go:31-44`)先于所有 validator 的 `Validate`(`chain.go:47-60`)执行——因为两处调用点在代码路径上一前一后(处理器层的 transformer 先跑,存储循环内的 `updateValidation` 后跑)。对 webhook 而言这意味着:**mutating webhook 可以放任意垃圾进对象,但一定逃不过后置的 validating 全集**,包括与 mutating 无关的第三方校验 webhook。运维排障时应先看 validating 链的拒绝信息,再看 mutating 链的字段来源(用 managedFields 的 manager 名定位是哪个 webhook 改的)。

## ⑦ FAQ

**Q1:resourceVersion 到底是什么?**
etcd MVCC 的全局 revision(单键维度即 ModRevision):读路径用 `getResp.KV.ModRevision` 回填(`etcd3/store.go:277`),写路径用它做事务 Compare(`client.go:84-105`)。它对整个集群单调递增,不区分资源。

**Q2:为什么 PUT 不带 resourceVersion 有时不报错?**
因为策略允许 `AllowUnconditionalUpdate`(如 Service、Namespace),此时等价于"以最新版本为基线覆盖"(`store.go:760,815-818`);大多数资源(如 ConfigMap)则会报 `resourceVersion must be specified for an update`(`store.go:825-832`)。

**Q3:watch 从 RV="" 开始会丢事件吗?**
不会丢但会有"起点语义":先对现有对象合成事件再从 maxRev+1 增量(`watcher.go:124-126`);若要"先快照后增量"的强一致组合,用 WatchList(SendInitialEvents + initial-events-end bookmark,`watcher.go:191-214`,`util.go:92-106`)。

**Q4:410 Gone 是怎么产生的?**
watch/list 携带的 RV 已被 etcd compaction 回收。etcd3 watcher 捕获 `mvcc: required revision has been compacted`(`watcher.go:421-423`)上报,客户端收到 410 后应放弃续传、重新 List。client-go 对此有完整的状态机:`isLastSyncResourceVersionUnavailable` 置位后,下一次 relist 自动改用 RV="" 直读 etcd(`reflector.go:1111-1132`),任何情况下都不会用"可能已不存在的 RV"无限重试。

**Q5:bookmark 事件是干什么的?只有 RV 的空事件。**
它推进客户端游标:① 周期性/到期前的心跳(`cacher.go:71-78`);② etcd progressNotify 的透传(`watcher.go:499-502`);③ WatchList 的"初始同步完成"标记(`util.go:92-106`)。从 bookmark 的 RV 恢复保证不重不漏(`watch/watch.go:76-79`)。

**Q6:mutating webhook 会看到最新数据吗?重试时会重复调用吗?**
会、会。Update 的 mutating admission 在 `GuaranteedUpdate` 的乐观循环内执行(`update.go:169-190` + `store.go:747`),每次 RV 冲突重试都以最新 existing 为 oldObj 重跑;官方用 ReinvocationContext 管理幂等(`interfaces.go:107-121`)。

**Q7:apiserver 是不是 etcd 的"broker"(代理队列)?**
不是。它没有消息语义,而是 etcd 之上的一致性读缓存 + 事件扇出层:Cacher 用自己的 reflector 维护内存历史窗口(`cacher.go:441-447`),把 etcd 的单流事件按 selector 复制给成百上千个 watcher,并消化 compaction 窗口(`EventFreshDuration`,`cacher.go:74`)。

**Q8:List 一定打到 etcd 吗?**
否。RV="0" 或带 Limit 的分页 list 通常由 watch cache 服务;只有 RV=""(quorum 语义)或 cache 未同步时才穿透(`cacher.go:1313-1320`;reflector 甚至在 RV≠"" 时主动关闭分页以命中 cache,`reflector.go:689-700`)。

**Q9:Get 是强一致读吗?**
是。etcd3 Get 未启用 serializable,默认线性一致(要过 quorum,`etcd3/store.go:252`);`validateMinimumResourceVersion` 进一步保证不返回比客户端已知 RV 更旧的数据(`etcd3/store.go:1290-1301`)。

**Q10:为什么 handler chain 里认证在 tracing 之前、RequestInfo 较靠内?**
认证后才允许客户端影响采样决策(`config.go:1070-1072` 注释);而 RequestInfo 解析出的 GVR/verb 是鉴权、审计、APF work estimator 的共同输入,必须在它们之前就位(`config.go:1110` 与 `1043-1048`)。

## ⑧ 深挖问题(后续调研方向)

1. **WatchList 的端到端一致性证明**:etcd3 watcher 的 initial-events-end bookmark 发在 `sync()` 之后、`WithRev(initialRev+1)` 的 watch 建立之前(`watcher.go:446-471`),存在事件先入队列后建 watch 的窗口——apiserver 靠什么保证两者无缝衔接(progressNotify?queue 顺序)?值得精读 `watchChan.run` 与 cacher 的 `bookmarkAfterResourceVersionFn`(`cacher.go:583-587`)。
2. **no-op 短路与 generation 语义**:`GuaranteedUpdate` 在新值字节级等于旧值时跳过写入(`etcd3/store.go:566-590`),但 `status` 子资源常回写相同内容——这与 ObjectMeta.generation 递增规则(`BeforeUpdate`)如何共同决定"watch 是否收到事件"?
3. **APF 对 watch 的量化**:workEstimator 把 watch 数计入请求成本(`config.go:1044-1048`,`flowcontrolrequest.NewWorkEstimator`),一条 watch 的"seats"如何随对象数/事件率变化,是理解大规模集群限流的关键。
4. **cacher 的历史窗口与 event 丢弃策略**:`DefaultEventFreshDuration`(bookmark 频率+15s,`cacher.go:71-74`)决定内存历史长度;窗口外的慢消费者如何被终止(410?)而非阻塞,涉及 `cacheWatcher` 的 chan 大小与 `nonblockingAdd`。
5. **etcd3 客户端 `kubernetes.Client` 封装**:本仓库 vendor 的 etcd client 新增了 `OptimisticPut/OptimisticDelete/RequestProgress` 语义层(`vendor/go.etcd.io/etcd/client/v3/kubernetes/client.go:84-130`),把 apiserver 原先散落的 Txn 代码收进客户端库——这次重构的动机(接口收敛?可测试性?)与其对 storage.Interface 兼容性的影响值得单独考证。
