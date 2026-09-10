# C 章 · HTTP 框架与请求生命周期

> 对象:nginx 主干(commit 231a60ee,2026-09-02)。文中所有结论均标注 `文件:行号`,行号以该 commit 为准。

## ① 全景:三层骨架——阶段引擎、过滤器链、变量表

nginx 的 HTTP 框架本质上是把"一次请求的处理过程"拆成三种可被第三方模块插桩的数据结构,全部挂在 `ngx_http_core_main_conf_t`(cmcf)上(`src/http/ngx_http_core_module.h:155-179`):

1. **阶段引擎(phase engine)**。`ngx_http_phases` 枚举定义了 11 个阶段(`ngx_http_core_module.h:110-129`),配置解析完成后被"压平"成一张线性数组 `phase_engine.handlers`,每个元素是 `{checker, handler, next}` 三元组(`ngx_http_core_module.h:136-140`)。请求运行期只做一件事:在这张数组上按 `checker` 的语义来回游走。
2. **过滤器链(filter chain)**。四个全局函数指针 `ngx_http_top_header_filter / top_early_hints_filter / top_body_filter / top_request_body_filter`(`src/http/ngx_http.c:74-77`)构成头/响应体/请求体三条单链,模块在 `postconfiguration` 时用"next = top; top = 我"的方式把自己压栈。
3. **变量表(variables)**。配置期出现的每个 `$var` 先在 `cmcf->variables` 数组里登记拿到**整数下标**,运行期请求结构体里预分配 `r->variables` 数组(`src/http/ngx_http_request.c:633-638`),读变量就是按下标取缓存。

**变量机制展开**(`src/http/ngx_http_variables.c`)。`ngx_http_get_variable_index()` 对每个变量名做一次线性去重查找,首次出现就在 `cmcf->variables` 数组追加一项并把**数组下标**返回给调用方(`ngx_http_variables.c:559-610`)——nginx 配置指令引用 `$var` 时真正持有的是这个下标。运行期取值分三档:先按名字在 `variables_hash` 中查找,命中且带 `NGX_HTTP_VAR_INDEXED` 标志的走 `ngx_http_get_flushed_variable(r, v->index)`,即查缓存数组,`valid` 未过期直接复用(`ngx_http_variables.c:699-703`);非索引变量现场调用 `get_handler` 求值,并用全局 `ngx_http_variable_depth` 计数器防御变量之间的循环引用,归零即报 "cycle while evaluating variable" 返回 NULL(`706-722`);hash 未命中的名字再按**前缀变量**线性匹配(最长的前缀获胜,`732-750`),`http_*`、`arg_*` 这类动态命名变量就是靠这一档实现的。三档的绑定发生在配置收尾:`ngx_http_variables_add_core_vars` 先把核心变量灌进 `variables_keys`(`2747+`),`ngx_http_variables_init_vars` 再把"配置里出现过的下标变量"与"核心/模块注册的变量定义"按名字对接,回填 `get_handler/data/flags` 并打上 `INDEXED` 标记(`2790+`)。最简的取值器是 `ngx_http_variable_request`:`s = (ngx_str_t *)((char *) r + data)` 直接对请求结构体按偏移取字段(`759-778`),一眼可见 nginx "变量即请求字段快照"的取向。

三者的初始化时序集中在 `ngx_http_block()`(`src/http/ngx_http.c:122-341`),顺序非常关键:先创建各模块 main/srv/loc conf 并合并(`189-275`)→ 为每个 server 构建 location 三叉树(`280-291`)→ 初始化阶段数组和 `headers_in` hash(`294-300`)→ 执行所有模块的 `postconfiguration`(模块在这里注册 phase handler 和 filter,`303-315`)→ 变量定版 `ngx_http_variables_init_vars`(`317-319`)→ 最后才把阶段数组压平成 phase engine(`329-331`)。也就是说:**phase handler 的注册发生在压平之前,filter 链的头(如 write filter)在更早的模块序中已就位**。

server/location 的配置树构建里,`ngx_http_init_locations()`(`ngx_http.c:670-831`)把排好序的 location 队列按"静态前缀 / named(@xxx)/ regex / predicate"切分:静态部分进入 `ngx_http_init_static_location_trees()` 构建三叉树(`ngx_http.c:834+`),named 与 regex 分别存入 `cscf->named_locations`(`ngx_http.c:756-777`)与 `clcf->regex_locations`,供 FIND_CONFIG 阶段与 `ngx_http_named_location` 查找。

另外注意 `ngx_http_block` 开头的模块计数:`ngx_http_max_module = ngx_count_modules(...)`(`ngx_http.c:150`),它决定了每个请求携带的 `ctx`/`conf` 指针数组的大小——`main_conf / srv_conf / loc_conf` 都是 `void *` 数组,按模块的 `ctx_index` 定位(`ngx_http.c:155-181`)。http{} 级的三个"空 ctx"(`167-181`)专门用于承接 http{} 直属指令,并与后续 server{} 的同名数组按 `merge_srv_conf / merge_loc_conf` 合并(`251-275`),这是所有 nginx 指令"由内向外的默认值继承"的物理载体。

## ② 一次 GET 请求的完整生命周期

```
[事件] accept → ngx_http_init_connection (request.c:210)
  │  hc->conf_ctx = 该 addr 的 default_server->ctx   (:309)
  │  rev->handler = ngx_http_wait_request_handler    (:329)
  ▼
等待请求行 ──client_header_timeout 超时──► 直接 close_connection (:394-398)
  │ 首字节到达,按 client_header_buffer_size 分配 c->buffer (:408-419)
  ▼
ngx_http_create_request (:539)
  │ 每请求一个 pool;r->header_in = hc->busy 或 c->buffer (:607)
  │ r->main = r; r->count = 1                          (:646-647)
  ▼
ngx_http_process_request_line (:1115) ◄────────────┐
  │ for(;;){ 读满 → 状态机逐字节解析 }              │
  │ 缓冲不够 → ngx_http_alloc_large_header_buffer   │
  │            (:1254-1272,过大→414)                │
  ▼                                                 │
ngx_http_process_request_headers (:1401) ──NGX_AGAIN──┘ (事件挂起等待更多数据)
  │ 每解析出一行:过 headers_in_hash 分发 (1541-1546)
  │ 超过 max_headers → 431 (:1503-1510)
  │ CR LF 空行 → NGX_HTTP_PARSE_HEADER_DONE
  ▼
ngx_http_process_request_header (:2024)
  │ HTTP/1.1 无 Host→400 (:2035);CL+TE 并存→400 (:2068);TE=chunked 标记 (:2077)
  ▼
ngx_http_process_request (:2126)
  │ c->read/write->handler = ngx_http_request_handler (:2209-2210)
  │ 有 client_body_early_read 命中时先读 body (:2213)
  ▼
ngx_http_handler (:848):r->internal ? 从 server_rewrite_index 起跑 (:878)
  │                    : phase_handler = 0            (:874)
  ▼
====== phase engine 线性 pipeline(11 阶段)======
  ▼
content handler 产出 → ngx_http_send_header(core:1918)/output_filter(core:1954)
  → 头/体过滤器链 → write filter 真正写 socket
  ▼
ngx_http_finalize_request (:2743) ── 多出口(见 ④)
  ├─ 未发完: set_write_handler → ngx_http_writer 等可写
  ├─ keepalive: set_keepalive (:3352) ─┐
  │   └─ 已有流水线数据(b->pos<b->last, :3374):新建 r->pipeline=1 的请求
  │       (:3440-3446),rev->handler=process_request_line 后 post 回来 → 回到顶部
  ├─ lingering close: set_lingering_close (:3063-3072)
  └─ close: close_request(:3948,引用计数递减)→ free_request(:3981,
            跑 cleanup 链 + 记访问日志 :4029)→ close_connection
```

逐段补充几个工程细节。**连接建立期**:`ngx_http_init_connection` 只做"按 local addr 选定 address 配置"(`request.c:236-306`)和 handler 挂接——此时请求对象尚不存在,`ngx_http_connection_t *hc` 挂在 `c->data` 上保存 `addr_conf` 与 `conf_ctx`(`232,309`),意味着 **Host 头匹配前的所有配置读取都来自 default_server**。**首缓冲复用**:`wait_request_handler` 里 `c->buffer` 是连接级缓冲(`412-432`),keepalive 复用连接时旧缓冲回收再用;而一旦走过大缓冲,`hc->busy` 链上的缓冲会代替 `c->buffer` 成为 `r->header_in`(`607`)。**每请求内存预算**:`ngx_http_alloc_request` 用 `request_pool_size` 建池(`584`)、按 `variables.nelts` 精确分配变量缓存(`633-638`),使单请求常驻内存可静态估算。

请求行/头解析器是**无回溯的逐字节状态机**,`state` 存放在 `r->state`(`src/http/ngx_http_parse.c:143`),因此可以随时在任意字节间被事件循环打断、续跑——这是 Nginx "读到一半也可以先去处理别的连接"的根基。请求行共 26 个状态(`parse.c:111-139`),如 `sw_start → sw_method → sw_spaces_before_uri → sw_uri → sw_http_HTTP → sw_almost_done`。两个值得细看的状态:

- **`sw_method`(parse.c:163-233)**:遇到空格时,先用 `p - m` 做长度分派,再用 `ngx_str3_cmp/ngx_str4cmp` 这类按 4 字节整型比较的宏识别 GET/POST/HEAD 等常见方法——一次比较 4 字节,避免逐字符 strcmp。
- **`sw_start`/`sw_name`(parse.c:909-971,头解析)**:`static u_char lowcase[256]` 表(`parse.c:889-897`)一表三用——把字符转小写、累进 `header_hash`、同时写入 `r->lowcase_header` 缓存;`_` 开头头名在默认配置下被标记 `invalid_header` 丢弃(`parse.c:933-943`,对应 `underscores_in_headers` 指令)。

头部每解析出一行,框架立刻用 hash 查 `ngx_http_headers_in[]` 注册表(`request.c:1541-1546`),让特殊头(Host、Connection、Content-Length…)在**解析期**就落进 `headers_in` 的专用字段,而不是等下游再线性扫描。`sw_name` 中的 hash 累积与 `lowcase_header` 截断逻辑配合(`parse.c:963-984`),让长头名在解析过程中就完成小写化,头部注册表因此可以直接以 `lowcase_key` 查找。

头解析中途若单行超过缓冲,`process_request_headers` 走 `ngx_http_alloc_large_header_buffer(r, 0)`(`request.c:1437`)换大缓冲;换不动(超过 `large_client_header_buffers` 上限)时按"是否已见到头名"分别报 431(`1444-1470`)。这些都发生在状态机外部,框架层只关心 `NGX_AGAIN`(数据不够)与 `NGX_HTTP_PARSE_INVALID_HEADER`(数据坏)两个出口。

**与 GET 无关但同属生命周期的请求体读取**在本章 ⑦ Q8/Q9 与深挖第 4 条展开,主干只有一句:默认情况下,读完头就把读事件控制权交给 `ngx_http_block_reading`(`request.c:2211`),body 由 content handler 按需发起、`ngx_http_do_read_client_request_body` 的双层 for 循环读满 `rb->rest` 后回调 `post_handler`(`body.c:295-462`)。

## ③ 11 阶段 pipeline 与 checker 的两种遍历方式

11 个枚举值(`ngx_http_core_module.h:110-129`)分两类:**可由模块注册 handler 的公开阶段**(POST_READ、SERVER_REWRITE、REWRITE、PREACCESS、ACCESS、PRECONTENT、CONTENT、LOG)与**框架自用的控制阶段**(FIND_CONFIG、POST_REWRITE、POST_ACCESS)。逐阶段速览:

| 阶段 | checker 类型 | 典型注册者 | 备注 |
|---|---|---|---|
| POST_READ | generic | realip、lua | 读完整头后第一时间可见 |
| SERVER_REWRITE | rewrite | rewrite 模块(server 级) | 记录 server_rewrite_index 作内部跳转入口 |
| FIND_CONFIG | 专属 | 仅 core | location 匹配 + 配置落地 |
| REWRITE | rewrite | rewrite(location 级)、try_files 前置 | 记录 location_rewrite_index |
| POST_REWRITE | 专属 | 仅 core | uri_changed 则回跳 FIND_CONFIG |
| PREACCESS | generic | limit_req/limit_conn | |
| ACCESS | access 专属 | auth_basic、access、auth_request | satisfy all/any 折叠 |
| POST_ACCESS | 专属 | 仅 core | 消费 access_code |
| PRECONTENT | generic | lua、mirror 等 | |
| CONTENT | content 专属 | static、autoindex、proxy、cgi | declined 链式下探 |
| LOG | (独立遍历) | log 模块 | 请求收尾时执行 |


`ngx_http_init_phase_handlers()`(`ngx_http.c:454-560`)在配置期把所有 handler 逆序压入一张数组:

```c
/* ngx_http.c:551-556 —— 同一阶段内,配置里写在后面的先执行 */
for (j = cmcf->phases[i].handlers.nelts - 1; j >= 0; j--) {
    ph->checker = checker;
    ph->handler = h[j];
    ph->next = n;          /* next 指向"本阶段耗尽后"的下一阶段入口 */
    ph++;
}
```

几个关键点:数组总长 `n = 1(find_config) + use_rewrite(post) + use_access(post) + 其余 handler 数`(`ngx_http.c:470-472`)——控制阶段仅在确实有 rewrite/access handler 时才占一个槽位;`server_rewrite_index / location_rewrite_index` 记录了两个跳转入口,供内部跳转复用(`ngx_http.c:464-465,492-513`);POST_REWRITE 的 `ph->next = find_config_index`(`ngx_http.c:517-525`)硬编码了"rewrite 改了 URI 就回 FIND_CONFIG 重新选 location"的环。

每个 handler 都配一个 checker,checker 决定返回值的语义。归纳为三种遍历/放行方式:

- **generic 型**(POST_READ/PREACCESS/PRECONTENT,`core_module.c:916-949`):`NGX_OK` 直跳本阶段终点 `ph->next`(跳过同阶段余下 handler);`NGX_DECLINED` 前进一格;`NGX_AGAIN/NGX_DONE` 挂起返回;其余(错误、HTTP 状态码)直接 `ngx_http_finalize_request`。
- **rewrite 型**(SERVER_REWRITE/REWRITE,`core_module.c:953-976`):语义收窄——`NGX_OK` 不再是"跳过同阶段",而是 **finalize**。因为 rewrite 模块把"改完 URI 后继续"翻译成 `NGX_DECLINED`,把"终止请求"翻译成各种 rc;`NGX_DONE` 保留为"挂起"。
- **find_config / access / content 专属 checker**。FIND_CONFIG(`core_module.c:980-1071`)调用 location 查找、落实 `loc_conf`(`ngx_http_update_location_config`,1010)、顺手拦截 `internal` location 的外部访问(`1000-1003`)与超限 body(`1016-1029`);ACCESS(`1119-1192`)对 subrequest 直接跳过(`1125-1128`),并按 `satisfy all/any` 折叠多个 access 模块的返回码(`1146-1181`);CONTENT(`1301-1351`)先试 `r->content_handler`(`1309`),再沿数组逐个 `NGX_DECLINED` 下探,全 declined 后按 URI 是否以 `/` 结尾给 403 或 404(`1336-1350`)。

运行期驱动者只有 4 行:`ngx_http_core_run_phases` 的 while 循环(`core_module.c:894-912`)——checker 返回 `NGX_OK` 即退出(请求已挂起或已移交),返回 `NGX_AGAIN` 则继续走下一格。

ACCESS checker 还有两处容易被忽略的细节。一是它把失败"记账"而非立即终止:`satisfy any` 模式下某个模块返回 401/403 时,只是把 rc 存进 `r->access_code` 继续走(`core_module.c:1168-1180`),由 POST_ACCESS 统一消费并 finalizer(`1195-1226`);二是 `auth_delay` 指令的实现——`ngx_http_core_auth_delay`(`1229-1271`)在鉴权失败时把写事件挂上 `auth_delay` 定时器并置 `delayed`,让错误响应"恒时"返回以拖慢爆破,期间读事件交给 `ngx_http_test_reading`,定时器到期后由 `ngx_http_core_auth_delay_handler`(`1274-1298`)取出 `access_code` 补做 finalize。

## ④ finalize 的多出口语义

`ngx_http_finalize_request(r, rc)`(`request.c:2743-2928`)是整个框架的"返回值路由器"。一个 handler 返回的 rc 经它分派到完全不同的出口:

```c
/* request.c:2755-2769(节选) */
if (rc == NGX_DONE) {            /* "我不是最终结果":引用计数还原 */
    ngx_http_finalize_connection(r);
    return;
}
if (rc == NGX_DECLINED) {        /* "继续跑 pipeline":重入阶段引擎 */
    r->content_handler = NULL;
    r->write_event_handler = ngx_http_core_run_phases;
    ngx_http_core_run_phases(r);
    return;
}
if (r != r->main && r->post_subrequest) {   /* subrequest 结束回调 */
    rc = r->post_subrequest->handler(r, r->post_subrequest->data, rc);
}
```

完整出口清单(按代码顺序),先用一张路由表总览:

| 传入 rc / 状态 | 出口 | 典型来源 |
|---|---|---|
| NGX_DONE | finalize_connection:只还引用计数,请求继续 | 异步 body 读取 |
| NGX_DECLINED | 重入 phase engine | content handler 交还控制权 |
| NGX_ERROR / 超时 / 断开 | post_action → terminate_request | 网络失败 |
| rc ≥ SPECIAL_RESPONSE 等 | special_response_handler 后递归 finalize | access 拒绝、handler 报错 |
| subrequest 终局 | post_subrequest 回调 → 还 c->data 给 parent → post_request 唤醒 | SSI/auth_request 等 |
| 正常 rc,仍有 buffered | set_write_handler 挂写事件 | 大响应、慢客户端 |
| 正常 rc,数据发完 | finalize_connection → keepalive / lingering / close | 一次成功的 GET |


1. **`NGX_DONE`** → `ngx_http_finalize_connection`(`2999`):只是把主请求引用计数归位,不结束请求——异步读 body(`body.c:2270` 处 `ngx_http_read_early_body` 以 `NGX_DONE` finalize)等场景用。
2. **`NGX_DECLINED`** → 重跑 phase engine(`2764-2769`)。
3. **subrequest 结束**(`2771-2773` → `2815-2887`):先调 `post_subrequest` 回调;若仍有 buffered 数据转 `set_write_handler`;否则标记 `r->done`、`r->main->count--`、把 `c->data` 还给 parent 并 `ngx_http_post_request(pr)` 唤醒父请求(`2853-2876`)。
4. **`NGX_ERROR`/超时/客户端断开**(`2775-2786`)→ 尝试 `post_action`,否则 `ngx_http_terminate_request`(`2932-2983`):立即执行主请求 cleanup 链(`2949-2958`)、置 `terminated` 标志、把 `write_event_handler` 换成 `ngx_http_terminate_handler` 后经 posted request 收尸——**terminate 是"跨过所有中间状态直接拆房",与 finalize 的逐级放行互补**。
5. **`rc >= NGX_HTTP_SPECIAL_RESPONSE`** → 先转投 `ngx_http_special_response_handler` 生成错误页,再**递归 finalize**(`2798-2812`)。
6. **正常完成**(`2889-2927`):若 `r->buffered || c->buffered || r->postponed` 说明还有数据没写完,转 `set_write_handler` 挂到写事件上;否则 `r->done = 1; request_complete = 1`,进 `finalize_connection`(`3019-3074`):`count != 1` 走 close_request 等待;keepalive 允许则 `set_keepalive`;需要" linger 读残包"则 `set_lingering_close`(`3063-3072`);否则 `close_request`。

引用计数贯穿始终:`r->count` 由 create=1(`request.c:647`)、subrequest/读 body 各 +1(`body.c:43`、`core_module.c:2581`)、`close_request` 中 `count--` 且 `count||blocked` 时不拆(`request.c:3962-3966`)。**finalize 与状态机的关系**:checker 用返回值决定"继续走数组/挂起/终局",而 finalize 把 handler 的"终局意图"翻译成对事件驱动状态机的下一组动作(重跑 pipeline、写事件、keepalive 复位、关连接)——两层各管一半,合起来才是"退出"。

"唤醒请求"为什么需要 posted 机制?因为 finalize 常发生在"当前正在处理另一个请求"的调用栈里,直接切换 `c->data` 会破坏上下文。`ngx_http_post_request` 把请求挂到 `main->posted_requests` 链,且对同一请求去重(`request.c:2713-2739`);`ngx_http_run_posted_requests`(`2681-2710`)在最外层事件回调返回前循环执行:只要连接未销毁就弹出队头请求,调用其 `write_event_handler`,直到队列为空。这层"两级调度"(事件 → 当前请求回调 → posted 队列)是理解 subrequest 编排、`ngx_http_terminate_request` 收尸、异步 body 回调共用的一条总线。

keepalive 分支值得单独看 `ngx_http_set_keepalive`(`request.c:3352-3576`):它先检查 `r->header_in` 里是否残留未读字节(`3374`,即 pipeline 的下一个请求),有则现场 `ngx_http_create_request` 并把读事件 handler 恢复成 `ngx_http_process_request_line` 后 post(`3440-3459`);没有则尽量 `ngx_pfree` 掉 `c->buffer` 的物理内存(`3472`)把空闲连接的内存压到最低,最后挂 `keepalive_timeout` 定时器(`3571`)。

## ⑤ filter 链的注册与执行

注册是标准的"头插法压栈",以 gzip 为例:

```c
/* ngx_http_gzip_filter_module.c:1127-1137 */
static ngx_int_t
ngx_http_gzip_filter_init(ngx_conf_t *cf)
{
    ngx_http_next_header_filter = ngx_http_top_header_filter;
    ngx_http_top_header_filter = ngx_http_gzip_header_filter;

    ngx_http_next_body_filter = ngx_http_top_body_filter;
    ngx_http_top_body_filter = ngx_http_gzip_body_filter;
    return NGX_OK;
}
```

调用时机是模块 `postconfiguration`(`ngx_http.c:303-315`)。编译顺序(`auto/modules:173-192`)是 write → header → chunked → v2/v3 → range → gzip → postpone → … → copy → range_body → not_modified,而 `write filter` 和 `header filter` 的 init 只做 `top = 自己`(`ngx_http_write_filter_module.c:365-371`、`ngx_http_header_filter_module.c:737`)。先注册者在链尾,于是默认构建下两条链的执行顺序为:

```
header 链 (ngx_http_send_header → core:1918 调 top_header_filter)
  headers ─► userid ─► gunzip ─► sub ─► … ─► gzip ─► range_header
     ─► chunked(收尾置 TE) ─► ngx_http_header_filter(终点:序列化状态行+头,写 r->out)

body 链 (ngx_http_output_filter → core:1954 调 top_body_filter)
  not_modified?/range_body ─► copy? ─► … ─► postpone(subrequest 编排)
     ─► gzip ─► range_body ─► chunked ─► ngx_http_write_filter(终点:r->out 拼链+限速+写 socket)

请求体链 (top_request_body_filter, ngx_http.c:77)
  … ─► ngx_http_request_body_length_filter / chunked_filter(body.c:991-999 分派)
```

(图中只画主干;具体成员随构建选项增减。)

压栈次序决定了两个后果。其一,**"越靠后编译/注册的模块越靠近内容生产者"**:gzip 在 `auto/modules:179` 注册、not_modified 在 `191`,所以 gzip 看到的是原始 body,而 not_modified 的头判断更靠近生成端;nginx 把"对输出做变换"的模块统一排在 standard handler 之后,正是为了让变换顺序可静态预期。其二,链上任何一环返回 `NGX_ERROR` 都会让 `ngx_http_output_filter` 把 `c->error` 置位(`core_module.c:1966-1969`),后续 write filter 会直接放弃发送——错误传播走的是连接级标志而非返回值逐层翻译。


write filter 是链的**终点而不是普通过滤器**——它把新 chain 拼到 `r->out` 残链上(`ngx_http_write_filter_module.c:134-144`),按 `limit_rate` 计算本窗口可写字节数并可能置延迟定时器(`258-282`),然后一次性交给连接层 `c->send_chain`;没写完就注册 `ngx_http_writer` 等可写事件,因此**每经过一次 body 链,write filter 都可能被反复穿越而数据滞留在 r->out**。content handler 侧的入口很薄:`ngx_http_output_filter`(`core_module.c:1954-1972`)只是调 `top_body_filter` 并在错误时置 `c->error`;subrequest 的输出顺序编排则由 postpone filter 通过 `r->postponed` 链完成。

这套设计的收益与代价同样明显:头/体一旦进入过滤器链,就**不再回头**——gzip 只能压缩"从它面前流过"的数据,无法改变已由更上游发出的字节;`last_buf` 标志是链上唯一的"终点信号",各 filter 都要正确转发它,这也是写 nginx 输出 filter 模块时最常见的出错点。理解了这一点,`filter_finalize`(`request.c:2760-2762`)、SSL 连接上的 `main_filter_need_in_memory = 1`(`request.c:640-643`,TLS 不能 sendfile,故强制数据进内存)等看似零散的标志,都是围绕"单向流"打补丁的产物;subrequest in memory 则由 `sr->filter_need_in_memory` 单独承担(`core_module.c:2541-2543`)。

## ⑥ 设计动机与取舍

phase engine 用"配置期压平的扁平数组 + 游标"换来运行期**零虚函数、零遍历分配**的确定性流水线;filter 链用全局函数指针的静态插桩换来**与模块列表同序、可在启动期裁剪**的输出管线;二者都刻意避开运行期动态注册,以牺牲"运行时可插拔"为代价换取每请求开销的可预测。一句话对比:**Apache 2.x 的 hook 模型是运行期在请求对象上遍历注册好的钩子数组、按返回值(OK/DECLINED)决定是否继续,与 nginx 的 checker 数组同构,但 nginx 把"选择 location 并重置配置上下文"这类昂贵动作做成了数组里的一个显式环节,并把所有阶段入口提前拼好,使热路径上没有任何查找与分支表遍历**。

## ⑦ FAQ

**Q1:rewrite 阶段 `last` 和 `break` 的区别在源码里是什么?**
`last` 触发 `uri_changed`,被 POST_REWRITE 发现后 `r->phase_handler = ph->next` 跳回 FIND_CONFIG(`core_module.c:1109`,`next` 即 find_config 索引,`ngx_http.c:520`);`break` 不改 URI,直接让 rewrite 返回 `NGX_DECLINED` 前进,后续 access/content 在当前 location 继续。

**Q2:内部重定向为什么不会死循环?**
每个请求携带 4 位计数 `uri_changes`,初值 `NGX_HTTP_MAX_URI_CHANGES + 1 = 11`(`request.h:12`、`request.c:661`);`ngx_http_internal_redirect` 每次 `uri_changes--`(`core_module.c:2616`),归零即 500(`2618-2625`)。subrequest 另有独立上限 `NGX_HTTP_MAX_SUBREQUESTS = 50`(`request.h:13`)。

**Q3:内部跳转后模块上下文为什么是"干净"的?**
`internal_redirect` 显式 `ngx_memzero(r->ctx, ...)` 并把 `r->loc_conf` 重置为 server 级(`core_module.c:2643-2646`),`r->internal = 1` 使 `ngx_http_handler` 从 `server_rewrite_index` 而非 0 起跑(`core_module.c:876-878`)——这就是"内部请求跳过 POST_READ/SERVER_REWRITE"的由来。

**Q4:`@named` location 的跳转与 URI 跳转有何不同?**
`ngx_http_named_location`(`core_module.c:2666-2738`)不参与 URI 匹配,直接命中 `cscf->named_locations` 数组(`ngx_http.c:756-777` 构建),并把游标直接拨到 `location_rewrite_index`(`core_module.c:2723`),即跳过 FIND_CONFIG。

**Q5:为什么 subrequest 的 access 阶段会被跳过?**
`ngx_http_core_access_phase` 开头 `if (r != r->main)` 直接 `phase_handler = ph->next`(`core_module.c:1125-1128`);subrequest 的鉴权被认为继承自父请求的配置上下文。

**Q6:subrequest 是"递归"吗?**
不是。`ngx_http_subrequest`(`core_module.c:2419-2607`)只是分配一个 `sr`,复用父请求的 pool 与 `r->variables`(`2537`),method 固定 GET(`2505`),挂进 `c->data`/`r->postponed` 编排链,再 `post_request` 排队;主请求计数上限 65535-1000(`2439`)防止失控。子请求的调度依赖 `ngx_http_run_posted_requests`(`request.c:2681-2710`):事件回调的**尾部**循环弹出 `main->posted_requests` 链并逐个执行 `r->write_event_handler(r)`,保证"请求切换"只发生在事件处理边界之外,避免深层递归——subrequest 自身的 `write_event_handler` 就是 `ngx_http_handler`(`core_module.c:2535`),被弹出时直接从阶段引擎开始跑。

**Q7:keepalive 与 pipeline 如何区分?**
`set_keepalive` 中 `b->pos < b->last` 即 header 缓冲里有流水线残留数据(`request.c:3374`)时立刻起新请求(`r->pipeline = 1`,`3446`);否则释放缓冲、进入 `keepalive_handler` 等下一个请求。`c->pipeline` 还会参与 lingering close 判断(`request.c:3063-3068`)。

**Q8:请求体一定先读完才处理吗?**
默认"读 body"是由 content handler 按需发起的:`ngx_http_read_client_request_body`(`body.c:32-228`)先尝试利用 header 缓冲里预读的部分(`102-147`),按 `client_body_buffer_size` 分配(读满为止,`173-195`),放不下才落到 `temp_file`;`client_body_early_read` 命中时 `ngx_http_process_request` 会把"读 body + 继续跑 pipeline"提前到阶段引擎之前(`request.c:2213,2222-2273`)。

**Q9:chunked 请求体和 content-length 共用一套读取循环吗?**
是。读取循环 `ngx_http_do_read_client_request_body`(`body.c:295-462`)不感知编码格式,长度判定下放给请求体过滤器 `ngx_http_request_body_filter` 按 `r->headers_in.chunked` 分派到 length/chunked 两个 filter(`body.c:991-999`);length filter 首次调用时把 `rb->rest` 设为 CL 并在收齐时打 `last_buf`(`body.c:1016-1073`)。

**Q10:访问日志在哪个出口打的?**
唯一入口在 `ngx_http_free_request`:`if (!r->logged) ngx_http_log_request(r)`(`request.c:4026-4030`);subrequest 只有配置了 `log_subrequest` 才在 finalize 早期补打(`request.c:2830-2838`)。LOG 阶段的 handler 则是在 pipeline 里跑(`ngx_http.c:402-407` 初始化),与前者不同层。

## ⑧ 深挖问题

1. **phase engine 压平顺序与 postconfiguration 的耦合**:压平发生在所有 postconfiguration 之后(`ngx_http.c:317-331`),意味着第三方模块若注册了 CONTENT handler 会改变 `next` 的计算;`find_config_index` 只在 `use_rewrite` 等条件影响数组长度时才需要——可以推演:如果模块在 FIND_CONFIG 注册 handler 会怎样?(答案藏在该阶段无 handler 槽位、`n=1` 硬编码里,`ngx_http.c:470`。)
2. **`r->count` 与 `blocked` 双计数的死锁窗口**:`close_request` 在 `count || blocked` 时都不拆(`request.c:3962-3966`),`terminate_request` 里 blocked 时只置 `connection->error = 1` 并等 finalizer(`2966-2972`)。哪些异步操作可能同时抬高两者、以及 V2/V3 下 `finalize_connection` 直接转 `close_request`(`2999-3015`)是否引入不同语义,值得专项审计。
3. **`uri_changes:4` 位域与 11 次上限**:位域只有 4 bit(`request.h:496`)却存值 11,依赖 `NGX_HTTP_MAX_URI_CHANGES + 1` 初值递减到 0 的用法;`post_action` 里专门处理 `r->uri_changes == 0` 的分支(`request.c:3921`)暗示曾有边界 bug,可考古其修复历史。
4. **请求体缓冲策略与背压**:`size += size >> 2` 的 25% 余量(`body.c:175-176`)、`rb->busy` 非空时对 `no_buffering` 与 `filter_need_buffering` 两种模式的不同挂起路径(`body.c:330-359`)构成了一组值得画图的背压状态机;与 `client_body_timeout` 定时器的交互(`438`)在慢客户端下如何退化。
5. **headers_in hash 的注册表模式能否覆盖 `max_headers` 防御**:计数在解析循环里(`request.c:1503-1510`),超限时主动置 `lingering_close = 1`(`1504`)——为何"头太多"也要 linger,而"头太长"同样置 linger(`1447`)?这关系到框架对"恶意慢速发送"的分类处理,可与 `discard_request_body`(`body.c:631`)的读残包策略合并研究。
6. **`NGX_DONE` 与 `NGX_DECLINED` 的语义重载**:同一返回值在不同层含义完全不同(挂起 vs 继续),checker 与 finalize 分别解释一遍;若要做第三个轻量级语义(如 early hint),需要同时改 checker、finalize 和过滤器三方约定,可评估当前预留位(`r->filter_finalize`,`request.c:2760-2762`)是否够用。
