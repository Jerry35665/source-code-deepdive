# 报告 E2 · objdetect 级联/HOG/QR(OpenCV 卷二)

> 基线:d3d247f1(4.13.0-dev,gitee 浅克隆,commit 标题 "Merge pull request #27962 from Tuchis:fix-fisheye-documentation")。一句话总结:objdetect 是一个"经典 CV 检测器百宝箱"——级联(Haar/LBP)靠积分图+扁平化 boosting 数组,HOG 靠手工 SIMD+图像金字塔+线性 SVM 点积,QR 靠 1:1:3:1:1 扫描线定位 + quirc/自研 RS 解码,全部为 CPU 优先、OpenCL 可选加速的 2010 年代技术栈,在本 commit 仍在演进(QR alignment marker、Structured Append、ECI 处理)。

## 1. 模块全景:一个模块装了四代检测器

文件行数实测(`wc -l`,modules/objdetect/):src/cascadedetect.cpp 1763 行、src/cascadedetect.hpp 656 行、src/hog.cpp 3530 行、src/qrcode.cpp 4733 行、src/qrcode_encoder.cpp 1844 行(+ qrcode_encoder_table.inl.hpp 869 行)、src/barcode.cpp 437 行、src/detection_based_tracker.cpp 885 行、src/face_detect.cpp 317 行、src/face_recognize.cpp 218 行、src/graphical_code_detector.cpp 45 行。

aruco 子目录(src/aruco/):aruco_detector.cpp 1511 行、charuco_detector.cpp 607 行、aruco_board.cpp 644 行、aruco_dictionary.cpp 447 行,以及内嵌 AprilTag 源码(src/aruco/apriltag/:apriltag_quad_thresh.cpp/.hpp、unionfind.hpp、zarray.hpp、zmaxheap.cpp/.hpp、predefined_dictionaries_apriltag.hpp)。

公共 API:include/opencv2/objdetect.hpp 881 行 + include/opencv2/objdetect/ 下子头(barcode.hpp、aruco_detector.hpp 462 行、aruco_board.hpp、aruco_dictionary.hpp、charuco_detector.hpp、face.hpp、graphical_code_detector.hpp、detection_based_tracker.hpp,均实测存在)。

第三方依赖:模块链接内嵌 quirc(modules/objdetect/CMakeLists.txt:18 `ocv_target_link_libraries(${the_module} quirc)`;源码树 3rdparty/quirc/ 实测存在)。FaceDetectorYN/FaceRecognizerSF 依赖 dnn(face_detect.cpp:11);BarcodeDetector 内置 SuperScale 超分(barcode.cpp:143)。

## 2. 级联(上):数据结构与新旧格式加载

特征类型枚举 `HAAR=0, LBP=1, HOG=2`(cascadedetect.hpp:14-19),但 `FeatureEvaluator::create` 只创建前两种,HOG 返回空指针(cascadedetect.cpp:909-914)。模型数据全部展平为并行数组:

```cpp
// cascadedetect.hpp:165-195(Data 内三类实体 + 三个值数组)
struct DTreeNode { int featureIdx; float threshold; int left; int right; };
struct DTree    { int nodeCount; };
struct Stage    { int first; int ntrees; float threshold; };
struct Stump    { int featureIdx; float threshold; float left; float right; };
...
std::vector<Stage>    stages;
std::vector<DTree>    classifiers;
std::vector<DTreeNode> nodes;
std::vector<float>    leaves;
std::vector<int>      subsets;
std::vector<Stump>    stumps;
```

`load()` 先按新格式 `read_`;失败则把旧格式经 `haar_cvt::convert` 转成内存中的 YAML 字符串再读一遍(cascadedetect.cpp:934-961)——旧格式并非运行时被解释,而是一次性格式转换;`isOldFormatCascade()` 以转换后 `oldCascade` 是否非空判断(cascadedetect.cpp:1235-1238)。读取约束:stageType 只接受 "BOOST"(cascadedetect.cpp:1451-1455);featureType 读到 "HOG" 直接报错:

```cpp
// cascadedetect.cpp:1457-1466
String featureTypeStr = (String)root[CC_FEATURE_TYPE];
if( featureTypeStr == CC_HAAR )
    featureType = FeatureEvaluator::HAAR;
else if( featureTypeStr == CC_LBP )
    featureType = FeatureEvaluator::LBP;
else if( featureTypeStr == CC_HOG )
{
    featureType = FeatureEvaluator::HOG;
    CV_Error(Error::StsNotImplemented, "HOG cascade is not supported in 3.0");
}
```

每级阈值统一减 `THRESHOLD_EPS=1e-5f`(cascadedetect.cpp:1448,1503)。若整棵级联全是深度 1 的树(`maxNodesPerTree==1`),加载期把 nodes/leaves 压成连续 stumps 数组(cascadedetect.cpp:1561-1577);`runAt` 据此分派到 Stump 或树两套 predictor(cascadedetect.cpp:979-996),HOG 分支返回 -2(永不可达,因读取已报错)。stump 路径无树遍历:

```cpp
// cascadedetect.hpp:583-600(predictOrderedStump:查表求和,负级号早退)
for( int stageIdx = 0; stageIdx < nstages; stageIdx++ )
{
    const CascadeClassifierImpl::Data::Stage& stage = cascadeStages[stageIdx];
    tmp = 0;
    int ntrees = stage.ntrees;
    for( int i = 0; i < ntrees; i++ )
    {
        const CascadeClassifierImpl::Data::Stump& stump = cascadeStumps[i];
        double value = featureEvaluator(stump.featureIdx);
        tmp += value < stump.threshold ? stump.left : stump.right;
    }
    if( tmp < stage.threshold )
    {
        sum = (double)tmp;
        return -stageIdx;
    }
    cascadeStumps += ntrees;
}
```

## 3. 级联(下):积分图、窗口判定数据流与 OpenCL

Haar 特征最多 3 个矩形(`RECT_NUM=3`,cascadedetect.hpp:324-329),读入时逐矩形做边界校验(cascadedetect.cpp:564-571);评估时预编译为 `OptFeature`(固定偏移+权重),`calc` 对 2~3 个积分图窗口差加权求和、`weight[2]==0` 时跳过第三个(cascadedetect.hpp:393-402)。LBP 特征 = 3×3 邻域 8 次积分图比较拼 8bit 码(cascadedetect.hpp:466-478),偏移按 2w/2h 网格展开(cascadedetect.cpp:878-891)。通道数 `nchannels = hasTiltedFeatures ? 3 : 2`(sum+sqsum[+tilted],cascadedetect.cpp:621),每尺度积分图经 `integral()` 写入打包的 sbuf(cascadedetect.cpp:648-689)。窗口判定前的方差归一化:

```cpp
// cascadedetect.cpp:716-743(setWindow:归一化因子 + 低对比度拒绝)
pwin = &sbuf.at<int>(pt) + s.layer_ofs;
const int* pq = (const int*)(pwin + sqofs);
int valsum = CALC_SUM_OFS(nofs, pwin);
unsigned valsqsum = (unsigned)(CALC_SUM_OFS(nofs, pq));
double area = normrect.area();
double nf = area * valsqsum - (double)valsum * valsum;
if( nf > 0. )
{
    nf = std::sqrt(nf);
    varianceNormFactor = (float)(1./nf);
    return area*varianceNormFactor < 1e-1;   // 对比度过低直接拒
}
varianceNormFactor = 1.f;
return false;
```

多尺度组织方式是"缩图像、固定窗口":`setImage` 对每个尺度 `resize(1/scale, INTER_LINEAR_EXACT)` 后计算积分图,全部打包进同一块 sbuf(单次大分配,`layer_ofs` 手工排布,cascadedetect.cpp:471-477 与 528-534)。滑窗步长 `ystep = scale>=2 ? 1 : 2`(cascadedetect.cpp:462)。尺度集合先生成再过滤,`minSize==maxSize` 未命中时用 L2 距离挑最接近的单一尺度(cascadedetect.cpp:1278-1315);入口断言 `scaleFactor > 1 && depth==CV_8U`(cascadedetect.cpp:1389)。CPU 并行按水平条带:每线程 clone evaluator、外层遍历尺度、内层滑窗,命中才回写原图坐标并加锁(cascadedetect.cpp:1034-1087);条带数 `nstripes = ceil(宽/32)`(cascadedetect.cpp:1365)。候选分组 `groupRectangles`:partition 聚类(eps)→ 类内均值 → 数量 ≤ groupThreshold 的簇丢弃 → 剔除完全落入更大簇内的小框(cascadedetect.cpp:63-173),`GROUP_EPS=0.2` 硬编码(cascadedetect.cpp:1396)。滑窗里 `if( result == 0 ) x += yStep;`(cascadedetect.cpp:1082-1083)对新格式是死代码——`runAt` 只返回 -1/-si/1(cascadedetect.cpp:968-997,推断)。

一次窗口判定的数据流(CPU 路径,按本 commit 源码绘制):

```
CascadeClassifierInvoker(水平条带并行, 每线程 clone evaluator)   :1013-1087
  │ for scaleIdx in 0..nscales:        (图像已按1/scale缩放, 积分图在sbuf)
  │   for y in 0..H step ystep(2或1):
  │     for x in 0..W step ystep:
  ▼
evaluator->setWindow(x,y)                                 :716-743
  ├─ 越界 ───────────────────────────► return -1 (跳过)
  └─ 积分图窗口差 → valsum / valsqsum
       varianceNormFactor = 1/sqrt(area*sqsum − sum²)
       area*nf < 0.1 (近纯色窗口) ──────► return false (拒绝)
  ▼
runAt → predictOrdered/Stump(Haar) 或 Categorical(LBP)    :968-997
  │   for stage in stages:                               hpp:497/583
  │     sum = Σ 弱分类器(树遍历取叶值 / stump 查表)
  │     if sum < stage.threshold: return -si   ← 级联早退(负级号)
  ▼
全部 stage 通过 → return 1
  ├─ 加锁 push_back(Rect(x*scale, y*scale, win*scale))    :1074-1081
  └─ 全图完成 → groupRectangles(minNeighbors, eps=0.2)     :1396-1404
```

OpenCL 门控与回退:

```cpp
// cascadedetect.cpp:1322-1350(节选)
bool use_ocl = tryOpenCL && ocl::isOpenCLActivated() &&
     OCL_FORCE_CHECK(_image.isUMat()) &&
     !featureEvaluator->getLocalSize().empty() &&
     (data.minNodesPerTree == data.maxNodesPerTree) &&  // 仅 stump 型
     !isOldFormatCascade() && maskGenerator.empty() && !outputRejectLevels;
...
CV_OCL_RUN(use_ocl, ocl_detectMultiScaleNoGrouping( scales, candidates ))
if (use_ocl)
    tryOpenCL = false;   // 失败一次, 永久回退 CPU
```

内核为 `runHaarClassifier`(cascadedetect.cl:71-72)与 `runLBPClassifierStumpSimple`(cascadedetect.cl:367),结果写 `ufacepos`(容量 MAX_FACES*3+1,MAX_FACES=10000,cascadedetect.hpp:137;cascadedetect.cpp:1118),全局规模按每 CU 12 个工作组硬编码(cascadedetect.cpp:1114-1115);LBP 要求 stump 型,否则 return false(cascadedetect.cpp:1176-1177)。Haar 的局部和缓冲仅对 AMD/Intel/NVIDIA 且 lbuf 面积 ≤1024 启用(cascadedetect.cpp:625-634)。注意:模块中不存在任何名为 hasNonZero 的函数(全目录 grep 无命中);"找非零点"用的标准 API 是 `findNonZero`,且只出现在 QR 路径(qrcode.cpp:2567 等 6 处)。

## 4. HOG(上):梯度、cell/block 与 L2Hys 归一化

默认参数:64×128 窗口、16×16 block、8×8 blockStride、8×8 cell、9 bins、L2Hys、阈值 0.2、nlevels=64(objdetect.hpp:407,415-419);细节:默认构造 `gammaCorrection=true`,带参构造默认 `false`(objdetect.hpp:417 vs 438)。描述子长度公式 = nbins×(block/cell)²×((win−block)/stride+1)²,64×128 下 = 9×2×2×7×15 = 3780(hog.cpp:87-102)。winSigma 负值时取 `(blockW+blockH)/8`(16×16 block 下 = 4,hog.cpp:104-107)。梯度:256 级 LUT(gamma 时预存 sqrt,hog.cpp:260-286)、1 像素中心差分(hog.cpp:496-521)、彩色图取三通道梯度模最大(hog.cpp:503-518)、BORDER_REFLECT_101(hog.cpp:292-299)、`cartToPolar` 后角度量化到 nbins 并线性插值:

```cpp
// hog.cpp:246-249(grad/qangle 的双通道编码)与 389(angleScale)
_grad.create(gradsize, CV_32FC2);  // <magnitude*(1-alpha), magnitude*alpha>
_qangle.create(gradsize, CV_8UC2); // [0..nbins-1] 相邻两个 bin
...
float angleScale = signedGradient ? (float)(nbins/(2.0*CV_PI)) : (float)(nbins/CV_PI);
```

block 直方图由 HOGCache 三张预计算表驱动:高斯空间权重 `exp(−((i−bh)²+(j−bw)²)/2σ²)`(hog.cpp:693-743);每像素对相邻 4/2/1 个 cell 的双线性权重(pixData 分 count4/count2/count1 三段,hog.cpp:773-863);作者注释明说是把"8 层嵌套循环"展平成窗口×block 两层(hog.cpp:748-771)。归一化即 L2Hys 两遍:

```cpp
// hog.cpp:1087-1145(节选:先 L2 缩放 + clip,再二次归一)
float scale = 1.f/(std::sqrt(sum)+sz*0.1f), thresh = (float)descriptor->L2HysThreshold;
...
hist[i] = std::min(hist[i]*scale, thresh);   // clip 到 0.2
...
scale = 1.f/(std::sqrt(sum)+1e-3f);
for ( ; i < sz; ++i)
    hist[i] *= scale;
```

## 5. HOG(下):SVM 检测、金字塔与默认人物检测器

`detect` 对每个滑窗位置做线性 SVM 点积,偏置取向量末位,`s >= hitThreshold` 记为命中(hog.cpp:1561,1618-1622);`setSVMDetector` 为 OCL 路径按行主序重排系数并分离 `free_coef`(hog.cpp:128-143)。多尺度:scale 从 1 起每层 ×scale0(默认 1.05,签名 objdetect.hpp:552-555),层数封顶 nlevels=64(hog.cpp:1905),`winStride` 缺省取 blockStride(hog.cpp:1917-1918);每层把图像缩小(`resize INTER_LINEAR_EXACT`,ALGO_HINT_APPROX 时 INTER_LINEAR,hog.cpp:1666-1680)、64×128 窗口固定滑动,命中点 ×scale 映回原坐标(hog.cpp:1687-1689)。分组默认 `groupRectangles(…, 0.2)`,`useMeanshiftGrouping=true` 时换 meanshift(hog.cpp:1942-1945;实现在 cascadedetect.cpp:175-363,核带宽 (8,16,log 1.3))。OpenCL 路径要求 8UC1、padding==0、winStride 为 blockStride 整数倍(hog.cpp:1920-1923),内核五阶段 compute_gradients/compute_hists_lut/normalize_hists/classify_hists/extract_descrs(src/opencl/objdetect_hog.cl:575,65,157,277-368,414-441)。

```cpp
// hog.cpp:2774-2779(getDaimlerPeopleDetector 的原始注释)
// This function renurn 1981 SVM coeffs obtained from daimler's base.
// To use these coeffs the detection window size should be (48,96)
std::vector<float> HOGDescriptor::getDaimlerPeopleDetector()
{
    static const float detector[] = {
        0.294350f, -0.098796f, -0.129522f, 0.078753f, ...
```

默认人物检测器 `getDefaultPeopleDetector` 硬编码于 hog.cpp:1960-2772,实测数组字面量 3781 个 float = 3780 维描述子 + 1 个自由偏置(检测时 `rho = svmDetector[dsize]` 取用,hog.cpp:1561);Daimler 版实测 1981 个(窗口 48×96,hog.cpp:2776-2779)。

## 6. QR 码:定位 → 矫正 → 版本 → 解码(附 aruco 一句话)

`QRCodeDetector` 为 pimpl(`ImplContour`,qrcode.cpp:964-1010)。预处理:短边归一到 512(小于则放大、大于则 INTER_AREA 缩小),再 `adaptiveThreshold(ADAPTIVE_THRESH_GAUSSIAN_C, 83, 2)` 二值化(qrcode.cpp:123-165)。定位核心 1:1:3:1:1 比例测试:逐行记录黑白跳变,5 段长度按 `|len/total−1/7|`(×4)+ `|len/total−3/7|` 求权重,`weight < eps_vertical` 即候选(qrcode.cpp:200-227);垂直验证的 eps 从 1 倍到 10 倍逐步放宽(qrcode.cpp:237-240);候选点 kmeans(k=3) 聚成三个定位角(qrcode.cpp:245-248);SHRINKING 失败回退缩小图重试并按 coeff_expansion 放回坐标(qrcode.cpp:513-539)。三个定位角经 fixationPoints 定第四角、floodFill+convexHull+getQuadrilateral 求四角(qrcode.cpp:365-396,568-699)。

解码由 `QRDecode` 执行:`straightDecodingProcess` = updatePerspective(矫正到 ≥251px,qrcode.cpp:1163)→ versionDefinition → 可选 detectAlignment → samplingForVersion → decodingProcess(qrcode.cpp:2931-2939)。版本三策略:黑白跳变数(`(min(tx,ty)−1)*0.25−1`,qrcode.cpp:2608-2609)、finder 间距、≥7 时版本信息码比对取最近,合法性 `0<version<=40`(qrcode.cpp:2617-2655)。解码本体双轨:

```cpp
// qrcode.cpp:2825-2850(节选:默认 quirc,ECC 失败镜像重试)
#ifdef HAVE_QUIRC
    ...
    quirc_data qr_code_data;
    quirc_decode_error_t errorCode = quirc_decode(&qr_code, &qr_code_data);
    if(errorCode ==  QUIRC_ERROR_DATA_ECC){
        quirc_flip(&qr_code);
        errorCode = quirc_decode(&qr_code, &qr_code_data);
    }
    if (errorCode != 0) { return false; }
#else
    auto decoder = QRCodeDecoder::create();
    if (!decoder->decode(straight, result_info))
        return false;
#endif
```

本仓自研 `QRCodeDecoderImpl`(qrcode_encoder.cpp:1320)仅在无 quirc 时启用,含完整 RS 纠错(伴随式、Berlekamp-Massey、Forney,qrcode_encoder.cpp:1548-1640)与格式信息汉明距离 ≤3 纠错(qrcode_encoder.cpp:1395-1410);解码失败还会转置矩阵重试(qrcode_encoder.cpp:1378-1386)。解码后按 mode 分派:NUMERIC/ALPHANUMERIC 要求 ASCII,BYTE 按 ECI 分 UTF-8/ASCII/单字节转码,KANJI 强标 Shift-JIS,ECI 警告"未正确支持"(qrcode.cpp:2872-2928)。多码走 `QRDetectMulti`(qrcode.cpp:3073);弯曲码走样条+分段拉直的 curvedDecodingProcess(qrcode.cpp:1091-1092,2011-2307)。`QRCodeEncoder` 在本仓:qrcode_encoder.cpp:174 起 `QRCodeEncoderImpl` + 869 行码字表(qrcode_encoder_table.inl.hpp),支持 Structured Append(objdetect.hpp:769-773)。

**aruco 与同模块其他检测器(一句话带过):** aruco 在 src/aruco/(aruco_detector.cpp 1511 行等),四边形提取直接内嵌 AprilTag 的 quad_thresh(aruco_detector.cpp:10 `#include "apriltag/apriltag_quad_thresh.hpp"`),姿态依赖 calib3d(aruco_detector.cpp:6);`QRCodeDetectorAruco` 复用 aruco::ArucoDetector,用 5×4 位字典定位三个 finder(qrcode.cpp:4644-4653)。BarcodeDetector 同实现 GraphicalCodeDetector 接口,内置 SuperScale 超分(barcode.cpp:143,346-350);FaceDetectorYN 是纯 dnn 前向(face_detect.cpp:34);DetectionBasedTracker 把任意检测器包成检测-跟踪级联(detection_based_tracker.cpp)。

## 7. 纠偏与设计动机

1. **"HOG 级联可用"——错。** 读取到 featureType "HOG" 直接 `CV_Error("HOG cascade is not supported in 3.0")`(cascadedetect.cpp:1462-1466);`create` 只造 HAAR/LBP(cascadedetect.cpp:909-914);`HOG=2` 是历史残留(cascadedetect.hpp:14-19)。
2. **"默认人物检测器 3780 维"——不精确。** 实为 3781 个 float:3780 维 + 末位偏置(rho),hog.cpp:1561 与 1960-2772 实测计数。
3. **"OpenCL hasNonZero"——不存在。** 全模块 grep 无此符号;级联内核是 runHaarClassifier/runLBPClassifierStumpSimple(cascadedetect.cl:72,367),QR 用的找点 API 是 findNonZero(qrcode.cpp:2567)。
4. **"detectMultiScale 放大窗口"——实现相反。** 级联与 HOG 都是缩图像、固定窗口(cascadedetect.cpp:528-534;hog.cpp:1666-1681)。
5. **"QR 解码是纯 OpenCV"——默认不是。** 有 quirc 时走内嵌第三方(CMakeLists.txt:18;3rdparty/quirc/),自研 RS 解码器只是回退(qrcode.cpp:2825-2869;qrcode_encoder.cpp:1320)。
6. **"旧格式级联被运行时解释"——实为内存转格式。** 先转 YAML 字符串再按新格式重读(cascadedetect.cpp:949-955)。

### 设计动机

1. **扁平数组优先**:stages/nodes/leaves 连续存储,cache 友好,且可 `copyVectorToUMat` 一次上传 GPU(cascadedetect.cpp:56-61,1122-1132)。
2. **stump 特化**:全一阶树时压成 Stump 查表路径,加载期一次转换、判定期零树遍历(cascadedetect.cpp:1561-1577,979-986)。
3. **积分图 O(1) + 预编译偏移**:OptFeature 把矩形换成固定偏移,窗口判定只做加减乘(cascadedetect.cpp:692-714;cascadedetect.hpp:340-342)。
4. **单块 sbuf 打包所有尺度**:一次大分配代替逐尺度分配(cascadedetect.cpp:471-477,525)。
5. **HOG 查找表展平循环**:pixData/blockData 把 8 层嵌套循环减到 2 层,作者注释直言"very-very slow"(hog.cpp:748-771)。
6. **QR 零模型依赖**:512 归一化+自适应阈值+比例扫描线+kmeans,任何平台可跑(qrcode.cpp:123-272)。
7. **OpenCL 保守门控+自动回退**:仅 stump 新格式启用,失败永久回退 CPU,正确性优先(cascadedetect.cpp:1322-1350)。
8. **级联早退即收益**:`-si` 负级号直接返回,背景窗口前几级被拒(cascadedetect.hpp:519-521)。

## 8. FAQ、深挖方向与正文蒸馏要点

### FAQ 候选(每条一句话)

1. CascadeClassifier 支持哪些特征?——只有 HAAR 与 LBP,读 HOG 直接抛异常(cascadedetect.cpp:1457-1468)。
2. 每级阈值为何减 1e-5?——THRESHOLD_EPS 浮点安全余量(cascadedetect.cpp:1448,1503)。
3. minNeighbors 过滤什么?——分组后"相似矩形数 ≤ groupThreshold"的簇(cascadedetect.cpp:141-142)。
4. minSize==maxSize 会怎样?——L2 距离挑最接近的单一尺度(cascadedetect.cpp:1296-1315)。
5. LBP 特征值怎么算?——3×3 邻域与中心块的积分图比较,8bit 共 256 类(cascadedetect.hpp:466-478)。
6. 为什么拒绝低对比度窗口?——方差归一化后 `area*nf<0.1` 说明近纯色,Haar 特征无意义(cascadedetect.cpp:730-737)。
7. HOG 的 winSigma 默认多少?——负值时取 (blockW+blockH)/8,默认 16×16 block 下为 4(hog.cpp:104-107)。
8. hitThreshold=0 时 SVM 阈值从哪来?——检测器向量末位的自由系数 rho(hog.cpp:1561)。
9. QR 版本号怎么估?——版本信息码比对 > finder 间距 > 跳变数,三策略择优且限 1..40(qrcode.cpp:2608-2655)。
10. HOG 金字塔最多几层?——nlevels 默认 64,到图像缩得比 64×128 窗口小即停(hog.cpp:1905-1913;objdetect.hpp:407)。

### 深挖方向

1. cascadedetect.cl 内核:lbuf 局部和缓冲如何在工作组内共享积分图窗口(cascadedetect.cl:71-365,编译选项 cascadedetect.cpp:1146-1151)。
2. QR 弯曲码:createSpline/divideIntoEvenSegments/straightenQRCodeInParts 的样条与分段透视(qrcode.cpp:2011-2307;quirc 内部 GF(256) 未逐行核实,标注未核实)。
3. meanshift 分组的带宽选择依据:(8,16,log1.3) 的来源与影响(cascadedetect.cpp:322-363)。
4. groupRectangles 聚类后 O(n²) 包含检测的复杂度(cascadedetect.cpp:144-162)。
5. HOG OCL 五阶段内核流水线与 classify_hists 的窗口并行策略(objdetect_hog.cl:277-411)。
6. DetectionBasedTracker 检测/跟踪接力状态机(detection_based_tracker.cpp,885 行)。

### 正文蒸馏要点

1. 级联模型是 stages/classifiers/nodes/leaves/subsets 扁平数组 + Stump 特化通道(cascadedetect.hpp:162-213;cascadedetect.cpp:1561-1577)。
2. 一次窗口判定 = 方差归一化门 → 逐 stage 求和 → sum<threshold 即 `-si` 早退(cascadedetect.cpp:716-743;cascadedetect.hpp:497-521)。
3. 旧格式级联加载即在内存转新 YAML 再读,一次性成本(cascadedetect.cpp:949-955)。
4. 多尺度=缩图像不缩窗口,积分图打包进单一 sbuf,滑窗步长 2/1(cascadedetect.cpp:528-534,462)。
5. OpenCL 仅 stump 新格式启用、失败永久回退;内核 runHaarClassifier/runLBPClassifierStumpSimple(cascadedetect.cpp:1322-1350,1152,1192)。
6. groupRectangles = partition 聚类 + 数量过滤 + 大框吞小框,eps 固定 0.2(cascadedetect.cpp:63-173,1396)。
7. HOG 64×128 描述子 3780 维,默认人物检测器实为 3781 系数(含 rho 偏置)(hog.cpp:87-102,1561,1960-2772)。
8. HOG 三板斧:梯度 LUT+SIMD、pixData/blockData 查找表、L2Hys 两遍归一(hog.cpp:260-286,748-771,1087-1145)。
9. HOG 金字塔 ×1.05、≤64 层,winStride 默认 blockStride,分组可换 meanshift(hog.cpp:1900-1945;objdetect.hpp:407,552-555)。
10. QR 定位 = 512 归一化+自适应阈值(83,2)+1:1:3:1:1 扫描线+kmeans(3),无神经网络(qrcode.cpp:123-272)。
11. QR 版本三策略判定限 1..40,透视矫正到 ≥251px 采样(qrcode.cpp:2608-2655,1163)。
12. QR 解码默认 quirc(ECC 失败镜像重试),自研 RS/BM/Forney 是回退;QRCodeEncoder 在本仓(qrcode.cpp:2825-2869;qrcode_encoder.cpp:174,1320)。
