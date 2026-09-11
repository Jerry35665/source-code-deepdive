# 第 04 章 · 滤镜图框架与核心工具库:activate 调度与有理数时间戳

> 基线:commit `9f63b36a`。行号以 libavfilter/ 和 libavutil/ 为准。
> 勘误:任务书中提到的 `libavfilter/filters.c` 在当前 master 已不存在——通用滤镜处理已拆分至 avfilter.c(1068-1700)、video.c(49-100)与 filters.h(40、639-712)。

## 4.0 全景:filter 就是 FFmpeg 的"Unix 管道"

| Unix 管道 | FFmpeg 滤镜图 |
|---|---|
| 进程 | 滤镜实例 AVFilterContext |
| stdin/stdout | 输入/输出 pad(AVFilterPad) |
| 匿名管道 | 连接 AVFilterLink(帧 FIFO + 协商参数) |
| `a \| b \| c` | `"scale=1280:720,overlay=W-w:0"` |
| shell 解析器 | graphparser.c |
| select() 就绪通知 | activate 回调 + ready 优先级调度 |

与管道的两个关键差异:① 帧不是字节流——每条链路要先协商时间基/分辨率/像素格式;② 图是多输入多输出 DAG——overlay 有两条输入,需要跨流帧对齐(framesync)。

## 4.1 三层抽象:AVFilter / AVFilterContext / AVFilterLink

- **AVFilter**(avfilter.h:215-260):静态"类"。name、pad 数组、priv_class(配置 schema)、flags。全进程只读共享;
- **AVFilterContext**(avfilter.h:273-353):实例。input/output pads、priv(私有状态如 ScaleContext)、graph 回指针;
- **AVFilterLink**(avfilter.h:367-427):连接。协商结果(format/w/h/time_base)+ FIFO + 四个调度状态字段。

**"公有头 + 私有体"的廉价继承**贯穿全库(avfilter_internal.h:35-92):

```c
typedef struct FilterLinkInternal {
    FilterLink l;              // 公有部分在首地址
    FFFrameQueue fifo;         // 该输入上待处理的帧队列
    int frame_wanted_out;      // 下游是否在要帧
    int frame_blocked_in;      // 上游暂时产不出帧,避免重复 request
    int status_in, status_out; // 链路两端各自看到的 EOF/错误
} FilterLinkInternal;
```

`avfilter_graph_config` 五步收尾(avfiltergraph.c:1434-1452):合法性检查 → 格式协商(反复调 query_formats 直到无 EAGAIN)→ 逐 link config_props 落地时间基 → 检查 → 构建 sink 链路"年龄堆"。运行期"最老优先"驱动 sink——**防多输出图饿死的简单而有效的策略**。

## 4.2 activate 模型:状态机 + 就绪标记

老 API 是"推"(filter_frame)+"拉"(request_frame)两个回调,多输入滤镜容易死锁。新 API 把决策权一次性交给滤镜:框架只保证"调用 activate 时世界可能变了",滤镜自己在回调里轮询所有输入输出。

没写 activate 的老滤镜走 `filter_activate_default`(avfilter.c:1263-1306)四段固定优先级:① 处理就绪帧 → ② 传播输入 EOF → ③ 转发要帧请求(先看 `frame_blocked_in` 防死循环)→ ④ sink 请求输入。

**avfilter.c:1308-1449 有一段以百行计的设计注释**,逐字段解释 `frame_wanted_out`/`frame_blocked_in`/`fifo`/`status_in`/`status_out` 的状态机——是源码里最值得通读的文档,没有之一。

## 4.3 libavutil 核心件

### 有理数:音视频时间戳的基础

`AVRational{num, den}` 用分数精确表示时间基(如 1/90000)。`av_reduce`(rational.c:35-78)用**连分数做分母受限的最佳逼近**并告知是否精确;`av_rescale_q` 是所有跨时间基换算的单一入口——**PTS 为何用分数不用 double:分数可精确表示 1/90000 而 double 不能**。

### 内存与日志

`av_malloc` 对齐到 `ALIGN`(32/64 位平台均 32/64 字节,mem.c);`av_log` 九级 + 子系统掩码、链式 log(与 Nginx 卷同构)。

## 4.4 FAQ

**Q1:filter graph 字符串怎么变成图?**
五阶段:`parse → create_filters → apply_opts → init → link`(graphparser.c:882-918);"逗号分隔=串行链,分号分隔=多分支"。

**Q2:overlay 怎么对齐两路输入的帧?**
framesync.c 维护每路输入的"下一帧时间戳",activate 时选最老的拉取,超前的等——**最老优先,与 K8s 的 sink 年龄堆思路同源**。

**Q3:AVRational 为什么不用 double?**
1/90000 不能精确表示为 double(二进制循环小数);分数运算无累积误差。

**Q4:activate 和老 API 的区别?**
老 API 推/拉分离容易死锁;activate 把决策权一次性交给滤镜,框架只保证"调用时世界可能变了"。

**Q5:滤镜图的背压怎么实现?**
`max_buffered_frames`(avfilter.h:608)限制每条 link 的 FIFO 深度;满了丢帧或阻塞(可配置)。

## 4.5 小结与深挖方向

本章结论:**filter = "三层抽象 + activate 状态机调度 + 连分数时间戳"**;avfilter.c:1308-1449 的百行设计注释是全库最值得通读的文档。深挖:

1. `framesync` 的 EOF 不对称传播策略;
2. `graphparser` 的新旧 API 兼容层(AVFilterGraphSegment);
3. `vf_scale` 的 sws 接口参数传递链;
4. `av_reduce` 连分数逼近的数学证明。

> 下一章:mux 框架、硬件加速与工程文化。
