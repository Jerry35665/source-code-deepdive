# E2 · networkd 与 resolved:网络配置与解析的守护进程

> 系列卷二。基线 commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`。行号均经实际核对;
> 路径相对仓库根。test/ 不在本地检出,本文不引用。

## 0. 总览

```
                       systemd-networkd(声明式配置引擎)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  内核 rtnl/genl/nfnl socket(事件源)                                     │
 │   │ RTM_NEWLINK/DELLINK/ADDR/ROUTE/RULE/...                              │
 │   ▼                                                                      │
 │  manager_setup_rtnl_filter():netlink_add_match 注册 8 组回调             │
 │   │          src/network/networkd-manager.c:334,397-457                  │
 │   ▼  按 ifindex 多路分发                                                  │
 │  Link 对象(hashmap links_by_index)                                       │
 │   │   src/network/networkd-link.c:2940 manager_rtnl_process_link         │
 │   ▼                                                                      │
 │  Link 状态机:  PENDING → INITIALIZED → CONFIGURING → CONFIGURED          │
 │   │            (FAILED / UNMANAGED / LINGER 为旁路终态)                   │
 │   ▼                                                                      │
 │  配置产物:静态 Address/Route/Rule/Nexthop 请求队列 +                      │
 │            DHCPv4 / DHCPv6 / NDisc(RA) / IPv4LL / radv 等协议引擎         │
 │            → 经 rtnl 写回内核(addr/route 配置)                            │
 │  旁路:netdev_vtable[] 解析 .netdev → RTM_NEWLINK 创建虚拟设备             │
 └──────────────────────────────────────────────────────────────────────────┘
        │ /run/systemd/netif 状态文件(sd_network)         │ varlink
        ▼                                                 ▼
                       systemd-resolved(解析聚合器)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  客户端入口                                                              │
 │   ├─ D-Bus org.freedesktop.resolve1   resolved-bus.c:2176 vtable         │
 │   ├─ varlink io.systemd.Resolve(.Monitor) resolved-varlink.c:1535        │
 │   └─ 本地 DNS stub 127.0.0.53 / 127.0.0.54:53                            │
 │       resolved-dns-stub.c:1390-1400(resolve-util.h:8,11)                 │
 │   ▼                                                                      │
 │  DnsQuery → QueryCandidate(按 scope 打分) → DnsTransaction               │
 │   ▼                                                                      │
 │  DnsScope 分流:  全局 unicast scope(DNS) + 每 link × {DNS,LLMNR,mDNS}    │
 │   │             resolved-link.c:147-188                                  │
 │   ├─①缓存(per-scope DnsCache,LRU+TTL)     ── 命中即回                    │
 │   ├─②本机合成(static records / /etc/hosts) ── resolved-dns-query.c:1059  │
 │   └─③上游协议:DNS(udp/tcp, 可选 DoT) / mDNS:5353 / LLMNR:5355            │
 │        → DnsTransaction 重试/超时/换服务器 → DNSSEC 验证                  │
 └──────────────────────────────────────────────────────────────────────────┘
```

两个守护进程没有 unit 类型意义上的 `.network`/`.netdev` unit(PID 1 不为接口生成 unit):
networkd 由 **udev/netlink 事件驱动**自行发现与管理接口(§1.5),再把结果(DNS 服务器、
mDNS/LLMNR/DNSSEC 开关)以状态文件形式供 resolved 读取(src/resolve/resolved-link.c:298)。

---

## 1. networkd:把 `.network` 文件变成内核状态

### 1.1 配置模型:声明式的 `.network` 与 `.netdev`

`network_load()` 在 `NETWORK_DIRS` 下枚举 `.network`,逐个 `network_load_one()` 载入
(src/network/networkd-network.c:629-637,325)。键值解析走 gperf 完美哈希:
`Match.MACAddress/Match.Driver` 等直接映射到 `Network->match` 字段
(src/network/networkd-network-gperf.gperf:78-82)。加载后立即 `network_verify()`:

```c
// src/network/networkd-network.c:128-145(节选)
if (net_match_is_empty(&network->match) && !network->conditions)
        return log_warning_errno(SYNTHETIC_ERRNO(EINVAL),
                                 "%s: No valid settings found in the [Match] section, ignoring file. "
                                 "To match all interfaces, add Name=* in the [Match] section.",
                                 network->filename);
/* skip out early if configuration does not match the environment */
if (!condition_test_list_net(network->conditions, environ, NULL, NULL, NULL))
        return log_debug_errno(SYNTHETIC_ERRNO(EINVAL),
                               "%s: Conditions in the file do not match the system environment, skipping.",
                               network->filename);
```

即:**没有 [Match] 或系统条件不满足的文件直接作废**,匹配选择推迟到接口出现时。

### 1.2 匹配选择:第一个命中的 `.network` 拿下接口

Link 分配时按加载顺序线性扫描(src/network/networkd-link.c:1368-1416):

```c
// src/network/networkd-link.c:1376-1395(link_get_network,节选)
ORDERED_HASHMAP_FOREACH(network, link->manager->networks) {
        r = net_match_config(&network->match,
                        link->dev, &link->hw_addr, &link->permanent_hw_addr,
                        link->driver, link->iftype, link->kind, link->ifname,
                        link->alternative_names, link->wlan_iftype,
                        link->ssid, &link->bssid);
        if (r < 0)
                return r;
        if (r == 0)
                continue;          /* 不匹配,试下一个文件 */
```

第一个命中者胜出;命中但写了 `Unmanaged=yes` 则返回 `-ENOENT`,接口进 UNMANAGED
(networkd-link.c:1408-1409)。基于可预测性差的接口名匹配会打 warning
(networkd-link.c:1397-1406)。

### 1.3 Link 状态机:七状态、事件驱动迁移

```c
// src/network/networkd-link.h:14-22
typedef enum LinkState {
        LINK_STATE_PENDING,     /* udev has not initialized the link */
        LINK_STATE_INITIALIZED, /* udev has initialized the link */
        LINK_STATE_CONFIGURING, /* configuring addresses, routes, etc. */
        LINK_STATE_CONFIGURED,  /* everything is configured */
        LINK_STATE_UNMANAGED,   /* Unmanaged=yes is set */
        LINK_STATE_FAILED,      /* at least one configuration process failed */
        LINK_STATE_LINGER,      /* RTM_DELLINK for the link has been received */
```

迁移主干:`link_new()` 创建即 PENDING(networkd-link.c:2892)→ udev 初始化完成后
`link_initialized()` 触发一次 GETLINK 同步,`link_initialized_and_synced()` 置
INITIALIZED(networkd-link.c:1699-1701,1759-1769)→ `link_configure()` 断言
INITIALIZED 并置 CONFIGURING(networkd-link.c:1232-1239)→ 各配置请求完成时反复调用
`link_check_ready()`,全就绪后置 CONFIGURED(networkd-link.c:626)。

`link_check_ready()` 是"就绪"的唯一裁判(networkd-link.c:484-627):依次查流量控制、
link 层设置、stacked netdev、各类静态 `*_configured` 旗标、IPv6LL 地址,再查动态协议——
任一启用的协议(IPv4LL/DHCPv4/DHCPv6/DHCP-PD/NDisc)完成即可(networkd-link.c:614);
存在静态地址时跳过对动态协议的等待(networkd-link.c:564-566)。

carrier 是另一条驱动线:RTM_NEWLINK 的 flags 变化折算为
`link_carrier_gained()/link_carrier_lost()`(networkd-link.c:2334-2337);gained 时若已在
CONFIGURING/CONFIGURED 则补启动动态配置(networkd-link.c:1909);lost 则起
`carrier_lost_timer` 延迟拆除(networkd-link.c:1996-2003)。

### 1.4 netlink 通道:单 socket、回调多路分发

`manager_connect_rtnl()` 打开 rtnl socket(networkd-manager.c:368-395),并按消息类别
注册回调(src/network/networkd-manager.c:334,397-457):

```c
// src/network/networkd-manager.c:397-425(节选)
r = netlink_add_match(m->rtnl, NULL, RTM_NEWLINK, &manager_rtnl_process_link, NULL, m, "network-rtnl_process_link");
r = netlink_add_match(m->rtnl, NULL, RTM_DELLINK, &manager_rtnl_process_link, NULL, m, "network-rtnl_process_link");
...
r = netlink_add_match(m->rtnl, NULL, RTM_NEWADDR, &manager_rtnl_process_address, NULL, m, "network-rtnl_process_address");
r = netlink_add_match(m->rtnl, NULL, RTM_DELADDR, &manager_rtnl_process_address, NULL, m, "network-rtnl_process_address");
```

覆盖 LINK/QDISC/TCLASS/ADDR/NEIGH/ROUTE/RULE/NEXTHOP 八类(manager.c:405-457),另有
genl(nl80211,manager.c:286)与 nfnl(manager.c:312-327)辅助通道;启动时先
`manager_enumerate_*` 全量枚举再进增量模式(manager.c:928-1061)。
`manager_rtnl_process_link`(实现在 networkd-link.c:2940-3068)按 ifindex 查找/新建
Link:新 link → `link_new()`+`link_update()`+`link_check_initialized()`;已有 link →
`link_update()` 后尝试 `link_reconfigure_impl()`(.network 可热替换);RTM_DELLINK →
`link_drop()/netdev_drop()`(networkd-link.c:2998-3061)。地址同理:`manager_rtnl_process_address`
先按 ifindex 找回 Link 再解析(src/network/networkd-address.c:1858-1901)。**多路复用的
实现方式就是:一个 socket,每个回调内做 ifindex → Link 查表**。

### 1.5 与 PID 1 的关系:没有 .network unit,事件来自 udev/内核

networkd 是普通服务(systemd-networkd.service),**不是 unit 生成器**:.network/.netdev 不是 unit 文件,不产生 job。接口发现完全来自内核 RTM_NEWLINK;PENDING 状态存在的意义就是"等 udev 给接口改名/打属性":udev 回调 `link_initialized()` 直言 "udev initialized link",再做一次 GETLINK 确保排队的 NEWLINK 已消化(networkd-link.c:1759-1769)。此外 networkd 从 PID 1 接收预打开的 socket-activation fd:rtnl/varlink/varlink-metrics/resolve-hook 四种(manager.c:218-276),resolve-hook fd 用于挂载面向 resolved 的 varlink 服务(manager.c:623)。

### 1.6 动态地址协议挂接点

`link_configure()` 末尾集中"挂发动机":`link_request_dhcp4_client()` / `link_request_dhcp6_client()` / `link_request_ndisc()` / `link_request_radv()` / `ipv4ll_configure()`,有 carrier 时再 `link_acquire_dynamic_conf()`(networkd-link.c:1318-1365,768)。协议引擎在 sd-dhcp-*/sd-ndisc/sd-radv 库(独立客户端库),networkd 只挂回调:DHCPv4 注册 `dhcp4_handler`,处理获取/续租/过期/丢失(src/network/networkd-dhcp4.c:1531,1187-1271);DHCPv6 同构(src/network/networkd-dhcp6.c:740);NDisc 收 Router Advertisement(src/network/networkd-ndisc.c:2900-2967);本机 DHCP 服务器/RA 用 sd-dhcp-server/sd-radv(src/network/networkd-radv.c:460)。一句话:**每个协议 = 一个库对象 + 一个 handler 回调 + 若干 `*_configured` 旗标参与 link_check_ready**。

### 1.7 netdev:虚表分发的虚拟设备工厂

`.netdev` 描述要**主动创建**的虚拟设备(bridge/bond/vlan/vxlan/wireguard/…共 38 种),
`netdev_vtable[]` 虚表分发(src/network/netdev/netdev.c:56-93)。加载是"两遍解析":先
通用 section 解析出 `Kind=`(`NetDev.Name/Kind=` 见 netdev-gperf.gperf:57-58),按 kind
定位虚表、分配真实对象、用该 kind 的 section 表二次解析并 `config_verify`
(src/network/netdev/netdev.c:1059-1115):

```c
// src/network/netdev/netdev.c:1075-1092(节选)
if (netdev_raw->kind == _NETDEV_KIND_INVALID)
        return log_warning_errno(..., "NetDev has no Kind= configured in \"%s\", ignoring.", filename);
if (!netdev_raw->ifname)
        return log_warning_errno(..., "NetDev without Name= configured in \"%s\", ignoring.", filename);
netdev = malloc0(NETDEV_VTABLE(netdev_raw)->object_size);
...
if (NETDEV_VTABLE(netdev)->init)
        NETDEV_VTABLE(netdev)->init(netdev);
```

独立 netdev(bridge/bond/dummy 等)由 `netdev_load()` 枚举后即排队创建
(netdev.c:1127-1153,1003-1025);创建本身也是 rtnl 请求
(`independent_netdev_process_request` → `independent_netdev_create`,netdev.c:967-995),
随后内核回 RTM_NEWLINK,`manager_rtnl_process_link` 用 `netdev_get()` 按名对号、
`netdev_set_ifindex()` 绑定 ifindex(networkd-link.c:2984-2996)。依附物理口的 stacked
netdev(vlan/macvlan/…)由所属 Link 在 `link_configure()` 里代建(networkd-link.c:1298,675)。

---

## 2. resolved:一个解析器聚合四种协议

### 2.1 形态与数据面入口

`manager_new()` 预置 LLMNR/mDNS 六种 socket fd、装载信任锚、创建全局 unicast scope
(src/resolve/resolved-manager.c:719-804;749 `dns_trust_anchor_load`,774
`dns_scope_new(..., DNS_SCOPE_GLOBAL, ..., DNS_PROTOCOL_DNS, ...)`)。resolved 也监听
rtnl 维护 per-Link 视图:`manager_process_link()` 处理 NEWLINK/DELLINK,link 消失时
顺带重写 resolv.conf(manager.c:63-134;`manager_rtnl_listen` 253)。启动面只有
`manager_dns_stub_start()` 与 varlink(manager.c:825-839)。客户端走三条路:D-Bus
(resolve_vtable,src/resolve/resolved-bus.c:2176;`bus_method_resolve_hostname` bus.c:470)、
varlink io.systemd.Resolve/.Monitor(src/resolve/resolved-varlink.c:1535)、本地 DNS
stub——127.0.0.53(普通解析)与 127.0.0.54(透传代理),UDP+TCP 各一
(src/resolve/resolved-dns-stub.c:1390-1400;地址常量 src/shared/resolve-util.h:8,11)。

### 2.2 四种上游协议,各一句话入口

- **经典 DNS(单播)**:全局 + 每 link unicast scope,`dns_scope_emit_udp()/dns_scope_socket_tcp()` 出包(src/resolve/resolved-dns-scope.h:83-85)。
- **mDNS**:每 link v4/v6 一对 scope(resolved-link.c:177-188),固定 UDP 5353 组播(`MDNS_PORT`,src/resolve/resolved-mdns.h:6)。
- **LLMNR**:每 link v4/v6 一对 scope(resolved-link.c:157-167),UDP/TCP 5355(`LLMNR_PORT`,src/resolve/resolved-llmnr.h:6)。
- **DoT**:非独立 scope,而是服务器级 `DNSOverTLS=` 模式:TCP 建立后在流上叠 TLS(`dnstls_stream_connect_tls`,src/resolve/resolved-dnstls.c:65;调用点 resolved-dns-transaction.c:785-790),后端可选 OpenSSL/GnuTLS。

协议枚举只有 DNS/MDNS/LLMNR 三个值,DoT 复用 DNS(src/shared/dns-packet.h:14-19)。

### 2.3 查询生命周期:Query → Candidate → Transaction

入口 `dns_query_go()` 依次试静态记录、/etc/hosts、varlink hook,再交 scope 选择
(src/resolve/resolved-dns-query.c:1059-1096);`DnsQueryCandidate` 对每个合格 scope
孵化 `DnsTransaction`,事务按问题键在 scope 内去重复用(resolved-dns-scope.h:63-69)。
事务主循环 `dns_transaction_go()`(src/resolve/resolved-dns-transaction.c:2116):

```c
// src/resolve/resolved-dns-transaction.c:2186-2204(节选)
if (t->scope->protocol == DNS_PROTOCOL_LLMNR &&
    (dns_name_endswith(..., "in-addr.arpa") > 0 || ...)) {
        /* RFC 4795, Section 2.4. reverse lookups shall always be made via TCP on LLMNR */
        r = dns_transaction_emit_tcp(t);
} else {
        /* Try via UDP, and if that fails due to large size or lack of support try via TCP */
        r = dns_transaction_emit_udp(t);
        if (IN_SET(r, -EMSGSIZE, -EAGAIN, -EPERM))
                r = dns_transaction_emit_tcp(t);
}
```

重试与超时:尝试上限 DNS 24 次、LLMNR/mDNS 各 3 次(src/resolve/resolved-timeouts.h:14,17,20);UDP 单发超时=总预算/24,TCP 给足 10 秒(resolved-timeouts.h:53,58);超时/无效应答时 `dns_transaction_retry()` 换下一台服务器再来(resolved-dns-transaction.c:521-540),服务器轮转靠 `dns_scope_next_dns_server()`;耗尽后 `dns_transaction_prepare()` 终结为 ATTEMPTS_MAX_REACHED(resolved-dns-transaction.c:1719-1736)。LLMNR/mDNS 首发前按 RFC 做随机抖动延迟(resolved-dns-transaction.c:2142-2170)。

### 2.4 缓存:按 scope 一份,LRU 修剪 + TTL 收缩

缓存不是全局一张,而是**每个 DnsScope 自带一份** `DnsCache`(src/resolve/resolved-dns-scope.h:46):`by_key` 哈希 + `by_expiry` 过期堆,默认上限 4096 条(src/resolve/resolved-dns-cache.h:7-22),`dns_cache_prune()` 做 LRU 式淘汰。写入时收缩 TTL:取应答最小 TTL,SOA 场景再 clamp 到 SOA minimum(resolved-dns-cache.c:352-359,470),导出时剩余寿命 clamp 到 [1,原TTL] 秒(resolved-dns-cache.c:1015-1023);陈旧数据最多保留 30 秒(RFC 8767,cache.h:11-12)。

### 2.5 scope:按"接口 × 协议"路由查询

`DnsScope` 携带 origin(全局/按链路/委托)、协议、地址族、所属 link、缓存与本地区(src/resolve/resolved-dns-scope.h:25-79)。每 link 五个 scope(resolved-link.c:147-188),外加一个全局 DNS scope(resolved-manager.c:774)。路由裁决在 `dns_scope_good_domain()`,返回四级匹配度,调用方只取最高分(resolved-dns-scope.c:676-696):

```c
// src/resolve/resolved-dns-scope.c:686-696(注释节选)
/*    DNS_SCOPE_NO         → This scope is not suitable for lookups of this domain, at all
 *    DNS_SCOPE_LAST_RESORT→ This scope is not suitable, unless we have no alternative
 *    DNS_SCOPE_MAYBE      → This scope is suitable, but only if nothing else wants it
 *    DNS_SCOPE_YES_BASE+n → This scope is suitable, and 'n' suffix labels match        */
```

其中过滤 loopback/特殊用途域(resolved-dns-scope.c:723-741);DNS scope 还要求有服务器、
按 search domain(含 route-only 域)计分(resolved-dns-scope.c:776-796)。这实现了
"*.company.com 走公司接口 DNS、其余走全局、.local 只走 mDNS"的分流。

### 2.6 DNSSEC 与 resolv.conf 的三种形态

DNSSEC:信任锚启动时从 `dnssec-trust-anchors.d` 装载,内置根锚(正向)与 `.invalid`
反向锚(src/resolve/resolved-dns-trust-anchor.c:32,85,121);事务准备阶段先查信任锚,
根 DS 缺失时按 allow-downgrade 合成无签名应答(resolved-dns-transaction.c:1721-1745);
裁决出口 `manager_dnssec_verdict()`(resolved-manager.c:1793)。默认模式由构建选项决定:
`allow-downgrade`(meson_options.txt:373-376)。

`/etc/resolv.conf` 三种形态由 resolved 写出的两个文件 + 一个静态文件构成
(src/shared/resolve-util.h:82-88):

1. **stub 模式(默认)**:`/run/systemd/resolve/stub-resolv.conf`——上游数据 + nameserver
   指向 127.0.0.53,`/etc/resolv.conf` 软链到它(resolv-conf.c:357-368);
2. **uplink 模式**:`/run/systemd/resolve/resolv.conf`——写出真实上游列表,供绕过 stub
   的场景软链(resolv-conf.c:347-355);
3. **静态形态**:stub 监听关闭时 stub 文件退化为指向包内静态 `resolv.conf` 的符号链接
   (resolv-conf.c:373-381;`PRIVATE_STATIC_RESOLV_CONF`,resolve-util.h:88)。

resolved 自己也读取 `/etc/resolv.conf` 作为上游补充来源(`manager_read_resolv_conf`,
resolv-conf.c:73-84);`manager_write_resolv_conf()` 在服务器/域变化与 link 删除时触发
(resolv-conf.c:327-345;resolved-manager.c:120-126)。

---

## 3. cgroup / IP 计费联动(一句话)

两个守护进程自身都不做 cgroup 级 IP 计费:`IPAccounting=` 是 PID 1 基于 cgroup 的
unit 级特性,统计与导出在 src/core/unit.c:2529-2534;resolved 与 cgroup 的接触点仅是
内存压力事件(SIGRTMIN+18,到来时清空缓存,src/resolve/resolved-manager.c:607-615),
networkd 则只是被 PID 1 以 socket-activation fd(§1.5)拉起并协作。

---

## 4. 设计动机

1. **为什么声明式 `.network` 文件而非命令式脚本**:配置落盘可审计、可随镜像分发;加载期 [Match] 校验(networkd-network.c:135-139)提前暴露"配置不适用";运行期只是"接口出现 → 找第一个匹配文件 → 收敛到目标状态",同一份配置反复应用幂等,天然支持热插拔与 reload。
2. **为什么 per-link 状态机 + `link_check_ready` 聚合**:接口"就绪"是静态配置、carrier、DHCPv4/v6、NDisc 等并发过程的合取/析取混合(networkd-link.c:614 的"任一动态协议完成"即析取),把过程归约为 Link 上的布尔旗标后,单一裁决函数即可随时重算"就绪",重配置时旗标清零重跑(networkd-link.c:1220-1227),避免回调网。
3. **为什么 netlink 用单 socket + 回调多路分发**:rtnl 是内核网络状态的唯一事实源,八类消息 × ifindex 查表(networkd-link.c:2983)让"事件"与"对象"解耦;先枚举后增量(manager.c:928 起)消除竞态窗口。resolved 复用同一手法(resolved-manager.c:63),两个守护进程对内核视图保持一致。
4. **为什么 resolved 把 DNS/mDNS/LLMNR(加 DoT)合并进一个进程**:四者共享问题表示(DnsResourceKey)、事务引擎、缓存、DNSSEC 验证与客户端 API,分拆必然四份重复;统一后还能做跨协议 scope 路由——同一名字按域规则选协议(resolved-dns-scope.c:686-696)。
5. **为什么缓存按接口 scope 划分而非全局一张表**:不同接口的上游可信度与可见视图不同(VPN 看得到内网名,家庭接口看不到),合并会跨接口污染;per-scope 缓存随 scope 释放自动作废,mDNS/LLMNR 记录带链路归属,天然只能本地域生效(resolved-dns-scope.h:46)。
6. **为什么 mDNS/LLMNR 是按链路、保守启用的特性**:组播解析会向本链路广播主机名与查询内容,有隐私与噪音成本,托管环境常需禁用;故上游把默认值做成构建选项(meson_options.txt:377-388,可为 no),运行时按链路开关,且全链路都关时连监听 socket 一并关闭(resolved-manager.c:129-131)。
7. **为什么 `/etc/resolv.conf` 有三种形态**:resolv.conf 是多代软件共享的契约——stub 形态给常态;uplink 形态给要直连上游的工具;静态形态给禁用 stub 的最小系统。resolved 不强行接管 /etc/resolv.conf,只生成候选文件交管理员软链选择(resolv-conf.c:347-381)。

---

## 5. 写作素材清单(文件:行号)

| # | 位置 | 内容 |
|---|------|------|
| 1 | src/network/networkd-link.h:14-22 | LinkState 七状态枚举及注释 |
| 2 | src/network/networkd-link.c:2940-3068 | manager_rtnl_process_link:netlink→Link 分发 |
| 3 | src/network/networkd-link.c:1693-1713 | PENDING→INITIALIZED 迁移 |
| 4 | src/network/networkd-link.c:484-627 | link_check_ready:CONFIGURING→CONFIGURED 裁决 |
| 5 | src/network/networkd-link.c:1368-1416 | link_get_network:.network 匹配选择 |
| 6 | src/network/networkd-network.c:128-145 | network_verify:[Match] 校验 |
| 7 | src/network/networkd-manager.c:397-457 | netlink_add_match 八类消息注册 |
| 8 | src/network/networkd-link.c:2334-2337 | carrier gained/lost 触发点 |
| 9 | src/network/networkd-dhcp4.c:1187,1531 | dhcp4_handler 与回调注册 |
| 10 | src/network/netdev/netdev.c:56-93 | netdev_vtable[] 38 种虚拟设备虚表 |
| 11 | src/network/netdev/netdev.c:1059-1115 | netdev 两遍解析(Kind=→虚表→typed sections) |
| 12 | src/resolve/resolved-manager.c:719-804 | manager_new:全局 scope/信任锚/fd 预置 |
| 13 | src/resolve/resolved-link.c:147-188 | 每 link 五个 scope 的创建 |
| 14 | src/resolve/resolved-dns-transaction.c:2116-2225 | dns_transaction_go:抖动/UDP→TCP/换服务器 |
| 15 | src/resolve/resolved-timeouts.h:14-58 | 尝试上限与超时常量(24 次/3 次/10s) |
| 16 | src/resolve/resolved-resolv-conf.c:327-390 | resolv.conf 双文件写出逻辑 |

(完)
