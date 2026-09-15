# 第 15 章 · CDI 设备注入:声明式设备的现代标准

> 基线:commit `f6132db`。行号以 pkg/cdi/、internal/cri/、vendor/tags.cncf.io/container-device-interface/ 为准。**核心论点**:containerd 2.x 无 pkg/nvidia、无厂商魔改——CDI 把设备知识从执行路径搬进数据文件,vendor 只声明、runtime 只兑现。

## 15.0 全景:CDI 的三段链

```
厂商生成 CDI 文件(/etc/cdi 静态 + /var/run/cdi 动态:config_unix.go:107-108)
  → containerd 启动 Configure 读注册表(internal/cri/server/service_linux.go:106-111)
     fsnotify 自动刷新(cache.go:485-524)
  → Create 时按名注入 OCI spec(cache.go:233-270 InjectDevices)
```

CDI 结构(vendor .../specs-go/config.go):`Spec{Version,Kind("vendor/class"),Devices[],ContainerEdits}`(:6-14);`Device{Name,ContainerEdits}`(:17-23);**ContainerEdits 七类编辑**(:26-34):Env/DeviceNodes/NetDevices/Hooks/Mounts/IntelRdt/AdditionalGids——**不止设备节点,还能带 env/mounts/hook**,这是 CDI 优于 --device 的根本。

## 15.1 注入链三段

1. **扫描与裁决**:scanSpecDirs→ReadSpec→validate,冲突按目录优先级裁决、同优先级则设备删除(cache.go:159-219,:174-187);
2. **kubelet 两条来源**:CRI `ContainerConfig.CDIDevices`(cri-api api.pb.go:5583-5592,仅 Name 字段)与 `cdi.k8s.io/*` 注解(:157,annotations.go:29,device plugin 过渡通道),在 WithCDI 汇合去重(internal/cri/opts/spec_linux.go:139-179);
3. **Apply**:WithCDIDevices(pkg/cdi/oci_opt.go:31-56,Refresh 软失败:37-44——**厂商坏 spec 不拖累其他厂商**)→Cache.InjectDevices(:233-270,unresolved 硬失败:260-263,全链唯一常规硬失败点);ContainerEdits.Apply(:75-178):DeviceNodes→linux.devices+devices cgroup 规则(:110-122,rwm 默认)、Hooks 六种(:146-163)、UID/GID 自动补进程属主(:99-108)。

挂接点:internal/cri/server/container_create_linux.go:103-114;EnableCDI=false 且请求设备直接报错;**enable_cdi 开关 v2.3 移除、CDI 恒开启**(deprecation.go:71;config.go:419)。

## 15.2 legacy 对照与设计动机

legacy --device(spec_opts_linux.go:43-61):只写 linux.devices+cgroup 规则,CRI 侧老翻译在 spec_linux_opts.go:315-357(container_create.go:801 挂接)——与 CDI 殊途同归于 runc 的 devices 处理。ctr --gpus 是全仓库唯一"厂商代码"(:520-528:探测 nvidia.com/amd.com 翻译为 `nvidia.com/gpu=<id>`)。

1. **为什么 CDI 取代 nvidia-container-runtime 类方案**:旧路=每厂商一个魔改 runtime 预处理 spec;CDI=厂商只写数据文件(JSON 声明),runtime 通用兑现——**设备知识从代码搬进数据**;
2. **七类编辑的表达力**:GPU 场景=设备节点+驱动库 mount+LD_LIBRARY_PATH env+hook 的组合——一个 ContainerEdits 全表达;
3. **fsnotify 刷新**:动态设备(热插拔 GPU)的 CDI 文件实时生效(:485-524);
4. **软失败哲学**:Refresh 失败仅告警(:37-44),unresolved 在注入时硬失败(:260-263)——**容错在加载,严格在使用**。

## 15.5 FAQ

**Q1:CDI 文件放哪?**
/etc/cdi(静态)+/var/run/cdi(动态)(:107-108),目录下标即优先级。

**Q2:两个厂商的 CDI 文件冲突怎么办?**
高优先级目录赢,同优先级设备删除(:174-187)。

**Q3:CDI 设备节点在宿主不存在?**
vendor 写全 type/major/minor 则可注入(fillMissingInfo :80 只补缺),否则硬报错(:94-97)。

**Q4:legacy --device 还能用吗?**
能(spec_opts_linux.go:43-61):单节点直通场景;复杂设备用 CDI。

**Q5:k8s 的 device plugin 和 CDI 什么关系?**
device plugin 管资源分配,CDI 管注入表达——注解 `cdi.k8s.io/*` 是过渡通道(:157)。

**Q6:CDI 能注入环境变量吗?**
能:ContainerEdits.Env(:26-34)——驱动库路径的标配。

**Q7:hook 能做什么?**
六种 OCI hook(:146-163):设备驱动的初始化(如 NVIDIA 的 libnvidia-container 逻辑)可在 hook 内完成。

**Q8:Refresh 失败会拒绝创建容器吗?**
不会(:37-44):用上一次成功快照;注入时 unresolved 才硬失败(:260-263)。

**Q9:ctr --gpus 是厂商代码吗?**
是全仓库唯一例外(:520-528):CLI 便利层,不影响核心。

**Q10:CDI 与 --device 的 cgroup 处理一样吗?**
殊途同归(:110-122 vs :43-61):都落 linux.devices+cgroup 规则,runc 侧无差别。

## 15.4 小结与深挖方向

本章结论:**CDI="设备知识数据化(vendor 声明 JSON)+注册表裁决+Apply 七类编辑"**;取代厂商魔改 runtime 的根本是把知识从代码搬进文件。深挖:

1. 目录下标优先级(:75/:95)与多 GPU 厂商共存;
2. fsnotify 刷新(:485-524)在 GPU 热插拔的时序;
3. NetDevices 编辑(网络设备 CDI)的落地现状;
4. IntelRdt 编辑(:26-34)与 resctrl 的对接;
5. CDI 文件的签名与供应链(未签名 JSON 的信任模型)。

> 下一章(卷末):测试与集成——containerd vs runc 的工程对照。
