# F(卷二):Parquet 扩展 —— 外部列存的零拷贝读取

> 基线 commit:`7e886f44428e90c8379d4d34e2afb866108ff079`。源码位于 `extension/parquet/`,thrift 定义在 `third_party/parquet/parquet.thrift`。本卷所有行号均经实际 Read/Grep 核对。

## 0. 全景图:Parquet 文件布局与 DuckDB 读取对象的映射

```text
Parquet 物理文件                            DuckDB 侧对象
┌─────────────────────────────┐
│  "PAR1" (4B magic)          │
│  ┌───────────────────────┐  │   RowGroup (parquet.thrift:1009)
│  │ Row Group 0           │  │   └→ GetGroup(state)          parquet_reader.cpp:1608
│  │  ┌─────────────────┐  │  │   ColumnChunk (parquet.thrift:966)
│  │  │ ColumnChunk c0  │  │  │   └→ ColumnReader.chunk       column_reader.cpp:251
│  │  │  [Dict Page]    │  │  │   PageHeader (parquet.thrift:805)
│  │  │  [Data Page 0]  │  │  │   └→ PrepareRead/PreparePage  column_reader.cpp:357,505
│  │  │  [Data Page 1]  │  │  │        页内: rep/def level + 编码值
│  │  └─────────────────┘  │  │
│  │  ┌─────────────────┐  │  │   StructColumnReader/ListColumnReader
│  │  │ ColumnChunk c1  │  │  │   └→ 嵌套 schema 树(每叶子一个 chunk)
│  │  └─────────────────┘  │  │
│  └───────────────────────┘  │
│  ┌───────────────────────┐  │
│  │ Row Group 1 ...       │  │   并行单位:一个线程领一个 row group
│  └───────────────────────┘  │   TryInitializeScan            parquet_multi_file_info.cpp:848
│  FileMetaData (thrift,      │   LoadMetadata                 parquet_reader.cpp:264
│   footer, 可加密 "PARE")    │   └→ ParquetFileMetadataCache  parquet_reader.cpp:1473-1487
│  footer_len (4B) + "PAR1"   │
└─────────────────────────────┘
  读取顺序:先读文件尾 8B 得 footer_len → 反解 footer → 按 ColumnChunk 偏移随机读列
```

要点:DuckDB 把 row group 当作**并行与剪枝的单位**,把 column chunk 当作 **I/O 与预取的单位**,把 page 当作**解码与页级过滤的单位**;三者都直接来自 thrift footer 元数据,无需打开文件即可规划。

## 1. 读入口:表函数注册与 MultiFileReader 衔接

`read_parquet` / `parquet_scan` 是同一个函数集的两个名字(parquet_extension.cpp:1009-1013)。真正的表函数体是泛型模板 `MultiFileFunction<ParquetMultiFileInfo>`——glob 展开、hive 分区、union_by_name、filename/file_row_number 虚拟列全部复用核心的 multi_file 框架(multi_file_function.hpp:92;文件列表由 `multi_file_reader->CreateFileList` 创建,multi_file_function.hpp:239),Parquet 扩展只提供接口实现 `ParquetMultiFileInfo`(parquet_multi_file_info.hpp:53)。

关键钩子都在 `ParquetScanFunction::GetFunctionSet`(parquet_multi_file_info.cpp:515-542):

```cpp
table_function.filter_pushdown = true;
table_function.filter_prune = true;
table_function.late_materialization = true;
```
(parquet_multi_file_info.cpp:537-539)

`filter_prune` 让优化器可以据 footer 统计直接剪掉整个文件/row group;`late_materialization` 允许"先解码过滤列、再按 selection 解码其余列"的两阶段扫描。其余入口:`parquet_scan` 也注册为 COPY FROM 的读函数(parquet_extension.cpp:1058-1059);直接查文件名的 replacement scan 把 `FROM 'x.parquet'` 改写成 `parquet_scan`(parquet_extension.cpp:897-914,注册于 1079)。另注册 `parquet_metadata`/`parquet_schema`/`parquet_kv_metadata`/`parquet_file_metadata`/`parquet_bloom_probe`/`parquet_full_metadata` 六个元数据表函数,全部走 `MultiFileReader::CreateFunctionSet`(parquet_extension.cpp:1016-1037;函数名定义 parquet_metadata.cpp:1177-1223)。扩展加载时还挂了一个 zstd 压缩文件系统,使 `x.parquet.zst` 可透明读取(parquet_extension.cpp:1007;zstd_file_system.hpp:17-45)。

读路径的每文件对象是 `ParquetReader : BaseFileReader`(parquet_reader.cpp:1444 构造),虚列有 `file_row_number` 与 `file_row_group_number` 两个(parquet_multi_file_info.cpp:790-795)。

## 2. metadata 读取:footer 解析与统计

footer 解析只做两次小读:先取文件尾 8 字节,校验 magic(`PAR1` 明文 / `PARE` 加密)并读出 4 字节 footer 长度(parquet_reader.cpp:240-262);远程文件为省一个 RTT,会先预估 footer 大小预取(估文件 1/1000,夹在 16KB~256KB,parquet_reader.cpp:285-291)。随后用 TCompactProtocol 反序列化 `FileMetaData`(parquet_reader.cpp:359):

```cpp
auto metadata = make_uniq<FileMetaData>();
...
metadata->read(file_proto.get());
```
(parquet_reader.cpp:331,359)

结构对应 parquet.thrift:1256(`FileMetaData`)、1009(`RowGroup`)、966(`ColumnChunk`)、805(`PageHeader`)、513(`SchemaElement`)、275(`Statistics`)——thrift IDL 直接由 `generate.sh` 生成 `parquet_types.h`,扩展不做任何中间封装。RowGroup/ColumnChunk 关键字段与 DuckDB 用途的对应:

- `RowGroup.num_rows` → 并行调度的行数与剪枝上限(parquet_reader.cpp:1885-1890);
- `ColumnChunk.meta_data.data_page_offset / dictionary_page_offset` → 列 I/O 起点,取二者最小值(column_reader.cpp:180-210);DuckDB 特意取 min,因为部分写手的 dictionary_page_offset 不可靠("ugh. sometimes there is an extra offset for the dict. sometimes it's wrong.",column_reader.cpp:266-271);
- `ColumnChunk.meta_data.total_compressed_size` → 预取区间与成本模型输入(column_reader.cpp:153-158);
- `ColumnChunk.meta_data.statistics` → zonemap/优化器统计;`bloom_filter_offset` → bloom 探针(parquet_statistics.cpp:1174-1194);
- `SchemaElement.repetition_type` → max_define/max_repeat 的推进规则(parquet_reader.cpp:971-980)。

加密文件走独立路径:footer 为 `PARE` 时先读 `FileCryptoMetaData`,仅支持 AES_GCM_V1(AES_GCM_CTR_V1 显式拒绝,parquet_reader.cpp:342-345),footer 解密成功后还会把密钥哈希存进缓存条目,用于后续校验"缓存与密钥是否匹配"(parquet_reader.cpp:354-357;哈希校验 parquet_reader.cpp:1494-1496)。

footer 可选缓存进 `ObjectCache`(受 `parquet_metadata_cache` 开关控制,parquet_reader.cpp:1473-1487,1517-1521),命中则同文件重复扫描不再解析 thrift。缓存有效性由 `ParquetCacheValidity` 判定;多文件场景下若任一文件缓存不可信或文件带删除标记,则整个 `get_partition_stats` 放弃上报,宁缺毋滥(parquet_multi_file_info.cpp:486-506)。

统计入口有三层,全部由 `ParquetStatisticsUtils::TransformParquetStatistics` 把 Parquet 的 thrift 统计转成 DuckDB `BaseStatistics`(parquet_statistics.cpp:480-608):数值/时间/DECIMAL/UUID 转 NumericStats(parquet_statistics.cpp:506),FLOAT/DOUBLE 因 NaN 语义特殊需单独处理(见第 6 节),字符串区分 exact/truncated 统计(parquet_statistics.cpp:523-528),新式 geospatial bbox 直接进 GeometryStats(parquet_statistics.cpp:552-599)。注意 Parquet 同时定义了 `min/min_value`、`max/max_value` 两套字段,转换时优先新字段(parquet_statistics.cpp:70-75)。

除了服务扫描,统计还被三个"旁路"表函数直接暴露:`parquet_metadata`(每个 row group × column 一行,含 num_values/null_count/min/max/压缩前后字节数)、`parquet_schema`(schema 树)、`parquet_kv_metadata`(文件级 KV 元数据)等,均由 `ParquetMetaDataOperator::Function` 一个算子按模式产出(parquet_metadata.cpp:117,1177-1223)。

转换后的统计既喂优化器基数/剪枝,也喂 row-group 级过滤(第 6 节)。此外每个 row group 被包装成 `PartitionStatistics`(count 为 `COUNT_EXACT`,parquet_reader.cpp:2149-2166),通过 `get_partition_stats` 回调暴露给优化器做分区剪枝(parquet_multi_file_info.cpp:536,468-513);`MinMaxIsExact` 还会检查 thrift 新增的 `is_min_value_exact/is_max_value_exact` 标志决定统计是否可信(parquet_reader.cpp:2120-2141)。

## 3. 类型映射:Parquet type → DuckDB LogicalType

单点函数 `DeriveLogicalType`(parquet_reader.cpp:392-611),优先级:logicalType → convertedType(legacy) → 物理类型兜底。摘要:

| Parquet 声明 | DuckDB 类型 | 位置 |
|---|---|---|
| logicalType.TIMESTAMP(millis/micros, isAdjustedToUTC) | TIMESTAMP / TIMESTAMP_TZ;NANOS 时 TIMESTAMP_NS / _TZ_NS | parquet_reader.cpp:414-432 |
| convertedType TIMESTAMP_MICROS/MILLIS | TIMESTAMP(+UNIT 标记) | parquet_reader.cpp:511-524 |
| INT96(无 logical/converted) | TIMESTAMP(IMPALA_TIMESTAMP 标记) | parquet_reader.cpp:594-596 |
| convertedType DECIMAL(precision,scale) | DECIMAL(p,s);精度超上限降级 DOUBLE,物理类型记 DECIMAL_INT32/INT64/BYTE_ARRAY | parquet_reader.cpp:525-549 |
| logicalType FLOAT16(FixedLenByteArray(2)) | FLOAT | parquet_reader.cpp:409-413 |
| logicalType.UUID | UUID | parquet_reader.cpp:405-408 |
| convertedType INT_8..UINT_64 / DATE / TIME_* / INTERVAL / JSON | 对应整型/DATE/TIME/INTERVAL/JSON | parquet_reader.cpp:457-576 |
| BYTE_ARRAY 无标注 | BLOB(`binary_as_string` 时 VARCHAR) | parquet_reader.cpp:601-606 |

DECIMAL 是最复杂的一档,同一逻辑类型按物理载体拆成三种 reader:

```cpp
case ConvertedType::DECIMAL:
    if (!s_ele.__isset.precision || !s_ele.__isset.scale) { ... }
    if (s_ele.precision > DecimalType::MaxWidth()) {
        schema.type_info = ParquetExtraTypeInfo::DECIMAL_BYTE_ARRAY;
        return LogicalType::DOUBLE;      // 精度超限,降级 DOUBLE
    }
    ...
    return LogicalType::DECIMAL(s_ele.precision, s_ele.scale);
```
(parquet_reader.cpp:525-549,摘录有省略)

物理与逻辑的差值(如毫秒 vs 微秒、Impala INT96、byte-array decimal)不进类型系统,而是记进 `ParquetExtraTypeInfo`(schema.type_info),读取时由对应的回调型 reader 转换(parquet_reader.cpp:398-401)。

嵌套映射在 `ParseSchemaRecursive`(parquet_reader.cpp:959-1136):遍历时维护 `max_define`/`max_repeat`(optional 各加一层 define,repeated 加一层 repeat,parquet_reader.cpp:975-980);`MAP_KEY_VALUE` 折成 `LogicalType::MAP`(1072-1086);单子节点的 struct 被"上提"避免多余一层 struct(1108-1111);repeated 包装成 LIST(1112-1117);新逻辑类型 VARIANT 识别为专用 schema 类型(1059-1062,1095-1101)。叶子到 reader 的工厂在 `ColumnReader::CreateReader`(column_reader.cpp:1015-1137):整型走 `TemplatedColumnReader`,时间/日期走 `CallbackColumnReader<物理类型,逻辑类型,转换函数>`(如 ImpalaTimestampToTimestamp,column_reader.cpp:1045-1059),DECIMAL 按物理载体分派(column_reader.cpp:1115-1126)。

## 4. 读取并行与预取

并行粒度是 row group。单文件时 `MaxThreads` 直接返回该文件的 row group 数(parquet_multi_file_info.cpp:679-688);多文件时总是开满线程(parquet_multi_file_info.cpp:682-685)。每个线程通过 `TryInitializeScan` 用原子递增的 `gstate.row_group_index` 领取下一个 row group(parquet_multi_file_info.cpp:848-860):

```cpp
if (gstate.row_group_index >= NumRowGroups()) {
    return false;   // 本文件 row group 领完
}
lstate.group_index = gstate.row_group_index;
gstate.row_group_index++;
```

领到组后,`RegisterRowGroupReads` 一次性完成:为每列建 reader、按 footer 统计判定整组是否可跳过、并决定预取策略(parquet_reader.cpp:2276-2359)。预取有三种策略:`WHOLE_GROUP`(整组连续区间一次注册)、`PREFETCH_FILTERS`(只异步拉过滤列)、`COLUMN_WISE_EAGER`(按列注册);AUTO 模式下按两个阈值自动二选一——待读压缩字节占整组跨度比例超过 `WHOLE_GROUP_PREFETCH_MINIMUM_SCAN`(0.95)或过滤器历史命中率超过 `PREFETCH_FILTER_MINIMUM_MATCH_RATIO`(0.9,过滤器看起来不挑行)时整组预取,否则只预取过滤列(parquet_reader.hpp:99-101;决策 parquet_reader.cpp:2331-2350)。真实 I/O 以 `AsyncTask` 交给异步池,每个未命中的 read head 一个 `CallbackAsyncTask`(parquet_reader.cpp:2169-2182,2361-2383)。`PREFETCH_FILTERS` 模式还有个二次挂起:过滤列解码完、若存活行非零,再异步拉取其余列(`ScheduleRemainingColumns`,parquet_reader.cpp:2484-2499),期间扫描协程以 `BLOCKED` 让出(parquet_reader.cpp:2541-2544)。预取合并间隙默认 16KB,成本模型按网络吞吐估计动态精化,上限 32MB,可用 `parquet_prefetch_column_gap` 钉死(parquet_reader.cpp:221-238;thrift_tools.hpp:62;parquet_prefetch_cost_model.hpp:27)。

每个 scan state 持有自己的列 reader 数组与 thrift 协议(parquet_reader.hpp:202-248),但整个文件共享一个带 FILE_FLAGS_PARALLEL_ACCESS 的句柄,句柄数随 reader 数而非 job 数增长(parquet_reader.cpp:2016-2029)。

## 5. 解码:page 循环与三种编码精读

`ColumnReader::ReadInternal` 是解码主循环:反复 `ReadPageHeaders`(读 thrift PageHeader + 解压页体)直到页内有值,再 `ReadData` 按 encoding 分派(column_reader.cpp:812-837)。页体准备在 `PreparePage`:无压缩直接读,否则 `DecompressInternal` 按 codec 分派 miniz(gzip)/snappy/zstd/brotli/lz4_raw(column_reader.cpp:505-540,542-615);DATA_PAGE_V2 的 rep/def level 按规约不压缩、单独拷贝(column_reader.cpp:427-495)。数据页装配时先读 rep/def level 的 RLE 编码段,再按页 encoding 选解码器(column_reader.cpp:617-695):

```cpp
case Encoding::RLE_DICTIONARY:
case Encoding::PLAIN_DICTIONARY: {
    encoding = ColumnEncoding::DICTIONARY;
    dictionary_decoder.InitializePage();
    break;
}
case Encoding::DELTA_BINARY_PACKED: {
    encoding = ColumnEncoding::DELTA_BINARY_PACKED;
    delta_binary_packed_decoder.InitializePage();
    break;
}
```
(column_reader.cpp:655-671)

**RLE_DICTIONARY**:字典页在 `InitializeDictionary` 一次性 Plain 解进一个可复用 DictionaryVector,DuckDB 把"NULL"塞为字典最后一个槽位以免单独 validity(parquet: decoder/dictionary_decoder.cpp:34-52);数据页只剩 u32 偏移流,`Read` 直接把 RLE 位打包偏移解进 SelectionVector,输出保持 dictionary vector 而非物化(decoder/dictionary_decoder.cpp:107-141)。偏移越界按损坏文件抛错(decoder/dictionary_decoder.cpp:117-123)。

```cpp
// 字典装入即过滤:整个字典只过一次过滤器,数据页解码时只查位图
if (filter && CanFilter(*filter, *filter_state)) {
    filter_result = make_unsafe_uniq_array<bool>(duckdb_dictionary_size);
    SelectionVector dict_sel;
    filter_count = duckdb_dictionary_size;
    ColumnSegment::FilterSelection(dict_sel, dictionary_data, *filter_state,
                                   duckdb_dictionary_size, filter_count);
    for (idx_t i = 0; i < filter_count; i++) {
        filter_result[dict_sel.get_index(i)] = true;
    }
}
```
(decoder/dictionary_decoder.cpp:55-70,摘录有省略)

**DELTA_BINARY_PACKED**:头四个 varint(block size、miniblock 数、总 count、首值 zigzag)在构造器解析(include/parquet_dbp_decoder.hpp:17-34);解码增量重排 `value = previous + min_delta + unpacked`,每 128 个值一批做 SIMD 友好的位解包,块间用 miniblock 位宽表切分(include/parquet_dbp_decoder.hpp:100-141)。`Skip` 复用同一循环但丢弃输出(include/parquet_dbp_decoder.hpp:53-60)。

**RLE/BP(Also rep/def 与布尔底层)**:`RleBpDecoder::GetBatch` 在 repeated run(填充)与 literal run(位解包)间切换,run 头是 varint,LSB 区分类型(include/parquet_rle_bp_decoder.hpp:44-65,126-160);`ComputeBitWidthFromMaxValue` 为 def/rep level 定位宽(include/parquet_rle_bp_decoder.hpp:87-96)。另支持 DELTA_LENGTH_BYTE_ARRAY/DELTA_BYTE_ARRAY/BYTE_STREAM_SPLIT(column_reader.cpp:672-686)。

**PLAIN 与字符串**:定长物理类型由 `TemplatedColumnReader` 按模板参数直读直转(include/reader/templated_column_reader.hpp 定义 `TemplatedParquetValueConversion`);字符串的 Plain 路径有一个"零拷贝倾向"的设计——整页解压缓冲 `block` 通过 `ReferenceBlock` 挂到结果 Vector 的辅助数据上,`string_t` 直接引用页内字节,不逐值拷贝(reader/string_column_reader.cpp:118-128)。代价是必须验证页内字符串确为合法 UTF8("reality is often disappointing",reader/string_column_reader.cpp:32-42):默认 STRICT 遇非法即抛错,可切换 REPLACE(修复)/IGNORE(剔除)模式(reader/string_column_reader.cpp:56-88,选项注册 parquet_multi_file_info.cpp:591-597)。JSON 别名列额外做 JSON 语法校验(reader/string_column_reader.cpp:95-101)。

**嵌套(def/rep level)**:STRUCT reader 只是 child reader 的扇出,struct 自身的 validity 由 define 值回填(reader/struct_column_reader.cpp:104-110);LIST reader 是全系统最精巧的循环——按 `child_repeats == MaxRepeat()` 判定"本级重复则当前 list_entry.length++",按 define 值区分非空 list、空 list(define == MaxDefine()-1)与上层 NULL,并处理子读取溢出到下一次调用的 overflow 逻辑(reader/list_column_reader.cpp:133-185,注释自称 "hard-won piece of code")。跳过 LIST 也复用同一循环,只是换一个空操作 OP(reader/list_column_reader.cpp:67-89,212-216)。

## 6. filter 下推:zone map + dictionary prefilter + bloom

三层递进,全部发生在 `PrepareRowGroupBuffer`(parquet_reader.cpp:1874-1962):

1. **Row group 级 zonemap**:取该列 chunk 的 thrift statistics 转 BaseStatistics,用 `ExpressionFilter::CheckStatistics` 判 `FILTER_ALWAYS_FALSE/FILTER_FALSE_OR_NULL` 则把 `offset_in_group` 直接拉满,整个 row group 跳过(parquet_reader.cpp:1902-1922,1952-1957)。浮点列因 NaN 比较"大于一切",需把 [min,max] 剪枝与 NaN 统计剪枝合并,任一不可剪则不可剪(parquet_reader.cpp:1676-1703)。
2. **Page 级 zonemap + 字典 prefilter**:`PageIsFilteredOut` 在读页头时就判定——字典编码页若字典已被过滤器清空则整页跳过;非字典页若页头带 min/max 统计,同样做统计剪枝,命中即 `trans.Skip(compressed_page_size)` 物理跳过(column_reader.cpp:276-325)。字典 prefilter 在字典页装入时就执行:用过滤器对字典向量做一次 FilterSelection,命中位图存进 `filter_result`(decoder/dictionary_decoder.cpp:54-70);之后每个数据页只需查偏移是否命中位图即可完成整页过滤,`DirectFilter` 把这一路径接到"一次读完整个 vector"的快车道上(column_reader.cpp:898-929)。
3. **Bloom filter**:统计剪枝不通过时,若 chunk 带 `bloom_filter_offset`,按 XXH64 哈希探针,能排除同样置 `FILTER_ALWAYS_FALSE`(parquet_reader.cpp:1924-1950;探针实现 parquet_statistics.cpp:1164-1199;嵌套类型会下钻到 LIST/STRUCT 叶子再探,parquet_reader.cpp:1705-1765)。

执行期则是 late materialization:`ProcessFilters` 先按自适应排序逐个解码过滤列并收缩 selection vector(parquet_reader.cpp:2394-2449),存活数为 0 时其余列走 `Skip`;否则再解码剩余列并 `result.Slice`(parquet_reader.cpp:2461-2515)。过滤顺序按历史选择率动态重排(`MultiFileAdaptiveFilterCache`,parquet_reader.hpp:230-235);能"直通解码器"的过滤(字典过滤、PLAIN 的 `PlainSelect`)走 `DirectFilter/DirectSelect` 快车道,否则退化为"读完再过滤"(column_reader.cpp:850-896;接口判定 column_reader.hpp:242-245)。`Skip` 是惰性的:只累加 `pending_skips`,等该列真正需要读时才在 `ApplyPendingSkips` 里按编码各自跳过(column_reader.cpp:937-994)。

```cpp
for (idx_t i = 0; i < state.scan_filters.size(); i++) {
    auto &scan_filter = state.scan_filters[permutation[i]];
    auto &child_reader = state.GetColumnReader(local_idx);
    if (filter_count == 0) {
        child_reader.Skip(scan_count);      // 已无存活行:其余过滤列直接跳过
        continue;
    }
    ...
    child_reader.Filter(reader_input, result_vector, scan_filter.filter,
                        *scan_filter.filter_state, state.sel, filter_count, is_first_filter);
}
```
(parquet_reader.cpp:2418-2438,摘录有省略)

过滤器能否下推到 Parquet 还有编译期防线:`ParquetScanPushdownExpression` 放行一切标量表达式(parquet_multi_file_info.cpp:220-222);strlen/octet_length 甚至可以整体下推为"读 BYTE_ARRAY 长度"——`BYTE_LENGTH` 投影表达式把列类型改写为 BIGINT,读取时换用 `ByteArrayLengthColumnReader`,前提是目标列未用 DELTA_LENGTH_BYTE_ARRAY 编码且是单文件(parquet_multi_file_info.cpp:337-424;reader 换用 parquet_reader.cpp:2050-2056)。

## 7. 写入:row group 缓冲与编码选择

写侧是 COPY 函数 `parquet`(parquet_extension.cpp:1045-1071)。本地状态缓冲数据,行数达到 `DEFAULT_ROW_GROUP_SIZE`(122880,src/include/duckdb/storage/storage_info.hpp:26)或字节数达标就 Flush 一个 row group:

```cpp
local_state.buffer.Append(local_state.append_state, input);
if (local_state.buffer.Count() >= bind_data.row_group_size ||
    local_state.buffer.SizeInBytes() >= bind_data.row_group_size_bytes) {
    global_state.writer->Flush(local_state.buffer, local_state.transform_data);
    local_state.buffer.InitializeAppend(local_state.append_state);
}
```
(parquet_extension.cpp:441-449)

`Combine` 阶段不满半组的碎数据会合并以免产生过小 row group(parquet_extension.cpp:452-482)。批量模式拆成 `PrepareRowGroup`(编码/转换,可并行)+ `FlushRowGroup`(落盘)两段(parquet_extension.cpp:858-876;parquet_writer.cpp:699-794,832-869),`PrepareRowGroup` 内按 8 列一批迭代 ColumnDataCollection 以摊薄迭代开销(parquet_writer.cpp:721)。

编码选择是"先分析后写":Analyze 阶段向 PrimitiveDictionary 插值,字典满(`dictionary_size_limit`,默认 row group 行数的 1/5)则放弃字典编码,按 parquet_version 与物理类型改选 V2 编码——INT32/64 用 DELTA_BINARY_PACKED、BYTE_ARRAY 用 DELTA_LENGTH_BYTE_ARRAY、浮点用 BYTE_STREAM_SPLIT,V1 退回 PLAIN(include/writer/templated_column_writer.hpp:235-264):

```cpp
case duckdb_parquet::Type::type::INT64:
    state.encoding = duckdb_parquet::Encoding::DELTA_BINARY_PACKED;
    break;
```
(include/writer/templated_column_writer.hpp:248-250)

字典成功时写字典页 + RLE_DICTIONARY 数据页,并顺手构建 bloom filter(false positive 率默认 0.01,include/writer/templated_column_writer.hpp:297-322)。页上限很大(页 100MB、字典页 1GB),即 DuckDB 基本不主动切页,交给 122880 行一组自然分页(include/writer/primitive_column_writer.hpp:84-87)。压缩 codec 默认 SNAPPY,可选 uncompressed/gzip/zstd/brotli/lz4(_raw),compression_level 仅对 zstd 生效(parquet_extension.cpp:91,187-207,369-371)。统计来自写入过程中的 min/max 收集,`GatherWrittenStatistics` 汇入 ColumnChunk(parquet_writer.cpp:1248)。

写侧还带一圈兼容性选项:`parquet_version` 选 V1/V2 编码集(parquet_extension.cpp:336-344);`write_timestamp_as_int96` 为 Impala/Spark 兼容把时间戳写回 INT96(parquet_extension.cpp:131-132,358-360);`timestamp_is_adjusted_to_utc` 控制时区语义标注(parquet_extension.cpp:134-135);`field_ids` 支持自动生成或按列显式指定 Parquet field id,服务于按 field_id 映射 schema 的表格式读者(读侧对应 `BY_FIELD_ID` 映射模式,parquet_extension.cpp:208-224;parquet_multi_file_info.cpp:175-179);GEOMETRY 列在 spatial 扩展在场时自动转 GeoParquet(parquet_extension.cpp:944-964);NOT NULL 信息从优化器列统计传播进来作为 required 标注(parquet_extension.cpp:379-391)。

## 8. 与原生存储的差异:只读语义的边界

- **无 update/delete**:Parquet 扩展没有 DELETE/UPDATE 入口,文件不可变;但为对接数据湖的 deletion vector,reader 保留一个 `deletion_filter` 钩子,在 `EvaluateFilters` 开头按全局行号过滤已删行(parquet_reader.cpp:2403-2409)。元数据缓存的有效性检查甚至考虑了"文件是否有过删除"(parquet_multi_file_info.cpp:456-458)——删除破坏了"footer 统计 = 文件内容"的假设,所以带删除的文件不再上报分区统计(parquet_multi_file_info.cpp:497-501)。
- **无事务/无写回**:COPY 只追加新文件;`HasPendingWrites` 恒 false,"Parquet row group 直接读自文件,不存在未 checkpoint 的写"(parquet_reader.cpp:2143-2146)。写出的文件在 `FlushRowGroup` 里做 Impala 式偏移校验(data_page_offset/dictionary_page_offset 必须落在文件内且字典页在数据页之前,parquet_writer.cpp:796-830,850)。
- **流式边界**:metadata 在文件尾部,不可 seek 的 FIFO 流直接抛 NotImplementedException(parquet_reader.cpp:1451-1455);chunk.file_path 外部引用也不支持(parquet_reader.cpp:256-259)。page offset 异常的文件会关闭预取并提示用户 `SET disable_parquet_prefetching=true`(parquet_reader.cpp:2318-2327)。
- **基数是估计**:单文件时行数是准确的 footer `num_rows`(parquet_multi_file_info.cpp:713-716);多文件无缓存时只能按"文件大小/每行字节"外推,并给每文件 1000 行下限防低估(parquet_multi_file_info.cpp:729-778);用户可用 `explicit_cardinality` 直接注入外部基数(parquet_multi_file_info.cpp:663-667)。
- **投影即读取**:扫描只创建被引用列的 reader(`column_indexes` 驱动,parquet_reader.cpp:2045-2080),struct 里未被引用的子列在输出中置 NULL(reader/struct_column_reader.cpp:88-91);嵌套过滤列之外的列在过滤阶段只做 `Skip`,不付解码成本(column_reader.cpp:2469-2471)。
- **DuckLake 一句话**:代码里 ducklake 仅以注释出现——自定义 `schema` 参数的用户"like Ducklake"不做 strlen 下推,因其按 field_id/name 映射另有 UNION 语义(parquet_multi_file_info.cpp:347-352);但 `explicit_cardinality` 参数与删除过滤钩子正是为这类外部 catalog 留的接缝,parquet 扩展本身对 lake format 无任何硬编码依赖。

## 9. 设计动机

1. **统计直接喂优化器**:footer 里的 min/max/null_count 被 `TransformParquetStatistics` 原样转成 DuckDB `BaseStatistics`(parquet_statistics.cpp:480-608),row group 即分区即统计单元(parquet_reader.cpp:2149-2166)。零成本获得可信谓词剪枝与精确基数,这是"外部文件当表查"能进决策计划的根本原因;代价是必须处理 Parquet 统计的全部怪癖(NaN、截断字符串、exact 标志)。
2. **映射层独立**:类型推导收敛在 `DeriveLogicalType` 一个函数(parquet_reader.cpp:392-611),物理/逻辑差异装进 `ParquetExtraTypeInfo` 延迟到 reader 工厂解决(column_reader.cpp:1045-1059)。这样新增一种 Parquet 逻辑类型只需两处小改,而扫描、过滤、并行逻辑完全不动。
3. **并行按 row group**:row group 是 Parquet 中唯一自带"行数 + 每列偏移"的自治单元(parquet.thrift:1009),调度只需原子递增一个下标(parquet_multi_file_info.cpp:848-860);更细的 page 级并行会被 thrift 页头解析的串行读破坏,更粗的文件级并行会被单大文件卡死。
4. **写不追求全编码**:字典不满就退到 DBP/DLBA/BSS 的保守策略(templated_column_writer.hpp:235-264)、页大到基本不切(primitive_column_writer.hpp:84-87),牺牲文件体积换取写路径简单、写速度快、产出文件对所有引擎可读;压缩交给成熟 codec 而非发明格式。
5. **保持只读**:文件不可变让元数据缓存可以安全复用(parquet_reader.cpp:1473-1487)、统计可以放心上报(COUNT_EXACT,parquet_reader.cpp:2158);更新/删除的语义复杂度被推给上层(DuckLake 的 deletion vector + `deletion_filter` 钩子,parquet_reader.cpp:2403-2409),扩展本体始终只有"读 + 追加写"两条路径。
6. **I/O 计划先于数据**:footer 读完即知道每个 chunk 的字节区间,预取策略(WHOLE_GROUP/PREFETCH_FILTERS/COLUMN_WISE)全部基于元数据与历史选择率而非试探(parquet_reader.cpp:2331-2350),远程对象存储上省的是整个 RTT。

## 写作素材清单(文件:行号)

1. extension/parquet/parquet_multi_file_info.cpp:515 — `ParquetScanFunction::GetFunctionSet`,filter_pushdown/filter_prune/late_materialization 开关
2. extension/parquet/parquet_extension.cpp:1009 — read_parquet/parquet_scan 双名注册与 replacement scan(1079)
3. extension/parquet/parquet_reader.cpp:240 — `ParseParquetFooter`,PAR1/PARE magic 与 footer_len
4. extension/parquet/parquet_reader.cpp:285 — footer 尺寸预估与远程预取(省 RTT)
5. extension/parquet/parquet_reader.cpp:392 — `DeriveLogicalType` 类型映射总入口
6. extension/parquet/parquet_reader.cpp:525 — DECIMAL 映射(超精度降 DOUBLE、物理载体三选)
7. extension/parquet/parquet_reader.cpp:959 — `ParseSchemaRecursive`,max_define/max_repeat 与 LIST/MAP 折叠
8. extension/parquet/parquet_reader.cpp:1874 — `PrepareRowGroupBuffer`,zonemap+bloom 的 row group 级剪枝
9. extension/parquet/parquet_reader.cpp:2276 — `RegisterRowGroupReads`,预取策略选择
10. extension/parquet/parquet_reader.cpp:2501 — `ProcessFilters`,late materialization 两阶段
11. extension/parquet/column_reader.cpp:276 — `PageIsFilteredOut`,页级统计与字典整页跳过
12. extension/parquet/column_reader.cpp:617 — `PrepareDataPage`,rep/def level 装配与 encoding 分派
13. extension/parquet/decoder/dictionary_decoder.cpp:34 — 字典装入 + 字典级 prefilter
14. extension/parquet/include/parquet_dbp_decoder.hpp:17 — DELTA_BINARY_PACKED 头解析与 miniblock 循环
15. extension/parquet/reader/list_column_reader.cpp:133 — LIST 的 rep/def 折叠("hard-won"循环)
16. extension/parquet/include/writer/templated_column_writer.hpp:235 — 写侧编码回退决策(字典满→V2 编码)
