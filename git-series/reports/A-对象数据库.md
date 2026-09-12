# Git 深读 · A 篇:对象数据库(blob / tree / commit / tag 与 loose 存储)

> 源码版本:git commit `47ce805`("A bit more for -rc1",shallow clone)。所有 `文件:行号` 均以该 commit 为准,经 grep -n / Read 逐一核对。
> 说明:此版本正值 ODB(object database)子系统重构落地:传统 `object-file.c` 中"一锅端"的读写代码正在拆分为 `odb/` 下的多后端(source-loose / source-packed / in-memory),旧的 `write_object_file()` 已演进为 `odb_write_object()`。文中两条链路都会标注。

---

## 1. 全景:四类对象与内容寻址

Git 的本体是一个 **键值数据库**:键是内容的哈希,值是四类对象。所有上层概念(分支、diff、历史)都是这四类对象的推论:

| 类型 | 常量 | 内容 | 指向谁 |
|---|---|---|---|
| blob | `OBJ_BLOB=3` | 文件内容原文 | 无 |
| tree | `OBJ_TREE=2` | 目录快照(条目列表) | blob / tree / commit(gitlink) |
| commit | `OBJ_COMMIT=1` | tree 指针 + 父 commit + 元数据 | tree / commit |
| tag | `OBJ_TAG=4` | 被签对象 + 标签名 + 签名 | 任意对象(可嵌套 tag) |

类型枚举 `object.h:98-110`,注意其数值**是 pack 文件格式的一部分**(`object.h:94-97` 注释明确指出),`OBJ_OFS_DELTA=6`、`OBJ_REF_DELTA=7` 只存在于 pack 中,loose 对象永远不会用到(见 `object.h:105-107`)。

内容寻址全链路(以 `echo "hello" | git hash-object -w --stdin` 为例):

```
工作区内容 "hello\n"
      │  ① 拼对象头(类型 + 长度)           format_object_header  object-file.c:102
      ▼
   "blob 6\0" + "hello\n"          ← 头也参与哈希,类型/长度因此防篡改
      │  ② 计算哈希                        hash_object_file      object-file.c:459
      ▼
   ce013625030ba8dba906f756967f9e9ca394464a
      │  ③ 前两个 hex 字符作为一级目录       fill_loose_path       object-file.c:46
      ▼
   .git/objects/ce/013625030ba8dba906f756967f9e9ca394464a
      │  ④ zlib deflate 压缩后落盘          write_loose_object    odb/source-loose.c:770
      ▼
   44 字节头("blob 6\0"+内容) --deflate--> 磁盘文件
```

**不可变性是免费获得的**:对象名 = H(头+内容)。任何字节改动都会得到新哈希、新路径,旧对象原封不动;因此"修改历史"在对象库层面根本不存在,只能新增对象、移动引用。同时哈希即校验和——读取路径会重算哈希并比对(`check_object_signature`,`object-file.c:113-124`;`parse_object_with_flags` 中 `object.c:380-384`),磁盘损坏无法静默传播。

对象之间的引用构成一张 **有向无环图(DAG)**:

```
 tag "v1.0" ──object──> commit ──tree──> tree(dir)──┬─"100644 hello.txt"──> blob
                        ^  │                        └─"40000 src"───────> tree(递归)
              parent    |  └──tree──> ...
                        |
                   父 commit
```

---

## 2. 对象类型系统:C 语言里的"面向对象"

### 2.1 struct object 首部多态

Git 用 **首部嵌入 + 指针强转** 模拟继承。公共基类只有 4 个字段(`object.h:159-164`):

```c
struct object {
    unsigned parsed : 1;
    unsigned type : TYPE_BITS;      /* 3 bit,object.h:92 */
    unsigned flags : FLAG_BITS;     /* 29 bit,object.h:90 */
    struct object_id oid;
};
```

四个子类都以 `struct object object` 开头:

- `struct blob { struct object object; }` —— blob 最"穷",连内容指针都没有(`blob.h:8-10`);
- `struct tree { struct object object; void *buffer; unsigned long size; }`(`tree.h:10-14`);
- `struct commit { ...; timestamp_t date; struct commit_list *parents; struct tree *maybe_tree; }`(`commit.h:27-39`);
- `struct tag { struct object object; struct object *tagged; char *tag; timestamp_t date; }`(`tag.h:8-13`)。

`(struct object *)commit` 与 `&commit->object` 是同一地址,所以 `obj->type` 判断后可直接强转回子类指针。`flags` 的 29 个 bit 是全仓库共享的稀缺资源,`object.h:66-89` 用一张注释表登记了每个子系统占用的位,防止冲突。

### 2.2 lookup_* 家族与类型 dispatch

每个 `lookup_blob/lookup_tree/lookup_commit/lookup_tag` 都是同一模板:先查进程内哈希表 `lookup_object()`,查不到就 `create_object()` 分配(经 `alloc.c` 的 slab 分配器,`alloc.c:79-124`),查到了但类型不符则走 `object_as_type()`(`object.c:165-183`):

```c
void *object_as_type(struct object *obj, enum object_type type, int quiet)
{
    if (obj->type == type)
        return obj;
    else if (obj->type == OBJ_NONE) {          /* 尚未知类型:就地定型 */
        if (type == OBJ_COMMIT)
            init_commit_node((struct commit *) obj);
        else
            obj->type = type;
        return obj;
    } else { ... error(_("object %s is a %s, not a %s"), ...); return NULL; }
}
```

`lookup_object_by_type()`(`object.c:193-209`)是显式 switch 分发;同一 oid 重复要求不同类型会报 "is a X, not a Y"——这就是用户看到的类型冲突错误的源头。

进程内对象表是 **开放寻址哈希表**(非链表法):`hash_obj()` 取 oid 前 4 字节做键(`object.c:66-69`),冲突线性探测(`insert_obj_hash`,`object.c:76-86`);`lookup_object()` 命中后还会把元素**换到探测起点**,让二次查找一步命中(`object.c:108-116`)。装载超过一半即倍增,最小 32 桶(`grow_object_hash`,`object.c:125-146`;扩容条件 `object.c:156-157`)。所有对象挂在 `parsed_object_pool` 上按 slab 整块释放,不做逐对象 free(`object.h:9-33`;`parsed_object_pool_clear`,`object.c:583-622` 注释解释了原因)。

`struct object_array`(`object.h:44-59`)是 revision.c 等遍历器的工作队列,条目除对象指针外还携带 `name`(如 `HEAD^`)、`path` 与 `mode`,插入逻辑在 `add_object_array_with_path()`(`object.c:444-474`,空串用静态 slopbuf 免分配,`object.c:436`)。

### 2.3 parse_object:缓存 + 校验的读入口

`parse_object_with_flags()`(`object.c:322-396`,薄封装 `parse_object()` 在 `object.c:398-401`)是"给我一个解析好的对象"的统一入口,做了四层优化:

1. **已解析直接返回**:`obj && obj->parsed` 即缓存命中(`object.c:335-337`);
2. **commit-graph 快捷通道**:`PARSE_OBJECT_SKIP_HASH_CHECK` 时先查 commit-graph 免解压(`object.c:339-343`;commit-graph 只提一句:它是 commit 元数据的旁路缓存,本篇不展开);
3. **blob 流式校验**:blob 无需构造子结构,直接开流重算哈希(`stream_object_signature`,`object.c:345-365` 调 `object-file.c:126-152`),边流边 hash,避免整块载入;
4. **常规路径**:`odb_read_object()` 读出全文 → `check_object_signature()` 重算哈希比对(`object.c:378-385`)→ 按 type 分派给 `parse_object_buffer()`(`object.c:261-309`)。

`parse_object_buffer` 的分派一目了然:blob → `parse_blob_buffer`(仅置 parsed 位,`blob.c:15-18`,blob 无内容可解析);tree → `parse_tree_buffer`(只挂 buffer,`tree.c:175-184`);commit → `parse_commit_buffer`;tag → `parse_tag_buffer`。

哈希校验可用标志跳过:`PARSE_OBJECT_SKIP_HASH_CHECK`(`object.h:223`),fsck 类工具用 `PARSE_OBJECT_DISCARD_TREE`(`object.h:224`)解析完立刻释放 tree buffer 省内存(`object.c:391-392`)。

另一处类型收口是 **peel**(剥 tag 到非 tag 对象):`peel_object_ext()` 沿 `((struct tag *)o)->tagged` 循环下钻(`object.c:230-243`),ref 存储的 peeled 值即来源于此语义。

---

## 3. loose object 存储:一条对象的完整一生

### 3.1 落盘格式

loose 对象 = **zlib deflate( "<type> <size>\0" + 内容 )**。头最长 32 字节(`MAX_HEADER_LEN`,`object-file.h:11`),由 `format_object_header()` 用 `"%s %"PRIuMAX` 生成并计入返回长度(+1 是 NUL)(`object-file.c:102-111`)。哈希覆盖头+内容(`hash_object_file`,`object-file.c:459-473`)——这就是"内容寻址"的精确含义:**寻址的是(头,内容)二元组**。

路径规则在 `fill_loose_path()`(`object-file.c:46-58`):逐字节输出 hex,在第一个字节后插一个 `'/'`;`odb_loose_path()` 拼上对象目录前缀(`object-file.c:60-69`)。SHA-1 时路径深 2+38,SHA-256 时 2+62。

### 3.2 写路径行号链(hash-object → 磁盘)

入口 `git hash-object -w`:`cmd_hash_object()`(`builtin/hash-object.c:64`),默认类型 blob(`:75`),`-w` 置 `INDEX_WRITE_OBJECT`(`:85-86`),落到 `hash_fd()` → `index_fd()`(`builtin/hash-object.c:23-34` → `object-file.c:942`)。此后:

1. `index_fd()` 常规文件 ≤ `core.bigFileThreshold`(默认 512MiB,`repo-settings.c:171`)走 `index_core()`(`object-file.c:650-677`,≤32KiB 直接 read,否则 mmap);
2. `index_mem()`(`object-file.c:564-605`):blob 先过 `convert_to_git()` 行尾/过滤器(`:580-586`);默认 `INDEX_FORMAT_CHECK` 会跑 fsck 拒绝畸形对象(`:587-596`);最后 `odb_write_object()`(`:599`);
3. `odb_write_object()`(内联,`odb.h:681-687`)→ `odb_write_object_ext()`(`odb.c:1021-1061`):先 `hash_object_file()` 算 oid(`odb.c:1028`);**对象已存在则只 freshen mtime 直接返回**(`odb.c:1035-1039`);
4. → `odb_source_write_object()`(内联,`odb/source.h:497-507`)→ 多后端分派 `source->write_object`,files 后端即 `odb_source_loose_write_object()`(`odb/source-loose.c:832-853`,vtable 装配于 `:1059`);
5. → `write_loose_object()`(`odb/source-loose.c:770-830`),核心三段:
   - `start_loose_object_common()`(`:674-718`):`create_tmpfile()` 在**目标同目录**建 `tmp_obj_XXXXXX`(0444,目录不存在则自动 mkdir,`:633-661`);`git_deflate_init()` 用 `core.compression` 派生的 `zlib_compression_level`(默认 `Z_BEST_SPEED`,`environment.c:767`);先喂头并同步哈希(`:709-715`);
   - `write_loose_object_common()`(`:724-744`):deflate 循环,哈希与写盘同步推进;
   - `end_loose_object_common()`(`:752-768`):收尾取哈希。**写完后用重算的 `parano_oid` 与预期 oid 比对**,不一致即 die("confused by unstable object source data")(`:811-813`)——防止内容在压缩期间被并发修改;
6. fsync 策略:`close_loose_object()`(`:598-615`)支持 batch-fsync;
7. 原子可见:`finalize_object_file_flags()`(`object-file.c:392-457`)优先 `link()`(同目录硬链接,`ObjectCreationMode` 可改 rename,`:403-408`);EEXIST 时做**逐字节碰撞检查**(`check_collision`,`object-file.c:329-381`)——同一哈希内容却不同即报错,这是防御(理论上的)哈希碰撞/磁盘位腐的最后一道闸。临时文件 0444 + 硬链接意味着已发布对象天然只读。

流式写(不知道哈希前不能定路径)走 `odb_source_loose_write_object_stream()`(`odb/source-loose.c:855-977`):先写临时文件,`end_loose_object_common()` 之后才得到 oid,再补建 `xx/` 目录并 finalize(`:952-970`);若期间对象已被他人写入,直接删临时文件(`odb_freshen_object` 分支,`:948-951`)。超过 `bigFileThreshold` 的大文件连 loose 都不落:流式直接写进临时 packfile(`index_fd` 大文件分支 `object-file.c:963-976` → 事务写 `odb_transaction_files_write_object_stream()` `:882-940` + `stream_to_pack()` `:751-812`)——这是 loose→pack 生命周期的第一个伏笔。

### 3.3 读路径

`odb_read_object()`(`odb.c:781`)→ files 后端 `read_object_info_from_path()`(`odb/source-loose.c:66-214`):mmap(空文件禁止 mmap,显式报错 `:138-141`)→ `unpack_loose_header()` 解出头(`object-file.c:177-209`,返回 `ULHR_OK/ULHR_BAD/ULHR_TOO_LONG`)→ `parse_loose_header()` 手工解析 `<type> <len>\0`、拒绝 "010" 这类非规范长度(`object-file.c:271-325`,注释明说嫌弃 sscanf 太宽松)→ `unpack_loose_rest()` 解出全文并校验 Z_STREAM_END 与无尾随垃圾(`object-file.c:211-257`,`:224-237` 的大段注释解释为何必须把 zlib 流"喂到底")。

存在性检查可走缓存:`odb_source_loose_cache()` 按 **第一字节(0-255)子目录** 做 oidtree 惰性缓存 + 位图去重(`odb/source-loose.c:28-58`),`quick_has_loose()` 免开文件(`:60-64`)。全量枚举走 `for_each_file_in_obj_subdir()`(`object-file.c:1041-1109`):文件名长度必须 == hexsz-2 且能解码为字节,否则归为 cruft(`:1080-1098`)。

### 3.4 alternates:对象库的"继承"

`.git/objects/info/alternates` 允许一个仓库借用别的对象目录(典型:测试套件借用主仓库对象)。解析在 `parse_alternates()`(`odb.c:137-195`):支持 `#` 注释、C 风格引号路径、相对路径基于当前对象目录取 realpath。装配在 `odb_add_alternate_recursively()`(`odb.c:204-239`):**alternate 还可以有自己的 alternates,递归深度上限 5**(`:229-231`);准入检查 `odb_is_source_usable()`(`odb.c:94-126`)拒绝目录不存在、重复路径与主对象目录自身。运行时读对象按 source 链表顺序探测(`odb_read_object_info_extended`,`odb.c:736`)。写永远只写主库,fetch-pack 等需感知 alternate 边界时另有 `read_alternate_refs()`(`odb.c:425`)。

### 3.5 freshen:防误剪的心跳

对象是否可被 `git gc` 清理由 mtime 决定。写重复对象时,若目标已存在则 `check_and_freshen_file()` 用 `utime()` 续命后跳过写入(`object-file.c:92-100`、`freshen_file()` `:72-83`;调用点 `odb.c:1035-1039` 与流式路径 `odb/source-loose.c:948`)。注释(`object-file.c:85-91`)提醒:freshen 失败不代表可以不写——文件可能正被并发 prune。

---

## 4. tree 与 commit 的二进制格式

### 4.1 tree 条目:逐字节

tree 对象内容是若干条目直接拼接,无分隔符、无条目长度字段:

```
"<mode-octal-ASCII> <name>\0<raw-oid (hashsz 字节,非 hex)>"
 ^                 ^      ^
 |                 |      NUL 终止名字
 |                 一个空格
 mode 如 "100644"、"40000"(目录无前导 0)
```

解析器 `decode_tree_entry()`(`tree-walk.c:17-48`):

```c
if (size < hashsz + 3 || buf[size - (hashsz + 1)]) {
        strbuf_addstr(err, _("too-short tree object"));
        return -1;
}
path = parse_mode(buf, &mode);          /* object.h:200-215,八进制到空格为止 */
...
len = strlen(path) + 1;
desc->entry.path = path;
desc->entry.mode = (desc->flags & TREE_DESC_RAW_MODES) ? mode : canon_mode(mode);
desc->entry.pathlen = len - 1;
oidread(&desc->entry.oid, (const unsigned char *)path + len, desc->algo);
```

三个要点:(a) 尾部哨兵——`buf[size-(hashsz+1)]` 必须为 0,即最后一条目的名字 NUL 必须恰好落在 raw oid 之前,截断的树当场报错;(b) mode 用 `parse_mode()`(`object.h:200-215`)手写八进制解析,遇非八进制字符返回 NULL;`canon_mode()`(`object.h:145-154`)把 100664 这类历史遗留模式收敛为 100644/100755/120000/160000/040000 中的一个;(c) oid 是**原始 20/32 字节**,不 hex 编码——这是 tree 紧凑的关键。

迭代即指针推进:`update_tree_entry_internal()` 计算下一条目地址 = `path + pathlen + 1 + rawsz`(`tree-walk.c:112-128`),`tree_entry()`(`:152-160`)取当前条目并推进。子目录递归遍历的骨架在 `read_tree_at()`(`tree.c:14-86`),gitlink 条目(mode 0160000,`object.h:121-122`)被特殊处理为解析子模块 HEAD(`tree.c:56-71`)。

**排序规则**是 tree 格式的隐形契约:条目按名字排序,且目录名参与比较时视为带尾部 `/`(`base_name_compare()`,`tree.c:99-116`)。这保证"同一个目录在任何引用它的 tree 里字节级相同",从而子树哈希可全局短路复用。

### 4.2 commit:parent 链如何成 DAG

commit 对象是纯文本:

```
tree <40 hex>
parent <40 hex>          (0..n 行)
author A U Thor <a@e> 1712345678 +0800
committer ...

message
```

`parse_commit_buffer()`(`commit.c:516-598`)的解析器是纯指针算术:`tree_entry_len = hexsz+5`、`parent_entry_len = hexsz+7`(`commit.c:523-524`);校验 `tree ` 前缀与定长换行(`commit.c:539-544`);`lookup_tree()` 挂上根 tree(`commit.c:545-550`);随后 parent 循环(`commit.c:557-577`):

```c
while (bufptr + parent_entry_len < tail && !memcmp(bufptr, "parent ", 7)) {
        ...
        new_parent = lookup_commit(r, &parent);      /* 惰性创建父 commit 节点 */
        ...
        pptr = &commit_list_insert(new_parent, pptr)->next;
}
```

**DAG 的构造方式**:`lookup_commit()`(`commit.c:101-107`)只是查/建一个"半初始化"节点(仅 oid+类型,未解析;此语义在 `object.h:181-192` 有专门注释),并不递归读盘。于是解析一个 commit 只付出 O(父数) 次哈希表插入,历史遍历按需逐个 `parse_commit` 展开——环不可能出现,因为能成为 parent 的 oid 本身就指向更早的快照。graft(嫁接,含 shallow)可在解析时**替换/删除真实 parent**(`commit.c:554-556`、`:578-590`),这是浅克隆在不改对象的前提下改写历史的机制。日期从 author/committer 行尾解析(`parse_commit_date()`,`commit.c:128`,取值在 `:591`)。commit 缓冲本体可存入 per-pool 的 buffer_slab 供后续取用(`set_commit_buffer`/`get_cached_commit_buffer`,`commit.c:369-389`)。

完整读入口 `repo_parse_commit_internal()`(`commit.c:600-660`):先问 commit-graph(`:625-639`,一句话:图缓存可直接重建 commit 元数据,跳过对象读取),否则 `odb_read_object_info_extended` 读全文再进 `parse_commit_buffer`。

### 4.3 tag:可递归的注释对象

`parse_tag_buffer()`(`tag.c:130-204`)按行解析 `object <hex>`(`:153-156`)、`type <t>`(`:158-166`)并按类型 dispatch 到四个 lookup_*(tag.c:168-179)——`type tag` 合法,所以 annotated tag 可嵌套(`:174-175`);随后 `tag <name>`(`:186-195`)与可选 `tagger` 行取日期(`:197-200`)。tag 还能携带 GPG 签名(`gpg_verify_tag()`,`tag.c:47-74`)。剥壳语义 `deref_tag()` 沿 `tagged` 链循环(`tag.c:76-95`),与 `peel_object_ext` 互为表里。

---

## 5. 哈希抽象:the_hash_algo 与 SHA-256 迁移

### 5.1 双算法的接口设计

核心是 **算法描述符结构体 + 函数指针 vtable**(`hash.h:294-335`):

```c
struct git_hash_algo {
    const char *name;          /* "sha1" / "sha256" */
    uint32_t format_id;        /* "sha1"=0x73686131 (hash.h:206),"s256"=0x73323536 (:215) */
    size_t rawsz, hexsz, blksz;/* 20/40/64 或 32/64/64 */
    git_hash_init_fn init_fn;  /* clone/update/final/final_oid/discard 一组函数指针 */
    ...
    const struct object_id *empty_tree, *empty_blob, *null_oid;
};
```

全局数组 `hash_algos[GIT_HASH_NALGOS]`(`hash.h:336`,定义 `hash.c:205`)按 `GIT_HASH_UNKNOWN/SHA1/SHA256`(`hash.h:187-193`)索引;代码里几乎不写死算法,而是用 `the_hash_algo`(宏,`hash.h:271-274`,即 `the_repository->hash_algo`)。运行上下文携带算法:哈希上下文 `git_hash_ctx` 用 union 同时容纳 SHA-1/SHA-256 状态(`hash.h:277-285`);oid 自带 `algo` 字段(`struct object_id`,`hash.h:229-232`)——`object-file.c:117-118` 演示了"oid 声明自己属于哪个算法"的典型用法。比较辅助函数对长度特化以便编译器内联(`hashcmp()`,`hash.h:400-409`;`oideq` 直接 memcmp 全宽 32 字节,`hash.h:438-441`,sha1 时高位补零保证安全)。

底层实现可插拔(hash.h:4-73):SHA-1 可选 OpenSSL / Apple CommonCrypto / 自研 block-sha1 / **SHA1_DC 冲突检测版**(SHA-1 shatter 之后的防碰撞后端,`hash.h:14-16`);SHA-256 可选 Nettle / Gcrypt / OpenSSL / 自研。另有一组 `_unsafe` 快速变体(`hash.h:22-54`)用于非对抗场景(哈希表键等)。

### 5.2 迁移机制的两个抓手

1. **默认算法开关**:`GIT_HASH_DEFAULT` 仍是 SHA-1,但 `WITH_BREAKING_CHANGES` 编译期可切为 SHA-256(`hash.h:196-200`)。
2. **compat 双写**:仓库可同时声明 `hash_algo` 与 `compat_hash_algo`。写对象时 `odb_write_object_ext()` 一并算出兼容算法下的 `compat_oid`(blob 直接重哈希,其他类型经 `convert_object_file` 转换,`odb.c:1041-1056`),loose 写路径把它登记进双向映射表(`repo_add_loose_object_map`,`odb/source-loose.c:849-850`、流式 `:971-972`)。空树/空 blob/全零 oid 也按算法各备一份(`hash.c:5-32`、`:200-201`),`is_empty_tree_oid()` 等以算法指针为参(`hash.h:507-517`)。

---

## 6. 设计动机

**为什么内容寻址?** 一个决定换来四件事:(1) 去重——同内容同哈希,写前 `odb_freshen_object` 探测即可跳过(§3.2);(2) 完整性——哈希即校验和,读路径默认复验(§2.3),对象头也入哈希,类型/长度不可篡改(§3.1);(3) 不可变语义——对象一旦命名即冻结,版本控制只剩"追加对象+移动引用";(4) 无中心协调的分布式——oid 全局唯一,克隆/推送无需命名仲裁。

**为什么 tree 是目录快照而非 diff?** 快照让"子树相同 ⇒ 子树哈希相同"成为 O(1) 判断:未改动的目录在新 commit 中直接复用旧 tree 对象,历史对比、rename 检测、三方合并都退化为哈希比较;代价是每次提交要为新改动路径沿途所有目录重写 tree 对象——但配合内容寻址的去重,这笔开销远小于维护增量 diff 链的复杂度。tree 排序规则(§4.1)与原始字节 oid 则是让"字节级稳定"成立的两个工程细节。

**loose→pack 的生命周期伏笔。** loose 对象是"一对象一文件"的极简设计:写入原子(tmpfile+link)、读取 mmap、单对象修复容易;但对象一多,inode 与目录项开销失控。于是设计上处处留了衔接:大文件写入时直接进临时 packfile 而不落 loose(§3.2 末);`git gc` 后 `for_each_loose_file_in_source()`(`object-file.c:1111-1130`)枚举剩余 loose 对象做迁移/prune;freshen 机制(§3.5)则保证"仍被引用的 loose 对象不被 gc 误剪"。loose 是热的、临时的;pack 是冷的、归档的——本篇的 loose 读取原语(`unpack_loose_header/parse_loose_header/unpack_loose_rest`)在 pack 侧也有对应物,是 B 篇(packfile)的天然入口。

---

## 7. FAQ 素材

1. **对象名到底哈希了什么?** `"<类型> <字节数>\0" + 内容`,头一起入哈希(`hash_object_file`,`object-file.c:459-473`);所以改类型或长度必然换名字。
2. **为什么 loose 对象目录是 256 个两位 hex 子目录?** 单目录文件数过多拖垮文件系统;`fill_loose_path` 取首字节分桶(`object-file.c:46-58`),进程内再做 per-subdir oidtree 缓存(`odb/source-loose.c:28-58`)。
3. **git show 看到的 commit 是解析后的什么?** `struct commit`:根 tree、parents 链、date(`commit.h:27-39`);message 不在结构体里,按需从缓存的原始 buffer 取(`commit.c:377-389`)。
4. **blob 为什么"解析"是空操作?** blob 无内部结构,`parse_blob_buffer` 只置 parsed 位(`blob.c:15-18`);它的解析成本就是一次哈希校验(`object.c:345-365` 流式路径)。
5. **同一 oid 既是 commit 又被当 tree 用会怎样?** `object_as_type` 报 "object X is a commit, not a tree" 并返回 NULL(`object.c:165-183`)。
6. **tree 条目的 mode 有哪些合法值?** 解析后经 `canon_mode` 归一为 100644/100755/120000(符号链接)/160000(gitlink)/040000(目录,磁盘上写作 `40000`)(`object.h:145-154`,`tree-walk.c:42`)。
7. **parent 指针会构成环吗?** 不会;`lookup_commit` 只惰性建节点不递归(§4.2),而 graft/shallow 还能在解析期隐藏或替换 parent(`commit.c:569-570`、`:578-590`)。
8. **alternates 有什么坑?** 递归上限 5 层(`odb.c:229-231`);alternate 消失会在可用性检查时报 "check .git/objects/info/alternates"(`odb.c:104-107`);引用计数不跨库,gc 需感知边界。
9. **为什么重复添加同一文件秒完成?** `odb_write_object_ext` 先 freshen:对象已存在则 utime 后直接返回,不重写(`odb.c:1035-1039`)。
10. **SHA-256 仓库的对象名和 SHA-1 仓库互通吗?** 不互通;compat 机制靠映射表双向翻译(`odb.c:1041-1056`,`odb/source-loose.c:849-850`)。

## 深挖方向

1. **碰撞检查的真实语义**:`finalize_object_file_flags` 遇 EEXIST 时 `check_collision` 逐字节比对两文件(`object-file.c:329-381`,4KB 步长);哈希相同内容不同 → 硬错误。可顺带研究 SHA1_DC 后端何时必须启用。
2. **obj_hash 的 move-to-front**:`lookup_object` 探测命中后 SWAP 到起点(`object.c:108-116`),对"反复查同一对象"的 revision 遍历是零成本优化;可与 grow 阈值 `size-1 <= nr*2`(`object.c:156-157`)一起做个小实验。
3. **头部长度预算**:`MAX_HEADER_LEN 32`(`object-file.h:11`)对 SHA-256 + 超大对象是否够用?`ULHR_TOO_LONG` 路径(`object-file.c:199-208`)如何处理?可推算上限。
4. **ODB 重构的过渡形态**:`odb_write_object_flags.ODB_WRITE_OBJECT_PERSIST` 已声明但全树无人消费(`odb.h:656`,grep 仅此一处)——`odb_write_object` 目前总是落盘;这是观察 Git API 演进(先加标志位、后改默认行为)的活样本。
5. **fsync 分层**:batch 模式下先 `FSYNC_WRITEOUT_ONLY`、提交时一次性硬件 barrier(`object-file.c:523-546`、`:1259-1297`),对比 `core.fsync` 组件清单,理解"对象数据先于对象名字可见"的崩溃一致性论证。

---

## 写作要点速查表(函数 → 文件:行号)

| # | 函数/结构 | 位置 | 一句话 |
|---|---|---|---|
| 1 | `enum object_type` | object.h:98-110 | 4 类型 + 2 delta,数值属 pack 格式 |
| 2 | `struct object`(基类) | object.h:159-164 | parsed:1 + type:3 + flags:29 + oid |
| 3 | `object_as_type` | object.c:165-183 | 类型定型/冲突报错的收口 |
| 4 | `lookup_object` / `create_object` | object.c:92-118 / 148-163 | 开放寻址表 + move-to-front |
| 5 | `parse_object_with_flags` | object.c:322-396 | 缓存→graph→blob 流式→全文校验 |
| 6 | `check_object_signature` | object-file.c:113-124 | 读路径重算哈希比对 |
| 7 | `hash_object_file` | object-file.c:459-473 | H("<type> <len>\0"+内容) |
| 8 | `fill_loose_path` | object-file.c:46-58 | objects/xx/yyyy... 命名 |
| 9 | `write_loose_object`(写主链) | odb/source-loose.c:770-830 | deflate+哈希+paranoid 复核 |
| 10 | `finalize_object_file_flags` | object-file.c:392-457 | tmpfile→link/rename 原子发布+碰撞检查 |
| 11 | `unpack_loose_header`/`parse_loose_header`/`unpack_loose_rest` | object-file.c:177/271/211 | loose 读三件套 |
| 12 | `odb_write_object_ext` | odb.c:1021-1061 | freshen 短路 + compat_oid 双写 |
| 13 | `parse_alternates` / `odb_add_alternate_recursively` | odb.c:137 / 204 | alternates 解析与 5 层递归 |
| 14 | `decode_tree_entry` | tree-walk.c:17-48 | mode SP name NUL raw-oid 逐字节解析 |
| 15 | `update_tree_entry_internal` | tree-walk.c:112-128 | 条目推进:path+pathlen+1+rawsz |
| 16 | `parse_commit_buffer` | commit.c:516-598 | tree 行 + parent 循环 + graft + date |
| 17 | `lookup_commit`(惰性节点) | commit.c:101-107 | 半初始化节点 → DAG 展开 |
| 18 | `parse_tag_buffer` | tag.c:130-204 | object/type/tag 行,tag 可嵌套 |
| 19 | `struct git_hash_algo` / `the_hash_algo` | hash.h:294-335 / 271-274 | 算法 vtable + 仓库级算法选择 |
| 20 | `struct object_id` | hash.h:229-232 | 32 字节缓冲 + algo 自描述 |

(完,commit 47ce805)
