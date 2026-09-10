# 第 08 章 · VDBE 虚拟机:190 条指令,一个巨型 switch

> 基线:SQLite 3.54.0,commit `492e7fc`。行号均以该版本源码为准。
> 定位(vdbe.h:12-14 原话):"The VDBE implements an abstract machine that runs a simple program to access and modify the underlying database"。当前 vdbe.c 有 193 个 `Opcode:` 文档块、约 190 条指令。

## 8.0 为什么 SQLite 要有自己的字节码

嵌入式、无服务器,没有客户端/服务器边界,不需要序列化执行计划。SQLite 把 SQL 编译成"**寄存器式字节码 + 单函数巨型 switch 解释器**",换来:① 编译产物紧凑、驻留 prepared statement 反复执行;② 执行可被 `sqlite3_interrupt`/progress callback 切分;③ 执行层与 B-tree 层之间有稳定可测试的中间层(EXPLAIN 直接看到全部细节)。与 PG(计划树交给 executor 递归执行)、MySQL(遍历计划树)一句话对比:**SQLite 把"执行计划"降低为"指令流",执行器退化成一个循环,而不是一组相互调用的算子对象**。

## 8.1 执行环境的内存布局

`sqlite3VdbeMakeReady()`(vdbeaux.c:2658-2755)一次性分配五个数组:

```
p->aOp    [nOp]      VdbeOp 指令数组(每条 5 操作数: opcode/p1/p2/p3/p4/p5)
p->aMem   [nMem]     寄存器(Mem)空间
p->aVar   [nVar]     绑定参数,初始化为 MEM_Null
p->apCsr  [nCursor]  VdbeCursor* 指针表
p->apArg  [nArg]     虚表 xUpdate/xFilter 实参表
```

两个精妙的内存技巧:

1. **寄存器空间兼作游标存储**:`nMem += nCursor`(vdbeaux.c:2690),游标不单独 malloc——0 号游标复用 `aMem[0]`(寄存器从 1 开始编号),其余从寄存器空间**顶端向下**分配(allocateCursor,vdbe.c:273-321)。每个 VdbeCursor 是变长结构,尾部带 `aType[]/aOffset[]` 柔性数组,用 Mem 的 zMalloc 缓冲存放、按需增长;
2. **指令数组尾部空间复用**:`aOp` 按 2 倍或 1KB 增长,MakeReady 时把闲置尾部作为一个 ReusableSpace 池,优先从中切出 aMem/aVar/apArg/apCsr,不够再补一次分配(2693-2737)——prepared statement 的实际持有内存因此极小。

## 8.2 主循环 dispatch 结构

`sqlite3VdbeExec`(vdbe.c:902-987、9480-9574)的骨架:

```
for(pOp=&aOp[p->pc]; 1; pOp++) {
    nVmStep++;
    switch( pOp->opcode ){
        case OP_Goto:  pOp = &aOp[pOp->p2 - 1];      /* 跳转 = 改 pOp */
                       check_for_interrupt;
        case OP_ResultRow: p->pc = pOp-aOp+1;         /* 挂起交行 */
                           rc = SQLITE_ROW; goto vdbe_return;
        case OP_Halt:      rc = sqlite3VdbeHalt(p);   /* 收尾 */
    }
}
abort_due_to_error / too_big / no_mem: 统一错误出口
```

四个要点:

1. **跳转的实现是修改局部变量 pOp**:P2 是 1 基地址(`pOp = &aOp[p2-1]` 再借 for 的 `pOp++` 落到 aOp[p2],1134-1135);
2. **中断检查是惰性的**:不在每条指令前检查,而是让所有跳转统一落到 `check_for_interrupt` 标签(循环回边必经),注释明确说这让 step 快约 1.5%(1142-1146);
3. **dispatch 是巨型 switch 而非函数指针表**:每个 case 直接操作局部缓存的 aMem 与 pIn1/pIn2/pIn3/pOut 四个寄存器指针,编译器生成单张跳转表,没有间接调用与栈帧开销;
4. **源码格式本身是接口**:每条 case 顶格书写、注释格式固定,`tool/mkopcodeh.tcl` 靠扫描 `case OP_xxx:` 行生成 opcode 头文件(1072-1105 有整段说明)——**构建期脚本与运行期代码协同**:mkopcodeh 特意把 jump 类 opcode 编在最小整数区间,使 `resolveP2Values` 反向扫描时一次整数比较就能跳过大部分指令(vdbeaux.c:888-894)。

前向跳转用负数占位,`resolveP2Values` 在 MakeReady 时从程序末尾反向扫到 OP_Init,把负 P2 换成真实地址;反向扫描顺带统计 readOnly/bIsReader(876-977)。

## 8.3 十个代表性 opcode

| Opcode | 位置 | 要点 |
|---|---|---|
| OP_Transaction | vdbe.c:4245-4344 | 真正开事务;BUSY 时停在原指令等重试;P5 做 schema cookie 校验(不一致报 SQLITE_SCHEMA) |
| OP_OpenRead/Write | 4508-4613 | allocateCursor 分配游标,nullRow=1;OpenWrite 带 BTREE_WRCSR,支持 root page 来自寄存器 |
| OP_Rewind | 6525-6558 | 循环头;无论成败都 `cacheStatus=CACHE_STALE` 失效列解码缓存 |
| OP_Next/Prev | 6648-6693 | 循环底;推进成功跳回循环头,扫完顺落;断言保证与 Rewind/Seek 方向匹配——免费的类型检查 |
| OP_Column | 3035-3360 | 最重的指令:惰性表头解析缓存(aType/aOffset/nHdrParsed)+ 零拷贝(页内 aRow)+ 内联 serial type 解码 |
| OP_MakeRecord | 3577-3790 | 寄存器 → 记录格式(第 05 章);两遍扫描,IntReal 大整数转 Real 省 8 字节 |
| OP_ResultRow | 1806-1836 | 唯一对外行出口;先 `cacheCtr=(cacheCtr+2)\|1` 把所有游标的列缓存集体作废(挂起期间 sqlite3_column_* 可能改写寄存器) |
| OP_SCopy/Copy | 1661-1761 | 浅拷贝(共享字符串指针)vs 浅拷贝后 Deephemeralize(等效深拷贝) |
| OP_Halt | 1315-1420 | P5=约束类型(1-4 对应 NOT NULL/UNIQUE/CHECK/FK)拼错误消息;触发器帧里 P1=OK 只弹帧 |
| OP_Function | 9029-9079 | P4 是预建 context;先置 NULL 再调 xSFunc;零拷贝传参 |

**OP_ResultRow 的缓存失效协议**是正确性关键:generation counter(每次输出行 `(ctr+2)|1`)+ 游标移动时显式置 CACHE_STALE——"列指针在下一次 step 后失效"的文档承诺,底层就是这个协议。

## 8.4 Mem 寄存器:SQLite 的"值世界"

`Mem` 就是公开的 `sqlite3_value`(vdbeInt.h:232-256):`u`(union:double/i64/nZero/…)、`z`(内容指针)、`n`、`flags`、`enc`(编码)、`zMalloc`(自有缓冲)。**MEMCELLSIZE = offsetof(Mem, db)** 定义"浅拷贝面"——db 之前是值本身,之后是所有权字段。

| 组 | 位 | 含义 |
|---|---|---|
| 亲和位 | Null/Str/Int/Real/Blob/IntReal | 六种基本值;Str 可与 Int/Real 共存(多表示缓存) |
| 修饰位 | FromBind/Term/Zero/Subtype | 绑定来源、NUL 结尾、"虚拟延长 BLOB"、子类型 |
| 所有权位 | Dyn/Static/Ephem/Agg | z 归谁管:xDel/静态/借用/聚合上下文 |

内存管理规则:`out2Prerelease`(vdbe.c:674-686)是所有写寄存器指令的入口——旧值含 MEM_Dyn/MEM_Agg 才真正释放,否则只把 flags 改成 MEM_Int(**释放路径挪到慢速函数,快路径零函数调用**);聚合函数上下文直接寄生在寄存器上(MEM_Agg)。

一条值的完整生命周期(`SELECT b FROM t`):OP_Column 解码写 r[2](flags=MEM_Str|MEM_Term)→ OP_SCopy 零拷贝交给结果寄存器 → OP_ResultRow 挂起 → `sqlite3_column_text()` 经 columnMem 定位,必要时编码转换 → 下一次 step 前 pResultRow 清空,halt/reset 时 releaseMemArray 统一释放。

## 8.5 从 EXPLAIN 反看编译产物

**例一:`SELECT b FROM t WHERE a=42`**(t 为 rowid 表,点查):

```
addr  opcode         p1    p2    p3    p4      comment
0     Init           0     7     0             Start at 7
1     OpenRead       0     2     0     2       root=2; t
2     Integer        42    1     0             r[1]=42
3     SeekRowid      0     6     1             intkey=r[1]
4     Column         0     1     2             r[2]= cursor 0 column 1
5     ResultRow      2     1     0             output=r[2]
6     Halt           0     0     0
7     Transaction    0     0     1             usesStmtJournal=0
8     Goto           0     1     0
```

读法:① 程序从 Init **跳到末尾的 addr 7**——事务指令刻意放在程序尾部:prepare 与首次 step 之间即使 schema 变了,也只在 OP_Transaction 的 cookie 校验处以 SQLITE_SCHEMA 失败,不提前占锁;② 9 条指令、循环体零次——"点查"在字节码层没有循环开销。

**例二:`INSERT INTO t VALUES(1,'x')`**:

```
1     OpenWrite      0     2     0     2       root=2
2     SoftNull       2     0     0             r[2]=可覆盖NULL
3     String8        0     3     0     x       r[3]='x'
4     Integer        1     1     0             r[1]=1
5     NotNull        1     7     0             有rowid则跳过分配
6     NewRowid       0     1     0
9     NotExists      0     11    1             rowid冲突检查
11    MakeRecord     2     2     4     DB      r[4]=mkrec(r[2..3])
12    Insert         0     4     1     t       intkey=r[1] data=r[4]
14    Transaction    0     1     1
```

编译器的三个固定习惯:**事务延迟到末尾、寄存器静态规划、循环 = 头(Rewind/Seek)+ 底(Next)的回边**。注意 IPK 列不进记录数据(addr 11 的 r[2] 是 NULL 占位),读回时由 rowid 逻辑合成。

## 8.6 设计动机

1. **巨型单函数 switch**:没有间接调用、没有每算子的对象生命周期——"性能优先于模块化"的极致;代价是 vdbe.c 近 9600 行,新增 opcode 必须遵守脚本可扫描的格式;
2. **寄存器机器而非栈机器**:编译器做静态寄存器分配,复用与向量操作容易表达;
3. **格式即接口**:opcode 编号、jump 类小区间、属性位图全部构建期生成;
4. **惰性化到处可见**:中断检查只放跳转点;OP_String8 首次执行自改写成 OP_String(算好长度);OP_Column 表头惰性解析;大值惰性加载(LENGTH/TYPEOF 优化位);
5. **测试即代码的一部分**:主循环散布 VdbeBranchTaken 分支覆盖回调与 testcase() 标注、SQLITE_TEST 专用计数器(search_count/sort_count)——生产构建全编译为空,但测试套件能断言"每条分支都走过";
6. **字节码格式是官方声明的不稳定接口**(OP_Explain 注释),opcode 编号跨版本会变。

## 8.7 FAQ

**Q1:P2 跳转地址为什么是 1 基的?**
跳转统一实现为 `pOp = &aOp[p2-1]` 再借 for 的 `pOp++`;因此 P2=0 对 jump 类有特殊含义("不跳")。

**Q2:OP_Halt 之后游标、锁、事务谁来收?**
`sqlite3VdbeHalt`:closeAllCursors → 特殊错误触发回滚 → autocommit 且唯一写者时提交 → 语句 savepoint 收尾(vdbeaux.c:3326-3525)。

**Q3:sqlite3_step 每次执行一条指令吗?**
不是,推进到 OP_ResultRow(挂起)或程序结束。

**Q4:SCopy 和 Copy 怎么选?**
目标寄存器在源失效前不会再写就用 SCopy(零拷贝);否则 Copy 落袋为安。危险由调试构建的 memAboutToChange 体系盯防。

**Q5:寄存器编号从 1 开始,aMem[0] 干什么用?**
被 0 号游标的变长存储征用;其余游标从寄存器空间顶端倒着排。

**Q6:大 BLOB/TEXT 读出会 memcpy 吗?**
页内内容零拷贝指针;溢出页才拷贝,且 >4000 字节的值走 RCStr 引用计数缓存。

**Q7:绑定参数存在哪、什么时候进寄存器?**
存在 aVar[](vdbeUnbind 写入),执行到 OP_Variable 才浅拷贝进寄存器并打 MEM_FromBind|MEM_Static。

**Q8:触发器/子程序如何执行?**
OP_Program 建独立 VdbeFrame(自己的 aOp/aMem/apCsr 副本),OP_Halt P1=OK 时弹帧恢复父现场;帧对象死亡后先进 pDelFrame 链表,reset 时统一释放。

## 8.8 小结与深挖方向

本章结论:**VDBE = 寄存器机器 + 巨型 switch + 惰性化(中断/解析/加载)+ 构建期与运行期协同的格式契约**;prepared statement 的内存紧凑来自"寄存器兼游标 + ReusableSpace"。深挖方向:

1. 列缓存失效协议(cacheCtr 奇偶变化)在触发器/增量 blob 场景的正确性实验;
2. 寄存器/游标内存 aliasing 的边界(OP_OpenWrite P2ISREG 用例);
3. schema 演化三层防线的实测差异(SAVESQL 关闭时 expmask 退化);
4. 3.54 新增 bloom filter 指令(OP_Filter)的假阳性语义与规划器配合;
5. VDBE_PROFILE 指令粒度火焰图验证跳转点中断检查的真实收益。

> 下一章(卷末):测试体系与工程文化——SQLite 可靠性神话的地基。
