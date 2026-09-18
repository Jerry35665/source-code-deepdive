# E2 · KV、ObjectStore 与微服务框架:JetStream 之上的三个 abstraction

> 《NATS 深读》卷二 · 报告 E(续)。基线:`nats-server` commit `8f3f31b0366eca0d855d0750b7ca547eadd10eff`。
> 卷一报告 E 讲了 JetStream 存储与复制本身;本报告讲架在它上面的 KV / ObjectStore / Micro 三层。
> 除特别注明"客户端约定(nats.go,不在本仓库)"外,所有论断均以 `文件:行号` 标注并经实际核对。

## 0. 先说结论:这三个 abstraction 到底在服务端的哪里?

先纠正一个常见误解:**nats-server 里没有 `$KV`、`$OBJ`、`$SRV` 的任何 API handler**。全仓库范围内:

- `$KV` 与 `$OBJ` 只出现在 `server/jetstream_api.go` 的两处:deny 列表(`jetstream_api.go:371-372`)和 domain 映射表(`jetstream_api.go:394-395`),此外再无业务代码;
- `KV_`/`OBJ_` 流名前缀在 `server/*.go` 非测试代码中 0 次出现(grep 核对);
- `$SRV`/`$JS.SRV` 在整个仓库(含文档)0 次出现(grep 核对)。

也就是说:KV 与 ObjectStore 是 **nats.go 客户端库里的"物化视图"库**,Micro 是**纯客户端规范**。服务端做的是三件事:① 提供一套足够强的 `$JS.API` 原语;② 把 `$KV.>`/`$OBJ.>` 当作独立主题空间保留并正确做 domain 映射;③ 为 KV 语义专门往流/存储层加特性(`AllowDirect`、`DiscardNewPer`、per-message TTL、subject delete markers、`KV-Operation` 头)。本报告以服务端视角把这三层"垫片"讲清楚。

## 1. 总览:两层 abstraction 的布局

KV:一个 bucket 就是一条 stream,key 就是 subject,"最新值"靠 per-subject 保留:

```text
        KV 客户端 (nats.go)                          nats-server
  bucket "config" ──► stream KV_config
  key "a.b"       ──► subject config.a.b            (stream Subjects: "config.>")
                                                    MaxMsgsPer = N 限制每 key 历史
  put  = 常规 PUB config.a.b ──────────────────────► processJetStreamMsg 落盘
  get  = 请求 $JS.API.DIRECT.GET.KV_config.a.b ────► processDirectGetLastBySubjectRequest
                                                    (LoadLastMsg,raw 消息直返,404=无 key)
  watch = 建 consumer(FilterSubject "config.>")──► 消费推送/拉取,marker 也是普通消息
  TTL  = 发布时带 Nats-TTL 头 ─────────────────────► filestore 时间轮到期删除/产生删除 marker
```

ObjectStore:一个 bucket 是"meta 流 + chunk 流"两条普通 stream(布局本身是客户端约定,服务端只看到两条流):

```text
  bucket "media" (nats.go 约定,服务端无感知)
  ┌────────────────────────────┐     ┌─────────────────────────────────────┐
  │ OBJ_media (meta,           │     │ OBJ_media C / chunks 流 (chunk)     │
  │  Subjects $O.media.M.*)    │     │  每个 chunk 一条消息,subject 编号    │
  │  每对象一条 meta 消息:      │     │  $O.media.C.<nroach>                │
  │  名称/大小/chunk 数/        │◄────│  顺序即流序,写入按 seq 单调          │
  │  nseq/digest(SHA256)/TTL   │ CAS │  大文件切固定大小块(客户端约定)       │
  └────────────────────────────┘     └─────────────────────────────────────┘
  meta 更新用 Nats-Expected-Last-Subject-Sequence 头做 CAS(stream.go:738, 6709-6734)
  get 时服务端不做聚合:客户端按 chunk 序号取回并按 SHA256 校验后拼接
```

## 2. KV:bucket=stream 的服务端支撑

### 2.1 `$KV` 主题空间:保留、deny 与 domain 映射

服务端把 `$KV.>`(以及 `$OBJ.>`)当作与 `$JS.API` 平行的独立主题空间,并明确禁止系统账号/域间链路误用它:

```go
// server/jetstream_api.go:371-372
var denyAllClientJs = []string{jsAllAPI, "$KV.>", "$OBJ.>"}
var denyAllJs = []string{jscAllSubj, raftAllSubj, jsAllAPI, "$KV.>", "$OBJ.>"}
```

这些 deny 在 leafnode 的 JetStream 域扩展场景里被合并进连接权限(`leafnode.go:2105-2111`,注释见 2106-2109:`$JS.API` 流量只该走系统账号),`auth.go:1136` 则在内部 nkey 用户上检查并告警。domain 映射表是理解"$KV 到底有没有服务端 API"的最佳材料,注释写得相当直白:

```go
// server/jetstream_api.go:376-385(节选)
// It is a consequence of what we defined the domain prefix to be "$JS.domain.API" ...
// For optics $KV and $OBJ where made to be independent subject spaces.
// As materialized views of JS, they did not simply extend that subject space to say "$JS.API.KV" "$JS.API.OBJ"
// ...
// To avoid overlaps KV and OBJ views append the prefix to their API.
// (Replacing $KV with the prefix allows users to create collisions with say the bucket name)
```

映射表本身把 `$JS.<domain>.API.$KV.>` 原样映射回 `$KV.>`(`jetstream_api.go:394-397`),即:**跨 domain 访问 KV 时,客户端照旧发 `$KV.>` 主题,由服务端映射补上 domain 前缀;而 KV 的实际操作(建流/建 consumer)复用的正是 `$JS.API.STREAM.*/CONSUMER.*`**(`jetstream_api.go:388-389`)。

### 2.2 服务端为 KV 语义专门加的流选项

`StreamConfig` 里有多项是带着 KV 注释进来的,这是"服务端懂 KV"的直接证据:

```go
// server/stream.go:80-86
	// Allow higher performance, direct access to get individual messages. E.g. KeyValue
	AllowDirect bool `json:"allow_direct"`
	// Allow higher performance and unified direct access for mirrors as well.
	MirrorDirect bool `json:"mirror_direct"`

	// Allow KV like semantics to also discard new on a per subject basis
	DiscardNewPer bool `json:"discard_new_per_subject,omitempty"`
```

配合 `MaxMsgsPer int64`(每 subject 历史上限,`stream.go:61`)即可实现 KV 的 history Limit;`DiscardNewPer` 开启时要求 `MaxMsgsPer > 0`(`stream.go:2039-2043`)。此外还有 `AllowMsgTTL` 与 `SubjectDeleteMarkerTTL`(`stream.go:105-111`,见 §2.5)。bucket 的发布策略就是普通 subject 发布:客户端把 key 编码进 subject,流用 Subjects 通配覆盖,KV 专属的"发布策略"服务端一概不知情。

### 2.3 get:`DIRECT.GET.*.>` 就是给 KV 准备的

`$JS.API.DIRECT.GET.<stream>.<key>` 的注释点名了 KV:

```go
// server/jetstream_api.go:111-117
// This is a direct version of get last by subject, which will be the dominant pattern for KV access once 2.9 is released.
// The stream and the key will be part of the subject to allow for no-marshal payloads and subject based security permissions.
	JSDirectGetLastBySubject  = "$JS.API.DIRECT.GET.*.>"
	JSDirectGetLastBySubjectT = "$JS.API.DIRECT.GET.%s.%s"
```

服务端在流启动时为该端点挂内部订阅,并刻意用队列组让 mirror 也能"择优"参与(`stream.go:5233-5242`;mirror 侧对称实现 `stream.go:5260-5283`,这依赖 `MirrorDirect`,`stream.go:83`)。队列组名直接复用系统组,镜像需在追平(`dgetCaughtUpThresh`)后才可应答:

```go
// server/stream.go:727-731
// For mirrors and direct get
const (
	dgetGroup          = sysGroup
	dgetCaughtUpThresh = 10
)
```请求处理里,key 就是主题第 5 个 token 之后的部分——服务端源码里的注释就叫 "Extract the key":

```go
// server/stream.go:6105-6117(节选)
	// Extract the key.
	var key string
	for i, n := 0, 0; i < len(subject); i++ {
		if subject[i] == btsep {
			if n == 4 {
				if start := i + 1; start < len(subject) {
					key = subject[i+1:]
				}
				break
			}
			n++
		}
	}
```

随后请求被规约成 `LastFor = key`(`stream.go:6132-6134`),最终落到 `store.LoadLastMsg(req.LastFor, &svp)`(`stream.go:6326`);查不到时回一个 `404 Message Not Found` 裸头响应(`stream.go:6333`)——这正是 KV "key 不存在" 的服务端来源。整条路径无 JSON 编解码、直接回传原始消息(端点注释:`jetstream_api.go:105-107`)。批量/多 key 变体有专门的响应头模板与"批结束"标记:

```go
// server/stream.go:6146-6152(节选)
// For direct get batch and multi requests.
const (
	dg   = "NATS/1.0\r\nNats-Stream: %s\r\nNats-Subject: %s\r\nNats-Sequence: %d\r\nNats-Time-Stamp: %s\r\n\r\n"
	dgb  = "NATS/1.0\r\nNats-Stream: %s\r\nNats-Subject: %s\r\nNats-Sequence: %d\r\nNats-Time-Stamp: %s\r\nNats-Num-Pending: %d\r\nNats-Last-Sequence: %d\r\n\r\n"
	eob  = "NATS/1.0 204 EOB\r\nNats-Num-Pending: %d\r\nNats-Last-Sequence: %d\r\n\r\n"
	eobm = "NATS/1.0 204 EOB\r\nNats-Num-Pending: %d\r\nNats-Last-Sequence: %d\r\nNats-UpTo-Sequence: %d\r\n\r\n"
)
```

每条响应自带 `Nats-Stream/Subject/Sequence/Time-Stamp` 元数据头(`stream.go:6203-6213`),客户端凭这些就能重建"这是哪个 key 的第几版",服务端无需再包一层 JSON。这也解释了 KV delete(purge)后 get 得到 404、而 watch 端却能看到 marker 消息的分工:get 是"查无此人",watch 是"流里发生过什么"。

顺带把 history 的边界语义钉死:`MaxMsgsPer` 与 `MaxMsgs` 一样,0 或非法负值一律归一为 `-1`(不限),pedantic 模式下才对显式负值报错——即 KV bucket 不设 HistoryLimit 时,服务端按"每 key 无限历史"处理:

```go
// server/stream.go:1955-1960
	if cfg.MaxMsgsPer == 0 || cfg.MaxMsgsPer < -1 {
		if pedantic && cfg.MaxMsgsPer < -1 {
			return StreamConfig{}, NewJSPedanticError(fmt.Errorf("max_msgs_per_subject must be set to -1"))
		}
		cfg.MaxMsgsPer = -1
	}
```

### 2.4 put / delete / purge:CAS、rollup 与 `KV-Operation`

- put 的 CAS 基础:`Nats-Expected-Last-Subject-Sequence` 头(`stream.go:738-739`),服务端解析(`stream.go:5663-5674`)后用 `LoadLastMsg` 比对,不匹配报 `WrongLastSequence`(`stream.go:6709-6734`)。KV 的"仅当未变更时写入"与 ObjectStore 的 meta 更新都靠它。
- delete 是 put nil:客户端发一条空 payload 消息(带 `KV-Operation: Key-Delete` 头,nats.go 侧约定)。服务端只对一个特殊值有感知——`PURGE`:

```go
// server/stream.go:763-767
// Headers for published KV messages.
var (
	KVOperation           = "KV-Operation"
	KVOperationValuePurge = []byte("PURGE")
)
```

- purge 单个 key:要么发 `Nats-Rollup: sub` 头——服务端校验后置 `rollupSub`(`stream.go:6989-7018`),存储后执行对该 subject 的 `purgeLocked`(`stream.go:7467-7471`);要么走 `$JS.API.STREAM.PURGE.*` 带 `filter`(`jetstream_api.go:78-80`;请求结构含 `Subject`/`Keep`,`jetstream_api.go:546-552`)。bucket 整体 wipe 即 `Keep=0` 的全流 purge(或客户端删流重建)。

### 2.5 watch:就是 consumer,marker 也是普通消息

watch 没有任何专用服务端代码:客户端建 consumer(通常 ephemeral pull),`FilterSubject` 按 key 前缀过滤、`DeliverSubject`/pull 拉取、`FlowControl`/`HeadersOnly` 都是现成的 `ConsumerConfig` 字段(`consumer.go:89-142`,FilterSubject/FilterSubjects 见 100-101,pull 参数 111-113,push 参数 116-118)。拉取走 `$JS.API.CONSUMER.MSG.NEXT.<stream>.<consumer>`(`jetstream_api.go:157-158`),创建走 `CONSUMER.CREATE/DURABLE.CREATE`(`jetstream_api.go:123-131`)。关键在于:**删除 marker、TTL 过期 marker 都是写进流里的普通消息**,所以 watcher 无需额外协议就能看到"删除事件"——这是 watch 设计最巧的一点(见下节)。

### 2.6 TTL 与 wipe:per-message expiry 的存储实现

服务端 per-message TTL 的入口是 `Nats-TTL` 头(`stream.go:748`),支持秒数或 `never`(负数,永不过期):

```go
// server/stream.go:5680-5694(节选)
func getMessageTTL(hdr []byte) (int64, error) {
	ttl := getHeader(JSMessageTTL, hdr)
	if len(ttl) == 0 {
		return 0, nil
	}
	return parseMessageTTL(bytesToString(ttl))
}
// - Positive return value: duration in seconds.
// - Zero return value: no TTL or parse error.
// - Negative return value: never expires.
func parseMessageTTL(ttl string) (int64, error) {
	if strings.ToLower(ttl) == "never" {
		return -1, nil
	}
	...
```

流必须 `AllowMsgTTL` 才接受该头,否则发布被拒(`stream.go:6698-6706`)。存储层的实现(filestore 一句话:**每条带 TTL 的消息按到期时间戳挂进持久化的时间轮 `thw.db`(`filestore.go:357-358`,恢复时回填 `filestore.go:2417-2422`),`expireMsgs` 定时把到期消息删掉**)。`expireMsgs` 的主循环同时处理流级 MaxAge 与 per-message TTL,注意它对 `never`(-1)消息的跳过:

```go
// server/filestore.go:7316-7325(节选)
	if maxAge > 0 {
		var seq uint64
		for sm, seq, _ = fs.LoadNextMsg(fwcs, true, 0, &smv); sm != nil && sm.ts <= minAge; sm, seq, _ = fs.LoadNextMsg(fwcs, true, seq+1, &smv) {
			if len(sm.hdr) > 0 {
				if ttl, err := getMessageTTL(sm.hdr); err == nil && ttl < 0 {
					// The message has a negative TTL, therefore it must "never expire".
					minAge = ats.AccessTime() - maxAge
					continue
				}
			}
```

时间轮到期的消息统一收集后排序再删(`filestore.go:7353-7379`,注释说明 THW 无序必须按 seq 排序、且不能持锁处理),每条删除同样要过 SDM 判定,以便"最后一个走、留墓碑"。真正有意思的是 KV 专属的 subject delete marker(SDM):当一个 subject 的**最后一条**消息因 MaxAge/TTL 消失时,存储层不是默默删除,而是"提案"一条新消息顶上去当墓碑:

```go
// server/filestore.go:7451-7465(节选)
func (fs *fileStore) handleRemovalOrSdm(seq uint64, subj string, sdm bool, sdmTTL int64) {
	if sdm {
		var _hdr [128]byte
		hdr := fmt.Appendf(
			_hdr[:0],
			"NATS/1.0\r\n%s: %s\r\n%s: %s\r\n%s: %s\r\n\r\n",
			JSMarkerReason, JSMarkerReasonMaxAge,
			JSMessageTTL, time.Duration(sdmTTL)*time.Second,
			JSMsgRollup, JSMsgRollupSubject,
		)
		msg := &inMsg{subj: subj, hdr: hdr}
		fs.pmsgcb(msg)
```

这条 marker 同时带三件事:`Nats-Marker-Reason: MaxAge`(标记语义,`stream.go:749,795`)、`Nats-TTL`(marker 自己的寿命,即 `SubjectDeleteMarkerTTL`,`stream.go:109-111`)、`Nats-Rollup: sub`(触发对该 subject 的清场,`stream.go:789-790,7467-7471`)。它经 `pmsgcb` 回到流的发布路径重新走一遍(`stream.go:5493-5501`),因此集群模式下会进 Raft 提案、watcher 也能自然收到。发布侧还有约束:带 `SubjectDeleteMarkerTTL` 的流,普通消息 TTL 会被抬到不小于 marker TTL,防止 marker 被"漏掉"(`stream.go:7301-7310`);SDM 判定同时认 `Nats-Marker-Reason` 或 `KV-Operation: PURGE`(`sdm.go:40-44`),并有 2 秒去重窗口防止重复提案(`filestore.go:7423-7427`)。启动恢复时若配置了 SDM,则不能走静默批量过期,必须逐条走提案路径(`filestore.go:2736-2745`)。memstore 的对称实现见 `memstore.go:1531-1549`。

## 3. ObjectStore:`$OBJ` 在服务端只有"门牌号"

如实陈述:服务端没有任何 `$OBJ` handler,没有 meta/chunk 两流的名字约定,也没有 digest 计算。`$OBJ.>` 在服务端的全部存在感是:deny 列表(`jetstream_api.go:371-372`)与 domain 映射(`jetstream_api.go:395`)。两流布局(对象名→meta 流、chunk 编号→chunk 流)、默认 chunk 大小、SHA256 digest 校验、bucket TTL→流 `MaxAge`,均为 nats.go 客户端约定(不在本仓库,不标行号)。服务端为它提供的是积木:

- **meta 的 CAS 更新**:`Nats-Expected-Last-Subject-Sequence`(`stream.go:738`,校验 `stream.go:6709-6734`),对应 OBJ 的"上传完成前 meta 不可见/更新需比对序列";
- **chunk 的顺序性**:chunk 按 subject 递增编号写入,流序号天然单调;`MaxMsgSize`(`stream.go:62`)约束单 chunk 上限;
- **TTL**:既可以是流的 `MaxAge`(`stream.go:60`),也可以逐消息 `Nats-TTL`(§2.6),对象到期同样会触发 SDM marker;
- **get 无服务端聚合**:服务端只提供单条/批量直读(`getDirectMulti` 一次最多 1024 条响应,`stream.go:6155-6157`),按序吐出并在响应头补 `Nats-Stream/Subject/Sequence/Time-Stamp` 等元数据(`stream.go:6203-6213`);chunk 拼接与 digest 校验完全在客户端完成。
- **删除与 wipe**:OBJ 的对象删除(客户端约定为改写 meta 标记 + 通知 GC)最终落在服务端就是两条流的 purge;bucket 级 wipe 走 `$JS.API.STREAM.PURGE`,请求里 `filter`(按 subject)与 `keep`(保留条数)就是为这类按需清场准备的:

```go
// server/jetstream_api.go:546-552
type JSApiStreamPurgeRequest struct {
	// Purge up to but not including sequence.
	Sequence uint64 `json:"seq,omitempty"`
	// Subject to match against messages for the purge command.
	Subject string `json:"filter,omitempty"`
	// Number of messages to keep.
	Keep uint64 `json:"keep,omitempty"`
}
```

换言之,OBJ 的一切"对象语义"(名字索引、分块、校验、TTL 映射)都是客户端在两条普通流上排演出来的;服务端提供的只是原语正确、语义中立。

## 4. Micro:服务端零实现,纯客户端规范

本仓库(含 `server/`、`doc/`、`test/`)grep 不到任何 `$SRV`、`$JS.SRV` 或 micro 服务实现(0 命中,已核对)。Micro 是定义在 nats.go `micro` 包中的客户端规范:服务实例自行订阅 `$SRV.*` 族主题(PING/INFO/STATS 及按服务名、版本细分的变体),发现与调用就是**核心 NATS 的 request-reply**,无需服务端参与;KV/Object 好歹还逼出了服务端新特性,Micro 连这个都没有。服务端对它唯一的"贡献"是底层通信本身。因此本系列对 Micro 的深读对象应是 nats.go 客户端库,而非本仓库。

## 5. 三者的共同传输:全部走 request-reply

KV 的建流/建 consumer、OBJ 的两流操作、以及一切 `$JS.API` 调用,都压在同一条 API 干道上:`$JS.API.>` 的 catch-all 订阅(`jetstream_api.go:41,1106-1109`)+ 显式 handler 表(`jetstream_api.go:1118-1142`),并以 ServiceExport 暴露给全部账号(`jetstream_api.go:1111-1114`);跨 domain 时由映射表改写前缀(`jetstream_api.go:374-398`)。响应统一是 `ApiResponse{Type, Error}`(`jetstream_api.go:422-426`)。`$KV.>`/`$OBJ.>` 作为"命名空间品牌"并不承载服务端语义——真正的语义载体始终是 `$JS.API` 与普通主题发布。

## 6. 与核心 NATS 的衔接(小结)

| 机制 | 服务端落点 | 关键代码 |
|---|---|---|
| KV get | DIRECT.GET last-by-subject,raw 直返 | `stream.go:5223-5242, 6084-6143, 6326` |
| KV put CAS | Expected-Last-Subject-Sequence | `stream.go:738, 6709-6734` |
| KV history | MaxMsgsPer / DiscardNewPer | `stream.go:61, 85-86, 2039-2043` |
| KV delete/purge | KV-Operation: PURGE / Rollup sub / PURGE API | `stream.go:763-767, 7467-7471` |
| KV watch | 普通 consumer,marker 即消息 | `consumer.go:89-142` |
| TTL | Nats-TTL + 时间轮 + SDM marker | `stream.go:748, 5680-5711`;`filestore.go:7451-7469` |
| OBJ meta CAS | 同 put CAS | `stream.go:6709-6734` |
| OBJ 直读 | DIRECT.GET(单条/批量 ≤1024) | `stream.go:6155-6157, 6203-6213` |

## 7. 设计动机

1. **为什么 KV 建在 stream 上(而不是独立存储)?** KV 的全部语义——历史版本、每 key 限制、复制、持久化、权限——都能约化为流参数(`MaxMsgsPer`、`DiscardNewPer`、Replicas、Subjects),服务端只需加少量"加速器"(AllowDirect 等,`stream.go:80-86`)。一份存储引擎、一套 Raft 复制、一个 API 面复用于所有 view,这是 JetStream "物化视图"定位的本质(注释自认 materialized views,`jetstream_api.go:379`)。
2. **为什么 get 走 DIRECT.GET 而不是 consumer?** 把 stream 和 key 编进主题(`jetstream_api.go:111-112`),一来免 JSON 编解码直返原始消息(低延迟),二来权限直接复用核心 NATS 的 subject 级授权;队列组还让 mirror 可择优就近应答(`stream.go:5236`)。
3. **为什么 delete/purge 用 rollup 与 marker?** 删除若只是"原地抹掉",watcher 无从得知、多副本也难一致。服务端把删除变成"发布一条带 `Nats-Rollup: sub` 的墓碑消息"(`stream.go:7467-7471`),清场与通知合二为一;TTL 过期同理,由存储层提案 marker(`filestore.go:7451-7469`)并回流发布路径进 Raft(`stream.go:5493-5501`)。
4. **为什么 per-message TTL 要做进存储层时间轮?** KV 的 key 过期必须不依赖客户端在线。到期时间持久化在 `thw.db`(`filestore.go:357-358`)、重启恢复回填(`filestore.go:2417-2422`),且 SDM 配置下放弃启动期静默清理、坚持走提案(`filestore.go:2741-2745`),保证"过期即事件"在集群与重启后仍然成立。
5. **为什么 watch 用 consumer?** consumer 自带回放起点(DeliverPolicy)、按 key 过滤(FilterSubject)、流控与心跳(consumer.go:107-118),watch 的"从历史开始/只看新值"就是 DeliverPolicy 的两种取值;零新增协议。
6. **为什么 ObjectStore 存两流?** meta 是小而频繁 CAS 更新的热数据(对象树),chunk 是大而只追加的冷数据;分流后 meta 流可用 per-subject 保留只留最新版,chunk 流纯追加按 seq 校序,两者保留策略、TTL、清理互不牵连。服务端不给聚合,是因为 digest 校验必须发生在数据端(客户端)而非转发端,聚合并不能省带宽。
7. **为什么 Micro 放客户端?** 微服务的路由、负载均衡、版本协商都是"主题命名约定"就能解决的事,核心 NATS 的 subject 通配 + request-reply 已是完备传输;放服务端只会引入第二个 API 面和状态,违背"机制在服务端、策略在边缘"的一贯取舍。

## 8. 写作素材清单(文件:行号)

1. `server/jetstream_api.go:371-372` — `$KV.>`/`$OBJ.>` deny 列表
2. `server/jetstream_api.go:376-397` — domain 映射表及"materialized views"注释
3. `server/stream.go:80-86` — AllowDirect("E.g. KeyValue")/MirrorDirect/DiscardNewPer
4. `server/stream.go:61,105-111` — MaxMsgsPer、AllowMsgTTL、SubjectDeleteMarkerTTL
5. `server/jetstream_api.go:105-117` — DIRECT.GET last-by-subject 端点与 KV 注释
6. `server/stream.go:5223-5242,5260-5283` — 直接读订阅(含 mirror 队列组)
7. `server/stream.go:6105-6134` — "Extract the key" 与 LastFor 规约
8. `server/stream.go:6326,6333` — LoadLastMsg 与 404 Message Not Found
9. `server/stream.go:738,5663-5674,6709-6734` — per-subject CAS
10. `server/stream.go:763-767` — KV-Operation: PURGE 头
11. `server/stream.go:6989-7018,7467-7471` — rollup 校验与 rollup purge
12. `server/stream.go:748,5680-5711` — Nats-TTL 解析(含 never)
13. `server/stream.go:6698-6706,7301-7310` — TTL 门禁与 marker 最小 TTL 抬升
14. `server/filestore.go:357-358,2417-2422,7316-7361` — thw.db 时间轮与过期循环
15. `server/filestore.go:7451-7469;server/memstore.go:1531-1549;server/sdm.go:40-44` — SDM marker 生成与判定
16. `server/stream.go:5493-5501;server/filestore.go:2736-2745` — marker 回流发布路径;恢复期不静默过期
17. `server/consumer.go:89-142;server/jetstream_api.go:123-131,157-158` — watch 的 consumer 配置与端点
18. `server/jetstream_api.go:41,1106-1142,422-426` — `$JS.API.>` dispatch、handler 表、统一响应

(每条均经本次 Read/Grep 核对;nats.go 客户端侧约定——KV_/OBJ_ 流名、chunk 大小、SHA256、`$SRV` 主题族——不在本仓库,文中已如实标注。)
