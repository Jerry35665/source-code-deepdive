# 第 04 章 · packfile 与 delta:存储层的真正主角

> 基线:commit `47ce805`。行号以 packfile.c、builtin/pack-objects.c、pack-write.c、midx.c、odb/source-packed.c 为准。

## 4.0 全景:loose→pack 的生命周期

```
写: 内容→loose(01 章) ──积累──→ gc/repack ──→ pack(快照打包+delta 压缩)
读: oid ─→ find_pack_entry(odb/source-packed.c:17)
          ├ MIDX 命中→单次二分(:27-31)
          └ 逐 pack 二分 .idx → 偏移 → unpack_entry 三阶段解包
```

为什么要 pack:**loose 对象每对象一个文件**——inode 爆炸、磁盘局部性差、无法直接网络传输。pack 把数万对象合成一个文件+一个索引,并把"相似内容"用 delta 压在一起。这对应第一系列 LevelDB 的 memtable→SST 沉降:写入用最笨的格式保快,后台整理换读效率。

## 4.1 idx/pack 二进制格式

**.idx**:fanout 表(256 项,每首字节的累计计数)——`bsearch_hash` 二分前先用 fanout[首字节] 把范围缩到 1/256,省 8 次比较(hash-lookup.c:112-113);后接排序 oid 数与偏移表。**.pack**:12 字节头,对象头是变长整数——首字节高 3 位类型+低 4 位长度,7 位续位(packfile.c:869-895)。

**delta 表示**(`get_delta_base`,:986-1025):OFS_DELTA 用**相对偏移**(每续位 +1 补偿,:1005-1011),REF_DELTA 用 20B hash;指令流仅两操作:copy(位掩码拼 offset/size)+insert(≤127 字面量)(patch-delta.c:39-83)——**delta 不是 diff 文本,是一对拷贝/插入指令**。

## 4.2 读路径:delta 链展开

`unpack_entry`(packfile.c:1504-1720)三阶段:①沿 delta 基指针下钻压栈(:1521-1591);②解最内层基对象;③逐层 `patch_delta` 回展开(:1613-1706),中间基进 LRU 缓存(:1268,默认 96MB,pack-objects.h:12)。**链深=读取代价**——没有"只解一半"的捷径,这是 `--depth` 存在的根本原因。MIDX 把 N 个 .idx 合成一份跨 pack 索引(chunk OIDF/OIDL/OOFF,midx.h:24-31),查找复用同一 `bsearch_hash`(midx.c:521):多 pack 收敛为单次二分。

## 4.3 写路径:delta 窗口决策

`builtin/pack-objects.c` 的流水线:枚举对象→`type_size_sort`(:2654,大→小、新→旧,注释 :2646-2653——**保证最深 delta 落在最老对象上**)→`find_deltas`(:2992)滑窗搜索→`write_one` base-first 写出→`write_idx_file` 生成 .idx(pack-write.c:57;fanout 生成 :113-123)。

核心是 `try_delta`(:2808)三重闸门:

1. 类型相同(:2820);
2. **深度闸**:`src->depth >= max_depth` 拒绝(:2839)——默认 depth 50(:230),硬上限 4095=OE_DEPTH_BITS=12 位字段容量(pack-objects.h:15);
3. **尺寸闸**:新 delta 至少省一半(:2845),基越深允许的 delta 越小(:2851-2852 深度配额折减),目标<源 1/32 跳过(:2859)。

`--window`(默认 10,:228)= 每对象只比对最近 10 个候选基——**窗口大→压缩率高但打包慢**;最佳基被轮转到窗口头下次最先尝试(:3107-3117)。OFS_DELTA 优于 REF_DELTA:编码更短、免一次 .idx 二分(packfile.c:1020)、换哈希算法免重写。

## 4.4 cruft pack:gc 不再直接删除

不可达对象的处置演进:**不再直接删**,而是按 mtime 打进带 `.mtimes` 扩展的 cruft pack(pack-write.c:333),超 `gc.pruneExpire`(默认 2.weeks.ago,builtin/gc.c:143)才经 `--expire-to` 出库(builtin/repack.c:654-688;逐对象 mtime 与过期时间比较在 reachable.c:183-192)——**"误删可以救回来两周"从民间经验变成机制**。这与 02 章 reflog 构成双层反悔:引用层 90 天,对象层 14 天。

## 4.5 partial clone:blob:none 懒取

`filter_blobs_none`(list-objects-filter.c:72-112):传输时 blob 只标记不发送;读 miss 时 `odb.c:625-633` 触发 `promisor_remote_get_direct`→子进程 `git fetch --filter=blob:none --stdin`(promisor-remote.c:43-49)——**对象库把"缺"变成一等状态**,monorepo 的 checkout 从 GB 级降到 MB 级。

## 4.6 设计动机

1. **delta vs 单对象 zlib**:源码文件间相似度极高,跨对象 delta 的压缩率碾压逐对象 deflate——代价是读取链展开(4.2);窗口/深度是空间-时间-解压速度的三方权衡,git 用三个常量把权衡暴露给用户;
2. **OFS 优于 REF**:偏移编码短且哈希无关——为 SHA-256 迁移铺路,一切设计都为 20 年后的迁移留门;
3. **启发式拒绝全局最优**:排序+滑窗+三闸门是 O(n·window) 贪心,不追求最优 delta 树——**钳住最坏情况比平均最优重要**(LevelDB compaction 同款哲学);
4. **cruft pack 的产品化**:把"gc 删数据"的恐惧变成可配置的宽限期——存储系统对"不可逆操作"的教科书处理。

## 4.7 FAQ

**Q1:git gc 到底什么时候删对象?**
不可达对象先进 cruft pack 记 mtime(pack-write.c:333),超 gc.pruneExpire(默认 2 周)才出库(reachable.c:183-192)。

**Q2:为什么 clone 下来的是 pack 而不是 loose?**
pack 是传输单元+存储最优形态;loose 只是写入缓冲(01 章)。

**Q3:--depth/--window 调大有什么代价?**
depth 大→读路径链展开慢(:1504-1720);window 大→打包 CPU/内存线性涨(:2992)。

**Q4:delta 链能部分解压吗?**
不能,必须从基对象逐层展开(:1613-1706)——链深即延迟,LRU 缓存(:1268)只缓解热点。

**Q5:MIDX 是必须的吗?**
多 pack 仓库强烈建议:查找从"逐 pack 二分"收敛为单次二分(odb/source-packed.c:27-31)。

**Q6:partial clone 后断网能工作吗?**
已取对象全正常;miss 才触发 promisor 取回(:625-633)——离线只影响"没看过的大文件"。

**Q7:为什么 OFS_DELTA 是默认?**
编码短+免 .idx 二分+哈希无关(:986-1025)——REF_DELTA 仅在无法知道偏移的流式场景用。

**Q8:repack 会重算全部 delta 吗?**
增量 repack 复用未变对象的 delta;--window/--depth 决定新算部分的质量。

**Q9:fanout 表为什么省 8 次比较?**
256 项首字节直查(hash-lookup.c:112-113):把 20 字节哈希的二分空间缩到同前缀子集。

**Q10:cruft pack 和 reflog 有什么区别?**
reflog 是"引用级"反悔(02 章);cruft 是"对象级"反悔——前者防误 reset,后者防误 gc。

## 4.8 小结与深挖方向

本章结论:**pack = "fanout 二分 + 变长对象头 + copy/insert delta 指令 + 三闸门贪心"**;cruft pack 与 partial clone 是近年最重要的两个存储层演进。深挖:

1. LRU 96MB(pack-objects.h:12)在不同工作集下的命中率曲线;
2. 深度配额折减公式(:2851-2852)的理论依据与实测压缩率损失;
3. MIDX bitmap(可达性位图)与 05 章协商算法的联合优化;
4. cruft pack 在 fork农场(同源万仓)的跨仓去重想象;
5. pack 头 3bit 类型(:869-895)的容量边界与 v4 pack 格式传闻。

> 下一章:传输协议——pkt-line、v2 命令化与协商算法。
