# 第 08 章 · 协议前端:MQTT 与 WebSocket(卷二)

> 基线:commit `8f3f31b0`。核心:server/mqtt.go(6477 行)与 server/websocket.go(1689 行)。两者都是 CLIENT 的扩展类型:MQTT 换掉整个 parser;WS 帧内就是原生 NATS 协议。

## 8.0 全景:两套前端的翻译深度

```
MQTT:mqttParse 替换 c.parse,每个报文翻译成 NATS 内部表示
  CONNECT→会话($MQTT_sess 流) SUBSCRIBE→'+'→'*'、'#'→'>'
  PUBLISH QoS0 直投;QoS1 异步存 $MQTT.msgs.* 按序 PUBACK;
  QoS2 三流状态机(qos2in 去重/msgs 正式/$MQTT_out PUBREL)——状态全押 JetStream
WS:rfc6455 握手→逐帧解头/去掩码→帧内字节流直调 c.parse(原生协议零改动)
  出站 writeLoop 把缓冲打成 binary 帧(浏览器 4096 限帧,permessage-deflate 可选)
```

## 8.1 MQTT:QoS 三套机制

- **QoS0**:直接走与 NATS 客户端相同的发布管线,零持久化;
- **QoS1**:交付后异步存 `$MQTT.msgs.<subject>` 流(InterestPolicy),JS ack 后由每连接 mqttAckLoop **按收包顺序**发 PUBACK(窗口 1024 反压;失败断连让客户端按 spec 重发)——若等 JS ack 再回 PUBACK,吞吐被 RTT 卡死;先回则存储失败丢消息,折中即此;
- **QoS2**:入库暂存与投递分离——PUBLISH 存 `$MQTT_qos2in` 流的 `$MQTT.qos2.<cid>.<pi>`(MaxMsgsPer=1 按 pi 去重)→PUBREC;PUBREL 才取出投递→PUBCOMP。**exactly-once 的状态机不在内存里,而是三个 JS 流+两张 pi 映射表合成的可恢复状态**;代价是每条 QoS2 至少 3 次 JS 写——提供 reject_qos2_pub 逃生门,作者显然清楚这是"正确但贵"。

## 8.2 会话与 retained

会话按 (account, clientID):持久化在账户级 `$MQTT_sess` 流(MaxMsgsPer=1,JSON+乐观锁),恢复重放订阅;同 ID 并发连接经 sessLocked 串行化,抢占进 flappers 监狱(1s);跨节点由 processSessionPersist 监听其他节点的会话回复,seq 更新即踢本地。retained 在 `$MQTT_rmsgs` 流(每主题一条 MaxMsgsPer=1,"每主题最后一条"由流语义天然保证;空 payload 即删除标记,靠各节点回放一致地删索引);内存侧 stree 树只存 sseq+2 分钟 TTL 缓存。**为什么 retained 独立成流**:其语义"每主题一条永久保留"与消息流的 InterestPolicy 正交。

## 8.3 主题映射与遗嘱

`/`↔`.` 层级对齐;空层级支持(行首 `/` 变 `/.`);NATS 的 `.` 在 MQTT 侧转义为 `//`;`#` 因 NATS 语义(fwc 不匹配本身)会额外注册上一级订阅;`$` 前缀对通配保留(Spec);$MQTT. 内部前缀禁止直接订阅(防绕过权限);空白/0x7f 直接拒绝。遗嘱(will)挂连接上,唯一触发点是关闭路径,合成 PUBLISH 走完整 QoS/retained/映射管线;DISCONNECT 正常断开与被挤掉线两条路不触发。keep alive=1.5×读超时——**服务端绝不给 MQTT 客户端发 NATS PING**,读超时正好表达"有入站流量即续命"。

## 8.4 WebSocket

握手按 rfc6455 逐点校验+手写 101(SHA1(key+GUID));kind 由路径决定(/leafnode→LEAF、/mqtt→MQTT、其余 CLIENT)。帧内字节流与 TCP 上的 NATS 协议完全一致——**NATS 客户端库只需换一个 dialer**,INFO/PING/headers/no_responders 协商原样可用;成本集中在入方向解掩码与出站打帧(permessage-deflate 可选,Safari 禁压缩分片)。浏览器能力边界:no_responders 依赖 headers 协商,不匹配即断连。cookie 认证把凭据从 CONNECT 挪进握手头(JWT/user/pass/token 四种兜底)。默认关闭且强制 TLS——浏览器是唯一动机也是攻击面,"别在生产裸奔"直接印在日志里。

## 8.5 设计动机

1. **内嵌 MQTT=JS 外包状态**:QoS/会话/retained/同 ID 互踢恰是 JS 流+MaxMsgsPer+集群复制已有的能力;MQTT 消息天然可被 NATS 客户端消费,反之亦然——一个集群两种协议;
2. **QoS2 正确但贵**:每个状态跃迁变成 JS 流上的记录,跨重连跨节点成立;逃生门留给运营;
3. **QoS1 PUBACK 流水线**:异步存+按序回,窗口反压;
4. **WS 复用原生协议**:帧内字节流一致,parser 零改动;
5. **retained 独立流**:与消息流保留策略正交,覆盖/删除变成一次 pub,一致性由流复制保证。

## 8.6 FAQ

**Q1:MQTT 的状态存在哪?**
JetStream:$MQTT_sess(会话)/$MQTT.msgs.*(QoS1)/$MQTT.qos2in+out(QoS2)/$MQTT_rmsgs(retained)——按账户惰性创建的 5 个流。

**Q2:QoS2 为什么贵?**
每条消息至少 3 次 JS 写(qos2in 入库/msgs 正式/out PUBREL);可 reject_qos2_pub 关闭。

**Q3:MQTT 客户端会被 NATS PING 吗?**
不会:keep alive 用 socket 读超时实现(1.5×),服务端零定时器。

**Q4:retained 删除怎么同步多节点?**
空 payload 存一条消息,各节点回放时一致删本地索引——免去跨节点删除通知。

**Q5:`foo/#` 在 NATS 侧怎么订阅?**
`foo.>`+额外注册 `foo`(fwc 语义差异),sid 加 " fwc" 后缀。

**Q6:MQTT 能用 JWT 吗?**
能:CONNECT 的 password 字段当 JWT 用,走统一 isClientAuthorized。

**Q7:WS 上能用 no_responders 吗?**
客户端必须显式声明 headers:true;不匹配直接断连。

**Q8:WS 需要掩码吗?**
入方向必须(浏览器强制),服务端逐帧异或解掩码;出方向默认不掩码(可协商)。

**Q9:纯单机能跑 MQTT 吗?**
不能:必须开 JetStream——QoS/会话/retained 全押在 JS 上。

**Q10:同 clientID 抢占会触发遗嘱吗?**
不会:被挤掉线先清旧客户端的 will。

## 8.7 小结与深挖方向

本章结论:**协议前端="MQTT 把状态外包给 JS 五流+WS 只是换 dialer;一个集群两种协议"**。深挖:

1. trackPublish 的 sseq↔pi 映射与 DUP 判定(mqtt.go:3611-3683);
2. flappers 监狱与跨节点同 ID 互踢;
3. Sparkplug B 的 NBIRTH/DEATH 特判;
4. permessage-deflate 的出站 flate 与浏览器 4096 限帧;
5. mqtt.checkPubRetainedPerms 的 reload 权限回收。
