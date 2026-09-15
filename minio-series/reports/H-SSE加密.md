# MinIO 深读 · 卷二第 2 章：服务端加密（SSE）体系

> 调研对象：minio/minio @ commit `7aac2a2`（7aac2a2c5b7c882e68c1ce017d8256be2feea27f）。
> 所有行号均为该 commit 下仓库相对路径的实测行号（grep -n / Read 核对）。

阅读指引：本章三层展开——密钥体系（internal/crypto：谁加密谁、密钥怎么封存）、数据面（cmd/encryption-v1.go + object-handlers.go：写入/读取何时加解密）、控制面（internal/kms：DEK 从哪来）。先读 §1 建立模型，§2/§3 是两条数据面证据链，§4 是唯一的对外密码服务依赖。

---

## 1. 全景：SSE 三形态与密钥层级

`internal/crypto` 共 15 个文件，核心是 `sse.go` 定义的 `Type` 接口——三种 SSE 形态各自实现它（internal/crypto/sse.go:48-53）：

```go
// Type represents an AWS SSE type:
//   - SSE-C
//   - SSE-S3
//   - SSE-KMS
type Type interface {
    fmt.Stringer
    IsRequested(http.Header) bool
    IsEncrypted(map[string]string) bool
}
```

三个实现分别是单例对象 `SSEC = ssec{}`（internal/crypto/sse-c.go:36）、`S3 = sses3{}`（internal/crypto/sse-s3.go:38）、`S3KMS = ssekms{}`（internal/crypto/sse-kms.go:39）。另有一个变体 `SSECopy`（internal/crypto/header.go:41），专用于 server-side copy 时解密源对象。请求头判定的优先级是 SSE-S3 > SSE-KMS > SSE-C（internal/crypto/sse.go:60-71）。

### 1.1 全景图

```
                       ┌────────────────── 客户端 ──────────────────┐
                       │  PUT + x-amz-server-side-encryption-*      │
                       └──────┬───────────────┬───────────────┬─────┘
                              │ SSE-C         │ SSE-S3        │ SSE-KMS
                    客户自带 32B │ (每次请求      │ 无密钥参数,   │ 带KeyId(+Context)
                    密钥,不落盘 │ 带上,用完即弃) │ 全托管        │
                              ▼               ▼               ▼
                    ┌─────────────┐  ┌──────────────────────────────┐
                    │ 客户密钥KEK  │  │        KMS (GlobalKMS)        │
                    │ (仅存内存)  │  │  MinKES / MinKMS / Builtin    │
                    └──────┬──────┘  │  (internal/kms)               │
                           │         └──────┬───────────────────────┘
                           │                │ GenerateKey()→DEK(明文+密文)
                           │                ▼
                           │      DEK(每次PUT生成,只存密文)
                           │                │
                           ▼                ▼
              ┌────────────────────────────────────────────┐
              │ ObjectKey(每对象 32B, 永不明文落盘)          │
              │  = crypto.GenerateKey(KEK明文, rand)        │
              │  → 加密对象数据流 (DARE v2, sio)             │
              │  → SealedKey{Key[64], IV[32]} 存入 xl.meta  │
              └────────────────────────────────────────────┘
```

### 1.2 密钥层级 root → object

1. **Root / master key**：活在 KES/KMS 里，MinIO 只持有 key name（如 `MINIO_KMS_KES_KEY_NAME`，internal/kms/config.go:55）。Builtin 模式下是 `MINIO_KMS_SECRET_KEY` 给的一条 32B 密钥（internal/kms/config.go:63，internal/kms/secret-key.go:43-55）。
2. **DEK（数据加密密钥）**：每次写入由 KMS `GenerateKey` 生成，返回 `{Plaintext, Ciphertext}` 对；**明文只在内存中参与派生，密文（连同 keyID）写进对象元数据**（cmd/encryption-v1.go:365-374）。
3. **ObjectKey（对象密钥）**：每对象 32 字节的 `crypto.ObjectKey`（internal/crypto/key.go:35-37），由 DEK 明文（或 SSE-C 客户密钥）加随机数经 HMAC-SHA256 派生（internal/crypto/key.go:42-60）；它才是真正加密对象数据的密钥。
4. **PartKey（分片密钥，仅 multipart）**：`ObjectKey.DerivePartKey(partID)` 从对象密钥按 part 序号再派生（internal/crypto/key.go:139-148），保证每个 part 是独立 DARE 流。

注意 SSE-C 是一条"扁平"链：客户密钥直接当 KEK，没有 KMS 参与（cmd/encryption-v1.go:407-411）。

---

## 2. 加密路径专节：写入时先整对象加密、后 EC 分片

**结论先行：加密发生在对象层（API handler）对"整对象明文流"进行，之后加密流才进入纠删码（EC）分片。盘上分片存的是密文的分片，每块盘 xl.meta 里都有一份密钥材料。**

证据链（按执行顺序）：

第一步，PutObjectHandler 发现 SSE 请求头（cmd/object-handlers.go:2054-2096），调用 `EncryptRequest` 把明文 reader 包装成 `sio.EncryptReader` 加密流（cmd/object-handlers.go:2070；cmd/encryption-v1.go:459-486 → 417-429）：

```go
func newEncryptReader(ctx context.Context, content io.Reader, kind crypto.Type,
    keyID string, key []byte, bucket, object string,
    metadata map[string]string, cryptoCtx kms.Context) (io.Reader, crypto.ObjectKey, error) {
    objectEncryptionKey, err := newEncryptMetadata(ctx, kind, keyID, key, bucket, object, metadata, cryptoCtx)
    ...
    reader, err := sio.EncryptReader(content, sio.Config{Key: objectEncryptionKey[:], MinVersion: sio.Version20})
    ...
    return reader, objectEncryptionKey, nil
}
```

第二步，加密流被重新包成 hash.Reader 并挂到 `PutObjReader` 上（cmd/object-handlers.go:2083-2088；cmd/object-api-utils.go:1084-1091）。此后下游所有层拿到的 `data.Reader` 都是密文流。

第三步，EC 层按 1MB 块读密文流做里德-所罗门编码：`erasureObjects.putObject`（cmd/erasure-object.go:1254）→ `erasure.Encode(ctx, data, writers, buffer, writeQuorum)`（cmd/erasure-object.go:1183）→ 循环 `io.ReadFull` + `e.EncodeData`（cmd/erasure-encode.go:67-113，EncodeData 在 cmd/erasure-coding.go:77）。**即：明文 → DARE v2 加密流 → EC 数据/校验分片 → bitrot 写盘。**

第四步，密钥材料写入元数据：`newEncryptMetadata` 按三种类型生成 ObjectKey 并 Seal（cmd/encryption-v1.go:358-415），SealedKey 随 `fi.Metadata` 并行写入所有盘的 xl.meta（cmd/erasure-metadata.go:409）。

### 2.1 每对象密钥材料的生成（三种形态对比）

`newEncryptMetadata` 的三个分支（cmd/encryption-v1.go:358-415）：

- **SSE-S3**（:361-375）：`GlobalKMS.GenerateKey` 得到 DEK → `crypto.GenerateKey(dek.Plaintext, rand.Reader)` 派生 ObjectKey → `objectKey.Seal(dek.Plaintext, GenerateIV, "SSE-S3", bucket, object)` → `crypto.S3.CreateMetadata` 把 sealed key、DEK 密文、keyID 全部写入 metadata。
- **SSE-KMS**（:376-406）：同上，外加 KMS Context 处理——客户提供的 context 原样保存，但派生用副本中强制注入 `bucket → bucket/object` 映射（:387-391），保证 AAD 与对象路径绑定。
- **SSE-C**（:407-411）：KMS 不参与，直接 `GenerateKey(key, rand.Reader)`，Seal 也用客户密钥。

`ObjectKey.Seal` 的关键在"密封密钥"的派生——把 IV、域（SSE-C/SSE-S3/…）、算法名、对象路径一起 HMAC（internal/crypto/key.go:86-109）：

```go
mac := hmac.New(sha256.New, extKey)
mac.Write(iv[:])
mac.Write([]byte(domain))
mac.Write([]byte(SealAlgorithm))
mac.Write([]byte(path.Join(bucket, object))) // canonical 'bucket/object'
mac.Sum(sealingKey[:0])
// sio.Encrypt(sealingKey, ObjectKey) → SealedKey.Key[64]
```

因此 SealedKey 被密码学绑定到具体对象路径，拷到别的对象的元数据里也解不开（internal/crypto/key.go:83-85 注释明说）。落盘的元数据键名常量集中在 internal/crypto/metadata.go:24-65：`MetaIV`（:31）、`MetaAlgorithm`（:35）、`MetaSealedKeySSEC/S3/KMS`（:38/:40/:42）、`MetaKeyID`（:46，KMS 主密钥 ID）、`MetaDataEncryptionKey`（:49，密封 DEK）、`MetaContext`（:61）。SSE-C 的客户密钥在落盘前被 `RemoveSensitiveEntries` 删除（internal/crypto/metadata.go:80-85，调用点 cmd/object-handlers.go:2100）。

加密算法标识是 `SealAlgorithm = "DAREv2-HMAC-SHA256"`（internal/crypto/sse.go:35），底层用 minio/sio 库的 DARE 2.0 流式格式：每包 64KiB 载荷 + 32B 元数据开销（cmd/encryption-v1.go:71-76 的 `SSEDAREPackageBlockSize`/`SSEDAREPackageMetaSize`）。

### 2.2 连带加密的周边数据

- **ETag**：加密对象的 ETag 用 ObjectKey 再封一层 `SealETag`（internal/crypto/key.go:154-165；cmd/object-api-utils.go:1109-1122），密封判定为 `len(etag) > 16`（internal/crypto/metadata.go:174）。
- **对象级元数据/压缩索引/checksum**：通过 `opts.EncryptFn = metadataEncrypter(objectEncryptionKey)`（cmd/object-handlers.go:2096；实现 cmd/encryption-v1.go:1049-1059）加密，压缩索引走 `compressionIndexEncrypter`（cmd/object-api-utils.go:1017-1027）。
- **multipart UploadPart**：每个 part 用 `DerivePartKey(partID)` 加密，nonce 由 SHA256(uploadID+partID) 确定性导出（cmd/object-multipart-handlers.go:820-836）。
- **自动加密**：`MINIO_KMS_AUTO_ENCRYPTION` 开启后，bucket 默认加密策略把非 SSE-C 请求转成 SSE-S3（internal/crypto/auto-encryption.go:26-40；Apply 调用点 cmd/object-handlers.go:1942-1945，且要求已配置 KMS，cmd/config-current.go:527-530）。

---

## 3. 读取解密专节：range 读的解密代价

读取入口是 `NewGetObjectReader`，发现对象加密后走专门的分支（cmd/object-api-utils.go:812-816、:930-981）：先用 `GetDecryptedRange` 把"明文 range"换算成"密文 range"，再挂解密 reader。

### 3.1 密文范围换算（GetDecryptedRange）

cmd/encryption-v1.go:855-950。核心算式（cmd/encryption-v1.go:923-929）：

```go
sseDAREEncPackageBlockSize := int64(SSEDAREPackageBlockSize + SSEDAREPackageMetaSize) // 64KiB+32
startPkgNum := (off - cumulativeSum) / SSEDAREPackageBlockSize
skipLen     := (off - cumulativeSum) % SSEDAREPackageBlockSize
encOff      := encCumulativeSum + startPkgNum*sseDAREEncPackageBlockSize
```

结束端多读一个包，保证覆盖最后一个目标字节（cmd/encryption-v1.go:944-947）。

**代价结论：range GET 不需要从 0 开始解密，但也不支持字节级随机访问**——

- 定位粒度是 64KiB 的 DARE 包：只需从目标包起读盘、解密（读取量 = 覆盖 range 的若干个 64KiB+32B 包，cmd/encryption-v1.go:592-593 同样的包换算在 multipart 分支复用）；
- 包内偏移靠读出后 `SkipReader(skipLen) + LimitReader` 丢弃（cmd/object-api-utils.go:972）；
- 每次请求要先解出 ObjectKey：SSE-C 用请求头里的客户密钥 Unseal（cmd/encryption-v1.go:508-517）；SSE-S3/KMS 要去外部 KMS 做一次 `Decrypt`（cmd/encryption-v1.go:490-507），这是一次网络往返延迟，MinIO 对 List 场景专门做了批量 `UnsealObjectKeys`（internal/crypto/sse-s3.go:99-116，cmd/encryption-v1.go:113-208 中 250 个/批）。

### 3.2 解密 reader 与跨 part 流式切换

单 part 对象：`DecryptRequestWithSequenceNumberR`（cmd/encryption-v1.go:527-536）→ `sio.DecryptReader` 带 `SequenceNumber`（起始包号）直接从任意包号开始解密流（cmd/encryption-v1.go:562-571）。这是 DARE 流支持随机读的关键设计。

multipart 对象：`DecryptBlocksRequestR`（cmd/encryption-v1.go:575-635）构造 `DecryptBlocksReader`——ObjectKey 只解一次、跨 part 复用（cmd/encryption-v1.go:624-629）；每切换到一个 part 就用 `DerivePartKey(partID)` 现场重建解密器（buildDecrypter，cmd/encryption-v1.go:655-673），Read 中越界时推进 partIndex 并换解密器（cmd/encryption-v1.go:675-718）。

SSE-C 读取时若请求没带密钥会直接 `ErrSecretKeyMismatch`（internal/crypto/key.go:133-135）；server-side copy 场景则解析 SSE-Copy 头（cmd/encryption-v1.go:540-552；internal/crypto/sse.go:81-87）。

---

## 4. KMS 专节：internal/kms 的 API 面

`internal/kms` 是对三类后端的统一抽象：`KMS.Type` 取值 MinKMS / MinKES / Builtin（internal/kms/kms.go:142-144）。**本仓库代码只对接 KES 协议与 MinKMS 协议及内建实现；Vault、AWS KMS、Fortanix 等外部 KMS 由 KES 服务端负责桥接，MinIO 源码里不直接出现 Vault SDK。**

核心两个调用（SSE 路径只用这两个）：

**GenerateKey——写路径取 DEK**（internal/kms/kms.go:228-238 → KES 实现 internal/kms/kes.go:184-210）：

```go
// kesConn.GenerateKey
name := req.Name
if name == "" { name = c.defaultKeyID }
dek, err := c.client.GenerateKey(ctx, name, aad)
...
return DEK{ KeyID: name, Plaintext: dek.Plaintext, Ciphertext: dek.Ciphertext }, nil
```

**Decrypt——读路径解 DEK**（internal/kms/kms.go:242-248 → internal/kms/kes.go:232-252）。关联数据 AAD 全程绑定 `kms.Context{bucket: path.Join(bucket, object)}`（internal/crypto/sse-s3.go:85；internal/crypto/sse-kms.go:118-127），加密与解密两侧必须一致，否则 KES 端 AEAD 校验失败（`ErrDecrypt`，internal/kms/kes.go:243-245）。

外围 API 面（供 admin/生命周期用）：`CreateKey`（internal/kms/kes.go:146-157）、`DeleteKey`（:163-174）、`ImportKey`（:213-217）、`EncryptKey`（:221-227，明文 ≤1MB）、`MAC`（:256-270）、`Status`（:68-127，多端点并发探活）、`ListKeys`（:129-139）。

**Builtin 模式**（无外部 KMS 时用 `MINIO_KMS_SECRET_KEY`，internal/kms/config.go:63）：`secretKey.GenerateKey` 在进程内完成"生成 32B 随机 DEK + 用主密钥 AES-GCM（必要时 ChaCha20）封装"，密文格式刻意与 KES/MinKMS 兼容（internal/kms/secret-key.go:115-161，注释见 :119-120），`Decrypt` 反之（:168-212）。这使 MinIO 能在零外部依赖时提供同一套 SSE-S3 语义。

连接配置全部走环境变量（internal/kms/config.go:36-63）：`MINIO_KMS_KES_ENDPOINT/_KEY_NAME/_API_KEY/_KEY_FILE/_CERT_FILE` 等；对 KES 的认证推荐 API key 或 mTLS 客户端证书（config.go:57-60）。

### 4.1 KMS 类型枚举与全局初始化

后端类型是三元枚举 `MinKMS / MinKES / Builtin`（internal/kms/conn.go:85-91，String() 见 :94-107）；进程启动时一次性初始化 `GlobalKMS *kms.KMS`（cmd/globals.go:343-344，赋值点 cmd/common-main.go:939）。SSE-S3/SSE-KMS 的读写路径一律先判 `GlobalKMS == nil` 再动手（cmd/encryption-v1.go:362-364、:490-507），未配置时返回 `errKMSNotConfigured`（cmd/encryption-v1.go:53）。Builtin 类型另有 stub 便捷入口（internal/kms/stub.go:41）。

---

## 5. 设计动机

**为什么 SSE-C 让客户供钥？** 职责切分到极致：MinIO 只做密码学执行者，密钥从未离开客户侧（每次请求带来、用完即弃，落盘前被删，internal/crypto/metadata.go:80-85）。客户可以随时让数据"物理不可读"——失去密钥即失去数据（`ErrSecretKeyMismatch`，internal/crypto/key.go:134）。代价是每次读都要带钥、丢钥无解。

**为什么每对象一个 DEK/ObjectKey，而不是一把全局密钥？** 三个理由：(a) 爆炸半径——单对象密钥泄露不影响其他对象；(b) 密钥材料小而静态——xl.meta 里只存 64B sealed key + 32B IV（internal/crypto/key.go:77-81），KMS 侧只存主密钥；(c) 生命周期独立——rotateKey（cmd/encryption-v1.go:261-356）可以只重封 ObjectKey 而不重加密数据（对象数据用 ObjectKey 加密，换 KEK 只需重新 Seal）。DEK 明文仅在一次 `GenerateKey` 往返后用于派生，密文+keyID 落盘，主密钥永不离开 KMS。

**为什么加密在 EC 之前（先加密后分片）？** (a) 安全上，若先分片再加密，需要每个分片独立密钥材料，元数据膨胀且 KMS 交互复杂化；先整流加密后，EC 只是对密文做线性代数，密钥材料每盘一份即可。(b) 工程上，`sio` 加密流与 `erasure.Encode` 的分块读循环天然解耦——handler 层包一层 reader（cmd/object-handlers.go:2070-2088），EC 层无感知（cmd/erasure-encode.go:95-106）。(c) 一致性——加密流自带每包 AEAD 认证，EC 重建出的密文流在解密时仍能被完整性校验，bitrot 负责"分片级"校验、DARE 负责"对象级"认证，两层互补。(d) 代价是 EC 并行恢复的是密文，恢复后仍需 ObjectKey 才能读——这恰是静态加密想要的性质。

**为什么 range 读按 64KiB 包对齐？** DARE 2.0 每包独立 AEAD（nonce=包序号），`DecryptReader` 可以从任意 SequenceNumber 起播（cmd/encryption-v1.go:562-571）。包大小是权衡：太大→小 range 读放大；太小→每 64KiB 的 32B 元数据开销约 0.05%，可忽略。multipart 再叠加一层 part 粒度的 DerivePartKey，使"读一个 part"不需要解密相邻 part 的流。

**TLS 与 SSE 的分工：传输加密 vs 静态加密。** 两者正交且互补。TLS 只保护网络路径上的字节；对象落盘后（以及内部副本/修复流量）的安全性由 SSE 负责——SSE-C/SSE-S3/SSE-KMS 加密后的盘上分片对任何拿到盘的人不可读。一个容易忽略的交叉点：KES 连接本身依赖 mTLS/API key 做认证（internal/kms/config.go:57-60 的 `MINIO_KMS_KES_KEY_FILE/_CERT_FILE/_API_KEY`），即"密钥通道"的机密性由 TLS 保障，而"数据通道"的静态安全由 DEK 体系保障。对 SSE-C 而言客户密钥出现在每个请求头中，生产部署必须全程 TLS，否则静态加密形同虚设——这正是 AWS 对 SSE-C 强制 HTTPS 的原因。另注：TLS 开启与否不影响 SSE 的编解码路径，二者在代码上无耦合（SSE 判定只看 `x-amz-server-side-encryption*` 头，internal/crypto/sse.go:60-76）。

---

## 6. FAQ 素材

1. **MinIO 会保存我的 SSE-C 密钥吗？** 不会。只保存 SealedKey（被客户密钥密封的 ObjectKey）与请求头里的 `x-amz-server-side-encryption-customer-key-MD5`；明文密钥在 `RemoveSensitiveEntries` 时从元数据删除（internal/crypto/metadata.go:80-85）。
2. **忘了 SSE-C 密钥还能恢复吗？** 不能。SealedKey 解封失败即 `ErrSecretKeyMismatch`（internal/crypto/key.go:133-135），没有任何后门。
3. **没有外部 KMS 能用 SSE-S3 吗？** 可以。`MINIO_KMS_SECRET_KEY` 提供 Builtin KMS，DEK 在进程内生成并内联封装，密文格式与 KES/MinKMS 兼容（internal/kms/secret-key.go:43-55、:119-161）。SSE-S3/SSE-KMS 的前提只是 `GlobalKMS != nil`（cmd/encryption-v1.go:362-364）。
4. **加密对象为什么 ETag 变长了？** ETag 被 ObjectKey 加密（internal/crypto/key.go:154-165），长度 >16 字节即视为密封（internal/crypto/metadata.go:174）；List 时由 `DecryptETags` 批量解出（cmd/encryption-v1.go:113-208）。
5. **range GET 要解密整个对象吗？** 不用。`GetDecryptedRange` 把 range 对齐到 64KiB DARE 包，从目标包号起解密，包内字节读出后再跳过（cmd/encryption-v1.go:923-929；cmd/object-api-utils.go:972）。
6. **为什么读 SSE-KMS 对象比明文对象多一次延迟？** 每请求要向 KMS 发一次 `Decrypt` 换取 DEK 明文（internal/crypto/sse-s3.go:82-89）；List 场景用 250 个/批的批量解密摊薄（cmd/encryption-v1.go:114-175）。
7. **开了自动加密后所有对象都会被加密吗？** 除 SSE-C 请求外都会转成 SSE-S3（internal/crypto/auto-encryption.go:26-32）；且该开关要求 KMS 已配置，否则启动报错（cmd/config-current.go:527-530）。
8. **加密与压缩/校验和共存吗？** 共存。顺序是先压缩后加密（压缩 reader 先构造，再被 `EncryptRequest` 包裹，cmd/object-handlers.go:1958 起的逻辑），压缩索引本身也用 ObjectKey 加密（cmd/object-api-utils.go:1017-1027）；PutObjReader 的明文 MD5 被密封进 ETag（cmd/object-api-utils.go:1055-1078）。
9. **能换 KMS 主密钥吗？** 能。`rotateKey` 对三种形态分别支持重封：SSE-S3/KMS 生成新 DEK 重新 Seal ObjectKey，数据本身不用重写（cmd/encryption-v1.go:261-356）。
10. **每块盘都存一份密钥材料吗？** 是。SealedKey 属于对象元数据，xl.meta 写入所有盘（cmd/erasure-metadata.go:409），读仲裁即可恢复密钥材料——数据分片丢了部分盘不影响解密能力。

## 7. 深挖方向

1. **SealedKey 的对象路径绑定**：密封密钥 = HMAC(KEK, IV‖domain‖算法‖bucket/object)（internal/crypto/key.go:86-99），可以写一个"重放 sealed key 到另一对象必失败"的验证实验。
2. **DARE SequenceNumber 随机读**：`sio.Config{SequenceNumber: seqNum}`（cmd/encryption-v1.go:562-571）+ `GetDecryptedRange` 的包换算，可推演任意 range 的读放大倍率（上取整到 64KiB 包）。
3. **Builtin 与 KES 密文格式兼容性**：`secretKey` 的 AEAD 封装刻意对齐 KES/MinKMS（internal/kms/secret-key.go:119-161），切换 KMS 后端时旧对象仍可解——值得通读 `parseCiphertext`（:227-248）与遗留 JSON 密文的兼容路径。
4. **SSE-Copy 的双钥场景**：server-side copy 时源/目标可各带一把 SSE-C 密钥（cmd/encryption-v1.go:604-622 有明确注释），且 SSE-S3 源对象拒绝 SSE-Copy 头（:236-238）。
5. **密钥材料与对象元数据同盘冗余的一致性**：`MetaKeyID`/`MetaDataEncryptionKey` 必须成对出现，否则元数据判定损坏（internal/crypto/sse-s3.go:177-184）——可作为"xl.meta 局部损坏"故障注入的观察点。

---

## 写作要点速查表

| # | 内容 | 位置 |
|---|------|------|
| 1 | Type 接口（SSE 三形态） | internal/crypto/sse.go:48-53 |
| 2 | 密钥材料元数据常量（IV/算法/sealed key/keyID/DEK 密文） | internal/crypto/metadata.go:24-65 |
| 3 | ObjectKey 派生（HMAC-SHA256 + 随机 nonce） | internal/crypto/key.go:42-60 |
| 4 | SealedKey 结构与 Seal（绑定 domain+bucket/object） | internal/crypto/key.go:77-109 |
| 5 | Unseal（DARE v2 / 遗留 DARE v1 双算法） | internal/crypto/key.go:114-137 |
| 6 | DerivePartKey（multipart 每 part 派生） | internal/crypto/key.go:139-148 |
| 7 | SSE-C 客户密钥解析（32B+MD5 校验） | internal/crypto/sse-c.go:72-93 |
| 8 | SSE-S3 用 KMS 解封 ObjectKey（AAD 绑定 bucket/object） | internal/crypto/sse-s3.go:74-92 |
| 9 | 写入三形态密钥生成（newEncryptMetadata） | cmd/encryption-v1.go:358-415 |
| 10 | 写入加密流包装（EncryptRequest→sio） | cmd/encryption-v1.go:459-486（sio 在 :423） |
| 11 | DARE 包参数 64KiB+32B | cmd/encryption-v1.go:71-76 |
| 12 | PutObject 加密接入点（handler 层） | cmd/object-handlers.go:2053-2097 |
| 13 | 读路径 range→密文 range 换算 | cmd/encryption-v1.go:855-950（核心 :923-929） |
| 14 | multipart 解密器跨 part 切换 | cmd/encryption-v1.go:575-635、655-718 |
| 15 | GetObjectReader 挂解密 reader | cmd/object-api-utils.go:930-981 |
| 16 | KES GenerateKey / Decrypt | internal/kms/kes.go:184-210 / 232-252 |
| 17 | Builtin KMS（MINIO_KMS_SECRET_KEY） | internal/kms/secret-key.go:43-73、120-161 |
| 18 | EC 在加密之后：Encode 循环读密文流做分片 | cmd/erasure-encode.go:67-113（:95 EncodeData）；调用点 cmd/erasure-object.go:1183 |

（行号实测于 commit 7aac2a2。）
