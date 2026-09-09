# D 篇 · Upstream 与反向代理子系统

> 仓库:Nginx 1.31.5 主干(commit 231a60ee,2026-09-02)。
> 本文所有结论均标注 `文件:行号`,行号对应该 commit 的源码。核心文件:`src/http/ngx_http_upstream.c`(7352 行)、`ngx_http_upstream.h`、`ngx_http_upstream_round_robin.{c,h}`、`src/http/modules/ngx_http_upstream_{zone,least_conn,ip_hash,hash,keepalive}_module.c`、`src/http/modules/ngx_http_proxy_module.c`、`src/core/ngx_resolver.c`、`src/event/ngx_event_pipe.c`。

---

## ① 全景:upstream 框架在 HTTP 框架中的位置

Nginx 把「反向代理」拆成三层:**内容生成器模块**(proxy/fastcgi/uwsgi/scgi/grpc/memcached)、**upstream 框架**(协议无关的状态机)、**负载均衡器**(可插拔的 peer 选取算法)。内容模块不碰 socket,只通过一组回调把协议编解码"挂"进 upstream 框架。

框架与协议层的契约就是 `ngx_http_upstream_t` 上的函数指针(`ngx_http_upstream.h:342-426`):

```c
struct ngx_http_upstream_s {
    ngx_http_upstream_handler_pt     read_event_handler;   /* 上行读事件分派 */
    ngx_http_upstream_handler_pt     write_event_handler;  /* 上行写事件分派 */
    ngx_peer_connection_t            peer;                 /* LB 选择的远端连接 */
    ngx_event_pipe_t                *pipe;                 /* 缓冲(pipe)模式管道 */
    ...
    ngx_int_t                      (*create_request)(ngx_http_request_t *r);
    ngx_int_t                      (*reinit_request)(ngx_http_request_t *r);
    ngx_int_t                      (*process_header)(ngx_http_request_t *r);
    void                           (*abort_request)(ngx_http_request_t *r);
    void                           (*finalize_request)(ngx_http_request_t *r, ngx_int_t rc);
    ngx_int_t                      (*input_filter)(void *data, ssize_t bytes);
    ...
};
```

`ngx_peer_connection_t.peer` 是框架与 LB 的接口:每个 LB 模块在配置期注册 `init_upstream`(构造 peer 池),每请求经 `init` 初始化请求数据,运行期框架调 `peer.get` 选后端、`peer.free` 归还并反馈成败(`ngx_http_upstream.h:88-98`、`ngx_http_upstream_round_robin.c:51`)。`ngx_http_upstream_module` 本身没有 loc_conf,它只提供 main_conf(所有 `upstream{}` 块的注册表 + 上游响应头 `headers_in` 的哈希表)和一组变量(`$upstream_addr` 等,`ngx_http_upstream.c:412-472`);真正的 per-location 参数(超时、缓冲、限速)住在协议模块自己的 `ngx_http_upstream_conf_t` 里(`ngx_http_upstream.h:165-268`),由 proxy 等模块 merge 后通过 `u->conf` 传给框架(`ngx_http_proxy_module.c:922`)。

**与 HTTP 框架的衔接点**:proxy 模块的 `ngx_http_proxy_handler` 被注册为 location 的 content handler(`ngx_http_proxy_module.c:4111`),它在读完(或决定流式读)客户端请求体后,把 `ngx_http_upstream_init` 挂为 `ngx_http_read_client_request_body` 的 post 回调(`ngx_http_proxy_module.c:970`),此后控制权完全移交 upstream 框架。框架通过改写 `r->read_event_handler / r->write_event_handler` 和 `u->read_event_handler / u->write_event_handler` 四个函数指针实现"状态机换挡",从不阻塞。

可观测性是这套框架的一等公民:每次尝试向 `r->upstream_states` 追加一个 `ngx_http_upstream_state_t`(status、response/connect/header/queue_time、response_length、bytes_received/sent、peer,`ngx_http_upstream.h:63-77`),日志变量 `$upstream_addr` 等把该数组串成逗号列表;多条目之间用 ", " 分隔、用 ", : " 标记"该次尝试连后端都未选中"(变量实现,`upstream.c:5964-5988`)。`$upstream_response_time` 之所以形如 "0.003, 0.012",正是这个数组的逐项投影,也是重试链路排障的第一入口。

---

## ② 一次 proxy_pass 的完整生命周期

### 2.1 状态流转图

```
 proxy_handler (proxy_module.c:876)
   |  创建 u、挂 create_request 等回调 (931-960)
   |  ngx_http_read_client_request_body(→ ngx_http_upstream_init)
   v
 init (upstream.c:543) ── 缓存命中?── 是 → cache_send → 结束 (606-643)
   | 否
   v
 init_request (587)
   |  create_request 编码协议头 (669)
   |  已解析域名? ── 否 → ngx_resolve_start/ngx_resolve_name (800-827)
   v                        | resolver 异步回调 resolve_handler (1236)
   v <──────────────────────┘
 uscf->peer.init(r,us)  ← LB 每请求初始化 (848)
   v
 connect (1570) ── ngx_event_connect_peer (1598)
   |  NGX_BUSY → next(FT_NOLIVE)  NGX_DECLINED → next(FT_ERROR) (1631-1640)
   |  NGX_AGAIN → 等 connect_timeout (1728-1731)   [SSL → ssl_handshake (1749)]
   v
 send_request (2161) ── 发头+体,NGX_AGAIN → 等 send_timeout (2196-2227)
   v
 process_header (2458) ── 循环 recv 直到头解析完 (2529-2605)
   |  status>=400 → test_next(2789)?重试  intercept_errors(2928)?
   |  X-Accel-Redirect → internal_redirect (3091-3151)
   v
 send_response (3275) ── ngx_http_send_header (3284)
   |
   +-- upgrade(101) → upgraded 双向裸管道 (3293-3304, 3618-3894)
   +-- !buffering → non_buffered_* 小缓冲直通 (3334-3393)
   +-- buffering  → 初始化 ngx_event_pipe (3490-3614)
              process_upstream(读后端,4350) ⇄ process_downstream(发客户端,4298)
                        ↓ (EOF/出错/收完)
              process_request (4396) → finalize_request (4770)
```

### 2.2 逐段解读

**(1) 创建与初始化。** `ngx_http_upstream_create` 分配 `ngx_http_upstream_t` 并把 `headers_in.content_length_n/last_modified_time` 置 -1(`ngx_http_upstream.c:509-539`)。proxy_handler 装配回调:`create_request` 负责拼出 `GET / HTTP/1.0\r\nHost: ...` 请求缓冲链;`process_header` 指向 `ngx_http_proxy_process_status_line`,收到 1xx 后会换挡为逐行头处理(`ngx_http_proxy_module.c:931-933, 1882`)。`proxy_buffering off` 且客户端 chunked body 时置 `request_body_no_buffering=1`,让请求体边读边发(`ngx_http_proxy_module.c:962-968`)。

**(1b) 请求的编码:两遍扫描。** `ngx_http_proxy_create_request` 先用脚本引擎逐项累加 `len`(method+URI+各 header),算完后一次 `ngx_palloc` 出缓冲,再跑同一套脚本代码做实际拷贝(`ngx_http_proxy_module.c:1184-1263`)。这是 Nginx 全代码库反复出现的"两遍模式":第一遍求长度、第二遍填充,杜绝 realloc。URI 侧有 `valid_unparsed_uri` 快路径(原样转发未转义 URI)与 `proxy_pass` 带变量时的慢路径(1260-1263);`Host` 头按 `proxy_set_header`/`ctx->vars.host_header` 兜底(1239-1243)。产出的头缓冲链挂在 `u->request_bufs`,请求体缓冲链在 `init_request` 里被拼到其后(`upstream.c:665-667`),最终整体交给 `ngx_output_chain` 顺序写出——这也是"请求体必须先缓冲才能整体重试"的物理基础。

**(2) 域名解析路径。** 若 `proxy_pass http://host:port` 未命中任何 `upstream{}` 块,`u->resolved` 被填充,`init_request` 先在 umcf->upstreams 里按 host+port 查找已定义的 uscf,找不到则走 `ngx_resolve_start/ngx_resolve_name`(upstream.c:750-829);没有配 `resolver` 直接 502(807-813)。回调 `ngx_http_upstream_resolve_handler` 把解析结果交给 `ngx_http_upstream_create_round_robin_peer` 临时构造一个单请求的 peer 池(重量均为 1、max_fails=1、fail_timeout=10,round_robin.c:655-663),再进 connect。

**(3) 连接。** `ngx_http_upstream_connect` 先 push 一条新的 `upstream_state`(每尝试一条,所以 `$upstream_addr` 是逗号列表,1579-1596),然后 `ngx_event_connect_peer(&u->peer)` 非阻塞 connect(1598)。返回 `NGX_BUSY` 意味着 LB 说"所有 peer 都不可用"(no live upstreams),`NGX_DECLINED` 是 connect 立即失败,两者都转入 `ngx_http_upstream_next` 重试(1631-1640)。连接成功后把 `c->read/write->handler` 统一设为 `ngx_http_upstream_handler`,并挂上第一批状态处理函数:`write_event_handler=send_request_handler`,`read_event_handler=process_header`(1650-1654)。

**(4) 事件总入口。** 这是本篇最核心的一个小函数,读/写事件在此分派:

```c
/* ngx_http_upstream.c:1315-1346 */
static void
ngx_http_upstream_handler(ngx_event_t *ev)
{
    ...
    u = r->upstream;
    c = r->connection;

    ngx_http_set_log_request(c->log, r);

    if (ev->delayed && ev->timedout) {
        ev->delayed = 0;
        ev->timedout = 0;
    }

    if (ev->write) {
        u->write_event_handler(r, u);

    } else {
        u->read_event_handler(r, u);
    }

    ngx_http_run_posted_requests(c);
}
```

`ev->delayed && ev->timedout` 的清位是限速定时器到期与真实超时区分的关键(见 §3.4)。所有分派只查 `u->*_event_handler` 当前指向哪个阶段函数——**状态机不是 switch,而是函数指针换挡**。

**(5) 发送请求。** `ngx_http_upstream_send_request` 记录 `connect_time`,经 `ngx_output_chain` 写出 `request_bufs`(头+体)。若 socket 写满(`NGX_AGAIN`)挂 `send_timeout` 定时器并等写事件(2196-2204);写完则删定时器、切 `write_event_handler= dummy_handler`(除非流式 body),并给 `c->read` 挂 `read_timeout`,随即若数据已到就直接进 `process_header`(2231-2275)。流式请求体由 `send_request_body` 的循环在"读客户端 → 写后端"之间往返(`upstream.c:2338-2386`),此时客户端读超时是 `NGX_HTTP_REQUEST_TIME_OUT` 而非重试(`read_request_handler`,2437-2455)。

**(6) 处理响应头。** `process_header` 首次进入时按 `buffer_size` 分配 `u->buffer`(2482-2495),循环 `c->recv` 直到 `u->process_header` 返回非 `NGX_AGAIN`。两个值得注意的失败语义:头超过 buffer_size → `NGX_HTTP_UPSTREAM_INVALID_HEADER` 并触发换节点重试("upstream sent too big header",2584-2591);对端 `n==0` 提前关闭 → "upstream prematurely closed connection" 同样走 next(2547-2555)。头解析成功后记录 `header_time`,状态 ≥400 时先问 `test_next`(是否值得换节点)再问 `intercept_errors`(是否用本机 error_page 接管,2624-2632)。

**(6b) 头部协议:声明式处理表。** 上游每个响应头由静态表 `ngx_http_upstream_headers_in` 驱动(`upstream.c:206-340`):每项含 `process_handler`(入站归一化,如 Content-Length 与 Transfer-Encoding 互斥校验、Cache-Control 解析出 valid_sec)与 `copy_handler`(向 `r->headers_out` 拷贝或改写)。`process_headers` 对所有头先查 `hide_headers_hash` 再查这张表,未注册的头走默认 `copy_header_line`(3153-3196)。Location/Refresh/Set-Cookie 的 copy 是 `rewrite_*` 系列,把 `proxy_redirect/proxy_cookie_domain` 等改写规则通过 `u->rewrite_redirect/rewrite_cookie` 回调反打给协议层(5718-5843)。重复头默认告警并丢弃、Content-Length 与 Transfer-Encoding 同时出现则判 `INVALID_HEADER`(4994-5031)——这些校验同时服务于缓存正确性与请求走私防护。这个主干版本还实现了 RFC 8297 Early Hints:`process_header` 返回 `NGX_HTTP_UPSTREAM_EARLY_HINTS` 时,103 响应的头被透传给客户端后清空重来,累计透传量受 `buffer_size` 限制(2596-2602, 2647-2749)。

**(7) 响应体与多路分离。** `send_response` 先发响应头给客户端,然后按三种模式分岔(`upstream.c:3275-3615`):

- **upgrade(WebSocket 等)**:`u->upgrade` 时切换为 4 个裸管道 handler,`process_upgraded` 用 `u->buffer`(下行)和 `u->from_client`(上行)两块缓冲做双向泵,任何一端 EOF 且数据发尽才整体结束(3618-3894)。
- **非缓冲**:`read_event_handler=process_non_buffered_upstream`、客户端写=process_non_buffered_downstream,`process_non_buffered_request` 用唯一的 `u->buffer` 循环"recv→input_filter→output_filter",`busy_bufs` 未清空前不再读,天然背压(3947-4077);此模式强制 `r->limit_rate=0`(不读后端限速,3354-3355)并建议开 tcp_nodelay。
- **缓冲**:构造 `ngx_event_pipe_t`(详见 §3),handler 换成 `process_upstream`/`process_downstream`(3611-3614)。

**(8) 收尾。** `process_request` 在 `p->upstream_done/upstream_eof/upstream_error` 时收尾:EOF 且 `p->length == -1`(无法预知长度,靠连接关闭界定)视为正常 0;EOF 但 length 已知未收满则记日志 "upstream prematurely closed connection" 并 502(4473-4491)。`finalize_request` 统一回滚:取消解析 ctx、补偿 state 时间、调协议层 `finalize_request`、`peer.free` 归还、关连接、处理临时文件/缓存提交,最后给客户端发 `NGX_HTTP_LAST` 或 `NGX_HTTP_FLUSH`(4770-4941)。

---

## ③ upstream 状态机与缓冲策略

### 3.1 双端缓冲:u->buffer 与 pipe

框架有两种内存缓冲:**头部缓冲 `u->buffer`**(总是分配,`process_header` 用)和 **pipe 的 bufs 池**(`conf->bufs`,默认 `proxy_buffers 8 4k|8k`)。非缓冲模式只复用 `u->buffer`;缓冲模式把 `u->buffer` 中已预读的头后数据作为 `preread_bufs` 交给 event_pipe(3490-3553):

```c
/* ngx_http_upstream.c:3492-3504 */
p->output_filter = ngx_http_upstream_output_filter;
p->output_ctx = r;
p->tag = u->output.tag;
p->bufs = u->conf->bufs;
p->busy_size = u->conf->busy_buffers_size;
p->upstream = u->peer.connection;
p->downstream = c;
...
p->limit_rate = ngx_http_complex_value_size(r, u->conf->limit_rate, 0);
p->start_sec = ngx_time();
p->cacheable = u->cacheable || u->store;
```

`ngx_event_pipe` 的读侧(`ngx_event_pipe_read_upstream`,`ngx_event_pipe.c:104-505`)循环做三件事:取 free buf 或新分配(总量受 `bufs.num` 限制,236-245);**下游就绪则直接短路**(置 `upstream_blocked=1`,先写客户端腾内存,255-271);否则把 `p->in` 链整批 `recv_chain`,内存放不下时写临时文件再腾 buf(273-301)。写侧 `write_to_downstream` 受 `busy_size` 约束:busy 链占用超过 `busy_size`(默认为 bufs 总量的两倍减一页)就停写等客户端消化(`ngx_event_pipe.c:626`)。

### 3.2 临时文件

内存不够且允许落盘时,`ngx_event_pipe_write_chain_to_temp_file` 把未发数据顺序写入 `p->temp_file`。上限是 `max_temp_file_size`(0 表示全落盘);cacheable/store 时 `temp_file->persistent=1`,文件最终被 rename 进 cache/store 路径,否则加 warn 标志,close 时删除,并打那条著名的日志 "an upstream response is buffered to a temporary file"(`upstream.c:3506-3533`)。`cyclic_temp_file` 指令复用固定文件,但必须禁 sendfile,因为 FreeBSD 上 sendfile 与同一文件页的写会互相踩(`upstream.c:3583-3592`)。

落盘决策发生在读循环的 buf 分配处,优先级依次是:有 free buf 就复用;未达 `bufs.num` 就新分配;下游可写就先把内存里的数据冲出去再读;否则(cacheable 或 temp 文件未超上限)才把 `p->in` 写临时文件腾 buf;最后仍不行则 break 停读(`ngx_event_pipe.c:224-311`)。因此 `max_temp_file_size=0` 对非缓存响应是**彻底禁止落盘**(条件 `offset < 0` 恒假,进 else 停读),默认值则高达 1G(proxy_module.c:3817-3825);而 cacheable 响应的临时文件就是缓存文件本体,不受该上限约束。写文件单次批量受 `temp_file_write_size` 控制,写线程化(aio_write)时由 `thread_handler` 投递到线程池(3536-3541)。

### 3.3 影子缓冲:数据从 pipe 到 filter 链的零拷贝

缓冲模式下 proxy 的 `input_filter` 是 `ngx_http_proxy_copy_filter`:它不拷贝数据,而是给原始 buf 制造一个**影子 buf**(shadow):`ngx_memcpy(b, buf, sizeof(ngx_buf_t)); b->shadow = buf; b->last_shadow = 1; buf->shadow = b`(`ngx_http_proxy_module.c:2155-2168`),随后把影子 buf 链入 `p->in` 交给 body filter 链。当 body filter 消费完一个影子 buf,pipe 才把对应的原始 buf 标记为 free 重新进读循环;`busy` 链(客户端没发完的)持续引用 buf,这就是 `busy_size` 背压的计数来源。chunked 响应则换 `ngx_http_proxy_chunked_filter` 在流水线上就地剥壳(`proxy_module.c:2101-2102`),`input_filter_init` 按 RFC 2616 4.4 为 204/304/HEAD 置 `pipe->length=0`、为 chunked 置 5("0" CRLF CRLF)、其余置 Content-Length(`proxy_module.c:2085-2119`)。这套"长度记账"贯穿始终:`u->pipe->length` 是 pipe 读侧的目标字节数,`u->length` 是非缓冲 filter 用的同一数字,两者在 `input_filter_init` 里同时初始化。

### 3.4 限速

响应限速作用于**读后端**这一侧,而不是写客户端:`p->limit_rate` 来自 `proxy_limit_rate` 或后端响应头 `X-Accel-Limit-Rate`(`upstream.c:5355-5390` 解析)。算法是令牌桶式预算:`limit = limit_rate * (now - start_sec + 1) - read_length`,透支则置 `read->delayed` 并挂定时器(`ngx_event_pipe.c:205-222`);读到 n 字节后再补算 `delay = n*1000/limit_rate` 做二次节流(344)。`ngx_http_upstream_handler` 顶部那对 `delayed/timedout` 清位(1333-1336)正是为了防止限速定时器到期被误判为 `read_timeout`。

### 3.5 状态机全景(handler 换挡表)

| 阶段 | u->read_event_handler | u->write_event_handler | r->read / r->write |
|---|---|---|---|
| 连接期 | `process_header` (1654) | `send_request_handler` (1653) | check_broken_connection (661-662) |
| 头已发、体未完 | 同上 | 同上(dummy 当 header_sent,2247-2249) | 同上 |
| 缓冲响应 | `process_upstream` (3611) | — | `process_downstream` (3612) |
| 非缓冲响应 | `process_non_buffered_upstream` (3350) | — | `process_non_buffered_downstream` (3351-3352) |
| upgrade | `upgraded_read_upstream` (3639) | `upgraded_write_upstream` (3640) | `upgraded_read/write_downstream` (3641-3642) |

两个方向的对称性值得注意:`process_downstream` 里客户端写超时标记 `p->downstream_error` 但**不重试**(已开始发响应,重试会重复发送);`process_upstream` 里后端读超时标记 `p->upstream_error`,二者最终都在 `process_request` 汇合判定(4298-4393, 4396-4502)。

---

## ④ 负载均衡框架与共享内存

### 4.1 round-robin 选取算法(代码原文)

默认 LB 是 smooth weighted round-robin,核心在 `ngx_http_upstream_get_peer`(注释略,`ngx_http_upstream_round_robin.c:810-929`,节选):

```c
for (peer = rrp->peers->peer, i = 0; peer; peer = peer->next, i++) {
    n = i / (8 * sizeof(uintptr_t));
    m = (uintptr_t) 1 << i % (8 * sizeof(uintptr_t));

    if (rrp->tried[n] & m) {          /* 本请求已试过的 peer 位图 */
        continue;
    }
    if (peer->down) { continue; }
    if (peer->max_fails
        && peer->fails >= peer->max_fails
        && now - peer->checked <= peer->fail_timeout)
    {                                  /* fail_timeout 窗口内拉黑 */
        continue;
    }
    if (peer->max_conns && peer->conns >= peer->max_conns) {
        continue;
    }

    peer->current_weight += peer->effective_weight;
    total += peer->effective_weight;

    if (peer->effective_weight < peer->weight) {
        peer->effective_weight++;      /* 慢启动/失败恢复 */
    }

    if (best == NULL || peer->current_weight > best->current_weight) {
        best = peer;
        p = i;
    }
}

best->current_weight -= total;         /* 选中者扣减总权重 */
```

算法语义:每轮给所有候选 peer 加 `effective_weight`,选 `current_weight` 最大者,然后该 peer 减去 `total`(所有候选 effective_weight 之和)。效果是权重 5:1:1 的三个后端形成 511511511… 的平滑序列而非 5551 连发。`effective_weight` 是失败惩罚的载体:每次 `NGX_PEER_FAILED` 扣 `weight/max_fails`,下限 0;此后每轮 +1 直到回到 `weight`,即故障恢复的"慢启动"(`round_robin.c:1063-1078`、`884-889`)。`tried` 位图保证同一请求内重试不撞同一个节点;≤64 个 peer 时位图直接内联在 `rrp->data`(round_robin.c:551-562)。主 pool 全挂后进入 `peers->next` 备份池并清零位图重选(772-796)。

### 4.2 其他 LB 的落点

所有方法模块都是"复用 RR 数据结构、只换 get"的装饰器,`least_conn` 甚至直接调 `ngx_http_upstream_init_round_robin` 初始化再覆写 `peer.get`(`ngx_http_upstream_least_conn_module.c:66-96`)。选取规则:比较 `peer->conns * best->weight < best->conns * peer->weight`(交叉乘避免浮点),并列者再套一遍 smooth WRR(181-248)。`ip_hash` 用 `hash = (hash*113 + addr[i]) % 6271` 只对 IPv4 前三字节/IPv6 整地址哈希,按总权重线性落点,重试 20 次失败后降级为普通 RR(`ngx_http_upstream_ip_hash_module.c:197-251`)。`hash $key consistent` 模块兼容 Cache::Memcached 的 `(crc32(key)>>16)&0x7fff`, ketama 一致性哈希时按点数建 160×number 个虚拟节点(源码 216-232 及其后的 ketama 部分)。`least_time`(商业版)则基于 `ngx_http_upstream_response_time_avg` 的 EMA(`round_robin.h:250-253`)。

### 4.3 zone 模块:共享内存与多 worker 一致

`zone` 指令把整个 `ngx_http_upstream_rr_peers_t` 链表深拷贝进 slab 共享内存,此后 `conns/fails/effective_weight/current_weight` 由所有 worker 共享(`ngx_http_upstream_zone_module.c:231-367`)。同步原语是两级锁:peers 级读写锁 + peer 级自旋锁,再辅以 `refs` 引用计数,请求执行中持有的 peer 标记 `zombie`,引用归零才真正 `slab_free`(round_robin.h:154-226)。这意味着 worker 间传递 peer 指针期间节点不会被释放,解决了"一边遍历一边删除"的竞态。

`server ... resolve` 的运行期 DNS 也由 zone 模块实现:每个 worker 的 `init_worker` 为 `peers->resolve` 里的模板 peer 挂定时器(`zone_module.c:651-719`),到期调 resolver,回调里做三向 diff——本轮已不在 DNS 结果中的 peer 摘链释放(866-922),新地址复制为正式 peer 追加(924-1006),容量耗尽只报错不挤占(942-946)。配置版本号 `peers->config` 每次增删都自增,请求持有的旧 `rrp->config` 与之不等时 `get_peer` 直接返回 `NGX_BUSY`(round_robin.c:716-719),宁可让请求失败也不在旧拓扑上重试。

### 4.4 单 peer 快路径与 tries 预算

RR 有一个刻意的特例:`peers->single` 时 `get_peer` 完全跳过权重计算,直接检查 down/max_conns 后返回,free 时也无条件清零 fails(round_robin.c:721-741, 1038-1053)——单节点上游不应因为自己重试失败把自己拉黑(否则会陷入永久不可用)。`tries` 预算在 `init_round_robin_peer` 时按"主池可上线节点数 + 备份池节点数"求和(`ngx_http_upstream_tries` 宏,round_robin.c:14-15, 547),这意味着隐式 upstream(`proxy_pass http://host/` 域名解析出 5 个 A 记录)默认有 5 次重试机会,这是很多运维没有意识到的默认行为,`next_upstream_tries` 正是为收敛它而存在(upstream.c:856-860)。

### 4.5 keepalive:连接缓存而非连接池

`keepalive` 模块也是装饰器:选 peer 时先照常走原 LB(`original_get_peer`,keepalive_module.c:219),再在 LRU 队列里按 sockaddr 匹配空闲连接,命中则 `pc->cached=1` 返回 `NGX_DONE`(229-273);归还时若无失败标记、未超请求数/时间限制且 `u->keepalive`(协议层判定:响应有界且非 `Connection: close`,proxy_module.c:2096 等),则连接挂 `keepalive_close_handler`(MSG_PEEK 探测对端关闭)入缓存(296-379)。`peer.notify` 钩子在响应头到达时通知缓存层计数(195-198)。

---

## ⑤ 失败重试语义(ngx_http_upstream_next)

先厘清三层"失败"的区分:**连接级失败**(connect 返回错误、send/read 中 socket 错误)产生 `FT_ERROR`;**协议级失败**(收到的状态码在 next_upstream 掩码中、响应头非法)在 `process_header`→`test_next` 或 `next` 中以 `FT_HTTP_5xx` 等位进入;**超时失败**由各阶段定时器产生 `FT_TIMEOUT`。三者殊途同归于 `ngx_http_upstream_next`。

`next` 的完整判定(`ngx_http_upstream.c:4598-4755`):

1. **失败记账**:`peer.free(&peer, data, state)`,403/404 传 `NGX_PEER_NEXT`(不算失败,只换节点),其余传 `NGX_PEER_FAILED`(4614-4623)。RR 侧据此执行 §4.1 的 effective_weight 惩罚与 fails++(round_robin.c:1056-1078)。
2. **max_fails/fail_timeout 语义**:`fails >= max_fails` 且 `now - checked <= fail_timeout` 的 peer 在选取时被跳过——即"fail_timeout 窗口内最多容忍 max_fails 次失败,超过后拉黑一个 fail_timeout 周期";窗口过后 selected 时若 `now - checked > fail_timeout` 会刷新 checked 并在成功归还时清零 fails(873-876, 924-926, 1082-1087)。`max_fails=0` 表示关闭探测。
3. **是否还有资格重试**,四个条件任一命中即放弃并按 ft_type 映射最终状态码(4687-4729):

```c
if (u->request_sent
    && (r->method & (NGX_HTTP_POST|NGX_HTTP_LOCK|NGX_HTTP_PATCH)))
{
    ft_type |= NGX_HTTP_UPSTREAM_FT_NON_IDEMPOTENT;
}

if (u->peer.tries == 0
    || ((u->conf->next_upstream & ft_type) != ft_type)
    || (u->request_sent && r->request_body_no_buffering)
    || (timeout && ngx_current_msec - u->peer.start_time >= timeout))
{
    ...  /* cache_use_stale 兜底后 finalize */
}
```

   - **NON_IDEMPOTENT**:`proxy_next_upstream` 默认只含 `error timeout`(proxy_module.c:3846-3850),POST/LOCK/PATCH 已发出请求体时强加上 `FT_NON_IDEMPOTENT` 位,与默认掩码求交必不相等,所以默认**非幂等请求不重试**;显式配置 `non_idempotent` 才放行。
   - **request_body_no_buffering**:流式 body 已部分发给 A 节点,重发到 B 语义不完整,直接放弃(4695)。
   - **next_upstream_timeout**:从 `peer.start_time` 起算的总预算,超时即停,防止"每跳都重试"导致雪崩式拖尾(4696)。
   - **tries 计数**:隐式 upstream 对每个解析出的地址都算一次 try;`next_upstream_tries` 可截断(upstream.c:856-860)。对取自 keepalive 缓存的连接,首个 `FT_ERROR` 会把 tries 加回来,让"缓存连接失效"不消耗重试预算(4636-4639)。
4. **HTTP 状态码触发**:`test_next` 按 `ngx_http_upstream_next_errors` 表(500/502/503/504/403/404/429,upstream.c:475-484)与配置位掩码比对,同样受 NON_IDEMPOTENT/预算约束(2789-2856)。
5. **cache_use_stale 兜底**:放弃重试时,若存在已过期的缓存且错误类型在 `cache_use_stale` 掩码内,退回复用 stale 缓存而不是把错误抛给客户端(4698-4725)。

举一个完整时序帮助建立直觉:上游 A、B(weight 各 1),配置 `proxy_next_upstream error timeout http_502`、默认 POST 不重试。客户端发 GET,请求在 A 上触发 502:`process_header` 发现 status=502,`test_next` 检查 `tries>1 && (next_upstream & FT_HTTP_502)==FT_HTTP_502` 成立 → `next(FT_HTTP_502)` → `peer.free(NGX_PEER_FAILED)` 记账并扣 effective_weight 0.5 → 关闭 A 连接 → 重新 `connect`,RR 这次大概率选 B(其 current_weight 被上一轮抬高)→ B 返回 200,`$upstream_addr` 记为 "A, B",`$upstream_status` 记为 "502, 200"。若改成 POST,第 4 步起 `FT_NON_IDEMPOTENT` 参与掩码判断,默认直接把 502 透传给客户端。

---

## ⑥ 设计动机与取舍

1. **回调换挡替代状态字段**。四个函数指针(`u->read/write_event_handler`、`r->read/write_event_handler`)让每个阶段的退出/重入都自然可恢复,代价是状态分散、调试困难——这也是社区反复出现的"next 重试时 header_sent 后不可能再换节点"类 bug 的温床。`u->header_sent` 之后所有错误路径都只 flush 不再发新头(finalize,4904-4938)。
2. **内存换延迟的分级缓冲**。非缓冲模式延迟最低但后端慢客户端会长时间占住后端连接;缓冲模式用固定 `bufs.num` 个 buf + 临时文件封顶内存,`busy_size` 保证下游有界背压,`upstream_blocked` 短路又让"下游就绪"时不做无谓落盘(ngx_event_pipe.c:255-271)。这是吞吐、内存、尾延迟三点折中,也是 `proxy_buffering` 没有唯一正确答案的原因。
3. **LB 作为可插拔装饰器**。RR 数据结构(`rr_peer/rr_peers`)是公共底盘,least_conn/ip_hash/hash/keepalive 全部只覆写 get/free 甚至复用原实现(least_conn_module.c:89-93;keepalive_module.c:174-186)。好处是 max_fails/慢启动/backup 逻辑全社区共享;代价是 keepalive 之类包装形成三层指针跳转(`original_get_peer`、`original_free_peer`),扩展 LB 必须理解调用顺序。
4. **共享内存 + 引用计数而非消息传递**。多 worker 的 peer 状态用 slab + 两级锁 + refs/zombie 解决,而不是每个 worker 独立统计——`max_fails` 在无 zone 时各 worker 独立(阈值被 worker 数放大),这是文档 FAQ "max_fails 不精确" 的代码根源。
5. **每尝试一条 state**。`$upstream_addr/$upstream_response_time` 逗号列表的设计(upstream.c:1583-1596, 5925-6136)让日志同时记录重试链与各跳耗时,是排障的"黑匣子";代价是 state 与 upstream_states 数组耦合在请求池生命周期上。
6. **resolver 与 upstream 解耦**。resolver 是纯异步状态机(红树缓存 + resend 队列),upstream 只在 resolved 路径和 zone 的 resolve 定时器两处调用它;zone 模块自己实现"DNS 结果 diff 进出 peer 集合",把运行期服务发现做成内存内的最优更新而非整池重建(zone_module.c:864-1006)。
7. **resolver 的缓存内嵌在事件循环里**。它不是每次查询都出网:`ngx_resolve_name_locked` 命中 `rn->valid` 未过期的缓存节点直接同步返回(round_robin 语义下的"即时解析",ngx_resolver.c:638-668);未命中才发 UDP 查询并进 resend 队列,`resend_timeout`(默认 5s)到期由全局唯一的 `resend_handler` 定时器重发,并在多条 DNS 服务器间轮转 `last_connection`(1544-1556);等待者以 `ctx->waiting` 链表挂在节点上,同一域名的并发请求共享一次出网查询(560-575)。请求级超时是另一个独立定时器 `ctx->timeout`(即 `resolver_timeout`,4075-4090),与重发互不干扰——重发直到总超时耗尽才回调失败。
8. **失败的第一反应是"断连"而非"复用"**。`next` 与 `finalize` 对出错连接一律 `ngx_destroy_pool + ngx_close_connection`(4746-4751, 4842-4847),SSL 走 no_wait/no_send shutdown 快速丢弃。只有 keepalive 模块在 free 钩子里显式验伤后才回池——保守的默认值让任何可疑连接都退化为"新建连接",把正确性置于连接复用率之上。

---

## ⑦ FAQ

**Q1:为什么日志里出现 "no live upstreams" 而配置里明明有健康节点?**
`connect` 返回 `NGX_BUSY` 表示 LB 的 get 已经无可选 peer(全部 down/max_fails 拉黑/max_conns 满/主备都耗尽),于是 `next(FT_NOLIVE)`(upstream.c:1631-1635)。`FT_NOLIVE` 不在 `next_upstream` 默认掩码里,直接 502。常见根因:fail_timeout 内连续失败把所有节点拉黑,或 zone 下 config 版本变化触发了 `goto busy`(round_robin.c:716-719, 798-806)。

**Q2:proxy_next_upstream 默认会重试哪些情况?POST 呢?**
默认位掩码是 `error|timeout`(proxy_module.c:3846-3850),即连接失败、send/read 阶段的写错和超时。502/504 等状态码、invalid_header 都要显式加。POST 等非幂等方法在 `request_sent` 时被强加 `FT_NON_IDEMPOTENT`,默认掩码不含它,故不重试(upstream.c:4687-4696);`proxy_next_upstream non_idempotent` 可显式打开。另外流式 body(`request_body_no_buffering`)一旦发送过就永不重试。

**Q3:max_fails=3 fail_timeout=10s 到底怎么计数?**
"10 秒窗口内第 3 次 FAILED 后,该 peer 被跳过 10 秒"。fails 在 free 时累加,`checked/accessed` 记窗口;窗口过后第一次被选中时若 `now - checked > fail_timeout` 则刷新 checked,成功归还时 `accessed < checked` 成立则 fails 清零(round_robin.c:1056-1087, 924-926)。`max_fails=0` 关闭被动探活。注意无 zone 时每个 worker 独立计数,等效阈值约为 3×worker 数。

**Q4:"upstream sent too big header" 后是重试还是 502?**
`process_header` 里 `NGX_AGAIN` 且 buffer 写满时报此错并 `next(FT_INVALID_HEADER)`(upstream.c:2584-2590)。`invalid_header` 不在默认 next_upstream 掩码中,所以通常直接 502,除非显式配置 `proxy_next_upstream invalid_header`;调大 `proxy_buffer_size`/`proxy_buffers` 是治本。

**Q5:proxy_buffering off 时 proxy_limit_rate 还有用吗?**
没用。非缓冲模式下框架强制 `r->limit_rate = 0` 并注释直白(upstream.c:3354-3355),因为数据是"读一点发一点",没有管道可攒;限速预算只实现于 event_pipe 读侧(ngx_event_pipe.c:205-222)。客户端侧限速仍由 core 的 `limit_rate` 控制。

**Q6:X-Accel-Redirect 为什么在发响应头之前就生效?**
`process_headers` 在 `ngx_http_send_header` 之前检查 `headers_in.x_accel_redirect`,命中则 finalize 当前 upstream(传 NGX_DECLINED,保留请求)后 `internal_redirect`/`named_location`,原响应头只拷贝 `redirect` 标记的那几张(upstream.c:3091-3151;headers_in 表 309-316)。`ignore_headers X-Accel-Redirect` 可关闭;`X-Accel-Buffering/Limit-Rate/Expires` 同理是后端控制代理行为的私有协议(5393-5446)。

**Q7:keepalive 模块和 proxy_http_version 有什么关系?**
`u->keepalive` 由协议层判定:响应有 Content-Length/chunked 边界且非 `Connection: close`(proxy_module.c:2096, 2112 等),而上游连接能回池的前提还包括 `proxy_http_version 1.1`(1.0 下 proxy 发的请求即带 Connection: close,后端会关连接)。keepalive 模块归还检查 `!u->keepalive → invalid`(keepalive_module.c:315-317)。

**Q8:为什么响应已经开始后错误不能重试?**
重试意味着丢弃已发给客户端的字节重新发,HTTP 层无法回收。框架在 `header_sent` 后,`next` 的所有路径实际只走 finalize:`process_downstream` 的客户端写超时仅置 `downstream_error`,`process_request` 里非 cacheable/store 才提前 finalize(upstream.c:4320-4346, 4494-4501)。`cache_use_stale` 是唯一例外——用缓存重放替代重试。

**Q9:upstream 解析失败(域名错误)返回什么?**
`proxy_pass http://hostname/...` 且未配 `resolver` → 502 且日志 "no resolver defined to resolve"(upstream.c:807-813);配了但解析超时/失败 → resolver 回调 state 非 0,同样 502(1257-1265)。resolver 的内部重试是 `resend_timeout=5s` 重发查询、`expire=30s` 清缓存、`ctx->timeout`(即 `resolver_timeout`)总超时(ngx_resolver.c:196-198, 4075-4090)。

**Q10:zone 共享内存大小怎么估?**
每 peer 约 `sizeof(rr_peer_t)` + sockaddr + `NGX_SOCKADDR_STRLEN` + server 字符串(+SSL session),启动时从 slab 分配(zone_module.c:370-460);`resolve` 场景下 DNS 结果会动态追加,slab 耗尽只记 "cannot add new server" 不中断服务(942-946)。zone 最小 8 页(zone_module.c:108-112)。

---

## ⑧ 深挖问题

**D1:`NGX_BUSY` 与 config 版本竞争窗口。** zone 下 `get_peer` 若发现 `rrp->config != *peers->config` 直接返回 BUSY(round_robin.c:716-719)。DNS 频繁变化 + 高并发时,是否会出现"所有 worker 恰好持旧版本 → 成片 no live upstreams"?试推导 config 自增与 wlock 释放的内存序保证,评估是否应改为重读 peers 或让 BUSY 走一次 `FT_NOLIVE` 重试。

**D2:smooth WRR 的 O(N) 每次请求成本。** `get_peer` 每次遍历全链表(含 tried/down/max_fails 判断)加 `peer_lock`,zone 模式下这些是跨核原子操作。10k+ 节点(SRWLM 场景)时锁前缀开销占比多大?能否像 hash 模块那样用二分/跳表,或在 worker 内维护影子权重、仅 free 时回写共享内存?

**D3:`p->length == -1` 与 "prematurely closed" 的误判面。** `process_request` 对 EOF 且 length==-1 视为正常结束(upstream.c:4477-4491),而 proxy 的 chunked filter 会在终止块把 length 归 0(proxy_module.c:2101-2102)。若后端在 chunked 中途关连接,`p->length` 仍 >0,应当报 502——验证 chunked_filter 中间断链时 upstream_eof 与 length 的实际组合,确认是否存在把截断响应当完整响应转发的路径。

**D4:限速定时器与 delayed 的竞态。** `handler` 顶部 `delayed&&timedout` 清位(upstream.c:1333-1336)假定限速到期先于 read_timeout 到期;若系统时钟跳变或 epoll 批量唤醒顺序颠倒,limit_rate 的定时器会不会被误当作 read_timeout 触发 `FT_TIMEOUT`?对照 `process_upstream` 的 `rev->delayed` 分支(4374-4384)推演。

**D5:`X-Accel-Redirect` + `proxy_ignore_headers` 与上游连接复用。** XAR 路径直接 `finalize_request(NGX_DECLINED)`(upstream.c:3094),此时响应体未读、连接未 drain,`u->keepalive` 尚未由协议层置位——keepalive 模块的 free 检查 `!u->request_body_sent → invalid`(keepalive_module.c:319-321),连接必然关闭。这是否意味着重内部跳转的服务实际上无法利用 upstream keepalive?可测量 XAR 前后 `upstream_bytes_sent`/连接关闭日志验证。

---

### 附:关键文件与行号速查

| 主题 | 位置 |
|---|---|
| 事件分派 handler | ngx_http_upstream.c:1315-1346 |
| connect / SSL | ngx_http_upstream.c:1570-1743, 1748-2071 |
| send_request / body | ngx_http_upstream.c:2161-2455 |
| process_header / early hints | ngx_http_upstream.c:2458-2786 |
| test_next / intercept_errors | ngx_http_upstream.c:2789-3021 |
| send_response 三分岔 | ngx_http_upstream.c:3275-3615 |
| pipe 模式双端处理 | ngx_http_upstream.c:4298-4502 |
| next / finalize | ngx_http_upstream.c:4598-4755, 4770-4941 |
| RR 选取/记账 | ngx_http_upstream_round_robin.c:810-929, 1022-1100 |
| zone 共享内存 / 运行期解析 | ngx_http_upstream_zone_module.c:133-367, 651-1034 |
| least_conn / ip_hash / hash | modules/ngx_http_upstream_least_conn_module.c:100-315; ip_hash:148-281; hash:168-300 |
| keepalive 装饰器 | modules/ngx_http_upstream_keepalive_module.c:163-384 |
| proxy 回调装配 / 过滤器 | modules/ngx_http_proxy_module.c:875-977, 2066-2180 |
| resolver 重发/超时 | src/core/ngx_resolver.c:196-198, 1446-1563, 4075-4090 |
| event_pipe 限速/落盘 | src/event/ngx_event_pipe.c:205-222, 255-301, 344, 626 |
