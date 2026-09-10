# Nginx 启动与进程模型(源码深读)

> 调研基线:Nginx 1.31.5 主干,commit 231a60ee(2026-09-02)。
> 本卷聚焦:src/core/nginx.c、src/core/ngx_cycle.c、src/os/unix/ngx_process.c、src/os/unix/ngx_process_cycle.c、src/os/unix/ngx_daemon.c,并旁及 ngx_module.c、ngx_connection.c、ngx_posix_init.c。所有结论均标注 `文件:行号`。

## 1. 全景

Nginx 的进程模型是一个"经典三件套":

- **master 进程**:以 root 运行,持有所有 listening socket,负责解析配置、fork/监管 worker、响应信号、执行平滑升级。它不处理任何连接,主循环是 `for(;;) sigsuspend()`(ngx_process_cycle.c:139-163),完全由信号驱动。
- **worker 进程**:master 的子进程,以 `user` 指令指定的低权限用户运行(ngx_process_cycle.c:833-863),执行 `ngx_process_events_and_timers` 事件循环,实际承载连接。worker 之间是"无共享"的:每个 worker 独立处理全量监听端口的连接(通过 accept mutex 或 SO_REUSEPORT/EPOLLEXCLUSIVE 竞争,ngx_event.c:647-659)。
- **cache manager / cache loader**:仅当配置了 proxy_cache/fastcgi_cache 等带 manager/loader 的 path 时才 fork(ngx_process_cycle.c:374-414)。manager 常驻清理缓存,loader 只在启动后 60 秒做一次索引然后 `exit(0)`(ngx_process_cycle.c:63-65, 1230),且不 respawn。

贯穿三者的是两个核心数据结构:**ngx_cycle_t**(一"代"运行时配置的总持,含 listening、open_files、shared_memory、conf_ctx)和 **ngx_processes[]**(进程表,1024 槽位,ngx_process.h:36,47)。每次 reload 都构造一个新 cycle,成功后替换全局 `ngx_cycle`,旧 cycle 延迟 30 秒回收(ngx_cycle.c:792-828)。

## 2. main() 到 master 循环:完整启动流程

```
main (nginx.c:199)
 │
 ├─ ngx_debug_init / ngx_strerror_init            (nginx.c:209-213)
 ├─ ngx_get_options: 解析 -p/-e/-c/-g/-s/-t/-T/-q/-v/-V
 │    └─ -s stop|quit|reopen|reload → ngx_process = NGX_PROCESS_SIGNALLER
 │                                                   (nginx.c:946-951)
 ├─ ngx_max_sockets = -1  /* TODO, STUB */        (nginx.c:227)
 ├─ ngx_time_init / ngx_regex_init(PCRE)          (nginx.c:229-233)
 ├─ ngx_pid = getpid(); ngx_parent = getppid()    (nginx.c:235-236)
 ├─ ngx_log_init: 打开初始 error log(失败退回 stderr)(nginx.c:238; ngx_log.c:317-398)
 ├─ init_cycle: 1KB 池 + log,挂到全局 ngx_cycle   (nginx.c:253-260)
 ├─ ngx_save_argv: 拷贝 argv(供 setproctitle/二次 exec)(nginx.c:262; 991-1030)
 ├─ ngx_process_options: prefix / conf_file / error_log (nginx.c:266; 1033-1134)
 ├─ ngx_os_init: setproctitle 迁移、pagesize、ncpu、
 │    getrlimit(RLIMIT_NOFILE) → ngx_max_sockets   (nginx.c:270; ngx_posix_init.c:34-98)
 ├─ ngx_crc32_table_init / ngx_slab_sizes_init    (nginx.c:278-286)
 ├─ ngx_add_inherited_sockets: 解析 $NGINX env 的
 │    "fd;fd;..."(平滑升级继承)                  (nginx.c:288; 477-534)
 ├─ ngx_preinit_modules: 静态模块数组编号          (nginx.c:292; ngx_module.c:25-39)
 ├─ ngx_init_cycle(&init_cycle) ←── ★ 核心,见下  (nginx.c:296; ngx_cycle.c:38-954)
 ├─ [-t/-T 在此出口; -s 在此读 pidfile 发信号退出] (nginx.c:306-334)
 ├─ ngx_init_signals(sigaction,daemon 之前!)     (nginx.c:348; ngx_process.c:284-315)
 ├─ ngx_daemon(): fork→setsid→/dev/null          (nginx.c:352-358; ngx_daemon.c:12-71)
 ├─ ngx_create_pidfile(此后才写 pid,含 daemon 后的 pid)(nginx.c:378; ngx_cycle.c:1031-1076)
 ├─ ngx_log_redirect_stderr + 关闭内置 log fd     (nginx.c:382-393)
 └─ ccf->master ? ngx_master_process_cycle       (nginx.c:342-344, 395-400)
              : ngx_single_process_cycle
```

`ngx_init_cycle` 内部(ngx_cycle.c:38-954),它同时服务于三种场景:首次启动、`-t` 测试、reload:

1. **池与元信息**:创建 `NGX_CYCLE_POOL_SIZE` 池,从 old_cycle 拷贝 prefix/conf_file/error_log/hostname(ngx_cycle.c:69-124, 207-224)。
2. **模块 conf 骨架**:`ngx_cycle_modules` 把静态模块表拷入 cycle;对 `NGX_CORE_MODULE` 类型调用 `create_conf`(ngx_cycle.c:227-248)。
3. **配置解析**:先 `ngx_conf_param` 吃掉 `-g` 参数,再 `ngx_conf_parse` 解析主配置文件(ngx_cycle.c:280-290)。解析前保存 `senv = environ`,失败路径恢复(ngx_cycle.c:251, 281)——因为 `env`/`load_module` 指令可能改写 environ。解析成功后对 core 模块调 `init_conf`(ngx_cycle.c:297-314)。
4. **SIGNALLER 早退**:`-s` 模式走到这里就带着配置上下文返回了(ngx_cycle.c:316-318),后面打开文件、监听、共享内存一概不做——这保证了 `-s` 与运行中的 master 使用相同的 prefix/配置定位 pid 文件。
5. **pid 文件**:init_cycle(首次启动)阶段刻意不写,注释直言"because we need to write the demonized process pid"(ngx_cycle.c:328-333);reload 时若 pid 路径变了则写新删旧(ngx_cycle.c:335-348)。
6. **open_files**:遍历配置期登记的文件(日志等),以 APPEND 方式打开并 `fcntl(FD_CLOEXEC)`——日志类 fd 不允许被 exec 泄漏给新二进制(ngx_cycle.c:367-409)。
7. **共享内存**:新 zone 与 old_cycle 按 name+tag+size 匹配则复用旧映射地址、用旧 data 调 init(零拷贝热升级),否则 `ngx_shm_alloc` + slab 初始化 + 锁(ngx_cycle.c:417-508; 965-1028)。
8. **listening 差分**:新配置与 old_cycle 的监听逐一 `ngx_cmp_sockaddr`,相同则**直接继承旧 fd**(`nls[n].fd = ls[i].fd`),并处理 protocol/backlog/deferred accept/reuseport 变化标记(ngx_cycle.c:513-612);不匹配的才走 `ngx_open_listening_sockets` 的 socket/bind/listen(带 5 次重试,ngx_cycle.c:632-634; ngx_connection.c:444)。这是 reload 不间断服务的关键。
9. **init_module 回调**:`ngx_init_modules` 遍历执行所有模块的 `init_module`(ngx_cycle.c:649-652; ngx_module.c:65-79)。
10. **清理旧 cycle**:释放未被复用的旧共享内存、关闭旧监听(含删除 unix socket 文件)、关闭旧文件;master/首次启动直接销毁 old_cycle 池;reload 场景则把 old_cycle 塞进 `ngx_old_cycles`,由 30 秒定时器 `ngx_clean_old_cycles` 检查其连接表无活 fd 后才销毁(ngx_cycle.c:655-828, 1379-1433)。任何一步失败走 `failed:` 标签回滚:关新文件、释放新共享内存、关新监听(ngx_cycle.c:833-953)。

值得强调的是 ngx_init_cycle 的**事务式设计**:old_cycle 始终作为"未提交状态"的基线被完整保留,新 cycle 的每一步资源申请(文件、共享内存、监听 fd)都是可回滚的,失败路径与成功路径对称(ngx_cycle.c:833-953 与 655-779 两段几乎是镜像操作)。这使得 reload 的语义可以概括为"两阶段提交":新 cycle 全部就绪(`ngx_init_modules` 是 commit 点,ngx_cycle.c:649)之后,才进入"清理旧资源"的第二个阶段。这套结构也解释了为什么配置解析要放到 init_cycle 里而不是 main 里——`-t`、`-s`、reload、首次启动、平滑升级的新二进制,五种入口共用同一个"构造一代运行时"的函数,差异只靠 `ngx_test_config`、`NGX_PROCESS_SIGNALLER`、`ngx_is_init_cycle(old_cycle)` 这三个开关裁剪(ngx_cycle.c:316-318, 322-348)。

**模块初始化分层**(总结):

| 阶段 | 时机 | 代码 |
|---|---|---|
| `ngx_modules[]` 链接期生成 | configure 脚本生成 objs/ngx_modules.c,声明 extern 后按序填数组与 `ngx_module_names[]` | auto/modules:1581-1622 |
| preinit(index/name 编号) | main 中配置解析前 | ngx_module.c:25-39 |
| `create_conf` | 配置解析前(core);http 模块在解析到 `http{}` 时自建 | ngx_cycle.c:233-248 |
| `load_module`(动态) | 解析期插入,校验 version+NGX_MODULE_SIGNATURE 二进制签名,按 order 数组决定插入位置 | ngx_module.c:170-183, 211-252 |
| `init_conf` | 解析后(core) | ngx_cycle.c:297-314 |
| `init_module` | 新 cycle 提交后,仅 master 执行一次 | ngx_cycle.c:649 |
| `init_process` | **每次 fork 出 worker 后在子进程内**执行 | ngx_process_cycle.c:925-932 |
| `exit_process` / `exit_master` | 各自退出时 | ngx_process_cycle.c:979-983, 690-694 |

注意:`init_master` 回调在 ngx_module.h:243 声明,但全仓库没有任何调用点(grep 仅命中头文件),属于历史遗留占位。http 模块的 `postconfiguration`(phase handler 挂载)在解析 `http{}` 块结束时执行(src/http/ngx_http.c:310-315)。

## 3. master 的信号状态机

### 3.1 信号注册与投递链

信号表硬编码于 ngx_process.c:39-83,宏定义在 ngx_config.h:60-71:

| 信号 | 宏 | master 行为 | worker 行为 |
|---|---|---|---|
| SIGHUP | NGX_RECONFIGURE_SIGNAL | `ngx_reconfigure=1` → reload | 忽略(ngx_process.c:434-438) |
| SIGUSR1 | NGX_REOPEN_SIGNAL | 重开自身文件 + 广播 | 重开日志(ngx_process_cycle.c:773-777) |
| SIGWINCH | NGX_NOACCEPT_SIGNAL | `ngx_noaccept=1` 停止接受新连接 | daemonized 时视为优雅退出 |
| SIGTERM | NGX_TERMINATE_SIGNAL | 快速退出(带退避升级到 SIGKILL) | 立即退出 |
| SIGQUIT | NGX_SHUTDOWN_SIGNAL | 优雅退出 | 优雅退出 |
| SIGUSR2 | NGX_CHANGEBIN_SIGNAL | exec 新二进制(平滑升级) | 忽略 |
| SIGINT | — | 同 SIGTERM | 同 SIGTERM |
| SIGALRM/SIGIO/SIGCHLD | — | 退避定时/控制事件/收割子进程 | — |
| SIGPIPE/SIGSYS | — | `SIG_IGN`(ngx_process.c:78-80) | — |

master 的主循环本身不 poll 信号,而是**先 `sigprocmask` 屏蔽全部关心信号,再 `sigsuspend(空集)` 原子地"解锁并等待"**(ngx_process_cycle.c:87-104, 163)。信号处理函数只做一件事:置 volatile `sig_atomic_t` 标志(ngx_process.c:340-404),真正的逻辑全部在 sigsuspend 返回后的循环体里串行执行——这是教科书级的"信号处理最小化"设计,避免了 handler 里做复杂操作的不可重入问题。全部状态浓缩在十个全局标志位里(ngx_process_cycle.c:36-53):`ngx_reap`(SIGCHLD)、`ngx_terminate`(TERM/INT)、`ngx_quit`(QUIT)、`ngx_reconfigure`(HUP)、`ngx_reopen`(USR1)、`ngx_change_binary`(USR2)、`ngx_noaccept`(WINCH)、`ngx_sigalrm`(退避定时)、`ngx_sigio`(控制事件),加上 `ngx_exiting`/`ngx_noaccepting`/`ngx_restart` 三个普通变量表达跨信号携带的状态。把主循环的每个 if 分支看作状态转移,整个 master 就是一张以"sigsuspend 唤醒"为时钟节拍的自动机;唯一可能同时置位的组合(比如 QUIT 与 TERM 连发)由分支顺序天然定序——terminate 分支在 quit 之前(ngx_process_cycle.c:203 vs 225),而二者互不清除对方标志,最终以 `!live` 收敛到 exit。

worker fork 时继承了 master 的屏蔽字,因此在 `ngx_worker_process_init` 里显式 `sigprocmask(SIG_SETMASK, 空集)` 解除(ngx_process_cycle.c:915-920)。

### 3.2 主循环逐分支解读(ngx_process_cycle.c:139-296)

```c
for ( ;; ) {
    if (delay) {                          /* 退出退避中 */
        if (ngx_sigalrm) { sigio = 0; delay *= 2; ngx_sigalrm = 0; }
        ... setitimer(ITIMER_REAL, ...);  /* 定时唤醒自己 */
    }
    sigsuspend(&set);                     /* 等信号 */
    ngx_time_update();

    if (ngx_reap) { ngx_reap = 0; live = ngx_reap_children(cycle); }
    if (!live && (ngx_terminate || ngx_quit)) ngx_master_process_exit(cycle);
    if (ngx_terminate) { ... }
    if (ngx_quit) { ... }
    if (ngx_reconfigure) { ... }
    ...
}
```

- **SIGHUP(reconfigure)**:`ngx_init_cycle(cycle)` 全量重建;失败则打回旧 cycle 继续跑(`cycle = (ngx_cycle_t *) ngx_cycle; continue;`),**reload 永不致命**(ngx_process_cycle.c:233-251)。成功则以 `NGX_PROCESS_JUST_RESPAWN` 起新 worker,`ngx_msleep(100)` 后向旧 worker 发 QUIT(ngx_process_cycle.c:256-265)。`just_spawn` 标志防止 `ngx_signal_worker_processes` 把刚起的进程也关掉(ngx_process_cycle.c:507-510)。特例:若 `ngx_new_binary` 非零(升级后新 master 收到 HUP),不重新解析配置而是按当前 worker 数重启进程并清 `ngx_noaccepting`(ngx_process_cycle.c:236-243)。
- **SIGTERM(terminate)**:进入退避流程。`delay` 从 50ms 起,每次 SIGALRM 翻倍;`sigio` 计数器=worker+2,每轮先向所有子进程发 TERM,收到的 SIGCHLD 会消耗计数(实际经 reap 分支),`delay > 1000ms` 后改发 **SIGKILL**(ngx_process_cycle.c:203-223)。即 stop 的语义是"先礼后兵"。
- **SIGQUIT(quit)**:向 worker 发 `NGX_CMD_QUIT` 通道命令(优先于 kill),随后 master 自己 `ngx_close_listening_sockets`(ngx_process_cycle.c:225-231)。当 reap 发现没有任何活子进程时 `ngx_master_process_exit`:删 pidfile → exit_master 回调 → 关监听 → 构造静态的 `ngx_exit_cycle/ngx_exit_log`(保证池销毁后信号 handler 仍能安全打日志)→ `exit(0)`(ngx_process_cycle.c:681-725)。
- **SIGUSR1(reopen)**:master 调 `ngx_reopen_files(cycle, ccf->user)`(新 fd 逐个 chown/chmod 回 worker 用户、FD_CLOEXEC,ngx_cycle.c:1181-1302),再向 worker 广播 reopen(ngx_process_cycle.c:276-282)。
- **SIGWINCH(noaccept)**:置 `ngx_noaccepting=1` 并让 worker 优雅退出,但 master 不退(ngx_process_cycle.c:290-295)。它是平滑升级的"退路开关":若决定放弃升级,再对新 master 发 QUIT 后,旧 master reap 到新二进制退出会把 pid.oldbin 改名回 pid,并置 `ngx_restart=1` 重新拉起 worker(ngx_process_cycle.c:639-663, 268-274)。
- **SIGUSR2(changbin)**:置 `ngx_change_binary`,master 调 `ngx_exec_new_binary`(详见第 4 节)。
- **SIGCHLD(reap)**:handler 内同步 `waitpid(-1, WNOHANG)` 循环收割(ngx_process.c:462-464, 470-561),标记 `exited`、记录退出原因;若 worker 因信号死亡打 ALERT(含 core dump 标记);**退出码为 2 且原计划 respawn 的,取消 respawn**——因为 2 是 worker 初始化失败的约定退出码(nginx.c:838, 863, 929 的 exit(2)),不禁止会陷入 crash loop(ngx_process.c:551-557)。随后 `ngx_unlock_mutexes` 强制释放死进程可能持有的 accept mutex 与各共享内存 slab 互斥锁(ngx_process.c:564-608)。master 循环侧的 `ngx_reap_children` 再做善后:关闭其 socketpair、广播 CLOSE_CHANNEL、按 `respawn && !exiting && !terminate && !quit` 决定重生(ngx_process_cycle.c:615-637),并压缩进程表(`i == ngx_last_process-1` 则数组收缩,否则留 `pid=-1` 的空槽复用,ngx_process_cycle.c:665-670)。

### 3.3 worker 侧信号差异

worker 的 handler 里,HUP/USR2/SIGIO 一律忽略;WINCH 在 daemonized 情况下会置 `ngx_debug_quit=1` 并**穿透到 QUIT 分支**——这让调试者可以用 WINCH 单独杀某个 worker 而不惊动 master(ngx_process.c:412-421)。worker 循环中 QUIT 的处理是"三步走":`ngx_exiting=1`、`ngx_set_shutdown_timer`(worker_shutdown_timeout 到点后把所有残留连接的 read->handler 强行触发以推进关闭,ngx_cycle.c:1436-1484)、`ngx_close_listening_sockets` + `ngx_close_idle_connections` + 处理 posted events(ngx_process_cycle.c:758-771);之后每轮检查 `ngx_event_no_timers_left()`——**所有定时器归零才真正退出**,保证上游响应/keepalive 收尾(ngx_process_cycle.c:742-747)。

## 4. worker 生命周期与平滑升级(USR2/WINCH 的 fd 继承细节)

### 4.1 spawn 与进程间"社交网络"

`ngx_spawn_process`(ngx_process.c:86-258)为每个子进程建一个 `socketpair(AF_UNIX, SOCK_STREAM)` 作为私有双向通道:master 保留 `channel[0]` 写,子进程继承 `channel[1]`(全局 `ngx_channel`,ngx_process.c:176),两端都 FD_CLOEXEC(防止 exec 泄漏),并通过 `ioctl(FIOASYNC)` + `fcntl(F_SETOWN, ngx_pid)` 让 socketpair 可读时向 master 发 SIGIO(ngx_process.c:146-158)。fork 后父进程填表(ngx_process.c:206-251),子进程进入 `ngx_worker_process_cycle`。

worker 初始化的顺序体现权限设计的严谨:`setpriority` → `setrlimit(nofile/core)` → **`setgid` → `initgroups` → `setuid`**(先降组再降用户,顺序不可逆,ngx_process_cycle.c:833-863)→ 透明代理时保留 CAP_NET_RAW → CPU 亲和 → `PR_SET_DUMPABLE`(保证 setuid 后仍能 coredump)→ chdir → 解除信号屏蔽 → `init_process` 回调 → 关闭**其他所有进程**的 channel[1](这些是 fork 时拷来的副本,不关会干扰彼此的 SIGIO)→ 注册 channel 读事件(ngx_process_cycle.c:782-969)。

master 每spawn一个子进程就 `ngx_pass_open_channel` 向所有存活子进程广播 `NGX_CMD_OPEN_CHANNEL {pid, slot, fd=channel[0]}`(ngx_process_cycle.c:417-450),worker 在 `ngx_channel_handler` 里登记,从而形成"所有进程互相知道对方通道"的全互联拓扑——这是 cache worker 等未来横向通信的基础设施(ngx_process_cycle.c:1079-1123)。

### 4.2 USR2 平滑升级:一次 execve 的接力

`kill -USR2 <old_master>` 触发 `ngx_exec_new_binary`(nginx.c:715-824),四步接力:

1. **构造 NGINX 环境变量**:把当前所有 listening fd 序列化成 `NGINX="7;8;9;"`(跳过 `ignore` 的,nginx.c:746-754)。这些监听 socket 创建时**没有**设 FD_CLOEXEC,而日志/通道 fd 都设了——这是刻意的差异,保证 execve 后监听 fd 原封不动地落在同号新二进制里。
2. **pid 文件改名**:`pid → pid.oldbin`(nginx.c:795-805),失败则中止;`ngx_execute`(fork 出的 DETACHED 子进程)里 `execve` 新二进制,失败 `exit(1)`(ngx_process.c:269-281)。
3. **新二进制启动**:main 里 `ngx_add_inherited_sockets` 读 $NGINX,逐个 `ngx_atoi` 还原 fd 数组并标记 `inherited=1`,随后 `ngx_set_inherited_sockets` 对每个 fd 反向探测:getsockname 拿地址、getsockopt(SO_TYPE/SO_RCVBUF/SO_SNDBUF/SO_REUSEPORT)重建 listening 元数据(nginx.c:477-534; ngx_connection.c:135-310)。新 master 因 `ngx_inherited=1` 跳过 daemonize 且 `ngx_daemonized=1`(nginx.c:360-362),并把新 pid 写进 pid 文件(旧 pid 已让位给 .oldbin)。
4. **新旧并存的防呆**:USR2 handler 里的守卫 `if (ngx_getppid() == ngx_parent || ngx_new_binary > 0) ignore` ——新 master 的 `ngx_parent` 是旧 master pid,只要旧 master 还活着它就忽略 USR2;旧 master 一旦已 spawn 新二进制也忽略重复 USR2(ngx_process.c:374-391)。守护性日志还会提示 CRIT 级别(ngx_process.c:455-460)。

随后管理员的操作序列与代码的对应关系:

```
USR2 → 旧master: pid→pid.oldbin, exec 新二进制(继承全部 listen fd)
       新master: 解析 $NGINX, 首个 init_cycle 中所有 listen 都命中
                 old_cycle->listening? 否——新二进制的 init_cycle 是"全新"的,
                 但 fd 已在手里,ngx_open_listening_sockets 对 inherited fd
                 只跳过 bind/listen (ngx_connection.c:504-511)
WINCH → 旧master: ngx_noaccepting=1, 旧 worker 优雅退出(不再接新连接)
QUIT → 旧master: 退出;新master reap 到其父进程消失(ngx_parent 变化),
       正常接管;reap_children 中检测 ngx_new_binary 退出的回滚逻辑
       (ngx_process_cycle.c:639-663)只在"新二进制失败退出"时触发改名回滚
```

若升级失败(新二进制 crash):旧 master reap 到 `pid == ngx_new_binary` 的子进程退出,把 `pid.oldbin` 改名回 `pid`,清 `ngx_new_binary`;若此期间发过 WINCH(`ngx_noaccepting=1`)则置 `ngx_restart=1` 重新拉起 worker(ngx_process_cycle.c:639-663)。**回滚是文件名级别的:监听 fd 一直握在旧 master 手里,从未关闭**。

升级窗口内还有一个容易忽略的细节:此时系统里有两个 master、两套 worker,它们通过 `NGINX` 环境变量交接的 fd 认领了同一批监听端口,accept 竞争完全由内核决定(或各自的 accept mutex——但两代进程的 shm zone 地址经 init_cycle 复用逻辑映射到同一块物理内存,ngx_cycle.c:473-488,因此锁本身是共享的)。旧 master 退出后,新 master 才是 pid 文件的持有者,后续 `nginx -s` 全部作用于新 master。

### 4.3 helper 进程

cache manager/loader 复用 `ngx_worker_process_init`(worker 传 -1,跳过 priority/affinity),但先把自己标成 `NGX_PROCESS_HELPER`、**关闭所有监听 socket**(避免 Unix 域 socket 文件被误删,注释见 ngx_process_cycle.c:1136-1142)、连接数压到 512、`ngx_use_accept_mutex=0`(ngx_process_cycle.c:1128-1176)。manager 定时器周期取各 path `manager()` 返回的最小值(默认上限 1 小时,ngx_process_cycle.c:1186-1205);loader 60 秒后一次性遍历所有 loader path 然后 `exit(0)`,且以 `NORESPAWN` 拉起,不复活(ngx_process_cycle.c:63-65, 409-411, 1230)。

## 5. 设计动机与取舍:为什么 master-worker 而不是线程

1. **隔离故障域**。任何一个 worker 的 segfault 都不会殃及其他连接,master 通过 SIGCHLD 无脑 respawn(ngx_process.c:551-557)即可自愈;线程模型下一个段的内存越界会污染整个进程。代价是进程间必须借助共享内存(slab + shmtx)通信,于是有了 ngx_cycle.c:417-508 的 shm zone 体系和 ngx_process.c:564-608 的死进程强制解锁——复杂度从"锁代码"转移到了"锁的生命周期管理"。
2. **规避多线程 accept 的 thundering herd 与锁竞争**。多个 worker 对同一 listen fd accept,历史上靠 `ngx_use_accept_mutex`(master && workers>1 && accept_mutex 开启,ngx_event.c:647-659)串行化;新内核时代则转向 EPOLLEXCLUSIVE/SO_REUSEPORT。进程模型让这些切换都是配置级的。
3. **权限分离**。只有 master 需要 root(绑定 <1024 端口、setuid),worker 降权运行。线程模型无法在同一进程内做 setuid。
4. **平滑升级的可行性**。execve 只能替换单个进程的镜像,fork 模型天然支持"旧 master exec 成新 master、listen fd 经 fd 表 + 环境变量接力"(第 4.2 节)。多线程程序的 fd 表属于进程,exec 会杀死所有线程,无法保留"旧逻辑继续服务存量连接"的能力。
5. **CPU 可扩展性让位于简单性**。worker 数通常 = CPU 核数(ngx_set_worker_processes 的 auto,nginx.c:1610-1613),每核一进程已足够吃满 I/O 密集型负载;这是 2002 年面对 LinuxThreads/NPTL 不成熟环境下的务实选择。今天看来,进程模型的代价是:每个 worker 独立的连接表使 `worker_connections` 语义变成 per-worker、跨 worker 无法共享连接级状态(只能进 shm zone)。
6. **信号即控制面**。因为 master 循环是 `sigsuspend`,控制协议(reload/reopen/quit/upgrade)不需要 socket/管道,`nginx -s` 甚至可以是一个**独立启动的 nginx 进程**读完配置后对 pidfile 里的 pid `kill()` 就退出(nginx.c:332-334; ngx_cycle.c:1096-1147; ngx_process.c:631-648)——控制面与数据面零耦合。
7. **COW 带来的低廉启动成本**。fork 出的 worker 与 master 共享配置、模块表、监听 fd 的内核对象,写时复制使得 N 个 worker 的边际内存只是各自的事件表和连接池;`ngx_setproctitle` 则复用 argv 内存区改写进程标题(ngx_posix_init.c:49),让运维在 ps/top 里直接读出 "master process ..." 与 "worker process is shutting down" 等状态(ngx_process_cycle.c:107-125, 762),这对排障的价值不亚于日志。

## 6. FAQ

**Q1: `nginx -s reload` 时新起的这个 nginx 进程做了什么?**
它完整走了一遍 main → init_cycle(所以 `-t` 能预检的它也能发现语法错误),但在 ngx_cycle.c:316-318 提前返回,只读 pidfile、`kill(pid, SIGHUP)`(ngx_os_signal_process,ngx_process.c:631-648)即退出。它不会碰监听 socket。

**Q2: reload 时配置有错怎么办?**
`ngx_init_cycle` 返回 NULL,master 用 `cycle = (ngx_cycle_t *) ngx_cycle` 回到旧 cycle 继续,只留一条 error 日志(ngx_process_cycle.c:247-251)。监听 fd 从未被旧 cycle 关闭,零影响。

**Q3: pid 文件为什么不在解析完配置立刻写?**
源码注释明示:daemon 之前写的 pid 是"将死的父进程"的,必须等 `ngx_daemon` fork 后再写(master 侧在 nginx.c:378)。而 init_cycle 阶段连 -t 也会创建(以 CREATE_OR_OPEN 不 TRUNCATE,ngx_cycle.c:1049),用于提前暴露权限问题。

**Q4: QUIT 和 TERM 有什么实质区别?**
QUIT 走通道命令 NGX_CMD_QUIT → worker 关监听、关 idle 连接、等定时器清零再退(ngx_process_cycle.c:742-771);TERM 在 master 侧启动 50ms→翻倍的退避计时,超 1 秒未退即 SIGKILL(ngx_process_cycle.c:203-223)。worker 收到 TERM 是立即 `ngx_worker_process_exit`。

**Q5: worker 崩溃后共享内存里的锁怎么办?**
master 在 waitpid 后调 `ngx_unlock_mutexes`:对 accept mutex `ngx_shmtx_force_unlock(&ngx_accept_mutex, pid)`,并对每个 shm zone 的 slab 互斥锁强制解锁并打 ALERT(ngx_process.c:564-608)。这依赖 shmtx 记录持有者 pid 的机制。

**Q6: 为什么 worker 以 exit code 2 退出后不再 respawn?**
exit(2) 是 init_process 等初始化失败的约定值(nginx.c:838, 929 等)。配置级错误 respawn 多少次都会立刻再死, ngx_process.c:551-557 检测到后把 `respawn` 清零并打 ALERT,避免 crash loop。

**Q7: master_process off / daemon off 分别改变什么?**
`daemon off` 跳过 ngx_daemon(main 里 ccf->daemon 判断,nginx.c:352-358),常用于容器前台运行;`master_process off` 使 main 走 `ngx_single_process_cycle`:不 fork,当前进程直接跑 worker 的事件循环,但保留 reload/reopen 能力(ngx_process_cycle.c:300-354)。注意 single 模式下 worker_processes 等指令失效,也不降权(setuid 在 worker init 里,single 不经过)。

**Q8: master 主循环为什么用 sigsuspend 而不是 sleep/poll?**
信号可能恰好在"检查标志"与"睡眠"之间到达,sleep 会睡满整个间隔。sigprocmask 屏蔽 + sigsuspend 原子解锁等待是 POSIX 提供的唯一无竞态方案(ngx_process_cycle.c:87-104, 163)。

**Q9: reload 会短暂出现新旧两组 worker,它们怎么共存?**
新旧 worker 是兄弟进程,监听 fd 是同一批(新 cycle 直接继承 fd,ngx_cycle.c:539-540),accept mutex 与 shm zone 也按 name+tag+size 复用(ngx_cycle.c:473-487)。旧 worker 只是收 QUIT 后停止 accept、排空存量连接。

**Q10: `nginx -s` 发的 stop/quit/reopen/reload 分别映射什么信号?**
查 signals[] 表的 `name` 字段:"stop"→SIGTERM、"quit"→SIGQUIT、"reopen"→SIGUSR1、"reload"→SIGHUP(ngx_process.c:40-63 的 name 列)。WINCH/USR2 没有对应的 `-s` 名字,只能手工 kill——官方有意让平滑升级走人工确认路径。

## 7. 深挖问题

1. **进程表 slot 的碎片化与 `NGX_MAX_PROCESSES=1024`**:reload 高频操作下,每次 reload 新增 worker+manager 槽位,旧槽位靠 `i == ngx_last_process - 1` 尾部收缩或留 `pid=-1` 空洞复用(ngx_process_cycle.c:665-670; ngx_process.c:94-110)。若频繁 reload 且每次 worker 数不同,中部空洞虽可复用,但 `ngx_pass_open_channel` 每次都是 O(N) 广播,且 worker 侧 `ngx_processes[ch.slot]` 登记依赖 channel 消息到达顺序(ngx_process_cycle.c:1093-1101)——两次 reload 间隔 <100ms 时(ngx_process_cycle.c:261 的 ngx_msleep),just_spawn 标志的清理(ngx_process_cycle.c:507-510)是否可能误伤上一批仍在退出的 worker?值得构造用例验证。
2. **`sigio` 计数与 SIGALRM 退避的正确性**:TERM 流程里 `sigio = ccf->worker_processes + 2`,每轮 sigsuspend 若 `ngx_sigalrm` 则 `delay *= 2`,且 `if (sigio) { sigio--; continue; }` 会**跳过本轮的 kill 重发**(ngx_process_cycle.c:203-223)。SIGCHLD 到达同样会唤醒 sigsuspend 并在 reap 分支消耗掉这个唤醒,那么 sigio 的减 1 到底对应"哪一次唤醒"?在 worker 死亡速度慢于 delay 的场景下,`delay > 1000 → SIGKILL` 的判断条件与子进程实际存活时间的耦合值得逐行推演(是否可能在 50ms×2^k 的某几拍里既不发信号也不 SIGKILL,导致 stop 停滞)。
3. **旧 cycle 延迟回收的内存安全边界**:`ngx_clean_old_cycles` 通过扫描 `cycle->connections[].fd != -1` 判断旧 cycle 是否仍被引用(ngx_cycle.c:1394-1421)。但 reload 后旧 worker 的事件循环仍持旧 cycle 指针,而 `ngx_old_cycles` 由 master 的 temp_pool 持有——若旧 worker 因 worker_shutdown_timeout 被强杀,master 侧的回收窗口(30 秒定时器)与 worker 退出时机之间的竞争是否保证不会出现"回收后旧 worker 仍解引用"?ngx_exit_cycle 静态结构(ngx_process_cycle.c:68-71)是否正是对此的兜底?
4. **共享内存 zone 复用的判定漏洞面**:`shm_zone[i].tag == oshm_zone[n].tag && size 相等` 即复用旧地址并调 `init(zone, old_data)`(ngx_cycle.c:473-488)。tag 是模块指针,而动态模块 .so 在 reload 时若被替换,同路径 .so 的模块指针地址可能变化,导致复用失败重建——反之若两个不同 .so 恰好加载在相同地址(tag 碰撞),会不会错误复用对方的 zone?nginx 只用指针做身份比较(ngx_cycle.c:1305-1376 的 shared_memory_add 同理)。
5. **`init_master` 回调从未被调用**:模块签名里它是唯一没有执行点的生命周期钩子(ngx_module.h:243,全仓库无调用)。它原本预留给什么(master 阶段的预初始化,比如在 fork 前建立统计基础设施)?现代第三方模块常误以为它会执行——这是维护者需要明确的文档空白。
