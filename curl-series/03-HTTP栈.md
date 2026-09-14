# 第 03 章 · HTTP 栈:cfilter 洋葱与三代 HTTP

> 基线:commit `0b04700`。行号以 lib/cfilters.c/cfilters.h、lib/http.c、lib/http1.c、lib/http2.c、lib/vquic/ 为准。**勘误**:本 commit 无 lib/http3.c、无 lib/cf-http.c——HTTP/3 在 lib/vquic/cf-ngtcp2.c/cf-quiche.c;协议基类已改名 `struct Curl_protocol`(lib/protocol.h:114),HTTP 请求/响应已成对象(httpreq/http_resp)。

## 3.0 全景:一次 HTTPS 请求的洋葱

```
[socket filter] ←→ [TLS filter] ←→ [HTTPS-CONNECT 竞速] ←→ [H2/H3 filter] → HTTP 语义层
(cfilters 链,头插法 cfilters.c:303;连接时 cf-setup.c:299 渐进组装)
```

**cfilter 架构**(近年最大重构):`Curl_cftype` 虚函数表(cfilters.h:217)+`Curl_cfilter` 链(next 指向更靠 socket 层)。连接时逐层插入 socks/代理/haproxy/SSL/QUIC 并逐级 connect(:299);数据下行 do_send(带 eos)/上行 do_recv+has_data_pending;`adjust_pollset` 实现 H2 窗口耗尽时撤 POLL_OUT 的**背压**;`CF_QUERY_*` 让连接池沿链读协议版本(:619)。

**为什么重构**:HTTP/2/3 的多路复用要求"协议"与"连接"解耦——一条连接上跑 N 个 transfer,每个 transfer 只是一条链。**关键洞见(本卷最漂亮的设计)**:HTTP/1.1 不是过滤器——只有 H2/H3 带 CF_TYPE_HTTP;H1 报文成了通用交换格式:**H2/H3 把上层写好的 H1 文本再解析回 httpreq 转伪头**(http2.c:2087→http.c:4938),响应侧又把 :status 重建成 "HTTP/2 xxx\r\n" 喂回 H1 解析器(http2.c:1534)——**三个版本共享认证/cookie/range/重定向逻辑**,零重复。

## 3.1 H1:请求组装与解析容错

`Curl_http()`(http.c:3038)按 http_hd_t ID 序组装请求(:2883);Expect:100-continue 仅 HTTP/1.1 且 body>1MB(阈值 http.h:151),等待实现为 cr_exp100 client-reader(:1501)。响应逐行 http_parse_headers(:4429)→http_rw_hd(:4237):手写状态行解析,**容忍非单空格、obs-fold 折叠、HTTP/0.9**;空行触发 http_on_response(:4112)裁决。chunked:响应解码是 client-writer(http_chunks.c:464),请求编码是 client-reader(:612)——**编解码皆"过滤器插件"**。

## 3.2 H2/H3:流映射与竞速

H2:每 easy 一个 h2_stream_ctx(http2.c:123)经 stream_user_data 映射;回调 on_frame_recv(:1154)/on_data_chunk_recv(:1262)→Curl_xfer_write_resp;h2_submit 把 H1 文本转 HEADERS 伪头(:2062);GOAWAY→connclose(:516)。H3:单一 cfilter(QUIC+TLS+H3 一体,cf-ngtcp2.c:1091/cf-quiche.c:1626),复用与 H2 相同的 H1 转换;官方仍标 EXPERIMENTAL。**HTTPS-CONNECT 竞速过滤器**(cf-https-connect.c:725):h3 与 TCP+TLS 双 baller 赛跑(soft=hard/2 超时 :758-759),ALPN=h2 时动态插入 H2 过滤器——**协议协商也是一场竞速**(04 章 IP 级竞速的上层镜像)。

## 3.3 设计动机

1. **cfilter 的必然性**:H2/H3 多路复用把"连接"从"传输"中解放——过滤链让"一条连接服务 N 个 transfer"成为结构而非特例;
2. **H1 作为交换格式**:三代 HTTP 共享 H1 语义层的认证/cookie/重定向——**兼容层的代价是一次文本往返,收益是语义层只写一份**;
3. **100-continue 的 1MB 阈值**:小 body 白等的成本>大 body 白传的成本(http.h:151)——阈值即策略;
4. **解析容错的现实**:obs-fold/0.9/非单空格——互联网不是 RFC,解析器必须诚实面对脏世界。

## 3.4 FAQ

**Q1:H1 为什么不是过滤器?**
H2/H3 才需要把连接复用抽象化;H1 一连接一事务,做链顶消费者最简(:CF_TYPE_HTTP 只给 H2/H3)。

**Q2:H2 怎么把响应变回 H1?**
把 :status 重建成 "HTTP/2 xxx\r\n" 喂 H1 解析器(:1534)——语义层零改。

**Q3:H3 成熟吗?**
实验标(EXPERIMENTAL);SOCKS 代理不支持——QUIC 生态仍在长。

**Q4:100-continue 什么时候发?**
HTTP/1.1+body>1MB(:151):大 body 才值得先探。

**Q5:背压怎么实现?**
adjust_pollset 撤 POLL_OUT:H2 窗口耗尽时不再可写——流控传导到 multi 的事件注册。

**Q6:一条 H2 连接能服务多少 transfer?**
流 id 空间+MAX_CONCURRENT_STREAMS 谓词(01 章 :981-1058):可复用性判定的一部分。

**Q7:GOAWAY 之后连接还能用吗?**
connclose(:516):立即标记不可复用,存量流跑完。

**Q8:HTTP/0.9 也支持?**
解析容忍(:4237):三十年兼容的尾部。

**Q9:请求头顺序有保证吗?**
http_hd_t ID 序组装(:2883):同类头相对顺序确定。

**Q10:为什么 h3 是"一个过滤器"?**
QUIC+TLS+H3 在协议上已融合(不可分层插入):一个 cf 封三件事。

## 3.5 小结与深挖方向

本章结论:**HTTP 栈="cfilter 洋葱+H1 通用交换格式+竞速协商"**;协议与连接的解耦是三代 HTTP 的架构总答案。深挖:

1. cf_call_data(cfilters.h:626)在多 easy 嵌套回调的正确性;
2. cr_exp100(:1501)与服务器 100 响应乱序的容错;
3. h2_submit 的伪头排序(:2062)对服务器兼容性;
4. H3 竞速败者(TCP 路径)的资源回收成本;
5. Curl_protocol 虚表(protocol.h:114)对 FTP/SMTP 等的推广。

> 下一章(卷末):TLS 层与连接管理——竞速与后端矩阵。
