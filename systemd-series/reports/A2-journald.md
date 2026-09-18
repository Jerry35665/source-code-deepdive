# A2 · journald：二进制日志的写入与索引

> 系列：《systemd 深读》卷二 ｜ 基线：commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`
>
> 本卷聚焦 src/journal/ 的 journald 守护进程与 journal 文件格式本身；读侧 sd-journal 库（迭代器、mmap-cache、catalog）留给报告 B。
>
> 命名提示：老版本里的 `journald-server.c`/`server_ratelimit` 在本基线已重构为 `src/journal/journald-manager.c` 与 `src/journal/journald-rate-limit.c`；journal 文件格式代码从 src/journal/ 移入了 `src/libsystemd/sd-journal/journal-file.c`（归入 sd-journal 库），rotate/vacuum 的胶水层在 `src/shared/journal-file-util.c`。下文一律按新路径引用，行号均经本基线 Read/Grep 核对。

## 一、磁盘布局：一个 journal 文件长什么样

journal 文件是一块连续的 mmap 区域：头部定长 272 字节（`assert_cc(sizeof(struct Header) == 272)`，src/libsystemd/sd-journal/journal-def.h:265），签名是八个字符 "LPKSHHRH"（journal-def.h:218-219）。

头部之后是唯一的"对象竞技场"（arena，尺寸记在 `arena_size`，journal-def.h:232），所有对象自低地址向高地址逐个追加，8 字节对齐（`ALIGN64`/`VALID64`，src/libsystemd/sd-journal/journal-file.h:145-146）。对象之间不用内存指针，只用 **le64_t 文件偏移**互指——这是 journal 一切索引结构的"指针语言"。

```
0x000000  ┌─────────────────────────────────────┐
          │ Header (272B, "LPKSHHRH")            │
          │  compatible_flags / incompatible_flags│ 压缩/keyed-hash/COMPACT/sealed
          │  file_id / machine_id / seqnum_id    │ machine_id 兼作 keyed-hash 密钥
          │  data_hash_table_offset/size         │ 头部直接记录两张 hash 表位置
          │  field_hash_table_offset/size        │
          │  tail_object_offset / n_objects      │ 追加游标与对象计数
          │  entry_array_offset / n_entries      │ 全局条目链入口与计数
          │  head/tail_entry_seqnum、realtime、   │ 时间二分的端点
          │  monotonic、tail_entry_boot_id       │
          │  n_data/n_fields/n_tags/n_entry_arrays + hash_chain_depth
          ├─────────────────────────────────────┤
header_size│ OBJECT_DATA_HASH_TABLE              │ HashItem{head,tail} × 预留项数
          │ OBJECT_FIELD_HASH_TABLE             │ 固定 1023 项
          ├────────── arena 依次追加 ───────────┤
          │ OBJECT_FIELD  "PRIORITY="           │ 字段名对象, head_data_offset→值链
          │ OBJECT_DATA   "PRIORITY=6"          │ 字段值对象, 三组链指针:
          │   next_hash_offset   → 同值对象链     │  (hash 桶内)
          │   next_field_offset  → 同名字段下一个值 │
          │   entry_offset/entry_array_offset/n_entries → 引用我的条目
          │ OBJECT_ENTRY  seqnum/realtime/       │ journal-def.h:116-133
          │   monotonic/boot_id/xor_hash + items │
          │   regular: [{le64 offset, le64 hash}] 或 compact: [le32 offset]
          │ OBJECT_ENTRY_ARRAY le64[] / le32[]   │ 条目索引链, next_entry_array_offset
          │ OBJECT_TAG    seqnum/epoch/HMAC-256  │ 仅 sealed 文件
          └─────────────────────────────────────┘ tail_object_offset 恒指向末尾
```

对象头是统一三件套 `type/flags/size`（ObjectHeader，journal-def.h:71-78）；type 枚举七种（journal-def.h:50-61），flags 放压缩算法标志 XZ/LZ4/ZSTD（journal-def.h:63-69），读回时由 `COMPRESSION_FROM_OBJECT` 还原成枚举（journal-file.h:328-343）。

头部还有一个单字节 `state`（OFFLINE/ONLINE/ARCHIVED，journal-def.h:177-182）：写者在线时置 ONLINE，关闭/轮转时由离线线程置回 OFFLINE 并在此期间完成 fsync（src/shared/journal-file-util.c:150-308）。这让崩溃后残留的 ONLINE 状态成为"该文件需要 verify"的信号。

## 二、一条日志的旅程：socket → entry → 落盘

```
/dev/kmsg (EPOLLIN) ────┐                        systemd-journald.service 预建 socket:
audit netlink ──────────┤                         /run/systemd/journal/socket   (native)
/dev/log → /run/systemd/│                         /run/systemd/journal/dev-log  (syslog)
  journal/socket (native)┼─► manager_process_datagram (journald-manager.c:1479)
stdout stream 连接 ─────┘     │ recvmsg_safe + SCM_CREDENTIALS/SCM_TIMESTAMP/SCM_SECURITY
                              │ 按 fd 三分: syslog_fd / native_fd / audit_fd (:1583-1613)
        ┌─────────────────────┼───────────────────────────────┐
        ▼                     ▼                               ▼
process_syslog_message  process_native_message         stdout_stream_log
(journald-syslog.c:337) (journald-native.c:307→98)     (journald-stream.c:211)
        └────────── 统一 iovec 字段数组, 进入 manager_dispatch_message ─────────┐
                                                                              ▼
                              级别过滤 + 限速 (manager_dispatch_message, journald-manager.c:1252)
                                                                              ▼
                              manager_dispatch_message_real (:1069): 注入可信字段
                              + 事件循环线性化时间戳 (:1195-1196)
                                                                              ▼
                              manager_write_to_journal (:944): 按 UID 选文件
                              → journal_file_append_entry; 失败/超限则 rotate+vacuum 重试
                                                                              ▼
                              journal-file.c: append_data×N → ENTRY → link_entry
                              → data hash 表 + field 值链 + entry array 三处索引
```

### 2.1 统一入口与各输入的解析

分派核心只有一次 `recvmsg_safe`，凭证与时间戳全部来自辅助数据：

- `SCM_CREDENTIALS`：pid/uid/gid（可信身份的来源）；
- `SCM_TIMESTAMP`：发送方时钟（只作参考，见第六节）；
- `SCM_SECURITY`：SELinux 标签；
- `SCM_RIGHTS`：随消息传 fd 一律拒收。

（收包与解析见 journald-manager.c:1541-1578，按 fd 三分见 :1583-1613。）

四个数据输入各自打 `_TRANSPORT=` 标记：syslog（journald-syslog.c:433）、native（journald-native.c:254）、stdout（journald-stream.c:269）、kernel/dev-kmsg。解析细节：

- **native 协议**（sd_journal_print/sd_journal_sendv 的通道）：`manager_process_entry` 按行解析，`NAME=value` 文本字段直接收（journald-native.c:162-193）；大二进制字段用 8 字节 le64 长度前缀帧（journald-native.c:195-247）。单条上限 `ENTRY_SIZE_MAX`≈770MB、未特权进程 32MB（journal-def.h:12-13），字段数上限 1024（journal-def.h:22，检查在 journald-native.c:148-151）。行首 `.`/`#` 当作控制命令/注释跳过（journald-native.c:140-145）。大消息装不下数据报时改传 fd：`manager_process_native_file` 只认普通文件或已密封 memfd（可直接 mmap 免拷贝），非密封 fd 还要求路径校验通过（journald-native.c:389-438）。
- **syslog 兼容**：`manager_process_syslog_message` 剥 `<pri>`、RFC3164 时间戳与 `tag[pid]:` 前缀（journald-syslog.c:400-413）；凡剥离过空白或含 NUL 的报文，原样补存 `SYSLOG_RAW=`（journald-syslog.c:471-484）。
- **stdout 捕获**：服务的标准输出经 socket 连到 journald，新连接先走握手状态机：identifier → unit_id → priority → level_prefix → 三个 forward 开关（src/journal/journald-stream.h:11-18），逐行消费至 RUNNING 态（`stdout_stream_line`，journald-stream.c:325）；此后每行按断行方式记 `_LINE_BREAK=`：nul/line-max/eof/pid-change（journald-stream.c:286-292），支持二进制日志流。
- **内核 /dev/kmsg**：`dev_kmsg_record` 解析 `<pri>,seq,timestamp,flag;message` 记录（journald-kmsg.c:96-176），用 mmap 的 kernel_seqnum 文件去重并检测丢号（journald-kmsg.c:141-158）；启动早期积压的内核消息由 `manager_flush_dev_kmsg` 一次性灌入（journald-kmsg.c:348）。
- **audit**：netlink 审计报文由 `manager_process_audit_message` 解析成 `_AUDIT_*` 字段（src/journal/journald-audit.c:420）。

### 2.2 与 syslog 的关系：接管 + 四个转发开关

journald 自己监听 /dev/log（经 /run 下 socket 激活），把传统 syslog 报文转成结构化条目入库。

反向"转发"是四个独立配置开关 `ForwardToSyslog/KMsg/Console/Wall`，在 native 处理中逐个判断（journald-native.c:275-285）：

- syslog 转发刻意转发**原始报文**——解析前先拷贝 buffer（journald-syslog.c:371-372、418-419）；
- kmsg 转发会重写 `<pri>` 头，并禁止非内核 facility 冒充内核来源（journald-kmsg.c:31-57）；
- 控制台与 wall 广播分别由 journald-console.c:30、journald-wall.c:12 承担；
- 另有可选的 socket 级转发目标（`manager_forward_socket`，src/journal/journald-socket.c:71）。

默认值：`#Seal=yes`、`#RateLimitIntervalSec=30s`、`#RateLimitBurst=10000`（src/journal/journald.conf.in:20-26）。

### 2.3 控制面：信号、varlink 与自守护

- 轮转/flush/sync 暴露为信号：SIGUSR1=flush to var、SIGUSR2=rotate、SIGRTMIN+1=sync（src/journal/journald-manager.c:1636、1678、1788）；
- 同样三个操作走 varlink 方法 `Synchronize/Rotate/FlushToVar`（src/journal/journald-varlink.c:35、88、110，另有 RelinquishVar :135）；
- journald 对自身的日志防护很自觉：主实例禁止把日志再送回 journald（`log_set_prohibit_ipc(true)`，src/journal/journald.c:52），只能在 console 与 kmsg 间选目标（journald.c:46-56）；
- PID 级 seqnum 跨重启延续靠 mmap 一小文件（`manager_map_seqnum_file`，journald-manager.c:2074）。

## 三、journal 文件格式：Header、对象与 offset 体系

文件由 `journal_file_open` 打开/创建（journal-file.c:4130）。新文件先 `fd_setcrtime` 把创建时间写进 xattr 供 vacuum 判龄（journal-file.c:4228-4233），再写 Header（journal-file.c:390-439）。

Header 的 `incompatible_flags` 记录压缩算法、keyed-hash、COMPACT 等"不兼容"特性——读侧不认识就整文件拒开；`compatible_flags` 记录 sealed 等"可降级"特性（journal-def.h:184-216）。三个写入期选项由环境变量与编译期探测决定：

- **keyed-hash 默认开**：`keyed_hash_requested()` 无环境变量时返回 true（journal-file.c:314-329），此后字段 hash 用以 file_id 为密钥的 siphash24（journal-file.c:1619-1635），防碰撞攻击；
- **COMPACT 默认开**：`compact_mode_requested()` 同样默认 true（journal-file.c:331-346）；
- **压缩算法**默认取编译期 `DEFAULT_COMPRESSION`（zstd，src/basic/compress.h:11），可被 `$SYSTEMD_JOURNAL_COMPRESS=zstd|lz4|xz|0` 覆盖（journal-file.c:349-374）。

创建顺序有讲究：先写头部，再一次性 append 两张 hash 表对象（data 表 journal-file.c:1299-1330、field 表 journal-file.c:1332-1359），之后数据只能追加其后。data hash 表按"每 768B 文件 1 项、填充率不超 75%"用 `metrics.max_size` 估算预留量，下限 2047 项（journal-file.c:1307-1313，常量 :47-48）；field 表因字段名增长缓慢用固定 1023 项（journal-file.c:1340-1343）。hash 表本身也是 arena 里的普通对象，Header 只存其 items 区偏移与尺寸。

**追加写引擎**只有二十几行主干（为展示删去错误处理）：

```c
int journal_file_append_object(JournalFile *f, ObjectType type,
                               uint64_t size, ...) {   /* journal-file.c:1250 */
        r = journal_file_set_online(f);                /* 标记 ONLINE          :1266 */
        r = journal_file_tail_end_by_mmap(f, &p);      /* 追加位置 = tail      :1270 */
        r = journal_file_allocate(f, p, size);         /* posix_fallocate 预分配 :1274 */
        r = journal_file_move_to(f, type, false, p, size, (void**) &o);
        o->object = (ObjectHeader) {
                .type = type,
                .size = htole64(size),
        };                                             /*                      :1282 */
        f->header->tail_object_offset = htole64(p);    /* 推进游标              :1287 */
        f->header->n_objects = htole64(... + 1);
}
```

`journal_file_allocate` 按需扩容：8MB 粒度向上取整（`FILE_SIZE_INCREASE`，journal-file.c:85），受 `metrics.max_size` 与 keep_free 双重约束（journal-file.c:814-837）；COMPACT 模式下新尺寸超 4GiB 直接 -E2BIG——否则 le32 偏移放不下（journal-file.c:817-819，上限常量 `JOURNAL_COMPACT_SIZE_MAX`，journal-file.c:55）。分配要求文件非稀疏、用 posix_fallocate 保证（journal-file.c:780-842）。归档关闭时还会对 entry array 尾部与文件尾 punch hole 归还空间（src/shared/journal-file-util.c:24-148）。读对象统一走 `journal_file_move_to_object`，先验 type 与尺寸再交出 mmap 窗口（journal-file.c:1108）。

**"追加写+双 hash 表+二分表"的分工**：hash 表创建时一次预留，运行期只改 HashItem 与对象内 `next_hash_offset`，绝不移动旧数据——这是崩溃安全（断电最多丢尾部、前缀恒完好）与 mmap 零反序列化读取的前提。至于"BisectTable"：现代格式中它已不存在，对象类型只有七种（journal-def.h:50-61）；时间二分改为读侧对 entry-array 链执行 `generic_array_bisect`（journal-file.c:3032，ChainCacheItem 缓存加速重复定位，journal-file.c:2694-2701），写侧只需保证条目链时间单调（见 7.2 与第六节）。

## 四、字段索引：data 对象如何织成网

一条日志的每个字段 `NAME=value` 各对应一个 DataObject。`journal_file_append_data` 先按内容 hash 查重（journal-file.c:1899-1905），命中即复用——重复的 `PRIORITY=6` 全文件只存一份。未命中才追加对象并做两步挂接：

```c
o->data.hash = htole64(hash);                     /* journal-file.c:1916 */

r = journal_file_link_data(f, o, p, hash);        /* 挂进 data hash 表    :1930 */
...
/* Create field object ... */                     /* 以 '=' 左侧切字段名   :1944 */
r = journal_file_append_field(f, data, (uint8_t*) eq - (uint8_t*) data, &fo, NULL);
o->data.next_field_offset = fo->field.head_data_offset;   /* 头插进值链    :1949-1950 */
fo->field.head_data_offset = htole64(p);
```

`link_data` 定桶直白：`h = hash % m`（m 为表项数），桶内用 HashItem 的 head/tail 加对象自身 `next_hash_offset` 串单向链：

```c
h = hash % m;                                     /* journal-file.c:1485 */
p = le64toh(f->data_hash_table[h].tail_hash_offset);
if (p == 0)
        /* 桶里第一个：只设 head */
        f->data_hash_table[h].head_hash_offset = htole64(offset);
else {
        /* 回移到链尾对象，补上 next 指针 */
        r = journal_file_move_to_object(f, OBJECT_DATA, p, &o);
        o->data.next_hash_offset = htole64(offset);        /*          :1498 */
}
f->data_hash_table[h].tail_hash_offset = htole64(offset);  /*          :1501 */
```

于是同一份字段数据被三层结构交叉索引：

1. **值索引**（data hash 表）：`journalctl PRIORITY=6` 先按完整字段值定位 data 对象；
2. **条目索引**（data 对象内嵌）：`entry_offset` 内联第一条 + `entry_array_offset`/`n_entries` 指向间接数组（journal-def.h:85-87），由 `journal_file_link_entry_item` 反向维护（journal-file.c:2252-2270），从任一字段值可列出所有含它的条目；
3. **名索引**（field hash 表 + FieldObject 值链）：`head_data_offset` 把同名字段所有取值串起来（journal-def.h:104-110），支撑"该字段有哪些取值"的浏览与 Match 展开。

**条目本体**：`journal_file_append_entry`（journal-file.c:2561）对每个 iovec 调 `append_data` 得 {offset, hash} 对，合成 XOR hash（journal-file.c:2640-2652），items 按磁盘偏移排序去重以改善读局部性（journal-file.c:2660-2663）；随后 `journal_file_append_entry_internal` 写 ENTRY：seqnum（跨文件单调，journal-file.c:1224）、realtime/monotonic/boot_id、xor_hash（journal-file.c:2422-2426），最后 `journal_file_link_entry` 挂进全局 entry_array 链并刷新 Header tail 统计（journal-file.c:2292-2309）。

挂链前先 `__atomic_thread_fence(__ATOMIC_SEQ_CST)`——先写对象体、后接索引（journal-file.c:2289），并发读者要么看不到、要么看到完整对象。

**COMPACT 模式**（Header 置 `HEADER_INCOMPATIBLE_COMPACT`，journal-def.h:190）把每个"条目→数据对象"引用从 16 字节（le64 offset + le64 hash）压到 4 字节 le32：

- ENTRY 的 items（journal-def.h:129-131）；
- ENTRY_ARRAY 的元素（journal-def.h:153-155）；
- DATA 尾部 `tail_entry_array_offset/n_entries` 快速指针（journal-def.h:92-96）。

读侧用同一组内联函数按模式透明取数（journal-file.h:201-212、238-248）。代价是文件不可超 4GiB，因此做成 per-file incompatible flag 而非全局改版——/run 与嵌入式小文件场景索引空间近乎减半。

## 五、写入路径：解析之后、落盘之前

### 5.1 限速：每 unit 分组、按优先级分池

闸门在 `manager_dispatch_message`：`MaxLevelStore` 以下直接丢弃（journald-manager.c:1269-1270），`Storage=none` 短路（journald-manager.c:1274-1275）；条目带 `_SYSTEMD_UNIT` 时才进 `journal_ratelimit_test`（journald-manager.c:1277-1288）。

限速器结构（src/journal/journald-rate-limit.c）：

- 全局分组上限 2047（`GROUPS_MAX`，:12），组按字符串 id（通常是 unit 名）挂在 OrderedHashmap 上；
- 每组 5 个池按优先级归并：EMERG~CRIT 一池、ERR、WARNING、NOTICE/INFO、DEBUG 各一池（:11-23）；
- 窗口内超 burst 即压制，窗口翻新时返回"放行 + 此前压制条数"（:220-237）：
- burst 随磁盘剩余空间对数放大——可用空间每 16 倍，容忍翻倍（`burst_modulate` 的注释给出 1MB→×1 … 1TB→×6 的表格，:148-174）。

触发压制时 journald 补发 "Suppressed N messages from <unit>" 的 driver 消息留痕（journald-manager.c:1291-1295）。默认 30s/10000（journald-config.c:25-26）。另有 `MaxLevelStore/Syslog/KMsg/Console/Wall` 五个级别开关（journald-config.c:57-61）控制各去向的最高级别。

### 5.2 压缩：data 对象粒度、尽力而为

`maybe_compress_payload` 仅当对象体积 ≥ `compress_threshold_bytes`（默认 512B、下限 8B，journal-file.c:50-51；传入点 journald-manager.c:297）且文件启用压缩时才动手（journal-file.c:1854-1871）；成功则把压缩后尺寸写回 `object.size`、flags 置位，失败则原文直存——压缩失败不是错误（journal-file.c:1918-1928）。`Compress=` 开关与阈值在配置合并层兜底为 enabled=true/UINT64_MAX（journald-config.c:80-83）。压缩是 per-object 的，条目内小字段（如 `PRIORITY=6`）永远原样存——这也正是值索引能直接 memcmp 的原因。

### 5.3 同步策略：不是每条 fsync

条目落盘不立即 fsync：`manager_schedule_sync` 对 `LOG_CRIT`/`ALERT`/`EMERG` 立即同步（journald-manager.c:1869-1871），其余挂定时器，默认 `SyncIntervalSec=5min`（journald-manager.c:1898；默认值 journald-config.c:24），CRIT 路径还把同步事件源提升优先级（journald-manager.c:1896）。mtime/ctime 刷新也走 25ms 合并定时器 `journal_file_post_change`（journal-file.c:2448，启用点 journald-manager.c:316）。SIGRTMIN+1 手动全量 sync（journald-manager.c:1772）。

## 六、可信字段与防伪造

字段名在入口先过 `journal_field_valid`：非空、≤64 字符、仅 `[A-Z0-9_]`、非数字开头，且 `allow_protected=false` 时**下划线开头一律拒收**（journal-file.c:1746-1782；调用点 journald-native.c:164、232）——客户端伪造不了任何 `_` 开头字段。

可信字段由 journald 在分派末端自己生成：

- **身份**：来自 socket 凭证 `ucred` 与按 PID 缓存的 ClientContext（缓存+LRU，journald-context.c:704-763）；上下文回读 /proc 取 comm/exe/cmdline/capability（`client_context_read_basic`，journald-context.c:230-243），补 audit session/loginuid（journald-context.c:546）与 cgroup 归属（journald-context.c:280），拼出 `_PID=`/`_UID=`/`_GID=`/`_COMM=`/`_EXE=`/`_CMDLINE=`/`_CAP_EFFECTIVE=`/`_AUDIT_SESSION=`/`_SYSTEMD_UNIT=` 等一整排（journald-manager.c:1091-1116）。带下划线即"由 journald 背书"。
- **代客记账**：`OBJECT_PID=`（描述被日志谈论的进程）只接受 root 发送方（`allow_object_pid`，journald-native.c:35-37、85-95），对应字段用不带下划线的 `OBJECT_*` 系列（journald-manager.c:1126-1152）。
- **时间**：条目 realtime/monotonic 不取发送方时钟，而取事件循环开始处理该消息的时刻（journald-manager.c:1192-1196），保证落盘条目按处理顺序严格单调；发送方 timeval 降级存为 `_SOURCE_REALTIME_TIMESTAMP=`（journald-manager.c:1156-1159）。
- **机器/引导**：`_BOOT_ID`/`_MACHINE_ID`/`_HOSTNAME`/`_RUNTIME_SCOPE`（initrd/system）由 journald 缓存注入（journald-manager.c:1164-1176）；boot_id 同时写入 ENTRY 对象支撑跨重启二分（journal-file.c:2426）。

## 七、持久化与轮转：/run 分流、vacuum、seal

### 7.1 /run 与 /var 的分流

`manager_system_journal_open` 双轨开文件：

- 持久侧：仅 `STORAGE_PERSISTENT` 才 mkdir `/var/log/journal` 前缀（`STORAGE_AUTO` 只尝试已存在的机器目录），打开系统文件 system.journal（journald-manager.c:360-384）；
- 运行时侧：`/run/log/journal/<machine-id>/system.journal` 永远 `seal=false`——密封需要持久密钥存储，/run 是易失的（journald-manager.c:405-424）。

只要 runtime journal 开着，一切消息写 /run：`manager_find_journal` 开头即短路返回（journald-manager.c:521-526）。/var 就绪后，SIGUSR1 或启动时的 `manager_flush_to_var` 用 `sd_journal_open(RUNTIME_ONLY|ASSUME_IMMUTABLE)` 读回运行时条目，`journal_file_copy_entry` 逐条搬运进系统文件（journald-manager.c:1339-1369），完成后在 /run 放 `flushed` 标记（journald-manager.c:324-350）。

写 /var 时按 `SplitMode` 与 UID 分文件：普通用户写 user-UID.journal 并加读 ACL（journald-manager.c:1179-1190、246-259），用户文件超时会离线归档（journald-manager.c:611）。空间记账带缓存：`cache_space_refresh` 周期性 statvfs，`manager_determine_space` 给限速器提供"可用空间"入参（journald-manager.c:143-212）。守护进程主循环（src/journal/journald.c:23-149）启动即 vacuum→flush→flush_dev_kmsg 三连（journald.c:78-80），支持多 namespace 实例与空闲自退出（journald-manager.c:2133-2210）、内存压力回调（journald-manager.c:2230）。

### 7.2 轮转与空间回收

写入前的例行检查 `journal_file_rotate_suggested` 五种情况建议轮转：

1. Header 落后于当前结构定义（journal-file.c:4662-4666）；
2. data/field hash 表填充率超 75%（:4672-4698）；
3. hash 链深度超 `HASH_CHAIN_DEPTH_MAX`=100（:4702-4718，常量 journal-file.c:91，对抗碰撞攻击）；
4. n_fields==0 而 n_data>0，索引异常（:4721-4730）；
5. 最老条目超 `MaxFileSec`（:4732-4745）。

此外两条轮转路径：时间倒跳立即轮转+vacuum——条目时间必须单调，二分才成立（journald-manager.c:961-971），strict_order 模式下写侧还直接拒绝时间倒退的条目（journal-file.c:2368-2395）；写入失败（ENOSPC 等）的恢复动作是 rotate+vacuum 后重试一次（`shall_try_append_again`，journald-manager.c:873-942、1013-1043）。

轮转本体：`journal_file_archive` 把现文件改名为 `名@seqnum_id-headseqnum-headrealtime.journal`（journal-file.c:4404-4414），`journal_file_rotate` 以旧文件为模板开新文件并延迟关闭旧件（src/shared/journal-file-util.c:445-485）。

vacuum（`journal_directory_vacuum`，src/libsystemd/sd-journal/journal-vacuum.c:126）只动归档：从文件名的 `@` 结构区分活跃/归档/损坏（`.journal~`），活跃文件永不删（journal-vacuum.c:177-251），空文件无条件清（journal-vacuum.c:253-274）；其余从老到新按三条硬规则删除：

```c
for (i = 0; i < n_list; i++) {                    /* journal-vacuum.c:295 */
        left = n_active_files + n_list - i;
        /* 三条同时不越界才停手：retention / 总量 / 文件数 */
        if ((max_retention_usec <= 0 || list[i].realtime >= retention_limit) &&
            (max_use <= 0 || sum <= max_use) &&
            (n_max_files <= 0 || left <= n_max_files))
                break;
        r = unlinkat_deallocate(dirfd(d), list[i].filename, 0);   /* :305 */
```

限额推算规则是一组常量：max_use 未配置时取文件系统 10% 并夹在 [1MiB, 4GiB]（journal-file.c:57-73、4060-4065），keep_free 上限 4GiB，n_max_files 默认 100（journal-file.c:76）；显式默认值全为 UINT64_MAX 即"自动"（`journal_reset_metrics`，journal-file.c:4559-4570）。除写入触发的即时 vacuum，主循环还按 `MaxRetentionSec` 定时回收（journald.c:109-120）。

### 7.3 seal 一句话

以 FSS 密钥文件（FSPRG 状态，FSSHeader 见 journal-def.h:270-282）驱动密钥按固定周期演化，journald 在每个演化窗口末对迄今所有对象头 HMAC-SHA256 出一个 OBJECT_TAG 追加入文件（src/shared/journal-authenticate.c:466-504），主循环按 `next_evolve_usec` 定时补签（journald.c:122-127、journald-manager.c:2544）——只防事后篡改（`journalctl --verify`），不防拦截者整体重放。

## 八、读侧一句话

读侧只需两件事即可工作：

- `sd_journal_add_match` 把 Match 变成"查 data 对象→走该对象的 entry 链"的集合运算（src/libsystemd/sd-journal/sd-journal.c:223）；
- `sd_journal_seek_cursor` 用 `seqnum + boot_id + monotonic + realtime + xor_hash` 五元组跨文件唯一定位一条日志（src/libsystemd/sd-journal/sd-journal.c:1302）。

写侧为此维护原料：keyed-hash 文件的 xor_hash 特意改用无密钥 Jenkins hash，保证 cursor 在轮转前后文件间完全一致（journal-file.c:2640-2652）。迭代器、多文件归并、mmap-cache 细节归报告 B。

## 九、设计动机

1. **二进制结构化而非文本**：字段名/值分别建 FieldObject/DataObject，同值只存一份（journal-file.c:1899-1905），字段天然可索引、可校验（字段名白名单，journal-file.c:1746-1782）；文本 syslog 靠事后正则，重复值与解析成本高，且无法区分"日志自称的"与"journald 查证的"。
2. **追加写 + 偏移指针**：所有链接是 le64 文件偏移、写入永不移动旧数据（journal-file.c:1250-1297），断电损坏面收敛到文件尾部；mmap 后零拷贝读取，读写进程无锁共享（靠先写体后挂链的内存屏障，journal-file.c:2289）。
3. **双 hash 表分工**：data 表按完整字段值索引，支撑等值匹配与去重；field 表按字段名索引，支撑取值浏览与 Match 展开（journal-file.c:1943-1950）。单一粒度无法同时满足"查值"与"看字段"两类查询；表按最大文件体积一次预留（journal-file.c:1307-1313），换取运行期零 rehash、零搬移。
4. **COMPACT 模式**：/run 与嵌入式场景里条目引用从 16B 砍到 4B（journal-def.h:129-131、153-155），索引空间近乎减半；代价是 4GiB 上限（journal-file.c:818-819），因此做成 per-file incompatible flag——老读程序明确拒开而非误读。
5. **默认限速（30s/10000）**：日志是唯一"任何进程都能无差别触发的磁盘写入通道"，不限速等于自建 DoS。按 unit 分组让滥用者只惩罚自己（journald-manager.c:1277-1288），按优先级分池保住 DEBUG 洪峰下的 ERR 可见性（journald-rate-limit.c:14-23），burst 随磁盘余量放大在洪峰与空间充裕间取平衡（journald-rate-limit.c:148-174），压制必留痕（journald-manager.c:1291-1295）。
6. **事件循环时间戳作为条目时间**：不信发送方时钟而用 journald 处理时刻（journald-manager.c:1192-1196），配合时间倒跳即轮转（journald-manager.c:961-971）与 strict_order（journal-file.c:2368-2395），使"按时间二分"在数学上成立；原始时钟仅存 `_SOURCE_REALTIME_TIMESTAMP` 供参考。
7. **下划线字段作为信任边界**：可信元数据只能由内核凭证与 /proc 生成（journald-manager.c:1091-1116），客户端通道在字段名校验处被硬性挡住（journal-file.c:1766-1768），日志因此可作审计输入；seal（7.3）再补一层"历史不可改"。

## 十、写作素材清单（文件：行号，均经本基线核对）

1. src/journal/journald-manager.c:1479 — `manager_process_datagram`：三 socket 统一收包、辅助数据、fd 分派
2. src/journal/journald-manager.c:1069 — `manager_dispatch_message_real`：可信字段注入、SplitMode 选 UID、事件时间戳
3. src/journal/journald-manager.c:1252 — `manager_dispatch_message`：级别过滤 + 限速闸门 + 压制留痕
4. src/journal/journald-manager.c:944 — `manager_write_to_journal`：选文件、旋转触发、失败重试
5. src/journal/journald-manager.c:352 — `manager_system_journal_open`：/run 与 /var 双轨、运行时 seal=false
6. src/journal/journald-manager.c:1301 — `manager_flush_to_var`：/run→/var 条目搬运
7. src/journal/journald-rate-limit.c:176 — `journal_ratelimit_test`：分组×池×burst 漏桶
8. src/journal/journald-native.c:98 — `manager_process_entry`：native 协议（文本行 + le64 长度帧）
9. src/journal/journald-syslog.c:337 — `manager_process_syslog_message`：RFC3164 解析、SYSLOG_RAW、原样转发
10. src/journal/journald-stream.c:211 — `stdout_stream_log`：stdout 捕获（配 journald-stream.h:11 握手状态机）
11. src/journal/journald-kmsg.c:96 — `dev_kmsg_record`：kmsg 解析与 seqnum 去重（:141-158）
12. src/journal/journald-context.c:230 — `client_context_read_basic`：/proc 采集可信元数据
13. src/libsystemd/sd-journal/journal-def.h:221 — `struct_Header__contents`：272B 头部全字段与 flags
14. src/libsystemd/sd-journal/journal-file.c:1878 — `journal_file_append_data`：查重、压缩、字段双链挂接
15. src/libsystemd/sd-journal/journal-file.c:2561 — `journal_file_append_entry`：条目组装、xor_hash、索引
16. src/libsystemd/sd-journal/journal-file.c:3032 — `generic_array_bisect`：entry-array 链上的时间二分

（其余已核对可引：journal-file.c:390 建 Header、:773 预分配、:1299 data 表估算、:1458 `link_data` 定桶、:1619 hash 选型、:2448 post_change 合并、:4388 归档改名、:4656 轮转条件、:4559 metrics 默认；journal-vacuum.c:126 回收主循环；journal-file-util.c:445 轮转；journal-authenticate.c:466 追加 TAG；journald-config.c:24-26 默认值；journald.conf.in:20-26；journald.c:78-133 主循环。）
