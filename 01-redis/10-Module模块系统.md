# 第 10 章 · Module 模块系统:Redis 的内核可编程扩展层

> 基线:commit `e8726d1`。行号以 src/module.c(14932 行)、redismodule.h 为准。

## 10.0 全景:Module API 的能力面

```
module.c 内核侧 RM_* 函数族 ↔ 模块侧经 RedisModule_Init(内联进模块的 static 函数)
  取回的函数指针表对接(约 380 个 REGISTER_API 导出)
六大能力面:①命令 ②自定义数据类型(RDB/AOF 持久化) ③阻塞客户端
④通知/定时器/事件循环/fork ⑤线程安全上下文+GIL ⑥复制传播与命令过滤器
```

moduleLoad 用 **dlopen(RTLD_NOW|RTLD_LOCAL)+dlsym("RedisModule_OnLoad")**(:12559/:12564),失败整体回滚(:12584-12591);非懒加载,配置 moduleLoadFromQueue(:12350)失败即 exit(1)。卸载四道守卫:导出类型/被依赖/有阻塞客户端/有定时器均拒绝卸载(:12656-12672)——**类型模块事实不可热卸载**。

## 10.1 命令与数据类型

RM_CreateCommand(:1280/:930)注册进 server.commands;所有模块命令经统一分发器 RedisModuleCommandDispatcher(:930)执行。**自定义数据类型**:RM_CreateDataType 要求 9 字符类型名,moduleTypeEncodeId 编码为 9×6bit+10bit encver 的 64 位 Type ID 写入 RDB 作路由键(:7069,:7079-7137);磁盘编码 RDB_TYPE_MODULE_2(rdb.h:62):Type ID 前缀+模块自定义操作码流+EOF 标记(**不认识也可跳过**);AUX 元数据(:247)则模块缺失即 exit(1);AOF 由 aof_rewrite 回调重放为原生命令;free_effort 联动惰性异步删除(lazyfree.c:168/:190);模块类型键变更需 RM_SignalKeyAsReady 唤醒阻塞客户端。Redis 8 的 vector sets 已是经模块 API 注册的"内置模块"(:12332-12339)——**模块系统成为内核自身复用的抽象层**。

## 10.2 阻塞、GIL 与复制

moduleBlockClient(:7977-7984):Lua/MULTI 中禁止阻塞;keys 非空走 blockForKeys 否则 blockClient(BLOCKED_MODULE);解阻塞经互斥队列+管道投递(:8355-8367),reply 回调在主线程 moduleHandleBlockedClients(:8451,beforeSleep 路径)执行。**GIL 是单把 pthread 互斥锁**(:8770+server.c:1960/:1981):beforeSleep 释放给模块线程、afterSleep 收回;RM_ThreadSafeContextLock(:8727)供模块线程获取。复制:RM_Replicate/ReplicateVerbatim 经 alsoPropagate 由内核以 MULTI/EXEC 包裹进 AOF/复制流(:3606/:3651,:3575-3577);不声明 touches-arbitrary-keys 则包裹(:1257-1258);通知回调内写键的传播由 execution_nesting 抑制并推迟到 RM_AddPostNotificationJob(:8978/:8946)。

## 10.3 设计动机

1. **为什么 dlopen 模块而非嵌入式语言**:模块=原生性能+完整 C 能力(对照 09 章 Lua 是"数据脚本");Redis 生态的重量级扩展(RediSearch/RedisJSON)需要原生性能;
2. **API 稳定性承诺**:函数指针表+APIVER_1 协商(:1364/:42)——模块与内核版本的解耦是生态的根基;
3. **卸载四道守卫**:类型/阻塞/定时器/被依赖——**有状态模块不可热卸载**的诚实;
4. **模块系统成为内核复用层**:vector sets 走模块 API(:12332-12339)——官方功能也用扩展机制,是最好的 API 测试。

## 10.4 FAQ

**Q1:模块是懒加载吗?**
不是:启动时 moduleLoadFromQueue dlopen(:12350),失败 exit(1)。

**Q2:模块能热卸载吗?**
有类型/阻塞/定时器即拒绝(:12656-12672):事实不可热卸载。

**Q3:模块的自定义类型在 RDB 里怎么识别?**
64 位 Type ID(9×6bit+10bit encver)作路由键(:7069-7137):不认识的模块类型可跳过(RDB_TYPE_MODULE_2)。

**Q4:模块命令的阻塞与原生命令阻塞共用吗?**
共用 blockForKeys 原语(:7977-7984);Lua/MULTI 中禁止。

**Q5:GIL 什么时候释放?**
beforeSleep 释放给模块线程、afterSleep 收回(:8770):模块线程与主线程互斥。

**Q6:模块命令怎么进复制流?**
RM_Replicate 经 alsoPropagate 以 MULTI/EXEC 包裹(:3606/:3575-3577);未声明 arbitrary-keys 则自动包裹。

**Q7:vector sets 为什么走模块 API?**
(:12332-12339):官方功能用扩展机制=最好的 API 测试+解耦演进。

**Q8:模块版本不匹配会怎样?**
RedisModule_Init 的 APIVER 协商缺失 API 即 Init 失败(:1364):启动即发现。

**Q9:模块命令的 ACL?**
RM_CreateCommand 支持 ACL 类别(:1305):模块命令纳入 ACL 体系。

**Q10:通知回调里能写键吗?**
经 execution_nesting 抑制+RM_AddPostNotificationJob 推迟(:8978/:8946)——防递归写。

## 10.5 小结与深挖方向

本章结论:**Module="dlopen+函数指针表+六能力面"**;内核与官方功能的自身复用是其最高证明。深挖:

1. 380 个导出 API 的版本协商矩阵在长周期模块的兼容成本;
2. 模块类型在 RDB 流式解析的跳过实现(rdb.h:62);
3. GIL 的粒度(单把锁)在多模块并发线程的竞争;
4. execution_nesting(:8978)的递归深度语义;
5. Redis 8 内置模块化(vector sets)对第三方模块生态的挤压或助推。

> 下一章:活动碎片整理——内存的在线整容。
