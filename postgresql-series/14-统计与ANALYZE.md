# 第 14 章 · 统计与 ANALYZE:规划器的感官(卷三卷末)

> 基线:commit `8c7a74c`。行号以 src/backend/commands/analyze.c、src/backend/commands/analyze_utils?(sampling.c)、src/backend/statistics/、src/backend/utils/adt/selfuncs.c 为准。K 报告(11 章)的选择率终点是 pg_statistic——本章讲统计的生产与消费。

## 14.0 全景:生产-存储-消费

```
ANALYZE 采样(两阶段) → 统计量计算(MCV/直方图/corr) → pg_statistic(脱敏:pg_stats 视图)
                                              ↓ 规划器 selfuncs(选择率) → 11 章代价模型
```

## 14.1 采样:两阶段与 300 定理

**第一阶段块级 Knuth Algorithm S**(sampling.c:38-116,每命中块只耗一个随机数)——尊重 I/O 局部性;**第二阶段行级 Vitter Algorithm Z 蓄水池**(sampling.c:146;调用点 analyze.c:1345):池满后按"跳过数 S"随机替换——行级无偏。两阶段同流进行,代价是样本组合不完全均匀(analyze.c:1244-1257 官方注释自认)。**采样行数 = max(各列 300×attstattarget, 扩展统计要求, 下限 100)**(analyze.c:506,:2002):300 来自 Chaudhuri SIGMOD'98 直方图采样定理,且**与表大小无关**——默认 target=100 即 3 万行。样本按物理位置排序后外推活/死行数写 pg_class(analyze.c:654,:1394-1398)。

## 14.2 统计量:MCV 与直方图的分工

compute_scalar_stats(analyze.c:2464)一次算齐:nullfrac、平均宽度、stadistinct(无重复→-1 比例;全重复→枚举;否则 Haas-Stokes Duj1 估计器,:2672-2700)、MCV、直方图、相关性。**MCV 裁剪**:可完整覆盖则全留,否则按超几何 2σ+0.5 显著性从尾部裁剪(:3042,:3127-3133);**直方图先"挖掉" MCV 再等距取边界**(:2830-2898)——**MCV 管高频等值的精确频率,直方图只管长尾插值**,两者互斥覆盖。相关性=物理序 vs 逻辑序的闭式相关系数(:2943)——11 章索引代价 correlation² 修正的来源。存储经 update_attstats 按 (relid,attnum,inh) upsert(analyze.c:1717,:1835);5 槽位开放设计(STATISTIC_NUM_SLOTS=5,pg_statistic.h:131;kind 1=MCV/2=直方/3=corr/4=MCELEM)。扩展统计三件套(ndistinct/函数依赖/多列 MCV)由 BuildRelationExtStatistics 构建(extended_stats.c:112,:205-210),依赖度消费时按 P(a,b)=f·P(a)+(1-f)·P(a)·P(b) 修正独立性假设。

## 14.3 消费:eqsel 的双路径

规划器经 SearchSysCache3(STATRELATTINH) 取统计(selfuncs.c:6072)。**eqsel→var_eq_const**(:370):常量在 MCV 中→直接用采样频率;不在→(1-sumcommon-nullfrac)/其余 distinct;**无统计兜底 1/DEFAULT_NUM_DISTINCT(=200)**。**scalarineqsel**(:655)=MCV 部分+直方图二分插值(ineq_histogram_selectivity,:1117;端点还会用索引实时 min/max 修正陈旧统计),合并公式 (1-nullfrac-sumcommon)×hist_selec(:769-777)。LIKE 提取固定前缀后退化走 eqsel/直方图(like_support.c:648)。**脱敏双层**:pg_stats 视图按列权限+RLS 过滤(system_views.sql:274-276,本体 REVOKE FROM public);规划器内**非 leakproof 函数禁碰受限列统计**(selfuncs.c:6685)——信息泄漏防线做进了选择率层。

## 14.4 触发与失效

autovacuum 的 relation_needs_vacanalyze **一票两判**(autovacuum.c:3287-3299):死元组→vacuum(G 章);**mod_since_analyze>阈值→analyze**(计数器 pgstat_relation.c:947)。统计更新**不失效**已缓存计划;DDL 才走 SI 失效 rd_statlist(relcache.c:4985)——**统计陈旧是慢性病,DDL 是急性事件**:两级失效的刻度差。

## 14.5 与前作对照与设计动机

| | PG | MySQL | SQLite |
|---|---|---|---|
| 统计 | 独立 pg_statistic+扩展统计 | 引擎各自(dict/持久直方图) | 无独立统计 |
| 采样 | 两阶段无偏 | 可配 | 无 |
| 消费 | selfuncs 家族 | cost 接口 | 内嵌小模型 |

1. **为什么采样两阶段**:纯行级随机破坏 I/O 局部性,纯块级引入块内相关性——Algorithm S+Z 各取一半,不均匀的代价被注释承认(:1244-1257);
2. **300×target 与表大小无关**:采样理论直方图只需常数样本——"统计的输入规模是精度的函数,不是数据的函数";
3. **MCV/直方图互斥覆盖**:高频精确+长尾插值——按值的分布形状分治;
4. **脱敏做到选择率层**(:6685):非 leakproof 函数不能"透过谓词偷看统计"——安全边界画在数据流的最细处。

## 14.6 FAQ

**Q1:ANALYZE 读全表吗?**
不:3 万行样本(默认)——300×target 与表大小无关(:2002)。

**Q2:MCV 最多多少个?**
采样能支撑的显著性内(:3127-3133 的 2σ 判据);default_statistics_target 决定样本量间接决定。

**Q3:统计和实际差很多怎么办?**
扩展统计(多列相关性)/提高 target/手动 ANALYZE;端点还会用索引 min/max 修正(:1117)。

**Q4:为什么 ANALYZE 后计划没变?**
统计不失效计划缓存(14.4):generic 计划只在重规划时用新统计。

**Q5:n_mod_since_analyze 在哪看?**
pg_stat_user_tables;autovacuum 一票两判(:3287-3299)自动触发。

**Q6:无统计的选择率是多少?**
1/200(兜底 distinct)(selfuncs.c:370)——宁可粗糙不空转。

**Q7:LIKE 的选择率怎么算?**
提取固定前缀退化为等值/直方图(like_support.c:648)——模式匹配的选择率也是"结构化"的。

**Q8:pg_statistic 谁能看?**
超级用户;普通用户走 pg_stats 视图(列权限+RLS 过滤,:274-276)。

**Q9:扩展统计什么时候有用?**
列间相关时(城市→邮编):函数依赖修正独立性假设(:205-210)。

**Q10:相关性统计对什么敏感?**
插入顺序:物理序被打乱后 correlation 退化→索引代价高估——CLUSTER/定期重排是对症药。

## 14.7 小结与卷三卷末语

本章结论:**统计="两阶段无偏采样+MCV/直方图分治+脱敏到选择率层"**;它是规划器(K 章)的感官,感知精度决定优化上限。

至此《PostgreSQL 深读》卷三完(11-14:规划器/分区/TOAST/统计),基线 commit 8c7a74c。三卷共 14 章+14 份报告,PG 的存储/执行/优化全骨架闭合。全系列横向对照的 PG 证据已回填 cross-series/00 的模式 3(VACUUM)、5(两阶段 DETACH)、10(clog/subtrans 持久化分级)。深挖方向:

1. Algorithm S/Z 的混合(:38-116,:146)在大块表的偏差量化;
2. Haas-Stokes Duj1(:2672-2700)在超高频重复列的估计误差;
3. 扩展统计依赖度(:205-210)与独立性假设的合成公式适用域;
4. non-leakproof 禁令(:6685)的绕过面(视图/RLS 组合);
5. 端点 min/max 修正(:1117)与陈旧统计的博弈。

— 《PostgreSQL 深读》卷三完。AI 编码助手:GLM-5.3-Flash。
