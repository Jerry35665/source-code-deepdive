# 报告 A4 · bootctl 与启动项管理(systemd 卷四)

> 基线:1f66b524(稀疏检出 src/)。一句话:bootctl 是 systemd-boot 的用户态管理器——探测 ESP/XBOOTLDR、复制 EFI 二进制、写 `Loader*` EFI 变量、用 entry-token 命名空间生成 BLS Type#1 commit 条目,并通过 varlink(`io.systemd.BootControl` + `io.systemd.SysUpdate.Notify`)向 sysupdate 暴露 Install/Link/LinkAuto/Unlink,把 `/var/lib/systemd/uki` 暂存的 UKI"链接"进启动菜单。

## 1. 代码版图与动词分发

用户态 bootctl 全部位于 `src/bootctl/`(11 个 .c,约 7600 行),`src/boot/` 只放 EFI 侧源码(stub/loader 本体),两侧靠 `Loader*`/`Stub*` EFI 变量对话。主文件 `bootctl.c` 仅 879 行,做参数解析、ESP 探测与 verb 分发;实现按域拆为 bootctl-status/install/link/unlink/cleanup/random-seed/set-efivar/reboot-to-firmware/uki(见 src/bootctl/meson.build)。17 个动词的归属:

| 动词 | 实现(文件:行号) | 说明 |
|---|---|---|
| status | bootctl-status.c:331-658 | 固件/loader/stub 状态 + 条目 |
| reboot-to-firmware | bootctl-reboot-to-firmware.c:16-51 | 固件"进设置"标记 |
| list | bootctl-status.c:660-706 | 枚举 BLS 条目,支持 JSON |
| link / link-auto | bootctl-link.c:1036-1052 / 1329-1357 | 为 UKI 建 Type#1 条目 |
| unlink / cleanup | bootctl-unlink.c:530 / bootctl-cleanup.c:91 | 删条目 / GC 孤儿文件 |
| set-default/-oneshot/-sysfail/-preferred/-timeout(-oneshot) | bootctl-set-efivar.c:132-180 | 写对应 Loader* 变量 |
| install / update | bootctl-install.c:1745-1767(同一函数) | 装/升 systemd-boot |
| remove / is-installed | bootctl-install.c:1984-2081 | 反向清理 / 已装判定 |
| random-seed | bootctl-random-seed.c:201-222 | 刷新 ESP 种子+系统令牌 |
| kernel-identify / kernel-inspect | bootctl-uki.c:10-40 | 解析 PE 内核/UKI 类型 |

被以 varlink 方式调用时(`sd_varlink_invocation(SD_VARLINK_ALLOW_ACCEPT)` 检测,bootctl.c:741-747),bootctl 不走动词分发而进入 `vl_server()`,注册两个接口共 8 个方法(bootctl.c:768-786);特权检查统一走 `varlink_check_privileged_peer`(bootctl-link.c:1598、1665、1693)。命令行约束:`--root=/--image=` 仅 8 个动词可用(bootctl.c:714-718),`--dry-run` 仅限 unlink/cleanup(bootctl.c:726-727),`--make-entry-directory` 是三态、`auto` 表示"machine-id 永久才建"(bootctl.c:502-513)。

每个动词共同的入口是 `acquire_esp()`:封装 `find_esp_and_warn_full()`,只对 `-ENOKEY` 自己报错(提示挂到 /boot 或 /efi、或用 --esp-path=),`graceful` 模式下降级为跳过日志;配套的 `acquire_xbootldr()` 在"XBOOTLDR 缺失"或"与 ESP 同路径"时清空 arg_xbootldr_path 并返回 0(bootctl.c:125-208)。chroot 内运行会强制开启 `--graceful`(bootctl.c:283-296)。

```c
// bootctl.c:143-152
r = find_esp_and_warn_full(arg_root, arg_esp_path, unprivileged_mode, &np, ret_fd, ret_part, ret_pstart, ret_psize, ret_uuid, ret_devid);
if (r == -ENOKEY) {
        if (graceful)
                return log_full_errno(arg_quiet ? LOG_DEBUG : LOG_INFO, r,
                                      "Couldn't find EFI system partition, skipping.");

        return log_error_errno(r,
                               "Couldn't find EFI system partition. It is recommended to mount it to /boot/ or /efi/.\n"
                               "Alternatively, use --esp-path= to specify path to mount point.");
}
```

```c
// bootctl.c:775-786
r = sd_varlink_server_bind_method_many(
                varlink_server,
                "io.systemd.BootControl.ListBootEntries",        vl_method_list_boot_entries,
                "io.systemd.BootControl.SetRebootToFirmware",    vl_method_set_reboot_to_firmware,
                "io.systemd.BootControl.GetRebootToFirmware",    vl_method_get_reboot_to_firmware,
                "io.systemd.BootControl.Install",                vl_method_install,
                "io.systemd.BootControl.Link",                   vl_method_link,
                "io.systemd.BootControl.LinkAuto",               vl_method_link_auto,
                "io.systemd.BootControl.Unlink",                 vl_method_unlink,
                "io.systemd.SysUpdate.Notify.OnCompletedUpdate", vl_method_on_completed_update);
```

## 2. ESP/XBOOTLDR 探测与 EFI 变量读写

探测在 `src/shared/find-esp.c`:未显式 `--esp-path=` 时按 `/efi`、`/boot`、`/boot/efi` 顺序搜索(find-esp.c:479),并验证文件系统为 FAT(`fd_is_fs_type(fd, MSDOS_SUPER_MAGIC)`,find-esp.c:341);块设备属性用 blkid 或 udev 双路验证(verify_esp_blkid/udev,find-esp.c:60、168)。XBOOTLDR 缺席或与 ESP 同一路径时回落用 ESP 当 `$BOOT`(bootctl.c:180-197);status/list 场景下两者 devnum 相同则抑制 XBOOTLDR 以免条目重复(bootspec-util.c:27-31)。`$BOOT = XBOOTLDR ?: ESP`(bootctl.h:62-65)。

`status` 读一整套 `Loader*`/`Stub*` 变量(bootctl-status.c:439-453):`LoaderFirmwareType/LoaderInfo/StubInfo/LoaderImageIdentifier/LoaderEntrySelected/LoaderEntryOneShot/LoaderEntryPreferred/LoaderEntryDefault/LoaderEntrySysFail/LoaderSysFailReason` 等,并把 22 个 loader 特性位、13 个 stub 特性位翻译成清单(bootctl-status.c:393-414,含 `EFI_LOADER_FEATURE_TYPE1_UKI`、`TYPE1_UKI_URL`、`MULTI_PROFILE_UKI`、`SMBIOS_MEASURED`)。`LoaderEntries` 由 EFI 侧 loader 写入、bootctl 只读:变量体是逐条 NUL 结尾的 UTF-16 串,解析时容忍末尾缺 NUL(efi-loader.c:96-110);`list` 用它对文件系统条目做 augment 排序(bootspec-util.c:35-47)。

写侧映射(bootctl-set-efivar.c:142-159):`set-default→LoaderEntryDefault`、`set-oneshot→LoaderEntryOneShot`、`set-sysfail→LoaderEntrySysFail`、`set-preferred→LoaderEntryPreferred`、`set-timeout(-oneshot)→LoaderConfigTimeout(OneShot)`;参数 `@current/@oneshot/@default/@sysfail` 解引用为对应变量现值,除 `@saved` 外其他 `@` 开头值被拒(bootctl-set-efivar.c:98-119)。空参数=删除变量(`efi_set_variable(variable, NULL, 0)`,bootctl-set-efivar.c:163-166)。`reboot-to-firmware` 无参时查询返回 `active/supported/not supported` 三态及退出码 0/1/2(bootctl-reboot-to-firmware.c:23-39),带 BOOL 参数写固件标记(45-50)。

```c
// bootctl-set-efivar.c:98-119(@-形参解引用与拒绝规则)
if (streq(arg1, "@current")) {
        r = efi_get_variable(EFI_LOADER_VARIABLE_STR("LoaderEntrySelected"), NULL, (void *) ret_target, ret_target_size);
        if (r < 0)
                return log_error_errno(r, "Failed to get EFI variable 'LoaderEntrySelected': %m");

} else if (streq(arg1, "@oneshot")) {
        r = efi_get_variable(EFI_LOADER_VARIABLE_STR("LoaderEntryOneShot"), NULL, (void *) ret_target, ret_target_size);
        ...
} else if (arg1[0] == '@' && !streq(arg1, "@saved"))
        return log_error_errno(SYNTHETIC_ERRNO(EINVAL), "Unsupported special entry identifier: %s", arg1);
```

```c
// bootspec-util.c:35-47(list/status 用 LoaderEntries 增强文件系统条目)
if (!root) {
        _cleanup_strv_free_ char **efi_entries = NULL;

        r = efi_loader_get_entries(&efi_entries);
        if (r == -ENOENT || ERRNO_IS_NEG_NOT_SUPPORTED(r))
                log_debug_errno(r, "Boot loader reported no entries.");
        else if (r < 0)
                log_warning_errno(r, "Failed to determine entries reported by boot loader, ignoring: %m");
        else
                (void) boot_config_augment_from_loader(config, efi_entries, /* auto_only= */ false);
}
```

## 3. install/update/remove:二进制、变量、随机种子与 Secure Boot 登记

`install` 与 `update` 共用 `verb_install`,仅 operation 不同:`INSTALL_NEW` / `INSTALL_UPDATE`(bootctl-install.c:1745-1751,注释"Invoked for both")。`run_install`(1646-1743)次序:UPDATE 先 `are_we_installed()`——判据是 `/EFI/systemd` 目录非空(1506-1550,注释给出三条理由:架构无关、不假设独占 BOOT*.EFI、专测 systemd-boot),未装则静默跳过(1652-1661);NEW 才建目录(1685-1697):ESP 侧 `EFI、EFI/systemd、EFI/BOOT、loader、loader/keys`,$BOOT 侧 `loader、loader/entries、EFI、EFI/Linux`(568-585)。随后:装二进制(1699)→ 写 `loader/loader.conf`(仅 NEW,已存在即跳过,892-945;内容仅注释 `#timeout 3`、`#console-mode keep` 加可选 `default <token>-*`,929-935)→ 建 entry 目录(1708)→ 落 `/etc/kernel/entry-token`(1016-1050,仅"建了目录或 token 非 machine-id"才写,1026-1027)→ 随机种子(仅 NEW 且无 `--root`,1716-1720)→ Secure Boot 自动登记(1722)→ 无条件补 `loader/entries.srel="type1"`(947-994,1727)。

二进制复制 `copy_one_file`(667-825)源在 `BOOTLIBDIR`(可 `--install-source=image/host`,689-711);装到 `/EFI/systemd/systemd-boot<arch>.efi` 的同时镜像到可移动介质约定的 `/EFI/BOOT/BOOT<ARCH>.EFI`(789-821),并刷新 `/EFI/BOOT` 下其他同源 `.efi`(update_efi_boot_binaries,602-665)。update 有两道保护:`.sdmagic` 版本比较,相同/更旧返回 `-ESTALE/-ESRCH` 跳过(747-751,881-886;版本串读取见 bootctl-util.c:135-189);覆盖主 binary 前先轮换出 `systemd-boot-fallback<arch>.efi`,且 fallback 与 `LoaderInfo` 报告的产品/版本一致时不动它(753-783)。EFI 变量注册条件化:容器/非 EFI/`--root` 时 `should_touch_install_variables()` 为假(240-250),`--all-architectures` 亦跳过(1737-1740)。注册流程:按"ESP UUID+路径"找既有 slot,否则取空闲 slot(find_slot,1253-1281),`efi_add_boot_option()` 写 `BootXXXX`(1473-1494),再插入 `BootOrder`——主项要求二进制已存在(`require_existing=true`,1627,1630-1633),fallback 项插在主项之后(1635-1643)。固件菜单描述默认 `"Linux Boot Manager"`(1382),上限 255 字符(bootctl.h:72-76)。

```c
// bootctl-install.c:766-777(update 前轮换 fallback 副本;777 起执行轮换)
_cleanup_close_ int fallback_fd = xopenat_full(dest_parent_fd, fallback_name, O_RDONLY|O_CLOEXEC, XO_REGULAR, MODE_INVALID);
if (fallback_fd >= 0) {
        _cleanup_free_ char *loader_info = NULL, *fallback_version = NULL;

        if (efi_get_variable_string(EFI_LOADER_VARIABLE_STR("LoaderInfo"), &loader_info) >= 0 &&
            get_file_version(fallback_fd, &fallback_version) >= 0)
                should_rotate = compare_product(loader_info, fallback_version) != 0 ||
                                compare_version(loader_info, fallback_version) != 0;
}

if (should_rotate)
        r = copy_file_with_version_check(dest_path, dest_fd, fallback_path, dest_parent_fd, fallback_name, -EBADF, true);
```

`remove`(1984-2052)反向清理:删 `/EFI/systemd` 整树及 `/EFI/BOOT` 中版本串以 `"systemd-boot "` 开头的二进制(1899-1922,1831),删 `loader.conf、loader/random-seed、entries.srel、loader/keys/auto/{PK,KEK,db}.auth`(2015-2028),删 9 个 `Loader*` 变量(1947-1956)与两条 Boot 选项(1972-1982)。

```c
// bootctl-install.c:1703-1720(仅 NEW 执行的初始化序列,错误分支从略)
if (c->operation == INSTALL_NEW) {
        r = install_loader_config(c);
        if (r < 0)
                return r;

        r = install_entry_directory(c);
        if (r < 0)
                return r;

        r = install_entry_token(c);
        if (r < 0)
                return r;

        if (arg_install_random_seed && !c->root) {
                r = install_random_seed(c->esp_path, c->esp_fd);
                if (r < 0)
                        return r;
        }

        r = install_secure_boot_auto_enroll(c);
        ...
}
```

随机种子 `install_random_seed`(bootctl-random-seed.c:114-199):新随机 32 字节(`RANDOM_EFI_SEED_SIZE==SHA256_DIGEST_SIZE`,125)与旧 seed 拼接做 SHA-256(155-167),0600 权限临时文件+rename 原子替换(169-189),`syncfs` 后调 `set_system_token()`(198)——`LoaderSystemToken` 已够长则绝不重写,写时 umask 0077(74-108)。Secure Boot 自动登记不直接写固件变量,而是在 ESP 生成 PKCS7 签名的 `EFI_VARIABLE_AUTHENTICATION_2` 文件 `loader/keys/auto/{PK,KEK,db}.auth` 交固件/loader 消费(1141-1225);需 `--secure-boot-auto-enroll` 且证书、私钥齐备(bootctl.c:729-739)。

## 4. link/link-auto:entry-token、commit 条目与空间回收

`bootctl link KERNEL` 把一个 UKI 复制进 `$BOOT/<entry-token>/` 并为它的每个 profile 生成 Type#1 条目;`link-auto` 自动发现暂存资源(bootctl-link.c:1329-1357)。命名空间 token 由 `boot_entry_token_ensure_at` 决定,AUTO 顺序:配置文件(`/etc/kernel/entry-token`,`KERNEL_INSTALL_CONF_ROOT` 可换根,68-74)→ machine-id → os-release `IMAGE_ID=`/`ID=`,全空报 `-EUNATCH`(src/shared/boot-entry.c:164-186);CLI 取值 `auto/machine-id/os-image-id/os-id/literal:`(boot-entry.c:243-289)。条目文件名是单调 commit 计数 `<token>-commit_<nr>[.<version>][@<profile>][+<tries>].conf`,commit 号取现有最大值 +1(bootspec-util.c:70-87;bootctl-link.c:636-693);条目正文 `title/uki /<token>/<file>/version[.profile][.machine-id][.extra …]`(bootctl-link.c:571-599);profile 循环上限 `UNIFIED_PROFILES_MAX=256`(src/fundamental/uki.h:36;bootctl-link.c:860-888),无有效 profile 报 EBADMSG(890-891)。

写入两阶段:先 `begin_copy_file/begin_write_entry_file` 写 `.#` 前缀临时文件(FAT 不支持 `O_TMPFILE`,写前手工清扫残留,bootctl-link.c:700-706,826,846),`syncfs` 后二次校验 keep-free(默认 5 MiB,bootctl.h:78-80;bootctl-link.c:782-802),然后 link 成正式名;从此刻起出错不再回滚,交给 `bootctl cleanup` GC(915-928 注释)。磁盘满(`ERRNO_IS_NEG_DISK_SPACE`)时 `run_link` 循环"删最旧 commit→重试"(998-1022);最旧 commit 选取跳过当前启动项(-EBUSY,bootspec-util.c:203-220,167-255)。同名文件已存在则跳过复制("already in place, not copying",bootctl-link.c:437-446)。

```c
// bootctl-link.c:1054-1064(link-auto 的五级 staging 搜索目录)
/* Directories (relative to the operative root) below which "bootctl link-auto" looks for a staged UKI and
 * extra resources, in decreasing priority order. /var/lib/systemd/uki/ is where systemd-sysupdate stages
 * downloaded resources; ... */
static const char* const uki_auto_dirs[] = {
        "etc/systemd/uki",
        "run/systemd/uki",
        "var/lib/systemd/uki",
        "usr/local/lib/systemd/uki",
        "usr/lib/systemd/uki",
};
```

两阶段提交的"不可逆点"有明确注释:所有资源 link 成正式名之前,任何错误都会清掉全部临时文件;之后切换模式,已就位的一律保留,残留交给 `bootctl cleanup`(bootctl-link.c:915-928)。commit 号的自动选取是"扫 loader/entries,解析同 token 条目文件名,取最大 commit +1,溢出报 E2BIG"(bootctl-link.c:636-693)。写条目前还有一道防御:标题与文件名先做控制字符/UTF-8 校验,生成不出合法条目就拒绝写(bootctl-link.c:565-569)。

```c
// bootctl-link.c:571-579(Type#1 条目正文模板)
if (asprintf(&text,
             "title %s\n"
             "uki /%s/%s\n"
             "version %" PRIu64 "%s%s\n",
             title,
             c->entry_token, c->kernel_filename,
             c->entry_commit, isempty(version) ? "" : ".", strempty(version)) < 0)
        return log_oom();
```

## 5. sysupdate 链路:staging 发现与 OnCompletedUpdate

link-auto 的 UKI 取"第一个含 `kernel.efi`(或 vpick 目录 `kernel.efi.v/` 最优版本)的目录"(bootctl-link.c:1223-1282,1309-1314,校验必须为 UKI:330-345);extra 资源后缀 `.sysext.raw/.confext.raw/.cred`,可为 vpick 版本目录(1072-1079),跨目录合并、高优先级目录以资源逻辑名去重胜出(1110-1121,1161-1172)。命令行还可追加 `--extra=`(658-684;300-328)。varlink `Link()` 的 `kernelFileDescriptor` 必填(1577-1592),且显式拒绝非 UKI:`kit != KERNEL_IMAGE_TYPE_UKI` → 错误 `io.systemd.BootControl.InvalidKernelImage`(1617-1625)。

sysupdate 完成更新后向 `/run/systemd/sysupdate/notify/` 下全部 varlink socket 广播 `io.systemd.SysUpdate.Notify.OnCompletedUpdate`(src/basic/constants.h:72;src/sysupdate/sysupdate.c:1793-1803,超时 5 分钟,参数 component/version/resources,均为可空)。bootctl 侧"故意忽略全部参数,行为等同默认参数的 LinkAuto"(bootctl-link.c:1697-1700):无暂存 UKI 时空回包(1716-1717),成功则链接但不回 ids(1719);`LinkAuto()` 正常回 `ids` 字符串数组,无暂存时空数组(1676-1677)。$BOOT 的解析在 varlink 路径里是"先 XBOOTLDR、无则 ESP",全缺则回 `NoDollarBootFound`,`-EUNATCH` 映射为 `BootEntryTokenUnavailable`(bootctl-link.c:1521-1552)。

```c
// bootctl-link.c:1548-1557(运行链接并按调用方决定是否回 ids)
r = run_link(&p->context);
if (r == -EUNATCH) /* no boot entry token is set */
        return sd_varlink_error(link, "io.systemd.BootControl.BootEntryTokenUnavailable", NULL);
if (r < 0)
        return r;

if (with_ids)
        return sd_varlink_replybo(link, SD_JSON_BUILD_PAIR_STRV("ids", p->context.linked_ids));

return sd_varlink_reply(link, NULL);
```

varlink 错误集:`NoESPFound`(bootctl-install.c:2183)、`NoDollarBootFound`(bootctl-link.c:1540)、`BootEntryTokenUnavailable`(-EUNATCH 映射,1550、bootctl-install.c:2200)、`InvalidKernelImage`(1621-1625)、`NoSuchBootEntry`(list 的 more 流哨兵,bootctl-status.c:747)。注:把 bootctl 的 socket 接入该目录的 unit 文件不在本次稀疏检出内(units/ 缺失,未核实具体文件名)。

```c
// bootctl-link.c:1697-1706(OnCompletedUpdate 的语义)
/* Triggered by systemd-sysupdate after an update completed. We deliberately ignore all parameters
 * (we don't even dispatch them) and behave like LinkAuto() with default parameters: discover the
 * staged UKI and extra resources and link them in. Contrary to LinkAuto() we reply without any
 * parameters, matching the io.systemd.SysUpdate.Notify.OnCompletedUpdate() signature. */
```

## 6. 纠偏(以 1f66b524 源码为准)

1. "bootctl 本体在 src/boot/bootctl.c"——错。用户态 bootctl 已拆至 `src/bootctl/`(bootctl.c 仅做分发),`src/boot/` 是 EFI 侧 stub/loader 源码(git ls-files 核实;`ls src/boot/` 全是 stub.c/pe.c 等)。
2. "bootctl 负责 TPM2/LUKS 密钥登记"——错。bootctl 的"enroll"只有 Secure Boot 自动登记(PK/KEK/db `.auth` 文件,bootctl-install.c:1077-1227);LUKS 密钥登记属 systemd-cryptenroll,bootctl 源码无任何 LUKS 逻辑(全库 grep 核实)。
3. "install 每次重写 loader.conf"——错。仅 INSTALL_NEW 且文件不存在时写(bootctl-install.c:915-919,1703-1706);update 反而会补写 `entries.srel`(1727),两者都幂等跳过已有文件。
4. "update 总是覆盖 ESP 上的 binary"——错。有 `.sdmagic` 版本比较,同/旧版本跳过(bootctl-install.c:747-751,881-886),且覆盖前先轮换 fallback 副本(753-783)。
5. "link-auto 只看 /var/lib/systemd/uki"——错。五目录优先级搜索,etc/run 排在 var/lib 之前(bootctl-link.c:1058-1064);UKI 取首个命中目录,extras 跨目录合并(1290-1327)。
6. "新 UKI 以 Type#2 放进 EFI/Linux"——错。link 机制把 UKI 复制进 `/<token>/` 并写 Type#1 条目(带 `uki ` 行)引用之(bootctl-link.c:571-579);`EFI/Linux` 目录仅是 install 预留(bootctl-install.c:578-585),entries.srel 固定声明 `type1`(984)。
7. "commit 条目按版本号排序自增"——不完全。文件名主键是单调递增 commit 号,版本只是文件名可选段(bootspec-util.c:70-79);GC 删除按"最旧 commit 且非当前启动项"(bootspec-util.c:203-220)。

## 7. ASCII:一次 `bootctl update` 的数据流

```
 bootctl update
   │ parse_argv (bootctl.c:370)                [--esp-path/--root/--variables/--graceful…]
   ▼
 acquire_esp + acquire_xbootldr (bootctl.c:125-208)
   │  搜索 /efi,/boot,/boot/efi (find-esp.c:479);验证 FAT (find-esp.c:341)
   ▼
 run_install(INSTALL_UPDATE) (bootctl-install.c:1646)
   ├─ are_we_installed? /EFI/systemd 非空? ──否──► 静默返回 (1652-1661)
   ├─ install_binaries: BOOTLIBDIR/systemd-boot<arch>.efi[.signed] (827-890)
   │     ├─ 版本比较,同/旧 → -ESTALE 跳过 (747-751, 881-886)
   │     ├─ 旧主 binary → systemd-boot-fallback<arch>.efi (753-783)
   │     ├─ 复制到 /EFI/systemd/ (721-787)
   │     └─ 镜像 /EFI/BOOT/BOOT<ARCH>.EFI + 刷新其他 .efi (789-821, 602-665)
   ├─ (NEW only) 建目录/loader.conf/entry 目录+token/随机种子/SB登记 (1685-1725)
   ├─ entries.srel="type1" 若缺 (947-994, 1727)
   └─ sync_everything (bootctl-util.c:85-101)
   ▼
 should_touch_install_variables? (240-250: 容器/非EFI/--root → 跳过)
   ├─ find_slot: 按 ESP-UUID+路径匹配 BootXXXX,否则空闲 slot (1253-1281)
   ├─ efi_add_boot_option → BootXXXX (1473-1494)
   └─ insert_into_order → BootOrder(主项在前,fallback 紧随) (1283-1350, 1614-1643)
   ▼
 完成:固件 → BOOT<ARCH>.EFI → systemd-boot → 读 loader/entries/*.conf + EFI/Linux/*.efi
 (varlink 路径:vl_method_install 同达 run_install,bootctl-install.c:2101-2203)
```

## 8. 设计动机 · FAQ 候选 · 深挖方向

**设计动机**
1. ESP 是无日志 FAT 且常仅几百 MiB:写入全走临时文件+link+`syncfs`,预留 keep-free 5 MiB,满则自动删最旧 commit(bootctl-link.c:700-706,917-928,998-1022;bootctl.h:78-80)。
2. 多系统共存:entry-token 给每个 OS 一个条目命名空间目录 `/<token>/`,machine-id 为默认但可被 entry-token 文件、IMAGE_ID/ID 覆盖(boot-entry.c:164-186)。
3. 面向不可变/UKI 化交付:commit 单调计数使"链接新版本、GC 旧版本"成为纯文件名运算,与 sysupdate 原子更新模型对齐(bootspec-util.c:50-87)。
4. varlink 而非 D-Bus:可传 root_fd/kernel_fd 文件描述符、校验极简,让 sysupdate 以最小权限触发安装(bootctl.c:768-786;bootctl-link.c:1468-1494)。
5. 永不给固件留死局:update 前轮换 systemd-boot-fallback 副本,已知良好 fallback 不被覆盖(bootctl-install.c:738-783)。
6. EFI 变量操作全程可关断(`--variables=no`、容器/离线自动跳过),保证 `--root=/--image=` 镜像构建可复现(bootctl-util.c:19-40;bootctl-install.c:240-250)。
7. 幂等:文件已存在跳过、loader.conf/entries.srel 只在缺失时创建、LoaderSystemToken 已够长不重写(bootctl-link.c:441;bootctl-install.c:915-919;bootctl-random-seed.c:81-85)。

**FAQ 候选**
1. bootctl 与 src/boot 的 systemd-boot 什么关系?——用户态管理工具 vs ESP 上的 EFI 二进制,以 `Loader*` 变量为接口(bootctl-status.c:439-453)。
2. install 与 update 区别?——同一 `verb_install`,NEW 建目录/写配置/装种子,UPDATE 前置"已装"检查且不建目录(bootctl-install.c:1652-1697)。
3. is-installed 判据?——`/EFI/systemd` 目录非空即视为已装(bootctl-install.c:1511-1549)。
4. entry-token 落到文件系统哪里?——`$BOOT/<token>/` 目录名,并持久化到 `/etc/kernel/entry-token`(bootctl-install.c:1016-1050)。
5. commit 号从几开始?——扫现有同 token 条目取最大 commit+1(bootctl-link.c:636-693)。
6. 磁盘满如何自愈?——`run_link` 删本 token 最旧 commit(跳过当前启动项)后重试(bootctl-link.c:998-1022;bootspec-util.c:203-220)。
7. set-oneshot 写哪个变量?——`LoaderEntryOneShot`,bootctl 只写、消费在 EFI 侧(bootctl-set-efivar.c:151-153)。
8. random-seed 为何先读旧文件?——新旧拼接做 SHA-256,保证熵"只进不退"(bootctl-random-seed.c:155-167)。
9. Secure Boot 自动登记改固件变量吗?——不改,只写 ESP 上 PKCS7 签名的 `.auth` 文件等固件自取(bootctl-install.c:1141-1225)。
10. `--root=` 下哪些动词可用?——仅 status/list/install/update/remove/is-installed/random-seed/unlink/cleanup(bootctl.c:714-718)。
11. OnCompletedUpdate 的参数会被用吗?——不会,bootctl 全部忽略,按默认 LinkAuto 执行(bootctl-link.c:1697-1717)。

**深挖方向**
1. `pe_find_uki_sections` 的多 profile 展开:每 profile 生成一条 `.conf`(`@<N>` 后缀)及标题合成规则(bootctl-link.c:509-563,860-888)。
2. vpick(`kernel.efi.v/`、`foo.sysext.raw.v/`)的版本挑选与 boot-counting 后缀的刻意不兼容(bootctl-link.c:1174-1198,1226-1263)。
3. `EFI_VARIABLE_AUTHENTICATION_2` 的 PKCS7 编码链与 EFI 侧登记代码 src/boot/efi-firmware.c 的配对验证。
4. `insert_into_order` 位置策略:UPDATE 不动用户排序、NEW 才置顶、after_slot 保序(bootctl-install.c:1283-1350)。
5. unlink/cleanup 的 `known_files` 引用计数:共享 kernel 文件如何决定删除(bootctl-unlink.c:70-183;bootctl-cleanup.c:50-89)。

## 9. 正文蒸馏要点

1. bootctl 17 个动词、8 个 varlink 方法集中在 bootctl.c:302-368、775-786;varlink 模式由 `sd_varlink_invocation()` 自动进入(bootctl.c:741-747)。
2. ESP 搜索 `/efi`→`/boot`→`/boot/efi` 且必须 FAT;XBOOTLDR 存在时它才是 `$BOOT`(find-esp.c:479,341;bootctl.h:62-65)。
3. `status` 读取 22 个 loader + 13 个 stub 特性位与全套 `Loader*` 变量(bootctl-status.c:393-453)。
4. `install`/`update` 同体:UPDATE 以 `/EFI/systemd` 非空为"已装"判据,否则静默跳过(bootctl-install.c:1652-1661,1506-1550)。
5. update 安全网:`.sdmagic` 版本比较跳过 + fallback 副本轮换(bootctl-install.c:747-783);变量注册条件化、可整体关断(bootctl-install.c:240-250,1737-1740)。
6. BootXXXX slot 按"ESP UUID+文件路径"复用,新项按策略插入 BootOrder(bootctl-install.c:1253-1281,1283-1350)。
7. 随机种子 = SHA256(新随机 32B ∥ 旧 seed),0600 原子替换;`LoaderSystemToken` 已够长则不重写(bootctl-random-seed.c:140-198,74-88)。
8. Secure Boot 自动登记产出 `loader/keys/auto/{PK,KEK,db}.auth`(PKCS7 签名),不直接写固件变量(bootctl-install.c:1141-1225)。
9. entry-token AUTO 优先级:entry-token 文件 → machine-id → os-release IMAGE_ID/ID,全空报 `-EUNATCH`(boot-entry.c:164-186)。
10. link 生成 Type#1 commit 条目 `<token>-commit_<n>[.ver][@p][+tries].conf`,正文核心是 `uki /<token>/<file>` 行(bootspec-util.c:70-79;bootctl-link.c:571-579)。
11. link-auto 五级 staging 目录,UKI 取首个命中,extras 跨目录按名去重合并(bootctl-link.c:1054-1064,1290-1327)。
12. sysupdate 更新完成后向 `/run/systemd/sysupdate/notify/` 广播 OnCompletedUpdate,bootctl 忽略参数、按默认 LinkAuto 链接暂存 UKI(constants.h:72;sysupdate.c:1793-1803;bootctl-link.c:1697-1719)。
