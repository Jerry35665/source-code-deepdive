# 第 08 章 · calib3d:一套畸变公式、两代 LM、双轨 RANSAC

> 基线:commit `d3d247f1`(4.13.0-dev)。核心:modules/calib3d/src/(calibration_base.cpp / calibration.cpp / compat_ptsetreg.cpp / fundam.cpp / solvepnp.cpp)。

## 8.0 全景:标定优化闭环

```
 objectPoints/imagePoints(N 视图)
   │ 非平面(z 有均值/方差)→ 必须 CALIB_USE_INTRINSIC_GUESS(calibration.cpp:320)
   ▼
 initIntrinsicParams2D:每视图 findHomography → H 两列=消失点线性方程
   → solve(SVD) → fx=sqrt(|1/f0|),fy=sqrt(|1/f1|),cx/cy=(w-1)/2(:61-140, 80-81)
   ▼
 ┌─► CvLevMarq::updateAlt(compat_ptsetreg.cpp:192-259,param[18+6N])
 │    CALC_J:projectPoints 出残差+雅可比 → JtJ/JtErr 块状组装(calibration.cpp:526-541)
 │    CHECK_ERR:errNorm 涨?→lambdaLg10++ 原地重试(≤+16);降?→lambdaLg10-- 前进
 └── iters<30 且 Δparam≥DBL_EPSILON?→ 继续
   ▼
 cameraMatrix/distCoeffs/r,t/RMS;标准差带 HZ 5.1.3 自由度校正(:556-574)
```

纠偏:projectPoints 不在 calibration.cpp 而在 **calibration_base.cpp:507**;cvLevMarq 实现在 **compat_ptsetreg.cpp:55-323**——levmarq.cpp 是另一代 `cv::LMSolver`(Matlab LMSolve 移植),solvePnPRefineLM 用后者、calibrateCamera 用前者,两代 LM 并存分工。

## 8.1 一套公式:14 维零填充

正向投影的核心循环(calibration_base.cpp:795-813):归一化坐标一次套入径向 k1-k6(k4-k6 是有理模型分母 icdist2)+切向 p1p2+薄棱镜 s1-s4+tilt 矩阵——**无论传入 4/5/8/12/14 个畸变系数,公式恒按 14 维 k[14] 零填充计算同一套式子**,分支只存在于入参断言与 HAL fast-path 的 switch(ktotal)(:504-509, 670-690)。逆向 `cvUndistortPointsInternal`(undistort.dispatch.cpp:336):tilt 项用 invMatTilt 精确求逆,径向无闭式解做定点迭代;**默认 TermCriteria(MAX_ITER,5,0.01) 实际只迭代 5 次**(EPS 需显式设置才参与比较,:454, 549);icdist<0 时回退回归 #14583(:460)。整图 undistort 不逐像素迭代,而是现算映射+remap 分条带(`4096/cols` 控内存,:300-322)——点 API 走迭代解,整图走查表。

## 8.2 CvLevMarq:整数幂阻尼状态机

四态状态机 DONE/STARTED/CALC_J/CHECK_ERR(calib3d_c.h:127)。特色:阻尼 λ 以整数 `lambdaLg10` 存储,只做 ±10 的幂伸缩(步长最多 ×10^16 / ÷10^16);且阻尼乘在 `diag(JtJ)*(1+λ)` 上而非教科书 +λI(compat_ptsetreg.cpp:317)。errNorm 涨则 ++lambdaLg10 原地重试、降则 -- 前进(:227-249),收敛 `iters≥max ‖ 相对误差<eps`;公开 API 默认 30 次迭代(calib3d.hpp:1732-1733)。calibrateCamera 的雅可比按块手工稀疏组装:内参块跨视图累加、外参块对角、交叉块单独(calibration.cpp:526-541,注释直接引 HZ A6.14)。防御:自由参数数 ≥ 2×总点数直接报错(:412-414)。

## 8.3 PnP:DLS/UPnP 已是死路径

`solvePnP` 分派(solvepnp.cpp):ITERATIVE(LM 精化)/EPnP/P3P/AP3P/IPPE/SQPNP;纠偏:**SOLVEPNP_DLS/UPNP 已破损**——:864-873 打日志 "Broken implementation ... Fallback to EPnP" 后直接构造 epnp,头文件 calib3d.hpp:569,571 已写明;dls.cpp/upnp.cpp 仍在仓库但全 modules/ 无调用点。按"仍是独立求解器"介绍 DLS 即错误。现代估计走 usac/ 目录(14 个 .cpp 共 9,077 行):RANSAC 家族的重写版,经 USAC_* flag 从 findHomography/findFundamentalMat 转发(fundam.cpp:363-365)。

## 8.4 findHomography 四分支与本质矩阵

findHomography 实际 4 分支(0/RANSAC/LMEDS/RHO,fundam.cpp:401-411)+USAC 转发;findFundamentalMat 用 7 点算法(fundam.cpp:910),本质矩阵走 five-point.cpp。经典 RANSAC 在 ptsetreg.cpp(与 CvLevMarq 同源历史),现代 USAC 在 usac/——**双轨并存**:老 API 稳定路径+新 flag 走新实现。

## 8.5 设计动机

1. **公式单点化**:投影/去畸变全模块共享 calibration_base 一处实现,HAL fast-path 只包同一公式(:795-813);
2. **两代 LM 分工**:CvLevMarq 服务大参数块标定(手工稀疏 JtJ),LMSolver 服务小问题精化——不动旧代码;
3. **整数幂阻尼**:λ 乘 10^±n 而非线性伸缩,数值稳定且状态可序列化(compat_ptsetreg.cpp:317);
4. **破损求解器显式降级**:DLS/UPnP 打日志回退 EPnP 而非删除 API——兼容优先、诚实标注(solvepnp.cpp:864-873);
5. **双轨 RANSAC**:ptsetreg 老路径与 usac 新实现并存,flag 渐进迁移;
6. **HZ 引用进注释**:雅可比块组装直接引 Hartley-Zisserman 公式编号,可对照教材复核(calibration.cpp:526-541)。

## 8.6 FAQ

**Q1:畸变传 5 个参数会走不同公式吗?**
不会,恒按 14 维零填充算同一套式子(calibration_base.cpp:519)。

**Q2:undistortPoints 默认迭代几次?**
5 次(MAX_ITER,5),EPS 需显式设置(undistort.dispatch.cpp:454, 549)。

**Q3:DLS 还能用吗?**
不能,已破损静默回退 EPnP(solvepnp.cpp:864-873)。

**Q4:cvLevMarq 和 LMSolver 什么关系?**
两代实现:标定用前者, solvePnPRefineLM 用后者(compat_ptsetreg.cpp:55; levmarq.cpp:46)。

**Q5:阻尼怎么调?**
lambdaLg10 整数幂:err 涨则 ++(重试),降则 --(compat_ptsetreg.cpp:227-249)。

**Q6:初值 fx/fy 怎么来的?**
每视图 H 两列构成消失点方程,SVD 解出 1/f²,fx=fy 时 (w-1)/2 当主点(calibration.cpp:92-130)。

**Q7:标准差可信吗?**
做了 HZ 5.1.3 自由度校正 nErrors=2*total-nparams_nz(calibration.cpp:556-574)。

**Q8:非平面标定架能直接标吗?**
必须 CALIB_USE_INTRINSIC_GUESS,否则压平 z=0(calibration.cpp:320-334)。

**Q9:USAC 怎么启用?**
findHomography 传 USAC_* flag,转发到 usac/ 新实现(fundam.cpp:363-365)。

**Q10:整图去畸变逐点迭代吗?**
不,现算映射+remap 分条带(4096/cols 控内存,undistort.dispatch.cpp:300-322)。

## 8.7 小结与深挖方向

本章结论:**calib3d=单点畸变公式+CvLevMarq 整数幂阻尼闭环+PnP 家族(DLS/UPnP 已降级)+经典/USAC 双轨**。深挖:

1. compat_ptsetreg 的 ALTERNATIVE(updateAlt)与普通 update 两种接口的内存差异;
2. usac/ 的 MAGSAC++ 与 LO-RANSAC 阈值自适应实现(usac/ransac_sac.cpp?);
3. initIntrinsicParams2D 消失点方程的退化视角数下限(calibration.cpp:61-140);
4. stereo_geom.cpp 的 stereoRectify 与 initUndistortRectifyMap 复用;
5. IPPE 的平面特解二义性消除(ippe.cpp)。
