# 第 16 章 · BRIN 索引:极小的块范围摘要

> 基线:commit `8c7a74c`。行号以 src/backend/access/brin/ 为准。

## 16.0 全景:三类页与 revmap

```
元页(块0:magic/pagesPerRange/lastRevmapPage,brin_page.h:64-75)
revmap 页(紧跟元页:整页定长 rm_tids[],每项 6 字节 TID,8kB 页约 1360 项 :78-94)
regular 页(存 BrinTuple 摘要)
每 pages_per_range(默认 128,brin.h:40)个连续堆页 → 一条 min/max 摘要
```

**revmap 是核心创新**:块号→摘要位置只做两次除法/取模:`HEAPBLK_TO_REVMAP_BLK/INDEX`(brin_revmap.c:40-43)——O(1) 反向映射,零 B-tree。摘要 tuple:4 字节 bt_blkno+1 字节 bt_info(placeholder/empty/hasnulls)+双倍长 NULL 位图+opclass 的 Datum(brin_tuple.h:63-93)。无 amgettuple 仅 amgetbitmap;amsummarizing=true(brin.c:254-313)。

## 16.1 summarization:摘要的生成与失真

- 插入维护 brininsert(brin.c:348-511):摘要不匹配才更新;brin_doupdate 同页覆写或搬家+改 revmap(brin_pageops.c:52-316);
- **失真规则:minmax 只扩不缩**(brin_minmax.c:94-122);删除/更新不收紧——**brinbulkdelete 是 no-op**(brin.c:1307-1316);一个离群值把区间撑 1000 倍(brin_minmax_multi.c:12-26 注释);
- 补摘要=**全扫该 range**:summarize_range 先插 placeholder 防并发漏值,再只扫这 128 堆块(brin.c:1762-1875);入口 VACUUM(:1322-1347)、brin_summarize_new_values/range(:1370-1490)、desummarize(:1495-1580);
- **autosummarize**:插入跨入新 range 第一行时 AutoVacuumRequestWork(AVW_BRINSummarizeRange)(brin.c:393-425),autovacuum 执行(:2739-2743)。

## 16.2 查询与代价模型

bringetbitmap(brin.c:745):`for heapBlk += pagesPerRange` 顺序走 revmap,每 range 读摘要做范围判定;**未摘要 range 无条件全收进位图**(:770-773,正确性保证)。代价模型(selfuncs.c:9297-9300):`estimatedRanges = minimalRanges/correlation`——**correlation(物理序与逻辑序的相关性)决定一切**:时间序列(完美相关)的 BRIN 极小极快,乱序写入则退化到全表。

## 16.3 与 B-tree 对照及设计动机

| | BRIN | B-tree |
|---|---|---|
| 大小(1TB 表) | ~MB 级 | GB 级 |
| 更新 | 摘要只扩不缩 | 每行维护 |
| 适用 | 自然有序(时间/序列) | 任意 |
| 精度 | range 级 | 行级 |

1. **为什么 BRIN 这么小**:每 128 块一条摘要——压缩比=128×(行宽/摘要宽);**"范围摘要"假设物理相关性**,PostgreSQL 的 correlation 统计(卷二 05 章)正是其输入;
2. **为什么删除不收紧摘要**(bulkdelete no-op):收紧=重扫全部 range——BRIN 的取舍是"误收可接受,漏收不可发生";
3. **autosummarize 的意义**:时间序列的自然追加会产生大量未摘要空 range——插入时顺手摘要避免查询时集中补;
4. **失效与重建**:失真的摘要只能 desummarize+重建(:1495-1580)——与 Git desummarize? 与卷一 GIN pending 的"重算优于修补"同族。

## 16.4 FAQ

**Q1:BRIN 多大?**
1TB 时间序列表:摘要 ~几 MB——**体积是它的卖点**。

**Q2:BRIN 查询为什么可能全表扫?**
未摘要 range 无条件全收(:770-773);离群值撑大 min/max 同样全收。

**Q3:revmap 扩页时老摘要去哪?**
(:521-620):占用目标块的 regular 页先疏散(BRIN_EVACUATE_PAGE)。

**Q4:minmax-multi 是什么?**
多区间摘要(opclass 之一):比单 min/max 精细,比 bloom 小——中间形态。

**Q5:删除行会更新摘要吗?**
不会(bulkdelete no-op :1307-1316):摘要失真只能靠重建。

**Q6:correlation 从哪来?**
pg_statistic(卷三 14 章 ANALYZE):物理序 vs 逻辑序的相关系数。

**Q7:pages_per_range 怎么调?**
默认 128(brin.h:40):越小越精越 大——随查询模式调。

**Q8:BRIN 能做唯一约束吗?**
不能:摘要无法表达唯一性——语义上限。

**Q9:并发插入同一 range?**
brin_doupdate 同页覆写或搬家(:52-316):revmap 项同步改写(:228-315)。

**Q10:BRIN 适合主键吗?**
仅当主键与物理序强相关(自增 ID):随机主键的 BRIN 无意义。

## 16.5 小结与深挖方向

本章结论:**BRIN="revmap O(1)+range 摘要+只扩不缩的失真模型"**;"物理相关性=索引效率"是它的一切前提。深挖:

1. minmax-multi(:12-26)的多区间距离算法;
2. bloom opclass(pg_opclass.dat)的假阳性率调参;
3. summarization 的 placeholder(:1762-1875)在并发插入的防漏证明;
4. revmap 疏散(:521-620)与 VACUUM 的页锁交互;
5. correlation(:9297-9300)在 CLUSTER 后的衰减曲线。

> 下一章:WAL 归档与 PITR。
