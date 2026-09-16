# 第 21 章 · 行级安全 RLS:同一张表,不同用户看到不同行

> 基线:commit `8c7a74c`。行号以 src/backend/rewrite/rewriteHandler.c、src/backend/commands/rowsecurity.c、src/backend/executor/execMain.c 为准。RLS 在**查询重写阶段注入**(rewriteHandler.c:16-23 设计注释),非执行器——策略 qual 变成普通过滤条件,规划器可正常优化。

## 21.0 全景:RLS 注入管线

```
解析 → QueryRewrite(rewriteHandler.c:4783)→ fireRIRrules(:2040)
  → 视图 RIR 规则先展开(:2184-2196)
  → RLS 最后注入(:2238-2243,策略 qual 可能含 SubLink)
     get_row_security_policies(rowsecurity.c:98)
     → USING → rte->securityQuals(:2332-2333)
     → WITH CHECK → query->withCheckOptions(:2335-2336)
  → 规划器(策略 qual 当普通 qual 处理)→ 执行器(无专有算子)
```

## 21.1 USING 与 WITH CHECK

USING 答"**看得见吗**"(SELECT 静默过滤,防侧信道);WITH CHECK 答"**写得进吗**"(INSERT/UPDATE 违反报错)。**WITH CHECK 缺省回落 USING**(rowsecurity.c:848-851 QUAL_FOR_WCO 宏)。非目标表一律按 SELECT 策略(:164-165);SELECT FOR UPDATE 先叠 UPDATE USING(:195-209);UPDATE/DELETE 带 RETURNING 叠 SELECT(:240-256);ON CONFLICT/MERGE 把 USING 也报错化为 WCO(:308-393,:444-554)。

## 21.2 组合语义:PERMISSIVE OR + RESTRICTIVE AND

可见性 = **(P₁ OR…OR Pₙ) AND R₁ AND…AND Rₘ**。PERMISSIVE 合成单个 OR 布尔式(:799-805);RESTRICTIVE 逐条 append 成隐式 AND(:780-793)并按名排序保证报错顺序确定(:652)。**无 PERMISSIVE → 恒 false 默认拒绝**(:814-817)——RESTRICTIVE 只能收紧不能放行。

## 21.3 绕过:信任锚与安全边界

check_enable_rls(rls.c:51-133)的短路顺序:内建表 OID<FirstNormalObjectId(:62-63)→未 ENABLE(:77)→**BYPASSRLS/超级用户绕过**(:87-88;aclchk.c:4217-4234)→owner 绕过但 FORCE RLS 可罩住(:98-118)→row_security=off 报错(:124-129)。绕过返回 RLS_NONE_ENV 而非 NONE——**动态绕过需重规划**(plancache.c:738-743:role 或 row_security GUC 变即重规划)。

## 21.4 设计动机

1. **为什么 RLS 在查询重写阶段**:策略 qual 变成普通过滤条件——规划器可正常优化、执行器无需专有算子;**机制归机制,策略归策略**;
2. **为什么注入在视图展开之后**:策略 qual 可能含 SubLink,先注入会被 walker 二次递归(:2238-2243 注释);
3. **为什么 owner 默认绕过**:表 owner 需要维护数据(如 VACUUM/REINDEX)——FORCE RLS 才能罩住;
4. **USING 静默过滤 vs WITH CHECK 报错**:"看不见"不报错(防侧信道),"写不进"报错(必须告知)——**读写的不对称安全语义**。

## 21.5 FAQ

**Q1:RLS 策略对表 owner 生效吗?**
默认不生效,ALTER TABLE ... FORCE ROW LEVEL SECURITY 罩住(:98-118)。

**Q2:多个 PERMISSIVE 策略怎么组合?**
OR(:799-805):任一通过即可见;RESTRICTIVE 之间 AND。

**Q3:只有 RESTRICTIVE 策略会怎样?**
无 PERMISSIVE 时恒 false 默认拒绝(:814-817)。

**Q4:行级安全的性能代价?**
策略 qual 当普通过滤条件:规划器优化、索引可用;但复杂策略可能阻断索引。

**Q5:plancache 什么时候失效?**
role 或 row_security GUC 变即重规划(:738-743)——**RLS 的 plan 缓存比普通查询更敏感**。

**Q6:RETURNING 子句受 RLS 影响吗?**
是:UPDATE/DELETE 带 RETURNING 叠 SELECT 策略(:240-256)——看不到的行也不能 RETURNING。

**Q7:ON CONFLICT 的 RLS 语义?**
(:308-393):把 USING 也报错化为 WCO——冲突检测必须能看到现有行。

**Q8:BYPASSRLS 和超级用户的区别?**
都是绕过(:87-88);BYPASSRLS 是角色属性(可授予非超级用户),超级用户是全局。

**Q9:RLS 对 TRUNCATE 有效吗?**
无效:TRUNCATE 绕过所有行级操作——这是 DDL 与 DML 的边界。

**Q10:securityQuals 和普通 qual 在执行器有区别吗?**
执行器无专有算子:securityQuals 被规划器转为普通 baserestrictinfo(:1949-1989)——RLS 的"不可见"就是过滤。

## 21.6 小结与深挖方向

本章结论:**RLS="查询重写阶段注入+USING/WC 双语义+PERMISSIVE OR/RESTRICTIVE AND+信任锚绕过"**。深挖:

1. securityQuals 在并行查询(卷四 18 章)worker 的传播;
2. RLS 策略含 SubLink 时的规划器性能(:2238-2243 注释的深层原因);
3. FORCE RLS 对 owner 的 VACUUM/REINDEX 影响;
4. pg_policy 失效(relcache :2703/:2756)在多连接的传播延迟;
5. RLS 与 FDW 的组合(外部表的策略下推)。

> RLS 完——PG 安全体系的行级防线。
