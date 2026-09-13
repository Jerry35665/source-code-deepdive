# J 章 · submodule 与 worktree:两种"引用仓库"的机制

> 源码版本:git commit `47ce805`(shallow clone)。所有 `文件:行号` 均为仓库相对路径,已逐一 grep/Read 核对。
> 本章承接卷一:01 章(tree 对象里的 160000 条目)、02 章(reftable 每工作树独立栈)、C 章(索引)。

---

## 1. 全景:两种"引用仓库"对照

Git 有两处需要"仓库引用仓库"。submodule 是**一个仓库的树里指向另一个仓库的指针**;worktree 是**一个仓库服务多份工作树**。方向相反,机制也不同:

```
SUBMODULE(垂直:父仓库 → 子仓库)             WORKTREE(水平:一个仓库 → 多工作树)

  父仓库 tree                                  $GIT_COMMON_DIR(共享)
  ┌──────────────────────────┐                ├─ refs/        ← refs/heads 等共享引用
  │ tree:                    │                ├─ objects/     ← 共享对象库
  │  lib/     (mode 040000)  │                ├─ config       ← 共享配置
  │  foo.c    (100644 blob)  │                └─ worktrees/<id>/   ← 每工作树目录
  │  lib/     (160000 commit)├──┐                 ├─ gitdir      ──→ 指回工作树/.git
  └──────────────────────────┘  │ 指向子仓库的     ├─ commondir   ──→ 指回 $GIT_COMMON_DIR
  .gitmodules(随树版本化)      │ commit OID       ├─ HEAD        ← 独立引用
  [submodule "lib"]             │                  ├─ index       ← 独立索引
    path = lib                  │                  └─ reftable/   ← 独立引用栈(02 章)
  index: lib ce_mode=160000   │
  .git/modules/lib/ ←子仓库gitdir(可不在工作树内)
  lib/.git (gitfile) ──→ .git/modules/lib

  两层仓库 = 两层状态机:                      一个引用库 = 多个命名空间:
  父记录"指针",子自己 checkout                 refs 按 worktree 路由,共享是默认,
  两边各有 index/HEAD,互不知情                 少数引用(HEAD 等)按 worktree 独立
```

一句话对比:**submodule 把"另一个仓库"当成一个 commit 指针存进 tree,把解引用工作推给用户;worktree 把"同一引用库"共享给多份工作树,把引用读写工作收进路由层**。

---

## 2. gitlink 专节:mode 160000 是什么、不是什么

### 2.1 定义:一个"碰巧存在"的 mode

`object.h` 的注释直接说明了这个模式的来历:

```c
/*
 * A "directory link" is a link to another git directory.
 *
 * The value 0160000 is not normally a valid mode, and
 * also just happens to be S_IFDIR + S_IFLNK
 */
#define S_IFGITLINK	0160000
#define S_ISGITLINK(m)	(((m) & S_IFMT) == S_IFGITLINK)
```
(object.h:115-122)

注意措辞:**0160000 不是任何合法 Unix 文件类型**,它只是"S_IFDIR | S_IFLNK"这个不可能组合被挪用为"目录链接"。这决定了它的通用语义:*任何"指针型条目"*——历史上还承载过 cpio/gitspecial 等——都可落在 160000,而非 submodule 专属(对照卷一 01 章的 tree 条目格式)。

三个关键派生函数把 160000 接进对象系统:

- `object_type()`:gitlink 条目的对象类型是 **OBJ_COMMIT**——tree 里存的是子仓库某个 commit 的 OID,不是 tree(object.h:126-131);
- `create_ce_mode()`:S_ISDIR 或 S_ISGITLINK 一律归一为 S_IFGITLINK(object.h:140-142);
- `canon_mode()`:switch 兜底分支 `return S_IFGITLINK`——**一切未识别 mode 都归为 gitlink**,呼应"任意未解析指针"的定位(object.h:145-153)。

tree 解析时对 mode 做 canon_mode(除非 TREE_DESC_RAW_MODES 保留原始位):tree-walk.c:17(decode_tree_entry)、tree-walk.c:42。

### 2.2 tree 侧与 index 侧的判定

- tree 侧:路径匹配把 gitlink 当目录对待——`'submod/'` 与 `'submod'` 统一匹配(tree-walk.c:890-905,尤其 902 的 `S_ISGITLINK(entry->mode)` 分支);`--recurse-submodules` 的 pathspec 通配也要单独照顾 gitlink(tree-walk.c:1110-1119、1163-1168)。
- index 侧:gitlink entry 在 dtype 判断中等同目录 `DT_DIR`(read-cache.h:36-37),pathspec 匹配同样按目录尾缀处理(read-cache.h:50)。
- 工作树遍历:dir.c 对 index 中的 gitlink 直接返回 DT_DIR(dir.c:2306-2307)。

### 2.3 add:嵌入式仓库如何变成 gitlink

`git add <dir>` 时,dir.c 的 `treat_directory` 注释写明:"如果它看起来像 git 目录且未设 DIR_NO_GITLINKS,就当作 gitlink 处理"(dir.c:1959-1961、1967-1976),判定条件是"非裸仓库且不是当前 gitdir 本身"(dir.c:2020-2034)。OID 的取得在 `index_path`:

```c
	case S_IFDIR:
		if (repo_resolve_gitlink_ref(istate->repo, path, "HEAD", oid))
			return error(_("'%s' does not have a commit checked out"), path);
		if (&hash_algos[oid->algo] != istate->repo->hash_algo)
			return error(_("cannot add a submodule of a different hash algorithm"));
		break;
```
(object-file.c:988-1020,S_IFDIR 分支约 1010-1016)

即:**add 不把目录内容打成 tree,而是解析 `<dir>/.git` 的 HEAD commit,把那个 commit 的 OID 写进父 index**(调用链 read-cache.c:724(add_to_index)→ read-cache.c:795(index_path))。add_to_index 限制只接受 regular/symlink/git-directory 三类(read-cache.c:740)。裸 git 目录但非 submodule 用途时会触发 "adding embedded git repository" 警告(builtin/add.c:326-341)。

### 2.4 checkout 与 clone:gitlink 的"内容缺席"语义

checkout 落盘时 gitlink 只 mkdir、不写内容:entry.c:396-400(`case S_IFGITLINK: ... mkdir(path, 0777)`);已存在目录则"如果是 gitlink,别动它"(entry.c:560-563)。删除时 rmdir 而非 unlink(entry.c:612-613),并先经 `submodule_move_head` 摘除子仓库 HEAD(entry.c:608-613)。checkout 一致性校验:比对子仓库 HEAD 与 ce->oid(read-cache.c:270-284 ce_compare_gitlink;unpack-trees.c:2335-2346)。

clone 因此得到的是**只有目录壳、没有内容的仓库**——gitlink OID 存在于 tree/index,但子仓库对象库不存在,除非 `--recurse-submodules`(builtin/clone.c:944-948 选项定义、1140-1156 克隆完成后补做 init+update)。这就是"孤儿态"的起点,见 §3.4。

---

## 3. submodule 专节:双层配置与 update 链

### 3.1 .gitmodules 与 .git/config:同一信息的两份账本

submodule 配置分两层:随树版本化的 `.gitmodules`(进入 tree、随分支切换)和本地的 `.git/config`(clone URL、active 标志,不版本化)。常量定义三件套:

```c
#define GITMODULES_FILE ".gitmodules"
#define GITMODULES_INDEX ":.gitmodules"
#define GITMODULES_HEAD "HEAD:.gitmodules"
```
(environment.h:30-32)

读取时的三级回退:先读工作树里的 `.gitmodules` 文件;没有就取 index 里的 blob(`:.gitmodules`);再没有取 `HEAD:.gitmodules` blob(submodule-config.c:784-811)。入口 `repo_read_gitmodules` 拒绝读未合并状态的 .gitmodules(submodule-config.c:830-842;未合并判定 submodule.c:47-73)。按 commit 查配置则走 `<commit>:.gitmodules` 解析(submodule-config.c:679-688、861-877)。

### 3.2 submodule.<name>.active 的三级判定

"这个 submodule 是否激活"的判定在 `is_tree_submodule_active`(submodule.c:239-289),优先级:

1. `submodule.<name>.active` 布尔值(submodule.c:245-250);
2. `submodule.active` 多值 pathspec,对 path 匹配(submodule.c:252-267);
3. 兜底:`submodule.<name>.url` 是否被设置——**设了 URL 即视为激活**(submodule.c:272-276)。

入口 `is_submodule_active` 用 null tree 查当前配置(submodule.c:290-293);而"子仓库是否已 checkout 到位"由 `is_submodule_populated_gently` 判定:解析 `<path>/.git` 能否定位 gitdir(submodule.c:295-303)。**激活(配置层)与填充(工作树层)是两个独立状态**,这是孤儿态的根源。

### 3.3 git submodule init:把 .gitmodules 抄写进 .git/config

`init_submodule` 做三件事(builtin/submodule--helper.c:574-648):

- 若未激活,写 `submodule.<name>.active=true` 到 .git/config(builtin/submodule--helper.c:596-601);
- 若 .git/config 尚无 url,从 .gitmodules 抄 `submodule.<name>.url` 并解析相对路径(608-629,输出 "registered" 在 630);
- 抄写 `submodule.<name>.update` 策略(632-645)。

源码注释明确标注:在多工作树世界里这些本应写 per-worktree 配置(NEEDSWORK,builtin/submodule--helper.c:586-587)——双层配置与 worktree 机制的交界是已知欠账。

`git submodule add` 的注册由 `configure_added_submodule` 完成:先写 .git/config 的 url(3526-3528),再跑 `git add --no-warn-embedded-repo` 把子目录登记为 gitlink(3530-3539),写 .gitmodules 的 path/url/branch(3541-3546),最后按 `submodule.active` pathspec 决定是否单独置 active(3565-3573)。

### 3.4 update 的行号链:clone → checkout → 递归

`git submodule update` 的完整调用链(均在 builtin/submodule--helper.c):

| 步骤 | 位置 | 做什么 |
|---|---|---|
| 命令入口 | `module_update` :2981 | 解析参数;`--init` 选项 :2994-2995 |
| init 前置 | :3078-3090 | `--init` 时先对列表跑 init(无参数时按 `submodule.active` 过滤) |
| 逐项筛选 | `prepare_to_clone_next_submodule` :2258 | 未合并跳过 :2275-2279;`update=none` 跳过 :2296-2302;**未激活则警告跳过 :2304-2308**;URL 取自 .git/config :2311;`needs_cloning = !file_exists("<path>/.git")` :2326 |
| 并行克隆 | `update_clone_get_next_task` :2387 → `update_submodules` :2909 | `run_processes_parallel` 多进程克隆(:2917-2927) |
| 单个克隆 | `clone_submodule` :1900 | gitdir 已存在则只清 index :1917;否则 `git clone --no-checkout` :1927-1928;`--separate-git-dir <父>.git/modules/<name>` :1949 |
| gitdir 落位 | `submodule_name_to_gitdir` :2737(submodule.c) | 默认 `<父>/.git/modules/<name>`;开启 `extensions.submodulePathConfig` 后读 `submodule.<name>.gitdir`(:2739-2760) |
| 拉平状态 | `update_submodules` :2952 | `ensure_core_worktree` 补 core.worktree |
| 单个更新 | `update_submodule` :2820 | 子仓库 HEAD 经 `repo_resolve_gitlink_ref` 取出 :2832-2836;`--remote` 时 fetch 并解析 `refs/remotes/<remote>/<branch>` :2838-2873;OID 与父 index 的 gitlink OID 不等或 force 才动 :2879-2884 |
| 执行更新 | `run_update_procedure` :2641 | 先 `is_tip_reachable`,不可达才 fetch :2645-2660 |
| 策略分发 | `run_update_command` :2549 | checkout→`git checkout -q [oid]` :2556-2560;rebase :2562;merge :2568;命令行 :2571 |
| 递归 | :2886-2901 | `update_data_to_args`(:2770)注入 `--recursive` 后在子仓库里**重新执行 submodule--helper update**,逐层下钻 |

克隆完成后父 index 的 gitlink OID 与子仓库 checkout 的 HEAD 之间的对齐,由父仓库 checkout 时的 `submodule_move_head`(submodule.c:2126)驱动:未激活直接早退(submodule.c:2135-2136);旧 HEAD 存在则检查子 index 脏否(submodule.c:2162-2166)、必要时 `absorb_git_dir_into_superproject`(submodule.c:2164-2168);新填充则 `connect_work_tree_and_git_dir` 把工作树与 `.git/modules/<name>` 接上并重置子 index(submodule.c:2182-2189)。该链接函数写两个文件:`<path>/.git` 写 `gitdir: <相对路径>`,`<gitdir>/config` 写 `core.worktree`(dir.c:4113-4142)。

`absorb_git_dir_into_superproject`(submodule.c:2556-2611)处理"子仓库 gitdir 散落在外"的历史形态:把 `<path>/.git` 实体目录搬进父仓库 `.git/modules/<name>`,并递归处理嵌套 submodule(submodule.c:2529-2554)。

### 3.5 孤儿态:gitlink 存在但子仓库未填充

三者叠加产生孤儿态:(a) tree/index 里 gitlink 存在;(b) `.git/modules/<name>` 未 clone;(c) 配置未 init。此时:

- `git checkout` 落盘只 mkdir 空目录(entry.c:396-400);
- `submodule_move_head` 因未激活而静默不动(submodule.c:2135-2136);
- `submodule update` 不带 `--init` 时因 :2304-2308 的激活检查而跳过并警告;
- 状态校验容忍缺失:`ce_compare_gitlink` 解析不到子 HEAD 就"视为匹配"(read-cache.c:270-284);`verify_clean_subdirectory` 同理(unpack-trees.c:2335-2346)。

即:**孤儿不是错误态,而是被精心容忍的常态**——gitlink 的对象类型是 commit(对象库里未必有这个对象),这一宽容贯穿始终。

---

## 4. worktree 专节:gitdir/commondir 指针链与引用路由

### 4.1 磁盘结构:一条双向指针链

主工作树的 gitdir 即 `$GIT_COMMON_DIR`;每个链接工作树在公共目录下有 `.git/worktrees/<id>/`,内含 `gitdir`(指回工作树)、`commondir`(指回公共目录)、`HEAD`、`index`、`locked`、`reftable/` 等。枚举入口 `get_worktrees_internal`:先列主工作树,再 opendir `worktrees/`(worktree.c:186-217);每个链接项靠读 `worktrees/<id>/gitdir` 文件还原工作树路径(worktree.c:141-183,读文件在 152-160,支持相对路径 realpath 回退 :162-166)。主工作树无 `gitdir` 文件,靠剥 `.git` 后缀得路径(worktree.c:113-138)。

add 时的写盘顺序(builtin/worktree.c:458-635):

- 候选路径与分支占用检查(:466、:486,详见 §5);
- `worktrees/<name>/` 目录,重名自动加数字后缀(:499-509);
- 写 `locked` 占位,防中途失败被 prune 捡走(:517-521);
- `write_worktree_linking_files` 写双向链接(:540-541):`<工作树>/.git` 写 `gitdir: <路径>`,而 `worktrees/<id>/gitdir` 写 `<工作树>/.git`(worktree.c:1105-1136;`--relative-paths` 需升级 `extensions.relativeWorktrees`,worktree.c:1120-1126);
- 写 `commondir` 文件,内容固定 `../..`(builtin/worktree.c:542-544)——指向上一级即公共 gitdir;
- `ref_store_create_on_disk` 初始化引用库(:557),随后写新工作树的 HEAD:分支则 symref,裸 commit 则直接写 OID(:561-565)。

`git worktree list` 的输出(`is_current`/`is_bare`/`detached`)均出自上述结构:is_current 比较当前 gitdir 与 worktrees/<id> 绝对路径(worktree.c:58-65);HEAD 解析在 `add_head_info`,SYMREF→head_ref,否则 detached(worktree.c:40-53)。锁原因读 `<id>/locked`(worktree.c:305-327),prune 原因是 should_prune_worktree 的薄包装(worktree.c:329-347)。

### 4.2 per-worktree vs 共享 refs:精确清单

路由核心是 `parse_worktree_ref`,它把任何 refname 分成四类(refs.c:944-990;枚举见 refs.h:1108-1117):

```c
enum ref_worktree_type {
	REF_WORKTREE_CURRENT, /* implicitly per worktree, eg. HEAD or ...  */
	REF_WORKTREE_MAIN,    /* explicitly in main worktree, eg. ...      */
	REF_WORKTREE_OTHER,   /* explicitly in named worktree, eg. ...     */
	REF_WORKTREE_SHARED,  /* the default, eg. refs/heads/main          */
};
```
(refs.h:1110-1116)

**独立的引用(每工作树一份)**:

- `HEAD` 及其余根引用:`is_root_ref` 收录全部大写根引用——以 `_HEAD` 结尾的(FETCH_HEAD 之类被排除)加上不规则名单 HEAD、AUTO_MERGE、BISECT_EXPECTED_REV、NOTES_MERGE_PARTIAL、NOTES_MERGE_REF、MERGE_AUTOSTASH(refs.c:912-937);FETCH_HEAD/MERGE_HEAD 是显式伪引用(refs.c:893-902);
- per-worktree 前缀:`refs/worktree/`、`refs/bisect/`、`refs/rewritten/`(refs.c:880-884)——bisect 状态与 rebase 的 rewritten 引用天然属于某次操作,必须随工作树独立;
- 显式跨树访问语法:`worktrees/<id>/...`(REF_WORKTREE_OTHER)与 `main-worktree/...`(REF_WORKTREE_MAIN)(refs.c:953-986)。

**共享的引用(默认)**:一切其余引用——`refs/heads/`、`refs/tags/`、`refs/remotes/` 等落在 REF_WORKTREE_SHARED(refs.c:988-989),存于公共目录。注意:**分支共享而 HEAD 独立**,这一组合正是"同一分支不能被两个 worktree 同时 checkout"(§5)的机制土壤。

`strbuf_worktree_ref` 展示了读取另一工作树引用时的名字改写:非当前工作树的 per-worktree 引用要加 `main-worktree/` 或 `worktrees/<id>/` 前缀(worktree.c:587-599)。每个 worktree 的引用库实例由 `get_worktree_ref_store` 构造:当前工作树复用主 store,否则以 `worktrees/<id>` 为 gitdir 建独立 store(refs.c:2448-2468)。

reftable 后端是这套路由的物理印证(呼应卷一 02 章"每工作树独立栈"):store 持有 `main_backend` 与 `worktree_backend` 两个栈(refs/reftable-backend.c:130、135),外加按需打开的其他工作树栈表(refs/reftable-backend.c:140、191-210);注释明言"仓库级引用与工作树级引用分别放在多个 reftable/ 数据库中"(refs/reftable-backend.c:224-231);`backend_for` 按 parse_worktree_ref 的四分类选栈(refs/reftable-backend.c:236-290):主栈开在 `$GIT_COMMON_DIR/reftable`(:445-448),工作树栈开在 per-worktree gitdir 的 `reftable/`(:452-464)。

### 4.3 prune:僵尸工作树回收

`git worktree prune` 逐目录调用 `should_prune_worktree`(worktree.c:937-1029),判死刑的顺序:

1. 目录本身不是有效目录(:953-955);
2. 有 `locked` 文件则豁免(:957-960);
3. `gitdir` 文件缺失(:963-966);
4. 读出 gitdir 内容,指向的 `<工作树>/.git` **不存在**——僵尸本体(:997-1013):
   ```c
   	if (!file_exists(dotgit.buf)) {
   		strbuf_reset(&file);
   		strbuf_addf(&file, "%s/index", repo_path.buf);
   		if (stat(file.buf, &st) || st.st_mtime <= expire) {
   			strbuf_addstr(reason, _("gitdir file points to non-existent location"));
   			rc = 1;
   			goto done;
   		}
   	}
   ```
   (worktree.c:1004-1013)——注意补偿逻辑:工作树没了但 `<id>/index` 还新鲜(mtime 晚于 expire)就暂缓回收,等 mtime 过期再收;`expire` 默认 TIME_MAX 即"不因新鲜豁免"(builtin/worktree.c:259)。

prune 主循环遍历 `worktrees/` 调用上式,命中则 `delete_git_dir` 递归删除 `<id>/` 目录(builtin/worktree.c:212-244、149-160、171-176),末尾清空 `worktrees/` 目录本身(:243-244)。同时用 `prune_dups` 处理多个 id 指向同一工作树路径的重复项(:234-241)。

与之互补的 `git worktree remove` 走正向删除:拒绝主工作树、检查 locked(两次 -f 才可破)、`validate_worktree` 校验,再 `git status --porcelain --ignore-submodules=none` 检查干净(含 submodule,builtin/worktree.c:1372-1414),最后删工作树、删 `<id>/`、清空目录(builtin/worktree.c:1425-1472,关键 :1449-1470)。另有 `git worktree repair` 修复断链(worktree.c:644-934,双向 repair:`repair_worktrees` 与 `repair_worktree_at_path`)。

---

## 5. 分支独占检测:为什么同一分支不能两个 worktree

**机制前提**:分支 `refs/heads/x` 是共享引用(REF_WORKTREE_SHARED,refs.c:988-989),而每个工作树只是通过自己的 `HEAD` symref **指向**它。若两个工作树 HEAD 同指一个分支,任何一侧的新 commit 都会移动共享的 `refs/heads/x`,另一侧的 HEAD 悄然"漂移"——两个工作树对"我当前在哪个 commit"的答案互相踩踏,而它们各自还有独立 index。这是正确性问题,不是偏好问题。

实现分两半:

**注册侧**——`prepare_checked_out_branches` 扫描全部工作树,把"被占用"的分支名登记进 strmap(branch.c:420-481),占用的形态不止 HEAD:

- HEAD symref 指向的分支(:424-428);
- 正在 rebase 的工作树(state.branch 登记,builtin 走 wt_status_check_rebase,:430-438);
- 正在 bisect 的工作树(:440-448);
- sequencer update-refs 扫过的引用(:450-462)。

查询即查表:`branch_checked_out(refname)` 返回占用该分支的工作树路径(branch.c:482-486)。

**执行侧**——`die_if_checked_out` 遍历工作树,用 `is_shared_symref` 判断"该工作树的 HEAD symref 目标是否等于这个分支",命中即 die(branch.c:881-895):

```c
void die_if_checked_out(const char *branch, int ignore_current_worktree)
{
	struct worktree **worktrees = get_worktrees(the_repository);

	for (int i = 0; worktrees[i]; i++) {
		if (worktrees[i]->is_current && ignore_current_worktree)
			continue;
		if (is_shared_symref(worktrees[i], "HEAD", branch)) {
			skip_prefix(branch, "refs/heads/", &branch);
			die(_("'%s' is already used by worktree at '%s'"),
				branch, worktrees[i]->path);
		}
	}
	...
```
(branch.c:881-893)

`is_shared_symref`(worktree.c:500-525)考虑了两个灰色地带:bare 工作树不算占用(:507);**detached HEAD 但正在 rebase/bisect 的也算占用**(is_worktree_being_rebased/bisected,worktree.c:462-497、510-515)——因为那两处内部也持有对分支的隐式引用。

调用点:`git checkout <branch>`(builtin/checkout.c:1663-1676,`--ignore-other-worktrees` 逃生门在 :1667-1668)、`git worktree add <path> <branch>`(builtin/worktree.c:486)、以及 `git branch -f` 强改被占用分支的拒绝(branch.c:514-518)。`git worktree add --force` 显式放行(--force 选项文案即"checkout <branch> even if already checked out in other worktree",builtin/worktree.c:837;分支路径的 die 在 :486,经过 add 入口的 :904)。

---

## 6. 设计动机

### 6.1 submodule 为什么"难用":两层仓库 = 两层状态机

架构根源在于:gitlink 让父仓库的 tree 携带一个**指向另一个完整仓库的 commit OID**,但 Git 的所有核心机制(checkout、status、diff)只认识"tree + 对象库"。子仓库有自己的对象库、index、HEAD,等于在状态机之外再挂一台状态机:

- **一致性靠约定而非事务**:父 index 的 gitlink OID 与子仓库 HEAD 之间没有任何原子绑定——`submodule_move_head` 只是在父 checkout 时用子进程跑 `git read-tree --recurse-submodules`(submodule.c:2197-2218);`git submodule update` 则是逐个子进程 clone/checkout(§3.4 表)。任何一步失败,两层就脱节,而 gitlink OID 仍客观存在于父 index 中。
- **配置三处分裂**:.gitmodules(版本化)、.git/config(active/url/update 抄本)、index(gitlink entry)。active 判定要串起三个来源按优先级读(submodule.c:239-289);init 的作用就是把第一层"抄写"进第二层(builtin/submodule--helper.c:574-648)。用户心智里"一个 submodule 一个配置",实现里是三本账。
- **分布式不对称**:clone 默认只带指针不带内容(builtin/clone.c:1140-1156 才补抓),因为 gitlink 引用的 commit 在别的仓库里,传输协议(卷一 E 章)没有任何"连带拉取"语义。孤儿态被到处容忍(read-cache.c:270-284、entry.c:396-400),本质是系统无法承诺子仓库可用。
- **路径安全补丁层**:gitdir 落位 `.git/modules/<name>` 后,嵌套路径冲突要靠 `validate_submodule_git_dir` 拒绝(submodule.c:2204-2210;`extensions.submodulePathConfig` 是后续补救,submodule.c:2739-2760);clone 时防符号链接写入子模块路径(builtin/submodule--helper.c:2940-2946)。这些不是设计,是补设计。

### 6.2 worktree 的引用路由为什么要白名单

共享是**默认**(REF_WORKTREE_SHARED,refs.c:988-989),独立必须**逐项列出**(refs.c:880-884)。原因:

- 引用绝大多数(branches/tags/remotes)天然跨工作树共享;若做成"独立是默认",每加一个功能引用都要回答"要不要进每份工作树",遗漏即事故。
- 独立引用的共性是"绑定当前操作/当前状态":HEAD、bisect、rewritten、worktree/ 命名空间。白名单=把"哪些引用有单工作树语义"集中成一份可审计清单(refs.c:880-884、912-937)。
- 文件后端靠**目录**区分公共与私有(02 章的 refs/,加上 per-worktree gitdir);reftable 没有文件系统目录可用,于是物理拆成两个栈(refs/reftable-backend.c:224-231),路由函数 backend_for 复用同一个四分类(refs/reftable-backend.c:236-290)。白名单是两种后端共同的语义层。

### 6.3 与 02 章引用事务的关系

- worktree 把"引用"从一维名字变成 `(worktree, refname)` 二维;引用锁与事务因此都要知道作用域——per-worktree 引用锁在自己 gitdir 下,共享引用锁在公共目录,锁文件路径由 parse_worktree_ref 的分类决定(refs.c:944-990)。reftable 下,共享引用的事务提交发生在 main 栈,per-worktree 的工作树栈互不干扰(:445-464),锁冲突体现为"栈已锁"(源码注释 :258-265)。
- submodule 则完全在引用事务之外:它对子仓库的写(checkout/rebase/merge)是子进程级操作,不参与父仓库的引用事务。这正是 02 章"引用级原子性"边界的一个反例注脚——**引用原子性从不跨仓库**。

---

## 7. FAQ 素材

1. **Q: tree 里的 160000 条目存的是什么?** A: 一个 commit 对象的 OID。`object_type()` 对 gitlink 返回 OBJ_COMMIT(object.h:126-131),所以 gitlink 可以指向任何 commit,与"子仓库"并无强绑定。
2. **Q: 为什么 160000 不是合法文件 mode?** A: 它是 S_IFDIR|S_IFLNK 的人为组合,Unix 里不存在,专门挪用为"目录链接"(object.h:115-122)。
3. **Q: git add 一个嵌套仓库会发生什么?** A: `index_path` 走 S_IFDIR 分支,解析该目录 `.git` 的 HEAD commit 作为 OID(object-file.c:1010-1016),只登记指针不登记内容;非 submodule 场景会打 embedded repo 警告(builtin/add.c:326-341)。
4. **Q: .gitmodules 不在工作树里时还能读到吗?** A: 能,三级回退:工作树文件 → index blob → HEAD blob(submodule-config.c:784-811;常量 environment.h:30-32)。
5. **Q: submodule 什么时候算"激活"?** A: `submodule.<name>.active` > `submodule.active` pathspec > `submodule.<name>.url` 存在,三级判定(submodule.c:239-289)。激活≠已填充,后者看 `<path>/.git` 能否解析(submodule.c:295-303)。
6. **Q: `git submodule update --init` 里 init 做了什么?** A: 把 .gitmodules 的 url/update 抄进 .git/config 并置 active(builtin/submodule--helper.c:574-648),然后照常走 clone/update 链(:3078-3090 先 init 再 update)。
7. **Q: 子仓库的 .git 去哪了?** A: 默认集中放在父仓库 `.git/modules/<name>`,工作树里只留一个 gitfile(submodule.c:2737-2772;gitfile 写入 dir.c:4113-4142);clone 用 `--separate-git-dir` 直接落位(builtin/submodule--helper.c:1949)。
8. **Q: worktree 里哪些引用是各工作树独立的?** A: HEAD 等 `_HEAD`/根引用、`refs/bisect/`、`refs/rewritten/`、`refs/worktree/`,加伪引用 FETCH_HEAD/MERGE_HEAD(refs.c:880-902、912-937);其余默认共享。
9. **Q: 删掉工作树目录后,`.git/worktrees/<id>` 会自己消失吗?** A: 不会,要靠 `git worktree prune`;僵尸判定是 gitdir 文件指向不存在的位置,且 `<id>/index` 的 mtime 已过 expire(worktree.c:1004-1013,builtin/worktree.c:212-244)。
10. **Q: 为什么两个 worktree 不能 checkout 同一分支?** A: 分支是共享引用,两个 HEAD symref 同指它会让两侧提交互相移动对方的"当前分支";检测在 `prepare_checked_out_branches` + `die_if_checked_out`(branch.c:420-486、881-895),rebase/bisect 状态也算占用(branch.c:440-448)。

## 深挖练习

1. **给 gitlink 做一次"手动 submodule"**:不碰 `git submodule`,只 `update-index --cacheinfo 160000,<commit>,path` + 手写 `.gitmodules` 与 `git config`,验证 update 链每一环的报错位置(提示:`prepare_to_clone_next_submodule` 的三次拦截点 builtin/submodule--helper.c:2275、2296、2304)。
2. **追踪一次 detach 漂移**:worktree A 在分支 x,B `--force` checkout x;两侧交替 commit 后用 `git worktree list --porcelain` 观察对方 HEAD,并在 `is_shared_symref` 处(worktree.c:500-525)设计一个更早的拦截。
3. **reftable 双栈实验**:`git init --ref-format=reftable` + 两个 worktree,观察 `$GIT_COMMON_DIR/reftable` 与 `worktrees/<id>/reftable` 各自增长的表文件,对应 refs/reftable-backend.c:445-464。
4. **prune 的 mtime 豁免**:手动改写 `<id>/gitdir` 指向不存在路径,再 touch `<id>/index`,验证 `--expire` 参数与 worktree.c:1004-1013 的交互。
5. **active 三级判定重排**:同时设 `submodule.<name>.active=false` 与 `submodule.<name>.url`,验证第一优先级胜出(submodule.c:245-250),理解为何 `update` 对它静默跳过。

---

## 写作要点速查表

| # | 关键函数/常量 | 位置 | 一句话 |
|---|---|---|---|
| 1 | `S_IFGITLINK`/`S_ISGITLINK` 定义与注释 | object.h:115-122 | 0160000 = S_IFDIR+S_IFLNK 的人为组合 |
| 2 | `object_type()` gitlink→OBJ_COMMIT | object.h:126-131 | tree 里存的是子仓库 commit OID |
| 3 | `canon_mode()` 兜底 S_IFGITLINK | object.h:145-153 | 未识别 mode 一律归 gitlink |
| 4 | tree 条目 canon_mode | tree-walk.c:17,42 | 解析时归一;890-905 按目录匹配 |
| 5 | `index_path()` S_IFDIR 分支 | object-file.c:988-1020 | add 嵌套仓库=取其 HEAD commit |
| 6 | checkout 对 gitlink 只 mkdir | entry.c:396-400,560-563 | 内容缺席语义 |
| 7 | `.gitmodules` 三级回退 | submodule-config.c:784-811 | 文件→index→HEAD(常量 environment.h:30-32) |
| 8 | `is_tree_submodule_active` 三级判定 | submodule.c:239-289 | active → active pathspec → url |
| 9 | `init_submodule` 抄配置 | builtin/submodule--helper.c:574-648 | .gitmodules→.git/config 的桥 |
| 10 | `prepare_to_clone_next_submodule` | builtin/submodule--helper.c:2258(2304/2326) | update 的三道拦截与 needs_cloning |
| 11 | `clone_submodule` | builtin/submodule--helper.c:1900(1949) | clone --no-checkout --separate-git-dir |
| 12 | `update_submodule`/`run_update_command` | 同文件 :2820/:2549 | OID 对齐;checkout/rebase/merge 分发 |
| 13 | `parse_worktree_ref` 四分类 | refs.c:944-990(枚举 refs.h:1108-1117) | CURRENT/MAIN/OTHER/SHARED |
| 14 | per-worktree 引用白名单 | refs.c:880-884,912-937 | worktree//bisect//rewritten/ + 根引用 |
| 15 | `should_prune_worktree` 僵尸检测 | worktree.c:937-1029(1004-1013) | gitdir 指向不存在 + index mtime 豁免 |
| 16 | `add_worktree` 写盘序 | builtin/worktree.c:458-635(542-544,561-565) | gitdir/commondir/HEAD 三件 |
| 17 | `die_if_checked_out` 分支独占 | branch.c:881-895(登记 :420-486) | is_shared_symref 命中即 die |
| 18 | reftable 双栈 | refs/reftable-backend.c:130,135,445-464 | 主栈 common 目录 + 每工作树栈(02 章) |
