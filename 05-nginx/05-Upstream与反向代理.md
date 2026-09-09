# 第 05 章 · Upstream 与反向代理:函数指针换挡的状态机

> 基线:commit `231a60ee`(2026-09-02)。行号均以该版本源码为准。

## 5.0 三层架构:内容模块 × 框架 × LB

Nginx 把反向代理拆成三层:**内容生成器模块**(proxy/fastcgi/grpc,不碰 socket,只挂回调)、**upstream 框架**(协议无关的状态机)、**负载均衡器**(可插拔的 peer 选取)。框架与协议层的契约是 `ngx_http_upstream_t` 上的一组函数指针:create_request/reinit_request/process_header/abort_request/finalize_request/input_filter——协议编解码被完全抽象出去。

**与 HTTP 框架的衔接**:proxy_handler 注册为 location 的 content handler,读完请求体后把 `ngx_http_upstream_init` 挂为 post 回调,此后控制权移交框架。可观测性是一等公民:**每次尝试向 r->upstream_states 追加一条状态**,`$upstream_addr`/`$upstream_response_time` 的逗号列表就是这个数组的逐项投影——重试链路排障的黑匣子。

## 5.1 一次 proxy_pass 的生命周期

```
proxy_handler(装配回调)→ read_request_body(post 回调 = upstream_init)
  → init: create_request 编码协议头(两遍扫描:先求长后填充,杜绝 realloc)
      域名未解析? → resolver 异步 → 回调续跑
  → peer.init(LB 每请求初始化)→ connect(NGX_BUSY=无可选节点→next)
  → send_request(NGX_AGAIN 挂 send_timeout)
  → process_header(循环 recv;头超 buffer → "sent too big header")
      status ≥400 → test_next(重试?)→ intercept_errors(本机 error_page?)
  → send_response 三分岔:
      upgrade → 双向裸管道
      非缓冲 → 单缓冲直通(强制 limit_rate=0)
      缓冲 → ngx_event_pipe(双端缓冲 + 临时文件)
  → process_request → finalize_request(peer.free 归还、临时文件/缓存提交)
```

**事件总入口**(ngx_http_upstream.c:1315-1346)是本章核心的小函数:只按读/写事件查 `u->read/write_event_handler` 四个指针——**状态机不是 switch,而是函数指针换挡**。函数顶部 `ev->delayed && ev->timedout` 的清位是限速定时器与真实 read_timeout 区分的关键。所有阶段的换挡表:连接期(process_header/send_request)→ 缓冲响应(process_upstream/process_downstream)→ 非缓冲 → upgrade(4 个裸管道 handler)。

## 5.2 缓冲策略:三级分级

- **双端缓冲(event_pipe)**:读侧循环"取 free buf → 下游就绪则短路(upstream_blocked=1,先写客户端腾内存)→ recv_chain → 内存放不下写临时文件";写侧受 busy_size 约束(默认 bufs 总量两倍减一页)——**下游有界背压**;
- **影子缓冲零拷贝**:proxy 的 input_filter 不拷数据,给原始 buf 制造 shadow buf 链入 filter 链;body filter 消费完影子,pipe 才把原始 buf 标记 free——busy 链的持续引用就是背压计数来源;
- **临时文件**:优先级依次是 free buf → 新分配 → 冲下游 → 落盘 → 停读;`max_temp_file_size=0` 对非缓存响应是**彻底禁止落盘**;cacheable 响应的临时文件就是缓存文件本体。"an upstream response is buffered to a temporary file" 那条著名日志来自这里。

**限速作用于读后端侧**(不是写客户端):令牌桶式预算 `limit = limit_rate * (now - start + 1) - read_length`;`proxy_buffering off` 时框架强制 `r->limit_rate=0`——数据读一点发一点,没有管道可攒。

## 5.3 smooth weighted round-robin(代码语义)

```c
peer->current_weight += peer->effective_weight;
total += peer->effective_weight;
if (peer->effective_weight < peer->weight) {
    peer->effective_weight++;              /* 慢启动/失败恢复 */
}
if (best == NULL || peer->current_weight > best->current_weight) best = peer;
...
best->current_weight -= total;             /* 选中者扣减总权重 */
```
(round_robin.c:858-910)

效果:权重 5:1:1 的三个后端形成 511511511… 的平滑序列而非 5551 连发。**失败惩罚内建于选取算法**:每次失败扣 `effective_weight = weight/max_fails`(下限 0),此后每轮 +1 直到恢复——故障节点的"慢启动"不需要独立机制。`tried` 位图保证同一请求内重试不撞同一节点;单 peer 特例:free 时**无条件清零 fails**——单节点上游不应因自己重试失败把自己拉黑(否则永久不可用)。

其他 LB 全是"复用 RR 数据结构、只换 get"的装饰器:least_conn 用交叉乘比较(`conns×weight` 避免浮点),ip_hash 只哈希 IPv4 前三字节,hash 模块兼容 ketama 一致性哈希,keepalive 在原 get 之外加一层 LRU 缓存命中(命中返回 cached 连接,free 时 MSG_PEEK 验伤后才回池)。

## 5.4 zone 共享内存与运行期服务发现

`zone` 指令把整个 peer 链表深拷进 slab 共享内存,conns/fails/权重由所有 worker 共享;两级锁(peers 读写锁 + peer 自旋锁)+ refs/zombie 引用计数——请求执行中持有的 peer 标记 zombie,引用归零才真正 free,解决"一边遍历一边删除"的竞态。**无 zone 时 max_fails 各 worker 独立计数(阈值被 worker 数放大)——文档 FAQ "max_fails 不精确"的代码根源**。

`server ... resolve` 的运行期 DNS:回调做三向 diff(摘除消失节点/追加新地址/标记备份);**config 版本号防护**——每次增删使 `peers->config` 自增,持有旧版本的请求在 get_peer 直接 `NGX_BUSY`:**宁可成片 "no live upstreams" 也不在旧拓扑上重试**——有明确取舍但少有人知的失败模式。

## 5.5 失败重试语义

三层"失败"殊途同归于 `ngx_http_upstream_next`:连接级(FT_ERROR)、协议级(状态码在 next_upstream 掩码中,如 http_502)、超时(FT_TIMEOUT)。放弃重试的四个条件:

1. **NON_IDEMPOTENT**:POST/LOCK/PATCH 已发出请求体时强加此位,与默认掩码(仅 error timeout)求交必不相等——**默认非幂等请求不重试**;
2. **request_body_no_buffering**:流式 body 已部分发给 A 节点,重发语义不完整;
3. **next_upstream_timeout**:从 peer.start_time 起算的总预算,防"每跳都重试"雪崩;
4. **tries 计数**:隐式 upstream 对每个 DNS 解析出的地址都算一次 try(域名解析出 5 个 A 记录默认 5 次重试机会!)——`next_upstream_tries` 为收敛它而存在。

放弃时的兜底:`cache_use_stale` 用过期缓存重放替代把错误抛给客户端。**响应已开始后错误不能重试**(HTTP 层无法回收已发字节);失败的第一反应是"断连"而非"复用"——任何可疑连接退化为新建,正确性置于连接复用率之上。

## 5.6 FAQ

**Q1:为什么日志出现 "no live upstreams" 而配置里有健康节点?**
全部 peer 被 down/max_fails 拉黑/max_conns 满,或 zone 下 config 版本变化触发 BUSY;FT_NOLIVE 不在默认重试掩码,直接 502。

**Q2:proxy_next_upstream 默认重试哪些?POST 呢?**
默认 error|timeout;状态码、invalid_header 要显式加;POST 非幂等默认不重试(non_idempotent 显式放行)。

**Q3:max_fails=3 fail_timeout=10s 怎么计数?**
10 秒窗口内第 3 次 FAILED 后拉黑 10 秒;无 zone 时每 worker 独立,等效阈值 ×worker 数。

**Q4:"upstream sent too big header" 后是重试还是 502?**
invalid_header 不在默认掩码,通常 502;治本是调大 proxy_buffer_size。

**Q5:X-Accel-Redirect 为什么在发头之前生效?**
process_headers 在 send_header 之前检查,命中则 finalize(NGX_DECLINED 保留请求)后 internal_redirect——后端控制代理行为的私有协议(X-Accel-Buffering/Limit-Rate 同理)。

**Q6:解析失败返回什么?**
未配 resolver → 502 "no resolver defined";resolver 内部有 5s 重发 + 缓存,同一域名并发请求共享一次出网查询。

## 5.7 小结与深挖方向

本章结论:**upstream = 回调换挡状态机 + 三级分级缓冲 + 装饰器式 LB + 保守的失败语义**;smooth WRR 把失败惩罚内建于选取、zone 把运行期服务发现做成内存内最优更新。深挖:

1. NGX_BUSY 与 config 版本竞争窗口(DNS 频繁变化 + 高并发的成片 BUSY);
2. smooth WRR 的 O(N) 每请求成本在 10k+ 节点下的锁前缀开销;
3. `p->length == -1` 与 premature closed 的误判面(chunked 中途断链);
4. 限速定时器与 delayed 的竞态(时钟跳变时误判 read_timeout);
5. X-Accel-Redirect 后 upstream keepalive 是否实际失效。

> 下一章:内存池与数据结构——"常数 4"的自愈机制与 slab 的位图中轴。
