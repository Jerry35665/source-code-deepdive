# PostgreSQL 深读报告 R:全文检索与 JSONB 内部实现

> 基线:commit `8c7a74c`。行号以 src/include/tsearch/、src/backend/utils/adt/、src/include/utils/jsonb.h 为准。

## tsvector 二进制布局

`[varlena][int32 size][WordEntry[n] 按 memcmp 排序去重][词素池+可选位置区]`。WordEntry=4B 位域:haspos:1+len:11(词素≤2047B)+pos:20(池≤1MB);pos 是相对 WordEntry 数组末尾的偏移。WordEntryPos=uint16:weight:2+pos:14;每词素≤256 位置。构建即规范化:uniqueentry qsort+合并重复词素的 position 数组。

tsquery:`[varlena][size][QueryItem 扁平后缀数组]['\0' 结尾操作数串池]`;QueryOperand 含 weight 位掩码+prefix+valcrc+length;QueryOperator 右孩子=item+1、左孩子=item+left(无指针树)。

## jsonb 二进制树

`Jsonb = varlena + JsonbContainer{header=计数+标志, JEntry[]}`;根无 JEntry,裸标量包成 JB_FSCALAR 单元素数组。JEntry=uint32:低 28bit 长度/偏移+3bit 类型(String/Numeric/BoolF/BoolT/Null/Container)+高位 HAS_OFF。每 JB_OFFSET_STRIDE=32 个节点存 1 个绝对偏移,其余存长度——为 TOAST 压缩保住可压缩性。对象存储:全部键的 JEntry+数据在前、值在后、按键序——按键查找缓存友好。

## GIN opclass 三兄弟对照

| opclass | 键产出 | recheck | 适用 |
|---|---|---|---|
| tsvector_ops | 每词素一 text 键 | false(权重缺失升 MAYBE) | 全文检索 |
| jsonb_ops(默认) | 每键名/值一个"1B 类型前缀+文本" | **永远 recheck** | 通用 JSONB |
| jsonb_path_ops | 从根到值的整条路径 uint32 哈希 | 仅 @> | 精确包含查询 |

## ts_rank 排名

default_weights{0.1,0.2,0.4,1.0};calc_rank_or 用调和级数 Σwᵢ/i² 除以 π²/6 归一化。
