# 第 03 章 · shim 与任务生命周期:每容器一个进程

> 基线:commit `f6132db`。行号以 core/runtime/v2/、pkg/shim/、internal/oom/ 为准。容器运行时的控制面心脏:**每个容器一个常驻 shim 进程**,containerd 宕机它也不死。

## 3.0 全景:一个容器的完整生命周期

```
dockerd/kubelet → containerd TaskManager.Create(task_manager.go:159)
  → NewBundle(:160,目录+config.json+rootfs)
  → ShimManager.Start(:192→shim_manager.go:205)
      exec containerd-shim-runc-v2 ... start(binary.go:66)
      [stdin 传 BootstrapParams(command.go:150-155),stdout 读回结果(:115,:129)]
      start 子命令建 ttrpc socket 后 exec 自身为常驻进程(:196,:235)
  → containerd 建长连接 makeConnection(shim.go:369-402,ttrpc/grpc 双协议)
  → shimTask.Create → runc create(04 章)→ runc start
```

**常驻 shim 从 fd3 建 ttrpc listener**(pkg/shim/shim_unix.go:52-71;调用 shim.go:475 serveListener(:3)),跑插件图注册 TTRPC 服务(:439-443),runc 适配器注册 TaskService(task/service.go:289-292)。Pod 分组:同 sandbox 的容器**复用同一 shim socket**(manager_linux.go:200-233,K8s 场景一个 pod 一个 shim)。

## 3.1 bundle:容器的磁盘快照

bundle 布局 `<state>/<ns>/<id>`:config.json(bundle.go:125)、rootfs/(:90)、work 软链(:106)、**bootstrap.json**(containerd 重启后 LoadExistingShims 凭它重连所有 shim,shim_load.go:39;落盘在 binary.go:140)、log FIFO、options.json/runtime(runc/container.go:96-102);删除是 umount+**rename 隐藏目录原子删**(bundle.go:146-184)。Bootstrap 协议:参数从 stdin 传(command.go:129-155),避免命令行泄漏与转义问题。

## 3.2 任务 API 与 stdio

五条 API 的 shim 侧实现链:Create(shim.go:713→task/service.go:222→`runc create`,产出 paused init);Start(:807→:295→`runc start`);Kill(:817→:492→`runc kill`);Delete(:644→:353→`runc delete`+Shutdown(:607,还有容器则 no-op));Wait(:890→:575,内存等待+reaper 收尸)。**stdio 三管道走 FIFO**:client 在 io 目录建三个 FIFO(pkg/cio/io_unix.go:35-55),路径经 CreateTaskRequest 传 shim(:718-727);shim 的 createIO 按 scheme 分派 fifo/binary-v2/file(process/io.go:84-132),copyPipes 把 runc 管道输出拷到 FIFO(:134-228);TTY 走 TempConsoleSocket+epoll CopyConsole(process/init.go:119,:160-168)。**字节流不过 containerd daemon**——数据面与控制面分离。

## 3.3 事件回路与 OOM

shim 用 TTRPC 反连 containerd events 服务 Forward 事件(pkg/shim/publisher.go:59,:127,:154-188;plugins/services/events/service.go:81);**shim 断连的收尸**:用 shim-binary-path 重放 `shim delete` 收尸并补发事件(binary.go:125,:154;shim.go:146-196)。OOM 监控:v2 用 **inotify 盯 cgroup memory.events 的 oom_kill 计数**(internal/oom/utils.go:33-47;watcher.go:102-141→service.go:697 发布 TaskOOM)——文件变化即事件,无轮询。

## 3.4 设计动机

1. **为什么每容器一个 shim**:崩溃隔离(shim 死不影响 containerd 与其他容器)+**升级独立**(containerd 重启,容器照跑)+状态归属(shim 持有容器运行态)——三收益买一个进程的成本;Pod 分组(:200-233)又把成本摊薄;
2. **为什么 TTRPC 而非 GRPC**:ttrpc 是 stripped-down GRPC(无 HTTP/2 状态、单连接复用)——shim 与 containerd 之间的消息量不值得全 GRPC;
3. **stdio 为什么走 FIFO**:字节流直通客户端,containerd 不做数据面——与 09 章 FFmpeg"字节流不过 daemon"同构;
4. **bootstrap.json**:containerd 可死可重启,shim 凭文件重连——**重启后的世界重建靠落盘的指针**(系列模式 4)。

## 3.5 FAQ

**Q1:containerd 重启,容器还在吗?**
在:shim 独立存活,凭 bootstrap.json 重连(shim_load.go:39)——这是"每容器一 shim"的核心红利。

**Q2:shim 进程死了呢?**
重放 `shim delete` 收尸补事件(:146-196):容器本体也死了(shim 持运行态)。

**Q3:一个 Pod 为什么共享 shim?**
K8s sandbox-id 标签(:200-233):同 pod 容器生命周期一致,合并管理省进程。

**Q4:容器日志怎么流出来?**
FIFO→客户端直读(:35-55):containerd 不碰字节流。

**Q5:OOM 怎么被发现?**
inotify 盯 memory.events 的 oom_kill 计数(:102-141):内核写文件→inotify→事件。

**Q6:ttrpc 是什么?**
精简版 ttrpc(非 HTTP/2):shim 场景的轻量 RPC。

**Q7:stdin/stdout 的路径谁建?**
client 建 FIFO(:35-55),路径字符串传给 shim(:718-727)。

**Q8:runc 是 shim 的子进程吗?**
是,每次操作 fork 一个 runc(:222/:295/:492):runc 是一次性工具(shim 才常驻)。

**Q9:Create 后容器就跑了吗?**
没有:runc create 产出 **paused init**(:149-178),等 `runc start` 写 fifo(04 章)。

**Q10:bootstrap 参数为什么不走命令行?**
stdin 传 proto(:129-155):免转义泄漏+长度不受限。

## 3.6 小结与深挖方向

本章结论:**shim="每容器常驻进程+TTRPC+FIFO stdio+bootstrap.json 重连"**;控制面与数据面的分离贯穿始终。深挖:

1. Pod 分组复用(:200-233)在 shim 升级时的边界(同 pod 能否半升级);
2. 死 shim 收尸(:146-196)与并发 delete 的竞态;
3. FIFO stdio 在客户端断开时的背压行为;
4. memory.events inotify(:102-141)在 cgroup v1/v2 的差异面;
5. bootstrap.json 的安全面(本地文件权限)。

> 下一章:runc 创建旅程——从 bundle 到 execve。
