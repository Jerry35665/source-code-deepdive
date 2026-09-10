# A-页面层与 B-tree(SQLite 3.54.0,commit 492e7fc)

> 调研对象:`src/btree.c`(11655 行)、`src/btree.h`、`src/btreeInt.h`,以及 `src/pager.c` 中与页缓存获取相关的一小节(`pcache.c`/`pcache1.c` 佐证)。所有结论均给出 `文件:行号`,行号以该版本源码为准。

## 1. 子系统全景:btree.c 在 SQLite 分层中的位置

SQLite 的分层是"虚表接口 → VDBE 字节码 → B-tree → Pager → OS 接口(VFS)"。btree.c 处于 VDBE 之下、Pager 之上,是**唯一理解数据库文件字节布局的模块**;pager.c 只把文件看成"编号页面的数组",pcache 负责把这些页面缓存住,而"页面上每个字节是什么"完全是 btree 层的知识。btree.c 开头的注释直言:"This file implements an external (disk-based) database using BTrees",并让读者去看 btreeInt.h 的头注释获取文件格式说明(`src/btree.c:12-14`)。

btreeInt.h 头部给出了 B-tree 的抽象模型:每页含 N 个条目与 N+1 个孩子指针,`Ptr(0) | Key(0) | Ptr(1) | ... | Key(N-1) | Ptr(N)`,查找代价 O(log M) 次页读取(`src/btreeInt.h:19-33`)。同时,key+data 合称 payload,payload 与前置指针合称 Cell(`src/btreeInt.h:36-43`)——这是理解后续一切的起点。

关键数据结构(均在 `src/btreeInt.h`):

- `MemPage`(btreeInt.h:273-304):一页载入内存后的解析视图。前 8 字节(`isInit/intKey/intKeyLeaf/pgno`)由 pager 分配时清零,其余字段懒初始化;内含函数指针 `xCellSize`/`xParseCell`,按页类型在四个解析函数间做"虚分发"(btreeInt.h:302-303)。
- `BtShared`(btreeInt.h:425-460):一个数据库文件一份,持有 Pager、页大小/可用大小、`maxLocal/minLocal/maxLeaf/minLeaf`、游标链表、页面 1 的常驻引用 `pPage1`。
- `BtCursor`(btreeInt.h:531-560):游标持有父页栈 `apPage[BTCURSOR_MAX_DEPTH-1]` 与每层下标 `aiIdx[]`,树最大深度 20 层(btreeInt.h:497),超过即判损坏。游标结构由调用者(VDBE 的 Cursor 对象)预分配,`sqlite3BtreeCursorSize()` 返回字节数(`src/btree.c:4821-4823`)。
- `CellInfo`(btreeInt.h:480-486):一次 cell 解析的产物:`nKey、pPayload、nPayload、nLocal、nSize`。

btree.h 定义的接口分四层(`src/btree.h`):文件/事务层(`sqlite3BtreeOpen/BeginTrans/Commit/GetMeta`,btree.h:45-131);表层(`sqlite3BtreeCreateTable/DropTable/ClearTable`,btree.h:87-126);游标层(`sqlite3BtreeCursor/TableMoveto/IndexMoveto/Next/Previous/Insert/Delete/Payload`,btree.h:241-341);以及少量辅助(完整性检查 `sqlite3BtreeIntegrityCheck`,btree.h:344-353)。表创建标志只有两种:`BTREE_INTKEY`(行id 表)与 `BTREE_BLOBKEY`(索引),btree.h:122-123。

btree 层内部还有一对刻意分离的句柄:`Btree` 是连接私有的薄壳(inTrans、wantToLock 等状态,btreeInt.h:345-363),`BtShared` 才是文件级共享体(pager、页缓存、全部游标链)。非共享缓存模式下每个连接独占一份 BtShared;shared-cache 模式下多个 Btree 指向同一 BtShared,此时所有字段访问都要拿 `BtShared.mutex`(btreeInt.h:400-405),表级读写锁则记录在 `BtShared.pLock` 的 `BtLock` 链表上,用于防止一个连接读表时另一连接写表(btreeInt.h:307-322)。理解这一点对读懂 btree.c 里遍布各处的 `sqlite3BtreeEnter()/Leave()` 非常必要:非共享编译下它们被宏成空操作(btree.h:406-411),因此真正的并发正确性主要由 pager 与 SQLite 的全局连接锁保证。

## 2. 数据库文件格式逐段解读

### 2.1 文件级布局与 100 字节文件头

文件被划分为 512B~65536B(2 的幂)的页,页号从 1 开始,0 表示"不存在"(btreeInt.h:47-51)。页 1 永远是一棵表 B-tree 的根(schema 表 `sqlite_master`),其前 100 字节是文件头(btreeInt.h:53-55)。头格式逐字段记录于 btreeInt.h:57-82:

```
偏移  长度  内容
0     16   "SQLite format 3\0" 魔数(SQLITE_FILE_HEADER,btreeInt.h:249)
16    2    页大小(值 1 表示 65536)
18    1    写版本 / 19:1 读版本(1=rollback,2=WAL)
20    1    每页末尾保留字节数(reserved space)
21    1    max embedded payload fraction(必须 64)
22    1    min embedded payload fraction(必须 32)
23    1    min leaf payload fraction(必须 32)
24    4    file change counter
28    4    数据库页数
32    4    空闲表(freelist)第一个 trunk 页 / 36:空闲页总数
40    60   15 个 4 字节 meta 值(见下)
92    4    version-valid-for / 96:SQLITE_VERSION_NUMBER
```

所有整数大端(btreeInt.h:84)。40 偏移起的 meta 数组在代码里通过 `36 + idx*4` 访问:`sqlite3BtreeGetMeta()` 直接 `get4byte(&pBt->pPage1->aData[36 + idx*4])`(`src/btree.c:10500`),索引常量 `BTREE_FREE_PAGE_COUNT=0 … BTREE_LARGEST_ROOT_PAGE=4 … BTREE_DATA_VERSION=15` 见 btree.h:152-161。两个容易被忽略的文件级事实:其一,每页末尾的保留字节(page1[20])默认为 0,是留给加密扩展等第三方代码的,`sqlite3BtreeSetPageSize()` 的 `nReserve` 参数即控制它,btree 层所有空间计算一律用 `usableSize = pageSize - nReserve` 而非页大小(`src/btree.c:3103-3134`);其二,文件存在一个 1GB 边界上的"锁字节区"(PENDING_BYTE,0x40000000),它落在哪个页、那个页就不得存放数据(`PENDING_BYTE_PAGE`,btreeInt.h:612;页大小必须是 2 的幂的原因正在于让锁字节恰好顶在页首,btree.c:3092-3095),因此 allocateBtreePage 从文件尾追加页号时会跳过它(6810-6811)。

lockBtree() 是打开文件时的校验入口(`src/btree.c:3312-3489`):比对魔数(3344)、读/写版本号(3356-3361,读版本 2 表示应走 WAL)、校验 21-23 三字节必须是 `\100\040\040`(即 64/32/32,注释明确"自 3.6.0 起固定",3389-3396)。页大小读取写得非常巧妙:`pageSize = (page1[16]<<8) | (page1[17]<<16)`(3401)——大端两字节,但值 1 会经 `<<16` 变成 65536,一举两得。保留字节得到 usableSize=pageSize-page1[20](3418),且可用大小不得低于 480(3446)。若发现实际页大小与 BtShared 假设不同,则解锁、记录后返回,由调用方用正确页大小重试(3419-3434)。

与 payload 分数配套的四个本地负载阈值在 lockBtree() 末尾计算(3471-3479):

```c
pBt->maxLocal = (u16)((pBt->usableSize-12)*64/255 - 23);
pBt->minLocal = (u16)((pBt->usableSize-12)*32/255 - 23);
pBt->maxLeaf  = (u16)(pBt->usableSize - 35);
pBt->minLeaf  = (u16)((pBt->usableSize-12)*32/255 - 23);
```

注释解释了 -23 的来历:预留 2 字节 cell 指针 + 4 字节孩子指针 + 9 字节 nKey + 4 字节 nData,保证一页至少能装下 4 个 cell(3458-3470)。对 4096 页面:maxLocal≈990、minLocal≈483、maxLeaf=4061。空库初始化由 newDatabase() 完成,写魔数、页大小、64/32/32,并把页 1 建成 `PTF_INTKEY|PTF_LEAFDATA|PTF_LEAF` 的空叶子(`src/btree.c:3540-3577`)。

### 2.2 页内布局

每一页分三段:页头、cell 指针数组、cell 内容区;页 1 另有前置的 100 字节文件头。btreeInt.h:110-124 的原图:

```
+---------------------------+ 0
| 文件头 100B(仅页 1)      |
+---------------------------+ 0 或 100
| 页头 8B(叶)/12B(内)      |  偏移0:类型flags;1-2:首个freeblock;
|                           |  3-4:cell数;5-6:cell内容区起点;
|                           |  7:碎片字节总数;8-11:最右孩子(仅内页)
+---------------------------+
| cell 指针数组             |  每 cell 2 字节,按 key 升序,向下增长
|---------------------------|
| 未分配空间(gap)          |
|---------------------------|
| freeblock 链 + 碎片       |
|---------------------------|  ^
| cell 内容区               |  |  自页尾向上增长,无序
+---------------------------+ usableSize
```

页头格式逐字段的规范描述在 btreeInt.h:128-134;类型字节只有 4 种合法组合(btree.c:2048-2053):`0x02`(索引内页)、`0x05`(表内页)、`0x0A`(索引叶)、`0x0D`(表叶),由 `decodeFlags()` 解析并安装对应的 `xCellSize/xParseCell` 函数指针与 min/maxLocal 参数(`src/btree.c:2055-2112`)。PTF 常量(INTKEY/LEAFDATA/ZERODATA/LEAF)定义在 btreeInt.h:256-259。

页内自由空间管理有三个实体(btreeInt.h:152-159):

1. **未分配区**(`gap` 与 `top` 之间):cell 指针数组的尾部到 cell 内容区起点之间,新 cell 优先从这里切出;
2. **freeblock**:≥4 字节的空洞,按地址升序串成单链表,节点头 4 字节 = 下一 freeblock 偏移(2B)+ 本块大小(2B)(btreeInt.h:161-164);
3. **fragment**:1~3 字节进不了链表的小空洞,总数记在页头偏移 7 的一个字节里,上限 60。

分配路径 `allocateSpace()`(`src/btree.c:1846-1930`)顺序是:若 freeblock 非空且 gap 与 top 之间还放得下 2 字节新指针,先调用 `pageFindSlot()`(1774-1831)在链表里找 ≥nByte 的洞——若余量 x<4 就把 x 计入碎片(上限检查 `aData[hdr+7]>57` 时放弃该洞,1795-1803,保证不超 60);否则若 `gap+2+nByte>top` 就先 `defragmentPage()` 整页整理(1909-1916),最后从 top 下切(1925-1929)。`defragmentPage()`(1640-1758)有两条路径:页上 ≤2 个 freeblock 且碎片不超限时用 memmove 平移(1674-1710),否则把 cell 逐一 memcpy 到临时页再从页尾压实重排(1712-1744)。65536 页大小有个经典边角:cell 内容区起点的 2 字节存不下 65536,用 0 代替,`get2byteNotZero` 宏(54)与 allocateSpace 中的特判(1873-1874)处理此事。

释放路径 `freeSpace()`(`src/btree.c:1945-2041`)做双向合并:先按地址序找到插入点,与后继 freeblock 合并(1990-1999)、与前驱合并(2005-2013),顺带修正碎片计数;若释放的块正好顶着 cell 内容区起点,则直接扩大未分配区而不新建 freeblock(2024-2031)。secure_delete 模式下先把内容清零(2019-2023)。

### 2.3 页与 pager 的握手

btree 层不直接碰磁盘,每页都是 `sqlite3PagerGet()` 拿到的 `DbPage`。`btreeGetPage()`(`src/btree.c:2362-2377`)包装之;`getAndInitPage()`(2409-2443)再确保 `MemPage.isInit`,懒初始化失败会释放引用。MemPage 挂在 pager 的 extra 区域:`btreePageFromDbPage()`(2338-2349)只在页号变化时重设 aData/pgno/hdrOffset。pager 回滚导致页内容被还原时,回调 `pageReinit()` 清掉 isInit 强制重解析(2512-2529)。页 1 特殊:它由 `BtShared.pPage1` 常驻持有,释放必须走 `releasePageOne()→sqlite3PagerUnrefPageOne()`,因为 pgno==1 的最后一笔引用决定读锁的释放(2449-2472;pager.c:5842-5869)。

### 2.4 页缓存获取(pager.c 一瞥)

`sqlite3PagerGet()` 只是分发到 `pPager->xGet`(`src/pager.c:5788-5808`),常规路径是 `getPageNormal()`(pager.c:5597-5699):先 `sqlite3PcacheFetch(cache, pgno, 3)` 查缓存,未中则 `FetchStress` 尝试淘汰脏页腾位,最后 `FetchFinish` 初始化 PgHdr(pager.c:5614-5624)。若缓存里已有初始化好的页(命中)直接返回并计数(5630-5635);否则两种情况不需要读盘——页号超出 dbSize 或带 `PAGER_GET_NOCONTENT` 标志,此时整页 memset 0(5652-5678),NOCONTENT 语义在注释里写明是"读 free-list 叶页"与"回滚 savepoint 装页"两个场景(5569-5584);其余情况 `readDbPage()` 真读盘(5682)。mmap 启用时有 `getPageMMap` 快路径(5703+)。

下层 pcache 的关键语义:`sqlite3PcacheFetch()` 的 createFlag 只取 0 或 3,内部换算成 eCreate:0=不许分配,1=开销小时才分配(脏页存在时),2=尽量分配(`src/pcache.c:403-441`);分配紧张时 `sqlite3PcacheFetchStress()` 会先 spill 脏页再要页(pcache.c:445-490)。默认缓存实现 pcache1 用开放寻址哈希 + LRU,五步策略写在 pcache1Fetch 的注释里(pcache1.c:1000-1052),其第 3 步在缓存接近满(90% 或 pinned 超 mxPinned)且 createFlag==1 时直接放弃(876-897),第 4 步从全组 LRU 尾回收页(901-912)。每页分配是单块内存:`szAlloc = szPage + szExtra + ROUND8(sizeof(PgHdr1))`(pcache1.c:793),页数据与 PgHdr/MemPage 一起分配,这正是 btree 层能从 `sqlite3PagerGetExtra()` 拿到 MemPage 的物质基础(pager.c:7367-7376)。

## 3. 表 B-tree 与索引 B-tree 的单元(cell)格式差异

四种页面对应四种 cell 解析函数(btree.c:1261-1263 注释):`btreeParseCellPtrNoPayload`(表内页,1269)、`btreeParseCellPtr`(表叶,1286)、`btreeParseCellPtrIndex`(索引页通用,1374);另有四个 `xCellSize` 实现(cellSizePtr 索引内页 1435、cellSizePtrIdxLeaf 索引叶 1477、cellSizePtrNoPayload 表内页 1519、cellSizePtrTableLeaf 表叶 1540)。

```
表叶(0x0D)                表内页(0x05)            索引内页(0x02)         索引叶(0x0A)
+------------------+       +---------------+        +---------------+     +---------------+
| var  payload长度  |       | 4  左孩子页号  |        | 4  左孩子页号  |     | var payload长度|
| var  rowid(key)  |       | var 该子树最大 |        | var payload长度|     | payload(完整  |
| payload(记录)    |       |      rowid    |        | payload(记录) |     |       记录)   |
| 4    首溢出页(可选)|       +---------------+        | 4  首溢出页(可选)|    | 4  首溢出页(可选)|
+------------------+                                +---------------+     +---------------+
```

差异的本质有三点:

1. **key 的存储方式**。表 B-tree 的 key 是 64 位整数 rowid,直接编码进 cell 头而不占 payload(btreeInt.h:193-194:"Number of bytes of key. Or the key itself if intkey flag is set");解析函数 `btreeParseCellPtr` 对 key 的 varint 做了完全展开的手工解码(含 9 字节符号修正 `iKey = (iKey<<8) ^ 0x8000 ^ (*++pIter)`,`src/btree.c:1325-1354`)。索引 B-tree 的 key 就是整个 payload(记录),`btreeParseCellPtrIndex` 里 `pInfo->nKey = nPayload`(1395)——nKey 字段语义从"键值"降格为"负载长度"。
2. **内页是否有负载**。表 B-tree 内容只在叶子,内页 cell 只有"左孩子指针 + 分割 rowid"(`btreeParseCellPtrNoPayload`,nPayload 恒 0,btree.c:1280-1283);索引 B-tree 的内页与叶子 cell 格式相同(都是负载型),所以分割 key(整条记录)会真实复制进父页。这也是为什么 balance 时表树只需拼叶子内容,索引树还需要把 divider cell 从父页摘下再插回(CellArray 注释,btree.c:7651-7660)。
3. **本地负载阈值不同**。表叶用 `maxLeaf/minLeaf`(可用 100% 页面),索引页用 `maxLocal/minLocal`(为 4 个 cell 留余量),decodeFlags 里按类型分别赋值(btree.c:2070-2078, 2094-2102)。

溢出判据是所有格式共享的(btreeParseCellAdjustSizeForOverflow,btree.c:1205-1234):

```c
surplus = minLocal + (nPayload - minLocal) % (usableSize - 4);
if( surplus <= maxLocal ){ nLocal = surplus; } else { nLocal = minLocal; }
nSize = &pPayload[nLocal] - pCell + 4;   /* +4 是末尾的溢出页号 */
```

动机:溢出链最后一页可能只有 1 字节数据,该公式让尾页尽量填满(余数交给尾页),同时本地部分不越过 minLocal~maxLocal 区间。`cellSizePtrTableLeaf`(表叶版 xCellSize,1540-1590)甚至故意向前"多读几个 varint 字节"以跳过 rowid 才能算出精确尺寸——这是表叶 cell 尺寸计算的独特复杂度。上限哨兵:`MX_CELL_SIZE = pageSize-8`、`MX_CELL = (pageSize-8)/6`(最小 cell 6 字节假设,btreeInt.h:222-229),btreeInitPage 里 `nCell>MX_CELL` 即判损坏(`src/btree.c:2277-2280`)。

溢出页本体是"4 字节下一页号 + usableSize-4 字节数据"的单链表(btreeInt.h:202-204),填充在 `fillInCell()`(`src/btree.c:7106-7289`)中完成:本地段写完后循环分配溢出页、`put4byte(pPrior, pgnoOvfl)` 把前驱的"下一页号"填上(7278-7284)。auto_vacuum 下溢出页分配会避开 ptrmap 页并写 PTRMAP_OVERFLOW1/OVERFLOW2 条目(7236-7262)。读回路径 `accessPayload()`(5155-5430)维护游标级缓存 `BtCursor.aOverflow[]`——每溢出页一项、惰性填充(5214-5258),配合 `SQLITE_DIRECT_OVERFLOW_READ` 甚至能绕过页缓存直读。

最后补一个贯穿两种树的对账表,便于速查:

| 维度 | 表 B-tree(intkey) | 索引 B-tree(index) |
| --- | --- | --- |
| 页类型字节 | 0x05 内页 / 0x0D 叶页 | 0x02 内页 / 0x0A 叶页 |
| key | rowid 内嵌于 cell 头 | 整条记录即 key(payload) |
| 内页 cell | 4B 左孩子 + 分割 rowid,无 payload | 4B 左孩子 + 完整记录 |
| 叶页本地负载阈值 | maxLeaf(≈整页)/minLeaf | maxLocal/minLocal(留 4 cell 余量) |
| 查找入口 | sqlite3BtreeTableMoveto(5837) | sqlite3BtreeIndexMoveto(6068) |
| 比较方式 | 64 位整数比较 varint | KeyInfo 定制的记录比较器 |
| balance 特化 | balance_quick 顺序追加可行 | 无 quick 路径(intKeyLeaf 不成立) |

其中"balance_quick 只属于表树"可以从代码直接看出:触发条件第一项就是 `pPage->intKeyLeaf`(btree.c:9217),索引树内页/叶子都会携带完整记录,追加语义无从谈起。

## 4. 一次查找/插入/删除在 btree.c 内的完整路径

### 4.1 游标与定位

打开游标 `btreeCursor()`(4719-4785)只填结构、挂入 BtShared 游标链表,`iPage=-1、eState=CURSOR_INVALID`,不读任何页;读游标将 `curPagerFlags=PAGER_GET_READONLY`(4782),让后续所有 getAndInitPage 以只读方式取页。

移动到根 `moveToRoot()`(5586-5663):若游标本来就在同一棵树上(`iPage>=0`),直接释放深层引用复用 `apPage[0]` 作根(5597-5605)——这是"同表连续查找不重复走根"的关键;否则从 `pgnoRoot` getAndInitPage。空的根页若不是页 1 则整树为空,返回 SQLITE_EMPTY(5658-5660);页 1 空根且有唯一孩子时下移一层,即"虚拟根"(5652-5657)。

下探/回退原语:`moveToChild()`(5486-5513)把当前页与下标压入 `apPage/aiIdx` 栈再取孩子,同时校验孩子的 `intKey` 与父一致且非空(5504-5507);`moveToParent()`(5545-5563)弹栈;`moveToLeftmost()`(5672-5685)沿"cell 的左孩子指针"一路下到叶;`moveToRightmost()`(5697-5714)沿页头最右孩子指针下探并停在 `ix=nCell-1`。

### 4.2 查找

`sqlite3BtreeTableMoveto()`(5837-5978)是 intkey 表的二分查找。三个快捷短路先行:游标已停在同一 key 上(5853-5857);已停在 AtLast 且目标更大(5858-5863);目标 key 恰为当前 key+1 时改用一次 `sqlite3BtreeNext()` 试探(5864-5879)。主体是双重循环:页内二分(`idx=(lwr+upr)>>1`,5953),intkey 叶直接跳过 payload 长度 varint 读 rowid 比较(5924-5931);未命中时按 `lwr` 位置取左孩子页号下探——`lwr>=nCell` 时取页头最右指针(5964-5969),命中且在内页时从命中 cell 的左孩子继续(5941-5943)。结果编码:*pRes<0/0/>0 表示游标落在小于/等于/大于目标的位置。

`sqlite3BtreeIndexMoveto()`(6068-6299)对索引树多两件事:一是开头两个基于"游标在树最右页"的短路(6104-6127)——若当前 cell 就是全树最后且 ≥ 目标,或当前页首 cell ≤ 目标,直接在当前页开搜(`bypass_moveto_root`),避免回根;二是比较器走 `sqlite3VdbeFindCompare`(6085),并有一个著名的局部优化 `indexCellCompare`(5996-6026):负载全部本地且首字节 varint ≤ max1bytePayload 时直接比较,否则返回 99("未知")迫使走慢路径——慢路径对溢出 cell 要 malloc 缓冲并用 accessPayload 拼出完整记录再比较(6202-6229)。循环体内对 moveToChild 做了手工内联(6266-6293)。

翻页:`sqlite3BtreeNext()`(6416-6434)把常见情形(叶页内 ix+1)压到几条指令,跨页情形交给 SQLITE_NOINLINE 的 btreeNext(6362-6415):内页右溢则沿最右指针 moveToLeftmost;叶尾则 moveToParent 循环向上找第一个 ix<nCell 的祖先,表树还要再递归 Next 以跳过只含分割 key 的祖先层(6404-6405)。Previous 对称(6456-6522),区别在于祖先回退后直接沿 `findCell` 的左孩子 moveToRightmost。游标被写操作"甩出"后进入 `CURSOR_REQUIRESEEK`,保存 `(pKey,nKey)` 待 restoreCursorPosition 重新 seek(saveCursorPosition 766-868)。

**读到数据**是另一条独立的路径:定位完成后,`getCellInfo()`(4895 起)把当前 cell 解析进 `pCur->info`,`sqlite3BtreeIntegerKey/PayloadSize` 直接读 info;批量内容走 `sqlite3BtreePayload()`(5377)→ `accessPayload()`(5155):先从 `info.pPayload` 拷贝本地段(5194-5205),不足部分沿溢出链逐页 `usableSize-4` 字节续拷(5208-5293);`fetchPayload()`(5433-5455)则是零拷贝快路径,直接把页内 payload 指针交出去,调用方保证在下次任何 btree 调用前用完——这是 VDBE 大多数读行的实际通道。

### 4.3 插入

`sqlite3BtreeInsert()`(9441-9742)流程:

1. 同表多游标时先 saveAllCursors 保存他人位置(9470-9481);
2. 定位:表树用 `BTCF_ValidNKey` 快捷判断"当前就是要覆盖的行",同长同载直接走 `btreeOverwriteCell()` 原地覆写(9529-9539);否则 TableMoveto(BTREE_APPEND 时 biasRight 偏向右,9545-9547)。索引树在 loc==0 时补一次 IndexMoveto(9562-9576);
3. 构造 cell:`fillInCell()` 把内容写进 `pBt->pTmpSpace`(9613, 9633),按需挂溢出链;
4. 落页:loc==0 时 clearCell 旧 cell;新旧同尺寸且无溢出时直接 memcpy 覆写返回(9657-9678,注释解释实验证明"变小后回收余量"并不更快);否则 dropCell + `insertCellFast()`(9688;7460-7540)。insertCellFast 从 allocateSpace 切空间、memmove 挤出 cell 指针数组空位、nCell++;若页内空间不足则**不落页**,把 cell 暂存在 `MemPage.apOvfl[4]` 的溢出槽里(7478-7488),页本身保持不变;
5. 只要 `pPage->nOverflow>0` 就调用 `balance(pCur)`(9712-9715),随后游标置 INVALID。注释特意说明:保持游标停在最后位置,能让 `INSERT ... SELECT` 或自增主键的顺序追加无需重新 seek(9703-9711)——配合 BTREE_APPEND 偏右定位,这就是顺序写快的机制级原因。

### 4.4 平衡的触发与再平衡策略

`balance()`(9162-9291)是一个自叶向根的 do-while 循环,每轮判定当前页:

- 无溢出 cell 且空闲空间不足 2/3(`nFree*3 <= usableSize*2`)→ 不需要平衡,退出(9175-9180)。注意:**没有"半满"下限**,SQLite 不要求页至少半满,只要不足 2/3 空闲就不动;
- 当前是根且有溢出 cell → `balance_deeper()`(9181-9198):分配新页、把根内容整体复制下去,根变内页只留一个右孩子(9081-9126)——这是唯一的"加层"操作;
- 否则:左侧/右侧快速平衡或全量重排。`balance_quick()`(8039-8133)只在四个条件同时成立时触发:表叶子、恰好 1 个溢出 cell 且位置在末尾、父页非页 1、该页是父页最右孩子(9217-9222)——即"顺序追加"场景:直接新建一个右兄弟页容纳溢出 cell,再在父页追加一个以最大 rowid 为 key 的 divider(8100-8126)。其余情形走 `balance_nonroot()`;
- 每轮结束上移一层(`pCur->iPage--`),父页可能因此超载,循环继续向上(9277-9283)。

`balance_nonroot()`(8277-9080)是重头戏:取当前页加左右各 NN=1 个兄弟(NB=3,btree.c:7551-7552,注释明确"NB 自诞生就是 3,从未测过其他值"),把父页上对应 divider 一并摘下,全部 cell 倒进一个 `CellArray`(7617-7632),然后**重新均匀装箱**:先按可用空间(`usableSpace = usableSize-12+leafCorrection`,8572)贪婪左偏装箱(8582-8620),再自右向左回调把右偏修正(8626-8656,注释说明这一步是"必要而非优化",右页可能被装成空页)。之后:能复用的旧页复用,不足则 allocateBtreePage 补新页(8697-8722);**把新页按页号排序**,用 `sqlite3PagerRekey` 交换缓存中的页身份,让磁盘上相邻的兄弟页页号连续以保持扫描局部性——注释称该优化使大批量插入删除快约 25%(8724-8738);最后把新 divider 插回父页(8885-8946)、按"先左后右/先右后左"的安全次序用 editPage 重写各兄弟页(8953-9037);若父页是根且清空了,再把唯一孩子拷回根,树高减一("balance-shallower",8970-8996)。还有一处稳健性细节:根页带溢出 cell 时若存在另一个游标也停在同一页上,balance 直接报损坏而不是继续重排——注释举的场景是损坏库里两张 SQL 表共用同一棵 b-tree,触发器在另一张表上的二次插入会从正在平衡的页面下把内容抽走(9128-9150)。

### 4.5 删除

`sqlite3BtreeDelete()`(9873-10073):

1. 内页删除不做"合并两孩子"这种复杂操作,而是把游标移到**前驱**(子树最大 entry),用叶子 cell 替换内页 cell(9948-9959;9988-10015),之后统一按"叶子上少了一个 cell"继续;
2. clearCell 释放溢出链(clearCellOverflow 逐页 freePage2,7011-7077)、dropCell 把 cell 从页上摘除并 freeSpace 回收(9977-9981);
3. 触发 balance 的条件与插入同源:空闲 > 2/3 才调用(10034-10040);若删除发生在内页、平衡叶后游标深度仍高于内页深度,再回到 iCellDepth 补一次 balance(10041-10049);
4. `BTREE_SAVEPOSITION` 标志下,预计会触发重平衡时先 saveCursorKey 置 CURSOR_REQUIRESEEK,否则置 CURSOR_SKIPNEXT 让 Next/Previous 变 no-op(9916-9946, 10051-10062)。

空闲页与分配页的供给端:`allocateBtreePage()`(6546-6854)优先从 freelist 取——文件头偏移 32 是首个 trunk 页号、36 是空闲页总数(6565-6567);trunk 页结构"下一 trunk 页号 + leaf 数 + leaf 页号数组"(btreeInt.h:211-214)。取页时按 nearby 参数在 leaf 数组里挑最近页号(6725-6749);BTALLOC_EXACT/LE 模式(auto_vacuum 增量整理用)会借助 ptrmap 确认目标页确在 freelist 上再整链搜索(6583-6596)。freelist 空则从文件尾追加,若新页号撞上 ptrmap 页或 pending-byte 页则跳过(6810-6830)。auto_vacuum 的 ptrmap 是每 usableSize/5+1 个数据页配一张指针映射页(ptrmapPageno,1063-1075),每项 5 字节"类型(1B)+父页号(4B)",类型五种(btreeInt.h:664-668);btreeCreateTable 依 meta[4](最大根页号)为新表保留低位页号,必要时 relocatePage 挪走占位页(10086-10217)。独立文件里页号 2 即首个用户表根页(`assert((pBt->openFlags & BTREE_SINGLE)==0 || pgnoRoot==2)`,10227)。

## 5. 设计动机与取舍

1. **页即解析缓存**。MemPage 的解析结果挂在 pager extra 区随页缓存存活,isInit 惰性计算、pageReinit 失效(2248-2295, 2512-2529),把"格式解析"成本摊到缓存生命周期里。
2. **双 B-tree 而非单格式**:intkey 树让 `WHERE rowid=?` 无需解码记录、无需 memcmp,二分只看 varint;索引树内页带完整记录,代价是 divider 变大,换来的是无需 sibling 指针即可范围扫描。两者共用同一套页管理,只在 decodeFlags 处分叉(2055-2112)。
3. **无最小占用约束 + 2/3 空闲阈值**:简化平衡逻辑(删除后不强制合并),牺牲空间密度换写放大可控(9175-9180)。真正的"平衡"只在溢出或超 2/3 空闲时发生。
4. **溢出页让 cell 尺寸有上界**:单 cell 本地部分 ≤ maxLocal(表叶 ≤ 页大小),保证 balance_nonroot 的 CellArray 装箱在常量个页内可完成(NB=3),避免任何 O(记录大小) 的边界情况。
5. **写时暂存溢出 cell(apOvfl)**:插入先试探落页,放不下先记账不搬数据,等 balance 统一重排——避免"放不下就立刻 defragment"的抖动(7460-7540)。
6. **页号重排优化局部性**:balance 后兄弟页页号升序,使磁盘扫描接近顺序读(8724-8738)。
7. **5 字节 ptrmap 换 auto_vacuum O(1) 挪页**:空闲页回收/文件收缩需要"谁指向我"的反向索引,SQLite 用密集的 5 字节/页数组而非每页试探,代价是 auto_vacuum 库多了约 0.2% 页数且 B-tree 页不能是 ptrmap 页(1063-1075, 6814-6830)。
8. **游标零拷贝**:游标只有页指针栈与下标栈,不复制 key/data;任何写都可能使位置失效,于是有 CURSOR_REQUIRESEEK/SKIPNEXT 状态机与 saveAllCursors(btreeInt.h:519-529;9470-9481)。saveAllCursors 的实现还体现了一个典型的"快路径先行"风格:先线性扫一遍游标链看有没有需要保存的(816-826),真的需要才走 NOINLINE 的慢函数(833-847),平时栈帧零开销。这是"游标轻量但脆弱"的取舍。

9. **二分查找里到处是"用历史位置作弊"**:表树的 ValidNKey/AtLast/key+1 短路(5853-5881)、索引树的两个"最后一页"短路(6104-6127)、moveToRoot 复用 apPage[0](5597-5605),加上 Insert 刻意把游标留在最后位置(9703-9711),共同构成"顺序扫描/顺序写几乎零寻道"的机制。SQLite 的 B-tree 层把大量精力花在"避免从根开始"上,而不是优化单次从根下探本身。

10. **防御式编程的密度**:任何对页内字段的读取几乎都伴随损坏检查(如 freeSpace 的六处 CORRUPT 判断,1945-2040;delete 前检查 pCell 是否落在 aCellIdx 之后,9912-9914),错误一律定位到页号(`SQLITE_CORRUPT_PGNO`)。btree 层同时是数据库格式的第一道免疫系统——`PRAGMA integrity_check` 复用的正是同一批检查函数。

## 6. 容易误解的点与面试级 FAQ

**Q1:SQLite 的 B-tree 页至少要半满吗?**
不是。btree.c 中不存在任何"最小占用"强制;balance() 的触发条件是"有溢出 cell 或空闲超过 2/3"(9175-9180)。删除后页可以长期保持很空,直到某次插入/删除恰好路过才被重排。传统的 B-tree"至少半满/2/3 满"不变量在这里被有意放弃了。

**Q2:大记录为什么会从 minLocal+余数处开始截断,而不是从 maxLocal 处?**
`surplus = minLocal + (nPayload-minLocal)%(usableSize-4)`(1225)。目的是让溢出链的**尾页尽量满**(余数落在尾页,尾页满格 usableSize-4),同时保证本地部分在 [minLocal, maxLocal] 内;若 surplus 超过 maxLocal 则退回 minLocal。若一律取 maxLocal,尾页平均只剩一半数据,空间浪费更明显。

**Q3:内页 cell 的 key 对表树和索引树分别是什么?**
表树内页 cell = "4 字节左孩子 + 最大 rowid 的 varint"(`btreeParseCellPtrNoPayload`,1280);索引树内页 cell = "4 字节左孩子 + 完整记录"(与叶子同构,1374-1412)。所以表树的父页极小、索引树的父页承载真实数据副本。

**Q4:freeblock 链上为什么没有 1~3 字节的洞?它们去哪了?**
freeblock 头本身要 4 字节,小于 4 字节的空洞挂不上链,被记为 fragment,总数存页头偏移 7(上限 60,btreeInt.h:156-159;pageFindSlot 中超过 57 就拒绝再吃 1~3 字节余量,1797)。碎片太多意味着该 defragment 了。

**Q5:cell 内容区为什么从页尾向页头增长,指针数组却从页头向页尾增长?**
两端相向增长让"加 cell"通常无需移动任何已有 cell:指针数组向下扩一格、内容区 top 上移即可(btreeInt.h:145-150;allocateSpace 1909-1929)。只有两者相遇(gap+2+nByte>top)才触发整页整理。

**Q6:删除内页条目时怎么处理它下面的两棵子树?**
SQLite 不做子树合并:先 `sqlite3BtreePrevious()` 找到左子树里的前驱叶子 cell,把它提升到内页填补空洞(9955-9959, 9988-10015),然后只需对叶子(可能欠满)做常规 balance。选前驱而非后继是因为前驱一定在待删 cell 的左孩子子树内,平衡更简单。

**Q7:cursor 的 eState 有哪些?REQUIRESEEK 是什么?**
CURSOR_INVALID/VALID/SKIPNEXT/REQUIRESEEK/FAULT(btreeInt.h:574-599)。REQUIRESEEK 表示"表被并发修改、原位置已失效",游标保存了 `(pKey,nKey)`,下次使用时 restoreCursorPosition 重新 seek(766-868);SKIPNEXT 则表示下一次 Next/Previous 应被吞掉(skipNext 正负区分方向),用于删除后停在"逻辑上仍指原位"。保存动作本身值得一看:`saveCursorKey()`(724-757)对表树只存一个 rowid(`pCur->nKey`,零拷贝),对索引树却要把整条 key malloc 出来并多垫 17 字节(注释解释:key 若损坏,restore 时 `sqlite3VdbeRecordUnpack` 可能越读一个 varint 加一个 8 字节值,742-746);`saveCursorPosition()`(766-790)随后释放游标手里全部页引用并置 REQUIRESEEK,而 pinned 游标(增量 blob 句柄)拒绝被保存,直接返回 `SQLITE_CONSTRAINT_PINNED`(773-775)。

**Q8:balance_quick 的触发为什么那么苛刻?**
它只服务顺序追加:表叶 + 单个溢出 cell + 溢出位置在最后 + 父页最右孩子(9217-9222)。此时只需新建右兄弟并追加 divider,完全不动已有页(8039-8133);其他任何形态都要 balance_nonroot 通用装箱。这是把"最常见的写路径"特化到极致的例子。

**Q9:为什么 btreeCursor 不需要malloc?这带来什么约束?**
游标结构由上层(VDBE)按 `sqlite3BtreeCursorSize()` 预分配并 `sqlite3BtreeCursorZero()` 清零前缀(4821-4823, 4852-4854,注释说 apPage/aiIdx 数组刻意不清零省时)。约束是 BtCursor 是借来的内存:btree 层绝不越权扩展它,所有"缓存"(aOverflow、pKey)单独 malloc 并在 close 时释放(4878-4881)。

**Q10:65536 页大小有什么特殊处理?**
两个 2 字节字段无法表达 65536:页大小字段用值 1 表示,读取时 `(page1[16]<<8)|(page1[17]<<16)`(3401);空页的"cell 内容区起点"字段用 0 表示 65536,由 get2byteNotZero 与 allocateSpace 特判(54, 1873-1874)。

**Q11:auto_vacuum 为什么需要 ptrmap?没有它不能收缩文件吗?**
收缩要修改"父→子"指针并可能搬移页,relocatePage 必须找到指向被搬页的所有引用(3974+)。B-tree 里孩子指针在父页,但溢出链、freelist 链的"父"不固定,ptrmap 用每页 5 字节记录"谁指向我"来 O(1) 定位(1063-1175)。非 auto_vacuum 库删页只会丢进 freelist,文件不缩。

**Q12:同一 key 的 UPDATE 为什么可能完全无 I/O 重排?**
Insert 路径上有同尺寸覆写短路:新旧 cell 的 `nSize` 相同、`nLocal==nPayload` 且(非 autovacuum 或无溢出)时直接 memcpy 覆盖旧位置(9657-9678);更进一步,同长同内容走 btreeOverwriteCell 的 memcmp 跳过(9296-9333)。覆写溢出内容时甚至沿溢出链逐页原位覆写(9340-9385)。

## 7. 深挖问题清单

1. **balance_nonroot 的崩溃一致性**:重排涉及父页、2~3 个兄弟页与新页的多页写序,editPage 的"先左后右再回扫"次序(8953-9037)如何与 pager 的 rollback journal 原子性配合?断电后 balance 中途的文件是什么形态,能否恢复?
2. **btreeGetHasContent/Bitvec 与 PAGER_GET_NOCONTENT 的互动**(683-701, 6772, 6806):freelist 取回的页可能位于"文件尾但事务内曾被写"的灰区,何时必须读盘、何时清零即可?增量回滚(incremental vacuum)中 bDoTruncate 的作用?
3. **溢出链读取的游标缓存**:accessPayload 的 aOverflow 数组(5214-5258)在 SAVEPOINT 回滚、`sqlite3BtreeTransferRow` 预格式化写入(9759+)之间如何失效/重建?BTCF_ValidOvfl 的清除点是否完备?
4. **页号重排与 sqlite3PagerRekey**:balance 中临时页号 PENDING_BYTE/pageSize+1 的三步换位(8759-8769)在何种极端序列下会与 pending-byte lock 页冲突?该断言(btsFlags BTS_EXCLUSIVE)如何保证?
5. **fordelete/incremental blob I/O 对页面层的反压**:BTREE_FORDELETE 游标(btree.h:215-239)与 incrblob(11510-11568)如何影响 balance 前的 saveAllCursors 与 clearCellOverflow 的引用检查(7052-7064)?
