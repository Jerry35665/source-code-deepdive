# 报告 F|账号、安全与工程文化

基线:nats-server @ 8f3f31b0366eca0d855d0750b7ca547eadd10eff(浅克隆,已检出)。最新提交本身就是一个安全修复:"[FIXED] Config reload disconnects operator mode clients sending an nkey (#8609)"。以下所有路径相对仓库根,行号均经实际 Read/Grep 核对。

## 0. 总览图

```
        operator/account/user 三层 JWT 链与签名校验路径
 ────────────────────────────────────────────────────────────────
   Operator claim(根,自签;ReadOperatorJWT 支持装饰/内联, server/jwt.go:27)
      │ op 私钥签名账号 claim
      ▼
   Account claim ──────► account resolver 分发(按需 + 过期重取):
      │                    Mem(sync.Map)  server/accounts.go:4211
      │  账号私钥或         URL(http GET) server/accounts.go:4235
      │  scoped signer      Dir(目录+NATS同步) server/accounts.go:4281
      ▼ 签用户 claim
   User claim + sig=Sign(nonce)  ──CONNECT──►  server 校验流水线:
                     1 jwt.DecodeUserClaims            server/auth.go:885
                     2 LookupAccount(issuer)           server/auth.go:1020
                     3 isTrustedIssuer(账号签发者)      server/auth.go:1027
                     4 acc.hasIssuer(用户签发者/作用域)  server/auth.go:1031
                     5 pub.Verify(nonce, sig)          server/auth.go:1103-1108
                     6 RegisterNkeyUser(权限注入)       server/auth.go:1127-1128

             nkey 认证的质询-应答时序(非 JWT 的裸 nkey)
 ────────────────────────────────────────────────────────────────
  client                                          server
     │ ── TCP 连接 ──────────────────────────────────► │
     │ ◄── INFO { nonce: 随机字节 } ────────────────── │ generateNonce  server/server.go:3294-3301
     │   sig = Ed25519_Sign(私钥, nonce)               │
     │ ── CONNECT { nkey(公钥), sig } ───────────────► │ s.nkeys 白名单查表  server/auth.go:916-922
     │                                                │ FromPublicKey(nkey).Verify(nonce, sig)
     │                                                │                server/auth.go:1195-1200
     │ ◄── +OK(注册账号/权限)/ -ERR 认证失败 ────────── │ RegisterNkeyUser server/auth.go:1205
```

公钥即身份:用户名就是 Base32 编码的 Ed25519 公钥,服务器永远不接触私钥,无需口令库;口令类凭证则是常量时间比较 `comparePasswords`(server/auth.go:1221)。服务器自身的集群身份也用 nkey(server.go:716-717),另生成 Curve 密钥对(xkey)用于服务器间加密消息,非 FIPS 构建才有(server/server.go:719-725)。

## 1. 认证谱系:一次 CONNECT 里的判定顺序

`processConnect` 先反序列化 CONNECT 选项;不在 operator 模式(`trustedKeys == nil`)时直接丢弃 JWT 字段(server/client.go:2361-2364),WebSocket 客户端还可能从 cookie/字段兜底取凭证(server/client.go:2342-2358)。随后统一入口 `checkAuthentication` 按 CLIENT/ROUTER/GATEWAY/LEAF 分派(server/auth.go:415-428),CLIENT 走 `isClientAuthorized`,顺序由作者注释明示(server/auth.go:435-437):

```go
// Check custom auth first, then jwts, then nkeys, then
// multiple users with TLS map if enabled, then token,
// then single user/pass.
if opts.CustomClientAuthentication != nil && !opts.CustomClientAuthentication.Check(c) {
	return false
}
if opts.CustomClientAuthentication == nil && !s.processClientOrLeafAuthentication(c, opts) {
	return false
}
```

`processClientOrLeafAuthentication`(server/auth.go:654)内部完整顺序:

1. 受信代理检查 `proxyCheck`(对代理签名再验一次 Ed25519,server/auth.go:677-680、1257-1275);
2. 未要求认证时,CLIENT 直接过、LEAF 注册到配置账号(server/auth.go:787-796);
3. operator 模式:必须携带可解码的用户 JWT(`DefaultSentinel` 可兜底),并做 claims 校验(server/auth.go:864-900);
4. nkeys 表:no_auth_user 命中且未带任何凭证时改用该 nkey;再按 `c.opts.Nkey` 查表并校验连接类型白名单(server/auth.go:905-923);
5. users 表:`tlsMap` 开启时用客户端证书的 DN 字面量/RDN 重排匹配用户名,替代 CONNECT 里的用户名(server/auth.go:926-984);否则用户名查表(server/auth.go:995-1001);
6. JWT 链:pinned 账号检查 → LookupAccount → 信任校验 → 作用域签名者 → nonce 验签 → 吊销/源 IP/时间窗(server/auth.go:1006-1125);
7. 裸 nkey 验签(server/auth.go:1176-1208);用户名+口令(server/auth.go:1210-1227);单 token、单用户口令(server/auth.go:1235-1242)。

各认证方式的凭证与信任根速查:

| 方式 | 客户端携带 | 服务器持有 | 信任判定点 |
|---|---|---|---|
| 匿名 | 无 | 无 | auth_required=false 即放行(server/auth.go:787-796) |
| 单 token | CONNECT.Token | 配置 token | comparePasswords(server/auth.go:1235-1236) |
| 单/多用户 | Username+Password | users 表 | 查表+常量时间比较(server/auth.go:995-1001、1221) |
| TLS 证书映射 | mTLS 证书 | tlsMap + users 表 | 证书 DN/RDN 匹配用户名(server/auth.go:926-984) |
| nkey | 公钥+nonce 签名 | nkeys 表(仅公钥) | Ed25519 验签(server/auth.go:1195-1200) |
| JWT(operator) | 用户 JWT+nonce 签名 | trustedKeys+resolver | 三级链校验(server/auth.go:1006-1125) |
| auth callout | 由上溯各方式失败后 | callout 服务账号 | 外部服务裁决 `$SYS.REQ.USER.AUTH`(server/auth_callout.go:30) |

认证通过后回到 `registerWithAccount`:把连接挂到账号、切换主题命名空间,施加账号级连接上限与配额(server/client.go:873-924,上限检查 906-915);任何路径都没绑定账号时回落全局账号 `$G`(server/client.go:2418-2420)。失败则 `authViolation`(server/client.go:2532)。注册回调把权限注入连接:`RegisterUser` 在持锁状态下套用 Permissions 并可设置连接截止时间(server/client.go:1008-1041),`RegisterNkeyUser` 同理(server/client.go:1046-1064)。MQTT 还能从 password 字段携带 JWT,且刻意等到验证通过才回填 `c.opts.JWT`,避免监控接口泄密(server/auth.go:854-861)。另有两个辅助机制:pinned_certs 对证书 SPKI 做 SHA-256 指纹白名单(server/auth.go:455-470);auth callout 把认证失败(或未命中配置)的连接委托给 `$SYS.REQ.USER.AUTH` 上的外部服务裁决,命中后还会对该主题追加 publish deny(server/auth.go:748-763;调用点 server/auth_callout.go:44、437)。

## 2. nkey:质询-应答与"公钥即身份"

INFO 中带有 `Nonce` 字段(server/server.go:127);仅当配置了 nkey/JWT 时才生成:`generateNonce` 填随机字节并缓存到 `c.nonce`(server/server.go:3294-3301)。客户端用私钥对 nonce 签名;签名是 base64 RawURL,失败回退 StdEncoding,然后只用公钥验证:

```go
sig, err := base64.RawURLEncoding.DecodeString(c.opts.Sig)
if err != nil {
	// Allow fallback to normal base64.
	sig, err = base64.StdEncoding.DecodeString(c.opts.Sig)
	if err != nil {
		c.Debugf("Signature not valid base64")
		return false
	}
}
pub, err := nkeys.FromPublicKey(c.opts.Nkey)
if err := pub.Verify(c.nonce, sig); err != nil {
	c.Debugf("Signature not verified")
	return false
}
```
(server/auth.go:1186-1203,有省略)

两个路径的验签对象不同:裸 nkey 用 `c.opts.Nkey` 重建公钥(server/auth.go:1195-1200);JWT 路径则从 claim 的 Subject(即用户公钥)重建(server/auth.go:1103-1108),`no_auth_user` 命中时豁免签名(server/auth.go:1181),bearer_token 同样跳过 nonce 验签并注释了理由(server/auth.go:1084-1088)。验签通过后 `buildInternalNkeyUser` 把 JWT 权限折叠成内部 NkeyUser 并注册(server/auth.go:1127-1128、server/client.go:1046-1064);配置式 nkey 用户直接查 `s.nkeys` 表(server/auth.go:916-922)。JWT 路径还叠加:账号过期、用户吊销列表、源 IP 白名单、时间窗(server/auth.go:1046-1053、1113-1125;吊销实现 server/accounts.go:3305-3310)。

## 3. JWT/operator:claims 解析、作用域签名与 account resolver

operator 模式由 `trustedKeys` 驱动(server/server.go:1627),`isTrustedIssuer` 检查账号 claim 的签发者(server/server.go:1597-1599)。账号侧两步:`verifyAccountClaims` 解码 + 验签发者 + 阻断性校验(server/server.go:2206-2220);`fetchAccount` 构建内部账号并注册,竞争时复用已注册账号并补一次 claim 更新(server/server.go:2224-2260)。

用户 claim 里的 `Issuer` 可以是账号的 scoped signer:`acc.hasIssuer` 命中后调用 `ValidateScopedSigner`,再用 `processUserPermissionsTemplate` 展开 mustache 模板(`{{subject()}}`、`{{account-name()}}`、`{{tag(x)}}` 等)生成最终权限,模板笛卡尔积上限 4096(server/auth.go:1031-1043;模板引擎 server/auth.go:479-619,上限常量 server/auth.go:473-477)。配额随注册写入连接:`applyAccountLimits` 取用户 JWT、作用域模板、账号与服务器全局限制的最小值(server/client.go:950-995)。

账号 claim 的验证三件事——解码、验签发者、阻断性校验——都收敛在这一个函数里:

```go
func (s *Server) verifyAccountClaims(claimJWT string) (*jwt.AccountClaims, string, error) {
	accClaims, err := jwt.DecodeAccountClaims(claimJWT)
	if err != nil {
		return nil, _EMPTY_, err
	}
	if !s.isTrustedIssuer(accClaims.Issuer) {
		return nil, _EMPTY_, ErrAccountValidation
	}
	vr := jwt.CreateValidationResults()
	accClaims.Validate(vr)
	if vr.IsBlocking(true) {
		return nil, _EMPTY_, ErrAccountValidation
	}
	return accClaims, claimJWT, nil
}
```
(server/server.go:2206-2220)

```
        account resolver 刷新回路
 ──────────────────────────────────────
  lookupOrFetchAccount(server/server.go:2080)
    ├─ 内存命中且未过期 ──► 直接返回
    ├─ IsExpired()(原子标志, server/accounts.go:3271)
    │    └─ updateAccount ─► resolver.Fetch ─► verifyAccountClaims
    │        (1 秒防抖, server/server.go:2119-2123)
    └─ 未注册 ─► fetchAccount ─► buildInternalAccount ─► registerAccount
```

三种 resolver:内存 `MemAccResolver`(sync.Map,server/accounts.go:4211-4228)、HTTP `URLAccResolver`(GET base_url+account,超时 DEFAULT_ACCOUNT_FETCH_TIMEOUT,server/accounts.go:4242-4277)、目录 + NATS 同步的 `DirAccResolver`(server/accounts.go:4281-4286)。取回超过 1 秒会打警告日志(server/server.go:2178-2182)。claim 更新入口 `UpdateAccountClaims` → `updateAccountClaimsWithRefresh`:整体重置 exports/imports、刷新签名密钥与加权映射(server/accounts.go:3480-3606),并把变更传播到依赖账号与其客户端(server/accounts.go:3743-3764);bearer token 是否放行由账号开关决定(server/accounts.go:3312-3315、server/auth.go:1050-1053)。

## 4. export/import:以 subject 映射实现服务间授权

账号 claim 应用循环把 Exports 逐条注册:Stream 导出或 Service 导出,后者带 Singleton/Streamed/Chunked 响应类型、延迟追踪采样、响应阈值(server/accounts.go:3613-3656)。Imports 循环先 `lookupAccount(i.Account)` 找到对端账号,再按 from/to 建立映射;`LocalSubject` 优先作为本地名,服务导入时甚至交换 from/to(server/accounts.go:3700-3738)。服务导入必须通过对端账号的授权检查,否则 `ErrServiceImportAuthorization`,并且导入前先做环检测:

```go
// First check to see if the account has authorized us to route to the "to" subject.
if !internal && !destination.checkServiceImportAuthorized(a, to, imClaim) {
	return ErrServiceImportAuthorization
}
// Check if this introduces a cycle before proceeding.
if err := a.serviceImportFormsCycle(destination, fromT); err != nil {
	return err
}
```
(server/accounts.go:1683-1694,有省略)

授权检查本体在 `checkServiceImportAuthorized`(server/accounts.go:3254-3262);`to` 为空时默认等于 `from`(server/accounts.go:1675-1677);环搜索上限 `MaxAccountCycleSearchDepth = 1024`(server/accounts.go:1703-1707)。导出方可用 `exportAuth` 限定请求账号、要求 token(server/accounts.go:1180-1204、1216-1267)。这套机制把"谁能调用谁的服务"完全编码进 subject 与 claim,服务器运行时只是执行者。

## 5. 权限模型:发布侧拒绝、订阅侧不创建

`setPermissions` 把 allow/deny 编译进各自的 sublist:publish 的 allow/deny 用可缓存 sublist,subscribe 用无缓存版本;subscribe 的 deny 同时保留解析结果 `c.darray` 供投递期过滤(server/client.go:1108-1206,关键行 1120-1133、1166-1194)。强制点有两个,方向不同:

- **发送侧(拒绝已发出但未投递的 PUB)**:`processInboundClientMsg` 中,若配置了 pub 权限而 `pubAllowedFullCheck` 不通过,直接 `pubPermissionViolation` 违规上报并丢弃(server/client.go:4386-4391;违规报告 server/client.go:5804)。检查走 pcache 缓存 + allow/deny sublist 匹配,并叠加动态回复检查(server/client.go:4209-4255)。
- **订阅侧(根本不创建兴趣)**:`canSubscribeInternal` 对 allow/deny sublist 做 Match(含队列名与 leaf 反向匹配),不通过则 SUB 直接失败、账号 sublist 里不留痕迹(server/client.go:3367-3414;违规报告 server/client.go:5813)。deny 的判定一目了然:

```go
// If we have a deny list and we think we are allowed, check that as well.
if allowed && c.perms.sub.deny != nil {
	r := c.perms.sub.deny.Match(subject)
	allowed = len(r.psubs) == 0

	if allowed && queue != _EMPTY_ && len(r.qsubs) > 0 {
		// If the queue appears in the deny list, then DO NOT allow.
		allowed = !queueMatches(queue, r.qsubs)
	}
}
return allowed
```
(server/client.go:3404-3413)

deny 通配符可能"事后"命中之后的具体订阅,因此引入投递期过滤器 `mperms`:仅当新订阅与 darray 中的 deny 条目冲突时才装载(server/client.go:3430-3444),`deliverMsg` 每条消息再查一次 `checkDenySub`(server/client.go:3797-3799)。response 权限是 request/reply 专用:配置时强制清空 blanket publish allow,默认每收件箱 1 条消息、2 分钟过期(server/auth.go:293-311、server/const.go:226-232);`deliverMsg` 把真实观察到的 reply 主题登记进 `c.replies` 并定期修剪(server/client.go:4021-4024、4142-4150),发布时只有登记在册且未超限的回复主题放行(server/client.go:4259-4274)。

## 6. TLS:reload 一等公民与一句话 Curve

TLS 全线支持热重载:`tlsOption.Apply` 热更新 info 中的 TLSRequired/TLSVerify(server/reload.go:234-255),`IsTLSChange()` 标记触发监听套接字重建(server/reload.go:57-58、253);总入口 `ReloadOptions` 完成 diff-then-apply,不可热更字段显式报错(server/reload.go:1427-1497、1541-1551);leafnode/cluster 的 TLSConfig 属可重载字段白名单(server/reload.go:941-950)。椭圆曲线偏好本身是配置项(CurveP256/384/521,server/opts.go:898、953-955)。Curve 一句话:nkeys 的 Curve 密钥(X25519)不是 TLS,而是服务器间消息端到端加密的 xkey,仅非 FIPS 构建生成(server/server.go:719-725);auth callout 的 XKey 也必须是合法 Curve 公钥(server/opts.go:4807)。

## 7. $SYS 事件:用 NATS 自身广播运维与账号事件

系统账号的导出/导入把 `$SYS` 主题注入每个账号(server/events.go:1595-1638、server/accounts.go:3601-3606)。事件发送统一走内部客户端的发送队列——本质就是"发一条 PUB"(server/events.go:763-768):

```go
func (s *Server) sendInternalMsg(subj, rply string, si *ServerInfo, msg any) {
	if s.sys == nil || s.sys.sendq == nil {
		return
	}
	s.sys.sendq.push(newPubMsg(nil, subj, rply, si, nil, msg, noCompression, false, false))
}
```
(server/events.go:763-768)

主题字典(server/events.go:43-69):

- 账号级连接/断连:`$SYS.ACCOUNT.<acc>.CONNECT` / `.DISCONNECT`(server/events.go:49-50);
- 账号 claim 按需取回:`$SYS.REQ.ACCOUNT.<acc>.CLAIMS.LOOKUP` 与打包 `$SYS.REQ.CLAIMS.PACK/LIST`(server/events.go:43-45);
- 账号 claim 变更:`$SYS.REQ.CLAIMS.UPDATE` 及新旧广播主题 `$SYS.REQ.ACCOUNT.<acc>.CLAIMS.UPDATE`、旧式 `$SYS.ACCOUNT.<acc>.CLAIMS.UPDATE`(server/events.go:46-56);
- 服务器级:`$SYS.SERVER.<id>.STATSZ / LAMEDUCK / SHUTDOWN`,以及发现用 `$SYS.REQ.SERVER.PING`(server/events.go:60-69)。

连接事件在认证通过后发布——`isClientAuthorized` 尾部显式调用 `accountConnectEvent`(server/auth.go:446-449),负载含账号、用户、JWT、签发者、标签、kind 等(server/events.go:2573-2615);断连事件被注释为"billing event"(server/events.go:2618-2620)。账号变更则是双向的:服务器订阅 `$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE` 的新旧两种主题接收 claim 推送(仅当 resolver 不是自跟踪更新时,server/events.go:1256-1268),同一条总线也承载 LAMEDUCK/SHUTDOWN 传播(server/events.go:1242-1255)。

## 8. 工程文化:零依赖、测试密度、发布纪律与 AI 政策

**依赖面**:`go.mod` 的 require 块只有 10 个依赖(server/go.mod:7-19),全部是 nats-io 自家生态(jwt/v2、nkeys、nuid、nats.go)、两个算法库(klauspost/compress、minio/highwayhash)、golang.org/x 三件套、TPM 支持与 Antithesis 无操作桩(go.mod:8)。DEPENDENCIES.md 逐条登记许可证(DEPENDENCIES.md:5-18)。这条纪律写进了贡献指南:"No additional external dependencies that aren't absolutely essential... we will be very critical of these"(CONTRIBUTING.md:34);同时"新功能没有测试覆盖不予接受"(CONTRIBUTING.md:32)。治理极简:GOVERNANCE.md 全文 3 行,指向 NATS 项目的总治理文档。

**测试组织**:server/ 下 75 个 `*_test.go` 与生产文件同目录同名(auth_test.go 23 个 Test 函数、accounts_test.go 73 个、client_test.go 104 个;抽样如 TestAuthCertMappedUserWithPassword server/auth_test.go:876、TestAuthProxyRequired server/auth_test.go:447)。专用基准 5 个——benchmark_publish_test.go、core_benchmarks_test.go、jetstream_benchmark_test.go、jetstream_meta_benchmark_test.go、raft_benchmark_test.go;fuzz 入口 3 个——parser_fuzz_test.go、server_fuzz_test.go、subject_fuzz_test.go。跨模块/集成测试独立成顶层 test/(38 个文件),如 operator_test.go、user_authorization_test.go(TestUserAuthorizationProto test/user_authorization_test.go:26)、client_auth_test.go、tls_test.go、cluster_tls_test.go。锁序约束单独写成 locksordering.txt(75 行)。错误处理同样是工程化产物:server/errors.json 声明式登记错误(常量/HTTP code/error_code/描述),`go generate` 生成 errors_gen.go("Generated code, do not edit",server/errors_gen.go:22)。

**测试组织**:server/ 下 75 个 `*_test.go` 与生产文件同目录同名(auth_test.go 23 个 Test 函数、accounts_test.go 73 个、client_test.go 104 个;抽样如 TestAuthCertMappedUserWithPassword server/auth_test.go:876、TestAuthProxyRequired server/auth_test.go:447)。专用基准 5 个——benchmark_publish_test.go、core_benchmarks_test.go、jetstream_benchmark_test.go、jetstream_meta_benchmark_test.go、raft_benchmark_test.go;fuzz 入口 3 个——parser_fuzz_test.go、server_fuzz_test.go、subject_fuzz_test.go。跨模块/集成测试独立成顶层 test/(38 个文件),如 operator_test.go、user_authorization_test.go(TestUserAuthorizationProto test/user_authorization_test.go:26)、client_auth_test.go、tls_test.go、cluster_tls_test.go。锁序约束单独写成 locksordering.txt(75 行)。错误处理同样是工程化产物:server/errors.json 声明式登记错误(常量/HTTP code/error_code/描述),`go generate` 生成 errors_gen.go("Generated code, do not edit",server/errors_gen.go:22)。

**发布与 AI 政策**:RELEASES.md 声明自 2.11 起遵循 6 个月发布周期、语义化版本、支持当前与前一个 minor 系列的修复(RELEASES.md:3-6)。贡献需 DCO 签名"法律姓名,不接受昵称"(CONTRIBUTING.md:46-48)。仓库根没有 AGENTS.md(全库检索仅命中 .github/workflows/claude.yml),但 AI 协作已是明文政策:CONTRIBUTING.md 设 "AI Policy" 一节——接受 AI 辅助贡献,但"不想和你的 AI 代理对话"(do not meat-proxy),且 AI 评审后"最终决定永远由人做出"(CONTRIBUTING.md:36-40);配套的 Claude Code 审查工作流复用 synadia-io/ai-workflows 共享 workflow,并为 backport/发布 PR 定制 review_focus 指令(.github/workflows/claude.yml:21、35)。CI 工作流共 10 个:tests、pull-requests、long-tests、nightly、mqtt-test、cov、vuln、release、stale-issues、claude。安全侧:README 披露 2025 年 4 月 Trail of Bits/OSTIF 第三方审计报告(README.md:66)与 security@nats.io 报告渠道(README.md:70-71)。

**与 Synadia/CNCF 的现状(如实一句)**:README 开篇即说 "NATS is part of the Cloud Native Computing Foundation (CNCF)",拥有 40+ 客户端语言实现(README.md:5);仓库仍托管在 nats-io 组织下,而 nightly 镜像发布在 synadia/nats-server Docker 仓库(RELEASES.md:9),Synadia 仍是主要商业背书方。

## 9. 读码路线(按这篇报告的论证顺序)

1. 先读 `server/client.go:2293`(`processConnect`)看 CONNECT 如何落地,注意 2361-2364 的 JWT 丢弃;
2. 再读 `server/auth.go:415`(`checkAuthentication`)与 `:654`(`processClientOrLeafAuthentication`)通读判定顺序;
3. 跳到 `server/server.go:3294` 看 nonce 生成,回 `server/auth.go:1176` 看裸 nkey 验签、`:1006` 看 JWT 链;
4. `server/client.go:873`(`registerWithAccount`)与 `:1008/:1046`(两个注册回调)看认证结果如何变成连接状态;
5. `server/accounts.go:3480`(`updateAccountClaimsWithRefresh`)看一条账号 claim 如何变成 exports/imports/mappings;
6. `server/accounts.go:4211-4286` 三种 resolver,对照 `server/server.go:2080-2260` 的查找/取回/验证三段式;
7. `server/client.go:1108`(`setPermissions`)看权限如何编译成 sublist,再跳 `:3367`、`:4364` 看两个强制点;
8. `server/events.go:43-69` 的主题字典加 `:763` 的 sendInternalMsg,理解 $SYS 的自举;
9. `server/reload.go:1427`(`ReloadOptions`)沿 diff-apply 路径看 TLS 热更新;
10. 最后看 `server/go.mod` 与 `CONTRIBUTING.md:25-48`,理解约束这套代码的文化。

## 10. 设计动机(为什么这么做)

1. **为什么 decentralized JWT**:权限数据彻底离开服务器配置文件——operator 私钥签账号 claim,账号私钥/scoped signer 签用户 claim,服务器只需内置信任 operator 公钥(server/server.go:1627),账号 claim 经 mem/URL/dir resolver 按需取回、过期自动刷新(server/accounts.go:4211-4286、server/server.go:2080-2099),权限变更无需触碰任何服务器,天然多租户与多集群一致。
2. **为什么 nkey 公钥即身份**:身份=Ed25519 公钥,免口令存储、免证书 PKI;服务器只握公钥表,认证以服务器 nonce 的签名为凭,重放无效(server/server.go:3294-3301、server/auth.go:1195-1203);同一 nkey 又是 JWT 的 Subject,把配置式认证与去中心化 JWT 统一在同一密钥空间(server/auth.go:1103-1108)。
3. **为什么权限做进协议层而非库**:客户端库鱼龙混杂,唯一可信执行点是服务器——PUB 在 `processInboundClientMsg` 被拒(server/client.go:4386-4391),SUB 直接不注册兴趣(server/client.go:3367-3414);deny 与通配符的语义边界再由投递期过滤兜底(server/client.go:3430-3444、3797-3799),权限因此对 40+ 种客户端语言一视同仁。
4. **为什么零依赖**:作为跑在边缘乃至树莓派的基础设施(README.md:5),依赖面即攻击面与编译面——10 个依赖的 go.mod(server/go.mod:7-19)让第三方审计(Trail of Bits,README.md:66)与交叉编译、FIPS 构建可控,贡献指南更是把"拒绝新依赖"写成硬规矩(CONTRIBUTING.md:34)。
5. **为什么 $SYS 走 NATS 自身**:运维事件就是 PUB 到 `$SYS.ACCOUNT.<acc>.CONNECT`(server/events.go:49-50、2573-2615),零新协议、天然按账号订阅(计费场景),随 NATS 集群路由到任意监控点;claim 更新与 resolver 取回也复用同一条请求/回复总线(server/events.go:43-56),自举无旁路。
6. **为什么 reload 是一等公民**:权限与 TLS 变更频繁,tlsOption 的 IsTLSChange 精确圈定需重建的监听器(server/reload.go:57-58、253),diff-then-apply 让不可热更字段显式报错(server/reload.go:1541-1551)——本仓库基线的最新提交正是 operator 模式 reload 的边角修复。
7. **为什么 response 权限做成 m/m 收件箱**:request/reply 的回复主题是动态的,静态 allow 列表无法表达"只能回最近请求方";`c.replies` 只登记真实观察到的收件箱,默认 1 条/2 分钟把越权面压到最小(server/client.go:4021-4024、4259-4274、server/const.go:226-232)。
8. **为什么 auth callout 存在**:operator 模式下把"未命中声明式规则"的连接委托给外部服务裁决(`$SYS.REQ.USER.AUTH`,server/auth_callout.go:30、44),既保住 JWT 的分发模型,又给企业级外部 IdP 留口子——扩展点仍长在 NATS 总线上。

## 11. 写作素材清单

1. `server/auth.go:435-437` — 认证顺序的作者注释(custom → JWT → nkey → TLS map → token → user/pass)。
2. `server/auth.go:864-900` — operator 模式强制用户 JWT 与阻断性校验。
3. `server/auth.go:1103-1111` — JWT 用户公钥对 nonce 的 Ed25519 验签。
4. `server/auth.go:1186-1203` — 裸 nkey 验签(含 base64 回退)。
5. `server/server.go:3294-3301` — INFO nonce 的生成与缓存。
6. `server/client.go:2361-2364、2418-2420` — 非 operator 丢弃 JWT;未认证回落全局账号。
7. `server/auth.go:1031-1043` + `473-477` — scoped signer 模板展开与 4096 上限。
8. `server/accounts.go:4211-4286` — Mem/URL/Dir 三种 account resolver。
9. `server/server.go:2080-2099、2116-2130` — 过期即重取 + 1 秒防抖。
10. `server/accounts.go:1683-1696` — 服务导入的对端授权与环检测。
11. `server/client.go:4386-4391` — 发送侧权限拒绝点(pubPermissionViolation)。
12. `server/client.go:3367-3414` — 订阅侧 allow/deny 判定(不创建订阅)。
13. `server/client.go:4021-4024、4259-4274` — response 权限的收件箱登记与放行。
14. `server/events.go:49-50、2573-2615` — $SYS 账号连接事件主题与负载。
15. `server/reload.go:234-255、1427-1497` — TLS 热更新与 ReloadOptions 总入口。
16. `server/go.mod:7-19` + `CONTRIBUTING.md:32-40` — 10 依赖清单、测试/依赖纪律与 AI 政策。
