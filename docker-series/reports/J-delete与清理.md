# J - delete 与清理:runc 如何料理容器的"后事"

> 源码:runc @ commit **579be22**(VERSION `1.5.0-rc.1+dev`)。
> 布局说明:该 commit 已把 main 包文件从旧布局 `cmd/runc/` 移到仓库根目录,本文按实际路径引用(`delete.go`、`kill.go`、`libcontainer/...`)。cgroup 管理器已拆分到独立模块 `github.com/opencontainers/cgroups`,其行号取自本仓库 `vendor/` 内的拷贝。
> 本章是卷一 04 章(`D-runc全景与创建.md`)的直接续篇:state.json 与 exec.fifo 这两个创建期写下的"活档",正是本章的清理对象。

---

## 1. 全景:容器死亡的四种方式

```
                    容器死亡的四种方式与各自的清理路径
                    =====================================

 (A) init 自然退出               (B) runc kill <id> KILL
     init 把自己 exec 成               CLI 解析信号(parseSignal)
     用户命令,命令退出                 → Container.Signal(SIGKILL)
          │                            → 私有 PID ns: 只杀 init
          ▼                            → 共享 PID ns: signalAllProcesses
     内核: init 变僵尸,                     │
     等父进程 wait 收尸                      ▼
          │                            同 (A):init 死 → stopped
          ▼
     runc 侧 refreshState(): hasInit()==false → 状态翻转为 stopped
     (container_linux.go:919-936)
          │
          ▼
     ★ 死亡 ≠ 清理 ★  此刻: cgroup 目录仍在、state.json 仍在
     必须有人跑 runc delete(或由 containerd-shim 兜底,见卷一 C)

 (C) runc delete --force         (D) OOM killer / 宿主重启
     killContainer(delete.go:17-26)   OOM: 内核直接 SIGKILL init,
     = Signal(SIGKILL)                     后果同 (A),只是 runc 毫无预知
       + 100×100ms 探活循环           重启: /run 是 tmpfs → state 目录
       + container.Destroy()               随之蒸发;cgroup 树同样不持久
                                       下次对同 ID 操作: Load 报 ErrNotExist
```

四条路的终点是一致的:**资源清理只有 `destroy()` 一条路**(libcontainer/state_linux.go:39),差异只在"谁触发、何时触发"。runc 没有任何后台 reaper/监视线程——它是一个一次性 CLI,退出即消失,清理责任明确交给了调用方。

`stopped` 是"运行时判定"而非"持久化字段":每次 `runc list`/`delete` 都会重新看一眼 `/proc`。`refreshState()`(libcontainer/container_linux.go:919-936)的判定顺序是:

1. cgroup freezer 处于 Frozen → `paused`(container_linux.go:920-926);
2. `hasInit()` 为假(init 进程没了)→ `stopped`(container_linux.go:927-929);
3. state 目录里 **exec.fifo 还在** → `created`(container_linux.go:930-934);
4. 否则 → `running`(container_linux.go:935)。

也就是说:**exec.fifo 的存在性就是 Created/Running 的分界线**(卷一 04 章的伏笔在此兑现)。init 死亡的判定 `hasInit()`(container_linux.go:939-952)不只查 PID 存在,还校验 `/proc/<pid>/stat` 的 starttime 与 state.json 记录一致、且进程不是 Zombie/Dead(container_linux.go:948)——这是防 PID 复用误判的关键。

## 2. delete 专节:两步走 kill+destroy,以及严格的顺序

### 2.1 CLI 层(delete.go)

`runc delete` 的 Action(delete.go:50-92)分四种情形:

```go
// delete.go:80-91
s, err := container.Status()
...
switch s {
case libcontainer.Stopped:
        return container.Destroy()
case libcontainer.Created:
        return killContainer(container)
default:
        return fmt.Errorf("cannot delete container %s that is not stopped: %s", id, s)
}
```

- **容器对象都不存在**(`Load` 返回 `ErrNotExist`,delete.go:57-71):说明 state.json 从未写成(如 create 中途夭折),但 `--root` 下可能残留以 ID 命名的空目录,直接 `os.RemoveAll` 兜底(delete.go:62-65)。能走到这一分支说明 ID 已通过 `validateID` 校验(factory_linux.go:113-115 先于路径拼接执行),不存在路径穿越问题。
- **Stopped**:直接 `container.Destroy()`(delete.go:85-86)。
- **Created**:走 `killContainer`(delete.go:87-88)——created 容器的 init 还没 exec,先杀了再清。
- **Running/Paused**:拒绝,报 "cannot delete ... that is not stopped"(delete.go:89-90)。Paused 尤其特殊:状态机要求先 Resume 才能销毁(state_linux.go:186-194)。

### 2.2 --force:kill 之后才许 delete

```go
// delete.go:17-26
func killContainer(container *libcontainer.Container) error {
        _ = container.Signal(unix.SIGKILL)
        for range 100 {
                time.Sleep(100 * time.Millisecond)
                if err := container.Signal(unix.Signal(0)); err != nil {
                        return container.Destroy()
                }
        }
        return errors.New("container init still running")
}
```

三个细节:其一,SIGKILL 发出后 **主动轮询等待内核把进程真正收走**(最多 10 秒),`Signal(0)` 是探活;其二,轮询失败并不强删,返回错误让上层决定——因为 init 未死时 rmdir cgroup 会 EBUSY、进程还占着资源;其三,`--force` 时**即便容器已 stopped 也照杀不误**(delete.go:72-79),注释写明原因:共享 PID namespace 的容器里,init 死后 cgroup 中可能还留着别的进程。

`--force` 的分派(delete.go:77-79)直接 `return killContainer(container)`,跳过 Status 检查——这就是"kill+delete 两步合一"的语义。

### 2.3 destroy() 的固定顺序(state_linux.go:39-67)

`Destroy()` 本身很薄:拿互斥锁、调 `c.state.destroy()`(container_linux.go:795-802)。真正的顺序在 `destroy()`:

```go
// libcontainer/state_linux.go:39-67(节选)
func destroy(c *Container) error {
        if !c.config.Namespaces.IsPrivate(configs.NEWPID) {
                _ = signalAllProcesses(c.cgroupManager, unix.SIGKILL)   // ① 共享 PID ns:杀残留进程
        }
        if err := c.cgroupManager.Destroy(); err != nil {               // ② 删 cgroup
                return fmt.Errorf("unable to remove container's cgroup: %w", err)
        }
        if c.intelRdtManager != nil { ... }                             // ③ 删 resctrl 组
        if err := os.RemoveAll(c.stateDir); err != nil {                // ④ 删状态目录
                return fmt.Errorf("unable to remove container state dir: %w", err)
        }
        c.initProcess = nil
        err := runPoststopHooks(c)                                      // ⑤ poststop 钩子
        c.state = &stoppedState{c: c}
        return err
}
```

顺序是精心设计的:**先杀进程 → 再删 cgroup → 最后删状态目录**。反了就会出事:先删 state.json,`Load` 报 ErrNotExist,残留 cgroup 成了无人认领的孤儿。② 失败则函数提前返回,④ 不会执行——状态目录保留,等用户排查后重试 delete,这是"墓碑比坟场重要"的取舍。

destroy 的入口还按状态分派(state_linux.go,状态机五态各有 destroy):

| 状态 | 行号 | 行为 |
|---|---|---|
| stoppedState | state_linux.go:104-106 | 直接 destroy |
| runningState | state_linux.go:134-139 | `hasInit()` 为真则 `ErrRunning` |
| createdState | state_linux.go:160-163 | **先对 init 发 SIGKILL** 再 destroy |
| pausedState | state_linux.go:186-194 | 有 init 报 `ErrPaused`;否则先 Thaw 再 destroy |
| restoredState | state_linux.go:215-222 | 检查 checkpoint 目录后 destroy |
| loadedState | state_linux.go:240-245 | `Load` 出来的容器:先 `refreshState` 再按真实状态重新分派 |

注意 factory_linux.go:143-144:`Load` 构造的容器初始态是 `loadedState`,其 destroy 不直接干活,而是刷新后**委托**给真实状态——保证跨进程调用的 delete 永远基于最新的运行时事实。

## 3. kill 专节:信号路由的三岔口

`runc kill`(kill.go:15-67)默认发 SIGTERM(kill.go:52-55),经 `parseSignal`(kill.go:69-83)支持数字与 `KILL`/`SIGKILL` 两种写法。曾经有 `--all` 选项向 cgroup 内所有进程发信号,如今已标记废弃隐藏(kill.go:32-39),仅在 `ErrNotRunning` 时吞错(kill.go:62-64)——**OCI 的 kill 语义就是"发给容器 init"**。

信号路由的核心在 `Container.signal`(container_linux.go:444-471):

```go
// libcontainer/container_linux.go:452-470(节选)
if s == unix.SIGKILL && !c.config.Namespaces.IsPrivate(configs.NEWPID) {
        if err := signalAllProcesses(c.cgroupManager, unix.SIGKILL); err != nil {
                ...
        }
        return nil
}
return c.signalInit(s)
```

三岔口:

1. **普通信号**(SIGTERM 等)→ `signalInit`:只发给 init 进程 PID(container_linux.go:473-490)。init 怎么处置转发、子进程怎么死,是容器内 init(或 tini 之类)的事。
2. **SIGKILL + 私有 PID namespace** → 仍走 `signalInit`,但依赖内核语义:从祖先 namespace 杀 PID 1,内核会连带杀掉该 PID ns 里**所有**进程(注释引 pid_namespaces(7),container_linux.go:445-448)。
3. **SIGKILL + 共享 PID namespace** → `signalAllProcesses`:必须逐个杀,否则残留进程成为脱离管理的孤儿(container_linux.go:450-451)。

`signalInit` 的两处防御:发信号前 `hasInit()` 检查,容器不在运行直接 `ErrNotRunning`,避免 PID 复用后把信号发进无关进程(container_linux.go:474-477);SIGKILL 且 cgroup 处于冻结态时顺手 **Thaw**——cgroup v1 下冻结中的进程收不到任何信号,不 thaw 的 SIGKILL 等于无效操作(container_linux.go:481-488)。

`signalAllProcesses`(libcontainer/init_linux.go:684-720)自身也有快慢两条路:优先写 **`cgroup.kill` = 1**(内核 5.14+,原子性杀光整棵子树,init_linux.go:688-697);失败(ENOENT 才回退)则老三样——先 Freeze 防止进程边杀边 fork,`GetAllPids` 逐个 `kill`,最后 Thaw(init_linux.go:699-717)。

至于"SIGKILL 不可拦截":那是内核保证(默认 handler、不可捕获不可忽略),runc 无需做任何事——这也是 --force 敢直接上 SIGKILL 的底气。B 章讲过的 `runc run` 前台信号转发(handler.forward,utils_linux.go:324-326)只在非 detach 模式生效,与本节的 kill 命令是两条独立通道。

## 4. cgroup 清理专节:v2 目录删除与非空难题

三个 manager 的 Destroy 各有分工(分派逻辑见 vendor/github.com/opencontainers/cgroups/manager/new.go:17-51):

**cgroup v2(fs2)**最简单:一行 `RemovePath(m.dirPath)`(vendor/github.com/opencontainers/cgroups/fs2/fs2.go:205-207)。真正的学问在 `RemovePath`(vendor/github.com/opencontainers/cgroups/utils.go:254-288):

```go
// vendor/.../cgroups/utils.go:254-288(节选)
func RemovePath(path string) error {
        if err := rmdir(path, false); err == nil {   // 快路径
                return nil
        }
        // rmdir 失败三可能: 1.有子 cgroup; 2.还有进程(将很快消失); 3.权限(EROFS)
        infos, err := os.ReadDir(path)
        ...
        for _, info := range infos {                 // 递归删子组
                if info.IsDir() {
                        if err = RemovePath(filepath.Join(path, info.Name())); err != nil {
```

"目录非空"的两种成因、两种对策:**僵尸子组**(比如用户手动 `runc exec` 之外的进程自建的子 cgroup)用递归 `RemovePath` 逐层 rmdir(utils.go:277-284);**进程尚未死透**导致的 EBUSY,由 `rmdir(path, true)` 的重试消化——最多 10 次、1ms 起指数退避(utils.go:229-249)。这就是 2.3 节"先杀进程再删 cgroup"顺序的下游配合:SIGKILL 后进程消失需要一点时间,EBUSY 退避刚好覆盖这个窗口。目录已不存在(ENOENT)按成功处理(utils.go:272-274),使 delete 幂等。

**systemd 驱动(v2)**:`UnifiedManager.Destroy`(vendor/.../cgroups/systemd/v2.go:426-443)两步——先 `stopUnit` 走 D-Bus 停掉 `runc-<id>.scope` 单元,再补一刀 `m.fsMgr.Destroy()` 删子 cgroup,注释点名原因:**systemd 239 不会移除子 cgroup**(v2.go:435-437)。`stopUnit`(vendor/.../cgroups/systemd/common.go:184-210)用 `StopUnitContext("replace")` 并等 Job 完成,30 秒超时报错;收尾无论成败都调 `resetFailedUnit`,防止单元卡在 failed 状态赖着不删(common.go:206-207)。

**v1 各路**:纯 cgroupfs 的 `fs.Manager.Destroy` 对 v1 的多个层级逐个 `RemovePaths`(vendor/.../cgroups/fs/fs.go:174-178;utils.go:291-302),删不干净的路径汇总报错;systemd v1 混合模式(legacy)先 stopUnit 再 `RemovePaths(m.paths)`,因为 `Apply()` 阶段有些层级是绕过 systemd 直接建的(systemd/v1.go:248-262)。

**Intel RDT**:`intelRdtManager.Destroy`(libcontainer/intelrdt/intelrdt.go:470 起)只在 closid 未显式指定、且目录确为自己所建时才 `os.Remove` resctrl 目录——外部管理的组不能碰。

## 5. 僵尸容器专节:谁负责收尸

"僵尸容器"要拆成两层,收尸人不同:

**第一层:进程僵尸**(内核语义)。init 死后变 Z,等父进程 `wait()`。runc 的答案分散在三处:前台 `runc run` 自己就是父进程,`handler.forward` 返回前会 wait;`runc run/create` 默认把自己设为 **child subreaper**(`PR_SET_CHILD_SUBREAPER`,utils_linux.go:264-269),接管中途被 reparent 的孙进程;而库使用者则被文档明确提醒——共享 PID ns 下 SIGKILL 会杀掉全部进程,"libcontainer 的使用者需要实现一个合适的 child reaper"(container_linux.go:433-437)。`runc create` + detach 的场景下,init 的父进程是创建它的那个 `runc` 进程,它退出后子进程上交 subreaper;这正是 containerd-shim 作为常驻 subreaper 存在的理由(卷一 C 章的 shim 进程模型,与本章互为印证)。

**第二层:资源僵尸**(runc 语义)。init 死透后,cgroup 目录、state 目录(含 state.json)**原样留在磁盘上**,`runc list` 会一直显示这个 status=stopped、pid=0 的条目(list.go:156-175,stopped 时 pid 置 0 在 list.go:166-169)——直到有人执行 `runc delete`。谁有义务来删?

- **前台 `runc run`**:runner 自带清理,非 detach(或任何出错)路径 `defer r.destroy()`(utils_linux.go:223-231,329-335),init 退出瞬间容器即被销毁。`--keep` 可关闭(`shouldDestroy: !cmd.Bool("keep")`,utils_linux.go:418;run.go:51-54),供事后尸检。
- **`runc create` + `start` 的 detach 模式**:runc 进程早已退出,**没人能自动跑 delete**。OCI 生命周期把 delete 定义为显式步骤,清理由上层 runtime 负责——containerd-shim 在收到 task 的 exit 事件后执行等价于 delete 的清理(shim delete),这就是卷一 C 章"shim 是任务监护人"的资源侧呼应。shim 若也死了(如 kill -9),资源僵尸落地,只能靠人工 `runc delete` 或清理工具。
- **宿主重启**:/run 是 tmpfs,state 目录蒸发;cgroup 树同样不持久。runc 无需处理此场景,反而受益:残留自动清零。唯一例外是 create 中途夭折留下的空 ID 目录,`delete` 的 ErrNotExist 分支会 `RemoveAll`(delete.go:59-69)。

## 6. 设计动机:为什么清理长这样

**delete 为什么是显式命令?** OCI runtime 生命周期把 create/start/kill/delete 做成四个正交动词:F-OCI 章的规范视角之外,工程上还有一个理由——runc 是无守护进程的 CLI,**它没有"容器死了"的通知渠道**。要么前台阻塞等到 init 退出(顺带清理),要么把责任移交给一个有通知渠道的常驻进程(shim)。让"观察者"负责清理,而不是让每个 API 调用者猜,这是职责的最小化。

**--force 为什么是两步(kill+等+delete)而不是一步 rm?** 因为 cgroup 目录的删除由内核把关:组内有进程时 rmdir 返回 EBUSY。硬闯没有意义,`killContainer` 的 100×100ms 探活循环(delete.go:19-24)是给内核收尸留时间;探活失败宁可报错退出,保住状态目录这个"事故现场"。

**状态目录为什么放 /run?** 生命周期对齐:tmpfs 随重启清空,容器状态天然不会跨启动残留;main.go:120-125 的 flag 帮助文本直说 "should be located in tmpfs"。rootless 模式换用 `$XDG_RUNTIME_DIR/runc`(main.go:98-103),并且按 XDG 规范给目录加 **sticky bit** 防 systemd-tmpfiles 的自动清扫(main.go:154-162 的注释)。state 目录本身 `0o711`(factory_linux.go:91),仅 root 可列目录内容。

**清理为什么敢不加全局锁?** 全仓库(不含 vendor)grep 不到任何 flock:并发防护靠三层——进程内 `sync.Mutex`(container_linux.go:41);state.json 的原子替换(`CreateTemp` 写临时文件后 `rename`,container_linux.go:882-906),读方永远看到完整文件;以及**跨进程不信任磁盘状态、每次决策前 refreshState/hasInit 复核运行时事实**。两个并发 delete 最坏情形是都调 `RemoveAll`/`RemovePath`,而两者对 ENOENT 幂等,天然收敛。

## 7. FAQ 素材

1. **`runc kill` 只发给 init 吗?** 是。默认与唯一正式语义都是发给 init(kill.go:17);`--all` 已废弃隐藏(kill.go:32-39)。唯一例外:SIGKILL 且共享 PID ns 时改为对 cgroup 全员开火(container_linux.go:452-468)。
2. **容器退出后为什么 `runc list` 还能看到它?** state 目录还在,Status 是运行时判定的 stopped,pid 显示 0(list.go:166-169)。`runc delete` 后条目才消失。
3. **`runc delete` 报 "cannot delete ... not stopped"?** 容器还在 Running;先 `runc kill` 等退出再 delete,或直接 `delete --force`。
4. **`delete --force` 对 stopped 容器为什么还要发 SIGKILL?** 共享 PID ns 的容器 init 死后 cgroup 里可能有残留进程,delete.go:72-76 的注释明说了这一点。
5. **exec.fifo 何时被删?** 三个时机:`runc start` 消费到 init 写入的字节后立即删(container_linux.go:262);create 流程中途失败时删(container_linux.go:382-386);delete 时随 stateDir 整体 `RemoveAll`(state_linux.go:60)。停在 created 状态的容器,fifo 会一直留着——这正是 refreshState 判定 created 的依据(container_linux.go:932)。
6. **cgroup 目录删不掉会怎样?** RemovePath 递归删子组 + EBUSY 指数退避(utils.go:254-288、229-249);最终失败则 destroy 提前返回,**state 目录保留**可重试(state_linux.go:52-54 早于 60)。
7. **systemd-cgroup 模式删除超时?** stopUnit 等 Job 最多 30s(common.go:191-203),超时后还会 resetFailedUnit 兜底(common.go:206-207);systemd 239 的子 cgroup 不随单元删除,需 fsMgr.Destroy 补删(v2.go:435-437)。
8. **init 死了变僵尸谁 wait?** 前台 run 是 runc 自己;`runc run/create` 默认设 subreaper(utils_linux.go:264-269);detach 场景由 shim 作为常驻 subreaper 兜底(卷一 C 章);库文档明确要求使用者自备 reaper(container_linux.go:433-437)。
9. **宿主重启后残留怎么办?** 无残留:/run 与 cgroup 树都在 tmpfs,重启即清。同 ID 重建时若撞上残留空目录,create 会报 ErrExist(factory_linux.go:52-56),delete 一次即清。
10. **PID 复用了 kill 会不会误伤?** hasInit 用 starttime 比对 + Zombie/Dead 检查(container_linux.go:948),PID 相同但进程是"新生的"也返回 ErrNotRunning,拒绝发信号(container_linux.go:474-477)。

## 8. 深挖选题

1. **`cgroup.kill` 快路径 vs freeze+逐杀**:init_linux.go:688-717 两条路径的正确性论证(为什么 freeze 能防 fork 竞态、cgroup.kill 为何原子),可引内核 5.14 commit。
2. **createdState.destroy 为何先 SIGKILL 再 destroy**(state_linux.go:160-163):created 容器的 init 尚未 exec,不杀直接删 cgroup 会让 init 携带特权 fd 继续跑——可与 CVE-2024-21626 的 fd 泄漏防护(container_linux.go:396-404)串成安全线。
3. **无锁并发模型**:从 saveState 的 rename 原子性(container_linux.go:882-906)到 loadedState 的 refresh-再分派(state_linux.go:240-245),论证"文件系统语义替代锁"的适用边界。
4. **EBUSY 退避与内核 rmdir 语义**:RemovePath 的三场景注释(utils.go:260-265)与 rmdir 重试参数(utils.go:229-249)能否证明最终一致?失败模式的用户可见后果是什么?
5. **--force 的杀漏风险**:rootless cgroups 下 signalAllProcesses 失败降级 signalInit(container_linux.go:454-459),上游 PR #4395 的讨论——委托不足时进程可能泄漏。

## 9. 写作要点速查表

| # | 函数/位置 | 行号 | 一句话 |
|---|---|---|---|
| 1 | delete.go `killContainer` | delete.go:17-26 | SIGKILL+100×100ms 探活+Destroy |
| 2 | delete.go Action(--force/状态分派) | delete.go:57-91 | ErrNotExist 兜底;Stopped/Created 分流 |
| 3 | kill.go Action(parseSignal) | kill.go:52-61,69-83 | 默认 SIGTERM,只发 init |
| 4 | `Container.signal` 路由 | container_linux.go:444-471 | SIGKILL+共享 PID ns→杀全员 |
| 5 | `signalInit`(hasInit/Thaw) | container_linux.go:473-490 | 防 PID 复用;冻结时 thaw |
| 6 | `destroy()` 固定顺序 | state_linux.go:39-67 | 杀残留→cgroup→intelrdt→stateDir→hooks |
| 7 | 状态机五态 destroy 分派 | state_linux.go:104-106,134-139,160-163,186-194,240-245 | 各态准入规则 |
| 8 | `signalAllProcesses` | init_linux.go:684-720 | cgroup.kill 快路径;freeze+逐杀回退 |
| 9 | `refreshState`/`hasInit` | container_linux.go:919-936/939-952 | fifo 分 created/running;starttime 防复用 |
| 10 | exec.fifo 生命周期 | container_linux.go:379-386(建)/262(删)/492-521 | Created 判据兼清理对象 |
| 11 | `Destroy()`(加锁入口) | container_linux.go:795-802 | mutex+state.destroy |
| 12 | Create/Load/loadState | factory_linux.go:35-103/108-148/150-172 | stateDir 0o711;ErrNotExist 源头 |
| 13 | runner 自清理(--keep) | utils_linux.go:223-231,329-335,418;run.go:51-54 | 前台 run 退出即销毁 |
| 14 | subreaper 设置 | utils_linux.go:264-269 | PR_SET_CHILD_SUBREAPER 收尸准备 |
| 15 | --root 默认与 tmpfs 要求 | main.go:98-103,120-125,154-162 | /run/runc;XDG+sticky |
| 16 | fs2 Destroy→RemovePath/rmdir | vendor fs2/fs2.go:205-207;utils.go:254-288,229-249 | 递归子组+EBUSY 退避 |
| 17 | systemd Destroy/stopUnit | vendor systemd/v2.go:426-443;common.go:184-210 | 30s 等待;resetFailedUnit;补删子组 |
| 18 | v1 fs/systemd Destroy | vendor fs/fs.go:174-178;systemd/v1.go:248-262 | RemovePaths 多层级清理 |

*(行号均核对自 commit 579be22 的工作树;vendor/ 路径行号属 opencontainers/cgroups v0.1.0。)*
