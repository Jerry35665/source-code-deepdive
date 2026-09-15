# G 篇 · IAM 与服务账号:MinIO 的身份与授权内幕

> 《MinIO 深读》卷二 第 1 章
> 调研对象:minio/minio @ commit **7aac2a2**(2026-02-11,"update README.md format and clarify state of the project")
>
> **版本注意**:该 commit 中 IAM 代码**不在 `internal/iam/`**,而是整体位于 `cmd/`(iam.go / iam-store.go / iam-object-store.go / iam-etcd-store.go);策略引擎也不在仓库内,而是外部依赖 `github.com/minio/pkg/v3 v3.1.3`(go.mod:64,源码在 minio/pkg 仓库的 `pkg/policy/`)。本文仓库内论断均标注 `文件:行号`(已用 grep/Read 核对);minio/pkg 部分以"函数级"引用并注明版本,不给可能漂移的行号。

---

## 1. 全景:一次 S3 请求的鉴权链

MinIO 对每个 API 请求做两件事:**认证(你是谁)** 和 **授权(你能不能做)**。签名校验、凭证解析、策略评估三段串联,任何一环失败即返回 S3 错误码。

```
  S3 请求 (Authorization: AWS4-HMAC-SHA256 Credential=...)
      │
      ▼
┌───────────────────────────────────────────────────────────────────┐
│ ① 请求类型识别  getRequestAuthType        cmd/auth-handler.go:124 │
│    signed/presigned V4 | V2 | 匿名 | POST策略 | 流式签名          │
└───────────────────────────────────────────────────────────────────┘
      │
      ▼
┌───────────────────────────────────────────────────────────────────┐
│ ② 签名验证(认证) authenticateRequest    cmd/auth-handler.go:357 │
│    isReqAuthenticated → reqSignatureV4Verify     :559 / :546     │
│    (HMAC 重算比对 + Content-Sha256 校验)                          │
└───────────────────────────────────────────────────────────────────┘
      │
      ▼
┌───────────────────────────────────────────────────────────────────┐
│ ③ 凭证解析  getReqAccessKeyV4     cmd/signature-v4-parser.go:52  │
│    → checkKeyValid            cmd/signature-v4-utils.go:148      │
│      ├─ root 凭证? → globalActiveCred(即 owner)                  │
│      ├─ 否则 globalIAMSys.CheckKey   cmd/iam.go:1843             │
│      │    (内存缓存命中;未命中则按需 LoadUser 从对象存储加载)     │
│      ├─ 校验 SessionToken 的 JWT claims(auth-handler.go:278)     │
│      └─ 判定 owner;带 sessionPolicy 则强制降级 owner :186-188    │
└───────────────────────────────────────────────────────────────────┘
      │
      ▼
┌───────────────────────────────────────────────────────────────────┐
│ ④ 策略评估(授权) authorizeRequest        cmd/auth-handler.go:418│
│    匿名请求 → globalPolicySys(桶策略)      :431-464             │
│    认证请求 → globalIAMSys.IsAllowed       :480-492              │
│                                                         cmd/iam.go:2492
│      ├─ 配置了 OPA/AuthZ 插件 → 完全交给外部    :2494-2500       │
│      ├─ IsOwner(root) → 无条件放行              :2502-2504       │
│      ├─ STS 临时凭证 → IsAllowedSTS             :2508-2513       │
│      ├─ 服务账号   → IsAllowedServiceAccount    :2517-2522       │
│      └─ 普通用户   → 合并策略后 IsAllowed        :2526-2537      │
└───────────────────────────────────────────────────────────────────┘
      │
      ▼
   Allow → handler 继续处理;Deny/无匹配 → ErrAccessDenied
```

串联入口是 `checkRequestAuthTypeCredential`(cmd/auth-handler.go:522-536):先 `authenticateRequest` 后 `authorizeRequest`,两段都过才放行。注意匿名请求走的是**桶策略系统**(`globalPolicySys`,cmd/bucket-policy.go:49),与 IAM 用户策略是两套并行的评估器。

---

## 2. 存储专节:IAM 对象在 XL 上的存放、加载与缓存失效

### 2.1 对象布局:全部是 `.minio.sys` 桶里的普通对象

IAM 没有专门的存储引擎——它直接复用对象层,把每条 IAM 记录存成 `.minio.sys` 桶(minioMetaBucket,cmd/object-api-utils.go:59)下的一个小 JSON 对象,路径前缀为 `config/iam`(minioConfigPrefix,cmd/config.go:36;iamConfigPrefix,cmd/iam-store.go:49)。分布式部署下对象层天然多副本、强一致,IAM 也就"免费"获得了多节点共享存储——这就是"镜像到对象存储的 IAM 存储桶"的含义。

目录结构(cmd/iam-store.go:52-83):

```
.minio.sys/config/iam/
├── format.json                      # 格式版本标记(:83)
├── users/<accessKey>/identity.json  # 内部用户凭证(:74)
├── service-accounts/<key>/identity.json  # 服务账号(:55)
├── sts/<key>/identity.json          # STS 临时凭证(:64)
├── groups/<group>/members.json      # 组成员(:80)
├── policies/<name>/policy.json      # 策略定义(:77)
└── policydb/{users,groups,sts-users,service-accounts}/<name>.json  # 策略映射(:67-71)
```

路径拼接逻辑:`getUserIdentityPath`(cmd/iam-store.go:105-116)按用户类型选前缀;`getPolicyDocPath`(:141-143);`getMappedPolicyPath`(:145-157,LDS 用户映射单独放 `policydb/sts-users/`)。写入走通用 `saveConfig`,即对 `.minio.sys` 的一次 `PutObject`(cmd/config-common.go:73-85);开启 KMS 后先 `config.EncryptBytes` 再落盘(cmd/iam-object-store.go:90-97)。

记录的三种载荷类型(cmd/iam-store.go:160-225):

```go
// cmd/iam-store.go:160
type UserIdentity struct {
    Version     int              `json:"version"`
    Credentials auth.Credentials `json:"credentials"`
    UpdatedAt   time.Time        `json:"updatedAt"`
}
```

`MappedPolicy`(:183-187)是"策略名集合"(逗号分隔);`PolicyDoc`(:220-225)在策略外层包了创建/更新时间戳,其 `parseJSON`(:260-275)同时兼容 2021 年 12 月前后的新旧两种磁盘格式,避免迁移。凭证结构 `auth.Credentials` 内含 `ParentUser`、`Claims` 等派生账号关键字段(internal/auth/credentials.go:113-129)。

### 2.2 读取路径:全量缓存 + 按需补载

**内存缓存** `iamCache` 持有 7 张表:策略文档、内部用户、用户→策略映射、STS 凭证(按需)、STS→策略、组、组成员反查表、组→策略(cmd/iam-store.go:288-311)。注释明说:"STS accounts are loaded on demand and not via the periodic IAM reload"(:299-303)。

**启动与周期全量加载**:`IAMSys.Init` → `initStore` 选择后端(cmd/iam.go:175-191,无 etcd 则 `newIAMObjectStore`)→ `Load`(cmd/iam.go:210-244)→ `LoadIAMCache`(cmd/iam-store.go:643-736)。对象存储后端走 `loadAllFromObjStore`(cmd/iam-object-store.go:556):先 `listAllIAMConfigItems` 递归 `Walk` 列出 `.minio.sys/config/iam/` 下全部对象(:877-911,Walk 调用在 :886),再用 32 路并发批量加载(:590 `count := 32`)。默认刷新周期 10 分钟(cmd/globals.go:108),实际间隔在 `[0.5x, 1.5x)` 区间随机抖动以错峰(cmd/iam.go:458-462)。

**缓存失效的三道防线**:

1. **全量替换带时间戳保护**——只有当 `cache.updatedAt.Before(loadedAt)`(即加载期间无人写过内存缓存)时才整体替换,否则放弃本轮、等下个周期,防止旧数据覆盖新写入(cmd/iam-store.go:713-733);
2. **写路径即时更新**——所有 IAM 写操作先落盘再同步更新本节点缓存,并**主动通知其他节点重载**:`notifyForUser` 在存储无 watch 能力时通过 `globalNotificationSys.LoadUser` 逐节点推送(cmd/iam.go:737-747),组同理(:1885-1894);
3. **读路径按需补载**——请求带着缓存里没有的 accessKey 进来时,`CheckKey`(cmd/iam.go:1843-1876)触发 `store.LoadUser`(cmd/iam-store.go:2907-3012):singleflight 合并并发加载(:2979-2983),一次把"该账号本身 + 父用户 + 策略映射 + 策略文档"连带装进缓存(:2910-2970)。这正是 STS 账号按需进 `iamSTSAccountsMap` 的通道。

watch 机制只有 etcd 后端有(`iamStorageWatcher` 接口,cmd/iam-store.go:628-630;etcd 实现 `IAMEtcdStore.watch`,cmd/iam-etcd-store.go:450-500)。**对象存储后端没有 watch**,跨节点同步靠"写后 peer 通知 + 10 分钟兜底轮询"两条腿。另外每小时跑一次 LDAP/OpenID 失效凭证清扫(cmd/iam.go:484-495,实现在 :1444-1510)。

### 2.3 一致性代价

对象存储后端的 IAM 写入是单对象 PutObject,没有跨 IAM 记录的事务;跨节点可见性依赖通知(可能丢)与轮询(分钟级延迟)。MinIO 用 `UpdatedAt` 时间戳与"宁可重读不可陈旧"的缓存替换策略来收敛,但**多节点间策略变更存在短暂窗口**(最长约一个刷新周期),这是"对象存储当 IAM 库"这一设计选择的固有折衷。

---

## 3. 策略引擎专节:JSON 结构、评估顺序与条件键

### 3.1 策略文档结构(与 AWS IAM 兼容)

引擎在外部包 minio/pkg v3.1.3 的 `pkg/policy/`(go.mod:64)。顶层结构:

```
Policy { ID string; Version string; Statements []Statement }
Statement {
    SID          ID                  `json:"Sid,omitempty"`
    Effect       Effect              `json:"Effect"`          // "Allow" | "Deny"
    Actions      ActionSet           `json:"Action"`          // s3:* / s3:GetObject ...
    NotActions   ActionSet           `json:"NotAction,omitempty"`
    Resources    ResourceSet         `json:"Resource,omitempty"`
    NotResources ResourceSet         `json:"NotResource,omitempty"`
    Conditions   condition.Functions `json:"Condition,omitempty"`
}
```

仓库内的消费方式:`PolicyDBGet` 取出用户(及其组)映射的策略名列表,`MergePolicies` 从缓存逐个取出 `PolicyDoc.Policy` 合并(cmd/iam-store.go:1588-1630,缺失的策略会回源补读),最后调 `Policy.IsAllowed`。多个策略名在映射里就是逗号分隔字符串(`MappedPolicy.toSlice`,cmd/iam-store.go:200-209)。

### 3.2 评估顺序:显式 Deny 永远赢

`policy.Policy.IsAllowed`(minio/pkg v3.1.3 `pkg/policy/policy.go`)的骨架:

```go
// minio/pkg v3.1.3 pkg/policy/policy.go(节选,函数级引用)
func (iamp Policy) IsAllowed(args Args) bool {
    // 1. 先扫全部 Deny 语句:任何一条命中 → 立即 false
    for _, statement := range iamp.Statements {
        if statement.Effect == Deny && statement.IsAllowed(args) {
            return false
        }
    }
    if args.DenyOnly { return true }   // "只查有没有 Deny"模式
    if args.IsOwner  { return true }   // root 无视策略
    // 2. 再找 Allow 语句:任一命中 → true
    for _, statement := range iamp.Statements {
        if statement.Effect == Allow && statement.IsAllowed(args) {
            return true
        }
    }
    return false                        // 3. 默认拒绝
}
```

三层语义:**deny 优先 → 默认拒绝 → root 豁免**。`DenyOnly` 是个特殊入参(cmd/iam.go:2492 的调用方在 auth-handler.go:465-479 传入):用于"只检查是否存在 Deny"的预判,例如带版本删除对象前先确认没有 `s3:DeleteObjectVersion` 的显式拒绝。

单条 `Statement.IsAllowed`(minio/pkg v3.1.3 `pkg/policy/statement.go`)依次校验:Action 匹配(或 NotAction 不匹配)→ 资源匹配(把 `BucketName/ObjectName` 拼成 `/bucket/object` 与 `Resource` 通配比对)→ `Conditions.Evaluate(条件值)`;最终经 `Effect.IsAllowed` 包装——对 Deny 语句结果取反。所以"Deny 语句命中"在 Policy 层表现为"该条不允许通过"。

### 3.3 条件键:请求侧的取值表

策略里写的条件键(`aws:SourceIp`、`s3:prefix` 等)能成立,靠请求侧构造的键值表。MinIO 在 `getConditionValues`(cmd/bucket-policy.go:78-200)把请求上下文展开成 `map[string][]string`:

- 通用键:`CurrentTime`、`EpochTime`、`SecureTransport`、`SourceIp`、`UserAgent`、`Referer`、`signatureversion`、`authType`(:117-141 附近);
- 身份键:派生凭证会把 `userid/username` 替换为 **ParentUser**(cmd/bucket-policy.go:87-89),`principaltype` 取值 Anonymous/User/AssumedRole/Account(:91-98);
- 对象标签键:动态生成 `ExistingObjectTag/<k>`、`RequestObjectTag/<k>`、`RequestObjectTagKeys`(:146-158);
- 对象锁键:`ObjectLockMode`、`ObjectLockLegalHold`、`ObjectLockRetainUntilDate`(:160-170)。

条件函数(StringEquals/IPAddress/DateGreaterThan 等)与"每个 Action 允许哪些条件键"的白名单校验(策略保存时拒绝非法组合)都在 minio/pkg 的 condition 子系统里完成;仓库内的入口是策略校验 `sessionPolicy.Validate()`(cmd/iam.go:1080-1084)与 `policy.ParseConfig`(cmd/iam.go:2392)。

---

## 4. 服务账号专节:派生账号的策略合并语义

服务账号(service account,`svcUser`)是"挂在某个真实身份下的子钥匙":它有自己的 accessKey/secretKey,但权限完全由父身份 + 可选的内嵌会话策略决定。类型判定很直接(internal/auth/credentials.go:162-165):`ParentUser != ""` 且 Claims 里有 `sa-policy` 键即为服务账号。

### 4.1 创建:两个 claim 决定权限模式

`NewServiceAccount`(cmd/iam.go:1063-1155)把关键信息全部写进凭证的 JWT claims:

```go
// cmd/iam.go:1102-1110
m := make(map[string]any)
m[parentClaim] = parentUser                    // "parent"(sts-handlers.go:77)
if len(policyBuf) > 0 {                        // 创建时带了内嵌策略
    m[policy.SessionPolicyName] = base64.StdEncoding.EncodeToString(policyBuf)
    m[iamPolicyClaimNameSA()] = embeddedPolicyType   // "embedded-policy"
} else {
    m[iamPolicyClaimNameSA()] = inheritedPolicyType  // "inherited-policy"
}
```

两种模式(cmd/iam.go:78-79):**inherited**(跟随父策略,父策略变更立即生效)与 **embedded**(内嵌策略随凭证固化)。内嵌策略大小上限 4096 字节(cmd/iam.go:83,超限检查 :1089-1091);过期时间必须在 15 分钟到 365 天之间(cmd/iam-store.go:87-88,校验 :1140-1146)。

### 4.2 评估:parent claim 校验 + 三段合并

`IsAllowedServiceAccount`(cmd/iam.go:2193-2290)的完整决策链:

1. **防提权校验**(:2195-2212):session token 里的 `parent` claim 必须与后端查到的 ParentUser 一致,缺失或不等直接拒绝——防止泄露的他人口令"拓宽特权"。
2. **父身份特权直通**(:2214,2221-2223):root 派生的服务账号默认全放行。
3. **取父策略**(:2225-2245):优先级为 RoleARN 绑定的策略 → 父用户的 PolicyDB 映射 → 父身份 JWT 里的 policy claim(OpenID 场景兜底)。
4. **无策略即拒绝**(:2249):防御性设计,不依赖默认放行。
5. **合并评估**(:2253-2289):

```go
// cmd/iam.go:2278-2289(节选)
if saPolicyClaimStr == inheritedPolicyType {
    return isOwnerDerived || combinedPolicy.IsAllowed(parentArgs)   // 纯继承
}
hasSessionPolicy, isAllowedSP := isAllowedBySessionPolicyForServiceAccount(args)
if hasSessionPolicy {
    return isAllowedSP && (isOwnerDerived || combinedPolicy.IsAllowed(parentArgs))
}
return (isOwnerDerived || combinedPolicy.IsAllowed(parentArgs))
```

即:**embedded 模式 = 内嵌策略 AND 父策略双重约束(交集)**;inherited 模式只看父策略。即使内嵌策略放行,父策略的 Deny 依然一票否决——因为 `isAllowedSP && combinedPolicy.IsAllowed` 两侧都要过,而每一侧内部又是 deny 优先。

### 4.3 会话策略评估的三个细节

`isAllowedBySessionPolicyForServiceAccount`(cmd/iam.go:2372-2426):

- **空策略特例**(:2399-2408):`null`/`{}`/`{"Statement":null}` 视为"没有会话策略"(Console 创建时发送 null 表示继承父策略),返回 `hasSessionPolicy=false`;
- **owner 强制降级**(:2420-2422):`sessionPolicyArgs.IsOwner = false`——即使父是 root,会话策略也必须实质评估,root 特权不能穿透内嵌策略;
- **DenyOnly 复位**(:2414-2419 注释):会话策略存在时必须"正向证明允许",而不是只排除 Deny。

配套读取接口 `getServiceAccount`(cmd/iam.go:1248-1276)负责把 base64 的 embedded 策略解码返回给管理端;`UpdateServiceAccount`(cmd/iam.go:1166-1178)可改策略/密钥/状态/过期。服务账号不能再生成 STS 临时凭证(cmd/sts-handlers.go:218-219 的 `user.IsTemp() || user.IsServiceAccount()` 拦截),STS 的"套娃"到此为止。STS 临时账号(`IsAllowedSTS`,cmd/iam.go:2295-2370)走同样的三段式:取策略 → 合并 → 会话策略取交集(cmd/iam.go:2362-2369)。

---

## 5. STS / LDAP / OIDC:外部身份源的对接面

MinIO 把"认证源"做成可插拔,但"授权"始终留在本地 IAM 策略引擎。STS API(cmd/sts-handlers.go)统一走 AssumeRole 系列端点:

- **内部用户 AssumeRole**(:260):已认证的普通用户换发临时凭证,策略继承父用户(cmd/iam.go:749-787 的注释列全了 5 种策略来源)。`checkAssumeRoleAuth`(:204-230)禁止临时/服务账号二次套娃。
- **OIDC/WebIdentity**(:373 `AssumeRoleWithSSO` 统一入口):`globalIAMSys.OpenIDConfig.Validate` 验 JWT(:455),策略从 JWT 的自定义 claim 读取(claim 名可配,openid.go:544 `GetIAMPolicyClaimName`),或走 RoleARN→策略绑定(:425-441,角色表在 :591 `GetRoleInfo` 构建并注册进 `sys.rolesMap`,cmd/iam.go:368-377)。
- **LDAP**(:649 `AssumeRoleWithLDAPIdentity`):用户名/密码透传给 LDAP `Bind`(internal/config/identity/ldap/ldap.go:232),拿到用户 DN + 组 DN(:693 附近),策略映射直接以 **DN 为 key** 存在 `policydb/sts-users/`(cmd/iam.go:2085 `PolicyDBUpdateLDAP`),`cred.ParentUser = ldapUserDN`(:748 附近),最后 `SetTempUser` 落盘(:757 附近;实现 cmd/iam.go:788-806)。
- **X.509 证书 / 自定义 Token**(:791 / :977)。

要点:LDAP/OIDC 用户**在 IAM 里没有 identity.json**,只有"DN/DN 派生串 → 策略"的映射;临时凭证本身以 stsUser 形式落盘,靠每小时清扫任务回收(cmd/iam.go:1444-1510,`purgeExpiredCredentialsForExternalSSO/LDAP`)。若配置了 OPA/AuthZ 插件,授权完全外移,本地策略映射直接跳过(cmd/iam.go:2493-2500)。

---

## 6. 设计动机

**为什么 IAM 内置、以对象存储为后端?** MinIO 的哲学是"单个二进制、零外部依赖"——etcd 后端(`iam-etcd-store.go`)保留仅为兼容联邦部署的旧方案,默认路径是 `newIAMObjectStore`(cmd/iam.go:180-189)。对象存储本身就是集群的强一致状态层:IAM 数据自动获得纠删码冗余、所有节点天然共享同一份 IAM,"多节点同步"退化为"读缓存如何失效"这一个本地问题。代价是可见性延迟(第 2.3 节)和全量加载的启动开销,换来的是不需要任何额外的协调服务。

**为什么 deny 优先 + 默认拒绝?** 这是与 AWS IAM 的语义兼容(策略文档格式一致,便于混合云迁移),更是安全工程的保守原则:任何一条显式 Deny 都能覆盖别处的 Allow,新增策略永远不可能"意外放大"已有权限;没有匹配到任何 Allow 就拒绝,保证"漏配 = 不可访问"而不是"漏配 = 全开"。MinIO 在此之上叠加了两个本地变体:root(`IsOwner`)豁免,以及会话策略出现时强制降级 owner(cmd/iam.go:2420-2422)——后者修补了"特权用户用内嵌策略自我设限却被 owner 短路"的漏洞。**为什么策略引擎外置到 minio/pkg?** 因为同一套 AWS 兼容策略解析还被 mc、console、k8s operator 复用;引擎纯函数化(`Args` 进、bool 出),MinIO 侧只需构造 `Args`(cmd/auth-handler.go:480-489)和组合调用点(STS/服务账号/普通用户三个入口)。

---

## 7. FAQ 素材

1. **IAM 数据到底存在哪?** `.minio.sys` 桶下的 `config/iam/` 前缀,每个用户/组/策略各一个小 JSON 对象(cmd/iam-store.go:49-83);可用 `mc admin trace` 或直接 `mc ls --insecure alias/.minio.sys/config/iam` 观察。
2. **改了策略,多久对所有节点生效?** 写入节点即时;其他节点靠 peer 通知(秒级,可能丢)+ 默认 10 分钟的随机化轮询兜底(cmd/globals.go:108,cmd/iam.go:458-462)。etcd 后端才有实时 watch(cmd/iam-etcd-store.go:450)。
3. **服务账号权限和父账号什么关系?** inherited 模式完全等同父账号;embedded 模式是父策略与内嵌策略的**交集**(cmd/iam.go:2283-2286),父的 Deny 仍生效。
4. **root 用户会被策略拒绝吗?** 不会,`IsOwner` 直接放行(cmd/iam.go:2502-2504);但其服务账号若带内嵌策略,owner 特权会被强制降级(cmd/iam.go:2420-2422)。
5. **显式 Deny 能覆盖 root 吗?** 不能覆盖 root 本身;但 `DenyOnly` 预检(cmd/auth-handler.go:465-479)可以拦下带版本删除等特定动作的非 root 请求。
6. **LDAP 用户在 IAM 里有记录吗?** 没有 identity.json,只有以 DN 为 key 的策略映射(cmd/iam.go:2085);临时凭证按 stsUser 落盘并按小时清扫(cmd/iam.go:1444-1510)。
7. **STS 临时凭证丢了会被一直用吗?** 不会:JWT 过期 + `Credentials.IsValid` 的 `IsExpired` 检查(internal/auth/credentials.go:176-182);还可按 tokenRevokeType 吊销(cmd/iam.go:694)。
8. **匿名请求走 IAM 吗?** 不走,走桶策略系统 `globalPolicySys`(cmd/auth-handler.go:431-464);两者在 `authorizeRequest` 中分流。
9. **一个用户能挂多个策略吗?** 能,映射是逗号分隔集合,评估前合并(cmd/iam-store.go:1588);用户+所属组的策略并集生效,组被禁用则该组贡献为空(cmd/iam-store.go:372-377)。
10. **为什么服务账号不能调 AssumeRole?** 防止凭证链套娃,`checkAssumeRoleAuth` 显式拦截(cmd/sts-handlers.go:218-219)。

## 深挖方向

1. **缓存一致性窗口**:构造"节点 A 改策略、节点 B 立即访问"的实验,观察 peer 通知失败时最长 10 分钟的旧策略窗口;对比 `_MINIO_IAM_REFRESH_INTERVAL` 调参效果。
2. **`LoadIAMCache` 的 stale 保护**:cmd/iam-store.go:713-733 的 `cache.updatedAt.Before(loadedAt)` 判定,推演"加载期间有写"时为何放弃本轮而非合并。
3. **会话策略的 DenyOnly 复位语义**:对照 cmd/iam.go:2414-2425 与 auth-handler.go:465-479 两处 `DenyOnly` 用法,梳理"只查 Deny"与"正向证明 Allow"两种模式。
4. **跨引挚对比**:etcd watch 路径(cmd/iam-etcd-store.go:450-500)与对象存储轮询路径的事件粒度差异,以及为何前者被降级为可选后端。
5. **minio/pkg 策略引擎边界**:Statement 对 admin/STS/KMS 动作跳过资源匹配的特判(v3.1.3 `statement.go` 的 `isAdmin/isSTS/isKMS`),以及条件键白名单校验失败的处理。

---

## 写作要点速查表

| # | 主题 | 位置 |
|---|------|------|
| 1 | IAM 对象前缀与子目录常量 | cmd/iam-store.go:49-83 |
| 2 | UserIdentity/MappedPolicy/PolicyDoc 三种载荷 | cmd/iam-store.go:160,183,220 |
| 3 | IAM 对象存储后端(加解密/重试/32 路并发全量加载) | cmd/iam-object-store.go:84,101,152,556,590 |
| 4 | Walk 列举 IAM 对象 | cmd/iam-object-store.go:877(.minio.sys:cmd/object-api-utils.go:59) |
| 5 | 内存缓存结构与"STS 按需加载"注释 | cmd/iam-store.go:288-311(:299) |
| 6 | 全量加载 + stale 保护 + 存储接口 | cmd/iam-store.go:643-736(:713),592-624 |
| 7 | 按需加载 singleflight(凭证缓存未命中路径) | cmd/iam-store.go:2907-3012 |
| 8 | 周期刷新:watch 分支 + 随机抖动 + 每小时清扫 | cmd/iam.go:432-502;默认 10min:cmd/globals.go:108 |
| 9 | 写后 peer 通知(无 watch 后端的多节点同步) | cmd/iam.go:737-747 |
| 10 | 鉴权链入口:认证+授权两段式 | cmd/auth-handler.go:522-536(357 认证 / 418 授权) |
| 11 | 签名后取凭证 + session 策略降级 owner | cmd/signature-v4-utils.go:148-191(:186-188) |
| 12 | IAM 总入口 IsAllowed(插件/owner/STS/服务账号/普通) | cmd/iam.go:2492-2538 |
| 13 | 服务账号策略合并(inherited/embedded 分支) | cmd/iam.go:2193-2290(:2278-2289) |
| 14 | 会话策略评估(空策略特例/DenyOnly 复位) | cmd/iam.go:2372-2426(:2405,2420-2422) |
| 15 | 服务账号创建:parent + embedded/inherited claims | cmd/iam.go:1063-1155(:1102-1110);上限 4096::83 |
| 16 | CheckKey:缓存未命中按需 LoadUser | cmd/iam.go:1843-1876 |
| 17 | STS:LDAP Bind→DN 策略映射→SetTempUser | cmd/sts-handlers.go:649 起;cmd/iam.go:788-806 |
| 18 | 凭证类型判定 IsTemp/IsServiceAccount/IsValid | internal/auth/credentials.go:157,162,176 |
