# T-行级安全 RLS:策略存储、重写期注入与组合语义

> 基于 PostgreSQL 源码 commit `8c7a74c`(shallow clone)。所有行号均以该版本为准,用 grep/Read 实际核对。
> 核心文件:`src/backend/rewrite/rowsecurity.c`(策略展开,972 行)、`src/backend/commands/policy.c`(DDL 与 relcache 加载,1299 行)、`src/backend/utils/misc/rls.c`(绕过判定,168 行)、`src/backend/rewrite/rewriteHandler.c`(重写入口,4872 行)。

## 0. 一句话总结

RLS 不是执行器里的逐行钩子,而是**查询重写阶段**把 `pg_policy` 里的表达式拷贝进查询树的 securityQuals(可见性过滤)与 WithCheckOptions(写入校验);之后规划器把它们当普通条件(带安全等级)优化,执行器只负责对写入行求值 WCO 并在违反时报错。执行器中没有名为 ExecRSLS 的专有算子——SELECT 的行过滤就是普通扫描 qual。

## 1. 全景:一次 SELECT 的 RLS 注入点

```
 解析 (parser)
   │  产出 Query;此时查询树对 RLS 一无所知
   ▼
 重写 (rewriter: rewriteHandler.c: QueryRewrite:4783)
   │  Step1 RewriteQuery (ON INSERT/UPDATE/DELETE 规则,可能产生多查询) :4804
   │  Step2 fireRIRrules (:4818 → 定义 :2040)
   │      ├─ 展开 SELECT 规则 (视图替换为子查询, 即 RIR 规则)   :2184-2196
   │      ├─ 递归 CTE, 并汇 hasRowSecurity                      :2202-2215
   │      ├─ 递归 SubLink 子查询                                :2221-2236
   │      └─ ★ RLS 注入: 遍历 rtable, 对每个 RTE_RELATION 调
   │           get_row_security_policies()                      :2267
   │           (刻意放在规则展开之后, 注释 :2238-2243)
   │           → rte->securityQuals        (USING 表达式)       :2332-2333
   │           → parsetree->withCheckOptions (WITH CHECK)       :2335-2336
   │           → parsetree->hasRowSecurity = true               :2343-2344
   ▼
 规划 (planner)
   │  securityQuals 逐条 preprocess_expression (EXPRKIND_QUAL)  planner.c:1190-1195
   │  process_security_barrier_quals: 每个子列表 security_level
   │  递增, 经 distribute_quals_to_rels 成为 baserestrictinfo   initsplan.c:1949-1989
   ▼
 执行 (executor)
    SELECT/UPDATE/DELETE 扫描: qual 逐行求值, 不可见即过滤 (无专有算子)
    INSERT/UPDATE 写入: ExecWithCheckOptions 逐 WCO 求值, 失败即报错
    (execMain.c:2296-2336; 各写路径调用点见 nodeModifyTable.c)
```

要点:

- **注入点在重写,不在执行**。文件头注释明确:普通查询在 rewrite 阶段对每个 RTE 调 `get_row_security_policies()`,返回值前置到 RTE 的 securityQuals;写查询再把 WITH CHECK 前置到 Query 的 WithCheckOptions;COPY 等旁路则直接改写成普通查询走同一管线(`src/backend/rewrite/rowsecurity.c:16-23`)。
- **为什么放最后**:"Apply any row-level security policies. We do this last..."——因为策略 qual 可能含 SubLink,若先注入,后面的 query_tree_walker 会把新 qual 再递归一遍,且策略子查询需要独立的防递归保护(`src/backend/rewrite/rewriteHandler.c:2238-2243`;策略 SubLink 的加锁与二次 RIR 在 :2273-2324,检测到策略自引用报 "infinite recursion detected in policy")。
- **与视图的先后**:视图(RIR 规则)先展开成子查询,RLS 后注入,因此底层表浮出水面后 RLS 才对其生效。视图底层表的 RLS 以视图属主身份判定(`checkAsUser`),`security_invoker` 视图则回到调用者身份(`src/backend/rewrite/rewriteHandler.c:3643-3646`);`get_row_security_policies` 内部取 `perminfo->checkAsUser`,未设置则用 `GetUserId()`(`src/backend/rewrite/rowsecurity.c:126-127`)。
- **securityQuals 前插语义**:RLS 条目插在 RTE->securityQuals 列表头部,使其先于(security barrier)视图条件求值(`src/backend/rewrite/rewriteHandler.c:2326-2333`)。
- **执行器无"ExecRSLS"**:可见性过滤就是扫描节点的普通 qual;写校验入口是 `ExecWithCheckOptions(WCOKind, ...)`,按 kind 过滤:INSERT(:1112)、UPDATE(:2501)、ON CONFLICT(:3232、:3376)、MERGE UPDATE/DELETE(:3652)(`src/backend/executor/nodeModifyTable.c`)。WCO 的 ExprState 在 ExecInitModifyTable 统一 ExecInitQual 编译(`src/backend/executor/nodeModifyTable.c:5470-5489`)。
- **计划缓存联动**:重写若可能涉及 RLS,`hasRowSecurity` 经 `get_row_security_policies` 回传写入 plancache 的 `dependsOnRLS`;角色或 `row_security` GUC 变化即判计划失效重规划(`src/backend/utils/cache/plancache.c:738-743`,字段见 `src/include/utils/plancache.h:129-131`)。这正是 RLS_NONE_ENV"本次没注入但要标记"的意义。

## 2. 策略存储专节:pg_policy 与 relcache 缓存

### 2.1 pg_policy 逐字段(`src/include/catalog/pg_policy.h:31-46`)

| 字段 | 行号 | 含义 |
|---|---|---|
| `oid` | :33 | 策略 OID(catalog OID 3256) |
| `polname` | :34 | 策略名;(polrelid,polname) 唯一索引 pg_policy_polrelid_polname_index :60 |
| `polrelid` | :35 | 所属关系(pg_class 外键) |
| `polcmd` | :37 | `ACL_*_CHR`('r'/'a'/'w'/'d')之一或 `'*'`(ALL);由 `parse_policy_command` 映射,TRUNCATE 无对应(`src/backend/commands/policy.c:119-141`) |
| `polpermissive` | :38 | true=PERMISSIVE(默认),false=RESTRICTIVE |
| `polroles[]` | :42 | 适用角色 Oid 数组,BKI_FORCE_NOT_NULL;不写角色即 PUBLIC(存 ACL_ID_PUBLIC) |
| `polqual` | :43 | USING 表达式,pg_node_tree(parse tree 文本) |
| `polwithcheck` | :44 | WITH CHECK 表达式,可为 NULL |

开关不在 pg_policy 而在 pg_class:`relrowsecurity`(:113)与 `relforcerowsecurity`(:116)(`src/include/catalog/pg_class.h`)。两者独立:ENABLE 决定普通用户是否受策略约束,FORCE 决定 owner 是否也被罩住(§5)。

DDL 侧:`CreatePolicy`(:581)/`AlterPolicy`(:783)/`RemovePolicyById`(:344)。表达式在 DDL 时用 `transformWhereClause` 以 `EXPR_KIND_POLICY` 解析并固定 collation(`src/backend/commands/policy.c:668-677`);只能对普通表/分区表建策略,要求表属主且非系统表(`RangeVarCallbackForPolicy` :63-108)。

### 2.2 relcache 缓存:rd_rsdesc

- Relation 结构挂 `struct RowSecurityDesc *rd_rsdesc`(`src/include/utils/rel.h:119`);`RowSecurityPolicy{policy_name, polcmd, roles, permissive, qual, with_check_qual, hassublinks}` 与 `RowSecurityDesc{rscxt, policies}` 定义在 `src/include/rewrite/rowsecurity.h:20-35`。
- **构建**:`RelationBuildRowSecurity`(`src/backend/commands/policy.c:204-334`)在独立内存上下文 rscxt 中按 (polrelid,polname) 索引扫描 pg_policy——靠索引序天然按名字有序,简化 equalRSDesc(:231-235);`stringToNode` 反序列化 qual/with_check 到 rscxt(:289,:303);`hassublinks` 用 `checkExprHasSubLink` 一次性预计算(:311-312);最后把 rscxt 重挂到 CacheMemoryContext 并赋给 rd_rsdesc(:331-333)。
- **两个构建时机**:`RelationBuildDesc` 首建时直接调用(`src/backend/utils/cache/relcache.c:1261-1264`);relcache 因其他字段失效而重载时,若 `relrowsecurity && rd_rsdesc==NULL` 则惰性重建(:4346-4351)——注释强调 relrowsecurity=true 时 rd_rsdesc 不可能为 NULL,pg_policy 无行时也是一条**默认拒绝**语义(实际是靠注入恒 false,见 §4)。
- **失效**:策略 DDL 调 `CacheInvalidateRelcache`(`src/backend/commands/policy.c:406,763,1101,1207`);`ATExecSetRowSecurity`/`ATExecForceNoForceRowSecurity` 改 pg_class(`src/backend/commands/tablecmds.c:19292-19317,19322+`)经目录更新自动触发 relcache 失效。收到失效消息后 `RelationClearRelation` 重建新描述并用 `equalRSDesc` 逐策略比较(数量、名字序、polcmd、roles、qual、with_check 全等,`src/backend/utils/cache/relcache.c:1000-1043`),相同则 `SWAPFIELD(RowSecurityDesc *, rd_rsdesc)` 换回旧指针,把"失效但内容没变"的重建成本省掉(:2703,:2756-2757)。
- **销毁**:释放 relcache 条目时统一 `MemoryContextDelete(rd_rsdesc->rscxt)` 回收全部策略表达式(`src/backend/utils/cache/relcache.c:2501-2502`)。
- **没有 pg_policy 专用 syscache**(syscache.c 中无 POLICYNAME/POLICYRELID):策略只缓存在 relcache,失效粒度是"整张表"——任何一条策略变动都使该表 rd_rsdesc 整体重建;单表策略数量通常很小,此粒度足够。
- 注意:rd_rsdesc 存的是**该表全部策略**,与用户无关;按命令/角色筛选发生在每次查询重写时(§3/§4),因此同一 relcache 条目服务所有用户。

### 2.3 relcache 中的策略结构(逐字段)

```c
typedef struct RowSecurityPolicy
{
    char       *policy_name;    /* Name of the policy */
    char        polcmd;         /* Type of command policy is for */
    ArrayType  *roles;          /* Array of roles policy is for */
    bool        permissive;     /* restrictive or permissive policy */
    Expr       *qual;           /* Expression to filter rows */
    Expr       *with_check_qual; /* Expression to limit rows allowed */
    bool        hassublinks;    /* If either expression has sublinks */
} RowSecurityPolicy;            /* src/include/rewrite/rowsecurity.h:20-29 */
```

- 与 pg_policy 一一对应,但 `polqual/polwithcheck` 已从 pg_node_tree 文本反序列化为内存 Expr 树,查询重写时 `copyObject` 拷贝使用,原始缓存不被污染(`rowsecurity.c:761,787`)。
- `hassublinks` 是构建期算好的缓存位:重写期据此决定是否走"加锁+二次 RIR"的慢路径,避免每次对每条策略重扫表达式树。

## 3. 评估专节:USING vs WITH CHECK

入口 `get_row_security_policies`(`src/backend/rewrite/rowsecurity.c:98-570`):

1. **判定状态**:`check_enable_rls` 三态(`src/include/utils/rls.h:41-46`):RLS_NONE(表没开 RLS,直接返回 :133-134)、RLS_NONE_ENV(本次绕过但结论依赖环境,只置 `*hasRowSecurity=true` 逼 plancache 重规划 :141-151)、RLS_ENABLED(真注入)。
2. **目标表语义**:仅目标表按命令类型取策略;非目标表一律按 CMD_SELECT 取("UPDATE t1...FROM t2 中 t2 用 SELECT 策略"):`commandType = rt_index == root->resultRelation ? root->commandType : CMD_SELECT`(:164-165)。
3. **USING → securityQuals(过滤,静默)**:`add_security_quals`(:739-818)把 USING 表达式放进 RTE->securityQuals;行不满足即从结果中消失——SELECT/UPDATE/DELETE 共用(:221-228)。两条叠加规则:
   - SELECT FOR UPDATE/SHARE 因要求 UPDATE 权限,先叠加 UPDATE USING(:195-209,高特权策略优先注释 :171-176);
   - UPDATE/DELETE/MERGE 若需 SELECT 权限(WHERE/RETURNING 引用了表列),再叠加 SELECT 策略(:240-256)。
4. **WITH CHECK → WithCheckOptions(校验,报错)**:INSERT/UPDATE 目标表把 WITH CHECK(缺省回落 USING,`QUAL_FOR_WCO` 宏 :848-851)挂为 WCO(:264-276)。执行器 `ExecWithCheckOptions` 中 `ExecQual` 为 false/NULL 即 ereport(ERROR);且**不打印行数据**——RLS 违反时不确定用户是否有权看见该行,只有 WCO_VIEW_CHECK 才可能回显(`src/backend/executor/execMain.c:2330-2351`)。
5. **防静默丢行的一致性**:INSERT..RETURNING 时 SELECT 策略也以 WCO 形式出现而非 securityQuals,否则"写入被过滤"会被静默吞掉(:278-301);INSERT..ON CONFLICT 对冲突旧行用 WCO_RLS_CONFLICT_CHECK 强制 USING 语义报错化(:308-361);MERGE 把 UPDATE/DELETE 的 USING 也做成 WCO_RLS_MERGE_UPDATE/DELETE_CHECK,注释自述"报错而非静默忽略,与 ON CONFLICT 一致"(:438-443);UPDATE/DELETE FOR PORTION OF 的遗留行补 INSERT WCO(:396-419)。WCOKind 全集见 `src/include/nodes/parsenodes.h:1392-1401`,WithCheckOption 节点(含 polname/cascaded)在 :1404-1410。
6. **一句话语义差**:USING 答"这行**看得见吗**"(看不见=当不存在,防侧信道),WITH CHECK 答"这行**写得进吗**"(写不进=错误)。UPDATE 两者都要:旧行必须可见(USING),新行必须合规(WITH CHECK)。
7. 收尾:`setRuleCheckAsUser` 把 checkAsUser 复制进 quals/WCO,策略子查询里的其他表按同一身份做权限检查(:562-563);`hasRowSecurity=true`(:569)。分区表同样注入(relkind 判定 :119-120);继承子表 RTE 不带自己的 securityQuals,父级 quals 传播下发(`src/backend/optimizer/util/inherit.c:471-494,913-926`)。

### 3.1 执行器侧 WCO 调用点一览(均按 WCOKind 过滤后求值)

| 写路径 | 调用点(nodeModifyTable.c) | WCO kind |
|---|---|---|
| INSERT | :1112 | WCO_RLS_INSERT_CHECK |
| UPDATE | :2501 | WCO_RLS_UPDATE_CHECK |
| INSERT..ON CONFLICT(取冲突行) | :3232、:3376 | WCO_RLS_CONFLICT_CHECK |
| MERGE(WHEN 判定后,按动作) | :3652 | WCO_RLS_MERGE_UPDATE/DELETE_CHECK |
| WCO ExprState 编译 | :5470-5489 | 全部 |

- 求值统一走 `ExecWithCheckOptions`(`src/backend/executor/execMain.c:2296-2336`):`forboth` 遍历 ri_WithCheckOptions/ri_WithCheckOptionExprs,kind 不匹配跳过(:2326-2327),`ExecQual` 为 false/NULL 即报错(:2336)。
- NULL 语义:USING 为 NULL → 行不可见(过滤);WCO 为 NULL → 校验失败(报错)。两侧都按三值逻辑从严处理。

## 4. 组合语义专节:PERMISSIVE 之间 OR,RESTRICTIVE 之间 AND

筛选(`src/backend/rewrite/rowsecurity.c:580-694`):按 polcmd 匹配(:596-633;MERGE 无独立 polcmd,借用其它命令策略 :620-627)与角色匹配(:639;`check_role_for_policy` :955-972——`roles[0]==ACL_ID_PUBLIC` 快速放行,否则 `has_privs_of_role` 按成员关系判定)分入 permissive/restrictive 两个列表;RESTRICTIVE 按名排序保证 WCO 报错顺序确定(:652,:704-726);扩展 hook 可追加两类策略(:659-693,hook 类型声明 `src/include/rewrite/rowsecurity.h:37-42`,实例 :86-87)。

合成(`add_security_quals` :739-818):

```c
if (permissive_quals != NIL) {
    /* RESTRICTIVE: 逐个 append → 相互之间隐式 AND */
    foreach(item, restrictive_policies) {
        ...
        *securityQuals = list_append_unique(*securityQuals, qual);
    }
    /* PERMISSIVE: 合成单个 OR 布尔表达式 */
    if (list_length(permissive_quals) == 1)
        rowsec_expr = (Expr *) linitial(permissive_quals);
    else
        rowsec_expr = makeBoolExpr(OR_EXPR, permissive_quals, -1);
    ...
} else
    /* 无任何 PERMISSIVE → 恒 false,默认拒绝 */
    *securityQuals = lappend(... makeConst(BOOLOID, ... BoolGetDatum(false), ...));
```

精确规则(最终可见性谓词):

```
可见(row) = (P1 OR P2 OR ... OR Pn) AND R1 AND R2 AND ... AND Rm
其中: n=0 时整式为 false(默认拒绝); m=0 时只剩 OR 部分;
      R 在 P 不存在时也救不了 —— RESTRICTIVE 只能收紧,不能放行。
```

示例(策略全部适用于当前用户):

```
策略: p_admin(PERMISSIVE, ALL)   p_sales(PERMISSIVE, SELECT)   r_audit(RESTRICTIVE, ALL)

SELECT 可见性 = (p_admin.qual OR p_sales.qual) AND r_audit.qual
INSERT 校验   = WCO{ (p_admin 的 with_check(缺省用 qual)) }   -- p_sales 不参与 INSERT
                叠加 WCO{ r_audit }(独立报错, 按名排序)
```

- WCO 侧同构:permissive 合成**一个** polname=NULL 的 WCO(注释:违反意味着"没有任何策略放行",而非某个具体策略被违反,:879-900);restrictive 每策略单独 WCO 并带 polname,便于错误信息定位到策略(:902-928);无 permissive → 单条恒 false WCO(:930-948)。
- 默认拒绝是隐式的:开了 `relrowsecurity` 却没有适用于你的 permissive 策略 → 看到并写入 0 行,无需建"deny 策略"(文件头注释 :9-11)。
- 语义记忆法:PERMISSIVE=授权池(投票制,一票通过),RESTRICTIVE=否决池(一票否决)。

## 5. 绕过专节:BYPASSRLS / owner / 超级用户

全部收敛在 `check_enable_rls`(`src/backend/utils/misc/rls.c:51-133`):

```c
if (relid < (Oid) FirstNormalObjectId)   return RLS_NONE;   /* 内建表 :62-63 */
...
if (has_bypassrls_privilege(user_id))    return RLS_NONE_ENV;  /* :87-88 */
amowner = object_ownercheck(RelationRelationId, relid, user_id); /* :98 */
if (amowner) {
    if (!relforcerowsecurity || InNoForceRLSOperation())
        return RLS_NONE_ENV;                                  /* :116-117 */
}
if (!row_security && !noError)           ereport(ERROR, ...);  /* :124-129 */
return RLS_ENABLED;                                           /* :132 */
```

- **信任锚 1 — BYPASSRLS/超级用户**:`has_bypassrls_privilege`(`src/backend/catalog/aclchk.c:4217-4234`)先 `superuser_arg` 短路("Superusers bypass all permission checking")再查 `rolbypassrls`——超级用户恒等价于 BYPASSRLS,这是安全模型的信任根。
- **信任锚 2 — 表属主**:owner 默认绕过;`ALTER TABLE FORCE ROW LEVEL SECURITY`(`ATExecForceNoForceRowSecurity`,tablecmds.c:19322 起)可把 owner 也罩住;但 `SECURITY_NOFORCE_RLS` 标志(`src/include/miscadmin.h:323`,判定函数 `InNoForceRLSOperation` 在 `src/backend/utils/init/miscinit.c:649`)例外——供 RI(外键)触发器等内部代码以属主身份免于 FORCE RLS,注释明确这是有意只在"确认为 owner"后判断(:106-114)。
- **RLS_NONE_ENV 的用意**:本次没注入策略,但结论随 role/GUC 变化,故标记 hasRowSecurity 让 plancache 在环境变化时重规划——"绕过"是查询级动态属性,不是表属性。
- **逃生阀 GUC**:`row_security`(bool,默认 on,"Enables row security",`src/backend/utils/misc/guc_parameters.dat:2592-2597`)off 时,非绕过用户查询将受 RLS 影响的表直接报错(:124-129,owner 场景附提示)——防止应用在不知情下静默拿到部分数据。
- **防旁路泄漏的哨兵**(noError=true 的两类消费方):唯一约束冲突的索引值描述(`src/backend/access/index/genam.c:207`)与 NOT NULL 违例行描述(`src/backend/executor/execMain.c:2480`)在 RLS 启用时直接返回 NULL,不给用户偷看不可见行的机会;权限检查函数注释亦声明 ACL 通过≠行可见,须再过 check_enable_rls(`src/backend/executor/execMain.c:578-585`)。
- **运维速记**:判断"当前角色对该表 RLS 是否生效"用 SQL 函数 `row_security_active`(noError=true 包装,:141-167)。
- **判定顺序速记**(自上而下短路):
  1. 内建表(OID < FirstNormalObjectId)→ 永不注入(:62-63);
  2. 表未 ENABLE → RLS_NONE(:77-78);
  3. BYPASSRLS/超级用户 → 绕过(:87-88);
  4. owner 且未 FORCE(或处于 RI 的 NOFORCE 上下文)→ 绕过(:98-118);
  5. `row_security=off` → 报错(:124-129);
  6. 否则注入策略(:132)。
  3/4 返回 RLS_NONE_ENV 而非 RLS_NONE,正是为了让 plancache 感知"绕过可能随时失效"。

## 6. 设计动机

1. **为什么在重写期而非执行器注入**:策略本质是"把谓词加进查询",重写期注入后能被规划器完整优化——索引选择、join 顺序、等价类推导、分区裁剪都适用;执行器钩子只能逐行白算。代价是策略必须能表达为当前查询树上的表达式(带 SubLink 也支持,只是更贵,且需二次加锁/RIR)。配套的安全机制是 securityQuals 的 security_level:优化器不会把用户条件下推/重排穿过 RLS 条件而造成信息泄漏(`src/backend/optimizer/plan/initsplan.c:1949-1989`,逐子列表递增;连 eager aggregation 在 qual_security_level>0 且聚合非 leakproof 时都放弃 :816-820)。规划结束后最终计划 RTE 不再携带 securityQuals(`src/backend/optimizer/plan/setrefs.c:583`),它们已融入 baserestrictinfo。
2. **为什么规则系统在前、RLS 在后**:视图展开后底层表浮出水面,RLS 才能对"用户真正读到的表"生效;后注入天然让 RLS 条件先于视图 barrier 条件求值;策略子查询又要独立防递归(策略引用自身表的子查询)。
3. **为什么 PERMISSIVE/RESTRICTIVE 分开**:纯 OR 集合下"多策略=更宽松",无法表达"无论谁授权都必须同时满足 X"(审计兜底、租户隔离上限)。OR 组(P)叠 AND 组(R)让 R 成为"不可被授权方绕过的全局约束",这是编写多租户强制边界的唯一抓手;也解释了为何无 PERMISSIVE 时是默认拒绝而非"只看 RESTRICTIVE"。
4. **为什么 owner 默认绕过**:RLS 的目标是"不可信用户对可信存储的分权";owner 既建表又写策略,若策略反过来约束 owner 会自举悖论。FORCE RLS 是给"应用以 owner 连接但想自我约束"的补丁;RI 例外(SECURITY_NOFORCE_RLS)保证外键检查不被策略卡死——信任链终点仍是超级用户。
5. **为什么策略缓存绑 relcache 而非 syscache**:策略完全依附表而存在,生命周期与表一致,表级失效粒度足够;省一套 syscache 与失效协议;equalRSDesc 比较兜底"失效但内容未变"的常见情形(如 pg_class 连带失效)。
6. **为什么 WCO 违反报错而 USING 违反静默**:读路径"行不存在"是合理语义,且让用户无法区分"没有"与"没权限"(防侧信道);写路径若静默丢行,"写入成功却查无此行"违背最小惊讶,故冲突路径、RETURNING 路径统一报错化(§3.5)。
7. **为什么 RLS 不复用 GRANT**:ACL 是列/表粗粒度的"能否摸到表",RLS 是行粒度的"哪些行可见可写",两者正交且按序生效——先 `ExecCheckPermissions` 查 ACL,重写期再注入行条件(`execMain.c:578-585` 注释明确分工)。BYPASSRLS 亦不豁免 GRANT,反之 GRANT 也给不了绕过。
8. **为什么性能敏感者常抱怨 RLS**:策略表达式与用户谓词一样参与逐行求值,索引可用性取决于表达式形态(如 `tenant_id = current_setting(...)`)是否 sargable;策略含 SubLink 时退化为子计划逐行触发。优化空间全在"把策略写可优化",而非内核特判——内核只保证安全等级不降。

## 7. FAQ 素材

1. RLS 开了但没建策略会怎样?→ 非绕过用户 0 行:无 permissive 时注入恒 false qual(`rowsecurity.c:814-817`)。
2. RLS 检查在执行器哪一步?→ 可见性在扫描 qual(baserestrictinfo);写校验在各写路径的 `ExecWithCheckOptions`,按 WCOKind 分批调用(`nodeModifyTable.c:1112/2501/3232/3376/3652`)。
3. 为什么改了策略 prepared statement 还有旧行为?→ DDL 会发 relcache 失效,策略本身即时生效;prepared statement 另受 dependsOnRLS 约束,role/row_security 变即重规划(`plancache.c:738-743`);RLS_NONE_ENV 时 hasRowSecurity 标记保证这一点(`rowsecurity.c:141-151`)。
4. 视图会绕过底层表 RLS 吗?→ 不会,以视图属主身份评估底层表;`security_invoker` 才回到调用者(`rewriteHandler.c:3643-3646`)。
5. 一个表能同时有多条策略吗?→ 能,同名不允许((polrelid,polname) 唯一,`pg_policy.h:60`);permissive 间 OR、restrictive 间 AND,先 OR 后 AND。
6. UPDATE 为什么可能同时叠加 SELECT 策略?→ WHERE/RETURNING 触发 ACL_SELECT 权限需求时叠加 SELECT USING(`rowsecurity.c:240-256`);SELECT FOR UPDATE/SHARE 同理叠加 UPDATE USING(:195-209)。
7. COPY 受 RLS 影响吗?→ RLS 启用时 COPY 被改写成 `COPY (SELECT * FROM t)` 走查询管线(`copy.c:231-242`);未启用则走原始路径。
8. TRUNCATE 受 RLS 吗?→ 不受,polcmd 只有 all/select/insert/update/delete 五种(`policy.c:119-141`),TRUNCATE 属表级 DDL。
9. 策略表达式能引用别的表吗?→ 能(SubLink);`hassublinks` 预计算(`policy.c:311-312`),重写期对其子查询加锁并二次 RIR,自引用报无限递归错(`rewriteHandler.c:2282-2314`)。
10. RESTRICTIVE 策略单独用(无 PERMISSIVE)行不行?→ 行但无意义:无 permissive 即恒 false,RESTRICTIVE 只是收紧器,不能放行(`rowsecurity.c:772-817`)。
11. 策略会随表删除自动消失吗?→ 会,pg_policy.polrelid 依赖 pg_class,`RemovePolicyById` 删策略时对目标表取 AccessExclusiveLock 并失效其 relcache(`policy.c:373-406`)。
12. 为什么策略 DDL 要拿目标表的 AccessExclusiveLock?→ 注释:锁住"可能依赖该表策略集合的查询",且持锁到提交——防止并发查询看到策略集合的中间态(`policy.c:373-377`)。

## 8. 深挖方向

1. **qual_security_level 与泄漏**:securityQuals 每子列表一级,用户条件下推/等价类传播受其约束;配合 leakproof 函数决定哪些用户谓词可下沉;eager aggregation 的保守放弃是现成案例(`initsplan.c:816-820`)。
2. **RLS + 分区表**:分区表 RTE 同样注入(:119-120);子分区 RTE 不带自己的 securityQuals,父级 quals 传播(`inherit.c:471-494,913-926`);分区内 WCO 需经属性映射搬到 root 表(`execPartition.c:680` 附近;另 `execPartition.c:1813` 用 check_enable_rls)。
3. **RLS 与 EPQ/并发更新**:UPDATE/DELETE 遇并发更新走 EvalPlanQual 重试,RLS quals 在 EPQ 中的重算语义值得单独验证(策略可能含子查询,EPQ 环境下求值路径不同)。
4. **hook 扩展模型**:`row_security_policy_hook_permissive/restrictive`(`rowsecurity.c:86-87`)是接入第三方授权(外部策略服务)的官方缝;hook 策略同样参与角色过滤,restrictive 还与内置策略统一按名排序(:659-693)。
5. **继承 vs 分区的策略语义差异**:老式继承表父子各自 RTE 独立注入、各自生效;分区表只有父级 quals 传播——同样的策略定义在两种模型下可见性可能不同,易踩坑。

## 9. 写作要点速查表

| # | 事实 | 出处(文件:行) |
|---|---|---|
| 1 | RLS 注入点:重写期 fireRIRrules 末尾,刻意晚于视图规则 | rewriteHandler.c:2238-2267 |
| 2 | 注入产物:rte->securityQuals + query->withCheckOptions(前插) | rewriteHandler.c:2332-2336 |
| 3 | 非目标表一律按 SELECT 策略评估 | rowsecurity.c:164-165 |
| 4 | USING=可见性过滤(securityQuals);WITH CHECK=写入校验(报错) | rowsecurity.c:739-818 / 835-949 |
| 5 | WITH CHECK 缺省回落 USING(QUAL_FOR_WCO 宏) | rowsecurity.c:848-851 |
| 6 | 组合:(P1 OR..OR Pn) AND R1 AND..AND Rm;无 P→false | rowsecurity.c:772-817 |
| 7 | RESTRICTIVE 按名排序;permissive 单 WCO 无名,restrictive 单列带名 | rowsecurity.c:652,879-928 |
| 8 | pg_policy 字段:polname/polrelid/polcmd/polpermissive/polroles/polqual/polwithcheck | pg_policy.h:31-46 |
| 9 | 策略缓存于 relcache rd_rsdesc,无 pg_policy syscache | rel.h:119;policy.c:204-334 |
| 10 | 失效:DDL→CacheInvalidateRelcache;equalRSDesc 相同则免重建 | policy.c:406,763;relcache.c:2703,2756 |
| 11 | 绕过三锚:BYPASSRLS(含超级用户)/owner/FORCE+RI 例外 | rls.c:87-88,98-118;aclchk.c:4217-4234 |
| 12 | check_enable_rls 三态 NONE/NONE_ENV/ENABLED 决定 plancache 依赖 | rls.h:41-46;plancache.c:738-743 |
| 13 | row_security GUC off→查询受 RLS 影响即报错 | rls.c:124-129;guc_parameters.dat:2592 |
| 14 | WCO 违反报错且不回显行数据(防泄漏);索引/NOT NULL 错误同理 | execMain.c:2330-2351,2480;genam.c:207 |
| 15 | 视图以属主身份评估 RLS,security_invoker 例外 | rewriteHandler.c:3643-3646 |
| 16 | COPY 在 RLS 启用时改写为 SELECT 走查询管线 | copy.c:231-242 |
| 17 | securityQuals 逐子列表 security_level 递增,防不安全下推 | initsplan.c:1949-1989 |
| 18 | 角色匹配:PUBLIC 快速放行 + has_privs_of_role 成员判定 | rowsecurity.c:955-972 |
