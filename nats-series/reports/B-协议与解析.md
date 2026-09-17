# NATS 深读 · 报告 B:文本协议与解析 —— 一个状态机吃掉全部流量

> 基线:nats-server commit `8f3f31b0366eca0d855d0750b7ca547eadd10eff`(版本 2.15.0-dev,`server/const.go:69`)。
> 核心文件:`server/parser.go`(1339 行)、`server/client.go`(7065 行)、`server/const.go`。
> 本文只讲"协议字节如何变成内存对象"。sublist 匹配算法留待报告 C。
> 阅读顺序建议:先用 2.1 的状态机图与 3.1 的握手时序建立骨架,再按 4→5→7→8 深入数据与心跳路径,最后以第 9 节的动机清单收束。

---

## 1. 协议全集与字节布局

NATS 的线上协议是纯文本、以 `\r\n` 分行(LEN_CR_LF=2,`const.go:126-129`)。服务端支持的协议版本 PROTO=1(`const.go:75`)。每条控制行有 4096 字节上限(`const.go:90`,快照到连接 `client.go:762-764`);参数个数上限被编译期定死:MAX_MSG_ARGS=4、MAX_RMSG_ARGS=6、MAX_HMSG_ARGS=7、MAX_PUB_ARGS=3、MAX_HPUB_ARGS=4(`const.go:174-186`)。

| 操作 | 方向 | 字节布局(不含 `server/parser.go` 中的路由扩展 RS+/LS+/A+/A-) | 参数个数 |
|---|---|---|---|
| INFO | S→C / 双向(路由、叶子) | `INFO {json}\r\n` | 1 个 JSON 块 |
| CONNECT | C→S | `CONNECT {json}\r\n` | 1 个 JSON 块 |
| PUB | C→S | `PUB <subject> [reply-to] <#bytes>\r\n<payload>\r\n` | 2 或 3 |
| HPUB | C→S | `HPUB <subject> [reply-to] <hdr#bytes> <total#bytes>\r\n<hdr+payload>\r\n` | 3 或 4 |
| SUB | C→S | `SUB <subject> [queue-group] <sid>\r\n` | 2 或 3 |
| UNSUB | C→S | `UNSUB <sid> [max_msgs]\r\n` | 1 或 2 |
| MSG | S→C | `MSG <subject> <sid> [reply-to] <#bytes>\r\n<payload>\r\n` | 3 或 4 |
| HMSG | S→C | `HMSG <subject> <sid> [reply-to] <hdr#> <total#>\r\n<hdr+payload>\r\n` | 5 或 6 |
| PING / PONG | 双向 | `PING\r\n` / `PONG\r\n`(`client.go:91-92`) | 0 |
| +OK | S→C | `+OK\r\n`(verbose,`client.go:94`) | 0 |
| -ERR | S→C | `-ERR '<message>'\r\n`(`client.go:93`,`client.go:2748`) | 1 |

四个协议常量就是四行字符串拼接(`server/client.go:91-94`),发送即 `enqueueProto` 入队,不经过任何序列化器。

**集群/叶子扩展指令**在同一状态机上多开了几个前缀分支:路由连接用 `RS+`/`RS-` 与 `LS+`/`LS-` 声明远端兴趣(`OP_R`/`OP_L`,仅非 CLIENT 可入,`parser.go:224-241`、`parser.go:739-756`),落到 `processRemoteSub`(`route.go:1502`);网关用 `RS+`(`gateway.go:2028`);账户级订阅 `A+`/`A-` 只给 LEAF/ROUTER(`parser.go:236-241`、`parser.go:545-635`,处理在 `route.go:172`)。入站消息同理:`MSG` 行在 ROUTER/GATEWAY 上被解释为 `RMSG`(6 参数,含 origin/account)或 `LMSG`,在 LEAF 上解释为 `LMSG`,分派给 `processRoutedMsgArgs`(`route.go:381`)、`processLeafMsgArgs`(`leafnode.go:3226`)等;参数个数上限 MAX_RMSG_ARGS=6、MAX_HMSG_ARGS=7 就是为此而设(`const.go:177-180`)。

## 2. Parser 状态机:`parse()` 一遍扫描

### 2.1 状态机全景(以 PUB 与 SUB 为例)

```
                       OP_START (parser.go:161)
            首字节 b 存入 c.op;非 CONNECT 首包要过 awaitingAuth 检查 (163-214)
        ┌───────┬──────────┬───────┬────────┬─────────┬───────┬──────┬──────┐
       'P'     'H'        'S'     'U'      'C'      'I'    '+'    '-'
        │        │         │       │        │        │       │      │
      OP_P    OP_H       OP_S    OP_U     OP_C     OP_I  OP_PLUS OP_MINUS
        │'U'    │'P'/'M'   │'U'    │'N'..   │..'T'   │'NFO'  │'OK'  │'ERR'
        ▼       ▼          ▼       ▼        ▼        ▼       ▼      ▼
      OP_PU   OP_HP/OP_HM OP_SU  OP_UN..  OP_CONNECT OP_INFO ...   MINUS_ERR_ARG
        │'B'    │'B'/'G'   │'B'    │'B'      │非空白   │非空白  │'\n'  │'\n'
        ▼       ▼          ▼       ▼         ▼        ▼       │     processErr
    OP_PUB_SPC OP_HPUB_SPC/OP_HMSG_SPC  │      CONNECT_ARG   │    (client.go:2225)
        │非空白 (pa.hdr=-1/0, 记 as)      │        │'\n'       │
        ▼                               │        ▼            │
     PUB_ARG (parser.go:435)      SUB_ARG (parser.go:665) processConnect
        │'\n'                           │'\n'   (client.go:2293)
        │ arg = buf[as : i-drop] (445)  │ arg 同上 (675)
        ▼                               ▼
   processPub(arg) (453)           parseSub(arg) (687)
        │ state=MSG_PAYLOAD, as=i+1 (457)         │ state=OP_START (715)
        │ msgBuf==nil 时 i 直接跳过 payload (462) │
        ▼                                        ▼
   MSG_PAYLOAD (469) ──收满 pa.size──▶ MSG_END_R (494) ─'\r'─▶ MSG_END_N (502)
        │ 若跨读缓冲:拷贝进 msgBuf (470-487)              │'\n'
        │ 否则零拷贝:仅判 i-as+1>=size (491)             ▼
        └──────────────────────── msgBuf = buf[as : i+1] (509)
                                  processInboundMsg(msgBuf) (533)
                                  重置 pa/argBuf/msgBuf/state (537-544) → OP_START
```

状态常量共 76 个(`server/parser.go:59-134`),全部是"逐字符前缀匹配"的中间态。`parse()` 主循环是一个 `for i=0; i<len(buf); i++` 加 `switch c.state`(`parser.go:157-160`),每字节 O(1) 转移;函数允许 `i` 跳跃,读到 payload 尾部时直接 `i = c.as + c.pa.size - LEN_CR_LF`(`parser.go:462`、`parser.go:1055`),即**payload 内容一个字节都不 switch**。

PING/PONG 的解析路径最短:OP_PI→OP_PIN→OP_PING 遇 `\n` 即调 `c.processPing()`(`parser.go:868-876`),PONG 对称(`parser.go:891-899`)。

图中通用机制:

- `c.drop` 处理 CR:ARG 态 `case '\r': c.drop = 1`,遇 `\n` 时参数右界回缩一格(`parser.go:437-445`、`parser.go:667-675`),同时兼容裸 `\n`。
- `c.as` 在进入 ARG 态时记录参数起点(`parser.go:430-433`、`parser.go:659-663`);`OP_x_SPC` 态吞掉连续空白(`parser.go:426-429`)。
- 每条指令处理完统一回 `OP_START` 并清空 `pa` 全部字段(`parser.go:537-544`),防止上一条消息的 slice 泄漏进下一条。

### 2.2 一台状态机服务四种连接

同一个 `switch c.state` 里,ARG 态的终点按 `c.kind` 分流:SUB_ARG 在 CLIENT 上走 `parseSub`、在 ROUTER 上按首字节 `c.op` 区分 RS/LS、在 GATEWAY/LEAF 上走各自的订阅前向(`parser.go:682-711`);UNSUB_ARG、MSG_ARG 同构(`parser.go:817-844`、`parser.go:1027-1046`)。这意味着协议解析只写一份,路由/网关/叶子的语义差异全部收敛在 process 函数内——这是"一个状态机吃掉全部流量"的字面含义。

### 2.3 零拷贝:直接在 read buffer 上取 arg 与 payload

连接的 `readLoop` 做盲读(`client.go:1467`,起始读缓冲 512B,`client.go:110`),把 `b[:n]` 整块交给 `parse()`(`client.go:1580`)。状态机不在协议行上做任何拷贝:

- 参数行 slice:`arg = buf[c.as : i-c.drop]`(`parser.go:445`,PUB;SUB 同型在 `parser.go:675`)。`c.as` 是参数起点偏移,`c.drop` 记录 `\r` 占位。
- payload slice:不跨读缓冲时,`MSG_END_N` 直接 `c.msgBuf = buf[c.as : i+1]`(`parser.go:509`),headers/payload 的切分只靠 `c.pa.hdr` 边界(`client.go:2875-2880` 的 `msgParts`)。
- 主体改写也发生在这个 slice 上:账户主题映射在 `MSG_END_N` 处就地替换 `c.pa.subject`(`parser.go:519-528`、`client.go:4348-4355`),不重新拷贝消息体。

每个连接持有一份 `parseState`,内嵌 `scratch [MAX_CONTROL_LINE_SIZE]byte` 和预分配的 `argsa [MAX_HMSG_ARGS+1][]byte`(`parser.go:25-36`);`processPub/processHeaderPub` 用栈上数组 `a := [MAX_PUB_ARGS][]byte{}` 承接 split 出的参数(`client.go:2889-2890`、`client.go:2961-2962`),注释明说是为避免运行时堆问题。`pubArg` 结构体缓存 subject/reply/szb/hdb 等 slice 及 `pacache`(映射缓存)(`parser.go:38-55`)。

### 2.4 跨读缓冲(split buffer):scratch 与 argBuf/msgBuf

盲读可能把一条指令劈成两半。状态机出口处统一处理:

```go
// server/parser.go:1204-1207(控制行跨读)
if c.argBuf == nil {
    c.argBuf = c.scratch[:0]
    c.argBuf = append(c.argBuf, buf[c.as:i-c.drop]...)
}
```

要点:`argBuf` **复用 4KB 的 scratch 数组**(`parser.go:1205`),只有超限才落到堆。payload 跨读时优先也用 scratch 剩余容量,装不下才 `make([]byte, lrem, c.pa.size+LEN_CR_LF)`(`parser.go:1230-1243`);此时若 pubArg 还引用着旧 read buffer,必须 `clonePubArg` 拷贝一份再重放对应 process 函数(`parser.go:1217-1226`、`parser.go:1297-1325`)。下一轮读进来后 `MSG_PAYLOAD` 按块 copy 补齐(`parser.go:470-487`)。

控制行长度防线在 `overMaxControlLineLimit`:CLIENT 上限即 mcl(默认 4096),LEAF/ROUTER/GATEWAY 放大 16 倍(64KB,容纳 origin/account/queue 扩展帧),超限发 `-ERR` 并断连(`parser.go:1274-1293`)。

### 2.5 解析错误路径

任何非法转移 `goto parseErr`:回发 `-ERR 'Unknown Protocol Operation'`,带 32 字节现场片段(`PROTO_SNIPPET_SIZE`,`const.go:168`;`parser.go:1252-1256`),readLoop 捕获后按 `ProtocolViolation` 关闭连接(`client.go:1595-1598`)。CLIENT 收到 `R/L/A` 开头指令直接 parseErr(非 CLIENT 专属指令,`parser.go:224-241`)。

## 3. INFO/CONNECT 握手

### 3.1 时序

```
server                                       client
  │ accept → createClient (server/server.go:3357)
  ├─ INFO {server_id,version,proto,max_payload,        │
  │        auth_required,tls_required,headers,          │
  │        connect_urls,client_ip,...}  ────────────────▶│  (server.go:3360-3364, sendProtoNow 同步直发)
  │        ※ TLSHandshakeFirst 时先不发,等 50ms 回退      │
  │                                                     ├─ CONNECT {verbose,pedantic,
  │◀──────────── CONNECT {lang,version,protocol,        │             jwt/user/pass/token,
  │                       headers,no_responders,...} ───┤             protocol,headers,
  │   CONNECT_ARG → processConnect (parser.go:950,968)  │             no_responders}
  ├─ 鉴权 checkAuthentication (client.go:2392)          │
  ├─ 协议校验: 0≤protocol≤1 (client.go:2476-2479)       │
  ├─ no_responders 需 headers (client.go:2483-2490)     │
  ├─ (verbose) +OK; clearAuthTimer; 设首个 PING 定时器    │
  │    (client.go:2297, 2313-2314)                      ├─ PING (多数客户端库惯例)
  │◀────────────────────────────────────────────────────┤
  ├─ PONG (firstPongSent 置位, client.go:2793-2798)      │
  ├─ proto≥1 时附带 INFO{connect_info,remote_account} ──▶│  (client.go:2801-2817)
  ▼ 握手完成,进入稳态
```

服务端在 accept 时就同步直发 INFO(`server.go:3357-3364`),此时 writeLoop 尚未启动,用 `sendProtoNow` 直写;`tls_first` 场景推迟(`server.go:3360`)。客户端 CONNECT 到来后 `processConnect` 在锁内 `json.Unmarshal` 进 `c.opts`(`client.go:2325`),置 `connectReceived` 标志(`client.go:2331-2332`)。

### 3.2 路由与叶子的握手差异

CLIENT 是 INFO→CONNECT→PING→PONG;ROUTER/GATEWAY/LEAF 上,INFO 由对端发来,`processInfo` 按 kind 分派给 `processRouteInfo/processGatewayInfo/processLeafnodeInfo`(`client.go:2209-2223`),CONNECT 则整体委托给 `processRouteConnect/processGatewayConnect/processLeafNodeConnect`(`client.go:2494-2503`)。特殊分支:压缩协商的 leaf 允许先发 INFO 再 CONNECT(`parser.go:204-209`),压缩切换在 readLoop 出口生效(`client.go:1607-1612`)。

### 3.3 协商项

- **headers**:`c.headers = supportsHeaders && c.opts.Headers`——服务器不声明 NoHeaderSupport 且客户端 CONNECT 声明 headers 才成立(`client.go:2368`;`supportsHeaders` 定义在 `server.go:4066-4071`)。
- **no_responders**:CONNECT 字段 `no_responders`(`client.go:696`);请求它但没开 headers 视为协议错,发 `-ERR` 并关连(`client.go:2483-2490`)。
- **echo/verbose**:分别落到 `c.echo`(`client.go:2334`)与 verbose(开启时每个操作回 `+OK`,`client.go:4408-4410`、`client.go:2491-2493`)。
- **鉴权失败**走 `authViolation`:回 `-ERR 'Authorization Violation'` 后关连(`client.go:2532-2555`,发送在 2552,关闭在 2554)。首包不是 CONNECT 也会在 parser 里被 `awaitingAuth` 拦下(`parser.go:151,163-214`;`client.go:5988`)。
- 服务端对 CLIENT 的 INFO 在首条 PING 后可再推一次带 `ConnectInfo=true` 的异步 INFO(携带 `RemoteAccount`/`IsSystemAccount`,`client.go:2801-2817`;集群变化时的全局异步推送见 `server.go:4793-4796`)。

## 4. PUB → MSG 全链:从入站字节到出站帧

以 CLIENT 发布为例,链路为:`PUB_ARG → processPub → MSG_PAYLOAD/MSG_END_N → processInboundMsg → processInboundClientMsg → processMsgResults → (sublist 匹配,报告 C) → deliverMsg → queueOutbound`。

**(1) processPub** 把参数行 split 成 `[subject, (reply), size]`(`client.go:2982-2995`),`parseSize` 转字节,负数或超过 `c.mpay`(max_payload,默认 1MB,`const.go:94`)即 `maxPayloadViolation` 发 `-ERR` 并关连(`client.go:3000-3005`、`client.go:2574-2578`)。HPUB 额外校验 `hdr≤total`(`client.go:2935-2937`)。值得注意:subject 的字面合法性(`*`/`>`/空格)默认**不校验**,只有 CONNECT 声明 `pedantic` 时才检查并回 `-ERR 'Invalid Publish Subject'`(`client.go:3006-3008`、`client.go:2953-2955`)——解析器把一切校验都从热路径上挪走了。

**(2) processInboundClientMsg** 计数 `in.msgs/in.bytes`(`client.go:4367-4368`),查 pub 权限 allow/deny(`client.go:4386-4392`),违例回 `-ERR 'Permissions Violation for Publish to ...'`(`client.go:5804-5811`)——注意这只发错误不断连。

**(3) 匹配与投递**。`deliverMsg`(`client.go:3778`)拿目标订阅的 client 加锁,依次处理 echo 抑制(`client.go:3784`)、deny 订阅(`client.go:3797`)、auto-unsub 计数(`client.go:3866-3896`)、对不支持 headers 的订阅者剥掉 header 部分(`client.go:3902-3905`),最后两行完成"出站帧"——没有构造完整 MSG 字符串,而是把协议头和 payload 分别入队:

```go
// server/client.go:4010-4016
// Queue to outbound buffer
client.queueOutbound(mh)      // "MSG <subject> <sid> [reply] <size>\r\n"
client.queueOutbound(msg)     // payload + \r\n(零拷贝引用入站 buffer)
if prodIsMQTT {
    client.queueOutbound([]byte(CR_LF))  // MQTT 生产者没有 CRLF,补一条
}
```

MSG 协议头由 `msgHeader` 生成,复用 `c.msgb` 这个 1KB scratch,前 5 字节预置 `"RMSG "` 按需改写成 `MSG `/`HMSG`(`client.go:3692-3731`,首字符改写在 3701;scratch 初始化在 `client.go:776`,常量在 `client.go:105-107`)。**队列组在协议层的表示**:入站是 `SUB <subject> <queue> <sid>` 三参数(`client.go:3051-3054`),存进 `subscription.queue`(`client.go:3070`);往路由/叶子转发时队列组不展开,折叠成 `| `(仅队列)或 `+ `(带 reply)前缀加逗号连接的队列名(`client.go:3651-3659`)。投递后 `flushSignal` 唤醒 writeLoop、`addToPCD` 登记待 flush 的目标连接(`client.go:4034-4040`)。

另一个热路径细节:每连接的 `readCache`(`client.go:494-511`)为 CLIENT 缓存 `(account, subject) → SublistResult`(`results`),为 ROUTER/GATEWAY 维护账户感知的 `pacache` L1(`client.go:500`),全部只在 readLoop 生命周期内使用,退出时置 nil(`client.go:1502`)。同一次盲读里反复发布的相同主题,匹配结果直接命中缓存——文本协议的"每连接单读循环串行解析"模型使这些缓存无需加锁。

### 4.1 批量 flush 管线:PCD / fsp / writeLoop

`deliverMsg` 只把字节挂进目标连接的 `out.nb`,并不写 socket。生产者的 readLoop 用 `addToPCD` 把目标连接登记进自己的 `pcd` 集合并给其 `out.fsp` 加一(`client.go:4052-4061`);本轮盲读解析完后统一调 `flushClients(0)`(`client.go:1644`),对每个待 flush 连接扣减 `fsp`、刷新 `last`,再按时间预算直接 `flushOutbound` 或 `flushSignal` 交给 writeLoop(`client.go:1426-1456`)。writeLoop 侧等待时若 `fsp < maxFlushPending` 且 `pb` 不大,则提前醒来继续循环(`client.go:1395-1396`;常量 `client.go:114`)。整条管线是"读循环驱动、写循环落盘":一次 read 扇出 N 条消息给 M 个订阅者,至多产生 M 次 flush 信号,socket 写几乎总是聚合的。

## 5. PING/PONG 心跳

服务端为每个连接设 ping 定时器 `processPingTimer`(`client.go:5842`):默认间隔 2 分钟、最大未决 2 个(`const.go:120-123`)。三个关键行为:

- **懒惰探测**:若窗口内收到过对端数据或 PING,就推迟本轮 PING(`client.go:5873-5878`);但 ROUTER/GATEWAY/spoke LEAF 一律照发(`client.go:5868-5869`),且 cluster 可配独立间隔(`client.go:5857-5859`)。
- **超限即杀**:`c.ping.out+1 > maxPingsOut` 时发 `-ERR 'Stale Connection'` 并关连(`client.go:5886-5891`)。`sendPing` 里 `c.ping.out++`(`client.go:2713`),收到 PONG 清零并顺手算 RTT(`client.go:2820-2823`)。
- **内联应答**:解析器在 OP_PING 状态直接调 `processPing` → `sendPong`,PONG 只是 `enqueueProto("PONG\r\n")`(`client.go:2674-2679`、`client.go:2770`),连同 `lastIn` 更新(`client.go:2774`)共十几行,无定时器、无队列往返。

readLoop 的读缓冲随之自适应:满读(>=cap)时倍增到 64KB 上限,连续 2 次半读收缩到 64B 下限(`client.go:1656-1671`;常量 `client.go:110-113`)——"PING/PONG 连接保持 64B 小缓冲"就是注释里写明的收缩目标。

反向方向上,服务端也主动发 PING 测 RTT:

- 受 `maxNoRTTPingBeforeFirstPong`(2 秒,`client.go:121`)约束:首条 PONG 未回且连接未超 2 秒时不允许发(`client.go:2693-2708`);
- 投递路径上发现目标连接 `rtt == 0` 时顺手补一发(`client.go:3999-4001`);
- RTT 不只为监控:路由/叶子的 s2_auto 压缩档位按它选档(`client.go:2832-2845`、`client.go:2861-2869`)。

## 6. 权限违例与 -ERR 的连接关闭路径

`-ERR` 处理分两种。**客户端发来的 `-ERR`**(`MINUS_ERR_ARG`,`parser.go:1169-1190` → `processErr`,`client.go:2225-2244`):CLIENT/ROUTER/GATEWAY/JETSTREAM 记日志后直接 `closeConnection(ParseError)`,只有 LEAF 特殊(交给 leafProcessErr,不断连)。**服务端发出的 `-ERR`** 语义分级:协议错误(`parseErr`/max_control_line)必然关连;权限违例(pub/sub violation)只回错误不断连;鉴权违例(`authViolation`)必关连(`client.go:2554`),关闭状态码各不相同(Authentication/Authorization/MaxPayloadExceeded 等)。

### 6.1 UNSUB 与 auto-unsub 的两段式语义

`UNSUB <sid> [max_msgs]`:带 `max` 且已收条数未到时只设置 `sub.max`(`client.go:3553-3555`),否则立即注销(`client.go:3556-3558`)。`deliverMsg` 投递时递增 `sub.nm` 与 `max` 比较:恰好等于则"先投递本条、再自动退订";超过则退订并丢弃(`client.go:3866-3896`)。请求-应答中"只收一次"的语义由这两段实现,订阅方无需应用层确认,且 ROUTER 侧的远端回复订阅有独立清理路径(`client.go:3867-3870`)。

### 6.2 verbose 与 trace

CONNECT 声明 `verbose=true` 后,订阅/退订/发布各回一条 `+OK`(握手期 `client.go:2491-2493`,投递期 `client.go:4408-4410`);`sendOK` 同样只是常量入队(`client.go:2753-2760`)。协议级 trace 在每个 ARG 终点调用,如 PUB(`parser.go:450-452`)、SUB(`parser.go:684-686`);CONNECT 参数进 trace 前先经 `removeSecretsFromTrace` 把 pass/token/sig 脱敏(`parser.go:965-967`;`client.go:2253-2258`)。

## 7. 大 payload 与 watermark:慢消费者判定

出站采用**乐观记账 + 双水位**。`queueOutbound`(`client.go:2582`)先把数据劈块塞进 `out.nb`(net.Buffers,三级 sync.Pool:512B/4KB/64KB,`client.go:366-368`、`client.go:395-399`),累加 `out.pb`(`client.go:2589`):

```go
// server/client.go:2622-2626 —— 慢消费者:超出 pending 上限,直接踢
if c.kind == CLIENT && c.out.pb > c.out.mp {
    c.out.pb -= int64(len(data))
    atomic.AddInt64(&c.srv.slowConsumers, 1)
    ...
    c.Noticef("Slow Consumer Detected: MaxPending of %d Exceeded", c.out.mp)
    c.markConnAsClosed(SlowConsumerPendingBytes)
```

- 硬上限 `out.mp = opts.MaxPending`(默认 64MB,`const.go:102`,快照在 `client.go:758`)。超限只对 CLIENT 判死(路由/叶子宁可堆积),先回退 pb 再计数、关连(`client.go:2622-2637`)。
- 软水位 75%:超过 `out.mp/4*3` 时给慢连接造一个 `out.stc` stall 门闩(`client.go:2644-2646`)。此后向它投递的 fast producer 在 `deliverMsg` 里调用 `stalledWait` **原地小睡**(2ms/5ms,总量封顶 10ms,`client.go:3733-3771`;常量 `client.go:124-126`),用自己的读循环节奏反向限流生产者,避免 writer 雪崩式落后。

### 7.1 写超时策略:为什么踢的只有 CLIENT

writeLoop 落盘受 `out.wtp` 约束:CLIENT 默认 `Close`(写卡即断),ROUTER/LEAF/GATEWAY 默认 `Retry`(抖动重试而非拆链)(`client.go:740-757`);flush 死线 10 秒(`const.go:132`)。这与慢消费者判定只对 `c.kind == CLIENT` 生效(`client.go:2622`)互为表里:终端连接一踢了之,集群连接则靠重试与 PING 探活维持拓扑完整。

## 8. headers:HPUB/HMSG 的字节布局与解析

HPUB 参数行比 PUB 多一个 `hdr_size`:`HPUB <subject> [reply] <hdr_len> <total_len>\r\n`(`client.go:2882` 注释;解析 `client.go:2883-2927`)。入站态机多出 `OP_H→OP_HM→OP_HMS→OP_HMSG→HMSG_ARG` 一条支线(`parser.go:253-261`、`parser.go:330-400`),HMSG_ARG 在路由/网关上分派给 `processRoutedHeaderMsgArgs`、叶子上给 `processLeafHeaderMsgArgs`(`parser.go:376-386`)。

`hdr` 是**从 total 里切出的头部字节数**,payload 视图由 `msgParts` 用三索引切片 `data[:hdr:hdr], data[hdr:]` 给出(`client.go:2875-2880`),cap 限定保证追加不越界。头部本体是 `NATS/1.0 <status...>\r\n<key: value>\r\n\r\n` 风格的 MIME 块,仅在需要结构化访问时惰性解析(`parseState.getHeader`,`parser.go:1327-1339`)。

服务端主动产生 headers 的典型是 no_responders 503:无人订阅且发布者要求通知时,直接 `Sprintf` 一条 `HMSG <reply> <sid> <hdrLen> <hdrLen>\r\nNATS/1.0 503\r\nNats-Subject: ...\r\n\r\n\r\n` 入队(`client.go:4528-4538`)。向不支持 headers 的订阅者投递 HMSG 时自动降级为 MSG,尺寸改写为 `size-hdr`(`client.go:3674-3684`、`client.go:3721-3725`)。

## 9. 设计动机

1. **为什么文本协议仍能扛千万级 msg/s**:热路径(PUB)每字节只做一次 switch;参数拆分用栈上定长数组(`client.go:2961`),payload 完全不做状态机遍历(索引跳跃,`parser.go:462`);文本行短、无二进制封帧层,CPU 成本集中在"找 \r\n"和一次 memcpy 都省掉的下标运算。
2. **为什么零拷贝直接引 read buffer**:payload 和参数行生命周期止于本轮投递——`deliverMsg` 把入站 buffer 的 slice 直接塞进目标连接的 `out.nb`(`client.go:4011-4012`),从头到尾 publish 一次字节拷贝都没有;代价是跨读缓冲时必须 `clonePubArg`(`parser.go:1297`),这是用"罕见路径多拷一次"换"常见路径零拷贝"。
3. **为什么握手先发 INFO**:客户端需要 `max_payload/tls_required/auth_required/connect_urls` 才能决定后续行为(发多大的包、要不要 TLS、连哪个集群);服务端先说,客户端 CONNECT 才能带上正确的 `protocol/headers/no_responders` 协商位(`client.go:2368`、`client.go:2483-2490`)。同步直发(`sendProtoNow`)还避免了 writeLoop 与 TLS 升级的竞态(`server.go:3360-3363`)。
4. **为什么 PING/PONG 内联在状态机**:它们是最高频的控制指令,解析路径仅 3 个状态、应答只是常量字符串入队(`client.go:2678`);同时 PONG 顺带承担 RTT 测量(`client.go:2823`)与首连确认(firstPongSent 闸住服务端主动 PING,`client.go:2702-2707`),做成异步队列反而增加延迟与复杂度。
5. **为什么慢消费者直接踢而非背压**:服务器是扇出枢纽,一个 64MB pending 的连接会拖垮其 readLoop 关联的所有 fast producer(共享 PCD/stall 机制已经在 75% 水位做了短暂 backpressure,`client.go:2644`、`client.go:3959-3965`);到硬上限说明订阅端已死或恶意,踢掉并计数(`client.go:2628-2636`)是保护多数人的唯一选择,且判定是 O(1) 整数比较。
6. **为什么 -ERR 权限违例不断连、鉴权违例必断连**:pub/sub 违例是策略性问题,断连会让客户端风暴式重连;而鉴权失败意味着身份本身不可信,保持连接只会扩大攻击面(`client.go:2552-2554`)。
7. **为什么给 LEAF/ROUTER 把控制行上限放大 16 倍**:集群帧在标准行上叠了 origin/account/queue/reply 等字段,4096 不够;但单独的上限使 CLIENT 侧的内存耗尽攻击面(parser 出口处的 argBuf 检查,`parser.go:1208-1213`)不因集群需求而放宽(`parser.go:1276-1284`)。
8. **为什么一台状态机服务所有连接类型**:CLIENT/ROUTER/GATEWAY/LEAF 共享同一 `switch c.state`,仅在 ARG 终点按 `c.kind` 分派 process 函数(`parser.go:682-711`);语义演进(如 headers、A+/A-)只改一处分派点,且常量数组 `argsa`/栈上 split 避免了泛型化或接口分派的开销——简单性本身就是性能。

## 10. 写作素材清单(文件:行号,均经核对)

1. `server/parser.go:59-134` —— 77 个 parser 状态常量全集
2. `server/parser.go:25-36` —— parseState 与 scratch/argsa 预分配
3. `server/parser.go:435-468` —— PUB_ARG:零拷贝取 arg + payload 索引跳跃
4. `server/parser.go:469-543` —— MSG_PAYLOAD→MSG_END_N:msgBuf 零拷贝与 pa 重置
5. `server/parser.go:1196-1244` —— 跨读缓冲:scratch 复用与 msgBuf 分配策略
6. `server/parser.go:1274-1293` —— overMaxControlLineLimit(CLIENT vs 集群 16 倍)
7. `server/client.go:91-94` —— PING/PONG/-ERR/+OK 协议常量
8. `server/client.go:110-113` —— 读缓冲 512B/64B/64KB 自适应常量
9. `server/client.go:1465-1706` —— readLoop 全貌(盲读、parse、错误关连、缓冲伸缩)
10. `server/client.go:2293-2505` —— processConnect:鉴权、协议与 headers/no_responders 协商
11. `server/client.go:2762-2855` —— processPing/processPong(ConnectInfo 推送与 ping.out 清零)
12. `server/client.go:2959-3010` —— processPub:栈上 splitArgs 与 max_payload 校验
13. `server/client.go:3778-4050` —— deliverMsg 全链(echo/auto-unsub/header 降级/queueOutbound)
14. `server/client.go:5842-5900` —— processPingTimer:懒惰 PING 与 Stale Connection
15. `server/client.go:2582-2647` —— queueOutbound:三级 nbPool、慢消费者踢除、75% stall 门闩
16. `server/const.go:88-129` —— 4096 控制行/1MB payload/64MB pending/2min PING/2 max out/CR_LF
