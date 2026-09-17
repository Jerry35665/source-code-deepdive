# 深读 B：类型系统与向量化执行的数据基座

> 基线 commit：`7e886f44428e90c8379d4d34e2afb866108ff079`（2026-09-17 主干）。
> 所有行号均经实际 Read/Grep 核对；路径相对仓库根。

DuckDB 执行引擎的"数据基座"由两层构成：**LogicalType/PhysicalType 双层类型系统**决定"一个 SQL 类型落在几字节的定长数组里"，**Vector/DataChunk** 决定"这批字节如何在算子间流动"。本篇沿源码逐层拆解。

---

## 0. 总览：Vector 内存布局 ASCII 图

```
DataChunk (src/include/duckdb/common/types/data_chunk.hpp:44)
+---------------------------------------------------------------+
| vector<Vector> data;   optional_idx count;  vector<VectorCache>|
|   |                      ( cardinality 可从子向量推导 :54-59 )  |
+---|-----------------------------------------------------------+
    |  每列一个 Vector (src/.../types/vector.hpp:35)
    v
Vector: { LogicalType type;  mutable buffer_ptr<VectorBuffer> buffer; }  (vector.hpp:238-240)
    |
    v
VectorBuffer (vector_buffer.hpp:84)  <--- vector_type 存在 buffer 里, Vector::GetVectorType() 转发 (vector.hpp:182-188)
+---------------------------------------------------------------+
| VectorType vector_type   (FLAT/CONSTANT/DICTIONARY/SEQUENCE/   |
|                           FSST/SHREDDED, enums/vector_type.hpp:15)
| VectorBufferType buffer_type + idx_t v_size (即行数)           |
| buffer_ptr<AuxiliaryDataSet> auxiliary_data (vector_buffer.hpp:215-218)
+---------------------------------------------------------------+
    | STANDARD_BUFFER 分支 (vector/flat_vector.hpp:16)
    v
StandardVectorBuffer
+---------------------------------------------------------------+
| ValidityMask validity    | data_ptr_t data_ptr                |
|   位图: 每 64 行一个 validity_t; validity_mask==nullptr     |
|   表示"整段无 NULL"(validity_mask.hpp:82-87)                |
+---------------------------------------------------------------+

string_t = 16 字节 (src/.../types/string_type.hpp:243-255):
+----------------+--------------------------------------------+
| uint32 length  |  len<=12: char inlined[12]   (内联)         |
| (4B)           |  len> 12: char prefix[4] + char* ptr (8B)   |
|                |           prefix 存前 4 字节, ptr 指向 heap |
+----------------+--------------------------------------------+

四种压缩形态:
 FLAT_VECTOR      : data_ptr + validity, 逐行存放
 CONSTANT_VECTOR  : 1 个值 + SetSize(count) (constant_vector.cpp:32)
 DICTIONARY_VECTOR: DictionaryBuffer{ SelectionVector sel; buffer_ptr<DictionaryEntry> entry{Vector data;} }
                    (dictionary_vector.hpp:99-100, 16-31)
 SEQUENCE_VECTOR  : SequenceBuffer{ int64_t start, increment; } 无数据数组 (sequence_vector.hpp:15-20)

Dictionary / List / Struct / Array 的"子向量"不放在 Vector 内,
而是挂在各自 VectorBuffer 子类的成员里, 经 auxiliary_data/entry 传播引用:
 VectorStructBuffer::children  (struct_vector.hpp:69)
 VectorListBuffer::child       (list_vector.hpp:74)
 DictionaryBuffer::entry->data (dictionary_vector.hpp:100)
```

---

## 1. LogicalType 与 PhysicalType：双层类型设计

### 1.1 两个枚举

DuckDB 把"SQL 语义类型"与"物理存储类型"拆成两个枚举。`LogicalTypeId`（约 50 个成员，含 `DECIMAL=21`、`TIMESTAMP_SEC/MS/US/NS` 一族、嵌套类型从 100 起编号）定义在 types.hpp:193-258；`PhysicalType`（BOOL/INT8..INT64/FLOAT/DOUBLE/INTERVAL/LIST/STRUCT/ARRAY/VARCHAR/INT128/UINT128/BIT/INVALID）定义在 types.hpp:71-188，其中 200 号以上是 DuckDB 自有扩展（types.hpp:180-187）。

二者由 `LogicalType::GetInternalType()` 这个巨型 switch 单向映射（src/common/types.cpp:63-176）。关键点：

- 所有整型时间/日期在物理上退化为定长整数：`DATE→INT32`，`TIME/TIMESTAMP 族→INT64`（types.cpp:75-91）。这就是"时间类型的组合"——逻辑上 6 种 timestamp，物理上只有一种 int64。
- **DECIMAL 是按宽度合成物理类型的**（types.cpp:103-120）：

```cpp
case LogicalTypeId::DECIMAL: {
    if (!type_info_) {
        return PhysicalType::INVALID;
    }
    auto width = DecimalType::GetWidth(*this);
    if (width <= Decimal::MAX_WIDTH_INT16) {
        return PhysicalType::INT16;
    } else if (width <= Decimal::MAX_WIDTH_INT32) {
        return PhysicalType::INT32;
    } else if (width <= Decimal::MAX_WIDTH_INT64) {
        return PhysicalType::INT64;
    } else if (width <= Decimal::MAX_WIDTH_INT128) {
        return PhysicalType::INT128;
    }
```

  宽度阈值常量在 decimal.hpp:41-45（`MAX_WIDTH_INT16=4, INT32=9, INT64=18, INT128=38, MAX_WIDTH_DECIMAL=MAX_WIDTH_INT128`）。`width/scale` 本身存放在 `ExtraTypeInfo`（DECIMAL_TYPE_INFO）里，校验见 types.cpp:724-727。
- `ENUM` 按字典大小映射到 UINT8/16/32（types.cpp:152-157，`EnumType::GetPhysicalType`）。
- 嵌套类型映射为"零/小负载"的容器物理类型：`STRUCT/TUPLE/UNION/VARIANT→PhysicalType::STRUCT`，`LIST/MAP→LIST`，`ARRAY→ARRAY`（types.cpp:130-139）；`GetTypeIdSize` 对 STRUCT/ARRAY 直接返回 0，LIST 返回 `sizeof(list_entry_t)`（types.cpp:359-364）。

`LogicalType` 对象仅由三个字段组成：`id_`、`physical_type_`、`shared_ptr<const ExtraTypeInfo> type_info_`（types.hpp:397-399），构造时即缓存 `physical_type_ = GetInternalType()`（types.cpp:44,48），运行期查询走 `InternalType()` 内联（types.hpp:275-277）。

### 1.2 物理大小表

"类型 id → 字节数"的全表在 `GetTypeIdSize`（src/common/types.cpp:326-368）：定长数值按 `sizeof` 返回，VARCHAR 返回 `sizeof(string_t)`（即 16），STRUCT/UNKNOWN/ARRAY 返回 0，LIST 返回 `sizeof(list_entry_t)`。定长判定 `TypeIsConstantSize` 在 types.cpp:370-373。向量分配容量与行布局（row layout）都依赖这张表。

---

## 2. Vector：一个带多态 buffer 的"句柄"

### 2.1 形态枚举与存取

2026 主干的 Vector 类已经高度"瘦身"：只有 `type` 与 `mutable buffer_ptr<VectorBuffer> buffer` 两个成员（vector.hpp:238-240），**行数（cardinality）与向量形态都下沉到 buffer 里**——`GetVectorType()` 直接转发 `buffer->GetVectorType()`（vector.hpp:182-188），buffer 里另存 `v_size`（vector_buffer.hpp:218）。`VectorType` 枚举共六种（src/include/duckdb/common/enums/vector_type.hpp:15-22）：FLAT、FSST、CONSTANT、DICTIONARY、SEQUENCE、SHREDDED；`VectorBufferType` 注释了每种 buffer 与形态的对应（vector_buffer.hpp:30-40）。

### 2.2 Flatten 与 ToUnifiedFormat：统一读接口

`Flatten()` 把任何形态物化为 FLAT（src/common/types/vector.cpp:440-445），仅委托 `Buffer().Flatten(type)`，返回新 buffer 或 nullptr（已 flat）。执行器的惯用入口是 `ToUnifiedFormat`（vector.cpp:458-467）：

```cpp
void Vector::ToUnifiedFormat(UnifiedVectorFormat &format) const {
    format.physical_type = GetType().InternalType();
    auto vtype = GetVectorType();
    if (vtype != VectorType::FLAT_VECTOR && vtype != VectorType::CONSTANT_VECTOR &&
        vtype != VectorType::DICTIONARY_VECTOR) {
        // FSST/SEQUENCE/SHREDDED: flatten first so the buffer can provide unified format
        Flatten();
    }
    Buffer().ToUnifiedFormat(format);
}
```

头文件注释明确：flat/constant/dictionary 三种形态可"零成本"转成 `{data 指针, validity, sel}` 的规范格式；`ToUnifiedFormat` 原名 Orrify，致敬 Orri Erling（vector.hpp:121-127）。`UnifiedVectorFormat` 结构体即 `{const SelectionVector *sel; const_data_ptr_t data; ValidityMask validity; SelectionVector owned_sel; PhysicalType physical_type;}`（src/include/duckdb/common/vector/unified_vector_format.hpp:22-35）——读取方统一写 `data[sel->get_index(i)]`，无需逐形态特判。

DICTIONARY 的统一化同样免拷贝：`DictionaryBuffer::ToUnifiedFormat` 只是把自身 sel 拷入 `owned_sel`、必要时原地 flatten 子字典，`format.data` 直接指向子向量数据（src/common/vector/dictionary_vector.cpp:65-75）。

### 2.3 Sequence：不存数据的向量

`Vector::Sequence(start, increment, count)` 只 new 一个 `SequenceBuffer{start, increment}`（vector.cpp:498-500；sequence_vector.hpp:15-20），没有数据数组也没有 validity——典型用于 rowid 列与表扫描的虚拟列。这也是 `ToUnifiedFormat` 里唯一必须先 Flatten 的"常规"形态（SEQUENCE 无法提供行寻址）。

### 2.4 auxiliary：字符串 heap 与子向量的家

向量自身 16KB 定宽数组放不下的东西，全部挂在 `VectorBuffer::auxiliary_data`（`buffer_ptr<AuxiliaryDataSet>`，vector_buffer.hpp:217 与 117-125 的 `AddAuxiliaryData`）。三个代表：

- **字符串 heap**：`VectorStringBuffer : StandardVectorBuffer` 内含惰性分配的 `StringHeap`（src/include/duckdb/common/vector/string_vector.hpp:25-76）。写入口 `StringVector::AddStringOrBlob → GetStringHeap(vector).AddBlob(data)`（src/common/vector/string_vector.cpp:222-225）；heap 的 `AddBlob` 内联检查 `len <= string_t::INLINE_LENGTH` 则直接内联、否则 `AddBlobToHeap`（src/include/duckdb/common/types/string_heap.hpp:44-49）。
- **Struct 子向量**：`VectorStructBuffer` 持有 `vector<Vector> children` 与顶层 `validity`（struct_vector.hpp:67-71），每个 child 是一个完整的 Vector。
- **List 子向量**：`VectorListBuffer` 持有 `unique_ptr<Vector> child`（list_vector.hpp:74），主 buffer 存 `list_entry_t{offset,length}` 数组，child 可按需 `Reserve` 增长。

`Vector::Initialize` 按 `InternalType()` 分派创建这几种 buffer（vector.cpp:273-297）；`AddHeapReference` 允许一个向量引用另一向量的 auxiliary，防止 heap 被提前释放（vector.cpp:303-313）。

---

## 3. string_t：16 字节、12 字节内联、4 字节前缀

`string_t` 全部常量与 union 布局在 string_type.hpp：`PREFIX_BYTES=4`、`INLINE_BYTES=12`、`HEADER_SIZE=8`（string_type.hpp:28-31）：

```cpp
struct string_t {
    ...
private:
    union {
        struct {
            uint32_t length;
            char prefix[4];
            char *ptr;
        } pointer;
        struct {
            uint32_t length;
            char inlined[12];
        } inlined;
    } value;
};   // string_type.hpp:243-255
```

即 **16 字节**：`len<=12` 时整串内联（`IsInlined()`，string_type.hpp:75-77）；超过时 `length+prefix[4]+ptr` 共 16 字节，prefix 复制前 4 字节内容。判定相等可以先用两个 `uint64` 批量比较 length+prefix，不等即短路（string_type.hpp:173-195）；比较大小用 prefix 做 bswap 后的整数比较（string_type.hpp:203-215）。写入方负责调 `Finalize()` 填 prefix/零填充（string_type.hpp:143-157）；`string_t::VerifyCharacters` 在 debug 下专门检查"prefix 必须等于真实前 4 字节"以防漏调 Finalize（src/common/types/string_type.cpp:40-50）。

## 4. ValidityMask：nullptr 即"全有效"

ValidityMask 是 `TemplatedValidityMask<validity_t>` 的别名（validity_mask.hpp:368），按 **64 位字位图** 组织：`BITS_PER_VALUE=64`，STANDARD_VECTOR_SIZE 对应 `STANDARD_ENTRY_COUNT=(2048+63)/64=32` 个字、256 字节（validity_mask.hpp:64-66）。核心优化是**用空指针编码"无 NULL"**：`validity_mask==nullptr` 时 `CannotHaveNull()` 为真、`GetValidityEntry` 直接返回全 1 的 `MAX_ENTRY`（validity_mask.hpp:82-87, 153-158）。NULL 判定入口 `RowIsValid(row_idx)`：先查 nullptr，再 `row/64` 定字、`row%64` 定位（validity_mask.hpp:169-174, 198-209）。首次 `SetValid` 触发 256 字节的 owned 分配（STANDARD_MASK_SIZE，validity_mask.hpp:66）。

## 5. SelectionVector：零拷贝切片与过滤

`SelectionVector` 是 `sel_t`（uint32）数组的一层薄封装，含裸指针 `sel_vector` 与共享的 `SelectionData`（selection_vector.hpp:12-20, 175-179）。读取端语义是"未设置则恒等映射"：`get_index(idx) => sel_vector ? sel_vector[idx] : idx`（selection_vector.hpp:136-139），因此**过滤算子可以只产出一个 sel 数组而不动数据**——谓词命中的行号写进 sel，下游统一经 `UnifiedVectorFormat::sel` 间接寻址。切片同理：`DataChunk::Slice(other, sel, count)` 对每列调 `Vector::Slice`，dictionary-on-dictionary 时组合 sel 而非拷贝数据（data_chunk.hpp:151；vector.cpp:221-234；组合逻辑见 dictionary_vector.cpp:145-160）。快速构造用 `SelectionVector::Incremental(0, count)`（selection_vector.hpp:62-71）。`sel_t` 上限 2^32 也解释了单个 chunk 行数为何有硬上限。

## 6. DataChunk：列向量组 + 可推导的行数

`DataChunk = vector<Vector> data + optional_idx count + vector<VectorCache>`（data_chunk.hpp:51, 189-193）。公开约定写在类注释：chunk 代表关系的一个子集，所有向量等长；Filter 这类不改数据的算子直接让下游 chunk 引用上游数据、只追加 selection vector（data_chunk.hpp:26-43）。本主干的新特性是**行数可从子向量推导**：`size()` 优先读显式 `count`，否则取第一个带 buffer 的向量的 `v.size()`（`DeriveSize`，src/common/types/data_chunk.cpp:77-89；data_chunk.hpp:54-59）。`SetCardinality` 已被标记 deprecated，演进为 `CheckCardinality/SetChildCardinality`（data_chunk.hpp:64-83）。`Reference()` 逐列 `Vector::Reference` 并复制 count（data_chunk.cpp:173-179）；`Flatten()` 只是把每列 flatten（data_chunk.cpp:288-292）。`Initialize` 默认按 `STANDARD_VECTOR_SIZE` 分配并借 `VectorCache` 复用内存（data_chunk.hpp:108-115；vector_cache.hpp:20-38）。

**STANDARD_VECTOR_SIZE = 2048**，定义于 src/include/duckdb/common/vector_size.hpp:16-21（`DEFAULT_STANDARD_VECTOR_SIZE 2048U`，可由宏覆盖，且静态断言必须为 2 的幂，vector_size.hpp:23-25）。

## 7. Value 与 Vector 的互转

- **Vector→Value**：`Vector::GetValue(index)` 委托 `buffer->GetValue(type, index)`，各 buffer 子类（含 dictionary/sequence）各自实现（vector.cpp:354-373；vector_buffer.hpp:169）。
- **Value→Vector**：`Vector::Reference(const Value &value, count_t count)`（vector.cpp:106-108）落到 `ConstantVector::Reference`：构造仅 1 个值的 constant buffer 并 `SetVectorSize(count)`（src/common/vector/constant_vector.cpp:32-35）——单个标量以 O(1) 内存冒充任意长度向量。
- `Value` 自身是"自描述标量"（type_ + is_null + 联合值，value.hpp:46；value.cpp:133-165），模板 `GetValue<T>()` 支持隐式转换读取（value.hpp:225-226）；内部测试工具 `Value::Hash` 甚至先把自身包成 1 行 Vector 再走 `VectorOperations::Hash`（value.cpp:1717-1724），可见 Vector 才是第一公民。

## 8. VectorOperations 与 cast 基础设施

`struct VectorOperations`（src/include/duckdb/common/vector_operations/vector_operations.hpp:30）集中了向量级运算入口：

- 比较：`Equals/NotEquals/GreaterThan...`（vector_operations.hpp:60-90，实现于 src/common/vector_operations/comparison_operators.cpp）。它有两个版本：物化布尔结果列的 `Equals(left,right,result)`，以及**过滤器专用**的 `Select` 版——返回值是"命中行数"，同时把命中行号写进 `SelectionVector`（vector_operations.hpp:95-152）。后者正是"谓词 → sel 向量"的生产端。
- `Hash/CombineHash`（vector_operations.hpp:163-170，实现于 vector_hash.cpp），聚合/连接的哈希桶入口。
- `Copy`（vector_operations.hpp:199-203，实现于 vector_copy.cpp），带 sel 的 scatter 拷贝。
- 向量化 cast：`VectorOperations::TryCast`（src/common/vector_operations/vector_cast.cpp:9-25），内部经 `CastFunctionSet` 取到 `BoundCastInfo` 后执行。
- 批量循环由 unary/binary/ternary_executor.hpp 的模板承担（同目录）。

类型转换矩阵的调度中心是 `CastFunctionSet::GetCastFunction`（src/function/cast/cast_function_set.cpp:54-86）：

```cpp
if (source == target) {
    BoundCastInfo result(DefaultCasts::NopCast);      // 同类型: 直接 Nop
    result.SetStatisticsCallback(CastStatistics::Propagate);
    return result;
}
for (auto bind_function = registered_bind_functions.rbegin(); ... ) {  // 扩展注册优先
    auto result = bind_cast(*bind_function);
    if (result.HasFunction()) {
        return result;
    }
}
auto result = bind_cast(default_bind_function);          // 内建: DefaultCasts
if (result.HasFunction()) { ... return result; }
// no cast found: return the default null cast
return DefaultCasts::TryVectorNullCast;
```

内建规则按目标类型分发到三十余个 `*CastSwitch`（src/include/duckdb/function/cast/default_casts.hpp:202-250），例如 `DecimalCastSwitch`（decimal_cast.cpp）、`ListCastSwitch/StructCastSwitch`（嵌套 cast 递归到 child，配合 `BindCastInput::GetCastFunction` 在 bind 期逐 child 取函数，cast_function_set.cpp:19-23）。隐式转换代价表 `ImplicitCastCost` 供 binder 做类型裁决（cast_function_set.cpp:187-219）。

## 8b. VectorCache：执行循环的内存复用

每个算子的每次 `GetData` 输出若都 `new` 一批 16KB 数组，分配器将成为瓶颈。`VectorCache`（src/include/duckdb/common/types/vector_cache.hpp:22-38）按类型预置一块缓存，`Vector::ResetFromCache` 让向量重新指回缓存内存而不重新分配（vector.cpp:205-207；src/common/types/vector_cache.cpp:51-84 会递归 reset struct/list/array 的 child cache）。`DataChunk::Initialize` 为每列建一个 cache（data_chunk.hpp:192-193），与"chunk 复用"的执行约定配套。

## 8c. 与行式布局的关系（row/ 一瞥）

向量（列式）与行布局（row layout）在 DuckDB 内部共存：算子落盘、排序、哈希聚合都要把 Vector"打散"成定长 tuple。`TupleDataLayout`（src/include/duckdb/common/types/row/tuple_data_layout.hpp:43-97）以 `GetRowWidth/GetDataWidth/AggregateCount` 描述一行内各列偏移，`GetStructLayout` 允许嵌套类型递归成行内 struct（tuple_data_layout.hpp:68）。gather/scatter 由 tuple_data_scatter_gather.cpp 完成——string 列在行内同样以 string_t 表示，序列化成 scan 时再指回 heap。这条路径也解释了 `GetTypeIdSize`（types.cpp:326）为何是全系统的定宽数据基石：向量数组、行布局、buffer 管理三处共用同一张大小表。

## 9. 嵌套类型的向量表示小结

| 类型 | 物理 | 主 buffer | 子数据位置 |
|---|---|---|---|
| STRUCT/TUPLE/UNION/VARIANT | STRUCT | VectorStructBuffer（含顶层 validity） | `children`（每列一个 Vector，struct_vector.hpp:69） |
| LIST/MAP | LIST | `list_entry_t` 数组 | `VectorListBuffer::child`（list_vector.hpp:74） |
| ARRAY | ARRAY | 固定长度展开 | `VectorArrayBuffer` 的 child（vector.cpp:284-285） |
| DICTIONARY 形态 | 任意 | SelectionVector | `DictionaryEntry::data`（dictionary_vector.hpp:22, 100） |

读取端统一用 `RecursiveToUnifiedFormat` 递归展开 child（vector.cpp:473-496）。

---

## 10. 设计动机

1. **为什么 chunk 是 2048 行**：2^12 行 × 常见 8/16 字节列宽 ≈ 16-32KB，多列合计后与 L1/L2 缓存同量级，一次 morsel 恰好"热"在缓存里；2 的幂使 `row % 64`（validity 位定位）、容量取整等运算全是位运算（vector_size.hpp:23-25 的静态断言强制了这一点），同时让并行 morsel 调度的分块粒度足够细又不够碎。
2. **为什么 LogicalType/PhysicalType 分离**：SQL 面向用户语义（DECIMAL(38,2)、TIMESTAMP_NS），执行面向定宽数组；一个 `GetInternalType()` 映射（types.cpp:63-176）让执行器只需写 INT8..INT128 等 ~15 种模板特化，而 DECIMAL 按宽度自动落到 int16/32/128、六种 timestamp 共享同一套 int64 算子——类型族扩展（如新加时间粒度）无需新增任何物理算子。ExtraTypeInfo 把 width/scale 等参数从热路径剥离。
3. **为什么 string_t 要内联+前缀**：12 字节内联让绝大多数标识符/短键零堆分配、比较就是两次 uint64 读（string_type.hpp:173-185）；4 字节前缀让长字符串的 `==`、`<`、hash、排序在多数情况下不必解引用 `ptr`，等于把"字典序压缩"免费内置进比较算子；16 字节定宽则保证了 VARCHAR 列与其他列共用同一套向量寻址。
4. **为什么 dictionary/constant 是惰性物化而非立即展开**：constant 向量用 O(1) 内存表达 O(n) 行（constant_vector.cpp:32-35），在广播 join 键、聚合初值等场景把拷贝变成 free；dictionary 向量让 filter/slice 只动 4 字节行号数组而不动 16KB 数据，序列化时还能只存"用到的字典子集"（vector.cpp:526-556 特意统计 `used_count*2 < count` 才值得）。代价被推到读取端：算子统一经 `ToUnifiedFormat` 的 sel 间接寻址，只有真正要写/要 hash 大量行时才 `Flatten`（vector.cpp:458-467）。
5. **为什么用 selection vector 而不是物化过滤结果**：filter 的输出行数未知，物化意味着每次谓词都搬运数据；sel 向量把"选了哪些行"编码成行号数组，下游以 `data[sel[i]]` 间接读，跳过的行一个字节都不拷。它同时是切片（Slice 生成 dictionary）、连接探测（probe 侧命中行）、半连接（复用 sel）的统一机制——`get_index` 的"未设置即恒等"设计（selection_vector.hpp:136-139）保证无过滤时代价为零。
6. **为什么 NULL 用"空指针位图"编码**：绝大多数列没有 NULL，`validity_mask==nullptr` 让 null 检查退化为一次指针判空 + 返回常量（validity_mask.hpp:153-158），热循环零开销；有 NULL 时才付 256 字节与位运算的代价。
7. **为什么 Vector 只剩"类型 + buffer 指针"**：把 vector_type/cardinality/validity 全部收进 VectorBuffer 后，`Reference` 一个向量就只是交换一个 shared_ptr（vector.cpp:110-118），浅拷贝、切片、字典共享（`DictionaryEntry` 支持带 id 的可复用全局字典，dictionary_vector.hpp:23-30）都变成引用计数操作，杜绝了大块数据被意外深拷贝，也让 auxiliary（heap/子向量）的生命周期随 buffer 自动管理。

---

## 11. 写作素材清单（文件:行号）

1. src/include/duckdb/common/types.hpp:193 — LogicalTypeId 枚举起点
2. src/include/duckdb/common/types.hpp:71 — PhysicalType 枚举（含 200+ 自有段）
3. src/common/types.cpp:103 — DECIMAL→INT16/32/64/128 的宽度映射
4. src/common/types.cpp:326 — GetTypeIdSize 物理大小表
5. src/include/duckdb/common/vector_size.hpp:16 — DEFAULT_STANDARD_VECTOR_SIZE 2048
6. src/include/duckdb/common/enums/vector_type.hpp:15 — 六种 VectorType
7. src/include/duckdb/common/types/vector.hpp:238 — Vector 仅 type+buffer 两成员
8. src/common/types/vector.cpp:458 — ToUnifiedFormat：三种形态零成本规范化
9. src/include/duckdb/common/types/vector_buffer.hpp:30 — VectorBufferType 与 auxiliary_data
10. src/include/duckdb/common/types/string_type.hpp:243 — string_t 16 字节 union 布局
11. src/include/duckdb/common/types/string_type.hpp:28 — INLINE_BYTES=12 / PREFIX_BYTES=4
12. src/include/duckdb/common/types/string_heap.hpp:44 — AddBlob 内联/入堆阈值
13. src/include/duckdb/common/types/validity_mask.hpp:64 — 64 位位图与 STANDARD_MASK_SIZE
14. src/include/duckdb/common/types/selection_vector.hpp:136 — get_index 恒等回退
15. src/common/types/data_chunk.cpp:77 — DeriveSize：cardinality 从子向量推导
16. src/function/cast/cast_function_set.cpp:54 — cast 矩阵调度入口 GetCastFunction

（备选素材：dictionary_vector.hpp:16 DictionaryEntry 可复用字典；vector.cpp:498 Sequence 零数据向量；struct_vector.hpp:69 / list_vector.hpp:74 嵌套子向量挂载点。）
