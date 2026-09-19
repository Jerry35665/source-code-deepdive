# 报告 A6 · ml 统计机器学习(OpenCV 卷三)

> 基线:opencv @ commit `d3d247f`(4.13.0-dev,gitee 镜像),路径 `modules/ml/`。所有行号以该 commit 为准;本报告只陈述源码可验证事实,不确定处标注"待验证"。
> 模块地图(行数):svm.cpp 2359、tree.cpp 1990、ann_mlp.cpp 1533、gbt.cpp 1373、data.cpp 1045、em.cpp 859、nbayes.cpp 471、rtrees.cpp 533、boost.cpp 533、knearest.cpp 530、svmsgd.cpp 524、kdtree.cpp 530、lr.cpp 604、inner_functions.cpp 222、testset.cpp 113;头文件 ml.hpp 1956。

## 1. StatModel 统一抽象与 TrainData

`ml.hpp:318` 声明 `class StatModel : public Algorithm`:Algorithm 提供属性系统与 FileStorage 读写,StatModel 只加四个语义——`getVarCount/isTrained/isClassifier/predict`(纯虚)+ `train/calcError`(基类实现)。Flags 枚举值得注意(ml.hpp:322-327):

```cpp
// ml.hpp:322-327
enum Flags {
    UPDATE_MODEL = 1,
    RAW_OUTPUT=1, //!< makes the method return the raw results (the sum), not the class label
    COMPRESSED_INPUT=2,
    PREPROCESSED_INPUT=4
};
```

同一数值 1 在"训练语境"是增量更新、在"预测语境"是原始输出,靠模型各自解释。派生树:`NormalBayesClassifier`(ml.hpp:398)、`KNearest`(436)、`SVM`(526)、`EM`(836)、`DTrees`(1053)→`RTrees`(1247)/`Boost`(1332)、`ANN_MLP`(1431)、`LogisticRegression`(1629)、`SVMSGD`(1796)。**`GBTrees` 的类声明在 ml.hpp:1388 被整段注释掉**,gbt.cpp 里只剩 CvMat 时代的 `CvGBTrees` 遗留实现——它不在 ml 命名空间新 API 中。基类 `train(TrainData)` 直接 `CV_Error(StsNotImplemented)` 强制子类实现(inner_functions.cpp:53-58);便捷重载 `train(samples, layout, responses)` 仅包一层 `TrainData::create`(inner_functions.cpp:60-65)。`calcError` 并行计算,返回 `err/weightSum * (isclassifier ? 100 : 1)`,分类给百分错误、回归给加权 RMS(inner_functions.cpp:165-173);若未调 `setTrainTestSplit`,test 子集为空则自动回退"全样本 + testerr=false"(inner_functions.cpp:147-152)。

TrainData(ml.hpp:145)把数据侧职责一次做完:布局 ROW/COL_SAMPLE、varType、varIdx/sampleIdx(掩码自动转索引,索引再排序,data.cpp:283-285)、样本权重(缺省全 1,data.cpp:274)、类目归一化。`getNVars` 返回 varIdx 有效变量数、`getNAllVars` 返回物理变量数,`getNTrainSamples` 优先 trainSampleIdx(data.cpp:127-148);`getResponseType` 的判据是"类目标签是否为空"而非 varType 本身(data.cpp:161-164)。多输出响应在 COL_SAMPLE 下会被转置成行布局存储(data.cpp:299-304)。默认变量类型规则(data.cpp:316-320):

```cpp
// data.cpp:316-320(setData)
varType.create(1, nvars, CV_8U);
varType = Scalar::all(VAR_ORDERED);
if( noutputvars == 1 )
    varType.at<uchar>(ninputvars) =
        (uchar)(responses.type() < CV_32F ? VAR_CATEGORICAL : VAR_ORDERED);
```

即 CV_32S 响应→分类、CV_32F→有序;多输出响应强制有序(data.cpp:322-326)。类目变量经 `preprocessCategorical` 排序归一为 0..m-1 并生成 catMap/catOfs(data.cpp:470-499,398-409),相同映射靠哈希复用以省内存(data.cpp:359-381)。**missing 值约定为 FLT_MAX**(ml.hpp:148),但掩码只在 `loadFromCSV` 路径生成(data.cpp:629-630 `compare(samples, MISSED_VAL, ...)`);`TrainData::create` 把 missing 形参硬编码为 `noArray()`(data.cpp:1039)。替代值 missingSubst:类目变量 -1(data.cpp:354)、有序变量**常量 0**——按均值替代的代码被注释掉(data.cpp:391-394)。train/test 切分由 `setTrainTestSplit(Ratio)` 完成,`shuffleTrainTest` 用随机交换贯穿 train/test 两个索引数组(data.cpp:774-841)。`getTrainSamples` 尽量零拷贝,仅在需要转置/压缩时物化(data.cpp:843-883)。

## 2. SVM:内核、SMO 求解器与决策函数缓存

参数默认值与合法性(svm.cpp:121-132,1293-1355):C_SVC + RBF,gamma=1、C=1、termCrit(1000, FLT_EPSILON);LINEAR 内核强制 gamma=1(svm.cpp:1303-1304);ONE_CLASS/NU_SVC 直接清零 C(1331-1332)。内核实现 6 种(LINEAR/RBF/POLY/SIGMOID/CHI2/INTER)+ CUSTOM,sigmoid 用 `(e^|t|-1)/(e^|t|+1)` 保证数值稳定(svm.cpp:206-218),RBF 手写 4 路展开距离平方(svm.cpp:232-249);`calc` 出口统一钳位 `FLT_MAX*1e-3` 防溢出(svm.cpp:332-337)。求解器是 libsvm 衍生的 SMO(文件头版权注记 svm.cpp:55-59;类注释"Generalized SMO+SVMlight",svm.cpp:431),核心是把 C_SVC/NU_SVC/ONE_CLASS/EPS_SVR/NU_SVR 五种形式统一进一个 `solve_generic` 循环,差异下沉为三个策略函数指针 `GetRow/SelectWorkingSet/CalcRho`(svm.cpp:454-456)。C_SVC 的组装与收尾(svm.cpp:1012-1034):

```cpp
// svm.cpp:1018-1031(solve_c_svc,节选)
_alpha.assign(sample_count, 0.);
vector<double> _b(sample_count, -1.);
Solver solver( _samples, _y, _alpha, _b, _Cp, _Cn, _kernel,
               &Solver::get_row_svc,
               &Solver::select_working_set,
               &Solver::calc_rho, termCrit );
if( !solver.solve_generic( _si ))
    return false;
for( int i = 0; i < sample_count; i++ )
    _alpha[i] *= _y[i];
```

`solve_generic`(svm.cpp:649-800):初始化梯度 G、按 alpha_status(上界/下界/自由)分类,循环里 `select_working_set` 挑 maximizing -grad·d 的 (i,j)(svm.cpp:803-854,收敛判据 `Gmax1+Gmax2 < eps`,853),对二变量做解析消元,再更新 G(svm.cpp:783-784):

```cpp
// svm.cpp:712-745(节选:二变量解析消元)
if( y[i] != y[j] ) {
    double denom = Q_i[i]+Q_j[j]+2*Q_i[j];      // 异号约束
    double delta = (-G[i]-G[j])/MAX(fabs(denom),FLT_EPSILON);
    double diff = alpha_i - alpha_j;
    alpha_i += delta; alpha_j += delta;
    ... // 按 0 与 Cp/Cn 截断
} else {
    double denom = Q_i[i]+Q_j[j]-2*Q_i[j];      // 同号约束
    double delta = (G[i]-G[j])/MAX(fabs(denom),FLT_EPSILON);
    double sum = alpha_i + alpha_j;
    alpha_i -= delta; alpha_j += delta;
    ...
}
```

NU_SVC 换成 4 个 Gmax 的工作集(svm.cpp:893-960)、专用 rho(962-),初值按 nu 均摊并做 `inv_r` 重缩放(svm.cpp:1047-1064,1075-1083);不可行 nu(某两类 `nu*(ci+cj)/2 > min(ci,cj)`)直接报错返回(svm.cpp:1456-1467)。内置 6 种内核的形态:LINEAR=`x·y`;RBF=`exp(-γ‖x-y‖²)`(4 路展开);POLY=`(γx·y+coef0)^degree`;SIGMOID=`tanh(2γx·y+2coef0)`(经 `(e-1)/(e+1)`);CHI2=`exp(-γΣ(x-y)²/(x+y))`;INTER=Σmin(x,y)(svm.cpp:306-338 及各 calc_*)。Q 矩阵不物化,按行 LRU 缓存:上限 40–500MB、按"约 25% 的 Q 被用到"估行数(svm.cpp:452,524-535),`get_row_base` 用"数组 + 1 偏移哨兵、0 即空"的双链表实现 O(1) 淘汰(svm.cpp:538-584);`get_row_svc` 取行后按 y∈{±1} 统一乘符号(svm.cpp:586-605)。多类 C_SVC/NU_SVC 是标准 one-vs-one:按类排序后逐对训练 n(n-1)/2 个二分类,支持向量以 `df_index/df_alpha` 分段挂在各 `DecisionFunc{rho,ofs}` 下(svm.cpp:1473-1525)。训练完对 LINEAR 做**支持向量压缩**——每个决策函数的 Σα·sv 折叠成一个向量,原始 SV 移入 `uncompressed_sv`(svm.cpp:1558-1608;`getSupportVectors` 返回的是压缩版,1255-1258)。predict 对每个样本一次性对全部 SV 算核,再逐 df 求和投票(svm.cpp:1940-1959);`RAW_OUTPUT` 仅二类生效(svm.cpp:1968);样本数 <10 串行、否则 `parallel_for_`(svm.cpp:2022-2026)。`trainAuto` 遇 ONE_CLASS 直接退化为普通 train(svm.cpp:1746-1748),默认网格 C:0.1→500、logStep=5(svm.cpp:378-382)。交叉验证的实现是"循环移位取折":`TrainAutoBody` 对参数网格并行,每个参数在 k_fold 折内用 `sidx[(i+start)%sample_count]` 环形取训练/测试样本,分类累计误分、回归累计平方误差(svm.cpp:1656-1720);若某折丢类,`do_train` 内 `sortSamplesByClasses` 后的 class_ranges 检查会先报错(svm.cpp:1449-1451)。

## 3. DTrees/RTrees/Boost:决策树家族

单树训练 = `startTraining` + `addTree(全样本索引)`(tree.cpp:228-236);priors 先乘进样本权重(tree.cpp:181-202)。递归 `addNodeAndTrySplit` 的停止条件与代理分裂(tree.cpp:379-407):

```cpp
// tree.cpp:379-407(节选)
if( n <= params.getMinSampleCount() || node.depth >= params.getMaxDepth() )
    can_split = false;
else if( _isClassifier ) { /* 节点内响应全同类则停 */ }
else {
    if( sqrt(node.node_risk) < params.getRegressionAccuracy() )
        can_split = false;
}
if( can_split )
    node.split = findBestSplit( sidx );
...
if( params.useSurrogates )
    CV_Error( cv::Error::StsNotImplemented, "surrogate splits are not implemented yet");
```

`findBestSplit` 遍历活跃变量,按 cat/ord × class/reg 四路调用(tree.cpp:429-451)。有序分类分裂的质量函数是 `quality=(lsum2*R+rsum2*L)/(L*R)`,代数上恒等于 `lsum2/L + rsum2/R`(左右各类权重平方和占比),即 Gini 不纯度最小化的等价代理;阈值取相邻排序值中点且必须严格介于两值之间(tree.cpp:675-706)。类目分裂:二类按"类内正样本比例"排序后线性扫描(tree.cpp:872-879);多类且取值数超过 maxCategories 时,先用加权 k-means(`clusterCategories`,tree.cpp:720-)把取值聚成 ≤maxCategories 组再枚举 2^mi 个子集(tree.cpp:858-868)。`calcValue` 同时算节点值与风险:分类=加权多数类、风险=误分权重;回归=加权均值、风险=MSE;CVFolds>0 时顺带记录 cv_Tn/cv_node_risk/cv_node_error 供剪枝(tree.cpp:469-643)。但**剪枝实际被停用**——`addTree` 里 `int maxdepth = INT_MAX;//pruneCV(root);`,`pruneCV`(1-SE 规则实现完整,tree.cpp:1200-)从未被调用(tree.cpp:265);上面的 CVFolds 统计照算不误,只是算完没人消费。预测走树时:有序变量 `val<=split.c` 向左;类目变量用位图子集 `CV_DTREE_CAT_DIR`;遇 FLT_MAX 先看 missingSubst,没有则按 `defaultDir` 下行(tree.cpp:1408-1482)。`PREDICT_AUTO` 的消歧:回归或"二类且带 RAW_OUTPUT"用 SUM(叶值求和),其余用 MAX_VOTE(多数票)(tree.cpp:1396-1400);RTrees 回归 predict 把 SUM 除以树数取均值(tree.cpp:1510,1525)。RTrees 继承全部机制,只覆写差异:默认 maxDepth=5、minSampleCount=10、CVFolds=0、useSurrogates=false(rtrees.cpp:75-83);每次长树前 `getActiveVars()` 把变量洗牌取前 m 个,默认 m=√nvars(rtrees.cpp:95-109,117);bootstrap 重采样时同步记 oobmask(rtrees.cpp:187-192);树数默认上限 10000(rtrees.cpp:140-141)。**OOB 误差默认根本不算**——仅当 `epsilon>0` 或 `calcVarImportance` 时才计算(rtrees.cpp:163);回归用运行均值累计、分类用跨树累计投票(rtrees.cpp:220-243)。变量重要性是置换法:把 OOB 样本第 vi 维换成其他 OOB 样本的值再预测,`importance += ncorrect - ncorrect_permuted`,最后 clamp≥0 并 L1 归一化(rtrees.cpp:247-296)。Boost 同样只写钩子:非 DISCRETE 强制 `_isClassifier=false` 并把响应映射成 ±1(LOGIT 为 ±2)(boost.cpp:95-108);叶值 DISCRETE 恒 ±1、REAL 为 `0.5·log(p/(1-p))`(boost.cpp:171-184);权重更新 DISCRETE:`C=log((1-err)/err)`,`w*=exp(C·[分错])`,`scaleTree` 把整棵树乘 C(boost.cpp:225-256);REAL/GENTLE 统一 `w*=exp(-y·f)`(258-275);LOGIT 走牛顿步,`w=p(1-p)`、工作响应 z 截断 ±10(276-309);`weightTrimRate` 过小权重样本被裁出下轮(boost.cpp:331-)。

## 4. ANN_MLP:两种训练与激活函数

默认 SIGMOID_SYM + RPROP(0.1, FLT_EPSILON)(ann_mlp.cpp:147-151)。激活 5 种:IDENTITY/SIGMOID_SYM/GAUSSIAN/RELU/LEAKYRELU(ann_mlp.cpp:223-258);`calc_activ_func` 把 SIGMOID_SYM 实现为 `exp 后 (1-e)/(1+e)·f_param2`,每层权重矩阵多一行 bias,weights[0] 与 weights[l_count+1] 分别是输入/输出的 [scale,shift] 逐维仿射(ann_mlp.cpp:470-573,973)。训练入口(ann_mlp.cpp:849-884):

```cpp
// ann_mlp.cpp:856-881(节选)
Mat inputs = trainData->getTrainSamples();
Mat outputs = trainData->getTrainResponses();
Mat sw = trainData->getTrainSampleWeights();
prepare_to_train( inputs, outputs, sw, flags );
if( !(flags & UPDATE_WEIGHTS) )
    init_weights();
...
switch(params.trainMethod){
case ANN_MLP::BACKPROP: iter = train_backprop(inputs, outputs, sw, termcrit); break;
case ANN_MLP::RPROP:    iter = train_rprop(inputs, outputs, sw, termcrit);    break;
case ANN_MLP::ANNEAL:   iter = train_anneal(trainData);                       break;
}
```

样本权重被归一化为和为 1(ann_mlp.cpp:840-843)。BACKPROP 是逐样本 SGD+动量:每 epoch 洗牌、按 epoch 检查 E 变化;迭代上限是 `maxCount×样本数`(ann_mlp.cpp:903,943-963);更新式 `dw = bpMomentScale·dw_prev + bpDWScale·x·grad` 由一次 gemm 完成(ann_mlp.cpp:1014)。RPROP 每轮先并行分块累计全量梯度 dEdw(块大小按 64KB 缓冲倒算,ann_mlp.cpp:1193-1196,1222-1224),再单线程按符号规则更新(ann_mlp.cpp:1244-1266):

```cpp
// ann_mlp.cpp:1244-1259(节选)
int s = CV_SIGN(Eval);
int ss = prevEk[j]*s;
if( ss > 0 ) {                       // 同号:步长放大
    dval *= dw_plus; dval = std::min( dval, dw_max );
    dwk[j] = dval; wk[j] = wval + dval*s;
} else if( ss < 0 ) {                // 反号:步长缩小——但仍前进一步
    dval *= dw_minus; dval = std::max( dval, dw_min );
    prevEk[j] = 0;
    dwk[j] = dval; wk[j] = wval + dval*s;
} else {                             // 符号未定:按当前步长走
    prevEk[j] = (schar)s;
    wk[j] = wval + dval*s;
}
```

注意反号分支并非教科书 RPROP 的"回退上次更新且本轮跳过",而是按缩小后的步长沿新梯度方向前进(与函数头注释 ann_mlp.cpp:1205-1212 也不一致,注释写的是 `dE/dw <- 0`)。flags:`UPDATE_WEIGHTS=1`、`NO_INPUT_SCALE=2`、`NO_OUTPUT_SCALE=4`(ml.hpp:1584-1594)。predict 内部按缓冲上限分块前向,激活对 CV_32F/CV_64F 输入都支持(ann_mlp.cpp:341-420)。

## 5. KNN 与其他模型速览

`KNearest` 内部是 `Impl` 接口 + 两个实现:BRUTE_FORCE(默认)与 KDTREE(knearest.cpp:349,424);`setAlgorithmType` 传非法值静默回落 BRUTE_FORCE(knearest.cpp:438-452)。train 仅存样本(行布局)与 CV_32F 响应,`UPDATE_MODEL` 时直接 push_back 增量(knearest.cpp:74-100);predict 一行转发:`return impl->findNearest(inputs, impl->defaultK, ...)`(knearest.cpp:491-494)。暴力核(knearest.cpp:173-204):

```cpp
// knearest.cpp:173-185(findNearestCore,节选)
float s = 0;
for( i = 0; i <= d - 4; i += 4 ) {
    float t0 = u[i] - v[i], t1 = u[i+1] - v[i+1];
    float t2 = u[i+2] - v[i+2], t3 = u[i+3] - v[i+3];
    s += t0*t0 + t1*t1 + t2*t2 + t3*t3;
}
for( ; i < d; i++ ) { float t0 = u[i] - v[i]; s += t0*t0; }
Cv32suf si; si.f = (float)s;          // float 按 uint32 位模式比较
```

top-k 维护一个有序长度 k 数组,插入用 `si.i >= dd[i-1].i` 的位比较(非负 float 的 IEEE754 位模式保序)加移位(knearest.cpp:187-204);回归取 k 近邻均值、分类把 k 个响应排序后数游程取众数(knearest.cpp:233-260);测试样本并行,块 256(knearest.cpp:284-291)。**全模块 grep 无任何 flann 引用**;KDTREE 选项用的是 ml 自己的 `kdtree.cpp`(KDTree 类),且其 `findNearest` 返回值"currently always 0"(knearest.cpp:395-416)。其余:EM 是 StatModel 但流程自成一派(ml.hpp:836);NBAYES 高斯假设逐维统计(nbayes.cpp);LogisticRegression 梯度类实现(lr.cpp);SVMSGD 支持 Sgd/Asgd 两解法(svmsgd.cpp);gbt.cpp 为遗留 CvGBTrees(gbt.cpp:42-)。

### 5.1 持久化与遗留层

各模型 `write/read` 自带字符串化的参数名,如 SVM 写 `"svmType" << "C_SVC"`(svm.cpp:2045-2057)、树写 `"max_categories"/"use_1se_rule"`(tree.cpp:1542,1550)。读取端要兼容 2.4 时代格式:树读取靠"有没有 missing_subst 字段"判断新旧格式并给日志提示(tree.cpp:1736-1751),旧格式 maxCategories 缺省 16(tree.cpp:1714)。这一层是 ml 模块 API 冻结的直接后果——参数以字符串落盘,改名即破坏兼容,这也是 Flags 枚举值复用、`CvGBTrees` 无法迁移到新 API 的同源约束。

### 5.2 各模型训练/预测入口对照

| 模型(ml.hpp) | train 取的数据 | 分类前提 | predict 输出 |
|---|---|---|---|
| SVM(526) | getTrainSamples + NormCatResponses/Responses(svm.cpp:1618-1630) | 响应须类目,否则报错(1624-1626) | 投票类标签;RAW 仅二类 |
| DTrees/RTrees(1053/1247) | cat_responses/ord_responses + 权重(tree.cpp:171-205) | responseType==VAR_CATEGORICAL | MAX_VOTE 输出 CV_32S(tree.cpp:1512) |
| Boost(1332) | 同树;非 DISCRETE 转 ±1 ord_responses(boost.cpp:95-108) | 仅 DISCRETE | SUM(叶值和) |
| ANN_MLP(1431) | getTrainSamples/Responses/SampleWeights(ann_mlp.cpp:856-858) | 无(回归/分类自定) | 输出层缩放后向量 |
| KNearest(436) | getTrainSamples(ROW)+响应转 CV_32F(knearest.cpp:77-79) | isclassifier 标志 | k 均值或游程众数 |
| EM/NBayes/LR/SVMSGD(836/398/1629/1796) | 各自实现 | 各自实现 | 各自实现 |

## 6. 纠偏清单(以本 commit 源码为准)

1. **"ml 的 KNN 基于 flann"——错。** knearest.cpp 无 flann 依赖(模块级 grep 零命中);BRUTE_FORCE 是手写展开暴力搜索,KDTREE 用模块内自带 kdtree.cpp。
2. **"TrainData::create 支持缺失掩码"——错。** `create()` 对 missing 恒传 `noArray()`(data.cpp:1039),缺失掩码只能由 `loadFromCSV`(missch 字符→FLT_MAX)产生(data.cpp:629-630);且只有树家族在预测时消费 missing(SVM/KNN/ANN 会把 FLT_MAX 当普通值)。
3. **"RTrees 训练完就能 getOOBError"——不成立。** 默认 `calcOOBError=false`,oobError 恒 0(rtrees.cpp:84,163);必须给带 EPS 的 TermCriteria 或开 calcVarImportance。
4. **"有序变量缺失用均值替代"——错。** missingSubst 固定 0(类目为 -1),均值替代代码被注释(data.cpp:391-394)。
5. **"树分类用信息熵/Gini 显式公式"——不准确。** 源码是 Gini 代数等价的 `(lsum2*R+rsum2*L)/(L*R)` 代理,从未出现熵或显式 Gini(tree.cpp:675-706);且 `useSurrogates=true` 直接 CV_Error(tree.cpp:406-407)。
6. **"Boost 可直接多类 + RPROP 反号回退"——都不对。** Boost 仅 DISCRETE 是分类器(boost.cpp:422),其余类型强制转 ±1 回归(boost.cpp:95-108);RPROP 反号分支仍按缩小步长更新(ann_mlp.cpp:1253-1260),与注释、教科书都不同。
7. **"设了 CVFolds 决策树就会剪枝"——错。** `pruneCV` 实现完整但调用点被注释,`addTree` 固定 `maxdepth=INT_MAX`(tree.cpp:265);CVFolds 折内统计是无人消费的死路径。

## 7. ASCII:TrainData → train → predict 通用管线

```text
                    ┌────────────────────────────────────────────────────┐
 用户 Mat/CSV ──► TrainData::create/loadFromCSV(data.cpp)                 │
                    │  samples(CV_32F, ROW/COL_SAMPLE)                   │
                    │  missing: 仅 CSV 路径有(FLT_MAX 掩码)              │
                    │  varType: 响应 CV_32S→cat / CV_32F→ord             │
                    │  catMap/catOfs: 类目→0..m-1(哈希复用)              │
                    │  missingSubst: ord=0, cat=-1                       │
                    │  varIdx/sampleIdx 掩码→排序索引; 权重缺省全 1       │
                    │  setTrainTestSplit(Ratio) → trainSampleIdx/testIdx │
                    └───────────────┬────────────────────────────────────┘
                                    │ Ptr<TrainData>
                                    ▼
   StatModel::train(data, flags)(子类覆写)                              │
     ├─ SVM:      getTrainSamples + NormCatResponses/Responses          │
     │            → SMO(solve_generic: LRU 核缓存 + 策略函数)            │
     │            → one-vs-one × n(n-1)/2 → DecisionFunc{rho,ofs}        │
     │            → LINEAR: SV 折叠压缩(optimize_linear_svm)            │
     ├─ RTrees:   bootstrap × N 棵 addTree(√nvars 随机变量子集)          │
     │            → (可选)OOB 误差 / 置换变量重要性                       │
     ├─ Boost:    循环 addTree → updateWeightsAndTrim(按 boostType)     │
     ├─ ANN_MLP:  getTrainResponses → backprop(SGD+动量) / rprop        │
     └─ KNearest: 仅 push_back 存样本                                    │
                                    │ 已训练模型
                                    ▼
   StatModel::predict(samples, results, flags)
     ├─ 树家族: predictTrees 逐树下行走位图/阈值; AUTO→SUM|MAX_VOTE
     ├─ SVM:     kernel(SV 批量) + ΣαK-ρ 逐 df 投票(RAW 仅二类)
     ├─ ANN:     分块前向 + 输入/输出 scale-shift 仿射
     └─ KNN:     暴力 L2 → top-k 位比较插入 → 均值/众数
     nsamples≥10 多数走 parallel_for_(SVM 2022; KNN 342; calcError 165)
                                    │
                                    ▼
             results(CV_32F;树多类 MAX_VOTE 输出 CV_32S, tree.cpp:1512)
```

## 8. 设计动机

1. **接口最小化**:StatModel 只强制 5 个纯虚函数(isTrained/isClassifier/getVarCount/predict + train),持久化与属性系统全部复用 Algorithm;新增模型成本被压到"一个 create + 一个实现类"。
2. **数据与模型彻底解耦**:布局转换、类目归一化、缺失替代、train/test 切分、样本加权全部在 TrainData 一次性完成;模型只见"压缩后的 CV_32F 矩阵 + 0..m-1 类号",避免每个模型重复实现数据管道(getTrainSamples 零拷贝路径 data.cpp:850-853)。
3. **策略注入统一 SMO**:五种 SVM 形式共享同一优化循环,只换"取行/选工作集/算 rho"三个函数指针(svm.cpp:454-456),一处调优处处受益。
4. **核缓存 LRU**:Q 无法物化,按"25% 行会被访问"折算缓存行数并配双链表 O(1) 淘汰(svm.cpp:524-535),在内存上限与命中率先验之间取折中。
5. **树内核复用**:RTrees/Boost 继承 DTreesImpl,通过 calcValue/getActiveVars/startTraining 等虚钩子只覆写差异——森林=bootstrap×addTree,提升=addTree+改权重,单树代码路径唯一。
6. **RPROP 的可并行性**:梯度大小不影响更新量,只影响符号,因此可以分块并行累加 dEdw 再串行一次更新(ann_mlp.cpp:1222-1269),这正是不选 SGD 做默认的原因之一。
7. **predict 的线程经济学**:SVM 样本<10 串行(svm.cpp:2023)、KNN 分块 256(knearest.cpp:286),避免小任务被并行调度开销吞掉。

## 9. FAQ

1. **为什么 SVM 要求 CV_32F?** predict 断言 `samples.cols==var_count && type==CV_32F`(svm.cpp:2009),核函数与缓存都是按 float(Qfloat=float,svm.cpp:93)写的。
2. **多类 C_SVC 设 RAW_OUTPUT 为什么拿不到判别值?** 仅 `returnDFVal && class_count==2` 返回 sum,多类投票结果直接覆盖(svm.cpp:1968-1969)。
3. **线性 SVM 的 getSupportVectors 怎么只有 k 行?** 训练后 optimize_linear_svm 把每个决策函数折叠成 1 个向量;原始 SV 在 getUncompressedSupportVectors(svm.cpp:1558-1608,1250-1258)。
4. **calcError 的 test 参数何时无效?** 未 setTrainTestSplit 时 test 索引为空,自动回退全量并把 testerr 置 false(inner_functions.cpp:147-152)。
5. **缺失值如何提供?哪些模型认?** 仅 loadFromCSV 的 missch 字符;只有树家族(predictTrees)消费,替代值 ord=0/cat=-1(data.cpp:394,354)。
6. **RTrees::getOOBError 总是 0?** 默认不算 OOB;需 TermCriteria(EPS) 或 setCalculateVarImportance(true)(rtrees.cpp:163)。
7. **Boost 能做多类吗?** 仅 DISCRETE 类型是分类器(boost.cpp:422);REAL/LOGIT/GENTLE 把响应压成 ±1 后按回归训练(boost.cpp:95-108)。
8. **ANN_MLP 如何关闭自动缩放?** flags 传 NO_INPUT_SCALE=2 / NO_OUTPUT_SCALE=4(ml.hpp:1590-1594);UPDATE_WEIGHTS=1 可续训权重(ann_mlp.cpp:862)。
9. **KNN 的 predict 和 findNearest 什么关系?** predict 就是以 defaultK 调 findNearest 的转发(knearest.cpp:491-494);KDTREE 版 predict 返回值恒 0(knearest.cpp:416)。
10. **maxCategories 干什么用?** 有序/类目变量取值过多时,先把取值加权 k-means 聚到 ≤maxCategories 组再做子集枚举(tree.cpp:858-866),防止 2^mi 爆炸。

## 10. 深挖

1. **SMO 工作集选择的两种实现**:C_SVC 用两个 Gmax,在 y=+1 中取 `!is_upper_bound` 的最大 -G 作 i、y=-1 取最大 G 作 j(约束 y·d 同号配对,svm.cpp:803-854);NU_SVC 用四个 Gmax 正负类各自配对再择优(svm.cpp:893-960)——对应 nu 形式化里每组各含自由支持向量的额外等式约束;收敛判据都是 Gmax 对之和 < eps。
2. **LRU 核缓存的哨兵技巧**:`lru_cache[i+1]` 整体偏移 1,0 充当"空链指针",首尾指针 lru_first/lru_last 各司其职;未命中时要么占空位要么摘 lru_last 复用其存储槽,命中行摘链前移,全是 O(1) 指针手术(svm.cpp:538-584)。缓存行按"约 25% 的 Q 会被访问"折算,并夹在 40–500MB 之间(svm.cpp:452,524-528)。
3. **Gini 代理的代数**:`(lsum2·R+rsum2·L)/(L·R) = lsum2/L + rsum2/R`,即左右子节点"类权重平方和/总权重";最大化它 ⇔ 最小化加权 Gini 不纯度。扫描一次排序数组,每个候选阈值只需 O(m) 更新 lsum2/rsum2(tree.cpp:675-706);同时"中点严格介于两值之间"的判断防止把相等的值分到两侧(tree.cpp:696-697)。
4. **KNN 的 float 位比较**:距离 s≥0,非负 IEEE754 float 的位模式与数值同序,故用 `Cv32suf` 转 uint32 比较可免浮点比较与 NaN 分支(knearest.cpp:187-196);top-k 插入是"从尾向头找插入点、整体右移",k 通常很小,均摊 O(k)。
5. **树的类目位图子集与缺失双路径**:每个类目分裂存 ceil(maxCategories/32) 个 uint32,`CV_DTREE_CAT_DIR(类号, subset)` 按位决定左右(tree.cpp:1468-1470);预测时类目值经 catMap 二分定位并缓存在 catbuf(tree.cpp:1440-1467);缺 FOREACH 值的样本走 defaultDir(训练时按多数方向预计算,tree.cpp:405,1138-),这比"缺失替代值"更保守,是 CART 缺失处理的极简替代。

## 正文蒸馏要点

1. StatModel=Algorithm+5 纯虚函数;`train(samples,layout,resp)` 只是 `TrainData::create` 的语法糖;基类 train 抛 NotImplement(inner_functions.cpp:53-65)。
2. StatModel::Flags 中 UPDATE_MODEL 与 RAW_OUTPUT 同为 1,靠训练/预测语境区分(ml.hpp:322-327)。
3. TrainData 的类目归一化(catMap)、缺失替代(ord=0/cat=-1)、train/test 切分是全模块共享的数据前置层;缺失掩码只有 CSV 路径能生成。
4. SVM 求解器=libsvm 式 SMO:一个 solve_generic 循环 + GetRow/SelectWorkingSet/CalcRho 三策略指针;C_SVC b=-1,NU_SVC 初值均摊 + inv_r 缩放。
5. 核行 LRU 缓存 40–500MB、25% 估计;多类 one-vs-one 存为 DecisionFunc{rho,ofs}+df_alpha/df_index;LINEAR 训练后 SV 折叠为每 df 一个向量。
6. 决策树:分类 quality 是 Gini 等价代理 `(lsum2·R+rsum2·L)/(L·R)`,阈值取相邻中点;类目超 maxCategories 先加权 k-means 分箱;surrogate splits 未实现。
7. RTrees=bootstrap+每树 √nvars 随机变量子集;OOB/变量重要性默认关闭,开重要性才顺带算 OOB;重要性=置换 OOB 特征后的正确率差,L1 归一化。
8. Boost:DISCRETE 权重 `exp(C·[miss])` 且整树乘 C;REAL/GENTLE `exp(-y·f)`;LOGIT 牛顿步 w=p(1-p);非 DISCRETE 强制转回归,多类仅 DISCRETE。
9. ANN_MLP 默认 SIGMOID_SYM+RPROP;BACKPROP=逐样本 SGD+动量;RPROP=并行梯度分块+符号步长(反号仍前进,非教科书回退);输入/输出各有一层 scale-shift 仿射。
10. KNN 无 flann:暴力 4 路展开 L2 + Cv32suf 位比较 top-k;predict=findNearest(defaultK) 纯转发;KDTREE 选项用模块内 kdtree.cpp 且返回值恒 0。
11. calcError:分类返回百分错误、回归返回加权 RMS,均除以样本权重和;无 test 子集时静默回退全量。
12. 并行策略一致:多样本预测与 calcError 走 parallel_for_,小批量(SVM <10)串行避线程开销。
