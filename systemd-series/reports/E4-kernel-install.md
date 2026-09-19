# 报告 E4 · kernel-install(systemd 卷四)

> 基线:1f66b52452879b68c32d79efdb9b97e4542ae7a4——kernel-install 是一个约 1781 行的 C 编排器,它自己不落任何引导文件:它解析 env/install.conf/machine-info 得出 ENTRY-TOKEN、BOOT_ROOT 与 layout,搭一个临时 staging 区,然后按文件名序执行 `/etc/kernel/install.d` 与 `/usr/lib/kernel/install.d` 下的 `*.install` 可执行插件(自带 4 个:50-depmod、60-ukify、90-loaderentry、90-uki-copy),由插件把内核/UKI/Type#1 条目写进 $BOOT。

## 1. 源码清单与总体定位

- 本 commit 的 src/kernel-install/ 共 10 个文件,逐行数(shown by `wc -l`):
  - kernel-install.c:1781 行,唯一的 C 源文件;
  - 50-depmod.install(60 行,POSIX sh)、90-uki-copy.install(134 行,sh);
  - 60-ukify.install.in(291 行,Python)、90-loaderentry.install.in(243 行,sh)——两者是 jinja2 模板,构建时注入 PROJECT_VERSION/VERSION_TAG 后安装(src/kernel-install/meson.build:14-28);
  - install.conf(12 行)、uki.conf(34 行):两个全注释的配置模板;
  - test-kernel-install.sh(453 行)、test-ukify-install.py(50 行)、meson.build(55 行)。
- **纠偏①**:不存在 `kernel-install-*.c`,也不存在 `plugins/` 子目录——插件从来不是内置 C 模块,而是独立可执行脚本;C 核只负责"列插件"与"执行插件"(kernel-install.c:757-775,1196-1205)。
- 插件安装路径:根 meson.build 定义 `kerneldir = prefixdir/'lib/kernel'`、`kernelinstalldir = kerneldir/'install.d'`(meson.build:183-184),即 /usr/lib/kernel/install.d/;
- sysconf 侧只建空目录 /etc/kernel/install.d(src/kernel-install/meson.build:49-51),供管理员放 drop-in 插件;
- 二进制条件编译:ENABLE_KERNEL_INSTALL 才构建(src/kernel-install/meson.build:3-12)。

```bash
# src/kernel-install/meson.build:14-20(节选)
ukify_install = custom_target(
        input : '60-ukify.install.in',
        output : '60-ukify.install',
        command : [jinja2_cmdline, '@INPUT@', '@OUTPUT@'],
        install : want_kernel_install and want_ukify,
        install_mode : 'rwxr-xr-x',
        install_dir : kernelinstalldir)
```

## 2. 插件体系:发现、调用协议、staging、verbose 与退出码

### 2.1 发现规则

- 后缀 `.install`,必须可执行、必须普通文件、过滤 masked(kernel-install.c:765-770):

```c
// kernel-install.c:765-770
r = conf_files_list_strv_at(
                &c->plugins,
                ".install",
                c->rfd,
                CONF_FILES_EXECUTABLE | CONF_FILES_REGULAR | CONF_FILES_FILTER_MASKED | CONF_FILES_WARN,
                STRV_MAKE_CONST("/etc/kernel/install.d", "/usr/lib/kernel/install.d"));
```

- 目录优先级:/etc/kernel/install.d 在前,/usr/lib/kernel/install.d 在后(kernel-install.c:770)。
- 环境变量 `KERNEL_INSTALL_PLUGINS` 可整表覆盖插件清单(kernel-install.c:532,505-519),值按空白切分并去引号;测试即靠它注入指定插件(test-kernel-install.sh:55-61)。

### 2.2 调用协议:argv 与 env

- argv(插件路径之后)由 context_build_arguments 构造(kernel-install.c:1082-1107):

```c
// kernel-install.c:1082-1096
a = strv_new("dummy-arg", /* to make strv_free() works for this variable. */
             verb,
             c->version ?: "KERNEL_VERSION",
             c->entry_dir);
...
        r = strv_extend(&a, c->kernel);
        r = strv_extend_strv(&a, c->initrds, /* filter_duplicates= */ false);
```

- 即:`PLUGIN add|remove KERNEL_VERSION ENTRY_DIR_ABS [KERNEL_IMAGE [INITRD…]]`;
- ENTRY_DIR_ABS = `$BOOT_ROOT/$ENTRY_TOKEN/$KERNEL_VERSION`(构造在 kernel-install.c:963-978);
- inspect 动词用同一协议的占位演示:verb 字符串为 `add|remove`、镜像为 `[KERNEL_IMAGE]`、initrd 为 `[INITRD...]`(kernel-install.c:1074-1076,1098-1105)。
- env 共 12 项(kernel-install.c:1124-1136):`LC_COLLATE` + `KERNEL_INSTALL_VERBOSE`、`KERNEL_INSTALL_IMAGE_TYPE`、`KERNEL_INSTALL_MACHINE_ID`、`KERNEL_INSTALL_ENTRY_TOKEN`、`KERNEL_INSTALL_BOOT_ROOT`、`KERNEL_INSTALL_LAYOUT`、`KERNEL_INSTALL_INITRD_GENERATOR`、`KERNEL_INSTALL_UKI_GENERATOR`、`KERNEL_INSTALL_BOOT_ENTRY_TYPE`、`KERNEL_INSTALL_STAGING_AREA`、`KERNEL_INSTALL_ENTRY_NAME`。
- 执行时以 DEBUG 日志打印插件清单、完整 env 与 argv(kernel-install.c:1185-1194)。

### 2.3 staging 语义

- staging 区在 var_tmp 下 `mkdtemp` 生成,模板 `kernel-install.staging.XXXXXX`(kernel-install.c:942-957);
- inspect 动词只生成模板路径字符串、不建目录(kernel-install.c:951-953;test-kernel-install.sh:424 的 JSON 快照证实输出未展开的 `XXXXXX`);
- 插件把中间产物写 staging,最终由 90-* 插件拷入 $BOOT:
  - 60-ukify 固定输出 `$STAGING_AREA/uki.efi`(60-ukify.install.in:262-263);
  - 90-uki-copy 认领 `$STAGING_AREA/uki.efi` 与 `.extra.d` 附加目录(90-uki-copy.install:92-105);
  - 90-loaderentry 把 staging 里的 `microcode*` 与 `initrd*` 拷入 ENTRY_DIR(90-loaderentry.install.in:180-197)。
- initrd 参与顺序(两插件一致):staging/microcode* → 命令行 initrds → staging/initrd*(60-ukify.install.in:235-240;90-loaderentry.install.in:180)。

### 2.4 verbose 语义

- `-v/--verbose` 做两件事:日志级别调到 DEBUG(kernel-install.c:1636-1639)+ 导出 `KERNEL_INSTALL_VERBOSE=1`(kernel-install.c:1126);
- 插件据此回显将执行的命令:50-depmod.install:32(`+depmod -a $VERSION`)、60-ukify.install.in:34,47-49、90-loaderentry.install.in:30,58,117,191,204。

### 2.5 退出码协议

- 插件串行执行,旗标 EXEC_DIR_SKIP_REMAINING(kernel-install.c:1196-1205);
- 退出码 77 = EXIT_SKIP_REMAINING:视为成功且跳过所有剩余插件(src/shared/exec-util.c:30,192-195):

```c
// src/shared/exec-util.c:192-197
if (FLAGS_SET(flags, EXEC_DIR_SKIP_REMAINING) && r == EXIT_SKIP_REMAINING) {
        log_info("%s succeeded with exit status %i, not executing remaining executables.", *path, r);
        skip_remaining = true;
} else if (FLAGS_SET(flags, EXEC_DIR_IGNORE_ERRORS))
        log_warning("%s failed with exit status %i, ignoring.", *path, r);
else {
        log_error("%s failed with exit status %i.", *path, r);
        return r;
}
```

- kernel-install.c:1211 注释明确返回值语义:"0 on success, positive exit code on plugin failure, negative errno on other failures";
- 进程退出码等于失败插件的退出码(DEFINE_MAIN_FUNCTION_WITH_POSITIVE_FAILURE,kernel-install.c:1781);测试验证 77 跳过、42 传播(test-kernel-install.sh:433-453)。

## 3. 动词与完整路径

- 五个动词:add(kernel-install.c:1284)、add-all(1315)、remove(1397)、inspect(1435,VERB_DEFAULT 默认动词)、list(1554);另有 argv[0]=installkernel 兼容入口(1775-1776)。

### 3.1 add

- 签名 `add [[[KERNEL-VERSION] KERNEL-IMAGE] [INITRD …]]`(kernel-install.c:1284-1285);
- VERSION 缺省取 `uname().release`(kernel-install.c:1250-1254);
- KERNEL-IMAGE 缺省查 `/usr/lib/modules/$VERSION/vmlinuz`(kernel_from_version,kernel-install.c:1219-1238),不存在则报错提示显式指定路径(1232);
- **纠偏②**:只给一个位置参数时,它被解释为 KERNEL-IMAGE 而非 VERSION——想只给版本需以空串或 `-` 占位(kernel-install.c:1450-1454 同样说明):

```c
// kernel-install.c:1304-1310
/* We use the same order of arguments that "inspect" introduced, i.e. if only on argument is
 * specified we take it as the kernel path, not the version, i.e. it's the first argument that is
 * optional, not the 2nd. */
version = argc > 2 ? empty_or_dash_to_null(argv[1]) : NULL;
kernel = argc > 2 ? empty_or_dash_to_null(argv[2]) :
        (argc > 1 ? empty_or_dash_to_null(argv[1]) : NULL);
initrds = strv_skip(argv, 3);
```
- `add`/`remove` 拒绝 `--root=`/`--image=`(EOPNOTSUPP,kernel-install.c:1293-1294,1405-1406);`$KERNEL_INSTALL_BYPASS=1` 时静默成功返回(kernel-install.c:1215-1217,1296-1297;src/shared/verbs.c:51-69 should_bypass)。

### 3.2 add-all

- 扫 /usr/lib/modules/ 下每个含 `vmlinuz` 的版本逐个安装(kernel-install.c:1335-1377);
- 每轮先 `context_copy` 深拷贝上下文(kernel-install.c:172-245,1357-1361)——测试注释"exercises context_copy"(test-kernel-install.sh:359);
- 任一版本失败记录首个错误继续,全部成功数>0 才算有事发生;一个都没有则 ENOENT(kernel-install.c:1373-1384)。

### 3.3 remove

- 签名 `remove KERNEL-VERSION`(kernel-install.c:1397-1398);
- **纠偏③**:不从 uname 推导版本,注释明说"we don't want to make it too easy to uninstall your running kernel, as a safety precaution"(kernel-install.c:1420-1423);
- 多余参数仅 debug 提示后忽略(kernel-install.c:1408-1410;#28448,test-kernel-install.sh:94-104)。

### 3.4 inspect(默认动词)

- 跑完整 prepare 流程(含插件清单、env、argv 构造),再输出竖表(kernel-install.c:1485-1551);
- 字段:Machine ID、Kernel Image Type、Layout、Boot Root、Entry Token Type/Token、Entry Name Format/Name、Entry Directory、Kernel Version、Kernel、Initrds、Initrd/UKI Generator、Plugins、Plugin Environment/Arguments(kernel-install.c:1493-1535);
- JSON 字段名由表头去空格生成,如 `EntryNameFormat`、`EntryDirectory`(kernel-install.c:1542-1548;test-kernel-install.sh:395-428 全量快照);
- `--root=`/`--image=` 仅 inspect/list 支持:--image 经 mount_image_privately_interactively 私有挂载后转成 arg_root(kernel-install.c:1753-1773)。

### 3.5 list

- 列 /usr/lib/modules/ 各版本及 vmlinuz 存在性(对勾列),按版本排序,支持 --json(kernel-install.c:1554-1611)。

## 4. ENTRY-TOKEN、machine-id 与 bootctl 条目命名的衔接(衔接卷四 19)

- machine-id 决策链(所有 context_set_* 均为"已设则跳过"的先到先得语义):
  1. `$MACHINE_ID` 环境变量(kernel-install.c:529);
  2. install.conf 的 `MACHINE_ID=`(kernel-install.c:558);
  3. /etc/machine-info 的 `KERNEL_INSTALL_MACHINE_ID=`(kernel-install.c:601-606,注释"for compatibility");
  4. /etc/machine-id(kernel-install.c:611-624);
  5. 都没有 → `sd_id128_randomize` 现场随机,只存内存不落盘(`machine_id_is_random`,kernel-install.c:626-647)。
- ENTRY-TOKEN 解析在共享代码 boot_entry_token_ensure_at(kernel-install.c:743-749):
  - AUTO 顺序:/etc/kernel(或 /usr/lib/kernel)的 `entry-token` 文件 → 非随机 machine-id → os-release `IMAGE_ID=`/`ID=` → 随机 machine-id 排最后(src/shared/boot-entry.c:164-186;entry_token_load 在 boot-entry.c:80-96);
  - 显式类型:machine-id / os-image-id / os-id / literal:值(枚举 src/shared/boot-entry.h:9-13;CLI 解析 boot-entry.c:243-277)。
- **纠偏④**:目录命名有两层,不把 machine-id 写死。ENTRY_DIR 的拼接(kernel-install.c:963-977):

```c
// kernel-install.c:969-977
if (c->entry_dir)
        return 0;

c->entry_dir = path_join(c->boot_root, c->entry_token, c->version ?: "KERNEL_VERSION");
if (!c->entry_dir)
        return log_oom();

log_debug("Using ENTRY_DIR=%s", c->entry_dir);
```

  - ENTRY_DIR = `$BOOT_ROOT/$ENTRY_TOKEN/$KERNEL_VERSION`(kernel-install.c:972)——放内核/initrd/dtb 文件;
  - 条目名 ENTRY_NAME 由格式串决定,默认 `%e-%v`(token-版本,kernel-install.c:134),可经 install.conf `entry_name_format=`/env `KERNEL_INSTALL_ENTRY_NAME_FORMAT` 覆盖(kernel-install.c:533,563),specifier 表支持 %e/%m/%v/%a/%A/%B/%H/%l/%q/%M/%o/%w/%W(kernel-install.c:365-380)。
- 90-loaderentry 写 `$BOOT_ROOT/loader/entries/$ENTRY_NAME[+TRIES].conf`(90-loaderentry.install.in:49,127);90-uki-copy 写 `$BOOT_ROOT/EFI/Linux/$ENTRY_NAME[+TRIES].efi`(90-uki-copy.install:33,83,85)。
- 与 bootctl 的衔接:bootctl 共用同一 boot-entry.c(`parse_boot_entry_token_type`,src/bootctl/bootctl.c:67,496-497),因此 bootctl list/unlink/cleanup 与 kernel-install 对同一批文件达成一致;test-kernel-install.sh:176-206 实测 bootctl cleanup 会删未被条目引用的 initrd、unlink 最后一条目时连带删资产文件。
- 长度预留:ENTRY_NAME 上限 `NAME_MAX - strlen(".efi.extra.d")`(kernel-install.c:131-132,385-391),为 `.efi.extra.d` 附加目录与 `+TRIES` 后缀留空间。
- token==machine-id 时的稳定性钩子:cmdline 追加 `systemd.machine_id=`(90-loaderentry.install.in:104-106;60-ukify.install.in:224-226),Type#1 条目写 `machine-id` 字段(90-loaderentry.install.in:210-213)。

## 5. layout 选项与 BOOT_ROOT 探测

### 5.1 layout 四值

- **纠偏⑤**:取值是 `auto|uki|bls|other`——没有 "ubl",也没有 "off"(kernel-install.c:86-102);无法识别的字符串归入 other 并原样保存(context_set_layout,kernel-install.c:276-302);
- 配置来源优先级(先到先得):env → install.conf → /etc/machine-info 的 `KERNEL_INSTALL_LAYOUT=`(kernel-install.c:791-807,560,607);
- install.conf 模板只注释 `layout=bls|other|...`(install.conf:10);实际读取的 6 个键为 MACHINE_ID/BOOT_ROOT/layout/initrd_generator/uki_generator/entry_name_format(src/shared/kernel-config.c:23-31);
- install.conf 搜索:`$KERNEL_INSTALL_CONF_ROOT/install.conf`+`install.conf.d/` dropins,否则标准 `kernel/install.conf`+dropins(kernel-config.c:36-63)。

### 5.2 auto 布局推断

```c
// kernel-install.c:871-876
if (c->kernel_image_type == KERNEL_IMAGE_TYPE_UKI) {
        c->layout = LAYOUT_UKI;
        ...
        return 0;
}
```

- 第一级:传入镜像本身是 UKI(pe_is_uki 判定,src/shared/kernel-image.c:118-156)→ uki;
- 第二级:`$BOOT_ROOT/loader/entries.srel` 首行 `type1` → bls;其他值 → other("let's stay away from it",kernel-install.c:894-903);
- 第三级:`$BOOT_ROOT/$ENTRY_TOKEN` 目录已存在 → bls(kernel-install.c:918-923);全无线索 → other(kernel-install.c:927-931);
- 镜像类型四值:unknown/uki/addon/pe(src/shared/kernel-image.h:7-11),由 PE 头+节区判定(kernel-image.c:131-169)。

### 5.3 layout 如何驱动插件

- 60-ukify 的三重门槛:镜像不是现成 UKI、`KERNEL_INSTALL_LAYOUT == 'uki'`、`KERNEL_INSTALL_UKI_GENERATOR == 'ukify'`(60-ukify.install.in:112-132);
- 90-loaderentry:`KERNEL_INSTALL_LAYOUT != "bls"` 即退出(90-loaderentry.install.in:29-33);
- 90-uki-copy:add 路径要求 `uki`(90-uki-copy.install:56),**纠偏⑥**:remove 路径不检查 layout(35-54)——bls 布局卸载时也会无条件清理 `$ENTRY_NAME*.efi`、`.efi.extra.d/` 与 `+*.efi`(44-47)。

### 5.4 BOOT_ROOT 探测

- 顺序(kernel-install.c:699-731):显式配置(env `BOOT_ROOT`/install.conf `BOOT_ROOT=`)→ **XBOOTLDR 分区优先**(find_xbootldr_and_warn_at,649-672)→ ESP(find_esp_and_warn_at,674-697)→ 兜底 `/boot`(718-727);
- `--esp-path=`/`--boot-path=` 可定向(kernel-install.c:1641-1651);
- ENTRY_DIR 建不建目录:`--make-entry-directory=` 三态 auto/yes/no(kernel-install.c:1653-1663);缺省 auto = 仅 layout==bls 时建(kernel-install.c:980-990,注释指这是对旧版 00-entry-directory 插件的兼容);remove 时对称删除(kernel-install.c:1013-1047);测试覆盖全部六种组合(test-kernel-install.sh:209-278);
- `--entry-type=type1|type2|all` 经 `KERNEL_INSTALL_BOOT_ENTRY_TYPE` 传给插件,用于部分卸载保护(kernel-install.c:1671-1683):50-depmod 在多类型并存时不删 modules.*(50-depmod.install:36-40),90-loaderentry 在 type2 且 /lib/modules 下 vmlinuz 仍在时不删条目(90-loaderentry.install.in:53-57),90-uki-copy 在 type1 时不删 UKI(90-uki-copy.install:37-41)。

## 6. 与 mkinitrd/dracut 传统工具的兼容层

- **纠偏⑦**:本 commit 源码树中没有任何 mkinitrd/dracut 兼容脚本(src/ 下 grep "mkinitrd" 零命中;历史上的 50-dracut.install 已不在树上);
- 唯一传统兼容面是内核 Makefile 的 `make install` 接口(kernel-install.c:70-72 COMMAND footer):

```c
// kernel-install.c:1387-1395
static int run_as_installkernel(char **args) {
        /* kernel's install.sh invokes us as
         *   /sbin/installkernel <version> <vmlinuz> <map> <installation-dir>
         * We ignore the last two arguments. */
        if (strv_length(args) < 2)
                return log_error_errno(SYNTHETIC_ERRNO(EINVAL), ...);
        return verb_add(3, STRV_MAKE("add", args[0], args[1]), 0, NULL);
}
```

- 触发方式:argv[0] 为 installkernel(kernel-install.c:1775-1776 invoked_as);测试用软链模拟(test-kernel-install.sh:113-115);
- initrd 生成完全外包:`install.conf` 的 `initrd_generator=`/`uki_generator=` 是声明性转口——kernel-install 只把值原样导出为 `KERNEL_INSTALL_INITRD_GENERATOR`/`KERNEL_INSTALL_UKI_GENERATOR`(kernel-install.c:1132-1133),调不调 dracut 由发行版自装插件决定;
- 对传统 initrd 落点的兜底:无 initrd 参数时,90-loaderentry 依次找 `$ENTRY_DIR/initrd` 与 `$BOOT_ROOT/initramfs-$KERNEL_VERSION.img`(后者即 dracut 传统命名,90-loaderentry.install.in:229-237);
- 60-ukify 对 ukify 的调用方式特殊:不做子进程 fork,而是把 ukify 脚本当 Python 模块 load 后直接调 apply_config/finalize_options/check_inputs/make_uki(60-ukify.install.in:243-275);ukify 路径可用 `KERNEL_INSTALL_UKIFY`、stub 用 `KERNEL_INSTALL_BOOT_STUB` 覆盖(39-40)。

## 7. 数据流:make install → 插件链 → $BOOT

```
make install / RPM 脚本 / 手工
   │  内核 install.sh: /sbin/installkernel VERSION VMLINUZ [MAP] [DIR](MAP、DIR 被忽略)
   ▼
kernel-install  [argv0=installkernel → run_as_installkernel(kernel-install.c:1387) → verb_add]
   │ ①env: MACHINE_ID/BOOT_ROOT/KERNEL_INSTALL_{CONF_ROOT,PLUGINS,ENTRY_NAME_FORMAT,...}(:526)
   │ ②install.conf: MACHINE_ID/BOOT_ROOT/layout/initrd_generator/uki_generator/entry_name_format(:537)
   │ ③/etc/machine-info 的 KERNEL_INSTALL_MACHINE_ID、KERNEL_INSTALL_LAYOUT(:569)
   │ ④machine-id: /etc/machine-id,缺失→内存随机(:626)  BOOT_ROOT: XBOOTLDR→ESP→/boot(:699)
   │ ⑤ENTRY-TOKEN: /etc/kernel/entry-token→machine-id→os-release IMAGE_ID=/ID=(:733+boot-entry.c:164)
   │ ⑥layout(auto): 镜像是UKI?→entries.srel→$BOOT/$TOKEN 存在?(:858)  staging: mkdtemp(:934)
   ▼
$TMPDIR/kernel-install.staging.XXXXXX   插件按文件名序 exec,argv=VER ENTRY_DIR_ABS KERNEL_IMAGE INITRD…
   │  env=KERNEL_INSTALL_{VERBOSE,IMAGE_TYPE,MACHINE_ID,ENTRY_TOKEN,BOOT_ROOT,LAYOUT,
   │      INITRD_GENERATOR,UKI_GENERATOR,BOOT_ENTRY_TYPE,STAGING_AREA,ENTRY_NAME}(:1124)
   ├─ 50-depmod        depmod -a VERSION → /lib/modules/…(remove 清 modules.*)(50-depmod:28-55)
   ├─ 60-ukify         layout=uki: import ukify 模块 → $STAGING/uki.efi(60-ukify:250-275)
   ├─ 90-loaderentry   layout=bls:  拷 linux/initrd/devicetree → $BOOT/$TOKEN/$VER/
   │                                写 $BOOT/loader/entries/$ENTRY_NAME[+TRIES].conf(Type#1)(:49,127)
   └─ 90-uki-copy      layout=uki:  $STAGING/uki.efi(或 .efi 后缀镜像)→ $BOOT/EFI/Linux/
                                 $ENTRY_NAME[+TRIES].efi + $ENTRY_NAME.efi.extra.d/(:33,83-92)
   │  插件退出码: 0=继续;77=跳过其余插件(视为成功);其他非零=中止并向上传播(exec-util.c:192)
   ▼
$BOOT/$ENTRY-TOKEN/$KERNEL-VERSION/*(Type#1 资产) 与/或 $BOOT/EFI/Linux/*.efi(Type#2 UKI)
remove: 同一插件链以 COMMAND=remove 反向清理,最后 kernel-install 删 $ENTRY_DIR(:1207)
```

设计动机:

1. **编排与策略分离**:C 核只定协议(argv/env/staging/退出码),UKI 怎么签、initrd 用谁生成全在可替换插件里(kernel-install.c:1196-1205 vs 60-ukify.install.in 全文)。
2. **staging 区保证原子性观感**:所有生成物先落临时目录、由序号最大的 90-* 插件一次性拷入 $BOOT,失败不留半成品(kernel-install.c:934-961;60-ukify.install.in:262-263)。
3. **与 bootctl 共享命名底座**:ENTRY-TOKEN/entry_name_format 逻辑放 src/shared/boot-entry.c,bootctl 与 kernel-install 对同一批文件达成一致(src/bootctl/bootctl.c:67,496-497;test-kernel-install.sh:176-206)。
4. **auto layout 让既有系统不被破坏**:entries.srel → token 目录 → other 的降级链使新装机默认 UKI、老 BLS 系统维持 Type#1,未知规范则避让(kernel-install.c:865-931)。
5. **安全保守的 remove**:不从 uname 推版本、--entry-type 限定部分卸载、depmod 文件在多类型并存时不删(kernel-install.c:1420-1423;50-depmod.install:36-40)。
6. **可旁路可演练**:`KERNEL_INSTALL_BYPASS` 服务打包器 chroot 场景;inspect(默认动词)输出 JSON 全景供脚本预检(kernel-install.c:1215-1217,1435-1551)。

## FAQ 候选

1. `kernel-install` 是不是把内核"安装"进 ESP 的工具?——它自己一个字节都不写引导区,只搭 env+staging 并按序执行 *.install 插件(kernel-install.c:1196-1205)。
2. 插件是什么形态?——/etc/kernel/install.d 与 /usr/lib/kernel/install.d 下可执行的 `*.install` 脚本,可用 `KERNEL_INSTALL_PLUGINS` 完全替换(kernel-install.c:765-770,505-519)。
3. `60-ukify` 是如何调用 ukify 的?——不 fork 子进程,而是把 ukify 脚本当 Python 模块 load 后直接调 make_uki(60-ukify.install.in:243-275)。
4. UKI 为什么固定叫 uki.efi?——插件约定输出 `$STAGING_AREA/uki.efi`,90-uki-copy 按此名拾取(60-ukify.install.in:262-263;90-uki-copy.install:92)。
5. 一个位置参数的 add 到底装哪个版本?——该参数是内核镜像路径而非版本,想只给版本需用 `-` 占位(kernel-install.c:1304-1310)。
6. 没有 /etc/machine-id 时会怎样?——现场随机一个(仅内存不落盘),且 token 优先用 os-release ID/IMAGE_ID(kernel-install.c:626-647;boot-entry.c:169-183)。
7. 插件失败会中断吗?——非 77 的非零退出码立即中止插件链并以同码退出;77 只跳过后续插件(exec-util.c:192-197)。
8. `layout=other` 是错误吗?——不是,表示"未知规范占有 /loader/entries,别碰",entries.srel 非 type1 或全无线索时都会得到它(kernel-install.c:899-931)。
9. 启动计数(+TRIES)在哪实现?——在两个 90-* 插件里读 /etc/kernel/tries 给条目改名,kernel-install 核心不知情(90-loaderentry.install.in:108-128;90-uki-copy.install:63-86)。
10. dracut/mkinitrd 还被内置支持吗?——本 commit 已无任何 dracut/mkinitrd 脚本,只剩 installkernel argv[0] 兼容与 initramfs-*.img 探测(kernel-install.c:1387-1395;90-loaderentry.install.in:234-236)。

## 深挖方向

1. `context_copy` 与 staging 归属:add-all 每轮拷贝上下文但共享同一 staging 路径(kernel-install.c:228,1357-1361),inspect 不 free 而其他动词 rm_rf_physical(160-164)——多版本并发写 staging 的隔离性值得实证。
2. `KERNEL_INSTALL_IMAGE_TYPE` 的 addon/pe 值(src/shared/kernel-image.h:7-11)的安装路径:60-ukify 见 `uki` 即退(60-ukify.install.in:113-117),addon 镜像由哪条插件链处理在本目录无答案。
3. 90-uki-copy 的 `$KERNEL_IMAGE.extra.d` 附加目录(90-uki-copy.install:120-127)与 systemd-stub 侧 .extra.d 加载的对接(衔接卷四 20)。
4. `entries.srel` 的写入者是谁(bootctl?其他组件?),以及 90-uki-copy"add 查 layout、remove 不查"的不对称(56 vs 35-54)是否有意设计。
5. meson 裁剪矩阵:`60-ukify.install` 仅在 ENABLE_KERNEL_INSTALL 且 want_ukify 时安装(src/kernel-install/meson.build:14-20),发行版不带 ukify 时 layout=uki 的退化行为。

## 正文蒸馏要点

1. kernel-install 是纯编排器:C 核不含任何布局/签名逻辑,全部委托 `/etc/kernel/install.d`+`/usr/lib/kernel/install.d` 的可执行 `*.install` 插件(kernel-install.c:765-770,1196-1205)。
2. 本 commit 自带且仅带 4 个插件:50-depmod(sh)、60-ukify(Python,.in 渲染)、90-loaderentry(sh,.in 渲染)、90-uki-copy(sh)(src/kernel-install/meson.build:14-39)。
3. 插件协议:argv 为 `add|remove KERNEL_VERSION ENTRY_DIR_ABS [KERNEL_IMAGE [INITRD…]]`,env 携带 11 个 KERNEL_INSTALL_* 变量(kernel-install.c:1082-1107,1124-1136)。
4. staging 区是协议核心:生成物先写 `$TMPDIR/kernel-install.staging.XXXXXX`,由 90-* 插件最终落 $BOOT;inspect 只演示不落盘(kernel-install.c:934-961)。
5. `-v` 的本质是导出 `KERNEL_INSTALL_VERBOSE=1` 让插件自己回显命令(kernel-install.c:1126;50-depmod.install:32)。
6. 退出码 77=成功且跳过剩余插件,其他非零码中止并原样上抛为进程退出码(exec-util.c:30,192-197;test-kernel-install.sh:446-453)。
7. 条目命名两层:$BOOT/$ENTRY_TOKEN/$KERNEL_VERSION/(ENTRY_DIR,放文件)与 $ENTRY_NAME=%e-%v 默认格式(放 loader/entries/*.conf 或 EFI/Linux/*.efi)(kernel-install.c:134,972;90-loaderentry.install.in:49)。
8. ENTRY-TOKEN 解析是 bootctl 与 kernel-install 共享的代码,token 类型含 literal:值(boot-entry.c:143-218;bootctl.c:67,496-497)。
9. BOOT_ROOT 探测序:显式配置 → XBOOTLDR → ESP → /boot,XBOOTLDR 优先于 ESP(kernel-install.c:699-731)。
10. layout 取值 auto/uki/bls/other(无 off/ubl);auto 由"镜像是 UKI → entries.srel → token 目录存在"三级推断,无线索即 other(kernel-install.c:86-100,858-931)。
11. remove 不从 uname 推导版本是显式安全设计;--entry-type 与 --make-entry-directory 三态控制部分卸载面(kernel-install.c:1420-1423,1653-1683)。
12. 唯一传统兼容是 argv[0]=installkernel(内核 make install,忽略 MAP/DIR);mkinitrd/dracut 插件本 commit 已不存在(kernel-install.c:1387-1395,1727-1734)。
