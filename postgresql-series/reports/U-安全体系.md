# U — PostgreSQL 安全体系：认证 / 角色 / 权限 / 加密

> 源码版本：PostgreSQL master 分支 shallow clone，commit `8c7a74c`（"Re-read standby LSN after recovery ends"）。
> 本文所有 `文件:行号` 均在该 commit 下用 grep/Read 实际核对。RLS 策略本身见卷 T《行级安全 RLS》，本文只讲 rolbypassrls 与 FORCE RLS 的接缝。

---

## 1. 全景：一次连接的认证 → 授权

PG 把"你是谁"（authentication，连接时一次）与"你能做什么"（authorization，每条 SQL）拆成两套独立机制：前者由 `pg_hba.conf` 驱动，后者由角色系统 + ACL 位掩码驱动。

```
 客户端                                postmaster → fork 出的 backend
    │  StartupMessage (user, db)              │
    │────────────────────────────────────────>│
    │                                         │
    │              ┌──────────────────────────▼──────────────────────────────┐
    │              │ ① 规则匹配  hba_getauthmethod()  hba.c:2935             │
    │              │    check_hba() 按文件顺序扫描 parsed_hba_lines          │
    │              │    首条同时命中 (conntype,addr,db,role) 的规则即定局     │
    │              │    全部落空  → 动态造一条 uaImplicitReject  hba.c:2434   │
    │              └──────────────────────────┬──────────────────────────────┘
    │<──── AuthenticationXxx(带挑战) ─────────│
    │                                         │ ② 认证分派 ClientAuthentication()
    │<──── SASL/MD5/GSS/... 多轮交换 ─────────│    auth.c:428 switch(auth_method)
    │                                         │    成功 → sendAuthRequest(AUTH_REQ_OK)
    │<──── AuthenticationOk ──────────────────│    auth.c:670-671
    │                                         │ ③ 会话初始化：加载 pg_authid 角色行
    │                                         │    InitPostgres（datconnect 检查、
    │                                         │    rolvaliduntil、连接数限额）
    │                                         │ ④ 每条 SQL：
    │                                         │    ExecCheckPermissions execMain.c:593
    │                                         │      pg_class_aclmask    表级位掩码
    │                                         │      pg_attribute_aclcheck 列级补差
    │                                         │    check_enable_rls rls.c:52（RLS 层）
    │<─────────────── 结果 ───────────────────│
```

关键分层：`ClientAuthentication()`（auth.c:376）只负责"进门"；进门后所有对象访问走 `aclmask()` 位运算（acl.c:1412）；RLS 在其上叠加行级过滤。三者互相独立：`trust` 进门的用户照样受 ACL 约束，`rolbypassrls` 用户照样需要表上的 SELECT 权限。

---

## 2. 认证方法专节

### 2.1 分派中心

`ClientAuthentication()`（auth.c:376）先调 `hba_getauthmethod()`（auth.c:396 → hba.c:2935）拿到 hba 规则，再进 switch（auth.c:428-634）：

| 方法 | 分派点 | 机制一句话 |
|---|---|---|
| trust | auth.c:627 | 直接 `STATUS_OK`，仅记录日志 |
| password | auth.c:598 | `CheckPasswordAuth`：明文密码（建议套 TLS） |
| md5 / scram-sha-256 | auth.c:593-596 | 统一进 `CheckPWChallengeAuth`（auth.c:836），按存储的口令类型再分流 |
| peer | auth.c:585 | `auth_peer`（auth.c:1903）：`getpeereid()`（auth.c:1915）取 Unix 域对端 uid，比对 OS 用户名 |
| cert | auth.c:625 | TLS 握手已验证书；`CheckCertAuth`（auth.c:2734）取 CN/DN 过 pg_ident 映射（auth.c:2786） |
| gss / sspi | auth.c:547 / 572 | Kerberos 票据；GSS 加密通道复用状态（auth.c:560-566） |
| ldap / radius / pam / bsd | auth.c:618 / 602 / 610 | 代理给外部目录/Radius/PAM |
| oauth | auth.c:630 | 新版 Bearer token，走 SASL 框架 `CheckSASLAuth` |
| reject / 隐式拒绝 | auth.c:430 / 478 | 直接 FATAL，报错文案区分显式 reject 与"没有匹配条目"（auth.c:539 "no pg_hba.conf entry..."） |

认证成功后统一调 `set_authn_id()`（auth.c:337）登记"认证身份"；该函数禁止二次设置（auth.c:342-354，两个认证源打架即 FATAL）。用户自带的 `ClientAuthentication_hook`（auth.c:219，调用点 auth.c:667-668）是扩展插桩点。

### 2.2 md5 vs SCRAM-SHA-256：根本差异

两者共用入口 `CheckPWChallengeAuth`（auth.c:836）。它先 `get_role_password()`（crypt.c:43，顺带检查 rolvaliduntil 过期，crypt.c:72-88）取 `pg_authid.rolpassword`：

- **用户不存在时防枚举**：仍走完整认证流程，按 `password_encryption` 设置假装出口令类型（auth.c:848-860 注释 "blends in best"）——SCRAM 侧对应 `mock_scram_secret`（auth-scram.c:695），盐由用户名 + 集群级 nonce 确定性导出（auth-scram.c:1468-1487）。
- **分流**：hba 写 `md5` 且存储是 MD5 哈希 → `CheckMD5Auth`；否则一律 SCRAM（auth.c:872-876）。MD5 认证成功还会排入一条"MD5 已弃用"警告（auth.c:936-949）。

**MD5 的机制与死穴**（crypt.c:265 `md5_crypt_verify`）：存储格式 `md5` + md5(password+username)；服务端下发 4 字节盐（auth.c:898 `md5Salt[4]`，auth.c:910），客户端回 `md5(stored_hash+salt)`，服务端本地同样计算后 `timingsafe_bcmp`（crypt.c:279-287）。**存储的哈希本身就是"密码等价物"**——拿到 pg_authid 副本即可离线伪造应答，且 MD5 抗碰撞性早已不达标，无服务器验证、无信道绑定。

**SCRAM-SHA-256 的三步交换**（auth-scram.c:350 `scram_exchange` 状态机，结果码 sasl.h:25-27）：

1. `SCRAM_AUTH_INIT`：读 client-first（auth-scram.c:397），服务端生成 18 字节随机 nonce（`SCRAM_RAW_NONCE_LEN`，scram-common.h:37）拼在客户端 nonce 后，回 `r=...,s=<盐>,i=<迭代数>`（auth-scram.c:1251-1254）。迭代数默认 4096（`SCRAM_SHA_256_DEFAULT_ITERATIONS`，scram-common.h:50；全局变量 auth-scram.c:194）。
2. `SCRAM_AUTH_SALT_SENT`：读 client-final（auth-scram.c:413），先验 nonce 前后缀严格拼接且 `timingsafe_bcmp`（auth-scram.c:1124-1139），再 `verify_client_proof`（auth-scram.c:1146）：`ClientSignature = HMAC(StoredKey, AuthMessage)`，`ClientKey = ClientProof XOR ClientSignature`（auth-scram.c:1181-1182），对 ClientKey 再做一次 SHA-256 与 StoredKey 比对（auth-scram.c:1185-1189）。
3. `build_server_final_message`（auth-scram.c:1408）：回 `v=base64(ServerSignature)`（auth-scram.c:1459）——**服务器也向客户端自证**它持有 ServerKey，客户端可确认没连到钓鱼服务器，这是 md5 完全没有的对称验证。

存储格式 `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>`（scram-common.c:251、275），由 `pg_be_scram_build_secret`（auth-scram.c:481）生成：SASLprep 归一化 + 16 字节随机盐（`SCRAM_DEFAULT_SALT_LEN`，scram-common.h:44）。StoredKey = H(ClientKey)，**服务器从不保存能重放应答的密钥**。信道绑定：客户端选 `SCRAM-SHA-256-PLUS` 且 TLS 在用时启用（auth-scram.c:256-257），绑定类型必须是 `tls-server-end-point`（auth-scram.c:1053），防中间人把认证流搬到明文连接。

一句话对比：**md5 是"服务端可重放的哈希挑战"，SCRAM 是"零知识证明 + 双向认证 + 信道绑定"**；这也是升级到 SCRAM 后明文 `password` 方法仍可对 SCRAM 密钥验密的原因（`scram_verify_plain_password`，auth-scram.c:521——服务端可从明文重算密钥，反过来不行）。

---

## 3. pg_hba.conf 专节

### 3.1 第一匹配赢

`check_hba()`（hba.c:2338）对 `parsed_hba_lines` 做顺序 `foreach`（hba.c:2347），每条规则依次过滤：

1. conntype：local/host/hostssl/hostnossl/hostgss/hostnogss（hba.c:2352-2387）；
2. 地址：IP/mask、all、samehost/samenet、反解主机名（hba.c:2390-2418，主机名匹配 `check_hostname`）；
3. database：`check_db`（hba.c:989）——关键字 `all`/`sameuser`/`samegroup,samerole`/`replication`（仅物理 walsender，hba.c:997-1020）、正则、精确；
4. role：`check_role`（hba.c:950）——**`+group` 前缀**做成员检查（token 判定 hba.c:70，走 `is_member` → `is_member_of_role_nosuper`，hba.c:938，超用户不隐式属于组）、`all`、正则、精确。

四关全过即 `port->hba = hba; return;`（hba.c:2429-2431）——**写在文件更前面的规则优先，后面的永不复议**。这条顺序语义是 pg_hba.conf 最常见的运维事故源：一条 `host all all 0.0.0.0/0 reject` 放在前面会吞掉后面所有更细的授权。

### 3.2 匹配失败与文件错误

- 无任何匹配：`check_hba` 末尾 palloc 一个空规则、置 `uaImplicitReject`（hba.c:2434-2437），客户端收到 "no pg_hba.conf entry for host ..."（auth.c:539）。错误信息刻意带 hba 文件名:行号:原文（auth.c:305-307），方便 DBA 定位。
- **文件加载是全有或全无**：`load_hba()`（hba.c:2452）继续解析剩余行以一次性收集所有错误（hba.c:2489-2501 注释），但只要有**一行**出错，整个新文件作废、保留旧配置（hba.c:2524-2531）；空文件同样算错误（hba.c:2504-2511）。不会出现"半新半旧"的规则集。
- 规则里数据库/角色还支持 `@file` 引用与大小写不敏感选项（`check_role` 的 case_insensitive 参数，hba.c:970-974）。

### 3.3 pg_hba_file_rules 视图（简）

SQL 侧用 SRF `pg_hba_file_rules()`（hbafuncs.c:432）物化 tuplestore（hbafuncs.c:442）逐行列出解析结果，11 列：rule_number/file_name/line_number/type/database/user_name/address/netmask/auth_method/options/**error**（pg_proc.dat:6675-6677）。解析失败的行也会出现且带 error 文案，因此可作 reload 前的语法预检；该函数默认只授予了 bootstrap 超用户执行权（pg_proc.dat:6678 `proacl => '{POSTGRES=X}'`）。

---

## 4. 角色系统专节

### 4.1 CREATE ROLE / ALTER ROLE 与角色属性

`CreateRole()`（user.c:133）解析 DefElem 后写 pg_authid。属性默认值（user.c:145-152）：`issuper=false`、`inherit=true`、`createrole=false`、`createdb=false`、`canlogin=false`、`isreplication=false`、`bypassrls=false`、`connlimit=-1`。`CREATE USER` 语法只是把 `canlogin` 默认翻成 true（user.c:185-188，`ROLESTMT_USER`）。各属性直接落成 pg_authid 列：rolsuper/rolinherit/rolcreaterole/rolcreatedb/rolcanlogin/rolreplication（user.c:417-422）、rolbypassrls（user.c:464）。`AlterRole()`（user.c:626）不允许非超用户改 rolsuper（user.c:763）。

initdb 自带角色在 pg_authid.dat 硬编码：bootstrap 超用户 `POSTGRES`（oid 10，rolsuper/rolbypassrls 全 true，pg_authid.dat:22-26）及一组预置权限组：pg_database_owner(6171)、pg_read_all_data(6181)、pg_write_all_data(6182)、pg_monitor(3373)、pg_read_all_settings(3374) 等——全是 `rolcanlogin=false` 的"组角色"。

会话级限制也在角色行上：`rolvaliduntil` 是口令有效期，认证时由 `get_role_password()` 检查、过期即拒绝（crypt.c:72-88）；`rolconnlimit` 由后端初始化阶段的连接数预算执行。口令本身以 rolpassword 存储（MD5 串或 SCRAM 密钥串，见第 2.2 节），pg_authid 因此是全集群最敏感的表——pg_auth_members（成员关系）反而是普通的可更新目录表。

### 4.2 角色嵌套（GRANT role TO role）

`GrantRole()`（user.c:1493）把成员关系写入 pg_auth_members，PG14+ 起每条边可带 `admin`/`inherit`/`set` 三选项（user.c:1501-1523 解析；落盘在 AddRoleMems）。授权时走 `check_role_membership_authorization`（user.c:1567）。

**递归展开的核心是 `roles_is_member_of()`**（acl.c:5178）：以角色自身为首元素建工作列表（acl.c:5226），用 `foreach` 边遍历边追加——列表同时充当"已见集合"与"待扫描队列"（acl.c:5220-5224 的巧注）：

- 每个成员经 `AUTHMEMMEMROLE` syscache 取直连边（acl.c:5235-5236）；
- 按 `type` 过滤边：查权限用 `ROLERECURSE_PRIVS`，跳过 `inherit_option=false` 的边（acl.c:5252-5253）；SET ROLE 用 `ROLERECURSE_SETROLE`，跳过 `set_option=false`（acl.c:5256-5257）；
- 防环：bloom filter 记录已见 oid（acl.c:5264；A->B 与 A->C->B 双路径合法，见 acl.c:5260-5263 注释）；
- `pg_database_owner` 的隐式成员关系在这里注入：datdba 自动属于该角色（acl.c:5269-5271）。

结果缓存进 TopMemoryContext（acl.c:5283-5294）。三个公开入口：`has_privs_of_role`（acl.c:5310，权限继承语义）、`member_can_set_role`（SET 权限）、`is_member_of_role_nosuper`（hba 组匹配用，超用户不隐式成组）。

### 4.3 rolbypassrls 与 FORCE RLS（呼应卷 T）

判定集中在 `check_enable_rls()`（rls.c:52），优先级从高到低：

1. 系统内置对象（oid < FirstNormalObjectId）一律不启用（rls.c:62-63）；
2. 表未开 relrowsecurity → RLS_NONE（rls.c:77-78）；
3. **BYPASSRLS**：`has_bypassrls_privilege(user_id)` 命中即旁路，超用户永远视同 BYPASSRLS（rls.c:87-88 及注释）；
4. **表属主**默认旁路，但若 `relforcerowsecurity` 已设则返回 RLS_ENABLED——即 FORCE RLS 把属主也罩进策略（rls.c:98-114）；RI（外键）检查上下文可经 `InNoForceRLSOperation` 豁免，否则引用完整性会被自己的策略卡死（rls.c:106-114 注释）。

注意 BYPASSRLS 是**角色属性**（user.c:151、464），FORCE RLS 是**表属性**，两者在 rls.c 这个小文件里交汇；rolbypassrls 不可自助授予—— ALTER ROLE 时由超用户把关（与 rolsuper 同级的检查链）。

---

## 5. ACL 专节

### 5.1 AclItem：位掩码的紧凑编码

每个对象在目录表里存一个 `aclitem[]`（如 pg_class.relacl），元素是定长三体：

```c
typedef struct AclItem
{
    Oid      ai_grantee;   /* 被授权者，PUBLIC 用 0 */
    Oid      ai_grantor;   /* 授权者 */
    AclMode  ai_privs;     /* 64 位：高 32 位 grant option，低 32 位实际权限 */
} AclItem;                 /* acl.h:54-59 */
```

权限位定义在 parsenodes.h:76-94：`ACL_INSERT(1<<0) ... ACL_MAINTAIN(1<<14)`；文本编码一字一权：`"arwdDxtXUCTcsAm"`（acl.h:154，对应 acl.h:137-151），这就是 `\dp` 输出里那些字母的来源。每类对象有自己的"全权"掩码：表 8 位、库 CONNECT/CREATE/TEMP、函数仅 EXECUTE 等（acl.h:159-171）。`ACL_SELECT_FOR_UPDATE = ACL_UPDATE`（parsenodes.h:94）。

### 5.2 权限判定：aclmask 三段式

`aclmask()`（acl.c:1412）是所有 `pg_*_aclmask` 的汇聚点：

1. 属主隐式持有全部 grant options，不经 ACL 条目（acl.c:1436-1443）；
2. 第一遍：直接授予 roleid 或 PUBLIC 的条目按位 OR（acl.c:1451-1462）；
3. 第二遍：间接条目先看剩余位是否有关，再昂贵的 `has_privs_of_role` 递归（acl.c:1471-1488）——最小化角色展开次数。

表级入口 `pg_class_aclmask_ext`（aclchk.c:3272）：非超用户对系统目录直接砍掉 INSERT/UPDATE/DELETE/TRUNCATE/USAGE 位（aclchk.c:3317-3331）；超用户短路返回整个 mask（aclchk.c:3336-3339）；relacl 为 NULL 时运行时按 `acldefault()` 现造默认 ACL（aclchk.c:3348-3361）。

### 5.3 GRANT / REVOKE 与 default ACL

`ExecuteGrantStmt()`（aclchk.c:392）把语法树转成 InternalGrant：目标 OID 收集（ACL_TARGET_OBJECT / ALL IN SCHEMA，aclchk.c:408-414）、grantee 列表（PUBLIC 映射为 `ACL_ID_PUBLIC`=0，aclchk.c:441-443）、权限列表转 AclMode 并按对象类型校验（aclchk.c:455-511）。表对象的 GRANT 由 `ExecGrant_Relation`（aclchk.c:1773）处理，列级权限单独累积成数组；REVOKE 表级权限会按 SQL 标准隐式 REVOKE 到每一列（aclchk.c:1904-1906 附近注释）。

**默认权限有两个来源**：

- 硬编码兜底 `acldefault()`（acl.c:827）：表/序列/schema/大对象 world 无权、仅属主全权；数据库 world 得 TEMP+CONNECT（acl.c:850-854，向后兼容）；**函数 world 默认 PUBLIC EXECUTE**（acl.c:855-858）；语言/类型 world 默认 USAGE。属主条目刻意不写 grant option 位——它们"来自系统"，在 aclmask 里特判（acl.c:918-927 注释）。
- 用户自定义 `pg_default_acl`：`get_user_default_acl()`（aclchk.c:4277）按 DEFACLOBJ_* 类型分别查全局条目与按 schema 条目（aclchk.c:4330-4331），再与硬编码默认 merge（aclchk.c:4342-4346）。它不是 initdb 灌数据，而是 ALTER DEFAULT PRIVILEGES 语句的产物；initdb 只负责把 template1/public 等系统对象的初始 relacl 写好。

### 5.4 列级权限：与表级叠加

执行期入口 `ExecCheckOneRelPerms()`（execMain.c:657）体现"表级优先、列级补差"：

```c
relPerms = pg_class_aclmask(relOid, userid, requiredPerms, ACLMASK_ALL);
remainingPerms = requiredPerms & ~relPerms;      /* execMain.c:684-685 */
```

表级位不够才看列级；剩余位里若混着只可能是表级的权限（如 TRUNCATE），直接判负（execMain.c:694-695）。SELECT 逐列 `pg_attribute_aclcheck`（execMain.c:718-736），整行引用需全列有权限（execMain.c:723-728）；`SELECT count(*)` 无显式列引用时按 SQL 标准放宽为"任一列有 SELECT 即可"（execMain.c:707-716）。INSERT/UPDATE 同法处理 modifiedCols（execMain.c:743-755）。因此 `GRANT SELECT(col1) ON t` 与表级授权是**并集**关系，而非叠加门槛。

### 5.5 SSL/TLS 层（简）

`be-secure.c` 是**服务端** TLS 的公共层（客户端在 fe-secure-*）：GUC 集中定义（ssl_cert_file/ssl_ca_file/ssl_crl_file 等，be-secure.c:37-45），`secure_initialize()` → `be_tls_init()`（be-secure.c:78-86），连接升级走 `secure_open_server()`（be-secure.c:116，先把 SSL 握手前缓冲的明文字节回推，be-secure.c:122-129）。具体实现后端是 `be-secure-openssl.c`。最低协议版本默认 TLS 1.2（be-secure.c:61），支持 SNI 开关（be-secure.c:65）。TLS 与 hba 联动于 conntype（hostssl/hostnossl，hba.c:2363-2374）与 clientcert 选项；cert 认证要求先加载 CA 验证位置（auth.c:405-423）。

---

## 6. 设计动机

1. **为什么 pg_hba.conf 是文件而非系统表？** 认证发生在 backend 尚未初始化、数据库集群可能不可用之时——查系统表需要先连上系统，鸡生蛋。规则由 postmaster 进程在 `load_hba()` 里解析并缓存在内存（hba.c:2452），崩溃恢复、单用户模式、replication 引导全都能用；SIGHUP reload 语义清晰；且"任一行出错即整文件作废"（hba.c:2524-2531）给出可预期的保守行为，比"合法行生效、非法行静默跳过"安全得多。pg_hba_file_rules 视图补足了可观测性。
2. **为什么 SCRAM 替代 md5？** md5 认证协议里，`pg_authid` 存储的哈希就是应答的输入材料——库文件泄露即等于密码泄露（离线重放）；无服务器验证、无信道绑定、底层 MD5 算法已破。SCRAM 把"证明"换成零知识：服务器只存 StoredKey/ServerKey，泄露后既不能直接登录也不能伪造服务端应答（ServerSignature 反向校验），配合 TLS 信道绑定防中间人。所以代码里 md5 认证成功都会挂弃用警告（auth.c:936-949）。
3. **为什么 ACL 用位掩码 + aclitem 数组，而非授权关系表？** 一次 syscache 读出 relacl 即可做纯位运算判定（acl.c:1451-1488 两遍循环），无 join、无索引回表；对象与其权限同页存储、同事务修改，天然避免"对象删了权限还在"的悬挂问题；高 32 位 grant option 塞进同一字段让"权限/可再授权"永远成对出现，简化 REVOKE 的级联（recursive_revoke）。代价是表达不了时间窗、数量等策略——那正是留给 RLS 和外部认证（LDAP/Radius）的空间。
4. **为什么角色属性（rolbypassrls 等）与 ACL 分开？** BYPASSRLS/SUPERUSER/REPLICATION 是"改变判定规则本身"的元权限，必须在判权代码里特判（如 aclchk.c:3336 超用户短路），无法用数据表达；而 ACL 是纯数据。两层叠加后，"谁能改规则"与"规则是什么"可以分开审计。

---

## 7. FAQ 素材

1. **Q: pg_hba.conf 改了不生效？** A: 规则在 postmaster 内存中，需 reload；且 `load_hba()` 任何一行出错会整体保留旧规则（hba.c:2524-2531），日志里有行级错误——不是"部分生效"而是"整体没生效"。用 pg_hba_file_rules 视图的 error 列预检。
2. **Q: "第一匹配赢"到底多绝对？** A: check_hba 顺序扫描、命中即 return（hba.c:2429-2431），后面规则对这条连接完全不可见；排错时先看更靠前的规则是否拦截。
3. **Q: md5 和 scram-sha-256 在 hba 里能互换吗？** A: 都进 CheckPWChallengeAuth（auth.c:836），最终按 rolpassword 的实际类型决定（auth.c:860）；写 md5 但存的是 SCRAM 密钥，实际执行的是 SCRAM 交换。
4. **Q: 用户不存在时为什么报"password authentication failed"而不是"user not found"？** A: 防用户名枚举：mock 认证走完全相同流程（auth.c:848-860；auth-scram.c:695）。
5. **Q: SCRAM 里服务器端存了什么、能不能泄密后登录？** A: 只有 `SCRAM-SHA-256$...` 的 StoredKey/ServerKey（scram-common.c:251）；StoredKey 是 ClientKey 的哈希，无法反推出 ClientProof。
6. **Q: grant role 后为什么没获得权限？** A: 查边上的 inherit 选项——`ROLERECURSE_PRIVS` 会跳过 inherit_option=false 的边（acl.c:5252-5253）；SET ROLE 资格另看 set_option（acl.c:5256-5257）。
7. **Q: 表属主会被自己的 RLS 策略拦吗？** A: 默认不会，但 ALTER TABLE ... FORCE ROW LEVEL SECURITY 后会（rls.c:98-114）；只有 BYPASSRLS 角色无视 FORCE（rls.c:87-88）。
8. **Q: 新建函数为什么任何用户都能执行？** A: acldefault 对 FUNCTION 默认给 PUBLIC EXECUTE（acl.c:855-858），安全敏感函数需显式 REVOKE。
9. **Q: 有表级 SELECT 还需要列级授权吗？** A: 反之——列级授权可以先顶上：表级 aclmask 不足的位由列级补（execMain.c:684-685），两者是并集。
10. **Q: peer 与 cert 认证"认证身份"和"数据库角色"什么关系？** A: OS uid / 证书 CN 只是认证凭据，须经 pg_ident 映射到数据库角色（auth.c:2786 check_usermap）；真实认证身份记录在 authn_id（auth.c:337）。

## 深挖方向

1. **认证钩子体系**：`ClientAuthentication_hook`（auth.c:219）是 pgaudit、插件认证的入口；SASL 框架（auth-sasl.c）统一了 SCRAM 与 OAuth 两种机制交换（auth.c:631）。
2. **授权链条完整还原**：`aclmask`（acl.c:1412）→ `has_privs_of_role` → `roles_is_member_of`（acl.c:5178）→ pg_auth_members syscache；把角色展开成本与缓存失效（TopMemoryContext 缓存，acl.c:5283-5294）画成时序图。
3. **GRANT 级联 REVOKE**：`recursive_revoke`（acl.c:1326）与 grantor 链的删除传播（acl.c:1238-1241 注释），SQL 标准授权图在 PG 的落地。
4. **GSS 加密与认证复用**：同一 GSS 状态先加密后认证的复用路径（auth.c:556-566），与 SSL 的 hostgss/hostnogss 规则（hba.c:2376-2387）。
5. **mock 认证的恒定时间性**：`scram_mock_salt` 用集群 nonce 派生盐（auth-scram.c:1468-1487），保证"不存在用户"与"存在用户"的计算路径耗时可比，防计时侧信道。

---

## 写作要点速查表

| 要点 | 位置 |
|---|---|
| 认证总入口 ClientAuthentication | auth.c:376；方法分派 switch auth.c:428-634 |
| hba 方法获取 | auth.c:396 → hba_getauthmethod hba.c:2935 |
| hba 顺序匹配、命中即返 | hba.c:2347（foreach）、2429-2431 |
| 隐式拒绝 uaImplicitReject | hba.c:2434-2437；报错文案 auth.c:539 |
| load_hba 任一行错误整体作废 | hba.c:2452、2524-2531 |
| md5/SCRAM 统一分流 | auth.c:836 CheckPWChallengeAuth；auth.c:872-876 |
| SCRAM 状态机与 nonce/proof/签名 | auth-scram.c:350、1232-1254、1146-1193、1408-1459 |
| SCRAM 存储格式 | scram-common.c:251/275；盐 16B、迭代 4096（scram-common.h:44/50） |
| 角色属性默认值与落盘 | user.c:145-152；user.c:417-422、464 |
| 角色递归展开（工作列表+防环） | acl.c:5178-5298；inherit/set 过滤 5252-5257 |
| BYPASSRLS 与 FORCE RLS 交汇 | rls.c:52、87-88、98-114 |
| AclItem 三体结构与高32位 grant option | acl.h:54-71；权限字母表 acl.h:154 |
| aclmask 三段式判定 | acl.c:1412-1491 |
| 默认 ACL 双来源 | acldefault acl.c:827-934；pg_default_acl 查询 aclchk.c:4277 |
| GRANT 执行骨架 | aclchk.c:392 ExecuteGrantStmt；表+列 aclchk.c:1773 |
| 表级/列级叠加补差 | execMain.c:657-758（关键 684-685、711-716） |
| 服务端 TLS 公共层 | be-secure.c:37-45、78-86、116；默认 TLS1.2 be-secure.c:61 |
| pg_hba_file_rules 视图 | hbafuncs.c:432；11 列含 error（pg_proc.dat:6675-6678） |
| 角色有效期 rolvaliduntil 检查 | crypt.c:43、72-88 |
| 认证身份登记 set_authn_id（仅一次） | auth.c:337-368 |
| cert 认证 CN/DN + pg_ident 映射 | auth.c:2734、2786 |
