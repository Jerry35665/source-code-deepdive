# L 章：SHA-1 → SHA-256 迁移机制 —— object format 的可插拔设计

> 源码基线：git 仓库 shallow clone，commit `47ce805`（"A bit more for -rc1"，2026-09-11）。
> 所有 `文件:行号` 以该 commit 为准，已逐一 grep/Read 核对。路径相对仓库根目录。

## 1. 全景：迁移的分层结构

SHA-256 迁移不是一个开关，而是四层各自的"hash 感知点"协同：每层只在**读写边界**
感知 hash，内部分别通过 vtable（算法层）与映射表（数据层）解耦。

```
                ┌───────────────────────────────────────────────┐
                │      仓库级算法选择（装配时一次决定，落盘 config）   │
                │ extensions.objectFormat       → 主算法           │
                │ extensions.compatObjectFormat → 兼容算法(可选)    │
                │ 解析: setup.c:660-689  应用: setup.c:1802-1803    │
                └───────────────────────────────────────────────┘
 ┌──────────────┬─────────────────┬─────────────────┬────────────────┐
 │ 对象层        │ pack 层          │ 引用层           │ 传输层          │
 ├──────────────┼─────────────────┼─────────────────┼────────────────┤
 │vtable:       │pack 头: "PACK"+  │files 后端:       │v0/v1: ref 广告  │
 │git_hash_algo │ 版本+条数,无 hash│ 纯文本 hex 行    │ 尾 object-format│
 │hash.h:294    │ 字段             │ 长度=hexsz       │ upload-pack    │
 │              │(pack-write.c:361)│(files-backend   │ .c:1214        │
 │the_hash_algo:│idx: fanout+oid   │ .c:2067)        │v2: capability  │
 │ 每仓库指针    │ 宽度=rawsz       │reftable 后端:    │ object-format  │
 │hash.h:271-274│pack/idx 尾:      │ 头部 hash_id    │ serve.c:165    │
 │              │ 仓库哈希双校验    │(reftable-backend│ 缺席默认 sha1   │
 │compat 双写:   │(packfile.c:106+) │ .c:424-434)     │ connect.c:508  │
 │odb.c:1040-   │★pack 内只存      │                 │不一致 → die    │
 │ 1057         │ 主格式对象        │                 │ connect.c:736  │
 │映射表: loose.c│                 │                 │                │
 └──────────────┴─────────────────┴─────────────────┴────────────────┘
```

三个结论先行：

1. **一个仓库只有一种"存储格式"**（`repo->hash_algo`），pack 与松散对象都按它编码；
2. **compat 模式下对象逻辑上同时有两个 oid**：物理一份内容，`loose-object-idx`
   记录双向映射（loose.c:15，loose.h:8-12）；非 blob 的 compat 内容**按需现算**
   （odb.c:702-710），不落盘；
3. 传输层不做跨格式转换：`object-format` 不一致直接断开（connect.c:736）。

## 2. 哈希抽象专节：git_hash_algo vtable 与 the_hash_algo

**接口面**。六个函数指针先以 typedef 声明（hash.h:287-292）：

```c
typedef void (*git_hash_init_fn)(struct git_hash_ctx *ctx);
typedef void (*git_hash_clone_fn)(struct git_hash_ctx *dst, const struct git_hash_ctx *src);
typedef void (*git_hash_update_fn)(struct git_hash_ctx *ctx, const void *in, size_t len);
typedef void (*git_hash_final_fn)(unsigned char *hash, struct git_hash_ctx *ctx);
typedef void (*git_hash_final_oid_fn)(struct object_id *oid, struct git_hash_ctx *ctx);
typedef void (*git_hash_discard_fn)(struct git_hash_ctx *ctx);
```

`struct git_hash_algo`（hash.h:294-335）成员分三类：**身份**——`name`（:299，
config/协议用名）与 `format_id`（:301-302，注释明言 "used in pack indices"；
常量 `GIT_SHA1_FORMAT_ID=0x73686131`、`GIT_SHA256_FORMAT_ID=0x73323536`，
hash.h:206,215）；**几何**——`rawsz`/`hexsz`/`blksz`（:305-311），全仓库缓冲
宽度之源；**钩子+哨兵**——六个函数指针（:317-322）与每种算法自带的
`empty_tree`/`empty_blob`/`null_oid`（:324-331，compat 模式预注册的种子）。
调用方经 `git_hash_init/clone/update/final/final_oid/discard` 包装（hash.h:343-370）；
上下文 `git_hash_ctx` 是带标签的 union（hash.h:277-285）。

**算法表与查找**。`hash_algos[]` 静态三元：unknown 占位（hash.c:206-220）、
sha1（:222-239）、sha256（:240-258），另有跳过碰撞检测的 sha1 unsafe 变体
（:188-202，经 `unsafe` 指针 :334 关联）。查找按名/format_id/长度：
hash.h:379-383。

**the_hash_algo 的真相**。`struct object_id` 自带算法标签（hash.h:229-233）：

```c
struct object_id {
	unsigned char hash[GIT_MAX_RAWSZ];
	uint32_t algo;	/* XXX requires 4-byte alignment */
};
```

`GIT_MAX_RAWSZ` 即 32 字节（hash.h:224），一个 oid 容纳任意算法。仓库持有两个
算法指针（repository.h:164-168）：`hash_algo`（"as serialized on disk"）与
`compat_hash_algo`。`the_hash_algo` 只是宏（hash.h:271-274）：

```c
# define the_hash_algo the_repository->hash_algo
```

赋值点是仓库装配 `apply_repository_format()` → `repo_set_hash_algo` /
`repo_set_compat_hash_algo`（setup.c:1802-1803；repository.c:194-196,199-208）。
注意 2026 年新变化：**compat 算法被门控在 Rust 构建之后**，非 `WITH_RUST`
构建设置 compat 直接 `die("compatibility hash algorithm support requires Rust")`
（repository.c:202-208）。默认算法仍是编译期开关：`WITH_BREAKING_CHANGES`
时 `GIT_HASH_DEFAULT` 为 sha256，否则 sha1（hash.h:196-200）。

**格式检测**。`struct repository_format` 携带 `hash_algo`/`compat_hash_algo`
（setup.h:189-190）。解析在 `handle_extension()`（setup.c:653-716）：
objectformat 分支 `hash_algo_by_name` 失败即报错（:660-670）；
compatobjectformat 分支额外做**单次性检查**——重复指定报
"'%s' already specified as '%s'"（:671-689，检查点 :681-687）。配合
`GIT_REPO_VERSION_READ=1`（setup.h:174-175），老版本 Git 见到未知扩展直接拒绝，
从根上防混写。`git init --object-format=`（builtin/init-db.c:59,110,171）在
非 sha1 时把仓库版本抬到 1 并写 `extensions.objectformat`
（setup.c:2450-2469，写点 :2466）。

**读路径分流**。读对象入口检查 oid 标签（odb.c:743-744）：

```c
	if (oid->algo && (hash_algo_by_ptr(odb->repo->hash_algo) != oid->algo))
		return oid_object_info_convert(odb->repo, oid, oi, flags);
```

`oid_object_info_convert`（odb.c:656-734）：先把输入 oid 映射为主算法（:669），
读出后**非 blob 内容反转换回输入算法的编码**（:702-710），delta base 也映射
（:721-729）。磁盘上永远只有主格式，compat 视图是读路径即时重编码。

## 3. compat 双写专节：映射表与一致性保证

**数据结构**。核心在 loose.c/loose.h。内存是两张 khash 表（loose.h:8-12）：

```c
struct loose_object_map {
	kh_oid_map_t *to_compat;
	kh_oid_map_t *to_storage;
};
```

磁盘载体 `objects/loose-object-idx`，头行 `"# loose-object-idx\n"`（loose.c:15），
每行 `<主oid> <compatoid>`（写 :194，解析 :95-104，两段分别按主/compat 算法
解析 :98-100）。启用条件：`repo->compat_hash_algo && repo->gitdir`
（loose.c:17-20）。格式文档见 gitformat-loose.adoc:54。

**双写路径**。总入口 `odb_write_object_ext`（odb.c:1021-1061）：

```c
	hash_object_file(odb->repo->hash_algo, buf, len, type, oid);
	if (odb_freshen_object(odb, oid))
		return 0;
	if (compat) {
		if (compat_oid_in)          /* 调用方已算好(commit 双写) */
			oidcpy(&compat_oid, compat_oid_in);
		else if (type == OBJ_BLOB)  /* blob: 同字节重哈希 */
			hash_object_file(compat, buf, len, type, &compat_oid);
		else {                      /* 树/commit/tag: 先转换再哈希 */
			convert_object_file(odb->repo, &converted, algo, compat,
					    buf, len, type, 0);
			hash_object_file(compat, converted.buf, converted.len,
					 type, &compat_oid);
		}
		compat_oid_p = &compat_oid;
	}
	return odb_source_write_object(odb->sources, buf, len, type,
				       oid, compat_oid_p, NULL, flags);
```

**落盘的只有主格式一份文件**；松散写完成后追加映射行（odb/source-loose.c:848-851）。
流式写同样维护第二个哈希上下文：`if (compat && compat_c)
git_hash_init(compat_c, compat)`（odb/source-loose.c:700-706），同一字节流双喂
（:712-716），收尾双 final（:752-764），落盘后 `repo_add_loose_object_map`
（:971-972）。`repo_add_loose_object_map`（loose.c:214-227）有新增才写盘；
`write_one_object` 以 `O_APPEND` 追加并持 lockfile（loose.c:182-200）——索引是
append-only 日志；全量重写 `repo_write_loose_object_map` 持锁进行并跳过预置
条目（loose.c:127-171，:148-150）。

**一致性保证一：预置条目**。空树/空 blob/null_oid 内容为空、跨算法各自哈希
固定，加载时直接静态配对（loose.c:82-84）：

```c
	insert_loose_map(loose, repo->hash_algo->empty_tree, repo->compat_hash_algo->empty_tree);
	insert_loose_map(loose, repo->hash_algo->empty_blob, repo->compat_hash_algo->empty_blob);
	insert_loose_map(loose, repo->hash_algo->null_oid, repo->compat_hash_algo->null_oid);
```

**一致性保证二：双向翻译+惰性重载**。查询按目标算法选表
`to == compat_hash_algo ? to_compat : to_storage`（loose.c:243-245）。上层
`repo_oid_to_algop`（object-file-convert.c:15-50）处理无标签 oid（:22-31）、
同算法直拷（:33-37），**映射未命中时重读索引再试**（:38-48）——注释解释：
另一进程（管道上游）可能刚写入新对象，本进程快照里还没有。这是 append-only
索引下跨进程可见性的补偿。

**一致性保证三：签名稳定顺序**。commit 双写在 `commit_tree_extended`
（commit.c:1773-1849）：compat 缓冲先翻译树/父/mergetag（:1780-1797，
mergetag 经 convert_commit_extra_headers :1409-1440，转换点 :1422）。签名头
顺序会改变内容→改变另一算法的哈希，故必须全局定序（commit.c:1821-1827）：

```c
		/*
		 * We write algorithms in the order they were implemented in
		 * Git to produce a stable hash when multiple algorithms are
		 * used.
		 */
		if (r->compat_hash_algo && hash_algo_by_ptr(bufs[0].algo) > hash_algo_by_ptr(bufs[1].algo))
			SWAP(bufs[0], bufs[1]);
```

按算法实现先后（sha1=1 < sha256=2）排序，两份缓冲施加同序双签
（:1833-1839）；签名头名 `gpg_sig_headers[] = { NULL, "gpgsig", "gpgsig-sha256" }`
（:1148-1152）；compat 内容哈希出 compat_oid 后一并交写入口（:1842-1849）。
tag 同理互嵌签名：主签名也进 compat 缓冲，compat 签名也嵌回主缓冲
（builtin/tag.c:176-189）。

**内容转换器**。`convert_object_file`（object-file-convert.c:253-290）对
"同算法或 blob" 直接 `BUG`（:263-265），分派：树逐项翻译重拼，宽度各用
from/to->rawsz（:72-96）；tag 保留双向签名（:98-148）；commit 逐行改写
tree/parent/mergetag，**未知 header 一律拒绝**——"might embed an oid"
（:234-237），是迁移安全的保守底线。

**compat 的边界**：
- 官方定位"未完成"：仅开发测试用途、不面向最终用户
  （config/extensions.adoc:6-17；RelNotes/2.51.1.adoc:17-20）；
- fast-import 内签名不支持：`die("signing commits in interoperability mode
  is unsupported")`（builtin/fast-import.c:2953-2962）；
- 跨格式传输不支持：fetch 请求即 `die("mismatched algorithms...")`
  （connect.c:733-739）；接收端 `die("error: unsupported object format...")`
  （builtin/receive-pack.c:2233-2240）。设计文档设想的"取 SHA-1 包转 SHA-256
  入库"尚未实现（hash-function-transition.adoc:127-136 为目标态）；
- pack 只存主格式：compat 名访问已打包对象依赖映射行存在；repack 时
  `loosen_unused_packed_objects` 把未进新包的对象 `force_object_loose`
  重新松散化并补建映射（builtin/pack-objects.c:4630-4697，映射点 :4655-4661）；
- compat 只能指定一次（setup.c:681-687）且须异于 objectFormat
  （extensions.adoc:8-9；同值 BUG，repository.c:203）；
- 用户接口：`git rev-parse --show-object-format[=storage|compat|input|output]`，
  compat 未配置输出空行（builtin/rev-parse.c:1121-1132）。

## 4. 传输协商专节：object-format capability

**v2**。object-format 是独立 capability，advertise/receive 成对注册
（serve.c:165-170）。服务端通告本仓库算法（serve.c:57-63）：

```c
static int object_format_advertise(struct repository *r,
				   struct strbuf *value)
{
	if (value)
		strbuf_addstr(value, r->hash_algo->name);
	return 1;
}
```

客户端锁定 `reader->hash_algo`（connect.c:497-509）：未知格式
`die("unknown object format '%s' specified by server")`（:501-502）；
**服务端未通告则回落 `GIT_HASH_SHA1_LEGACY`**（:508）。fetch 请求再校验
（connect.c:733-739）：

```c
	if (server_feature_v2("object-format", &hash_name)) {
		const unsigned int hash_algo = hash_algo_by_name(hash_name);
		if (hash_algo_by_ptr(the_hash_algo) != hash_algo)
			die(_("mismatched algorithms: client %s; server %s"),
			    the_hash_algo->name, hash_name);
		packet_buf_write(req_buf, "object-format=%s", the_hash_algo->name);
	} else if (hash_algo_by_ptr(the_hash_algo) != GIT_HASH_SHA1_LEGACY) {
		die(_("the server does not support algorithm '%s'"),
		    the_hash_algo->name);
	}
```

即 v2 下 SHA-256 客户端连不上沉默的服务器——沉默即 sha1。服务端接收客户端
声明的算法存入 `client_hash_algo`（serve.c:65-74）。

**v0/v1**。ref 广告行 capability 追加 `object-format=%s`（upload-pack.c:1214）；
客户端解析时缺席默认 legacy sha1（connect.c:247-258）。push 方向：send-pack 写入
capability（send-pack.c:597），receive-pack 通告（:280）、校验客户端请求
（:2233-2240）。

**立场**：协议层做"对等断言"而非"网关转换"，跨格式 fetch/push 转换仍是
transition 计划中的目标（hash-function-transition.adoc:649-664）。

## 5. 设计动机

**为什么离开 SHA-1**。2017-02-23 SHAttered（shattered.io）演示实用化 SHA-1
碰撞；Git v2.13.0 起默认加固版 SHA-1（HMAC 式碰撞检测），"isn't vulnerable
to the SHAttered attack, but SHA-1 is still weak"，且无法保证未来攻击有缓解
手段（hash-function-transition.adoc:28-44）。哈希是 Git 的内容寻址与信任锚：
哈希不可信则"该 hash 代表已知良好内容"的通信前提崩塌（:36-44）。选 SHA-256：
256 位匹配主流实践、OpenSSL/Apple CommonCrypto 有高质量实现、需要碰撞/第二
原像抗性而不需要抗长度扩展（:49-70）。

**为什么双写而非一刀切**。文档"Alternatives considered"否决了 flag-day 方案
（内核级项目无法全员同步切换，:716 起）。compat 让老用户以 SHA-1 名、新用户以
SHA-256 名共用一库，双签名保证两端均可验证（:691-695）；代价是映射表与转换器，
故明确限定为过渡脚手架。仓格式以 `repositoryFormatVersion=1` + extensions 保证
老 Git **死在门口**而非写坏仓库（:152-171 给出两个时代的报错样例）。

**边界哲学**。存储层单格式、逻辑层双名字：避免每对象两份实体与 pack 分叉；所有
跨格式访问收敛到 `repo_oid_to_algop`（名字）与 `convert_object_file`（内容）
两个函数。转换器覆盖不了的一律拒绝：未知 commit header（object-file-convert.c
:234-237）、fast-import 签名（fast-import.c:2961）、跨格式传输（connect.c:736）。

## 6. FAQ 素材

1. **SHA-256 仓库在磁盘上如何声明格式？** `core.repositoryFormatVersion=1`
   + `extensions.objectformat=sha256`；init 非 sha1 自动写入并抬版本
   （setup.c:2450-2469）。
2. **老版本 Git 打开会怎样？** 报 "Expected git repo version <= 0, found 1"
   或 "unknown repository extensions found: objectformat"，拒绝操作
   （hash-function-transition.adoc:162-171）。
3. **一个对象真的存两份吗？** 不。物理只有主格式一份；compat oid 记录在
   loose-object-idx；树/commit/tag 的 compat 内容读路径即时转换
   （odb.c:702-710），blob 只重哈希（odb.c:1045-1046）。
4. **映射存哪、什么格式？** objects/loose-object-idx，首行
   `# loose-object-idx`，每行双 oid，append-only + lockfile
   （loose.c:15,182-200）。
5. **pack/idx 里有 hash 类型字段吗？** pack 头仅 "PACK"+版本+对象数
   （pack-write.c:361-368），hash 语义在 trailer 长度与 idx 表项宽度；四字节
   format_id 用于 .rev/.mtime 与 reftable 头（pack-write.c:201,307）。idx v2
   尾部为"pack 内容哈希 + idx 自身哈希"双校验（pack-write.c:175 及 hashfile
   finalize），load_idx 按 `4*256+hashsz+hashsz+nr*(hashsz+4)` 反推宽度
   （packfile.c:138-162）。
6. **SHA-256 的 ref 存储与 SHA-1 有何不同？** files 后端无差别——一行 hex
   文本，长度取 `hash_algo->hexsz`（refs/files-backend.c:2067）；reftable
   在文件头写 hash_id，由 format_id 映射（refs/reftable-backend.c:424-434；
   reftable/writer.c:105-118）。
7. **传输两端怎么确认 hash？** v2 capability `object-format=<name>` 双向
   通告（serve.c:165-170）；缺席一律当 sha1（connect.c:508,257-258）；
   不一致断连（connect.c:736，receive-pack.c:2239）。
8. **compat 下 GPG 签名怎么办？** 双签名：commit 用 `gpgsig` 与
   `gpgsig-sha256` 头（commit.c:1148-1152），按算法实现顺序插入保证哈希
   稳定（commit.c:1821-1827）；tag 双向互嵌签名（builtin/tag.c:181-189）。
9. **新仓库默认 SHA-256？** 默认仍 sha1，除非 `WITH_BREAKING_CHANGES`
    编译（hash.h:196-200）；可 `git init --object-format=sha256`
    （builtin/init-db.c:59,110,171）。

## 7. 深挖建议

1. **签名稳定顺序形式化**：从 `add_header_signature` 插入位置
   （commit.c:1153 起）推演 SWAP 条件（commit.c:1826）为何在两个方向都使
   同一逻辑 commit 的两种编码逐字节可预期。
2. **映射缺失实验**：向 SHA-256 仓库注入无映射行的 pack，用 compat 名访问，
   观察 `die("missing mapping of %s to %s")`（odb.c:670-673）；再跑
   `git repack` 看 force_object_loose 补建映射（pack-objects.c:4675-4697）。
3. **双哈希成本模型**：compat 松散写需两个 git_hash_ctx、双喂 zlib
   （odb/source-loose.c:700-743）；注意 `odb_freshen_object` 短路
   （odb.c:1037）对重复对象的豁免。
4. **`WITH_BREAKING_CHANGES` 语义边界**：除翻转 GIT_HASH_DEFAULT（hash.h
   :196-200）外还影响什么？grep 引用面评估"默认 sha256"是否足以构成"破坏性变更"。
5. **Rust 门控的来龙去脉**：repository.c:202-208 的 `WITH_RUST` 条件是
   2026 年新强约束，追对应提交确认 compat 功能迁入 Rust 的范围。

## 8. 写作要点速查表

| 要点 | 文件:行号 | 一句话 |
|---|---|---|
| vtable 定义 | hash.h:294-335 | name/format_id/rawsz/hexsz + 6 函数指针 + 哨兵 oid |
| the_hash_algo | hash.h:271-274 | 宏 = the_repository->hash_algo，每仓库指针 |
| oid 算法标签 | hash.h:229-233 | hash[GIT_MAX_RAWSZ] + uint32_t algo |
| format_id 常量 | hash.h:206,215 | 0x73686131 "sha1" / 0x73323536 "sha256" |
| 默认算法开关 | hash.h:196-200 | WITH_BREAKING_CHANGES → sha256 |
| compat 需 Rust | repository.c:202-208 | 非 WITH_RUST 构建直接 die |
| 扩展解析 | setup.c:660-689 | objectformat / compatobjectformat（仅一次） |
| 格式应用 | setup.c:1802-1803 | repo_set_(compat_)hash_algo |
| 映射表 | loose.h:8-12; loose.c:15,95-104 | 双 khash + loose-object-idx 行式双 oid |
| 双写总入口 | odb.c:1021-1061 | blob 重哈希，其余先 convert 再哈希 |
| 读路径转换 | odb.c:743-744,656-734 | 标签不符 → 即时反向转换 |
| 翻译+重载 | object-file-convert.c:38-48 | miss 后重读索引防跨进程盲区 |
| 双签名稳定序 | commit.c:1821-1827,1148-1152 | gpgsig/gpgsig-sha256 按算法序 SWAP |
| idx 双校验尾 | packfile.c:138-162 | pack 哈希 + 文件哈希，宽度按 hashsz 反推 |
| ref 两后端 | files-backend.c:2067; reftable-backend.c:424-434 | hex 文本 vs 头部 hash_id |
| v2 协商 | serve.c:165-170; connect.c:497-509,733-739 | 缺席默认 sha1，不一致 die |
| 官方未完成声明 | extensions.adoc:15-17 | compat 仅开发测试用途 |
| SHAttered 动机 | hash-function-transition.adoc:31-33 | 2017-02-23 实用碰撞 |
