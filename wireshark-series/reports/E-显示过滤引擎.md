# 报告 E · 显示过滤引擎 dfilter(Wireshark)

> 基线:tag v4.7.3,commit f6e0bf224bdabf5f09b897da64fe6b10c66173d4
> 一句话总结:显示过滤是"编译一次、每包解释执行"的字节码 VM——flex 扫描 + lemon 归约出语法树,semcheck 做类型检查/常量转换,gencode 线性生成 49 种 DFVM 指令,运行期每包从 proto_tree 读出 fvalue 填入寄存器后单遍求值。

## 1. 两阶段结构图与编译管线全链

### 结构图

```text
【编译期:每条过滤器一次】                    【执行期:每个数据包一次】
"ip.src==10.0.0.1 && len(tcp.payload)>0"
        │ DF_EXPAND_MACROS?
        ▼
 dfilter_macro_apply  ←── 宏文本展开(深度≤23)     epan_dissect_run(edt)
        │                                              │ dissect → proto_tree
        ▼                                              ▼ (prime: 只记 interesting_fields)
 dfwork_parse (dfilter.c:398)                    dfilter_apply_edt(df, edt)
   ├─ scanner.l → df_yylex 逐 token               = dfvm_apply(df, edt->tree)
   └─ grammar.lemon → Dfilter() 归约                 │
        │  语法树 stnode_t (syntax-tree.c)           ▼
        ▼                                      dfvm_apply_full 主循环 (dfvm.c:1591)
 dfw_semcheck (semcheck.c:2264)                  for id in insns:
   ├─ 类型兼容/常量转 fvalue                        ├─ READ_TREE: 树→fvalue→寄存器
   ├─ 引用/raw/vals 标记                            ├─ ANY_EQ 等: fvalue 比较 → accum
   └─ ret_type                                     ├─ IF_FALSE_GOTO: 短路分支
        ▼                                          ├─ CALL_FUNCTION ← function_stack
 dfw_gencode (gencode.c:908)                       └─ RETURN: 清寄存器, 返回 accum
   ├─ gen_entity/gen_test 生成指令                  结果 = true(显示)/false(隐藏)
   ├─ optimize() 跳转合并(可选)
   └─ interesting_fields 登记表
        ▼
 dfilter_t{insns, 寄存器数, references, ...}  ──复用──▶ 执行期
```

### 编译管线

入口 `dfilter_compile_full`(epan/dfilter/dfilter.c:605):若带 `DF_EXPAND_MACROS` 位(dfilter.h:128)先做宏展开 `dfilter_macro_apply`(dfilter.c:631),否则原样 strdup(dfilter.c:638);随后进 `compile_filter`(dfilter.c:529)。常用接口是包装宏 `dfilter_compile`,固定注入 `DF_EXPAND_MACROS|DF_OPTIMIZE` 并以 `__func__` 作调用者标识(dfilter.h:160-163);六个编译标志从 SAVE_TREE 到 RETURN_VALUES(dfilter.h:126-137):

```c
// dfilter.h:126-137, 160-163
#define DF_SAVE_TREE        (1U << 0)  /* 保存语法树文本(调试) */
#define DF_EXPAND_MACROS    (1U << 1)  /* 对过滤文本做宏替换 */
#define DF_OPTIMIZE         (1U << 2)  /* 编译后做优化遍 */
#define DF_DEBUG_FLEX       (1U << 3)  /* flex 调试跟踪 */
#define DF_DEBUG_LEMON      (1U << 4)  /* lemon 调试跟踪 */
#define DF_RETURN_VALUES    (1U << 5)  /* 根为字段时返回值而非仅判存在 */
#define dfilter_compile(text, dfp, errp) \
    dfilter_compile_full(text, dfp, errp, \
                DF_EXPAND_MACROS|DF_OPTIMIZE, __func__)
```

阶段一 词法+语法:`dfwork_parse`(dfilter.c:398)初始化 flex 扫描器(`df_yylex_init`,dfilter.c:406)、把文本挂入缓冲(`df_yy_scan_string`,dfilter.c:411),循环 `df_yylex` 取 token 喂给 lemon 生成的 `Dfilter()`(dfilter.c:447);输入结束时再喂 0 令牌复位解析器状态(dfilter.c:457-463)。语法文件为 `epan/dfilter/grammar.lemon`(`%name Dfilter` 在 grammar.lemon:47;`%extra_argument {dfsyntax_t *dfs}` 在 :49;`%token_type {stnode_t*}` 在 :52)与 `epan/dfilter/scanner.l`(1178 行);构建由 CMake `add_lemon_files(LEMON_FILES ... grammar.lemon)` 与 flex 包装驱动,工具在 `tools/lemon`(epan/dfilter/CMakeLists.txt:63,66-67,93)。token 本身携带 stnode,归约动作直接拼语法树,如切片规则:

```c
// grammar.lemon:488-496
slice(R) ::= entity(E) LBRACKET range_node_list(L) RBRACKET.
{
    R = stnode_new(STTYPE_SLICE, NULL, NULL, DFILTER_LOC_EMPTY);
    sttype_slice_set(R, E, L);
    /* Delete the list, but not the drange_nodes ... */
    g_slist_free(L);
}
```

词法侧,比较/逻辑运算符全是"符号+单词"双拼法(`==`/`eq`/`any_eq` 同 token,scanner.l:180-189);`#` 触发专用 LAYER 开始态,其后必须跟数字或 `[`,否则扫描失败返回 `SCAN_FAILED`(scanner.l:224-233):

```c
// scanner.l:224-233
"#"     {
    BEGIN(LAYER);
    return simple(TOKEN_HASH);
}
<LAYER>[[:digit:]]+     {
    BEGIN(INITIAL);
    update_location(yyextra, yytext);
    return set_lval_simple(yyextra, TOKEN_INDEX, yytext, STTYPE_UNINITIALIZED);
}
<LAYER>[^[:digit:[]     { FAIL("Expected digit or \"[\"..."); return SCAN_FAILED; }
```

阶段二 语义检查:`dfwork_build`(dfilter.c:472)先打日志树,再调 `dfw_semcheck`(semcheck.c:2264)。该函数用 TRY/CATCH(TypeError) 包住递归分派 `semcheck`(semcheck.c:2227):按根节点类型走 `check_test/check_nonzero/check_exists`(semcheck.c:2239-2247);若整树没碰任何字段(`dfw->field_count==0`)判"Constant expression is invalid"(semcheck.c:2249-2252)。常量节点就地转 fvalue:

```c
// semcheck.c:344-373(节选)
void
dfilter_fvalue_from_number(dfwork_t *dfw, ftenum_t ftype, stnode_t *st)
{
    ...
    if (ftype == FT_SCALAR) {          /* 伪类型按词法落地 */
        switch (num_type) {
            case STNUM_INTEGER:
            case STNUM_UNSIGNED:  ftype = FT_INT64;  break;
            case STNUM_FLOAT:     ftype = FT_DOUBLE; break;
        ...
        }
    }
    /* 再按字段 ftenum 调 fvalue_from_sinteger64/uinteger64/floating */
```

阶段三 生成字节码:`dfw_gencode`(gencode.c:908-921)先造 `DFVM_RETURN` 骨架,再递归 `gencode(dfw, st_root)`(gencode.c:820-851)填指令体;`DF_OPTIMIZE` 时跑 `optimize()`(gencode.c:918-920)做跳转改写。

阶段四 装配:把 insns、interesting_fields、references/raw_references、expanded_text 搬进 `dfilter_t`,按 `dfw->next_register` 分配寄存器组 `g_new0(df_cell_t, num_registers)`(dfilter.c:493-524),返回类型 `ret_type` 来自 semcheck(dfilter.c:509;semcheck.c:2285)。**空过滤器编译成功且返回 NULL dfilter_t**——UI 清空过滤栏即"显示全部帧"(dfilter.c:546-554)。全局侧,`dfilter_init` 只创建一次 lemon 解析器单例 `DfilterAlloc`(dfilter.c:113)并初始化 sttype/函数/宏/插件四个子系统(dfilter.c:116-120)。

## 2. DFVM:49 个 opcode 与"寄存器=多值列表"的执行模型

opcode 枚举共 **49 个**,`DFVM_NULL` 到 `DFVM_NO_OP`(dfvm.h:77-127),分组:分支 4(IF_TRUE_GOTO/IF_FALSE_GOTO/RETURN/NOT)、读 6(CHECK_EXISTS(_R)/READ_TREE(_R)/READ_REFERENCE(_R))、装载 1(PUT_FVALUE)、谓词 16(ALL/ANY × EQ/NE/GT/GE/LT/LE/CONTAINS/MATCHES)、集合 7(SET_ALL/ANY_(NOT_)IN + SET_ADD/SET_ADD_RANGE/SET_CLEAR)、算术 9(SLICE/LENGTH/BITWISE_AND/UNARY_MINUS/ADD/SUBTRACT/MULTIPLY/DIVIDE/MODULO)、调用 3(CALL_FUNCTION/STACK_PUSH/STACK_POP)、其他 3(NOT_ALL_ZERO/NO_OP/NULL)。指令是三元组 `dfvm_insn_t{id, op, arg1..3}`(dfvm.h:141-147);参数 `dfvm_value_t` 为引用计数的 tagged union,11 种类型:EMPTY/FVALUE/HFINFO/RAW_HFINFO/HFINFO_VS/INSN_NUMBER/REGISTER/INTEGER/DRANGE/FUNCTION_DEF/PCRE(dfvm.h:30-42)。

**纠偏提示:本版没有 PEER 指令**(对 epan/dfilter 全目录大小写不敏感 grep,仅命中 `TypeError` 的字母巧合);同名多字段靠 `hfinfo->same_name_next` 链遍历(dfvm.c:956-959),层选择走 `field#[层]` 语法派生的 `*_R` 指令(grammar.lemon:187-193)。

主循环 `dfvm_apply_full`(dfvm.c:1590-1822):`for(id=0; id<length; id++)` 顺序扫描,`switch(insn->op)`(dfvm.c:1612)分派;全局状态只有布尔累加器 `accum`、寄存器组和两个栈。分支指令改 `id` 后 `goto AGAIN`(dfvm.c:1802-1814);`DFVM_RETURN` 把可选结果寄存器引用给调用方(`DF_RETURN_VALUES` 场景)、清理全部寄存器并返回 accum(dfvm.c:1789-1797)。

```c
// dfvm.c:1047-1068(节选,ALL/ANY 共用的双循环)
static bool
cmp_test_internal(enum match_how how, DFVMCompareFunc match_func,
            GPtrArray *fv1, GPtrArray *fv2)
{
    bool want_all = (how == MATCH_ALL);
    ...
    for (size_t idx1 = 0; idx1 < fv1->len; idx1++)
      for (size_t idx2 = 0; idx2 < fv2->len; idx2++) {
        have_match = match_func(fv1->pdata[idx1], fv2->pdata[idx2]);
        if (want_all && have_match == FT_FALSE) return false;
        else if (want_any && have_match == FT_TRUE) return true;
      }
    return want_all;    /* 空集:ALL 为真,ANY 为假 */
}
```

寄存器 `df_cell_t` 本体就是一个 `GPtrArray`(dfilter-int.h:31-33),装"该字段在本包的所有出现值"。`any_test/all_test`(dfvm.c:1115-1129)向其注入 `fvalue_eq/gt/...` 函数指针;算术 `mk_binary` 对两寄存器做笛卡尔积(dfvm.c:1377-1395);`call_function` 从 `df->function_stack` 取参、向返回寄存器写结果(dfvm.c:1318-1337);`stack_push/stack_pop` 管理函数参数栈(dfvm.c:1481-1511);集合 `set_push/any_in/all_in` 操作 `set_stack`(dfvm.c:1513-1553,1202-1258)。寄存器分"只引用/拥有所有权"两种初始化(dfvm.c:948-954),RETURN 时统一 `df_cell_clear`(dfvm.c:1262-1268)。gencode 侧 `select_opcode` 用"ALL/ANY 枚举值相邻,op±1"的技巧换挡(gencode.c:31-64)。

## 3. ftypes 协作、drange 与 slice 的完整路径

ftypes 层提供值对象 fvalue_t 与每类型一张方法表。`enum ftenum` 实际类型 **46 个**(FT_NONE…FT_STRINGZTRUNC,后随哨兵 FT_NUM_TYPES),另有算术专用伪类型 FT_SCALAR(epan/ftypes/ftypes.h:26-76);实现分散在 12 个 ftype-*.c:bytes/double/guid/ieee-11073-float/integer/ipv4/ipv6/none/protocol/string/time。方法表 `struct _ftype_t`(ftypes-int.h:126-216)成员:val_from_literal/string/charconst/uinteger64/sinteger64/double 六个入转换,val_to_uinteger64/sinteger64/double 三个出转换,`compare`(order 比较返回 ft_result 三态)、contains/matches/hash、is_zero/is_negative/is_nan、len、slice,以及 bitwise_and/unary_minus/add/subtract/multiply/divide/modulo 算术回调——**没有旧版的 `how_is_equal`/`convert` 成员**(纠偏,见第 6 节)。全部相等/大小判断由此派生:

```c
// epan/ftypes/ftypes.c:1290-1301
ft_bool_t
fvalue_eq(const fvalue_t *a, const fvalue_t *b)
{
    int cmp;
    enum ft_result res;

    ws_assert(a->ftype->compare);
    res = a->ftype->compare(a, b, &cmp);
    if (res != FT_OK)
        return -res;                 /* 类型错误折成负三态 */
    return cmp == 0 ? FT_TRUE : FT_FALSE;
}
```

`ip.src[0:4]` 的完整路径:① 语法——`slice ::= entity LBRACKET range_node_list RBRACKET`(grammar.lemon:488),每个 `RANGE_NODE` 经 `drange_node_from_str` 解析;drange 注释列明五种形式 `[i:j]`(偏移:长度)、`[i-j]`(闭区间)、`[i]`、`[:j]`、`[i:]`(epan/dfilter/drange.c:56-62)。② 语义——`check_slice` 检查实体 `ftype_can_slice`,失败报"cannot be sliced into a sequence of bytes"(semcheck.c:1707 起,1719-1729)。③ 生成——`dfw_append_mk_slice` 从 stnode 偷出 drange 塞进 `DFVM_SLICE` arg3(gencode.c:264-284)。④ 执行——`mk_slice` 遍历寄存器逐值 `fvalue_slice`(dfvm.c:1273-1296),后者字符串走 `slice_string`、其余走 `slice_bytes`(用 `drange_foreach_drange_node` 抄字节进新 FT_BYTES,ftypes.c:927-933 及 slice_bytes 实现处)。此外层范围语法 `field#[N]` 在归约时构造 drange 挂到字段节点上(grammar.lemon:187-210),运行期由 `drange_contains_layer` 按 `proto_layer_num` 过滤,负偏移按"倒数第 N 层"换算(dfvm.c:752-785)。

多值集合 `tcp.port in {80,443,1..5}` 不占寄存器:gencode 的 `gen_relation_in` 逐元素发 `SET_ADD`(区间发 `SET_ADD_RANGE`)压入 set_stack,然后一条 `SET_ANY_IN/SET_ALL_IN/SET_*_NOT_IN` 判定成员(区间用 `fvalue_le/fvalue_ge` 夹逼,dfvm.c:1163-1200),最后 `SET_CLEAR` 清栈(gencode.c:456-509)。

## 4. 运行期:每包调用点、prime 机制与"值从树来"

`dfilter_apply_edt(df, edt)` 即 `dfvm_apply(df, edt->tree)`(dfilter.c:699-703)。**求值对象是 proto_tree:常规字段从树的 `field_info->value` 取已解码 fvalue**(dfvm.c:905-912),不是原始字节;两种例外:`@field` raw 语法(RAW_HFINFO)经 `dfvm_get_raw_fvalue` 从 `fi->ds_tvb` 抄原始字节构造 FT_BYTES(dfvm.c:787-816),`vals()` 语义经 `proto_item_fill_display_label` 现场生成 FT_STRING(dfvm.c:818-828)。每包调用点:tshark 读过滤 `cf->rfcode` 在 dissect 后先执行(tshark.c:3543-3570),显示过滤 `cf->dfcode` 在 tshark.c:3587(依赖帧判断)、3822 与 4576(双遍模式);其余:着色规则 epan/color_filters.c:605,632、tap epan/tap.c:372,382、自定义列 epan/proto.c:7920、打印 epan/print.c:3017、字段提取 proto.c:7683。

```c
// dfvm.c:922-962(节选,读树 + 本包缓存 + 同名链)
static bool
read_tree(dfilter_t *df, proto_tree *tree, dfvm_value_t *arg1,
        dfvm_value_t *arg2, dfvm_value_t *arg3)
{
    header_field_info *hfinfo = arg1->value.hfinfo;
    raw = arg1->type == RAW_HFINFO;
    val_str = arg1->type == HFINFO_VS;
    int reg = arg2->value.numeric;
    rp = &df->registers[reg];
    /* Already loaded in this run of the dfilter? */
    if (!df_cell_is_null(rp))
        return !df_cell_is_empty(rp);      /* 缓存命中 */
    ...
    while (hfinfo) {
        read_tree_finfos(rp, tree, hfinfo, range, raw, val_str);
        hfinfo = hfinfo->same_name_next;   /* 同名多字段链 */
    }
    return !df_cell_is_empty(rp);
}
```

性能支点是 **prime 机制**:编译期把引用到的字段登记进 `interesting_fields` 哈希(gencode.c:204-210,256-258,656-660),`epan_dissect_prime_with_dfilter`(epan.c:846-851)→ `dfilter_prime_proto_tree`(dfilter.c:711-719)逐个 `proto_tree_prime_with_hfid`,告知 dissector 本包只需记录这些字段,从而树可只含过滤所需项(epan.h:680-694 的接口注释;tshark 实际调用 tshark.c:3546-3549、3774-3776)。

```c
// dfilter.c:857-892(节选,引用快照的加载:值从树里现拷)
static void
load_references(GHashTable *table, proto_tree *tree, bool raw)
{
    ...
    g_hash_table_iter_init(&iter, table);
    while (g_hash_table_iter_next(&iter, (void **)&hfinfo, (void **)&refs)) {
        g_ptr_array_set_size(refs, 0);
        while (hfinfo) {
            finfos = proto_find_finfo(tree, hfinfo->id);
            if (finfos == NULL) {
                hfinfo = hfinfo->same_name_next;
                continue;
            }
            for (unsigned i = 0; i < finfos->len; i++) {
                finfo = g_ptr_array_index(finfos, i);
                g_ptr_array_add(refs, reference_new(finfo, raw));
            }
            ...
            hfinfo = hfinfo->same_name_next;
        }
        g_ptr_array_sort(refs, compare_ref_layer);
    }
}
````${ref}` 引用走另一条快照路:`dfilter_load_field_references` 在 dissect 后一次性把每个引用字段的值(raw 版走 tvb)复制进 `df->references/raw_references`,按 `proto_layer_num` 排序(dfilter.c:857-920);执行期 `READ_REFERENCE(_R)` 只读快照、绝不回查树(dfvm.c:1004-1038),这就是着色规则与 GUI 字段引用能跨阶段稳定取值的原因。

## 5. 宏、函数与插件:名字到指令的两条路

宏是**编译前纯文本替换**:`dfilter_compile_full` 先 `dfilter_macro_apply`(dfilter.c:630-640;入口 dfilter-macro.c:651-657),`dfilter_macro_apply_recurse` 以状态机扫描 `$name(args)`,嵌套深度上限 23("too much nesting in macros",dfilter-macro.c:约566-570),宏定义由 UAT 配置文件管理(epan/dfilter/dfilter-macro-uat.c,220 行;`macro_parse` 预切分 `$N` 占位,dfilter-macro.c:661 起)。函数则编译期查表:归约 `function ::= IDENTIFIER ( params )` 时 `df_func_lookup`(grammar.lemon:516-533),内置表 13 项——lower/upper/len/count/string/float/double/dec/hex/vals/max/min/abs(dfunctions.c:670-689)。

```c
// dfunctions.c:670-689(节选)
static df_func_def_t
df_functions[] = {
    { "lower",  df_func_lower,  1, 1, FT_STRING, ul_semcheck_is_string },
    { "upper",  df_func_upper,  1, 1, FT_STRING, ul_semcheck_is_string },
    /* Length function is implemented as a DFVM instruction. */
    { "len",    NULL,           1, 1, FT_UINT32, ul_semcheck_can_length },
    { "count",  df_func_count,  1, 1, FT_UINT32, ul_semcheck_is_field },
    ...
    /* VALUE STRING function is implemented as a DFVM instruction. */
    { "vals",   NULL,           1, 1, FT_STRING, ul_semcheck_value_string },
```

`len`/`vals` 的 func 指针为 NULL:gencode 特判,`len()` 直接降级为 `DFVM_LENGTH` 指令(gencode.c:353-356;执行时 `fvalue_length2` 产出 FT_UINT32,dfvm.c:1298-1316),`vals()` 退化为对字段节点读 value-string(gencode.c:358-363)。其余函数生成 `CALL_FUNCTION`:参数逐个 `gen_entity` 后 `STACK_PUSH`,末尾记参数个数、`STACK_POP n` 并补一条失败跳转(gencode.c:365-401);运行期 `call_function` 执行 `funcdef->function(df->function_stack, arg_count, rp_return)`(dfvm.c:1318-1337),如 `df_func_upper` 即 `string_walk(stack, arg_count, retval, g_ascii_toupper)`(dfunctions.c:648-652)。第三方可 `df_func_register` 动态注册(dfunctions.c:719-741),dfilter 插件统一在 `dfilter_init` 里逐个 `plug->init()`(dfilter-plugin.c:33-39;挂载点 dfilter.c:120)。

## 6. 纠偏(以本 tag 源码为准)

1. **不存在 PEER 指令**:dfvm.h:77-127 全部 49 个 opcode 中无 PEER(grep "peer" 仅命中 `TypeError` 的大小写巧合);同名多值由 `same_name_next` 链 + 层范围 `#` 语法(`READ_TREE_R` 等)承担(dfvm.c:956-959;grammar.lemon:187)。
2. **ftype_t 没有 `how_is_equal`/`convert` 回调**:3.x 旧结构;4.x 重构后为 `compare`(order + ft_result 三态,ftypes-int.h:186 附近)派生全部比较(fvalue_eq,ftypes.c:1290),转换是 `val_to_uinteger64/sinteger64/double` 与 `val_from_*` 族(ftypes-int.h:53-64,160-166)。
3. **显示过滤不是在原始字节上求值**:常规字段读树中已解码的 `finfo->value`(dfvm.c:911);只有 `@field` raw 引用与 raw_references 走 tvb 原始字节(dfvm.c:787-816;dfilter.c:894-899)。
4. **`len()`/`vals()` 不是运行期函数调用**:编译期特判为 `DFVM_LENGTH` 指令/字段 val_str 读取(gencode.c:353-363;dfunctions.c:675,684),不产生 CALL_FUNCTION。
5. **`==` 是 ANY_EQ、`!=` 是 ALL_NE、`===` 才是 ALL_EQ、`!==` 是 ANY_NE**(scanner.l:180-189):双符号默认"任一匹配"语义,三符号才是全称量词。
6. **优化非必开且很弱**:`optimize()` 仅在 `DF_OPTIMIZE`(dfilter.h:130)时运行,只做三种跳转改写——跳到下条则变 NO_OP、跳到反向跳转则剪枝、连续同目标跳转合并,外加同寄存器 READ_TREE 特判(gencode.c:866-902);无常量折叠与死码清除。

## 7. 设计动机

1. **编译一次、每包解释**:字符串只在编译期解析一次,每包成本降为"读树 + 寄存器运算",支撑百万包流水的实时过滤。
2. **寄存器=多值单元格**:一个字段的所有出现值进一个 GPtrArray 寄存器,ALL/ANY 量词内建于指令选择而非运行期展开,语义单一实现(dfvm.c:1047-1067)。
3. **读树缓存与寄存器复用**:执行期 `df_cell_is_null` 判已加载避免重复读树(dfvm.c:943-946);编译期 `loaded_fields` 哈希让同字段复用寄存器(gencode.c:161-187)。
4. **prime 协议**:把"过滤需要哪些字段"反向喂给 dissector,"仅过滤"场景免建全树,是 GUI/tshark 的性能支点(dfilter.c:711-719;epan.c:846-851)。
5. **三态比较 + 类型方法表**:新 ftype 只需填 ftype_t 方法表即自动参与全部 49 指令,引擎与类型系统解耦(ftypes-int.h:126-216)。
6. **引用快照(`${}`)**:着色/引用在树存活时预取并按层排序,执行期零树查询(dfilter.c:857-920;dfvm.c:1004-1038)。
7. **异常式 semcheck**:深层递归类型检查 THROW(TypeError) 一步跳出(semcheck.c:2274-2281),免除层层错误码 plumbing。
8. **Lemon 解析器单例**:`DfilterAlloc` 全局一次(dfilter.c:113),编译末喂 0 复位(dfilter.c:463),高频重编译零分配。

## 8. FAQ 候选与深挖方向

1. 过滤器何时从字符串变成可执行物?——`dfilter_compile_full` 一次产出指令数组,此后每包只跑 `dfvm_apply`(dfilter.c:605;dfvm.c:1591)。
2. 每包执行的总状态是什么?——布尔累加器 accum + 寄存器组 + function/set 两栈,RETURN 统一清理(dfvm.c:1591-1797)。
3. `ip.src[0:4]` 与 `ip.src#[0]` 的区别?——前者字节切片(DFVM_SLICE),后者按协议层选第 N 层(READ_TREE_R;grammar.lemon:187,488)。
4. 字段值从哪来?——proto_tree 的 finfo->value;`@raw` 与 vals 变体才转原始字节/显示标签(dfvm.c:905-928)。
5. 过滤为何快?——prime 让树只含 interesting_fields 字段(dfilter.c:711-719;epan.c:846-851)。
6. `==` 与 `===` 的语义差别?——ANY_EQ 任一对相等即真,ALL_EQ 要求全部相等(dfvm.h:90-91;scanner.l:180-189)。
7. `${ip.src}` 引用特殊在哪?——读编译期登记、按层排序的值快照,执行期不查树(dfilter.c:894-905;dfvm.c:1004-1038)。
8. 宏在哪一步展开、能嵌套多深?——编译前文本递归替换,深度上限 23(dfilter.c:631;dfilter-macro.c:566 附近)。
9. 未知字段名在哪个阶段报错?——语法归约时 `resolve_unparsed` 查 `proto_registrar_get_byname/alias`(grammar.lemon:31-40;dfilter.c:80-101)。
10. 空过滤器算错误吗?——不算,编译成功返回 NULL dfilter_t,语义为显示全部帧(dfilter.c:546-554)。

### 深挖方向

1. `optimize()` 三种跳转改写与 NO_OP 填充对 tshark `-Y` 吞吐的实测收益(gencode.c:855-905)。
2. 层范围 `#` 语法的 `proto_layer_num` 分配规则与 `drange_contains_layer` 负偏移换算(dfvm.c:752-785)。
3. `fvalue_eq` 错误路径(返回 `-res`)在 ALL/ANY 双循环中的短路传播与最终真值(dfvm.c:1055-1067;ftypes.c:1290-1301)。
4. `DF_SAVE_TREE` 语法树字符串与 `dfilter_get_syntax_tree` 在 GUI 过滤器诊断/AI 类工具中的复用(dfilter.c:488-520,655-691)。
5. dfilter-translator.c(332 行)把显示过滤翻译为捕获过滤(BPF)的能力边界与回退策略。

## 9. 正文蒸馏要点

1. 编译四级流水:`dfilter_compile_full`(dfilter.c:605)→ `dfwork_parse` flex+lemon(dfilter.c:398,447)→ `dfw_semcheck`(semcheck.c:2264)→ `dfw_gencode`(gencode.c:908)→ `dfwork_build` 装配(dfilter.c:472-527)。
2. 语法输入是 `grammar.lemon`(`%name Dfilter`,grammar.lemon:47)与 `scanner.l`,构建由 CMake 调 `tools/lemon`(epan/dfilter/CMakeLists.txt:66-67,93),非手写递归下降。
3. DFVM 共 49 个 opcode(dfvm.h:77-127),指令为三元 dfvm_insn_t(dfvm.h:141-147),参数是 11 种 tagged union(dfvm.h:30-42);本版无 PEER 指令。
4. 执行主循环单遍 + accum + goto 分支(dfvm.c:1604-1818);`dfw_gencode` 保证末尾必有 RETURN(gencode.c:915-917)。
5. 寄存器即"字段全部出现值"的 GPtrArray 单元(dfilter-int.h:31-33);`==` 编译为 ANY_EQ、`===` 为 ALL_EQ(scanner.l:180-189;dfvm.c:1115-1129)。
6. 字段值来自 proto_tree 的 finfo->value;仅 `@` raw 引用走 tvb 原始字节(dfvm.c:905-916,787-816)。
7. prime 机制:interesting_fields → `proto_tree_prime_with_hfid`,实现"仅过滤"的瘦身树(dfilter.c:711-719;epan.c:846-851;tshark.c:3774)。
8. 每包调用点:tshark.c:3587/3822/4576,着色 color_filters.c:605,tap tap.c:372,自定义列 proto.c:7920,打印 print.c:3017。
9. ftenum 共 46 个实际类型 + FT_SCALAR 伪类型(ftypes.h:26-76);全部相等判断由 `compare` 三态回调派生(ftypes.c:1290-1301),已无 how_is_equal/convert。
10. slice 路径:语法 grammar.lemon:488 → `drange_node_from_str` 五种形式(drange.c:56-62)→ `check_slice`(semcheck.c:1707)→ DFVM_SLICE(gencode.c:264)→ `fvalue_slice` 分流 string/bytes(dfvm.c:1273;ftypes.c:927)。
11. 集合 `in {a,b,c..d}` 生成 SET_ADD(_RANGE) 压 set_stack、SET_*_IN 判定、SET_CLEAR 清栈(gencode.c:456-509;dfvm.c:1202-1258)。
12. 内置 13 函数中 len/vals 编译期降级为专用指令/读取(gencode.c:353-363;dfunctions.c:675,684),其余走 CALL_FUNCTION+参数栈(gencode.c:365-401);宏为编译前文本替换,嵌套限 23 层(dfilter-macro.c:566 附近)。
