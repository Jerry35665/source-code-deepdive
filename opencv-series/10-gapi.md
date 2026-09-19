# 第 10 章 · gapi:图 API 的静态异构与 Fluid 行级流水

> 基线:commit `d3d247f1`(4.13.0-dev)。核心:modules/gapi/src/(api/ compiler/ backends/fluid/ executor/)。

## 10.0 全景:表达式到执行的编译管线

```
 GIn(a,b) + 算子表达式 ──► GComputation{Priv::Expr}(gcomputation.cpp:93-97)
   ▼ GCompiler::compile(gcompiler.cpp:500-506)
 generateGraph(表达式反向展开为 ADE 图) → runPasses 六段:
   init(查环→变换→expand_kernels→拓扑排序→init_islands→check_islands)
   kernels(bind_net_params→resolve_kernels:每算子静态选 backend)
   intrin/meta/transform/exec(fuse_islands→add_streaming→sort_islands)
   ▼ compileIslands(每岛调后端编译出 GIslandExecutable)
 produceCompiled(选 GExecutor/GThreadedExecutor,流式另有 GStreamingExecutor)
```

纠偏:异构选择是**纯编译期静态决策**——`resolveKernels` 对每个算子按 kernel id 在包里静态 lookup 一锤定音(kernels.cpp:168-232),Islands 切分 = 静态亲和度+用户 `cv::gapi::island` 标签+同后端贪心融合(exec.cpp:57-220),**没有任何代价模型或运行时探测**。"G-API 自动把子图分给最快硬件"是误读。

## 10.1 GMat:出身证明式的类型擦除

GMat 不持有像素,只包 `shared_ptr<GOrigin>`——记录"这个数据由哪个节点、第几个端口产出"(gorigin.hpp:25-37);三种构造对应空图起点/常量输入/算子输出(gmat.cpp:19-31)。GIn/GOut 只是给参数包打标签,编译器经 `proto::origin_of()` 从 variant 拆箱(gproto.cpp:21-44)。`apply` 先 `recompile`:输入 meta 未变直接复用 m_lastCompiled,形状相同还可走 reshape 免重编(gcomputation.cpp:188-217)。

## 10.2 backend 合并:右优先

`GBackend` 是 shared_ptr<Priv> 轻句柄,身份即指针;`GKernelPackage` 内部是 map<kernel_id,(backend,impl)>,合并**右边优先**——`cv::gapi::combine(ocv_pkg, user_pkg)` 使用户包覆盖内建包(gkernel.cpp:79-99; gcompiler.cpp:57-89)。运行期数据交换的公共货币是 RMat:执行器把用户 Mat 包成 RMatOnMat,后端经 bindRMat 物化(gexecutor.cpp:130-145; gbackend.cpp:127-132)。纠偏:gapi::ocl 后端**没有重写 OpenCL 算子**——核体就是拿 UMat 调现成 T-API(如 cv::add,goclcore.cpp:36-43);G-API 只做图级"算子归谁"的静态指派,与卷一 T-API 的"算子内部怎么降级"(CV_OCL_RUN 瀑布)正交互补,且图级没有设备不可用时的跨后端自动降级。

## 10.3 Fluid:环形 buffer 行级流水

Fluid kernel 不是整图函数而是 {Kind, LPI, scratch, f, 窗口} 回调组(gfluidkernel.hpp:52-101);中间数据是**高度按公式裁剪的环形缓冲**:`data_height = max(line_consumption, skew) + writer_lpi - 1`,物理行号=逻辑行号对容量取模(gfluidbuffer.cpp:521-538; gfluidbuffer_priv.hpp:134, 165)——这就是"缝合":相邻算子共享同一 Buffer,上游 writeDone 推进写游标,下游 readDone 推进读游标并按需拷行补边(gfluidbuffer.cpp:250-306, 583-598)。调度把每算子包成 FluidAgent,第一遍迭代贪心扫描生成 m_script 定序、之后按脚本直放(gfluidbackend.cpp:498-529, 1339-1367)。

## 10.4 执行器:同步/多线程/流式 actor 三态

同步 GExecutor 把 Island 图拓扑序摊平成脚本逐个跑(gexecutor.cpp:27-70);流式 GStreamingExecutor 是 actor 模型:每个 Island 一条线程,主循环即"读消息→跑 Island→投递结果",节点间有界队列背压,`cv::gapi::desync` 可拆异步分支(gstreamingexecutor.cpp:1036-1063, 1680-1741)。同步与流式的分界在编译期定型:`compileStreaming` 打 Streaming{} 标记,同一 GComputation 可同时持有两份产物(gcompiler.cpp:508-520)。gasync 是进程级单例线程池把 apply 丢队列(gasync.cpp:30-60)。有状态核经 GAPI_OCV_KERNEL_ST 注册,新流到来 handleNewStream 重建状态(gcpubackend.cpp:166-180, 214-218)。

## 10.5 设计动机

1. **静态异构**:backend 选择在编译期定死,执行零探测开销,行为可预测(kernels.cpp:168-232);
2. **两级图**:GModel(算子)折叠为 GIslandModel(ISLAND/SLOT/EMIT/SINK),执行器只看后一层(gislandmodel.hpp:204-233);
3. **右优先包合并**:用户覆盖内建的语义一目了然,无需优先级配置(gkernel.cpp:79-99);
4. **Fluid 行级流水**:中间结果不落整帧,内存占用与 cache 命中同时优化(gfluidbuffer.cpp:521-538);
5. **执行器可插拔**:同步/多线程/流式共享同一 Island 抽象,流式只是多打一个标记(gcompiler.cpp:456-520);
6. **复用而非重写**:ocl 后端直接调 T-API,避免第二套 OpenCL 算子实现漂移(goclcore.cpp:36-43)。

## 10.6 FAQ

**Q1:G-API 会自动选最快设备吗?**
不会,backend 是编译期静态指派+用户标签(kernels.cpp:168-232)。

**Q2:apply 每次都重新编译吗?**
不,meta 未变复用 m_lastCompiled,形状相同可 reshape(gcomputation.cpp:188-211)。

**Q3:Fluid 怎么省内存?**
中间数据是高度=consumption+writer_lpi-1 的环形 buffer,不存整帧(gfluidbuffer.cpp:534)。

**Q4:图怎么手工指定某段用某后端?**
cv::gapi::island(name, GIn(...), GOut(...)) 打标签(gcomputation.cpp:307-356)。

**Q5:ocl 后端的 OpenCL 核在哪?**
没有新核,直接调 T-API(cv::add 等,goclcore.cpp:36-43)。

**Q6:流式和同步能共存吗?**
能,同一 GComputation 持有两份编译产物(gcompiler.cpp:508-520)。

**Q7:两个后端的算子相邻会怎样?**
异后端不可合并岛,数据经 SLOT 交接(exec.cpp:57-84)。

**Q8:有状态核的状态何时重置?**
新流 handleNewStream 重建;reshape 仅告警重置(gcpubackend.cpp:203-218)。

**Q9:desync 是什么?**
拆出异步分支,主路径与支路经 sink_sync 区分(desync.hpp:41-63)。

**Q10:pattern 重写循环做什么?**
把用户注册的 pattern→substitute 图重写应用到不动点(transformations.cpp:101-139)。

## 10.7 小结与深挖方向

本章结论:**gapi=表达式→ADE 图→静态 backend 指派→岛融合→可插拔执行器;Fluid 用环形 buffer 行级流水消除整帧中间结果**。深挖:

1. desync 的 sink_sync 集合与队列满时的丢弃策略(gstreamingexecutor.cpp:1733-1741);
2. Fluid resize/YUV420 核的 LPI(每迭代行数)选择对吞吐的影响(gfluidkernel.hpp:53-58);
3. GStreamingExecutor 的 bounds 与背压参数调优;
4. GInfer 推理岛的 aux kernels 装配(gcompiler.cpp:199-204);
5. dump_dot 调试输出与 ADE 图的可视化(gcompiler.cpp:exec 段)。
