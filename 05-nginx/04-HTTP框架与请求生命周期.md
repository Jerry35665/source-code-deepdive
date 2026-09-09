# 第 04 章 · HTTP 框架与请求生命周期:11 阶段引擎与返回值路由器

> 基线:commit `231a60ee`(2026-09-02)。行号均以该版本源码为准。

## 4.0 全景:三层骨架

Nginx 的 HTTP 框架把"一次请求的处理过程"拆成三种可被模块插桩的数据结构,全部挂在 cmcf 上:

1. **阶段引擎**:11 个阶段(ngx_http_core_module.h:110-129)在配置期被"压平"成线性数组 `phase_engine.handlers`,每元素 `{checker, handler, next}` 三元组——运行期只做一件事:在这张数组上按 checker 语义游走;
2. **过滤器链**:头/响应体/请求体三条单链,模块在 postconfiguration 时"next = top; top = 我"头插压栈;
3. **变量表**:每个 `$var` 配置期登记拿**整数下标**,请求结构体预分配 `r->variables` 数组,取值即按下标查缓存。

变量取值三档:hash 命中且 INDEXED → 查缓存数组;现场 get_handler(带 `ngx_http_variable_depth` 计数器防循环引用);前缀变量线性匹配(`http_*`/`arg_*` 动态命名靠这档)。最简取值器 `ngx_http_variable_request`:`(ngx_str_t *)((char *) r + data)` 直接按偏移取请求字段——"变量即请求字段快照"。

初始化时序关键:先 conf 创建合并 → location 三叉树 → postconfiguration(模块在此注册 phase handler 与 filter)→ 变量定版 → **最后才压平 phase engine**——handler 注册发生在压平之前。

## 4.1 一次 GET 的完整生命周期

```
accept → ngx_http_init_connection(hc 挂 addr 配置;请求对象尚不存在)
  → 首字节到达,分配 c->buffer → ngx_http_create_request(每请求一个 pool)
  → process_request_line(逐字节状态机,可随时被事件打断续跑)
  → process_request_headers(每行过 headers_in_hash,特殊头解析期落位)
  → process_request → phase engine(11 阶段)
  → content handler 产出 → send_header/output_filter(过滤器链)
  → finalize_request(多出口)
      ├─ 未发完 → set_write_handler 等可写
      ├─ keepalive → set_keepalive(检查 pipeline 残留)
      └─ close → free_request(跑 cleanup 链 + 记访问日志)→ close_connection
```

三个工程细节:

- **Host 匹配前的一切配置都来自 default_server**——请求对象尚不存在时 `hc` 只保存 addr_conf(ctx);
- **解析器是无回溯的逐字节状态机**,state 存 `r->state`——随时可在任意字节间被事件循环打断续跑,"读到一半先去处理别的连接"的根基;`sw_method` 用 4 字节整型比较识别 GET/POST(`ngx_str4cmp`);头解析的 `lowcase[256]` 表一表三用(转小写 + 累进 hash + 写 lowcase_header 缓存);
- **每请求内存预算静态可估**:request_pool_size 建池 + 按 variables.nelts 精确分配变量缓存。

## 4.2 11 阶段与 checker 的三种遍历

| 阶段 | checker | 备注 |
|---|---|---|
| POST_READ / SERVER_REWRITE / FIND_CONFIG / REWRITE / POST_REWRITE / PREACCESS / ACCESS / POST_ACCESS / PRECONTENT / CONTENT / LOG | generic / rewrite / 专属 | 控制阶段(FIND_CONFIG/POST_*)框架自用 |

压平的三个关键:**数组总长 `n = 1 + use_rewrite + use_access + 其余 handler 数`**——控制阶段仅在确实有 rewrite/access handler 时才占槽位(条件编译式的占位);**POST_REWRITE 的 next 硬编码指向 find_config_index**——"rewrite 后回跳"不是运行期逻辑而是配置期拼进数组的静态跳线(ngx_http.c:520);同一阶段内**配置里写在后面的先执行**(逆序压栈)。

checker 三种遍历:generic 型(OK 跳过同阶段余下、DECLINED 前进一格、AGAIN/DONE 挂起);rewrite 型(OK 不再是跳过而是 finalize——rewrite 模块把"改完继续"翻译成 DECLINED);专属 checker(FIND_CONFIG 做 location 匹配 + 拦截 internal 外部访问;ACCESS 对 subrequest 直接跳过 + `satisfy all/any` 折叠——**失败"记账"而非立即终止**,由 POST_ACCESS 统一消费;CONTENT 逐个 DECLINED 下探)。运行期驱动者只有 4 行:core_run_phases 的 while 循环。

## 4.3 finalize:返回值路由器

`ngx_http_finalize_request`(request.c:2743-2928)把 handler 的"终局意图"翻译成对事件驱动状态机的下一组动作:

| 传入 rc | 出口 |
|---|---|
| NGX_DONE | 只还引用计数,请求继续(异步 body) |
| NGX_DECLINED | **重入 phase engine** |
| subrequest 终局 | post_subrequest 回调 → 还 c->data 给 parent → post_request 唤醒 |
| NGX_ERROR/超时 | terminate_request:跨过所有中间状态直接拆房 |
| rc ≥ SPECIAL_RESPONSE | 转错误页 handler 后**递归 finalize** |
| 正常 rc,有 buffered | set_write_handler 挂写事件 |
| 正常 rc,发完 | keepalive / lingering / close |

**同一返回值在 checker 层和 finalize 层被解释两遍**(DECLINED 在 finalize 里变成"重入 phase engine")。唤醒请求需要 posted 机制:finalize 常发生在"当前正在处理另一个请求"的调用栈里,直接切换 c->data 会破坏上下文;`ngx_http_post_request` 挂链去重,`ngx_http_run_posted_requests` 在最外层事件回调返回前循环执行——**"事件 → 当前请求回调 → posted 队列"的两级调度**是 subrequest/terminate/异步 body 共用的总线。

keepalive 分支的精妙:`set_keepalive` 里 `b->pos < b->last` **一个字节比较**即判定流水线残留,当场新建请求并把读 handler 恢复后 post;无残留则 `ngx_pfree` 掉 c->buffer 物理内存,把空闲连接内存压到最低(request.c:3374、3472)——keepalive 的内存账本与 pipeline 复用在同一函数里完成分流。

## 4.4 filter 链:单向流

注册是标准头插法(gzip 例):`next = top; top = 我`。编译顺序(auto/modules)决定链序:**越靠后注册的模块越靠近内容生产者**——gzip 看到原始 body,not_modified 的头判断更靠近生成端。write filter 是链的**终点而非普通过滤器**:把新 chain 拼到 `r->out` 残链上、按 limit_rate 限速、没写完注册写事件——**每经过一次 body 链,write filter 都可能被反复穿越而数据滞留在 r->out**。

收益与代价:头/体一旦进入过滤器链**不再回头**——`last_buf` 是链上唯一"终点信号",各 filter 都要正确转发(写输出 filter 最常见的出错点);错误传播走连接级标志 `c->error` 而非返回值逐层翻译。

## 4.5 FAQ

**Q1:rewrite 的 last 和 break 在源码里是什么?**
last 触发 uri_changed,被 POST_REWRITE 发现后跳回 FIND_CONFIG(静态跳线);break 不改 URI,rewrite 返回 DECLINED 前进,后续在当前 location 继续。

**Q2:内部重定向为什么不会死循环?**
每请求 4 位计数 uri_changes,初值 11,内部跳转每次递减,归零即 500;subrequest 另有独立上限 50。

**Q3:subrequest 是递归吗?**
不是。分配 sr 复用父请求 pool 与变量,挂 posted_requests 排队;调度发生在事件回调尾部,保证"请求切换"只在事件处理边界之外——避免深层递归。

**Q4:为什么 subrequest 的 access 阶段被跳过?**
checker 开头 `if (r != r->main)` 直接前进;subrequest 鉴权继承父请求配置上下文。

**Q5:请求体一定先读完才处理吗?**
默认由 content handler 按需发起;读取循环不感知编码,长度判定下放给请求体过滤器按 chunked 分派——一套循环两种编码。

**Q6:访问日志在哪打的?**
唯一入口 ngx_http_free_request(`!r->logged` 时);LOG 阶段 handler 是另一层。

**Q7:头太多/太长为什么都置 lingering_close?**
框架对"恶意慢速发送"的分类处理:linger 读残包丢弃,防连接复用读到脏数据。

## 4.6 小结与深挖方向

本章结论:**HTTP 框架 = 配置期压平的确定性流水线(零虚函数)+ 单向过滤器链 + posted 两级调度**;一切都刻意避开运行期动态注册,以牺牲运行时可插拔换取每请求开销的可预测。与 Apache 的 hook 模型同构,但 Nginx 把"选 location"做成数组里的显式环节,热路径上没有任何查找与分支表遍历。深挖:

1. phase engine 压平与 postconfiguration 的耦合(FIND_CONFIG 无 handler 槽位的推演);
2. r->count 与 blocked 双计数的死锁窗口;
3. 请求体缓冲策略与背压状态机(25% 余量与两种挂起路径);
4. NGX_DONE/DECLINED 语义重载的第三个预留位(filter_finalize)。

> 下一章上到反向代理:upstream 状态机的函数指针换挡与 smooth WRR。
