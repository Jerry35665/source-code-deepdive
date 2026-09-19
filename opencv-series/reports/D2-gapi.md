# 报告 D2 · gapi 图 API 与异构执行(OpenCV 卷二)

- 系列:《源码深读 · OpenCV 卷二》
- 基线:`repos/opencv` commit `d3d247f1e3125f03171e59ed8fd2fe9454b8ee5f`(4.13.0-dev)
- 一句话总结:G-API 把 C++ 表达式编译成 ADE 数据流图,在编译期用 kernel 包静态选定每算子的 backend、把同 backend 算子融合为 Island,再由可替换执行器(同步/多线程/流式 actor)驱动 Fluid 等各后端执行——异构选择发生在编译期,与卷一 T-API 的运行时瀑布是两个层次。
- 正文所有 `文件:行号` 相对仓库根,均经本次逐条核对。

---

## 1. 编程模型:GMat 是一张"出身证明"(类型擦除)

GMat 等图类型不持有像素,只包一个 `shared_ptr<GOrigin>`;GOrigin 记录"这个数据由哪个节点、第几个端口产出"(modules/gapi/src/api/gorigin.hpp:25-37):

```cpp
struct GOrigin
{
    ...
    const GShape          shape;   // 产出对象的形状类别
    const GNode           node;    // 产出该对象的节点
    const gimpl::ConstVal value;   // 常量初值(值初始化 GMat)
    const std::size_t     port;    // GNode 的输出端口号
    gimpl::HostCtor       ctor;
    detail::OpaqueKind    kind;
};
```

GMat 的三种构造对应"空图起点 / 常量输入 / 算子输出"三种身份(modules/gapi/src/api/gmat.cpp:19-31);类声明见 modules/gapi/include/opencv2/gapi/gmat.hpp:67-99。GMatP、GFrame、GScalar、GArrayU、GOpaqueU 同构,统一收进 variant `GProtoArg`。`GIn/GOut` 只是给参数包打上 In/Out 标签(modules/gapi/include/opencv2/gapi/gproto.hpp:92-103):

```cpp
using GProtoInputArgs  = GIOProtoArgs<In_Tag>;
using GProtoOutputArgs = GIOProtoArgs<Out_Tag>;
template<typename... Ts> inline GProtoInputArgs GIn(Ts&&... ts)
{
    return GProtoInputArgs(detail::packArgs(std::forward<Ts>(ts)...));
}
```

编译器对图的一切操作都通过 `proto::origin_of()` 从 variant 里"拆箱"取出 GOrigin(modules/gapi/src/api/gproto.cpp:21-44),这是全部类型擦除的枢纽。`GComputation` 仅保存 `Priv::Expr{m_ins, m_outs}`(或反序列化 Dump),构造函数按转发收尾(modules/gapi/src/api/gcomputation.cpp:93-97)。

执行入口 `apply` 先 `recompile` 再调用缓存的可执行对象(modules/gapi/src/api/gcomputation.cpp:213-217);`recompile` 并非每次重编:输入 meta 未变直接复用 `m_lastCompiled`,仅 depth/chan 相同还允许走 `reshape` 免重编(modules/gapi/src/api/gcomputation.cpp:188-211)。`compile(GMetaArgs, GCompileArgs)` 构造 `GCompiler` 并调 `comp.compile()`(gcomputation.cpp:118-123)。

## 2. 编译管线:GCompiler 六段 pass

GCompiler 构造函数即管线装配处(modules/gapi/src/compiler/gcompiler.cpp:220-300):`init`(check_cycles → apply_transformations → expand_kernels → topo_sort → init_islands → check_islands)→ `kernels`(bind_net_params → resolve_kernels → check_islands_content)→ `intrin`(desync/finalizeIntrin)→ `meta`(initMeta/inferMeta/storeResultingMeta)→ `transform`(后端自留空段)→ `exec`(fuse_islands → sync_island_tags → add_streaming → sort_islands → 可选 dump_dot)。总流程四步(gcompiler.cpp:500-506):

```cpp
cv::GCompiled cv::gimpl::GCompiler::compile()
{
    std::unique_ptr<ade::Graph> pG = generateGraph();   // 表达式 -> ADE 图
    runPasses(*pG);                                     // 全部 pass
    compileIslands(*pG);                                // 每 Island 调后端编译
    return produceCompiled(std::move(pG));              // 选执行器,包成 GCompiled
}
```

要点:(a) 图由 `GModelBuilder::put(unrollExpr(...))` 从表达式反向遍历展开(modules/gapi/src/compiler/gmodelbuilder.cpp:62-205,gcompiler.cpp:548-568);(b) `apply_transformations` 把用户注册的 pattern→substitute 图重写循环应用到不动点(gcompiler.cpp:222-224;modules/gapi/src/compiler/passes/transformations.cpp:101-139);(c) `expand_kernels` 把 compound kernel 展开成真实子图(kernels.cpp:234-259);(d) `compileIslands` 对每个 Island 节点调 `backend.priv().compile(orig_g, args, ops, ins, outs)` 产出 `GIslandExecutable`(modules/gapi/src/compiler/gislandmodel.cpp:268-320);(e) `produceCompiled` 按 compile arg 决定 GExecutor 还是 GThreadedExecutor(gcompiler.cpp:456-464);流式版本 `compileStreaming` 额外打 `Streaming{}` 标记并只在有 meta 时编 Island(gcompiler.cpp:508-520)。

## 3. Islands:静态亲和度 + 同后端融合,而非"自动最优切分"

islands pass(modules/gapi/src/compiler/passes/islands.cpp)只做两件事:`initIslands` 把用户用 `cv::gapi::island(name, GIn(...), GOut(...))` 打在算子上的标签传播到两侧数据节点(islands.cpp:72-94,标签源头在 gcomputation.cpp:307-356);`checkIslands` 用 flood-fill 禁止同名不连通岛(islands.cpp:100-202)。真正决定"子图归哪个 backend"的是更早的 `resolveKernels`:对每个算子按 kernel id 在包里做一次**静态** lookup,写死 `op.backend`(modules/gapi/src/compiler/passes/kernels.cpp:168-232);同名岛必须同 backend,否则报错(islands.cpp:204-233)。随后 `fuse_islands` 反向合并:`fusionIsTrivial` 判定"单后端、无用户岛、无 desync"时整图并成一个 Island(modules/gapi/src/compiler/passes/exec.cpp:57-84),否则沿拓扑序按 `canMerge` 逐对融合(exec.cpp:176-220):

```cpp
// Islands with different affinity can't be merged
if (a_ptr->backend() != b_ptr->backend())
    return false;
...                                    // 会成环的、用户岛与非用户岛之间不可合并
if (    this_backend_p.controlsMerge()
    && !this_backend_p.allowsMerge(g, a_nh, slot_nh, b_nh))
    return false;
```

即:图的异构划分 = 编译期 kernel 静态选择 + 用户手工 island 边界 + 同后端贪心融合;全程没有任何代价模型或运行时探测。

### 3.1 两级图:GModel 与 GIslandModel

islands 切分后,编译器面对的不再是算子图,而是"Island 图":GIslandModel 把原 GModel(算子/数据两级)折叠成 ISLAND/SLOT/EMIT/SINK 四种节点(gislandmodel.cpp:268-320 处按此遍历)。节点元数据结构如下(modules/gapi/src/compiler/gislandmodel.hpp:204-233):

```cpp
enum { ISLAND, SLOT, EMIT, SINK} k;        // NodeKind
struct FusedIsland { std::shared_ptr<GIsland> object; };
struct DataSlot
{
    ade::NodeHandle original_data_node;    // 直连 GModel 的原始数据节点
};
struct IslandExec
{
    std::shared_ptr<GIslandExecutable> object;
};
struct Emitter { std::size_t proto_index; std::shared_ptr<GIslandEmitter> object; };
```

SLOT 持有对原 GModel 数据节点的引用,是跨 Island 数据交接点;GExecutor/GStreamingExecutor 都只遍历这层图构造自己的脚本/线程(gexecutor.cpp:37-70)。

## 4. backend 注册:GBackend 句柄与 GKernelPackage 右优先合并

`GBackend` 是 `shared_ptr<Priv>` 的轻句柄,身份即指针 hash(modules/gapi/src/api/gbackend.cpp:92-113),故 `unordered_set<GBackend>` 天然可用。核实现:`GKernelPackage` 内部是 `map<kernel_id, (backend, impl)>`,合并时**右边优先**—— collision 时保留 RHS(modules/gapi/src/api/gkernel.cpp:79-99),多包合并按右折叠(gkernel.hpp:719-721)。编译时的组装(gcompiler.cpp:57-89):

```cpp
static auto ocv_pkg = cv::gapi::combine(cv::gapi::core::cpu::kernels(), ...);
auto user_pkg = cv::gapi::getCompileArg<cv::GKernelPackage>(args);
...
return cv::gapi::combine(ocv_pkg, user_pkg_with_aux);   // 用户包覆盖内建包
```

同时永远并入 meta/streaming 内建核与各后端的 `auxiliaryKernels()`(如推理核,gcompiler.cpp:59-69、199-204)。`use_only` 参数可禁止内建包(gcompiler.cpp:71-73)。运行期数据交换的公共货币是 RMat:GExecutor 把用户 Mat 包成 `RMatOnMat`(modules/gapi/src/executor/gexecutor.cpp:130-145),后端经 `bindRMat` 拿 `RMat::View` 并物化出 `cv::Mat`(gbackend.cpp:127-132),Fluid 直接把这块 Mat 绑进自己的环形 buffer(gfluidbackend.cpp:1250-1255)。

## 5. Fluid:行级流水、环形 buffer"缝合"

Fluid kernel 不是整图函数,而是 `{Kind, LPI, scratch, f, is, rs, b, gw}` 一组回调:产出 LPI 行、可选 scratch、窗口大小(modules/gapi/include/opencv2/gapi/fluid/gfluidkernel.hpp:52-101;Kind 为 Filter/Resize/YUV420toRGB,gfluidkernel.hpp:53-58)。中间数据不再是完整 Mat,而是高度按公式裁剪的环形缓冲(modules/gapi/src/backends/fluid/gfluidbuffer.cpp:521-538):

```cpp
// FIXME? This formula serves general case to avoid possible deadlock,
// 2 lines produced, 2 consumed, data_height can be 2, not 3
auto data_height = std::max(line_consumption, skew) + m_writer_lpi - 1;
m_storage = createStorage(data_height, m_desc.size.width, ...);
```

物理行号 = 逻辑行号对容量取模(modules/gapi/src/backends/fluid/gfluidbuffer_priv.hpp:134、165),这就是"缝合":相邻算子共享同一 Buffer/View,上游 `writeDone` 推进写游标并刷新行指针缓存(gfluidbuffer.cpp:583-598),下游 `readDone` 推进读游标并按需从上游拷行、补边框(gfluidbuffer.cpp:250-306);边框分 WithBorder(编译期填常量/复制边)与 WithoutBorder 两种 storage(gfluidbuffer.cpp:230-270)。调度端把每个算子包成 FluidAgent,`doWork` 即 `prepareToRead → k.m_f(核回调) → readDone/writeDone`(gfluidbackend.cpp:498-529);整个图第一遍迭代用贪心扫描生成 `m_script` 定序,之后按脚本直放(gfluidbackend.cpp:1339-1367)。

## 6. 执行器:同步脚本、流水 actor、异步单例与 stateful 核

同步 `GExecutor::run` 把 GIslandModel 拓扑序摊平成脚本,逐 Island 构造 Input/Output 适配器后调 `isl_exec->run(i, o)`,最后写回输出(modules/gapi/src/executor/gexecutor.cpp:27-70、363-441);可选 `use_threaded_executor` 换 GThreadedExecutor(带线程池,gcompiler.cpp:456-461;gthreadedexecutor.cpp:326-329)。流式 `GStreamingExecutor` 是 actor 模型:每个 Island 一条线程,主循环就是"读消息→跑 Island→投递结果"(modules/gapi/src/executor/gstreamingexecutor.cpp:1036-1063):

```cpp
while (!output.done())
{
    if (cv::util::holds_alternative<cv::gimpl::Exception>(input.read()))
    { ... output.post(std::move(...Exception>(in_msg))); }
    else
    {
        island_exec->run(input, output);   // 队列->Island->队列
    }
}
```

`setStreaming` 为每个 emitter、每个 Island、每个 collector 各起一条 `std::thread`,启动前对每个 Island 调 `handleNewStream()`(gstreamingexecutor.cpp:1680-1741),节点间靠有界队列背压;`addStreaming` pass 在 IslandModel 上补 Emit/Sink 节点(modules/gapi/src/compiler/passes/streaming.cpp:37-84),`cv::gapi::desync` 可拆出异步分支(inline/opencv2/gapi/streaming/desync.hpp:41-63;collectors 按 sink_sync 区分主路径,gstreamingexecutor.cpp:1733-1741)。`gasync` 是进程级单例线程池 `async_service`,把 apply 丢进队列执行(modules/gapi/src/executor/gasync.cpp:30-60)。有状态核通过 `GAPI_OCV_KERNEL_ST(Name, API, State)` 注册(modules/gapi/include/opencv2/gapi/cpu/gcpukernel.hpp:488-494),后端为每个核节点调用户 `setup` 建 state(gcpubackend.cpp:166-180);新流到来时 `handleNewStream()` 重建状态(gcpubackend.cpp:214-218),reshape 时仅告警并重置(gcpubackend.cpp:203-211)。

同步与流式的分界在编译期就定型:`compileStreaming()` 向图元数据打 `Streaming{}` 标记,`addStreaming` 只对该标记生效,且流式编译允许 meta 为空(留给 setSource 时的 runMetaPasses 补跑,gcompiler.cpp:254-263、508-520、522-544)。因此同一个 GComputation 可以同时持有 GCompiled 与 GStreamingCompiled 两份产物,互不干扰。

## 7. 异构共存:与卷一 T-API 瀑布的对照

G-API 的 ocl 后端核**并未重写 OpenCL 算子**,而是拿 UMat 调现成 T-API(modules/gapi/src/backends/ocl/goclcore.cpp:36-43):

```cpp
GAPI_OCL_KERNEL(GOCLAddC, cv::gapi::core::GAddC)
{
    static void run(const cv::UMat& a, const cv::Scalar& b, int dtype, cv::UMat& out)
    {
        cv::add(a, b, out, cv::noArray(), dtype);
    }
};
```

即 CV_OCL_RUN 瀑布(核内 fallback 到 CPU)原样保留在算子实现内部,G-API 在其上再加一层**图级**分发:一个图里哪些算子走 `gapi::core::cpu::kernels()`、哪些走 `gapi::core::ocl::kernels()`(约 62 个核,goclcore.cpp:620-680)由 kernel 包合并优先级在编译期一锤定音,Island 边界处经 magazine/RMat 交接数据(gbackend.cpp:127-132)。ocl 包核数远少于 CPU 包(ocl core 62 + imgproc 24 个宏,对比 cpu 包覆盖全部 API),未覆盖的算子会静默落到 CPU 包;Fluid 只消费主机 `cv::Mat`(gfluidbackend.cpp:1250-1255),故 Fluid 与 OCL 岛混排时数据要下载到宿主。这与 T-API"单算子内、运行时按设备状态降级"互补:G-API 管"这个算子归谁",T-API 管"这个算子内部怎么跑"。

值得注意的是,Fluid 与 CPU/OCV 后端实现**同一个 API 类**(如 `cv::gapi::core::GAdd`:gfluidcore.cpp:444 与 gcpucore.cpp:15),kernel id 由 API 类静态给出,故二者是"同 id 不同实现";同一张图里同 id 只会解析出一个 backend 的实现(第 3 节),想让 Fluid 接管就得把它放进用户包靠右优先胜出,或用 `use_only` 独占(gcompiler.cpp:71-88)。而 OpenCL 与 CPU 之间**没有**"设备不可用自动降级到另一后端"的机制——降级只发生在单核内部(T-API 瀑布),图级选择是纯静态的。

GInfer 一句话:推理网络是带 tag 的普通图算子,`GNetPackage` 携带 `(tag, backend, params)`,`bindNetParams` 按 tag 把网络与后端绑到算子上,推理核经各后端的 auxiliaryKernels 进入解析(kernels.cpp:135-158;modules/gapi/src/api/ginfer.cpp:18-26;inline/opencv2/gapi/infer.hpp:661-681)。

## 8. 纠偏(以本 commit 源码为准)

1. **"apply 每次调用都重新编译图"** —— 错。`recompile` 缓存 `m_lastMetas/m_lastCompiled`,meta 相同直接复用,格式(depth/chan)不变还走 `reshape`(gcomputation.cpp:188-211);但 `reshape` 会重置有状态核状态(gcpubackend.cpp:203-211)。
2. **"G-API 运行时探测设备、自动挑最快后端"** —— 错。kernel 选择是 `GKernelPackage` 按 id 的静态 map 查找,合并右优先(gkernel.cpp:79-99;kernels.cpp:176-190),没有任何耗时/设备探测逻辑;选错后端只能靠用户改包。
3. **"Islands 自动把图最优切给不同硬件"** —— 错。切分=编译期静态亲和度(resolve_kernels)+用户 island 标签+同后端贪心融合(exec.cpp:57-220),无代价模型;用户岛还**禁止**与非用户岛融合(exec.cpp:190-196)。
4. **"Fluid 的 line 交织指行间交错存储"** —— 不准确。它是逻辑行→物理行取模的环形缓冲(`physIdx = logIdx % rows`,gfluidbuffer_priv.hpp:134、165),配合 LPI 一次产多行、skew 处理消费速度差(gfluidbuffer.cpp:521-538)。
5. **"gapi::ocl 后端自带一套 OpenCL kernel"** —— 错(就 core/imgproc 而言)。其核体是 UMat 调 T-API(goclcore.cpp:36-43),OpenCL 编译/降级仍由卷一的 CV_OCL_RUN 机制承担;ocl 包只覆盖少数算子(goclcore.cpp:620-680)。
6. **"流式执行 = 自动数据并行加速"** —— 错。GStreamingExecutor 是每个 emitter/Island/collector 一线程的**流水线并行**(gstreamingexecutor.cpp:1680-1741);数据并行只有 Fluid 的实验性 `GFluidParallelOutputRois` 分 tile(gfluidbackend.cpp:1394-1401)。

## 9. GComputation 编译执行管线图

```text
 用户表达式 C++                GComputation{Expr{GIn, GOut}}
      | cv::GComputation::apply / compile / compileStreaming
      v
 GCompiler 构造:合并 kernel 包(ocv ⊕ user, 右优先) + GNetPackage      [gcompiler.cpp:57-204]
      |  generateGraph: unrollExpr -> GModelBuilder.put -> ADE 图
      v
 +----------------------------- ade::ExecutionEngine -----------------------------+
 | init    : check_cycles -> apply_transformations(图重写) -> expand_kernels      |
 |           (compound 展开) -> topo_sort -> init_islands -> check_islands        |
 | kernels : bind_net_params(tag->NN后端) -> resolve_kernels(静态选核)            |
 |           -> check_islands_content                                            |
 | intrin  : desync / finalizeIntrin                                             |
 | meta    : initMeta -> inferMeta(形状/类型推理) -> storeResultingMeta           |
 | exec    : fuse_islands(建 GIslandModel 并贪心融合) -> add_streaming(Emit/Sink) |
 |           -> sort_islands  [+ 各后端 addBackendPasses]                        |
 +-------------------------------------------------------------------------------+
      |  compileIslands: 每 Island 调 backend.priv().compile() -> GIslandExecutable
      v
 produceCompiled ──► GExecutor(单线程脚本) / GThreadedExecutor(线程池)
      或 produceStreamingCompiled ──► GStreamingExecutor(emitter/actor/collector 线程)
      |
      v
 GCompiled::operator() ──► 绑定 magazine(RMat 货币) ──► Island 执行
      ┌────────────────────────┬───────────────────────────┐
      │ Fluid Island           │ CPU(OCV)/OCL Island       │
      │ FluidAgent 链          │ kernel 调 cv::* (Mat/UMat)│
      │ 环形 Buffer/View 缝合  │ (OCL 核内仍有 CV_OCL_RUN) │
      └────────────────────────┴───────────────────────────┘
```

## 10. 设计动机

1. **表达式即图、类型即擦除**:GOrigin 让 GMat/GScalar/GArray 等全部退化为"节点+端口"标签,gmodelbuilder 才落成 ADE 图(gmat.cpp:19-31;gmodelbuilder.cpp:62)。
2. **编译期决定算子宿主**:resolveKernels 的静态 lookup 把"哪个后端跑哪个算子"从运行时挪到编译时,换取零分发开销与可预测性(kernels.cpp:168-232)。
3. **包合并右优先**:用户包天然覆盖内建包,`use_only` 可完全接管,给厂商后端留出确定性的插入点(gkernel.cpp:83-98;gcompiler.cpp:71-88)。
4. **Island = 后端边界**:以 Island 为粒度装配可执行对象与数据交换协议(RMat/magazine),使异构混排成为一等公民(gislandmodel.cpp:268-320;gbackend.cpp:127-132)。
5. **Fluid 追求极限内存带宽**:环形 buffer + LPI + 窗口让中间结果不再整帧落内存,相邻核"缝合"成行级流水(gfluidbuffer.cpp:521-538;gfluidbuffer_priv.hpp:134)。
6. **执行器可插拔**:GIslandExecutable 的 IInput/IOutput 抽象让同一份编译产物可被单线程脚本、线程池、流式 actor 三种运行时驱动(gexecutor.cpp:363-441;gstreamingexecutor.cpp:1036-1062)。
7. **流式是一等编译目标**:`Streaming{}` 元数据 + addStreaming pass 让同一张图能编成 GStreamingCompiled,desync 再支持乱序分支(gcompiler.cpp:508-520;streaming.cpp:37-84)。
8. **复合核与内建恒等核的隐形扩展**:`expand_kernels` 让高层复合 API 先展开成低层图(gcompiler.cpp:225-227),meta/streaming 恒等核则由框架无条件并入包内,对用户不可见却保证 dump/流式正确(gcompiler.cpp:59-69)。

## 11. FAQ 候选

1. GMat 里存的是图像数据吗?——不是,只有 `shared_ptr<GOrigin>`,像素在执行期才落在后端 buffer 或用户 Mat(gmat.cpp:19-31)。
2. `apply` 与先 `compile` 再调用有何区别?——`apply` 内部同样走 `recompile` 缓存,meta 不变时复用同一 GCompiled(gcomputation.cpp:188-217)。
3. 两个后端算子相连时数据怎么传?——经 GIslandModel 的 Slot,以 magazine 中的 RMat(及其 Mat 视图)交接(gbackend.cpp:127-132;gexecutor.cpp:130-145)。
4. 同名 kernel 在多个包里冲突听谁的?——听合并时靠右的包,右优先(gkernel.cpp:83-98)。
5. 用户 `cv::gapi::island()` 能强制阻止融合吗?——能,用户岛与非用户岛之间、不同名用户岛之间都被 canMerge 拒绝(exec.cpp:190-196)。
6. Fluid 图为什么省内存?——中间 buffer 高度只有 `max(窗口需求, skew)+LPI-1` 行的环形缓冲(gfluidbuffer.cpp:534)。
7. 流式 pull 返回 false 意味着什么?——对应执行器已停止/流结束,由各 actor 线程向队列投递 Stop 消息驱动(gstreamingexecutor.cpp:1733-1741)。
8. 有状态核的状态何时初始化?——编译后 setup 一次,新流(handleNewStream)与 reshape 时重建(gcpubackend.cpp:166-218)。
9. GInfer 的网络由谁编译?——由 tag 对应的推理后端(GNetPackage)负责,参数经 bindNetParams 绑定(kernels.cpp:135-158)。
10. async API 用单独线程池吗?——是进程级单例 async_service,懒启动一条服务线程(gasync.cpp:30-60)。

## 12. 深挖方向

1. pattern_matching 的子图同构匹配算法(passes/pattern_matching.cpp:1-580)如何做到保序匹配、失败回溯,以及 pattern 出现在 substitute 中的静态死循环检查(gcompiler.cpp:162-176)。
2. GStreamingExecutor 的队列同步与背压细节:`StreamingInput/Output`、`QueueReader` 与 desync 多 collector 的停流协议(gstreamingexecutor.cpp:731-830、1062 起)。
3. Fluid reshape/GFluidOutputRois 分 tile 并行的可行性与局限(`GParallelFluidExecutable` 不支持 reshape,gfluidbackend.cpp:1147-1242、1394-1401)。
4. RMat/IStreamSource/MediaFrame 三条零拷贝路径在 OAK/OneVPL 后端的落地(src/backends/oak、src/streaming/onevpl、queue_source.cpp)。
5. s11n 反序列化图(Dump 路径)与 python bridge 的 GraphInfo 协议:outMeta 缺失如何在 resolveKernels 中补齐(gcompiler.cpp:563-566;gcomputation.cpp:31-45;kernels.cpp:214-221)。
6. Ade ExecutionEngine 的 pass 依赖与"transform"空段的用途:后端如何经 `addMetaSensitiveBackendPasses` 注入自己的 meta 后 pass(gcompiler.cpp:264-300、533-543)。

## 13. 正文蒸馏要点

1. GMat 仅是 `shared_ptr<GOrigin>` 的句柄,类型擦除枢纽是 `proto::origin_of()` 对 variant 的拆箱(modules/gapi/src/api/gmat.cpp:19-31;gproto.cpp:21-44)。
2. `GComputation` 只存 Expr{ins,outs};`apply=recompile+调用`,meta 未变即复用上次编译产物(gcomputation.cpp:93-97、188-217)。
3. GCompiler 六段 pass 管线:init→kernels→intrin→meta→transform→exec,全部注册在构造函数(gcompiler.cpp:220-300)。
4. 图重写(apply_transformations)循环应用 pattern→substitute 至不动点,且预先检查 pattern 不得出现在 substitute 中(transformations.cpp:101-139;gcompiler.cpp:205-216)。
5. kernel 选择是编译期静态 map 查找(resolveKernels),`combine` 右优先使用户包覆盖内建包(kernels.cpp:168-232;gkernel.cpp:79-99;gcompiler.cpp:75-88)。
6. Islands = 静态亲和度 + 用户标签 + 同后端贪心融合,无代价模型;用户岛拒绝与非用户岛融合(exec.cpp:57-220)。
7. 每 Island 由 `backend.priv().compile()` 产出 GIslandExecutable,这一步才生成后端执行计划(gislandmodel.cpp:268-320)。
8. Fluid 的"缝合"是相邻算子共享环形 Buffer:`data_height=max(line_consumption,skew)+LPI-1`,`physIdx=logIdx%rows`(gfluidbuffer.cpp:534;gfluidbuffer_priv.hpp:134)。
9. Fluid 首次运行贪心扫描生成 `m_script`,后续按脚本直放(gfluidbackend.cpp:1339-1367)。
10. 同步 GExecutor 按拓扑序脚本顺序执行各 Island;流式 GStreamingExecutor 为 emitter/Island/collector 各起线程做流水并行(gexecutor.cpp:363-441;gstreamingexecutor.cpp:1680-1741)。
11. 有状态核经 `GAPI_OCV_KERNEL_ST` 注册,状态在编译后、新流、reshape 三个时机重建(gcpukernel.hpp:488-494;gcpubackend.cpp:166-218)。
12. gapi::ocl 后端核体是 UMat 调 T-API,CV_OCL_RUN 瀑布仍在核内;G-API 负责图级后端指派,T-API 负责算子内降级,两层正交(goclcore.cpp:36-43、620-680)。

<!-- 验证说明:文中全部行号基于 commit d3d247f1 实际读取;未核实项:无 -->
