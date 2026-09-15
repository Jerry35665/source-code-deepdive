# I - Module 模块系统:Redis 的内核可编程扩展层

> 调研基线:仓库当前 commit `e8726d1`("[vector sets] Add --ollama-url option..."),src/module.c 共 **14932 行**,是 Redis 代码库中最大的单一源文件(核心文件几乎全部被它超过)。所有行号以该 commit 为准,均已 grep -n / Read 核对。
>
> 与卷一的呼应:卷一 05(客户端阻塞原语)讲的是 `blockClient/blockForKeys`(blocked.c);本篇讲模块系统如何"借道"这套原语实现自定义阻塞,以及命令、类型、复制、线程等扩展面。

---

## 1. 全景:Module API 的能力面

模块系统的本体是 `src/module.c`:内核侧函数全部以 `RM_` 前缀实现,模块侧经 `redismodule.h` 里的函数指针以 `RedisModule_` 前缀调用,两者靠一张运行时导出的 API 表对接(module.c:787-795 的注释明确说明:起 `RM_` 别名是为了"防止动态链接器把主程序的同名符号覆盖到模块的全局函数指针上")。

```
                        +--------------------------------------+
                        |         .so 模块 (dlopen)             |
                        |  RedisModule_OnLoad / OnUnload       |
                        +------------------+-------------------+
                           ^  函数指针表     |  回调(命令/类型/阻塞/通知)
                           |  server.moduleapi                 v
+--------------------------+---------------------------------+------------------+
|                          Redis 内核 (module.c ~14900 行)     |                  |
|  命令:    CreateCommand/CreateSubcommand/ACL 类别/SetCommandInfo               |
|  类型:    CreateDataType(rdb_load/rdb_save/aof_rewrite/free/mem_usage/aux/...) |
|  键访问:  OpenKey(逻辑DB句柄)/String/List/ZSet/Hash/Stream DMA                |
|  内嵌调用: Call(带回复解析) / Reply* 家族 / CallReply* 家族                     |
|  阻塞:    BlockClient / BlockClientOnKeys / SignalKeyAsReady / UnblockClient   |
|  线程:    GetThreadSafeContext + GIL(Try)Lock/Unlock / Yield                  |
|  异步面:  CreateTimer(rax) / EventLoopAdd(ae复用) / Fork / CreateString      |
|  通知:    SubscribeToKeyspaceEvents / AddPostNotificationJob / SubscribeTo    |
|          ServerEvent / RegisterCommandFilter / 模块间 SharedAPI                |
|  传播:    Replicate / ReplicateVerbatim / EmitAOF(重写期)                     |
+-----------------------------------------------------------------------------+--+
        |                          |                        |
   AOF/复制流                  RDB 文件                  ae 主事件循环
 (MULTI/EXEC 包裹的命令)   (RDB_TYPE_MODULE_2/AUX)   (GIL 在 sleep 前后放/收)
```

能力面的边界(模块**不能**做什么)在 §6 讨论。导出面规模:`moduleRegisterCoreAPI()`(module.c:14550)里连排的 `REGISTER_API` 宏(module.c:12208)约有 380 处,几乎每个 `RM_` 函数都对应一个导出名。

---

## 2. 注册与生命周期:Init / OnLoad / UnLoad / dlopen

### 2.1 加载:MODUL.E LOAD 与 dlopen

两条加载路径殊途同归:

- **配置文件**:`loadmodule` 指令先入队,服务器初始化完毕后由 `moduleLoadFromQueue()`(module.c:12350)逐个执行;失败直接 `exit(1)`(module.c:12357-12364)——注释给出理由:客户端依赖这些命令、AOF 加载需要模块、副本必须理解主库命令。
- **运行时命令**:`MODULE LOAD <path> [args]` / `MODULE LOADEX`(带 CONFIG/ARGS 解析,module.c:13918-13935)/ `MODULE UNLOAD` / `MODULE LIST`(module.c:13904-13951)。

`moduleLoad()`(module.c:12546)的核心就是 POSIX 动态链接:

```c
// module.c:12559-12573(节选)
handle = dlopen(path,RTLD_NOW|RTLD_LOCAL);
if (handle == NULL) { ... return C_ERR; }
onload = (int (*)(void *, void **, int))(unsigned long) dlsym(handle,"RedisModule_OnLoad");
if (onload == NULL) {
    dlclose(handle);
    serverLog(LL_WARNING,
        "Module %s does not export RedisModule_OnLoad() "
        "symbol. Module not loaded.",path);
    return C_ERR;
}
return moduleOnLoad(onload, path, handle, module_argv, module_argc, is_loadex);
```

`moduleOnLoad()`(module.c:12578)回调 `RedisModule_OnLoad(ctx, argv, argc)`(12581),失败则 `moduleUnregisterCleanup` + `dlclose` 整体回滚(12584-12591);成功则把模块结构挂进全局 `modules` 字典(12595),并发出 `REDISMODULE_EVENT_MODULE_CHANGE/LOADED` 事件(12633)。值得注意的是 Redis 8 起内核自带"内置模块":vector sets 就是以模块形态在 `moduleLoadInternalModules()` 里注册的(module.c:12332-12339)——模块系统已成为内核自身复用的抽象。

### 2.2 版本协商:RedisModule_Init 与 APIVER

`RedisModule_Init` 不是内核函数,而是 `redismodule.h` 里**静态内联进每个模块**的函数(redismodule.h:1362-1364)。它从 ctx 的第 0 个槽位取回 `RM_GetApi` 的指针(redismodule.h:1365-1366),然后连续数百个 `REDISMODULE_GET_API(name)` 把内核导出的 `RedisModule_<name>` 逐个取到模块自己的函数指针上。

版本协商是"双保险":

- **API 版本**:`RedisModule_Init(ctx,"name",1,REDISMODULE_APIVER_1)`,`REDISMODULE_APIVER_1 == 1`(redismodule.h:42)。目前只有 APIVER_1 一代,兼容策略靠"API 永不删除、只新增"维持。
- **结构体版本**:`RedisModuleTypeMethods.version` 必须等于 `REDISMODULE_TYPE_METHOD_VERSION`(当前 5,redismodule.h:46),内核按版本逐段读取回调字段(见 §3)。

`RM_GetApi`(module.c:797)只是在 `server.moduleapi` 字典里按名字查函数指针;查不到即 ERR——这意味着**老模块加载进新 Redis 时,若引用了不存在的 API,Init 直接失败**,而不是运行到一半崩溃。名字查重由 `RM_IsModuleNameBusy`(module.c:2344)在 `Init` 尾部完成(redismodule.h:1747-1749),真正的模块结构由 `RM_SetModuleAttribs`(module.c:2307)创建,初始 `module->onload = 1`(module.c:2337)——这是后续"只能在 OnLoad 里注册"检查的依据。

系统初始化入口是 `moduleInitModulesSystem()`(module.c:12232):建 API 表、模块字典、通知订阅链表、模块线程唤醒管道 `server.module_pipe`(12255)、定时器 rax(12262),并把 **GIL 先行加锁**(12270-12272,"it is just unlocked when it's safe")。

### 2.3 命令注册与 ACL 类别

`RedisModuleCommandDispatcher`(module.c:930)是所有模块命令在命令表中的统一 `proc`:取 `c->cmd->module_cmd`,构造 `REDISMODULE_CTX_COMMAND` 上下文并回调 `cp->func`。`RM_CreateCommand`(module.c:1280)的守卫链:onload 检查(1281)、flags 解析失败即 ERR(1283-1284)、`no-cluster` 与集群互斥(1285)、命令名合法性与占用检查(1293-1298),最后 `dictAdd` 进 `server.commands` 与 `server.orig_commands`(1304-1307)并分配 ACL 命令 ID(1309)。

flags 是字符串风格("write deny-oom" ...),完整枚举在 module.c:1201-1258,模块特有的关键项:

- `getkeys-api` / `getchannels-api`:键位置非线性时,由命令自身在"探查调用"里用 `RM_KeyAtPosWithFlags`(module.c:1036)报告键(探查模式靠 `REDISMODULE_CTX_KEYS_POS_REQUEST` 上下文区分,module.c:1012);
- `may-replicate`:读命令也可能产生复制流量(1245-1246);
- `blocking`:声明可能阻塞客户端(1248);
- `touches-arbitrary-keys`:不提供 argv 之外的键会被改动,内核因此**放弃 MULTI/EXEC 包裹**(1257-1258,复制语义见 §5);
- `allow-busy`:服务器因慢模块命令/脚本 BUSY 时仍可执行(1249-1251)。

ACL 集成是双向的:模块可以新增类别 `RM_AddACLCategory`(module.c:1501,仅限 OnLoad,卸载失败时回收,module.c:12326-12330),也可以给命令挂类别 `RM_SetCommandACLCategories`(module.c:1573);模块加载成功后对所有用户重算命令位(module.c:12607-12611),卸载后同样重算(12712)。

### 2.4 卸载与守卫

`moduleUnload`(module.c:12647)的守卫序列解释了"模块基本不可热卸载"的现实:

```c
// module.c:12656-12672(节选)
} else if (listLength(module->types) && !forced_unload) {
    *errmsg = "the module exports one or more module-side data "
              "types, can't unload";
} else if (listLength(module->usedby)) { ... }
  else if (module->blocked_clients) { ... }
  else if (moduleHoldsTimer(module)) { ... }
```

即:导出数据类型、被其他模块引用、还有阻塞客户端、还有未触发定时器——任一命中都拒绝卸载。通过守卫后调用 `dlsym("RedisModule_OnUnload")` 给模块清理机会(12676),再 `dlclose`(12693)、`moduleUnregisterCleanup`(12532:命令/通知/共享 API/过滤器/事件/配置/认证回调一揽子注销)。运行期临时客户端对象有池化回收:`modulesCron()`(module.c:12275)。

---

## 3. 数据类型专节:RedisModule_Type

### 3.1 Type ID:9 字符名 + 10 位编码版本

`RM_CreateDataType`(module.c:7069)要求 9 字符类型名(如 `tree-AntZ`),`moduleTypeEncodeId`(module.c:6790)把每个字符按 64 符号字符表(module.c:6785)编成 6 bit,9 字符 + 10 bit encver 拼成 64 位 Type ID。该 ID 写入 RDB 作为"这个值归哪个模块加载"的路由键;RDB 加载时 `moduleTypeLookupModuleByID`(module.c:6850)按 **高 54 位**(忽略 encver,module.c:6877)匹配,并带一个 3 项小缓存(6848-6854)。

回调集合按 `RedisModuleTypeMethods.version` 分版本解析(module.c:7076-7137):

- 基础(v1):`rdb_load / rdb_save / aof_rewrite / mem_usage / digest / free`;
- v2:`aux_load / aux_save`(键空间之外的辅助数据);
- v3:`free_effort / unlink / copy / defrag`;
- v4:`mem_usage2 / free_effort2 / unlink2 / copy2`(带 KeyOptCtx,含 dbid/键名);
- v5:`aux_save2`(未写则整个 AUX 段省略,使无模块也能打开 RDB)。

### 3.2 持久化语义:RDB 中的模块值

RDB 侧,模块类型是**一等公民对象类型** `OBJ_MODULE`,磁盘编码 `RDB_TYPE_MODULE_2`(rdb.h:62,"带解析注解的模块值")。保存(rdb.c:1150-1173):

```c
// rdb.c:1159-1167(节选)
/* Write the "module" identifier as prefix, so that we'll be able
 * to call the right module during loading. */
int retval = rdbSaveLen(rdb,mt->id);
...
mt->rdb_save(&io,mv->value);
retval = rdbSaveLen(rdb,RDB_MODULE_OPCODE_EOF);
```

`rdb_save` 回调内部用 `RM_SaveUnsigned`(module.c:7269)/`RM_SaveString`(module.c:7323)等 IO 原语写入,每个值前都带操作码(`RDB_MODULE_OPCODE_UINT/STRING/...`),使 RDB 即使不认识该模块也能**跳过**值体(加载端按操作码逐段消费到 EOF,rdb.c:1710-1735)。加载端 `RDB_TYPE_MODULE_2`(rdb.c:3098)把控制权交给 `mt->rdb_load`,最后强制校验 EOF 标记(rdb.c:3139-3144)。若 RDB 里的 Type ID 没有对应模块,报错并给出 9 字符名(`moduleTypeNameByID`,module.c:6897)。

`aux_load/aux_save` 处理键空间外元数据:`RDB_OPCODE_MODULE_AUX`(rdb.h:90)段在键值区前后各写一次(`AUX_BEFORE_RDB/AFTER_RDB`,rdb.c:1470、1482);加载时**模块缺失或不支持 AUX 直接 exit(1)**(rdb.c:3519-3523)——与键空间值"可跳过"不同,AUX 是强依赖。IO 错误的容忍度由 `REDISMODULE_OPTIONS_HANDLE_IO_ERRORS` 声明(`RM_SetModuleOptions`,module.c:2520;全模块是否都支持决定能否 diskless 加载,module.c:7209)。

### 3.3 AOF 语义与内存/复制联动

- **AOF 重写**:`aof_rewrite` 回调用 `RM_EmitAOF`(module.c:7671)把当前值"重放"为一串原生命令写入重写缓冲——即模块类型的 AOF 等价物是一段命令流。
- **内存统计**:`mem_usage(_2)` 供 `MEMORY USAGE`;`free_effort` 供惰性删除决策——返回 0 恒定异步释放(lazyfree.c:168),大于阈值且 refcount==1 时走异步删除(lazyfree.c:185-190)。
- **DUMP/RESTORE 复用**:`RM_SaveDataTypeToString / RM_LoadDataTypeFromStringEncver`(module.c:7633、7600)把 rdb_save/rdb_load 回调复用为任意字符串载荷的编解码。
- **阻塞联动**:模块类型的键不会自动唤醒 BLPOP 类原语,需要模块在内部结构变化后显式调用 `RM_SignalKeyAsReady`(module.c:8350,内部 `signalKeyAsReady(db,key,OBJ_MODULE)`),这就是任务书里提到的持久化/复制之外的关键语义钩子。
- 键关闭时隐式 `signalModifiedKey`(解除 WATCH/失效客户端缓存)见 `moduleCloseKey`(module.c:4175-4181),可用 `NO_IMPLICIT_SIGNAL_MODIFIED` 选项关闭。

---

## 4. 阻塞与线程专节

### 4.1 BlockClient:两阶段(命令函数 → reply 回调)

`RM_BlockClient`(module.c:8234)与 `RM_BlockClientOnKeys`(module.c:8325)共用 `moduleBlockClient`(module.c:7920)。第一阶段:命令函数里登记回调集合(reply/timeout/free_privdata + 可选 disconnect),然后:

```c
// module.c:7977-7984(节选)
} else {
    if (keys) {
        blockForKeys(c,BLOCKED_MODULE,keys,numkeys,timeout,
                     flags&REDISMODULE_BLOCK_UNBLOCK_DELETED);
    } else {
        c->bstate.timeout = timeout;
        blockClient(c,BLOCKED_MODULE);
    }
}
```

——完全复用卷一 05 的客户端阻塞原语,只是 btype 为 `BLOCKED_MODULE`。从 Lua 脚本或 MULTI/EXEC 里调用会直接报错而不阻塞(7926-7927 探测,7966-7970 报错)。第二阶段:后台任务(常见为模块线程)完成后调用 `RM_UnblockClient(bc, privdata)`(module.c:8402)——**该函数线程安全**:把句柄推入 `moduleUnblockedClients` 链表(互斥锁保护),再向 `server.module_pipe` 写一字节唤醒主线程(module.c:8355-8367);真正的 reply 回调由主线程在 `moduleHandleBlockedClients()`(module.c:8451)里执行,调用点在 blocked.c 的 beforeSleep 路径(blocked.c:772)。超时/`CLIENT UNBLOCK` 则走 `moduleBlockedClientTimedOut`(module.c:8573)触发 timeout 回调;`RM_AbortBlock`(module.c:8416)清掉回调后按普通解阻塞处理。

### 4.2 BlockClientOnKeys:按"键就绪"解阻塞

`RM_BlockClientOnKeys` 与 BLPOP 同构但更通用:blockForKeys 挂上键后,每次键就绪都会**重新调用 reply 回调**试探(module.c:8291-8295 的契约):回调返回 OK 即服务该客户端,ERR 则继续等。试探入口是 `moduleTryServeClientBlockedOnKey`(module.c:8174),由 `handleClientsBlockedOnKeys`(blocked.c:334)在键就绪时调用(blocked.c:714)。这让模块可以实现"列表至少 5 个元素才唤醒"这类自定义条件。客户端中途断连由 `unblockClientFromModule`(module.c:7863)处理,可触发 disconnect 回调(8439)。

### 4.3 GIL 与线程安全上下文

模块线程与主线程共享进程地址空间,同步原语是一把全局互斥锁 `moduleGIL`:

- 启动时即持锁(module.c:12270-12272);
- 主线程 **beforeSleep 释放 GIL**(server.c:1960,注释警告其后不得再加代码),让模块线程在事件循环空闲窗口安全访问数据集;**afterSleep 重新加锁**(server.c:1978-1981),之后才处理本轮 IO 事件;
- 模块线程侧:`RM_GetThreadSafeContext`(module.c:8662)拿到可跨线程使用的上下文(绑定的阻塞客户端各配一个临时 client 用于累积回复,7945-7946);调用任何非 Reply API 前必须 `RM_ThreadSafeContextLock`(module.c:8727,内部 `moduleAcquireGIL`,8770),用完 `RM_ThreadSafeContextUnlock`(8764);`TryLock` 版本 8739。Reply 家族在绑定了阻塞客户端时免锁(直接写进 `bc->reply_client`)。

```c
// module.c:8770-8780
void moduleAcquireGIL(void) {
    pthread_mutex_lock(&moduleGIL);
}
int moduleTryAcquireGIL(void) {
    return pthread_mutex_trylock(&moduleGIL);
}
void moduleReleaseGIL(void) {
    pthread_mutex_unlock(&moduleGIL);
}
```

长命令体则靠 `RM_Yield`(module.c:2427)周期性让出:内部 `processEventsWhileBlocked()` 处理事件,达到 `busy-reply-threshold` 后服务器对普通命令回 `-BUSY`(仅 `allow-busy` 命令放行);非主线程调用时通过 module_pipe 委托主线程处理事件(2462-2478)。限频由 `ctx->next_yield_time` 控制在每 `server.hz` 周期至多一次(2517 附近)。

### 4.4 定时器、事件循环与 fork

- **定时器**:`RM_CreateTimer`(module.c:9390)把定时器按到期时间(key 为大端 ustime)插入 rax `Timers`(9315);ae 主循环只需一个真实 timer(9316),到期后 `moduleTimerHandler`(9330)一次性触发所有过期项再重排下一个。这是注释所称"可注册百万级定时器的 green timers"抽象(9296-9313)。持有未触发定时器会阻止模块卸载(9476 的 `moduleHoldsTimer`)。
- **事件循环接入**:`RM_EventLoopAdd`(module.c:9565)把模块的 fd 以 READABLE/WRITABLE 掩码挂进 ae,用 stub 回调做掩码映射以保持二进制兼容(9577-9586)。
- **fork**:`RM_Fork`(module.c:11497)允许模块像 RDB 子进程一样 fork 出后台子进程做重活,带心跳(11518)与完成回调(11563)。
- **服务器事件钩子**:`RM_SubscribeToServerEvent`(module.c:11896)可订阅复制角色变化、FLUSHDB、客户端变更、CRON 循环等;分发器 `moduleFireServerEvent`(module.c:11994)首行做零订阅快速返回以保证主路径零开销。

---

## 5. 复制专节:模块命令如何进 AOF/复制流

模块命令不会自动进复制流——**内核不理解模块对数据做了什么**,所以传播责任显式交给模块,两种风格(module.c:3572-3589):

- `RM_ReplicateVerbatim`(module.c:3651):把客户端原始 argv 原样传播——命令本身确定性可重放时使用;
- `RM_Replicate`(module.c:3606):传播任意(通常为原生)命令序列。

两者底层都是 `alsoPropagate`,追加进当前命令执行单元的传播数组,由内核统一以 **MULTI/EXEC 包裹**(module.c:3575-3577 的注释:"The replicated commands are always wrapped into the MULTI/EXEC")写入 AOF 与副本流,保证多条传播的原子性:

```c
// module.c:3624-3634(节选)
int target = 0;
if (!(flags & REDISMODULE_ARGV_NO_AOF)) target |= PROPAGATE_AOF;
if (!(flags & REDISMODULE_ARGV_NO_REPLICAS)) target |= PROPAGATE_REPL;

alsoPropagate(ctx->client->db->id,argv,argc,target);
...
server.dirty++;
```

`"A"`/`"R"` 格式修饰符可分别屏蔽 AOF 或副本方向。配套约束:

- 传播目标选择(3624-3626)、`server.dirty++`(3633)使 AOF 重写与 save 条件正确推进;
- 从线程安全上下文调用 Replicate 必须**持 GIL**(module.c:3591-3600、3647-3648 明确警告);
- 声明 `touches-arbitrary-keys` 的命令跳过 MULTI/EXEC 包裹(module.c:1257-1258);
- 数据类型路径不产生命令:值变更后依赖 `aof_rewrite`(重写期)与 RDB(全量),副本接收方也必须有同款模块——这是"模块类型集群/主从必须双侧安装模块"的根源。

键空间通知回调内写键的危险性也有传播对策:`moduleNotifyKeyspaceEvent`(module.c:8978)通过 `enterExecutionUnit` 抑制回调内命令的提前传播(8997-9001),使其并入引发通知的原命令事务;规范做法是 `RM_AddPostNotificationJob`(module.c:8946)把写动作推迟到"安全且与通知同事务"的执行单元(加载中/只读副本直接拒绝,8947-8949)。

---

## 6. 设计动机与边界

**为什么是 dlopen 的 C ABI 模块,而不是嵌入式语言?** Redis 已内嵌 Lua(及后来的 Functions),但嵌入式脚本解决的是"用户侧逻辑",模块系统解决的是"内核侧扩展":新数据结构(如 RedisJSON 的 JSON、RediSearch 的倒排索引)、新命令语义、原生性能与自有持久化。C ABI + 函数指针表的设计让扩展与内核同进程、零跨语言开销、可访问内部数据结构(DMA),同时 `APIVER` + "只增不删"的导出表 + `RedisModuleTypeMethods.version` 提供了朴素的 ABI 稳定性承诺:老模块的符号解析失败是显式、即时的(module.c:797-808),而非运行期未定义行为。代价是模块与服务器**同生死**(OOM/崩溃互相牵连)、无沙箱,这也是社区长期争论点。生态上,RedisJSON/RediSearch/RedisTimeSeries 等官方 Stack 模块与 8.0 并入内核的 vector sets(module.c:12332-12339)都构建在这套 API 之上——模块系统事实上是 Redis 有限公司的产品化边界。

**模块能做什么 / 不能做什么**:能——注册命令与子命令、定义持久化数据类型、阻塞客户端、收发键空间/服务器事件、定时器、后台线程(经 GIL)、fork 子进程、注册 ACL 类别与配置项(module.c:13123 起的 Configurations API)、甚至过滤/改写其他命令(`RM_RegisterCommandFilter`,module.c:10979;执行点 `moduleCallCommandFilters`,11011)与自定义认证(`RM_RegisterAuthCallback`,module.c:8041)。不能——绕过传播契约(写键不 Replicate 就会主从不一致)、在通知回调里安全地写键、在无 GIL 时触碰数据集、导出数据类型后卸载自身(12656)。

---

## 7. FAQ 素材

1. **Q: 模块是懒加载 dlopen 吗?** A: 不是"懒"加载,是显式加载——`loadmodule` 配置在服务器就绪后由 `moduleLoadFromQueue` 统一执行(module.c:12350),或运行期 `MODULE LOAD`;加载即 `dlopen(RTLD_NOW)`(module.c:12559),符号立即解析。
2. **Q: `RedisModule_Init` 是内核导出的吗?** A: 不是。它是 redismodule.h 里 static 内联进每个模块的函数(redismodule.h:1364),唯一需要"从内核取回"的是 `RM_GetApi` 指针——藏在 ctx 的第 0 个槽位(redismodule.h:1365),之后所有 API 经函数指针表解析。
3. **Q: API 版本怎么协商?** A: 三层:`REDISMODULE_APIVER_1`(redismodule.h:42)标识 API 代数;`RedisModuleTypeMethods.version`(当前 5,redismodule.h:46)标识类型回调结构版本;缺失的 API 会在 Init 时因 `RM_GetApi` 查表失败而使模块加载失败(module.c:804-805)。
4. **Q: 模块命令的键声明和原生命令有何不同?** A: 简单情形用 firstkey/lastkey/keystep(module.c:1263-1271);复杂情形声明 `getkeys-api`,内核在 Cluster/ACL 需要键列表时以"探查上下文"重入命令函数,由 `RM_KeyAtPosWithFlags` 报告(module.c:1012-1051);或用 `RM_SetCommandInfo` 声明 key specs(module.c:1884)。
5. **Q: 模块类型在 RDB 里如何与内建类型区分?** A: 独立对象类型 `OBJ_MODULE`,磁盘编码 `RDB_TYPE_MODULE_2`(rdb.h:62),值前写 64 位 Type ID(rdb.c:1159),值体是模块自定义的操作码流,可无损跳过;AUX 元数据用 `RDB_OPCODE_MODULE_AUX`(rdb.h:90),模块缺失则加载直接失败(rdb.c:3519-3523)。
6. **Q: 为什么导出数据类型的模块不能 MODULE UNLOAD?** A: 键空间里存在无法"脱离模块"解释的值,卸载后这些键既不能加载也不能释放;守卫在 module.c:12656-12659。同理还有 usedby/blocked_clients/未触发 timer 三道闸(12660-12672)。
7. **Q: `RM_BlockClient` 之后客户端 socket 上发生了什么?** A: 与 BLPOP 完全相同:进入 `bstate`,`BLOCKED_MODULE`,事件循环继续服务其他客户端;模块线程算完后 `RM_UnblockClient` 只是"投递"(互斥队列+管道唤醒,module.c:8355-8367),真正回复在主线程 `moduleHandleBlockedClients`(8451,由 blocked.c:772 在 beforeSleep 调用)。
8. **Q: 模块线程直接调 `RedisModule_Set` 安全吗?** A: 不安全。必须先拿线程安全上下文并 `ThreadSafeContextLock`(获取 GIL,module.c:8727);GIL 在主线程 beforeSleep 释放、afterSleep 重新获取(server.c:1960、1981),所以模块线程只在事件循环睡眠窗口内真正并行。
9. **Q: 模块写命令不调 Replicate 会怎样?** A: 内核不感知模块的数据变更,内存生效但 AOF/副本缺失 → 主从永久不一致、重启丢数据。模块必须 `ReplicateVerbatim`/`RM_Replicate`(module.c:3606、3651)或把类型变更交由 rdb_save/aof_rewrite 表达。
10. **Q: 键空间通知回调里能写键吗?** A: 危险且被抑制:回调是同步的,运行在命令逻辑中段(module.c:8849-8857 警告);内核用 execution_nesting 防止回调内命令提前传播(8997-9001),规范做法是 `RM_AddPostNotificationJob`(8946)。

## 8. 深挖方向

1. **GIL 的公平性与延迟**:单把 `moduleGIL` 互斥锁 + beforeSleep/afterSleep 放收(server.c:1960-1984),结合 `RM_Yield` 的非主线程管道委托(module.c:2462-2478),可画出"模块线程与主线程的交错时序图",量化长 GIL 占用对 P99 的影响。
2. **`RM_Call` 的执行单元嵌套**:`RM_Call`(module.c:6423)与 `enterExecutionUnit/exitExecutionUnit`(826-829、8997-9025)如何统一处理"通知→Call→再通知"的传播合并与缓存时钟(`RM_CachedMicroseconds`,module.c:2372)。
3. **模块配置系统**:7.0 加入的 `RM_RegisterBoolConfig/Numeric/String/Enum` 家族(module.c:13123 起)如何在 `config.c` 的 standardConfig 数组中动态插拔(`removeConfig`,module.c:12313-12323),以及 `module_configs_queue` 的启动顺序约束(12368-12378)。
4. **命令过滤器与安全面**:`moduleCallCommandFilters`(module.c:11011)在命令路径的精确位置、过滤器能否改写 argv、以及它对权限模型(ACL 之前/之后)的影响。
5. **SharedAPI 模块间依赖**:`RM_ExportSharedAPI`(module.c:10802)/`RM_GetSharedAPI`(10846)与 `usedby/using` 链表如何构成模块依赖图,卸载顺序如何保证(module.c:12660 的守卫)。

## 9. 写作要点速查表

| 要点 | 位置 |
|---|---|
| RM_ vs RedisModule_ 命名缘由(符号防覆盖) | src/module.c:787-795 |
| `RM_GetApi`:API 表查询(server.moduleapi) | src/module.c:797-808 |
| `RedisModule_Init` 静态内联 + APIVER_1 | src/redismodule.h:1364 / 42 |
| `RM_SetModuleAttribs`:模块结构创建,onload=1 | src/module.c:2307(2337) |
| 命令分发器 `RedisModuleCommandDispatcher` | src/module.c:930 |
| `RM_CreateCommand` 守卫与注册(flags 列表 1201-1258) | src/module.c:1280(1305) |
| ACL:新增类别 / 命令挂类别 | src/module.c:1501 / 1573 |
| Type ID 编码:9 字符×6bit+10bit encver | src/module.c:6790 |
| `RM_CreateDataType`:五回调+版本化扩展回调 | src/module.c:7069(7079-7137) |
| RDB 模块值:写 Type ID + rdb_save + EOF | src/rdb.c:1150-1173;RDB_TYPE_MODULE_2=7(rdb.h:62) |
| AUX 段:MODULE_AUX=247,缺失即 exit(1) | src/rdb.h:90;src/rdb.c:3505-3523 |
| AOF 重写出口 `RM_EmitAOF` | src/module.c:7671 |
| `moduleLoad`:dlopen/dlsym OnLoad | src/module.c:12546(12559/12564) |
| `moduleUnload` 四道守卫(类型不可卸载) | src/module.c:12647(12656-12672) |
| `moduleBlockClient`:Lua/MULTI 禁止、blockForKeys | src/module.c:7920(7977-7984) |
| `RM_UnblockClient` 线程安全投递 + 管道唤醒 | src/module.c:8402(8355-8367) |
| 解阻塞批处理(beforeSleep 路径) | src/module.c:8451;src/blocked.c:772 |
| GIL:beforeSleep 放 / afterSleep 收 / 模块侧 Lock | src/server.c:1960/1981;src/module.c:8727/8770 |
| 定时器:单 ae timer + rax 虚拟定时器 | src/module.c:9315/9330/9390 |
| `RM_Replicate`:alsoPropagate,A/R 修饰,MULTI 包裹 | src/module.c:3606(3624-3628);3575-3577 |
| `RM_SignalKeyAsReady`:模块类型唤醒阻塞客户端 | src/module.c:8350 |
| 键空间通知分发 + AddPostNotificationJob | src/module.c:8978 / 8946 |
| MODULE LOAD/LOADEX/UNLOAD/LIST 子命令 | src/module.c:13904-13951 |
| 内置模块:vector sets 经模块 API 注册 | src/module.c:12332-12339 |
