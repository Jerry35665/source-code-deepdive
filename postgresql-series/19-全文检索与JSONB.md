# 第 19 章 · 全文检索与 JSONB:非结构数据的结构化存储

> 基线:commit `8c7a74c`。行号以 src/include/tsearch/、src/include/utils/jsonb.h、src/backend/access/gin/ 为准。**衔接**:GIN 的 extractQuery/consistent 回调(卷四 15 章)在本章有真实消费者。

## 19.0 全景:两种非结构数据的结构化策略

```
tsvector(全文检索)                jsonb(半结构化)
  = 排序去重的词素数组               = 树形容器(key→值,按键序)
  + 可选位置/权重                     + JEntry 索引(偏移/长度)
  → GIN 索引:每词素一 key            → GIN 索引:每键/值/路径一 key
  → 查询:tsquery 树匹配              → 查询:@> 包含/jsonpath
```

**两者的共同点**:都是"把非结构数据拆成可索引的 key"——tsvector 拆成词素,jsonb 拆成键值对;**GIN 是统一的倒排引擎**,opclass 只定义"怎么拆、怎么查"。

## 19.1 tsvector:排序去重的词素数组

`[varlena][int32 size][WordEntry[n] 按 memcmp 排序去重][词素池+可选位置区]`;WordEntry=4B 位域:haspos:1+len:11+pos:20(ts_type.h:43-49);pos 是相对 WordEntry 数组末尾的偏移。WordEntryPos=uint16:weight:2+pos:14;每词素≤256 位置。构建即规范化:uniqueentry qsort+合并重复词素的 position 数组。tsvector_bsearch 排序红利=O(log n) 词素定位(tsvector_op.c:396)。

tsquery:`[varlena][size][QueryItem 扁平后缀数组]['\0' 操作数串池]`;QueryOperand 含 weight+prefix+valcrc+length;**QueryOperator 右孩子=item+1,左孩子=item+left**(ts_type.h:216-218)——无指针树,扁平后序遍历。parse_tsquery(makepol→打包→findoprnd 回填,tsquery.c:817-940)。

## 19.2 jsonb:树形容器与偏移折中

`Jsonb = varlena + JsonbContainer{header=计数+标志,JEntry[]}`(jsonb.h:138-150);根无 JEntry,裸标量包成 JB_FSCALAR 单元素数组。JEntry=uint32:低 28bit 长度/偏移+3bit 类型(String/Numeric/BoolF/BoolT/Null/Container)+高位 HAS_OFF(jsonb.h:121-131 注释:offset-or-length 折中——TOAST 压缩 vs O(1) 访问)。**每 JB_OFFSET_STRIDE=32 个节点存 1 个绝对偏移**,其余存长度。对象存储:全部键的 JEntry+数据在前、值在后、**按键序**——按键查找缓存友好。jsonb 规范化 vs json 原文:键去重、键序化、数字转 Numeric;`@>` 真值靠 JsonbDeepContains。jsonpath 同为 varlena 二进制:JsonPathItem 以 nextPos 相对偏移串链,执行器 executeItem 沿 jsonb 树下行。

## 19.3 GIN opclass 三兄弟

| opclass | 键产出 | recheck |
|---|---|---|
| tsvector_ops | 每词素一 text 键 | false(权重缺失升 MAYBE) |
| jsonb_ops(默认) | 每键名/值一个"1B 类型前缀+文本" | **永远 recheck** |
| jsonb_path_ops | 从根到值的整条路径 uint32 哈希 | 仅 @> |

权威注册表:pg_amproc.dat:706-749。jsonb_ops 的键无结构信息→永远 recheck;jsonb_path_ops 的键编码了路径→recheck 可信——**精度与通用性的折中**。

## 19.4 设计动机

1. **为什么 tsvector 排序去重**:GIN 的 posting 合并要求 key 有序;bsearch(tsvector_op.c:396)的 O(log n) 来自排序红利;
2. **为什么 jsonb 用树形而非文本**:json 文本解析 O(n) 每次查询;jsonb 树形+二进制=一次解析多次访问——**存储格式为查询模型服务**;
3. **为什么 GIN 是全文/JSONB 的搭档**:两者的查询语义("包含词 X"/"包含键值对 Y")都是倒排索引的天然场景——**GIN 的 opclass 抽象让"什么算一个 key"可插拔**;
4. **ts_rank 的调和级数**:Σwᵢ/i² 除以 π²/6(tsrank.c:284)——频率权重+位置权重的混合公式,数学上收敛于常数归一。

## 19.5 FAQ

**Q1:tsvector 的 position 是必需的吗?**
可选(haspos 位):位置用于 rank 排名与 phrase 查询;纯过滤不需要。

**Q2:jsonb 与 json 类型差在哪?**
jsonb=二进制树(解析一次多次查询);json=原文(每次解析)——jsonb 写慢读快,json 反之。

**Q3:为什么 jsonb_ops 的查询永远 recheck?**
键只含键名/值,不含路径结构:GIN 只能说"可能匹配",须 recheck 验证(:jsonb_ops 键无结构信息)。

**Q4:jsonb_path_ops 比 jsonb_ops 好在哪?**
键=整条路径哈希:精确匹配@> 不需要 recheck;但只支持 @> 操作。

**Q5:大 JSON 对象怎么处理?**
TOAST(ts_type.h:134-138/jsonb.h:401 的 typstorage='x'):超 2KB 自动压缩+分片(卷三 13 章)。

**Q6:ts_rank 的权重来自哪?**
default_weights{0.1,0.2,0.4,1.0}(tsrank.c:25):D/A/B/C 四级;setweight 可设。

**Q7:tsquery 的操作数池为什么在尾部?**
扁平后缀数组的长度已知:操作数串紧随其后,用 length 定位边界。

**Q8:jsonpath 能编译缓存吗?**
能:JsonPathItem 是 varlena,可存储与复用。

**Q9:tsvector 和 GIN 的 VACUUM 联动?**
ginbulkdelete 第一步强制清 pending(卷四 15 章);死 TID 过滤走 ginvacuumitempointers(:48-84)。

**Q10:全文检索的排名公式为什么用调和级数?**
(tsrank.c:284):词频的边际递减——调和级数天然模拟"首个命中价值最大"。

## 19.6 小结与深挖方向

本章结论:**非结构数据的结构化="拆成可索引的 key+GIN 统一倒排+opclass 定义拆法"**。深挖:

1. WordEntry 的 11bit len 上限(2047B)对长词素的截断行为;
2. jsonb 的 HAS_OFF 折中(:121-131)在压缩/非压缩切换的性能差;
3. jsonb_path_ops 的路径哈希碰撞率与假阳性 recheck;
4. ts_rank 的调和级数(:284)在多词查询的归一化精度;
5. jsonpath 执行器(executeItem)的谓词下推优化空间。

> 下一章:逻辑解码与后台工作者——PG 的可编程扩展面。
