# 报告 B2 · calib3d 标定与三维几何(OpenCV 卷二)

> 基线:d3d247f1(4.13.0-dev,gitee 镜像)。一句话:calib3d 把"针孔投影 + 14 维畸变向量"做成全模块共享的单点公式(projectPoints),再以 CvLevMarq 阻尼最小二乘为引擎闭环出 calibrateCamera/stereoCalibrate,以 ptsetreg 经典 RANSAC 与 usac/ 现代 RANSAC 双轨估计单应/本质/位姿——其中 DLS/UPnP 已在源码层标记破损并静默回退 EPnP。

## 1. 模块地图与本 commit 纠偏点

`modules/calib3d/src/` 共 45 个文件;本报告核实的核心分布(以 grep 定位):

- 畸变/投影公式:`calibration_base.cpp:507`(`cv::projectPoints`,不在 calibration.cpp!);`undistort.dispatch.cpp:336`(`cvUndistortPointsInternal`)、`:287`(`cv::undistort` 整图去畸变,分条带 remap)。
- 标定:`calibration.cpp:61`(`initIntrinsicParams2D`,旧名 `cvInitIntrinsicCamera2DParams` 已不存在)、`:166`(`calibrateCameraInternal`)、`:1309+`(公开重载)、`:1653`(`stereoCalibrateImpl`)。
- LM:`compat_ptsetreg.cpp:55-323`(CvLevMarq 全部实现);`levmarq.cpp:80` 是另一代 `cv::LMSolver`。
- 点集回归:`ptsetreg.cpp`(经典 RANSAC/LMeDS);`fundam.cpp`(单应/基本);`five-point.cpp`(本质)。
- PnP:`solvepnp.cpp` 分派;`epnp/p3p/ap3p/ippe/sqpnp/dls/upnp*.cpp` 为各求解器;`usac/` 14 个 .cpp 共 9077 行。
- 立体:`stereo_geom.cpp`(不是 calibration3d.cpp)。

**纠偏(≥3 条,以本 commit 为准):**
1. `projectPoints` 与 `undistort` 不在 calibration.cpp,而在 `calibration_base.cpp:507` 与 `undistort.dispatch.cpp:287`;calibration.cpp 只剩标定流程。
2. `cvLevMarq` 的实现文件是 `compat_ptsetreg.cpp:55-323`(历史上从 ptsetreg.cpp 拆出),既不是 lmmin 也不是 levmarq.cpp;`levmarq.cpp:46-47` 注明其 LMSolver 移植自 Matlab LMSolve 包,`solvePnPRefineLM` 用的是 LMSolver(`solvepnp.cpp:757`),`calibrateCamera` 用的是 CvLevMarq(`calibration.cpp:337`)——两代 LM 并存且分工不同。
3. `SOLVEPNP_DLS/UPNP` 不再调用 dls.cpp/upnp.cpp:`solvepnp.cpp:864-873` 打日志 "Broken implementation ... Fallback to EPnP" 后直接构造 `epnp`;头文件 `calib3d.hpp:569,571` 已写明 "will fallback to EPnP"。dls.cpp/upnp.cpp 仍在仓库但全仓库无 include(未发现调用点)。
4. findHomography 不是"RANSAC/LMEDS 两种":实际 4 分支(0/RANSAC/LMEDS/RHO,`fundam.cpp:401-411`)加 USAC_* 转发(`fundam.cpp:363-365`)。
5. 畸变"5/8/12/14 参数分支"不是公式级 if-else:正向投影始终按 14 维 `k[14]` 零填充数组算一套公式(`calibration_base.cpp:519,801-804`),分支只存在于 HAL fast-path 的 `switch(ktotal)`(`calibration_base.cpp:670-690`)与入参长度断言(`calibration_base.cpp:504-509`,枚举 4/5/8/12/14)。

## 2. projectPoints 与 undistort:同一畸变公式的双向路径

正向投影核心循环(`calibration_base.cpp:778-813`),先旋转平移、归一化,再一次性套入径向+切向+薄棱镜+倾斜(tilt)全部项:

```cpp
// calibration_base.cpp:795-813
r2 = x*x + y*y; r4 = r2*r2; r6 = r4*r2;
a1 = 2*x*y; a2 = r2 + 2*x*x; a3 = r2 + 2*y*y;
cdist   = 1 + k[0]*r2 + k[1]*r4 + k[4]*r6;          // k1,k2,k3
icdist2 = 1./(1 + k[5]*r2 + k[6]*r4 + k[7]*r6);     // k4,k5,k6(有理模型分母)
xd0 = x*cdist*icdist2 + k[2]*a1 + k[3]*a2 + k[8]*r2 + k[9]*r4;   // p1,p2,s1,s2
yd0 = y*cdist*icdist2 + k[2]*a3 + k[3]*a1 + k[10]*r2 + k[11]*r4; // s3,s4
vecTilt = matTilt*Vec3d(xd0, yd0, 1);                // tau_x,tau_y 倾斜传感器
invProj = vecTilt(2) ? 1./vecTilt(2) : 1;
m[i].x = invProj*vecTilt(0)*fx + cx;  m[i].y = invProj*vecTilt(1)*fy + cy;
```

参数语义由 HAL 结构注释固定:4=[k1,k2,p1,p2]、5=+k3、8=+k4..k6、12=+s1..s4、14=+tau_x,tau_y(`calibration_base.cpp:672-687`)。雅可比 dpdk/dpdf/dpdc 解析计算,tilt 的导数经 `dMatTilt`(843-845);纯 32f/64f 输入走 `CALL_HAL(projectPoints, cv_hal_project_points_pinhole…)`(710, 766)。

逆向 `cvUndistortPointsInternal`(`undistort.dispatch.cpp:336`)先归一化(430-432),tilt 项用 `invMatTilt`(376, 442-445)精确求逆,径向部分无闭式解,做定点迭代:

```cpp
// undistort.dispatch.cpp:457-476(有删节)
double r2 = x*x + y*y;
double icdist = (1 + ((k[7]*r2 + k[6])*r2 + k[5])*r2)
              / (1 + ((k[4]*r2 + k[1])*r2 + k[0])*r2);
if (icdist < 0) { x = (u-cx)*ifx; y = (v-cy)*ify; break; }  // :460 回退(回归14583)
double deltaX = 2*k[2]*x*y + k[3]*(r2+2*x*x) + k[8]*r2 + k[9]*r2*r2;
double deltaY = k[2]*(r2+2*y*y) + 2*k[3]*x*y + k[10]*r2 + k[11]*r2*r2;
x = (x0 - deltaX)*icdist;   y = (y0 - deltaY)*icdist;        // 定点迭代
```

迭代终止由 `TermCriteria` 控制:默认 `TermCriteria(MAX_ITER,5,0.01)`(`undistort.dispatch.cpp:549`),即默认只迭代 5 次(0.01 需设 EPS 才参与比较,454)。EPS 分支会真正把畸变点投回图像算像素误差(478-514)。之后可再复合 R、P(`undistort.dispatch.cpp:519-526`),这正是 `initUndistortRectifyMap`(`:86`)生成校正映射的基础。

整图 `cv::undistort`(`undistort.dispatch.cpp:287`)并不逐像素调上面的函数,而是现算映射再 remap,并按 `stripe_size0 = min(max(1, 4096/cols), rows)` 分条带控内存(`undistort.dispatch.cpp:300, 320-322`);映射类型 CV_16SC2+CV_16UC1 的定点+余数表示(:301)。也就是说:**去畸变点 API 走迭代解,整图走查表**,两条路径只在 initUndistortRectifyMap 处汇合(其内部生成 map,:86-285)。

## 3. calibrateCamera 主流程与优化闭环

`calibrateCameraRO → calibrateCameraInternal`(`calibration.cpp:1350→166`)四步:

1. **入参整形**(`calibration.cpp:220-221, 271-282`):畸变长度必须 ∈{4,5,8,12,14};不足 8 自动 `CALIB_FIX_K3|K4|K5|K6`(277-282)。参数向量布局 `[fx fy cx cy | k0..k13 | 每视图 (rvec,tvec)×6 | releaseObject 物点×3]`,`nparams = NINTRINSIC(18) + nimages*6`(:271;`CALIB_NINTRINSIC=18` 见 `calib3d.hpp:605`)。
2. **初值**(`calibration.cpp:316-334`):非平面标定架(z 有均值/方差)强制要求 `CALIB_USE_INTRINSIC_GUESS`(:320-322),否则压平 z=0 后调 `initIntrinsicParams2D`(:334);每视图 `findHomography` 求 H(:93),H 的两列构成消失点线性方程 `A f = b`(:121-124),`solve(DECOMP_NORMAL+DECOMP_SVD)` 后 `fx=sqrt(|1/f0|), fy=sqrt(|1/f1|)`(:128-130),cx/cy 取 `(width-1)/2`(:80-81)。外参初值逐视图 `findExtrinsicCameraParams2`(:417-431)。
3. **迭代优化**(`calibration.cpp:337, 442-578`):`CvLevMarq solver(nparams,0,criteria)`,公开 API 默认 `TermCriteria(COUNT+EPS, 30, DBL_EPSILON)`(`calib3d.hpp:1732-1733`);`CALIB_USE_LU/QR` 改 `solver.solveMethod`(:339-344)。
4. **输出**(`calibration.cpp:580-621`):重投影误差 `sqrt(reprojErr/total)`(:621),每视图误差 `sqrt(viewErr/ni)`(:546);若请求 stdDeviations,用 `JtJ⁻(对角)×σ²` 估计,σ² 分母做 HZ 5.1.3 自由度校正 `nErrors = 2*total - nparams_nz`(:556-574,PR#22992)。

初值估计的核心摘录(每视图两个方程,来自 H 的两个"旋转"列):

```cpp
// calibration.cpp:92-98, 121-130
Mat matH0 = findHomography(matM, _m);          // 每视图单应
H(0,0) -= H(2,0)*cx; H(0,1) -= H(2,1)*cx; …    // 抵消主点
for(int j = 0; j < 3; j++) {                   // h,v = H 的两列, d1,d2 = 其和/差
    h[j]=H(j,0); v[j]=H(j,1); d1[j]=(t0+t1)*0.5; d2[j]=(t0-t1)*0.5; }
matA(i*2+0,0) = h[0]*v[0]; matA(i*2+0,1) = h[1]*v[1];   // h·v 的两分量方程
matA(i*2+1,0) = d1[0]*d2[0]; matA(i*2+1,1) = d1[1]*d2[1];
solve(matA, matb, f, DECOMP_NORMAL + DECOMP_SVD);
fx = std::sqrt(fabs(1./f[0]));  fy = std::sqrt(fabs(1./f[1]));
```

进入优化前还有一个防御:自由参数数不得 ≥ 2×总点数,否则 `CV_Error("There should be less vars to optimize …")`(`calibration.cpp:412-414`)。

主循环中雅可比按块手工稀疏组装(`calibration.cpp:509-541`),注释直接引 HZ (A6.14):

```cpp
// calibration.cpp:526-537(calcJ 时,Ji=内参雅可比, Je=外参雅可比)
JtJ(Rect(0,0,NINTRINSIC,NINTRINSIC)) += Ji.t()*Ji;   // 内参×内参:跨视图累加
JtJ(Rect(si,si,6,6)) = Je.t()*Je;                    // 本视图外参块(块对角)
JtJ(Rect(si,0,6,NINTRINSIC)) = Ji.t()*Je;            // 交叉块
JtErr.rowRange(0,NINTRINSIC) += Ji.t()*err;
JtErr.rowRange(si,si+6) = Je.t()*err;
```

标定优化闭环(ASCII):

```text
 objectPoints/imagePoints (N 视图)
        │ z≠0? ── 是 → 必须 CALIB_USE_INTRINSIC_GUESS (:320)
        ▼
 initIntrinsicParams2D: 每视图 H → 消失点方程 → fx,fy (calib.cpp:61-140)
        │                        findExtrinsicCameraParams2 → 每视图 r,t (:417)
        ▼
 ┌─► CvLevMarq::updateAlt (:449)   param[18+6N]
 │      │ state=CALC_J: projectPoints 出残差+Ji/Je (calib_base:507)
 │      │              JtJ/JtErr 块状组装 (calib.cpp:526-541)
 │      ▼ state=CHECK_ERR: reprojErr=Σ‖err‖² (:544-552)
 │      errNorm↑? ── 是 → lambdaLg10++ 重新 step (最多 +16)
 │      │ 否         ← lambdaLg10--
 │      ▼
 └── iters<30 且 Δparam≥DBL_EPSILON ? ── 是 → 回 CALC_J
         │ 否(DONE)
         ▼
 cameraMatrix / distCoeffs / rvecs,tvecs / RMS=sqrt(reprojErr/total) (:621)
```

### 3.1 引擎解剖:CvLevMarq 状态机

状态机四态 `DONE=0, STARTED=1, CALC_J=2, CHECK_ERR=3`(`calib3d_c.h:127`)。`updateAlt`(`compat_ptsetreg.cpp:192-259`)每轮:CALC_J 时复制参数→`step()` 走一步;CHECK_ERR 时若 `errNorm > prevErrNorm` 则 `++lambdaLg10`(≤16)原地重试(:227-238),否则 `lambdaLg10 = MAX(lambdaLg10-1, -16)` 放宽并前进(:240-249),收敛条件 `iters≥max_iter ‖ CV_RELATIVE_L2(param) < epsilon`(:241-242)。

```cpp
// compat_ptsetreg.cpp:289-322(CvLevMarq::step)
double lambda = exp(lambdaLg10*LOG10);       // 阻尼以 log10 整数存储
subMatrix(JtJ, _JtJN, mask, mask);  subMatrix(JtErr, _JtErr, …); // 固定参数剪枝
completeSymm(_JtJN, completeSymmFlag);
_JtJN.diag() *= 1. + lambda;                 // 阻尼加在对角元上
solve(_JtJN, _JtErr, nonzero_param, solveMethod);   // LU/QR 可选
param[i] = prevParam[i] - (mask[i] ? nonzero_param(j++) : 0);
```

注意三点:阻尼乘在 `diag(JtJ)` 上而非加 λI(:317);λ 用 `lambdaLg10` 整数表示、步进只做 ±10 的幂(:140 定义,:162-173 增减),回避浮点漂移;`update`(老 API,:121-189)与 `updateAlt` 逻辑同构,区别是 alt 版由调用方直接累积 JtJ,省去 N×params 大 J 矩阵——calibrateCamera 正因此手写块组装(第 3 节)。而新一代 `LMSolverImpl`(`levmarq.cpp:80-196`)用比值增益 R∈[0.25,0.75] 调 λ(:113, 140-162),解法固定 `DECOMP_EIG`(:130),服务于 solvePnPRefineLM(`solvepnp.cpp:757`)与 findHomography 精修(`fundam.cpp:433`)。

## 4. fundam.cpp:单应/基本/本质的估计器谱系

`cv::findHomography`(`fundam.cpp:357`)先查 USAC 区间(`method >= USAC_DEFAULT && <= USAC_MAGSAC` → `usac::findHomography`,:363-365;USAC_DEFAULT=32…USAC_MAGSAC=38,`calib3d.hpp:554-560`),否则四分支(:401-411):`method==0` 或恰 4 点直接 `runKernel` 解 DLT;RANSAC/LMEDS 经 `createRANSACPointSetRegistrator/createLMeDSPointSetRegistrator`(模型点数 4);RHO 走 `createAndRunRHORegistrator`(:280-355,外部 RHO_HEST,注释自认"输出单精度 H"是代价,:294;beta=0.35 :292)。默认阈值 3 px(:367,396)、confidence=0.995(`calib3d.hpp:844`)。RANSAC/LMEDS 成功后用内点重解 + LMSolver 精修 10 步(:415-434),RHO 不精修(:415 `method != RHO`)。

经典 RANSAC 本体在 `ptsetreg.cpp`:`RANSACUpdateNumIters` 实现标准公式 log(1-p)/log(1-(1-ε)^s) 动态缩短迭代(:55-75);`getSubset` 最多 10000 次重抽避免退化样本(:208);内点判定是残差平方 ≤ thresh²(:93-97);每轮好内点数更新 `niters`(:233);先找 bestModel,再跑零次迭代的确认循环重拟合(:186 附近)。LMeDS 按中位残差估 σ(:309-358)。

`cv::findFundamentalMat`(`fundam.cpp:852`)同样接 USAC(:859)或经典轨道,注意其模型点数是 **7** 而非 8(`fundam.cpp:910`,7 点法给 1-3 个 F 解,`FMEstimatorCallback` 定义于 :792-801),LMEDS 同(:912)。单应估计器 `HomographyEstimatorCallback` 在 :71,其 `runKernel`(:125)做归一化 DLT;旧 C API `cvFindHomography` 在整个 modules/ 下已无残留(grep 全量验证)。

`cv::findEssentialMat`(`five-point.cpp:442`)先按 K 归一化坐标(:474-477)、阈值除以平均焦距(:483),再以 5 点模型进同一 RANSAC(:487-489);其核即 Nister 五点法 `EMEstimatorCallback::runKernel`(:49-108):构造 9×n 的 Q 矩阵(:56-65)、SVD 取零空间 4 个解(:67-70)、展开为 10×20 系数矩阵消元得 x³y³ 十次多项式(:71-108,系数硬编码展开)。含畸变重载会先 `undistortPoints`(:519-531)。USAC 重载 `findEssentialMat(..., UsacParams)` 走 `usac::run`(:533-541)。

## 5. solvePnP 分派与 usac/ 的地位

`solvePnP`(:132-150)是 `solvePnPGeneric`(:825)的"取第一解"包装;分派完全按 flags 线性 if-else:

```text
solvePnPGeneric (solvepnp.cpp:825)
 ├ npoints 断言: ≥4;ITERATIVE+guess 可 3;SQPNP 可 ≥3 (:835-837)
 ├ EPNP / DLS / UPNP (:864-885)  → DLS/UPNP 打"Broken"日志,全部
 │      undistortPoints → epnp::compute_pose (:876-881)   [dls.cpp 未被调用]
 ├ P3P / AP3P (:886-892) → solveP3P (:427): p3p.estimate (:456) /
 │      ap3p.solve (:460),去畸变后 3 点解多解输出
 ├ ITERATIVE (:893-911) → findExtrinsicCameraParams2 (:907),即标定同款 LM,
 │      useExtrinsicGuess 时用传入 rvec/tvec 作初值
 ├ IPPE (:912-943) → 要求共面(DbgAssert isPlanarObjectPoints 1e-3, :914,
 │      实现 :59),IPPE::PoseSolver::solveGeneric 返回两解按重投影误差排序 (:925-940)
 ├ IPPE_SQUARE (:944, 恰 4 点特例) / SQPNP (:1016-1021, sqpnp::PoseSolver)
 └ else CV_Error (:1050-1052)
```

方法枚举 `SOLVEPNP_ITERATIVE=0 … SQPNP=8`(`calib3d.hpp:564-583`)。`solvePnPRansac`(:214)同样先查 USAC(:222-224),经典路径的 RANSAC 核选择有一处少有人注意的逻辑(`solvepnp.cpp:254-274`):

```cpp
// solvepnp.cpp:254-271(节选)
int model_points = 5;                         // 默认用 EPnP
int ransac_kernel_method = SOLVEPNP_EPNP;
if( flags == SOLVEPNP_P3P || flags == SOLVEPNP_AP3P) { model_points = 4; … }
else if( npoints == 4 ) { model_points = 4; ransac_kernel_method = SOLVEPNP_P3P; }
if( model_points == npoints )   // 点数恰好等于最小样本:跳过 RANSAC 直接解
    solvePnP(opoints, ipoints, …, ransac_kernel_method);
```

即恰好 4 点时不跑 RANSAC、直接转 P3P;RANSAC 结束后再用内点重解一次,并把 P3P/AP3P 统一换成 EPnP(:337-355)。

`usac/`(14 个 .cpp,9077 行)是 2019 年 Google Summer of Code 落地的统一框架:`usac.hpp:943-970` 暴露 findHomography/findFundamentalMat/findEssentialMat/solvePnPRansac 四个入口与 `setParameters`;`ransac_solvers.cpp:608` 的 `Ransac::run` 内联了 采样→估计多解→质量评分→模型验证→终止条件更新→局部优化(LO#0/#1)→SPRT 退化检验 的完整流水(`local_optimization.cpp`、`degeneracy.cpp` 各司其职);PnP 末端还要把 R 重算投影矩阵再复核内点(`ransac_solvers.cpp:1441-1466`)。地位总结:**flags 32-38 才进 usac;传统 0/8/16/24 路径与 ptsetreg 经典 RANSAC 仍是默认**,两轨并存。

## 6. 立体:stereoRectify 与 reprojectImageTo3D

`cv::stereoRectify`(`stereo_geom.cpp:116-325`,实文件 stereo_geom.cpp,"calibration3d.cpp" 不存在)。数学分三步:①两相机旋转平均 `om*=-0.5 → r_r`,使新旧姿态各转一半(:135-137);②构造绕基线的全局 Z 旋转 `ww = t×uu`,角度 `acos(|c|/nt)`,使光轴与基线平面正交(:139-151),`R1=wR·r_rᵀ, R2=wR·r_r`(:153-158);③新内参:令 fy=fx(行对齐约束,注释 :207-209),用四角点去畸变再投影取均值求新 cc(:180-205),`CALIB_ZERO_DISPARITY` 时两 cc 取均值否则按水平/垂直立体各取一维均值(:213-221);`P2[idx][3]=t_idx*fc_new` 即 baseline×focal(:234);alpha∈[0,1] 在内/外接矩形间插值缩放(:255-274)。Q 矩阵显式写死(:312-324):

```cpp
// stereo_geom.cpp:314-321
double q[] = { 1,0,0, -cc_new[0].x,
               0,1,0, -cc_new[0].y,
               0,0,0,  fc_new,
               0,0, -1./t_idx, (cc_new[0].x-cc_new[1].x)/t_idx };
```

`reprojectImageTo3D`(`stereo_geom.cpp:9-114`)逐像素做一次 4×4 齐次乘法:

```cpp
// stereo_geom.cpp:88-94
double d = sptr[x];
Vec4d homg_pt = _Q*Vec4d(x, y, d, 1.0);
dptr[x] = Vec3d(homg_pt.val);
dptr[x] /= homg_pt[3];
if( fabs(d-minDisparity) <= FLT_EPSILON )
    dptr[x][2] = bigZ;                    // bigZ=10000, 无效视差占位
```

`handleMissingValues` 时先用 `minMaxIdx` 找全图最小视差作为"无效"标记(:50-55)。鱼眼是独立命名空间 `cv::fisheye`(等距模型),`fisheye::stereoRectify` 在 `fisheye.cpp:632`,与主针孔路径不共享代码。另有 `stereoRectifyUncalibrated`(`stereo_geom.cpp:333`,由 F 直接求两个单应 H1/H2,不走内参)。

## 7. 写作素材:设计动机、FAQ 与深挖方向

### 7.1 设计动机清单(≥5)

1. **单一公式单点维护**:整个模块的正向投影只有 calibration_base.cpp:778-813 一份,标定/PnP/RANSAC 评分/solvePnPRansac 误差全部复用它,保证"标什么就是什么"。
2. **参数打包 + mask**:18 内参 + 6N 外参压成一个向量,`mask` 表达 CALIB_FIX_* 的全部组合,LM 只见向量不见语义(:350-388)。
3. **稀疏 JtJ 手工组装**:标定问题的 Hessian 天然块状(HZ A6.14),updateAlt 把组装权交给调用方,避免 O(N·P) 大 J(compat_ptsetreg.cpp:192;calibration.cpp:526-541)。
4. **log 域整数阻尼**:λ 只取 10 的幂(lambdaLg10),失败 ×10、成功 ÷10,上下界 ±16,实现极简且数值稳健(compat_ptsetreg.cpp:162-173)。
5. **消失点线性初值**:平面标定的 fx/fy 无需非线性搜索,每视图 H 两列给 2 方程,全体视图联立最小二乘(calibration.cpp:121-130),这也是 findHomography 被 calibrateCamera 依赖的原因。
6. **双 RANSAC 轨道**:经典 ptsetreg(可预测、依赖少)与 usac(可组合 FAST/ACCURATE/PROSAC/MAGSAC,含 LO 与 SPRT)并存,新方法经 flag 32-38 渐进迁移,不破坏旧 API。
7. **HAL 加速口**:pinhole 投影在 32f/64f 时走 cv_hal_project_points_pinhole,IP 层可替换实现(calibration_base.cpp:657-769)。
8. **校正数学显式化**:stereoRectify 把"平均旋转 + 绕基线旋转 + 共享焦距"三步全展开为矩阵运算,注释直接说明每个约束的几何原因(stereo_geom.cpp:135-234)。

### 7.2 FAQ 候选(每条一句话答案)

1. calibrateCamera 什么时候必须给 `CALIB_USE_INTRINSIC_GUESS`?——objectPoints 的 z 有变化(非平面标定架)时,`calibration.cpp:320-322` 直接报错要求初值。
2. `undistortPoints` 默认迭代几次?——默认 `TermCriteria(MAX_ITER,5,0.01)` 且未设 EPS 位,即固定 5 次定点迭代(undistort.dispatch.cpp:549,452-455)。
3. SOLVEPNP_DLS 现在还算数吗?——不算,运行时打 DEBUG 日志后回退 EPnP(solvepnp.cpp:866-869),头文件亦标注破损(calib3d.hpp:569)。
4. findHomography 的 RHO 与 RANSAC 差在哪?——RHO 是独立 C 实现(rhoInit/rhoHest),只出单精度 H 且不做末次 LMSolver 精修(fundam.cpp:294,415)。
5. calibrateCamera 返回值单位是什么?——总 RMS 重投影误差(像素),`sqrt(Σ‖err‖²/总点数)`,每点残差 2 维(calibration.cpp:621)。
6. 参数标准差是怎么来的?——收敛后取 `JtJ⁻` 对角 × σ² 开方,σ² 的自由度用 `2*total - nparams_nz` 校正(calibration.cpp:556-574)。
7. solvePnP ITERATIVE 内部是什么?——与标定共用 `findExtrinsicCameraParams2`(LM 迭代),非闭式解(solvepnp.cpp:907)。
8. stereoRectify 为什么把 fy 强制等于 fx?——水平极线要求两图 y 方向尺度一致,注释明言"keep the epipolar constraint"(stereo_geom.cpp:207-209)。
9. Q 矩阵里 `-1/Tx` 是什么?——视差 d 与 Z 的倒数关系 Z = f·Tx/(cx2-cx1-d) 的系数,存于 Q 第三行(stereo_geom.cpp:319)。
10. USAC 怎么启用?——把 method 传成 `USAC_DEFAULT(32)…USAC_MAGSAC(38)` 即整体转发 usac::*,传统 flags(0/8/16/24)不受影响(fundam.cpp:363;calib3d.hpp:554-560)。

### 7.3 深挖方向(5 条)

1. `undistort.dispatch.cpp:86-285` 的 `initUndistortRectifyMap`:定点化/插值表生成与 CV_CPU_DISPATCH 派发机制,及 `cv::undistort` 分条带 remap 的内存策略(:287-340)。
2. `usac/ransac_solvers.cpp:608-940` 的 USAC 主循环:SPRT 预验(`sprt.cpp` 部分)、LO#0/#1 触发条件、PROSAC 排序采样与 MAGSAC++ 的 `gamma_values.cpp` 边际化积分表。
3. IPPE 两解次序与简并:`ippe.cpp:45,173` solveGeneric/solveSquare,以及 `solvepnp.cpp:925-940` 排序在重投影误差几乎相等时的稳定性问题。
4. `calibrateCameraRO` 的 releaseObject:物点也进参数向量的雅可比块 Jo(calibration.cpp:390-405, 529-534),哪些标定架值得释放物点。
5. 其余标定路径:`stereoCalibrateImpl`(calibration.cpp:1653)联合优化双相机、`homography_decomp.cpp` 的 H→R|t 分解、以及 `fisheye.cpp` 独立等距模型(其自有 stereoRectify 在 :632)为何不并入主畸变框架。

## 8. 正文蒸馏要点

1. `cv::projectPoints` 在 `calibration_base.cpp:507`(非 calibration.cpp),畸变公式集中于 `calibration_base.cpp:795-813`(cdist/k1-k3、icdist2/k4-k6、切向 p1p2、薄棱镜 s1-s4、tilt tau 一套写完);系数只允许 4/5/8/12/14 个(`:504-509`),分支语义表在 `:672-687`,正向投影恒按 14 维零填充数组计算,无独立公式分支。
2. `undistortPoints` 逆映射是定点迭代,默认 5 次(`undistort.dispatch.cpp:549`),`icdist<0` 直接放弃并回退归一化坐标(`:460-465`),tilt 用解析逆 `invMatTilt`(`:376,442-445`);整图 `cv::undistort` 走分条带查表 remap(`:287,300-322`)。
4. 初值估计 `initIntrinsicParams2D`(`calibration.cpp:61-140`):每视图 findHomography→H 两列构成消失点方程(:121-124),SVD 最小二乘解 fx/fy(:128-130);非平面标定架必须给初值(`:320-322`)。
5. calibrateCameraInternal(`calibration.cpp:166-622`)参数向量 = 18 内参 + 6N 外参(+释放物点 3P,`:271-273`),`CALIB_NINTRINSIC=18`(`calib3d.hpp:605`)。
6. 优化引擎 `CvLevMarq` 实现在 `compat_ptsetreg.cpp:55-323`(不在 levmarq.cpp),阻尼是 `diag(JtJ)*(1+λ)`、λ 以 `lambdaLg10` 整数 ±10 的幂伸缩(`:317,162-173`),状态机 DONE/STARTED/CALC_J/CHECK_ERR(`calib3d_c.h:127`)。
7. calibrateCamera 默认终止 `TermCriteria(COUNT+EPS,30,DBL_EPSILON)`(`calib3d.hpp:1732-1733`);雅可比块状组装引用 HZ A6.14(`calibration.cpp:525-541`);返回 RMS=`sqrt(reprojErr/total)`(`:621`)。
8. 标准差输出用 `JtJ⁻` 对角 ×σ²,自由度校正 `2*total-nparams_nz`(`calibration.cpp:556-574`)。
9. findHomography 四分支 0/RANSAC/LMEDS/RHO(`fundam.cpp:401-411`)加 USAC 转发(`:363-365`);RANSAC/LMEDS 之后统一用 LMSolver 精修 10 步(`:433`),RHO 除外。
10. 经典 RANSAC 的动态迭代公式与实现:`RANSACUpdateNumIters`(`ptsetreg.cpp:55-75`),内点=残差平方≤thresh²(`:93-97`),每轮按内点率缩短 niters(`:233`)。
11. findEssentialMat(`five-point.cpp:442-492`)先归一化坐标并按焦距缩放阈值(:474-483),内核是 Nister 五点法(Q 矩阵 SVD + 10×20 消元,five-point.cpp:49-108)。
12. solvePnP 分派表中 DLS/UPNP 已破损回退 EPnP(`solvepnp.cpp:864-885`),ITERATIVE 走 findExtrinsicCameraParams2(:907),IPPE 双解按重投影误差排序(:925-940),SQPNP 调 sqpnp::PoseSolver(:1016-1021);usac/ 是 flags 32-38 的并行轨道(`usac.hpp:943-970`,PnP 末端复核内点 `ransac_solvers.cpp:1441-1466`)。
13. stereoRectify(`stereo_geom.cpp:116-325`)三板斧:平均旋转(:135-137)、绕基线 Z 旋转(:147-158)、fy=fx + baseline×focal 进 P2(:207-234);Q 矩阵硬编码于 `:314-321`,reprojectImageTo3D 逐像素 `Q·[x,y,d,1]ᵀ/w`(`:89-91`)。
