# 第 05 章 · healing 与扫描器:静默损坏的自愈闭环

> 基线:commit `7aac2a2`。行号以 cmd/data-scanner.go、cmd/erasure-healing.go、cmd/mrf.go 为准。**勘误**:heal-object.go 文件不存在(实现在 erasure-healing.go);.bloomcycle.bin 只是历史文件名,现仅存 cycle 计数器,并无 bloom 全量索引。

## 5.0 全景:两个后台子系统

```
data scanner(单实例,leader.lock :156):
  每 cycle → NSScanner(:205)→ 每 set 一个 goroutine(:735)
  → 每盘 scanDataFolder/scanFolder(:307/:399)遍历目录树
  → 每对象 applyActions(:1036):ILM 评估(:1095)+统计+1/1024 概率触发 heal(:506)
healing:四源触发 → heal worker 池(GOMAXPROCS/2)→ healObject 比对修复
```

**速率自律**:dynamicSleeper(factor 2、上限 1s,:66/:1410-1452)——处理时长×倍率睡眠、配置热更新;压缩目录按 xxhash 分摊到 16 个 cycle(:656-661),未轮到直接搬旧统计——**扫描器主动慢下来,用户流量优先**。

## 5.1 healing:四源触发与修复流程

触发四源(admin API :716;scanner :968/:723;**读写 MRF** :403/:806/:2153;换盘 :373/:559)→heal worker 池(background-heal-ops.go:157,GOMAXPROCS/2)→healObject(erasure-healing.go:295):加锁→readAllFileInfo 读全部盘 xl.meta(:333)→listOnlineDisks/pickValidFileInfo 选 quorum 最新元数据(:368/:372)→checkObjectWithAllParts 校验(:291;深扫走 VerifyFile bitrot :414-422)→逐盘 shouldHealObjectOnDisk(:178)→健康分片 erasure.Heal 重写到 tmp(:603)→RenameData 回填(:663)。判定表(:178-205):notfound/corrupt→全重写;XLV1→升级重写;meta 过期→outdated;part 缺失/损坏→只重写数据。**不可修(parities 不足)转 deleteIfDangling**(:458);Normal 撞 corrupt 自动升级 Deep 重修(:1101-1106);dry-run 在写盘前返回(:434-436)。**MRF**:队列 100000、满即丢弃(mrf.go:39/:94-97);落盘 .heal/mrf/list.bin 重启回放(:147/:199);独立 5× sleeper(:213)。

## 5.2 scanner 的产出与读时自愈

扫描产出:.usage.json 统计(data-usage.go:58)、ILM 删除/转冷入队、heal 工单、告警事件。**读时自愈**(卷一 02 章 :400-418 的呼应):GET 重建成功同时发现缺失/损坏——照常服务客户端+静默入 MRF(BitrotScan 标记深扫);heal 判定表(erasure-healing.go:178-205):notfound/corrupt→全重写,XLV1→升级重写,meta 过期→outdated,part 缺失/损坏→只重写数据。

## 5.3 设计动机

1. **为什么后台扫描器要"慢"**:用户流量优先——dynamicSleeper 的倍率+封顶(:1410-1452)让扫描可无限让路;
2. **为什么 heal 按需+巡检双触发**:读时自愈(MRF)覆盖"正在被用"的数据,巡检覆盖"沉睡"的数据——两者合起来才是完整的自愈面;
3. **数据统计为什么靠扫描而非实时**:对象计数/大小是全量聚合,实时维护的成本>周期扫描——扫描器的统计是副产品(:1036 的三合一);
4. **Normal→Deep 自动升级**(:1101-1106):轻校验发现问题即升级深度校验——分级检查的动态加深。

## 5.4 FAQ

**Q1:扫描器会拖慢业务吗?**
dynamicSleeper 限速(:1410-1452)+idle 模式:只在空闲时全速。

**Q2:heal 抽样率 1/1024 是什么?**
(:506):对象级 heal 概率抽样——大集群的巡检覆盖率与成本的平衡。

**Q3:MRF 队列满了丢什么?**
(:94-97):丢弃后靠扫描器兜底再发现——MRF 是加速器不是正确性依赖。

**Q4:什么对象"不可修"?**
缺失分片数>parity(:438-458):转悬挂删除——EC 数学的不可能区。

**Q5:dry-run 模式做什么?**
(:434-436):完整走 heal 判定但写盘前返回——预览修复计划。

**Q6:Normal 和 Deep heal 的区别?**
Normal 校验元数据+分片存在;Deep 走 VerifyFile bitrot 全量校验(:414-422)。

**Q7:healing 时服务中断吗?**
不:健康分片照常服务,重写走 tmp+rename(:603/:663)——原子替换。

**Q8:换盘后自动 heal 吗?**
是:background-newdisks-heal-ops(:373/:559)监听新盘入池触发。

**Q9:ILM 过期是谁删的?**
扫描器 applyActions(:1036-1162):过期对象按生命周期规则删除/转 tier。

**Q10:扫描的 cycle 是什么?**
全集群扫描一轮为一 cycle;压缩目录 16 cycle 摊一次(:656-661)。

## 5.5 小结与深挖方向

本章结论:**自愈闭环="读时自愈(MRF)+巡检(scanner)+分级 heal 判定+不可修悬挂删除"**;资源自律(限速/抽样/预算)贯穿两个子系统。深挖:

1. 1/1024 抽样(:506)在大集群的巡检收敛时间;
2. MRF 落盘 list.bin(:147/:199)的回放幂等性;
3. dynamicSleeper(:1410-1452)热更新配置的生效延迟;
4. VerifyFile 深扫(:414-422)对大对象的 IO 冲击;
5. leader.lock(:156)在 scanner 崩溃后的接管延迟。

> 下一章(卷末):工程文化——巨石包与自有轮子。
