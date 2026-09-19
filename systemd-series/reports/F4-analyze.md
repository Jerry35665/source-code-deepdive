# 报告 F4 · systemd-analyze(systemd 卷四)

> 基线:1f66b524(nspawn: align config `PrivateUsersOwnership` default with CLI)——systemd-analyze 是一个"借 PID1 解析器与 D-Bus 属性做离线/在线体检"的瑞士军刀:启动链(time/blame/critical-chain/plot)全部读 Manager 的单调时间戳属性而非任何日志,security 用 81 项加权评估器算 exposure,verify 直接复用 libcore 的 Manager 装载代码。

## 1. 动词全景:分发与文件对照

`analyze.c` 不再是传统 switch 分发,而是声明式动词表:每个动词由 `VERB_SCOPE(, verb_xxx, ...)` 注册,分成 9 个 `VERB_GROUP`(analyze.c:211-299),`dispatch_verb()` 统一分发(analyze.c:688)。全局选项集中在 `parse_argv()`,并在尾部做"选项×动词"合法性校验(analyze.c:572-630),例如 `--offline=` 只配 security(analyze.c:572-574)、`--json=` 只配 13 个动词(analyze.c:580-583)。

| 动词组 | 动词 → 实现文件 | 一句话 |
|---|---|---|
| Boot Analysis | time → analyze-time.c | 打印 firmware+loader+kernel+initrd+userspace 启动耗时(analyze-time.c:21-26) |
| | blame → analyze-blame.c | 按"激活耗时"降序列出 running 单元(analyze-blame.c:39-45) |
| | critical-chain → analyze-critical-chain.c | 从 default.target 沿 After= 回溯时间关键链(analyze-critical-chain.c:240) |
| Dependency Analysis | plot → analyze-plot.c | 同一数据源画 SVG(或 `--table`/`--json=` 出表格)(analyze-plot.c:475-518) |
| | dot → analyze-dot.c | 输出依赖图 dot(1) 格式 |
| | dump → analyze-dump.c | 调 Manager 的 D-Bus `Dump`/`DumpByFileDescriptor` 序列化(analyze-dump.c:23-41) |
| 配置与搜索路径 | cat-config → analyze-cat-config.c | 显示配置文件及其 drop-in |
| | unit-files → analyze-unit-files.c | 列出 unit 别名映射(`ids:`/`aliases:`)(analyze-unit-files.c:24-59) |
| | unit-paths → analyze-unit-paths.c | 列出 unit 加载目录(唯一支持 `--global` 的动词,analyze.c:589-591) |
| 枚举 OS 概念 | exit-status/capability/syscall-filter/filesystems/architectures/smbios11/chid/transient-settings | 见第 5 节;capability 在 analyze-capability.c,syscall-filter 在 analyze-syscall-filter.c |
| 表达式求值 | condition → analyze-condition.c | 离线求值 Condition=/Assert=(analyze-condition.c:139-150) |
| | compare-versions / image-policy | 版本串比较;镜像策略串解析 |
| Clock & Time | calendar/timestamp/timespan | 纯解析器回环验证,不碰系统 |
| Unit & Service Analysis | verify → analyze-verify.c | 静态校验 unit 文件(第 3 节) |
| | security → analyze-security.c | 沙箱暴露面评分(第 2 节) |
| | fdstore/malloc/unit-gdb/unit-shell | D-Bus fdstore 查询/malloc 统计/进服务命名空间调试与执行 |
| Executable Analysis | inspect-elf/dlopen-metadata | 解析 ELF 打包元数据与 dlopen 依赖 |
| TPM Operations | has-tpm2/identify-tpm2/pcrs/nvpcrs/srk | TPM2 探测与 PCR/NvPCR 导出 |

另有 7 个已弃用且不进 `--help` 的动词(log-level/log-target/set-log-level/get-log-level/set-log-target/get-log-target/service-watchdogs,analyze.c:301-308)。构建上 systemd-analyze 直接 `link_with: libcore, libshared`(meson.build:54-56),这是 verify/condition/security --offline 能复用 PID1 代码的物理前提;`analyze-verify-util.c` 被单独列为 `export` 源(meson.build:43, 52)供 `test-verify.c` 复用。

## 2. security:沙箱暴露面评分

### 2.1 评估器表与权重

核心是 `security_assessor_table[]`(analyze-security.c:781-1646),共 81 个评估器(含 `#if HAVE_SECCOMP` 的 12 个 SystemCallFilter/Architectures 项,未编 seccomp 时为 69)。每个条目是 `struct security_assessor`:`id`(设置名)、`json_field`、`weight`、`range`、`assess` 回调、`offset`(SecurityInfo 内字段偏移)、`default_dependencies_only`(analyze-security.c:115-133)。代表性权重:

- `PrivateNetwork=` 权重 2500,全表最高(analyze-security.c:825-834);
- `User=/DynamicUser=` 权重 2000、range 10(analyze-security.c:782-790):root 记 badness 10,nobody 记 9,动态/静态非 root 记 0,user 管理器记 0(analyze-security.c:221-262);
- `CapabilityBoundingSet=~CAP_SYS_ADMIN`/`CAP_SET(UID|GID|PCAP)`/`CAP_SYS_PTRACE` 各 1500(analyze-security.c:986-1020);
- `RestrictNamespaces=~user` 与 `RestrictAddressFamilies=~AF_(INET|INET6)` 各 1500(analyze-security.c:1380-1389, 1456-1466);
- 大多数 Private*/Protect*/NoNewPrivileges/RestrictSUIDSGID/SystemCallFilter=@mount 等为 1000(analyze-security.c:802-912, 975-985, 1565-1573);
- 低位项:ProtectHostname=50、CAP_IPC_LOCK/CAP_SYS_CHROOT=50、CAP_LINUX_IMMUTABLE=75、AF_UNIX=25、CAP_BPF 等 25(analyze-security.c:922-932, 1198-1217, 1467-1477, 1274-1284)。

### 2.2 exposure 计算

`assess()` 先定义 0-1000 刻度的分级表(analyze-security.c:1753-1766),再逐项累积:

```c
// analyze-security.c:1816-1821, 1915
if (badness != UINT64_MAX) {
        assert(badness <= range);
        badness_sum += DIV_ROUND_UP(badness * weight, range);
        weight_sum += weight;
}
...
exposure = DIV_ROUND_UP(badness_sum * 100U, weight_sum);
```

即"加权平均 badness×100",落在 0-1000;打印成 `exposure/10.exposure%10` 的一位小数(analyze-security.c:1944),分级阈值同样是 0-1000 刻度:≥100(=10.0 分)DANGEROUS、≥90 UNSAFE、≥75 EXPOSED、≥50 MEDIUM、≥10 OK、≥1 SAFE、否则 PERFECT(analyze-security.c:1758-1765)。明细表中每项还给出"该项贡献占比" `DIV_ROUND_UP(DIV_ROUND_UP(badness*weight*100, range), weight_sum)`(analyze-security.c:1896)。`--threshold=N` 时 exposure 严格大于阈值即返回 `-EINVAL`(analyze-security.c:1976-1978),供 CI 把门。

```c
// analyze-security.c:221-254  assess_user:User= 项的 badness 刻度(range=10)
if (streq_ptr(info->user, NOBODY_USER_NAME)) {
        d = "Service runs under as '" NOBODY_USER_NAME "' user, ...";
        b = 9;
} else if (info->dynamic_user && !STR_IN_SET(info->user, "0", "root")) {
        d = "Service runs under a transient non-root user identity";
        b = 0;
} else if (info->user && !STR_IN_SET(info->user, "0", "root", "")) {
        d = "Service runs under a static non-root user identity";
        b = 0;
} else if (info->runtime_scope == RUNTIME_SCOPE_USER) {
        /* user@0.service 会被误分类,注释自认 (analyze-security.c:244-247) */
        d = "Service runs under the calling user's identity";
        b = 0;
} else {
        *ret_badness = 10;   /* root:满分扣 */
        ...
```

多值设置也非二值:`ProtectHome=` no→10 / read-only→5 / tmpfs→1 / yes→0(analyze-security.c:278-293);`ProtectSystem=` no→10 / yes→5 / full→3 / strict→0(analyze-security.c:317-332);`ProtectProc=` noaccess→1 / invisible|ptraceable→0 / 默认→3,range=3(analyze-security.c:441-446, 1310);UMask= 按 0002/0004/0020/0040 位阶梯 10/5/2/1/0(analyze-security.c:390-405);IPAddressDeny 无 allow list→10 / 含非 localhost→5 / 仅 localhost→2 / 全封→0(analyze-security.c:697-712);DeviceAllow 无 ACL→10 / strict|closed 且有 ACL→5 / 空 ACL→0(analyze-security.c:736-754);SystemCallFilter 对 deny list 命中@组记 10、allow list 命中记 9(analyze-security.c:636-669)。

### 2.3 数据来源:在线 D-Bus vs 离线 Manager 测试运行

默认(在线)`acquire_security_info()` 用 `bus_map_all_properties` 按 47 项属性映射表从运行中 manager 拉 `SecurityInfo`(analyze-security.c:2318-2391);只有 `--offline=` 才走纯静态路径:

```c
// analyze-security.c:2718-2723, 2737-2743, 2795  offline_security_checks:迷你 manager
const ManagerTestRunFlags flags =
        MANAGER_TEST_RUN_MINIMAL |
        MANAGER_TEST_RUN_ENV_GENERATORS |
        MANAGER_TEST_RUN_IGNORE_DEPENDENCIES |
        MANAGER_TEST_DONT_OPEN_EXECUTOR |
        run_generators * MANAGER_TEST_RUN_GENERATORS;
...
r = manager_new(scope, flags, &m);
...
r = manager_startup(m, /* serialization= */ NULL, /* fds= */ NULL, ..., root);
...
k = manager_load_startable_unit_or_warn(m, /* name= */ NULL, prepared, LOG_ERR, &units[count]);
```

装载成功后 `get_security_info(u, unit_get_exec_context(u), unit_get_cgroup_context(u), ...)` 直接从内核于内存中的 ExecContext/CGroupContext 抄字段(analyze-security.c:2699, 2475-2680)。`--offline` 必须显式给 unit 名(analyze.c:576-578)。在线路径还做"推导"避免双重扣分:设置了 PrivateDevices/ProtectHome 等 ⇒ 视为 private_mounts(analyze-security.c:2413-2421),ProtectKernelModules ⇒ 从 bounding set 清 CAP_SYS_MODULE(2423-2424),ProtectClock ⇒ 清 CAP_SYS_TIME|CAP_WAKE_ALARM(2429-2431),PrivateDevices ⇒ 清 CAP_MKNOD|CAP_SYS_RAWIO(2433-2435)。

### 2.4 策略 JSON 与 NA 判定

`--security-policy=` 或 `CONF_PATHS` 下的 `systemd-analyze-security.policy` 可整体覆盖每项的 weight/range/描述(analyze-security.c:2949-2967, 1648-1743);policy 中 weight=0 的项按"Option excluded by policy, skipping"跳过(analyze-security.c:1803-1807)。三种跳过(NA)情况记 badness=UINT64_MAX 且不计入分母:特殊启动阶段的单元(default_dependencies_only,1798-1802)、root 下不适用的 RemoveIPC=/SupplementaryGroups=(501-502, 520-521)、user 作用域的 RemoveIPC=(495-499)。`user` 管理器恒判"非特权",代码注释自认 user@0.service 会被误分类(analyze-security.c:184-200, 244-247)。

### 2.5 一项扣分判定流程(ASCII)

```
            ┌────────────────────────────────────────────┐
            │ FOREACH_ELEMENT(a, security_assessor_table) │  81 项
            └───────────────────┬────────────────────────┘   (analyze-security.c:1789)
                                │
        ┌───────────────────────┴────────────────────────┐
        │ default_dependencies_only 且单元在特殊启动阶段? │──是──▶ badness=UINT64_MAX (NA)
        │       (analyze-security.c:1798-1802)           │       "Service runs in special boot phase"
        └───────────────────────┬────────────────────────┘
                                │否
        ┌───────────────────────┴────────────────────────┐
        │   policy 把 weight 置 0?                        │──是──▶ NA,"Option excluded by policy"
        │       (analyze-security.c:1803-1807)           │
        └───────────────────────┬────────────────────────┘
                                │否
        ┌───────────────────────┴────────────────────────┐
        │ a->assess(...) 按设置取 0..range 的 badness      │  例:assess_user root→10 / nobody→9 / 非 root→0
        │   (analyze-security.c:1809, 221-262)           │      assess_bool: parameter 决定正反向 (203-219)
        └───────────────────────┬────────────────────────┘
                                │
                 badness_sum += DIV_ROUND_UP(badness*weight, range)
                 weight_sum  += weight          (analyze-security.c:1819-1820)
                                │  循环结束
                 exposure = DIV_ROUND_UP(badness_sum*100, weight_sum)   (:1915)
                                │
                 ≥100 DANGEROUS │ ≥90 UNSAFE │ ≥75 EXPOSED │ ≥50 MEDIUM │ ≥10 OK │ ≥1 SAFE │ 0 PERFECT
                 (analyze-security.c:1758-1765)
                                │
                 exposure > --threshold ⇒ 返回 -EINVAL(:1976-1978)
```

## 3. verify:静态校验与 PID1 解析复用

`verb_verify()` 先在 `/tmp/systemd-analyze-XXXXXX` 建临时目录,把 `别名:真身` 语法(`process_aliases`)拷贝为真名文件(analyze-verify.c:16-60, 67-73),然后调 `verify_units()`。校验不是"重新实现一遍解析",而是真跑一个迷你 manager:标志 `MANAGER_TEST_RUN_MINIMAL|MANAGER_TEST_RUN_ENV_GENERATORS|MANAGER_TEST_DONT_OPEN_EXECUTOR`,按 `--recursive-errors=` 增减 IGNORE_DEPENDENCIES/GENERATORS(analyze-verify-util.c:289-294),随后 `manager_startup()`(321 行)、`manager_load_startable_unit_or_warn()`(341 行)——即与 PID1 同一套 config_parse/unit 装载代码(链接 libcore)。每个通过装载的单元再过四道关:

```c
// analyze-verify-util.c:252-271
static int verify_unit(Unit *u, bool check_man, const char *root) {
        ...
        r = manager_add_job(u->manager, JOB_START, u, JOB_REPLACE, &error, /* ret= */ NULL);
        if (r < 0)
                log_unit_error_errno(u, r, "Failed to create %s/start: %s", ...);
        RET_GATHER(r, verify_socket(u));          /* socket 必须能找到其 service (171-190) */
        RET_GATHER(r, verify_executables(u, root)); /* ExecCommand 路径必须可执行 (192-224) */
        RET_GATHER(r, verify_documentation(u, check_man)); /* man: 页可打开 (226-250) */
        return r;
}
```

`manager_add_job(JOB_START)` 意味着依赖闭包也会被装载检查。语法告警通过 `set_log_syntax_callback` 收集成集合(analyze-verify-util.c:25-42, 308),全部装载成功但存在告警时按 `--recursive-errors=` 模式返回 `-ENOTRECOVERABLE`(362-379)。`verify_set_unit_path()` 把参数文件的目录前插进 `SYSTEMD_UNIT_PATH`(analyze-verify-util.c:129-169);模板实例用全局 `arg_instance`(默认 "test_instance",analyze.c:94)替换实例名(analyze-verify-util.c:63-67)。

## 4. 启动链:time/blame/critical-chain/plot 的数据来源

四个动词共用 `analyze-time-data.c`,数据只有一路:Manager 及每单元的 D-Bus 属性,连"单元耗时"都是两个时间戳相减而非日志统计:

```c
// analyze-time-data.c:304-318  acquire_time_data 的单元属性映射(节选)
static const struct bus_properties_map property_map[] = {
        { "InactiveExitTimestampMonotonic",  "t",  NULL, offsetof(UnitTimes, activating)           },
        { "ActiveEnterTimestampMonotonic",   "t",  NULL, offsetof(UnitTimes, activated)            },
        { "ActiveExitTimestampMonotonic",    "t",  NULL, offsetof(UnitTimes, deactivating)         },
        { "InactiveEnterTimestampMonotonic", "t",  NULL, offsetof(UnitTimes, deactivated)          },
        { "After",                           "as", NULL, offsetof(UnitTimes, deps[UNIT_AFTER])     },
        { "Before",                          "as", NULL, offsetof(UnitTimes, deps[UNIT_BEFORE])    },
        { "Requires",                        "as", NULL, offsetof(UnitTimes, deps[UNIT_REQUIRES])  },
        ...
};
```

`acquire_boot_times()` 一次拉 `FirmwareTimestampMonotonic`/`LoaderTimestampMonotonic`/`KernelTimestamp`/`InitRD*`/`UserspaceTimestampMonotonic`/`FinishTimestampMonotonic`/`Security*TimestampMonotonic`(LSM 初始化)/`Generators*`/`UnitsLoad*`/`PreviousShutdown*`/`SoftRebootsCount` 共 24 项(analyze-time-data.c:39-64);单元耗时 `time = activated - activating`(analyze-time-data.c:390-395)。不是读 bootup 日志,也没有 BootChart:仓库 src/ 下已无 bootchart 目录,src/analyze 中 grep "bootchart" 零命中(本次核实)。

- time:`pretty_boot_time()` 拼接 "Startup finished in firmware + loader + kernel + initrd + userspace = 总长";新增两条链路:LUO/kexec 活更新恢复的上一轮 shutdown 三段前置打印(analyze-time-data.c:210-230),以及 soft-reboot 时把 firmware/kernel/initrd 清零、以 `previous_shutdown_start_time` 为 reverse_offset 平移(analyze-time-data.c:96-113)。
- blame:`require_finished=false`,按 time 降序排表(analyze-blame.c:23, 39-45),time<=0 的单元被跳过(analyze-blame.c:48)。
- critical-chain:默认从 `SPECIAL_DEFAULT_TARGET` 出发,递归取 `After=` 属性,只在 `activated <= finish_time` 的单元里找"最晚激活者",比它早不超过 `--fuzz` 的依赖才继续展开(analyze-critical-chain.c:83-85, 112-133, 240)。
- plot:同一份 UnitTimes 先按 activating 排序,画 SVG(`SCALE_X=0.1*timescale/1000.0` 像素每微秒,analyze-plot.c:22-23);图例含 security(LSM 初始化)/generators/unitsload 三种系统条(analyze-plot.c:377-383);`--table`/`--json=` 时改为输出六列原始时间表 `produce_plot_as_text()`(analyze-plot.c:449-470, 497)。user/container 作用域下 firmware~userspace 全清零、以 userspace 为原点(analyze-time-data.c:120-138)。

## 5. 静态表导出动词简述

- capability:合并 `CAP_LAST_CAP`(编译期)与 `cap_last_cap()`(运行期内核)枚举全部 capability(analyze-capability.c:34);`--mask` 解析十六进制掩码逐位反解(analyze-capability.c:36-59)。
- syscall-filter:导出 `syscall_filter_sets` 全部分组;无参数时还读 `/sys/kernel/tracing/available_events`(旧 debugfs 路径兜底)列出"内核支持但不在任何组里"的 syscall,并隐藏 newuname 等历史别名(analyze-syscall-filter.c:29-56, 180-193);未编 seccomp 时直接 EOPNOTSUPP(analyze-syscall-filter.c:200-202)。
- filesystems:同一套路,分组来自 `filesystems.h` gperf 表,并读 `/proc/filesystems` 补"内核实际支持"对比(analyze-filesystems.c:18-51)。
- architectures:三列表 id/name/support(analyze-architectures.c:49)。
- pcrs:优先用内核接口 `/sys/class/tpm/tpm0/pcr-{sha256,sha384,sha1}/N` 直读 PCR 值,全 0/全 FF 的 PCR 置灰(analyze-pcrs.c:16-35, 83-85);TPM2 支持不足时只列 nr/name(analyze-pcrs.c:99-102)。
- nvpcrs:NvPCR 名录来自 `conf_files_list_nulstr` 配置,有 TPM2 时经 `tpm2_nvpcr_read()` 读 NV 索引值,否则只给 nvindex/priority(analyze-nvpcrs.c:15-50, 55-80)。

## 6. 纠偏(以 1f66b524 源码为准)

1. **没有 "boot-chain" 动词**:启动链分析由 time/blame/critical-chain(+plot)承担,`analyze.c` 动词表里无此名(analyze.c:211-217);bootchain 一词在 src/analyze 中零命中。
2. **启动链数据不来自 bootup 日志,BootChart 也早已不在**:全部读 Manager/Unit 的 D-Bus 单调时间戳属性(analyze-time-data.c:39-64, 304-318);src/ 无 src/bootchart,plot 就是当年的 bootchart 替代(本次核实)。
3. **security 评分清单里没有 LoadCredential**:src/analyze 全目录 grep `LoadCredential|SetCredential` 零命中,`SecurityInfo` 字段集(analyze-security.c:41-113)不含凭证类设置;评分只覆盖 81 项沙箱设置。
4. **security 默认是在线(需要运行中的 manager),离线才是例外**:无 `--offline` 时先连 D-Bus(analyze-security.c:2941-2945),且全量扫描只看 `.service`、只看已加载、跳过 oneshot(analyze-security.c:2867-2882);`--offline` 又必须显式给 unit(analyze.c:576-578)。
5. **exposure 不是"扣分项计数",而是加权平均**:分子是各项 `badness*weight/range` 之和,分母是有效项权重和(analyze-security.c:1819-1820, 1915),NA 项(UINT64_MAX)双跳过、不影响分母。
6. **verify 不是文本正则校验**:它复用 libcore 的 manager 装载与 job 闭包(meson.build 链接、analyze-verify-util.c:262),所以能发现"依赖单元装载失败"这类语义错误,而非仅语法。
7. **`--offline`/`--root=`/`--image=` 的组合限制**:`--root/--image` 只配 cat-config/verify/condition/inspect-elf/unit-gdb 和 offline 模式的 security(analyze.c:601-605),`--root` 与 `--image` 互斥(analyze.c:608-609)。
8. **security 对 user 作用域恒判"非特权"是已知误报点**:代码注释明确 user@0.service(root 拥有的用户管理器)下的服务会被错判为不受权(analyze-security.c:184-200, 244-247),引用评分结论时应注意该边界。
9. **`plot` 的 `--table` 与 `--json=` 互斥**(analyze.c:620-624),且 plot 在 user 作用域会退化为"以 userspace 为原点"的相对时间轴,firmware/kernel 段不存在(analyze-time-data.c:120-138)。

## 7. 选项×动词的合法性校验矩阵(节选)

`parse_argv()` 尾部把"哪些选项配哪些动词"写成硬性检查,这本身就是一张使用地图(analyze.c:572-630):`--offline=` 仅 security(572-574);`--json=` 仅 13 个动词:security/inspect-elf/dlopen-metadata/plot/fdstore/pcrs/nvpcrs/architectures/capability/exit-status/chid/blame/identify-tpm2(580-583);`--threshold=` 仅 security(585-587);`--global` 仅 unit-paths(589-591);`--user` 不支持 cat-config(593-595);`--security-policy=` 仅 security(597-599);`--table` 仅 plot 且与 `--json=` 互斥(620-624);`--mask` 仅 capability(626-627);`--drm-device` 仅 chid(629-630);`--unit=` 仅 condition(611-612)。这些检查意味着:凡在正文中描述"某选项的行为",都必须同时声明其绑定动词,否则运行期直接 EINVAL。

## 8. 设计动机、FAQ 候选与深挖方向

### 设计动机(≥5)

1. **"借尸还魂"复用 PID1 解析器**:链接 libcore 让 verify/security --offline/condition 与 PID1 行为零漂移,避免第二套解析器(meson.build:54-56;analyze-verify-util.c:315-321)。
2. **把"安全建议"量化成单一分数**:81 项加权 + 归一化到 0.0-10.0,使 CI 能用 `--threshold=` 机械把门(analyze-security.c:1915, 1976-1978)。
3. **权重表即文档**:每项评估器自带 man URL,表格单元格直接可点击跳转(analyze-security.c:186-187 及全表 `.url` 字段;渲染于 1864)。
4. **推导避免双重扣分**:Protect* 隐含的 bounding-set 收紧由代码显式推导(analyze-security.c:2423-2435),防止同一防护被两个评估器各罚一次。
5. **离线评审面向镜像/便携场景**:`--offline` 配 `--profile=` 可把 portable profile 以 drop-in 注入再评分(analyze-security.c:2747-2793)。
6. **策略外置**:内置权重可被 `systemd-analyze-security.policy` JSON 按发行版/合规基线整体改写,包括把某项 weight 置 0 除名(analyze-security.c:2954-2966, 1803-1807)。
7. **soft-reboot/LUO 时代的时间轴修正**:启动时间轴必须对"上一轮 shutdown 起点"做平移,否则图会跨软重启拉长到荒谬(analyze-time-data.c:96-113, 366-370)。
8. **评分项的"三种状态"而非二元**:good/bad/NA 各配独立文案,NA 文案同样可被策略 JSON 覆盖(access_description_na,analyze-security.c:1700-1713),使"不适用"与"未加固"在报告中可区分。
9. **静态表动词同时对照本地内核**:syscall-filter/filesystems/capability 都把"我们认识的"与"本机内核支持的"做差集展示,服务于跨内核迁移审查(analyze-syscall-filter.c:180-193;analyze-filesystems.c:18-51;analyze-capability.c:34)。

### FAQ 候选(10 条,每条一句话答案)

1. `systemd-analyze time` 的 "firmware" 一段怎么算的?——`FirmwareTimestampMonotonic - LoaderTimestampMonotonic`(analyze-time-data.c:232)。
2. exposure 的满分是多少?——内部 0-1000,打印/阈值按 0.0-10.0 一位小数呈现(analyze-security.c:1915, 1944)。
3. 为什么根服务里 User= 只扣一部分?——User= 的 range 是 10,badness 10 才等于满扣,nobody 只扣 9(analyze-security.c:788, 235-237)。
4. `SystemCallFilter=~@known` 这类组怎么参与评分?——按 11 个 SystemCallFilter 风险组各自独立评估,匹配任一 offend syscall 即按该组权重扣分(analyze-security.c:1521-1618, 610-678)。
5. `analyze security` 不带参数时为什么漏掉我的 oneshot 服务?——全量模式强制 ONLY_LOADED|ONLY_LONG_RUNNING,oneshot 被跳过(analyze-security.c:2882, 2410-2411)。
6. verify 会执行 unit 里的命令吗?——不会,只 `find_executable_full` 检查 ExecCommand 路径存在可执行(analyze-verify-util.c:192-206),manager 以 DONT_OPEN_EXECUTOR 运行(289-294)。
7. `verify foo.service:bar.service` 是什么语法?——别名:把真身文件以别名拷进临时目录参与校验(analyze-verify.c:16-60)。
8. critical-chain 的 `--fuzz` 是什么?——比"最晚激活的依赖"早不超过 fuzz 秒的兄弟依赖也算进关键链(analyze-critical-chain.c:123-133)。
9. `plot --table` 输出什么?——SVG 换成六列原始时间表(name/activated/activating/time/deactivated/deactivating)(analyze-plot.c:453)。
10. `pcrs` 读值走 TPM 命令吗?——默认走内核 sysfs `pcr-<alg>/N` 虚拟文件,不走 /dev/tpm(analyze-pcrs.c:48-69)。

### 深挖方向(5 条)

1. `get_security_info()`(离线)与 `acquire_security_info()`(在线)的字段差集:离线从 ExecContext/CGroupContext 抄值(analyze-security.c:2475-2680),是否与 47 项 D-Bus 映射完全同义(如 RestrictAddressFamilies 双路径解析逻辑分别在 2031-2086 与 2567-2589)值得逐项对表。
2. `MANAGER_TEST_RUN_*` 各标志在 core/manager.c 里的确切语义(minimal 环境、env generators、ignore dependencies),决定 verify/security 离线与真实启动的差异边界。
3. soft-reboot(`SoftRebootsCount`、`reverse_offset`)与 LUO 恢复的 `PreviousShutdown*` 时间戳在 PID1 侧(src/core)的产生条件,是理解新时间轴逻辑的前置(analyze-time-data.c:48-51, 62, 96-113)。
4. `syscall_names_in_filter()` 对 `@` 组的递归展开与 `seccomp_syscall_resolve_name` 存在性过滤(analyze-security.c:581-608)——跨架构(非 NATIVE)时的漏判风险。
5. `systemd-analyze-security.policy` JSON 的完整 schema 及发行版实际部署样例(仓库内仅 src/ 稀疏检出,docs/ 未在检出范围,未核实)。

## 9. 正文蒸馏要点

1. systemd-analyze 是声明式动词表分发,9 组 36 个可见动词 + 7 个弃用隐藏动词,`dispatch_verb()` 统一入口(analyze.c:211-308, 688)。
2. 二进制直接链接 libcore,verify/security--offline/condition 因此与 PID1 共用同一套装载代码(meson.build:54-56)。
3. security 共 81 个评估器(HAVE_SECCOMP 时),表驱动 weight/range/assess 回调/SecurityInfo 偏移(analyze-security.c:781-1646, 115-133)。
4. `exposure = DIV_ROUND_UP(badness_sum*100, weight_sum)`,各项贡献 `DIV_ROUND_UP(badness*weight, range)`,刻度 0-1000、展示 0.0-10.0(analyze-security.c:1819-1820, 1915, 1944)。
5. 分级:≥100 DANGEROUS、≥90 UNSAFE、≥75 EXPOSED、≥50 MEDIUM、≥10 OK、≥1 SAFE、0 PERFECT(analyze-security.c:1758-1765)。
6. 最重权重:PrivateNetwork=2500;User=2000(range 10);CAP_SYS_ADMIN/CAP_SET(UID|GID|PCAP)/CAP_SYS_PTRACE/RestrictNamespaces=~user/AF_INET|INET6 各 1500(analyze-security.c:830, 787, 992-1019, 1385, 1462)。
7. 在线路径读 47 项 D-Bus 属性并做 bounding-set 推导去重;离线路径用 MANAGER_TEST_RUN_MINIMAL 迷你 manager + ExecContext 直抄(analyze-security.c:2318-2437, 2718-2807)。
8. `--threshold=N` 下 exposure 严格大于即 -EINVAL,是 CI 集成点;策略 JSON(`systemd-analyze-security.policy`)可改权重/除名(analyze-security.c:1976-1978, 2949-2966)。
9. LoadCredential/凭证类设置完全不在 security 评分清单内(src/analyze 零命中;SecurityInfo 定义 analyze-security.c:41-113)。
10. verify 校验四关:JOB_START 依赖闭包、socket→service、ExecCommand 可执行、man 页存在;语法告警按 `--recursive-errors=no/yes/one` 决定退出码(analyze-verify-util.c:252-271, 356-379)。
11. time/blame/critical-chain/plot 单一数据源:Manager 与 Unit 的 D-Bus 单调时间戳属性,无日志、无 BootChart(analyze-time-data.c:39-64, 304-318)。
12. soft-reboot 与 LUO/kexec 活更新引入 reverse_offset 平移与上一轮 shutdown 三段时间轴,是时间类动词最新复杂度来源(analyze-time-data.c:96-113, 210-230)。
