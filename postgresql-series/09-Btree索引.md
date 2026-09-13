# 第 09 章 · B-tree 索引:nbtree 的 MVCC 感知特化

> 基线:commit `8c7a74c`。行号以 src/backend/access/nbtree/ 为准(README 必读)。注意文件拆分:`_bt_readpage` 在 nbtreadpage.c、`_bt_preprocess_keys` 在 nbtpreprocesskeys.c(老教程指向 nbtsearch.c/nbtutils.c 已失效)。

## 9.0 全景:页族与三元组

```
metapage(0 号:真根+fastroot) → root → 内部层(pivot) → 叶层(数据,TID)
   叶层双向链(prev/next)——范围扫描可沿链走
```

页尾 special 区 `BTPageOpaqueData`(nbtree.h:63-70):btpo_prev/next 双链、btpo_level(叶=0)、btpo_flags、btpo_cycleid(VACUUM 分裂周期)。**High Key 在页首**(非最右页第 1 项是 hikey,数据从 P_FIRSTDATAKEY 起,:368-370;最右页无 hikey=隐含 +∞)——hikey 放首位是为了追加不搬动。元组三态靠 t_tid 高位区分(:460-502):非 pivot(堆 TID)/pivot(downlink)/posting(dedup 数组);metapage 存 fastroot(最低单页层,瘦树跳层,根验证 nbtpage.c:365-404);单元组上限 1/3 页(:165-169,保证页能容 hikey+2 数据项)。

## 9.1 蟹行锁:不耦合父的下降

`_bt_search` 每层:move-right 校正→页内二分→压栈→**先放父读锁再取子锁**(nbtsearch.c:184-185)。不持父锁是 Lehman-Yao 的特权:并发分裂导致跟错链接时,**hikey 越界即沿右链恢复**(_bt_moveright,cmpval=nextkey?0:1,:275-317)。锁序铁律:先取新再放旧只许向右/向上(README:106-110)——方向性防死锁。`_bt_compare` 的三处"负无穷"约定(:713-714,:793-810):内部页首数据项、被后缀截断的属性都当负无穷——**缺失即最小**的不变量让比较函数统一。范围扫描停在"页之间":整页 TID 拷入私有 currPos 并记住 prev/next(nbtreadpage.c:153-154),翻页沿记录值走——避免重扫分裂搬走的项;后向扫描有 4 步 move-left(README:330-360)。

## 9.2 分裂:空间记账与倾斜策略

`_bt_split`(nbtinsert.c:1489):把新元组假想放入页内,划分点=lastleft|firstright 缝隙;空间记账要求新元组计入一侧、左页新 hikey 两侧重复计入(nbtsplitloc.c:496-546)。**偏离中间的三个理由**:非最右页对半均分;**最右页按 fillfactor 90% 留空右页**(:95-99)——防单调追加把每页填成 50% 浪费;全同值 96%。候选点先按平衡 delta 排序,取 5%(叶)/7.5%(内部)容差区间(:850-851),区间内以**后缀截断惩罚**选最优——pivot 更小,内部页分裂更晚。hikey:叶层可截断(_bt_truncate,nbtutils.c:692),内部层禁截断(nbtinsert.c:1687-1712,须保持分隔键接缝)。分裂两段 WAL:左页打 BTP_INCOMPLETE_SPLIT(:1582),downlink 由 `_bt_insert_parent` 后补(**按子块号匹配**,nbtinsert.c:2414);右移 prev 链按左→右序锁(:1912-1914)防死锁。

## 9.3 dedup 与唯一检查

dedup(PG13+):同键元组合并成 posting 元组(nbtdedup.c:89,上限约 1/6 页)——**重复键场景的分裂延迟**;插入时优先合并而非新页。**唯一约束的 MVCC 交叉**(_bt_check_unique,nbtinsert.c:216-235,:589-601):遇 in-progress 的同键元组→放锁 `XactLockTableWait` 等对方出结果→**goto search 全重来**(等完重找,页可能已分裂)——索引一致性检查与 MVCC(06 章)的正面相遇:不能乐观,只能等待重来。

## 9.4 页删除与 VACUUM 联动

删除是两阶段:先摘叶子(half-dead,阶段一把顶父块号**藏进 hikey 的 t_tid**(nbtpage.c:2253-2255,BTreeTupleSetTopParent)),后回收内部页;**只删全空叶页**(:1906-1915),根/最右页永不删——树高不减,fastroot 承担"跳层"。VACUUM 的 bulk delete 用 G 章的 TidStore 批量过滤死 TID(nbtree 侧 _bt_delitems)——**索引侧的死元组清理由 VACUUM 统一调度**(G 章)。

## 9.5 与前作对照与设计动机

| | PG nbtree | SQLite B-tree | Git fanout |
|---|---|---|---|
| 并发 | 多进程+蟹行 | 单写者无并发页问题 | 静态只读 |
| MVCC | 死 TID 需 VACUUM | WAL 快照免死元组 | 内容寻址无删除 |
| 前缀压缩 | 后缀截断 pivot | 无 | 无 |

1. **MVCC 感知的 B-tree 为什么难**:索引键不区分版本——同一键的多个版本并存,唯一性/扫描/VACUUM 都要"跨版本思考";nbtree 的答案是"等待重来"(9.3)+死 TID 批量清(9.4);
2. **蟹行的乐观主义**:先放父锁赌不跟错,错了沿右链恢复——乐观+可恢复验证,与 FPW 判据(03 章)同构;
3. **分裂倾斜是负载建模**:最右页 90% fillfactor 是"单调追加"负载的先验知识写进代码(nbtsplitloc.c:95-99);
4. **dedup 是空间经济学**:重复键的存储从 O(键×版本) 压到"键+TID 数组"——数据分布常识变成索引策略。

## 9.6 FAQ

**Q1:hikey 为什么在页首?**
追加写场景数据从尾部进,hikey 放头不搬动(:368-370)。

**Q2:蟹行丢了锁会读错吗?**
不会:跟错时 hikey 越界检测→move-right 恢复(:275-317)——乐观的代价是恢复路径。

**Q3:最右页为什么留 10% 空?**
单调插入(自增 ID)总进最右页:对半分会让每页半满(:95-99)。

**Q4:唯一冲突等谁?**
in-progress 的插入者:XactLockTableWait 等其提交或中止(:589-601)——期间锁全放。

**Q5:为什么等完要 goto search 重来?**
等待期间页可能分裂/删除:唯一安全假设是"一切可能变了"(:216-235)。

**Q6:dedup 会破坏唯一索引吗?**
唯一索引禁用 dedup:posting 合并会隐藏重复检查时机——dedup 只服务非唯一。

**Q7:空页删除为什么两阶段?**
父 downlink 更新需要子信息(藏进 hikey t_tid :2253-2255):先自删叶子,父层晚点回收——两段 WAL 各自原子。

**Q8:树高会降吗?**
不会:根/最右页永不删(:1906-1915);fastroot 记录实际最低层,扫描跳过空壳。

**Q9:扫描时能放锁吗?**
可以:整页 TID 已拷入私有 currPos(:153-154),pin 可放防挡 VACUUM(:57-75)。

**Q10:nbtree 的元组上限为什么 1/3 页?**
保证分裂后页仍能容 hikey+2 数据项(:165-169)——不变式优先于大元组支持(超长的用 TOAST,卷三)。

## 9.7 小结与深挖方向

本章结论:**nbtree="蟹行乐观锁+倾斜分裂+dedup/截断空间经济+MVCC 感知的等待重来"**。深挖:

1. move-right(:275-317)在高并发单点插入的往返次数;
2. dedup posting 上限 1/6 页(:89)对宽索引键的失配;
3. 后缀截断(:692)对变长文本键的实际节省;
4. half-dead(:2253-2255)在 VACUUM 中断后的自愈路径;
5. `_bt_check_unique` 等待(:589-601)在热点键(insert 同键风暴)的串行化瓶颈。

> 下一章(卷末):复制与逻辑解码——WAL 的三类消费者。
