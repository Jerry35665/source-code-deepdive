# 报告 F2 · photo 计算摄影与 stitching 拼接(OpenCV 卷二)

> 基线:d3d247f1(4.13.0-dev)……一句话总结:photo 模块以"FMM 优先队列(Telea/NS 修补)、DST 直接解(Poisson 融合)、SVD/交替迭代(HDR)、滑窗增量(NL-means)、原始-对偶(TVL1)"五种求解器覆盖计算摄影,而 stitching 以"多尺度特征→光束法平差→图割接缝→分块增益→五层拉普拉斯"的工厂化流水线把 6 个算法阶段编排成一条 composePanorama 主链。

本章证据全部来自 `modules/photo/src/` 与 `modules/stitching/src/`,行号以 d3d247f1 工作树为准。

---

## 一、纠偏清单(先证伪,以本 commit 源码为准)

1. **不存在 `hdr/` 子目录,也没有 merge_debevec.cpp/merge_robertson.cpp。** HDR 三件套是扁平单文件:`merge.cpp`(377 行,含 MergeDebevecImpl/MergeMertensImpl/MergeRobertsonImpl 三个类)、`calibrate.cpp`、`tonemap.cpp`(`modules/photo/src/` 目录清单已核实)。
2. **`TonemapDurand` 不在本仓库。** 全仓 grep "Durand" 仅命中 `modules/core/src/mathfuncs.cpp:1701` 的 Durand-Kerner 多项式求根注释;photo 的 tonemap.cpp 只实现 Tonemap(线性+gamma)、Drago、Reinhard、Mantiuk 四个(tonemap.cpp:56/113/199/299)。Durand2002 在 opencv_contrib/xphoto(未核实具体版本,因 contrib 不在本仓)。
3. **不存在 `seamless_cloning_mod.cpp`**,实际文件是 `seamless_cloning.cpp`(API 层)+ `seamless_cloning_impl.cpp`(Cloning 类);且 Poisson 方程不是稀疏矩阵迭代解,而是**离散正弦变换(DST)直接解**(seamless_cloning_impl.cpp:98-203)。
4. **fastNlMeans CPU 实现不用积分图。** 它是"上一行/上一列距离和增量更新"的滑窗传播(up_col_dist_sums + calcUpDownDist,fast_nlmeans_denoising_invoker.hpp:213-226),"积分图加速"是流传甚广的错误说法。
5. **Stitcher PANORAMA 默认不是 GainCompensator 也不是 SURF:** 默认特征 `ORB::create()`、曝光补偿 `BlocksGainCompensator`(32×32 块)、接缝 `GraphCutSeamFinder(COST_COLOR)`(stitcher.cpp:61-63/81;exposure_compensate.hpp:211)。GainCompensator 是 Blocks 内部每块调用的求解器(exposure_compensate.cpp:605-608)。
6. **photo 修补只认两个 flag:** `INPAINT_NS=0`、`INPAINT_TELEA=1`(photo.hpp:95-96),其余直接 CV_Error(inpaint.cpp:786-787);seamlessClone 另有隐藏的 `*_WIDE` 枚举(NORMAL_CLONE_WIDE=9/MIXED_CLONE_WIDE=10/MONOCHROME_TRANSFER_WIDE=11,photo.hpp:743-759),改变 ROI 定位逻辑(seamless_cloning.cpp:88-92)。

## 二、inpaint:一个 FMM 骨架跑两种算法

`icvInpaint` 把图像加 2 像素边框,mask 非零处标 INSIDE,用 3×3 十字膨胀减原 mask 得到 BAND(窄带),BAND 入堆,T 初值 1e6(inpaint.cpp:718-742)。三值状态 KNOWN=0/BAND=1/INSIDE=2(另留 CHANGE=3 服务值)定义在 inpaint.cpp:77-80。优先队列 `std::priority_queue` 以 T 升序出堆,T 相同时按**插入顺序**稳定出堆(inpaint.cpp:88-95)——这保证同波前像素确定性处理。Eikonal 方程的 Godunov 格式解:

```cpp
// inpaint.cpp:168-186(FastMarching_solve,节选)
if( f.at<uchar>(i1,j1) != INSIDE )
    if( f.at<uchar>(i2,j2) != INSIDE )
        if( fabs(a11-a22) >= 1.0 )  sol = 1+m12;
        else  sol = (a11+a22+sqrt((double)(2-(a11-a22)*(a11-a22))))*0.5;
    else  sol = 1+a11;
...
return (float)sol;
```

每次弹出带内点,对 4 邻域取 `min4(四个对角方向的 solve)` 更新 T 并重新入堆(inpaint.cpp:213-219)。初始化阶段的三步建带:

```cpp
// inpaint.cpp:727-742(icvInpaint,节选)
input_img.copyTo( output_img );
mask.setTo(Scalar(KNOWN,0,0,0));
COPY_MASK_BORDER1_C1(inpaint_mask,mask,uchar);       // mask 非零 → INSIDE
SET_BORDER1_C1(mask,uchar,0);
f.setTo(Scalar(KNOWN,0,0,0));
t.setTo(Scalar(1.0e6f,0,0,0));                       // T 初值 1e6
cv::dilate(mask, band, el_cross, cv::Point(1, 1));   // 3×3 十字膨胀
Heap=cv::makePtr<CvPriorityQueueFloat>();
subtract(band, mask, band);                          // 窄带 = 膨胀 − mask
...
f.setTo(Scalar(BAND,0,0,0),band);
f.setTo(Scalar(INSIDE,0,0,0),mask);
```

**Telea 与 NS 共享这副骨架,差别只在权重**。Telea 权重 = 距离项 × 层级项 × 方向项:

```cpp
// inpaint.cpp:310-315(Telea 权重)
dst = 1.f/(VectorLength(r)*sqrt(VectorLength(r)));   // 1/|r|^3
lev = 1.f/(1+fabs(t.at<float>(k,l)-t.at<float>(i,j)));
dir = VectorScalMult(r, gradT[color]);               // r·∇T
if (fabs(dir)<=0.01) dir=0.000001f;
w = fabs(dst*lev*dir);
```

估计值 = 加权均值 + 等照度线方向的一阶修正:`sat = Ia/s + (Jx+Jy)/(‖(Jx,Jy)‖+ε)`(inpaint.cpp:353)。NS 则用 `dst=1/(|r|²+1)`(inpaint.cpp:519),方向项取 r 与 **∇I 的等照度线**夹角余弦(inpaint.cpp:550-557),输出纯加权平均 `Ia/s`(inpaint.cpp:567)——这正是把经典 NS 偏微分方程离散成"沿等照度线传播"的邻域加权版。细节:Telea 里 ∇T 中心差分系数是 0.5(inpaint.cpp:266),而 ∇I 的中心差分写成 `*2.0f`(inpaint.cpp:319/332)——量纲上等效于把梯度放大 4 倍,是历史遗留写法(是否 bug 本报告不定性)。Telea 专属前置:先从窄带向外(FAST 行进 + `negate` 取负回填)对 `range` 邻域外环算一张 T 距离场供权重用(inpaint.cpp:744-755);`range` 被夹到 [1,100](inpaint.cpp:715-716)。

## 三、seamlessClone:DST 直接解的 Poisson 融合

API 层 `cv::seamlessClone` 把 mask 内缩 1 像素再用零边框补回(seamless_cloning.cpp:79-80,防止贴边),取 boundingRect,把源块与目标 ROI 交给 `Cloning::normalClone`(seamless_cloning.cpp:103)。实现层先对 destination 与 patch 各算前向梯度(computeGradientX/Y,1D 差分核 filter2D,seamless_cloning_impl.cpp:48-80),mask 用 3×3 全 1 核腐蚀 3 次(seamless_cloning_impl.cpp:261)。`poisson()` 把"patch 梯度 + destination 梯度"求二阶差分得到散度右端项(seamless_cloning_impl.cpp:292-296),再进 `poissonSolver`:边界条件由"内部清零后取 Laplacian"提取(seamless_cloning_impl.cpp:212-218),然后 `solve()` 用两次 DFT 合成的 DST 解三对角特征系统:

```cpp
// seamless_cloning_impl.cpp:151-162(solve,节选)
dst(mod_diff, res);                      // 正变换(偶延拓+DFT_ROWS)
for(int j = 0 ; j < h-2; j++)
    for(int i = 0 ; i < w-2; i++)
        resLinePtr[i] /= (filter_X[i] + filter_Y[j] - 4);  // 特征值 2cos+2cos-4
dst(res, mod_diff, true);                // 逆变换
```

特征值预生成 `2cos(π(k+1)/(N-1))`(seamless_cloning_impl.cpp:236-246)。三种模式在进入求解前改写 patch 梯度场:NORMAL_CLONE 直接乘 mask(seamless_cloning_impl.cpp:336-337);MIXED_CLONE 逐像素比较 `|gx−gy|` 大小选 patch 或 destination 的梯度(seamless_cloning_impl.cpp:359-371,注意比较的是两通道差而非梯度模);MONOCHROME_TRANSFER 改用灰度图梯度(seamless_cloning_impl.cpp:379-386)。colorChange/illuminationChange/textureFlattening 复用同一求解核,只在梯度场上做缩放/幂调制/Canny 置零(seamless_cloning_impl.cpp:394-456)。

## 四、HDR:calibrate → merge → tonemap 三段式

公共常量 `LDR_SIZE=256`(photo.hpp:331)。权重函数:Debevec 用三角"帽"函数(hdr_common.cpp:62-77),Robertson 用高斯形(hdr_common.cpp:79-93);响应初值是恒等线性表(hdr_common.cpp:107-114)。

**CalibrateDebevec**(calibrate.cpp:51-200):随机或网格采 `samples`(默认 70)个像素点,逐通道构建 (点数×图数+257)×(256+点数) 的加权方程组:

```cpp
// calibrate.cpp:125-148(Debevec 方程组构建,节选)
for(size_t i = 0; i < points.size(); i++) {
    for(size_t j = 0; j < images.size(); j++) {
        int val = images[j].ptr()[channels*(points[i].y*cols + points[i].x) + ch];
        float wij = w.at<float>(val);
        A.at<float>(k, val) = wij;              // 数据项: w·g(Z)
        A.at<float>(k, LDR_SIZE + (int)i) = -wij;  //           − w·lnE
        B.at<float>(k, 0) = wij * log(times.at<float>((int)j));  // = w·ln t
        k++;
    }
}
A.at<float>(k, LDR_SIZE / 2) = 1;               // 中值固定为 0
for(int i = 0; i < (LDR_SIZE - 2); i++) {       // λ 平滑项(二阶差分)
    float wi = w.at<float>(i + 1);
    A.at<float>(k, i) = lambda * wi;
    A.at<float>(k, i + 1) = -2 * lambda * wi;
    A.at<float>(k, i + 2) = lambda * wi;
}
```

最后 `solve(A,B,solution,DECOMP_SVD)` 最小二乘(calibrate.cpp:152),输出 exp 还原的响应曲线(calibrate.cpp:158)。默认 samples=70/λ=10/random=false(photo.hpp:569)。

**MergeDebevec**(merge.cpp:50-140):每张 LDR 图 LUT 查帽权重与 log 响应,`result += w·(g(Z) − ln t)`,`weight_sum += w`,最后 `/weight_sum` 后 `exp()` 还原到 HDR(merge.cpp:98-122)。**MergeRobertson**(merge.cpp:312-375):闭式加权最小二乘 `E = Σ t·w·g(Z) / Σ t²·w(+ε)`(merge.cpp:354-357)。**CalibrateRobertson** 则是交替迭代:merge 求辐射图 → 辐射图反推新响应 → 按中值归一 → 差值 < 0.01 停(calibrate.cpp:244-272),默认 30 轮(photo.hpp:593)。**MergeMertens** 与 HDR 无关:对多曝光 LDR 直接构造对比度(Laplacian)/饱和度(通道标准差)/曝光适度(exp(−(I−0.5)²/0.08))三权重相乘(merge.cpp:191-225),再用 `maxlevel=log2(min(w,h))` 层的拉普拉斯金字塔融合(merge.cpp:232-270),默认 exposure_weight=0(photo.hpp:669)。

**Tonemap 系列**(tonemap.cpp):公共开头是线性 Tonemap(归一化到 [0,1] 再 `pow(dst,1/gamma)`,tonemap.cpp:73-84);log 域统一钳底 1e-4(tonemap.cpp:50-54)。四个 mapper 一览:

| 类 | 核心公式位置 | 关键默认值 |
|---|---|---|
| Tonemap | 归一化 + gamma 幂,tonemap.cpp:77-84 | gamma=1.0(photo.hpp:355) |
| TonemapDrago | tonemap.cpp:150-156 | bias=0.85(photo.hpp:386) |
| TonemapReinhard | tonemap.cpp:234-249 | intensity=0,light=1,color=0(photo.hpp:419) |
| TonemapMantiuk | CG 迭代 tonemap.cpp:342-365 | scale=0.7(photo.hpp:445) |

Drago:对数均值做键值,映射核 `log(1+I)/log(2+8·(I/max)^(ln bias/ln 0.5))`(tonemap.cpp:150-154)。Reinhard:逐通道估计全局/局部自适应亮度,`channel/(adapt_l·V^key + channel)`:

```cpp
// tonemap.cpp:234-248(Reinhard,节选)
float key = (log_max - log_mean) / (log_max - log_min);
float map_key = 0.3f + 0.7f * pow(key, 1.4f);
intensity = exp(-intensity);
...
for(int i = 0; i < 3; i++) {
    float global = color_adapt * chan_mean[i] + (1.0f - color_adapt) * gray_mean;
    Mat adapt = color_adapt * channels[i] + (1.0f - color_adapt) * gray_img;
    adapt = light_adapt * adapt + (1.0f - light_adapt) * global;
    pow(intensity * adapt, map_key, adapt);
    channels[i] = channels[i].mul(1.0f / (adapt + channels[i]));
}
```

Mantiuk 最重:多尺度对比度场经 `signedPow(0.4185)` 调制(tonemap.cpp:413-419),再对 log 亮度解 Poisson 式方程组,用**共轭梯度法**(上限 100 轮、目标误差 1e-3,tonemap.cpp:342-365),其 `calculateProduct` 即 A·x 通过反复取梯度-求和实现(tonemap.cpp:463-468)。色彩保持统一走 `mapLuminance`:通道比 × 饱和度幂 × 新亮度(hdr_common.cpp:95-105)。

## 五、denoise:NL-means 滑窗 + TVL1 原始-对偶

**fastNlMeans**(denoising.cpp + fast_nlmeans_denoising_invoker.hpp):公开函数只做分发——支持 L1/L2 范数、每通道独立 h、多线程 `parallel_for_` 按行切(denoising.cpp:104-166),彩色版先转 Lab 再对 L 与 ab 分别去噪(denoising.cpp:191-207)。UMat/UMat 输入走 OpenCL 分支,但小图(≤5×5)强制回退 CPU 并注明"低分辨率下精度差"(denoising.cpp:123-126);行级并行粒度按 `dst.total()/(1<<17)` 自适应(denoising.cpp:53)。Invoker 核心在滑窗复用:

```cpp
// fast_nlmeans_denoising_invoker.hpp:213-222(列和增量更新,节选)
for (int x = 0; x < search_window_size; x++)
{
    dist_sums_row[x] -= col_dist_sums_row[x];            // 减掉滑出模板窗的一列
    col_dist_sums_row[x] = up_col_dist_sums_row[x]
        + D::template calcUpDownDist<T>(a_up, a_down, b_up_ptr[bx], b_down_ptr[bx]);
    dist_sums_row[x] += col_dist_sums_row[x];            // 加上新的一列
    up_col_dist_sums_row[x] = col_dist_sums_row[x];
}
```

即搜索窗整体滑动一格只需 O(搜索窗²) 次两行像素差,而非 O(模板窗×搜索窗²) 全量重算;`calcUpDownDist` 只算新进入/离开的那一行(commons.hpp:174-176)。权重全部**预计算成查找表**:`almost_dist2weight_[dist>>shift]`,定点数乘 + 移位除法(fast_nlmeans_denoising_invoker.hpp:126-143,242-243);权重公式 `exp(−d²/(h²·C))`(DistAbs,commons.hpp:136-139),模板窗尺寸断言 ≤46340=√INT_MAX(invoker:127)。默认参数 h=3、template 7、search 21(photo.hpp:147-148)。

**denoise_TVL1**(denoise_tvl1.cpp):Chambolle 投影/原始-对偶算法(文献引用 @cite ChambolleEtAl,photo.hpp:298),常数 `L2=8, tau=0.02, sigma=1/(L2·tau), theta=1`(denoise_tvl1.cpp:63),默认 lambda=1.0、niters=30(photo.hpp:324)。迭代三步:对偶上升 P += σ∇X 后球面投影 `P/max(‖P‖,1)`(denoise_tvl1.cpp:94-98);多观测残差 R 裁剪到 ±λ(denoise_tvl1.cpp:107-114);原始更新与外推:

```cpp
// denoise_tvl1.cpp:140-143(原始步 + 过冲外推,节选)
// X1 = X + tau*(-nablaT(P))
x_new = x_curr[x] + tau*(p_curr[x].x - p_curr[x-1].x + p_curr[x].y - p_prev[x].y) - tau*s;
    // X = X2 + theta*(X2 - X)
x_curr[x] = x_new + theta*(x_new - x_curr[x]);
```

首轮 σ 放大为 1+σ(denoise_tvl1.cpp:82)。图像按 1/255 归一、结果 ×255 转 8U(denoise_tvl1.cpp:74,148-149);接口接受多帧 observations,R 逐帧裁剪实现联合去噪(denoise_tvl1.cpp:108-115)。

## 六、Stitcher 全管线(ASCII)

两个入口拆分是刻意的:`estimateTransform`(:102-118)把贵的注册阶段缓存下来,`composePanorama`(:121-376)可对同一批相机参数反复合成;`stitch` 只是二者串调(:385-393)。

```text
Stitcher::stitch(images)                          stitcher.cpp:385-393
  ├── estimateTransform = matchImages + estimateCameraParams   :102-118
  ▼
[1 注册:matchImages  stitcher.cpp:396-495]
  work_scale = min(1, sqrt(0.6e6/area))     :434   ← registrationResol 0.6 :57
  computeImageFeatures: detect+compute 分离,可并行    :457 (matchers.cpp:282-306)
  默认特征 ORB::create()                    :63
  BestOf2NearestMatcher + findHomography(RANSAC)  :469 (matchers.cpp:397/427)
  leaveBiggestComponent(conf_thresh=1)      :474   ← 置信度筛选连通域
  ▼
[2 相机:estimateCameraParams  stitcher.cpp:498-541]
  HomographyBasedEstimator                  :501
    ├ estimateFocal ← focalsFromHomography  (motion_estimators.cpp:165, autocalib.cpp:63-100)
    ├ findMaxSpanningTree 广度优先旋转向外传播 (motion_estimators.cpp:171-173,1146)
  BundleAdjusterRay: CvLevMarq,3×2 误差/匹配对,焦距+Rodrigues 旋转  :513 (557-629)
    归一化:所有 R 左乘中心图 R⁻¹             (motion_estimators.cpp:318-324)
  中位数焦距 → warped_image_scale_           :516-528
  waveCorrect(WAVE_CORRECT_HORIZ)           :530-538 (motion_estimators.cpp:932-1012)
    moment=Σr₁r₁ᵀ 取最小特征向量定"水平",再 rg0=rg1×Σr₃ 定向,conf<0 翻转
  ▼
[3 合成:composePanorama  stitcher.cpp:129-376]
  seam_scale = min(1, sqrt(0.1e6/area))     :441   ← seamEstimationResol 0.1 :58
  SphericalWarper 按 K,R 投影 seam 图       :184-198 (warpers.cpp:496-499)
  ① 曝光补偿(先于接缝!)feed + apply        :203-206 (exposure_compensate.cpp:83-112)
  ② GraphCutSeamFinder(COST_COLOR).find     :212    GCGraph: 端点权=mask 项, n 链权=Σ‖ΔRGB‖+ε,
    越界 +bad_region_penalty_ → graph.maxFlow()       (seam_finders.cpp:1150-1184, 1343)
  ③ 逐张全分辨率(compose_resol 默认 −1=原图) :249-250
     warp → apply 增益 → seam mask 膨胀+resize 对齐   :306-337
  ④ MultiBandBlender(默认 5 层, CV_16S 累加) :62, 328, 346, 357
  ⑤ blend: 逐层 normalize + restoreImageFromLaplacePyr → CV_16S→CV_8U  :366, 373 (blenders.cpp:668-678, 865-875)
```

三个尺度各自职责:work_scale 配特征、seam_scale 配接缝与补偿、compose_scale 配最终融合;三套 K(corners/focal/pp)按 `compose_work_aspect` 同步缩放(stitcher.cpp:262-282)。失败路径:图 <2 张或筛选后 <2 张返回 `ERR_NEED_MORE_IMGS`(stitcher.cpp:398-402,488-492);BA 失败返回 `ERR_CAMERA_PARAMS_ADJUST_FAIL`(stitcher.cpp:513-514)。SCANS 模式整组换件:AffineBestOf2NearestMatcher + BundleAdjusterAffinePartial + AffineWarper + 无曝光补偿 + 关波浪校正(stitcher.cpp:84-91)。

### 6.1 曝光补偿:块状增益的两层结构

`GainCompensator::singleFeed` 统计重叠区:像素数矩阵 N(`N(i,j)=max(1,交集像素数)`)与平均强度积矩阵 I(exposure_compensate.cpp:165-180),再解带正则的线性方程组 A·g = b,其中 `alpha=0.01、beta=100`(exposure_compensate.cpp:214-230),`solve(A,b,l_gains)`(exposure_compensate.cpp:267,有 HAVE_EIGEN 时用 Eigen LLT)。新版还支持 `nr_feeds_` 多轮迭代与相似度 mask 过滤(exposure_compensate.cpp:93-104)。`BlocksGainCompensator` 把全景切成 32×32 块、每块跑一遍 GainCompensator,再对增益图做平滑(exposure_compensate.hpp:172-213;exposure_compensate.cpp:605-608)。

### 6.2 波浪校正与光束法的两处细节

waveCorrect 用全部旋转矩阵的第一列构造 3×3 moment 矩阵,取**最小**特征向量(HORIZ 取 eigen_vecs.row(2))当作"水平方向"rg1,再叉乘第三列之和得 rg0,保证右手系;conf<0 时整体翻转(motion_estimators.cpp:932-1012)。BundleAdjuster 的边集只保留 `confidence > conf_thresh_` 的匹配对(motion_estimators.cpp:246),解算用 legacy `CvLevMarq`(motion_estimators.cpp:257),每步数值差分雅可比;收敛后把所有相机旋转归一到最大生成树中心图(motion_estimators.cpp:318-324)——这就是"第 0 张图不旋转"约定的来源。

### 6.3 接缝与融合的内存设计

GraphCut 建图:端点权 `mask? terminal_cost_ : 0`(seam_finders.cpp:1175),n 链权 = 两对相邻像素的 ‖ΔRGB‖ 之和 + ε,越出重叠区再加 bad_region_penalty_(seam_finders.cpp:1181-1184);实际切割在 ROI 外扩 gap=10 的邻域内进行(seam_finders.cpp:1266,1274),`graph.maxFlow()` 一锤定音(seam_finders.cpp:1343)。另有 DpSeamFinder(动态规划,代价函数可换 COLOR/COLOR_GRAD,seam_finders.cpp:191)与 VoronoiSeamFinder 备选。MultiBandBlender 的 `prepare` 把层数收敛为 `min(5, ceil(log2(max_len)))`,并把目标 ROI pad 成 2^层数 的倍数(blenders.cpp:233-245);`feed` 只保留每图周边 `gap=3·(1<<num_bands_)` 的条带并对齐 2 的幂(blenders.cpp:366-384),权重累加走 CV_16S 定点(`(src*w)>>8`,blenders.cpp:578-583),最终逐层 `pyrUp+add` 重建(blenders.cpp:865-875)。

### 6.4 特征与匹配:复用 features2d 而非另造轮子

`computeImageFeatures` 直接调 `featuresFinder->detect()` + `compute()`(matchers.cpp:291-293),因此任何 Feature2D(ORB/SIFT/AKAZE)可插拔;`BestOf2NearestMatcher::match` 做双向最近邻交叉验证后 `findHomography(..., RANSAC)` 求 H(matchers.cpp:397-427),仿射版换 `estimateAffine2D/estimateAffinePartial2D`(matchers.cpp:537-539)。SphericalWarper 走 `RotationWarperBase<SphericalProjector>::buildMaps` 通用映射表机制(warpers.cpp:496-499;warpers.hpp:99)。

---

## 设计动机列表(源码证据向)

1. **FMM 统一调度:** Telea/NS 共用一套窄带堆,把"从边界向内"的传播顺序与像素值估计解耦,只换权重函数(inpaint.cpp:236-479)。
2. **DST 而非迭代解 Poisson:** 边界固定的矩形域上 Laplacian 特征值已知(2cos+2cos−4),O(N log N) 精确解,免掉矩阵组装(seamless_cloning_impl.cpp:151-162)。
3. **HDR 全链查表:** 响应曲线/权重都是 256 项 LUT,merge 端零三角函数,只用 LUT+逐元素乘(merge.cpp:104-114)。
4. **NL-means 的"计算一次,复用一路":** 相邻像素搜索窗 99% 重叠,只增量算一列/一行差,权重查表化把 exp 全部移出主循环(invoker:126-143,213-226)。
5. **stitching 三分辨率解耦:** 注册/接缝/合成各用各的尺度,像素量分别被 0.6/0.1/1.0 兆像素约束,stitcher.cpp:57-59。
6. **先曝光补偿后找缝:** 增益在找缝前 apply,接缝决策看到的是亮度一致后的图,stitcher.cpp:203-212。
7. **接缝只算一次,合成时复用:** seam 层得到的 mask 经"膨胀 + resize + bitwise_and"迁移到合成分辨率,stitcher.cpp:334-337。
8. **定点数端到端:** NL-means 权重定点查表、多带融合 CV_16S 权重累加,牺牲极小精度换内存与带宽(invoker:242-243;blenders.cpp:366 起)。

## FAQ 候选(正文用)

1. inpaintRange 传多大?——会被强制夹到 [1,100] 像素(inpaint.cpp:715-716)。
2. Telea 和 NS 底层一样吗?——同一个 FMM 堆,只差权重与梯度项(inpaint.cpp:236/477)。
3. seamlessClone 为什么快?——Poisson 方程用 DST 特征值除法直接解,无迭代(seamless_cloning_impl.cpp:158)。
4. MIXED_CLONE 怎么混?——逐像素比较 |gx−gy|,强的一侧胜出(seamless_cloning_impl.cpp:359)。
5. TonemapDurand 去哪了?——本仓库 photo 没有,已迁至 contrib xphoto(grep 证据:mathfuncs.cpp:1701 之外无命中)。
6. MergeMertens 要曝光时间吗?——不要,InputArray times 参数被忽略(merge.cpp:153-158)。
7. CalibrateDebevec 怎么解响应?——逐通道加权最小二乘 + DECOMP_SVD(calibrate.cpp:152)。
8. fastNlMeans 靠什么快?——列和增量复用 + 权重查找表 + 定点移位,不是积分图(invoker:213-226)。
9. 什么时候报 ERR_NEED_MORE_IMGS?——输入 <2 张,或置信度筛选后剩 <2 张(stitcher.cpp:398,488)。
10. 多带融合默认几层?——5 层,且被 ceil(log2(最长边)) 收窄(blenders.hpp:130;blenders.cpp:239)。
11. 曝光补偿在接缝前还是后?——前:先 apply 增益再 find 接缝(stitcher.cpp:203-212)。
12. PANORAMA 与 SCANS 差在哪?——单应+球面 vs 仿射+平面,曝光补偿与波浪校正一并关闭(stitcher.cpp:73-91)。

## 深挖方向

1. **Telea ∇I 系数 ×2.0 之谜:** inpaint.cpp:319 与 gradT 的 0.5 对比,写脚本复现其对结果的实际影响。
2. **DST 解的适用边界:** mask 顶到图像边框时边界条件退化行为(seamless_cloning_impl.cpp:212-222)。
3. **Mantiuk 的 CG 收敛:** 100 轮上限与 1e-3 目标在实际 HDR 图上的停机分布(tonemap.cpp:342-365)。
4. **BundleAdjusterRay 的解析雅可比:** calcJacobian 用 1e-4 数值差分(motion_estimators.cpp:631-653),可对比解析式精度。
5. **BlocksGainCompensator 分块粒度:** 32×32 块 + 每块独立最小二乘的增益平滑核(exposure_compensate.hpp:172)对大图拼接的影响。
6. **GraphCut vs DP 接缝质量对比:** DpSeamFinder 的 COLOR/COLOR_GRAD 代价函数与图割的结果差异(seam_finders.cpp:191,746)。

## 正文蒸馏要点

1. OpenCV 修补的 Telea/NS 共享同一套 FMM 优先队列骨架,flag 只有 INPAINT_NS=0/INPAINT_TELEA=1 两个合法值(inpaint.cpp:744-787;photo.hpp:95-96)。
2. Telea 权重 = |r|⁻³ × 1/(1+|ΔT|) × |r·∇T|,估计值再加等照度线方向修正项(inpaint.cpp:310-315,353)。
3. NS 的方向项是搜索向量与等照度线 ∇I 的夹角余弦,输出是纯加权平均而非 Telea 的"均值+梯度修正"(inpaint.cpp:519,550-567)。
4. seamlessClone 的 Poisson 方程用 DST(两次 DFT 合成)按特征值 2cos(π(i+1)/(N−1)) 逐项相除直接求解,不是稀疏迭代(seamless_cloning_impl.cpp:151-162,236-246)。
5. MIXED_CLONE 的"逐像素选强梯度"实际比较的是 |gx−gy| 而非梯度模长,这是一个可观测的实现细节(seamless_cloning_impl.cpp:359-360)。
6. CalibrateDebevec 每通道建 (采样点×图数+LDR_SIZE+1) 行方程组:数据项+中值固定+λ 平滑项,DECOMP_SVD 最小二乘(calibrate.cpp:119-152)。
7. MergeRobertson 是闭式解 `Σ t·w·g(Z)/Σ t²·w`,而 CalibrateRobertson 才是 30 轮交替迭代、阈值 0.01 早停(merge.cpp:354-357;calibrate.cpp:245-271)。
8. tonemap 系列只有线性/Drago/Reinhard/Mantiuk;Mantiuk 是唯一的迭代求解器(CG ≤100 轮,误差 1e-3),TonemapDurand 不在本仓(tonemap.cpp:342-365)。
9. fastNlMeans 的加速本质是"滑窗距离和增量更新 + 预计算权重表 + 定点移位",文献常见的"积分图"说法与 CPU 实现不符(fast_nlmeans_denoising_invoker.hpp:126-143,213-226)。
10. denoise_TVL1 是 Chambolle 原始-对偶投影算法:L2=8、τ=0.02、σ=1/(L2τ),对偶变量球面投影 + 首轮 σ+1 加速(denoise_tvl1.cpp:63,82,94-98)。
11. Stitcher PANORAMA 默认配置是 ORB + BundleAdjusterRay + 中位数焦距 + waveCorrect(HORIZ) + GraphCut(COST_COLOR) + BlocksGainCompensator(32×32) + MultiBandBlender(5 层)(stitcher.cpp:61-63,79-81)。
12. 融合分辨率由 compose_resol(默认 −1 即原图)决定,三套相机参数按 compose_work_aspect 现场重标定;结果先以 CV_16S 累加再转 CV_8U 输出(stitcher.cpp:249-282,328,373)。

---
*本报告基于浅克隆工作树逐文件核对;所有行号可直接用 `sed -n 'Np'` 复验。*
