# 第 20 章 · ukify 与 systemd-stub:一个 PE 的两次生命

> 基线:commit `1f66b524`。核心:src/ukify/ukify.py(2,706 行,Python)与 src/boot/(stub.c/pe.c/measure.c/cpio.c——纠偏:stub C 源在 `src/boot/`,**不存在 src/efi/**,历史上 src/boot/efi/ 已摊平)。

## 20.0 全景:构建段布局 vs 启动测量

```
 ukify build(组装,PE 文件内顺序 ukify.py:1462-1476):
   stub PE 底座 → .profile → .osrel/.cmdline/.dtb/.dtbauto/.hwids/.uname
   → .splash/.pcrpkey → .linux → .initrd → .efifw(measure=False!)→ .ucode
   → SB 签名外调 sbsign/pesign/systemd-sbsign;PCR 预签名外调 systemd-measure
 systemd-stub(启动,src/boot/):
   从内存 PE 段表解包 → 测量:PCR11=静态段,PCR12=cmdline/credentials/confext,
   PCR13=sysext,SMBIOS 进 PCR1 → 重组 initrd(ucode 插最前)→ LoadFile2 交内核
```

纠偏:**测量顺序=枚举顺序(.linux 打头,uki.c:7-27 注释"PLEASE DO NOT REORDER"),与 PE 文件布局顺序是两个独立概念**;PE 段内 .ucode 靠后,但启动时 ucode(含 addon,反序)插到合并 initrd 最前——内核取"第一个匹配"的微码文件(stub.c:474-476, 1274-1285)。

## 20.1 ukify:编排器而非实现者

纠偏:签名是三种 subprocess 外调(pesign/sbsign/systemd-sbsign,ukify.py:522-641,全程无 sbattach);PCR 计算与签名一律外调 systemd-measure(:812-958);底座改写靠 python-pefile 手工重排 PE(剥离符号表、对齐 PointerToRawData、圆整 SizeOfHeaders 腾段表空间,:997-1181);唯一内置密码学是 genkey(python-cryptography 生成 RSA-2048 自签证书,:1623-1702)。内核版本自动提取:x86 real-mode 头 HdrS 魔数→ELF note→全文正则(:343-410);`--sign-kernel` 未给时用 sbverify/pesign 探测内核已签名与否来决定(:1397-1408)。子命令只有 build/genkey/inspect 三个(:2020)。

## 20.2 真实一致性缺口:.efifw 测量不对称

**本 commit 最重要的发现**:ukify 把 `.efifw` 标记 `measure=False` 不传给 systemd-measure(ukify.py:1474),但 stub 侧段测量只排除 `.pcrsig` 一项(unified_section_measure;stub.c:733-760),会把 `.efifw` 量入 PCR 11——**含 .efifw 的 UKI,其 PCR11 预签名策略与 stub 实际测量不一致,PCR11 绑定的解锁策略会失配**。另纠偏:不存在 `.dtbadd` 段(grep 零命中),DTB 附加=内嵌 .dtb/.dtbauto + `\loader\addons\*.addon.efi`(stub.c:642-666)。

## 20.3 PCR 布局与 sidecar initrd

PCR11=镜像静态段(可预计算);PCR12=cmdline/addon/credentials/confext/profile 编号;PCR13=sysext;SMBIOS 进 PCR1(tpm2-pcr.h:28-38; measure.c:366-384)。CC(机密计算)协议与 TCG2 双写防 CVE-2021-42299 类碰撞(measure.c:302, 341-342);完成后写 StubPcrKernelImage=11 等四个 EFI 变量(stub.c:971-988)。合并 initrd 槽位顺序由枚举固定(stub.c:36-52):UCODE→PREVIOUS→BASE→CREDENTIAL→SYSEXT→CONFEXT→PCRSIG→...;`.cred/.raw/.confext.raw` sidecar 扫描 UKI 同目录与 \loader\credentials、\loader\extensions 全局目录,打包成 cpio,落盘路径与 PCR 归属在 cpio.c 规范表(credentials=.extra/credentials 0500/0400 进 PCR12;sysext 进 PCR13,cpio.c:512-566)。random-seed:sd-boot 未初始化时,ESP 种子 SHA256 混入 UEFI 单调计数器与 RTC,派生值装进 LINUX_EFI_RANDOM_SEED_TABLE(random-seed.c:240-417)。

## 20.4 设计动机

1. **段即协议**:ukify 写段/stub 读段同源于 unified_sections[] 清单,≤8 字符段名(uki.c:7-27);
2. **编排而非实现**:签名/测量外调专门工具,ukify 保持零密码学面(ukify.py:522-641);
3. **PCR 分层**:静态段(11)/参数(12)/扩展(13)分开,策略可组合可预签(measure.c:366-384);
4. **TCG2+CC 双写**:机密计算时代防碰撞(measure.c:341-342);
5. **sidecar cpio 规范表**:落盘路径与测量归属一表定死(cpio.c:512-566);
6. **随机种子接力**:loader 与 stub 共享"是否已初始化"特性位,避免双重播种(random-seed.c:240-296)。

## 20.5 FAQ

**Q1:stub 源码在哪?**
src/boot/(不存在 src/efi/,历史目录已摊平)。

**Q2:ukify 自己会签名吗?**
不,外调 sbsign/pesign/systemd-sbsign 三选一(ukify.py:522-641)。

**Q3:.efifw 会被测量吗?**
stub 会量进 PCR11,但 ukify 预签名不覆盖它——本 commit 真实缺口(ukify.py:1474 vs stub.c:733-760)。

**Q4:PCR12 装什么?**
cmdline/credentials/confext/DT addon/profile 编号(tpm2-pcr.h:28-38)。

**Q5:有 .dtbadd 段吗?**
没有;DTB 附加靠 .dtb/.dtbauto 段+addon PE(stub.c:642-666)。

**Q6:ucode 为什么启动时插最前?**
内核取第一个匹配的微码文件(stub.c:1274-1282 注释)。

**Q7:.pcrsig 被测量吗?**
既不作为原始段也不作为 cpio 被测量(stub.c:888-895)。

**Q8:离线签名 JSON 为何填空格?**
每个策略摘要预留 1024 空格给签名占位(4KB/签名上限)(ukify.py:905-910)。

**Q9:pcrsig/pcrpkey 怎么交给用户态?**
包装成 initrd 内 /.extra/tpm2-pcr-signature.json 等文件(stub.c:880-929)。

**Q10:boot-secret 是什么?**
从随机种子表+启动期 EFI 变量秘密+ESP mixin+.osrel ID 派生的 initrd 文件(boot-secret.c:8-23)。

## 20.6 小结与深挖方向

本章结论:**UKI=ukify 手工 PE 追加段+外调签名测量;stub=内存解包+分层 PCR 测量+initrd 重组;契约=unified_sections 一张清单**。深挖:

1. .efifw 测量不对称的修复方向(measure=True 或 stub 排除);
2. MULTI_PROFILE UKI 的 --join-profile 分段测量合并(ukify.py:1542-1583);
3. .dtbauto 的 compatible 硬件匹配(devicetree.c:184-194);
4. CC 协议双写的 CC_EVENT 形态(measure.c:302);
5. boot-secret 与 systemd-creds 的密钥衔接(卷四 18 章)。
