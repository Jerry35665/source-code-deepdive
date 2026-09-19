# 第 16 章 · importd 与 portabled:编排器+短命子进程的两级架构

> 基线:commit `1f66b524`。核心:src/import/(importd.c 2,144 行 / pull-job.c / pull-common.c / curl-util.c)与 src/portable/(portable.c 2,683 行 / portabled-bus.c)。

## 16.0 全景:一次 pull-tar 的完整管线

```
 importctl pull-tar URL
   ▼ D-Bus org.freedesktop.import1 / Varlink io.systemd.Import
 importd(编排器,Transfer 池 ≤64,importd.c:124)
   ▼ transfer_start:fork "(sd-transfer)" → invoke_callout_binary(systemd-pull)
 systemd-pull:TarPull{tar_job, checksum_job, signature_job, settings_job}(≤4 并行)
   │ CurlGlue(multi socket ↔ sd-event IO/timer/defer 桥接,curl-util.c:181-301)
   │ PullJob 状态机:INIT → ANALYZING(探测压缩)→ RUNNING → DONE
   │ write_cb:先 EVP_sha256(压缩字节)再解压再写盘(pull-job.c:246-251)
   ▼ pull_verify:sha256 行匹配 + gpg 签名(pull-common.c:610-675)
   ▼ install_file:".tar-<url>.<etag>" 原子改名;进度 sd_notifyf("X_IMPORT_PROGRESS=nn%")
 importd 转发 D-Bus 信号 + varlink notify(importd.c:252-279)
```

纠偏:importd 是**纯编排器,不碰网络**——下载/校验全部由 fork 出的 systemd-pull 等 callout 子进程完成;连 GPG 校验都是子进程:fork gpg2 并先把密钥环拷进临时 gpghome,防 `--auto-key-import` 污染原钥环(pull-common.c:421-608)。

## 16.1 下载细节:etag、哈希与限流

SHA256 在解压**之前**的写回调里增量计算——SHA256SUMS 描述的是服务器原始压缩产物(pull-job.c:246-251);纠偏:**304/etag 命中时完全跳过校验**——不重下也不重新校验,直接做本地副本(缓存文件名 `.tar-<url>.<etag>`,URL 超长换 siphash24;pull-common.c:144-188; pull-tar.c:475-491)。压缩与未压缩流量各限 64GB;写盘用 sparse_write(空洞阈值 64 字节);完成后 ftruncate 到未压缩长度、写 user.source_etag/source_url xattr(pull-job.c:466-493)。libcurl 是 dlopen 的 libcurl.so.4,缺失则功能不可用;curl fd 注册为 sd-event IO 源、timer 驱动超时。进度合成:下载 0-85%、verify 85%、finalize 90%、copy 95%,100ms 限频上报(pull-tar.c:161-223)。另有 import-generator 解析内核命令行 `systemd.pull=` 生成开机拉取 service(import-generator.c:239-346)。

## 16.2 portabled:attach 的本质

纠偏:本 commit **没有 "PortablePolicy"/"PolicyStyle" 这类接口**——镜像可信走分区级 image policy:从 dissect 事实反推 `image_policy_new_from_dissected()`(默认全分区 ABSENT),写成 drop-in 的 `RootImagePolicy=`/`ExtensionImagePolicy=` 生效,D-Bus 侧恒传 NULL 策略(image-policy.c:287-332; portable.c:1475-1549)。attach 流程:dissect 镜像 → 抽取 unit 与 os-release → profile 匹配 → **生成 drop-in 到 /etc/systemd/system.attached**(仅 --runtime 才是 /run;portabled-image-bus.c:396; path-lookup.c:308)。DetachImage 复用 attach-images polkit 动作,user scope 整体豁免 polkit(portabled-bus.c:368-376)。

## 16.3 设计动机

1. **编排与执行分离**:特权敏感的下载/解压在短命子进程里,importd 崩溃不影响进行中的传输(importd.c:442-509);
2. **sd_notify 做进度通道**:子工具只需一行 notifyf,D-Bus 轮询消失(pull-tar.c:215);
3. **先哈希后解压**:校验对象是传输字节,与服务器 SHA256SUMS 天然对齐(pull-job.c:246);
4. **etag 缓存跳过校验**:信任一次校验过的 URL 内容不可变,换取增量刷新零成本(pull-common.c:170-184);
5. **GPG 子进程+临时 gpghome**:密钥导入不污染系统钥环(pull-common.c:421-608);
6. **分区级 image policy**:可信性绑定在磁盘分区事实而非运行时参数,drop-in 可审计(image-policy.c:287-332)。

## 16.4 FAQ

**Q1:同时能跑几个传输?**
Transfer 池 ≤64;同 (type, remote) 去重报 AlreadyInProgress(importd.c:124, 751-763)。

**Q2:下载器是谁?**
systemd-pull 等 callout 子进程;importd 不碰网络(importd.c:442-509)。

**Q3:SHA256 对什么算?**
解压前的压缩字节,与服务器原始产物对齐(pull-job.c:246-251)。

**Q4:etag 命中还会校验吗?**
不会,直接做本地副本(pull-common.c:170-184)。

**Q5:取消传输怎么实现?**
前 3 次 SIGTERM,之后 SIGKILL(importd.c:369-380)。

**Q6:portable attach 的 drop-in 落在哪?**
默认 /etc/systemd/system.attached;--runtime 才是 /run(portabled-image-bus.c:396)。

**Q7:portable 的镜像信任怎么做?**
分区级 image policy 从 dissect 事实反推,写进 drop-in 生效(image-policy.c:287-332)。

**Q8:开机自动拉镜像?**
import-generator 解析 systemd.pull= 内核参数生成 service(import-generator.c:239-346)。

**Q9:btrfs 支持可关吗?**
子卷/quota 默认开,环境变量可关(importd.c:711-715)。

**Q10:OCI 镜像支持吗?**
支持 pull-oci 类型,同样走 systemd-pull callout(transfer_type_table,importd.c:126-135)。

## 16.5 小结与深挖方向

本章结论:**镜像搬运=编排器+callout 子进程两级;镜像可信=etag/SHA256/GPG 与分区 image policy 分层兜底**。深挖:

1. PullJob 的 ANALYZING 压缩探测与 decompressor_force_off 兜底(pull-job.c:407-419);
2. import_mangle_os_tree_fd 对 os 树的清理规则(pull-tar.c:500-526);
3. portable 的 profile 匹配语义(10-profile.conf 的 PortabilityProfile);
4. Varlink io.systemd.Import 与 D-Bus 的双面一致性(importd.c:2023-2049);
5. qcow2 导入的写时复制转换路径(src/import/qcow2-util.c)。
