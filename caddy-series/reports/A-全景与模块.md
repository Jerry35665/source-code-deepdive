# Caddy 源码深读（五之五）· 全景与模块体系

> 调研对象：caddyserver/caddy，commit `56e3a88`（shallow clone）。文中所有 `文件:行号` 均为仓库相对路径，行号以该 commit 为准。
> 本篇是系列的总纲：先建立"一次配置加载的生命周期"和"一切皆模块"两张全景图，后续各篇（HTTP、TLS/自动 HTTPS、存储等）都挂在这两棵树上。

---

## 1. 全景：一次配置加载的生命周期

### 1.1 顶层结构：Config 就是整个运行时

Caddy 的原生配置格式是 JSON，`Config` 结构体是配置树的根（caddy.go:68-95）。真正驱动行为的字段只有两个"模块插槽"：

```go
type Config struct {
    Admin   *AdminConfig `json:"admin,omitempty"`
    Logging *Logging     `json:"logging,omitempty"`

    // StorageRaw 是存储模块：证书等资产如何/存哪里
    StorageRaw json.RawMessage `json:"storage,omitempty" caddy:"namespace=caddy.storage inline_key=module"`

    // AppsRaw 是 Caddy 要加载运行的 app：key 是 app 模块名，value 是其配置
    AppsRaw ModuleMap `json:"apps,omitempty" caddy:"namespace="`

    apps map[string]App          // 运行期：已实例化的 app（caddy.go:84）
    ...
}
```

要点：
- `App` 接口只有 `Start() error` / `Stop() error` 两个方法（caddy.go:98-101），是"被 Caddy 运行的东西"的最小定义。
- `StorageRaw` 的 struct tag `caddy:"namespace=caddy.storage inline_key=module"` 告诉反射层：去 `caddy.storage` 命名空间找模块，模块名内联在 JSON 的 `"module"` 键里（caddy.go:77）。
- `AppsRaw` 的 namespace 为空串，即顶层 app 模块（`http`、`tls`、`events`、`pki`…）直接以 key 命名（caddy.go:82）。

### 1.2 生命周期 ASCII 图

```text
 CLI / Admin API / 配置加载器
        │  JSON 字节
        ▼
 Load(cfgJSON, forceReload)          caddy.go:115
        │  包一层 changeConfig()      caddy.go:136→158
        │  ①写锁 rawCfgMu（串行化所有变更）        caddy.go:168
        │  ②把 JSON 合入 rawCfg map、序列化对比
        │    （无变化且不强制 → errSameConfig）    caddy.go:220-223
        │  ③索引 @id → rawCfgIndex               caddy.go:227
        ▼
 unsyncedDecodeAndRun(newCfg)        caddy.go:337
        │  剥离 @id 元字段 → 严格解码成 *Config    caddy.go:340-344
        ▼
 run(newCfg, start=true)             caddy.go:419
        │
        ├─ provisionContext()          caddy.go:484   ←── Provision 阶段
        │    ├─ openLogs：日志最先就绪              caddy.go:524-530
        │    ├─ 加载存储模块 → certmagic.Default.Storage  caddy.go:540-559
        │    ├─ replaceLocalAdminServer（先起新管理端点） caddy.go:564-570
        │    └─ 逐个 ctx.App(name) → LoadModuleByID：│
        │        New()→JSON 解码→Provision→Validate  context.go:364-465
        │
        ├─ Start：遍历 apps 调 a.Start()             caddy.go:444-463
        │    （某个 app 失败 → 回滚已启动的 apps）    caddy.go:449-457
        ▼
 原子换上下文（新已就绪，旧的还在跑）    caddy.go:368-372
        │    currentCtx = newCtx
        ▼
 unsyncedStop(oldCtx)                caddy.go:375   ←── Cleanup 阶段
        │    旧 app 逐个 Stop() → cancelFunc 触发
        │    所有旧模块的 Cleanup()               caddy.go:724-742, context.go:75-92
        ▼
 autosave 配置到磁盘                 caddy.go:377-400
```

核心心法：**新的先全部建好、跑起来，再一次性把 `currentCtx` 指针换成新的，最后才停旧的**。任何一步失败，新上下文 cancel，旧配置原封不动（见第 3 节）。

### 1.3 模块树的形态

注册表是 `map[string]ModuleInfo`（modules.go:379-382），模块 ID 的点分前缀构成逻辑树：

```text
(空 namespace，即 app 层)          ← AppsRaw 的 key（caddy.go:82）
├── http                          modules/caddyhttp/app.go:180-185
│   ├── http.handlers.*           routes.go:92（inline_key=handler）
│   ├── http.matchers.*           routes.go:43
│   └── http.encoders.* ...
├── tls
│   ├── tls.certificates.*        modules/caddytls/tls.go:72
│   ├── tls.issuance.*            admin.go:167（identity 复用同一命名空间）
│   └── tls.handshake_match.*
├── events                        modules/caddyevents/app.go:113-118
├── pki / caddy.storage.file_system / caddy.logging.encoders.* ...
└── admin.api.*                   管理端点本身也是模块！
    ├── admin.api.load (/load、/adapt)   caddyconfig/load.go:49,58-64
    ├── admin.api.pki                    modules/caddypki/adminapi.go:43
    └── admin.api.metrics                modules/metrics/adminmetrics.go:44
```

树不是数据结构，是**命名约定**：`GetModules(scope)` 按段数+前缀精确匹配取"下一层"模块（modules.go:204-242）；`Namespace()`/`Name()` 就是对 ID 做最后一个点的切割（modules.go:103-118）。

---

## 2. 模块体系专节：接口、注册表、命名空间

### 2.1 caddy.Module：一个方法 + 三个可选生命周期接口

核心接口小到令人发笑——只要求类型自报家门（modules.go:54-60）：

```go
type Module interface {
    // 返回 ModuleInfo，必须无副作用
    CaddyModule() ModuleInfo
}

type ModuleInfo struct {
    ID  ModuleID          // 全名，如 "http.handlers.file_server"
    New func() Module     // 返回空实例指针，初始化留给 Provision
}                         // (modules.go:63-77)
```

宿主模块加载子模块的完整流程写在 `Module` 接口的文档注释里（modules.go:42-53）：`New()` 拿空实例 → JSON 严格解码进实例 → 依次探测可选接口 `Provisioner`（modules.go:296-298）、`Validator`（modules.go:305-307）、最后断言为宿主期望的业务接口（如 `caddyhttp.MiddlewareHandler`，modules/caddyhttp/caddyhttp.go:90-92）；上下文取消时若实现了 `CleanerUpper`（modules.go:315-317）则调用 `Cleanup()`。

**"模块是类型而不是实例"**：注册表里存的是 `ModuleInfo`（一个 ID + 一个构造函数），运行时实例由 `LoadModuleByID` 现场制造——同一模块 ID 可在配置里出现 N 次，得到 N 个互不共享状态的实例（context.go:364-376）。

### 2.2 注册表与注册时机

`RegisterModule` 在包 `init()` 时被调用（模块包作为副作用被 import 时完成注册，modules.go:130-137），四道防线全是 panic 而非 error——因为注册错误属于程序员 bug，要在启动时炸出来（modules.go:138-161）：

- ID 为空 → panic（modules.go:141-143）
- ID 为保留字 `caddy`/`admin` → panic（modules.go:144-146）
- `New` 缺失或返回 nil → panic（modules.go:147-152）
- ID 重复 → panic（modules.go:157-159）

查询端：`GetModule(name)` 按 ID 查（modules.go:164-172）；`GetModules(scope)` 列举命名空间下一层，并用排序保证确定性（modules.go:204-242）；`Modules()` 返回全部 ID 的有序列表（modules.go:246-258）。仓库内 132 处 `RegisterModule` 调用（grep 统计，不含测试）。

标准发行版 = caddy 核心 + `modules/standard/imports.go` 里的一串空导入（modules/standard/imports.go:15-18，仅 13 个包）——所谓"自带插件"不过是"预先 import 的包"。

### 2.3 模块 ID 命名空间约定

`ModuleID` 文档明确了 `<namespace>.<name>` 形态：无点的 ID（如 `http`）是 app 层模块，标签小写、下划线代替空格（modules.go:79-98）。三个代表性命名空间：

| 命名空间 | 声明处 | 用途 |
|---|---|---|
| `http.handlers.*` | routes.go:92 `caddy:"namespace=http.handlers inline_key=handler"` | HTTP 中间件 |
| `http.matchers.*` | routes.go:43 `caddy:"namespace=http.matchers"` | 请求匹配器 |
| `admin.api.*` | admin.go:276 `GetModules("admin.api")` 遍历注册路由 | 管理端点扩展 |
| `caddy.storage.*` | caddy.go:77 | 证书存储后端 |
| `events.handlers` | modules/caddyevents/app.go:104 | 事件处理器 |

### 2.4 "配置即类型"：JSON 如何变成 Go 实例

`Context.LoadModule(structPtr, fieldName)` 是整个体系的关节（context.go:188-287）：用反射读 struct tag 拿到 `namespace` 与 `inline_key`，按字段类型（`json.RawMessage`/切片/Map 四种形态，context.go:145-154）分派，最终都落到 `LoadModuleByID`（context.go:364-465）：

```go
func (ctx Context) LoadModuleByID(id string, rawMsg json.RawMessage) (any, error) {
    modInfo, ok := modules[id]          // 查注册表
    ...
    val := modInfo.New()                // 造空实例（context.go:376）
    if len(rawMsg) > 0 {
        err := StrictUnmarshalJSON(rawMsg, &val)   // 严格解码：未知字段报错
        ...
    }
    if appModule, ok := val.(App); ok { ctx.cfg.apps[id] = appModule }  // app 提前登记
    ...
    if prov, ok := val.(Provisioner); ok { err = prov.Provision(ctx) }  // (context.go:425)
    if validator, ok := val.(Validator); ok { err = validator.Validate() } // (context.go:440)
    ctx.moduleInstances[id] = append(...)   // 记入实例账本，供 Cleanup 遍历 (context.go:454)
```

两个值得展开的点：

- **严格解码**：`StrictUnmarshalJSON` 开启 `DisallowUnknownFields`（modules.go:342-350），拼错一个字段名整个加载失败，而不是静默忽略。这是"配置即类型"的安全网。
- **inline_key**：当模块名不能当 map key 时（比如路由数组里的一串 handler），模块名内联在对象里，`getModuleNameInline` 把该键从 raw 中删掉再解码（否则严格解码会报未知字段），modules.go:263-286。
- **配置使命完成后释放**：加载成功后宿主字段里的 raw JSON 被清零，让 GC 回收（context.go:283-284）。

config adapter 也是同一机制的乘客：`RegisterAdapter` 会顺手把 adapter 包成 `caddy.adapters.<name>` 模块注册（caddyconfig/configadapters.go:111-117,135-140）；Caddyfile 适配器在 `caddyconfig/httpcaddyfile/httptype.go:41` 注册，名为 `caddyfile`。

---

## 3. 生命周期专节：三阶段与热重载的原子切换

### 3.1 三阶段职责边界

| 阶段 | 入口 | 职责 | 禁忌 |
|---|---|---|---|
| Provision | `Provision(ctx)`，context.go:425 | 建连接池、解析引用、`ctx.LoadModule` 子模块、拿 logger | 要快（"imperceptible"），副作用必须配 Cleanup（modules.go:288-295） |
| (Validate) | `Validate()`，context.go:440 | 校验配置合法性，同样要快 | 不应有副作用 |
| Start/Stop | app 级，caddy.go:98-101 | 监听端口、开始服务 | 只属于 app 模块 |
| Cleanup | `Cleanup()`，context.go:82-91 | 回收文件/goroutine/非栈状态；Provision 半途失败也要能清（modules.go:309-317） | — |

`caddy.Validate(cfg)`（caddy.go:746-752）就是跑一遍 `run(cfg, false)`：只 Provision 不 Start，然后 cancel 触发全量 Cleanup——"试运行"。

### 3.2 热重载的原子切换（这是 Caddy 最精巧的一段）

`changeConfig` 全程持有 `rawCfgMu` 写锁，天然串行化所有配置变更（caddy.go:168-169，锁的用途注释见 caddy.go:1232-1234）。真正的切换在 `unsyncedDecodeAndRun`（caddy.go:337-403）：

```go
// run the new config and start all its apps
ctx, err := run(newCfg, true)      // 新实例完全就绪、已开始服务
if err != nil { return err }

// swap old context (including its config) with the new one
currentCtxMu.Lock()
oldCtx := currentCtx
currentCtx = ctx                   // ← 原子切换点：只换一个指针
currentCtxMu.Unlock()

// Stop, Cleanup each old app
unsyncedStop(oldCtx)               // 旧实例才开始退场
```

（caddy.go:362-375，摘录 12 行）

由此得出几个可检验的推论：

1. **新配置的监听器先绑定再交接**——这也是无缝重载的原因：新 app Start 时端口可复用（SO_REUSEPORT 相关基础设施在 listen.go/listen_unix.go），旧 app 在 `unsyncedStop`（caddy.go:724-742）里才释放。
2. **停旧实例的顺序**：先逐个 `a.Stop()`（错误只记日志、继续停下一个，caddy.go:733-738），再 `cancelFunc` 触发所有模块 `Cleanup()`（caddy.go:741 + context.go:75-92 的 wrappedCancel）。
3. **管理端点先换新再关旧**：`replaceLocalAdminServer` 在 Provision 阶段就把新 admin server 拉起，defer 里异步 shutdown 旧 server（且"新起失败则不关旧"，admin.go:374-395 注释与实现）。
4. **默认日志的切换也是热插拔**：`setupNewDefault` 换掉全局 `defaultLogger` 后，把旧 buffered core 的存量日志 Flush 到新 logger，保证日志顺序（logging.go:168-200）。

### 3.3 失败的回滚：三层防御

- **模块级**：`LoadModuleByID` 中 Provision/Validate 失败立即对该模块调 `Cleanup()`（context.go:428-437, 443-451）。
- **config 级**：`provisionContext` 里任何错误 → `cancelCause(err)` 触发新上下文所有已 Provision 模块的 Cleanup，并把 `certmagic.Default.Storage` 恢复为旧配置的存储（caddy.go:505-520）；Start 阶段某个 app 失败则把已启动的 app 逐个 Stop（caddy.go:449-457）。
- **raw 状态级**：`unsyncedDecodeAndRun` 失败时，把旧 `rawCfgJSON` 重新 unmarshal 回 `rawCfg`，保证"内存里的配置视图"与"实际运行的配置"一致（caddy.go:248-264，注释明说"restore old config state to keep it consistent with what caddy is still running"）。

为什么旧配置要重新 unmarshal 而不是留着？因为 `changeConfig` 是在共享 map 上原地改的，深层指针可能已被污染（caddy.go:252-255 注释）。`Stop()` 则是反操作：停当前配置并清空 rawCfg/rawCfgJSON/rawCfgIndex（caddy.go:694-712）。进程退出走 `exitProcess`：Stop → 清 CertMagic 锁 → 删 pidfile → 执行 exitFuncs → goroutine 里关 admin server（让它先响应完 API 请求），caddy.go:760-839。

### 3.4 入口与信号

`caddy run` → `cmdRun`：读配置文件、（可选）经 adapter 转 JSON、`caddy.Load(config, true)`（cmd/commandfuncs.go:188,252,283）。SIGUSR1 重载复用 `SetLastConfig` 记录的源文件与回调（caddy.go:1262-1268, cmd/commandfuncs.go:272-280）。`caddy reload` 则是对运行中实例 POST `/load`（cmd/commandfuncs.go:406）。

---

## 4. Admin API 专节：localhost:2019 上的"配置数据库"

### 4.1 端点与安全默认

- 默认监听 `localhost:2019`（admin.go:1450-1453），可被环境变量 `CADDY_ADMIN` 覆盖（admin.go:58-67）；远程管理端点默认 `:2021` 但必须显式启用且依赖 mTLS（admin.go:1455-1459, 181-191）。
- 标准路由注册（admin.go:263-265）：`/config/`（配置树 CRUD）、`/id/`（按 @id 寻址）、`/stop`（优雅退出）；`/debug/pprof/*`、`/debug/vars`（admin.go:268-273）；模块路由通过 `GetModules("admin.api")` 注入（admin.go:276-290）。
- **`/load` 端点本身是个模块**：`adminLoad` ID 为 `admin.api.load`，之所以不写死在 caddy 包里只是为了避免 import cycle——注释本身就是模块化设计的注脚（caddyconfig/load.go:34-43,47-66）。`handleLoad` 支持按 `Content-Type` 自动调 adapter（如 `text/caddyfile`），非 JSON 配置直接 POST 即可（caddyconfig/load.go:73-112, 179-215）；另有 `/adapt` 端点只转换不加载（load.go:62-64,137-175）。
- 防浏览器侧攻击：DNS rebinding 缓解（Host 校验，admin.go:871-878,941-954）、Origin/Referer 校验（admin.go:880-896,960-1006）、拒绝 WebSocket 与 `Origin: null`（admin.go:838-869）。回环地址默认允许 localhost/::1/127.0.0.1 三个 origin（admin.go:336-344）；unix socket 上不做 Host 校验（浏览器无法访问 UDS，注释长篇论证，admin.go:305-335）。
- 配置主体上限 100 MB（admin.go:1074-1075），非 GET 写操作要求 `Content-Type: application/json`（admin.go:1063-1067）。

### 4.2 配置的 ID 标识：@id 与 /id/ 短路径

配置对象里任何位置可放 `"@id": "foo"`；加载时 `indexConfigObjects` 递归扫描并把 ID 映射到完整 JSON 路径，重复 ID 报错（caddy.go:290-327）。`handleConfigID` 把 `/id/foo/...` 重写为 `/config/...` 后内部重定向（返回哨兵错误 `errInternalRedir`，重新走鉴权，admin.go:1111-1145, 1482-1487）。@id 是纯元数据，真正 run 前会被正则剥掉（`RemoveMetaFields`，admin.go:1363-1374, 1477）。

### 4.3 /config/ 的 RESTful 语义与并发控制

`handleConfig`（admin.go:1026-1109）+ `unsyncedConfigAccess`（admin.go:1179-1356）实现了对 JSON 树的 GET/POST(追加)/PUT(新建，键已存在报 409)/PATCH(替换)/DELETE，支持数组下标与 `...` 展开（admin.go:1208-1219）。GET 返回 ETag（xxhash，admin.go:1008-1016,1047），写请求可带 `If-Match: "<path> <hash>"` 做乐观并发控制，不匹配返回 412（caddy.go:171-203）。`POST /config` 与 `/load` 都汇入同一个 `changeConfig`（caddy.go:158, 1089），所以"部分改一个字段"和"整体替换"拥有一致的重载语义：无变化则跳过（errSameConfig，caddy.go:220-223,1325），除非带 `Cache-Control: must-revalidate` 强制重载（admin.go:1087）。

成功加载后配置自动落盘 `autosave.json`（`caddy --resume` 的后端，caddy.go:377-400, storage.go:157）。

---

## 5. Replacer 专节：全库通用的占位符系统

### 5.1 两级（或多级）provider 链

`Replacer` 是 provider 链而非 map（replacer.go:63-67）。`NewReplacer()` 默认挂三个 provider，**按序短路**（replacer.go:34-45）：

```go
rep.providers = []replacementProvider{
    globalDefaultReplacementProvider{},   // ① 全局：env./system./time.*
    fileReplacementProvider{},            // ② {file.*}：读文件内容（上限 1MB）
    ReplacerFunc(rep.fromStatic),         // ③ Set() 写入的静态变量
}                                         // (replacer.go:39-43，摘录 5 行)
```

请求级变量是**运行时再 Map 进来的第四个 provider**：HTTP 中间件把 replacer 放进请求 context（键 `ReplacerCtxKey`，replacer.go:448-449），`addHTTPVarsToReplacer` 追加 `httpVars` 闭包，覆盖 `http.request.uri.*`、`http.request.header.*`、`http.request.cookie.*`、`http.request.tls.*` 等（modules/caddyhttp/replacer.go:58-130, 180-202）。查值时沿链问一遍，谁先认领谁生效（replacer.go:100-107）。

全局 provider 的实现是纯 switch：`env.FOO`、`system.hostname/slash/os/wd/arch`、`time.now(.http/.common_log/.unix/...)`（replacer.go:380-420）。

### 5.2 性能设计

- **快速路径**：输入不含 `{`/`}` 直接原串返回（replacer.go:179-181）；预分配 `sb.Grow(len(input))`（replacer.go:183-187）。
- **免反射的值转字符串**：`ToString` 是按具体类型排布的 type switch，常见类型零分配（replacer.go:291-331）。
- **对抗病态输入**：未闭合占位符超过 100 个直接报错（CVE 缓解，注释引用 issue #4170，replacer.go:210-213）；反斜杠转义 `\{` `\}`（replacer.go:198-201, 451）。
- **文件 provider 有 1MB 上限**且用 `io.LimitReader` 防大分配（replacer.go:360-361, 423-434）；安全敏感场景可用 `WithoutFile()` 摘除（replacer.go:74-83）。
- 三种替换模式语义不同：`ReplaceAll`（未知占位符替换为空/默认值）、`ReplaceKnown`（未知原样保留）、`ReplaceOrErr`（未知/空报错），replacer.go:147-173——Caddyfile 层大量用 ReplaceKnown，管理端点解析监听地址用 ReplaceOrErr（admin.go:1412）。
- 事件系统复用同一机制注入 `event.*` 占位符（modules/caddyevents/app.go:247-273）。

---

## 6. 设计动机

**为什么 JSON 是核心格式，Caddyfile 只是糖。** JSON 是"配置的汇编"：模块名、嵌套、数组都能无损表达，`json.RawMessage` 天然是模块插槽；而 `StrictUnmarshalJSON` + struct tag 让"JSON→类型化实例"变成机械过程。Caddyfile 是 `Adapter` 接口（caddyconfig/configadapters.go:26-28）的一个实现，产出的也是 Caddy JSON——适配可以发生在任何地方：CLI 启动时（cmd/main.go LoadConfig）、`POST /load` 的 Content-Type 协商（caddyconfig/load.go:96-112）、甚至运行中的 `/adapt` 端点（load.go:62-64）。糖不会渗入核心。

**为什么模块是类型（ModuleInfo.New）而非实例。** 注册发生在 init 期，运行期按需实例化：同一 ID 可多实例（N 条路由各挂一个 file_server）、配置驱动生命周期（每个实例绑定自己的 Context，cancel 时统一 Cleanup，context.go:454+75-92）、以及热重载时"新旧两套实例树短暂并存"成为可能——这是 nginx 式"编译期模块、一份配置"做不到的。代价是反射+两阶段构造，Caddy 用严格解码和 init 期 panic 把错误提前。

**xcaddy 的插件经济学。** Go 的静态链接使"运行时 dlopen 插件"基本不可行，Caddy 的答案是：插件=Go 包，构建=把包 import 进来再编译。xcaddy（独立仓库 github.com/caddyserver/xcaddy，README.md:145-148, cmd/cobra.go:91-92）本质上是一个"帮你写 main.go 的 go build 包装器"：把 caddy 与第三方插件锁进同一个 go.mod，产出单个静态二进制。与 nginx 对照：nginx 模块是 C 编译期 `--with-xxx_module`（换模块=换发行版/自己编译，第三方模块升级要跟着 nginx 版本走），动态模块 .so 还要匹配 ABI；Caddy 的"注册表+类型反射"把插件 ABI 问题转化为 Go 接口问题——`RegisterModule` 的 panic-on-duplicate 与 go.mod 版本仲裁共同保证一致性。运行期行为变更则完全交给 Admin API 的 JSON 热重载，不需要插件参与。

**事件与日志也走模块化。** `events` app 提供同步、DOM 式冒泡的事件总线（从 `a.b.c` 冒泡到 `a.b`、`a` 再到全局，`Aborted` 可截断，modules/caddyevents/app.go:43-72；`Emit` 在 app.go:208）。caddy 核心通过 `eventEmitter` 小接口反转依赖，避免 import caddyevents 包（context.go:683-689, caddy.go:471,730 的 started/stopping 事件）。日志同理：`Logging` 是配置驱动的 zap 组装器——每条日志按模块 ID 匹配到 N 个 CustomLog，用 `zapcore.NewTee` 多路复写（logging.go:219-246）；logger 名即模块 ID，因此可以按 `http.handlers` 前缀过滤某类模块的日志（logging.go:50-56 注释）。日志 writer 通过 `UsagePool` 按 WriterKey 共享/引用计数（logging.go:250-261, usagepool.go:58）。

**存储接口是 CertMagic 的边界。** Caddy 自己定义 `StorageConverter`（把配置模块转成 `certmagic.Storage`，storage.go:31-33），默认实现是文件系统 `caddy.storage.file_system`（modules/filestorage/filestorage.go:37），指向 `AppDataDir()`（storage.go:160）；每次加载配置都会把新存储设为 `certmagic.Default.Storage`（caddy.go:553-556），失败回滚时再换回旧的（caddy.go:516-518）。证书存储的可插拔（文件/S3/Redis…）就是自动 HTTPS 能上云的关键。

---

## 7. FAQ 素材

1. **热重载期间请求会中断吗？** 设计目标是不中断：新 app 先 Start（端口可复用），`currentCtx` 单指针切换后旧 app 才 Stop（caddy.go:362-375）。真正无缝依赖监听器复用与 app 自身的优雅退场。
2. **改配置后 Caddy 怎么知道要不要重载？** `changeConfig` 把变更后的整棵树重新序列化，与 `rawCfgJSON` 字节级对比，相同则返回 errSameConfig 视为成功（caddy.go:220-223）；强制重载需 `Cache-Control: must-revalidate`（admin.go:1087）。
3. **新配置加载失败，旧配置还在吗？** 在。三层回滚：模块级 Cleanup、config 级 cancel+恢复 certmagic 存储、rawCfg 级重新 unmarshal 旧 JSON（caddy.go:248-264, 505-520）。
4. **为什么模块 ID 要带命名空间？** 注册表是一个平面 map，命名空间纯靠约定；`GetModules(scope)` 用它枚举"下一层"，Admin API 扩展端点、存储后端、事件处理器都靠同一约定发现（modules.go:204-242, admin.go:276）。
5. **Caddyfile 改了要重启吗？** 不用。Caddyfile→JSON 适配发生在加载时（CLI 或 `/load` 的 Content-Type 协商），运行时管理一律走 JSON（caddyconfig/load.go:96-112）。
6. **`caddy reload` 和 `caddy run` 走同一条路吗？** 是。reload 是 POST `/load`（cmd/commandfuncs.go:406），load 端点直接调 `caddy.Load`（caddyconfig/load.go:116），与启动时 `cmdRun` 的调用（cmd/commandfuncs.go:283）殊途同归。
7. **占位符在哪些地方可用？** 理论上任何接受字符串配置处：监听地址（admin.go:1412）、日志输出、matcher……全局占位符永远可用，请求级占位符在 HTTP 上下文里由 `addHTTPVarsToReplacer` 注入（modules/caddyhttp/replacer.go:58）。
8. **Admin API 裸奔安全吗？** 默认只听 localhost:2019，带 Host/Origin 校验防 DNS rebinding/CSRF（admin.go:871-896）；跨机管理必须走 identity+mTLS 的 remote 端点（admin.go:181-191, 547-579）或 unix socket。
9. **日志为什么默认刷 stderr？什么时候变 JSON？** 交互终端用 console 编码，非交互用 JSON（logging.go:45-48 注释）；配置里的 `logging.logs.default` 可整体接管，切换时旧 buffered 日志会先 flush（logging.go:168-200）。
10. **两个插件注册同一个模块 ID 会怎样？** panic：`module already registered`（modules.go:157-159）。这是 init 期故障，无法被配置救回——xcaddy 构建时就应该解决版本冲突。

## 深挖方向

1. **端口无缝交接的底层**：`addr.Listen` 与 SO_REUSEPORT（listen.go, listen_unix.go），以及 http app 如何在新旧实例间复用 listener（modules/caddyhttp/app.go:479 Start）。
2. **StrictUnmarshalJSON 与 RemoveMetaFields 的正则剥离**：为什么 @id 用正则删而不是 map 操作（admin.go:1358-1374 注释给了理由），以及它在什么输入下会误伤。
3. **事件总线的 Abort 语义**：`Emit` 的 DOM 冒泡实现与 `Aborted` 对程序流的控制（modules/caddyevents/app.go:279+）。
4. **UsagePool 引用计数**：日志 writer、监听器等跨配置生命周期的共享资源如何在 reload 间存活（usagepool.go, logging.go:250-261）。
5. **动态配置拉取**：`admin.config.load` 模块 + load_delay 的轮询循环与递归拉取防护（caddy.go:593-678, 353-360）。

---

## 写作要点速查表

| # | 事实 | 位置 |
|---|---|---|
| 1 | `Config` 根结构；AppsRaw `caddy:"namespace="`、StorageRaw `namespace=caddy.storage inline_key=module` | caddy.go:68-95 (82,77) |
| 2 | `App` 接口 = Start/Stop | caddy.go:98-101 |
| 3 | `Load` → `changeConfig(POST,"/config")`；errSameConfig 视为成功 | caddy.go:115-142, 1325 |
| 4 | changeConfig 持 rawCfgMu 写锁；字节级对比决定是否重载 | caddy.go:168-169, 220-223 |
| 5 | 失败回滚：旧 rawCfgJSON 重新 unmarshal 恢复现场 | caddy.go:248-264 |
| 6 | 原子切换三连：run → currentCtx=ctx → unsyncedStop(oldCtx) | caddy.go:362-375 |
| 7 | run() 的 app 启动循环与"失败回滚已启动 apps" | caddy.go:444-463 (449-457) |
| 8 | provisionContext：日志→存储→admin→apps 的顺序 | caddy.go:484-582 (524-580) |
| 9 | unsyncedStop：Stop 各 app 后 cancelFunc 触发 Cleanup | caddy.go:724-742 (741) |
| 10 | Module 接口与 ModuleInfo{ID,New}；模块加载 6 步文档 | modules.go:54-77 (42-53) |
| 11 | RegisterModule：保留 ID/重复注册均 panic | modules.go:138-161 (144-146,157-159) |
| 12 | ModuleID 命名空间 `<ns>.<name>`；Namespace()/Name() | modules.go:79-98,103-118 |
| 13 | LoadModuleByID：New→严格解码→Provision→Validate→入实例账本 | context.go:364-465 (390,425,440,454) |
| 14 | Context cancel 触发全部模块 Cleanup（wrappedCancel） | context.go:72-96 (82-91) |
| 15 | Admin 默认 localhost:2019 / 远端 :2021；CADDY_ADMIN 覆盖 | admin.go:1450-1459, 58-67 |
| 16 | 标准路由 /config/、/id/、/stop + admin.api 模块注入 | admin.go:263-265, 276-290 |
| 17 | /load 端点本身是模块 admin.api.load；Content-Type 协商适配 | caddyconfig/load.go:47-66, 96-112, 116 |
| 18 | @id 索引与 /id/ 内部重定向（errInternalRedir） | caddy.go:290-327, admin.go:1111-1145 |
| 19 | Replacer 三默认 provider + 未知占位符>100 报错 | replacer.go:39-45, 210-213 |
| 20 | 请求级占位符 addHTTPVarsToReplacer；events ID "events"；http app ID "http" | modules/caddyhttp/replacer.go:58；caddyevents/app.go:115；caddyhttp/app.go:182 |
