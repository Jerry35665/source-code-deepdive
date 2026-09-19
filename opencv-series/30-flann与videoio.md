# 第 30 章 · flann 与 videoio:被裁剪的距离族与双预算捕获机

> 基线:commit `d3d247f1`(4.13.0-dev)。核心:modules/flann/src/miniflann.cpp(886 行)+ 头文件索引模板、modules/videoio/src/cap_ffmpeg_impl.hpp。

## 30.0 全景:flann 分层与距离裁剪

```
 miniflann 门面(cv::flann::Index,void* 类型擦除)
   └ 按距离编译期标签分发工厂(all_indices.h:59-156):
     向量空间距离(L2/L1)→ kd 树族可用;Hamming → Linear/KMeans/Hierarchical/LSH
 纠偏:dist.h 定义 14 个距离 functor,但 MINIFLANN_SUPPORT_EXOTIC_DISTANCE_TYPES=0
   把 Minkowski/Hellinger/ChiSquare/KL 等 7 种全部编译裁掉——门面只剩 L2/L1/HAMMING
 纠偏:CompositeIndexParams 名不副实——构造写入的 algorithm 键是 FLANN_INDEX_KMEANS,
   经 cv::flann::Index 建出来的是多树 KMeans;真 Composite(=3)只有 cvflann API 可达
   (miniflann.cpp:216)
```

且"FLANN 返回平方距离需开方"仅对 L2/L1 成立——**Hamming 输出 CV_32S 整数距离,FlannBasedMatcher 对它不做 sqrt**(matchers.cpp:1421-1424);LSH 索引还强制改写 distType 为 HAMMING(miniflann.cpp:409-412)。

## 30.1 KDTree/KMeans:随机化与 cb_index 折扣

KDTreeIndex 建 4 棵随机化 kd 树:节点切分从**方差最大的前 RAND_DIM=5 维中随机挑一维**,切分平面取该维均值(kdtree_index.h:311-399);检索 best-bin-first:贪心下行+分支按界入堆,受 checks 预算约束,explore_all_trees 先走完每棵树。KMeansIndex 是层次 k-means(branching=32/iterations=11):检索只进最近子树,其余按 `dist - cb_index·variance` **打折入堆**——cb_index 补偿"中心远但簇散"的子树(kmeans_index.h:1560-1596);checks=-1 时走三角不等式剪枝的真精确检索。

## 30.2 videoio:FFmpeg 双预算状态机

纠偏:**open 不解码首帧**——CvCapture_FFMPEG::open 只开 demuxer/decoder,首帧在首次 grab 才解码(cap_ffmpeg_impl.hpp:1046-1160);grabFrame 受 `OPENCV_FFMPEG_READ_ATTEMPTS=4096`/`DECODE_ATTEMPTS=64` 双预算约束,EOF 时塞空包冲刷解码器缓存。时间戳三步链:pts 优先→pkt_dts 兜底→减流 start_time 换算秒→帧号=fps×sec+0.5 反推;seek 是 delta=16 起步倍增的回退+前向补偿(:1595-1740, 2115-2225)。

## 30.3 设计动机

1. **miniflann 门面裁剪**: exotic 距离砍一半,把维护面收敛到三种常用距离(miniflann.cpp:3);
2. **编译期标签分发**:is_kdtree_distance 决定工厂分支与树内增量剪枝,错误组合直接编译不可达(all_indices.h:92-156);
3. **checks 预算**:近似检索的精度/耗时旋钮,跨树共享一个计数器;
4. **cb_index 折扣**:k-means 树的边界模糊补偿机制内建于检索;
5. **惰性首帧**:open 只搭管线,首帧成本推迟到 grab(cap_ffmpeg_impl.hpp:1046);
6. **双预算防死循环**:坏流在 4096/64 次尝试内必然退出。

## 30.4 FAQ

**Q1:flann 有几种距离可用?**
门面只有 L2/L1/HAMMING 三种;其余 7 种被编译裁掉(miniflann.cpp:3)。

**Q2:CompositeIndexParams 建的是什么?**
多树 KMeans,不是真 Composite(miniflann.cpp:216)。

**Q3:Hamming 距离要开方吗?**
不要,输出 CV_32S 整数;平方距离仅 L2/L1(matchers.cpp:1421-1424)。

**Q4:kd 树切分维怎么选?**
方差最大前 5 维随机挑一,平面取均值(kdtree_index.h:311-385)。

**Q5:cb_index 是什么?**
k-means 树检索时次优分支的入堆折扣系数(kmeans_index.h:1560-1596)。

**Q6:VideoCapture.open 解码第一帧吗?**
不,首帧推迟到首次 grab(cap_ffmpeg_impl.hpp:1046-1160)。

**Q7:坏流会卡死吗?**
不会,READ_ATTEMPTS=4096/DECODE_ATTEMPTS=64 双预算。

**Q8:LSH 用什么距离?**
强制 HAMMING(miniflann.cpp:409-412)。

**Q9:radiusSearch 支持批量查询吗?**
不支持,query.rows!=1 直接报错(nn_index.h:103-108)。

**Q10:seek 怎么补偿误差?**
delta=16 起步倍增回退+前向逐帧补偿(:2115-2225)。

## 30.5 小结与深挖方向

本章结论:**flann=模板索引族+门面裁剪+checks 预算近似检索;videoio=后端分发+FFmpeg 惰性解码与双预算状态机**。深挖:

1. AutotunedIndex 的参数搜索成本模型(autotuned_index.h);
2. LshIndex 的多表参数与召回率关系(lsh_index.h);
3. Hamming2 的 SWAR 实现与 DNAmming 家族(dist.h);
4. MSMF/V4L2 后端与 FFmpeg 后端的 open 语义差异(modules/videoio/src/cap_*.cpp);
5. OPENCV_FFMPEG_CAPTURE_PARAMS 环境变量的编解码器透传。
