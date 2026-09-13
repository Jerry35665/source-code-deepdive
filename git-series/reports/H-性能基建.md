# Git 深读 · H 篇:性能基建——对象库之上的辅助索引(commit-graph / pack bitmaps / reachable)

> 源码版本:git commit `47ce805`(shallow clone)。所有 `文件:行号` 均以该 commit 为准,经 grep -n / Read 逐一核对。
> 定位:卷一 01 章讲了对象库本体、04 章讲了 midx/cruft 等 pack 侧机制;本章专讲"对象库之上的辅助索引"三件套——commit-graph(提交图缓存+changed-path Bloom filter)、pack bitmap(可达性位图与 pack 复用)、reachable(可达性标记,gc/prune 前置)。附带简述 name-rev(反向命名)与两个用户入口。

---

## 1. 全景:辅助索引在对象库之上的位置

这三样东西都**不是新的对象存储**:对象仍只存在 loose 目录和 packfile 里(01 章),辅助索引只是可以随时删掉、随时重建的加速层。位置关系:

```
                         ┌────────────────────────────────────────┐
 读取/遍历路径           │            辅助索引(可删可重建)          │
 ────────────────        │                                        │
 git log <path>  ───────▶│ commit-graph                           │
 git status(merge-base) │   objects/info/commit-graph(.graph)    │◀─ 存:OIDF/OIDL/CDAT/GDA2/
 git rev-list --objects  │   + Bloom filter BIDX/BDAT             │     EDGE/BIDX/BDAT/BASE
                         │                                        │   commit-graph.c:44-53
 gc / prune 可达性 ─────▶│ pack bitmap                            │
 fetch/push/clone 出包   │   pack-*.bitmap 或 midx-*.bitmap       │◀─ 存:BITM 头 + 4 张类型位图
                         │   objects/pack/*.bitmap                │     + 若干 commit 位图
                         │                                        │   pack-bitmap.h:16,39-42
                         │ reachable(运行期,不落盘)               │
                         │   mark_reachable_objects()             │◀─ gc/prune 的前置遍历
                         │                                        │   reachable.c:302-358
                         └───────────────┬────────────────────────┘
                                         │ 命中失败就回退
                                         ▼
                         ┌────────────────────────────────────────┐
                         │        对象库本体(01 章 / 04 章)        │
                         │  loose 对象 + packfile + idx + midx    │
                         └────────────────────────────────────────┘
```

三个"可删可重建"的共同逻辑在文档里说得直白:commit-graph 是"a supplemental data structure … If a user downgrades or disables the 'core.commitGraph' config setting, then the existing object database is sufficient"(`Documentation/technical/commit-graph.adoc:18-22`);bitmap 则"may have at most one bitmap"且只对 pack/MIDX 做闭包描述(`Documentation/technical/bitmap-format.adoc:10-11`)。镜像这一点的代码事实:`repo_parse_commit_internal` 先试 commit-graph、失败才去读对象(`commit.c:625-639`);`mark_reachable_objects` 先试 bitmap walk、失败才做普通遍历(`reachable.c:337-345`)。

## 2. commit-graph:把"解压 commit"变成"查表"

### 2.1 文件格式与 chunk 布局

文件头 4 字节签名 `CGPH` + 版本 + 哈希算法 + chunk 数 + base 图数(`commit-graph.c:44-64`),随后是 chunk 目录与各 chunk。写入侧用统一的 chunkfile 机制注册(`commit-graph.c:2152-2185`):

| chunk | 内容 | 写入函数 | 读取校验 |
|---|---|---|---|
| OIDF | 256×4B 扇出表,F[255]=提交总数 | `write_graph_chunk_fanout` commit-graph.c:1169-1194 | `graph_read_oid_fanout` commit-graph.c:282-304(291 行从 fanout[255] 取 N) |
| OIDL | N×H 字节,OID 按字典序排列 | `write_graph_chunk_oids` commit-graph.c:1196-1208 | `graph_read_oid_lookup` commit-graph.c:306-314 |
| CDAT | N×(H+16) 字节:根树 OID+两个父位置+topo level+提交时间 | `write_graph_chunk_data` commit-graph.c:1216-1317 | `graph_read_commit_data` commit-graph.c:316-324 |
| GDA2 | N×4B,修正提交日期偏移 | commit-graph.c:1350 | commit-graph.c:326-334 |
| EDGE | 八爪鱼合并第 3..n 个父 | commit-graph.c:1393 | 配 `pair_chunk` commit-graph.c:446 |
| BIDX/BDAT | changed-path Bloom filter 索引/数据 | commit-graph.c:1448-1508 | commit-graph.c:336-371 |
| BASE | 分片链下层图的哈希 | commit-graph.c:2081 | commit-graph.c:448 |

格式文档与代码一一对应:`Documentation/gitformat-commit-graph.adoc:86-134`(OIDF/OIDL/CDAT/GDA2/EDGE)。CDAT 每条 16 字节非哈希部分是"父1位置 + 父2位置(最高位开则指向 EDGE)+ 2bit 高位日期拼 30bit topo level + 32bit 日期"(`gitformat-commit-graph.adoc:94-107`);写入时 `packedDate[0]` 就是"日期高 2 位 | topo_level<<2"(`commit-graph.c:1303-1311`),父位置常量 `GRAPH_PARENT_NONE=0x70000000`、八爪鱼标志 `0x80000000`(`commit-graph.c:58-60`)。GDA2 的 chunk ID 带"2"是因为旧版 GDAT 有错数据,改名让新版静默忽略旧块(`gitformat-commit-graph.adoc:178-182`)。

### 2.2 读取路径:parse_commit_in_graph 如何替代解压

这是与 01 章 parse_object 四层优化的衔接点:01 章讲过 commit 解析最终落到 `parse_commit_buffer` 逐字段扫文本。有了 commit-graph,`repo_parse_commit_internal` 在碰对象库之前先试图:

```c
// commit.c:625-639(repo_parse_commit_internal)
if (use_commit_graph && parse_commit_in_graph(r, item)) {
        static int commit_graph_paranoia = -1;
        ...
        if (commit_graph_paranoia && !odb_has_object(r->objects, &item->object.oid, 0)) {
                unparse_commit(r, &item->object.oid);
                return quiet_on_missing ? -1 : ...
        }
        return 0;                       // ← 没有读过任何 zlib 流
}
```

`parse_commit_in_graph`(commit-graph.c:1064-1079)→ `find_commit_pos_in_graph`(997-1006,已有位置就直接用)→ `search_commit_pos_in_graph`(981-995,对分片链逐层 `bsearch_graph` 二分,commit-graph.c:831)→ `fill_commit_in_graph`(925-979):

- **日期**:直接从 CDAT 的 8 字节读(`commit-graph.c:895-897`),不需要解析 "committer ... <ts> +0800" 文本;
- **修正代(generation v2)**:从 GDA2 读偏移,`generation = 提交日期 + offset`,偏移最高位开则进 GDO2 溢出表(`commit-graph.c:899-914`);
- **父指针**:CDAT 里是**整数位置**,`insert_parent_or_die` 按位置 `load_oid_from_graph` 直接查 OIDL,八爪鱼的更多父沿 EDGE 链走(`commit-graph.c:948-976`);父未解析时**只建壳不递归**,这是 `lookup_commit` 的推论(01 章);
- **根树**:同样从 CDAT 直接得 OID(`write_graph_chunk_data` 写入侧 commit-graph.c:1234-1235)。

代数的妙用在设计文档里:`N<=M ⇒ A 不可能到达 B`,merge-base/status 的 ahead-behind 计算由此可提前剪枝(`Documentation/technical/commit-graph.adoc:70-89`)。01 章的四层优化(status 快路径)正是消费这份代数的一个客户端;`name-rev` 是另一个:`set_commit_cutoff` 直接用 `commit_graph_generation` 做剪枝界(`builtin/name-rev.c:53-65`,判断在 84-91)。

### 2.3 分片(split)写入与合并策略

每次 fetch/gc 追加少量提交时,不必重写全量图。分片链是多层文件,每层名 `graph-{hash}.graph`,由 `commit-graph-chain` 文件按从底到顶的顺序记录哈希(`Documentation/technical/commit-graph.adoc:165-171`);上层通过 BASE chunk 记住下层哈希(`commit-graph.c:2182-2185`),图内位置 = 层内位置 + 底下各层提交数之和(`Documentation/technical/commit-graph.adoc:203-211`)。

新层写在哪、要向下合并几层,由 `split_graph_merge_strategy`(commit-graph.c:2282-2370)决定:

```c
// commit-graph.c:2311-2325
while (g && (g->num_commits <= st_mult(size_mult, num_commits) ||
            (max_commits && num_commits > max_commits))) {
        if (g->odb_source != ctx->odb_source)
                break;
        ...
        num_commits += g->num_commits;
        g = g->base_graph;
        ctx->num_commit_graphs_after--;   // 每吞一层,层数减一
}
```

默认 `size_mult=2`(`commit-graph.c:2291`,命令行默认同值 builtin/commit-graph.c:265),含义是"若第 N 层提交数 ≤ 新层数的 2 倍就把它并进来",级联向下;文档给的界是:条件 1 使层数对总提交数呈对数,条件 2(--max-commits)限制单层过大(`Documentation/technical/commit-graph.adoc:277-296`)。被合并层的提交重新入栈靠 `merge_commit_graph` 逐条 `load_oid_from_graph`(commit-graph.c:2372-2399),合并循环在 `merge_commit_graphs`(2450-2477)。孤立的旧文件不立刻删:`mark_commit_graphs` 把它们 mtime 刷新到现在(2479-2495),`expire_commit_graphs` 只删 mtime 早于过期时间的文件(2497-2554)——给还在读旧链的并发进程留窗口(文档 328-342)。混合代数链的处理:顶 层没有 GDA2 时整条链退回 topo level(`validate_mixed_generation_chain`,commit-graph.c:524-543;写入侧传播规则 commit-graph.c:2356-2369,文档 298-327)。

### 2.4 changed-path Bloom filter(BIDX/BDAT)

`git log <path>` 的问题是:为了知道哪些 commit 动过某个路径,传统做法要对每个 commit 与其第一父做树 diff——这正是 walk 中最贵的操作。Bloom filter 把"这个 commit 是否**可能**动过该路径"变成一次位查询。

**格式**:BDAT 头三个 u32(哈希版本、每路径哈希次数、每条目最小比特数),后面按 OIDL 顺序拼接所有 filter(`gitformat-commit-graph.adoc:143-164`);BIDX[i] 是"第 0..i 个 commit 的 filter 累计字节数",相邻两项之差就是单个 filter 的大小(`gitformat-commit-graph.adoc:136-141`;写入 commit-graph.c:1448-1466,读取 `load_bloom_filter_from_graph` bloom.c:58-102)。两个 chunk 必须成对存在,否则一起禁用(commit-graph.c:471-478)。

**哈希**:murmur3 32 位 + 双哈希合成 k 个位置——`hashes[i] = hash0 + i*hash1`,seed 取 `0x293ae76f` 与 `0x7e646e2c`(bloom.c:225-243),v2 修正了 v1 在 char 有符号、路径含 ≥0x80 字节时的 bug(bloom.c:168-223,`gitformat-commit-graph.adoc:151-154`)。默认参数:7 次哈希、每条目 10 bit、最大改动路径 512(`bloom.h:44-45`)。

**写入**:对每个 commit 与第一父做 `diff_tree_oid`,把每条改动路径连同**所有祖先目录**一起入 filter(bloom.c:497-535);超过 512 条就写成单字节全 1 的"截断 filter"(bloom.c:348-355, 564-569),无改动的 commit 是单字节全 0(bloom.c:545-551,文档 162-163)。

**查询**(消费端在 revision.c,不属于 commit-graph.c):

```c
// revision.c:810(rev_compare_tree 内)
bloom_ret = check_maybe_different_in_bloom_filter(revs, commit);
```

`prepare_to_use_bloom_filter`(revision.c:708-747)把 pathspec 的**无通配前缀**转成 `bloom_keyvec`——对 "a/b/c" 同时生成 "a/b/c"、"a/b"、"a" 三个 key(bloom.c:286-324,bloom.h:96-109 的文档注释),所以目录级查询也能命中;`check_maybe_different_in_bloom_filter`(revision.c:749-779)对每个候选 commit 逐 key `bloom_filter_contains_vec`(bloom.c:598-608),任一位为 0 即"肯定没动过",直接跳过树 diff。效果:`git log dir/` 从"每个 commit 都树 diff"的 O(N×diff) 降为"绝大多数 commit 一次位查询"。注意它在 `prepare_revision_walk` 里挂载(revision.c:4048),且禁止 pathspec 有通配(revision.c:717-726 的 nowildcard 截断)。

## 3. pack bitmaps:把可达性变成位运算,把打包变成 memcpy

### 3.1 EWAH 表示与文件布局

位图本体是 EWAH 压缩(Rocket-Oriented 压缩位图,来自 JGit/JavaEWAH):流由若干 chunk 组成,每个 chunk 是一个 RLW(run length word)+ M 个字面量字;RLW 编码"1 bit 重复位 B + 32bit 重复次数 K + 31bit 字面量数 M"(`Documentation/technical/bitmap-format.adoc:176-201`)。序列化头是"未压缩位数 + 压缩字数 + 字面量 + RLW 位置"(同文档 156-174);内存结构 `struct ewah_bitmap` 记录 buffer/bit_size/rlw 指针(`ewah/ewok.h:57-63`),`ewah_set` 追加位时自动处理运行长度合并(`ewah/ewah_bitmap.c:202-237`),两 bitmap 的对称差用 `ewah_xor` 逐 chunk 归并(`ewah/ewah_bitmap.c:407`)。磁盘上 `.bitmap` 文件 = `BITM` 头(版本 1 + flags + 条目数 + 所属 pack/MIDX 校验和)+ 4 张类型位图(commits/trees/blobs/tags)+ N 个 commit 位图条目(`Documentation/technical/bitmap-format.adoc:42-150`;写入 `bitmap_writer_finish` pack-bitmap-write.c:1359-1405,写头+四张类型位图在 1391-1400)。

每个 commit 条目 = 4B 对象位置 + 1B xor_offset + 1B flags + 压缩位图;`xor_offset=y` 表示本位图要与 y 个条目之前的位图 XOR 才是真实值,上限 160(`Documentation/technical/bitmap-format.adoc:120-150`)。读取端用一个 160 项的环形缓存待解项(`pack-bitmap.c:381,392-437`),`lookup_stored_bitmap` 递归 XOR 合成(pack-bitmap.c:153-170)。flags 里 `BITMAP_OPT_FULL_DAG` 必须置位(位图要求 pack 内父链闭包,`pack-bitmap.c:268-270`),可选扩展有 name-hash cache(0x4)、commit 查找表(0x10,`<commit_pos,offset,xor_row>` 三元组,免解中间条目)、pseudo-merge(0x20)(pack-bitmap.h:39-42,`load_bitmap_header` pack-bitmap.c:245-334)。仓库同一时刻只认一张位图:open 时 MIDX 位图优先、其次 pack 位图(pack-bitmap.c:687-735)。

### 3.2 选点策略:哪些 commit 配拥有位图

位图位点不在数量上贪多——每张位图要占空间且重建要时间,选点在 `bitmap_writer_select_commits`(pack-bitmap-write.c:1045-1101):

1. 候选集按日期倒序(pack-bitmap-write.c:1051);
2. 步长函数 `next_commit_index`(pack-bitmap-write.c:1014-1036):前 100 个 commit(复数分支/近期历史,`MUST_REGION=100`)**每个都选**;100~20000 之间间隔从 0 渐增到 100(`MIN_COMMITS`);2 万之后间隔从 100 渐增到 5000(`MAX_COMMITS`)封顶;
3. 每个间隔内,优先选**被 refs 直接指着的 commit**(`NEEDS_BITMAP` 标记,`mark_bitmap_preferred_tip` builtin/pack-objects.c:4769-4783)或**合并提交**(多父,pack-bitmap-write.c:1087-1088),否则取间隔首;
4. 仓库总提交数 < 100 时全选(pack-bitmap-write.c:1053-1060)。

逻辑动机:fetch/push 的 wants 绝大多数是 ref 尖端,ref 尖端有位图意味着一次 OR 就覆盖全部祖先(见下);合并提交的位图是最"不同"的,信息量最大。构建本体在 `bitmap_writer_build`(pack-bitmap-write.c:915-1009):按**逆拓扑序**逐 commit 填充位图,子 commit 把位图 OR 给父(962-974),已选中的存下来,最后 `compute_xor_offsets` 做 XOR 压缩(1007)。还会加载旧位图并建立映射来增量复用(937-941,`create_bitmap_mapping` pack-bitmap.c:3135)。

### 3.3 复用路径(一):walk 中的位图 OR

`prepare_bitmap_walk`(pack-bitmap.c:2122-2276)是所有位图消费者的入口(带 pathspec 的 walk 直接拒绝,2142-2143——路径信息位图不掌握,那是 Bloom filter 的活)。对 wants 里的每个 commit:

```c
// pack-bitmap.c:1577-1584(find_objects)
if (object->type == OBJ_COMMIT &&
    add_commit_to_bitmap(bitmap_git, &base, (struct commit *)object)) {
        object->flags |= SEEN;
        existing_bitmaps = 1;
        continue;               // 有位图:一次 OR 覆盖全部祖先,不 walk
}
object_list_insert(object, &not_mapped);   // 没位图:留给 fill-in walk
```

`add_commit_to_bitmap` 就是"查到 → `bitmap_or_ewah` 并进结果"(pack-bitmap.c:1261-1280,hits/misses 计数在 1268/1272);查不到的 roots 才进入 `fill_in_bitmap` 的真实遍历(pack-bitmap.c:1628-1642),遍历中 `should_include` 检查父是否已在结果位图里,是就停止下钻(1220-1244)。haves 侧同理求出后 `bitmap_and_not(wants_bitmap, haves_bitmap)` 一步差集(pack-bitmap.c:2239-2240)。这就是"新 fetch 只花 O(新对象) 时间"的原因:共同历史被 OR 抵消,`haves/boundary` 模式让服务端只走到边界(2178-2182, 2211-2227)。

### 3.4 复用路径(二):pack 数据级复用——GitHub 级 fetch 提速的本体

位图 OR 只省了"决定发什么"的时间;**pack 级复用**连"重新 delta/压缩"都省了。服务端(upload-pack→pack-objects)在 `get_object_list_from_bitmap`(builtin/pack-objects.c:4721-4755)里先调 `reuse_partial_packfile_from_bitmap`:

- 输入是 `result` 位图(wants-haves-filter 之后的最终对象集)与若干"位图覆盖的 pack"(MIDX 时是全部 pack 按 bitmap_pos 排序,pack-bitmap.c:2503-2525;单 pack 时就是那张位图 pack,2526-2569);
- `reuse_partial_packfile_from_bitmap_1`(pack-bitmap.c:2377-2467)扫描 result 的每一个置位:首选/唯一 pack 区间内**全 1 的整字直接 memcpy**(2385-2407);其余逐位调 `try_partial_reuse`(2282-2375);
- `try_partial_reuse` 的准入条件是精髓:对象必须是 OFS/REF delta 时,其 **base 也在本次 reuse 集合里**才放行(2366-2367 `if (!bitmap_get(reuse, base_bitmap_pos)) return 0;`),且假设 delta 依赖永远向前指(2353-2354),跨 pack 的 delta 直接拒绝(2322-2338)——这样服务端可以把 pack 文件的原始字节原样搬运(`write_reused_pack_one` builtin/pack-objects.c:1099-1170),不做任何 delta 计算;
- 复用成功后从 result 里清掉这些位(`bitmap_and_not(result, reuse)` pack-bitmap.c:2592),剩下的对象走常规打包路径。

一句话:**fetch 的绝大多数对象在服务端是"从已有 pack 复制字节",既不算 delta 也不解压**——这是 t/perf/p5311-pack-bitmaps-fetch.sh 专门度量的场景。name-hash cache(BITMAP_OPT_HASH_CACHE)则把路径名哈希缓存在位图文件尾部,后续 repack 不必重算就能让 delta 启发式对齐同名路径(`Documentation/technical/bitmap-format.adoc:209-229`)。

### 3.5 verify 与测试

`git rev-list --test-bitmap` 走 `test_bitmap_walk`(pack-bitmap.c:2810-2879):对指定 commit 取出磁盘位图,再用普通遍历重算可达集,`bitmap_equals` 比对,不一致即 die(2871-2874)。MIDX 位图额外要求 revindex 存在(pack-bitmap.c:511-513)且校验和与 MIDX 一致(505-509)。

## 4. reachable:gc/prune 的可达性标记器

prune 删"不可达"对象,前提是先算出"什么可达"。`mark_reachable_objects`(reachable.c:302-358)汇集所有可达性**根**:

- 索引里的对象(reachable.c:317)、所有 refs(320-321)、分离 HEAD 与其他 worktree HEAD(324-325);
- rebase 状态文件里的 autostash/orig-head(328,实现 55-84)——防止 rebase 进行中 prune 掉半成品;
- reflog(331-332,`mark_reflog` 参数控制);
- 然后**优先位图**:能开位图就用 `traverse_bitmap_commit_list` 把可达对象直接标 SEEN,否则普通 `traverse_commit_list`(reachable.c:337-345)。这使 `git gc` 在有位图的仓库里免掉一次完整历史遍历;
- 最后是"近期对象"补丁:prune 有 `--expire` 宽限期,但引用遍历覆盖不到"没有任何 commit 指着、但 mtime 还新"的松散对象(比如刚写失败的中间产物),`add_unseen_recent_objects_to_traversal`(reachable.c:247-284)按 **pack 顺序**扫描全部对象(272),mtime 晚于 expire 的加入遍历(203-245,判断在 183-192),还可由 `gc.recentobjectshook` 钩子追加额外保留集(164-181)。prune 侧唯一调用点在 `perform_reachability_traversal`(builtin/prune.c:57-71,68 行调 mark_reachable_objects);gc 顺带在完成后写 commit-graph(builtin/gc.c:751-752,维护任务 874-899)。

### 4.1 用户入口与 name-rev 速览

- `git commit-graph {write|verify}`:`builtin/commit-graph.c` 的 write 子命令聚合 `--reachable/--stdin-packs/--stdin-commits/--append/--changed-paths/--split(--max-commits/--size-multiple/--expire-time/--max-new-filters)` 全部选项(233-260),三者互斥校验在 280-281,`--reachable` 走 `write_commit_graph_reachable`(298-302);verify 子命令最终调 `verify_commit_graph`(133,实现 commit-graph.c:2918)。
- `git multi-pack-index {write|compact|verify|expire|repack}`:`builtin/multi-pack-index.c:405-439`,子命令表在 413-417;write 的 `--bitmap`(让 MIDX 位图随写)与 `--preferred-pack`(决定复用倾向的优先 pack)在 153-157。
- `git name-rev`:把 OID 反查成 `v1.0~3^2~1` 式名字。算法是**从每个 tag/ref 尖端向父方向广播名字**,比较函数 `is_better_name` 以"taggerdate 新者优先、tag 优先、distance 小者优先"裁决(`builtin/name-rev.c:113-162`),穿过一次 merge 分支按 `MERGE_TRAVERSAL_WEIGHT=65535` 计代价(94,108-111),非第一父的名字带 `^n` 后缀(223-241);剪枝靠 commit-graph 代数或日期截止(53-91)——**这是 commit-graph 造福的又一个"免费"命令**。

## 5. 性能对照表

| 操作 | 无辅助索引 | 有 commit-graph | 有 bitmap(含 pack 复用) |
|---|---|---|---|
| `git log -- path`(path-limited) | 每 commit 解压+树 diff,O(N×diff) | commit 解压变查表(commit.c:625) | Bloom filter 淘掉绝大多数树 diff(revision.c:810) |
| `git status`(ahead/behind) | 走到根,时钟偏离不可剪枝 | 代数剪枝:gen(A)≤gen(B) 即断(technical/commit-graph.adoc:70-89) | 同左 |
| merge-base / 图遍历 | 逐 commit `parse_commit_buffer`(commit.c:516-598) | 父/日期/根树全在 mmap 常驻内存(fill_commit_in_graph,commit-graph.c:925-979) | rev-list --objects 全程位运算(prepare_bitmap_walk) |
| 服务端 fetch/push 打包 | 重新发现可达集+全量 delta 计算 | — | wants/haves 各一次 OR/AND_NOT(pack-bitmap.c:2234-2240);命中对象 memcpy 原始 pack 字节(2385-2407, builtin/pack-objects.c:1099-1170) |
| gc/prune 可达性标记 | 完整历史遍历 | — | 位图路径直接标 SEEN(reachable.c:337-345) |
| 写入成本 | 0(即对象库本体) | 写图+bloom;可 split 增量(commit-graph.c:2095-2280) | repack 时构建;选点只存少数位点(pack-bitmap-write.c:1045-1101) |

## 6. 设计动机

**为什么 commit-graph 不进对象库本体?** 它是"repo-local caches for optimizations"(设计文档引用的 Jeff King 原话,`Documentation/technical/commit-graph.adoc:397-403`)。放进本体意味着每个写路径都要维护它、损坏要影响正确性;放外面则:core.commitGraph 一关就回退(commit-graph.adoc:18-22)、校验失败仅 warning(`parse_commit_graph` 各 error 返回 NULL,commit-graph.c:373-491)、删文件零损失,连分片文件都可以先标记后过期地"慢慢删"(commit-graph.c:2479-2554)。位图同理,且更进一步:一个仓库同时只认一张位图(pack-bitmap.c:39-44 注释),因为它必须对"整包闭包"负责——`BITMAP_OPT_FULL_DAG` 缺失直接 BUG(pack-bitmap.c:268-270)。

**Bloom filter 的误报代价?** Bloom 只说"可能"与"肯定不":误报的后果仅仅是对该 commit 白做一次树 diff(revision.c:810 之后照常 `diff_tree_oid`),**正确性不受影响**。真正的工程代价是截断规则:改动超过 512 条路径的 commit 直接写成全 1 filter(bloom.c:537-543, 564-569),让大改动 commit 永远走慢路径,保证 filter 体积有界(bits_per_entry×路径数)。v1 哈希 bug 的处理也体现"辅助索引可弃"哲学:换 chunk 语义版本(GDA2 换名,gitformat-commit-graph.adoc:178-182)、`commitGraph.changedPathsVersion` 不兼容直接拒读(bloom.c:424-439 的版本检查,写入端 commit-graph.c:2588-2594)。

**位图为什么只能有几个位点?** 一张位图 = 所选 commit 数 ×(约 6B 头+位图数据),且构建需要逆拓扑全量填充(pack-bitmap-write.c:944-978)。选点函数的三段式步长(0/≤100/≤5000,pack-bitmap-write.c:1014-1036)是对"命中率 × 空间"的显式权衡:近期 ref 尖端必选(fetch wants 高频),越老越稀疏(老 commit 的位图反正会被新位图的 OR 覆盖,单独存收益低)。中间态由 pseudo-merge 补齐:把一组 commit 的并集预 OR 成一张共享位图(`Documentation/technical/bitmap-format.adoc:259-267`),专治"refs 太多导致单 commit 位点覆盖不住"的巨型仓库。

## 7. FAQ 素材

1. **commit-graph 存了提交正文吗?** 没有。只有 OID、父位置、根树 OID、日期、代数、(可选)bloom。看消息仍要读对象本体(chunk 清单 commit-graph.c:44-53)。
2. **删掉 objects/info/commit-graph 会怎样?** 一切照旧,只是每次 parse commit 都要解压(commit-graph.adoc:18-22;回退点 commit.c:625)。gc 的 maintenance 任务会自动重建(builtin/gc.c:891-899)。
3. **八爪鱼合并怎么存?** CDAT 只有 2 个父槽,第 2 槽最高位开 = 指向 EDGE chunk 的位置链(commit-graph.c:1268-1301 写,961-976 读)。
4. **为什么旧仓库偶尔显示 "commit-graph … hash version … 不匹配"?** 文件头记录哈希算法,与仓库当前算法不一致就整体忽略(gitformat-commit-graph.adoc:53-60;代码 commit-graph.c:404-409)。
5. **fetch 多快能返回?** 若服务端有位图且 wants 命中位点:可达集是位运算,对象体是 pack 原始字节复制(3.3/3.4 节)。位图不存在则全走 delta 重算。
6. **位图什么时候生成?** `git repack -adb`(写位图的 pack-objects 走 bitmap_writer_* 系列,builtin/pack-objects.c:1481-1484)或 `git multi-pack-index write --bitmap`(builtin/multi-pack-index.c:156-157)。fetch/clone 不会自动生成。
7. **`git log -- dir/` 为什么突然变快?** commit-graph 里带了 changed-path bloom(commit-graph write --changed-paths;gc 默认开),按前缀 key 一次位查询即可"肯定没动过"跳过(bloom.c:598-608)。
8. **bloom 会漏报吗?** 不会漏(方向性:说"动过"可能是误报,说"没动过"一定可靠),但超大 commit 的 filter 是全 1,等于永远"可能"——慢路径兜底(bloom.c:348-355)。
9. **prune 会不会删掉 reflog 里的提交?** 默认不会:mark_reachable_objects 把 reflog 加入 pending(reachable.c:331-332),想真删得 `reflog expire` 先。
10. **rebase 中途 gc 安全吗?** rebase 状态文件(autostash/orig-head)也被当作可达性根加载(reachable.c:55-84, 328)。

## 8. 深挖建议

1. **位图选点的缓存效应**:实测调整 `repack.writeBitmaps` 与 pseudo-merge 配置(`Documentation/config/bitmap-pseudo-merge.adoc`)在多分支大仓库下的 fetch 时间;观察 trace2 计数 `bitmap/hits`、`bitmap/roots_without_bitmap`(pack-bitmap.c:2260-2267)。
2. **GDA2 溢出链**:构造超 34 位日期的仓库,看 `write_graph_chunk_generation_data_overflow`(commit-graph.c:1374)与读取端 `graph_data->generation = item->date + offset`(commit-graph.c:909-912)如何配合;顺带读 34 位掩码注释(1319-1337)。
3. **分片链的并发窗口**:两个进程同时 `git commit-graph write --split`,观察 `commit-graph-chain.lock`(commit-graph.c:2124-2128)与 expire 的 mtime 策略(2479-2554)如何避免读半链。
4. **`GIT_COMMIT_GRAPH_PARANOIA`**:打开后 `parse_commit_in_graph` 命中还要回查对象库确实存在(commit.c:626-636),可以讨论"性能索引与 fsck 级正确性"的张力。
5. **pack 复用的边界**:手工做一个 base 在另一个 pack 里的 OFS_DELTA,验证 `try_partial_reuse` 拒绝跨 pack 复用(pack-bitmap.c:2322-2338),思考未来转 REF_DELTA 的可能(代码注释原文)。

## 9. 写作要点速查表

| 主题 | 函数/常量 | 位置 |
|---|---|---|
| chunk ID 常量(含 BIDX/BDAT) | GRAPH_CHUNKID_* | commit-graph.c:44-53 |
| 分片合并判据 | split_graph_merge_strategy | commit-graph.c:2282-2344(判据 2311-2312) |
| 孤立层过期 | expire_commit_graphs / mark_commit_graphs | commit-graph.c:2497-2554 / 2479-2495 |
| 读路径总入口 | parse_commit_in_graph | commit-graph.c:1064-1079 |
| 无解压填 commit | fill_commit_in_graph(父/EDGE) | commit-graph.c:925-979 |
| 代数读取(GDA2/GDO2) | fill_commit_graph_info | commit-graph.c:876-918 |
| 与 parse 衔接 | repo_parse_commit_internal | commit.c:600-660(625) |
| CDAT 写入(父位置+日期) | write_graph_chunk_data | commit-graph.c:1216-1317 |
| BIDX/BDAT 写入 | write_graph_chunk_bloom_indexes/_data | commit-graph.c:1448-1466 / 1484-1508 |
| bloom 双哈希 | bloom_key_fill(seeds 0x293ae76f/0x7e646e2c) | bloom.c:225-243 |
| bloom 查询 | bloom_filter_contains_vec | bloom.c:598-608 |
| bloom 生成(树 diff+目录前缀) | get_or_compute_bloom_filter | bloom.c:441-576 |
| log 消费点 | check_maybe_different_in_bloom_filter | revision.c:749-779(挂载 810/4048) |
| 位图头/flags | load_bitmap_header | pack-bitmap.c:245-334 |
| XOR 链上限 160 | MAX_XOR_OFFSET / load_bitmap_entries_v1 | pack-bitmap.c:381 / 392-437 |
| 位图选点 | next_commit_index + bitmap_writer_select_commits | pack-bitmap-write.c:1014-1036 / 1045-1101 |
| 位图 OR 复用 | add_commit_to_bitmap / find_objects | pack-bitmap.c:1261-1280 / 1523-1647 |
| pack 字节复用 | reuse_partial_packfile_from_bitmap(_1)/try_partial_reuse | pack-bitmap.c:2481-2596 / 2377-2467 / 2282-2375 |
| 打包端挂载 | get_object_list_from_bitmap | builtin/pack-objects.c:4721-4755 |
| 位图自校验 | test_bitmap_walk | pack-bitmap.c:2810-2879 |
| 可达性标记 | mark_reachable_objects(bitmap 优先) | reachable.c:302-358(337-345) |
| name-rev 代数剪枝 | set_commit_cutoff / name_rev | builtin/name-rev.c:53-65 / 180-254 |
