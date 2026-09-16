# N 章：RDB 二进制格式与 AOF 重写内部（Redis 8.x）

> 源码版本：Redis unstable 分支，commit `e8726d1`（e8726d18e5bab24cbfcb0a0c36f21ce5a1140471）。
> 本文所有 `文件:行号` 均为仓库相对路径，已逐一 grep/Read 核对。
> 呼应卷一 06 章（持久化概览：fork+COW、Multi-Part AOF）；本章深入字节格式与重写内部实现。

---

## 1. 全景：RDB 文件的字节布局

RDB 当前版本为 v12（`src/rdb.h:21`）。写入入口 `rdbSaveRio()` 按固定顺序产出整个文件（`src/rdb.c:1459-1497`）：

```c
snprintf(magic,sizeof(magic),"REDIS%04d",RDB_VERSION);   /* "REDIS0012" 共 9 字节 */
if (rdbWriteRaw(rdb,magic,9) == -1) goto werr;
if (rdbSaveInfoAuxFields(rdb,rdbflags,rsi) == -1) goto werr;   /* AUX 字段 */
...
for (j = 0; j < server.dbnum; j++) {
    if (rdbSaveDb(rdb, j, rdbflags, &key_counter) == -1) goto werr;
}
if (rdbSaveType(rdb,RDB_OPCODE_EOF) == -1) goto werr;
cksum = rdb->cksum; memrev64ifbe(&cksum);
if (rioWrite(rdb,&cksum,8) == 0) goto werr;              /* 8 字节 CRC64 */
```

字节布局 ASCII 图（自上而下为文件顺序）：

```
+--------------------------------------------------------------+
| "REDIS" + 4 位版本号            9B    rdb.c:1467-1468         |  例: REDIS0012
+--------------------------------------------------------------+
| AUX 字段若干（每条 = 0xFA + len+key + len+value）rdb.c:1263   |  redis-ver / redis-bits /
|                                                              |  ctime / used-mem /
|                                                              |  repl-stream-db / repl-id /
|                                                              |  repl-offset / aof-base
+--------------------------------------------------------------+
| MODULE_AUX (0xF7) 段（模块 aux_before）  rdb.c:1470           |
| FUNCTION2 (0xF5) 函数库段               rdb.c:1473           |
+--------------------------------------------------------------+
| 每个非空 db 重复（rdbSaveDb, rdb.c:1372-1449）:               |
|   SELECTDB(0xFE) + varlen dbid          rdb.c:1385-1388      |
|   RESIZEDB(0xFB) + varlen size + varlen expires_size          |
|                                         rdb.c:1391-1397      |
|   [cluster] SLOT_INFO(0xF4)+3×varlen    rdb.c:1405-1414      |
|   逐键: [EXPIRETIME_MS(0xFC)+8B ms]     rdb.c:1200-1203      |
|         [IDLE(0xF8)+varlen]  [FREQ(0xF9)+1B]                  |
|              rdb.c:1206-1223 (仅 LRU/LFU 策略开启时)          |
|         TYPE(1B) + key(string) + value rdb.c:1226-1228       |
+--------------------------------------------------------------+
| MODULE_AUX 段（模块 aux_after）          rdb.c:1482           |
+--------------------------------------------------------------+
| EOF 操作码 0xFF（1B）                   rdb.c:1485           |
+--------------------------------------------------------------+
| CRC64 校验和（8B，小端）                rdb.c:1489-1491      |
+--------------------------------------------------------------+
```

关键事实：

- **键级前缀操作码是"修饰下一个键"的**：EXPIRETIME_MS/IDLE/FREQ 必须紧邻其后那个键，加载端把它们暂存到局部变量，键落地后复位（`src/rdb.c:3366,3377-3402,3672-3674`）。
- **RESIZEDB 只是 hint**：加载端用它预扩哈希表避免 rehash（`src/rdb.c:3418-3426`）。
- **CRC64 从文件头开始滚动计算**：`rdb->update_cksum = rioGenericUpdateChecksum`（`src/rdb.c:1465-1466`）；加载端只有 `rdbver >= 5` 才校验（`src/rdb.c:3677-3692`），校验和为 0 表示保存时关闭了校验、跳过检查。
- **落盘是"临时文件+rename 原子替换"**：`temp-<pid>.rdb` → fsync → `rename()`（`src/rdb.c:1605,1566,1614`）；可选增量 fsync/页缓存回收（`src/rdb.c:1553-1556,1567`）。

### 1.1 变长整数（varlen）编码：一切长度的地基

RDB 中所有"长度/数量"共用一套 1~9 字节前缀编码，靠首字节最高 2 位区分（`src/rdb.h:23-41`）：

| 首字节高 2 位 | 含义 | 字节数 |
|---|---|---|
| `00` | 6 位长度 | 1 |
| `01` | 14 位长度 | 2 |
| `10` `0x80` | 32 位长度（网络序） | 5 |
| `10` `0x81` | 64 位长度（网络序） | 9 |
| `11` | 特殊编码对象（见 §2.2） | - |

写入见 `rdbSaveLen()`（`src/rdb.c:157-188`），读取见 `rdbLoadLenByRef()`（`src/rdb.c:200-234`）。绝大多数键名/短值只需 1 字节长度头——这是 RDB 省空间的第一道关卡。

---

## 2. RDB 类型编码专节

### 2.1 RDB type 值总表

`rdbSaveType/rdbLoadType` 读写 1 字节（`src/rdb.c:101-112`）。类型值是**磁盘契约**，与内存 OBJ_* 无关（`src/rdb.h:52-54`）。对象类型 0-7、9-25（`src/rdb.h:55-80`），操作码挤在 244-255（`src/rdb.h:87-98`）：

| RDB type | 含义 | 编码方式 |
|---|---|---|
| 0 | STRING | 一个 string（可 int 内联/LZF） |
| 1 | LIST（旧版） | ziplist 串 |
| 2 | SET（哈希表） | 元素数 + 逐元素 string |
| 3 | ZSET（旧版） | score 为文本 double |
| 4 | HASH（哈希表，无 HFE） | field 数 + field/value 对 |
| 5 | ZSET_2 | score 为 IEEE754 二进制 |
| 6/7 | MODULE（旧 RC / 现行） | 模块自带编解码 |
| 9/13 | HASH_ZIPMAP / HASH_ZIPLIST | 历史遗留，只读 |
| 10/12 | LIST_ZIPLIST / ZSET_ZIPLIST | 历史遗留，只读 |
| 11 | SET_INTSET | intset 整块原样存储 |
| 14/18 | LIST_QUICKLIST / _2 | quicklist 节点数+逐节点 |
| 15/19/21 | STREAM_LISTPACKS 1/2/3 | rax+listpack+PEL/消费者组 |
| 16 | HASH_LISTPACK | listpack 整块 |
| 17 | ZSET_LISTPACK | listpack 整块 |
| 20 | SET_LISTPACK | listpack 整块 |
| 24/25 | HASH_METADATA / HASH_LISTPACK_EX | 带 hash field TTL（HFE）的 7.4+ 格式 |

操作码：0xF4 SLOT_INFO、0xF5 FUNCTION2、0xF7 MODULE_AUX、0xF8 IDLE、0xF9 FREQ、0xFA AUX、0xFB RESIZEDB、0xFC EXPIRETIME_MS、0xFD EXPIRETIME（秒，旧）、0xFE SELECTDB、0xFF EOF（`src/rdb.h:87-98`）。

`rdbSaveObjectType()` 把内存对象映射到 RDB type（`src/rdb.c:677-722`）：

- LIST：quicklist 或 listpack 编码**统一写成** `RDB_TYPE_LIST_QUICKLIST_2`（`src/rdb.c:682-683`）——listpack 会被伪装成"单节点 quicklist"落盘（`src/rdb.c:866-875`），加载端无需区分。
- SET：intset→11、哈希表→2、listpack→20（`src/rdb.c:687-692`）。
- ZSET：listpack→17，skiplist→ZSET_2(5)（`src/rdb.c:695-699`）。
- HASH：listpack→16、带字段 TTL 的 listpack→25、无 HFE 哈希表→4、有 HFE 哈希表→24（`src/rdb.c:703-711`）。
- STREAM→21、MODULE→7（`src/rdb.c:715,717`）。

### 2.2 字符串：len+data、int 内联与 LZF

`rdbSaveRawString()` 是一切字符串落盘的总闸（`src/rdb.c:440-470`），三级降级策略：

```c
/* Try integer encoding */
if (len <= 11) {                                  /* rdb.c:445 */
    if ((enclen = rdbTryIntegerEncoding((char*)s,len,buf)) > 0) { ... }
}
/* Try LZF compression */
if (server.rdb_compression && len > 20) {         /* rdb.c:455 */
    n = rdbSaveLzfStringObject(rdb,s,len);
    ...
}
/* Store verbatim */
if ((n = rdbSaveLen(rdb,len)) == -1) return -1;   /* rdb.c:463 */
```

**int 内联**：长度 ≤11 且文本可解析为整数时，首字节 `11|000000` 标记特殊编码，随后按值域选 INT8/16/32，整串压到 2/3/5 字节（`rdbEncodeInteger`，`src/rdb.c:251-271`；编码判定 `rdbTryIntegerEncoding`，`src/rdb.c:328`；读取 `rdbLoadIntegerObject`，`src/rdb.c:276+`）。`rdbSaveStringObject()` 对已是 `OBJ_ENCODING_INT` 的对象直接走这条路，免去解码再编码（`src/rdb.c:492-501`）。

**LZF 压缩**：`rdb_compression` 开启（默认 yes）且长度 >20 字节才尝试（`src/rdb.c:455`）；lzf 要求至少省 4 字节且实际压出更小的结果，否则放弃转原样存储（`src/rdb.c:366-374`）。LZF blob 布局（`rdbSaveLzfBlob`，`src/rdb.c:337-360`）：

```
[0xC3]            1B   (RDB_ENCVAL<<6)|RDB_ENC_LZF, rdb.h:41,50
[compressed_len]  varlen
[original_len]    varlen
[data]            compressed_len 字节
```

加载端读回两个长度，分配目标缓冲后 `lzf_decompress`，解压结果长度不符即报 corrupt（`src/rdb.c:393-421`）。

原样存储即 `[varlen len][data]`；`rdbGenericLoadStringObject` 按	flags 返回 robj/sds/plain/hfield 四种形态（`src/rdb.c:518-584`，flags 定义 `src/rdb.h:109-114`）。

### 2.3 浮点：文本与二进制两条路

- **文本式** `rdbSaveDoubleValue()`：1 字节长度前缀 + 字符串；特殊值直接用长度字节表达——253=NaN、254=+inf、255=-inf（`src/rdb.c:594-625`）。整数可安全表示时走整型打印加速（`src/rdb.c:614-616`）。
- **二进制式** `rdbSaveBinaryDoubleValue()`：RDB v8+ 用于 ZSET_2 score 等，IEEE754 binary64 **8 字节原样 + memrev64ifbe 强制小端**（`src/rdb.c:650-653`）；float 同理 4 字节（`src/rdb.c:664-667`）。过期时间戳同样固定小端 8 字节（`src/rdb.c:125-129`；v9 之前有大小端 bug，读取端按版本兼容，`src/rdb.c:131-152`）。

### 2.4 复合类型落盘形态（rdbSaveObject，`src/rdb.c:835+`）

- LIST(quicklist)：节点数 + 逐节点 [container 标记][节点数据]，压缩节点复用 LZF blob（`src/rdb.c:844-865`）。
- SET(哈希表)：元素数 + 逐元素 string（`src/rdb.c:881-902`）；intset/listpack 编码则整块内存原样写出（`src/rdb.c:903-911`）。
- ZSET(skiplist)：成员数 + 逐对 [member][8B 二进制 score]，且**从尾部（最小分）向头部遍历写出**，使加载时插入恒命中表头、O(N) 建表（`src/rdb.c:922-944`）。
- HASH(哈希表)：field 数 + 逐对 field/value；带 HFE 时先写最小过期时间（`src/rdb.c:951-1010` 一带，LISTPACK 分支 953 起、HT 分支 970 起）。
- STREAM：listpack 块的 rax + 消费组/PEL 结构（`rdbSaveStreamPEL`，`src/rdb.c:740-779`；`rdbSaveStreamConsumers`，`src/rdb.c:784+`）。

---

## 3. AOF 重写专节

### 3.1 rewriteAppendOnlyFileRio：遍历内存生成最小命令集

AOF 重写**读的是内存数据，不是任何旧文件**。子进程遍历每个 db 的每个键，把当前值翻译成"能重建该值的最短命令序列"（`src/aof.c:2387-2488`）：

```c
for (j = 0; j < server.dbnum; j++) {
    char selectcmd[] = "*2\r\n$6\r\nSELECT\r\n";        /* aof.c:2404 */
    ...
    while((de = kvstoreIteratorNext(kvs_it)) != NULL) {
        ...
        if (o->type == OBJ_STRING) {
            char cmd[]="*3\r\n$3\r\nSET\r\n";           /* aof.c:2431 */
            ...
        } else if (o->type == OBJ_LIST)  { rewriteListObject(...); }        /* aof.c:2437 */
        else if (o->type == OBJ_SET)   { rewriteSetObject(...); }           /* aof.c:2439 */
        else if (o->type == OBJ_ZSET)  { rewriteSortedSetObject(...); }     /* aof.c:2441 */
        else if (o->type == OBJ_HASH)  { rewriteHashObject(...); }          /* aof.c:2443 */
        else if (o->type == OBJ_STREAM){ rewriteStreamObject(...); }        /* aof.c:2445 */
        ...
        if (expiretime != -1) { /* PEXPIREAT key ts */ }                    /* aof.c:2459-2464 */
    }
}
```

命令生成规则：

- LIST 用 `RPUSH key v1 v2 ...`，SET 用 `SADD`，ZSET 用 `ZADD`，均**变长参数批插**，但每条命令最多 `AOF_REWRITE_ITEMS_PER_CMD=64` 个元素（`src/server.h:136`；list 实现 `src/aof.c:1918-1956`，set `src/aof.c:1960-1989`，zset `src/aof.c:1993+`）。批内计数归零即另起一条命令。
- 过期键重写为 `PEXPIREAT`（绝对毫秒），而非 PEXPIRE/TTL 相对值（`src/aof.c:2460`）。
- 输出全部是 RESP 内联字面量（如 `"*3\r\n$3\r\nSET\r\n"`），直接写 rio，绕过命令表。
- 子进程内对每个已写键调用 `dismissObject()` 归还内存给 OS，主动**减小 COW 放大**（`src/aof.c:2452-2456`；`src/rdb.c:1426-1430` 同款；实现 `src/object.c:773`）。
- 每约 1024 键/1 秒向父进程回报进度（`src/aof.c:2469-2475`）。
- 可选时间戳注解 `#TS:<unixtime>\r\n`（`src/aof.c:2394-2399,1389-1398`）。

`rioWriteBulkObject` 刻意避免 `getDecodedObject`，int 编码对象直接写 long——减少一次性解码分配，正是为 COW 场景优化（`src/aof.c:1904-1907`）。

### 3.2 rewriteAppendOnlyFile：RDB preamble 与原子落盘

`rewriteAppendOnlyFile()`（`src/aof.c:2497-2558`）是子进程的主函数：

- 写临时文件 `temp-rewriteaof-<pid>.aof`（`src/aof.c:2504`），增量 fsync + 页缓存回收（`src/aof.c:2513-2516,2533`）。
- `aof-use-rdb-preamble` 默认开启（`src/config.c:3104`）时，**整个 base 部分直接是一份完整 RDB**：调 `rdbSaveRio(..., RDBFLAGS_AOF_PREAMBLE, ...)`（`src/aof.c:2520-2525`）；关闭时才走 §3.1 的文本命令路径（`src/aof.c:2527`）。AUX 字段 `aof-base=1` 标记这份 RDB 是 AOF base（`src/rdb.c:1265,1282`）。
- 写完 fsync、`rename()` 原子改名（`src/aof.c:2531-2542`）。

### 3.3 bgrewriteaof：fork+COW 编排

`rewriteAppendOnlyFileBackground()`（`src/aof.c:2577-2645`），注释给出完整五步流程（`src/aof.c:2563-2576`）：

1. 父进程先把 `aof_selected_db` 置 -1（强制下条命令重发 SELECT）、`flushAppendOnlyFile(1)` 强制刷缓冲、`openNewIncrAofForAppend()` 打开新 INCR 文件——**fork 之前**完成，保证 fork 瞬间后的增量一条不丢（`src/aof.c:2589-2596`）。
2. `redisFork(CHILD_TYPE_AOF)` 出子进程，改名 `redis-aof-rewrite`（`src/aof.c:2614-2619`）。
3. 子进程写 `temp-rewriteaof-bg-<pid>.aof`，成功后上报 COW 大小（`sendChildCowInfo(CHILD_INFO_TYPE_AOF_COW_SIZE)`，`src/aof.c:2620-2624`）。
4. 父进程继续服务写命令、追加到新 INCR 文件；两份视角并存：子进程看 fork 时刻的内存快照，父进程产生 fork 之后的增量。

内存放大估算：COW 页数 ∝ **fork 期间父进程被写脏的页**，与数据集总量无关。两个放量因素：(a) fork 后写命令的写入速率×重写时长；(b) 子进程遍历触达页的访存压力（redis hash、KV 惰性对象等引用页会被子进程读、若被父进程写则触发复制）。因此 Redis 用 `dismissObject` 释放子进程侧引用、用 `hasActiveChildProcess()` 让 `aof-no-fsync-on-rewrite` 等配置规避抖动（`src/aof.c:1325-1326`）。手动 `BGREWRITEAOF` 在已有子进程时只置 `aof_rewrite_scheduled` 排队（`src/aof.c:2650-2655`）。

### 3.4 AOF 管道写与 fsync 策略

命令先经 `feedAppendOnlyFile()` 序列化进 `server.aof_buf`（`src/aof.c:1408+`，RESP 编码函数 `catAppendOnlyGenericCommand`，`src/aof.c:1356-1379`），再由 `flushAppendOnlyFile()` 落盘（`src/aof.c:1146-1354`）。三种策略（`src/server.h:617-619`，默认 everysec `src/config.c:3168`）：

- **always**：写后当场 `redis_fsync`（Linux 上是 fdatasync，避免刷元数据），fsync 失败直接 `exit(1)`——契约是"已回复的写必已落盘"（`src/aof.c:1329-1345`）。
- **everysec**：write 常驻主线程；fsync 交给 BIO 线程（`aof_background_fsync`，`src/aof.c:982`，每秒一次，`src/aof.c:1346-1353`）。若上一轮 fsync 未完成，先**推迟 flush 最多 2 秒**，超时则带病写入并计 `aof_delayed_fsync`（`src/aof.c:1185-1204`）。缓冲为空时也会补一次逾期 fsync（`src/aof.c:1161-1177`）。
- **no**：只 write 不主动 fsync，交给 OS（`flushAppendOnlyFile` 的 fsync 段不处理该值）。

短写/写失败处理：`ftruncate` 回滚到最后一致偏移，everysec/no 降级为停止接受写并保留缓冲重试，always 无回旋直接退出（`src/aof.c:1236-1300,1278-1285`）。写入延迟按"pending-fsync / active-child / alone"三态采样（`src/aof.c:1224-1231`）。

---

## 4. Multi-Part AOF 专节：base / incr / history 的编排

7.0 起 AOF 拆为目录内多文件 + 一份 manifest（块注释与示例 `src/aof.c:41-70`）：

```
file appendonly.aof.2.base.rdb seq 2 type b
file appendonly.aof.1.incr.aof seq 1 type h
file appendonly.aof.4.incr.aof seq 4 type i
```

- 三种文件类型 `b/h/i`（`src/aof.c:1707-1711` 的枚举 AOF_FILE_TYPE_BASE/HIST/INCR，实为字符）；命名后缀宏（`src/aof.c:73-78`）。
- manifest 行格式由 `aofInfoFormat()` 生成：`file <名> seq <序号> type <b|i|h> [startoffset .. endoffset]`（`src/aof.c:117-139`）；键名宏（`src/aof.c:81-85`）。
- 内存结构 `aofManifest`：base 至多一个、incr 有序列表（重写进行中/失败后会有多个 incr）、history 列表、当前 base/incr 序号（`src/server.h:1721-1731`）。
- **重写成功的切换序列** `backgroundRewriteDoneHandler()`（`src/aof.c:2734-2848`）：dup 一份临时 manifest → `getNewBaseFileNameAndMarkPreAsHistory`（旧 base 转 history）→ `rename(temp-rewriteaof-bg-*, 新 base 名)`（`src/aof.c:2756-2762`）→ `markRewrittenIncrAofAsHistory`（已消费的 incr 转 history，`src/aof.c:2814`；实现 `src/aof.c:505`）→ `persistAofManifest`（`src/aof.c:2817`）→ `aofDelHistoryFiles` 后台删除（`src/aof.c:2843`；实现 `src/aof.c:681`）。任何一步失败都会 `bg_unlink` 新文件并回滚内存 manifest，保证磁盘上 manifest 所指文件集永远自洽。
- **新 INCR 文件的诞生**：fork 前调 `openNewIncrAofForAppend()`（`src/aof.c:803`），序号 = 当前 incr seq+1，父进程立刻写新文件；旧 incr 保持不动等子进程追赶。
- **manifest 自身的原子性**：写临时文件后 rename（`writeAofManifestFile`，`src/aof.c:538`；`persistAofManifest`，`src/aof.c:611`）。
- **启动加载** `loadAppendOnlyFiles()`（`src/aof.c:1773-1896`）：先算总大小供进度条（`src/aof.c:1809`），按序 load base（`src/aof.c:1822-1844`）再逐个 load incr（`src/aof.c:1847-1879`）；**截断/损坏若发生在非最后一个文件则直接判致命**，最后一个文件才允许 AOF_TRUNC 容忍（`src/aof.c:1836-1839,1870-1873`）。老版本单文件 AOF 会走升级路径 `aofUpgradePrepare`（`src/aof.c:1790-1798,633`）。
- base 文件若是 RDB 格式，`loadSingleAppendOnlyFile()` 读前 5 字节比对 `"REDIS"` magic 即切换到 `rdbLoadRio` 加载（`src/aof.c:1523-1554`）；随后剩余 incr 以文本协议逐条重放，客户端是 `createAOFClient()` 造的 fake client（`src/aof.c:1520,1557+`）。
- **RDB 与 AOF 的启动互斥**：`loadDataFromDisk()` 里 `aof_state == AOF_ON` 只走 AOF 加载分支，否则才 `rdbLoad()`（`src/server.c:7047-7049` 一带）。RDB 从不与 AOF 并列加载——RDB 只以 base/preamble 形态被 AOF 体系吸收。

---

## 5. 设计动机

**为什么 RDB 用 fork+COW 而非在线序列化？**
在线序列化要面对"序列化过程中数据在被修改"的两难：要么加全局读锁冻结写入，要么为一致性做逐对象版本协调，两者代价都不可接受。fork 以一次页表复制（微秒~毫秒级）换来一个对整个数据集的**原子时间点快照**：子进程看到的内存永远一致，父进程零阻塞继续服务。代价从"与数据集大小成正比的停顿"变成"与**写入量**成正比的 COW 内存"——对写多场景这是可预算的放大，配合 `dismissObject`（子进程主动归还引用页，`src/object.c:773`；调用点 `src/rdb.c:1430`、`src/aof.c:2456`）与 COW 上报机制（`src/rdb.c:1660`、`src/aof.c:2624`）可观测、可缓解。`temp-<pid>.rdb` + rename 保证磁盘上要么是旧完整文件、要么是新完整文件（`src/rdb.c:1605,1614`）。

**为什么 AOF 重写也要 fork？**
重写语义是"以某个时间点的数据集为基准生成最小命令集"。若在主线程做，遍历数 GB 键空间期间所有写请求排队；若在事件循环碎片化地做，基准时间点模糊、增量衔接复杂。fork 让"基准"天然成立（子进程内存即 fork 瞬间状态），父进程只需在 fork 前切好新 INCR 文件（`src/aof.c:2589-2596`），之后的增量一条不落地进新文件，最终 base(=快照)+incr(=fork 后增量) 拼出完整历史。重写期间增量持续产生，这正是 Multi-Part 里"重写进行中可能有多个 INCR"的来源（`src/aof.c:52-57`）。

**为什么重写产物默认是 RDB preamble？**
同样的数据集，文本命令序列（RPUSH/SADD 逐元素）通常远大于紧凑二进制 RDB；RDB 还有 LZF、int 内联、listpack 整块落盘等压缩手段。加载端 RDB 解析是纯结构重建，比逐条文本命令经命令表分发快得多。于是 base 取 RDB 之快（`src/aof.c:2520-2525`），incr 取文本命令之实时，二者经 `"REDIS"` magic 无歧义拼接（`src/aof.c:1527`）。代价是丢失"人类可读"，redis-check-aof 仍可校验。

**LZF 的取舍**
LZF 是"压缩极快、解压极快、压缩率一般"的算法，选它是因为 RDB 的瓶颈常在 CPU/延迟而非磁盘体积。策略上极度保守：全局开关 `rdb_compression`、>20 字节才尝试（`src/rdb.c:455`）、压完必须至少省 4 字节且确实变小（`src/rdb.c:366-374`），失败即回退原样存储——保证最坏情况只多花一次试压的 CPU。作用域是**单个字符串/quicklist 节点**（`src/rdb.c:857-858`），而非整文件，因此读取端可按节点粒度解压、不必整体扫描。

---

## 6. FAQ 素材

1. **RDB 文件开头 9 字节是什么？** `"REDIS" + 4 位版本号`，如 `REDIS0012`（`src/rdb.c:1467-1468`，版本上限 `src/rdb.h:21`）。加载端据此校验并取版本号做兼容分支（`src/rdb.c:3353-3363`）。
2. **RDB 怎么做到"短字符串几乎不浪费空间"？** 三层：varlen 首字节高 2 位复用（≤63 的长度只占 1 字节）、≤11 字节纯数字串内联为 2/3/5 字节整数（`src/rdb.c:445,251-271`）、LZF 压缩（`src/rdb.c:455`）。
3. **RDB type 值会随 Redis 版本变化吗？** 是磁盘契约，只增不改。旧编码（zipmap/ziplist 等 9/10/12/13）只保留读取不写出；7.4 的 hash field TTL 引入 24/25（`src/rdb.h:55-80`）。
4. **ZSET 的 score 在 RDB 里是字符串还是二进制？** 旧 type 3 是文本 double，现行 skiplist 编码（type 5/ZSET_2）是 8 字节 IEEE754 小端（`src/rdb.c:650-653,943`）。
5. **AOF 重写期间的新写入会丢吗？** 不会。fork 前 `openNewIncrAofForAppend` 已切到新 INCR 文件，父进程边服务边追加；子进程只负责 fork 时刻的快照（`src/aof.c:2589-2596,2614+`）。
6. **重写产物到底是 AOF 还是 RDB？** base 默认是 RDB 格式（aof-use-rdb-preamble 默认 yes，`src/config.c:3104`），加载端看前 5 字节 magic 自动分流（`src/aof.c:1527,1541`）。
7. **AOF 里 redis-check / 截断恢复怎么界定？** Multi-Part 下只有**最后一个**文件允许截断容忍，中间文件损坏直接判致命（`src/aof.c:1836-1839,1870-1873`）。
8. **everysec 到底丢多少？** 主线程 write 后数据在页缓存；fsync 由 BIO 线程每秒一次。fsync 卡住时 flush 最多推迟 2 秒，超时强制写入（可能丢这 2 秒内未 fsync 的数据），并计 `aof_delayed_fsync`（`src/aof.c:1185-1204`）。
9. **always 策略为何写失败就自杀？** 契约是"回复客户端成功=已落盘"；输出缓冲已发出去无法回滚，只能 exit 保语义（`src/aof.c:1278-1285`）。
10. **RDB 保存时 LRU/LFU 信息会丢吗？** 不丢。按淘汰策略附带 IDLE（秒粒度 varlen）/FREQ（1 字节对数计数器）操作码（`src/rdb.c:1206-1223`），加载端 `objectSetLRUOrLFU` 还原（`src/rdb.c:3656`）。

## 深挖素材

1. **COW 大小如何被量化上报**：子进程周期性 `sendChildCowInfo`，父进程在 INFO 里呈现 `mem_aof_rewrite_dataset`/COW 指标；`sendChildInfo` 每秒/每 1024 键同步进度（`src/rdb.c:1435-1441`、`src/aof.c:2469-2475`、`src/rdb.c:1660`、`src/aof.c:2624`）。
2. **dismiss 机制**：子进程边序列化边释放键引用内存，令 OS 提前回收"父进程已不再共享"的页，实测可显著压低 fork 子进程峰值 RSS（`src/object.c:773`；`src/rdb.c:1426-1430`）。
3. **ZSET 逆序序列化优化**：从 skiplist 尾（最小分）写起，加载端插入恒在表头 O(1)，把重建从 O(N logN) 降到 O(N)（`src/rdb.c:929-944` 注释）。
4. **manifest 的崩溃一致性设计**：先 rename 数据文件、后 persist manifest；失败时 `bg_unlink` 新文件 + 内存回滚，任何瞬间磁盘状态都可被旧 manifest 完整解释（`src/aof.c:2752-2833`）。
5. **端序兼容的历史包袱**：过期时间戳在 RDB v9 前未做 memrev64ifbe，大端机存的文件换端读会全错；读取端按 `rdbver >= 9` 分支兼容旧文件（`src/rdb.c:131-152`）——磁盘格式的"只增不改"原则被迫打补丁的典型案例。

---

## 写作要点速查表

| 主题 | 函数/宏 | 位置 |
|---|---|---|
| RDB 版本 12 | `RDB_VERSION` | src/rdb.h:21 |
| varlen 编码注释/宏 | `RDB_6BITLEN` 等 | src/rdb.h:23-41 |
| 特殊编码宏 | `RDB_ENC_INT8/16/32/LZF` | src/rdb.h:47-50 |
| 类型与操作码总表 | `RDB_TYPE_*` / `RDB_OPCODE_*` | src/rdb.h:55-98 |
| varlen 写/读 | `rdbSaveLen` / `rdbLoadLenByRef` | src/rdb.c:157 / 200 |
| int 内联 2/3/5B | `rdbEncodeInteger` | src/rdb.c:251 |
| 字符串三级降级 | `rdbSaveRawString` | src/rdb.c:440 |
| LZF blob 布局 | `rdbSaveLzfBlob` | src/rdb.c:337 |
| double 文本/二进制 | `rdbSaveDoubleValue` / `rdbSaveBinaryDoubleValue` | src/rdb.c:602 / 650 |
| 对象→RDB type 映射 | `rdbSaveObjectType` | src/rdb.c:677 |
| 键级操作码（EXP/IDLE/FREQ） | `rdbSaveKeyValuePair` | src/rdb.c:1195 |
| db 级编排（SELECT/RESIZE/SLOT） | `rdbSaveDb` | src/rdb.c:1372 |
| 文件整体布局（magic→EOF+CRC） | `rdbSaveRio` | src/rdb.c:1459 |
| CRC 校验（v5+） | `rdbLoadRioWithLoadingCtx` 尾部 | src/rdb.c:3677-3692 |
| 后台保存 fork | `rdbSaveBackground` | src/rdb.c:1643 |
| 变长批插上限 64 | `AOF_REWRITE_ITEMS_PER_CMD` | src/server.h:136 |
| fsync 三策略宏 | `AOF_FSYNC_NO/ALWAYS/EVERYSEC` | src/server.h:617-619 |
| manifest 结构 | `aofManifest` / `aof_file_type` | src/server.h:1721 / 1707 |
| 重写遍历与命令生成 | `rewriteAppendOnlyFileRio` | src/aof.c:2387 |
| RPUSH/SADD 变长批插 | `rewriteListObject` / `rewriteSetObject` | src/aof.c:1918 / 1960 |
| RDB preamble 开关 | `aof-use-rdb-preamble` 默认 1 | src/config.c:3104 |
| 重写子进程主函数 | `rewriteAppendOnlyFile` | src/aof.c:2497 |
| bgrewriteaof fork 编排 | `rewriteAppendOnlyFileBackground` | src/aof.c:2577 |
| 重写完成切换 | `backgroundRewriteDoneHandler` | src/aof.c:2734 |
| AOF 缓冲写+fsync 策略 | `flushAppendOnlyFile` | src/aof.c:1146 |
| Multi-Part 启动加载 | `loadAppendOnlyFiles` | src/aof.c:1773 |
| RDB-preamble 识别（magic） | `loadSingleAppendOnlyFile` | src/aof.c:1527,1541 |
| COW 减负 | `dismissObject` | src/object.c:773 |
| 启动 RDB/AOF 互斥 | `loadDataFromDisk` | src/server.c:7047-7049 |
