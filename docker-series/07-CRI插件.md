# 第 07 章 · CRI 插件:K8s 如何经由 containerd 跑 Pod

> 基线:commit `f6132db`(2.x)。行号以 plugins/cri/ 与 internal/cri/ 为准。**勘误**:CRI 实现已从 plugins/cri/server 迁入 internal/cri/;plugins/cri/ 只剩注册薄层。

## 7.0 全景:kubelet 的调用链

```
kubelet ──CRI GRPC──→ containerd(plugins/cri/cri.go:49-68 单插件,双服务
                        Runtime+Image :209-214,in-memory services,ns "k8s.io")
           → internal/cri/server → containerd API(01-02 章)→ shim → runc
```

CRI 是单个 GRPCPlugin,双服务(Runtime+Image)注册同一 gRPC server;命名空间固定 "k8s.io"——**K8s 的全部对象住在独立 namespace**,与 docker 的对象互不干扰。

## 7.1 pod 语义:sandbox 与 pause 容器

K8s 的 Pod=sandbox 对象(pause/infra 容器)+N 个业务容器。RunPodSandbox(internal/cri/server/sandbox_run.go:54):建 ID/lease→选 runtime handler→写 sandbox store→**非 hostNetwork 时建宿主侧 netns 并调 CNI**(:209-218,:266)→预拉 pause 镜像(:416-438)→CreateSandbox/StartSandbox→StateReady。

pause 容器(podsandbox/sandbox_run.go:61 Controller.Start)的特殊性:**只读 rootfs、NullIO(不接 stdio)、只占 namespace**——它持有 Pod cgroup 与 netns,贡献 /etc/hosts/hostname/resolv.conf/dev/shm;业务容器用 `/proc/<sandboxPid>/ns/{net,ipc,uts}` 加入 Pod(opts/spec_opts.go:349-359)。Pod cgroup 锚在 pause 的 spec(WithCgroup,podsandbox/sandbox_run_linux.go:63-66)。默认 sandboxer 是 `podsandbox`(宿主侧 Controller,config.go:677-679)——**宿主侧沙箱模式(去 pause 化)**可配 `shim` 外包。

## 7.2 生命周期映射与元数据三处存放

CreateContainer(container_create.go:59)只建容器对象+rootfs 快照——**Create/Start 分离对应 containerd 的 container/task 模型**(container_start.go:138/:179)。CRI 元数据三处存放:bolt extension(`io.containerd.cri.container.metadata`,:389,持久)、本地 checkpoint `<root>/containers/<id>/status`(原子写 store/container/status.go:167-180)、内存 store(restart.go:55 启动重建)。五态机由三个时间戳推导(:104-118),TaskExit 事件驱动迁移(:173,:294-297)。

## 7.3 镜像服务:GC 归 kubelet

PullImage(image_pull.go:199-238)2.x 默认走 transfer service(:187-191);**镜像 GC 完全由 kubelet 决策**:ImageFsInfo(:54-63)注释明说 kubelet 只取返回数组第一项——containerd 不自删,kubelet 按阈值调 RemoveImage。**控制权归属的清晰划分**:containerd 管"怎么做",kubelet 管"做什么"。

## 7.4 设计动机

1. **为什么 K8s 抽象 Pod 而非容器**:共享 netns/ipc/uts 的紧密耦合组是一等公民——sandbox(基础设施容器)承载共享面,业务容器轻量加入;
2. **CRI 为什么是 GRPC**:kubelet 与运行时可独立升级/异进程——接口即解耦;CRI 是 GRPC 插件挂进 containerd(非独立项目)——**接口标准的最佳归宿是参考实现**;
3. **pause 容器的存在理由**:没有它,共享 namespace 需要第一个业务容器当锚(死一个全 pod 断链)——infra/业务分离让生命周期解耦;
4. **元数据三处存放**:bolt(持久)/checkpoint(快恢复)/内存(热路径)——一致性靠事件驱动迁移,读写分离的代价。

## 7.5 FAQ

**Q1:pause 容器里跑的是什么?**
一个 sleep 的极小镜像:只持有 namespace/cgroup/共享文件(:61 NullIO)。

**Q2:业务容器怎么加入 Pod 网络?**
spec 加 `/proc/<sandboxPid>/ns/net` 等(:352-356):ns 路径共享。

**Q3:CRI 元数据为什么存三处?**
bolt 持久/本地 checkpoint 快恢复/内存热路径(:389,:167-180)——读写分离的三级。

**Q4:镜像 GC 谁负责?**
kubelet(阈值+RemoveImage);containerd 的 ImageFsInfo 只报容量(:54-63)。

**Q5:RunPodSandbox 建网络在什么时机?**
非 hostNetwork 时宿主侧 netns+CNI(:209-218):Pod IP 在此产生。

**Q6:CRI 的 namespace 是什么?**
"k8s.io":K8s 对象与 docker 对象物理隔离(同 bolt 不同桶)。

**Q7:Create/Start 为什么分离?**
对应 containerd 的 container/task 两级模型(:138/:179):挂载/配置在 Create 完成。

**Q8:去 pause 化是什么?**
podsandbox 宿主侧沙箱(:677-679):不启动 pause 进程,由 containerd 直接持 netns——省一个容器。

**Q9:CRI 元数据在 bolt 哪里?**
extension `io.containerd.cri.container.metadata`(:389):容器对象的扩展槽。

**Q10:sandbox shim 模式是什么?**
把 sandbox Controller 外包给 shim 实现(config.go:677-679):runtime 决定沙箱形态。

## 7.6 小结与深挖方向

本章结论:**CRI="Pod 语义的翻译层+控制权划分(containerd 管机制,kubelet 管策略)"**。深挖:

1. podsandbox 宿主沙箱(:677-679)对 Windows/非 cgroup 场景的覆盖;
2. CNI 调用(:209-218)的带宽插件链与超时;
3. TaskExit 驱动的五态机(:104-118)在 crash-loop 的振荡;
4. transfer service(:187-191)取代 pull 的收益;
5. CRI 元数据 extension 与镜像 GC 协同的一致性边界。

> 下一章:streaming——exec/attach 的通道选择。
