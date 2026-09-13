# 第 13 章 · TOAST:超长值的分片人生

> 基线:commit `8c7a74c`。行号以 src/backend/access/common/toast_internals.c、toast_compression.c、src/include/access/varatt.h、src/backend/catalog/toasting.c 为准。卷一 02 章 8KB 页 + 09 章"超长用 TOAST"——本章兑现。

## 13.0 全景:一个长文本的存储旅程

```
INSERT(1MB 文本)→ 元组超 2032B 阈值(heapam.c:2259-2266)
  → 压缩决策(lz4/pglz)→ 仍超 → 分片写 toast 表(每片 1996B)
  → 主表只留 18B 外部指针(varatt_external_oid)
SELECT → detoast:整值解或 slice 按需取片
```

**va_tag 四形态**(varatt.h:169-174 位布局,宏 :233-242):①普通内联(4B 头,长度=头>>2);②压缩内联(4B 头+va_tcinfo:30 位解压后大小+2 位压缩法);③短内联(1B 头,≤126B);④外部指针(2B 头+va_tag)。"压缩外部"是④子形态:16B 指针 {va_rawsize,va_extinfo,va_valueid,va_toastrelid}(varatt.h:32-39;detoast.h:31),**是否压缩靠 extsize<rawsize 的大小比较判定**(varatt.h:543-548)——不占标志位。

## 13.1 分片:1996 的推导

toast 表三列 chunk_id/chunk_seq/chunk_data,**全 PLAIN 禁压防递归**(toasting.c:239-265);(chunk_id,chunk_seq) 唯一 btree(:317-369)。CHUNK_SIZE=1996 的推导(heaptoast.h:80-89):8KB 页放 4 条 toast 元组→单元组 2032B,减 24B 元组头+三个变长头;**主表触发阈值同为 2032B**(TOAST_TUPLE_THRESHOLD,:48)——两数同源。写入 toast_save_datum 每片 Min(1996,剩余)(toast_internals.c:283-349,:301);读取 slice 直接换算起止片(:652-654)——**O(片数) 索引范围扫,不读无关片**。

## 13.2 压缩:策略与采纳门槛

四轮策略(heaptoast.c:159-271):EXTENDED 先压→再外置→MAIN 压→MAIN 外置(目标放宽到整页)。**压缩采纳门槛:净省 >2 字节**(toast_internals.c:81-97),否则标记不可压——为 2 字节付解压成本不划算。压缩法选择:本 commit **编译进 lz4 就默认 lz4**(toast_compression.h:56-62;GUC guc_parameters.dat:783-787)——pglz 的历史地位被工程判断取代。**slice 读取的压缩差异**(detoast.c:204-333):未压外部只取所需片(:232-234);pglz 用 pglz_maximum_compressed_size 估算多取(:254-256);**lz4 必须整取**(:249-252)——压缩格式的随机访问能力决定 slice 策略。解压入口 PG_DETOAST_DATUM_PACKED(fmgr.c:1797-1836):仅压缩/外部形态才解;**解包须有活动快照**(toast_internals.c:628-647)。

## 13.3 索引、VACUUM 与目录自举

**索引元组永不含 toast 指针**(indextuple.c:29,:110-135):先解外部再压缩,超限报错——09 章 nbtree 的元组上限(1/3 页)与这里闭环。VACUUM 先主表后持会话锁递归 vacuum toast 表(vacuum.c:2291-2302,:2379-2392;VACUUM FULL 例外走 cluster 重建);toast 表不 ANALYZE。**目录自举**(toasting.c:389-408+bootparse.y:382-392):BKI 脚本 `declare toast`→BootstrapToastTable 预定 OID 建表,bootstrap 期原地写 pg_class.reltoastrelid——**鸡生蛋用预定 OID 破解**。纠偏:本 commit 的 pg_class.h 已无 DECLARE_TOAST(老 OID 2786 不再声明);仍有 toast 表的是 pg_proc/pg_rewrite/pg_statistic/pg_trigger/pg_index 等 34 个目录。新旋钮 toast_value_type(toasting.c:149-180)正为 chunk_id 类型扩展铺路。

## 13.4 与前作对照与设计动机

| | PG TOAST | InnoDB 溢出页 | Git blob |
|---|---|---|---|
| 形态 | 分片+指针(旁表) | 溢出页链 | 全量独立对象 |
| 压缩 | 值级 lz4/pglz | 页级 | zlib 全量 |
| 读取 | 按需 slice | 整链 | 整取 |

1. **为什么 8KB 页需要 TOAST**:页是 I/O 与并发单位,单值失控会毁掉两者的可预期性——TOAST 把"大"隔离到旁表,主表元组永远可预期(≤约 2KB 阈值内);
2. **压缩标志在值头**:同一列可混合四种形态(varatt 四 tag)——值的形态是值的属性,不是列的属性;
3. **按需解压是默认**:slice 读前缀(如 substr)可以只解所需片——存储格式为最常见访问模式优化;
4. **四轮策略是"从无损体验逐级让步"**:先压缩(透明)→外置(慢一点)→放宽目标——每轮都有明确代价声明。

## 13.5 FAQ

**Q1:1996 这个数怎么来的?**
8KB÷4 条=2032B 减头(heaptoast.h:80-89):与主表触发阈值同源——数字是几何的推论。

**Q2:TOAST 会让 SELECT 变慢吗?**
外部值需读旁表+解压;slice 路径(substr)只取所需片(:232-234)——按需解压是默认。

**Q3:能对单列禁用压缩吗?**
能:ALTER TABLE ... SET COMPRESSION;四轮策略(:159-271)随之跳过压缩轮。

**Q4:为什么索引列不能 TOAST?**
索引元组上限 1/3 页且永不含指针(indextuple.c:110-135):索引键必须自包含。

**Q5:toast 表也是堆表吗?**
是:三列普通表+(chunk_id,chunk_seq) btree(:317-369)——复用全部基础设施,零特殊机制。

**Q6:pg_class 自己能 TOAST 吗?**
本 commit pg_class 无 DECLARE_TOAST(无超长 varlena 列);pg_proc/pg_statistic 等 34 个目录有——纠偏老认知。

**Q7:压缩怎么选?**
编译进 lz4 就默认 lz4(toast_compression.h:56-62);列级 SET COMPRESSION 可覆盖。

**Q8:TOAST 的 VACUUM 顺序?**
先主表后 toast 表(vacuum.c:2291-2302):死主行的片随行清——顺序防悬挂片。

**Q9:1GB 字段可行吗?**
可行:30 位长度上限(:169-174);实际受内存与 slice 策略限制。

**Q10:解压为什么需要快照?**
读 toast 片走普通表扫描(:628-647):MVCC 可见性判定(06 章)需要快照——TOAST 也活在 MVCC 世界。

## 13.6 小结与深挖方向

本章结论:**TOAST="四形态值头+1996 分片+四轮降级策略+目录自举"**;复用堆表基础设施(零特殊机制)是它最优雅的一笔。深挖:

1. lz4 整取限制(:249-252)对 substr 模式的前缀读退化;
2. 2032B 阈值与 8KB 页的推导在 32K 页(page_size 可配)下的变化;
3. 目录 toast 的 34 个目录清单演进(pg_class 退出的原因);
4. 四轮策略(:159-271)在"压缩后仍超页"的极端值行为;
5. toast_value_type(toasting.c:149-180)铺路的 chunk_id 64 位化。

> 下一章(卷三卷末):统计与 ANALYZE——规划器的感官。
