# 第 08 章 · SSE 加密:三种形态与密钥层级

> 基线:commit `7aac2a2`。行号以 internal/crypto/、internal/kms/、cmd/encryption-v1.go 为准。

## 8.0 全景:SSE 三形态与密钥层级

```
SSE-C(SSEC,sse-c.go:36):客户每次请求自带 32B 密钥,用完即弃(:80-85 落盘前删除)
SSE-S3(S3,sse-s3.go:38):全托管,KMS GenerateKey 取 DEK
SSE-KMS(S3KMS,sse-kms.go:39):KeyId+Context,context 强制注入 AAD
密钥层级:KMS 主密钥(root)→ DEK(每次写入 GenerateKey,只存密文+keyID)
  → 每对象 32B ObjectKey(key.go:37:HMAC 派生)→ multipart 再派生 PartKey(:140)
```

数据加密算法=DAREv2-HMAC-SHA256(sio 库,sse.go:35),每包 64KiB+32B(encryption-v1.go:71-76)。

## 8.1 加密顺序定论:整对象在 EC 分片之前加密

证据链:object-handlers.go:2070 `EncryptRequest` 把明文包成 sio DARE 加密流(:423)→:2088 挂到 PutObjReader→**erasure 层拿到密文流做 Reed-Solomon 分片**(erasure-object.go:1183→erasure-encode.go:67-113)。顺序=明文→DARE 加密流→EC 分片→bitrot→盘;每块盘 xl.meta 各存一份密钥材料(erasure-metadata.go:409)。**密钥材料的密码学绑定**:Seal=HMAC(KEK,IV‖domain‖算法‖bucket/object)(key.go:86-109)——密封密钥与对象路径绑定,挪用到别的对象即失效。

## 8.2 range 读与密钥轮换

**加密对象的随机读**:GetDecryptedRange(:855-950)把明文 range 换算成密文 range(按 64KiB 包对齐 :923-929),从目标包起解密——**sio.DecryptReader 带 SequenceNumber 可从任意包号起播**(:562-571),range 读不必从 0 解。密钥轮换 rotateKey(:261-356):**只重封 ObjectKey 不重写数据**(DEK 密文更新,数据分片不动);自动加密 MINIO_KMS_AUTO_ENCRYPTION(auto-encryption.go:31)需 KMS。KMS 面:internal/kms/kes.go——GenerateKey(返回 DEK 明文+密文对 :184-210)/Decrypt(AAD 必须匹配 :232-252);后端 MinKMS/MinKES/Builtin(conn.go:85-91),Builtin 即环境变量 MINIO_KMS_SECRET_KEY(:43-73,密文格式与 KES 兼容 :119-161);**Vault 不在 MinIO 源码内**,由 KES 桥接。ETag 用 ObjectKey 封装(>16B 即密封,metadata.go:174-165)。

## 8.3 设计动机

1. **为什么 SSE-C 客户户供钥**:密钥不落盘=服务端被攻破也不泄密——信任模型的最强档,代价是客户端管钥;
2. **为什么每对象 DEK**:一密泄只影响一对象;DEK 密文+keyID 存元数据——密钥层级化(根密钥→DEK→数据);
3. **加密在 EC 分片之前**:密文分片后,单盘泄露的是密文分片(无意义)——**加密先于分布**是顺序不变式;
4. **64KiB 包+SequenceNumber**:随机读从目标包起解——加密流的"索引"是包号。

## 8.5 FAQ

**Q1:SSE-C 的密钥存哪里?**
不存:用完即弃,只存 SealedKey(校验用)(:80-85)——密钥不出客户端。

**Q2:丢了 SSE-C 密钥还能读吗?**
不能:ObjectKey 由它派生,SealedKey 密码学绑定对象路径(:86-109)。

**Q3:加密和 EC 谁先?**
加密先(:2070→:1183):EC 分片的是密文——单盘泄露无意义。

**Q4:range 读加密对象要从头解吗?**
不用:GetDecryptedRange 换算到目标 64KiB 包(:855-950);lz4 压缩例外需整段(卷一 03 章? 非——15 章对照)。

**Q5:密钥轮换要重写数据吗?**
不用:rotateKey 只重封 ObjectKey(:261-356)——DEK 密文在元数据里换。

**Q6:KES 是什么?**
MinIO 的 KMS 网关(kestrel):桥接 Vault 等,KMS API 的唯一入口(:184-210)。

**Q7:Builtin KMS 的密文存哪?**
环境变量 MINIO_KMS_SECRET_KEY(:43-73):根密钥在环境,DEK 密文在元数据。

**Q8:自动加密的开关?**
MINIO_KMS_AUTO_ENCRYPTION(:31):需 KMS;所有新对象默认加密。

**Q9:multipart 的每 part 密钥?**
DerivePartKey(:140):nonce=SHA256(uploadID+partID) 确定性导出。

**Q10:ETag 为什么会变长?**
密封 ObjectKey 封装进 ETag(:174-165):加密对象的 ETag≠明文 MD5。

## 8.6 小结与深挖方向

本章结论:**SSE="三形态 Type 接口+四级密钥层级+加密先于 EC+包号索引的随机读"**。深挖:

1. DAREv2 的 64KiB 包在 range 读的放大系数;
2. SealedKey 的 HMAC 域分离(:86-109)对抗挪用的证明;
3. rotateKey 的并发(轮换中读)一致性;
4. Builtin KMS 在合规场景的适用边界;
5. sio 库的包格式与认证加密强度(AEAD)。

> 下一章(卷二卷末):S3 API 层——路由树与 PutObject 全链。
