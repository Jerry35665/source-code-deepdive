# B2 · 扩展沙箱:Wasm 与 Lua filter

> 基线:tag `v1.39.1`,commit `b579d07d3ad7ee11d32b105e91a5a39ad24718d7`。
> 所有 `文件:行号` 均以仓库根为相对路径,并经本报告实际 Read/Grep 核对。
> 两条技术路线:Wasm(proxy-wasm ABI,独立 VM,多运行时后端)与 Lua(LuaJIT,per-worker 状态机 + 协程挂起)。前者面向强隔离的多语言插件生态,后者面向内嵌的轻量脚本定制。

## 0. 总览图

```
【Wasm】每 worker 一份 VM 克隆,一条流的回调走 ABI 穿栈
 main thread                         worker thread (每线程一份)
 ┌──────────────────────┐            ┌────────────────────────────────────────┐
 │ PluginConfig         │            │  ThreadLocal PluginHandle (TLS slot)   │
 │  ├ createWasm()      │  构造+克隆  │   └ WasmHandle ──► Wasm(克隆 VM 实例)  │
 │  ├ base_wasm_(首建)  │ ─────────► │       ├ WasmVm(V8/WAMR/Wasmtime/Null)  │
 │  └ failure_policy    │            │       ├ RootContext(每 plugin 一个)    │
 └──────────────────────┘            │       └ Context(每流一个=StreamFilter)│
                                     └────────────────────────────────────────┘
  upcall(VM→宿主入口):  on_vm_start / on_configure / on_request_headers /
                          on_request_body / on_response / on_tick / on_done ...
  downcall(宿主→VM 导出): get_header_map_value / http_call / define_metric /
                          log / get_property / set_shared_data ...
                     ▲ 两端按 proxy-wasm ABI 以 (ptr,size) 交换线性内存 ▼

【Lua】每 worker 一个 lua_State,每条流一个 coroutine
 worker thread
 ┌───────────────────────────────────────────────────────────┐
 │ PerLuaCodeSetup(每份脚本代码一个)                        │
 │  └ ThreadLocalState ──► TLS: lua_State(luaL_openlibs+编译)│
 │       ├ global ref: envoy_on_request / envoy_on_response  │
 │       └ createCoroutine() = lua_newthread(轻量,每流一个) │
 │ Filter(decodeHeaders)                                     │
 │   └ coroutine.start(envoy_on_request)                     │
 │        ├ 脚本 handle:body()   → lua_yield → State::WaitForBody    │
 │        │                     Filter 返回 StopIterationAndBuffer   │
 │        ├ 脚本 handle:httpCall()→ lua_yield → State::HttpCall      │
 │        │                     AsyncClient 响应后 resumeCoroutine   │
 │        └ 脚本 return          → State::Finished → Continue        │
 └───────────────────────────────────────────────────────────┘
```

---

## 1. Wasm:proxy-wasm ABI 与宿主桥

### 1.1 分层:Envoy 只做宿主,ABI 在 pinned 依赖里

Envoy 的 Wasm 支持分三层:`source/extensions/common/wasm/`(宿主公共层)、`source/extensions/wasm_runtime/`(运行时后端注册)、`source/extensions/filters/http/wasm/`(薄 HTTP filter 壳)。真正的 ABI 语义(入口分发、线性内存编解码、共享数据/队列)在上游 `proxy-wasm-cpp-sdk`(插件侧)与 `proxy-wasm-cpp-host`(宿主侧)中,以固定 commit 引入:`bazel/repository_locations.bzl:622-630`(sdk `e5256b0c`,host `f2db56af`)。

宿主侧的 C++ 抽象全部继承自 proxy-wasm 基类:`Wasm : WasmBase`(`source/extensions/common/wasm/wasm.h:44`)、`WasmHandle : WasmHandleBase + ThreadLocalObject`(`wasm.h:125`)、`PluginHandle`(`wasm.h:138`)与 `Context : ContextBase`(`source/extensions/common/wasm/context.h:107`)。

ABI 的入口(upcall)由 proxy-wasm 的 `ContextBase` 按 ABI 版本分发到 VM 导出函数 `proxy_on_vm_start / proxy_on_configure / proxy_on_request_headers / proxy_on_request_body / proxy_on_response_headers / proxy_on_response_body / proxy_on_done / proxy_on_tick` 等;Envoy 侧 Context 覆写的是宿主 downcall 与流量回调。Envoy 还在 ABI 之外补了两个私有入口:`on_resolve_dns` 与 `on_stats_update`,经 `Wasm::getFunctions()` 从 VM 取函数指针,并注册宿主函数 `envoy_resolve_dns`(`source/extensions/common/wasm/wasm.cc:185-201`);NullVm 路径下这两个入口以宿主函数形式提供(`source/extensions/common/wasm/wasm_vm.cc:41-73`),扩展 SDK 基类见 `source/extensions/common/wasm/ext/envoy_proxy_wasm_api.h:17-24`。

### 1.2 流生命周期:Context 即 StreamFilter

`Context` 是"多重身份"类:同时是 `proxy_wasm::ContextBase`、`Http::StreamFilter`、`AccessLog::Instance`、`Network::Filter` 等(`source/extensions/common/wasm/context.h:107-114`)。因此 Wasm filter 不需要独立的 per-stream filter 类——Envoy 的 FilterManager 直接把 `Context` 插进过滤链,每个 decode/encode 回调转成一次 ABI upcall:

```cpp
// source/extensions/common/wasm/context.cc:1661-1670
Http::FilterHeadersStatus Context::decodeHeaders(Http::RequestHeaderMap& headers, bool end_stream) {
  onCreate();
  request_headers_ = &headers;
  end_of_stream_ = end_stream;
  auto result = convertFilterHeadersStatus(onRequestHeaders(headerSize(&headers), end_stream));
  if (result == Http::FilterHeadersStatus::Continue) {
    request_headers_ = nullptr;
  }
  return result;
}
```

`onRequestHeaders/onRequestBody/onResponseHeaders/onResponseBody` 是 `ContextBase`(proxy-wasm)的方法,它们把 header 大小、end_of_stream 压参后调进 VM;返回的 Stop/Continue 再映射回 Envoy 的 `FilterHeadersStatus`。stop-and-buffer 语义由宿主记忆:`decodeData` 里 `buffering_request_body_` 置位后持续把数据转存 `decoder_callbacks_->addDecodedData`,直到 413 触发或 VM 放行(`context.cc:1672-1705`)。流结束时 `Http::StreamFilterBase::onDestroy()` 触发 `onDone()/onDelete()` upcall(`context.cc:1498-1505`)。定时器 upcall 挂在根上下文上:`setTimerPeriod` 创建 dispatcher timer,`tickHandler` 调 `context->onTick(0)` 并自续周期(`source/extensions/common/wasm/wasm.cc:106-140`)。

### 1.2.1 配置投递:vm_configuration 与 plugin_configuration 两级

VM 启动与插件配置在 ABI 上分两步:VM 级 `vm_config.configuration` 与插件级 `plugin.configuration` 都是 `Any`/bytes,插件里分别通过 `proxy_get_configuration` 取到。宿主侧 `Context::getConfiguration()` 按上下文身份返回:流/根上下文(持 `temp_plugin_` 时)返回插件配置,VM 上下文返回 VM 配置(`source/extensions/common/wasm/context.cc:1194-1200`)。根上下文按 plugin 寻址:`Wasm::getRootContext` 委托 `WasmBase` 按 plugin 建/查(`wasm.h:54-56`),`PluginHandle::rootContextId()` 在每次取流上下文时解析根 id(`wasm.h:146`)。`on_vm_start/on_configure` 的调用时序由 proxy-wasm host 在 `createWasm`/克隆后驱动,Envoy 侧不参与,只负责把配置原文送进去。

### 1.3 VM 抽象与多后端工厂

低层 VM 由 `createWasmVm(runtime)` 创建(`source/extensions/common/wasm/wasm_vm.h:44`),实现走注册表:每个后端一个 `WasmRuntimeFactory`,category 为 `envoy.wasm.runtime`(`source/extensions/common/wasm/wasm_runtime_factory.h:16-22`)。四个后端各自只有几行注册代码:

- V8:`V8RuntimeFactory::createWasmVm() → proxy_wasm::createV8Vm()`,`source/extensions/wasm_runtime/v8/config.cc:12-21`;
- WAMR:`source/extensions/wasm_runtime/wamr/config.cc`(同构);
- Wasmtime:`source/extensions/wasm_runtime/wasmtime/config.cc`(同构,不在官方构建中,`api/envoy/extensions/wasm/v3/wasm.proto:102-105`);
- Null(`envoy.wasm.runtime.null`):无沙箱,Wasm 模块以原生代码编进 Envoy 二进制,用于测试与内联(`source/extensions/wasm_runtime/null/config.cc:12-19`;proto 注释 `wasm.proto:90-91`)。

未指定 runtime 时按 v8 → wasmtime → wamr 顺序取第一个可用引擎:

```cpp
// source/extensions/common/wasm/wasm_vm.cc:80-89
absl::string_view getFirstAvailableWasmEngineName() {
  constexpr absl::string_view wasm_engines[] = {
      "envoy.wasm.runtime.v8", "envoy.wasm.runtime.wasmtime", "envoy.wasm.runtime.wamr"};
  for (const auto wasm_engine : wasm_engines) {
    if (isWasmEngineAvailable(wasm_engine)) {
      return wasm_engine;
    }
  }
  return "";
}
```

proto 注释同样写明优先级(`wasm.proto:84-85`)。`createWasmVm` 还挂上 `EnvoyWasmVmIntegration`,把 Envoy 日志级别/日志器接进 VM(`wasm_vm.cc:21-39,107`)。

### 1.4 隔离模型:base VM + 每线程克隆,vm_id/root_id 决定共享

关键结构在 `PluginConfig`(`wasm.h:187-229`):主线程先通过 `createWasm()` 建"base Wasm"(含 base VM),再把 `PluginHandle` 放进 TLS slot;每个 worker 首次访问时用 `Wasm(WasmHandleSharedPtr, Dispatcher)` 克隆构造函数复制出该线程自己的 VM 实例(`wasm.cc:86-102`),即"每 worker 独立 VM、无跨线程共享内存访问",克隆由 `proxy_wasm::getOrCreateThreadLocalPlugin` 按 vm_key 去重(`wasm.cc:466-483`)。

共享粒度由两个配置键决定:`vm_id` + 代码哈希相同的 plugin 共用同一个 VM(降内存、便于共享数据,proto 注释明确提示这有安全含义,`wasm.proto:76-81`);同一 `vm_id` 下 `root_id` 相同的 plugin(比如一个 Wasm HTTP filter + 一个 Wasm access log)共享同一个 RootContext(`wasm.proto:151-154`)。Envoy 侧还把环境变量哈希拼进 vm_key,env 变更等价于代码变更、触发 VM 重建(`wasm.cc:378-384`)。跨线程投递(共享队列唤醒等)由 `Wasm::callOnThreadFunction` 桥到本线程 dispatcher(`wasm.cc:202-206`);Envoy 侧 per-root timer 表也印证"root 状态只在线程内"(`wasm.h:107`)。

### 1.5 资源与限制:没有燃料表,失败靠 fail policy

- **无 fuel / 指令上限**:整个 `source/extensions/` 与 `wasm.proto` 中 grep 不到 fuel/instruction-limit/heap-limit 配置;`VmConfig` 仅有 runtime、code、allow_precompiled、nack_on_code_cache_miss、environment_variables 等字段(`wasm.proto:73-140`)。恶意或失控插件的唯一约束是引擎自身(OOM→fail_state)。
- **capability 白名单(未完成)**:`capability_restriction_config` 能配置 `allowed_capabilities`,但 sanitization 字段是空 TODO,Envoy 只把名字透传给 proxy-wasm(`source/extensions/common/wasm/plugin.cc:12-16`;空 proto `wasm.proto:53-58`)。
- **环境变量注入**:`key_values` 与 `host_env_keys` 合并注入 VM;NullVm 禁用 key_values 以免直接改 Envoy 进程环境(`plugin.cc:18-54`)。
- **失败策略**:FAIL_CLOSED / FAIL_OPEN / FAIL_RELOAD 三态,legacy `fail_open` 归一化处理(`source/extensions/common/wasm/wasm.cc:574-612`);FAIL_RELOAD 仅针对 `RuntimeError`,带 jitter 退避地重建线程本地插件(`wasm.cc:488-542`)。fail-open 时 `PluginConfig::createContext()` 直接返回 nullptr(不加 filter),fail-closed 返回空 Context 吞流量回调(`wasm.cc:652-671`)。
- **超时**:httpCall/grpcCall 的 timeout 由插件按次传参(`context.cc:882-912`);脚本本身无执行时限。
- **可观测性兜底**:VM 生命周期事件全部打点(VmCreated/VmShutDown/UnableToCreateVm/RuntimeError/…,`wasm.cc:281-304` 与 `wasm.cc:82-83,143-144`),配合 `wasm.<name>.` 前缀的 per-plugin stats(`wasm.cc:614`),把"哪个插件、哪次失败、是否重载"串成一条可查的证据链。

### 1.6 与 Envoy API 的桥

宿主 downcall 全部在 `Context` 上(header/trailer/metadata 六类 map 操作、buffer、metric、grpc,`context.h:227-267`);几条代表性路径:

- **header 操作**:`getHeaderMapValue` 等按 `WasmHeaderMapType` 找到当前流上的 map 指针(`context.h:414-421` 缓存的原始指针)直接读写;ABI 0.2.1 之前改请求头会主动 `clearRouteCache()`(`context.h:383-389`)。
- **HTTP callout**:`Context::httpCall` 走 cluster manager 的 `httpAsyncClient().send`,token 记入 `http_request_` 表,响应经 `AsyncClientHandler::onSuccess` 回到 VM 的 `on_http_call_response`(`context.cc:879-935`;handler 结构 `context.h:299-318`)。gRPC call/stream 同构(`context.cc:937-985`)。
- **getProperty/CEL**:`proxy_get_property` 的 path(NUL 分隔)被逐段求值在 CEL activation 上,支持 map/message/list 遍历(`context.cc:547-619`)——Wasm 插件读流信息的统一入口。
- **metrics**:`defineMetric/incrementMetric/recordMetric` 映射到 Envoy stats(`context.h:251-254`,实现 `context.cc:1218` 起)。
- **shared kv(SHM)**:`proxy_set_shared_data`/共享队列的存储与 CAS 语义在 proxy-wasm host 的 `WasmBase`(外部依赖);Envoy 提供的是跨线程投递与根上下文寻址(`wasm.cc:202-206,127-140`)。
- **foreign functions**:Envoy 注册了 `verify_signature/sign/compress/uncompress/set_envoy_filter_state/clear_route_cache/declare_property/expr_create/expr_evaluate` 等宿主函数(`source/extensions/common/wasm/foreign.cc:94-234,328-330,371-373,434-436`),是 ABI 之外的能力逃生门。

### 1.7 配置加载:local 即读,remote HTTP+sha256 缓存(无 OCI)

`createWasm()`(`wasm.cc:306-464`)先取代码:`code.local` 用 `Config::DataSource::read`(文件或 inline bytes,`wasm.cc:370-375`);`code.remote` 是 HTTP URI + 强制 sha256 校验,配一个进程级 `code_cache`(带 24h TTL 与 10s 负缓存,`wasm.cc:31-36,54-60`)。缓存命中/未命中/抓取成败都会打点(`RemoteLoadCacheHit/Miss/FetchSuccess/FetchFailure`,`wasm.cc:337-368,420-427`),可直接用于诊断"配置下发成功但插件代码没到"的场景。远程拉取有两种模式:`nack_on_code_cache_miss=true` 时先 NACK 配置、后台 `RemoteDataFetcher` 填缓存(`wasm.cc:442-454`);否则用 `RemoteAsyncDataProvider` 异步拉取(`wasm.cc:456-459`)。注释明确"xDS 无法异步报错",所以未命中缓存时立即失败(`wasm.cc:428-436`)。**没有 OCI 镜像拉取**——远程就是普通 HTTP GET + 哈希校验。拿到代码后交给 `proxy_wasm::createWasm`,同时传入 base 工厂与克隆工厂(`wasm.cc:394-398`)。远程加载至今标记为不稳定并打 warning(`wasm.cc:318-320`)。

### 1.8 HTTP Wasm filter:一个继承壳

filter 层几乎零逻辑:`FilterConfig : PluginConfig` 三个构造重载(downstream/upstream/server 上下文,`source/extensions/filters/http/wasm/wasm_filter.h:19-29` 与 `wasm_filter.cc:22-38`),工厂注册名即 `envoy.filters.http.wasm`(`source/extensions/filters/http/wasm/config.cc:14-15`)。流级对象就是 `PluginConfig::createContext()` 返回的 `Context`。因为 `Context` 同时实现了 `Network::Filter`/`Network::ConnectionCallbacks`(`context.h:157-169`),同一套 ABI 也能挂在网络过滤链与 TCP 场景;`continueStream/closeStream` 里对 `WasmStreamType::Downstream/Upstream` 的分支即网络侧通路(`context.cc:1507-1538,1540-1556`)。

### 1.9 代理之外的同一套基建

`source/extensions/common/wasm/` 不只服务 HTTP filter:同一 `PluginConfig` 被复用在 Wasm access log(`source/extensions/access_loggers/wasm/wasm_access_log_impl.h`,`Context : AccessLog::Instance` 的来源)、Wasm stats sink(`source/extensions/stat_sinks/wasm/`,对应 `Wasm::onStatsUpdate`,`wasm.h:75,230-233`)以及 bootstrap 级 WasmService(无方向、可 singleton,`source/extensions/bootstrap/wasm/config.cc:16-32`)。这意味着一个插件可以在一个 VM 里同时充当 filter + logger + sink,只要 `root_id` 相同即共享 RootContext(见 1.4)。生命周期计数(`wasm.lifecycle` created/active/…)在 `Wasm` 构造/析构时更新(`wasm.cc:80-83,142-145`;实现 `source/extensions/common/wasm/stats_handler.cc:77-82`),是运维观察 VM 数量的主要抓手。

---

## 2. Lua:per-worker 状态机与协程式挂起

### 2.1 生命周期:主线程验证一次,每 worker 编译一次

Lua 侧的入口是 `PerLuaCodeSetup`(每份脚本代码一个,持有一个 `ThreadLocalState`;注释写明 VM 数为 `concurrency + 1`,`source/extensions/filters/http/lua/lua_filter.h:33-60`)。`ThreadLocalState` 构造时先在主线程建临时 state 做 `luaL_dostring` 语法验证、失败即抛配置错误(`source/extensions/filters/common/lua/lua.cc:82-96`),再经 TLS slot 在每个 worker 上各建一个 `lua_State` 并编译同一份代码(`lua.cc:128-135`)——这就是"编译缓存":编译产物以全局函数形式驻留,per-request 零编译。`envoy_on_request/envoy_on_response` 两个全局被 `registerGlobal` 换成 `luaL_ref` 引用号(`lua.cc:104-121`;注册点 `lua_filter.cc:246-254`),并顺带把 20+ 个宿主类型注册进 metatable(`lua_filter.cc:210-232`)。运行时是 LuaJIT 2.1 滚动版(`bazel/repository_locations.bzl:264-270`),语言版本约 5.1(`docs/root/configuration/http/http_filters/lua_filter.rst:8-11`)。

### 2.2 挂起/恢复:coroutine + 状态枚举 + FilterManager 配合

每条流在 doHeaders 时 `createCoroutine()`(本质 `lua_newthread`,`lua.cc:123-126`)并启动全局函数(`source/extensions/filters/http/lua/lua_filter.cc:916-942`)。协程内脚本调 `handle:body()/httpCall()/trailers()` 时,包装器置状态并 `lua_yield`;宿主侧凭 `State` 枚举(`lua_filter.h:171-184`:Running/WaitForBodyChunk/WaitForBody/WaitForTrailers/HttpCall/Responded)决定返回给 FilterManager 的 FilterStatus:

```cpp
// source/extensions/filters/http/lua/lua_filter.cc:273-286
Http::FilterHeadersStatus StreamHandleWrapper::start(int function_ref) {
  // We are on the top of the stack.
  coroutine_.start(function_ref, 1, yield_callback_);
  Http::FilterHeadersStatus status =
      (state_ == State::WaitForBody || state_ == State::HttpCall || state_ == State::Responded)
          ? Http::FilterHeadersStatus::StopIteration
          : Http::FilterHeadersStatus::Continue;
  ...
}
```

恢复点与状态一一对应:下一个 body chunk 到来时 `onData` 按 `WaitForBodyChunk` 用新 chunk resume、按 `WaitForBody`(end_stream)补齐缓冲后 resume,`HttpCall` 未决期间保持 `StopIterationAndWatermark`(`lua_filter.cc:288-321`)。`body()`/bodyChunks 迭代器/trailers 的 yield 点分别在 `lua_filter.cc:557-599,614-625,627-646`。协程驱动的核心只有十几行:

```cpp
// source/extensions/filters/common/lua/lua.cc:61-80
void Coroutine::resume(int num_args, const std::function<void()>& yield_callback) {
  ASSERT(state_ == State::Yielded);
  int rc = lua_resume(coroutine_state_.get(), num_args);

  if (0 == rc) {
    state_ = State::Finished;
    ENVOY_LOG(debug, "coroutine finished");
  } else if (LUA_YIELD == rc) {
    state_ = State::Yielded;
    ENVOY_LOG(debug, "coroutine yielded");
    yield_callback();
  } else {
    state_ = State::Finished;
    const char* error = lua_tostring(coroutine_state_.get(), -1);
    if (!error) {
      error = "unspecified lua error";
    }
    throw LuaException(error);
  }
}
```
`httpCall` 的闭合环在 `doHttpCall` 里 `lua_yield`(`lua_filter.cc:418-434`),AsyncClient 响应回来后 `onSuccess` 压返回值再 `resumeCoroutine(2, ...)`,并在协程已跑完时补一个 `callbacks_.continueIteration()` 让 FilterManager 继续走链(`lua_filter.cc:436-514`)。`lua_resume` 的三种结局(完成/YIELD/错误)在 `Coroutine::resume` 中归一,YIELD 触发 yield_callback 校验"yield 只能发生在已知阻塞点"(`source/extensions/filters/common/lua/lua.cc:61-80`;意外 yield 在 `lua_filter.cc:266-270` 直接抛错)。协程与 stream wrapper 的所有权上提到 Filter 层以打破 yield 时的循环引用(`lua_filter.h:706-719`);流销毁时 `onDestroy→onReset` 取消未决 HTTP 请求(`lua_filter.cc:906-914`)。

`respond()` 是第四种 yield:构造响应、校验 200-599 后置 `State::Responded` 并 yield,直接终结脚本(`lua_filter.cc:355-384`);若请求头已放行则拒绝调用(`lua_filter.cc:358-360`)。请求/响应两个方向各自持有独立的 coroutine 与 StreamHandleWrapper(`lua_filter.h:718-724`),所以一个脚本可同时 hook 两端而互不干扰。

### 2.2.1 路由级脚本:第三种代码来源

除 `inline_code` 与 `default_source_code` 互斥的二选一(`lua_filter.cc:862-875`)外,还支持命名脚本表 `source_codes`(`lua_filter.cc:877-886`)与路由级覆盖 `LuaPerRoute`:`disabled` / `name`(引用命名脚本)/ 路由内联 `source_code`(`lua_filter.cc:889-904`)。运行时按"最具体 per-route 配置优先"解析出实际执行的 `PerLuaCodeSetup`(`lua_filter.h:663-685`)。注意每份脚本代码都是一个独立 Lua state,路由脚本会增加 `concurrency + 1` 个 VM(`lua_filter.h:33-35`)。脚本抛错统一进 `scriptError`:计 errors、复位两个方向的 wrapper(本次流不再执行脚本),但请求本身继续(`lua_filter.cc:973-978`)。

### 2.3 沙箱边界:API 面是白名单,拦截靠生命周期而非解释器

- **可用 API 面**:脚本唯一入口是 stream handle,导出函数表即契约:`headers/body/bodyChunks/trailers/metadata/httpCall/respond/streamInfo/connection/importPublicKey/verifySignature/base64Escape/timestamp/timestampString/connectionStreamInfo/setUpstreamOverrideHost/clearRouteCache/filterContext/virtualHost/route/stats`(`lua_filter.h:208-230`)。header 修改经 `HeaderMapWrapper` 的 add/get/remove/replace 等 8 个方法(`source/extensions/filters/http/lua/wrappers.h:47-56`),修改是否合法由 `CheckModifiableCb` 回调把关(`wrappers.h:43-45`);自定义指标经 `StatsScopeWrapper→Counter/Gauge/Histogram`(`wrappers.h:660-695`)。
- **"禁止"的本质**:宿主确实调用了 `luaL_openlibs`,标准库(含 io/os)在解释器层面是打开的(`lua.cc:88,132`);沙箱性来自三条软约束——文档契约"禁止阻塞操作、一切 IO 走 Envoy API"(`docs/root/configuration/http/http_filters/lua_filter.rst:23`)、API 面刻意保持极小(`lua_filter.rst:25-27`)、以及 `BaseLuaObject` 的 markDead/checkDead 机制让跨 yield 持有的包装器立刻变成 Lua 错误(`source/extensions/filters/common/lua/lua.h:219-233`;headers/iterators 不跨 yield,`lua_filter.h:393-408`、`wrappers.h:110-113`)。
- **内存可见性**:`runtimeBytesUsed/runtimeGC` 暴露 per-state GC 统计(`lua.h:506-515`);脚本错误只计 stats 不炸进程(`lua_filter.cc:973-978`)。
- **无 IO/时钟原语**:时间只能经 `timestamp/timestampString` 取(`lua_filter.h:333-347`),没有 socket/file API 被 bridge 进来。

### 2.3.1 观测与失败语义

filter 只有两个计数器 `executions/errors`(`lua_filter.h:23-30`);每次 doHeaders 执行即 +1(双向 hook 会记 2,注释明示是有意为之,`lua_filter.cc:931-938`)。VM 数量暴露为共享 gauge `lua.lua_vm_count`,每份代码固定加 `concurrency + 1`,析构时减回(`lua_filter.cc:256-259`)。错误路径只复位 wrapper、日志 err、计 errors,流继续走——Lua 没有"WASM 式整 VM 失败"的概念,失败域天然只有单条流。

### 2.4 与 Wasm 的取舍

| 维度 | Lua | Wasm |
|---|---|---|
| 语言 | 仅 Lua(LuaJIT 5.1) | C++/Rust/AssemblyScript/Go 等 SDK |
| 隔离 | 同进程解释执行,标准库未裁剪(`lua.cc:132`) | 线性内存沙箱 + 每线程独立 VM(`wasm.cc:86-102`);NullVM 例外 |
| 挂起模型 | coroutine yield/resume,同步写法(`lua.cc:61-80`) | 回调式 ABI,Stop/Continue 由插件返回 |
| 开销 | lua_newthread 极轻,零拷贝 userdata 包装 | 每次调用穿 ABI + 内存编解码;VM 常驻内存 |
| 能力面 | 单一 stream handle,面小而稳 | proxy-wasm 全集 + foreign functions + 根上下文定时器/共享 kv |
| 失败域 | 脚本错误→errors 计数,流继续 | RuntimeError→FAIL_RELOAD 整 VM 重建(`wasm.cc:488-542`) |

两点补充让取舍更立体。其一,生成方式不同:Wasm 插件的头/体操作要经过 ABI 的字符串编解码(每次 get/set 都是跨线性内存拷贝),Lua 的 HeaderMapWrapper 则直接持有 `Http::HeaderMap&`(`wrappers.h:125`)在栈上操作,单次调用量级更便宜;但 Wasm 的 JIT 化计算密集逻辑(解析、签名、正则)远快于 LuaJIT 解释执行。其二,演进速度不同:Lua 的 API 面由 Envoy 的 C++ 包装直接定义、随版本加方法(如 stats/override host 都是后加的,`wrappers.h:656-695`、`lua_filter.cc:980-998`);Wasm 的能力面必须先动 proxy-wasm ABI 或注册 foreign function(`foreign.cc:94-234`),前者慢但跨实现,后者快但只属于 Envoy。

文档示例位置:Lua filter 主示例 `docs/root/configuration/http/http_filters/_include/lua-filter.yaml`(`default_source_code.inline_string` 定义 `envoy_on_request/envoy_on_response`),API 手册 `docs/root/configuration/http/http_filters/lua_filter.rst`(1967 行);Wasm filter 示例经 literalinclude 引 `start/sandboxes/_include/wasm-cc/envoy.yaml`(`docs/root/configuration/http/http_filters/wasm_filter.rst:22-40`,注意该文档开头保留 experimental 提示,`wasm_filter.rst:7-12`)。

---

## 3. 设计动机

1. **为什么双轨 Wasm + Lua**:两者服务不同门槛——Lua 让运维用十几行脚本改头/短路的场景零编译、零 ABI 开销;Wasm 面向需要强隔离、任意语言和三方分发生态的插件市场。Envoy 把两者的 per-stream 抽象都落在 `Http::StreamFilter` 上(Lua 的 `Filter`,`lua_filter.h:528`;Wasm 直接是 `Context`,`context.h:110`),上层 FilterManager 无感差异。
2. **为什么 proxy-wasm ABI 而非自研插件接口**:ABI 是跨 SDK(C++/Rust/…)的稳定边界,入口/导出函数、(ptr,size) 传参、ABI 版本协商都由 proxy-wasm 定义,Envoy 只写宿主桥(`wasm.cc:185-201`);pin 上游 commit(`repository_locations.bzl:622-630`)让 Envoy 跟随多厂商(Istio 等)共享同一插件生态,而不是各造各的。
3. **为什么 V8/WAMR/Wasmtime/Null 多后端**:运行时是编译期可选的注册扩展(`wasm_runtime_factory.h:16-22`),不同发行版按体积/性能/维护取舍裁剪(官方主推 V8,WAMR/Wasmtime 不进官方构建,`wasm.proto:97-105`),NullVM 则给测试和嵌入场景一个零沙箱直通路(`null/config.cc:12-19`)。默认引擎按 v8→wasmtime→wamr 兜底(`wasm_vm.cc:80-89`)。
4. **为什么 Lua 每 worker 一个 state**:Lua state 非线程安全,而 Envoy 的全部 worker 并行模型靠 TLS 复制(`lua.cc:95,128-135`);注释直言"没有真正的全局状态"(`lua.h:466-468`)。代价是全局表不共享,收益是脚本内零锁、GC 独立、单个 state 崩坏不外溢。
5. **为什么 Wasm 也按线程克隆而不是共享一个 VM**:与 Envoy"每 worker 独立调度、无锁"的线程模型对齐(`wasm.cc:86-102,631-639`),流上下文只在本线程存活;跨 worker 只留共享 kv/队列这一条显式通道,并经 dispatcher 投递回属主线程(`wasm.cc:202-206`)。
6. **为什么没有 fuel/指令上限**:工程上 V8/WAMR 的 metering 支持参差、且代理场景插件是自己人(下发通道本身受 xDS 信任模型保护);Envoy 选择的兜底是 fail_state + FAIL_RELOAD 整体换新(`wasm.cc:488-542`)与 timeout 参数化(`context.cc:882-912`),把"跑飞"的代价控制在可重建单元,同时避免每次调用付 fuel 计数税。
7. **为什么 Lua 脚本写成同步风格**:协程把"异步回调地狱"压平成 `body()`、`httpCall()` 这样的顺序调用,宿主借 yield 恢复点精确接管 buffering 与继续时机(`lua_filter.cc:288-321`),这正是 Lua 路线对插件作者的核心让利;也是文档第一条铁律"禁止阻塞操作"的由来(`lua_filter.rst:23`)。

---

## 4. 写作素材清单(文件:行号)

1. `source/extensions/common/wasm/wasm.h:44` —— `Wasm : WasmBase` 宿主执行实例。
2. `source/extensions/common/wasm/wasm.h:125-163` —— WasmHandle/PluginHandle/ThreadLocal 包装(TLS 载体)。
3. `source/extensions/common/wasm/wasm.cc:86-102` —— 线程本地 VM 克隆构造函数。
4. `source/extensions/common/wasm/wasm.cc:306-464` —— createWasm:local/remote 代码、code cache、vm_key。
5. `source/extensions/common/wasm/wasm.cc:488-542` —— FAIL_RELOAD 退避重载。
6. `source/extensions/common/wasm/wasm_vm.cc:75-109` —— 后端注册表查找与默认引擎顺序。
7. `source/extensions/common/wasm/context.h:107-114` —— Context 的多重身份(ABI+StreamFilter+AccessLog…).
8. `source/extensions/common/wasm/context.cc:879-935` —— Context::httpCall 宿主桥全路径。
9. `source/extensions/common/wasm/context.cc:1498-1538` —— onDestroy→onDone 与 continueStream 的延迟续转。
10. `source/extensions/common/wasm/foreign.cc:94-234` —— Envoy 扩展 foreign functions(签名/压缩/过滤状态)。
11. `source/extensions/wasm_runtime/v8/config.cc:12-21` —— V8 后端注册(对照 null/wamr/wasmtime)。
12. `source/extensions/filters/http/wasm/wasm_filter.h:19-29` —— filter 层继承 PluginConfig 的薄壳。
13. `source/extensions/filters/common/lua/lua.cc:61-135` —— Coroutine start/resume 与 ThreadLocalState/TLS 编译。
14. `source/extensions/filters/http/lua/lua_filter.h:171-184` —— StreamHandleWrapper 状态枚举(挂起原因表)。
15. `source/extensions/filters/http/lua/lua_filter.cc:288-321` —— onData:按状态 resume + StopIteration 映射。
16. `source/extensions/filters/http/lua/lua_filter.cc:386-514` —— httpCall 的 yield→AsyncClient→resume 闭环。
17. `source/extensions/filters/http/lua/wrappers.h:41-130` —— HeaderMapWrapper API 面与 CheckModifiableCb。
18. `api/envoy/extensions/wasm/v3/wasm.proto:76-81,151-161` —— vm_id/root_id 共享语义的权威注释。
19. `docs/root/configuration/http/http_filters/lua_filter.rst:8-27` —— Lua 设计三原则(LuaJIT/每线程/协程/禁阻塞)。
20. `docs/root/configuration/http/http_filters/_include/lua-filter.yaml:23-33` —— Lua 配置示例位(default_source_code)。
21. `source/extensions/common/wasm/context.cc:1194-1200` —— getConfiguration 的 VM/插件两级配置投递。
22. `source/extensions/common/wasm/wasm.cc:106-140` —— setTimerPeriod/tickHandler:根上下文定时器与 on_tick upcall。
23. `source/extensions/common/wasm/context.cc:1672-1705` —— decodeData 的 stop-and-buffer 语义。
24. `source/extensions/filters/http/lua/lua_filter.cc:355-384` —— luaRespond:第四种 yield(直连响应)。
25. `source/extensions/filters/http/lua/lua_filter.cc:862-904` —— 三种脚本来源与 LuaPerRoute 路由级覆盖。
26. `source/extensions/bootstrap/wasm/config.cc:16-32` —— bootstrap WasmService:同一 PluginConfig 复用到代理之外。

## 5. 一句话收束

Wasm 路线的本质是"把 proxy-wasm ABI 作为跨语言插件的稳定边界,Envoy 提供 per-worker VM 克隆 + 宿主桥 + fail-reload 兜底";Lua 路线的本质是"把 LuaJIT 协程当作挂在 FilterManager 状态机上的可暂停函数,每 worker 一个 state,挂起点即缓冲决策点"。两者在 Envoy 内共享同一个流量抽象(StreamFilter),却在隔离、能力面与失败域上刻意互补——读懂这一对,就读懂了 Envoy 对"内嵌可编程性"的全部取舍。
