# F 卷(卷二收尾章):HAL、并行与工程文化

> 基线:d3d247f1e3125f03171e59ed8fd2fe9454b8ee5f(4.x,version.hpp 显示 `4.13.0-dev`,modules/core/include/opencv2/core/version.hpp:8-11)。本文所有行号均经实际 Read/Grep 核对;代码摘录均 ≤15 行。

## 0. 一张图:一次 `cv::blur` 的四级降级阶梯

```
cv::blur(src, dst, ksize)                        box_filter.dispatch.cpp:421
   │  (blur 只是 boxFilter(normalize=true) 的别名)  box_filter.dispatch.cpp:426
   ▼
cv::boxFilter()
   │
   ├─[第1级: OpenCL]  CV_OCL_RUN(_dst.isUMat(), ocl_boxFilter...)            :373-378
   │      UMat + OCL 可用 → 跑 GPU kernel 并 return;否则宏为空,继续下行
   │      (宏定义: modules/core/include/opencv2/core/opencl/ocl_defs.hpp:80)
   ▼
   ├─[第2级: 硬件 HAL]  CALL_HAL(boxFilter, cv_hal_boxFilter, ...)           :399-401
   │      外置 HAL(carotene/KleidiCV/IPPV/OpenVX...)在构建期被静态替换进来;
   │      返回 CV_HAL_ERROR_OK → 完成;返回 NOT_IMPLEMENTED → 自动落到下一级
   ▼
   ├─[第3级: CV_CPU_DISPATCH SIMD]                                            :407-411
   │      CV_CPU_DISPATCH(blockSum/createBoxFilter, ..., CV_CPU_DISPATCH_MODES_ALL)
   │      宏链展开为 AVX512→AVX2→SSE4.2→…→baseline 的逐级试探,
   │      每级以运行时 cpuid 结果为门(CV_CPU_HAS_SUPPORT_xxx)
   ▼
   └─[第4级: 纯 C++] baseline 版本(cpu_baseline 命名空间)
          box_filter.simd.hpp 内所有 SIMD 段都有 `#if (CV_SIMD || CV_SIMD_SCALABLE)`  :315
          关掉 intrinsics(CV_DISABLE_OPTIMIZATION 或目标 ISA 不支持)后
          剩下的就是标量循环(FilterEngine 逐行/逐列累加)
```

注:GaussianBlur 与此同构——smooth.dispatch.cpp:652 先试 OCL,:708/:809 CALL_HAL,:718/:786 CV_CPU_DISPATCH,中间还插了一级 IPP(:714)。这就是 OpenCV 全库统一的"性能瀑布":每一级失败都可无损回落,任何一台机器至少能跑通最后一级。

## 1. Universal intrinsics:一套 `v_uint8` 统一九种 SIMD

核心思想写在头文件注释里:HAL API 放在 `cv::hal` 命名空间,而 SIMD intrinsics 故意放近 `cv` 命名空间——"make its access from within opencv code more accessible"(modules/core/include/opencv2/core/hal/intrin.hpp:92-95)。

`intrin.hpp` 本体只是"路由器",按编译目标把具体实现引到各家后端(intrin.hpp:222-262):SSE2/NEON/VSX/MSA/WASM/RVV071/LSX 走 128 位实现;随后 AVX2、AVX512、LASX 可以与前级**叠加编译**,用 `v256_`/`v512_` 前缀与 `vx_` 宽度自适应前缀共存(注释见 intrin.hpp:264-271,代码 272-290)。对算法作者暴露的是"当前机器最宽寄存器"别名:AVX512 目标上 `typedef v_uint8x64 v_uint8;`(intrin.hpp:441),`CV_SIMD_WIDTH` 相应取 64(intrin.hpp:434-437);RVV 可伸缩向量另有成套宽度无关类型 `v_uint8/v_int16/v_float32...`(intrin.hpp:417-427)。类型到重载的胶水由 `CV_DEF_REG_TRAITS` 表提供(intrin.hpp:374-427)。

```cpp
// intrin.hpp:222-234(节选)
#if (CV_SSE2 || CV_NEON || CV_VSX || CV_MSA || CV_WASM_SIMD || CV_RVV071 || CV_LSX) && !defined(CV_FORCE_SIMD128_CPP)
#define CV__SIMD_FORWARD 128
#include "opencv2/core/hal/intrin_forward.hpp"
#endif
#if CV_SSE2 && !defined(CV_FORCE_SIMD128_CPP)
#include "opencv2/core/hal/intrin_sse_em.hpp"
#include "opencv2/core/hal/intrin_sse.hpp"
#elif CV_NEON && !defined(CV_FORCE_SIMD128_CPP)
#include "opencv2/core/hal/intrin_neon.hpp"
```

"最宽寄存器"别名是按宽度择优选择的,512 位目标上(intrin.hpp:431-441):

```cpp
// intrin.hpp:431-441(节选)
#if CV_SIMD512 && (!defined(CV__SIMD_FORCE_WIDTH) || CV__SIMD_FORCE_WIDTH == 512)
#define CV__SIMD_NAMESPACE simd512
namespace CV__SIMD_NAMESPACE {
    #define CV_SIMD 1
    #define CV_SIMD_64F CV_SIMD512_64F
    #define CV_SIMD_FP16 CV_SIMD512_FP16
    #define CV_SIMD_WIDTH 64
    //! @brief Maximum available vector register capacity 8-bit unsigned integer values
    typedef v_uint8x64    v_uint8;
```

每个后端实现在独立命名空间(`hal_baseline`/`hal_AVX2`…,见 intrin.hpp:180-190 的 `CV_CPU_OPTIMIZATION_HAL_NAMESPACE` 宏族),配合第 3 节的 `opt_*` dispatch 命名空间,才能让同一个函数名在不同 ISA 下编译成多份互不冲突的符号。全套后端头文件在 modules/core/include/opencv2/core/hal/ 下:sse/neon/avx/avx512/vsx/msa/wasm/rvv071/rvv_scalable/lsx/lasx,外加纯 C++ 仿真 intrin_cpp.hpp(没有 SIMD 的平台也走同一套 `v_uint8` API)与 `simd_utils.impl.hpp` 公共数学件(目录经 ls 核对)。

## 2. 硬件 HAL:构建期静态符号替换

HAL 接口是纯 C 风格的 `hal_ni_*` 默认内联函数,一律返回"未实现":

```cpp
// modules/core/src/hal_replacement.hpp:83(典型默认体)
inline int hal_ni_add8u(const uchar *src1_data, size_t src1_step, const uchar *src2_data, size_t src2_step, uchar *dst_data, size_t dst_step, int width, int height) { return CV_HAL_ERROR_NOT_IMPLEMENTED; }
```

错误码协议只有三个(modules/core/include/opencv2/core/hal/interface.h:9-11):

```c
#define CV_HAL_ERROR_OK 0
#define CV_HAL_ERROR_NOT_IMPLEMENTED 1
#define CV_HAL_ERROR_UNKNOWN -1
```

替换机制是文档化的宏技巧:"Define your functions to override default implementations: `#undef hal_add8u / #define hal_add8u my_add8u`"(hal_replacement.hpp:61-66)。构建系统为启用的 HAL 生成 `custom_hal.hpp`(模板 cmake/templates/custom_hal.hpp.in:1-6,唯一内容是 `@_hal_includes@` 占位符),并在 hal_replacement.hpp 尾部统一 include `hal_internal.hpp` 与 `custom_hal.hpp`(hal_replacement.hpp:1215-1216)——被替换的符号在编译期就换掉了,零运行时开销。调用侧一律走 `CALL_HAL` 宏:

```cpp
// modules/core/src/hal_replacement.hpp:1220-1234(节选)
#define CALL_HAL_RET2(name, fun, retval, ...) \
{ \
    int res = __CV_EXPAND(fun(__VA_ARGS__)); \
    if (res == CV_HAL_ERROR_OK) \
        return retval; \
    else if (res != CV_HAL_ERROR_NOT_IMPLEMENTED) \
        CV_Error_(cv::Error::StsInternal, \
        ("HAL implementation " CVAUX_STR(name) " ==> " CVAUX_STR(fun) " returned %d (0x%08x)", res, res)); \
}
#define CALL_HAL(name, fun, ...) \
CALL_HAL_RET2(name, fun, ,__VA_ARGS__)
```

语义:OK 就走 HAL;NOT_IMPLEMENTED 静默回落到下一级;其他错误码立即抛异常——**HAL 不允许半吊子实现**。值得强调:这里没有 `cv_hal_set` 之类的运行时注册 API(全库 Grep 无此符号),替换完全在链接期决定。

仓库自带的 HAL 供应商在根目录 hal/(ls 核对):carotene(ARM NEON)、fastcv(高通)、kleidicv(ARM)、ipp(Intel)、openvx、ndsrvp(Andes)、riscv-rvv。以 openvx 为例,它自带独立的 README 与 C++ 封装库 ivx——"lightweight - minimal overhead vs standard C API / automatic references counting / exceptions instead of return codes"(hal/openvx/README.md:1-9),即把 OpenVX 图 API 包成异常风格的 C++ 再挂进 HAL 接口。根 CMakeLists 的装配逻辑(CMakeLists.txt:1006-1059):按名字 `add_subdirectory(hal/<name>)` 后 `ocv_hal_register(...)` 并登记到 `OpenCV_USED_HAL`(构建信息里可见,如 :1046);不认识的 hal 名字退到 `find_package(${hal} NO_MODULE QUIET)`(CMakeLists.txt:1054-1057)——这就是第三方闭源 HAL 的接入点。内置的 `hal_internal.*` 则是"内部 HAL":用 LAPACK 实现 LU/SVD/QR/gemm/Cholesky 等声明(hal_internal.hpp:48-64),并给小矩阵设阈值避免 LAPACK 在小规模上反而慢(modules/core/src/hal_internal.cpp:60-65,如 GEMM 100、SVD 25、QR 30)。

## 3. CV_CPU_DISPATCH:baseline/SIMD 多层调度

没有独立的 cpu_dispatch.cpp 文件,调度系统由三部分组成。

**(a) 声明层**:`*.dispatch.cpp` 是每个内核的唯一入口,一行宏完成"打点 + HAL 回落 + SIMD 调度":

```cpp
// modules/core/src/mathfuncs_core.dispatch.cpp:12-19
void cartToPolar32f(const float* x, const float* y, float* mag, float* angle, int len, bool angleInDegrees)
{
    CV_INSTRUMENT_REGION();
    CALL_HAL(cartToPolar32f, cv_hal_cartToPolar32f, x, y, mag, angle, len, angleInDegrees);
    CV_CPU_DISPATCH(cartToPolar32f, (x, y, mag, angle, len, angleInDegrees),
        CV_CPU_DISPATCH_MODES_ALL);
}
```

`CV_CPU_DISPATCH_MODES_ALL` 由 CMake 生成的 `*.simd_declarations.hpp` 注入(mathfuncs_core.dispatch.cpp:8 的注释:"defines CV_CPU_DISPATCH_MODES_ALL=AVX2,...,BASELINE based on CMakeLists.txt content")。

**(b) 宏链层**:`CV_CPU_DISPATCH` 展开为编译期拼出的调用链(cv_cpu_dispatch.h:22-25),每个 ISA 一环;环的形态由 CMake 模板生成(cmake/OpenCVCompilerOptimizations.cmake:856-880),分三种命运(模板见 :860-877):

- 该 ISA 进了 baseline(`CV_CPU_COMPILE_xxx`):`CV_CPU_HAS_SUPPORT=1`,直接 return baseline 版本,零运行时开销;
- 进了 dispatch 列表:`CV_CPU_HAS_SUPPORT_xxx` 是运行时 `cv::checkHardwareSupport(CV_CPU_xxx)`,`CV_CPU_CALL_xxx` 变成 `if (...) return (opt_xxx::fn args)`;
- 都不是:整环为空宏,链自然终止于 baseline。

生成结果的实例(modules/core/include/opencv2/core/cv_cpu_helper.h:6-14):

```cpp
// cv_cpu_helper.h:6-14(节选,SSE 为例)
#  define CV_CPU_HAS_SUPPORT_SSE 1                      // baseline 时
#  define CV_CPU_CALL_SSE(fn, args) return (cpu_baseline::fn args)
#  define CV_CPU_CALL_SSE_(fn, args) return (opt_SSE::fn args)
// dispatch 模式时:
#  define CV_CPU_HAS_SUPPORT_SSE (cv::checkHardwareSupport(CV_CPU_SSE))
#  define CV_CPU_CALL_SSE(fn, args) if (CV_CPU_HAS_SUPPORT_SSE) return (opt_SSE::fn args)
```

**(c) 运行时探测层**:system.cpp 启动时用 CPUID 填 `have[]` 表——x86 上先 leaf 1 取 SSE/AVX 位,再 leaf 7 取 AVX2/AVX-512 位(modules/core/src/system.cpp:461-486),`checkHardwareSupport(feature)`(:857)即查该表。

每个 dispatch 模式编译成**独立的目标文件**,代码隔离在 `namespace opt_AVX2` 等命名空间中(cv_cpu_dispatch.h:10-18),编译选项按模式注入(OpenCVCompilerOptimizations.cmake:652-687,如 `CV_CPU_COMPILE_AVX2=1` 定义与对应 `-mavx2` 标志)。三层物理隔离意味着:AVX2 代码永远不会意外跑在只支持 SSE2 的机器上——因为带 AVX2 编译选项的目标文件根本不会被调用。跨 ISA 边界还有一个工程细节:当 AVX 函数从非 VEX 编译的调用方进入时要先 `_mm256_zeroupper()`,由 RAII 守卫完成(modules/core/include/opencv2/core/cv_cpu_dispatch.h:202-214)。

顺带分清另一类"dispatch":`depthDispatch`(modules/core/include/opencv2/core/detail/dispatch_helper.impl.hpp:13-43)是按**数据深度**(CV_8U/16S/32F…)的模板分发,与这里的按 **ISA** 分发相互正交,后者才是 CV_CPU_DISPATCH 的职责。

## 3.5 校验:dispatch 链是编译期展开的

值得给读者一个直观感受——`CV_CPU_DISPATCH(f, args, AVX2, SSE4_2, BASELINE)` 这类调用在预处理后等价于:

```text
if (checkHardwareSupport(CV_CPU_AVX2))    return opt_AVX2::f(args);
if (checkHardwareSupport(CV_CPU_SSE4_2))  return opt_SSE4_2::f(args);
return cpu_baseline::f(args);
```

没有任何函数指针表或注册动作,链由宏拼接(`__CV_CPU_DISPATCH_CHAIN_ ## mode`,cv_cpu_dispatch.h:22-25)在编译期完成,分支预测友好,也便于调试器直接步入。

## 4. parallel_for:一个语义,七种后端

后端优先级注释本身就说明设计(modules/core/src/parallel.cpp:95-103):TBB/HPX/OpenMP 需显式启用;GCD(仅 Apple)、WinRT、ms-concurrency(Windows 运行时自带)、pthreads 自动可用。选中的后端落地为 `CV_PARALLEL_FRAMEWORK` 字符串(parallel.cpp:140-154)。

4.x 又叠加了新的可插拔层 `ParallelForAPI`:初始化时读环境变量 `OPENCV_PARALLEL_BACKEND`(modules/core/src/parallel/parallel.cpp:33-38),按优先级逐个 try 直至成功(:52-90),全失败则 "fallback on builtin code"(:91-105);运行时可整体热切换 `setParallelForBackend`(:124-199)。内置注册表只有 TBB(或插件 ONETBB/TBB)与 OPENMP(静态或动态插件),优先级 1000 起按序递减(registry_parallel.impl.hpp:30-46, 60-68),可用 `OPENCV_PARALLEL_PRIORITY_LIST` 重排甚至注入新插件(:111-144)。OpenMP 与 TBB 的新式后端工厂分别在 parallel/parallel_openmp.cpp:21 与 parallel/parallel_tbb.cpp:23;插件加载走 plugin_parallel_wrapper.impl.hpp(经 parallel/parallel.cpp:20-21 include)。

`parallel_for_` 本体有两个关键语义(modules/core/src/parallel.cpp:507-541):

1. **嵌套并行退化为串行**:`flagNestedParallelFor` 原子标志,嵌套调用直接 `body(range)`(:520-541)——防止外层 TBB 内层再 fork 打爆线程数;
2. **分块粒度由 nstripes 表达**:`nstripes = cvRound(_nstripes <= 0 ? len : MIN(MAX(_nstripes, 1.), len))`(parallel.cpp:211),即调用方用"期望切多少条"声明每片最小工作量;实际边界按比例舍入(parallel.cpp:348-351)。

```cpp
// modules/core/src/parallel.cpp:566-573(节选)
std::shared_ptr<ParallelForAPI>& api = getCurrentParallelForAPI();
if (api)
{
    CV_CheckEQ(stripeRange.start, 0, "");
    api->parallel_for(stripeRange.end, parallel_for_cb, (void*)&pbody);
    ctx.finalize();  // propagate exceptions if exists
    return;
}
```

之后才是传统的编译期后端 switch:HAVE_TBB 走 `tbbArena.execute`(:576-583);OpenMP 用 `#pragma omp parallel for schedule(dynamic) num_threads(...)`(:588-590);Apple GCD 走 `dispatch_apply_f`(:596);Windows 走 PPL(:600-611);pthreads 走自研线程池 `parallel_for_pthreads`(:617)。

```cpp
// modules/core/src/parallel.cpp:587-591(逐字核对,OpenMP 分支)
#elif defined HAVE_OPENMP

        #pragma omp parallel for schedule(dynamic) num_threads(numThreads > 0 ? numThreads : numThreadsMax)
        for (int i = stripeRange.start; i < stripeRange.end; ++i)
            pbody(Range(i, i + 1));
```

自研池在 parallel_impl.cpp:WorkerThread 用 `pthread_create` 起线程(:241),执行时每线程先认领动态份额 `min(100u, num_threads*4)`(:309-316),用 mutex/cond 唤醒与同步(:408, :461-463);互斥锁注释明确写着保护对象是"并发 parallel_for 调用"下的 job/threads 字段(parallel_impl.cpp:121)。

wrapper 层还负责跨线程传递主线程 RNG 状态并在结束时恢复(parallel.cpp:214, :234-239)、把 worker 线程异常收集回主线程重抛(:358-379)——这是"自研 parallel 框架"最容易被忽视的价值:**OpenCV 特有的语义补丁集中在与后端无关的一层**,换任何后端都不丢行为。线程数管理:`setNumThreads`/`getNumThreads`(parallel.cpp:716, :634,可传播给新后端 :726),默认 `numThreadsMax` 来自 `omp_get_max_threads()` 或 CPU 数(:465-474)。

## 5. 工具与质量:ts/perf/trace/log

**测试框架**:modules/ts 把 GoogleTest 整文件打包进 `ts_gtest.cpp`(11,448 行,直接 include gtest 的 *.cc 源文件,ts_gtest.cpp:48 注释),并支持无线程编译(modules/ts/CMakeLists.txt:47-49,`GTEST_HAS_PTHREAD=0`)。**perf 框架**在 ts_perf.cpp(2,171 行)+ ts_perf.hpp:`TestBase` 提供 warmup(ts_perf.hpp:417)、多迭代计时、`PERF_TEST` 宏族与 impl 切换(:554, :650);misc/ 下还有 trace_profiler.py、report.py、run.py 等离线分析与跑测脚本(ls modules/ts/misc 核对)。

**instrumentation(内建计时树)**:每个内核入口都有 `CV_INSTRUMENT_REGION()`(modules/core/include/opencv2/core/private.hpp:805,关闭时退化为 `CV_TRACE_FUNCTION()`);它按实现类型把耗时记成调用树——`IMPL_PLAIN/IPP/OpenCL/OpenVX` 等枚举(instrumentation.hpp:55),可 `setUseInstrumentation(true)` 开启(:105)。第 3 节的 `.dispatch.cpp` 入口正是靠它在 profile 里显示"这段耗时是 OpenCL 还是 IPP 还是 plain"。

**trace(ITT 导出)**:由 `OPENCV_TRACE` 环境变量总开关(trace.cpp:68),底层桥接 Intel ITT(`__itt_domain`,trace.cpp:194-206),trace 深度与子节点数分别由 `OPENCV_TRACE_DEPTH_OPENCV`/`OPENCV_TRACE_MAX_CHILDREN` 控制(:73-75)。parallel_for 也埋了点(parallel.cpp:510-513)。

**logging**:logtag 体系把"模块名→日志级别"做成可配置对象(modules/core/include/opencv2/core/utils/logtag.hpp:15-20 的 `struct LogTag`),配置解析与生命周期管理在 logtagconfigparser/logtagmanager(src/utils/logtagmanager.cpp:6-7 include 关系核对)。

## 6. Python 绑定:生成式,头文件是唯一事实源

构建时用 `hdr_parser.py` 解析各模块公共头(hdr_parser.py:8-13 内置头清单,core/imgproc/calib3d/highgui 等一一列出),解析产出的声明格式为 `[funcname, return_type, modifiers, args, ...]`,修饰符里 `/O`=输出参数、`/S`=静态方法、`/A`=裸数组(hdr_parser.py:27-29 文档注释);`gen2.py` 消费该 JSON 并生成 cv2 的 C++ 胶水与 typing stubs(gen2.py:3-4 引入 hdr_parser 与 typing_stubs_generator)。装配是一次 CMake custom command(modules/python/bindings/CMakeLists.txt:117-128):

```cmake
add_custom_command(
    OUTPUT ${cv2_generated_files}
    COMMAND "${PYTHON_DEFAULT_EXECUTABLE}" "${PYTHON_SOURCE_DIR}/src2/gen2.py"
        "--config" "${JSON_CONFIG_FILE_PATH}"
        "--output_dir" "${CMAKE_CURRENT_BINARY_DIR}"
    DEPENDS ... "${PYTHON_SOURCE_DIR}/src2/hdr_parser.py" ... ${opencv_hdrs}
    COMMENT "Generate files for Python bindings and documentation")
```

手写的部分只剩少量运行时:`cv2.hpp` 的 `ArgInfo` 把头文件标志位翻译成参数属性(outputarg/arithm_op_src/pathlike/nd_mat,cv2.hpp:43-62)、numpy 内存转换 cv2_convert.*、GIL 与异常处理 cv2_util.*。HDR 处理要点:头文件里的注释修饰直接决定 Python 签名——C++ API 与 Python API 从不漂移,这是生成式绑定最大的工程红利;同一条流水线同时喂 Java/ObjC 生成器(gen2.py 同类引用见 modules/java 与 modules/objc 的 generator CMakeLists,Grep 核对)。

## 7. 构建组织与版本节奏(一瞥)

根 CMakeLists.txt:`cmake_minimum_required(VERSION 3.5)`(:19);选项一律走 `OCV_OPTION` 包装(例:`OPENCV_ENABLE_NONFREE` 默认 OFF,:196),第三方库"平台默认源码编译"策略集中在一排布尔项(CMakeLists.txt:199-207):

```cmake
# CMakeLists.txt:196-205(节选)
OCV_OPTION(OPENCV_ENABLE_NONFREE "Enable non-free algorithms" OFF)
OCV_OPTION(OPENCV_FORCE_3RDPARTY_BUILD   "Force using 3rdparty code from source" OFF)
OCV_OPTION(BUILD_ZLIB               "Build zlib from source"             (WIN32 OR APPLE OR OPENCV_FORCE_3RDPARTY_BUILD) )
OCV_OPTION(BUILD_TIFF               "Build libtiff from source"          (WIN32 OR ANDROID OR APPLE OR OPENCV_FORCE_3RDPARTY_BUILD) )
OCV_OPTION(BUILD_OPENJPEG           "Build OpenJPEG from source"         (WIN32 OR ANDROID OR APPLE OR OPENCV_FORCE_3RDPARTY_BUILD) )
```

`option()` 语义由 CMP0077 固定(:80);HAL 装配见第 2 节(:1006-1061);调度相关的 `CPU_BASELINE`/`CPU_DISPATCH` 缓存变量与帮助文本在 OpenCVCompilerOptimizations.cmake:35-67。版本:`4.13.0-dev`(version.hpp:8-11);README 指向 docs.opencv.org/4.x(README.md:8)。**仓库内没有 CHANGELOG 文件**(根目录仅 README/CONTRIBUTING/SECURITY/LICENSE/COPYRIGHT,ls 核对)——4.x 的发布节奏以 GitHub Releases 与官方公告为准,源码树本身不携带变更日志;这是"代码即文档"文化的另一面。

## 8. 设计动机(为何如此设计)

1. **为什么 universal intrinsics?** 一个算法源文件(如 box_filter.simd.hpp)编译到 SSE/NEON/VSX/MSA/WASM/RVV/LSX/LASX 九类后端 + C++ 仿真(intrin.hpp:222-298 的路由表),没有它,每个 SIMD 内核要维护九份副本;`vx_` 宽度自适应让算法"免费"吃到 AVX512/RVV 的加宽(intrin.hpp:264-271)。
2. **为什么 HAL 可替换(静态符号)?** 让 Carotene/KleidiCV/IPP/OpenVX 等供应商在不修改 OpenCV 一行代码的前提下接入:接口是 C 的、错误协议三值(interface.h:9-11)、NOT_IMPLEMENTED 自动回落(hal_replacement.hpp:1220-1234),商业版与开源版共用同一棵调用树,第三方 HAL 经 `find_package` 注入(CMakeLists.txt:1054-1057)。
3. **为什么 dispatch 三层(baseline/SIMD256/SIMD512)?** AVX-512 目标文件的编译成本与二进制体积只为真正支持的机器支付;编译期命名空间隔离(opt_AVX2,cv_cpu_dispatch.h:10-18)+ 运行时 cpuid 门(cv_cpu_helper.h:12-13)同时拿到"单二进制全兼容"与"每台机器跑满上限",还用 VZeroUpperGuard 规避 AVX-SSE transition 性能陷阱(cv_cpu_dispatch.h:202-214)。
4. **为什么自研 parallel?** RNG 状态传递(parallel.cpp:214,234-239)、异常回收(:358-379)、嵌套并行退化(:520-541)、nstripes 粒度语义(:211)这些 OpenCV 特有语义必须放在与后端无关的一层;同时保留 pthreads 池(parallel_impl.cpp:241)作为零依赖兜底,并用 ParallelForAPI 支持运行时换后端(parallel/parallel.cpp:124-131)。
5. **为什么绑定生成式?** C++ 头文件是唯一事实源,hdr_parser.py + gen2.py(hdr_parser.py:27-29)保证 cv2 与 C++ API 同步演进,输出参数、静态方法、typing stubs 全部自动推导——以 OpenCV 的 API 面积,手工绑定不可维护。
6. **为什么全库埋 CV_INSTRUMENT_REGION?** "性能是特性"的文化需要数据:instrumentation 调用树按 IMPL_PLAIN/IPP/OCL 分色(instrumentation.hpp:55),"HAL 有没有生效"在 profile 里一眼可见;trace 经 ITT 可接 VTune 等外部工具(trace.cpp:194-206)。

## 9. 写作素材清单(文件:行号)

1. modules/core/include/opencv2/core/hal/intrin.hpp:92-95 —— intrinsics 放进 cv 命名空间的动机注释
2. intrin.hpp:264-271 —— AVX2/SSE2 叠加编译与 vx_ 前缀说明
3. intrin.hpp:441 / 417-427 —— `typedef v_uint8x64 v_uint8` 与 RVV 宽度无关类型
4. modules/core/include/opencv2/core/hal/interface.h:9-11 —— HAL 三值错误协议
5. modules/core/src/hal_replacement.hpp:61-66 —— "宏覆盖即替换"文档化说明;:83 默认未实现体
6. hal_replacement.hpp:1220-1234 —— CALL_HAL/CALL_HAL_RET 宏全文
7. modules/core/src/hal_internal.cpp:60-65 —— LAPACK 小矩阵阈值;hal_internal.hpp:48-64 接口清单
8. CMakeLists.txt:1054-1061 —— find_package 第三方 HAL + custom_hal.hpp 生成;:1006-1026 各供应商分支
9. modules/imgproc/src/box_filter.dispatch.cpp:373-401 —— blur 的 OCL→HAL 两级
10. box_filter.dispatch.cpp:407-417 —— blockSum/CPU dispatch→FilterEngine 两级;:421-427 blur 定义
11. modules/core/src/mathfuncs_core.dispatch.cpp:12-19 —— dispatch 入口函数标准范式
12. cmake/OpenCVCompilerOptimizations.cmake:860-879 —— CV_CPU_CALL/dispatch 链生成模板;:652-687 按模式注入编译选项
13. modules/core/include/opencv2/core/cv_cpu_helper.h:6-14 —— 生成结果实例(SSE);cv_cpu_dispatch.h:10-18 命名空间
14. modules/core/src/system.cpp:461-486 —— CPUID 运行时探测(leaf 1 + leaf 7)
15. modules/core/src/parallel.cpp:95-103, 140-154 —— 并行后端优先级与框架选择
16. parallel.cpp:211, 348-351 —— nstripes 分块粒度计算;:507-541 嵌套并行退化
17. modules/core/src/parallel/parallel.cpp:33-38 —— OPENCV_PARALLEL_BACKEND 环境变量;:124-131 热切换
18. modules/core/src/parallel/registry_parallel.impl.hpp:30-46 —— 内置后端注册表;:60-97 优先级
19. modules/core/src/parallel_impl.cpp:241, 309-316 —— pthreads 自研线程池
20. modules/python/bindings/CMakeLists.txt:117-128 —— gen2.py 装配命令;hdr_parser.py:27-29 声明格式

(正文引用均注明于各节,共 20 组,供写作取用。)
