# FFmpeg 源码调研报告:明星视频滤镜族——框架概念如何落地

> 调研对象:commit `9f63b36a`(master)。所有行号均为仓库相对路径 `libavfilter/...` 下的实际行号,已用 grep/Read 逐一核对。
> 前置章节(04 章)已讲滤镜图框架:activate 调度、framesync、有理数时间戳。本章回答"具体滤镜怎么实现这些回调"。

---

## 1. 全景表:七个滤镜的回调组合

| 滤镜 | 文件 | 驱动模式 | 输入数 | 是否改 outlink 属性 | 表达式系统 |
|---|---|---|---|---|---|
| scale | vf_scale.c | **activate + framesync**(单输入也走 framesync) | 1(用到 ref 变量时动态加到 2) | 是(w/h/SAR,config_props) | init/frame 双模式 |
| overlay | vf_overlay.c | activate + framesync(dualinput) | 2(main/overlay) | 是(继承 main 的 w/h/tb,config_output) | x/y,init/frame 双模式 |
| crop | vf_crop.c | **filter_frame**(被动) | 1 | 是(w/h/SAR,config_output) | w/h 仅 init;x/y 每帧 |
| pad | vf_pad.c | filter_frame(被动) | 1 | 是(w/h,config_output) | init/frame 双模式 |
| settb | settb.c | activate(手写单输入循环) | 1 | 是(time_base,config_output_props) | tb 表达式仅 init |
| fps | vf_fps.c | activate(手写,带 2 帧缓冲) | 1 | 是(frame_rate=tb 倒数,config_props) | fps 表达式仅 init |
| eq | vf_eq.c | filter_frame(被动) | 1 | 否 | 8 个参数,init/frame 双模式 |
| drawtext | vf_drawtext.c | filter_frame(被动) | 1 | 否 | x/y/alpha/fontsize 每帧 + 文本展开 |

两个"意外事实"(与旧文档印象不同):

1. **scale 在当前 master 上不再是纯 filter_frame 滤镜**。`ff_vf_scale` 注册了 `.activate`(vf_scale.c:1201),activate 只有一句 `return ff_framesync_activate(&scale->fs)`(vf_scale.c:1035-1039);framesync 在 `config_props` 里以单输入方式初始化,`in[0].sync=1`、before/after 都是 `EXT_STOP`(vf_scale.c:687-708)。带 `filter_frame` 的 pad 表(vf_scale.c:1230-1241)只属于已废弃的 scale2ref(vf_scale.c:1258-1270)。
2. **settb 与 fps 标记 `AVFILTER_FLAG_METADATA_ONLY`**(settb.c:179、vf_fps.c:393):它们不触碰像素,调度器因此可对其做更激进的优化(如跳过格式协商细节),这是"时间戳手术"滤镜的类别标签。

回调风格的两类写法:
- **framesync 型**(scale/overlay):init 里设 `fs.on_event = do_xxx`(vf_overlay.c:896、vf_scale.c:692),activate 全权委托 `ff_framesync_activate`(framesync.c:352-370),真正的处理发生在 on_event 回调里。
- **被动型**(crop/pad/eq/drawtext):在输入 pad 上挂 `.filter_frame`(vf_crop.c:375、vf_pad.c:449、vf_eq.c:307、vf_drawtext.c:1951),来一帧处理一帧,完全不需要自己拉取数据。

---

## 2. vf_scale:libswscale 的"适配器"

### 2.1 与 swscale 的衔接点

关键结论:**master 上的 scale 不再调用 `sws_getContext`**。衔接链是:

1. `preinit` 里 `sws_alloc_context()` 空造一个 SwsContext(vf_scale.c:310-324,核心在 314 行),只是占位;线程数默认留 0,后续在 init 里若用户未显式设置则取滤镜线程数 `ff_filter_get_nb_threads(ctx)`(vf_scale.c:425-426)。
2. sws 上下文本身作为 AVClass 子对象暴露给选项系统(`child_class_iterate` 返回 `sws_get_class()`,vf_scale.c:1041-1053),所以用户能直接写 `scale=flags=bicubic` 这类 sws 选项。
3. 每帧真正调用 `sws_scale_frame(scale->sws, out, in)`(vf_scale.c:884)。该函数在 libswscale 内部做惰性初始化:`sws_frame_setup` 按帧的格式/尺寸装配缩放图(libswscale/swscale.c:1428),即"设置一次选项、每帧按需建图"的新 API 风格。

`sws_is_noop(out, in)` 判断"什么都没变"则直接把输入帧原样返回,避免空转(vf_scale.c:872-877)。

### 2.2 表达式:w/h/iw/ih 与求值顺序

变量表在 vf_scale.c:46-82(`in_w/iw`、`out_w/ow`、`a/sar/dar/hsub/vsub`、`n/t`,以及 scale2ref 遗留的 `main_*` 和新式 `ref_*`)。数值填充在 `scale_eval_dimensions`(vf_scale.c:532-619):

- out_w/out_h 先置 NAN,先求 w、再求 h、**再求一遍 w**(591-608 行),因为 `h` 可能引用刚求出的 `ow`;crop/pad 也是同款两轮求值(见第 4 节)。
- `check_exprs` 静态扫描表达式引用的变量集:禁止 w 引用 ow(自引用,vf_scale.c:197-205),w、h 互引则告警(207-210),init 模式下引用 `n/t/pos` 直接报错(244-252)。

`eval` 选项决定重算时机(vf_scale.c:1158-1160):`init`(默认)只在 config 时求一次;`frame` 模式每帧重算。每帧行为在 `scale_frame`(vf_scale.c:744-812):若 `eval_mode==EVAL_MODE_FRAME` 或输入属性发生变化(frame_changed 判定在 758-764 行,含宽高/格式/SAR/色彩空间/范围七项),就把输入属性写回 inlink、重新走一遍 `config_props(outlink)`(803-811 行),**等于动态重建 outlink 与 sws 图**——这是"动态分辨率视频"能过 scale 的原因。n/t 变量在 799-801 行更新。

### 2.3 色彩空间/范围的透传与约束

- `query_formats` 用 `sws_test_format` 过滤像素格式(vf_scale.c:463-481);若用户指定了 `out_color_matrix`/`out_range`,则把输出约束收窄成单元素列表,强迫协商器选中它(vf_scale.c:502-521)。
- 运行期,in_* 选项强制覆盖输入帧的色彩元数据(vf_scale.c:824-832),out_* 写回输出帧与 outlink(841-851);SAR 用 `av_reduce` 按"像素面积守恒"重算(863-870)。
- 尺寸变化时清掉尺寸相关 side data,色彩语义变化时清掉色彩相关 side data(vf_scale.c:677-685 与 853-861),避免陈旧元数据随帧泄漏。

config_props 中 `ff_scale_adjust_dimensions` 处理 `force_original_aspect_ratio`/`force_divisible_by`(vf_scale.c:643-645;实现 libavfilter/scale_eval.c:123)。

---

## 3. vf_overlay:framesync 双输入消费模式

### 3.1 配置:一条主链 + 一条副链

`config_output` 里调 `ff_framesync_init_dualinput`(vf_overlay.c:343;实现 framesync.c:372-388):主输入 sync=2、副输入 sync=1,副流 before=EXT_NULL、after=EXT_INFINITY。outlink 尺寸与时间基**直接继承 main 输入**(vf_overlay.c:346-348)。framesync 的三个用户选项挂在滤镜私有选项里(vf_overlay.c:913-933):`eof_action`(repeat 默认/endall/pass)、`shortest`(默认 0)、`repeatlast`(默认 1);`FRAMESYNC_DEFINE_CLASS` 宏(framesync.h:352-353)让这些选项作为子对象透出(vf_overlay.c:942)。

### 3.2 activate 推进:帧事件循环

滤镜 activate 就是 `ff_framesync_activate(&s->fs)`(vf_overlay.c:900-904)。framesync.c 的推进逻辑分四步:

```c
// framesync.c:187-236(framesync_advance 摘要)
while (!(fs->frame_ready || fs->eof)) {
    ret = consume_from_fifos(fs);          // 从各输入 FIFO 拉帧/拉状态
    ...
    pts = INT64_MAX;                        // 取所有输入 pts_next 的最小值
    for (i = 0; i < fs->nb_in; i++)
        if (fs->in[i].have_next && fs->in[i].pts_next < pts)
            pts = fs->in[i].pts_next;
    ...
    for (i = 0; i < fs->nb_in; i++) {
        if (fs->in[i].pts_next == pts || ...) {  // 推进该输入到新帧
            ...
            fs->in[i].state = fs->in[i].frame ? STATE_RUN : STATE_EOF;
            if (fs->in[i].sync == fs->sync_level && fs->in[i].frame)
                fs->frame_ready = 1;              // 只有最高 sync 层的帧触发事件
        }
    }
    fs->pts = pts;
}
```

要点:**每路输入统一换算到 framesync 的时间基**(inject 时 `av_rescale_q_rnd`,framesync.c:251),事件时间基取所有 sync 输入时间基的 GCD(framesync.c:160-177)。`sync` 等级的语义见 framesync.h:149-160——只有最高等级输入的帧才产生"帧事件";某路 EOF 后其 sync 降为 0(framesync.c:261),全部归零则整图 EOF(framesync.c:131-134)。

EOF 策略在 `ff_framesync_configure` 里归一化(framesync.c:141-158):`repeatlast=0` 等价于 eof_action=pass;`shortest=1` 等价于把所有输入 after 改成 `EXT_STOP`(该输入结束就全体结束)。三种 EXT 模式的定义在 framesync.h:60-76。

### 3.3 do_blend:取帧、判直通、切片并行

`do_blend`(vf_overlay.c:845-890)是 on_event 回调:

```c
// vf_overlay.c:854-858
ret = ff_framesync_dualinput_get_writable(fs, &mainpic, &second);
if (ret < 0)
    return ret;
if (!second)
    return ff_filter_frame(ctx->outputs[0], mainpic);   // 副流缺席:主帧直通
```

- `dualinput_get_writable`(framesync.c:410-424)= `dualinput_get`(主帧 pts 重定回 outlink 时间基,framesync.c:402)+ `ff_inlink_make_frame_writable`(要就地混合,必须可写)。主帧是否需要 clone 由 `ff_framesync_get_frame(get=1)` 决定:若另一个 sync 流的当前帧会活得更久,就 clone 一份,否则直接拿走所有权(framesync.c:281-294)。
- `eval=frame` 模式(默认,vf_overlay.c:919)每帧重算 x/y:更新 n/t/W/H/w/h 变量后 `eval_expr`(vf_overlay.c:860-876);x 表达式可能引用 y,所以求两遍(96-106 行)。
- 混合本身走 `ff_filter_execute` 切片并行(vf_overlay.c:886-887),blend 函数指针由格式在 `init_slice_fn` 里选定(760-843 行),x86 SIMD 挂钩在 838-840 行。混色核心是 alpha 混合:`FAST_DIV255` 快速除法(vf_overlay.c:355)、straight/premultiplied 四组合由后缀 `_ss/_sp/_ps/_pp` 宏展开(705-709 行)。

---

## 4. 几何滤镜:crop 与 pad

### 4.1 crop:零拷贝裁剪 = 移动 data 指针

crop 的 outlink 重算发生在**输出 pad 的 config_output**(vf_crop.c:233-248):`link->w = s->w; link->h = s->h;`(242-243 行),SAR 按 keep_aspect 重算(config_input 里,vf_crop.c:199-205);硬件像素格式例外——不改尺寸,靠 crop 元数据(vf_crop.c:238-241)。

表达式求值:宽高只在 config_input 求一次,同样是"先 w、后 h、再 w"两轮(vf_crop.c:160-175);非 exact 模式把 w/h/x/y 向下对齐色度子采样(vf_crop.c:185-188、222-225)。x/y 是每帧求值(filter_frame,vf_crop.c:261-264),求两遍的原因与 overlay 相同("It is necessary if x is expressed from y"),随后 clamp 到画面内(269-276 行)。

核心操作是指针平移而非拷贝:

```c
// vf_crop.c:292-302(软帧分支)
frame->width  = s->w;
frame->height = s->h;

frame->data[0] += s->y * frame->linesize[0];
frame->data[0] += s->x * s->max_step[0];

if (!(desc->flags & AV_PIX_FMT_FLAG_PAL)) {
    for (i = 1; i < 3; i ++) {
        if (frame->data[i]) {
            frame->data[i] += (s->y >> s->vsub) * frame->linesize[i];
            frame->data[i] += (s->x * s->max_step[i]) >> s->hsub;
```

色度平面按 hsub/vsub 缩放偏移,alpha 平面单独处理(308-311 行)。这解释了 query_formats 为何拒绝 bitstream 与"SW_FLAT_SUB"格式(vf_crop.c:92-100)——平移指针要求平面布局规整。

### 4.2 pad:可能零拷贝的"外框填补"

pad 用 drawutils(`FFDrawContext`)做像素格式无关的填色:`config_input` 里 `ff_draw_init_from_link` + `ff_draw_color`(vf_pad.c:117-122),`color` 选项默认 black(vf_pad.c:433)。表达式同样是两轮求值(vf_pad.c:135-181),且 x/y 越界自动回中(183-186 行),所有几何量经 `ff_draw_round_to_sub` 对齐色度(188-199 行)。

outlink 重算极简:`config_output` 只写 `outlink->w/h = s->w/s->h`(vf_pad.c:226-233)。

pad 的精髓是**尝试在输入 buffer 上原地 pad**:

- `get_buffer.video` 钩子(vf_pad.c:448,实现 235-262 行)向上游申请比输入更大的输出尺寸 buffer,再把 data 指针推进到 (x,y) 处——如果上游配合,四周边框区是现成的。
- `frame_needs_copy`/`buffer_needs_copy`(vf_pad.c:317-328、265-315)逐 plane 检查 buffer 前后空隙与 plane 间距,判断能否免拷贝。
- filter_frame 里:能原地就把 data 指针往回退(375-383 行),否则分配新帧并 `ff_copy_rectangle2`(404-408 行);四条边用 `ff_fill_rectangle` 按序填充 top/bottom/left/right(vf_pad.c:386-413)。`eval=frame` 模式下输入属性变化会触发 config_input/config_output 重跑(vf_pad.c:336-359)。

---

## 5. 时间戳手术:settb 与 fps

两者都是 `AVFILTER_FLAG_METADATA_ONLY`(settb.c:179、vf_fps.c:393)。

### 5.1 settb:重定时间基的"换算器"

- `config_output_props`(settb.c:72-107):把 AVTB/intb/sr 三个变量代入 tb 表达式(默认 `"intb"`,settb.c:65-68),`av_d2q` 转成有理数并检查为正(93-99 行),写 `outlink->time_base`(101 行),同时复制 w/h(85-86 行)。
- `rescale_pts`(settb.c:109-122):单点换算函数,`av_rescale_q(orig_pts, inlink->time_base, outlink->time_base)`。
- activate(settb.c:135-160)是手写的最小单输入循环:`FF_FILTER_FORWARD_STATUS_BACK` → `ff_inlink_consume_frame` → filter_frame(129-130 行换算 pts 与 duration)→ `ff_inlink_acknowledge_status` 时**连 EOF 的 pts 也一起换算**再 `ff_outlink_set_status`(152-155 行)→ `FF_FILTER_FORWARD_WANTED`。EOF 时间戳换算是下游对齐的关键细节。

### 5.2 fps:丢帧/复制的状态机

fps 把时间基**定死为目标帧率的倒数**(vf_fps.c:198-199):

```c
// vf_fps.c:198-199
ol->frame_rate      = av_d2q(res, INT_MAX);
outlink->time_base  = av_inv_q(ol->frame_rate);
```

运行期维护 `AVFrame *frames[2]` 的小缓冲(vf_fps.c:87)与 `next_pts`(91 行,期望输出时间轴)。activate(vf_fps.c:326-379)的策略:

1. 缓冲未满 2 帧就尽量读入(`read_frame`,内部把输入 pts 按 start_time 偏移+舍入方式换算到输出时间基,vf_fps.c:248-251)。
2. 不足 2 帧且无 EOF → 请求上游继续(`FF_FILTER_FORWARD_WANTED`,357 行)。
3. `write_frame`(vf_fps.c:264-314)的丢弃/复制判定:

```c
// vf_fps.c:290-306(摘要)
if ((s->frames_count == 2 && s->frames[1]->pts <= s->next_pts) ||
    (s->status            && s->status_pts     <= s->next_pts)) {
    frame = shift_frame(ctx, s);        // 下一帧已能顶上(或 EOF 已到):
    av_frame_free(&frame);              // 丢弃当前缓冲帧
    ...
} else {
    frame = av_frame_clone(s->frames[0]);  // 输出时间轴还没到下一输入帧:
    ...
    frame->pts = s->next_pts++;            // 复制当前帧,pts 沿目标网格推进
    frame->duration = 1;
```

即:**第二帧的时间戳已 `<= next_pts` 说明第一帧在输出网格上多余 → 丢;反之输出网格点还没等到新帧 → clone**。`shift_frame` 顺手统计 dup/drop(vf_fps.c:145-155),uninit 打印"in/out/drop/dup"汇总(172-173 行)。`eof_action=pass` 时 EOF pts 用 `AV_ROUND_UP` 收尾(vf_fps.c:317-324)。单次 activate 产出一帧后用 `ff_filter_set_ready(ctx, 100)` 把自己重新排进调度(vf_fps.c:367-368)——这就是 04 章 activate 调度"滤镜自己声明还有活干"的实例。另附带 closed-caption FIFO 防止复制帧时字幕重复(vf_fps.c:256、303-304)。

---

## 6. 参数化滤镜:eq(附 fade 一句)

eq 有 8 个字符串参数(contrast/brightness/saturation/gamma/gamma_r/g/b/gamma_weight),全部是表达式(vf_eq.c:316-331,均 TFLAGS 运行时参数,314 行)。三层结构值得写进文章:

1. **每帧重算标量**:filter_frame 在 `EVAL_MODE_FRAME` 时调 set_gamma/set_contrast/set_brightness/set_saturation(vf_eq.c:243-248),每个 set_* 内部 `av_expr_eval` + clip + `lut_clean=0`(如 set_contrast,vf_eq.c:89-95)。
2. **调度到三档实现**:`check_values`(vf_eq.c:79-87)——参数全默认则 `adjust=NULL`(平面直接拷贝);gamma==1 且 |contrast|<7.9 走 `eq->process`(SIMD 逐像素);否则走 256 项查找表 `apply_lut`(64-77 行),LUT 由 `create_lut` 惰性重建(39-62 行)。"参数变化 → 只置脏标记 → 下帧重建 LUT"是典型的缓存失效模式。
3. **运行时命令**:`process_command` 支持逐参数热更(vf_eq.c:284-301),init 模式下立即生效,frame 模式下下帧生效。

对比:fade(vf_fade.c)没有表达式系统,而是一个 `WAITING/FADING/DONE` 三态状态机,按帧数或时长线性推进 factor(16.16 定点),OUT 方向取反(vf_fade.c:469-512),最后同样 `ff_filter_execute` 分平面切片(514-532 行);输入 pad 标 `AVFILTERPAD_FLAG_NEEDS_WRITABLE`(574 行)因为要就地改像素。两者放一起正好展示"参数化滤镜"的轻/重两档。

---

## 7. drawtext:逐帧文本渲染(主流程)

drawtext 也是被动 filter_frame(vf_drawtext.c:1951),pad 标 NEEDS_WRITABLE(1950 行)。每帧流程:

1. **文本刷新**:`reload` 选项控制每 N 帧重读 textfile(vf_drawtext.c:1902-1914)。
2. **帧级变量**:n/t/pict_type/duration/metadata 填入 var_values(vf_drawtext.c:1916-1923)。
3. **文本展开**(`draw_text`,vf_drawtext.c:1598 起):`exp_mode` 三档——EXP_NONE 原样、EXP_NORMAL 走 `ff_expand_text` 函数式展开(`%{pts:hms}`、`%{metadata:...}` 等,函数表 955-967 行)、EXP_STRFTIME(1630-1642 行);`fontcolor_expr` 支持每帧算颜色(1654-1666 行);`update_fontsize` 让字号也可表达式化(1668 行)。
4. **度量**:measure_text 得到 text_w/text_h/max_glyph_* 等变量填回 var_values(1672-1691 行)——所以 x 表达式可以写 `(w-text_w)/2`。
5. **x/y/alpha 每帧求值**:x 求两遍(1697-1701 行,与 crop/overlay 同因);`update_alpha` 再算一次 alpha 表达式(1266 行起)。
6. **字形缓存**:渲染过的 glyph 按 UTF-32 码位存进 `struct AVTreeNode *glyphs` 平衡树(vf_drawtext.c:284);命中走 `av_tree_find`(743 行),未命中 `load_glyph` 后 `av_tree_insert`(776 行)。缓存键包含亚像素偏移(shift_x64/y64,723-728 行),uninit 时整树释放(1137-1139 行)。`reinit` 命令则整个换一份 DrawTextContext(vf_drawtext.c:1202-1234)。
7. draw_glyphs 把字形 blit 到帧上(1281 行起),box/shadow/border 在 draw_text 后半段处理(1709 行起)。

不深入字体/HarfBuzz 细节,主流程的要点是:**表达式系统每帧喂两遍(x 两遍、y 一遍)+ 文本展开每帧一次 + 字形树缓存跨帧复用**。

---

## 8. 设计动机

### 8.1 为什么有 filter_frame 与 activate 两种驱动模式

- filter_frame 是"推"模型:数据到了就处理,代码最短,适合**1 进 1 出、逐帧、无缓冲决策**的滤镜(crop/pad/eq/drawtext)。代价是滤镜无法表达"我需要再等一帧才能决定输出什么"。
- activate 是"拉+调度"混合模型:滤镜每次被调度时自查输入就绪度(`ff_inlink_consume_frame` / `ff_inlink_check_available_frame` / `ff_inlink_acknowledge_status`),自己决定产出、请求或休眠(`FFERROR_NOT_READY`),甚至用 `ff_filter_set_ready` 给自己排下一次(vf_fps.c:367-368)。凡是**需要缓冲、需要跨输入对齐、需要在 EOF 时做策略**的滤镜都必须用它(fps 的 2 帧缓冲、settb 的 EOF pts 换算、overlay/scale 的多输入同步)。
- framesync 则是 activate 模式上抽取的"多输入同步"公共库:滤镜只需提供 on_event(vf_overlay.c:896),连 EOF 策略选项都是现成的(framesync.c:36-53)。scale 单输入也走 framesync(vf_scale.c:687-708),因为它的"输入属性变化 → 重配置"逻辑与帧事件天然契合。

### 8.2 为什么几何滤镜必须重算 outlink

滤镜图在协商阶段就固化了每条链接的 w/h/format/time_base(vf_crop.c:242-243、vf_pad.c:230-231、vf_scale.c:636-637)。下游滤镜据此分配 buffer、按尺寸推导变量(crop/pad/scale 的 hsub/vsub 变量全部读自 link)。若只改帧不改 link,下一级的 `ff_get_video_buffer` 尺寸、表达式的 iw/ih 都会错位。因此 crop/pad/scale 都实现了 config_props 重算,并支持 `eval=frame` + `process_command` 动态改几何(crop 的 process_command 直接重跑 config_input/config_output,vf_crop.c:337-345)。同理,settb/fps 必须在 config 阶段定下 time_base,否则整条链的 pts 语义断裂。

### 8.3 表达式系统复用 eval

所有几何/参数表达式都是 `libavutil/eval.c` 的 `AVExpr`:init 时 `av_expr_parse` 一次,每帧仅 `av_expr_eval`(crop:vf_crop.c:261-264;eq:vf_eq.c:91;drawtext:vf_drawtext.c:1697)。变量表采用"全滤镜同款命名"(iw/ih/ow/oh/a/sar/dar/hsub/vsub/n/t),frame 级变量只有 n/t/pos 这类每帧变化的量——init 模式引用它们会被静态拒绝(scale:vf_scale.c:244-252)。解析式 AST 复用 + 数值注入,是"初始化贵、每帧便宜"的标准做法。

---

## 9. FAQ 素材

1. **scale 用的是 sws_getContext 吗?** 不是。preinit 里 `sws_alloc_context`(vf_scale.c:314),每帧 `sws_scale_frame`(vf_scale.c:884),由 libswscale 内部 `sws_frame_setup` 惰性建图(libswscale/swscale.c:1428)。
2. **scale 滤镜是 filter_frame 驱动吗?** 当前 master 不是:单输入 scale 也走 activate+framesync(vf_scale.c:1201、1035-1039);filter_frame 只剩 scale2ref 在用(vf_scale.c:1234、961-973)。
3. **为什么 crop 不分配新 buffer?** 软帧直接平移 `frame->data[i]` 指针(vf_crop.c:295-311),所以它拒绝 bitstream/平面布局不规整的格式(vf_crop.c:96-99);硬帧则改 crop_top/left 等元数据(vf_crop.c:286-290)。
4. **pad 什么时候会拷贝?** `frame_needs_copy` 检查 buffer 可写性与四周边界空隙(vf_pad.c:317-328、265-315);`get_buffer.video` 钩子向上游要大 buffer(vf_pad.c:448、235-262),上游配合则全程零拷贝。
5. **overlay 的 shortest/repeatlast/eof_action 什么关系?** configure 时归一:repeatlast=0 ⇔ eof_action=pass;shortest=1 ⇔ 全输入 after=EXT_STOP(framesync.c:141-158)。默认 repeatlast=1、shortest=0(framesync.c:43-44)。
6. **framesync 怎么决定"该出一帧了"?** 只有 `sync` 等级等于当前最高等级的输入产生帧事件(framesync.h:149-160;framesync.c:221-222);EOF 后该输入 sync 降 0(framesync.c:261),全降完则整体 EOF(131-134)。
7. **fps 滤镜怎么决定丢还是复制?** 缓冲两帧看第二帧 pts:已 `<= next_pts` 则丢第一帧,否则 clone 第一帧并把 pts 沿 1/out_frame_rate 网格推进(vf_fps.c:290-306)。
8. **settb 连 EOF 都管吗?** 管。EOF 状态携带的 pts 也经 `rescale_pts` 换算后传给下游(settb.c:152-155)。
9. **eq 为什么快?** 参数命中"无操作/线性"时跳过 LUT:`check_values` 三档调度 no-op/SIMD/256 项 LUT,参数变化只置 `lut_clean=0` 惰性重建(vf_eq.c:79-87、39-62)。
10. **drawtext 每帧都重新光栅化文字吗?** 否。字形按码位+亚像素偏移缓存在 AVTree(vf_drawtext.c:284、743、776),只有新字形才走 FreeType;但表达式与文本展开确实每帧重算(1697-1701、1630-1642)。

## 10. 深挖线索

1. **framesync 的 need_copy 决策**:`ff_framesync_get_frame(get=1)` 时扫描其他 sync 流的 pts_next,判断当前帧是否还会被后续事件引用,决定 clone 还是转移所有权(framesync.c:281-294)——一个精巧的零拷贝条件。
2. **`ts_sync_mode`**:TS_DEFAULT 取"≤ 主帧时间的最近副帧",TS_NEAREST 取绝对最近(framesync.h:84-97、framesync.c:207-211),对副流帧率高于主流的场景有意义。
3. **scale 的 side data 清理**:尺寸相关/色彩相关的帧与链接 side data 在变化时被精确移除(vf_scale.c:677-685、853-861),是元数据正确性的现成范例。
4. **fps 的 ccfifo**:复制帧时闭字幕数据被抽走不随帧重复(vf_fps.c:256、303-304),可引申"复制一帧 ≠ 复制所有附件"。
5. **pad 的 get_buffer 钩子**:上游分配时就预留边框(vf_pad.c:235-262),可与 buffer_needs_copy 的几何判断(265-315)合讲"滤镜间 buffer 协商"。

---

## 11. 写作要点速查表

| 事实 | 位置 |
|---|---|
| scale:sws_alloc_context(preinit) | vf_scale.c:314 |
| scale:sws_scale_frame 每帧调用 | vf_scale.c:884(sws_frame_setup:libswscale/swscale.c:1428) |
| scale:单输入也 init framesync(sync=1,EXT_STOP) | vf_scale.c:687-708 |
| scale:activate=ff_framesync_activate | vf_scale.c:1035-1039(注册 1201) |
| scale:表达式两轮求值 + frame 模式重配置 | vf_scale.c:591-608、766-812 |
| scale:SAR 面积守恒重算 | vf_scale.c:863-870 |
| overlay:ff_framesync_init_dualinput(outlink 继承 main) | vf_overlay.c:343-348(framesync.c:372-388) |
| overlay:on_event=do_blend + dualinput_get_writable | vf_overlay.c:896、854 |
| framesync:advance 取最小 pts_next 推进帧事件 | framesync.c:187-236 |
| framesync:EOF 策略归一 + 时间基 GCD | framesync.c:141-158、160-177 |
| framesync:sync 等级语义 | framesync.h:149-160;framesync.c:261 |
| crop:outlink w/h 重算 + data 指针平移 | vf_crop.c:242-243、295-311 |
| crop:x/y 每帧求两遍 | vf_crop.c:261-264 |
| pad:ff_draw_init/ff_draw_color + 四边填充 | vf_pad.c:117-122、386-413 |
| pad:get_buffer 钩子 + needs_copy 判定 | vf_pad.c:448/235-262、265-328 |
| settb:outlink time_base 表达式 + EOF pts 换算 | settb.c:72-107、152-155 |
| fps:time_base=1/frame_rate;丢/复制判定 | vf_fps.c:198-199、290-306 |
| fps:set_ready 自我再调度 | vf_fps.c:367-368 |
| eq:check_values 三档调度 + LUT 惰性重建 | vf_eq.c:79-87、39-62 |
| drawtext:x/y 每帧求值 + 字形 AVTree 缓存 | vf_drawtext.c:1697-1701、284/743/776 |
