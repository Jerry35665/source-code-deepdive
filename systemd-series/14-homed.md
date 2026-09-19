# 第 14 章 · homed:可移植家目录——编排者、三副本对账与令牌派生口令

> 基线:commit `1f66b524`。核心:src/home/(homed-home.c / homework.c / homework-luks.c / homed-manager.c)。

## 14.0 全景:homectl activate 的完整调用链

```
 homectl activate lennart(homectl.c:2048)
   ▼ D-Bus org.freedesktop.home1 → homed 守护进程(编排者,单事件循环)
   ▼ Home 状态机 26 态排队 Operation(homed-home.h:8-38)
   ▼ home_start_work:记录+secret 写 memfd,fork systemd-homework 子进程(homed-home.c:1291-1454)
   ▼ homework:LUKS 激活(认证五级瀑布)→ 挂载 → 结果经 memfd+sd_notify 回传
   ▼ 三副本 identity 记录按 lastChangeUSec 对账,"最新者胜"(homework.c:684-723)
```

纠偏:所有挂载/解密**不由 homed 自己做**——由 fork 出的 `systemd-homework` 子进程完成;状态机里"挂起未卸成"的状态叫 **HOME_LINGERING**(15 秒重试卸载,home-util.h:39),不存在 "dormant"。

## 14.1 五种存储与 LUKS2 头槽结构

`home_setup()` 按记录 storage 字段分派五路:LUKS/子卷/目录/fscrypt/CIFS(homework.c:515-535),文件系统白名单仅 ext4/btrfs/xfs(home-util.c:77-81);镜像名 `/home/<user>.home`,目录型 `.homedir`(inotify 按后缀发现)。LUKS2 元数据固定扩到 **4MB**("Largest LUKS2 supports",homework-luks.c:1821);每个有效口令各占一个 keyslot——口令/恢复钥用完整 PBKDF,**FIDO2/PKCS#11 派生的随机口令用最小 PBKDF(PBKDF2-1000)**,因为密钥本身高熵(:1760-1775);卷密钥是创建时随机生成的,不由任何口令派生(:1812-1817)。不止镜像文件:udev 监听 GPT 分区类型 SD_GPT_USER_HOME,按分区名 `user@realm` 直接合成 LUKS home——"U 盘随身家"(homed-manager.c:1206-1237)。

## 14.2 三副本 identity 对账

用户记录是带分区的 JSON:REGULAR/SECRET/PRIVILEGED/PER_MACHINE/BINDING/STATUS/SIGNATURE 七区块(user-record.h:38-44);secret 只在认证瞬间存活,privileged 放密钥哈希物,binding 记录某台机器的落盘绑定。三处副本:宿主 `/var/lib/systemd/home/<user>.identity`、**LUKS2 头 token(用卷密钥加密)**、家目录内 `~/.identity`;激活时按 lastChangeUSec 对账最新者胜(homework.c:684-723),update 走 REQUIRE_NEWER(嵌入副本必须严格更新否则 -ESTALE)。纠偏式动机(注释原文):头部记录独立于文件系统存储,是为了**先验记录、后挂文件系统**——"kernel file system implementations are generally not ready to be used on untrusted media"(homework-luks.c:1070-1076);口令校验因此发生在挂载之前。

## 14.3 令牌不直接解锁 LUKS

纠偏:FIDO2/PKCS#11 **不直接解锁 LUKS**——令牌只派生一个随机口令去开 keyslot(homectl-fido2.c:84-98:令牌 HMAC 派生秘密 base64+UNIX 哈希存 privileged.fido2HmacSalt;PKCS#11 用令牌公钥加密随机密钥,homectl-pkcs11.c:98-134;恢复钥 modhex64 同写 privileged/public/secret 三处,homectl-recovery-key.c:116-150)。认证是五级瀑布:密钥环卷密钥→口令→恢复钥→缓存派生口令→现场令牌探测(homework.c:96-269)。

## 14.4 守护进程:D-Bus 管理、varlink 只读

纠偏:varlink **不是管理接口**——管理全走 D-Bus(org.freedesktop.home1);varlink 只实现 io.systemd.UserDatabase 三个只读查询方法(userdb/NSS 面),响应按 peer UID 决定信任级别:root 或本人可看 PRIVILEGED,否则 STRIP_PRIVILEGED,SECRET 恒剥离(homed-manager.c:1080-1088; homed-varlink.c:28-56)。userdb 客户端按 socket xattr 通告的 UID 区间 60001-60513 路由查询。客户端引用靠两根 FIFO(please-suspend/dont-suspend)计数,写端全关即 EOF 触发 release(homed-home.c:2835-2886);挂载期间持 pin_fd 让顶层目录保持 busy;登出卸载失败每 15s 重试(lingering)。

## 14.5 设计动机

1. **编排与执行分离**:特权与解析逻辑在 homework 子进程里跑完即退,内存中的 secret 生命周期最短(homed-home.c:1291-1454);
2. **三副本时间戳对账**:宿主/头 token/内嵌三方可独立演化,离线改动靠 lastChangeUSec 仲裁(homework.c:684);
3. **头部先于文件系统**:口令校验在挂载前完成,不可信介质不运行内核 FS 代码(homework-luks.c:1070-1076);
4. **令牌派生口令而非直接解锁**:令牌不可用时仍可用普通口令,同一 LUKS 槽体系(homework-luks.c:1760-1775);
5. **FIFO 引用计数**:挂起的 home 在无消费者时自动释放(homed-home.c:2835-2886);
6. **管理/查询双面**:D-Bus 面向管理工具,varlink 面向 userdb/NSS 生态,信任级别按 peer 区分。

## 14.6 FAQ

**Q1:home 目录有几种存储?**
五种:LUKS2 镜像/子卷/目录/fscrypt/CIFS(homework.c:515-535)。

**Q2:挂起未卸成的状态叫什么?**
HOME_LINGERING,15 秒重试(home-util.h:39);没有 dormant 态。

**Q3:LUKS2 头多大?**
固定 4MB,注释称 LUKS2 支持的最大值(homework-luks.c:1821)。

**Q4:FIDO2 直接解密数据吗?**
不,只派生一个随机口令开 keyslot,该口令用 PBKDF2-1000 落槽(:1760-1775)。

**Q5:用户记录改了会冲突吗?**
三副本按 lastChangeUSec 最新者胜;update 要求嵌入副本严格更新否则 -ESTALE(homework.c:684-723, 1697)。

**Q6:为什么记录存 LUKS 头而不存文件系统里?**
口令校验须在挂载前;内核 FS 代码不适合在不可信介质上运行(homework-luks.c:1070-1076)。

**Q7:homed 的管理接口是什么?**
D-Bus org.freedesktop.home1;varlink 只做 userdb 只读查询(homed-manager.c:1080-1088)。

**Q8:别的用户能查到我的记录吗?**
PRIVILEGED 区块仅 root/本人可见,SECRET 恒剥离(homed-varlink.c:28-56)。

**Q9:U 盘上的家目录怎么被识别?**
udev 监听 SD_GPT_USER_HOME 分区类型,按分区名 user@realm 合成(homed-manager.c:1206-1237)。

**Q10:用户态怎么"占用"一个 home?**
写 please-suspend/dont-suspend FIFO 持引用,全关即释放(homed-home.c:2835-2886)。

## 14.7 小结与深挖方向

本章结论:**homed=编排者守护进程+homework 调用子进程+五种存储+三副本 JSON 对账+令牌派生口令**。深挖:

1. user_record_reconcile 的 REQUIRE_NEWER 三档语义与 -ESTALE 路径(user-record-util.h:15-19);
2. 空间回收 REBALANCE 状态机与 83% 默认配额(home-util.c:19);
3. SYSTEMD_LUKS_LOCK 的 BSD 锁交接细节(homed-home.c:1400-1404);
4. fscrypt 后端的密钥描述符管理(homework-fscrypt.c);
5. CIFS 后端与 kerberos 凭据的衔接(homework-cifs.c)。
