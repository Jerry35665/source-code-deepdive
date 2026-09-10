# 第 06 章 · 版本管理与 LSM 分层:不可变的层级视图

> 基线:LevelDB 1.23,commit `7ee830d0`。行号均以该版本源码为准。
> 两个勘误(流行资料常见错误):LevelDB 源码中**没有** `file_overreaded`(那是 RocksDB 的概念,LevelDB 对应物是 `allowed_seeks`,version_edit.h:22);也**没有** `maxcompactionbytes`(对应物是 `MaxGrandParentOverlapBytes` = 10×target_file_size 与 `ExpandedCompactionByteSizeLimit` = 25×target_file_size,version_set.cc:28-39)。

## 6.0 Version / VersionSet / Manifest 三者关系

LevelDB 把"磁盘上每个层级有哪些 SSTable"建模为**不可变快照对象 Version**:

```
CURRENT(1 行文本) ──指向──> MANIFEST-000005(log 格式追加文件)
                                   │ 逐条重放 VersionEdit 记录
                                   ▼
                 VersionSet(内存元数据枢纽)
                  ├─ Version 环形双向链表: v3(current) ← v2 ← v1
                  ├─ next_file_number_ / last_sequence_ / log_number_
                  └─ compact_pointer_[7](每层 compaction 起点游标)
```

LSM 层级形态(7 层,dbformat.h:25-45):

| 层 | 文件键区间 | 容量 | 触发 |
|---|---|---|---|
| L0 | **允许互相重叠**,按文件号新→旧读 | 文件数 ≤4(kL0_CompactionTrigger) | size:文件数;写限速:8/12 个 |
| L1..L6 | 层内互不重叠、按 smallest 排序 | L1=10MB,此后每层 ×10 | size:总字节/层容量 |
| 输出文件 | — | 2MB(max_file_size) | — |

数据流:memtable 冻结 → `WriteLevel0Table` 生成 L0 文件(范围允许时经 `PickLevelForMemTableOutput` 直落 L1/L2,version_set.cc:470-495,最多推到 kMaxMemCompactLevel=2)→ 后台逐层下推。

## 6.1 Version 不可变性与查找

Version 构造私有、拷贝被 delete(version_set.h:123-134)——任何修改都走"Builder 生成新 Version → AppendVersion"的 copy-on-write 路径。**FileMetaData 本身被多版本共享**(refs 字段),旧 Version 只需 O(1) 保留指针。

谁在持旧 Version:活跃迭代器(db_impl.cc:1100-1102)、进行中的 compaction(`input_version_->Ref()`)、Get 的临时持有。这就是"旧版本存在的意义":迭代器必须在快照语义下稳定存活。

**Get 的层级查找**(Version::Get,version_set.cc:324-400):

- **L0:线性过滤 + 按年龄排序**——L0 文件键区间可能重叠无法二分,命中的文件按文件号**降序**逐个探测(文件号越大越新,保证读到最新版本);
- **L≥1:一次二分,至多一个候选**——层内互不重叠,`FindFile` 二分返回"第一个 largest ≥ 目标"的文件;
- **结果语义**:kTypeValue → kFound 终止;kTypeDeletion → kDeleted **同样终止**——删除标记让查找短路,不必再搜更老的层。

## 6.2 allowed_seeks:把 IO 成本折算成 seek 预算

seek 触发 compaction 的定价推导(version_set.cc:650-664)是全库最漂亮的一段注释:

```
(1) 一次 seek 成本 10ms
(2) 读写 1MB 成本 10ms(100MB/s)
(3) 1MB 的 compaction 做 25MB IO ⇒ 25 次 seek ≈ 压平 1MB 数据
⇒ allowed_seeks = file_size / 16384,下限 100
```

即 **1 次 seek ≈ 压平 40KB**,保守取 16KB/seek。记账位置很讲究:Get 若要读多于一个文件,就把"第一个被读的文件"记进 stats.seek_file(version_set.cc:344-349)——"如果第一个文件里就有答案就不用花第二次 seek",所以账记在第一个文件头上。耗尽即标 `file_to_compact_`。迭代路径另有 1MB 采样的 `RecordReadSample`(415-451):同一 user key 匹配到 ≥2 个文件时同样扣账。

**为什么 seek 也要触发 compaction**:size 触发只看"量",对"少量键被疯狂点查"失明——一个 100KB 文件反复挡在热点 key 的读路径上,每次 Get 都多一次 seek。allowed_seeks 用读放大信号补写放大信号的盲区。(失效模式:定价假设机械盘;SSD 上高估 100 倍,seek 触发可能永不发生——深挖点。)

## 6.3 Manifest:VersionEdit 的追加日志

**VersionEdit 的 TLV 编码**(version_edit.cc:14-24),tag 写盘后不可变:

| Tag | 字段 | 载荷 |
|---|---|---|
| 1 | Comparator | 长度前缀字符串 |
| 2/3/4 | LogNumber / NextFileNumber / LastSequence | varint64 |
| 5 | CompactPointer | level + InternalKey |
| 6 | DeletedFile | level + 文件号 |
| 7 | NewFile | level + 文件号 + 大小 + smallest/largest 两个 InternalKey |
| 9 | PrevLogNumber | 已废弃但保留解析 |

`LogAndApply`(777-859)在提交前**强制补齐四个标量**——保证任意一条 MANIFEST 记录都携带恢复所需的全局状态。首次写时 `WriteSnapshot` 写入当前版本的全量快照(一条巨型 VersionEdit);写记录期间**解锁**(817-840);新 MANIFEST 落地后 `SetCurrentFile` 用"写 .dbtmp + rename"原子切换 CURRENT。

**Recover**(861-992):读 CURRENT → log::Reader 带校验和逐条重放 → **先比对 comparator 名**(防用不同排序读旧库)→ 三标量缺一即 Corruption(这就是 WriteSnapshot 必须写全量的原因)→ 恢复后 `manifest_file_number_ = next_file`(**下一个 MANIFEST 直接复用 next_file 号**)。`ReuseManifest` 仅在 reuse_logs 且旧 MANIFEST < 2MB 时续写;默认每次打开都换代。

**Builder**(569-731)把一串 VersionEdit 增量应用到 base 版本:每层一个按 smallest 排序的 set,SaveTo 做 base 与 added 的有序归并;`MaybeAddFile` 断言层内不重叠,SaveTo 末尾在 NDEBUG 下还做全层重叠扫描,**发现重叠直接 abort**(699-713)——这份偏执来自真实事故(曾因 level-1..n 重叠文件导致读返回错误结果),断言与 `AddBoundaryInputs` 都是它的补丁。

**AddBoundaryInputs**(1360-1383)修的 bug 值得记住:同一 user key 恰好横跨两个文件边界时,只压前者会让层内二分命中后者(更旧版本)而**提前返回旧值**——层内不重叠的假设被同键跨界打破。

## 6.4 Compaction 触发的版本侧

**Finalize**(1031-1067)预计算各层得分:

```cpp
if (level == 0) {
  /* L0 得分 = 文件数 / 4:大 write_buffer 下不希望频繁 L0 compaction;
     L0 每次读要合并所有文件,文件个数才是读放大来源 */
  score = v->files_[level].size() / (double)config::kL0_CompactionTrigger;
} else {
  score = level_bytes / MaxBytesForLevel(options_, level);
}
```

L≥1 容量 L1=10MB 后每层 ×10;**最后一层 L6 不参与评分**。取分最高层存入 compaction_score_。

**PickCompaction**(1252-1304)双触发,size 优先:size 触发从 `compact_pointer_[level]` 游标之后选第一个文件(层内轮转,防热点区间被反复压缩);seek 触发直接压 file_to_compact_。**L0 特判**:用 GetOverlappingInputs 把所有重叠 L0 文件一网打尽(L0 允许重叠,漏文件会读出旧值;其中的"扩张-重扫"循环在 L0 全域重叠时是 O(n²))。

**SetupOtherInputs**(1385-1446)三步:AddBoundaryInputs 修边界 → 取 level+1 重叠文件,并尝试"扩容"(不增加 level+1 文件数且总字节 <25×target 时扩张,摊薄固定开销)→ 收集 level+2 的 grandparents 供输出切分。

**Trivial move**(1499-1507):单文件、下层无输入、爷辈重叠 ≤10×target 时,不做归并,直接在 VersionEdit 里改指针——零 IO。

## 6.5 垃圾回收与快照

新版本落地后,被替换的 SSTable 不立即删除,`RemoveObsoleteFiles`(db_impl.cc:225-290)统一回收:live 集合 = pending_outputs_(防竞态)+ **遍历所有仍被引用的 Version** 收集文件号;删除动作解锁后批量执行。

**SnapshotList**(snapshot.h)与 Version 无关但同属一致视图机制:SnapshotImpl 只封装一个 sequence_number_;compaction 用 `smallest_snapshot`(最老快照,无快照则 LastSequence)计算删除标记的安全丢弃水位——快照挡住的只是"seq 可见性",从而间接阻止旧数据被物理删除。

## 6.6 设计动机五条

1. **L0 允许重叠**:强制不重叠则每次 flush 都要合并重写,写放大瞬间爆炸;代价转嫁给读(L0 全扫),因此 L0 用文件数而非字节触发,并用 8/12 阈值在写路径反压;
2. **层级 ×10**:数据从 Ln 压到 Ln+1 后,重叠比例约 1/10,逐层写放大收敛于 O(10);90% 数据驻留 L6,读命中 L0-L1 概率最大化;
3. **Version copy-on-write**:一致视图需要多版本并存,不可变 + 引用计数让迭代器/compaction/Get 各持一个 O(1) 指针;代价是每次提交重建全部 files_ vector(百万文件时的 memcpy 是 RocksDB 引入增量结构要解决的问题);
4. **MANIFEST 追加而非重写**:提交只追加一条记录 + Sync;冗余靠"换代"控制;
5. **文件号宁大勿小**:Recover 后 `next_file_number_ = next_file + 1`,文件号重置可能导致新文件覆盖旧 live 文件。

## 6.7 FAQ

**Q1:CURRENT 和 MANIFEST 的关系?坏一个会怎样?**
CURRENT 是一行指针;CURRENT 缺失/无换行结尾 → Corruption;指向的 MANIFEST 缺失 → Corruption。CURRENT 用 rename 切换,损坏窗口极小。

**Q2:MANIFEST 记录和 WAL 记录格式一样吗?**
一样的外层封装(log 分块 record + 校验和),载荷不同:前者 VersionEdit,后者 WriteBatch。

**Q3:版本切换瞬间,正在执行的 Get/迭代器怎么办?**
不受影响:它们 Ref 钉住旧 Version,新版本照常 AppendVersion;旧 Version 等最后一个 Unref 才析构,其文件在 live 集合中不会被误删。

**Q4:为什么 L0 score 用文件数,别的层用字节?**
读 L0 要合并全部文件,文件个数才是读放大的直接度量;字节在压缩比、小文件场景下失真。

**Q5:compact_pointer 重启后会丢吗?**
不会:随 edit 的 kCompactPointer tag 持久化,WriteSnapshot 也写。

**Q6:一个 VersionEdit 会同时含 Add 和 Remove 吗?**
会(compaction 的 edit 同时含输入删除与输出新增);Builder 先记删除集合、归并时过滤,顺序无关。

**Q7:文件号会回收复用吗?**
几乎不;ReuseFileNumber 只在"刚分配即放弃"时回退一格,恢复后宁大勿小。

## 6.8 小结与深挖方向

本章结论:**版本管理 = 不可变 Version + copy-on-write + 引用计数 + 追加式 manifest;层级策略 = L0 换读放大、深层换写放大收敛**。深挖:

1. Builder 归并复杂度:百万文件大库上每次 LogAndApply 重建全部 vector 的提交延迟曲线(对照 RocksDB VersionBuilder);
2. L0 重叠闭包的最坏情况 O(n²) 实验;
3. allowed_seeks 定价在 SSD 上的失效模式与可配化;
4. 常驻数月库的 MANIFEST 无限增长路径与 Open 耗时;
5. Finalize"单层最优"缺陷:L1 与 L3 同时超限时深层回收被推迟。

> 下一章进入 LSM 的心脏:compaction 的执行主循环、drop 判定决策树与迭代器组合体系。
