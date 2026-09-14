# A - curl 全景与 Easy/Multi 架构

> 调研基线:curl 仓库 commit `0b04700`(2026-09-12,版本号 8.22.1-DEV,见 `include/curl/curlver.h:35`)。
> 本文所有 `文件:行号` 均为该 commit 下 grep/Read 实际核对结果。curl 迭代极快,行号会漂移,但函数名与结构长期稳定。

curl 的招牌是"传输瑞士军刀":单列表可协商出 25 个协议(`lib/version.c:290` 的 `supported_protocols[]`,http/https/ftp/ftps/imaps/mqtt/ws... 按 `CURL_DISABLE_*` 裁剪),TLS 后端可在 OpenSSL/GnuTLS/mbedTLS/wolfSSL/Schannel/rustls 间任选(`lib/vtls/vtls.c:706-725` 的 `available_backends[]`)。但对源码读者来说,它真正的"骨架"只有一条:**一切传输都是 multi 状态机,Easy API 只是糖**。

---

## 1. 全景:一次请求的生命周期

从 `curl_easy_perform()` 到数据抵达写回调,完整链路如下(行号为本次核对值):

```text
 应用                       libcurl 内部                          socket
 ────                       ────────────                          ──────
 curl_easy_init()   ─► Curl_open() 建立 Curl_easy(url.c:448)
                       └ Curl_init_userdefined() 灌默认值(url.c:307)
 curl_easy_setopt() ─► Curl_vsetopt(lib/setopt.c,2955 行的选项管道)
 curl_easy_perform()┐
   (easy.c:847)     │ easy_perform(easy.c:768)
                    │  ├ 复用/创建隐藏 multi:Curl_multi_handle(easy.c:803)
                    │  └ Curl_multi_add_handle(multi.c:462)
                    │       └ MSTATE_INIT
                    │
                    │  ┌──────────── 驱动循环(easy_transfer easy.c:715)────────────┐
                    │  │ curl_multi_poll(1000ms) ─► curl_multi_perform             │
                    │  │      │                        └► multi_runsingle(multi.c:2713)
                    │  │      │                            按 mstate 分发(multi.c:2783 起 switch)
                    │  └────────────────────────────────────────────────────────────┘
                    │                          mstate 流转(见 §3)
                    │   INIT→SETUP→CONNECT→(CONNECTING)→PROTOCONNECT(ING)→DO
                    │        →DOING/DOING_MORE→DID→PERFORMING⇄RATELIMITING→DONE
                    │        →COMPLETED→MSGSENT           (multihandle.h:47-64)
                    │
                    │   数据面:PERFORMING 中 Curl_sendrecv(transfer.c:354)
                    │      └► 写回调 curl_write_callback(curl.h:285,默认 fwrite,url.c:325)
                    ▼
 curl_multi_info_read / msg 队列(handle_completed multi.c:2415)
```

三个关键角色:

- `struct Curl_easy`(`lib/urldata.h`):一个传输的配置+状态,`set.*` 子结构存 287 个 `CURLOPT_*`(宏注册见 `include/curl/curl.h:1132`)。
- `struct Curl_multi`(`lib/multihandle.h:87-201`):驱动核心,持有传输表 `xfers` 与四个工作集 `process/dirty/pending/msgsent`(multihandle.h:102-105)、连接池 `cpool`(multihandle.h:154)、DNS 缓存、超时管理。
- `struct connectdata` + `struct cpool`:连接及其按目的地分桶的池(§4)。

---

## 2. 专节:easy 是 multi 的糖

`lib/easy.c:751-767` 的注释把这层关系写得毫不掩饰(原文即为 "CONCEPT/REALITY" 两段):

```c
/* easy_perform() is the internal interface that performs a blocking
 * transfer as previously setup.
 *
 * CONCEPT: This function creates a multi handle, adds the easy handle to it,
 * runs curl_multi_perform() until the transfer is done, then detaches the
 * easy handle, destroys the multi handle and returns the easy handle's return
 * code.
 *
 * REALITY: it cannot create and destroy the multi handle that easily. It
 * needs to keep it around since if this easy handle is used again by this
 * function, the same multi handle must be reused so that the same pools and
 * caches can be used.                                        (easy.c:752-763)
 */
```

实现要点(easy.c:768-841):

1. **multi 复用**:首次调用 `Curl_multi_handle(16, 1, 3, 7, 3)` 用最小哈希表尺寸建隐藏 multi(easy.c:803);之后同一 easy 句柄再次 perform 时直接取 `data->multi_easy`(easy.c:798-799)——否则连接池、DNS 缓存会随 multi 销毁,连接复用就失效了。这是"easy 句柄复用能提速"的根因。
2. **参数透传**:把 easy 侧的 `maxconnects/quick_exit` 用 `curl_multi_setopt` 抄写给 multi(easy.c:812-813)。
3. **驱动**:一行选引擎 `result = events ? easy_events(multi) : easy_transfer(multi);`(easy.c:831)。
   - `easy_transfer`(easy.c:715-739):`curl_multi_poll(multi, NULL, 0, 1000, NULL)` + `curl_multi_perform` 循环,every 1 秒醒一次兜底,读到 `CURLMsg` 即退出;
   - `easy_events`(easy.c:695-709):走 socket 事件引擎,**仅 DEBUGBUILD 可用**(easy.c:710-713 非 debug 直接 `#define easy_events(x) CURLE_NOT_BUILT_IN`),配合 `curl_easy_perform_ev()`(easy.c:864)用于测试 socket API 路径。
4. **不销毁**:结束后只 `Curl_multi_remove_handle`,multi 留在 easy 句柄上等下次复用(easy.c:835-839)。

**为什么这样设计**:传输逻辑(状态机、重试、复用判定、超时)只有一份,活在 multi 里。Easy API 要 1998 年就定下的阻塞签名,Multi API 要 2001 年后的并发能力——与其维护两份传输代码,不如让 easy 成为 multi 的一个单元素特例。API 兼容性与逻辑单份在此达成交易。代价是:`curl_easy_perform` 内部其实是"伪异步",阻塞与并发永远不可能在同一个 easy 调用里混用。

---

## 3. 专节:mstate 状态机

### 3.1 状态定义

历史文献里的 `CURLM_STATE_*` 在当前代码中已改名 `MSTATE_*`,枚举移入 `lib/multihandle.h:47-65`,共 17 个:

```c
typedef enum {
  MSTATE_INIT,            /* 0 - start in this state */
  MSTATE_PENDING,         /* no connections, waiting for one */
  MSTATE_SETUP,           /* start a new transfer */
  MSTATE_CONNECT,         /* resolve/connect has been sent off */
  MSTATE_CONNECTING,      /* awaiting the TCP connect to finalize */
  MSTATE_PROTOCONNECT,    /* initiate protocol connect procedure */
  MSTATE_PROTOCONNECTING, /* completing the protocol-specific connect phase */
  MSTATE_DO,              /* start send off the request (part 1) */
  MSTATE_DOING,           /* sending off the request (part 1) */
  MSTATE_DOING_MORE,      /* send off the request (part 2) */
  MSTATE_DID,             /* done sending off request */
  MSTATE_PERFORMING,      /* transfer data */
  MSTATE_RATELIMITING,    /* wait because limit-rate exceeded */
  MSTATE_DONE,            /* post data transfer operation */
  MSTATE_COMPLETED,       /* operation complete */
  MSTATE_MSGSENT,         /* the operation complete message is sent */
  MSTATE_LAST
} CURLMstate;                                  /* multihandle.h:47-65 */
```

改状态必须走 `mstate()`(multi.c:152):DEBUG 下打 trace,并按 `state_enter[]` 表(multi.c:159-178)触发进入钩子——如进入 COMPLETED 时补齐进度计时、摘除连接、`Curl_expire_clear_all`(mstate_enter_completed,multi.c:123-149)。

### 3.2 multi_runsingle:按状态分发

`multi_runsingle`(multi.c:2713)是每个传输每次被调度时的入口。新版把它从"千行巨型 switch"重构成**每状态一个 `multistate_*` 函数**,switch 只做分发(multi.c:2783 起);入口处统一处理:multi 已死检查(multi.c:2720)、清 dirty 位(multi.c:2728)、admin 内部句柄走连接关闭队列(multi.c:2731-2740)、超时检查 `multi_handle_timeout`(multi.c:2767 附近)。循环尾部由 `is_finished`(multi.c:2356)兜底收敛到 COMPLETED,再由 `handle_completed`(multi.c:2415)填 `CURLMsg` 并把句柄移入 `msgsent` 集。

| 状态 | 处理函数(行号) | 职责与流转条件 |
|---|---|---|
| INIT | multistate_init multi.c:2463 | `Curl_pretransfer`(transfer.c:440)初始化→SETUP;一次性状态 |
| SETUP | multistate_setup multi.c:2487 | 记 STARTSINGLE、挂总超时/连接超时定时器→CONNECT;**重定向会回到这里** |
| CONNECT | multistate_connect multi.c:2310 | `Curl_connect`(url.c:2436)做"找池内连接或新建";池满则转 PENDING(multi.c:2322-2330),连接已可用则→PROTOCONNECT,异步中→CONNECTING |
| CONNECTING | multistate_connecting multi.c:2504 | 轮询 TCP/过滤器连接完成(`Curl_conn_connect`),完成→PROTOCONNECT,失败→收尾 |
| PROTOCONNECT | multistate_protoconnect multi.c:2538 | **复用连接直接跳 DO**(multi.c:2545-2551,注释点名 FTP 会挂);否则跑协议握手→DO 或 PROTOCONNECTING |
| PROTOCONNECTING | multistate_protoconnecting multi.c:2572 | 等协议层握手(FTP 220、TLS 后的应用层)完成→DO |
| DO | multistate_do multi.c:2149 | 调 prereq 回调(multi.c:2155-2175)、`multi_do`→协议 `do` 动作(发请求第一段);未发完→DOING,`bits.do_more`→DOING_MORE,否则→DID;**复用连接上 SEND_ERROR 会回 CONNECT 重试**(multi.c:2222-2244) |
| DOING | multistate_doing multi.c:2594 | 继续 DO 阶段直到 `dophase_done`→DOING_MORE 或 DID |
| DOING_MORE | multistate_doing_more multi.c:2620 | 第二段发送(FTP 上传为主)→DID |
| DID | multistate_did multi.c:2651 | 多路复用时唤醒 pending(multi.c:2656);无 socket 直接→DONE,否则→PERFORMING(且 HTTP 族多传输时故意不连发,让其他传输有机会上线,multi.c:2667-2672) |
| PERFORMING | multistate_performing multi.c:2010 | `Curl_sendrecv`(transfer.c:354)读写数据;req.done 后按重定向/重试→SETUP 或→DONE(multi.c:2119-2138);错误则 streamclose+multi_done |
| RATELIMITING | multistate_ratelimiting multi.c:2285 | `--limit-rate` 超速即在此等待,速率回落回 PERFORMING |
| DONE | multistate_done multi.c:2684 | `multi_done`(multi.c:680)归置连接(还给池或关闭)→COMPLETED |
| COMPLETED/MSGSENT | — | 结果已入队;MSGSENT 表示应用已通过 `curl_multi_info_read`(multi.c:3089)取走 |

### 3.3 DO/DOING/PERFORMING 的划分依据

这套三段式是按**协议交互阶段**切的,不是按网络事件:

- **DO/DOING/DOING_MORE = "把请求发出去"**:各协议 `scheme->run->do_it` 可能一次做不完(FTP 要 CWD/SIZE/PASV 三轮往返、wildcard 列目录),所以 DO 是入口、DOING 是"未完待续"、DOING_MORE 是 `bits.do_more` 标记的第二段(multi.c:2192-2203, 2620-2648)。
- **DID→PERFORMING = "请求发完,开始收发载荷"**:此处对多路复用有特殊让位逻辑(见 DID 行)。
- **PERFORMING 里混着收尾判断**:重定向(newurl)、重试(retry)、HTTP/2 降级 1.1(multi.c:2047-2070)都在这里裁决,裁决结果决定回 SETUP(重定向)、回 CONNECT(重试)或进 DONE。

PENDING 是独立的"调度态":连接数/并发流受限时传输被移出 process 集合放进 pending 集合(multi.c:2322-2330),由 `multi_schedule_pending`(multi.c:3860 附近,move_pending_to_connect multi.c:3829)在连接状态变化时放行——注意它回到的是 **CONNECT** 而非 INIT,因为 needle 已建好。

---

## 4. 专节:连接缓存 cpool

### 4.1 结构与 key

连接缓存近期完成了一轮更名+重构:旧 `conncache` 现为 `struct cpool`(`lib/conncache.h:49-59`),挂在 multi 上(multihandle.h:154),也可通过 share 共享。组织方式是**两级**:

```c
struct cpool {
  /* the pooled connections, bundled per destination */
  struct Curl_hash dest2bundle;   /* destination 字符串 -> bundle */
  size_t num_conn;
  ...
};
struct cpool_bundle {
  struct Curl_llist conns;        /* 同一目的地的连接链 */
};                                /* conncache.h:49-59, conncache.c:63-65 */
```

- **key = `conn->destination` 字符串**,在连接建立时生成(url.c:1528-1548):`hostname:port`,IPv6 带 scope 时为 `[host%scope]:port`,统一转小写。按目的地哈希分桶,桶内是 llist。
- 近期重构痕迹:RELEASE-NOTES 中的 "conncache: remove bundle dest";bundle 已退化成纯链表容器,连接节点直接内嵌 `cpool_node` 链接节点(conncache.c:150-170 的摘除逻辑)。

### 4.2 查找:先哈希后逐个匹配

`Curl_cpool_find`(conncache.c:701)锁池后用 destination 取 bundle,**优先重试上一次用过的连接**(`data->state.lastconnect_id` 匹配,conncache.c:713-728,注释明说是为了让多请求认证走在同一条连接上),再遍历桶内其余连接调用回调。

真正的匹配链是 url.c 的 `url_match_conn`(url.c:981-1058),由十几个小谓词组成——每个都可独立讲:

1. `url_match_connect_config`(url.c:601):connect_only/close/no_reuse 不可复用,IP 版本、本地绑定端口/设备须一致;
2. `url_match_destination`(url.c:865):`Curl_peer_same_destination` 比 via_peer(connect-to)与 origin;scheme 可不同但须同族且旧连接带 TLS(IMAP→IMAPS 允许);
3. `url_match_fully_connected`(url.c:638):未连完/升级中的连接不挑;
4. `url_match_multiplex_needs`(url.c:668):占用的连接必须支持 multiplex 且当前传输也允许;
5. SSL 配置、代理使用、HTTP 多路复用、auth/NTLM/Negotiate 凭据态(url.c:885-979)逐一比对;
6. `url_match_multiplex_limits`(url.c:685):客户端侧 `MAX_CONCURRENT_STREAMS` 上限;
7. 最后两道生命线:`conn_max_age_ms` 超龄即关(url.c:1035-1043);空闲连接复用前过一次健康检查 `Curl_cpool_conn_seems_healthy`(conncache.c:974-1010)——调协议 `connection_is_dead` 或 `Curl_conn_is_alive`,且"无传输却有输入待读"视为不健康(可能是 TLS close_notify),检查结果 1 秒内缓存(`lastchecked_ms`)。

匹配结果由 `url_match_result`(url.c:1060)收口:命中即在锁内 `Curl_attach_connection`;未见多路复用连接则取消 pipewait;`CURLOPT_PIPEWAIT` 时宁可挂起等待(去等 ALPN 结果揭晓能否复用 HTTP/2,url.c:1075-1079)。

### 4.3 复用为什么是命根

连接的入口在 `Curl_connect`→`url_find_or_create_conn`(url.c:2229):先 `url_create_needle` 造"模板连接",`reuse_fresh`/`connect_only` 不满足才 `url_attach_existing`(url.c:2291-2297)查池。命中即免掉 DNS+TCP+TLS 三轮开销;未命中才把 needle 升级为真连接。归还发生在 `multi_done`(multi.c:680):`multi_conn_should_close`(multi.c:586)决定"回收还是关闭"——`Curl_cpool_conn_now_idle`(conncache.c:139)成功则日志打 "Connection #N left intact"(multi.c:669);池超限由 `Curl_cpool_check_limits`(conncache.c:452)按 `CURLMOPT_MAX_HOST_CONNECTIONS/MAX_TOTAL_CONNECTIONS` 逐出最老空闲连接;死连接清扫 `Curl_cpool_prune_dead`(conncache.c:792)至多每秒一次。支撑这一切的是三十年来每个 CVE、每个代理怪癖的积累——这也是 curl 的护城河:复用判定的**正确性**比状态机本身更难复刻。

---

## 5. 专节:两种驱动 —— multi_perform 与 multi_socket

### 5.1 轮询模型:curl_multi_perform

应用自己写循环:准备好 fd 集(`curl_multi_fdset`,multi.c:1240)或直接用 `curl_multi_wait/poll`(multi.c:1644/1660,内部 `multi_wait` multi.c:1522 统一聚合各传输 pollset + 额外 fd + wakeup socketpair),然后:

- `curl_multi_perform`(multi.c:2967)→内部 `multi_perform`(multi.c:2892):遍历 `process` 集合逐个 `multi_runsingle`,随后清理过期定时器(multi.c:2925 起)、`Curl_update_timer`(multi.c:3566)经 `timer_cb` 向应用报告下次超时(multi.c:3610 调用点)。
- 返回 `CURLM_CALL_MULTI_PERFORM` 表示"立刻再来一遍"(multi_runsingle 的 do-while 尾,multi.c:2878-2888)。

这是"应用级 select 轮询":libcurl 不持有事件循环,任何 socket 就绪都靠应用发现后进来推进。easy API 就是这个模型的自动挡。

### 5.2 事件模型:curl_multi_socket_action

面向想把 libcurl 嵌进自家 epoll/kqueue 事件循环的宿主(nginx 式集成):

1. 注册 `CURLMOPT_SOCKETFUNCTION`(multi.c:3330,存入 `multi->socket_cb`,multihandle.h:118);
2. libcurl 主动**反注册**:socket 的关注事件变化时经 `mev_sh_entry_update`(multi_ev.c:278-341)回调应用,参数为 `CURL_POLL_IN/OUT/REMOVE` 组合——同一 fd 被多个传输共享(多路复用)时合并成单一读写掩码(multi_ev.c:324-325);
3. 应用在自己的事件循环里对就绪 fd 调 `curl_multi_socket_action(s, ev)`(multi.c:3462)→`multi_socket`(multi.c:3236):把该 socket 上的传输标记 dirty(`Curl_multi_ev_dirty_xfers`,multi.c:3262)再 `multi_run_dirty`(multi.c:3194)逐个 runsingle;定时器到点则传 `CURL_SOCKET_TIMEOUT`(multi.c:3275-3283);`curl_multi_socket_all`(multi.c:3475)走 `checkall` 分支直接整体 `multi_perform` + 全量重估(multi.c:3247-3256);
4. fd 与私有数据的映射用 `curl_multi_assign`(multi.c:3818→`Curl_multi_ev_assign` multi_ev.c:574)。

内建簿记在 `lib/multi_ev.c`(651 行):哈希表 `sh_entries` 记录每个 fd 的 readers/writers 计数、announced 状态、user_data;`mev_assess`(multi_ev.c:501)在传输 pollset 变化后统一重算并差量通知应用。脏集合 `multi->dirty`(`uint32_bset`,multihandle.h:103)是事件模型的"待跑队列",`Curl_multi_mark_dirty`(multi.c:4185)遍布各处:重定向、超时到期(multi.c:3186)、pending 放行(multi.c:3841)。

**两种模型的分工**:轮询模型简单、可移植,性能瓶颈在每次全量 fdset 拷贝;事件模型零轮询、千级连接友好,但宿主要实现 socket 回调+定时器+`curl_multi_wakeup`(multi.c:1676,wakeup socketpair 定义在 multihandle.h:165-175)三件套。libcurl 自己的测试套件用 `easy_events`(DEBUGBUILD)验证后者与前者行为一致。

---

## 6. 设计动机

1. **为什么一切皆 multi**:传输是一个跨多次调用的进程间状态(TCP 半连接、TLS 握手中、等待响应),不可能封装进单次函数调用。multi 的状态机把"传输"建模为可被任意事件源推进的对象,easy 只是"事件源=内部循环"的特例(§2)。这个决定让 HTTP/2 多路复用、异步 DNS、Happy Eyeballs、连接池共享全部只需一份逻辑。
2. **连接复用为什么是命根**:curl 的价值=正确+快。快的大头在握手开销,而握手开销只能靠复用摊销;复用的难点恰恰是"何时不该复用"(§4.2 的十几个谓词)。连接池行为错一条就是安全或正确性事故(如凭据态混用、TLS 参数不一致),所以判定代码散落成大量可独立验证的小函数,而不敢写成一个复合 if。
3. **回调模型与 C 语言约束**:libcurl 无闭包,所有异步交互都退化为"函数指针+用户指针"二元组——写回调 `curl_write_callback`(curl.h:285,注册于 `CURLOPT_WRITEFUNCTION`=11,curl.h:1187)、读回调(curl.h:404)、头回调(CURLOPT_HEADERFUNCTION=79,curl.h:1428)、进度回调三世同堂:`curl_progress_callback`(curl.h:240,已弃用)→`curl_xferinfo_callback`(curl.h:249,=219,curl.h:1930)。287 个 CURLOPT 选项(curl.h:1132 起的 `CURLOPT(na,t,nu)` 宏计数)本质上是一个手写的虚表:版本演进不敢改签名,只能加编号——这是 C ABI 冻结下的活化石,也是兼容性的代价。
4. **hyper 后端已退场**:曾作为可选 HTTP 后端于 7.75.0 引入(docs/HISTORY.md:414),8.12.0 移除(docs/DEPRECATE.md:72),如今 `version.c:567` 只剩 `NULL /* Hyper version */` 占位。教训:替换整个协议栈的实现成本高于预期,C ABI 之外的"内部接口"同样难以抽象稳定。

---

## 7. FAQ 素材

1. **curl_easy_perform 和 curl_multi_perform 是两套实现吗?** 不是。easy 内部建隐藏 multi 再跑 `curl_multi_poll`+`curl_multi_perform` 循环(easy.c:768-841, 715-739)。
2. **为什么 easy 句柄复用会更快?** 隐藏 multi 被保留在 `data->multi_easy`(easy.c:798-799),连接池/DNS 缓存跨请求存活。
3. **状态机的状态名 CURLM_STATE 找不到了?** 已改名 `MSTATE_*`,在 lib/multihandle.h:47-65;17 个状态,INIT 和 SETUP 是过渡态,重定向回 SETUP。
4. **DO 和 DOING 区别?** DO 首次调协议 do 动作;一次做不完(FTP 多轮)则停留 DOING;`bits.do_more` 的第二段是 DOING_MORE(multi.c:2192-2203)。
5. **连接怎么判定可复用?** destination(`host:port`)哈希定位 bundle(url.c:1528-1548),再过 url_match_conn 十余项谓词(url.c:981-1058),空闲连接最后还要健康检查(conncache.c:974)。
6. **multi_socket API 的价值?** 让宿主用自有事件循环托管 socket,libcurl 只做状态机推进;socket 关注变化经 CURLMOPT_SOCKETFUNCTION 差量通知(multi_ev.c:278-341)。
7. **CURLM_CALL_MULTI_PERFORM 何时返回?** 状态机还需连续推进(如 INIT→SETUP→CONNECT 链)时;应用须立即重调(multi.c:2878-2888 的 do-while)。
8. **多路复用连接被几个传输共享,socket 回调会不会被打爆?** 不会,per-fd 合并掩码后仅在变化时通知(multi_ev.c:324-331)。
9. **限速是怎么实现的?** 专用状态 RATELIMITING,超速时传输在此停留,`Curl_pgrsCheck` 通过才放行(multi.c:2285-2308)。
10. **hyper 现在还能启用吗?** 不能,8.12.0 已移除(docs/DEPRECATE.md:72)。

## 8. 深挖方向

1. **multi_runsingle 的重构史**:从单函数巨型 switch 到 `multistate_*` 每态一函数(multi.c:2010-2711),对比 8.0 之前的版本可看到"状态即函数"的可测试性演进。
2. **`multi->dead` 熔断**:任一 multi 级回调返回 -1 即置 dead,后续所有传输直接 CURLE_ABORTED_BY_CALLBACK(multi.c:2720-2726)——回调错误传播的设计。
3. **wakeup 机制**:eventfd/socketpair 双通道,`ENABLE_WAKEUP` 供 `curl_multi_wakeup`、`ENABLE_INTERNAL_WAKEUP` 供线程化解析器(multihandle.h:69-76),admin 句柄代持消费(multi.c:2731-2740)。
4. **cshutdn 延迟关闭队列**:连接关闭不阻塞主流程,交给 admin 句柄在 multi->cshutdn 队列里慢慢 shutdown(multi.c:667 与 conncache.c:215-227),这是"优雅关闭"与"不阻塞 perform"的平衡。
5. **`Curl_sendrecv` 数据面**(transfer.c:354):PERFORMING 的真正引擎,xfer 抽象(`Curl_xfer_setup_*`,transfer.c:704-727)如何统一 socket/WS/木马协议的收发。

---

## 9. 写作要点速查表(函数:行号,commit 0b04700)

| 主题 | 函数/定义 | 位置 |
|---|---|---|
| 状态枚举 | `MSTATE_*` 17 态 | lib/multihandle.h:47-65 |
| multi 主体 | `struct Curl_multi`(process/dirty/pending/msgsent) | lib/multihandle.h:87,102-105 |
| 状态迁移 | `mstate()` + state_enter 表 | lib/multi.c:152,159-178 |
| 调度核心 | `multi_runsingle` / switch | lib/multi.c:2713 / 2783 |
| 各态处理 | multistate_do/performing/connect/... | lib/multi.c:2149/2010/2310(其余见 §3.2 表) |
| 收尾 | `is_finished` / `handle_completed` | lib/multi.c:2356 / 2415 |
| 轮询驱动 | `multi_perform` / `curl_multi_perform` | lib/multi.c:2892 / 2967 |
| 事件驱动 | `multi_socket` / `curl_multi_socket_action` | lib/multi.c:3236 / 3462 |
| socket 注册 | CURLMOPT_SOCKETFUNCTION 存 cb | lib/multi.c:3330 |
| 事件簿记 | `mev_assess` / 掩码合并 | lib/multi_ev.c:501 / 324-331 |
| 定时器 | `Curl_update_timer` → timer_cb | lib/multi.c:3566 / 3610 |
| easy 糖 | `easy_perform` / `easy_transfer` / `curl_easy_perform` | lib/easy.c:768 / 715 / 847 |
| 隐藏 multi 复用 | `Curl_multi_handle(16,1,3,7,3)` | lib/easy.c:798-806 |
| 连接池 | `struct cpool`(dest2bundle) | lib/conncache.h:49-59 |
| 池查找 | `Curl_cpool_find`(lastconnect 优先) | lib/conncache.c:701,713-728 |
| 复用判定链 | `url_match_conn` 各谓词 | lib/url.c:981-1058 |
| destination key | `curl_maprintf("%s:%u")` | lib/url.c:1528-1548 |
| 连接入口 | `Curl_connect` / `url_find_or_create_conn` | lib/url.c:2436 / 2229 |
| 默认值管道 | `Curl_init_userdefined` / `Curl_open` | lib/url.c:307 / 448 |
| 选项规模 | 287 个 CURLOPT + 回调 typedef | include/curl/curl.h:1132,285,240,249 |

发布节奏:每 8 周周三一版,10 天冷却 + 3 周特性窗口 + 25 天特性冻结(docs/RELEASE-PROCEDURE.md:64-80)。
