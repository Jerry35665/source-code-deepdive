# 第 10 章 · TLS 传输套接字与 SDS:证书的生命周期(卷二)

> 基线:tag v1.39.1。路径勘误:TLS 核心在 source/common/tls/,extensions 目录只剩扩展点与工厂注册。

## 10.0 全景:BIO 桥接与证书热轮换时序

```
SslSocket:自定义 BIO_s_io_handle 把 BoringSSL 读写对接 IoHandle
  EAGAIN→BIO_set_retry_read→SSL_ERROR_WANT_READ→控制权交回 event loop
  (SSL↔socket 的搬运由 BIO 完成,Envoy 不自己拷贝密文)
握手状态机四态;BoringSSL 异步错误码(证书验证/私钥运算)→readDisable 等回调
SecretManager 三态:static(永不轮换,update 回调为 null)/inline/SDS(动态)
热轮换链:SDS onConfigUpdate/文件 MovedTo→setSecret→回调→ContextConfig 重建
  →factory onAddOrUpdateSecret→createSslServerContext(新 SSL_CTX)→读写锁 swap
  →新连接拿新 ctx;存量连接持旧 ContextImpl shared_ptr 不受影响,不 drain
```

## 10.1 SslSocket 与 ContextImpl

自定义 BIO 是必须的:Envoy 的 IoHandle 抽象(win32/io_uring 后端)与 BoringSSL 的 fd 假设不匹配;自定义 BIO 让 SSL 层复用 event loop 非阻塞语义,Envoy 侧完全不接触密文字节。握手后统计 SSL_session_reused(旧文档的 sslresumption 计数器现名于此);**TCP 侧 TLS1.3 early data(0-RTT)不受支持**(0-RTT 仅在 QUIC 握手器)。ContextImpl 构建:每张证书一份 SSL_CTX、严格 cipher list(失败逐个拆解定位坏 cipher)、ECDSA 仅 P-256/384/521、RSA≥2048、编译期 #error 锁定 BoringSSL/AWSLC。**SNI 多证书**:select_certificate_cb 在 ClientHello 后、Certificate 前介入——只有 SSL_CTX 级回调能这么早;DefaultTlsCertificateSelector 把 DNS SAN(无 SAN 退化 CN)收进 map,精确→通配→(可选)全扫→兜底,同批 ECDSA 优先。session id 上下文=所有证书 CN/SAN/issuer+SNI 的 SHA256——跨 filter chain 不可 resume。

## 10.2 SecretManager:file/inline/SDS 三态

三态在 ContextConfigImpl 构造时分流;**静态 provider 的 update 回调返回 nullptr**——静态配置属 bootstrap,"轮换"在类型上不可表达,避免伪热更新。动态 provider 以 (hash(sds_config), name) 去重共享;其 init target 无条件加进所属 listener/cluster 的 init_manager——这正是"CDS/LDS 必须 warming 等 SDS"的实现点:**把"引用了不存在的证书"从运行期故障收敛为启动顺序问题**。SDS 文件 watcher 是目录级 MovedTo(支持 K8s secret 原子换名),带 5 次有界重试的原子轮换检测。secret 未就绪时工厂返回 NotReadySslSocket(连接即失败)并计数。

## 10.3 热轮换的完整链路

xDS 更新/文件 inotify→setSecret→回调→ContextConfigImpl 重建配置→factory 构造**全新 SSL_CTX**→读写锁 swap→`ssl_context_update_by_sds` 计数。**既不在 SSL_CTX 上 in-place 换证书,也不 drain 存量连接**:SSL_CTX 不可线程安全换证书,而重建+引用计数天然解决新旧共存;重建失败的新 ctx 直接拒更新,旧 ctx 不受牵连——**回滚语义免费获得**。listener 配置因 LDS 重推且仅 filter chain 变化时走 in-place update+drain(卷一 03 章)。撤销语义:CRL 也是 SDS 资源,轮换后重建 context 重灌 X509_STORE;配合 reverify_on_resume,连 resumed session 也要过新 store——CRL 吊销即刻生效。OCSP 现状:仅下游 server 侧 stapling。

## 10.4 设计动机

1. **BoringSSL**:select_certificate_cb/异步私钥/compliance policy 等 API 是异步证书选择与 FIPS 的前提;OpenSSL 缺钩子;
2. **SNI 回调在 ctx 层**:证书选择发生在 ClientHello 后 Certificate 前,只有 SSL_CTX 级回调能介入;
3. **热轮换靠重建**:SSL_CTX 不可线程安全换证书;重建+引用计数=新旧共存+免费回滚;
4. **SDS 与 CDS/LDS 依赖**:init target 机制把缺证书从运行期故障变成启动顺序;
5. **自定义 BIO**:IoHandle 抽象与 BoringSSL fd 假设不匹配;retry flag 传递非阻塞语义;
6. **静态 secret 不可轮换**:类型上不可表达,避免伪热更新。

## 10.5 FAQ

**Q1:TLS 核心代码在哪?**
source/common/tls/;extensions 下只有扩展点与工厂注册。

**Q2:支持 TLS1.3 0-RTT 吗?**
TCP 侧不支持(全目录无 SSL_early_data);0-RTT 仅在 QUIC 握手器。

**Q3:换证书要重启吗?**
不:SDS/文件轮换触发新 SSL_CTX 重建+swap;存量连接持旧 ctx 继续服务。

**Q4:静态配置的证书能轮换吗?**
不能:静态 provider 的 update 回调为 null——"轮换"类型上不可表达。

**Q5:SNI 匹配顺序?**
精确名→通配名→(可选)full_scan→兜底第一张;同批 ECDSA 优先。

**Q6:证书被吊销(CRL)后 resume 的会话还认吗?**
不认:reverify_on_resume 让 resumed session 也过新 X509_STORE。

**Q7:OCSP 支持吗?**
仅下游 server stapling(must-staple 探测/响应匹配/策略);上行 client 不做。

**Q8:secret 没就绪时连接会怎样?**
NotReadySslSocket:读写都是 Close;计 context_secrets_not_ready。

**Q9:上游 SNI 怎么定?**
options 覆盖>auto_host_sni(host hostname)>静态 sni;auto_sni_san_validation 开启时把 SNI 作为 SAN 校验。

**Q10:握手失败怎么诊断?**
drainErrorQueue 拼 failure_reason(access log 可见);peer RST 单独 SO_ERROR 探测。

## 10.6 小结与深挖方向

本章结论:**TLS="BIO 桥接+ctx 级 SNI 选择+重建式热轮换+SDS 启动依赖,回滚免费"**。深挖:

1. session ticket key 的轮换加密续票协议(server_context_impl.cc:338-396);
2. auto_sni_san_validation 与 per-route SAN 覆盖的交互;
3. compliance policy(FIPS_202205/CNSA)的统一施加点;
4. 证书选择器的 full_scan_certs_on_sni_mismatch 性能代价;
5. keylog 的 local/remote IP 白名单过滤。
