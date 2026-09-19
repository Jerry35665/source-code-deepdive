# 第 22 章 · sysext 与 confext:一个二进制的两个身份与三段式 merge

> 基线:commit `1f66b524`。核心:src/sysext/sysext.c(3,319 行)——纠偏:**没有 src/confext/**,systemd-confext 只是 systemd-sysext 的安装符号链接(meson.build:19-21),`invoked_as(argv,"systemd-confext")` 一行分流(sysext.c:3254)。

## 22.0 全景:一张参数表与三段式 merge

```
 image_class_info[](sysext.c:149-192)——全文的钥匙:
   sysext :层级 /usr、/opt;点目录 .systemd-sysext;挂载 RDONLY|NODEV
   confext:层级 /etc;点目录 .systemd-confext;挂载 +NOSUID|NOEXEC(更紧)
 merge 三段式(私有 mount ns 子进程):
   ① /run 置 MS_SLAVE + tmpfs 工作区 /run/systemd/sysext(:1989-2004)
   ② 组装 overlayfs:扩展按 strverscmp_improved 升序排序后"倒序"入层,
      meta 目录压顶,宿主 /usr 垫底(:2263-2265, 2385, 1253-1274)
   ③ 只有最后的 MS_BIND|MS_REC 传播回宿主命名空间(:2462-2490)
 退出码协议:123=NOTHING_FOUND(转 unmerge),124=SKIP_REFRESH(NOP)(:102-105, 2530-2533)
```

纠偏:不存在 "service" 层级——SYSEXT_SCOPE 缺省视为 {system, portable}(extension-util.c:50-52),服务级 ExtensionImages= 传 NULL 完全跳过 scope 检查(namespace.c:2041);本 commit 也没有 `reload` 动词与 `.extended-*` 目录(实为 `.systemd-sysext`)。

## 22.1 origin 指纹与短路刷新

每个入选镜像构造 origin 指纹 JSON:verityHash 优先,缺失时回退 onMountId/fileHandle/inode+crtime+mtime,**有强标识时刻意抑制弱标识**(confext 存于 /usr 时 mount ID 会因 sysext overlay 改变而不可靠,:2227-2245);新旧指纹相等即短路,不做无谓重挂(:2345-2363)。扩展校验走 extension_release_validate:读镜像内 extension-release.d,比对 ID/VERSION_ID/层级与 scope;非 --force 时校验不过计入 ignored(:2155-2178)。

## 22.2 搜索路径的镜像世界

sysext 搜索 /etc/extensions→/run/extensions→/var/lib/extensions,**刻意不含 /usr**——扩展要扩展 /usr,放进 /usr 会与 overlayfs "lowerdir 互为父子"检查撞 -ELOOP(discover-image.c:75-86);confext 反而允许 /usr/lib/confexts(配置不扩展 /usr,无此冲突)。initrd 下追加 /.extra/sysext、/.extra/global_sysext(systemd-stub 投放,衔接卷四 20 章),并实施更严签名策略:/.extra/ 下其余路径直接 image_policy_deny(sysext.c:1760-1773)。内核命令行 systemd.sysext=/systemd.confext= 置 0 时**仅拒绝 systemd 代为调用**,手工执行不受影响(:3267-3275)。

## 22.3 与 portabled 的定位差异

portabled(卷三 16)把"可执行的服务单元+镜像"整体 attach 出 drop-in,面向"应用即镜像";sysext 只合并文件树进 /usr、/etc,面向"给只读系统镜像补内容"——前者生成 unit 覆盖,后者生成 overlayfs 挂载。confext 与 sysext 共用全部逻辑,差异全在 image_class_info[] 一张表:层级、点目录、release 路径、搜索路径、挂载标志、默认镜像策略(:149-192)。

## 22.4 设计动机

1. **一码两身份**:argv[0] 分流+一张参数表,confext 零独立实现(meson.build:19-21);
2. **私有 ns + tmpfs 工作区**:组装过程的所有临时挂载随命名空间消亡自动清理(sysext.c:2002);
3. **版本倒序入层**:高版本扩展层在上,overlayfs lowerdir 顺序即优先级(:2382-2392);
4. **origin 指纹**:verityHash 强标识优先、弱标识抑制,重复刷新零成本(:2227-2245);
5. **退出码协议**:123/124 让"无扩展可合并/无需刷新"成为可编程事实(:102-105);
6. **/usr 禁入**:把 overlayfs 嵌套限制变成搜索路径约束(discover-image.c:75-78)。

## 22.5 FAQ

**Q1:systemd-confext 是独立程序吗?**
不是,是 systemd-sysext 的符号链接,argv[0] 分流(sysext.c:3254)。

**Q2:两者挂载标志差什么?**
confext 多 NOSUID|NOEXEC(配置文件不需要执行)(:164-191)。

**Q3:为什么 sysext 不能放 /usr 下?**
扩展要扩展 /usr,overlayfs lowerdir 互为父子会 -ELOOP(discover-image.c:75-78)。

**Q4:merge 是原子操作吗?**
组装在私有 ns+tmpfs 完成,只有最终 MS_BIND 传播回宿主(:2462-2490)。

**Q5:扩展间版本冲突怎么排?**
strverscmp_improved 升序排序后倒序入层,高版本在上(:2263-2265)。

**Q6:没有扩展时会挂空 overlay 吗?**
不会,返回退出码 123,refresh 层转 unmerge(:102-105)。

**Q7:origin 指纹含什么?**
verityHash>onMountId>fileHandle>inode+时间戳,强标识抑制弱标识(:2227-2245)。

**Q8:.systemd-sysext 目录是什么?**
overlay 内的元数据压顶层,记录当前合并信息(:169, 183)。

**Q9:initrd 里怎么拿到扩展?**
systemd-stub 把 /.extra/sysext 投放成 cpio(卷四 20 章),签名策略更严(:1760-1773)。

**Q10:systemd.sysext=0 是完全禁用吗?**
只是拒绝 systemd 代为调用,手工执行不受影响(:3267-3275)。

## 22.6 小结与深挖方向

本章结论:**sysext/confext=一码两身份+私有 ns 三段式 merge+origin 指纹短路;层级/标志差异收敛在一张表**。深挖:

1. merge_hierarchy 的 mutable 目录(MUTABLE_MODE)处理(:1020-1065);
2. ExtensionImages= 服务级沙箱与 namespace.c 的跳过逻辑(:2041);
3. verity 签名镜像的 DISSECT_IMAGE_VALIDATE_OS_EXT 强制(:2080-2081);
4. confext 放 /usr/lib/confexts 的叠加顺序验证(discover-image.c:86);
5. Mutable=dirty 模式下 upperdir 的生命周期(:1305-1357)。
