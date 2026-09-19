# 第 19 章 · bootctl:用户态启动项管理器与"永不死局"双保险

> 基线:commit `1f66b524`。核心:src/bootctl/(11 个 .c 约 7,600 行)/ src/shared/find-esp.c。纠偏:bootctl 本体已**不在 src/boot/**——src/boot/ 是 EFI 侧 stub/loader 源码,两侧靠 Loader*/Stub* EFI 变量对话。

## 19.0 全景:17 个动词 + 8 个 varlink 方法

```
 bootctl.c(879 行,分发)+ 按域拆分:status/install/link/unlink/cleanup/
 random-seed/set-efivar/reboot-to-firmware/uki
 动词:status/list/link/link-auto/unlink/cleanup/set-default/-oneshot/-sysfail/
      set-preferred/-timeout/install/update/remove/is-installed/random-seed/kernel-identify/inspect
 varlink:io.systemd.BootControl(7 方法)+ io.systemd.SysUpdate.Notify.OnCompletedUpdate
      (bootctl.c:775-786)——特权检查统一 varlink_check_privileged_peer
 入口共同点:acquire_esp()(找不到 ESP:-ENOKEY,graceful 模式降级为跳过日志,bootctl.c:143-152)
```

纠偏:sysupdate→bootctl 的接链是**零参数广播**——sysupdate 向 /run/systemd/sysupdate/notify/ 内全部 varlink socket 广播 OnCompletedUpdate(5 分钟超时),bootctl 侧**故意忽略全部参数**,按默认 LinkAuto 从五级目录(etc→run→var/lib→usr/local/lib→usr/lib)发现暂存 UKI,生成 `<token>-commit_<n>[.ver][@p][+tries].conf` Type#1 条目,写满自动 GC 最旧 commit(bootctl-link.c:1058-1064, 1697-1719; bootspec-util.c:70-79)。

## 19.1 ESP 探测与 EFI 变量

ESP 按 /efi→/boot→/boot/efi 顺序搜索,验证 FAT+blkid/udev 双路(find-esp.c:341-479);`$BOOT = XBOOTLDR ?: ESP`;status/list 下两者 devnum 相同则抑制 XBOOTLDR 防条目重复。status 读全套 Loader*/Stub* 变量并翻译 22 个 loader+13 个 stub 特性位(TYPE1_UKI/MULTI_PROFILE_UKI/SMBIOS_MEASURED 等,bootctl-status.c:393-453);LoaderEntries 是 EFI 侧写入的 UTF-16 NUL 串数组,bootctl 只读并用它对文件系统条目 augment 排序(efi-loader.c:96-110; bootspec-util.c:35-47)。写侧映射:set-default→LoaderEntryDefault、set-oneshot→LoaderEntryOneShot 等;`@current/@oneshot/@default/@sysfail` 解引用,除 `@saved` 外其他 `@` 值拒绝;空参数=删除变量(bootctl-set-efivar.c:98-166)。

## 19.2 install/update:次序与两道保护

install 与 update 共用 verb_install(INSTALL_NEW/INSTALL_UPDATE,bootctl-install.c:1745-1751)。run_install 次序(:1646-1743):UPDATE 先判 `/EFI/systemd` 目录非空(未装则静默跳过)→ NEW 建目录树(ESP 侧 EFI/systemd、EFI/BOOT、loader;$BOOT 侧 loader/entries、EFI/Linux)→ 装二进制(同时镜像到 /EFI/BOOT/BOOT<ARCH>.EFI,刷新同源 .efi)→ 写 loader.conf(仅 NEW,内容仅注释行)→ 落 /etc/kernel/entry-token → 随机种子(仅 NEW)→ Secure Boot .auth 登记 → 无条件补 loader/entries.srel="type1"。**两道保护**:`.sdmagic` 版本比较,相同/更旧返回 -ESTALE/-ESRCH 跳过(:747-751);覆盖主 binary 前轮换出 systemd-boot-fallback<arch>.efi,且 fallback 与 LoaderInfo 产品/版本一致时不动(:753-783)——这就是"永不死局"双保险。EFI 变量注册条件化:容器/非 EFI/--root/--all-architectures 全跳过(:240-250, 1737-1740);主 BootXXXX 仅在二进制已存在时注册(:1627-1633)。

## 19.3 remove 与纠偏

remove 反向清理:删 /EFI/systemd 整树、/EFI/BOOT 中版本串以 "systemd-boot " 开头的二进制、loader.conf/random-seed/entries.srel/keys/*.auth、9 个 Loader* 变量与两条 Boot 选项(:1899-2052)。纠偏:"bootctl 负责 TPM2/LUKS 登记"不成立——bootctl 只有 Secure Boot `.auth` 文件登记(:1077-1227),LUKS 登记在 systemd-cryptenroll(卷三 15)。

## 19.4 设计动机

1. **用户态/EFI 侧分离**:bootctl 与 loader 靠 EFI 变量协议对话,无共享代码(bootctl.h 注释);
2. **零参数广播**:sysupdate 与 bootctl 解耦,事件语义而非命令语义(sysupdate.c:1793-1803);
3. **fallback 轮换**:任何时刻 ESP 上都有一个能启动的旧 binary(bootctl-install.c:753-783);
4. **.sdmagic 版本闸**:旧版本不覆盖新版本,防降级踩坑(:747-751);
5. **条件化变量注册**:容器/CI 里跑 install 不留 BootXXXX 垃圾(:240-250);
6. **entries.srel 无条件补写**:声明"本机条目全是 Type#1",给 cleanup 以依据(:947-994)。

## 19.5 FAQ

**Q1:bootctl 源码在哪?**
src/bootctl/;src/boot/ 是 EFI 侧 stub/loader(最常见错位)。

**Q2:sysupdate 完成后 bootctl 怎么知道?**
varlink 零参数广播 OnCompletedUpdate,参数被故意忽略(bootctl-link.c:1697-1719)。

**Q3:UKI 条目命名?**
<token>-commit_<n>[.ver][@p][+tries].conf Type#1 条目,写满 GC 最旧 commit。

**Q4:找不到 ESP 会怎样?**
-ENOKEY 报错;graceful(含 chroot)降级为跳过日志(bootctl.c:143-152, 283-296)。

**Q5:update 会覆盖新版本吗?**
不会,.sdmagic 版本比较挡住相同/更旧(bootctl-install.c:747-751)。

**Q6:覆盖失败会变砖吗?**
不会,先轮换 fallback binary,LoaderInfo 一致则不动(:753-783)。

**Q7:容器里跑 install 安全吗?**
EFI 变量注册自动跳过(:240-250)。

**Q8:bootctl 管 LUKS 登记吗?**
不管,只有 Secure Boot .auth 登记;LUKS 在 cryptenroll。

**Q9:remove 删什么?**
/EFI/systemd 整树+同源 BOOT*.EFI+配置与 9 个变量+2 条 Boot 选项(:1899-2052)。

**Q10:@saved 是什么?**
唯一的合法 @ 特殊标识,其余 @ 值拒绝(bootctl-set-efivar.c:98-119)。

## 19.6 小结与深挖方向

本章结论:**bootctl=ESP 探测+二进制安装双保险+BLS 条目管理+varlink 服务面,EFI 变量是与 loader 的唯一对话协议**。深挖:

1. bootctl-uki.c 的 PE 解析判定内核/UKI 类型(bootctl-uki.c:10-40);
2. MULTI_PROFILE_UKI 特性位与多 profile 切换的状态面(bootctl-status.c:393-414);
3. random-seed 的系统令牌与 ESP 种子双写(bootctl-random-seed.c:201-222);
4. entries.srel 与 cleanup 的孤儿文件判定(bootctl-cleanup.c:91);
5. --make-entry-directory=auto 的 machine-id 永久性判定(bootctl.c:502-513)。
