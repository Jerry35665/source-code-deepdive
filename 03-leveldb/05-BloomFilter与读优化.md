# 第 05 章 · Bloom Filter:一次磁盘读都不发生的判定

> 基线:LevelDB 1.23,commit `7ee830d0`。行号均以该版本源码为准。
> 收益定位(filter_policy.h:8-11 原话):"a filter can cut down the number of disk seeks from a handful to a single disk seek per DB::Get() call"。第 04 章已见到它在点查骨架里的位置:`KeyMayMatch` 为假时直接 Not Found,**一次磁盘读都不发生**(table.cc:224-226)。

## 5.0 FilterPolicy 接口:策略模式的教科书样本

filter_policy.h:27-52 只有三个纯虚函数:`Name()`、`CreateFilter(keys, n, dst)`(追加语义,禁止改写 *dst 已有内容)、`KeyMayMatch(key, filter)`。

`Name()` 的注释要求"编码不兼容地变化时必须改名"(31-35)——这是 **metaindex 按 `filter.<Name>` 寻址**的格式级演进机制;bloom 内置策略现名 `"leveldb.BuiltinBloomFilter2"`(bloom.cc:26),后缀 2 就是历史上编码变更的痕迹。

## 5.1 布隆参数:k 随 filter 持久化

```cpp
/* We intentionally round down to reduce probing cost a little bit */
k_ = static_cast<size_t>(bits_per_key * 0.69);  /* 0.69 =~ ln(2) */
if (k_ < 1) k_ = 1;
if (k_ > 30) k_ = 30;
```
(util/bloom.cc:19-24)

`CreateFilter`(28-54)的参数链条:总位数 `bits = n * bits_per_key`,**最小 64 位**(防小 n 时误判率爆炸);数组尾部 `push_back(k_)` 把探测次数**随 filter 一起持久化**(41)——读端 `KeyMayMatch` 用**存进 filter 的 k** 而非本进程配置的 k(63-65),同一 SSTable 被不同参数版本的策略读取仍正确。`k > 30` 时直接返回 true——**给未来"短 filter 新编码"留的逃生门,宁可多读磁盘也不误判不存在**。

**误判率推导**:标准布隆模型下,某位未被置 1 的概率 `(1-k/m)^n ≈ e^{-kn/m}`,误判率:

```
p = (1 - e^{-kn/m})^k
代入 m/n = b(bits_per_key), k = b·ln2(理论最优):
p_opt = (0.6185)^b ≈ e^{-0.4805·b}
```

b=10、k 理论值 6.93,向下取整为 6,实测 `p = (1-e^{-0.6})^6 ≈ 0.84%`——文档宣称的 "~1% false positive rate"。向下取整以"略增误判"换"每次查询少一次探测",注释直言是故意的(bloom.cc:20)。b=16 时 p≈0.04%;b=32 时 p≈2e-4。

## 5.2 Double Hashing:两个哈希替代 k 个

```cpp
uint32_t h = BloomHash(keys[i]);
const uint32_t delta = (h >> 17) | (h << 15);   /* Rotate right 17 bits */
for (size_t j = 0; j < k_; j++) {
  const uint32_t bitpos = h % bits;
  array[bitpos / 8] |= (1 << (bitpos % 8));
  h += delta;
}
```
(util/bloom.cc:46-53)

只算一次哈希,探测序列用 `h + j·delta` 等差生成,delta 是 h 循环右移 17 位——引用 Kirsch-Mitzenmacher 2006 的结论:**双哈希模拟 k 哈希的渐近误判率不变**。哈希本体是类 murmur 的 32 位函数(hash.cc)。工程注意:`h % bits` 在 bits 非 2 的幂时有轻微模偏置——理论 purity 换单次除法的取舍。

## 5.3 Filter Block:按文件偏移分桶

粒度 `kFilterBaseLg = 11` → **每 2KB 文件偏移一个 filter**,而非每个 data block 一个——多个小块共享一个布隆,offset 数组才不会膨胀(filter_block.cc:15-16)。按**物理偏移**分桶让 `KeyMayMatch(block_offset)` 只需一次移位寻址,不依赖逻辑块号;大块跨桶时 StartBlock 的 while 循环自动补空 filter(21-27)。

内存结构是"两次摊平"的追加式设计:AddKey 阶段只把 key 追加进共享扁平字符串 `keys_` 并记录偏移,**每 key 零对象分配**;GenerateFilter 时才构造 Slice 数组喂给 CreateFilter(29-70)——与 memtable/arena 的思路同源:**构建期热路径消灭小对象分配**。

布局(filter_block.cc:35-49,与 doc/table_format.md 逐字对应):N 个 filter 数据、N 个 fixed32 偏移、fixed32"偏移数组起始"、末尾 1 字节 `lg(base)`。读取端 FilterBlockReader 由此独立解析。

## 5.4 "错误即放行"的降级哲学

FilterBlockReader 的防御规则(filter_block.cc:90-104,末行注释 "Errors are treated as potential matches"):索引越界或布局异常返回 true"当作可能命中"——**宁可退化为多读磁盘也不返回错误**;唯独 `start == limit` 的空 filter 明确匹配失败。配套的静默链:filter block 整体不压缩、metaindex 解码失败被静默忽略("meta info is not needed for operation",table.cc:94-97)。

这是一套**可静默降级组件**的完整设计:filter 的全部作用是省 IO,所以它自身的任何故障都不该升级为读失败——降级路径就是"没有 filter 的普通读"。代价是一个真实缝隙:构建中途换 filter_policy(`ChangeOptions` 只挡 comparator 不挡 filter_policy)会导致已生成 filter 数据与 metaindex 键不匹配,再叠加读端静默降级,**最终表现为无 filter 而非报错**——格式无版本号、靠宽松解析演进的策略代价的典型样本。

## 5.5 测试:统计式验收

`bloom_test.cc:109-150` 对 1 到 10000 递增的 key 数量建 filter,断言三条:filter 大小 ≤ `length*10/8+40`、真 key 全命中(零假阴性)、**1 万次探测的误判率 ≤ 2%**;更进一步统计"超过 1.25% 的 mediocre filter 数量不得超过 good 的 1/5"——**对概率结构做统计验收而非单点断言**。

## 5.6 FAQ

**Q1:为什么误判无害、假阴性致命?**
布隆说"可能存在"时可能误判(多读一次磁盘,代价小);说"不存在"时必须绝对正确(否则丢数据)。所以 k>30、布局异常等都返回 true。

**Q2:k 为什么存进 filter?**
允许同一 SSTable 被不同参数/版本的策略正确读取;k 只占 1 字节。

**Q3:为什么向下取整 k?**
每次查询少一次探测(省一次哈希 + 一次访存),代价是误判率从 0.62% 升到 0.84%——注释明说是故意的。

**Q4:filter 为什么按 2KB 物理偏移分桶?**
桶太细 → 偏移数组开销大;太粗 → 一次误判要读整个大区间;按物理偏移寻址只需一次移位且不依赖逻辑块号。

**Q5:verify_checksums 默认 false 不危险吗?**
读路径默认信任 page cache 换取点查零 CRC 开销;真正防线在写入端(每 block 必算)与 paranoid_checks(打开时 index/metaindex 强制校验)。

**Q6:filter block 为什么不压缩?**
它要常驻内存(Table::Open 时经 metaindex 读入),压缩省不了多少还增加解码开销。

## 5.7 小结与深挖方向

本章结论:**bloom = "参数随数据持久化 + 双哈希 + 错误即放行"三个决定;它是 LSM 把点查从"k 次 seek"压到"1 次 seek"的全部秘密**。深挖:

1. 双哈希在 bits_per_key=2(k=1)与 b=32(k=22)两端的实测误差(Kirsch-Mitzenmacher 只保证渐近);
2. filter 桶与 data block 跨桶边界的 5 字节 trailer 偏移验证;
3. ChangeOptions 换 policy 缝隙的复现与修复建议(挡住 filter_policy 或 metaindex 双键);
4. "错误即放行"策略在 filter 数据大面积损坏时的 IO 放大量化。

> 下一章(卷末前):工程文化与接口设计——Slice、Status、Options 与"接口先行"的哲学。
