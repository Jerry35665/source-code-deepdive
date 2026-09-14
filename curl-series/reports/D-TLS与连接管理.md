# D 报告：curl 的 TLS 抽象层（vtls 多后端）与连接管理（happy eyeballs / keepalive / 超时）

> 基于源码快照：curl 仓库 shallow clone，commit `0b04700`（2026-09-13）。
> 所有行号均为该 commit 下仓库相对路径 `lib/...` 的行号。

---

## 1. 全景：TLS 后端矩阵与 filter 链位置

### 1.1 后端矩阵（编译开关 × 平台默认）

| 后端 | 源文件 | 编译开关 | 典型平台/默认 | 体量(行) | 显著能力位 |
|---|---|---|---|---|---|
| OpenSSL 系 | lib/vtls/openssl.c | `USE_OPENSSL` | 也覆盖 BoringSSL/AWS-LC/LibreSSL 变体 | 5556 | CA_PATH/CAINFO_BLOB/CERTINFO/PINNEDPUBKEY/SSL_CTX/CRLFILE/OCSP/ECH (`openssl.c:5508-5530`) |
| wolfSSL | lib/vtls/wolfssl.c | `USE_WOLFSSL` | 嵌入式 | 2347 | 条件式 PINNEDPUBKEY、HTTPS_PROXY（`wolfssl.c:2302-2310`） |
| GnuTLS | lib/vtls/gtls.c | `USE_GNUTLS` | Linux 发行版常见 | 2349 | CA_PATH/CRLFILE/ISSUERCERT/OCSP（`gtls.c:2313-2323`） |
| mbedTLS | lib/vtls/mbedtls.c | `USE_MBEDTLS` | 嵌入式/IoT | 1710 | CA_PATH/CAINFO_BLOB/CERTINFO（`mbedtls.c:1667-1675`） |
| rustls | lib/vtls/rustls.c | `USE_RUSTLS` | Rust 实现，实验性 | 1460 | ECH/CRLFILE/TLS13 ciphersuites（`rustls.c:1428-1436`） |
| Schannel | lib/vtls/schannel.c | `USE_SCHANNEL` | Windows 默认 | 2901 | 系统证书存储、CERTINFO/CAINFO_BLOB（`schannel.c:2868-2876`） |
| (Apple SecTrust) | lib/vtls/apple.c | `USE_APPLE_SECTRUST` | **不再是独立后端**，而是校验辅助模块 | 295 | 被 openssl/gtls 委托做 trustd 校验（`apple.c:81`） |

关键认知：本 commit 的 curl 里，**`apple.c` 已不是老的 sectransp 后端**——它只提供
`Curl_vtls_apple_verify()` 一个函数（`apple.c:81-88`），供 `openssl.c:4739` 与 `gtls.c:1614`
在 macOS/iOS 上把证书链交给系统 trustd 校验（`native_ca_store` 模式）。macOS 上构建
OpenSSL 版 curl 可以同时获得 OpenSSL 的全部功能与系统钥匙串信任。

### 1.2 cf-https-connect 在 filter 链中的位置

HTTPS（非代理、启用 ALPN）时的完整过滤链（自上而下）：

```
HTTPS-CONNECT   (cf-https-connect.c:725, Curl_cft_http_connect)
 │  ALPN 级 eyeball：baller[0]=h3(QUIC) 或 h2/h1 与 baller[1] 竞速
 └─ SETUP        (cf-setup.c，cf_hc_baller_init 内经 Curl_cf_setup_insert_after 插入, cf-https-connect.c:168-179)
     │  等待 DNS → 插入 HAPPY-EYEBALLS (cf-setup.c:205)
     └─ HAPPY-EYEBALLS (cf-ip-happy.c:964, Curl_cft_ip_happy)
         │  IP 级 eyeball：多个地址/地址族并发试连，最多 6 并发 (cf-ip-happy.c:755)
         └─ TCP (cf-socket.c:1861, Curl_cf_tcp_create)
             │  连接成功后 SETUP 再补插 SSL 过滤器 (cf-setup.c:264-292)
             └─ SSL (vtls.c:1311, Curl_cft_ssl) ← TLS 握手在这里
```

即：TLS 握手过滤器本身在 `vtls.c`（`Curl_cft_ssl`，vtls.c:1311-1326；代理版
`Curl_cft_ssl_proxy`，vtls.c:1330-1345），`cf-https-connect.c` 并不实现 TLS 握手，
而是负责"选 HTTP 版本 + 选传输"的上层竞速。两条 eyeball（HTTP 版本级、IP 地址级）
分层嵌套，是这套 filter 架构的直接产物。

---

## 2. 注册表专节：表驱动与后端选择

### 2.1 全局单指针 + 编译期数组

vtls 不是运行时 dlopen 的插件，而是"编译进来的多个后端 + 一个全局函数表指针"：

```c
const struct Curl_ssl *Curl_ssl =
#ifdef CURL_WITH_MULTI_SSL
  &Curl_ssl_multi;            /* 惰性分发壳 */
#elif defined(USE_WOLFSSL)
  &Curl_ssl_wolfssl;
...（gnutls/mbedtls/rustls/openssl/schannel 依次）
#endif                       /* vtls.c:687-704 */

static const struct Curl_ssl *available_backends[] = {
#ifdef USE_WOLFSSL
  &Curl_ssl_wolfssl,
...
#endif
  NULL
};                           /* vtls.c:706-726 */
```

- 每个后端实现一个 `struct Curl_ssl` vtable（`vtls_int.h:140-190`）：init/cleanup、
  `do_connect`、`send_plain`/`recv_plain`、`shut_down`、`adjust_pollset`、`sha256sum`、
  `get_channel_binding` 等 20 个槽位，外加能力位字段 `supports`（vtls_int.h:146）。
- 单后端编译（未定义 `CURL_WITH_MULTI_SSL`）时 `Curl_ssl` 直接指向该后端，零间接开销。

### 2.2 multi 壳：惰性后端决定

`CURL_WITH_MULTI_SSL` 构建时，`Curl_ssl` 初始指向 `Curl_ssl_multi`（vtls.c:661-685），
它的每个成员函数都先调 `multissl_setup(NULL)` 再转发（如 `multissl_connect`，
vtls.c:610-616）。真正的选择发生在第一次 TLS 调用时（vtls.c:779-821）：

1. 环境变量 `CURL_SSL_BACKEND=<name>` 匹配 `info.name`（vtls.c:795-804）；
2. 编译期宏 `CURL_DEFAULT_SSL_BACKEND`（vtls.c:806-815）；
3. 兜底取 `available_backends[0]`（vtls.c:817-818）。

一旦选定就覆写全局 `Curl_ssl` 指针，**此后不可再换**：应用 API
`curl_global_sslset()` 走 `Curl_init_sslset_nolock()`（vtls.c:825-852），若在
`Curl_ssl != &Curl_ssl_multi` 之后调用返回 `CURLSSLSET_TOO_LATE`（vtls.c:837-838）。
版本字符串会把未选中后端打括号列出：`multissl_version()`（vtls.c:742-777）。

### 2.3 配置的复制与连接绑定

- 用户级配置两份：`data->set.ssl` 与 `data->set.proxy_ssl`（`ssl_easy_config`，
  `vtls_config.h:70+`）；连接级克隆为 `conn->ssl_config` / `conn->proxy_ssl_config`
  （`ssl_filter_config`，`vtls_config.h:32-68`）。过滤器通过
  `Curl_ssl_cf_get_filter_config()` 取（vtls.c:1602-1611），依据是否为代理过滤器二选一。
- 连接复用检查配置一致性：`Curl_ssl_conn_config_match()`（vtls_config.c:136）比较
  CA/证书/验证开关等主配置，避免把 A 主机的 TLS 参数套到 B 连接上。
- 会话缓存键 `scache_key` 也在 peer 初始化时生成：`Curl_ssl_peer_init()`（vtls.c:897-941）
  → `Curl_ssl_peer_key_make()`（`vtls_scache.h:56-66`），由 peer + TLS 配置 + 后端版本号
  组成，保证"同 key 才可复用会话"。

---

## 3. cf-https-connect 专节：两级竞速的上层（ALPN eyeball）与 SSL 过滤器握手

### 3.1 HTTPS-CONNECT 过滤器（选协议）

状态机五态（cf-https-connect.c:43-49）：`CF_HC_RESOLV → CF_HC_INIT → CF_HC_CONNECT
→ CF_HC_SUCCESS / CF_HC_FAILURE`，入口 `cf_hc_connect()`（474-579）。

- INIT：按优先级选 baller1 的 ALPN——HTTPS-RR（285-336）→ 用户 preferred（338-362）→
  wanted/allowed 列表（364-383）；随后尽量配出 baller2（`cf_hc_set_baller2`，440-472，
  需等 HTTPS-RR 完成）。典型对局：h3(QUIC) vs h2/h1(TCP)。
- 竞速启动：hard 超时 = `CURLOPT_HAPPY_EYEBALLS_TIMEOUT`，soft = 其一半
  （cf-https-connect.c:758-759），`Curl_expire_set(EXPIRE_ALPN_EYEBALLS, soft)` 定时
  （519）。
- `time_to_start_baller2()`（238-271）：baller1 已失败 / 耗时超过 hard 超时 /
  超过 soft 超时且 `CF_QUERY_CONNECT_REPLY_MS < 0`（一个字节都没收到），才启动
  baller2——这是"错峰"竞速。
- 胜负结算 `baller_connected()`（195-236）：把胜者子链挂到主链 `cf->next`
  （212-213），清掉败者，重置错误缓冲（219）；若协商出 h2 还要动态插 h2 过滤器
  `Curl_http2_switch_at()`（221-234）。
- 每个 baller 的连接动作是"借壳"执行：临时把 `cf->next` 换成 baller 子链再调
  connect，用完恢复（`cf_hc_baller_connect`，181-193）。

### 3.2 SSL 过滤器本体（vtls.c）与后端握手状态机

TLS 过滤器 `ssl_cf_connect()`（vtls.c:959-1021）分四步：

```c
if(!cf->next->connected) {          /* 1) 先让下层(TCP)连上 */
  result = cf->next->cft->do_connect(cf->next, data, done);
  ...
}
if(!connssl->prefs_checked) {       /* 2) 校验 SSLVERSION 参数 */
  if(!ssl_prefs_check(cf, data)) ...
}
result = connssl->ssl_impl->do_connect(cf, data, done);  /* 3) 后端握手 */
if(!result && *done) {
  cf->connected = TRUE;             /* 4) 记录握手完成时刻 */
  if(connssl->state == ssl_connection_complete)
    connssl->handshake_done = *Curl_pgrs_now(data);
  ...
}
```
（vtls.c:977-1003）

过滤器层的非阻塞契约：过滤器状态机 `ssl_connect_1/2/3/done`（vtls_int.h:82-87），
连接态 `ssl_connection_none/deferred/negotiating/complete`（vtls_int.h:89-94）。
后端在握手中间不睡眠，而是设 `connssl->io_need = CURL_SSL_IO_NEED_RECV/SEND`
（vtls_int.h:105-107）并返回 `CURLE_AGAIN`；multi 循环靠
`Curl_ssl_adjust_pollset()`（vtls.c:233-257）把对应方向的 fd 放进 poll 集，
下次再进来重入同一个 step。以 OpenSSL 为例：

```c
err = SSL_connect(octx->ssl);            /* openssl.c:4147 */
...
if(detail == SSL_ERROR_WANT_READ) {
  connssl->io_need = CURL_SSL_IO_NEED_RECV;
  return CURLE_AGAIN;                    /* openssl.c:4165-4169 */
}
if(detail == SSL_ERROR_WANT_WRITE) {
  connssl->io_need = CURL_SSL_IO_NEED_SEND;
  return CURLE_AGAIN;
}
```

`ossl_connect_common()`（约 openssl.c:4970-5045）驱动 step1（建 SSL_CTX/SSL、
SNI、ALPN、会话加载，`ossl_connect_step1` openssl.c:4012）→ step2（`SSL_connect`
+ 握手后读 ALPN，`ossl_connect_step2` openssl.c:4128，`SSL_get0_alpn_selected`
openssl.c:4363-4365）→ step3（证书校验 `Curl_ossl_check_peer_cert`，openssl.c:4865）。
x509 信任库延迟到发出 ClientHello 之后才装配（openssl.c:4154-4160）。

**ALPN 生成端**（vtls.c:80-122）：按 wanted/preferred 组出 `ALPN_SPEC_H2_H11` 等
静态表，`alpn_get_spec()` 选择；过滤器创建时绑定到 `connssl->alpn`
（`cf_ssl_create`，vtls.c:1349-1382）。协商结果统一走 `Curl_alpn_set_negotiated()`
（vtls.c:1689-1755），其上层消费点：
- `ssl_cf_query(CF_QUERY_ALPN_NEGOTIATED)`（vtls.c:1253-1259）→ HTTPS-CONNECT 的
  h2 判定；
- `CF_CTRL_CONN_INFO_UPDATE` 把 `http/1.1|h2|h3` 写进 `conn->httpversion_seen`
  （vtls.c:1278-1287）。
- 会话复用时 ALPN 必须前后一致，否则拒绝连接（vtls.c:1699-1726："Refusing to
  continue"）。

握手完成时间通过 `TIMER_APPCONNECT` 上报：`CF_CTRL_REPORT_STATS` 或 deferred 完成
路径 `Curl_pgrsTimeWas(data, TIMER_APPCONNECT, ...)`（vtls.c:1068-1071、1288-1295）。

---

## 4. 抽象的代价：vtls 抹平了什么、没抹平什么

vtls 统一了这些上层不用各后端操心的部分：

- **SNI**：`Curl_ssl_peer_init()` 统一生成——DNS 名小写、去尾点、限 64K，IP 地址
  不发 SNI（vtls.c:919-932）；后端只管调各自 API（如 `SSL_set_tlsext_host_name`，
  openssl.c:3614）。
- **ALPN**：spec 表、协议 buf 编解码（`Curl_alpn_to_proto_buf`，vtls.c:1613-1634）、
  协商结果记录与 h2 切换判定，全在公共层。
- **密钥日志**：`lib/vtls/keylog.c` 统一实现 `SSLKEYLOGFILE` 写文件
  （`Curl_tls_keylog_write_line`，keylog.c:76-94）；连接完成时提示
  （vtls.c:1004-1010，含 LibreSSL 只支持 TLS≤1.2 的注记）。后端仅在能挂上游回调时
  用上游机制，否则事后补导出 TLS1.2 secret（openssl.c:4162-4167）。
- **会话缓存**：cache 归 curl 所有（见 §7.2），后端只负责序列化/反序列化自己的
  会话对象（OpenSSL 存 DER：`d2i_SSL_SESSION`，openssl.c:3325）。
- **pinned pubkey**：`Curl_pin_peer_pubkey()` 公共实现（vtls.c:442-581），后端只需
  提供 sha256（vtls.c:462-472）。
- **证书信息导出**：`Curl_ssl_init_certinfo`/`push_certinfo`（vtls.c:313-364）。

没有抹平、形成"著名差异"的部分：

- **能力位 `supports`**：CRLFILE 仅 openssl/gtls/rustls/mbedtls(条件) 支持；
  SSL_CTX 导出基本只有 OpenSSL 系；OCSP stapling 支持查询
  `cert_status_request()` openssl/gtls/rustls/wolfssl/mbedtls 有，schannel 恒 NULL
  （schannel.c:2886；对比 openssl.c:5541、gtls.c:2334）。
- **证书校验引擎**：schannel 直接用系统 CryptoAPI 链
  （`CertGetCertificateChain`，schannel_verify.c:761；系统存储
  `CERT_STORE_PROV_SYSTEM`，schannel.c:547-553）；macOS 上 openssl/gtls 可通过
  apple.c 委托 trustd（openssl.c:4815-4830，SecTrust 验证失败才报错）；rustls 用
  webpki 根 + 自定义 verifier（`rustls_verify_server_cert_params`，rustls.c:390）。
- **unverified 会话不复用**：OpenSSL 路径在复用会话时仍检查 verify 结果，来自未
  验证连接的会话丢弃（openssl.c:3332-3341），且 SecTrust 验证结果随会话记忆
  （`sectrust_verified`，openssl.c:3333-3337、4741-4749）。
- **Early data（TLS 1.3 0-RTT）**：公共状态机在 vtls.c（`ssl_cf_connect_deferred`，
  vtls.c:1045-1095：连接推迟到第一次 send/recv 才真正握手，先缓冲 earlydata），
  只有实现了 `HAVE_OPENSSL_EARLYDATA` 等的后端真正发送
  （`SSL_write_early_data`，openssl.c:4890-4900；接受/拒绝上报
  `Curl_pgrsEarlyData`，vtls.c:1075-1086）。

---

## 5. happy eyeballs 专节

curl 现在有**两层** happy eyeballs。都基于同一原理：非阻塞多路尝试 + 定时器错峰 +
先到先得。

### 5.1 IP 层竞速（cf-ip-happy.c，经典 A/AAAA 竞速的推广）

- 每次"尝试"= 一个 `cf_ip_attempt`（160-177），持有独立子 filter 链（TCP/QUIC/UDP
  由 `transport_providers[]` 表创建，cf-ip-happy.c:73-89）。
- 并发上限 `IP_HE_MAX_CONCURRENT_ATTEMPTS = 6`（cf-ip-happy.c:755），超出时丢弃
  最老的未完成尝试（`cf_ip_ballers_prune`，365-394）。
- 启动节奏：`attempt_delay_ms` 取自 `CURLOPT_HAPPY_EYEBALLS_TIMEOUT` 默认值
  （cf-ip-happy.c:1001-1005），仅在"还有地址未试"且距上次启动超过该间隔才开下一个
  （`cf_ip_ballers_run` 内 478-483）。
- **地址族交替**：优先试 IPv6，A/AAAA 轮流（`last_attempt_ai_family` 初始
  AF_INET 以便下一个是 v6，cf-ip-happy.c:361；选择逻辑 492-506）。
- 胜负判定（424-462）：任一尝试 `*connected` → 立即宣布 winner、**清空并释放其余
  全部尝试**（436-441）；硬失败立刻出链丢弃并记 `last_dead_result`（452-460）；
  `CURLE_WEIRD_SERVER_REPLY` 视为 inconclusive（259-260），全部地址试完后还可
  重启 inconclusive 的尝试（543-573）。
- 定时回场：无胜者时计算 `EXPIRE_HAPPY_EYEBALLS` 下次到期时间（583-613），同时
  每轮都检查整体连接超时 `Curl_timeleft_now_ms < 0` → `CURLE_OPERATION_TIMEDOUT`
  （414-418）。
- 胜者安装（`cf_ip_happy_connect`，837-916）：`cf->next = winner->cf`
  （887-888），清 timers、清错误缓冲、`numconnects++`（903-907）。
- 每个 socket 尝试的"响应速度"由 `CF_QUERY_CONNECT_REPLY_MS` 提供：
  socket 层记 `first_byte_at - started_at`（cf-socket.c:1819-1825），竞速器取所有
  尝试的最小值（cf-ip-happy.c:668-681）。

### 5.2 协议层竞速（cf-https-connect.c，h3 vs h2/h1）

见 §3.1。soft 超时（一半）+ "零字节回复"才启动第二个 baller
（cf-https-connect.c:262-269），防止在 h2 本来很快的网络上白白多发 QUIC 握手。
两个 baller 各自内部又各含一条完整的 HAPPY-EYEBALLS 子链——两层竞速正交组合。

---

## 6. keepalive 与超时矩阵

### 6.1 socket 选项（cf-socket.c）

- **TCP_NODELAY**：`tcpnodelay()`（152-169），默认开启（`set->tcp_nodelay = TRUE`，
  url.c:406），`CURLOPT_TCP_NODELAY` 可关。
- **TCP keepalive**：`tcpkeepalive()`（186-338）。默认关闭（url.c:401）；
  `CURLOPT_TCP_KEEPIDLE/KEEPINTVL/KEEPCNT` 默认 60/60/9 秒（url.c:402-404）。平台分派：
  Windows ≥10 1709 用 `TCP_KEEPIDLE/KEEPINTVL/KEEPCNT`（202-238），更老版本走
  `WSAIoctl(SIO_KEEPALIVE_VALS)` 且毫秒换算（180、241-263）；Linux/BSD 用
  `TCP_KEEPIDLE/INTVL/CNT`（265-291、328-335）；macOS 用 `TCP_KEEPALIVE`（273-281）；
  Solaris <11.4 用 `TCP_KEEPALIVE_THRESHOLD/ABORT_THRESHOLD`（282-327）。
- 选项落地点：`cf_socket_open()`——socket() 即非阻塞（1204-1217；回调存在时事后补
  `curlx_nonblock`，1324-1333），IPv6 关闭 `IPV6_V6ONLY`（Windows，1226-1238），
  NODELAY/keepalive 仅对 TCP 生效（1266-1274），用户 `CURLOPT_OPENSOCKETFUNCTION`
  回调（1276-1291），本地绑定 `bindlocal()`（1300）。
- **TCP Fast Open**：`do_connect()`（1353-1406）——Darwin `connectx`（1364-1386）、
  Linux ≥4.11 `TCP_FASTOPEN_CONNECT`（1387-1393）、老内核 MSG_FASTOPEN 仅非 TLS
  （1394-1399）。

### 6.2 超时矩阵（层次与触发点）

| 层次 | 选项/来源 | 定时器 | 起点 | 触发点 |
|---|---|---|---|---|
| 连接超时 | `CURLOPT_CONNECTTIMEOUT_MS`（默认 300000ms，connect.h:42） | `EXPIRE_CONNECTTIMEOUT`（multi.c:2495-2499） | `TIMER_STARTSINGLE` | `timeleft_now_ms()` 在"正在连接"分支计算（connect.c:75-82）；ip-happy 每轮复查（cf-ip-happy.c:414-418） |
| 整体超时 | `CURLOPT_TIMEOUT_MS` | `EXPIRE_TIMEOUT`（multi.c:2491-2493） | `TIMER_STARTOP` | 同函数另一分支（connect.c:85-94），两者取 min（connect.c:98-101） |
| 限速暂停 | `CURLOPT_MAX_SEND/RECV_SPEED_LARGE`（令牌桶） | `EXPIRE_TOOFAST` | — | `mspeed_check()`（multi.c:1964-2000），进入 `MSTATE_RATELIMITING`（multihandle.h:60） |
| 低速中止 | `CURLOPT_LOW_SPEED_LIMIT/TIME` | `EXPIRE_SPEEDCHECK`（每 1s，progress.c:169） | 速度首次低于阈值时记 `keeps_speed` | `pgrs_speedcheck()`（progress.c:132-167）：持续低于 limit 达 time 秒 → `CURLE_OPERATION_TIMEDOUT` |
| HE 竞速 | `CURLOPT_HAPPY_EYEBALLS_TIMEOUT` | `EXPIRE_HAPPY_EYEBALLS` / `EXPIRE_ALPN_EYEBALLS` | 每次尝试启动 | cf-ip-happy.c:569/612、cf-https-connect.c:519 |

multi 层聚合：`multi_timeout()`（multi.c:3508-3543）取所有 easy 的最早到期定时器
（`Curl_timeouts_next_ms`），`curl_multi_timeout()` 暴露给应用（3545+）。
`EXPIRE_*` 全表在 urldata.h:496-509；mstate 全表 multihandle.h:48-65。
SSL 关闭阶段还有独立预算：`Curl_cshutdn_timeleft_ms`，超时即放弃关闭
（vtls_shutdown_blocking，vtls.c:1506-1558）。

层次关系：connect timeout 是 overall timeout 在连接阶段的"提前收紧"（min 合并）；
low-speed 与 rate-limit 作用于传输阶段；HE 超时只控制"何时并行开新尝试"，最终仍受
connect timeout 约束（cf-ip-happy.c:586-593 用 `CURLMIN(next_expire_ms,
timeleft)` 保证）。

---

## 7. 设计动机

### 7.1 为什么 TLS 后端是"编译期插件"

- 平台与合规约束差异巨大（Windows 强推 Schannel、FIPS 环境要特定库、嵌入式只要
  mbedtls/wolfssl），curl 无法内嵌固定实现；但 C 生态没有统一 ABI，于是采用
  "vtable + 编译开关 + 单全局指针"：单后端构建零间接，多后端构建用 multi 壳惰性
  选择（§2.2），环境变量让发行版打包者一次编译满足多种用户。
- 代价：运行时切换不可逆（`CURLSSLSET_TOO_LATE`）、能力差异要靠 `supports` 位
  逐项查询（`Curl_ssl_supports`，vtls.c:1500-1504）。

### 7.2 session 缓存为何归 curl 层

- 会话数据（session ticket / session ID）生命周期跨连接、跨 easy，归属 multi 或
  share 才能跨 transfer 共享：`cf_ssl_scache_get()` 优先取 share 的
  `ssl_scache`，否则 multi 的（vtls_scache.c:367-380）；multi 创建时每 peer 存 2
  个会话（multi.c:295）。
- curl 层持有抽象 `struct Curl_ssl_session`（含 ALPN、earlydata 上限、验证标记、
  过期时间），后端只存不透明的序列化载荷；配额/淘汰/LRU/锁（`Curl_ssl_scache_lock`，
  vtls_scache.c:687-705，share 模式映射到 `CURL_LOCK_DATA_SSL_SESSION`）统一实现。
- 寿命策略：默认 1 天（vtls_scache.c:644），TLS1.3 会话最长 7 天、TLS1.2 最长 1 天
  （vtls_scache.h:38-40，对应 RFC 8446 上限）。
- 好处：校验状态、ALPN 一致性、earlydata 决策这些跨后端语义只需写一次
  （openssl.c:3317-3388 消费；vtls.c:1757-1785 `Curl_on_session_reuse` 决定是否
  发 0-RTT）。

### 7.3 happy eyeballs 的用户价值

- IPv6 部署参差：AAAA 可能路由黑洞。IP 层竞速（5.1）用有限并发（≤6）+ 间隔启动，
  把"坏路径"的代价从完整超时降到 `happy_eyeballs_timeout` 级别；inconclusive
  （WEIRD_REPLY）不判死，支持"服务器正在重启"的场景重试（cf-ip-happy.c:543-573）。
- HTTP/3 不可达（UDP 被墙）同理由协议层竞速兜底（5.2），且 QUIC 失败可无感回落
  h2/h1。两层正交，curl 用 filter 链把指数级的组合（传输×地址族×地址×协议）自然
  编排出来，而不需要专门的状态机。

---

## 8. FAQ 素材

1. **curl 能同时编译多个 TLS 后端吗？运行时怎么选？** 能（`CURL_WITH_MULTI_SSL`）。
   顺序：`curl_global_sslset()` > 环境变量 `CURL_SSL_BACKEND` > 编译宏
   `CURL_DEFAULT_SSL_BACKEND` > 首个可用（vtls.c:779-821）；选定后不可改
   （vtls.c:837-838）。
2. **为什么我的 macOS curl 用 OpenSSL 却信任系统钥匙串？** `USE_APPLE_SECTRUST`
   下 OpenSSL/GnuTLS 校验失败且 `native_ca_store` 开启时委托 SecTrust 再验
   （openssl.c:4815-4830）。
3. **TLS 握手如何做到非阻塞？** 后端返回 `CURLE_AGAIN` + `io_need` 标记读/写方向，
   过滤器 `adjust_pollset` 注册 fd，multi 循环到期重入同一 step（vtls.c:233-257、
   openssl.c:4165-4179）。
4. **`__connecting_state` 的 step1/2/3 分别干嘛？** step1 建 SSL/设 SNI/ALPN/载会话；
   step2 跑握手；step3 证书校验（openssl.c:4012/4128/4865）。
5. **会话复用时 ALPN 一定一致吗？** 强制一致，否则 "Refusing to continue"
   （vtls.c:1699-1726）——否则已按 h2 装好的过滤器链会对不上。
6. **0-RTT 什么时候发？** 会话允许 earlydata 且 ALPN 匹配时，连接进入
   `ssl_connection_deferred`，推迟到首个应用字节才握手并发 earlydata；被服务器
   拒绝则回退重发（vtls.c:1045-1095、openssl.c:3363-3378）。
7. **happy eyeballs 默认间隔是多少？** `CURLOPT_HAPPY_EYEBALLS_TIMEOUT` 默认值同时
   用作 IP 层启动间隔与 ALPN 层 hard 超时（soft 为其一半，cf-https-connect.c:758-759；
   IP 层并发上限 6，cf-ip-happy.c:755）。
8. **keepalive 默认开吗？** 不开；开完后 idle=60s、intvl=60s、 probes=9
   （url.c:401-404），Windows 老版本自动做毫秒换算（cf-socket.c:180）。
9. **connect timeout 和 timeout 同时设，哪个生效？** 连接阶段取两者剩余的较小值
   （connect.c:98-101），连接超时默认 5 分钟（connect.h:42）。
10. **LOW_SPEED 和 MAX_SPEED 有什么区别？** 前者是"持续太慢则中止"
    （progress.c:132-167），后者是令牌桶主动限速、进入 `MSTATE_RATELIMITING`
    等待（multi.c:1964-2000）。

## 深挖建议

1. **两条竞速链的嵌套细节**：HTTPS-CONNECT 的每个 baller 借 `cf->next` 临时换链
   执行 connect（cf-https-connect.c:181-193），出错传播与 failf 缓冲重置
   （`Curl_reset_fail`，cf-https-connect.c:219、cf-ip-happy.c:510、906）值得画图。
2. **session cache 的 key 语义**：`Curl_ssl_peer_key_make` 把 TLS 配置混入 key，
   可以实验验证：改 CAfile 后同一主机不再复用会话。
3. **deferred 握手与 earlydata 计数**：`earlydata_skip` 在被接受时跳过应用层重发
   字节（vtls.c:1139-1152），配合 `Curl_pgrsEarlyData` 正负计数（1075-1086）。
4. **Windows keepalive 的版本矩阵**：Win10 1709 前后两条路径 + `KEEPALIVE_FACTOR`
   毫秒换算（cf-socket.c:171-338）是跨平台 socket 选项处理的范本。
5. **multi 壳的线程安全边界**：`multissl_setup` 只在 global init 锁内被 API 触发，
   其余入口都假设单线程初始化完成（vtls.c:593-633），可对照 `curl_global_init`
   文档讨论。

---

## 写作要点速查表

| 关键函数/结构 | 位置 | 一句话 |
|---|---|---|
| `Curl_ssl` 全局指针 | lib/vtls/vtls.c:687-704 | 编译期默认后端选择链 |
| `available_backends[]` | lib/vtls/vtls.c:706-726 | 多后端注册表（表驱动） |
| `Curl_ssl_multi` | lib/vtls/vtls.c:661-685 | multi 壳 vtable |
| `multissl_setup()` | lib/vtls/vtls.c:779-821 | 环境变量/编译宏/兜底选择 |
| `Curl_init_sslset_nolock()` | lib/vtls/vtls.c:825-852 | curl_global_sslset 实现 |
| `struct Curl_ssl`（vtable） | lib/vtls/vtls_int.h:140-190 | 后端接口 20 槽 |
| `ssl_connect_data` / 三组状态枚举 | lib/vtls/vtls_int.h:82-136 | 过滤器握手状态 |
| `alpn_get_spec()` | lib/vtls/vtls.c:98-122 | ALPN 表生成 |
| `Curl_cft_ssl` | lib/vtls/vtls.c:1311-1326 | SSL 过滤器（代理版 1330-1345） |
| `ssl_cf_connect()` | lib/vtls/vtls.c:959-1021 | 先连下层再握手 |
| `Curl_ssl_adjust_pollset()` | lib/vtls/vtls.c:233-257 | io_need → poll 方向 |
| `Curl_alpn_set_negotiated()` | lib/vtls/vtls.c:1689-1755 | ALPN 结果记录/校验 |
| `Curl_vtls_apple_verify()` | lib/vtls/apple.c:81 | SecTrust 委托校验 |
| `ossl_connect_step1/2/3` | lib/vtls/openssl.c:4012/4128/4865 | OpenSSL 握手三步 |
| `SSL_connect` WANT_READ/WRITE→AGAIN | lib/vtls/openssl.c:4147-4179 | 非阻塞握手核心 |
| `ossl_apply_session()` | lib/vtls/openssl.c:3317-3388 | 会话复用+验证检查 |
| `Curl_ossl_check_peer_cert()` | lib/vtls/openssl.c:4760+ | 证书校验总入口 |
| `cf_ssl_scache_get()`（归属） | lib/vtls/vtls_scache.c:367-380 | share 优先于 multi |
| `Curl_ssl_scache_lock()` | lib/vtls/vtls_scache.c:687-705 | 会话缓存锁 |
| `Curl_cft_http_connect` / `cf_hc_connect` | lib/cf-https-connect.c:725-740 / 474-579 | ALPN eyeball 状态机 |
| `time_to_start_baller2()` | lib/cf-https-connect.c:238-271 | soft/hard 超时错峰 |
| `baller_connected()` | lib/cf-https-connect.c:195-236 | 胜者接链 + h2 切换 |
| `Curl_cft_ip_happy` / `cf_ip_ballers_run` | lib/cf-ip-happy.c:964-979 / 396-616 | IP 竞速主循环 |
| `IP_HE_MAX_CONCURRENT_ATTEMPTS` | lib/cf-ip-happy.c:755 | 并发尝试上限 6 |
| `tcpnodelay()` / `tcpkeepalive()` | lib/cf-socket.c:152-169 / 186-338 | socket 选项 |
| `cf_socket_open()` | lib/cf-socket.c:1193-1351 | 非阻塞/绑定/回调 |
| `do_connect()`（TFO） | lib/cf-socket.c:1353-1406 | TCP Fast Open 分派 |
| `CF_QUERY_CONNECT_REPLY_MS` | lib/cf-socket.c:1819-1825 | 首字节延迟 |
| `timeleft_now_ms()` | lib/connect.c:69-101 | connect/overall 超时合并 |
| `DEFAULT_CONNECT_TIMEOUT` | lib/connect.h:42 | 默认 300000ms |
| `EXPIRE_*` 定时器表 | lib/urldata.h:496-509 | 定时器 id 全集 |
| `multistate_setup()`（超时安装） | lib/multi.c:2484-2500 | TIMEOUT/CONNECTTIMEOUT 挂表 |
| `mspeed_check()` | lib/multi.c:1964-2000 | 限速 → MSTATE_RATELIMITING |
| `pgrs_speedcheck()` | lib/progress.c:132-169 | 低速中止 + 每秒复查 |
| `multi_timeout()` | lib/multi.c:3508-3543 | multi 层定时聚合 |
| `Curl_ssl_scache` 生命周期常量 | lib/vtls/vtls_scache.h:38-40, vtls_scache.c:644 | 1.3=7d / 1.2=1d / 默认 1d |
