# D2(卷二):TLS 传输套接字与 SDS——证书的生命周期

基线:tag v1.39.1(commit b579d07d)。行号均经本仓库逐文件核对。

> 路径勘误:v1.39 中 TLS 核心实现位于 `source/common/tls/`(`ssl_socket.cc`、`context_impl.cc`、`cert_validator/` 等),
> `source/extensions/transport_sockets/tls/` 只保留扩展点(证书选择器/校验器扩展、上下行工厂注册 `config.h`、
> `downstream_config.cc`/`upstream_config.cc`)。下文引用以 `source/common/tls/` 为主。

## 0. 全景图

### 图 A:SslSocket 读写路径——BoringSSL 借 BIO 挂上 libevent 事件循环

```
   Network::Connection (libevent, edge trigger)
        │  read/write ready
        ▼
   SslSocket::doRead / doWrite                 ssl_socket.cc:110,330
        │   (握手未完成时先 doHandshake)          ssl_socket.cc:113,334
        ▼
   SslHandshakerImpl::doHandshake              ssl_handshaker.cc:142
        │   SSL_do_handshake()
        ▼
   SSL ──BIO_s_io_handle──► IoHandle           io_handle_bio.cc:97
        │  io_handle_read: readv 返回 EAGAIN
        │    → BIO_set_retry_read (io_handle_bio.cc:39)
        │    → SSL_get_error == WANT_READ/WANT_WRITE
        ▼
   返回 PostIoAction::KeepOpen,交还 event loop
   (SSL ↔ socket 的搬运由 BIO 完成,Envoy 不自己拷贝密文)

   异步分支: WANT_CERTIFICATE_VERIFY / PRIVATE_KEY_OPERATION
        → HandshakeBlockedOnAsyncOperation      ssl_handshaker.cc:162-167
        → readDisable(true) 等待回调 (ssl_socket.cc:222-234)
        → onAsynchronousCertValidationComplete → resumeHandshake (ssl_socket.cc:460-465)
```

### 图 B:SecretManager 证书分发与 SDS 热轮换时序

```
  静态: bootstrap static_resources.secrets
        └─ SecretManagerImpl::addStaticSecret          secret_manager_impl.cc:29
           (StaticProvider: update 回调恒为 nullptr     secret_provider_impl.h:22-35)

  内联: tls_certificate 直写在 listener/cluster 配置里
        └─ createInlineTlsCertificateProvider           secret_manager_impl.cc:105

  动态: tls_certificate_sds_secret_configs{sds_config, name}
        └─ findOrCreateTlsCertificateProvider           secret_manager_impl.cc:130
           map_key = hash(sds_config)+"."+name          secret_manager_impl.h:88-89
           └─ TlsCertificateSdsApi (subscription start) sds_api.cc:208-215
              init_target 注册进 listener/cluster 的 init_manager
              ( LDS/CDS 必须 warming 等 SDS —— 与卷一 B 的依赖顺序在此) secret_manager_impl.h:102-118

  热轮换:
   xDS SR/文件 inotify MovedTo
     → SdsApi::onConfigUpdate / onWatchUpdate          sds_api.cc:89,50
     → setSecret+resolveSecret(路径内联化)             sds_api.cc:268,289
     → update_callback_manager_.runCallbacks()         sds_api.cc:74,145
     → ContextConfigImpl::setSecretUpdateCallback      context_config_impl.cc:318
        (重造 TlsCertificateConfigImpl / CvcConfig)
     → ServerSslSocketFactory::onAddOrUpdateSecret     server_ssl_socket.cc:79
        createSslServerContext(新 SSL_CTX) → swap(ssl_ctx_) → removeContext(旧)
        stats_.ssl_context_update_by_sds_.inc()        server_ssl_socket.cc:89
     → 此后 createDownstreamTransportSocket 拿到新 ctx  server_ssl_socket.cc:54-75
     存量连接持有旧 ContextImpl shared_ptr,不受影响;
     listener 侧走 in-place filter chain update,旧 filter chain drain  listener_manager_impl.cc:636-641
```

## 1. SslSocket:BoringSSL 之上的适配层

**BIO 桥接。** Envoy 不用默认 socket BIO,而是自定义 `BIO_s_io_handle` 把 BoringSSL 的
读写直接对接 `Network::IoHandle`(即 libevent 持有的 fd 封装)。握手/加解密期间 BoringSSL 需要
读网络时,回调 `io_handle_read`,`EAGAIN/Interrupt` 翻译成 `BIO_set_retry_read`,SSL 层随即以
`SSL_ERROR_WANT_READ` 返回,控制权交回 event loop——非阻塞语义由 retry flag 传递:

```c
// source/common/tls/io_handle_bio.cc:25-44 (节选)
int io_handle_read(BIO* b, char* out, int outl) {
  ...
  auto result = io_handle->readv(outl, &slice, 1);
  BIO_clear_retry_flags(b);
  if (!result.ok()) {
    auto err = result.err_->getErrorCode();
    if (err == Api::IoError::IoErrorCode::Again || err == Api::IoError::IoErrorCode::Interrupt) {
      BIO_set_retry_read(b);
    } else {
      ERR_put_error(ERR_LIB_SYS, 0, result.err_->getSystemErrorCode(), __FILE__, __LINE__);
    }
    return -1;
  }
```

BIO 在 `setTransportSocketCallbacks` 时创建并与 SSL 绑定,同时把 `TransportSocketCallbacks*`
存进 SSL ex_data(`ssl_socket.cc:83-87`),供 keylog、证书校验回调反查连接上下文。
读路径上 `sslReadIntoSlice` 循环 `SSL_read` 填充 buffer slice(`ssl_socket.cc:89-108`);
写路径限速为每次 `linearize` 至多 16KB,并在 `WANT_WRITE` 后用 `bytes_to_retry_` 保证
SSL_write 幂等重试(`ssl_socket.cc:341-345,369-371`)。

**握手状态机。** 状态四值:`HandshakeWaitingForConnectionData / HandshakeBlockedOnAsyncOperation /
HandshakeComplete / ShutdownSent`(envoy/ssl/ssl_socket_state.h:9-19)。`SSL_do_handshake`
返回 1 即成功,触发 `onSuccess`→`logHandshake` 统计 + `Connected` 事件(ssl_handshaker.cc:144-152;
ssl_socket.cc:193-215)。BoringSSL 特有的异步错误码(`SSL_ERROR_PENDING_CERTIFICATE`、
`WANT_PRIVATE_KEY_OPERATION`、`WANT_CERTIFICATE_VERIFY`、`WANT_X509_LOOKUP`)归入
BlockedOnAsyncOperation(ssl_handshaker.cc:162-167)。此时 Envoy 会 `readDisable(true)` 以便检测
对端关闭,回调完成后再恢复(ssl_socket.cc:222-234)。证书选择(`SSL_set_SSL_CTX` + OCSP staple
回填)在 `SslExtendedSocketInfoImpl::onCertificateSelectionCompleted`(ssl_handshaker.cc:99-110)。

**关闭。** `closeSocket` 先反注册 private key provider;若因 RST 关闭且
`envoy.reloadable_features.ssl_socket_report_connection_reset` 开启,则跳过 close_notify,
避免与 RST 信号互相打架(ssl_socket.cc:427-441);否则 `SSL_shutdown`(或半关
`shutdown(ENVOY_SHUT_WR)`),Windows EmulatedEdge 下 rc==0 还要补一次读激活(ssl_socket.cc:396-416)。

**会话恢复与 early data 现状。** 下行:`SSL_CTX_set_tlsext_ticket_key_cb` 支持 STK 轮换解密续期
(server_context_impl.cc:173-185,338-396;首把 key 加密、旧 key 只解密并返回 2 触发续票,
server_context_impl.cc:350,388-389)。上行:client 侧 `SSL_SESS_CACHE_CLIENT` + `newSessionKey`
缓存,`newSsl` 时取队首复用,TLS1.3 单次票据用后即弃(client_context_impl.cc:94-104,178-201,
207-221)。握手后统计 `SSL_session_reused`(context_impl.cc:576-578)——即 stats.h:14 的
`session_reused`(旧文档里的 `sslresumption` 计数器现名于此)。**TCP 侧 TLS1.3 early data(0-RTT)
在 v1.39 的 source/common/tls 中没有任何 SSL_early_data 调用,不受支持**(全目录 grep 无命中);
0-RTT 仅存在于 QUIC 握手器一侧。

## 2. ContextImpl:SSL_CTX 的构建

构造顺序(context_impl.cc:71-404):先选 cert validator 工厂(默认
`envoy.tls.cert_validator.default`,factory 支持 dynamic_forwarding_metadata 扩展,context_impl.cc:89-102);
每个 `tls_certificates` 一份 `SSL_CTX`+一份 `Ssl::TlsContext`(context_impl.cc:104-110);
然后 min/max 协议版本(115-119)、严格 cipher list(失败时逐个拆解定位坏 cipher,121-150)、
ECDH curves(152-157)、signature algorithms(160-166)、证书压缩 brotli>zlib 注册(168-174)。
校验语境由 validator 注入,并统一挂 `SSL_CTX_set_custom_verify` + `set_reverify_on_resume`
(context_impl.cc:177-198;后者保证 session resume 时重验 client CA/CRL,这是撤销语义的关键)。

证书链在内存里解析:`PEM_read_bio_X509_AUX` 读 leaf,余下用 `SSL_CTX_add_extra_chain_cert`
逐张挂链,并以 `PEM_R_NO_START_LINE` 判 EOF(context_impl.cc:729-762);私钥
`PEM_read_bio_PrivateKey` + `checkPrivateKey`(FIPS 下跑 RSA/ECDSA 成对一致性测试,
context_impl.cc:764-779,820-846)。加载时强约束:ECDSA 仅 P-256/P-384/P-521,RSA ≥2048(FIPS
枚举 2048/3072/4096),否则拒绝创建 context(context_impl.cc:241-294)。证书过期时间同时写进
per-cert gauge(227-230)。ALPN 字符串在此层转 wire format(450-478);每个新 `SSL` 从第一个
context 派生,SNI 选择后再 `SSL_set_SSL_CTX` 换(context_impl.cc:480-489)。keylog 按
local/remote IP 白名单过滤后写文件(361-372,429-440);compliance policy(FIPS_202205、
CNSA1/2)最后统一施加(375-403,406-416)。编译期强制 BoringSSL/AWSLC:非二者直接 `#error`
(context_impl.h:35-37)。

**SNI/多证书选择。** server 侧在 base ctx 挂 `SSL_CTX_set_select_certificate_cb`,ClientHello
一到就进 `ServerContextImpl::selectTlsContext`(server_context_impl.cc:124-132,490-544),交给
证书选择器。默认选择器 `DefaultTlsCertificateSelector` 构建时把每张证书的 DNS SAN(无 SAN 退化
到 CN)收进 `server_names_map_`,按 `*.example.com`→`.example.com` 归并、按 key 类型(RSA/ECDSA)
分桶(default_tls_certificate_selector.cc:28-85)。查找:精确名→通配名(取第一个 `.` 之后)→
(可选)`full_scan_certs_on_sni_mismatch` 全扫→兜底 `tls_contexts_[0]`
(default_tls_certificate_selector.cc:248-280);同一批内 ECDSA 优先,RSA 作 candidate
(185-220)。ECDSA 能力判定直接解析 ClientHello 的 sigalgs/supported_groups
(server_context_impl.cc:401-468)。session id 上下文 = 所有证书 CN/SAN/issuer + validator 配置 +
SNI 列表的 SHA256,保证跨 filter chain 不可 resume(server_context_impl.cc:232-336,318-321)。

## 3. SecretManager:file/inline/SDS 三态

三种来源在 `ContextConfigImpl` 构造时分流(context_config_impl.cc:41-95):
`tls_certificates` 非空→inline provider;`tls_certificate_sds_secret_configs` 带 `sds_config`
→动态 `findOrCreate*`,否则按名查静态 secret(查不到直接报 "Unknown static secret",
context_config_impl.cc:78-90)。validation context 同理,另有 `combined_validation_context`
把本地 default 与远端 SDS 合并校验(context_config_impl.cc:155-165,305-316)。
静态 provider 的 add/update/remove 回调一律返回 nullptr——静态 secret 永不轮换
(secret_provider_impl.h:22-35)。动态 provider 以 `(hash(sds_config), name)` 去重共享,
析构时反注册(secret_manager_impl.h:87-101,135-140);其 init target 无条件加进所属
listener/cluster 的 init_manager,这正是"CDS/LDS 依赖 SDS"的实现点(secret_manager_impl.h:102-118;
context_config_impl.cc:71-77)。SDS 是单资源订阅,remove 事件仅 ACK 并放行 warming
(sds_api.cc:153-176)。任务书里的 "SecretsEvent" 在 v1.39 并不存在,事件面即
`SecretProvider` 的三类回调 + `Secret::SecretCallbacks::onAddOrUpdateSecret`
(envoy/secret/secret_callbacks.h:15;sds_api.h:153-168;注册即 fire:若 secret 已就绪先同步执行一次,
sds_api.h:158-164)。

## 4. SDS 订阅细节与热轮换链路

订阅构造即创建(SDS 资源 typeUrl `envoy.extensions.transport_sockets.tls.v3.Secret`),
`initialize` 里 `subscription_->start({name})`(sds_api.cc:32-39,208-215)。更新到达:
哈希比较去重 → `validateConfig`(STK/CVC 有校验回调)→ `setSecret` → 建文件 watcher
(目录级 `MovedTo`,支持 K8s secret 原子换名;sds_api.cc:108-148,119-135)→
`loadFiles` 把 filename 型 DataSource 内联化(`resolveDataSource`,sds_api.cc:41-48)→
`update_callback_manager_.runCallbacks()`。文件轮换路径 `onWatchUpdate` 还带 5 次有界重试
的"原子轮换"检测,失败仅告警并 `key_rotation_failed_` 计数(sds_api.cc:50-87,85)。

回调链:provider → `ContextConfigImpl::setSecretUpdateCallback` 重建
`tls_certificate_configs_`/`validation_context_config_`(context_config_impl.cc:318-366)→
factory 的 `onAddOrUpdateSecret` → `manager_.createSslServerContext/createSslClientContext`
构造全新 `SSL_CTX`(旧配置对象原样复用)→ 读写锁 swap,新连接拿新 ctx,旧 ctx 从
ContextManager 移除(server_ssl_socket.cc:79-91;client_ssl_socket.cc:84-95;
context_manager_impl.cc:95-102)。**既不在 SSL_CTX 上 in-place 换证书,也不 drain 存量连接**:
存量 `SslSocket` 持有旧 `ContextImpl` shared_ptr 继续服务,生命周期由引用计数收尾;
listener 配置若因 LDS 重推,`ListenerMessageUtil::filterChainOnlyChange` 命中则走 in-place
filter chain update,被换下的 filter chain 各自 drain(listener_manager_impl.cc:636-641;
listener_impl.cc:1146-1184,1199-1200;listener_manager_impl.h:337)。secret 未就绪时工厂返回
`NotReadySslSocket`(读=写=Close,failureReason="TLS error: Secret is not supplied by SDS",
ssl_socket.h:134-139;ssl_socket.cc:27-31),并计
`downstream/upstream_context_secrets_not_ready`(server_ssl_socket.cc:72;client_ssl_socket.cc:77)。

## 5. Upstream TLS:auto_sni 与 verify 设置

`UpstreamSslSocketFactory` 注册名 "tls",把 `UpstreamTlsContext` 编译成
`ClientSslSocketFactory`(upstream_config.cc:15-31;downstream_config.cc:15-29 对称)。
`ClientContextImpl::newSsl` 决定 SNI 优先级:options 覆盖 > `auto_host_sni`(取 upstream host
hostname)> 静态 `sni`(client_context_impl.cc:130-146);`auto_sni_san_validation` 开启时必须配
validation context(client_context_impl.cc:73-77;default_validator.cc:190-193),校验时把 SNI 作为
DNS 精确 SAN matcher(default_validator.cc:279-281;san_matcher.h:73-85)。per-route SAN 覆盖
`verifySubjectAltNameListOverride` 会强制 `SSL_VERIFY_PEER|FAIL_IF_NO_PEER_CERT`
(client_context_impl.cc:148-150)。ALPN 优先级:override > 上下文静态 > fallback
(client_context_impl.cc:152-172)。`allow_renegotiation` 才放开 `ssl_renegotiate_freely`
(client_context_impl.cc:174-176;读写路径把非预期重协商一律落 Close,ssl_socket.cc:150-155,373)。
多证书 client 上下文默认拒绝,需自定义 upstream selector(`SSL_CTX_set_cert_cb` 异步选证,
client_context_impl.cc:80-84,106-117,225-283)。

## 6. 校验与撤销:CRL/OCSP/钉扎

`DefaultCertValidator::initializeSslContexts` 把 CA(可含 CRL 的 PEM 栈)灌进 `X509_STORE`,
`X509_V_FLAG_PARTIAL_CHAIN`;CRL 存在则 `CRL_CHECK`(可配 leaf-only)或 `CRL_CHECK_ALL`
(default_validator.cc:154-186,195-217;CRL 经进程级共享缓存,199-203)。
`allow_expired_certificate` 映射 `NO_CHECK_TIME`(183-185)。SAN 匹配两类:string matcher(支持
通配/正则/RE2,san_matcher.h:43-68)与 DNS 精确语义 matcher;钉扎双轨:`verify_certificate_hash_list`
(证书 SHA256,hex,可带冒号,default_validator.cc:231-245,510-521)与
`verify_certificate_spki_list`(SPKI SHA256,base64,231-256,486-508),两者任一命中即过,
否则 `fail_verify_cert_hash_`(345-367)。**OCSP 现状**:仅下游 server 侧 stapling——
must-staple 扩展探测(context_impl.cc:234-239)、响应与证书匹配校验(server_context_impl.cc:217-227)、
策略 Lenient/Strict/MustStaple(default_tls_certificate_selector.cc:123-164)、client 能力探测
(server_context_impl.cc:470-479);上行 client 不做 OCSP,CRL/OCSP 撤销均依赖 SDS/文件轮换
+ resume 重验(context_impl.cc:195)实现"可撤销"。

## 7. 失败诊断与统计

`drainErrorQueue` 遍历 BoringSSL 错误队列拼 `failure_reason`(access log 可见),并区分:
peer 未交证书→`fail_verify_no_cert_`;`CERTIFICATE_VERIFY_FAILED` 时附 validator 细节;
无法归类才计 `connection_error_`(ssl_socket.cc:239-328,249-253,318-326);peer RST 单独探测
(SO_ERROR probe,io_handle_bio.cc:45-58;无其他错误时才报告为 ConnectionReset,ssl_socket.cc:295-299)。
握手成功统一走 `logHandshake`:`handshake`、`session_reused`、按 cipher/version/curve/sigalg
分值计数、无对端证书计 `no_certificate`(context_impl.cc:573-598;stats.h:11-23)。工厂级
`ssl_context_update_by_sds` 是观察热轮换的直接指标(ssl_socket.h:32-35;server_ssl_socket.cc:89)。

## 8. 设计动机

1. **为什么 BoringSSL**:编译期即锁定 BoringSSL/AWSLC(context_impl.h:35-37)。BoringSSL 提供
   `select_certificate_cb`、`SSL_ERROR_PENDING_CERTIFICATE`、private key method、compliance
   policy 等 API,是 Envoy 异步证书选择/异步签名/异步校验/FIPS 202205 的前提;OpenSSL 缺这些
   钩子,适配成本远高于维护 fork。
2. **为什么 SNI 回调在 ctx 层而不是 filter chain 层**:证书选择发生在 ClientHello 之后、Certificate
   之前,只有 `SSL_CTX_set_select_certificate_cb`(SSL_CTX 级,server_context_impl.cc:124-132)
   能在发送证书前介入;filter chain 路由发生在 HTTP/L4 过滤器层,晚于证书交换。且每张证书一份
   SSL_CTX、用 `SSL_set_SSL_CTX` 切换(context_impl.h:44-48 注释明言),复用 BoringSSL 原生多证书机制。
3. **为什么热轮换靠 context 重建而非 in-place**:SSL_CTX 不可线程安全地换证书,而重建后引用计数
   天然解决新旧共存——存量连接持旧 `ContextImpl` shared_ptr,新连接从工厂拿新 ctx
   (server_ssl_socket.cc:83-87),无需 drain、无需锁等待(仅一把读写锁包住指针 swap)。重建失败的
   新 ctx 直接拒更新,旧 ctx 不受牵连,回滚语义免费获得。
4. **为什么 SDS 订阅与 CDS/LDS 有依赖**:cluster/listener 引用 secret 时,若先激活配置而证书未到,
   工厂只能给 `NotReadySslSocket`(连接即失败)。把 SdsApi 的 init target 加进所属资源的
   init_manager(secret_manager_impl.h:114-118),让 CDS/LDS 在 warming 阶段等 SDS ready,
   把"引用了不存在的证书"从运行期故障收敛为启动顺序问题。
5. **为什么 client CA 可撤销**:校验语境(trusted CA+CRL)也是 SDS 资源,轮换后重建 context 时
   重灌 X509_STORE;配合 `SSL_CTX_set_reverify_on_resume`(context_impl.cc:195),连 resumed
   session 也要过一遍新 store,CRL 吊销即刻生效——这是"in-place 改 store 做不到"的一致性。
6. **为什么 BIO 自定义**:Envoy 的 IoHandle 抽象(含 win32、io_uring 等后端)与 BoringSSL 的
   fd 假设不匹配;自定义 BIO 让 SSL 层复用 event loop 的非阻塞语义(retry flag),Envoy 侧完全
   不接触密文字节。
7. **为什么静态 secret 不给 update 回调**:静态配置属 bootstrap,重建进程才能换;返回 nullptr
   (secret_provider_impl.h:22-35)让"轮换"在类型上不可表达,避免伪热更新。

## 9. 写作素材清单(文件:行号)

1. `source/common/tls/io_handle_bio.cc:25-59` — BIO read/retry/RST 探测
2. `source/common/tls/ssl_socket.cc:83-87` — BIO 与 SSL 绑定、ex_data 回链
3. `source/common/tls/ssl_socket.cc:110-174` — doRead 全路径(WANT_READ/ZERO_RETURN/end_stream)
4. `source/common/tls/ssl_socket.cc:219-237` — doHandshake 与 readDisable 联动
5. `source/common/tls/ssl_socket.cc:239-328` — drainErrorQueue/failure_reason/统计
6. `source/common/tls/ssl_handshaker.cc:142-173` — 握手状态机与异步错误码
7. `source/common/tls/ssl_handshaker.cc:88-119` — 证书选择完成:SSL_set_SSL_CTX+OCSP staple
8. `source/common/tls/context_impl.cc:89-198` — validator 创建/ciphers/custom verify/reverify
9. `source/common/tls/context_impl.cc:480-531` — newSsl 与 customVerifyCallback
10. `source/common/tls/server_context_impl.cc:124-132,490-544` — select_certificate_cb/异步选证
11. `source/common/tls/default_tls_certificate_selector.cc:166-284` — SNI→证书匹配全算法
12. `source/common/tls/client_context_impl.cc:120-205` — upstream SNI/ALPN/会话复用/auto_sni
13. `source/common/secret/sds_api.cc:89-151` — SDS onConfigUpdate 与文件 watcher
14. `source/common/tls/context_config_impl.cc:318-366` — secret→config 更新回调装配
15. `source/common/tls/server_ssl_socket.cc:54-91` — 热轮换 swap 与 NotReadySslSocket
16. `source/common/tls/cert_validator/default_validator.cc:195-256,345-367` — CRL/hash/spki 钉扎
