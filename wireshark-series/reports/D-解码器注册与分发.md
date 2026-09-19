# 报告 D · 解码器注册与分发(Wireshark)

> 基线:tag v4.7.3,commit f6e0bf224bdabf5f09b897da64fe6b10c66173d4(epan/packet.c 共 4,323 行,epan/register.c 263 行,epan/conversation.c 3,533 行,epan/dissectors/ 下 1,700 个 packet-*.c)。一句话总结:Wireshark 用"构建期正则生成的注册函数表 + 三层运行期哈希(协议/句柄/dissector table)+ initial/current 双槽位"把全部解码器在启动时装配成一张可被 "Decode As"、启发式、会话三条旁路动态改写的分发网。

## 1. 注册模型与启动时序:一切始于生成的函数表

每个 packet-*.c 暴露两个入口:`proto_register_<x>`(声明协议、字段、表、启发式列表)与 `proto_reg_handoff_<x>`(把自己挂进别人的表、抓取他人句柄)。构建期由 `tools/make-regs.py` 用正则 `void\s+(proto_register_[\w]+)\s*\(\s*void\s*\)\s*{` 扫描全部源码,生成 `dissectors.c` 中的两个 `dissector_reg_t` 数组,并按字母序排列(tools/make-regs.py:44-46,53-54,60-71;生成命令见 epan/dissectors/CMakeLists.txt:2014-2015):

```c
// epan/dissectors/dissectors.h:20-27(生成物的公共头)
typedef struct _dissector_reg {
    const char *cb_name;
    void (*cb_func)(void);
} dissector_reg_t;
extern dissector_reg_t const dissector_reg_proto[];
extern dissector_reg_t const dissector_reg_handoff[];
extern const unsigned long dissector_reg_proto_count;
extern const unsigned long dissector_reg_handoff_count;
```

启动链条(tshark 为例,逐跳带行号):

1. `tshark.c:1377-1378`:把 `register_all_protocols` / `register_all_protocol_handoffs` 填入 `epan_app_data`(字段定义 epan/epan.h:197-198);`:1380` 调 `epan_init`;
2. `epan/epan.c:337`:HAVE_PLUGINS 时先 `plugins_init` 加载动态插件;
3. `epan/epan.c:374-409` 顺序:`packet_init()`(建全局哈希,epan/packet.c:229-250)→ `proto_init(...)`(395)→ `packet_cache_proto_handles()`(398;缓存 frame/file/data 三个句柄,packet.c:252-266)→ `final_registration_all_protocols()`(401;跑 `register_final_registration_routine` 收尾回调,packet.c:599-612)→ `register_all_tap_listeners`(408)→ `uat_load_all`(409);
4. `epan/proto.c:656`:`register_func(cb, client_data)` 即 `register_all_protocols`,遍历 `dissector_reg_proto[]` 逐个 `cb_func()`(epan/register.c:42-45,99-103);随后 659-661 行调用 epan 插件协议注册、666 行调用 `dissector_plugins` 的 protoinfo;
5. `epan/proto.c:673`:`handoff_func` 即 `register_all_protocol_handoffs`(register.c:111-114,173-177),再轮到 epan 插件 handoff(676-678)与 dissector 插件 handoff(681-683),最后排序协议列表并 `packet_all_tables_sort_handles()`(proto.c:686-690)。

协议注册与 handoff 被刻意分成两批:进入 handoff 阶段时,所有 `register_dissector`/`register_dissector_table` 必然已完成,proto.c:668-671 的注释明说 handoff 例程要"register the dissector in other dissectors' handoff tables, and fetch any dissector handles they need"。带进度回调时,worker 跑在独立线程,主线程每 150ms 用 `cb(RA_REGISTER, cur_cb_name, ...)` 上报当前正在注册的协议名,支撑 GUI 启动进度条:

```c
// epan/register.c:74-89(worker + 回调,常量 CB_WAIT_TIME 在 :28)
static void *
register_all_protocols_worker(void *arg _U_)
{
    ...
    for (unsigned long i = 0; i < dissector_reg_proto_count; i++) {
        set_cb_name(dissector_reg_proto[i].cb_name);
        dissector_reg_proto[i].cb_func();
    }
    ...
}
        while (!g_async_queue_timeout_pop(register_cb_done_q, CB_WAIT_TIME)) {
            ...
            cb(RA_REGISTER, cb_name, cb_data);
```

`register_count()` 返回 `dissector_reg_proto_count + dissector_reg_handoff_count` 之和(register.c:179-182)。同一套机制在 4.7 新扩展出 event dissector:`event_register_*`/`event_reg_handoff_*` 由 `register_all_event_dissectors[_handoffs]` 调度(register.c:184-250)。

## 2. 三件套:proto_register_protocol → register_dissector → dissector_add_uint

**第一件:协议本体。** `proto_register_protocol(name, short_name, filter_name)` 分配 `protocol_t`,把三个名字分别插进 `proto_names` / `proto_filter_names` / `proto_short_names` 三张哈希,任一重复即 REPORT_DISSECTOR_BUG;并为协议自身注册一个 FT_PROTOCOL 字段、返回 proto_id(epan/proto.c:8608-8668):

```c
// epan/proto.c:8620-8666(节选)
protocol = g_new(protocol_t, 1);
protocol->is_enabled = true;           /* protocol is enabled by default */
protocol->enabled_by_default = true;
protocols = g_list_prepend(protocols, protocol);
if (!g_hash_table_insert(proto_names, (void *)name, protocol)) {
    REPORT_DISSECTOR_BUG("Duplicate protocol name \"%s\"...", name); }
...
protocol->proto_id = proto_register_field_init(hfinfo, hfinfo->parent);
```

pino 协议(选项/辅助"伪协议")走 `proto_register_protocol_in_name_only`,只允许 FT_PROTOCOL/FT_BYTES 两种类型(proto.c:8671-8684)。TCP 就用它把 20 多个 TCP 选项包成独立协议(packet-tcp.c:11326 起)。

**第二件:句柄。** `register_dissector(name, dissector, proto)` 创建 `struct dissector_handle`(含 name/description/dissector_type/函数联合体/dissector_data/protocol,packet.c:860-878)并插入全局 `registered_dissectors`;重名直接 `ws_error` 终止进程,epan/packet.c:3608-3612 的报错文本还提示应改用 `create_dissector_handle()` 创建匿名句柄(packet.c:3603-3622,3626-3633)。`find_dissector` 就是这张表的一次 `g_hash_table_lookup`(packet.c:3449-3452);`deregister_dissector` 会连依赖表一起清(3671-3682)。

**第三件:挂表。** `register_dissector_table(name, ui_name, proto, type, param)` 按键类型建哈希:uint 表用 `g_direct_hash`(值本身充当键),string 表用 `g_str_hash`,另有 FT_GUID / FT_NONE / 自定义 FT_BYTES(`register_custom_dissector_table`,允许自带哈希函数,packet.c:2852-2877)五类:

```c
// epan/packet.c:2795-2806(uint 表的哈希选型)
case FT_UINT8:
case FT_UINT16:
case FT_UINT24:
case FT_UINT32:
    /* XXX - there's no "g_uint_hash()" or "g_uint_equal()",
     * so we use "g_direct_hash()" and "g_direct_equal()". */
    sub_dissectors->hash_table = g_hash_table_new_full(g_direct_hash,
                                                       g_direct_equal,
                                                       NULL, &g_free);
```

`dissector_add_uint(name, pattern, handle)` 校验表与句柄存在(`dissector_get_table_checked`,packet.c:1289-1310,失败走 `ws_dissector_oops`)后写入 `dtbl_entry`——每个槽位是 **initial + current 两个 handle**(packet.c:1212-1215;写入逻辑 `dissector_add_uint_real` 1312-1347)。若表支持 "Decode As",add_uint 顺手把句柄登入该表候选名单(packet.c:1365-1366)。范围注册 `dissector_add_uint_range` 逐个展开 low..high 并同样参加 Decode As(1369-1391)。全仓库规模(grep 统计,epan/dissectors/):约 1,958 处 `proto_register_protocol(`、2,120 处 `register_dissector("`、549 处 `register_dissector_table(`、452 处 `heur_dissector_add(`、1,329 个 `proto_reg_handoff_*` 定义。

## 3. dissector table 与 "Decode As":改 current 不改 initial

`struct dissector_table` 四要素:`hash_table`(pattern→dtbl_entry)、`dissector_handles`(该表候选句柄 GSList,仅支持 Decode As 的表维护)、`da_descriptions`(描述→句柄,描述必须唯一,供 GUI 选择与文件写回)、type/param/protocol(protocol 关联用于依赖分析)(epan/packet.c:97-105,62-96 注释)。

用户在 "Decode As" 对话框的改动走 `dissector_change_uint`(packet.c:1650)/`dissector_change_string`(1965):只覆写 `dtbl_entry->current`(1672);`dissector_reset_uint` 把 current 拨回 initial、无 initial 则整槽删除(1695-1720);`dissector_is_uint_changed` 以 `current != initial` 判定"此值被用户改过"(packet.c:1727-1736)——TCP 分发正是用它实现"用户指定优先"(见第 6 节)。

持久化载体是名为 `decode_as_entries` 的 profile 文件(键 `decode_as_entry`,值为 `table,selector,initial,current` 四段 CSV):`load_decode_as_entries` 在 `epan_load_settings` 中经 `read_prefs_file` 逐行解析,查到表后重放 `dissector_change_uint/string`,并对 `(none)` 特殊处理为 NULL 句柄(epan/decode_as.h:24,30;epan/decode_as.c:188-284,287-303;调用点 epan/epan.c:437-453)。注意 packet.c:80-83 注释把它称作 "the decode_as_entries UAT",但实现并非 UAT 框架(详见纠偏)。表还支持别名:`register_dissector_table_alias` 把旧表名映射到现行表名,`find_dissector_table` 查不到正名时查别名并 `ws_warning`(packet.c:1218-1232,2880-2895)。

```c
// epan/decode_as.c:201-243(节选,重放一条规则)
if (strcmp(key, DECODE_AS_ENTRY) == 0) {
    /* Parse csv into table, selector, initial, current */
    ...
    sub_dissectors = find_dissector_table(values[0]);
    ...
    handle = dissector_table_get_dissector_handle(sub_dissectors, values[3]);
    if (handle != NULL || g_ascii_strcasecmp(values[3], DECODE_AS_NONE) == 0) {
        is_valid = true; }
    if (is_valid) {
        if (FT_IS_STRING(selector_type)) {
            dissector_change_string(values[0], values[1], handle);
        } else {
            ...
            dissector_change_uint(values[0], (unsigned)long_value, handle);
```

## 4. 启发式 dissector:prepend 注册 + 命中冒泡

启发式列表先以表名注册:`register_heur_dissector_list_with_description`/`register_heur_dissector_list` 建立以表名为键的哈希条目(packet.c:3336-3357;全局容器 `heur_dissector_lists` 建于 packet_init,246-247),TCP 的列表名是 `"tcp"`,UI 名 "TCP heuristic"(packet-tcp.c:11323)。`heur_dissector_add` 做四件事:按 (dissector 函数, protocol) 二元组查重、校验内部名必须全小写合法(`check_valid_heur_name_or_fail`,2942-2950)、登记进 `heuristic_short_names` 全局哈希(短名重复即 ws_error,3026-3029)、**g_slist_prepend 头插**(packet.c:3015-3042,头插在 3031)。所以顺序是"后注册者先试";此外命中一次后,`dissector_try_heuristic` 会把命中的 entry 摘下拼到链首,越常用越靠前:

```c
// epan/packet.c:3180-3184
/* Bubble the matched entry to the top for faster search next time. */
if (prev_entry != NULL) {
    sub_dissectors->dissectors = g_slist_remove_link(sub_dissectors->dissectors, entry);
    sub_dissectors->dissectors = g_slist_concat(entry, sub_dissectors->dissectors);
}
```

遍历逻辑(packet.c:3082-3196):对每个候选,先检查协议启用与单项 `enabled` 开关(3129-3135,该位来自注册时的 `HEURISTIC_ENABLE`/`HEURISTIC_DISABLE`,3021-3022);先 `add_layer` 再调 `hdtbl_entry->dissector`,返回 0 或没画任何树节点则 `remove_last_layer` 回滚层号(3148-3172);期间 `pinfo->heur_list_name` 记录当前表名(3151)。命中时通过出参 `heur_dtbl_entry` 把命中项告知调用方(3178)——TCP 用它在 "Follow Stream" 等处还原选择。`heur_dissector_delete` 支持反注册(3055-3079)。另有 `call_heur_dissector_direct` 允许直接重放某个启发式项(3735-3779)。

## 5. 分发路径:call_dissector 链与 can_desegment 的单跳授权

查表链与句柄链是两条正交路径。查表链:`dissector_try_uint_with_data` → `find_uint_dtbl_entry`(一次 `g_hash_table_lookup`,键经 `GUINT_TO_POINTER`,packet.c:1235-1264)→ 取 `dtbl_entry->current`(为 NULL 视作"无此 dissector"返回 0,好让其他候选有机会,1763-1771)→ 保存/设置/恢复 `pinfo->match_uint` → `call_dissector_work`(packet.c:1743-1797);`dissector_try_uint` 是 `add_proto_name=true, data=NULL` 的薄封装(1799-1805);字符串表对应 `dissector_try_string_with_data`(2057 起)。

```c
// epan/packet.c:1752-1780(节选)
dtbl_entry = find_uint_dtbl_entry(sub_dissectors, uint_val);
if (dtbl_entry == NULL) {
    return 0;                       /* There's no entry in the table */
}
handle = dtbl_entry->current;
if (handle == NULL) {
    return 0;                       /* pretend this dissector didn't exist */
}
saved_match_uint  = pinfo->match_uint;
pinfo->match_uint = uint_val;
len = call_dissector_work(handle, tvb, pinfo, tree, add_proto_name, data);
pinfo->match_uint = saved_match_uint;
```

句柄链层层包裹:`call_dissector` → `call_dissector_with_data`(ret==0 时兜底 `call_data_dissector`,packet.c:3701-3716)→ `call_dissector_only`(不兜底,3688-3696)→ `call_dissector_work`(990-1088)→ `call_dissector_through_handle`(按 `DISSECTOR_TYPE_SIMPLE`/`DISSECTOR_TYPE_CALLBACK` 两种函数指针形态调用,957-969)。`call_dissector_work` 的职责是"跨层环境管理":协议未启用直接返回 0(1002-1008);递减 `can_desegment`;压栈/出栈 `current_proto`、层号与 layers 列表(1010-1043,1084-1087);若子 dissector 一字未消费或没画树,把刚加的层回滚(1053-1083)。错误包(ICMP 内嵌帧等)走 `call_dissector_work_error`,异常时恢复列可写性、地址端口与 can_desegment(packet.c:1091-1173)。

```c
// epan/packet.c:1016-1029(单跳授权注释与实现)
/*
 * can_desegment is set to 2 by anyone which offers the
 * desegmentation api/service.
 * Then every time a subdissector is called it is decremented
 * by one.
 * Thus only the subdissector immediately on top of whoever
 * offers this service can use it.
 * We save the current value of "can_desegment" for the
 * benefit of TCP proxying dissectors such as SOCKS, ...
 */
pinfo->saved_can_desegment = saved_can_desegment;
pinfo->can_desegment = saved_can_desegment-(saved_can_desegment>0);
```

子 dissector 侧的"请求重组"协议:把 `pinfo->desegment_len` 置为还差的字节数(`DESEGMENT_ONE_MORE_SEGMENT`/`DESEGMENT_UNTIL_FIN` 为特殊值)、`desegment_offset` 置为未消费起点(字段语义见 packet-tcp.c:558-559 注释)。

## 6. conversation:四元组通配查找 + 挂在会话上的协议数据

会话键已从旧 addr/port 结构体升级为 `conversation_element_t` 数组(`CE_ADDRESS`/`CE_PORT`/`CE_CONVERSATION_TYPE` 结尾,epan/conversation.h:229-231,243,261;数组最长 8 元素,conversation.c:220-233)。存储按通配形态分成多张 wmem_map:`exact_addr_port`、`exact_addr`、`no_addr2`、`no_port2`、`no_addr2_or_port2`、`id`,外加 anchor 变体、deinterlacer、err_pkts(错误包引用本体)(epan/conversation.c:135-209)。`conversation_init` 在 `wmem_epan_scope()` 建索引 map,而数据本体 `wmem_map_new_autoreset(wmem_epan_scope(), wmem_file_scope(), ...)`,即 **conversation 键的容器是 epan 级、值随文件开关清空**(conversation.c:589-620)。

`find_conversation(frame_num, addr_a, port_a, addr_b, port_b, ctype, options)` 的查找顺序:先正、反两个方向各做一次 exact 匹配,反方向命中且 `conv_index` 更大者胜(取"更新的"会话,conversation.c:1876-1922);失败再按 no_addr2 → no_port2 → no_addr2_or_port2 逐级放宽通配,命中 no_addr2 且非 UDP 时还会把通配地址补实(`conversation_set_addr2`,1949-1974);Fibre Channel 因 OXID/RXID 不对调而走特殊键序(1909-1916,1941-1948)。

```c
// epan/conversation.c:2810-2821(会话分发器:按帧号取句柄)
if (!conversation->dissector_tree) {
    return false;
}
dissector_handle_t handle = (dissector_handle_t)wmem_tree_lookup32_le(
        conversation->dissector_tree, pinfo->num);
if (handle == NULL) {
    return false;
}
ret = call_dissector_only(handle, tvb, pinfo, tree, data);
```

会话不直接存 dissector,而是带一棵按帧号组织的 `dissector_tree`:"Decode As"/`conversation_set_dissector` 写入的句柄经 `wmem_tree_lookup32_le(dissector_tree, pinfo->num)` 取"该帧时点生效"的句柄并 `call_dissector_only`(epan/conversation.c:2806-2827)。TCP 总分发的第一步是 `try_conversation_dissector(&pinfo->src, &pinfo->dst, CONVERSATION_TCP, src, dst, ...)`,内部按 options 组合最多四次 `find_conversation`(packet-tcp.c:8426-8431;conversation.c:2840-2884)。TCP 的分析状态 `tcpd` 也挂在会话上:`conversation_get_proto_data(conv, proto_tcp)` 取,没有就 `init_tcp_conversation_data` + `conversation_add_proto_data`(packet-tcp.c:2193-2253),并按地址/端口比较结果区分 fwd/rev 流(2221-2247)。

## 7. packet-tcp.c 实例:注册规模、handoff、decode_tcp_ports 七级瀑布

`proto_register_tcp`(packet-tcp.c:10178)注册:主 hf 数组 215 项(10180 起至 ei 数组前,`grep -c '&hf_'` 计数)+ mptcp_hf 14 项(11241-11298);`register_dissector("tcp", dissect_tcp, proto_tcp)`(11313)与 capture 句柄;**"tcp.port" 表 FT_UINT16**(11321-11322)、**启发式表 "tcp"**(11323)、"tcp.option" 表 FT_UINT8(11324);`decode_as_t tcp_da` 定义 src/dst/both 三种端口组合的 Decode As 语义(11300-11304);prefs 注册含 `desegment_tcp_streams`(变量 `tcp_desegment`,4735;绑定 11368)、`try_heuristic_first`(8389;绑定 11435)、`tcp_reassemble_out_of_order`(559)。

```c
// epan/dissectors/packet-tcp.c:11313-11324(节选)
tcp_handle = register_dissector("tcp", dissect_tcp, proto_tcp);
...
proto_register_field_array(proto_tcp, hf, array_length(hf));
...
subdissector_table = register_dissector_table("tcp.port",
    "TCP port", proto_tcp, FT_UINT16, BASE_DEC);
heur_subdissector_list = register_heur_dissector_list_with_description("tcp", "TCP heuristic", proto_tcp);
tcp_option_table = register_dissector_table("tcp.option",
    "TCP Options", proto_tcp, FT_UINT8, BASE_DEC);
```

`proto_reg_handoff_tcp`(packet-tcp.c:11529-11572)只做四类事:`dissector_add_uint("ip.proto", IP_PROTO_TCP, tcp_handle)`(11531)、`dissector_add_for_decode_as_with_preference("udp.port", tcp_handle)`(11532)、`capture_dissector_add_uint("ip.proto", ...)`(11536)、为 TCPOPT_* 建 20+ 个句柄挂 "tcp.option" 表(11539-11564)。**没有任何 `dissector_add_uint("tcp.port", ...)`**——全仓库 32 处 tcp.port 注册分散在 23 个应用 dissector 文件中(各协议自己挂端口)。

入口 `dissect_tcp`(packet-tcp.c:8847)先管 `can_desegment`:9685 清零;数据完整、`tcp_desegment` 开启且非错误包时置 2(9849-9858),残缺/校验不过则 `desegment_ok=false`(9840-9846)。载荷经 `dissect_tcp_payload`(8688-8717:`pinfo->can_desegment` 非零走 `desegment_tcp`,否则 `process_tcp_payload` 直通)→ `decode_tcp_ports`(8394)完成子协议选择,瀑布顺序:

1. keepalive 段直接当 data,不调子 dissector(8406-8416);
2. `try_conversation_dissector`(8426-8431);
3. server/low/high 端口中**被 Decode As 改过的**先试(`dissector_is_uint_changed` → `dissector_try_uint_with_data`,8437-8505);
4. `try_heuristic_first` 开启则先启发式(8507-8514);
5. 默认顺序 server(SYN/SYN-ACK 观测的服务端口)→ low → high(8516-8551;注释解释偏好低位/服务端口的原因);
6. 启发式(未提前试时,8553-8560);
7. 全部拒绝则先 `DISSECTOR_ASSERT` 没人偷偷请求重组,再 `call_dissector(data_handle, ...)` 兜底(8562-8573)。

`desegment_tcp`(4950)是消费端:进入先清 `desegment_offset/len`(4990-4991);子 dissector 返回后若 `pinfo->desegment_len!=0` 置 `must_desegment` 并记 `deseg_offset`(5505-5518);多段 PDU 表(MSP)命中则 `fragment_add` 进 `tcp_reassembly_table`(5370-5416),凑齐时 `tvb_new_chain` 合成新 TVB、加 "Reassembled TCP" 数据源、置 `tcpinfo.is_reassembled` 再调子 dissector(5537-5562);还不够就 `fragment_set_partial_reassembly` 等下一帧(5606-5613);一帧内还有后续 PDU 时重新置 `can_desegment=2` 并 `goto again`(5856-5874)。乱序重组 `reassemble_ooo` 由四个条件合成(4969)。

## 8. 插件注册:GModule dlopen + plugin_register 自登记

插件加载实现在 wsutil/plugins.c(不存在 epan/plugins.c)。`plugins_init(type, prefix)` 依次扫描全局目录与用户目录(提权启动或两目录相同时跳过后者),`scan_plugins_dir` 对每个 `.so/.dll`:`g_module_open` → 必须导出 `plugin_version` 且通过版本兼容检查 → 必须导出 `plugin_register` 并**立刻调用**(wsutil/plugins.c:158-247;目录选择在 256-283):

```c
// wsutil/plugins.c:196-222(节选)
if (!g_module_symbol(handle, "plugin_version", &symbol)) {
    report_failure("The plugin '%s' has no \"plugin_version\" symbol", name);
    ...
}
if (!pass_plugin_version_compatibility(handle, name)) { ... }
/* Search for the entry point for the plugin registration function */
if (!g_module_symbol(handle, "plugin_register", &symbol)) { ... }
((plugin_register_func)symbol)();
```

`plugin_register` 内部以 `proto_register_plugin`(epan/proto.c:564-575)/`epan_register_plugin` 等把回调挂进链表;真正的批量注册仍发生在 `epan_init`→`proto_init` 的插件阶段槽位(proto.c:659-683;epan.c:265-267,394-397,407)。仓库自带 14 个 epan 插件源码目录(plugins/epan/:mate、opcua、profinet、unistim、wimax 全家、ethercat、gryphon、irda、stats_tree、transum、falco_events、dfilter),经同一套 CMake 构建成动态库。Lua(wslua)不走 GModule,在 `epan_init` 尾部 `wslua_init` 挂入(epan.c:404-406)。

## 9. 纠偏(以本 tag 源码为准)

- **"packet-tcp.c 的 handoff 在约 1983 行、注册大批端口号"不成立**:本 tag `proto_reg_handoff_tcp` 在 packet-tcp.c:11529,函数体(11529-11572)不注册任何 tcp.port 条目;端口注册权已下放给各应用 dissector(32 处散布于 23 个文件)。handoff 阶段 TCP 只挂 `ip.proto`、`udp.port`(Decode As)与 `tcp.option`。
- **不存在 "dissector_utils.h / register-dissector 工厂"**:epan/dissectors/ 下没有 dissector_utils.h,注册设施只有 epan/packet.c 的 `register_dissector()` 系列;批量调用靠构建期 `tools/make-regs.py` 正则扫描生成 `dissectors.c` 数组(make-regs.py:42-48,2014-2015 行 CMake 命令),不是运行期反射、也不是头文件工厂。
- **TCP 入口函数不叫 `tcp_dissect`**:是 `dissect_tcp`(packet-tcp.c:8847),以名 "tcp" 的句柄注册(packet-tcp.c:11313),由 `ip.proto` 表键 IP_PROTO_TCP=6 命中(packet-tcp.c:11531)。
- **"decode_as_entries 是 UAT"的注释不可信**:packet.c:80-83 注释称其为 UAT,实现却是 profile 下 prefs 风格文本文件,经 `read_prefs_file` 解析(decode_as.c:294-298),与 uat*.c 的 UAT 框架无关。
- **启发式匹配顺序不是"注册序先注册先试"**:`heur_dissector_add` 头插(packet.c:3031)使后注册者先试,且命中后冒泡队首(packet.c:3180-3184);写作"按注册顺序匹配"均需纠正。
- **`call_dissector` 失败并非总是回退 data**:只有 `call_dissector_with_data` 在 ret==0 时兜底 data(packet.c:3708-3714);`dissector_try_uint` 查不到/被拒绝只返回 0,兜底责任在调用方(packet-tcp.c:8573)。

## 10. 分发链 ASCII 全景

```
   eth帧 → frame dissector → ip dissector(ip.proto 表)
        dissector_try_uint("ip.proto", 6)            packet.c:1743
                    │ dtbl_entry->current
                    ▼
            dissect_tcp  (handle 名 "tcp")            packet-tcp.c:8847
                    │  can_desegment=2(可重组时)      packet-tcp.c:9857
                    ▼
            decode_tcp_ports                          packet-tcp.c:8394
   ┌──────────┬──────────────┬───────────────┬─────────────┐
   │1 会话命中 │2 用户改过的端口│5 默认 server→low→high│4/6 启发式 "tcp"│
   │conversation│dissector_try_uint│(tcp.port 表)   │dissector_try_heuristic│
   │ _dissector│ ("tcp.port")  │  packet.c:1743 │ packet.c:3082│
   └────┬─────┴──────┬───────┴───────┬────────┴──────┬──────┘
        │            │               │全部拒绝          │
        ▼            ▼               ▼                ▼
  dissector_tree  子 dissector   call_dissector   data 兜底
  (wmem_tree按帧)  (HTTP/SSH/…)  _work→through_handle packet-tcp.c:8573
        │            │          (packet.c:990/941)
        └────────────┴──── 子 dissector 可请求 desegment_len>0
                          → desegment_tcp 重组后再调(packet-tcp.c:4950)
```

## 11. 设计动机

1. **构建期注册表替代运行期发现**:1,700 个文件的注册符号由正则在编译期固化进两个数组(make-regs.py:44-46),启动即纯循环调用(register.c:42-45),无 dlopen 扫描、无反射开销,链接器还顺带完成漏注册检查(make-regs.py:50-51 无注册即退出报错)。
2. **initial/current 双槽把 "Decode As" 做成可逆叠加**:默认分发永不丢失,用户覆盖只改 current(packet.c:1672),`dissector_is_uint_changed` 让 TCP 得以"用户指定优先"(packet.c:1728-1736;packet-tcp.c:8439),reset 一行归位(1714-1718)。
3. **can_desegment 递减实现"单跳授权"**:2→1→0 的门票(packet.c:1016-1029)确保只有直接挂在 TCP 上的 dissector 能要重组,又给 SOCKS 类代理留了 `saved_can_desegment` 恢复口。
4. **启发式先头插后冒泡**:把注册序、使用频率序与用户禁用位(packet.c:3021-3022,3129-3135)统一在一条 GSList 上,常见协议近 O(1) 命中。
5. **会话键 element 化 + 多张通配表**:一套 `conversation_element_t` 键覆盖四元组/双地址/单端口/纯 ID 等全部形态(conversation.c:135-165,222-233),`dissector_tree` 按 setup 帧号取句柄,天然支持"从某帧起换 dissector"(conversation.c:2815-2816)。
6. **注册与 handoff 两阶段严格分离**:先全员自我声明、再全员互挂钩件,消除跨文件初始化顺序问题(proto.c:651-683);插件的注册回调插进同一时序的固定槽位,动态与静态一体。
7. **注册可观测性**:后台线程 + 150ms 回调上报当前协议名(register.c:28,81-89),GUI 进度条与 tshark 启动日志都有颗粒度;`-G` 报告依赖的表排序集中在 `packet_all_tables_sort_handles`(proto.c:690;packet.c:2340-2353)。

## 12. FAQ 候选

1. Q: 1,700 个 dissector 的注册函数由谁在何时调用? A: 构建期 make-regs.py 生成数组,启动时 epan_init→proto_init→register_all_protocols 顺序遍历调用(register.c:99-103;proto.c:656)。
2. Q: 两个 dissector 抢同一个名字会怎样? A: `register_dissector_handle` 里插入失败直接 `ws_error` 终止进程,报 "already registered"(packet.c:3615-3619)。
3. Q: dissector table 的键可以是什么类型? A: FT_UINT8/16/24/32(direct-hash)、FT_STRING 系(g_str_hash,可忽略大小写)、FT_GUID、FT_NONE 及自定义哈希的 FT_BYTES(packet.c:2793-2838;1860-1864;2852-2877)。
4. Q: "Decode As" 到底改了什么? A: 只把 `dtbl_entry->current` 换成新句柄,initial 永不覆盖,reset 即回默认(packet.c:1212-1215,1672,1714-1718)。
5. Q: 用户级 Decode As 规则存在哪? A: 当前 profile 的 `decode_as_entries` 文件,四段 CSV `table,selector,initial,current`,启动时重放 change(decode_as.h:24,30;decode_as.c:203-243,294-298)。
6. Q: 启发式 dissector 的尝试顺序? A: 后注册先试(prepend)+ 命中者冒泡队首,禁用项跳过(packet.c:3031,3180-3184,3129-3135)。
7. Q: 子 dissector 怎么申请"数据不够,等我凑齐再调"? A: 置 `pinfo->desegment_len`(与 `desegment_offset`),TCP 在 desegment_tcp 里 fragment_add 凑齐后用合成 TVB 重调(packet-tcp.c:5509-5518,5413-5416,5546-5562)。
8. Q: 为什么子 dissector 设置了 desegment_len 却可能不生效? A: `can_desegment` 逐层递减,深层 dissector 无门票;且 TCP 要求"拒绝即不许请求重组",违者 DISSECTOR_ASSERT(packet.c:1028-1029;packet-tcp.c:8562-8570)。
9. Q: TCP 如何决定先试哪个端口? A: 会话 dissector → 被改过的 server/low/high → (可选启发式) → server → low → high → 启发式 → data(packet-tcp.c:8426-8573)。
10. Q: 插件和内置 dissector 的注册时序差异? A: 插件 dlopen 后先经 plugin_register 自登记回调(wsutil/plugins.c:212-222),但与内置逻辑一样在 proto_init 的 protocols→handoffs 两阶段槽位里被统一调用(proto.c:659-683)。

## 13. 深挖方向

1. `desegment_tcp` 的 MSP 状态机与 `epan/reassemble.c` 的 fragment_add 交互,含乱序重组 `reassemble_ooo` 的四条件合成与 `fragment_reset_tot_len` 防截断(packet-tcp.c:4969,5393-5442)。
2. `conversation_element_t` 新式键 API 与旧 addr/port API 并存的迁移成本;anchor/deinterlacer/err_pkts 三张附属表的真实使用方(conversation.c:170-209)。
3. `postdissector` 机制:`register_postdissector` 如何在主分发尾部再跑一遍指定 dissector,以及 `prime_epan_dissect_with_postdissector_wanted_hfids` 的首遍预处理(packet.c:164-171,241,622-627)。
4. `register_depend_dissector` 依赖图如何反哺字段引用统计与协议禁用提示(add_for_decode_as 与 heur_dissector_add 尾部都会登记,packet.c:2419-2423,3037-3041)。
5. Lua(wslua_init,epan.c:405)与 asn2wrs/dcerpc 生成代码如何复用同一注册 API;pino 协议(`proto_register_protocol_in_name_only`)在 TCP 选项上的应用(packet-tcp.c:11326 起;proto.c:8671-8684)。

## 14. 正文蒸馏要点

1. 注册函数表由 `tools/make-regs.py` 构建期正则生成(`dissector_reg_proto`/`dissector_reg_handoff`,make-regs.py:44-46,60-71),运行期 `register_all_protocols` 只是顺序遍历调用(register.c:42-45,99-103)。
2. 完整启动序:tshark.c:1377-1380 → epan_init(epan.c:294)→ plugins_init(337)→ packet_init(380)→ proto_init(proto.c:624):先全员 proto 注册(656)再全员 handoff(673),插件插在两阶段之间(659-683);随后 packet_cache_proto_handles(epan.c:398)与 final_registration(401)。
3. `proto_register_protocol` 以三张名字哈希保证全名/短名/过滤名全局唯一并返回 proto_id(proto.c:8640-8652);`register_dissector` 重名即 ws_error 终止(packet.c:3615-3619)。
4. dissector table 共五类键型,uint 表哈希是 `g_direct_hash`——端口值即键(packet.c:2803-2806);槽位结构 `dtbl_entry{initial,current}` 是 Decode As 可逆性的全部基础(packet.c:1212-1215)。
5. `dissector_try_uint_with_data` = 一次哈希查 current + 保存/恢复 `pinfo->match_uint` + `call_dissector_work`(packet.c:1743-1797);查表失败/句柄为 NULL 返回 0,不自动兜底 data。
6. `call_dissector_work` 负责跨层簿记:协议开关检查(1002-1008)、can_desegment 递减(1028-1029)、layers 压栈与"零消费/零绘制"回滚(1053-1083)。
7. 启发式:头插注册(packet.c:3031)、命中冒泡(3180-3184)、失败回滚层(3156-3172);TCP 启发式表名 "tcp",`try_heuristic_first` 控制其先于端口表(packet-tcp.c:8507,8553)。
8. Decode As 持久化在 profile 文件 `decode_as_entries`(非 UAT,packet.c:80-83 注释有误),启动时 `load_decode_as_entries` 经 read_prefs_file 重放 dissector_change_uint/string(epan.c:442;decode_as.c:287-303)。
9. TCP 子协议选择是七级瀑布:conversation → 被改端口 → 启发式(可选)→ server → low → high → 启发式 → data(packet-tcp.c:8426-8573);server 端口来自 SYN/SYN-ACK 观测(8438-8449),低位端口优先是一致性策略(8516-8528)。
10. can_desegment=2 由 TCP 在数据完整且 tcp_desegment 开启时授予(packet-tcp.c:9849-9858),call_dissector_work/dissector_try_heuristic 每层递减(packet.c:1029,3111),desegment_tcp 是消费端(packet-tcp.c:5509-5518,5862)。
11. conversation 键是 CE_ADDRESS/CE_PORT/CE_TYPE 的 element 数组,查找先双向 exact 再逐级通配,反方向命中且 conv_index 更大者胜(conversation.c:1857-1922,1886-1908);键容器 epan 级、数据 file 级,dissector_tree 按 setup 帧号取句柄(conversation.c:589-620,2815)。
12. 插件加载:全局+用户两目录、版本校验、必须有 `plugin_register` 符号并即时调用(wsutil/plugins.c:187-247,256-283);本 tag 自带 14 个 epan 插件目录(plugins/epan/)。
