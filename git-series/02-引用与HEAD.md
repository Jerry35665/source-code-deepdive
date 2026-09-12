# 第 02 章 · 引用与 HEAD:不可变世界上的可变指针

> 基线:commit `47ce805`。行号以 refs.c、refs/files-backend.c、refs/reftable-backend.c、reftable/ 为准。本章最大的新闻:reftable 已是完整可用的第二后端,且支持每工作树独立栈——"refs = loose+packed" 的旧心智模型该退役了。

## 2.0 全景:两层抽象

引用=**可变指针指向不可变对象**(01 章)。架构是教科书式虚函数表:

```
refs API 门面(refs.c)
   │ refs_backends[] 注册数组(refs.c:36-39)
   ├─ refs_be_files(files-backend.c:4085)   ← 默认
   │    ├ loose ref(一文件一引用)
   │    └ packed-refs(packed-backend.c,files 内部子 ref_store)
   └─ refs_be_reftable(reftable-backend.c:2861) ← 新后端
        └ reftable 栈(tables.list 提交)
```

`struct ref_storage_be` 约 30 个函数指针(refs/refs-internal.h:567-601),`struct ref_store`(:612)是基类——**门面查表即完成后端切换**(对照 FFmpeg 的 URLProtocol 表)。

## 2.1 files 后端:symref、packed-refs 与锁

- **symref**:HEAD 的本质是文本 `ref: <target>`(读 refs/files-backend.c:674,写 :2186);解析链上限 SYMREF_MAXDEPTH=5(refs/refs-internal.h:260)。
- **读**:loose 主循环(:514-646),miss 回落 packed-refs——mmap 快照+stat 校验+二分(packed-backend.c:808-859)。
- **写**:`.lock` 锁文件+fsync+rename 原子替换(files-backend.c:846,2058-2077)。
- **packed-refs 的死穴**:**任何写都是全文件重写**(write_with_updates,packed-backend.c:1376)——百万引用仓库每次 prune 都 O(n) 重写磁盘,这是 reftable 存在的理由(reftable.adoc:9-22 动机原文)。

## 2.2 引用事务:五步 API 与原子性

批量更新走五步(begin→update→prepare→commit/abort→free,refs.h:257-339;状态机 refs.c:2681/2732/2759):

- **prepare**:一次拿全部 `.lock`+packed 锁,锁序固定(files-backend.c:2949-3130)——避免死锁的锁排序纪律;
- **finish**:先写更新后删引用(:3321-3475)——崩溃时最多"该删的没删",不会"该建的没建";
- 用户协议:`update-ref --stdin` 的 start/prepare/commit/abort 指令(update-ref.c:673-693)——**外部工具(bazel/jj 等)用它做自己的原子分支操作**。

对照 etcd 的 Txn/K8s 的 SSA:同一问题("多个可变状态的一致跃迁")的三种 C/Go 时代答案。

## 2.3 reftable:LSM 思想的移植

reftable 后端:

- **栈式表文件**+`tables.list` 单行提交(reftable/stack.c:775-848)——写新表+改一行索引,原子性由文件系统 rename 承担;
- **自动几何 compaction**(因子 2,:1550-1624)——LevelDB 同款思想:小表周期性合并,读放大可控;
- `pack-refs` 退化为全栈压实(reftable-backend.c:1714-1724);
- **reflog 与引用同库存为 log record**(:1463-1600)——不再有 logs/ 目录;
- 本 commit 已支持**每工作树独立 reftable 栈**,HEAD 等 per-worktree 引用进 worktree 栈(backend_for 路由,:229-295)。

迁移靠 `extensions.refStorage` 仓库扩展+clone/init 时选定——两后端长期并存,不做自动切换。

## 2.4 reflog 与 detached

reflog 行格式 `old new ident\tmsg`(files-backend.c:1986-2006),写在事务 finish 内、引用落地之前(:3355-3361)——**先记日志后生效**,崩溃时的 reflog 就是审计轨迹。detached 判定:HEAD 解析无 REF_ISSYMREF 即 detached(worktree.c:40-56)。reflog 过期(gc.reflogExpire)是"reflog 恢复"窗口的边界——它与 04 章 cruft pack 的宽限期共同构成 git 的双层反悔机制。

## 2.5 设计动机

1. **引用与对象分层的全部意义**:01 章不可变性免费换来"分支=一个 41 字节文件"——创建分支 O(1)、比较分支=比较 oid;CVS 时代"分支=复制全树"的阴影由此驱散;
2. **事务化是被工具链倒逼的**:git 自身可以接受"逐引用更新",但 bazel/jj 等外部系统需要原子多更新——五步 API 是库被当平台用的标准进化(对照 16 章 ffmpeg 调度器的收权);
3. **reftable 借鉴 LSM**:packed-refs 的全量重写与 memtable 的困境同构;栈+几何压实是已被验证的答案——20 年老项目仍在吸收新存储思想;
4. **锁排序纪律**:prepare 阶段固定锁序(files-backend.c:2949-3130)是并发正确性的地基,与任何数据库的锁管理器同构。

## 2.6 FAQ

**Q1:分支为什么这么便宜?**
一个 loose ref 文件(41 字节 oid)或 packed-refs 一行——创建/切换只动引用层,对象层零拷贝。

**Q2:HEAD 是什么?**
symref 文本 `ref: refs/heads/xxx`(files-backend.c:674);无此前缀即 detached(worktree.c:40-56)。

**Q3:reftable 启用后旧工具会坏吗?**
标准 refs API 不变;直接读 .git/refs 目录的脚本会坏——`extensions.refStorage` 声明后 git 自身全部走后端。

**Q4:reflog 为什么能找回"丢失"的提交?**
reflog 写在引用生效前(finish 内 :3355-3361),旧 oid 都有记录;reset/rebase 只动引用,对象仍在。

**Q5:多引用原子更新怎么保证?**
prepare 全锁+固定锁序(:2949-3130),finish 先写后删(:3321-3475)——崩溃安全优先于即时一致。

**Q6:packed-refs 什么时候重写?**
files 后端任何 packed 写操作全量重写(packed-backend.c:1376)——引用越多越痛,reftable 解决之。

**Q7:reflog 会无限增长吗?**
按 gc.reflogExpire 过期(默认 90 天可达条目);与 cruft pack 宽限期(04 章)是两层反悔窗口。

**Q8:update-ref --stdin 是给谁的?**
外部工具的原子多更新协议(update-ref.c:673-693):start/prepare/commit/abort 四指令。

**Q9:symref 为什么限深 5?**
SYMREF_MAXDEPTH(refs/refs-internal.h:260):防符号引用循环,5 层覆盖所有真实用法。

**Q10:每工作树独立栈是什么意思?**
worktree 的 HEAD 等引用进各自的 reftable 栈(reftable-backend.c:229-295)——多工作树不再共享引用存储的锁竞争。

## 2.7 小结与深挖方向

本章结论:**引用层 = "虚函数表双后端 + 五步事务 + 先日志后生效"**;reftable 是 LSM 思想在指针文件上的移植。深挖:

1. reftable 几何压实(因子 2)的读写放大曲线 vs LevelDB 分层 compaction;
2. .lock 文件在 NFS 上的原子性边界与 O_EXCL 语义;
3. 引用事务与工作树/索引操作组合时的中断恢复(.git/rebase-merge 呼应 06 章);
4. per-worktree reftable 栈对 worktree 级锁竞争的量化改善;
5. oid 映射(SHA-1↔SHA-256)在传输协商(05 章)与引用层的分工。

> 下一章:索引与状态机——status 为什么有时自己变慢。
