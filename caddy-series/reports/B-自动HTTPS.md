# B 报告:Caddy 自动 HTTPS 深读(ACME / certmagic)

> 调研对象:Caddy v2 仓库 caddyserver/caddy,shallow clone,commit `56e3a88`(go.mod 第 12 行依赖 `github.com/caddyserver/certmagic v0.25.4`,libdns v1.1.1 在第 146 行)。
> 源码里 **没有 vendor 目录**,certmagic 以 module 依赖形式存在;本报告 certmagic 侧行号按 **GitHub tag v0.25.4** 的源码逐一核对,标注为 `certmagic@v0.25.4/文件:行号`;Caddy 侧标注为 `仓库相对路径:行号`。

自动 HTTPS 是 Caddy 的招牌:把域名写在配置里,证书申请、部署、续期、OCSP 全自动。真正的引擎在 certmagic 库;Caddy 侧只做两件事——把配置翻译成 certmagic.Config(自动化策略/automation policy),并把 TLS 握手、HTTP 端口、存储等系统资源接给 certmagic。

---

## 1. 全景:一个域名从配置到证书的旅程

```text
Caddyfile / JSON
   │  "example.com" 出现在 host matcher / automate loader
   ▼
[1] caddyhttp 自动 HTTPS 第一阶段(Provision 期)
    modules/caddyhttp/autohttps.go:77  automaticHTTPSPhase1
    ├ 扫描所有路由的 MatchHost,收集域名            autohttps.go:150-168
    ├ SubjectQualifiesForCert 过滤 + SkipCerts      autohttps.go:203-204
    └ 生成 HTTP→HTTPS 重定向路由(隐式 server)      autohttps.go:498-503
   ▼
[2] caddytls 把域名归入自动化策略(AutomationPolicy)
    modules/caddytls/tls.go:905  getAutomationPolicyForName(首个匹配,catch-all 兜底)
    modules/caddytls/automation.go:182  AP.Provision → makeCertMagicConfig :272
    默认 issuer:LE(无邮箱时);配置邮箱再加 ZeroSSL   automation.go:479-488
    → 得到 certmagic.Config{ Issuers, Storage, OnDemand, ... }  automation.go:364-378
   ▼
[3] 服务器启动完成后才发起签发(避免抢端口)
    modules/caddyhttp/autohttps.go:869  automaticHTTPSPhase2 → tlsApp.Manage
    modules/caddytls/tls.go:604  Manage:按策略分桶,批量 ManageAsync     tls.go:629
   ▼
[4] certmagic 侧 obtainCert(certmagic@v0.25.4/config.go:547)
    ├ 存储里已有证书?→ no-op                       config.go:557-559
    ├ 获取 issue_cert_<域名> 分布式锁               config.go:571-575
    ├ 锁内再查一次存储(双检)                      config.go:598-601
    ├ 生成私钥 + CSR                                config.go:629-640
    ├ 逐个 issuer 尝试 Issue(ACME 订单)           config.go:649-691
    │    └ challenge:solvers 由 acmeclient.go:186-226 装配(HTTP-01/TLS-ALPN-01,配 DNS 则独占)
    └ saveCertResource 落盘(cert/.key/.json)      config.go:717
   ▼
[5] 内存缓存 + 存储双写
    Cache.cache(哈希→证书)+ cacheIndex(SAN→哈希)  certmagic@v0.25.4/cache.go:55-58
    存储布局:certificates/<issuer>/<域名>/{.crt,.key,.json}  certmagic@v0.25.4/storage.go:232-251
   ▼
[6] TLS 握手时按 SNI 取证书
    connpolicy.go:282 注入 GetCertificate → certmagic GetCertificateWithContext
    certmagic@v0.25.4/handshake.go:53(先查缓存 :276,精确→通配逐标签退化 :144-152)
```

一句话:配置里的域名 → automation policy 翻译成 certmagic.Config → `ManageAsync` 批量管理 → `obtainCert`(锁→challenge→签发→落盘)→ 内存缓存 → SNI 命中。之后 certmagic 的后台维护协程(`cache.go:110` 启动)每隔 `RenewCheckInterval` 扫描一次到期情况,自动续期。

---

## 2. certmagic 缓存专节:证书的生命周期

### 2.1 两条索引

`Cache` 结构(certmagic@v0.25.4/cache.go:49-70)有两条数据结构:

```go
// The cache is keyed by certificate hash
cache map[string]Certificate
// cacheIndex is a map of SAN to cache key (cert hash)
cacheIndex map[string][]string
```

- `cache`:证书内容哈希 → Certificate,天然去重(同一张证书被多个 SAN 命中只存一份)。
- `cacheIndex`:SAN → 哈希列表,握手时按名字 O(1) 查找;`AllMatchingCertificates` 在精确匹配失败后把域名标签逐个换成 `*` 试通配符(cache.go:386-400)。

进程级单例:certmagic 有 `defaultCache`(cache.go:438-441),Caddy 在 `tls.Provision` 里自己建了一个全局 `certCache`,容量默认 10000(modules/caddytls/tls.go:214-216),并传入 `GetConfigForCert` 回调——缓存里的每张证书要管理时,都按"它的第一个 SAN"反查对应的 automation policy(tls.go:202-204)。缓存与"如何管理这张证书的策略"解耦,是 certmagic 最核心的一个设计决策。

### 2.2 写入:去重、容量淘汰

`unsyncedCacheCertificate`(cache.go:208-281)是唯一写入口:

- 哈希命中即视为 no-op,只补 tag(cache.go:212-233)——多个 server 共用一张证书时零拷贝。
- 达到容量上限时**随机淘汰**(cache.go:241-261),但 `randomCert.managed` 为假(手工加载的证书)不参与淘汰(cache.go:250)。淘汰不是 LRU,注释明说随机数便宜且分布更均匀(cache.go:242-246)。

### 2.3 替换与卸载

- 续期成功后走 `replaceCertificate`(cache.go:323-331):先 `removeCertificate` 再写入新证书,同一把写锁内完成,握手中的请求要么看到旧证书要么看到新证书。
- Caddy 重载配置时,`TLS.Cleanup` 用 `RemoveManaged`(cache.go:411-425)按 subject+issuerKey 精确卸载不再管理的证书,issuerKey 不同也要卸了重管(tls.go:539-559,public/internal CA 切换被视为不同证书);整个 TLS app 消失时才 `certCache.Stop()` 并置 nil(tls.go:584-593)。

### 2.4 动态加载:未缓存域名在握手时发生什么

`getCertDuringHandshake`(certmagic@v0.25.4/handshake.go:272-420)是缓存未命中后的完整决策树:

```go
// handshake.go:300-330(节选)
certLoadWaitChansMu.Lock()
waiter, ok := certLoadWaitChans[name]
if ok {
    // another goroutine is already loading the cert; just wait
    ...
    timeout := time.NewTimer(2 * time.Minute)
    select {
    case <-timeout.C: ...
    case <-waiter.done: ...
```

- **进程内 singleflight**:同名 SNI 并发到达,只有 leader 去加载/签发,其余等 `waiter.done`,超时 2 分钟(handshake.go:300-325)。on-demand 签发另有 `obtainCertWaitChans` 一套同样的等待机制(handshake.go:515-543)。
- **能否动态加载**:`loadDynamically := cfg.OnDemand != nil || cacheAlmostFull`(handshake.go:382),后者是缓存用量 ≥90% 时允许重新从盘上加载被淘汰的证书(handshake.go:381)。
- 顺序:先 `loadCertFromStorage`(handshake.go:386,先精确后 `*.` 通配,handshake.go:431-435),盘上没有且允许 on-demand,才 `obtainOnDemandCertificate` 向 CA 签发(handshake.go:395,整体 180 秒超时,handshake.go:557)。
- 已缓存的 on-demand 证书不靠定时器维护,而是**由握手触发**维护(handshake.go:283-288 的注释明说 "maintenance is triggered by handshakes instead of by a timer")。

---

## 3. ACME 流程专节:challenge 与分布式锁

### 3.1 三种 challenge 的装配与实现

solver 在建 ACME client 时装配(certmagic@v0.25.4/acmeclient.go:186-226):配了 DNS solver 就**独占** dns-01(acmeclient.go:223-226,注释:DNS 通常只在不便开 80/443 的场景用);否则同时注册 http-01 和 tls-alpn-01,具体选哪个由底层 acmez 库在订单里决定。官方规定的端口是 80 与 443(certmagic@v0.25.4/certmagic.go:471,475)。

- **http-01**:`httpSolver.Present` 尝试 `robustTryListen` 绑定 80 口(solvers.go:59-82);绑不上且能 TCP 连通,就假设"已有人在听、它能答 challenge",容忍后返回 nil(solvers.go:716-801,这是多 server 共用进程时避免互相打架的关键)。应答逻辑在 `HandleHTTPChallenge`(httphandlers.go:54-65)→ `distributedHTTPChallengeSolver`(:71)→ `solveHTTPChallenge` 写回 `token.thumbprint`(:178-194),并且校验 Host 防止 DNS rebinding(:181)。
- **tls-alpn-01**:`tlsALPNSolver.Present` 先生成专用"毒性证书"(solvers.go:138),再用 `config.TLSConfig()` 包一层 TLS listener(solvers.go:176);每个进来的连接只做握手不干别的(solvers.go:204-223)。Caddy 侧在握手入口特判 ALPN 恰为 `acme-tls/1` 的 ClientHello,直接回 challenge 证书(handshake.go:73-90)。
- **dns-01**:`DNS01Solver.Present` 经 libdns Provider `AppendRecords` 写 `_acme-challenge` TXT(solvers.go:261-280,createRecord:382-410),`Wait` 轮询传播(solvers.go:285-299),`CleanUp` 删记录(solvers.go:307-327)。同一 `_acme-challenge.example.com` 会被 example.com 与 *.example.com 共用,靠 TXT 值区分(solvers.go:248-255)。

所有 solver 最外层再包一层 `solverWrapper`(solvers.go:870-884),把 challenge 信息记进进程级 `activeChallenges` 表(solvers.go:842-845)。注释点名了这个机制服务的场景:**Caddy 的 admin endpoint 和 HTTP/TLS 模块互不知晓**,但同一进程里任何端口上的服务器都能靠这张表替别人应答 challenge(acmeclient.go:228-242)。

### 3.2 分布式锁:多实例怎么不重复签发

Caddy 的答案不是"选主",而是**把互斥下沉到共享存储**:

1. **签发互斥**。`obtainCert`/`renewCert` 都先 `acquireLock(ctx, cfg.Storage, "issue_cert_<域名>")`(certmagic@v0.25.4/config.go:571-575,838-853;`lockKey` 定义 config.go:1320-1322,常量 `certIssueLockOp = "issue_cert"` config.go:1379)。锁实现在 `Storage.Locker` 接口上(storage.go:129-153):默认文件存储用原子 `create` 竞争锁文件(filestorage.go:408),拿不到就每秒轮询(fileLockPollInterval);锁文件带 `lockMeta` 时间戳,超过 `lockFreshnessInterval`(5 秒)未刷新判定 stale,可被安全移除(filestorage.go:244-256)。
2. **锁租约续期**。重试期间锁可能到期,`renewLockLease` 按"当前重试间隔+签发超时"续租(config.go:509-530),存储需实现可选接口 `LockLeaseRenewer`(storage.go:172)。
3. **锁内双检**。拿到锁后再查一次"存储里是不是已经有了",别人刚签完就直接复用(config.go:598-601;续期同理 config.go:873-885)。
4. **challenge token 共享**。`distributedSolver.Present` 把整个 challenge JSON 存进共享存储 `<issuer前缀>/challenge_tokens/<域名>.json`(solvers.go:634-650,675-683),本机没发起过这单的实例从存储读出 token 帮忙应答:`getACMEChallengeInfo` 先查本进程内存,miss 再查存储(config.go:1169-1217);HTTP 应答入口即 `HandleHTTPChallenge`(httphandlers.go:44 的注释:"this instance or any other instance in this cluster")。
5. **续期去重的兜底**。维护循环发现证书快到期时,先看存储里是不是已被别的实例续过,是则直接 reload 而不再签(maintain.go:142-158,注释:"checking disk first is a simple way to possibly drastically reduce rate limit problems")。

集群的全部要求浓缩在一段注释里(solvers.go:612-614):**共享 sync+storage,并用本包的 solver 设施**。

Caddy 侧的接线:HTTP challenge 由 `caddyhttp` 的服务器在**任何用户 handler 之前**拦截(caddyhttp/server.go:695-698 "guarantee ACME HTTP challenges"),转发给 `TLS.HandleHTTPChallenge`(modules/caddytls/tls.go:809-851):先按 r.Host 找 automation policy 里能应答的 issuer(:824-830),再退到进程内 `GetACMEChallenge` 表(:837-839)。fillInACMEIssuer 会把 http app 的自定义端口写进 challenge 的 AlternatePort,使 `:8443` 之类的站点也能自动续证书(autohttps.go:827-857)。Phase2 特意等所有 server 启动后才调 Manage,防止 certmagic 的临时 listener 抢占 80/443 导致用户站点绑定失败(autohttps.go:863-868 注释)。

---

## 4. 续期专节:"30 天阈值"的真相

### 4.1 阈值不是写死的 30 天,而是剩余寿命的 1/3

这是调研中最值得纠正的常见误解。判断函数 `certNeedsRenewal`(certmagic@v0.25.4/certificates.go:90-186)的优先级:

```go
// certificates.go:167(无 ARI 时的常规判断)
if currentlyInRenewalWindow(leaf.NotBefore, expiration, cfg.RenewalWindowRatio) {
    ...return true
}
```

`currentlyInRenewalWindow` 用"剩余:总寿命"的比值计算窗口(certificates.go:214-224),`DefaultRenewalWindowRatio = 1.0/3.0`(maintain.go:985)——**90 天的 Let's Encrypt 证书,1/3 × 90 = 30 天,所谓"30 天续期"只是 1/3 比例在 90 天证书上的涌现结果**。Caddy 侧文档也这样描述:剩余约 1/3 寿命时续期是好习惯(modules/caddytls/automation.go:122-128)。

此外还有几层保险(certificates.go:115-183):

- **ARI 优先**(RFC draft "ACME Renewal Information"):CA 下发建议续期窗口,取随机时刻(certificates.go:122,128-134);到期前 `RenewCheckInterval` 即触发(:142-148)。续期时若同一 CA,经 ARI 的 "replaces" 机制声明替换哪张旧证书(config.go:954-962)。
- **紧急窗口 1/20**:即使 ARI 说不用续,寿命只剩 1/20 也要强续,防 ARI 实现有 bug 拖垮站点(certificates.go:156-161)。
- **绝对紧急**:寿命剩 1/50,或剩余时间 < 5×RenewCheckInterval(certificates.go:178-179)。

### 4.2 续期循环

后台维护协程 `maintainAssets`(maintain.go:43-85)随 `NewCache` 启动(cache.go:110),两个 ticker:续期检查默认 **10 分钟**一次(maintain.go:979,Caddy 可配 `renew_interval`,automation.go:65),OCSP 检查 1 小时(maintain.go:988)。panic 被捕获并递归重启自身,至多 10 次(maintain.go:47-56)。

`RenewManagedCertificates`(maintain.go:92-227)的核心纪律是**先只读扫描、出锁后执行**(maintain.go:99-105 的注释:读写锁内做网络操作会死锁,且 TLS-ALPN challenge 需要拿缓存写锁,maintain.go:161-163):

- 快到期 → 先查存储有没有人续过(→ reloadQueue,maintain.go:146-158),没有才进 renewQueue;
- On-demand 证书跳过定时维护(maintain.go:128-130,交给握手触发);
- renewQueue 里的任务经 `queueRenewalTask` 提交给 jobManager,名字 `renew_<域名>` 天然去重(maintain.go:243,async.go:40-46);on-demand 证书续期失败则直接从缓存移除(maintain.go:252-257)。

### 4.3 失败退避

非交互(后台)签发/续期都套 `doWithRetry`(async.go:98-149):重试间隔表从 1 分钟起步,逐步拉长到 6 小时,持续到 **maxRetryDuration = 30 天**(async.go:179-209)。两个细节:

- 30 天兜底的逻辑闭环:LE 证书 90 天寿命、剩 30 天时开始续,即使 CA 持续故障也能每天多轮重试撑满整个窗口;
- 30 天耗尽后的最后一句日志是 "final attempt; giving up",**返回 nil 而非 error**(async.go:139-145)——放弃是"成功结束"这一轮重试,下一轮 10 分钟扫描还会再来。

成功后 `reloadManagedCertificate` 把新证书原子换进缓存(config.go:489,maintain.go:263),OCSP 装订随之更新。

---

## 5. On-Demand 专节:ask 端点的防滥用设计

On-Demand TLS = 证书不为配置里写死的域名预签,而是**握手时**见到什么 SNI 就签什么(handshake.go:506 obtainOnDemandCertificate)。这天然是个"任何人对我的服务器任意 SNI 就能让我向 CA 请求证书"的放大器——攻击者可借你的服务器消耗 CA 配额、污染你的缓存。Caddy 的防线:

**第一道:必须配权限模块,否则直接拒绝启动签发。** automation policy 里 `on_demand` 为真时,若该策略是通配/catch-all 且未配 permission 模块,`makeCertMagicConfig` 直接报错:"on-demand TLS cannot be enabled without a permission module to prevent abuse"(modules/caddytls/automation.go:302-307);对显式列出的非通配 subject 且只用 internal issuer 的场景才豁免(:302 注释:internal issuer 不会给公共 PKI 施压)。app 启动时再检查一遍,漏配就打大字警告 "YOUR SERVER MAY BE VULNERABLE TO ABUSE"(tls.go:407-416)。

**第二道:每次签发/加载前问一次。** certmagic 侧入口 `checkIfCertShouldBeObtained`(handshake.go:478-499)依次过:域名是否够格拿证书、`DecisionFunc`(Caddy 注入的)、隐式 allowlist(ManageAsync 时写入,config.go:380-383)。Caddy 的 DecisionFunc 最终调用权限模块 `permission.CertificateAllowed`(automation.go:338),并把 ClientHello 里的来源 IP 带进日志方便审计(automation.go:324-335)。

**第三道(经典 `ask` 端点,现已弃用但仍是典型形态):**

```go
// modules/caddytls/ondemand.go:119-133,164-165(节选)
func (p PermissionByHTTP) CertificateAllowed(ctx context.Context, name string) error {
    ...
    qs := askURL.Query()
    qs.Set("domain", name)
    askURL.RawQuery = qs.Encode()
    ...
    if resp.StatusCode < 200 || resp.StatusCode > 299 {
        return fmt.Errorf("%s: %w %s - non-2xx status code %d",
            name, ErrPermissionDenied, askEndpoint, resp.StatusCode)
    }
```

要点:GET `?domain=example.com`,**2xx 即放行、其余一律拒绝**(ondemand.go:164-166);不跟随重定向(ondemand.go:180-182),HTTP 客户端 10 秒超时(:178-179);`ErrPermissionDenied`(ondemand.go:174)专门把"业务拒绝"和"网络错误"区分开——前者记 debug,后者记 error,因为只有后者值得运维介入(automation.go:339-355)。权限模块是注册在 `tls.permission` 命名空间的可插拔模块(ondemand.go:51),`ask` 只是它的一个内置实现(`tls.permission.http`,ondemand.go:97),新的 `permission` 写法替代了旧的 `ask` 字符串配置,两者混用直接报错(tls.go:283-285)。

**第四道:缓解的兜底。** 非配置域名的证书即使签成了,续期失败即从缓存移除(maintain.go:252-257),存储清理器(`CleanStorage`,maintain.go:649)定期扫掉过期资产,Caddy 侧 `keepStorageClean` 默认 24 小时一轮(tls.go:952-982,automation.go:78)。

---

## 6. 设计动机

**为什么默认全自动?** Caddyfile 的极简主义建立在"安全默认值"上:域名合法(`SubjectQualifiesForCert`)就直接给公网 CA 签,内部名/IP 自动落到 internal issuer 自签(tls.go:916-919 与 autohttps.go:323-333)。用户不做任何选择就得到可用且正确(自动 OCSP、自动 ARI、自动续期)的结果;想要手动加载证书的人反而是"高级用户",走 `tls cert_file key_file` 或 certificate loaders。代价是复杂度全部内化在 certmagic 里——cache、锁、challenge、重试、OCSP 各一个子系统。

**证书存储为什么抽象成 Storage 接口?** 因为它同时承担三件事:证书资产持久化、**跨实例互斥锁**(Locker 子接口,storage.go:129)、**challenge token 共享**(第 3.2 节)。后两者决定了"多副本部署下不重复签发"不需要任何额外组件——换上 Redis/S3/Consul 实现即可平滑获得集群能力。接口刻意简单:`Store/Load/Delete/List/Stat/Exists` + `Lock/Unlock`(storage.go:62 起),键即路径。落盘布局:`certificates/<issuerKey>/<域名>/<域名>.crt|.key|.json`(storage.go:220-251),`Safe()` 把 `*` 编码为 `wildcard_` 并剔除 `..` 防目录穿越(storage.go:274-280);Caddy 默认根在 `AppDataDir()`(`$XDG_DATA_HOME/caddy`,modules/../storage.go:122-160)。注意这个接口的"文件系统语义"是契约的一部分,注释明说不支持大文件、非流式(storage.go:29-36)。

**分布式锁的取舍。** 文件锁的正确性依赖"时间戳+stale 判定",注释坦承:锁变 stale 后互斥性不再完美,要么可能死循环(caddyserver/caddy#4448)要么放弃严格互斥,他们选了避免死循环的简单方案(filestorage.go:244-249)。这是一切无协调人锁的共性:用"最终总有一个人做成 + 双检复用结果"换"不引入额外基础设施"。配合签发幂等(锁内双检 config.go:598-601、续期前查盘 maintain.go:146-158),即使锁偶发失效,后果也只是偶尔多签一张证书,而不是错误状态。再看 challenge 侧:它没有用锁,而是把 token 放进共享存储让所有实例都能应答(solvers.go:634-650)——锁管"谁签",存储管"谁能答",分工干净。

---

## 7. FAQ 素材

1. **Q: 证书多久续一次?** 不是固定 30 天。默认剩余寿命 1/3 时续(certmagic maintain.go:985, certificates.go:214-224);90 天证书即 30 天。可用 `renewal_window_ratio` 调(automation.go:129)。ARI 可用时以 CA 下发的建议窗口优先(certificates.go:115-148)。
2. **Q: 续期失败会怎样?会丢站吗?** 退避重试持续 30 天(async.go:209);期间只要旧证书未过期就继续服务(on-demand 场景明确"still has time remaining, so serve it anyway",handshake.go:467-472)。
3. **Q: 多台 Caddy 用同一个域名会重复签发吗?** 配相同 Storage 就不会:`issue_cert_<域名>` 锁互斥(config.go:571),锁内双检(config.go:598),维护循环查盘复用别人续好的证书(maintain.go:146-158),challenge token 也共享(solvers.go:634)。
4. **Q: HTTP-01 为什么必须开 80 口?** ACME 规范固定端口(certmagic certmagic.go:471);自定义 http 端口会被写进 `AlternatePort` 转发场景使用(autohttps.go:835-838)。绑定失败但端口通时 certmagic 假设"有人在替我应答"(solvers.go:764-797)。
5. **Q: TLS-ALPN-01 是什么,什么时候用?** CA 直连 443 做 TLS 握手,ALPN 必须恰为 `acme-tls/1`(handshake.go:73-75);Caddy 在握手入口优先特判并回 challenge 证书。80 口不可用时它是默认后备(acmeclient.go:209-222)。
6. **Q: on_demand 需要什么前置条件?** 现在强制要求 permission 模块(通配/catch-all 无模块直接配置报错,automation.go:307);`ask` 端点是它的 HTTP 形态且已标记弃用(ondemand.go:46)。
7. **Q: 手动加载的证书也会被自动续期吗?** 不会。缓存按 `managed` 标记区分,随机淘汰时手工证书被豁免(cache.go:250),维护循环只处理 `cert.managed`(maintain.go:109)。
8. **Q: 缓存有上限吗?满了怎么办?** Caddy 默认 10000 张(tls.go:214-216);满了随机淘汰 managed 证书(cache.go:241-261),被淘汰的域名再次握手会因 `cacheAlmostFull`(≥90%)从存储重新加载(handshake.go:381-386)。
9. **Q: 换 CA(比如从 internal 到 Let's Encrypt)会怎样?** Caddy 按 subject+issuerKey 卸载旧证书并立即用新策略重管(tls.go:539-559,574)。
10. **Q: 内网域名/IP 也自动 HTTPS 吗?** 不够公网签发资格的 subject 自动落到 internal issuer 自签(tls.go:309-317 的默认 internal 策略;IP 在无显式策略时也归 internal,autohttps.go:323-327),浏览器信任需装 Caddy 的根证书。

## 8. 深挖素材

1. **certLoadWaitChans 与 obtainCertWaitChans 是两套 singleflight**:前者管"从盘加载进缓存"(handshake.go:300-344),后者管"向 CA 签发"(handshake.go:515-543);leader 结果通过 waiter 传播,follower 不再递归查缓存(handshake.go:320-324)。对比 Go 标准库 singleflight 的同构实现,可作并发专题素材。
2. **doWithRetry 的"放弃即成功"**:30 天重试耗尽后返回 nil(async.go:139-145),因为真正的重试引擎是外层 10 分钟维护循环;两层循环叠加后,一张证书的续期窗口实际被覆盖到过期前最后一刻。
3. **solverWrapper 与 activeChallenges**:进程内任意端口上的 HTTP/TLS 服务器都能替其他 server 应答 challenge,连 admin endpoint 都因此受益(acmeclient.go:228-242);tls.go:837-839 的 fallback 是同一机制的消费端。
4. **robustTryListen 的错误处理美学**:返回 `(nil, nil)` 表示"端口被占但有人听着,交给它"(solvers.go:705-715,764-779);还处理 fd 继承(solvers.go:732-764)与 Windows 上 `x:1234` 绑定冲突的怪癖(solvers.go:780-798)。
5. **GetConfigForCert 回调**:缓存里每张证书在维护时动态反查它该用哪份配置——因为缓存的寿命(数年)远长于任何一份配置(数小时),签 DNS challenge 的提供商都可能在两次续期之间换掉(cache.go:159-168 的注释)。这是理解"缓存与管理配置解耦"的钥匙。

---

## 9. 写作要点速查表

| # | 内容 | 位置 |
|---|------|------|
| 1 | 自动 HTTPS 第一阶段:扫域名+重定向 | modules/caddyhttp/autohttps.go:77(域名收集 150-168) |
| 2 | 第二阶段:服务器起完后才 Manage(防抢端口) | modules/caddyhttp/autohttps.go:869(注释 863-868) |
| 3 | 域名→automation policy 匹配(catch-all 兜底) | modules/caddytls/tls.go:905-920 |
| 4 | AP.Provision → certmagic.Config(默认 issuer) | modules/caddytls/automation.go:182,272(默认 issuer :479) |
| 5 | Manage 分桶批量 ManageAsync | modules/caddytls/tls.go:604(:629 批量调用) |
| 6 | on_demand 无 permission 模块即报错 | modules/caddytls/automation.go:302-307 |
| 7 | ask 端点实现:GET ?domain=,2xx 放行 | modules/caddytls/ondemand.go:119-169(:164 判定) |
| 8 | GetCertificate 注入 tls.Config | modules/caddytls/connpolicy.go:282-318 |
| 9 | HTTP challenge 在用户 handler 之前拦截 | modules/caddyhttp/server.go:695-698 + tls.go:809-851 |
| 10 | 缓存双索引 + NewCache 启动维护协程 | certmagic@v0.25.4/cache.go:49,55-58,110 |
| 11 | 缓存写入/随机淘汰(豁免手工证书) | certmagic@v0.25.4/cache.go:208-281(:250) |
| 12 | obtainCert:锁→双检→CSR→issuer 循环→落盘 | certmagic@v0.25.4/config.go:547-752(锁 :571,双检 :598) |
| 13 | 三种 challenge 装配与分布式 token 存储 | certmagic@v0.25.4/acmeclient.go:186-226;solvers.go:615-683 |
| 14 | 维护循环 + 1/3 续期阈值(10 分钟一轮) | certmagic@v0.25.4/maintain.go:43,92(:139 调 NeedsRenewal);certificates.go:214;maintain.go:985 |
| 15 | 重试表与 30 天上限 | certmagic@v0.25.4/async.go:179-209 |
| 16 | 握手取证书:缓存→singleflight→盘→签发 | certmagic@v0.25.4/handshake.go:272-420 |
| 17 | on-demand 签发(180s 超时+等待者) | certmagic@v0.25.4/handshake.go:506-576 |
| 18 | Storage 接口含 Locker/LockLeaseRenewer | certmagic@v0.25.4/storage.go:62,129,172 |
| 19 | 落盘布局 .crt/.key/.json + Safe() 防穿越 | certmagic@v0.25.4/storage.go:232-251,269-285 |
| 20 | 文件锁:原子建文件+stale 判定(取舍声明) | certmagic@v0.25.4/filestorage.go:174-269(:244-249) |

*(本报告所有行号:Caddy 侧对应 commit `56e3a88`;certmagic 侧对应 tag v0.25.4。)*
