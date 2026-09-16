# curl 扩展 · HTTP/2 多路复用:nghttp2 集成与流控

> curl 精简卷补篇。基线:commit `0b04700`。行号以 lib/http2.c、lib/multi.c 为准。

## HTTP/2 多路复用:一条连接 N 个 transfer

```
一条 TCP → 一个 nghttp2 session(cf_h2_ctx.h2)→ N 个 stream → N 个 easy handle
双回指:curl 侧 cf_h2_ctx.streams 哈希(mid→stream)http2.c:256-258
  nghttp2 侧 stream->user_data→Curl_easy*(提交时传入 :2133-2138)
```

## nghttp2 session 回调

- **on_frame_recv**(:1154-1227):stream_id==0 处理连接级帧——SETTINGS 捕获 MAX_CONCURRENT_STREAMS(:1180)并调 Curl_multi_connchanged(:1192);GOAWAY 记录 rcvd_goaway/remote_max_sid(:1204-1213);
- **on_data_chunk_recv**(:1262-1296):字节写入 Easy 的响应通道(:911-939),nghttp2_session_consume 上报消费(:1293);
- **on_stream_close**(:1298-1353):置 closed/error;REFUSED_STREAM 换连接重试(:1692-1697)。

## 流控:手动窗口管理

**禁用 nghttp2 自动窗口**(:462)改为 curl 手动接管。接收方向 cf_h2_update_local_win(:300-346):根据限速配额/暂停状态计算期望窗口(:285-298,暂停置 0),扩窗 set+submit 两步(:314-322),缩窗仅 set(:333)。触发点:头部完成(:904)、DATA 完成(:938)、上层取走数据(:1842)。**连接级窗口 1GB**(:2474-2481,兜底 #10988)。发送:请求体存 sendbuf(:2045),req_body_read_callback(:1577-1626)供给 nghttp2;未读完返回 DEFERRED(:1625)。

## multi 衔接

multi_socket 处理一个 socket 事件时,**同 socket 上所有 Easy 标 dirty**(multi.c:3262→multi_ev.c:585),再 multi_run_dirty 逐个 runsingle(multi.c:3194-3232)。只有第一个 Easy 真正走 cf_h2_recv→h2_progress_ingress(:1865-1939)做 socket 读取和解析;其他 Easy 的数据通过回调标记 dirty 下轮执行。**pollset 错位监听**:发送窗口 0 时改等 POLLIN(:2329-2371)。

## FAQ

**Q1:HTTP/2 连接复用条件?**
忙不拒(:685-707):超 MAX_CONCURRENT_STREAMS 才拒;bits.multiplex 需首个响应证据(:2664-2668)。

**Q2:为什么手动流控?**
(:462):nghttp2 自动窗口不够灵活——按限速/暂停动态调整。

**Q3:REFUSED_STREAM 怎么处理?**
(:1692-1697):换连接重试——服务端过载的正确响应。

**Q4:GOAWAY 后现有流怎么办?**
(:1204-1213):记录 remote_max_sid;现有流跑完才关连接。

**Q5:1GB 接收窗口为什么?**
(:2474-2481):高带宽高延迟(BDP)网络的吞吐——窗口=BDP 才打满。

**Q6:XFF 伪造在 H2 怎么处理?**
同 H1:默认信任零个代理(卷三 04 章)。

**Q7:流式响应(SSE)在 H2 怎么处理?**
(:938 DATA 后 consume):消费上报驱动窗口更新——无限流的流控。

**Q8:暂停的 transfer 怎么处理?**
(:285-298 窗口置 0):服务端停止发送——transfer.resume 恢复窗口。

## 小结

**HTTP/2="一条连接 N 个流+手动流控+连接级窗口 1GB+multi dirty 联动"**。深挖:优先级依赖树(nghttp2 deprecated 的处理)、GOAWAY 后的优雅排空、h2→h1 的降级策略。

> curl 扩展完——HTTP/2 多路复用补齐了传输协议的现代层。
