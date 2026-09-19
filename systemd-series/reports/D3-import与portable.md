# 报告 D3 · importd 与 portabled(systemd 卷三)

> 基线:1f66b524(2026-09-11)。一句话:镜像搬运是"编排器 + 短命子进程"两级架构——importd 只做 D-Bus/Varlink 编排与进度转发,真正的下载/校验/落盘由 systemd-pull 等子工具在自己的 sd-event + curl multi socket 循环里完成;portabled 几乎无状态,attach 的本质是"dissect 镜像 → 抽取 unit 与 os-release → 生成 20-portable.conf/10-profile.conf drop-in 到 system.attached 目录",镜像可信性由 etag/SHA256/GPG 与分区级 image policy 两套机制分层兜底。

## 1. 进程拓扑:importd 是编排器,不是下载器

`systemd-importd`(总线名 org.freedesktop.import1)维护 Transfer 对象池,硬上限 64(src/import/importd.c:124)。Transfer 记录 8 种类型、verify 模式、remote/local、log_fd、pidref 与进度(src/import/importd.c:56-67、69-103)。

```c
// src/import/importd.c:124
#define TRANSFERS_MAX 64
// src/import/importd.c:126-135(类型表)
static const char* const transfer_type_table[_TRANSFER_TYPE_MAX] = {
        [TRANSFER_IMPORT_TAR] = "import-tar",
        ...
        [TRANSFER_PULL_TAR]   = "pull-tar",
        [TRANSFER_PULL_RAW]   = "pull-raw",
        [TRANSFER_PULL_OCI]   = "pull-oci",
};
```

关键在 `transfer_start()`:fork 出 "(sd-transfer)" 子进程后在子进程里拼命令行,经 `invoke_callout_binary()` 拉起 systemd-import/-fs/-export/-pull 二进制;父进程只监视退出与日志管道。

```c
// src/import/importd.c:442-447(fork)
r = pidref_safe_fork_full(
                "(sd-transfer)",
                (int[]) { t->stdin_fd, t->stdout_fd < 0 ? pipefd[1] : t->stdout_fd, pipefd[1] },
                NULL, 0,
                FORK_RESET_SIGNALS|FORK_CLOSE_ALL_FDS|FORK_DEATHSIG_SIGTERM|FORK_REARRANGE_STDIO|FORK_REOPEN_LOG,
                &t->pidref);
// src/import/importd.c:505-509(选 callout)
case TRANSFER_PULL_TAR:
case TRANSFER_PULL_RAW:
case TRANSFER_PULL_OCI:
        cmd[k++] = SYSTEMD_PULL_PATH;
```

- 进度不走 D-Bus 轮询:子工具 `sd_notifyf("X_IMPORT_PROGRESS=%u%%")`(src/import/pull-tar.c:215),父进程 notify socket 收到后解析并广播 D-Bus 信号 + varlink notify(importd.c:681-697、252-279)。
- 日志管道优先级被提到 `SD_EVENT_PRIORITY_NORMAL-5`,保证先于子进程退出事件处理(importd.c:615-618)。
- 同类型同 remote 的传输去重:`manager_find()` 按 (type, remote) 线性查找,命中报 `TRANSFER_IN_PROGRESS`(importd.c:751-763、1177-1179);Varlink 侧对应 `io.systemd.Import.AlreadyInProgress`(importd.c:1932)。
- btrfs 子卷/quota 默认开,环境变量 `SYSTEMD_IMPORT_BTRFS_SUBVOL/QUOTA` 可关(importd.c:711-715、2062-2084)。
- 空闲(无传输、无 polkit 待答、无 varlink 连接)即退出(importd.c:2032-2037)。
- 对外同时暴露 D-Bus 与 Varlink:`io.systemd.Import.Pull/ListTransfers` 绑定于 importd.c:2023-2025,系统 scope 监听 `$runtime/systemd/io.systemd.Import`(importd.c:2042-2049)。
- 命令行工具 importctl 提供 pull-tar/raw/oci、import-tar/raw/fs、export-tar/raw、cancel-transfer 全套动词(src/import/importctl.c:271-948)。
- src/import/import-generator.c 解析内核命令行 `systemd.pull=`(import-generator.c:239-255),生成 `Requires=systemd-importd.socket` 的 systemd-import@.service,实现开机拉取(import-generator.c:331-346)。
- 取消:前 3 次 SIGTERM,之后 SIGKILL(importd.c:369-380)。

## 2. pull 管线:curl 事件循环与 PullJob 状态机

pull-tar 一次最多并行 4 个 PullJob:主 tar job、checksum job、signature job、settings job(.nspawn),接线在 `tar_pull_start()`(src/import/pull-tar.c:742-790)。curl 侧先造 easy 句柄,限定协议与低速 abort:

```c
// src/shared/curl-util.c:424-437
if (sym_curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 60L) != CURLE_OK)
        return -EIO;
if (sym_curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 30L) != CURLE_OK)
        return -EIO;
#if LIBCURL_VERSION_NUM >= 0x075500 /* libcurl 7.85.0 */
        if (sym_curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, "HTTP,HTTPS,FILE") != CURLE_OK)
#else
        if (sym_curl_easy_setopt(c, CURLOPT_PROTOCOLS, CURLPROTO_HTTP|CURLPROTO_HTTPS|CURLPROTO_FILE) != CURLE_OK)
                return -EIO;
        if (sym_curl_easy_setopt(c, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP|CURLPROTO_HTTPS) != CURLE_OK)
#endif
```

- libcurl 是 dlopen 的 `libcurl.so.4`,缺失则功能不可用(curl-util.c:602-631;pull.c:581 标注 LIBCURL_NOTE(suggested))。
- 事件桥接:`curl_glue_socket_callback()` 把 curl 的 fd 注册为 sd-event IO 源(curl-util.c:181-240);timer 回调驱动 curl 超时(curl-util.c:256-292);完成消息经 defer 源逐条取出回调 slot(curl-util.c:114-156)。
- `curl_glue_perform_async()` 把 easy 加入 multi,建 CurlSlot 并以 CURLOPT_PRIVATE 反查(curl-util.c:443-498)。

```
[importctl / machinectl]          [portablectl]
        | (D-Bus org.freedesktop.import1 / Varlink io.systemd.Import)
        v
+--------------------------- systemd-importd ---------------------------+
| Transfer{id,type,verify,...}   (<=64, importd.c:124)                   |
|  transfer_start(): fork "(sd-transfer)" -> invoke_callout_binary      |
+----------------------------------|------------------------------------+
                                   v
+--------------------------- systemd-pull tar --------------------------+
| TarPull{tar_job, checksum_job, signature_job, settings_job}           |
|   | CurlGlue(multi) + sd-event io/timer/defer  (curl-util.c:181-301)  |
|   | PullJob: INIT -> ANALYZING(探测压缩) -> RUNNING -> DONE           |
|   |   write_cb: 先 EVP_sha256(压缩字节) 再解压再写盘 (pull-job.c:246) |
|   |   304/etag 命中 => etag_exists=true 跳过下载 (pull-job.c:367-370) |
|   v 全部 DONE 且 tar 子进程退出 (pull-tar.c:405-473)                   |
|   pull_verify(): sha256 行匹配 + gpg 签名 (pull-common.c:610-675)     |
|   import_mangle_os_tree_fd() 清理 os 树 (pull-tar.c:500、526)          |
|   install_file(): ".tar-<url>.<etag>" 原子改名 (pull-tar.c:530-540)   |
|   tar_pull_make_local_copy(): btrfs 快照/复制出 <local> (246-403)     |
+------------------------------------------------------------------------+
        | X_IMPORT_PROGRESS=nn% (sd_notify, pull-tar.c:215)
        v
importd 转发 ProgressUpdate / varlink notify (importd.c:252-279)
```

状态机细节:

- ANALYZING 阶段先缓冲探测压缩格式;流结束仍未识别则 `decompressor_force_off()` 按原文写(pull-job.c:407-419、514-528)。
- 写盘对普通文件用 `sparse_write`,空洞阈值 64 字节(pull-job.c:190-197)。
- HTTP 分支:304 → etag_exists;401 → -ENOKEY;404 触发 `on_not_found` 回退链;Content-Length 不符报 truncated(pull-job.c:360-405、429-432)。
- 完成后:ftruncate 到未压缩长度、写 `user.source_etag`/`user.source_url` xattr、恢复 mtime/crtime(pull-job.c:466-493)。
- 压缩与未压缩流量各限 64GB(pull-job.c:764-765);请求带 `If-None-Match: <旧 etag 列表>`(pull-job.c:811-825)。
- tar 的落盘打开回调 `on_open_disk_tar` 见第 4 节;进度合成:下载占 0-85%、verify 85%、finalize 90%、copy 95%,以 100ms 限频上报(pull-tar.c:161-223)。

## 3. 校验:sha256 按"压缩字节"算,GPG 是子进程

sha256 用 dlopen 的 OpenSSL EVP 在写回调里增量计算,且发生在解压之前——即 SHA256SUMS 描述的是服务器原始压缩产物:

```c
// src/import/pull-job.c:246-253(先哈希后解压)
if (j->checksum_ctx) {
        r = sym_EVP_DigestUpdate(j->checksum_ctx, data->iov_base, data->iov_len);
        ...
}
r = decompressor_push(j->compress, data->iov_base, data->iov_len, pull_job_write_uncompressed, j);
// src/import/pull-job.c:288-295(初始化)
j->checksum_ctx = sym_EVP_MD_CTX_new();
r = sym_EVP_DigestInit_ex(j->checksum_ctx, sym_EVP_sha256(), NULL);
```

- `pull_verify()` 编排:主文件与 settings 等辅助文件逐一与 checksum payload 比对;verify=signature 再对 checksum 文件本体验签(pull-common.c:610-675)。
- `verify_one()` 把十六进制摘要拼成 `"<hash> *<fn>\n"`(兼容 ` *`/`  `/` ` 三种分隔符,后者是 linuxcontainers.org 风格),memmem 匹配且要求行首命中(pull-common.c:389-415)。
- `--verify=` 还接受字面 64 位 hex sha256:此时不再下载 checksum/signature/roothash 等文件(pull.c:353-379,冲突校验 pull.c:526-527)。
- verify=signature 时 `verify_gpg()` fork 子进程,先试 `gpg2` 再 `gpg`(pull-common.c:571-578):

```c
// src/import/pull-common.c:528-543(gpg 参数,临时 gpghome)
cmd = strv_new(
                "gpg",
                "--no-options",
                "--no-default-keyring",
                "--no-auto-key-locate",
                "--no-auto-check-trustdb",
                "--batch",
                "--trust-model=always",
                "--auto-key-import",
                "--import-options=merge-only,import-clean");
...
r = strv_extendf(&cmd, "--homedir=%s", gpg_home);
```

- 密钥环收集顺序:`$SYSTEMD_OPENPGP_KEYRING` → `/etc/systemd/import-pubring.pgp`(USER_KEYRING_PATH)→ 旧 `.gpg` → `<libexecdir>/import-pubring.pgp`(VENDOR_KEYRING_PATH)(pull-common.c:438-501;路径定义 meson.build:326-330;随包安装见 src/import/meson.build:112-115)。
- 注释明确:先拷贝密钥环到临时 gpghome 再验,防 gpg `--auto-key-import` 把签名内嵌公钥写回原钥环(pull-common.c:503-526)。
- 404 回退链:checksum job 先试 `<fn>.sha256`,失败抓 `SHA256SUMS`;signature job 按 `.sha256.asc → .sha256.gpg → SHA256SUMS.gpg → SHA256SUMS.asc` 四级回退(pull-common.c:324、347、703-812)。
- etag 即缓存:落盘名 `.tar-<escaped-url>.<etag>`(pull-tar.c:239),raw 为 `.raw-`(pull-raw.c:290);URL 超长(`>= _POSIX_PATH_MAX-16`)换成 siphash24 哈希(pull-common.c:31、115-126、170-184);文件名对 url/etag 做 `xescape("/.#\"')` 转义(pull-common.c:30、47)。
- etag 命中(304)时不重下也**不重新校验**,直接走本地副本(pull-tar.c:475-491)。

## 4. 落盘副作用:btrfs 子卷、nocow、qcow2 展开、keep-download

tar 流到达时先建临时树;`IMPORT_BTRFS_SUBVOL` 时建 btrfs 子卷(失败回退目录),成功且开 quota 时对池与子卷各设配额:

```c
// src/import/pull-tar.c:644-665
if (p->flags & IMPORT_BTRFS_SUBVOL)
        r = btrfs_subvol_make_fallback(AT_FDCWD, where, 0755);
else
        r = RET_NERRNO(mkdir(where, 0755));
...
if (r > 0 && (p->flags & IMPORT_BTRFS_QUOTA)) { /* actually btrfs subvol */
        if (!(p->flags & IMPORT_DIRECT))
                (void) import_assign_pool_quota_and_warn(p->image_root);
        (void) import_assign_pool_quota_and_warn(where);
}
p->tree_fd = open(where, O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
...
j->disk_fd = import_fork_tar_x(p->tree_fd, p->userns_fd, &p->tar_pid); // 真 tar 进程解包
```

- 机器池本身在每次传输前由 `image_setup_pool()` 建子卷、启用 quota、建 qgroup 层级(src/shared/discover-image.c:2198-2230)。
- raw:下载完若 `qcow2_detect()` 认出 QCOW2 魔数 0x514649fb(src/import/qcow2-util.c:11),`qcow2_convert()` 按簇展开成普通 raw(簇复制优先 reflink,qcow2-util.c:64-73;调用点 pull-raw.c:228-271)。
- raw 本地副本先 `import_set_nocow_and_log()` 关 COW,减少 btrfs 碎片(pull-raw.c:390-392)。
- 辅助文件 `.nspawn/.roothash/.roothash.p7s/.verity` 在主镜像改名后跟进,且会"重新生成"带 etag 的最终名再 rename(pull-tar.c:549-567;raw 辅助文件 pull-raw.c:297-339、425-441)。
- `--keep-download`(仅 machine class 默认开启,pull.c:539-542)时原始下载保留为只读母本,本地名经 btrfs 递归快照(BTRFS_SNAPSHOT_RECURSIVE|FALLBACK_COPY|FALLBACK_DIRECTORY)或 copy_tree 克隆(pull-tar.c:267-353)。
- flag 语义全集:IMPORT_FORCE/READ_ONLY/KEEP_DOWNLOAD 公开,BTRFS_SUBVOL/QUOTA/CONVERT_QCOW2/DIRECT/SYNC/FOREIGN_UID 私有,PULL_* 仅下载(src/import/import-common.h:8-36)。
- user scope 追加 `IMPORT_FOREIGN_UID`:经 mountfsd + nsresourced userns 以外来 UID 建树(pull-tar.c:615-642;pull.c:544-545)。
- `--direct` 模式跳过改名游戏直写目标路径,支持 `--offset/--size-max`(pull.c:462-486、523-524;pull-tar.c:493-512)。

## 5. 镜像发现与鉴别:按 class 的搜索路径 + os-release 一句话

发现逻辑统一在 src/shared/discover-image.c,按 class 定搜索路径:

```c
// src/shared/discover-image.c:61-79
const char* const image_search_path[_IMAGE_CLASS_MAX] = {
        [IMAGE_MACHINE] =   "/etc/machines\0"              /* only place symlinks here */
                            "/run/machines\0"              /* and here too */
                            "/var/lib/machines\0"          /* the main place for images */
                            "/var/lib/container\0"         /* legacy */
                            "/usr/local/lib/machines\0"
                            "/usr/lib/machines\0",
        [IMAGE_PORTABLE] =  "/etc/portables\0"
                            "/run/portables\0"
                            "/var/lib/portables\0"
                            "/usr/local/lib/portables\0"
                            "/usr/lib/portables\0",
```

- sysext 搜索路径刻意不含 /usr/(注释:避免 OverlayFS lowerdir 递归 -ELOOP,discover-image.c:80-86);initrd 下额外搜 `/.extra/sysext` 等(discover-image.c:88-102)。
- 各 class 主池目录:/var/lib/machines|portables|extensions|confexts(discover-image.c:114-118);下载根由 `image_root_pick()` 按 scope/class/runtime 选(discover-image.c:2526-2568)。
- 镜像类型:directory/subvolume/raw/block 外还有 IMAGE_MSTACK(discover-image.c:2519-2525)。
- DissectImage 对 os-release 一句话:挂载后 `DISSECT_IMAGE_VALIDATE_OS` 仅以 `path_is_os_tree()` 检查 etc|usr/lib/os-release 存在,否则 -EMEDIUMTYPE 拒绝(src/shared/dissect-image.c:2660、2705-2722)。
- portable/sysext 场景再校验 extension-release 与根 os-release 的 ID/LEVEL 匹配(portable.c:1011-1019)。
- machined 简述:src/machine/ 提供 Machine/Image 两类对象(Image 走 D-Bus 与 varlink io.systemd.MachineImage:image-dbus.c:447 起、image-varlink.c:34-382 的 update/clone/remove/limit/clean),machined 负责 RegisterMachine 与 varlink user/group record(machined-varlink.c:166-612);镜像读元数据统一用 image_policy_service(portabled-image-bus.c:64)。本章不展开。

## 6. portabled:attach 与 detach 完整流程

portabled 本体仅 200 行壳(src/portable/portabled.c),方法转给 bus 层:读 matches、profile(portablectl 默认 "default",portablectl.c:37)、copy 模式 symlink/copy/mixed(portabled-image-bus.c:360-366),polkit 动作 `org.freedesktop.portable1.attach-images`(portabled-image-bus.c:378-384),再进 `portable_attach()`(portable.c:2033-2171):

- `extract_image_and_extensions()`:绝对路径先过 vpick(.v/)选版本(portable.c:829-847),`image_find_harder()` 定位(discover-image.c:1060;portable.c:849);扩展镜像逐一抽取、extension-release 校验、PORTABLE_PREFIXES 合并(portable.c:966-1035);镜像 os-release 可声明 `PORTABLE_PREFIXES` 与 `PORTABLE_SCOPE`(scope 不匹配拒绝,portable.c:927-963)。
- `portable_extract_by_path()`:目录镜像直接抽;raw/block 建 loop 设备后 `dissect_loop_device()` 按 image policy 拆(portable.c:582-687),fork "(sd-dissect)" 子进程进独立 mount namespace 挂载再抽(portable.c:707-754);user scope 改走 mountfsd+nsresource userns(portable.c:626-644);子进程经 seqpacket 把 os-release/extension-release 与 unit 回传(portable.c:271-330、191-269);unit 匹配只认 .service/.socket/.target/.timer/.path(portable.c:76-96)。

```c
// src/portable/portable.c:1712-1714(半原子序注释)
/* We install the drop-ins first, and the actual unit file last to achieve somewhat atomic behaviour if PID 1
 * is reloaded while we are creating things here: as long as only the drop-ins exist the unit doesn't exist at
 * all for PID 1. */
// src/portable/portable.c:60-63(marker 定义)
#define PORTABLE_DROPIN_MARKER_BEGIN "# Drop-in created for image '"
#define PORTABLE_DROPIN_MARKER_END "', do not edit."
```

- `20-portable.conf` 内容:`RootDirectory=/RootImage=/RootMStack=`(按镜像类型,portable.c:1290-1307)、`Environment=PORTABLE=`、`LogExtraFields=PORTABLE(_ROOT/_EXTENSION)=` 与 name/version 字段(portable.c:1467-1508);扩展映射 `ExtensionImages=/ExtensionDirectories=`,--force 时追加 `:x-systemd.relax-extension-release-check`(portable.c:1309-1320、1523-1532)。
- 策略落 drop-in:`RootImagePolicy=`/`ExtensionImagePolicy=`(portable.c:1475-1485、1539-1549),多扩展策略做并集(portable.c:991-1002)。
- `10-profile.conf` 是 profile 文件的 symlink(--copy 时 copy)(portable.c:1584-1646)。
- 目标目录:PORTABLE_RUNTIME → /run/systemd/system.attached,否则 /etc/systemd/system.attached(src/libsystemd/sd-path/path-lookup.c:308-309;选择 portable.c:1648-1660)。
- 前置校验:unit 已存在或已 active 拒绝(portable.c:2122-2135);matches 不在镜像 PORTABLE_PREFIXES 内拒绝(portable.c:2078-2102);收尾 `install_image_and_extensions()` 把镜像 symlink/copy 到 /run|/etc/systemd/portables,失败仅忽略(portable.c:1922-1950、2157-2159)。
- detach(portable.c:2342-2514):扫 system.attached,读 marker 与镜像列表 1:1 匹配(分层镜像冒号列表,portable.c:2173-2304),active 拒绝(portable.c:2395-2401),删 unit、两个 drop-in、.d 目录(portable.c:2427-2465),删搜索路径外镜像副本(portable.c:2468-2485)。
- 工具侧 portablectl:attach/detach/reattach/list/inspect/is-attached/read-only/remove/set-limit 等动词(portablectl.c:276-1443);attach 后可选 --enable --now(maybe_enable_start,portablectl.c:1276)。
- 内置 profile 四套:default/strict/trusted/nonetwork(src/portable/profile/system|user/ 下各 service.conf);strict 含 `CapabilityBoundingSet=`(空)、`PrivateNetwork=yes`、`IPAddressDeny=any`、`TasksMax=4`(profile/system/strict/service.conf);default 含 `DynamicUser=yes`、`ProtectSystem=strict`、`SystemCallFilter=@system-service`(profile/system/default/service.conf)。
- profile 查找:目录集 `portable_profile_dirs()`(系统为 PORTABLE_PROFILE_DIRS,user 为 XDG 目录),按 unit 类型后缀搜 `<profile>/<type>.conf`(src/shared/portable-util.c:11-99)。

## 7. 安全模型:image policy 分区判别 + polkit 动作

没有名为 "PortablePolicy" 的接口(全仓 grep 无此符号,已核实);portable 的策略链是:① 调用方传 image_policy——但 D-Bus 路径恒传 NULL(portabled-image-bus.c:396);② dissect 结果"钉死"一份策略并写入 drop-in;③ 运行时挂载由 PID1/mountfsd 按策略执行。

```c
// src/shared/image-policy.c:287-292(从 dissect 事实反推)
ImagePolicy* image_policy_new_from_dissected(const DissectedImage *image, const VeritySettings *verity) {
        ...
        /* Default to 'absent', only what we find is allowed to be used */
        image_policy->default_flags = PARTITION_POLICY_ABSENT;
        // 随后按分区是否出现、crypto_LUKS、verity/签名就绪、growfs/rw 位逐分区填 flags(287-332)
```

- 内置 `image_policy_service`:root/usr 允许 verity/signed/encrypted/encrypted-with-integrity/unprotected/absent,home/srv/tmp/var 仅 encrypted 类,ESP/XBOOTLDR/swap 默认 IGNORE(image-policy.c:1098-1106)。
- 策略字符串支持符号 "*"~/`-` 与 per-designator 规则(image-policy.c:336-360 起);`image_policy_to_string(simplify=true)` 生成 drop-in 短格式(image-policy.c:646-652;portable.c:1478)。
- 鉴权(所谓 "PolicyStyle" 并不存在,已核实):importd 系统 scope 用 polkit 动作 org.freedesktop.import1.import/export/pull/cancel,默认全部 `auth_admin`(active 为 `auth_admin_keep`)(src/import/org.freedesktop.import1.policy:21-57;调用点 importd.c:778-788、980-991、1080-1091、1296-1305)。
- user scope 直接跳过 polkit(importd.c:777);Varlink 侧 `varlink_verify_polkit_async` 并把 remote/local/class/type/verify 作为 detail 提交(importd.c:1935-1948)。
- portable1 三动作 inspect/attach/manage 同为 auth_admin(_keep)(src/portable/org.freedesktop.portable1.policy:12-39);注意 DetachImage 也用 attach-images 动作(portabled-bus.c:368-376),且刻意不做镜像对象重定向以支持"先删镜像再补 detach"(portabled-bus.c:258-263)。

## 8. 纠偏(以 1f66b524 源码为准)

- **纠偏一**:"importd 下载镜像"不准确。importd 不碰网络,只 fork systemd-pull/import/export 子工具执行(importd.c:442-592);curl 亦非直接链接而是 dlopen(curl-util.c:602-631)。
- **纠偏二**:"SHA256 校验解压后内容"不对——哈希在解压前按压缩字节计算(pull-job.c:246-251),SHA256SUMS 对应服务器原始文件。
- **纠偏三**:GPG 校验不是进程内库实现,而是 fork `gpg2/gpg` 子进程 + 临时 gpghome + 密钥环拷贝,防签名内嵌密钥污染原钥环(pull-common.c:421-608);内置厂商钥环只是 libexecdir 下一个文件(meson.build:330)。
- **纠偏四**:attach drop-in 默认落 **/etc**/systemd/system.attached(持久),--runtime 才是 /run(path-lookup.c:308-309;portablectl.c:39 arg_runtime 默认 false);"写到 /run"是旧印象。
- **纠偏五**:不存在 "PortablePolicy"/"PolicyStyle" 这样的 D-Bus API 或结构;镜像策略由分区级 image policy 从 dissect 结果推导并写成 RootImagePolicy=/ExtensionImagePolicy= 生效,D-Bus 调用侧恒传 NULL 策略(portabled-image-bus.c:396、image-policy.c:287-332、portable.c:1475-1549)。
- **纠偏六**:DetachImage/ReattachImage 复用 attach-images polkit 动作,无独立 detach 动作(portabled-bus.c:368-376)。
- **纠偏七**:etag 命中(304)时既不重下也**不重新校验**,只重做本地副本(pull-tar.c:475-491);etag 直接编进缓存文件名,URL 超长换 siphash24(pull-common.c:170-184)。
- **纠偏八**:进度并非 D-Bus 轮询属性,而是子工具 sd_notify `X_IMPORT_PROGRESS=` 推送、importd 广播(pull-tar.c:215、importd.c:681-697);D-Bus `Progress` 属性与 varlink notify 双轨并存。

## 设计动机

1. **编排器/工人分离**:下载、tar 解包、gpg 各自短命进程,崩溃即终结,importd 常驻面缩到最小;日志/进度经管道与 sd_notify 单向流入(importd.c:432-618、681-697)。
2. **etag 即缓存键**:url+etag 编进文件名并配合 If-None-Match,"重复拉取"退化为一次 304 加一次快照克隆(pull-common.c:144-188、pull-job.c:811-825)。
3. **校验先于改名**:先写 tempfn 临时名,verify 通过后 `install_file()` 原子 rename,避免半成品被 machined/nspawn 发现(pull-tar.c:521-540)。
4. **btrfs 子卷+quota 作为机器池配额单位**:池级 qgroup 层级让 per-image usage/limit 变成纯 btrfs 查询(discover-image.c:2198-2230、2153-2173)。
5. **portable 的"无守护状态"**:attach 的全部状态就是文件系统上的 unit+drop-in+marker,detach/inspect 靠 marker 文本反向解析,无数据库(portable.c:60-63、2244-2304)。
6. **profile 作为安全基线机制**:镜像作者不写沙箱,发行方/管理员用 profile 统一注入,按 unit 类型分文件覆盖(portable-util.c:69-99)。
7. **image policy 让可信落在分区本身**:从 dissect 事实反推策略并钉进 drop-in,镜像签名/加密状态一旦固定,运行时挂载即受约束(image-policy.c:287-332)。
8. **user scope 全链路 userns/mountfsd**:使非 root 用户也能 import/pull/attach(外来 UID 落盘)(pull-tar.c:615-642、portable.c:626-644)。

## FAQ 候选

1. importd 自己下载镜像吗?——不,它 fork systemd-pull/import/export 子工具执行,自己只管编排与进度(importd.c:442-592)。
2. SHA256 是对什么算的?——对服务器上的原始压缩字节,在解压前增量计算(pull-job.c:246-251)。
3. 默认 verify 模式是什么?——signature(校验 checksum 并验其 GPG 签名),可 --verify=no/checksum 降级(importd.c:1160-1163、pull.c:34)。
4. 签名文件 404 怎么办?——按 .sha256.asc → .sha256.gpg → SHA256SUMS.gpg → SHA256SUMS.asc(校验和 .sha256 → SHA256SUMS)逐级回退(pull-common.c:756-812)。
5. 同一镜像重复 pull 会重下吗?——不会:旧 etag 列表触发 If-None-Match,304 即跳过下载与校验(pull-job.c:811-825、pull-tar.c:475-491)。
6. attach 的 drop-in 写到哪?——默认 /etc/systemd/system.attached,--runtime 时 /run/systemd/system.attached(path-lookup.c:308-309)。
7. 镜像里的哪些 unit 会被 attach?——仅 .service/.socket/.target/.timer/.path 后缀,且需匹配前缀或镜像 PORTABLE_PREFIXES(portable.c:76-96、2078-2102)。
8. detach 怎么知道该删哪些?——读 20-portable.conf 首行 marker 并与镜像列表 1:1 精确匹配(portable.c:2173-2304)。
9. QCOW2 镜像 pull 后可直接跑吗?——pull-raw 会检测魔数 0x514649fb 并按簇展开成普通 raw(pull-raw.c:228-271、qcow2-util.c:11)。
10. --user 拉取有何不同?——追加 IMPORT_FOREIGN_UID 经 mountfsd+userns 以外来 UID 落盘,且跳过 polkit(pull.c:544-545、pull-tar.c:615-642、importd.c:777-788)。

## 深挖方向

1. pull-oci 与 src/import/oci-registry/(registry.docker.io / registry.fedora 预置信任)的 OCI 分发协议实现与 pull-tar 的差异(pull-oci.c 全 1614 行;oci-util.c:409 行)。
2. IMAGE_MSTACK 多栈镜像类型在 discover/portable 中的落点与用途(discover-image.c:523、2519-2525;portable.c:1304 的 RootMStack=)。
3. import-generator 的开机拉取闭环:imports-pre.target/imports.target 顺序、sysext class 特殊处理与 initrd runtime 模式(import-generator.c:331-360、runtime=in_initrd() 于 91 行)。
4. image policy 字符串语法与 simplify 规则完整矩阵,以及 RootImagePolicy= 在 PID1/mountfsd 侧的执行路径(image-policy.c:336-360、467-530)。
5. Varlink 订阅式进度与 D-Bus 信号双轨语义差异,及 importd socket 激活(unit Requires=systemd-importd.socket)与空闲退出交互(importd.c:242-279、2032-2037;import-generator.c:345)。

## 正文蒸馏要点

1. importd 是纯编排器:Transfer 上限 64,下载全部由 fork 的 systemd-pull 等子工具完成(importd.c:124、442-592)。
2. 进度用 sd_notify `X_IMPORT_PROGRESS=` 上报,importd 转发为 D-Bus 信号与 varlink notify 双轨(importd.c:681-697、252-279)。
3. curl 经 dlopen + multi socket API 桥进 sd-event,协议白名单 HTTP/HTTPS/FILE,60 秒低速 abort(curl-util.c:181-301、424-437、602-631)。
4. PullJob 状态机 INIT→ANALYZING→RUNNING→DONE,先探测压缩再流式解压,压缩/未压缩各限 64GB(pull-job.c:514-528、764-765)。
5. sha256 按压缩字节计算;checksum 行匹配要求行首命中;GPG 用子进程+临时钥环验证(pull-job.c:246-251、pull-common.c:389-415、421-608)。
6. 默认 verify=signature;`--verify=` 也接受字面 64hex 摘要,此时不再下载 checksum/signature 等辅助文件(importd.c:1160-1163、pull.c:353-379)。
7. etag 缓存:文件名 `.tar-|.raw-<url>.<etag>`,超长 URL 用 siphash24 哈希,304 跳过下载与校验(pull-common.c:144-188、170-184;pull-tar.c:475-491)。
8. 落盘副作用集合:btrfs 子卷+池/子卷 quota、sparse write、nocow、qcow2 按簇展开、source_etag/source_url xattr、mtime/crtime 恢复(pull-tar.c:601-658、pull-job.c:466-493、pull-raw.c:228-271、390-392)。
9. 镜像发现按 class 搜索 /etc|/run|/var/lib|/usr*/lib/{machines,portables,extensions,confexts};DissectImage 的 os-release 验证即 path_is_os_tree(discover-image.c:61-118、dissect-image.c:2705-2722)。
10. portable attach = dissect(子进程 mountns)→ 抽 os-release+unit → 写 20-portable.conf(RootImage=/PORTABLE= 等)+ 10-profile.conf → 最后落 unit 本体,半原子序(portable.c:1712-1714、1446-1582、path-lookup.c:308)。
11. detach 依赖 20-portable.conf 首行 marker 的 1:1 镜像列表匹配,active 单元拒绝 detach(portable.c:2173-2304、2395-2401)。
12. 安全双轨:polkit 动作 org.freedesktop.import1.*/portable1.*(auth_admin/auth_admin_keep,user scope 豁免);镜像可信由分区级 image policy 从 dissect 结果推导并写为 RootImagePolicy=/ExtensionImagePolicy=(org.freedesktop.import1.policy:21-57、image-policy.c:287-332、portable.c:1475-1549)。
