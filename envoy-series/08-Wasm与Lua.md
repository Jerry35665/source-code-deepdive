# 第 08 章 · 扩展沙箱:Wasm 与 Lua filter(卷二)

> 基线:tag v1.39.1。两条路线:Wasm(proxy-wasm ABI,强隔离,多语言生态)与 Lua(LuaJIT,轻量脚本定制)。两者共享同一个流量抽象 Http::StreamFilter。

## 8.0 全景:两种沙箱模型

```
Wasm:main 线程建 base VM → 每 worker 克隆一份(TLS slot)
  Context 同时是 ContextBase + Http::StreamFilter + AccessLog::Instance…
  流回调即 ABI upcall(on_request_headers/body/response…);
  宿主 downcall:get_header_map_value/http_call/define_metric/shared kv…
  四后端:V8(默认)/WAMR/Wasmtime/Null(测试直通),按 v8→wasmtime→wamr 兜底
Lua:每 worker 一个 lua_State(主线程验证一次语法,worker 各编译一次)
  每条流一个 coroutine;脚本 body()/httpCall() 时 lua_yield,
  宿主凭 State 枚举返回 StopIteration,异步完成后 resumeCoroutine
```

## 8.1 Wasm 要点

**隔离模型**:"base VM+每 worker 克隆";`vm_id`+代码哈希相同的插件共用 VM(降低内存,有安全含义),同 vm_id 下 root_id 相同的插件共享 RootContext——**一个插件可同时当 filter+logger+sink**。**ABI 在 pinned 依赖里**:proxy-wasm-cpp-sdk/host 固定 commit,Envoy 只写宿主桥,与 Istio 等共享插件生态。**资源限制现状如实**:无 fuel/指令/堆上限(全仓无命中);capability 白名单是空 TODO;失控插件靠 fail_state+FAIL_RELOAD 退避重建兜底。**配置加载**:local 直读;remote 是 HTTP+强制 sha256+进程级 code cache(24h TTL/10s 负缓存),无 OCI;`nack_on_code_cache_miss` 决定 NACK 还是异步填缓存。foreign functions 是 ABI 外的逃生门(签名/压缩/CEL 求值/清路由缓存)。

## 8.2 Lua 要点

主线程 `luaL_dostring` 语法验证一次,每 worker 各建 state 编译一次——编译产物以全局函数驻留,per-request 零编译;`envoy_on_request/response` 以 luaL_ref 引用。**协程式挂起**:脚本调 body()/httpCall() 时 lua_yield,宿主凭 State 枚举(WaitForBody/HttpCall/Responded…)决定返回 StopIteration;异步完成后 resumeCoroutine,协程已跑完则补 continueIteration() 让 FilterManager 继续走链。respond() 是第四种 yield(直连终结)。路由级脚本:source_codes 命名表+LuaPerRoute 覆盖;每份脚本代码都是独立 state(增加 concurrency+1 个 VM)。脚本抛错只计 errors、复位 wrapper、流继续——**Lua 的失败域天然只有单条流**。

## 8.3 沙箱边界的真相

Lua 的 `luaL_openlibs` 实际打开了全部标准库(含 io/os)——沙箱性来自三条软约束:文档契约"禁止阻塞操作"、API 面刻意极小(stream handle 的 20 个方法)、markDead/checkDead 生命周期拦截(跨 yield 持有的包装器立即变 Lua 错误)。Wasm 侧是线性内存真沙箱+每线程独立 VM,但同样没有 fuel。取舍:Lua 单次调用量级更便宜(直接持 HeaderMap 引用),Wasm 的 JIT 计算密集逻辑远快于解释执行;Wasm 能力面要动 proxy-wasm ABI 或注册 foreign function(前者慢但跨实现)。

## 8.4 设计动机

1. **双轨**:Lua 服务"十几行脚本改头/短路"的零编译场景;Wasm 面向强隔离、任意语言、三方分发生态;
2. **proxy-wasm ABI**:跨 SDK 稳定边界,pin 上游 commit 跟随多厂商共享生态;
3. **每 worker 克隆**:与 Envoy 无锁线程模型对齐;跨 worker 只留共享 kv/队列一条显式通道;
4. **Lua 协程同步风格**:把异步回调地狱压平成顺序调用,yield 恢复点即缓冲决策点;
5. **无 fuel 上限**:metering 支持参差且下发通道受 xDS 信任模型保护;兜底是 FAIL_RELOAD 整 VM 换新。

## 8.5 FAQ

**Q1:Wasm 支持哪些语言?**
经 SDK:C++/Rust/AssemblyScript/Go 等;Lua 只有 LuaJIT 5.1。

**Q2:VM 是每线程一份吗?**
是:base VM 建好后每 worker 克隆;vm_id+哈希相同的插件共享 VM。

**Q3:恶意 Wasm 插件会吃满 CPU 吗?**
没有 fuel 上限;兜底是 OOM→fail_state 与 FAIL_RELOAD 整体重建。

**Q4:Wasm 插件代码怎么分发?**
本地文件/inline,或 HTTP+sha256(24h 缓存);无 OCI。

**Q5:Lua 能发 HTTP 请求吗?**
能:httpCall() yield 后走 AsyncClient,响应 resume 回脚本。

**Q6:Lua 脚本死循环会怎样?**
没有执行时限;文档契约禁止阻塞操作,真死循环会挂住该 worker 的这条流。

**Q7:Wasm 的 Context 是什么?**
多重身份类:ContextBase+StreamFilter+AccessLog::Instance+Network::Filter——filter 层几乎零逻辑。

**Q8:NullVM 是什么?**
无沙箱,Wasm 模块以原生代码编进二进制;用于测试与内联。

**Q9:路由能覆盖 Lua 脚本吗?**
能:LuaPerRoute 的 disabled/命名脚本/内联三种,最具体者优先。

**Q10:Wasm 能同时当 filter 和 access log 吗?**
能:root_id 相同即共享 RootContext,同一 VM 多重身份。

## 8.7 小结与深挖方向

本章结论:**扩展沙箱="Wasm=ABI 边界+VM 克隆+FAIL_RELOAD;Lua=per-thread state+协程挂起;共享 StreamFilter 抽象"**。深挖:

1. proxy_get_property 的 CEL activation 逐段求值;
2. stop-and-buffer 的 413 触发与 VM 放行;
3. SharedQueue 跨线程投递回属主线程的机制;
4. Lua 的 markDead/checkDead 与迭代器跨 yield 拦截;
5. on_resolve_dns/on_stats_update 两个 ABI 外私有入口。
