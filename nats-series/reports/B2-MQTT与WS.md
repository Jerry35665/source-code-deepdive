# B2 协议前端:MQTT 与 WebSocket(NATS 深读·卷二)

基线:repos/nats-server @ 8f3f31b0366eca0d855d0750b7ca547eadd10eff。
卷一已确认:MQTT 与 WS 都不是独立 kind,而是 CLIENT 连接上的"扩展类型"。本文深入两套前端:
`server/mqtt.go`(6477 行)把 MQTT 语义翻译成 NATS+JetStream;`server/websocket.go`(1689 行)
只做传输层封装,帧内仍是原生 NATS 协议。MQTT 甚至可以跑在 WS 上(websocket.go:839-840,
`wsUpgrade` 按 URL 路径 `/mqtt`(mqtt.go:193)把 kind 判为 MQTT)。

## 0. 全景图

```
MQTT 前端(每个报文 → NATS 内部表示)
  client                     nats-server                              JetStream (按账户)
    |-- CONNECT -------------> mqttParseConnect (mqtt.go:3787)
    |     clientID/will/ka      mqttProcessConnect (4006) --恢复/新建会话--> $MQTT_sess (MaxMsgsPer=1)
    |<-------- CONNACK --------- sendConnAck (4196, session present)
    |-- SUBSCRIBE -------------> mqttFilterToNATSSubject (6173) '+'->'*', '#'->'>'
    |     pi, filters+QoS       mqttProcessSubs (2646)
    |                             QoS0: 直接 sub "foo.bar" + 回调 mqttDeliverMsgCbQoS0 (5389)
    |                             QoS1+: durable consumer(过滤 $MQTT.msgs.foo.bar)
    |                                   + sub "$MQTT.sub.<nuid>" 回调 mqttDeliverMsgCbQoS12 (5460)
    |<-------- SUBACK ---------- mqttEnqueueSubAck (6009) + retained 补发 (5995)
    |-- PUBLISH QoS0 ----------> mqttProcessPub (4456) --交付--> 常规 NATS 转发
    |-- PUBLISH QoS1 (pi) -----> 交付 + 异步存 $MQTT.msgs.<subj>,JS ack 后按序 PUBACK(mqttAckLoop 4570)
    |-- PUBLISH QoS2 (pi) -----> mqttStoreQoS2MsgOnce (4817): 存 $MQTT.qos2.<cid>.<pi>(去重)→ PUBREC
    |-- PUBREL (pi) -----------> mqttProcessPubRel (4848): 取出/删除暂存 → 真正投递 → PUBCOMP
    |-- PINGREQ ---------------> mqttEnqueuePingResp (6140)

WebSocket 前端(握手 → 帧 → 原生协议复用)
  browser/lib                 wsUpgrade (websocket.go:833)
    |-- GET /  Upgrade: websocket ---> rfc6455 校验(853-880)+ origin(883) + 压缩协商(890)
    |<-- 101 + Sec-WebSocket-Accept -- SHA1(key+GUID)(110-119);hijack 后交给 createWSClient (1401)
    |-- bin帧 [NATS CONNECT] -------> wsReadLoop (282) 逐帧解头/去掩码 → c.parse(b) (278)
    |<-- bin帧 [NATS INFO/MSG/PING] - writeLoop → wsCollapsePtoNB (1495) 把出站缓冲打成 binary 帧
    (帧内字节流与普通 TCP 上的 NATS 协议完全一致;压缩帧先 flate 解压再喂同一 parser,462-521)
```

## 1. MQTT:报文解析与状态分发

MQTT 复用 CLIENT 的 readLoop:client.go:1479 为 MQTT 连接挂上 `mqttReader`,client.go:1579 的
`c.parse()` 在 parser.go:140-141 被分流到 `c.mqttParse(buf)`——不再走 NATS 文本解析器。
`mqttParse`(mqtt.go:766-996)是唯一入口:第一个报文必须是 CONNECT(805-815,若发现
"GET " 前缀还提示连错了端口,810),之后按 fixed header 的类型字节分发到 PUBLISH/PUBACK/
PUBREC/PUBREL/PUBCOMP/SUBSCRIBE/UNSUBSCRIBE/PINGREQ/CONNECT(二次 CONNECT 报错,941-943)/
DISCONNECT。DISCONNECT 丢弃遗嘱(977-983,Spec [MQTT-3.1.2-8])并走正常关闭。

keep alive:CONNECT 里的 KeepAlive × 1.5 变成 `cp.rd`(mqtt.go:3860-3868);实现不是服务端
主动踢,而是给 socket 设读超时——每轮解析完把 deadline 重置为 `now+rd`(mqtt.go:992-994),
解析前先清掉(776-778)。服务端"绝不"给 MQTT 客户端发 NATS PING:createMQTTClient 注释
"No Ping timer for MQTT clients..."(mqtt.go:668),RTT 探测也被禁用(client.go:2694-2697)。
PINGREQ 的应答只有 2 字节,常量直接写死(mqtt.go:216, 6140-6144)。

## 2. QoS 0/1/2:三套完全不同的机制

**QoS0(fire and forget)**:`mqttProcessPub` 直接 `mqttInitiateMsgDelivery`(mqtt.go:4469-4470),
把报文重新编码成带内部头的 NATS 消息(`Nmqtt-Pub:<qos>`,mqtt.go:4391-4428)后调用
`processInboundClientMsg`(4779)——即与 NATS 客户端同一条发布管线,零持久化。

**QoS1(至少一次)**:交付后还要把消息异步存进 `$MQTT.msgs.<subject>` 流(mqtt.go:4802-4807,
流本身 InterestPolicy 保留,1440),存成功才回 PUBACK。PUBACK 由每连接的 `mqttAckPipeline`
按收包顺序发出(4528-4532):`mqttAckLoop`(4570-4623)逐个等 JS ack,失败或超时直接断连,
让客户端重发。窗口 `mqttMaxAcksInFlight=1024`(4512),满了会让 readLoop 阻塞反压客户端
(4700-4731)。权限违规被丢弃的消息也必须补 PUBACK(4521-4526, 4780-4787)。
出方向(订阅侧):JS durable consumer 投递到 `$MQTT.sub.<nuid>`,回调 `mqttDeliverMsgCbQoS12`
把 JS 流序列号映射为 MQTT packet id(`trackPublish`,3611-3683:cpending[jsDur][sseq]=pi 保证
JS 重投不换 pi,而是置 DUP),未确认的 pi 计入 `pendingPublish`,超过会话 maxp 就先不投,
等 JS AckWatch 重投(mqtt.go:3653-3659)。客户端 PUBACK → `untrackPublish`+向 JS ack
(5182-5214)。AckWait 默认 30s(mqtt.go:147)。

```go
// server/mqtt.go:4468-4496(节选)
switch qos {
case 0:
    return s.mqttInitiateMsgDelivery(c, pp)
case 1:
    // ... The PUBACK is emitted by the pipeline once JetStream acks the
    // store, in the order the PUBLISH packets were received.
    return s.mqttInitiateMsgDelivery(c, pp)
case 2:
    // [MQTT-4.3.3-2]. Method A, Store message, send PUBREC.
    err := s.mqttStoreQoS2MsgOnce(c, pp)
    if err == nil {
        c.mqttEnqueuePubResponse(mqttPacketPubRec, pp.pi, trace)
    }
    return err
}
```

**QoS2(exactly once)**:入库暂存与投递分离。inbound 状态机:
`PUBLISH(qos2,pi)` → `mqttStoreQoS2MsgOnce`(4817-4838)把消息(带 `Nmqtt-Subject` 头,encodePP
=TRUE)存入 `$MQTT_qos2in` 流的 `$MQTT.qos2.<cid>.<pi>` 主题;该流 MaxMsgsPer=1 + DiscardNewPer
(1455-1464),同一 (cid,pi) 重发会撞 `ErrMaxMsgsPerSubject`,以此实现按 pi 去重;然后回 PUBREC。
`PUBREL(pi)` → `mqttProcessPubRel`(4848-4885):按 pi 取回暂存消息、删除、此时才真正投递,
最后 PUBCOMP。outbound(服务端作为发送方):PUBREC → `trackAsPubRel`(3714-3748)并把 PUBREL
封装成消息存入 `$MQTT_out` 流(5203-5210),由会话级 durable(PUBREL 专用,5823-5835)投递、
`mqttDeliverPubRelCb`(5540-5567)补发 PUBREL,直到 PUBCOMP 确认(5226-5243)。即:exactly-once
的"状态机"不在内存里,而是三个 JS 流(qos2in/out/msgs)+ 会话内两张 pi 映射表
(`pendingPublish`/`pendingPubRel`,mqtt.go:332-341)合成的可恢复状态;pi 分配由 `bumpPI`
扫 0xFFFF 环(3540-3561),释放后不复用刚释放的 id 以免客户端误判 DUP(3696-3698)。
运维可用 `reject_qos2_pub`/`downgrade_qos2_sub`(经 `mqtt.rejectQoS2Pub`/`downgradeQoS2Sub`,
mqtt.go:417-423, 576-579)直接关掉或降级 QoS2。

## 3. 会话与持久化

会话按 (account, clientID) 组织:`mqttAccountSessionManager`(mqtt.go:266-277)持 sessions/
sessByHash/sessLocked/flappers 五张表。CONNECT 时 `mqttProcessConnect`(4006-4194):
1) 先做认证(4018-4024,失败回 CONNACK rc=5,client.go:2548-2549);2) 用 sessLocked 串行化
同 ID 的并发连接(4075-4082,重试 10 次失败新客户端);3) 会话存在且任一方要求 clean 就
`clear()`(4118-4127;clean=false 时 CONNACK 置 session present,4129-4131);4) 同 ID 抢占:
旧客户端被踢并进 flappers 监狱(4144-4156,监狱 1s,mqtt.go:184);5) 总是 `save()` 一次以便
集群感知(4169-4172)。

持久化载体是账户级 `$MQTT_sess` 流(MaxMsgsPer=1,FileStorage,1417-1424),键为
`$MQTT.sess.<domain.><clientID 哈希>`,值为 JSON `mqttPersistedSession`
{clean, subs, cons, pubRel}(mqtt.go:353-360);save 时带 `JSExpectedLastSubjSeq` 乐观锁
(3419-3431)。恢复走 `createOrRestoreSession`(3156-3194):内存没有就去流里按哈希取,
记录里 ID 不匹配报 session collision(3176-3178)。订阅恢复:CONNECT 后把持久化的 filters
重放 `processSubs`(4184-4192);SUBSCRIBE/UNSUBSCRIBE 变更经 `update`→`save` 落盘
(3511-3538)。clean session 断开时删 durable、删会话记录(3451-3504);持久会话只解绑客户端
(1074-1087)。跨节点同 ID 连接由 `processSessionPersist`(2213-2272)监听其它节点的 SP 回复,
发现 seq 更新即踢本地连接并关进 flappers(2261-2270)。空 clientID 仅允许 clean session,
否则拒绝;空 ID 现场发 NUID(mqtt.go:3878-3885)。

## 4. Retained:独立流 + 内存索引/缓存

retain 池:账户级 `$MQTT_rmsgs` 流,主题按消息逐个展开为 `$MQTT.rmsgs.<subject>`,
MaxMsgsPer=1(FileStorage、LimitsPolicy,1496-1504)——"每主题最后一条"由流语义天然保证,
覆盖即新消息、空 payload 即删除标记。写入点在发布权限检查之后的钩子
`mqttHandlePubRetain`(client.go:4413-4415 → mqtt.go:4892-4989):空 payload 不就地删除,
而是存一条空体消息,靠 `processRetainedMsg`(2150-2186)在各节点回放时一致地删本地索引
(4919-4928 的注释解释了这如何免去跨节点删除通知)。内存侧是两层:`retmsgs`
(stree 主题树,只存 sseq,2455-2474)+ TTL 2 分钟的 `rmsCache`(mqtt.go:197, 3334-3371)。
新订阅时先 `addRetainedSubjectsForSubject` 收集匹配主题、`loadRetainedMessages` 从流回读
(2691-2704),再序列化进 sub.mqtt.prm,订阅注册成功后由 `mqttSendRetainedMsgsToNewSubs`
入队(5995-6007)。权限与 retained 的交叉:配置 reload 后 `mqttCheckPubRetainedPerms`
(4997-5083)按消息里记录的 Source 用户名重查发布权限,不再允许的 retained 会被清掉。
Sparkplug B 的 NBIRTH/DEATH 语义也被特判(4895-4909, 5254+)。

## 5. 主题映射:MQTT 通配符 → NATS token

核心是 `mqttToNATSSubjectConversion`(mqtt.go:6194-6273):`/`→`.`(层级对齐);为支持空层级,
行首 `/` 变 `/.`、行尾或连续 `/` 变 `./`(foo//bar → foo./.bar,6185-6188);NATS 的 `.` 在
MQTT 侧转义为 `//`(6241-6246),反向转换在 6282-6311。限制:
- PUBLISH 主题禁通配符(`wcOk=false`,6247-6252,Spec [MQTT-3.3.2-2]);
- 空白字符一律拒绝——会破坏 NATS 线上协议的控制行(6229-6234);0x7f 会破坏 stree 索引,
  同样拒绝(6235-6240);
- `#` 的 NATS 语义(`foo.>` 不匹配 foo 本身)与 MQTT 不同,所以 `foo.#` 会额外注册一个
  上一级订阅 `foo`,sid 加后缀 " fwc"(mqtt.go:107, 2651-2661, 2768-2782);
- Spec [MQTT-4.7.2-1]:通配符过滤器不匹配 `$` 开头主题——`#`/`*`/`*.` 开头的订阅标 reserved,
  回调里对 `$` 主题跳过(mqtt.go:5574-5592, 5400-5406);
- `$MQTT.` 内部前缀禁止 MQTT 客户端直接订阅,否则可绕过订阅权限(2675-2681);
- 主题映射(mappings)在 PUBLISH/will 解析时经 `selectMappedSubject` 应用,且会反向重写
  MQTT topic(3919-3933, 4280-4294);映射改主题时 QoS 消息会在新主题下补存一份
  (client.go:5024-5025 → mqtt.go:1145-1158)。

## 6. 遗嘱(will)

CONNECT 里解析 will 的 topic/message/QoS/retain 并转成 NATS 主题(mqtt.go:3895-3941;
QoS2 will 可被配置拒收,3846-3848)。will 挂在 `c.mqtt.cp.will` 上,唯一触发点是连接关闭
路径 `mqttHandleClosedClient` → `mqttHandleWill`(4210-4237):把 will 合成一条
`mqttPublish`(带 QoS/retain 标志)走标准 `mqttInitiateMsgDelivery`,即遗嘱也享受完整
QoS/retained/映射管线。两条路不触发:DISCONNECT 正常断开(977-983 先清 will)、被同 ID
客户端挤掉线(4144-4148 先清旧客户端的 will)。

## 7. TLS 与认证

MQTT 监听口支持 TLS:`tlsRequired = opts.MQTT.TLSConfig != nil && ws == nil`(mqtt.go:620),
配 `allow_non_tls` 时嗅探首字节 0x16 判断(633-644),证书映射/pinned certs 同普通 TLS
(653)。认证:`mqttConfigAuth` 只要在 mqtt 段配了 username/token/no_auth_user 就置
authOverride(690-694);CONNECT 报文里的 username 直接进 `c.opts.Username`,password 复制给
`c.opts.Token`(3943-3963)——即同时支持 users/nkeys 静态认证与 JWT/operator 模式(token 当
JWT 用),最终统一走 `s.isClientAuthorized`(4018)。选项校验强制:集群/网关模式必须显式
server name(705-707),纯单机必须开 JetStream(734-737)——MQTT 的 QoS/会话/retained 全部
押在 JS 上,不是可选项。JWT 连接类型细分 `ConnectionTypeMqtt`/`ConnectionTypeMqttWS`
(client.go:6880-6891)。

```go
// server/mqtt.go:3859-3868(节选)
// Keep alive
var ka uint16
ka, err = r.readUint16("keep alive")
if err != nil {
    return 0, nil, err
}
// Spec [MQTT-3.1.2-24]
if ka > 0 {
    cp.rd = time.Duration(float64(ka)*1.5) * time.Second
}
```

## 8. WebSocket:握手升级

`wsUpgrade`(websocket.go:833-985)按 rfc6455 逐点校验:GET、Host、Upgrade/Connection 头、
16 字节 `Sec-WebSocket-Key`、version 13(853-880);origin 检查(883-885);随后 http.Hijacker
接管连接,手写 101 响应:`Sec-WebSocket-Accept = base64(SHA1(key+GUID))`(110-119, 918-920),
可选拼 `permessage-deflate; server_no_context_takeover; client_no_context_takeover`
(92-96, 921-923)、`Nats-No-Masking: true`(88-91, 924-926)、MQTT-over-WS 时加
`Sec-Websocket-Protocol: mqtt`(97-99, 927-929)以及配置的自定义响应头(930-932)。
kind 由路径决定:`/leafnode`→LEAF、`/mqtt`→MQTT、其余 CLIENT(834-842)。
选项校验强制 TLS(除非 `no_tls`,1144-1147),启动时无 TLS 会直接警告不要上生产
(1318-1320);原因注释写明:浏览器场景要在握手头里带 JWT,防窃听(1286-1289)。

## 9. WebSocket:帧解析与原生协议复用

读路径:`readLoop` 对 WS 客户端改走 `wsReadAndParse`(client.go:1559-1572)。

```go
// server/websocket.go:267-279(节选)
return c.wsReadLoop(r, ior, buf, func(b []byte, compressed, final bool) error {
    if compressed {
        if err := c.wsDecompressAndParse(r, b, final, mpay); err != nil {
            r.resetCompressedState()
            return err
        }
        if final {
            r.fc = false
        }
        return nil
    }
    return c.parse(b)
})
```

`wsReadLoop`
(websocket.go:282-407)手工解析帧:opcode 校验、RSV2/RSV3 必须为 0(295-297)、未协商压缩却
带 RSV1 报协议错(298-300)、客户端必须掩码(311-313,LEAF 除外)、控制帧 ≤125 字节且不可
分片/压缩(318-330)、126/127 两种长度扩展(347-362);PING→PONG、CLOSE→回显+io.EOF 触发
优雅关闭(526-593);消息分片由 wsReadInfo.ff/fc 状态机拼装。普通帧的 payload 直接
`c.parse(b)`(278)——即 NATS 原生协议解析器;压缩帧则攒齐分片后追加 deflate 尾块
`{0x00,0x00,0xff,0xff,0x01,0x00,0x00,0xff}` 用 flate 解压再 `c.parse`(103, 462-521),
消息总大小受 `max_payload×8`(上限 64MB)约束(64-65, 203-212)。

写路径:writeLoop 把出站缓冲交给 `wsCollapsePtoNB`(1495-1681)统一打帧:一律 binary 帧
(1576, 1587, 1662);开启压缩时整批 flate 压缩后去尾 4 字节(1564)、小于 64 字节不压
(63, 1512);浏览器连接强制 4096 字节分帧(62, 1499-1501),Safari(Version/+Safari/ UA)
额外禁止压缩帧分片(959-967, 1521-1523);服务端出方向默认不掩码,除非客户端协商
no-masking 失败(945)。

关闭码映射:`wsEnqueueCloseMessage` 把 NATS 的 ClosedState 翻成 1000/1008/1002/1009/1001/
1011 等(755-781),协议错误现场回 CLOSE(787-792)。

## 10. origin 校验与 cookie 认证

`checkOrigin`(1049-1110):既配 `same_origin` 又配 `allowed_origins` 时两者都查;请求无
Origin 头直接放行(1063-1068,引用 rfc6455:非浏览器客户端 origin 无意义)。origin 比较
scheme/host/port,缺省端口按 80/443 补全(1112-1127)。allowed_origins 在启动/reload 时解析进
host→[{scheme,port}] 映射(1211-1236),合法性校验在 1148-1163。

cookie 认证:升级阶段按配置的 cookie 名抓取 JWT/username/password/token 四个值存进
`websocket` 结构(969-982, 124-140);真正生效在处理 NATS CONNECT 时:CONNECT 里没带对应
字段才用 cookie 值兜底(client.go:2341-2359)。`jwt_cookie` 要求配了 trusted operators/keys
(1181-1185)。cookie 只是把凭据从 CONNECT 挪进握手头,认证模型与普通 CLIENT 完全一致。
另有 `no_masking` 自定义头与 `X-Forwarded-For` 客户端 IP 透传(88-91, 947-955)。

## 11. 浏览器场景的能力边界

WS 客户端就是普通 NATS 客户端:createWSClient 发完整 INFO(1443)、设 ping timer(1485)、
支持 CONNECT 协议协商。差异点:
- headers 协商:`c.headers = supportsHeaders && c.opts.Headers`(client.go:2368)——老浏览器
  代理会吃掉大写头,客户端必须显式声明 `headers:true`;`no_responders` 依赖 headers,
  二者不匹配直接断连并报 `ErrNoRespondersRequiresHeaders`(client.go:2481-2489);
- 掩码:浏览器(及所有 WS 客户端)入方向必须掩码,服务端逐帧异或解掩码(596-623),
  这是 WS 相对裸 TCP 的固定 CPU/带宽税;
- 分帧/压缩策略对 Safari 等做了特判(见 §9);
- `X-Forwarded-For` 需要显式信任代理头,取第一个合法 IP(947-955)。

## 12. 共通:CLIENT 扩展类型、权限模型与统计

- 类型判定:`client.kind==CLIENT` 不变,MQTT 看 `c.mqtt != nil`、WS 看 `c.ws != nil`
  (mqtt.go:750-752;websocket.go:239-241);`clientType()` 返回 NATS/WS/MQTT
  (client.go:615-627),Connz 的 Type 字段即 `nats/websocket/mqtt`(client.go:629-634;
  monitor.go:586)。MQTT-over-WS 同时设两个标志,类型归 MQTT。
- 权限模型:发布/订阅都复用 CLIENT 的 perms;仅对内部主题豁免——MQTT 客户端对
  `$MQTT.sub.*`/`$MQTT.deliver.pubrel.*` 隐式放行(仍查 deny),非 CLIENT 连接对整个
  `$MQTT.` 前缀放行(client.go:3384-3389 订阅、4222-4226 发布),配合 mqtt.go:2675-2681
  的入口封禁形成闭环;QoS 投递回调里还按订阅原 filter 复查 deny(5516-5524)。
- 统计:WS/MQTT 都是 CLIENT,进出字节计入 `s.inClientMsgs/inClientBytes` 等总账户/服务器
  计数(client.go:1616-1641),但 MQTT 无 NATS 意义上的 ping/RTT;varz 分别有
  `mqtt`/`websocket` 配置段(monitor.go:1711, 1257)。
- 接线:`startMQTT`(mqtt.go:525-560)与 `startWebsocketServer`(websocket.go:1265-1384)
  并列于 server 启动;WS 的 mux 内再分发 createWSClient/createMQTTClient/createLeafNode
  (1337-1359)。

## 13. 设计动机(编者按)

1. **为什么内嵌 MQTT 而非独立 broker**:MQTT 需要 QoS1/2、持久会话、retained、集群内同 ID
   互踢——这些恰好是 JetStream 流 + 按键 MaxMsgsPer + 集群复制已有的能力。于是 MQTT 前端
   只做"协议翻译",把状态全部外包给按账户惰性创建的 5 个流(mqtt.go:1413-1605),单机模式
   干脆强制开 JS(734-737)。换来的是:MQTT 消息天然能被 NATS 客户端消费(就存在
   `$MQTT.msgs.*`),反之 NATS 发布也能喂给 MQTT 订阅者(QoS0 回调 5431-5448),一个集群
   两种协议。
2. **为什么 QoS2 难做、这里做成了什么样**:exactly-once 要求"同一 pi 只投一次"跨重连、
   跨节点成立。本地内存状态做不到(节点会宕),本实现把每个状态跃迁都变成 JS 流上的一条
   记录:qos2in 的 (cid,pi) 去重、out 的 PUBREL 投递、msgs 的正式消息,三段式
   Store→PubRec→PubRel→Deliver→PubComp;`sseq↔pi` 映射(cpending)保证 JS 重投时 pi 稳定
   只置 DUP。代价是每条 QoS2 消息至少 3 次 JS 写,所以又提供 `reject_qos2_pub` 逃生门——
   作者显然清楚这是"正确但贵"。
3. **为什么 QoS1 用 PUBACK 流水线**:若等 JS ack 再回 PUBACK,客户端吞吐被 RTT 卡死;
   若先回 PUBACK,存储失败就丢消息。折中:异步存、按收包顺序发 PUBACK
   (mqtt.go:4528-4532),窗口 1024 反压,失败断连让客户端按 spec 重发
   (4475-4479 引 [MQTT-4.3.2-2]"收到 PUBACK 即转移所有权")。
4. **为什么 WS 复用原生协议**:WS 只是传输,帧内字节流与 TCP 完全一致(wsReadAndParse 直调
   c.parse,278),于是 NATS 客户端库只需换一个 dialer;INFO/PING/headers/no_responders
   协议协商原样可用。成本集中在两处:入方向解掩码、出方向打帧(浏览器 4096 限帧)与
   permessage-deflate 的编解码,全部封在 websocket.go 内,parser 零改动。
5. **为什么 retained 独立存储($MQTT_rmsgs)而非复用消息流**:retained 的语义是"每主题一条、
   永久保留",与 $MQTT_msgs 的 InterestPolicy(无订阅即删)正交;单独的流 + MaxMsgsPer=1
   让"覆盖/删除"变成一次 pub,跨节点一致性由流复制保证,本地只需 sseq 索引 + TTL 缓存。
   旧版"单一主题 + 逐条迁移"的兼容代码(transferRetainedToPerKeySubjectStream,3277-3332)
   反证了这个设计是迭代出来的。
6. **为什么 WS 默认关、且强制 TLS**:浏览器是唯一动机,但也是攻击面(CSRF/origin 伪造/
   凭据泄露)。默认关闭、开了就必须给 TLS 或显式 no_tls(1144-1147)、origin 白名单 +
   same_origin、JWT 走 cookie 时强制 trusted keys——整套约束都在说"别在生产裸奔"
   (1318-1320 的警告直接印在日志里)。
7. **为什么 MQTT 的 keep alive 用读超时而不是定时器**:MQTT 规范只要求"1.5 倍窗口内没收到
   任何报文就断开",读超时正好表达"有任何入站流量即续命",顺带省掉 per-connection 定时器;
   服务端也无需主动 PING(668)。

## 14. 写作素材清单(文件:行号,均已核对)

1. server/mqtt.go:42-58 —— MQTT 报文类型/标志常量,一屏看懂 wire format
2. server/mqtt.go:110-141 —— $MQTT.* 内部主题与 5 个流名总表
3. server/mqtt.go:310-351 —— mqttSession 结构:pendingPublish/pendingPubRel/cpending 三表
4. server/mqtt.go:490-516 —— Nmqtt-* 内部头定义(QoS/retained 元数据跨节点契约)
5. server/mqtt.go:566-682 —— createMQTTClient:headers=true、echo、无 ping、TLS 探测
6. server/mqtt.go:1413-1486 —— 会话/消息/qos2/out 四个流的创建参数(保留策略对比)
7. server/mqtt.go:3611-3683 —— trackPublish:sseq→pi 映射与 DUP 判定(QoS1/2 出向核心)
8. server/mqtt.go:4456-4501 —— mqttProcessPub:QoS 0/1/2 三岔口
9. server/mqtt.go:4570-4623 —— mqttAckLoop:按序 PUBACK、失败断连
10. server/mqtt.go:4817-4885 —— QoS2 去重入库 + PUBREL 取出投递(exactly-once 状态机)
11. server/mqtt.go:4006-4194 —— mqttProcessConnect:flappers/sessLocked/session present/踢人
12. server/mqtt.go:6194-6273 —— 主题转换规则('/'↔'.','.'→'//',空白/0x7f 拒绝)
13. server/websocket.go:833-985 —— wsUpgrade:rfc6455 校验、101 手写、压缩/no-masking 协商
14. server/websocket.go:282-407 —— wsReadLoop 帧状态机(掩码/分片/控制帧)
15. server/websocket.go:1495-1681 —— wsCollapsePtoNB:出站打帧、flate、浏览器 4096 限帧
16. server/client.go:3384-3389, 4222-4226 —— MQTT 内部主题的权限豁免(仍受 deny 约束)

(2026-09-18,基于 commit 8f3f31b;所有行号以该检出为准。)
