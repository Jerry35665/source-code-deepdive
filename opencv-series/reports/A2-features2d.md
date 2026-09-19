# 报告 A2 · features2d 特征与匹配(OpenCV 卷二)

> 基线:d3d247f1(4.13.0-dev)。一句话:features2d 把"检测 + 提取"统一进 `Feature2D::detectAndCompute` 单接口,向下挂 FAST/ORB/SIFT 等实现、向上由 BFMatcher(核心 batchDistance)与可选的 FlannBasedMatcher 输出 DMatch 对,本报告逐段核实该流水线的全部主路径。

行号约定:`文件:行号` 均指本 commit 的 `modules/` 下路径;`features2d.hpp` 指 `modules/features2d/include/opencv2/features2d.hpp`,其余同理。本仓库为 gitee 镜像浅克隆,`git log` 仅 1 个提交(即 d3d247f 自身),涉及"历史演变"的论断只能以文件现状与注释为准,无法以提交史佐证,下文逐处标明。

## 1. 总览:从图像到匹配点对

```
              图像 (BGR)                                    图像 (BGR)
                 │ cvtColor 灰度化                              │
   ┌─────────────▼───────────────┐               ┌─────────────▼───────────────┐
   │ FAST: 圆周16点比较+3x3 NMS   │               │ SIFT: 2x放大→高斯金字塔→DoG  │
   │  fast.cpp:216-252,289-299    │               │  sift.dispatch.cpp:176-309   │
   │ ORB: 金字塔FAST→Harris重选   │               │ 极值→亚像素插值→方向直方图    │
   │  orb.cpp:886-993             │               │  sift.simd.hpp:291-396       │
   └─────────────┬───────────────┘               └─────────────┬───────────────┘
                 │ KeyPoint(pt,size,angle,                     │ KeyPoint[]
                 │           response,octave)                  │
   ┌─────────────▼───────────────┐               ┌─────────────▼───────────────┐
   │ ORB: ICAngles方向+旋转采样   │               │ SIFT: 4x4x8梯度直方图        │
   │  bit_pattern_31_ (rBRIEF)    │               │ 三线性插值+归一化截断         │
   │  orb.cpp:181-215,244-285     │               │  sift.simd.hpp:709-905       │
   └─────────────┬───────────────┘               └─────────────┬───────────────┘
                 │ Mat Nx32 (CV_8U)                            │ Mat Nx128 (CV_32F/8U)
                 └──────────────┬──────────────────────────────┘
                                ▼
              DescriptorMatcher::knnMatch(matchers.cpp:647-661)
              ┌───────────────────────────────────────────┐
              │ BFMatcher → batchDistance (modules/core)  │ Hamming=popcount(整数距离)
              │ FlannBasedMatcher → flann::Index(可选模块)│ KDTree/KMeans/LSH/Autotuned
              └──────────────────┬────────────────────────┘
                                 ▼
              vector<vector<DMatch>> (queryIdx,trainIdx,imgIdx,distance)
                                 │  ← Lowe ratio test:由用户自己做(不在匹配器内)
                                 ▼
              findHomography / drawMatches(draw.cpp:206-248)
```

## 2. 统一抽象:Feature2D 的合并与三层接口

`Feature2D` 直接继承 `Algorithm`,并在 5.0 起改为虚继承(features2d.hpp:132-138);检测器与提取器在 3.x 已合并为这一个抽象基类,旧名只是 typedef 兼容别名(features2d.hpp:227-228、233-235,347-348 还有 `typedef SIFT SiftFeatureDetector`,259-260 有 `typedef AffineFeature AffineFeatureDetector`):

```cpp
// features2d.hpp:227-235
/** Feature detectors in OpenCV have wrappers with a common interface ...
All objects that implement keypoint detectors inherit the FeatureDetector
interface. */
typedef Feature2D FeatureDetector;
/** Extractors of keypoint descriptors ... All objects that implement
the vector descriptor extractors inherit the DescriptorExtractor interface. */
typedef Feature2D DescriptorExtractor;
```

统一接口就是六个虚方法:`detect`、`compute`、`detectAndCompute`、`descriptorSize`、`descriptorType`、`defaultNorm`(features2d.hpp:151-203)。其中 `detect`/`compute` 是 `detectAndCompute` 的薄包装——空图短路后直接转调(feature2d.cpp:59-71、114-126),而基类版 `detectAndCompute` 只抛"未实现",即具体算法必须自己实现这一条;`useProvidedKeypoints=true` 时 compute 复用外部关键点(features2d.hpp:196-199):

```cpp
// feature2d.cpp:59-70
void Feature2D::detect( InputArray image,
                        std::vector<KeyPoint>& keypoints,
                        InputArray mask )
{
    CV_INSTRUMENT_REGION();
    if( image.empty() )
    {
        keypoints.clear();
        return;
    }
    detectAndCompute(image, mask, keypoints, noArray(), false);
}
// feature2d.cpp:125:compute(...) => detectAndCompute(image, noArray(), keypoints, descriptors, true);
```

基类默认 `descriptorSize()=0`、`descriptorType()=CV_32F`(feature2d.cpp:197-205),距离度量由类型自动推导:

```cpp
// feature2d.cpp:207-211
int Feature2D::defaultNorm() const
{
    int tp = descriptorType();
    return tp == CV_8U ? NORM_HAMMING : NORM_L2;
}
```

两个容易忽略的细节:其一,`detect`/`compute` 虽声明为 virtual(features2d.hpp:151、177),但其实现内部不再走虚函数而直接调 `detectAndCompute`,子类只重写后者即同时获得三个入口(feature2d.cpp:70、125);其二,关键点的过滤/去重/按响应裁剪不放在各算法里,而是统一的 `KeyPointsFilter` 静态工具类(features2d.hpp:92-121),`retainBest` 用 `nth_element`+`partition` 做部分排序(keypoint.cpp:69-88),ORB 与 SIFT 都依赖它。

## 3. FAST 与 ORB:高速度与旋转不变

**FAST 的快速路径**。16 个圆周点的偏移表以正下方 (0,3) 为起点顺时针排列(fast_score.cpp:52-56),`makeOffsets` 把数组扩到 25 项(环形回卷,`pixel[k]=pixel[k-patternSize]`),使"连续弧"检查无需取模(fast_score.cpp:76-80)。逐像素判定时先建三值查表(1=比中心暗超阈值,2=亮超阈值,0=其他,fast.cpp:78-80),再用对跖点对短路:

```cpp
// fast.cpp:214-231(节选)
int v = ptr[0];
const uchar* tab = &threshold_tab[0] - v + 255;
int d = tab[ptr[pixel[0]]] | tab[ptr[pixel[8]]];
if( d == 0 ) continue;                        // 上下两点既不亮也不暗 → 直接排除
d &= tab[ptr[pixel[2]]] | tab[ptr[pixel[10]]];
d &= tab[ptr[pixel[4]]] | tab[ptr[pixel[12]]];
d &= tab[ptr[pixel[6]]] | tab[ptr[pixel[14]]];
if( d == 0 ) continue;
d &= tab[ptr[pixel[1]]] | tab[ptr[pixel[9]]];
d &= tab[ptr[pixel[3]]] | tab[ptr[pixel[11]]];
d &= tab[ptr[pixel[5]]] | tab[ptr[pixel[13]]];
d &= tab[ptr[pixel[7]]] | tab[ptr[pixel[15]]];
```

`d&1` 表示存在更暗方向,沿环形数组数连续弧,`++count > K`(K=patternSize/2,N=patternSize+K+1)即判为角点;`d&2` 同理处理更亮方向(fast.cpp:233-275)。候选点记录位置,若开 NMS 则立即算 score 存入当前行缓冲(fast.cpp:244-246)。非极大抑制是逐候选与上下两行共 8 个邻居的 score 比较,通过的点固定 `size=7, angle=-1`,response 即 score(fast.cpp:289-299):

```cpp
// fast.cpp:292-298
int score = prev[j];
if( !nonmax_suppression ||
   (score > prev[j+1] && score > prev[j-1] &&
    score > pprev[j-1] && score > pprev[j] && score > pprev[j+1] &&
    score > curr[j-1] && score > curr[j] && score > curr[j+1]) )
{
    keypoints.push_back(KeyPoint((float)j, (float)(i-1), 7.f, -1, (float)score));
}
```

score 的定义是"把阈值加到多大该点不再是角点",即最大可行阈值再减 1:SIMD 版在 fast_score.cpp:119-164(`threshold = v_reduce_max(q0) - 1`),标量版循环求 min/max 后 `threshold = -b0 - 1`(fast_score.cpp:168-209)。patternSize 8/12/16 三种分别对应 TYPE_5_8/7_12/9_16(fast.cpp:470-478),入口依次尝试 HAL、OpenCL、AVX2/SIMD128、标量(fast.cpp:440-467;fast.cpp:63-70);HAL dense 路径只支持 `threshold<=20`,同样遵守 response-1 约定(fast.cpp:385、431)。类包装 `FastFeatureDetector_Impl` 默认 `threshold=10, nonmaxSuppression=true, TYPE_9_16`(features2d.hpp:586-588;fast.cpp:492-539)。

**ORB 的方向与 rBRIEF**。ORB 检测端不是重写 FAST,而是组合 `FastFeatureDetector::create(fastThreshold, true)` 逐金字塔层调用(orb.cpp:891-894),随后 `runByImageBorder` 清边界点、按响应保留 2 倍候选(orb.cpp:897-899)。打分:7x7 窗 Harris,K=0.04(orb.cpp:50、131-176),重打分后再次 `retainBest` 裁到每层目标数(orb.cpp:924-958)。方向用亮度质心:圆形 patch 中心行直接累加 m_10,上下各行以 `umax`(半径圆每行的对称半宽,872-875 做过等值修正)为界累加,`angle = fastAtan2(m_01, m_10)` 单位为度(orb.cpp:195-213)。描述子在 `computeOrbDescriptor` 中把学习到的 256 对采样点 `bit_pattern_31_`(orb.cpp:380)按角度旋转后取最近邻像素:

```cpp
// orb.cpp:244-250
#define GET_VALUE(idx) \
       (x = pattern[idx].x*a - pattern[idx].y*b, \
        y = pattern[idx].x*b + pattern[idx].y*a, \
        ix = cvRound(x), \
        iy = cvRound(y), \
        *(center + iy*step + ix) )
```

被 `#else` 禁用的分支才是双线性插值采样(orb.cpp:251-259)。`WTA_K=2` 时每字节 8 次 `t0<t1` 两两比较(orb.cpp:261-285),3/4 元组变体分别每字节产 4 个 2 位(orb.cpp:286-330),`defaultNorm` 相应返回 NORM_HAMMING 或 NORM_HAMMING2(orb.cpp:772-782),`descriptorSize()=kBytes=32`(orb.cpp:762-764)。边界约束 `border = max(edgeThreshold, max(ceil(halfPatch*sqrt2), HARRIS_BLOCK/2))+1` 显式考虑了旋转采样的越界(orb.cpp:1028-1031);每层采描述子前做 7x7 高斯模糊(orb.cpp:1214-1218);patchSize≠31 时改用固定种子 0x34985739 的随机模式(orb.cpp:641-649、1208-1211)。`ORB::create` 默认 500 点/1.2 倍/8 层/edge31/HARRIS_SCORE/patch31/FAST 阈 20(features2d.hpp:460-461)。

## 4. SIFT:DoG 尺度空间到 128 维描述子

主路径在 `SIFT_Impl::detectAndCompute`(sift.dispatch.cpp:501-560)。第一步 `createInitialImage`:灰度化并乘 `SIFT_FIXPT_SCALE`(浮点实现为 48,sift.simd.hpp:119-123);检测时 `firstOctave=-1` 触发 2x 放大——`enable_precise_upscale` 用 warpAffine 精确插值,否则 `resize`(sift.dispatch.cpp:195-207),再补一次方差为 `σ²-SIFT_INIT_SIGMA²*4`(上采样支,193 行)或 `σ²-SIFT_INIT_SIGMA²`(原分辨率支,216 行)的高斯模糊(211、218 行)。高斯金字塔的 σ 预算公式与逐层生成:

```cpp
// sift.dispatch.cpp:231-240(节选)
//  \sigma_{total}^2 = \sigma_{i}^2 + \sigma_{i-1}^2
sig[0] = sigma;
double k = std::pow( 2., 1. / nOctaveLayers );
for( int i = 1; i < nOctaveLayers + 3; i++ )
{
    double sig_prev = std::pow(k, (double)(i-1))*sigma;
    double sig_total = sig_prev*k;
    sig[i] = std::sqrt(sig_total*sig_total - sig_prev*sig_prev);
}
```

每 octave 底层由上一层第 `nOctaveLayers` 层半分辨率重采样(sift.dispatch.cpp:250-255),`buildDoGPyramid` 生成每 octave `nOctaveLayers+2` 层差分并 `parallel_for_` 并行(sift.dispatch.cpp:302-309)。极值检测与关键点定位在分发实现中(sift.dispatch.cpp:349 `CV_CPU_DISPATCH`;CMakeLists.txt:4 `ocv_add_dispatched_file(sift SSE4_1 AVX2 AVX512_SKX)`),核心是 DoG 上的 3x3x3 邻域极值 + 泰勒插值:

```cpp
// sift.simd.hpp:330-341(节选)
Matx33f H(dxx, dxy, dxs,
          dxy, dyy, dys,
          dxs, dys, dss);
Vec3f X = H.solve(dD, DECOMP_LU);
xi = -X[2]; xr = -X[1]; xc = -X[0];
if( std::abs(xi) < 0.5f && std::abs(xr) < 0.5f && std::abs(xc) < 0.5f )
    break;                                   // 至多 SIFT_MAX_INTERP_STEPS=5 步
```

随后三道过滤:对比度 `|contr|*nOctaveLayers < contrastThreshold`(sift.simd.hpp:372-374)、主曲率 trace/det 判据 `tr²*edgeThreshold >= (r+1)²*det`(sift.simd.hpp:382-386)、边界 5 像素(常量 SIFT_IMG_BORDER,sift.simd.hpp:93)。`kpt.octave` 把 `octave + layer<<8 + 亚像素层<<16` 打包,size = `σ·2^((layer+xi)/nOctaveLayers)·2^octave·2`(sift.simd.hpp:389-392)。方向直方图 36 bin、高斯 σ=1.5·尺度、半径 3σ、峰值 0.8 的次峰派生额外关键点(常量 sift.simd.hpp:99-108,直方图函数 160-235)。描述子为 4x4 cell x 8 bin:采样半径 `3σ·√2·(d+1)/2`,高斯权 `exp(-1/(2σ_d²))`(sift.simd.hpp:719-722),三线性插值写入直方图后归一化、0.2 截断(hysteresis)再归一化,按 512 缩放以便转 8 位(sift.simd.hpp:862-905);`descriptorSize()=4*4*8=128`,`defaultNorm()=NORM_L2`(sift.dispatch.cpp:485-498)。默认参数 `nOctaveLayers=3, contrastThreshold=0.04, edgeThreshold=10, sigma=1.6`(sift.dispatch.cpp:90-92),`create` 也接受 CV_8U 描述子变体(sift.dispatch.cpp:153-159)。检测后 `removeDuplicatedSorted` 去重、按 `nfeatures` 裁剪(sift.dispatch.cpp:552-556)。

版权与专利:文件头声明实现基于 Rob Hess 的代码,并注明 "Patent US6711293 expired in March 2020"(sift.dispatch.cpp:8-12),其下保留了 2004 年 Lowe 专利警告的完整原文(sift.dispatch.cpp:17-43)——即"历史警告仍在,但已带过期声明"。

## 5. 匹配:KeyPoint/DMatch、BFMatcher 与 batchDistance

`KeyPoint` 六字段 `pt/size/angle/response/octave/class_id` 定义在 core(不是 features2d 头)里,注释明确 `angle` 为 [0,360) 度、顺时针、size 是"有意义邻域的直径"(modules/core/include/opencv2/core/types.hpp:811-818,类声明 751-819);`DMatch` 四字段同样在 types.hpp(848-863)。匹配侧,`match()` 就是 `knnMatch(k=1, compactResult=true)` 再摊平(matchers.cpp:611-618);`knnMatch` 先 `checkMasks`、`train()` 再进虚函数 `knnMatchImpl`(matchers.cpp:647-661)。BFMatcher 的实质是把重活整体交给 core 的 `batchDistance`:

```cpp
// matchers.cpp:852-864(节选)
int dtype = normType == NORM_HAMMING || normType == NORM_HAMMING2 ||
    (normType == NORM_L1 && queryDescriptors.type() == CV_8U) ? CV_32S : CV_32F;
for( iIdx = 0; iIdx < imgCount; iIdx++ )
{
    batchDistance(queryDescriptors, trainDescCollection[iIdx], dist, dtype, nidx,
                  normType, knn, masks.empty() ? Mat() : masks[iIdx], update, crossCheck);
    update += IMGIDX_ONE;                    // IMGIDX_SHIFT=18,matchers.cpp:763
}
// matchers.cpp:886-887:
// mq.push_back( DMatch(qIdx, nidxptr[k] & (IMGIDX_ONE-1), nidxptr[k] >> IMGIDX_SHIFT, distptr[k]) );
```

即多训练图的 `imgIdx` 打包进 `nidx` 高位、低 18 位是 `trainIdx`(每张图描述子数须 <2^18,断言在 matchers.cpp:856、860)。`batchDistance` 本体在 `modules/core/src/batch_distance.cpp:265-386`:Hamming 走 `hal::normHamming`(popcount,batch_distance.cpp:103-140),`dtype` 缺省语义与 BFMatcher 一致(278-281);crossCheck 在函数内部实现,要求 K==1、无 mask,用两次互反调用求"互为最近":

```cpp
// batch_distance.cpp:301-313(节选)
if( crosscheck )
{
    CV_Assert( K == 1 && update == 0 && mask.empty() );
    batchDistance(src2, src1, tdist, dtype, tidx, normType, K, mask, 0, false);
    batchDistance(src1, src2, sdist, dtype, sidx, normType, K, mask, 0, false);
    // if nidx[idx] = i*, it means that idx-th element of src1 is the nearest
    // to i*-th element of src2 and i*-th element of src2 is the closest to
    // idx-th element of src1. If nidx[idx] = -1, ... no such ideal couple.
    // This O(2N) procedure is called cross-check ...
}
```

**ratio test 在匹配器里不存在**:matchers.cpp 全文检索 "ratio" 仅命中 "Corporation" 等版权行;Lowe 比值检验由用户在 `knnMatch(k=2)` 结果上自做(教程样例 samples/cpp/tutorial_code/features2D/feature_flann_matcher/SURF_FLANN_matching_Demo.cpp 即此写法)。匹配器名/枚举到实现的映射在 `DescriptorMatcher::create`:MatcherType 枚举 FLANNBASED=1..BRUTEFORCE_SL2=6(features2d.hpp:997-1005),字符串分支在 matchers.cpp:1013-1049("BruteForce-Hamming"→BFMatcher(NORM_HAMMING) 等),其中 "FlannBased" 分支包在 `#ifdef HAVE_OPENCV_FLANN` 内(matchers.cpp:1025-1031)。

## 6. FLANN 分发与绘制路径

features2d 对 flann 是 **OPTIONAL** 依赖(`ocv_define_module(features2d opencv_imgproc ... OPTIONAL opencv_flann ...`,modules/features2d/CMakeLists.txt:7),整段 FlannBasedMatcher 包在 `#ifdef HAVE_OPENCV_FLANN` 里(matchers.cpp:1096-1464)。`train()` 把多张训练描述子合并成 `DescriptorCollection` 后一次性建 `flann::Index`(matchers.cpp:1160-1175);`knnMatchImpl` 直接调 `flannIndex->knnSearch`,返回的平方距离要 `sqrt` 还原(matchers.cpp:1437-1425);mask 不支持(matchers.cpp:1384-1387),带训练数据的深拷贝 clone 因 flann::Index 无拷贝构造而明确抛未实现(matchers.cpp:1389-1395)。

flann 侧各类 `*IndexParams` 只是往字典里塞 `algorithm` 键,KDTreeIndexParams 默认 `trees=4`(modules/flann/include/opencv2/flann/miniflann.hpp:102)、SearchParams 默认 `checks=32`(miniflann.hpp:147),索引类型覆盖 Linear/Composite/KMeans/HierarchicalClustering/LSH/Autotuned(miniflann.cpp:206-280);AutotunedIndexParams 携带 `target_precision` 等参数,由运行期按采样自动选型与调参(miniflann.cpp:229-243)。flann 模块本体只是 core 的薄封装(modules/flann/CMakeLists.txt:3,`ocv_define_module(flann opencv_core WRAP python)`),索引模板全在头文件里。注意 LSH 索引不支持 radiusSearch(miniflann.cpp:664),二进制描述子配 FLANN 只能 knnSearch。

绘制:`draw_multiplier=16`(draw_shift_bits=4),所有坐标按 16 倍放大以保留亚像素(draw.cpp:44-45、56);`DRAW_RICH_KEYPOINTS` 画 `size/2` 半径圆与方向短线(angle=-1 不画),普通模式画 R=3 小圆(draw.cpp:53-89);`drawKeypoints` 默认铺白底再叠点(draw.cpp:91-110);`drawMatches` 按 `matchesMask` 过滤后逐对画连线并断言 query/train 下标合法(draw.cpp:206-248),另有 kNN 版重载(draw.cpp:255-279)。

## 7. 设计动机、纠偏、FAQ 与深挖

**设计动机(6 条)**:
1. 接口收敛:旧三大类(FeatureDetector/DescriptorExtractor/通用)合一,`detect`/`compute` 全部退化为 `detectAndCompute` 的包装,新增算法只需实现一个函数(feature2d.cpp:59-175)。
2. 类型决定度量:`descriptorType()=CV_8U → NORM_HAMMING` 的自动推导把"二进制描述子配汉明距离"编码进基类,防错配(feature2d.cpp:207-211)。
3. 速度分层:FAST 用查表+对跖点对短路+环形数组,把每像素最坏 16 次比较压到平均 3-4 次(fast.cpp:216-252);同一问题保留 HAL/OCL/AVX2/SIMD128/标量五级实现(fast.cpp:63-70、440-467)。
4. 旋转不变的最小代价:ORB 用亮度质心估角(一遍像素遍历)+ 最近邻旋转采样,避开 SIFT 级的梯度统计(orb.cpp:195-213、244-250)。
5. 匹配批处理:BFMatcher 不自写双重循环,统一走 `batchDistance`(top-K 堆与 crossCheck 都在里面),imgIdx 位打包省掉一层循环(matchers.cpp:852-893;batch_distance.cpp:265-386)。
6. 依赖最小化:FLANN 设为可选模块,无 flann 时 features2d 照常编译,只有 FlannBasedMatcher 缺席(CMakeLists.txt:7;matchers.cpp:1096)。

**纠偏清单(5 条,以本 commit 为准)**:
1. **SIFT 专利状态**:源码头注明专利 US6711293 已于 2020 年 3 月过期(sift.dispatch.cpp:12),SIFT 位于主仓库 features2d,与 `OPENCV_ENABLE_NONFREE` 无关(该开关仍在,但管的是其他非自由算法,CMakeLists.txt:196);"SIFT 在 contrib/xfeatures2d、要开 NONFREE"是旧版情况——迁移历史(4.4.0 移回主仓)因浅克隆未核实,现状可核实。
2. **ORB 的"旋转 BRIEF"没有独立实现位置**:就是 `computeOrbDescriptor` 的 `GET_VALUE` 宏按角度旋转采样点后 `cvRound` 取最近邻(orb.cpp:244-250),双线性版本被 `#if 1/#else` 禁用(orb.cpp:251-259);rBRIEF 模式是硬编码的学习结果 `bit_pattern_31_`(orb.cpp:380),非运行时学习,仅 patchSize≠31 才用固定种子随机生成(orb.cpp:641-649)。
3. **FAST 不是论文"先测 1/5/9/13 四点"的字面实现**:标量快速路径先比较正上/正下(pixel[0]|pixel[8]),再做三对斜点与全圆(fast.cpp:216-231),是工程等价而非论文原序;score 也不是梯度响应和,而是"最大可行阈值-1"(fast_score.cpp:203-209)。
4. **Lowe ratio test 不在 OpenCV 匹配器里**:BFMatcher 只有 crossCheck(batch_distance.cpp:301-313),ratio 检验是教程/用户层代码;`match()` 内部只是 knnMatch(k=1)(matchers.cpp:611-618)。
5. **ORB 最终响应不是 FAST 响应**:默认 HARRIS_SCORE 下 FAST 只出候选,Harris 重打分决定保留谁(orb.cpp:899、924-958);FAST 自身输出的关键点 size 恒为 7、angle=-1(fast.cpp:298),直接拿 FAST 当"检测器输出"时没有方向信息。

**FAQ 候选(10 条)**:
1. `detect` 与 `detectAndCompute` 什么关系?——前者就是 `detectAndCompute(image,mask,kps,noArray(),false)` 的包装(feature2d.cpp:70)。
2. FAST 的 response 含义?——让该点仍成立的最大阈值再减 1,越大越"尖"(fast_score.cpp:164、203-209)。
3. ORB 方向角如何得到?——亮度质心 m01/m10 的 `fastAtan2`,单位度(orb.cpp:213)。
4. rBRIEF 的 256 对点从哪来?——硬编码 `bit_pattern_31_`,patchSize=31 时不重新生成(orb.cpp:380、1206-1211)。
5. ORB 描述子为何是 32 字节?——256 次 `t0<t1` 比较、每字节 8 位,kBytes=32(orb.cpp:261-285、762-764)。
6. `knnMatch(k=2)` 内置 Lowe ratio 吗?——没有,匹配器只给 crossCheck,ratio 由用户自己做(见 §5)。
7. 多张训练图时 `imgIdx` 怎么来的?——由 nidx 高 18 位解包,低 18 位是 trainIdx(matchers.cpp:763、886-887)。
8. FlannBasedMatcher 默认索引?——`KDTreeIndexParams(trees=4)` + `SearchParams(checks=32)`(features2d.hpp:1296-1297;miniflann.hpp:102、147)。
9. 二进制描述子能用 FLANN 吗?——能,需换 `LshIndexParams`,且 LSH 不支持 radiusSearch(miniflann.cpp:664)。
10. SIFT 现在还要 NONFREE 开关吗?——不要,专利 2020 年 3 月已过期且实现就在主仓库(sift.dispatch.cpp:12)。

**深挖方向(5 条)**:
1. AGAST/OAST:agast.cpp/agast_score.cpp 的自适应阈值圆周检测与 FAST 的代码同构性、score 复用方式。
2. OpenCL 路径:ocl_FAST 与专用 NMS 核(fast.cpp:304-380)、ocl_ICAngles/ocl_HarrisResponses(orb.cpp:62-125)、ocl_knnMatch 仅支持 k=2 的原因(matchers.cpp:744-754)。
3. KAZE/AKAZE 与 BRISK:kaze/ 目录的非线性尺度空间、brisk.cpp 的采样模式旋转,与 ORB steering 方案对比。
4. 下游消费:calib3d/stitching 的 findHomography+RANSAC 如何过滤 DMatch;bagofwords.cpp 的 BOWTrainer/BOWImgDescriptorExtractor。
5. HAL 替换面:hal_replacement.hpp 的 `cv_hal_FAST`/`FAST_NMS` dense score 语义(fast.cpp:383-437,注意 response-1 约定与 threshold≤20 限制)。

## 8. 正文蒸馏要点

1. `FeatureDetector`/`DescriptorExtractor` 自 3.x 起就是 `Feature2D` 的 typedef,三类接口合一;`detect`/`compute` 都是 `detectAndCompute` 的包装,基类版直接抛未实现(features2d.hpp:227-235;feature2d.cpp:59-71、114-126、167-175)。
2. 距离度量由描述子类型推导:`CV_8U→NORM_HAMMING` 否则 `NORM_L2`(feature2d.cpp:207-211);ORB 的 WTA_K=3/4 覆盖为 `NORM_HAMMING2`(orb.cpp:772-782)。
3. FAST 判角:16 点圆环偏移表 + 三值查表对跖点对短路 + 环形数组连续弧 >9;NMS 为 3x3;关键点 size 恒 7、angle=-1(fast_score.cpp:52-80;fast.cpp:216-231、289-298)。
4. FAST score = "最大可行阈值-1"(fast_score.cpp:119-209);实现五级分发 HAL/OCL/AVX2/SIMD128/标量,HAL 限 threshold≤20(fast.cpp:440-488、383-437)。
5. ORB 检测端组合复用 `FastFeatureDetector`,逐层 FAST 后留 2 倍候选再以 7x7 Harris(K=0.04)重打分裁剪(orb.cpp:891-899、924-958)。
6. ORB 方向 = 亮度质心 `fastAtan2(m01,m10)`,umax 半宽表做过对称修正(orb.cpp:181-215、858-875)。
7. ORB 描述 = 学习模式 `bit_pattern_31_` 按角度旋转后 cvRound 最近邻采样,双线性分支被禁用;WTA_K 2/3/4 改变位编码与度量(orb.cpp:244-330、380)。
8. ORB 默认 500 点/1.2 倍/8 层/HARRIS_SCORE/patch31/FAST 阈 20;边界用 `sqrt(2)` 补偿旋转采样越界,采样前 7x7 高斯(features2d.hpp:460-461;orb.cpp:1028-1031、1214-1218)。
9. SIFT 主流程:2x 初始放大(firstOctave=-1 时)→ σ 平方累加的高斯金字塔 → DoG(parallel_for)→ 泰勒插值(≤5 步)+ 对比度 + trace/det 主曲率过滤 → 36 bin 方向、0.8 峰值派生 → 4x4x8 三线性直方图、0.2 截断、512 缩放(sift.dispatch.cpp:176-309、501-560;sift.simd.hpp:308-396、99-108、709-905)。
10. SIFT 默认 3 层/0.04/10/1.6,128 维 CV_32F(可 CV_8U),defaultNorm=NORM_L2;源码保留完整 Lowe 专利警告并注明 2020 年 3 月专利过期(sift.dispatch.cpp:90-92、485-498、8-12)。
11. KeyPoint/DMatch 定义在 core/types.hpp 而非 features2d 头;angle 为 [0,360) 顺时针、size 是直径(types.hpp:751-819、848-863);BFMatcher 委托 core `batchDistance`(Hamming=popcount,CV_32S 整数距离),imgIdx 打包在 nidx 高 18 位;crossCheck=双向互为最近(matchers.cpp:757-893;batch_distance.cpp:265-386);匹配器内没有任何 ratio test。
12. FlannBasedMatcher 可选编译(CMakeLists.txt:7;matchers.cpp:1096),train 时合并描述子建 `flann::Index`,knnSearch 返回平方距离需开方,不支持 mask 与深拷贝 clone;默认 KDTree(4 树)+checks=32,LSH 无 radiusSearch(matchers.cpp:1160-1175、1424、1384-1405;miniflann.hpp:102、147;miniflann.cpp:664)。
