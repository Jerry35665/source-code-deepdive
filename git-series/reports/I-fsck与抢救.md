# I — fsck 与抢救：Git 完整性检查与数据恢复的代码全景

> 本文基于 Git 源码 shallow clone（commit `47ce805`，"A bit more for -rc1"）逐行核对，
> 所有行号均为该 commit 下仓库相对路径 `文件:行号`。卷一 01 章讲过写入时的哈希自检，
> 04 章讲过 gc/cruft pack 的删除宽限；本章补齐"检查与修复"这一面：fsck 如何验证、
> 对象如何损坏与被发现、以及损坏后有什么抢救手段。

---

## 1. 全景：数据可能坏在哪，三层防线站在哪

### 1.1 数据可能坏在哪

| 损坏源 | 典型形态 | 代码中的痕迹 |
|---|---|---|
| 磁盘位翻转 | loose 对象内容与文件名哈希不符 | `object-file.c:1183-1187`（hash mismatch） |
| 半写的 loose 对象 | zlib 流被截断、尾部有垃圾 | `object-file.c:1170-1180`（corrupt / garbage at end） |
| 半写的 pack | 传输中断、磁盘满导致 `tmp_pack_*` 残留 | `builtin/prune.c:129-151` 专门清理 `tmp_` 文件 |
| 进程 kill | 已写对象但引用未更新 → dangling 对象 | `builtin/fsck.c:303-314` 注释（"a commit that got dropped"） |
| 上游传坏数据 | 恶意/故障对端推来畸形对象 | `builtin/receive-pack.c:60-62`（fsckObjects 开关） |

### 1.2 三层防线（ASCII 图）

```
           ┌─────────────────────────────────────────────────────────┐
 写入时 ──▶│ 第一层：内容寻址即校验                                    │
 (卷一01章) │  · 写 loose 对象前后重算哈希 object-file.c:113-124        │
           │  · 对象名=内容哈希，任何一处读出即可自检                    │
           └─────────────────────────────────────────────────────────┘
           ┌─────────────────────────────────────────────────────────┐
 传输时 ──▶│ 第二层：pack 流边收边验                                   │
           │  · index-pack 逐对象 CRC32 累积   index-pack.c:343,586   │
           │  · 逐对象哈希重算 + fsck          index-pack.c:928-959   │
           │  · 整包尾哈希比对                 index-pack.c:1292-1298 │
           │  · receive/fetch 可选 fsck 拦截   receive-pack.c:178-184 │
           └─────────────────────────────────────────────────────────┘
           ┌─────────────────────────────────────────────────────────┐
 运行时 ──▶│ 第三层：fsck 全库体检（本章主角）                          │
           │  · 结构校验（每对象）  fsck.c:1263-1280                   │
           │  · 连接性校验（全图）  builtin/fsck.c:364-402             │
           │  · 附属索引校验        builtin/fsck.c:1148-1186           │
           │  · prune 抢救联动      builtin/prune.c:84-109            │
           └─────────────────────────────────────────────────────────┘
```

三层的关键区别：第一层是**单对象自证**（哈希即名字），第二层是**通道内校验**（收完即验，
拒绝入库），第三层是**事后体检**（对已入库数据做结构 + 连接性双重检查）。前两层由
写入路径自动执行；第三层需要用户或工具显式触发——`git gc` 并不运行 fsck
（`builtin/gc.c` 中无任何 fsck 调用），这是 FAQ 常见误区。

---

## 2. fsck 总控专节：两阶段架构

`cmd_fsck`（`builtin/fsck.c:1008-1190`）是理解全部行为的入口。它分两个阶段：
**先收集 roots 并做对象级校验，再做一次连接性遍历**。

### 2.1 两套 fsck_options，两种 walk 回调

fsck 同时维护两个选项结构，walk 回调不同，这是最容易读漏的一点
（`builtin/fsck.c:1029-1036`）：`fsck_walk_options.walk = mark_object`（连接性遍历用），
`fsck_obj_options.walk = mark_used`（对象级校验用），strict 时给后者置位（1035-1036 行）。

- `mark_object`（`builtin/fsck.c:125-179`）：把可达对象打上 `REACHABLE`（151-153 行去重），
  压入 `pending` 队列（177 行）。
- `mark_used`（`builtin/fsck.c:213-220`）：只打 `USED` 位（218 行），**不**入队。
  它在对象级校验时把"被别人指着"这件事记下来，为 dangling 判定服务。

四个标志位定义在 `builtin/fsck.c:30-34`：`REACHABLE`（可达）、`SEEN`（已做过对象级校验）、
`HAS_OBJ`（本地存在）、`USED`（有指针指向它）。

### 2.2 阶段一：对象级校验 + roots 收集

入口 `cmd_fsck` 中的执行顺序：

1. **引用库体检**：`fsck_refs`（`builtin/fsck.c:955-979`）拉起子进程 `git refs verify`
   （968 行），默认开启（52 行）。
2. **refs 快照**：`snapshot_refs`（597-665 行，调用点 1063）。注释
   `builtin/fsck.c:1057-1062` 说明动机：避免遍历对象期间用户改 refs 导致漏检。顺序：
   显式命令行对象（611-625 行，若给了则跳过 reflog：627-630）→ 所有 refs
   （632-633 行，含 broken：601）→ 每个 worktree 的 HEAD（635-661 行）。
   664 行记下 `now = time(NULL)`，供 reflog 时间过滤（504 行）。
3. **对象库逐对象校验**（1068-1104 行）分两条路：
   - `--connectivity-only`：只对每个对象打 `HAS_OBJ`（`mark_object_for_connectivity`，
     911-919 行），完全不解析内容——快，但漏掉 blob 内容损坏（文档
     `Documentation/git-fsck.adoc:68-76` 明说了这一点）。
   - 完整模式：先扫 loose（`fsck_source` 792-811 → `fsck_loose` 721-774），再
     `verify_pack` 扫每个 pack（1091-1098 行），逐对象回调 `fsck_obj_buffer`
     （450-469 行，467 行打 `HAS_OBJ`）。之后 `fsck_finish`（1102-1103 行）收尾
     `.gitmodules`/`.gitattributes` 的延迟校验（`fsck.c:1361-1373`）。
4. **process_refs**（675-714 行，调用点 1107）：快照 refs 逐个 `mark_object_reachable`
   （583-595 行，589 行打 `USED`）；然后遍历全部 worktree 的 reflog（687-696 行），
   `fsck_handle_reflog_oid`（473-494 行）把 reflog 新旧值都标 `USED` + 可达（486-487 行）。
5. **index 兜底**：没给显式对象时 `keep_cache_objects = 1`（1110-1111 行），
   `verify_index_checksum = 1`（1120 行）打开 index 自身校验，逐 worktree
   `fsck_index`（879-909 行）：index 里的 blob（886-905 行）、cache-tree（906-907 →
   813-838 行）、resolve-undo（908 → 840-877 行）都作为可达根。这是"暂存区里的
   东西不会被 prune 删掉"的代码依据。

### 2.3 阶段二：连接性遍历与分类报告

`check_connectivity`（`builtin/fsck.c:364-402`）：

- `traverse_reachable`（197-211 行）是典型的**工作队列遍历**：`while (pending.nr)`
  循环弹出对象调 `traverse_one_object`（205-208 行），后者经 `fsck_walk` 分派
  （186-195 行）。去重靠 `mark_object` 先查 `REACHABLE` 标志（151-153 行），保证
  每个对象只入队一次；promisor 对象（部分克隆）到此为止不再递归（155-161 行）。
- `--connectivity-only` 时为让 dangling 准确，补一轮 `mark_unreachable_referents`
  （222-253 行，触发点 376-389 行）给不可达对象打 `USED`。
- 最后全量遍历对象哈希表逐个 `check_object`（396-401 行）分类报告。

**unreachable vs dangling 的精确区别**（`builtin/fsck.c:281-351`）：

- *unreachable*：存在、但没打 `REACHABLE` 的对象（`--unreachable` 才打印，296-301 行）。
- *dangling*：unreachable 且 `!USED`——即**没有任何别的对象指向它**，是不可达子图的
  "尖端"（315-344 行）。303-314 行的注释给出动机：删错分支后，这个尖端正是
  "找回头部的首选起点"，所以即使不开 `--unreachable` 也默认打印
  （`show_dangling = 1`，50 行）。

一句话：**dangling ⊆ unreachable；dangling 是"没人指"的尖端，unreachable 还包括
"被尖端牵着"的整个尾巴**。

### 2.4 附带体检与退出码

fsck 顺带校验四类附属索引（`builtin/fsck.c:1148-1186`）：pack 反向索引
（`check_pack_rev_indexes` 921-953）、bitmap（1149-1150 → `pack-bitmap.c:3413-3436`）、
commit-graph（1154-1169，子进程）、multi-pack-index（1171-1186，子进程）。
退出码是 8 个位标志（54-61 行）：`ERROR_OBJECT=01`、`ERROR_REACHABLE=02`、
`ERROR_PACK=04`、`ERROR_REFS=010`、`ERROR_COMMIT_GRAPH=020`、
`ERROR_MULTI_PACK_INDEX=040`、`ERROR_PACK_REV_INDEX=0100`、`ERROR_BITMAP=0200`；
`cmd_fsck` 最后 `return errors_found`（1189 行），脚本可用位运算区分损坏类别。

---

## 3. 对象校验专节：四类对象各自的检查点

`fsck_buffer`（`fsck.c:1263-1280`）按类型分派。所有错误经由 `report()`
（260-280 行）→ `fsck_vreport`（233-258 行）→ 注入的 `error_func` 输出。

### 3.1 tree：`fsck_tree`（fsck.c:616-810）

逐条目扫描（648-761 行），收集 11 类疑点，最后统一报告（765-809 行）：

| 检查点 | 行号 | 默认级别 |
|---|---|---|
| null sha1 条目 | 655 → 765-768 | WARN |
| 全路径/空名/`.`/`..`/`.git` | 656-660 → 769-788 | WARN |
| 零填充 mode、超长路径 | 661-662 → 789-792/805-808 | WARN |
| `.gitmodules` 是符号链接 | 664-673 | ERROR |
| 非法 mode（白名单 722-743） | 793-796 | INFO（`--strict` 下升级） |
| 重复条目、未按序 | `verify_ordered` 544-614 → 797-804 | ERROR |

mode 白名单（722-743 行）只放行 `0755/0644/符号链接/目录/gitlink`；`0664`
（历史上 g+w 位）仅在非 strict 时被原谅（737-739 行）——这正是 `--strict`
文档承诺要抓的东西（`Documentation/git-fsck.adoc:78-85`）。

### 3.2 commit：`fsck_commit`（fsck.c:950-1010）

检查顺序严格：头部分隔（`verify_headers` 829-859：NUL 字节 838-841、无 `\n\n`
或尾换行 857-858）→ `tree` 行（969-976）→ `parent` 循环（977-984）→
恰好一条 `author`（985-997，多 author 报 994-995）→ `committer`（998-1002）→
正文无 NUL（1003-1008）。身份行格式由 `fsck_ident`（877-948 行）做逐字段检查，
连"日期零填充"（932-933）和"时区必须 `±HHMM`"（939-945）都管。

### 3.3 tag：`fsck_tag_standalone`（fsck.c:1021-1131）

`object`/`type`/`tag`/`tagger` 四行依次检查（1041-1095 行）。注意两点：
缺 `tagger` 只是 INFO（1089-1093 行，"early tags"容错）；GPG 签名头
`gpgsig`/`gpgsig-sha256` 做续行格式检查（1097-1113 行）。**注意 fsck 只验签名的
"格式"，不验签名的"真伪"**——验真伪是 `git verify-tag`/`gpg` 的事。

### 3.4 blob：`fsck_blob`（fsck.c:1184-1252）

普通 blob 没有结构可查（内容是任意的）。唯一例外是被称为 blob 的
`.gitmodules`/`.gitattributes`：fsck 在 tree 阶段先把它们的 oid 收进
`gitmodules_found`/`gitattributes_found` 集合（`fsck.c:664-683`），等 `fsck_finish`
（1361-1373 行）统一读出内容、按配置文件语法校验子模块名/URL/path/update
（1139-1182 行）。"tree 指向的 blob 可能还没扫到"是这个两段式设计的原因
（`fsck.h:219-224` 注释）。

### 3.5 分级、`--strict` 与用户豁免

- 五级消息类型：`FSCK_IGNORE/INFO/FATAL` 内部使用，对外呈现为
  `ERROR/WARN`（`fsck.h:7-15`）；`fsck_vreport` 把 FATAL 归一为 ERROR、INFO 归一为
  WARN（`fsck.c:244-247`）。
- 每条消息的默认级别集中在 `FOREACH_FSCK_MSG_ID` 表（`fsck.h:23-104`）：
  FATAL 2 条、ERROR 51 条、WARN 10 条、INFO 11 条、IGNORE 1 条。
- `--strict` 的本质是**提级**：`fsck_msg_type` 在 strict 模式把 WARN 升为 ERROR
  （`fsck.c:110-112`）。
- 用户可用 `fsck.<msgId>=error|warn|ignore` 逐条改级（`git_fsck_config`，
  `fsck.c:1440-1469`），或 `fsck.skipList=<file>` 豁免特定 oid（1446-1459 行；
  解析在 `fsck_set_msg_types` 183-220，匹配在 `report` 的
  `object_on_skiplist` 272-273 行）。但 FATAL 消息不许降级（176-177 行）。

---

## 4. prune 联动专节：fsck → prune → cruft 的流水线

`git prune`（`builtin/prune.c:153-217`）与 fsck 是**同一套可达性语义的两种消费者**：
fsck 用它来"报告"，prune 用它来"删除"。

### 4.1 prune 的过期判定

`prune_object`（`builtin/prune.c:84-109`）的判定只有两闸：可达即绝不删
（90-91 行调 `is_object_reachable`）；不可达再看 mtime——`st.st_mtime > expire`
则宽限保留（98-99 行），过期才 `unlink_or_warn`（106-107 行）。
可达性来自 `perform_reachability_traversal`（57-71 行）调用
`mark_reachable_objects(revs, 1, expire, progress)`（68 行）。`expire` 默认
`TIME_MAX`（172 行，即裸 `git prune` 默认不删任何东西——必须给 `--expire`）；
`git gc` 传入的默认值是 `2.weeks.ago`（`builtin/gc.c:143`）。

### 4.2 roots 的最大化：比 fsck 更保守

`mark_reachable_objects`（`reachable.c:302-358`）的 roots 集合比 fsck 更宽：

- index 对象（317 行）、全部 refs（320-321）、detached/其他 worktree 的 HEAD
  （324-325）；
- **rebase 现场文件**：`rebase-apply|merge/{autostash,orig-head}`（55-84 行），
  中断的 rebase 不会丢工作；
- 全部 reflog（331-332 行）；
- **"近期对象"兜底**（347-355 行）：即使不可达，mtime 晚于 expire 的对象也标记
  SEEN 不删（`add_unseen_recent_objects_to_traversal` 247-284 行；
  `obj_is_recent` 183-192 行按 mtime 判定，另可由 `gc.recentobjectshook`
  外挂补充名单，172-181 行）。

### 4.3 与 04 章的接口：pack 内不可达对象交给 cruft

prune 只删 loose 对象（201-202 行）和过期 pack（`prune_packed_objects`，204 行）。
pack **内部**的不可达对象走 04 章讲过的 cruft 路径：gc 把 `pruneExpire` 翻译成
repack 的 `--cruft --cruft-expiration=<expire>`（`odb/source-files.c:490-498`），
非 cruft 模式则是 `-A --unpack-unreachable=<expire>`（499-503 行）——先降级为
loose 再由下一轮 prune 按 mtime 删。误删防线是叠加的：引用可达 + reflog 未过期 +
mtime 宽限 + cruft 宽限，四道闸全开才可能真删。另外
`repository_format_precious_objects` 仓库直接拒绝 prune（`builtin/prune.c:179-180`）。

---

## 5. 传输校验专节：index-pack 的边收边验

`git index-pack` 是 fetch/clone/receive 的落盘通道（`builtin/index-pack.c`），
校验有三层：

1. **流级 CRC32**：`use()` 每消费一批字节就累积（339-357 行，343 行）。
   每个对象开始时清零（532 行），对象结束时记录进 idx 条目
   （`obj->idx.crc32 = input_crc32`，586 行）——这就是日后 `fsck`/`verify-pack`
   做 `check_pack_crc` 比对的凭据（`pack-check.c:30-50`）。
2. **逐对象哈希 + fsck**：`sha1_object`（883-979 行）。先做碰撞检测
   （892-926 行，与既有同 oid 对象逐字节 memcmp）；strict/`transfer.fsckObjects`
   时对每个对象跑 `fsck_object`（928-959 行），错误即 `die("fsck error in packed object")`
   （938/957 行）。
3. **整包收尾验证**：`parse_pack_objects` 末尾把流式累积的哈希与 pack 尾哈希比对
   （`builtin/index-pack.c:1292-1298`，`hasheq(fill(rawsz), hash)` 不等即
   `die("pack is corrupted (SHA1 mismatch)")`），随后检查"包尾无垃圾"（1301-1306 行）；
   写出 `.idx` 后再比对 tail hash（1381-1403 行）。

`verify-pack` 路径的静态校验在 `pack-check.c`：整包哈希对 idx 记录（85-91 行）、
idx v2 逐对象 CRC（121-130 行）、逐对象重算哈希（155-157 行）。
midx 校验（`midx.c:925-1063`）则验证 checksum（950 行 → `midx_checksum_valid`
757-760 行）、OID 排序（979-992 行）和每对象 offset 与所属 pack idx 一致
（1047-1052 行）。接收端开关：`receive.fsckObjects`/`transfer.fsckObjects`
（`builtin/receive-pack.c:178-184`）；fetch 侧 `fetch-pack.c:1007-1054` 决定
是否用带 fsck 的 index-pack。

---

## 6. 抢救手册专节：按损坏类型给代码依据

| 症状 | 发现手段（代码依据） | 抢救路径 |
|---|---|---|
| 误删分支/commit | `git fsck` 默认打 dangling（`builtin/fsck.c:315-319`）；尖端语义 303-314 | `git fsck --unreachable \| grep commit` → `git show <oid>` 确认 → `git branch rescue <oid>` |
| 误删的未提交文件（dangling blob） | blob 无结构，dangling 报告 315-319 | `git fsck --lost-found`：blob **内容**写入 `.git/lost-found/other/<oid>`，commit/tree/tag 只写 oid 引用文件到 `commit/`（320-342 行；blob 分支 332-337） |
| reflog 还在 | `fsck_handle_reflog_oid` 把 reflog 当根（473-494）；prune 同样保 reflog（`reachable.c:331-332`） | `git reflog` / `git log -g` 找回；reflog 未过期即不会被 prune |
| 中断的 rebase/merge | rebase 现场文件被列为根（`reachable.c:55-84`）；resolve-undo（rr-cache 语义）在 `builtin/fsck.c:840-877` 被当根 | `git rebase --continue/--abort`；冲突三阶段 blob 可从 index/resolve-undo 找回 |
| loose 对象位翻转 | `fsck_loose` 报 `hash-path mismatch`/`object corrupt or missing`（`builtin/fsck.c:737-744`） | 删除坏 loose 文件 + `git fetch` 重取（对象名即内容哈希，可安全重建）；定位用 `git cat-file -p` 报错路径 |
| pack 损坏 | `verify_packfile` 报 checksum/CRC/corrupt（`pack-check.c:86-91,126,152,157`） | 换存储/重取：从远端重新 fetch 该 pack，或 reclone；**切忌**手改 pack（哈希链全断） |
| 大对象、中断的半写文件 | `tmp_obj_*`/`tmp_pack_*` 由 `remove_temporary_files` 清（`builtin/prune.c:135-151`） | `git prune` 自动清；无需手动 |
| 孤儿对象全量找回 | `git cat-file --batch-all-objects`（`builtin/cat-file.c:1240-1241`）枚举一切已知对象 | 配合 `--batch-check` 按类型过滤逐个导出 |
| 软索引损坏 | index 校验 `verify_index_checksum=1`（`builtin/fsck.c:1120`） | `rm .git/index && git reset`（index 可从 HEAD 重建，非对象数据） |
| 端上拦坏数据 | `receive.fsckObjects`/`transfer.fsckObjects`（`builtin/receive-pack.c:178-184`） | 服务端配置常开，防止坏对象入库 |

抢救的总原则来自内容寻址：**对象名就是内容哈希**（卷一 01 章
`object-file.c:113-124`），所以"找回"永远优于"修复"——
坏对象直接从任何持有正确副本的远端重新取回即可，无需理解损坏细节。

---

## 7. 设计动机

**为什么 fsck 默认只报不修？** 所有错误路径终点都是 `objerror`（`builtin/fsck.c:84-92`）
或 `fsck_objects_error_func`（94-121 行）——打印 + 置位 `errors_found`，没有任何写回。
原因有三：(1) "正确内容"往往不可再生——fsck 知道 tree 没排序，但不知道正确顺序；
(2) 内容哈希一旦改了对象名就变，等于新建对象，"修复"无从谈起；(3) 修复策略依赖外部
信息（远端副本、reflog 时间线），这是策略问题，fsck 作为机制只负责如实报告。

**完整性的分层哲学**：每对象哈希（自证，寻址即校验）→ 全图连接性（fsck，回答
"每个指针都指着存在且合法的对象吗"）→ 传输校验（pack 哈希链 + 逐对象 CRC，回答
"数据在通道里坏没坏"）。三层各覆盖一类故障：写坏、链接错、传坏。对比其他存储：
SQLite `integrity_check` 遍历全部 B-tree 页验证结构 + 索引一致性，是"单级但彻底"；
LevelDB 每块 CRC32 + MANIFEST 校验，是"每级自证"。Git 的独特之处在于对象图让
**部分损坏天然可定位到具体对象**（哈希不等 → 精确到 oid），且 `--connectivity-only`
（`builtin/fsck.c:1068-1070`）提供跳过 blob 内容读取的快速路径——大仓库可秒级确认
"指针网完好"，把昂贵的逐字节验证留给全量 fsck。

**dangling 为什么默认打印？** `builtin/fsck.c:303-314` 的注释是罕见的"产品思维"
代码注释：不可达集合本身没意思，有意思的是尖端——"如果你误删了一个分支，这就是
最好的起点"。把最可能被抢救的数据默认推到用户眼前，是 fsck 作为抢救入口的核心设计。

---

## 8. FAQ 素材

1. **unreachable 和 dangling 有什么区别？** dangling 是没有任何对象指向它的
   unreachable 尖端（`builtin/fsck.c:315-344`）；unreachable 还包含被尖端牵着的
   整条尾巴。`--unreachable` 全打印，dangling 默认打印。
2. **`git gc` 会跑 fsck 吗？** 不会。`builtin/gc.c` 无 fsck 调用；gc 只做
   pack-refs/reflog 过期/repack(cruft)/commit-graph。体检要显式 `git fsck`，可放 cron。
3. **fsck 的退出码怎么用？** 位标志：1 对象损坏、2 可达性、4 pack、8 refs、
   16 commit-graph、32 midx、64 rev-index、128 bitmap（`builtin/fsck.c:54-61`）。
4. **`--connectivity-only` 为什么快、漏什么？** 只标 `HAS_OBJ` 不解析内容
   （911-919 行），blob 损坏完全检不出（文档 68-76 行）。
5. **`--strict` 到底多查了什么？** WARN 全部升为 ERROR（`fsck.c:110-112`）；
   典型如 g+w 的 0664 mode（`fsck.c:737-743`）。
6. **历史仓库一大堆 warning 怎么办？** `fsck.<msgId>=ignore` 或 `fsck.skipList`
   （`fsck.c:1440-1469`），FATAL 不可降级（176-177 行）。
7. **dangling blob 是怎么产生的？** add 之后 reset、中断的 merge、index 半程操作
   写入但未被引用的 blob；受 mtime 宽限保护，宽限期内 fsck 能看到。
8. **`--lost-found` 的输出为什么有两种目录？** commit/tree/tag 写 oid 引用文件
   （可 `git show` 展开），blob 直接写内容（`builtin/fsck.c:320-342`）——blob 没有
   可解析的语义结构，直接给内容最实用。
9. **fsck 能验 GPG 签名真伪吗？** 不能。只验 `gpgsig` 头的格式
   （`fsck.c:1097-1113`）；验真伪用 `git verify-tag`。
10. **为什么裸 `git prune` 什么都不删？** 默认 `expire = TIME_MAX`
    （`builtin/prune.c:172`），`st.st_mtime > expire` 恒真（98 行）；只有 gc 传入的
    `2.weeks.ago`（`builtin/gc.c:143`）才真正开删。

## 深挖素材

1. **refs 快照的一致性设计**：遍历对象前先复制 refs 列表（`builtin/fsck.c:529-545,
   1057-1063`），换"遍历期间 refs 变更不漏检"的弱一致——讨论快照 vs 加锁的取舍。
2. **碰撞检测的双保险**：index-pack 收包时对已存在同 oid 对象逐字节 memcmp
   （`builtin/index-pack.c:892-926`）——SHA-1 弱化背景下"名字即内容"模型的攻击面
   与 sha256 迁移（`object-file.c:117-118` 按 `oid->algo` 分派）。
3. **fsck 的内存安全证明**：`verify_headers` 注释（`fsck.c:812-828`）解释为何先验
   头部分隔符即可保证后续行扫描内存安全——"解析器不变量即安全边界"的 C 语言案例。
4. **附属索引的可卸载性**：midx/rev-index/bitmap/commit-graph 全部可 `rm` 重建
   （fsck 用子进程验证，`builtin/fsck.c:1148-1186`）——什么数据允许缓存化、什么必须
   可验证，是存储设计的通用问题。
5. **`fsck_finish` 的两段式校验**：`.gitmodules` 内容检查必须等全部对象扫描完
   （`fsck.c:1361-1373`），tree 阶段只见 oid 不见内容——流式校验中的"前向引用"
   问题与拓扑排序意识。

---

## 写作要点速查表

| 函数/结构 | 位置 | 一句话 |
|---|---|---|
| `cmd_fsck` | builtin/fsck.c:1008-1190 | 总控：refs 体检→快照→对象校验→roots→连接性→附属索引 |
| `mark_object` / `mark_used` | builtin/fsck.c:125-179 / 213-220 | REACHABLE 入队 vs 仅打 USED |
| `traverse_reachable` | builtin/fsck.c:197-211 | pending 工作队列 + 标志去重 |
| `check_unreachable_object` | builtin/fsck.c:281-351 | unreachable/dangling 分界与 lost-found 落盘 |
| `check_connectivity` | builtin/fsck.c:364-402 | 阶段二入口；connectivity-only 补 USED |
| `fsck_loose` | builtin/fsck.c:721-774 | loose 逐个重算哈希，hash-path mismatch |
| `fsck_index` | builtin/fsck.c:879-909 | index/cache-tree/resolve-undo 作为根 |
| `fsck_walk` 分派 | fsck.c:482-504 | blob 终结、tree/commit/tag 递归 |
| `fsck_tree` | fsck.c:616-810 | 11 类 tree 疑点收集与报告 |
| `fsck_commit` | fsck.c:950-1010 | tree/parent/author/committer 头格式 |
| `verify_headers` / `fsck_ident` | fsck.c:829-859 / 877-948 | 内存安全前提；身份行逐字段 |
| `FOREACH_FSCK_MSG_ID` | fsck.h:23-104 | 75 条消息的默认分级表 |
| `fsck_msg_type` | fsck.c:102-116 | --strict 把 WARN 提为 ERROR |
| `prune_object` | builtin/prune.c:84-109 | 可达即免删 + mtime 宽限 |
| `mark_reachable_objects` | reachable.c:302-358 | index/refs/HEAD/rebase/reflog/recent 全量根 |
| `verify_packfile` | pack-check.c:52-180 | 包哈希 + idx CRC + 逐对象哈希 |
| `sha1_object` | builtin/index-pack.c:883-979 | 收包时碰撞检测 + fsck 拦截；尾检 1292-1306 |
| `verify_midx_file` / `read_loose_object` | midx.c:925-1063 / object-file.c:1192-1257 | midx 三查 / 读时重算哈希（01 章引用） |
