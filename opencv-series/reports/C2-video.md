# 报告 C2 · video 时序分析(OpenCV 卷二)

> 基线:d3d247f1(4.13.0-dev,gitee 浅克隆)。一句话总结:modules/video 用五个"老而硬"的算法族支撑时序分析——定点数金字塔 LK 稀疏光流、Farnebäck 多项式展开稠密光流、Brox2004 式变分精化(同时充当 DIS 的内循环)、Zivkovic 自适应分量数的 MOG2/KNN 背景建模,以及 Kalman/CamShift 两个经典时序滤波跟踪器;全部以 CPU SIMD 为主体,OpenCL 仅为平行实现并带严格参数闸门。

## 1. 文件地图与本 commit 事实

- 稀疏 LK:`lkpyramid.cpp`(1558 行)+ `lkpyramid.hpp`(deriv_type=short,lkpyramid.hpp:8);OpenCL kernel `opencl/pyrlk.cl`(558 行)。
- 稠密 Farnebäck:**文件名是 `optflowgf.cpp`(1211 行,"gf"=Gunnar Farnebäck),不是 optflow_farneback.cpp**;OpenCL kernel 文件才叫 `optical_flow_farneback.cl`。
- 变分精化:`variational_refinement.cpp`(1241 行),`VariationalRefinement` 声明于 tracking.hpp:552。
- 背景建模:MOG2 在 **`bgfg_gaussmix2.cpp`**(996 行)而非 bgfg_mog2.cpp;KNN 在 `bgfg_KNN.cpp`(913 行);头文件仍是 `background_segm.hpp`(MOG2 类在 background_segm.hpp:105,KNN 在 :256)。
- 滤波与跟踪:`kalman.cpp`(134 行)、`camshift.cpp`(220 行)。另有 `dis_flow.cpp`、`ecc.cpp` 本章仅作关联带过。

## 2. 金字塔 LK:calcOpticalFlowPyrLK 全链路(lkpyramid.cpp)

**入口是薄封装**:calcOpticalFlowPyrLK 直接 create + calc(lkpyramid.cpp:1432-1441);默认参数 winSize=21×21、maxLevel=3、TermCriteria(COUNT+EPS,30,0.01)、minEigThreshold=1e-4(lkpyramid.cpp:857-861)。

**层数判定与"小图像分支"**:buildOpticalFlowPyramid 断言 winSize>2(lkpyramid.cpp:753),每层先把图像四周按 winSize 补边 copyMakeBorder(lkpyramid.cpp:788),再 pyrDown(lkpyramid.cpp:808),导数用 Scharr 算子 calcScharrDeriv(竖向 [-3,10,3]、横向同核,系数 3/10 在 lkpyramid.cpp:115-116,151);注意 calc 主流程建金字塔时 withDerivatives=false(lkpyramid.cpp:1380、1383),导数改为每层现场计算(lkpyramid.cpp:1400-1413)。**关键截断**:每次降采样后若 `sz.width <= winSize.width || sz.height <= winSize.height` 立即收缩 pyramid 并返回当前 level;calc 端若用户传入 STD_VECTOR_MAT 金字塔,也会把 maxLevel 压到实际层数(lkpyramid.cpp:1347-1348、1375-1376)。所以 maxLevel 是上限而非保证值。

```cpp
// lkpyramid.cpp:832-837  层数截断:半分辨率图不再比窗口大就停
sz = Size((sz.width+1)/2, (sz.height+1)/2);
if( sz.width <= winSize.width || sz.height <= winSize.height )
{
    pyramid.create(1, (level + 1) * pyrstep, 0 /*type*/, -1, true);
    return level;
}
```

Scharr 导数的实现细节:竖向卷积 `t0=(srow0+srow2)*3+srow1*10`、`t1=srow2-srow0`,横向再做 `trow0[x+cn]-trow0[x-cn]` 与 `(trow1[x+cn]+trow1[x-cn])*3+trow1[x]*10`,Ix/Iy 交错存为 short 对(lkpyramid.cpp:115-118、148-153),等价于 3×3 Scharr 核 [[-3,0,3],[-10,0,10],[-3,0,3]] 的两方向;行边界按最近有效行复制(lkpyramid.cpp:89-91、122-127)。SIMD 部分用 v_dotprod 定点卷积,4 像素一组(lkpyramid.cpp:305-374)。

**逐层求解(LKTrackerInvoker::operator(),lkpyramid.cpp:187-745)**:
- 定点化:W_BITS=14、FLT_SCALE=1/(1<<20),导数与灰度全部按 2^14 定标后用 int16/int32 SIMD 累加(lkpyramid.cpp:191-192);窗口中心 halfWin=(winSize-1)*0.5(lkpyramid.cpp:194)。
- 坐标传递:prevPt 按 1/2^level 缩放;最高层初值取 prevPt(或 OPTFLOW_USE_INITIAL_FLOW 时的 nextPts),低层一律 nextPt=上层结果×2(lkpyramid.cpp:211-222)。
- 一次提取、多次复用:先在 prev 图提取窗口双线性灰度 IWinBuf 与导数 derivIWinBuf,并累加结构张量 A11/A12/A22(lkpyramid.cpp:295-494);之后每轮迭代只重算 J 侧 diff(lkpyramid.cpp:663-668)。

```cpp
// lkpyramid.cpp:687-702  增量求解、写回与双重终止
Point2f delta( (float)((A12*b2 - A22*b1) * D),
              (float)((A12*b1 - A11*b2) * D));
//delta = -delta;                       // 历史遗迹:符号曾被讨论(仅注释)
nextPt += delta;
nextPts[ptidx] = nextPt + halfWin;      // 每轮都写回,便于低层继承
if( delta.ddot(delta) <= criteria.epsilon )   // epsilon 已被平方(1393)
    break;
if( j > 0 && std::abs(delta.x + prevDelta.x) < 0.01 &&
   std::abs(delta.y + prevDelta.y) < 0.01 )   // 相邻增量反号→振荡,回退半步
{
    nextPts[ptidx] -= delta*0.5f;
    break;
}
```

**终止条件在 calc 里被归一化**:maxCount 未设则 30、夹到 [0,100];epsilon 未设则 0.01、夹到 [0,10];然后 `criteria.epsilon *= criteria.epsilon`(lkpyramid.cpp:1385-1393)——因为终止比较的是 delta·delta(lkpyramid.cpp:694),默认 0.01 实际对应 0.1 像素位移阈值。

```cpp
// lkpyramid.cpp:1385-1393  终止条件归一化(ε 平方)
if( (criteria.type & TermCriteria::COUNT) == 0 )
    criteria.maxCount = 30;
else
    criteria.maxCount = std::min(std::max(criteria.maxCount, 0), 100);
if( (criteria.type & TermCriteria::EPS) == 0 )
    criteria.epsilon = 0.01;
else
    criteria.epsilon = std::min(std::max(criteria.epsilon, 0.), 10.);
criteria.epsilon *= criteria.epsilon;
```

判废还有一个前置:窗口起点 iprevPt 满足 `x < -winSize.width || x >= derivI.cols || y < -winSize.height || y >= derivI.rows` 时该点本层直接跳过(lkpyramid.cpp:245-255);J 侧迭代中每次重取 inextPt 后再查一次(lkpyramid.cpp:520-526)。补边恰为 winSize,因此"点在图内但窗口出界"是允许的——出界读落在补边上。

**判废与误差**:结构张量最小特征值 minEig=(A11+A22-√((A11-A22)²+4A12²))/(2·winSize.area())(lkpyramid.cpp:496-498);`minEig < minEigThreshold || D < FLT_EPSILON` 即废点(lkpyramid.cpp:503-508);status 只在 level==0 时落笔 false(lkpyramid.cpp:248-250、523-524)。err 默认是 level 0 窗口内平均绝对差 errval/(32·winSize.area()·cn)(lkpyramid.cpp:742),置 OPTFLOW_LK_GET_MIN_EIGENVALS 时改为输出 minEig(lkpyramid.cpp:500-501)。

**OpenCL/简化分支**:CV_OCL_RUN 门控要求 UMat 输入且支持 CV_32F image 格式(lkpyramid.cpp:1266-1268);checkParam 强制 winSize∈[8,24]、iters≤100(lkpyramid.cpp:893-909);kernel 以 8×8 线程组织,winSize<16 时置编译期 WSX/WSY=0 精简路径(lkpyramid.cpp:1006-1010);OpenCL 路径不做 Scharr 预计算(输入转 CV_32F 后建纯金字塔,lkpyramid.cpp:946-953),GET_MIN_EIGENVALS 时直接拒绝走 OCL(lkpyramid.cpp:1055-1056)。**OpenVX 分支被硬编码禁用**:`CV_OVX_RUN(false, openvx_pyrlk(...)) // Disabled due to bad accuracy`(lkpyramid.cpp:1271-1273)。

```
金字塔 LK 一次点跟踪(单点,共 L+1 层)
        prevImg                     nextImg
           │ pyrDown×L (含winSize补边, 832层截断)        │
           ▼                                             ▼
   [L0]┌────────┐      x_L = prevPt/2^L  (初值或INITIAL_FLOW)
       │ 层 L   │◄──── nextPt_L ◄─── 2×nextPt_{L+1}(层间上采样, 221)
       │ Scharr │      ┌──────────────────────────────┐
       │ 导数   │      │ for j < maxCount(≤100):      │
       └───┬────┘      │   J侧双线性diff   (663-668)  │
           ▼           │   Δ = A⁻¹·b      (687-688)   │
   [L1]…    └─────────►│   nextPt += Δ; 写回(692)     │
           层内循环:    │   Δ·Δ ≤ ε² ? 退(694)        │
           A 只算一次   │   Δₙ ≈ -Δₙ₋₁ ? 回半步(697)  │
           (295-494)   └──────────────────────────────┘
           ▼
   [L0] 最终 status/err:minEig 阈值判废(503) + 平均|diff|(742)
```

**附带观察**:lkpyramid.cpp 尾部还住着旧版 `cv::estimateRigidTransform`——图像输入会被缩到 ≤160×120、铺 15 行网格点跑 calcOpticalFlowPyrLK(Size(21,21),3 层,TermCriteria(MAX_ITER,40,0.1)),再交给 estimateAffine2D/estimateAffinePartial2D(lkpyramid.cpp:1443-1558,采样与 LK 调用在 1512-1529、1549-1556);它要求 calib3d 存在,否则直接 CV_Error(lkpyramid.cpp:1446-1448)。

## 3. Farnebäck 多项式展开稠密光流(optflowgf.cpp)

算法出处注释:Gunnar Farneback, "Two-Frame Motion Estimation Based on Polynomial Expansion"(optflowgf.cpp:52-55)。CPU 主流程在 FarnebackOpticalFlowImpl::calc(optflowgf.cpp:1098-1190),默认 numLevels=5、pyrScale=0.5、winSize=13、numIters=10、polyN=5、polySigma=1.1(optflowgf.cpp:588-589)。

**到代码的映射(论文→函数)**:
1. G(亮度平滑):每层对原图做 σ=(1/scale−1)×0.5 的高斯模糊后再 resize(optflowgf.cpp:1141-1143、1173-1174)——缩得越狠平滑越弱,抵消 pyrDown 造成的过度模糊。
2. 多项式展开:FarnebackPolyExp 对每个像素拟合二次曲面,输出 5 通道系数(不存常数项,"do not store r1");权重 g/xg/xxg 与 6×6 矩阵的逆仅 4 个标量 ig11/ig03/ig33/ig55 参与(optflowgf.cpp:60-114);sigma<ε 时退化为 n×0.3(optflowgf.cpp:64-65)。

```cpp
// optflowgf.cpp:193-198  五通道系数存储(跳过常数项 r1)
// do not store r1
drow[x*5+1] = (float)(b2*ig11);              // 一次项
drow[x*5]   = (float)(b3*ig11);              // 一次项
drow[x*5+3] = (float)(b1*ig03 + b4*ig33);    // 平方项
drow[x*5+2] = (float)(b1*ig03 + b5*ig33);    // 平方项
drow[x*5+4] = (float)(b6*ig55);              // 交叉项 xy
```

3. 位移估计:FarnebackUpdateMatrices 用当前流双线性采 R1,构造逐像素 5 通道线性系统 [G11,G12,G22,h1,h2]——线性项取 (R0−R1)/2,二次项取 (R0+R1)/2、xy 项因对称除 4(optflowgf.cpp:259-261、286-287);组装式 `M[0]=r4²+r6², M[1]=(r4+r5)r6, M[2]=r5²+r6², M[3]=r4r2+r6r3, M[4]=r6r2+r5r3`(optflowgf.cpp:304-308);图像四周 5 像素用 {0.14,0.14,0.4472,0.4472,0.4472} 衰减置信度(optflowgf.cpp:220-221、292-302)。采不到 R1 的点线性项清零、只保留 R0 二次项(optflowgf.cpp:278-284)。
4. 聚合迭代:numIters 轮在 winSize 邻域把 M 盒滤波(FarnebackUpdateFlow_Blur,optflowgf.cpp:314-404)或高斯滤波(sigma=m×0.3,FarnebackUpdateFlow_GaussianBlur,optflowgf.cpp:407-577,flag=OPTFLOW_FARNEBACK_GAUSSIAN 时,tracking.hpp:61),然后解 2×2 方程 idet=1/(g11·g22−g12²+1e-3)(optflowgf.cpp:391-394)。为摊薄成本,M 只按条纹增量更新:`min_update_stripe = max(1024/width, block_size)`(optflowgf.cpp:322、397-402、415、570-575)。

```cpp
// optflowgf.cpp:1180-1186  每层迭代;最后一轮不再更新矩阵(省一次 O(WH))
for( i = 0; i < numIters_; i++ )
{
    if( flags_ & OPTFLOW_FARNEBACK_GAUSSIAN )
        FarnebackUpdateFlow_GaussianBlur( R[0], R[1], flow, M, winSize_, i < numIters_ - 1 );
    else
        FarnebackUpdateFlow_Blur( R[0], R[1], flow, M, winSize_, i < numIters_ - 1 );
}
```

金字塔层数同样按 min_size=32 截断:scale 乘 pyrScale 直到宽或高 <32 即停(optflowgf.cpp:1107、1127-1134);上层流 resize 后乘 1/pyrScale 上采样作为下层初值(optflowgf.cpp:1165-1166)。OpenCL 版另有约束:polyN 必须 5 或 7(optflowgf.cpp:638、1063)、fastPyramids 仅支持 pyrScale=0.5(optflowgf.cpp:639);calcOpticalFlowFarneback 老接口固定 fastPyramids=false(optflowgf.cpp:1194-1203)。

## 4. 变分精化:Brox2004,不是 TV-L1

`VariationalRefinement` 的能量为 E(U)=∫δΨ(E_I)+γΨ(E_G)+αΨ(E_S)(颜色常性+梯度常性+平滑项,Ψ(s²)=√(s²+ε²)),文档明确引用 Brox2004(tracking.hpp:542-550)。**主仓库 modules/ 下 grep 不到任何 DualTVL1/TVL1 符号**;TV-L1 位于 opencv_contrib 的 optflow 模块(本仓库外,其内部未核实)。与 Farnebäck 的关系:两者是并列的稠密光流算法,Farnebäck 不使用它;真正内置消费者是 DIS——每层 densification 之后调用 `variational_refinement_processors[i]->calcUV(...)`(dis_flow.cpp:1496-1497),处理器是每层一个 `VariationalRefinement::create()`(dis_flow.cpp:139、236)。

最小化结构:外层 fixedPointIterations(默认 5)次定点迭代,内层 sorIterations(默认 5)次 Red-Black SOR;默认 α=20、δ=5、γ=10、ω=1.6、ζ=0.1、ε=0.001(variational_refinement.cpp:217-228)。数据项把 δ 加权颜色常性、γ 加权梯度常性线性化进 A/b(variational_refinement.cpp:693-722);平滑项权重 α 出现在 variational_refinement.cpp:827;SOR 松弛 ω 直接写在更新式里(variational_refinement.cpp:1109-1110)。calc 要求输入 8U 或 32F 单通道、流为 CV_32FC2 且同尺寸(variational_refinement.cpp:1119-1124);calcUV 的主体循环为"数据项红/黑两遍 → 平滑项水平/垂直遍 → sorIterations 轮 SOR 红/黑两遍 → W←W+dW 更新边界"(variational_refinement.cpp:1164-1194)。

```cpp
// variational_refinement.cpp:1109-1110  Red-Black SOR 的逐点更新(ω 松弛)
pdu[j] += var->omega * ((sigmaU + pb1[j] - pdv[j] * pa12[j]) / pa11[j] - pdu[j]);
pdv[j] += var->omega * ((sigmaV + pb2[j] - pdu[j] * pa12[j]) / pa22[j] - pdv[j]);
```

ζ(0.1)在代码里以平方形式并入归一化因子 derivNorm 与对角项(ζ²=0.01,variational_refinement.cpp:588-589、695、701);ε 同样以平方进惩罚 Ψ(variational_refinement.cpp:699、716、827)。

```cpp
// variational_refinement.cpp:83-88  red-black 布局的自述(设计动机见 §8)
/* This struct defines a special data layout for Mat_<float>. Original buffer is split into
 * two: one for "red" elements (sum of indices is even) and one for "black" (sum of indices
 * is odd) in a checkerboard pattern. It allows for more efficient processing in SOR
 * iterations, more natural SIMD vectorization and parallelization (Red-Black SOR). ... */
```

## 5. MOG2 背景建模:bgfg_gaussmix2.cpp 的更新方程

Zivkovic 2004/2006 两篇论文的注释头部(bgfg_gaussmix2.cpp:43-64);默认值集中在 bgfg_gaussmix2.cpp:106-118:history=500(注释:α=1/history)、varThreshold=16(4σ²)、nmixtures=5、backgroundRatio=0.9、varThresholdGen=9(3σ²)、varInit=15、varMax=75、varMin=4、fCT=0.05、shadow 值=127、τ=0.5。模型内存为每像素 K 组 (w, μ, σ²) 扁平 float 数组:bgmodel 尺寸 h·w·K·(2+cn)(bgfg_gaussmix2.cpp:230-234)。

**学习率**:apply 时若用户 learningRate≥0 且 nframes>1 则用之,否则 `1./std::min(2*nframes, history)`(bgfg_gaussmix2.cpp:900);prune = −learningRate×fCT(bgfg_gaussmix2.cpp:910)——复杂度先验直接变成权重衰减项。

**逐像素更新(MOG2Invoker,bgfg_gaussmix2.cpp:573-768)**:权重新值 = α₁·w+prune(bgfg_gaussmix2.cpp:623);匹配判定分两级——背景级 `totalWeight<TB && dist2<Tb·var`(bgfg_gaussmix2.cpp:653-654),拟合级 `dist2<Tg·var`(bgfg_gaussmix2.cpp:657);命中后 w+=αT、k=αT/w、μ←μ−k·d、σ²←σ²+k·(dist2−σ²) 并夹到 [varMin,varMax](bgfg_gaussmix2.cpp:666-678),命中分量按权重冒泡上浮排序(bgfg_gaussmix2.cpp:683-694);w<−prune 的分量剪除(bgfg_gaussmix2.cpp:701-705);无匹配且 αT>0 时替换最弱分量,σ²=varInit(bgfg_gaussmix2.cpp:726-746);最后归一化权重(bgfg_gaussmix2.cpp:715-723)。

```cpp
// bgfg_gaussmix2.cpp:663-678  命中分量的 EM 式在线更新
//update weight
weight += alphaT;
float k = alphaT/weight;
//update mean
for( int c = 0; c < nchannels; c++ )
    mean_m[c] -= k*dData[c];
//update variance
float varnew = var + k*(dist2-var);
//limit the variance
varnew = MAX(varnew, varMin);
varnew = MIN(varnew, varMax);
gmm[mode].variance = varnew;
```

注意两点次序细节:排序发生在权重新值算出后立刻进行、逐分量冒泡(bgfg_gaussmix2.cpp:680-694),而"剪枝"(w<−prune 置 0 并 nmodes--)在循环体内边走边做(bgfg_gaussmix2.cpp:700-705);新分量若与现有权重相比过小,也会再次冒泡沉底(bgfg_gaussmix2.cpp:748-760)。已知前景掩码(apply 的 4 参重载)命中时直接 mask=255 并跳过更新(bgfg_gaussmix2.cpp:597-606、868-897)。

**阴影检测**(detectShadowGMM,bgfg_gaussmix2.cpp:480-525):对背景分量算标量投影 a=Σ(d·μ)/Σ(μ·μ),满足 `numerator≤denominator && numerator≥τ·denominator`(即 0<a≤1,像素是背景的"变暗版本")且色度残差 dist2a<Tb·σ²·a²(即 ±√Tb·σ)才判阴影(bgfg_gaussmix2.cpp:505-516);输出掩码:背景=0、阴影=127、前景=255(bgfg_gaussmix2.cpp:765-767)。依据 Prati et al. PAMI2003(注释 bgfg_gaussmix2.cpp:477-479)。OpenCL 路径同参并要求 UMat(bgfg_gaussmix2.cpp:789-834),kernel 源为 bgfg_mog2.cl。

**KNN 版一句话**:bgfg_KNN.cpp 实现 Zivkovic & van der Heijden 2006 的非参数 K 近邻模型(bgfg_KNN.cpp:45-50),默认每像素存 7 个样本、判前/背景的平方距离阈值 20²(bgfg_KNN.cpp:56-57),同样带 τ=0.5 的阴影检测(bgfg_KNN.cpp:59-60)。

## 6. Kalman 滤波与 CamShift

**KalmanFilter 纯矩阵实现(kalman.cpp,全文件 134 行)**:predict 是 x'←A·x(+B·u)、P'←A·P·Aᵀ+Q,其中 A·P·Aᵀ 用 gemm(...,GEMM_2_T) 一次完成(kalman.cpp:87-97);副作用是把 statePre/errorCovPre 复制回 statePost/errorCovPost,保证"无 measurement 连续 predict"也自洽(kalman.cpp:99-101)。correct 的增益不求显式逆:temp3=H·P'·Hᵀ+R 后 `solve(temp3, temp2, temp4, DECOMP_SVD)` 得 Kᵀ,再转置(kalman.cpp:111-120);随后 x←x'+K(z−H·x')、P←P'−K·(H·P')(kalman.cpp:123-129)。

```cpp
// kalman.cpp:87-101  predict:状态与协方差外推 + 无观测自洽回写
// update the state: x'(k) = A*x(k)
statePre = transitionMatrix*statePost;
if( !control.empty() )
    // x'(k) = x'(k) + B*u(k)
    statePre += controlMatrix*control;
// update error covariance matrices: temp1 = A*P(k)
temp1 = transitionMatrix*errorCovPost;
// P'(k) = temp1*At + Q
gemm(temp1, transitionMatrix, 1, processNoiseCov, 1, errorCovPre, GEMM_2_T);
// handle the case when there will be no measurement before the next predict.
statePre.copyTo(statePost);
errorCovPre.copyTo(errorCovPost);
```

```cpp
// kalman.cpp:116-120  增益 = S⁻¹·H·P' 经一次 SVD solve + 转置
// temp4 = inv(temp3)*temp2 = Kt(k)
solve(temp3, temp2, temp4, DECOMP_SVD);
// K(k)
gain = temp4.t();
```

构造期只分配 5 个临时 Mat(temp1..temp5,kalman.cpp:75-79),controlParams≤0 时 controlMatrix 直接 release(kalman.cpp:70-73);类型仅允许 CV_32F/CV_64F(kalman.cpp:55)。

**meanShift(camshift.cpp:44-107)**:窗口内求矩,位移 dx=m10/m00−w/2、dy 同理(camshift.cpp:89-90),迭代至 `dx²+dy²<eps²`(eps 在入口被平方,camshift.cpp:68-69)或 maxCount(缺省 100,camshift.cpp:70);窗口每轮先夹回图像范围,非法空窗则重置到图像中心(camshift.cpp:74-81);m00≈0(窗内零概率)即退(camshift.cpp:86-87),函数返回实际迭代次数 i(camshift.cpp:106)。

**CamShift(camshift.cpp:110-218)**:先调 meanShift(camshift.cpp:126),随后窗口四边各外扩常数 TOLERANCE=10(camshift.cpp:115、128-142)——**不是循环扩张**;再由二阶矩 a=μ20/m00、b=μ11/m00、c=μ02/m00 求 θ=atan2(2b, a−c+√(4b²+(a−c)²))(camshift.cpp:156-162),旋转后的二阶矩给 length=4·√(rotate_a/m00)、width=4·√(rotate_c/m00)(camshift.cpp:168-173),必要时长宽互换、θ 改写(camshift.cpp:176-181);下一帧窗口宽 = max(|len·cosθ|,|w·sinθ|)+2(camshift.cpp:187-203)。RotatedRect 角度归一化到 [0,180)(camshift.cpp:208-214)。

## 7. 纠偏与设计动机(以本 commit 源码为准)

### 7.1 纠偏

1. **Farnebäck 文件名**:是 `optflowgf.cpp`,不是"optflow_farneback.cpp";后者只存在于 OpenCL kernel 资源名 `optical_flow_farneback_oclsrc`(optflowgf.cpp:873)。
2. **variational_refinement ≠ TV-L1**:它最小化 Brox2004 的 δΨ(E_I)+γΨ(E_G)+αΨ(E_S)(tracking.hpp:544-550);本仓库无 DualTVL1 符号(modules/ 全量 grep 为空),常见教程把二者混为一谈。
3. **maxLevel 不是承诺**:buildOpticalFlowPyramid 在层尺寸 ≤ winSize 时截断并返回实际层数(lkpyramid.cpp:832-837),用户自带金字塔时同样被钳制(lkpyramid.cpp:1347-1348、1375-1376)。
4. **epsilon 语义**:LK 的 ε 在进入迭代前被平方(lkpyramid.cpp:1393),默认 0.01 实际是"位移模长 ≤0.1 像素即停",直接读文档容易误解。
5. **MOG2 文件名**:实现文件是 `bgfg_gaussmix2.cpp`;`bgfg_mog2.cl` 只是它的 OpenCL kernel。
6. **OpenVX LK 被禁用**:CV_OVX_RUN(false, ...) + 注释 "Disabled due to bad accuracy"(lkpyramid.cpp:1271-1273),不是可选加速路径。
7. **CamShift 的"扩张循环"**:窗口扩张是 meanShift 收敛后的**一次性**常数 10 外扩(camshift.cpp:126-142),循环性质只属于 meanShift 自身的迭代(camshift.cpp:72-103)。
8. **LK 层间传递**:低层初值是上层结果 ×2(lkpyramid.cpp:221),且每轮迭代即写回 nextPts(lkpyramid.cpp:692),并非层结束才写。

### 7.2 设计动机(源码证据,≥5 条)

1. **由粗到细的金字塔**:把大位移拆成每层小位移,弥补 LK 的一阶泰勒假设;初值跨层 ×2 传递(lkpyramid.cpp:211-222)。
2. **定点数窗口预算**:W_BITS=14 定标 + int16/32 SIMD 使窗口内积全程整数化,仅在外围乘 FLT_SCALE 还原(lkpyramid.cpp:191-192、492-494),为的是 128 位通道一次处理 8 像素。
3. **Farnebäck 的"参数化+聚合"**:二次曲面 5 系数把逐像素优化降为 2×2 闭式解 + 邻域盒/高斯聚合(optflowgf.cpp:304-308、391-394),无迭代收敛问题;每层 σ 随 scale 自适应防止过度平滑(optflowgf.cpp:1141)。
4. **MOG2 的自适应分量数**:fCT 复杂度先验化作 prune=−lr·fCT 的权重衰减(bgfg_gaussmix2.cpp:910、701-705),模型规模逐像素自动伸缩——Zivkovic 对 Stauffer-Grimson 的核心增量(注释 bgfg_gaussmix2.cpp:58-63)。
5. **Red-Black 棋盘布局**:把 SOR 的串行依赖解耦为红黑两相,天然并行 + SIMD(variational_refinement.cpp:83-88,更新式 1109-1110)。
6. **数值稳健的 Kalman**:增益用 DECOMP_SVD 的 solve 而非显式求逆(kalman.cpp:117);predict 顺手回写 post 状态处理"无观测"帧(kalman.cpp:99-101)。
7. **OpenCL 闸门化**:LK 限定 winSize∈[8,24]、Farnebäck 限定 polyN∈{5,7} 且 fastPyramids 需 pyrScale=0.5(lkpyramid.cpp:900-904;optflowgf.cpp:638-639),不满足即静默回退 CPU,保证精度一致。

## 8. FAQ 候选与深挖方向

### 8.1 FAQ 候选(每条一句话答案)

1. calcOpticalFlowPyrLK 的默认窗口、层数、终止条件是什么?——21×21、maxLevel=3、TermCriteria(COUNT+EPS,30,0.01)、minEigThreshold=1e-4(lkpyramid.cpp:857-861)。
2. 为什么传 maxLevel=5 实际层数可能更少?——某层降采样后尺寸 ≤winSize 即截断(lkpyramid.cpp:832-837)。
3. status=false 都有哪些触发点?——窗口起点越界(lkpyramid.cpp:245-255、520-526、714-719)或 minEig<阈值/行列式过小(lkpyramid.cpp:503-508),且只在 level 0 落笔。
4. err 输出的两种含义?——默认为 level 0 窗口平均绝对差(lkpyramid.cpp:742),OPTFLOW_LK_GET_MIN_EIGENVALS 时为结构张量最小特征值(lkpyramid.cpp:497-501)。
5. Farnebäck 的 polyN/polySigma 是什么?——多项式展开的拟合窗口与高斯加权,σ 缺省 n×0.3(optflowgf.cpp:64-65),OpenCL 仅允许 5/7(optflowgf.cpp:638)。
6. OPTFLOW_FARNEBACK_GAUSSIAN 改变了什么?——位移聚合从盒滤波换成 σ=(winSize/2)×0.3 的高斯滤波(optflowgf.cpp:1182-1185、416)。
7. MOG2 的默认学习率怎么算?——未显式给时为 1/min(2·nframes, history),即前几百帧快速收敛(bgfg_gaussmix2.cpp:900)。
8. MOG2 掩码里 127 是什么?——阴影标记值 nShadowDetection,255 前景、0 背景(bgfg_gaussmix2.cpp:117、765-767)。
9. KalmanFilter 如何求增益而不做矩阵求逆?——solve(S, H·P', DECOMP_SVD) 得 Kᵀ 再转置(kalman.cpp:117-120)。
10. CamShift 返回的角度范围?——归一化到 [0,180)(camshift.cpp:208-214)。
11. DIS 光流和本章谁有关?——其每层变分精化直接复用 VariationalRefinement 实例(dis_flow.cpp:139、236、1496-1497)。

### 8.2 深挖方向(5 条)

1. `opencl/pyrlk.cl` 内核:GPU 上 Scharr 与迭代的排布、WSX/WSY<16 精简路径与 CPU 定点路径的精度差异(lkpyramid.cpp:1006-1042)。
2. `optical_flow_farneback.cl` 的 polynomialExpansion 共享内存实现与 CPU FarnebackPolyExp 的系数一致性(optflowgf.cpp:915-950)。
3. DIS 的 PatchInverseSearch/整层流水线与 VariationalRefinement 每层耦合的消融(dis_flow.cpp:1478-1497)。
4. `bgfg_mog2.cl` 与 CPU MOG2Invoker 的更新次序差异(排序/剪枝是否逐位一致,bgfg_gaussmix2.cpp:789-834)。
5. `ecc.cpp`(ECC 迭代配准)与 LK 同为增量式对齐,比较其雅可比参数化与 rot/refine 策略(ecc.cpp,未在本报告展开)。

## 正文蒸馏要点(8-12 条核心论断)

1. calcOpticalFlowPyrLK 是薄封装,SparsePyrLKOpticalFlowImpl::calc 承载全部逻辑,默认 21×21/3 层/30 次迭代/ε=0.01/最小特征值阈值 1e-4(lkpyramid.cpp:1432-1441、857-861)。
2. 实际金字塔层数由 buildOpticalFlowPyramid 按"层尺寸>winSize"截断决定,833-836 行的提前 return 是小图像退化的根源(lkpyramid.cpp:832-837)。
3. LK 用 14 位定点数实现窗口内积,A(结构张量)一次提取终身复用,迭代只重算 J 侧 diff,δ=A⁻¹b 闭式更新(lkpyramid.cpp:191-192、295-494、687-691)。
4. 双重终止:δ·δ≤ε²(ε 入口被平方,1393/694)与相邻增量反号振荡回退半步(lkpyramid.cpp:697-702)。
5. 废点判定 = minEig<minEigThreshold 或 det≈0,只有 level 0 才置 status=false(lkpyramid.cpp:496-508、248-250)。
6. Farnebäck 在 optflowgf.cpp:层自适应 σ=(1/scale−1)/2 → 高斯平滑 → 5 系数多项式展开 → (R0−R1)/2 与 (R0+R1)/2 组装 2×2 系统 → winSize 邻域盒/高斯聚合 ×numIters(optflowgf.cpp:1141-1186、286-308)。
7. Farnebäck 图像边缘 5 像素按固定表衰减置信度、方程加 1e-3 正则(optflowgf.cpp:220-221、391)。
8. VariationalRefinement 是 Brox2004 式(δ/γ/α 三能量项+Ψ 稳健惩罚),最小化用定点迭代×Red-Black SOR(ω=1.6),不是 TV-L1;TV-L1 不在本仓库(tracking.hpp:542-552、variational_refinement.cpp:217-228、83-88)。
9. DIS 的每层精化直接复用该类,即"DIS=逆搜索粗解+Brox 式精化"的实现事实(dis_flow.cpp:139、236、1496-1497)。
10. MOG2 更新四件套:w←α₁w+prune、命中则 w+=αT 与 μ/σ² 指数滑动(k=αT/w)、权重冒泡排序、无匹配替换最弱分量;prune=−lr·fCT 实现自适应分量数(bgfg_gaussmix2.cpp:623、666-694、701-746、910)。
11. MOG2 学习率缺省 1/min(2·nframes, history);阴影=背景分量的暗投影(a∈[τ,1] 且色度残差<√Tb·a·σ),掩码 0/127/255 三值(bgfg_gaussmix2.cpp:900、505-516、765-767)。
12. Kalman correct 用 SVD solve 求 Kᵀ 避免显式求逆,predict 自回写支持无观测帧;CamShift=meanShift+一次性 10 像素外扩+二阶矩直接解出带角度的 RotatedRect 并同步给出下一帧窗口(kalman.cpp:97-129;camshift.cpp:115-142、159-203)。
