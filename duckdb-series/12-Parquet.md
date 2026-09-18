# 第 12 章 · Parquet 扩展:外部列存的读取与写出

> 基线:commit `7e886f44`。核心:extension/parquet/ 目录。

## 12.0 全景:文件布局与读取对象映射

```
Parquet 文件                      DuckDB 侧对象
"PAR1" magic
 RowGroup 0 ←────────────── 并行与剪枝单位(一个线程领一个组)
   ColumnChunk c0 ──────── I/O 与预取单位
     [Dict Page][Data Page…] ← 解码与页级过滤单位
 RowGroup 1 …
 FileMetaData(thrift footer,可加密"PARE") ← 打开文件前即可规划一切
 footer_len(4B)+"PAR1"
读取顺序:先读文件尾 8B→反解 footer(thrift CompactProtocol)→按 chunk 偏移随机读列
```

read_parquet/parquet_scan 是 `MultiFileFunction<ParquetMultiFileInfo>` 模板实例——glob/hive 分区/union_by_name 全复用核心 multi_file 框架;扩展只挂三个开关:filter_pushdown/filter_prune/late_materialization(parquet_multi_file_info.cpp:537-539)。

## 12.1 metadata:footer 即 I/O 计划

footer 解析只做两次小读;远程文件为省一个 RTT 会预估 footer 大小(1/1000,16KB~256KB)预取。thrift 统计被 `TransformParquetStatistics` 原样转成 DuckDB BaseStatistics **喂优化器**——row group 即分区即统计单元,零成本获得可信谓词剪枝与精确基数,这是"外部文件当表查"能进计划的前提。footer 可缓存进 ObjectCache(命中则同文件重复扫描不再解析 thrift);带删除标记的文件放弃上报统计——删除破坏了"footer 统计=文件内容"的假设。

## 12.2 类型映射与并行

类型推导单点收敛在 `DeriveLogicalType`:DECIMAL 按物理载体三分(INT32/INT64/BYTE_ARRAY,超精度降 DOUBLE);时间戳按 unit×UTC 组合;INT96 走 Impala 回调;物理/逻辑差值装进 ParquetExtraTypeInfo 延迟到 reader 工厂。嵌套在 ParseSchemaRecursive 折成 LIST/MAP/STRUCT(max_define/max_repeat 推进)。**并行按 row group**:单文件线程数=组数,原子递增领号;预取三策略(WHOLE_GROUP/PREFETCH_FILTERS/COLUMN_WISE)按 0.95/0.9 阈值自动切换,真实 I/O 走 AsyncTask 异步池;PREFETCH_FILTERS 还有二次挂起——过滤列解完、存活行非零,再异步拉其余列。

## 12.3 过滤下推:三层递进 + late materialization

①row group 级 zonemap(浮点因 NaN 语义需合并剪枝);②page 级 zonemap+**字典 prefilter**——字典页装入即对整个字典做一次 FilterSelection,数据页只查位图,命中不了整页物理跳过;③bloom filter(XXH64 探针)。执行期 late materialization:按历史选择率动态重排过滤列顺序,逐个解码过滤列收缩 selection,存活 0 则其余列直接 Skip,否则再解码剩余列 Slice。字符串 PLAIN 路径"零拷贝倾向":页内字节直接挂到结果 Vector 的辅助数据,string_t 引用而非拷贝(代价是必须验证 UTF-8,非法可选 REPLACE/IGNORE)。LIST 折叠循环被注释自称 "hard-won piece of code"(list_column_reader.cpp:133)。

## 12.4 写入与只读边界

写侧 COPY:缓冲到 122880 行或字节达标就 Flush 一个 row group;编码选择"先分析后写"——字典满(行组/5)则按版本退 DBP/DLBA/BSS,成功则字典页+RLE_DICTIONARY 并顺手建 bloom(fp 0.01);压缩默认 SNAPPY。**只读语义边界**:无 update/delete(仅留 deletion_filter 钩子对接数据湖删除向量)、流不可 seek、基数多文件时靠外推。DuckLake 仅以注释出现——外部 catalog 的接缝是 explicit_cardinality 与删除钩子,扩展本体零硬编码。

## 12.5 设计动机

1. **统计直接喂优化器**:footer 的 min/max/null_count 原样转换,外部文件获得与原生表同级的剪枝能力;
2. **映射层独立**:新增 Parquet 逻辑类型只需两处小改,扫描/过滤/并行逻辑不动;
3. **并行按 row group**:它是唯一自带"行数+每列偏移"的自治单元;page 级会被串行页头解析破坏;
4. **写不追求全编码**:字典不满退保守编码、页大到基本不切——换取写路径简单、产出对所有引擎可读;
5. **保持只读**:文件不可变让缓存安全复用、统计放心上报;更新语义推给上层湖格式。

## 12.6 FAQ

**Q1:footer 读几次?**
两次小读(尾 8B);远程预取可省 RTT;可缓存进 ObjectCache。

**Q2:Parquet 统计能信吗?**
exact 标志可信;截断字符串与 NaN 有专门处理;带删除标记的文件不上报。

**Q3:并行粒度为什么不是 page?**
页头 thrift 解析是串行的;row group 是自治单元,调度只需原子递增。

**Q4:字典 prefilter 什么时候发生?**
字典页装入时:对字典向量一次 FilterSelection,数据页解码只查位图。

**Q5:过滤列顺序会变吗?**
会:MultiFileAdaptiveFilterCache 按历史选择率动态重排。

**Q6:写 Parquet 用什么压缩?**
默认 SNAPPY,可选 gzip/zstd/brotli/lz4;compression_level 仅 zstd 生效。

**Q7:字典编码何时放弃?**
字典满(行组行数/5):INT 转 DELTA_BINARY_PACKED、字符串转 DELTA_LENGTH_BYTE_ARRAY、浮点 BYTE_STREAM_SPLIT。

**Q8:能写 INT96 时间戳吗?**
能:write_timestamp_as_int96 为 Impala/Spark 兼容。

**Q9:非法 UTF-8 的 Parquet 会报错吗?**
默认 STRICT 抛错;可选 REPLACE 修复/IGNORE 剔除。

**Q10:删除向量怎么接?**
deletion_filter 钩子按全局行号过滤;元数据缓存有效性会考虑删除标记。

## 12.7 小结与深挖方向

本章结论:**Parquet 扩展="footer 即 I/O 计划+三层过滤下推+late materialization+只读边界"**。深挖:

1. ByteArrayLengthColumnReader:strlen 下推把列类型改写为 BIGINT;
2. PREFETCH_FILTERS 的二次挂起与 BLOCKED 协程让出;
3. LIST rep/def 折叠循环的 overflow 处理;
4. Impala INT96 时间戳的精度坑;
5. parquet_metadata/parquet_schema 六个元数据表函数。
