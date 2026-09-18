# 第 06 章 · HAL、并行与工程文化(卷二·收尾)

> 基线:commit `d3d247f1`。全库统一的"性能瀑布"四级降级阶梯:OpenCL→硬件 HAL→CV_CPU_DISPATCH SIMD→纯 C++,每级失败无损回落。

## 6.0 全景:一次 cv::blur 的四级阶梯

```
cv::blur(=boxFilter(normalize=true))
 ├ 第1级 CV_OCL_RUN:UMat+OCL 可用→GPU kernel 并 return
 ├ 第2级 CALL_HAL(boxFilter, cv_hal_boxFilter,…):外置 HAL(carotene/KleidiCV/IPP/OpenVX)
 │   构建期静态符号替换;返回 OK 完成/NOT_IMPLEMENTED 自动落到下一级
 ├ 第3级 CV_CPU_DISPATCH:blockSum→AVX512→AVX2→SSE4.2→…逐级试探
 │   每级以运行时 cpuid 结果为门(CV_CPU_HAS_SUPPORT_xxx)
 └ 第4级 纯 C++ baseline(cpu_baseline 命名空间的标量循环)
任何一台机器至少能跑通最后一级——"性能是特性"需要每一级可验证
```

## 6.1 Universal intrinsics:一套 v_uint8 统一九种 SIMD

intrin.hpp 是"路由器":SSE/NEON/VSX/MSA/WASM/RVV/LSX 走 128 位实现,AVX2/AVX512/LASX 可**叠加编译**(v256_/v512_ 前缀与 vx_ 宽度自适应前缀共存);对算法作者暴露"当前机器最宽寄存器"别名(AVX512 上 typedef v_uint8x64 v_uint8)。RVV 可伸缩向量另有宽度无关类型。每个后端独立命名空间(hal_AVX2/opt_AVX2),同名函数在不同 ISA 下编译成多份互不冲突的符号;纯 C++ 仿真(intrin_cpp.hpp)让无 SIMD 平台也走同一套 API。

## 6.2 硬件 HAL:链接期静态替换

HAL 接口是纯 C 的 hal_ni_* 默认内联函数,一律返回 NOT_IMPLEMENTED;错误码协议三值(OK/NOT_IMPLEMENTED/UNKNOWN)——**HAL 不允许半吊子实现**(其他错误码立即抛异常)。替换是文档化的宏技巧(#undef/#define)+构建期生成 custom_hal.hpp,**零运行时开销**;无 cv_hal_set 运行时注册 API(全库 grep 无此符号)。供应商 HAL 在根目录 hal/:carotene(ARM)/fastcv(高通)/kleidicv/ipp/openvx/ndsrvp/riscv-rvv;第三方闭源经 find_package 注入。内置 hal_internal 用 LAPACK 实现 LU/SVD/QR/GEMM 并给小矩阵设阈值(避免 LAPACK 小规模反而慢)。

## 6.3 CV_CPU_DISPATCH:三层物理隔离

*.dispatch.cpp 是每个内核的唯一入口(INSTRUMENT_REGION→CALL_HAL→CV_CPU_DISPATCH);调度由三部分组成:声明层(宏链)、生成层(CMake 模板按 ISA 拼接调用链)、探测层(启动时 CPUID 填 have[] 表)。**每个 dispatch 模式编译成独立目标文件**,代码隔离在 opt_AVX2 等命名空间——AVX2 代码永远不会意外跑在只支持 SSE2 的机器上;跨 ISA 边界有 VZeroUpperGuard 规避 AVX-SSE 转换陷阱。预处理后等价于 `if (checkHardwareSupport(CV_CPU_AVX2)) return opt_AVX2::f(args);` 的宏链——无函数指针表,分支预测友好,调试器可直接步入。

## 6.4 parallel_for:一个语义,七种后端

后端:TBB/HPX/OpenMP 显式启用,GCD/WinRT/pthreads 自动可用;4.x 叠加 ParallelForAPI 可插拔层(OPENCV_PARALLEL_BACKEND 环境变量,运行时热切换)。两个关键语义:**嵌套并行退化为串行**(原子标志防打爆线程数);**nstripes 表达分块粒度**(调用方以"期望切多少条"声明最小工作量)。wrapper 层负责跨线程传递 RNG 状态并在结束时恢复、把 worker 异常收集回主线程重抛——**OpenCV 特有语义集中在与后端无关的一层**,换任何后端不丢行为。

## 6.5 绑定与文档

Python 绑定完全生成式:hdr_parser.py 解析公共头([funcname,return,modifiers,args],/O=输出 /S=静态),gen2.py 生成 cv2 胶水与 typing stubs——**头文件是唯一事实源,C++ 与 Python API 从不漂移**;同一流水线喂 Java/ObjC。仓库无 CHANGELOG(根目录仅 README 等)——发布节奏以 GitHub Releases 为准,"代码即文档"文化的另一面。

## 6.6 设计动机

1. **universal intrinsics**:一个算法源文件编译到九类后端,没有它每个 SIMD 内核要维护九份;vx_ 加宽免费吃 AVX512/RVV;
2. **HAL 静态可替换**:供应商不改 OpenCV 一行代码接入;三值协议+自动回落,商业版开源版共用调用树;
3. **dispatch 三层**:AVX512 编译成本只为真支持的机器支付;命名空间隔离+cpuid 门同时拿到全兼容与跑满上限;
4. **自研 parallel**:RNG 传递/异常回收/嵌套退化是 OpenCV 特有语义,必须在后端无关层;
5. **绑定生成式**:以 OpenCV 的 API 面积,手工绑定不可维护;
6. **全库埋 INSTRUMENT_REGION**:"HAL 有没有生效"在 profile 里一眼可见。

## 6.7 FAQ

**Q1:性能瀑布有几级?**
四级:OpenCL→硬件 HAL→CV_CPU_DISPATCH(SIMD)→纯 C++;每级失败无损回落。

**Q2:如何让代码吃满 AVX512?**
算法用 vx_ 宽度自适应前缀写 universal intrinsics;构建启用 AVX512 dispatch。

**Q3:第三方闭源 HAL 怎么接?**
find_package(${hal}) 注入;符号在链接期覆盖。

**Q4:HAL 返回 UNKNOWN 会怎样?**
立即抛异常——HAL 不允许半吊子实现。

**Q5:嵌套 parallel_for 会爆线程吗?**
不会:flagNestedParallelFor 让嵌套调用退化为串行 body。

**Q6:parallel_for 换后端要重编译吗?**
不必:OPENCV_PARALLEL_BACKEND 运行时热切换(内置 TBB/OPENMP 注册表)。

**Q7:AVX 和 SSE 混用有坑吗?**
有:VZeroUpperGuard(RAII)在非 VEX 调用方进入 AVX 函数时清 upper。

**Q8:Python 绑定怎么生成?**
hdr_parser.py 解析头文件(注释修饰 /O /S /A)+gen2.py 生成胶水与 typing stubs。

**Q9:有 CHANGELOG 吗?**
仓库没有:发布节奏看 GitHub Releases;version.hpp 显示 4.13.0-dev。

**Q10:RNG 跨线程怎么一致?**
wrapper 层传递主线程 RNG 状态并在结束时恢复——后端无关。

## 6.8 小结与全系列回顾

本章结论:**工程="universal intrinsics 统一九 ISA+链接期 HAL 替换+宏链三层调度+生成式绑定,每级可验证可回落"**。OpenCV 卷一闭环:01 core 数据结构→02 异构执行→03 imgproc 管线→04 IO→05 dnn 推理→06 工程文化。深挖:gapi 图 API 模块、cv::cuda 命名空间、trace 的 ITT 集成、TS 框架的 perf 宏族。
