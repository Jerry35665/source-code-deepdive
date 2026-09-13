# 第 06 章 · MVCC 与快照:可见性判定的完整矩阵

> 基线:commit `8c7a74c`。行号以 src/include/access/htup_details.h、src/backend/access/heap/heapam_visibility.c、src/backend/utils/time/snapmgr.c、src/backend/storage/ipc/procarray.c 为准。这是 PG 的灵魂章:每行数据能不能看,由"元组头×clog×快照"三元输入决定。

## 6.0 全景:三元判定

```
元组头(每行自带 xmin/xmax) ─┐
clog(每事务 2bit 状态,卷一 04)─┼→ HeapTupleSatisfiesVisibility → live/dead/in-progress
快照(事务的"现在"边界)   ─┘
```

MVCC 的核心决策:**可见性放元组头而非中央表**——每行自带自己的"时间凭证",判定无需加锁(中央表会成为瓶颈),代价是旧版本就地堆积(07 章 VACUUM 的根源)。

## 6.1 元组头:23 字节的时间凭证

逐字段(htup_details.h:153-181):t_xmin(创建者事务)/t_xmax(删除者)/t_cid(命令序)/t_ctid(版本链指针)/t_infomask/t_bits。infomask 关键位(:204-219):XMIN_COMMITTED=0x0100、XMIN_INVALID=0x0200、XMAX_COMMITTED=0x0400、XMAX_INVALID=0x0800、XMAX_IS_MULTI=0x1000;**冻结=XMIN 两位置位**(07 章)。版本链:heap_update 末行 `oldtup.t_data->t_ctid = heaptup->t_self`(heapam.c:4212-4218;ctid 语义注释 htup_details.h:86-112)——**更新即造新版本+链表衔接**,旧版本原地不动。

## 6.2 可见性矩阵:两段式裁剪

入口分派 8 个 Satisfies 函数(heapam_visibility.c:1731-1749):MVCC 主判(:938-1096)、Update(:510-736,返回 TM_* 六态)、Dirty(:758-914)、Vacuum(:1112-1329)、Historic(:1504-1671,逻辑解码用)。MVCC 判定是**两段式:先裁 xmin 再裁 xmax**:

| xmin 状态 | 结果(行号) |
|---|---|
| 本事务 | 看 cmin vs curcid |
| 在快照 xip 内 | **不可见**(:1005-1006,不查 clog——快照已经给出答案) |
| 提示位已提交但**在快照内** | **仍不可见**(:1018-1024,"当作在跑") |
| 已提交且不在快照 | 可见,**埋提示位** |
| 已中止 | 不可见 |

xmax 侧(:1086-1095):0/INVALID/仅锁→可见;删除者未决→看 cmax;**已提交但删除者还在快照内→可见**(老快照看不见新删除)。关键语义:提示位说"已提交",但 XID 在快照内时仍当在跑——**提示位是加速器不是裁决者**,快照永远优先。

## 6.3 快照:ProcArray 的扫描与复用

SnapshotData(snapshot.h:138-210):xmin(最老运行事务)/xmax(latestCompletedXid+1,:2194-2196)/xip[](运行中事务数组)/subxip[]/curcid。`GetSnapshotData`(procarray.c:2113-2466)是全系统最热路径之一:共享锁(:2178)→扫 proc 数组收集 xip(:2220-2311,跳过无 XID/自己/≥xmax/逻辑解码/VACUUM 的进程)→安装 MyProc->xmin(:2360-2361)。**复用快路径**:GetSnapshotDataReuse(:2033-2079)——xactCompletionCount 未变则免扫(计数器方案又一次替代遍历)。子事务 64 缓存溢出标 suboverflowed(:2291-2292;proc.h:44),XidInMVCCSnapshot 对溢出的折算走 subtrans 顶层事务(snapmgr.c:1947)。

## 6.4 hint bits:谁先读谁埋

提示位(SetHintBitsExt,:141-192)把"clog 查询结果"就地写进元组头,后续判定免查 clog。两个精巧细节:**LSN 互锁**(:152-166)——提交记录的 WAL 未刷盘且页 LSN 更旧时不写位(防止页先于 WAL 落盘,03 章 WAL 先行);**延迟埋位**(:922-936 注释:热路径不抢 ProcArrayLock)。埋位安全吗——多进程并发写同一位,任何顺序结果一致,无需锁。批量化(:1689-1719)一次处理整页。

## 6.5 隔离级别:快照的选择点

选择逻辑在 snapmgr.c:271-346(xact.h:52-53 的级别枚举):**RC 每语句重取**(:343,调用点 postgres.c:1186/1541/1824——每条语句看到"新的现在");**RR 首快照注册复制**(:316-329,整个事务冻结);SERIALIZABLE 走 SSI 的谓词冲突检查(predicate.c:1611,核心 :3952/:4265)——三个级别的差异本质是"快照换得多勤"。

## 6.6 与前作对照与设计动机

| 系统 | 可见性机制 |
|---|---|
| PG | 行级 MVCC:元组头+clog+快照三元 |
| etcd | key 级 MVCC:revision 全序+compact |
| SQLite | 单写者:WAL 快照读,无行级判定 |
| LevelDB | 无事务可见性(单事务语义) |
| Kafka | offset 消费位点(非事务可见性) |

1. **可见性进元组头**:判定免锁、无需中央索引——代价是旧版本堆积+VACUUM 子系统(07 章),**成本守恒,记账位置的选择**;
2. **快照是"时间的一次性照片"**:xip 数组+边界数,19 行字段(snapshot.h:138-210)承载全部隔离语义;
3. **hint bits 是乐观缓存的极致**:多写无锁正确(交换律)+LSN 互锁防越序——两个不变式支撑一个"看起来危险"的优化;
4. **复用计数器**(xactCompletionCount)替代 proc 扫描:与 Git fanout、K8s RV 同族——"计数器变化检测"是并发系统最便宜的缓存键。

## 6.7 FAQ

**Q1:为什么提示位设了还可能看不见?**
提示位只说事务已提交(:141-192);快照内 XID 仍按在跑处理(:1018-1024)——老快照不能看见新提交。

**Q2:hint bits 会写坏数据吗?**
不会:多进程写同位结果一致(交换律);LSN 互锁(:152-166)防"页比 WAL 新"。

**Q3:RR 和 RC 的实现差异就一行?**
本质是快照获取频率(:343 vs :316-329)——实现差异极小,语义差异极大,好设计的标志。

**Q4:long transaction 的代价具体是什么?**
撑住 xmin→VACUUM 不能收(G 章)→表膨胀+clog 不截断+WAL 增长——一个事务拖全集群。

**Q5:子事务超过 64 个会怎样?**
suboverflowed(:2291-2292):快照仍正确,但判定退化到查 subtrans(慢)——正确性与性能分离。

**Q6:删除的数据真的马上没了?**
不,xmax 打标+版本链保留,VACUUM 后才物理回收——MVCC 的代价与红利同源。

**Q7:冻结(FROZEN)是什么位?**
XMIN_COMMITTED|XMIN_INVALID 同时置(htup_details.h:206)——"比所有快照都老"的意思,07 章展开。

**Q8:GetSnapshotData 为什么是热点?**
每条语句(RC)都调:proc 数组扫描+两个计数器——复用快路径(:2033-2079)是近年最大的优化。

**Q9:SSI 是怎么实现可串行化的?**
谓词锁记录"读写依赖",冲突时中止一方(predicate.c:1611 入口)——乐观串行化,细节留卷三。

**Q10:逻辑解码用哪个 Satisfies?**
Historic(:1504-1671):用解码快照(10 章 snapbuild)替代运行时快照——同一矩阵,不同时间源。

## 6.8 小结与深挖方向

本章结论:**MVCC="可见性进元组头+快照是时间照片+hint bits 乐观缓存"**;两段式矩阵(938-1096)是全系统正确性的核心 160 行。深挖:

1. xactCompletionCount 复用(:2033-2079)在高提交速率下的失效频率;
2. hint bits 与页校验和(data checksums)的相互作用(位变化=页变脏);
3. XidInMVCCSnapshot 的 subtrans 折算(:1947)在最深嵌套的性能;
4. HOT 链(07 章)与版本链(ctid)在长链上的扫描代价;
5. SSI 谓词锁的内存上界(predicate.c)。

> 下一章:VACUUM——为 6.6 的"成本守恒"买单的子系统。
