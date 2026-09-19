# 报告 D4 · sysext 与 confext(systemd 卷四)

> 基线:1f66b524(2026-09-14)。一句话:sysext/confext 是**同一个二进制的两个身份**——systemd-confext 只是 systemd-sysext 的 argv[0] 符号链接(src/sysext/meson.build:19-21),全部合并逻辑都在 3319 行的 src/sysext/sysext.c 里:在私有 mount namespace 的 /run/systemd/sysext tmpfs 工作区中组装 overlayfs(扩展层按版本降序叠在宿主 /usr 之上、元目录 .systemd-sysext 压顶),再用 MS_BIND 把成品移入宿主命名空间;confext 仅是"换一套环境变量名 + 层级 /etc + 更紧挂载标志"的参数化重放。

## 1. 一个二进制、两个身份:身份判定、配置汇流与镜像形态

身份在 `run()` 开头一锤定音(src/sysext/sysext.c:3254):

```c
// src/sysext/sysext.c:3254
arg_image_class = invoked_as(argv, "systemd-confext") ? IMAGE_CONFEXT : IMAGE_SYSEXT;
```

安装侧 confext 不是独立可执行文件(src/sysext/meson.build:18-21):

```c
// src/sysext/meson.build:18-21
if conf.get('ENABLE_SYSEXT') == 1
        install_symlink('systemd-confext',
                        pointing_to : 'systemd-sysext',
                        install_dir : bindir)
```

随后一切差异都查表 `image_class_info[]`(src/sysext/sysext.c:149-192),这张表是全文的钥匙:

```c
// src/sysext/sysext.c:164-191(节选)
[IMAGE_SYSEXT] = {
        .short_identifier = "sysext",
        .polkit_rw_action_id = "io.systemd.sysext.manage",
        .dot_directory_name = ".systemd-sysext",
        .level_env = "SYSEXT_LEVEL",
        .scope_env = "SYSEXT_SCOPE",
        .name_env = "SYSTEMD_SYSEXT_HIERARCHIES",
        .default_image_policy = &image_policy_sysext,
        .default_mount_flags = MS_RDONLY|MS_NODEV,
},
[IMAGE_CONFEXT] = {
        .short_identifier = "confext",
        .dot_directory_name = ".systemd-confext",
        .default_mount_flags = MS_RDONLY|MS_NODEV|MS_NOSUID|MS_NOEXEC,
}
```

环境变量五组(SYSEXT_LEVEL/SYSEXT_SCOPE/SYSTEMD_SYSEXT_HIERARCHIES/SYSTEMD_SYSEXT_MUTABLE_MODE/SYSTEMD_SYSEXT_OVERLAYFS_MOUNT_OPTIONS)由 `parse_env_image_class_config` 以 `secure_getenv` 读取(src/sysext/sysext.c:235-256)。CLI 描述也按身份双写(133-146):sysext "Merge system extension images into /usr/ and /opt/.",confext "Merge configuration extension images into /etc/."。

配置汇流顺序是"配置文件最低、环境变量居中、argv 最高":`context_from_cmdline` 先吸收 argv 与 env(src/sysext/sysext.c:308-348),`parse_config_file` 只填未被前者初始化的字段,注释明言 "Configuration has the lowest priority"(292-303);配置文件路径 `systemd/sysext.conf`(confext 为 confext.conf),节名 [SysExt]/[ConfExt],目前仅有 `Mutable=` 与 `ImagePolicy=` 两键(267-275)。另有 `--root=` 一旦给出即强制 `arg_no_reload`(3161-3167),Varlink 调用由 `sd_varlink_invocation` 探测(3232-3236)。内核命令行门控:`systemd.sysext=`/`systemd.confext=`(initrd 中按是否带 `--root=` 加 `rd.` 前缀,注释强调两种前缀语义不同、不可剥除,3261-3265)置 0 时**仅拒绝 systemd 代为调用**,手工执行不受影响(3267-3275)。

镜像支持四种 `Image` 类型:目录、btrfs 子卷、raw 磁盘镜像(`.raw` 后缀判定,src/shared/discover-image.c:622)、块设备(src/shared/discover-image.c:575、605、645、705);man 页将其归为"目录/子卷、GPT 分区 DDI、无分区表裸文件系统(如 erofs/squashfs/ext4)"三种用户口径(man/systemd-sysext.xml:92-98)。merge 时目录/子卷走只读 bind 重挂(src/sysext/sysext.c:2047-2054),raw/block 走 loop device + dissect + verity 签名(src/sysext/sysext.c:2058-2150),非 `--force` 时对裸 fs 镜像要求 `DISSECT_IMAGE_VALIDATE_OS_EXT`(2080-2081),dissect 侧的类检查 miss 报 ENOCSI(src/shared/dissect-image.c:5048-5060)。搜索路径上 sysext 是 /etc/extensions、/run/extensions、/var/lib/extensions(主目录),**刻意不含 /usr**;confext 反而允许 /usr/local/lib/confexts、/usr/lib/confexts(src/shared/discover-image.c:75-86),理由写在注释里:扩展要扩展 /usr,放进 /usr 会与 overlayfs "lowerdir 互为父子" 检查撞出 -ELOOP(75-78)。镜像名后缀 `.sysext`/`.confext` 会被剥成 pretty 名(107-110)。initrd 下追加 /.extra/sysext、/.extra/global_sysext 等由 systemd-stub 投放的目录(91-105),并对其实施更严的签名策略(src/sysext/sysext.c:1760-1773):`/.extra/` 下其余路径直接 `image_policy_deny`(1771-1772)。

## 2. merge 主流程:私有 mount ns、tmpfs 工作区与 overlayfs 组装

merge/unmerge 都 fork 出独立 mount namespace 的子进程完成(src/sysext/sysext.c:2506-2512、1929-1944),且 merge/unmerge 动词先验 `CAP_SYS_ADMIN`(2703-2707、2825-2829)。`merge_subprocess` 的完整步骤按序如下(行号均在 src/sysext/sysext.c):

1. `--root=` 给出时先 chase 解析根目录(1979-1983);
2. /run 置 MS_SLAVE(1989)并创建、挂载 tmpfs 工作区(1994-2004);
3. 读宿主 os-release 四键,`ID` 为空即 EINVAL(2007-2018);
4. 逐镜像挂载:目录/子卷先查禁忌内容(非 `--force`),再只读 bind(2021-2056);raw/block 走 loop + dissect + verity + 解密(2058-2153);
5. 非 `--force` 时按 initrd 与否取 scope "initrd"/"system",调 `extension_release_validate`,不过则计入 ignored(2155-2178);
6. 入选者记入 extensions 列表并构造 origin 指纹(2182-2251);
7. 零入选且非 mutable → 返回 MERGE_NOTHING_FOUND(2255-2261);
8. 版本排序并倒序生成层路径表(2263-2265、2377-2392),读旧 origin、写新 origin 并决定是否短路(2297-2364);
9. 先拆旧 overlay("拿到底层文件系统的引用"),每个层级建 meta/overlay/mh_workspace/submounts 四个工作点并 `merge_hierarchy`(2394-2460);
10. 成品 MS_BIND|MS_REC 移入宿主命名空间(2462-2490)。

目录/子卷的挂载方式(与 raw/block 的 dissect 路径相对):

```c
// src/sysext/sysext.c:2047-2054(节选)
r = mount_nofollow_verbose(LOG_ERR, img->path, p, NULL, MS_BIND, NULL);
...
/* Make this a read-only bind mount */
r = bind_remount_recursive(p, MS_RDONLY, MS_RDONLY, NULL);
```

origin 指纹的 JSON 组装(新旧比对即基于它):

```c
// src/sysext/sysext.c:2505-2524(节选)
r = pidref_safe_fork("(sd-merge)", FORK_DEATHSIG_SIGTERM|FORK_LOG|FORK_NEW_MOUNTNS, &pidref);
...
r = merge_subprocess(c, images, "/run/systemd/sysext");
/* Our namespace ceases to exist here, also implicitly detaching all temporary mounts ... */
if (r == MERGE_NOTHING_FOUND)  _exit(MERGE_EXIT_NOTHING_FOUND);   /* 123 */
if (r == MERGE_EXIT_SKIP_REFRESH) _exit(MERGE_EXIT_SKIP_REFRESH); /* 124 */
```

子进程里:把 /run 设为 MS_SLAVE 使临时挂载不外泄(1989),在工作区挂 tmpfs(2002,注释明言"内核随命名空间消亡自动清理 inodes"),读取宿主 os-release 的 ID/ID_LIKE/VERSION_ID/SYSEXT_LEVEL,且 ID 为空即 EINVAL 拒绝(2007-2018),逐个挂载并校验镜像(2021-2153),然后按 `strverscmp_improved` 版本升序排序(2263-2265)再**倒序**生成层路径表:`extensions[n_extensions - 1 - k]`(2382-2392)。期间为每个入选镜像构造 origin 指纹(2227-2245):verityHash 优先,缺失时回退 onMountId / fileHandle / inode+crtime+mtime,并刻意在"有强标识"时抑制弱标识(2229-2232 注释:confext 存于 /usr 时 mount ID 会因 sysext overlay 改变,不可靠)。刷新前先 `unmerge_hierarchy` 拆掉旧 overlay 以"拿到底层文件系统的引用"(2394-2419),再对每个层级调 `merge_hierarchy`(2442-2450)。工作区内部布局(2425-2438):

```c
// src/sysext/sysext.c:2425-2436(节选)
meta_path    = path_join(workspace, "meta", *h);   /* 元数据暂存 */
overlay_path = path_join(workspace, "overlay", *h);/* overlayfs 成品 */
merge_hierarchy_workspace = path_join(workspace, "mh_workspace", *h);
```

`merge_hierarchy` 的骨架是"选层 → 挂载 → 记账 → 只读"(src/sysext/sysext.c:1698-1734):`determine_used_extensions` 先筛掉在该层级缺目录或目录为空的扩展(1067-1104),一个都不剩且非 mutable 就整层跳过(1702-1703);随后 `overlayfs_paths_new` 解析层级与 mutable 目录(1020-1065),`determine_lower_dirs` 拼层序(1276-1303),`determine_upper_dir`/`determine_work_dir` 决定可写性(1305-1357),`mount_overlayfs_with_op` 真正挂载(1359-1420),`store_info_in_meta` 写元数据(1581-1639),最后 `make_mounts_read_only` 收紧(1641-1672)。成品经 `MS_BIND|MS_REC` 绑到宿主层级——因为只有 /run 被隔离,这一挂会传播回宿主命名空间(2462-2490,注释 "This is where things appear in the host namespace")。origin 指纹的 JSON 组装(新旧比对即基于它):

```c
// src/sysext/sysext.c:2324-2339(节选)
r = sd_json_buildo(&extensions_origin_json,
                   SD_JSON_BUILD_PAIR_OBJECT("mutable",
                                             SD_JSON_BUILD_PAIR_STRING("mode", mutable_mode_to_string(c->mutable)),
                                             ...),
                   SD_JSON_BUILD_PAIR_CONDITION(!!extensions_origin_entries,
                                                "extensions",
                                                SD_JSON_BUILD_VARIANT(extensions_origin_entries)));
...
r = sd_json_variant_format(extensions_origin_json, SD_JSON_FORMAT_PRETTY|SD_JSON_FORMAT_NEWLINE, &extensions_origin_content);
```

已合并时 merge 直接 EBUSY(2717-2721),Varlink 侧报 `io.systemd.sysext.AlreadyMerged`(2811)。合并结构总览:

```text
       合并后的 /usr(overlayfs,经 MS_BIND|MS_REC 进入宿主,sysext.c:2485)
      ┌────────────────────────────────────────────────────────────────┐
顶部  │ [meta 层] /run/systemd/sysext/meta/usr/.systemd-sysext/        │ ← 永远压顶
(upper)│   extensions | dev | origin | backing | work_dir              │   (1180-1183)
      │----------------------------------------------------------------│
      │ [扩展层,版本降序] myapp-2.1 → myapp-1.9 → myapp-1.2           │ ← 高版本遮蔽低版本
      │   各自的 <ext>/usr 子树(2385 倒序 + 862-863 注释)          │   (2263-2265 升序排序)
      │ [mutable=import 时:/var/lib/extensions.mutable/usr 插此]      │   (1106-1129)
      │----------------------------------------------------------------│
底部  │ [宿主层] /usr 基础系统树;其 st_dev 记入 backing 文件          │ ← (1253-1274)
      └────────────────────────────────────────────────────────────────┘
  mutable=yes/auto 时改用 upperdir=/var/lib/extensions.mutable/usr + workdir
  =<upperdir> 同盘父目录下的 .systemd-usr-workdir(1305-1335、811-850、839)
  confext 完全同构,仅层级换成 /etc、点目录 .systemd-confext(169、183)
```

## 3. 层序、元目录与只读/mutable 语义

层顺序由 `determine_lower_dirs` 三段式拼装(src/sysext/sysext.c:1276-1303):top 段先放 meta 路径并注明 "Put the meta path (i.e. our synthesized stuff) at the top of the layer stack"(1180-1183),随后按需插入 mutable import/ephemeral-import 层,注释"add it just below the meta path"(1106-1171);middle 段是已排序的扩展挂载点(1196-1204);bottom 段是宿主层级本身——若 mutable 目录与层级同 inode,宿主层级"将充当 upperdir"而退出 lowerdir,同时取其 st_dev 作 backing 记录(1206-1274,尤其 1242-1248)。结构体注释直接钉死语义:"lowest index is top lowerdir, highest index is bottom lowerdir"(852-864)。overlayfs 挂载参数在 `mount_overlayfs` 拼接,有 upperdir 时清掉 MS_RDONLY、补 workdir 并默认套用 `redirect_dir=on,noatime,metacopy=off,index=off`(src/sysext/sysext.c:743-760、128)。挂载前还会把顶层 chmod 成宿主层级的权限,否则合并树会变成 root:0700(1408-1413)。

元目录是识别"这是我们挂的"的关键:`is_our_mount_point` 读取 `<层级>/.systemd-sysext/dev` 里的主次设备号并与挂载点 st_dev 比对,注释言明这是为了"不把 tar 解包出来的离线副本误当活动合并树"(src/sysext/sysext.c:373-405)。元数据共五件:extensions 清单(1422-1453)、origin(1455-1477,注释:用于 refresh 的可跳过判定)、dev(1479-1510)、backing(1512-1539)、work_dir(1541-1579,ephemeral 模式不落盘、路径转义防换行),由 `store_info_in_meta` 统一落盘并把 meta 目录 mtime 定为合并时刻(1581-1639,尤其 1635 的 utimensat;status 列 "since" 即读它,2614-2621)。只读收紧分两路(src/sysext/sysext.c:1641-1672):不可变模式对整个 overlay 递归 bind 重挂 RO,注释自嘲 "Extra turbo safety";mutable 模式则单独把 .systemd-sysext 子目录 bind 成 RO,防止元数据被改导致 systemd 认不出自家挂载(1646-1653)。

mutable 六模式以 `/var/lib/extensions.mutable` 为写路由中枢(124):

```c
// src/sysext/sysext.c:85-92
static const char* const mutable_mode_table[_MUTABLE_MAX] = {
        [MUTABLE_NO]               = "no",
        [MUTABLE_YES]              = "yes",
        [MUTABLE_AUTO]             = "auto",
        [MUTABLE_IMPORT]           = "import",
        [MUTABLE_EPHEMERAL]        = "ephemeral",
        [MUTABLE_EPHEMERAL_IMPORT] = "ephemeral-import",
};
```

要点:auto 只在目录已存在时启用且校验目录 mode 必须与层级一致(src/sysext/sysext.c:915-941、981-988);ephemeral 系把 mutable 目录挪进 tmpfs 工作区、无视 root(966-971),unmerge 时由 work_dir 文件找回路径并 `rm_rf` 删除(1806-1824、1845-1849);hierarchy 与 mutable 目录互指会 ELOOP 拒绝(1118-1122);upperdir 所在文件系统只读时 EROFS 拒绝,workdir 必须与 upperdir 同文件系统否则 EXDEV(1322-1332、827-832)。默认 mutable=no(118、218-223)。

## 4. extension-release 校验:ID/LEVEL/ARCH/SCOPE 与文件定位

兼容性门槛在 `extension_release_validate`(src/shared/extension-util.c:13-137),键名按类切换 `SYSEXT_LEVEL`/`CONFEXT_LEVEL`、`SYSEXT_SCOPE`/`CONFEXT_SCOPE`(24-25)。检查顺序:release 数据缺失即拒(32-35)→ scope → ARCHITECTURE(uname 比对,`_any` 豁免,59-67)→ ID 必填、须匹配宿主 ID 或列入 ID_LIKE(69-97)→ SYSEXT_LEVEL 优先、否则回退 VERSION_ID,双缺(rolling release)只看 ID(99-133)。scope 段如下:

```c
// src/shared/extension-util.c:49-56
/* By default extension are good for attachment in portable service and on the system */
valid = strv_contains(
        scope_list ?: STRV_MAKE("system", "portable"),
        host_extension_scope);
if (!valid) {
        log_debug("Extension '%s' is not suitable for scope %s, ignoring.", ...);
        return 0;
}
```

host 侧传入的 scope 只有两种取值:`is_initrd ? "initrd" : "system"`(src/sysext/sysext.c:2159-2170,用 /etc/initrd-release 探测 initrd);而核心里每服务挂载扩展(`ExtensionImages=` 走 `MOUNT_EXTENSION_DIRECTORY`)时显式传 `host_extension_scope=NULL`,注释"we need to accept both system and portable"(src/core/namespace.c:2035-2043),其类判定还带 sysext→confext 回退(1999-2017)。release 文件本体:sysext 找 `/usr/lib/extension-release.d/extension-release.<NAME>`,confext 找 `/etc/extension-release.d/...`(src/basic/os-util.c:41-46);文件名与镜像名不符时回退到目录内任意 `extension-release.*`,但须携带 `user.extension-release.strict` xattr,出现两个候选则 ENOTUNIQ(src/basic/os-util.c:248-299、301-305)。裸 fs 镜像在 dissect 侧同样经 `load_extension_release_pairs` 读取并按类回退(src/shared/dissect-image.c:5052-5060)。层级默认值:sysext 合并 /usr 与 /opt,confext 只合并 /etc,还有一个三合一的 `SYSTEMD_SYSEXT_AND_CONFEXT_HIERARCHIES` 默认(src/shared/extension-util.c:139-163):

```c
// src/shared/extension-util.c:146-155(节选)
if (streq(hierarchy_env, "SYSTEMD_CONFEXT_HIERARCHIES"))
        l = strv_new("/etc");
else if (streq(hierarchy_env, "SYSTEMD_SYSEXT_HIERARCHIES"))
        l = strv_new("/usr", "/opt");
else if (streq(hierarchy_env, "SYSTEMD_SYSEXT_AND_CONFEXT_HIERARCHIES"))
        l = strv_new("/usr", "/opt", "/etc");
```

环境变量经 `getenv_path_list` 解析:冒号分隔、必须绝对路径、必须规范化、拒绝 "/"(src/basic/env-util.c:1078-1110)。host 侧 scope 取值的选择点如下:

```c
// src/sysext/sysext.c:2159-2172(节选)
r = chase_and_access("/etc/initrd-release", c->root, CHASE_PREFIX_ROOT, F_OK, NULL);
...
r = extension_release_validate(img->name,
                              host_os_release_id, ..., is_initrd ? "initrd" : "system",
                              image_extension_release(img, c->image_class),
                              c->image_class);
if (r == 0) { n_ignored++; continue; }
```

另一道硬闸:`extension_has_forbidden_content` 禁止扩展携带 /usr/lib/os-release,注释括号里写明"放 /etc/os-release 无妨,因为不参与合并"(src/shared/extension-util.c:165-180);merge 对目录/子卷镜像执行此检查,`--force` 才放行(src/sysext/sysext.c:2037-2045)。

## 5. reload 语义、服务单元与 Varlink/sysupdate 联动

本 commit 的动词表只有 status(默认)/merge/unmerge/refresh/list/help(src/sysext/sysext.c:2556、2696、2820、2933、3045、3137),man 页同(man/systemd-sysext.xml:322-383)。"reload" 只以三种形态存在:一是 `--no-reload` 选项(3204-3206),二是 merge/unmerge 收尾时按需 `daemon_reload()` → D-Bus `bus_service_manager_reload`(607-616),三是扩展 release 声明的三键驱动(src/sysext/sysext.c:505-540):

```c
// src/sysext/sysext.c:515-524(节选)
value = strv_env_pairs_get(extension_release, "EXTENSION_RESTART_UNITS");
r = split_unit_string(value, "EXTENSION_RESTART_UNITS", *extension, &restart_units);
...
if (!isempty(value))
        /* Listing units to restart implies a manager reload because a unit
         * shipped (and later removed) by the extension would otherwise not
         * be visible to the manager when RestartUnit/StopUnit is issued. */
        need_to_reload = true;
```

RESTART 优先于 RELOAD_OR_RESTART(537-540:前者集合中的单元从后者集合剔除);单元已消失(如 unmerge 拆掉了它)时先试 RestartUnit、收到 NO_SUCH_UNIT/LOAD_FAILED 再回退 StopUnit 防泄漏(src/sysext/sysext.c:626-644):

```c
// src/sysext/sysext.c:635-644(节选)
r = bus_call_method(bus, bus_systemd_mgr, m, &error, &reply, "ss", unit, "replace");
if (r < 0 && sd_bus_error_has_names(&error, BUS_ERROR_NO_SUCH_UNIT, BUS_ERROR_LOAD_FAILED)) {
        sd_bus_error_free(&error);
        m = "StopUnit";
        r = bus_call_method(bus, bus_systemd_mgr, m, &error, &reply, "ss", unit, "replace");
        ...
}
```

`--root=` 模式一律跳过 reload 与单元重启,注释明言"对宿主管理器谈论外来 root 的扩展从来不是想要的"(451-461)。refresh 的契约写在 `refresh()` 的尾注里(src/sysext/sysext.c:2916-2928):有扩展则拆旧挂新(或按 origin 短路),零扩展则转 unmerge,四象限注释逐一枚举(2916-2928);merge 子进程退出码 123→父进程返回 0→触发 unmerge,124→返回 1 表示"无变化已跳过"(102-105、2530-2533)。origin 比对是 JSON 语义等价而非字节比对:`sd_json_variant_equal`(2345-2363),`--always-refresh=yes` 可强行真刷(2355-2361)。

服务侧:systemd-sysext.service/-initrd.service/-sysroot.service 及 confext 对应物在 man 页登记(man/systemd-sysext.xml:20-27、119-151),保证在 basic.target 前完成(142-146);但 units/ 目录不在本次 sparse 检出内,各单元 ExecStart 具体内容**未核实**。Varlink 模式绑定 io.systemd.sysext 的 Merge/Unmerge/Refresh/List 与 io.systemd.SysUpdate.Notify.OnCompletedUpdate(src/sysext/sysext.c:3297-3305;接口定义 src/shared/varlink-io.systemd.sysext.c:18-62);后者只收 root 对端,一次通知**同时刷新两类**扩展并 RET_GATHER 容错——"a single notification refreshes both image classes"(3020-3043),这正是 sysupdate 装完新 sysext 后免重启接入的通道。polkit 四条 action:manage 需 auth_admin_keep,read 全放行(src/sysext/io.systemd.sysext.policy)。与 portabled 的定位差异一句话:sysext 把文件无隔离地"长进"宿主 /usr,portable 则自带依赖树并以服务级沙箱隔离运行(man/systemd-sysext.xml:133-140)。

## 6. confext 与 sysext:共用与差异清单

共用:同一 sysext.c 代码路径、同一 Varlink 接口(class 参数可切 sysext/confext,src/shared/varlink-io.systemd.sysext.c:11-14;方法实现里 `parse_image_class_parameter`,src/sysext/sysext.c:882-897)、同一 release 校验函数、同一 mutable 机制与配置文件框架(节名 [SysExt]/[ConfExt],src/sysext/sysext.c:267-275)。镜像发现读元数据时也同时尝试两类 release(src/shared/discover-image.c:2287-2301)。差异集中在 `image_class_info` 表(src/sysext/sysext.c:164-191):层级(/usr,/opt vs /etc)、点目录名、release 文件位置(os-util.c:41-46)、搜索路径(discover-image.c:79-86)、默认挂载标志、镜像策略。挂载标志差异是最硬的安全线:

```c
// src/sysext/sysext.c:176 与 190
.default_mount_flags = MS_RDONLY|MS_NODEV,                      /* sysext */
.default_mount_flags = MS_RDONLY|MS_NODEV|MS_NOSUID|MS_NOEXEC,  /* confext */
```

`--noexec=false` 可去掉 confext 的 noexec(`SET_FLAG(flags, MS_NOEXEC, noexec)`,src/sysext/sysext.c:744-745;man/systemd-sysext.xml:504-511)。confext 默认镜像策略只保留 root 分区参与校验,sysext 另含 usr 分区(src/shared/image-policy.h:74-77)。差异速查:

| 维度 | sysext | confext | 证据 |
| --- | --- | --- | --- |
| 合并层级 | /usr /opt | /etc | extension-util.c:147-155 |
| 元目录 | `.systemd-sysext` | `.systemd-confext` | sysext.c:169、183 |
| release 位置 | /usr/lib/extension-release.d/ | /etc/extension-release.d/ | os-util.c:41-46 |
| 搜索路径 | /etc,/run,/var/lib/extensions | 另含 /usr(/local)/lib/confexts | discover-image.c:79-86 |
| 挂载标志 | RDONLY\|NODEV | +NOSUID\|NOEXEC | sysext.c:176、190 |
| 默认策略 | root+usr | 仅 root | image-policy.h:74-77 |

unmerge 的循环语义两边同构:只要 `is_our_mount_point` 认账就反复拆(EINVAL 视为"整个层级只读故元目录未 bind"而放行,src/sysext/sysext.c:1794-1853),拆完把先前挪走的子挂载搬回原位(1907-1909、2457-2459)。子挂载搬迁不用 bind 而用 open_tree 克隆 + move_mount,注释解释是让克隆体脱离传播关系、MNT_DETACH 不再波及嵌套挂载(src/sysext/sysext.c:593-601):

```c
// src/sysext/sysext.c:597-601(节选)
r = RET_NERRNO(move_mount(m->mount_fd, "", child_fd, "",
                          MOVE_MOUNT_F_EMPTY_PATH|MOVE_MOUNT_T_EMPTY_PATH));
...
(void) umount_verbose(LOG_WARNING, m->path, MNT_DETACH);
```

## 7. 纠偏、设计动机与深挖方向

**纠偏(以本 commit 源码为准,共 6 条):**
1. 不存在 `/usr/.extended-*` 之类目录:元目录是 `<层级>/.systemd-sysext/`(confext 为 `.systemd-confext`),workdir 形如 `.systemd-usr-workdir`(src/sysext/sysext.c:169、183、839)。
2. 不存在 `reload` 动词:动词集只有 status/merge/unmerge/refresh/list/help,`--no-reload` 只是抑制收尾的 manager reload 与单元重启(src/sysext/sysext.c:2556-3141 各动词注册处、3204-3206)。
3. `SYSEXT_SCOPE` 没有 "service" 层级:扩展侧缺省视为 {system, portable},host 侧只会传 system 或 initrd,服务级 ExtensionImages= 干脆传 NULL 跳过检查(src/shared/extension-util.c:50-52;src/sysext/sysext.c:2170;src/core/namespace.c:2041)。
4. 不存在 "merge-utils" 共享文件:两类扩展共用的是整个 sysext.c(3319 行),外加 src/shared/extension-util.c(180 行)与 src/basic/os-util.c 的 release 读取(os-util.c:41-46、457-467);本 commit 无 src/confext/ 目录。
5. "三种镜像形态"是 man 页的用户口径;代码中 Image 类型有 directory/subvolume/raw/block 四种,Varlink ImageType 枚举还含 mstack(src/shared/discover-image.c:605、575、645、705;src/shared/varlink-io.systemd.sysext.c:10-16)。
6. confext 并非"配置侧等价物"这么简单:它的搜索路径反而含 /usr/lib/confexts、挂载标志更严(NOSUID|NOEXEC)、默认镜像策略不含 usr 分区——三处都与 sysext 反向(src/shared/discover-image.c:83-86;src/sysext/sysext.c:190;src/shared/image-policy.h:74-77)。

**设计动机(源码/文档证据,8 条):**
1. 不可变镜像运行时扩展 /usr、/opt,免整体重建(man/systemd-sysext.xml:52-57)。
2. 默认严格只读,mutable 写路由必须显式 opt-in,且写入汇聚到 /var/lib/extensions.mutable/<层级>(man 76-80、264-318;sysext.c:124)。
3. 无 enable/disable 概念:装了即激活,屏蔽靠 /etc/extensions 下同名空目录(man 153-156)。
4. 声明式兼容契约:extension-release 的 SCOPE/ARCH/ID/LEVEL 四道闸门(extension-util.c:32-133)。
5. origin JSON 指纹让 refresh 幂等短路,服务启动重复调用零开销(sysext.c:1461、2345-2363)。
6. dev/backing 文件 + st_dev 比对,把"活动合并树"与离线拷贝区分开(373-405、1487-1490 注释)。
7. 全程私有 mount ns + tmpfs 工作区:组装失败不留残挂,子进程退出即内核回收(1998-2004、2514-2515 注释)。
8. confext 以 NOSUID|NOEXEC 对齐"配置文件不该可执行"的威胁模型(190)。

**深挖方向(5 条):**
1. move_submounts 的 open_tree_attr_with_fallback/move_mount 无传播重挂细节与内核版本门槛(src/sysext/sysext.c:551-605;src/shared/mount-util.c:1601-1638)。
2. core/namespace.c 的 ExtensionImages=/ExtensionDirectories= 每服务扩展与全系统 sysext 的职责分界(src/core/namespace.c:1988-2049;src/core/load-fragment.c:5452)。
3. origin 指纹的稳定性:verityHash/onMountId/fileHandle/inode 回退链在真实部署中的抖动与误判面(src/sysext/sysext.c:2215-2245)。
4. units/ 未在 sparse 检出内:systemd-sysext.service/-initrd/-sysroot 三单元的依赖序与 ExecStart 未核实,需补 units/ 检出(man/systemd-sysext.xml:119-151 仅文档面)。
5. sysupdate 完成通知→双类刷新→polkit 的 Varlink 激活链路,与 io.systemd.SysUpdate.Notify 接口定义(src/sysext/sysext.c:3020-3043;src/shared/varlink-io.systemd.SysUpdate.Notify.h)。

## 8. FAQ 候选与正文蒸馏要点

**FAQ 候选(10 条,一句话答案):**
1. systemd-confext 有独立源码吗?——没有,是 systemd-sysext 的符号链接,argv[0] 定身份(src/sysext/meson.build:19-21;sysext.c:3254)。
2. 扩展能带 /usr/lib/os-release 吗?——不能,`extension_has_forbidden_content` 直接拒,`--force` 才跳过该检查(extension-util.c:165-180;sysext.c:2037-2045)。
3. 两个扩展提供同名文件谁赢?——strverscmp_improved 版本高者位于更高层而胜出(sysext.c:2263-2265、2385)。
4. 合并后 /usr 还能写吗?——默认整体只读,mutable 模式才经 upperdir 放行,且元目录单独再锁一层 RO(sysext.c:1641-1672)。
5. extension-release 放哪?——sysext 在 /usr/lib/extension-release.d/,confext 在 /etc/extension-release.d/,文件名须配镜像名(os-util.c:41-46)。
6. 重复执行 merge 会怎样?——EBUSY "already merged",刷新应使用 refresh(sysext.c:2717-2721)。
7. refresh 每次都真重挂吗?——origin JSON 语义相等即跳过,除非 --always-refresh=yes(sysext.c:2345-2363)。
8. 扩展想让某服务合并后重启怎么办?——release 里写 EXTENSION_RESTART_UNITS=,重启优先于 reload-or-restart 且隐含 manager reload(sysext.c:515-540)。
9. sysext 镜像能放 /usr 下吗?——不能,搜索路径刻意排除 /usr 以避 overlayfs 嵌套 -ELOOP;confext 却可放 /usr/lib/confexts(discover-image.c:75-86)。
10. 扩展镜像里的 os-release 会合入吗?——sysext 禁带 /usr/lib/os-release、其 /etc 内文件本就不参与合并;confext 的 /etc 子树整体入栈,故其 /etc/os-release 会真实出现在合并结果(extension-util.c:168-170;sysext.c:1067-1104)。

**正文蒸馏要点(12 条):**
1. confext 不是第二个实现:install_symlink 把 systemd-confext 指到 systemd-sysext,`invoked_as` 一行分流(src/sysext/meson.build:19-21;sysext.c:3254)。
2. sysext 默认层级 /usr+/opt,confext 仅 /etc,均可被 SYSTEMD_*_HIERARCHIES 覆盖且拒绝相对路径、非规范化路径与 /(extension-util.c:147-155;env-util.c:1090-1102)。
3. merge 的完整编排:私有 mount ns → /run MS_SLAVE → tmpfs 工作区 → 挂载校验镜像 → 版本升序排序后倒序成层 → 先拆旧 overlay → merge_hierarchy → MS_BIND|MS_REC 入宿主(sysext.c:1985-2492)。
4. overlayfs 层序 = meta 压顶 + (mutable import 层) + 扩展按版本降序 + 宿主垫底;有 upperdir 时整层转可写并清 MS_RDONLY(sysext.c:1173-1303、747-760)。
5. 元目录五件套 extensions/dev/origin/backing/work_dir 同时是"识别自家挂载"的凭证,st_dev 比对防离线拷贝误判(sysext.c:373-405、1581-1639)。
6. release 校验四道闸:scope(缺省 {system, portable})、ARCHITECTURE、ID/ID_LIKE、SYSEXT_LEVEL→VERSION_ID 回退(extension-util.c:32-133)。
7. host scope 只有 system|initrd 两值;服务级 ExtensionImages= 传 NULL 完全绕过 scope 检查(sysext.c:2159-2170;namespace.c:2041)。
8. sysext 挂载标志 RDONLY|NODEV,confext 追加 NOSUID|NOEXEC,是两类扩展最直接的威胁模型差异(sysext.c:176、190)。
9. 无 reload 动词:EXTENSION_RELOAD_MANAGER/RESTART_UNITS/RELOAD_OR_RESTART_UNITS 三键驱动收尾的 daemon-reload 与单元重启,RESTART 优先、消失单元回退 StopUnit(sysext.c:505-540、626-644)。
10. refresh 以 origin JSON 相等做幂等短路;merge 退出码 123/124 分别驱动 refresh 的"转 unmerge"与"无事发生"两条捷径(sysext.c:2345-2363、102-105、2530-2533)。
11. mutable 六模式(no/auto/yes/import/ephemeral/ephemeral-import)以 /var/lib/extensions.mutable 为写路由中枢,ephemeral 系把 mutable 目录挪进 tmpfs 工作区且不落 work_dir 文件(sysext.c:74-94、966-971、1552-1554)。
12. 搜索路径不对称是刻意的:sysext 禁入 /usr 防 overlayfs lowerdir 嵌套 -ELOOP,confext 可放 /usr/lib/confexts(discover-image.c:75-86)。
