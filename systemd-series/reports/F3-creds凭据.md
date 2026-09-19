# 报告 F3 · systemd-creds 与凭据体系(systemd 卷三)

> 基线:1f66b524(systemd 主线)。一句话:凭据体系 = PID1 启动期把内核命令行/固件/boot loader 传入的凭据落进 `/run/credentials/@system|@encrypted` 两个信任桶,再按单元配置(SetCredential=/LoadCredential=/ImportCredential=)解密、以只读 noswap 文件系统挂进服务沙箱,配合 `systemd-creds` 工具提供 AES256-GCM 加密(host key / TPM2 HMAC / null 三类密钥)与 Varlink IPC 解密。

## 一、PID1 启动期导入:四个来源与两个信任桶

`src/core/import-creds.c` 的头注释明说它做四件事(import-creds.c:39-67):从 sd-boot 的 `/.extra/credentials/`、`/proc/cmdline`、qemu fw_cfg、SMBIOS OEM 串收集凭据;其中来自 ESP 的是"不可信"来源,进 `@encrypted` 桶;命令行/固件来源进 `@system` 桶(import-creds.c:44-50)。两个桶的固定路径定义于 creds-util.h:33-34:

```c
/* Where system creds have been passed */
#define SYSTEM_CREDENTIALS_DIRECTORY "/run/credentials/@system"
#define ENCRYPTED_SYSTEM_CREDENTIALS_DIRECTORY "/run/credentials/@encrypted"
```
(creds-util.h:33-34)

调用点在 main.c:2689(`(void) import_credentials();`),且受 `systemd.import_credentials=` 内核命令行开关控制,缺省为开(import-creds.c:937-943)。

【纠偏 1】内核命令行上**不存在** `systemd.credentials=` 选项;真实选项是 `systemd.set_credential=<名>:<值>` 与 `systemd.set_credential_binary=<名>:<base64>`,由 proc_cmdline_callback 解析后写入 `@system` 桶(import-creds.c:338-341, 362-372)。另有 `systemd.credentials_boot_policy=` 控制解密端对 null key 的接受策略(creds-util.c:1275-1281)。

```c
if (proc_cmdline_key_streq(key, "systemd.set_credential"))
        base64 = false;
else if (proc_cmdline_key_streq(key, "systemd.set_credential_binary"))
        base64 = true;
else
        return 0;

colon = value ? strchr(value, ':') : NULL;
```
(import-creds.c:338-345)

每个来源写入前都过同一套闸门:名必须 `credential_name_valid`、单凭据与累计体积都不得超 `CREDENTIAL_SIZE_MAX`/`CREDENTIALS_TOTAL_SIZE_MAX`(credential_size_ok,import-creds.c:133-149),文件以 `O_EXCL|0400` 独占创建、重名直接忽略(import-creds.c:115-131)——即"先到先得"在系统导入层就已成立。

目录本身不是普通目录:非加密桶尝试挂载一个专属文件系统,优先级为"支持 noswap 的 tmpfs(内核 ≥6.3)→ ramfs → 普通 tmpfs",并带 `nodev/noexec/nosuid/nosymfollow` 且 mode=0700(mount-util.c:1984-1999, 2008);导入完成后重挂为只读并 setenv `$CREDENTIALS_DIRECTORY`/`$ENCRYPTED_CREDENTIALS_DIRECTORY`(import-creds.c:157-166)。SMBIOS OEM 串只认 `io.systemd.credential:` 与 `io.systemd.credential.binary:` 两个前缀(import-creds.c:545-548);机密虚拟化下默认不信任固件通道,唯一例外是 Intel TDX(SMBIOS 被 TDVF 测量进 RTMR0)(import-creds.c:625-633)。initrd 侧的 `/run/credentials/@initrd` 在 initrd→host 切换后被搬空并 rmdir(import-creds.c:658-745)。导入还会消费 `vmm.notify_socket` 凭据并转设 `$NOTIFY_SOCKET`(import-creds.c:831-846)。

日志里两个桶分别叫 "regular credentials" 与 "untrusted credentials"(import-creds.c:888-894)——这是理解整套安全模型的关键命名:PID1 自己能读的只是"未加密但来自可信通道"的凭据;ESP 来的密文必须再经 `LoadCredentialEncrypted=` 解密认证。

## 二、creds-util:加密格式、密钥与名称规则

**名称规则**:凭据名必须同时是合法文件名与合法 fd 名——`filename_is_valid(s) && fdname_is_valid(s)`(creds-util.c:49-53),长度上限 `CREDENTIAL_NAME_MAX = FDNAME_MAX = 255`(creds-util.h:9;fd-util.h:11)。glob 仅允许**尾部一个** `*`,禁用 `?`/`[`/`]`(creds-util.c:55-91)。单凭据 ≤1MiB,单服务总量同上限,密文 ≤1MiB+128KiB(creds-util.h:12-21)。

**密钥来源**(creds-util.c:681-708 注释):对称密钥 = SHA256(以下之一或拼接)——① host key(`/var/lib/systemd/credential.secret`,4KB 随机数 + 哈希后的 machine-id 头,模式强制 0400,换机器即删)(creds-util.c:422-432, 543-546, 608-612);② TPM2 对 nonce 求得的 HMAC 密钥(seal/导出存于文件内);③ 两者拼接;④ 定长空 "null" 密钥。用 host+TPM2 时密文里再多一个 per-UID "scoped" 变体:把 UID/用户名/machine-id 结构 HMAC 进密钥(creds-util.c:821-869)。

**文件格式**(全部小端、8 字节对齐;creds-util.c:711-764):

```c
struct _packed_ encrypted_credential_header {
        sd_id128_t id;              /* 哪种密钥类型(见 ID 表) */
        le32_t key_size, block_size, iv_size, tag_size;
        uint8_t iv[];               /* 后接 NUL 至 8 字节边界 */
};
struct _packed_ tpm2_credential_header {   /* 仅 TPM2 密钥类型 */
        le64_t pcr_mask; le16_t pcr_bank; le16_t primary_alg;
        le32_t blob_size, policy_hash_size;
        uint8_t policy_hash_and_blob[];
};
/* tpm2_public_key_credential_header / tpm2_pinned_srk_credential_header / scoped_credential_header 类似 */
struct _packed_ metadata_credential_header {  /* 这一段是密文! */
        le64_t timestamp, not_after; le32_t name_size; char name[];
};
```
(creds-util.c:711-756,节选)

即:明文头(id+尺寸+IV)→[TPM2 头/公钥头/ pinned SRK 头/scoped 头]→**密文**(metadata 头+载荷)→ GCM tag;头部整体作为 AAD,"整份文件要么是 AAD、要么是密文、要么是 tag,无未保护数据"(creds-util.c:706-708)。真实密钥类型共 16 个 ID(含 `_SCOPED`/`_WITH_PK`/`_PINNED_SRK` 组合),另有 5 个永不上盘的 `_CRED_AUTO*` 内部 ID(creds-util.h:86-128)。

解密端校验:密文里的名字与目标名不符则拒绝(可用 `$SYSTEMD_CREDENTIAL_VALIDATE_NAME` 显式放行),`not_after` 过期同理(`$SYSTEMD_CREDENTIAL_VALIDATE_NOT_AFTER`)(creds-util.c:1662-1694)。核心比对逻辑:

```c
if (validate_name && !streq(embedded_name, validate_name)) {
        r = secure_getenv_bool("SYSTEMD_CREDENTIAL_VALIDATE_NAME");
        ...
        if (r != 0)
                return log_error_errno(SYNTHETIC_ERRNO(EDESTADDRREQ),
                        "Embedded credential name '%s' does not match filename '%s', refusing.",
                        embedded_name, validate_name);
}
```
(creds-util.c:1672-1680)

null key 解密在允许时也要 log_warning(creds-util.c:1568-1569);是否接受 null key 由 boot policy 决定:strict/tofu/relaxed/off,RELAXED 为缺省(creds-util.h:69-76;creds-util.c:391-413, 1272-1281)。

```c
case CRED_BOOT_TOFU:    return first_boot || !have_tpm2;
case CRED_BOOT_RELAXED: return !secure_boot || !have_tpm2;
case CRED_BOOT_OFF:     return true;
```
(creds-util.c:401-408)

密钥重推导在解密侧与加密侧完全对称:先按头部 ID 取 host secret / TPM2 unseal 出的 HMAC 密钥,SHA256 合并;scoped 类型再叠一层 UID HMAC(creds-util.c:1562-1576)。GCM tag 校验失败一律返回 `-EBADMSG`(Varlink 侧映射为 `io.systemd.Credentials.BadFormat`),因为常见错误(错钥匙/文件损坏)下 OpenSSL 错误队列往往为空,不能依赖 errno 翻译(creds-util.c:1636-1640)。

## 三、systemd-creds 工具(src/creds/creds.c)

子命令清单:`list`(默认子命令,creds.c:315)、`cat`(creds.c:476)、`encrypt`(creds.c:564)、`decrypt`(creds.c:674)、`setup`(生成 host key,creds.c:758)、`has-tpm2`(隐藏,重定向到 systemd-analyze,creds.c:774-777)。

【纠偏 2】工具**没有 `print` 子命令**——读凭据输出内容的命令是 `cat`;`--pretty` 只是 encrypt 输出格式的修饰(把 base64 排成可直接粘贴的 `SetCredentialEncrypted=` 行,creds.c:646-662)。`list` 同时枚举加密/未加密两桶,非 `--system` 时依赖 `$CREDENTIALS_DIRECTORY`(creds.c:334-339)。

`--with-key=` 的取值与真实 ID 映射(creds.c:114-142):

```
auto / auto-initrd / host / tpm2 / tpm2-with-public-key /
host+tpm2 / tpm2+host / host+tpm2-with-public-key /
tpm2-with-public-key+host / null / tpm2-absent(遗留别名)
```
快捷键:`-H` = host,`-T` = `_CRED_AUTO_TPM2`(creds.c:897-904)。

【纠偏 3】`--with-key=tpm2` 实际写入的是 `CRED_AES256_GCM_BY_TPM2_HMAC_PINNED_SRK`(**pinned SRK** 变体,creds.c:134-139),而非裸 `CRED_AES256_GCM_BY_TPM2_HMAC`;`tpm2-absent` 是旧名,现等同于 `null`(creds.c:125, 141)。

encrypt 流程:读入(≤1MiB)→ 未指定 `--name=` 时以输出文件名作为嵌入名(否则告警,creds.c:593-604)→ root 直接调 `encrypt_credential_and_warn`,非 root 且非 null key 则走 polkit + Varlink IPC(creds.c:611-635)→ 结果 base64 后写盘(creds.c:639-667)。

```c
if (arg_pretty && !output_path && name) {
        ...
        j = strjoin("SetCredentialEncrypted=", escaped, ": \\\n        ",
                    indented, "\n");
```
(creds.c:646-657)

`decrypt` 同样支持文件/stdin 输入,密文侧上限为 `CREDENTIAL_ENCRYPTED_SIZE_MAX`(creds.c:690-696);`cat` 则按"未加密桶→加密桶"顺序各找一遍,命中加密桶后即时解密再输出,全程走 `erase_and_free` 擦除内存(creds.c:495-553)。`setup` 子命令即生成/补齐 host secret(creds.c:758-772)。工具依赖 libmount 与 OpenSSL(编不进则工具整体不构建),TPM2 支持为可选(creds/meson.build:3-17)。IPC 对端是 `/run/systemd/io.systemd.Credentials` 的 Varlink 服务(creds-util.c:1790-1797),由 systemd-creds 自身以 `--varlink`/socket 激活模式承担(`sd_varlink_invocation(SD_VARLINK_ALLOW_ACCEPT)` 自动识别,creds.c:1018-1021, 1405-1435;对应 socket 单元不在本次 sparse 检出内,未核实);polkit 动作 `io.systemd.credentials.encrypt/.decrypt`(io.systemd.credentials.policy:21, 31)。IPC 解密对非 root 客户端仅接受"新鲜"时间戳(±30s),超出即要求 polkit(creds.c:1024-1034, 1349-1365)。

## 四、单元级传递:三种设置与沙箱落位

三种设置在 gperf 中的定义(load-fragment-gperf.gperf.in:168-172),解析实现分别在 load-fragment.c:4705(Set/Encrypted)、4790(Load/Encrypted)、4863(Import)。语义差别:

- **SetCredential=名:值**:字面量内嵌(支持转义),`SetCredentialEncrypted=` 为其 base64 密文变体;仅在同名凭据尚未存在时生效(兜底/默认值)。
- **LoadCredential=名:路径**:路径可为绝对文件/目录(目录则递归导入,`/`→`_` 拼名)、可写 `AF_UNIX` socket(读流)、或裸凭据名(从上游凭据桶继承);找不到时非致命(若 Set 有同名兜底则静默)(exec-credential.c:720-733)。
- **ImportCredential=glob[:新前缀]**:按 glob 从 credstore/系统凭据桶批量导入并可选改名,glob 校验见 creds-util.c:55-91。

采集顺序固定:先 Load,再 Import(不覆盖已有),最后 Set(只补缺)。源码里的三段注释把次序与覆盖语义写得非常直白(exec-credential.c:826-828, 865-866, 902-903):

```c
/* First, load credentials off disk (or acquire via AF_UNIX socket) */
...
/* Next, look for system credentials and credentials in the credentials store.
 * Note that these do not override any credentials found earlier. */
...
/* Finally, we add in literally specified credentials. If the credentials
 * already exist, we'll not add them, so that they can act as a "default" ... */
```

写入目录时 `O_CREAT|O_EXCL` 0600、写完 fchmod 0400,再给服务 UID 加 ACL 读权限,ACL 不可用时回退 chown(exec-credential.c:426-449):

```c
fd = openat(dfd, id, O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC, 0600);
...
r = RET_NERRNO(fchmod(fd, 0400)); /* Take away "w" bit */
...
r = fd_add_uid_acl_permission(fd, uid, ACL_READ);
```
(exec-credential.c:426-439)

加密凭据在系统模式由 PID1 直连 TPM2 解密;但配置了 PrivateDevices/设备策略时改走 IPC(避免设备沙箱挡住 /dev/tpm)(exec-credential.c:470-508, 787-805, 1159)。

落位与沙箱:目标目录 `<runtime>/credentials/<unit>`(即 `/run/credentials/<unit>`,get_credential_directory,exec-credential.c:274)。有特权时先 `fsmount_credentials_fs()` 挂独立 noswap 文件系统、灌入凭据,再通过 `fsconfig(..., "ro") + FSCONFIG_CMD_RECONFIGURE` 把整个文件系统重配置为只读,最后 move_mount 到位(exec-credential.c:1054-1108);无特权回退为"临时 workspace 准备 + rename/RENAME_EXCHANGE 原子换入"的普通目录(exec-credential.c:952-1013)。进入服务 mount namespace 时:整个 `/run/credentials` 先垫一层只读 tmpfs(mode=0755),再把本单元目录以 **只读 bind** 覆盖(namespace.c:2973-3006);完全没有凭据的单元则直接挂 `MOUNT_INACCESSIBLE` 把 `/run/credentials` 整体遮蔽(namespace.c:3009-3020)。

```c
*me = (MountEntry) {
        .path_const = p->creds_path,
        .mode = MOUNT_BIND,
        .read_only = true,
        .source_const = p->creds_path,
};
```
(namespace.c:2998-3004)

服务进程拿到 `$CREDENTIALS_DIRECTORY=<…>/credentials/<unit>`(exec-invoke.c:2179-2186),PAM 会话分支亦同(exec-invoke.c:1088-1102)。

【纠偏 4】服务内**只会看到已解密的明文凭据**:服务侧读取原语 `read_credential()` 只查 `$CREDENTIALS_DIRECTORY`;`read_credential_with_decryption()` 是给 generators/PID1 用的"解密加强版",注释明说"services only receive decrypted credentials"(creds-util.c:190-200, 156-180)。

【纠偏 5】凭据不是"启动时挂一次就完事":`Service.RefreshOnReload=`(service.c:3345-3349 生效判断)触发 `service_enter_refresh_credentials`,fork `(sd-refresh-creds)` 助手执行 `unit_refresh_credentials`,必要时借助 namespace_fork 钻进主进程的 mount ns 用 `mount_exchange_graceful` 原子换新(exec-credential.c:1208-1262, 1172-1206;service.c:3368-3374)。

## 五、安全模型与生态衔接

- **信任二分**:@system(可信,明文直用)vs @encrypted(不可信,须再认证)是唯一的全局信任分界(import-creds.c:44-50;creds-util.h:33-34)。
- **credstore 搜索路径**:`LoadCredential` 相对名在 `$CREDENTIALS_DIRECTORY` + `/etc/credstore`、`/usr/lib/credstore` 等 CONF_PATHS 系列中查找;加密变体查 `credstore.encrypted`(sd-path.c:646-664, 368-389);安装时这两个 /etc 目录建为 0700(creds/meson.build:23-28)。
- **纵深**:文件系统层(noswap、ro、nodev/noexec/nosuid/nosymfollow,mount-util.c:1980-1984)、权限层(0400+ACL)、密码层(AES256-GCM 全文件 AAD)、时间层(not_after)、策略层(boot policy/ polkit)五层叠加。
- **nspawn 衔接**:`systemd-nspawn --set-credential=ID:VALUE --load-credential=ID:PATH` 在宿侧收集,进容器后走同一套单元凭据协议(nspawn.c:1341-1350;machine-credential.c:40-52)。
- **homed/系统初始化衔接**:凭据消费方不止服务——sysusers/firstboot 读 `passwd.hashed-password.<user>`/`passwd.plaintext-password.<user>`(creds-util.c:347-380;firstboot.c:936;sysusers.c:732);tmpfiles 支持 `L`/`C` 行从凭据取内容(tmpfiles.c:4702, 5209);udev 与 network generator 用 `pick_up_credentials` 把 `udev.rules.*`、`network.network.*` 等前缀凭据铺成配置(udevadm-control.c:237-243;network-generator-main.c:251-258)。homed 本体直接消费凭据的代码点在本次检出内未核实(src/home 下未见 read_credential 调用)。
- **cryptenroll 一句话**:`systemd-cryptenroll` 负责向 LUKS 卷登记 password/recovery-key/pkcs11/fido2/tpm2 五类密钥槽(cryptenroll.c:136-140),与凭据体系仅共享 TPM2/policy 底座(其 FIDO2 PIN 经 ask-password 凭据名 `cryptenroll.fido2-pin` 传递,cryptenroll-fido2.c:126),不属凭据数据面。

`pick_up_credentials` 的表驱动用法(creds-util.h:239-245 定义 `PickUpCredential{前缀,目标目录,后缀}`):

```c
const PickUpCredential table[] = {
        { "network.conf.",    context.networkd_conf_dropin_dir, ".conf"    },
        { "network.link.",    context.network_dir,              ".link"    },
        { "network.netdev.",  context.network_dir,              ".netdev"  },
        { "network.network.", context.network_dir,              ".network" },
};
RET_GATHER(ret, pick_up_credentials(table, ELEMENTSOF(table)));
```
(network-generator-main.c:251-258)

## 六、一条加密凭据的完整数据流(ASCII)

```
 [离线/别机] systemd-creds encrypt --with-key=host+tpm2 --name=myapp.token
        明文 ──AES256-GCM──▶ 密文(SHA256(host.secret+TPM HMAC) 为 key)
        │  头部=AAD│密文含 metadata(名字/not_after)│尾部=GCM tag
        ▼
   base64 文本 myapp.token  ──写入──▶ ESP/=/etc/credstore.encrypted/
        │                                   (不可信桶,@encrypted)
        ▼  (若经 UKI: sd-boot 拷入 initrd /.extra/credentials/)
 PID1 启动  import_credentials()  (main.c:2689)
        ├── /.extra/* ──▶ /run/credentials/@encrypted  (noswap fs, 后转 ro)
        └── setenv $ENCRYPTED_CREDENTIALS_DIRECTORY     (import-creds.c:151-169)
        ▼
 单元启动: SetCredentialEncrypted=myapp.token:<base64>
        exec_setup_credentials()  (exec-credential.c:1113)
        ├── maybe_decrypt_and_write_credential():root 直连 TPM2 解密
        │   (或 IPC→ io.systemd.Credentials;device 沙箱时强制 IPC)
        ├── 明文 0400+ACL 写入 workspace → rename/挂载为
        │   /run/credentials/<unit>  → 整 fs 重配置 ro
        ▼
 mount namespace:  /run/credentials (ro tmpfs 0755)
                   └── <unit> 以只读 bind 覆盖        (namespace.c:2998)
        + $CREDENTIALS_DIRECTORY=/run/credentials/<unit>
        ▼
 服务进程: read_credential("myapp.token")  → 明文字节
        (服务侧永不接触密文;creds-util.c:156-180)
```

## 七、设计动机与 FAQ 候选

**设计动机(为什么这样做):**

1. **以文件名/fd 名为凭据 ID**:凭据名同时满足 filename/fdname 规则(creds-util.c:50-52),一条路径贯穿"命令行→文件→挂载→fd 传递"所有通道,无需新 IPC 协议。
2. **RAM 中转、永不上盘**:明文凭据只存在于 noswap tmpfs/ramfs(mount-util.c:1987-1994),规避 swap/休眠泄露,且单元结束后 umount+rm_rf(exec-credential.c:311-315)。
3. **信任显式分桶**:@system/@encrypted 与 "regular/untrusted" 日志(import-creds.c:888-894)把"数据来自可信通道"与"数据可认证"分离,强迫用户对 ESP 来源凭据走解密认证路径。
4. **离线可加密、在线才可解**:TPM2 HMAC/policy 绑定 PCR,加密可在任意机器做(公钥/with-pk 变体),解密必须在本机 TPM 状态匹配时成立(creds-util.c:1517-1539)。
5. **服务零改动消费**:只读环境变量 `$CREDENTIALS_DIRECTORY` 即接入,不要求应用理解 TPM/policy;复杂度全部收敛在 PID1 与工具侧(exec-invoke.c:2179-2186)。
6. **原子性与最小暴露**:workspace+rename、挂载后立即 ro、无凭据单元遮蔽 `/run/credentials`(namespace.c:3009-3020),避免半初始化状态与他单元窥视。
7. **非 root 也能安全解密**:加解密经 Varlink IPC + polkit + 新鲜时间戳约束(creds.c:1349-1365),让用户级加密(per-UID scoped)不触碰 host secret。
8. **格式自描述**:密文头部携带密钥类型 ID 与各段尺寸,解密端用同一套 `CRED_KEY_*` 宏族做"按需解析"(TPM2 头/公钥头/SRK 头/scoped 头都是可选段,creds-util.h:130-229),一种文件格式兼容 16 种密钥策略。
9. **防"换机密钥"静默错配**:host secret 头部存哈希后的 machine-id,发现异机密钥即加锁删除重造(creds-util.c:422-432, 656-678);密文嵌入凭据名,落错文件名即拒收(creds-util.c:1672-1683)——用低成本校验消灭最常见的运维错误。

**FAQ 候选(每条一句话答案):**

1. 凭据名里能有哪些字符?——能做文件名且能做 fd 名的那些(无 `/`、非 `.`/`..`、≤255 字节),规则即 `credential_name_valid()`(creds-util.c:49-53)。
2. `systemd.set_credential=` 和 `LoadCredential=` 的数据最终都在哪?——前者在 `/run/credentials/@system`(系统桶),后者经 PID1 复制进 `/run/credentials/<unit>`(单元桶),二者都只读挂载。
3. 服务怎么读凭据?——`$CREDENTIALS_DIRECTORY/<名>` 读文件,或直接用 `read_credential()` 系列助手(creds-util.h:40-41)。
4. 加密凭据文件是二进制吗?——盘上是 Base64 文本,读入时 `READ_FULL_FILE_UNBASE64` 解码(creds-util.c:221-227)。
5. 没有 TPM2 的机器能加密吗?——能:host-only 或 null(null 无保密无认证,有 TPM+SecureBoot 时策略上拒收,creds-util.c:391-413)。
6. `LoadCredentialEncrypted=` 和 `ImportCredential=` 能混用吗?——能,Import 也分两轮扫 trusted 与 encrypted 搜索路径(exec-credential.c:868-899)。
7. 同名凭据谁赢?——采集顺序 Load→Import→Set 且后写不覆盖先写,先到先得(exec-credential.c:826-918);系统导入层同样 `O_EXCL` 忽略重名(import-creds.c:122-125)。
8. 服务需要自己访问 TPM2 吗?——不需要,PID1 在挂载前已解密;PrivateDevices/设备策略挡住 TPM 时自动改走 Varlink IPC(exec-credential.c:470-508, 787-805)。
9. 容器里怎么传?——nspawn 侧 `--set-credential/--load-credential` 收集,容器内 PID1 按同一协议挂载(nspawn.c:1341-1350)。
10. 凭据会不会被服务改写?——不会:文件 0400、目录 ACL 只读、整个文件系统 ro 重配置再 bind(exec-credential.c:434, 1081-1087;namespace.c:2998-3004)。
11. `systemd-creds list` 为何在服务里能看到、在裸 shell 里看不到?——非 `--system` 模式它只认 `$CREDENTIALS_DIRECTORY`,裸 shell 没设(creds.c:334-339)。

## 八、深挖方向与正文蒸馏要点

### 深挖方向(候选正文/后续卷)

1. `LoadCredential` 的 AF_UNIX 读流通道:`READ_FULL_FILE_CONNECT_SOCKET` 与自描述 bind 名 `@random/unit/<unit>/<id>` 的服务端协议(exec-credential.c:682-689)。
2. `unit_refresh_credentials` 的 mountns 钻取细节:namespace_fork_full + open_tree + mount_exchange_graceful 的原子换装(exec-credential.c:1233-1352)。
3. scoped( per-UID)凭据:`scoped_hash_data` 结构与 `mangle_uid_into_key` 的 HMAC 构造,以及 homed 场景的扩展预留(creds-util.c:758-773 注释)。
4. pcrlock/UKI 联动:`tpm2_with_public_key` 变体如何用 UKI 公钥固定 PCR 策略(tpm2_public_key_credential_header,creds-util.c:732-737;creds-util.c:1476-1506)。
5. Varlink 错误表 `credentials_varlink_error_by_errno` 与 `io.systemd.Credentials` 接口的完整 schema(varlink-io.systemd.Credentials.c:86;creds-util.c 尾部错误映射)。

### 正文蒸馏要点(结尾)

1. PID1 的 `import_credentials()`(main.c:2689)从命令行/固件/ESP/initrd 四通道导入,落 `/run/credentials/@system` 与 `/run/credentials/@encrypted` 两桶(creds-util.h:33-34),桶即信任边界:后者被日志直呼 "untrusted credentials"(import-creds.c:888-894)。
2. 【纠偏】内核命令行选项是 `systemd.set_credential[.binary]=名:值`,不是 `systemd.credentials=`;总开关是 `systemd.import_credentials=`(import-creds.c:338-341, 937)。
3. 系统桶所在文件系统按 "noswap tmpfs → ramfs → tmpfs" 优先级挂载,带 nodev/noexec/nosuid/nosymfollow,导入完成后立即只读化并 setenv(import-creds.c:151-169;mount-util.c:1984-1999)。
4. 凭据名 = 合法文件名 ∩ 合法 fd 名,≤255 字节;单凭据与单服务总量均 ≤1MiB(creds-util.c:49-53;creds-util.h:9-17)。
5. 加密 = AES256-GCM,密钥 = SHA256(host secret / TPM2 HMAC / 两者拼接 / null);host secret 在 `/var/lib/systemd/credential.secret`,0400 且与哈希 machine-id 绑定,异机即删(creds-util.c:681-708, 543-546, 656-678)。
6. 密文布局 = 明文头(类型 ID+IV)→ 可选 TPM2/公钥/pinned-SRK/scoped 头 → 密文(时间戳+名字+载荷)→ tag,头部全为 AAD,文件无未保护区(creds-util.c:706-756)。
7. 解密端强制校验嵌入名与 not_after,可用 `$SYSTEMD_CREDENTIAL_VALIDATE_NAME/_NOT_AFTER` 两个环境变量显式放行;null key 接受与否由 `systemd.credentials_boot_policy=`(strict/tofu/relaxed/off,缺省 relaxed)裁决(creds-util.c:1669-1702, 391-413, 1275)。
8. 【纠偏】systemd-creds 子命令为 list(默认)/cat/encrypt/decrypt/setup(+隐藏 has-tpm2),没有 `print`;`--with-key=tpm2` 实际是 pinned-SRK 变体,`tpm2-absent` 是 null 的遗留别名(creds.c:315, 476, 564, 674, 758, 774;134-142, 125)。
9. 非 root 的加解密走 `/run/systemd/io.systemd.Credentials` Varlink 服务(socket 激活自动识别),受 polkit `io.systemd.credentials.*` 与 ±30s 时间戳新鲜度约束(creds-util.c:1790-1797;creds.c:1018-1021, 1024-1034;policy:21, 31)。
10. 三种单元设置语义:Set=字面量兜底(可加密)、Load=文件/目录/socket/继承、Import=glob 批量改名;采集顺序 Load→Import→Set,先到先得(gperf:168-172;exec-credential.c:826-918)。
11. 单元凭据落位:优先独立 noswap fs 挂载后 fsconfig 整体转 ro,无特权回退 rename/RENAME_EXCHANGE;沙箱内 `/run/credentials` 垫 ro tmpfs、单元目录只读 bind、无凭据则 INACCESSIBLE 遮蔽(exec-credential.c:1054-1108, 952-1013;namespace.c:2973-3020)。
12. 【纠偏】服务内只见明文:服务侧 `read_credential()` 不做解密,`read_credential_with_decryption()` 仅供 generators/PID1;凭据可在 `RefreshOnReload` 时经 `(sd-creds-ns)` 助手跨 mountns 原子刷新(creds-util.c:190-200;service.c:3345-3374;exec-credential.c:1208-1262)。
