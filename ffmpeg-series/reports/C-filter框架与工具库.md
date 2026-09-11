# C · 滤镜图框架与核心工具库

> 系列:《源码深读·系统开源项目解读系列》第二系列《FFmpeg》
> 代码版本:master @ 9f63b36a(2025 年前后 master,已包含 AVFilterGraphSegment 新解析 API)
> 本篇覆盖:`libavfilter/`(avfilter.c、graphparser.c、framesync.c、vf_scale.c)+ `libavutil/`(mem.c、log.c、rational.c、time.c、error.c、samplefmt.c)
> 阅读前提:有 3-5 年后端经验,不要求音视频背景。

---

## ① 全景:filter 就是 FFmpeg 的"Unix 管道"

如果把 FFmpeg 的转码流水线压缩成一句话,就是:demuxer 拆出压缩包 → decoder 解成裸帧(AVFrame)→ **filter 图加工裸帧** → encoder 压回去 → muxer 写出。中间那一级,就是本篇的主角 libavfilter。它的编程模型和 Unix 管道几乎一一对应:

| Unix 管道 | FFmpeg 滤镜图 |
|---|---|
| 进程 | 滤镜实例 AVFilterContext |
| stdin/stdout | 输入/输出 pad(AVFilterPad) |
| 匿名管道 | 连接 AVFilterLink(帧的先进先出队列 + 协商好的参数) |
| `a | b | c` 命令行 | `"scale=1280:720,overlay=W-w:0"` 字符串 |
| shell 解析器 | graphparser.c |
| `select()`/事件循环就绪通知 | activate 回调 + ready 优先级调度 |

与管道不同的两个关键点:

1. **帧不是字节流**。每条链路上要先"协商"出统一的时间基(AVRational)、分辨率、像素格式(或音频的采样格式/声道布局),协商失败时框架会自动插入 `format`/`scale`/`aresample` 转换滤镜(`avfilter_insert_filter`,libavfilter/avfilter.c:282)。
2. **图是多输入多输出的 DAG**,不是单向一维流。`overlay` 这类滤镜有两条输入(主画面 + 叠加层),于是必须有跨流的帧对齐——这就是 framesync.c 的职责。

调度模型上,libavfilter 采用"拉取 + 就绪标记"的混合模式:下游通过 `ff_request_frame` 把 `frame_wanted_out` 标记逐级上推,上游 `ff_filter_frame` 把帧压入每条 link 自带的 FIFO 并把目标滤镜标为 ready(libavfilter/avfilter.c:1068-1125);图的最外层反复挑选 ready 值最高的滤镜调用其 `activate`(avfilter.c:1451-1465)。

> **版本勘误**:任务清单中提到的 `libavfilter/filters.c` 在当前 master 已不存在——"通用滤镜输入输出处理"的职责已拆分:`ff_filter_frame`/`ff_inlink_*`/`ff_outlink_*` 都在 avfilter.c,视频帧缓冲池分配在 `libavfilter/video.c`(ff_get_video_buffer,libavfilter/video.c:89-100),`filters.h` 里则集中了 AVFilterPad 结构与 `FF_FILTER_FORWARD_*` 宏(libavfilter/filters.h:40、639-712)。本篇按现状覆盖。

---

## ② AVFilterGraph 三层抽象:AVFilter / AVFilterContext / AVFilterLink

libavfilter 的核心是"类 vs 实例 vs 连接"三层:

- **AVFilter**(libavfilter/avfilter.h:215-260):静态的滤镜"类"。只有 name、description、两个 pad 数组(`inputs`/`outputs`)、`priv_class`(私有选项表,即滤镜的"配置 schema")和 flags。全进程只读共享。
- **AVFilterContext**(avfilter.h:273-353):一个实例。除回指 `filter` 外,关键是 `input_pads/inputs/nb_inputs` 三元组、`priv`(每个实例独立的私有状态,如 ScaleContext)、`graph` 回指针、线程参数和 `enable_str`(timeline 表达式)。
- **AVFilterLink**(avfilter.h:367-427):连接。记录 `src/srcpad/dst/dstpad` 四个端点,以及协商结果:`format`、视频的 `w/h/sample_aspect_ratio/colorspace/color_range`、音频的 `sample_rate/ch_layout`,以及音视频共同的时间基 `time_base`(注释明确:输出侧可以改,输入侧视为不可变属性,avfilter.h:396-403)。`incfg/outcfg` 是协商前双方各自"支持列表"。
- **AVFilterGraph**(avfilter.h:561-619):只是 `filters` 实例数组 + 全图线程配置 + `execute`(可替换的并行执行器,avfilter.h:608)+ `max_buffered_frames` 背压上限。

值得注意的内幕:公开结构体其实只是"头",真实状态藏在内部扩展结构里,用首成员嵌套 + 强转实现继承(libavfilter/avfilter_internal.h:35-92):

```c
typedef struct FilterLinkInternal {
    FilterLink l;              // 公有部分在首地址
    FFFramePool frame_pool;    // 输出帧缓冲池
    FFFrameQueue fifo;         // 该输入上待处理的帧队列
    int frame_blocked_in;      // 上游暂时产不出帧,避免重复 request
    int status_in, status_out; // 链路两端各自看到的 EOF/错误
    int64_t status_in_pts;
    int frame_wanted_out;      // 下游是否在要帧
    int age_index;             // sink 链路"年龄堆"中的位置
    ... init_state;
} FilterLinkInternal;
```

`FFFilterContext` 里同样藏着调度核心字段 `ready`(就绪优先级)与命令队列(avfilter_internal.h:99-123)。这套"公有头 + 私有体"的廉价继承贯穿整个 FFmpeg(FFFilter、FFFrameSync 同款)。

建立连接的 `avfilter_link`(libavfilter/avfilter.c:149-196)做四件事:校验同一 graph、pad 存在且未占用、媒体类型一致(avfilter.c:169-175);malloc 一个 FilterLinkInternal 并同时写进两端 `outputs[srcpad]` 与 `inputs[dstpad]`(avfilter.c:182);format 先置 -1 表示"尚未协商"(avfilter.c:190-191);给 link 挂上 FIFO(avfilter.c:193)。

```
        AVFilterContext "scale"                AVFilterContext "overlay"(主输入)
        ┌───────────────────────┐              ┌───────────────────────┐
        │ filter = ff_vf_scale  │              │ filter = ff_vf_overlay│
        │ priv = ScaleContext   │              │ priv = OverlayContext │
        │  input_pads[0] ←──────│──link────────│→ input_pads[0] "main" │
        │  output_pads[0] ──────│→  AVFilterLink│                      │
        └───────────────────────┘              └───────────────────────┘
link 内容: src=scale, srcpad=&output_pads[0], dst=overlay, dstpad=&input_pads[0]
          format=yuv420p, w=1280, h=720, time_base=1/25, fifo=[帧...帧]
          frame_wanted_out / status_in / status_out / age_index ...
```

图初始化完成后由 `avfilter_graph_config`(libavfilter/avfiltergraph.c:1434-1452)收尾,五步:合法性检查 → 格式协商(`graph_config_formats`,avfiltergraph.c:1366-1392:反复调各滤镜 `query_formats` 直到 EAGAIN 消失,再 `reduce_formats`/`swap_sample_fmts` 等启发式减少转换)→ 逐 link 调 `config_props` 使分辨率/时间基落地(`ff_filter_config_links`,libavfilter/avfilter.c:328-455,音频默认时间基取 `1/sample_rate`,avfilter.c:424-425)→ 检查 → 构建 sink 链路"年龄堆"(`graph_config_pointers`,avfiltergraph.c:1394-1432)。之后运行期,`update_link_current_pts` 用 `av_rescale_q` 把帧 PTS 换算成微秒维护堆序(avfilter.c:216-227),`avfilter_graph_request_oldest` 永远驱动"最老"的 sink(avfiltergraph.c:1567-1597)——这个"最老优先"是防多输出图饿死的简单而有效的策略。

作为应用开发者,你通常不会亲手 new 出滤镜和连线,而是走两个"边界滤镜":`buffer`(视频)/`abuffer`(音频)作为图的数据入口,`buffersink`/`abuffersink` 作为出口。API 流程四步:`avfilter_graph_alloc` 建图 → `avfilter_graph_create_filter` 建 buffer 入口并 `av_buffersrc_add_frame` 喂帧 → 中间一段滤镜图字符串交给 graphparser → `av_buffersink_get_frame` 循环收帧。也就是说,滤镜图对宿主程序而言就是一个"帧进帧出的协程",所有调度细节都封在 `av_buffersrc_add_frame`/`av_buffersink_get_frame` 内部的 activate 循环里。

**activate 模型**是理解运行期的钥匙。老 API 是"推"(filter_frame)+"拉"(request_frame)两个回调,多输入滤镜很容易写死锁;新 API 把决策权一次性交给滤镜:框架只保证"调用 activate 时世界可能变了",滤镜自己在回调里轮询所有输入输出。没写 activate 的老滤镜走通用默认实现 `filter_activate_default`(avfilter.c:1263-1306),它按固定优先级尝试:① 处理就绪帧 → ② 传播输入 EOF → ③ 转发要帧请求(先看 `frame_blocked_in` 防死循环)→ ④ sink 请求输入。avfilter.c:1308-1449 有一段罕见的、以百行计的设计注释,逐字段解释 `frame_wanted_out`/`frame_blocked_in`/`fifo`/`status_in`/`status_out` 的状态机,是源码里最值得通读的文档。应用层驱动方式则是标准的 `av_buffersrc_add_frame` 喂帧、`av_buffersink_get_frame` 收帧。

---

## ③ 滤镜图字符串解析:`"scale=1280:720,overlay=W-w:0"` 如何变成图

解析器在 libavfilter/graphparser.c。新一代 API 把解析拆成五个可插拔阶段(graphparser.c:882-918 的 `avfilter_graph_segment_apply`):**parse → create_filters → apply_opts → init → link**,老入口 `avfilter_graph_parse_ptr`(graphparser.c:920-1042)只是它们的顺序封装。

**第一层:词法。** 语法只有四级:

```
graph   := chain (';' chain)*          ; 分号分隔多条链(多分支)
chain   := filter (',' filter)*        ; 逗号串联,前一输出接后一输入
filter  := [in_label...] name[@inst][:=opts] [out_label...]
label   := '[' 任意非]字符 ']'
```

`avfilter_graph_segment_parse`(graphparser.c:460-514)先吞掉可选的 `sws_flags=...;` 前缀(graphparser.c:115-136,它作用于图内所有自动插入的 scale),然后循环调 `chain_parse`。`chain_parse`(graphparser.c:403-458)循环调 `filter_parse`,遇到 `,` 继续本链、`;` 或串尾结束本链(graphparser.c:432-446)。`filter_parse`(graphparser.c:338-401)是词法核心:

```c
ret = linklabels_parse(logctx, filter, &p->inputs, &p->nb_inputs); // 吃 "[a][b]"
p->filter_name = av_get_token(filter, "=,;[");                     // "scale"
inst_name = strchr(p->filter_name, '@');                           // scale@x 的实例名
if (**filter == '=') {                                             // "scale=..." 有参数
    (*filter)++;
    opts = av_get_token(filter, "[],;");                           // "1280:720"
    ret  = ff_filter_opt_parse(logctx, f ? f->priv_class : NULL,
                               &p->opts, opts);                    // 冒号分隔,首参可匿
}
ret = linklabels_parse(logctx, filter, &p->outputs, &p->nb_outputs);
```

注意它用 `av_get_token` 而非 `strtok`,所以引号和转义(`overlay=x='a:b'`)是安全的。参数解析复用 AVOption 体系:`ff_filter_opt_parse`(libavfilter/avfilter.c:853-904)按 priv_class 的声明顺序给无 key 的位置参数配对(所以 `scale=1280:720` 等价 `scale=w=1280:h=720`,avfilter.c:869-874),余下按 `key=value:key2=value2` 处理。`scale=1280:720` 中 `W-w` 这种表达式此刻只是字符串,真正求值发生在滤镜 config_props 阶段(见 ⑤)。

**第二层:建实例。** `avfilter_graph_segment_create_filters`(graphparser.c:516-575)用 `avfilter_get_by_name` 查注册表(注册表在 allfilters.c,编译期生成),失败报 `No such filter`(graphparser.c:542-546)。未命名的实例自动叫 `Parsed_scale_0` 这类名字(graphparser.c:549)。

**第三层:连线。** `avfilter_graph_segment_link` 遍历每个滤镜,`link_inputs`/`link_outputs`(graphparser.c:702-812)处理两种边:带 label 的边先在同段内用 `find_linklabel`(graphparser.c:643-676)找配对(支持跨链,即 `[v]` 引用更早的链);**无 label 的 pad 优先接到同链下一个滤镜的无 label 输入**(graphparser.c:785-802 的显式注释)——这就是逗号串联语义的实现。接不上的端口装进 `AVFilterInOut` 链表作为"开放端口"返回。

**第四层:与外界缝合。** `avfilter_graph_parse` / `parse_ptr` 拿开放端口和应用传入的 buffersrc/buffersink 按名字配对(graphparser.c:979-1018);没写 label 的首个输入/最后输出默认叫 `[in]`/`[out]`(graphparser.c:174-176、952-971)——所以 `"scale=1280:720"` 单独就能用。

**错误处理风格**值得后端工程师学习:任何一步失败都把已创建的滤镜逐个 `avfilter_free` 并清空 graph->filters(graphparser.c:156-159、1023-1030),保证"parse 失败 = 图不存在",不留半初始化状态;选项残留则精确报出第一个不存在的选项名(graphparser.c:857-880)。

---

## ④ 多输入同步:framesync 的帧对齐策略

`overlay`、`blend`、`xfade` 等 N 入 1 出滤镜共同的问题是:两路流的帧率、起点、时长都不同,何时能合成一帧?libavfilter 把答案抽成可复用组件 FFFrameSync(libavfilter/framesync.c),它自己也是一个 AVOption 子对象,暴露四个滤镜级参数(framesync.c:36-53):`eof_action=repeat|endall|pass`、`shortest`、`repeatlast`、`ts_sync_mode=default|nearest`——这些正是 `overlay=...:shortest=1:eof_action=pass` 的来源。

核心抽象是"**帧事件**":把所有输入的 PTS 统一到公共时间基(取各路 time_base 的最大公约数,`av_gcd_q`,framesync.c:160-177)后,沿时间轴推进;每当最高同步级的输入到达一个新 PTS,就触发一次 `on_event` 回调,滤镜在回调里取各路"当前帧"做合成。`FFFrameSyncIn.sync` 字段定义同步级:主输入 sync=2、叠加输入 sync=1,即只有主输入的帧会"造事件",叠加层只负责在事件发生时提供"PTS ≤ 事件时刻的最近一帧"(framesync.h:149-160 的注释给了三输入的例子)。

推进循环 `framesync_advance`(framesync.c:187-236)的策略:

```c
while (!(fs->frame_ready || fs->eof)) {
    ret = consume_from_fifos(fs);          // 从各 link FIFO 拉帧/EOF 注入
    pts = INT64_MAX;
    for (i = 0; i < fs->nb_in; i++)
        if (fs->in[i].have_next && fs->in[i].pts_next < pts)
            pts = fs->in[i].pts_next;      // 事件时刻 = 所有"下一帧"的最小 PTS
    for (i = 0; i < fs->nb_in; i++) {
        if (fs->in[i].pts_next == pts || ...TS_NEAREST条件...) {
            ... 换装: frame=frame_next, 状态 BOF/RUN/EOF 迁移
            if (fs->in[i].sync == fs->sync_level && fs->in[i].frame)
                fs->frame_ready = 1;       // 最高同步级到帧 → 事件就绪
        }
    }
}
```

每个输入在内部维护 `frame`(当前帧)与 `frame_next`(预读的下一帧)两个槽位,因此**叠加输入的"旧帧"可以一直留存**到主输入追上来——这就是 `repeatlast` 的实现基础。EOF 处理是三个维度的组合(framesync.h:60-76):输入结束后 `after` 模式取 `EXT_STOP`(整图停)/`EXT_NULL`(忽略该流)/`EXT_INFINITY`(最后一帧无限延长);dualinput 的默认配置正好体现 overlay 语义:主输入 `before=EXT_STOP`(主没来就别开始)、`after=EXT_INFINITY`(主结束后依旧发事件直到被 shortest/endall 掐掉),副输入 `after=EXT_INFINITY` + `repeatlast=1`(framesync.c:372-388)。EOF 时刻的 PTS 用 `framesync_pts_extrapolate = pts + 1` 粗糙外推(framesync.c:238-243,注释自嘲"可用帧率改进")。

滤镜侧的接入极其薄。以 overlay 为例(vf_overlay.c:343、903):init 里 `ff_framesync_init_dualinput`,activate 里只有一行 `return ff_framesync_activate(&s->fs);`,activate 再驱动 `on_event`(overlay 的 `do_blend`)。`ff_framesync_get_frame` 还处理了引用语义:若本帧会比别的同步流活得久就 `av_frame_clone`,否则直接移交所有权(framesync.c:282-294)。

`ts_sync_mode` 值得单独展开,它回答"副输入拿哪一帧对齐主输入"这个实际业务问题:`default` 模式取 PTS ≤ 事件时刻的最近一帧,即"主画面到哪,副画面只用不超前的素材",对硬字幕、台标这类叠加语义是安全的选择;`nearest` 模式取绝对时间上最近的一帧,可能取到"未来"的帧,适合 blend/xfade 这类两侧地位对等的混合。`framesync_sync_level_update`(framesync.c:113-135)在任一输入到达 EOF 时重算全图同步级:同步级下降后,原本压着不发的低级输入升格为事件源,同时按 `ts_sync_mode` 选项重排各输入的匹配策略——这保证了"视频流先结束、只剩音频驱动的场景"仍能继续产出画面而不是提前断流。

值得指出两个务实细节:其一,`ff_framesync_init` 直接 `av_assert0(parent->nb_outputs == 1)`(framesync.c:91)——框架宁可断言也不实现用不到的通用性;其二,与 timeline `enable` 联动靠 `dualinput_get` 里 `if (ctx->is_disabled) secondpic = NULL`(framesync.c:403-404):滤镜被禁用时把副画面置空,主画面原样透传,framesync 时钟不乱。

---

## ⑤ 案例分析:vf_scale 从配置到 sws 到输出

`scale` 是使用率最高的滤镜,也是"滤镜如何包装一个算法库(libswscale)"的范本。声明在 libavfilter/vf_scale.c:1189-1203:

```c
const FFFilter ff_vf_scale = {
    .p.name = "scale",
    .p.priv_class = &scale_class,      // 选项表 scale_options(1069-1162)
    .p.flags = AVFILTER_FLAG_DYNAMIC_INPUTS,   // 运行时可加输入 pad
    .preinit = preinit, .init = init, .uninit = uninit,
    .priv_size = sizeof(ScaleContext),
    FILTER_QUERY_FUNC2(query_formats),
    .activate = activate,
    .process_command = process_command,
};
```

**生命周期分四段:**

1. **preinit**(vf_scale.c:310-324):在选项尚未解析时就 `sws_alloc_context()` 造好 SwsContext——因为 scale 的选项表通过 `child_class_iterate`(vf_scale.c:1041-1053)把 sws 的选项也挂为自己的子选项,用户可写 `scale=flags=lanczos` 直接透传给 sws,这要求 sws 对象先存在。
2. **init**(vf_scale.c:328-439):配置落地。`size`/`s` 先经 `av_parse_video_size` 归一成 w/h 表达式(vf_scale.c:345-356);未指定则默认 `w=iw, h=ih`(vf_scale.c:357-360)——这就是"只写 scale 不带参数=原尺寸"的由来。表达式在此 `av_expr_parse` 编译成 AST(`scale_parse_expr`,vf_scale.c:257-308),`check_exprs`(vf_scale.c:184-255)静态拒绝 `w` 表达式引用 `ow` 这类自引用。若表达式用到 `rw/rh` 等 ref 变量,动态追加一个 "ref" 输入 pad(vf_scale.c:428-436,兼容已废弃的 scale2ref,也因此声明了 DYNAMIC_INPUTS)。
3. **协商**:`query_formats`(vf_scale.c:451-530)枚举全像素格式表,用 `sws_test_format` 过滤出 sws 真正支持的输入/输出集合,再连同色彩空间/范围一起挂到 link 的 `outcfg`——格式协商由框架在 graph config 时统一完成,滤镜只声明能力。
4. **config_props + 运行**:输出 pad 的 `config_props = config_props`(vf_scale.c:1185)在图配置阶段被框架调用(avfilter.c:442-448),这里完成真正的尺寸求值:

```c
// vf_scale.c:633-645(config_props,节选)
if ((ret = scale_eval_dimensions(ctx)) < 0) goto fail;  // 求值 w/h 表达式
outlink->w = scale->w;  outlink->h = scale->h;
ret = ff_scale_adjust_dimensions(inlink, &outlink->w, &outlink->h,
                           scale->force_original_aspect_ratio,
                           scale->force_divisible_by, w_adj);
```

`scale_eval_dimensions`(vf_scale.c:532-619)把 `iw/ih/a/sar/dar/hsub...` 等变量灌进 `var_values` 再 `av_expr_eval`——`overlay=W-w:0` 同理是在 overlay 的 config 里求值的。`force_original_aspect_ratio=decrease/increase` 与 `force_divisible_by` 的钳制在 `ff_scale_adjust_dimensions`(scale_eval.c)完成。SAR(像素宽高比)重算是一段经典有理数应用:输出 SAR = 输入 SAR × (in_w/out_w) ÷ (in_h/out_h),框架用 `av_div_q`/`av_mul_q` 两行搞定(vf_scale.c:660-664)。

运行期:activate → `ff_framesync_activate`(vf_scale.c:1035-1039,scale 即使单输入也走 framesync,为的是统一处理 EOF/enable)→ 事件回调 `do_scale`(vf_scale.c:898-959)→ `scale_frame`(vf_scale.c:744-896):检测输入属性变化(`frame_changed`,vf_scale.c:758-764,流中途变分辨率会触发重新 config_props,支持动态分辨率);`eval=frame` 模式下每帧重求表达式;`ff_get_video_buffer` 从 link 的帧池拿输出帧(vf_scale.c:818,实现在 libavfilter/video.c:49-100,池按 `av_cpu_max_align()` 对齐);尺寸色彩都相同则 `sws_is_noop` 直接透传省一次拷贝(vf_scale.c:872-877);否则一行 `sws_scale_frame(scale->sws, out, in)`(vf_scale.c:884)交给 swscale,最后 `ff_filter_frame(outlink, out)` 把帧推进下游。

**运行时控制**:w/h 选项带 `AV_OPT_FLAG_RUNTIME_PARAM`(vf_scale.c:1070-1073),`process_command`(vf_scale.c:1010-1033)支持运行中改 `scale@x w=...`,且失败时回滚旧表达式(`scale_parse_expr` 的 revert 逻辑,vf_scale.c:297-307)——"改配置要么全成要么不变"的乐观更新模式。

---

## ⑥ libavutil 核心件:mem / rational / log(及 time、error、samplefmt)

**mem.c——带对齐的分配器**(libavutil/mem.c)。`av_malloc`(mem.c:98-153)与 malloc 的唯一本质区别是显式对齐:优先 `posix_memalign(&ptr, ALIGN, size)`,Windows 用 `_aligned_malloc`,对齐值 `ALIGN = 64/32/16 由 SIMD 能力决定`(mem.c:65)。mem.c:117-140 那段注释记录了 2002 年前后在 P3 上的 benchmark 数据,解释"为什么 64":cache 行对齐 + AVX 指令要求,宁可多给不搞多级逻辑。所有 array 版本(`av_malloc_array`/`av_calloc`/`av_realloc_array`,mem.c:209-223)都先过 `size_mult` 溢出检查(`__builtin_mul_overflow`,mem.c:80-96);全局 `av_max_alloc` 上限(mem.c:74-78)是防恶意文件把堆打爆的保险丝。惯用组合 `av_freep`(mem.c:247-254)在 free 的同时把调用方的指针置 NULL——FFmpeg 代码里漫山遍野的 `av_freep(&x)` 就是防 use-after-free/double-free 的纪律化写法。两个陷阱:① `av_realloc` 走系统 realloc,**不保证** ALIGN 对齐(mem.c:155-171,`size + !size` 技巧保证 size=0 也能合法返回),所以 SIMD 缓冲必须用 av_malloc 系;② `av_malloc(0)` 返回一个 1 字节块而非 NULL(mem.c:144-147),使"NULL=失败"语义纯净。`av_fast_realloc`/`av_fast_malloc` 是带 1/16 + 32 增长因子的幂等扩容(mem.c:487-556),配合调用方缓存的 size 避免逐帧 realloc。

**rational.c——时间戳为什么必须是分数**(libavutil/rational.c)。`AVRational {int num, den}`(libavutil/rational.h:58-61)。视频时间基如 1/90000(MPEG TS)、1/1000、音频 1/44100,都不是 2 的幂,用 double 存 PTS 会随时长累积精度损失,分数则精确。核心 `av_reduce`(rational.c:35-78)用**连分数展开**把任意 int64 分数在分母 ≤ max 的约束下化成最佳有理逼近(经典算法,`return den == 0` 还能告知"结果是精确的");`av_d2q` 反向把 double 转分数(rational.c:110-127)。四则运算全部即时约分:`av_div_q(b,c) = av_mul_q(b, {c.den, c.num})`(rational.c:88-91)。真正消税率最高的是 mathematics.c 的 `av_rescale_q(ts, from_tb, to_tb)`:以 128 位中间精度做 `ts * from_tb/to_tb` 的有理缩放,是所有时间基转换的唯一入口(filtersync.c:251、avfilter.c:223、vf_scale.c:953 全在调它)。

举个具体例子帮助建立直觉:一帧 29.97fps(准确说是 30000/1001)视频,PTS 递增 3003 个 `1/90000` 秒;转成毫秒时间基要算 `3003 * (1/90000) ÷ (1/1000) = 33.36…`,`av_rescale_q` 会四舍五入成 33 且全程无浮点参与;而 framesync 把两路不同时间基归一时用的 `av_gcd_q`(rational.c:188-195,分母取最小公倍数、分子取最大公约数)保证公共时间基仍是精确分数而非近似小数。对后端工程师,可以把它理解成"时间戳界的定点数库":一切运算只在整数域发生,`av_reduce` 负责把结果压回可表示范围。

**log.c——分级 + 全局回调的日志系统**(libavutil/log.c)。级别按 **8 递增**定义(libavutil/log.h:192-238):QUIET(-8)、PANIC(0)、FATAL(8)、ERROR(16)、WARNING(24)、INFO(32,默认,log.c:59)、VERBOSE(40)、DEBUG(48)、TRACE(56)——间隔 8 是为了把低 3 位挪作 `AV_LOG_C(color)` 色号复用(log.h:247 的示例)。架构是经典的"两级分发":`av_log(obj, level, fmt, ...)` → `av_vlog` 取出原子变量持有的全局回调(log.c:440、459-469)→ 默认回调 `av_log_default_callback`(log.c:379-438)加互斥锁、按 `av_log_level` 过滤、支持 `AV_LOG_SKIP_REPEATED` 去重("Last message repeated N times",log.c:407-417)、按级别和对象类别着色(log.c:98-125 的调色表,可用 `AV_LOG_FORCE_NOCOLOR` 环境变量干预,log.c:171-186)。对象侧的约定:一切可日志对象首成员是 `AVClass*`,`format_line` 借 `parent_log_context_offset` 自动拼出 `[graph @ 0x...] [scale @ 0x...]` 两级前缀(log.c:332-345)——这就是 ffplay 里日志能标明"哪个滤镜说的"的机制。业务方 `av_log_set_callback` 一行即可接管(log.c:491-494),注意默认回调是有锁的,热路径频繁打 DEBUG 会有争用成本。

**time.c**:区分墙钟 `av_gettime`(微秒,系统启动可回拨;Windows 上做 FILETIME 1601 纪元换算,time.c:46-51)与单调钟 `av_gettime_relative`(CLOCK_MONOTONIC / QPC,time.c:57-76);无单调钟的平台上用"墙钟 + 42 小时偏移"兜底并让 `av_gettime_relative_is_monotonic` 返回 0 告知调用方不可靠——像 `-re` 读文件限速、rtcp 定时器都用相对钟。`av_usleep` 同样是三层平台折叠(time.c:93-107)。

**error.c**:FFmpeg 在 errno 之外定义了 20 多个自有错误码(AVERROR_EOF、AVERROR_INVALIDDATA、AVERROR_FILTER_NOT_FOUND...),用 X-Macro 一张表同时生成枚举偏移、紧凑字符串池和条目表(error.c:30-132),`av_strerror` 先查自有表再回落 `strerror_r`(error.c:134-151)。`av_err2str` 宏在栈上借复合字面量拼 buffer,让调用方免管生命周期。

**samplefmt.c**:音频采样格式的元数据表驱动设计。`sample_fmt_info[AV_SAMPLE_FMT_NB]`(samplefmt.c:37-49)每个表项存 name、位深 `bits`、`planar` 与 `altform`(packed↔planar 互转的孪生格式)。关键函数:`av_samples_get_buffer_size`(samplefmt.c:121-151)——align=0 时自动把采样数向上 32 对齐(samplefmt.c:133-138),planar 时 linesize 是单声道行宽、总大小 ×nb_channels(samplefmt.c:145-150),并带两处整数溢出防御;`av_samples_fill_arrays`(samplefmt.c:153-180)把一块裸 buffer 按 planar 布局切出每声道指针。planar(每声道一块连续内存,如 fltp,是现代音频编码器的原生格式)与 packed(帧内交织)的二元对立,是读音频滤镜代码前必须建立的第一直觉。

---

## ⑦ 设计动机与取舍

1. **"声明能力,框架协商"**。滤镜只通过 query_formats 声明支持集,格式由图级 `query_formats` 不动点循环 + 启发式统一决定(avfiltergraph.c:1366-1392)。代价是实现复杂(consq:格式协商代码是 libavfilter 公认最难读的部分),收益是任意滤镜可自由组合、缺格式自动插转换滤镜,用户字符串几乎不需要写 format 转换。
2. **activate 取代 push/pull 双回调**。老模型下单输入好写、多输入易死锁(要靠 `frame_blocked_in` 猜),新模型把调度逻辑还给滤镜作者,框架只提供 FIFO 与状态字段(avfilter.c:1308-1449 的长注释即为此写的教材)。代价是每个滤镜的 activate 都是一段手写状态机,好在 framesync 把最常见的多输入情形封装掉了。
3. **廉价的 C 继承**。公有结构体首嵌私有体 + `static inline` 强转访问器(avfilter_internal.h:94-97),零开销实现"公共 API 稳定、内部随便加字段"。AVFilterLink 公共头里甚至明文划出"此线以下非公有"(avfilter.h:410-415)。
4. **帧所有权用引用计数 + 写时复制**。`ff_inlink_make_frame_writable`(avfilter.c:1567-1605)仅在引用计数 >1 时整体拷贝;framesync 的 `need_copy` 判定(framesync.c:282-294)把 clone 也省到只剩必要。整条管线几乎零多余 memcpy,这是 FFmpeg 性能的根基之一。
5. **字符串即配置,表达式即参数**。滤镜参数、图拓扑全部是可序列化字符串,由 AVOption/eval 两套通用解释器消化,换来 ffmpeg CLI 与 API 的单一入口;代价是配置错误只能推迟到运行期才暴露(scale 的 w 表达式到 config_props 才求值),check_exprs 这类静态检查是事后补救。
6. **libavutil 的"最小公共件"哲学**:mem/rational/log 不封装资源句柄、不做对象系统,只提供纪律化的原语(av_freep、AVRational、AVClass 日志前缀),把内存与数值正确性变成"写法惯例"而非运行时强制——这是 C 项目规模化协作的务实选择,但也意味着纪律失守(如绕过 av_* 直接用 realloc 对齐缓冲)不会有编译器替你报警。

---

## ⑧ FAQ

**Q1:`scale=1280:720` 里的 `1280` 没写 `w=`,为什么能对上?**
`ff_filter_opt_parse` 按 priv_class 选项声明顺序为无名参数配对(implicit key),w/h 是 scale_options 的前两项(libavfilter/avfilter.c:869-874、vf_scale.c:1070-1073)。

**Q2:`overlay=W-w:0` 的 `W-w` 什么时候求值?字符串存在哪?**
存进 AVOption(`x/y` 是字符串选项),在滤镜 config_props 阶段用 av_expr 求值;scale 的同类求值在 `scale_eval_dimensions`(vf_scale.c:591-608)。`eval=frame` 可改为每帧求值。

**Q3:两个滤镜一个只输出 yuv420p、一个只要 rgb24,谁来转?**
协商失败时框架自动 `avfilter_insert_filter` 插入 `format`/`scale`/`aresample`(libavfilter/avfilter.c:282-326),并把 `scale_sws_opts`(graphparser.c:523-528)等全局参数带给自动插入的 scale。

**Q4:帧数据在滤镜间会反复拷贝吗?**
不会。链路传的是 AVFrame 引用;仅当 pad 声明 `AVFILTERPAD_FLAG_NEEDS_WRITABLE` 或 framesync 判定必须 clone 时才拷(avfilter.c:1047-1051、framesync.c:282-294)。输出帧本身从 link 级帧池分配(video.c:49-86)。

**Q5:EOF 是怎么在图里传播的?**
link 两端各有一个 status:`status_in`(源侧写入)/`status_out`(宿侧确认)。`ff_inlink_acknowledge_status` 是消费方确认 EOF 的唯一正规途径(avfilter.c:1467-1481),`FF_FILTER_FORWARD_STATUS*` 宏做逐级转发(filters.h:666-693),framesync 里再按 eof_action/shortest 折算成输出 EOF(framesync.c:106-111)。

**Q6:activate 滤镜还能用 `ff_request_frame` 吗?**
不能,函数开头 `av_assert1(!activate)`(avfilter.c:489)。activate 滤镜改用 `ff_outlink_set_status`/`ff_inlink_request_frame` 与宏组合表达同样的拉取意图。

**Q7:av_realloc 出来的指针能给 SIMD 代码用吗?**
不能保证。`av_realloc` 走系统 realloc,只有 `av_malloc` 系列保证 ALIGN(≤64)对齐(mem.c:155-171 vs 98-153)。这也是滤镜帧池坚持 av_malloc 分配的原因。

**Q8:为什么 PTS 用 AVRational 时间基而不是纳秒整数?**
常见时间基(1/90000、1/44100、1/30000÷1001)分母含 3、7、11 等因子,固定纳秒整数会引入舍入且跨容器转换有累积误差;分数表示精确且 `av_rescale_q` 用 64/128 位中间精度一次性换算,`av_reduce` 的连分数逼近保证任何有限小数都能找到可表示的最佳分数(rational.c:35-78)。

**Q9:怎么接住 FFmpeg 的日志?**
`av_log_set_callback(my_cb)`,签名 `(void *ctx, int level, char *fmt, va_list)`,在回调里用 `av_log_format_line2` 展开前缀(log.c:361-377)。级别用 `av_log_set_level` 控制;库内所有过滤只看全局级别,没有 per-object 级别。

**Q10:planar 和 packed 音频格式怎么选?**
解码/编码器普遍偏好 planar(fltp/s16p),滤波器内部也多为 planar 处理;交给只吃 packed 的外部设备前用 `aformat` 或自动插入的 aresample 转换。`av_get_alt_sample_fmt`/`av_get_packed_sample_fmt` 负责查孪生格式(samplefmt.c:68-93)。

---

## ⑨ 深挖问题(进一步研究的入口)

1. **格式协商不动点的复杂度与可预测性**:`query_formats`(avfiltergraph.c:526-713)每轮扫描全图、EAGAIN 重试,叠加 `reduce_formats`/`swap_sample_fmts` 等启发式;复杂图中能否出现协商结果依赖滤镜枚举顺序(非最优转换路径)的情况?`avfilter_graph_set_auto_convert` 关闭自动转换后协商失败的报错路径长什么样?
2. **`ready` 调度的公平性**:avfilter.c:1377-1381 自述"最终应换成优先队列",当前实现是 `ready` 非零即激活、清零重来;多 sink 图中 `avfilter_graph_request_oldest` 的"最老优先堆"(avfiltergraph.c:1567-1597)与 ready 机制如何交互,是否存在某分支长期饥饿(注释里 concat 反例 avfilter.c:1437 已现端倪)?
3. **framesync 的 `pts + 1` 外推**:EOF PTS 用 `framesync_pts_extrapolate = pts + 1`(framesync.c:238-243)估算,在高帧率/不同 time_base 输入下会不会让 `eof_action=pass` 的尾帧 PTS 抖动?注释说"可用帧率改进"——patch 应从哪条 link 拿 frame_rate?
4. **`sws_is_noop` 与 side data 的一致性**:scale 在 noop 时直接透传(vf_scale.c:872-877),但前文已按 outlink 删过 size/color 依赖的 side data(vf_scale.c:677-685);属性变化但尺寸未变时,透传帧携带的 side data 是否仍是准确的?
5. **自动插入滤镜与线程模型的边界**:slice 线程只在声明 `AVFILTER_FLAG_SLICE_THREADS` 的滤镜内并行(avfilter.c:935-942),帧级并行(不同滤镜同时跑)依赖多线程图(`AVFILTER_FLAG_...`/`graph->execute`);当前 master 中帧级并行由谁驱动——应用多开图,还是图内调度?(可对比同仓库 `pthread.c` 与 N5.0 前的 `slice threading` 演进史)

---

### 附:本篇引用文件清单

| 文件 | 关键内容 |
|---|---|
| libavfilter/avfilter.c | avfilter_link(149)、ff_filter_config_links(328)、ff_filter_frame(1068)、filter_activate_default(1263)、调度注释(1308-1449)、ff_inlink_*(1467-1660) |
| libavfilter/avfilter.h | AVFilter(215)、AVFilterContext(273)、AVFilterLink(367)、AVFilterGraph(561) |
| libavfilter/avfilter_internal.h | FilterLinkInternal(35)、FFFilterContext(99)、FFFilterGraph(138) |
| libavfilter/avfiltergraph.c | graph_config_formats(1366)、avfilter_graph_config(1434)、request_oldest(1567) |
| libavfilter/graphparser.c | filter_parse(338)、segment 五阶段(460-918)、avfilter_graph_parse_ptr(920) |
| libavfilter/framesync.c/.h | 选项(36)、advance(187)、dualinput(372-424)、EXT_*/sync 语义(h:60-163) |
| libavfilter/video.c | 帧池与 ff_get_video_buffer(49-100) |
| libavfilter/filters.h | AVFilterPad(40)、FORWARD 宏(639-712) |
| libavfilter/vf_scale.c | ScaleContext(127)、init(328)、query_formats(451)、config_props(621)、scale_frame(744)、声明(1189) |
| libavutil/mem.c | ALIGN(65)、av_malloc(98)、av_freep(247)、av_fast_*(487-556) |
| libavutil/log.c/.h | 级别表(h:192-238)、默认级别(59)、format_line(320)、默认回调(379) |
| libavutil/rational.c/.h | av_reduce(35)、四则(80-108)、av_d2q(110)、AVRational(h:58) |
| libavutil/time.c | av_gettime(40)、av_gettime_relative(57)、av_usleep(93) |
| libavutil/error.c | AVERROR_LIST(30)、av_strerror(134) |
| libavutil/samplefmt.c | 格式表(37-49)、buffer_size(121)、fill_arrays(153) |
