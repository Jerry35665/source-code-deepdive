# 第 09 章 · S3 API 层:路由树与 PutObject 全链

> 基线:commit `7aac2a2`。行号以 cmd/routers.go、cmd/api-router.go、cmd/object-handlers.go、cmd/erasure-multipart.go 为准。

## 9.0 全景:S3 API 路由树

`configureServerHandler`(routers.go:84)以 **SkipClean(true).UseEncodedPath()**(:87)建 mux——保留原始 URL 编码(S3 对象名可含特殊字符)。apiRouter 两条:虚拟主机 `Host {bucket}.<domain>`(:264-289)与路径风格 `PathPrefix("/{bucket}")`(:289);桶级子路由靠 **Queries("list-type","2") 等子资源谓词**分发(:505-627);对象级 `Path("/{object:.+}")` 按 method+Queries 分发(:300-408);根 GET=ListBuckets(:638);V1 列表注册在最后(:626)。每 handler 经 s3APIMiddleware 统一包 trace/gzip/maxClients/统计(:210-252)。

## 9.1 PutObject 全链:HTTP 到磁盘的一次穿越

```
PutObjectHandler(object-handlers.go:1793)
  → vars+unescapePath(:1803)→ Content-Length/streaming 解码校验(:1832-1852)
  → 元数据抽取(:1860)→ 策略 isPutActionAllowed(:1884)
  → 验签(streaming v4 用 newSignV4ChunkedReader 包 body :1892)
  → 配额/桶级 SSE 注入(:1927/:1942)
  → hash.Reader+PutObjReader(:1993/:2014)
  → Object Lock/复制标记(:2037/:2049)
  → EncryptRequest+WithEncryption(卷二 H :2070/:2088)
  → objectAPI.PutObject → erasure 层 putObject(erasure-object.go:1254)
     动态 parity+EC 编码+renameData 原子提交(:1564)
  → 解密回 ETag、发事件、仅头部响应(:2126-2183)
```

一条链串起本系列已讲的全部机制:鉴权(G)、加密(H)、EC(卷一 B)。

## 9.2 分片上传:multipart 的组织

multipart 目录=`.minio.sys/multipart/<sha256(bucket/object)>/<uploadUUID>`(object-api-utils.go:59-63;erasure-multipart.go:47-61);**uploadID=base64(deploymentID+uuid+纳秒)**(:506-507);Complete 按 "rename 提交":multipart 目录→最终对象(:1462);除末片外 ≥5MB 校验(:1318-1325);**Complete 强制 parts 升序**,否则 ErrInvalidPartOrder(object-multipart-handlers.go:961-966);multipart ETag=MD5(ETags)+"-N"(:1001-1018)。

## 9.3 ListObjects 与错误响应

ListObjectsV2 的 **continuation-token=base64(内部 marker)**,token 优先于 start-after(api-resources.go:96-103;转换 erasure-server-pool.go:1372-1376);NextMarker 生成(:1541-1554);maxObjectList=1000(api-response.go:43)。错误响应:S3 错误 XML 结构 APIErrorResponse(api-errors.go:64-76)与统一出口 writeErrorResponse(api-response.go:957-983);Go 错误翻译 toAPIError(:2462)。streaming v4 逐块验签 reader:s3ChunkedReader 帧解析+签名链比对(streaming-signature-v4.go:264-393,种子 :54-73,trailer :507-523)。

## 9.4 设计动机

1. **为什么完全自实现 S3**:S3 API 的每个细节(签名/子资源/错误 XML)都是行为承诺——自实现保证语义精确,而非"大部分兼容";
2. **SkipClean 的必要性**:对象名含合法特殊字符(空格/Unicode),mux 默认清洗会破坏——**保留原样的决心**;
3. **子资源查询参数路由化**:uploadId/partNumber 等 S3 概念映射为 gorilla 谓词——REST 的查询参数成为路由的一等公民;
4. **multipart 的目录哈希**:按 bucket/object 哈希分散 multipart 目录——防单目录巨量 uploadID。

## 9.5 FAQ

**Q1:对象名含 `..` 会路径穿越吗?**
不会:SkipClean+PathPrefix 的精确匹配+Clean 保留编码(:87)——路径穿越在 runc/PG 系列同族的防线。

**Q2:uploadID 泄露有风险吗?**
可续传 part:需要同凭证——鉴权在 handler 层兜底。

**Q3:CompleteMultipart 乱序 part 会怎样?**
ErrInvalidPartOrder(:961-966):升序是 S3 规范强制。

**Q4:multipart 的 ETag 为什么带 -N?**
MD5(ETags)+"-N"(:1001-1018):区分"整体上传的 MD5"与"分片合成"。

**Q5:V1 列表还在吗?**
在(:626 注册在最后):兼容旧 SDK;V2 是默认。

**Q6:continuation-token 和 start-after 同时给?**
token 优先(:96-103):token 是服务端状态编码,更精确。

**Q7:streaming v4 是什么?**
签名随 chunked body 逐块携带(:264-393):边传边验签,免先算 Content-Length。

**Q8:虚拟主机风格的路由怎么识别?**
Host 头 `{bucket}.<domain>`(:264-289):需要配置 domain 才启用。

**Q9:错误响应为什么是 XML?**
S3 规范:Error{Code,Message,Resource,RequestId}(api-errors.go:64-76)。

**Q10:PutObject 返回前数据落盘了吗?**
是:renameData 原子提交完成后才响应(:1564→:2126-2183)——quorum 写完成即 200。

## 9.6 小结与深挖方向

本章结论:**S3 API 层="路由树+子资源谓词+PutObject 全链横穿各子系统+streaming 验签"**。深挖:

1. SkipClean(:87)与 Content-Disposition 注入的组合攻击面;
2. multipart 哈希目录(:59-63)在百万未完成上传的组织;
3. Complete 的 renameData(:1462)在部分盘失败的回滚;
4. ListObjectsV2 的 marker 在删除对象后的语义漂移;
5. streaming v4 的 chunk 大小与验签性能。

> 下一章(卷二卷末):分层与联邦——数据的远行与多站同步。
