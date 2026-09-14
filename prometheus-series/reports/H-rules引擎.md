# H - Prometheus rules 引擎深读(记录规则与告警规则)

> 基于 prometheus/prometheus 源码,shallow clone,commit `b0f312b`(2025 年主干)。所有行号以该 commit 为准,已用 grep -n / Read 实际核对。本章呼应卷一 05 章(TSDB 读写路径)中 Appender/Querier 的事务语义。

`rules/` 目录全景(去掉测试与 fixtures 后仅 6 个源文件,引擎出奇地小):

| 文件 | 职责 |
|---|---|
| `rules/manager.go` | Manager:加载/更新规则组、并发控制器、依赖控制器、NotifyFunc 适配 |
| `rules/group.go` | Group:每 goroutine 一组的调度循环、Eval 评估事务、依赖图、for 状态恢复 |
| `rules/alerting.go` | AlertingRule:active map 状态机、ALERTS/ALERTS_FOR_STATE 合成序列、发送判定 |
| `rules/recording.go` | RecordingRule:求值并重写指标名/标签 |
| `rules/rule.go` | Rule 接口(共 18 个方法,含依赖查询方法) |
| `rules/origin.go` | 把规则信息注入 ctx,供查询溯源(rules → PromQL 引擎的"是谁在查") |

注意:模板引擎已不在 `rules/template.go`,迁至 `template/template.go`(卷一 A 报告写作时点的路径差异,本章按新位置标注)。

## 1. 全景:一条告警规则的生涯

```
规则文件 rule.yml
   │ rules.Manager.Update (manager.go:271)
   │   LoadGroups 解析 → NewAlertingRule/NewRecordingRule (manager.go:402/416)
   │   RuleDependencyController.AnalyseRules (manager.go:424)
   ▼
Group{file;name} ── 每 goroutine 一个 (manager.go:308-319 newg.run)
   │ Group.run (group.go:208)
   │   首睡到下一个"对齐槽位" EvalTimestamp+interval (group.go:212-217)
   │   time.NewTicker(interval) 循环驱动 (group.go:229)
   ▼
Group.Eval 每个槽位一次 (group.go:504)
   │ 组内规则按声明顺序串行 eval (group.go:674-682)
   │ for 循环内: rule.Eval → 状态机推进 → sendAlerts → Appender 回写
   ▼
AlertingRule.Eval (alerting.go:387)
   │ instant query @ ts (alerting.go:389)
   │ 结果向量 → 展开标签/注解模板 → hash 进 alerts map (alerting.go:456-462)
   │ 与 r.active 合并:新 labelset → StatePending (alerting.go:471-478)
   │ 持续命中 ≥ for → StateFiring (alerting.go:526-529)
   │ 从结果消失 → resolve / keep_firing_for (alerting.go:483-519)
   ▼
sendAlerts: needsSending? → NotifyFunc (alerting.go:618-633)
   │ needsSending: pending 不发;firing 每 resendDelay 重发;resolve 立即补发 (alerting.go:102-113)
   ▼
rules.SendAlerts → notifier.Manager.Send (manager.go:498-521 → notifier/manager.go:259)
   │ StartsAt=FiredAt, EndsAt=ResolvedAt|ValidUntil (manager.go:504-513)
   ▼
Alertmanager(去重/分组/路由/静默 → 真正的邮件/IM/电话)
   与此并行:ALERTS / ALERTS_FOR_STATE 两条合成序列写回 TSDB (alerting.go:539-542)
```

## 2. 调度专节:group goroutine 模型与 interval 对齐

### 2.1 一个 group 一个 goroutine

`Manager.Update` 为每个新 group 起 goroutine:`go func(newg *Group){ ...; newg.run(m.opts.Context) }(newg)`(rules/manager.go:308-319)。新旧配置比对用 `Group.Equals`(rules/group.go:892-924,逐字段比较 rules 的 YAML 字符串),未变化的 group 直接复用旧实例(rules/manager.go:302-304),**active 状态不丢**;变化的先 `oldg.stop()` 再 `newg.CopyState(oldg)`(rules/manager.go:309-311)。

`CopyState` 按 "name+labels" 匹配规则(rules/group.go:459-475),把旧规则的 `seriesInPreviousEval` 与**整个 active map** 拷进新 group(rules/group.go:486:`maps.Copy(ar.active, far.active)`)——热重载不断告警的关键。

Stop 语义分两步(rules/manager.go:245-266):先全部 `stopAsync`(close done channel)再统一 `waitStopped`;随后 `close(m.done)` 触发各 group 的 stale 清理 goroutine(rules/manager.go:262-263)。

### 2.2 interval 对齐:hash offset 而非随机抖动

各 group 的评估时刻不是 `启动时刻 + N*interval`,而是对齐到全局时间轴上的"槽位",槽位相位由 group 的 hash 决定:

```go
// rules/group.go:422-445
func (g *Group) EvalTimestamp(startTime int64) time.Time {
    var (
        offset = int64(g.hash() % uint64(g.interval))
        adjNow = startTime - offset
        // Adjust to perfect evaluation intervals.
        base = adjNow - (adjNow % int64(g.interval))
        // Add one offset to randomize the evaluation times of this group.
        next = base + offset
    )
    return time.Unix(0, next).UTC()
}
```

`g.hash()` 是 `labels{name,file}` 的哈希(rules/group.go:312-318),同一 group 永远落在同一相位;不同 group 因 hash 不同而错开,避免所有规则组在同一瞬间砸向 TSDB。注释解释了为何先减再加 offset:保证 `now - (now%interval) + offset` 落在过去(rules/group.go:427-434)。

`run()` 首次先睡到 `EvalTimestamp(now)+interval`(即下一个对齐槽位,rules/group.go:212-217),然后起 ticker(rules/group.go:229)。注意用 ticker 而非逐次 sleep——评估耗时不累计漂移,每次 tick 后按 `missed = (time.Since(evalTimestamp)/interval) - 1` 补记错过多少槽位,并把 evalTimestamp 前移 `(missed+1)*interval`(rules/group.go:286-291):**评估落后不会越积越多,但错过即错过**(计入 `rule_group_iterations_missed_total`,rules/group.go:288)。

`evalTimestamp` 是"槽位时间"而非墙钟时间,它是 instant query 的时间戳(rules/group.go:538 传给 rule.Eval 的 `ts`),保证同一 interval 内多次重试/追踪的时间轴一致;trace 里用 `scheduleDelay` span 单独标出"调度延迟"(rules/manager.go:104-107)。

### 2.3 组内串行与并发实验开关

默认所有规则在组内按声明顺序串行:`for i, rule := range g.rules { eval(i, rule, nil) }`(rules/group.go:674-682),每条规则 eval 前检查 group 是否已停(rules/group.go:676-680)。并发评估是 feature flag `concurrent-rule-eval`:启用时 `concurrentRuleEvalController` 用加权信号量限流(全局上限,默认 4,rules/manager.go:572-580;cmd/prometheus/main.go:623-624),把组内规则切成三段批:无依赖的先并发 → 既有依赖又是被依赖的逐条串行 → 无被依赖的再并发(rules/manager.go:582-616),批间 `wg.Wait()` 硬同步(rules/group.go:707)。

## 3. 告警状态机专节:active map 的 pending/firing

### 3.1 状态与载体

四态定义于 rules/alerting.go:56-67:`StateUnknown(0) < StateInactive(1) < StatePending(2) < StateFiring(3)`(整型大小即"最高态"比较,`State()` 取所有实例最大态,rules/alerting.go:555-570)。每个 AlertingRule 持有 `active map[uint64]*Alert`,键是**展开标签后的 labelset 指纹**(rules/alerting.go:146-150, 449)。

### 3.2 一次 Eval 内的迁移

`AlertingRule.Eval`(rules/alerting.go:387-551)分四步:

**第一步:求值 + 造候选。** instant query 后,对每个样本展开模板生成 alert(labels 在 rules/alerting.go:435-440,annotations 在 442-446),初始化为 `StatePending, ActiveAt=ts`(rules/alerting.go:456-462)。同 hash 重复直接报 `ErrDuplicateAlertLabelSet`(rules/alerting.go:452-454)。

**第二步:合并进 active。** 已存在且非 inactive 的实例只更新 Value/Annotations——**ActiveAt 保留旧值,这是 for 计时的累积点**(rules/alerting.go:471-474);新 labelset 整条插入(rules/alerting.go:477)。

**第三步:推进状态。** 核心迁移:

```go
// rules/alerting.go:526-537
if a.State == StatePending && ts.Sub(a.ActiveAt) >= r.holdDuration {
    a.State = StateFiring
    a.FiredAt = ts
}
// If the alert is firing and the active time is less than the new hold duration, set the state to pending.
if a.State == StateFiring && ts.Sub(a.ActiveAt) < r.holdDuration {
    a.State = StatePending
    a.FiredAt = time.Time{}
    a.LastSentAt = time.Time{}
    a.KeepFiringSince = time.Time{}
}
```

pending→firing 的判定就是一次时间差比较:**for 的实现没有任何定时器,全靠每次 Eval 时与 ActiveAt 求差**。第二段是"for 被改小"的回退:热重载后 holdDuration 变短时把已 firing 的打回 pending(此时 LastSentAt 清零,保证重发)。

**Resolve(从结果向量消失)与 keep_firing_for**(rules/alerting.go:482-519):指纹不再出现在本轮结果里时,若在 firing 且配了 keep_firing_for,则记 `KeepFiringSince` 并在窗口内继续算 firing(rules/alerting.go:490-497);pending 态直接 delete(rules/alerting.go:510-512);其余置 inactive、记 `ResolvedAt=ts`(rules/alerting.go:513-516)。已 resolve 的实例仍在 map 里保留 `resolvedRetention = 15min`(rules/alerting.go:383, 510)——注释写明这是为了让 resolved 通知有足够机会送达 Alertmanager(rules/alerting.go:499-509)。

**第四步:写合成序列。** restored 后每个 active 实例产出两条样本:`ALERTS{alertstate=...}`(值恒 1,rules/alerting.go:237-254)与 `ALERTS_FOR_STATE`(值 = ActiveAt.Unix 秒,rules/alerting.go:258-276, 539-542)。超过 group limit 则**清空整个 active map 并报错**(rules/alerting.go:545-548)——防告警风暴的釜底抽薪。

### 3.3 发送判定:resendDelay 与 holdDuration(注意是 ValidUntil)

`sendAlerts` 在 Group.Eval 中、**Appender 回写之前**被调用(rules/group.go:557-559,先通知后回写):

```go
// rules/alerting.go:102-113
func (a *Alert) needsSending(ts time.Time, resendDelay time.Duration) bool {
    if a.State == StatePending {
        return false
    }
    // if an alert has been resolved since the last send, resend it
    if a.ResolvedAt.After(a.LastSentAt) {
        return true
    }
    return a.LastSentAt.Add(resendDelay).Before(ts)
}
```

三句话:pending 永不上报;resolved 晚于上次发送则立即补发 resolve;否则按 `resendDelay`(默认 1m,cmd/prometheus/main.go:620-621)周期重发 firing。每次发送时 `ValidUntil = ts + 4*max(interval, resendDelay)`(rules/alerting.go:623-625,注释:容忍两次 Eval/AM 发送失败)。

跨进程边界由 `rules.SendAlerts`(rules/manager.go:498-521)完成格式转换:`StartsAt=FiredAt`、`EndsAt = ResolvedAt(已解析)或 ValidUntil(仍在 firing)`、`GeneratorURL = externalURL + 表达式表格链接`(rules/manager.go:504-513, 507)。随后 `notifier.Manager.Send` 对每台 Alertmanager 入队(notifier/manager.go:259-280 → alertmanagerset.go:134),由 sendloop 异步批量重试(notifier/sendloop.go:164-166 截断超批)。

### 3.4 重启恢复:ALERTS_FOR_STATE 的用途

`RestoreForState`(rules/group.go:761-889)在 group 首次 Eval 后查询自己写的 `ALERTS_FOR_STATE` 序列(rules/group.go:798,值即 ActiveAt),按"宕机前已 pending 多久"回拨 ActiveAt:剩余 pending > `ForGracePeriod`(默认 10m,cmd/prometheus/main.go:617-618)则平移补偿宕机时长(rules/group.go:872-878);剩余 < grace 则压到 grace 后(rules/group.go:859-871,注释里附了 firingTime 的代数证明)。超出 `OutageTolerance`(默认 1h,cmd/prometheus/main.go:614-615)不恢复(rules/group.go:770-771)。恢复窗口查询只对 holdDuration ≥ grace 的规则进行(rules/group.go:789-796)。

## 4. 记录规则专节:回写路径

`RecordingRule.Eval`(rules/recording.go:86-123)是全引擎最短的路径:query → 改标签 → 返回向量。标签重写用 `labels.NewBuilder`:`lb.Reset(sample.Metric)` 后 `lb.Set(labels.MetricName, rule.name)` 覆盖指标名,再叠加规则自带 labels(rules/recording.go:94-107)。去重校验 `vector.ContainsSameLabelset()`(rules/recording.go:111-113)与 limit 检查(rules/recording.go:116-118)在 Eval 内完成。

**真正的 TSDB 写入不在 RecordingRule 内,而在 Group.Eval 的闭包里**(每条规则一个独立事务):

```go
// rules/group.go:570-604 (摘录)
app := g.opts.Appendable.Appender(ctx)
...
for _, s := range vector {
    if s.H != nil {
        _, err = app.AppendHistogram(0, s.Metric, s.T, nil, s.H)
    } else {
        app.SetOptions(g.appOpts) // DiscardOutOfOrder: true, group.go:146
        _, err = app.Append(0, s.Metric, s.T, s.F)
    }
    ...
}
// defer: app.Commit() 失败则规则置 HealthBad (rules/group.go:573-591)
```

要点三条:(1) 写入时间戳用 `s.T` = 求值时的槽位时间 `ts`(记录规则在 AlertingRule.Eval 里是 `ts.Add(-queryOffset)`,因 queryOffset 只影响查询时刻,样本仍带查询时间戳);(2) **每条规则独立 Appender + Commit**,一条规则失败不影响其他规则的样本(rules/group.go:573-591);(3) 上一轮产出、本轮消失的序列在本事务内补 StaleNaN 标记(rules/group.go:642-661),group 停用/规则删除的陈旧序列延迟"2 个 interval"后由 `cleanupStaleSeries` 补写,给改名规则留插入窗口(rules/group.go:232-253, 727-757)。

查询侧一致性:eval 经 `EngineQueryFunc` → `engine.NewInstantQuery(ctx, q, nil, qs, t)`(rules/manager.go:53-78),`q` 就是 Prometheus 自身的 storage.Queryable(rules/manager.go:144),即**规则读到的是包含本 group 之前规则的写入的头修数据**(组内串行天然保证依赖规则看到新序列;head 上未落盘的样本对同进程 Querier 可见,呼应卷一 05 章的 head/Querier 路径)。ctx 里带着 `RuleDetail` 来源标记(rules/origin.go:29-46, group.go:219-224 注入 ruleGroup),查询超时/取消沿用引擎的 ctx 传播。

## 5. 模板专节:标签/注解的展开引擎

告警 labels/annotations 是 Go text/template。每次 Eval 对每个样本构造 `AlertTemplateData`(labels、externalLabels、externalURL、值样本,template/template.go:298-299),再预置四个便捷变量(rules/alerting.go:409-414):

```go
// rules/alerting.go:409-414
defs := []string{
    "{{$labels := .Labels}}",
    "{{$externalLabels := .ExternalLabels}}",
    "{{$externalURL := .ExternalURL}}",
    "{{$value := .Value}}",
}
```

展开经 `template.NewTemplateExpander`(template/template.go:121-140),funcMap 注册了 `query/first/label/value/match/humanize...` 等模板函数(其中 `query` 让注解模板里也能跑 PromQL,template/template.go:131-134)。`Expander.Expand`(template/template.go:326-344)用 `defer recover` 兜底:模板 panic 或出错只产出 `<error expanding template: ...>` 并计 `templateTextExpansionFailures`,**绝不因注解模板缺陷炸掉评估循环**(rules/alerting.go:427-431 的 error 降级同此)。展开失败的 labels 值照样写入——这也是 `QueryForStateSeries` 跳过含 `{{` 的标签值做匹配的原因(rules/alerting.go:284-289)。

## 6. 依赖规则:为什么"声明顺序即依赖顺序"

`RuleDependencyController.AnalyseRules` 在加载时对每组规则建依赖图(rules/manager.go:424, 534-545)。`buildDependencyMap`(rules/group.go:1148-1234)扫描每条规则的 VectorSelector:选择器命中前面某条规则的输出名即构成依赖;命中 `ALERTS`/`ALERTS_FOR_STATE` 元序列时按 `alertname` matcher 关联到对应告警规则(rules/group.go:1186-1196, 1218-1222)。两个关键保守性:出现无指标名的通配选择器(如 `{cluster="prod1"}`)则整图判为不可信(indeterminate),返回 nil(rules/group.go:1178-1183, 1229-1231);**只认"前面的规则"为依赖**——注释明说组内规则按定义顺序生效,后面的规则不构成依赖(rules/group.go:1199-1206)。所以官方语义是:组内依赖靠书写顺序表达,引擎不做拓扑重排;依赖信息只用于 (a) 并发评估时切批的安全判定(rules/manager.go:582-616),(b) 查询溯源元数据(rules/origin.go:37-41)。

## 7. 设计动机

**为什么组内串行为默认?** 记录规则链是"上一条写、下一条读"的流水线,串行 + 组内可见的 head 写入 = 免费的依赖语义;一旦并发,就必须依赖图证明安全——这正是依赖控制器与三段式切批存在的全部理由(rules/manager.go:585-587)。串行也让 active map 等组内状态无需细粒度锁(Group 只有一把 mtx 保护统计字段,rules/group.go:55)。

**为什么 for 必须显式、且用时间差实现?** 瞬时毛刺(抓取抖动、单点重启)不应触发通知;for 把"条件持续 N"的判断从查询语言挪进状态机,查询本身保持无状态。时间差实现(`ts.Sub(ActiveAt) >= holdDuration`,rules/alerting.go:526)让状态机只需每 Eval 推进一步,重启后还能靠 ALERTS_FOR_STATE 把 ActiveAt 持久化在 TSDB 里恢复(rules/group.go:798-885)——用既有存储解决自身状态持久化,不引入额外存储。

**为什么通知走 Alertmanager 而非直发?** Prometheus 只保证"至少多次发送"(firing 每 resendDelay 重发、resolve 补发、ValidUntil 兜底超时,rules/alerting.go:618-633),不做路由/分组/抑制/静默/重试退避——这些有状态的通知策略集中在 Alertmanager;Prometheus 侧无通知队列持久化,notifier 队列丢弃即等下轮重发。这种分工让 Prometheus 的告警代码保持无状态可水平重启。

## 8. FAQ 素材

1. **同一 group 改了配置,告警状态为什么没丢?** `Equals` 判等失败的 group 才重建,`CopyState` 按 name+labels 把旧 `active` map 整体拷入(rules/group.go:486);判等通过的 group 连 goroutine 都复用(rules/manager.go:302-304)。
2. **评估"错过"会补跑吗?** 不会。只计 `IterationsMissed` 并把槽位时间前推,下次从最新槽位开始(rules/group.go:286-291);槽位时间是过去的对齐点,永远不追历史。
3. **for 期间 Prometheus 重启,要重头等吗?** 不用。ALERTS_FOR_STATE 序列记录了 ActiveAt,`RestoreForState` 回拨(rules/group.go:848-881);但 holdDuration < ForGracePeriod(默认 10m)的规则直接放弃恢复(rules/group.go:789-796)。
4. **告警在 for 中途条件消失,会发通知吗?** 不会,pending 从不发送(rules/alerting.go:103-105),且 pending 态实例从结果消失直接 delete(rules/alerting.go:510-512)——用户完全无感。
5. **resolved 通知丢了怎么办?** 双保险:resolved 实例在 active map 里留 15 分钟供补发(rules/alerting.go:383, 503-509);发送时 `ResolvedAt.After(LastSentAt)` 判定立即重发(rules/alerting.go:108-110);AM 侧未收到 EndsAt 会按超时自 resolve。
6. **两条规则输出同名序列会怎样?** 记录规则 `ContainsSameLabelset` 报错整条失败(rules/recording.go:111-113);告警规则同 hash 直接 `ErrDuplicateAlertLabelSet`(rules/alerting.go:452-454)。时间戳相同值不同的样本由 Appender 按 `ErrDuplicateSampleForTimestamp` 丢弃(rules/group.go:621-623)。
7. **limit 超了为什么整个 active map 清空?** rules/alerting.go:545-548:与其留半成品状态,不如显式报错让用户修复,防止失控 labelset 刷爆 TSDB。
8. **组间能依赖吗?** 不能安全依赖:不同 group 调度相位不同(hash offset),互相看到的可能是对方上一轮的结果。依赖语义只在组内以书写顺序成立(rules/group.go:1199-1206)。
9. **queryOffset 是什么?** 组/全局配置,让规则查询"过去的快照"(如对齐远端写延迟),求值时刻仍为 ts,查询时刻为 `ts.Add(-queryOffset)`(rules/alerting.go:389;QueryOffset 解析 rules/group.go:715-725)。
10. **告警样本为什么还有 ALERTS_FOR_STATE?** ALERTS 只表达当前态,重启无法区分"pending 多久了";FOR_STATE 值 = ActiveAt.Unix(),把计时起点持久化进 TSDB(rules/alerting.go:541)。

## 9. 深挖素材

1. **hash offset 与指标抓取的 scrape offset 同构**:group.go:422-445 的 `% interval` 对齐与 scrape loop 的 offset 思路同源,可对比 `scrape/` 的槽位设计,讨论"分布式系统里用确定性哈希相位替代随机抖动"。
2. **并发切批的三段式与 DAG 分层**:manager.go:585-615 实际是把依赖图分层(无前驱层 → 中间链 → 无后继层),但依赖图只认书写顺序,可讨论为何不做完整拓扑排序(保守性 vs 语义复杂度)。
3. **ValidUntil 的租约语义**:alerting.go:623-625 的 `4*max(interval,resendDelay)` 是典型的 lease 续约设计,AM 侧 EndsAt 过期即视为 resolve——可与分布式租约/TTL 模式互参。
4. **RestoreForState 的代数证明**:group.go:859-871 注释证明"压到 grace 后 firing"的公式正确性,适合作为"状态恢复时的不变量设计"案例。
5. **通知先于回写的次序**(group.go:557-570):sendAlerts 在 Appender 之前,意味着通知已发出而 ALERTS 样本可能写入失败——两侧不一致的容忍窗口与 15min resolvedRetention 的关系。

## 写作要点速查表

| # | 关键点 | 位置 |
|---|---|---|
| 1 | 每 group 一 goroutine,Update 内 `newg.run` | rules/manager.go:308-319 |
| 2 | interval 对齐:hash%interval 作相位偏移 | rules/group.go:422-445(hash:312-318) |
| 3 | 首睡至下一对齐槽位,ticker 驱动,missed 只计数不补跑 | rules/group.go:212-229, 286-291 |
| 4 | 组内串行 eval 循环(默认) | rules/group.go:674-682 |
| 5 | 并发切批三段式(无依赖/中间/无被依赖) | rules/manager.go:582-616 |
| 6 | active map:按 labelset 指纹索引 | rules/alerting.go:146-150, 449 |
| 7 | pending→firing:`ts.Sub(ActiveAt) >= holdDuration`;for 改小回退 | rules/alerting.go:526-537 |
| 8 | resolve + keep_firing_for + 15min resolvedRetention | rules/alerting.go:482-519, 383 |
| 9 | needsSending 三判:pending 不发/resolve 补发/resendDelay 重发 | rules/alerting.go:102-113 |
| 10 | sendAlerts:ValidUntil=ts+4*max(interval,resendDelay) | rules/alerting.go:618-633 |
| 11 | SendAlerts 转 notifier.Alert:FiredAt/ResolvedAt/ValidUntil | rules/manager.go:498-521 |
| 12 | notifier 入队 → Alertmanager | notifier/manager.go:259-280 |
| 13 | 记录规则:改指标名/标签 + 去重/limit | rules/recording.go:86-123 |
| 14 | 每规则独立 Appender 事务 + StaleNaN 补写 | rules/group.go:570-661, 727-757 |
| 15 | 模板展开:defs 四变量 + Expand 兜底 recover | rules/alerting.go:409-433;template/template.go:121-140, 326-344 |
| 16 | 依赖图:只认书写顺序在前的规则;通配判 indeterminate | rules/group.go:1148-1234(1199-1206, 1178-1183) |
| 17 | for 状态恢复:ALERTS_FOR_STATE + ForGracePeriod 公式 | rules/group.go:761-889(848-881) |
| 18 | 默认参数:outage 1h / grace 10m / resend 1m / 并发 4 | cmd/prometheus/main.go:614-624 |
