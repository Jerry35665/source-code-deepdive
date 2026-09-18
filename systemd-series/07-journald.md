# 第 07 章 · journald:二进制日志的写入与索引(卷二)

> 基线:commit `1f66b524`。核心:src/journal/(守护进程)与 src/libsystemd/sd-journal/journal-file.c(文件格式)。命名提示:本基线 journald-server.c 已更名为 journald-manager.c。

## 7.0 全景:journal 文件布局与一条日志的旅程

```
journal 文件 = Header(272B,"LPKSHHRH")+ 两张 hash 表 + 对象 arena(追加写)
  对象七种:DATA(字段值)/FIELD(字段名)/ENTRY/ENTRY_ARRAY/TAG/HASH_TABLE…
  一切互指只用 le64_t 文件偏移;data 对象三链交叉:data hash 表(值索引)
  + next_field_offset(同名值链)+ entry_offset/entry_array(倒排:哪些条目含我)
一条日志:socket(syslog/native/audit/kmsg/stdout)→manager_process_datagram
  →限速→可信字段注入(_UID/_PID/_COMM…,下划线字段入口即拒收客户端伪造)
  →journal_file_append_entry(查重/压缩/三处索引挂接)→/run 或 /var 分文件
```

## 7.1 格式要点:追加写 + COMPACT + keyed-hash

对象头统一 type/flags/size;追加写引擎只有二十几行(journal_file_append_object,journal-file.c:1250-1297)——写入永不移动旧数据,断电损坏面收敛到文件尾部,mmap 零反序列化读取。**COMPACT 模式默认开**:条目引用从 16B 压到 4B le32(索引空间近乎减半),代价是单文件 4GiB 上限,做成 per-file incompatible flag 让老读程序明确拒开。**keyed-hash 默认开**:字段 hash 用以 file_id 为密钥的 siphash24,防碰撞攻击;cursor 所需的 xor_hash 刻意用无密钥 Jenkins——保证游标跨文件轮转一致。压缩 per-object 尽力而为(≥512B 才压,默认 zstd,失败原文直存);小字段永远原样存——值索引才能直接 memcmp。

## 7.2 可信字段:下划线是信任边界

字段名校验:非空、≤64 字符、仅 `[A-Z0-9_]`,且客户端通道**下划线开头一律拒收**(journal-file.c:1746-1782)。可信字段由 journald 自己生成:身份来自 socket 凭证 SCM_CREDENTIALS+/proc 采集(`_PID/_UID/_COMM/_EXE/_CMDLINE/_SYSTEMD_UNIT`);**条目时间取 journald 处理时刻而非发送方时钟**(journald-manager.c:1192-1196)——保证按时间二分在数学上成立,发送方时钟降级存 `_SOURCE_REALTIME_TIMESTAMP=`。`OBJECT_PID=`(代客记账)只收 root。

## 7.3 限速与轮转

限速按 unit 分组(上限 2047 组)×5 个优先级池(EMERG~CRIT 一池保住 ERR 可见性),默认 30s/10000;**burst 随磁盘剩余空间对数放大**(1MB→×1…1TB→×6);压制必留痕"Suppressed N messages"。轮转五条件:结构落后/hash 表填充>75%/链深>100(防碰撞攻击)/索引异常/最老条目超时;另有时间倒跳立即轮转(条目时间必须单调,二分才成立)。vacuum 只删归档、活跃文件永不删,三条规则(retention/总量/文件数)。旧 BisectTable 已移除——时间二分改为读侧在 entry-array 链上做(ChainCacheItem 缓存加速)。

## 7.4 设计动机

1. **二进制结构化而非文本**:字段可索引可校验,同值全文件只存一份,能区分"日志自称的"与"journald 查证的";
2. **追加写+偏移指针**:零拷贝读取、读写无锁(先写体后挂链的内存屏障)、崩溃面收敛;
3. **双 hash 表分工**:data 表按值(等值匹配+去重)、field 表按名(取值浏览+Match 展开),一次预留运行期零 rehash;
4. **默认限速**:日志是唯一任何进程都能无差别触发的磁盘写入通道,不限速等于自建 DoS;
5. **/run 永远 seal=false**:密封需要持久密钥;/var 就绪后 flush 搬运(journal_file_copy_entry)。

## 7.5 FAQ

**Q1:journal 文件头多大?签名?**
272 字节,"LPKSHHRH"(journal-def.h:218-219,265)。

**Q2:客户端能伪造 _PID 吗?**
不能:下划线字段入口拒收;可信字段由 journald 从内核凭证与 /proc 生成。

**Q3:条目的时间是日志方的时间吗?**
不是:取 journald 处理时刻(保证单调);发送方时钟存 _SOURCE_REALTIME_TIMESTAMP。

**Q4:为什么条目时间必须单调?**
读侧按时间在 entry-array 链上二分;时间倒跳立即轮转+vacuum。

**Q5:日志洪峰会打垮磁盘吗?**
限速:按 unit 分组、优先级分池、burst 随磁盘余量放大;压制留痕。

**Q6:/run 和 /var 怎么分流?**
/var 未就绪全写 /run(seal=false);就绪后 SIGUSR1 flush 搬运。

**Q7:什么时候轮转?**
结构落后/hash 表 75%/链深 100/索引异常/超时;写入失败也 rotate+vacuum 重试。

**Q8:压缩会压小字段吗?**
不会:≥512B 才压且 per-object;PRIORITY=6 这类永远原样。

**Q9:COMPACT 模式的代价?**
单文件 4GiB 上限(le32 偏移);做成 incompatible flag,老程序拒开而非误读。

**Q10:seal 防什么?**
只防事后篡改(--verify 验 HMAC TAG);不防拦截者整体重放。

## 7.6 小结与深挖方向

本章结论:**journald="追加写 arena+三层交叉索引+可信字段边界+分组限速,崩溃面收敛到文件尾"**。深挖:

1. stdout 捕获的握手状态机与 _LINE_BREAK 断行语义(journald-stream.h:11);
2. hash 链深 100 与 keyed-hash 的碰撞攻击对抗;
3. keep_free/max_use 的默认推导(文件系统 10% 夹在 1MiB-4GiB);
4. fdstore 与 daemon-reload 时 journal fd 的保留;
5. FSS seal 的 FSPRG 密钥演化窗口。
