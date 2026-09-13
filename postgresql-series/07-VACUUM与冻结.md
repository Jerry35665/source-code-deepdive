# 第 07 章 · VACUUM 与冻结:三重债的清偿

> 基线:commit `8c7a74c`。行号以 src/backend/commands/vacuum.c、src/backend/access/heap/vacuumlazy.c、pruneheap.c、heapam.c、src/backend/access/transam/varsup.c 为准。

## 7.0 全景:三重债模型

MVCC 旧版本就地留下(06 章),于是每张表同时欠**三种债**:

```
①空间债    死元组占堆页+索引死 TID → 表/索引膨胀
②可见性债  死元组的 xmin 需查 clog 作证 → clog 不能截断(卷一 04 闭环)→ WAL 增长
③wraparound 债  XID 32 位模 2^31 环形比较,最老 XID 绕半圈(≈21 亿)追上最新 → 数据静默丢失
```

VACUUM 一趟收三样:prune+索引清理+truncate(空间)、推进 relfrozenxid→datfrozenxid→vac_truncate_clog(可见性)、freeze(wraparound)。**一张表不 VACUUM,全集群的 clog 与 XID 水位都被它拖死**——这是"个人债务集群化"。

## 7.1 主流程:五阶段与 TidStore

`heap_vacuum_rel`(vacuumlazy.c)五阶段(:624 cutoffs→:801 TidStore 分配→:880 扫堆→:910 truncate→:971 更新 pg_class)。**OldestXmin 的确定**:GetOldestNonRemovableTransactionId(vacuum.c:1161,procarray.c:1944)——比任何活跃快照都保守的地平线,死元组的判定基准(06 章快照的 VACUUM 版:SatisfiesVacuum)。死元组收集容器是 **TidStore(radix tree)**(vacuumlazy.c:3497,底层 tidstore.c:7);小表走 bypass(2% 页+32MB 阈值,:187,:2448-2450);TidStore 超 max_bytes 时**中途先清一轮索引再继续扫**(:1352-1372)——老"多轮扫描"的新形态。**failsafe**:relfrozenxid 落后超 Max(16 亿,max_age×1.05) 即放弃索引清理只赶冻结(vacuum.c:1294,:1309)——wraparound 危急时空间债让路。

## 7.2 页级 prune:四种处置

on-access prune 的触发三条件(pruneheap.c:271,:287,:297,:310):pd_prune_xid 提示+可判死+页满。处置分类(:1736 REDIRECT/:1767 DEAD/:1828 UNUSED):REDIRECT 让版本链绕过死版本、DEAD 等索引确认、UNUSED 直接回收。**HOT 的黄金约定**(heapam.c:4068-4077):更新同页且索引列未动→HOT 链整链 prune、**索引零维护**——索引列稳定是性能的第一纪律。

## 7.3 冻结:把时间戳变成"永远"

freeze 判据(heapam.c:7271 heap_prepare_freeze_tuple):**xmin < OldestXmin**(:7300,人人可见→不再需要"何时提交"信息);页级由 heap_tuple_should_freeze(:8090)按 FreezeLimit 判定(FreezeLimit≤max_age/2 且≤OldestXmin,vacuum.c:1213-1222)。实现是**位+字段作废**而非"写 2":infomask 打 HEAP_XMIN_FROZEN=COMMITTED|INVALID(htup_details.h:206,heapam.c:7449-7452),xmax 重写为 Invalid(heapam.h:533-543);读侧见 FROZEN 位即按 FrozenTransactionId=2 处理(htup_details.h:329-333)。MultiXact 冻结四出路(FreezeMultiXactId,heapam.c:6915),早于 relfrozenxid 直接报数据损坏(:7294-7297)。PG17 起 freeze 无独立 WAL——PRUNE 记录内嵌 freeze plan(heapam_xlog.h:399-400,pruneheap.c:2589,:2733-2739)。

## 7.4 wraparound:三级防御

XID 32 位环形比较(transam.h:35),四级水位(varsup.c:384,:400,:414,:437):绕半圈(≈21 亿)即 wrap 危险;Warn=−1 亿;Vac=+max_age(默认 2 亿,guc_parameters.dat:159);Stop=−300 万。防御三级(GetNewTransactionId,varsup.c:63,:152,:168):警告→强制 anti-wraparound autovacuum→**拒绝分配新 XID(单用户模式救援)**——最后一道是停服,因为 wraparound 的后果是数据静默错乱,停服是唯一理性选择。

## 7.5 自动化:launcher/worker 与限速

autovacuum launcher/worker 双进程(autovacuum.c:406,:1413,:3251-3263):launcher 按 naptime 轮询,触发公式 **50+0.2×reltuples**(:3251-3263;naptime 60s,guc_parameters.dat:210)——死元组比例驱动的触发,非定时。worker 的 cost 限速(VacuumCost sleep)让 VACUUM 对前台 IO 温和——与 02 章 ring buffer 同一哲学:**批处理自律**。

## 7.6 与前作对照与设计动机

| 系统 | 清偿对象 | 机制 |
|---|---|---|
| PG VACUUM | 空间+可见性+wraparound 三债 | 扫描+prune+冻结 |
| LevelDB compaction | 空间债(key 旧版本) | 分层重写 |
| Git gc | 空间+可达性债 | repack+cruft 宽限 |
| Redis | 过期/淘汰 | 渐进+惰性 |

1. **为什么旧版本就地留**:原地更新需要回滚日志+锁等待(传统 DB),就地留版本换来"读者永不等待"——VACUUM 是这笔交易的分期付款;
2. **freeze 是"时间戳的退休"**:xmin<OldestXmin 的元组永远可见,事务 ID 信息可弃——按"信息还有没有读者"决定保留,与 clog 截断(卷一 04)同一判据;
3. **failsafe 的优先级设计**:三债冲突时 wraparound>空间——数据正确性>性能,不可协商;
4. **autovacuum 是进程而非线程**:01 章 fork 公理的自然推论,连 VACUUM 也活在隔离的地址空间里。

## 7.7 FAQ

**Q1:不 VACUUM 会立刻出问题吗?**
不会立即:三债缓慢累积——表膨胀(慢)、clog 不截断(WAL 堆)、半圈后强制停服——最后一击最重。

**Q2:VACUUM 会锁表吗?**
ShareUpdateExclusive(与 DDL 互斥,与 DML 兼容):正常业务不停;truncate 尾页需短暂独占。

**Q3:freeze 后的 xmin 变成什么?**
不是写 2:打 FROZEN 位+xmax 作废(:7449-7452),读侧按 2 处理(:329-333)——位+字段的混合方案保留原值调试能力。

**Q4:为什么 HOT 更新这么重要?**
索引零维护(:4068-4077):索引只存 TID,行迁移就要改所有索引——HOT 链让"更新"对索引不可见。

**Q5:autovacuum 触发公式里的 50 是什么?**
死元组阈值:50+0.2×reltuples(:3251-3263)——小表 50 行起步,大表 20% 比例。

**Q6:failsafe 放弃索引清理为什么?**
(:1294-1309):wraparound 危急时只赶冻结——空间债可以拖,时间债不能。

**Q7:VACUUM FULL 和 VACUUM 差在哪?**
FULL=重写整表(锁写、空间立还);普通 VACUUM=原地清(不还空间给 OS,truncate 尾页除外)。

**Q8:长事务冻结 VACUUM 怎么办?**
OldestXmin 被它撑住(:1161)→死元组判不了死→全表停收——kill 长事务是唯一解。

**Q9:freeze 会写很多 WAL 吗?**
PG17 起并入 PRUNE 记录(:399-400):页级打包,一次记录管全页 freeze plan。

**Q10:为什么 wraparound 停服而不是静默错?**
环形比较失效=旧事务"看起来在未来"→可见性全错(:63-168 三级递进)——停服是诚实的失败。

## 7.8 小结与深挖方向

本章结论:**VACUUM="三债清偿器"(空间/可见性/wraparound),freeze=时间戳的退休机制,failsafe=正确性优先的降级**。深挖:

1. TidStore radix(:3497)在大表(亿级死元组)的内存水位;
2. HOT 断链(索引列被更新)的频率对 autovacuum 触发公式的扰动;
3. failsafe 阈值 Max(16 亿,:1294)与真 32bit 环形的安全边距推导;
4. MultiXact 冻结四出路(:6915)在高并发行锁表的膨胀;
5. PG17 PRUNE 内嵌 freeze(:2733-2739)对 WAL 体积的实测节省。

> 下一章:执行器——计划树如何变成行流。
