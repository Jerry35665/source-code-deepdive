# 报告 B3 · homed 可移植家目录(systemd 卷三)

> 基线:1f66b524——homed 把用户家目录做成"LUKS2 镜像/fscrypt/子卷/普通目录/CIFS 五种可搬运存储 + JSON 用户记录三副本对账"的自服务单元:homed 守护进程只做编排与状态机,所有挂载/解密实际由 fork 出的 systemd-homework 子进程完成,管理面走 D-Bus(org.freedesktop.home1),userdb 查询面走 varlink。

## 一、概念与模型:五种存储、LUKS2 头与槽

homed 并非"只有 LUKS 镜像"一种存储:`home_setup()` 按记录里的 `storage` 字段分派五路,其中 LUKS 由 homework-luks.c 承担,目录/子卷/fscrypt 共用 directory 一路,CIFS 单独一路(homework.c:515-535)。支持的文件系统白名单仅 ext4/btrfs/xfs(home-util.c:77-81)。镜像名约定为 `/home/<user>.home`、目录型为 `/home/<user>.homedir`(inotify 按 `.home`/`.homedir` 后缀发现,homed-manager.c:168)。

```c
// homework.c:515
switch (user_record_storage(h)) {
case USER_LUKS:
        return home_setup_luks(h, flags, NULL, setup, cache, ret_header_home);
case USER_SUBVOLUME:
case USER_DIRECTORY:
        r = home_setup_directory(h, setup);
        break;
case USER_FSCRYPT:
        r = home_setup_fscrypt(h, flags, setup, cache);
        break;
case USER_CIFS:
        r = home_setup_cifs(h, flags, setup);
        break;
```

LUKS2 后端的"头与槽"三层结构:镜像(或裸分区)经 loop 设备接 cryptsetup;LUKS2 元数据固定扩到 4MB;每个"有效口令"各占一个 keyslot——口令/恢复钥用完整 PBKDF,FIDO2/PKCS#11 派生出的随机口令用最小 PBKDF(PBKDF2 1000 次迭代,因为密钥本来就是高熵随机值,homework-luks.c:1760-1775)。卷密钥本身是创建时随机生成的(homework-luks.c:1812-1817),不由任何口令"派生"。

```c
// homework-luks.c:1821
r = sym_crypt_set_metadata_size(cd, 4096U*1024U, 0);   /* 4M,Largest LUKS2 supports */
...
r = sym_crypt_format(cd, CRYPT_LUKS2, ..., &(struct crypt_params_luks2) {
        .label = label,
        .subsystem = "systemd-home",
        .sector_size = sector_size,
        .pbkdf = &good_pbkdf,
});
// homework-luks.c:1856
if (password_cache_contains(cache, *pp))  /* fido2/pkcs11 派生口令 */
        r = sym_crypt_set_pbkdf_type(cd, &minimal_pbkdf);
...
r = sym_crypt_keyslot_add_by_volume_key(cd, slot, volume_key, volume_key_size, *pp, strlen(*pp));
```

LUKS 后端不只支持镜像文件:udev 监听 GPT 分区类型 `SD_GPT_USER_HOME` 的插入,按分区名 `user@realm` 直接合成 LUKS home(即"U 盘随身家"),homed-manager.c:1206-1237。所有操作参数打包在 `HomeSetup` 结构中,含 undo_dm/undo_mount 回滚位与 `/run/systemd/user-home-mount` 工作挂载点(homework.h:27-61、homework.h:113)。

## 二、identity 记录:JSON 用户记录、三处副本与 reconcile

用户记录是带分区的 JSON 对象,按 mask 分七个区块:REGULAR/SECRET/PRIVILEGED/PER_MACHINE/BINDING/STATUS/SIGNATURE(src/shared/user-record.h:38-44)。`secret` 只在认证瞬间存活;`privileged` 放 pkcs11EncryptedKey/fido2HmacSalt/recoveryKey 等哈希物;`binding` 记录某台机器上的落盘绑定(存储类型、image path、LUKS/文件系统 UUID、UID,homectl 侧由 user_record_add_binding 写入,homework-directory.c:237-252)。密钥注册发生在 homectl 客户端:`--fido2-device=` 调 `identity_add_fido2_parameters`(homectl.c:1064),令牌 HMAC 派生秘密经 base64 后 UNIX 哈希存入 `privileged.fido2HmacSalt`,up/uv/clientPin 策略一并记录(homectl-fido2.c:84-98);`--recovery-key=1` 生成 modhex64 恢复钥并同写 privileged/public/secret 三处(homectl-recovery-key.c:116-150);PKCS#11 则用令牌公钥加密随机密钥存 `pkcs11EncryptedKey`(homectl-pkcs11.c:98-134)。

同一份记录存在三处副本:宿主机 `/var/lib/systemd/home/<user>.identity`(home-util.c:148-150)、LUKS2 头部 token、家目录内 `~/.identity`。激活时三方按 `lastChangeUSec` 时间戳对账,"最新者胜":

```c
// homework.c:684
/* At this point we have three records to deal with:
 *      · The record we got passed from the host
 *      · The record included in the LUKS header (only if LUKS is used)
 *      · The record in the home directory itself (~/.identity)
 *  Now we have to reconcile all three, and let the newest one win. */
// homework.c:723
r = user_record_reconcile(h, embedded_home, mode, &new_home);
```

对账模式有 ANY/REQUIRE_NEWER/REQUIRE_NEWER_OR_EQUAL 三档(user-record-util.h:15-19),update 走 REQUIRE_NEWER(嵌入副本必须严格更新,否则 -ESTALE,homework.c:1697),passwd 走 REQUIRE_NEWER_OR_EQUAL(homework.c:1799)。头部副本的写入用卷密钥自身加密后放进 `systemd-homed` 类型 token:

```c
// homework-luks.c:1070
/* Let's store the user's identity record in the LUKS2 "token" header data fields, in an encrypted
 * fashion. ... If we'd rely on the record being embedded in the payload file system itself we
 * would have to mount the file system before we can validate the JSON record ... kernel file
 * system implementations are generally not ready to be used on untrusted media. */
r = user_record_clone(h, USER_RECORD_EXTRACT_EMBEDDED|USER_RECORD_PERMISSIVE, &header_home);
...
r = sym_crypt_token_json_set(setup->crypt_device, token, text);   // :1106
```

读取侧 `luks_validate_home_record` 用卷密钥解 token 里的 base64 记录并做严格认证(homework-luks.c:865-968),因此口令校验在挂载文件系统**之前**完成——这是"记录独立于文件系统存储"的核心动机。与 userdb 的关系:记录的 REGULAR/PER_MACHINE 等公开区块经 varlink `GetUserRecord` 输出给 NSS(userdb 客户端按 socket 上的 `user.userdb.uid` xattr 通告的 UID 区间 60001–60513 路由查询,homed-manager.c:1109-1112;区间定义见 src/basic/user-util.h:16-17)。

## 三、homed 守护进程:Manager 事件循环与 Home 状态机

homed 是单事件循环服务:`run()` 依次 manager_new → manager_startup → `sd_event_loop(m->event)`(homed.c:48-62)。startup 串起 notify socket、D-Bus、varlink、密钥对加载、/home inotify、udev 监听与三类枚举(homed-manager.c:1544-1587)。签名密钥按 KEY_PATHS_NULSTR 五目录查找,`/var/lib/systemd/home/` 居中,便于首次自动生成(homed-manager.c:70-78)。

```c
// homed-manager.c:1080
r = sd_varlink_server_bind_method_many(
        m->varlink_server,
        "io.systemd.UserDatabase.GetUserRecord",  vl_method_get_user_record,
        "io.systemd.UserDatabase.GetGroupRecord", vl_method_get_group_record,
        "io.systemd.UserDatabase.GetMemberships", vl_method_get_memberships, ...);
// homed-manager.c:1101
socket_path = "/run/systemd/userdb/io.systemd.Home";
```

注意 varlink 不是管理接口:管理全走 D-Bus(org.freedesktop.home1,homed-manager-bus.c:1136 起),varlink 只实现 io.systemd.UserDatabase 三个查询方法;查询响应按 peer UID 决定信任级别——root 或本用户本人可看 PRIVILEGED,否则 STRIP_PRIVILEGED,SECRET 恒剥离(homed-varlink.c:28-42、52-56)。homed 还给自己设 `SYSTEMD_BYPASS_USERDB` 防递归查询(homed-manager.c:1124)。

Home 对象的状态机比外界描述的丰富得多:26 个状态(homed-home.h:8-38),且 `state` 字段只在"正在做事"时有效,平时置 INVALID,由 `home_get_state()` 按需从挂载表/镜像存在性推导(homed-home.h:116-120 注释、homed-home.c:2218-2240):

```c
// homed-home.c:2222
/* When the state field is initialized, it counts. */
if (h->state >= 0)
        return h->state;
/* Otherwise, let's see if the home directory is mounted. */
if (user_record_test_home_directory(h->record) == USER_TEST_MOUNTED)
        return h->retry_deactivate_event_source ? HOME_LINGERING : HOME_ACTIVE;
```

客户端引用靠两根 FIFO(`/run/systemd/home/<user>.{please-suspend,dont-suspend}`)做引用计数,写端全部关闭即 EOF 触发 release(homed-home.h:140-146、homed-home.c:2835-2886)。排队操作由 `on_pending` defer 源分派 6 种 Operation(ACQUIRE/RELEASE/LOCK_ALL/DEACTIVATE_ALL/PIPE_EOF/DEACTIVATE_FORCE,homed-home.c:3196-3203);登出后卸载失败(仍有进程占用)则每 15s 重试,即 lingering 态的由来(home-util.h:39、homed-home.c:496-521)。挂载期间 homed 持 `pin_fd` 让顶层目录保持 busy(homed-home.h:162-163),LUKS 设备的互斥由 worker 经 `SYSTEMD_LUKS_LOCK` 请求 BSD 锁并经 sd_notify 把锁 fd 交回 manager(homed-home.c:1400-1404、homed-home.c:2250-2264)。空间回收是独立小状态机:REBALANCE_OFF→…→SHRINKING/GROWING(homed-manager.h:8-17),默认配额为可用空间的 83%(home-util.c:19 断言)。

## 四、activate 全路径

```c
// homed-home.c:1291 home_start_work():把记录+secret 写 memfd,fork worker
stdin_fd  = memfd_new_and_seal_string("request", formatted);      // :1365
stdout_fd = memfd_new("homework-stdout");                         // :1380
r = pidref_safe_fork_full("(sd-homework)", ..., &pid);            // :1385
...
r = invoke_callout_binary(SYSTEMD_HOMEWORK_PATH,
                          STRV_MAKE(SYSTEMD_HOMEWORK_PATH, verb)); // :1431
```

`homectl activate lennart` 完整调用链(本 commit 源码核实):

```text
homectl activate lennart                                    homectl.c:2048 verb_activate_home
  │  acquire_passed_secrets() 取口令/令牌 PIN                homectl.c:2059
  │  D-Bus: ActivateHome(user, secret)                      homectl.c:2067-2079
  │     超时 HOME_SLOW_BUS_CALL_TIMEOUT_USEC = 2min          home-util.h:36
  ▼
systemd-homed
  │  method_activate_home → polkit 鉴权                      homed-manager-bus.c:350
  │  bus_home_method_activate:读 secret → home_activate()    homed-home-bus.c:179
  ▼
Home 状态检查 home_activate()                                homed-home.c:1557
  │  UNFIXATED→先 inspect 定着;ACTIVE→EALREADY;LINGERING→取消卸载定时器
  │  home_ratelimit() 失败计数限速                            homed-home.c:1587
  │  home_start_work("activate", record+secret)  fork worker  homed-home.c:1549
  ▼
systemd-homework activate(stdin=memfd 记录)                  homework.c:2128 分派
  │  user_record_authenticate(h,h) 首轮口令/令牌校验          homework.c:934
  │  test_home_directory/test_image_path 预检                 homework.c:938-948
  │  ├─ LUKS:      home_activate_luks                        homework-luks.c:1581
  │  │    home_get_state_luks:dm 已存在→EEXIST                 :1606
  │  │    home_setup_luks:                                     :1276
  │  │      open 镜像/分区 → luks_validate(GPT/UUID/扇区)      :1416
  │  │      标脏 xattr user.home-dirty                          :1430
  │  │      loop_device_make → luks_setup(crypt_activate)      :1444,:1462
  │  │      luks_validate_home_record:解密 token 记录+严格认证  :1482
  │  │      run_fsck → unshare+mount → root_fd                 :1491-1503
  │  │    home_auto_grow_luks(可选在线扩)                      :1622
  │  ├─ 目录/子卷/fscrypt: home_activate_directory            homework-directory.c:66
  │  │    bind mount 到 /run/systemd/user-home-mount(MS_PRIVATE)
  │  │    home_refresh → home_move_mount 到最终家目录           :101
  │  └─ CIFS: home_activate_cifs                              homework.c:963
  │  home_refresh:三方 reconcile→写 LUKS token→写 .identity
  │    →chown 递归→syncfs                                     homework.c:866-914
  ▼
worker 结束:sd_notify(ERRNO=)先行、stdout memfd 带回新记录
  home_on_worker_process → home_parse_worker_stdout           homed-home.c:1204,553
  home_activate_finish:验签→home_set_record→home_save_record
    →清 state→manager_schedule_rebalance                      homed-home.c:824-873
```

populating 只发生在**创建**时:`home_populate()` 拷贝 /etc/skel、写 .identity、建 blob 目录、递归 chown、设访问模式(homework.c:1115-1142);目录型创建还会尝试 btrfs 子卷+配额,失败降级普通目录,并尝试 UID 映射挂载(btrfs 成功时映射到 nobody,homework-directory.c:144-212)。"activate 时 setrlimit/watch"在本 commit 源码中不存在——挂载后并无 rlimit 设置或 inotify 监听家目录的代码路径(未核实到任何此类调用,应为讹传;相关机制是 manager 层的 /home inotify 与 rebalance,见 §三)。

## 五、deactivate 路径、fsync 与崩溃安全

卸载是"先搬运后拆除":先把家目录 bind mount 到运行时工作目录并打开 root_fd,再从原位 umount(支持 MNT_FORCE/MNT_DETACH 强拆),随后 LUKS 路径做 logout 瘦身(fitrim)、syncfs、可选自动收缩,最后 detach DM 设备并清内核密钥环(homework.c:984-1076):

```c
// homework.c:1006-1036(节选)
r = mount_nofollow_verbose(LOG_ERR, user_record_home_directory(h),
                           HOME_RUNTIME_WORK_DIR, NULL, MS_BIND, NULL);
...
r = umount_verbose(LOG_ERR, user_record_home_directory(h),
                   UMOUNT_NOFOLLOW | (force ? MNT_FORCE|MNT_DETACH : 0));
if (user_record_storage(h) == USER_LUKS) {
        password_cache_load_keyring(h, &cache);   /* 卷密钥从 keyring 取回 */
        (void) home_trim_luks(h, &setup);
}
if (syncfs(setup.root_fd) < 0) ...               /* 显式 sync,供 drop caches */
...
if (user_record_storage(h) == USER_LUKS)
        (void) home_auto_shrink_luks(h, &setup, &cache);
```

崩溃安全三板斧。其一,镜像脏标记:激活改动前打 `user.home-dirty` xattr,正常卸载时先 fsync_full 再摘除(homework-luks.c:87-120),下次激活看到脏标记即报 `USER_TEST_DIRTY`(homed-home.c:2235-2236)。其二,记录文件原子写+SYNC:宿主记录经 `WRITE_STRING_FILE_ATOMIC|...|WRITE_STRING_FILE_SYNC` 落盘(homed-home.c:355-360);`~/.identity` 用临时名+renameat 原子替换(homework.c:606-633)。其三,fscrypt v2 密钥回滚:RAII 结构 FscryptV2KeyUndo 在 teardown 时从文件系统密钥环移除 v2 主密钥,激活成功才解除武装(homework.h:12-25、homework-directory.c:107-110)。卸载完成后还有 `drop_caches_now()` 清页缓存(homework.c:1069-1072)、离线 fallocate/fitrim 收缩镜像(homework-luks.c:1718-1723)。坏口令响应被强制对齐到 3 秒的整数倍以抗时序侧信道(homework.c:2152-2168)。

## 六、认证体系与 PAM/userdb 协作

worker 内一次激活要做最多三层认证(宿主记录→LUKS 头记录→~/.identity),`user_record_authenticate` 的尝试顺序:内核密钥环卷密钥快捷通道→明文口令→恢复钥→已缓存的 PKCS#11/FIDO2 派生口令→现场探测令牌;各类失败按严重度排序返回(homework.c:96-100、102-133、271-295)。已解密的派生口令进 PasswordCache,同一操作内后续两层免令牌交互(homework.c:79-93 注释)。

```c
// homework.c:96
if (cache->volume_key &&
    sd_json_variant_is_blank_object(sd_json_variant_by_key(secret->json, "secret"))) {
        log_info("LUKS volume key from keyring unlocks user record.");
        return 1;
}
```

PAM 模块 pam_systemd_home 的策略是三级降级循环:优先 `RefHome()`(免认证取引用,适用于已激活或非加密家),失败(如 HOME_NOT_ACTIVE)则升级 `AcquireHome()`,再失败且允许时 `RefHomeUnrestricted()` 兜底(SSH 场景:登录先放行,由 fallback shell 再补口令提示);整个循环最多 5 次,成功后把 home 引用 fd 存进 PAM 数据,并回写 PAM_AUTHTOK(pam_systemd_home.c:548-568、604-717、720-724)。open_session 走免认证路径,chauthtok 单独实现改密(pam_systemd_home.c:843-900、1085)。userdb 侧:homed 的三个 varlink 方法按 `service` 字段校验 socket 名(BadService,homed-varlink.c:103-104),组记录从用户记录现场合成(group_record_synthesize,homed-varlink.c:162-167),成员关系来自记录的 memberOf 字段加"同名自组"(homed-varlink.c:301-313)。

## 七、纠偏、设计动机、FAQ 候选与深挖方向

纠偏(以 1f66b524 源码为准):
- "homed 直接挂载家目录"不成立:挂载/解密全部在 fork 的 systemd-homework 子进程内完成,结果经 memfd+sd_notify 回传(homed-home.c:1291-1454);worker 崩溃由 `homes_by_worker_pid` 哈希表对账(homed-manager.c:1150)。
- 状态名里没有 "dormant":挂起但未卸成的状态叫 HOME_LINGERING,靠 15s 重试定时器维持(homed-home.h:20、home-util.h:39)。
- "FIDO2/PKCS#11 直接解开 LUKS"不成立:令牌只是派生出一个随机口令,再以该口令开 LUKS keyslot;派生口令以最小 PBKDF 落槽(homework.c:219-269、homework-luks.c:1835-1842)。
- "记录只存在 ~/.identity"不成立:三副本(宿主/LUKS 头 token/~/.identity)按 lastChangeUSec 对账,头部副本用卷密钥加密、先验记录后挂文件系统(homework.c:684-690、homework-luks.c:1070-1076)。
- "varlink 是 homed 管理 API"不成立:管理走 D-Bus org.freedesktop.home1,varlink 仅实现 userdb 三个只读查询(homed-manager.c:1080-1088)。
- LUKS 后端不止加密镜像:支持 GPT `SD_GPT_USER_HOME` 裸分区(U 盘拔插即插即用)(homed-manager.c:1211-1237)。

设计动机列表:
1. 记录先于文件系统可验证:头部 token 使口令校验、签名校验发生在 mount 之前,规避在不可信介质上执行内核文件系统代码(homework-luks.c:1070-1076)。
2. 时间戳对账而非主从同步:三副本任一可独立演进(离线改密、异机使用),最新者胜使多机携带语义自洽(homework.c:684-690)。
3. worker 进程隔离:mount/unshare/cryptsetup 等高危操作限制在短命子进程,崩溃不伤守护进程,RAII 回滚位保证半途失败不留挂载(homework.h:47-52)。
4. 每用户 UID 区间隔离:60001–60513 专用于 homed,配合 UID 映射挂载使未激活用户的 UID 不可见(src/basic/user-util.h:16-17、homework-directory.c:202-210)。
5. 引用计数即生命周期:FIFO 写端引用让"最后一个用户登出才卸载"无需轮询,please-suspend/dont-suspend 两根还表达系统挂起时的意愿分歧(homed-home.h:140-146)。
6. 失败代价显性化:脏标记 xattr、原子记录写、v2 密钥回滚,把断电/崩溃后的状态收敛为"要么干净要么显式 DIRTY"(homework-luks.c:87-120)。

FAQ 候选(每条一句话答案):
1. homed 管理的用户 UID 范围?60001–60513(src/basic/user-util.h:16-17)。
2. `~/.identity` 是什么?家目录内嵌的用户记录副本,与宿主记录、LUKS 头 token 三方按时间戳对账(homework.c:684-690)。
3. 忘记口令怎么办?用恢复钥(modhex64)当口令输入即可,它有独立哈希与 keyslot(homectl-recovery-key.c:32-33)。
4. FIDO2 解锁的原理?令牌 HMAC 派生秘密→base64→作为 LUKS/fscrypt 的一个口令,hashedPassword 只用于本地核对(homectl-fido2.c:84-90)。
5. 为什么登录慢?worker 要做 PBKDF、fsck、递归 chown、syncfs,故 D-Bus 超时放宽到 2 分钟(home-util.h:36)。
6. 登出时家目录没卸载会怎样?进入 lingering,每 15 秒重试卸载直到成功(home-util.h:39)。
7. 磁盘紧张时 homed 会做什么?按 rebalance 权重先缩后胀各 LUKS 镜像,默认权重使新建即占可用空间 83%(homed-manager.h:8-17、home-util.c:19)。
8. 家目录能否真放 U 盘上?能,GPT 分区类型 SD_GPT_USER_HOME 插入即被 udev 发现并合成记录(homed-manager.c:1211-1237)。
9. fscrypt 后端和老版本有何不同?新家默认 v2 密钥(文件系统密钥环,bind mount/容器可见),v1 依赖进程密钥环(homework-fscrypt.c:49-51)。
10. root/nobody 能被 homed 管理吗?不能,suitable_user_name 显式排除 root/nobody/systemd-/_ 前缀(home-util.c:35-44)。

深挖方向:
1. `home_refresh` 中 UID 迁移(home_maybe_shift_uid)与 ID 映射挂载的完整语义(homework.c:889)。
2. rebalance 状态机的调度间隔与权重推导(manager_schedule_rebalance,homed-manager.c:2101 起)。
3. LUKS 头 token 的 cipher 选择:如何由 DM 设备的加密参数反推 EVP cipher(crypt_device_to_evp_cipher,homework-luks.c:798)。
4. CIFS 后端与 Kerberos 凭据的交互(homework-cifs.c)。
5. blob 目录(`/var/cache/systemd/home/`)与 fdmap 传 fd 机制(homework-blob.c、homework.c:2049-2088)。

## 八、正文蒸馏要点

1. homed 是编排者而非执行者:五路存储分派在 worker(homework.c:515-535),fork 与 memfd 回传在 homed-home.c:1291-1454。
2. 存储五分:LUKS/子卷/目录/fscrypt/CIFS;文件系统白名单 ext4/btrfs/xfs(homework.c:515-535、home-util.c:77-81)。
3. LUKS2 元数据 4MB,卷密钥随机生成,每口令一 keyslot;令牌派生口令用 PBKDF2-1000 最小 PBKDF(homework-luks.c:1821、1812-1817、1760-1775)。
4. 用户记录七区块,secret 恒剥离、privileged 按信任发放(src/shared/user-record.h:38-44、homed-varlink.c:52-56)。
5. 三副本对账以 lastChangeUSec 定胜负,update/passwd 分别用 REQUIRE_NEWER 与 REQUIRE_NEWER_OR_EQUAL(homework.c:684-690、1697、1799)。
6. 头部 token 用卷密钥加密用户记录,先验证后挂载,防御不可信介质(homework-luks.c:1070-1076、865-968)。
7. 状态机 26 态且惰性求值:平时无状态,按挂载表/镜像存在性现场推导(homed-home.h:8-38、homed-home.c:2222-2239)。
8. 客户端引用靠双 FIFO 计数;卸载失败转 lingering 每 15s 重试(homed-home.c:2835-2886、home-util.h:39)。
9. 认证五级瀑布:密钥环卷密钥→口令→恢复钥→缓存派生口令→现场令牌探测(homework.c:96-269)。
10. PAM 三级降级 RefHome→AcquireHome→RefHomeUnrestricted,5 次上限,fd 存 PAM 数据(pam_systemd_home.c:548-568、711-717)。
11. 崩溃安全:user.home-dirty xattr + 原子/SYNC 记录写 + fscrypt v2 密钥回滚(homework-luks.c:87-120、homed-home.c:355-360、homework.h:12-25)。
12. 管理面 D-Bus、查询面 varlink(userdb);坏口令响应按 3s 整数倍延迟抗时序侧信道(homed-manager.c:1080-1088、homework.c:2152-2168)。
