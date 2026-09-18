# 第 03 章 · imgproc:图像处理管线的实现

> 基线:commit `d3d247f1`。核心:modules/imgproc/src/。所有热点函数遵循同一分派链:公开 API→CV_OCL_RUN→CALL_HAL→hal::xxx→FilterEngine/函数表→CV_CPU_DISPATCH(SIMD)。

## 3.0 全景:三层分派与滤波骨架

```
文件名即分层:filter.dispatch.cpp(API+HAL)+ filter.simd.hpp(SIMD 内核,按 ISA 重复编译)
可分离滤波骨架(FilterEngine__proceed):
  borderTab 查表补边(边界插值翻译成"偏移表")→环形行缓存
  →rowFilter 1D 水平卷积→攒够 ksize 行→columnFilter 竖直卷积→dst
  (垂直方向不复制像素:列滤波把行指针数组直接指向环形缓存中的逻辑行)
```

## 3.1 FilterEngine 与核的定型

FilterEngine 组合 rowFilter+columnFilter(可分离)或单个 filter2D;isSeparable 判据就是 filter2D 是否为空。**边界插值被翻译成偏移表**:borderTab 只存索引,每行一次 memcpy+gather;BORDER_CONSTANT 指向预填充行。核定型:getKernelType 探测核性质(对称/反对称/平滑/整型);8U 输入且平滑对称时把浮点核转成 32S 定点——**跨平台 bit-exact 的整数路径**。8U→8U 且核面积≤256 用 CV_16U 缓冲,否则 CV_32S。

## 3.2 boxFilter/GaussianBlur/resize

boxFilter 是"求和型"滤波:RowSum 滑动窗增量更新,**每像素 O(1) 与核尺寸无关**(右进左出)。GaussianBlur 三层:核生成(sigma≤0 用固定二项式系数表 softdouble 精确分数;一般 σ=0.15n+0.35 经验公式)→8U 快路径核转 ufixedpoint16 定点(OCL→定点 HAL→CV_CPU_DISPATCH GaussianBlurFixedPoint)→兜底浮点 FilterEngine。边界归一化修正:反射边下核权和≠1,先把权重归一到截断窗再乘回。resize 公开入口仅 45 行,真分派在 hal::resize 六张深度×插值函数表;**2x 缩小 LINEAR↔AREA 互改写**(2x2 均值更快且与 bilinear 一致);LINEAR_EXACT 走 softdouble 定点 bit-exact。warpAffine/Perspective 解析逆阵后折算成 remap 的 (xy,alpha) 短整 map——**remap 是几何变换的通用底座**,消除 N 变换×M 插值×K 边界的组合爆炸。

## 3.3 cvtColor/形态学/直方图

cvtColor 是大 switch+`CvtHelper<Set<3,4>,Set<1>,Set<...>>` 模板校验(通道集/深度集/尺寸策略一行声明)——约 200 个 code 只对应几十个方向函数,新增转换只需写核循环+一行包装;HSV 8U 用定点除法表 hdiv_table。形态学的关键守卫:**仅矩形全非零核才拆两趟**(min/max 无卷积可分离性,盲目两趟会算错任意结构元);iterations>1 折叠成一次大核;BORDER_CONSTANT 默认边值按 op 反转(腐蚀填 +MAX 膨胀填 -MAX)。calcHist 稠密版 CV_32S 累加避免浮点误差,稀疏版 SparseMat 按需建桶(高维直方图绝大多数桶为空)。

## 3.4 设计动机

1. **分离核**:k×k→O(2k);环形行缓存把内存压到 O(k);
2. **BORDER 抽象**:越界取哪折叠成纯函数+索引表,滤波器完全无边界感知;新增边界模式改一处;
3. **remap 通用底座**:采样/边界/插值只实现一处;镜头校正/立体校正免费获得同一套优化;
4. **cvtColor 表驱动**:CvtHelper 消灭 200 个 code 的样板检查;
5. **定点优先**:跨 ISA 逐位相同是测试与嵌入式确定性部署的前提;Q7/Q15 恰好映射 SIMD 饱和乘加;
6. **三套加速路径共存**:OCL/HAL/SIMD 覆盖不同部署形态,每层失败即回落。

## 3.5 FAQ

**Q1:为什么 GaussianBlur 能比理论快?**
滑动和与定点核;3x3/5x5 二项式表 softdouble 精确。

**Q2:resize 的 LINEAR_EXACT 是什么?**
softdouble 定点系数的跨平台逐位一致版本;2x 缩小时借用 AREA。

**Q3:形态学迭代 10 次会跑 10 遍吗?**
矩形核折叠成一次大核(ksize+(iters-1)×(ksize-1))。

**Q4:彩色转灰度的系数?**
Rec.601:0.299/0.587/0.114;8U 走定点乘加 SIMD 特化。

**Q5:remap 支持哪些 map 布局?**
三种(map1=xy 短整对、map1=浮点 xy、map1+map2 分离),CALL_HAL 三种各自处理。

**Q6:calcHist 高维会爆内存吗?**
稀疏版按需建桶;越界的点直接丢弃(整点判定)。

**Q7:自适应阈值怎么实现?**
boxFilter(或高斯)求局部均值→src-mean-C 的比较循环,自身一遍。

**Q8:OCL/HAL/SIMD 会嵌套吗?**
不会:OCL 在公开 API 短路;HAL 在 hal:: 包装层替换;DISPATCH 只在 .simd.hpp 内核粒度。

**Q9:8U 滤波为什么用 16S 中间缓冲?**
核面积 ≤256 时 16 位够且 SIMD 友好;否则升 32S。

**Q10:warpAffine 为什么要 INTER_BITS=5 位小数?**
把小数坐标折算成 INTER_TAB_SIZE² 的查表索引,块内调 remap。

## 3.6 小结与深挖方向

本章结论:**imgproc="三层分派+分离核两趟+偏移表补边+remap 底座+定点 bit-exact"**。深挖:

1. INTER_LINEAR_EXACT 与普通 LINEAR 的逐位差异场景;
2. LAPACK 在 hal_internal 的小矩阵阈值(GEMM 100/SVD 25);
3. cvtColor 的 OclHelper 模板与内核参数装配;
4. calcHist_8u 的 4 路展开直方计数;
5. threshold 的 Otsu/Triangle 自动阈值实现。
