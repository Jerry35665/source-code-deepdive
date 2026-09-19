# 第 12 章 · photo 与 stitching:五种求解器与一条拼接主链

> 基线:commit `d3d247f1`(4.13.0-dev)。核心:modules/photo/src/(inpaint.cpp / seamless_cloning_impl.cpp / merge.cpp / tonemap.cpp)与 modules/stitching/src/。

## 12.0 全景:Stitcher 管线

```
 输入图像集
   ▼ 特征(默认 ORB,stitcher.cpp:61)→ 匹配 → 运动估计
   │   motion_estimators:焦距估计 + BundleAdjuster 光束法平差 + waveCorrect
   ▼ warp(球面/柱面)→ 接缝(默认 GraphCutSeamFinder(COST_COLOR),:81)
   ▼ 曝光补偿(默认 BlocksGainCompensator 32×32 块;GainCompensator 是块内求解器)
   ▼ 融合(MultiBandBlender 五层拉普拉斯金字塔)
 composePanorama 主链(stitcher.cpp)
```

纠偏:Stitcher PANORAMA 默认是 **ORB+BlocksGainCompensator+GraphCut(COST_COLOR)**,而非流传的 SURF/GainCompensator/COST_COLOR_GRAD(stitcher.cpp:61-63, 81)。

## 12.1 inpaint:一副 FMM 骨架跑两种权重

`icvInpaint` 把图像加 2 像素边、mask 标 INSIDE、3×3 十字膨胀减 mask 得窄带 BAND 入堆,T 初值 1e6(inpaint.cpp:718-742);优先队列以 T 升序出堆、同值按插入序稳定出堆(:88-95)。Eikonal 方程 Godunov 格式解两邻点取 min(:168-186)。**Telea 与 NS 共享骨架,差别只在权重**:Telea = 1/|r|^3 × 层级项 × r·∇T 方向项,再加等照度线一阶修正(:310-353);NS = 1/(|r|²+1) × 等照度线夹角项,输出纯加权平均(:519-567)。只认 INPAINT_NS/TELEA 两个 flag,其余 CV_Error(photo.hpp:95-96; inpaint.cpp:786-787)。

## 12.2 seamlessClone:DST 直接解

纠偏:Poisson 方程**不是稀疏迭代**,而是两次 DFT 合成的离散正弦变换直接解——按 Laplacian 特征值 `filter_X[i]+filter_Y[j]-4`(2cos+2cos−4)逐项相除,O(N log N) 无迭代(seamless_cloning_impl.cpp:151-162, 236-246)。三种模式在进求解器前改写 patch 梯度场:NORMAL 乘 mask、MIXED 逐像素比较**|gx−gy| 两通道差**(而非梯度模)选源、MONOCHROME 换灰度梯度(:336-386);colorChange/illuminationChange/textureFlattening 复用同一求解核只调梯度场(:394-456)。另有隐藏的 *_WIDE 枚举改变 ROI 定位(photo.hpp:743-759)。

## 12.3 HDR:三段式与"Durand 不在主仓"

纠偏:photo 无 hdr/ 子目录——HDR 是 merge.cpp/calibrate.cpp/tonemap.cpp 三个扁平单文件;**TonemapDurand 不在本仓库**(全仓 grep 只有 Durand-Kerner 求根注释;tonemap.cpp 只有线性/Drago/Reinhard/Mantiuk 四个,tonemap.cpp:56-299),Durand2002 已迁 contrib/xphoto。CalibrateDebevec:每通道采 70 点构建加权方程组(数据项 w·g(Z)−w·lnE=w·ln t + 中值固定 + λ 二阶差分平滑),SVD 最小二乘(calibrate.cpp:125-152);MergeDebevec 逐图 `result += w·(g(Z)−ln t)` 加权后 exp 还原(merge.cpp:98-122);Robertson 是闭式加权最小二乘+交替迭代 30 轮;Mertens 与 HDR 无关——对比度/饱和度/曝光适度三权重+拉普拉斯金字塔融合(merge.cpp:191-270)。

## 12.4 NL-means:滑窗增量,不是积分图

纠偏:fastNlMeans CPU 实现**不用积分图**——是"上一列距离和增量更新"(up_col_dist_sums+calcUpDownDist)+预计算权重查找表+定点移位(fast_nlmeans_denoising_invoker.hpp:126-143, 213-226, 242-243)。

## 12.5 设计动机

1. **FMM 优先队列稳定出堆**:同波前像素确定性处理,结果可复现(inpaint.cpp:88-95);
2. **DST 直接解**:矩形域 Laplacian 特征值解析已知,直接频除免迭代(seamless_cloning_impl.cpp:151-162);
3. **HDR 方程组显式组装**:数据项+固定中值+平滑项三段清晰,可对照 Debevec 论文逐行验证(calibrate.cpp:125-148);
4. **权重查找表+定点移位**:NL-means 把指数权重离线化,滑窗增量复用列和(invoker:126-143);
5. **拼接工厂化**:六阶段各自可替换(特征/接缝/补偿/融合),默认组合面向手持全景(stitcher.cpp:61-81)。

## 12.6 FAQ

**Q1:inpaint 支持几种算法?**
两种:INPAINT_NS/INPAINT_TELEA,其余报错(photo.hpp:95-96)。

**Q2:seamlessClone 是迭代求解吗?**
不是,DST 频域直接解,O(N log N)(seamless_cloning_impl.cpp:151-162)。

**Q3:TonemapDurand 在主仓吗?**
不在,已迁 contrib/xphoto;主仓四个 tonemap。

**Q4:Mertens 融合需要曝光时间吗?**
不需要,纯 LDR 多图三权重融合,默认 exposure_weight=0(merge.cpp:191-225)。

**Q5:fastNlMeans 用积分图吗?**
不用,滑窗列和增量更新+权重查找表(invoker:213-226)。

**Q6:Stitcher 默认特征是什么?**
ORB;接缝 GraphCut(COST_COLOR)、补偿 Blocks 32×32(stitcher.cpp:61-63, 81)。

**Q7:MIXED_CLONE 怎么选梯度?**
逐像素比较 |gx−gy| 两通道差选源,不是梯度模(impl:359-360)。

**Q8:Robertson 标定怎么收敛?**
交替迭代:merge→反推响应→中值归一,差值<0.01 停,默认 30 轮(calibrate.cpp:244-272)。

**Q9:MutiBandBlender 多少层?**
默认 5 层拉普拉斯(blenders.cpp;band Numbers 由编译参数定)。

**Q10:NL-means 为什么快?**
预计算权重 LUT+定点移位+列和增量,避免每窗口重算指数(invoker:126-143)。

## 12.7 小结与深挖方向

本章结论:**photo=FMM/DST/SVD/滑窗增量/原始-对偶五种求解器;stitching=工厂化的六阶段主链**。深挖:

1. Telea 的 ∇I 差分系数 2.0f 与 0.5 的量纲不一致是否影响输出(inpaint.cpp:319);
2. DST 求解器对非矩形 mask 的边界内缩策略(seamless_cloning.cpp:79-80);
3. BlocksGainCompensator 的块间增益图平滑(exposure_compensate.cpp:605-608);
4. GraphCutSeamFinder 的 COST_COLOR vs COST_COLOR_GRAD 代价项实现;
5. MultiBandBlender 的金字塔层数自适应与源图尺寸关系(blenders.cpp)。
