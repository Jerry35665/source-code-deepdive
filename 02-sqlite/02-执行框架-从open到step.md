# 第 02 章 · 执行框架:从 sqlite3_open 到第一行结果

> 基线:SQLite 3.54.0,commit `492e7fc`。行号均以该版本源码为准。
> 与 Redis 卷的对照:Redis 的框架是"一个事件循环吃掉一切";SQLite 没有事件循环,它的框架是**一条"编译 → 字节码 → 解释执行"的流水线**,API 按阶段切开:open 建连接,prepare 编译,step 执行。

## 2.0 一次交互的三个阶段

```
sqlite3_open_v2()   ── 建连接(db 对象、锁、VFS)
sqlite3_prepare_v2() ── SQL 文本 → Vdbe 字节码(词法→文法→AST→优化→代码生成)
sqlite3_step()      ── 解释执行,直到 OP_ResultRow(SQLITE_ROW)或 OP_Halt(SQLITE_DONE)
sqlite3_finalize()  ── 释放 VM
```

对外的 `sqlite3_stmt` 句柄本质上就是一个 `Vdbe` 结构(vdbeInt.h:455-458)——**prepared statement = 编译产物 = VM 实例**三者一体。

## 2.1 openDatabase:连接对象的诞生(main.c:3385 起)

`openDatabase`(main.c:3385)的顺序:

1. `sqlite3_initialize()`(全局一次性初始化,可配置为自动调用,main.c:3402-3405);
2. **线程模式决策**(3407-3415):bCoreMutex、OPEN_NOMUTEX/FULLMUTEX、全局默认三选一;
3. **flag 净化**(3432-3444):把 DELETEONCLOSE、TEMP_DB 等内部位从用户参数里静默剥掉——API 面对任意输入的第一道防线;
4. `db = sqlite3MallocZero(sizeof(sqlite3))`,递归 mutex,`db->nDb = 2`(main + temp 两个槽,用静态数组 `aDbStatic`,3466-3468);
5. 初始禁用 lookaside(3469-3470),拷贝硬限制表 `aHardLimit`(3474);
6. 后续:`sqlite3ParseUri` 解析 URI 参数、选 VFS、`sqlite3BtreeOpen` 打开主库与临时库、注册默认 collation 与函数、加载扩展、读 schema(首次访问时惰性)。

注意 open 阶段**不读数据库文件**——真正的文件校验(魔数、页大小、schema cookie)推迟到第一次访问,由 pager 的 sharedLock + btree 的 lockBtree 完成(第 03、04 章)。

## 2.2 prepare:从文本到字节码

`sqlite3Prepare`(prepare.c:700)的关键步骤:

1. **Parse 上下文入栈**(714-717):`db->pParse` 链成外层指针——触发器/子程序递归编译靠它;
2. **schema 锁预检**(742-779):拿不到所有 Btree 的 schema 读锁就拒绝 prepare——注释解释了灾难场景:若对着未提交的 schema 变更编译,对方回滚后再做别的变更,schema cookie 将检测不到,prepared 语句就在错误的 schema 上运行;
3. `sqlite3RunParser`(797/804)跑词法 + lemon LALR(第 06 章),归约动作直接建 AST 并调用代码生成(DDL 走 build.c,SELECT 走 sqlite3Select,DML 走 insert/update/delete.c);
4. `sqlite3FinishCoding` 收尾 → `sqlite3VdbeMakeReady` 分配执行环境(第 08 章);
5. 尾部处理:`pzTail` 指向剩余文本(多条语句逐条 prepare)。

`SQLITE_PREPARE_PERSISTENT` 会**禁用 lookaside**(736-739)——长期使用的语句不占小对象池。错误路径上,parse 失败且 `checkSchema` 置位时会先调 `schemaIsValid()` 排除 schema 过期导致的假错误(819-822)。

**没有计划缓存**:每次 prepare 重新编译。SQLite 的回应是让编译足够快(第 06、07 章的毫秒级限流设计),并用 statement 重试机制兜底(见 2.4)。

## 2.3 step:解释执行与挂起协议

`sqlite3_step`(vdbeapi.c:980 → sqlite3Step 838)的状态机:

- READY → RUN(pc=0);HALT → 自动 reset 再重启(889-917)——**reset-and-restart 语义**让"执行完的语句"可以被直接再次 step;
- `explain` 非零走 `sqlite3VdbeList()`(EXPLAIN 换解释器,不跑程序);
- 主体 `sqlite3VdbeExec`(vdbe.c:902)——巨型 switch 解释器(第 08 章)。

**只有三条离开主循环的通路**:`OP_ResultRow`(交出一行,`p->pc` 保存进度,返回 SQLITE_ROW 并挂起)、`OP_Halt`(收尾,返回 SQLITE_DONE 或错误)、出错出口。这就是"一次 step 推进到下一行"的全部机制。

**行数据的失效承诺**:`sqlite3_column_*` 返回的指针在下一次 step 后失效——底层是寄存器复用而非引用计数(OP_ResultRow 后 `pResultRow` 被清,vdbeapi.c:944;寄存器在 halt/reset 时统一释放)。

## 2.4 schema 演化的三层防线

prepared 语句与 schema 的同步是执行框架最精妙的部分,三层防线层层递进:

1. **OP_Transaction 的 cookie 校验**(vdbe.c:4307-4341):事务指令在每段程序的**末尾**(Init 先跳过去),真正开事务时把 B-tree 元数据与编译时快照比对,不一致报 SQLITE_SCHEMA——这就是"事务延迟到末尾"布局的动机:prepare 与首次 step 之间 schema 变了,只会在 cookie 校验处失败,不提前占锁;
2. **reprepare 循环**(vdbeapi.c:991-1024):sqlite3_step 外层包了 SQLITE_SCHEMA 自愈循环,失败则 `sqlite3Reprepare` 重编译重试,上限 `SQLITE_MAX_SCHEMA_RETRY = 50`;
3. **绑定驱动的重编译**(vdbeapi.c:1753-1760):绑定参数若影响 schema 引用(如 `sqlite3_prepare` 的 expmask 位图),set 绑定时直接触发重编译。

## 2.5 收尾:sqlite3VdbeHalt 的决策树

`sqlite3VdbeHalt`(vdbeaux.c:3326-3525)是所有执行的收口:

```
closeAllCursors(2849)
  → 特殊错误(NOMEM/IOERR/INTERRUPT/FULL)→ 语句级或全量回滚(3364-3398)
  → autocommit 且本 VM 是唯一写者 → 提交(vdbeCommit, 3412-3447)
  → 语句 savepoint 的 RELEASE/ROLLBACK(3455-3487)
```

**opcode 本身不碰事务**——所有错误处理 goto 到统一出口(too_big/no_mem/abort_due_to_interrupt/abort_due_to_error),回滚到哪一级由 errorAction 决策树集中裁决。这个"指令无状态、收尾集中"的设计与 Redis 的 rejectCommand 统一出口异曲同工。

## 2.6 FAQ

**Q1:prepare 和 step 可以跨线程吗?**
连接默认串行模式(FULLMUTEX 可选);同一 stmt 并发 step 由 mutex 串行化,但语义上应避免。线程模式在 open 时决策后不可改。

**Q2:为什么 open 不读文件?**
惰性:文件校验在第一次访问时由 pager/btree 完成,只读连接甚至可以打开不存在的文件直到真正访问。

**Q3:一次 step 执行一条指令吗?**
不是。一次 step 把程序推进到 OP_ResultRow(返回 ROW)或程序结束(DONE)。

**Q4:schema 变了,老语句会怎样?**
OP_Transaction 的 cookie 校验失败 → SQLITE_SCHEMA → 外层自动 reprepare 重试(最多 50 次)。

**Q5:多条语句的 SQL 怎么处理?**
prepare 处理第一条,pzTail 指向剩余;循环调用即可。

**Q6:EXPLAIN 会执行 SQL 吗?**
不会,走独立的 sqlite3VdbeList 解释器逐条返回指令元数据(vdbeapi.c:923-932)。

## 2.7 小结

本章结论:**执行框架 = 编译与执行严格两段 + 挂起式字节码协议 + schema 三层自愈**。下一章开始下沉:先看这套框架踩着的地基——页面层与 B-tree。

> (注:为便于按层次阅读,本章提前引用了第 07、08 章的结论;阅读顺序可按第 01 章的三条路线自行调整。)
