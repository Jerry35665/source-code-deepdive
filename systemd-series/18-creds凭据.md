# 第 18 章 · systemd-creds:信任桶、AES256-GCM 格式与"服务只见明文"

> 基线:commit `1f66b524`。核心:src/core/import-creds.c / src/shared/creds-util.c / src/creds/creds.c / src/core/exec-credential.c。

## 18.0 全景:一条加密凭据的一生

```
 systemd-creds encrypt --name=app.dbpw - (root 或 Varlink IPC+polkit)
   ▼ AES256-GCM:明文头(id+尺寸+IV)→[TPM2/公钥/pinned SRK/scoped 头]→密文→tag
   │  "整份文件要么是 AAD、要么是密文、要么是 tag,无未保护数据"(creds-util.c:706-708)
   ▼ SetCredentialEncrypted=app.dbpw:base64(嵌入单元)
 PID1 启动:解密(read_credential_with_decryption,仅供 generators/PID1)
   ▼ /run/credentials/<unit>/ 只读 noswap 文件系统挂进沙箱
   ▼ 服务进程:read_credential() 只见已解密明文 + $CREDENTIALS_DIRECTORY
```

纠偏:内核命令行上**不存在 `systemd.credentials=`**——真实选项是 `systemd.set_credential=`/`systemd.set_credential_binary=`,写入 `/run/credentials/@system` 桶(import-creds.c:338-341);总开关 systemd.import_credentials=,null key 接受策略由 systemd.credentials_boot_policy=(strict/tofu/relaxed/off,缺省 relaxed)。

## 18.1 四个来源与两个信任桶

PID1 启动期从 sd-boot 的 /.extra/credentials/、/proc/cmdline、qemu fw_cfg、SMBIOS OEM 串收集凭据(import-creds.c:39-67):ESP 来的进 **@encrypted**(不可信)桶,命令行/固件进 **@system** 桶(creds-util.h:33-34);日志里分别叫 "regular" 与 "untrusted credentials"——PID1 自己能读的只是"未加密但来自可信通道"的凭据。每个来源过同一闸门:credential_name_valid+单凭据/总量上限(CREDENTIAL_SIZE_MAX=1MiB),O_EXCL|0400 独占创建、重名忽略——"先到先得"。目录不是普通目录:优先挂"支持 noswap 的 tmpfs"(内核 ≥6.3)→ramfs→tmpfs,nodev/noexec/nosuid/nosuid,导入完重挂只读。机密虚拟化下默认不信任固件通道,唯一例外 Intel TDX(SMBIOS 被 TDVF 测量进 RTMR0)(import-creds.c:625-633)。

## 18.2 加密格式与密钥派生

名称规则:必须是合法文件名+合法 fd 名(≤255);glob 仅允许**尾部一个** `*`。密钥=SHA256(host key /var/lib/systemd/credential.secret 4KB 随机数 / TPM2 对 nonce 的 HMAC / 两者拼接 / null);host+TPM2 时另有 per-UID "scoped" 变体(UID/用户名/machine-id HMAC 进密钥,creds-util.c:821-869)。文件格式全小端 8 字节对齐:头部 16 个真实密钥类型 ID(+5 个不上盘的 _CRED_AUTO* 内部 ID);metadata 头(timestamp/not_after/name)在密文内部——名字与目标不符拒绝(可用 $SYSTEMD_CREDENTIAL_VALIDATE_NAME 放行),not_after 过期同理(:1662-1694);GCM tag 校验失败一律 -EBADMSG(不依赖 OpenSSL errno 翻译,:1636-1640)。

## 18.3 工具面与运行时挂载

纠偏:`systemd-creds` **没有 print 子命令**——读取是 `cat`,list 是默认子命令(creds.c:315, 476);`--with-key=tpm2` 实际写入 **pinned-SRK** 变体而非裸 TPM2 HMAC ID(creds.c:134-139);tpm2-absent 是旧名等同 null。非 root 加解密走 /run/systemd/io.systemd.Credentials Varlink 服务+polkit+±30s 时间戳新鲜度约束(creds-util.c:1790-1797)。运行时:有特权时单元凭据是独立 noswap 文件系统整体 fsconfig 转 ro;无特权时 workspace+RENAME_EXCHANGE **原子换入**——凭据可跨 mount namespace 刷新;沙箱内再以只读 bind 覆盖,无凭据单元直接 MOUNT_INACCESSIBLE 遮蔽 /run/credentials(exec-credential.c:952-1108; namespace.c:2973-3020)。

## 18.4 设计动机

1. **两个信任桶**:可信通道明文直读,ESP 密文必须显式解密——信任级别决定 API 面(import-creds.c:44-50);
2. **服务只见明文**:解密复杂度(密钥选择/TPM 会话)全部收敛在 PID1,服务端零依赖(creds-util.c:190-200);
3. **metadata 在密文内**:名字/时间戳不可被旁观者篡改或枚举(:711-756);
4. **先到先得导入**:同名凭据以最先到达为准,防后置来源覆盖(:115-131);
5. **RENAME_EXCHANGE 原子刷新**:运行中的服务能看到凭据更新而无半状态(exec-credential.c:1054-1108);
6. **noswap tmpfs**:凭据页永不换出 swap(mount-util.c:1984-1999)。

## 18.5 FAQ

**Q1:内核命令行怎么传凭据?**
systemd.set_credential=/set_credential_binary=,没有 systemd.credentials=(import-creds.c:338-341)。

**Q2:服务读到的是密文吗?**
不是,PID1 已解密;服务只见明文+环境变量(creds-util.c:190-200)。

**Q3:@system 和 @encrypted 区别?**
可信通道 vs ESP 不可信来源;后者必须 LoadCredentialEncrypted= 解密。

**Q4:凭据名有什么规则?**
合法文件名+fd 名,≤255;glob 仅尾部一个 *(creds-util.c:49-91)。

**Q5:--with-key=tpm2 写的什么格式?**
pinned-SRK 变体,非裸 HMAC ID(creds.c:134-139)。

**Q6:有 print 子命令吗?**
没有,读取用 cat;--pretty 是 encrypt 的输出修饰(creds.c:476, 646-662)。

**Q7:非 root 能加密凭据吗?**
能,经 Varlink 服务+polkit+时间戳新鲜度约束(creds-util.c:1790-1797)。

**Q8:名字不匹配会怎样?**
拒绝(EDESTADDRREQ);$SYSTEMD_CREDENTIAL_VALIDATE_NAME 可显式放行(creds-util.c:1672-1680)。

**Q9:凭据目录在服务里可写吗?**
只读;无凭据单元整个 /run/credentials 被 inaccessible 遮蔽(namespace.c:2973-3020)。

**Q10:null key 什么时候被接受?**
boot policy 决定:relaxed 缺省下非 SecureBoot 或无 TPM2 时接受(creds-util.c:401-408)。

## 18.8 小结与深挖方向

本章结论:**凭据=PID1 导入两桶+AES256-GCM 三类密钥+服务只见明文;挂载层 noswap+只读+原子换入**。深挖:

1. scoped 变体的 UID HMAC 与多用户服务的配合(creds-util.c:821-869);
2. io.systemd.Credentials Varlink 服务的时间戳防重放窗口(:1790-1797);
3. ImportCredential= 的 glob 展开与单元级过滤(exec-credential.c);
4. TDX 例外把 SMBIOS 纳入测量的正确性边界(import-creds.c:625-633);
5. initrd→host 切换时 @initrd 桶的搬空语义(:658-745)。
