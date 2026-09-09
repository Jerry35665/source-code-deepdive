# E - 记录格式与类型系统

> 源码深读·系统开源项目解读系列·第二卷《SQLite》
> 基准版本:SQLite 3.54.0(commit 492e7fc0,2026-08-27)。所有 `文件:行号` 均以该检出的 `src/` 目录为准。
> 读者假设:3-5 年后端经验,熟悉 B 树、页式存储,但未读过 SQLite 源码。

**版本勘误(重要)**:调研开始时按惯例寻找 `src/record.c`,发现该文件在本版本中**已不存在**。记录格式的"序列化"一侧自 2022-04-02 起被内联进 `OP_MakeRecord` 操作码(vdbeaux.c:3867 的注释明确记载:"sqlite3VdbeSerialPut() <--- in-lined into OP_MakeRecord as of 2022-04-02";vdbeaux.c:3903-3913 把 `sqlite3VdbeSerialType()` 整体包在 `#if 0` 中,注明"only used by the STAT3 logic and STAT3 support has ended, kept here for historical reference only");"反序列化 + 比较"一侧则一直在 `vdbeaux.c` 的 3862-5130 行。因此本报告以 `vdbeaux.c` + `vdbe.c` + `vdbemem.c` 为核心展开,并保留旧函数名到新位置的映射,供对照旧资料使用。

| 旧名(旧资料/老版本) | 本版本位置 |
|---|---|
| `sqlite3VdbeSerialType()` | `#if 0` 保留,vdbeaux.c:3915-3973;实际逻辑内联于 vdbe.c OP_MakeRecord 3682-3774 |
| `sqlite3VdbeSerialPut()` | 内联于 OP_MakeRecord,vdbe.c:3834-3921 |
| `sqlite3VdbeSerialGet()` | vdbeaux.c:4090-4186(仍在) |
| `sqlite3VdbeRecordCompare()` 族 | vdbeaux.c:4705-5130(仍在) |
| `sqlite3VdbeFindCompare()` | vdbeaux.c:5085-5130(仍在) |

---

## ① 全景:动态类型哲学 vs 传统 RDBMS

传统行存 RDBMS(PostgreSQL/MySQL)的表是"定式"的:每列有固定类型,行格式(tuple header + 定长/半定长列数组)由 schema 唯一决定,解析一行不需要知道每个值本身是什么——类型信息在 schema 里。SQLite 反其道而行:

1. **类型跟着值走,不跟列走**。每条记录(表 b-tree 的 payload、索引 b-tree 的 key)头部携带一张"serial type 表",逐列声明本行该列的存储类别(vdbeaux.c:3870-3879 的总注释:"In an SQLite index record, the serial type is stored directly before the blob of data ... In a table record, all serial types are stored at the start of the record, and the blobs of data at the end")。同一列在第 1 行存整数、第 2 行存文本完全合法。
2. **列只提供"倾向"**:类型亲和性(type affinity)。写入/比较时,引擎尽量把值往列的亲和性上转,转不动就保留原样(vdbe.c:339-343:"Try to convert a value into a numeric representation if we can do so without loss of information ... If it does not look like a number, leave it alone")。
3. **存储类别(storage class)与比较秩(order rank)合一**:`sqlite3MemCompare` 定义了全序:NULL < 数字(int/real) < text < blob(vdbeaux.c:4544-4547 的注释原文:"Sorting order is NULL's first, followed by numbers (integers and reals) sorted numerically, followed by text ordered by the collating sequence pColl and finally blob's ordered by memcmp()")。因为索引 b-tree 的 key 就是记录本身,比较器必须能对任意两个不同存储类别的值给出确定的次序。
4. **两级键空间**:rowid 表的 b-tree key 是 8 字节整数(`sqlite3BtreeTableMoveto`,vdbeaux.c:3820),**根本不走记录比较器**;索引 b-tree(`sqlite3BtreeIndexMoveto`,btree.c:6068)才使用 `xRecordCompare`。btree.c:6144 直接断言 `pCur->pPage->curIntKey==0`(索引路径)——"intkey 快路径"不是 RecordCompare 的一个分支,而是整棵 b-tree 层面的分叉:表 b-tree 用整数比较,索引 b-tree 才比较记录。

这个设计的收益是:一行内每列按需存储(小整数 1 字节、0/1 用 0 字节),并且列类型可以事后"变宽";代价是每行自带头部、每次比较要现场解码、以及把类型语义的复杂度从 schema 层推到了比较器和亲和性转换层——后两者正是本报告的重点。

与传统 RDBMS 行格式的具体差异可以归纳成一张对照表。PostgreSQL 的 heap tuple 虽然也是变长布局,但每列的类型由 `pg_attribute` 固定,列是否为 NULL 由行头的 null bitmap 声明,值本身的二进制表示由列类型决定(定长的直接存,变长的带 varlena 头);InnoDB 的记录格式(RECORD COMPACT)同样在行头放 null bitmap 与变长长度数组,但数组的粒度是"字节长度"而非"类型码",类型信息仍然完全依赖 schema。SQLite 的 serial type 把这两件事合而为一:一个 varint 同时编码了 NULL 与否、存储类别和字节长度。这意味着:(a) 同一列在不同行里可以用不同宽度的物理表示(整数 127 和整数 127000 分别占 1 字节和 3 字节,而 InnoDB 中 BIGINT 恒占 8 字节);(b) 读一条记录不需要打开 schema,索引 key 可以在不知道列定义的情况下被比较(只依赖 KeyInfo 里的 collation 与排序方向);(c) 代价是每行都要解析 varint 头,而且"这列到底是什么类型"这个问题没有唯一答案——它取决于行、取决于列亲和性、取决于上下文(比较还是存储)。

另一个值得记住的全局图景是:SQLite 的类型系统其实是三层叠加。最底层是**存储类别**(NULL/INTEGER/REAL/TEXT/BLOB),这是文件格式层面的物理事实,由 serial type 决定;中间层是**亲和性**,这是 schema 对写入和比较行为的一种"建议",只影响转换时机,不改变存储类别本身的存在;最上层是**严格模式**(STRICT),它在 API 层把"建议"升级为"约束",但刻意没有触碰文件格式。三层各自正交,理解了这一点,后文所有看起来奇怪的边界行为(REAL 列存整数、TEXT 列存数字、NaN 变 NULL)都能找到准确的落点。

---

## ② 记录格式逐字节解读

### 2.1 总体布局

OP_MakeRecord 开头的注释(vdbe.c:3593-3607)给出了权威图示:

```
假定记录含 N 个字段:
----------------------------------------------------------------------------
| hdr-size | type 0 | type 1 | ... | type N-1 | data0 | ... | data N-1 |
----------------------------------------------------------------------------
  ^varint     ^每列一个 varint(serial type)      ^数据区按头中顺序紧密排列
```

`hdr-size` 是一个 varint,值为**含它自身**的头部长度(vdbe.c:3776-3779,EVIDENCE-OF: R-22564-11647)。数据区中 NULL 与常量 0/1 **不占任何字节**(数据长度 0)。用一个具体例子:`INSERT INTO t VALUES(127,'ab',x'01',NULL,1)` 生成的表 b-tree payload 共 10 字节:

```
字节:  06   01   11   0e   00   09  | 7f 61 62 01
       hdr  t0   t1   t2   t3   t4     data0..data2
        ^头长6=1(hdr-size)+5(每个 type 各 1 字节 varint)
```

逐列解读(各 type varint 均单字节):

- t0:`127` → serial type `01`(uu=127≤127,但 (i&1)==i 不成立,i 不是 0/1,走 1 字节整数,vdbe.c:3717-3723);data0=`7f`(127 的 8-bit 二补码)。
- t1:`'ab'` → `0x11`=17(=13+2*2,奇数 → TEXT,长度 (17-13)/2=2);data1=`61 62`("ab")。
- t2:`x'01'` → `0x0e`=14(=12+2*1,偶数 → BLOB,长度 1);data2=`01`。
- t3:`NULL` → `00`,**无数据字节**。
- t4:`1` → `09`(常量 1,file_format≥4 且值恰为 0/1 时零数据长度,vdbe.c:3717-3720);**无数据字节**。

若把首列换成 `0` 或 `1`,t0 将变为 `08`/`09` 且 data0 消失;若在旧文件格式(minWriteFileFormat<4)上,同样的 0/1 仍占 1 字节(serial type 1)——见 §2.3。

### 2.2 serial type 编码全表

权威表在 vdbeaux.c:3881-3897 的注释中,连同反序列化实现(vdbeaux.c:4095-4184)逐条印证:

| serial type | 数据字节数 | 含义 | 反序列化落点 |
|---|---|---|---|
| 0 | 0 | NULL | vdbeaux.c:4104-4108 |
| 1 | 1 | 8-bit 二补码整数 | 4109-4116 |
| 2 | 2 | 16-bit 大端整数 | 4117-4124 |
| 3 | 3 | 24-bit 大端整数 | 4125-4132 |
| 4 | 4 | 32-bit 大端整数 | 4133-4144 |
| 5 | 6 | 48-bit 大端整数 | 4145-4152 |
| 6 | 8 | 64-bit 大端整数 | 4153-4160 |
| 7 | 8 | IEEE 754-2008 64-bit 大端浮点 | `sqlite3VdbeSerialGet7`,4066-4082 |
| 8 | 0 | 整数常量 0 | 4165-4172(3.3.0/文件格式 4 引入,3899-3900) |
| 9 | 0 | 整数常量 1 | 同上 |
| 10 | 0 | 内部使用:虚表 UPDATE "未变更" NULL(带 MEM_Zero 标记) | 4096-4102;产生于 vdbe.c:3684-3699 |
| 11 | — | 保留 | vdbeaux.c:4103 |
| N≥12 偶数 | (N-12)/2 | BLOB | 4173-4183(`aFlag[serial_type&1]` 选 MEM_Blob/MEM_Str) |
| N≥13 奇数 | (N-13)/2 | TEXT | 同上 |

三个容易被忽略的细节:

- **浮点即大端 IEEE 754**,且读回时 `IsNaN(x)` 直接转成 `MEM_Null`(vdbeaux.c:4076-4079)。这就是"文件里的 NaN 读出来是 NULL"的出处。
- **text/blob 的长度公式**是 `(N-12)/2`,奇偶性承载"是不是 text"这一比特;type varint 本身就编码了长度,`sqlite3VdbeSerialTypeLen` 对 ≥128 的类型直接 `(serial_type-12)/2`(vdbeaux.c:3999-4007),<128 则查 `sqlite3SmallTypeSizes` 表(3979-3994,含"0,1,2,3,4,6,8,8,0,0"这类历史遗留的怪异定长)。
- **48 位整数的上限**:`MAX_6BYTE ((((i64)0x00008000)<<32)-1)`(vdbeaux.c:3926)= 140737488355327,选择 6 字节而非 8 字节的分界(vdbe.c:3733)。这是为兼容旧文件格式保留的历史尺寸。

### 2.3 编码侧:OP_MakeRecord 的两遍扫描

写侧逻辑(vdbe.c:3577-3928)分三步:

第一步,应用亲和性(见 §④)并把 `MEM_IntReal` 标记去掉(vdbe.c:3626-3639,REAL 亲和的值若落回整数,打上 MEM_IntReal 以便比较器按整型走快路径)。

第二步,**从最后一列向前**遍历(vdbe.c:3681-3774),为每个 Mem 计算 `uTemp`(即 serial type)并累计 `nHdr/nData/nZero`。整型最小化编码的核心:

```c
/* vdbe.c:3702-3723(节选) */
i64 i = pRec->u.i;
u64 uu;
if( i<0 ){ uu = ~i; } else { uu = i; }   /* 负数按位取反后判容量 */
nHdr++;
if( uu<=127 ){
  if( (i&1)==i && p->minWriteFileFormat>=4 ){
    pRec->uTemp = 8+(u32)uu;              /* 0/1 → 零长度的 serial type 8/9 */
  }else{
    nData++; pRec->uTemp = 1;             /* 1 字节 */
  }
}
```

注意负数用 `~i` 而非 `-i`:这是为了把"绝对值"归一化(二补码下最小负数 `-2^63` 取反不溢出)。`MEM_Zero`(zero-blob,`sqlite3VdbeMemSetZeroBlob`,vdbemem.c:1009-1017)只在必要时展开:`nData==0` 时把零尾挂到 `nZero` 上不拷贝(vdbe.c:3759-3767),否则 `sqlite3VdbeMemExpandBlob` 实打实展开(3762-3763)。

第三步,修正头长度的自指问题(vdbe.c:3776-3791):`nHdr<=126` 时 hdr-size 占 1 字节;否则 varint 长度增长会反噬 `nHdr`,代码用 `nHdr += sqlite3VarintLen(nHdr)` 并在位数变化时 `nHdr++` 兜底。随后写侧有一个隐藏优化:在 `SQLITE_MAX_LENGTH<=2147483640` 且字节序编译期已知时,多分配 7 字节 `OVERRUN`(vdbe.c:3799-3803),使定长整数可以用"8 字节整体字节序翻转 + 算术右移 + memcpy 8 字节"的方式写出,免去逐字节大端化(vdbe.c:3863-3868 的 `aShift` 表与 vdbeaux.c:4968 的读取侧 `aShift` 表互为镜像)。

### 2.4 解码侧:OP_Column 的惰性解析

读侧不是"一次把记录解开成 N 个 Mem",而是按需推进:游标缓存 `aType[]`(每列 serial type)与 `aOffset[]`(每列数据起点),`nHdrParsed` 记录已解析到的列(vdbe.c:3160-3195);只解析到本次 `p2` 需要的列为止,`cacheStatus!=p->cacheCtr` 时才重新解析头(vdbe.c:3066)。头部上限有硬校验:最大 98307 字节 = 32768 列 × 3 字节 type + 3(vdbe.c:3123-3134 的注释给出推导),与 `vdbeRecordCompareDebug` 的 `szHdr1>98307` 防御(vdbeaux.c:4302)一致。真正把字节变成 Mem 的就是 `sqlite3VdbeSerialGet`(见 §2.2 表),text/blob 解码只挂指针(`pMem->z = (char*)buf`,MEM_Ephem),不拷贝(vdbeaux.c:4178-4182)。

---

## ③ 比较器族逐段解读:RecordCompare 的多级快路径

### 3.1 关键的数据结构:UnpackedRecord 与 KeyInfo

```c
/* sqliteInt.h:2766-2780 */
struct UnpackedRecord {
  KeyInfo *pKeyInfo;  /* 比较规则:collation、DESC、enc */
  Mem *aMem;          /* 解包后的各列值(查找键一侧) */
  union { char *z; i64 i; } u;  /* aMem[0] 的缓存(供快路径) */
  int n;              /* aMem[0].n 缓存(字符串快路径用) */
  u16 nField;         /* 键的列数(可为索引前缀) */
  i8 default_rc;      /* 前缀相等时的默认返回值 */
  u8 errCode;
  i8 r1;              /* lhs<rhs 时的返回值(DESC 时与 r2 对调) */
  i8 r2;
  u8 eqSeen;
};
```

`default_rc/r1/r2` 的语义在 sqliteInt.h:2747-2764 有完整注释:r1/r2 正常是 -1/+1,DESC 索引时对调;`default_rc` 是"两键可比较前缀全部相等"时的返回值,设为 ±1 可让 b-tree 二分分别落在**第一个/最后一个**匹配项上(处理非唯一索引),`eqSeen` 告诉调用者是否真的存在精确匹配。`u/n` 是 `sqlite3VdbeFindCompare` 预热的前缀缓存(sqliteInt.h:2769-2773)。

`KeyInfo`(sqliteInt.h:2704-2712)持有 `nKeyField/nAllField`(索引键列 vs 键+rowid 列)、`aSortFlags[]`(KEYINFO_ORDER_DESC=0x01,KEYINFO_ORDER_BIGNULL=0x02,sqliteInt.h:2729-2730)和 `aColl[]`(每列 collation)。

### 3.2 调度器 sqlite3VdbeFindCompare:三级选择

```c
RecordCompare sqlite3VdbeFindCompare(UnpackedRecord *p){   /* vdbeaux.c:5085 */
  if( p->pKeyInfo->nAllField<=13 ){
    int flags = p->aMem[0].flags;
    if( p->pKeyInfo->aSortFlags[0] ){          /* DESC 或 BIGNULL */
      if( p->pKeyInfo->aSortFlags[0] & KEYINFO_ORDER_BIGNULL )
        return sqlite3VdbeRecordCompare;      /* 退回通用版 */
      p->r1 = 1;  p->r2 = -1;                 /* DESC:预先对调 */
    }else{ p->r1 = -1; p->r2 = 1; }
    if( (flags & MEM_Int) ){ p->u.i = p->aMem[0].u.i;
      return vdbeRecordCompareInt; }          /* 快路径 1:整型首列 */
    if( (flags&(MEM_Real|MEM_IntReal|MEM_Null|MEM_Blob))==0
     && p->pKeyInfo->aColl[0]==0 ){ p->u.z = p->aMem[0].z; p->n = p->aMem[0].n;
      return vdbeRecordCompareString; }       /* 快路径 2:BINARY 文本首列 */
  }
  return sqlite3VdbeRecordCompare; }          /* 通用版 */
```

**为什么是 13 列**:注释(vdbeaux.c:5086-5098)给出推理——快路径假设头部 varint 单字节(<128),且 `vdbeRecordCompareInt` 允许越界读最多"最大合法头 + 8 字节";b-tree 侧保证 buffer 后有 74 字节 padding,因此把头限制在 64 字节以内;若首列是整数,最大合法头 = 12×5(varint type 最长 5 字节的 12 列)+1(hdr)+1(首列 type)= 62 ≤ 63,即 **13 列**。这是一个"比较器-缓冲区契约":调用方(btree.c)必须按约定提供 padding(见 3.5)。

### 3.3 快路径 1:vdbeRecordCompareInt

典型场景:索引首列恰是 INTEGER PRIMARY KEY 的隐含 rowid(或整型列),这正是 `SELECT ... WHERE rowid=?`、`WHERE a=? AND b=?` 最热的路径。

```c
/* vdbeaux.c:4947-5006(节选) */
const u8 *aKey = &((const u8*)pKey1)[*(const u8*)pKey1 & 0x3F]; /* 跳过 1 字节头 */
int serial_type = ((const u8*)pKey1)[1];
if( (u32)(serial_type-1)<=5 ){
  static const u8 aShift[] = { 0, 56, 48, 40, 32, 16, 0 };
  lhs = ((i64)sqlite3Get8byte(aKey)) >> aShift[serial_type];  /* 算术右移 */
}else if( serial_type==8 || serial_type==9 ){
  lhs = serial_type - 8;                     /* 零长度常量 0/1 */
}else{ return sqlite3VdbeRecordCompare(nKey1, pKey1, pPKey2); } /* 降级 */
v = pPKey2->u.i;                             /* 前缀缓存,免读 aMem[0] */
if( v>lhs )       res = pPKey2->r1;
else if( v<lhs )  res = pPKey2->r2;
else if( pPKey2->nField>1 )
  res = sqlite3VdbeRecordCompareWithSkip(nKey1, pKey1, pPKey2, 1); /* 跳首列续比 */
else { res = pPKey2->default_rc; pPKey2->eqSeen = 1; }
```

精彩处在注释里(vdbeaux.c:4956-4979):**不按宽度 switch**,而是统一读 8 字节、按 serial type 查表算术右移丢弃低位并符号扩展——因为键中整数宽度经常混布,switch 会分支误预测。注释坦承算术右移负数是"not defined by the C standards, or so Claude tells me",并用 assert+testcase 验证(vdbeaux.c:4970-4981)。这是一个用 UB-adjacent 技巧换分支预测的教科书案例。首列相等时进入 `WithSkip(bSkip=1)`:它从 `aKey1[1]` 重新读首列 type,直接把 `idx1/d1/i` 推进到第二列(vdbeaux.c:4723-4733),避免重复比较。

### 3.4 快路径 2:vdbeRecordCompareString 与通用版 WithSkip

`vdbeRecordCompareString`(vdbeaux.c:5015-5078)按首列 serial type 三分:数字/NULL → `r1`(数 < 文本,遵循存储类别全序);blob → `r2`;text → 直接 `memcmp(&aKey1[szHdr], pPKey2->u.z, nCmp)`,前缀相等再比长度,全等进入 WithSkip。全程不构造 Mem、不查 collation(已由 FindCompare 保证 `aColl[0]==0` 即 BINARY)。

通用版 `sqlite3VdbeRecordCompareWithSkip`(vdbeaux.c:4705-4925)的骨架是:**按 RHS(解包键)的存储类别分派**,LHS 只需读 1 字节 serial type 即可裁决多数情形:

- RHS 整型:serial≥10 → ±1(blob/text 大于数);0 → -1;7 → `SerialGet7` 后 `sqlite3IntFloatCompare`;否则 `vdbeRecordDecodeInt`(vdbeaux.c:4650-4682)**只解整数不构造 Mem**——case 4 用 `*(int*)&y` 严格别名风格的重解释,case 5 手工拼 48 位(`FOUR_BYTE_UINT(aKey+2) + (((i64)1)<<32)*TWO_BYTE_INT(aKey)`,4671),case 8/9 直接 `serial_type-8`。
- RHS 实型/字符串/blob/NULL 各一支(4782-4882);字符串若 `aColl[i]` 存在则走 `vdbeCompareMemString`(4827-4834),否则 memcmp(4835-4839)——这正是 FindCompare 中 `aColl[0]==0` 检查在逐列层面的推广。
- 比较出差异后处理排序旗标(vdbeaux.c:4884-4893):DESC 取反;`KEYINFO_ORDER_BIGNULL` 只在"与 NULL 比较"时按 `(sortFlags&KEYINFO_ORDER_DESC)!=(serial_type==0||rhs NULL)` 决定是否取反——这是 NULLS LAST-in-DESC 的布尔实现,逻辑很绕,是回归测试的重灾区。

正确性保障:`SQLITE_DEBUG` 下 `vdbeRecordCompareDebug`(vdbeaux.c:4271-4377)用"逐列解包 + `sqlite3MemCompare`"的朴素实现与优化版对拍,并覆盖 BIGNULL/DESC(vdbeaux.c:4346-4353)。

### 3.5 与 b-tree 层的衔接

`sqlite3BtreeIndexMoveto`(btree.c:6068)入口即调 `xRecordCompare = sqlite3VdbeFindCompare(pIdxKey)`(btree.c:6085),随后在页面内二分。cell 读取有三档(btree.c:6175-6229):

1. cell 长度 1 字节 varint 且整个记录在页内 → 直接 `xRecordCompare(nCell, &pCell[1], ...)`(btree.c:6184);
2. 2 字节 varint 且页内 → 同样直接调用(6185-6191);
3. 溢出到 overflow 页 → 必须 `accessPayload` 拷出整个记录,额外分配 **18 字节 overrun padding** 并清零(btree.c:6199-6222),然后退回通用入口 `sqlite3VdbeRecordCompare`(btree.c:6228)——因为溢出 buffer 无法享受页内 buffer 的 74 字节 padding 契约,只能用不做越界读的通用版。

"74 字节 padding"契约的另一端在 vdbe 层的临时 buffer 分配处(vdbeaux.c 5090-5094 注释:"there is guaranteed to be at least 74 (but not 136) bytes of padding following each buffer"),两处数字必须一致,这类跨文件数值契约没有任何编译期保护,是深挖时值得单独核对的点。另注意**表 b-tree 完全绕过这一切**:`sqlite3BtreeTableMoveto`(vdbeaux.c:3820)直接整数比较 rowid;索引记录的最后一个字段固定是 rowid,`sqlite3VdbeIdxRowid`(vdbeaux.c:5140-5210)就是靠"头长 varint 定位最后一个 type、type 必为 1-6/8/9(vdbeaux.c:5181-5188 拒绝 7)、从尾部反向取整数"实现的免解码快路径。

---

## ④ 类型亲和性:规则与转换时机

### 4.1 亲和性的表示与判定

亲和性是字符常量,直接用 ASCII 值便于构造字符串映射表(sqliteInt.h:2370-2379):`NONE='@' 0x40, BLOB='A', TEXT='B', NUMERIC='C', INTEGER='D', REAL='E', FLEXNUM='F'`。建表时两条路:标准类型名(INT/INTEGER/REAL/TEXT/BLOB/ANY)在 `sqlite3AddColumn` 里查 `sqlite3StdType[]` 表直接得到 affinity,连类型字符串都不用存(只记 `eCType` 枚举,build.c:1588-1601;表内容见 global.c:395-411);自定义类型(如 `VARCHAR(10)`)走 `sqlite3AffinityType`(build.c:1710-1776),用滑动 4 字节哈希在类型名里找子串,优先级规则(build.c:1696-1708):

| 含子串 | 亲和性 |
|---|---|
| INT | INTEGER(命中即 break,build.c:1742-1745) |
| CHAR/CLOB/TEXT | TEXT |
| BLOB | BLOB |
| REAL/FLOA/DOUB | REAL |
| 都不含 | NUMERIC |

注释里给的例子:`BLOBINT` → INTEGER(build.c:1690-1694),因为 INT 最先判且 break。完全没有类型名的列默认 `SQLITE_AFF_BLOB`(即 NONE 语义,不转换)(build.c:1626-1631)。`szEst`(估算列宽)也在同函数里顺带算出(BLOB/TEXT 带 `(k)` 参数时 `(k/4+1)`,build.c:1749-1774)。

### 4.2 转换的核心:applyAffinity / applyNumericAffinity

```c
static void applyAffinity(Mem *pRec, char affinity, u8 enc){ /* vdbe.c:397-428 */
  if( affinity>=SQLITE_AFF_NUMERIC ){
    if( (pRec->flags & MEM_Int)==0 ){
      if( (pRec->flags & (MEM_Real|MEM_IntReal))==0 ){
        if( pRec->flags & MEM_Str ) applyNumericAffinity(pRec,1);
      }else if( affinity<=SQLITE_AFF_REAL ){
        sqlite3VdbeIntegerAffinity(pRec);   /* REAL 亲和:能转整型则转 */
      }
    }
  }else if( affinity==SQLITE_AFF_TEXT ){
    if( 0==(pRec->flags&MEM_Str) && (pRec->flags&(MEM_Real|MEM_Int|MEM_IntReal)) )
      sqlite3VdbeMemStringify(pRec, enc, 1);
    pRec->flags &= ~(MEM_Real|MEM_Int|MEM_IntReal);  /* 文本化后剥离数值表示 */
  } /* BLOB/NONE:不动 */
}
```

三个语义要点:(1) **TEXT 亲和只转"有数值表示的值",blob 与 NULL 永不转**(vdbe.c:412-424);(2) **NUMERIC/INTEGER/REAL 亲和只对字符串动手**,且"能无损转成整数就转成整数,即使亲和是 REAL——因为整型在磁盘上更省"(vdbe.c:380-384 注释);(3) 文本转数后**必须丢弃文本表示**,否则 '4.0' 之类非规范形式会留在 Mem 里,`applyNumericAffinity` 尾部 `pRec->flags &= ~MEM_Str` 的注释(vdbe.c:367-371)引用了 ticket 343634942dd54ab57b7024。字符串→数的判定在 `applyNumericAffinity`(vdbe.c:354-372):`sqlite3MemRealValueRC` 返回码的 bit1 表示"无小数点/无指数"(vdbe.c:673-674 的不变量注释),此时用 `sqlite3Atoi64` 尝试整型;`bTryForInt=1` 时 '48.00' 这类也落回整型(`sqlite3VdbeIntegerAffinity` 要求 real→int→real 往返无损且非 INT64 边界值,vdbemem.c:814-827)。

### 4.3 转换时机清单(什么时候发生?)

1. **写入时(INSERT/UPDATE,生成记录前)**:非 STRICT 表生成 `OP_Affinity`(vdbe.c:3525-3548,P4 是 `sqlite3TableAffinityStr` 生成的逐列亲和性字符串,insert.c:204-223);OP_MakeRecord 自身若带 P4 亲和串也会先 `applyAffinity`(vdbe.c:3623-3639)。REAL 亲和在此处把整型改成 `MEM_IntReal`(vdbe.c:3630-3633)——以整型存储但"身份是 real",这是 SQLite 把"REAL 列省空间"与"类型上报正确"两者调和的关键标志位。
2. **比较时**:比较 opcode(OP_Eq/OP_Lt/...)的 P5 编码了比较亲和性,`comparisonAffinity`(expr.c:366-381)按 `sqlite3CompareAffinity`(expr.c:344-360)合成:两侧都是列 → 一方有数值亲和则用 NUMERIC,否则 BLOB(即不转换);只有一侧是列 → 用列亲和。运行到比较 opcode 时对字符串侧调 `applyNumericAffinity`(vdbe.c:2412-2417,OP_Eq/OP_Lt 共享体内;vdbe.c:5010,OP_SeekGE/SeekLT 族),索引可用性也据此判定:`sqlite3IndexAffinityOk`(expr.c:389-398)。
3. **CAST 时(强制)**:`sqlite3VdbeMemCast`(vdbemem.c:926-966)与亲和性的区别写在注释里:"Casting is different from applying affinity in that a cast is forced ... even if that results in loss of data"(vdbemem.c:920-925)。CAST 到 NUMERIC 调 `sqlite3VdbeMemNumerify`(vdbemem.c:893-917):**尽力解析,哪怕字符串不完整**("Convert as much of the string as we can and ignore the rest",vdbemem.c:889-891),这与 `applyNumericAffinity` 的"无损才转"形成对照。
4. **读取时(不转)**:OP_Column 只按 serial type 还原,不做任何亲和性处理——存储类别是值的属性。

### 4.4 Mem 数值提取的工程细节

`sqlite3VdbeIntValue`(vdbemem.c:641-657)与 `sqlite3VdbeRealValue`(vdbemem.c:770-785)是"多表示取值"入口。文本转浮点有两个易踩的坑被显式处理:字符串可能非 UTF8/非零终止,`sqlite3MemRealValueRCSlowPath` 会先复制成 C 串再 `sqlite3AtoF`(vdbemem.c:677-718);int 与 float 比较绝不能 `(double)i` 了事,`sqlite3IntFloatCompare`(vdbeaux.c:4523-4540)先处理 NaN("SQLite considers NaN to be a NULL. And all integer values are greater than NULL")、再做范围截断、最后才数值比较。`sqlite3RealToI64`(vdbemem.c:879-883)同样为避开 UBAN 的"溢出转换"警告而夹逼。

---

## ⑤ 严格模式(STRICT)与 collation 定制

### 5.1 STRICT 表:从"倾向"回到"约束"

STRICT 在 `sqlite3EndTable` 收尾处理(build.c:2756-2792):每列类型必须是标准六类之一,`eCType==COLTYPE_CUSTOM`(自定义类型串)直接报 "unknown datatype";无类型列报 "missing datatype";`COLTYPE_ANY` 列的亲和性固定为 BLOB(build.c:2781-2782);非 IPK 的主键列被隐式 `NOT NULL`(build.c:2784-2790)。标准类型清单与枚举的对应关系在 global.c:404-411(`ANY/BLOB/INT/INTEGER/REAL/TEXT`)与 sqliteInt.h:2302-2308(`COLTYPE_*`)。

运行时的落点是**新 opcode `OP_TypeCheck`**(vdbe.c:3426-3514):代码生成器把刚生成的 OP_MakeRecord 原地改名为 OP_TypeCheck、再补插一条 MakeRecord(insert.c:182-201),即"记录造出来之前先验类型"。其语义:先 `applyAffinity`(vdbe.c:3455),再按 `eCType` 逐列核验 Mem flags——INTEGER 列必须 `MEM_Int`,TEXT 必须 `MEM_Str`,BLOB 必须 `MEM_Blob`(3458-3468)。REAL 列的处理最讲究(vdbe.c:3471-3493):

```c
/* vdbe.c:3474-3490(节选) */
if( pIn1->flags & MEM_Int ){
  if( pIn1->u.i<=140737488355327LL && pIn1->u.i>=-140737488355328LL){
    pIn1->flags |= MEM_IntReal;   /* 6 字节装得下:保留整型精度 + REAL 身份 */
    pIn1->flags &= ~MEM_Int;
  }else{
    pIn1->u.r = (double)pIn1->u.i;
    pIn1->flags |= MEM_Real;      /* 否则降级为 double */
  }
}
```

也就是说 STRICT REAL 列存 `5` 实际以 6 字节整型落盘,但 `typeof()` 报 'real'。类型不符报 `SQLITE_CONSTRAINT_DATATYPE`(vdbe.c:3509-3513)。

存量数据的体检在 `PRAGMA integrity_check`:它生成 `OP_IsType`(vdbe.c:2860-2920)——**直接用游标已解析的 serial type 位掩码判型,不物化列值**(vdbe.c:2872-2897 的 aMask 表:0x01=INT,0x02=FLOAT,0x04=TEXT,0x08=BLOB,0x10=NULL)。STRICT 表用 `aStdTypeMask[]`(pragma.c:1987-1994,如 INT/INTEGER=0x11 即 NULL+INT);非 STRICT 表也做软校验:TEXT 亲和列禁止 NUMERIC 值(掩码 0x1c,pragma.c:2003-2011),数值亲和列禁止"可无损转数的 TEXT"(先 OP_Affinity 转一遍再验,pragma.c:2012-2028)。唯一例外是 NaN:serial type 7 读出的 NaN 等价 NULL,OP_IsType 检测不到,必须真的 `OP_Column` 读值判 NULL(pragma.c:1965-1972 的注释专门说明)。

### 5.2 collation 与 KeyInfo

定制 collation 经 `sqlite3_create_collation`(main.c:3806-3844)注册;列级 `COLLATE` 在 `sqlite3AddCollateType` 挂到 Column(build.c:2004 起);表达式级解析遵循"COLLATE 算符 > 列默认 > 左操作数优先"的次序(`sqlite3ExprCollSeq`,expr.c:248-317,注释见 255-262)。比较规则最终汇聚到 `KeyInfo.aColl[]/aSortFlags[]`,由 `sqlite3KeyInfoOfIndex`(build.c:5733-5760)从 Index 构造:**BINARY collation 存成 NULL**(build.c:5748-5749:`pKey->aColl[i] = zColl==sqlite3StrBINARY ? 0 : ...`),使比较器可以在无 collation 时走 memcmp 快路径——这就是 FindCompare 的 `aColl[0]==0` 检查(vdbeaux.c:5119-5121)得以成立的原因;若索引引用了未注册的 collation,索引会被标记 `bNoQuery` 停用直到 schema 重载(build.c:5753-5761)。

跨编码(UFT8↔UTF16)字符串比较由 `vdbeCompareMemStringWithEncodingChange` 先统一编码再调 `pColl->xCmp`(vdbeaux.c:4422-4447);编码一致时直接调用户函数(vdbeaux.c:4454-4457)。

### 5.3 NULL 排序与 ROWID 别名

NULL 的全序位置由 `sqlite3MemCompare` 定死:NULL 最小(vdbeaux.c:4560-4565),NULL==NULL。因此 ASC 时 NULL 在前、DESC 时自然在后;`NULLS FIRST/LAST` 语法只存在于查询的 ORDER BY(parse.y:943-944),**不允许**出现在索引/主键定义中——`sqlite3HasExplicitNulls` 会报 "unsupported use of NULLS FIRST/LAST"(build.c:3992-4006,调用点 build.c:4061)。索引内部需要"NULL 视为最大"语义的只有 min() 优化:`minMaxQuery` 对可能为 NULL 的 min() 参数设置 `KEYINFO_ORDER_BIGNULL`(select.c:5481-5485),让 b-tree 顺扫时跳过前导 NULL。

ROWID 别名机制:单列、INTEGER(`eCType==COLTYPE_INTEGER`)、ASC 的 PRIMARY KEY 不建索引,而是把列下标记进 `pTab->iPKey`(build.c:1885-1963,注释明言 "No index is created for INTEGER PRIMARY KEYs",build.c:1892-1893)。此后所有读写按列序号 `==pTab->iPKey` 或 `XN_ROWID(-1)`(sqliteInt.h:2887)分流到 rowid 路径(select.c:2052、2225、2320 等)。因为表 b-tree key 即 rowid,IPK 的索引就是表本身;二级索引里 rowid 是记录末列,由 `sqlite3VdbeIdxRowid` 直取(vdbeaux.c:5172-5197)。注意 `iPKey` 在 ALTER TABLE 等场景会被重算或清 -1(build.c:2471-2486),且 WITHOUT ROWID 表强制有 PK、无 IPK(build.c:2800-2808)。

顺带一提 FLEXNUM(SQLITE_AFF_FLEXNUM,'F'):它不来自任何 DDL,而是**子查询结果列**的亲和性——当结果列是 `CAST(x AS NUMERIC)` 时赋 FLEXNUM(select.c:2440),语义是"比较时把文本转数,但其余场合不动值"(vdbe.c:386-388),用于让 `WHERE cast_col = 5` 能走索引,同时避免写入路径的强制转换。这是 3.54 开发版里较新的语义拼图。

---

## ⑥ 设计动机与取舍

1. **自描述头 vs 定长行**:每行多出 1+K 字节头部(varint type),换来的是逐行最优存储(0/1 零字节、小整数 1 字节)与 schema 演化弹性(行间列数可不同,OP_Column 对越界列返回 NULL)。对以"页内扫描+点查"为主的嵌入式负载,这是合理权衡;对需要紧凑定长行的分析型负载则纯属开销。
2. **函数指针单态化**:比较器族不是"一个带分支的函数",而是按查找键首列类型**为每次搜索选择一个专用函数**(FindCompare 返回函数指针,btree.c:6085),把"是否 DESC、是否 BINARY、首列类型"这些循环不变量全部编译进选择期,循环体里只剩 `r1/r2` 这类 i8 比较。这是 C 里手工做的"部分求值/JIT-lite"。
3. **越界读换速度**:74/18 字节 padding、OVERRUN 7、`aShift` 8 字节读 + 算术右移,都在用"调用方保证多给一点内存"换掉逐字节循环与分支。代价是形成多处脆弱的跨文件数值契约(§3.5),并且依赖实现定义行为(注释自述靠 assert+testcase 兜底,vdbeaux.c:4970-4981)。
4. **MEM_IntReal/IntReal 折中**:REAL 亲和值尽量整型存储(MEM_IntReal),既满足"整型更省"的文件格式原则(vdbe.c:380-384),又保证 `typeof`/STRICT 校验/浮点比较语义正确。这比 8 字节浮点硬存 `5.0` 省一半,还维持了精度(6 字节整型范围内无损)。
5. **类型 10 的复用**:serial type 10 本是保留值,被挪用为"虚表 UPDATE 未变更列"的内部哨兵(vdbe.c:3685-3695,注释详述 xUpdate + `sqlite3_value_nochange()` 的配合),所有比较器都硬编码 10 的裁决(如 vdbeaux.c:4763-4764 `rc = serial_type==10 ? -1 : +1`),不给外部可见语义。
6. **STRICT 的渐进式落地**:STRICT 没有改变文件格式,只是(a)建表期收紧 DDL,(b)写入期用 OP_TypeCheck 前置校验,(c)体检期用 OP_IsType 基于串类型的位掩码静态判型。三者都不触碰比较器与 record 格式,说明动态类型是文件格式承诺,STRICT 是 API 层约束——两者正交。
7. **转换语义的"无损优先"分层**:同一个"把字符串变成数"的需求,SQLite 给出了三种强度截然不同的实现:`applyNumericAffinity`(无损才转,失败则保留原值,vdbe.c:354-372)、`sqlite3VdbeMemNumerify`(尽力而为,解析前缀,CAST 用,vdbemem.c:893-917)、以及完全不做转换的读取路径(OP_Column)。强度由 SQL 语义决定:亲和性是"建议"、CAST 是"断言"、读取是"事实"。很多来自其他数据库的工程师在这里踩坑,根源是把三种强度混为一谈。
8. **防御式解析贯穿始终**:从 OP_Column 的 98307 头长上限、`d1>(unsigned)nKey1` 的提前退出(vdbeaux.c:4743-4746)、比较器里对 `serial_type1+2>nKey1` 的近似空间校验(vdbeaux.c:4320-4333),到溢出 buffer 的 18 字节清零(vdbe.c:6222),所有解码路径都假设输入可能来自损坏的文件。SQLite 作为嵌入式引擎无法用"沙箱"保护自己,只能让每个解析函数自带防护,这些散落的检查点值得在安全审计时逐一核对。

---

## ⑦ FAQ

**Q1:为什么 `INTEGER PRIMARY KEY` 没有对应的索引?**
因为它就是 rowid 的别名:列值即表 b-tree 的 key(build.c:1892-1893 不建索引;读写路径按 `pTab->iPKey` 分流,select.c:2052)。二级索引的最后一列固定是 rowid,由 `sqlite3VdbeIdxRowid` 免解码直取(vdbeaux.c:5172-5197)。

**Q2:把 '1.0' 存进 INTEGER 列,读出来是什么?**
写入时 OP_Affinity/OP_TypeCheck 调 applyAffinity:'1.0' 可无损转 1.0 → `sqlite3VdbeIntegerAffinity` 往返无损 → 以 MEM_Int 落盘,serial type 1,读回是整数 1。若存 'abc' 则原样保留文本(applyAffinity 的"无损才转"原则,vdbe.c:339-343)。反过来,把 5 存进 TEXT 列会变成 '5'(sqlite3VdbeMemStringify,vdbemem.c:471),并且 Mem 里原有的整数表示被剥离(vdbe.c:426)——这就是"TEXT 列看起来把数字变成了字符串"的机制。注意 BLOB(NONE) 亲和列两者都不做:数字仍是数字,这也是"无类型列不转数字"的出处。

**Q3:为什么 STRICT 表里 REAL 列存 5,`typeof()` 是 'real' 却可以整型落盘?**
OP_TypeCheck 对 6 字节可容纳的整数打 MEM_IntReal 标记(vdbe.c:3474-3486):存储用 serial type 1-5(整型),身份是 REAL。超出 6 字节范围才降级为 8 字节浮点(vdbe.c:3487-3490)。

**Q4:`BLOBINT` 这种奇怪类型名的亲和性是什么?**
INTEGER。`sqlite3AffinityType` 按优先级扫子串,INT 命中即 break(build.c:1742-1745;文档注释 build.c:1690-1694)。

**Q5:记录头最长能有多少?为什么?**
98307 字节(=32768 列×3 字节 type+3)。OP_Column 用它防损坏 DB 的超大分配(vdbe.c:3123-3134),调试比较器也有同样断言(vdbeaux.c:4302)。但优化快路径只敢假设头 ≤127(单字节 varint),通用比较器则用 varint 解析兜底。

**Q6:NULL 排序在哪一端?`NULLS FIRST/LAST` 能用在索引上吗?**
NULL 是全序最小值(vdbeaux.c:4560-4565),ASC 在前、DESC(取反后)在后。NULLS FIRST/LAST 语法仅限 ORDER BY(parse.y:943-944),索引用它会被 `sqlite3HasExplicitNulls` 拒绝(build.c:3998-4000)。

**Q7:为什么 RecordCompareInt/String 只服务 ≤13 列的索引?**
它们假设头长 varint 单字节且可安全越界读;13 列时最大头 62 字节 ≤ 63,配合调用方 74 字节 padding 契约刚好安全(vdbeaux.c:5086-5098)。多列索引自动退回通用版。这一限制只影响速度不影响正确性:超限的索引在每次搜索时都走 `sqlite3VdbeRecordCompareWithSkip` 的逐列循环,多付一次函数指针间接调用与若干分支。实践中复合索引超过 13 列本身就很少见(SQLITE_MAX_COLUMN 默认 2000,但优化器推荐 3-5 列),所以这个数字的取舍非常务实。

**Q8:TEXT 和 BLOB 谁大?数字和文本谁大?**
存储类别全序:NULL < 数字 < TEXT < BLOB(vdbeaux.c:4544-4547;字符串与 blob 相碰时 text 更小,vdbeaux.c:4610-4619)。TEXT 内部用 collation,BLOB 用 memcmp。

**Q9:比较器里的 `default_rc` 是干什么的?**
非唯一索引上,查找键可能匹配多条记录。`default_rc=±1` 让二分收敛到第一个/最后一个匹配,0 表示取精确项;`eqSeen` 告诉上层是否存在精确等值(sqliteInt.h:2752-2764)。`r1/r2` 则把 DESC 翻转前移到初始化期(vdbeaux.c:5106-5111)。顺带回答一个相邻问题:为什么快路径要把 r1/r2 缓存进 UnpackedRecord 而不是每次判断 DESC?因为 b-tree 二分内层循环每页要调用几十次比较器,把 DESC 翻转、首列值、首列字符串指针全部在 `sqlite3VdbeFindCompare` 阶段物化成标量字段(sqliteInt.h:2769-2779),内层循环只需访问栈上一小块结构,缓存友好且便于编译器寄存器分配。

**Q10:文件里存了一个 NaN,读出来是什么?排序时算大算小?**
读回即 NULL(`sqlite3VdbeSerialGet7` 的 IsNaN 分支,vdbeaux.c:4076-4079);比较时 NaN 被当作 NULL,任何整数都大于它(vdbeaux.c:4524-4527)。integrity_check 为此必须物化 REAL 列再验 NULL(pragma.c:1965-1972)。

**Q11:为什么比较亲和性在"两列都无数值亲和"时是 BLOB(不转换)而不是 TEXT?**
防止 `WHERE text_col = int_col` 之类把两侧强行文本化/数值化造成索引失效与语义漂移;expr.c:346-354 的规则是"有一方数值亲和才用 NUMERIC,否则不转"。索引能否使用由 `sqlite3IndexAffinityOk` 同源判定(expr.c:389-398)。

**Q12:`CAST('12abc' AS INTEGER)` 得到什么?为什么和 WHERE 里的转换不一样?**
12。CAST 走 `sqlite3VdbeMemCast`→`sqlite3VdbeMemNumerify`,强制解析前缀、忽略尾部垃圾(vdbemem.c:889-917);而亲和性/比较走 `applyNumericAffinity`,无损才转(vdbe.c:354-372)。一个是显式断言,一个是尽量兼容。

---

## ⑧ 深挖问题

1. **record.c 的消亡史**:SerialPut 内联(vdbeaux.c:3867 注释记为 2022-04-02)与 SerialType 的 `#if 0` 化(vdbeaux.c:3903-3913,注因"STAT3 已终结")意味着 SQLite 用"把热点摊进 opcode"替代"独立翻译单元"。可对照 3.38 之前的 record.c 与 OP_MakeRecord 当前 350 行的实现,量化内联收益(vdbe.c:3682-3774 与老函数逐行 diff 几乎一致),并讨论 amalgamation 与编译器内联边界的关系。
2. **算术右移的 UB 契约**:vdbeRecordCompareInt 用 `(i64)sqlite3Get8byte(aKey) >> aShift[st]` 同时完成"丢弃低位"与"符号扩展"(vdbeaux.c:4967-4981),依赖有符号数算术右移这一实现定义行为,注释甚至自嘲引用了 Claude 的说法。值得实测各编译器/UBSAN 下行为,并对比 `vdbeRecordDecodeInt`(vdbeaux.c:4650-4682)中 `*(int*)&y`、`*(i64*)&x` 这类严格别名违例为何被接受(同为 hot path,历史包袱)。
3. **padding 数值契约的传递链**:74 字节(vdbeaux.c:5090-5094 假设)→ btree 页内 cell(btree.c:6184 直接用页内指针)→ 溢出路径降级 18 字节 + 通用比较器(btree.c:6204、6228)→ OVERRUN 7(vdbe.c:3799-3803)。这条链上任何一处数字改动都没有类型系统保护;可以写一个 Fuzz/断言实验验证 74 的下界来源(最大合法头 63 + 8 + 余量?)。
4. **BIGNULL × DESC 的布尔正确性**:WithSkip 尾部 `if((sortFlags&KEYINFO_ORDER_BIGNULL)==0 || ((sortFlags&KEYINFO_ORDER_DESC)!=(serial_type==0||rhs NULL))) rc=-rc;`(vdbeaux.c:4887-4892)与调试对拍版 `rc=-rc` 的直白写法(vdbeaux.c:4346-4350)语义不同(前者避免把"DESC+与 NULL 比较"错误翻回)。构造 `(a INTEGER DESC NULLS LAST?)` 式真值表逐格验证,并解释为什么 min() 优化只需 ASC+BIGNULL 一种组合(select.c:5481-5485)。
5. **FLEXNUM 的完整语义闭环**:FLEXNUM 仅在子查询列来自 `CAST(x AS NUMERIC)` 时产生(select.c:2440),applyAffinity 对它"只转文本、别的不动"(vdbe.c:386-388),而 build.c:2216 在 table_info 的类型回推中给它 " NUM" 显示名。需要回答:它与 NUMERIC 亲和在写入、比较、索引可用性三个场景的精确差异,以及为何不用普通 NUMERIC 即可(猜测:NUMERIC 会触发写入路径 OP_Affinity,破坏 CAST 列的"只读时转换"意图)。

---

### 附:本报告引用文件清单

| 文件 | 引用要点(行号) |
|---|---|
| src/vdbeaux.c | 3862-3901(格式总注)、3979-4011(定长表)、4066-4186(SerialGet)、4214-4257(Unpack)、4271-4377(Debug 对拍)、4422-4461(编码切换比较)、4523-4640(IntFloatCompare/MemCompare)、4650-4682(DecodeInt)、4705-4931(WithSkip/RecordCompare)、4943-5078(Int/String 快路径)、5085-5130(FindCompare)、5140-5210(IdxRowid) |
| src/vdbe.c | 354-372(applyNumericAffinity)、397-428(applyAffinity)、469-491(computeNumericType)、2860-2920(OP_IsType)、3426-3514(OP_TypeCheck)、3525-3548(OP_Affinity)、3577-3928(OP_MakeRecord) |
| src/vdbemem.c | 641-657(IntValue)、669-751(RealValueRC 不变量)、802-829(IntegerAffinity)、834-857(Integerify/Realify)、868-883(RealSameAsInt/RealToI64)、893-917(Numerify)、919-966(Cast) |
| src/build.c | 1549-1655(AddColumn)、1696-1776(AffinityType)、1885-1963(AddPrimaryKey/iPKey)、2227-2240(类型名回推)、2756-2792(STRICT)、3992-4006(NULLS 拒绝)、5733-5760(KeyInfoOfIndex) |
| src/insert.c | 160-224(TableAffinity/OP_TypeCheck 落位) |
| src/pragma.c | 1900-2028(integrity_check 类型校验) |
| src/expr.c | 248-317(ExprCollSeq)、344-398(比较亲和性) |
| src/btree.c | 6068-6259(IndexMoveto/xRecordCompare 衔接) |
| src/select.c | 2400-2450(FLEXNUM)、5460-5496(minMaxQuery/BIGNULL) |
| src/sqliteInt.h | 2302-2308(COLTYPE)、2370-2385(AFF 宏)、2704-2730(KeyInfo)、2766-2780(UnpackedRecord)、2887(XN_ROWID) |
| src/global.c | 395-411(标准类型表) |
| src/parse.y | 936-944(sortorder/nulls) |
| src/main.c | 3806-3844(create_collation) |
