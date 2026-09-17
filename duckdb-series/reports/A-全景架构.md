# A · 全景与架构 —— DuckDB 深读(一)

> 基线:commit `7e886f44428e90c8379d4d34e2afb866108ff079`(2026-09-17 主干,浅克隆)。
> 所有 `文件:行号` 均以仓库根为相对路径,并经实际读码核对;后续报告 B/C 的行号基线与本篇一致。

---

## 1. 定位:进程内的分析型数据库

README 对自己的第一句定义是:"DuckDB is a high-performance analytical database system"(README.md:18),强调 SQL 方言、窗口函数、复杂类型与易用性,随后列出 CLI 与 Python/R/Java/Wasm 等嵌入型客户端(README.md:20)。整个仓库是一个 CMake 工程(`project(DuckDB)`,CMakeLists.txt:23),根目录 `make` 即可编译出静态库、CLI 与各语言绑定(README.md:45)。

与另外两类"单机数据库"对比,可以精准刻画 DuckDB 的位置:

| 维度 | SQLite | PostgreSQL | DuckDB |
|---|---|---|---|
| 进程模型 | 进程内(库) | 客户端/服务器 | 进程内(库) |
| 存储 | 单文件,行存 | 服务端堆/索引,行存 | 单文件,列存 + 压缩 |
| 目标负载 | OLTP | 混合(偏 OLTP) | OLAP 分析查询 |
| API 形态 | C API `sqlite3_*` | libpq / 协议 | C API `duckdb_*` + 原生 C++ |

DuckDB 复刻了 SQLite 的"嵌入、单文件、零配置"外壳,内核却是列存向量化的 OLAP 执行器;"SQLite of Analytics"的定位在代码里处处可见:打开一个不存在的路径就新建文件(`src/storage/storage_manager.cpp:478`),连不上任何文件时退化为内存库(`src/main/database.cpp:499`)。

## 2. 两张全景图

### 2.1 进程内对象层次

```text
应用进程 (Python / R / C++ / CLI ...)
│
├─ duckdb::DuckDB  (src/include/duckdb/main/database.hpp:131)      ── 轻外壳
│   └─ shared_ptr<DatabaseInstance> instance                        ── 真正的引擎
│       DatabaseInstance (database.hpp:45, src/main/database.cpp:82)
│       ├─ DBConfig            全局配置/设置/文件系统/分配器 (src/main/config.cpp:71 起注册)
│       ├─ DatabaseManager     所有 ATTACH 的库 (src/main/database_manager.cpp:23)
│       │   └─ AttachedDatabase × N   每个 = Catalog + StorageManager + TransactionManager
│       │                              (src/include/duckdb/main/attached_database.hpp:98)
│       ├─ StandardBufferManager  缓冲池 (src/main/database.cpp:321)
│       ├─ TaskScheduler        线程池 (src/main/database.cpp:336)
│       ├─ ExtensionManager     扩展装载 (src/main/database.cpp:340)
│       └─ ConnectionManager    连接登记表 (src/main/database.cpp:339)
│
└─ duckdb::Connection (src/main/connection.cpp:22)
    └─ shared_ptr<ClientContext>  (src/include/duckdb/main/client_context.hpp:90)
        ├─ TransactionContext   每连接事务 (client_context.cpp:200)
        ├─ ClientData/Profiler  会话数据 (client_context.cpp:208)
        └─ registered_state     扩展注入的会话状态 (client_context.cpp:202)
```

规则:**一个 DatabaseInstance 对应一个数据库文件(或内存库),多个 Connection 各持一个 ClientContext**。Connection 的构造与析构是一对登记/摘除操作:

```cpp
// src/main/connection.cpp:22-27,43-48
Connection::Connection(DatabaseInstance &database)
    : context(make_shared_ptr<ClientContext>(database.shared_from_this())) {
	auto &connection_manager = ConnectionManager::Get(database);
	connection_manager.AssignConnectionId(*this);
	connection_manager.AddConnection(*context);
}
...
Connection::~Connection() {
	if (!context) {
		return;
	}
	ConnectionManager::Get(*context->db).RemoveConnection(*context);
}
```

另有一条重要规则:DatabaseInstance 之外,DatabaseManager 还常驻一个**无存储的 SYSTEM_DATABASE**,构造函数里创建(src/main/database_manager.cpp:25),`InitializeSystemCatalog` 只初始化它(src/main/database_manager.cpp:41-44);系统函数(如 `pragma_version`)都挂在这个库的目录里,它与用户库共享同一 `AttachedDatabase` 抽象。会话级临时表则挂在 `client_data->temporary_objects` 上(src/main/database_manager.cpp:64)。

### 2.2 一条 SQL 的生命周期

```text
Connection::Query/SendQuery (src/main/connection.cpp)
        │
        ▼
ClientContext::Query (src/main/client_context.cpp:1114)
   ParseIterator 逐语句流式解析(UTF-8 校验 client_context.cpp:1121-1130)
        │
        ▼
Parser(PEG 解析器)      src/parser/parser.cpp:239 ParseQuery;词法/文法在 src/parser/peg/
        │  SQLStatement(树)
        ▼
Planner → Binder         src/main/client_context.cpp:488 logical_planner.CreatePlan
        │  LogicalOperator(逻辑计划)
        ▼
Optimizer                src/main/client_context.cpp:525-530 optimizer.Optimize
        │  优化后的逻辑计划
        ▼
PhysicalPlanGenerator    src/main/client_context.cpp:541-542 逻辑算子 → 物理算子
        │  PhysicalOperator(物理计划)
        ▼
Executor + TaskScheduler 多线程 push/pull 执行(src/parallel/)
        │  DataChunk(向量化批,默认 2048 行/列)
        ▼
QueryResult(Materialized / Stream)
```

注意 2.2 中**没有网络层**:从 ClientContext 到 Executor 全部是同进程函数调用,这正是"in-process"的架构含义。

## 3. 仓库结构

### 3.1 src/ 各子目录职责(src/CMakeLists.txt:60-71 的注册顺序)

| 目录 | 职责 |
|---|---|
| `src/main/` | 对外的进程骨架:DatabaseInstance/ClientContext/Connection/配置/扩展(本篇主角) |
| `src/parser/` | SQL → AST。`Parser::ParseQuery`(src/parser/parser.cpp:239);PEG 文法与匹配器在 `src/parser/peg/`(文法系统自述见 src/parser/peg/README.md:1-3) |
| `src/planner/` | Binder:名字解析、类型绑定,产出逻辑计划 |
| `src/optimizer/` | 逻辑计划优化(谓词下推、join 顺序等,约几十个 pass) |
| `src/execution/` | 物理算子与表达式求值(`physical_plan_generator.cpp`、`operator/`) |
| `src/parallel/` | TaskScheduler、流水线与并发原语 |
| `src/storage/` | 块管理、压缩、WAL/checkpoint、`SingleFileStorageManager`(src/storage/storage_manager.cpp:209 处的类声明) |
| `src/transaction/` | 事务与 MVCC |
| `src/function/` | 内置标量/聚合/表函数与 pragma |
| `src/catalog/` | 目录对象(Catalog/CatalogSet/默认条目) |
| `src/common/` | 类型系统、Value、Allocator、文件系统抽象等基础设施 |
| `src/logging/` | 结构化日志 |
| `src/include/` | 全部公开/内部头文件,含 C API `src/include/duckdb.h`(10374 行,wc 实测) |

### 3.2 third_party/:内嵌的第三方库

构建显式链接的一组(CMakeLists.txt:1075-1085;链接名见 src/CMakeLists.txt:73-84):

- **fmt**:字符串格式化;**re2**:正则;**utf8proc**:UTF-8 分析/大小写(解析器入口就用它校验查询,src/parser/parser.cpp:70 的 `Utf8Proc::Analyze`);
- **miniz**:zip 压缩(扩展包安装);**zstd**:块压缩;**fsst**:字符串压缩;**hyperloglog**:近似 count(distinct);**fastpforlib**:位压缩;**skiplist**:跳表;**mbedtls**:加密(可选 OpenSSL 路径,CMakeLists.txt:920);**jemalloc**(Linux 默认分配器,CMakeLists.txt:1053-1054)。

目录里还有但由扩展/按需使用的:**parquet + thrift**(Parquet 元数据类型,extension/parquet/CMakeLists.txt:10、43)、**lz4/snappy/brotli**(Parquet 压缩)、**yyjson**(JSON)、**httplib**(httpfs)、**pcg/pdqsort/ska_sort/vergesort/concurrentqueue/tdigest/jaro_winkler/fast_float** 等算法件、**catch**(测试)、**imdb**(基准数据)。

**一个必须修正的印象:这一版主干里已经没有 libpg_query。** `third_party/` 与全文 grep 均找不到 `pg_query`/`postgres_parser`;SQL 解析已切换为自研 PEG 解析器(src/parser/peg/,文法用 `.gram` 文件描述、经 `scripts/parser/build_grammar.sh` 生成内联文法与 transformer 骨架,见 src/parser/peg/README.md:141-186)。写稿时不应再沿用"内嵌 PostgreSQL 解析器 libpg_query"的旧说法。

## 4. DatabaseInstance::Initialize:启动顺序逐行读

`DuckDB` 构造函数只是薄壳:创建实例 → `Initialize` → 装载扩展 → 收尾(src/main/database.cpp:375-381):

```cpp
DuckDB::DuckDB(const char *path, DBConfig *new_config) : instance(make_shared_ptr<DatabaseInstance>()) {
	instance->Initialize(path, new_config);
	if (instance->config.options.load_extensions) {
		ExtensionHelper::LoadAllExtensions(*this);
	}
	instance->db_manager->FinalizeStartup();
}
```

`DatabaseInstance::Initialize`(src/main/database.cpp:302-373)的顺序是理解全局的关键:

1. `Configure`:把用户 DBConfig 折叠进实例配置、定默认内存/线程数、创建文件系统与缓冲池(src/main/database.cpp:309;Configure 本体 485-575);
2. `RegisterLinkedExtensions`:把 CMake 生成的"静态链接扩展清单"发布到 config(src/main/database.cpp:311;实现由模板生成,extension/generated_extension_loader.cpp.in:12);
3. 依序创建 db_file_system、**DatabaseManager**、BufferManager、LogManager、**TaskScheduler**、ConnectionManager、**ExtensionManager**(src/main/database.cpp:316-340);
4. 初始化 SecretManager 与 **system catalog**(src/main/database.cpp:343-346);
5. `DBPathAndType::ResolveDatabaseType` 解析"要打开的是什么"(src/main/database.cpp:349-350,详见第 6 节);
6. `LoadExtensionSettings`:未被识别的配置项尝试归因到某个扩展的设置(src/main/database.cpp:363,本体 255-296);
7. `CreateMainDatabase`:用一条内部 Connection 走完整 ATTACH 流程挂上主库(src/main/database.cpp:365-367,本体 230-242);
8. 最后才启动/调整调度线程数,避免与 catalog 初始化竞争(src/main/database.cpp:369-372)。

这个顺序有一个贯穿全仓库的原则:**先元数据、后并发;先系统表、后用户库**。

## 5. ClientContext 与 Connection:会话层

ClientContext 是"一条连接的全部状态":事务上下文、中断标志、日志器、客户端数据、扩展注册状态(src/main/client_context.cpp:199-208)。它对查询的主入口:

- `Query(string)`:流式逐语句解析并执行,语句间只看 token 不预解析,让 `LOAD ext; SELECT ...` 这样的两段式生效(src/main/client_context.cpp:1114-1216,惰性解析的注释在 1170-1173);
- `CreatePreparedStatementInternal`:Planner → Optimizer → PhysicalPlanGenerator 三步(src/main/client_context.cpp:480-546);
- `BeginQueryInternal`:autocommit 时自动开事务,登记 query number、超时 deadline(src/main/client_context.cpp:299-329);
- `Destroy`:析构前回滚未提交事务并清理现场(src/main/client_context.cpp:273-282;析构函数 219-226)。

Connection 则更薄,基本是 ClientContext 的门面(portal):构造时创建 ClientContext 并在 ConnectionManager 登记(src/main/connection.cpp:22-27),对外暴露三组执行入口——`SendQuery`(允许流式,src/main/connection.cpp:80)、`Query`(物化,src/main/connection.cpp:88)、`PendingQuery`(拆成 prepare + 多次 execute 的分步形态,src/main/connection.cpp:106-121);对应头文件声明在 src/include/duckdb/main/connection.hpp:81-114。C++ 侧还有一个独立的 `Prepare` 通道,语句可按名字缓存与复用(src/main/client_context.cpp:883、941)。同文件的 `Connection(DuckDB&)` 直接转发(src/main/connection.cpp:29)。

值得写进正文的细节:ClientContext 内部用一把 `context_lock` 串行化本连接的所有操作(`LockContext`,src/main/client_context.cpp:228-230),所以"同一连接内并发提交查询"本身就不是受支持用法——这和 PostgreSQL 每条会话一个 backend 的串行语义一致,只是这里串行的单位从进程变成了互斥锁。

## 6. 打开一个数据库文件的全流程

从 `duckdb_open` 或 `DuckDB(path)` 进来后:

1. **实例缓存命中判定**(C API 路径):`duckdb_open_ext` → `DBInstanceCache::GetOrCreateInstance`,cache key 是规范化的绝对路径,Windows/macOS 上还做小写归一(src/main/db_instance_cache.cpp:33-48);命中时校验配置一致,不一致直接抛 `ConnectionException`(src/main/db_instance_cache.cpp:95-98)。C API 确实走缓存,而 C++ 的 `DuckDB` 构造函数直连 Initialize(src/main/capi/v1/duckdb-c.cpp:44 与 src/main/database.cpp:376)。
2. **路径登记与并发互斥**:`DatabaseFilePathManager::InsertDatabasePath` 维护 全进程"路径→已附加库" 表;两个只读附加可以共存并累加引用计数,读写与只读/读写混用则抛 `ResourceInUseException`(src/main/database_file_path_manager.cpp:37-58)。
3. **ATTACH 主库**:`DatabaseManager::AttachDatabase` 做远程文件只读降级、`ON CONFLICT` 处理、路径规范化,然后自旋等待同一文件的并发附加完成(src/main/database_manager.cpp:105-222,等待循环 165-183)。
4. **构造 AttachedDatabase**:为 DuckDB 文件创建 `DuckCatalog + SingleFileStorageManager + DuckTransactionManager` 三件套(src/main/attached_database.cpp:138-160);若是第三方存储格式则转交 StorageExtension(attached_database.cpp:162-194)。
5. **识别文件类型**:`DBPathAndType::ResolveDatabaseType` 先看 `sqlite:` 这样的扩展前缀,再读 **magic bytes** 判定是 SQLite 文件、Parquet/CSV(`__open_file__` 替换扫描)还是普通 DuckDB 文件(src/main/database_path_and_type.cpp:22-60)。
6. **真正加载/创建文件**:`SingleFileStorageManager::LoadDatabase`;**read_only 判定的核心几行**就在文件存在性检查上(src/storage/storage_manager.cpp:476-494):

```cpp
// src/storage/storage_manager.cpp:476-484
// Check if the database file already exists.
// Note: a file can also exist if there was a ROLLBACK on a previous transaction creating that file.
if (!read_only && !fs.FileExists(path)) {
	// file does not exist and we are in read-write mode
	// create a new file

	wal_path = GetWALPath();
	// try to remove the WAL file if it exists
	fs.TryRemoveFile(wal_path);
```

逻辑三分:文件存在 → 加载并做 WAL 恢复;文件不存在且可写 → 新建(注释还专门提醒:存在却写着 ROLLBACK 语义的残留文件也要按"存在"处理);文件不存在且只读 → 由后续打开流程报错。内存库则完全绕过这条路径,直接挂 `InMemoryBlockManager`(src/storage/storage_manager.cpp:424-431)。

顺带一提,C API 与 C++ API 在"打开"上的分叉:普通 `duckdb_open/duckdb_open_ext` 并不走缓存,而是直接 new 一个 `DuckDB`(src/main/capi/v1/duckdb-c.cpp:81-89);只有先 `duckdb_create_instance_cache` 拿到缓存句柄,再经 `duckdb_get_or_create_from_cache` 打开,才会命中 `GetOrCreateInstance`(src/main/capi/v1/duckdb-c.cpp:69-77 与 44;缓存句柄的创建在 duckdb-c.cpp:12-15)。Python/R 等官方绑定正是用后者保证 `duckdb.connect("a.db")` 幂等。

## 7. 配置系统

配置分三层:**DBConfigOptions 结构体字段**(编译期默认,如 `checkpoint_wal_size = 1 << 24`,src/include/duckdb/main/config.hpp:92;`access_mode`,config.hpp:88)、**命名设置表**(`internal_options[]` 宏展开,src/main/config.cpp:71 起,每个设置带 global/local 作用域回调,宏定义 31-69 行)、以及**扩展设置**(`DBConfig::AddExtensionOption`,src/main/config.cpp:553)。

命名参数入口 `SetOptionByName`:用户配置先存 `options.user_options`,能找到内置设置就 `SetOption`,是扩展设置就按扩展索引写,否则丢进 `unrecognized_options` 等启动时归因(src/main/config.cpp:360-378):

```cpp
// src/main/config.cpp:360-378
void DBConfig::SetOptionByName(const Identifier &name, const Value &value) {
	if (is_user_config) {
		// for user config we just set the option in the `user_options`
		options.user_options[name] = value;
	}
	auto option = DBConfig::GetOptionByName(name);
	if (option) {
		SetOption(*option, value);
		return;
	}

	ExtensionOption extension_option;
	if (TryGetExtensionOption(name, extension_option)) {
		Value target_value = value.DefaultCastAs(extension_option.type);
		SetOption(extension_option.setting_index.GetIndex(), std::move(target_value));
	} else {
		options.unrecognized_options[name] = value;
	}
}
```

真正的赋值在 `SetOption`:通用设置写 `user_settings` 数组,老式全局设置调 `option.set_global` 回调(src/main/config.cpp:388-405)。会话级的 SET/RESET 最终也落在同一张 `user_settings` 表上。`DBConfig` 还持有可注入的 FileSystem/Allocator/BufferPool 等策略对象(src/include/duckdb/main/config.hpp:186-210),这是嵌入式数据库"让宿主接管资源"的典型做法。`Configure` 阶段的默认值推导也值得一写:内存上限取系统可用内存的八成(`SetDefaultMaxMemory`,src/main/database.cpp:531-533),线程数取系统并行度(src/main/database.cpp:534-539)。

## 8. 扩展机制

**静态链接扩展**:发布版默认链接 icu、json、parquet、autocomplete,tpch/tpcds 只测不链(.github/config/bundled_extensions.cmake:17-26);裸仓库最小集是 core_functions 与 parquet(extension/extension_config.cmake:10-13)。CMake 按清单生成头文件与 loader(extension/CMakeLists.txt:16-40),模板把每个扩展注册为一个 lambda 压进 `config.linked_extensions`(extension/generated_extension_loader.cpp.in:12-16;类型定义在 src/include/duckdb/main/config.hpp:55-58 与 286)。启动时 `LoadAllExtensions` 按注册顺序逐个执行 lambda(src/main/extension/extension_helper.cpp:109-116),LOAD 时则按名查找 `LoadExtension`(extension_helper.cpp:97-107)。

**动态扩展(autoload / install)代码路径**:

- `TryAutoLoadExtension`:可选 autoinstall → `InstallExtension` → `LoadExternalExtension`(src/main/extension/extension_helper.cpp:238-255);
- `AutoLoadExtension` 的 DatabaseInstance 重载在 extension_helper.cpp:432;
- 下载与落盘:`InstallExtensionInternal`(src/main/extension/extension_install.cpp:569);
- 加载与 ABI 校验:`InitialLoad`/`TryInitialLoad`(src/main/extension/extension_load.cpp:730、455);扩展文件尾部的元数据(版本、平台、ABI)校验逻辑在 src/main/extension/extension.cpp:42-99。
- 可 autoload 的扩展名单是硬编码常量(src/include/duckdb/main/extension_entries.hpp:1544-1548);全部内置扩展及"是否已链接"的登记表在 src/main/extension/extension_helper.cpp:121-152。

并发安全由 `ExtensionManager::BeginLoad` 统一:同扩展的二次加载直接返回 nullptr,别名冲突报错(src/main/extension/extension_manager.cpp:88-163);装载完成后经回调通知各观察者并写日志(`FinishLoad`,src/main/extension/extension_manager.cpp:12-30)。

## 8.5 仓库里还有什么

除 `src/`、`third_party/`、`extension/` 之外,根目录还有几块值得点名:`tools/` 下是 CLI(shell)、C++ 示例、sqllogic 测试引擎、swift 绑定与构建工具(tools/shell、tools/cpp、tools/sqllogic、tools/swift、tools/utils);`benchmark/` 内置基准套件(README.md:45 提到的 `benchmark_runner` 即出自这里);`test/` 是 sqllogic + 单元测试的主场;`api_spec/` 存放 API 的生成规格。写"如何读这个仓库"时,建议读者以 `src/main` 为圆心、沿第 4 节的启动顺序向外辐射。

## 9. 对外 API 面

**C API**(`src/include/duckdb.h`,10374 行):核心生命周期函数包括 `duckdb_open`(src/include/duckdb.h:4550)、`duckdb_open_ext`(:4567)、`duckdb_close`(:4583)、`duckdb_create_config`(:4615)、`duckdb_connect`(:3690)、`duckdb_disconnect`(:3727)、`duckdb_query`(:6500)、`duckdb_prepare`(:5758)、`duckdb_execute_prepared`(:6348)、`duckdb_library_version`(:4596),另有 Arrow 系 `duckdb_query_arrow`(:2874)、appender、table function 注册等大族。扩展可用的稳定 ABI 是另一套 `duckdb_ext_api_v1`(由 src/main/database.cpp:298-300、659 供给)。

**C++ API**(include/duckdb/main/):`DuckDB`(src/include/duckdb/main/database.hpp:131,三个构造重载 133-135 对应 路径/路径/共享实例)、`Connection`(src/include/duckdb/main/connection.hpp:38)、`ClientContext`(src/include/duckdb/main/client_context.hpp:90)、`QueryResult/PendingQueryResult/PreparedStatement/Appender/Relation` 等。`DuckDB::LibraryVersion/SourceID` 就声明在 database.hpp:179-180。

## 10. 版本定义

版本不在源码里硬编码,而是构建期合成:`DUCKDB_VERSION` 由 `DUCKDB_EXPLICIT_VERSION` 环境变量或 `scripts/ci/release_version.txt` + git 提交计数拼出,如 `v<主>.<次>.0-dev<迭代>`(CMakeLists.txt:428-503);随后注入编译定义(CMakeLists.txt:1046-1048)。`DUCKDB_SOURCE_ID` 是 10 位 git hash,由子目录 CMake 单独定义(src/function/table/version/CMakeLists.txt:1)。运行期经 `DuckDB::LibraryVersion/SourceID` 暴露(src/function/table/version/pragma_version.cpp:57-62),`pragma_version()` 的 codename 按前缀映射(v1.4=Andium、v1.5=Variegata、v2.0=Cyanoptera,pragma_version.cpp:64-92)。

---

## 11. 设计动机(写作观点)

1. **为什么 in-process?** 数据不必跨进程搬运:查询计划、执行、结果物化在同一次函数调用内完成(第 2.2 节的链条里没有协议层),对 pandas/DataFrame 这类"宿主已持有数据"的场景,嵌入是唯一低摩擦的形态;代价是失去多进程共享与权限隔离,所以同一文件只允许一个读写实例(src/main/database_file_path_manager.cpp:54-57)。
2. **为什么单文件?** 单文件 = 可拷贝、可版本管理、零部署。DuckDB 把 block 管理、压缩、WAL、checkpoint 全部收进一个 `SingleFileStorageManager`(src/storage/storage_manager.cpp:209 起),甚至提供 `checkpoint_on_shutdown` 把 WAL 折叠回单文件(src/include/duckdb/main/config.hpp:115)。
3. **为什么自研 PEG 解析器取代 libpg_query?** 旧主干依赖 PostgreSQL 的 gram 驱动,扩展语法要改 PG 文法、报错定位与增量能力受限;PEG 文法按语句拆成 `.gram` 文件、由脚本生成匹配器与 transformer(src/parser/peg/README.md:141-186),让 `SELECT FROM 'file.csv'` 这类方言扩展可以随语法一起演进(本篇 3.2 节)。
4. **为什么扩展静态链接进主库?** parquet/json/icu 是分析场景的"事实上核心",静态链接免去首次查询的下载等待与供应链风险;生成器只产出一个 `linked_extensions` 列表(extension/generated_extension_loader.cpp.in:12-16),同一条代码路径既能加载静态扩展也能加载下载的动态扩展(第 8 节),这是"静态是动态的特例"的干净设计。
5. **为什么实例缓存?** 同一进程反复打开同一文件若各建实例,会撞上文件锁与内存翻倍;以规范化路径为 key 的缓存 + 配置一致性检查(src/main/db_instance_cache.cpp:60-98)让"多次 connect 等价于共享一个实例",官方语言绑定正是经 `duckdb_get_or_create_from_cache` 使用它(src/main/capi/v1/duckdb-c.cpp:69-77)。缓存条目持弱引用、实例析构期间后来者自旋等待的设计(第 6 节第 1 步)则展示了嵌入式场景特有的生命周期难题:实例的生死不归数据库管,归宿主管。
6. **为什么 ATTACH 统一主库与附加库?** 主库就是一次普通 ATTACH(`CreateMainDatabase`,src/main/database.cpp:230-242),这让 sqlite_scanner/postgres 等外部存储与主库共享同一套 Catalog/事务抽象(AttachedDatabase 双构造,src/main/attached_database.cpp:138-194),"lakehouse 前端"的架构由此铺路。

## 12. 写作素材清单(最值得引用的 16 处)

1. `README.md:18` — 官方自我定位原句
2. `src/main/database.cpp:302` — `DatabaseInstance::Initialize` 启动顺序起点
3. `src/main/database.cpp:375` — `DuckDB` 构造:壳与引擎的分离
4. `src/main/client_context.cpp:199` — ClientContext 状态全貌
5. `src/main/client_context.cpp:480` — Planner→Optimizer→Physical 三段式编译
6. `src/main/client_context.cpp:1114` — 多语句流式 Query 主入口
7. `src/main/connection.cpp:22` — Connection 与 ClientContext 的绑定
8. `src/main/db_instance_cache.cpp:95` — 实例缓存配置一致性检查
9. `src/main/database_file_path_manager.cpp:37` — 只读共存/读写互斥规则
10. `src/main/database_manager.cpp:105` — ATTACH 主流程
11. `src/main/attached_database.cpp:156` — Catalog+Storage+Transaction 三件套
12. `src/main/database_path_and_type.cpp:22` — magic bytes 识别文件类型
13. `src/storage/storage_manager.cpp:478` — read_only 与文件创建判定
14. `src/main/extension_helper.cpp:121` — 内置扩展登记表
15. `src/include/duckdb/main/config.hpp:92` — checkpoint_wal_size 等默认值
16. `src/function/table/version/CMakeLists.txt:1` — DUCKDB_SOURCE_ID 注入

(次选:`src/parser/peg/README.md:1`、`extension/generated_extension_loader.cpp.in:12`、`src/include/duckdb.h:4550`)
