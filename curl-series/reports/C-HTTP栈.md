# C 篇：curl 的 HTTP 栈 —— cfilter 过滤器架构与 HTTP/1.1、HTTP/2、HTTP/3

> 调研对象：curl 源码，shallow clone，commit `0b04700`（2026-09-13）。
> 所有 `文件:行号` 均为仓库相对路径（`lib/...`）。
>
> **重要勘误（相对任务提示）**：在该 commit 上，任务提示中的部分文件布局已过时——
> `lib/http3.c` 与 `lib/cf-http.c` **不存在**。HTTP/3 实现位于 `lib/vquic/`（`cf-ngtcp2.c`、
> `cf-quiche.c`、`cf-ngtcp2-cmn.c`）；HTTP/1.1 的响应头解析在 `lib/http.c` 内
> （`http_parse_headers`/`http_rw_hd`），`lib/http1.c`（347 行）只保留 H1 请求行的
> 解析/写出工具。协议处理器基类也已从 `Curl_handler` 更名为 `Curl_protocol`
> （lib/protocol.h:114）。本文按实际代码撰写。

---

## 1. 全景：一次 HTTPS 请求的洋葱图

curl 把"建立连接"与"跑协议"彻底分层。每个 `connectdata` 在每个 socket 索引上
挂着一条**连接过滤器链**（cfilter chain，lib/cfilters.h:235-243），数据永远从链顶
流向链底（发送）或反向（接收）。一次 `curl https://example.com/` 的典型链：

```
        上层：multi 状态机 → Curl_http()（http.c:3038，HTTP 语义层，不在 cfilter 链内）
                                    │  请求：dynbuf -> Curl_req_send(request.c:380)
                                    │  响应：scheme->run->write_resp(transfer.c:746)
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ [HTTP/2]  cf_h2_send/recv          http2.c:2764（仅当 ALPN 协商出 h2）│
│   │ HEADERS/DATA 帧 <-> 流映射（每个 easy 一个 stream）               │
┌──┴───────────────────────────────────────────────────────────────────┐
│ [HTTPS-CONNECT] cf_hc_connect      cf-https-connect.c:725            │
│   │  "eyeball" 双球赛跑：h3 baller vs TCP baller（软/硬超时）          │
│   │                                                                  │
│   ├──(胜者=h3)──► [HTTP/3] Curl_cft_http3   vquic/cf-ngtcp2.c:1091   │
│   │                QUIC + TLS1.3 + H3 三合一，直连 UDP                │
│   │                                                                  │
│   └──(胜者=tcp)─► [SSL] Curl_cft_ssl        vtls/vtls.c:1311          │
│                     │  TLS 握手，ALPN 选出 h1/h2                      │
│                   [IP-HAPPY] cf-ip-happy    cf-ip-happy.c            │
│                     │  IPv6/IPv4 双栈赛跑                            │
│                   [DNS] cf-dns            vdns/cf-dns.c              │
│                     │  域名解析（含 DoH）                            │
│                   [TCP] Curl_cft_tcp       cf-socket.c:1844          │
└──────────────────────────────────────────────────────────────────────┘
```

要点：**HTTP 语义层（http.c）永远只面对"一条抽象的字节流/消息通道"**。它把请求
按 HTTP/1.1 文本格式写进发送缓冲；若下面是 H2/H3 过滤器，由过滤器自己把这份 H1
报文**重新解析**并转成 HEADERS 帧（见 §4）。响应侧则相反：H2/H3 过滤器把
`:status` 与头部字段**重建成 H1 风格文本行**再交给上层（http2.c:1534-1560）。

代理场景下的链更长：`cf-setup.c:299-362`（`cf_setup_connect_steps`）在连接过程中
逐级插入 SOCKS、HTTP 代理（`cf-h1-proxy.c`/`cf-h2-proxy.c` 隧道）、HAProxy、SSL、
QUIC-capsule 等过滤器，每插一级就连一级。

## 2. cfilter 架构专节

### 2.1 虚函数表与实例

过滤器分"类型"（`struct Curl_cftype`，虚函数表，lib/cfilters.h:217-232）与"实例"
（`struct Curl_cfilter`，lib/cfilters.h:235-243）：

```c
/* lib/cfilters.h:217-243（节选） */
struct Curl_cftype {
  const char *name;                        /* 过滤器名，如 "TCP"、"SSL"、"HTTP/2" */
  int flags;                               /* CF_TYPE_* 能力位 */
  Curl_cft_connect *do_connect;            /* 建立连接 */
  Curl_cft_send *do_send;                  /* 发数据（带 eos 尾包标记） */
  Curl_cft_recv *do_recv;                  /* 收数据 */
  Curl_cft_cntrl *cntrl;                   /* 事件/控制 */
  Curl_cft_query *query;                   /* 链上查询（未知则下传） */
  ...
};
struct Curl_cfilter {
  const struct Curl_cftype *cft;
  struct Curl_cfilter *next;               /* 链表，next 是更靠近 socket 的一层 */
  void *ctx;                               /* 类型私有状态 */
  struct connectdata *conn;
  int8_t sockindex;
  BIT(connected);
};
```

能力位（cfilters.h:208-214）：`CF_TYPE_IP_CONNECT`（IP 级连接，含 QUIC/隧道）、
`CF_TYPE_SSL`、`CF_TYPE_MULTIPLEX`（可多路复用多个 easy）、`CF_TYPE_HTTP`、
`CF_TYPE_SETUP`（连接建立后可拆除）等。全库扫描显示实现了 `CF_TYPE_HTTP` 的
过滤器只有三类：nghttp2 的 H2 过滤器（http2.c:2766）与 ngtcp2/quiche 两个 H3
过滤器（vquic/cf-ngtcp2.c:1091、vquic/cf-quiche.c:1626）——**HTTP/1.1 不是过滤器**，
它是多状态机里的协议处理器（§3）。

### 2.2 链的构建与生命周期

- `Curl_cf_create()`（cfilters.c:283-301）：按类型造实例，未挂链。
- `Curl_conn_cf_add()`（cfilters.c:303-315）：**头插**到 `conn->cfilter[sockindex]`，
  所以"后加的在上层"。`Curl_conn_cf_insert_after()`（cfilters.c:317-330）支持在链中
  插入整条子链——这是 H2 过滤器在 TLS 之上插入用的（http2.c:2825）。
- 连接是**渐进式**的：每个过滤器的 `do_connect` 先把 `cf->next` 连上，再做自己的
  握手。`cf_setup_connect_steps`（cf-setup.c:299-362）是教科书式的动态组装：
  `goto connect_sub_chain` 循环里依次插入 ip-happy → socks → http 代理 → haproxy →
  SSL/QUIC，插一级连一级。
- `Curl_conn_ev_data_setup/DONE/DONE_SEND`（cfilters.h:541-553）把"一个 transfer
  开始/结束"广播给全链，H2 过滤器借此为每个 easy 建/拆 stream（http2.c:257-302）。

### 2.3 数据上下行通道

- 下行（发送）：`Curl_cf_send(cf, data, buf, len, eos, &n)`（cfilters.h:511）调用链顶
  的 `do_send`。默认实现 `Curl_cf_def_send`（cfilters.c:84-92）直接透传给 `cf->next`；
  H2/H3/代理过滤器则**消费**这些字节转成帧。`eos` 参数（cfilters.h:89）让"半关闭"
  可以穿透整条链。
- 上行（接收）：`Curl_cf_recv`（cfilters.h:503）+ `has_data_pending`（cfilters.h:82）
  用于"链里还有没有憋着的字节"（TLS 解密缓冲、H2 流缓冲都靠它报告）。
- bufq 便利层：`Curl_cf_recv_bufq/Curl_cf_send_bufq`（cfilters.h:520-535）。
- 流控反压：`Curl_cft_adjust_pollset`（cfilters.h:78-80）。头部注释举例：TLS 握手期
  动态增删 POLL_IN/POLL_OUT；**H2 流窗口耗尽时撤掉 POLL_OUT、改订阅 POLL_IN**
  等 WINDOW_UPDATE——这正是"把协议放进过滤器"才做得到的精细化事件控制。

### 2.4 事件、查询与"当前 easy"难题

- 控制事件 `CF_CTRL_DATA_SETUP/PAUSE/DONE/DONE_SEND/FLUSH...`（cfilters.h:114-124）
  经 `Curl_conn_cf_cntrl` 按 first-fail 或 ignore 语义广播。
- 查询 `CF_QUERY_MAX_CONCURRENT / CONNECT_REPLY_MS / SOCKET / HTTP_VERSION /
  ALPN_NEGOTIATED ...`（cfilters.h:167-183）：过滤器不认识就把查询下传。连接池
  判断复用时，`Curl_conn_http_version()`（cfilters.c:619-643）沿链找到第一个
  `CF_TYPE_HTTP` 过滤器问版本——这是"连接是谁的协议"这一信息从协议层移入
  连接层的直接证据。
- **cf_call_data 机制**（cfilters.h:626-690）：过滤器回调是"链上的连接"被多个 easy
  复用，而底层回调（如 nghttp2 的 send_callback）随时可能换成另一个 easy 触发。
  `CF_DATA_SAVE/RESTORE/CF_DATA_CURRENT` 在过滤器 ctx 里保存"本次调用属于哪个
  easy"，支持嵌套（DEBUGBUILD 还带 depth 校验），源头是 issue #10336
  （cfilters.h:627 注释）。http2.c:117-118 把它定义为 `cf_h2_ctx.call_data`。

### 2.5 与旧架构的对照：为什么必须重构

旧 curl 中"每协议自管 socket"：`Curl_handler` 只有 `do/done/connecting` 等粗粒度
钩子，socket 收发直接绑定在 `connectdata` 上，协议栈（如 H2）如果想多路复用，
就必须自己窥视底层 socket、自己管理读写缓冲，与 FTP/HTTP 代理等代码互相打补丁。
cfilter 化之后：

1. 协议（H2/H3）成为连接上的**可插拔段**：ALPN 协商出 h2 才插入 H2 过滤器
   （cf-https-connect.c:216-227 中 `baller_connected` 检查 ALPN 后调
   `Curl_http2_switch_at`，http2.c:2873）；协商出 h1 就什么协议过滤器都不插。
2. 连接复用/多路复用由**链的能力位与查询**描述（`CF_TYPE_MULTIPLEX`、
   `CF_QUERY_MAX_CONCURRENT`），连接池与 multi 状态机不再关心协议细节。
3. 隧道（HTTP 代理 CONNECT、SOCKS、QUIC 代理）全部变成链上的普通过滤器
   （cf-h1-proxy.c、cf-h2-proxy.c、cf-ngtcp2-proxy.c），同一套 connect/send/recv
   状态机驱动，无需每个协议单独实现一遍代理逻辑。

## 3. HTTP/1.1 专节

### 3.1 请求组装：`Curl_http()`（lib/http.c:3038-3205）

`Curl_http` 由 multi 的 DO 阶段调用（http.c:3034 注释），步骤：

1. `http_check_new_conn`（新连接附加处理）+ `Curl_headers_init`（h1 3124 行附近）；
2. `Curl_http_method` 决定方法与 `Curl_HttpReq` 枚举（GET/POST/PUT...，http.h:31-38）；
3. `http_set_aptr_host`（http.c:2026）选 Host；`Curl_http_output_auth`（http.c:798）
   算认证头；
4. `set_reader`（http.c:2318）装配**请求体 client-reader 栈**：postfields 用
   `Curl_creader_set_buf`（http.c:2351）、fread 用 `Curl_creader_set_fread`
   （http.c:2331-2367，回调上传且未知长度时以 `chunked ? -1 : postsize` 传入）；
5. `http_request_version` 决定版本，然后**按固定 ID 序**写头：

```c
/* lib/http.c:3090-3096 */
for(hd_id = 0; hd_id <= H1_HD_LAST; ++hd_id) {
  result = http_add_hd(data, &req, (http_hd_t)hd_id,
                       httpversion, method, httpreq);
  ...
}
...
Curl_xfer_setup_sendrecv(data, FIRSTSOCKET, -1);
result = Curl_req_send(data, &req, httpversion);
```

`http_hd_t` 枚举在 http.c:2854-2883；`http_add_hd`（http.c:2883-3020）switch 每个
ID：`H1_HD_REQUEST` 写请求行（`http_target`，http.c:2117——经代理时把完整绝对 URL
作 target，IDN 主机名要换成解码形式）；`H1_HD_HOST/USER_AGENT/ACCEPT/
ACCEPT_ENCODING/COOKIES/CONDITIONALS/CUSTOM...` 各写一段；`H1_HD_TRANSFER_ENCODING`
走 `http_req_set_TE`（http.c:2390）；`H1_HD_UPGRADE` 处理 h2c 升级
（调 `Curl_http2_request_upgrade`，http.c:2997 → http2.c:1645）；`H1_HD_CONNECTION`
与 `H1_HD_LAST`（空行 \r\n）收尾。任何一段超长返回 `CURLE_TOO_LARGE` →
"HTTP request too large"（http.c:3200）。

`Curl_req_send`（lib/request.c:380-432）：请求头小且无请求体时直接同步发出；
否则放进 `data->req.sendbuf`（bufq）由 PERFORM 阶段继续冲刷。

### 3.2 Expect: 100-continue 的决策与实现

```c
/* lib/http.c:2459-2466（addexpect 内） */
else if(!data->state.disableexpect && (httpversion == 11)) {
  curl_off_t client_len = Curl_creader_client_length(data);
  if(client_len > EXPECT_100_THRESHOLD || client_len < 0) {
    result = curlx_dyn_addn(r, STRCONST("Expect: 100-continue\r\n"));
```

阈值 `EXPECT_100_THRESHOLD = 1024 * 1024`（lib/http.h:151）：仅 HTTP/1.1 且请求体
超过 1MB（或长度未知）才自动加，用户自定义 Expect 头优先（http.c:2450-2456），
升级 101 场景一律不加（http.c:2444-2446）。

等待机制不再是老版的散落状态位，而是一个**client-reader 插件** `cr_exp100`
（http.c:1483-1601）：

```c
/* lib/http.c:1501-1531（节选）cr_exp100_read */
case EXP100_SENDING_REQUEST:
  if(!Curl_req_sendbuf_empty(data)) { /* 请求没发完，计时器不启动 */ }
  ctx->state = EXP100_AWAITING_CONTINUE;
  Curl_expire_set(data, EXPIRE_100_TIMEOUT,
                  data->set.expect_100_timeout, &ctx->start);
  ...
case EXP100_AWAITING_CONTINUE:
  if(ms < data->set.expect_100_timeout) return CURLE_OK; /* 0 字节，阻塞请求体 */
  http_exp100_continue(data, reader);   /* 超时，放行 */
```

即：请求头发完后 reader 返回 0 字节挡住请求体；收到 1xx（`http_exp100_got100`，
http.c:1602）或超时（默认由 `CURLOPT_EXPECT_100_TIMEOUT_MS` 控制）才放行。
声明了 Expect 的同时由 `http_add_content_hds`（http.c:2545-2547）挂上该 reader。

### 3.3 响应头解析与容错

接收路径：连接层收到字节 → transfer 层回调 `scheme->run->write_resp`（transfer.c:746）
= `Curl_http_write_resp`（http.c:4646）→ 头部阶段交给 `http_parse_headers`
（http.c:4429）逐行切分，再进 `http_rw_hd`（http.c:4237）处理单行。容错点：

- **状态行手写解析**（http.c:4271-4330 区段）：只认 `HTTP/1.0|1.1` 与 `HTTP/2|3`
  前缀；注释直言 *"RFC 9112 requires a single space following the status code,
  but the browsers do not so let's not insist"*（http.c:4295-4297）——对现实世界
  服务器妥协的典型样本。
- **obscure 折叠头（obs-fold）**：`http_parse_headers` 中 `maybe_folded`/
  `unfold_header`（http.c:4434-4444、4520-4540）把以空白开头的续行并进上一条头，
  折叠处多余空白压成单空格（http.c:4455-4468）。
- **HTTP/0.9**：首行不是 `HTTP/` 前缀且连接非复用、且 `accept_09`（http.h:60）
  允许时，整段按 body 直写（http.c:4526-4540、4650-4657）。
- 首行不完整就先存 `data->state.headerb` 攒着（http.c:4480-4490）。
- 完整头写给客户端走 `http_write_header`（http.c:1650-1677，带
  `Curl_bump_headersize` 头部总量上限统计）。
- 空行=头结束：`http_rw_hd` 开头（http.c:4249-4270）拼出最后一条头并调
  `http_on_response`（http.c:4112）做**最终响应裁决**：1xx 走
  `http_on_1xx_response`（http.c:3959，含 101 升级 http.c:3896）；≥200 时判定
  "无 Content-Length、无 chunk、无 close → 靠连接关闭收尾"（http.c:4155-4164）、
  错误码检查、auth 决策、`http_size` 定界（http.c:3809）。版本中途切换大版本
  会被 `http_statusline`（http.c:3718-3744）拒绝。
- 响应头解析的**按首字母分发**：`http_header`（http.c:3666-3700）switch
  `hd[0]` 到 `http_header_a/c/l/p/r/s/t/w`（如 Transfer-Encoding 在
  `http_header_t`，http.c:3598-3625），每个函数只认自己字母开头的头。

### 3.4 chunked 编解码（lib/http_chunks.c，685 行）

同一个状态机 `httpchunk_readwrite`（http_chunks.c:108-370）包成两个方向：

- **响应解码** = client-writer `Curl_httpchunk_unencoder`（http_chunks.c:464，
  `cw_chunked_write` 421-460）。它不是由 http.c 手工挂的，而是 Transfer-Encoding
  头触发 `Curl_build_unencoding_stack`（http.c:3610）→ content_encoding.c:652 把
  "chunked" 与压缩编码统一装进 client-writer 栈，并做 RFC 9112 §6.1 合法性检查：
  chunked 必须是最后一个 transfer coding（content_encoding.c:813-825）、不得重复
  （content_encoding.c:826-834）。
- **请求编码** = client-reader `Curl_httpchunk_encoder`（http_chunks.c:656-667，
  `cr_chunked_read` 612 起，`add_last_chunk` 503 补 `0\r\n\r\n` 尾）。由
  `http_add_content_hds` 在 `upload_chunky` 时经 `Curl_httpchunk_add_reader`
  （http_chunks.c:670）挂载；HTTP/2+ 上会自动取消 chunky（http.c:3100-3104）。
  决策在 `http_req_set_TE`（http.c:2415-2430）：HTTP/1.1 且长度未知才
  `Transfer-Encoding: chunked`。

## 4. HTTP/2 专节（lib/http2.c，2999 行，nghttp2）

### 4.1 过滤器身份与安装

`Curl_cft_nghttp2`（http2.c:2764-2776）名为 "HTTP/2"，flags
`CF_TYPE_MULTIPLEX | CF_TYPE_HTTP`。安装时机两种：ALPN 结果为 h2 时
`Curl_http2_switch_at`（http2.c:2873 → `http2_cfilter_add` 2781 头插）；或 h1 升级
路径在请求头写完后插入并改写 Upgrade 头（http2.c:2825 `http2_cfilter_insert_after`，
由 http.c 的 `H1_HD_UPGRADE` 分支触发）。是否可切换由 `Curl_http2_may_switch`
（http2.c:2838）判断。

### 4.2 流 ↔ transfer 映射

连接级 `struct cf_h2_ctx`（http2.c:117 起）持 nghttp2 session 与 in/out bufq；
每 easy 一个 `struct h2_stream_ctx`（http2.c:123-148）：

```c
/* lib/http2.c:123-133（节选） */
struct h2_stream_ctx {
  struct bufq sendbuf;          /* 该流的请求/待发数据 */
  struct h1_req_parser h1;      /* 把上层写下的 H1 请求再解析回来! */
  struct dynhds resp_trailers;
  int status_code;  uint32_t error;  CURLcode xfer_result;
  int32_t id;  BIT(closed); BIT(reset); BIT(bodystarted); ...
};
```

映射通过 nghttp2 的 `stream_user_data`（`nghttp2_session_set_stream_user_data`，
http2.c:428）把 stream_id ↔ `Curl_easy*` 关联；`H2_STREAM_CTX` 宏（http2.c:257）
从 easy 取流。

### 4.3 发送路径：把 H1 报文再解析成 HEADERS

`cf_h2_send`（http2.c:2197）收到的 buf 是**上层已经写好的 HTTP/1.1 报文**
（请求行+头，甚至体）。首个包走 `h2_submit`（http2.c:2062-2160）：

```c
/* lib/http2.c:2087-2101（节选） */
result = Curl_h1_req_parse_read(&stream->h1, buf, len, NULL, ..., &nwritten);
...
result = Curl_http_req_to_h2(&h2_headers, stream->h1.req, data);  /* http.c:4938 */
...
stream_id = nghttp2_submit_request(ctx->h2, &pri_spec, nva, nheader,
                                   &data_prd, data);              /* 2133 */
```

`Curl_http_req_to_h2`（http.c:4938-4985）把 `struct httpreq` 的 method/scheme/
authority/path 转成 `:method/:scheme/:authority/:path` 伪头，逐条过滤非法头
（`h2_permissible_field`，TE 仅允许 `trailers`，http.c:4972-4977）。后续请求体走
`req_body_read_callback`（nghttp2 data provider）。字节级出口在
`send_callback`（http2.c:605-652）：nghttp2 想发包就写 `cf->next`（下层 TLS/TCP），
阻塞时存 `outbufq` 并返回 `NGHTTP2_ERR_WOULDBLOCK`。

### 4.4 接收路径：nghttp2 回调 → xfer 写出

回调注册集中在 `http2_cfilter_add` 之前的 setup（http2.c:2391-2405）。接收主循环
`h2_progress_ingress` 把底层字节喂 `nghttp2_session_mem_recv`（http2.c:496）：

- `on_frame_recv`（http2.c:1154-1247）：stream 0 处理 SETTINGS（更新
  `max_concurrent_streams` 并 `Curl_multi_connchanged`，1174-1195）、GOAWAY
  （1204-1215）；带 stream_id 的转发给 `on_stream_frame`。
- `on_data_chunk_recv`（http2.c:1262-1296）：按 stream_id 找到 easy，调
  `h2_xfer_write_resp`（http2.c:911-941）→ `Curl_xfer_write_resp`（transfer.c:740）
  → 顶层 H1 语义层的 `write_resp` 写给客户端；随后 `nghttp2_session_consume`
  上报流控窗口，出错即 RST 流（928-934）。写暂停由
  `Curl_xfer_write_is_paused` 感知并置 `stream->write_paused`（935-941）。
- `on_header`（http2.c:1399-1560）：`:status` 被重建成文本行
  `"HTTP/2 <code> \r\n"` 喂给上层（1534-1541），普通头逐条拼成
  `"name: value\r\n"`（1549-1560）——上层 http.c 的响应解析完全复用；
  trailer 存 `stream->resp_trailers`；PUSH_PROMISE 校验 authority 一致性
  （1422-1450）。
- `on_stream_close`（http2.c:1298 起）标记流关闭并唤醒 multi。

`cf_h2_recv`（http2.c:1941-2010）：先从流缓冲取数；不够就 `h2_progress_ingress`
拉新帧再取；取到后 `nghttp2_session_consume` 承认消费；最后总是
`h2_progress_egress` 把积压帧冲出去。连接保活/判活（`http2_connisalive`，
http2.c:529 区段）特判"可读不等于死连接，因为服务器可能发 PING"。

### 4.5 多路复用与连接复用的联合

- `CF_QUERY_MAX_CONCURRENT` 由 SETTINGS 驱动（1174-1180），multi 据此决定
  往这条连接再塞几个 easy。
- 收到 GOAWAY 或流 ID 耗尽时 `nghttp2_session_check_request_allowed` 为 0 →
  `connclose(cf->conn)`（http2.c:516-523），连接池不再复用但存量流继续。
- 每个 easy 独立的 `initial_win_size` 变化会触发 SETTINGS 更新（2122-2130）。

## 5. HTTP/3 专节（lib/vquic/，如实陈述）

- **位置**：`lib/http3.c` 在本 commit 已不存在。H3 直接以**单个 cfilter** 实现：
  ngtcp2 后端 `Curl_cft_http3`（vquic/cf-ngtcp2.c:1091-1105）与 quiche 后端
  （vquic/cf-quiche.c:1626 起），flags 为
  `CF_TYPE_IP_CONNECT | CF_TYPE_SSL | CF_TYPE_MULTIPLEX | CF_TYPE_HTTP`——
  传输、TLS1.3、HTTP/3 三件事一个过滤器全包，因为 QUIC 内嵌 TLS。
  两后端共享逻辑抽在 `cf-ngtcp2-cmn.c`（2098 行）；HTTP/3 代理（MASQUE）在
  `cf-ngtcp2-proxy.c` 与 `cf-capsule.c`（CONNECT-UDP/CONNECT-IP capsule）。
- **入口**：HTTPS 场景下 `Curl_cf_https_setup`（cf-https-connect.c:795-820）装上
  "HTTPS-CONNECT" 赛马过滤器（cf-https-connect.c:725），h3 作为 baller1/baller2
  之一（`cf_hc_baller_assign`，同文件 138-167：`ALPN_h3 → TRNSPRT_QUIC`）与
  TCP+TLS 赛跑，软超时为 happy-eyeballs 的一半、硬超时为全额（240-272）。H3 胜出
  则其子链直接成为连接的过滤器链（`baller_connected`，195-237）。想走 QUIC 的
  代理隧道则由 cf-setup 在隧道之上插 capsule+QUIC（cf-setup.c:236-252）。
- **前提检查**：`Curl_conn_may_http3`（vquic/vquic.c:1194-1220）拒绝 UNIX 套接字、
  非 HTTPS URL、SOCKS 代理。
- **请求/响应**：与 H2 完全同构——`Curl_h1_req_parse_read` +
  `Curl_http_req_to_h2`（vquic/cf-ngtcp2.c:692-704、cf-quiche.c:1014-1026）复用
  同一批 H1↔H2 转换工具；响应经 `Curl_xfer_write_resp_hd/Curl_xfer_write_resp`
  写出（cf-ngtcp2.c:135/155、cf-quiche.c:345/465）。ngtcp2 后端的 H3 回调：
  `cb_h3_recv_data`（cf-ngtcp2.c:209）、`cb_h3_end_headers`（258）、
  `cb_h3_recv_header`（285）；连接状态机 `cf_ngtcp2_connect`（1023）、
  `cf_ngtcp2_send`（796）、`cf_ngtcp2_recv`（490）。quiche 后端
  `cf_quiche_connect`（1382），头部事件逐条回调重建 H1 行。
- **成熟度**：构建依赖 `USE_HTTP3`（ngtcp2+nghttp3 或 quiche），在 curl 官方文档
  中长期标注 **EXPERIMENTAL**（docs/EXPERIMENTAL.md:10 列入实验特性清单）。
  代码本身已深度接入 cfilter/transfer 新架构（与 H2 共用写出路径），但多后端
  并存、代理场景受限（SOCKS 不支持、HTTP 代理需 capsule/专用 h3-proxy 过滤器），
  生产可用性仍弱于 H1/H2。

## 6. 设计动机

- **cfilter 的必然性**：HTTP/2/3 要求"一条连接、多个并发交换"。若协议各自管
  socket，多路复用逻辑必然与代理、TLS、happy-eyeballs 代码纠缠。把"建立传输"
  与"跑协议"切成可组合的过滤器后：H2/H3 是链上带 `CF_TYPE_HTTP` 标志的段，
  连接池用查询（cfilters.c:619-643）读取协议版本；代理是普通过滤器；h1 甚至
  根本不是过滤器——**它是链顶的消费者**，说明分层标准是"是否改变字节流的
  语义封装"，而不是"是不是 HTTP"。
- **H1 报文作为通用交换格式**：上层永远产出 H1 文本报文（`Curl_h1_req_write_head`，
  lib/http1.c:322-345），H2/H3 过滤器把它解析回 `struct httpreq`（http1.c:262-320
  的 `Curl_h1_req_parse_read`）再转伪头（http.c:4938）；响应侧又把伪头重建为 H1
  行（http2.c:1534-1560）。浪费一点解析时间，换来"HTTP 语义层只写一份"——
  三个 HTTP 版本共享同一套认证、cookie、range、重定向逻辑。`struct httpreq`/
  `struct http_resp` 对象（http.c:4700/5007）是这一共享的载体。
- **100-continue 的取舍**：1MB 阈值是小请求延迟与大请求带宽浪费之间的折中
  （http.h:145-151 注释解释了初衷）；等待实现为 reader 插件而不是状态机特例，
  与 rewind/认证重发等机制正交；对 101 升级、HTTP/2 场景主动回避（http.c:2444）。
- **解析容错的现实**：状态行分隔符不严格要求单空格（http.c:4295 注释点名
  "browsers do not"）、支持 obs-fold、容忍 HTTP/0.9、Transfer-Encoding 与
  Content-Length 冲突时按 RFC 偏保守处理（"no chunk, no close, no size → assume
  close"，http.c:4155-4164）——curl 面对的互联网远比 RFC 脏。

## 7. FAQ 素材

1. **HTTP/1.1 状态机在哪个文件？** 不在 http1.c。请求组装在 lib/http.c:3038
   （`Curl_http`），响应解析在 http.c:4429/4237；http1.c 只有 H1 请求行解析/
   写出工具，供代理与 H2/H3 转换复用。
2. **curl 如何决定用 HTTP/1.1 还是 2/3？** HTTPS：ALPN（cf-https-connect.c:385-440
   依 HTTPS-RR/配置选 baller）协商；明文 h2c：`Curl_http2_may_switch`+
   Upgrade 头（http.c:2997、http2.c:1645）；`--http3` 强制 H3（http.c:126-134
   在 setup 时校验可行性）。
3. **一条 H2 连接怎么服务多个 easy？** H2 过滤器 flags 含 `CF_TYPE_MULTIPLEX`，
   stream_user_data 挂 easy（http2.c:428），MAX_CONCURRENT_STREAMS 动态反馈给
   multi（http2.c:1174-1195）。
4. **chunked 响应是谁解的码？** 不是 http.c，而是 client-writer 栈里的
   `Curl_httpchunk_unencoder`（http_chunks.c:464），由 Transfer-Encoding 头触发
   content_encoding.c 装栈（http.c:3610）。
5. **Expect: 100-continue 什么时候发？** 仅 HTTP/1.1 且 body >1MB 或长度未知
   （http.c:2459-2466，阈值 http.h:151）；等待以 cr_exp100 reader 实现
   （http.c:1501），超时放行。
6. **过滤器链什么时候变化？** 连接建立过程中动态插入（cf-setup.c:299-362）；
   ALPN 定 h2 后插入 H2 过滤器（cf-https-connect.c:216-227）；`CF_TYPE_SETUP`
   过滤器连上后可拆（cfilters.h:438）。
7. **H2 下游还有 TLS 缓冲怎么办？** `has_data_pending`（cfilters.h:82）逐层上报，
   `Curl_conn_data_pending`（cfilters.c:645-661）只问第一个已连接层。
8. **H3 为什么不是 http3.c？** 该版本已重构为 vquic/ 下按后端划分的 cfilter；
   ngtcp2 公共逻辑还在 cf-ngtcp2-cmn.c 供直连与代理两个过滤器共用。
9. **请求体从哪来？** client-reader 栈：`set_reader`（http.c:2318）按
   POSTFIELDS/MIME/fread 选 reader，chunked、100-continue、认证回退都是栈上
   插件，长度经 `Curl_creader_total_length` 汇总。
10. **为什么数据写入统一走 `Curl_xfer_write_resp`？** transfer.c:740-766 把
    "协议负责写响应"收敛到一个虚函数位（`scheme->run->write_resp`），H1/H2/H3
    各自实现，写暂停/EOS 语义集中管理。

## 8. 深挖建议

1. **cf_call_data 的嵌套陷阱**（cfilters.h:626-690 + http2.c:117）：沿一个
   "H2 回调里触发底层 send、send 又进 send_callback" 的真实栈，验证
   `CF_DATA_CURRENT` 如何在 easy 间切换（issue #10336）。
2. **HTTPS-CONNECT 赛马的公平性**（cf-https-connect.c:474-578）：软/硬超时、
   HTTPS-RR ALPN 优先级（273-330）、败者子链的销毁路径。
3. **h2c Upgrade 的完整链路**：http.c `H1_HD_UPGRADE` → `Curl_http2_request_upgrade`
   （http2.c:1645）→ 101 → `http_on_101_upgrade`（http.c:3896）→ 过滤器插入时序。
4. **流控背压端到端**：`h2_xfer_write_resp` 暂停（http2.c:911）→
   `adjust_pollset` 撤 POLL_OUT（cfilters.h:69-72）→ WINDOW_UPDATE → 恢复。
5. **响应解码栈顺序**：chunked 与 Content-Encoding 的叠加/校验
   （content_encoding.c:780-860），以及 "chunked 不在最后" 的拒绝路径。

## 9. 写作要点速查表

| 主题 | 位置 |
|---|---|
| cfilter 虚函数表 | lib/cfilters.h:217-232 |
| cfilter 实例（链表） | lib/cfilters.h:235-243 |
| send/recv 签名（含 eos） | lib/cfilters.h:85-96 |
| CF_TYPE_* 能力位 | lib/cfilters.h:208-214 |
| CF_QUERY_* 查询 | lib/cfilters.h:167-183 |
| cf_call_data（easy 嵌套） | lib/cfilters.h:626-690 |
| 链头插/中插 | lib/cfilters.c:303-330 |
| 默认透传 send/recv | lib/cfilters.c:84-102 |
| 沿链查 HTTP 版本 | lib/cfilters.c:619-643 |
| 动态组装/连接步骤 | lib/cf-setup.c:299-362 |
| HTTPS 赛马过滤器 | lib/cf-https-connect.c:725(connect) 474(状态机) 795(setup) |
| TCP/UDP 过滤器 | lib/cf-socket.c:1844 / 2060 |
| TLS 过滤器 | lib/vtls/vtls.c:1311(cft) 1375(create) |
| H1 请求组装入口 | lib/http.c:3038（Curl_http） |
| 请求头逐 ID 写入 | lib/http.c:2883（http_add_hd），枚举 2854 |
| 请求 target | lib/http.c:2117（http_target） |
| Expect 决策 | lib/http.c:2435-2469；阈值 lib/http.h:151 |
| 100-continue reader | lib/http.c:1501（cr_exp100_read），挂载 1575 |
| chunked 请求编码 reader | lib/http_chunks.c:612,670 |
| chunked 响应解码 writer | lib/http_chunks.c:421,464 |
| 响应头切分/折叠 | lib/http.c:4429（http_parse_headers） |
| 单行处理+状态行解析 | lib/http.c:4237（http_rw_hd） |
| 最终响应裁决 | lib/http.c:4112（http_on_response） |
| write_resp 虚函数位 | lib/transfer.c:740-766 |
| H1 报文写出工具 | lib/http1.c:262(解析) 322(写出) |
| H2 过滤器类型/安装 | lib/http2.c:2764 / 2781 / 2873 |
| H2 流对象 | lib/http2.c:123-148 |
| H2 请求转换 | lib/http2.c:2062-2145（h2_submit） |
| H2 关键回调 | lib/http2.c:605(send) 1154(frame) 1262(data) 1399(header) 1298(close) |
| H2 收/发 | lib/http2.c:1941（recv） 2197（send） |
| H1→H2 头转换 | lib/http.c:4938（Curl_http_req_to_h2） |
| H3 ngtcp2 过滤器 | lib/vquic/cf-ngtcp2.c:1023(connect) 490(recv) 796(send) 1091(cft) |
| H3 quiche 过滤器 | lib/vquic/cf-quiche.c:1382(connect) 1626(cft) |
| H3 可行性检查 | lib/vquic/vquic.c:1194（Curl_conn_may_http3） |
| 协议处理器注册 | lib/http.c:5050（Curl_protocol_http），基类 lib/protocol.h:114 |
