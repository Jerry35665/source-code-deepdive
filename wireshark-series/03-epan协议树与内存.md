# 第 03 章 · epan 协议树与内存:三层树、假节点与按包池

> 基线:tag `v4.7.3`(commit `f6e0bf22`)。核心:epan/proto.c / epan/tvbuff.c / epan/epan.c / wmem。

## 3.0 全景:一棵树,两种开销

```
 pinfo(每包归零再灌值,pinfo->pool=BLOCK_FAST 池,epan/epan.c:691)
  └ proto_node{first_child/last_child/next/parent, hfinfo, finfo, tree_data}(proto.h:913-922)
      hfinfo ──► header_field_info(全局注册表 gpa_hfinfo,启动期一次性 30 万条,proto.c:471-474)
      finfo  ──► field_info{start/length, fvalue, rep}(每包实例,池上分配,可空=假节点)
 tvb 链:顶层 REAL tvb 零拷贝指向 rec 缓冲 → subset 窗口(不复制)→ 单链整体释放
 异常阶梯:BoundsError(截断)→ FragmentBoundsError → ContainedBoundsError → ReportedBoundsError
```

纠偏:4.7.3 的 tvbuff 已**彻底 vtable 化**——不再有 TVBUFF_REAL_DATA/SUBSET/COMPOSITE 类型枚举(全仓 grep 为空),`struct tvbuff` 改为 `tvb_ops` 虚表+统一 length/reported_length/contained_length 字段,三种语义按文件分置 tvbuff_real.c/tvbuff_subset.c/tvbuff_composite.c(epan/tvbuff-int.h:14-131)。引用旧教材的"三种类型枚举"写法对本版已失效。

## 3.1 解码入口链与每包归零

`epan_dissect_new`(epan/epan.c:737)→`epan_dissect_init`:创建 `pi.pool = wmem_allocator_new(WMEM_ALLOCATOR_BLOCK_FAST)`(epan.c:691,池经 pinfo_pool_cache 跨 edt 复用,epan.c:686-689, 830-836),按需建根树并 set_visible。`dissect_record`(epan/packet.c:751-774)先做 pinfo 的"每包归零":六个地址 clear、ptype 归 PT_NONE、layers 在池上新建 wmem_list(packet.c:673-692);再 `tvb_new_real_data` 让顶层 tvb **零拷贝**指向接收缓冲,`call_dissector_with_data(frame_handle,...)` 进入帧解析,CATCH 层兜底把 ReportedBoundsError 画成 malformed(packet.c:762-769)。帧解析器按 `pkt_encap` 从 wtap_encap 表取链路层句柄派发(packet-frame.c:1148-1157)。

## 3.2 三层结构与字段注册

树节点本体只有 4 个指针+hfinfo/finfo/tree_data(proto.h:913-922);field_info 是每包实例(含 fvalue 与 GUI repr),header_field_info 是全局注册项(名称/abbrev/FT 类型)。注册走 `proto_register_field_array` → `proto_register_field_init`:hfinfo 指针挂进全局数组 gpa_hfinfo,**预分配 30 万条、尾部追加、id==len-1**,add_* 家族用 `PROTO_REGISTRAR_GET_NTH` O(1) 取回(epan/proto.c:471-480, 10210-10240, 464-469)。注册发生在 epan_init 阶段一次性完成,注释自述"启动时几乎被调用 30 万次"(proto.c:9245)——树不可见与否与注册无关。

`proto_tree_add_item_new` 的顺序值得注意:先 `get_hfinfo`+`get_hfi_length`+`test_length`,**然后**才 CHECK_FOR_NULL_TREE 与 TRY_TO_FAKE_THIS_ITEM(proto.c:4563-4581)——即使树不可见,字节读取与越界异常照样发生。

## 3.3 假节点:省的是建节点+格式化,不是读包

`TRY_TO_FAKE_THIS_ITEM`(proto.c:120-167,全文件 59 处调用)触发条件(全满足):树不可见、父项 FI_HIDDEN、字段未被 DIRECT/PRINT 引用、非 FT_PROTOCOL(或允许 fake 协议)。命中返回 `proto_tree_add_fake_node`——**没有 field_info 的真节点**,保证下层仍有挂接点、仍计数并受 gui_max_tree_items 熔断(proto.c:134-157, 6607-6630)。配套 `TRY_TO_FAKE_THIS_REPR` 跳过 vsnprintf 生成 repr——"树不可见时字符串格式化开销趋近于零"的出处(proto.c:172-181, 986-989)。纠偏:"无 -V 时解码零开销"是误读,省的只是节点与格式化;引用标记由 `proto_tree_prime_with_hfid` 完成(直接引用置 DIRECT、父协议置 INDIRECT,proto.c:8348-8372)。

## 3.4 tvbuff:窗口与异常阶梯

subset 是背书 tvb 的"窗口",不复制数据:背书连续时 real_data 直接指到偏移处,ds_tvb 继承顶层源,tvb 链头插成单链、随包整体 `tvb_free_chain` 释放(tvbuff_subset.c:119-158; tvbuff.c:120-150; 生命周期契约 tvbuff.h:55-73——解析器不得保存 tvb 到下一帧)。`compute_offset` 的异常阶梯(tvbuff.c:212-229):offset 超过已捕获长度但在 contained_length 内 → BoundsError;分片配置问题 → FragmentBoundsError;超过 reported_length → ReportedBoundsError(报文自称更长,顶层兜底画 malformed)。所有 tvb_get_* 必经 `ensure_contiguous` → `check_offset_length` THROW(tvbuff.c:427-437)。

## 3.5 wmem:池生命周期在应用层

纠偏:`wmem_packet_scope()` 已消亡——每包池是 `pinfo->pool`,重置调用点在应用循环的 `epan_dissect_reset → wmem_free_all`(epan.c:730; tshark.c:3608)。wmem 四种 allocator(BLOCK_FAST 等)底层仍是 glib g_malloc/g_free(wmem_core.c:33-35),它的价值是**作用域化批量释放**:树节点、fvalue、layers 列表全部池上分配,连"取值中途抛异常"也不需要清理处理器(proto.c:2924-2931 注释自证)。纠偏:pinfo->cdat/ldat 在本 tag 不存在,引用旧资料会出错。

## 3.6 设计动机

1. **注册与实例分离**:30 万字段只注册一次,每包只付 finfo 成本,数组下标即 id(proto.c:10210-10240);
2. **假节点保挂接**:隐形树仍维持父子结构,协议树遍历代码零特判(proto.c:6607-6630);
3. **按包池**:解析器从此不写 free——异常安全免费获得(proto.c:2924-2931);
4. **tvb 窗口不复制**:切片成本 O(1),越界防护集中在 ensure_contiguous 一处(tvbuff.c:945-985);
5. **熔断内建**:节点数/空闲计数双阈值防解析器死循环(proto.c:136-147, 7148-7162)。

## 3.7 FAQ

**Q1:树不可见时字段还解析吗?**
读包照旧(取值在判 fake 之前),省的只是节点与格式化(proto.c:4571-4576)。

**Q2:字段 id 是怎么编的?**
注册数组尾部追加,id==len-1,O(1) 回查(proto.c:10240)。

**Q3:假节点是什么?**
无 field_info 的真节点,保挂接、仍计数(proto.c:6607-6630)。

**Q4:子 tvb 复制数据吗?**
不,subset 是窗口;背书连续时直接指偏移处(tvbuff_subset.c:143-145)。

**Q5: ReportedBoundsError 和 BoundsError 区别?**
前者报文声明长度就不够(画 malformed);后者捕获截断内越界(tvbuff.c:212-229)。

**Q6:每包内存何时释放?**
应用循环 epan_dissect_reset → wmem_free_all(epan.c:730)。

**Q7:解析器要 free 内存吗?**
不用,一切在 pinfo->pool 上,异常也安全(proto.c:2924-2931)。

**Q8:一帧有多个 tvb 怎么释放?**
tvb_new_chain 串成单链,tvb_free_chain 整体释放(tvbuff.c:120-150)。

**Q9:死循环解析怎么防?**
节点计数与"start 不前进"空闲计数双熔断(proto.c:136-147, 7148-7162)。

**Q10:packet_scope 还能用吗?**
本 tag 已消亡,换用 pinfo->pool 与显式 allocator。

## 3.8 小结与深挖方向

本章结论:**协议树=全局注册表+每包 finfo 实例;内存=按包 BLOCK_FAST 池;防护=tvb 异常阶梯;优化=假节点跳过节点与格式化而非读包**。深挖:

1. tvb_ops 虚表的 clone/find 在 composite 重组路径的成本(tvbuff-int.h:14-95);
2. HF_REF_TYPE_DIRECT/INDIRECT 的 prime 传播对树重建的影响(proto.c:8348-8372);
3. pinfo_pool_cache 的池复用命中率与 BLOCK_FAST 块大小调参(epan.c:830-836);
4. ptvcursor 与 add_item_new 两条写树路径的性能差(proto.c:4533-4558);
5. expert 信息与树节点的挂接时机(epan/expert.c)。
