# 报告 C4 · measure 与 pcrlock(systemd 卷四)

> 基线:1f66b524(nspawn: align config `PrivateUsersOwnership` default with CLI)。一句话总结:systemd 用两条互补路线"驯服"不可预测的 PCR——systemd-measure 在构建期对 UKI 逐段做虚拟 extend,算出 PCR 11 的已知预期值并签出 PolicyPCR 策略;systemd-pcrlock 则在运行期解析 TCG 事件日志 + 组件库,把未来 PCR 状态枚举成有限组合,经 PolicyPCR+PolicyOR 折叠后写进 TPM NV index,由 PolicyAuthorizeNV 间接钉住。

## 一、模块地图:两个工具的分工

- `src/measure/measure-tool.c`(1110 行):**注意文件名是 measure-tool.c,仓库内不存在 measure.c**。文件头注释即定位:"预计算预期 PCR 值……按 sd-stub 测量 PCR 11 的方式"(measure-tool.c:30-31)。
- measure 的动词:`status`(读当前 PCR 11,measure-tool.c:387)、`calculate`(只算不签,:788)、`sign`(算并签,:1078)、`policy-digest`(只算策略摘要并输出待签数据,:1084)。
- `src/pcrlock/pcrlock.c`(5817 行)+ `pcrlock-firmware.c`(169 行):systemd-pcrlock,"管理 TPM2 PCR 锁"(pcrlock.c:106-111)。
- systemd-pcrlock 既是 CLI(约 20 个动词),也是 **root-only Varlink 常驻服务**:绑定 `io.systemd.PCRLock` 的 ReadEventLog/ListComponents/MakePolicy/RemovePolicy/Lock 与 `io.systemd.SysUpdate.Notify.OnCompletedUpdate` 六个方法(pcrlock.c:5778-5811、方法表 :5798-5803)。
- `src/pcrlock/pcrlock.d/`:**组件库**(数据而非代码),内置相位词等组件;构建时整目录安装(pcrlock/meson.build:27-45)。组件按数字前缀排序,即"启动时间轴"上的位置。
- 支撑层:`src/shared/tpm2-util.c`(策略计算/预测数据结构/日志路径)、`src/shared/pe-binary.c` 的 `uki_hash`(pe-binary.c:551)、`src/fundamental/uki.h/c`(段枚举与测量序)。
- 两者都强依赖 OpenSSL+TPM2 构建选项:pcrlock 缺一即整目录跳过(pcrlock/meson.build:5-7);measure 在入口声明 `LIBCRYPTO_NOTE(required)`(measure-tool.c:1093)。
- 分工一句话:measure 解决"**我知道内核会测什么**"(签名已知预期值);pcrlock 解决"**我不知道固件会测什么,但日志+组件库能枚举出有限可能**"(pcrlock.c:3632-3655 的官方自述注释)。

## 二、systemd-measure:UKI 段 → PCR 11 预期值

**输入面**(measure-tool.c:236-266):

- 每段一个 `--linux=…` 类选项,映射到 `UnifiedSection` 枚举,含 .linux/.osrel/.cmdline/.initrd/.ucode/.splash/.dtb/.dtbauto/.uname/.sbat/.pcrpkey/.profile/.hwids/.efifw(measure-tool.c:236-264)。
- `.pcrsig` 明确"不是签名输入"(measure-tool.c:256);`assert_cc(UNIFIED_SECTION_EFIFW + 1 == _UNIFIED_SECTION_MAX)` 保证新增段必须同步此表(:266)。
- `.pcrpkey` **会**被测量(:257-258)。
- bank 缺省全开:SHA1/SHA256/SHA384/SHA512(measure-tool.c:284-289)。
- 相位缺省硬编码 4 个:`enter-initrd`、`enter-initrd:leave-initrd`、`…:sysinit`、`…:ready`(:299-307)。
- `--current` 直接读现值,与 `--linux=` 互斥(:293-297)。

**核心结构**是每 bank 一个 PcrState,初值全零(measure-tool.c:471-477、739),extend 运算即 PCR 语义——先哈希旧值、再哈希新数据(measure-tool.c:506-538):

```c
// measure-tool.c:525-531(pcr_state_extend 的拼接次序)
/* First thing we do, is hash the old PCR value */
if (sym_EVP_DigestUpdate(mc, pcr_state->value, pcr_state->value_size) != 1)
        return log_error_errno(…);

/* Then, we hash the new data */
if (sym_EVP_DigestUpdate(mc, data, sz) != 1)
        return log_error_errno(…);
```

**段遍历与哈希拼接次序**(`measure_kernel`,measure-tool.c:542-662):

- 按 `UnifiedSection` 枚举值 0→MAX 遍历(measure-tool.c:583),这正是 ukify 规定的"规范测量序"(uki.h:8-10 注释 "This is the canonical order in which we measure the sections into TPM PCR 11. PLEASE DO NOT REORDER!"),而非 PE 文件布局序。
- 每段以 16KiB 缓冲流式哈希内容(:540、610-624)。
- **空文件跳过,并注明"stub 也这么做"**(:628-629)。
- 对每个 bank:先 extend `hash(段名+NUL)`(:639-645,EVP_Digest 传 `strlen+1`),再 extend `hash(段内容)`(:649-655)。

```c
// measure-tool.c:639-655(每段两次 extend 的次序,有删节)
/* Measure name of section */
if (sym_EVP_Digest(unified_sections[c], strlen(unified_sections[c]) + 1,
                   data_hash, &data_hash_size, pcr_states[i].md, NULL) != 1) …
r = pcr_state_extend(pcr_states + i, data_hash, data_hash_size); …
/* Retrieve hash of data and measure it */
if (sym_EVP_DigestFinal_ex(mdctx[i], data_hash, &data_hash_size) != 1) …
r = pcr_state_extend(pcr_states + i, data_hash, data_hash_size);
```

**相位测量**(`measure_phase`,measure-tool.c:664-710):相位串按":"切词(:675),每词 extend `hash(word)`(:699-703)——与组件库 `pcrlock.d/750-enter-initrd.pcrlock` 里的 digest 逐字节吻合(已验证:该文件 sha256 项 `51e6b92f…14fed` = SHA256("enter-initrd"))。运行期这些相位词由 pcrextend 侧扩入 PCR 11(pcrextend.c:189-194,缺省相位掩码落到 `TPM2_PCR_KERNEL_BOOT`)。

**多相位复用**:`calculate` 测完内核后 `pcr_states_save` 保存状态,每个相位算完即 `pcr_states_restore`,避免从零重算(measure-tool.c:815-817、865-866)。`--current` 模式不走模拟,直接读 `/sys/class/tpm/tpm0/pcr-<bank>/11`(:551-576)。构建端由 ukify 驱动:ukify.py 的 `call_systemd_measure` 把各段路径喂给本工具(ukify.py:812-830),`combine_signatures` 汇总多签为 `.pcrsig`(ukify.py:742-745)。

## 三、签名输出:签的是 PolicyPCR 摘要,不是裸 PCR 值

`sign`/`policy-digest` 共用 `build_policy_digest`(measure-tool.c:880-1076),强制 JSON 输出(:907)。每相位 × 每 bank 的流水线(measure-tool.c:995-1064):

1. 用该 bank 的预期 PCR 值算 `tpm2_calculate_policy_pcr` → 策略摘要(:1006-1010)。
2. 把"策略摘要+policyRef"拼成待签数据 TBS(:1012-1013);TBS 即两者的字节串接,对应 TPM2 规范 PolicyAuthorize 的签名语义(tpm2-util.c:6926-6951,注释引 Spec Part 3, 23.16)。
3. **签名摘要恒为 SHA256,与 `--bank` 无关**(measure-tool.c:1020-1021:"We always use SHA256 for signing currently. Regardless of the bank.")。
4. 附公钥 SHA256 指纹 pkfp(:1030-1036、1046)。

```c
// measure-tool.c:1043-1050(.pcrsig 的 JSON 内容,有删节)
r = sd_json_buildo(&bv,
                   SD_JSON_BUILD_PAIR_VARIANT("pcrs", a),                        /* PCR 掩码 */
                   SD_JSON_BUILD_PAIR_CONDITION(pubkey_fp_size > 0, "pkfp", …),  /* 公钥指纹 */
                   SD_JSON_BUILD_PAIR_CONDITION(!isempty(arg_policyref), "ref",…),
                   SD_JSON_BUILD_PAIR_HEX("pol", pcr_policy_digest.buffer, …),   /* PolicyPCR 摘要 */
                   SD_JSON_BUILD_PAIR_CONDITION(!sign, "tbs", …),                /* 待签数据 */
                   SD_JSON_BUILD_PAIR_CONDITION(ss > 0, "sig", …));              /* base64 签名 */
```

- `.pcrsig` 记录的是"策略摘要的签名":验证方(卷三 15 章的 PolicyAuthorize 路径)用 pkfp 选公钥验签 pol,再让 TPM 会话比对 PCR 实际值是否落在 pol 上。
- `policy-digest`(sign=false)输出 `tbs` 供外部 HSM 离线签名(:1049);`--append=` 可向已有 JSON 追加签名(:900-904)。
- 密钥约束:`--public-key` 与 `--certificate` 互斥(:278-279);签名时私钥缺省自动派生公钥(:968-973)。

## 四、systemd-pcrlock:双日志解析与自校验

**日志源有两个**,路径均可被 env 覆盖(tpm2-util.c:8445-8451):

- 固件 TCG log:`/sys/kernel/security/tpm0/binary_bios_measurements`(pcrlock.c:947)。头校验:EV_NO_ACTION、PCR0、零摘要、签名 "Spec ID Event03"(pcrlock-firmware.c:104-123);逐事件按头部宣告的算法表步进(pcrlock-firmware.c:31-80)。
- userspace JSON log:`/run/log/systemd/tpm2-measure.log`,记录间以 ASCII 0x1E 分隔(pcrlock.c:1241),共享锁读取(:1219)。
- **sticky bit 标记日志不完整(写者在更新 PCR 与追加记录之间死掉),照常加载但相关 PCR 校验会失败**(:1222-1227)。

特殊语义与自校验:

- StartupLocality 伪事件(17 字节)存入 `startup_locality`(:986-997),最终成为 **PCR 0 初始值的最低字节**;PCR 1-16/23 初值全零,PCR 17-22(DRTM)全 0xFF(:1360-1388)。
- 每算法顺序与头部不符时逐一搜索配对(某些 Hyper-V 固件,:1030-1038)。
- 记录统一为 `EventLogRecord`(pcrlock.c:172-201):pcr 或 nv_index 二选一(:175-176);固件 vs userspace 事件由 `firmware_event_type`/`userspace_event_type` 区分(:203-204)。
- sd-stub 的 EV_IPL 事件只在 PCR 11/12/13 上被认领(:508-527):

```c
// pcrlock.c:508-527(event_log_record_is_stub,有删节)
/* Recognizes the special EV_IPL events systemd-stub generates. … */
if (rec->firmware_event_type != EV_IPL)
        return false; …
if (!IN_SET(rec->pcr,
            TPM2_PCR_KERNEL_BOOT,        /* 11 */
            TPM2_PCR_KERNEL_CONFIG,      /* 12 */
            TPM2_PCR_SYSEXTS))           /* 13 */
        return false;
```

- EV_IPL 负载是 UTF-16 段名,但哈希按 UTF-8+NUL 计,故验证提供"替身哈希"二次尝试(:1518-1528、1555-1559)。
- 自校验:对含原始负载的事件重算哈希比对——固件侧严格类型(EV_EFI_ACTION/GPT/VARIABLE_BOOT2/…)必须命中,否则标 `EVENT_PAYLOAD_VALID_NO`(:1489-1496、1561-1567);userspace 侧对 content.string 字段哈希比对(:1593-1613)。
- 整树重放出"计算值"(从初值逐记录 extend,:1390-1461),与 TPM 实读的"观测值"比对(:1322-1358;比对函数 :2343-2353)。
- 主算法选择:有 SHA256 用 SHA256,否则取 id 最大者(:2533-2554)。`log`/`cel` 动词分别输出人读表格与 TCG CEL-JSON(:2604-2646、2719-2754;CEL 编码 :2648-2717)。

## 五、组件库:把未知固件变成可枚举变体

- 三层数据结构:Component → Variant → Records(pcrlock.c:220-235);组件文件是 **JSON(非 YAML)**,`sd_json_parse_file` 解析(:1768-1774),格式为 TCG CEL 子集(`{"pcr":…,"digests":[{hashAlg,digest}…]}`,:2899 注释)。
- 加载:搜索 `/etc、/run、/var/lib、/usr/local/lib、/usr/lib` 下的 `pcrlock.d`(:1892-1897);`X.pcrlock.d/` 目录是组件、每文件一变体(:1831-1883),单个 `X.pcrlock` 是单变体组件(:1737-1829)。
- **匹配算法**是"变体记录在日志中的子序列匹配",递归回溯(pcrlock.c:1972-2014):

```c
// pcrlock.c:1989-2011(event_log_match_component_variant,有删节)
if (j == variant->n_records)
        return true;                                  /* 变体全部命中 */
if (!event_log_record_equal(el->records[i], variant->records[j]))
        return event_log_match_component_variant(el, i + 1, variant, j, …); /* 日志前移 */
r = event_log_match_component_variant(el, i + 1, variant, j + 1, assign); /* 双双前移 */ …
if (assign) { …
        /* (Note we allow multiple components and variants to take ownership of the same record!) */
        el->records[i]->mapped[el->records[i]->n_mapped++] = variant; }
```

- 记录相等只比主算法的 digest(:1711-1735)。
- 空组件被剔除,否则会把合法策略集清零(:1919-1942);某 PCR 存在未认领记录则 `fully_recognized=false`(:1944-1970)。
- `--location=START[:END]` 窗口外的组件缺失不算错(:2083-2107);缺省窗口 `760-` 到 `940-`(:5511-5521)——**预测默认只覆盖 userspace 相位词区间**。
- 固件侧组件(240-620 号)的变体来自 `systemd-pcrlock lock-*` 写进 `/var/lib/pcrlock.d/…generated.pcrlock` 的快照(路径常量 :113-124)。

## 六、预测与 make-policy:PolicyPCR + PolicyOR → NV index

**预测**(`predict` 动词,pcrlock.c:3479-3508):

- 默认掩码 `DEFAULT_PCR_MASK` 覆盖 PCR 0,1,2,3,4,5,7,11,13,14,15,**刻意排除 PCR 12**:

```c
// pcrlock.c:128-140(DEFAULT_PCR_MASK,有删节)
#define DEFAULT_PCR_MASK                                     \
        ((UINT32_C(1) << TPM2_PCR_PLATFORM_CODE) | …         \
         (UINT32_C(1) << TPM2_PCR_SECURE_BOOT_POLICY) |      \
         (UINT32_C(1) << TPM2_PCR_KERNEL_BOOT) |             \
         /* Note: we do not add PCR12/TPM2_PCR_KERNEL_CONFIG here, since our pcrlock policy ends up in there, and this would hence result in a conceptual loop */ \
         (UINT32_C(1) << TPM2_PCR_SYSEXTS) | …)
```

- 先 `reduce_to_safe_pcrs` 按三条件剔除不可信 PCR(:3102-3110):计算值≠观测值、日志含未识别测量、日志缺已知组件;`--strict` 下任何剔除升级为失败(:3140-3159)。
- 然后按组件序做 **DFS 组合枚举**(:3443-3477、3266-3343):每组件取一变体,复制父状态、对每个 bank extend(:3200-3264,缺 bank 即作废该哈希 :3221-3229),到尾部登记结果。
- 相同结果经 OrderedSet 去重(:3178-3180);组合总数 = 各组件变体数连乘,带 SSIZE_MAX 溢出检查(:3345-3361)。

**make-policy** 把预测折叠成一条策略(pcrlock.c:3632-4058):

- 折叠规则在 `tpm2_calculate_policy_super_pcr`(tpm2-util.c:9684-9781):只有单一允许值的 PCR 全部并进一条 PolicyPCR;有 2-8 个变体的 PCR,各变体从公共前缀演化出一条 PolicyPCR 再 PolicyOR 合并;**超 8 个变体直接 E2BIG**(:9742)。
- 硬性前置:TPM 必须支持 PolicyAuthorizeNV 命令与 SHA-256(pcrlock.c:3732-3735)。
- 策略写入 NV index(define :3915-3922;write :3962-3969);NV 写权限由 PIN 保护,PIN 转 HMAC 密钥走 PolicySigned(:3891-3893)。
- PIN 本身又被 AES-GCM **封闭到同一 NV 策略之下**(:3974-4000)——作者自注 "we dogfood 🌭 🐶 hard"(:3647-3649):更新策略必须先让旧策略通过。
- 用旧策略解封 PIN 时若 PCR 中途变化得到 -ESTALE,最多重试 16 次(:3836-3877)。
- 与旧策略等价则跳过(:3719-3724);v257 及更早误把 `--pcrlock=` 当策略路径,仍回退(:3690-3698)。

```c
// pcrlock.c:4021-4031(策略 JSON 的全部字段)
r = sd_json_buildo(&new_configuration_json,
                   SD_JSON_BUILD_PAIR_STRING("pcrBank", …),
                   SD_JSON_BUILD_PAIR_VARIANT("pcrValues", new_prediction_json),
                   SD_JSON_BUILD_PAIR_INTEGER("nvIndex", nv_index),
                   JSON_BUILD_PAIR_IOVEC_BASE64("nvHandle", &nv_blob),
                   JSON_BUILD_PAIR_IOVEC_BASE64("nvPublic", &nv_public_blob),
                   JSON_BUILD_PAIR_IOVEC_BASE64("srkHandle", &srk_blob),
                   JSON_BUILD_PAIR_IOVEC_BASE64("pinPublic", &pin_public),
                   JSON_BUILD_PAIR_IOVEC_BASE64("pinPrivate", &pin_private));
```

- 产物三份:策略 JSON 写 `/var/lib/systemd/pcrlock.json`(initrd 中为 `/run/...`,:4040);同一 JSON 经 `encrypt_credential`(**TPM 掩码为 0**)写成 ESP 上 `pcrlock.<entry-token>.cred` 引导凭据(:3554、3604-3624);NV index 内容在 TPM 里。
- Varlink 侧 `OnCompletedUpdate` 在 sysupdate 完成后无条件重算策略,且校验调用方为 root(:5734-5753);CLI 侧 `make-policy` 无变化时返回 NOP(:4060-4070;Varlink 报 NoChange :5644)。

## 七、lock-* 动词族与 cryptenroll 的消费

**lock- \* 家族**为各组件生成变体文件(pcrlock.c:4279 起的 "Protections" 组):

- `lock-firmware-code/-config`:从当前日志取 PCR 0/2(或 1/3)全部事件 + PCR 4(或 5)上**分隔符之前**的事件,切成 early/late 两个 .pcrlock(:4294-4310、4346-4396)。
- 分隔符边界兼容两种固件习惯:EV_SEPARATOR 或 "Calling EFI Application from Boot Option" 动作(:4359-4373);代码里留有 FIXME 要求预校验分隔符恰好出现一次(:4343-4344)。
- `lock-secureboot-policy` 不看日志,直接从 EFI 变量(SecureBoot/PK/KEK/db/dbx/dbt/dbr)合成 PCR 7 记录,缺库按空库测量(:4443-4513,变量表 :4448-4456)。
- `lock-secureboot-authority` 摘取 EV_EFI_VARIABLE_AUTHORITY 记录,并强制 PCR 7 记录有序、无重复、authority 在变量之后(:4575-4643)。
- `lock-gpt` 重构固件对 GPT 的测量写法(GPT 头 + 条目数 + 非零条目)进 PCR 5(:4736-4848)。
- `lock-uki`:整体 pe_hash 生成 PCR 4 记录,再对每个 `unified_section_measure` 的段生成与 measure 完全同构的两条 PCR 11 记录——`hash(段名+NUL)` 与段内容哈希(:5060-5074;测量谓词 uki.h:29-33,排除 .pcrsig)。
- 其余:machine-id / root+var 文件系统 → PCR 15(:5094、5178),kernel-cmdline(UTF-16 编码)与 initrd → PCR 9(:5245-5250、5276),`lock-pe` 缺省 PCR 4(:4929-4930),`lock-raw` 必须显式 `--pcr`(:5309-5310)。

**cryptenroll 消费侧**(衔接卷三 15 章,此处只展开登记端的 NV 语义):

- `--tpm2-pcrlock=` 指定策略文件(cryptenroll.c:697-702);未指定则在 `/run/systemd`、`/var/lib/systemd` 自动搜索 `pcrlock.json`(cryptenroll.c:804-812;搜索函数 tpm2-util.c:9932-9943)。
- 注册时只加载策略并置 `TPM2_FLAGS_USE_PCRLOCK`(cryptenroll-tpm2.c:407-415)。
- 密封策略里 `tpm2_calculate_policy_authorize_nv` **仅钉住 NV public(即 NV index 的名字),不含预测值本身**(tpm2-util.c:5733-5737)——所以 pcrlock 更新=重写 NV 内容,旧 LUKS2 token 无需改动即可继续工作。

```c
// tpm2-util.c:5733-5745(密封策略中的 pcrlock 分支)
if (pcrlock_policy) {
        …
        r = tpm2_calculate_policy_authorize_nv(&nv_public, digest);
        if (r < 0)
                return r;
}
```

- 运行期解锁会话现场执行 `tpm2_policy_super_pcr` + `tpm2_policy_authorize_nv`(tpm2-util.c:5788-5810)。
- 签名 PCR(PolicyAuthorize)与 pcrlock(PolicyAuthorizeNV)语义上不可并入一条策略;两者并用时把 FDE 密钥**分片(sharding)**分别锁到两条策略(cryptenroll-tpm2.c:475-506;同样断言 tpm2-util.c:5704-5706)。

## 八、纠偏、数据流与蒸馏

### 8.1 纠偏(以本 commit 源码为准,5 条)

1. **文件名纠偏**:measure 的源码是 `src/measure/measure-tool.c`(1110 行),仓库内不存在 `measure.c`;`src/pcrlock/` 下除 5817 行的 pcrlock.c 外只有 169 行的 pcrlock-firmware.c 和 pcrlock.d 组件库,**没有独立的"yml 解析"文件**——组件文件是 JSON(.pcrlock),解析用 sd_json_parse_file(pcrlock.c:1768-1774)。
2. **签名对象纠偏**:measure 的 `sig` 签的不是 PCR 预期值本身,而是 PolicyPCR 策略摘要+policyRef 的串接(TBS,measure-tool.c:1012-1013、tpm2-util.c:6936-6945),且摘要恒用 SHA256(:1020-1021),与所选 bank 无关。
3. **测量输入纠偏**:`.pcrsig` 永不进 PCR 11(measure-tool.c:256、uki.h:18 "This is not measured actually"、uki.h:29-33);`.pcrpkey` 会进(measure-tool.c:257-258)。段处理次序按枚举定义序而非 PE 布局序(uki.h:8-10),空段整体跳过且与 stub 行为对齐(measure-tool.c:628-629)。
4. **"lock-fast" 不存在**:pcrlock 的锁定/解除是 `lock-firmware-code/-config`、`lock-secureboot-policy/-authority`、`lock-gpt/-pe/-uki/-machine-id/-file-system/-kernel-cmdline/-kernel-initrd/-raw` 及对应 unlock 动词(pcrlock.c:4399-5326);源码中 "fast" 仅出现在 stdin 快路径注释里(:4877)。策略"轮换"的实现是重写 NV index 内容,消费端只钉 NV index(tpm2-util.c:5733-5737),没有独立 fast 通道。
5. **预测范围纠偏**:默认掩码不含 PCR 12(概念自指,pcrlock.c:137);默认 `--location` 窗口 760-940 只覆盖 userspace 相位段(:5511-5521),固件组件靠 /var/lib 下的 generated.pcrlock 变体参与预测(:113-124);每 PCR 变体上限 8,源于 PolicyOR 分支限制(tpm2-util.c:9742)。

### 8.2 数据流 ASCII 图

```
          systemd-measure(sign)(构建期,纯软件模拟,不触 TPM)     systemd-pcrlock(make-policy)(运行期)
 ┌─────────────────────────────────────────────┐     ┌──────────────────────────────────────────────────┐
 │ UKI 各段文件 --linux= --osrel= --cmdline= …  │     │ 固件 TCG log(binary_bios_measurements,           │
 │  (.pcrpkey 参与;.pcrsig 永不参与)           │     │   pcrlock-firmware.c 校验 "Spec ID Event03")      │
 │ bank=SHA1/256/384/512(缺省全开)            │     │ userspace log(tpm2-measure.log,0x1E 分隔 JSON)  │
 │ phase=enter-initrd/…(缺省硬编码 4 个)      │     │ + /etc|/usr/lib/pcrlock.d 组件库 + /var/lib 变体  │
 └──────────────────┬──────────────────────────┘     └──────────────────┬───────────────────────────────┘
                    │ 逐段:extend(H(段名+NUL)) → extend(H(段内容))     │ 日志重放校验 + 组件变体子序列匹配(递归)
                    │ 相位:逐词 extend(H(word))                         │ reduce_to_safe_pcrs(三条件剔除 PCR)
                    ▼                                                   ▼
          PCR11 预期值(每 bank 一份)                  Tpm2PCRPrediction(每 PCR 一组允许值,OrderedSet 去重)
                    │ tpm2_calculate_policy_pcr                          │ 单值→1 条 PolicyPCR;多变体→≤8 条 PolicyPCR→PolicyOR
                    ▼                                                   ▼
            策略摘要 "pol"                                 super PCR policy digest ──写入──▶ TPM NV index
                    │ +policyRef → TBS →(SHA256 摘要)私钥签名 → "sig"    │(PIN→HMAC 密钥→PolicySigned;PIN 亦封于本策略)
                    ▼                                                   ▼
      ukify 拼接为 .pcrsig 嵌入 UKI(ukify.py:742、812)  /var/lib/systemd/pcrlock.json + ESP pcrlock.<token>.cred
                    │                                                   │
                    └───── cryptenroll --tpm2-public-key(卷三)──┬──────┴── cryptenroll --tpm2-pcrlock
                                  LUKS2 密钥分片 sharding(PolicyAuthorize 与 PolicyAuthorizeNV 不可共存)
```

### 8.3 设计动机(≥5 条)

1. **构建期离线计算**:measure 全程软件模拟 extend,除 `--current` 外不接触 TPM(measure-tool.c:542-577),签名可在无 TPM 的构建机完成;`policy-digest` 输出 tbs 供 HSM 离线签(:1049)。
2. **相位窗口复用**:save/restore 让 N 个相位共享一次内核测量(measure-tool.c:815-817、865-866),复杂度从 O(N×段) 降为 O(段+N×词)。
3. **签策略而非签值**:绑定 PolicyPCR 摘要使验证方获得"值域"语义;pol/tbs/sig 字段分离允许离线签名与密钥轮换(:1044-1050)。
4. **组件库把混沌变有限**:固件/配置不可预测,但把每种可能枚举成变体后,未来状态是有限组合,策略可用 PolicyOR 封闭表达(pcrlock.c:3635-3639)。
5. **NV index 间接层**:LUKS2 token 只钉 NV public(tpm2-util.c:5733-5737),组件更新后重写 NV 内容即完成策略轮换,无需重新注册加密卷(pcrlock.c:3639-3643)。
6. **安全自动降级**:reduce_to_safe_pcrs 宁可放弃保护也不锁到可疑状态(pcrlock.c:3102-3110),`--strict` 才把降级当错误(:3140-3159)。
7. **自举闭环(dogfood)**:恢复 PIN 封闭在同一 NV 策略下(pcrlock.c:3647-3649),策略更新必须经旧策略授权,攻击者无法在绕过当前 PCR 状态的情况下改写策略。

### 8.4 FAQ 候选(10 条)

1. measure 输出 JSON 里的 `pol` 是什么?——该相位单条 PolicyPCR 表达式的策略摘要(measure-tool.c:1048)。
2. `sig` 的私钥签的具体字节是什么?——PolicyPCR 摘要与 policyRef nonce 的串接(tpm2-util.c:6936-6945),摘要固定 SHA256(measure-tool.c:1020-1021)。
3. `.pcrsig` 段会被测进 PCR 11 吗?——不会,三处源码一致排除(measure-tool.c:256、uki.h:18、uki.h:31)。
4. 空段(如空 .splash)怎么处理?——跳过不测,并注明与 sd-stub 行为一致(measure-tool.c:628-629)。
5. pcrlock 读哪些日志?——固件 binary_bios_measurements 与 userspace tpm2-measure.log 两路合并(tpm2-util.c:8445-8451、pcrlock.c:1306-1320)。
6. PCR 17-22 的初值是什么?——全 0xFF(DRTM);PCR 0 初值末字节为 StartupLocality,其余全零(pcrlock.c:1369-1383)。
7. 组件组合爆炸怎么办?——连乘有 SSIZE_MAX 溢出检查(pcrlock.c:3355-3356),策略侧每 PCR 最多 8 个 PolicyOR 分支(tpm2-util.c:9742)。
8. 升级内核/固件后旧 LUKS2 pcrlock token 会失效吗?——不会,cryptenroll 只钉 NV index,make-policy 重写 NV 内容即完成切换(tpm2-util.c:5733-5737、pcrlock.c:3962-3969)。
9. pcrlock.json 是机密吗?——不是,SRK/NV 已被它钉住、预测数据必须过 NV 策略才有用,官方注释明言"数据不敏感"(pcrlock.c:3650-3655)。
10. 忘了恢复 PIN 还有救吗?——`--recovery-pin=show` 首次生成时显示、`query` 由用户提供(pcrlock.c:3766-3809),PIN 亦可用旧策略自身解封(:3836-3877)。

### 8.5 深挖方向(5 条)

1. sd-stub 实际测量路径与本报告模拟逻辑的对账:EV_IPL 负载为 UTF-16 段名而哈希按 UTF-8+NUL(pcrlock.c:1518-1528 的"替身哈希"正是为此),可在 `src/boot/efi` 源头核对。
2. ukify.py 的 `call_systemd_measure`/`combine_signatures` 全流程(ukify.py:742、812-830):profile UKI 下分段测量与 `.pcrsig` 合并策略。
3. `Tpm2PCRPrediction` 的 JSON 序列化与相等判定(tpm2-util.h:269-286、tpm2-util.c:9529):如何忽略变体路径只看 digest。
4. 启动侧相位词触发点:哪些 unit 在何时调用 pcrextend 把 enter-initrd/ready 等词扩入 PCR 11(pcrextend.c:189-194;units 未在本 sparse 检出中,未核实)。
5. `io.systemd.PCRLock` Varlink 接口与 sysupdate 的闭环(pcrlock.c:5734-5753):更新完成后策略重算的失败处理与 `NoChange` 语义(:5644)。

### 8.6 正文蒸馏要点(12 条核心论断)

1. systemd-measure 的真身是 `src/measure/measure-tool.c`(1110 行),无 measure.c;动词 status/calculate/sign/policy-digest(measure-tool.c:387、788、1078-1088)。
2. PCR 11 段测量次序由 `UnifiedSection` 枚举死锁("PLEASE DO NOT REORDER",uki.h:8-10):.linux→.osrel→.cmdline→.initrd→.ucode→.splash→.dtb→.uname→.sbat→(.pcrsig 跳过)→.pcrpkey→.profile→…(uki.c:14-27)。
3. 每段做两次 extend:先 `hash(段名+NUL)` 再 `hash(段内容)`(measure-tool.c:639-655);extend 本体是 `H(旧值‖新数据)`(:525-531);空段跳过与 stub 对齐(:628-629)。
4. `.pcrsig` 永不参与测量(measure-tool.c:256、uki.h:29-33);缺省 bank 为 SHA1/256/384/512(:284-289),缺省相位硬编码 4 个(:299-307)。
5. `sig` 签的是"PolicyPCR 摘要‖policyRef"(measure-tool.c:1012-1013、tpm2-util.c:6936-6945),摘要恒 SHA256 与 bank 无关(measure-tool.c:1020-1021);`policy-digest` 输出 tbs 支持离线签(:1049)。
6. pcrlock 的日志双源:固件 TCG log 头验签 "Spec ID Event03"(pcrlock-firmware.c:120-123),StartupLocality 落为 PCR 0 初值末字节(pcrlock.c:986-997、1371-1374);userspace 日志 0x1E 分隔、sticky bit 标记不完整(pcrlock.c:1241、1222-1227)。
7. 组件库是 JSON 组件(.pcrlock/.pcrlock.d)而非 YAML,三层结构 Component→Variant→Records(pcrlock.c:220-235、1892-1897);匹配是仅看主算法 digest 的子序列递归回溯,允许多重认领(:1972-2014、2005-2011、1711-1735)。
8. 预测 = 组件变体笛卡尔积的 DFS,每 PCR 结果经 OrderedSet 去重(pcrlock.c:3266-3343、3178-3180),默认掩码刻意排除 PCR 12 防自指(:128-140);不可信 PCR 按"值不符/含未识别测量/缺已知组件"三条件剔除(:3102-3110)。
9. make-policy 的折叠规则:单值 PCR 并入一条 PolicyPCR,多变体 PCR 各自 PolicyPCR 后 PolicyOR,上限 8 分支(tpm2-util.c:9684-9781、9742);硬性要求 PolicyAuthorizeNV+SHA-256(pcrlock.c:3732-3735)。
10. 策略写入随机分配的 NV index(:3915-3922、3962-3969),写权限由 PIN 经 PolicySigned 保护,PIN 自身也被封到同一策略下实现"更新须过旧策略"的自举(:3891-3893、3974-4000、3647-3649)。
11. 产物三份:非敏感策略 JSON(/var/lib/systemd/pcrlock.json,initrd 为 /run)、ESP 上加密引导凭据 pcrlock.<entry-token>.cred、NV index 内容(:4021-4043、3554、3604-3624、3650-3655);sysupdate 完成回调触发重算(:5734-5753)。
12. cryptenroll 消费端只以 PolicyAuthorizeNV 钉住 NV public(tpm2-util.c:5733-5737),故"更新组件→make-policy 重写 NV→旧 LUKS2 token 不变即换策略";签名 PCR 与 pcrlock 不可并入一条策略,须密钥分片(cryptenroll-tpm2.c:475-506)。
