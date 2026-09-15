# I — S3 API 层:MinIO 的 HTTP 面实现

> 《MinIO 深读》卷二 第 3 章 | 源码:minio/minio @ commit `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`(下文行号均以此 commit 为准,仓库相对路径)

MinIO 没有依赖任何 "S3 server 框架",S3 API 完全自实现:`cmd/api-router.go` 用一个薄封装的 mux 路由树把 HTTP 方法 + 路径 + 子资源查询参数映射到约 80 个 handler 方法上,`cmd/object-handlers.go`、`cmd/bucket-handlers.go`、`cmd/object-multipart-handlers.go` 承载协议语义,再向下调用 `ObjectLayer` 接口(纠删码实现见卷一 B)。本章沿"路由 → 中间件 → PutObject 全链 → 分片上传 → ListObjects → 错误响应"逐层拆解。

---

## 1. 全景:S3 API 路由树

### 1.1 路由挂载点

S3 API 路由在 `configureServerHandler`(cmd/routers.go:84)里注册:`registerAPIRouter(router)`(cmd/routers.go:110)。关键细节是 router 创建时 `SkipClean(true).UseEncodedPath()`(cmd/routers.go:87)——禁止 mux 规范化 URL 路径,否则对象名里的 `//`、`./` 会被静默改写,违背 S3 语义(注释引用了 minio#3256)。

全局中间件链 `globalMiddlewares`(cmd/routers.go:54-81)按序为:addCustomHeadersMiddleware(补 `x-amz-request-id`)→ httpTracerMiddleware → setAuthMiddleware(鉴权前置)→ setBrowserRedirectMiddleware → setCrossDomainPolicyMiddleware → setRequestLimitMiddleware(限制 body/header 上限)→ setRequestValidityMiddleware → setUploadForwardingMiddleware → setBucketForwardingMiddleware。

### 1.2 路由树 ASCII 图

```
mux.Router (SkipClean, UseEncodedPath)                      routers.go:87
│
├── /minio/admin/*        Admin API      admin-router.go
├── /minio/health/*       健康检查        healthcheck-router.go
├── /minio/metrics/*      指标           metrics-router.go
├── /sts/*                STS            sts-handlers.go
├── /kms/*                KMS            kms-router.go
├── storage REST / grid / peer            routers.go:28-51 (分布式内部)
│
└── apiRouter = PathPrefix("/")  ──────────────────────────  api-router.go:262
    │
    ├─ [虚拟主机风格] Host: {bucket}.<domain>              api-router.go:264-289
    ├─ [路径风格]     PathPrefix("/{bucket}")             api-router.go:289
    │   │
    │   ├── 对象级  Path("/{object:.+}")                   api-router.go:300-408
    │   │   ├── HEAD                 → HeadObjectHandler          :302
    │   │   ├── GET  ?attributes     → GetObjectAttributesHandler :306
    │   │   ├── PUT  ?partNumber&uploadId → PutObjectPartHandler  :316
    │   │   ├── GET  ?uploadId       → ListObjectPartsHandler     :320
    │   │   ├── POST ?uploadId       → CompleteMultipartUploadHandler :324
    │   │   ├── POST ?uploads        → NewMultipartUploadHandler  :328
    │   │   ├── DELETE ?uploadId     → AbortMultipartUploadHandler:332
    │   │   ├── GET/PUT ?tagging     → 对象 Tagging               :344-354
    │   │   ├── POST ?select         → SelectObjectContent        :356
    │   │   ├── GET/PUT ?retention|legal-hold → ObjectLock       :359-385
    │   │   ├── PUT + X-Amz-Copy-Source → CopyObjectHandler       :375
    │   │   ├── PUT + X-Minio-Extract   → PutObjectExtractHandler :388
    │   │   ├── PUT                  → PutObjectHandler           :398
    │   │   ├── DELETE               → DeleteObjectHandler        :402
    │   │   └── POST ?restore        → PostRestoreObjectHandler   :406
    │   │
    │   └── 桶级  (无 Path,匹配桶根)                       api-router.go:410-627
    │       ├── GET ?location|policy|lifecycle|encryption|... → 各桶配置读 :413-451
    │       ├── GET ?list-type=2[&metadata=true] → ListObjectsV2[M] :509-515
    │       ├── GET ?versions[&metadata=true]    → ListObjectVersions[M] :517-523
    │       ├── GET ?uploads          → ListMultipartUploadsHandler :505
    │       ├── GET (无子资源)        → ListObjectsV1Handler       :626
    │       ├── PUT ?policy|tagging|versioning|... → 各桶配置写 :529-565
    │       ├── PUT (无子资源)        → PutBucketHandler           :568
    │       ├── HEAD                  → HeadBucketHandler          :571
    │       ├── POST (PostPolicy V4 签名) → PostPolicyBucketHandler :574
    │       ├── POST ?delete          → DeleteMultipleObjectsHandler :580
    │       └── DELETE                → DeleteBucketHandler        :600
    │
    └── 根路径 GET "/"  → ListBucketsHandler                api-router.go:638
        GET "//"        → ListBucketsHandler(兼容 S3 browser)  api-router.go:643
    NotFoundHandler / MethodNotAllowedHandler → 错误 XML        api-router.go:647-648
```

三个值得注意的路由机制:

- **子资源即路由**:mux 的 `Queries("uploads","")` 等谓词把子资源查询参数变成了路由匹配的一部分,`POST /bucket/object?uploads` 与 `POST /bucket/object?uploadId=...` 落到不同 handler(api-router.go:324-330)。这是"一个 URL 无数语义"的 S3 风格最自然的表达方式。
- **顺序敏感**:路由注册顺序即匹配优先级。`ListObjectsV2M`(?list-type=2&metadata=true,MinIO 扩展的"带元数据列表")必须注册在 `ListObjectsV2` 之前(api-router.go:509-515);兜底的 `ListObjectsV1Handler` 放在最后(api-router.go:626),吞掉所有未匹配子资源的 GET——因为 V1 就是"裸 GET /bucket"。
- **显式拒绝清单**:`rejectedObjAPIs`/`rejectedBucketAPIs`(api-router.go:93-169)对 torrent、acl(对象)、inventory、cors(写)、metrics 等不支持的 API 返回 `ErrNotImplemented`(notImplementedHandler,api-router.go:82),而不是让它们落进语义错误的兜底路由。

### 1.3 每个 handler 的统一包装:s3APIMiddleware

所有 S3 handler 都经 `s3APIMiddleware` 包装(api-router.go:210-252),它用反射取出 handler 名,再套四层:trackingResponseWriter → httpTraceHdrs/httpTraceAll(按 flag 决定只 trace 头还是连 body)→ gzipHandler(可用 noGZS3HFlag 关)→ maxClients 并发限流(可用 noThrottleS3HFlag 关,如 ListenNotification)→ collectAPIStats(按 API 名统计)。大流量 PUT/GET 都传了 `traceHdrsS3HFlag`,注释明确说明原因:trace 整个 body 会造成高内存占用(api-router.go:205-209)。

---

## 2. PutObject 全链:HTTP → 鉴权 → 加密 → EC 写入

以 `PutObjectHandler`(cmd/object-handlers.go:1793)为主线,给出完整调用链。它是整个 S3 API 层最"全"的 handler,几乎每一类前置逻辑都在这里出现。

### 2.1 前置校验段(1793-1955)

1. `newContext` + 审计日志(cmd/object-handlers.go:1794-1795;newContext 定义在 cmd/utils.go:791)。
2. `api.ObjectAPI()` 为 nil → `ErrServerNotInitialized`(:1797-1801)。每个 handler 的第一件事都是这个判空,因为对象层是异步初始化的。
3. 取路由变量:`bucket := vars["bucket"]`,`object := unescapePath(vars["object"])`(:1803-1809;unescapePath 在 cmd/utils.go:758)——配合 `SkipClean`,Percent-Encoding 在这里才被还原。
4. 拒绝 Copy-Source 头(:1812)、校验 StorageClass(:1818)、解析 Content-MD5(:1825)。
5. Content-Length:streaming 签名类请求改读 `X-Amz-Decoded-Content-Length`(:1832-1848),`size == -1` 直接 `ErrMissingContentLength`(:1849);超 5TB(`globalMaxObjectSize`,cmd/utils.go:289)返回 `ErrEntityTooLarge`(:1855)。
6. `extractMetadataFromReq`(cmd/handler-utils.go:144)抽取 `x-amz-meta-*` 等元数据(:1860),Tags 解析(:1866)。

### 2.2 鉴权段(1883-1919,呼应 G 报告)

先做策略检查 `isPutActionAllowed(ctx, rAuthType, bucket, object, r, policy.PutObjectAction)`(cmd/object-handlers.go:1884;实现 cmd/auth-handler.go:722),再按签名类型分流(:1889-1919):

- streaming v4(`authTypeStreamingSigned`/`Trailer`):`newSignV4ChunkedReader` 把 body 包成边读边验签的 reader(:1890-1896);
- streaming unsigned trailer:`newUnsignedV4ChunkedReader`(:1897-1903);
- V2:`isReqAuthenticatedV2`(:1904);V4/V4-presign:`reqSignatureV4Verify` + 取 `x-amz-content-sha256`(:1911-1918)。

对比其他 handler 的简单路径:`checkRequestAuthType`(cmd/auth-handler.go:338)→ `checkRequestAuthTypeCredential`(:522)= `authenticateRequest`(验签,:357)+ `authorizeRequest`(IAM/桶策略,:418)。PutObject 之所以手写展开,是因为 streaming 类型不能走 `authenticateRequest`(body 是签名块流,不能整体 hash,只能包装成 chunked reader 逐块验)。全局层面 `setAuthMiddleware`(cmd/auth-handler.go:616)在路由之前已拒绝缺日期/时钟偏移超限(`globalMaxSkewTime`)/不支持的签名版本的请求(:623-653, :672)。

### 2.3 配额、桶加密、压缩段(1927-2011)

- 硬配额 `enforceBucketQuotaHard`(:1927);副本写请求补 Replica 元数据(:1931-1939)。
- **桶级默认加密**:`globalBucketSSEConfigSys.Get(bucket)` + `sseConfig.Apply(r.Header, ...)`(:1941-1945)——即使客户端没带 SSE 头,桶策略也能注入加密请求,这是 H 报告讲的 SSE-S3 自动加密入口。
- `putOptsFromReq`(cmd/object-api-options.go:321)生成 `ObjectOptions`(:1951)。
- **S2 压缩**:满足条件(`isCompressible` 且大于 `minCompressibleSize`)时包装压缩 reader、记录 `actual-size`、`size = -1`(:1959-1985)。
- 组装 `hash.Reader`(MD5/SHA256 边读边算,:1993-2004)→ `PutObjReader`(:2013-2014)。

### 2.4 条件写、Object Lock、复制标记(2017-2052)

If-Match/If-None-Match 挂成 `opts.CheckPrecondFn` 回调(:2020-2030,真正的检查在 erasure 层执行,见 2.6);`checkPutObjectLockAllowed` 校验 retention/legalHold 并写入元数据(:2037-2048);`mustReplicate` 打上 Pending 复制标记(:2049-2052)。

### 2.5 加密段(2053-2100,呼应 H 报告)

```
cmd/object-handlers.go:2053    var objectEncryptionKey crypto.ObjectKey
:2054                          if crypto.Requested(r.Header) {         // SSE 头三选一校验
:2070                              reader, objectEncryptionKey, err = EncryptRequest(hashReader, r, bucket, object, metadata)
:2083                              hashReader = hash.NewReader(ctx, etag.Wrap(reader, hashReader), wantSize, ...)
:2088                              pReader, err = pReader.WithEncryption(hashReader, &objectEncryptionKey)
:2096                              opts.EncryptFn = metadataEncrypter(objectEncryptionKey)  // 元数据也要加密
:2100                          crypto.RemoveSensitiveEntries(metadata)
```

`EncryptRequest` 生成对象密钥并把明文流包成加密流;ETag 从此变成"密文 ETag",写响应时要解回(:2127-2148)。压缩索引若存在,还要再过一层 `compressionIndexEncrypter`(:2093-2095)。这里完整体现了"加密是 handler 层与存储层之间的一道 reader 变换",存储层拿到的永远只是字节流。

### 2.6 EC 写入段(2112,呼应卷一 B)

```
cmd/object-handlers.go:2112    objInfo, err := putObject(ctx, bucket, object, pReader, opts)
```

注意这里的 `putObject` 是局部变量 `putObject = objectAPI.PutObject`(:1880),即 `ObjectLayer` 接口方法(cmd/object-api-interface.go:27)。进入纠删码实现 `erasureObjects.PutObject`(cmd/erasure-object.go:1249)→ `putObject`(:1254):

- 条件前置回调在此执行:`opts.CheckPrecondFn` + NSLock(:1261-1286);
- 按 StorageClass/在线盘数动态定 parity(:1299-1333),`writeQuorum = dataDrives`(data==parity 时 +1)(:1338-1341);
- 初始化 `partsMetadata`、`fi.DataDir`、临时对象 UUID(:1343-1360);
- EC 编码写入临时对象(`erasure.Encode`,:1183/:1440 两处按大小分路径);
- **提交即改名**:`renameData(ctx, onlineDisks, minioMetaTmpBucket, tempObj, partsMetadata, bucket, object, writeQuorum)`(cmd/erasure-object.go:1564)——"先写 .minio.sys/tmp 再原子 rename 到最终位置",这是 B 报告详述的写路径;`commitRenameDataDir` 清旧目录(:1577)。

回到 handler:写成功后处理加密 ETag 回填(:2126-2148)、`setPutObjHeaders`(:2154)、发 `ObjectCreatedPut` 事件(:2156-2166)、版本数过多时补发 `ObjectManyVersions` 事件(:2167-2179)、`writeSuccessResponseHeadersOnly`(:2183)——PUT 成功响应没有 body,只有 ETag 等响应头。

---

## 3. 分片上传专节:multipart 元数据组织与 Complete 组装

### 3.1 存储布局

```
.minio.sys/                                ← minioMetaBucket      cmd/object-api-utils.go:59
└── multipart/                             ← mpartMetaPrefix      cmd/object-api-utils.go:61
    └── <sha256(bucket/object)>/           ← getMultipartSHADir   cmd/erasure-multipart.go:59-61
        └── <uploadUUID>x<unixnano>/       ← getUploadIDDir       cmd/erasure-multipart.go:47-57
            ├── xl.meta                    (上传级元数据:初版 FileInfo)
            └── <fi.DataDir>/
                ├── part.1                 (EC 分片数据)
                ├── part.1.meta            (msgpack 序列化的 ObjectPartInfo)
                └── part.N ...
```

uploadID 本身不是裸 UUID:`uploadUUID = mustGetUUID()+x+纳秒时间戳`,再 base64 RawURLEncoding 拼上 `globalDeploymentID()`(cmd/erasure-multipart.go:506-507);getUploadIDDir 解码还原(cmd/erasure-multipart.go:49-55)。桶/对象名用 SHA256 而非明文做目录,避免特殊字符与超长路径。`cleanupStaleUploads`(cmd/erasure-multipart.go:134)后台清理僵尸上传。

### 3.2 NewMultipartUpload

Handler(cmd/object-multipart-handlers.go:64)做鉴权(:83)、SSE 配置注入(:89)、加密元数据准备并打上 `Encrypted-Multipart` 标记(:104-142)、Object Lock(:168)、复制(:180),最后调 `objectAPI.NewMultipartUpload`(:230-232)。纠删码实现 `newMultipartUpload`(cmd/erasure-multipart.go:376)核心是:按 StorageClass 定 parity(:411)、初始化 FileInfo(:457-462)、生成 uploadID(:506-507)、把初版元数据写到所有盘的 multipart 目录(`writeAllMetadata`,:511)。响应只含 UploadID(`generateInitiateMultipartUploadResponse`,cmd/api-response.go:783)。

### 3.3 UploadPart(PutObjectPart)

Handler(cmd/object-multipart-handlers.go:590):解析 uploadID/partNumber(:647-654),partID > 10000(`globalMaxPartID`,cmd/utils.go:296)拒绝(:663);鉴权与验签同 PutObject(:674-708)。纠删码实现 `PutObjectPart`(cmd/erasure-multipart.go:575):

1. `checkUploadIDExists`(:589,实现 :64)跨盘读上传元数据并重算 quorum——uploadID 验证本质上是一次跨盘元数据读;
2. 数据先 EC 编码写到 `.minio.sys/tmp/<uuid>x<nano>/part.N`(:614-675);
3. 构建 `ObjectPartInfo{Number, ETag, Size, ActualSize, Checksums...}` 并 `MarshalMsg` 成 part.N.meta(:728-741);
4. 对 partID 加写锁、对 uploadID 加读锁(:744-760),然后 `renamePart` 把临时分片原子改名进 multipart 目录(:762,实现 :536)。

### 3.4 CompleteMultipartUpload

Handler(cmd/object-multipart-handlers.go:914):要求 ContentLength > 0(:946)、解析 XML parts 列表(:952)、**parts 必须已按 PartNumber 升序**,否则 `ErrInvalidPartOrder`(:961-966);按 S3 公式预计算 multipart ETag `MD5(ETag_1..ETag_n)+"-N"`(:1001-1018,etag.Multipart)。纠删码实现 `CompleteMultipartUpload`(cmd/erasure-multipart.go:1096)的组装逻辑:

1. `checkUploadIDExists`(:1128)读上传元数据;
2. 读全部 `part.N.meta`(`readParts`,:1142-1150);
3. 加密场景恢复对象密钥并解密比对 ETag(:1187-1215,注释解释了密文 ETag 与客户端 ETag 不匹配的原因);
4. 逐片校验:partNumber 对得上(:1224)、ETag 一致(:1268-1277)、可选 checksum 校验(:1279-1316)、**除最后一片外每片 ≥ 5MB**(`isMinAllowedPartSize`,cmd/utils.go:305;检查在 :1318-1325,违者 `PartTooSmall`);
5. 累计 objectSize/objectActualSize,生成最终 `fi.Parts`(:1333-1342),写回 `fi.Metadata["etag"]`(:1393-1399);
6. 清理未列入 Complete 的分片(:1427-1441),持 NSLock 后 `cleanupMultipartPath` + `renameData` 把整个上传目录**原子改名**为最终对象(:1453-1466),成功后 `deleteAll` 清空 uploadID 目录(:1455-1459)。

"Complete = rename"是 MinIO multipart 的精髓:各分片早已 EC 落盘,Complete 只做元数据合并与目录改名,不搬数据。AbortMultipartUpload(cmd/erasure-multipart.go:1517)则直接删目录。

---

## 4. ListObjects 专节:V1/V2/Versions/带元数据 四种列表的分页语义

路由层四个入口(api-router.go:509-523, :626)对应 handler 三套:`ListObjectsV2Handler`/`ListObjectsV2MHandler`(cmd/bucket-listobjects-handlers.go:141/154,共用实现 :160)、`ListObjectVersionsHandler`/`MHandler`(:62/66,实现 :73)、`ListObjectsV1Handler`(:273)。参数解析在 cmd/api-resources.go:`getListObjectsV1Args`(:27)、`getListObjectsV2Args`(:69)、`getListBucketObjectVersionsArgs`(:47);每页上限 `maxObjectList = 1000`(cmd/api-response.go:43)。

### 4.1 V1:marker 就是上页最后一个 Key

`prefix/marker/delimiter/max-keys`(cmd/api-resources.go:27-45)。Handler(:273)直接把 marker 传给 `objectAPI.ListObjects`(:305-310)。语义:`NextMarker = 本页最后一条的 Key`,客户端下次带 `?marker=它` 续传。

### 4.2 V2:continuation-token(不透明 token)+ start-after

`getListObjectsV2Args`(cmd/api-resources.go:69-105)的三条规则:

- `continuation-token` 存在但为空串 → `ErrIncorrectContinuationToken`(:73-78);
- token 是 **base64 标准编码**的不透明串,先 `base64.StdEncoding.DecodeString` 还原成内部 marker(:96-103);
- `start-after` 仅在首屏生效(有 token 时被忽略)。

纠删码层的转换逻辑一目了然(cmd/erasure-server-pool.go:1372-1391):

```go
func (z *erasureServerPools) ListObjectsV2(ctx ..., continuationToken, delimiter string,
        maxKeys int, fetchOwner bool, startAfter string) (ListObjectsV2Info, error) {
    marker := continuationToken
    if marker == "" {
        marker = startAfter        // token 优先,start-after 只是首屏起点
    }
    loi, err := z.listObjectsGeneric(ctx, bucket, prefix, marker, delimiter, maxKeys, false)
    ...
    listObjectsV2Info := ListObjectsV2Info{
        ...
        NextContinuationToken: loi.NextMarker,   // 复用 V1 的 marker 当 token
    }
```

即:**V2 的 continuation-token 内部就是 V1 的 marker(再经 opts.encodeMarker 编码,cmd/erasure-server-pool.go:1552-1554)**,V2 只是把翻页状态从"客户端可读的 Key"变成"服务端可解释的不透明串"。`NextMarker` 取本页最后一条 Key(:1541-1544);若 ILM 已删除对象留下的"跳过条目"字典序更高,则用它前移,减少下一页扫描(:1546-1550)。另一个细节:`maxKeysPlusOne` 多取一条用于判断 IsTruncated(cmd/erasure-server-pool.go:1476-1484)。

### 4.3 字典序语义

列表本质上是对 `xl.meta` 命名空间按 Key 字节序归并的多路遍历:`listObjectsGeneric`(cmd/erasure-server-pool.go:1486)构造 `listPathOptions{Prefix, Separator, Marker, Limit}` 后调 `z.listPath` 归并各 pool/set 的结果(`merged.forwardPast(opts.Marker)` 从 marker 之后推进,:1507),`merged.fileInfos(bucket, prefix, delimiter)` 按 delimiter 切出 CommonPrefixes(:1515-1540)。V2M(`?metadata=true`)额外带 `checkObjMeta` 回调,对每个返回对象单独做 `s:GetObject` 授权(cmd/bucket-listobjects-handlers.go:177-182)——"列表桶级鉴权一次 + 对象级逐个鉴权"的 MinIO 扩展语义。

### 4.4 校验规则与 ListBuckets

`validateListObjectsArgs`(cmd/bucket-listobjects-handlers.go:38-60):maxKeys 非负、encoding-type 只许 `url`、**marker 必须以 prefix 开头**(否则 `ErrNotImplemented`,比 AWS 更严格)。`ListBucketsHandler`(cmd/bucket-handlers.go:305)支持匿名+策略过滤:先列表,若鉴权结果是 `ErrAccessDenied` 则逐桶用 `s:ListBucket`/`s:GetBucketLocation` 过滤,过滤后为空才报错(:359-402)。

---

## 5. 错误响应专节:S3 错误 XML 的结构化生成

### 5.1 三层结构:错误码枚举 → APIError → XML

- `APIErrorCode` 是 int 枚举(cmd/api-errors.go:85 起,数百个),`stringer` 生成名字(:81);
- `errorCodeMap`(cmd/api-errors.go:457)把枚举映射为 `APIError{Code, Description, HTTPStatusCode}`(:55-61),静态表在 :482 起。例如 `ErrAccessDenied`(:543)、`ErrInvalidAccessKeyID`(:593)、`ErrNoSuchBucket`(:653)、`ErrSignatureDoesNotMatch`(:718)、`ErrSignatureVersionNotSupported`(:763);
- `APIErrorResponse`(cmd/api-errors.go:64-76)是最终 XML:

```go
type APIErrorResponse struct {
    XMLName          xml.Name `xml:"Error" json:"-"`
    Code             string
    Message          string
    Key              string `xml:"Key,omitempty" ...`
    BucketName       string `xml:"BucketName,omitempty" ...`
    Resource         string
    Region           string `xml:"Region,omitempty" ...`
    RequestID        string `xml:"RequestId" ...`
    HostID           string `xml:"HostId" ...`
    ...
}
```

### 5.2 生成路径

统一出口 `writeErrorResponse(ctx, w, err APIError, reqURL)`(cmd/api-response.go:957):503/429 加 `Retry-After: 60`(:958-963);InvalidRegion/AuthorizationHeaderMalformed 动态补上本机 region 描述(:965-970);最后 `getAPIErrorResponse`(cmd/api-errors.go:2625)填 RequestId/HostId(来自响应头,由 addCustomHeadersMiddleware 早期写入)并 `encodeResponse` + `writeResponse`(mimeXML,:981-982)。Handler 里的标准用法是两行:

```go
if s3Err != ErrNone {
    writeErrorResponse(ctx, w, errorCodes.ToAPIErr(s3Err), r.URL)   // errorCodes.ToAPIErr: api-errors.go:476
    return
}
```

Go 层错误(internal/error)到 S3 错误的翻译在 `toAPIError`(cmd/api-errors.go:2462):逐类匹配 StorageError/对象层错误;翻译不了的兜底 `InternalError` 并打内部日志(:2605-2610)——外部只见 InternalError,内部日志留全量 cause,这是安全与可排障的平衡。鉴权类错误码(`ErrSignatureDoesNotMatch` 等)由验签函数直接返回(如 cmd/streaming-signature-v4.go:171、cmd/auth-handler.go 内多处),经同一出口渲染成 XML,即 G 报告所述鉴权失败响应的最终形态。此外还有三个变体:`writeErrorResponseHeadersOnly`(HEAD 请求,cmd/api-response.go:985,顺带写 `X-Minio-Error-Code/Description` 头)、`writeErrorResponseJSON`(Admin API,:998)。

---

## 6. 设计动机

**为什么完全自实现 S3 而不用库?** S3 协议的重心不在"URL 到函数的映射"(那部分 mux 三百行就写完了),而在大量非标准语义:子资源查询参数路由化(api-router.go 的 `Queries` 谓词)、`SkipClean` 保留原始路径(cmd/routers.go:87)、streaming v4 的逐块验签必须以 reader 包装形式插入 body 读取路径(cmd/object-handlers.go:1892)——任何通用框架都会在这些点打架。自实现还让每个 handler 都能精确控制中间件组合(s3APIMiddleware 的 per-handler flags,api-router.go:210),比如 GET/PUT 关 trace-body 防止内存放大。Go 生态当年也没有可用的 S3 server 库(事实上 MinIO 后来反哺出了 minio-go 客户端与 S3-Kafka-网关生态)。

**streaming v4 的处理哲学:验签下沉为 reader。** `newSignV4ChunkedReader`(cmd/streaming-signature-v4.go:195)先用 seed signature 验证请求头(calculateSeedSignature,:101),之后 `s3ChunkedReader.Read`(:264)边解析 `size;chunk-signature=...\r\n` 帧边算 SHA256、逐块与声明签名比对(:386-391,链条式:每个 chunk 签名以土个签名为种子,:54-73),trailer 变体则额外校验 `x-amz-trailer-signature`(:507-523)。好处:内存 O(chunk 上限 16MB,:187),且验签失败发生在数据入库前;代价:handler 里的鉴权代码必须按 authType 手工展开(PutObject 与普通 handler 的两套写法,见 2.2)。

**multipart 为什么是"目录 rename"而不是"索引提交"?** 见 3.4:分片按 EC 落盘、元数据 msgpack 化、Complete 用 `renameData` 原子切换。这让 Complete 的耗时与对象大小无关(GB 级视频与 10MB 分片一样快),abort/清理也只是删目录(erasure-multipart.go:1517 起)。上传目录用 SHA256(bucket/object) 做键、uploadID 内嵌 deploymentID 与时间戳(:506-507),既防冲突又便于 `cleanupStaleUploads` 按时间清僵尸。

**continuation-token 为什么 base64 而非明文?** 让 token 成为不透明串,内部可以自由演进(marker 编码、pool/set 提示位等,`opts.encodeMarker`,cmd/erasure-server-pool.go:1552-1554),客户端只能原样回传;同时天然规避了特殊字符的 encoding-type=url 转义问题。

---

## 7. FAQ 素材

1. **MinIO 的 S3 API 用什么路由库?** MinIO 自己 fork 维护的 `github.com/minio/mux`(gorilla/mux 分支),注册入口 `registerAPIRouter`(cmd/api-router.go:255),`SkipClean(true)` 是灵魂(cmd/routers.go:87)。
2. **一个 PUT /bucket/object 请求会经过多少层?** 全局中间件 9 层(cmd/routers.go:54-81)+ s3APIMiddleware 4 层(api-router.go:220-248)+ handler 内 8 段校验(cmd/object-handlers.go:1793-2112)+ ObjectLayer。
3. **为什么 GET/PUT handler 都传 traceHdrsS3HFlag?** trace body 会把整个请求体留在内存里做追踪记录,大对象场景内存翻倍(api-router.go:205-209 注释)。
4. **ListObjectsV2 的 continuation-token 里是什么?** base64 后的内部 marker,本质是上页最后一条 Key(cmd/api-resources.go:96-103 + cmd/erasure-server-pool.go:1385-1386)。
5. **start-after 和 continuation-token 同时给,谁生效?** token 优先;start-after 只在无 token 的首屏生效(cmd/erasure-server-pool.go:1373-1376)。
6. **分片最小 5MB 在哪强制?** Complete 时校验,除最后一片外 `isMinAllowedPartSize` 不过即 `PartTooSmall`(cmd/erasure-multipart.go:1318-1325)。
7. **multipart 元数据在哪?** `.minio.sys/multipart/<sha256(bucket/object)>/<uploadUUID>/`,uploadID 是 base64(deploymentID.uuidx纳秒)(cmd/object-api-utils.go:59-63、cmd/erasure-multipart.go:47-61, :506-507)。
8. **CompleteMultipartUpload 为什么要求 parts 有序?** handler 直接拒绝无序列表 `ErrInvalidPartOrder`(cmd/object-multipart-handlers.go:961-966),纠删码层按序合并元数据。
9. **S3 错误 XML 里 RequestId 从哪来?** addCustomHeadersMiddleware 先写进响应头,writeErrorResponse 再从响应头取回填 XML(cmd/api-response.go:979-980)。
10. **桶不存在时 PutObject 报什么?** 进入 erasure 层后由 `toAPIError` 翻译为 `ErrNoSuchBucket`(静态定义 cmd/api-errors.go:653);handler 层不预检桶,减少一次元数据往返。
11. **streaming unsigned trailer 是什么?** AWS 新的 `STREAMING-UNSIGNED-PAYLOAD-TRAILER`:内容不签名但带 CRC trailer,MinIO 用 `newUnsignedV4ChunkedReader` 支持(cmd/object-handlers.go:1897-1903)。
12. **HEAD 请求出错为什么不返回 XML?** HEAD 响应不允许有 body,走 `writeErrorResponseHeadersOnly`,错误码放自定义响应头(cmd/api-response.go:985-989)。

## 深挖练习

1. **跟踪一个 16MB+ streaming PUT 的完整数据流**:从 `s3ChunkedReader.Read` 的帧解析(cmd/streaming-signature-v4.go:264-393)到 `hash.Reader` 校验(cmd/object-handlers.go:1993)到 EC 分片写(cmd/erasure-object.go:1440),画出 reader 嵌套顺序图。
2. **Complete 的并发安全**:两个 CompleteMultipartUpload 并发到达时,`renameData`(cmd/erasure-multipart.go:1462)与 NSLock(:1443-1451)如何保证只有一个成功?失败的 rename 返回什么错误?
3. **多 pool 列表归并**:`z.listPath` 如何把 N 个 pool 的有序流归并成全局字典序?`merged.forwardPast` 与 ILM 跳过条目优化(cmd/erasure-server-pool.go:1507, :1546-1550)对 NextMarker 的影响。
4. **虚拟主机路由与 domain 配置**:`globalDomainNames` 为空/非空时路由树差异(api-router.go:264-289),以及 k8s 下跳过 `minio.<domain>` 的特殊处理(:266-284)。
5. **PostPolicy 表单上传**:路由用 MatcherFunc 而非 Queries 谓词判断(api-router.go:574-578),对比 `isRequestPostPolicySignatureV4` 的识别条件,为什么它无法用查询参数表达。

## 写作要点速查表

| # | 内容 | 位置 |
|---|------|------|
| 1 | S3 路由注册入口 / SkipClean | cmd/api-router.go:255 / cmd/routers.go:87 |
| 2 | 全局中间件链 | cmd/routers.go:54-81 |
| 3 | 对象级路由(PutObject at 398, multipart at 324-334) | cmd/api-router.go:300-408 |
| 4 | 桶级路由 + List 系列 + V1 兜底 | cmd/api-router.go:505-523, :626 |
| 5 | s3APIMiddleware(trace/gzip/限流/统计) | cmd/api-router.go:210-252 |
| 6 | PutObjectHandler 主函数 | cmd/object-handlers.go:1793 |
| 7 | PutObject 鉴权分流(streaming v4 reader) | cmd/object-handlers.go:1884-1919 |
| 8 | 加密接入 EncryptRequest/WithEncryption | cmd/object-handlers.go:2053-2100 |
| 9 | EC 写入 + rename 提交 | cmd/erasure-object.go:1254, :1564 |
| 10 | multipart 目录布局与 uploadID 生成 | cmd/erasure-multipart.go:47-61, :506-507 |
| 11 | Complete 校验(ETag/5MB/checksum)+ rename | cmd/erasure-multipart.go:1255-1342, :1462 |
| 12 | CompleteMultipartUploadHandler(parts 有序检查) | cmd/object-multipart-handlers.go:914, :961 |
| 13 | V2 参数解析(token base64) | cmd/api-resources.go:69-105 |
| 14 | ListObjectsV2 = token→marker 转换 | cmd/erasure-server-pool.go:1372-1391 |
| 15 | listObjectsGeneric(归并/NextMarker) | cmd/erasure-server-pool.go:1486-1556 |
| 16 | 错误 XML 结构与 writeErrorResponse | cmd/api-errors.go:64-76 / cmd/api-response.go:957-983 |
| 17 | errorCodes 静态表 + toAPIError 翻译 | cmd/api-errors.go:482, :2462 |
| 18 | streaming v4 chunked reader | cmd/streaming-signature-v4.go:195, :264-393 |
