# 第 08 章 · rules 引擎:告警的生老病死

> 基线:commit `b0f312b`。行号以 rules/manager.go、rules/group.go、rules/alerting.go 为准。**勘误**:模板已迁至 template/template.go。

## 8.0 全景:调度与热重载

**一个 group 一个 goroutine**(manager.go:308-319 `go newg.run`);新旧配置 Equals 判等则复用旧实例(:302-304),变了才 stop+**CopyState 按 name+labels 拷贝旧 active map**(group.go:486)——热重载不断告警。**interval 对齐用 hash offset 而非随机抖动**:`offset = hash(file;name) % interval`,槽位=`(now-offset)-(now-offset)%interval+offset`(group.go:422-445)——同组恒同相位、异组错峰。落后只计 IterationsMissed 并把槽位前推,**永不补跑**(:286-291)。组内默认串行(:674-682);`concurrent-rule-eval` 开启后按依赖图切三段批(:707),全局信号量默认上限 4(main.go:623-624);**依赖只认书写顺序在前的规则**(:1199-1206),通配选择器判 indeterminate 使依赖图失效——引擎不做拓扑重排。

## 8.1 告警状态机:for 的全部实现

`active map[uint64]*Alert`,键为展开标签后的 labelset 指纹(alerting.go:146-150,:449)。**for 无定时器,纯时间差**:`pending && ts.Sub(ActiveAt)>=holdDuration → firing`(:526-529);for 被改小则 firing 打回 pending 并清 LastSentAt(:532-537);已存在实例只更新 Value/Annotations、**保留 ActiveAt**(:471-474)。resolve:指纹从结果消失→keep_firing_for 窗口内续 firing(:490-497),否则 inactive+ResolvedAt(:513-516);resolved 实例留 15min 供补发 resolved 通知(:383)。发送判定 needsSending(:102-113):pending 不发、ResolvedAt>LastSentAt 补发、否则每 resendDelay(默认 1m)重发;ValidUntil=ts+4×max(interval,resendDelay)(:618-633)。**sendAlerts 在 Appender 回写之前**(group.go:557-570):通知先于写 TSDB。重启恢复:查自己写的 `ALERTS_FOR_STATE`(值=ActiveAt.Unix)回拨 ActiveAt,窗口 1h+最短补偿 10m(group.go:761-889;默认值 main.go:614-621)。

## 8.2 记录规则与模板

RecordingRule.Eval 只改指标名/标签(recording.go:94-113),TSDB 写入统一在 Group.Eval 闭包;每规则独立 Appender 事务+消失序列补 StaleNaN(:570-661)。模板展开四变量 `$labels/$externalLabels/$externalURL/$value`(alerting.go:409-414),Expand 带 recover 兜底(template/template.go:326-344)。

## 8.3 设计动机

1. **为什么 for 是时间差而非定时器**:纯函数式判定(每次 eval 自查),重启可从 ALERTS_FOR_STATE 重建——**状态最小化**;
2. **为什么 group 内串行**:组内规则可能有依赖(书写顺序即依赖声明 :1199-1206)——串行是依赖语义的自然实现;并发是 opt-in 的三段批;
3. **hash offset 对齐**:分布式部署的多 Prometheus 实例天然错峰(与 06 章抓取相位哈希同族)——两处同思想;
4. **通知先于写 TSDB**(:557-570):告警的及时性优先于记录的完整性——场景决定次序。

## 8.4 FAQ

**Q1:for 期间重启 Prometheus,告警进度丢吗?**
不丢:ALERTS_FOR_STATE 回拨 ActiveAt(group.go:761-889),1h 容忍窗口。

**Q2:热重载会清空 pending 告警吗?**
不会:CopyState 拷贝 active map(:486);for 改小会把 firing 打回 pending(:532-537)。

**Q3:为什么我的告警每分钟重复通知?**
resendDelay 默认 1m(:102-113):Alertmanager 的分组去重负责抑制。

**Q4:组内规则能并行吗?**
能但需开 concurrent-rule-eval:依赖图切三段批(:707),串行的只有"有依赖有被依赖"的。

**Q5:规则失败会阻塞 group 吗?**
单规则错误记日志继续:组内其他规则不受影响。

**Q6:keep_firing_for 是什么?**
(:490-497):指纹消失后维持 firing 一段时间——防抖动告警。

**Q7:依赖为什么只认书写顺序?**
(:1199-1206):串行执行下,书写序=执行序——语义从执行模型推出。

**Q8:告警的 resolve 通知什么时候发?**
ResolvedAt 之后 15min 内可补发(:383):错过窗口不再发。

**Q9:记录规则的 stale 处理?**
结果消失时补 StaleNaN(:570-661):与抓取消失的语义统一。

**Q10:落后很多个 interval 会连发吗?**
不会:只计数、槽位前推、不补跑(:286-291)——监控系统的自我克制。

## 8.5 小结与深挖方向

本章结论:**rules 引擎="group goroutine+hash 对齐+纯时间差状态机+CopyState 热重载"**。深挖:

1. CopyState(:486)在规则改名时的行为(指纹变化=新告警);
2. 三段批并发(:707)的依赖图构建完整性;
3. ALERTS_FOR_STATE 的 1h 窗口(:761-889)与长 for 的组合;
4. 模板 Expand recover(:326-344)的恶意模板防护;
5. 组间依赖(跨 group)不支持的架构原因。

> 下一章:K8s 服务发现——最复杂的 SD 实现。
