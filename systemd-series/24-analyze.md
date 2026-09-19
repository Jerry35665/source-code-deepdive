# 第 24 章 · systemd-analyze:借 PID1 的解析器做体检

> 基线:commit `1f66b524`。核心:src/analyze/(声明式动词表,9 个 VERB_GROUP)。构建上直接链接 libcore(meson.build:54-56)——这是 verify/security --offline 能复用 PID1 代码的物理前提。

## 24.0 全景:动词分组与单一数据源

```
 9 个 VERB_GROUP(analyze.c:211-299,dispatch_verb 统一分发 :688):
 Boot Analysis:time/blame/critical-chain/plot —— 全部读 D-Bus 单调时间戳
   (acquire_boot_times/acquire_time_data,analyze-time-data.c:39-64)
   ——非 bootup 日志、无 BootChart;也不存在 "boot-chain" 动词
 配置:cat-config/unit-files/unit-paths
 枚举:exit-status/capability/syscall-filter/filesystems/architectures/smbios11/chid
 表达式:condition/compare-versions/image-policy
 单元:verify/security;TPM:has-tpm2/identify-tpm2/pcrs/nvpcrs/srk
```

纠偏:启动链四动词(time/blame/critical-chain/plot)**单一数据源=D-Bus 单调时间戳属性**,非日志;新增复杂度来自 soft-reboot 的 reverse_offset 平移与 LUO/kexec 恢复的上一轮 shutdown 三段时间轴(analyze-time-data.c:96-113, 210-230)。

## 24.1 security:81 项加权评估器

核心是 security_assessor_table[](analyze-security.c:781-1646)共 81 项(无 seccomp 时 69)。exposure = **加权平均 badness×100**(0-1000 刻度):`exposure = DIV_ROUND_UP(badness_sum*100, weight_sum)`(:1915)。代表性权重:PrivateNetwork=2500 全表最重(:830),User=2000/range 10(:787),CAP_SYS_ADMIN 等三组 capability 与 RestrictNamespaces=~user、AF_INET|INET6 各 1500;多数 Private*/Protect*=1000;低位项 ProtectHostname=50、AF_UNIX=25。多值设置非二值:ProtectHome no→10/read-only→5/tmpfs→1/yes→0;UMask 按位阶梯 10/5/2/1/0。分级 ≥100 DANGEROUS … 0 PERFECT;`--threshold=` 严格大于即 -EINVAL,可作 CI 把门(:1976-1978)。纠偏:**LoadCredential/凭据设置完全不在评分清单内**(src/analyze 零命中)。

## 24.2 verify:跑真 manager 的静态校验

verify 不是文本正则校验——以 `MANAGER_TEST_RUN_MINIMAL|DONT_OPEN_EXECUTOR` 跑真 manager,对每个单元 `manager_add_job(JOB_START)` 做**依赖闭包检查**(analyze-verify-util.c:289-294, 262);security 离线模式同样 manager_startup 后直接从 ExecContext/CGroupContext 抄值(analyze-security.c:2718-2807)。默认(在线)security 用 bus_map_all_properties 按 47 项属性映射表拉 SecurityInfo(:2318-2391)。

## 24.3 设计动机

1. **链接 libcore**:分析器与 PID1 共用解析/装载代码,规则永不漂移(meson.build:54-56);
2. **声明式动词表**:选项×动词合法性集中校验(analyze.c:572-630);
3. **加权而非计数**:暴露面反映"最重的洞",PrivateNetwork 一项能主导总分(:830);
4. **在线/离线双源**:同一评分器服务运行态与镜像构建态(:2318 vs 2718);
5. **时间戳单一数据源**:soft-reboot/kexec 时代时间轴复杂度全部收敛在 time-data 一层(:96-230);
6. **threshold 把门**:exposure 与退出码挂钩,security 可进 CI(:1976-1978)。

## 24.4 FAQ

**Q1:time 系列动词读日志吗?**
不读,读 Manager 的 D-Bus 单调时间戳属性(analyze-time-data.c:39-64)。

**Q2:exposure 怎么算?**
81 项加权平均 badness×100,0-1000 刻度(:1915)。

**Q3:哪个安全项权重最高?**
PrivateNetwork=2500;User=2000;三组 capability 各 1500(:830, 787)。

**Q4:凭据设置计入评分吗?**
不计入,LoadCredential 等不在清单内。

**Q5:verify 是正则校验吗?**
不是,跑真 manager 做 JOB_START 依赖闭包检查(analyze-verify-util.c:289-294)。

**Q6:security 能离线吗?**
能,--offline 走迷你 manager 从 ExecContext 抄值(:2718-2807)。

**Q7:--threshold=10 什么行为?**
exposure 严格大于即 -EINVAL,适合 CI(:1976-1978)。

**Q8:有 boot-chain 动词吗?**
没有;启动分析四动词是 time/blame/critical-chain/plot。

**Q9:--global 谁能用?**
只有 unit-paths(analyze.c:589-591)。

**Q10:systemd-analyze 里有 TPM 动词吗?**
有:has-tpm2/identify-tpm2/pcrs/nvpcrs/srk(与卷四 15/21 章衔接)。

## 24.5 小结与深挖方向

本章结论:**analyze=链接 libcore 的离线/在线体检器;security=81 项加权暴露面;启动分析=D-Bus 时间戳单源**。深挖:

1. 评估器 offset 字段与 SecurityInfo 的反射式取值(analyze-security.c:115-133);
2. user 管理器误分类的自认注释(:244-247);
3. critical-chain 的 After= 回溯与 fragment 截断(analyze-critical-chain.c:240);
4. inspect-elf 的 dlopen 元数据与 pack 依赖;
5. srk 动词输出的 TPM2 SRK 公钥格式(与 15 章密封密钥衔接)。
