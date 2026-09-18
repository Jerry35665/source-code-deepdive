# 第 08 章 · udevd:设备事件的处理管线(卷二)

> 基线:commit `1f66b524`。核心:src/udev/。纠偏:本代 udevd.c 已收缩为 91 行薄入口,主体在 udev-manager.c/udev-worker.c;控制面已换 Varlink;devtmpfs 时代不做 mknod。

## 8.0 全景:一条 udev 事件的生命

```
内核 kobject_uevent(netlink 组播 group=kernel)
 → udevd manager:on_uevent→入队(按 SEQNUM 排序,乱序去重)→找 blocker
   (devpath 前缀包含=同/父子设备串行;不同磁盘照常并行)→挑空闲 worker 或 fork
 → netlink 单播发给 worker(worker 带走 rules/属性副本,加入 workers cgroup)
 → worker:flock 整盘共享锁(忙则 TRY_AGAIN 让路)→跑规则(token 化引擎)
   →改网卡名(RTM_NEWLINK,先落盘 ID_RENAMING 防半成品)→节点权限/软链接仲裁
   →RUN{builtin|program}→清 ID_PROCESSING→终写 /run/udev/data→组播+PROCESSED=1
 → PID 1 收 group=udev 组播合成 .device unit(卷一)
```

## 8.1 worker 池与串行化

事件四状态 QUEUED/RUNNING/LOCKED/PROCESSED(udev-manager.h:82-85)。`event_find_blocker` 向前扫描:devpath 前缀包含、device id、节点名、DEVPOLD 任一相同即 blocker——**串行化的是可能互相改写状态的设备链,不是整个队列**。worker 数=min(CPU×2+16, 内存/128MiB);fork 而非线程使"超时 SIGKILL"成为可靠回收——卡死的只是子进程,rules/属性副本天然隔离;超时先警告后按 timeout_signal 击杀(:353-361)。worker 失败记 UDEV_WORKER_FAILED 属性随事件广播,PID 1 据此拒绝消费脏事件。

## 8.2 规则引擎:解析即编译

规则在解析期拆成 token 链(ACTION/KERNEL/SUBSYSTEM/ATTR/IMPORT/RUN…约 70 种),行级位标志(LINE_HAS_NAME/GOTO/…)预筛——执行期不可能命中的行整行跳过;GOTO 在解析期绑定为行指针,悬空引用即暴露。文件按**字典序**合并成一条解析序列("数字前缀定序、/etc 覆盖 /usr/lib"的机制)。`IMPORT{program}` 命中 builtin 注册表时自动降级为内置调用。RUN 统一推迟到规则跑完后执行。

## 8.3 节点、链接与 builtin

**udevd 不做 mknod**——节点由内核 devtmpfs 创建;udevd 只做 chmod/chown/SECLABEL(fchmod_and_chown,udev-node.c:636-699)与软链接仲裁:每个链接名对应 /run/udev/links 下的优先级栈,候选设备按 link_priority 争属主,remove 时只有自己仍是属主才改写。`/dev/disk/by-*`=builtin blkid 探测(ID_FS_UUID/LABEL…)+发行版规则 SYMLINK 的接力。builtin 注册表是函数指针数组(blkid/kmod/path_id/usb_id/net_id/net_setup_link…),run_once 位图保证每事件一次并缓存结果。

## 8.4 数据库与网络命名

每设备一份 `/run/udev/data/<id>`:临时文件+rename 原子替换,行格式 S/L/I/E/G/Q/V;**ID_PROCESSING=1 显式化"规则已完、RUN 未完"窗口**,网卡改名场景先把 ID_RENAMING 落盘再发 RTM_NEWLINK——任何读者都能判断"上一轮是否处理完"。命名两段式:net_id builtin 产 ID_NET_NAME_ONBOARD/SLOT/PATH 属性(不改名)→net_setup_link 的 link_generate_new_name 按 NamePolicy 消费,真正改名在 worker 的 rename_netif。

## 8.5 设计动机

1. **worker 池**:慢事件(外部程序/磁盘 IO)隔离在独立地址空间;fork 让 SIGKILL 回收可靠;
2. **同/父子设备串行**:交错改写 devlink/db/sysfs 会撕碎状态;只牺牲同设备链内并行;
3. **rules 编译成 token**:一次解析、每事件数千次复用;`udevadm verify` 离线复用同一解析器;
4. **builtin 而非外部进程**:高频探测免进程创建与动态链接,属性结构化回传;
5. **整盘 flock**:mkfs/mount 等外部工具与 udevd 抢同一块盘——LOCK_SH 让 udev 主动让路或外部阻塞,让路期间 LOCKED 队列重试;
6. **ID_PROCESSING+blocker 串行**:没有这两层,IMPORT{db} 读到的将是任意中间态。

## 8.6 FAQ

**Q1:udevd 还创建设备节点吗?**
不:devtmpfs 时代节点由内核建;udevd 只管权限/标签/软链接。

**Q2:两个磁盘的事件并行吗?**
并行:blocker 只按 devpath 前缀包含(同/父子)判定。

**Q3:worker 卡死怎么办?**
警告定时器+击杀定时器,timeout_signal(默认 SIGKILL)回收。

**Q4:规则文件优先级?**
全目录字典序合并;后出现的同名文件追加/遮蔽前者。

**Q5:IMPORT{program} 和 builtin 什么关系?**
命令名命中 builtin 注册表时自动改写为内置调用(兼容彩蛋)。

**Q6:/dev/disk/by-uuid 怎么来的?**
blkid builtin 导出 ID_FS_UUID 属性+发行版规则 SYMLINK 落链接;冲突走优先级栈。

**Q7:网卡改名对 networkd 的竞态?**
先把 ID_RENAMING 写进设备与数据库落盘,再发 RTM_NEWLINK——不收半成品。

**Q8:machine 被外部工具直接写了节点?**
OPTIONS=watch 的 inotify(经 manager 代持)检测 IN_CLOSE_WRITE,合成 change 事件自愈。

**Q9:控制协议是什么?**
Varlink(io.systemd.Udev);旧 control socket 只是兼容符号链接。

**Q10:重启会丢事件吗?**
不:未处理 QUEUED 事件写进存储 socket 进 PID 1 fdstore,下次启动收回。

## 8.7 小结与深挖方向

本章结论:**udevd="worker 池+设备链串行化+token 编译规则+原子数据库+Varlink 控制面"**。深挖:

1. locked_events_by_disk 的 200ms 重试与 3 分钟放弃;
2. 事件队列跨重启的 netlink 存储 socket 机制;
3. uaccess builtin 的 ACL 授予与 logind 的协作;
4. SR-IOV/RPS/IRQ 在 link_apply_config 中的应用次序;
5. 合成事件(udevadm trigger)的 UUID 回收路径。
