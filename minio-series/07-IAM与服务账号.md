# 第 07 章 · IAM 与服务账号:鉴权链与策略引擎

> 基线:commit `7aac2a2`。行号以 cmd/auth-handler.go、cmd/iam*.go、internal/iam/ 为准。**勘误**:本 commit 的 IAM 代码在 cmd/ 下(iam.go/iam-store.go/iam-object-store.go),策略引擎在外部依赖 minio/pkg/v3(非 internal/iam)。

## 7.0 全景:一次 S3 请求的四段鉴权链

```
checkRequestAuthTypeCredential(auth-handler.go:522):
  ①类型识别(getRequestAuthType :124:匿名/Presigned/V4/V4-streaming/SSE-C)
  ②签名验证(authenticateRequest :357→isReqAuthenticated :559:HMAC 重算+SHA256)
  ③凭证解析(getReqAccessKeyV4→checkKeyValid,signature-v4-utils.go:148:
     缓存未命中走 CheckKey 按需加载 singleflight,iam.go:1843)
  ④授权(authorizeRequest :418:匿名走桶策略 globalPolicySys;
     认证走 IAMSys.IsAllowed iam.go:2492)
```

**授权的顺序链**(:2492 起):AuthZ 插件→IsOwner(root 豁免)→STS→IsAllowedSTS→服务账号→IsAllowedServiceAccount→普通用户合并策略评估。

## 7.1 IAM 存储:bolt 桶在 XL 的 JSON 对象

IAM 全部存为 `.minio.sys/config/iam/` 下 JSON 对象(users/service-accounts/sts/policies/policydb,iam-store.go:49-83),**写入即 PutObject**(config-common.go:83)——用对象存储自身当 IAM 数据库(01 章"自体适用"哲学)。全量加载带 stale 保护:`cache.updatedAt.Before(loadedAt)` 才整体替换缓存(:713-733);凭证缓存未命中按需加载 singleflight(:2907)。**多节点同步双通道**:写后 peer 通知(iam.go:737,仅无 watch 后端)+默认 10 分钟随机抖动轮询(globals.go:108;:458-462);etcd 后端才有 watch(iam-etcd-store.go:450)。

## 7.2 策略引擎:显式 Deny 永远赢

Statement{Effect/Actions/NotActions/Resources/Conditions};`Policy.IsAllowed` 语义=**显式 Deny 命中即拒→默认拒绝→IsOwner(root)豁免**,单条语句按 Action→Resource→Condition 匹配;条件键取值表由 getConditionValues 从请求构造(bucket-policy.go:78,含 SourceIp/SecureTransport/对象标签)。**DenyOnly 预检**(auth-handler.go:465-479):带版本删除场景只查显式 Deny。服务账号两模式:claims 里 parent+sa-policy(embedded/inherited,iam.go:1102-1110);**评估=会话策略 AND 父策略交集**(:2278-2289);会话策略存在时强制 IsOwner=false(:2420-2422)——**root 特权不能穿透内嵌策略**。

## 7.3 设计动机

1. **为什么 IAM 用对象存储自身**:零外部依赖(01 章哲学)+天然多副本(EC 保护 IAM 元数据)+watch 缺失用轮询补;
2. **Deny 优先**:与 AWS IAM 对齐的行业惯例——安全策略的组合可预测性;
3. **服务账号的 AND 交集**:派生账号权限⊆父账号——权限不可放大的安全不变式;
4. **root 不能穿透内嵌策略**(:2420-2422):即使 root 也要受会话策略约束——最小权限的彻底执行。

## 7.5 FAQ

**Q1:IAM 数据存在哪?**
.minio.sys/config/iam/ 的 JSON 对象(iam-store.go:49-83):用自身对象存储当数据库。

**Q2:多节点 IAM 怎么同步?**
写后 peer 通知+10 分钟轮询(:737/:458-462);etcd 后端才有 watch。

**Q3:显式 Allow 和显式 Deny 冲突?**
Deny 赢(:IsAllowed 语义):任何显式 Deny 命中即最终拒绝。

**Q4:服务账号能比父账号权限大吗?**
不能:embedded 模式取交集(:2278-2289);root 特权也不穿透(:2420-2422)。

**Q5:匿名请求的策略评估?**
走桶策略 globalPolicySys(:418):匿名条件键有限(SecureTransport 等)。

**Q6:policy JSON 的结构?**
Statement{Effect/Actions/NotActions/Resources/Conditions}:与 AWS IAM 同构。

**Q7:凭证缓存的失效?**
按需 singleflight 加载(:2907)+写后通知失效——多节点最终一致。

**Q8:root 用户的请求跳过策略吗?**
IsOwner 豁免策略评估,但 DenyOnly 预检仍执行(:465-479)。

**Q9:LDAP/OIDC 用户怎么映射?**
STS 返回临时凭证+claims 映射为策略名(外部身份源对接面)。

**Q10:条件键有哪些?**
SourceIp/SecureTransport/对象标签/对象锁键等(:78 的 getConditionValues)。

## 7.6 小结与深挖方向

本章结论:**IAM="自身对象存储当库+四段鉴权链+Deny 优先策略引擎+服务账号 AND 交集"**。深挖:

1. stale 保护(:713-733)在时钟偏移多节点的误判面;
2. 10 分钟轮询(:458-462)对策略生效延迟的影响;
3. DenyOnly 预检(:465-479)与 policy 条件的组合盲区;
4. 服务账号 parent claim(:2195-2212)的伪造防护;
5. singleflight(:2907)在凭证风暴的合并率。

> 下一章:SSE 加密——三种形态与密钥层级。
