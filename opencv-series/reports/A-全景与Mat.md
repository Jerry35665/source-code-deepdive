# 《OpenCV 深读》报告 A:全景与架构 —— cv::Mat 与自动内存管理

> **基线说明(如实注明)**:本报告基于 gitee 镜像 HEAD,commit `d3d247f1e3125f03171e59ed8fd2fe9454b8ee5f`(2025-11-05 同步的浅克隆检出),`version.hpp` 显示版本为 `4.13.0-dev`(主分支开发态,见 modules/core/include/opencv2/core/version.hpp:9-12)。相对个别正式发布版,该基线较旧,但 cv::Mat / 内存管理这一层的架构自 4.x 以来高度稳定,结论不失时效。所有行号均经实际 Read/Grep 核对。

---

## 1. 全景图

### 1.1 modules 目录地图(目录清单经 `ls modules/` 核实)

```text
opencv/
├── modules/core/        一切的地基:cv::Mat/UMat、MatExpr、InputArray、引用计数内存、
│                        parallel_for、TLS 线程本地存储、错误处理(CV_Error/Exception)
├── modules/imgproc/     2D 图像处理:滤波、几何变换、色彩空间、直方图、形状分析
├── modules/imgcodecs/   图像文件编解码:JPEG/PNG/WebP 等与 Mat 的互转(imread/imwrite)
├── modules/videoio/     视频/摄像头采集与写出(FFmpeg/MSMF/V4L2 等后端,VideoCapture)
├── modules/video/       视频时序分析:光流、跟踪、背景建模
├── modules/highgui/     窗口与交互:imshow/waitKey、鼠标与滑条回调
├── modules/dnn/         深度网络推理:加载 ONNX/Caffe/TF 模型并前向执行
├── modules/features2d/  特征点检测/描述子/匹配(BFMatcher、FLANN 依赖 modules/flann/)
├── modules/calib3d/     相机标定、立体几何、PnP、单应矩阵估计
├── modules/objdetect/   传统目标检测:Haar 级联、HOG、QR 码/人脸等检测器
├── modules/ml/          统计机器学习:SVM、随机树、KNN、Boost
├── modules/photo/       计算摄影:图像修复、HDR、去噪、seamlessClone
├── modules/stitching/   全景拼接流水线(特征→匹配→变换→融合)
└── modules/ts/          测试基础设施:TS 测试框架、性能测试宏(其余模块的 tests 依赖它)
```

(另有 `flann/`、`gapi/`、`java/`、`js/`、`objc/`、`python/`、`world/` 等目录;`world` 是把各模块合并成单一库的聚合模块。)

### 1.2 cv::Mat 内部布局:多个"头"共享一个 UMatData

```text
   cv::Mat 头对象(栈上,轻量)                        堆内存
 ┌───────────────────────────────┐
 │ flags(int:魔数|深度|通道|连续性)│            ┌─────────────────────────────┐
 │ dims / rows / cols            │            │  像素数据(整幅或其中一块)   │
 │ data ─────────────────────────┼──────────▶ │                             │
 │ datastart / dataend / datalimit──(ROI 定位)└─────────────────────────────┘
 │ allocator(MatAllocator*)      │                      ▲   ▲
 │ u(UMatData*)──────────────────┼──────────────────────┘   │
 │ size(MatSize,int* p→&rows)    │            ┌─────────────UMatData─────────────┐
 │ step(MatStep,size_t p+buf[2]) │            │ urefcount │ refcount  │ data     │
 └───────────────────────────────┘            │ origdata  │ size      │ flags    │
        Mat A(整图)   Mat B=A(Range,Range)     │ currAllocator │ handle │ ...   │
        两个头的 data 不同,但 u 指向同一 UMatData └──────────────────────────────────┘
```

字段定义:flags/dims/rows/cols/data 见 modules/core/include/opencv2/core/mat.hpp:2161-2167;datastart/dataend/datalimit 见 mat.hpp:2170-2172;allocator 与全局分配器接口见 mat.hpp:2175-2179;u/size/step 见 mat.hpp:2185-2188。UMatData 字段见 mat.hpp:586-600(urefcount:588,refcount:589,data/origdata:590-591)。

---

## 2. README 自述与项目定位

仓库根 README.md:1 一句话开篇:"OpenCV: Open Source Computer Vision Library";随后列出主页(opencv.org)、4.x 文档(docs.opencv.org/4.x/)、issue 跟踪与 opencv_contrib 扩展仓库的位置(README.md:5-17)。即:**OpenCV 是以模块化 C++ 库组织的开源计算机视觉库,core 提供数据结构,其余模块提供算法,contrib 提供实验性扩展**。

## 3. cv::Mat 全解剖

### 3.1 头(Header)与数据(Body)分离

`class CV_EXPORTS Mat`(mat.hpp:829)只有十几个字段,不含变长数据本体。关键成员(行号均已在 mat.hpp 核对):

- `flags`(mat.hpp:2161):位域组合——魔数 `MAGIC_VAL=0x42FF0000`、深度、通道数、连续标志,掩码定义在 mat.hpp:2152-2153(`MAGIC_MASK/TYPE_MASK/DEPTH_MASK`,以及 `SUBMATRIX_FLAG = CV_SUBMAT_FLAG`)。
- `dims`(mat.hpp:2163)、`rows, cols`(mat.hpp:2165):维度数;二维以上时 rows/cols 置 -1。
- `data`(mat.hpp:2167):指向当前 ROI 左上角像素的 `uchar*`。
- `datastart/dataend/datalimit`(mat.hpp:2170-2172):"helper fields used in locateROI and adjustROI"——分别指向**底层整块数据**的首/当前 ROI 有效末尾/分配块末尾,用于反推子矩阵在母矩阵中的偏移。
- `u`(mat.hpp:2185):`UMatData*`,真正的"数据块管理对象",引用计数就挂在它身上。
- `size`/`step`(mat.hpp:2187-2188):两个轻量代理结构。`MatSize` 只是 `int* p`(指向 `&rows` 或堆数组,mat.hpp:605-617);`MatStep` 是 `size_t* p; size_t buf[2]`(mat.hpp:619-632)——二维时 step 内联在 `buf` 里免堆分配,三维以上才指向堆数组。

步长的寻址公式与不变量写在类文档里(mat.hpp:644-651):`addr(M_{i,j}) = M.data + M.step[0]*i + M.step[1]*j`,且 `M.step[i] >= M.step[i+1]*M.size[i+1]`,最内层 `step[dims-1] == elemSize()`(分配后有断言,matrix.cpp:711)。

### 3.2 UMatData:引用计数的宿主

UMatData(mat.hpp:562-601)是"数据块 + 两个引用计数"的载体:

```cpp
// modules/core/include/opencv2/core/mat.hpp:586-599(节选)
const MatAllocator* prevAllocator;
const MatAllocator* currAllocator;
int urefcount;          // UMat(OpenCL 路径)的引用数
int refcount;           // Mat(主机路径)的引用数
uchar* data;
uchar* origdata;
size_t size;
UMatData::MemoryFlag flags;   // COPY_ON_MAP/TEMP_UMAT/USER_ALLOCATED 等, mat.hpp:564-568
void* handle;                 // 设备侧句柄(OpenCL/VAAPI 等)
```

注意:4.x 中 **Mat 自己不再有 `refcount` 成员**,计数统一收敛到 `UMatData::refcount`;`int* refcount` 的旧式接口在 MatAllocator 中已被注释废弃(mat.hpp:504-506)。UMatData 甚至可能与数据块一并分配、手工 init,因此刻意"没有构造/析构语义"(注释见 mat.hpp:558-561)。

### 3.3 引用计数与 release:自动内存管理的核心

拷贝构造只拷头并原子加计数(matrix.cpp:401-417,`CV_XADD(&u->refcount, 1)` 在 matrix.cpp:407;CV_XADD 是原子取加,cvdef.h:697-704);赋值运算符同理,先加对方计数再 `release()` 自己的旧引用(matrix.cpp:484-510)。析构函数极简(matrix.cpp:477-482):`release()` + 释放多维 step 数组。

```cpp
// modules/core/src/matrix.cpp:401-417(节选)
Mat::Mat(const Mat& m)
    : flags(m.flags), dims(m.dims), rows(m.rows), cols(m.cols), data(m.data),
      datastart(m.datastart), dataend(m.dataend), datalimit(m.datalimit), allocator(m.allocator),
      u(m.u), size(&rows), step(0)
{
    if( u )
        CV_XADD(&u->refcount, 1);      // 浅拷贝:只加计数
    if( m.dims <= 2 )
        { step[0] = m.step[0]; step[1] = m.step[1]; }
    else
        { dims = 0; copySize(m); }     // >2 维时 step 才落到堆数组
}
```

```cpp
// modules/core/src/matrix.cpp:547-552
void Mat::release()
{
    if( u && CV_XADD(&u->refcount, -1) == 1 )   // 从 1 减到 0 的人负责销毁
        deallocate();
    u = NULL;
    datastart = dataend = datalimit = data = 0;
    ...
}
```

`deallocate()`(matrix.cpp:733-741)把数据块交还给 `u->currAllocator`(缺省回退到 `allocator` 或 `getDefaultAllocator()`)的 `unmap/deallocate` 流程;StdMatAllocator::deallocate 会断言两个计数都为 0,再 `fastFree` 数据并 `delete u`(matrix.cpp:163-176)。这就是"谁最后引用,谁销毁"的无 GC 自动内存管理。

### 3.4 create 的分配路径

`Mat::create(rows, cols, type)`(matrix.cpp:527-534)先做短路判断:**尺寸类型都没变且已有数据就直接返回**(matrix.cpp:530),这解释了热循环里反复 create 无开销。真正的多维版本 `Mat::create(int d, const int* _sizes, int _type)`(matrix.cpp:659-716)流程:

1. 形状/类型比对短路(matrix.cpp:665-676);
2. `release()` 旧数据(matrix.cpp:686);
3. `setSize()` 计算 step(matrix.cpp:690);
4. 选分配器:成员 `allocator` 为空则用 `getDefaultAllocator()`(matrix.cpp:694-696),**自定义分配器抛异常时自动回退标准分配器**(matrix.cpp:703-710);
5. `u = a->allocate(dims, size, _type, 0, step.p, ...)`(matrix.cpp:699),最后 `addref()` + `finalizeHdr()`(matrix.cpp:714-715,finalizeHdr 定义在 matrix.cpp:310)。

### 3.5 MatAllocator 抽象与默认分配器

分配器是纯虚接口(mat.hpp:497-525):`allocate/deallocate/map/unmap/upload/download/copy`(mat.hpp:507-521),为 GPU/OpenCL 后端预留了完整的双向搬运虚函数。默认实现 `StdMatAllocator`(matrix.cpp:126-177):`allocate` 自顶向下累积 `total *= sizes[i]` 算出总字节数,`fastMalloc` 分配并 new 一个 UMatData(matrix.cpp:129-155);外部传入 `data0` 时标记 `USER_ALLOCATED`,销毁时**不释放用户内存**(matrix.cpp:151-152, 170-174)。`fastMalloc` 默认走 malloc,可选 `OPENCV_ENABLE_MEMALIGN` 打开对齐分配(alloc.cpp:99, alloc.cpp:130)。默认分配器是进程级单例:`CV_SINGLETON_LAZY_INIT(MatAllocator, new StdMatAllocator())`(matrix.cpp:196-199),可用 `Mat::setDefaultAllocator` 全局替换(matrix.cpp:191-194;声明 mat.hpp:2179)。

`UMatUsageFlags`(mat.hpp:481-491)是传给分配器的**用途提示**:`USAGE_DEFAULT=0`、`USAGE_ALLOCATE_HOST_MEMORY / DEVICE_MEMORY / SHARED_MEMORY`(mat.hpp:483-488),文档明言除 DEFAULT 外均属实验性,主要服务于 OpenCL/SVM 场景(mat.hpp:471-479)。UMatData 的 MemoryFlag(mat.hpp:564-568,如 `TEMP_UMAT`、`DEVICE_MEM_MAPPED`)则记录数据块当前处于主机侧还是设备侧。

### 3.6 ROI 与 submatrix:共享底层的 O(1) 切片

矩形 ROI 构造(matrix.cpp:796-826)是"共享底层"的最佳标本:

```cpp
// modules/core/src/matrix.cpp:796-813(节选)
Mat::Mat(const Mat& m, const Rect& roi)
  : flags(m.flags), dims(2), rows(roi.height), cols(roi.width),
    data(m.data + roi.y*m.step[0]),        // 只挪指针,不搬数据
    datastart(m.datastart), dataend(m.dataend), datalimit(m.datalimit),
    allocator(m.allocator), u(m.u), size(&rows)
{
    ...
    data += roi.x*esz;
    if( roi.width < m.cols || roi.height < m.rows )
        flags |= SUBMATRIX_FLAG;           // matrix.cpp:809
    step[0] = m.step[0]; step[1] = esz;    // 继承母矩阵行距(带 padding)
    updateContinuityFlag();
    addref();                              // matrix.cpp:813 计数 +1
```

Range 版本同样在范围不满时打 `SUBMATRIX_FLAG`(matrix.cpp:768/777/809)。整个 ROI 构造函数体到 matrix.cpp:820 结束。`locateROI`(matrix.cpp:1095)与 `adjustROI`(matrix.cpp:1116)利用 datastart/dataend 反推/扩张子矩阵在母图中的位置。类文档给出承诺:头拷贝与 ROI 切片都是 O(1),要独立副本用 `clone()`(mat.hpp:685-688, mat.hpp:709-723)。

**clone 的时机**:OpenCV 的策略是"赋值即共享 + 显式深拷"。`clone()` 就是 `copyTo`(matrix.cpp:512-517;`Mat::copyTo` 定义于 copy.cpp:427)。它不做隐式写时复制——`Mat B = A; B.setTo(0)` 会连 A 一起清零;正确写法是 `Mat B = A.clone()`。所谓 COW 由**函数签名约定**实现:改写型函数一律收 `OutputArray`,内部经 `_OutputArray::create` 另行分配,天然不踩输入数据(见 §5)。

### 3.7 UMat 与 Mat_<_Tp>:同一个故事的两个变体

`class CV_EXPORTS UMat`(mat.hpp:2459)是 Mat 的透明计算 API(T-API)孪生兄弟:字段布局几乎同构——flags/dims/rows/cols/data、datastart/dataend/datalimit、u/size/step 一应俱全(mat.hpp:2665-2674 区段),只是 `u->urefcount` 与 `u->refcount` 分别统计 UMat 侧与 Mat 侧的引用(mat.hpp:588-589),配合 MemoryFlag(`COPY_ON_MAP/TEMP_UMAT/DEVICE_MEM_MAPPED`,mat.hpp:564-568)在主机/设备内存间惰性迁移。`Mat::getUMat()`(mat.hpp:1104)给出 Mat→UMat 的桥。本报告不展开 OpenCL 细节,留待后续报告。另有一个薄封装模板 `Mat_<_Tp>`(mat.hpp:2195-2197,"Template matrix class derived from Mat"),在编译期绑定元素类型,省掉运行时 `at<>(i,j)` 的类型检查,底层仍是同一个 Mat 头。

## 4. Mat 表达式:MatExpr 的延迟计算

`A + B` 并不立即算,而是返回一个 `MatExpr`(类定义 mat.hpp:3612;字段:`const MatOp* op`(mat.hpp:3643)、操作数 `a,b,c`(mat.hpp:3646)、系数 `alpha,beta` 与 `Scalar s`(mat.hpp:3647-3648))。每个运算对应一个 `MatOp` 策略子类(mat.hpp:3525-3564,核心纯虚是 `assign(expr, m, type)`,mat.hpp:3532)+ 一个进程级单例:

```cpp
// modules/core/src/matrix_expressions.cpp(单例清单,行 49-181)
static MatOp_Identity g_MatOp_Identity;   // :49
static MatOp_AddEx    g_MatOp_AddEx;      // :71   A*a + B*b + s
static MatOp_Bin      g_MatOp_Bin;        // :89   逐元素乘/除
static MatOp_Cmp      g_MatOp_Cmp;        // :104  比较
static MatOp_GEMM     g_MatOp_GEMM;       // :134  矩阵乘
```

`MatExpr::MatExpr(const Mat&)` 把普通 Mat 包装成 Identity 表达式(matrix_expressions.cpp:612)。求值发生在**赋值或转换**瞬间:转换运算符 `MatExpr::operator Mat()` 就是 `Mat m; op->assign(*this, m); return m;`(mat.inl.hpp:3083-3089);`Mat::operator=(const MatExpr&)`(mat.hpp:1101)更聪明——"能复用已分配好的目标缓冲就不重新分配",文档举例 `C = A + B` 直接展开为 `add(A, B, C)`(mat.hpp:1094-1100)。分配端的策略代码在 `MatOp_AddEx::assign`(matrix_expressions.cpp:1293 起):按 alpha/beta 的取值分派到 `cv::add / subtract / scaleAdd / addWeighted`(matrix_expressions.cpp:1300-1316),一次落盘,消除了中间临时矩阵。

## 5. InputArray / OutputArray:一套哑类型吃下多种容器

`_InputArray`(mat.hpp:160)内部只有三个字段 `int flags; void* obj; Size sz`(mat.hpp:261-263),类型信息编码在 flags 的高位:`KIND_SHIFT=16`、`KIND_MASK=31<<KIND_SHIFT`(mat.hpp:164-167),种类枚举涵盖 `MAT/MATX/STD_VECTOR/STD_VECTOR_MAT/UMAT/STD_BOOL_VECTOR/STD_ARRAY_MAT/OPENGL_BUFFER/CUDA_GPU_MAT` 等(mat.hpp:169-188,`EXPR` 已删,注记 PR#17046)。它为 Mat、MatExpr、vector<T>、Matx、double、GpuMat、UMat……各备了一个构造重载(mat.hpp:193-214),构造时把"我是哪种容器"写进 flags。

按 kind 分发的取值逻辑在 `_InputArray::getMat_`(modules/core/src/matrix_wrap.cpp:14-75):

```cpp
// modules/core/src/matrix_wrap.cpp:14-65(节选)
Mat _InputArray::getMat_(int i) const
{
    _InputArray::KindFlag k = kind();              // :16 取出 kind 位域
    if( k == MAT )   { const Mat* m=(const Mat*)obj; return i<0 ? *m : m->row(i); }  // :19-25
    if( k == UMAT )  { ... return m->getMat(accessFlags); }   // :27-33
    if (k == MATX)   { return Mat(sz, flags, obj); }          // :35-38
    if( k == STD_VECTOR ) { ...Mat(size(), t, (void*)&v[0])... }  // :41-47
    if( k == STD_BOOL_VECTOR ) { ...拷成一行 CV_8U... }        // :50-56
    if( k == NONE )  return Mat();                 // :65-66
    ...
}
```

(`UMat` 路径经 `getUMat`,matrix_wrap.cpp:126。)输出侧 `_OutputArray` 继承 `_InputArray`(mat.hpp:296),多出的关键动作是 `create()`:按 kind 分发,若目标形状/类型已匹配则原地复用,否则重新分配(matrix_wrap.cpp:1268 起的多维版 `_OutputArray::create`)。**注意**:_InputArray/_OutputArray 的实现实际位于 modules/core/src/matrix_wrap.cpp,而非传闻中的 src/array.cpp——array.cpp(3254 行)承载的是 C API(CvMat/CvMemStorage 等)兼容层。

## 6. 错误处理:CV_Error 与 cv::Exception

宏定义在 modules/core/include/opencv2/core/base.hpp(静态分析分支的简化版在 base.hpp:383-385;常规分支):

- `CV_Error(code, msg)` → `cv::error(code, msg, CV_Func, __FILE__, __LINE__)`(base.hpp:399);
- `CV_Error_(code, args)` 支持 printf 风格格式化(base.hpp:413);
- `CV_Assert(expr)` 失败时以 `Error::StsAssert` 抛出,Debug/Release 都生效(base.hpp:423)。

`cv::error(int, ...)` 先构造 `Exception` 再转发(system.cpp:1285-1287)。`Exception`(modules/core/include/opencv2/core.hpp:119,文档"Class passed to an error"在 core.hpp:112)携带五元组 `code/err/func/file/line`(core.hpp:141-145)。`error(const Exception&)`(system.cpp:1246)依次:交给自定义回调 `customErrorCallback`(system.cpp:1261-1263)→ 可选 dump → `throw exc`(system.cpp:1274);回调可通过 `cv::redirectError` 替换(system.cpp:1304-1315)。

## 7. 基础设施速览

- **TLS(线程本地存储)**:平台抽象类 `TlsAbstraction`(system.cpp:1502),单例常驻、刻意不析构以免析构顺序问题(system.cpp:1548-1551 注释 "memory leak is intended");Windows 实现基于 `__declspec(thread)`(system.cpp:1558)。对外封装是模板 `TLSData<T>`(modules/core/include/opencv2/core/utils/tls.hpp:63)与可汇总的 `TLSDataAccumulator<T>`(tls.hpp:88),并行算法靠它保存每线程状态。
- **parallel_for(一句话,细节留后续报告)**:`cv::parallel_for_(range, body, nstripes)`(modules/core/src/parallel.cpp:507)是统一入口,内部 `parallel_for_impl`(parallel.cpp:552)按构建选项选择 TBB/OpenMP/**PPLP**/串行等后端,并主动放弃并行化嵌套调用(parallel.cpp:537)。
- **版本号**:`CV_VERSION_MAJOR/MINOR/REVISION/STATUS` 定义于 modules/core/include/opencv2/core/version.hpp:9-12,拼接宏 `CV_VERSION` 在 version.hpp:19;本基线为 `4.13.0-dev`。

## 8. 关键函数速查表(均为已核对出处)

| 函数/机制 | 位置 | 一句话 |
|---|---|---|
| `Mat::Mat(const Mat&)` | matrix.cpp:401 | 浅拷头 + 原子加计数 |
| `Mat::~Mat()` | matrix.cpp:477 | release() + 释放多维 step 数组 |
| `Mat::operator=(const Mat&)` | matrix.cpp:484 | 加对方计数,再释放自己旧引用 |
| `Mat::clone()` | matrix.cpp:512 | 借 copyTo 的完全深拷 |
| `Mat::create(rows,cols,type)` | matrix.cpp:527 | 同形同型直接短路返回 |
| `Mat::create(d,sizes,type)` | matrix.cpp:659 | release→setSize→allocator→addref |
| `Mat::addref()/release()` | matrix.cpp:541 / 547 | 计数增减,减到 0 触发销毁 |
| `Mat::deallocate()` | matrix.cpp:733 | 归还 UMatData 给 currAllocator |
| `Mat::locateROI/adjustROI` | matrix.cpp:1095 / 1116 | 靠 datastart/dataend 反推/扩张 ROI |
| `Mat::total()` | matrix.cpp:577 | 各维 size 连乘 |
| `updateContinuityFlag/finalizeHdr` | matrix.cpp:283 / 310 | 连续性与头字段的收尾校正 |
| `StdMatAllocator::allocate` | matrix.cpp:129 | 累乘算字节,fastMalloc,new UMatData |
| `getStdAllocator` | matrix.cpp:196 | 进程级单例(CV_SINGLETON_LAZY_INIT) |
| `_InputArray::getMat_` | matrix_wrap.cpp:14 | 按 kind 分发成 Mat 视图 |
| `_OutputArray::create`(ND) | matrix_wrap.cpp:1268 | 输出缓冲按需分配/复用 |
| `cv::error` | system.cpp:1246 / 1285 | 回调→dump→throw 的错误管线 |
| `parallel_for_` | parallel.cpp:507 | 多后端并行循环统一入口 |

## 9. 设计动机(为什么这样造)

1. **为什么引用计数而非 GC**:视觉函数每秒要进出成千上万个"图像",GC 的停顿与不可预测回收不可接受;引用计数让"最后持有者销毁"在确定性时刻发生(matrix.cpp:547-552),头拷贝 O(1)(mat.hpp:686-688),且计数与数据块(UMatData)绑定而非与 Mat 头绑定,天然支持多线程下 `CV_XADD` 原子增减(cvdef.h:697-704)。代价是用户必须显式 `clone()` 才能独立副本——用可预期的语义换掉运行时的不确定性。
2. **为什么 step 有 padding(行距 ≥ 行宽)**:ROI、行对齐、外部缓冲(如采集卡的 stride)都要求"下一行首地址 ≠ 上一行首地址 + 行宽"。step 与 rows 解耦后,`Mat(高,宽,类型,外部指针,step)` 能零拷贝包装异构内存(matrix.cpp:419-445, BadStep 断言在 437),ROI 只需挪 data 指针、继承 step(matrix.cpp:811),寻址公式仍然统一(mat.hpp:646-648)。
3. **为什么 InputArray 能收多种类型**:把"容器种类"压进一个 int 的 kind 位域(mat.hpp:164-188),用 `void* obj` 擦除具体类型,再在 `getMat_/_OutputArray::create` 里按 kind 分发(matrix_wrap.cpp:14-75, 1268)——一次分派,让一套 API 同时服务 `Mat / vector<T> / Matx / 标量 / UMat / GpuMat`,而调用方永远不需要看到这个适配层(mat.hpp:271-276 文档:"users should not care")。头只有 3 个字段(mat.hpp:261-263),按值传递几乎零成本。
4. **为什么 MatExpr 惰性**:`C = A*B + D` 若逐步求值,会产生两个大临时矩阵;MatExpr 把"运算树"压进一个小结构(op + 三个操作数 + 标量系数,mat.hpp:3643-3648),直到赋值才一次性展开到目标缓冲(mat.inl.hpp:3083-3089),并按系数形态挑最优内核(matrix_expressions.cpp:1303-1317),`operator=` 还能复用旧缓冲(mat.hpp:1094-1100)。惰性把"表达式美观"与"零临时"同时拿到手。
5. **为什么 submatrix 共享底层**:裁剪、选行选列、滑窗处理是视觉算法的基本动作,若每次都拷贝像素,代价随 ROI 数量线性爆炸。共享底层把切片做成 O(1)(matrix.cpp:796-820),datastart/dataend 三件套让子矩阵随时能"回忆"自己在母图中的位置(mat.hpp:2169-2172, locateROI 在 matrix.cpp:1095);是否共享用 `SUBMATRIX_FLAG` 自报家门(mat.hpp:2152),需要独立性时一行 `clone()` 解决(mat.hpp:722-723)。
6. **为什么把分配器抽象成 MatAllocator**:GPU/统一内存要求"同一个 cv::Mat 语义,不同后端分配策略";upload/download/copy 等虚函数(mat.hpp:511-521)让 UMat 数据块可以在主机/设备间迁移而不改上层代码,UMatData 的 flags(mat.hpp:564-568)记录迁移状态。而默认路径(StdMatAllocator)保持纯 CPU、零依赖(matrix.cpp:126-177),复杂度只在被用到时出场。
7. **为什么 size/step 做成代理结构**:二维矩阵占 OpenCV 使用场景的绝大多数,MatStep 用内联的 `buf[2]`(mat.hpp:628-629)承载 row-step/elem-size,免去每次构造都堆分配;`MatSize::p` 直接指向 `&rows`(mat.hpp:616),让 `size[0]==rows` 零成本成立。三维以上才退化为堆数组(~Mat 里 `step.p != step.buf` 判断后释放,matrix.cpp:480-481)。

## 10. 写作素材清单(文件:行号,均已核对)

1. modules/core/include/opencv2/core/mat.hpp:2161-2188 —— Mat 头全部字段(flags→step)
2. modules/core/include/opencv2/core/mat.hpp:586-601 —— UMatData:双引用计数与设备句柄
3. modules/core/include/opencv2/core/mat.hpp:644-651 —— step 寻址公式与不变量(文档)
4. modules/core/src/matrix.cpp:547-565 —— release():减到 0 即销毁
5. modules/core/src/matrix.cpp:659-716 —— create() 完整分配路径与自定义分配器回退
6. modules/core/src/matrix.cpp:796-818 —— Rect ROI 构造 + SUBMATRIX_FLAG
7. modules/core/src/matrix.cpp:126-177 —— StdMatAllocator:默认 CPU 分配/释放
8. modules/core/include/opencv2/core/mat.hpp:497-525 —— MatAllocator 抽象接口
9. modules/core/include/opencv2/core/mat.hpp:481-491 —— UMatUsageFlags 用途提示
10. modules/core/src/matrix_expressions.cpp:1293-1330 —— MatOp_AddEx::assign 融合求值
11. modules/core/include/opencv2/core/mat.inl.hpp:3083-3089 —— MatExpr::operator Mat() 触发求值
12. modules/core/src/matrix_wrap.cpp:14-75 —— _InputArray::getMat_ 的 kind 分发
13. modules/core/include/opencv2/core/base.hpp:399-424 —— CV_Error/CV_Error_/CV_Assert 宏
14. modules/core/include/opencv2/core.hpp:112-145 —— Exception 类与五元组错误信息
15. modules/core/src/system.cpp:1246-1287 —— cv::error():回调→dump→throw
16. modules/core/include/opencv2/core/version.hpp:9-19 —— CV_VERSION 拼装(4.13.0-dev)

(附:modules/core/src/parallel.cpp:507 与 system.cpp:1502 可作为 parallel_for / TLS 专题的开题引子。)

---

*报告完。后续报告 B 将深入 UMat/OpenCL 路径与并行框架细节。*
