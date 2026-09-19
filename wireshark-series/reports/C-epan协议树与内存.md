# 报告 C · epan 协议树与内存模型(Wireshark)

> 基线:tag v4.7.3,commit f6e0bf22。一句话总结:Wireshark 把"解码结果"组织成一棵由 `proto_node`(节点)挂 `field_info`(实例)引用 `header_field_info`(注册表项)的三层协议树,全部节点和值从 `pinfo->pool` 这个 wmem BLOCK_FAST 分配器里按包分配、按包整体释放;不可见树通过 `TRY_TO_FAKE_THIS_ITEM` 退化为"假节点",而真正的字节读取与边界防护由 vtable 化的 tvbuff 以异常阶梯完成。

## 1. 一次解码的完整入口链

入口链:`epan_dissect_run` → `dissect_record` → `call_dissector_with_data(frame_handle,...)` → `dissect_frame` → `wtap_encap` 分发表 → 链路层解析器(如 ether)逐层下探。`epan_dissect_new`(epan/epan.c:737)先调 `epan_dissect_init`(epan/epan.c:679):创建 `pi.pool = wmem_allocator_new(WMEM_ALLOCATOR_BLOCK_FAST)`(epan/epan.c:691,可复用 `pinfo_pool_cache`,epan/epan.c:686-689),按需 `proto_tree_create_root` 并 `proto_tree_set_visible`(epan/epan.c:694-697)。`epan_dissect_run`(epan/epan.c:755-769)只做 Lua dfilter 预热然后直接转调 `dissect_record`(epan/epan.c:764)。

```c
// epan/packet.c:751-774
edt->tvb = tvb_new_real_data(ws_buffer_start_ptr(&rec->data),
            fd->cap_len, fd->pkt_len);              // 顶层 REAL tvb,数据零拷贝指向 rec 缓冲
add_new_data_source(&edt->pi, edt->tvb, rec->rec_type_name);
// dissect_frame() 自身仍可能抛 ReportedBoundsError,所以在这一层兜底
call_dissector_with_data(frame_handle, edt->tvb, &edt->pi, edt->tree,
                         &frame_dissector_data);    // packet.c:760
CATCH(BoundsError) { ws_assert_not_reached(); }     // packet.c:762-763
CATCH2(FragmentBoundsError, ReportedBoundsError) {  // packet.c:765
    proto_tree_add_protocol_format(edt->tree, proto_malformed, ...);
} ENDTRY;
fd->visited = 1;                                    // packet.c:774
```

`dissect_record` 前半段是对 pinfo 的"每包归零再灌值":地址六个全部 clear、ptype 归 PT_NONE、`layers` 在池上新建 wmem_list(epan/packet.c:675-692),编号与时间戳取自 fd,epan/packet.c:637-647:

```c
// epan/packet.c:673-692(节选)
edt->pi.fd = fd;
edt->pi.rec = rec;
clear_address(&edt->pi.dl_src);  clear_address(&edt->pi.dl_dst);
clear_address(&edt->pi.net_src); clear_address(&edt->pi.net_dst);
clear_address(&edt->pi.src);     clear_address(&edt->pi.dst);
edt->pi.noreassembly_reason = "";
edt->pi.ptype = PT_NONE;
...
edt->pi.layers = wmem_list_new(edt->pi.pool);   // 协议层级列表,池上分配
edt->pi.proto_data = NULL;                       // 每包协议私有数据表随之清空
```

`frame_handle` 在 `packet_cache_proto_handles()` 中一次性 `find_dissector("frame")` 缓存(epan/packet.c:255-256)。`dissect_frame`(epan/dissectors/packet-frame.c:568)先画 Frame 根节点(受 `proto_field_is_referenced(tree, proto_frame)` 门控,packet-frame.c:667-677),再按 `pinfo->rec->rec_header.packet_header.pkt_encap` 从 `wtap_encap` 表取链路层句柄派发(packet-frame.c:1148-1157)。`dissect_record` 开头把 fd 的编号/时间戳/伪头部灌进 pinfo(epan/packet.c:632-691),首扫时还要 `prime_epan_dissect_with_postdissector_wanted_hfids`(epan/packet.c:627)。

## 2. proto_tree 的三层结构与字段注册

树节点本体极简:`proto_node` 只有 4 个指针 + `hfinfo`/`finfo`/`tree_data`(epan/proto.h:913-922);`proto_tree`/`proto_item` 都是它的 typedef(epan/proto.h:925-927)。整树共享一份 `tree_data_t`:可见位、fake_protocols、节点计数 `count`、回指 pinfo(epan/proto.h:902-911)。每个节点可挂一个 `field_info` 实例:start/length、`tree_type`(ett)、`rep`(GUI 字符串)、`ds_tvb`、fvalue 值(epan/proto.h:822-835);`field_info` 只指向全局注册表项 `header_field_info`(名称/abbrev/FT 类型/BASE/strings/bitmask,epan/proto.h:773-792),后者由 `HFILL` 宏预填运行时字段(epan/proto.h:799-806)。

注册路径:每个解析器在 `proto_register_*` 里调 `proto_register_field_array`(epan/proto.c:9220-9258)→ `proto_register_field_init`(epan/proto.c:10210)把 hfinfo 指针挂进全局数组 `gpa_hfinfo`(epan/proto.c:474-480,索引即 hf id,"id == len - 1"),数组按 30 万条预分配(epan/proto.c:471,分配/扩容在 proto_register_field_init 内,g_malloc/g_realloc,10220-10231)。注册发生在 `epan_init → proto_init`(epan/epan.c:395-396)阶段一次性完成,注释明言"启动时几乎被调用 30 万次"(epan/proto.c:9245)。

```c
// epan/proto.c:10210-10240(节选)proto_register_field_init
if (gpa_hfinfo.len >= gpa_hfinfo.allocated_len) {
    if (!gpa_hfinfo.hfi) {
        gpa_hfinfo.allocated_len = PROTO_PRE_ALLOC_HF_FIELDS_MEM;   // 30 万条预分配
        gpa_hfinfo.hfi = g_malloc(sizeof(header_field_info *) * PROTO_PRE_ALLOC_HF_FIELDS_MEM);
        gpa_hfinfo.hfi[0] = NULL;   // 下标 0 保留,不用于字段
        gpa_hfinfo.len = 1;
    } else {
        gpa_hfinfo.allocated_len += 1000;                            // 每次扩 1000
        gpa_hfinfo.hfi = g_realloc(...);
    }
}
gpa_hfinfo.hfi[gpa_hfinfo.len] = hfinfo;
gpa_hfinfo.len++;
hfinfo->id = gpa_hfinfo.len - 1;      // "总在尾部追加,所以 id == len - 1"
```

所有 `add_*` 入口用 `PROTO_REGISTRAR_GET_NTH(hfindex, hfinfo)` 以 O(1) 数组下标取 hfinfo(epan/proto.c:464-469,带未注册断言)。

```c
// epan/proto.h:913-922
typedef struct _proto_node {
    struct _proto_node *first_child, *last_child, *next, *parent;
    const header_field_info *hfinfo;   // 指向全局注册表项
    field_info         *finfo;         // 本包实例,可空(假节点)
    tree_data_t        *tree_data;     // 仅根节点使用
} proto_node;
```

add_* 家族代表:`proto_tree_add_item`(epan/proto.c:4584-4591)→ `proto_tree_add_item_new`(epan/proto.c:4563-4581):先 `get_hfi_length`+`test_length`(4571-4572),再 `CHECK_FOR_NULL_TREE`(4574)与 `TRY_TO_FAKE_THIS_ITEM`(4576),最后 `new_field_info`(epan/proto.c:7134)+ `proto_tree_new_item`(epan/proto.c:2909-2988,按 FT 类型取值)。

```c
// epan/proto.c:2909-2945(节选)proto_tree_new_item:按 FT 类型分派取值
switch (new_fi->hfinfo->type) {
    case FT_NONE:
        break;                                    // 无值可取
    case FT_PROTOCOL:
        // 协议节点:从 start 起对 ds_tvb 取剩余部分作为协议 tvb
        proto_tree_set_protocol_tvb(new_fi,
            new_fi->ds_tvb ? tvb_new_subset_remaining(new_fi->ds_tvb, new_fi->start) : NULL, ...);
        break;
    case FT_BYTES:
        proto_tree_set_bytes_tvb(new_fi, tvb, start, length);
        break;
    case FT_BOOLEAN: ...
    case FT_CHAR: case FT_UINT8: case FT_UINT16: case FT_UINT24: case FT_UINT32: ...
}
```

值得注意的注释:proto_tree_new_item 开头明言 fvalue 从"packet-scoped pool"分配,即使取值中途抛异常,池释放时也会回收,无需清理处理器(epan/proto.c:2924-2931)——这是树与池耦合的又一证据。ptvcursor 变体(`ptvcursor_add`,epan/proto.c:4533-4558)逻辑相同,区别仅在先推进游标再做树操作。文本节点走内部 `proto_tree_add_text_internal`,统一用特殊字段 `hf_text_only`("text", FT_NONE,epan/proto.c:404,406 处定义、639 处注册);格式化家族 `proto_tree_add_none_format`/`proto_tree_add_protocol_format` 在 epan/proto.c:4878/4938,最终经 `proto_tree_set_representation`(epan/proto.c:7240)生成 repr。父子挂接零成本:`proto_item_add_subtree` 只是返回同一节点指针并在 finfo 里记 `tree_type`(epan/proto.c:8406-8417)。

## 3. 性能门:visible 与 fake 机制

`TRY_TO_FAKE_THIS_ITEM`(epan/proto.c:120-167,全文件 59 处调用)是隐形树的核心优化。触发条件(全部同时满足,proto.c:148-158):树不可见 `!PTREE_DATA(tree)->visible`;父项为隐藏节点 `PROTO_ITEM_IS_HIDDEN(tree)`(即 FI_HIDDEN,语义是"该节点子树可整枝丢弃");本字段未被过滤器直接引用(`ref_type != HF_REF_TYPE_DIRECT/PRINT`);且不是 FT_PROTOCOL,或树允许 fake 协议(`PTREE_DATA(tree)->fake_protocols`)。命中即返回 `proto_tree_add_fake_node`——一个**没有 field_info 的真节点**,保证下层字段仍有挂接点(proto.c:149-157 注释;实现 proto.c:6607-6630,附带 `gui_max_tree_depth` 深度防环检查)。引用标记由 `proto_tree_prime_with_hfid` 完成:直接引用置 `HF_REF_TYPE_DIRECT`,并顺带把父协议标成 INDIRECT(epan/proto.c:8348-8372,8359 处赋值);来源是显示过滤器/tap 的 priming(epan/epan.c:847-866)与 postdissector 预热(epan/packet.c:627)。

```c
// epan/proto.c:134-157(节选)
PTREE_DATA(tree)->count++;                       // 假节点也计数(死循环探测)
PROTO_REGISTRAR_GET_NTH(hfindex, hfinfo);
if (PTREE_DATA(tree)->count > prefs.gui_max_tree_items) { ... THROW_MESSAGE(DissectorError, ...); }
if (!(PTREE_DATA(tree)->visible)) {
    if (PROTO_ITEM_IS_HIDDEN(tree)) {
        if ((hfinfo->ref_type != HF_REF_TYPE_DIRECT)
            && (hfinfo->ref_type != HF_REF_TYPE_PRINT)
            && (hfinfo->type != FT_PROTOCOL || PTREE_DATA(tree)->fake_protocols)) {
            return proto_tree_add_fake_node(tree, hfinfo);   // 无 finfo 的占位节点
        }
    }
}
```

配套宏 `TRY_TO_FAKE_THIS_REPR`(epan/proto.c:172-181):隐形树上跳过 vsnprintf 生成 repr——这正是"树不可见时字符串格式化开销趋近于零"的出处(proto_tree_set_visible 注释,proto.c:986-989)。另一道门是总数:`count` 超过 `prefs.gui_max_tree_items` 直接 THROW Message(死循环熔断,proto.c:136-147);`new_field_info` 里还有"start 不前进"的空闲计数熔断(epan/proto.c:7148-7162)。**树不可见时字段照常注册**:注册是会话级一次性行为(§2),与每包树可见性无关;且 `add_item_new` 在判空/判 fake **之前**就完成取值与长度校验(epan/proto.c:4571-4574),所以即使 `tree == NULL`(tshark 不加 -V 时默认无树)字节读取与越界异常照样发生——隐形省的是"建节点+格式化字符串",不是"读包"。

## 4. tvbuff:类型、边界检查与异常

**纠偏**:4.7.3 的 tvbuff 已重构成 vtable 设计。`struct tvbuff`(epan/tvbuff-int.h:88-131)不再有 `TVBUFF_REAL_DATA/SUBSET/COMPOSITE` 类型枚举字段(全仓库 grep 无此枚举),取而代之的是 `const struct tvb_ops *ops` 虚表(epan/tvbuff-int.h:14-95:free/offset/get_ptr/memcpy/find/clone 八个函数指针)与统一字段 `real_data`/`length`(已捕获)/`reported_length`/`contained_length`/`ds_tvb`/`raw_offset`,外加把所有 tvb 串成单链表的 `next`(tvbuff-int.h:91-93)。三种语义按文件分置:real(epan/tvbuff_real.c,`tvb_new_real_data` 在 :58,`tvb_new_child_real_data` 在 :104)、subset(epan/tvbuff_subset.c,`tvb_new_subset_length_caplen` :161,内核 `tvb_new_with_subset` :119-158)、composite(epan/tvbuff_composite.c,由 `tvb_new_composite`+`tvb_composite_finalize` 拼接,epan/tvbuff.h:350)。

subset 的关键设计:它只是背书 tvb 的"窗口",自己不复制数据;若背书是连续 real 数据,`real_data` 直接指到偏移处(epan/tvbuff_subset.c:143-145),`ds_tvb` 继承背书的顶层源(:155),`contained_length` 被钳制在背书剩余量内(:135)。`tvb_new_chain`/`tvb_add_to_chain` 把子 tvb 头插到父的 next 链(epan/tvbuff.c:132-150),因此一帧的所有 tvb 沿单链可整体 `tvb_free_chain` 释放(epan/tvbuff.c:120-127);该链在 `epan_dissect_reset/cleanup` 中随包释放(epan/epan.c:720-724, 821-824),生命周期契约写在 epan/tvbuff.h:55-73(解析器不得保存 tvb 指针到下一帧)。TCP 即典型:头部后 `tvb_new_subset_length_caplen` 切出载荷(epan/dissectors/packet-tcp.c:6056),`decode_tcp_ports` 再 `tvb_new_subset_remaining` 交给端口分发(epan/dissectors/packet-tcp.c:8412-8418)。

```c
// epan/tvbuff.c:212-229 compute_offset:异常阶梯(选)
if (G_LIKELY((unsigned) offset <= tvb->length)) {
    *offset_ptr = offset;                       // 在已捕获长度内:OK
} else if ((unsigned) offset <= tvb->contained_length) {
    return BoundsError;                         // packet.c:762 断言不可达
} else if (tvb->flags & TVBUFF_FRAGMENT) {
    return FragmentBoundsError;                 // 分片重组配置问题
} else if ((unsigned) offset <= tvb->reported_length) {
    return ContainedBoundsError;
} else {
    return ReportedBoundsError;                 // 报文声称的长度就不够
}
```

`tvb_get_*` 的统一防线是 `ensure_contiguous` → `check_offset_length`(epan/tvbuff.c:427-437,算出绝对偏移后 `THROW(exception)`);异常常量定义在 epan/exceptions.h:25/38/47/57。语义分级:`length` 越界但 `contained_length` 内 → BoundsError(捕获即截断,dissect_record 层断言不会漏出,packet.c:762-764);超出 reported_length → ReportedBoundsError(报文本身声明更长,顶层兜底画 malformed,packet.c:765-769)。

```c
// epan/tvbuff.c:945-985(节选)每个 tvb_get_* 的必经之路
static const void *
ensure_contiguous_no_exception(tvbuff_t *tvb, const int offset, const int length,
                               int *pexception) {
    unsigned abs_offset, abs_length;
    int exception;
    exception = check_offset_length_no_exception(tvb, offset, length,
                                                 &abs_offset, &abs_length);
    if (pexception) *pexception = exception;
    if (exception) return NULL;
    return ensure_contiguous_without_offset(tvb, abs_offset, abs_length);
}
```

composite 侧:成员 tvb 逐段登记、`tvb_composite_finalize` 汇总总长(实现在 epan/tvbuff_composite.c:299,声明在 tvbuff.h:361;入口 `tvb_new_composite` 在 tvbuff.h:350);约束是"composite 的成员必须已在当前 tvb 链上"(epan/tvbuff.h:68-69),否则释放序会被打乱。此外还有 zlib/brotli/zstd/lz77 等解压 tvb 工厂(epan/tvbuff_zlib.c 等),如 `tvb_child_uncompress_zlib`(epan/tvbuff_zlib.c:300),它们经 `tvb_child_uncompress` 挂入链(epan/tvbuff.h:68)。

## 5. wmem:allocator 族与每包池

wmem 位于 wsutil/wmem/(注意:不在 epan/ 下)。分配器是四实现的统一 vtable `wmem_allocator_t`(`walloc/wfree/wrealloc/free_all/gc/cleanup`,wsutil/wmem/wmem_allocator.h:34-52):SIMPLE(逐次 g_malloc)、BLOCK、BLOCK_FAST、STRICT,由 `wmem_allocator_new` 的 switch 装配(wsutil/wmem/wmem_core.c:129-165);环境变量 `WIRESHARK_DEBUG_WMEM_OVERRIDE` 可强制全部换成指定实现以便 valgrind 排查(wmem_core.c:176-199)。底层出口是 glib:`wmem_alloc(NULL,...)` 直接 `g_malloc`,`wmem_free(NULL,...)` 直接 `g_free`(wmem_core.c:33-35,63-65);BLOCK_FAST 从 g_malloc 拿 2 MiB 大块再切 chunk(wsutil/wmem/wmem_allocator_block_fast.c:42,72-77),超限走 jumbo 链(:58-61,86-105)——即 wmem 是"glib 之上的作用域分配器",不是替代品。

`pinfo->pool` 就是每包作用域:类型 BLOCK_FAST(epan/epan.c:691),`PNODE_POOL(node)` 即 `tree_data->pinfo->pool`(epan/proto.h:1013),树节点(epan/proto.c:7135 FIELD_INFO_NEW)、fvalue、repr 全从它出。**每包重置的调用点在应用层**:`epan_dissect_reset`(epan/epan.c:708-734)依次 `tvb_free_chain`(722)→ `proto_tree_reset`(727)→ `wmem_free_all(pi.pool)`(730),tshark 每包循环里显式调用(tshark.c:3608,3854,4615);`epan_dissect_cleanup` 则把池放进 `pinfo_pool_cache` 供下一个 edt 复用、避免反复申请大块(epan/epan.c:830-836)。`proto_tree_reset` 不逐个 free 节点,只对 fvalue 做 `fvalue_cleanup` 释放类型相关数据(epan/proto.c:926-932)——真正的节点内存由池整体回收。

```c
// wsutil/wmem/wmem_allocator_block_fast.c:86-124(节选)
static void *wmem_block_fast_alloc(void *private_data, const size_t size) {
    ...
    if (size > WMEM_BLOCK_MAX_ALLOC_SIZE) {          // 超大分配走 jumbo 直连
        block = wmem_alloc(NULL, size + WMEM_JUMBO_HEADER_SIZE + WMEM_CHUNK_HEADER_SIZE);
        ...
        chunk->len = JUMBO_MAGIC;
        return WMEM_CHUNK_TO_DATA(chunk);
    }
    real_size = WMEM_ALIGN_SIZE(size) + WMEM_CHUNK_HEADER_SIZE;
    /* Allocate a new block if necessary. */          // 剩余不足则再拿一块 2MiB
    if (!allocator->block_list ||
            (WMEM_BLOCK_SIZE - allocator->block_list->pos) < real_size)
        wmem_block_fast_new_block(allocator);
    chunk = (wmem_block_fast_chunk_t *)((uint8_t *)allocator->block_list
                                        + allocator->block_list->pos);
    chunk->len = (uint32_t) size;
    allocator->block_list->pos += real_size;         // bump 指针即完成分配
```

对比:SIMPLE 分配器每个 walloc 直接 `wmem_alloc(NULL,...)`(即 g_malloc),并把指针记入数组,`wmem_simple_free_all`(wsutil/wmem/wmem_allocator_simple.c:89-98)遍历数组逐个 g_free;BLOCK_FAST 则"分配=bump 指针(:124)、free=空操作、free_all=整块丢弃",这是它被选为 pinfo->pool 的原因(wmem_core.c:153-155 装配处;epan.c:691)。另两个:BLOCK(带空闲链的块分配器,wmem_allocator_block.c)与 STRICT(调试用、填充哨兵值,wmem_allocator_strict.c)。

```c
// epan/epan.c:707-733(节选)
void epan_dissect_reset(epan_dissect_t *edt) {
    wtap_block_unref(edt->pi.rec->block);
    free_data_sources(&edt->pi);
    if (edt->tvb) { tvb_free_chain(edt->tvb); edt->tvb = NULL; }  // 整条 tvb 链
    if (edt->tree) proto_tree_reset(edt->tree);                    // 树节点只清 fvalue
    tmp = edt->pi.pool;
    wmem_free_all(tmp);                                            // 池整体清空
    memset(&edt->pi, 0, sizeof(edt->pi));
    edt->pi.pool = tmp;                                            // 跨 memset 保留池指针
}
```

## 6. pinfo 与 frame_data

`packet_info`(epan/packet_info.h)关键字段:`num`(帧号,:47)、回指 `fd`(:53)与 `rec`(:55)、四层地址 `dl_src/dl_dst/net_src/net_dst` 与合并视图 `src/dst`(:58-63)、`ptype/srcport/destport`(:75-77,新版还有 `use_conv_addr_port_endpoints` 时经 `PINFO_SRCPORT/DESTPORT` 宏从会话端点取值,:182-183)、`layers`(每包池上的 wmem_list,:690 处在 dissect_record 创建)、每包内存池 `pool`(:164)。**`cdat`/`ldat` 在本 tag 不存在**(grep packet_info.h 无命中,旧资料残留概念,勿引用)。`dissect_record` 每包清零这些字段并从 fd 灌值:`edt->pi.num = fd->num`(epan/packet.c:637)、`abs_ts`(:646)、`fd`/`rec` 指针(:673-674)。

`frame_data`(epan/frame_data.h:63-101)则相反:由捕获文件层(cfile)持有、**跨包存活**——`num/pkt_len/cap_len/file_off/abs_ts`(:64-67,92)是索引元数据,`visited` 位(:84)标记首扫完成(dissect_record 结尾置位,packet.c:774),`ref_time/marked/ignored` 等用户状态也在其中;注释强调"每帧一个,量大,尽量压到 2 的幂附近"(frame_data.h:57-62)。

```c
// epan/frame_data.h:63-94(节选)
typedef struct _frame_data {
  uint32_t     num;          /**< 帧号(1 起) */
  uint32_t     dis_num;      /**< 显示帧号 */
  uint32_t     pkt_len;      /**< 线上长度 */
  uint32_t     cap_len;      /**< 实际捕获长度 */
  int64_t      file_off;     /**< 文件偏移 */
  wmem_list_t *pfd;          /**< 每帧 proto 数据 */
  ...
  unsigned int visited          : 1;  /**< 是否已解码过 */
  unsigned int marked           : 1;  /**< 用户标记 */
  unsigned int ref_time         : 1;  /**< 时间参考帧 */
  ...
  nstime_t     abs_ts;          /**< 绝对时间戳 */
  uint32_t     frame_ref_num;   /**< 相对时间戳的参考帧 */
} frame_data;
```所以生命周期分三层:`wtap_rec`(当前记录缓冲)与 tvb/pinfo 树随包释放,`frame_data` 随捕获文件存活,`header_field_info/gpa_hfinfo` 随 epan 会话存活。

## 7. 纠偏(以本 tag 源码为准)

1. **"tvb 分 REAL_DATA/SUBSET/COMPOSITE 三种枚举类型"是旧版认知**:本 tag 无该枚举,tvbuff 改为 `tvb_ops` vtable + 统一 `real_data/length/reported_length/contained_length` 字段,实现拆分到 tvbuff_real.c/tvbuff_subset.c/tvbuff_composite.c(epan/tvbuff-int.h:14-131;全仓库无 TVBUFF_REAL_DATA)。
2. **`wmem_packet_scope()` 已不存在**:现代 API 是 `pinfo->pool`(BLOCK_FAST 分配器),创建于 epan_dissect_init(epan/epan.c:691),由应用层每包调 `epan_dissect_reset → wmem_free_all` 重置(epan/epan.c:730;tshark.c:3608)。不存在显式 enter/leave packet scope 的调用点。
3. **`pinfo->cdat`/`pinfo->ldat` 不存在**(epan/packet_info.h 全文无命中);对应信息现由 `rec`(wtap_rec)与 `pseudo_header` 承担(packet.c:651-671)。
4. **"树不可见 = 不做解码工作"是误解**:`proto_tree_add_item_new` 在判空/判 fake 之前先取值并校验长度(epan/proto.c:4571-4574);fake 节点也计入 `count` 并维持父子挂接(proto.c:134-157)。隐形只省节点构造与字符串格式化。
5. **协议节点默认也会被 fake,但有条件**:root 默认 `fake_protocols = true`(epan/proto.c:8331),故隐形树上 FT_PROTOCOL 默认可 fake;一旦被过滤器引用(`HF_REF_TYPE_DIRECT/PRINT`)则绝不 fake(proto.c:150-153),且 `proto_field_is_referenced` 为假时连 Frame 根节点都不建(packet-frame.c:667-677)。
6. **BoundsError 在顶层"不可达"**:`dissect_record` 对 `CATCH(BoundsError)` 直接 `ws_assert_not_reached`(packet.c:762-764)——顶层 tvb 的已捕获长度即全部数据,正常情况只会抛 ReportedBoundsError/FragmentBoundsError。
7. **"hf 变量必须初始化为 -1"是旧惯例**:4.4 起未注册字段传 0 即可,本 tag 源码注释直言"大多数字段初始化为 0;有些用 -1(4.4 之前的标准)"(epan/proto.c:9242-9244),写解析器时两种都可能见到。
8. **proto_tree_reset ≠ proto_tree_free**:reset 用于复用同一 edt 连续解码,不释放节点内存(交给池,proto.c:936-961);free 才 g_slice_free 根节点与 tree_data(proto.c:963-984)。根节点/树数据走 g_slice(proto.c:8312 `g_slice_new(proto_tree)`,8316 `g_slice_new(tree_data_t)`),而业务节点走 pinfo 池——两套分配并存。

## 8. ASCII:一个 TCP 包的树结构与内存作用域

```text
epan_dissect_run(edt, rec, fd, cinfo)                    [epan/epan.c:755]
 └─ dissect_record                                       [epan/packet.c:617]
     ├─ pi.pool = wmem BLOCK_FAST (每包整体重置)          [epan/epan.c:691,730]
     ├─ edt->tvb = tvb_new_real_data(rec->data 缓冲)  <== 零拷贝,数据在 wtap rec
     └─ dissect_frame(tvb)                               [packet-frame.c:568]
        ├─ Frame  (proto_node + field_info) ←内存: pi.pool
        │    ├─ Frame Number/Time/... (hf 字段)
        │    └─ Ethernet II                        ← wtap_encap 表派发
        │         ├─ Source/Dest (FT_ETHER)
        │         └─ IPv4  ← tvb_new_subset_remaining / subset_length(窗口,不复制)
        │              ├─ Version/IHL/TTL/Checksum (hf 字段)
        │              └─ TCP ← tvb_new_subset_length_caplen   [packet-tcp.c:6056]
        │                   ├─ Src/Dst Port → pinfo->srcport/destport
        │                   ├─ Seq/Ack/Flags
        │                   └─ HTTP ← tvb_new_subset_remaining [packet-tcp.c:8418]
        │                        └─ GET /... (FT_STRING)
        └─ (tvb 链)  real(frame) ⇄ subset(eth) ⇄ subset(ip) ⇄ subset(tcp) ⇄ subset(http)
                     —— 全部挂在 edt->tvb 的 next 链上,随 tvb_free_chain 整链释放
内存三层:  gpa_hfinfo/header_field_info    → epan 会话级(注册一次)
           frame_data(fd)                  → 捕获文件级(跨包存活)
           proto_node/field_info/fvalue/tvb链/pi.pool → 包级(epan_dissect_reset 清空)
```

### 设计动机(为什么这样设计)

1. **树节点 7 指针 + 实例分离**:同一字段在全包出现千万次,注册表信息(`header_field_info`)只存一份,每包仅存偏移/长度/值,内存与缓存友好(proto.h:913-935)。
2. **隐形树两级退化(NULL 树 → fake 节点)**:让"不过滤/不显示"场景几乎零开销,同时保住父子结构使引用字段仍可挂接(proto.c:120-159)。
3. **异常而非错误码做边界防护**:解析器代码不必层层 if,越界即 THROW,由帧层统一兜底画 malformed(tvbuff.c:427-437;packet.c:762-770)。
4. **tvb 单链 + 池化释放**:一帧几十个子 tvb 不需要逐个 free,两个 O(链长)/O(1) 次回收操作搞定(tvbuff.c:120-127;epan.c:722,730)。
5. **每包池(WMEM_BLOCK_FAST)代替逐对象 g_free**:块式 bumped allocation 使"分配≈指针递增、释放≈清零状态",2 MiB 大块摊薄 malloc 成本(wmem_allocator_block_fast.c:42,72-77)。
6. **索引化 hf 注册表(gpa_hfinfo 下标即 id)**:`PROTO_REGISTRAR_GET_NTH` 是数组取值而非哈希查找,这是每字段每包都要走的热路径(proto.c:464-469)。
7. **熔断内建**:节点总数、树深、"start 不前进"三重死循环探测写进最热路径,防御恶意报文(proto.c:136-147,6607-6630,7151-7160)。

### FAQ 候选(每条一句话答案)

1. Q:tshark 不加 -V 时树是 NULL 吗?——A:默认仍创建树但 `visible=false`,fake 机制生效;完全不建树需 `create_proto_tree=false`(epan.c:694-699,691)。
2. Q:fake 节点和普通节点区别在哪?——A:它是没有 `finfo` 的真 `proto_node`,仅作挂接占位(proto.c:6607-6630)。
3. Q:过滤器引用如何让字段"逃过"fake?——A:dfilter 编译后经 `epan_dissect_prime_with_dfilter → proto_tree_prime_with_hfid` 置 `ref_type=HF_REF_TYPE_DIRECT`(epan.c:847-866;proto.c:8359)。
4. Q:为什么 `hfindex` 必须非 0?——A:id 0 是保留哨兵,`gpa_hfinfo.hfi[0]=NULL`,GET_NTH 直接断言失败(proto.c:464-469,10225)。
5. Q:顶层 tvb 的数据是谁的?——A:直接指向 wtap 记录缓冲 `rec->data`,零拷贝(packet.c:751-752)。
6. Q:subset tvb 会复制数据吗?——A:不会,只存偏移/长度窗口;仅当背书非连续(如 composite)时 get_ptr 才物化(tvbuff_subset.c:119-158)。
7. Q:ReportedBoundsError 和 BoundsError 差别?——A:前者超出"报文声称长度"(报文损坏),后者只在已捕获与包含长度之间(tvbuff.c:212-229;exceptions.h:25,47)。
8. Q:proto_tree_reset 为什么不用逐节点 free?——A:节点在 pi.pool 上,`wmem_free_all` 整体回收,只需对 fvalue 做 `fvalue_cleanup`(proto.c:926-932;epan.c:730)。
9. Q:同一个 abbrev 能注册多个字段吗?——A:能,`same_name_prev_id/same_name_next` 链就是为此存在(proto.h:790-791;proto.c:10234 起)。
10. Q:每包池会被销毁吗?——A:通常不,`epan_dissect_cleanup` 把它放入 `pinfo_pool_cache` 复用,多余才销毁(epan.c:830-836)。
11. Q:TCP 载荷 tvb 从哪来?——A:`tvb_new_subset_length_caplen` 从帧 tvb 切窗口(packet-tcp.c:6056),再按端口二次 subset 下发(:8412-8418)。

### 深挖方向

1. `proto_tree_new_item` 的 FT 类型分派全表与 fvalue 体系(epan/proto.c:2909-3100 + epan/ftypes/),尤其 FT_PROTOCOL 的 `proto_tree_set_protocol_tvb`。
2. dfilter 编译期如何生成 priming 列表、以及 `interesting_hfids` 在 tap 过滤中的作用(tree_data_t,proto.h:903)。
3. wmem BLOCK_FAST 的 slab/buddy 细节与 `WIRESHARK_DEBUG_WMEM_OVERRIDE` 在内存排查中的实操(wmem_allocator_block_fast.c 全文)。
4. tvbuff 的 `contained_length` 引入对截断捕获(切片抓包)语义的影响,及 `TVBUFF_FRAGMENT` 与重组(tvb-fragment)的交互。
5. pinfo 的 `conv_addr_port_endpoints`/`conversation` 新会话模型与旧 srcport/destport 的并存逻辑(packet_info.h:182-183 + epan/conversation.c)。

### 正文蒸馏要点

1. 入口链四跳:`epan_dissect_run`(epan.c:755)→`dissect_record`(packet.c:617)→`frame_handle` 派发(packet.c:760)→`dissect_frame`(packet-frame.c:568),随后经 `wtap_encap` 表进入链路层(packet-frame.c:1148-1157)。
2. 协议树是三层引用:`proto_node`(树形,epan/proto.h:913-922)挂包级 `field_info`(proto.h:822-835)指向会话级 `header_field_info`(proto.h:773-792);`proto_tree/proto_item` 是同一结构 typedef(proto.h:925-927)。
3. hf 字段启动时经 `proto_register_field_array` 一次性注册进 `gpa_hfinfo`,下标即 id,约 30 万项(proto.c:9220-9258,471-480);`PROTO_REGISTRAR_GET_NTH` 为 O(1) 数组访问加断言(proto.c:464-469)。
4. `TRY_TO_FAKE_THIS_ITEM` 三条件:树不可见、父项 FI_HIDDEN、字段未被 DIRECT/PRINT 引用;FT_PROTOCOL 默认可 fake 但受 `fake_protocols` 控制(proto.c:148-158;root 默认 true,proto.c:8331)。
5. fake 节点是无 finfo 的真节点,既计数(死循环熔断)又保挂接;总数超 `gui_max_tree_items` 抛 DissectorError(proto.c:134-147,6607-6630)。
6. 隐形省的是节点+repr(vsnprintf),不是字节读取:取值与长度校验发生在判空/判 fake 之前(proto.c:4571-4576;REPR 宏 proto.c:172-181)。
7. tvbuff 已 vtable 化,无 REAL/SUBSET/COMPOSITE 枚举;统一字段含 `contained_length` 与链表 `next`(tvbuff-int.h:88-131),三种实现分置 tvbuff_real/subset/composite.c。
8. subset tvb 是零复制窗口,直接复用背书 real_data 偏移并继承 ds_tvb(tvbuff_subset.c:143-155);TCP 载荷即两级 subset(packet-tcp.c:6056,8418)。
9. 边界异常四级阶梯:Bounds/Fragment/Contained/Reported(tvbuff.c:212-229;exceptions.h:25-57),顶层只兜底 Reported/Fragment 并画 malformed(packet.c:765-769)。
10. wmem 四 allocator(SIMPLE/BLOCK/BLOCK_FAST/STRICT)统一 vtable,底层仍是 glib g_malloc/g_free(wmem_core.c:129-165,33-35);`wmem_packet_scope` 已废,pinfo->pool(BLOCK_FAST,epan.c:691)当每包作用域,应用层 `epan_dissect_reset → wmem_free_all` 重置(epan.c:730;tshark.c:3608),池经 pinfo_pool_cache 复用(epan.c:830-836)。
11. pinfo 无 cdat/ldat;关键字段为 num/fd/rec/src/dst/ptype/srcport/destport/pool(packet_info.h:47-183),每包由 dissect_record 从 fd 灌值并清零(packet.c:632-691)。
12. 生命周期三段:注册表随 epan 会话、frame_data 随捕获文件(frame_data.h:63-101,visited :84)、树节点/tvb 链/池随单包(epan.c:708-734)。
