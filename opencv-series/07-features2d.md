# 第 07 章 · features2d:统一 detectAndCompute 之下的三种速度

> 基线:commit `d3d247f1`(4.13.0-dev)。核心:modules/features2d/src/(fast.cpp / orb.cpp / sift.dispatch.cpp / matchers.cpp)。

## 7.0 全景:从图像到匹配点对

```
 图像灰度化
   ├ FAST:圆周16点比较+3x3 NMS(fast.cpp:216-299)──┐
   ├ ORB:金字塔FAST→Harris重打分→ICAngles方向      ├─ KeyPoint[](pt,size,angle,response,octave)
   │      +rBRIEF 旋转采样(orb.cpp:886-993,181-285)─┘
   └ SIFT:2x放大→高斯金字塔→DoG 极值→亚像素插值→方向直方图→4x4x8=128维
          (sift.dispatch.cpp:176-309; sift.simd.hpp:291-905)
                    │ Mat N×32(CV_8U)/N×128
                    ▼
   knnMatch(matchers.cpp:647)→ BFMatcher→batchDistance(Hamming=popcount)
                            → FlannBasedMatcher→flann::Index(KDTree/LSH/自动调优)
                    ▼
   vector<vector<DMatch>> ── ratio test 由用户自己做 ──► findHomography/drawMatches
```

纠偏:**Lowe ratio test 根本不在 OpenCV 匹配器里**——matchers.cpp 全文检索 "ratio" 只命中版权行;BFMatcher 只有 crossCheck(实现还在 core 的 batch_distance.cpp:301-313),"knnMatch 内置 ratio"是流传最广的误读,教程里都在用户代码层做。

## 7.1 统一抽象:一个接口三个入口

`Feature2D` 合并了旧检测器/提取器,`FeatureDetector/DescriptorExtractor` 只是 typedef(features2d.hpp:227-235);`detect/compute` 都是 `detectAndCompute` 的薄包装——基类实现内部不再走虚函数直接转调,子类只重写后者即同时获得三个入口(feature2d.cpp:59-70, 125)。距离度量按描述子类型自动推导:CV_8U→NORM_HAMMING,否则 NORM_L2(feature2d.cpp:207-211)。关键点的过滤/去重不在各算法里,统一在 `KeyPointsFilter::retainBest`(nth_element+partition 部分排序,keypoint.cpp:69-88)。

## 7.2 FAST:对跖点短路 + score 即"最大可行阈值"

逐像素判定先建三值查表(1 暗/2 亮/0 其他),再用四组对跖点对短路——上下两点既不亮也不暗直接排除(fast.cpp:214-231),通过后沿环形数组数连续弧,`count > patternSize/2` 即角点。NMS 是与上下两行共 8 邻居比 score(fast.cpp:289-299);**score 的定义是"把阈值加到多大该点不再是角点"再减 1**(SIMD 版 `threshold = v_reduce_max(q0) - 1`,fast_score.cpp:119-164)。patternSize 8/12/16 对应 TYPE_5_8/7_12/9_16,入口依次尝试 HAL→OpenCL→SIMD→标量(fast.cpp:440-467)。类包装默认 threshold=10、TYPE_9_16(features2d.hpp:586-588)。

## 7.3 ORB:组合而非重写

纠偏:ORB 检测端**就是组合复用** `FastFeatureDetector::create` 逐金字塔层调用(orb.cpp:891-894),候选先留 2 倍再按 7x7 Harris(K=0.04)重打分裁剪(orb.cpp:924-958)。方向用亮度质心:`angle = fastAtan2(m_01, m_10)`,umax 表做过等值修正(orb.cpp:195-213)。rBRIEF 的 256 对点是硬编码学习结果 `bit_pattern_31_`(orb.cpp:380);"旋转 BRIEF"没有独立实现——就是 GET_VALUE 宏按角度旋转采样点后 `cvRound` 取最近邻(orb.cpp:244-250),双线性插值版被 `#if 1/#else` 禁用(:251-259);patchSize≠31 才以固定种子 0x34985739 随机重生成模式(:641-649)。WTA_K=2 时每字节 8 次两两比较,defaultNorm 返回 NORM_HAMMING(orb.cpp:772-782)。

## 7.4 SIFT:专利已过期,警告仍保留

纠偏:sift.dispatch.cpp:8-12 明文 "Patent US6711293 expired in March 2020"——SIFT 在主仓库且与 `OPENCV_ENABLE_NONFREE` 无关(CMakeLists.txt:196),但 2004 年 Lowe 的专利警告原文仍完整保留在同文件 17-43 行:"历史警告仍在、已带过期声明"是可核实的表述。检测主路径:灰度化乘 SIFT_FIXPT_SCALE(浮点实现为 48,sift.simd.hpp:119-123),firstOctave=-1 触发 2x 放大再补 `σ²-σ₀²` 高斯(sift.dispatch.cpp:195-218),DoG 极值→亚像素插值→方向直方图→4x4x8 梯度直方图三线性插值+归一化截断(sift.simd.hpp:291-396, 709-905)。

## 7.5 匹配:距离计算全在 core

BFMatcher 的真正计算在 `batchDistance`(modules/core/src/batch_distance.cpp):Hamming 距离用 popcount 整数距离;crossCheck 是双向互为最近(:301-313)。FlannBasedMatcher 包装 flann::Index(KDTree/KMeans/LSH/Autotuned,可选模块)。DMatch 只有 queryIdx/trainIdx/imgIdx/distance 四字段——knnMatch 返回每查询点的 k 近邻,ratio 检验留给用户。

## 7.6 设计动机

1. **合并检测与提取**:一次 detectAndCompute 同时产出关键点与描述子,`useProvidedKeypoints` 支持复用外部关键点(features2d.hpp:196-199);
2. **FAST 对跖点短路**:O(1) 拒绝绝大多数非角点,整数比较无乘除(fast.cpp:214-231);
3. **ORB 组合复用**:检测用现成 FAST,描述子旋转采样内联进宏,无第二套实现(orb.cpp:891-894);
4. **score 语义统一**:"最大可行阈值-1"让 NMS 分数跨阈值可比(fast_score.cpp:119-164);
5. **KeyPointsFilter 集中**:裁剪/去重策略一处实现,所有算法共享(keypoint.cpp:69-88);
6. **匹配器不管 ratio**:匹配器只做距离排序,语义后处理留给管线(fundam 接棒)。

## 7.7 FAQ

**Q1:knnMatch 里有 ratio test 吗?**
没有,匹配器只算距离;ratio 是用户层惯例(matchers.cpp 全文核实)。

**Q2:ORB 的旋转 BRIEF 是独立实现吗?**
不是,GET_VALUE 宏旋转采样+取整(orb.cpp:244-250)。

**Q3:SIFT 还要 NONFREE 开关吗?**
不要,专利 2020-03 过期,警告原文仍在(sift.dispatch.cpp:8-12)。

**Q4:FAST 的 score 是什么?**
最大可行阈值-1,越大越稳(fast_score.cpp:119-164)。

**Q5:Hamming 距离在哪算?**
core 的 batchDistance,popcount(batch_distance.cpp:301-313)。

**Q6:描述子维度谁定?**
descriptorSize():ORB=32 字节(orb.cpp:762-764),SIFT=128 维。

**Q7:crossCheck 和 knnMatch 能同用吗?**
crossCheck 只支持 NORM_HAMMING/L2 一对一,与 knn 互斥语义。

**Q8:ORB 为什么先留 2 倍候选?**
Harris 重打分后再裁到目标数,防 FAST 响应排序偏置(orb.cpp:897-899)。

**Q9:patchSize≠31 的 ORB 用什么模式?**
固定种子 0x34985739 随机重生成(orb.cpp:641-649)。

**Q10:关键点去重在算法里吗?**
在 KeyPointsFilter 静态工具类,统一 nth_element(keypoint.cpp:69-88)。

## 7.8 小结与深挖方向

本章结论:**features2d=统一接口+三种速度档(FAST 对跖短路/ORB 组合复用/SIFT 尺度空间)+匹配与语义分离**。深挖:

1. retainBest 的 nth_element+partition 部分排序稳定性(keypoint.cpp:69-88);
2. SIFT 高斯 σ 预算公式与 octave 间下采样关系(sift.simd.hpp:119-230);
3. flann Autotuned 的参数搜索空间与 LSH 表数选择;
4. FAST HAL dense 路径 threshold≤20 的限制原因(fast.cpp:385);
5. drawMatches 的 DMatch 着色与 draw.cpp:206-248。
