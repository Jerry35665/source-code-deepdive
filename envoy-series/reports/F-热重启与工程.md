# 报告 F:热重启、Admin 与工程文化

基线:tag v1.39.1(commit b579d07d3ad7ee11d32b105e91a5a39ad24718d7)。本报告所有 `文件:行号`
均经实际 Read/Grep 核对。热重启的"本体"并不在单一文件里:协议骨架在
`source/server/hot_restarting_{base,child,parent}.cc`,与共享内存/版本逻辑的粘合层在
`source/server/hot_restart_impl.cc`,旧资料里的 `hot_restart_parent_stub` 在当前版本对应的是
无热重启模式的桩 `source/server/hot_restart_nop_impl.h`(类 `HotRestartNopImpl`,16-44 行)。

## 0. 总览图:三条通道与时间线

```text
            父进程 epoch N                                子进程 epoch N+1
  ┌─────────────────────────────┐  shm_open /envoy_shared_memory_{base_id*10}
  │ SharedMemory{log_lock,      │◄──────mmap 共享(通道① 共享内存)───────┐
  │  access_log_lock, flags_}   │      仅锁+标志位,不含 stats 数据          │
  └──────────────┬──────────────┘                                          │
                 │ ②控制通道:{socket_path}_parent_{id}  ◄───{...}_child_{id}┘
                 │   AF_UNIX SOCK_DGRAM,长度前缀+HotRestartMessage protobuf
                 │   kPassListenSocket(SCM_RIGHTS 附带 fd)
                 │   kStats / kDrainListeners / kShutdownAdmin / kTerminate
                 │ ③UDP 透传通道:{socket_path}_udp_parent_{id} ◄── _udp_child_{id}
                 ▼   kForwardedUdpPacket(父把收到的 UDP 包原样转给子)
  时间线:
  t0 父 serving(epoch N,持有 listen fd / admin fd)
  t1 子启动,attachSharedMemory() 校验 version=11,置 INITIALIZING 标志
  t2 子按地址向父要 fd(kPassListenSocket);worker 起来后开始服务
  t3 子 restarter_.drainParentListeners() → 父进入 drain(drain-time-s,默认 600s)
  t4 drain 结束/到期,父关 listener;parent-shutdown-time-s(默认 900s)定时器到期
  t5 子 sendParentTerminateRequest → 父 kill(getpid(), SIGTERM)
```

图示对应源码:通道① `source/server/hot_restart_impl.cc:31`(`/envoy_shared_memory_{base_id}`)、
通道② `source/server/hot_restarting_child.cc:62-69`、通道③ `source/server/hot_restarting_parent.cc:20-26`。
时间线锚点:子要 fd 在 `source/common/listener_manager/listener_manager_impl.cc:376`;
drain 触发在 `source/server/server.cc:960`;父终止在 `source/server/drain_manager_impl.cc:224-231`。

## 1. 热重启本体

### 1.1 共享内存:刻意做小

共享内存段不是 stats 大表,而是一个几十字节的结构体(`source/server/hot_restart_impl.h:30-36`):
`size_`/`version_`/两个进程间互斥锁/`flags_`。协议版本 `HOT_RESTART_VERSION = 11`
(`source/server/hot_restart_impl.h:24`),子进程 attach 时严格校验尺寸与版本,不兼容直接
RELEASE_ASSERT 快速失败(`source/server/hot_restart_impl.cc:65-70`),注释明说"你必须热重启进
了一个不兼容的新版本"——这是一条明确的版本隔离契约:不兼容就走全量重启。

初始化竞态用共享内存里的一个原子位兜底:epoch 0 进程 `shmUnlink` 后重建,后来者
`fetch_or(SHMEM_FLAGS_INITIALIZING)`,若前一个进程尚未完成初始化则抛
`EnvoyException("previous envoy process is still initializing")`
(`source/server/hot_restart_impl.cc:73-81`)。日志锁采用 `PTHREAD_PROCESS_SHARED +
PTHREAD_MUTEX_ROBUST`,并对 `EOWNERDEAD` 做 `pthread_mutex_consistent` 恢复
(`source/server/hot_restart_impl.h:60-69`、`source/server/hot_restart_impl.cc:85-91`),父进程
暴死也不会把锁永久带进坟墓。

父子共生关系由内核保证:`prctl(PR_SET_PDEATHSIG, SIGTERM)`,父亡则子收 SIGTERM,
"我们不应该在没有父进程的情况下存在"(`source/server/hot_restart_impl.cc:107-110`)。

### 1.2 控制通道:domain socket 上的迷你 RPC

每个 epoch 的父/子各 bind 一个 `AF_UNIX SOCK_DGRAM` socket,名字由
`{socket_path}_{role}_{base_id*10 + id}` 组成(`source/server/hot_restarting_base.cc:32-49`)。
base_id 自动乘 10 以免不同 base-id 的 Envoy 撞名(`source/server/hot_restart_impl.cc:93-101`);
`MaxConcurrentProcesses = 3`——同址最多 3 个 Envoy 共存,第 3 个启动时会顶掉最老的父
(`source/server/hot_restarting_base.cc:35-38`)。

消息是 `uint64 长度前缀 + HotRestartMessage` protobuf,按 4096 字节分块 `sendmsg`
(`source/server/hot_restarting_base.cc:15,72-99`);`ECONNREFUSED` 时以 1 秒间隔重试至多
10 次(`source/server/hot_restarting_base.cc:16-17,118-143`)。fd 传递走 cmsg 控制数据:

```c
// source/server/hot_restarting_base.cc:104-115(节选)
uint8_t control_buffer[CMSG_SPACE(sizeof(int))];
if (replyIsExpectedType(&proto, HotRestartMessage::Reply::kPassListenSocket) &&
    proto.reply().pass_listen_socket().fd() != -1) {
  memset(control_buffer, 0, CMSG_SPACE(sizeof(int)));
  message.msg_control = control_buffer;
  message.msg_controllen = CMSG_SPACE(sizeof(int));
  cmsghdr* control_message = CMSG_FIRSTHDR(&message);
  control_message->cmsg_level = SOL_SOCKET;
  control_message->cmsg_type = SCM_RIGHTS;
  control_message->cmsg_len = CMSG_LEN(sizeof(int));
  *reinterpret_cast<int*>(CMSG_DATA(control_message)) = proto.reply().pass_listen_socket().fd();
```

请求类型在 `source/server/hot_restart.proto:7-38`:PassListenSocket / ShutdownAdmin /
DrainListeners / ForwardedUdpPacket / Terminate / TestConnection。父进程侧用
`dispatcher.createFileEvent` 把 domain socket 挂进主 event loop
(`source/server/hot_restarting_parent.cc:51-62`),`onSocketEvent()` 按 oneof 分派五种请求
(`source/server/hot_restarting_parent.cc:64-117`)。

### 1.3 fd 通道与"谁管 listener"的仲裁

子进程创建 listener socket 时先向父要:TCP/passthrough 场景
`duplicateParentListenSocket(addr, worker_index, ns)`
(`source/common/listener_manager/listener_manager_impl.cc:375-389`),Unix pipe 场景同理
(356 行)。父进程按 `localAddress == 请求地址 && bindToPort()` 遍历自己的 listener 找到
socket factory,再校验 `worker_index < concurrency()` 后把对应 worker 的 fd 复制给子
(`source/server/hot_restarting_parent.cc:150-171`)。找不到则 fd=-1,子进程自行 bind。

仲裁规则总结:

- 非 reuse-port:同一时刻 fd 只在父(或只在子)手里,交接零丢包;`duplicate()` 语义见
  `source/common/listener_manager/listener_impl.cc:152-166` 的长注释——SO_REUSEPORT 下内核
  为每个 socket 分独立 accept 队列,关队列会丢弃排队连接,所以克隆场景刻意 duplicate 而非
  重建,避免多出临时队列。
- reuse-port(`SO_REUSEPORT` 由 `source/common/network/socket_option_factory.cc:173` 注入;
  bind 类型选择在 `source/common/listener_manager/listener_manager_impl.cc:1264-1267`):
  父子各自持有同址 socket,内核分流入流量;此时 LDS 同名 listener 更新可跳过"地址重复"
  检查(`source/common/listener_manager/listener_manager_impl.cc:713-717`)。
  跨版本默认值一致性也有协议保障:子启动时向父发 `kShutdownAdmin`,把父的
  `enable_reuse_port_default` 原样继承(#17259 切换 reuse-port 默认值的过渡)
  (`source/server/server.cc:640-648`、`source/server/hot_restarting_parent.cc:133-135`)。
- admin socket:子初始化早期发 `sendParentAdminShutdownRequest`,父执行 `shutdownAdmin()`
  (关 admin listener、并顺手 terminate 自己的父)并把 `original_start_time` 传给子
  (`source/server/server.cc:640-643`、`source/server/server.cc:1154-1163`,
  `source/server/hot_restarting_parent.cc:128-136`)。
- drain 节奏:子 workers 全部起来后 `drainParentListeners()`(`source/server/server.cc:960`),
  父 `server_->drainListeners()`(`source/server/hot_restarting_parent.cc:228-232`);
  `drainClose` 按 `elapsed/drain_timeout` 概率渐进关连接(`source/server/drain_manager_impl.cc:75-98`),
  drain 时间来自 `--drain-time-s`(默认 600s,`source/server/options_impl.cc:149-151`);
  子再挂 `--parent-shutdown-time-s`(默认 900s)定时器向父发 Terminate
  (`source/server/drain_manager_impl.cc:218-232`)。命令行禁用热重启时整个机制被
  `HotRestartNopImpl` 桩替换,所有方法空实现/返回 -1
  (`source/server/hot_restart_nop_impl.h:19-39`;开关在 `source/server/options_impl.cc:163-164`)。

### 1.4 UDP 透传通道

TCP 靠 fd 交接,UDP(尤其 QUIC)则由父把每个收到的包封装成 `kForwardedUdpPacket` 转发到
`_udp` domain socket,直到子完成 drain(`source/server/hot_restarting_parent.cc:37-49`);
子按目的地址(含 0.0.0.0/[::] 默认路由回退)找到自己的 listener 投递给对应 worker
(`source/server/hot_restarting_child.cc:20-47,102-125`)。注释坦承:若 worker 数或 QUIC
connection-id 策略在两代间变化,转发会失败,但"绝大多数热重启不会变,这个实现已经比没有
强得多"(`source/server/hot_restarting_child.cc:107-123`)。

## 2. Stats 的跨进程重放

共享内存里没有 stats 数据;stats 是"父导出 protobuf → 子重放"的会话式交接:

- 父端 `exportStatsToChild` 遍历 `forEachSinkedGauge/forEachSinkedCounter`,只导出
  `used()` 的 gauge 与 `latch()>0` 的 counter 增量,附上 `memory_allocated` 与
  `num_connections`(`source/server/hot_restarting_parent.cc:179-202`)。
- 动态 stat 段(如 `cluster.{name}.upstream_cx_total` 里的 `name`)以 span 区间一并导出,
  见 `recordDynamics`(`source/server/hot_restarting_parent.cc:204-226`,引用 issue #9874)。
- 子端 `mergeParentStats` 用 `Stats::StatMerger` 重放
  (`source/server/hot_restarting_child.cc:251-269`)。因为 SymbolTable 是每进程私有的,
  重放时必须按 spans 把名字拆成"符号段+动态段"再 join,恢复与正常运行时完全一致的
  StatName 表示(`source/common/stats/stat_merger.cc:22-75`)。
- gauge 有三种合并语义(Accumulate 累加 / NeverImport 跳过 / Uninitialized 先记父值),
  父贡献记录在 `parent_gauges_`,析构时统一 `setParentValue(0)` 清账
  (`source/common/stats/stat_merger.cc:87-143,10-20`)。
- 接力棒最后交还:子向父发 Terminate 时 `retainParentGaugeValue` 保留
  `server.hot_restart_generation` 的父贡献并销毁 StatMerger
  (`source/server/hot_restarting_child.cc:236-248`;generation gauge 定义于
  `source/server/hot_restarting_base.cc:273-287`,父端启动即 inc,
  `source/server/hot_restarting_parent.cc:124-126`)。子进程在 `run()` 一开始就合并父 stats
  (`source/server/server.cc:262-264`)。

## 3. Admin:挂在主 event loop 上的控制面

当前版本 admin 不是独立操作系统线程,而是主线程 event loop 上一组独立的
listener + HCM(连接管理)实例:`AdminImpl::startHttpListener` 自己建 socket/listener
(`source/server/admin/admin.cc:54-77`),由 server 初始化流程启动
(`source/server/server.cc:797`);`AdminListener` 是一个独立的 `Network::ListenerConfig`
(`source/server/admin/admin.h:385-405`)。"独立 event loop"的工程意义在于:它与全部
worker 隔离,worker 死锁或过载时 admin 仍可应答;它还自带一个假 overload manager
(`null_overload_manager_`,`source/server/admin/admin.cc:117`)并支持
`ignore_global_conn_limit`,让控制面不受数据面降级策略波及。

端点全部是构造函数里的一张 `handlers_` 表(`source/server/admin/admin.cc:127-280`),函数级挂点:

| 端点 | 实现函数 | 位置 |
|---|---|---|
| /clusters | `ClustersHandler::handlerClusters`(re2 filter,json/text 双输出) | source/server/admin/clusters_handler.cc:48,64-69 |
| /config_dump | `ConfigDumpHandler::handlerConfigDump`,经 `ConfigTracker::getCallbacksMap()` 收集各组件注册的 dump 回调 | source/server/admin/config_dump_handler.cc:152,193 |
| /stats | `StatsHandler::statsHandler` 返回的 UrlHandler(filter/usedonly/format/type 参数化) | source/server/admin/stats_handler.cc:214,244 |
| /stats/prometheus | `StatsHandler::handlerPrometheusStats` | source/server/admin/stats_handler.cc:146 |
| /server_info | `ServerInfoHandler::handlerServerInfo` | source/server/admin/server_info_handler.cc:82 |
| /hot_restart_version | `handlerHotRestartVersion` | source/server/admin/server_info_handler.cc:36-40 |
| /drain_listeners、/healthcheck/*、/quitquitquit 等 | listeners_handler/server_cmd_handler | source/server/admin/admin.cc:182-233 |

热重启 epoch 在 `/server_info` 的呈现(`source/server/admin/server_info_handler.cc:92-100`):
`hot_restart_version`(协议版本,同 `--hot_restart_version` 输出
`{11}.{sizeof(SharedMemory)}`,`source/server/hot_restart_impl.cc:170-172`)、
`hot_restart_initializing`(读共享内存 INITIALIZING 位,
`source/server/hot_restart_impl.cc:166-168`)、以及 `uptime_current_epoch` 与
`uptime_all_epochs` 的分列——后者就是"本进程活了多久 vs 首个 epoch 起活了多久",
`original_start_time` 由父进程经 shutdownAdmin 应答传下来
(`source/server/server.h:303`、`source/server/server.cc:640-643`)。

## 4. 进程收尾:terminate_handler 与 GuardDog

### 4.1 std::terminate 钩子

`TerminateHandler::logOnTerminate` 预热地址映射(避免栈回溯时的 signal-unsafe 文件操作),
然后 `std::set_terminate`:记录异常、打印 backtrace、`std::abort`
(`source/exe/terminate_handler.cc:15-24,26-40`)。它以成员对象身份嵌在
`MainCommon` 里全局生效(`source/exe/main_common.h:146`)。

### 4.2 GuardDog:多级间隔表,宁杀勿挂

GuardDog 是独立线程(线程名 `dog:{dispatcher}`,`source/server/guarddog_impl.cc:229-236`),
周期 `loop_interval_` 取所有阈值的最小非零值(37-49 行)。每个 worker 通过
`createWatchDog` 注册 watchdog 并由 dispatcher 每 loop_interval/2 自动 touch
(`source/server/guarddog_impl.cc:191-209`;worker 侧 `source/server/worker_impl.cc:175`,
主线程也有自己的 watchdog,`source/server/server.cc:1080`)。`step()` 逐级判罚
(`source/server/guarddog_impl.cc:143-172`):

| 级别 | 默认阈值 | 行为 | 源码 |
|---|---|---|---|
| miss | 200ms | `watchdog_miss` 计数 + MISS 事件回调 | source/server/configuration_impl.cc:225-226 |
| megamiss | 1000ms | `watchdog_mega_miss` 计数 + MEGAMISS 回调 | source/server/configuration_impl.cc:227-228 |
| kill | 0=默认关闭 | 触发 KILL(可加 `max_kill_timeout_jitter` 抖动) | source/server/configuration_impl.cc:230-243 |
| multikill | 0=默认关闭 | 达到 `multi_kill_threshold`(占被监视线程比例)且多个线程同卡,判全局死锁 | source/server/guarddog_impl.cc:124-127,164-171 |

kill/multikill 默认挂一个 abort_action:先 `Thread::terminateThread` 向卡死线程发终止信号,
等 5 秒仍不退则 `PANIC` 自爆(`source/common/watchdog/abort_action.cc:14,38-50`)。
这套"自杀式"设计留全量 backtrace 给运维,而不是让进程无声挂死。

## 5. OverloadManager:压力→降级的 manager 侧管线

主线程周期定时器(15.6.0 起默认间隔由 bootstrap 配置)驱动 `flushResourceUpdates` 与
每个 resource monitor 的 `update`(`source/server/overload_manager_impl.cc:583-614`)。
触发器两种:`ThresholdTriggerImpl`(压力≥阈值即饱和,26-45 行)与
`ScaledTriggerImpl`(线性插值出 0~1 的 `UnitFloat` 状态,47-84 行)。
`updateResourcePressure` 把资源压力映射到 action:状态变化才记录、去重后批量 flush 到
thread-local,并回调 `registerForAction` 注册的订阅者
(`source/server/overload_manager_impl.cc:673-719,628-642`)。
与 C 报告的 accept 闸门呼应:同一压力值还会喂给每个 `LoadShedPoint`
(705-707 行;`getLoadShedPoint` 在 660-665 行),accept 拒绝/keepalive 关闭等具体闸门
动作由各 LoadShedPoint 侧实现。一个内建消费者示范了"action→行为"管线:ReduceTimeouts
action 的状态会反转后传给 `ScaledRangeTimerManager::setScaleFactor`,全局缩时各类定时器
(645-658 行)。

## 6. 工程文化:registry、bazel/CI、测试与发布

- **扩展注册机制**:header-only 的 `envoy/registry/registry.h` 提供
  `FactoryRegistry<Base>`(按名查找,不允许重名,166 行起)与
  `FactoryCategoryRegistry`(按 category 聚合,104-146 行);扩展以静态对象
  `REGISTER_FACTORY` / `LEGACY_REGISTER_FACTORY` 自注册
  (`envoy/registry/registry.h:505-506,623-642`;实例:
  `source/extensions/access_loggers/file/config.cc:88-89`)。服务端发现 /server_info
  里能看到全部注册项(`source/server/server.cc:616-634`)。
- **配置安全网**:每个扩展 config 都走 `MessageUtil::downcastAndValidate` + 生成的
  `*.pb.validate.h` 做启动期强校验(`source/extensions/access_loggers/file/config.cc:6,26-28`)
  ——配置错误在启动即死,而非运行期静默错配。扩展元数据(status/security_posture/type_urls)
  集中在 `source/extensions/extensions_metadata.yaml:1-17`。
- **bazel 与 CI**:约 1384 个 `.cc`、42 个扩展目录;CI 是 checks 模型(Envoy/Prechecks 快查
  format/lint/spelling,Envoy/Checks 跑编译/测试/覆盖率/sanitizer),format 失败是"最常见的
  CI 拒因"(`AGENTS.md:169-187,10-13`)。
- **测试金字塔(目录证据,未运行)**:`test/common` 440 个 `*test.cc`(单元)、
  `test/server` 50、`test/integration` 96(真网络集成);AGENTS.md 明文要求测试镜像
  `source/` 结构、新代码 100% 覆盖、单测必须 hermetic/确定性、集成测试走 localhost
  (`AGENTS.md:43-48`)。
- **发布节奏**:季度大版本(`RELEASES.md:19`,"quartely"为原文拼写);
  `changelogs/` 保留从 1.0.0 起每个版本的 yaml(`REPO_LAYOUT.md:11`),抽样本仓
  `changelogs/1.39.1.yaml:1` 日期 2026-08-27、内容以 CVE 修复为主;现行开发在
  `changelogs/current/` 放 rst 片段(`AGENTS.md:145-146`)。热重启的外层包装脚本
  `restarter/hot-restarter.py` 仍在(`REPO_LAYOUT.md:29`),与 §1.2 的"三进程共存"语义配套。
- **AGENTS.md 现状**:本仓 v1.39.1 已有面向 AI 编码代理的仓库级说明
  (`AGENTS.md:1-3`),核心规则 7 条:真人 `git commit -s` 签署、提交前跑 format、
  review 后禁止 amend/force-push、禁止 rebase、**提交 PR 必须披露 AI 使用且提交者须完全
  理解所提交代码**(`AGENTS.md:18-20`)、禁直接提交 main、推个人 fork(7-23 行)。
- **版本与兼容(一句话)**:`VERSION.txt:1`(1.39.1)是代理发行版本,`API_VERSION.txt:1`
  (3.0.0)是 data plane API 版本,二者解耦,使 xDS API 演进不必绑定代理发版
  (API_VERSION.txt 由 bazel 注入 `envoy_api_version`,`bazel/repo.bzl:342`)。

## 7. 设计动机

1. **为什么 fork 新进程而非线程内重启**:进程是唯一的"内存全量回收"边界——旧版本代码、
   泄漏的堆、烂掉的 TLS 状态都随旧进程消亡;`HOT_RESTART_VERSION` 契约允许不兼容版本
   干脆利落地全量重启(`source/server/hot_restart_impl.cc:65-70`),`PR_SET_PDEATHSIG`
   保证无孤儿(`source/server/hot_restart_impl.cc:107-110`)。
2. **为什么用 domain socket 传 fd**:SCM_RIGHTS 是 POSIX 下唯一能把"已 bind 的 listen
   socket 所有权"原样移交(保留 accept 队列、不中断服务)的机制;SOCK_DGRAM 保消息边界,
   天然适合一问一答的迷你 RPC(`source/server/hot_restarting_base.cc:56,103-116`)。
3. **为什么 stats 不再放大共享内存,而走 RPC 重放**:符号化 stat 名的收益依赖每进程私有
   SymbolTable,父进程全名字符串表会侵蚀该收益(源码 TODO 自述,
   `source/server/hot_restarting_parent.cc:175-178`);共享内存只留互斥锁与初始化标志
   (`source/server/hot_restart_impl.h:30-36`),重放时用 dynamic spans 精确保留
   "动态段"语义(`source/common/stats/stat_merger.cc:22-75`)。
4. **为什么 GuardDog 宁杀勿挂**:卡死的 worker 会让 accept/连接资源无声冻结,外部探针
   只能杀整个 pod 且拿不到现场;watchdog 自爆能留下 backtrace、由外层 restarter 拉起新
   epoch,multikill 用"多线程同时卡死"的占比阈值区分单线程饥饿与全局死锁
   (`source/server/guarddog_impl.cc:164-171`)。
5. **为什么 admin 与 worker 隔离(独立 listener/HCM)**:控制面必须比数据面活得久——
   worker 全卡死时 `/server_info` `/healthcheck/fail` 仍可用,admin 还有自己的
   overload 管理豁免(`source/server/admin/admin.cc:117`)与独立连接管理,热重启时
   admin socket 经 `kShutdownAdmin` 显式交接(`source/server/hot_restarting_parent.cc:128-136`)。
6. **为什么 OverloadManager 集中采样、分布式执行**:压力判定在主线程单点完成(避免各
   worker 采样漂移),状态经 thread-local 广播 + 回调通知消费方各自降级
   (`source/server/overload_manager_impl.cc:574-577,697-701`),闸门动作仍贴近数据面。
7. **为什么强调启动期校验与静态注册**:pb.validate + REGISTER_FACTORY 让"配置是否能被
   这个二进制解释"在启动时成为封闭问题,配合 100% 覆盖率与 hermetic 单测的文化约定
   (`AGENTS.md:44-48`),是 Envoy 大规模扩展不掉链子的根本。

## 8. 写作素材清单(文件:行号)

1. `source/server/hot_restart_impl.h:24,30-36` — HOT_RESTART_VERSION=11 与共享内存结构
2. `source/server/hot_restart_impl.cc:73-81` — INITIALIZING 竞态保护
3. `source/server/hot_restart_impl.cc:93-110` — base_id*10 与 PDEATHSIG
4. `source/server/hot_restarting_base.cc:35-45` — 三进程共存与 socket 命名
5. `source/server/hot_restarting_base.cc:103-116` — SCM_RIGHTS 传 fd
6. `source/server/hot_restarting_parent.cc:64-117` — 父侧五种请求分派(kTerminate=自杀)
7. `source/server/hot_restarting_parent.cc:138-173` — 按 worker_index 复制 listen fd
8. `source/server/hot_restarting_child.cc:167-175` + `source/server/server.cc:957-961` — drain 触发链
9. `source/server/drain_manager_impl.cc:75-98,218-232` — 概率 drainClose 与 parent-shutdown 定时器
10. `source/common/listener_manager/listener_impl.cc:152-166` — SO_REUSEPORT 队列与 duplicate 语义
11. `source/server/hot_restarting_parent.cc:179-226` + `source/common/stats/stat_merger.cc:22-75` — stats 导出/重放
12. `source/server/admin/admin.cc:127-238` — handlers_ 表;/server_info 呈现见
    `source/server/admin/server_info_handler.cc:86-100`
13. `source/server/guarddog_impl.cc:143-172` + `source/server/configuration_impl.cc:225-245` — 多级 MSD 间隔表
14. `source/common/watchdog/abort_action.cc:38-50` + `source/exe/terminate_handler.cc:15-24` — 自杀与收尾
15. `source/server/overload_manager_impl.cc:583-614,673-719` — 压力→action 管线
16. `envoy/registry/registry.h:104-146,623` + `source/extensions/access_loggers/file/config.cc:26-28,88-89` — 注册与校验文化;
    节奏佐证 `RELEASES.md:19`、`changelogs/1.39.1.yaml:1`、`AGENTS.md:18-20`
