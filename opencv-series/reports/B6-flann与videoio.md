# 报告 B6 · flann 与 videoio(OpenCV 卷三)

> 基线:d3d247f1(4.13.0-dev,gitee 镜像)。本章承接卷一 04(FFmpeg 宏减震器)与卷二 07(features2d 只带过 FlannBasedMatcher),逐行核实 modules/flann 的近邻索引族与 modules/videoio 的后端分发机、FFmpeg open/close/read 状态机与时间戳。注册表优先级(1000-i*10、三张投影表、环境变量重排)已在卷一 D 报告核实,本章只引用不重复。所有行号均以本 commit 检出为准。

## 1. flann 分层:miniflann 门面 + 头文件模板 + 工厂分发

flann 模块只有两个 .cpp:flann.cpp(56 行,仅剩已废弃的全局距离开关)与 miniflann.cpp(886 行,全部公开实现)。八种索引模板全在头文件 modules/flann/include/opencv2/flann/ 下,真实类名核实为:`LinearIndex`、`KDTreeSingleIndex`、`KDTreeIndex`、`KMeansIndex`、`CompositeIndex`、`HierarchicalClusteringIndex`、`LshIndex`、`AutotunedIndex`(all_indices.h:60-83)。`NNIndex<Distance>` 是唯一抽象基类(buildIndex/knnSearch/radiusSearch/findNeighbors/saveIndex/loadIndex 等纯虚入口,nn_index.h:59-173);`cvflann::Index<Distance>`(flann_base.hpp:116-190)是运行期包装,按 params["algorithm"] 调 `create_index_by_type` 实例化具体索引,FLANN_INDEX_SAVED 时从文件反查类型载入(flann_base.hpp:125-133)。

工厂按距离的**编译期标签**裁剪候选:向量空间距离(L2/L1 等,`is_kdtree_distance=True`)可建 kd 树族;Hamming 只能建 Linear/KMeans/Hierarchical/LSH——`index_creator` 存在 `False` 特化版本,其中根本没有 KDTree 分支(all_indices.h:92-148),分发键是两个标签类型(:150-156)。

```
// modules/flann/include/opencv2/flann/all_indices.h:59-88(节选)
switch (index_type) {
case FLANN_INDEX_LINEAR:        nnIndex = new LinearIndex<Distance>(...); break;
case FLANN_INDEX_KDTREE_SINGLE: nnIndex = new KDTreeSingleIndex<Distance>(...); break;
case FLANN_INDEX_KDTREE:        nnIndex = new KDTreeIndex<Distance>(...); break;
case FLANN_INDEX_KMEANS:        nnIndex = new KMeansIndex<Distance>(...); break;
case FLANN_INDEX_COMPOSITE:     nnIndex = new CompositeIndex<Distance>(...); break;
case FLANN_INDEX_AUTOTUNED:     nnIndex = new AutotunedIndex<Distance>(...); break;
case FLANN_INDEX_HIERARCHICAL:  nnIndex = new HierarchicalClusteringIndex<Distance>(...); break;
case FLANN_INDEX_LSH:           nnIndex = new LshIndex<Distance>(...); break;
default: FLANN_THROW(cv::Error::StsBadArg, "Unknown index type");
}
```

公开 API `cv::flann::Index`(miniflann.hpp:150-191)用 `void* index` 类型擦除,内部靠 distType 三分支重复分发;另有模板类 `cv::flann::GenericIndex<Distance>`(flann.hpp:170 起)支持任意距离,旧 `Index_<T>` 已 CV_DEPRECATED(flann.hpp:433-436)。基类 knnSearch 用去重的 `KNNUniqueResultSet`,结果 `sorted` 默认 true(nn_index.h:84-90);radiusSearch 只允许单条查询(query.rows!=1 直接报错,nn_index.h:103-108);miniflann 侧 `CV_Assert((size_t)knn <= index_->size())` 禁止 k 超过数据集规模(miniflann.cpp:521)。

## 2. dist.h 距离体系:14 个 functor,门面只放行 3 个

dist.h(1292 行)定义 14 个距离 functor:L2_Simple(:206)、L2(:240)、L1(:306)、Minkowski(:364)、MaxDistance(:429)、HammingLUT(:487)、Hamming(:548)、Hamming2(:656)、DNAmmingLUT(:751)、DNAmming2(:809)、HistIntersection(:903)、Hellinger(:959)、ChiSquare(:1009)、KL_Divergence(:1064)。三个机制贯穿全文件:(a) `Accumulator` 把整型元素累加器提升为 float,防溢出(:129-141);(b) L2 是**平方**欧氏距离,4 路循环展开、带 `worst_dist` 早退,注释明言"computation of squared root at the end is omitted"(:266-278),`accum_dist` 同样返回平方(:293-299);(c) `is_kdtree_distance`/`is_vector_space_distance` 两个 True/False 标签既决定 §1 的工厂分支,也决定树内能否用 accum_dist 做增量剪枝。

但 miniflann.cpp 第一行 `#define MINIFLANN_SUPPORT_EXOTIC_DISTANCE_TYPES 0`(:3)把 Minkowski/Max/HistIntersect/Hellinger/ChiSquare/KL/DNAMMING 七种距离的 build/knnSearch/radiusSearch/save/load 分支全部编译裁掉——经 cv::flann::Index 实际可用的只有 `FLANN_DIST_L2`、`FLANN_DIST_L1`、`FLANN_DIST_HAMMING` 三种。LSH 索引还会强制改写 distType 为 HAMMING(:409-412)。Hamming 距离下输出矩阵 dtype 是 CV_32S,其余为 CV_32F(:610-611);CV_NEON 平台上 Hamming 实现选 `Hamming<uchar>` 而非 HammingLUT(:364-368)。

```
// modules/flann/src/miniflann.cpp:409-447(节选)
if ( algo == FLANN_INDEX_LSH) distType = FLANN_DIST_HAMMING;   // LSH 强制汉明
switch( distType )
{
case FLANN_DIST_HAMMING:
    buildIndex< HammingDistance >(index, data, params); break;
case FLANN_DIST_L2:
    buildIndex< ::cvflann::L2<float> >(index, data, params); break;
case FLANN_DIST_L1:
    buildIndex< ::cvflann::L1<float> >(index, data, params); break;
#if MINIFLANN_SUPPORT_EXOTIC_DISTANCE_TYPES   // =0:Minkowski/Hellinger/KL 等 7 种全裁掉
#endif
default:
    CV_Error(Error::StsBadArg, "Unknown/unsupported distance type");
}
```

## 3. KDTreeIndex:随机化多树与 checks 预算

KDTreeIndex(kdtree_index.h,636 行)建 `trees` 棵(miniflann 默认 4,miniflann.hpp:102)随机化 kd 树。每个节点:对当前样本集逐维算均值与平方和方差(kdtree_index.h:311-341)→`selectDivision` 从**方差最大的前 RAND_DIM=5 维中随机挑一维**(:358-385,常量定义 :584)→切分平面取该维均值,`planeSplit` 双向分区并保证空子树时对半退化(:388-399)。检索是 best-bin-first:每棵树贪心下行,分支按下界距离入堆,受 `checks` 预算约束;跨树叶子去重靠 `DynamicBitset checked`;`explore_all_trees=true` 时先完整走完每棵树再处理堆(:460-530)。`searchLevel` 中另一分支入堆条件是 `new_distsq*epsError < worstDist || !result.full()`(:516-521),eps 由此生效。

```
// modules/flann/include/opencv2/flann/kdtree_index.h:311-341(节选)
memset(mean_,0,veclen_*sizeof(DistanceType));   // 随后逐维累加并除以 cnt 得均值
/* Compute variances (no need to divide by count). */
for (int j = 0; j < cnt; ++j) {
    ElementType* v = dataset_[ind[j]];
    for (size_t k=0; k<veclen_; ++k) {
        DistanceType dist = v[k] - mean_[k];
        var_[k] += dist * dist;
    }
}
cutfeat = selectDivision(var_);   // 前 RAND_DIM=5 大方差维随机挑一(:584)
cutval = mean_[cutfeat];          // 切分平面 = 该维均值
```

## 4. KMeansIndex、Hierarchical 与"不可达"的 Composite

KMeansIndex(kmeans_index.h,1819 行)是层次 k-means 树:miniflann 参数默认 branching=32、iterations=11、centers_init=RANDOM(miniflann.hpp:130-133)、cb_index 构造默认 0.2;索引内部若参数缺失则 cb_index 兜底 0.4(kmeans_index.h:375)。初始中心支持 Random(带重复中心检测,:120-155)/Gonzales(:161-210)/KMeanspp(:212 起),按参数选绑定(:364-370)。检索同 KDTree 的堆式预算:每层算 query 到各子中心距离,只进最近子树,其余子树按 `dist - round(cb_index*variance)` 折扣入堆(:1560-1596)——cb_index 补偿"中心远但簇散(边界模糊)"的子树。`checks=-1`(FLANN_CHECKS_UNLIMITED)时改走 `findExactNN`:用 `(bsq-rsq-wsq)² > 4*rsq*wsq` 三角不等式剪枝的真精确检索(:529-531、1633-1642),并按中心距离排序逐子树递归。Hamming 距离有专用 `computeBitfieldNodeStatistics` 位直方图求中心(:830-878)。

HierarchicalClusteringIndex 是 KMeans 的多树变体(branching/centers_init/trees=4/leaf_size=100,miniflann.hpp:124-127),findNeighbors 同样 checks 预算 + explore_all_trees(hierarchical_clustering_index.h:528-552),卷二已记它为二进制描述子的树形选项。CompositeIndex(composite_index.h)只是"KMeansIndex+KDTreeIndex 各建一份、findNeighbors 先后写同一 ResultSet"(:175-179)——但见 §10 纠偏 1,它经 miniflann 门面实际不可达。

```
// modules/flann/include/opencv2/flann/kmeans_index.h:1580-1595(节选)
for (int i=0; i<branching_; ++i) {
    domain_distances[i] = distance_(q, node->childs[i]->pivot, veclen_);
    if (domain_distances[i]<domain_distances[best_index]) best_index = i;
}
for (int i=0; i<branching_; ++i) {
    if (i != best_index) {
        // 次优分支按"距离 - cb_index*方差"打折入堆
        domain_distances[i] -= cvflann::round<DistanceType>(
                                cb_index_*node->childs[i]->variance );
        heap->insert(BranchSt(node->childs[i],domain_distances[i]));
    }
}
```

## 5. 精确族、LSH 与 AutotunedIndex

KDTreeSingleIndex(kdtree_single_index.h):单棵带包围盒的 kd 树,建完后把数据按 vind_ 顺序**重排进连续 data_ 数组**(:117-127),节点记录 divlow/divhigh 区间,切维用 middleSplit_;`findNeighbors` 只读 eps、**没有 checks 预算**——纯 bbox 剪枝的精确检索(:242-248)。LinearIndex:buildIndex 空函数,findNeighbors 对全库逐一算距离,searchParams 完全被忽略(:95-111),唯一"永远精确、零参数"的索引。

LshIndex(lsh_index.h):参数在实现内兜底默认 table_number=12、key_size=20、multi_probe_level=2(:100-102),但 miniflann 的 `LshIndexParams` 三参**无默认值**、必须显式给(miniflann.hpp:136)。buildIndex 就是"建 table_number 张随机哈希表 + add 全库"(:115-127);multi-probe 用 xor 掩码枚举翻每位附近的邻近桶(:239-252);检索内层对桶内候选逐一算汉明距离(:278-300)。两个坑:saveIndex 只存参数与数据集、loadIndex 重新建表(:133-158);检索使用 `static` 局部 `score_index_heap` 缓冲(:271),同一索引的并发检索并不可靠。另 LSH 被禁止 radiusSearch(miniflann.cpp:663-664)。

AutotunedIndex(autotuned_index.h):buildIndex = 网格调参 + 建最优索引 + 调搜索参数(:105-123)。候选网格写死:KMeans iterations{1,5,10,15}×branching{16,32,64,128,256} 共 20 组(:332-333),KDTree trees{1,4,8,16,32} 共 5 组(:375-383);每组在 `sample_fraction`(默认 0.1)采样的子集上建索引,用 ground truth 测达到 target_precision(默认 0.8)所需 checks,代价 `(buildTime*build_weight + searchTime)/bestTime + memory_weight*memoryCost`(:462-476);胜者是 KMeans 时再扫 cb_index 0→1.0(步长 0.2)与最优 checks(:521-530)。saveIndex 存 **bestIndex 的类型+数据+checks**(:134-138),载入后 autotuned 身份消失——文件里只有胜者。SearchParams 缺省 checks=-2(FLANN_CHECKS_AUTOTUNED)时 findNeighbors 委托 bestSearchParams_(declarations :161-170)。

```
// modules/flann/include/opencv2/flann/lsh_index.h:133-148(节选)
void saveIndex(FILE* stream) CV_OVERRIDE
{
    save_value(stream,table_number_);
    save_value(stream,key_size_);
    save_value(stream,multi_probe_level_);
    save_value(stream, dataset_);      // 只存参数+数据
}
void loadIndex(FILE* stream) CV_OVERRIDE
{
    load_value(stream, table_number_); ... load_value(stream, dataset_);
    // Building the index is so fast we can afford not storing it
    buildIndex();                      // 载入即重建哈希表
}
```

## 6. 与 features2d 的衔接:FlannBasedMatcher 全链条

卷二 07 只带到"train 时建 Index、平方距离需开方",本节补全链条(matchers.cpp:1096-1464,整体包在 `#ifdef HAVE_OPENCV_FLANN` 内):(a) `train()` 在 `!flannIndex || mergedDescriptors.size() < addedDescCount` 时把多图描述子合并进 DescriptorCollection 后**整体重建** flann::Index——增量 add 没有增量插入,代价是全量重训(:1160-1174);(b) `knnMatchImpl` 调 `flannIndex->knnSearch` 后由 `convertToDMatches` 把扁平下标经 `getLocalIdx` 还原成 (imgIdx,trainIdx),**CV_32S 分支(Hamming)直接 cast,CV_32F 分支(L2/L1)才 sqrt**(:1407-1442);(c) `radiusMatchImpl` 逐行调 radiusSearch,传入 `maxDistance*maxDistance`——再次印证 L2 是平方距离(:1444-1458);(d) mask 不支持(:1384-1386),带训练数据的深拷贝 clone 明确 CV_Error,因 flann::Index 无拷贝构造(:1389-1397)。序列化:FileStorage 以 name/type/value 三元组存参数,靠 `IndexParams::getAll` 的逐类型 cast 试探(miniflann.cpp:91-196);索引文件头签名 `"FLANN_INDEX"` + 数据类型/维度(saving.h:40-43、88-118),载入要求传入数据集尺寸与类型完全一致(miniflann.cpp:825-831),索引与数据**必须成对保存**。

```
// modules/features2d/src/matchers.cpp:1407-1427(节选)
void FlannBasedMatcher::convertToDMatches(...)
{
    int idx = indices.at<int>(i, j);
    if( idx >= 0 )
    {
        int imgIdx, trainIdx;
        collection.getLocalIdx( idx, imgIdx, trainIdx );
        float dist = 0;
        if (dists.type() == CV_32S)
            dist = static_cast<float>( dists.at<int>(i,j) );   // Hamming:整数原样
        else
            dist = std::sqrt(dists.at<float>(i,j));            // L2/L1:平方开方
        matches[i].push_back( DMatch( i, trainIdx, imgIdx, dist ) );
    }
```

## 7. videoio 分发机:窄接口、三张表与 grab/retrieve

C++ 后端契约只有 6 个可覆写点:`IVideoCapture{getProperty,setProperty,grabFrame,retrieveFrame,isOpened,getCaptureDomain}`(cap_interface.hpp:213-223),Writer 侧同理(:225-234)。FFmpeg 代理类继承的 `VideoCaptureBase` 是横切增强层:管理 `CAP_PROP_ORIENTATION_AUTO`,按旋转元数据交换宽高、在 retrieveFrame 成功后原地 `cv::rotate`(cap_interface.hpp:247-324)——"自动转正"在通用包装层而非各后端。参数袋 `VideoParameters` 是 (key,value) 平铺对,读即标记 isConsumed,事后可列出未消费项(cap_interface.hpp:57-199)。

`VideoCapture::open` 三条平行路径:文件(cap.cpp:120-240)、相机(:372-503)、IStreamReader 流(:242-365,禁用 CAP_ANY 防止逐后端尝试重置流);三者从注册表取各自投影表逐一尝试,后端异常默认吞掉继续下一个,只有 `throwOnFail` 且钉死非 CAP_ANY 后端时才在 catch 内重抛(:171-197),全局失败在函数尾统一抛(:221-224)。相机编号的**百位数字隐含后端**(:381-390)。`read()` 就是 `grab()+retrieve()`,返回 `!image.empty()`(:554-565);`operator>>` 走同一路径(WinRT 分支除外);多路同步 `waitAny` 仅 V4L 后端实现(:646-655)。`VideoWriter::open` 同构遍历 writer 表(cap.cpp:722-820,后端名单见卷一 D),并逐个报告 `getUnused()` 的无效参数(:756-764)。

```
// modules/videoio/src/cap.cpp:381-390(节选)
if (apiPreference == CAP_ANY)
{
    // interpret preferred interface (0 = autodetect)
    int backendID = (cameraNum / 100) * 100;   // 百位数字即后端 ID
    if (backendID)
    {
        cameraNum %= 100;
        apiPreference = backendID;             // open(700+n) == open(n, CAP_DSHOW)
    }
}
```

```
VideoCapture::open("a.mp4" | 0 | stream, apiPreference, params)   cap.cpp:120/372/242
  │  已打开则先 release;params 打包成 VideoParameters(key,value + isConsumed)
  ▼
videoio_registry::getAvailableBackends_CaptureByFilename/Index/Stream  ←三张投影表
  │  (静态 builtin 表按 1000-i*10 排序、环境变量可重排——卷一 D 已核实)
  ▼
for info in backends:  apiPreference==CAP_ANY 或 ==info.id ?
  │
  ├─ info.backendFactory->getBackend()   ← 静态工厂(内置)或插件工厂(dll/so)
  ▼
backend->createCapture(filename | index | stream, parameters)
  │  异常?→ 记 WARNING,继续下一个后端(throwOnFail 且钉死后端才重抛)
  ▼
icap->isOpened()? ──否──► release();尝试下一个后端
  │是
  ▼
read(img) = grab() + retrieve()                      cap.cpp:554-565
  grab()    → IVideoCapture::grabFrame()    只推进解码,不拷像素
  retrieve()→ VideoCaptureBase 先查旋转元数据,再 retrieveFrame_(channel,img)
              FFmpeg: UMat 先试 retrieveHWFrame 零拷贝;否则 sws_scale→BGR24 后 Mat 拷贝
```

## 8. FFmpeg 状态机:open 不解码,grab 双循环,时间戳三步换算

`CvCapture_FFMPEG::open`(cap_ffmpeg_impl.hpp:1046-1160)只做参数消费(CONVERT_RGB、FORMAT=-1 即 rawMode、HW 加速、N_THREADS、`OPENCV_FFMPEG_CAPTURE_OPTIONS` 字典)、avformat_open_input/找流/开解码器——**首帧不在 open 时解码**,open 成功不代表首帧可用;`seek` 里也特意"若还没 grab 过任何帧,先 grabFrame 采首帧信息"(:2168-2171)。`grabFrame`(:1595-1740)是双计数状态机:读包循环受 `OPENCV_FFMPEG_READ_ATTEMPTS`(默认 4096)约束(跳过音频等非视频流),解码循环受 `OPENCV_FFMPEG_DECODE_ATTEMPTS`(默认 64)约束(:1603-1604);新 API 下 send/receive 分离,AVERROR(EAGAIN) 继续收(:1619-1701);读到 AVERROR_EOF 时塞空包冲刷解码器缓存帧(:1643-1652)。时间戳三步:取帧时 picture pts 非 NOPTS/非 0 则用 pts,否则退 pkt_dts(:1705-1715);换算统一到帧率时基,首帧 dts 记为 `dts_delay_in_fps_time_base`(:1722-1725);`CAP_PROP_POS_MSEC = dts_to_sec(pts)*1000`,而 `dts_to_sec = (dts - stream.start_time)*time_base`(:1976-1981、2121-2125),`POS_FRAMES` 返回内部 frame_number,它由 `dts_to_frame_number = fps*sec + 0.5` 从时间戳反推(:2115-2119)。fps 取 avg_frame_rate,失败退 av_guess_frame_rate、再退 1/time_base(:2081-2102)。

```
// modules/videoio/src/cap_ffmpeg_impl.hpp:1638-1701(压缩节选)
while (!valid) {
    int ret = av_read_frame(ic, &packet);                 // EAGAIN 则重试
    if (ret == AVERROR_EOF) { ... 塞空包冲刷解码器缓存帧 ... }
    if( packet.stream_index != video_stream ) {           // 音频等其他流
        if (++cur_read_attempts > max_read_attempts) break;   // READ_ATTEMPTS=4096
        continue;
    }
    if (rawMode) { valid = processRawPacket(); break; }   // CAP_PROP_FORMAT=-1 直通包
    avcodec_send_packet(context, &packet);                // USE_AV_SEND_FRAME_API
    ret = avcodec_receive_frame(context, picture);
    if (ret >= 0) valid = true;
    else if (ret == AVERROR(EAGAIN)) continue;            // 一个包可能出多帧
    else if (++cur_decode_attempts > max_decode_attempts) break;  // DECODE_ATTEMPTS=64
}
```

retrieveFrame(:1742-1900)三层:rawMode 或 extradata 通道直接返回包字节(:1747-1765);硬解帧先 `av_hwframe_transfer_data` 拷回系统内存(:1768-1777);常规路径 sws_scale 转 BVR24(convertRGB=true),sws 上下文带线程数缓存重建(:1808-1871)。seek(:2160-2225)按帧号回退:初始 delta=16 帧、`AVSEEK_FLAG_BACKWARD` 对齐关键帧,不中则 ×2/×1.5 倍增重试,命中后逐帧 grab 前进;raw 模式用 rawSeek 标志一次跳过下次 grab(:2189-2193)。setProperty 仅支持 POS_MSEC/POS_FRAMES/POS_AVI_RATIO/FORMAT(-1→setRaw)/CONVERT_RGB 五项(:2232-2259)。Writer 侧 `writeFrame`(:2641-2786):pts 直接取 frame_idx(合成流无真实时钟,:2777-2783),容忍 AVERROR(EAGAIN)(:2772);SIMD 越界读防护的 32 字节 step 对齐拷贝(:2676-2710);raw 封装模式(encode_video=false)走 `icv_av_encapsulate_video_FFMPEG` 直填包并按 idr_period 补关键帧(:2641-2648)。

## 9. 源码地图(复核用行号索引)

- flann 门面:miniflann.cpp:3(距离裁剪开关)、199-311(params 构造)、331-356(build 模板)、388-448(build 分发)、604-649(knnSearch)、651-693(radiusSearch,LSH 拒绝 :663-664)、721-767(save)、792-882(load)
- 索引骨架:nn_index.h:59-173;工厂 all_indices.h:48-156;cvflann::Index 包装 flann_base.hpp:88-190;枚举 defines.h:70-170
- KDTreeIndex:kdtree_index.h:123-140(建树循环)、311-399(均值/方差切分)、460-530(检索)
- KMeansIndex:kmeans_index.h:110-370(初始化中心)、521-556(findNeighbors)、1560-1642(折扣入堆/精确检索)
- LSH:lsh_index.h:100-127、133-158、195-345;Autotuned:autotuned_index.h:75-175、240-340、456-530
- FlannBasedMatcher:matchers.cpp:1096-1200(train/read)、1384-1464(clone/match)
- VideoCapture:cap.cpp:49-63(调试环境变量)、115-240(文件 open)、242-365(流 open)、372-503(相机 open)、505-656(isOpened/get/grab/retrieve/read/waitAny)
- VideoWriter:cap.cpp:663-897(open 遍历、getUnused 告警、fourcc)
- 接口:cap_interface.hpp:57-199(VideoParameters)、213-234(IVideoCapture/IVideoWriter)、247-324(VideoCaptureBase autorotate)
- FFmpeg 捕获:cap_ffmpeg.cpp:68-190(代理);cap_ffmpeg_impl.hpp:1046-1160(open)、1595-1740(grabFrame)、1742-1900(retrieveFrame)、1970-2125(属性/换算)、2160-2259(seek/setProperty)
- FFmpeg 写:cap_ffmpeg.cpp:194-262(Writer 代理);cap_ffmpeg_impl.hpp:2641-2786(writeFrame)、2865 起(close)、2978 起(open)

## 10. 纠偏:以本 commit 源码为准

1. **"CompositeIndexParams 建 Composite 索引"是错的**:其构造函数写入的 algorithm 键是 `FLANN_INDEX_KMEANS`(miniflann.cpp:216),所以经 cv::flann::Index 建出来的是**多树 KMeansIndex**;真正的 CompositeIndex(FLANN_INDEX_COMPOSITE=3)只有走 flann_base.hpp 的 cvflann API 才能创建。
2. **"FLANN 支持十来种距离"对 OpenCV 用户不成立**:dist.h 确有 14 个 functor,但 `MINIFLANN_SUPPORT_EXOTIC_DISTANCE_TYPES=0`(miniflann.cpp:3)把 Minkowski/Hellinger/ChiSquare/KL 等全裁掉,门面只剩 L2/L1/Hamming;想要 Hellinger 匹配只能用 GenericIndex 自配距离或走 BFMatcher。
3. **"FLANN 返回平方距离"只对 L2/L1 成立**:Hamming 返回整数汉明距离,输出矩阵是 CV_32S(miniflann.cpp:610-611),FlannBasedMatcher 对它不做 sqrt(matchers.cpp:1421-1424);"开方"是 L2 专属步骤。
4. **"kd-tree 索引是精确检索"是误解**:KDTreeIndex/KMeansIndex/Hierarchical 都是 checks 预算下的近似检索;checks=-1 才是 KMeans 的精确模式(kmeans_index.h:529-531)。默认参数下真正精确的只有 LinearIndex(暴力,搜索参数被无视)与 KDTreeSingleIndex(bbox 剪枝、无预算)。
5. **"LSH 索引能 save/load"要打折扣**:存盘只有参数+数据,加载即重建哈希表(lsh_index.h:133-158);检索用 static 堆缓冲(:271)使并发检索不可靠;radiusSearch 被显式禁止(miniflann.cpp:663-664)。
6. **"open 返回 true 就能立刻拿到第一帧"对 FFmpeg 不严格成立**:open 不解码首帧,首次 grab 才推进解码;且 `open(700+n)` 这类百位编号直接钉死 DSHOW(cap.cpp:381-390)——CAP_ANY 自动回退并不覆盖所有写法。

## 11. 设计动机

1. **模板全在头文件 + 门面用 void* 类型擦除**:flann 需要被 Python 等绑定(CV_WRAP)且避免为每种 (索引×距离) 组合导出符号;类型擦除让一份 miniflann.cpp 覆盖全部实例化(miniflann.hpp:150-191),代价是 distType 三分支样板在 build/knn/radius/save/load 五处重复。
2. **距离 functor 带 is_kdtree_distance 标签**:kd 树依赖"部分距离可累积"(accum_dist)剪枝,Hamming 天然不满足;编译期标签让工厂直接少掉不合法分支,把"二进制描述子配 KDTree"从运行期错误变成编译期不可表达(all_indices.h:150-156)。
3. **用 checks 而非时间做近似预算**:checks(检查叶子/点数)确定、可复现、与机器速度无关,使 AutotunedIndex 能用"达到 target_precision 所需 checks"跨结构横向比较(autotuned_index.h:240-258)。
4. **grab/retrieve 拆分**:相机多通道(depth+rgb)、raw 包模式(FORMAT=-1 时 grab 产出 packet、retrieve 返回字节或 extradata)以及 waitAny 多路就绪检查,都要求"推进"与"取像素"可分别调用(cap.cpp:554-565;cap_ffmpeg_impl.hpp:1747-1765)。
5. **6 虚函数窄接口 + VideoCaptureBase 增强层**:窄接口让 30 余个后端接入门槛最低;旋转转正这类与后端无关的横切逻辑收进包装基类,避免在 cap_msmf/cap_ffmpeg/cap_v4l 里各抄一份(cap_interface.hpp:247-324)。
6. **FFmpeg seek 采用"回退关键帧 + 前向补偿"**:demuxer 只能对齐关键帧,delta=16 起步倍增在"回退太多逐帧前进"与"回退不够重试"间自动平衡;首帧信息采集也搭车这次 grab(cap_ffmpeg_impl.hpp:2160-2225)。
7. **Writer 的 pts=frame_idx**:写出的文件没有外部时钟,fps 是唯一时间基准,单调帧号即可满足编码器;真实时间戳场景才由上层显式处理。

## 12. FAQ

1. `cv::flann::Index` 与 `GenericIndex<Distance>` 什么关系?——前者是 CV_WRAP 的类型擦除版(仅 L2/L1/Hamming,miniflann.hpp:150),后者是模板版支持任意距离(flann.hpp:170);旧 `Index_<T>` 已废弃并打印迁移提示(flann.hpp:436-458)。
2. 参数如何传进模板索引?——全走字符串字典 `IndexParams`(any 包装),构造函数只是塞键(miniflann.cpp:199-311),索引内部 `get_param<T>("key",default)` 读取,拼错键名不会报错而是落回默认值。
3. `SearchParams(checks,eps,sorted,explore_all_trees)` 各自含义?——checks 叶子预算(-1 无限、-2 用 autotuned 结果,defines.h:168-170);eps 相对误差放宽;sorted 结果按距离排序;explore_all_trees 先完整走完每棵树(kdtree_index.h:204-208 注释)。
4. LSH 的 12/20/2 默认值在哪?——索引实现内的 get_param 兜底(lsh_index.h:100-102);miniflann 构造函数无默认值必须显式传三参(miniflann.hpp:136),教程常写 LshIndexParams(12,20,2) 即源于此。
5. 索引文件能跨数据集加载吗?——不能。load 要求传入数据集尺寸/类型与文件头一致(miniflann.cpp:825-831),flann_base 层还要求算法可重建(flann_base.hpp:99-105);数据集本身不存进通用索引文件,只有 LSH 例外面(它存数据)。
6. FlannBasedMatcher 为什么不支持 mask?——isMaskSupported 返回 false(matchers.cpp:1384-1386),flann 层没有逐对掩码入口;需要 mask 用 BFMatcher。
7. 二进制描述子(ORB/BRIEF)配 FLANN 该用什么?——工厂按 is_kdtree_distance=False 裁剪,KDTree 族不可用;实战选 LSH(或 Hierarchical+Hamming 距离);radiusSearch 仅 LSH 被拒(miniflann.cpp:663-664)。
8. VideoCapture 读 IStreamReader 为何禁 CAP_ANY?——逐后端尝试会反复消费/重置流数据,故要求显式指定后端(cap.cpp:247-250)。
9. CAP_PROP_POS_MSEC 从哪来?——FFmpeg 后端由最近一帧 pts(缺失退 pkt_dts)减流 start_time 再乘 time_base,不是逐帧累计计时(cap_ffmpeg_impl.hpp:1976-1981、2121-2125)。
10. 后端插件与内置后端有差别吗?——捕获插件走 CAPTURE_API_VERSION=2 的 C ABI(plugin_capture_api.hpp:16),内置走 IVideoCapture 虚函数;VideoCapture 层无感,统一经 backendFactory 抽象(cap.cpp:145-150),这继承了卷一 D 的注册表结论。

## 13. 深挖

1. **AutotunedIndex 的代价函数**:`(buildTime*w_build + searchTime)/bestTime + w_mem*memoryCost`,三个权重即构造参数 build_weight(0.01)/memory_weight(0);target_precision 经 ground truth 换算成所需 checks 再折算 searchTime(autotuned_index.h:240-258、462-476)——"精度约束下时间最优"的拉格朗日式写法。
2. **cb_index 的两次登场**:建树时它参与检索折扣(:1594);estimateSearchParams 会为已建好的 KMeans 索引重扫 cb_index 0→1.0(步长 0.2)找最优——建树后仍可调,这是 FLANN 少见的"后验参数"(autotuned_index.h:521-530)。
3. **KDTreeIndex 的 RAND_DIM=5**:不取方差最大维,而取"前 5 大方差维随机挑一"——多棵树因维度随机化而彼此独立,这是 FLANN 论文 randomized kd-tree 的实现点(kdtree_index.h:358-385、584)。
4. **rawMode 全链路**:open 时 CAP_PROP_FORMAT=-1 开启(:1074-1087)→grabFrame 走 processRawPacket(可经 bsfc 比特流过滤)(:1669-1673)→retrieveFrame(flag==0) 返回包字节、(flag==extraDataIdx) 返回 extradata(:1747-1765)→seek 用 rawSeek 一次跳过(:2189-2193);"只解封装不解码"的完整旁路。
5. **retrieveFrame 的 sws 上下文缓存与线程数**:libswscale≥6.4 时手工 sws_alloc_context 带 threads 选项并保留色度位置参数,否则退回 sws_getCachedContext;插值固定 BICUBIC;convertRGB=false 时原格式直出,但仅 GRAY8/GRAY16LE 受官方支持(cap_ffmpeg_impl.hpp:1783-1870、1065-1073)。

## 14. 正文蒸馏要点

1. flann 真实类名是 KDTreeIndex/KDTreeSingleIndex/KMeansIndex/CompositeIndex/HierarchicalClusteringIndex/LshIndex/AutotunedIndex/LinearIndex;工厂按距离标签两级裁剪(all_indices.h:59-156)。
2. cv::flann::Index 门面只放行 L2/L1/Hamming,其余被 MINIFLANN_SUPPORT_EXOTIC_DISTANCE_TYPES=0 裁掉;LSH 强制 Hamming(miniflann.cpp:3、409-447)。
3. L2 是平方距离(worst_dist 早退);FlannBasedMatcher 输出前才 sqrt,Hamming 分支不开方(matchers.cpp:1407-1442;dist.h:266-278)。
4. FlannBasedMatcher::train 全量重建索引,增量 add 无增量插入;mask 不支持、深拷贝 clone 抛异常(matchers.cpp:1160-1174、1384-1397)。
5. CompositeIndexParams 实际建的是多树 KMeansIndex,Composite 索引在 miniflann 门面下不可达(miniflann.cpp:216)。
6. checks 是近似索引统一预算:-1 无限(KMeans 转精确)、-2 用 autotuned 最优值;Linear 与 KDTreeSingle 恒精确(defines.h:168-170;kmeans_index.h:529)。
7. AutotunedIndex = 20 组 KMeans + 5 组 KDTree 在 10% 采样上评估,saveIndex 只存胜者索引与 checks,载入即失身份(autotuned_index.h:332-476、134-155)。
8. LSH 参数 12/20/2 是实现内兜底(构造函数无默认);save/load 即重建;static 缓冲有并发隐患;radiusSearch 被禁止(lsh_index.h:100-158、271;miniflann.cpp:663-664)。
9. videoio 后端契约仅 6 个虚函数;grab/retrieve 分离支撑 raw 模式、多通道与 waitAny(仅 V4L)(cap_interface.hpp:213-223;cap.cpp:646-655)。
10. 相机编号百位即后端;文件/相机/流三张投影表各自排序,CAP_ANY 逐后端吞异常回退,throwOnFail 只在钉死非 ANY 后端时中途重抛(cap.cpp:381-390、131-208、171-197)。
11. FFmpeg open 不解码首帧;grabFrame 是 READ_ATTEMPTS=4096/DECODE_ATTEMPTS=64 双计数循环,EOF 塞空包冲刷缓存(cap_ffmpeg_impl.hpp:1595-1740)。
12. 时间戳三步:pts 优先、pkt_dts 兜底→减流 start_time 换算秒→帧号=fps*sec+0.5 反推;seek 回退 16 帧起步倍增再前向补偿;Writer 的 pts 就是帧号(cap_ffmpeg_impl.hpp:1705-1725、2115-2125、2160-2225、2777-2783)。
