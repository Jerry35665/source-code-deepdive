# 第 02 章 · unit 状态机与 job 引擎:声明式依赖如何变成执行计划

> 基线:commit `1f66b524`。核心:src/core/unit.c、job.c、transaction.c。

## 2.0 全景:两台正交自动机 + 事务十步

```
Unit 状态机(unit-def.h:38-49,8 态):INACTIVE→ACTIVATING→ACTIVE→(RELOADING)→DEACTIVATING→…
  真正写状态的是各类型自己的 *_set_state,统一经 unit_notify(unit.c:2738)上报
Job 状态机:WAITING→(job_run_and_invalidate)→RUNNING→(job_finish_and_invalidate)→FINISHED
Transaction 十步(transaction.c:800-892):标 anchor matters→minimize_impact→drop_redundant
  →循环{GC→verify_order 环检测}→循环{merge_jobs}→drop_redundant→is_destructive→apply
```

状态→job 结算的翻译器是 `unit_process_job`(unit.c:2636-2696):job 在 RUNNING 而 unit 逆着 job 意愿变状态时标 unexpected,触发 retroactively_* 补发 START/STOP job(unit.c:2313-2344)——**"状态变化没有 job 请求"本身就是信号**。

## 2.1 依赖的表示:名字 → atom 位掩码

用户可见的 20+ 种 UnitDependency 只是概念名,真正起作用的是映射出的正交 atom(unit-dependency-atom.c:6-101):Requires=PULL_IN_START+失败连坐(但不做事后绑定);Wants=失败被忽略;Requisite=只 VERIFY 不拉起;BindsTo=Requires 全部+CANNOT_BE_ACTIVE_WITHOUT(须配 After 否则有竞态,unit.c:1899-1919);Upholds=持续保活;Conflicts=PULL_IN_STOP;Before/After=纯排序 atom,被 job_is_runnable 与环检测消费;OnFailure/OnSuccess=事件触发 START。引擎只面对 30 来个原子语义——新增依赖类型无需改引擎。**常见误读的根源**:Requires= 的文档语义全部来自 atom 组合,不含排序也不含"跟死"。

## 2.2 job 合并:一张满足结合律的真值表

`job_merging_table`(job.c:416-424)是 10 格静态表:START+STOP 不可合并(-1),RESTART 兼容一切;注释给出结合律与可传递性证明(job.c:398-415)。查出的状态相关类型(RELOAD_OR_START 等)再按 unit 当前状态塌缩(job.c:482-516)。**STOP/RESTART 永远排在对方前面**(job_compare,job.c:1717-1748)。同 unit 多 job 归一时发现不可合并,删一个再试:双方都不 matters 时"宁删 STOP 不删 START"(transaction.c:176-205)。

## 2.3 环检测:单趟 DFS + 删环自愈

`transaction_verify_order_one` 沿排序边 DFS:marker 记来路、generation 去重;找到环就挑环上第一个非 anchor 的 job 所在 unit 整体删除,返回 -EAGAIN 让外层重试;删不动才报 cyclic 错误(transaction.c:412-563)。如实修正直觉:这是带记忆化的多源 DFS,单轮 O(V+E),不是 O(n²);每删一环重跑一轮,总代价随修复次数线性。**删环自愈让带小环的系统仍能启动**——工程上比直接拒绝可用性高。

## 2.4 加载与默认依赖

加载链:manager_load_unit→unit_load_fragment(load-fragment.c:6196-6300):transient 优先→lookup paths 找主文件→掩码检查(空文件即 UNIT_MASKED)→config_parse→drop-in 叠加→系统实例找不到回退内置单元。**默认依赖写在代码里按类型生成**而非单元文件:service 自动 After+Requires sysinit.target、Before+Conflicts shutdown.target(service.c:1114-1152),打 UNIT_DEPENDENCY_DEFAULT 掩码便于 reload 时定向清洗,DefaultDependencies=no 可整体关闭。停机全是普通 job:shutdown.target 的 Conflicts 语义经 PULL_IN_STOP 反向给全系统下 STOP;job_shutdown_magic 打停机时间戳(job.c:1414-1444)。

## 2.5 设计动机

1. **事务制而非即时执行**:先物化"想要的世界状态"再原子裁决,apply 带 rollback——依赖图从不半更新;
2. **合并做成静态表**:合并必须满足交换律/结合律/可传递,一张表+数学证明把语义复杂度压到 O(1) 查表;
3. **环检测 O(V+E)+自愈重试**:现实依赖图极稀疏;含环配置属异常路径,删除式自愈比拒绝可用;
4. **默认依赖在代码**:sysinit/basic/shutdown 耦合是"类型不变量"而非用户策略,独立掩码便于精准清洗;
5. **unit_notify 收口**:任何来源的状态变化获得完全一致的副作用集(D-Bus/时间戳/job 结算/十几个队列)。

## 2.6 FAQ

**Q1:Requires= 隐含 After= 吗?**
不:排序是独立 atom;文档反复强调的这条警告在 atom 表里一目了然。

**Q2:BindsTo 为什么要求配 After?**
不配则启动时无法静态判断依赖是否已活,有竞态(unit.c:1899-1919 注释)。

**Q3:TRY_RESTART 是独立类型吗?**
进事务前就塌缩成 RESTART 或 NOP(job.h:32-39)。

**Q4:环了就拒绝启动吗?**
先删环自愈(挑非 anchor job),删不动才拒绝。

**Q5:同一个 unit 同时收到 START 和 STOP?**
查合并表:不可合并,事务里删一个;都不 matters 时宁删 STOP。

**Q6:daemon-reload 会重置超时吗?**
不:coldplug 按状态反推绝对截止时刻重建定时器(job.c:1368-1393)。

**Q7:没有 job 请求 unit 自己变 active?**
retroactively_start_dependencies 即时补发 Requires= 对象的 START job。

**Q8:mask 的 unit 会怎样?**
空文件即 UNIT_MASKED,不加载(load-fragment.c:6247-6251)。

**Q9:无主的 inactive unit 会堆积吗?**
GC 队列回收;UNIT_REFERENCES 引用让被依赖的 target 不被 GC。

**Q10:isolate 是什么?**
JOB_ISOLATE 模式:应用事务前清掉事务外的全部已安装 job(transaction.c:727-743)。

## 2.7 小结与深挖方向

本章结论:**job 引擎="atom 位掩码+真值表合并+事务十步+DFS 删环自愈"**。深挖:

1. JOB_REPLACE_IRREVERSIBLY 的不可逆安装语义(transaction.c:631);
2. late merge 禁止并入 RELOAD 的理由(两次 reload 间的配置变更,job.c:194-219);
3. CYCLIC_TRANSACTIONS_MAX=4096 的日志限流;
4. service_add_default_dependencies 与 user 实例的 basic.target 差异;
5. PropagatesStopTo 的"优雅停"延迟裁决(job_type_propagate_stop_graceful)。
