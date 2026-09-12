# C 篇:Git 索引(index)与工作树状态机深读

> 源码版本:git commit `47ce805`(shallow clone);所有 `文件:行号` 均为仓库相对路径,已用 grep/Read 实际核对。

## 1. 全景:三方状态模型

Git 的核心心智模型是三个"虚拟文件系统快照":工作树(worktree)、索引(index)、HEAD。任何命令都可理解为在这三者之间搬运内容:

```
        git add / git add -p          git commit
 工作树  ──────────────────────▶  索引  ──────────────▶  HEAD
 (磁盘文件)                     (.git/index 文件)      (commit → tree)
    ▲                              │                      │
    │      git checkout / restore  │   git reset --soft   │
    └──────────────────────────────┴──────────────────────┘
              git diff(工作树 vs 索引)
              git diff --cached(索引 vs HEAD)
              git diff HEAD(工作树 vs HEAD)
```

索引文件的本质是:**"扁平化的树快照 + stat 缓存"**。
- "扁平化的树":index 按路径名 `memcmp` 升序存放全部文件条目(无目录层级,目录只是路径前缀),排序规则见 `Documentation/gitformat-index.adoc:54-56`。commit 时把这份扁平列表重建(或复用缓存)为真正的树对象。
- "stat 缓存":每个条目额外保存 ctime/mtime/dev/ino/uid/gid/size(`read-cache.c:1681-1698`),使得"工作树是否改动"可以先用一次 `lstat` 判定,内容没变就不必读文件、更不必哈希——这是 `git status` 快的根源。
- 关键内存结构 `struct index_state`(`read-cache-ll.h:166-191`):`cache` 指针数组 + `cache_nr`、`version`、`cache_tree`、`timestamp`(index 文件自身的 mtime,racy 判定的基石,`read-cache-ll.h:173`)、`untracked`、`fsmonitor_*`、`sparse_index` 等。

## 2. index 文件格式专节

### 2.1 DIRC 头 → entry 二进制 → 扩展 → 尾部校验

整体布局(小节数字为源码锚点):

```
| "DIRC" | version | entry 数 |      (12 字节头)
| entry 0 | entry 1 | ... | entry N-1 |
| EXT "TREE" | len | data | EXT "REUC" | len | data | ...
| 尾部:整个文件内容的 SHA-1/SHA-256 |
```

- 魔数:`#define CACHE_SIGNATURE 0x44495243 /* "DIRC" */`(`read-cache-ll.h:12`);头结构 3 个 uint32(`read-cache-ll.h:13-17`);支持版本 2-4(`read-cache-ll.h:19-20`,`INDEX_FORMAT_LB/UB`)。
- 读入:`do_read_index()` 打开文件并 `mmap`(`read-cache.c:2230,2247`),`verify_hdr()` 校验魔数(`read-cache.c:1723`)、版本范围(`read-cache.c:1726-1727`)与尾部校验和(`read-cache.c:1729-1743`);尾部哈希同时存入 `istate->oid`(`read-cache.c:2257-2258`)。
- 写入:头在 `do_write_index()` 组装(`read-cache.c:2868-2872`);所有扩展写完后 `finalize_hashfile()` 落盘整体哈希(`read-cache.c:3090-3091`)。注意默认情况下 `verify_index_checksum` 为 0,读取时**只查魔数不重算哈希**(`read-cache.c:1709-1710,1729-1730`),靠"写时哈希+读时 mmap"换取速度。

### 2.2 entry 二进制逐字段(v2/v3)

磁盘条目 `struct ondisk_cache_entry`(`read-cache.c:1681-1698`),全部大端(注释:为了 index 文件能跨 NFS 使用,`read-cache.c:1678-1679`):

| 字段 | 宽度 | 含义 |
|---|---|---|
| ctime.sec / ctime.nsec | 4+4 | 文件元数据变更时间(stat 缓存) |
| mtime.sec / mtime.nsec | 4+4 | 内容变更时间(racy 判定核心) |
| dev / ino | 4+4 | 设备号/inode(仅低 32 位,`read-cache.c:1673-1676`) |
| mode | 4 | 文件类型+权限(100644/100755/120000/160000/040000) |
| uid / gid | 4+4 | 属主 |
| size | 4 | 文件大小低 32 位 |
| oid | 20/32 | blob/gitlink 的对象 ID |
| flags | 2 | namelen(12bit)+stage(2bit)+CE_VALID/CE_EXTENDED |
| flags2(可选) | 2 | CE_EXTENDED 时:INTENT_TO_ADD/SKIP_WORKTREE |
| name | 变长 | 路径;v2/v3 补零到 8 字节对齐(`read-cache.c:1700-1703`) |

flags 位定义:`CE_STAGEMASK/CE_EXTENDED/CE_VALID`(`read-cache-ll.h:34-37`),扩展位 `CE_INTENT_TO_ADD|CE_SKIP_WORKTREE`(`read-cache-ll.h:70-75`)。解析端逐字段读取见 `create_from_disk()`(`read-cache.c:1865-1883`),写回见 `copy_cache_entry_to_ondisk()`(`read-cache.c:2625-2650`)。

### 2.3 v2 vs v4:路径前缀压缩

相邻条目往往共享长路径前缀。v4 只存"相对上一条删掉几个尾部字节"+新增后缀:

```c
// read-cache.c:1808-1815(读取端)
/* Adjacent cache entries tend to share the leading paths, so it makes
 * sense to only store the differences in later entries.  In the v4
 * on-disk format of the index, each on-disk cache entry stores the
 * number of bytes to be stripped from the end of the previous name,
 * and the bytes to append to the result, to come up with its name.
 */
int expand_name_field = version == 4;
```

读取端:`decode_varint()` 读出 strip 长度,`copy_len = previous_len - strip_len`,再从上一条拷前缀(`read-cache.c:1833-1847,1885-1889`);namelen 若被 12 位掩码截断则回退到 `strlen`(`read-cache.c:1849-1853`)。
写入端:`ce_write_entry()` 对 v4 传入 `previous_name`(`read-cache.c:2910`),逐字节求公共前缀、`encode_varint(to_remove)` 编码删除长度,只写后缀(`read-cache.c:2674-2696`)。v2 则整名写入并补零对齐(`read-cache.c:2668-2673`)。

### 2.4 扩展区与写入主流程

扩展头为 "4 字节签名 + 4 字节长度"(`write_index_ext_header()`,`read-cache.c:2557-2572`);未知扩展若首字母非大写则报错、大写则忽略(`read-cache.c:1774-1779`)。写入端依次输出(`do_write_index()` 内):

- IEOT(多线程读索引的分块表,`read-cache.c:2983-2993`,特意先写以减少扫描);
- LINK(split index 基索引指针,`read-cache.c:2995-3010`;与 sparse index 互斥,`read-cache.c:2999-3000`);
- TREE(cache-tree,`read-cache.c:3011-3022`)、REUC、UNTR(untracked cache)、FSMN(fsmonitor);
- `sdir` 零长度扩展:存在即代表"本索引已折叠为 sparse index"(`read-cache.c:3061-3064`,读取端置 `INDEX_COLLAPSED`,`read-cache.c:1770-1773`);
- EOIE(记录 entry 区结束偏移+扩展区自哈希,`read-cache.c:3077-3078`;内容由 `write_eoie_extension()` 写 offset+哈希,`read-cache.c:3648-3660`)。

版本选择:配置 `index.version`,默认写 v2;有扩展 flags 时 v3 保留、否则降回 v2(`read-cache.c:2859-2864`)。EOIE/IEOT 由 `index.recordEndOfIndexEntries/index.recordOffsetTable` 或 `index.threads` 触发(`read-cache.c:2773-2795`)。读端借助两者实现多线程解析(`read-cache.c:2285-2311`)。

## 3. stat 缓存与 racy git 专节

### 3.1 为什么 stat 会"假干净"

`match_stat_data()` 逐项比对 mtime/ctime/nsec/uid/gid/ino/size(`statinfo.c:64-102`)。问题:**mtime 与 size 的分辨率和原子性有限**。同一秒内:

```c
// read-cache.c:418-433(注释原文节选)
 * Within 1 second of this sequence:
 *      echo xyzzy >file && git-update-index --add file
 * running this command:
 *      echo frotz >file
 * would give a falsely clean cache entry.  The mtime and
 * length match the cache, and other stat fields do not change.
```

即"touch→改内容→add,再改内容"后,新内容可能与旧 stat 完全同 mtime 同 size,单看 stat 会误判"干净"。而"假脏"(实际没改却被判改)会导致多余的读文件与哈希,只是慢,不会错;"假干净"才是正确性问题。

### 3.2 racy 的判定:与 index 文件自身 mtime 比较

Git 用一个巧妙的锚点:**写入 index 文件时记录其自身 mtime 到 `istate->timestamp`**(`read-cache.c:2313-2314` 读时;`read-cache.c:3102-3103` 写后更新)。凡 mtime **不早于** index mtime 的条目都可能是在"add 之后、窗口期内"被改过的,一律按 racy 处理:

```c
// read-cache.c:353-366
static int is_racy_stat(const struct index_state *istate,
                        const struct stat_data *sd)
{
        return (istate->timestamp.sec &&
#ifdef USE_NSEC
                (istate->timestamp.sec < sd->sd_mtime.sec ||
                 (istate->timestamp.sec == sd->sd_mtime.sec &&
                  istate->timestamp.nsec <= sd->sd_mtime.nsec))
#else
                istate->timestamp.sec <= sd->sd_mtime.sec
#endif
                );
}
```

`is_racy_timestamp()`(`read-cache.c:368-373`)对 gitlink 直接豁免(submodule 靠 HEAD 比对)。状态查询路径在 `ie_match_stat()` 中:stat 相同但 racy 时,升级为"真的去文件系统核对内容"(`ce_modified_check_fs()`,读文件哈希比对,`read-cache.c:286-307`),调用点 `read-cache.c:434-439`。`add_to_index()` 干脆对可疑条目传 `CE_MATCH_RACY_IS_DIRTY`(`read-cache.c:729`),宁假脏勿假干净;其"stat 未变则直接复用旧条目"的快路径在 `read-cache.c:780-792`。

### 3.3 smudged 条目的识别

写入端把可疑条目的 `sd_size` 抹成 0 后,读端靠这段识别(`ce_match_stat_basic()` 尾部):

```c
// read-cache.c:342-350
        changed |= match_stat_data(&ce->ce_stat_data, st);

        /* Racily smudged entry? */
        if (!ce->ce_stat_data.sd_size) {
                if (!is_empty_blob_oid(&ce->oid, the_repository->hash_algo))
                        changed |= DATA_CHANGED;
        }

        return changed;
```

即:索引里 size 为 0 且 oid 不是空 blob ⇒ 这一定是个被 smudge 的条目,直接判"已修改"强制走内容比对。空 blob 是例外,因为 size==0 本来就与空文件一致。

### 3.4 两道防线:读时核对 + 写时 smudge

- **读/比对防线**:`ie_match_stat()` 的 racy 分支(见上),以及 `ce_match_stat_basic()` 里的"smudged 条目"识别——`sd_size == 0` 且 oid 非空 blob 则必然 DATA_CHANGED(`read-cache.c:344-348`)。
- **写回防线**:`do_write_index()` 写每个条目前,若它不是 uptodate 且 racy,调用 `ce_smudge_racily_clean_entry()`:再 lstat 一次、stat 仍匹配、且**内容核实确有出入**(`ce_modified_check_fs()`)时,把索引里的 `sd_size` 置 0 打上"此条目不可信"标记(`read-cache.c:2916-2917` 调用;`read-cache.c:2574-2622` 实现,`sd_size = 0` 在 `read-cache.c:2620`)。这被称为 "racily clean → smudge":此后每次比对都因 size 不匹配而被迫读内容,牺牲速度保正确。长注释(含 `frotz` 例子)论证了该操作不会与后续 update-index 冲突(`read-cache.c:2595-2619`)。
- 兜底检查:`has_racy_timestamp()`(`read-cache.c:2749-2760`)与 `repo_update_index_if_able()`(`read-cache.c:2762` 起)用于决定是否需要重写 index 清除 racy 状态。
- `ie_modified()` 另一反直觉点:刚 `read-tree --cacheinfo` 后 size 为 0,`DATA_CHANGED` 不可信,必须查文件系统(`read-cache.c:461-473`)。

## 4. 三方对比专节:status 的实现

### 4.1 两次 diff 的顺序与模型

`git status` 的数据收集在 `wt_status_collect()`(`wt-status.c:865-888`),顺序固定:

1. **worktree vs index**:先做!`wt_status_collect_changes_worktree()` 走 `run_diff_files()`(不碰对象库、纯 stat 驱动,`wt-status.c:639-664`,调用在 `:662`),回调 `wt_status_collect_changed_cb`(`wt-status.c:460`)写入 `index_status`;
2. **index vs HEAD**:`wt_status_collect_changes_index()` 用 `setup_revisions` 把 `opt.def` 设为 HEAD(初始提交则为空树,`wt-status.c:673`),再 `run_diff_index(&rev, DIFF_INDEX_CACHED)`(`wt-status.c:708`),回调 `wt_status_collect_updated_cb`(`wt-status.c:547`)写入 `index_status` 与 `oid_head/oid_index`;稀疏目录条目要求 `diffopt.recursive=1` 才能递归到具体文件(`wt-status.c:699-705`);
3. **untracked**:`wt_status_collect_untracked()`(`wt-status.c:806-850`)。

每个路径最多两个状态位(`index_status`/`worktree_status`),`s->committable` 在 index 侧有变化时置位(`wt-status.c:573,578,596`);未合并路径记 `stagemask`(`wt-status.c:598-600`、`785-793`)。status 无需构造 diff 补丁,只取"哪些路径变了"的回调结果——这正是 worktree→index 用 `run_diff_files`(可被 stat 缓存短路)的原因:最贵的"工作树扫描"放在最先且可提前剪枝。

两次 diff 都挂"回调收集器"而非输出格式,从 `wt_status_collect_updated_cb()` 可见每条 diff pair 如何映射回三方字段(`wt-status.c:547-605`):`ADDED` 只填 `mode_index/oid_index`(HEAD 侧留零)、`DELETED` 只填 `*_head`、`MODIFIED/RENAMED/COPIED` 两侧都填并携带改名分数(`wt-status.c:586-596`)。同一路径被两轮 diff 各改一次时,第一轮写入的状态不被覆盖(`if (!d->index_status) d->index_status = p->status;`,`wt-status.c:566-567`)——两轮结果在 `struct wt_status_change_data` 上叠加而非互相干扰。

另有两条旁路:初始仓库(无 HEAD)不跑 index-vs-HEAD,改走 `wt_status_collect_changes_initial()` 把索引全部条目标为 `ADDED`,sparse 目录条目还要递归树展开(`wt-status.c:742-766`);`git commit` 的部分提交走锁定临时索引,期间 status 读的是"被暂存子集"的索引(见 `builtin/commit.c:405-434`)。

### 4.2 untracked 的目录级剪枝

默认(`status.showUntrackedFiles=normal`)下 untracked 只报目录不递归:

- status 侧给 `dir_struct` 打 `DIR_SHOW_OTHER_DIRECTORIES|DIR_HIDE_EMPTY_DIRECTORIES`(`wt-status.c:816-818`);并挂上索引里的 untracked cache(`dir.untracked = istate->untracked`,`wt-status.c:825`);
- 入口 `fill_directory()` 用 pathspec 公共前缀收缩扫描根(`dir.c:272-294`);
- 递归体 `read_directory_recursive()`(`dir.c:2698-2793`)对每项调用 `treat_path()`(`dir.c:2426`)得到 `path_treatment` 四值(`dir.c:52-57`,注意优先级:untracked > excluded);仅 `path_recurse` 才继续下钻(`dir.c:2730-2740`);
- 目录命运由 `treat_directory()` 决定(`dir.c:1966` 起):目录在索引中存在→recurse(`dir.c:1982-1989`);`DIR_SHOW_OTHER_DIRECTORIES` 分支在 `dir.c:2044-2070`——非空判定靠 `check_only` 模式的短路递归,`stop_early` 允许"排除目录遇到第一个文件即停"(`dir.c:2145,2752-2771`),整个目录只产出一条 `dir_entry`(目录名),实现 O(目录数) 报告。

### 4.3 ignore 规则求值路径

每个路径的"是否被忽略"由 `last_matching_pattern()` 裁决(`dir.c:1808`),它先 `prep_exclude()` 把沿途 `.gitignore`/`$GIT_DIR/info/exclude`/`core.excludesFile` 逐级压栈(`dir.c:1649` 起),再从最内层作用域向外找第一条命中的规则——"越深越优先"的语义正是这样实现的。`treat_directory()` 里被排除的目录还有专门分支(`dir.c:2044-2068`),配合 `DIR_SHOW_IGNORED_TOO_MODE_MATCHING` 决定报告目录本身还是其下的 ignored 子路径。

### 4.4 untracked cache:把"扫目录"也缓存掉

- 每目录缓存 stat 数据与排除结果,复用条件在 `valid_cached_dir()`:fsmonitor 可信或 `match_stat_data_racy()` 未变(`dir.c:2523-2569`,关键 `2538-2547`);
- 启用条件保守:`validate_untracked_cache()` 要求全树扫描(无 pathspec/前缀,`dir.c:3003-3004`)、不收集 ignored(`dir.c:3007-3009`)、排除规则仅来自标准文件(`dir.c:2994-3017`);
- 索引侧写路径自动失效:`untracked_cache_invalidate_path()`(`dir.c:4020`,add 路径调用 `read-cache.c:1285`)。它是 `TREE` 之外的第二个"索引内嵌的次级缓存":拿 index 体积换 status 速度。

## 5. sparse index 专节

### 5.1 动机:O(HEAD) → O(Populated)

官方设计文档直指痛点:数百万路径的大仓库中,`git status/add` 的开销被"解析与重写 index"主导,因为 index 塞满 `SKIP_WORKTREE` 的占位文件条目(`Documentation/technical/sparse-index.adoc:22-30`)。目标是把这类命令从 O(HEAD) 降到 O(Populated)(`sparse-index.adoc:31`)。这与 partial clone(promisor remote)同属超大仓库计划:clone 只取元数据+所需 blob,索引也只保留"感兴趣区域"的条目。

### 5.2 机制:目录条目代替成千文件条目

- **表示**:折叠区的整个目录只留一个 mode `040000`、带 `SKIP_WORKTREE`、路径以 `/` 结尾的"sparse directory entry",其 oid 指向 HEAD 中的树(`Documentation/gitformat-index.adoc:59-64`);判定宏 `S_ISSPARSEDIR(m) == S_IFDIR`(`object.h:124`)。磁盘上以零长度 `sdir` 扩展标记整个索引已折叠(`read-cache.c:3061-3064`)。
- **折叠**:`convert_to_sparse()`(`sparse-index.c:208-265`)前置条件严苛:必须 cone 模式(`sparse-index.c:164,202-203`)、非 split index(`sparse-index.c:173`)、无未合并条目(`sparse-index.c:228`);依赖有效 cache-tree——无效则先 `cache_tree_update(WRITE_TREE_MISSING_OK)`(`sparse-index.c:231-243`),因为**折叠正是按 cache-tree 的 `entry_count` 区间切分**:`convert_to_sparse_rec()` 用子树 `entry_count` 一次跳过整段文件条目、替换为一条目录条目(`sparse-index.c:95-136`,取 span 在 `:116`),最后 `cache_nr` 大幅缩小(`sparse-index.c:249`)。entry 数量级从"文件数"降到"cone 边界目录数",可差 2-4 个数量级。
- **展开**:`expand_index()` 对每条 sparse dir 用 `read_tree_at()` 递归展开回文件条目(`sparse-index.c:404-444`);`ensure_full_index()` 是所有未适配代码路径的保险丝(`sparse-index.c:469-473`)。部分展开(只动 cone 边界附近)记为 `INDEX_PARTIALLY_SPARSE`(`sparse-index.c:394`)。
- **与 status 的配合**:index-vs-HEAD 的 diff 开 `recursive` 以穿透 sparse 目录条目(`wt-status.c:699-705`);初始提交 status 遇 sparse dir 则递归树收集"新增"文件(`wt-status.c:757-766`)。近三年(2.32 起)它已是 cone 模式仓库的默认性能路径,并与 split index 显式互斥(`read-cache.c:2999-3000`)。

## 6. cache-tree:commit 为什么快

索引里内嵌一棵"未落盘的树对象缓存"(`TREE` 扩展,`read-cache.c:3011-3022`;格式:路径 + `entry_count subtree_nr` + 树 oid,`cache-tree.c:555-563`)。两层收益:

- **读**:若 `cache_tree_fully_valid()`(根 oid 在对象库存在且全子树有效,`cache-tree.c:278-292`),则 commit 的树 oid 直接取根节点,**零树构建**:`write_index_as_tree_internal()` 先查有效性再决定是否重建(`cache-tree.c:745-770`);`git commit` 最终就用 `the_repository->index->cache_tree->oid` 作为提交树(`builtin/commit.c:1938`)。
- **写**:失效时只重建。`update_one()` 先查"本级 oid 仍存在则整棵子树免重建"(`cache-tree.c:336-339`),再按斜杠切分子树递归(`cache-tree.c:352-392`),最后按 tree 对象格式拼 `"mode name\0" + oid` 缓冲(`cache-tree.c:480-482`)写对象库(`cache-tree.c:501-502`)。只改一个文件时,根与受影响目录重写、兄弟子树全部缓存命中——commit 接近 O(改动路径所在的树链),而非 O(全仓库条目数) 的全量建树。
- **失效传播**:任何 index 改动沿路径祖先链精确失效 `cache_tree_invalidate_path()`(`cache-tree.c:159-163`;增删改条目处的调用如 `read-cache.c:632,935`)。
- commit 前的统一入口:`cache_tree_update()`(内置未合并条目校验 `verify_cache`,写前批量预取 promisor 对象,`cache-tree.c:517-548`),`builtin/commit.c` 在 424(交互暂存)、464/488/537(部分提交路径)、1111(正式提交前 `Error building trees` 检查)多处调用。
- 反哺关系闭合:sparse index 折叠依赖 cache-tree 的 `entry_count`(`sparse-index.c:116`),折叠后又要重建之(`sparse-index.c:253-255`)。

## 7. `git add` 与索引刷新路径(builtin/add.c 简读)

`git add` 的主线(`cmd_add`,入口读索引用预加载:`repo_read_index_preload()`,`builtin/add.c:578`):

- 暂存 worktree 改动:`add_files_to_cache()`(`builtin/add.c:675` → 实现 `read-cache.c:4026-4069`):内部还是那套 diff 机制——`run_diff_files(&rev, DIFF_RACY_IS_MODIFIED)`(`read-cache.c:4063`)以回调 `update_callback()`(`read-cache.c:3987-4024`)对 `MODIFIED/TYPE_CHANGED` 调 `add_file_to_index()` 写 blob 入库并更新条目,对 `DELETED` 从索引移除;`DIFF_RACY_IS_MODIFIED` 保证窗口期条目宁可多算不漏算。
- `git add --refresh`:只刷新 stat 缓存、不写对象,核心是 `refresh_index()`(`builtin/add.c:124-160`,调用在 `:134`);对只匹配 skip-worktree 的 pathspec 给专门提示(`builtin/add.c:140-153`)。
- 其余变体:`--renormalize`(`builtin/add.c:74,672-673`)、`--chmod`(`builtin/add.c:43,687`)都是"改条目元数据"的不同入口。
- `add_to_index()` 的快路径值得记住:同名、非未合并、`ie_match_stat` 判未变 ⇒ 直接复用旧条目标 `CE_UPTODATE`("Nothing changed, really",`read-cache.c:780-792`)——`git add .` 在干净仓库上接近纯 stat 扫描,不写任何对象。

## 8. 设计动机讨论

- **为什么 index 是单文件而非数据库(如 SQLite)?** (1)访问模式极端单一:整读整写、全序遍历、无随机查询热点,append+mmap 即最优;(2)原子性靠"临时文件+rename"锁文件即可(`write_locked_index` 体系),无需 WAL;(3)格式是自描述的字节流,任何版本 git 可前向容忍未知扩展(`read-cache.c:1774-1779`),跨版本协作比嵌入式库 schema 更平滑;(4)零依赖、可跨 NFS 拷贝(大端字段注释,`read-cache.c:1678-1679`)。代价是每次写全量重写——于是才有 v4 压缩、IEOT 多线程、split index/skip-hash 等补丁式演进。
- **stat 缓存是拿空间换扫描**:每条目 ~30+ 字节 stat 数据(`read-cache.c:1681-1698`)换来 `status` 的 O(entries) 次 lstat 而非 O(entries) 次读文件+哈希;racy 防线(smudge/racy-check)说明这层启发式的正确性必须靠回退机制兜底,典型"乐观缓存+校验回退"设计。
- **格式演进驱动**:v2(基线)→ v3(扩展 flags:stage 之外的 Intent-to-Add/Skip-worktree)→ v4(路径前缀压缩,大仓库 index 体积)→ EOIE/IEOT(多线程读写,CPU 换墙钟)→ TREE/UNTR/FSMN(把派生数据内嵌索引避免重算)→ sparse dir(条目数量级,`sparse-index.adoc:31-38`)。每次演进都对应一个性能瓶颈:体积→CPU→扫描→条目数。
- **次级缓存的可失效性设计**:untracked cache/fsmonitor 都挂在 `index_state` 上并随 index 原子落盘,失效入口收敛(如 `dir.c:4020`),保证"缓存错了也能自愈"——与 stat 缓存的 racy 防线同构。

## 9. FAQ 素材

1. **`git status` 为什么有时候突然变慢、要读很多文件?** 多半是 racy/smudged 条目:窗口期内 mtime 相同的条目被迫内容核对(`read-cache.c:344-348,434-439`),或 untracked cache 被失效(`dir.c:4020`)。
2. **index v2/v3/v4 有什么区别?** v3 增加扩展 flags 位;v4 增加相邻条目路径前缀压缩(`read-cache.c:1808-1815,2674-2696`);默认写 v2,`index.version` 可覆盖(`read-cache.c:2859-2864`)。
3. **`git add` 到底做了什么?** `add_files_to_cache()` 用 `run_diff_files(DIFF_RACY_IS_MODIFIED)` 找 worktree vs index 差异,对每条 `add_file_to_index()` 写 blob 并更新条目(`read-cache.c:4026-4069`);随后 `git commit` 时 `cache_tree_update()` 建树(`builtin/commit.c:1111`)。
4. **commit 后 index 会变吗?** 会:写 index 后更新 `istate->timestamp`(`read-cache.c:3102-3103`),cache-tree 一并写回 TREE 扩展。
5. **为什么 `git status` 对 untracked 有时只显示目录?** `status.showUntrackedFiles=normal` 时 `DIR_SHOW_OTHER_DIRECTORIES` 触发目录级报告(`wt-status.c:816-818`,`dir.c:2044-2070`);`-uall` 才展开。
6. **merge 冲突时 index 里有什么?** 同名路径最多 3 个条目,stage 1/2/3,`ce_stage()` 由 flags 12-13 位表示(`read-cache-ll.h:34-37`);status 记成 `stagemask`(`wt-status.c:785-793`)。
7. **`--assume-unchanged`/skip-worktree 为什么能跳过扫描?** `ie_match_stat()` 开头对 `CE_VALID`/skip-worktree 直接返回 0(`read-cache.c:401-406`)。
8. **sparse index 和 sparse checkout 是一回事吗?** 不是:checkout 决定磁盘上有哪些文件;index 折叠决定 index 里有哪类条目(目录条目),且仅限 cone 模式(`sparse-index.c:160-206`)。
9. **index 末尾的哈希平时校验吗?** 读路径默认跳过(`verify_index_checksum=0`,`read-cache.c:1709,1729-1730`),`git fsck` 可强制;但写路径始终计算(`read-cache.c:3090-3091`)。
10. **fsmonitor 如何让 status 更快?** 条目带 `CE_FSMONITOR_VALID` 时比对直接返回 0(`read-cache.c:405-406`),untracked cache 也可信任其 valid 位(`dir.c:2534-2538`)。

## 10. 深挖建议

1. **split index 与 skip-hash**:`CACHE_EXT_LINK`(`read-cache.c:2995-3010`)共享基索引;`index.skipHash` 允许省略尾部哈希(`read-cache.c:2844-2845`)——与本文校验叙述互补。
2. **nsec 的双刃剑**:`USE_NSEC` 下 racy 判定精确到纳秒(`read-cache.c:357-362`),但多数文件系统 nsec 不可靠,故默认编译关闭——可实验 `core.checkStat`/`core.trustCtime`(`statinfo.c:71-73,83-89`)。
3. **smudge 的边界条件**:`ce_smudge_racily_clean_entry()` 长注释(`read-cache.c:2595-2619`)是一段微型证明,值得逐行推演 `frotz/nitfol` 时序。
4. **`add -p` 的索引副线**:交互补丁在锁定的临时 index 上操作并重建 cache-tree(`builtin/commit.c:405-434`),可对比 `COMMIT_NORMAL` 路径。
5. **status 的性能观测**:trace2 已埋点(`status/worktrees`、`index/do_write_index`、`s->untracked_in_ms`,`wt-status.c:810,848-849`;`read-cache.c:3150-3153`),可实测三方对比各占比。

## 附:写作要点速查表

| 事实 | 锚点 |
|---|---|
| DIRC 魔数/头结构/版本上下限 | read-cache-ll.h:12,13-17,19-20 |
| 磁盘 entry 字段(ctime..size) | read-cache.c:1681-1698 |
| in-memory cache_entry/flags | read-cache-ll.h:22-32,34-37,70-75 |
| v4 前缀压缩(读/写) | read-cache.c:1808-1815,1833-1847 / 2674-2696 |
| verify_hdr(魔数+哈希) | read-cache.c:1715-1744 |
| do_write_index(头/降版/扩展/收尾) | read-cache.c:2820-3110(降版 2862-2864;smudge 2916-2917;sdir 3061-3064;哈希 3090) |
| do_read_index(mmap/多线程/timestamp) | read-cache.c:2225-2324(2313-2314) |
| is_racy_stat / is_racy_timestamp | read-cache.c:353-366,368-373 |
| ie_match_stat racy→查内容 | read-cache.c:418-442 |
| ce_smudge_racily_clean_entry | read-cache.c:2574-2622(2620 置 0) |
| match_stat_data(逐 stat 字段) | statinfo.c:64-102 |
| cache_tree_fully_valid / update_one | cache-tree.c:278-292,299-515(336-339 早退) |
| cache_tree_update / commit 取树 oid | cache-tree.c:517-548;builtin/commit.c:1111,1938 |
| cache_tree_invalidate_path | cache-tree.c:159-163 |
| status 收集顺序 | wt-status.c:865-888 |
| worktree diff(run_diff_files) | wt-status.c:639-664(662) |
| index-vs-HEAD(DIFF_INDEX_CACHED) | wt-status.c:666-710(708) |
| untracked 收集与目录剪枝 | wt-status.c:806-850;dir.c:1966-2090,2698-2793 |
| untracked cache 有效性/失效 | dir.c:2523-2569,2972-3030,4020 |
| sparse 折叠/展开 | sparse-index.c:208-265,95-136,330-455,469-473 |
| add 刷新与暂存路径 | builtin/add.c:124-160,578,675;read-cache.c:4026-4069 |
