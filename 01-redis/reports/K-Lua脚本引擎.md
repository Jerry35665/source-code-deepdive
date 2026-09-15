# K 篇 · Redis Lua 脚本引擎:从 EVAL 到 Functions

> 调研基线:redis unstable 分支,commit `e8726d18`(2025-09-15),`version.h` 为 255.255.255 开发标记。所有行号均以该 commit 为准,标注格式 `文件:行号`(仓库相对路径)。
> 本文补齐卷一未覆盖的脚本子系统,涉及文件:`src/eval.c`(1758 行)、`src/script_lua.c`(1721 行)、`src/script.c`(684 行)、`src/functions.c`(1132 行)、`src/function_lua.c`(511 行),以及被魔改的内嵌 Lua 5.1(`deps/lua/src/`)。

---

## 1. 全景:一次 EVAL 的旅程

脚本引擎 7.0 后拆成三层:`eval.c` 只管 legacy EVAL/SCRIPT 命令与 LDB 调试器;`functions.c`+`function_lua.c` 管 Functions 库模型;`script.c`+`script_lua.c` 是两者共用的"运行时"(运行上下文 scriptRunCtx、redis.call 桥、Lua API 注册)。三个家族的命令:EVAL/EVALSHA/EVAL_RO/EVALSHA_RO 与 FCALL/FCALL_RO(命令标志同为 NOSCRIPT/SKIP_MONITOR/MAY_REPLICATE/NO_MANDATORY_KEYS/STALE,`commands/eval.json`、`commands/fcall.json`),SCRIPT 子命令(`eval.c:669-741`)与 FUNCTION 子命令(`functions.c:432-870`)。

```
 client                      Redis 主线程(单线程,VM 阻塞一切)                复制流 / AOF
   │                              │
   │ EVAL "..." 1 k a ───────────▶│ processCommand → call()
   │                              │  ├ getCommandFlags → evalGetCommandFlags   (eval.c:391)
   │                              │  ├ sha1hex → 函数名 f_<sha1>               (eval.c:441)
   │                              │  ├ registry 查 f_<sha1>
   │                              │  │   ├ 无+EVAL   → luaL_loadbuffer 编译入缓存 (eval.c:458)
   │                              │  │   └ 无+EVALSHA → -NOSCRIPT               (eval.c:583)
   │                              │  ├ scriptPrepareForRun:script 声明的 flags  (script.c:177)
   │                              │  │    决定 write/oom/stale/cross-slot 安检面
   │                              │  ├ luaCallFunction:填 KEYS/ARGV → lua_pcall (script_lua.c:1613)
   │                              │  │      ┌─── Lua VM(lctx.lua,全机唯一)───┐
   │                              │  │      │ redis.call(...)                │
   │                              │  │      │  └▶ luaRedisGenericCommand     │ (script_lua.c:883)
   │                              │  │      │      └▶ scriptCall 五道安检    │ (script.c:616)
   │                              │  │      │          └▶ call(fake client) ─┼─▶ 内部写命令逐条
   │                              │  │      │   每条命令 = 一个"效果"         │    传播 AOF/副本
   │                              │  ├ scriptResetRun:preventCommandPropagation (script.c:321)
   │◀───────── 脚本返回值 luaReplyToRedisReply 转 RESP ─────────┤  → EVAL 本身不进 AOF/复制流
```

要点:脚本的**可见副作用**(数据写入)以单命令形式进入复制流与 AOF,而 EVAL 命令本身被抑制传播——这就是 7.0 起的"效果复制"(§4)。

四个文件的职责切分值得记住,它解释了很多行号走向:

| 文件 | 角色 | 不负责 |
|---|---|---|
| src/eval.c | EVAL/EVALSHA 命令、脚本缓存字典与 LRU、LDB 调试器、`SCRIPT` 子命令 | redis.call 桥(在 script_lua.c) |
| src/script_lua.c | 两引擎共用的 Lua API 注册、redis.call/pcall 桥、Lua↔RESP 双向转换、超时钩子 | 安检与传播决策(在 script.c) |
| src/script.c | `scriptRunCtx` 生命周期、flags→命令标志翻译、逐命令安检、KILL、超时事件重入 | Lua 栈操作 |
| src/functions.c + function_lua.c | Functions 库模型、引擎虚表、FUNCTION 子命令;后者是 LUA 引擎实现 | EVAL 缓存 |

---

## 2. EVAL 专节

### 2.1 lua_State:初始化、复用与重置

Redis 为 EVAL 保留**全局唯一**的 Lua 解释器,所有客户端共用:`struct luaCtx { lua_State *lua; client *lua_client; dict *lua_scripts; list *lua_scripts_lru_list; unsigned long long lua_scripts_mem; } lctx;`(`eval.c:59-65`),注释直说 "We use just one for all clients"。初始化在 `scriptingInit()`(`eval.c:170-257`):

1. `createLuaState()` 建虚拟机(`eval.c:177`);jemalloc 构建下走私有 arena + 私有 tcache 分配器(`script.c:52-107`),避免 Lua 内存分配扰动碎片整理线程;
2. 建 `lua_scripts` 字典(SHA1→脚本体)与 LRU 链表(`eval.c:186-188`);
3. `luaRegisterRedisAPI()` 注册 `redis.*` API(`eval.c:190`;实现 `script_lua.c:1403-1493`);
4. 注册调试器钩子 `redis.breakpoint/debug` 和已成摆设的 `redis.replicate_commands`(`eval.c:192-208`);
5. 加载一段 Lua 写的错误处理器 `__redis__err__handler`,顺手把 `debug` 库置 nil(`eval.c:216-235`);
6. 创建"假客户端" `lua_client`,打上 `CLIENT_SCRIPT | CLIENT_DENY_BLOCKING`(`eval.c:241-247`)——脚本内所有命令都以它执行,因此天然禁止阻塞命令;
7. 最后把全局表加错误元表并**递归只读锁**(`eval.c:249-254`)。

脚本执行完并不销毁 VM,只做增量 GC(`luaGC`,每 50 次调用走一步,`script_lua.c:1714-1721`;EVAL 侧计数器在 `eval.c:27`,Functions 侧另有独立计数器 `function_lua.c:38`——注释见 `script_lua.c:1712-1713`)。整个 VM 何时重建?只有 `SCRIPT FLUSH` → `scriptingReset()`(`eval.c:287-290`,命令分支 `eval.c:689-702`),支持 ASYNC 惰性释放(`eval.c:280-285`)。Functions 引擎则是**另一个**独立 `lua_State`(`function_lua.c:429-431`),两台 VM 互不复用。

### 2.2 编译与 sha1 寻址

EVAL 把脚本体整体 SHA1 后命名成 Lua 函数 `f_<40位hex>` 存进 registry(`evalCalcFunctionName` `eval.c:296-317`;`sha1hex` 实现 `eval.c:99-114`)。首次 EVAL 的编译入库在 `luaCreateFunction()`(`eval.c:434-491`):

```c
funcname[0] = 'f'; funcname[1] = '_';
sha1hex(funcname+2, body->ptr, sdslen(body->ptr));
if ((de = dictFind(lctx.lua_scripts, funcname+2)) != NULL)
    return dictGetKey(de);                    // 已存在,幂等返回
...
if (luaL_loadbuffer(lctx.lua, ..., "@user_script")) { ... }   // 编译(eval.c:458)
lua_setfield(lctx.lua, LUA_REGISTRYINDEX, funcname);          // 挂进 registry(eval.c:471)
l->body = body; l->flags = script_flags;
sds sha = sdsnewlen(funcname+2, 40);
l->node = luaScriptsLRUAdd(c, sha, evalsha);                  // 进 LRU(eval.c:480)
dictAdd(lctx.lua_scripts, sha, l);                            // SHA1 → luaScript(eval.c:481)
```

之后每次 EVAL/EVALSHA 只是 `lua_getfield(registry, f_<sha>)` 取出函数指针直接 `lua_pcall`(`eval.c:574-597`),**零重复编译**。EVALSHA 找不到函数时直接回 `NOSCRIPT No matching script. Please use EVAL.`(`shared.noscripterr`,`server.c:2037-2038`;分支 `eval.c:583-586`)。`SCRIPT LOAD` 走同一个 `luaCreateFunction(c, argv[2], 1)`(`eval.c:713-716`),`SCRIPT EXISTS` 就是查字典(`eval.c:703-712`)。脚本体首行支持 `#!lua flags=...` shebang 声明 flags,解析在 `evalExtractShebangFlags`(`eval.c:324-387`)。

### 2.3 redis.call 桥:luaRedisGenericCommand

`redis.call`/`redis.pcall` 在注册时指向同一实现、仅"是否抛错"不同(`script_lua.c:1019-1026`)。核心 `luaRedisGenericCommand`(`script_lua.c:883-987`)是一台"C 协议转换泵":

1. 从 registry 取回当前 `scriptRunCtx`(`script_lua.c:885`);递归调用检测 `inuse`(防调试钩子搞事,`script_lua.c:896-910`);
2. `luaArgsToRedisArgv` 把 Lua 栈上的参数转成 `robj*` 数组,带 argv 数组复用与小型参数对象缓存池 `lua_args_cached_objects`(`script_lua.c:774-780, 782-851, 853-881`);数字参数不能走 `lua_tolstring`(丢精度),单独用 `double2ll`/`fpconv_dtoa`(`script_lua.c:811-817`);
3. `scriptCall()`(`script.c:616-679`)做全套"像真命令一样"的安检:参数量、NOSCRIPT(`script.c:632-635`)、stale、**ACL(按调用者用户)**(`script.c:641, 620`)、写权限、OOM、集群 slot(`script.c:658`),任一失败以 `afterErrorReply` 写回假客户端(`script.c:676-678`);写命令则置 `SCRIPT_WRITE_DIRTY`(`script.c:653-656`);
4. `call(c, call_flags)` 真正执行,`call_flags` 按运行上下文的 `repl_flags` 携带 `CMD_CALL_PROPAGATE_AOF|CMD_CALL_PROPAGATE_REPL`(`script.c:664-671`)——**传播发生在这一层**;
5. 把假客户端输出缓冲区的 RESP 回复解析成 Lua 值:`redisProtocolToLuaType`(`script_lua.c:218-222`,回调表 199-216),错误转成 `{err="..."}` 表(`script_lua.c:307-327`);快速路径直接偷用客户端静态缓冲避免拼 SDS(`script_lua.c:943-959`);
6. 脚本最终 return 的 Lua 值再反向转 RESP 给真实调用者:`luaReplyToRedisReply`(`script_lua.c:583-767`),支持 `{ok=}`/`{err=}`/`{double=}`/`{big_number=}`/`{verbatim_string=}`/`{map=}`/`{set=}` 及数组。

设计注释说得很直白:借"未连接客户端"复用整条命令执行路径,脚本引擎不需要任何 Redis 内部 API,"the script is like a normal client that bypasses all the slow I/O paths"(`script_lua.c:182-191`)。

### 2.4 随机性与写语义:shebang flags 体系

脚本声明面共 5 个 flag:`no-writes / allow-oom / allow-stale / no-cluster / allow-cross-slot-keys`(`script.c:23-30`);对应位定义 `script.h:62-67`。`scriptFlagsToCmdFlags()` 把命令自身的 STALE/DENYOOM/WRITE/MAY_REPLICATE 清掉后按脚本声明重写(`script.c:157-174`)。命令执行前的静态检查在 `evalGetCommandFlags`(`eval.c:391-412`,入口接线 `server.c:4053-4059`),并把字典项缓存进 `c->cur_script` 供后续复用(`eval.c:399`)。运行期逐命令检查在 `scriptPrepareForRun`(`script.c:177-302`):只读副本写(`script.c:209-212`)、磁盘故障 MISCONF(`script.c:215-227`)、`*_ro` 变体禁写(`script.c:229-232`)、min-replicas(`script.c:235-239`)、OOM(`script.c:244-250`);`FCALL_RO`/`no-writes` 置 `SCRIPT_READ_ONLY`,写命令在 `scriptVerifyWriteCommandAllow` 处被拒(`script.c:283-287, 406-411`)。

关于"随机命令标记":旧版靠给 SRANDMEMBER/SPOP 等打 `random` 标志决定整脚本复制——本 commit 源码已**不存在 CMD_RANDOM**(server.h 全文无匹配),因为它随效果复制一起消亡(§4)。无 shebang 的 legacy EVAL 则落入 `SCRIPT_FLAG_EVAL_COMPAT_MODE` 兼容模式(`script.h:66`),保持旧行为:stale 副本直接拒(`script.c:252-258`)、默认可写可 OOM。

Functions 侧同构但更直接:`fcallGetCommandFlags` 拿函数自身的 `f_flags` 翻译命令标志(`functions.c:609-617`),flags 来自库代码里 `redis.register_function{flags={...}}` 的声明,经 `luaRegisterFunctionReadFlags` 对 `scripts_flags_def` 白名单逐个匹配(`function_lua.c:235-274`,未知 flag 直接拒绝)。

### 2.5 附:LDB 调试器的进程模型

`SCRIPT DEBUG YES` 后,EVAL 走 `evalGenericCommandWithDebugging`(`eval.c:982-989`)。默认(async)模式 `ldbStartSession` 会 **fork 子进程**跑调试会话,父进程直接 `freeClientAsync` 甩掉该连接(`eval.c:865-890`),所以慢脚本调试不影响主库数据;行钩子 `luaLdbLineHook`(`eval.c:1711-1758`)在断点/步进/超时三种情况下进入 REPL(`ldbRepl`,`eval.c:1580-1707`),直接在钩子里对调试连接做裸 I/O 而不回事件循环。`SYNC` 模式不 fork、共享真实数据集(`eval.c:866`),abort 时已执行写不回滚——文档语焉不详处,源码里一目了然。

---

## 3. 缓存与 Functions 专节

### 3.1 EVAL 脚本缓存的驱逐:LRU 500

脚本缓存**有界**:`luaScriptsLRUAdd` 只对 EVAL 来源脚本生效,SCRIPT LOAD 永不驱逐(`eval.c:533-535`);超过 `LRU_LIST_LENGTH 500`(`eval.c:532`)就摘链表头最老脚本,经 `luaDeleteFunction` 从 registry 置 nil 并删字典(`eval.c:497-516`),计入 `server.stat_evictedscripts`(`eval.c:538-543`)。每次命中把节点 O(1) 挪到队尾(`eval.c:614-619`)。为什么敢驱逐 EVAL 而不敢驱逐 SCRIPT LOAD?注释:滥用 EVAL 的用户会每次生成新脚本,EVAL 自身带回脚本体、不存在"驱逐后 EVALSHA 找不到"的流水线事故(`eval.c:518-531`)。内存口径由 `evalScriptsMemoryVM/Engine` 汇报(`eval.c:743-756`)。

### 3.2 FUNCTION:库模型与引擎抽象

Functions 不按 SHA1 寻址,而是"命名库 → 命名函数"两级字典:`functionsLibCtx { libraries; functions; cache_memory; engines_stats }`(`functions.c:36-41`),全局当前上下文 `curr_functions_lib_ctx`(`functions.c:103`),引擎注册表 `engines`(`functions.c:100`)。引擎是虚表(`functions.c:499-509`):create/call/get_used_memory/free_function/free_ctx,目前只有 "LUA" 一个实现(`function_lua.c:31, 510`),注册时同样创建带 `CLIENT_SCRIPT|CLIENT_DENY_BLOCKING` 的假客户端(`functions.c:415-416`)。

`FUNCTION LOAD [REPLACE] <code>` 流程(`functions.c:1038-1072`):

1. 解析首行 shebang 元数据 `#!lua name=<库名>`(`functionExtractLibMetaData`,`functions.c:891-948`,库名合法字符校验 `functions.c:873-889`);
2. `functionsCreateWithLibraryCtx`(`functions.c:958-1031`)查引擎、查同名库、调 `engine->create`(`functions.c:992`)——即 `luaEngineCreate`(`function_lua.c:88-142`):临时把全局表 `__index` 换成 `__LIBRARY_API__`(`function_lua.c:94-99`),`luaL_loadbuffer("@user_function")` 编译后**立即执行一次**让库体调用 `redis.register_function`(`function_lua.c:102, 116-118`);
3. `redis.register_function` 只能在 LOAD 期间调用(registry 里查不到 LOAD 上下文即报错,`function_lua.c:403-410`),回调函数经 `luaL_ref` 存进 registry,得到 `luaFunctionCtx{lua_function_ref}`(`function_lua.c:311-314, 46-49`);
4. 全局函数名字典查重(`functions.c:1002-1011`)、`libraryLink` 双向挂表(`functions.c:304-323`);零注册函数的库直接报错(`functions.c:996-999`)。

FCALL 路径:`fcallCommandGeneric`(`functions.c:619-656`)→ 查函数字典 → `scriptPrepareForRun` → `engine->call`(`functions.c:653`)→ `luaEngineCall`(`function_lua.c:147-170`)→ 与 EVAL 共用的 `luaCallFunction`(`script_lua.c:1613`)。区别仅在:EVAL 模式把 KEYS/ARGV 写成**全局变量**,Functions 模式作为**函数参数**传入(`script_lua.c:1633-1647` 的 `SCRIPT_EVAL_MODE` 分支与 `lua_pcall` 0参/2参之别,`script_lua.c:1656-1660`)。Functions 的隔离更强:运行在一张空全局表上,靠元表 `__index` 透读到默认全局(`function_lua.c:489-496`),EVAL 时代脚本污染全局的可能性被结构性消灭。

`FUNCTION KILL/FLUSH/LIST/STATS/DELETE` 分别在 `functions.c:603-605, 804-827, 506-581, 432-473, 586-600`;DELETE/FLUSH/RESTORE/LOAD 都置 `server.dirty++` 让其按写命令持久化与复制(`functions.c:598, 825, 790, 1070`)。

### 3.3 Functions 的持久化:进 RDB 的库代码

函数库作为数据随 RDB 持久化:`rdbSaveFunctions` 逐库写 `RDB_OPCODE_FUNCTION2`(值 245,`rdb.h:88`)+ 库源码裸字符串(`rdb.c:1349-1366`),在 `rdbSaveRio` 主流程中调用(`rdb.c:1473`,可用 `SLAVE_REQ_RDB_EXCLUDE_FUNCTIONS` 排除)。加载端 `rdbFunctionLoad`(`rdb.c:3291-3322`)取出源码后调 `functionsCreateWithLibraryCtx` **重新完整编译**——RDB 里只有源码,没有字节码;7.0 rc1/rc2 的旧 opcode `FUNCTION_PRE_GA`(246,`rdb.h:89`)在加载时被拒(`rdb.c:3558-3560`,`functions.c:763-766`)。`FUNCTION DUMP/RESTORE` 复用同一格式(每库前置 FUNCTION2 opcode,RDB 版本号+crc64 收尾,`functions.c:689-709`),RESTORE 支持 FLUSH/APPEND/REPLACE 三策略及回滚(`functions.c:721-801`,碰撞回滚在 `libraryJoin` `functions.c:331-401`)。对比:EVAL 脚本**从不进 RDB**——脚本只是操作数据的代码,效果已随数据落盘。

---

## 4. 复制专节:整脚本传播 → 效果复制

**演进三阶段**(代码现状均为效果复制):

1. **≤3.2 整脚本复制**:EVAL 原文进 AOF/复制流,要求脚本确定性——随机命令被拒,连带催生 `redis.replicate_commands()` 之前的诸多限制;
2. **3.2-6.x 可选效果复制**:脚本内 `redis.replicate_commands()` 开启逐命令传播;
3. **7.0 起效果复制唯一化**(PR #8206 方向):`replicate_commands` 退化为永远返回 true 的空操作(`eval.c:148-158`,注释 "DEPRECATED: Now do nothing and always return true"),CMD_RANDOM 标志整体删除。

**现状代码链路**(这是本篇最值得背下来的因果链):

- 内层:脚本每条 `redis.call` 经 `scriptCall → call()`,以假客户端身份按 `run_ctx->repl_flags`(默认 `PROPAGATE_AOF|PROPAGATE_REPL`,`script.c:281`)传播——call() 内部的传播判定是 `dirty 则 PROPAGATE_AOF|REPL`、`CLIENT_PREVENT_*` 可关断(`server.c:3849-3887`,关键判定 `server.c:3852, 3861`),最终 `alsoPropagate`(`server.c:3884`);
- 外层:`scriptResetRun` 对**原始客户端**调 `preventCommandPropagation()` 置 `CLIENT_PREVENT_PROP`(`script.c:321`;定义 `server.c:3530-3532`),于是 EVAL 命令自己在 call() 收尾的传播检查中被跳过(`server.c:3852`)——**脚本原文永不进复制流**;
- 细粒度开关:`redis.set_repl(REPL_NONE/REPL_AOF/REPL_SLAVE/REPL_ALL)`(`script_lua.c:1095-1114`,注册 1448-1471 → `scriptSetRepl` `script.c:577-583`);
- 在 MULTI 里跑脚本时假客户端被标 `CLIENT_MULTI`(`script.c:274-276`),内部写随 EXEC 传播;
- `evalCommand`/`fcallCommandGeneric` 仍先喂 MONITOR(`eval.c:631-634`,`functions.c:621`),MONITOR 看到的是 EVAL 原文+内部命令两层。

**FUNCTION 的复制是另一条路**:FUNCTION LOAD/DELETE/FLUSH/RESTORE 本身是 WRITE 命令(`commands/function-load.json` 标 WRITE+DENYOOM)且 `server.dirty++`,整条命令(含库源码)原文复制,与数据命令无异。

**AOF 含义**:重放 AOF 时不再需要 Lua 引擎参与"脚本语义",7.0 前"EVALSHA 在 AOF 重放时找不到脚本"的补丁问题(旧版需把 EVALSHA 回填为 EVAL,见 `eval.c:473-475` 遗留注释)在效果复制下自然消失,`eval.c:626-628` 注释明确 "newly generated AOF files, in which scripts propagate effects rather than scripts"。

**对从库的一个推论**:从库重放的是效果命令流(mustObeyClient 的 master/AOF 客户端在 `scriptPrepareForRun` 多数安检中被豁免,`script.c:209, 216, 236, 464`),但它仍要执行脚本本体吗?——不需要。从库收到的复制流里只有内部写命令;只有当 AOF/RDB 是 7.0 前旧格式或主从版本混布时才会遇到 EVAL 原文重放。这也解释了为什么从库依然保留完整脚本引擎:处理旧 AOF、运维命令与历史兼容。

---

## 5. 超时与沙箱专节

### 5.1 luaMaskCountHook:脚本的定时自断点

Lua 是协作式 C 嵌入,主线程跑脚本时事件循环全停。Redis 用 Lua count hook 制造中断点:当配置了超时阈值,`luaCallFunction` 挂钩 `LUA_MASKCOUNT, 100000`——每 10 万条 VM 指令触发一次(`script_lua.c:1623-1625`;调试模式换成 `luaLdbLineHook` LINE+COUNT,`script_lua.c:1626-1628`)。阈值即 `busy-reply-threshold`(旧名 `lua-time-limit`,默认 5000ms,`config.c:3237`)。

```c
static void luaMaskCountHook(lua_State *lua, lua_Debug *ar) {
    scriptRunCtx* rctx = luaGetFromRegistry(lua, REGISTRY_RUN_CTX_NAME);
    if (scriptInterrupt(rctx) == SCRIPT_KILL) {
        serverLog(LL_NOTICE, "Lua script killed by user with SCRIPT KILL.");
        lua_sethook(lua, luaMaskCountHook, LUA_MASKLINE, 0);  // 改行钩子,防 pcall 吞错
        luaPushError(lua, "Script killed by user with SCRIPT KILL...");
        luaError(lua);                                        // 长跳出脚本
    }
}                                  // script_lua.c:1551-1568
```

`scriptInterrupt`(`script.c:126-155`):未超时直接放行(`script.c:134-137`);超时则进入 timedout 态(`enterScriptTimedoutMode` → `blockingOperationStarts`,`script.c:44-50`),`protectClient` 保护调用者后 `processEventsWhileBlocked()` 重入事件循环伺候其他客户端(`script.c:150-152`)。此后新命令在 `processCommand` 被 `-BUSY` 拒绝(EVAL 场景回 `slowevalerr`,FUNCTION 场景回 `slowscripterr`,`server.c:4378-4386`;错误文案 `server.c:2041-2045`),仅 ALLOW_BUSY 命令放行。`SCRIPT KILL` 只是置 `SCRIPT_KILLED` 标志(`script.c:371`),等下一个钩子点长跳。**不可杀条件**已经写过数据的脚本(WRITE_DIRTY)回 `-UNKILLABLE`(`script.c:353-360`),主从链路中来自 master 的脚本同样不可杀(`script.c:348-352`);EVAL 与 FUNCTION 的 KILL 命令互不通用(`script.c:361-370`,错误对象即 `slowscripterr`/`slowevalerr`,文案见 `server.c:2041-2045`)。timedout 态的收尾在 `scriptResetRun`:退出 timedout、`unprotectClient`、若是从库则把 master 重新排入 reprocessing 队列(`script.c:35-42, 311-316`)。LDB 调试模式下超时转入手动交互(`eval.c:1725-1735`)。另有一处独立超时:FUNCTION LOAD 库体执行限 500ms(`LOAD_TIMEOUT_MS` `functions.c:16`,钩子 `luaEngineLoadHook` `function_lua.c:68-79`),master 传播来的 LOAD 不限时(`functions.c:1060-1062`)。

### 5.2 沙箱:三层剥离与全局锁

**第一层:库面裁剪**。加载的库只有 base/table/string/math/debug/os/cjson/struct/cmsgpack/bit(`script_lua.c:1224-1239`);`package` 明确不加载——"#if 0 ... for sandboxing concerns"(`script_lua.c:1236-1238`)。**os 库在 Lua 源码级被阉割**:`luaopen_os` 只注册 `os.clock` 一项,原 syslib 全表 UNUSED("Only a subset is loaded currently, for sandboxing concerns",`deps/lua/src/loslib.c:242-254`)。`math.random/randomseed` 被替换成基于 `redisLrand48` 的跨平台确定性实现(`script_lua.c:1481-1492, 1511-1548`)。`pcall` 也被替换以兼容 7.0 错误对象从字符串变表的格式(`script_lua.c:998-1016, 1410-1411`)。

**第二层:全局变量白名单过滤**。注册 API **之前**先给全局表挂 `__newindex` 元方法(`luaRegisterRedisAPI` 开头,`script_lua.c:1404-1406`),之后所有库注册写入全局都要过闸:allow list 放行(`script_lua.c:31-109`),deny list(`dofile/loadfile/print`,`script_lua.c:115-120`)静默丢弃不告警,其余记录警告(`luaNewIndexAllowList`,`script_lua.c:1282-1325`)。这就是 `EVAL "return loadfile('x')"` 报 `Script attempted to access nonexistent global variable 'loadfile'` 的原因(测试断言 `tests/unit/scripting.tcl:1161-1177`)。`debug` 库允许加载但初始化错误处理器后被脚本片段 `debug = nil` 摘除(`script_lua.c:89-92`;`eval.c:217-218`、`function_lua.c:454-455` 内嵌代码)。

**第三层:递归只读锁**。初始化尾声对全局表及可达子表、元表逐一 `lua_enablereadonlytable`(`luaSetTableProtectionRecursively`,`script_lua.c:1343-1368`;EVAL 侧调用 `eval.c:249-254`,Functions 侧 `function_lua.c:475-478`)。只读表是 Redis 对 Lua 5.1 的魔改原语(`deps/lua/src/lapi.c:1094-1102`);写 KEYS/ARGV 这类"合法临时全局"时要先解锁再上锁(`script_lua.c:1635-1646`)。访问不存在全局由错误元表拦截报错(`luaProtectedTableError`,`script_lua.c:1254-1266`)。

---

## 6. 设计动机

**为什么内嵌 Lua(2011,eval.c 版权 2011-Present)**:① 原子性白拿——单线程执行天然串行化,脚本 = 免费 WATCH/MULTI 的复合操作;② 带宽与往返——把 N 次往返折叠成 1 次;③ "假客户端"桥(`script_lua.c:182-191` 注释)让引擎零侵入复用整条命令路径,不需要为脚本另写一套内部 API,这是整个设计最省力的一步。选 Lua 5.1 则因为小、可嵌、协程无用武之地反而要禁(`CLIENT_DENY_BLOCKING`,`eval.c:246`)。

**为什么引入 Functions(7.0)**:EVAL 有三个结构性缺陷——SHA1 寻址不可读不可运维、脚本即贴即用导致服务器端没有任何"已部署代码"的治理视图、缓存无持久化(重启即空,靠 AOF 回填)。Functions 把**代码变成有名字、有生命周期、随 RDB 持久化的实体**(`functions.c:36-41` 库模型;`rdb.c:1473` 持久化),命名函数 + 描述 + flags(`function_lua.c:296-329`)就是给"服务器端应用"补上包管理;引擎虚表(`functions.c:499-509`)还为 JS 等多引擎留了插槽。独立的空全局表(`function_lua.c:489-496`)解决了 EVAL 脚本可以互相留全局状态的脏问题。

**为什么效果复制**:整脚本复制的前提是"脚本确定性",但这既难保证(时间、随机、TTL、Lua 遍历顺序)又难表达(需要 random/no-writes 标志体系)。效果复制把复制语义从"代码"降到"数据变更",① 复制流与 AOF 收敛为同一命令序列,② 随机命令合法化(CMD_RANDOM 之死),③ EVALSHA 失联/脚本驱逐等边角问题消失,④ 从库端看不再需要维护脚本缓存来重放。代价是复制流量可能放大(脚本内 N 条命令传 N 条),以及脚本必须在主从上确定性执行才不漂移——所以 flags 体系保留下来用于**权限与运行门禁**而非复制模式选择。

---

## 7. FAQ 素材

1. **EVAL 和 EVALSHA 的实现差异有多大?** 仅"找不到函数"分支不同:EVAL 现场编译入库(`eval.c:588-593`),EVALSHA 回 NOSCRIPT(`eval.c:583-586`);其余共用 `evalGenericCommand`(`eval.c:550`)。
2. **脚本缓存会无限增长吗?** 不会。EVAL 来源脚本走 LRU-500 驱逐(`eval.c:532-548`);SCRIPT LOAD 来源永不驱逐——因为驱逐会破坏后续 EVALSHA(注释 `eval.c:518-531`)。
3. **SCRIPT FLUSH 做了什么?** 整个 lua_State 销毁重建(`scriptingReset` `eval.c:287-290`),jemalloc 下连带私有 tcache 销毁(`eval.c:260-276`),可 ASYNC。
4. **redis.call 和 redis.pcall 区别?** 同一 C 函数,`raise_error` 参数不同:call 出错即 `lua_error` 长跳,pcall 把 `{err=...}` 表返回给脚本(`script_lua.c:1019-1026`)。
5. **脚本里的 ACL 用谁的身份?** 调用者的:`scriptCall` 把 `c->user` 换成原始客户端 user 再检(`script.c:620, 641`),可用 `redis.acl_check_cmd` 预检(`script_lua.c:1119-1149`)。
6. **FUNCTION 库在 RDB/AOF 里是什么形态?** RDB:每库一段 `FUNCTION2` opcode + 源码原文,加载时重新编译(`rdb.c:1349-1366, 3291-3322`);AOF:FUNCTION LOAD 整命令原文(效果复制仅针对 EVAL/FCALL 内的写命令)。
7. **脚本超时后 SCRIPT KILL 一定能杀掉吗?** 写过数据就杀不掉(UNKILLABLE,`script.c:353-360`),只能等自然结束或 SHUTDOWN NOSAVE;没写过则下一个钩子点(最多 10 万条指令)长跳退出。
8. **脚本为什么不能 BLPOP 等阻塞命令?** 假客户端带 `CLIENT_DENY_BLOCKING`(`eval.c:246`,`functions.c:416`),且 `call` 后断言未 BLOCKED(`script.c:672`)。
9. **KEYS/ARGV 是全局变量还是参数?** EVAL 是全局变量(写锁临时打开,`script_lua.c:1635-1646`);FCALL 是函数入参(`script_lua.c:1659`)——这也是 Functions 隔离更强的体现。
10. **redis.replicate_commands() 还有用吗?** 无用,恒返 true(`eval.c:148-158`),7.0 起效果复制是唯一模式。
11. **脚本 GC 会不会抖?** 每 50 次脚本做一次分步 GC(`LUA_GC_CYCLE_PERIOD` `script_lua.c:1714-1721`),EVAL/Functions 各自独立计数;首次入库与每次执行结束也各补一次(`eval.c:465, 488, 624`,`function_lua.c:140, 169`)。
12. **Lua 用的哪个版本、动过哪些刀?** 5.1 魔改:只读表原语(`deps/lua/src/lapi.c:1094`)、jemalloc 私有 arena/tcache(`script.c:52-93`)、os 库阉割(`deps/lua/src/loslib.c:242-254`)。
13. **脚本能读到 `debug` 库吗?** 初始化后即被置 nil(错误处理器加载片段 `debug = nil`,`eval.c:217-218`),但白名单仍为其保留名字空间(`script_lua.c:89-92`);`pcall` 也被同名 C 函数替换以兼容错误对象格式(`script_lua.c:998-1016`)。
14. **集群模式下脚本访问未声明键会怎样?** `scriptVerifyClusterState` 用假客户端跑 `getNodeByQuery`,跨 slot 未声明则报错(`script.c:476-536`,尤其 489, 522-530);shebang 声明 `allow-cross-slot-keys` 可放行(`script.c:294-296`),另有不阻断执行的兼容性统计 `scriptCheckClusterCompatibility`(`script.c:538-563`)。

## 8. 深挖方向

1. **效果复制的流量放大与"半脚本状态"**:脚本执行到一半被 KILL 不可能(WRITE_DIRTY 不可杀),但超时期间已传播的写命令与最终提交的一致性如何论证?可对照 `script.c:126-155` 与 `scriptKill` 的 WRITE_DIRTY 门禁写一篇"脚本中断语义"。
2. **两台 Lua VM 的内存治理**:jemalloc 私有 arena 如何让碎片整理线程跳过 Lua 页(`script.c:84-93`),配合 `MEMORY` 的 `evalScriptsMemoryVM/Engine`(`eval.c:743-756`)做量化。
3. **FUNCTION 引擎虚表 vs Module API**:同是扩展机制,Function 引擎注册面只有 7 个函数指针(`functions.c:499-509`),对照 I 篇 Module 的 RedisModule_* 体系(I-Module模块系统.md §2、§5),讨论"代码型扩展"两种形态的边界:数据类型/事件钩子只有 Module 能做,脚本执行只有引擎做。
4. **LDB 调试器的 fork 隔离**:默认异步模式 fork 子进程调试、父进程直接 freeClientAsync(`eval.c:865-890`),坑点在 `ldbEndSession` 的 exit 路径(`eval.c:918-945`)。
5. **只读表魔改的移植性**:Valkey 分叉后这套 Lua 补丁(`lua_enablereadonlytable` 等)成为双方共同维护负担,可追踪上游 Lua 5.1 vendoring 的演化。

## 9. 写作要点速查表

| 主题 | 函数/定义 | 位置 |
|---|---|---|
| 全局 Lua 上下文(单 VM) | `lctx` 结构体 | eval.c:59-65 |
| VM/脚本缓存初始化 | `scriptingInit` | eval.c:170-257 |
| SHA1→函数名 | `sha1hex` / `evalCalcFunctionName` | eval.c:99-114 / 296-317 |
| 编译入库 | `luaCreateFunction` | eval.c:434-491 |
| LRU 驱逐(仅 EVAL,500) | `luaScriptsLRUAdd` / `LRU_LIST_LENGTH` | eval.c:533-548 / 532 |
| EVAL 主流程 | `evalGenericCommand` | eval.c:550-629 |
| redis.call 桥 | `luaRedisGenericCommand` | script_lua.c:883-987 |
| 脚本内命令安检+传播 | `scriptCall` | script.c:616-679 |
| 运行上下文准备(flags) | `scriptPrepareForRun` / `scriptFlagsToCmdFlags` | script.c:177-302 / 157-174 |
| EVAL 本体不传播 | `preventCommandPropagation`(在 `scriptResetRun`) | script.c:321;server.c:3530-3532,3852 |
| 超时钩子 | `luaMaskCountHook` / `scriptInterrupt` | script_lua.c:1551-1568 / script.c:126-155 |
| KILL 门禁 | `scriptKill`(WRITE_DIRTY→UNKILLABLE) | script.c:343-373 |
| 随机 API 确定化 | `redis_math_random` | script_lua.c:1517-1548 |
| 沙箱 deny/allow list | `deny_list` / `luaNewIndexAllowList` | script_lua.c:115-120 / 1282-1325 |
| 递归只读锁 | `luaSetTableProtectionRecursively` | script_lua.c:1343-1368 |
| FUNCTION 库加载 | `functionLoadCommand`→`functionsCreateWithLibraryCtx` | functions.c:1038-1072 / 958-1031 |
| 引擎虚表(LUA) | `luaEngineInitEngine` | function_lua.c:428-511 |
| Functions 进 RDB | `rdbSaveFunctions` / `rdbFunctionLoad` | rdb.c:1349-1366 / 3291-3322 |
| 超时阈值配置 | `busy-reply-threshold`(lua-time-limit) | config.c:3237 |
| FCALL 主流程 / 函数 flags 翻译 | `fcallCommandGeneric` / `fcallGetCommandFlags` | functions.c:619-656 / 609-617 |
| replicate_commands 摆设化 | `luaRedisReplicateCommandsCommand` | eval.c:148-158 |
