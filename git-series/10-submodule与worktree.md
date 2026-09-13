# 第 10 章 · submodule 与 worktree:仓库引用仓库的两种姿势

> 基线:commit `47ce805`。行号以 object.h、submodule.c、refs.c、worktree.c 为准。卷一 02 章 reftable 后端提过"每工作树独立栈"——本章把两个"引用仓库"机制讲透。

## 10.0 全景:垂直引用与水平引用

```
submodule(垂直):父仓库 tree 里存 mode 160000 条目=子仓库 commit 的 OID
                  子仓库独立对象库/index/HEAD;两层状态机靠子进程对齐
worktree(水平):一个引用库(objects/config/refs/heads 共享)服务多份工作树
                  每工作树独占 HEAD/index/少数引用;一致性由路由层保证
```

**方向相反**:submodule 把解引用推给用户(两层仓库=两层状态机,一致性靠约定);worktree 把路由收进核心(白名单决定哪些引用独立)。两者分别解决"复用别的仓库"与"一仓库多处检出"。

## 10.1 gitlink:一个被挪用的 mode

`S_IFGITLINK=0160000`(object.h:115-122)——注释明言它"不是合法 mode,恰为 S_IFDIR+S_IFLNK",即**任意未解析指针**而非 submodule 专属;gitlink 存的是 commit OID(object.h:126-131,映射到 OBJ_COMMIT)。`git add` 嵌套仓库时的行为(object-file.c:988-1020,S_IFDIR 分支):解析子仓库 HEAD commit 写入父 index——**不打包内容,只记指针**。checkout 对 gitlink 只 mkdir 不动已有目录(entry.c:396-400,:560-563)——**"内容缺席"是常态而非异常**;孤儿态被全局容忍(read-cache.c:270-284,解析不到子 HEAD 视为匹配)。

## 10.2 submodule:双层配置与 update 链

配置有两层且语义不同:**.gitmodules 是版本化的**(三级回退读:工作树文件→index blob(`:.gitmodules`)→HEAD blob,submodule-config.c:784-811;常量 environment.h:30-32);**.git/config 是本地的**(clone URL 常因 fork 而不同)。激活判定三级(:239-289):`submodule.<name>.active` > `submodule.active` pathspec > url 存在;**激活与填充是两个独立状态**(:295-303)——gitlink 在但子仓库没 clone 是合法的中间态。

update 全链(builtin/submodule--helper.c):三道拦截(未合并/none/未激活,:2258/:2304/:2326)→ `needs_cloning=!file_exists(.git)` → `clone --no-checkout --separate-git-dir .git/modules/<name>`(:1900-1949)→ OID 对齐后 checkout/rebase/merge 分发(:2820/:2549);**递归靠注入 `--recursive` 重新执行自身**(:2770,:2886-2901)——没有"递归引擎",只有自相似的命令重入。

## 10.3 worktree:指针链与引用白名单

结构:`.git/worktrees/<id>/{gitdir,commondir,HEAD}`——add 时写 `commondir` 内容 `../..` 指回公共目录(:542-544,:561-565),`write_worktree_linking_files`(:1105-1136)建双向 gitdir/gitfile,再为新工作树建 HEAD symref。**引用路由白名单**(refs.c:880-884,:912-937):per-worktree 独占的精确清单是 `refs/worktree/`、`refs/bisect/`、`refs/rewritten/` + 全部根引用(HEAD、`*_HEAD`、AUTO_MERGE、BISECT_EXPECTED_REV、MERGE_AUTOSTASH 等);**其余默认 SHARED**(:988-989);四分类由 `parse_worktree_ref`(:944-990;枚举 refs.h:1108-1117)完成。reftable 后端的两个栈(卷一 02 章)正是消费这份清单:主栈(commondir/reftable)与工作树栈(per-worktree gitdir/reftable)。

**prune 僵尸判定**(worktree.c:1004-1013):`gitdir` 指向不存在位置即候选;但 `<id>/index` mtime 晚于 expire 则暂缓(默认 TIME_MAX 不豁免,builtin/worktree.c:259)——与 09 章 prune 同款"mtime 宽限"思想。

## 10.4 分支独占检测

同一分支两个 worktree 同时 checkout 为什么必须禁止:分支是 SHARED 引用而 HEAD 是 CURRENT 引用——**两侧的 commit 都会移动共享分支指针**,历史即损坏。实现:`prepare_checked_out_branches` 登记占用(branch.c:420-486,四种形态:HEAD/rebase/bisect/update-refs),`die_if_checked_out` 经 `is_shared_symref`(worktree.c:500-525)拦截——detached+rebase/bisect 也算占用。

## 10.5 设计动机

1. **gitlink 的通用化是抽象的胜利**:mode 160000 本可叫"submodule 指针",git 选择叫"未解析指针"——后来者(git-lfs 早期方案、jj 的工作区复制)都能复用这个槽位;
2. **submodule 难用的架构根源**:两层仓库=两层状态机,任何操作(状态同步/冲突/垃圾回收)都要×2 且跨进程——这是"引用别的仓库"问题的固有复杂度,git 选择了最薄的适配层而非深集成;
3. **worktree 的白名单哲学**:共享是默认、独占需列名(:880-884)——新增 per-worktree 引用必须动核心清单,把"哪些状态属于工作树"变成显式设计决策而非意外;
4. **prune 的 mtime 宽限复用**:worktree prune 与对象 prune(09 章)共享"宁可缓删"的时间维反悔思想——git 的删除类操作有一致的安全模式。

## 10.6 FAQ

**Q1:gitlink 的 160000 是文件 mode 吗?**
不是合法文件 mode(:115-122,S_IFDIR+S_IFLNK 的组合位)——专为"树里的仓库指针"预留的槽位。

**Q2:submodule 为什么有 .gitmodules 和 .git/config 两份配置?**
前者版本化(跟仓库走),后者本地化(你的 fork URL)——(:784-811)三级回退连接两者。

**Q3:gitlink 存在但子仓库没 clone,仓库坏了吗?**
没有:孤儿态被容忍(:270-284)——submodule update --init 即填充。

**Q4:两个 worktree 能 checkout 同一分支吗?**
不能,is_shared_symref 拦截(:500-525)——共享分支指针会被两侧互相移动。

**Q5:哪些引用是 per-worktree 的?**
白名单:refs/worktree/、refs/bisect/、refs/rewritten/+全部根引用(refs.c:880-884)——其余共享。

**Q6:worktree 的对象库是共享的吗?**
是:objects 在 commondir(:542-544);工作树只有 index/HEAD 独立——磁盘开销极小。

**Q7:submodule 的递归是怎么实现的?**
没有递归引擎:注入 --recursive 重新执行 submodule--helper 自身(:2770,:2886-2901)。

**Q8:删除 worktree 目录就干净了吗?**
不,.git/worktrees/<id> 会残留——需 git worktree prune(:1004-1013)按 gitdir 悬空检测回收。

**Q9:submodule 能锁死在某个 commit 吗?**
天然如此:gitlink 就是 commit OID;父仓库"更新 submodule"=改这个指针+子仓库 checkout。

**Q10:reftable 下 worktree 的引用在哪?**
两个栈:主栈在 commondir/reftable,工作树独占引用在各自 gitdir/reftable(卷一 02 章,:445-464)。

## 10.7 小结与深挖方向

本章结论:**submodule=垂直指针(两层状态机,一致性靠约定);worktree=水平路由(白名单隔离,一致性靠核心)**。深挖:

1. gitlink 槽位被其他工具复用(jj/ghq)的兼容边界;
2. submodule active 三级判定(:239-289)在 monorepo 部分克隆的组合语义;
3. worktree 白名单新引用(如 REBASE_HEAD)的演进轨迹;
4. prune 的 mtime 宽限(:1004-1013)在容器化(工作树在 tmpfs)的误判;
5. reftable 双栈与分支独占检测(:500-525)的锁一致性。

> 下一章(卷末):builtin 架构——200+ 命令的公共骨架。
