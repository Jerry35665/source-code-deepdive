# 第 07 章 · LeafNode:分布式部署的信任边界(卷二)

> 基线:commit `8f3f31b0`。核心:server/leafnode.go(3825 行)。纠偏:源码无 "SPEB";leaf 链路线上元素就是 INFO/CONNECT/LS±/LMSG,角色由 CONNECT 的 is_hub 协商。

## 7.0 全景:hub-spoke 与运行期角色

```
spoke(edge,主动外连)                      hub(中心,accept)
  本地账号"edgeA" ── outbound ──────────→ hub 账号"hubA"(hub 侧认证)
      ← inbound(INFO 带 Import/Export 权限反转+RemoteAccount)─
线上:INFO→CONNECT{is_hub,cluster,domain,remote_account}→LS+ <subj> [queue weight]/LS- →LMSG
环路探测:每账号 $LDS.<nuid>,LS+ 从对面回来即断链+30s 退避;集群级靠 sub.origin 标记+集群名校验
```

**hub/spoke 不是部署形态而是每条连接的运行期角色**(判定矩阵 leafnode.go:123-143):同一台服务器可只做 hub、也可同时持有 outbound 与 inbound leaf 连接。LeafNode 是 NATS 唯一"账号可重映射"的边界——spoke 侧本地账号与 hub 侧账号的映射只在这条连接上生效;edge 可自由演进本地账号体系而不惊动中心。

## 7.1 连接管理与兴趣传播

outbound 常驻循环:URL 洗牌+轮转、抖动退避(delay=Interval+rand)、HTTP CONNECT 代理、WS 隧道;四种惩罚退避(环路/权限/同名集群 30s、版本低 5s)。hub 集群每个节点的地址经 route 建立时汇入 LeafNodeURLs 并异步 INFO 广播——spoke 自动学习换节点(hub 单点宕机自愈)。**兴趣传播**:LS+/LS- 不带账号字段(账号语境由连接决定,与 route 的 RS+ 按账号分桶完全不同);smap 计数过零才发协议(队列订阅恒发,权重 qw 直接当 delta)。spoke 只传播 CLIENT/SYSTEM/JETSTREAM/ACCOUNT 及 hub 角色 leaf 的兴趣,不二次外传其他 spoke 的;isolated 配置完全阻断 leaf 间互通。恢复=**全量重放**(initLeafNodeSmapAndSendSubs 快照成一批 LS+)——状态一次快照收敛,简单且幂等。

## 7.2 权限 Gate:hub 声明、spoke 执行

hub 把 accept 认证得到的用户权限**反向翻译**(pub/sub 字段对调,"data is flowing in the opposite direction")下发 INFO;spoke 用它做三件事:限制快照与出站 LS+、限制入站消息、通配订阅宽松匹配。上行方向 hub 用连接的 Export 权限逐条检查,leafSendAllowed 刻意读连接 opts 而非运行时 perms——以免 JS 转发附加的 deny 误杀合法 JS API 请求。`_R_` 服务回执与 `$JS.ACK.` 免检。$SYS 账号可做 leaf 的 LocalAccount(此时是 JetStream 域扩展的前提),首连强制延迟 250ms。

## 7.3 JetStream over leaf:deny 表+映射的代理

没有专用 RPC:**域一致时**给非系统账号挂映射表 `$JS.<domain>.API.*`→`$JS.API.*`(jetstream_api.go:374-400),edge 应用的 JS 请求被 mapping 改写穿过 leaf 连接落到 hub;系统账号扩展(共享 $SYS)则让 leaf 侧 meta raft 进 observer 并 Reset 对齐日志。域不一致→denyAllJs/denyAllClientJs 整表拒绝。弱网配套:`jetstream_cluster_migrate` 断连超时后把本机 R>1 资产的 leader 迁走,恢复后复位。断连时**本地服务照常**(leaf 影子订阅只是账号子表的普通成员,摘除不阻塞本地匹配)——断连即降级的话 leaf 就失去意义。

## 7.4 设计动机

1. **信任边界在 leaf**:hub 只下发权限声明,spoke 本地过滤——越权流量在离源最近处被拦截,不消耗骨干带宽;
2. **hub-spoke 而非 full mesh**:N 站点两两互连是 O(N²) 公网链路;收敛到 hub 后回环退化为"对端集群标记+单一探测主题";
3. **leaf 可独立账号**:账号名只是本地命名空间,跨边界折叠成每连接一对映射;
4. **断连本地继续**:间歇性网络是常态;受影响的只有跨边界消息;
5. **恢复靠全量重放而非日志**:无序号/确认层做廉价增量;单账号兴趣规模可控,快照幂等;
6. **LS± 简化到无账号无 SID**:计数语义(smap)替代会话语义,断线即弃重连重建。

## 7.5 FAQ

**Q1:同一台服务器能既做 hub 又做 spoke 吗?**
能:hub/spoke 是每条连接的运行期角色,不是部署形态。

**Q2:LS+ 带账号吗?**
不带:账号语境由连接决定(remote_account 字段+hub 回带 RemoteAccount)。

**Q3:两条 leaf 互连会成环吗?**
$LDS.<nuid> 探测主题从对面回来即断链+30s 退避;注册时同集群名也拒绝。

**Q4:hub 断了 leaf 上的应用还能用吗?**
本地订阅/发布照常;跨边界消息中断,恢复后全量重放兴趣。

**Q5:leaf 上能用 JetStream 吗?**
域一致时:普通账号经映射代理到 hub;系统账号扩展让 leaf 参与 hub 的 meta。

**Q6:同 server 名重连会怎样?**
hub 侧陈旧连接顶替:旧半开连接被踢,防"旧连接占兴趣"。

**Q7:队列组权重在 leaf 怎么表达?**
LS+ 第三参数直接写权重,delta 取权重;权重变化走同 key 更新。

**Q8:能走 WebSocket 吗?**
能:/leafnode 路径伪装 WS 升级,校验 permessage-deflate 与私有 no-masking 头。

**Q9:压缩怎么协商?**
INFO/CONNECT 的 compress_mode;auto 档按首包 RTT 选。

**Q10:接错端口能发现吗?**
能:INFO 指纹区分四种监听端口;客户端误连靠 CONNECT 带 lang 识别。

## 7.6 小结与深挖方向

本章结论:**leaf="信任边界下沉+树形拓扑最小状态+账号折叠成连接维度+快照式恢复"**。深挖:

1. sharedSysAccDelay 与系统账号共享的 250ms 延迟;
2. stale 连接 2s 定时器与 CONNECT 后 writeLoop 才启动的次序;
3. tsub 5 秒清理与建连快照竞争;
4. isolate_leafnode_interest 与 request_isolation 的粒度;
5. JS observer Reset 不做的后果(两条 raft 日志分叉)。
