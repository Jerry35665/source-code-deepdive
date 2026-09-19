# 第 23 章 · kernel-install:C 编排器 + 外部插件协议

> 基线:commit `1f66b524`。核心:src/kernel-install/kernel-install.c(1,781 行)+ 4 个自带插件(50-depmod/60-ukify/90-loaderentry/90-uki-copy)。纠偏:**不存在 kernel-install-*.c 或 plugins/ 目录**——插件从来不是内置 C 模块,而是独立可执行脚本。

## 23.0 全景:make install 之后的插件链

```
 make install(发行版包装)→ kernel-install add VERSION KERNEL_IMAGE [INITRD…]
   ▼ C 核:解析 env/install.conf/machine-info → ENTRY-TOKEN/BOOT_ROOT/layout
   ▼ 建 staging:var_tmp 下 mkdtemp "kernel-install.staging.XXXXXX"(:942-957)
   ▼ 按文件名序执行 /etc/kernel/install.d + /usr/lib/kernel/install.d 的 *.install:
     50-depmod(sh)→ 60-ukify(Python,产出 $STAGING_AREA/uki.efi)
     → 90-loaderentry(sh,Type#1 条目)→ 90-uki-copy(sh,认领 uki.efi 落 $BOOT)
   ▼ 插件协议:PLUGIN add|remove KERNEL_VERSION ENTRY_DIR_ABS [KERNEL_IMAGE [INITRD…]]
     + 12 项 KERNEL_INSTALL_* env(:1082-1136)
```

纠偏:条目命名两层且与 bootctl **同源**——资产目录 `$BOOT/$ENTRY_TOKEN/$KERNEL_VERSION`(:972),ENTRY-TOKEN 解析在与 bootctl 共享的 src/shared/boot-entry.c:143-218(auto 顺序:entry-token 文件→machine-id→os-release IMAGE_ID=/ID=)。

## 23.1 插件协议细节

插件发现:后缀 .install、可执行、普通文件、过滤 masked,conf_files_list_strv 一次列全(:765-770);`KERNEL_INSTALL_PLUGINS` env 可整表覆盖(测试靠它注入,:532)。staging 语义:中间产物必须先落 staging,由 90-* 插件统一落 $BOOT;initrd 参与顺序(两插件一致):staging/microcode* → 命令行 initrds → staging/initrd*(60-ukify.install.in:235-240)。**退出码协议**:77=EXIT_SKIP_REMAINING(视为成功且跳过剩余插件),其他非零码原样上抛为进程退出码;`-v` 两件事:日志 DEBUG+导出 KERNEL_INSTALL_VERBOSE=1,插件据此回显将执行的命令(exec-util.c:192-197; kernel-install.c:1636-1639)。

## 23.2 动词与纠偏

layout 是 `auto|uki|bls|other`(**无 off/ubl**);BOOT_ROOT 探测中 **XBOOTLDR 优先于 ESP**(:699-731);`add` 只给一个参数时它是内核镜像路径而非版本(:1304-1310);`remove` 刻意不从 uname 推版本(:1420-1423);mkinitrd/dracut 兼容层**已不存在**,唯一传统接口是 argv[0]=installkernel(忽略 MAP/DIR 参数,:1387-1395);remove 时 90-uki-copy 不查 layout、无条件清理 UKI(90-uki-copy.install:35-56)。60-ukify 是 jinja2 模板,构建时注入 PROJECT_VERSION 后安装(meson.build:14-28);60-ukify 内部调 ukify build(衔接卷四 20 章),uki.conf 是全注释配置模板。

## 23.3 设计动机

1. **C 核只做编排**:列插件/搭 staging/传协议,所有"写 $BOOT"的决策在插件里(kernel-install.c:757-775);
2. **staging 强制**:中间产物不直接进 $BOOT,失败不留半成品(:942-957);
3. **退出码 77**:插件表达"本插件不适用,跳过其余"的正面语义(exec-util.c:192-195);
4. **TOKEN 同源**:与 bootctl 共享 boot-entry.c 解析,条目命名永不漂移(boot-entry.c:143-218);
5. **jinja2 注入版本**:60-ukify 的 --osrel 等参数随 systemd 版本生成(:14-28);
6. **KERNEL_INSTALL_PLUGINS**:测试与特殊发行版的整表覆盖口(:532)。

## 23.4 FAQ

**Q1:插件是内置的吗?**
不是,是 /etc/kernel/install.d 与 /usr/lib/kernel/install.d 下的可执行 *.install 脚本。

**Q2:插件收到什么参数?**
add|remove VERSION ENTRY_DIR_ABS [KERNEL_IMAGE [INITRD…]]+12 项 env(:1082-1136)。

**Q3:staging 在哪?**
var_tmp 下 mkdtemp 的 kernel-install.staging.XXXXXX(:942-957)。

**Q4:退出码 77 什么意思?**
成功且跳过剩余插件(EXIT_SKIP_REMAINING)(exec-util.c:30)。

**Q5:ENTRY-TOKEN 怎么定?**
entry-token 文件→machine-id→os-release IMAGE_ID=/ID=(boot-entry.c:143-218)。

**Q6:layout 有 off 吗?**
没有,只有 auto|uki|bls|other。

**Q7:remove 从 uname 推版本吗?**
刻意不推,必须显式给版本(:1420-1423)。

**Q8:还兼容 dracut 的 installkernel 吗?**
兼容层已删,只剩 argv[0]=installkernel 且忽略 MAP/DIR(:1387-1395)。

**Q9:60-ukify 产出什么?**
$STAGING_AREA/uki.efi,由 90-uki-copy 认领落 $BOOT(60-ukify.install.in:262)。

**Q10:inspect 动词做什么?**
用同一协议打印占位演示(含未展开的 XXXXXX staging 路径)(:1074-1076)。

## 23.5 小结与深挖方向

本章结论:**kernel-install=1,781 行 C 编排器+外部脚本插件协议+staging 两段式落盘;与 bootctl 共享 ENTRY-TOKEN 解析**。深挖:

1. 60-ukify.install.in 的 uki.conf 合并逻辑与 --epochs?(291 行 Python);
2. 90-loaderentry 的 Boot Count 尝试计数支持(243 行 sh);
3. KERNEL_INSTALL_BOOT_ENTRY_TYPE 与 Type#1/#2 的选择面;
4. conf_files_list_strv 的 masked 过滤实现(:765-770);
5. test-kernel-install.sh 的 77/42 退出码验证用例(test:446-453)。
