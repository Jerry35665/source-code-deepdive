# C · imgproc:图像处理管线的实现

> 基线:opencv `d3d247f1e3125f03171e59ed8fd2fe9454b8ee5f`(4.x,2025-11-05 同步)。
> 除特别注明外,本文行号均相对 `modules/imgproc/src/` 或 `modules/core/src/` 下的具体文件。

## 0. 源码布局:一套三层分派骨架

imgproc 的所有热点函数都遵循同一套分派链,读任何一处源码前先记住这条路径:

```text
cv::xxx(InputArray...)              公开 API(xxx.dispatch.cpp)
  ├─ CV_OCL_RUN(_dst.isUMat(), ocl_xxx)      T-API:OpenCL 内核
  ├─ CALL_HAL(..., cv_hal_xxx, ...)          供外部 HAL/IPP 替换的钩子
  │     └─ 失败则回落 ocvXxx() 默认实现
  └─ hal::xxx(...) → FilterEngine / 函数表 → CV_CPU_DISPATCH(SIMD 内核,xxx.simd.hpp 按 ISA 多次编译)
```

文件名即分层:`filter.dispatch.cpp`(API+HAL)+ `filter.simd.hpp`(SIMD 内核,由 `filter.simd_declarations.hpp` 定义 `CV_CPU_DISPATCH_MODES_ALL` 后在同一编译单元内按 BASELINE/AVX2 等模式重复编译,见 `filter.dispatch.cpp:57`)。色彩转换同理拆成 `color.cpp`、`color_rgb.dispatch.cpp`、`color_hsv.simd.hpp` 等一族。

## 1. 滤波器通用骨架(ASCII)

以可分离线性滤波(cv::GaussianBlur / boxFilter / sepFilter2D 共用)为例:

```text
                输入 Mat(ROI 可为原图子矩形,locateROI 还原 whole)
                          │
      ┌───────────────────▼────────────────────┐
      │ FilterEngine__start:                   │
      │  计算 dx1/dx2(水平核超出边界的宽度)   │ filter.simd.hpp:145-146
      │  预生成 borderTab[](borderInterpolate  │ filter.simd.hpp:169-181
      │  得到"取哪个像素"的偏移表,查表完成)  │
      │  分配 ringBuf(环形行缓存)            │ filter.simd.hpp:139
      └───────────────────┬────────────────────┘
                          ▼  每送入一行 src
   [补边] memcpy 本行 + 按查表复制左/右边带 → 得到 width+ksize-1 的扩展行
                          │                    filter.simd.hpp:242-262
   [行滤波] rowFilter(1D 水平卷积,SIMD)→ 写入 ringBuf 一行
                          │                    filter.simd.hpp:265-266
   [列滤波] 攒够 ksize.height 行后,列 borderInterpolate 从 ringBuf
            挑出 kheight 行指针 brows[],columnFilter 竖直卷积 → dst
                          │                    filter.simd.hpp:270-291
                          ▼
              输出若干行;ringBuf 循环覆盖(I/O 流式,O(1) 行缓存)
```

要点:**边界插值被翻译成"偏移表"**。borderTab 只存索引,proceed 内每行用一次 memcpy+gather 复制边带;垂直方向不复制像素,列滤波时直接把 brows[i] 指向环形缓存中由 `borderInterpolate` 算出的逻辑行(filter.simd.hpp:272-283),BORDER_CONSTANT 时指向预填充的 constBorderRow(filter.simd.hpp:117-135、275)。

## 2. FilterEngine:可分离滤波的执行引擎

`FilterEngine`(`filterengine.hpp:214`)组合三类滤波器:`BaseRowFilter`/`BaseColumnFilter`(可分离路径)或单个 `BaseFilter`(2D 路径);`isSeparable()` 的判据就是 `filter2D` 是否为空(`filterengine.hpp:249`)。`init()` 在此之上确定 ksize/anchor、检查 `BORDER_WRAP` 非法(`filter.dispatch.cpp:130`)、为 BORDER_CONSTANT 预转 borderValue(`filter.dispatch.cpp:155-161`)。

引擎本身不含算子,`start/proceed/apply` 只是薄封装,真正实现是 `CV_CPU_DISPATCH` 转发到 `FilterEngine__start/__proceed/__apply`(`filter.dispatch.cpp:173-218`)。核心循环 `FilterEngine__proceed`(`filter.simd.hpp:198`):

```cpp
// filter.simd.hpp:232-242(摘录)
int bi = (this_.startY - this_.startY0 + this_.rowCount) % bufRows;
uchar* brow = alignPtr(&this_.ringBuf[0], VEC_ALIGN) + bi*this_.bufStep;
uchar* row  = isSep ? &this_.srcRow[0] : brow;
...
memcpy( row + _dx1*esz, src, (width1 - _dx2 - _dx1)*esz );   // 本行有效区
// 随后按 borderTab 把左右边带 gather 进 row(244-262 行)
// 可分离时: (*this_.rowFilter)(row, brow, width, cn)  (265-266 行)
```

列端输出(`filter.simd.hpp:288-291`):`columnFilter(brows, dst, ...)` 或非可分离的 `filter2D(brows, dst, ...)`——注意 2D 路径同样吃"行指针数组",只是补边发生在水平+垂直两处。这个"行指针数组 + 查表补边"的设计让任意核形状统一走同一条 I/O 契约。

**borderInterpolate 本体在 core**:`modules/core/src/copy.cpp:882`,注释直接画出各模式语义(copy.cpp:873-881)。反射模式是个 do-while 折叠(copy.cpp:896-913);BORDER_CONSTANT 返回 -1 由调用方特殊处理(copy.cpp:922-923)。

**核的定型**:createSeparableLinearFilter(`filter.dispatch.cpp:305`)先用 `getKernelType`(`filter.dispatch.cpp:225-259`,对称/反对称/平滑/整型四标志)探测核性质:

```cpp
// filter.dispatch.cpp:242-257(摘录)
for( i = 0; i < sz; i++ )
{
    double a = coeffs[i], b = coeffs[sz - i - 1];
    if( a != b )      type &= ~KERNEL_SYMMETRICAL;
    if( a != -b )     type &= ~KERNEL_ASYMMETRICAL;
    if( a < 0 )       type &= ~KERNEL_SMOOTH;
    if( a != saturate_cast<int>(a) ) type &= ~KERNEL_INTEGER;
    sum += a;
}
if( fabs(sum - 1) > FLT_EPSILON*(fabs(sum) + 1) ) type &= ~KERNEL_SMOOTH;
```

8U 输入且"平滑+对称、输出 8U"或"整型对称、输出 16S"时尝试把浮点核转成 32S 定点(`createBitExactKernel_32S`,`filter.dispatch.cpp:288-303`),成功则 `bits` 移位、bdepth=CV_32S,得到跨平台 bit-exact 的整数路径(`filter.dispatch.cpp:334-362`)。随后 `getLinearRowFilter/getLinearColumnFilter`(`filter.simd.hpp:2949/3004`)按 (srcType,bufType) 组合选模板:小核(≤5)对称核走 `SymmRowSmallFilter` 特化(`filter.simd.hpp:2960-2965`),否则 `RowFilter<uchar,int,RowVec_8u32s>` 一类,SIMD 与标量通过 `RowVec_8u32s` vs `RowNoVec` 同名算子无缝切换(filter.simd.hpp:315-341 空实现,351 起 SIMD 实现)。

## 3. boxFilter 与 GaussianBlur(smooth / box_filter)

**boxFilter 是"求和型"可分离滤波**:createBoxFilter(`box_filter.simd.hpp:1639`)按精度选缓冲类型——8U→8U 且核面积 ≤256 用 CV_16U,否则 CV_32S/CV_64F(`box_filter.simd.hpp:1645-1653`),再拼 RowSum+ColumnSum 两趟。RowSum 用滑动窗增量更新,O(1) 每像素:

```cpp
// box_filter.simd.hpp:103-111(摘录,cn==1 分支)
ST s = 0;
for( i = 0; i < ksz_cn; i++ ) s += (ST)S[i];      // 首窗求和
D[0] = s;
for( i = 0; i < width; i++ ) {
    s += (ST)S[i + ksz_cn] - (ST)S[i];            // 右进左出
    D[i+1] = s;
}
```

`cv::boxFilter`(`box_filter.dispatch.cpp:365`)的分派次序:两个 `CV_OCL_RUN`(3x3_8UC1 特化 + 通用,373-378 行)→ `CALL_HAL(boxFilter, cv_hal_boxFilter, ...)`(399 行)→ 浮点小核(≤5)走 `blockSum`(407-411 行,按行块累加)→ 其余 FilterEngine(414-417 行)。`cv::blur` 就是 `boxFilter(normalize=true)`(421-427 行)。积分图另有独立实现 `integral()`(sumpixels.*.cpp),boxFilter 的加速实际靠滑动和而非整图积分。

**GaussianBlur 的三层实现**(smooth.dispatch.cpp:609 起):

1. 核生成:`createGaussianKernels`(`smooth.dispatch.cpp:280`)在 sigma>0 而 ksize≤0 时自动定尺寸 `cvRound(sigma*(8U?3:4)*2+1)|1`(288-291 行);sigma≤0 时用固定二项式系数表(3/5/7/9 各一套 softdouble 精确分数,`getGaussianKernelBitExact`,smooth.dispatch.cpp:87-145);一般情形 σx = 0.15n+0.35 经验公式(152 行),softdouble 计算 exp 并归一化(162-176 行)。
2. 8U 快路径:核转 `ufixedpoint16` 定点(`fixedpoint.inl.hpp`),OCL 先行——3x3/5x5 走专用 `ocl_GaussianBlur_8UC1`(652-656 行),否则 `ocl_sepFilter2D_BitExact`(674-680 行);CPU 侧 sigma==0(二项式)先试 `CALL_HAL(gaussianBlurBinomial,...)`(696 行),hint==ALGO_HINT_APPROX 再试通用 `CALL_HAL(gaussianBlur,...)`(701-711 行),最终 `CV_CPU_DISPATCH(GaussianBlurFixedPoint,...)`(718-719 行)。16U 路径用 `ufixedpoint32` 同构(724-787 行)。
3. 兜底:其余深度在 OpenCL 可用时走 `sepFilter2D`(793-798 行),再回落 `createGaussianFilter` 的 FilterEngine 浮点路径(306-314 行)。

`GaussianBlurFixedPoint`(`smooth.simd.hpp:59`)按核尺寸分派到 `hlineSmooth3N121`(1-2-1 二项式,269 行)、`hlineSmooth3N/5N`(331/493 行)等特化;非二项式核则走 `hlineSmooth`(通用 ksize)与 `vlineSmooth`。值得写的细节是**边界归一化修正**:反射边下窗口被截断时,核权和不再为 1,于是先把权重和归一到截断窗再乘回,例如 3 核情形:

```cpp
// smooth.simd.hpp:162(摘录)
ufixedpoint16 msum = borderType != BORDER_CONSTANT ? m[0] + m[1] + m[2] : m[1];
```

固定 1-2-1、1-4-6-4-1 形状还有跨行整体版 `smooth3N121/smooth5N14641`(smooth.simd.hpp:698/826),直接在整块缓冲上做两趟,省掉逐行函数调用。

## 4. resize:五种插值 + 固定比速分支(resize.cpp)

`cv::resize`(`resize.cpp:4201`)异常薄:算 dsize、同尺寸直接 copyTo、`CV_OCL_RUN(ocl_resize)`(4226 行,限定 NEAREST/LINEAR/放大 AREA),然后**一行调 `hal::resize`**(4245 行)。真正的分派在 `cv::hal::resize`(`resize.cpp:3826`):先 `CALL_HAL`(3840 行)让外部 HAL 优先,再按插值类型走六张深度×函数表:

- `linear_tab`/`cubic_tab`/`lanczos4_tab`(`resize.cpp:3849/3883/3911`)——通用路径 `resizeGeneric_`,H/V 两趟分离:水平趟先算 xofs+alpha(4097-4152 行,fx=(dx+0.5)*scale-0.5 的像素中心对齐;8U 用 `INTER_RESIZE_COEF_SCALE` 定点 ialpha,4138-4141 行),核尺寸 linear=2、cubic=4、lanczos4=8(4076-4083 行);系数生成 `interpolateCubic`(964 行)/`interpolateLanczos4`(974 行)。
- `INTER_NEAREST` 直接 `resizeNN`(3993 行,实现 1122 行);`INTER_NEAREST_EXACT` 走 `resizeNN_bitexact`(3999 行,实现 1267 行)。
- **AREA 双分支**:整数倍缩小(浮点 scale 与整数相等)走 `areafast_tab`(4018-4041 行,每输出像素等价于 `iscale_x*iscale_y` 个固定偏移的平均,`resizeAreaFast_Invoker` 并行,2975 行);一般缩小走 `area_tab`+`computeResizeAreaTab` 生成贡献区间表(4044-4066 行,表生成 3334 行)。
- **等价改写**:LINEAR 且恰好 2 倍缩小被改写成 INTER_AREA(4011-4012 行,2x2 均值更快且与 bilinear 结果一致);反向地,INTER_LINEAR_EXACT 在 2x 缩小时也借用 AREA(3976-3981 行),其余用 `resize_bitExact`(`linear_exact_tab`,3953-3963 行,`interpolationLinear` softdouble 定点系数,794 行)——跨平台逐位一致。
- 放大时的 AREA 退化为 bilinear(条件 `scale_x>=1 && scale_y>=1`,4016 行)。

CPU 侧加速不用 CV_CPU_DISPATCH,而是显式 `opt_SSE4_1::` 引用(如 `VResizeLanczos4Vec_32f16u` 内 `#if CV_TRY_SSE4_1` 分支,resize.cpp:1513-1518)与 `resize.avx2.cpp / resize.sse4_1.cpp / resize.lasx.cpp` 三个独立编译单元;垂直核用 `VResize*` 结构、水平核用 `hlineResizeCn<ET,FT,len,needsign,cn>` 定点模板(375 行起,按 1/2/3/4 通道逐一显式实例化)。

通用路径的执行体 `resizeGeneric_Invoker`(`resize.cpp:2167`)是"H 趟缓存 ksize 行中间结果 + V 趟合成"的经典布局,并带一行缓存复用:缩小时多个输出行共享同一源行,`prev_sy[]` 命中就直接 memcpy:

```cpp
// resize.cpp:2215-2231(摘录)
for(int k = 0; k < ksize; k++ ) {
    int sy = clip(sy0 - ksize2 + 1 + k, 0, ssize.height);
    for( k1 = std::max(k1, k); k1 < ksize; k1++ ) {
        if( k1 < MAX_ESIZE && sy == prev_sy[k1] ) // 该源行已算过,复用
        {
            if( k1 > k ) memcpy( rows[k], rows[k1], bufstep*sizeof(rows[0][0]) );
            break;
        }
    }
    ...
}
if( k0 < ksize ) hresize( ..., xofs, alpha, ... );   // 只补算缺失的源行
vresize( (const WT**)rows, dst.data + dst.step*dy, beta, dsize.width );
```

## 5. cvtColor:分派结构 + BGR↔Gray/HSV 要点

`cv::cvtColor`(`color.cpp:192`)是巨型 switch:OCL 先行(204-206 行,`ocl_cvtColor` 14 行起同样 switch,HSV 在 123-125 行),CPU 侧每个 case 调一个 `cvtColorXxx` 包装(color.cpp:228-231 的 BGR2GRAY、270 行的 BGR2HSV)。包装函数用模板 `CvtHelper<VScn,VDcn,VDepth,sizePolicy>`(实现在 `color.simd_helpers.hpp:83`;color.hpp:195 起那份同名代码已被注释废弃)统一做"通道集合/深度集合/尺寸策略"校验与 dst 创建,`Set<i0,i1>` 是编译期整数集合(color.simd_helpers.hpp:50-75):

```cpp
// color_rgb.dispatch.cpp:575-581
void cvtColorBGR2Gray( InputArray _src, OutputArray _dst, bool swapb)
{
    CvtHelper< Set<3, 4>, Set<1>, Set<CV_8U, CV_16U, CV_32F> > h(_src, _dst, 1);
    hal::cvtBGRtoGray(h.src.data, h.src.step, h.dst.data, h.dst.step,
                      h.src.cols, h.src.rows, h.depth, h.scn, swapb);
}
```

hal 层函数(`color_rgb.dispatch.cpp:269`)内再 `CALL_HAL`(276 行)+ `CV_CPU_DISPATCH`(308 行)压到 `color_rgb.simd.hpp`。灰度系数 R2YF/G2YF/B2YF(Rec.601:0.299/0.587/0.114)由 `RGB2Gray` functor 应用,blueIdx 用 swap 顺序而非分支(color_rgb.simd.hpp:583-597);8U 走定点乘加的 SIMD 特化(608 行 `RGB2Gray<uchar>`)。

分派所需的"code → 属性"查询本身也是表格式的纯函数:`dstChannels(code)`(color.hpp:94-139 的 switch)、`greenBits`(141 行)、`uIndex`(162 行)、`isFullRangeHSV/is_sRGB` 等,color.cpp 的主 switch 全靠它们把一个 code 拆解为若干 bool/int 参数传给具体转换。OCL 侧对应 `OclHelper` 模板(color.hpp:240-332):构造函数里完成通道/深度校验、TO_YUV/FROM_YUV 尺寸策略与内核参数装配(274-315 行 `createKernel`),公开 API 里一句 `CV_OCL_RUN` 即可复用。

**HSV**:8U 转换先建 `hdiv_table180/256`(H 区间 180/256 的定点除法表)与 `sdiv_table`(color_hsv.simd.hpp:64-77),标量核是 `h = (h*hdiv_table[diff] + (1<<(hsv_shift-1))) >> hsv_shift`(253 行),SIMD 版用 `vx_lut` 查同一张表(color_hsv.simd.hpp:164-167)。`_FULL` 后缀只改 hrange(180↔256),由 `isFullRangeHSV(code)` 从 code 位段解出(color.cpp:270)。hal 层 `color_hsv.dispatch.cpp:65/126`(HSV→BGR 为 138/203)完成 CALL_HAL→CV_CPU_DISPATCH 的两级下压。

## 6. 几何变换:逆映射 + remap 通用底座(imgwarp.cpp)

三函数共享"**目标图每像素反解源坐标**"的逆映射模型:

- `cv::warpAffine`(2365 行):未指定 `WARP_INVERSE_MAP` 时先解析求 2x3 逆阵(2399-2409 行),再 `hal::warpAffine`(2411 行)。hal 实现(2250 行)把 M 的两列预饱和成定点偏移表 `adelta/bdelta`(2266-2270 行),`WarpAffineInvoker`(1992 行)以 64x64 块逐行生成 `(xy, alpha)` 短整对——xy=整数坐标、alpha=INTER_TAB_SIZE² 小数索引(2030-2036 行,SIMD 版 `warpAffineBlockline` 2326-2357 行,AVX2/LASX 在 imgwarp.avx2.cpp 等单元)——随后**块内直接调用 `cv::remap`**(2039-2044 行)。
- `cv::warpPerspective`(2827 行):同样先 `invert(matM, matM)`(2859-2860 行),hal 侧逐像素除 w(经 `WarpPerspectiveLine_ProcessNN_CV_SIMD` 等 CV_SIMD128_64F 双精度 SIMD,2418 行起)后汇入同一 remap 管线。
- `cv::remap`(1519 行)是最终底座:四张 `[relative][depth]` 函数表 `nn_tab/linear_tab/cubic_tab/lanczos4_tab`(1527-1591 行)选择 `remapNearest/remapBilinear/...`;双线性用预生成的 2²×INTER_TAB_SIZE² 插值表 `BilinearTab_i`(71-72 行,`initInterTab2D` 152 行),C4 通道有对齐版 `BilinearTab_iC4`(75-76 行、216-219 行);OCL(1596 行)与三种 map 布局的 `CALL_HAL`(1608-1622 行)先行。`RemapInvoker`(1069 行)并行扫行,fixpt=8U 时用 short 系数查表,否则浮点 `Cast<float,T>`(1633 行、1542-1546 行)。采样核极简,每个目标像素就是一次查表四系数加权:

```cpp
// imgwarp.cpp:759-768(摘录,remapBilinear cn==1 分支)
for( ; dx < X1; dx++, D++ )
{
    int sx = XY[dx*2]+(isRelative ? (_offset.x+dx) : 0),
        sy = XY[dx*2+1]+off_y;
    if( borderType == BORDER_CONSTANT &&
        (sx >= ssize.width || sx+1 < 0 ||
         sy >= ssize.height || sy+1 < 0) )
        D[0] = cval[0];      // 四邻全出界才填常量
    else ...
}
```

BORDER_TRANSPARENT 有专门分支:源点在界内但四邻不全在时按"界内权重和"重归一,完全出界则保留 dst 原值(imgwarp.cpp:727-754)。

warpAffine 不自己写双线性,而是折算成 remap 的 map,代价是多一层坐标编码(INTER_BITS=5 位小数),收益是边界处理(BORDER_CONSTANT/REPLICATE/…)、ROI、多插值类型全部只在 remap 一处实现。

## 7. 形态学:锚点与"矩形核才可分离"(morph.dispatch.cpp)

`createMorphologyFilter`(90 行)的关键判断:**仅当核全为非零(矩形结构元)时才拆成 MorphologyRowFilter+MorphologyColumnFilter 两趟,否则退化为 2D `getMorphologyFilter`**(103-109 行)——腐蚀/膨胀是 min/max 归约,数学上本无卷积式可分离性,但对全非零矩形核,"先横向 min 再纵向 min"恰好等价。锚点经 `normalizeAnchor` 规范化(96 行;`morphOp` 内 961 行同样调用),负锚点折进核尺寸。BORDER_CONSTANT 的默认边值按 op 反转:腐蚀填 +MAX、膨胀填 -MAX(`morphologyDefaultBorderValue` 语义,111-128 行)。

`morphOp`(950 行)还做了两处预处理:kernel 为空时等价于 `iterations` 半径的方形核(977-981 行);iterations>1 且为矩形核时**把多次迭代折叠成一次大核**——ksize 变为 `ksize + (iterations-1)*(ksize-1)`、anchor 同步外推(982-990 行),与数学上 erode 复合的等价性一致。OCL 条件极苛刻:仅 BORDER_CONSTANT+默认边值+中心锚点+erode/dilate(966-968 行,`ocl_morphOp` 761 行起按迭代串核)。CPU 终点 `hal::morph`(492 行)→ `ocvMorph`(449 行)→ FilterEngine。SIMD 侧 `MorphRowFilter/MorphColumnFilter`(morph.simd.hpp:488/544)是 `Op(Min/Max)+VecOp` 的模板配对,通道维度做双元素流水(morph.simd.hpp:516-527)。erode/dilate/morphologyEx 入口在 1019/1031/1172 行;morphologyEx 的 OPEN/CLOSE/GRADIENT/TOPHAT/BLACKHAT 全部由 erode/dilate 组合实现(1050-1092 行)。

## 8. 直方图:calcHist 的稠密/稀疏双表示(histogram.cpp)

dense 版 `cv::calcHist`(949 行):OpenVX(957 行)、IPP(976 行)、单图单通道时 `CALL_HAL`(982 行)三级外迁后,内部以 **CV_32S 累加、最后 convertTo(CV_32F)**(986-1015 行)避免浮点累加误差;按深度分派 `calcHist_8u`(524 行)或模板 `calcHist_<ushort/float>`(1006-1013 行)。8U 的一维情形还针对步长为 1 的连续图做了 4 路展开直方计数:

```cpp
// histogram.cpp:551-557(摘录,calcHist_8u dims==1 连续无掩码)
for( x = 0; x <= imsize.width - 4; x += 4 )
{
    int t0 = p0[x], t1 = p0[x+1];
    matH[t0]++; matH[t1]++;
    t0 = p0[x+2]; t1 = p0[x+3];
    matH[t0]++; matH[t1]++;
}
```

其中 `calcHistLookupTables_8u`(536 行调用,60 行定义)把"多维索引 → 线性偏移"折算成 size_t 表,多维情形一次查表即得桶地址,等价于手写的行主序展开。

多维(>1 维)时输出 SparseMat,稀疏版入口在 1266 行,核心 `calcSparseHist_`(1022 行):

```cpp
// histogram.cpp:1043-1054(摘录,uniform 分支)
i = 0;
if( !mask || mask[x] )
    for( ; i < dims; i++ ) {
        idx[i] = cvFloor(*ptrs[i]*uniranges[i*2] + uniranges[i*2+1]);
        if( (unsigned)idx[i] >= (unsigned)size[i] )   // 越界即整点丢弃
            break;
        ptrs[i] += deltas[i*2];
    }
if( i == dims )
    ++*(int*)hist.ptr(idx, true);   // SparseMat:按需创建桶并累加
```

注意 `hist.ptr(idx, true)` 的 `create=true` 语义:高维直方图绝大多数桶为空,HashTrip 运行时才分配;非 uniform 区间用线性扫描 `while( v >= R[j+1] && ++j < sz )`(1083 行)。8U 稠密专用版 `calcHist_8u`(524 行)靠预生成查找表免除逐像素浮点乘法。

## 9. 阈值一句话

`cv::threshold`(thresh.cpp:1610)支持 Otsu/Triangle 自动阈值(THRESH_OTSU/TRIANGLE 标志位,1630-1645 行;Otsu 直方图法 `getThreshVal_Otsu_8u` 1279 行,Triangle 1324 行)后按 8 种模式逐条带循环;`cv::adaptiveThreshold`(1902 行)则是"boxFilter(或高斯)求局部均值 → src-mean-C 的阈值表达式"的短路实现,mean 直接复用 boxFilter(1930 行)/GaussianBlur(1937 行),自身只有一遍比较循环。

## 10. T-API(ocl)/HAL/CPU_DISPATCH 的覆盖矩阵

| 函数 | CV_OCL_RUN(入口) | CALL_HAL(hal:: 内) | CV_CPU_DISPATCH / SIMD |
|---|---|---|---|
| filter2D / sepFilter2D | filter.dispatch.cpp:1530 / 1565 | hal::filter2D/sepFilter2D 1425/1488 → cv_hal_* (hal_replacement.hpp:180-182 附近) | FilterEngine__proceed 系列(filter.simd.hpp:198) |
| GaussianBlur | smooth.dispatch.cpp:652、674 | 696(gaussianBlurBinomial)、708(APPROX) | GaussianBlurFixedPoint 718(实现在 smooth.simd.hpp:59) |
| boxFilter | box_filter.dispatch.cpp:373-378 | 399 | blockSum 409;RowSum/ColumnSum(box_filter.simd.hpp:68/179) |
| resize | resize.cpp:4226 | hal::resize 3826 内 3840 | 显式 opt_SSE4_1 引用(resize.cpp:1513-1518) |
| warpAffine/Perspective | imgwarp.cpp:2375/2834 | 2255(cv_hal_warpAffine)、2281/2311(blockline) | CV_SIMD128 内联 + avx2/lasx 单元(imgwarp.cpp:2320-2324) |
| remap | imgwarp.cpp:1596 | 1610-1621(3 种 map 布局) | RemapVec_8u(表内 1542 行) |
| erode/dilate | morph.dispatch.cpp:966 | hal::morph 492 内 503 | getMorphologyRowFilter 63(MorphRowVec,morph.simd.hpp:111) |
| cvtColor | color.cpp:204 | 各 hal::cvt* 内(如 color_hsv.dispatch.cpp:65) | color_*.simd.hpp(如 126 行) |
| calcHist | histogram.cpp:1288(InputArrayOfArrays 版);dense 版走 OVX/IPP 957/976 | 982 | calcHist_8u 表驱动(标量为主) |
| threshold | thresh.cpp:1614 | 1489、1635(thresholdOtsu) | 标量 stripe 循环 |

规律:**OCL 在公开 API 层短路;HAL 在 hal:: 包装层替换整个实现;CV_CPU_DISPATCH 只出现在 .simd.hpp 对应的"内核函数"粒度**,三者互不嵌套、失败皆可回落默认实现,保证功能等价。

两个宏的机制值得一篇小节:`CALL_HAL(fun,hal_fun,...)` 展开为"声明与 `hal_fun` 同名的弱符号函数指针并调用,返回 `CV_HAL_ERROR_OK` 即短路"(宏表在 `hal_replacement.hpp`,如 180-182 行 sepFilter、236-238 行 morph、342-345 行 resize/warpAffine、972 行 cvtBGRtoHSV),外部 HAL 库(含 IPP、Carotene)用 `#define hal_ni_xxx` 重定向;`CALL_HAL_RET` 是带回返回值的变体(thresh.cpp:1635)。`CV_CPU_DISPATCH(fn,args,MODES)` 则利用 `.simd_declarations.hpp` 生成的一组 per-ISA 内联转发——同一份 `.simd.hpp` 在 `#define CV_CPU_DISPATCH_MODE AVX2` 等 repeat-include 下被编译多次,运行时由 CMake 生成、cpuid 探测的初始化表选中实现(`filter.dispatch.cpp:57` 的 include 即入口)。因此 imgproc 的 SIMD 不靠运行期函数指针表手工维护,而是"同名单符号 + 编译期多次实例化"。

## 11. 设计动机

1. **为什么分离核(两趟)**:k×k 卷积分解为 1D×1D,复杂度 O(k²)→O(2k);boxFilter 更进一步用滑动和做到与核尺寸无关(box_filter.simd.hpp:107-110)。代价是中间缓冲,FilterEngine 用 ksize.height+3 行的环形缓存把内存压到 O(k)(filterengine.hpp:107-109、filter.simd.hpp:107-109)。
2. **为什么 BORDER 抽象**:边界是所有局部算子的公共分母。把"越界取哪"折叠成 borderInterpolate 的纯函数(copy.cpp:882)+索引表,使 rowFilter/columnFilter 完全无边界感知(filterengine.hpp:75/131 的注释明言"边界插值在类外完成");新增一种边界模式只需改一处,所有滤波器/重映射同时受益。
3. **为什么 remap 是通用底座**:任何几何变换最终都归结为"目标像素 ← 源坐标 + 插值权"。warpAffine/warpPerspective 只负责生成 (map,mapA),采样、边界、插值统一复用 remap(imgwarp.cpp:2039-2044);这消除了 N 种变换 × M 种插值 × K 种边界的组合爆炸,也让 cv::remap 本身(镜头校正、立体校正)获得同一套优化。
4. **为什么 cvtColor 表驱动(CvtHelper+Set)**:cvColor 有 ~200 个 code 枚举,但真正实现只有几十个方向函数。`CvtHelper<Set<3,4>,Set<1>,Set<...>>` 把"输入通道集/输出通道集/深度集/尺寸约束"压缩成一行类型声明(color_rgb.dispatch.cpp:577),参数检查、inplace 处理(color.simd_helpers.hpp:96-98)、dst 分配全部去重;新增一个转换只需写核循环与一行包装。
5. **为什么 fixed-point 优先**:8U 图像用 16 位定点小数核(GaussianBlur 的 ufixedpoint16、resize 的 ialpha、warp 的 alpha)可跨 CPU/ISA/平台得到**逐位相同**的结果(filter.dispatch.cpp:288-303 的 bit-exact 验证、resize 的 INTER_LINEAR_EXACT),这是单元测试和嵌入式确定性部署的前提;同时 Q7/Q15 定点恰好映射到 SIMD 饱和乘加指令,比浮点路径更快。浮点仅作为 32F/64F 深度的兜底。
6. **为什么容忍三套并行的加速路径**:OCL/HAL/SIMD 覆盖不同的部署形态(带 GPU、带厂商库、纯 CPU),且每层都"失败即回落",任何一层缺席都不损失正确性——这解释了为何同一函数里 CV_OCL_RUN、CALL_HAL、CV_CPU_DISPATCH 常常三连出现。
7. **为什么形态学不硬做可分离**:min/max 没有卷积的可分离代数性质,盲目两趟会算错任意结构元;代码用"矩形全非零才两趟"的守卫(morph.dispatch.cpp:103-109)在数学安全的前提下吃到性能,这是一处典型的"先证等价、再做优化"的工程示范。

## 12. 写作素材清单(文件:行号,均经核对)

1. `modules/imgproc/src/filterengine.hpp:214` — FilterEngine 类定义;249 行 isSeparable;268 行 ringBuf。
2. `modules/imgproc/src/filter.dispatch.cpp:305-383` — createSeparableLinearFilter:核类型探测→定点化→组装引擎。
3. `modules/imgproc/src/filter.simd.hpp:198-297` — FilterEngine__proceed:环形行缓存+查表补边+两趟执行全文。
4. `modules/core/src/copy.cpp:882-927` — borderInterpolate 全部边界模式实现。
5. `modules/imgproc/src/smooth.dispatch.cpp:87-153` — 高斯核:sigma≤0 二项式表 / σ=0.15n+0.35。
6. `modules/imgproc/src/smooth.dispatch.cpp:609-723` — GaussianBlur 三层分派(OCL→定点 HAL→CPU_DISPATCH)。
7. `modules/imgproc/src/box_filter.simd.hpp:1639-1661` — createBoxFilter 的 sumType 精度选择。
8. `modules/imgproc/src/box_filter.simd.hpp:103-111` — RowSum 滑动窗增量求和。
9. `modules/imgproc/src/resize.cpp:3826-4194` — cv::hal::resize:六张函数表+AREA 双分支+定点系数。
10. `modules/imgproc/src/resize.cpp:4201-4246` — cv::resize 薄入口(OCL 4226、hal 调用 4245)。
11. `modules/imgproc/src/color.cpp:192-231` — cvtColor 大 switch;`color.simd_helpers.hpp:83` — CvtHelper 模板。
12. `modules/imgproc/src/color_rgb.simd.hpp:583-597` — RGB2Gray 系数与循环;`color_hsv.simd.hpp:64-77,253` — HSV 定点除法表。
13. `modules/imgproc/src/imgwarp.cpp:2250-2277` — hal::warpAffine 定点偏移表;`2365-2413` — cv::warpAffine 逆阵解析。
14. `modules/imgproc/src/imgwarp.cpp:1519-1658` — cv::remap 四张函数表+initInterTab2D;`1992-2048` — WarpAffineInvoker 块化生成 map 后调 remap。
15. `modules/imgproc/src/morph.dispatch.cpp:90-133` — createMorphologyFilter:矩形核才分离+边界值反转;`975-990` — iterations 折叠。
16. `modules/imgproc/src/histogram.cpp:1022-1107` — calcSparseHist_:SparseMat 按需建桶;`949-1016` — dense 版 32S 累加。

(补:`thresh.cpp:1610/1902` — threshold/adaptiveThreshold;`filter.dispatch.cpp:1521/1555` — filter2D/sepFilter2D 公开入口。)

## 13. 建议阅读路线

1. 先读 `filterengine.hpp:62-280`:三个 Base 类 + FilterEngine 的成员与文档注释,建立"行/列/2D 三算子 + 引擎"的心智模型;
2. 再读 `filter.simd.hpp:91-313`:start(表准备)→ proceed(双循环)→ apply(组合),这是所有线性/非线性滤波的共用底盘;
3. 用 `smooth.dispatch.cpp:609` 的 GaussianBlur 走一遍完整分派,体会 OCL/定点/HAL/浮点四条路的取舍;
4. 跳到 `resize.cpp:3826-4194` 对照六张表,理解"坐标表+系数表先行、内层循环零分支"的写法;
5. `color.cpp:192` + `color.simd_helpers.hpp:83` 看模板如何消灭样板;
6. 最后以 `imgwarp.cpp:1519`(remap)收尾:它是 FilterEngine 之外另一条"底座"路线,两相对照可讲清 imgproc 的两个抽象层次——空间不变的滤波与空间可变的采样。
