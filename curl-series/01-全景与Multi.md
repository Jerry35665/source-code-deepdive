# 第 01 章 · 全景与 Multi 架构:easy 是 multi 的糖

> 基线:commit `0b04700`(8.22.1-DEV)。行号以 lib/easy.c、lib/multi.c、lib/multihandle.h、lib/conncache.c、lib/url.c 为准。**基线勘误**:本 commit 的架构比常见资料新一代——`CURLM_STATE_*` 已改名 `MSTATE_*` 移入 multihandle.h;conncache 重构为 `struct cpool`(dest2bundle 两级);multi_runsingle 已拆为每状态 `multistate_*` 函数;hyper 后端已于 8.12.0 移除。

## 1.0 全景:一次请求的状态机

```
easy_perform(easy.c:768) = 内建 multi + 轮询(easy 是 multi 的糖,注释自认 :751-767)
  → multi_runsingle(multi.c:2713)按 MSTATE 分发:
INIT → SETUP(挂定时器;重定向回此) → CONNECT(池内找连接/新建;池满转 PENDING)
  → CONNECTING → PROTOCONNECT(ING) → DO → DOING(ING_MORE) → DID
  → PERFORMING ⇄ RATELIMITING → DONE → COMPLETED → MSGSENT
```

17 态枚举在 multihandle.h:47-65;改状态必须经 `mstate()`(multi.c:152,带 state_enter 钩子表)。**DO/DOING/DOING_MORE 是"发请求"的三段**(FTP 多轮往返),DID→PERFORMING 才进数据面 Curl_sendrecv(transfer.c:354);重定向裁决在 PERFORMING 内回 SETUP。

## 1.2 easy 为什么是 multi 的糖

`easy_perform`(:768-841):内部 `Curl_multi_handle(16,1,3,7,3)` 建隐藏 multi(:798-806)+easy_transfer 轮询循环(poll 1000ms+perform,:715-739)。**逻辑单份,API 双形态**——阻塞用户拿到最简单接口,事件驱动用户拿 multi_socket。两种驱动:curl_multi_perform(轮询,:2967)vs curl_multi_socket_action(:3462,事件注册 CURLMOPT_SOCKETFUNCTION :3330,per-fd 读写掩码差量合并通知 multi_ev.c:278-341)——后者是 nginx 集成式的宿主模型。

## 1.3 连接缓存:cpool 与复用谓词

`struct cpool` 是 dest2bundle 两级(conncache.h:49-59):key=`conn->destination` 字符串(host:port,IPv6 带 scope,url.c:1528-1548),哈希到 bundle(同目的地链表)。查找 `Curl_cpool_find`(conncache.c:701):优先重试 lastconnect_id(保多请求认证同连接),再过 `url_match_conn` 十余项谓词(url.c:981-1058:connect_only/IP 版本/本地绑定/SSL 配置/代理/NTLM/MAX_CONCURRENT_STREAMS/conn_max_age…);**空闲连接复用前还要健康检查** `Curl_cpool_conn_seems_healthy`(conncache.c:974,含"无传输却有输入待读"判死)。

## 1.4 设计动机

1. **一切皆 multi**:阻塞/事件驱动共享同一状态机——两套逻辑必然漂移,curl 三十年没漂;
2. **连接复用是命根**:TLS 握手成本远超 HTTP 事务,cpool 的十余项谓词是"复用正确性"的全部;
3. **回调模型**:287 个 CURLOPT 是 C 无闭包时代的函数指针+void* 载荷范式(对照 PG config_fn_t,PG 卷一 11 章);
4. **8 周一版**(docs/RELEASE-PROCEDURE.md:66):三十年不破 ABI 的发布纪律。

## 1.5 FAQ

**Q1:easy 和 multi 能混用吗?**
不能混 handle,但 easy 内部就是 multi——性能与功能完全等价(:751-767 注释)。

**Q2:为什么连接池按 host:port 字符串做 key?**
(:1528-1548):字符串即"目的地"的完整语义(IPv6 scope 都装得下),比结构体比较简单。

**Q3:复用的连接健康吗?**
空闲复用前跑 seems_healthy(:974):对端半关(收到输入却无传输)即判死。

**Q4:MSTATE 为什么拆出 DO/DOING/DOING_MORE?**
FTP 类协议"发命令→等响应→再发"多轮(:2783 起):状态机为最复杂协议建模,简单协议只走三态。

**Q5:池满会怎样?**
转 PENDING 排队(:1.1 图),完成一个再唤醒——背压内建。

**Q6:multi_socket 和 multi_perform 选哪个?**
集成进事件循环(nginx/GPU 服务)用 socket 模式(:3330);独立线程工具用 perform 轮询。

**Q7:hyper 后端呢?**
8.12.0 已移除(HTTP 解析回归自研)——实验后撤的教训。

**Q8:连接多久算旧?**
conn_max_age 谓词(:981-1058):可配置的最大空闲年龄。

**Q9:为什么优先 lastconnect_id?**
认证类连接(NTLM)必须同连接(:701):正确性优先于通用性。

**Q10:287 个选项怎么组织?**
Curl_init_userdefined 默认值管道(url.c:307):选项=结构体字段+默认+解析器三件套。

## 1.6 小结与深挖方向

本章结论:**骨架="状态机即协议无关内核+连接池即复用正确性+双驱动 API 即宿主光谱"**。深挖:

1. mstate() 的 state_enter 钩子表(:152)在调试模式的行为;
2. PENDING 队列的公平性(多个 easy 等同一 host);
3. cpool bucket 的哈希冲突与迁移成本;
4. RATELIMITING 态(multihandle.h:60)的令牌桶实现;
5. dead-end 连接的回收策略。

> 下一章:URL 解析与认证——一次请求的语义层。
