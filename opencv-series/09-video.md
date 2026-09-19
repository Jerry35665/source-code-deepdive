# 第 09 章 · video:定点数 LK、多项式展开光流与 MOG2 更新方程

> 基线:commit `d3d247f1`(4.13.0-dev)。核心:modules/video/src/(lkpyramid.cpp / optflowgf.cpp / variational_refinement.cpp / bgfg_gaussmix2.cpp)。

## 9.0 全景:一次点跟踪的金字塔 LK

```
 prevImg ──pyrDown×L(每层先按 winSize 补边;降采样后 ≤winSize 即截断)──► 层 L
   每层:坐标 x_L=prevPt/2^L;层间 nextPt_L = 2×nextPt_{L+1}(lkpyramid.cpp:211-222)
   层内循环(≤30 次,夹 [0,100]):
     prev 侧一次提取 IWinBuf+derivIWinBuf,累加结构张量 A11/A12/A22(:295-494)
     J 侧每轮只重算双线性 diff(:663-668)
     Δ=A⁻¹b → nextPt+=Δ → Δ·Δ≤ε² ? 退(:694)
     Δn≈-Δn₋₁(振荡)→ 回退半步再退(:697-702)
   层 0:status 判废 = minEig<threshold(:503-508);err 默认=窗口平均|diff|(:742)
```

纠偏:**maxLevel 只是上限**——降采样后尺寸 ≤winSize 立即截断并返回实际层数(lkpyramid.cpp:832-837),用户自带金字塔也被钳制(:1347-1348);默认 ε=0.01 在入口被**平方**(:1393),实际终止条件是位移模长 ≤0.1 像素。

## 9.1 LK 的工程细节:定点数与振荡保护

整条路径 W_BITS=14 定点化:导数与灰度按 2^14 定标,int16/int32 SIMD 累加,FLT_SCALE=1/2^20(lkpyramid.cpp:191-192);导数用 Scharr([-3,0,3;-10,0,10;-3,0,3])每层现场算(主流程建金字塔时 withDerivatives=false,:1380-1413)。窗口提取一次、复用整轮迭代——只有 J 侧 diff 重算。振荡保护:相邻增量反号且和<0.01 时回退半步退出(:697-702)。OpenCL 分支带严格参数闸门:winSize∈[8,24]、iters≤100、GET_MIN_EIGENVALS 直接拒走(:893-909, 1055-1056);OpenVX 分支被硬编码禁用("Disabled due to bad accuracy",:1271-1273)。附带:旧 estimateRigidTransform 也住在本文件尾部,缩到 ≤160×120 铺网格点跑 LK(:1443-1558)。

## 9.2 Farnebäck:多项式展开到代码

纠偏:文件名是 **optflowgf.cpp**("gf"=Gunnar Farnebäck),不是 optflow_farneback.cpp。论文到代码的映射(optflowgf.cpp):①G 平滑——每层 σ=(1/scale−1)×0.5 高斯后 resize,抵消 pyrDown 过度模糊(:1141-1143);②多项式展开——每像素拟合二次曲面输出 5 通道系数(跳过常数项),6×6 矩阵的逆只有 4 个标量参与(:193-198);③位移估计——用当前流采 R1 构造逐像素 5 通道线性系统,图像四周 5 像素衰减置信度(:259-308);④聚合迭代——numIters 轮把 M 盒滤波/高斯滤波后解 2×2 方程,分母加 1e-3 防零(:391-394)。金字塔按 min_size=32 截断;最后一轮不更新 M(省一次全图遍历,:1180-1186)。

## 9.3 变分精化:Brox2004,不是 TV-L1

纠偏:`VariationalRefinement` 的能量是 δΨ(E_I)+γΨ(E_G)+αΨ(E_S)(颜色常性+梯度常性+平滑,tracking.hpp:542-552),文档明确引用 **Brox2004**;主仓库 grep 不到任何 DualTVL1 符号——TV-L1 在 opencv_contrib。它也不是 Farnebäck 的附属:**真正的内置消费者是 DIS 光流**,每层精化 `VariationalRefinement::create()` 后 calcUV(dis_flow.cpp:139, 1496-1497)。求解:外层 5 次定点迭代×内层 5 次 Red-Black SOR,棋盘式数据布局自述利于 SIMD 与并行(variational_refinement.cpp:83-88, 1109-1110, 1164-1194)。

## 9.4 MOG2:自适应分量数是硬机制

纠偏:MOG2 在 **bgfg_gaussmix2.cpp**。每像素 K 组 (w,μ,σ²) 扁平数组,默认 history=500/varThreshold=16(4σ²)/K=5(:106-118)。学习率缺省 `1/min(2·nframes, history)`(:900);**复杂度先验 fCT=0.05 直接化为每帧权重衰减 prune=−learningRate×fCT**(:910),权重 w<−prune 的分量即被剪除(:701-705)——Zivkovic 的"自适应分量数"就是这一行衰减。命中分量做 EM 式在线更新:μ←μ−k·d、σ²←σ²+k·(dist2−σ²) 并夹到 [varMin=4,varMax=75],再按权重冒泡上浮(:666-694);无匹配且 αT>0 时替换最弱分量(:726-746)。

## 9.5 设计动机

1. **定点数 LK**:2^14 定标+整数 SIMD,精度换吞吐,窗口提取一次复用(lkpyramid.cpp:191-192);
2. **层数自适应**:小图自动降层数,小窗口上不浪费迭代(:832-837);
3. **多项式展开的迭代结构**:金字塔粗到细,每层只解 2×2 系统,矩阵增量更新摊薄成本(optflowgf.cpp:322);
4. **变分精化独立成类**:既服务 DIS 也独立可用,能量三权分立可调(tracking.hpp:542-552);
5. **MOG2 衰减即剪枝**:不维护显式分量数,权重自然收敛到"有用的 K"(bgfg_gaussmix2.cpp:910);
6. **OpenCL 严格闸门**:参数不符直接回 CPU,保正确性优先于加速(lkpyramid.cpp:893-909)。

## 9.6 FAQ

**Q1:maxLevel=3 一定用 3 层吗?**
不一定,小图会提前截断,实际层数是返回值(lkpyramid.cpp:832-837)。

**Q2:TermCriteria 0.01 是什么单位?**
入口被平方,比较的是 Δ·Δ≤ε²,即 0.1 像素位移(:1393, 694)。

**Q3:err 输出的是什么?**
默认窗口内平均绝对差;加 OPTFLOW_LK_GET_MIN_EIGENVALS 改输出结构张量最小特征值(:742, 500-501)。

**Q4:Farnebäck 的 Gaussian flag 干什么?**
把盒滤波聚合换成 σ=winSize×0.3 的高斯聚合(:407-577)。

**Q5:TV-L1 在主仓库吗?**
不在,主仓库是 Brox2004 式变分精化;TV-L1 在 contrib(variational_refinement.cpp)。

**Q6:MOG2 怎么"自动"定分量数?**
fCT 先验化成每帧权重衰减,权重过低即剪除(bgfg_gaussmix2.cpp:910, 701-705)。

**Q7:阴影判定怎么实现?**
τ=0.5 亮度比检验,命中标 127(:43-64, shadow=127)。

**Q8:LK 点在图边怎么办?**
补边恰为 winSize,窗口出界读落在补边上,点本身在图内即可(:788)。

**Q9:OpenCL 版限制?**
winSize∈[8,24]、iters≤100、polyN∈{5,7} 等,不符回 CPU(lkpyramid.cpp:893-909)。

**Q10:estimateRigidTransform 在哪?**
就住在 lkpyramid.cpp 尾部,铺网格跑 LK(:1443-1558)。

## 9.7 小结与深挖方向

本章结论:**video=定点数金字塔 LK+多项式展开稠密流+Brox 变分精化+衰减式 MOG2,全部 CPU SIMD 主体**。深挖:

1. umax/Scharr 定点卷积的 v_dotprod 4 像素分组(lkpyramid.cpp:305-374);
2. DIS 光流的 densification 与变分精化的逐层组合(dis_flow.cpp:1496);
3. KNN 背景建模(bgfg_KNN.cpp)与 MOG2 的收敛速度对比;
4. Kalman 5 矩阵 predict/correct 的数值稳定性(kalman.cpp);
5. CamShift 窗口扩张的终止条件(camshift.cpp)。
