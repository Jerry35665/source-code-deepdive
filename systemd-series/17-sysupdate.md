# 第 17 章 · sysupdate:声明式 transfer、GPT 状态机与 varlink 通知钩子

> 基线:commit `1f66b524`。核心:src/sysupdate/(33 个文件共 13,206 行;sysupdate.c 3,571 行 / sysupdated.c / sysupdate-partition.c / sysupdate-pattern.c)。

## 17.0 全景:一次 update 的数据流

```
 sysupdate.d/*.transfer([Transfer]/[Source]/[Target] 三节)
   ▼ update(默认=ACQUIRE+INSTALL;--offline 只装)
 acquire:委托 systemd-pull/import 子进程下载(URL 源强制 SHA256,transfer.c:1405-1415)
   ▼ partial → pending → final 的状态机:
   分区侧:label "_empty" 的 slot 被选中写入;中间态 = 对原 type UUID 做 HMAC 派生的两个新
          GPT type UUID(不再污染 label);文件侧 = .sysupdate.partial./.pending. 前缀 rename 阶梯
   ▼ OnCompletedUpdate:向 /run/systemd/sysupdate/notify/ 广播 varlink 通知
 bootctl 收到后从 /var/lib/systemd/uki 等 staging 目录发现 UKI 并接链(bootctl-link.c:1053-1064)
```

纠偏:动词集已重构——**没有 fetch/verify**:下载是独立动词 `acquire`,update 默认=下载+安装,verify 仅剩 `--verify=` 签名开关(sysupdate.c:1945-3187, 2792, 3432-3442);Resource 是 **7 种**而非常说的 3 种(url-file/url-tar/tar/partition/regular-file/directory/subvolume,sysupdate-resource.h:7-17)。

## 17.1 pattern:单字符字段标记语言

instance 命名不是 glob,而是字段标记:`@v` 版本(必须恰好出现一次)、`@u` PARTUUID、`@f` flags、`@t` mtime、`@s` size、`@d/@l` 尝试计数、`@h` SHA256 等(sysupdate-pattern.c:50-79);字段间必须有字面文本或 `/` 分隔,保留字符 `$ * ? [ ] ! \ |` 禁用;正向 pattern_match 逐字段抽取、反向 pattern_format 生成最终实例名(:106-208, 211-681)。`**/` 前缀让源匹配递归下钻目录。URL 型实例发现=下载 SHA256SUMS 清单解析,拒绝 `..`/`%`/控制字符文件名;`BEST-BEFORE-*` 魔法文件是清单过期戳,过期默认 ESTALE 拒更(resource.c:511-659, 449-509)。

## 17.2 A/B 语义:GPT label 就是状态

纠偏:A/B slot 发现靠 **GPT label 字面 `_empty`**——find_suitable_partition 选类型匹配、label 恰为 `_empty`、容量够的最小分区(sysupdate-partition.c:148-213);回收只是把 label 改回 `_empty`,**从不删分区表项**(transfer.c:830-851);partial/pending 以固定 app-id 对原 type UUID 做 HMAC 派生成两个新 GPT type UUID(sysupdate-partition.c:12-24)。全流程**无 rollback 命令、也无任何分区 resize**(growfs 只是 GPT attribute 位)。

## 17.3 UpdateSet 与 Component/Feature

UpdateSet 是跨 transfer 的同版本组合,8 个标志位(NEWEST/AVAILABLE/INSTALLED/OBSOLETE/...);缺件语义不对称:AVAILABLE 缺任一 transfer 整套跳过(不替服务器发残缺更新),INSTALLED 缺件标 INCOMPLETE 继续算——注释引 issue #33339,防误删正在运行的系统(sysupdate.c:594-614)。Component/Feature 是两层门控:`RequisiteFeatures=` 任一缺失即禁用,`Features=` 任一启用即启用;enable-feature 落 /etc/sysupdate.d 的 Enabled= drop-in(sysupdate-transfer.c:518-540)。vacuum 保底:**永远至少留 1 个实例**,space==instances_max 直接 ENOSPC;分区目标还要求 n_empty+n_instances≥2(sysupdate-transfer.c:914-967)。

## 17.4 与 bootctl 的衔接:varlink 通知而非直接写

纠偏:sysupdate **不写 boot entry、不调 ukify/kernel-install**——安装完成后向 /run/systemd/sysupdate/notify/ 广播 `io.systemd.SysUpdate.Notify.OnCompletedUpdate`(sysupdate.c:1750-1808),bootctl 收到后按 LinkAuto 语义从 /var/lib/systemd/uki 等 staging 目录发现 UKI 并接链,pcrlock/sysext 同样订阅(bootctl-link.c:1053-1064, 1697-1730)。installdb(/var/lib/systemd/sysupdate/installdb)以"目录+pattern"符号链接记录历史安装位置,cleanup 删除不再被认领的文件(sysupdate-cleanup.c:25-71)。

## 17.5 设计动机

1. **声明式 transfer**:Source→Target 一条规则一个文件,分区/文件/目录统一抽象(sysupdate-transfer.c:546-575);
2. **GPT label 即状态**:_empty/_满/派生 type UUID,分区表本身就是元数据库,无旁路文件(sysupdate-partition.c:148-213);
3. **缺件不对称**:下载侧宁缺毋滥、安装侧容忍不完整,两种失败两种策略(sysupdate.c:594-614);
4. **varlink 通知解耦**:启动项管理归 bootctl,sysupdate 只广播事件(sysupdate.c:1750-1808);
5. **vacuum 保底**:至少留一个可启动实例,清空即 ENOSPC(sysupdate-transfer.c:925-929);
6. **installdb 链接记账**:历史安装可被 cleanup 回收,新 transfer 换 pattern 也不丢(sysupdate-cleanup.c:25-54)。

## 17.6 FAQ

**Q1:有 fetch/verify 命令吗?**
没有:acquire 下载、update=下载+安装、--verify= 只是签名开关(sysupdate.c:2792, 3432)。

**Q2:Resource 有几种?**
7 种:仅 4 种可作 Target,url-* 只能作 Source(sysupdate-resource.h:7-35)。

**Q3:怎么找空的 A/B slot?**
GPT label 恰为 `_empty`、类型匹配、容量够的最小分区(sysupdate-partition.c:148-213)。

**Q4:中间状态怎么表达?**
分区侧派生 type UUID,文件侧 .sysupdate.partial./.pending. 前缀(:12-24)。

**Q5:会自动写启动项吗?**
不会,只广播 varlink 通知,bootctl 自行接链(sysupdate.c:1750-1808)。

**Q6:有回滚命令吗?**
没有;A/B 靠多 slot 共存,旧 slot 本身就是回滚点。

**Q7:会缩放分区吗?**
不会 resize;growfs 只是 GPT attribute 位。

**Q8:清单过期怎么办?**
BEST-BEFORE-* 过期默认 ESTALE 拒更,环境变量可降级为警告(resource.c:449-509)。

**Q9:最坏情况会删光实例吗?**
不会,vacuum 永远至少留 1 个(sysupdate-transfer.c:925-929)。

**Q10:@v 能出现两次吗?**
不能,pattern 校验直接拒载(pattern.c:202-203)。

## 17.7 小结与深挖方向

本章结论:**sysupdate=声明式 transfer+GPT label 状态机+varlink 通知钩子;自己不写启动项、不做 resize、不删分区**。深挖:

1. HMAC 派生 type UUID 的 app-id 选择与碰撞面(sysupdate-partition.c:12-24);
2. context_process_partial_and_pending 的断点续装(sysupdate.c:1585-1588);
3. updatectl/sysupdated D-Bus 面与 CLI 的等价性(sysupdated.c 2,204 行);
4. Feature 门控在组件化发行版(镜像+附加组件)中的组合(sysupdate.c:2740-2774);
5. web_cache 的清单去重与多 URL 源一致性(sysupdate-cache.c:79-80)。
