# 第 18 章 · libavutil 工具箱:选项系统、像素描述符与表达式引擎

> 基线:commit `9f63b36a`。行号以 libavutil/ 为准。系列各章零散用到 av_reduce、av_log、hwcontext,本章系统盘点地基货架。**本章三处结论与流行教程相反**:①`av_expr_parse_with_vars` 在本 commit 不存在,变量注入走 const 数组;②scale 滤镜已不用 sws_getContext(见 19 章);③AVOption 的本质是"往结构体偏移写内存"的伪反射。

## 18.0 全景:地基的分层

```
┌─────────────────────────────────────────────────────┐
│ 系统层: log(日志) error(错误码) time(时钟) mem(内存) │
├─────────────────────────────────────────────────────┤
│ 编码层:  pixdesc(像素格式) channel_layout(声道)      │
│          rational(有理数) samplefmt(采样格式)        │
├─────────────────────────────────────────────────────┤
│ 数据结构层: dict fifo bprint tree avss(解析工具)     │
├─────────────────────────────────────────────────────┤
│ 元编程层: opt(AVOption 伪反射) eval(表达式引擎)      │ ← 全库配置的骨架
└─────────────────────────────────────────────────────┘
```

## 18.1 AVOption:C 的伪反射

FFmpeg 所有"能用字符串配置"的结构体(AVCodecContext/AVFormatContext/滤镜私有上下文)共享同一机制:

1. **AVClass 前置**:可配置结构体的第一个成员是 AVClass 指针(log.h:76)——运行时类型信息的锚点;
2. **offset 映射**:静态选项表用 `offset` 字段(opt.h:443)把"选项名"映射到"结构体字节偏移";`av_opt_set` 查表后算出目标地址直接写内存(opt.c:165,偏移计算 :221)——**没有 setter,没有虚函数,就是 *(dst+offset)=value**;
3. **对象树**:`child_next`(log.h:150,遍历真实子对象)与 `child_class_iterate`(log.h:167,遍历类)让一条字符串穿透多层:`-b:v 2M` 先落在 AVCodecContext,未识别则深入编码器私有上下文;`av_opt_find2` 递归搜索(opt.c:2089-2102);
4. **字符串→数字的三层兜底**(`set_string_number`,opt.c:426):
   - sscanf 有理数解析(:432);
   - 查 AV_OPT_TYPE_CONST 命名常量(:463)——`-preset medium` 的 medium 就是 CONST 项;
   - 表达式引擎 `av_expr_parse_and_eval`(:497)——`-b:v 2*1024*1024` 这种算式直接能算。

类型系统 20 种(opt.h:254-334)加 FLAG_ARRAY 修饰位(:345)。字典管道语义:`av_opt_set_dict2` 把**未识别的 key 放回 dict**(opt.c:2051)供下层继续消费——`-ar 44100 -c:a aac` 一个字典流过"滤镜→格式→编解码"三层,各取所需。

## 18.2 pixdesc:让像素格式自解释

全部像素格式的布局信息集中在一张描述符表(pixdesc.c:203):

```c
/* AVPixFmtDescriptor.comp[i](pixdesc.h:30-58)
   plane  │ 所在平面
   step   │ 该分量步进字节
   offset │ 平面内偏移
   shift  │ 低位移位
   depth  │ 有效位深        */
```

三个实例:yuv420p(:204)三平面各 8bit;nv12(:567)UV 交错在第二平面;rgb565le(:1228)单平面 16bit 内 R/B 各 5 位、G 6 位,靠 shift/depth 拆位。**swscale/编解码器读取这个描述符就能正确访问任意格式,零 switch-case**——新增 10bit/16bit/半浮点格式只需加表项。这是"描述符表 vs switch-case 山"的又一名局,与 15 章 SIMD 分发表同属一脉。

## 18.3 eval:手写递归下降的表达式引擎

滤镜的几何/时间参数(`crop=w=iw/2`,`overlay=x='t*100'`)由 eval.c 求值。词法+递归下降,调用链即优先级:

```
parse_expr(:664) → subexpr(:640,加减) → term(:616,乘除)
   → factor(:589,一元/幂) → primary(:382,数字/变量/函数)
```

函数绑定表(:470)注册 sin/cos/random 等;变量注入经 **const_names/const_values 数组**与 `st/ld` 十个虚拟寄存器(eval.c:59,:351,:206)——`ld(1)` 存取中间值,配合 ST 变量实现紧凑的循环表达式。纠偏:老教程的 `av_expr_parse_with_vars` 已不存在,接口统一并入 av_expr_parse 的参数。

**为什么自研不嵌脚本语言**:依赖体积、确定性(同一表达式必须产出同一值,不许 GC 抖动)、沙箱(用户输入来自命令行,不能有 IO 能力)——eval 的 2000 行换来这三条,是"够用哲学"的典型。

## 18.4 av_log:面向诊断的日志

级别按 8 步长编排(log.h:197-236:QUIET/PANIC/FATAL/ERROR/WARNING/INFO/VERBOSE/DEBUG/TRACE),中间级别可插拔;分发经原子函数指针 av_vlog(log.c:440,459)——**库不直接 printf,应用可整体接管**;默认回调自带重复行折叠(连续相同行显示 `last message repeated N times`,log.c:407-417)。8 步长是为了在级别位里塞入 per-message 标志位。

## 18.5 AVChannelLayout:一次现代 API 迁移的标本

旧 `uint64_t channel_mask` 表达不了自定义顺序与高阶声场。新 AVChannelLayout = order 判别 + union(channel_layout.h:328-379):NATIVE(mask)/CUSTOM(顺序表)/AMBISONIC 三态。迁移策略温和:`av_channel_layout_from_string` 保留纯 mask 语法分支(channel_layout.c:414)——**旧字符串零成本解析成新结构**;`av_channel_layout_subset`(:867)提供新→旧出口。与 03 章 send/receive API 迁移同款手法:新 API 并存,旧 API 转发。

## 18.6 小件速览

| 组件 | 要点 | 行号 |
|---|---|---|
| error.c | AVERROR=负 errno;av_err2str 栈上拼接宏 | error.h 主宏 |
| bprint.c | 自动增长字符串缓冲,平方复杂度→线性 | — |
| fifo.c | 元素大小泛型化的环形队列 | — |
| tree.c | av_tree 平衡二叉树(排序去重场景) | — |
| mem.c | av_malloc 按 ALIGN 对齐(SIMD 前提,15 章) | — |
| rational.c | av_reduce 连分数逼近(04 章已展开) | :35,不等式 :57-63 |
| dict.c | 键值容器,配置管道暂存区(见 18.1) | — |

## 18.7 设计动机

1. **伪反射是 C 库的救赎**:没有运行时类型,就把类型信息做成静态表(AVClass+AVOption),把"访问"退化为指针算术——20 年 API 演进中所有新结构体都免费获得字符串配置能力;
2. **描述符表让数据自描述**:像素格式、通道布局、采样格式都是"表项"而非"枚举分支"——扩展点集中在数据,代码保持惰性;
3. **eval 的取舍**:表达式能力以 2000 行为限,宁缺毋滥——够用哲学与确定性优先;
4. **迁移靠并存**:AVChannelLayout/AVFrame 侧数据/send-receive API,新旧两套长期共存,转发层吸收阵痛——大库演进的唯一现实路径。

## 18.8 FAQ

**Q1:AVOption 怎么找到结构体里的字段?**
静态表 offset 字段直接给出字节偏移(opt.h:443),av_opt_set 算地址写内存(opt.c:165,221)——纯指针算术,无 setter。

**Q2:-preset medium 的 medium 是字符串吗?**
是 AV_OPT_TYPE_CONST 命名常量(set_string_number 第二层,:463),不是枚举值硬编码。

**Q3:-b:v 2*1024*1024 为什么能算?**
第三层兜底走表达式引擎(opt.c:497)——所有数值选项都白送四则运算能力。

**Q4:同一个字典为什么能同时配滤镜和编码器?**
av_opt_set_dict2 把未识别 key 放回 dict(opt.c:2051)——字典沿对象树逐层消费,各取所需。

**Q5:怎么知道 nv12 的 UV 平面怎么排?**
查 pixdesc 总表(pixdesc.c:203 的 :567 条目):UV 交错在 plane 1,step=2——消费者读描述符,无硬编码。

**Q6:滤镜表达式里能存中间变量吗?**
能,st/ld 十个虚拟寄存器(eval.c:59,351,206)——`st(1,x); ld(1)+1` 模式实现跨项复用。

**Q7:av_log 重复行折叠是每行比对吗?**
默认回调内做连续相同行计数(log.c:407-417);自定义回调接管后折叠失效——诊断工具常因此重复刷屏。

**Q8:老代码的 channel_mask 会失效吗?**
不会,from_string/from_mask 保留兼容分支(channel_layout.c:414),subset(:867)提供回退出口。

**Q9:为什么 libavutil 没有 std::map 之类的容器?**
tree/fifo/dict/bprint 按需造轮子:每个都为特定访问模式优化,标准库无 ABI 稳定保证——C 库只能自带。

**Q10:av_malloc 为什么要自定义对齐?**
SIMD 加载要求 16/32/64 字节对齐(15 章流水线的隐藏前提),malloc 只保证 max_align_t——av_malloc 用 posix_memalign/手动对齐补齐(mem.c)。

## 18.9 小结与深挖方向

本章结论:**libavutil 的精华是"元编程层"——AVOption 伪反射 + pixdesc 描述符表 + eval 表达式,三者合起来让 C 库获得了配置/自描述/计算三种"脚本级"能力而零依赖**。深挖:

1. child_next 对象树在硬件上下文(AVHWDeviceContext)中的穿透深度;
2. FLAG_ARRAY(opt.h:345)数组选项的内存布局与 ABI 演进;
3. eval 虚拟寄存器 st/ld 的求值语义与死循环防护;
4. AVChannelLayout AMBISONIC 的高阶声场扩展路径;
5. tree.c 平衡策略在字形缓存(19 章 drawtext)中的实际负载。

> 下一章:视频滤镜族——框架概念在明星滤镜中的落地。
