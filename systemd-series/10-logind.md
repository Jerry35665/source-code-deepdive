# 第 10 章 · logind:会话、seat 与电源策略(卷二)

> 基线:commit `1f66b524`。核心:src/login/。世代交替:v258 起 session 追踪的 FIFO 已被 pidfd 取代(inhibitor 的 FIFO 仍在);CreateSession 有了 Varlink 版且 pam_systemd 优先走它。

## 10.0 全景:四层对象与 cgroup 树

```
logind 对象:User(uid)→Seat("seat0")→Session(c1,VT2)→Device(drm/input)
                          ↓ 映射到 PID 1 的 cgroup 树
user.slice ─ user-1000.slice ─ user@1000.service + user-runtime-dir@1000.service
                              └ session-c1.scope(StartTransientUnit 创建,
                                 领头进程以 PID/PIDFD 属性直接入组——不是事后搬运)
主循环三步:manager_gc 回收→检查 delay 型 inhibitor 到点→sd_event_run 阻塞
```

两套 API 分工:D-Bus org.freedesktop.login1 管全部控制面与信号;Varlink io.systemd.Login 只提供 CreateSession/ReleaseSession 与只读 List*,要求特权对端+强制 pidfd(防 PID 复用)。

## 10.1 session 生命周期

CreateSession:拒绝已在会话中的进程/被占用的 VT/超上限;会话 ID 优先复用 audit ID;按身份降级会话类(root TTY 升 USER_EARLY,图形保持 USER,否则 USER_LIGHT);首个"钉住"类会话把用户 GC 模式切成 USER_GC_BY_PIN——手动拉起的 user@.service 不会阻止用户最后退场。scope 属性:Slice=user-1000.slice、SendSIGHUP=true(bash 忽略 SIGTERM)、OOMPolicy=continue。退出:leader pidfd 事件感知死亡→ReleaseSession 仅允许会话自揭→session_release 装 20s 定时器→**AbandonScope**(告诉 PID 1 剩余进程是遗留物并记杀进程日志)→按 KillUserProcesses 决定是否杀 cgroup。

## 10.2 user 与 linger

user_start 顺序精心安排:先把 state 文件写盘(pam_systemd 稍后读它回填 XDG_RUNTIME_DIR)→调 slice 资源限制→启动 user-runtime-dir@(挂 tmpfs 到 /run/user/<uid>)→有条件启动 user@(只有存在需要服务管理器的会话或开了 linger)。停止只显式停 runtime-dir——user@.service 靠 BindsTo= 跟着退场,logind 不维护它的状态机。GC 三段:有无 pinning 会话→最后会话关闭后留 10s→linger 用户若三个单位都死了也照样回收。linger 标志就是 /var/lib/systemd/linger/ 下一个文件。

## 10.3 seat 与 VT

seat 由 udev 驱动:带 master-of-seat tag 的设备出现才建 seat(从无到有发 CanGraphical)。seat0 是唯一有 VT 的 seat(以能否打开 /sys/class/tty/tty0/active 判定);**VT 待命 watch 就是这个文件的 fd**——内核前台 VT 一变即触发,换算 VTnr 选活跃会话并按需拉 autovt@getty。图形会话走 VT_PROCESS 同步:收到 SIGRTMIN 切换请求时先暂停设备再确认;多 seat(无 VT)由 logind 用 pending_switch+设备暂停协议自行调度。会话激活完成时对 seat 设备触发 uevent 让 udev 改 ACL,必要时恢复同会话设备防黑屏。

## 10.4 按钮与 inhibitor

电源键/盖子是 input 设备的 evdev 事件;盖子不是边沿事件——EVIOCGSW 读初始状态,盖着时挂 post 事件源反复复查;动作按"扩展坞/外接电源"三分;**盖子有 30s holdoff**(开机/唤醒后忽略)。统一动作机 manager_handle_action:查表得 target/polkit/inhibit 位;block 型 inhibitor 直接拒绝并指认 blocker;delay 型先广播 PrepareForShutdown、挂 5s 定时器延后。**inhibitor 的抑制期=进程存活期**:Inhibit 调用返回 FIFO 写端 fd,进程退出 fd 关闭读端见 EOF,inhibitor 即刻消失——liveness 委托给内核,无需引用计数。分级(block/block-weak/delay)是查询期过滤而非存储期分类。

## 10.5 设计动机

1. **每会话一个 scope 而非 service**:会话不是被 PID 1"管理"的单元;AbandonScope 语义天然契合"杀或不杀残留"的策略分叉;
2. **FIFO 通知 liveness**:写端关闭即 EOF;pidfd 换代是因为它还答"是谁"而不只"死没死";
3. **inhibitor 分级**:把"能否阻止"与"能阻止多久"解耦,避免单一语义要么全挡要么全放;
4. **seat 抽象**:多显卡整机与单 VT 笔记本用同一套代码——有 VT 借内核调度,无 VT 自己实现 pending_switch;
5. **user manager 独立进程**:按用户横切出非特权管理边界;logind 只需 StartUnit/StopUnit 两个动词;
6. **状态文件+fdstore 双轨**:/run 的 env 文件人可读可审计,fdstore 传回 pidfd/设备 fd——logind 成为可随时重启的无状态守护进程。

## 10.6 FAQ

**Q1:会话 scope 是 logind 搬进程进去的吗?**
不是:leader 以 PID/PIDFD 属性写进 transient unit 直接入组;AttachProcessesToUnit 是 user manager 的 Delegate 链路。

**Q2:用户还开着进程时 user@ 会被 GC 吗?**
不会:pinning 会话挡住;全关后再留 10s。

**Q3:VT 切换怎么通知图形会话?**
VT_PROCESS 信号:logind 先暂停会话设备再应答内核;完成后触发 uevent 改 ACL。

**Q4:合盖动作有几种判定?**
三分:扩展坞/外接电源/默认,配置独立;30s holdoff 防开机误触。

**Q5: inhibitors 重启后还在吗?**
state 文件冷插恢复,FIFO 两端重开;对端已死的孤儿直接回收。

**Q6:idle 怎么判定?**
图形会话由合成器显式 SetIdleHint;TTY 会话读 TTY 的 atime;全局要求无 IDLE 抑制。

**Q7:挂起是谁写 /sys/power/state?**
systemd-sleep(target 拉起的独立可执行);logind 只 StartUnit"点菜"并做 sleep_supported 检查。

**Q8:logind 重启会断会话吗?**
不会:scope 在 PID 1 名下;fdstore 里的 pidfd/设备 fd 按名归位重新接管。

**Q9:PAM 怎么调 logind?**
优先 Varlink(特权+pidfd),失败回退 D-Bus;两路汇入同一 CreateSession。

**Q10:无 VT 的 seat 怎么切会话?**
pending_switch+暂停全部会话设备等控制器确认,全 asleep 即切换。

## 10.7 小结与深挖方向

本章结论:**logind="scope 归置+FIFO/pidfd 存活语义+inhibitor 分级+seat 抽象+无状态重启"**。深挖:

1. session_load 的 pidfd id 校验防 PID 复用;
2. TakeControl 独占与 SessionDevice 的 drmSetMaster;
3. idle_action 的 edge 状态防重复触发;
4. RemoveIPC 清理 POSIX/SysV IPC 的排除名单;
5. systemd-pcrlogin@(TPM 量测)与会话的关系。
