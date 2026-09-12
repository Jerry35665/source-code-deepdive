# Git 引用与 HEAD 深读:refs API、files 后端、引用事务、reftable 与 reflog

> 源码版本:git commit `47ce805`(`47ce80527c56f462cb97db4ca8125342204d3783`,A bit more for -rc1)。
> 所有 `文件:行号` 均以仓库相对路径标注,并经 grep/Read 实际核对。

---

## 1. 全景:引用是"可变指针",对象是"不可变数据"

Git 的对象数据库(Commit/Tree/Blob/Tag)一旦写入就不可变;仓库的"可变性"几乎全部集中在引用层:分支、标签、HEAD 都只是指向对象(或指向另一个引用)的可变指针。正因如此,引用系统是 Git 并发写入最激烈的战场——每次 commit、push、fetch 都在改引用。

### 1.1 ref_store 抽象与虚函数表

引用存储的核心抽象在 `refs/refs-internal.h`:

- `struct ref_storage_be`(refs/refs-internal.h:567)就是一张虚函数表,包含 `init`、`transaction_prepare/finish/abort`、`iterator_begin`、`read_raw_ref`、一组 reflog 函数和 `fsck` 等约 30 个函数指针(refs/refs-internal.h:567-601)。
- `struct ref_store`(refs/refs-internal.h:612)是所有后端的公共基类,只有 `be` 指针、`repo` 和 `gitdir` 三个字段(refs/refs-internal.h:612-623)。
- 两个注册好的后端以数组形式挂在 refs.c:36-39:

```c
static const struct ref_storage_be *refs_backends[] = {
	[REF_STORAGE_FORMAT_FILES] = &refs_be_files,
	[REF_STORAGE_FORMAT_REFTABLE] = &refs_be_reftable,
};
```

两个后端各自在文件末尾给出完整的函数表实例:

- files 后端:`struct ref_storage_be refs_be_files = {...}`(refs/files-backend.c:4085-4112)
- reftable 后端:`struct ref_storage_be refs_be_reftable = {...}`(refs/reftable-backend.c:2861-2888)

注意 files 后端的函数表里还藏着第二个后端 `refs_be_packed`(refs/refs-internal.h:605,refs/packed-backend.c)——packed-refs 在架构上是 files 后端"内部"的子存储,不单独对外注册(refs_backends[] 数组里没有它,refs.c:36-39)。

### 1.2 后端选择与 ASCII 架构图

入口 `find_ref_storage_backend()`(refs.c:41-47)按 `enum ref_storage_format` 查表;`git init --ref-format=reftable` 与 `extensions.refStorage` 配置(Documentation/config/extensions.adoc:59)决定用哪个。仓库发现阶段也可通过环境变量覆盖(setup.c:2088-2098)。

```
                    调用方 (builtin/*, commit.c, receive-pack.c ...)
                                   │
                        refs.h 门面 API (refs.h:918/951/966...)
                                   │
                         refs.c 通用层 (ref_transaction_* 状态机,
                                   │    refs_resolve_ref_unsafe refs.c:2113)
             ┌─────────────────────┴──────────────────────┐
             │ refs_backends[] 查表 (refs.c:36-39)        │
             v                                            v
   refs_be_files (files-backend.c:4085)      refs_be_reftable (reftable-backend.c:2861)
             │                                            │
   ┌─────────┼─────────────┐                  ┌───────────┼─────────────┐
   │         │             │                  │ main_backend(共享+主工作树,
 loose ref  packed-refs   reflog               │  reftable-backend.c:435-448)
 $GIT_DIR/  packed-backend.c  $GIT_DIR/logs/   │ worktree_backend(每工作树栈,
 refs/**    (子 ref_store)  (逐引用文本文件)    │  reftable-backend.c:458-465)
                                           reftable/stack.c (栈+合并读+compaction)
```

门面层的典型函数:`refs_read_raw_ref`(refs.c:2094)、`refs_resolve_ref_unsafe`(refs.c:2113)、`ref_store_transaction_begin`(refs.c:1220)。

---

## 2. files 后端专节:loose ref、symref 与 packed-refs

### 2.1 路径规则:共享与每工作树

`files_ref_path`(refs/files-backend.c:266-290)把引用名翻译为磁盘路径:`REF_WORKTREE_CURRENT` 落在当前 `gitdir`,`REF_WORKTREE_SHARED/MAIN` 落在 `gitcommondir`(refs/files-backend.c:283-286),`worktrees/<name>/` 下的其他工作树引用单独处理(refs/files-backend.c:279-281)。reflog 路径同理,只是多一层 `logs/` 前缀(refs/files-backend.c:239-264)。每工作树命名空间(refs/bisect/、refs/worktree/、refs/rewritten/)由 `is_per_worktree_ref` 判定(refs.c:880-884)。

### 2.2 loose ref 读路径与 symref 文本格式

读一个引用从 `read_ref_internal` 开始(refs/files-backend.c:514):先 `lstat` 目标文件;若不存在则回落到 packed-refs 子存储查询(refs/files-backend.c:554-565);是目录则同样查 packed-refs(处理 D/F 冲突,refs/files-backend.c:594-609);是普通文件则整读后交给 `parse_loose_ref_contents`:

```c
// refs/refs-internal.h:629 声明;实现 refs/files-backend.c:668-698
int parse_loose_ref_contents(const struct git_hash_algo *algop,
			     const char *buf, struct object_id *oid, ...)
{
	const char *p;
	if (skip_prefix(buf, "ref:", &buf)) {
		while (isspace(*buf))
			buf++;
		strbuf_reset(referent);
		strbuf_addstr(referent, buf);
		*type |= REF_ISSYMREF;
		return 0;
	}
	/* 否则按 "<hex-oid>" 解析,FETCH_HEAD 允许尾随内容 (686-692) */
```

即 symref 就是内容为 `ref: refs/heads/main` 的普通文本文件;除此之外还有一种历史形态:真正的符号链接(refs/files-backend.c:569-591 手工跟随 `refs/` 开头的 symlink)。写侧对应 `create_symref_lock`(refs/files-backend.c:2177-2193),其中 2186 行 `fprintf(..., "ref: %s\n", target)` 是 symref 格式的写侧源头。`core.preferSymlinkRefs` 真符号链接路径已宣布将在 Git 3.0 移除(refs/files-backend.c:2161-2170)。

### 2.3 packed-refs:读路径与快照失效

packed-refs 子存储把所有引用放在一个排序文件中(`$GIT_COMMON_DIR/packed-refs`,路径拼接在 refs/packed-backend.c:233-248)。读路径是快照(snapshot)式的:

- `get_snapshot`(refs/packed-backend.c:824-833):未持锁时先 `validate_snapshot`(refs/packed-backend.c:808-813)用 stat 有效性校验文件是否变化,变了就 `clear_snapshot`;然后按需 `create_snapshot`(refs/packed-backend.c:725),支持 mmap,由 `enum mmap_strategy` 三档策略控制(refs/packed-backend.c:22-39:MMAP_NONE/TEMPORARY/OK,Windows 用 TEMPORARY)。
- 单引用查找 `packed_read_raw_ref`(refs/packed-backend.c:835-859)在快照内二分(`find_reference_location`,refs/packed-backend.c:846),记录类型打上 `REF_ISPACKED`(refs/packed-backend.c:857)。
- packed-refs 文件头部是 `# pack-refs with: peeled fully-peeled sorted` 之类的能力行,逐行解析见 refs/packed-backend.c:408-425;peeled 值(解包 tag 得到的最终对象)直接缓存在文件里,迭代时可通过 `peel_iterated_oid`(refs.h:187-191)零开销取出,这是 packed-refs 相对 loose ref 的一大读优化。

### 2.4 写路径:.lock 文件与原子替换

files 后端的每次写都是"锁文件 + 原子改名":

1. `lock_raw_ref`(refs/files-backend.c:759)对引用文件加 `.lock` 锁:`repo_hold_lock_file_for_update_timeout(..., ref_file.buf, ...)`(refs/files-backend.c:846-848),即锁的是 `refs/heads/foo.lock`;失败(EEXIST)会被归类为 `REF_TRANSACTION_ERROR_CREATE_EXISTS`/大小写冲突(refs/files-backend.c:860-876)。D/F 冲突(如同时存在 `refs/foo` 文件与 `refs/foo/bar` 目录)在创建父目录阶段就被识别并重试(refs/files-backend.c:792-844,3 次重试)。
2. 持锁后读旧值(refs/files-backend.c:887-888),新值写入锁文件:`write_ref_to_lockfile`(refs/files-backend.c:2058-2077)写 hex oid + 换行并 **fsync**(refs/files-backend.c:2069,由 `FSYNC_COMPONENT_REFERENCE` 控制)。
3. 提交时 `commit_ref(lock)` 把 `.lock` 原子改名覆盖真身(refs/files-backend.c:3379、2134)。

packed-refs 的写则不同:锁住 `packed-refs.lock` 后立即关闭锁文件本体(refs/packed-backend.c:1249-1265),实际新内容写到独立 tempfile,再整体替换——即任何小改动都是全文件重写(`write_with_updates`,refs/packed-backend.c:1376),这是 reftable 要解决的核心痛点(见第 4 节)。锁超时默认 1000ms,可由 `core.packedRefsTimeout` 调整(refs/packed-backend.c:1242-1247)。

---

## 3. 引用事务专节:五步 API 与批量原子性

### 3.1 五步 API

refs.h:257-339 用一整段注释定义了调用协议:`ref_transaction_begin` → `ref_transaction_update/create/delete/verify` → (可选)`ref_transaction_prepare` → `ref_transaction_commit`/`ref_transaction_abort` → `ref_transaction_free`(refs.h:263-295)。声明位置:`ref_transaction_update`(refs.h:918)、`ref_transaction_create`(refs.h:951)、`ref_transaction_delete`(refs.h:966)、`ref_transaction_prepare`(refs.h:1005)。

`ref_transaction_update`(refs.c:1398-1463)在入队时就做校验:名字合法性、非法 flags 报 BUG(refs.c:1421)、新 oid 必须存在且分支只能指向 commit(refs.c:1441-1451)、tag 会顺手算出 peeled 值存入事务(refs.c:1452-1456)——所以引用事务同时承担了"引用完整性外键"的角色。

状态机在通用层:

- `ref_transaction_prepare`(refs.c:2681-2730):排序并去重 refnames(refs.c:2708-2710),触发 `preparing` 钩子(refs.c:2713,reference-transaction 钩子),然后调用 `refs->be->transaction_prepare`(refs.c:2719)——锁全部引用、检查前置条件、把新值写进锁文件,但不落地。
- `ref_transaction_commit`(refs.c:2759-2787):若未 prepare 会自动先 prepare(refs.c:2766-2771),再调用后端 `transaction_finish`(refs.c:2783),成功后触发 `committed` 钩子(refs.c:2784-2785)。
- `ref_transaction_abort`(refs.c:2732-2757):回滚锁文件。

### 3.2 files 后端如何实现批量原子性

`files_transaction_prepare`(refs/files-backend.c:2949-3130)是理解"锁顺序"的关键:

1. 先解析 HEAD,若事务里有更新恰好指向 HEAD 的 symref 目标,调用 `split_head_update`(refs/files-backend.c:2499-2545)追加一条 `REF_LOG_ONLY` 的 HEAD 更新——仅为让 HEAD 的 reflog 也记一笔(refs/files-backend.c:2986-3010 的长注释解释了这个"特殊补丁":没有反向 symref 索引,只覆盖 HEAD 这 99% 的场景)。
2. 循环对每个 update 调 `lock_ref_for_update`(refs/files-backend.c:2687),即逐引用加 `.lock` 锁;symref 更新会被 `split_symref_update`(refs/files-backend.c:2555-2607)拆成"symref 本身(log-only)+ 被指向的引用"两条。
3. 删除类更新打包进一个 **packed 子事务**(refs/files-backend.c:3035-3060),随后按"先 loose 后 packed"的固定顺序加锁:`packed_refs_lock`(refs/files-backend.c:3085),并用 `is_packed_transaction_needed` 判断是否真需要重写 packed-refs,不需要则只持锁不放(refs/files-backend.c:3091-3120)。注释明确承认 loose 与 packed 两次加锁之间存在竞态窗口,但不引入全局锁(refs/files-backend.c:3063-3076)。

`files_transaction_finish`(refs/files-backend.c:3321-3475)的落地顺序体现生存优先:**先写更新**(reflog + 改名,refs/files-backend.c:3347-3387),**后做删除**(先删 reflog、再删 packed 项、最后 unlink loose 文件,refs/files-backend.c:3389-3451)——中途崩溃最坏留下"悬空 loose 文件",不会丢引用。由于所有锁在 prepare 阶段就全部拿到,commit 阶段几乎不可能失败,这正是 refs.h:275-281 说的"prepare 成功后 commit 几乎必然成功"。

### 3.3 reftable 后端的同一协议

`reftable_be_transaction_prepare`(refs/reftable-backend.c:1314-1416)不碰文件锁,而是为每个要写的栈创建 `reftable_addition`(写会话,内部锁 `tables.list`,refs/reftable-backend.c:968-999),逐条检查 old_oid/old_target;成功则置 `REF_TRANSACTION_PREPARED`(refs/reftable-backend.c:1400-1401)。`reftable_be_transaction_finish`(refs/reftable-backend.c:1666-1697)只做一件事:把全部更新作为一个新表 `reftable_addition_add` + `reftable_addition_commit` 追加(refs/reftable-backend.c:1676-1681)。abort 则仅销毁写会话(refs/reftable-backend.c:1418-1426)——没有任何磁盘回滚需要做,因为未 commit 的表文件根本不会进入 tables.list。对比两份函数表可见 files 版有 30 行锁管理逻辑,而 reftable 版 prepare/finish 各只有几十行。

### 3.4 用户入口:git update-ref --stdin

builtin/update-ref.c:673-693 的命令表定义了 `start/prepare/commit/abort` 四个协议动词,与 `update/create/delete/verify/symref-*` 更新动词并列;`parse_cmd_prepare`(builtin/update-ref.c:621-631)、`parse_cmd_commit`(builtin/update-ref.c:645-660)直接映射到事务 API。状态机 `UPDATE_REFS_OPEN/STARTED/PREPARED/CLOSED`(builtin/update-ref.c:662-671)正是五步 API 的交互式化身,也是外部工具(如 JGit、libgit2 对端)实现引用事务锁步的协议基础。

---

## 4. reftable 专节:近两年最大的引用架构变化

### 4.1 为什么要迁移

官方格式文档把动机写得直白(Documentation/technical/reftable.adoc:9-22):大仓库(如 86.6 万引用)的 packed-refs 高达 62MB 且单引用查找要线性扫描;**原子多引用更新要求把整个 packed-refs 复制一遍("62M in, 62M out")**;海量 loose 引用又耗尽 inode。目标包括"近常数时间单引用查找"与"O(更新量) 的原子推送"(Documentation/technical/reftable.adoc:31-36)。代码侧对应物正是 2.4 节的 `write_with_updates`(refs/packed-backend.c:1376)——每次 prepare 都全量重写。

### 4.2 栈式表与 compaction(借鉴 LSM-Tree)

reftable 把引用库组织为一个"栈":每个写事务生成一个小的、不可变的表文件追加到栈顶;读时把栈内所有表归并(merged table)出一个逻辑快照。`struct reftable_stack`(reftable/stack.h:15-31)持有 `list_file`(即 `$GIT_DIR/reftable/tables.list`)、表数组与合并视图。写提交流程 `reftable_addition_commit`(reftable/stack.c:775-848):

1. 把旧表名列表 + 新表名列表整体重写进 `tables.list`(reftable/stack.c:784-796)并 fsync(reftable/stack.c:803);
2. `flock_commit` 提交 list 锁(reftable/stack.c:809)——tables.list 这一行就是"提交点";
3. 重载栈(reftable/stack.c:824),然后**自动 compaction**(reftable/stack.c:828-843),并发 compactor 冲突时把 `REFTABLE_LOCK_ERROR/OUTDATED_ERROR` 当作良性忽略。

compaction 采用 LSM 经典的**几何分级**:表大小应保持 64,32,16,8,4,2,1 的几何序列,`suggest_compaction_segment`(reftable/stack.c:1550-1624,因子 `DEFAULT_GEOMETRIC_FACTOR = 2`,reftable/constants.h:16)从栈顶向下找第一个破坏几何关系的位置确定压缩区间,摊还后每次写只压 O(log n) 级别的内容。`git pack-refs` 在 reftable 仓库中退化为 `reftable_stack_compact_all`(全栈压实,refs/reftable-backend.c:1714-1724)。

### 4.3 与 files 后端的同构与差异

| 维度 | files 后端 | reftable 后端 |
|---|---|---|
| 单引用读 | lstat+read loose,miss 后二分 packed-refs(refs/files-backend.c:554-565) | 栈合并迭代器 seek(refs/reftable-backend.c:880-908,64-96) |
| symref | `ref: ` 文本文件(refs/files-backend.c:674) | 记录类型 `REFTABLE_REF_SYMREF`(refs/reftable-backend.c:93-96) |
| 写原子性 | N 个 `.lock` + 改名 + packed-refs 全量重写 | 追加一个新表 + tables.list 单行提交(reftable/stack.c:795-809) |
| reflog | `$GIT_DIR/logs/` 逐引用文本(refs/files-backend.c:239-264) | 与引用同库存为 log record(refs/reftable-backend.c:1463-1600),删除引用时逐条写 tombstone(refs/reftable-backend.c:1517-1544) |
| 每工作树 | 路径分流(refs/files-backend.c:266-290) | 多个独立 reftable 栈,读时合并(refs/reftable-backend.c:216-228 注释、229-295 路由) |
| 锁粒度 | 每引用 `.lock` + packed-refs 锁 | 仅 `tables.list` 的 flock + 各表 `tables/*.lock`(compaction 用) |
| 碎片治理 | `git pack-refs` 手工 | 写后自动几何 compaction(reftable/stack.c:828-843) |

值得一提的是 reftable 里每个记录都带 `update_index`(单调版本号,`reftable_stack_next_update_index`,reftable/stack.c:973),同一事务的更新占用连续 index(refs/reftable-backend.c:1484),这给了引用库"原生 MVCC 快照"的能力——files 后端只能靠 packed-refs 快照 + stat 校验近似。

---

## 5. reflog 专节

### 5.1 写入时机:在引用更新流程内自动发生

reflog 不是独立模块,而是引用更新管线的内嵌步骤。files 后端:`files_transaction_finish` 对每个 `REF_NEEDS_COMMIT|REF_LOG_ONLY` 的更新先调 `parse_and_write_reflog`(refs/files-backend.c:3355-3361),它最终走到 `files_log_ref_write`(refs/files-backend.c:2008-2052)→ `log_ref_write_fd`,格式化函数只有一句核心(refs/files-backend.c:1996):

```c
strbuf_addf(&sb, "%s %s %s", oid_to_hex(old_oid), oid_to_hex(new_oid), committer);
if (msg && *msg) {
	strbuf_addch(&sb, '\t');
	strbuf_addstr(&sb, msg);
}
strbuf_addch(&sb, '\n');
```

即每行 `旧oid SP 新oid SP 提交者ident TAB 消息 LF`,解析端注释同款:"old SP new SP name <email> SP time TAB msg LF"(refs/files-backend.c:2235)。文件是否创建由 `log_ref_setup`(refs/files-backend.c:1912-1968)决定:非裸仓库默认为 HEAD/refs/heads/** 自动建(`core.logAllRefUpdates`,判断在 refs.c:1064-1077)。对 reftable 后端,reflog 是表里的 log record,同样在事务 finish 时写入(refs/reftable-backend.c:1551-1597),`should_write_log` 复刻了 files 的建 log 策略(refs/reftable-backend.c:1443-1461)。

两个易被忽略的细节:(1) 写 reflog 发生在**引用落地之前**(files_transaction_finish 先写 log 再 `commit_ref`,refs/files-backend.c:3347-3387;`commit_ref_update` 里同样是先 log 后 rename,refs/files-backend.c:2093-2134)——顺序是"先记账后转账"的镜像:log 失败则放弃更新;(2) 分支被直接更新且 HEAD 指向它时,HEAD 的 reflog 也会补一条(split_head_update 机制,refs/files-backend.c:2499-2545;旧单引用路径在同款补丁 refs/files-backend.c:2103-2132)。

### 5.2 过期策略

`git reflog expire` 的判定函数 `should_expire_reflog_ent`(reflog.c:370-402):时间早于 `expire_total` 直接过期(reflog.c:378);早于 `expire_unreachable` 时再看新旧值是否从当前引用图可达(reflog.c:386-396,可达性标记在 `reflog_expiry_prepare`,reflog.c:446-483)。默认保留期在 reflog.h:25-28:**可过期条目 30 天、不可达条目 90 天**(`REFLOG_EXPIRE_OPTIONS_INIT`)。HEAD 的 reflog 特殊:过期时以全部引用为可达根(`UE_HEAD` 分支,reflog.c:454-475)。files 后端的过期实现 `files_reflog_expire`(refs/files-backend.c:3521-3650)是"锁引用→重写整个 log 文件"(refs/files-backend.c:3586-3604);reftable 后端则是写一批 deletion record(refs/reftable-backend.c:2618-2730)。

---

## 6. HEAD 专节:symref 解析链与 detached 判定

### 6.1 解析链

`refs_resolve_ref_unsafe`(refs.c:2113-2203)是全仓库 HEAD 解析的必经之路:循环 `refs_read_raw_ref`,每读到 symref 就把引用名替换为其目标继续迭代,上限 `SYMREF_MAXDEPTH = 5`(refs/refs-internal.h:260,防循环);读到非 symref(普通 oid)即返回当前引用名(refs.c:2172-2178)。flags 里 `REF_ISSYMREF` 表示"最后一级是指针",`REF_ISBROKEN`/`REF_BAD_NAME` 表示悬空或非法(refs.h:347-368)。

### 6.2 detached 的判定

"detached HEAD"没有显式状态位,判定就是**一次带 flags 的解析**:worktree 层的 `add_head_info`(worktree.c:40-56)解析 HEAD 后,`flags & REF_ISSYMREF` 成立则记 `head_ref`,否则 `wt->is_detached = 1`(worktree.c:52-55)。`git symbolic-ref` 的 `check_symref`(builtin/symbolic-ref.c:17-44)同理:解析结果非 symref 就报"ref is not a symbolic ref"(builtin/symbolic-ref.c:28-33)。

切换行为:attach 与 detach 是同一条 update_refs_for_switch 里的两个分支——切分支时 `refs_update_symref` 改写 HEAD 的 symref 目标(builtin/checkout.c:1021);detach 时则用 `refs_update_ref` 直接把 commit oid 写进 HEAD(带 `REF_NO_DEREF`,builtin/checkout.c:1010-1013)并打印 "HEAD is now at"。安全护栏:symbolic-ref 拒绝把 HEAD 指向 `refs/` 之外(builtin/symbolic-ref.c:86-88),也拒绝删除 HEAD(builtin/symbolic-ref.c:75-76)。

---

## 7. 设计动机

**引用为什么要事务化?** 单引用更新用 `.lock`+rename 已足够,但 push(同时更新多条分支)、fetch(批量更新 refs/remotes)、`git branch -m`(改名+转移 reflog)天然是"全有或全无"的多点写。没有事务时,中途失败会留下半套更新。这与 etcd 的 multi-key 事务、K8s 中通过 MVCC 多对象写入保证 controller 语义是同一问题类:Git 在 2.x 引入 `ref_transaction` 后,receive-pack、clone(初始事务用 `REF_TRANSACTION_FLAG_INITIAL` 提速,refs.h:290-292)、update-ref --stdin 全部收敛到同一条原子路径。references-transaction 钩子(refs.c:65-66、2713、2784)则把原子边界暴露给审计/策略工具。

**reftable 为什么借鉴 LSM?** refs 的负载特征与 LSM 完全一致:读多写少、写粒度小、写放大敏感。packed-refs 相当于"每次 compaction 全量 SSTable 重写",在写密集的托管服务上是灾难;reftable 把提交点压缩为"追加一个文件 + 改一行 tables.list"(reftable/stack.c:795-809),把重写成本摊还到后台几何 compaction(reftable/stack.c:1550-1624)。附带收益:引用与 reflog 同库存储、原生版本号提供快照一致性、文件数从 O(引用数) 降为 O(log 写次数)。

**两后端并存的迁移策略:** reftable 通过 `extensions.refStorage`(Documentation/config/extensions.adoc:59)+ 仓库版本提升(setup.c:2459-2462,非 files 格式直接把 repo version 提到 READ 版)显式声明,没有热切换,靠 `git clone --ref-format=reftable` / init 时选定让新旧仓库长期共存。通用层 `refs_backends[]` 查表(refs.c:36-47)保证所有上层命令零改动;这解释了为什么虚函数表里保留了 `create_on_disk/remove_on_disk` 这样的迁移期操作(refs/refs-internal.h:571-572)。

---

## 8. FAQ 素材

1. **HEAD 到底是什么文件?** 一个内容为 `ref: refs/heads/main` 的文本文件(写侧 refs/files-backend.c:2186;读侧 parse_loose_ref_contents,refs/files-backend.c:674-681)。reftable 仓库中则是栈内一条 `REFTABLE_REF_SYMREF` 记录,由每工作树栈承载(refs/reftable-backend.c:93-96、216-228)。
2. **detached HEAD 有标志文件吗?** 没有。HEAD 解析不出 `REF_ISSYMREF` 就是 detached(worktree.c:52-55)。
3. **为什么 packed-refs 里有的行下面缩进一行 `^oid`?** 那是 peeled 值缓存,解析在 refs/packed-backend.c:408-425;迭代器可直接取用(refs.h:187-191)。
4. **引用更新会自动写 reflog 吗?** 会,写在事务 finish 阶段、引用改名落地之前(refs/files-backend.c:3347-3361);但仅当该引用的 log 存在或被允许自动创建(refs/files-backend.c:1920-1926)。
5. **为什么 commit 后 logs/HEAD 和 logs/refs/heads/x 各有一条?** 分支更新且 HEAD 指向它时会追加一条 HEAD 的 log-only 更新(refs/files-backend.c:2499-2545)。
6. **update-ref --stdin 的 prepare/commit 是什么?** 五步事务 API 的交互式暴露(builtin/update-ref.c:673-693),prepare 后可 abort。
7. **reftable 仓库还有 packed-refs 吗?** 没有;`git pack-refs` 语义由全栈 compaction 承担(refs/reftable-backend.c:1714-1724)。
8. **reflog 默认保留多久?** 可达条目 30 天、不可达 90 天(reflog.h:25-28);判定在 reflog.c:370-402。
9. **引用名冲突(D/F)怎么办?** `refs/foo` 与 `refs/foo/bar` 冲突在加锁与可用性检查阶段被拒绝,`refs_verify_refnames_available`(refs.c:2789;files 版调用 refs/files-backend.c:3077-3082)。
10. **事务中途崩溃会怎样?** files 后端最坏留下 `.lock` 残留或 loose 文件未删,不会出现半套值(先写后删的顺序,refs/files-backend.c:3347-3451);reftable 后端未进 tables.list 的表文件等同于不存在(reftable/stack.c:784-796)。

## 深挖方向

1. **iterator 协议**:`ref_iterator` 前向/回调双层抽象,refs/iterator.c 与各后端的 `iterator_begin`(refs/files-backend.c、refs/reftable-backend.c 函数表)如何支撑 for_each_ref 的懒求值。
2. **worktree 引用路由**:`parse_worktree_ref` 的四类前缀与 reftable 多栈合并(refs/reftable-backend.c:229-295),跨工作树 `worktrees/<name>/HEAD` 语法。
3. **reftable 文件格式**:block 前缀压缩与 restart point(Documentation/technical/reftable.adoc:184-199、274-286),reftable/writer.c 的写路径。
4. **REF_TRANSACTION_ALLOW_FAILURE**:`ref_transaction_maybe_set_rejected`(refs/files-backend.c:3027、refs/reftable-backend.c:1383)如何让批量更新部分失败而非整体回滚——`update-ref --stdin` 批处理性能recent优化。
5. **fsync 策略**:引用/日志落盘由 `FSYNC_COMPONENT_REFERENCE`(refs/files-backend.c:2069)等组件化开关控制,与 core.fsync 联动。

---

## 写作要点速查表

| 主题 | 位置 |
|---|---|
| 后端注册数组 | refs.c:36-39 |
| ref_storage_be 虚函数表 | refs/refs-internal.h:567-601 |
| files 后端函数表 | refs/files-backend.c:4085-4112 |
| reftable 后端函数表 | refs/reftable-backend.c:2861-2888 |
| loose ref 路径/共享分流 | refs/files-backend.c:266-290(reflog 239-264) |
| loose ref 读取主循环 | refs/files-backend.c:514-646 |
| symref 前缀解析 "ref:" | refs/files-backend.c:668-698(674);写侧 2186 |
| packed-refs 快照与失效 | refs/packed-backend.c:808-833 |
| packed-refs 单引用二分 | refs/packed-backend.c:835-859 |
| packed-refs 锁/全量重写 | refs/packed-backend.c:1236-1292;1376(write_with_updates) |
| 事务协议注释 | refs.h:257-339 |
| ref_transaction_prepare/commit | refs.c:2681-2730;2759-2787 |
| files 事务 prepare(锁顺序) | refs/files-backend.c:2949-3130(packed 锁 3085) |
| files 事务 finish(先写后删) | refs/files-backend.c:3321-3475 |
| symref 拆分/HEAD 拆分 | refs/files-backend.c:2555-2607;2499-2545 |
| reftable 事务 prepare/finish | refs/reftable-backend.c:1314-1416;1666-1697 |
| 栈提交 + 自动 compaction | reftable/stack.c:775-848(828) |
| 几何 compaction 分段 | reftable/stack.c:1550-1624(因子 reftable/constants.h:16) |
| reflog 行格式 | refs/files-backend.c:1986-2006(1996) |
| reflog 过期判定/默认 30/90 天 | reflog.c:370-402;reflog.h:25-28 |
| symref 解析链/深度上限 | refs.c:2113-2203;refs/refs-internal.h:260 |
| detached 判定 | worktree.c:40-56;checkout 分支 builtin/checkout.c:1007-1023 |
| update-ref --stdin 命令表 | builtin/update-ref.c:673-693 |
| symbolic-ref 读/写/护栏 | builtin/symbolic-ref.c:17-44;86-92 |
| reftable 迁移动机 | Documentation/technical/reftable.adoc:9-36;extensions.adoc:59 |
