# Q 章 · libavutil 工具箱:FFmpeg 的"地基货架"

> 调研对象:FFmpeg master(commit 9f63b36a)。所有行号均在 grep -n / Read 在该提交上核对。
> 本章盘点 libavutil 中教学价值最高的基础工具:AVOption 配置系统、像素格式描述符、
> 表达式引擎、日志系统、声道布局现代化,以及七个"小件"。

---

## 1. 全景:libavutil 的三层结构

```
┌────────────────────────────────────────────────────────────────┐
│ 编码层(多媒体语义):"懂音视频"                                │
│  pixdesc.c 像素格式自描述表(§3) │ channel_layout.c 声道布局(§6)│
│  rational.c AVRational(§7) │ csp.c/samplefmt.c 色彩与采样格式   │
├────────────────────────────────────────────────────────────────┤
│ 配置层(对象协议):"让 C 结构体可被字符串驱动"                 │
│  opt.c AVOption 反射式配置(§2,最厚) │ dict.c 键值容器(§7)     │
│  eval.c 表达式引擎(§4) │ log.c AVClass+av_log 协议(§5)        │
├────────────────────────────────────────────────────────────────┤
│ 系统层(纯基础设施):"只懂字节"                                │
│  mem.c 对齐分配 │ error.c 错误码 │ bprint.c 增长字符串          │
│  fifo.c 泛型队列 │ tree.c AVL 树 │ buffer.c 引用计数            │
└────────────────────────────────────────────────────────────────┘
```

关键观察:**AVClass(log.h:76)是贯穿三层的协议头**——任何想被配置
(log.h:96 的 `option` 表)、被日志识别(log.h:113/124)、被树状遍历
(log.h:150/167)的结构体,第一个成员都是 `AVClass *`。这是全库"伪反射"的锚点。

---

## 2. AVOption 专节:全库配置骨架

### 2.1 一切从 AVClass 开始

`AVOption`(opt.h:428-478)字段极简:`name`(opt.h:429)、`help`(opt.h:435)、
`offset`(opt.h:443,选项值在结构体内的字节偏移)、`type`(opt.h:444)、
`min/max`(opt.h:465-466)、`unit`(opt.h:478)。**offset 是灵魂**:选项表只是
"名字 → 结构体偏移"的映射,av_opt_set 最终就是往 `dst + offset` 写内存。

类型共 20 种(opt.h:254-334):FLAGS/INT/INT64/UINT/UINT64/DOUBLE/FLOAT/STRING/
RATIONAL/BINARY/DICT/IMAGE_SIZE/VIDEO_RATE/PIXEL_FMT/SAMPLE_FMT/DURATION/COLOR/
BOOL/CHLAYOUT/CONST,外加数组修饰位 `AV_OPT_TYPE_FLAG_ARRAY`(opt.h:345)。
opt.c:60-83 的 `opt_type_desc[]` 登记**每种类型的 C 字节宽度和打印名**:

```c
// libavutil/opt.c:60-83(节选)
static const struct {
    size_t      size;
    const char *name;
} opt_type_desc[] = {
    [AV_OPT_TYPE_INT]        = { sizeof(int),            "<int>" },
    [AV_OPT_TYPE_STRING]     = { sizeof(char *),         "<string>" },
    [AV_OPT_TYPE_BINARY]     = { sizeof(uint8_t *),      "<binary>" },
    [AV_OPT_TYPE_PIXEL_FMT]  = { sizeof(enum AVPixelFormat), "<pix_fmt>" },
    [AV_OPT_TYPE_CHLAYOUT]   = { sizeof(AVChannelLayout),"<channel_layout>" },
    /* ...共 19 项... */
};
```

数组选项经 `TYPE_BASE(type)` 宏(opt.c:45,剥掉 FLAG_ARRAY 位)复用同一张表。

### 2.2 av_opt_set 的完整路径

`av_opt_set`(opt.c:889-901)只分两步:

1. `opt_set_init`(opt.c:165-224):调 `av_opt_find2` 找选项和 **target_obj**
   (值真正所在对象,可能是子对象,opt.c:173);查 READONLY(opt.c:177)、
   运行时限制(opt.c:190-211,非 RUNTIME_PARAM 选项在对象初始化后禁止再改)、
   打 deprecation 警告(opt.c:213-214),算出 `dst = tgt + o->offset`(opt.c:221)。
2. 按数组与否分发 `opt_set_array` / `opt_set_elem`(opt.c:899-900)。

`opt_set_elem`(opt.c:727)内是巨大 switch(opt.c:731-803),按类型分派:
`set_string_number`(opt.c:426)、`set_string_image_size`(opt.c:521)、
`set_string_video_rate`(opt.c:542)、`set_string_color`(opt.c:554)、
`set_string_bool`(opt.c:580)、`set_string_fmt`(opt.c:613,像素/采样格式共用,
opt.c:665/677 是薄封装)、`set_string_dict`(opt.c:684)、
`set_string_channel_layout`(opt.c:707)、`set_string_binary`(opt.c:364,
十六进制转字节);DURATION 直接 `av_parse_time` 转微秒(opt.c:770-787)。

### 2.3 数字选项:字符串→二进制的三层兜底

`set_string_number`(opt.c:426-519)最有讲头:

- 有理数快捷方式:`"30000/1001"` 用 sscanf 直解(opt.c:432-440);
- **命名常量**:先查同名 `AV_OPT_TYPE_CONST` 项(opt.c:463-468);查不到就把
  当前 unit 下全部 CONST 项 + default/max/min/none/all 注入常量表
  (opt.c:470-495);
- **兜底调表达式引擎** `av_expr_parse_and_eval`(opt.c:497-498)——
  `-vf scale=w=iw/2` 能吃进去,根子在此。

FLAGS 支持 `+`(或上)/`-`(清掉)前缀增量语法(opt.c:449-455、505-511)。
最后 `write_number`(opt.c:275-295)做范围检查(opt.c:280-286)并按类型写内存。

### 2.4 对象树:child_next / child_class_iterate

AVCodecContext 内嵌私有编解码器上下文、AVFormatContext 内嵌 mux/demux 私有
上下文、滤镜内嵌硬件设备——都是"父 + 子"的树。AVClass 用两个函数指针描述
(log.h:150/167):`child_next(obj, prev)` 遍历**实际存在的**子对象实例;
`child_class_iterate(iter)` 遍历**类可能拥有的**子类(对象不存在也能枚举,
供 CLI `-h full` 列全量配置)。opt.h:177-183 注释明确二者差异:AVCodecContext
的 child_next 返回 priv_data(真实实例),child_class_iterate 返回编解码器私有
AVClass(与实例无关)。

查找入口 `av_opt_find2`(opt.c:2075-2118):带 `AV_OPT_SEARCH_CHILDREN`
(opt.h:604)时先递归子对象(opt.c:2089-2102,FAKE_OBJ 走类迭代分支,
opt.h:612),再线性扫本层选项表(opt.c:2104-2116);两个 wrapper 在
opt.c:2120-2133。递归 + 偏移寻址 = "一条 `-b:v 2M` 穿透三层结构体"的全部秘密。

### 2.5 批量入口与字符串协议

- `av_opt_set_dict2`(opt.c:2040-2062):逐 key 调 av_opt_set,**未匹配项不丢弃
  而是存回 dict**(opt.c:2051-2052、2059-2060)——"dict 消费剩余项下传"语义的出处;
- `av_opt_set_from_string`(opt.c:1975-2025):解析 `k=v:k2=v2`,支持**位置速记**
  (无 key 时按 shorthand 顺序隐式命名,opt.c:2003-2009)——`scale=1280:720`
  靠它把 1280 依序配给 w、h;
- `av_opt_set_defaults2`(opt.c:1762 起):把 default_val 写入结构体,数组选项按
  分隔符拆串重放(opt.c:1778-1784);wrapper 在 opt.c:1756;
- `av_opt_free`(opt.c:2027-2038)与 `opt_free_elem`(opt.c:127-146):只回收
  STRING/BINARY/DICT/CHLAYOUT 四类含堆内存的选项;
- 数组 API:`av_opt_get_array_size`(opt.c:2243)、`av_opt_get_array`(opt.c:2261)、
  `av_opt_set_array`(opt.c:2349);查询/序列化:`av_opt_query_ranges`
  (opt.c:2536)、`av_opt_is_set_to_default`(opt.c:2645)、
  `av_opt_serialize`(opt.c:2838);强类型 setter 见 `av_opt_set_int`
  (opt.c:936,经 `set_number` opt.c:920)与 `OPT_EVAL_NUMBER` 宏(opt.c:903-918)。

---

## 3. pixdesc 专节:让像素格式"自解释"

### 3.1 描述符与描述符表

`AVComponentDescriptor`(pixdesc.h:30-58)五元组:`plane`(pixdesc.h:34)、
`step`(pixdesc.h:40,相邻像素间距,bitstream 格式单位是 bit)、`offset`
(pixdesc.h:46,首像素内偏移)、`shift`(pixdesc.h:52,右移位数)、`depth`
(pixdesc.h:57)。`AVPixFmtDescriptor`(pixdesc.h:69-105)再补 `nb_components`
(pixdesc.h:71)、`log2_chroma_w/h`(pixdesc.h:80/89,色度下采样指数)、
`flags`(pixdesc.h:94)、`comp[4]`(pixdesc.h:105)。旗标 11 位
(pixdesc.h:116-163):BE(116)、PAL(120)、BITSTREAM(124)、HWACCEL(128)、
PLANAR(132)、RGB(136)、ALPHA(147)、BAYER(152)、FLOAT(158)、XYZ(163)。

全库唯一一张表 `av_pix_fmt_descriptors[AV_PIX_FMT_NB]`(pixdesc.c:203),以枚举值
为下标静态初始化——**格式自解释,零 switch-case**。三个样例:

```c
// libavutil/pixdesc.c:204-215  yuv420p:全平面 4:2:0
[AV_PIX_FMT_YUV420P] = {
    .name = "yuv420p", .nb_components = 3,
    .log2_chroma_w = 1, .log2_chroma_h = 1,      // 宽高各减半
    .comp = {
        { 0, 1, 0, 0, 8 },   /* Y: 平面0, 步长1字节, 8bit */
        { 1, 1, 0, 0, 8 },   /* U: 平面1 */
        { 2, 1, 0, 0, 8 },   /* V: 平面2 */
    },
    .flags = AV_PIX_FMT_FLAG_PLANAR,
},
```

- **yuv420p**(pixdesc.c:204-215):三平面,Y 全分辨率,U/V 宽高各乘 1/2;
- **nv12**(pixdesc.c:567-578):Y 在平面 0,U/V **同在平面 1 交错**——
  U=`{1,2,0,0,8}`(步长 2 字节、偏移 0),V=`{1,2,1,0,8}`(偏移 1 字节);
  NV21(pixdesc.c:579-590)仅 U/V 两行互换。"半平面"格式的表中形态;
- **rgb565le**(pixdesc.c:1228-1239):单平面 2 字节装 3 分量——
  R=`{0,2,1,3,5}`(字节 1、右移 3、5 位),G=`{0,2,0,5,6}`(偏移 0、右移 5、
  6 位),B=`{0,2,0,0,5}`(右移 0、5 位),带 FLAG_RGB(pixdesc.c:1238)。
  LE 布局被 offset/shift 精确编码。

### 3.2 描述符的消费者

- 访问:`av_pix_fmt_desc_get`(pixdesc.c:3460-3465)、`av_pix_fmt_desc_next`
  (pixdesc.c:3467)、`av_pix_fmt_desc_get_id`(pixdesc.c:3479);
- 度量:`av_get_bits_per_pixel`(pixdesc.c:3412-3423,depth 按下采样折算)、
  `av_get_padded_bits_per_pixel`(pixdesc.c:3425-3443,按 step 含 padding);
- 工具:`av_pix_fmt_get_chroma_sub_sample`(pixdesc.c:3488)、
  `av_pix_fmt_count_planes`(pixdesc.c:3500);协商:`get_color_type`
  (pixdesc.c:3544)、`av_get_pix_fmt_loss`(pixdesc.c:3728);
- 名字↔枚举:`av_get_pix_fmt_name`(pixdesc.c:3380)、`av_get_pix_fmt`
  (pixdesc.c:3392,按 name/alias 匹配,opt.c:3372-3374 附近)——AVOption 的
  PIXEL_FMT 字符串转换直接复用此表。

一句话:**swscale/滤镜链能处理几百种格式,是因为格式知识被压缩成 3942 行静态表,
代码只认描述符不认具体格式。**

---

## 4. eval 专节:滤镜几何/时间参数的表达式引擎

### 4.1 词法与"数字增强"

eval.c 全文 855 行。入口 `av_strtod`(eval.c:110-147)先于标准 strtod:支持
`0x`(eval.c:114-117)、`dB` 转线性(eval.c:120-123)、SI 词头 k/M/G… 与二进制
Ki/Mi(eval.c:124-135,前缀表 si_prefixes eval.c:73-98)、`B` 乘 8 转 bit
(eval.c:137-139)。词法辅助 `strmatch`(eval.c:151-159):前缀匹配且后续不是
标识符字符。

### 4.2 递归下降解析:优先级即调用栈

AST 节点 `AVExpr`(eval.c:171-183):type + value(兼作符号)+ 函数指针 +
`param[3]`。优先级从低到高排成调用链,每层处理一种运算符:

```
parse_expr   (eval.c:664)    ';'  序列        → e_last(另有 stack_index 防爆栈 :668-670)
parse_subexpr(eval.c:640)    '+' '-'          → e_add
parse_term   (eval.c:616)    '*' '/'          → e_mul / e_div
parse_factor (eval.c:589)    '^'              → e_pow
parse_dB     (eval.c:574)    防止 -3dB 被拆成 -(3dB)
parse_pow    (eval.c:567)    一元 +/-
parse_primary(eval.c:382)    数字/常量/函数
```

`parse_primary`(eval.c:382-549)依次:数字(eval.c:391-398)→ 调用方
const_names(eval.c:401-410)→ 内置常量 PI/E/PHI/QP2LAMBDA(eval.c:411-419)→
要求 `函数名(`(eval.c:421-428),在 50 余个 if-else strmatch 链里绑定为内置
类型或 libm 函数(eval.c:470-520),最后轮到**调用方注册的 func1/func2 名表**
(eval.c:522-540)。深度上限 `MAX_DEPTH=100`(eval.c:44)。

### 4.3 变量注入:const_names + st/ld(注意:av_expr_parse_with_vars 已不存在)

常见误解需要澄清:当前 master **没有 `av_expr_parse_with_vars`**(eval.h 全文
只有 parse/eval/count_vars/parse_and_eval,eval.h:50/74/88/99/119)。变量注入
有两条现行路径:

1. **常量表**:解析时传 `const_names/const_values` 数组,求值经 `av_expr_eval`
   (eval.c:824-837)——滤镜每帧只更新数值数组,无需重新 parse,是标准姿势;
2. **st/ld 虚拟寄存器**:表达式内 `st(1,x); ld(1)` 存取 10 个槽位
   (`#define VARS 10` eval.c:59;e_st 求值 eval.c:351-355,e_ld eval.c:206),
   存于根节点外挂的 `AVExprRoot.var`(eval.c:185-189、784)。

`while/taylor/root` 等控制流在求值器里(eval.c:266-332),图灵可玩,但定位始终
是"一行几何公式"而非脚本。快捷入口 `av_expr_parse_and_eval`(eval.c:839-855)
解析+求值+释放一步到位。

### 4.4 与滤镜的关系

滤镜自持 `var_names[]` 并调 `av_expr_parse`:vf_scale.c:46-58 定义
`in_w/iw/out_w/oh/a/sar/dar/hsub/vsub...`,vf_scale.c:277 解析;vf_zoompan.c:29
定义每帧变量,zoom/x/y 三式在 vf_zoompan.c:138-146 解析;f_select.c:42/188、
boxblur.c:26/91、af_afftfilt.c:56/175 同构。模式统一:**参数阶段 parse 一次,
每帧 eval 一次(喂 var_values 数组)**。

---

## 5. av_log 专节:层级、回调、折叠

- **级别**:PANIC..TRACE 以 8 为步长 0→56(log.h:197-236),`level>>3` 可当
  下标;全局阈值 `av_log_level` 为原子量(log.c:59),set/get 在 log.c:476/471;
- **路由**:`av_log`(log.c:442-448)→ `av_vlog`(log.c:459-469)→ 函数指针
  `av_log_callback`(log.c:440,原子存储)。`av_log_set_callback`(log.c:491-494)
  一行劫持输出——所有播放器嵌入 FFmpeg 的第一件事。av_vlog 还按 AVClass 的
  `log_level_offset_offset` 加级别偏移(log.c:464-466);
- **前缀组装**:`format_line`(log.c:320-359)用 5 个 AVBPrint 拼段:父对象
  `[parent @ ptr]`(经 parent_log_context_offset,log.c:333-341)、本对象
  (log.c:342-343)、时间戳 AV_LOG_PRINT_TIME(log.h:413,log.c:347-348)、
  级别标签 AV_LOG_PRINT_LEVEL(log.h:408,log.c:350-351);`sanitize`
  把控制字符换 '?'(log.c:251-257);
- **重复行折叠**:默认回调(log.c:379-438)静态保存上一行(log.c:383),开
  `AV_LOG_SKIP_REPEATED`(log.h:400)后相同行只打 "Last message repeated
  N times"(log.c:407-417)——逐帧告警因此刷不了屏;
- **着色**:Windows Console 与 ANSI 双路(颜色表 log.c:65-125,`colored_fputs`
  log.c:213-239),INFO 永不着色(log.c:222);环境变量 AV_LOG_FORCE_NOCOLOR/
  FORCE_COLOR 控制(log.c:171-174);
- **一次性告警** `av_log_once`(log.c:450-457);"缺样本"提示
  `avpriv_request_sample`(log.c:510)。

---

## 6. AVChannelLayout 迁移专节:从 uint64 mask 到结构体

### 6.1 为什么必须换结构体

旧 API 用 uint64 位掩码,只能表达"64 个预定义声道里有哪些",无法表达
Ambisonic、任意自定义顺序或带名字的声道。新 `AVChannelLayout`
(channel_layout.h:328-379):`order`(channel_layout.h:333)+ `nb_channels`
(channel_layout.h:338)+ union(NATIVE 用 `mask` channel_layout.h:360,CUSTOM
用 `map` 数组 channel_layout.h:379)。四种 order(channel_layout.h:119-155):
UNSPEC(119,只知声道数)、NATIVE(125,掩码)、CUSTOM(132,逐声道 id+名字)、
AMBISONIC(155)。

### 6.2 自定义顺序

`av_channel_layout_custom_init`(channel_layout.c:233-251)分配 nb_channels 个
`AVChannelCustom`,id 全置 AV_CHAN_UNKNOWN,之后逐槽赋 id、写 name。字符串侧
`"2 channels (FL+FR@left)"` 的 @ 别名由 `parse_channel_list`
(channel_layout.c:266-292)解析——它直接复用 `av_opt_get_key_value`
(channel_layout.c:275),工具箱自食其力。

### 6.3 与旧 mask 的兼容路径

- 旧→新:`av_channel_layout_from_mask`(channel_layout.c:253-264)把 mask 包成
  NATIVE order,popcount 得声道数;
- 新→旧:`av_channel_layout_subset`(channel_layout.c:867-885)从任意 order
  "抠出"与给定 mask 的交集——NATIVE/AMBISONIC 直接 AND(:874-876),CUSTOM
  逐位查 channel id(:877-881);更彻底的规整是 `av_channel_layout_retype`
  (channel_layout.c:887-955),四种 order 间无损(或按 flags 允许有损)互转;
- 字符串解析 `av_channel_layout_from_string`(channel_layout.c:313-441)优先级
  值得背:预定义名(:322-327)→ `ambisonic N+...`(:334-391)→
  `"N channels (FL+FR)"`(:398)→ **纯十六进制 mask(:414-420,旧格式仍收)** →
  `"5.1c"` 默认布局(:422-430)→ `"6C"` 无序声道(:433-438)。
  mask 分支兼容是老代码零成本迁移的保证。

---

## 7. 小件速览

### 7.1 error.c:AVERROR 机制
负数 errno + 自定义负码。描述文本用 X-macro 生成三份产物:偏移枚举
(error.c:101-110)、单块字符串池(error.c:112-118)、`{num,offset}` 索引表
(error.c:120-132)。`av_strerror`(error.c:134-151)先查表,未命中回退
`strerror_r`(:142-146)。自定义码一览 AVERROR_BUG/EOF/INVALIDDATA/
OPTION_NOT_FOUND 等(error.c:32-59)。

### 7.2 bprint.c:自动增长打印
`AVBPrint` 内嵌小缓冲(av_bprint_init bprint.c:69-83),`AV_BPRINT_SIZE_AUTOMATIC`(bprint.h:118)下先零分配;`av_bprint_alloc`(bprint.c:36-57)每次**倍增**(:44-46)并封顶 size_max;超限转入"截断计数"不崩。`av_bprint_finalize`(bprint.c:235)决定堆缓冲所有权去留。log.c 的行格式化、命令行解析全靠它。

### 7.3 fifo.c:泛型 FIFO
`struct AVFifo`(fifo.c:32-42)按 `elem_size` 存任意元素——memcpy + 字节偏移的朴素泛型。环形回绕见 `fifo_write_common`(fifo.c:149,两段 memcpy :164-172);自动增长默认上限 1MB(fifo.c:30;`av_fifo_auto_grow_limit` :77,`av_fifo_grow2` 内做腾挪重排 :99-118)。入口 `av_fifo_alloc2`(fifo.c:47)、`av_fifo_write`(fifo.c:188)、`av_fifo_read`(fifo.h:167,实现 fifo.c:240)、peek(fifo.c:255)、`av_fifo_freep2`(fifo.h:236)。

### 7.4 tree.c:av_tree 现状
自平衡 **AVL 树**(非红黑),平衡信息只一个 `int state`(tree.c:29)。`av_tree_find`(tree.c:39-57)顺手支持 `next[2]` 输出"刚好大于/小于 key 的邻居"(:45-47)。`av_tree_insert`(tree.c:59-146)的旋转代码上方留有等价 rotate 函数注释(:89-108),源码里的微型教材。全库现存重度用户只有 libavcodec/bsf/dts2pts.c:169/494/696——"保留但基本冻结",新代码多用 dynarray。

### 7.5 mem.c:av_malloc 对齐策略
`ALIGN` 按编译期 SIMD 能力取 64/32/16(mem.c:65);分配顺序 posix_memalign → _aligned_malloc → memalign(mem.c:105-116),注释保留"为什么 64:缓存行/AVX"的基准记录(:117-133)。`av_max_alloc` 全局上限(mem.c:74-78)防溢出,乘法有 `size_mult` 检查(mem.c:80-96)。`av_free`(mem.c:238)、`av_freep`(mem.c:247)、`av_mallocz`(mem.c:256)是全库最高频符号。

### 7.6 rational.c:av_reduce 连分数(04 章已现,补核心行号)
`av_reduce`(rational.c:35-78):先 gcd 约分(:40-45),再**连分数展开**逼近(:51-70):每轮取商 x 维护相邻两级渐进分数 a0/a1,一旦分子分母超 max,按"最佳有理逼近"不等式(:57-63)截断。断言保证结果既约且 ≤max(:71-72)。opt.c:226 的 `double_to_rational` 也靠它;av_gcd 在 mathematics.c:37。

### 7.7 dict.c:AVDictionary 语义
本质是 `{count, elems[]}` **线性数组**(非哈希),`av_dict_iterate`(dict.c:42-58)按下标走。`av_dict_get`(dict.c:60-84)默认大小写不敏感(:75),`AV_DICT_IGNORE_SUFFIX` 允许 `key:xxx` 前缀匹配(:79)。`av_dict_set`(dict.c:86-175)旗标:`DONT_STRDUP_KEY/VAL` 窃取所有权(:94-105)、`DONT_OVERWRITE`(:127)、`APPEND`(:132)、`MULTIKEY` 同名多键(:109-120)。与 AVOption 的分工:**dict 是未识别选项的暂存区**,opt.c:2051-2052 把剩余项放回 dict 供下游继续消费——ffmpeg CLI 的 per-stream options 管道即此。

---

## 8. 设计动机

1. **C 没有反射,就用 AVClass+AVOption 模拟**。每个可配置结构体首成员是 AVClass
   指针(log.h:76 协议),静态选项表 + offsetof 即"字段元数据";
   child_next/child_class_iterate 是"成员对象遍历"。CLI、库 API、滤镜字符串三种
   配置入口收敛到同一个 av_opt_set。代价:类型不安全(全按 offset 写内存);
   收益:一次实现全库复用。
2. **描述符表模式 vs switch-case**。pixdesc 若用 switch,新增像素格式要改 N 处;
   表驱动(pixdesc.c:203)下新格式只是追加一个初始化器,消费方零改动。同一模式
   遍布全库:opt_type_desc(opt.c:60)、error 字符串池(error.c:112)、
   channel_layout_map(channel_layout.c:322)。"数据即代码"在 C 里就是 static const 表。
3. **eval 为何自研不嵌脚本语言?** 需求边界是"每帧求值的算术表达式":无字符串、
   无对象、无 GC、解析产物是纯 AST(eval.c:171-183)可缓存;855 行零外部依赖。
   嵌入脚本语言引入运行时依赖、沙箱安全问题与不可控延迟;st/ld+while
   (eval.c:266-272、351-355)已覆盖循环存取的极端需求,再多就该写滤镜了。
4. **log.c 与 mem.c 的原子量**(log.c:59/60/440,mem.c:74):日志级别和回调必须
   能在多线程运行中热切换,而 av_log 每条消息都读它们——relaxed 原子读是最廉价的
   一致性方案。

---

## 9. FAQ 素材与深挖建议

**FAQ:**

1. `-option value` 为何能同时作用于编码器/滤镜/格式层?——三层对象都实现了 AVClass+AVOption;av_opt_set_dict2(opt.c:2040)逐层消费,认不出的 key 留在 dict 下传(opt.c:2051)。
2. `scale=w=iw/2` 的除法谁算的?——字符串经 av_opt_set_from_string(opt.c:1975),数值类选项到 set_string_number 兜底调 av_expr_parse_and_eval(opt.c:497)。
3. AV_OPT_TYPE_CONST 有什么用?——不占内存,是给同 unit 选项(opt.h:478)登记"命名常量";set_string_number 把它注入表达式常量表(opt.c:470-482)。
4. 怎么列出对象全部可配置项?——av_opt_next 线性迭代(opt.c:47);跨子对象 av_opt_child_next(opt.c:2120);对象不存在时 child_class_iterate(opt.c:2128)。
5. rgb565le 的 G 为什么 offset=0 shift=5?——16bit 小端中 G 占中 6 位;offset/shift 以 bit 精确编码位域(pixdesc.c:1233-1237;语义 pixdesc.h:46/52)。
6. 怎么判断格式是 planar/几个平面?——flags & AV_PIX_FMT_FLAG_PLANAR(pixdesc.h:132);平面数 av_pix_fmt_count_planes(pixdesc.c:3500)。
7. 为什么我的日志回调收不到?——检查 av_log_set_level(log.c:476);每条消息先过级别门槛(log.c:395)再进回调。
8. "Last message repeated" 谁打印的?——默认回调折叠逻辑,受 AV_LOG_SKIP_REPEATED 控制(log.c:407-417,log.h:400);自定义回调需自行实现。
9. 旧 uint64 channel mask 还能用吗?——能。av_channel_layout_from_mask 包成 NATIVE(channel_layout.c:253);字符串解析保留纯 mask 分支(channel_layout.c:414)。
10. AVDictionary 是哈希表吗?——不是,线性数组(dict.c:42-58),键量级小,O(n) 反而最快。

**深挖建议:**

1. opt.c 数组选项全链路:AV_OPT_TYPE_FLAG_ARRAY(opt.h:345)→ opt_set_array 拆串与转义(opt.c:824-862)→ av_opt_get_array 反向(opt.c:2261)。
2. eval 的 e_root 数值求根(eval.c:291-332):1024 次扫描+二分求零点,"表达式引擎内嵌数值方法"的取舍。
3. channel_layout_retype 的无损性判定:canonical_order(channel_layout.c:528)与三路转换(channel_layout.c:901-953),理解"order 是表示而非语义"。
4. tree.c 注释里的 rotate 函数(tree.c:89-108):复原成代码,是理解 AVL 平衡常数 0x614586/0x400EEA 的捷径。
5. format_line 的 5 段 AVBPrint(log.c:320-359):为何消息体 part[3] 上限 65536 而其余 AUTOMATIC(log.c:324-328)——bprint 策略的嵌入式应用。

---

## 写作要点速查表

| 主题 | 函数/位置 | 行号 |
|---|---|---|
| opt | av_opt_next 线性迭代;opt_type_desc 类型→尺寸表 | opt.c:47;:60-83 |
| opt | opt_set_init(查找+权限+dst);av_opt_set 主入口 | opt.c:165;:889 |
| opt | set_string_number(常量表 :470,expr 兜底 :497) | opt.c:426 |
| opt | av_opt_set_from_string(速记 :2008);set_dict2(回填 :2051) | opt.c:1975;:2040 |
| opt | av_opt_find2(子树递归 :2089);child_next/class_iterate | opt.c:2075;:2120/2128 |
| opt | AVOption 类型/旗标/结构体定义 | opt.h:254-334 / 351-389 / 428-478 |
| pixdesc | 描述符总表;yuv420p/nv12/rgb565le 条目 | pixdesc.c:203;:204/:567/:1228 |
| pixdesc | av_get_bits_per_pixel / av_pix_fmt_desc_get | pixdesc.c:3412 / 3460 |
| eval | av_strtod(dB/SI 词头) | eval.c:110 |
| eval | 递归下降链 expr→subexpr→term→factor | eval.c:664/640/616/589 |
| eval | parse_primary 函数绑定(:470);VARS=10(:59);st/ld(:351/:206) | eval.c:382 |
| eval | av_expr_parse / parse_and_eval | eval.c:735 / 839 |
| log | av_vlog 回调分发(指针 :440) | log.c:459 |
| log | 默认回调+重复折叠(:407-417) | log.c:379 |
| chlayout | 四种 order / AVChannelLayout 结构体 | channel_layout.h:119-155 / 328-379 |
| chlayout | from_string(mask 兼容 :414);from_mask/subset/retype | channel_layout.c:313;:253/:867/:887 |
| 小件 | av_reduce 连分数(逼近 :57) | rational.c:35 |
| 小件 | av_malloc(ALIGN :65);bprint 倍增/finalize | mem.c:98;bprint.c:36/235 |
| 小件 | fifo 结构/alloc2;av_tree_insert(AVL) | fifo.c:32/47;tree.c:59 |
| 小件 | av_strerror;av_dict_set 旗标语义 | error.c:134;dict.c:86 |
