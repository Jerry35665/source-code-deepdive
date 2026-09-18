# 第 11 章 · networkd 与 resolved:网络配置与解析(卷二)

> 基线:commit `1f66b524`。核心:src/network/(networkd)与 src/resolve/(resolved)。概览卷:各讲清架构主干。纠偏:没有 .network/.netdev unit——networkd 由 udev/netlink 事件驱动自行管理接口。

## 11.0 全景:两个守护进程的架构

```
networkd(声明式配置引擎):
 内核 rtnl socket(8 组消息回调注册,networkd-manager.c:397-457)
 → manager_rtnl_process_link 按 ifindex 分发到 Link 对象
 → Link 状态机:PENDING→INITIALIZED→CONFIGURING→CONFIGURED(UNMANAGED/FAILED/LINGER 旁路)
 → 静态配置请求队列+DHCPv4/v6/NDisc(RA)/IPv4LL 协议引擎→rtnl 写回内核
resolved(解析聚合器):
 三入口(D-Bus/Varlink/本地 stub 127.0.0.53 与透传 127.0.0.54)
 → DnsQuery→Candidate(按 scope 打分)→DnsTransaction
 → per-scope 缓存(LRU+TTL)→本机合成(/etc/hosts)→上游(DNS/mDNS/LLMNR/DoT)
```

## 11.1 networkd:声明式配置的执行

`.network` 文件加载期即校验:**没有 [Match] 或系统条件不满足直接作废**;匹配选择推迟到接口出现——按加载顺序线性扫描,**第一个命中者胜出**(Unmanaged=yes 则接口旁路)。Link 状态机七态;`link_check_ready` 是"就绪"的唯一裁判:静态旗标+IPv6LL+任一启用的动态协议完成即析取;存在静态地址时跳过对动态协议的等待。netlink 复用方式朴素而有效:**一个 socket,每个回调内做 ifindex→Link 查表**;先全量枚举再进增量模式消除竞态窗口。`.netdev`(38 种虚拟设备:bridge/bond/vxlan/wireguard…)走虚表两遍解析:先通用 section 解出 Kind=,按 kind 定虚表、分配真实对象、再按 kind 的 section 表二次解析。carrier 丢失起延迟定时器拆除而非立即反应。

## 11.2 resolved:一个进程聚合四种协议

入口三路:D-Bus/Varlink/本地 DNS stub(127.0.0.53 普通解析、127.0.0.54 透传)。查询生命周期:DnsQuery→Candidate→DnsTransaction(按问题键在 scope 内去重复用);LLMNR 反向查询强制走 TCP(RFC 4795);UDP 超时/EMSGSIZE 自动升级 TCP;重试 DNS 24 次/LLMNR·mDNS 各 3 次,超时换下一台服务器。**缓存 per-scope**(by_key 哈希+by_expiry 堆,4096 条,陈旧数据最多留 30s)——不同接口可信度不同(VPN 看得到内网名),合并会跨接口污染。scope 路由四级匹配度:NO/LAST_RESORT/MAYBE/YES+n(后缀匹配计分),实现"*.company.com 走公司 DNS、.local 只走 mDNS"的分流。DNSSEC 信任锚启动装载,默认 allow-downgrade(构建选项)。/etc/resolv.conf 三形态:stub(默认软链目标)/uplink(真实上游)/静态。

## 11.3 设计动机

1. **声明式 .network 而非脚本**:配置可审计可随镜像分发;运行期只是"接口出现→找第一个匹配→收敛到目标状态",幂等天然支持热插拔与 reload;
2. **per-link 状态机+聚合裁判**:把并发过程归约为 Link 上的布尔旗标,单一裁决函数随时重算"就绪",避免回调网;
3. **单 netlink socket+回调查表**:rtnl 是内核网络状态的唯一事实源,"事件"与"对象"解耦;先枚举后增量消除竞态;
4. **四协议合一个进程**:共享问题表示/事务引擎/缓存/DNSSEC 验证与客户端 API;统一后才有跨协议 scope 路由;
5. **缓存 per-scope**:可信度与可见视图按接口不同;随 scope 释放自动作废;
6. **mDNS/LLMNR 保守启用**:组播解析有隐私与噪音成本,默认值做成构建选项,全关时连监听 socket 一并关闭。

## 11.4 FAQ

**Q1:.network 是 unit 文件吗?**
不是:PID 1 不为接口生成 unit;networkd 自行监听 udev/netlink。

**Q2:多个 .network 都匹配怎么办?**
第一个命中者胜出(按加载顺序);Unmanaged=yes 显式旁路。

**Q3:接口"就绪"怎么判定?**
link_check_ready:静态旗标合取+IPv6LL+任一动态协议(析取);有静态地址则不等 DHCP。

**Q4:carrier 断了配置会拆吗?**
起 carrier_lost_timer 延迟拆除,防抖。

**Q5:.netdev 支持哪些虚拟设备?**
38 种(bridge/bond/vlan/vxlan/wireguard…),虚表分发,两遍解析。

**Q6:resolved 的缓存是全局的吗?**
不是:每个 DnsScope 一份(per-link×协议),4096 条上限,陈旧最多留 30 秒。

**Q7:*.company.com 怎么保证走公司 DNS?**
scope 路由按后缀匹配计分取最高;route-only 域只做路由不承接查询。

**Q8:DNS 查询重试多少次?**
DNS 24 次(UDP 单发超时=总预算/24,TCP 给足 10s);LLMNR/mDNS 各 3 次。

**Q9:DoT 是独立协议吗?**
不是:服务器级 DNSOverTLS= 模式,TCP 流上叠 TLS;协议枚举复用 DNS。

**Q10:resolved 挂了域名解析就断吗?**
stub 模式依赖它;uplink 形态允许绕过 stub 直连上游的工具。

## 11.5 小结与深挖方向

本章结论:**网络栈="声明式配置+per-link 状态机+单 socket 查表分发;解析侧=四协议聚合+per-scope 缓存+后缀计分路由"**。深挖:

1. DHCPv4 续租/过期/丢失的 handler 状态(networkd-dhcp4.c:1187-1271);
2. stack netdev(vlan/macvlan)由所属 Link 代建的次序;
3. radv/DHCP 服务器(sd-dhcp-server/sd-radv)的本机服务侧;
4. DNSSEC allow-downgrade 的合成无签名应答路径;
5. resolve-hook varlink fd 与 networkd→resolved 的 DNS 服务器通知。
