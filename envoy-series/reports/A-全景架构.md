# A · Envoy 全景与架构

> 系列:《Envoy 深读》报告 A
> 基线:tag **v1.39.1**(VERSION.txt:1),commit `b579d07d3ad7ee11d32b105e91a5a39ad24718d7`
> 所有 `文件:行号` 均在上述基线上逐一核对(相对仓库根)。

## 1. 全景图:进程内的对象层次

```
envoy 进程 (单进程, N = --concurrency 个 worker 线程)
├── main 线程 (source/exe/main_common.cc:164 Thread::MainThread)
│   ├── MainCommon ── StrippedMainBase
│   │     ├── ThreadLocal::InstanceImpl        (tls_,stripped_main_base.cc:68)
│   │     ├── Stats::ThreadLocalStoreImpl      (stats_store_,stripped_main_base.cc:69)
│   │     └── HotRestart (parent/child 共享内存) (stripped_main_base.cc:106-164)
│   └── Server::InstanceImpl  (instance_impl.h:10,继承 server.h:240 InstanceBase)
│         ├── Api::Impl + main Dispatcher "main_thread"   (server.cc:94-98)
│         ├── AdminImpl (admin HTTP server)               (server.cc:653-663)
│         ├── Runtime::Loader  (分层 runtime/RTDS)        (server.cc:670)
│         ├── OverloadManager  (资源压力→动作)            (server.cc:674-677)
│         ├── ListenerManagerImpl  (listener_manager_impl.cc:429-431 建 workers)
│         │     └── workers_: vector<WorkerPtr>           (listener_manager_impl.h:385)
│         ├── ClusterManager (经 config_.initialize,server.cc:841)
│         ├── XdsManagerImpl (xds_manager_,server.cc:824-825)
│         └── MainImpl (ServerConfiguration,configuration_impl.cc:112-159)
└── worker 线程 ×N  (WorkerImpl,worker_impl.cc:49-70)
      ├── 独立 Dispatcher = libevent event_base (libevent_scheduler.cc:26-32)
      ├── tls_.registerThread(dispatcher, false)   (worker_impl.cc:56)
      └── ConnectionHandler (accept + 连接生命周期) (worker_impl.cc:44)
```

### 1.1 请求生命周期(线程视角)

```
下游连接                          main 线程                      worker 线程 (每连接固定一个)
   │                                                                  │
   │── SYN → 内核:同一个 listen fd(NoReusePort)或 per-worker        │
   │          reuse_port fd(envoy/server/listener_manager.h:102-109)  │
   │                                                    accept → ConnectionHandlerImpl::addListener
   │                                                             (connection_handler_impl.cc:40)
   │                                                       │
   │                                                       ├── L4 network filters (tcp_proxy 等)
   │                                                       └── HCM → http filters → router
   │                                                                  │
   │                                                  ClusterManager 选主机 → 上游连接池(同 worker)
   │
配置/统计/关闭等全局事务由 main 线程经 dispatcher post 广播到全部线程
(thread_local_impl.cc:128-135 set / 179-189 runOnAllThreads)
```

要点:数据面请求**不经过 main 线程**;main 线程只负责配置(xDS 订阅在 main dispatcher 上)、统计聚合与生命周期管理。这是理解 Envoy 并发模型的第一原则。

## 2. 定位:README 与一句话差异

README 第 3 行自述:"Cloud-native high-performance edge/middle/service proxy"——云原生、高性能、边缘/中间层/服务间代理,由 CNCF 托管(README.md:5)。README.md:20-23 直接给出四篇设计博客:线程模型、hot restart、stats 架构、universal data plane API,基本就是"全景/线程/热重启/统计"这条写作路线的官方索引。

一句话对比:**Nginx** 是"多进程 worker + 静态配置文件 + reload/热升级"的 Web/反向代理;**Caddy** 是"单二进制、自动 HTTPS、面向站点托管"的 Web 服务器;**Envoy** 则是"单进程多线程、以 xDS 动态配置为核心、以 filter 为扩展单元"的 L7 数据平面——它是给控制面(Mesh)编程的代理,而不是给运维改配置文件的 Web 服务器。

## 3. 启动链:从 main() 到 main dispatch loop

### 3.1 exe 层:main → MainCommon

- `source/exe/main.cc:16-25`:`main()` 只做一层转发,Windows 下走 `ServiceBase`,其余直接 `MainCommon::main(argc, argv)`(main.cc:24)。
- `source/exe/main_common.cc:158-193`:`MainCommon::main` 先 `absl::InitializeSymbolizer`(162),再声明 `Thread::MainThread main_thread`(164),在 `TRY_ASSERT_MAIN_THREAD` 中构造 `MainCommon`(171);异常按 NoServing/MalformedArgv/EnvoyException 三类兜底(178-188)。`run()` 特意放在 try/catch **之外**(190-192),让意外异常直接 core dump 便于诊断。
- `MainCommon` 构造(main_common.cc:135-145):`OptionsImpl`(命令行解析)→ `MainCommonBase`,成员包括 `RealTimeSystem`、`DefaultListenerHooks`、`ProdComponentFactory`(main_common.h:149-153)。
- `StrippedMainBase` 构造(stripped_main_base.cc:44-75):尽早处理 `--disable-extensions`(52)、开启 core dump(55-62);Serve/InitOnly 模式下创建 **ThreadLocal::InstanceImpl**(68)与 **Stats::ThreadLocalStoreImpl**(69)——这两个对象先于 server 存在,因为它们是所有组件的底座;Validate 模式用 `HotRestartNopImpl`(72)。
- 热重启初始化:`configureHotRestarter`(stripped_main_base.cc:106-164),动态 base-id 最多重试 100 次(118-132)。
- `StrippedMainBase::init`(77-96):经 `createFunction`(main_common.cc:34-51)new 出 **`Server::InstanceImpl`**(main_common.cc:44)并调用 `server->initialize(local_address, component_factory)`(main_common.cc:48)。生产类 InstanceImpl(instance_impl.h:10-13)只覆写 heap shrinker/GuardDog/HDS 等可替换件。
- `MainCommonBase::run()`(main_common.cc:80-105)按模式分派:`Serve → runServer()`(86-87),`Validate → Server::validateConfig`(93-97),`InitOnly` 仅 PERF_DUMP(99-101)。同一套 exe 代码支撑三种运行模式。

### 3.2 server 层:InstanceBase::initialize 的关键步骤(逐行)

`InstanceBase` 构造(server.cc:78-109)即建好:Api::Impl(94)、**main 线程 dispatcher** `"main_thread"`(98)、AccessLogManager(99-100)、ConnectionHandler 与 `worker_factory_`(101),并把 ServerFactoryContext 注册到线程局部单例(108)。`initialize`(server.cc:423-462)先挂文件日志(425-437)、`restarter_.initialize`(443)、创建全局 `drain_manager_`(444),随后进入 `initializeOrThrow`(server.cc:464-890):

| 步骤 | 位置 | 说明 |
|---|---|---|
| 打印静态链接扩展 | server.cc:469-472 | 遍历 FactoryCategoryRegistry |
| 主线程注册 TLS | server.cc:478 | `registerThread(*dispatcher_, true)` |
| **加载 Bootstrap** | server.cc:481-482 | 见 §5 配置入口 |
| 应用日志/Perfetto/header 前缀/自定义 inline header | server.cc:485-535 | |
| 正则引擎注入单例 | server.cc:540-541 | 先于 stats(stats matcher 可能含正则) |
| TagProducer / StatsMatcher / HistogramSettings | server.cc:545-552 | |
| server.* 统计与初始化耗时直方图 | server.cc:554-574 | `initialization_time_ms_`(573) |
| node/user_agent/扩展清单回填 bootstrap | server.cc:601-630 | 供 xDS 对端识别 |
| LocalInfoImpl | server.cc:632-634 | cluster/node/zone 元数据 |
| **InitialImpl(initial_config)** | server.cc:637-638 | admin/flags/runtime 等 bootstrap 级配置 |
| **AdminImpl 创建** | server.cc:653-663 | 含 allow_paths(656-659) |
| SecretManager | server.cc:664 | |
| **Runtime Loader** | server.cc:670 | `component_factory.createRuntime`(stripped_main_base.cc:39-42) |
| **OverloadManager**(先于他人注册动作) | server.cc:673-677 | 注释明说"initialize the overload manager early" |
| bootstrap_extensions 实例化 | server.cc:681-689 | |
| fatal actions 注册 | server.cc:691-709 | |
| 默认 socket interface | server.cc:711-718 | |
| **ListenerManager 创建** | server.cc:737-740 | 注释:"Workers get created first so they register for thread local updates" |
| runtime 刷新 worker 快照 | server.cc:745-747 | |
| **stats 线程化** | server.cc:750 | `stats_store_.initializeThreading` |
| **Admin 启动 HTTP listener** | server.cc:788-811 | `startHttpListener`(797-798)+ `addListenerToHandler`(810) |
| SSL ContextManager | server.cc:814-815 | |
| **XdsManagerImpl** | server.cc:824-825 | |
| ProdClusterManagerFactory | server.cc:827-830 | |
| **config_.initialize(= ClusterManager + 静态资源)** | server.cc:841 | 见下文与 §5 |
| **创建 LDS API** | server.cc:845-856 | 必须晚于 listener manager |
| runtime 挂接 CM / RTDS | server.cc:860 | |
| **stats sinks 挂载 + flush timer** | server.cc:865-874 | 非 flushOnAdmin 时起定时器(872-874) |
| GuardDog(main/worker) | server.cc:883-888 | 必须先于 worker 启动(881 注释) |

server.cc:757-770 有一段官方口径的初始化总顺序注释,值得整段引用:

```cpp
// The broad order of initialization from this point on is the following:
// 1. Statically provisioned configuration (bootstrap) are loaded.
// 2. Cluster manager is created and all primary clusters (i.e. with endpoint assignments
//    provisioned statically in bootstrap, discovered through DNS or file based CDS) are
//    initialized.
// 3. Various services are initialized and configured using the bootstrap config.
// 4. RTDS is initialized using primary clusters. ...
// 5. Secondary clusters (with endpoint assignments provisioned by xDS servers) are initialized.
// 6. The rest of the dynamic configuration is provisioned.
```

`config_.initialize` 即 `MainImpl::initialize`(configuration_impl.cc:112-159):tracer 配置先行(122)、stats_config(128)、静态 secrets(131-136)、**`clusterManagerFromProto` + `cluster_manager_->initialize`**(141-144)、静态 listeners 逐个 `addOrUpdateListener`(147-154)、watchdog(155)、**stats sink 工厂创建**(166-175)。

ClusterManager 内部又是两阶段初始化(cluster_manager_impl.cc:365-428):先装 primary clusters(非 EDS 或文件型 EDS,392-404),再初始化 ADS 连接(407),然后才是依赖 ADS 的 secondary(EDS)clusters(410-425)。RTDS 回调链在 `onClusterManagerPrimaryInitializationComplete`/`onRuntimeReady`(server.cc:892-943,secondary clusters 901、HDS 909-931)——**配置系统的依赖拓扑:静态种子 cluster → xDS 通道 → 其余一切**。

### 3.3 Init::Manager:两阶段初始化的粘合剂

Listener/RTDS/RDS 等"需要异步初始化"的组件都实现 `Init::Target`,由 `Init::Manager` 串行驱动(source/common/init/manager_impl.cc:40 `initialize` 起,完成后置 `State::Initialized`,99)。server 级 init_manager 在 RunHelper 的 `cm.setInitializedCb` 里被触发(server.cc:1058),其完成回调即 `startWorkers`。

### 3.4 run():RunHelper → workers → 退出

`InstanceBase::run()`(server.cc:1066-1095)先构造 **RunHelper**(990-1064):

- 注册 SIGTERM/SIGINT/SIGUSR1/SIGHUP(1005-1024;SIGUSR1 重开访问日志 1016-1019,SIGHUP 被吞掉因为热重启不走信号 1021-1023);
- **启动 OverloadManager**(1028-1029);
- 注册 `cm.setInitializedCb`(1046):所有 cluster 就绪后 **pause RDS** → 执行 `init_manager.initialize`(1055-1058)→ resume RDS(1060-1062 的 Cleanup 语义)。

init 完成回调里 `notifyCallbacksForStage(PostInit)` 并 **`startWorkers()`**(1070-1074),随后 main 线程进入 `dispatcher_->run(Event::Dispatcher::RunType::Block)`(1087),并为主线程创建 GuardDog watch dog(1078-1082)。`startWorkers`(server.cc:945-963)的完成回调里:完成初始化计时、置 `workers_started_`、触发 `hooks_.onWorkersStarted`、通知热重启父进程 drain 并启动 parent shutdown sequence(953-961)。`shutdown()`(1147-1152)经 `Stage::ShutdownExit` 生命周期回调后 `dispatcher_->exit()`(1151)。退出路径 `terminate()`(server.cc:1097-1143)按序:`thread_local_.shutdownGlobalThreading`(1104)→ `stats_store_.shutdownThreading`(1107)→ 关闭 xDS mux 工厂(1110-1118)→ `stopWorkers`(1126)→ CM shutdown(1135)→ `thread_local_.shutdownThread`(1138)——与初始化顺序镜像。

## 4. 目录结构

REPO_LAYOUT.md:31-52 给出权威划分:

- **source/common/**:"可被库化"的核心代码——event(Dispatcher/libevent)、thread_local、upstream(ClusterManager)、http、listener_manager(connection handler/LDS 等)、router、stats、config(xDS 订阅)(REPO_LAYOUT.md:41-43)。
- **source/server/**:独立 server 形态专属——启动(server.cc)、配置(configuration_impl.cc)、worker(worker_impl.cc)、overload、hot restart、guarddog、admin(REPO_LAYOUT.md:50-52)。
- **source/exe/**:最终二进制专属的 main/信号/平台层,是唯一不被单测与集成测试共享的代码(REPO_LAYOUT.md:46-47)。
- **envoy/**:全抽象类的"公共接口头文件"(REPO_LAYOUT.md:21-25),如 envoy/server/listener_manager.h。
- **source/extensions/**:按类别注册的扩展(REPO_LAYOUT.md:84-170)。重要类别举例:
  - `filters/http/`:router、rbac、jwt_authn、lua、wasm、ext_authz、ext_proc、fault、oauth2、grpc_json_transcoder 等(source/extensions/filters/http/ 目录,60+ 项);
  - `filters/network/`:http_connection_manager、tcp_proxy、redis_proxy、thrift_proxy、dubbo_proxy、mongo_proxy、ext_authz、wasm 等(source/extensions/filters/network/ 目录);
  - 其余:access_loggers、clusters、tracers、stat_sinks(statsd/dog_statsd/hystrix/metrics_service/open_telemetry/wasm)、transport_sockets、quic、load_balancing_policies、resource_monitors、wasm_runtime、config_subscription 等(REPO_LAYOUT.md:85-170)。

扩展注册进 `extensions_build_config.bzl`,可按站点裁剪编译(REPO_LAYOUT.md:78-83);运行时 server.cc:469-472 会把注册表打印成 "statically linked extensions" 日志,contrib 仓库另有 contrib/ 目录镜像 extensions 布局(REPO_LAYOUT.md:179-188)。

## 5. 配置入口:Bootstrap → ServerConfiguration

Envoy 的配置分两层:**Bootstrap(静态,文件/命令行)**与 xDS(动态,网络)。加载入口是 `InstanceUtil::loadBootstrapConfig`(server.cc:364-397):`--config-path` 文件(378-380)、`--config-yaml` 覆盖合并(381-391)、`Options::configProto`(392-394),三者至少其一(372-376),最后统一 `MessageUtil::validate`(395)。

Bootstrap 中的 `static_resources`(clusters/listeners/secrets)由 `MainImpl::initialize` 消化(§3.2);`dynamic_resources` 的 LDS 在 server.cc:845-856 挂接,CDS 经 ClusterManager 订阅;`XdsManagerImpl`(server.cc:824-825)统一管理 xDS 传输与 ADS 连接(cluster_manager_impl.cc:407)。bootstrap 级"先于主配置"的 admin/flags/runtime/overload 部分被抽成 `Configuration::InitialImpl`(server.cc:637-638);stats/tracer/watchdog 完整语义在 configuration_impl.cc:112-221。`ServerFactoryContext`(server.cc:108 注册)是所有工厂拿到 server 全局对象的统一入口。

## 6. 线程模型:main + N worker,每 worker 一个 event loop

- worker 数量 = `--concurrency`,在 ListenerManager 构造时一次性创建:listener_manager_impl.cc:429-431,命名 `worker_<i>`。
- 每个 worker = 一个线程 + 一个独立 libevent event loop:`ProdWorkerFactory::createWorker` 里 `api_.allocateDispatcher(worker_name, ...)`(worker_impl.cc:42-43)+ ConnectionHandler(44);dispatcher 底层是 `event_base_new`(libevent_scheduler.cc:26-32)。Dispatcher 同时提供 post 队列(263)、deferredDelete(244)与 `run(RunType)`(291)(source/common/event/dispatcher_impl.cc)。
- 真正起线程在 `startWorkers`(listener_manager_impl.cc:1120-1131):先把每个 active listener 播发给每个 worker(1096-1104,计数器凑齐后回调 `workers_started_`),可选 CPU 亲和(1107-1119,`enable_worker_cpu_affinity`),`worker->start(guard_dog, cb, cpu_id)` 后用 `BlockingCounter` 等全部 worker 跑起来(1072-1075, 1134)。线程名前缀 `wrk:`(worker_impl.cc:126),`createThread`(128-129)。
- `WorkerImpl::threadRoutine`(worker_impl.cc:168-192):`dispatcher_->run(RunType::Block)`(179);退出时先 `handler_.reset()` 关闭全部连接(189,注释解释了为什么析构必须发生在 worker 线程——否则会引用已销毁的 thread locals),再 `tls_.shutdownThread()`(190)。
- worker 的构造函数把"每线程事务"一次注册齐(worker_impl.cc:49-70):

```cpp
WorkerImpl::WorkerImpl(ThreadLocal::Instance& tls, ListenerHooks& hooks,
                       Event::DispatcherPtr&& dispatcher, Network::ConnectionHandlerPtr handler,
                       OverloadManager& overload_manager, Api::Api& api, WorkerStatNames& names)
    : tls_(tls), hooks_(hooks), dispatcher_(std::move(dispatcher)),
      handler_(std::move(handler)), api_(api), reset_streams_counter_(...) {
  tls_.registerThread(*dispatcher_, false);
  overload_manager.registerForAction(
      OverloadActionNames::get().StopAcceptingConnections, *dispatcher_, ...);
  overload_manager.registerForAction(
      OverloadActionNames::get().RejectIncomingConnections, *dispatcher_, ...);
  overload_manager.registerForAction(
      OverloadActionNames::get().ResetStreams, *dispatcher_, ...);
}
```

  (摘录有删节,原文 worker_impl.cc:49-70,还注册了 CloseIdleHttpConnections)——TLS 注册、独立 dispatcher、ConnectionHandler、过载动作四件事全部 per-worker,main 线程从不替 worker 执行数据面逻辑。
- **连接如何固定到 worker**:监听 socket 由 ListenerManager 统一创建一次(`createListenSocket`,listener_manager_impl.cc:286-318;热重启时从父进程 `duplicateParentListenSocket`,356),随后把**同一个 listener 配置** post 给每个 worker 的 ConnectionHandler(listener_manager_impl.cc:1096-1104 → worker_impl.cc:72-81 → connection_handler_impl.cc:40)。默认 `BindType::NoReusePort` 即"所有 worker 共享一个已 bind 的 socket"(envoy/server/listener_manager.h:102-109),内核在共享 fd 上分散唤醒各 worker 的 epoll;配置 `reuse_port` 时每个 worker 独立 bind(同文件 107-108)。连接一经某 worker accept,其整个生命周期(含上游连接池、过滤器链)固定在该 worker 线程内,数据面无跨线程锁。
- **与 Nginx 的异同**:同——事件驱动、每执行单元一个 loop、连接固定不迁移;异——Nginx 是多进程 worker(地址空间隔离、统计靠共享内存、改配置靠 fork+reload),Envoy 是单进程多线程(堆共享、靠 TLS 消除读锁、改配置靠 xDS 推送,升级靠 hot restart 进程接力,README.md:20-21)。

## 7. ThreadLocal:无锁化的基石

`ThreadLocal::InstanceImpl`(thread_local_impl.h:16-25)用 **静态 `thread_local` 存储 + slot 索引** 实现(thread_local_impl.cc:17):

- **slot 分配**:`allocateSlot()` 只允许主线程调用(thread_local_impl.cc:28),从 `free_slot_indexes_` 复用空闲索引(31-41);slot 即全局唯一下标,`thread_local_data_.data_[index]` 存本线程对象(211-217)。
- **注册**:`registerThread(dispatcher, main_thread)` 记录 main dispatcher 或把 worker dispatcher 加入 `registered_threads_`(138-150)。
- **写入(set)**:`SlotImpl::set` 对每个注册线程 `dispatcher.post(...)`,在目标线程内构造对象,main 线程就地构造(124-136)——数据永远由"所属线程"自己写,读自然无锁。
- **广播**:Slot 暴露 `runOnAllThreads`(115-122),底层 post 到所有线程 + main 线程直呼(179-189);带完成回调的版本用 shared_ptr 引用计数实现"最后一个线程完成后回调"(191-209)。
- **销毁**:slot 析构只发生在 main 线程;worker 线程析构则 post 回 main(thread_local_impl.cc:47-71)。`removeSlot` 把所有线程的该索引置空并回收(152-177)。回调安全靠 `still_alive_guard_`(weak_ptr)防止 post 途中悬空(thread_local_impl.h:57-63, thread_local_impl.cc:73-113)。
- **关停**:`shutdownGlobalThreading`(219-223)先停全局更新,各线程 `shutdownThread` **按逆序**析构 slot,保证过滤器先于 cluster manager 等底座销毁(225-256,注释含完整理由)。

ClusterManager、Runtime、OverloadManager、stats store 等全部经 slot 下发——这就是"多线程、单进程、却几乎无锁"的机制来源。stats 的线程化生命周期同样绑定于此:`ThreadLocalStoreImpl::initializeThreading / shutdownThreading`(thread_local_store.cc:240, 250),由 server.cc:750 与 1107 驱动。

## 8. Admin 与 stats sink 的挂载点(函数级)

- **Admin 创建**:`AdminImpl` 在 server.cc:653-663 构造;**socket 监听**在 `AdminImpl::startHttpListener`(admin.cc:54-77,TcpListenSocket + `AdminListener`);**挂到 main 线程 ConnectionHandler** 在 `AdminImpl::addListenerToHandler`(admin.cc:556-561),由 server.cc:810 调用——即 Admin 是 main dispatcher 上的一个普通 listener,不占 worker。
- **路由表**:handlers 表在 `AdminImpl` 构造函数初始化列表静态写死(admin.cc:127 起):`/clusters`(131)、`/config_dump`(136)、`/logging`(196)、`/healthcheck/fail|ok`(182-185)等,分别委托给 clusters_handler_/config_dump_handler_/logs_handler_ 等成员对象(121-125);动态增删走 `addHandler`(admin.cc:517-523)。进程内直连入口是 `AdminImpl::request`(admin.cc:534-548);嵌入式用法见 `MainCommonBase::adminRequest`(main_common.cc:112-133):post 到 main dispatcher 执行。
- **stats sink**:bootstrap `stats_sinks` → `MainImpl::initializeStatsConfig` 逐个 `StatsSinkFactory::createStatsSink`(configuration_impl.cc:166-175)→ `stats_store_.addSink`(server.cc:866-868);定时刷写 `stat_flush_timer_`(server.cc:872-874),执行链 `flushStats → mergeHistograms → flushStatsInternal → InstanceUtil::flushMetricsToSinks`(server.cc:237-307,指标快照 225-235)。内置 sink 在 source/extensions/stat_sinks/。

## 9. OverloadManager 与 GuardDog(运行时守护)

- **OverloadManager**:创建于 server.cc:674-677,RunHelper 里 `start()`(server.cc:1028;overload_manager_impl.cc:570-614:TLS 状态 + 定时采样资源压力)。各组件在**自己的 dispatcher** 上 `registerForAction`(overload_manager_impl.cc:628-642);WorkerImpl 注册 StopAcceptingConnections / RejectIncomingConnections / ResetStreams / CloseIdleHttpConnections 四个动作(worker_impl.cc:57-69,响应实现 194-246)。
- **GuardDog(死锁看门狗)**:`GuardDogImpl` 构造(guarddog_impl.cc:33),周期 `step()` 检查各线程心跳并触发 MISS/MEGAMISS/KILL/MULTIKILL 动作(106-182);`createWatchDog/stopWatching`(191-211)。main 与 worker 各配一只(server.cc:883-888),worker 的 watch dog 在进入 dispatch loop 后才创建(worker_impl.cc:172-178)。
- **热重启**:parent/child 经 `shm_open` 共享内存交换统计与 listen fd(hot_restart_impl.cc:26-66 attachSharedMemory);child 启动后向 parent 发 admin shutdown 请求并继承 original_start_time(server.cc:641-649),全部 worker 就绪后再 `drainParentListeners`(server.cc:958-961)。
- **DrainManager 与生命周期回调**:全局 drain manager 只在 listener 修改(热重启)时触发(stripped_main_base.cc:31-37 注释与实现);排空序列 `startDrainSequence`(drain_manager_impl.cc:147-151),逐连接 `drainClose`(44-66)。扩展可订阅 `ServerLifecycleNotifier::Stage`(envoy/server/lifecycle_notifier.h:18;PostInit/Startup/ShutdownExit 等),由 `registerCallback`(server.cc:1167-1179)登记、`notifyCallbacksForStage`(server.cc:1181-1214)在 main 线程触发;带完成回调的变体要求 workers 已启动(1205 注释),这是ShutdownExit 优雅排空(如 access log flush)的实现基础。

## 10. 测试体系一瞥

- **布局**:单测目录与 source 一一对应(test/common、test/exe、test/server),扩展单测在 test/extensions,端到端在 test/integration("接近真实的 Envoy + fake downstream/upstream"),test/mocks 是 envoy/ 公共接口的全量 mock(REPO_LAYOUT.md:58-71)。
- **运行**:统一走 Bazel——`bazel test //test/...` 跑全部(bazel/README.md:400),单目标 `bazel test //test/common/http:async_client_impl_test`(409),`--test_output=streamed` 看实时日志(415);覆盖率由 test/coverage.yaml 与 test/run_envoy_bazel_coverage.sh 管理。测试入口 `TestRunner::runTests`(test/test_runner.h:7)。
- **两点补充**:配置类测试独立成 test/config_test(对 example 配置做启动级验证);fuzz 测试集中在 test/fuzz,以 libprotobuf-mutator 驱动解析类与过滤器代码路径(test/ 目录,REPO_LAYOUT.md:70-71 提及 fuzz/coverage 等工具目录)。另注意 bazel/README.md:431-432 还提供 `ENVOY_IP_TEST_VERSIONS=v4only/v6only` 的双栈测试开关,写 v4/v6 相关深读时可用。

## 11. 设计动机

1. **为什么单进程多线程而非多进程?** 连接固定 worker + 共享堆让 ClusterManager/路由表只存一份、统计天然聚合;配合 hot restart(parent/child 共享内存传 socket 与统计,hot_restart_impl.cc:26-66, server.cc:641-649)补齐了多进程方案"升级不断流"的优点,却避免多份地址空间开销与 reload 的全量重建。
2. **为什么 ThreadLocal slot 而不是锁?** 配置对象(cluster/LB/runtime)读多写少,以 slot 索引让每线程持有私有副本、由 main 线程经 post 单写多读(thread_local_impl.cc:124-136),换来数据面无锁读;slot 回收与逆序析构(152-177, 225-256)解决了跨线程生命周期这个最难的部分。
3. **为什么所有 IO 收敛到一个 event loop(libevent)?** 一个连接从 accept 到上游响应只被一个线程触碰,消除 per-request 锁与上下文切换;dispatcher 同时是定时器、post 队列、deferred deletion 的统一调度器(libevent_scheduler.cc:26-32, dispatcher_impl.cc:244/263/291),GuardDog 也只需盯住 loop 心跳即可发现死锁(guarddog_impl.cc:106-182)。
4. **为什么扩展以 filter 为中心?** Listener filter → L4 network filter → HCM → L7 http filter 构成统一管线抽象,router/tcp_proxy/redis_proxy 皆为 network filter,扩展只实现回调链、完全不感知线程模型;工厂注册表(server.cc:469-472 打印)使扩展可按站点裁剪编译(REPO_LAYOUT.md:78-83)。
5. **为什么 Bootstrap 与 xDS 分离?** 启动自举存在"先有 cluster 才能连上管理服务器"的鸡生蛋问题:bootstrap 提供静态种子(admin/静态资源/primary clusters,server.cc:757-770 注释、cluster_manager_impl.cc:369-375 注释),LDS/CDS/RDS/RTDS 随后经这些 cluster 下发(server.cc:845-860);这保证配置体系自身的依赖有序,也让"改配置"无需触碰进程生命周期。
6. **为什么 OverloadManager 早于一切初始化?** 让资源监控在任何模块注册动作之前就位(server.cc:673 注释),数据面各层声明式订阅压力动作(worker_impl.cc:57-69),而非各自硬编码降级逻辑;动作回调始终投递到注册线程自己的 dispatcher 执行(overload_manager_impl.cc:639-640),依旧不引入锁。

## 12. 三个常见误解的澄清

- "Envoy 是多线程所以有数据面锁竞争"——错:连接固定 worker + TLS 私有副本,稳态数据路径无锁;唯一的全局临界区集中在配置更新(main 线程单点写,thread_local_impl.cc:124-136)。
- "Admin 端口参与流量转发"——错:Admin listener 只挂到 main 线程的 handler(server.cc:810),与 worker 的 ConnectionHandler 互不相干。
- "改配置 = 重启/ reload"——错:LDS/CDS/RDS 常驻内存热更新,listener 有 warming/active/drain 三态由 ListenerManager 管理(listener_manager_impl.cc:594 addOrUpdateListenerInternal 起);只有二进制升级才需要 hot restart 进程接力。
- "hot restart 等价于 Nginx reload"——不完全:它靠共享内存 + socket 传递实现零断流与统计交接(hot_restart_impl.cc:26-66),但解决的是"换二进制",日常配置变更的正确路径仍是 xDS。

## 13. 初读路线(给后续报告的入口)

- 追一条 TCP 请求:connection_handler_impl.cc:40 → active_tcp_listener/active_tcp_socket → filter chain → tcp_proxy(source/extensions/filters/network/tcp_proxy/)。
- 追一条 HTTP 请求:connection_handler_impl.cc:40 → http_connection_manager → source/common/http/conn_manager_impl.cc → router(source/extensions/filters/http/router/)→ cluster_manager_impl.cc 选主机。
- 追一次配置下发:server.cc:845-856(LDS)/ configuration_impl.cc:141-144(CDS)→ source/common/config/(grpc mux 订阅)→ listener_manager_impl.cc:594(listener 三态)。
- 追一次统计:server.cc:237-307(flush 链)→ thread_local_store.cc:240(线程化)→ stat sink 扩展。

## 14. 写作素材清单(文件:行号)

1. source/exe/main.cc:24 — 生产入口的极简 main
2. source/exe/main_common.cc:34-51 — InstanceImpl 的工厂与 initialize 调用
3. source/exe/stripped_main_base.cc:64-74 — TLS 与 stats store 的最早创建
4. source/server/server.cc:757-770 — 官方初始化顺序注释(bootstrap→primary→RTDS→secondary)
5. source/server/server.cc:841 — config_.initialize(ClusterManager + 静态资源入口)
6. source/server/server.cc:865-874 — stats sinks 挂载与 flush timer
7. source/server/server.cc:990-1064 — RunHelper:信号/overload/RDS 暂停
8. source/server/server.cc:1097-1143 — terminate() 的镜像式退出顺序
9. source/server/configuration_impl.cc:112-159 — MainImpl::initialize 的资源装载顺序
10. source/common/upstream/cluster_manager_impl.cc:365-428 — 两阶段 cluster 装载与 ADS 初始化
11. source/common/listener_manager/listener_manager_impl.cc:1096-1131 — listener 播发给 worker + worker->start
12. source/server/worker_impl.cc:168-192 — worker 线程主循环与退出顺序
13. source/common/thread_local/thread_local_impl.cc:124-136 — Slot::set 的 per-thread post 写入
14. source/common/thread_local/thread_local_impl.cc:225-256 — shutdownThread 的逆序析构注释
15. source/server/admin/admin.cc:54-77 — startHttpListener:Admin 监听挂载
16. source/server/overload_manager_impl.cc:570-614 — OverloadManager::start 的 TLS + 定时采样
