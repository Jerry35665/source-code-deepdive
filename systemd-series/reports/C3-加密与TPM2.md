# 报告 C3 · 加密存储与 TPM2(systemd 卷三)

> 基线:1f66b524(nspawn: align config `PrivateUsersOwnership` default with CLI)。一句话总结:systemd 把 FDE 解锁做成"多来源密钥的级联尝试 + LUKS2 JSON token 元数据"体系,TPM2 侧以"主机随机密钥 + TPM 内 SRK/primary 密钥封装 + 可组合的 PCR 策略(明文 PCR / 签名 PCR / pcrlock / PIN)分片密封"为核心,v258 起注册端已不再默认绑定 PCR 7。

## 一、模块地图:加密存储子系统的文件构成

- `src/cryptsetup/cryptsetup.c`(2789 行):systemd-cryptsetup 主工具,attach/detach 两个动词(cryptsetup.c:145-149、2487-2488、2734-2735)。
- `src/cryptsetup/cryptsetup-generator.c`(946 行):读 /etc/crypttab(cryptsetup-generator.c:848-851)与 `luks.*` 内核参数(:663-682),生成 `systemd-cryptsetup@.service` 与符号链接。
- `src/cryptenroll/`:systemd-cryptenroll,按注册类型分文件(password/recovery/pkcs11/fido2/tpm2/wipe/list/varlink/interactive)。
- `src/shared/cryptsetup-util.*`:对 libcryptsetup 的 dlopen 封装(cryptsetup-util.h:25-50 起的 DLSYM_PROTOTYPE 列表;`crypt_set_keyring_to_link` 兼容 2.7 前头文件,:18-27)。
- `src/shared/cryptsetup-tpm2.c`:`acquire_tpm2_key`(:67)与 `find_tpm2_auto_data`(:292),被 cryptsetup 与 cryptenroll 共用。
- `src/shared/tpm2-util.c/h`(12150/653 行):TPM2 ESYS 全量封装,含 `tpm2_seal`(:6952)/`tpm2_unseal`(:7174)与 LUKS2 JSON 编解码(:11259、:11407)。
- `src/cryptsetup/cryptsetup-tokens/`:编译为 libcryptsetup 外挂 token 插件(,tpm2/fido2/pkcs11 三个 .so)。
- 周边配角:`src/measure/measure-tool.c`(systemd-measure,"为 PCR 11 预计算预期值",measure-tool.c:31-32)、`src/pcrlock/pcrlock.c`(5817 行,systemd-pcrlock,基于事件日志预测未来 PCR 状态,pcrlock.c:107-109、3266)。

```c
// src/cryptsetup/cryptsetup.c:145-149
COMMAND(
        "systemd-cryptsetup\0",
        "Attach or detach an encrypted block device.",
        .man_pages = "systemd-cryptsetup(8)\0",
);
```

## 二、systemd-cryptsetup 的 attach 路径:一次密钥级联尝试

`attach` 命令签名是 `attach VOLUME SOURCE-DEVICE [KEY-FILE] [CONFIG]`(cryptsetup.c:2487),第 4 个参数就是 crypttab 行的选项列,由 `parse_crypt_config`→`parse_one_option` 逐词解析(cryptsetup.c:651-689、177-649)。`noauto/auto/nofail/fail/_netdev/keyfile-timeout` 在本工具之外处理(cryptsetup.c:184-188);未知选项仅告警忽略(:645-646)。

TPM2/FIDO2/PKCS#11 相关选项全部在这一个解析函数里,摘录(完整表 177-649 行):

```c
// src/cryptsetup/cryptsetup.c:470-490(节选)
} else if ((val = startswith(option, "tpm2-device="))) {
        if (streq(val, "auto")) {
                arg_tpm2_device = mfree(arg_tpm2_device);
                arg_tpm2_device_auto = true;
        } else { … }
} else if ((val = startswith(option, "tpm2-pcrs="))) {
        r = tpm2_parse_pcr_argument_to_mask(val, &arg_tpm2_pcr_mask);
        if (r < 0)
                return r;
} …
```

值得注意的默认值:`arg_tries = 3`(cryptsetup.c:85)、`arg_token_timeout_usec = 30s`(:120)、`arg_tpm2_pcr_mask = UINT32_MAX` 即"未指定"(:116)、FIDO2 手工参数沿用 systemd 248 时代的 PIN/UP 行为(:110-113)。

真正的解锁是一个 **try 循环**(cryptsetup.c:2620-2726),源码注释明确顺序(cryptsetup.c:2630-2636):

```c
// src/cryptsetup/cryptsetup.c:2630-2636
/* When we were able to acquire multiple keys, let's always process them in this order:
 *
 *    1. A key acquired via PKCS#11 or FIDO2 token, or TPM2 chip
 *    2. The configured or discovered key, of which both are exclusive and optional
 *    3. The empty password, in case arg_try_empty_password is set
 *    4. We enquire the user for a password
 */
```

关键机制,每条均有行号:
- token 类型判定优先级 TPM2 > FIDO2 > PKCS#11,互斥取先(determine_token_type,cryptsetup.c:2449-2458)。
- 显式密钥文件读不到时,自动在 `/etc/cryptsetup-keys.d`、`/run/cryptsetup-keys.d` 搜 `<卷名>.key`(discover_key,cryptsetup.c:2460-2485,搜索逻辑在 cryptsetup-keyfile.c:8-43)。
- 每轮失败(-EAGAIN)只作废一个输入,逐级降级:TPM2 → FIDO2 → PKCS#11 → 自动发现密钥 → key_file → 密码(cryptsetup.c:2692-2723);默认 3 次尝试(:85),耗尽报 EPERM(:2728-2729)。
- 空 password 由 `try-empty-password=` 控制,每轮只试一次(cryptsetup.c:2652-2655)。
- 密码是"最后手段",且先经 `check_registered_passwords` 判断卷上还有没有可输入的东西:它枚举 LUKS2 token,被 systemd-* token 引用的 slot 不算"常规口令 slot",`systemd-recovery` token 记为恢复密钥(cryptsetup.c:801-891,token 类型集合在 :844)。
- `headless` 选项直接禁用交互提问,返回 ENOPKG(cryptsetup.c:910-911);PKCS#11 模式强制禁用口令缓存,显式开启即报错(cryptsetup.c:677-686)。
- 进程一开始 `mlockall` 防密钥换出("A delicious drop of snake oil",cryptsetup.c:2525-2526);激活 flags 恒置 `CRYPT_ACTIVATE_SERIALIZE_MEMORY_HARD_PBKDF` 防 OOM(cryptsetup.c:2429-2431)。
- `keyfile-erase=` 只擦除命令行显式给出的密钥文件,自动发现的是共享资源不归本卷所有(cryptsetup.c:2528-2532,删除用 `unlinkat_deallocate(UNLINK_ERASE)`,:2436-2447)。

TCRYPT(VeraCrypt/TrueCrypt)与 token 互斥,直接 EAGAIN(cryptsetup.c:1220-1223)。若同时要求测量(`tpm2-measure-pcr=`),`use_token_plugins()` 返回 false,强制走本进程手工路径以便拿到 volume key(cryptsetup.c:1401-1413)。

## 三、TPM2 解锁:token 发现、PCR 选择与策略会话

解锁入口分两条路:有 libcryptsetup 插件时先 `crypt_activate_by_token_pin("systemd-tpm2")` 把活儿交给插件,参数包是 `search_pcr_mask/device/signature_path/pcrlock_path`(cryptsetup.c:1906-1937);无插件时在本进程遍历 token:`find_tpm2_auto_data` 按 `search_pcr_mask` 过滤、从 `start_token` 起逐个解析 systemd-tpm2 token(cryptsetup-tpm2.c:292-354),拿全 blob/policy_hash/salt/srk/pcrlock_nv 后交给 `acquire_tpm2_key`(cryptsetup.c:2040-2101)。token 与当前开机状态不匹配的错误组是 `-EREMCHG/-ENOANO/-EPERM/-ENOSTR/-EREMOTE/-EADDRNOTAVAIL`,此时 `token++` 换下一个继续试(tpm2-util.h:58-60;cryptsetup.c:2107-2111)。

PCR 策略的"计算侧"与"会话侧"是两套对称实现:`tpm2_calculate_sealing_policy`(离线算 policy digest)按固定次序叠加策略——签名公钥→PolicyAuthorize、pcrlock→PolicyAuthorizeNV、PCR 值→PolicyPCR、PIN→auth value(tpm2-util.c:5697-5735);`tpm2_build_sealing_policy`(:5755)则在真实 policy session 里调 ESYS 命令得到同样的 digest(Esys_PolicyAuthorize :5679、Esys_PolicyAuthorizeNV :5264、Esys_PolicyOR :5318、Esys_PolicyPCR :5467)。签名 PCR 与 pcrlock 无法在同一条策略里组合(PolicyAuthorize 与 PolicyAuthorizeNV 冲突),systemd 的解法是**分片**:一个密钥拆两片,片 0 绑签名 PCR、片 1 绑 pcrlock(cryptenroll-tpm2.c:474-510;tpm2-util.c:5702-5705、7230-7233)。

```c
// src/shared/tpm2-util.c:5707-5735(节选)
        /* The combination of signed PCR policies and pcrlock is not supported (because we cannot combine
         * PolicyAuthorize and PolicyAuthorizeNV in one policy). … */
        if (public) {
                …
                r = tpm2_calculate_policy_authorize(public, &policy_ref, digest);
        if (pcrlock_policy) {
                …
                r = tpm2_calculate_policy_authorize_nv(&nv_public, digest);
        if (n_pcr_values > 0) {
                r = tpm2_calculate_policy_pcr(pcr_values, n_pcr_values, digest);
        if (use_pin) {
                r = tpm2_calculate_policy_auth_value(digest);
```

解锁前还有一道廉价的健全性检查:`tpm2_build_sealing_policy` 先 `tpm2_pcr_mask_good` 确认所选 PCR 在当前 bank 上确实初始化过,没初始化只打 debug 不硬失败(tpm2-util.c:5773-5779;`tpm2_pcr_mask_good` 实现 :3927)。

PCR bank 与 PCR 编号的选择策略:
- bank 偏好 SHA256 > SHA384 > SHA512 > SHA1,优先读固件经 `LoaderTpm2ActivePcrBanks` EFI 变量上报的激活 bank,否则本地探测"≥24 个启用的寄存器且所选 PCR 已初始化"的 bank(tpm2-util.h:552-554;tpm2-util.c:4108-4160,:4131-4133)。
- 旧 token 未存 bank 时按 legacy 规则(仅 SHA256/SHA1)反推(tpm2-util.c:7235-7241;bank 字段自 v250 才可选,tpm2-util.c:11456-11457)。
- PCR 编号语义定义在 `src/fundamental/tpm2-pcr.h`:PCR7=SecureBoot 策略(:17)、PCR11=sd-stub 内核镜像(:28)、PCR12=内核命令行/凭证(:31)、PCR15=根卷密钥(:38)。
- **v258 分水岭**:注册端不再默认绑 PCR 7,只在与旧版解锁兼容时保留(tpm2-util.h:519-524);`--tpm2-public-key=auto` 时 public-key PCR 默认取 PCR 11(cryptenroll.c:813-817);什么限制都不给则注册"空策略",仅打提示(cryptenroll.c:818-825)。解锁端若手动指定密钥数据而未给 PCR 掩码,才回落 `TPM2_PCR_MASK_DEFAULT_LEGACY`(=PCR7,cryptsetup.c:1969)。

```c
// src/shared/tpm2-util.h:519-524(有删节,前半为注释)
/* Before v258 we used to bind to PCR 7 by default at various places if no explicit PCR mask was set. With
 * v258 we stopped doing that (…), but when unlocking to maintain compatibility when no mask is specified we
 * still need to default to PCR 7. */
#define TPM2_PCR_INDEX_DEFAULT_LEGACY TPM2_PCR_SECURE_BOOT_POLICY
#define TPM2_PCR_MASK_DEFAULT_LEGACY INDEX_TO_MASK(uint32_t, TPM2_PCR_INDEX_DEFAULT_LEGACY)
```

## 四、tpm2_seal / tpm2_unseal:封装密钥的数据流

`tpm2_seal` 的自述(tpm2-util.c:6970-6981):TPM 内有跨启动稳定的 seed,派生出确定性 primary 密钥(SRK 或 legacy 模板);主机用内核 RNG 随机生成"真正要注册进 LUKS2 的密钥",送入 TPM 用 primary 密钥加密(受 PCR policy session 约束),再把密文 blob 序列化进 LUKS2 JSON。sealed 对象类型是 **KEYEDHASH**(HMAC 模板,只当二进制载体用,tpm2-util.c:7000-7005);带 PIN 时启 DA 防爆破,不带 PIN 则置 NODA(tpm2-util.c:6990-6995)。优先用 SRK(handle 0x81000001,tpm2-util.h:28)并序列化 srk 随 token 保存,否则退回 legacy primary(ECC 优先,RSA 兜底,tpm2-util.c:7028-7036、7069-7085、7157)。

```
        systemd-cryptenroll(注册)                      systemd-cryptsetup attach(解锁)
  ────────────────────────────────────────       ─────────────────────────────────────────────
   volume key VK(对称,LUKS slot 里的)              LUKS2 header → systemd-tpm2 token JSON
        │                                              (tpm2-blob / tpm2-pcrs / tpm2-pcr-bank /
   secret = 主机RNG,n_shards×32B                        tpm2-policy-hash / tpm2_srk …)
        │                                                   │
        ▼                                                   ▼
   TPM2: seed(固定) ──派生──▶ SRK/primary          tpm2_srk blob 反序列化恢复 primary
        │                                            (无 srk 则用 legacy 模板重建, tpm2-util.c:7243-7266)
   policy session: PolicyPCR                          │
   [+PolicyAuthorize 签名PCR]                         ▼
   [+PolicyAuthorizeNV pcrlock]                 policy session 重建同样策略链,
   [+authValue(PIN)]                            逐分片比对 tpm2-policy-hash(:7369-7386)
        │                                             │
        ▼                                             ▼
   TPM2_Create(KEYEDHASH, 内含 secret 分片)      TPM2_Load(blob 还原 KEYEDHASH, PIN 绑定会话
        │ 防总线窃听                                   :7330-7340) → TPM2_Unseal(:7399-7411)
        ▼                                             │
   blob = marshal(public+private)                     ▼
   ── 写入 LUKS2 JSON token ──▶            secret 分片拼接 → base64 → 作为 passphrase
   VK 经 crypt_keyslot_add_by_volume_key        经 crypt_volume_key_get 解出 VK,
   写入 LUKS2 keyslot(cryptenroll-tpm2.c:616)   crypt_activate_by_volume_key 激活 DM 卷
```

`tpm2_unseal` 是全文件最精心的函数:文档注释罗列 11 种错误码及其语义,其中 `EREMCHG/ENOANO/EUCLEAN/EPERM` 四个都可能是"PCR 状态不匹配"(tpm2-util.c:7191-7207);上层把它们归并为"换下一个 token"或"落回传统解锁"两组(tpm2-util.h:55-60)。可靠性细节逐条:
- PCR 在策略会话中途变化会以 `TPM2_RC_PCR_CHANGED`/`-EUCLEAN` 出现,外层整体重试,上限 30 次(RETRY_UNSEAL_MAX,tpm2-util.c:7172、7406-7409)。
- blob 带 seed 字段说明是离线算出/复制来的密封对象,需先 `tpm2_import` 装入 TPM(tpm2-util.c:7297-7313)。
- PIN 通过 `tpm2_set_auth` 绑定会话密钥,注释直言这是防"总线中间人伪造 TPM 后转发真实 TPM"的对策(:7324-7330)。
- 已知 policy hash 时先在主机侧比对,失配即 -EPERM 短路,不必等 TPM 拒绝;此处还有 RSA 默认指数置 0 的重试 workaround(bug #30546,:7369-7386)。
- 成功的 secret 分片按序拼接还原(tpm2-util.c:7415 的 `iovec_append`)。
- 解锁成功后再过一层合成:Argon2id 注册的卷用 `HKDF(key1, unsealed)` 得最终密钥,否则直接 base64 当 passphrase(cryptenroll-tpm2.c:599-610)。

```c
// src/shared/tpm2-util.c:7191-7207(节选)
/* Returns the following errors:
 *   -EREMOTE         → blob is from a different TPM
 *   -EUCLEAN         → PCR state doesn't match expectations
 *   -EPERM           → stored policy does not match TPM state
 *   …
 * Of these all four of EREMCHG, ENOANO, EUCLEAN, EPERM can all mean that PCR state is not matching
 * expectations. */
```

## 五、cryptenroll:五类注册与各自的 LUKS2 slot 操作

类型清单与 token 映射(cryptenroll.c:135-150):password/recovery/pkcs11/fido2/tpm2 五种;**password 类型没有 LUKS2 token**,recovery/pkcs11/fido2/tpm2 分别对应 `systemd-recovery/systemd-pkcs11/systemd-fido2/systemd-tpm2` token。公共前置:先解锁卷拿 volume key(UNLOCK_EMPTY/PASSWORD/KEYFILE/FIDO2/TPM2/HEADLESS 六种方式,cryptenroll.c:906-941;`--unlock-headless` 会先试 TPM2 再试空密码,:933-941),然后按类型分发(:1021-1034)。所有类型最终都是 `crypt_keyslot_add_by_volume_key` 写 slot:recovery 用 `make_recovery_key` 生成的 64 位 modhex 串(每 8 字符一个连字符,recovery-key.c:90-105;token JSON 见 cryptenroll-recovery.c:84-93),fido2 用 `fido2_generate_hmac_hash`(默认 COSE_ES256,cryptenroll-fido2.c:117-148),pkcs11 用解密出的密钥(cryptenroll-pkcs11.c:88)。

TPM2 注册(`enroll_tpm2`,cryptenroll-tpm2.c:299-658)流程最复杂:
1. PIN 模式分两档:Argon2id 档把 PIN 拆分为 key1(主机侧)+ b64 PIN(TPM 侧)防止 PIN 明文进 TPM 日志(350-363);无 OpenSSL 3.2 时降级为"PBKDF2 加盐 + base64"直通档(365-376,降级判定 cryptenroll.c:827-832);盐值用后即擦(:318-325)。
2. PCR 值不全就从 TPM 现读补齐(:436-440);bank 从字面 PCR 值推导,或按 pubkey 掩码选最佳 bank(:446-472)。
3. 计算 policy digest(可 2 片),`tpm2_seal` 或离线 `tpm2_calculate_seal`(指定 `--tpm2-device-key` 时,:516-547)。
4. **去重**:同 policy hash 已注册则直接返回既有 keyslot 不动(:557-569);同 hash 带 PIN 重注册则顺带计划抹旧 slot(:562-564)。
5. **回读校验**:能验证时立即 unseal 一次,与 secret 不等即 ENOTRECOVERABLE(:572-597)。
6. 用 minimal PBKDF 把 base64 后的 secret 注册成 keyslot,再 `tpm2_make_luks2_json` + `cryptsetup_add_token_json` 写入 token(:612-649)。

```c
// src/cryptenroll/cryptenroll.c:135-150(节选)
static const char* const enroll_type_table[_ENROLL_TYPE_MAX] = {
        [ENROLL_PASSWORD] = "password",
        [ENROLL_RECOVERY] = "recovery",
        [ENROLL_PKCS11]   = "pkcs11",
        [ENROLL_FIDO2]    = "fido2",
        [ENROLL_TPM2]     = "tpm2",
};
static const char *const luks2_token_type_table[_ENROLL_TYPE_MAX] = {
        /* ENROLL_PASSWORD has no entry here, as slots of this type do not have a token in the LUKS2 header */
        [ENROLL_RECOVERY] = "systemd-recovery", …
```

## 六、LUKS2 token 机制:systemd-tpm2 的字段与外挂插件

token JSON 由 `tpm2_make_luks2_json` 生成(tpm2-util.c:11259-11348),解析在 `tpm2_parse_luks2_json`(:11407)。字段分两代:连字符老字段(`tpm2-blob`/`tpm2-pcrs`/`tpm2-pcr-bank`/`tpm2-primary-alg`/`tpm2-policy-hash`/`tpm2-pin`)与下划线新字段(`tpm2_pcrlock`/`tpm2_pubkey_pcrs`/`tpm2_pubkey`/`tpm2_pubkey_ref`/`tpm2_salt`/`tpm2_srk`/`tpm2_pcrlock_nv`/`tpm2_argon2id_{memcost,iterations,lanes}`)。**没有叫 "pcrbank" 的字段,正确名称是 `tpm2-pcr-bank`**;命名注释直言"We made the mistake of using '-'"(tpm2-util.c:11317-11319)。`tpm2-blob`/`tpm2-policy-hash` 既可为单串(旧版兼容)也可为数组(分片),由 `tpm2_parse_shard_array` 统一消化(:11350-11405、11365-11368)。

```c
// src/shared/tpm2-util.c:11321-11333(节选)
r = sd_json_buildo(
                &v,
                SD_JSON_BUILD_PAIR("type", JSON_BUILD_CONST_STRING("systemd-tpm2")),
                SD_JSON_BUILD_PAIR("keyslots", SD_JSON_BUILD_ARRAY(SD_JSON_BUILD_STRING(keyslot_as_string))),
                SD_JSON_BUILD_PAIR_VARIANT("tpm2-blob", bj),
                SD_JSON_BUILD_PAIR_VARIANT("tpm2-pcrs", hmj),
                SD_JSON_BUILD_PAIR_CONDITION(…, "tpm2-pcr-bank", …),
                SD_JSON_BUILD_PAIR_CONDITION(…, "tpm2-primary-alg", …),
                SD_JSON_BUILD_PAIR_VARIANT("tpm2-policy-hash", phj),
                SD_JSON_BUILD_PAIR_CONDITION(…, "tpm2-pin", …), …
```

libcryptsetup ≥2.x 可加载外部 token 插件:本仓库提供 `cryptsetup-token-systemd-tpm2/fido2/pkcs11.c` 三个插件,`crypt_activate_by_token_pin` 经 `crypt_token_set_external_path` 调进插件(cryptsetup-util.h:24-27;开关 `use_token_plugins()`,cryptsetup.c:1401-1433,可用环境变量 `SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE` 关闭,:1423-1427)。插件把"token 不匹配开机状态"的内部错误重映射为 -EPERM,好让 libcryptsetup 的 CRYPT_ANY_TOKEN 循环继续遍历(cryptsetup-tokens/cryptsetup-token-systemd-tpm2.c:31-42)。无插件时 systemd-cryptsetup 用同样的 `acquire_tpm2_key`/`find_tpm2_auto_data` 手工复刻插件逻辑(cryptsetup.c:2019-2120)。

## 七、generator、measure/pcrlock 一瞥,以及与 homed 的衔接

cryptsetup-generator 把每条 crypttab 行生成为 `systemd-cryptsetup@<卷名>.service`,挂到 `cryptsetup.target`(网络卷是 `remote-cryptsetup.target`)的 wants/requires,并让 `dev-mapper-<x>.device` requires 它;非 nofail 卷再加 `JobTimeoutSec=infinity` drop-in 防止设备超时拖死启动(cryptsetup-generator.c:548-570)。

```c
// src/cryptsetup/cryptsetup-generator.c:553-570(节选)
        r = generator_add_symlink(arg_dest,
                                  netdev ? "remote-cryptsetup.target" : "cryptsetup.target",
                                  nofail ? "wants" : "requires", n);
        dmname = strjoina("dev-mapper-", e, ".device");
        r = generator_add_symlink(arg_dest, dmname, "requires", n);
        if (!noauto && !nofail) {
                r = write_drop_in(arg_dest, dmname, 40, "device-timeout",
                                  … "JobTimeoutSec=infinity\n");
```

此外:keydev=/headerdev= 会在运行时生成辅助 .mount 单元先挂载密钥/头文件(cryptsetup-generator.c:103 起的 `generate_device_mount`);`luks.uuid=`/`luks.name=`/`luks.options=`/`luks.crypttab=` 等内核参数在 :663-682 解析(:885 起 `add_proc_cmdline_devices` 落地);GPT 可发现分区规范中的卷名自动隐含 `x-initrd.attach`(:291-296)。systemd-measure 是"为 PCR 11 预计算预期值"的 UKI 签名工具(measure-tool.c:31-32);systemd-pcrlock 从固件/启动事件日志**预测**未来 PCR 状态并把卷锁到预测集合上(经 NV index + PolicyAuthorizeNV,pcrlock.c:87、3266 起),C 端在 cryptsetup 侧以 `tpm2-pcrlock=` 选项与 `TPM2_FLAGS_USE_PCRLOCK` 消费(cryptsetup.c:509-517;cryptenroll-tpm2.c:408-417)。

与 homed 的衔接一句话:homed 与 cryptsetup/cryptenroll 不共享注册路径——cryptenroll 遇 `systemd-homed` token 直接拒绝操作("please use homectl to enroll tokens",cryptenroll.c:840-860),而 cryptsetup 解锁侧与 homed 的兼容仅靠一条约定:**token/TPM2 解出的二进制密钥统一 base64 后再当 passphrase 用**(cryptsetup.c:1660、1833-1839、2163;cryptenroll-tpm2.c:607)。

```c
// src/cryptenroll/cryptenroll.c:840-858(节选)
static int check_for_homed(struct crypt_device *cd) {
        /* Politely refuse operating on homed volumes. The enrolled tokens for the user record and the LUKS2
         * volume should not get out of sync. */
        for (int token = 0; token < sym_crypt_token_max(CRYPT_LUKS2); token++) {
                r = cryptsetup_get_token_as_json(cd, token, "systemd-homed", NULL);
                …
                return log_error_errno(SYNTHETIC_ERRNO(EHOSTDOWN),
                                       "LUKS2 volume is managed by systemd-homed, please use homectl to enroll tokens.");
```

测量(补一句):`tpm2-measure-pcr=` 把解锁后的 volume key 以 `HMAC(volume_key, prefix)` 形式扩展进 PCR(默认布尔 true 对应 PCR 15,cryptsetup.c:519-536、1027-1033),且受 `efi_measured_os()` 门控——内核 stub 没做 OS 测量就不做用户态测量(:1015-1021);`tpm2-measure-bank=` 已废弃无效(:538-542)。

## 八、纠偏、设计动机与深挖

**纠偏(以本 commit 源码为准)**:
1. "TPM2 加密默认绑 PCR 7"已过时:v258 起注册端默认不再绑 PCR 7(空策略或 PCR 11,见第三节),PCR 7 仅是解锁端兼容掩码(tpm2-util.h:519-524;cryptenroll.c:813-825;cryptsetup.c:1969)。
2. LUKS2 TPM2 token 无 "pcrbank" 字段,实际是 `tpm2-pcr-bank`,且新字段已改下划线命名(tpm2-util.c:11325-11340)。
3. attach 的 try 循环没有独立 "recovery 密钥"分支:恢复密钥就是普通 passphrase,recovery 之名只是 `check_registered_passwords` 从 `systemd-recovery` token 推断出的提示文案(cryptsetup.c:844-848、2659-2671)。
4. "TPM2 解锁失败会卡死启动"不成立:任何 TPM2 错误都被改写成 -EAGAIN 非致命降级,最终落到口令路径(cryptsetup.c:1997-2000、2116-2119);token 不匹配还会自动换下一个 token(:2107-2111)。
5. `tpm2-measure-bank=` 已废弃无效果,且测量内容不是裸哈希而是 HMAC(volume_key, prefix)(cryptsetup.c:538-542、1031-1033)。
6. 密码类型注册不产生任何 LUKS2 token; crypttab 选项中不存在 "dstc" 之类的缩写(全量解析表在 cryptsetup.c:177-649)。
7. systemd-cryptenroll 不是 homed 的注册前端,反而显式拒绝 homed 卷(cryptenroll.c:840-860)。

**设计动机**(≥5):
1. 元数据进 LUKS2 header:token 自描述,卷可跨机器迁移,无需系统级配置数据库(tpm2-util.c:11321-11324 的 type/keyslots 结构)。
2. 解锁永远有退路:token→密钥文件→空密码→口令的级联与错误码非致命化,保证"安全加固不产生砖机"(cryptsetup.c:2630-2636、1997-2000)。
3. 主机生成密钥 + TPM 封装,而非 TPM 生成:密钥可用普通 bit 位备份/恢复进 LUKS2,TPM 只提供"绑定"(tpm2-util.c:6970-6981)。
4. 策略可组合又不可全组合时,用密钥分片代替策略或运算(签名 PCR × pcrlock)(cryptenroll-tpm2.c:474-477)。
5. 离线可算与在线可验成对出现:calculate_sealing_policy 与 build_sealing_policy 双实现,注册端立即 unseal 回读验证(cryptenroll-tpm2.c:572-597)。
6. 每个 token 携带自身策略哈希,解锁端逐个比对、失败换下一个,实现平滑的系统升级/回滚(cryptsetup.c:2023-2025、2107-2111)。
7. PIN 的双重防护:DA 锁定防 TPM 在线爆破,Argon2id 拆分防 PIN 堆栈/日志泄漏(tpm2-util.c:6990-6995;cryptenroll-tpm2.c:350-363)。

**FAQ 候选(每条一句话)**:
1. systemd-cryptsetup 与 cryptsetup(命令行)什么关系?——它不格式化卷,只在启动时 attach/detach 已有 LUKS/tcrypt/bitlk/plain 卷,libcryptsetup 经 dlopen 调用(cryptsetup.c:2763-2787、cryptsetup-util.h)。
2. 没插 TPM 的机器上 crypttab 写了 tpm2-device=auto 会怎样?——非致命:等待 `tpmrm` udev 设备超时后 EAGAIN 降级(cryptsetup.c:2122-2147)。
3. TPM2 解锁的 PIN 在哪里验证?——作为 sealed 对象的 authValue 在 TPM 内验证,失败错误组是 -EACCES/-ENOLCK(cryptsetup.c:2102-2103)。
4. 为什么解出的密钥要 base64?——与 homed 及 UNIX 口令哈希等"NUL 结尾字符串"接口兼容(cryptsetup.c:1833-1839)。
5. `tpm2-pcrs=` 写法支持什么?——经 `tpm2_parse_pcr_argument_to_mask` 解析成位掩码(cryptsetup.c:483-487)。
6. 插件与手工路径如何选择?——`use_token_plugins()`:测量/fixate/FIDO2 手工参数时禁用插件(cryptsetup.c:1401-1413)。
7. recovery key 长什么样?——64 个 modhex 字符、每 8 字符一个连字符,共 79 字符(recovery-key.c:90-105)。
8. 同一组 PCR 重复 enroll 会怎样?——同 policy hash 直接复用既有 keyslot,只在带 PIN 时重注册以更新 PIN(cryptenroll-tpm2.c:557-569)。
9. 启动时 PIN 从哪来?——先环境变量 `PIN`(插件路径)或 keyring/credential(cryptsetup.tpm2-pin),再交互询问(cryptsetup.c:1482-1494;cryptsetup-tpm2.c:22-62)。
10. unseal 时 PCR 抖动怎么办?——TPM2_RC_PCR_CHANGED 触发整体重试,上限 30 次(tpm2-util.c:7172、7406-7409)。

**深挖方向(5)**:
1. `tpm2_get_or_create_srk` 的 SRK 模板协商与 NV 持久化路径(tpm2-util.c:2013 起),对照 legacy primary 模板的兼容矩阵。
2. pcrlock 的事件日志解析与 PCR 预测算法(pcrlock.c:3162-3400),及其 NV 索引策略与 `PolicyAuthorizeNV` 的配合。
3. cryptenroll 的 Varlink 接口(io.systemd.cryptenroll.policy)与 sysupdate/credential 体系的联动。
4. Argon2id 拆分密钥的内存开销自适应调节逻辑(cryptenroll.c:1128-1194)。
5. FIDO2/PKCS#11 与 TPM2 路径的错误码/超时行为差异(token-timeout=30s,cryptsetup.c:120)。

## 正文蒸馏要点

1. systemd-cryptsetup 的解锁是密钥来源级联:token(TPM2>FIDO2>PKCS#11)→ 自动发现/配置密钥文件 → 空密码 → 交互口令,每轮 -EAGAIN 只降级一项(cryptsetup.c:2449-2458、2630-2636、2692-2723)。
2. crypttab 选项经 `parse_one_option` 单函数解析,`noauto/nofail/_netdev/keyfile-timeout` 等在本工具外处理,未知选项告警忽略(cryptsetup.c:177-649、184-188、645-646)。
3. TPM2 封装本质:主机 RNG 密钥被 TPM 内 SRK/primary 密钥以 KEYEDHASH 对象加密,密文 blob 存 LUKS2 JSON;TPM 从不生成也不泄漏该密钥(tpm2-util.c:6970-7005)。
4. policy digest 双实现:离线 `tpm2_calculate_sealing_policy` 与在线 `tpm2_build_sealing_policy` 按同一顺序叠加 PolicyAuthorize/PolicyAuthorizeNV/PolicyPCR/authValue(tpm2-util.c:5697-5735、5755)。
5. v258 起 TPM2 注册不再默认绑 PCR 7:自动签名 PCR 策略用 PCR 11,无限制则是空策略+提示;PCR 7 只是解锁端 legacy 掩码(cryptenroll.c:813-825;tpm2-util.h:519-524;cryptsetup.c:1969)。
6. PCR bank 优先读 `LoaderTpm2ActivePcrBanks` EFI 变量,偏好 SHA256>SHA384>SHA512>SHA1,旧 token 未存 bank 时按 SHA256/SHA1 反推(tpm2-util.c:4108-4160;tpm2-util.h:552;tpm2-util.c:7235-7241)。
7. LUKS2 systemd-tpm2 token 字段:老连字符系(`tpm2-blob`/`tpm2-pcrs`/`tpm2-pcr-bank`/`tpm2-policy-hash`/`tpm2-pin`)+新下划线系(`tpm2_srk`/`tpm2_salt`/`tpm2_pubkey`/`tpm2_pcrlock_nv`/`tpm2_argon2id_*`),blob/policy-hash 支持分片数组(tpm2-util.c:11321-11340、11365-11368)。
8. cryptenroll 五类注册共用"先解锁取 volume key,再 `crypt_keyslot_add_by_volume_key`"骨架;password 无 token,recovery 是 64 modhex 字符恢复密钥(cryptenroll.c:135-150、906-941、1021-1034;recovery-key.c:90-105)。
9. TPM2 注册含去重(同 policy hash 复用 slot)与回读校验(unseal 比对,失配 ENOTRECOVERABLE),PIN 走 Argon2id 拆分或 PBKDF2 加盐(cryptenroll-tpm2.c:557-597、350-376)。
10. TPM2 解锁失败永不致命:错误统一改写 -EAGAIN 降级到下一来源;token 状态失配组(6 种 errno)触发 token++ 续试;PCR 中途抖动重试上限 30 次(cryptsetup.c:1997-2000、2107-2111;tpm2-util.h:55-60;tpm2-util.c:7172)。
11. libcryptsetup 外挂 token 插件与内置手工路径逻辑同源,共享 `find_tpm2_auto_data`/`acquire_tpm2_key`;插件把失配错误重映射 -EPERM 让 CRYPT_ANY_TOKEN 循环继续(cryptsetup.c:2019-2120;cryptsetup-tokens/cryptsetup-token-systemd-tpm2.c:31-42)。
12. homed 衔接:仅靠 base64-as-passphrase 约定兼容,cryptenroll 遇 homed 卷直接拒绝;卷密钥测量走 PCR 15(NvPCR 记 keyslot),受内核 stub 测量门控(cryptsetup.c:1833-1839、1015-1033;cryptenroll.c:840-860)。
