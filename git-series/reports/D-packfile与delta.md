# D 章：Git Packfile 与 Delta 深度调研

> 源码版本：git commit `47ce805`（2026-09-11，shallow clone）。所有行号以该 commit 为准，
> 标注格式为 `仓库相对路径:行号`。行号均经 grep/Read 实际核对。

---

## 1. 全景：loose → pack 生命周期

```
 写入侧(热)                                  存储侧(冷)                        查询侧
┌────────────┐  git add   ┌───────────────┐
│ 工作区文件  │──────────▶│ loose 对象     │  zlib 整对象压缩, 一文件一对象
└────────────┘            │ .git/objects/xx/yyyy…
                          └──────┬────────┘
                                 │ git gc / repack / fetch 后自动
                                 ▼
                   ┌──────────────────────────┐   ┌───────────────┐
                   │ pack-*.pack              │◀──│ pack-*.idx    │ fanout+二分: oid→pack内偏移
                   │ 12B头+对象流(带delta)+SHA1│   └───────────────┘
                   └──────┬───────────────────┘
                          │ 多 pack 碎片化后: git multi-pack-index write
                          ▼
                   ┌──────────────────────────┐   ┌───────────────┐
                   │ 多个 .pack               │◀──│ multi-pack-   │ 跨 pack 统一 oid→(pack,offset)
                   │                          │   │ index (MIDX)  │ (+ 可选 RIDX 反查/bitmap)
                   └──────────────────────────┘   └───────────────┘
 不可达对象: 旧 = git prune 直接删 → 新 = cruft pack(按 mtime 打包 + gc.pruneExpire 宽限)  [§5]
 稀有对象:   partial clone 不取 blob → promisor remote 懒取                            [§6]
```

为什么要有 pack：

1. **文件系统压力**：loose 模式下一个对象一个文件，大仓库动辄百万级文件，inode 与目录项开销巨大；pack 把数万对象合为 2 个文件（.pack + .idx）。
2. **磁盘局部性**：pack 内对象按内容连续存放，遍历/传输是顺序读；.idx mmap 后查找免 I/O（`packfile.c:76` `check_packed_git_idx` 直接 `xmmap`，`packfile.c:94`）。
3. **传输单元**：clone/fetch 的协议载荷就是 pack 流——`git upload-pack` 直接把 pack 写 stdout（`builtin/pack-objects.c:1353` `pack_to_stdout` 分支）。
4. **delta 压缩**：pack 内允许对象表示为"对基对象的补丁"，版本历史间的相似性被跨对象利用，这是 loose 的 zlib 单对象压缩做不到的（详见 §7）。

对象定位总入口在 `odb/source-packed.c:17` `find_pack_entry`：**先查 MIDX，再逐个 pack 查 .idx**（§3.3）。

---

## 2. 二进制格式专节：.idx 与 .pack

### 2.1 pack 文件头（12 字节）与校验

签名 `"PACK"` = `0x5041434b`（`pack.h:15`），头为 3 个 4 字节大端字段：

```c
// pack.h:19-23 (struct pack_header)
// hdr_signature("PACK") + hdr_version(2/3) + hdr_entries(对象数)
// pack-write.c:364-373
off_t write_pack_header(struct hashfile *f, uint32_t nr_entries)
{
        struct pack_header hdr;
        hdr.hdr_signature = htonl(PACK_SIGNATURE);
        hdr.hdr_version = htonl(PACK_VERSION);
        hdr.hdr_entries = htonl(nr_entries);
        hashwrite(f, &hdr, sizeof(hdr));
        return sizeof(hdr);
}
```

打开 pack 时逐一校验（`packfile.c:567-594`）：签名（573）、版本（575 `pack_version_ok`）、**条目数必须与 .idx 一致**（581-585）、末尾 20 字节哈希必须等于 .idx 末尾双哈希中的 pack 哈希（586-594）。

### 2.2 对象头：变长整数编码

pack 内每个对象（含 delta）的头是一个自描述变长整数：首字节高 3 位是类型（commit/tree/blob/tag/OFS_DELTA/REF_DELTA），低 4 位是长度低位，后续每字节 7 位长度续位：

```c
// pack-write.c:508-529
int encode_in_pack_object_header(unsigned char *hdr, int hdr_len,
                                 enum object_type type, uintmax_t size)
{
        int n = 1;
        unsigned char c;
        if (type < OBJ_COMMIT || type > OBJ_REF_DELTA)
                die("bad type %d", type);
        c = (type << 4) | (size & 15);
        size >>= 4;
        while (size) {
                *hdr++ = c | 0x80;   // 续位
                c = size & 0x7f;
                size >>= 7;
                n++;
        }
        *hdr = c;
        return n;
}
```

解码端镜像实现 `unpack_object_header_buffer`（`packfile.c:869-895`）：`*type = (c >> 4) & 7`（876），循环 `size += (c & 0x7f) << shift; shift += 7`（884-891），并防御 shift 溢出 size_t。

### 2.3 .idx 格式：fanout 表 + 二分

.idx 有 v1/v2 两代（`packfile.c:117-126`：签名 `\377tOc` = `PACK_IDX_SIGNATURE`，`pack.h:42` 时为 v2；否则 v1）。v2 布局：8B 头 + 256×4B fanout + N×hash + N×4B CRC32 + N×4B 偏移 + 可选 8B 大偏移表 + pack 哈希 + 文件哈希（大小校验 `packfile.c:145-165`；写入侧 `pack-write.c:97-173`）。

fanout 表是"以首字节为桶的累计计数"，把二分范围直接缩到 1/256：

```c
// hash-lookup.c:107-118
int bsearch_hash(const unsigned char *hash, const uint32_t *fanout_nbo,
                 const unsigned char *table, size_t stride, uint32_t *result)
{
        uint32_t hi, lo;
        hi = ntohl(fanout_nbo[*hash]);               // 本桶累计
        lo = ((*hash == 0x0) ? 0 : ntohl(fanout_nbo[*hash - 1])); // 前桶累计
        while (lo < hi) {
                unsigned mi = lo + (hi - lo) / 2;
                int cmp = hashcmp(table + mi * stride, hash, ...);
                ...
```

封装与偏移读取：

- `bsearch_pack`（`packfile.c:1722-1744`）：v1 表项 stride=hashsz+4，v2 fanout 前移 8 字节后 stride=hashsz。
- `nth_packed_object_offset`（`packfile.c:1784-1802`）：v2 中 32 位偏移最高位置 1（`off & 0x80000000`，1795）时，其低 31 位是 8 字节大偏移表的下标（1797-1800）。
- `find_pack_entry_one`（`packfile.c:1804-1818`）：二分命中→返回 pack 内偏移，未命中→0。
- 写入端生成 fanout（`pack-write.c:113-123`）：对按 SHA 排好的表逐桶扫描写累计数，注释明言"省去八次二分迭代"（108-112）。

.idx 还保证 fanout 单调不减才可信（`packfile.c:131-135` `non-monotonic index` 校验）。

### 2.4 delta 三元组：基 + 目标长度 + 指令流

delta 载荷 inflate 后的结构：`基对象大小(变长) + 结果大小(变长) + 指令流`（`delta.h:89-104` `get_delta_hdr_size`，注释"须调用两次"）。指令流每字节一个 opcode（`patch-delta.c:39-85`）：

- `cmd & 0x80`：copy——低 7 位是位掩码，决定后续哪几个字节拼出 cp_off(0x01-0x08)/cp_size(0x10-0x40)；`cp_size==0` 特指 0x10000（`patch-delta.c:69`）；从基对象 `memcpy`。
- `1 <= cmd <= 127`：insert——本字节起 cmd 个字面量字节直接拷出（`patch-delta.c:72-77`）。
- `cmd == 0`：保留，遇之报 `unexpected delta opcode 0`（`patch-delta.c:80-83`）。

两种基引用（读取侧解析 `get_delta_base`，`packfile.c:986-1025`）：

- **OFS_DELTA**：存"我减去基对象的相对偏移"，变长 7 位编码且**每续一位额外 +1**（1005-1011，补偿前导 0x80 续位字节的占位）；相对偏移必须落在本对象之前（1012-1014 越界检查）。注释（995-1000）指出：若相对偏移编码比 hash 还长，"那 REF_DELTA 反而更小"。
- **REF_DELTA**：直接存基对象 hash（1016-1021），解析时还要 `find_pack_entry_one` 二分一次本 pack（1020）。

写入侧在 `write_no_reuse_object` 中二选一（`builtin/pack-objects.c:557-563`）：

```c
// builtin/pack-objects.c:557-558
type = (allow_ofs_delta && DELTA(entry)->idx.offset) ?
        OBJ_OFS_DELTA : OBJ_REF_DELTA;
```

OFS 偏移的编码循环在 586-590；REF 则直接写基 hash（600-613）。`allow_ofs_delta` 由 `--delta-base-offset` 打开（usage 文本 `builtin/pack-objects.c:194`；协议上 upload-pack 对支持 side-band-64k 的客户端默认启用）。

---

## 3. 读路径专节：从 oid 到字节流

### 3.1 查找：oid → (pack, offset)

`odb/source-packed.c:17-70` `find_pack_entry`：

1. 有 MIDX 则 `midx_fill_entry`（28-31），命中即返回——**MIDX 优先**；
2. 否则遍历 pack 链表逐个 `packfile_fill_entry`（33-41），命中者**移到 MRU 链表头**（38 `packfile_list_prepend`）；
3. 并发 repack 竞态补救：MIDX 指向的 pack 消失但对象在另一 pack 时，第二次读会直扫 MIDX 各 pack（54-68）。

单 pack 查找链：`packfile_fill_entry`（`packfile.c:1841-1866`，先查坏对象 oidset 再二分）→ `find_pack_entry_one` → `bsearch_pack` → `bsearch_hash`。读之前 `is_pack_valid` 复核文件仍在（1857）。

### 3.2 解包：unpack_entry 三阶段 delta 链展开

入口 `unpack_entry`（`packfile.c:1504-1720`），自带 64 项栈上预分配的 delta 栈（1497-1514）：

```c
// packfile.c:1521-1522 / 1561-1565 / 1575-1590 (节选)
/* PHASE 1: drill down to the innermost base object */
for (;;) {
        ... // 先查 delta base 缓存(1527-1535)
        type = unpack_object_header(p, &w_curs, &curpos, &size);
        if (type != OBJ_OFS_DELTA && type != OBJ_REF_DELTA)
                break;                          // 到达非 delta 基对象
        base_offset = get_delta_base(p, &w_curs, &curpos, type, obj_offset);
        ...
        delta_stack[i++] = {obj_offset, curpos, size}; // 压栈
        curpos = obj_offset = base_offset;      // 跳到基,继续下钻
}
/* PHASE 2 */ 解出最内层基对象数据(1593-1611, 命中缓存则免解压)
/* PHASE 3 */ while (delta_stack_nr) 逐层 patch_delta 回栈顶(1613-1706)
```

要点：

- **链深不是读取时限制**：`--depth` 是写包时承诺（§4.2）；读取侧只要链存在就得走到底，因此深度直接决定冷读成本。
- 每层解出的基对象写入 **delta base 缓存**（LRU，`add_delta_base_cache`，`packfile.c:1268-1300`；上限 `core.deltaBaseCacheLimit`，默认 96MB，`pack-objects.h:12`），同链的兄弟对象读取时可在 Phase 1 直接命中缓存（1527）。
- 基对象损坏时甚至能跨 pack/loose 找回基数据再继续（1628-1657，注释自嘲 "in deep shit"）。
- 底层 I/O 是 mmap 窗口：`use_pack`（`packfile.c:620`）按 `core.packedGitWindowSize` 滑动映射，`in_window` 保证偏移后还有一个 hash 长度可用（606-618，供对象头/delta 基解析不越窗）。
- CRC 校验：开启 `do_check_packed_object_crc` 时 v2 .idx 的 CRC 表用于逐对象校验（1537-1559）。

### 3.3 MIDX：跨 pack 统一寻址

MIDX 签名 `"MIDX"`（`midx.h:14`），按 chunk 组织：`PNAM`(pack 名表)/`OIDF`(fanout)/`OIDL`(排序 oid)/`OOFF`(pack_id+offset 对)/`LOFF`(8B 大偏移)/`RIDX`(反向索引)/`BTMP`(bitmapped packs)（`midx.h:24-31`）。查找几乎复用 .idx 的两段式结构：

```c
// midx.c:521-531
int bsearch_one_midx(const struct object_id *oid, struct multi_pack_index *m,
                     uint32_t *result)
{
        int ret = bsearch_hash(oid->hash, m->chunk_oid_fanout,
                               m->chunk_oid_lookup, ...rawsz, result);
        if (result)
                *result += m->num_objects_in_base;   // 增量 MIDX 链的基偏移
        return ret;
}
```

命中后 `midx_fill_entry`（`midx.c:592-630`）取 `nth_midxed_pack_int_id`（584-590，OOFF 前 4 字节）与 `nth_midxed_offset`（561-582，LOFF 处理大偏移），`prepare_midx_pack`（456-485）懒打开对应 pack。fanout 合法性同样校验单调性（`midx.c:51-75`）。多对象数下 MIDX 把"N 个 .idx 二分"收敛为"1 次 OIDF+OIDL 二分"，也免去了 pack 间重复二分；增量 MIDX 链用 `bsearch_midx` 逐层尝试（533-540）。

Bitmap（简述）：`.bitmap` 为 EWAH 压缩位图，每个代表性 commit 一个位串，仓库默认只有最大 pack（或 MIDX）的一份（`pack-bitmap.c:35-40`）。作用是让 `pack-objects --revs` 的可达性计算变成位运算，并支持整段复用已有 pack 字节（`builtin/pack-objects.c:1375-1381` `reuse_packfiles_nr` 复用路径；枚举入口 `4721` `get_object_list_from_bitmap`）。

---

## 4. 写路径专节：pack-objects

### 4.1 对象枚举与 repack 决策

- `git repack`/`gc` 通过 stdin 把对象清单喂给 `pack-objects`（`read_object_list_from_stdin`，`builtin/pack-objects.c:4380`）；位图路径 `get_object_list_from_bitmap`（4721）成功则跳过遍历（4952）。
- 枚举回调 `want_found_object`（1622-1712）决定"本地已有是否还写"：`--local` 丢弃借来 pack 的对象（1652），`.keep` pack 的对象跳过（1658-1701），增量 `--incremental` 一律不重写（1627）。
- 大骨架决策在 `builtin/repack.c`：keeps/new packs 组合成 stdin 的 keep/discard 列表（`repack-cruft.c:80-93` 可见 `-%s.pack` / `%s.pack` 语法），`-d` 删冗余 pack；`--max-pack-size` 多包轮转由 `write_pack_file` 的 `WRITE_ONE_BREAK` 循环处理（`builtin/pack-objects.c:1352-1512`）。

### 4.2 delta 窗口搜索：--window / --depth / try_delta

默认 `window = 10`、`depth = 50`（`builtin/pack-objects.c:228,230`；文档同值，`Documentation/git-pack-objects.adoc:158`），上限 4095（`OE_DEPTH_BITS = 12`，`pack-objects.h:15`，超限钳制在 `builtin/pack-objects.c:5295-5299`）。

**排序**（决定谁与谁同窗）：`type_size_sort`（2654-2685）按 类型 → 路径名 hash → preferred_base →（可选 island）→ **size 降序** → 地址(≈引入顺序，"newest first")排序。其注释（2646-2653）给出核心直觉：大→小排列让 delta 都是"从大文件删改出小文件"，而大文件往往更新，最深的 delta 落在最老、最少访问的对象上。

**滑窗主循环** `find_deltas`（2992-3132）：环形数组保存最近 window 个候选基（`struct unpacked`，2687-2692，含数据/索引/当前链深）；新对象入窗时对窗内其余对象逐个 `try_delta`（3048-3063）：

```c
// builtin/pack-objects.c:3041-3046, 3048-3063 (节选)
max_depth = depth;
if (DELTA_CHILD(entry)) {                       // 已有子 delta 家族
        max_depth -= check_delta_limit(entry, 0); // 子树最深者占用配额
        if (max_depth <= 0)
                goto next;
}
j = window;
while (--j > 0) {
        ...
        ret = try_delta(n, m, max_depth, &mem_usage);
        if (ret < 0) break;                     // 类型不同→整窗同类型可提前终止
        else if (ret > 0) best_base = other_idx;
}
```

**try_delta 的逐层闸门**（2808-2963）：

1. 类型必须相同（2820-2821）；
2. 复用模式下同 pack 已判定失败的不重试（2831-2836）；
3. **深度闸**：候选基链深 `src->depth >= max_depth` 直接放弃（2839-2840）；
4. **尺寸闸**：对未 deltify 的目标，delta 必须省一半以上（`max_size = trg_size/2 - hashsz`，2845）；已有 delta 时不劣化现值（2848）；再按剩余深度配额折减——基越深，允许的 delta 越小（2851-2852：`max_size *= (max_depth - src->depth) / (max_depth - ref_depth + 1)`）；尺寸差倒挂、目标只有源 1/32 时跳过（2856-2860）；
5. 内存闸：`--window-memory` 动态驱离窗口尾部（3022-3028）；delta 缓存配额 `delta_cacheable`（2694-2708）决定 delta 结果留内存还是丢弃重算；
6. 真正构造：`create_delta_index` 给基建哈希索引（2915），`create_delta` 产出指令流（2925）；同尺寸但更深的新 delta 不采纳（2930-2935）；成功则 `trg->depth = src->depth + 1`（2960）。

窗口循环后的两个微优化：已达 max_depth 的对象先被驱离窗口（3095-3100）；**最佳基被轮转挪到窗口头部**，下个对象最先试它（3103-3117）。`check_delta_limit`（2965-2976）递归统计子树深度以防把别人顶穿限额。

**window/depth 的权衡语义**：

- `--window`↑ → 候选基更多、压缩率更高，但每对象比对次数线性涨（且 `create_delta_index` 的内存也涨）→ **慢**；
- `--depth`↑ → 链更长、压缩率略升，但读取要逐层 `patch_delta`，冷读延迟涨 → **防链爆炸**本质是给读路径上保险；
- `--window-memory`/delta cache 则把 CPU/内存开销封顶。

### 4.3 写出：write_one 与 .idx 生成

`write_one`（801-832）先递归写 delta 基（"base first"），用 `offset==1` 哨兵侦测递归环（808-819）。字节选择见 §2.4。收尾 `write_pack_file`（1333+）多包轮转时用 `fixup_pack_header_footer` 改写头中条目数（1416）。

`write_idx_file`（`pack-write.c:57-180`）：对象按 SHA 排序（76 `sha1_compare`）→ 写 256 项 fanout（113-123）→ 写 hash 表（128-138）→ v2 追加 CRC32 表（143-148）、32 位偏移表（150-160，≥2^31 的置高位指向 8B 大偏移表 162-173）→ pack 哈希 + 文件哈希收尾（175-178）。v2 的启用条件是"最大对象偏移 ≥ 2^31"或显式 `--index-version`（98 `need_large_offset`）。

---

## 5. Cruft Pack 专节：不可达对象的"缓期执行"

**演进**：早期 `git gc` 对不可达对象是"立即物理删除"（`git prune` 语义），本版本 gc 默认开启 cruft pack（`builtin/gc.c:138` `.cruft_packs = 1`），不可达但未过期的对象被收进带 `.mtimes` 附属文件的 cruft pack，超过 `gc.pruneExpire`（默认 `2.weeks.ago`，`builtin/gc.c:143`）才真正消失。

**机制四件套**：

1. **按 mtime 收集**：`--cruft --cruft-expiration=<time>`（`builtin/pack-objects.c:5203-5206`）。`enumerate_and_traverse_cruft_objects`（4274-4319）先经 `add_unseen_recent_objects_to_traversal`（`reachable.c:247-284`）用 `obj_is_recent`（183-192：`mtime > timestamp`）把"仍新鲜"的不可达对象作为 pending 根，再走正常可达遍历（4315 `traverse_commit_list` + `show_cruft_object/commit`，4209-4227）。
2. **逐对象记录 mtime**：`add_cruft_object_entry`（4155-4207）把来源 pack/loose 的 mtime 写入 `oe_cruft_mtime`（字段 `pack-objects.h:182,333-347`），多副本取最大（4204-4205）。
3. **.mtimes 附属文件**：cruft pack 的每个对象 mtime 单独存盘，格式 12B 头 + N×4B + 哈希（`pack-mtimes.c:16` `MTIMES_HEADER_SIZE`；写端 `pack-write.c:333-362` `write_mtimes_file`，315-325 按 index 顺序逐对象 `hashwrite_be32`）。此后不可达对象的"年龄"不再依赖文件系统 mtime。
4. **宽限期裁剪**：`write_cruft_pack`（`repack-cruft.c:40-98`）带 `--cruft-expiration` 再调 pack-objects；`builtin/repack.c:648-652`。若配 `repack -d --expire-to=<dir>`，则再写第二个"过期包"到该目录——注释（654-682）讲清了诀窍：第二次调用必须把 `cruft_expiration` 置 NULL，否则必然产出空包；过期对象随包被移出主对象库，由调用方决定删除。

**多副本 mtime 择优**：`want_cruft_object_mtime`（`builtin/pack-objects.c:1565-1620`）——对象已存在非 cruft pack 时不再重复打包（1590-1591）；已存在于旧 cruft pack 时，仅当新 mtime 严格更新才重打（1608-1615），保证对象不会在 cruft pack 之间无意义搬家。

**为什么这样设计**：宽限期天然兼容"并发进程还在引用旧对象""误删可回滚""`--expire-to` 可做异地备份/审计"，比裸 prune 安全得多；同时 mtime 精确到对象级，避免了"整个 loose 文件 mtime 一碰就续命"的粗粒度问题。

---

## 6. Partial Clone 专节（简）

- **过滤回调**：`--filter=blob:none` 对应 `filter_blobs_none`（`list-objects-filter.c:72-112`）：tag/commit/tree 一律 `LOFR_MARK_SEEN | LOFR_DO_SHOW`（85-98），**blob 则只标记不发送**（104-110），可选收集进 omits 集合供客户端记录缺失清单。blob:size/sparse 等是同骨架的其他 filter 函数（343,386）。
- **懒取链路**：本地读对象 miss 时，`odb.c:625-633` 检查 `fetch_if_missing && has_promisor_remote` 后调 `promisor_remote_get_direct`（`promisor-remote.c:298+`）→ `try_promisor_remotes`（273-296）逐远端 `fetch_objects`（24-60）——即 fork 一个 `git fetch --filter=blob:none --stdin`，把缺失 oid 逐行喂进子进程；单对象失败时剔除已取成功者再试下一远端（283-292）。

---

## 7. 设计动机

1. **delta vs zlib 单对象**：zlib 只消除单对象内部冗余；delta 消除对象之间（同一文件的历史版本、相近 tree）的冗余，指令流本身再走 zlib（`builtin/pack-objects.c:3079-3093` 先压 delta 缓存）。代价是把"解压一个对象"变成"O(depth) 次解压+patch"，Git 用 depth 上限 + base 缓存（§3.2）托底。
2. **OFS_DELTA 优于 REF_DELTA 的三个理由**：(a) 编码更短（相对偏移变长数 vs 20/32 字节 hash，`packfile.c:995-1000` 注释自证）；(b) 解析免一次 .idx 二分（REF 要 `find_pack_entry_one`，`packfile.c:1020`）；(c) 基以位置表达，pack 重编号/重哈希（换 hash 算法）时天然免改。代价是基必须同 pack 且在前面，故写包时 `write_one` 强制 base-first（`builtin/pack-objects.c:823-825`）。
3. **窗口/深度 = 空间-打包时间-读延迟三角**：window 换压缩率、付打包 CPU/内存；depth 换少量压缩率、保读取 O(1)~O(depth)。排序（大→小、新→旧，§4.2）让质量随 window 缩小优雅退化——这与 LevelDB compaction 的分层思想同构：**都是"把写时的整理成本（找最优/归并）换读时的访问成本"，都拒绝全局最优（窗口≈每层 size ratio，depth≈层数上限），用启发式把最坏读取路径钳在常数级**。区别在 LevelDB 以放大写空间换读，Git 以放大写时间换存储与传输。
4. **cruft pack 的哲学**：GC 不做不可逆操作——"删除"被降级成"搬去一个可审计的容器 + 时间锁"，与 `--expire-to` 组合后连删除策略都外置给了运维。

---

## 8. FAQ 素材

1. **pack 和 idx 各干什么？** .pack 是数据流（12B 头+对象流+SHA1，`pack-write.c:364`），.idx 是 oid→偏移的 mmap 索引（fanout+二分，`packfile.c:1722`）。
2. **为什么 .idx 开头是 256 个 4 字节？** 首字节 fanout，二分先缩到 1/256 桶（`hash-lookup.c:112-113`），省约 8 次比较（`pack-write.c:108-112` 注释）。
3. **v1/v2 .idx 区别？** v2 加 8B 头、独立 CRC32 表、32 位偏移表 + 8B 大偏移表（>2GB pack 必需，`packfile.c:1784-1802`；v1 大小校验见 `packfile.c:145-147`，24B 定长条目）。
4. **--window/--depth 默认多少？上限？** 10 / 50（`builtin/pack-objects.c:228,230`）；depth 上限 4095（`pack-objects.h:15` + `builtin/pack-objects.c:5295`）。
5. **--depth 影响读取吗？** 不限制读取；读取必须展开整条链（`packfile.c:1521-1591`），depth 只是写包承诺。
6. **OFS_DELTA 头里存的什么？** 与基的相对偏移的 7 位变长码，且续位每级 +1 补偿（`packfile.c:1004-1011`）。
7. **delta 指令集多复杂？** 两个操作：copy（位掩码拼 offset/size，最大 64KB）与 insert（1-127 字面量）；cmd 0 保留报错（`patch-delta.c:39-83`）。
8. **为什么找了 MIDX 还要保留 .idx？** MIDX 只提供寻址，`prepare_midx_pack` 仍要打开各 pack；且非 MIDX 覆盖 pack、竞态恢复路径都回落到 .idx 二分（`odb/source-packed.c:33-68`）。
9. **cruft pack 靠文件系统 mtime 吗？** 不，.mtimes 附属文件逐对象记录（`pack-write.c:315-325`），过期判断在内存比较（`reachable.c:186`）。
10. **partial clone 拉回来的 blob 什么时候到？** 第一次真正读取时：odb miss → `promisor_remote_get_direct` → 子进程 `git fetch`（`odb.c:625-633`, `promisor-remote.c:43-49`）。

## 9. 深挖方向

1. **多线程 delta 搜索**：`delta_search_threads` 分片（`builtin/pack-objects.c:3135` 注释"主列表切分给各 worker"；变量定义 231）与 `cache_lock`/`packing_data_lock` 的锁层级（2868, 2944）。
2. **`--path-walk`**：新式按路径分组枚举（`builtin/pack-objects.c:5282-5291`），改变 delta 候选分布，值得一读 `get_object_list_path_walk`（4870）。
3. **bitmap 复用 pack 原始字节**：`reuse_packfiles_nr` / `write_reused_pack`（`builtin/pack-objects.c:1390-1397`），服务端推包可近乎 `sendfile`。
4. **增量 MIDX 链**：`midx-*.idx` 链式叠加与 `BASE` chunk（`midx.c:255-374`, `midx.h:31`），大仓库免全量重写 MIDX。
5. **pack 重排序（pack.order）**：`pack-write.c:182` `pack_order_cmp` 与 `compute_write_order`（`builtin/pack-objects.c:989`）——写顺序按"tag→commit→tree→blob、基在前、recency"重排，优化克隆时的磁盘顺序。

## 写作要点速查表（关键函数 + 行号）

| # | 函数/结构 | 位置 | 一句话 |
|---|-----------|------|--------|
| 1 | `bsearch_hash` | hash-lookup.c:107 | fanout 缩桶后二分（读路径核心） |
| 2 | `bsearch_pack` / `find_pack_entry_one` | packfile.c:1722 / 1804 | .idx 查找封装，返回 pack 内偏移 |
| 3 | `nth_packed_object_offset` | packfile.c:1784 | v2 偏移表 + 8B 大偏移间接 |
| 4 | `load_idx`（fanout 单调校验） | packfile.c:106（关键 130-135） | 签名/版本/大小校验 |
| 5 | `unpack_object_header_buffer` | packfile.c:869 | 对象头 3+7n 变长解码 |
| 6 | `get_delta_base` | packfile.c:986 | OFS 相对偏移 / REF hash 解析 |
| 7 | `unpack_entry` | packfile.c:1504 | 三阶段 delta 链展开 |
| 8 | `add_delta_base_cache` | packfile.c:1268 | LRU 基缓存（默认 96MB，pack-objects.h:12） |
| 9 | `find_pack_entry`（MIDX 优先） | odb/source-packed.c:17 | odb 统一入口 |
| 10 | `bsearch_one_midx` / `midx_fill_entry` | midx.c:521 / 592 | MIDX = 跨 pack 的 OIDF/OIDL/OOFF |
| 11 | `try_delta` | builtin/pack-objects.c:2808 | 类型/深度/尺寸三重闸 + create_delta |
| 12 | `find_deltas` | builtin/pack-objects.c:2992 | window 环形窗口、best-base 前移(3107) |
| 13 | `type_size_sort` | builtin/pack-objects.c:2654 | 大→小、新→旧排序动机注释 2646-2653 |
| 14 | `check_delta_limit` | builtin/pack-objects.c:2965 | 子树深度配额扣减 |
| 15 | `write_no_reuse_object`（OFS/REF 选择） | builtin/pack-objects.c:516（557-599） | delta 字节落地 |
| 16 | `write_idx_file` | pack-write.c:57（fanout 113-123） | .idx 生成 |
| 17 | `write_pack_header` | pack-write.c:364 | 12B pack 头 |
| 18 | `write_cruft_pack` / PACK_CRUFT 分支 | repack-cruft.c:40 / builtin/repack.c:624-689 | cruft+expire-to 双包 |
| 19 | `want_cruft_object_mtime` | builtin/pack-objects.c:1565 | cruft 多副本 mtime 择优 |
| 20 | `add_unseen_recent_objects_to_traversal` | reachable.c:247（obj_is_recent:183） | 宽限期= mtime 比较 |
