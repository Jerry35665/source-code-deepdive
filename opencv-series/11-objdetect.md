# 第 11 章 · objdetect:级联、HOG 与"quirc 优先"的 QR 码

> 基线:commit `d3d247f1`(4.13.0-dev)。核心:modules/objdetect/src/(cascadedetect.cpp / hog.cpp / qrcode.cpp)。

## 11.0 全景:一次窗口判定的数据流

```
 CascadeInvoker(水平条带并行,nstripes=ceil(宽/32),每线程 clone evaluator)
   │ 图像按 1/scale 缩放,每尺度积分图打包进同一块 sbuf(cascadedetect.cpp:471-534)
   │ 滑窗步长 ystep = scale≥2 ? 1 : 2(:462)
   ▼ setWindow(:716-743)
   ├ 积分图窗口差 → valsum/valsqsum → 方差归一化因子
   ├ area*nf < 0.1(近纯色窗口)→ 直接拒绝
   ▼ runAt(:968-997)
   │ for stage:sum=Σ弱分类器;sum < stage.threshold → 返回负级号(级联早退)
   ▼ 全部通过 → 加锁写回原图坐标 → groupRectangles(eps=0.2 硬编码,:1396)
```

纠偏:特征枚举虽保留 `HOG=2`(cascadedetect.hpp:14-19),但读到 "HOG" 直接 `CV_Error("HOG cascade is not supported in 3.0")`(cascadedetect.cpp:1462-1466),`create()` 也只创建 HAAR/LBP(:909-914)——级联的 HOG 分支是**不可达死路径**,"HOG 级联"是误解。

## 11.1 级联:扁平化数组与 stump 快路径

模型数据全部展平为并行数组:stages/DTree/DTreeNode/leaves/subsets/stumps(cascadedetect.hpp:165-195);若整棵级联全是深度 1 的树,加载期把 nodes/leaves 压成连续 stumps,runAt 分派到无树遍历的查表求和(predictOrderedStump,cascadedetect.hpp:583-600)。旧格式加载是一次性格式转换而非运行时解释(load 失败走 haar_cvt::convert 转 YAML 再读,cascadedetect.cpp:934-961);每级阈值统一减 THRESHOLD_EPS=1e-5f(:1448)。OpenCL 门控苛刻:仅 stump 型+非旧格式+无 maskGenerator 才走(:1322-1350)。

## 11.2 HOG:3781 个系数的硬编码 SVM

纠偏:默认人物检测器是 **3781 个系数**而非"3780 维"——hog.cpp:1960-2772 硬编码数组实测 = 3780 维描述子+末位自由偏置,检测时 `rho = svmDetector[dsize]` 取的正是偏置(hog.cpp:1561);Daimler 检测器 1981 个系数(窗口 48×96,:2776-2779)。HOG 特征:cell 梯度直方图+block 归一化;检测是图像金字塔+固定 64×128 窗口的线性 SVM 点积,手工 SIMD 主导。

## 11.3 QR:quirc 优先,自研 RS 回退

纠偏:QR **解码默认走内嵌第三方 quirc**——构建带 quirc 时把矫正图逐位填进 quirc_code,ECC 失败还会 quirc_flip 镜像重试一次(qrcode.cpp:2825-2850);本仓自研 `QRCodeDecoderImpl`(伴随式+Berlekamp-Massey+Forney,qrcode_encoder.cpp:1548-1640)仅在无 quirc 时启用(:2858-2869);模块 CMakeLists.txt:18 显式链接 quirc。定位端是 1:1:3:1:1 扫描线找 finder pattern;本 commit 的编码侧(qrcode_encoder.cpp)仍在演进(alignment marker/Structured Append/ECI)。

## 11.4 设计动机

1. **扁平化并行数组**:stages/nodes/leaves 连续存储,缓存友好、可整体 memcpy 加载(cascadedetect.hpp:165-195);
2. **缩图像而非缩窗口**:每尺度 resize 后积分图打包单次大分配,窗口固定(hog/cascade 共同策略);
3. **级联早退用负级号**:返回 -stageIdx 兼顾"拒绝位置"信息量(cascadedetect.cpp:968-997);
4. **第三方优先**:QR 解码交给久经测试的 quirc,自研解码器只做无依赖回退(CMakeLists.txt:18);
5. **检测器即数据**:3781 个 float 直接编译进二进制,零模型文件依赖(hog.cpp:1960-2772);
6. **方差归一化前置**:近纯色窗口在进级联前就被拒,省掉全部 stage 计算(cascadedetect.cpp:716-743)。

## 11.5 FAQ

**Q1:HOG 级联能用吗?**
不能,读取即报错"not supported in 3.0"(cascadedetect.cpp:1462-1466)。

**Q2:默认 HOG 检测器多少维?**
3780 维描述子+1 个偏置=3781 个系数(hog.cpp:1960-2772)。

**Q3:QR 解码用的是谁?**
默认内嵌 quirc;自研 RS 解码器是无 quirc 时的回退(qrcode.cpp:2825-2869)。

**Q4:级联滑窗步长多少?**
scale≥2 时 1 像素,否则 2(:462)。

**Q5:近纯色窗口怎么办?**
方差归一化因子过低直接拒,不进级联(:716-743)。

**Q6:旧格式 XML 级联怎么加载?**
先 haar_cvt::convert 转成新格式内存串再读,一次性转换(:934-961)。

**Q7:OpenCL 级联有什么限制?**
仅 stump 型+新格式+无掩码生成器才启用(:1322-1350)。

**Q8:groupRectangles 的 eps 是多少?**
GROUP_EPS=0.2 硬编码;数量不足 minNeighbors 的簇丢弃(:1396, 63-173)。

**Q9:aruco 在哪?**
同模块 aruco/ 子目录,内嵌 AprilTag 四边形检测源码(aruco/apriltag/)。

**Q10:stump 快路径何时生成?**
整棵级联全是深度 1 树时,加载期压平(:1561-1577)。

## 11.6 小结与深挖方向

本章结论:**objdetect=扁平化级联(Haar/LBP)+手工 SIMD 的 HOG 线性 SVM+quirc 优先的 QR,四代检测器同仓共存**。深挖:

1. groupRectangles 的 partition 聚类与嵌套框剔除细节(cascadedetect.cpp:63-173);
2. HOG OpenCL kernel 与 CPU 路径的 scale 循环差异(hog.cpp);
3. qrcode_encoder 的 Structured Append 分包逻辑;
4. BarcodeDetector 的 SuperScale 超分触发条件(barcode.cpp:143);
5. FaceDetectorYN 对 dnn 的最小依赖面(face_detect.cpp:11)。
