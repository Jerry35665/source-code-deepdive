# 第 12 章 · Lua 脚本引擎:Redis 的嵌入式编程面(扩展卷卷末)

> 基线:commit `e8726d1`。行号以 src/eval.c、src/script_lua.c、src/script.c、src/functions.c 为准。

## 12.0 全景:一次 EVAL 的旅程

```
EVAL → 全机唯一 lua_State(lctx,eval.c:59-65;VM 仅在 SCRIPT FLUSH 重建 :287-290)
  → 脚本按 SHA1 编译成 registry 里的 f_<sha1> 函数(eval.c:441/:458/:471 零重复编译)
  → 执行:redis.call 桥(script_lua.c:883-987:Lua 参数→robj→五道安检→call()→RESP 回 Lua)
  → 复制:效果复制(7.0 唯一模式)——EVAL 本体不传播(:321 preventCommandPropagation),
     脚本内每条写命令逐条进复制流/AOF(:664-671→server.c:3849-3887)
```

**脚本缓存**:EVAL 来源脚本有 LRU-500 驱逐(eval.c:532-548),SCRIPT LOAD 永不驱逐;EVALSHA 未命中仅回 NOSCRIPT(:583-586)。

## 12.1 Functions(7.0+):库模型

FUNCTION LOAD 的库模型:库体在 LOAD 时执行一次以注册函数(functions.c:958-1031,500ms 限时 function_lua.c:68-79);RDB 逐库存 FUNCTION2 opcode+**源码原文**、加载重编译(rdb.c:1349-1366,:3291-3322);与 EVAL 的 sha1 匿名不同,**Functions 是有名字有版本的库**。

## 12.2 复制:脚本复制 vs 效果复制

旧模式:整脚本传播到从库重放(非确定性风险);**7.0 起唯一模式=效果复制**:内层脚本内每条写命令经假客户端 call() 携带 CMD_CALL_PROPAGATE_AOF|REPL 逐条传播(script.c:664-671→server.c:3849-3887),外层 scriptResetRun 对原始客户端 preventCommandPropagation(script.c:321→server.c:3852)——EVAL 本体永不进复制流/AOF;`redis.replicate_commands()` 已退化为恒返 true 空操作(eval.c:148-158);CMD_RANDOM 全仓消失。**效果复制的动机**:非确定性脚本(TIME/随机)在从库重放会分叉——只复制"实际效果"才是正确性。

## 12.3 超时与沙箱

**超时**:LUA_MASKCOUNT 10 万指令一次钩子(script_lua.c:1551-1568)→scriptInterrupt(script.c:126-155)重入事件循环,新命令收 -BUSY(server.c:4378-4386);**写过数据则 SCRIPT KILL 不可杀**(:343-360)——只读脚本可杀,写过的必须 SHUTDOWN NOSAVE 或等自然结束(原子性)。**沙箱**:os 库仅剩 os.clock 是 Lua 源码级阉割(deps/lua/src/loslib.c:242-254),dofile/loadfile/print 靠 globals `__newindex` deny list 丢弃(script_lua.c:115-120,:1282-1325),全局表递归只读锁(:1343-1368)。

## 12.4 设计动机

1. **为什么内嵌 Lua**:原子执行多条命令+带逻辑的数据访问——脚本在服务端执行免网络往返;对照 Module(卷一 10 章):Lua 是"数据脚本",Module 是"原生扩展";
2. **为什么效果复制**:非确定性脚本(SRANDMEMBER/TIME)的脚本复制会分叉——**复制"实际效果"是唯一正确**;
3. **10 万指令的中断粒度**:Lua debug hook 的计数钩子是唯一可靠的中断点——粒度是"能中断"与"够快"的折中;
4. **全局表只读锁**(:1343-1368):脚本间不共享全局变量(每个脚本一个干净环境)——防脚本互相污染。

## 12.5 FAQ

**Q1:EVALSHA 找不到脚本怎么办?**
回 NOSCRIPT(:583-586):客户端应先 EVAL 或 SCRIPT LOAD。

**Q2:脚本写了一半能 KILL 吗?**
写过数据的不能(:343-360):SCRIPT KILL 只对纯读/未写脚本有效。

**Q3:脚本是每次重新编译吗?**
不:SHA1 编译缓存于 registry(:441-491),EVALSHA 零编译。

**Q4:redis.call 的错误怎么回 Lua?**
错误转 `{err=}` 表(:307-327):脚本可捕获并自行处理。

**Q5:脚本里能用 os.time 吗?**
不能:os 库被阉割只剩 os.clock(loslib.c:242-254)——非确定性的排除。

**Q6:脚本有超时吗?**
busy-reply-threshold(默认 5s? config.c:3237):Lua hook 每 10 万指令检查。

**Q7:FUNCTION 与 EVAL 的区别?**
Functions=有名字有版本的库(functions.c:958-1031),RDB 持久化源码原文(rdb.c:1349-1366);EVAL=匿名一次性。

**Q8:脚本的全局变量会跨脚本共享吗?**
不会:全局表只读锁(:1343-1368)+每脚本干净环境——防互相污染。

**Q9:效果复制下从库和主库结果一致吗?**
一致:复制的是脚本内每条实际执行的写命令(:664-671)。

**Q10: Functions 库的 500ms 限时是什么?**
LOAD 时执行库体注册函数的限时(function_lua.c:68-79):防恶意库体死循环。

## 12.6 小结与扩展卷卷末语

本章结论:**Lua 引擎="单 VM 复用+SHA1 缓存+redis.call 桥+效果复制+hook 超时+全局只读沙箱"**。

至此《Redis 深读》扩展卷完(09-12:Stream/Module/defrag/Lua,基线 commit e8726d1)。Redis 第一卷(01-08)+扩展卷(09-12)合计 12 章:数据结构→事件→持久化→复制→内存→Stream→Module→defrag→Lua,Redis 的主干与外围基本闭合。全系列至此 **19 个项目目录、178 篇正文+152 份报告**。深挖方向:

1. lua_State 单 VM 在 MULTI+Lua 组合的状态污染面;
2. 效果复制(:664-671)对 Lua排序非确定性(如 table.sort 不稳定)的防护;
3. SCRIPT FLUSH(:287-290)在 Function 时代的兼容;
4. 全局只读锁(:1343-1368)的绕过面(weak table/metatable);
5. Function 库体 500ms(:68-79)对复杂库的注册超时。

— 《Redis 深读》扩展卷完。AI 编码助手:GLM-5.3-Flash。
