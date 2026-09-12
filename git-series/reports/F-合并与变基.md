# F 章：Git 合并与变基内部深度调研（merge-ort / sequencer）

> 源码版本：git commit `47ce805`（2026-09-11，shallow clone）。所有行号以该 commit 为准，
> 标注格式为 `仓库相对路径:行号`，均经 grep/Read 实际核对。
> **版本要点**：本 commit 中 `merge-recursive.c` 已从源码树**彻底删除**（2.50 开始分步移除，
> 见 `Documentation/RelNotes/2.50.0.adoc:112`；2.34 起 ort 成为默认策略，
> 见 `Documentation/RelNotes/2.34.0.adoc:18`）。旧引擎只能通过兼容层与历史视角考察。

---

## 1. 全景：一次 merge 的分层

```
 git merge -s ort (builtin/merge.c:800-838)
      │
      ▼
┌────────────────────────────────────────────────────────────────────┐
│ L0  merge_incore_recursive()        merge-ort.c:5429               │
│     └ merge_ort_internal()          :5313  多 merge base 时递归归并  │
│        （每个虚祖先合并 call_depth++，不落工作区，冲突标记加倍 :5347）    │
│        └ merge_ort_nonrecursive_internal()  :5245  ← 三树单次入口     │
├────────────────────────────────────────────────────────────────────┤
│ L1  树级 diff：collect_merge_info()  :1738                          │
│     traverse_trees 同时遍历 base/side1/side2 三棵树，                  │
│     回调 collect_merge_info_callback :1259 一次收集全部路径状态         │
│     → 全部装入内存 strmap opt->priv->paths        :354               │
├────────────────────────────────────────────────────────────────────┤
│ L2  rename 检测：detect_and_process_renames()  :3553                 │
│     对 side1/side2 各跑一次 diffcore_rename_extended()               │
│     (diffcore-rename.c:1380)：精确→basename→不精确矩阵三级流水        │
│     + 目录级 rename 聚合(:3597-3632) + rename 应用 process_renames   │
├────────────────────────────────────────────────────────────────────┤
│ L3  内容三路合并：process_entries→process_entry :4498/:4079          │
│     handle_content_merge :2179 → merge_3way :2107                   │
│     → ll_merge (merge-ll.c:406) → xdl_merge (xdiff/xmerge.c:684)    │
├────────────────────────────────────────────────────────────────────┤
│ L4  树写回：process_entries 逆序遍历自底向上写子树                     │
│     write_completed_directory :3897 → write_tree :3839              │
│     得到 result->tree（仅对象库，工作区/索引未动！）                    │
└────────────────────────────────────────────────────────────────────┘
      │
      ▼  merge_switch_to_result()  merge-ort.c:4927   ← 唯一的"落地"时刻
      ├── checkout()               :4936→:4604  unpack_trees 双树切换工作区
      ├── record_conflicted_index_entries() :4947→:4648  写 stage>0 索引项
      └── 写 AUTO_MERGE 伪引用     :4960  （供 mergetool/git restore 使用）
```

关键分层语义：**merge 计算与工作区切换完全解耦**——`merge_incore_*()` 承诺
"working tree and index are untouched"（merge-ort.h:99-101、121）。cherry-pick/rebase
序列可以只算 `result->tree` 干净与否，中途失败也不留半成品（对比旧引擎边算边写）。

## 2. merge-ort 专节：批处理引擎

### 2.1 名字与定位

- `ort` = "Ostensibly Recursive's Twin"，注释自嘲没起成更好的缩写（merge-ort.c:2-15）。
- 设计目标：`-s recursive` 的即插即用替换（merge-ort.c:4-10）。
- 旧引擎死后，`recursive` 名字被**别名**到 ort：`get_strategy()` 里
  `default_strategy=="ort" && name=="recursive"` 时直接改用 ort（builtin/merge.c:180-184）；
  "recursive"/"subtree"/"ort" 三种拼写在 `try_merge_strategy()` 里走同一条
  `merge_ort_recursive()` 路径（builtin/merge.c:800-838）。
- 兼容旧 API 的壳：merge-ort-wrappers.c:33（`merge_ort_nonrecursive`）、:46（`merge_ort_recursive`）。

### 2.2 核心数据结构（全部内存态）

`struct merge_options_internal`（merge-ort.c:318-421）：

- `paths`（:354）：**全仓库相关路径的主索引**，key 是完整路径串，value 指向
  `merged_info`（干净）或 `conflict_info`（含三个 stage 的 `stages[3]`/filemask/dirmask）。
  key 顺带做**字符串驻留**：所有路径比较退化为指针比较（:322-334）。
- `conflicted`（:367）：`paths` 中仍冲突条目的子集，避免收尾时再全量扫描（:358-366）。
- `pool`（:377）：mem_pool 统一分配/释放，注释明说"provides a nice speedup"（:370-376）。
- 三方统一编码 `enum merge_side { MERGE_BASE=0, SIDE1=1, SIDE2=2 }`（:75-79），
  配合 `filemask/dirmask` 位运算（collect_merge_info_callback:1281-1294）。

### 2.3 为什么快（与 recursive 的架构差异）

1. **一次树 diff，全程内存**。旧引擎对每个目录递归调用且中间结果频繁物化；
   ort 用 `traverse_trees` 三树同扫（collect_merge_info:1738，回调 :1259，n 恒为 3，:1312-1314），
   所有判断先在 strmap 里完成，最后才一次性写树（process_entries:4498）。
2. **平凡合并大量短路**。三树全等→直接以 base 收案（:1353-1359）；
   side1==side2→取 side1（:1368-1374）；side1==base→取 side2（:1383-1390）；
   反之亦然（:1393-1400）。目录整体未动可整棵跳过（"possible_trivial_merges"，
   注释 :91-113；延迟重扫 handle_deferred_entries:1564）。
3. **rename 缓存跨 pick 复用**。cherry-pick/rebase 序列中相邻提交的
   base/side 树常相同，ort 把本轮三棵树记进 `renames->merge_trees[3]`
   （merge_incore_nonrecursive:5420-5422），下轮 `merge_check_renames_reusable()`
   （:5155）判断哪一侧缓存仍有效（`cached_pairs_valid_side`，:233-242），
   命中则 `use_cached_pairs()` 直接注入 rename 结果（:3298）。
4. **先测 rename 再重启合并**。`redo_after_renames` 优化（:287-306）：
   rename 检测完成后若能解锁更多平凡目录合并，就清空内部状态从 redo 标签重来
   （merge_ort_nonrecursive_internal:5260 `redo:` + :5280-5285），
   因为第二轮 collect_merge_info 可跳过更多子树，比把每条路径送进
   process_entry 便宜。
5. **无并行**。全文件 grep 无 thread/parallel；速度来自算法剪枝与内存驻留，
   不是多线程。真正的异步只有 promisor 场景的批量预取
   （prefetch_for_content_merges:4450）。
6. **mergeability_only 模式**（merge-ort.h:86）：只判定能否干净合并，
   跳过 blob/树对象写出（process_entries:4509-4510、process_entry:4342-4343，
   process_entries 在发现冲突时提前 return :4570-4574）。

### 2.4 冲突表示与收尾

- `process_entry()` 按 `filemask` 位型分发：`>=6` 走内容合并或 add/add
  （:4335-4373）；`3/5` 是 modify/delete（:4374-4421）；`2/4` 单侧新增（:4422-4427）；
  `1` 双侧删除（:4428-4435）。冲突消息即在此发出（`CONFLICT (content)` :4369-4372）。
- D/F 冲突（同名目录/文件）在此阶段依靠"目录先写完再处理文件"的逆序
  遍历（process_entries:4537-4545 注释、:4548）自然消解或改道
  （process_entry:4100-4167）。
- `merge_switch_to_result()`（:4927）才触碰真实仓库：checkout（:4936）、冲突项写索引
  （record_conflicted_index_entries:4648，把 stage 1/2/3 追加到索引尾部再整体排序，
  :4728-4759）、写 AUTO_MERGE（:4960）。
- `merge_finalize()`（:4979）只是释放 `result->priv`；与"立即切换"模型不同，它必须在
  **不调用** switch 时也由调用方显式触发（merge-ort.h:165-167）。

### 2.5 多 merge base 的递归归并（行为差异点）

`merge_ort_internal()`（:5313）：无公共祖先时用空树当虚拟祖先（:5336-5343）；
多个 base 时两两合并成虚拟 commit（循环 :5355-5387），期间 `call_depth++`（:5360）、
分支标签固定为 "Temporary merge branch 1/2"（:5371-5372）；call_depth 会把冲突
标记尺寸翻倍（process_entry:4347 → merge_3way:2125 → ll_merge:445）以免内层
标记污染外层。最后以归并出的祖先树对真实两树做一次非递归合并（:5390-5395）。

### 2.6 merge-recursive 的后事（简）

- 2.34 默认切 ort（Documentation/RelNotes/2.34.0.adoc:18）；2.50 开始分步移除
  （Documentation/RelNotes/2.50.0.adoc:112）；本 commit 中 `merge-recursive.c`
  文件已不存在。
- 残留遗迹：`merge_recursive_config()` 名字保留于 merge-ort.c:5453（读
  merge.verbosity/diff.renamelimit/merge.directoryrenames，:5457-5481）；注释
  "Originally from merge_recursive_internal()"（:5311）等。
- 替换是性能与正确性双驱动：性能即 §2.3 的五项（旧引擎全无）；正确性如目录
  rename 默认冲突化 `MERGE_DIRECTORY_RENAMES_CONFLICT`（:5503）、
  RelNotes 2.50.0.adoc:224 记录 recursive/ort 在角标用例同崩溃后修复收敛于 ort。

## 3. rename 检测专节：diffcore-rename 三级流水

入口 `diffcore_rename_extended()`（diffcore-rename.c:1380），调用方 merge-ort
在 `detect_regular_renames()`（merge-ort.c:3429）里对两侧各调一次。
判定阈值：`MAX_SCORE 60000.0`、`DEFAULT_RENAME_SCORE 30000`（即 50%，
diffcore.h:39-40）。

**第 0 级：精确 rename**。`find_exact_renames()`（diffcore-rename.c:347，
调用 :1470）：按 blob oid 建 hashmap（`insert_file_table` :326，hash 即 oid :264-274），
`find_identical_files()`（:276）同 oid 配对；多个候选时优先未用过的源、
再优先 basename 相同（:303-313，`basename_same` :75），最多试 100 个（:283、:316）。

**第 1 级：basename 快路径**。`find_basename_matches()`（:903，调用 :1523）：

```c
/* diffcore-rename.c:910-913（节选） */
 * When I checked in early 2020, over 76% of file renames in linux
 * just moved files to a different directory but kept the same
 * basename.  gcc did that with over 64% of renames, gecko did it
 * with over 79%, and WebKit did it with over 89%.
```

实现：给 source/dest 各建 `basename → 唯一下标` 的 strintmap（:959-988），
basename 唯一匹配上之后仍要过内容相似度，但阈值被**抬高**：
`min_basename_score = minimum_score + 0.5*(MAX_SCORE-minimum_score)`
（:1495-1504，可由环境变量 GIT_BASENAME_FACTOR 调权 :1497-1501），
即默认 50%→75%，用更高精度换取敢跳过 NxM 矩阵的底气。

**第 2 级：不精确矩阵**。`too_many_rename_candidates()`（:1086）按
`num_destinations * num_sources > rename_limit^2`（:1094-1109）决定是否放弃
不精确检测；候选配对只保留每个 dst 的前 `NUM_CANDIDATE_PER_DST=4` 名
（:1064、record_if_better:1065），按 score 降序、同分时 name_score 高者胜
（score_compare:242-256）。

**相似度怎么算**：`estimate_similarity()`（:132）

- 非常规文件直接 0 分（:158-159）；
- 先只查大小，`max_size*(MAX_SCORE-min) < delta_size*MAX_SCORE` 提前淘汰（:179-192）；
- 再 `diffcore_count_changes()`（diffcore-delta.c:169）：把文件按 64 字节窗口
  滚动哈希成**跨度直方图**（spanhash，:162 `hashval=(accum1+accum2*61)%HASHBASE`，
  add_spanhash:82），两幅直方图归并扫描得"可复用字节数 src_copied"（:212-221）；
- 分数 = `src_copied * MAX_SCORE / max_size`（diffcore-rename.c:212）。

**与 pack-objects delta 搜索（D 章）对照**：

| 维度 | rename 相似度 (diffcore-delta.c) | delta 搜索 (builtin/pack-objects.c:2808 try_delta) |
|------|--------------------------------|--------------------------------------------------|
| 目标 | 输出 0-60000 相似度分数 | 输出二进制 delta 指令流 |
| 指纹 | 64B 窗口滚动哈希的字符直方图 | 无指纹，直接对候选源算真 delta |
| 剪枝 | 大小差比例阈值 (:191) | 大小/深度/`trg_size<src_size/32` (:2845-2851) |
| 候选集 | 全源集合矩阵，basename 先收敛 | 类型+size 排序后滑窗近邻 (type_size_sort:2654) |
| 相同点 | 都是"先廉价过滤，后昂贵比较"的瀑布模型 | 同左 |

**merge-ort 侧的 rename 消费**：`detect_and_process_renames()`（merge-ort.c:3553）→
目录级 rename 由文件计数投票得出（`dir_rename_count` :167，provisional 计算 :2467，
冲突调解 :3606），再把文件级与目录级合并成 combined 队列排序（collect_renames，
:3618-3628）交给 `process_renames()`（:2913）改写 `conflict_info` 的 pathnames/stages。

## 4. xdiff 冲突专节：三路合并的扫描与冲突块

`xdl_merge()`（xdiff/xmerge.c:684）四步：

1. base vs side1、base vs side2 各做一次完整 diff（:695-699 `xdl_do_diff`），
   再 change_compact+build_script 得到两个"补丁脚本" xscr1/xscr2（:701-709）。
   一侧无改动→整个文件直接抄另一侧（:711-724），连冲突扫描都省了。
2. **双指针同步扫描两个补丁脚本**（`xdl_do_merge` :505，主循环 :545-619）：
   - 两个 hunk 不重叠（`xscr1->i1+chg1 < xscr2->i1`，:548；镜像 :563）→
     记为 mode=1/2 的非冲突块（`xdl_append_merge` :50，重叠时并块并把 mode 降为 0 冲突，:56-61）；
   - 重叠则看 `level`：MINIMAL 下必冲突；EAGER+ 下两侧改动**逐行相同**则不冲突
     （xdl_merge_cmp_lines :96，判定 :578-583）；否则合成一个 mode=0 冲突块，
     并按两侧起止的几何关系扩张 chg0/chg1/chg2（:585-609）。
   - level 语义注释在 :497-504（0=全冲突…3=zealous+alnum 判断）。
3. **冲突块精修**：默认 level=XDL_MERGE_ZEALOUS（merge-ll.c:132）触发
   `xdl_refine_conflicts()`（:363）：把每个冲突块两侧的文本**再各自 diff 一次**（:390），
   只让真正不同的行留在冲突区，相同改动升级为 mode=4（:398-403）；
   相邻冲突间隔 ≤3 行则合并（xdl_simplify_non_conflicts :467，阈值 :485）。
   ZEALOUS_DIFF3 风格改用只削头尾的 `xdl_refine_zdiff3_conflicts`（:334，分派 :655-656）。
4. **输出**：`xdl_fill_merge_buffer()`（:283）对 mode!=0 块调用
   `fill_conflict_hunk()`（:196）逐字节拼装：

```c
/* xdiff/xmerge.c:217-269（有删节） */
    memset(dest + size, '<', marker_size);      /* :217  <<<<<<< */
    ...
    size += xdl_recs_copy(xe1, m->i1, m->chg1, ...);  /* :230 我方 */
    if (style == XDL_MERGE_DIFF3 || style == XDL_MERGE_ZEALOUS_DIFF3) {
            memset(dest + size, '|', marker_size);   /* :238 ||||||| */
            size += xdl_orig_copy(xe1, m->i0, m->chg0, ...); /* :249 base */
    }
    memset(dest + size, '=', marker_size);      /* :256 ======= */
    size += xdl_recs_copy(xe2, m->i2, m->chg2, ...);  /* :264 对方 */
    memset(dest + size, '>', marker_size);      /* :269 >>>>>>> */
```

标记宽度 `DEFAULT_CONFLICT_MARKER_SIZE=7`（xdiff/xdiff.h:144），可被
`conflict-marker-size` 属性放大（merge-ll.c:431-438）。CRLF 探测决定是否补 `\r`
（is_eol_crlf:157、is_cr_needed:181）。返回值即冲突块数（xdl_cleanup_merge:81-94），
>0 映射为 `LL_MERGE_CONFLICT`（merge-ll.c:145）。

## 5. ll_merge：内容级驱动分发

`ll_merge()`（merge-ll.c:406）是 merge-ort（merge_3way:2161）、rerere（rerere.c:612）、
合并不一致时的 ll-merge 管道的公共内容入口：

- 先查 `.gitattributes`：`merge` 属性（:429-430）+ `conflict-marker-size`（:431）。
- 驱动查找 `find_ll_merge_driver()`（:363）：属性 `set`→text（:371-372）、`unset`→binary
  （:373-374）、未指定→`merge.default`（:375-380）、具名→用户自定义
  （`[merge "name"] driver=...`，注册为外部命令 `ll_ext_merge`，:306）。
- 内建三驱动表（:171-175）：`binary`/`text`/`union`。
- `ll_xdl_merge()`（:103）：任一 blob 超大或疑似二进制→退化 `ll_binary_merge`
  （:117-129）；后者虚拟祖先场景取 base 内容（:76-78），否则按 -X ours/theirs 取
  src1/src2 并报 `LL_MERGE_BINARY_CONFLICT`（:80-93）。
- `union` 驱动 = 强制 `XDL_MERGE_FAVOR_UNION`（:149-166），冲突两行都保留。
- 虚拟祖先递归时可切换到驱动的 `recursive` 变体（:441-443）；
  renormalize 时三个 blob 先过清洗规则（:423-427）。

## 6. sequencer 专节：rebase/revert/cherry-pick 的公共引擎

### 6.1 本质：rebase = 逐个 cherry-pick

`builtin/rebase.c` 只负责选区与落地；真正的提交重放全在 sequencer.c：

- 三种操作共享一个 todo 引擎；交互式 rebase 的每条命令就是 `pick <sha> <subject>`，
  非交互 rebase 也是先生成脚本再执行。命令字表 `todo_command_info[]`：p/revert/
  e edit/r reword/f fixup/s squash/x exec/b break/l label/t reset/m merge/u
  update-ref/d drop（:1822-1840）。
- todo 生成：`sequencer_make_script()`（:6256）按 rev walk 写出 pick 行；
  `complete_action()`（:6658）串起 update-ref 注入、autosquash 重排
  （todo_list_rearrange_squash:6794，调用 :6685）、编辑器、onto 检查。
- 单个提交的应用核心 `do_pick_commit()`（:2283）：revert 时 `base=commit, next=parent`
  （:2392-2396），pick 时 `base=parent, next=commit`（:2401-2407）——**都归约成一次三方合并**；
  merge 提交按 `-m` 选 mainline 父（:2334-2350）；`allow_ff` 且目标父就是 HEAD 时直接
  快进，不重造提交（:2365-2377，fast_forward_to:646 用**引用事务**更新 HEAD，:660-665）；
  默认策略走 ort：`do_recursive_merge()`（:746）→ `merge_incore_nonrecursive(base_tree,
  head_tree, next_tree)`（:782）+ `merge_switch_to_result`（:792）；仅当用户指定其他
  strategy 才 spawn 外部命令 try_merge_command（:2472-2496）；冲突时写 `CHERRY_PICK_HEAD`/
  `REVERT_HEAD` 伪引用（:2505-2514）、打印 "could not apply"（:2516-2521）、顺手
  `repo_rerere()`（:2522）。
- 主循环 `pick_commits()`（:5091）：`while (todo_list->current < todo_list->nr)`
  （:5111），每步先 `save_todo()` 把剩余 todo 落盘（:5116→:3691，即"从文件头删
  已完成行"），再按命令分派 pick/exec/label/reset/merge/update-ref（:5149-5194），
  成功才 `todo_list->current++`（:5213）。rebase 进度写 msgnum/end（:5120-5133）。
  全部完成后：按 `head-name` 把分支引用从 orig-head 快进式更新到最终 HEAD
  （:5220-5257，同样走 refs_update_ref 引用事务），跑 post-rewrite 钩子
  （:5281-5298），apply autostash（:5299），最后删整个 sequencer 目录（:5320）。

### 6.2 中断恢复：.git/sequencer/* 状态文件

```c
/* sequencer.c:68-73（原样） */
static GIT_PATH_FUNC(git_path_seq_dir, "sequencer")
static GIT_PATH_FUNC(git_path_todo_file, "sequencer/todo")
static GIT_PATH_FUNC(git_path_opts_file, "sequencer/opts")
static GIT_PATH_FUNC(git_path_head_file, "sequencer/head")
static GIT_PATH_FUNC(git_path_abort_safety_file, "sequencer/abort-safety")
```

交互式 rebase 另有一整套 `.git/rebase-merge/*`：git-rebase-todo / done
（:82、:92，"处理过的行从 todo 头部移到 done 尾部" :76-81）、msgnum/end
（:97、:102）、message / message-squash / message-fixup（:107-124）、
author-script（:135）、amend、stopped-sha、patch、rewritten-list、
squash-onto（:169）等。

- 写入：`save_opts()` 把 no-commit/edit/allow-empty 等以 config 格式写进
  `sequencer/opts`（:3733-3745）；`create_seq_dir()` mkdir（:3473，:3505），
  已有未完成序列时报 "cherry-pick/revert is already in progress"（:3482-3503）。
- 解析：`todo_list_parse_insn_buffer()`（:2912）逐行 `parse_insn_line`，
  失败行变成 TODO_COMMENT+1 占位不中断整体（:2931-2941）。
- **continue**：`sequencer_continue()`（:5554）→ 读 opts/todo（:5562-5582）→
  rebase 场景先 `commit_staged_changes()`（:5350，把用户解决冲突后的暂存
  amend/commit 上去）→ 继续 `pick_commits`（:5608 附近调用）。
  非序列的单步冲突靠 `CHERRY_PICK_HEAD` 存在性走 `continue_single_pick`（:5323）。
- **abort**：`sequencer_rollback()`（:3577）读 `sequencer/head` 回退
  （:3584-3610）；防误伤检查 `rollback_is_safe()`：abort-safety 文件里的
  期望 HEAD 与当前 HEAD 不同就拒绝回卷（:3517-3539，告警 :3612-3615）。
- **skip**：`sequencer_skip()`（:3626）验证对应 *_HEAD 存在 + rollback 安全
  （:3651-3671）后 reset --merge 再 continue（:3673-3678）。

### 6.3 为什么 rebase 后 hash 全变

提交对象内容 = (tree, parent[], author, committer, message) 的哈希。
rebase 重放时：parent 指向新的基底（first parent 变了）；committer 时间戳
重写（do_commit 路径生成新提交）；重放过程的树可能因冲突消解与上下文
合并而与原树不同。三者任一变化 ⇒ 全新 oid。且原提交不动——rebase 只是把
分支引用"换指"到新链上（pick_commits 尾部 refs_update_ref，:5245-5256），
旧提交成为不可达对象等待 gc（呼应 D 章）。这就是 `rewritten-list`
（:161）存在的意义：记录 old→new 映射给 post-rewrite/notes 复制用。

## 7. rerere 专节：冲突签名与重放

- 存储：`.git/rr-cache/<conflict-id>/preimage|postimage`（rerere_path:95-106，
  目录 `rr-cache` :856）。开关 `rerere.enabled`（:849-873，无配置但目录存在即自动开启 :866-867）。
- 冲突签名（conflict ID）：`handle_conflict()`（:340）逐行识别 `<<<<<<< / ||||||| / ======= /
  >>>>>>>` 标记（is_conflict_marker_line，merge-ll.c:472），归一化两件事：**丢弃 diff3 的
  base 段**（:386-387 RR_ORIGINAL 直接 discard）、**两侧按字典序交换**（:371-372 strbuf_swap），
  然后 `hash(one + NUL + two + NUL)`（注释 :398-406；哈希注入 :379-382）。归一化保证
  "同一逻辑冲突换个分支名/换个顺序"仍命中同一条目。
- 登记与重放主流程 `do_plain_rerere()`（:795，入口 repo_rerere:900）：find_conflict（:534）
  扫索引中的未合并路径（:803）→ handle_file 算签名（:822）→ 建目录与 id（:830-834）→
  每条路径 do_rerere_one_path（:718）：用户已手工解决（文件无冲突了）→ 把解决结果存为
  **postimage**（:730-739）；否则遍历该 ID 的各 variant 找 pre+post 齐全的记录尝试**重放**
  （:747-757）：`try_merge()`（:596）把 postimage 当"别人已经改好的另一侧"与当前冲突文件做
  ll_merge 三方合并（:612，注释明确尊重自定义驱动），成功则把结果写回工作区文件（:666-672）、
  touch postimage 助 gc（:661），并由 `update_paths()` 自动 `git add` 暂存（:682-699）。
- 状态簿记在 `.git/MERGE_RR`（setup_rerere 锁写 :888、read_rr:200、write_rr:245），
  即"路径→最近一次冲突 ID"的映射，跨进程延续。
- 接入点：do_pick_commit 冲突分支（sequencer.c:2522）、builtin/merge 等均在冲突后调用 repo_rerere。

## 8. builtin/rebase.c：主控速览

- 两代后端枚举 `REBASE_APPLY` / `REBASE_MERGE`（:57-58）；现代默认全走 sequencer
  （run_specific_rebase:742）。选项结构 `struct rebase_options`（:88-150）：
  upstream/onto/state_dir/fork_point（:133，默认 -1 未定义，:150）。
- 选区：`upstream..orig_head`（:1907-1912）；`--onto` 缺省即 upstream（:1751-1752）；
  `--keep-base` 用 `A...B` 的 merge base（:1745-1750）。
- `--fork-point`：`get_fork_point()`（commit.c:1087）在上游 reflog 里找分支真正的分叉点
  （防上游强推后选错 base）；无参数 rebase 默认开启（:1658-1660），配置 rebase.forkPoint
  （:845），结果存入 `restrict_revision` 缩小重放集（:1776-1778）。
- 快进短路：`can_fast_forward()`（:897）检查 branch_base==onto、单 merge base、线性历史
  （`is_linear_history`），成立且未 --force 时直接 checkout_up_to_date 返回 "up to date"
  （:1804-1826）。落地前置：pre-rebase 钩子（:1838-1843）、require_clean_work_tree
  （:1788-1792）、autostash 创建（:1783-1785）。
- 真正执行前 detach HEAD 到 onto（:1875-1893）；branch_base==orig_head 时整体 fast-forward
  即可（:1899-1905），否则 run_specific_rebase（:1916-1917）进 sequencer。

## 9. 设计动机

1. **为什么重写合并引擎**：性能上，ort 把 O(路径×递归) 的多次树遍历收敛为单次三树扫描 +
   strmap 批处理（§2.3），并用 basename 启发式把 rename 检测从 NxM 降到近似线性（§3）；
   正确性上，目录 rename 默认冲突化（MERGE_DIRECTORY_RENAMES_CONFLICT，:5503）、冲突消息集中到
   path_messages 由调用方决定呈现（merge-ort.h:30-36）——旧引擎的输出直接往 stderr 上泼，
   rebase 时还得靠 buffer_output=2 兜底（sequencer.c:768-769）。策略选择权也在引擎内：
   diff.algorithm 只对 UI 合并生效（:5482-5489）。
2. **为什么 rebase 不改对象只换指针**：对象库是纯内容寻址、不可变的；"重写历史"的成本其实
   只有重放计算，落地动作只是一个 refs 事务（pick_commits 尾部 refs_update_ref :5245，
   fast_forward_to 的 ref_store_transaction_begin :660-665）——与 B 章引用事务完全同源：
   一次事务、要么整体生效要么不动，保证 rebase 中途崩溃后分支引用不会指向半新半旧的链。
   旧链仅失去引用庇护，交给 gc。
3. **merge commit 的双亲与 DAG**：merge 提交的两个 parent 来自 `HEAD` 与被合并分支，正是
   "递归虚祖先"的物化：多个 merge base 时先在 call_depth 里两两合并 base
   （merge_ort_internal:5355-5387）造出虚拟提交（make_virtual_commit:5016，只有 tree+标签、
   不进对象库），最终真实 merge commit 的双亲结构把"哪些冲突已在虚祖先里解决过"的信息永久
   写进 DAG——这是 Git 能"记住"合并历史、下次合并少冲突的原因。
4. **sequencer 的文件态而非内存态**：长序列随时可能中断数天，todo/opts/head 全部落盘（§6.2），
   状态机由"文件存在性 + 伪引用（CHERRY_PICK_HEAD、REVERT_HEAD、REBASE_HEAD——
   write_rebase_head:1712）+ abort-safety 校验"构成，与 C 章"索引即状态机"一脉相承。

## 10. FAQ 素材

1. **Q: merge-ort 比 recursive 快在哪？** 一次三树遍历（merge-ort.c:1259）+ 平凡合并剪枝
   （:1353-1400）+ 全程内存 strmap（:354）+ rename 缓存跨提交复用（:5420-5422）+ rename 后重启
   解锁更多剪枝（:5280-5285）。无多线程。
2. **Q: `-s recursive` 现在还等价于过去吗？** 不。名字被别名到 ort（builtin/merge.c:180-184），
   merge-recursive.c 在本 commit 已删除（RelNotes 2.50）。
3. **Q: `<<<<<<<` 标记是谁打的？** xdiff/xmerge.c fill_conflict_hunk 的
   `memset(dest+size,'<',marker_size)`（:217/238/256/269），宽度默认 7（xdiff/xdiff.h:144），
   虚拟祖先递归时 ×2 加长（merge-ort.c:4347）。
4. **Q: 两侧改动相同时为什么有时不冲突？** xdl_do_merge 对重叠块做逐行相等检查
   （xmerge.c:578-583），zealous 级还会把冲突块二次 diff 只留差异行（:363-430）。
5. **Q: rename 检测的 50% 是什么？** DEFAULT_RENAME_SCORE=30000/60000（diffcore.h:39-40）；
   basename 快路径同分重命名要求更高（50%→75%，diffcore-rename.c:1503-1504）。
6. **Q: 为什么 rename 会被误判/漏判？** 相似度是 64B 窗口字符直方图的重合度
   （diffcore-delta.c:162-221），大改小文件天然低分；`rename_limit²` 超限直接放弃不精确检测
   （diffcore-rename.c:1094-1109）。
7. **Q: rebase 中断后 Git 靠什么知道"上次做到哪"？** `.git/rebase-merge/git-rebase-todo`（剩余）+
   `done`（已完成）（sequencer.c:82/:92），外加 stopped-sha、amend、author-script（:149/:144/:135）。
8. **Q: `git rebase --abort` 会不会把我的手工提交卷没了？** 有 abort-safety 防线：期望 HEAD 与
   当前 HEAD 不一致时拒绝回卷只警告（sequencer.c:3517-3615）。
9. **Q: rerere 怎么识别"同一个冲突"？** 签名 = hash(归一化 side1 + NUL + side2 + NUL)：丢 base 段、
   两侧按字典序排序后哈希（rerere.c:371-382，注释 :398-406），与路径、分支名无关。
10. **Q: 二进制文件冲突时工作区里是什么？** ll_binary_merge 直接搬运 src1（或 -X 选 src2），
    返回 LL_MERGE_BINARY_CONFLICT（merge-ll.c:80-93），merge-ort 打印
    "Cannot merge binary files"（merge-ort.c:2164-2168）。

## 11. 深挖线索

1. **merge-ort 对 rebase 的专项优化链**：从 merge_trees 记录（merge-ort.c:5420）
   → merge_check_renames_reusable（:5155）→ cached_pairs/use_cached_pairs
   （:252/:3298）→ redo_after_renames 重启（:306/:5260）逐行走一遍，
   解释 t6423 系列测试为何能在 100k 文件仓库上验证性能。
2. **conflict_info 的生命周期**：setup_path_info 挂入 paths（:1422）→
   process_renames 改写 stages/pathnames（:2913）→ process_entry 判定 clean
   （:4079）→ record_conflicted_index_entries 落 stage 1/2/3（:4741-4749）。
   对照 `git ls-files -u` 的输出。
3. **xdl_refine_conflicts 的"块中块"递归结构**（xmerge.c:384-425）：冲突块
   内部再跑一次完整 diff，链表原地生长——评估其对病态输入（大量近似重复行）
   的复杂度风险。
4. **rerere variant 机制**：同一 conflict ID 下多个 variant（assign_variant:80，
   scan_rerere_dir:128）解决"同 ID 不同解法"的歧义，重放按 variant 轮询
   （do_rerere_one_path:747-757）。
5. **fork-point 的 reflog 取证**：commit.c:1087 get_fork_point 如何用
   upstream 的 reflog 重建"分支可能的真实分叉"，以及 restrict_revision
   如何改变 upstream..orig_head 选区（builtin/rebase.c:1907-1912）。

## 12. 写作要点速查表

| 主题 | 函数/事实 | 位置 |
|------|-----------|------|
| ort 名字来源 / 入口 | "Ostensibly Recursive's Twin"；merge_incore_recursive / _nonrecursive | merge-ort.c:2-15, :5429/:5403 |
| 多 base 归并 | merge_ort_internal（虚祖先、Temporary merge branch） | merge-ort.c:5313, :5371 |
| 单次三树流程 | collect→renames→process_entries（redo 标签） | merge-ort.c:5260-5290 |
| 树遍历回调 / 主结构 | collect_merge_info_callback；paths/conflicted/pool | merge-ort.c:1259; :354/:367/:377 |
| rename 总控 | detect_and_process_renames | merge-ort.c:3553 |
| 内容合并链 | handle_content_merge→merge_3way→ll_merge | merge-ort.c:2179/:2107/:2161 |
| 树写回 / 落地 | process_entries 逆序 + write_tree；switch 三件事 | merge-ort.c:4498/:3839/:4927-4971 |
| rename 相似度 | estimate_similarity + spanhash 直方图 | diffcore-rename.c:132; diffcore-delta.c:169 |
| basename 快路径 | find_basename_matches（76%/64%/79%/89% 统计） | diffcore-rename.c:903, :910-913 |
| 冲突标记 / 扫描 | fill_conflict_hunk；xdl_do_merge 双脚本主循环 | xdiff/xmerge.c:196-280, :545-619 |
| ll_merge 分发 | 属性→驱动表 binary/text/union | merge-ll.c:406/:363/:171 |
| sequencer / rebase 状态 | .git/sequencer/*；.git/rebase-merge/git-rebase-todo+done | sequencer.c:68-73; :82/:92 |
| pick 核心 | do_pick_commit（revert=反着 pick） | sequencer.c:2283, :2392-2407 |
| rebase 主循环 | pick_commits（save_todo→分派→current++） | sequencer.c:5091, :5111-5213 |
| rerere 签名 / 重放 | handle_conflict 归一化哈希；try_merge 复用 ll_merge | rerere.c:340/:371-382; :596 |
| rebase 选区 | fork_point 与 revisions 拼装 | builtin/rebase.c:1776/:1907 |
| 默认策略切换 | ort 替代 recursive（2.34）/删除 recursive（2.50+） | Documentation/RelNotes/2.34.0.adoc:18; 2.50.0.adoc:112 |
