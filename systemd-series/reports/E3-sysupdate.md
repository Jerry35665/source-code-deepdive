# 报告 E3 · sysupdate 系统更新(systemd 卷三)

> 基线:1f66b524("nspawn: align config `PrivateUsersOwnership` default with CLI")。
> 一句话总结:systemd-sysupdate 是"声明式 transfer 定义 + GPT/文件系统双后端"的 A/B 式资源复制器——它自己不写 boot entry、不做分区 resize、把下载/解包委托给 systemd-pull/import,
> 把安装状态刻进 GPT 分区表与文件名前缀,把 boot entry 与 PCR 状态收尾交给 bootctl/pcrlock/sysext 的 varlink 通知钩子。
> 源码范围:src/sysupdate/(33 个文件,共 13206 行),入口 sysupdate.c(3571 行)、sysupdated.c(2204 行,org.freedesktop.sysupdate1 守护进程)、updatectl.c(1749 行,D-Bus 客户端)。

## 1. 核心概念与 instance 模式:Transfer / Resource / UpdateSet / Component / Feature

配置单元是 transfer 定义文件(`sysupdate.d/*.transfer`,兼容旧 `.conf` 后缀并告警),由 `[Transfer]`/`[Source]`/`[Target]` 三节组成(sysupdate-transfer.c:546-575;sysupdate.c:445-453)。

Resource 类型共 **7 种**,而非流传已久的 3 种(sysupdate-resource.h:7-17):
`url-file`、`url-tar`、`tar`、`partition`、`regular-file`、`directory`、`subvolume`。
其中仅 `partition`/`regular-file`/`directory`/`subvolume` 四种可作 Target(resource.h:29-35);`url-*` 只能作 Source(resource.h:19-27);tar 也可以是本地文件(sysupdate-resource.c:689-692)。

```c
/* src/sysupdate/sysupdate-transfer.h:10-24(节选) */
typedef struct Transfer {
        char *id;
        char *min_version;
        char **protected_versions;
        char *current_symlink;
        bool verify;
        char **features;
        char **requisite_features;
        bool enabled;
        Resource source, target;
        uint64_t instances_max;
```

Transfer 即"一条 Source→Target 复制规则";Source/Target 类型不匹配直接拒载(sysupdate-transfer.c:649-655)。
Target 类型缺省时可自动推导:源为 file 且 Target `Path=` 以 `/dev/` 开头 → partition,否则 regular-file(sysupdate-transfer.c:615-638)。
分区目标未配 `MatchPartitionType=` 时默认 `SD_GPT_LINUX_GENERIC`(sysupdate-transfer.c:644-647)。

Instance 是某个 Resource 下"一个具体版本的具体载体"(文件路径或分区设备),携带从 pattern 抽出的 `InstanceMetadata`
(版本、PARTUUID、flags、mtime、mode、size、tries、sha256 等,sysupdate-instance.h:9-26),并有 `is_partial`/`is_pending` 两个状态位(sysupdate-instance.h:51-52)。

UpdateSet 是"跨 transfer 的同版本组合":对每个光标版本,把所有 transfer 中匹配该版本的 instance 各取一个装进 `us->instances[]`(sysupdate.c:525-727)。
标志位共 8 个,定义于 sysupdate-update-set-flags.h:6-15:`UPDATE_NEWEST/AVAILABLE/INSTALLED/OBSOLETE/PROTECTED/INCOMPLETE/PARTIAL/PENDING`。
缺件语义不对称:AVAILABLE(下载源)缺任一 transfer 即整套跳过(不替服务器发残缺更新,sysupdate.c:594-603);
INSTALLED 缺件则标 `UPDATE_INCOMPLETE` 继续算,注释明确引 issue #33339,防止误删正在运行的系统(sysupdate.c:604-614)。

Component(`sysupdate.<name>.component` 描述 + `sysupdate.<name>.d/` 定义目录)与 Feature(`*.feature`)是新版的两层门控(sysupdate.c:349-395、403-429)。
`transfer_decide_if_enabled()`:`RequisiteFeatures=` 任一缺失/禁用 → 禁用;`Features=` 任一启用 → 启用;都没配 → 隐式启用(sysupdate-transfer.c:518-540)。
`enable-feature` 通过往 `/etc/sysupdate.d` 写 `Enabled=` drop-in 实现(sysupdate.c:2197-2224)。

instance 的命名与识别由 pattern 语法承担。它不是 glob,而是一套单字符字段标记语言(sysupdate-pattern.c:50-79):
`@v` 版本、`@u` PARTUUID、`@f` 分区 flags、`@t` mtime、`@m` mode、`@s` size、
`@d`/`@l` boot 尝试计数(done/left)、`@a`/`@r`/`@g` no-auto/read-only/growfs、`@h` SHA256 hex。
硬性语法规则(sysupdate-pattern.c:106-208):

```c
/* src/sysupdate/sysupdate-pattern.c:202-203 */
if (!(mask_found & (UINT64_C(1) << PATTERN_VERSION)))
        return log_debug_errno(SYNTHETIC_ERRNO(EINVAL),
                               "Version field marker '@v' not specified in pattern, refusing.");
```

- `@v` 必须恰好出现一次(pattern.c:202-203);同一字段重复出现报错(pattern.c:124-126);
- 两个字段标记之间必须有字面文本或 `/` 作分隔,否则拒载(pattern.c:128-131);
- 保留字符 `$ * ? [ ] ! \ |` 与控制字符禁止用于字面部分(pattern.c:81-90);
- 版本抽取后必须过 `version_is_valid(..., VERSION_ALLOW_UNDERSCORE|VERSION_ALLOW_PLUS)`(pattern.c:271);
- Target 未配 `MatchPattern=` 时继承 Source 的 pattern 并剥掉 `**/` 前缀、去重(sysupdate-transfer.c:702-721)。

正向匹配 `pattern_match` 把文件名/GPT label 按字面切段、逐字段抽取填 `InstanceMetadata`(pattern.c:211-454);
反向 `pattern_format` 用第一个 Target pattern + 元数据算出最终实例名(pattern.c:521-681;调用点 sysupdate-transfer.c:1265)。
`**/` 目录前缀:源匹配只对 basename 进行、可递归下钻(pattern.c:497-507;resource.c:175-192);
`Type=directory/subvolume` 的源禁用该前缀(sysupdate-transfer.c:688-691)。

实例发现按类型分派(sysupdate-resource.c:682-710):
- 目录型递归扫描,识别并剥离 `.sysupdate.partial.`/`.sysupdate.pending.` 文件名前缀(resource.c:152-171);
- 块设备型走 GPT 扫描(§4);
- URL 型下载 `SHA256SUMS` 清单解析(resource.c:379-383、511-659):逐行 64 位 hex + 文件名,
  拒绝绝对路径、含 `..`、含 `%`、含控制字符的文件名(resource.c:593-600);
  `BEST-BEFORE-*` 魔法文件是清单过期戳,过期默认 ESTALE 拒更,`$SYSTEMD_SYSUPDATE_VERIFY_FRESHNESS=0` 降级为警告(resource.c:449-509);
  同一 URL 的清单在一次运行内经 `web_cache` 去重(sysupdate-cache.c:79-80;resource.c:526-540、650-656)。
- 同版本多实例合法(分区表不强制唯一),排序以路径为次键并打提示日志(resource.c:661-680、721-739)。

## 2. 命令实现:动词全集与关键路径

动词全集(sysupdate.c:1945-3187):`list`、`features`、`enable-feature`/`disable-feature`、`check-new`、
`update`、`acquire`、`vacuum`、`cleanup`、`pending`/`reboot`、`components`、`enable-component`/`disable-component`。
**没有 `fetch`,也没有 `verify` 动词**——`--verify=` 只剩签名校验开关(sysupdate.c:3432-3442),`[Transfer] Verify=` 是布尔(sysupdate-transfer.c:549)。

- `list [VERSION]`(sysupdate.c:1945-2020):在线加载已装+可用;无参打表(评估列文案 "current"/"candidate"/
  "current+pending"/"current+partial"/"installed+incomplete" 等由标志位映射,sysupdate-update-set-flags.c:50-160);
  带参展示逐 transfer 明细(sysupdate.c:801-830);JSON 输出 `{current, all, appstreamUrls}`(sysupdate.c:2008-2010)。
- `check-new`(sysupdate.c:2513-2564):打印候选版本;**无候选时 EXIT_FAILURE 退出**,便于脚本轮询(2539-2541)。
- `acquire [VERSION]`(sysupdate.c:2792-2796):只下载。走 `context_acquire`(1558-1668):
  选 candidate 或显式版本 → `transfer_compute_temporary_paths`(先算路径再腾位,防 label 超长白删,1611-1622)→
  `context_vacuum(space=1)` → 逐 transfer `transfer_acquire_instance`(1659)。
  已是 pending 则转 `context_process_partial_and_pending` 只补安装阶段(1585-1588);已装则跳过(1589-1593)。
- `update [VERSION]`(sysupdate.c:2781-2790):默认 ACQUIRE+INSTALL;`--offline` 时只剩 INSTALL(2783-2789)。
  `context_update`(2621-2696)串联 acquire/install;install 阶段跳过"已在目标且非 pending"的 instance(1843-1845);
  `--reboot` 仅当新版比 os-release `IMAGE_VERSION` 更新、或同版本 incomplete 被修复时才真重启(2679-2692)。
- `vacuum`(sysupdate.c:2798-2827)与 `cleanup`(2829-2889):见下。保底逻辑:

```c
/* src/sysupdate/sysupdate-transfer.c:925-929 */
else if (space == instances_max)
        return log_error_errno(SYNTHETIC_ERRNO(ENOSPC),
                               "Asked to delete all possible instances, can't allow that. "
                               "One instance must always remain.");
```
- `pending`/`reboot`(sysupdate.c:2891-2961):比较"最新已装 vs os-release `IMAGE_VERSION=`"(2933-2955);
  `pending` 无新版时也退 EXIT_FAILURE(2957-2958)。
- `features`/`components` 及 enable/disable 对应物:枚举与开关,`--component-all` 更新时先更新默认组件再逐个
  component 循环(sysupdate.c:2740-2774);component 被禁用报 EHOSTDOWN 并跳过(2768)。

vacuum/cleanup 的落点:
- `transfer_vacuum`(sysupdate-transfer.c:861-1014):先清全部 partial(除非保护中,pending 受 ProtectVersion 保护,884-893);
  再按 `instances_max - space` 定保留数,且**永远至少留 1 个实例**,`space==instances_max` 直接 ENOSPC(914-929);
  分区目标还要求 `n_empty + n_instances ≥ 2`,不允许清空全部 slot(931-967);
  `RemoveTemporary=yes` 时顺带清 `.#` 与 `.sysupdate.partial.` 遗留物(759-807)。
- installdb(`/var/lib/systemd/sysupdate/installdb[.<component>]`)以"目录+pattern"符号链接记录历史安装位置;
  `cleanup` 删除不再被现行 transfer 认领的文件及对应记录(sysupdate-cleanup.c:25-54、65-71)。

## 3. 分区型更新:找 slot、partial→pending→final 的 GPT 状态机

slot 发现 `find_suitable_partition()`(sysupdate-partition.c:148-213):
遍历 GPT 分区,要求类型匹配(190-191)+ **GPT label 恰为字面 `_empty`**(193)+ 容量足够(196)+
同样条件下取最小者(199-204);找不到即 ENOSPC(206-207)。
**A/B 语义由此而来:slot 的"空闲"与"占用"完全由分区表本身表达,没有 sidecar 状态文件。**

vacuum 回收 slot 同样只是把 label 改回 `_empty`、必要时还原被改掉的 type UUID,**从不删除分区表项**(sysupdate-transfer.c:830-851)。

acquire/install 全程共三次 GPT 改写(sysupdate-transfer.c):
1. 选中 slot 后立刻把 label 设为最终名、type 改为派生的 partial UUID(1381-1398);
2. 数据直写分区设备(§5);
3. 写完 type 改为 pending UUID,并按配置写 PARTUUID/flags/no-auto/ro/growfs(1618-1657);
4. install 时 type 恢复真实类型、label 定格(1743-1760),随后 `CurrentSymlink=` symlink 原子翻转(1769-1833)。

`patch_partition()` 用 dlopen 的 libfdisk 改 label/uuid/type/flags 并写回,flock 块设备挡 udev 并发读(sysupdate-partition.c:237-347)。
partial/pending UUID 不用 label 前缀,而是固定 app-id 对原 type UUID 做 HMAC 派生,注释明说"省下宝贵的 label 空间"(sysupdate-partition.c:12-24):

```c
/* src/sysupdate/sysupdate-partition.c:15-24(节选) */
#define GPT_SYSUPDATE_PARTIAL_APP_ID SD_ID128_MAKE(ac,cf,a0,c2,da,24,46,0a,9f,c9,0b,b8,fc,78,52,19)
#define GPT_SYSUPDATE_PENDING_APP_ID SD_ID128_MAKE(80,f3,d6,1e,23,83,43,b9,81,f5,ce,37,93,f4,7d,4c)

int gpt_partition_type_uuid_for_sysupdate_partial(sd_id128_t type, sd_id128_t *ret) {
        return sd_id128_get_app_specific(type, GPT_SYSUPDATE_PARTIAL_APP_ID, ret);
}
```

扫描端据此把中间态分区识别为 partial/pending instance(resource.c:297-318)。
文件系统型 Target 对应的原子阶梯是 rename:
写入 `.sysupdate.partial.<版本>` → mtime/mode 修补 + fsync/syncfs → rename 成 `.sysupdate.pending.<版本>` →
install 时 rename 到 final_path(sysupdate-transfer.c:1289-1301、1565-1615、1720-1738)。
**"扩容"在 sysupdate 内不存在**:`patch_partition` 无改 size 的分支,`PartitionGrowFileSystem=` 只写 GPT growfs
attribute 位(sysupdate-partition.c:293-295、307),fs 增长交给 growfs/repart;`--image=` 模式挂镜像时倒是带
`DISSECT_IMAGE_GROWFS`(sysupdate.c:1145-1159)。

## 4. 下载与解包:全部委托 systemd-pull / systemd-import

`transfer_acquire_instance()` 按 Source×Target 组合 fork 子进程(sysupdate-transfer.c:1417-1561):
- 本地文件 → 文件/分区:`systemd-import raw --direct`(1419-1456);
- 本地 tar → 目录/subvol:`systemd-import tar --direct`(1482-1497);
- 本地目录/subvol → 目录/subvol:`systemd-import-fs run --direct`(1464-1480);
- URL 文件/tar → 各目标:`systemd-pull raw|tar --direct --verify <sha256hex>`(1499-1556),分区目标附 `--offset/--size-max`(1519-1534)。

- URL 源强制要求已知 SHA256,否则拒绝(sysupdate-transfer.c:1405-1415);典型 callout 形态:

```c
/* src/sysupdate/sysupdate-transfer.c:1507-1516(节选) */
r = run_callout("(sd-pull-raw)",
               STRV_MAKE(
                       SYSTEMD_PULL_PATH,
                       "raw",
                       "--direct",          /* just download the specified URL, ... */
                       "--verify", digest,  /* validate by explicit SHA256 sum */
                       t->context->sync ? "--sync=yes" : "--sync=no",
                       i->path,
                       t->temporary_partial_path),
                t, i, cb, userdata);
```
- regular file→regular file 也走 import 的理由写在注释里:隐式解压、沙箱、稀疏文件(1425-1428);
- 子进程经 `run_callout()` 在独立 event loop 里跑,接 NOTIFY_SOCKET 上报进度,SIGINT/SIGTERM 转杀子进程(1177-1244、1099-1175);
- `Path=` 可为 `auto`(以 `/run/systemd/volatile-root` 或 `/usr` 的块设备为盘,resource.c:828-867);
  `PathRelativeTo=` 支持 `root/esp/xbootldr/boot`(`boot` 即 BLS 的 `$BOOT`,resource.h:65;解析 resource.c:923-935)
  与 `explicit`+`--transfer-source=`(sysupdate-transfer.c:661-663)。

**ASCII 数据流:一次 `systemd-sysupdate update`(分区型 A/B)**

```
 systemd-sysupdate update
   │
   ├─① 读 /usr/lib|etc/sysupdate.d/*.transfer (+feature/component)      sysupdate.c:403-470
   ├─② Target 扫 GPT:instance=非_empty 分区,_empty 计入 n_empty         resource.c:261-361
   ├─③ Source 拉 <URL>/SHA256SUMS (systemd-pull, 查 BEST-BEFORE)        resource.c:363-509
   ├─④ 聚合 UpdateSet:候选 = 最新"可用且未装且不过时"                   sysupdate.c:525-727
   ├─⑤ vacuum:清 partial、删最老(ProtectVersion 豁免),
   │    保证每 transfer 留 ≥1 实例、GPT slot 空闲 ≥1                     transfer.c:861-1014
   ├─⑥ find_suitable_partition:label=="_empty" 的最小适配 slot          partition.c:148-213
   ├─⑦ patch_partition:label=最终名, type=partial UUID   ── GPT 写①    transfer.c:1381-1398
   ├─⑧ systemd-pull raw --verify SHA256 --offset --size-max
   │      HTTP ══直接写入══▶ /dev/nvme…pN                                transfer.c:1523-1534
   ├─⑨ patch_partition:type=pending UUID (+PARTUUID/flags) ─ GPT 写②    transfer.c:1618-1657
   ├─⑩ transfer_install_instance:type=真实 UUID, label 定格 ─ GPT 写③   transfer.c:1743-1760
   ├─⑪ CurrentSymlink= → symlink_atomic 指向新 slot                      transfer.c:1769-1833
   └─⑫ varlink 广播 OnCompletedUpdate → bootctl(link-auto)/
        systemd-pcrlock/systemd-sysext 各自订阅收尾                      sysupdate.c:1750-1808
```

## 5. 纠偏:以本 commit 源码为准

1. **没有 `fetch`/`verify` 子命令**。老文档口口相传的 `list/verify/fetch/vacuum` 已重构为
   `list/check-new/acquire/update/vacuum/cleanup/pending/reboot/...`(sysupdate.c:1945-3187);
   下载("fetch")拆成独立动词 `acquire`,支持"先下载、择机安装"两段式(2781-2796);
   `verify` 仅存于 `--verify=` 开关与 `[Transfer] Verify=`(3432-3442;sysupdate-transfer.c:549)。
2. **Resource 不是三种而是七种**,tar/regular-file/directory/subvolume 皆可作本地源,目标类型还会按
   Source 类型与 `Path=` 是否 `/dev/` 前缀自动推导(sysupdate-resource.h:7-17;sysupdate-transfer.c:615-638)。
3. **sysupdate 不写任何 boot loader spec entry,也不调 ukify/kernel-install**
   (src/sysupdate/ 全目录 grep 无命中;唯一 "BLS" 字样是 resource.h:65 注释)。
   UKI 衔接方式:sysupdate 把资源装进 `$BOOT` 或 `/var/lib/systemd/uki`,完成后 varlink 通知 bootctl 的
   `OnCompletedUpdate`,bootctl 按 LinkAuto 语义发现 staging UKI 并接链(bootctl-link.c:1053-1064、1685-1730)。
   systemd-pcrlock 与 systemd-sysext 订阅同一通知(src/pcrlock/pcrlock.c:5739-5803;src/sysext/sysext.c:3011-3030)。

```c
/* src/bootctl/bootctl-link.c:1697-1702(节选) */
/* Triggered by systemd-sysupdate after an update completed. We deliberately ignore all parameters
 * (we don't even dispatch them) and behave like LinkAuto() with default parameters: discover the
 * staged UKI and extra resources and link them in. */
```
4. **A/B slot 发现不靠"下一个未用 PARTUUID"轮转,而靠 label 字面 `_empty`**(sysupdate-partition.c:193);
   回收也只改回 `_empty`,分区表项永不删除(sysupdate-transfer.c:834-851)。
5. **中间态不再污染分区 label,而是派生 partition type UUID**(app-specific HMAC,sysupdate-partition.c:12-24);
   文件系统侧用 `.sysupdate.partial./.sysupdate.pending.` 前缀(sysupdate-resource.c:152-161)。
6. **没有 rollback/revoke 机制**:全目录 grep 无 rollback;回滚 = 老 slot 未被覆盖 + 引导菜单自选;
   代码提供的唯一保护是 `ProtectVersion=`/`MinVersion=` 防误删(sysupdate-transfer.c:547-548、977-989)。
7. **sysupdate 不 resize 分区**:growfs 只是写 GPT attribute 位,扩容动作交给后续 growfs/repart
   (sysupdate-partition.c:284-337 无 size 分支)。
8. **systemd-sysupdated 是 D-Bus 活动守护进程,内部仍 fork systemd-sysupdate CLI**
   (`--json=short`,可被 `$SYSTEMD_SYSUPDATE_PATH` 覆盖,sysupdated.c:392-396、419-470);
   updatectl 是其 D-Bus 客户端(src/shared/bus-locator.c:67-70);
   sysupdate 自身 varlink 服务器(CheckNew/ListFeatures/ListTargets)仅在 varlink 方式调用时启用(sysupdate.c:3513-3532)。

## 6. 设计动机(从源码注释与结构归纳)

```c
/* src/sysupdate/sysupdate.c:608-614(节选) */
if (!match && !(extra_flags & (UPDATE_PARTIAL|UPDATE_PENDING)))
        /* When we're looking for installed versions, let's be robust and treat
         * an incomplete installation as an installation. Otherwise, there are
         * situations that can lead to sysupdate wiping the currently booted OS.
         * See https://github.com/systemd/systemd/issues/33339 */
        extra_flags |= UPDATE_INCOMPLETE;
```

1. **服务器无状态**:只需静态文件 + 一份 `SHA256SUMS`;过期控制是清单里的 `BEST-BEFORE-*` 空文件(校验其
   SHA256 恰为空文件哈希,resource.c:468-478),客户端自校验,过期即 ESTALE 拒更(resource.c:488-505)。
2. **任意时刻断电可恢复**:partial→pending→final 三级命名/类型阶梯让中间态自描述;
   重入时 vacuum 先清 partial,pending 受保护(sysupdate-transfer.c:871-912)。
3. **不重造下载/解包轮子**:全部委托 systemd-pull/import,白得 SHA256 校验、压缩、稀疏文件、沙箱
   (sysupdate-transfer.c:1425-1428 注释)。
4. **GPT 即元数据**:slot 占用、中间态、no-auto/ro/growfs 属性全写进分区表本身,无需 sidecar 状态文件
   (sysupdate-partition.c:193;sysupdate-transfer.c:1629-1647)。
5. **保守删除**:永远保底 1 实例、分区表至少留 1 个可用 slot、`space==instances_max` 直接 ENOSPC
   (sysupdate-transfer.c:914-967);incomplete 的已装版本宁可当"装了"也不当"可删"(sysupdate.c:604-614)。
6. **生态协同而非接管**:更新完成只广播 varlink 通知,boot entry/PCR 度量/sysext 刷新由各守护进程自行响应
   (bootctl-link.c:1697-1706 注释:"deliberately ignore all parameters")。
7. **同一套定义适配多变体**:feature 条件门控 + component 维度,让"基础系统 + 可选组件"独立升级,
   `--component-all` 复用同一 context_update 循环(sysupdate-transfer.c:518-540;sysupdate.c:2740-2774)。

## 7. FAQ 候选与深挖方向

### 7.1 FAQ 候选(每条一句话答案)

1. `acquire` 和 `update` 差在哪?——`update` 默认带 ACQUIRE 动作位,`--offline` 时只剩 INSTALL(sysupdate.c:2783-2789)。
2. "下一个空 slot"怎么找?——遍历 GPT,选类型匹配、label 恰为 `_empty`、容量够的最小分区(sysupdate-partition.c:180-207)。
3. 下载到一半断电会怎样?——分区停在 partial type UUID(或文件停在 `.sysupdate.partial.` 前缀),下次 vacuum 先清掉重来(sysupdate-transfer.c:871-912)。
4. 装到一半断电呢?——停在 pending 态,`list` 显示 "current+pending",`update` 重入走 `context_process_partial_and_pending` 只补安装(sysupdate.c:1585-1588、1671-1732)。
5. sysupdate 帮我写 BLS entry 吗?——不写,只装文件;bootctl 收到 OnCompletedUpdate 通知后自己 link(bootctl-link.c:1697-1730)。
6. 为什么 URL 源必须有 SHA256?——下载无法事后验证,manifest 行内嵌 hex 是唯一凭据,缺失直接拒绝(sysupdate-transfer.c:1405-1415)。
7. 版本比较用什么?——`strverscmp_improved`,UpdateSet 光标按"严格小于边界"逐版回退扫描(sysupdate.c:556-578)。
8. 怎么保护某版本不被清理?——`ProtectVersion=`(可多次),vacuum 跳过受保护版本(sysupdate-transfer.c:548、977-989)。
9. 怎么判断"当前运行的版本"?——读 os-release 的 `IMAGE_VERSION=` 字段,不是查磁盘(sysupdate.c:2933-2938)。
10. systemd-sysupdated 里跑的是谁?——fork 出的 `systemd-sysupdate --json=short` 子进程,stdout 经 memfd+JSON 行解析回 D-Bus(sysupdated.c:419-470)。
11. 同一版本出现多个实例会怎样?——允许(分区表不强制唯一),排序以路径为次键并打提示(resource.c:661-680、721-739)。
12. feature 被禁用后 transfer 会怎样?——进 `disabled_transfers`,vacuum 时其全部实例被清空(sysupdate.c:333-336、1091-1097)。

### 7.2 深挖方向

1. `context_discover_update_sets_by_flag()` 光标扫描算法(sysupdate.c:525-727):AVAILABLE 缺件即弃、
   INSTALLED 缺件补 INCOMPLETE 的不对称,以及 candidate 提升的三条规则(674-676、709-724)。
2. `io.systemd.SysUpdate.Notify.OnCompletedUpdate` 通知协议:`varlink_execute_directory` 一对多扇出、
   5 分钟超时、`$SYSTEMD_SYSUPDATE_FORCE_NOTIFY` 空通知语义(sysupdate.c:1734-1808),
   与 bootctl link-auto 的 staging 目录搜索序(bootctl-link.c:1053-1064)。
3. installdb 清理机制:"目录+pattern" 符号链接库如何做到 transfer 定义变更后仍能定位并清理孤儿文件
   (sysupdate-cleanup.c:25-54、178-260)。
4. sysupdated 的 Job 生命周期:memfd 捕获 stdout、`job_parse_child_output` 解析进度/版本 JSON 行、
   忙碌目标 EBUSY 语义(sysupdated.c:196-306、419-425)。
5. URL 源安全模型:manifest 文件名过滤(拒 `..`/`%`/控制字符)、BEST-BEFORE 新鲜度、
   pattern 内嵌 `@h` 与 manifest 双处 SHA256 交叉校验(resource.c:593-600、629-635)。

## 8. 正文蒸馏要点

1. sysupdate 的原子单位是 transfer(Source→Target 复制规则),版本聚合是 UpdateSet;
   七个 Resource 类型中仅 partition/regular-file/directory/subvolume 可作 Target(sysupdate-resource.h:7-35)。
2. instance 文件名/GPT label 用 `@v` 等字段标记语法描述,`@v` 必须存在且字段间需字面分隔符(sysupdate-pattern.c:50-79、126-131、202-203)。
3. 动词集已无 fetch/verify:`acquire`=下载、`update`=下载+安装(`--offline` 只装),`check-new` 无更新时退非零(sysupdate.c:2513-2544、2781-2796)。
4. A/B slot = GPT 中 label 为 `_empty`、类型匹配、容量够的最小分区;回收 slot 只改 label 不删表项(sysupdate-partition.c:148-213;sysupdate-transfer.c:830-851)。
5. 中间态用派生 GPT type UUID(partial/pending,app-specific HMAC)与 `.sysupdate.partial./.pending.` 前缀表达,不用 label 前缀(sysupdate-partition.c:12-24;sysupdate-resource.c:152-161)。
6. 传输全部委托 systemd-pull/systemd-import 子进程,URL 源强制 SHA256,`--offset/--size-max` 直写分区设备(sysupdate-transfer.c:1405-1415、1417-1561)。
7. 分区安装 = 三次 GPT 改写(partial→pending→真实类型),顺带写 PARTUUID/flags/no-auto/ro/growfs 位;从不 resize 分区(sysupdate-transfer.c:1381-1398、1618-1657、1743-1760;sysupdate-partition.c:284-337)。
8. vacuum 是保守删除:保底 1 实例、分区至少留 1 slot、ProtectVersion 豁免;incomplete 已装版本不当可删(sysupdate-transfer.c:914-1011;sysupdate.c:604-614)。
9. 无 rollback 命令:回滚 = 保留的老 slot + 引导菜单;仅有 MinVersion/ProtectVersion 防误删(sysupdate-transfer.c:547-548、977-989)。
10. sysupdate 不写 boot entry、不调 ukify/kernel-install;bootctl/pcrlock/sysext 经 `/run/systemd/sysupdate/notify/` varlink 通知自行收尾(bootctl-link.c:1053-1064、1697-1730;src/basic/constants.h:71-72)。
11. "当前版本"基准是 os-release 的 `IMAGE_VERSION=`,`--reboot`/`reboot`/`pending` 动词据此决策(sysupdate.c:2683-2692、2933-2955)。
12. 守护态体系:org.freedesktop.sysupdate1(systemd-sysupdated,D-Bus)内部 fork systemd-sysupdate CLI;updatectl 为其客户端;sysupdate 亦可 varlink 直连(sysupdated.c:392-470;sysupdate.c:3513-3532)。
