# 第 02 章 · 自动 HTTPS:证书旅程与分布式锁

> 基线:commit `56e3a88`。行号以 modules/caddyhttp/autohttps.go、modules/caddytls/ 为准;certmagic 引用标注 `certmagic@v0.25.4/`(go.mod 依赖 v0.25.4,仓库无 vendor)。

## 2.0 全景:域名从配置到证书

```
配置里的域名 → autohttps.go:77 扫描收集+建 HTTP→HTTPS 重定向
  → caddytls 按域名匹配 automation policy(tls.go:905)翻译成 certmagic.Config(automation.go:272)
  → 所有服务器启动后才 Manage(autohttps.go:869,防 certmagic 抢 80/443)
  → certmagic obtainCert(config.go:547):存储已有则 no-op
     → 取 issue_cert_<域名> 分布式锁 → 锁内双检 → CSR → 逐 issuer 签发
     → certificates/<issuer>/<域名>/{.crt,.key,.json} 落盘+进内存缓存
  → 握手时 connpolicy.go:282 的 GetCertificate 按 SNI 查缓存(精确→逐标签通配)
```

## 2.1 分布式锁:互斥下沉到共享存储

**不选主,互斥下沉**:多实例竞争同一域名时,`issue_cert_<域名>` 文件锁(原子建文件+5 秒 stale 判定,filestorage.go:244 坦承"锁失效后互斥不再完美,选了避免死循环的简单方案")+锁租约续期(config.go:509)+**锁内双检**(拿锁后再查存储,可能别人已签好)。challenge 走另一路:token JSON 存共享存储(solvers.go:634),任何实例都能代答挑战——**锁管"谁签",存储管"谁能答"**。默认 issuer:LE,配了邮箱追加 ZeroSSL(automation.go:479-488)。

## 2.2 续期与 On-Demand

续期阈值是剩余寿命 **1/3**(certmagic@v0.25.4/maintain.go:985+certificates.go:214-224)——90 天证书才有"30 天"的说法;后台重试 30 天上限(async.go:209);缓存双索引:哈希→证书+SAN→哈希(cache.go:55-58),随机淘汰但豁免手工证书(:250);Caddy 缓存容量默认 10000(tls.go:214-216)。**On-Demand**:通配/catch-all 场景无 permission 模块直接配置报错(automation.go:307);ask 端点=GET `?domain=`,2xx 放行(:164),不跟重定向、10s 超时——**防"用我的服务器免费签任意域名"的滥用闸**;维护由握手触发而非定时器(handshake.go:283-288),续期时未过期则边续边服务(:806-809)。

## 2.3 challenge 与存储

三种 challenge:HTTP challenge 在一切用户 handler **之前**拦截(server.go:695-698→tls.go:809);TLS-ALPN 特判 ALPN 恰为 `acme-tls/1`(handshake.go:73-75);DNS challenge 一旦配置则**独占**(acmeclient.go:223-226);80 口绑定失败且端口通时假设别人能代答(solvers.go:764-797)。**Storage 接口一职三能**(storage.go:62,:129):持久化+Locker+challenge token——接口的多能复用。

## 2.4 设计动机

1. **为什么默认全自动**:证书运维是 HTTPS 时代最大的摩擦——把它做成"写域名就行"是产品定义本身;
2. **锁下沉共享存储**:多实例/多机部署下 ACME 账号与签发互斥,独立锁服务(数据库/选主)违反零依赖——存储本来就是共享点;
3. **1/3 续期阈值**:CA 端传播+OCSP 稳定的经验值;阈值自适应证书寿命(短证书按比例早续);
4. **ask 端点**:On-Demand 的滥用面(任意域名签发)被一个"外部仲裁"收缩——机制最小,责任外移。

## 2.5 FAQ

**Q1:两台 Caddy 会不会重复签发?**
分布式锁+锁内双检(config.go:509,:547):锁失效时"重复"而非"失败"(:244 的取舍自述)。

**Q2:证书什么时候续?**
剩余寿命 1/3(maintain.go:985):90 天→剩 30 天续。

**Q3:On-Demand 没配 ask 会怎样?**
配置直接报错(automation.go:307)——滥用闸是强制的。

**Q4:DNS challenge 与 HTTP 能共存吗?**
DNS 一旦配置独占(:223-226):通配符证书只能 DNS。

**Q5:80 端口被占还能 HTTP challenge 吗?**
绑定失败且端口通→假设同机别的实例能代答(:764-797)。

**Q6:缓存的 10000 上限淘汰谁?**
随机但豁免手工证书(cache.go:250):自动证书可再生。

**Q7:GetConfigForCert 干什么?**
缓存里的证书(寿命数年)反查当前策略(配置数小时):tls.go:202-204。

**Q8:续期失败会打断服务吗?**
不会:30 天重试窗内边续边服务(:806-809);耗尽才失败(:139-145)。

**Q9:证书落盘布局?**
certificates/<issuer>/<域名>/{.crt,.key,.json}——按 issuer 分域。

**Q10:内部证书(pki)呢?**
internal issuer 走本地 CA(非 ACME):与 certmagic 同存储结构。

## 2.6 小结与深挖方向

本章结论:**自动 HTTPS="配置即证书需求+锁下沉共享存储+1/3 阈值续期+ask 闸"**。深挖:

1. 文件锁 5 秒 stale(:244)在分布式时钟漂移下的正确性;
2. DNS challenge 独占(:223-226)与多 issuer 的组合策略;
3. On-Demand ask 的响应缓存与抖动;
4. 缓存随机淘汰(:250)在巨量域名下的命中率;
5. ECH/短证书(ACME 新趋势)对 1/3 阈值的影响。

> 下一章:HTTP 栈与路由——显式顺序与预编译链。
