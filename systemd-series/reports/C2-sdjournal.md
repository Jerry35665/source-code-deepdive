# C2 · sd-journal：日志查询库与过滤引擎（卷二）

> 基线：systemd commit `1f66b52452879b68c32d79efdb9b97e4542ae7a4`。卷二 A 篇（A2-journald）讲"怎么写"，本篇讲"怎么读"：`src/libsystemd/sd-journal/sd-journal.c`（查询状态机，3836 行）、`journal-file.c`（单文件内二分定位，4767 行）、以及 journalctl 的读路径——本基线已拆分为 `journalctl.c`（1139 行，解析与分发）/ `journalctl-show.c` / `journalctl-filter.c` / `journalctl-util.c` / `journalctl-misc.c` / `journalctl-varlink.c`。所有行号均经实际 Read/Grep 核对；test/ 不在本地，未引用。

## 一、全景：一次带 Match 的查询

以 `journalctl _PID=731 -f` 为例，`sd_journal_next()` 一次推进的完整路径：

```
 sd_journal_next(j)  (= real_journal_next, sd-journal.c:1129)
 │
 │   j->files: OrderedHashmap<path, JournalFile*>   journal-internal.h:76
 │   （/run /var 下每个 machine-id[.namespace] 目录 × 每个 .journal 文件, 上限 7168）
 │
 ├────────────── 对每个文件 f 独立执行（k 个候选并行推进）──────────────┐
 │                                                                      │
 │  next_beyond_location(f)                       sd-journal.c:999      │
 │    │  (可选: ratelimit 下的尾时间戳刷新        sd-journal.c:1011)    │
 │    │                                                                │
 │    ├─ 有 Match:  next_for_match(level0)        sd-journal.c:666      │
 │    │    MATCH_DISCRETE "_PID=731":                                  │
 │    │      ① journal_file_find_data_object_with_hash                 │
 │    │         data 哈希表 % m → 链上比对      journal-file.c:1655    │
 │    │      ② move_to_entry_by_offset_for_data                        │
 │    │         在该 data 对象的 entry 偏移链上二分                     │
 │    │         (after_offset 之后第一条)       journal-file.c:3710    │
 │    │    AND 项: 反复 gallop 收敛到交集        sd-journal.c:718-748   │
 │    │    OR 项:  各子项取最小 offset           sd-journal.c:699-716   │
 │    ├─ 无 Match: journal_file_next_entry       journal-file.c:3572   │
 │    │    主 entry array 链上 bisect + 取邻     journal-file.c:3032   │
 │    ▼                                                                │
 │  journal_file_save_location(f, entry)         journal-file.c:3547   │
 │    f->current_{offset,seqnum,realtime,monotonic,boot_id,xor_hash}   │
 │    并与上一条全局游标比对, 跳过跨文件重复条目  sd-journal.c:1061-1078│
 │                                                                      │
 └──────────────────────────────────────────────────────────────────────┘
 │
 ▼  k 个候选各持一个 LOCATION_SEEK
 compare_locations(af, bf)                        sd-journal.c:1081
    全序键: seqnum_id+seqnum → boot_id(按 prioq 估值) → realtime → xor_hash
    （同一 seqnum_id 才比 seqnum; 不同 boot 用 newest_by_boot_id prioq 换算）
 │
 ▼  取方向上最小/最大的那个文件
 set_location(j, new_file, o)                     sd-journal.c:126
    j->current_location 变为 LOCATION_DISCRETE, j->current_file = 赢家
 （follow 模式: inotify 目录监听 → sd_journal_process → 再次进入本流程）
```

核心思路：**没有任何全局索引**。每个文件只保证自己内部有序（写侧 A2 篇），查询库让每个文件在自己的数据结构上"跳到下一条匹配"，再在文件层面做 k 路归并。下面按"发现文件 → 定位 → 匹配 → 归并 → 输出"的顺序展开。

## 二、文件发现与目录约定

### 2.1 打开入口族

| 入口 | 位置 | 文件集合的确定方式 |
| --- | --- | --- |
| `sd_journal_open` / `_namespace` | sd-journal.c:2385-2387 / 2366-2383 | 固定搜索根（见下） |
| `sd_journal_open_directory` / `_fd` | sd-journal.c:2440-2461 / 2496-2527 | 任意目录当根；`OS_ROOT` 旗标则仍走搜索根 |
| `sd_journal_open_files` / `_fd` | sd-journal.c:2466-2487 / 2532-2580 | 仅指定文件，置 `no_new_files`（fd 版再置 `no_inotify`） |
| `sd_journal_open_container`（已弃用） | sd-journal.c:2394-2432 | 读 `/run/systemd/machines/<name>` 的 ROOT 键 |

搜索根只有两个：`/run/log/journal` 与 `/var/log/journal`；非 `SD_JOURNAL_LOCAL_ONLY` 时追加 `/var/log/journal/remote`（接收远程日志的目录，`add_search_paths`，sd-journal.c:2254-2272）。journalctl 默认加 LOCAL_ONLY，`-m/--merge` 时去掉（journalctl-util.c:59-63），这就是"merge 时把 remote 文件纳入查询"的全部机制。

### 2.2 目录命名：machine ID 与 namespace

- `dirname_is_machine_id()`：目录名是 `<machine-id>` 或 `<machine-id>.<namespace>`；`SD_JOURNAL_LOCAL_ONLY` 时只接受本地 machine-id 目录或 `/run` 前缀路径（sd-journal.c:1852-1879、2130-2133）。namespace 后缀先过 `log_namespace_name_valid()` 合法性检查。
- `dirname_has_namespace()`：按 `.` 后缀与 `j->namespace` 精确匹配；无后缀视为默认命名空间，仅当 `SD_JOURNAL_INCLUDE_DEFAULT_NAMESPACE` 时纳入；`SD_JOURNAL_ALL_NAMESPACES`（`--namespace=*`）全收（sd-journal.c:1881-1904、2135-2139）。
- 根目录下"像 ID 或 ID.ns 的子目录"才递归：`dirent_is_journal_subdir()`（sd-journal.c:1918-1938）；文件则须以 `.journal`/`.journal~` 结尾（`dirent_is_journal_file`，sd-journal.c:1906-1916）。

### 2.3 文件名过滤与打开细节

`file_type_wanted()` 按 `SD_JOURNAL_SYSTEM`/`SD_JOURNAL_CURRENT_USER` 匹配 `system.journal` / `user-<uid>.journal` 前缀，归档名 `*.journal~` 与 `*journal@*.journal` 中间态都算（`file_has_type_prefix`，sd-journal.c:1552-1593）；系统 UID（root 等）的查询自动加收 system 文件（sd-journal.c:1581-1587）。`add_any_file()`（sd-journal.c:1616-1733）的要点：路径相对 `toplevel_fd` 时强制改写为相对路径再 `openat`（1632-1638）；同名但 device/inode 变了即认定被轮转替换，先移除旧对象（1670-1690）；文件数到 `JOURNAL_FILES_MAX`=7168 拒绝（journal-internal.h:9、1693-1697）；打开成功即读一次尾时间戳（1722）。

### 2.4 实时跟随的 inotify 目录监听

每个已登记目录（含根）挂一个 watch，mask 覆盖 `IN_CREATE|IN_MOVED_TO|IN_MODIFY|IN_ATTRIB|IN_DELETE|IN_DELETE_SELF|IN_MOVE_SELF|IN_UNMOUNT|IN_MOVED_FROM|IN_ONLYDIR`（`directory_watch`，sd-journal.c:2074-2104；add_directory 内调用 2155-2158）。watch 以 wd 反查 `Directory`（`directories_by_wd`，journal-internal.h:125-126）。`process_inotify_event()` 三分支（sd-journal.c:3151-3198）：

1. 文件事件：`IN_CREATE|IN_MOVED_TO|IN_MODIFY|IN_ATTRIB` → 加文件；`IN_DELETE|IN_MOVED_FROM|IN_UNMOUNT` → 删文件；
2. 子目录自毁（非根、无名字事件）：`IN_DELETE_SELF|IN_MOVE_SELF|IN_UNMOUNT` → 释放 Directory；
3. 根目录下出现新目录且名字是合法 ID → 作为新 machine 目录加入。

inotify 队列溢出（`IN_Q_OVERFLOW`）则整体重枚举：generation 计数器 +1，凡本轮没见过的文件/目录（根除外）一律 GC（`process_q_overflow`，sd-journal.c:3111-3149）。inotify fd 是惰性创建的（`sd_journal_get_fd` 首调才建，随后 `reiterate_all_paths` 补挂 watch，sd-journal.c:3046-3071）；网络文件系统上退化为 2 秒轮询（`JOURNAL_FILES_RECHECK_USEC`，sd-journal.c:47、3087-3109）。

## 三、游标模型与位置状态

sd-journal 的"游标"是两层结构。**全局层** `j->current_location`（journal-internal.h:37-54）携带 `{seqnum+seqnum_id, realtime, monotonic+boot_id, xor_hash}` 五键及各自 set 位；**文件层**每个 `JournalFile` 有同构的 `current_*` 与 `location_type`（journal-file.h:65-82）。

`LocationType` 四态（journal-file.h:30-42）：

- `LOCATION_HEAD` / `LOCATION_TAIL`：位于首前/尾后（未开始/已耗尽）；
- `LOCATION_DISCRETE`：全局游标已落在某具体条目上，推进时须越过它（跨文件去重的锚点）；
- `LOCATION_SEEK`：文件已定位出候选但尚未被全局采纳；seek 族调用后、下一次 next 前的中间态。

seek 族的实现都是"重置 location、只设相应键"（真正的定位推迟到 next）：

| API | 位置 | 设置的键 |
| --- | --- | --- |
| `sd_journal_seek_head` / `_tail` | sd-journal.c:1517-1528 / 1530-1541 | type=HEAD/TAIL |
| `sd_journal_seek_realtime_usec` | sd-journal.c:1502-1515 | realtime |
| `sd_journal_seek_monotonic_usec` | sd-journal.c:1486-1500 | monotonic+boot_id |
| `sd_journal_seek_cursor` | sd-journal.c:1302-1403 | 解析出的各键子集 |

定位执行在 `find_location_with_matches()`（sd-journal.c:924-974）：优先 seqnum（须同 `seqnum_id`），再 monotonic（同 boot 内二分；未命中则落到下一 boot 的首/上一 boot 的尾），再 realtime，最后回到顺序边界。游标字符串是自描述的六键格式：

```c
if (asprintf(ret,
             "s=%s;i=%"PRIx64";b=%s;m=%"PRIx64";t=%"PRIx64";x=%"PRIx64,
             SD_ID128_TO_STRING(j->current_file->header->seqnum_id), le64toh(o->entry.seqnum),
             SD_ID128_TO_STRING(o->entry.boot_id), le64toh(o->entry.monotonic),
             le64toh(o->entry.realtime),
             le64toh(o->entry.xor_hash)) < 0)
        return -ENOMEM;                    /* sd-journal.c:1291-1297 */
```

游标是"值"而非"位置"：不绑定文件，拷贝到别的机器也能 `--after-cursor` 续读（`sd_journal_test_cursor` 逐键校验当前条目，sd-journal.c:1405-1484）。另有一个跨 boot 排序修正：无 RTC 机器上 `compare_locations` 可能选错文件，若某文件恰好持有游标的精确 (seqnum_id, seqnum)，则强制采纳（`exact_match`，sd-journal.c:1170-1184，注释引 issue #31516）。

## 四、Match 体系：四层树与 data 链跳转

### 4.1 内部表示

`sd_journal_add_match` 把每个 `FIELD=value` 收进一棵固定四层的匹配树（sd-journal.c:223-325）：

```c
/* level 0: AND term
 * level 1: OR terms
 * level 2: AND terms
 * level 3: OR terms
 * level 4: concrete matches */          /* sd-journal.c:241-245 */
```

`Match` 节点只有 DISCRETE / OR_TERM / AND_TERM 三型（journal-internal.h:17-35）；DISCRETE 预存 jenkins hash（sd-journal.c:271）——新式 keyed siphash 因每文件种子不同不能预存（sd-journal.c:269-270），求值时须 `journal_file_hash_data` 现算（journal-file.c 侧见 §五）。同字段多个值自动并入同一 OR 项（`same_field` 以 `=` 为界比较字段名，sd-journal.c:170-183、286-295）。**注意：没有 min_level 之类的字段**，优先级 `-p` 是被编译成多个 `PRIORITY=N` DISCRETE 的 OR（§八）。有效性检查 `match_is_valid` 只允许 `大写/数字/_` 字段名且禁止 `__` 前缀（sd-journal.c:141-168）。

### 4.2 disjunction / conjunction 的手工拼装

- `sd_journal_add_disjunction()`：置空 level2 —— 结束当前 AND 组，开启新组（sd-journal.c:377-395）；
- `sd_journal_add_conjunction()`：置空 level1 —— 结束当前 OR 大组（sd-journal.c:358-375）。

即调用方以"顺序 API"拼出 `(A AND B) OR (C AND D)` 形状的树；`journal_make_match_string` 能把树渲染回 `X AND (Y OR Z)` 字符串供调试（sd-journal.c:397-433，journalctl-filter.c:484-492 在 DEBUG 日志里打印它）。

### 4.3 求值：data 值链上的跳转

`next_for_match()`（sd-journal.c:666-762）是过滤引擎的核心。DISCRETE 先在文件 data 哈希表定位 `FIELD=value` 的 data 对象，再在其私有 entry 偏移链上二分出 `after_offset` 之后（或之前）第一条——**匹配是"跳"，不是"试"**：

```c
if (m->type == MATCH_DISCRETE) {
        if (JOURNAL_HEADER_KEYED_HASH(f->header))
                hash = journal_file_hash_data(f, m->data, m->size);
        else
                hash = m->hash;
        r = journal_file_find_data_object_with_hash(f, m->data, m->size, hash, &d, NULL);
        if (r <= 0)
                return r;
        return journal_file_move_to_entry_by_offset_for_data(f, d, after_offset, direction, ret, ret_offset);
}                                                        /* sd-journal.c:682-697 */
```

OR 项对每个子项求值取最小（DOWN）/最大（UP）offset（699-716）；AND 项用 gallop 法求交集（718-748）：反复"跳到当前已知最小命中之后"，记录"最近移动过的子项"优先重试以保局部性。**本基线中不存在 `evaluate_and_return`/min_bbox 式的 bbox 记账**（全仓 grep 无 `bbox`）——交集计算就是这段 gallop 循环。

带 Match 的 seek 定位走 `find_location_for_match()`（sd-journal.c:813-922）：先让各子项分别定位，AND 取最远、OR 取最近，再交给 `next_for_match` 收敛。monotonic+boot 定位未命中时的跨 boot 推进由 `move_by_boot_for_data()` 处理（跳到 boot 边界外的第一条，再回到字段链二分，sd-journal.c:764-811）。

## 五、二分查找：entry array 链上的 bisect

**bisect 表已移除**：本基线 journal-def.h / journal-file.c 中没有任何 bisection table 结构（grep `bisect_table` 为空），替代品是每文件至多 `CHAIN_CACHE_MAX`=20 项的 `ChainCacheItem` 链缓存（journal-file.c:82、2694-2701），字段 `{first, array, begin, total, last_index}` 记录"上次停在链中第几个 array、此前累计多少项、上次看过的下标"。它是纯运行时记忆：顺序扫描（`-n`、follow）天然命中，写侧零维护。

- **主链 bisect** `generic_array_bisect()`（journal-file.c:3032-3270）：在 `header->entry_array_offset` 打头的 entry array 单链上，用 `test_object` 回调（比 offset/seqnum/realtime/monotonic）找"最接近 needle"的条目。链缓存命中且上次起点在 needle 左侧则直接跳到缓存 array（3073-3093）；每个 array 先试末元素决定去留，再以 `last_index±1` 邻域试探提升局部性（3136-3154），最后经典二分（3156-3193，中点 `i=(left+right+(UP))/2`，3184）。
- **方向语义**：`TEST_FOUND` 在 DOWN 时折为 TEST_RIGHT（找第一条命中）、UP 时折为 TEST_LEFT（找最后一条命中），由 `generic_array_bisect_step` 统一处理（2945-3030，3000-3005）；entry array 是单链，UP 方向找前驱 array 只能从链头重扫（`bump_entry_array`，2764-2810）。
- **坏条目韧性**：step 遇 `EBADMSG`/`EADDRNOTAVAIL` 时收缩右界或回退前一 array（2974-2996、3217-3243）；`generic_array_get()`（2812-2933）顺序取条目时逐个跳过坏 entry（2914-2921）。
- **data 链 bisect** `generic_array_bisect_for_data()`（3272-3355）：先试 data 对象的"直连 entry" `data.entry_offset`（写侧第一条命中的 entry 不进数组），DOWN 方向命中即免二分（3304-3316）；UP 方向若直连 entry 已在 needle 左侧则整个链都不用看（3319-3326）。
- **入口函数族**：by_offset（3371）、by_seqnum（3411）、by_realtime（3451）、by_monotonic（3505-3529——先 `find_data_object_by_boot_id()` 把 `_BOOT_ID=<uuid>` 字符串当 data 键查到 boot 的倒排链，再在其上比单调时钟，3491-3503）。`journal_file_next_entry()`（3572-3640）= bisect 定位 + `generic_array_get` 取邻 + `check_properly_ordered` 有序性校验（3560-3570、3630-3633）。
- **双重二分求交**：`journal_file_move_to_entry_by_monotonic_for_data()`（3732-3803）——"找某 boot 内含某字段、且时刻 ≥ t 的第一条"：先 pin 住字段 data 对象（3751-3754），在 `_BOOT_ID=` 链上按 monotonic 二分得 z，再在字段链上按 offset 二分，两个结果不一致就交替逼近直至收敛（3771-3796）。这是两条倒排链求交的教科书实现。

## 六、k 路归并：跨文件全序、去重与实时跟随

### 6.1 全序键

`real_journal_next()` 每轮让所有文件各给一个候选（候选挂在文件层 location，`location_type=LOCATION_SEEK`），再 `compare_locations()` 两两定序选赢家（sd-journal.c:1145-1181）。键序（sd-journal.c:1092-1127）：

1. 五键完全相等 → 同一条，返回 0（去重前提）；
2. 同 `seqnum_id` → 比 `seqnum`（同一序列号域才可比；同域同号不同内容按 borked 处理，回落按时间比，1101-1109）;
3. 同 `boot_id` → 比 `monotonic`；异 boot → `compare_boot_ids()` 估值（1111-1118）；
4. 比 `realtime`（1121）；5. 比 `xor_hash` 内容兜底（1126）。

### 6.2 跨 boot 估值器：newest_by_boot_id

`j->newest_by_boot_id` 是按 boot id 有序、可二分的数组，每 boot 挂一个按"最新 monotonic"大顶的 prioq（journal-internal.h:64-67；sd-journal.c:447-538）。`compare_boot_ids()` 取两个 boot 各自最新的文件，**仅当两者 `newest_machine_id` 相同（同源机器）**时用 `newest_realtime_usec` 定序，否则放弃比较（sd-journal.c:588-605）。这些 newest 值由 `journal_file_read_tail_timestamp()` 维护：优先读 header 快捷字段 `tail_entry_offset`（2679-2685），否则摸尾对象或手动走链到末条；并刻意从**尾条目的 `_MACHINE_ID=` 字段**而非 header 取机器 ID——journal-remote 落盘时 header 记接收方、条目才是来源方（2658-2780，注释 2736-2752）。归并迭代期间的刷新受 rate limit，否则大 `journalctl -n` 查询会被 O(N×files) 的 mmap 易失读拖垮（1007-1012；journal-file.h:111）。

### 6.3 跨文件去重

同一条日志常同时存在于 system/user 或 runtime/persistent 两个文件。`next_beyond_location()` 的收尾循环用 `compare_with_location()`（sd-journal.c:607-664，五键全等快速通道 620-630）与全局游标比对，方向上未"越过"就继续 next（1055-1078）——因此重复条目只输出一次，且由"最赢得比较"的那份文件提供。

### 6.4 实时跟随与韧性

follow 模式下 journalctl 把 `sd_journal_get_fd()` 的 inotify fd 挂进 sd_event（journalctl-show.c:458-494；fd 获取 547-556），事件到来 → `sd_journal_process()` 增删文件并递增 invalidate 计数（sd-journal.c:3200-3242）→ 重入归并循环。两个工程细节：

- 展示循环每 1024 条主动 process 一次，缩短轮转后已删除文件 fd 的存活窗口（journalctl-show.c:25、301-311）；
- 归并途中选中的文件可能刚被 vacuum 掉：`-EIDRM`/`EADDRNOTAVAIL` 等错误会剔除该文件并重试，剔除保证下轮必有进展（sd-journal.c:1189-1206）；`sd_journal_wait` 首次建立 watch 时也会先清扫一遍已删除文件（3262-3268）。

## 七、实时与单调时钟的映射

- **单调时钟只在 boot 内有意义**。`sd_journal_get_monotonic_usec()` 在调用方不索要 boot_id 时，取本机当前 boot id 与条目 boot_id 比对，不一致返回 `-ESTALE`（sd-journal.c:2810-2849）。
- **本机 boot id** 由 `sd_id128_get_boot()` 读 `/proc/sys/kernel/random/boot_id` 并线程本地缓存（src/libsystemd/sd-id128/sd-id128.c:174-199）；容器内查询走 `id128_get_boot_for_machine()`，machine 为空即退化为读本机（src/libsystemd/sd-id128/id128-util.c:280-292）。journalctl `-b` 的快捷路径正是用它一步拿当前 boot，避免遍历（journalctl-util.c:100-105）；带偏移（`-b -1`）才走慢路径 `journal_find_boot` 逐 boot 数（106-126）。
- **since/until 与展示换算**：`--since/--until` 是墙钟值，直接 `sd_journal_seek_realtime_usec` 按每文件 realtime 二分；`short-monotonic`/`short-delta` 输出由 `parse_display_timestamp()` 在条目自身 (realtime, monotonic) 基准上用 `map_clock_usec_raw` 线性映射 `_SOURCE_*_TIMESTAMP=` 的偏移（src/shared/logs-show.c:486-524，映射 514-518）；时钟基准换算原语 `map_clock_usec(_raw)` 在 src/basic/time-util.c:95-133。
- **boot 枚举不靠时钟换算表**：`journal_get_log_ids()` 从尾（或头）逐条扫，用 `sd_journal_get_monotonic_usec` 副产物 boot_id 判别切换，再借 `_BOOT_ID=` match 在倒排链上跳到该 boot 的首/末条补齐时间（src/shared/logs-show.c:2021-2140 的 `discover_next_id`、2274-2338 的 `journal_get_log_ids`；`--list-boots` 入口 journalctl-misc.c:163-187）。boot id 数据对象本身的 (首,末) 条目时间可经 `journal_file_get_cutoff_monotonic_usec` O(1) 取得——首条就是 `data.entry_offset` 直连 entry，末条走链尾（journal-file.c:4616-4654）。

## 八、journalctl 的关键实现

### 8.1 拆分与动作分发

`journalctl.c` 只剩参数解析与分发（`run()` 于 journalctl.c:1049-1137）：SHOW（默认）、LIST_BOOTS、LIST_FIELDS/`-F`、LIST_FIELD_NAMES/`-N`、DISK_USAGE、VACUUM/ROTATE、VERIFY（FSS）、FLUSH/RELINQUISH、catalog 族、varlink 服务模式（`vl_server`，284-320，提供 `io.systemd.JournalAccess.GetEntries` 与 `io.systemd.Metrics.*`）。另有 `--invocation/-I` 的 invocation 级过滤（解析于 journalctl-util.c:240-284）。

### 8.2 action_show 主流程（journalctl-show.c:523-620）

`acquire_journal`（journalctl-util.c:31-74，选择 open 入口；非 follow 时全局加 `SD_JOURNAL_ASSUME_IMMUTABLE`，journalctl.c:991-992，库侧据此跳过尾时间戳刷新，sd-journal.c:2671-2672）→ `add_filters`（journalctl-filter.c:427-495：先 `journal_acquire_boot`/`journal_acquire_invocation` 解析出目标 ID，清空意外 match，再按 invocation | boot+unit → dmesg → identifier → priority → facility → 位置参数 的顺序装配；位置参数里 `+` 生成 disjunction，绝对路径参数会展开成 `_EXE`/`_COMM`/`_KERNEL_DEVICE` 匹配，388-425、288-386）→ `seek_journal`（journalctl-show.c:50-157，四种定位策略：cursor/after-cursor 精确续读 → `--reverse`/`-n` 先 seek tail 再 `previous_skip` → `--since` seek realtime → 默认 seek head）→ 非 follow 直接 `show()`，follow 进 sd_event 循环（579-595），退出前 `update_cursor` 回写 `--cursor-file`（496-521）。

`show()` 循环（journalctl-show.c:159-315）逐条处理：`--until` 时间闸（183-195，`-n` 足量时可豁免 `until_safe`）→ `--since` 重定位（197-224）→ boot 切换横幅（226-239）→ **grep 过滤**（241-288）→ `show_journal_entry` 输出（290）。

### 8.3 输出格式

`-o` 归一到 src/shared/logs-show.c 的函数表（journalctl.c:638-657；logs-show.c:1479-1491）：

- `output_short`（logs-show.c:526）：一次枚举挑出 `_PID/_COMM/MESSAGE/PRIORITY/_HOSTNAME/SYSLOG_IDENTIFIER/_SYSTEMD_UNIT/_SOURCE_*_TIMESTAMP` 等十余字段（551-566），按终端宽度设 `data_threshold` 促成省略号截断（574-578）；`-T` 排除的 identifier 在此二次过滤（597-598）。
- `output_verbose`（783）逐字段打印全部 data；`output_export`（911）可回放导出格式；`output_json`（1331）；`output_cat`（1412）裸 MESSAGE。
- export/json 模式自动置 `arg_quiet`（journalctl.c:649-650）。

### 8.4 --grep：没有降级，只有逐条过滤

PCRE2 是 dlopen 可选依赖；`pattern_compile_and_log` 在未编译 PCRE2 或模式非法时**直接报错退出**（`-EOPNOTSUPP`/`-EINVAL`），没有逐字匹配降级（src/shared/pcre2-util.c:35-72、56-155）。大小写默认自动：模式含 `[[:upper:]]` 即敏感（102-119）。运行期**不是跳文件而是逐条过滤**——`show()` 每条取 `MESSAGE=` 做 `pattern_matches_and_log`（NOMATCH 返回 false，pcre2-util.c:115-137），不中则 `need_seek=true` 跳下一条（journalctl-show.c:241-288），命中区间作为 highlight 传给输出层着色（274-275、290-292）。两个配套行为：`--grep`+`-n` 隐含 `--reverse` 自尾部回扫（journalctl.c:982-988）；全不命中时模仿 grep 返回非零 `-ENOENT`（journalctl-show.c:612-617）。

### 8.5 磁盘用量、vacuum 与字段枚举

- `--disk-usage` → `action_disk_usage()` → `sd_journal_get_usage()` 按 `st_blocks*512` 累加（journalctl-misc.c:91-108；sd-journal.c:3396-3423）。
- `--vacuum-size/-files/-time` 解析（journalctl.c:828-850）→ `action_vacuum()` 对 `j->directories_by_path` 每个目录调 `journal_directory_vacuum()`（journalctl-varlink.c:99-115；删除策略属写侧，见 A2 篇）。
- `-F` 值枚举：`sd_journal_query_unique` + `sd_journal_enumerate_unique`——沿 `field.head_data_offset` → `data.next_field_offset` 值链遍历，跨"更早的文件"做存在性去重（keyed hash 文件须重算哈希再查），并用 `journal_file_pin_object` 固定当前对象防窗口被换出（sd-journal.c:3425-3565，去重 3531-3555）。
- `-N` 字段名枚举：`sd_journal_enumerate_fields` 遍历 field 哈希表桶 + `next_hash_offset` 链，同样跨文件去重（sd-journal.c:3590-3730）；两者在 `-p/-b/-S` 等过滤选项下都被禁止（journalctl.c:958-960，判定函数 journalctl-filter.c:26-43）。
- `--list-namespaces` 直接扫两个根目录下的 `ID.ns` 子目录（journalctl-misc.c:285-355）。

## 九、设计动机

1. **为什么游标是值而不是 SQL/文件偏移量**：journal 文件会被轮转、vacuum、跨机拷贝；偏移量会失效，也不存在可连接的服务端（读取方是任意进程内库）。六键游标让"位置"成为可序列化、可跨文件验证的数据（sd-journal.c:1291-1296、1405-1484），`--cursor-file` 因此能做断点续传式的日志采集。
2. **为什么 k 路归并而非全局索引**：写侧按 boot/大小主动切文件（A2 篇），全局索引要与轮转竞争且难增量维护；而每个文件内部天然有序（entry array 单调、data 倒排链单调），归并只需 O(k) 次文件内推进。代价是全序键复杂——seqnum 按 `seqnum_id` 分域、monotonic 按 boot 分域，跨域只能用"最新时间戳 prioq"估值（sd-journal.c:588-605），这也是 `exact_match` 修正与 issue #31516 存在的根源。
3. **为什么 Match 用 data 链跳转而不是逐条过滤**：`FIELD=value` 的全部命中位置在写侧就已串进该 data 对象的 entry 链；查询时一次哈希定位 + 链上二分即跳到"下一条命中"，复杂度与命中数的对数相关，与文件总条数无关。四层 AND/OR 树把任意组合归约为"链跳转的求交/取最小"，不需要表达式求值器。正则（MESSAGE）因值无序才退回逐条扫描——索引的边界恰好画在"值是否可序"上。
4. **为什么 bisect 表被链缓存取代**：旧 bisection table 是文件内静态加速结构，随追加而失效且占 header；`ChainCacheItem` 把"上次二分停在哪"作为纯运行时记忆（journal-file.c:2694-2701），对顺序扫描天然命中，对随机 seek 也不劣于从头二分，写侧零维护成本。同样，旧式 bbox 记账交集在本基线已被 gallop 循环取代——跳转本身已足够快，预处理交集边界反而增加簿记。
5. **为什么 grep 不建 ngram 索引**：日志的典型查询是"字段等值 + 时间范围"，正则是少数派；为少数派维护倒排索引会显著放大写放大（A2 篇的压缩与 hash 表已经不小）。journalctl 的选择是游标扫描 + PCRE2，配合"从尾部回扫 + 提前退出（-n）"把成本压到命中窗口附近。
6. **为什么 follow 用目录 inotify 而非文件 inotify**：文件会被轮转替换（inode 变化），目录级 `IN_CREATE|IN_MOVED_TO` 天然感知新文件与 machine-id 子目录的诞生（sd-journal.c:3151-3198）；队列溢出再以 generation 全量重枚举兜底——"事件增量 + 全量兜底"的经典组合。

## 十、写作素材清单（文件:行号，均经本基线核对）

1. `src/libsystemd/sd-journal/sd-journal.c:241-245` — Match 四层结构注释（AND/OR 交替）
2. `src/libsystemd/sd-journal/sd-journal.c:666-762` — `next_for_match`：DISCRETE/OR/AND 三种求值
3. `src/libsystemd/sd-journal/sd-journal.c:1081-1127` — `compare_locations` 跨文件全序五级键
4. `src/libsystemd/sd-journal/sd-journal.c:1129-1212` — `real_journal_next` k 路归并主循环与 exact_match 修正
5. `src/libsystemd/sd-journal/sd-journal.c:1274-1300` — 游标字符串格式 `s=;i=;b=;m=;t=;x=`
6. `src/libsystemd/sd-journal/sd-journal.c:2254-2272` — 搜索路径与 `/var/log/journal/remote`
7. `src/libsystemd/sd-journal/sd-journal.c:2658-2780` — 尾时间戳读取与 `_MACHINE_ID` 来源修正
8. `src/libsystemd/sd-journal/journal-internal.h:69-129` — `sd_journal` 对象全貌（files/location/level0-2/inotify）
9. `src/libsystemd/sd-journal/journal-file.h:30-42` — `LocationType` 四态枚举
10. `src/libsystemd/sd-journal/journal-file.c:2694-2742` — `ChainCacheItem`（bisect 表的替代品）
11. `src/libsystemd/sd-journal/journal-file.c:3032-3270` — `generic_array_bisect` 主链二分
12. `src/libsystemd/sd-journal/journal-file.c:3732-3803` — boot 链与字段链的双重二分求交
13. `src/journal/journalctl-show.c:50-157` — `seek_journal` 四种定位策略
14. `src/journal/journalctl-show.c:241-288` — `--grep` 逐条过滤与高亮区间
15. `src/journal/journalctl-filter.c:427-495` — `add_filters` 装配顺序
16. `src/shared/pcre2-util.c:56-155` — PCRE2 dlopen、大小写自动判定与无降级路径
