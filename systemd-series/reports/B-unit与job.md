# B · unit 状态机与 job 引擎:声明式依赖如何变成执行计划

> 基线:systemd commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`。所有行号均以该基线实际核对。
> 核心文件:`src/core/unit.c`(7294 行)、`src/core/job.c`(1756 行)、`src/core/transaction.c`(1405 行)、`src/core/manager.c`(5677 行)、`src/core/unit-dependency-atom.c`(245 行)。

## 0. 全景图

```
【Unit 状态机】UnitActiveState(src/basic/unit-def.h:38-49)
                       vtable->start()
   UNIT_INACTIVE/UNIT_FAILED ────────────────► UNIT_ACTIVATING
        ▲   ▲                                     │           │
        │   │  停止完成                     失败/超时          │ 启动完成(unit_notify:
        │   └──────────────────────┐              │           │  UNIT_IS_ACTIVE_OR_RELOADING)
        │                          ▼              ▼           ▼
        │                 UNIT_DEACTIVATING   UNIT_FAILED   UNIT_ACTIVE ◄──reload── UNIT_RELOADING
        │                          │                          ▲
        └──────────────────────────┴──────────────────────────┘ (stop)
   注:另有 UNIT_MAINTENANCE(degraded)与 UNIT_REFRESHING(资源刷新),见 unit-def.h:45-46;
   高层状态由各类型私有子状态经 state_translation_table 折算(target.c:12、32;service.c:1731)。

【Job 状态机】JobState(src/core/job.h:52-58)
   job_install()                    job_run_and_invalidate()            job_finish_and_invalidate()
JOB_WAITING ─────────────────► JOB_RUNNING ────────────────────────► JOB_FINISHED(uninstall+free)
   ▲   ▲                          │   │
   │   └── RESTART 补丁: stop 完成后改类型为 JOB_START,重新入队(job.c:1037-1047)
   └────── r == -EAGAIN:依赖未就绪/子状态等待,回 WAITING(job.c:968-969)

【一次 Transaction 的合并与环检测】
 manager_add_jobs()                        manager.c:2311(D-Bus 入口 dbus-manager.c:903)
   ├─ transaction_new()                                          manager.c:2347
   ├─ anchor: job_type_collapse() 后 transaction_add_job_and_dependencies()   递归展开
   │    ├─ transaction_add_one_job():同 unit 同类型 job 已存在 → 去重      transaction.c:894-935
   │    ├─ 挂 JobDependency(by)或进 anchor_jobs(无 by)                transaction.c:1112-1123
   │    └─ 按 atom 拉入依赖 job:PULL_IN_START→START、PULL_IN_VERIFY→VERIFY_ACTIVE、
   │        PULL_IN_STOP→STOP(CONFLICTS)、PROPAGATE_STOP→STOP/TRY_RESTART      transaction.c:1144-1245
   ├─ (isolate) transaction_add_isolate_jobs()                          transaction.c:1296
   └─ transaction_activate() 十步流水线                                  transaction.c:800-892
        1 标记 matters_to_anchor      2 minimize_impact      3 drop_redundant
        4 loop{ collect_garbage → verify_order(DFS 找环,删环上一个非 anchor job → -EAGAIN 重试) }
        5 loop{ merge_jobs(同 unit 多个 job 按合并表合一;不可合并 → delete_one_unmergeable_job 再试) }
        6 drop_redundant → 9 is_destructive → 10 transaction_apply():job_install()+入 run_queue
```

## 1. 两个正交的自动机:Unit 状态与 Job 类型

systemd 把"长期生命状态"放在 Unit 上,把"一次性动作"放在 Job 上。高层状态枚举只有 8 个:

```c
// src/basic/unit-def.h:38-49
typedef enum UnitActiveState {
        UNIT_ACTIVE,
        UNIT_RELOADING,
        UNIT_INACTIVE,
        UNIT_FAILED,
        UNIT_ACTIVATING,
        UNIT_DEACTIVATING,
        UNIT_MAINTENANCE,
        UNIT_REFRESHING,
        ...
} UnitActiveState;
```

注意:新版代码里**没有**统一的 `unit_set_state()`——真正写状态的是各类型自己的 `*_set_state()`,再经 `unit_notify()` 上报:service.c:1651/1731、target.c:25-32(用 `state_translation_table` 把私有子状态折算成 ActiveState)。`unit_active_state()` 只是虚表转发:`UNIT_VTABLE(u)->active_state(u)`(unit.c:911-922)。

Job 侧,类型枚举刻意按"合并语义"排布(job.h:8-50):进入事务的只有 `JOB_START/VERIFY_ACTIVE/STOP/RELOAD/RESTART`(+哨兵 `_JOB_TYPE_MAX_MERGING`);`JOB_NOP`、`JOB_TRY_RESTART`、`JOB_TRY_RELOAD`、`JOB_RELOAD_OR_START` 分别处在更高档位,注释明确说明 TRY_RESTART "总在进事务前塌缩成 RESTART 或 NOP"(job.h:32-39)。

## 2. 状态迁移由谁驱动:unit_notify 是唯一的总线上报点

任何子状态变化最终都汇到 `unit_notify(u, os, ns, reload_success)`(unit.c:2738-2900)。它在一处串起了时间戳、D-Bus 队列、job 结算、审计和十几个延迟队列,要点:

```c
// src/core/unit.c:2799-2814(节选)
/* Let's propagate state changes to the job */
if (u->job)
        unexpected = unit_process_job(u->job, ns, reload_success);
else
        unexpected = true;
/* If this state change happened without being requested by a job, ... */
if (unexpected) {
        if (UNIT_IS_INACTIVE_OR_FAILED(os) && UNIT_IS_ACTIVE_OR_ACTIVATING(ns))
                retroactively_start_dependencies(u);
        else if (UNIT_IS_ACTIVE_OR_ACTIVATING(os) && UNIT_IS_INACTIVE_OR_DEACTIVATING(ns))
                retroactively_stop_dependencies(u);
}
```

驱动源有三类:
- **job 完成**:`job_run_and_invalidate()` 调 `unit_start/unit_stop/unit_reload`(job.c:881-902),类型回调再推进子状态;
- **进程/cgroup 事件**:子进程退出、cgroup empty 等直接改子状态再走 `unit_notify`(service.c:1731);
- **D-Bus/配置**:`unit_notify` 第一步就是 `unit_add_to_dbus_queue(u)`(unit.c:2751),而 D-Bus 侧的 StartUnit 等方法经 `manager_add_jobs()` 造事务(dbus-manager.c:749、850、903)。

`unit_process_job()`(unit.c:2636-2696)是"状态→job 结算"的翻译器:START/VERIFY_ACTIVE 见到 `UNIT_IS_ACTIVE_OR_RELOADING` 即 `JOB_DONE` 收尾;若 job 在 RUNNING 而 unit 逆着 job 意愿变了状态(如启动中进程死了),标记 `unexpected=true` 并按 `JOB_FAILED/JOB_DONE` 作废 job。`unexpected` 正是触发 `retroactively_*` 的开关(unit.c:2313-2344):例如 unit 自己变 active 而 Requires= 对象还没起,就即时补 `manager_add_job(JOB_START, other, JOB_REPLACE)`(unit.c:2319-2327)。

## 3. 依赖的表示:dep 类型表 → 行为原子(atom)

用户可见的 20+ 种 UnitDependency(src/basic/unit-def.h:222-278)只是"概念名",真正起作用的是它映射出的位掩码 atom。核心映射表在 `src/core/unit-dependency-atom.c:6-101`:

```c
// src/core/unit-dependency-atom.c:17-35(节选)
[UNIT_REQUIRES]  = UNIT_ATOM_PULL_IN_START |
                   UNIT_ATOM_RETROACTIVE_START_REPLACE |
                   UNIT_ATOM_ADD_STOP_WHEN_UNNEEDED_QUEUE | ...,
[UNIT_REQUISITE] = UNIT_ATOM_PULL_IN_VERIFY | ...,      // 只验证不拉起
[UNIT_WANTS]     = UNIT_ATOM_PULL_IN_START_IGNORED |
                   UNIT_ATOM_RETROACTIVE_START_FAIL | ...,
[UNIT_BINDS_TO]  = UNIT_ATOM_PULL_IN_START | ... |
                   UNIT_ATOM_CANNOT_BE_ACTIVE_WITHOUT | ...,
[UNIT_UPHOLDS]   = ... UNIT_ATOM_ADD_START_WHEN_UPHELD_QUEUE | ...,
[UNIT_CONFLICTS] = UNIT_ATOM_PULL_IN_STOP | UNIT_ATOM_RETROACTIVE_STOP_ON_START,
```

语义差异由此一目了然(引擎消费 atom 的位置附后):
- **Requires=**:`PULL_IN_START`(事务展开时拉入 START job,transaction.c:1144-1153)+ 失败传播 `RETROACTIVE_START_REPLACE`;但**不**做事后绑定;
- **Wants=**:同上但失败被忽略(`PULL_IN_START_IGNORED`,transaction.c:1155-1166);
- **Requisite=**:`PULL_IN_VERIFY`——只 enqueue 一个 `JOB_VERIFY_ACTIVE`,不在则失败,不拉起;
- **BindsTo=**:Requires 全部语义 + `CANNOT_BE_ACTIVE_WITHOUT`:被绑对象停止后自己也要停(`check_bound_by_dependencies`,unit.c:2303-2311;启动时强校验 `unit_verify_deps`,unit.c:1899-1919,注释要求必须配合 After= 才检查,否则有竞态);
- **PartOf=**:单 atom `ADD_DEFAULT_TARGET_DEPENDENCY_QUEUE`,stop 传播靠 `PropagatesStopTo` 另行配置(unit-dependency-atom.c:85、75-76);
- **Upholds=/UpheldBy=**:持续保活——对象 inactive 时被 `start_when_upheld` 队列重新拉起(unit.c:2221-2249、2866);
- **Conflicts=**:`PULL_IN_STOP|CONFLICTS` 位(transaction.c:1178-1186):启动自己 = 给对方下 STOP job,且两 job 互斥;
- **Before/After=**:纯排序 atom,在 `job_is_runnable`(job.c:554-568)与环检测(transaction.c:533-557)中消费;
- **OnSuccess=/OnFailure=**:单 atom,unit 变 INACTIVE/FAILED 时 `unit_start_on_termination_deps()` 补发 START job(unit.c:2346-2384、2831-2834),job 超时/依赖失败也补(job.c:1088-1098);
- **Triggers=/TriggeredBy=**:`can_trigger` 校验(unit.c:3246-3251),socket 激活 service 用;isolate 与 GC 时用于保护触发者(transaction.c:1273-1291)。

依赖的登记入口是 `unit_add_dependency()`(unit.c:3200-3286):先 `unit_follow_merge` 解别名、拒绝自依赖(unit.c:3223-3229)、按 atom 做类型合法性检查(device 不可被 Before、slice 校验等),底层实现把双向反依赖(如 REQUIRES↔REQUIRED_BY)和 `UNIT_REFERENCES` GC 引用一起写入 `u->dependencies` 二级 hashmap(unit.h:240-244,值是携带来源掩码的 `UnitDependencyInfo`,unit.h:131-137)。遍历一律用 `UNIT_FOREACH_DEPENDENCY(other, u, atom)`(unit.h:1264-1267,按"含任一 atom"匹配)。

一张速查表(全部可在 atom 表中逐行对出):

| 依赖 | 拉起 | 失败连坐 | 停止绑定 | 排序 | 备注 |
|---|---|---|---|---|---|
| Requires= | PULL_IN_START | RETROACTIVE_START_REPLACE + PROPAGATE_START_FAILURE | 无 | 无 | 失败即连坐,但对象事后停止不影响自己 |
| Requisite= | 只 VERIFY | PROPAGATE_START_FAILURE(经 REQUISITE_OF) | 无 | 无 | 不在即失败,不拉起 |
| Wants= | PULL_IN_START_IGNORED | 无 | 无 | 无 | 失败仅告警 |
| BindsTo= | PULL_IN_START | 同 Requires | CANNOT_BE_ACTIVE_WITHOUT | 需配 After | 对象停自己也停(unit.c:1899-1919) |
| PartOf= | 无 | 无 | 无 | 无 | 单 atom,主要供 stop 传播组合 |
| Upholds= | PULL_IN_START_IGNORED | 无 | 无 | 无 | START_STEADILY 保活(unit.c:2235-2244) |
| Conflicts= | — | — | PULL_IN_STOP | 隐式反序 | 启动自己=给对方 STOP job |
| Before/After= | — | — | — | 本体 | job_is_runnable + 环检测消费 |
| OnFailure/OnSuccess= | 事件触发 START | — | — | — | unit.c:2831-2834 |
| Triggers=/TriggeredBy= | 事件触发 | — | isolate 豁免 | — | unit.c:3246-3251 校验 |

常见误读:Requires= 不含 After=,也不含 BindsTo= 的"跟死"语义——文档语义全部来自 atom 的组合,而非依赖名本身;这也是 systemd 文档反复强调"After= 不会被 Requires= 隐含"的代码根源。

## 4. job 引擎:合并表、调度与收尾

### 4.1 合并语义是一张静态表

```c
// src/core/job.c:416-424
static const JobType job_merging_table[] = {
/* What \ With       *  JOB_START            JOB_VERIFY_ACTIVE JOB_STOP JOB_RELOAD */
/* JOB_VERIFY_ACTIVE */ JOB_START,
/* JOB_STOP          */ -1,                  -1,
/* JOB_RELOAD        */ JOB_RELOAD_OR_START, JOB_RELOAD,       -1,
/* JOB_RESTART       */ JOB_RESTART,         JOB_RESTART,      -1,      JOB_RESTART,
};
```

START+STOP 不可合并(-1),RESTART 兼容一切;`job_type_lookup_merge`(job.c:426-441)按下三角查表,注释证明了合并的**结合律与可传递性**(job.c:398-415)。查出的 `JOB_RELOAD_OR_START` 等状态相关类型再用 `job_type_collapse()`(job.c:482-516)按 unit 当前状态塌缩成 START/RELOAD/NOP。`job_type_is_redundant()`(job.c:443-480)决定哪些 job 可作为冗余丢弃:START 对已 active 的 unit 冗余,但 RELOAD/RESTART 永不冗余(job.c:453-472 有整段关于 ACTIVATING 状态下必须保留 RESTART 的论证)。

### 4.2 调度:run_queue + job_is_runnable + job_compare

安装后的 job 进 `m->run_queue` 优先队列(按 unit 优先级比较,manager.c:888-892;事件源 manager.c:767、2874-2906)。出队执行 `job_run_and_invalidate()`(job.c:916-995):WAITING→RUNNING,`job_is_runnable()` 检查 After/Before 邻居是否还有未完成 job(job.c:531-571),再 switch 到 `job_perform_on_unit` 调 `unit_start/stop/reload`;返回的 errno 逐个映射成 JobResult(-EALREADY→JOB_DONE、-EBADR→JOB_SKIPPED、-ENOLINK→JOB_DEPENDENCY……job.c:967-991)。排序方向由 `job_compare()` 定死:**STOP/RESTART 永远排在对方前面**(job.c:1717-1748,注释给出四种组合的两步序)。

### 4.3 收尾:job_finish_and_invalidate 的四路传播

`job_finish_and_invalidate()`(job.c:1014-1119)做四件事:RESTART 完成后改类型为 START 回 WAITING(job.c:1037-1047);失败时按 atom `PROPAGATE_START_FAILURE/PROPAGATE_STOP_FAILURE` 连坐依赖 job(job.c:1056-1061);START "成功"但 unit 实际不 active(oneshot/Condition 跳过)时按 `PROPAGATE_INACTIVE_START_AS_FAILURE` 连坐(job.c:1080-1083);最后把 After/Before 邻居的 job 重新入队,驱动下一个 job(job.c:1102-1113)。注释中提到的 `job_cascade` 职责在本基线已由 `job_is_runnable`+`job_compare` 承担,job.c 中已无该函数名。

## 5. Transaction:把依赖图折叠成一个可执行计划

入口 `manager_add_jobs()`(manager.c:2311-2431)是 D-Bus 与内部 API 共用的工厂:先按 mode 校验(isolate 只配 start 等,manager.c:2332-2345),`transaction_new()`(manager.c:2347;结构体 transaction.h:6-13 只有一个 Unit→job 链 hashmap 加 anchor 集合),对每个 anchor 调 `job_type_collapse` 后进入 `transaction_add_job_and_dependencies()`(transaction.c:1030-1258)递归展开;`JOB_ISOLATE` 再补 `transaction_add_isolate_jobs()`(transaction.c:1296-1327,`shall_stop_on_isolate` 豁免被触发者,transaction.c:1260-1294)。展开阶段按 atom 决定子 job 类型:

```c
// src/core/transaction.c:1144-1179(节选)
if (IN_SET(type, JOB_START, JOB_RESTART)) {
        UNIT_FOREACH_DEPENDENCY_SAFE(dep, job->unit, UNIT_ATOM_PULL_IN_START) {
                r = transaction_add_job_and_dependencies(tr, JOB_START, dep, job,
                                TRANSACTION_MATTERS | ..., e); ... }
        UNIT_FOREACH_DEPENDENCY_SAFE(dep, job->unit, UNIT_ATOM_PULL_IN_VERIFY) {
                r = transaction_add_job_and_dependencies(tr, JOB_VERIFY_ACTIVE, dep, job, ...); ... }
        UNIT_FOREACH_DEPENDENCY_SAFE(dep, job->unit, UNIT_ATOM_PULL_IN_STOP) {
                r = transaction_add_job_and_dependencies(tr, JOB_STOP, dep, job,
                                TRANSACTION_MATTERS | TRANSACTION_CONFLICTS | ...); ... }
```

STOP/RESTART 再经 `PROPAGATE_STOP` 传播,且"只以 TRY_RESTART 传播,以免拉起本来不在的依赖"(transaction.c:1199-1218);RELOAD 走 `transaction_add_propagate_reload_jobs()`(transaction.c:971-997);`PropagatesStopTo=` 的"优雅停"延迟到能看清整张事务图时再决定 STOP 还是 RESTART(`job_type_propagate_stop_graceful`,transaction.c:999-1028)。

### 5.1 合并:同一 unit 上多个 job 归一

`transaction_merge_jobs()`(transaction.c:321-362)三步走:先 `transaction_drop_nop`(NOP 与常规 job 撞车时丢 NOP,transaction.c:266-319),再对 matters/不 matters 两组分别 `transaction_ensure_mergeable`(transaction.c:227-264)——发现同 unit 两个 job 不可合并时,`delete_one_unmergeable_job()`(transaction.c:158-225)挑一个删:双方都不 matters 时"宁删 STOP 不删 START,除非 STOP 是被 ConflictedBy 拉的"(transaction.c:176-205);两边都 matters 则整个事务报 `BUS_ERROR_TRANSACTION_JOBS_CONFLICTING`。最后逐 unit 把链上所有 job 按 `job_type_merge_and_collapse` 归并成一个(transaction.c:341-359)。安装期还允许"晚合并":新事务撞上已在 RUNNING 的 job 时,`jobs_may_late_merge()` 禁止并入 RELOAD(防止吞掉两次 reload 之间的配置变更)但允许 RESTART(job.c:194-219)。

### 5.2 环检测:单趟 DFS + 自愈重试

`transaction_verify_order_one()`(transaction.c:412-563)沿排序边做 DFS:`j->marker` 记录来路、`j->generation` 去重(transaction.c:526-527);再访且 marker 为 NULL 说明"此子图已证明无环",直接剪枝返回(transaction.c:429-436)。找到环时,沿 marker 回溯路径打日志,并挑环上第一个"不 matters_to_anchor"的 job 所在 unit 整体删除,返回 -EAGAIN 让外层重试(transaction.c:441-512);删不动才报 `BUS_ERROR_TRANSACTION_ORDER_IS_CYCLIC`(transaction.c:514-521)。遍历只在 `job_compare(j,o,d) >= 0` 时剪枝(transaction.c:550),即按 job 执行序真实存在的"先于"边走。如实描述复杂度:`transaction_verify_order()`(transaction.c:565-584)对每个 job 作起点但共享同一 generation,已验证节点直接剪枝,单轮是带记忆化的多源 DFS,代价 O(V+E)(排序边按 Before/After 两个方向各走一遍,transaction.c:414-417、533-557);每删一个环重跑一轮,最坏 O(k·(V+E)),k 为被删环数——不是严格的 O(n²) 算法,但外层 `transaction_activate` 的两个 `for(;;)` 重试环(transaction.c:836-850、852-867)使总代价随修复次数线性增长;`CYCLIC_TRANSACTIONS_MAX=4096`(transaction.c:19、477-485)只是限制环事务的记录条数,与检测本身无关。

### 5.3 定稿与落盘

`transaction_activate()`(transaction.c:800-892)按编号注释的十步执行,主干一目了然:

```c
// src/core/transaction.c:822-848(节选)
/* First step: figure out which jobs matter. */
transaction_find_jobs_that_matter_to_anchor(tr, generation++);
/* Second step: Try not to stop any running services if we don't have to. ... */
r = transaction_minimize_impact(tr, mode, e);
...
/* Third step: Drop redundant jobs. */
transaction_drop_redundant(tr);
for (;;) {
        /* Fourth step: Let's remove unneeded jobs that might be lurking. */
        if (mode != JOB_ISOLATE)
                transaction_collect_garbage(tr);
        /* Fifth step: verify order makes sense and correct cycles if necessary and possible. */
        r = transaction_verify_order(tr, &generation, e);
        if (r >= 0)
                break;
        ...
}
```

之后是 merge 循环 → 二次 drop_redundant(transaction.c:869-870)→ is_destructive(JOB_FAIL 模式下与已安装 job 冲突即拒绝,transaction.c:618-649)→ `transaction_apply()`(transaction.c:713-798):ISOLATE/FLUSH 先清掉事务外的全部已安装 job(transaction.c:727-743),然后逐个 `job_install()` 进 `m->jobs` 并入 run_queue,失败有回滚(transaction.c:792-797)。同 unit 已有 job 时的冲突裁决其实在 `job_install()`(job.c:240-297):conflicting 则 `JOB_CANCELED` 掉旧 job,可合并则并入;`JOB_REPLACE_IRREVERSIBLY` 产生的 `irreversible` job 不允许被后续事务反向覆盖(transaction.c:631)。

## 6. 加载与默认依赖:unit 文件如何长出 Unit 对象

- **名字→Unit**:`manager_load_unit()`(manager.c:2798-2819)先 `manager_load_unit_prepare()`(manager.c:2716-2796):查重、`unit_new()`(unit.c:97,默认 `default_dependencies=true`,unit.c:109)入 load_queue;再同步 `manager_dispatch_load_queue` 清队列。
- **文件→属性**:`unit_load()`(unit.c:1688-1758)调虚表 `->load()`,service 等类型实现为 `unit_load_fragment_and_dropin()`(unit.c:1439-1479)。`unit_load_fragment()`(load-fragment.c:6196-6300)的来源优先级:transient(6203-6207)→ 按 `unit_file_build_name_map`/`unit_file_find_fragment` 在 lookup paths 里找主 fragment(6210-6226)→ 掩码检查(null 文件即 UNIT_MASKED,6247-6251)→ `config_parse` 解析(6274-6279)→ 系统实例找不到文件时回退到内置单元(6285-6295);drop-in 随后叠加,别名再经 UNIT_MERGED 合并。`[Unit]` 的依赖行统一走 `config_parse_unit_deps()`(load-fragment.c:261-316),逐词 `unit_add_dependency_by_name(..., UNIT_DEPENDENCY_FILE)`(312),ltype 就是 dep 枚举值(gperf 表绑定)。
- **加载后补齐结构依赖**:`unit_load()` 在 LOADED 后追加 `unit_add_slice_dependencies()`(slice 隐式 After+Requires,unit.c:1517-1542)与 `unit_add_mount_dependencies()`(RequiresMountsFor→.mount,unit.c:1544-)。
- **默认依赖在代码里按类型生成**,不在单元文件中:target 的 `target_add_default_dependencies()`(target.c:35-68)给所有依赖方补 `target After= u`,并让非 shutdown target `Before+Conflicts shutdown.target`(target.c:67);service 的(service.c:1114-1152)为 After+Requires sysinit.target(系统实例,1130)或 Requires basic.target(user 实例,1138)、After basic.target(1146)、Before+Conflicts shutdown.target(1151);mount 的(mount.c:492-524,extrinsic 根文件系统豁免 506)统一 `Before+Conflicts umount.target`(mount.c:451)。这些依赖都打 `UNIT_DEPENDENCY_DEFAULT` 掩码,与文件依赖(unit.h:91-126 的 9 位来源掩码)区分,便于 daemon-reload 时定向清洗。
- **停机路径**:全是普通 job——shutdown.target 启动时,Conflicts 语义经 `PULL_IN_STOP` 反向给全系统下 STOP;`job_shutdown_magic()` 识别 shutdown.target 的 START job,打停机时间戳并触发磁盘 cache 回写(job.c:1414-1444)。信号入口:SIGINT 系统实例走 ctrl-alt-del.target(2 秒 7 次则 emergency,manager.c:3270-3290),user 实例走 exit.target(manager.c:3345);目标名定义在 src/basic/special.h(umount.target:8、shutdown.target:13、exit.target:19、sysinit.target:33)。

### 6.1 daemon-reload、coldplug 与 GC:状态机的"存档/读档"

重载不影响本报告主线,但与状态机衔接紧密,值得交待三处:

- **读档**:反序列化只记录"意图回到的状态",真正生效靠虚表 `coldplug()`——unit.h:575-586 的注释写明 coldplug 必须在 manager 退出 reloading 之前调用,只复原原状、不追赶 reload 期间的外部变化(那归 `catchup()`)。`unit_coldplug()`(unit.c:3823-3848)依次处理 D-Bus track、类型 coldplug 与 job 的 `job_coldplug()`(job.c:1368-1393:WAITING 的重新入 run_queue、重建 job 计时器)。
- **递归 coldplug 陷阱**:`transaction_add_job_and_dependencies()` 开头有一处精妙处理——reloading 期间建事务时先 `unit_coldplug(unit)`(transaction.c:1048-1052),注释解释这是为了让 path_coldplug 之类在拉 job 前看到已复原的依赖状态,避免读到未 coldplug 的 unit 状态。
- **GC**:事务与 unit 都有兜底回收。job 侧 `job_may_gc()`(job.c:1477)判断无用 job,`transaction_collect_garbage()` 则在事务内删除"没有任何父 job 指向"的悬空 job(transaction.c:586-616);unit 侧 `unit_may_gc()`(unit.c:424)配合 `unit_add_to_gc_queue`(unit_notify 尾部,unit.c:2869)实现"不被任何引用且 inactive 的 unit 自动消亡",这正是默认依赖中 UNIT_REFERENCES(unit.c:3273-3278)存在的目的:被 Requires= 引用的 target 不会被 GC。

## 7. 失败传播小结

三层机制叠加:① job 层连坐——`job_fail_dependencies()` 按 `PROPAGATE_START/STOP_FAILURE` atom 把依赖方的 START/VERIFY_ACTIVE job 判 `JOB_DEPENDENCY`(job.c:997-1012、1056-1061);② 状态层——unit 真正变 FAILED 时 `unit_notify` 触发 `OnFailure=`(unit.c:2833-2834)、BindsTo 对象掉线触发 `stop_when_bound` 队列(unit.c:2890)与 `unit_verify_deps` 拒启(unit.c:1996-1997);③ 请求层——retroactively_* 在"无 job 请求的状态跳变"后补发 START/STOP job(unit.c:2313-2344)。BindsTo+After 的强绑定因此横跨 ②③ 两层:启动前静态校验,运行后事件驱动。

## 8. 设计动机

1. **为什么事务制而非即时执行**:一次 `systemctl start` 会拉起整棵依赖树,若边解析边执行,一半路径可能走到与另一请求相反的方向。事务先把整棵"想要的世界状态"物化成 job 集合,再原子裁决(合并/删冗余/环检测/破坏性检查)后一次 `job_install`,且 `transaction_apply` 带 rollback(transaction.c:792-797);同一请求内的一致性由 anchor/matters 标记保证(transaction.c:57-91)。
2. **为什么合并语义做成按 job 类型的静态表**:合并必须满足交换律、结合律、可传递性,否则"同一 unit 先收到 START 后收到 STOP"这类竞态的结果不确定。一张 10 格表 + 数学证明注释(job.c:398-424)把语义复杂度压到 O(1) 查表,新增 job 类型只需扩展表(job.h:7 的警告)。
3. **为什么环检测可接受 O(V+E)+重试**:单元依赖图在现实中极稀疏(E≈几倍 V),多源 DFS 带 generation 剪枝单轮即线性;而"含环配置"本属异常路径,删除式自愈(挑非 anchor job 删)让带小环的系统仍能启动——工程上比直接拒绝可用性高得多,记录上限 4096 只约束日志刷屏(transaction.c:19)。
4. **为什么默认依赖写在代码而非单元文件**:sysinit/basic/shutdown 的隐式耦合是"类型不变量"而非用户可自由取舍的策略;按类型在 `*_add_default_dependencies()` 中生成,可打上独立掩码 `UNIT_DEPENDENCY_DEFAULT`(unit.h:100-103)以便精准清洗,也可用 `DefaultDependencies=no` 整体关闭(unit.c:1119 等每处开头检查),并避免在数百个发行版单元文件里重复维护同一片段。
5. **为什么状态上报统一走 unit_notify**:一个 unit 的子状态变迁来源极杂(进程退出、cgroup 事件、D-Bus、timer),而每次变迁要做的横切动作有十几项(D-Bus 信号、时间戳、job 结算、audit、oomd、十来个延迟队列)。收口到一个函数(unit.c:2738)保证"任何来源的状态变化都获得完全一致的副作用集",也给了 `MANAGER_IS_RELOADING` 单一豁免点(unit.c:2765、2796)。
6. **为什么 dep 类型要拆成 atom**:Requires/Wants/BindsTo/Upholds 的行为是若干正交能力(拉起、失败连坐、绑定停机、保活)的组合。拆成位掩码后,引擎只面对 30 来个原子语义(atom 表 unit-dependency-atom.c:6-101),新增用户可见依赖类型无需改引擎;`unit_dependency_from_unique_atom()` 还能反查唯一类型做快速遍历(unit-dependency-atom.c:112-244)。

## 9. 写作素材清单(文件:行号)

1. `src/basic/unit-def.h:38-49` — UnitActiveState 八态枚举
2. `src/basic/unit-def.h:222-278` — UnitDependency 全量依赖类型
3. `src/basic/unit-def.h:289-302` — JobMode 十种(事务裁决策略)
4. `src/core/job.h:8-50` — JobType 分档(可入事务/可合并/不可入事务)
5. `src/core/job.c:416-424` — job_merging_table 合并真值表
6. `src/core/job.c:482-516` — job_type_collapse 状态相关塌缩
7. `src/core/job.c:916-995` — job_run_and_invalidate errno→JobResult 映射
8. `src/core/job.c:1014-1119` — job_finish_and_invalidate 四路传播
9. `src/core/transaction.c:1030-1258` — transaction_add_job_and_dependencies 递归展开
10. `src/core/transaction.c:800-892` — transaction_activate 十步流水线
11. `src/core/transaction.c:412-563` — 环检测 DFS 与删环自愈
12. `src/core/unit.c:2738-2900` — unit_notify 状态上报总线
13. `src/core/unit.c:2636-2696` — unit_process_job 状态→job 结算
14. `src/core/unit.c:3200-3286` — unit_add_dependency 校验与登记
15. `src/core/unit-dependency-atom.c:6-101` — dep 类型→atom 映射表
16. `src/core/load-fragment.c:6196-6300` — unit_load_fragment 来源优先级与掩码
17. `src/core/manager.c:2311-2431` — manager_add_jobs 事务工厂(D-Bus 入口 dbus-manager.c:903)
18. `src/core/service.c:1114-1152` — service 默认依赖(sysinit/basic/shutdown)

(完)
