# 第 02 章 · UMat 与 T-API:透明异构计算

> 基线:commit `d3d247f1`。核心:modules/core/src/umatrix.cpp、ocl.cpp(8000+ 行)、CV_OCL_RUN 宏。

## 2.0 全景:两个边界与一条数据流

```
cv::blur(src,dst)——同一份算法代码
  dst 是 Mat:CPU 路径(SIMD/IPP/HAL)
  dst 是 UMat 且 OCL 可用:
    边界 A:Mat::getUMat→创建 temp UMatData(弱链接原 Mat)→clCreateBuffer 上传
    kernel 异步执行(数据留 GPU)——多个 kernel 链式调用数据不回主机
    边界 B:UMat::getMat→clEnqueueMapBuffer(CL_TRUE) 阻塞回读
性能钥匙:两个边界各一次 PCIe 传输;边界之间数据驻留设备——UMat 存在的全部意义
```

## 2.1 Mat↔UMat:两个方向的语义不同

Mat→UMat(getUMat)**创建新的** UMatData 并以 originalUMatData 弱链接原 Mat(TEMP_UMAT 语义);UMat→Mat(getMat)**共享同一个** u,且强制 ACCESS_RW 映射(umatrix.cpp:1075 的 TODO 承认了只读场景的浪费)。OpenCL 库运行期 dlopen(编译期不强依赖),Context 进程级单例;USE_OPENCL 判定链:HAVE_OPENCL 宏→haveOpenCL(枚举平台)→useOpenCL(TLS 线程级开关)→isOpenCLActivated(短路,未激活连运行时都不加载)。

## 2.2 kernel 三级缓存与同步点

`.cl` 源码构建期由 cl2cpp 转成字符串常量(MD5 作 sourceHash);运行期三级缓存:进程内 phash(key=模块+名+hash+设备前缀+buildflags,LRU,**编译失败也缓存**避免反复撞编译器)→磁盘二进制缓存(跨进程)→clCreateKernel。build options 双层拼接(算法侧类型/尺寸常量现拼+厂商/extra 合并),一个 .cl 模板长出成百上千个特化 kernel。**同步点**:所有 map/read/write 一律 CL_TRUE 阻塞;kernel 参数含 temp UMat 时强制 clFinish;真正的 clFlush 全库只有 2 处(Image2D 非连续中转)。

## 2.3 CV_OCL_RUN:顺序降级而非 if/else

```cpp
#define CV_OCL_RUN_(condition, func, ...) \
try { if (cv::ocl::isOpenCLActivated() && (condition) && func) { \
    CV_IMPL_ADD(CV_IMPL_OCL); return __VA_ARGS__; } } \
catch (const cv::Exception&) {}
```

宏允许每个调用点写自己的 condition(尺寸/深度/边界检查),OpenCL 失败即"穿透"到紧随其后的 CPU 实现;isOpenCLActivated 短路保证未激活环境零开销。blur 的完整链:两个 CV_OCL_RUN→CALL_HAL→FilterEngine。性能边界如实:每个 Mat↔UMat 边界≈一次全量 PCIe 传输;离散 GPU 默认 copy-on-map;混合流水线反复转换会把 GPU 收益全部吃掉——官方答案是整条流水线都喂 UMat。

## 2.4 设计动机

1. **造 UMat 而非 Mat 重载**:重载要为每个 API 写双份签名;UMat 把"数据在哪"下沉到 UMatData+MatAllocator 抽象,算法层只见 `_dst.isUMat()` 一个分支;
2. **映射而非总拷贝**:统一内存/Intel 平台零拷贝;离散 GPU pinned 映射让 DMA 直达用户地址;
3. **三层缓存**:OpenCL 编译数十至数百 ms,"透明"不能是"透明的慢";连失败结果也缓存;
4. **宏而非虚函数**:分发条件逐调用点定制;顺序代码无虚表开销;
5. **默认 CPU**:OpenCL 运行时质量参差(workaround 散布),每分支自带条件失败回退。

## 2.5 FAQ

**Q1:Mat 和 UMat 共享数据块吗?**
方向不同:Mat→UMat 创建新 UMatData 弱链接;UMat→Mat 共享同一个 u。

**Q2:OpenCL 是编译期依赖吗?**
不是:运行期 dlopen,可用 OPENCV_OPENCL_RUNTIME=disabled 整体关闭。

**Q3:kernel 编译失败会反复重试吗?**
不会:失败的 Program 也被缓存。

**Q4:什么时候 clFinish?**
kernel 参数含 temp UMat、temp UMat 析构回读、显式 finish()——常规 map/read/write 都是 CL_TRUE 阻塞。

**Q5:GPU 上数据何时回主机?**
temp UMat 析构且 hostCopyObsolete 时 clEnqueueReadBuffer+clFinish。

**Q6:为什么 getMat 强制读写映射?**
TODO 承认的浪费:只读场景也按 ACCESS_RW(umatrix.cpp:1075-1076)。

**Q7:buffer 池是干嘛的?**
复用 cl_mem 避免 clCreateBuffer 反复分配;上限 OPENCV_OPENCL_BUFFERPOOL_LIMIT。

**Q8:build options 怎么拼?**
算法侧现拼类型/尺寸常量+厂商宏(-D AMD_DEVICE 等)+环境变量 extra options。

**Q9:强制走 CPU 有开关吗?**
cv::ocl::setUseOpenCL(false);或环境变量 disabled。

**Q10:HAL 和 OpenCL 什么关系?**
互不重叠的两级:HAL 是 OpenCL 之后 CPU 路径里的替换入口(CALL_HAL)。

## 2.6 小结与深挖方向

本章结论:**T-API="UMatData 双态+映射优先+三级 kernel 缓存+CV_OCL_RUN 顺序降级"**。深挖:

1. buffer pool 的两级实现与 OPENCV_OPENCL_BUFFERPOOL_LIMIT;
2. ASYNC_CLEANUP 清理队列的延迟释放;
3. Kernel::Impl 对参数 UMat 的 urefcount 增持(防悬空);
4. OpenCLExecutionContext 的线程级切换;
5. Intel 小核特化分支(box_filter.dispatch.cpp:197-216)。
