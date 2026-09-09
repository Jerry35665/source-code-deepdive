# D - VDBE 虚拟机(SQLite 3.54.0)

> 调研对象:commit 492e7fc0(2026-08-27)。
> 核心文件:`src/vdbe.c`(9574 行)、`src/vdbeaux.c`(5765 行)、`src/vdbeapi.c`(2734 行)、`src/vdbeInt.h`(766 行)、`src/vdbe.h`、`tool/mkopcodeh.tcl`。
> 所有结论均标注 `文件:行号`,行号对应该版本源码。

---

## ① VDBE 全景

VDBE(Virtual Database Engine)是 SQLite 的字节码虚拟机。`src/vdbe.h` 开头对它的定位只有一句话:"The VDBE implements an abstract machine that runs a simple program to access and modify the underlying database"(vdbe.h:12-14)。任何 SQL 语句在 `sqlite3_prepare` 阶段被编译为一段 VDBE 程序(一个 `VdbeOp` 数组),`sqlite3_step` 阶段由 `sqlite3VdbeExec()` 解释执行(vdbe.c:902)。对外的 `sqlite3_stmt` 句柄本质上就是一个 `Vdbe` 结构(vdbeInt.h:455-458)。

为什么 SQLite 要自带一套字节码?SQLite 是嵌入式、无服务器的数据库,没有"客户端/服务器"边界,不需要序列化、网络传输执行计划。它选择把 SQL 编译成"寄存器式字节码 + 单函数巨型 switch 解释器",换来的是:① 编译产物紧凑、可直接驻留在 prepared statement 里反复执行;② 执行过程可被 `sqlite3_interrupt()`、progress callback 等手段切分和控制;③ 整个执行层与 B-tree 层之间有一个稳定、可测试的中间层(EXPLAIN 能直接看到全部执行细节)。与客户端/服务器数据库(如 PostgreSQL 把计划树交给 executor 递归执行、MySQL 直接遍历计划树)相比,一句话概括差异:SQLite 把"执行计划"进一步降低为"指令流",执行器退化成一个循环,而不是一组相互调用的算子对象。原来 vdbe.c 单文件超过 6000 行后,才把私有信息拆到 vdbeInt.h(vdbeInt.h:12-16)。

当前 vdbe.c 中共有 193 个 `Opcode:` 文档块、190 个 `case OP_` 标签(含别名 fall-through),即约 190 条指令,涵盖表达式求值、游标控制、B-tree 读写、排序、虚表、约束检查等全部执行语义。

---

## ② 执行环境与主循环

### 2.1 执行环境的内存布局

`Vdbe` 结构保存 VM 的完整状态(vdbeInt.h:458-531),核心执行资源是五个数组,在 `sqlite3VdbeMakeReady()` 中一次性分配(vdbeaux.c:2658-2755):

```
p->aOp    [nOp]      VdbeOp 指令数组(vdbe.h:73-105)
p->aMem   [nMem]     寄存器(Mem)空间;同时"背刺"用作游标存储(见下)
p->aVar   [nVar]     绑定参数数组,初始化为 MEM_Null(vdbeaux.c:2749)
p->apCsr  [nCursor]  VdbeCursor* 指针表,初始为 NULL(vdbeaux.c:2752)
p->apArg  [nArg]     虚表 xUpdate/xFilter 的实参指针表(vdbeaux.c:2726)
```

两个值得注意的内存技巧:

1. **寄存器空间兼作游标存储**。`nMem += nCursor`(vdbeaux.c:2690-2691),即游标不单独 malloc:0 号游标复用 `aMem[0]`(寄存器从 1 开始编号,0 号永远不被程序使用),1 号游标用 `aMem[nMem-1]`,2 号用 `aMem[nMem-2]`……从寄存器空间顶端向下分配(vdbe.c:273-277,`allocateCursor`)。每个 `VdbeCursor` 是变长结构,尾部带 `aType[nField]` 和 `aOffset[nField+1]` 柔性数组(vdbeInt.h:136-139,146-147),用 Mem 的 `zMalloc` 缓冲存放,便于按需增长(vdbe.c:259-308 注释解释了这一设计:游标号可能被不同用途复用、需要可增长分配,且可被内存管理器惰性回收)。
2. **指令数组尾部空间复用**。`aOp` 按 2 倍或 1KB 增长(growOpArray, vdbeaux.c:164-198),`MakeReady` 时把 `nOpAlloc - nOp` 的闲置尾部作为一个 `ReusableSpace` 池,第一遍优先从里面切出 `aMem/aVar/apArg/apCsr`,不够再补一次分配(vdbeaux.c:2693-2737,ReusableSpace 定义 2561-2598)。这显著降低 prepared statement 的实际持有内存。

`VdbeOp` 每条指令 5 个操作数:opcode(u8)、p1/p2/p3(int)、p4(union,按 `p4type` 解释为字符串/KeyInfo/FuncDef/SubProgram 等十余种)、p5(u16 标志位)(vdbe.h:80-105)。`MakeReady` 之后 `AddOp*` 一律禁止,VM 与 Parse 对象解绑(vdbeaux.c:2647-2653)。

### 2.2 从 sqlite3_step 到主循环

```
sqlite3_step()                        vdbeapi.c:980
  └─ sqlite3Step()                    vdbeapi.c:838
       ├─ 状态机:READY→RUN(pc=0, vdbeapi.c:885);
       │   HALT→自动 reset 再重启(vdbeapi.c:889-917)
       ├─ p->explain 非零 → sqlite3VdbeList()   ← EXPLAIN 分支,不跑程序
       └─ sqlite3VdbeExec(p)               vdbe.c:902
            局部缓存 aOp/aMem(905,921)、寄存器指针 pIn1/pIn2/pIn3/pOut
```

`sqlite3_step` 外层还包了一个 `SQLITE_SCHEMA` 自愈循环:失败则 `sqlite3Reprepare` 后重试,上限 `SQLITE_MAX_SCHEMA_RETRY = 50`(vdbeapi.c:991-1024;vdbeInt.h:25-27)。

### 2.3 主循环 dispatch 结构

`sqlite3VdbeExec` 的骨架如下(vdbe.c:902-987,9480-9574):

```
for(pOp=&aOp[p->pc]; 1; pOp++) {              /* vdbe.c:987 */
    nVmStep++;                                 /* 步数统计/性能计数 */
    switch( pOp->opcode ){                     /* vdbe.c:1070 */
        case OP_Goto:  pOp = &aOp[pOp->p2 - 1];      /* 跳转=改 pOp */
                       check_for_interrupt;          /* vdbe.c:1134-1149 */
        case OP_Next:  ... if(成功) goto jump_to_p2_and_check_for_interrupt;
                       else fall through(循环出口在下方)
        case OP_ResultRow: p->pc = pOp-aOp+1;        /* 挂起并交行 */
                           rc = SQLITE_ROW; goto vdbe_return;   /* 1833 */
        case OP_Halt:      rc = sqlite3VdbeHalt(p);  /* 收尾 */
                           goto vdbe_return;         /* 1410-1419 */
        default:           OP_Noop / OP_Explain      /* 9424-9428 */
    }
    /* switch 后:循环尾断言/trace */
}
abort_due_to_error:  设 p->rc, sqlite3VdbeHalt(p)      /* 9480-9514 */
vdbe_return:         累计 VM_STEP、释放共享锁、return rc /* 9519-9549 */
too_big / no_mem / abort_due_to_interrupt: 统一错误出口 /* 9554-9573 */
```

要点:

- **跳转的实现是修改局部变量 pOp**:所有跳转类 opcode 统一落到 `jump_to_p2_and_check_for_interrupt` 标签,`pOp = &aOp[pOp->p2 - 1]`,再靠 for 循环的 `pOp++` 落到 `aOp[p2]`——所以 **P2 是 1 基地址**(vdbe.c:1134-1135)。`jump_to_p2` 与 `check_for_interrupt` 两个标签把"跳转"和"跳转+中断检查"分开。
- **中断检查是惰性的**:为避免每条指令都检查 `sqlite3_interrupt`,SQLite 把检查放在跳转目标处(循环回边必然经过),注释明确说这一写法让 `sqlite3_step()` 快约 1.5%(vdbe.c:1142-1146)。
- **两个挂起点**:正常程序只有三条离开大循环的通路——`OP_ResultRow`(交出一行,挂起)、`OP_Halt`(整体收尾)、`abort_due_to_error`(异常收尾)。每个程序末尾有一条隐式的 `Halt 0 0 0`(vdbe.c:1345-1347)。
- **dispatch 是巨型 switch 而非函数指针表**:每个 case 直接操作 `aMem[]` 局部缓存与 `pIn1/pIn2/pIn3/pOut` 四个寄存器指针,编译器可生成单张跳转表,没有间接调用与栈帧开销。调试构建下,switch 之前会用 `sqlite3OpcodeProperty[]` 位图对 IN1/IN2/IN3/OUT2/OUT3 类操作数做范围与初始化断言(vdbe.c:1030-1065)。
- **源码格式本身是接口**:每条 case 顶格书写、注释格式固定,`mkopcodeh.tcl` 靠扫描 `case OP_xxx:` 行生成 opcodes.h/opcodes.c,`Opcode:` 文档块生成 opcode.html(vdbe.c:1072-1105 有整段说明)。

### 2.4 程序是如何被"写"出来的:AddOp 与标签

代码生成器(Parse)构造 VM 时并不关心跳转目标尚未出现,这套机制由三部分组成:

- **AddOp 家族**:`sqlite3VdbeAddOp3` 把 opcode/p1/p2/p3 直接写进 `aOp[]` 尾部并返回下标即"地址";容量不足走 `growOpArray` 翻倍扩容(上限受 `SQLITE_LIMIT_VDBE_OP` 保护)(vdbeaux.c:271-315,164-198)。`AddOp4` 额外挂一个带类型的 P4 指针(427-439)。`sqlite3VdbeGoto/LoadString/AddInt64/AddDouble` 等是语义化包装(366-391)。
- **前向标签**:前向跳转先用负数占位,`resolveP2Values` 在 MakeReady 时**从程序末尾反向扫到 addr 0 的 OP_Init** 为止,把负 P2 通过 `aLabel[]` 换成真实地址(vdbeaux.c:940-948)。反向扫描顺带完成两项统计:出现 OP_Transaction(P2≠0)/OP_Vacuum 等则 `readOnly=0`、`bIsReader=1`(898-915)——这两个标志在 step 时决定是否计入 nVdbeWrite/nVdbeRead 计数,在 Halt 时决定是否参与提交决策。
- **编号协同**:mkopcodeh.tcl 特意把 jump 类 opcode 编在最小整数区间,使这里的反向扫描可以先用 `opcode <= SQLITE_MX_JUMP_OPCODE` 一个整数比较跳过全部非跳转指令(vdbeaux.c:888-894)——构建期脚本与运行期代码的一次经典协同。

每个程序的第一条指令固定是 OP_Init(断言见 vdbeaux.c:886):它发 trace 回调、复位 OP_Once 计数,并按 P2 跳到"真正的第一条指令"(见 §5 的 Init→Goto 骨架;OP_Init 实现在 vdbe.c:9225-9294)。

### 2.5 EXPLAIN 的实现方式

EXPLAIN 不是运行程序加 trace,而是**换一个解释器**:`sqlite3Step` 中若 `p->explain` 非零,直接调 `sqlite3VdbeList()` 而不进 `sqlite3VdbeExec`(vdbeapi.c:923-932)。`sqlite3VdbeList` 每次调用经 `sqlite3VdbeNextOpcode()` 找到"下一条要展示的指令",填进前 8 个(或 4 个)寄存器后返回 SQLITE_ROW——恰好复用 ResultRow 的"一行结果"通道,所以 CLI 可以像读表一样逐行读出字节码(vdbeaux.c:2417-2505;`nResColumn = 12 - 4*p->explain`,vdbeaux.c:2706-2710)。EXPLAIN QUERY PLAN(`explain==2`)则只挑 `OP_Explain` 指令输出(vdbeaux.c:2367-2371)。触发器子程序(OP_Program 的 P4_SUBPROGRAM)会被 `sqlite3VdbeNextOpcode` 递归展开、线性编入行号(vdbeaux.c:2339-2357)。P4 的可读文本由 `sqlite3VdbeDisplayP4` 生成(仅调试或 EXPLAIN 构建编译进,见 VDBE_DISPLAY_P4,vdbeInt.h:33-39)。

---

## ③ 代表性 opcode 深读

先约定阅读规则:每条指令的文档块标明操作数方向,`in1/in2/in3` 表示 P1/P2/P3 是输入寄存器,`out2/out3` 表示 P2/P3 是输出寄存器,`jump/jump0` 表示 P2 是跳转目标(0 可合法);这些属性由 case 尾注释声明、mkopcodeh.tcl 汇总进 `sqlite3OpcodeProperty[]` 位图(vdbe.c:1090-1093;tool/mkopcodeh.tcl:306-313)。编译期还常在注释里给出 `Synopsis: r[P2]=P1` 形式的速记,EXPLAIN 的 comment 列即由此渲染。以下 10 条指令覆盖"事务—游标—记录—输出—函数"全链路,每条给出源码关键行。

### 3.1 OP_Transaction(vdbe.c:4245-4344)

P1=数据库号,P2=0 只读/1 读写/2 读写(2 允许一条语句内二次开启)。执行 `sqlite3BtreeBeginTrans` 真正开事务;若 BUSY 则把 `p->pc` 停在本指令、直接返回,等下次 step 重试(vdbe.c:4274-4279)——这就是 SQLITE_BUSY 可重试语义的来源。P5 非零时进行 **schema cookie 校验**:把 B-tree 元数据 `iMeta` 与编译时的 P3 比较,不一致则报 "database schema has changed"、置 `p->expired=1`、返回 SQLITE_SCHEMA(vdbe.c:4307-4341),驱动上层 reprepare。需要语句日志(statement journal)时在这里建 savepoint 并记录延迟约束计数基线(4283-4304)。

### 3.2 OP_OpenRead / OP_OpenWrite / OP_ReopenIdx(vdbe.c:4508-4613)

三者共享同一段代码,`OP_ReopenIdx` 先检查 P1 号游标是否已开在同一 root page,是则变成 no-op(4521-4526)。核心流程:P4 为 KeyInfo(索引 b-tree)或列数整数(表 b-tree)→ `allocateCursor` 分配变长 VdbeCursor → 设 `nullRow=1`(尚未指向任何行)→ 调 `sqlite3BtreeCursor` 绑定 b-tree 游标(4587-4596)。`isTable = (P4 不是 KeyInfo)`(4602)。OpenWrite 额外带 `BTREE_WRCSR` 写标志,并允许 `OPFLAG_P2ISREG`(root page 号来自寄存器,服务于运行期 CREATE TABLE 后立即写入的场景,4558-4571)。

### 3.3 OP_Rewind(vdbe.c:6525-6558)

循环头。sorter 游标走 `sqlite3VdbeSorterRewind`,b-tree 游标走 `sqlite3BtreeFirst`;无论成败都 `pC->cacheStatus = CACHE_STALE` 失效 OP_Column 的解码缓存(6549)。空表时置 `nullRow` 并跳 P2(6552-6555)。OP_Sort/OP_SorterSort 是它的别名,只为让测试能统计"真的发生了排序"(6500-6509)。

### 3.4 OP_Next / OP_Prev(vdbe.c:6648-6693)

循环底。`sqlite3BtreeNext/Previous` 返回 SQLITE_OK 表示推进成功:清 `nullRow`、累计 P5 指定的事件计数器(全表扫描步数或自动索引,6664-6667)、`goto jump_to_p2_and_check_for_interrupt` 跳回循环头(P2);返回 SQLITE_DONE 表示扫完:`nullRow=1`、顺落到底部继续往下执行(6689-6692)。无论成败都 `pC->cacheStatus = CACHE_STALE`(6679)。断言确认 Next 的 P1 游标最近一次定位必须是 Rewind/SeekGE/SeekGT 一族(6672-6675)——即编译器保证"方向匹配",这是免费的类型检查。

### 3.5 OP_Column(vdbe.c:3035-3360)

最重的指令:把游标当前记录按 MakeRecord 格式解码出第 P2 列,写入寄存器 P3。三个关键机制:

- **惰性表头解析缓存**:首次访问某行时解析记录头(变长 header-size,逐个 serial type varint,累加出 `aOffset[]` 偏移数组,3179-3216),已解析列数记在 `pC->nHdrParsed`;只要 `pC->cacheStatus == p->cacheCtr` 且游标未移动,后续列访问直接取 `pC->aType[p2]` 免解析(3066,3236)。游标一旦 Next/Prev 或 ResultRow 输出就使缓存失效。
- **零拷贝路径**:优先从页内缓冲 `pC->aRow` 直接取数(3102-3105);内容在溢出页时走 `vdbeColumnFromOverflow`,>4000 字节的 TEXT/BLOB 还会用 RCStr 引用计数缓存(vdbe.c:741-769)。
- **内联 serial-type 解码 switch**(3260-3338):type 0/11→NULL;1-6→1/2/3/4/6/8 字节大端整数;7→IEEE double;8/9→常量 0/1(连数据字节都没有);10→虚表 no-change 专用 NULL;≥12→`(t-12)/2` 长度的 BLOB(t 偶)或 TEXT(t 奇),并复制进寄存器自有的 `zMalloc` 缓冲、补双 NUL(3326-3336)。

### 3.6 OP_MakeRecord(vdbe.c:3577-3790)

把 P2 个寄存器(自 P1 起)按 P4 的亲和性字符串逐列 `applyAffinity` 后,编码成 SQLite 记录格式:`| hdr-size(varint) | type0..typeN-1 | data0..dataN-1 |`(格式注释 3593-3607)。两遍扫描:第一遍从后往前为每个字段算 serial type 存进 `Mem.uTemp`(整型按 |i| 大小选 1/2/3/4/6/8 字节,0 和 1 的小整数可省数据字节,即 type 8/9,3717-3723;IntReal 大整数直接转 Real 省 8 字节,3738-3745;字符串 type = 2*len+12+奇偶),同时累加 `nHdr/nData/nZero`(3681-3774);第二遍按算好的尺寸写 header 与 data(3776 之后)。NULL 尾部裁剪(SQLITE_ENABLE_NULL_TRIM)与虚表 no-change 的 serial type 10 也在这里处理(3641-3653,3684-3699)。

### 3.7 OP_ResultRow(vdbe.c:1806-1836)

唯一对外的"行出口"。P1..P1+P2-1 个寄存器即一行结果:把 `p->pResultRow` 指向 `&aMem[p1]`、保存 `p->pc = 当前地址+1`、返回 SQLITE_ROW,VM 就地挂起(1833-1835)。注意它先做 `p->cacheCtr = (p->cacheCtr+2)|1`,把所有游标的列缓存集体作废(1811)——因为挂起期间 `sqlite3_column_*` 可能对寄存器做编码转换,旧缓存不可信;同时断言清掉 `pScopyFrom` 浅拷贝依赖(1820-1826)。

### 3.8 OP_SCopy / OP_Copy / OP_Move(vdbe.c:1661-1761)

- OP_SCopy:**浅拷贝**,`sqlite3VdbeMemShallowCopy(pOut,pIn1,MEM_Ephem)` 只拷 Mem 头部(MEMCELLSIZE 之前的字段)+ 把源标为 Ephem;字符串本体共享源指针,源失效则拷贝悬垂(1737-1761)。用于短生命周期传递,省 memcpy。
- OP_Copy:浅拷贝后立即 `Deephemeralize`(把 Ephem 升级为寄存器自有拷贝),等效深拷贝,支持 P3+1 个寄存器批量;P5 的 0x02 位要求清 MEM_Subtype(1699-1735)。
- OP_Move:`sqlite3VdbeMemMove` 按字节搬移 Mem 结构,源置 NULL,要求区间不重叠(1652-1697)。

### 3.9 OP_Halt(vdbe.c:1315-1420)

程序终点/异常点。P1=返回码,P2=处置策略(OE_Fail/OE_Abort/OE_Rollback),P3/P4 携带错误文本,P5=约束类型(1-4 对应 NOT NULL/UNIQUE/CHECK/FOREIGN KEY,拼错误消息,1394-1404)。若当前在触发器子程序帧里且 P1==SQLITE_OK,则只弹帧、恢复父帧的 aOp/aMem/pc 继续执行(1365-1384);否则设 `p->rc/p->errorAction` 后调 `sqlite3VdbeHalt(p)` 做事务级收尾(1410)。错误消息、约束语义(OE_* 的裁决)都在这一条指令上收口。

### 3.10 OP_Function(vdbe.c:9029-9079)

调用 SQL 函数。P4 是预建的 `sqlite3_context`(P4_FUNCCTX,含 pFunc/argc),参数寄存器从 P2 起、结果写 P3。触发器场景寄存器数组可能换址,所以每次检查 `pCtx->pOut != pOut` 后重绑 argv(9040-9046);先把目标寄存器置 NULL,再调 `xSFunc`(9056-9058);函数报错则转 abort 并清该指令的 auxdata 缓存(9061-9069)。相邻的 OP_PureFunc 仅在 `SQLITE_ENABLE_STAT4`/调试构建里区分"纯函数不可依赖运行时状态"。寄存器在 VM 内是"值传递给函数指针",配合 Mem 的 Ephem/Dyn 语义实现零拷贝传参。

---

## ④ Mem 寄存器的类型系统与内存管理

### 4.1 Mem 结构

`Mem` 就是公开的 `sqlite3_value`(vdbeInt.h:232-256):

```
struct sqlite3_value {
  union MemValue { double r; i64 i; int nZero;
                   const char *zPType; FuncDef *pDef; } u;
  char *z;        /* 字符串/BLOB 内容指针 */
  int n;          /* 内容长度(不含 NUL) */
  u16 flags;      /* 类型位图,见下 */
  u8  enc;        /* UTF-8 / UTF-16LE / UTF-16BE */
  u8  eSubtype;   /* 应用子类型 */
  sqlite3 *db; int szMalloc; u32 uTemp; char *zMalloc;
  void (*xDel)(void*);
};
```

`MEMCELLSIZE = offsetof(Mem, db)`(vdbeInt.h:262)定义"浅拷贝面"——db 之前是值本身,之后是所有权字段。这一布局被 OP_Variable、ShallowCopy 大量利用(vdbe.c:1645)。

### 4.2 类型标志位(vdbeInt.h:309-334)

| 组 | 位 | 含义 |
|---|---|---|
| 亲和位(0x3f) | MEM_Null 0x01 / MEM_Str 0x02 / MEM_Int 0x04 / MEM_Real 0x08 / MEM_Blob 0x10 / MEM_IntReal 0x20 | 六种基本值类型;Str 可与 Int/Real 共存(多表示缓存) |
| 修饰位 | MEM_FromBind 0x40 / MEM_Cleared 0x100 / MEM_Term 0x200 / MEM_Zero 0x400 / MEM_Subtype 0x800 | 绑定来源、OP_Null 专用 NULL、以 NUL 结尾、"n+u.nZero 个 0"虚拟延长 BLOB、子类型有效 |
| 所有权位 | MEM_Dyn 0x1000 / MEM_Static 0x2000 / MEM_Ephem 0x4000 / MEM_Agg 0x8000 | z 指针归谁管:xDel 析构 / 静态 / 别人所有 / 聚合上下文 |

几个精巧设计:MEM_IntReal(0x20)表示"存的是整数,但按 REAL 序列化",服务于 MakeRecord 的类型压缩(vdbe.c:3630-3633);`MEM_Null|MEM_Zero` 是虚表 UPDATE 的 no-change 哨兵值(MemNullNochng, vdbeInt.h:351-353);MEM_Undefined(全 0)表示"未初始化",调试构建读它即断言(memIsValid, vdbeInt.h:364)。

### 4.3 内存管理规则

- 寄存器自有缓冲只有一个:`zMalloc`(大小 `szMalloc`)。MEM_Dyn 走 `xDel`,MEM_Static/MEM_Ephem 不拥有 z。
- `out2Prerelease`(vdbe.c:674-686)是所有 out2 类指令写寄存器前的入口:若旧值含 MEM_Dyn/MEM_Agg 才真正释放(`out2PrereleaseWithClear`),否则只把 flags 改成 MEM_Int——释放路径被挪到慢速函数,快路径零函数调用。
- `Deephemeralize`(vdbe.c:242-244)把 Ephem 字符串升级为自有拷贝,是 SCopy→Copy 语义转换的核心。
- 生命周期全部收口在 halt/reset:`releaseMemArray` 批量释放寄存器(`sqlite3VdbeHalt` → closeAllCursors, vdbeaux.c:2849;EXPLAIN 每行前 `releaseMemArray(pMem,8)`, vdbeaux.c:2437)。
- 聚合函数上下文直接寄生在寄存器上:MEM_Agg 时 `z` 指向聚合缓冲,`sqlite3_aggregate_context` 首次调用时分配(vdbeapi.c:1193-1224)。

### 4.4 与类型系统的关系

SQLite 的动态类型(NULL/INTEGER/REAL/TEXT/BLOB)就是 flags 的投影:`sqlite3_value_type` 直接映射 flags;比较、亲和转换(applyAffinity)、`typeof()` 都只是位运算和有限转换函数。寄存器是唯一"值世界",B-tree 里的记录(串行格式)与 API 边界(绑定/取列)各做一次编解码,中间不重复转换。

### 4.5 一条值在 VM 里的完整生命周期

以 `SELECT b FROM t` 为例跟踪 b 列的值:

1. **产生**:OP_Column 从页内字节解码,写入寄存器 r[2],flags=`MEM_Str|MEM_Term`,z 指向寄存器自有 zMalloc 缓冲(vdbe.c:3317-3336);
2. **搬运**:代码生成器多用 OP_SCopy 把 r[2] 交给 ResultRow 所在寄存器段——零拷贝,但生成器保证两寄存器寿命重叠段内源不被改写;
3. **挂起**:OP_ResultRow 把 pResultRow 指向该寄存器,VM 返回 SQLITE_ROW(vdbe.c:1806-1836);
4. **外部读取**:`sqlite3_column_text()` 经 `columnMem` 定位 `pResultRow[i]`(vdbeapi.c:1393-1408),必要时触发编码转换(可能 malloc,失败记入 p->rc 再由 columnMallocFailure 上报,1428-1442);`sqlite3_column_value` 把 STATIC 标志降级为 Ephem,防止调用方误认为可长期持有(1488-1496);
5. **销毁**:下一次 step 前 `p->pResultRow=0`(vdbeapi.c:944);寄存器本体在 halt/reset 时由 `releaseMemArray` 统一释放。

理解这条链就理解了为什么"列 API 返回的指针在下一次 step 后失效"——文档承诺背后的机制正是寄存器复用而非引用计数。

---

## ⑤ 从 EXPLAIN 反看编译产物

以下两条均由 3.53 CLI 实际生成(与本仓库 3.54 的代码生成逻辑一致),手工注释。

### 5.1 例一:`SELECT b FROM t WHERE a=42`(t 为 rowid 表)

```
addr  opcode         p1    p2    p3    p4      comment
0     Init           0     7     0             Start at 7
1     OpenRead       0     2     0     2       root=2 iDb=0; t
2     Integer        42    1     0             r[1]=42
3     SeekRowid      0     6     1             intkey=r[1]
4     Column         0     1     2             r[2]= cursor 0 column 1
5     ResultRow      2     1     0             output=r[2]
6     Halt           0     0     0
7     Transaction    0     0     1     0       usesStmtJournal=0
8     Goto           0     1     0
```

读法:① 程序从 addr 0 的 `Init` 无条件跳到 **addr 7**——事务指令被刻意放在程序**末尾**(P2=0 只读事务):prepare 与首次 step 之间即使 schema 变了,也只需在 OP_Transaction 的 cookie 校验处(vdbe.c:4307-4341)以 SQLITE_SCHEMA 失败,而不必提前占用读事务;② `Goto 1` 回到 addr 1 真正开始;③ `OpenRead 0 2 0 2`:游标 0,root page=2,P4=2 表示"表 b-tree,2 列"(p4type=P4_INT32);④ `SeekRowid` 用 r[1]=42 直接定位主键,找不到跳 6(Halt);⑤ `Column 0 1 2`:游标 0 的第 1 列(b)→ r[2];⑥ `ResultRow 2 1`:r[2..2] 作为一行输出,VM 挂起在 addr 6 之前的 pc。整个查询 9 条指令、单步循环体只执行一次,体现"点查"在字节码层几乎零循环开销。

### 5.2 例二:`INSERT INTO t VALUES(1,'x')`

```
addr  opcode         p1    p2    p3    p4      comment
0     Init           0     14    0             Start at 14
1     OpenWrite      0     2     0     2       root=2 iDb=0; t
2     SoftNull       2     0     0             r[2]=NULL
3     String8        0     3     0     x       r[3]='x'
4     Integer        1     1     0             r[1]=1
5     NotNull        1     7     0             if r[1]!=NULL goto 7
6     NewRowid       0     1     0             r[1]=rowid
7     MustBeInt      1     0     0
8     Noop           0     0     0             uniqueness check for ROWID
9     NotExists      0     11    1             intkey=r[1]
10    Halt           1555  2     0     t.a     UNIQUE constraint failed: t.a
11    MakeRecord     2     2     4     DB      r[4]=mkrec(r[2..3])
12    Insert         0     4     1     t       intkey=r[1] data=r[4]
13    Halt           0     0     0
14    Transaction    0     1     1     0       usesStmtJournal=0
15    Goto           0     1     0
```

读法:① `Transaction 0 1 1`:P2=1,写事务,末尾同款"延迟开启"布局;② 寄存器布局由编译器规划:r[1]=rowid,r[2]=a 列占位,r[3]='x';`SoftNull` 给 r[2] 预置"可覆盖的 NULL"(INTEGER PRIMARY KEY 列不进记录数据,r[2] 之后由 Insert 用 r[1] 填充);③ addr 5-6 是"给了 rowid 就跳过 NewRowid"的编译期双分支;④ addr 9 `NotExists` 做 rowid 冲突检查,冲突跳 addr 10 `Halt 1555 2 0 t.a 2`:P1=1555(SQLITE_CONSTRAINT_ROWID),P2=OE_Abort,P5=2 → 按 §3.9 的规则拼出 "UNIQUE constraint failed: t.a"(vdbe.c:1394-1404);⑤ addr 11 `MakeRecord 2 2 4`:把 r[2..3] 编码为记录存 r[4],P4="DB" 是列亲和字符串(D=INTEGER,B=TEXT);⑥ addr 12 `Insert` 以 r[1] 为 key、r[4] 为 payload 写入表 b-tree。注意记录里 a 列其实是 NULL——rowid 表的 IPK 列不重复存储,读回时由 OP_Column/Rowid 逻辑合成。

对比两条程序的公共骨架 `Init→(末尾)Transaction→Goto 主体→...→Halt`,可以看到编译器的三个固定习惯:**事务延迟到末尾、寄存器静态规划、循环 = 头(Rewind/Seek)+ 底(Next/Goto)的回边**。

---

## ⑥ 设计动机与取舍

1. **巨型单函数 switch vs 算子树/函数表**。整个解释器是一个函数,所有状态(aOp/aMem/pc)是局部变量或 Vdbe 字段,opcode 间用 goto 传递控制流;没有间接调用、没有每算子的对象生命周期。代价:vdbe.c 近 9600 行、可读性依赖注释规范、新增 opcode 必须遵守脚本可扫描的格式。这是 SQLite"性能优先于模块化"哲学的极致体现。
2. **寄存器机器而非栈机器**。寄存器随机寻址,编译器(`expr.c/insert.c`)做静态寄存器分配,重复求值、复用、批量操作(P1@P2 向量操作数)都容易表达;栈机则难做跨分支复用。
3. **格式即接口**。opcode 编号、"jump 类集中在小编号区间"(SQLITE_MX_JUMP_OPCODE)、属性位图(OPFLG_*)全部由 tool/mkopcodeh.tcl 在构建期生成——resolveP2Values 扫描程序时先用一次 `opcode<=SQLITE_MX_JUMP_OPCODE` 比较就跳过 80% 的指令(vdbeaux.c:894)。
4. **惰性化到处可见**:中断检查只放跳转点;OP_String8 首次执行自改写成 OP_String(算好长度, vdbe.c:1500);OP_Column 表头惰性解析;大值惰性加载(LENGTH/TYPEOF 优化位 OPFLAG_LENGTHARG/TYPEOFARG, vdbe.c:3028-3033)。
5. **内存换取速度的边界**。SCopy 广泛用于"借用"字符串,靠 memAboutToChange 断言体系兜底(vdbe.c:34-46);生产构建只有零成本,调试构建能抓悬垂。两遍 ReusableSpace 分配(vdbeaux.c:2693-2737)几乎消灭 prepared statement 的碎片分配。
6. **错误处理的统一出口**。所有 opcode 出错只允许 goto 四个标签(too_big/no_mem/abort_due_to_interrupt/abort_due_to_error),收尾语义(回滚到哪一级)集中到 sqlite3VdbeHalt 的 errorAction 决策树(vdbeaux.c:3326-3503),opcode 本身不碰事务。
7. **牺牲品**:字节码格式被官方明确声明为不稳定接口(OP_Explain 注释:" meanings of the parameters ... subject to change from one release to the next", vdbe.c:9418-9422);寄存器数量受 `SQLITE_LIMIT_VDBE_OP` 约束(vdbeaux.c:185)。
8. **测试即代码的一部分**。主循环里散布着大量 `VdbeBranchTaken(...)` 分支覆盖回调、`testcase(...)` 边界标注与 SQLITE_TEST 专用全局计数器(search_count/sort_count/found_count,vdbe.c:55-117):生产构建全部编译为空,但它们让 SQLite 测试套件能断言"每一条分支都走过、每一次优化都生效"。VDBE 覆盖工具甚至记录生成每条字节码的 C 源码行号并把"不可能发生的分支方向"编码进高 8 位(vdbe.c:172-229)。
9. **解释器与编译器的接口刻意做薄**。P4 类型十余种但"复杂对象只有指针":KeyInfo(比较规则)、FuncDef/FuncCtx(函数)、SubProgram(触发器)、Vtab 等都由 prepare 阶段的对象充当,执行期只读;执行期自己的可变状态几乎全部收敛在寄存器与游标里。这使得"同一语句重复 step"不需要重建任何编译期对象,也解释了 reprepare 为何是整体替换 VM 而非局部修补。

---

## ⑦ FAQ

1. **Q: P2 跳转地址为什么是 1 基的?** A:跳转统一实现为 `pOp = &aOp[pOp->p2 - 1]` 再借 for 的 `pOp++`,正好落在 `aOp[p2]`(vdbe.c:1134-1135)。因此 `P2=0` 对 jump 类 opcode 有特殊含义("不跳",OPFLG_JUMP0),如 Rewind 的 P2=0 断言表永不为空(vdbe.c:6518-6519)。
2. **Q: OP_Halt 之后游标、锁、事务谁来收?** A:OP_Halt 只设 rc/errorAction 并调 `sqlite3VdbeHalt`(vdbe.c:1410);Halt 里 closeAllCursors(vdbeaux.c:2849)→ 特殊错误(NOMEM/IOERR/INTERRUPT/FULL)触发语句或全量回滚(3364-3398)→ autocommit 且本 VM 是唯一写者时提交(vdbeCommit,3412-3447)→ 语句 savepoint 的 RELEASE/ROLLBACK(3455-3487)。
3. **Q: sqlite3_step 每次执行一条指令吗?** A:不是。一次 step 会把程序推进到 OP_ResultRow(返回 SQLITE_ROW 并挂起)或程序结束(返回 SQLITE_DONE)。OP_ResultRow 保存 `p->pc` 后整循环返回,下次 step 从 `p->pc` 继续(vdbe.c:1833,987)。
4. **Q: 为什么 Transaction 总在程序末尾、Init 先跳过去?** A:让"开事务+schema cookie 校验"发生在真正开始读写前一刻:既避免 prepare 后事务空转,又把 SQLITE_SCHEMA 的检测点集中在一处(vdbe.c:4307-4341);对只读语句,若 btree 尚未真正需要,也不会过早拿锁。
5. **Q: SCopy 和 Copy 怎么选?** A:目标寄存器在源失效前不会再写、也不再被外部长期持有,就用 SCopy(零拷贝);否则用 Copy(Deephemeralize 落袋为安)。危险由调试构建的 pScopyFrom/memAboutToChange 体系盯防(vdbe.c:34-46,1755-1758)。
6. **Q: EXPLAIN 会执行 SQL 吗?** A:不会。explain 模式下 sqlite3Step 走 sqlite3VdbeList 单独解释器,逐条返回指令元数据,主程序从未执行(vdbeapi.c:923-932;vdbeaux.c:2417-2505)。EXPLAIN QUERY PLAN 则只筛 OP_Explain 指令。
7. **Q: 寄存器编号从 1 开始,aMem[0] 干什么用?** A:0 号被 0 号游标的变长存储征用,1 号以上才是程序可见寄存器;其余游标从寄存器空间顶端倒着排(vdbe.c:273-277;vdbeaux.c:2685-2691)。所以调试断言里寄存器上界是 `nMem+1-nCursor`(vdbe.c:1035)。
8. **Q: sqlite3_interrupt 靠什么生效?** A:置 db->u1.isInterrupted 原子标志;VM 只在跳转目标和循环出口检查(vdbe.c:1147-1148,9570-9573)。长循环每轮回边必然经过,点查则几乎立刻到达某条跳转——响应延迟与程序结构相关。
9. **Q: opcode 的整数编号是谁定的、稳定吗?** A:构建期由 mkopcodeh.tcl 扫描 vdbe.c 分配:resolveP2Values 特殊处理的 9 条最小,然后是全部 jump 类,再按分组补齐(tool/mkopcodeh.tcl:156-230);编号跨版本会变,`same as TK_xxx` 别名让表达式运算符 opcode 与文法 token 共值(mkopcodeh.tcl:13-25)。
10. **Q: 绑定参数存在哪、什么时候进寄存器?** A:存在 `p->aVar[]`(vdbeUnbind 写入,vdbeapi.c:1721-1762),程序执行到 OP_Variable 才以 MEMCELLSIZE 浅拷贝进寄存器并打上 MEM_FromBind|MEM_Static(vdbe.c:1635-1649)。
11. **Q: 触发器/子程序如何执行?** A:OP_Program 建独立 VdbeFrame(自己的 aOp/aMem/apCsr 副本),OP_Halt P1=OK 时弹帧恢复父现场(vdbe.c:1365-1384;VdbeFrame 定义 vdbeInt.h:194-216)。为避免递归释放,帧对象死亡后先进 Vdbe.pDelFrame 链表,reset 时统一释放(vdbeInt.h:181-189)。
12. **Q: 大 BLOB/TEXT 读出会 memcpy 吗?** A:页内内容先用 `pC->aRow` 零拷贝指针;溢出页内容才拷贝,且 >4000 字节的表 b-tree 值走 RCStr 引用计数缓存,重复读取不再拷(vdbe.c:3252-3253,741-769)。

---

## ⑧ 深挖问题(供后续章节展开)

1. **列缓存失效协议的正确性**。`VdbeCursor.cacheStatus` 依赖 `Vdbe.cacheCtr` 生成计数:OP_ResultRow 每次 `(ctr+2)|1`(vdbe.c:1811),Next/Prev/Rewind 直接置 CACHE_STALE=0(vdbe.c:6549,6679),PSEUDO 游标与 aAltMap 换道时还有 `op_column_restart` 重入(vdbe.c:3056,3087-3091)。这套"generation counter + 显式失效"协议是理解 OP_Column 在触发器、增量 blob 写入等场景下正确性的钥匙;建议实验:`PRAGMA vdbe_trace` 观察 cacheCtr 随 ResultRow 的奇偶变化。
2. **寄存器/游标内存 aliasing**。游标寄生在 Mem 槽位上,意味着"寄存器写入"与"游标分配"共享空间;编号越界断言 `nMem+1-nCursor`(vdbe.c:1035)和 allocateCursor 里对 `pMem->flags==MEM_Undefined` 的断言(vdbe.c:295)是仅有的防线,值得构造 OP_OpenWrite 的 P2ISREG 用例验证与游标顶部分配的边界是否相安无事。
3. **schema 演化路径的三层防线**:OP_Transaction 的 cookie 校验(vdbe.c:4307-4341)→ SQLITE_MAX_SCHEMA_RETRY=50 的 reprepare 循环(vdbeapi.c:991-1024)→ expmask 驱动的"绑定触发重编译"(vdbeapi.c:1753-1760)。`SQLITE_PREPARE_SAVESQL` 关闭时 expmask 恒 0,`sqlite3_expired` 语义随之退化,值得实测差异。
4. **3.54 新增 bloom filter 指令(OP_Filter/OP_FilterAdd)**:哈希注释明确警告只在 BINARY collation 下有效(tag-202607231411, vdbe.c:692-694);"假阴性无害、假阳性致命"的跳转语义(vdbe.c:9156-9168)如何被查询规划器保守使用,可结合 whereLoop 的 IN 算子实现展开。
5. **解释器性能画像**:VDBE_PROFILE/STMT_SCANSTATUS 给每条指令记 nExec/nCycle(Op 结构内嵌计数器,vdbe.h:107-110;累加点 vdbe.c:995-1005,9438-9445),配合 `sqlite3_stmt_status(SQLITE_STMTSTATUS_VM_STEP)`(vdbe.c:9542)可做指令粒度的火焰图,验证 §② 各项取舍(跳转点中断检查、out2Prerelease 快路径)的真实收益。

---

*报告完*
