# 第 03 章 · 控制器模式:Informer、工作队列与控制循环

> 基线:commit `517a94ff`。行号相对仓库根目录。
> 控制面的自我描述(client-go/tools/cache/controller.go:36-43):informers 是"组成 K8s 控制面骨干的高层控制器的关键组件"。

## 3.0 通用骨架:四层流水线

1. **Reflector**:LIST+WATCH 拉变更 → DeltaFIFO;
2. **DeltaFIFO**:变更的"缓冲 + 合并"账本,同一 key 的多个 delta 攒成一条 Deltas;
3. **Indexer**:本地带索引的只读缓存,配合 Lister 供控制器无锁读;
4. **工作队列 + worker**:事件处理器只把对象 key 丢进限速队列,N 个 worker 逐个执行 syncHandler。

每一环都服务同一目标:**把"事件驱动"(edge)可靠地转化为"状态驱动"(level)**——事件可能丢、乱、重复,但只要本地缓存最终与 etcd 一致,worker 每次调和都从缓存读全量状态,系统就收敛。

## 3.1 Reflector:LIST-WATCH 的执行者

主循环 = 带退避的无限 ListAndWatch(reflector.go:423-435);退避 800ms 起、30s 封顶、2 分钟无错误重置——目标是 apiserver 不健康时把重试 QPS 压到约 0.22。防御性细节:

- watch 超时在 [5,10) 分钟**随机**取值——打散大量客户端同时断连的惊群(与 Nginx 卷 watch 超时随机化同源!);
- 429/连接拒绝按退避重试 watch 而非 relist;410 Gone 才触发 quorum 全量 relist;
- **watch 起始 RV 的保守传播**:从空 RV/"0" 启动时,必须等收到第一个非 Added 事件才把 RV 写入 lastSyncResourceVersion(reflector.go:585-638)——防初始合成 Added 事件的乱序 RV 污染断点续传(直接影响 relist 死循环风险,极少被提及的细节)。

**Resync 是纯本地操作**:`store.Resync()` 只给 Indexer 中"当前没有排队 delta"的 key 补发 Sync delta(delta_fifo.go:704-747),零网络流量——"周期性调和"与"网络流量"无关是理解 K8s 控制器的关键。

## 3.2 DeltaFIFO:合并不去重的账本

核心结构:`items(key→Deltas) + queue(key 的 FIFO 序,key 在 queue ⇔ 在 items)`。两个设计要点:

1. **key 去重、delta 追加**:同一对象连续变更只追加到该 key 的 Deltas 尾部;唯一去重是"连续两个 Deleted 合并"。消费方拿到的是"自上次消费以来的完整变更序列";
2. **Replace 是删除的兜底**:relist 后把"不在新列表里"的旧 key 补发 Deleted delta,对象用 `DeletedFinalStateUnknown` 包裹——**解决 watch 断连期间漏掉删除事件的经典难题**。

Pop 的语义:先删后处理,处理失败由调用方 AddIfNotPresent 塞回;process 在持锁状态执行,注释警告"应避免昂贵 I/O"。`HasSynced` 在 initialPopulationCount 归零时变 true——控制器启动时 WaitForCacheSync 等待的信号。

**Indexer 是被忽视的第三件套**:控制器调和时**绝不 GET apiserver**,全走 Lister 读内存快照;副索引让"列出某 RS 的全部 Pod"从 O(全部 Pod) 降为 O(命中数)。processorListener 每 handler 一条管道(3 goroutine + 2 channel + 无界环形缓冲):**慢消费者不拖慢 informer 主循环,只拖慢自己**——代价是内存无上界,所以官方要求"handler 快速处理,耗时工作丢给 workqueue"。OnUpdate 的精妙判定:RV 未变的事件视为 resync 事件,只分发给要求 resync 的监听者。

## 3.3 工作队列:去重 + 限速 + 延迟

三层包装(Type → DelayingQueue → RateLimitingQueue):同一 key 在队列中只存一份(天然去重);失败重试用 ItemExponentialFailureRateLimiter 指数退避;AddAfter 提供"延迟重新入队"原语——控制器的"N 分钟后重试"全部构建在它上面。

## 3.4 Deployment 控制器:一个实例

syncHandler 编排:Lister 读 RS 与 Pod(按 ControllerRef 索引)→ 计算 diff → 按滚动策略调整 new/old RS 副本数。**滚动更新的可用性守恒公式**(rolling.go:127-131):

```go
maxScaledDown = allPodsCount - minAvailable - newRSUnavailablePodCount
```

把新 RS 的不可用副本计入"不可缩额度"——**crashloop 场景下旧副本一个也不缩**(注释算例 13-8-5=0),回滚后立即可缩 4 个。配合"每轮调和只扩或缩一步、随即刷新 status 退出"的事务化推进,是 Deployment 语义最精妙的两段实现。

## 3.5 leader election 与级联删除(概览)

leader election 用 Lease 资源实现:竞争者周期性 TryAcquireOrRenew(CAS 更新 lease 的 holderIdentity/leaseDuration),失败者持续 watch;HolderIdentity + LeaseDurationSeconds + renewTime 构成"租约真相"。级联删除(GarbageCollector)则用 ownerReference 图:GC 控制器把"所有者已不存在"的对象入孤儿队列删除——**级联删除本身也是一个控制器**。

## 3.6 设计动机:level-triggered 为什么是 K8s 的灵魂

1. **事件不可靠是常态**:watch 断连、事件丢失、处理器失败都被视为正常输入;Resync + Replace 的删除兜底 + 每次调和读全量状态,三层保险让系统对事件语义"免疫";
2. **控制循环无状态化**:worker 只依赖"缓存里的期望 vs 缓存里的实际",重启即恢复;leader election 只为避免重复劳动而非正确性;
3. **读路径全部本地**:控制器的 API 调用只有写(更新 status/spec);大规模集群的 API 压力由此可控;
4. **通用骨架的复利**:任何 CRD 控制器用同一套 informer/workqueue 模式(代码生成器 kubebuilder 生成的骨架就是本章的缩影)。

## 3.7 FAQ

**Q1:Resync 会打爆 apiserver 吗?**
不会——resync 是纯本地操作,零网络流量;它只是让 handler 重新看到"当前缓存状态"。

**Q2:控制器重启后怎么恢复?**
Lister 是本地缓存,重启后 WaitForCacheSync(List+Replace+Sync 完成)即可;进度与状态全在 apiserver 的对象里。

**Q3:为什么 worker 处理失败不会丢事件?**
Pop 先删后处理,失败 AddIfNotPresent 塞回 + 指数退避;同时 resync 会周期性重新触发调和——双保险。

**Q4:watch 断连期间的删除事件丢了怎么办?**
DeltaFIFO.Replace 会把"不在新列表"的旧 key 补发 Deleted(DeletedFinalStateUnknown 包裹),GC 控制器据此清理。

**Q5:两个控制器副本会不会重复调和?**
leader election 保证同一时刻一个 leader;即使脑裂,调和是幂等的(最终都是把实际推向期望)。

## 3.8 小结与深挖方向

本章结论:**控制器模式 = "Reflector→DeltaFIFO→Indexer→workqueue"四层 + level-triggered 语义**;它的精髓不在任何单件,而在"对事件不可靠的全盘接受"。深挖:

1. DeltaFIFO 的锁粒度与 Pop 持锁回调的 I/O 禁令边界;
2. processorListener 无界缓冲的 OOM 案例;
3. leader election 的 lease 续约与时钟漂移;
4. Deployment 的 maxSurge/maxUnavailable 与守恒公式的边界;
5. GC 控制器的 ownerReference 图遍历规模。

> 下一章:调度器——过滤、打分与抢占。
