# E《dnn:推理引擎的层图与后端抽象》

> 基线:opencv 4.x,commit `d3d247f1e3125f03171e59ed8fd2fe9454b8ee5f`(2025-11-05)。所有行号以该检出为准。
> dnn 是 OpenCV 内置的前馈神经网络推理引擎:自管一张以 `Layer` 为节点的 DAG,自建 CPU/OpenCL 参考实现,再以"每层可选挂接"的方式把计算委托给 OpenVINO/CUDA/Vulkan/WebNN/TimVX/CANN 等后端。

## 0. 全景图:网络生命周期与 Layer 虚函数表

```
 readNet()/readNetFromXxx()                       dnn_read.cpp:13 按扩展名分发
        |  parser 逐层 addLayer()+connect()  => LayerParams{Dict 参数, blobs 权重}
        v
 Net::Impl::layers : map<int, LayerData>          net_impl.hpp:51  层图本体(DAG)
   连接 = LayerPin(lid,oid)  "第 lid 层的第 oid 个输出"   layer_internals.hpp:12
        |  setInput() / forward()
        v
 setUpNet()  net_impl.cpp:127 -- validateBackendAndTarget() -- clear()
        |
        |-- getLayersShapes -> getLayerShapesRecursively(:1090)
        |       └─ 调 Layer::getMemoryShapes() 推导每个输出的形状 + supportInPlace
        |-- allocateLayers(:558) -> allocateLayer(:453)
        |       └─ BlobManager 分配/复用 outputBlobs、internals;wrap() 造 BackendWrapper
        |-- fuseLayers  net_impl_fuse.cpp:35   conv+BN/ReLU/Eltwise 融合, 被融层 skip=true
        v
 forwardToLayer(:861) 按 id 升序逐层 forwardLayer(:618)
        |
        |-- DNN_BACKEND_OPENCV:  CPU 直接 layer->forward(Mat 路径 :731)
        |        └─ OPENCL target: UMat 路径 layer->forward(UMat) (:649)
        |-- CUDA / HALIDE / WEBNN / TIMVX / VKCOM: 取 backendNodes[b] 分发 (:794-841)
        '-- IE_NGRAPH: 子类 NetImplOpenVINO::forwardLayer -> ov::Model 执行 (net_openvino.cpp:161)

 Layer 虚函数表(子类按需覆盖, dnn.hpp:220-462)
  ├-- 形状:   getMemoryShapes(:444)  updateMemoryShapes(:452)  getFLOPS(:449)
  ├-- 初始化: finalize(:236/:245)
  ├-- 计算:   forward(:254/:261)  forward_fallback(:277)
  ├-- 后端:   supportBackend(:315) + initHalide(:327)/initNgraph(:329)/initVkCom(:331)
  |           /initWebnn(:333)/initCUDA(:342)/initTimVX(:356)/initCann(:368)
  ├-- 融合:   tryAttach(:397)  setActivation(:405)  tryFuse(:412)  getScaleShift(:427)
  '-- 量化:   tryQuantize(:269)  getScaleZeropoint(:436)
```

## 1. 层图的表示:Net / LayerData / Net::Impl

公开类 `Net` 只是薄壳:构造时 `impl = makePtr<Net::Impl>()`(modules/dnn/src/net.cpp:13-17),`addLayer/connect/forward/setInput` 全部一行转发给 Impl(net.cpp:23-28、net.cpp:76-82)。真正的实现 `struct Net::Impl : public detail::NetImplBase`(modules/dnn/src/net_impl.hpp:37)刻意拆成多个 .cpp:net_impl.cpp(生命周期)、net_impl_backend.cpp(后端)、net_impl_fuse.cpp(融合)、net_openvino.cpp(OpenVINO 子类)。

图的三要素全部落在 `Impl` 的字段里(net_impl.hpp:49-60):`netInputLayer`(虚构的 0 号输入层)、`layers`(id→LayerData)、`layerNameToId`/`outputNameToId`、`blobManager`(CPU 内存复用)、`backendWrappers`(host 指针→设备包装)。0 号层在构造函数里手工插入:name 为 `_input`、type 为 `__NetInputLayer__`(net_impl.cpp:42-51),因此 `empty()` 判据是 `layers.size() <= 1`(net_impl.cpp:65-68)。

节点是 `LayerData`(modules/dnn/src/layer_internals.hpp:43-123):静态描述 `id/name/type/dtype/params`(:67-71),拓扑信息 `inputBlobsId`(指向父层输出的 LayerPin 列表,:73)与 `consumers`(:76),运行时状态 `layerInstance`、`outputBlobs`(vector<Mat>)、`inputBlobs`(vector<Mat*> 指向父层输出,:88-91),以及每个后端挂接的计算节点 `std::map<int, Ptr<BackendNode>> backendNodes`(:93):

```cpp
// layer_internals.hpp:88-95
    Ptr<Layer> layerInstance;
    std::vector<Mat> outputBlobs;
    std::vector<Mat*> inputBlobs;
    std::vector<Mat> internals;
    // Computation nodes of implemented backends (except DEFAULT).
    std::map<int, Ptr<BackendNode>> backendNodes;
    // Flag for skip layer computation for specific backend.
    bool skip;
```

"pin" 是这张图的边权:`LayerPin{lid, oid}`(layer_internals.hpp:12-20)把"某层的第 oid 个输出"编码成可比较、可作 map 键的小结构;`Net::Impl::getBlob(pin)`(net_impl.cpp:1329)凭它取数据。边由 `connect(outLayerId, outNum, inLayerId, inNum)` 建立:写 `addLayerInput` 并把父层 `requiredOutputs`/`consumers` 补齐(net_impl.cpp:406-417);`registerOutput` 则为命名输出补插一个 Identity 层(net_impl.cpp:420-450)。注意一个演进痕迹:早期设计中层的输出 blob 曾有独立存储类,当前基线里已无 `BlobStorage`,学习参数直接内联为 `Layer::blobs`(include/opencv2/dnn/dnn.hpp:225)和 `LayerParams::blobs`(dnn.hpp:145-153)。

建图 API 有意做成"可渐进替换":`addLayer` 遇到诊断模式下的同名 NotImplemented 层允许原地换类型(net_impl.cpp:367-382);任何层 dtype 为 CV_8S 即把整网标记 `netWasQuantized`(net_impl.cpp:390-391)。

**setInput 的含义**:输入数据并不存在 Net 里,而是存进 0 号 DataLayer 的 `inputsData`/`scaleFactors`/`means`(layer_internals.hpp:330-336)。`Impl::setInput`(net_impl.cpp:1397-1458)把用户 Mat 拷到 `netInputLayer->inputsData[pin.oid]`,并让 0 号层的 `outputBlobs[oid]` 直接引用同一块内存(:1448-1452,零拷贝);同时记录预处理参数,真正的 scale/mean 换算推迟到 DataLayer::forward 执行(layer_internals.hpp:140-207)。关键一行在末尾:`netWasAllocated = netWasAllocated && oldShape`(net_impl.cpp:1457)——只有形状没变时才免于重新分配,形状一变整个 setUpNet 流程(第 4 节)自动重跑。`setInputShape`/`setInputsNames` 则只是写进 DataLayer 的 `shapes`/`outNames`(net_impl.cpp:1383-1392),配合动态形状推理。

## 2. Layer 抽象:一个"能用最小实现跑通"的接口

`Layer : public Algorithm`(dnn.hpp:220-462)把职责分成五组(见第 0 节虚函数表)。设计哲学是基类给"不会崩"的默认值,子类只覆盖关心的部分:`supportBackend` 默认只认 `DNN_BACKEND_OPENCV`(modules/dnn/src/layer.cpp:39-42);所有 `initXxx` 默认抛 NotImplemented(layer.cpp:44-94);`tryAttach/setActivation/tryFuse` 默认返回 false(layer.cpp:96-102);`getMemoryShapes` 默认"输出抄输入第 0 个、internals 为空、不支持 in-place"(layer.cpp:250-258):

```cpp
// layer.cpp:250-258
bool Layer::getMemoryShapes(const std::vector<MatShape>& inputs,
        const int requiredOutputs,
        std::vector<MatShape>& outputs,
        std::vector<MatShape>& internals) const
{
    CV_Assert(inputs.size());
    outputs.assign(std::max(requiredOutputs, (int)inputs.size()), inputs[0]);
    return false;   // 返回 true 表示该层可原地计算(supportInPlace)
}
```

返回值即 in-place 意愿:net_impl.cpp:1162 调用它并记录 `layerShapes.supportInPlace`(net_impl.cpp:1185),供 BlobManager 决定是否让输出直接复用输入内存。另一个重要默认是 `forward_fallback`(dnn.hpp:277):它把新式 `InputArrayOfArrays` 版 forward 退化到旧的 `vector<Mat*>` 版(layer.cpp:161-220),使老式层自动获得 FP16 场景的"转 FP32 算再转回"能力。0 号层 `DataLayer` 就是标准范例:负责 scale/mean 预处理,且当输入输出同址、无预处理时把自己的 `skip` 置 true(layer_internals.hpp:314-327)。

## 3. LayerFactory:字符串到 C++ 类的注册表

层的类型名(如 "Convolution")到构造函数的映射由全局工厂维护。工厂本体是 `map<string, vector<Constructor>>`:同名可叠加注册,取用 `back()`(modules/dnn/src/layer_factory.cpp:47-62、layer_factory.cpp:99),注销 `pop_back`(layer_factory.cpp:64-79),全程持 `getLayerFactoryMutex()`(layer_factory.cpp:14-24)。首次访问工厂时懒触发 `initializeLayerFactory()`(layer_factory.cpp:32-45)。`Layer` 的公开 API 从 `layer.details.hpp` 挪到了 include/opencv2/dnn/layer.hpp:56-81,注册宏 `CV_DNN_REGISTER_LAYER_CLASS` 在 layer.details.hpp:27-46,靠静态对象构造/析构完成自动注册与反注册。

全部内置层在 modules/dnn/src/init.cpp:79-244 一次性注册,共 149 条 `CV_DNN_REGISTER_LAYER_CLASS`:conv/pooling 等计算层(:96-108),一大串激活层(:110-151),后处理层(:177-192),以及独立的 Int8 家族(:204-243)。工厂查找失败时,`Net::Impl::getLayerInstance` 还会尝试 `basePtr_` 的上游注册表——这是用户继承 Net::Impl 注入自定义层的通道(net_impl.hpp:88-112,回退逻辑在 :101-105)。

注册宏的两个变体值得一提:`CV_DNN_REGISTER_LAYER_CLASS(type, class)` 展开为一个自由构造函数 + 一个静态 `_LayerStaticRegisterer` 对象(include/opencv2/dnn/layer.details.hpp:27-46);后者构造时调 `registerLayer`、析构时 `unregisterLayer`(layer.details.hpp:57-72),于是"链接进来的层自动可用、卸载模块自动清走",与工厂的栈式叠加语义(layer_factory.cpp:74-77)配合,还能支持同一类型名的"最后一次注册生效"。

## 4. 内存规划:getMemoryShapes → allocateLayers → BlobManager

`setUpNet`(net_impl.cpp:127)是懒初始化总闸:`validateBackendAndTarget`(net_impl.cpp:98-125)检查后端/目标组合合法性并做能力降级(如无 OpenCL GPU 则回落 CPU,net_impl.cpp:140-166);`clear()` 复位标志(net_impl.cpp:71-95);随后 `allocateLayers`(net_impl.cpp:558-615)驱动三步:形状推导(`getLayersShapes`,内部递归 `getLayerShapesRecursively`,net_impl.cpp:1090-1217)、给 blobManager 计数(输入与 blobsToKeep 各加引用,net_impl.cpp:594-605)、按依赖序 `allocateLayer`(net_impl.cpp:453-555)。

每层的实际分配交给 `BlobManager`(modules/dnn/src/legacy_backend.hpp:109-328),整个流程可以概括为:

```
 blobManager.reset()                       net_impl.cpp:582   清 refCounter/reuseMap/memHosts
 给 0 号输入/所有层输入/blobsToKeep 加引用    net_impl.cpp:594-605
 allocateLayer(按依赖序递归)                net_impl.cpp:453
   └─ blobManager.allocateBlobsForLayer    net_impl.cpp:520
        ├─ supportInPlace 且唯一消费者 → 输出 reshape 输入内存   legacy_backend.hpp:247-258
        └─ 否则按尺寸从大到小 reuseOrCreate(best-fit 复用/新建)  legacy_backend.hpp:279-303
   └─ releaseReferences(本层输入 + 内部 blob)  net_impl.cpp:551-552   ← 计数归零即可被后续层复用
 fuseLayers                                 net_impl.cpp:614
```

`reuseOrCreate`(legacy_backend.hpp:183-227)在 `memHosts` 里找"引用计数已归零、容量足够、dtype 相同"的最小宿主块做 best-fit 复用(:196-211),找到就直接 reshape 别名(:215),找不到才 `dst.create`;`allocateBlobsForLayer`(legacy_backend.hpp:229-305)保证每层至少一个输出 blob(:242)。注意 `OPENCV_DNN_DISABLE_MEMORY_OPTIMIZATIONS` 可整体关闭复用(legacy_backend.hpp:185)。分配完成后立即 `releaseReferences` 释放父层输出的引用计数(net_impl.cpp:551-552),这正是"拓扑序分配 + 引用计数"能省内存的原因;要长期持有的输出用 `blobsToKeep` 额外加引用(net_impl.cpp:602-605,字段在 net_impl.hpp:50)。

## 5. forward 入口链:从用户调用到单层分发

同步链:`Net::forward`(dnn.hpp:645)→ `Impl::forward(name)`(net_impl.cpp:894-913,空名取最后一层,组 pins 后 `setUpNet` + `forwardToLayer` + `getBlob`)→ `forwardToLayer`(net_impl.cpp:861-891,清 flag 后按 id 升序把目标层之前的层全部算完——拓扑序被编码为"父层 id 必小于子层 id",见 connect 的 `CV_Assert(outLayerId < inLayerId)`,net_impl.cpp:408)→ 单层 `forwardLayer`(net_impl.cpp:618-858)。

异步与多输出:`forwardAsync` 返回 `AsyncArray`(net_impl.cpp:916-941),仅在支持异步的后端有效(默认实现直接报错,net_impl.cpp:636-637);多输出重载在 net_impl.cpp:944-1024,对 GPU 目标先逐个 `copyToHost`(:966-971)再拷回用户容器。要取"用户没显式要"的中间结果,出口是 `getUnconnectedOutLayers/Names`(net_impl.cpp:2159-2218):建图期未被任何消费者引用、也不在 registerOutput 名单里的输出即暴露给用户。

`forwardLayer` 是后端分发的心脏:先查 `ld.backendNodes.find(preferableBackend)`,查不到或后端就是 OPENCV 则走参考实现(net_impl.cpp:630-641):

```cpp
// net_impl.cpp:634-649(有删节)
        if (preferableBackend == DNN_BACKEND_OPENCV || it == ld.backendNodes.end() || it->second.empty())
        {
            if (!layer->supportBackend(DNN_BACKEND_OPENCV))
                CV_Error(...);
#ifdef HAVE_OPENCL
            if (preferableBackend == DNN_BACKEND_OPENCV && IS_DNN_OPENCL_TARGET(preferableTarget))
            {
                std::vector<UMat> umat_inputBlobs = OpenCLBackendWrapper::getUMatVector(ld.inputBlobsWrappers);
                ...
                layer->forward(umat_inputBlobs, umat_outputBlobs, umat_internalBlobs);   // :649
```

CPU 路径(:719-787)先把各输入 wrapper `copyToHost`(:720-724),再调 `layer->forward(inps, ld.outputBlobs, ld.internals)`(:731),最后对输出 wrapper `setHostDirty`(:783-787);可选 NaN/Inf 检查由 `OPENCV_DNN_CHECK_NAN_INF` 控制(:733-781)。后端路径则按枚举逐个分发:CUDA 节点 `forward` + 后台 D2H 拷贝(:794-809)、HALIDE(:811)、WEBNN(:819)、TIMVX(:823)、VKCOM 失败时清空节点递归回退 CPU(:828-840)。每层耗时记入 `layersTimings`(:848-851),支撑 `getPerfProfile`。

融合发生在分配期末尾:`allocateLayers` 最后一步调 `fuseLayers(blobsToKeep_)`(net_impl.cpp:614;实现于 net_impl_fuse.cpp:35)。机制是"上一层吃掉下一层":conv 对后续层调 `tryFuse`(net_impl_fuse.cpp:93),成功即把被吃层的 `skip` 置 true(net_impl_fuse.cpp:96);激活层走专用通道 `setActivation`(net_impl_fuse.cpp:168-171);Conv+Add 走 NaryEltwise 折叠(:197-281)。被 skip 的层在 `forwardLayer` 里只把计时记 0(net_impl.cpp:852-855),其输出指针仍会被改指到融合宿主的输出上以保证 `getBlob` 语义(:290-301)。

## 6. 后端/目标抽象:BackendNode、BackendWrapper 与插件

枚举上,Backend 有 DEFAULT/HALIDE/INFERENCE_ENGINE/OPENCV/VKCOM/CUDA/WEBNN/TIMVX/CANN(dnn.hpp:72-82),内部值 `DNN_BACKEND_INFERENCE_ENGINE_NGRAPH = 1000000` 才是 OpenVINO 真实后端 ID(dnn.hpp:85);Target 覆盖 CPU/OPENCL(+FP16)/MYRIAD/VULKAN/FPGA/CUDA(+FP16)/HDDL/NPU/CPU_FP16(dnn.hpp:97-107)。两个抽象类配对使用:`BackendNode` 只带 `backendId`(dnn.hpp:158-166),是某层在特定后端的可执行节点;`BackendWrapper` 是 Mat 的设备视图,契约仅两个方法 `copyToHost()`/`setHostDirty()`(dnn.hpp:171-211)。

`Net::Impl::wrap(Mat&)`(net_impl_backend.cpp:22-104)按 `host.data` 指针做缓存复用(同一 CPU 缓冲只造一个设备包装,:33-35),再按后端分支构造 OpenCL/Halide/IE/WebNN/Vulkan/CUDA/TimVX 包装;CPU 目标直接返回空指针(:24-26)。初始化期 `initBackend`(net_impl_backend.cpp:107-163)按后端调各自的 init;运行期切后端走 `setPreferableBackend`(net_impl_backend.cpp:169-217):`DNN_BACKEND_DEFAULT` 读环境参数 `OPENCV_DNN_BACKEND_DEFAULT`(modules/dnn/src/dnn_params.cpp:36-40),`INFERENCE_ENGINE` 一律改写为 NGRAPH(:174),OpenVINO/CANN 通过把 Impl 整体换成子类实现(:193-207),`dnn_backend::NetworkBackend` 接口(backend.hpp:14-37,`switchBackend/readNetwork/checkTarget`,析构在 backend.cpp:26-29)服务于动态插件路径(plugin_wrapper.impl.hpp)。量化网络只允许 OPENCV/TIMVX/OpenVINO 三种后端(net_impl_backend.cpp:176-188)与 CPU/OpenCL/NPU 目标(net_impl_backend.cpp:220-224)。

## 7. OpenVINO 桥接:继承 Net::Impl 而非旁路

一句话:OpenVINO 不是"另一种 forward 循环",而是 `NetImplOpenVINO : public Net::Impl`(modules/dnn/src/net_openvino.cpp:30-158)——构造时接管 base 的层图并 `resetAllocation`(:51-76),每个 dnn 层经 `Layer::initNgraph`(dnn.hpp:329,如 conv 在 convolution_layer.cpp:817 的实现)映射成 ngraph 节点,串成 `ov::Model` 由 `InfEngineNgraphNet::forward` 执行(ie_ngraph.cpp:522;节点类 `InfEngineNgraphNode : BackendNode` 在 ie_ngraph.hpp:85);不支持的层直接回落基类 CPU 实现(net_openvino.cpp:170-175),自定义层则包成 `NgraphCustomOp`(ie_ngraph.cpp:51)回调 cv::Layer。

展开一点:`initBackend` 覆写(net_openvino.cpp:268 起)先给每个层的输出 wrapper 命名(便于与 ov::Model 的端口对齐),然后遍历层图调各层 `initNgraph` 把 dnn 节点缝成 ngraph 函数;`forwardLayer` 覆写里如果该层没有 ngraph 节点(如输入层或回退层)就 `return Base::forwardLayer(ld)`(:170-175),否则直接 `ieNode->net->forward(ld.outputBlobsWrappers, isAsync)`(:187)。切后端的语义也由继承表达:在 OpenVINO 原生加载的网络上调 `setPreferableBackend` 换别的后端,会直接把 `Net::impl` 指针换回 base(net_openvino.cpp:86-95)——"实现即对象,后端即子类"。`setPreferableBackend` 主流程里对应的入口是 `switchToOpenVINOBackend(net)` 或插件路径 `createPluginDNNNetworkBackend("openvino").switchBackend(net)`(net_impl_backend.cpp:193-207)。

## 8. CPU 卷积:为什么是多路径

Conv 的 CPU forward(modules/dnn/src/layers/convolution_layer.cpp:1199-1310)先 `CV_OCL_RUN` 尝试 OpenCL(:1204-1205),失败落 CPU:一次性把权重打包成 `FastConv`(:1290-1306),再调 `runFastConv`(:1308)。打包结构 `FastConv`(modules/dnn/src/layers/cpu_kernels/convolution.hpp:55-92)同时携带通用权重、Winograd 变换权重与 FP16 副本,并探测 NEON/AVX2/RVV 能力。`runFastConv`(cpu_kernels/convolution.cpp:1098)按序分流(:1121-1126、:1169-1174):depthwise 走专用 `runDepthwise`,3x3 且输入 H/W≥12 走 Winograd F63(条件在 convolution_layer.cpp:1296),1x1 stride=1 走"整输入先 im2row"的快速路径(:1203、:1284 `separateIm2col`),其余为"分块隐式 im2row + convBlock 块 GEMM"的直接卷积——stripes 级输入重排进线程本地缓冲(:1289-1306),`convBlock_F32` 按 AVX2/AVX/NEON/基线多份实现运行时分发(:1520-1543),Winograd 变换函数同样经 `CV_CPU_DISPATCH` 派发(modules/dnn/src/layers/cpu_kernels/conv_winograd_f63.dispatch.cpp:14)。

```cpp
// convolution_layer.cpp:1289-1308(有删节)
            // Initialization of FastCovn2d, pack weight.
            if (!fastConvImpl || variableWeight)
            {
                ...
                bool canUseWinograd = useWinograd && conv_dim == CONV_2D
                                      && inputs[0].size[2] >= 12 && inputs[0].size[3] >= 12;
                fastConvImpl = initFastConv(weightsMat, &biasvec[0], ngroups, K, C, kernel_size,
                                            strides, dilations, pads_begin, pads_end, conv_dim,
                                            preferableTarget == DNN_TARGET_CPU_FP16, canUseWinograd);
                weightsMat.release();   // 权重已打包,原始副本可弃
            }
            runFastConv(inputs[0], outputs[0], fastConvImpl, nstripes, activ, reluslope, fusedAdd);
```

convBlock 内核的 ISA 分发(convolution.cpp:1516-1544 节选):`opt_*` 命名空间即手写 SIMD 内核,置于 conv_block.simd.hpp / conv_winograd_f63.simd.hpp,由各 .dispatch.cpp 经 `CV_CPU_DISPATCH` 派发(conv_winograd_f63.dispatch.cpp:14),编译期由 CMake 决定可用集合:

```cpp
// cpu_kernels/convolution.cpp:1516-1545(有删节)
#if CV_TRY_AVX2
                                if (haveAVX2)
                                    opt_AVX2::convBlock_F32(c1 - c0, wptr, inptr, cptr, ldc, c0 == 0, outLen, CONV_MR, CONV_NR);
                                else
#endif
#if CV_TRY_AVX
                                if (haveAVX)
                                    opt_AVX::convBlock_F32(...);
                                else
#endif
                                ...   /* NEON / NEON_FP16 分支 */
                                    convBlock_F32(c1 - c0, wptr, inptr, cptr, ldc, c0 == 0, outLen, CONV_MR, CONV_NR);
```

OpenCL 侧则是独立的 ocl4dnn 子系统:src/ocl4dnn/src/ocl4dnn_conv_spatial.cpp(模板实例化在 :1963)配合 src/opencl/ 下的 im2col.cl、col2im.cl、gemm_buffer.cl、gemm_image.cl、conv_layer_spatial.cl——GPU 路径是经典"im2col+GEMM/空间分解",与 CPU 的"块内隐式重排"是两套算法。GEMM 基建共享:`fastGemm` 家族(layers/cpu_kernels/fast_gemm.hpp:154-173)被 FC/MatMul/Gemm 复用(如 layers/fully_connected_layer.cpp:71 起的 InnerProduct 实现内部用 `FullyConnected : ParallelLoopBody`,fully_connected_layer.cpp:203)。激活融合通过 `setActivation` 注入(conv 在 convolution_layer.cpp:453-565,记录 `fusedActivation`),ReLU/ReLU6 甚至退化为 `runFastConv` 的 min/max 截断参数(convolution.cpp:1137-1165)。

## 9. 并行:层内 parallel_for,层间串行

dnn 全模块共 61 处 `parallel_for_`,集中在卷积(convolution_layer.cpp:1828、2048,cpu_kernels/convolution.cpp:1320、1371)、FC/MatMul(fully_connected_layer.cpp:232、layers/matmul_layer.cpp)、eltwise/reduce/topk/concat/attention 及 int8 同名层;典型切法是把输出通道×空间切成 `nstripes = getNumThreads()` 份(convolution_layer.cpp:1282)。以 1x1 快速路径的"阶段一 im2row"为例,重排本身就按 ntasks 并行(convolution.cpp:1317-1331):

```cpp
// cpu_kernels/convolution.cpp:1313-1326(有删节)
    // In the case of 1x1 convolution we first reorder the whole input tensor.
    // In general, im2row results in Hk*Wk-x unrolling factor ...
    if (separateIm2col)
    {
        // the optional phase 1. im2row
        parallel_for_(Range(0, ntasks), [&](const Range& r0) {
        for (int task_id = r0.start; task_id < r0.end; task_id++)
        {
            if (fast_1x1)
            {
                int nc0 = task_id*N*C/ntasks, nc1 = (task_id+1)*N*C/ntasks, dc = 0;
```

层与层之间没有并行:`forwardToLayer` 按 id 顺序执行(net_impl.cpp:876-885),且 BlobManager 的"父层输出可被覆盖"语义依赖这一串行序;跨层异步只有 forwardAsync/OpenCL 队列与 CUDA D2H 后台拷贝(net_impl.cpp:804-808)两种受限形态。

## 10. 模型导入:readNet 的嗅探与 parser 布局

`readNet(model, config, framework)` 纯靠扩展名嗅探(modules/dnn/src/dnn_read.cpp:13-58):caffemodel/prototxt(:20-25)、pb/pbtxt(:26-31)、tflite(:32-35)、t7/net(:36-39)、weights/cfg(:40-45)、xml/bin(OpenVINO,:46-53)、onnx(:54-57),嗅探失败直接报错(:58);内存缓冲版按显式 framework 分发(dnn_read.cpp:61-80)。每个框架一个子目录,parser 自带 proto/结构定义并直接产出 dnn 层图:caffe/(caffe_importer.cpp 617 行,入口 :572)、tensorflow/(tf_importer.cpp 3345 行,入口 :3273,含 7 个 proto)、onnx/(onnx_importer.cpp 4062 行,入口 :4006)、tflite/(tflite_importer.cpp 1362 行)、darknet/(darknet_importer.cpp 258 行,入口 :205)、torch/(torch_importer.cpp 1270 行)。配套的图简化器把框架侧冗余折叠掉:通用 graph_simplifier.cpp、tf_graph_simplifier.cpp、onnx_graph_simplifier.cpp。

```cpp
// dnn_read.cpp:18-30(有删节)
    const std::string modelExt = model.substr(model.rfind('.') + 1);
    const std::string configExt = config.substr(config.rfind('.') + 1);
    if (framework == "caffe" || modelExt == "caffemodel" || ... || modelExt == "prototxt" ...)
    {
        if (modelExt == "prototxt" || configExt == "caffemodel")
            std::swap(model, config);
        return readNetFromCaffe(config, model);
    }
    if (framework == "tensorflow" || modelExt == "pb" || ...)
        ...
```

值得强调的是 parser 与引擎的分工:所有 importer 都只依赖第 1 节的公共建图 API——`dstNet.addLayer(name, type, dtype, params)` + `connect`,例如 ONNX 导入器(onnx_importer.cpp:626)与 TF 导入器(tf_importer.cpp:896 的 Convolution、:3617 的常量层)。导入器不感知后端,后端也不感知格式;层的语义缺口由 `NotImplemented` 占位层承接(配合 `enableModelDiagnostics`,dnn.hpp:130-138),图简化器则负责把 Reshape/Identity/常量子图折叠掉(graph_simplifier.cpp)。OpenVINO 的 xml/bin 例外地保留原始 IR:它走 `Net::readFromModelOptimizer`(dnn_read.cpp:82-99),产出的是 NetImplOpenVINO 子类网络而非普通层图。

## 11. 量化 int8:后处理式 PTQ,覆盖保守

公开入口 `Net::quantize(calibData, ...)`(net.cpp:119-125)是训练后量化:复制出新网络,校准期间强制 CPU 后端 + 关融合 + 关 Winograd(net_quantization.cpp:48-55),逐层用收集到的 scale/zeropoint 调 `Layer::tryQuantize` 改写 LayerParams(net_quantization.cpp:203;基类默认 false,layer.cpp:242-245),在 FP32↔Int8 边界自动插 `Quantize/Dequantize` 层(net_quantization.cpp:211-253)。Int8 计算层成体系但独立成目录 src/int8layers/(conv/pooling/eltwise/softmax/fc 等,conv forward 在 int8layers/convolution_layer.cpp:1498),注册名带 Int8 后缀(init.cpp:204-243)。外部 QDQ 格式的 ONNX 模型会被导入器映射到同一套层:`QuantizeLinear/DequantizeLinear` → `Quantize/Dequantize`(onnx_importer.cpp:3254、:3974),`QLinearConv` 亦有专表项(onnx_importer.cpp:738)。约束见第 6 节:仅三个后端、四个目标支持量化网(net_impl_backend.cpp:176-188、220-224)。总体是"够用但非主线"的状态。

## 12. 可观测性:dump、剖析与诊断

三件套让这张层图"看得见"。其一是结构转储:`Net::dump()`/`dumpToPbtxt`(net.cpp:201-226)输出含后端/目标/融合状态的文本与 pbtxt,`Impl::dumpNetworkToFile` 在 `OPENCV_DNN_NETWORK_DUMP` 打开时自动落盘(net_impl.cpp:131-134、2104;文件名由 `NetImplBase::getDumpFileNameBase` 用全局 networkId 编号生成,net_impl.cpp:14-30)。其二是性能:`forwardLayer` 用 TickMeter 记每层耗时(net_impl.cpp:626-851),`getPerfProfile` 汇总(net_impl.hpp:267),`getMemoryConsumption` 估算权重与 blob 内存(net_impl.cpp:2233-2320)。其三是运行期诊断:第 5 节的 NaN/Inf 检查(net_impl.cpp:652-713)与诊断模式(dnn.hpp:138)。这套设施全部建立在前述"串行逐层 + id 序"的执行模型上,反过来说明了该模型对可维护性的价值。

## 13. 设计动机

1. **为什么层图自管,而不是直接接 ONNX Runtime 等外部运行时**:dnn 的核心资产是"任意框架模型 → 统一 LayerParams+DAG → 自带参考实现"的闭环。第 10 节的 parser 面向 caffe/torch7/darknet/tflite 等外部运行时不覆盖的格式;第 4-5 节的形状推导、内存复用、逐层融合都建立在"图是我自己的"之上。接入外部运行时反而成为其中一种后端(第 7 节的 OpenVINO 桥),这与第 3 节可扩展的 LayerFactory(net_impl.hpp:101-105 还支持用户继承注入)共同保证了离线/嵌入式场景零外部依赖可用。
2. **为什么后端抽象做成"每层 opt-in"而非整网编译**:每层自己声明 `supportBackend` 并按需产出 `BackendNode`(layer_internals.hpp:93 存成 map),`forwardLayer` 逐层查表、缺节点即回落 CPU(net_impl.cpp:630-641)。整网能跑的比例因此远大于任何单一后端算子覆盖率,OpenVINO 桥对不支持层直接 `Base::forwardLayer`(net_openvino.cpp:170-175)就是证据;切换后端也不用重解析模型,只需 `clear()` 后重新分配。
3. **为什么 conv 有多路径**:硬件 ISA 差异(NEON/AVX/AVX2/RVV/FP16)与卷积形状差异(1x1、3x3、depthwise、一般)各自对应最优算法,`runFastConv` 按形状分流、`convBlock`/Winograd 按运行时 CPU 特性 `CV_CPU_DISPATCH`(convolution.cpp:1520-1543、conv_winograd_f63.dispatch.cpp:14),OpenCL 又是第三套算法(ocl4dnn)。单一实现无法同时吃满 ARM 手机与 x86 服务器。
4. **为什么格式解析内置在模块里**:各框架 proto 语义差异(名字、布局、常量折叠、训练残留节点)必须在导入期归一化,还要配合图简化器做 dnn 侧融合预处理;这些逻辑与 dnn 的层类型一一对应,放进模块内才能让 `readNetFromXxx` 产出即用 LayerParams 的层图(第 10 节),也让 dnn 能长期兜住已停更的旧格式。
5. **为什么量化现状保守**:dnn 的 Int8 是"PTQ 后处理 + 独立 Int8 层类"的方案,需为每层维护两份实现并处理边界 Quantize/Dequantize(第 11 节),收益/维护比低于把量化交给 OpenVINO/TimVX 委托执行,因此官方刻意限定其可用后端/目标(net_impl_backend.cpp:176-188)并把精力放在 float 路径与后端桥上。
6. **为什么内存复用自己写**:BlobManager 的引用计数 + best-fit 复用 + in-place(第 4 节)只需拓扑序与 `getMemoryShapes` 的 `supportInPlace` 返回值,不依赖任何分配器设施,且对 Mat/UMat 两条路径统一生效;这正是 CPU 内存受限设备上 dnn 的立身之本。
7. **为什么层间不并行**:执行序被编码为"id 严格递增"(net_impl.cpp:408、876-885),它同时是拓扑序、内存复用安全性(可覆盖判定依赖串行)与 `getPerfProfile` 逐层计时的前提;并行收益被下沉到层内 parallel_for,避免通用流调度的高复杂度。

## 14. 写作素材清单(已核对行号)

1. modules/dnn/src/net.cpp:13-17 — Net 薄壳,impl 转发
2. modules/dnn/src/net_impl.hpp:49-60 — 层图字段:layers/blobsToKeep/blobManager/backendWrappers
3. modules/dnn/src/layer_internals.hpp:88-95 — LayerData 运行时字段与 backendNodes
4. modules/dnn/src/net_impl.cpp:42-51 — 0 号虚拟输入层 `_input`
5. modules/dnn/src/net_impl.cpp:1090-1217 — getLayerShapesRecursively 形状推导
6. modules/dnn/src/net_impl.cpp:618-858 — forwardLayer 的后端分发全貌
7. modules/dnn/src/net_impl.cpp:127-225 — setUpNet 懒初始化与能力降级
8. modules/dnn/src/net_impl_fuse.cpp:35-96 — fuseLayers:tryFuse 命中即 skip
9. modules/dnn/src/legacy_backend.hpp:183-227 — BlobManager::reuseOrCreate best-fit 复用
10. modules/dnn/include/opencv2/dnn/dnn.hpp:220-462 — Layer 虚函数表
11. modules/dnn/src/layer_factory.cpp:47-105 — 注册/查工厂(back() 优先)
12. modules/dnn/src/init.cpp:87-243 — 149 个内置层注册(含 Int8 家族)
13. modules/dnn/src/dnn_read.cpp:13-58 — readNet 扩展名嗅探
14. modules/dnn/src/layers/convolution_layer.cpp:1281-1309 — FastConv 打包与多路径入口
15. modules/dnn/src/layers/cpu_kernels/convolution.cpp:1098-1174 — runFastConv 分流(depthwise/winograd/1x1)
16. modules/dnn/src/net_openvino.cpp:30-158 — NetImplOpenVINO 子类桥接

(完)
