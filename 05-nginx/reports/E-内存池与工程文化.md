# E · 内存池、数据结构与工程文化 —— Nginx 核心基建源码深读

> 调研对象:nginx 主干(commit 231a60ee,2026-09-02,版本线 1.31.x)
> 读者定位:3-5 年后端经验工程师。所有结论均标注 `文件:行号`,行号对应该 commit 的源码。
> 本报告是《源码深读》系列第五卷 Nginx 分册的子系统调研材料。

---

## ① 全景:Nginx 的"无 free"世界观

Nginx 核心基建由一小组约 200-2000 行的 C 文件组成,彼此高度正交:

| 层 | 文件 | 职责 |
|---|---|---|
| 内存 | `ngx_palloc.c/.h` | 进程内 arena 内存池,小块/大块双轨 |
| 共享内存 | `ngx_slab.c/.h` | 多 worker 共享的 slab 分配器 |
| 字符串 | `ngx_string.c/.h` | `ngx_str_t`、自研 printf、转义表 |
| 缓冲 | `ngx_buf.c/.h` | 内存/文件双坐标 buf + chain 链 |
| 配置 | `ngx_conf_file.c` | 手写 tokenizer + 指令分发 |
| 模块 | `ngx_module.c/.h` | 静态数组 + 动态 .so 双轨模块系统 |
| 日志 | `ngx_log.c/.h` | 9 级日志 + 链式 log 结构 |
| 哈希 | `ngx_hash.c` | 预编译一次性 hash(含通配符树) |
| 构建 | `auto/` | 纯 POSIX sh 手写 configure |

理解 Nginx 的关键钥匙是它的资源模型:**对象生命周期与请求/周期绑定,内存只分配不逐个释放,整体随 pool 销毁**。HTTP 请求池在 `src/http/ngx_http_request.c:584` 由 `ngx_create_pool(cscf->request_pool_size, c->log)` 创建,请求结束时 `ngx_destroy_pool` 一次性归还。这换来的是 O(1) 的错误处理路径——任何中途失败都不需要逐层回滚 malloc,只需销毁 pool 或返回错误码。错误码体系同样极简:`NGX_OK=0 / NGX_ERROR=-1 / NGX_AGAIN=-2 / NGX_BUSY=-3 / NGX_DONE=-4 / NGX_DECLINED=-5 / NGX_ABORT=-6`(`src/core/ngx_core.h:39-45`),全项目共享这一组 int 返回值,没有 errno 风格的全局错误对象。

---

## ② 内存池逐段解读:ngx_palloc 的双轨设计

### 2.1 结构体与阈值

```c
/* src/core/ngx_palloc.h:49-65 */
struct ngx_pool_s {
    ngx_pool_data_t       d;      /* last/end/next/failed */
    size_t                max;    /* 小块上限 */
    ngx_pool_t           *current;/* 分配起点(跳过耗尽块) */
    ngx_chain_t          *chain;  /* 空闲 chain 节点回收站 */
    ngx_pool_large_t     *large;  /* 大块单链表 */
    ngx_pool_cleanup_t   *cleanup;/* 析构回调链 */
    ngx_log_t            *log;
};
```

三个关键常量:`NGX_MAX_ALLOC_FROM_POOL = (ngx_pagesize - 1)`(即 x86 上 4095,注释明确说 Windows 下减小它可减少内核锁定页,`ngx_palloc.h:16-20`);默认池大小 `NGX_DEFAULT_POOL_SIZE = 16 * 1024`(`ngx_palloc.h:22`);池自身 16 字节对齐 `NGX_POOL_ALIGNMENT = 16`(`ngx_palloc.h:24`)。

`ngx_create_pool` 的初始化逻辑(`ngx_palloc.c:18-43`):用 `ngx_memalign(NGX_POOL_ALIGNMENT, size, log)` 整块申请,`p->d.last` 指向 header 之后,`p->max = min(size - sizeof(ngx_pool_t), NGX_MAX_ALLOC_FROM_POOL)`(`ngx_palloc.c:33-34`)——**max 就是大小块分界线**,默认 16K 池下为 4095。

双轨布局如下(以 16K 池为例):

```
        小块轨道(arena,Bump-Pointer)                大块轨道(直接 malloc)
+-----------------------------------+
| ngx_pool_t header (d/max/current/ |        pool->large
| chain/large/cleanup/log)          |      +----------------+   +----------------+
+-----------------------------------+      | next ---------+-->| next -> NULL   |
| d.last ......> [数据...]           |      | alloc ---------+->| malloc() 内存  |
|                [数据...] d.end    |      +----------------+   +----------------+
+-----------------------------------+          ^ pfree 后 alloc=NULL,槽位复用
      ^ next 指向后续同尺寸块
+-----------------------------------+
| ngx_pool_data_t(仅 4 个字段,     |   分配路径:
|  无 max/current 等重复 header)    |   ngx_palloc(size):
+-----------------------------------+     size <= pool->max ? ngx_palloc_small
| [小块数据区...]                    |                        : ngx_palloc_large
+-----------------------------------+
```

### 2.2 小块路径:palloc / pnalloc / block

`ngx_palloc` 与 `ngx_pnalloc` 的唯一区别是对齐参数(`ngx_palloc.c:122-145`):`palloc` 走 `ngx_palloc_small(pool, size, 1)`(对齐),`pnalloc` 走 `align=0`(不对齐,给字符串用,省内存)。`NGX_ALIGNMENT` 默认是 `sizeof(uintptr_t)` 即平台字长(`src/core/ngx_config.h:96-98`)。

`ngx_palloc_small`(`ngx_palloc.c:148-174`)是教科书级 bump allocator:从 `pool->current` 开始沿 `d.next` 链找第一个能装下 size 的块,`p->d.last = m + size` 前移即完成分配,连搜索都只在当前块剩余空间不足时才发生。全链都装不下时进入 `ngx_palloc_block`。

`ngx_palloc_block`(`ngx_palloc.c:177-210`)有两个人类智慧点:

1. **新块与首块等尺寸**(`psize = pool->d.end - (u_char *) pool`,`ngx_palloc.c:184`),但新块只带 `ngx_pool_data_t` 这 16/32 字节的迷你 header(`m += sizeof(ngx_pool_data_t)`,`ngx_palloc.c:197`),不像很多 pool 实现每块都复制完整 `ngx_pool_s`。
2. **failed 计数器推进 current**:申请失败超过 4 次的块说明它剩余空间太小,后续每次分配都白扫一遍,于是 `pool->current` 前移越过它(`ngx_palloc.c:201-205`):

```c
for (p = pool->current; p->d.next; p = p->d.next) {
    if (p->d.failed++ > 4) {
        pool->current = p->d.next;   /* 淘汰"碎片化"的块 */
    }
}
```

这是典型的"用 O(1) 统计换取平均 O(1) 分配"的工程折中——不做首次适配的复杂索引,只对最坏情形做惰性淘汰。

### 2.3 大块路径:large 链与槽位复用

超过 `pool->max` 的分配走 `ngx_palloc_large`(`ngx_palloc.c:213-249`):直接 `ngx_alloc`(即 malloc)申请,然后在一个 `ngx_pool_large_t`(仅 `next`+`alloc` 两个指针,`ngx_palloc.h:41-46`)单链表上登记。两个细节值得注意:

- **登记节点优先复用已释放槽位**:扫描链表前 4 个节点,发现 `large->alloc == NULL`(此前被 `ngx_pfree` 置空)就直接占用,超过 4 个才重新从小块轨道分配登记节点(`ngx_palloc.c:225-236`)。与 failed>4 一样,常数 4 是有意的扫描上限。
- `ngx_pfree`(`ngx_palloc.c:277-294`)只对大块有意义:free 掉内存但保留登记节点,返回 `NGX_DECLINED` 表示"这不是我管的大块"。小块永不单独释放——这是整个模型的代价与前提。

`ngx_pmemalign`(`ngx_palloc.c:252-274`)是"对齐大块"变体,供需要页对齐(如 directio)的场景。

### 2.4 生命周期:destroy / reset / cleanup

`ngx_destroy_pool`(`ngx_palloc.c:46-96`)的顺序是精心设计的:**先跑 cleanup 回调,再 free 大块,最后 free 池块链**。cleanup 先于大块释放,是因为回调(如关闭文件、发送 trailer)往往还依赖池内数据。`NGX_DEBUG` 下还有一段注释解释了为什么 free 大块不能用 log 打日志:pool->log 本身可能就是从这个池分配的(`ngx_palloc.c:61-66`)——顺序即正确性。

cleanup 链是 Nginx 少见的"析构函数"机制:`ngx_pool_cleanup_add` 挂入 `handler/data/next` 三元组(`ngx_palloc.c:311-339`),标准用法如 `ngx_pool_cleanup_file`/`ngx_pool_delete_file`(`ngx_palloc.c:363-401`)封装"请求结束时关闭/删除临时文件"。`ngx_pool_run_cleanup_file` 还支持按 fd 提前执行单个 cleanup(`ngx_palloc.c:342-360`)。

`ngx_reset_pool`(`ngx_palloc.c:99-119`)值得专门一提:它 free 全部大块、把每块 `d.last` 拨回 `(u_char *) p + sizeof(ngx_pool_t)`,但**不清理 cleanup 链**,也不重置 large 登记节点——用于跨请求复用池结构时要小心(实际上 HTTP 请求池走的是 destroy+create,reset 主要给连级池使用)。

---

## ③ buf/chain:一套坐标系统走天下

### 3.1 ngx_buf_t 的双坐标

```c
/* src/core/ngx_buf.h:20-56(节选) */
struct ngx_buf_s {
    u_char          *pos;        /* 内存读坐标 */
    u_char          *last;       /* 内存写坐标 */
    off_t            file_pos;   /* 文件读坐标 */
    off_t            file_last;  /* 文件写坐标 */
    u_char          *start;      /* 缓冲区物理起点 */
    u_char          *end;
    ngx_buf_tag_t    tag;        /* 归属模块标签,回收依据 */
    ngx_file_t      *file;
    ngx_buf_t       *shadow;
    unsigned         temporary:1; /* 内容可修改(内存) */
    unsigned         memory:1;    /* 只读内存(如 mmap/静态) */
    unsigned         mmap:1;
    unsigned         recycled:1;
    unsigned         in_file:1;   /* 内容(部分)在文件中 */
    unsigned         flush:1;     unsigned sync:1;
    unsigned         last_buf:1;  unsigned last_in_chain:1;
    unsigned         last_shadow:1; unsigned temp_file:1;
    /* STUB */ int   num;
};
```

核心设计:**一个 buf 可同时携带内存坐标与文件坐标**(如 sendfile 场景"头部在内存、体在文件"),`ngx_buf_size` 宏根据 `temporary|memory|mmap` 判定取哪套(`ngx_buf.h:136-138`)。标志位全部是 1-bit 位域,`ngx_buf_special` 等谓词宏(`ngx_buf.h:128-130`)构成整条输出链的公共语言。`num` 字段上赤裸裸的 `/* STUB */` 注释(`ngx_buf.h:55`)是十多年历史包袱的诚实标注。

### 3.2 chain 链与 free/busy 回收

`ngx_chain_t` 就是 `{buf, next}`(`ngx_buf.h:59-62`)。Nginx 在 pool 上维护了一个**chain 节点空闲链**:`ngx_alloc_chain_link` 先看 `pool->chain`,有就摘下来用,没有才 palloc(`ngx_buf.c:47-65`);对应的 `ngx_free_chain` 宏把节点还回去(`ngx_buf.h:148-150`)。`pool->chain` 字段在 `ngx_reset_pool`/`ngx_destroy_pool` 里也确实被随池整体回收——单节点 palloc/free 的开销被压到几乎为零。

`ngx_chain_update_chains`(`ngx_buf.c:184-223`)是输出滤镜共同遵守的回收协议:发送完成后,把 `*out` 整体并入 `*busy`,再从 busy 头部逐个检查——**tag 不匹配的节点直接释放**(这是多模块共享一条输出链时防止误收别人 buf 的关键,`ngx_buf.c:206-209`);`ngx_buf_size == 0` 的节点重置 `pos/last = start` 后移入 `*free`(`ngx_buf.c:212-221`)。`ngx_chain_update_sent`(`ngx_buf.c:271-314`)则按已发送字节数同时推进内存坐标 `pos` 与文件坐标 `file_pos`,两套坐标的对称性在此一览无余。`ngx_chain_coalesce_file`(`ngx_buf.c:226-268`)负责把连续同 fd 的文件 buf 合并以利于 sendfile,还会按页对齐截断。

---

## ④ 配置解析与模块系统

### 4.1 手写 tokenizer:ngx_conf_read_token

配置解析不依赖任何生成器。`ngx_conf_parse`(`src/core/ngx_conf_file.c:157-355`)以 4KB 缓冲(`NGX_CONF_BUFFER`,`ngx_conf_file.c:11`)读文件,主循环调用 `ngx_conf_read_token`,返回值就是一套迷你状态机:`NGX_OK`(分号结束)/`NGX_CONF_BLOCK_START`(`{`)/`NGX_CONF_BLOCK_DONE`(`}`)/`NGX_CONF_FILE_DONE`(EOF)/`NGX_ERROR`(`ngx_conf_file.c:248-256` 的注释完整列出了这个协议)。三种解析模式 `parse_file/parse_block/parse_param` 对应"读文件 / 递归块内 / -g 命令行参数"(`ngx_conf_file.c:165-169`、`ngx_conf_param` 在 `ngx_conf_file.c:62-98`)。

tokenizer 本身(`ngx_conf_file.c:505-820`)用一组布尔状态变量(`need_space/last_space/sharp_comment/quoted/s_quoted/d_quoted/variable`)逐字符扫描,处理引号、`#` 注释、`\t\r\n` 转义(`ngx_conf_file.c:774-805`)与 `${var}` 变量边界。缓冲区扫到尾部时把半截 token memmove 回起点再续读(`ngx_conf_file.c:582-609`);token 超过 4096 字节直接报错,引号未闭合时还会猜出缺的是 `"` 还是 `'`(`ngx_conf_file.c:560-580`)。每个 token push 进 `cf->args`(ngx_array),一行指令的参数数组就这么攒出来。

### 4.2 指令分发:ngx_conf_handler

`ngx_conf_handler`(`ngx_conf_file.c:358-502`)线性遍历 `cf->cycle->modules[i]->commands` 双重循环做名字匹配(没有指令哈希表——启动路径不在乎 O(N)),依次校验:模块类型是否匹配 `cf->module_type`(`:390-394`)、位置 `cmd->type & cf->cmd_type`(`:398`)、`;`/`{` 收尾与声明一致(`:402-414`)、参数个数(8 个固定 TAKE1..7 位与 1MORE/2MORE/ANY,查表 `argument_number`,`ngx_conf_file.c:50-59`、`ngx_conf_file.h:22-52`)。

最能体现"双编号"价值的是 conf 指针的三选一(`ngx_conf_file.c:452-464`):

```c
if (cmd->type & NGX_DIRECT_CONF) {
    conf = ((void **) cf->ctx)[cf->cycle->modules[i]->index];
} else if (cmd->type & NGX_MAIN_CONF) {
    conf = &(((void **) cf->ctx)[cf->cycle->modules[i]->index]);
} else if (cf->ctx) {
    confp = *(void **) ((char *) cf->ctx + cmd->conf);
    if (confp) {
        conf = confp[cf->cycle->modules[i]->ctx_index];
    }
}
rv = cmd->set(cf, cmd, conf);
```

core 模块用 `index` 直接寻址 conf_ctx,块内模块用 `conf` 偏移找到该层 ctx 数组再用 `ctx_index` 寻址。通用 slot setter(`ngx_conf_set_str_slot` 等,`ngx_conf_file.c:1069-1090`)据此把值写进模块 conf 结构的 `cmd->offset` 处,重复赋值返回 `"is duplicate"`。指令回调的返回值约定是字符串:`NULL`=NGX_CONF_OK,`(void*)-1`=NGX_CONF_ERROR,其他字符串会被 `ngx_conf_log_error` 拼进报错(`ngx_conf_file.h:63-64`)——错误消息因此天然带文件名与行号。

### 4.3 模块系统:index / ctx_index 双编号与动态加载

`ngx_module_t`(`src/core/ngx_module.h:227-262`)前置 `ctx_index`、`index` 两个编号,后置 8 个生命周期钩子与 8 个 `spare_hook` 保留位(`NGX_MODULE_V1_PADDING`,`ngx_module.h:224`)。静态模块表 `ngx_modules[]` 由构建系统生成(见下),`ngx_preinit_modules` 按数组序赋 `index` 并填 `name`(`src/core/ngx_module.c:25-39`);`ngx_count_modules` 再按模块类型分配 `ctx_index`(`ngx_module.c:82-153`),分配时会检查 `old_cycle` 保证 reload 后编号稳定(`ngx_module.c:133-146`)。**index 面向全局数组与 core conf,ctx_index 面向同类型模块的模块私有 conf 数组**——两个编号空间解耦了"全局顺序"与"同类序号"。

动态模块走 `load_module` 指令 → `ngx_load_module`(`src/core/nginx.c:1625-1704`):`ngx_dlopen` 打开 .so 后 `ngx_dlsym` 取出符号 `ngx_modules`、`ngx_module_names`、`ngx_module_order`(可选),逐个调 `ngx_add_module` 插入 `cycle->modules` 数组(`nginx.c:1682-1692`)。三条安全绳:

1. **时机检查**:`modules_used` 置位后加载直接报 `"is specified too late"`(`nginx.c:1636-1638`;置位点在 `ngx_count_modules`,`ngx_module.c:150`)。
2. **ABI 检查**:模块内嵌 34 位特征串 `NGX_MODULE_SIGNATURE`(`ngx_module.h:21-217`),涵盖指针宽度、kqueue/epoll/AIO/QUIC/PCRE 等编译期特性;版本号与特征串任一不符即拒绝(`ngx_module.c:170-182`),避免 .so 与主程序"擦边兼容"。
3. **顺序检查**:`ngx_module_order` 允许 .so 声明"我要排在某模块前面",`ngx_add_module` 用 memmove 在数组中腾位插入(`ngx_module.c:211-251`)——HTTP filter 模块的执行顺序正确性全靠它。

.dso 的 dlclose 挂在 cycle pool 的 cleanup 上(`nginx.c:1648-1662`、`ngx_unload_module` 在 `nginx.c:1707-1720`),又一次复用 cleanup 机制。

### 4.4 auto/ 构建体系:手写 configure

`auto/configure` 是一个约 300 行的 POSIX sh 脚本,依次 `. auto/options → init → sources → cc/conf → os/conf → unix → threads → modules → lib/conf → make`,全部探测结果写入 `objs/ngx_auto_config.h`(`auto/configure:10-12,50-107`)。特性探测不用 autoconf 宏,而是 `auto/feature`:现场生成 `$NGX_AUTOTEST.c`、编译、执行,成功则经 `auto/have` 把 `#define NGX_HAVE_XXX 1` 追加进 auto_config.h(`auto/feature:31-50`,`auto/have:8-13`)。

`auto/modules` 是模块表的唯一事实来源:每个模块经 `auto/module` 脚本分类(静态/动态/DYNAMIC 时编 .so),最后在 `auto/modules:1581-1620` 用 here-doc 直接"打印"出 `objs/ngx_modules.c`——先 `extern ngx_module_t $mod;` 声明,再生成 `ngx_module_t *ngx_modules[]` 与平行数组 `ngx_module_names[]`。运行期 `ngx_preinit_modules` 遍历的正是这张编译期定稿的表。

---

## ⑤ slab 分配器:共享内存里的世界

worker 间共享状态(RT计量、限流、upstream zone、缓存元数据)落在 `ngx_slab_pool_t` 上。它在 `ngx_init_zone_pool`(`src/core/ngx_cycle.c:965-1028`)里由 mmap 出来的共享段(`src/os/unix/ngx_shmem.c:15-23`)初始化,自带互斥锁 `ngx_shmtx`。所有 API 分 `_locked` 与加锁两套(`src/core/ngx_slab.h:64-69`),供已持锁的调用方免重入。

布局(`src/core/ngx_slab.c:98-165`):`pool` 头之后是 **slots[] 槽位数组**(按 size class 分桶,数量为 `ngx_pagesize_shift - min_shift`)、stats 数组、page 描述符数组 `pages[]`,剩余空间页对齐后即数据区 `start`。每页由三元组 `ngx_slab_page_t {slab, next, prev}` 描述(`src/core/ngx_slab.h:18-22`),`slab`/`prev` 一位不浪费:`prev` 低 2 位存页类型 `PAGE/BIG/EXACT/SMALL`(`ngx_slab.c:11-15,47`),`slab` 低 4 位存 shift、高位存位图。

分配(`ngx_slab_alloc_locked`,`ngx_slab.c:184-417`)三分天下:

- `size > ngx_slab_max_size`(半页)→ 整页甚至多页分配(`:191-206`);
- `shift < ngx_slab_exact_shift` → 小块,**位图放在页数据区开头**,页头 `slab` 只存 shift(`:228-269`);
- `shift == exact_shift`(`ngx_pagesize / (8*sizeof(uintptr_t))`,4K 页下即 64B)→ **页头 slab 本身就是 64 位完整位图**,零额外空间(`:271-294`);
- `shift > exact_shift` → 大块,位图塞进 `slab` 高 32 位(`NGX_SLAB_MAP_SHIFT`,`:296-325`)。

`ngx_slab_exact_size = ngx_pagesize / (8 * sizeof(uintptr_t))`(`ngx_slab.c:91`)这个"恰好一个 uintptr_t 位图能管全页"的巧合点,是整个设计的中轴:比它小的块位图放不进页头就挪进页数据区,比它大的块位图用不完就塞进高位。free 路径(`ngx_slab_free_locked`,`ngx_slab.c:461-674`)根据页类型逆向拆解,任何不一致(指针越界、块未对齐、重复释放)都走 `ngx_slab_error` 打 ALERT 并 `ngx_debug_point()`(`ngx_slab.c:328-329,659-673`)——共享内存损坏不可恢复,宁可 crash 也要把现场留在日志里。

---

## ⑥ 日志与错误码约定

### 6.1 九级日志与链式 log

级别定义 `STDERR/EMERG/ALERT/CRIT/ERR/WARN/NOTICE/INFO/DEBUG` 共 9 级(`src/core/ngx_log.h:16-24`);DEBUG 之上还有按子系统掩码的 `NGX_LOG_DEBUG_CORE/ALLOC/MUTEX/EVENT/HTTP/MAIL/STREAM`(0x010-0x400,`ngx_log.h:26-32`)与特殊位 `NGX_LOG_DEBUG_CONNECTION = 0x80000000`(`ngx_log.h:41`)。因此 `log_level` 一个字段同时编码"最低打印级别"与"debug 子系统开关",比较用 `>=`(级别)而 debug 用 `&`(掩码),宏 `ngx_log_error` / `ngx_log_debug` 分别实现(`ngx_log.h:88-96`)。非 debug 构建下 `ngx_log_debug0..8` 直接展开为空(`ngx_log.h:216-222`),调试日志的格式化开销被编译期剔除——这是 Nginx 敢在热路径铺满 debug 日志的原因。

`ngx_log_t` 自身是个单链表节点(`ngx_log.h:50-76`,`next` 在 `:72`)。`error_log` 指令可多次出现,每条生成一个节点并按级别降序插入链(`ngx_log_insert`,`src/core/ngx_log.c:676-707`,头部交换技巧避免了修改所有指向链头的指针)。写日志时沿链遍历,**级别不够就 break**(`ngx_log.c:163`)——链有序性使"低级别日志必然同写"成为不变量。`ngx_log_error_core`(`ngx_log.c:95-210`)在栈上拼一行:`时间 [级别] pid#tid *conn 消息 (errno: strerror)`,上限 `NGX_MAX_ERROR_STR=2048`(`ngx_log.h:79`);errno 段空间不足时会截断加省略号、预留 50 字节(`ngx_log_errno`,`ngx_log.c:287-314`)。同一行还要"多路投递":支持 file/syslog(`:644-655`)/memory: 环形缓冲(仅 debug 构建,`:585-642`)三种 writer,写满磁盘的文件有 1 秒熔断(`:172-181`)。低于 WARN 的日志若尚未写过 stderr,还会用 `nginx: [级别]` 前缀补写控制台(`:198-209`)。

### 6.2 错误处理风格

- **返回值语义**:六元组 OK/ERROR/AGAIN/BUSY/DONE/DECLINED/ABORT 覆盖全项目(`ngx_core.h:39-45`)。`NGX_DECLINED` 表示"未处理,交给下游"(模块化 pipeline 的粘合剂),`NGX_AGAIN` 表示"数据未就绪,等事件再叫我"(非阻塞 IO 的心脏)。
- **goto 清理**:启动路径的资源回滚统一走 `goto failed/done` 标签,如 `ngx_conf_parse` 的双标签结构(`ngx_conf_file.c:329-354`)与 `ngx_init_cycle` 的 800+ 行大函数末尾的 `failed:` 回滚段(`src/core/ngx_cycle.c:833`)。请求路径则根本不清理——直接靠 pool。
- **日志即错误处理**:几乎所有失败分支都是 `ngx_log_error(level, log, ngx_errno, "... failed") + return NGX_ERROR`,错误文本固定带 `ngx_XXX_n` 系统调用名宏(如 `ngx_close_file_n`,`ngx_palloc.c:371-374`),保证 Windows/Linux 文案一致。
- **不可恢复即 abort**:`ngx_log_abort`(`ngx_log.c:242-255`)、slab 的 `ngx_debug_point`。

---

## ⑦ 工程文化观察

1. **反 autoconf 的构建体系**。手写 sh configure + 现场编译测试程序(`auto/feature`),换来的是零依赖(只需要 sh + cc)与完全可控的输出。这与 Linux 内核的 Kbuild、PostgreSQL 的 autoconf 形成三种流派:Nginx 选择"少工具、多约定"。
2. **代码即文档的注释密度**。`ngx_string.c:90-119` 用 30 行注释列出全部自研 printf 格式;`ngx_hash.c:91-99` 用 4 行注释写清指针低 2 位的语义协议;`ngx_string.c:1517-1533` 的转义位图表逐字节标注 ASCII 顺序(`/* ?>=< ;:98 7654 3210 ... */`)。这些注释是"协议声明",不是复述代码。
3. **常数 4 的哲学**。large 槽位复用扫 4 个(`ngx_palloc.c:233`)、failed>4 淘汰(`:202`)——不引入任何可调参数,靠经验常数封顶最坏路径。与 glibc malloc 的自适应机制相比,这种"够用且可预测"的取向贯穿全项目。
4. **诚实的 `#if 0` 与 `/* STUB */`**。`ngx_palloc.c:404-430` 保留了从未启用的 block cache 草稿,`ngx_buf.h:55` 的 `/* STUB */ int num` 十几年未清,`ngx_hash.c:455-483` 留着完整的 hash dump 调试代码。历史包袱就地标注而非掩盖,git 之外还保留着一层"代码考古层"。
5. **版权头即治理结构**。每个文件头的 `Copyright (C) Igor Sysoev / Maxim Dounin / Nginx, Inc.`(`ngx_palloc.c:2-4`、`ngx_module.h:2-5`)标明个人署名与公司署名并存的历史断层,`ngx_module.h` 的 "Copyright (C) Maxim Dounin" 正对应动态模块机制(1.9.11)由其实现的史实。
6. **性能注释先于抽象**。`ngx_string.h:101-109` 解释 memcpy 为何做成宏("gcc3/msvc/icc 会内联 rep movs"),`ngx_string.h:119-134` 为 icc 手写 <17 字节的展开循环。每个"看似多余"的宏背后都有一条具体的编译器行为注释,优先于任何"更优雅"的抽象。
7. **与同类项目对照**:同为池化模型,Apache APR 的 `apr_pool_t` 支持父子池树与逐池销毁,复杂度更高;Linux SLUB 面向通用负载,Nginx slab 只服务共享内存这一确定场景,因此敢于把位图塞进页头、把类型位塞进 prev 指针。Golang 的 panic/defer 让错误路径可以惰性,Nginx 用 pool 达到同一效果但零运行时成本——两种语言级方案殊途同归。
8. **API 面积极小且不设防**。`ngx_palloc.h` 对外仅 10 个函数;hash、rbtree、array、list 全部暴露内部结构直接操作字段,不做封装。信任使用者(模块作者)与使用者能力,是 C 生态"库即框架"的典型取舍。

---

## ⑧ FAQ

**Q1:ngx_palloc 和 ngx_pnalloc 到底差在哪?**
仅差对齐:`palloc` 走 `ngx_palloc_small(pool, size, 1)`,`pnalloc` 走 `align=0`(`ngx_palloc.c:122-145`)。结构体用 palloc,字符串/字节流用 pnalloc(省去对齐垫片)。两者超过 `pool->max` 都转大块路径,大块一律来自 malloc,对齐由 allocator 自身保证。

**Q2:小块阈值是多少?可以更大吗?**
`pool->max = min(size - sizeof(ngx_pool_t), ngx_pagesize - 1)`(`ngx_palloc.c:33-34`、`ngx_palloc.h:20`)。池 16K 时是 4095;把池开大,max 也**不会**超过页大小减一——这是硬上限,设计动机见 `ngx_palloc.h:17-18` 注释(Windows 减少锁定页;且大块走 malloc 有更好的反碎片性)。

**Q3:为什么小块没有 free?会不会浪费?**
设计前提是"对象与请求同寿命"。碎片化块的代价通过 `d.failed > 4` 推进 `pool->current` 被摊销(`ngx_palloc.c:201-205`),真正需要回收的少数对象(如大 buffer)走 `ngx_pfree` 大块路径。这也是为什么 HTTP 层还要额外引入 `pool->chain` 空闲链(`ngx_buf.c:47-65`)和 free/busy 队列(`ngx_buf.c:184-223`)做对象级复用。

**Q4:ngx_destroy_pool 时 cleanup 为什么先执行?**
cleanup 回调可能引用池内数据或大块内容(例如记录响应尾、关闭文件后再由 `ngx_pool_delete_file` 删文件),先 free 大块会悬空。顺序:cleanup → large → pool blocks(`ngx_palloc.c:53-95`)。DEBUG 构建下连"free 大块时打日志"都被禁止,因为 log 可能就活在这个池里(`:61-66`)。

**Q5:ngx_snprintf 会截断吗?与 libc 的区别?**
`ngx_vslprintf` 的循环条件是 `*fmt && buf < last`(`ngx_string.c:178`),保证至少还能写 1 字符,且 `%s`/`%V` 等字符串写入也逐段检查(`ngx_sprintf_str`)。注意 `ngx_sprintf` 传入 `last = (void *) -1` 即**无界**(`:129`),必须确保缓冲够大;`ngx_snprintf(buf, max, ...)` 才是安全版(`:137-147`)。它不支持 `%n`、浮点只有 `%f` 固定小数实现(`:368-407`)。

**Q6:%V 和 %s 有什么区别?**
`%V` 直接打 `ngx_str_t *`(len+data,可含 `\0`)、`%v` 打 `ngx_variable_value_t *`、`%s` 打 C 字符串(可配 `%*s` 先传 len 再传指针,`ngx_string.c:252-273`)。日志里几乎全是 `%V`,因为 len 前缀避免 strlen 且天然 binary-safe。配套 `%Z`/`%N` 输出 `\0`/`\n`(`:430-447`)。

**Q7:ngx_buf 的 tag 是干什么的?**
发送后回收 chain 时,`ngx_chain_update_chains` 只回收 `tag` 等于当前滤镜 tag 的节点(`ngx_buf.c:206-209`)。一条输出链可能串着 gzip、range、静态文件等多个模块创建的 buf,没有 tag 就会发生 A 模块把 B 模块的 buf 塞进自己的 free 链的错配。

**Q8:动态模块 .so 为什么不会 ABI 不兼容?**
靠版本号 + 34 位特征字符串双保险(`ngx_module.c:170-182`)。特征串把指针宽度、事件模型(kqueue/epoll/IOCP)、AIO、PCRE、HTTP 特性等编译期布尔逐位编进字符串(`ngx_module.h:21-217`),任何一个特性开关不同,签名就不同,加载即报 `"is not binary compatible"`。

**Q9:error_log 能写多个文件吗?**
可以。每个 `error_log` 指令产生一个 `ngx_log_t` 节点,按级别降序串成链(`ngx_log.c:676-707`),写日志沿链广播直到遇到级别低于当前消息的节点(`:161-196`)。所以 `error_log /path debug; error_log /path2 error;` 会让两条都收到 error 及以上。

**Q10:slab 分配器需要初始化吗?worker 间如何一致?**
共享 zone 首次由 master 在 `ngx_init_zone_pool` 初始化(`ngx_cycle.c:965-1028`),并在 `sp->addr` 记录基址;reload 后新 worker 映射同段共享内存,若 `sp == sp->addr`(映射地址一致)直接复用,Windows 下还支持 remap(`:973-993`)。并发安全靠每池一个 `ngx_shmtx` 互斥锁(`ngx_slab.c:168-180`)。

---

## ⑨ 深挖问题(建议后续专题)

1. **`pool->max` 为什么钉死在页大小?** 若允许大池(如 1MB)的小块上限超过 4K,碎片行为如何变化?可对照 `ngx_palloc.h:17-19` 注释与 HTTP `request_pool_size` 的实际配置做量化实验。
2. **大块链 O(n) 扫描的退化**:`ngx_palloc_large` 槽位复用只扫 4 个节点(`ngx_palloc.c:227-236`),但 `ngx_pfree` 是全链 O(n)(`:282-291`)。高频率 pfree 的模块(如 proxy 的临时 buffer)是否在长链下成为瓶颈?可写 benchmark 验证。
3. **slab 位图三分支的分支开销**:small/exact/big 三条路径每分支独立维护"页满摘链"逻辑(`ngx_slab.c:251-264,280-287,311-318`),能否统一抽象?上游为何选择复制粘贴式实现(猜测:页头寄存器位置不同导致无法统一),值得读 git 考古。
4. **动态模块 order 机制的边界**:`ngx_add_module` 的 order 插入算法(`ngx_module.c:211-251`)在多个 .so 互相声明顺序约束时是否可能产生非预期结果?`auto/module:18-26` 对 HTTP filter 默认插入 `ngx_http_copy_filter_module` 之前,该默认值如何与显式 order 交互?
5. **log 链的写放大**:多级 `error_log`(main/server/location 各配一条)时一条消息会写多份(`ngx_log.c:161-196`),debug 级别 + 多文件场景的日志 IO 对 P99 延迟的影响值得实测;`disk_full_time` 1 秒熔断(`:172-181`)只防 ENOSPC,不防慢盘。

---

### 附:本次实读文件清单

- `src/core/ngx_palloc.h`(全文)、`src/core/ngx_palloc.c`(全文)
- `src/core/ngx_string.h`(全文)、`src/core/ngx_string.c`(格式化与转义段:1-480、1359-1930)
- `src/core/ngx_buf.h`(全文)、`src/core/ngx_buf.c`(全文)
- `src/core/ngx_conf_file.h`(1-200)、`src/core/ngx_conf_file.c`(1-870、slot 段 1029-1100)
- `src/core/ngx_module.h`(全文)、`src/core/ngx_module.c`(全文)、`src/core/nginx.c`(load_module 段 1620-1721)
- `src/core/ngx_slab.h`(全文)、`src/core/ngx_slab.c`(1-730)
- `src/core/ngx_log.h`(1-220)、`src/core/ngx_log.c`(全文)
- `src/core/ngx_hash.c`(1-700)、`src/core/ngx_hash.h`(ngx_hash 宏)
- `src/core/ngx_core.h`(错误码)、`src/core/ngx_config.h`(对齐宏)
- `src/core/ngx_cycle.c`(init_zone_pool 段 965-1028、failed 段 833)
- `auto/configure`、`auto/modules`(ngx_modules.c 生成段)、`auto/module`、`auto/feature`、`auto/have`、`auto/init`
