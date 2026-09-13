# 第 09 章 · fsck 与数据抢救:完整性的三层防线

> 基线:commit `47ce805`。行号以 builtin/fsck.c、fsck.c、builtin/prune.c、builtin/index-pack.c 为准。卷一 04 章讲了 gc/cruft 的删除宽限——本章讲"检查与修复"面:git 怎么验证自己、坏了怎么救。

## 9.0 全景:数据坏在哪,防线在哪

```
坏因:磁盘位翻转 / 进程 kill 的半写 / 传输中断
防线:写入时校验(01 章:头+内容哈希)
     ── 运行时 fsck(本章:对象结构+图连接性)
     ── 传输时校验(index-pack 边收边验)
```

fsck 的架构是**两阶段**(builtin/fsck.c):阶段一收集 roots 与逐对象校验;阶段二 `check_connectivity`(:364-402)全图遍历。关键设计:**两套 fsck_options**(:1029-1036)——`mark_object` 打 REACHABLE 并入队(:125-179),`mark_used` 只打 USED 不入队(:213-220):**dangling = unreachable 且 !USED**(:281-351)——"没人指的尖端",是误删分支的最佳抢救起点(:303-314 注释明言),故默认打印(show_dangling=1)。

## 9.1 fsck 总控:roots 与连接性

阶段一的顺序:`git refs verify` 子进程先体检引用库(:955-979)→refs 快照(snapshot_refs,:597-665:命令行对象→全部 refs→各 worktree HEAD;快照的理由在 :1057-1063 注释——检查期间引用可能移动)→完整模式扫 loose(:792-811)+verify_pack(:1091-1098),`--connectivity-only` 只打 HAS_OBJ 跳过内容校验(:911-919)→process_refs 把 refs+reflog 当根(:675-714)→index 兜底(:1110-1146,verify_index_checksum=1)。阶段二的工作队列 traverse_reachable(:205-208)与 mark_object 的 REACHABLE 去重(:151-153)。

退出码是 8 位标志(:54-61),cmd_fsck `return errors_found`(:1189)——CI 可按位区分错误类型。顺带校验 rev-index/bitmap/commit-graph/midx(:1148-1186)——**辅助索引(08 章)的体检也是 fsck 的职责**。

## 9.2 对象级校验:四类各自的检查点

fsck_buffer 分派(:1263-1280);fsck_walk 按类型递归(:482-504,blob 即终结):

- **tree**(:616-810):11 类疑点——null sha1/超长 path/含 .git/未排序/重复条目等;mode 白名单(:722-743);
- **commit**(:950-1010):tree/parent/author(唯一)/committer/正文无 NUL;
- **tag**(:1021-1131):四行头+gpgsig 格式(**不验签名真伪**——那是 verify-tag 的事);
- **blob**(:1184-1252):仅 .gitmodules/.gitattributes 两类内容,经 fsck_finish **延迟两段式校验**(:1361-1373)。

分级:75 条消息默认级别总表(fsck.h:23-104);`--strict` 的本质是 **WARN 提级为 ERROR**(fsck.c:110-112);用户可 fsck.<msgId> 调级、skipList 豁免(:1440-1469);FATAL 不可降级(:176-177)。loose 位翻转的检测形态是 **hash-path mismatch**(builtin/fsck.c:737-744):内容哈希与路径名不符——01 章"头+内容哈希"设计的检测面。

## 9.3 prune 联动:误删防线的叠加

prune_object 有两道闸(builtin/prune.c):可达不删(:90-91);mtime>expire 宽限(:98-99),expire 默认 TIME_MAX(:172),gc 传 2.weeks.ago(gc.c:143)——04 章 cruft 的上游。**mark_reachable_objects 的 roots 比 fsck 更宽**(reachable.c:302-358):index/rebase 现场文件(:55-84)/reflog/近期 mtime 兜底(:347-355)——**gc 的"可达"定义故意比"引用可达"宽松**:宁多留不误删。pack 内不可达走 cruft(odb/source-files.c:490-498);preciousObjects 仓库直接拒绝 prune(:179-180)。

顺带纠正一个常见误区:**git gc 并不运行 fsck**——两者共享底层工具但互不调用。

## 9.4 传输校验:index-pack 边收边验

接收端 `index-pack`:use() 累积 CRC32(:343)、每对象记录 idx.crc32(:586)、sha1_object 里碰撞检测+对象 fsck(:883-979)、**整包尾哈希比对**(:1292-1298)+包尾垃圾检查(:1301-1306)。静态 verify-pack 在 pack-check.c:52-180(包哈希 :85-91/idx CRC :121-130/逐对象哈希 :155-157);midx 三查(midx.c:925-1063);接收端可选 `receive.fsckObjects`(:178-184)把 fsck 前移到 push 时刻。三层防线各覆盖一种坏:写入坏(01 章哈希)、链接坏(fsck 连接性)、传输坏(index-pack)。

## 9.5 抢救手册(按损坏类型)

| 场景 | 路径(代码依据) |
|---|---|
| 误删分支 | `fsck --unreachable` 找 dangling commit → `git branch rescue <oid>`(:281-351) |
| 找回文件 | `fsck --lost-found`:blob 内容写 .git/lost-found/other/(:320-342) |
| 引用还在对象丢 | reflog 仍是根(:473-494)→fetch 重取 |
| rebase 中断状态 | rebase 现场文件是 prune 的根(reachable.c:55-84) |
| loose 位翻转 | hash-path mismatch(:737-744)→删坏文件+重取 |
| pack 损坏 | verify-pack 定位→重取/reclone(内容不可"修复",只能重取) |
| 全量枚举 | `cat-file --batch-all-objects`(cat-file.c:1240-1241) |

总原则:**对象名即内容哈希 ⇒ "找回优于修复"**——不存在"修一个对象",只有"换一个正确的对象"。

## 9.6 设计动机

1. **fsck 只报不修**:错误处理终点全是打印+置位退出码(:84-121)——内容不可再生,修复的唯一安全形式是"用正确副本替换";
2. **完整性分层**:每对象哈希(01 章)+全树连接性(fsck)+传输校验(index-pack)——三层各覆盖一种坏因,缺一不可;
3. **roots 越宽越安全**:fsck 用严格 roots 报告丢失,prune 用宽松 roots 决定删除——**报告与删除使用不同的可达定义**,这是误删防线的架构表达;
4. **dangling 的产品化**:默认打印+--lost-found 落盘(:320-342)——"悬空对象"从异常变成功能(对照 04 章 cruft 宽限:时间维+图维双层反悔)。

## 9.7 FAQ

**Q1:git gc 会帮我跑 fsck 吗?**
不会——常见误区,两者共享工具但互不调用;要体检显式 git fsck。

**Q2:unreachable 和 dangling 什么区别?**
dangling=unreachable 且无对象引用它(:281-351)——可达性图的"尖端",抢救价值最高。

**Q3:--connectivity-only 快在哪?**
跳过 blob 内容校验只验图(:911-919)——大仓库体检先用它。

**Q4:fsck 报 dangling 一定危险吗?**
多数是正常操作残留(amend/rebase);默认打印是提示而非错误——看退出码与级别。

**Q5:误删的提交真的能找回吗?**
reflog 窗口内(02 章)必能;窗口外靠 fsck dangling(:281-351)+cruft 宽限(04 章)。

**Q6:fsck 会不会改我的仓库?**
默认完全只读;--lost-found 只写 .git/lost-found/(:320-342)。

**Q7:--strict 什么时候用?**
把 WARN 提级 ERROR(:110-112)——CI 门禁与接收外部仓库时。

**Q8:push 时能强制 fsck 吗?**
能,receive.fsckObjects(:178-184)——代价是服务端 CPU。

**Q9:半写的 loose 对象什么表现?**
要么解压失败要么 hash-path mismatch(:737-744)——01 章头哈希设计的红利。

**Q10:损坏能修吗?**
不能"修",只能"换":重取/reclone——内容寻址(01 章)使修复这个概念不存在。

## 9.8 小结与深挖方向

本章结论:**完整性 = "写时哈希+运行时连接性+传输校验"三层;报告用严格 roots,删除用宽松 roots;dangling 是产品**。深挖:

1. fsck_finish 延迟两段式(:1361-1373)对 .gitmodules 的检查覆盖面;
2. --connectivity-only 与 commit-graph(08 章)组合的体检成本曲线;
3. receive.fsckObjects(:178-184)在 CI monorepo 的吞吐代价;
4. 8 位退出码标志(:54-61)的 CI 语义设计;
5. dangling 检测在百万 loose 对象仓库的 I/O 形态。

> 下一章:submodule 与 worktree——仓库引用仓库的两种姿势。
