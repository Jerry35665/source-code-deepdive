# M - TOAST 超长属性存储深度调研

> 源码版本：PostgreSQL master，commit `8c7a74c3239ce29940582643533a190721b395c0`（shallow clone）。
> 所有行号均已用 grep/Read 核对，路径为仓库相对路径。
> 与卷一 09 章"B-tree 索引"的衔接：索引元组不含外部 toast 指针（见第 6 节）；与 07 章 VACUUM 的 toast 表清理顺序也在第 6 节兑现。

TOAST（The Oversized-Attribute Storage Technique）解决一个问题：8KB 页约束下如何存一个可达 1GB 的字段。答案不是"更大的页"，而是**压缩 + 移出 + 分片**三件套：能压就压着内联，压不动就整体搬到一张影子表（toast 表）并留下 18 字节指针，影子表里再按约 2KB 一片存放。

---

## 1. 全景：一个长文本的存储旅程

```
INSERT INTO t(bigtext) VALUES (<1MB 文本>)
────────────────────────────────────────────
 heap_insert (heapam.c:2259-2266)
   │  t_len > TOAST_TUPLE_THRESHOLD(2032B)? ──否──▶ 原样入主堆页
   ▼ 是
 heap_toast_insert_or_update (heaptoast.c:96)        ┌── 主堆页 (8KB) ──────────┐
   │  第1轮: EXTENDED 列先压缩 (heaptoast.c:184-218)  │ t_id=1 | bigtext ┐      │
   │  单列仍超限 → 立即外置                            │  = 18B toast指针 ┘      │
   │  第2轮: EXTENDED/EXTERNAL 列外置 (220-235)       └──────────────────────────┘
   │  第3轮: MAIN 列压缩 (237-251)                              │
   │  第4轮: MAIN 列外置, 目标放宽到整页 (253-271)               ▼
   ▼                                              toast_save_datum
 toast_save_datum (toast_internals.c:118)          (toast_internals.c:118-367)
   │  分配值OID va_valueid (217-220)                 ┌── pg_toast.pg_toast_16400 ─┐
   │  按 TOAST_OID_MAX_CHUNK_SIZE(1996B) 分片 (283)  │ chunk_id=104032 seq=0 data │
   │  每片一行: (valueid, seq++, 1996B) (306-314)    │ chunk_id=104032 seq=1 data │
   │  每行插 (chunk_id,chunk_seq) 唯一索引 (327-337) │ chunk_id=104032 seq=2 data │
   │  返回 18B 指针 (359-366)                        │ ...                        │
                                                   └────────────────────────────┘

SELECT substring(bigtext, 1, 100)                   ──按需解包(detoast)──
────────────────────────────────────────────────
 执行器里 Datum 仍是 18B 指针，不解包；
 真正解包发生在函数取参时:
   PG_DETOAST_DATUM_PACKED (fmgr.h:248) → detoast_attr (detoast.c:116)
 substring 走 slice 路径 (varlena.c:586 text_substring → fmgr.h:305
   DatumGetTextPSlice → detoast.c:204 detoast_attr_slice)
   未压缩外部值: 只取覆盖目标区间的那几片 (detoast.c:232-234)
   pglz 压缩值: 算出"够解出前缀"的压缩字节数再取 (detoast.c:254-256)
   lz4 压缩值: 前缀必须整取 (detoast.c:249-252 注释)
```

关键分工：**toaster 决定"怎么放"**（heaptoast.c + toast_helper.c），**detoast 决定"怎么取"**（detoast.c + fmgr.c:1797-1836），两者只通过 varlena 值头里的指针/标志位通信，主元组头完全不知情。

## 2. va_tag 四形态专节：varlena 值头的位级布局

任何 toastable 类型（attlen = -1 的 varlena）的值都以 1 字节头开头，靠头两位区分四种形态（小端机布局，src/include/varatt.h:169-174 注释，宏实现 233-242）：

| 形态 | 首字节（小端） | 宏 | 说明 |
|---|---|---|---|
| ① 普通内联 | `xxxxxx00` | `VARATT_IS_4B_U`（varatt.h:235） | 4 字节头，长度=头>>2，最多约 1GB |
| ② 压缩内联 | `xxxxxx10` | `VARATT_IS_4B_C`（varatt.h:237） | 4 字节头 + 4 字节 va_tcinfo（解压后大小+压缩法） |
| ③ 短内联 | `xxxxxxx1` | `VARATT_IS_1B`（varatt.h:239） | 1 字节头，长度=头>>1，≤126B（VARATT_SHORT_MAX=0x7F，varatt.h:284） |
| ④ 外部指针 | `00000001` | `VARATT_IS_1B_E`（varatt.h:241） | 头后跟 1 字节 va_tag 区分指针种类 |

判别顺序很讲究：先查 EXTERNAL 再查 1B——因为外部指针也是 1B 形态，`VARSIZE_1B` 对它会返回 0（varatt.h:193-195 注释）。三种底层结构（varatt.h:131-159）：

```c
typedef union
{
    struct                      /* Normal varlena (4-byte length) */
    {
        uint32      va_header;
        char        va_data[FLEXIBLE_ARRAY_MEMBER];
    }           va_4byte;
    struct                      /* Compressed-in-line format */
    {
        uint32      va_header;
        uint32      va_tcinfo;  /* Original data size ... and
                                 * compression method; see va_extinfo */
        char        va_data[FLEXIBLE_ARRAY_MEMBER];
    }           va_compressed;
} varattrib_4b;                      /* varatt.h:131-145 */

typedef struct { uint8 va_header; ... } varattrib_1b;        /* varatt.h:147-151 */
typedef struct { uint8 va_header; uint8 va_tag; ... } varattrib_1b_e; /* 154-159 */
```

**④ 外部指针**里 va_tag 有四种取值（vartag_external 枚举，varatt.h:89-95）：`VARTAG_INDIRECT=1`（指向内存中另一 varlena）、`VARTAG_EXPANDED_RO=2`/`RW=3`（expanded object，如 array 的展开形态）、`VARTAG_ONDISK_OID=18`（磁盘 toast 表指针；18 这个怪值是为了兼容"曾把 tag 当长度"的老盘上格式，varatt.h:84-88 注释）。

磁盘 toast 指针携带 16 字节寻址信息（varatt_external_oid，varatt.h:32-39）：

```c
typedef struct varatt_external_oid
{
    int32       va_rawsize;   /* 原始(解压后)大小, 含头 */
    uint32      va_extinfo;   /* 实际存储大小(不含头) + 高2位压缩法 */
    Oid         va_valueid;   /* toast 表内的值 ID */
    Oid         va_toastrelid;/* toast 表的 OID */
} varatt_external_oid;
```

加上 2 字节头，整个指针共 18 字节（TOAST_OID_POINTER_SIZE，src/include/access/detoast.h:31）。指针在元组内**不对齐存储**，必须 memcpy 进局部变量再读字段（VARATT_EXTERNAL_GET_POINTER，detoast.h:22-28）。

**"压缩外部"是 ④ 的子形态，不占独立编码**：va_extinfo 低 30 位存实际存储大小，高 2 位存压缩法（VARLENA_EXTSIZE_BITS=30，varatt.h:49-50；`VARATT_EXTERNAL_SET_SIZE_AND_COMPRESS_METHOD`，varatt.h:528-534）。判定不靠标志位而是靠**大小比较**：extsize < rawsize - VARHDRSZ 即被压缩过（`VARATT_EXTERNAL_OID_IS_COMPRESSED`，varatt.h:543-548）——因为系统只在真省空间时才压缩。

长度上限由此定死：4B 头长度字段只有 30 位（varatt.h:247-248 小端 `>>2 & 0x3FFFFFFF`），加上 palloc 上限 MaxAllocSize = 0x3fffffff（src/include/utils/memutils.h:40），**任何单个字段（含头部）≤ 1GB-1**。

## 3. 分片专节：CHUNK_SIZE 为什么是 1996

toast 表固定三列（toasting.c:239-251）：`chunk_id Oid` + `chunk_seq int32` + `chunk_data bytea`，三列全部强制 `TYPSTORAGE_PLAIN`、禁止压缩——**toast 表绝不能再被 toast，否则递归**（toasting.c:253-265 注释原话："Ensure that the toast table doesn't itself get toasted, or we'll be toast :-("）。

分片大小推导（src/include/access/heaptoast.h）：

```c
#define MaximumBytesPerTuple(tuplesPerPage) \
    MAXALIGN_DOWN((BLCKSZ - \
                   MAXALIGN(SizeOfPageHeaderData + (tuplesPerPage) * sizeof(ItemIdData))) \
                  / (tuplesPerPage))              /* heaptoast.h:23-26 */
#define EXTERN_TUPLES_PER_PAGE  4                 /* heaptoast.h:80 */
#define EXTERN_TUPLE_MAX_SIZE   MaximumBytesPerTuple(EXTERN_TUPLES_PER_PAGE)  /* :82 */
#define TOAST_OID_MAX_CHUNK_SIZE    \
    (EXTERN_TUPLE_MAX_SIZE - MAXALIGN(SizeofHeapTupleHeader) -  \
     sizeof(Oid) - sizeof(int32) - VARHDRSZ)      /* heaptoast.h:84-89 */
```

代入 8KB 页：页头 24B + 4 个行指针 16B = 40B；`(8192-40)/4 = 2038`，MAXALIGN_DOWN 后 **EXTERN_TUPLE_MAX_SIZE = 2032**；再减 toast 元组自身开销（元组头 23→MAXALIGN 24 + chunk_id 4 + chunk_seq 4 + chunk_data 变长头 4）= **每片数据 1996 字节**。设计目标：一条 toast 元组 24+4+4+2000 = 2032B，**每页恰好放下 4 条**（EXTERN_TUPLES_PER_PAGE，heaptoast.h:72-76 注释明说"fit EXTERN_TUPLES_PER_PAGE tuples of maximum size onto a page"）。改这个数必须 initdb（heaptoast.h:78）。

主键 `(chunk_id, chunk_seq)` 是一把**唯一 btree 索引**（toasting.c:317-369：ii_Unique=true 在 341，BTREE_AM_OID 在 349，操作符类 OID_BTREE_OPS_OID/INT4_BTREE_OPS_OID 在 356-357）。注释解释为何要两列索引：单列也能工作，但按片读取靠 `(chunk_id, chunk_seq)` 范围条件直接定位连续片段，且唯一性防止值 OID 重复（toasting.c:320-327）。

写入循环（toast_internals.c:283-349）：`chunk_size = Min(TOAST_OID_MAX_CHUNK_SIZE, data_todo)`（:301），每片 `t_values[0]=值OID, [1]=chunk_seq++`（:306-307），逐片 heap_insert + 对每个 indisready 的索引 index_insert（:314, 327-337）。值 OID 用 GetNewOidWithIndex 从 toast 索引分配（:217-220）；表重写（CLUSTER/ATRewrite）时若旧 toast 值沿用同一 toast 表则**复用旧值 OID**，避免已死行版本的拷贝占用空间且 VACUUM 无法回收（:222-278，尤其是 239-259 的 corner case 注释）。

**1GB 字段为何可行**：seq 是 int32，1996B × 2^31 片 ≈ 4TB 理论容量，远超 va_extinfo 30 位给出的 1GB 单值上限——瓶颈在长度编码而非分片；读取端按 `startchunk = sliceoffset/1996` 精确换算页范围（heaptoast.c:652-654，heap_fetch_toast_slice）。

## 4. 压缩专节：pglz vs lz4，何时压、何时解

**压缩法编码**：内部 ID `TOAST_PGLZ_COMPRESSION_ID=0`、`TOAST_LZ4_COMPRESSION_ID=1`（src/include/access/toast_compression.h:39-41）；列存储的字符形式 `'p'/'l'`（toast_compression.h:49-50），存在 pg_attribute.attcompression（src/include/catalog/pg_attribute.h:115-122，默认 `'\0'` 表示跟随全局默认）。

**选法优先级**（toast_compress_datum，src/backend/access/common/toast_internals.c:45-104）：列上 attcompression 有效则用它，否则用 GUC default_toast_compression（:57-59）。注意本 commit 的默认值：**编译进 LZ4 就默认 lz4**（toast_compression.h:56-62 `#ifdef USE_LZ4 → TOAST_LZ4_COMPRESSION`）；GUC 定义在 src/backend/utils/misc/guc_parameters.dat:783-787，枚举项 pglz/lz4 在 guc_tables.c:472-477。

**两种算法**：
- pglz：内置 LZ 变体。默认策略要求输入 ≥32B、前 1KB 内无匹配即放弃、需 25% 压缩率（strategy_default_data，src/common/pg_lzcompress.c:222-234）。
- lz4：LZ4_compress_default，输出 `len > valsize` 视为不可压返回 NULL（lz4_compress_datum，toast_compression.c:166-170）；前缀解压需 liblz4 ≥1.8.3，否则退回整体解压（:225-226）。

**是否采纳压缩的统一门槛**：即使压缩"成功"，也要净省超过 2 字节才用——否则头部 + 对齐填充反而变大（toast_internals.c:81-97，`VARSIZE(tmp) < valsize - 2`）。压缩头 va_tcinfo 同样是 30 位大小 + 2 位方法（toast_compress_header，src/include/access/toast_internals.h:23-46）。

**列级策略**：`ALTER TABLE ... ALTER COLUMN ... SET COMPRESSION lz4` 走 ATExecSetCompression（src/backend/commands/tablecmds.c:19432-19490）：校验类型可 toast（GetAttributeCompression，tablecmds.c:22753-22778，注释强调 attstorage 与 attcompression 相互独立）、改 pg_attribute.attcompression（:19473）并同步索引列（SetIndexStorageProperties，:19481）。注意这只影响**之后新写入**的值；已存值不改写。

**解压时机——默认是"迫不得已才解"**：
- 普通 SQL 函数用 `PG_DETOAST_DATUM_PACKED`（src/include/fmgr.h:248-249），仅当值是压缩/外部形态才解（pg_detoast_datum_packed，src/backend/utils/fmgr/fmgr.c:1829-1836）；内联未压值零成本直通。
- `detoast_external_attr`（detoast.c:44-102）**只取回不解压**——索引插入等"只想要字节"的调用方受益。
- substring 类操作走 slice 路径（text_substring，src/backend/utils/adt/varlena.c:586 起，注释直言"can avoid detoasting all of it in some cases"），未压缩外部值只取覆盖区间的片（detoast.c:232-234），pglz 值用 pglz_maximum_compressed_size 估算要取多少压缩字节（detoast.c:254-256；实现 src/common/pg_lzcompress.c:857），lz4 值因流式格式只能整取（detoast.c:249-252）。
- 解压前还要通过 get_toast_snapshot 检查存在活动快照——跨事务持有 toast 指针再解引用是不安全的（toast_internals.c:628-647；SnapshotToastData 定义 src/backend/utils/time/snapmgr.c:146）。

## 5. 目录 TOAST 专节：系统目录自身的超长值

哪些目录有 toast 表由头文件里 `DECLARE_TOAST(catalog, toastOid, indexOid)` 声明、genbki.pl 生成 BKI `declare toast ... on ...` 语句（src/backend/catalog/genbki.pl:131-137, 707-710），由 bootstrap 语法 `XDECLARE XTOAST oidspec oidspec ON boot_ident` 执行（src/backend/bootstrap/bootparse.y:382-392，词法 src/backend/bootstrap/bootscanner.l:108），最终调 BootstrapToastTable（toasting.c:98-117）用**预先定死的 OID** 建表。

本 commit 实际声明了 toast 表的目录（grep `DECLARE_TOAST` src/include/catalog/*.h）：pg_proc 2836/2837（pg_proc.h:142，prosrc 函数体）、pg_rewrite 2838/2839（ev_action 视图查询树——典型巨无霸）、pg_statistic 2840/2841、pg_trigger 2336/2337（tgargs）、pg_constraint 2832/2833、pg_description/pg_shdescription 2834/2835、2846/2847（长注释）、pg_attrdef 2830/2831（默认值表达式）、pg_index 6351/6352（indexprs/indpred，PG16 起才有）、pg_type 4171/4172 等 34 个。

**必须修正一个常见想当然**：传统认知里 pg_class 有 toast 表（老 OID 2786/2787），但本 commit 的 src/include/catalog/pg_class.h **已无 DECLARE_TOAST**（全文 grep 确认），pg_depend、pg_attribute 也没有——前者本就全是定长 OID 列无需 toast，后者同理；pg_class 的 relacl（pg_class.h:139 aclitem[]）虽是 varlena 但该目录现无 toast 表。也就是说"目录的目录"如今只覆盖仍声明了 DECLARE_TOAST 的那批目录。

自举的鸡生蛋问题与解法：
1. bootstrap 阶段不能用正常事务更新，所以把 reltoastrelid 写进 pg_class 用的是**原地覆盖**（systable_inplace_update_begin/finish，toasting.c:389-408；正常阶段才走 SearchSysCacheCopy1 + CatalogTupleUpdate，:381-388）。
2. toast 表登记依赖 pg_class、而 pg_class 自己的行可能很大——这批引导目录（BKI_BOOTSTRAP，pg_class.h:34）的行在 initdb 时都不会超限，且 needs_toast_table 在 bootstrap 后**禁止给共享目录和系统目录再补建 toast 表**（toasting.c:454-464："Which catalogs get toast tables is explicitly chosen in catalog/pg_*.h"）。
3. 是否需要 toast 表由 AM 决策（table_relation_needs_toast_table，toasting.c:467）；分区表不需要（:447-448）。
4. 主表与 toast 表间记 DEPENDENCY_INTERNAL 依赖，主删则 toast 删（toasting.c:414-428）。

另外本 commit 出现了新旋钮 `toast_value_type`（STDRD_OPTION_TOAST_VALUE_TYPE_OID，toasting.c:162-180；src/include/utils/rel.h:347-348），决定 chunk_id 的类型（当前仅 OID 一档），并为 binary upgrade 强校验（toasting.c:202-220）——是为未来扩展 chunk_id 留的口子。

## 6. 与 09 章 B-tree / 07 章 VACUUM 的衔接

**索引不含 toasted 值**：index_form_tuple 对 varlena 索引列先 `detoast_external_attr`（只取回不解压），再超 TOAST_INDEX_TARGET（MaxHeapTupleSize/16，heaptoast.h:68）才尝试内联压缩，仍大就直接报错（src/backend/access/common/indextuple.c:29-30 的 `#define TOAST_INDEX_HACK`，:110-135 的去 toast + 压缩）。因此大值在索引里最多留下"解压后全量副本"的代价，B-tree（卷一 09 章）键值永远不会是 18 字节指针——引用完整性由"外部值被解出后再进索引"保证。

**UPDATE 的旧指针处理**：toast_tuple_init 对未变化的外部值直接复用（memcmp 比较 18 字节指针，src/backend/access/table/toast_helper.c:73-98），变化的标 TOASTCOL_NEEDS_DELETE_OLD；cleanup 时对旧行的外部值逐个 toast_delete_datum（toast_helper.c:299 附近；删除实现 toast_internals.c:375-439，按值 OID 有序扫索引逐片删）。heap_delete 同步触发 heap_toast_delete（src/backend/access/heap/heapam.c:3184；推测性插入中止 :6516）。

**VACUUM 顺序**（src/backend/commands/vacuum.c）：`VACUUM t` 默认带 VACOPT_PROCESS_TOAST（:175 process_toast=true，:316 拼入 options）；vacuum_rel 先处理主表（:2333-2353），然后**在仍持有主表会话级锁的前提下递归 vacuum_rel(toast_relid)**（:2379-2392），并把 toast_parent 设回主表以便权限检查走主表（:2387-2388）。VACUUM FULL 不递归——toast 表由 cluster_rel 整体重建（:2291-2302 注释）。toast 表的统计信息被有意跳过："the toaster always uses hardcoded index access and statistics are totally unimportant for toast relations"（:2372-2378）。这与 07 章的 lazy vacuum 流程呼应：主表死元组回收不会自动回收 toast 行——toast 行的回收要么靠写入时的立即删除（上面 toast_delete_datum），要么靠这次对 toast 表自身的 vacuum。

## 7. 与前作对照：长值存储的三条路线

| 系统 | 方案 | 与 TOAST 的差异 |
|---|---|---|
| MySQL InnoDB | 溢出页（off-page）：长值整块放溢出页，行内留 20B 指针；溢出页本身不分片，COMPACT/RECOMPACT 格式可留 768B 前缀在行内 | TOAST 分片到**多条堆元组**并建 btree 按 (id,seq) 随机/范围访问，支持只取前缀片；InnoDB 溢出页通常整页读写 |
| SQLite | 无溢出：整库单文件，超长记录直接让单条记录跨页连续存放（页内溢出链），行格式内部解决 | TOAST 把长值搬去**独立的影子关系**，主表页保持紧凑（4 元组/页假设）；SQLite 无独立段、无指针 OID，靠页链 |
| Git | blob 全量存储 + SHA 寻址，无大小上限，靠 packfile 压缩 | 相同点：内容寻址 + 可压缩；TOAST 的 va_valueid 类似 blob hash 的"间接层"角色，但 TOAST 指针里还带大小与压缩法，做到不解包即知元信息 |

TOAST 的独特点：**分片 + 指针 + 原地标志**三者都编码在 18 字节值头里，与 AM 无关（toast_helper.c 是 AM 无关层，heaptoast.c 只是 heap AM 的实现）。

## 8. 设计动机

**为什么 8KB 页需要 TOAST**：页是崩溃恢复与并发的原子单位（卷一 02 章），放大页会拖累全库；缩小单元组上限又毁掉 text/array 的实用性。TOAST 让"常见行很小、罕见行很大"都成立——普通页保持 4 元组/页的密度假设（TOAST_TUPLES_PER_PAGE=4，heaptoast.h:46-50），大值只在专属影子表里以固定 4 元组/页密度排队。

**为什么压缩标志在值头不在元组头**：① 值会被 deform 成 Datum 独立传递，任何函数拿到裸指针就要能解释字节（fmgr.h:224-249 的调用约定），元组头帮不上忙；② toast 机制对任意 AM、任意容器（含复合类型 Datum）通用，唯一可靠位置就是值自身；③ 压缩是**每值**决策（toast_tuple_find_biggest_attribute 找最大列逐个压，toast_helper.c:180-219），不是每元组决策。代价是 varlena 头吃掉 1-4 字节并演化出短头/压缩头/指针头的多态布局。

**为什么按需解压是默认**：典型查询只碰大值的一小部分（substring、哈希前缀、输出客户端）。执行器全程传指针不解包；解压延迟到取参宏，slice API 把 IO 也省了（只取所需片）。误用跨事务持有 toast 指针会被 get_toast_snapshot 的快照检查拦下（toast_internals.c:643-644）——默认策略的边界由此标出。

## 9. FAQ 素材

1. **单字段最大多大？** 约 1GB-1：4B 头长度字段 30 位（varatt.h:247-248）+ MaxAllocSize 0x3fffffff（memutils.h:40）。
2. **一片多大？** 数据 1996B（heaptoast.h:84-89），8KB 页每页 4 条 toast 元组；改动需 initdb（heaptoast.h:78）。
3. **toast 表叫什么名字？** `pg_toast_<主表OID>`，索引 `pg_toast_<主表OID>_index`，放 pg_toast 模式（toasting.c:233-236, 277-280）。
4. **什么时候触发 toaster？** 元组 >2032B（TOAST_TUPLE_THRESHOLD）或已含外部指针（heapam.c:2259-2266）。
5. **PLAIN/EXTERNAL/EXTENDED/MAIN 区别？** 四种列存储策略（pg_type.h:311-314）：PLAIN 完全不动、EXTERNAL 只外置不压、EXTENDED 压+外置、MAIN 尽量内联（压不外置，直到最后目标放宽到整页，heaptoast.c:253-271）。
6. **压缩失败怎么办？** 返回 NULL 标记不可压（TOASTCOL_INCOMPRESSIBLE），后续轮次跳过（toast_helper.c:246-249）；外置是兜底。
7. **UPDATE 大字段会重写全部片吗？** 指针 memcmp 相同则整列复用不重写（toast_helper.c:88-97）；仅表重写复用值 OID 的场景才短路分片循环（toast_internals.c:255-260）。
8. **能对单列指定压缩法吗？** `SET COMPRESSION pglz|lz4`，存 pg_attribute.attcompression（tablecmds.c:19432-19490），只影响新写入。
9. **toast 表有统计吗？** 没有：vacuum 不 ANALYZE toast 表，toaster 走硬编码索引访问（vacuum.c:2372-2378）。
10. **为什么 toast 指针 tag 是 18？** 兼容"曾把 tag 当指针长度"的旧盘上格式（varatt.h:84-88）。

### 深挖方向

1. **`pglz_maximum_compressed_size` 的前缀估算**：如何由目标原始字节反推需取的压缩字节数（src/common/pg_lzcompress.c:843-880），以及 lz4 为何无解（流式 match 可能回指任意远，detoast.c:249-252）。
2. **expanded object 与 VARTAG_EXPANDED_RO/RW**：数组/复合类型在函数间传引用而非拷贝的内存内"第四种 toast"（varatt.h:66-81, 97-103；detoast.c:80-92 展开）。
3. **toast_value_type 旋钮**：chunk_id 类型参数化（toasting.c:149-180）暗示上游正在为 64-bit toast 值 ID 铺路，配合本 commit 已把结构体定名为 varatt_external_oid（varatt.h:32）。
4. **跨 AM 复用**：table/toast_helper.c + tableam 的 relation_fetch_toast_slice 钩子（src/backend/access/heap/heapam_handler.c:2700）——heap 之外的 AM 如何接入同一套 detoast 路径。
5. **HOT 与 toast**：heap_update 走 toast 的路径（heapam.c:3968）与 HOT 链前提（所有索引列未变）如何共存——指针不变是复用条件（toast_helper.c:73-98）。

## 10. 写作要点速查表

| # | 事实 | 位置 |
|---|---|---|
| 1 | 值头四种形态位布局（小端） | src/include/varatt.h:169-174（宏 233-242） |
| 2 | 外部指针结构与 16B 寻址字段 | varatt.h:32-39（18B 指针见 detoast.h:31） |
| 3 | va_tag 四取值，ONDISK=18 兼容旧格式 | varatt.h:89-95（注释 84-88） |
| 4 | va_extinfo = 30 位大小 + 2 位压缩法 | varatt.h:49-50（外部压缩判定 543-548） |
| 5 | 压缩内联头 va_tcinfo | varatt.h:138-144；toast_internals.h:23-46 |
| 6 | 触发阈值 TOAST_TUPLE_THRESHOLD=2032B | heaptoast.h:46-50；heapam.c:2259-2266 |
| 7 | 分片 1996B 推导（每页 4 条） | heaptoast.h:80-89；toasting.c:239-251 |
| 8 | toast 表 (chunk_id,chunk_seq) 唯一 btree | toasting.c:317-369（341, 349, 356-357） |
| 9 | 分片写入循环 | toast_internals.c:283-349（301, 306-314） |
| 10 | 四轮压缩/外置策略 | heaptoast.c:159-271 |
| 11 | 压缩净省 2 字节门槛 + pglz/lz4 分派 | toast_internals.c:81-97（64-76 选法 57-59） |
| 12 | 默认压缩：编译进 lz4 即默认 lz4 | toast_compression.h:56-62；GUC guc_parameters.dat:783-787 |
| 13 | detoast 三入口（全量/仅外部/slice） | detoast.c:116, 44, 204；fmgr 包装 fmgr.c:1797-1836 |
| 14 | slice：未压取片、pglz 估算、lz4 整取 | detoast.c:232-234, 254-256, 249-252 |
| 15 | 取片换算 chunk 范围 | heaptoast.c:626 起（652-654） |
| 16 | 索引不含 toast 指针（TOAST_INDEX_HACK） | indextuple.c:29-30, 110-135 |
| 17 | VACUUM 先主表后 toast 递归、FULL 例外 | vacuum.c:2291-2302, 2379-2392（FULL 2297-2299） |
| 18 | bootstrap 建 toast：BKI + 原地写 pg_class | bootparse.y:382-392；toasting.c:389-408 |
