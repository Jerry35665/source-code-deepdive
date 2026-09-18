# 第 01 章 · 全景与架构:cv::Mat 与自动内存管理

> 基线:commit `d3d247f1`(4.13.0-dev)。核心:modules/core/。

## 1.0 全景:modules 地图与 Mat 布局

```
modules/core(Mat/UMat/MatExpr/InputArray/parallel/TLS/错误)
 imgproc(滤波/几何/色彩) imgcodecs(文件编解码) videoio(视频/摄像头)
 video(光流/跟踪) highgui(窗口) dnn(推理) features2d calib3d objdetect ml photo stitching ts(测试)
cv::Mat 头(栈上轻量):flags(魔数|深度|通道|连续)/dims/rows/cols/data/
  datastart/dataend/datalimit(ROI 定位三件套)/allocator/u(UMatData*)/size/step
UMatData:urefcount(UMat 侧)+refcount(Mat 侧)双计数+data/origdata+handle(设备句柄)
```

README 一句话:"Open Source Computer Vision Library"(README.md:1)。纠偏:4.x 的 Mat 头**没有自己的 refcount**——计数统一收敛到 UMatData(mat.hpp:588-589);MatSize/MatStep 是代理结构,二维时 step 内联在 buf[2] 免堆分配(mat.hpp:619-632)。

## 1.1 引用计数:谁最后引用,谁销毁

拷贝构造只拷头并 `CV_XADD(&u->refcount,1)` 原子加计数(matrix.cpp:401-417);release 从 1 减到 0 的人负责 `deallocate()`——交还 currAllocator 销毁(:547-565)。create 的分配路径:同形同型短路返回(:530)→release→setSize→选分配器(**自定义分配器抛异常自动回退标准分配器**, :703-710)→allocate→addref。StdMatAllocator 默认走 fastMalloc;MatAllocator 抽象为 GPU 预留了 upload/download/map/unmap 全套虚函数(mat.hpp:497-525)。默认分配器是进程级单例,可 setDefaultAllocator 全局替换。

## 1.2 ROI 与"无 COW"

矩形 ROI 构造是 O(1):只挪 data 指针、继承 step、打 SUBMATRIX_FLAG(matrix.cpp:796-820);datastart/dataend 让子矩阵随时能 locateROI 反推自己在母图中的位置。**OpenCV 无隐式 COW**:`Mat B=A; B.setTo(0)` 连 A 一起清零——"写时复制"由函数签名约定实现(改写型函数收 OutputArray,内部 _OutputArray::create 另行分配,天然不踩输入);要独立副本显式 clone()。step 与 rows 解耦使 `Mat(高,宽,类型,外部指针,step)` 能零拷贝包装采集卡 stride 内存。

## 1.3 MatExpr 与 InputArray

`A+B` 不立即算,返回 MatExpr(op 策略单例+操作数+系数,mat.hpp:3643-3648);求值发生在赋值/转换瞬间,按 alpha/beta 形态挑最优内核一次落盘(add/subtract/addWeighted),`operator=` 还能复用旧目标缓冲——**表达式美观与零临时同时拿到手**。InputArray 内部只有 flags/obj/sz 三字段,kind 位域编码 15 种容器(MAT/vector/UMat/GpuMat…),getMat_ 按 kind 分发(matrix_wrap.cpp:14-75);纠偏:实现实际在 matrix_wrap.cpp 而非传闻的 array.cpp(后者是 C API 兼容层)。

## 1.4 设计动机

1. **引用计数而非 GC**:视觉函数每秒进出成千上万图像,GC 停顿不可接受;确定性销毁+O(1) 头拷贝;
2. **step 有 padding**:ROI/行对齐/外部 stride 都要求行距≠行宽;寻址公式统一;
3. **InputArray 多态**:kind 位域+void* 擦除,一套 API 服务全部容器,调用方永不需要看到适配层;
4. **MatExpr 惰性**:消除中间临时矩阵,同时拿到美观与性能;
5. **submatrix 共享底层**:裁剪/滑窗是视觉基本动作,O(1) 切片否则代价线性爆炸;
6. **分配器抽象**:同一 Mat 语义不同后端策略,复杂度只在被用到时出场。

## 1.5 FAQ

**Q1:Mat 的引用计数在哪?**
UMatData::refcount/urefcount 双计数(mat.hpp:588-589);Mat 头只有指针。

**Q2:为什么 B.setTo(0) 连 A 一起清零?**
赋值即共享;OpenCV 无隐式 COW,用 clone() 取独立副本。

**Q3:反复 create 有开销吗?**
同形同型直接短路返回(matrix.cpp:530)。

**Q4:外部内存能包成 Mat 吗?**
能:构造传外部指针+step;USER_ALLOCATED 标记销毁时不释放。

**Q5:Matx 与 Mat 什么关系?**
Matx 是编译期定尺寸栈上矩阵;Mat_<_Tp> 则是绑定元素类型的 Mat 薄封装。

**Q6:CV_Error 后程序会怎样?**
构造 Exception(code/err/func/file/line)→自定义回调→dump→throw;redirectError 可替换。

**Q7:三维 Mat 的 step 在哪?**
堆数组(二维内联 buf[2]);析构按 p!=buf 判断释放。

**Q8:UMatUsageFlags 有用吗?**
给分配器的用途提示(主机/设备/共享内存);除 DEFAULT 外实验性。

**Q9:版本号在哪定义?**
version.hpp:9-19,本基线 4.13.0-dev。

**Q10:TLS 是什么?**
平台抽象的线程本地存储,TlsAbstraction 单例刻意不析构(避免析构顺序问题)。

## 1.6 小结与深挖方向

本章结论:**core="头体分离+双引用计数+ROI 共享+表达式惰性+哑类型多态"**。深挖:

1. UMatData 的 MemoryFlag(COPY_ON_MAP/TEMP_UMAT)与设备迁移状态机;
2. locateROI/adjustROI 的反推算法;
3. MatOp_GEMM 表达式的 GEMM 融合条件;
4. fastMalloc 的 OPENCV_ENABLE_MEMALIGN 对齐路径;
5. customErrorCallback 与 Java/Python 绑定的错误翻译。
