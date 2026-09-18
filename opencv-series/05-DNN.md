# 第 05 章 · dnn:推理引擎的层图与后端抽象

> 基线:commit `d3d247f1`。核心:modules/dnn/src/。dnn 是内置前馈推理引擎:自管 Layer DAG、自带 CPU/OpenCL 参考实现,以"每层可选挂接"方式委托 OpenVINO/CUDA/Vulkan/WebNN/TimVX。

## 5.0 全景:网络生命周期

```
readNet(扩展名嗅探:caffe/pb/tflite/t7/cfg/xml/onnx)→ parser 逐层 addLayer+connect
 → Net::Impl::layers(map<int,LayerData>,0 号虚拟输入层)拓扑被编码为"父层 id<子层 id"
 → setUpNet:validateBackendAndTarget(能力降级)→getMemoryShapes 递归推导
 → allocateLayers(BlobManager 引用计数+best-fit 复用+in-place)→fuseLayers(conv 吃 BN/ReLU)
 → forwardToLayer 按 id 序逐层 forwardLayer:
     OPENCV 后端:CPU Mat 路径/OpenCL UMat 路径
     CUDA/HALIDE/WEBNN/TIMVX/VKCOM:查 backendNodes 分发,缺节点回落 CPU
Layer 虚函数表:getMemoryShapes/forward/supportBackend/initXxx 后端/tryFuse/tryQuantize
```

## 5.1 关键机制

**setInput 的零拷贝**:输入数据存进 0 号 DataLayer,Impl::setInput 把用户 Mat 拷到 inputsData 并让 outputBlobs 直接引用同一内存;`netWasAllocated = netWasAllocated && oldShape`——形状一变整个分配流程自动重跑。**BlobManager 内存复用**:supportInPlace 且唯一消费者→输出 reshape 输入内存;否则按尺寸从大到小 best-fit 复用(reuseOrCreate 找"引用计数归零、容量够、dtype 同"的最小块);每层分配完立即 releaseReferences 父层输出——拓扑序分配+引用计数正是省内存的原因。**融合**:conv 对后续层 tryFuse 成功即置 skip,输出指针改指融合宿主保证 getBlob 语义;被 skip 层计时记 0。**OpenVINO 桥="后端即子类"**:NetImplOpenVINO 继承 Net::Impl,每层 initNgraph 缝成 ov::Model;不支持层直接回落基类 CPU 实现;切后端=把 impl 指针换回 base。

## 5.2 CPU 卷积多路径

FastConv 打包结构同时携带通用权重/Winograd 变换权重/FP16 副本;runFastConv 按形状分流:depthwise 专用路径、3x3 且 HW≥12 走 Winograd F63、1x1 stride=1 走整输入 im2row 快路径、其余分块隐式 im2row+convBlock 块 GEMM——convBlock 按 AVX2/AVX/NEON 运行时分发。OpenCL 侧是独立 ocl4dnn(im2col+GEMM),与 CPU 的"块内隐式重排"是两套算法。激活融合经 setActivation 注入,ReLU 甚至退化为 runFastConv 的 min/max 截断参数。**层内 parallel_for(61 处),层间刻意串行**——内存复用安全性与逐层计时依赖此序。

## 5.3 模型导入与量化

readNet 纯扩展名嗅探,6 个 parser 子目录(caffe/tf/onnx/tflite/darknet/torch)只依赖公共建图 API(addLayer+connect)——导入器不感知后端,后端不感知格式;图简化器折叠 Reshape/Identity/常量子图。量化是 PTQ 后处理:quantize 复制新网、校准期强制 CPU+关融合、逐层 tryQuantize 改写参数、FP32↔Int8 边界自动插 Quantize/Dequantize 层;仅 3 后端 4 目标支持——"够用但非主线",官方刻意保守。

## 5.4 设计动机

1. **层图自管而非接外部运行时**:核心资产是"任意框架模型→统一层图→自带参考实现"闭环;外部运行时只是其中一种后端,离线/嵌入式零外部依赖可用;
2. **后端抽象每层 opt-in**:整网能跑的比例大于任何单一后端算子覆盖率;切后端不用重解析模型;
3. **conv 多路径**:ISA 与卷积形状各自对应最优算法,单一实现无法同时吃满 ARM 手机与 x86 服务器;
4. **格式解析内置**:框架 proto 语义差异必须在导入期归一化;让 dnn 长期兜住已停更旧格式;
5. **量化保守**:PTQ+双份实现的收益/维护比低,交给 OpenVINO/TimVX 委托执行;
6. **内存复用自写**:只需拓扑序与 supportInPlace 返回值,Mat/UMat 两路径统一,是受限设备的立身之本;
7. **层间串行**:同时是拓扑序、内存复用安全性与逐层计时前提;并行下沉到层内。

## 5.5 FAQ

**Q1:层图怎么表示?**
map<int,LayerData>,LayerPin(lid,oid) 编码"某层第 oid 个输出"作边;0 号虚拟输入层。

**Q2:支持的模型格式?**
caffe/tensorflow(onnx 之外)/tflite/darknet/torch/onnx/openvino(xml/bin 走子类网络)。

**Q3:内存怎么省?**
BlobManager 引用计数+best-fit 复用+in-place;可用 OPENCV_DNN_DISABLE_MEMORY_OPTIMIZATIONS 关闭。

**Q4:层融合做了什么?**
conv 吃 BN/ReLU/Eltwise;被吃层 skip=true,计时记 0,输出指针改指宿主。

**Q5:OpenVINO 桥的本质?**
NetImplOpenVINO 继承 Net::Impl;每层 initNgraph 缝 ngraph;不支持层回落 base CPU。

**Q6:卷积有哪些 CPU 路径?**
depthwise/Winograd F63(HW≥12)/1x1 im2row 快路径/分块隐式 im2row;convBlock 按 ISA 分发。

**Q7:层间并行吗?**
不:id 序串行是拓扑序+内存安全+逐层计时三重前提;并行在层内 parallel_for。

**Q8:自定义层怎么加?**
CV_DNN_REGISTER_LAYER_CLASS 注册(静态对象构造自动注册);或继承 Net::Impl 注入。

**Q9:量化网络支持哪些后端?**
仅 OPENCV/TIMVX/OpenVINO 三后端、CPU/OpenCL/NPU 目标。

**Q10:模型格式嗅探失败会怎样?**
readNet 直接报错;内存缓冲版需显式 framework 参数。

## 5.6 小结与深挖方向

本章结论:**dnn="自管层图+每层 opt-in 后端+BlobManager 复用+多路径卷积+OpenVINO 子类桥"**。深挖:

1. fuseLayers 的 Conv+Add NaryEltwise 折叠;
2. forwardAsync 的 AsyncArray 与受限异步形态;
3. onnx_importer 4062 行的 QDQ 映射;
4. getUnconnectedOutLayers 的"未被消费即暴露"判定;
5. NaN/Inf 检查(OPENCV_DNN_CHECK_NAN_INF)。
