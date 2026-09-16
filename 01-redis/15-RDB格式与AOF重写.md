# 第 15 章 · RDB 格式与 AOF 重写:持久化的二进制契约

> 基线:commit `e8726d1`。行号以 src/rdb.c、src/rdb.h、src/aof.c 为准。卷一 06 章讲了持久化概览(fork+COW/Multi-Part AOF)——本章深入**二进制格式与重写内部**。

## 15.0 全景:RDB 文件的字节布局

```
rdbSaveRio(src/rdb.c:1459-1497):
REDIS%04d(9B magic,v12 rdb.h:21)
  → AUX 字段(redis-ver/bits/ctime/used-mem/repl-*/aof-base :1263-1284)
  → 模块 AUX+函数库段
  → 逐 db(SELECTDB 0xFE+RESIZEDB 0xFB+逐键)
  → EOF 0xFF → 8B CRC64(小端,v5+ 才校验 :3677-3692)
每键:[EXPIRETIME_MS 0xFC+8B][IDLE 0xF8][FREQ 0xF9] 前缀 + TYPE(1B) + key + value
  (rdbSaveKeyValuePair src/rdb.c:1195-1235)
```

varlen 长度编码(rdb.h:23-41):首字节高 2 位分 6/14/32/64 位/特殊编码。

## 15.1 类型编码:字符串的三级降级

rdbSaveRawString(src/rdb.c:440-470):≤11 字节纯数字→**int 内联 2/3/5 字节**(rdbEncodeInteger :251);rdb_compression 且 >20B→**LZF**(0xC3 头+压缩长+原始长+数据 :337-360,须省 4 字节否则回退);否则 [len][data]。double 文本式:1B 长度前缀,253=NaN/254=+inf/255=-inf(:602);二进制式:IEEE754 8B 强制小端(:650-653)。

**类型映射**(rdbSaveObjectType :677-722):listpack/set 统一存整块或伪装单节点 quicklist;skiplist zset **从尾(最小分)逆序写出**,加载 O(N)(:929-944);hash 有 HFE 时用 type 24/25。RDB type 0-25 完整表(rdb.h:55-98)是**磁盘契约**:版本兼容的锚点。

## 15.2 AOF 重写:遍历内存生成最小命令

rewriteAppendOnlyFileRio(src/aof.c:2387-2488):读**内存**遍历生成最小命令:SET/RPUSH/SADD/ZADD 变长批插,每命令最多 64 元素(server.h:136 AOF_REWRITE_ITEMS_PER_CMD),过期键发 PEXPIREAT。fork 前:flush 缓冲+openNewIncrAofForAppend 切新 INCR 文件——增量零丢失(:2589-2596);子进程写 temp-rewriteaof-bg-\<pid\>.aof(:2620);**COW 减负**:子进程边写边 dismissObject 归还内存(:2456,object.c:773);COW 大小经 sendChildCowInfo 上报(rdb.c:1660,aof.c:2624)。fsync 三策略(flushAppendOnlyFile :1146-1354):always 当场 fdatasync、失败即 exit;everysec BIO 线程每秒 fsync、fsync 卡住时 flush 推迟至多 2 秒;no 只 write。

## 15.3 Multi-Part AOF:base+incr+history

manifest 三类文件 b/h/i(aof.c:47-70;server.h:1707-1731);**重写完成五步**:新 base 名→旧 base 转 history→rename→incr 转 history→persist manifest(临时文件+rename)→后台删 history(backgroundRewriteDoneHandler,aof.c:2734-2848);启动加载顺序 base→incr,截断仅容忍最后一个文件(loadAppendOnlyFiles :1773-1896);AOF 开启时 RDB 不独立加载(server.c:7047-7049);**aof-use-rdb-preamble 默认 yes**:base 直接是完整 RDB(:2520-2525),加载端靠 "REDIS" magic 分流(:1527,:1541)。

## 15.4 设计动机

1. **为什么 RDB 用 fork+COW 而非在线序列化**:RDB 是**全量快照**——fork 后子进程看到一致的内存视图,不需要锁;代价是 COW 的瞬时内存峰值(与卷一 06 章呼应);
2. **为什么 AOF 重写也要 fork**:AOF 是"命令日志"——重写=把命令日志压缩成"当前状态的最小命令集",必须读一致视图;
3. **LZF 的取舍**:压缩比低但 CPU 极低(对照 zstd 的压缩率);>20B 且省 4B 才压缩——**阈值即策略**;
4. **RDB preamble 默认 yes**:base 文件直接是 RDB(加载最快);INCR 增量是命令——**两种格式的优势互补**。

## 15.5 FAQ

**Q1:RDB 的 CRC64 什么时候校验?**
v5+ 才有 CRC(:3677-3692);加载时校验,旧文件跳过。

**Q2:LZF 压缩比大概多少?**
(:337-360):须省 4B 才写;压缩头 0xC3+双长度——典型 2-3× 压缩。

**Q3:zset 从尾逆序写出为什么?**
(:929-944):skiplist 的 rank 计算从 tail 更高效,逆序写使加载直接建 skiplist。

**Q4:AOF 的 everysec 到底丢多少?**
(:1146-1354):最多丢 ~1s( BIO 线程的 fsync 周期);fsync 卡住时推迟至多 2s。

**Q5:RDB preamble 是什么?**
(:2520-2525):AOF 的 base 文件就是完整 RDB——加载先走 RDB 路径再重放 INCR 命令。

**Q6:Multi-Part AOF 的三类文件命名?**
b(h)=base,h=incr,h(istory)=历史(aof.c:47-70):manifest 是"目录"。

**Q7:AOF 重写的 COW 峰值怎么控制?**
dismissObject(:2456)主动归还子进程内存+COW 大小上报(rdb.c:1660)。

**Q8:RDB 的 AUX 字段有什么?**
(:1263-1284):redis-ver/bits(64 位标志)/ctime/used-mem/repl-id/reploffset——元数据的自描述。

**Q9:AOF 的三种 fsync 策略选哪个?**
always(零丢失但慢)/everysec(默认,~1s 窗口)/no(OS 决定)——业务对丢失容忍度决定。

**Q10:截断容忍为什么只限最后一个文件?**
(:1773-1896):中间文件截断=前面的也坏了——只有"最后写入的"才可能是"部分写"。

## 15.6 小结与深挖方向

本章结论:**RDB="字节级格式契约+三级字符串降级+fork+COW 一致视图";AOF 重写="内存遍历→最小命令+Multi-Part 编排"**。深挖:

1. varlen 编码(:23-41)的 6/14/32/64 位边界与实际数据分布;
2. LZF 的压缩质量 vs zstd(如换 zstd 的 RDB 体积收益);
3. Multi-Part AOF 的 manifest 原子性(:2734-2848)在断电的恢复完备性;
4. aof-use-rdb-preamble 在大 RDB preamble 的加载时间;
5. RDB type 24/25(HFE hash)的编码与卷一 08 章 ebuckets 的序列化联动。

> Redis 深读扩展卷完——gossip 协议/Sentinel 选举/RDB 格式/AOF 重写全部闭合。
