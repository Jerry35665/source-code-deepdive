# 第 04 章 · TLS 层与连接管理:竞速、后端矩阵与超时(卷末)

> 基线:commit `0b04700`。行号以 lib/vtls/vtls.c、cf-https-connect.c、cf-ip-happy.c、cf-socket.c、connect.c 为准。**勘误**:TLS 握手过滤器本体是 `Curl_cft_ssl`(vtls.c:1311),不在 cf-https-connect.c;后者是**协议级竞速器**(h3 vs TCP+TLS);后端注册表现名 `available_backends[]`(vtls.c:706-726);apple.c 已不是 sectransp 后端,仅剩 SecTrust 校验辅助(:81,295 行)。

## 4.0 全景:后端矩阵与 filter 链

```
"编译期插件+单全局指针":Curl_ssl 指针(vtls.c:687-704)+ available_backends[](:706-726)
多后端构建走 Curl_ssl_multi 惰性壳(:661-685):curl_global_sslset() > 环境变量
CURL_SSL_BACKEND > 编译宏默认 > 首个可用;选定后 TOO_LATE 不可换

filter 链(连接时组装):HTTPS-CONNECT(协议竞速,cf-https-connect.c:725)
  → SETUP → HAPPY-EYEBALLS(IP 级竞速,cf-ip-happy.c:964) → TCP(cf-socket.c:1861)
  → 连上后补插 SSL 过滤器(vtls.c:1311)
```

| 后端 | 行数 | 特色 |
|---|---|---|
| openssl | 5556 | 全功能:OCSP/CRL/ECH/earlydata(:5508-5530 supports 位) |
| wolfssl | 2347 | 嵌入式 OpenSSL 替代 |
| gtls | 2349 | CRLFILE/ISSUERCERT/OCSP(:2313-2323) |
| mbedtls | 1710 | 嵌入式轻量 |
| rustls | 1460 | Rust 后端,ECH+CRLFILE(:1428-1436) |
| schannel | 2901 | Windows 系统证书存储(:547-553) |
| apple | 295 | 仅 SecTrust 校验辅助,被 openssl/gtls 委托(:4739/:1614) |

## 4.1 双层竞速:协议级与 IP 级

**HTTPS-CONNECT**(cf-https-connect.c:474-579 五态状态机):h3 与 TCP+TLS 双 baller,`time_to_start_baller2`(:238-271)——**零字节回复才启动第二路**(第一路有进展就不浪费);**HAPPY-EYEBALLS**(cf-ip-happy.c:396-616):v4/v6 竞速,A/AAAA 交替(:492-506),并发上限 6(:755),胜者即清空其余尝试。**两级竞速=协议协商与地址族协商的正交**:用户感知是"自动选最快的路",实现是两个独立过滤器。SSL 握手非阻塞契约:后端设 connssl->io_need+返回 CURLE_AGAIN,pollset 按 READ/WRITE 重挂(vtls.c:233-257;openssl.c:4165-4179)。

## 4.2 会话缓存归 curl 层

vtls_scache.c(:367-380):session ticket 缓存 **share 优先、multi 兜底**(multi.c:295 每 peer 2 会话);TLS 1.3=7 天/1.2=1 天(vtls_scache.h:38-40)——**缓存放 curl 层而非各后端**:跨后端一致、随 share 接口共享、后端只管握手。ALPN 细节:协商结果校验(:1689-1755,复用会话 ALPN 不符即拒绝);SNI/IP 判定(:919-932)。

## 4.3 keepalive 与超时矩阵

tcpkeepalive(cf-socket.c:186-338):默认关,idle/intvl/cnt=60/60/9(url.c:401-404),Windows 毫秒换算。超时三层:connecttimeout(默认 300000ms,connect.h:42)与整体 timeout 取 min(connect.c:69-101);LOW_SPEED 中止(progress.c:132-169,每秒检查)vs 令牌桶限速 `MSTATE_RATELIMITING`(multi.c:1964-2000)——**"超时"与"限速"是两个子系统**。

## 4.4 设计动机

1. **为什么 TLS 后端是插件**:合规(多国密码法规)与平台(schannel/apple)的现实——curl 不能"只支持 OpenSSL";矩阵的另一面是**抽象的代价**:vtls 要抹平回调/BIO/SNI/ALPN/证书存储的差异;
2. **会话缓存放 curl 层**:跨后端一致+随 share 接口共享+后端瘦身——**共享状态的上提**是成熟库的常见重构(对照 Git vtls_scache 与 PG stat);
3. **竞速的普遍化**:happy eyeballs(IP 级)→ HTTPS-CONNECT(协议级)——"同时试、谁快用谁"从地址族推广到协议族;每层竞速只赌"启动第二路的时机"(零字节回复判定 :238-271);
4. **非阻塞握手契约**(io_need+CURLE_AGAIN):TLS 库的阻塞 API 被包装成可轮询的状态机——multi 状态机的客户。

## 4.5 FAQ

**Q1:能运行时切换 TLS 后端吗?**
多后端构建可以,但首个传输后 TOO_LATE(:779-821)——全局指针的代价。

**Q2:apple.c 怎么只剩 295 行?**
sectransp 后端移除,SecTrust 校验辅助被 openssl/gtls 委托做 macOS 原生信任(:81)。

**Q3:happy eyeballs 会同时建两条连接吗?**
会(并发上限 6,:755),输者被清(:396-616)——浪费换来低延迟。

**Q4:h3 和 TCP+TLS 怎么赛?**
HTTPS-CONNECT 双 baller(:725):第二路仅在第一路零进展时启动(:238-271)。

**Q5:session ticket 跨进程共享吗?**
share 接口内共享(:367-380);跨进程需 CURLSH+同进程语义。

**Q6:keepalive 为什么默认关?**
(:186-338):历史兼容;现代服务建议显式开。

**Q7:连接失败会自动换 IP 吗?**
会:happy eyeballs 队列内自然尝试下一地址(:492-506)。

**Q8:ALPN 不匹配会怎样?**
复用会话 ALPN 不符即拒(:1689-1755)——防协议降级。

**Q9:三个超时谁先到谁生效?**
connect/整体取 min(connect.c:69-101);LOW_SPEED 是独立维度(:132-169)。

**Q10:证书校验能关吗?**
能(-k)但**每个后端的"不校验"实现都不同**(schannel vs openssl 的 fallback 面)——抽象的代价实例。

## 4.8 小结与卷末语

本章结论:**TLS 层="编译期插件矩阵+非阻塞握手契约+双层竞速";连接管理="竞速普遍化+超时分层"**。

至此《curl 深读》一卷完(01-04+导读,基线 commit 0b04700):骨架→语义→协议→安全。curl 三十年 ABI 不破的秘诀在本卷反复显影:**状态机收权(01)、安全默认进库(02)、H1 交换格式(03)、插件化安全(04)**。全系列至此 12 个项目、144 篇正文+107 份报告。深挖:

1. Curl_ssl_multi 惰性壳(:661-685)在首连接前的选择时机;
2. cf-ip-happy 并发上限 6(:755)对 CDN 多 A 记录的覆盖;
3. vtls_scache(:367)在 multi 与 share 并用时的优先级冲突;
4. MSTATE_RATELIMITING(:1964)令牌桶的突发语义;
5. Curl_protocol 虚表(protocol.h:114)向 MQTT/WebSocket 的扩展前景。

— 《curl 深读》完。AI 编码助手:GLM-5.3-Flash。
