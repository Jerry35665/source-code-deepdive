# S 卷 · curl 的 HTTP/2 多路复用实现(nghttp2 集成)

> 源码:curl 仓库 shallow clone,commit `0b04700`(urlapi: run the urlparser perf test faster)。
> 行号以该 commit 的 `lib/http2.c`(2999 行)、`lib/http2.h`(76 行)为准,其余文件同样按此 commit 核对。
> 本卷扩展《curl 深读》卷二的 multi 状态机部分,聚焦:一条 TCP 连接如何承载 N 个 easy handle。

---

## 1. 全景:一条 TCP → 一个 nghttp2 session → N 个 stream → N 个 easy

```text
┌────────────────────────── multi handle ──────────────────────────┐
│  dirty 位图(mid 集合) ◄── 回调里 Curl_multi_mark_dirty(其他 easy)  │
│  max_concurrent_streams(默认 100, CURLMOPT 可调)                 │
└──────┬──────────────────────────────────────────┬────────────────┘
       │ multi_socket(sock 可读)                   │ multi_run_dirty()
       ▼                                          │ 逐个运行 dirty easy
┌─ easy A (mid=17) ─┐                      ┌─ easy B (mid=18) ─────────┐
│ state.url / 请求   │                      │ 自己的响应写入自己的缓冲     │
└──────┬────────────┘                      └──────┬────────────────────┘
       │ streams 哈希: data->mid → h2_stream_ctx    │
       │ nghttp2 stream user_data = Curl_easy*     │
┌──────▼──────────────────────────────────────────▼────────────────────┐
│ cf_h2 连接过滤器(Curl_cft_nghttp2, 标志 CF_TYPE_MULTIPLEX)             │
│  nghttp2_session *h2        ← 整条连接仅 1 个(session = 连接)           │
│  inbufq / outbufq(网络收发 bufq)  streams 哈希  drain_total            │
│  h2_stream_ctx{ id, sendbuf, status_code, closed, write_paused ... }  │
└──────┬────────────────────────────────────────────────────────────────┘
       │ send_callback / recv(Curl_cf_recv_bufq)
┌──────▼─────────┐   HTTP/2 帧: HEADERS/DATA/WINDOW_UPDATE/SETTINGS/
│ 1 条 TCP+TLS   │   GOAWAY/RST_STREAM 都带 stream_id,经 nghttp2 解帧分发
└────────────────┘
```

关键对应关系(全篇最重要的两个"回指"):

- curl 侧:`cf_h2_ctx.streams` 是 `data->mid → h2_stream_ctx` 的哈希,宏 `H2_STREAM_CTX` 完成查找(lib/http2.c:256-258);stream 上下文在首个请求发送时经 `http2_data_setup()` 建立并以 mid 入表(lib/http2.c:361-391,入表在 384)。
- nghttp2 侧:每个 nghttp2 stream 的 user_data 直接存 `struct Curl_easy *`,回调里用 `nghttp2_session_get_stream_user_data(session, stream_id)` 从 stream_id 反查 easy(lib/http2.c:1220、1276、1310)。提交请求时 user_data 就是最后一个参数 `data`(lib/http2.c:2133-2138)。

连接级状态 `struct cf_h2_ctx` 持有 nghttp2 session、收发 bufq、streams 哈希、`max_concurrent_streams`、GOAWAY 标志等(lib/http2.c:90-114);流级状态 `struct h2_stream_ctx` 持有请求 sendbuf、状态码、窗口尺寸、closed/reset 标志等(lib/http2.c:123-148)。**session 是连接的属性,不是 easy 的属性**——这是 h2 与 h1 结构上的根本区别(h1 每条连接同时只服务一个 easy)。

---

## 2. session 回调专节

### 2.1 回调注册与 session 创建

`cf_h2_ctx_open()` 注册全部回调并创建 session(lib/http2.c:2373-2492):注册表在 2391-2406,`nghttp2_session_client_new3()` 在 2409(经 `h2_client_new()`,lib/http2.c:450-471,其中 462 行 `nghttp2_option_set_no_auto_window_update(o, 1)` 关闭 nghttp2 的自动窗口管理,curl 要自己做流控)。随后提交 SETTINGS(2464)并把**连接级**接收窗口一次性扩到 `HTTP2_HUGE_WINDOW_SIZE`(100×10MB=1GB,lib/http2.c:2474-2481,宏定义在 85)。

### 2.2 on_frame_recv(lib/http2.c:1154-1227)

每个完整帧解出后回调。分叉逻辑:

- `stream_id == 0`(连接级帧,1173-1218):
  - SETTINGS(非 ACK):读取对端 `MAX_CONCURRENT_STREAMS` 与 `ENABLE_PUSH` 存入 ctx(1180-1183);值变化则 `Curl_multi_connchanged()` 通知 multi 有新连接资源可抢(1192);并给可能因 64K 初始窗口而 HOLD 的传输解除暂停(1194-1200)。
  - GOAWAY:记 `rcvd_goaway`、`goaway_error`、`remote_max_sid`(1204-1213),同样通知 multi。
- `stream_id != 0`:用 user_data 找到所属 easy(1220),转交 `on_stream_frame()`(lib/http2.c:941-1053):
  - DATA(956):若 body 未开始属协议错误,回 RST(964-971)。
  - HEADERS(973):1xx 不是最终响应,重置 status_code 等下一轮(987-990);最终响应则写结尾空行、置 `resp_hds_complete` 并 mark dirty(992-998)。
  - PUSH_PROMISE(1000):`push_promise()` 克隆父 easy(`h2_duphandle`,700-712)、校验同源(756)、询问应用回调,批准则 `Curl_multi_add_perform()` 直接挂到本连接上跑(848),并把新 stream 的 user_data 指向新 easy(871-873)。
  - RST_STREAM(1016):记 `reset_by_server`、mark dirty。
  - WINDOW_UPDATE(1021-1031):见第 3 节。
  - 帧带 END_STREAM(1037-1051):若上传未完而状态码又是 4xx/1xx,主动 RST 停止上传(1046)。

### 2.3 on_data_chunk_recv(lib/http2.c:1262-1296)

DATA 帧的净荷逐块到达。查 user_data 得到该 stream 的 easy(1276);查不到说明传输已被中止,静默消费掉防止窗口悬挂(1281-1284)。正常路径:`h2_xfer_write_resp()` 把字节写给该 easy 的响应通道(lib/http2.c:911-939;写失败则 RST 该 stream,925),随后 **`nghttp2_session_consume()` 立即向对端报告消费量**(1293)——这是 h2 流控"读多少、报多少"的第一半。注意该回调不直接动 socket,也不唤醒别的 easy;跨 easy 的唤醒由 on_header/on_stream_close 里的 mark dirty 完成。

### 2.4 on_stream_close(lib/http2.c:1298-1353)

stream 关闭(正常 END_STREAM、RST 或 GOAWAY 牵连)。置 `closed`/`error`/`reset`(1333-1336),**mark dirty 该 easy**(1343)让状态机收尾,再清掉 nghttp2 侧 user_data(1346)。真正的错误转换在 `http2_handle_stream_close()`(lib/http2.c:1683-1755):REFUSED_STREAM → 关连接并置 `refused_stream` 触发重试(1692-1697);无 body 需求时容忍尾部错误(1699-1706);其余 reset 报 `CURLE_HTTP2_STREAM`/`CURLE_PARTIAL_FILE`(1710-1711)。easy 退出时 `http2_data_done()` 对未关 stream 补发 RST 并从哈希摘除(lib/http2.c:416-448,补 RST 在 436)。

### 2.5 on_header(lib/http2.c:1399-1575)

`:status` 解析成状态码并伪造 "HTTP/2 200" 风格状态行写回(1509-1546);其余头部统一转成 h1 风格 `name: value\r\n` 再写入上层(1552-1562),这让 curl 的既有头部处理管线零改动复用。若当前回调的 easy 不是"正在跑"的 easy(`CF_DATA_CURRENT(cf) != data`),必须 mark dirty 唤醒那个 easy(1541-1542、1568-1569)——多路复用下"socket 事件由 A 进来、数据却属于 B"是常态。

### 2.6 帧处理速查:六类关键帧的落点

| 帧 | 到达时处理位置 | curl 的反应 |
|---|---|---|
| DATA | on_data_chunk_recv(http2.c:1262) | 写给所属 easy;consume 报消费;未知 stream 静默消费 |
| HEADERS | on_header(http2.c:1399)+ on_stream_frame HEADERS 分支(973) | :status 定状态码;转 h1 风格写回;1xx 等下一轮 |
| SETTINGS | on_frame_recv stream 0 分支(1177-1202) | 抓对端 MAX_CONCURRENT/ENABLE_PUSH;unhold 传输;ACK 由 nghttp2 自动回 |
| WINDOW_UPDATE | on_stream_frame(1021-1031) | resume_data 恢复挂起请求体;或 mark dirty |
| GOAWAY | on_frame_recv stream 0 分支(1204-1213);allowed 检查(511-518) | 记 error/last_stream;mark 连接不可复用;存量 stream 继续 |
| RST_STREAM | on_stream_frame(1016-1020)+ on_invalid_frame_recv(1229-1260) | 记 reset_by_server/error;收尾时转 CURLE_HTTP2_STREAM 等(1683-1755) |

非法帧由 `cf_h2_on_invalid_frame_recv()` 兜底:对所属 stream 回 RST 并记 error,但返回 0 让 nghttp2 自行决定连接级处置(http2.c:1229-1260,注释在 1258)。PING 无专门处理:nghttp2 自动回 ACK,而 curl 主动发 PING 用作 keepalive 探测(`http2_send_ping`,569-589;`cf_h2_keep_alive`,2704-2714)。

---

## 3. 流控专节:WINDOW_UPDATE 的收与发

### 3.1 缓冲尺寸先定基调(lib/http2.c:57-85)

`H2_CHUNK_SIZE` 16K(恰好匹配 DATA 帧)、连接接收窗口 `H2_CONN_WINDOW_SIZE` 10MB(61)、单 stream "in flight" 上限 `H2_STREAM_WINDOW_SIZE_MAX` 10MB(67)、初始窗口 64K(71,可被 nghttp2 的 set_local_window_size 能力动态调)、连接级硬顶 `HTTP2_HUGE_WINDOW_SIZE` 1GB(85)。

### 3.2 接收窗口:为什么必须动态调整

curl 关闭了 nghttp2 自动 WINDOW_UPDATE(462),自己在 **数据真正交给应用层后** 才放行窗口,保证"窗口 ≤ 内存缓冲"而不是"窗口 ≤ 承诺值"。核心是 `cf_h2_update_local_win()`(lib/http2.c:300-346):

```c
dwsize = (stream->write_paused || stream->xfer_result) ?
         0 : cf_h2_get_desired_local_win(cf, data);
if(dwsize != stream->local_window_size) {
  int32_t wsize = nghttp2_session_get_stream_effective_local_window_size(
                    ctx->h2, stream->id);
  if(dwsize > wsize) {                    /* 扩窗:改窗 + 补发增量 */
    rv = nghttp2_session_set_local_window_size(..., stream->id, dwsize);
    rv = nghttp2_submit_window_update(..., stream->id, dwsize - wsize);
  }
  else {                                  /* 缩窗:只改窗,不发负增量 */
    rv = nghttp2_session_set_local_window_size(..., stream->id, dwsize);
  }
```

- 目标窗口 `cf_h2_get_desired_local_win()` 按限速剩余配额取值(lib/http2.c:285-298):`CURLOPT_MAX_RECV_SPEED` 限速时窗口跟着限速走,限速为 0 则窗口收到 0,实现暂停;无限制回到 10MB。
- 触发点三处:响应头写完后(h2_xfer_write_resp_hd,904)、每个 DATA 块写完后(h2_xfer_write_resp,938)、以及上层每取走一次数据(`cf_h2_recv`,1842)。
- 写出侧确认消费:`cf_h2_recv` 把字节交给上层后调 `nghttp2_session_consume(ctx->h2, stream->id, *pnread)`(1983),配合连接级 1GB 大窗口与 per-stream 小窗口,既不饿死连接也不撑爆内存。连接级窗口风暴问题(#10988)由 1GB 硬顶兜底(81-85 的注释)。

### 3.3 发送窗口:被动跟踪 + 唤醒

发送侧窗口由 nghttp2 维护,curl 只做两件事:

- **收到 WINDOW_UPDATE 时**(on_stream_frame,lib/http2.c:1021-1031):若请求体已全部进入 sendbuf 且在等窗口,`nghttp2_session_resume_data()` 恢复该 stream 的挂起读回调(1028);若 transfer 还想写则 mark dirty(1022-1025)。
- **请求体出栈**:`req_body_read_callback()` 从 `stream->sendbuf` 读数据喂给 nghttp2,读完且 `body_eos` 则置 `NGHTTP2_DATA_FLAG_EOF`(1621-1623),无数据可读返回 `NGHTTP2_ERR_DEFERRED` 挂起(1625);`cf_h2_body_send()` 每写入 sendbuf 也调 `nghttp2_session_resume_data()`(2052-2057)。
- 发送窗口数值仅在调试日志里跟踪:`nghttp2_session_get_stream_remote_window_size` / `get_remote_window_size`(2270-2272)。

---

## 4. multi 衔接专节:一个 socket 如何驱动 N 个 transfer

### 4.1 事件入口:socket 事件 → dirty 集合

事件驱动模式下,`multi_socket()` 收到某 socket 的可读/可写事件(lib/multi.c:3241 起),第一步就是把该 socket 上挂的**所有** easy 打上 dirty:`Curl_multi_ev_dirty_xfers(multi, s)`(lib/multi.c:3262;实现在 lib/multi_ev.c:585-600)。随后 `multi_run_dirty()` 逐个运行(lib/multi.c:3194-3232),核心循环:

```c
if(Curl_uint32_bset_first(&multi->dirty, &mid)) {
  do {
    struct Curl_easy *data = Curl_multi_get_easy(multi, mid);
    if(data) {
      if(!Curl_uint32_bset_contains(&multi->process, mid)) {
        Curl_uint32_bset_remove(&multi->dirty, mid);
        continue;
      }
      /* runsingle() clears the dirty mid */
      mresult = multi_runsingle(multi, data, sigpipe_ctx);
      ...
      mresult = Curl_multi_ev_assess_xfer(multi, data);
```

(lib/multi.c:3202-3220,有删节)每个 easy 走一遍 `multi_runsingle` 状态机;超时到期的传输同样经 `multi_mark_expired_as_dirty()` 汇入同一通道(lib/multi.c:3163-3191)。

### 4.2 一个 easy 读 socket,喂饱所有 easy

只有 dirty 集合里第一个跑的 easy 会真正碰 socket:它的 `cf_h2_recv()` 触发 `h2_progress_ingress()`(lib/http2.c:1865-1939),循环 `Curl_cf_recv_bufq` 收进 `inbufq`(1905),再 `nghttp2_session_mem_recv()` 解帧(经 `h2_process_pending_input`,496)。解帧触发的各回调可能把**其他 easy** mark dirty:

- on_header:数据属于别的 easy 时(1541-1542、1568-1569);
- on_stream_close(1343);
- on_stream_frame 的 HEADERS/RST/WINDOW_UPDATE/END_STREAM 分支(998、1019、1024、1050);
- h2_xfer_write_resp 的暂停/恢复切换(928-935)。

这些 easy 下一轮 `multi_run_dirty` 再跑,各自从自己的 stream 缓冲取数据,**不再碰 socket**。此外 multi 在传输收尾检查时发现"pollset 想读但连接里还有未取数据"也会重新标 dirty(lib/multi.c:990-998),兜住 h2 连接缓冲里的"别人的数据"。

### 4.3 pollset:窗口耗尽时该监听什么

`cf_h2_adjust_pollset()`(lib/http2.c:2329-2371)回答"这个 easy 现在该等什么事件":想发送但连接级或 stream 级发送窗口为 0,则改等 POLLIN(等对端 WINDOW_UPDATE,2349-2353);有数据可写或 outbufq 非空则保留 POLLOUT(2354-2356)。这是 h2 特有的"发送阻塞却监听可读"的错位监听,h1 过滤器不需要。

### 4.4 并发上限的协商与查询

- 客户端初始 `multi->max_concurrent_streams = 100`(lib/multi.c:268),`CURLMOPT_MAX_CONCURRENT_STREAMS` 可调(lib/multi.c:3379-3386);本端 SETTINGS 宣告该值(lib/http2.c:219-220)。
- 对端值在 on_frame_recv 的 SETTINGS 分支更新(1180-1181),变化即 `Curl_multi_connchanged()` 让 pending 的传输来抢连接(1192)。
- 复用判定时,multi 侧 `Curl_conn_get_max_concurrent()` 经 `CF_QUERY_MAX_CONCURRENT` 向过滤器要上限(lib/cfilters.c:958-975);cf_h2 的实现:session 已不可再发请求(GOAWAY/流 ID 耗尽)时返回当前已挂载数(等效拒绝),否则返回对端宣告值(lib/http2.c:2725-2738)。

---

## 5. 连接复用判定:与 HTTP/1.1 的差异

h1 的复用前提是"连接空闲"(一条连接同时只能服务一个 transfer);h2 的复用前提是"连接可用且未达并发上限"。curl 在 `url_match_conn()`(lib/url.c:981 起)里的 h2 特有关卡:

- `xfer_may_multiplex()`:HTTP 协议族 + multi 开了多路复用 + 允许 h2/h3,三者齐备才算"可复用型传输"(lib/url.c:530-548);
- `url_match_multiplex_needs()`:连接忙时,若 `conn->bits.multiplex` 未置位直接淘汰;置位了还要求传输本身可复用、且同属一个 multi(lib/url.c:668-683);
- `url_match_multiplex_limits()`:已挂数 ≥ 客户端上限(690-696)或 ≥ 连接宣告上限(697-702)则跳过——**busy 不再是拒绝理由,超限才是**;
- `url_match_http_multiplex()`:候选连接还是 h1 且升级未完成(`!conn->httpversion_seen`)时,要么按 `CURLOPT_PIPEWAIT` 等它升级成 h2,要么放弃(lib/url.c:768-786);
- `url_match_http_version()`:h2 连接只复用给允许 h2 的传输,与 h1/h3 互斥(lib/url.c:788-819)。

`bits.multiplex` 标志由 cf_h2 在首个响应确认 h2 后设置:`CF_CTRL_CONN_INFO_UPDATE` 里置 `httpversion_seen=20` 并 `Curl_conn_set_multiplex()`(lib/http2.c:2664-2668;实现 lib/connect.c:381-389)。也就是说:**"这条连接支持多路复用"是运行时证据,不是先验假设**,与"同 origin 即可复用"的 h1 规则叠加(目的地址/代理/TLS 配置各关仍须通过)。

优先级/依赖树(简):curl 只支持"同依赖根(0)+权重"的最小子集,`h2_pri_spec()` 以 `data->set.weight` 填 `nghttp2_priority_spec_init(pri_spec, 0, weight, FALSE)`(lib/http2.c:1777-1783);用户改权重后由 `h2_progress_egress()` 补发 PRIORITY 帧(1798-1810)。RFC 7540 的完整依赖树在 RFC 9113 中已被废弃,curl 从未实现树形调度。

---

## 6. 设计动机

**为什么用 nghttp2 而非自研**:h2 的难点不在帧编解码,而在 HPACK 动态表、流依赖调度、安全边界(fuzzing 常客)。curl 把帧解析、窗口记账、流状态机整体外包给 nghttp2,自己只保留策略层:"什么时候放窗口"(与限速/暂停联动,nghttp2 的自动窗口做不到,所以 462 行显式关掉)、"stream 归属哪个 easy"、"连接何时可复用"。回调模型(`user_data` 回指 easy)让 nghttp2 的"连接视角"无损映射到 curl 的"transfer 视角"。

**为什么流控要动态调整**:h2 的接收窗口是"愿意缓冲多少"的承诺。固定大窗口会迫使 curl 缓冲 10MB×100 stream(内存爆炸,见 81-85 注释引用的 #10988);固定小窗口则限制单 stream 吞吐。动态方案:连接级 1GB 保证总吞吐,stream 级从 64K 起步、按"应用消费速度 + 限速配额"伸缩(285-298),暂停时收到 0。窗口成为内存与限速的执行机构,而非摆设。

**为什么复用判定要区分"忙"与"超限"**:h1 时代 `CONN_INUSE` 等价于"不可用";h2 下 busy 是常态,唯一的稀缺资源是并发流配额。所以判定被拆成 `multiplex_needs`(能不能复用)与 `multiplex_limits`(还装得下吗)两级,url_match_multiplex_limits 的双上限检查(lib/url.c:685-707)就是配额仲裁。

---

## 7. FAQ 素材

1. **一条 h2 连接上最多挂多少个 easy?** 取客户端上限(multi.c:268 默认 100)与对端 SETTINGS MAX_CONCURRENT_STREAMS 的较小者;查询入口 `CF_QUERY_MAX_CONCURRENT`(http2.c:2725),接收端更新在 on_frame_recv(http2.c:1180)。
2. **nghttp2 的 stream user_data 存的是什么?** 直接是 `struct Curl_easy *`(http2.c:2133-2138 提交时传入),回调里 get_stream_user_data 反查;curl 自身的流上下文另用 mid 哈希管理(http2.c:256-258)。双轨制,互不冗余。
3. **收到 DATA 后窗口什么时候还给服务器?** 两步:回调内 `nghttp2_session_consume` 报连接级消费(http2.c:1293),上层取走数据后 `cf_h2_update_local_win` 调整 stream 窗口并按需 submit_window_update(http2.c:1983 → 300-346)。
4. **为什么 curl 要关掉 nghttp2 的自动 WINDOW_UPDATE?** 自动策略只看 nghttp2 自己的缓冲,curl 需要把窗口与"应用是否取走数据/限速剩余配额/暂停状态"挂钩(http2.c:461-462 注释与实现)。
5. **GOAWAY 之后连接立刻断吗?** 不是。已存在的 stream 继续跑(`remote_max_sid` 之内),只是 `nghttp2_session_check_request_allowed()==0` 时把连接标记 connclose 不再复用(http2.c:511-518);关闭过程还能收尾(shutdown 里 submit_goaway 后继续读写到 done,http2.c:2574-2601)。
6. **RST_STREAM 什么情况下由 curl 主动发?** 至少五处:传输提前 DONE(436)、DATA 先于响应头(965)、写响应失败(925)、非法/拒绝的 PUSH(1004)、END_STREAM 时上传未完且状态码异常(1046)。
7. **REFUSED_STREAM 为什么值得特殊对待?** 它表示服务器没流可分了,换一条连接重试大概率成功,curl 置 `refused_stream` 并返回可重试错误(http2.c:1692-1697)。
8. **HTTP/1.1 Upgrade 升级路径在哪里?** `Curl_http2_request_upgrade` 生成 `Upgrade: h2c` + base64 SETTINGS(http2.c:1645-1681);服务端 101 后 `Curl_http2_upgrade` 建 cf_h2 过滤器、把残留字节塞进 inbufq、stream id 固定为 1(2893-2944,upgrade 分支 2418-2458)。
9. **服务器 PUSH 如何变成一个新 transfer?** `push_promise()` 克隆父 easy → 应用回调裁决 → `Curl_multi_add_perform` 直接在**本连接**上开跑(http2.c:780-893);非同源 PUSH 在 on_header 阶段就 RST(1430-1457)。
10. **h2 的队头阻塞解决了吗?** 传输层解决了(一个 stream 丢包重传不再阻塞其他 stream 的帧交错;多 stream 并发不再像 h1 管道化那样被严格 FIFO);但单条 TCP 上丢包仍阻塞整条连接的所有 stream(传输层队头阻塞,直到 HTTP/3),且应用层若共享 CPU/限速配额仍有排队。h1 管道化的失败根源(响应必须按序返回、慢响应卡死后续)在 h2 由 stream id + 帧交错根治。

---

## 8. 深挖方向

1. **窗口调整算法的临界行为**:`cf_h2_update_local_win` 缩窗只 `set_local_window_size` 不发负 WINDOW_UPDATE(http2.c:332-343),依赖 RFC 9113 的窗口语义(窗口只能显式增大);配合限速暂停(dwsize=0)可观察服务器何时停止发送。
2. **`drain` 机制**:`cf_h2_ctx.drain_total`(http2.c:101)与 stream DRAIN(http2.c:1984-1987)——closed stream 残留数据如何被"排干"而不阻塞其他 stream,`should_close_session`(476-480)以 drain_total==0 为前置条件。
3. **cf-h2-proxy.c 的隧道变体**:经 HTTP/2 代理的 CONNECT 隧道独立实现了一份 nghttp2 集成(lib/cf-h2-proxy.c,1517 行),与主路径的差别(单 stream、无多路复用)是过滤器模型可替换性的好案例。
4. **`CF_DATA_CURRENT` 与 call_data 保存/恢复**:每个过滤器入口 `CF_DATA_SAVE/RESTORE`(如 http2.c:1965、2012)解决"连接级对象被多个 easy 重入"的当前上下文问题,是理解 h2 过滤器线程/重入模型的钥匙。
5. **multi 的 `connchanged` 传播**:SETTINGS 变化 → `Curl_multi_connchanged`(http2.c:1192)→ pending 传输重扫连接池,可对比 `url_match_result` 的 wait_pipe 决策(url.c:1075-1097)看"资源出现"的两种唤醒路径。

---

## 9. 写作要点速查表

| 主题 | 文件:行号 | 一句话 |
|---|---|---|
| 双回指 | lib/http2.c:256-258, 2133-2138 | mid→stream_ctx 哈希 + nghttp2 user_data→easy |
| 过滤器类型 | lib/http2.c:2764-2779 | `Curl_cft_nghttp2`,CF_TYPE_MULTIPLEX |
| session 创建 | lib/http2.c:450-471, 2409 | client_new3;462 关自动窗口 |
| SETTINGS 提交 | lib/http2.c:215-230, 2464 | MAX_CONCURRENT/INITIAL_WIN/ENABLE_PUSH |
| 连接窗口 1GB | lib/http2.c:85, 2474-2481 | HTTP2_HUGE_WINDOW_SIZE 兜底 #10988 |
| on_frame_recv | lib/http2.c:1154-1227 | stream 0 连接级;SETTINGS/GOAWAY 在此 |
| MAX_CONCURRENT 协商 | lib/http2.c:1180-1193 | 对端值变化 → connchanged 唤醒 pending |
| on_data_chunk_recv | lib/http2.c:1262-1296 | 写响应 + consume 报消费 |
| on_stream_close | lib/http2.c:1298-1353 | closed/reset + mark dirty + 清 user_data |
| 动态收窗 | lib/http2.c:285-346 | 限速/暂停决定窗口,set+submit 两段式 |
| WINDOW_UPDATE 到达 | lib/http2.c:1021-1031 | resume_data 恢复挂起的请求体 |
| 发送入口 | lib/http2.c:1577-1626, 2052-2057 | sendbuf→read_callback,DEFERRED/EOF |
| egress 泵 | lib/http2.c:1791-1828 | PRIORITY 补发 + session_send 循环 |
| recv 主路径 | lib/http2.c:1941-2014 | ingress→stream_recv→consume→egress |
| pollset 错位监听 | lib/http2.c:2329-2371 | 窗口 0 时发等收 |
| 并发上限查询 | lib/http2.c:2725-2738; lib/cfilters.c:958-975 | GOAWAY 后返回 attached_xfers |
| multiplex 标志置位 | lib/http2.c:2664-2668; lib/connect.c:381-389 | 首响应后 conn->bits.multiplex=TRUE |
| 复用判定 | lib/url.c:530-548, 668-683, 685-707, 768-786 | busy 不拒绝,超限才拒绝 |
| socket→dirty | lib/multi.c:3241-3262; lib/multi_ev.c:585 | 一个事件唤醒同 socket 全部 easy |
| dirty 运行 | lib/multi.c:3194-3232 | multi_run_dirty 逐个 runsingle |
| 缓冲输入兜底 | lib/multi.c:990-998 | 想读且连接有残留 → 再标 dirty |
| 上限默认/配置 | lib/multi.c:268, 3379-3386 | 默认 100,CURLMOPT 可调 |

(全文约 250 行;行号核对于 curl commit `0b04700`,2026-09)
