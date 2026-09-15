# H · 快照与 Code Cache:V8 的启动加速

> 调研基线:V8 shallow clone,commit `c6a1f7c2`(ppc64: Replace r0 with TemporaryRegisterScope in TypedArrayElementOperand)。
> 所有 `文件:行号` 为仓库相对路径,已用 grep -n / Read 实际核对;引用片段每段 ≤15 行。

---

## 1. 全景:冷启动的三级加速

V8 冷启动要干两类昂贵的初始化:**建对象**(内置对象、Symbol、Map、Script……)和**编译代码**(builtins 机器码)。快照体系把这两类工作都搬到**构建期**,再对"用户 JS 的编译产物"提供运行期缓存:

```text
 构建期(一次性)                          运行期(每个进程/每个页面)
 ─────────────────────────               ─────────────────────────────────────────
 mksnapshot                              ① embedded blob   : builtins 机器码已
   ├─ 起一个 Isolate,跑 bootstrap          在 .text/.rodata 里,启动免编译
   │  生成全部内置对象 + 全部 builtins        (InstructionStartOf 直取,跳转执行)
   ├─ Snapshot::Create 序列化堆 → blob
   │    (read-only / startup / shared /    ② startup snapshot : 反序列化直接"长出"
   │     context 四段,可 zlib 压缩)          内置堆对象,免 bootstrap 重建
   └─ EmbeddedFileWriter 把 builtins
      机器码写成 C 数组编进二进制            ③ context snapshot : NewContextFromSnapshot
                                            克隆出每个 JS Context
 用户 JS(v8::ScriptCompiler)
   ├─ CreateCodeCache    : 把编译好的        ④ code cache      : SFI+字节码整体反序列化,
   │  SFI/字节码序列化成 CachedData          免 parse+编译(不加速执行)
   └─ kConsumeCodeCache  : 校验后反序列化
```

三层各管一段,互不重叠(引用 `src/snapshot/snapshot.h:70`、`src/snapshot/code-serializer.h:77`):

| 层 | 免掉什么 | 内容 | 生命周期 |
|---|---|---|---|
| embedded blob | builtins **编译** | 纯机器码+元数据,不进堆 | 跟随 V8 二进制,进程内只读共享 |
| snapshot blob | 内置对象**创建** | 堆对象图(4 段)+ 版本/校验头 | 跟随 V8 二进制(或外置 snapshot_blob) |
| code cache | 用户 JS **parse+编译** | 用户脚本的 SFI 对象图 | 跟随用户 JS 文件,任意失效 |

一条重要的约束把三层串起来:快照/code cache 反序列化出来的对象最终要指向 embedded blob 里的 builtins,所以**快照、embedded blob、二进制必须是同一次构建的同版本产物**——版本校验失败会直接 FATAL(见 §5.2)。

---

## 2. mksnapshot 专节:构建期生成与 embedded blob

### 2.1 mksnapshot 的 main 流程

mksnapshot 是构建期跑的独立可执行文件,入口 `src/snapshot/mksnapshot.cc:225`。关键步骤(行号均为 mksnapshot.cc):

1. 强制 `predictable = true`(可复现快照,mksnapshot.cc:229)并临时关 `use_ic`(mksnapshot.cc:234);
2. 起一个真 Isolate,把 `EmbeddedFileWriter` 挂进去(mksnapshot.cc:285);
3. 特意把 code range 设为 `kMaxPCRelativeCodeRangeInMB`,使 builtins 相对跳转可达(mksnapshot.cc:292-300,注释原文 "Set code range such that relative jumps for builtins to builtin calls in the snapshot are possible");
4. `v8::SnapshotCreator creator(isolate, create_params)`(mksnapshot.cc:303),然后 `CreateSnapshotDataBlob(creator, embed_script)` 真正执行 bootstrap + 序列化(mksnapshot.cc:305,内部走 `src/snapshot/snapshot.cc:778` 的 `CreateSnapshotDataBlobInternal`);
5. `WriteEmbeddedFile(&embedded_writer)` 把 builtins 机器码写成 C 源文件(mksnapshot.cc:307,实现在 194-197:取 `EmbeddedData::FromBlob()` 后 `writer->WriteEmbedded(&embedded_blob)`);
6. 可选生成 static-roots 表(mksnapshot.cc:309-316);
7. 可选用 warmup 脚本"焐热"快照(mksnapshot.cc:330-334),最后 `snapshot_writer.WriteSnapshot(blob)` 写出 snapshot_blob(mksnapshot.cc:339)。

warmup 的原理在 `src/snapshot/snapshot.cc:817`(`WarmUpSnapshotDataBlobInternal`):用冷快照起 Isolate → 跑 warmup 脚本触发编译/IC 建立 → **再开一个干净 context** → 重序列化。这样热身效应留在堆里,而 context 本身不被污染。

`Snapshot::Create` 是序列化总入口(src/snapshot/snapshot.cc:401),四段各用一个序列化器:

```cpp
// src/snapshot/snapshot.cc:412-419
ReadOnlySerializer read_only_serializer(isolate, flags);
read_only_serializer.Serialize();
...
SharedHeapSerializer shared_heap_serializer(isolate, flags);
StartupSerializer startup_serializer(isolate, flags, &shared_heap_serializer);
startup_serializer.SerializeStrongReferences(no_gc);
```

context 段在 429-431 逐个 `ContextSerializer::Serialize`,最后 startup 段补弱引用与 deferred(440),汇总进 `SnapshotImpl::CreateSnapshotBlob`(475)。只读段排在 blob 最前,注释说明是为了让 RO space image 页对齐(snapshot.cc:555-557)。

### 2.2 快照 blob 的物理布局

blob 头部与四段数据的布局定义在 `src/snapshot/snapshot.cc:73-89` 的注释里,偏移常量在 91-106:

```text
[0] number of contexts N      [1] rehashability   [2] checksum
[3] read-only snapshot checksum
[4] (64 字节) version string
[5] offset to startup   [6] offset to shared heap
[7..] offset to context i
随后依次:read-only 段 → startup 段 → shared heap 段 → context 0..N-1 段
```

每一段都是一份 `SnapshotData`:两字头(magic+payload 长度,`src/snapshot/snapshot-data.h:96-101`)加序列化字节码流;`V8_SNAPSHOT_COMPRESSION` 下各段先用 zlib raw 压缩(`src/snapshot/snapshot-compression.cc:21-64`,前 4 字节手工存未压缩长度,45-51 行调 `CompressHelper`)。运行期 `Snapshot::Initialize`(snapshot.cc:177)先 `CheckVersion`+`VerifyChecksum`(181-184),再 `MaybeDecompress` 四段(193-197),交给 `Isolate::InitWithSnapshot`(src/execution/isolate.cc:5940)。

### 2.3 embedded blob:布局与写入

embedded blob 与快照 blob 是**两个不同的东西**:它只装 builtins 机器码,不装堆对象。`EmbeddedData` 分 code / data 两个 section,布局注释在 `src/snapshot/embedded/embedded-data.h:212-227`:

```text
data: [0] data 段 hash  [1] code 段 hash  [2] isolate hash
      [3..] 每个 builtin 的 LayoutDescription{instruction_offset,length,metadata_offset}
      [n..] 按 offset_end 升序的 BuiltinLookupEntry 二分查找表
      [x..] 各 builtin 的 metadata
code: 各 builtin 的指令流(按 "embedded snapshot order" 排列)
```

结构体与偏移计算:LayoutDescription(embedded-data.h:174-188)、BuiltinLookupEntry(197-208)、`FixedDataSize()`(252-256)、代码对齐 `PadAndAlignCode = RoundUp<kCodeAlignment>(size+1)`(290-294)。`EmbeddedData::NewFromIsolate`(src/snapshot/embedded/embedded-data.cc:240)遍历 `builtins->code(builtin)` 收集各段;若开了 `--reorder-builtins` 且 profile 哈希匹配,用 `BuiltinsSorter` 按执行密度重排 builtin 顺序(embedded-data.cc:253-270;算法注释见 `src/snapshot/sort-builtins.h:11-30`:聚类合并,按调用概率 0.1 阈值、簇上限 1MB)。

`EmbeddedFileWriter::WriteCodeSection`(src/snapshot/embedded/embedded-file-writer.cc:168)把整个 code section 声明进 `.text`(177 行 `SectionText()`),然后按 embedded 顺序逐个 `WriteBuiltin`(205-209)——最终产物就是二进制 `.text/.rodata` 里的两个全局符号 `v8_Default_embedded_blob_code_` / `..._data_`。运行期 `Isolate::InitializeDefaultEmbeddedBlob`(src/execution/isolate.cc:5799)把这对符号设为当前 blob,多 Isolate 经 "sticky blob" 引用计数共享(5804-5812)。

**short builtin calls 优化**:PC 相对寻址范围有限(如 arm64 128MB,`src/codegen/arm64/constants-arm64.h:33`),`.text` 里的 blob 可能离 code range 太远。`Isolate::InitializeIsShortBuiltinCallsEnabled`(isolate.cc:5860)决定是否启用:老生代阈值 2GB(isolate.cc:5869-5870,常量在 `src/common/globals.h:252`)或 code range 已有副本;满足则 `MaybeRemapEmbeddedBuiltinsIntoCodeRange`(isolate.cc:5890)把 blob **再映射一份到 code range 内**——`CodeRange::RemapEmbeddedBuiltins`(src/heap/code-range.cc:495)从 code range 末端往下找一个 PC 相对可达的位置 `AllocatePages` 并 memcpy(526-553),之后 `embedded_blob_code_` 指向副本(isolate.cc:5905)。进程内所有 Isolate 共享同一份副本,found via `embedded_blob_code_copy_` 缓存(code-range.cc:507-516)。

---

## 3. 序列化格式专节:对象图字节码

### 3.1 字节码总表

序列化产物不是 JSON 式自描述格式,而是极紧凑的**单字节操作码流**,定义在 `src/snapshot/serializer-deserializer.h:79-191`:

| 字节 | 操作码 | 含义(行号) |
|---|---|---|
| 0x00-0x03 | `kNewObject` + 空间号 | 新建对象(85) |
| 0x04- | `kBackref` | 引用已序列化对象(87) |
| 0x05 | `kReadOnlyHeapRef` | 只读堆对象(89) |
| 0x06/0x07 | startup/shared 对象缓存 | 缓存命中(91,97) |
| 0x08 | `kRootArray` | 根表项(93) |
| 0x09 | `kAttachedReference` | 附件表(95) |
| 0x0b | `kSynchronize` | 段同步哨兵(105) |
| 0x12 | `kVariableRawData` | 变长原始数据(116) |
| 0x15 | `kExternalReference` | 外部引用按 id(120) |
| 0x1c/0x1d | `kRegister/ResolvePendingForwardRef` | 前向引用(133,136) |
| 0x40-0x5f | `kRootArrayConstants` | 前 32 个根直接编码(177) |
| 0x60-0x7f | `kFixedRawData` | 1-32 字长的固定原始数据(180) |
| 0x80-0x8f | `kFixedRepeatRoot` | 同一根重复 2-17 次(187) |
| 0x90-0x97 | `kHotObject` | 8 个"热对象"工作集(190) |

高频值直接编码进操作码本身:`kRootArrayConstantsCount = 0x20`、`kFixedRawDataCount = 0x20`、`kFixedRepeatRootCount = 0x10`、`kHotObjectCount = 8`(serializer-deserializer.h:69-77)。空间枚举只有 4 个(kReadOnlyHeap/kOld/kCode/kTrusted,`src/snapshot/references.h:18-24`),所以 `kNewObject`/`kBackref` 各占满一个 4 值范围(serializer-deserializer.h:66 的 static_assert)。

### 3.2 序列化一个对象

`Serializer::SerializeObject`(src/snapshot/serializer.cc:161)先做归一化:ThinString 直接穿透到内部化字符串(162-165),Code 只允许 builtin 或退化为 BytecodeArray(166-177)。随后逐槽尝试由简到繁的编码路径(`CodeSerializer::SerializeObjectImpl` 里的顺序最清晰,src/snapshot/code-serializer.cc:125-128):hot object → root → backref → read-only 引用,都不中才真正落一个新对象。

**back-ref 机制**:`reference_map_`(IdentityMap)记录"对象 → 序号"。`SerializeBackReference`(serializer.cc:236-262)查出序号后 `Put(kBackref)` + `PutUint30(back_ref_index)`(258-259);注册发生在 `SerializePrologue` 尾部——`num_back_refs_++` 后 `reference_map()->Add(*object_, BackReference(num_back_refs_-1))`(serializer.cc:564,573-575)。序号即"第 n 个被序列化的新对象",反序列化端用数组 `back_refs_` 对应回取。

**hot object**:两端各有一个 8 槽环形工作集(`Serializer::HotObjectsList`,serializer.h:346)。每次发出 backref/根都会 `hot_objects_.Add(object)`(serializer.cc:302,326),下次再遇到就只发 1 字节 `HotObject::Encode(index)`(serializer.cc:221-234);反序列化端在 `GetBackReferencedObject` 里对称地 `hot_objects_.Add(obj)`(src/snapshot/deserializer.cc:760)。

**forward ref(前向引用)**:出现环时对象可能先被引用后定义。`PutPendingForwardReference` 发 `kRegisterPendingForwardRef` 并登记 slot(serializer.cc:348-361),对象真正序列化后再逐个发 `kResolvePendingForwardRef` + id 回填(serializer.cc:363-373)。

**新对象的编码顺序**(ObjectSerializer::SerializePrologue,serializer.cc:505-547):`kNewObject+空间` → 30 位"字数" → **先序列化 map**(513-518,反序列化端分配后要立刻知道对象类型) → ExtendedMap 的 bit_field_ex(519-527) → 沙箱下 `kInitializeSelfIndirectPointer`(539-543) → 解析 pending 引用(547) → 各字段。序列化前还会把可重建数据摘除:`Snapshot::ClearReconstructableDataForSerialization`(snapshot.cc:222)丢弃 SFI 编译产物、feedback vector、regexp 编译码,JSFunction 统一指回 `CompileLazy`(288)。

### 3.3 反序列化:堆重分配

反序列化驱动在 `Deserializer` 模板(可跑在主线程 Isolate 或后台 LocalIsolate 上)。Startup 段的骨架在 `src/snapshot/startup-deserializer.cc:22`(`DeserializeIntoIsolate`):校验外部引用表(41,102-112)→ 迭代 Smi 根/强根/启动缓存/弱根(43-51)→ deferred 对象(52)→ `FlushICache`(68)→ `builtins()->MarkInitialized()`(84)。

单对象重分配在 `Deserializer::ReadObject(SnapshotSpace)`(src/snapshot/deserializer.cc:791),顺序极其讲究(818-834 的注释是必读):

```cpp
// src/snapshot/deserializer.cc:838-845
Tagged<HeapObject> raw_obj =
    Allocate(allocation, size_in_bytes,
             HeapObject::RequiredAlignment(in_shared_space, *map));
raw_obj->set_map_after_allocation(isolate_, *map);
MemsetTagged(raw_obj->RawField(kTaggedSize),
             Smi::uninitialized_deserialization_value(), size_in_tagged - 1);
```

即:分配(共享堆字符串重定向见 807-816)→ 装 map → 其余字段先填固定 Smi 哨兵 → 再逐槽 `ReadData` 覆盖。这样做是因为"填字段可能触发 GC"(如写 barrier、分配),对象必须在下次分配前处于"GC 可遍历"状态。底层分配就是常规堆请求:`Allocate` → `heap()->AllocateRawOrFail`(deserializer.cc:1711-1724,空间映射在 775-788 的 `SpaceToAllocation`)。字节码分发总开关 `ReadSingleBytecodeData` 在 deserializer.cc:1028-1114;`ReadBackref`(1157-1170)、`ReadRootArrayConstants`/`ReadFixedRawData`(1630-1655)等一一对应上表。

**只读段走专用镜像格式**:RO space 用更接近"整页镜像"的私有字节码(`kAllocatePage/kSegment/kReadOnlyRootsTable/...`,src/snapshot/read-only-deserializer.cc:27-56 的 `DeserializeImpl`),由 `ReadOnlyHeap::DeserializeIntoIsolate`(src/heap/read-only-heap.cc:89-99)驱动,并支持多 Isolate 共享同一份 RO artifacts;启用 static roots 时连 RO 地址都是编译期常量(`src/snapshot/read-only-serializer.cc:570` 的 `Serialize` 只做镜像+可 rehash 检查,582 `Pad()`)。

---

## 4. Code Cache 专节:用户 JS 编译产物的缓存

### 4.1 写入:CreateCodeCache → CodeSerializer::Serialize

公开 API 是 `v8::ScriptCompiler::CreateCodeCache`(src/api/api.cc:2990-3016,函数版 3018-3032),内部全部收敛到 `CodeSerializer::Serialize`(src/snapshot/code-serializer.cc:53):取 toplevel SFI,算 `source_hash`,挂到 `CodeSerializer` 上(79-81),`SerializeSharedFunctionInfo`(104-116)以 SFI 为根遍历堆、`Pad()` 后把 payload 包上头部。序列化对象时做了大量"剥离"——Script 的 host_defined_options 置空(152-156)、DebugInfo 的插桩字节码还原(175-181)、UncompiledData 的 job 指针清零(207-227),并硬性 CHECK 禁止 Map/ JSGlobalProxy / JSFunction / Context 进缓存(code-serializer.cc:249-261)。

头部由 `SerializedCodeData` 构造函数写入(code-serializer.cc:726-760),布局在 `src/snapshot/code-serializer.h:117-127`:

```cpp
// src/snapshot/code-serializer.h:118-127(均为 uint32 槽)
kVersionHashOffset    // Version::Hash()
kSourceHashOffset     // 源串长度+wrapped/module 位
kFlagHashOffset       // FlagList::Hash()
kReadOnlySnapshotChecksumOffset
kPayloadLengthOffset
kChecksumOffset       // 可选,verify_snapshot_checksum
// kHeaderSize = POINTER_SIZE_ALIGN(kUnalignedHeaderSize)
```

### 4.2 校验:九种拒绝原因

消费端入口 `CodeSerializer::Deserialize`(code-serializer.cc:476)先 `SerializedCodeData::FromCachedData`(853-867)做 sanity check,失败即 `cached_data->Reject()`(863)并回退到正常 parse+编译(507-515 上报 `code_cache_reject_reason`)。核心检查 `SanityCheckWithoutSource`(780-814)依次为:大小(782)→ magic number = `0xC0DE0000 ^ ExternalReferenceTable::kSize`(`src/snapshot/snapshot-data.h:46`)→ **version hash**(789-792,即 `Version::Hash()` = major/minor/build/patch 的 hash_combine,`src/utils/version.h:30-33`)→ **flag hash**(793-796,`src/flags/flags.cc:1559`)→ **只读快照 checksum**(797-801,从当前 snapshot blob 头部取,snapshot.cc:671-675)→ payload 长度(802-806)→ 可选整体 checksum(807-812)。七项合source hash 共九种结果,枚举个数有 static_assert 锁死(code-serializer.h:58)。

source hash 只由"源长度 + 是否 wrapped + 是否 module"构成(code-serializer.cc:816-830)——**故意不含源内容哈希**:嵌入方(如 Chrome)自己用更强的内容校验,V8 只需防"拿 A 脚本的缓存当 B 脚本用"这类长度级错配。全部通过后 `ObjectDeserializer::DeserializeSharedFunctionInfo` 把 SFI 对象图装回堆(518-519),必要时与编译缓存中已有 Script 做 `BackgroundMergeTask` 合并(532-541)。后台消费路径是 `StartDeserializeOffThread` / `FinishOffThreadDeserialize`(576-602 / 604-724):后台线程先做不含 source 的检查(583-585),拿到源后再补 source 检查(625-632)。编译器侧的接线在 `src/codegen/compiler.cc:3979-3985`(`kConsumeCodeCache` 选项),后台任务封装在 2831-2897。

值得注意:code cache 缓存的是 **SFI + BytecodeArray 级别的"编译产物"**,不是 OptimizedCode——机器码会被 `ClearReconstructableDataForSerialization` 一路清掉,缓存命中只省 parse/字节码生成,不省执行。

---

## 5. 设计动机

### 5.1 为什么 builtins 机器码要嵌进二进制

其一,**免编译**:每次起 Isolate 都把 1500+ 个 builtins 用生成器重新编译一遍不可接受,embedded blob 让 builtins 变成"数据"。其二,**地址距离**:builtin 间、builtin 与 JIT 代码间的大量调用走 PC 相对寻址,`kMaxPCRelativeCodeRangeInMB`(arm64 128MB,arm 32MB)限制了可达范围, hence blob 要么嵌在 `.text`,要么 remap 进 code range(§2.3)。其三,**安全**:这段机器码只读(RX),跨 Isolate 物理共享一份,`Builtins::kAllBuiltinsAreIsolateIndependent` 保证不依赖 isolate 状态(embedded-file-writer.cc:203 的 static_assert);配合 blob 自带 code/data 双 hash 与 isolate hash(embedded-data.h:156-169),DEBUG 下 `IsolateIsCompatibleWithEmbeddedBlob` 会校验堆与 blob 一致(isolate.cc:5808-5815)。mksnapshot 甚至把 code range 上限专门设小以保证生成代码的相对跳转可编码(mksnapshot.cc:292-300)。

### 5.2 快照与堆的版本绑定

快照里的字节流编码了**堆的精确形状**(对象大小、字段偏移、map 布局、root 序号),与 V8 构建强耦合,所以启动时 `CheckVersion` 拿 64 字节版本串逐字节比对,不合即 `FATAL("Version mismatch between V8 binary and snapshot...")`(snapshot.cc:735-751);再加整体 checksum(snapshot.cc:641-651)与 rehashability 标志(663-668)。这不是保守,而是必须:字节码里连"root 表第几项"都编进去了(serializer.cc:300-302),对象布局挪一格就全盘错乱。

### 5.3 code cache 的失效策略

五元组校验(version/flags/RO-checksum/length/source)把"缓存一定能被当前二进制安全消化"变成 O(1) 检查。策略上取**激进失效**:任何一项不匹配就整个 reject、回退全量编译(拒绝原因直方图 code-serializer.cc:512-513),没有部分复用。`FlagList::Hash` 连 JS 可见 flag 变化都不放过——因为 flag 会改变字节码生成策略。对外还提供 `CachedDataVersionTag`(api.cc:2985-2988,version hash ⊕ flag hash)给嵌入方做粗筛。

### 5.4 外部参照

一句话收敛:V8 快照本质是"**堆的镜头文件**"——像 git 把工作树打包成对象图、PG 把脏页 checkpoint 成磁盘镜像一样,把"初始化完成的堆"原样搬运输;但 V8 的独特点在于格式不是页级 dump 而是可重定位的对象图字节码,反序列化时在**新地址空间重新分配**而非原地址映射,所以它对 ASLR/多实例天然友好,代价是必须做逐对象引用重定位(back-ref/forward-ref)和更严的版本绑定。

---

## 6. FAQ 素材

1. **快照文件里有 JavaScript 代码吗?** 有源码字符串与字节码(内置 JS builtins 编译产物),但没有独立"脚本文件"概念;mksnapshot 可用 `--startup-src`/extras 把额外 JS 预编译进快照(mksnapshot.cc:271-274)。
2. **embedded blob 和 snapshot_blob 是一个东西吗?** 不是。前者只有 builtins 机器码(嵌二进制),后者是堆对象图(可外置文件);校验链也不同:blob 靠 64 字节版本串+checksum,embedded 靠 code/data hash。
3. **为什么快照能加速启动却不能加速执行?** 它免去的是初始化(parse/编译/建对象),反序列化出的 Code 对象指向 embedded blob 执行;JIT 层面的优化代码不在快照里(序列化前被 Clear,JSFunction 指回 CompileLazy,snapshot.cc:288)。
4. **自定义 context 快照怎么生成?** `v8::SnapshotCreator`:AddContext/AddData → CreateBlob(`include/v8-snapshot.h:135` 起;实现在 `SnapshotCreatorImpl::CreateBlob`,snapshot.cc:1033,最终收敛到 `Snapshot::Create` 1147)。嵌入方典型做法:起默认快照 → 跑自己的 JS 预置环境 → 重序列化。
5. **back-ref 和 forward-ref 分别解决什么?** back-ref 复用已序列化对象(序号寻址),forward-ref 处理环:先登记 slot、后回填(kRegisterPendingForwardRef/kResolvePendingForwardRef,serializer.cc:348-373)。
6. **反序列化时对象为什么先填 Smi 哨兵?** 填字段过程可能 GC,对象必须先"GC 可遍历":map 最先装,其余字段先置 `Smi::uninitialized_deserialization_value()`(deserializer.cc:818-845 注释+代码)。
7. **code cache 为什么用长度而非内容做 source hash?** 内容校验交给嵌入方(V8 无密钥、无强哈希诉求),长度+module/wrapped 位已防"张冠李戴";真正的危险——版本/flag 不匹配——由独立四槽拦截(code-serializer.cc:816-830,780-814)。
8. **为什么只读段要单独一种格式?** RO 堆生命周期是进程级、多 Isolate 共享,按"页镜像+根表"整块重建(read-only-deserializer.cc:27-56)比逐对象快得多,还支持静态根地址(static roots)。
9. **快照体积多大?靠什么压?** 各段独立 zlib raw 压缩(snapshot-compression.cc:21-64),启动时先解压再消费(MaybeDecompress,snapshot.cc:136-147);`--serialization-statistics` 可打印每段字节数(snapshot.cc:569-618)。
10. **一个进程多个 Isolate 会复制快照吗?** RO 段与 embedded blob 物理共享(artifacts/sticky blob,read-only-heap.cc:60-75、isolate.cc:5799-5812);startup/context 段每个 Isolate 各自反序列化进自己的堆。

## 7. 深挖方向

1. **字节码预算**:UNUSED_SERIALIZER_BYTE_CODES 占位(serializer-deserializer.h:34-60)显示编码空间已逼近上限,0x98 以后全空;新增空间(如 SharedOld)会动 `kNumberOfSnapshotSpaces` 并连带 kNewObject/kBackref 范围(66 的 static_assert 警告)。
2. **sandbox 下的可信对象序列化**:`kIndirectPointerPrefix`/`kInitializeSelfIndirectPointer`/`kAllocateJSDispatchEntry`(serializer-deserializer.h:151-170)与 `PostProcessExposedTrustedObjects`(deserializer.cc:447)——JSDispatchTable 条目如何在反序列化中重建。
3. **static roots**:mksnapshot 生成静态根表(mksnapshot.cc:309-316 → `src/snapshot/static-roots-gen.cc`),RO 对象地址变成编译期常量后,read-only-serializer 走完全不同的镜像路径(read-only-serializer.cc:413-435 的 `V8_STATIC_ROOTS_BOOL` 分支)。
4. **后台反序列化**:Deserializer<LocalIsolate> 双实例化(design 见 deserializer.cc:607 的 LocalIsolate 特化)与 code cache 的 OffThread 路径——两端校验如何分工(先无源检查,后补源检查,code-serializer.cc:583-590 vs 625-632)。
5. **builtin 重排**:profile 驱动的 `BuiltinsSorter`(sort-builtins.h:11-30)如何把热点 builtin 聚进同一 I-cache 簇,以及 `all_hash_matched` 门槛(embedded-data.cc:254)——否则退回 builtin id 序。

## 8. 写作要点速查表

| 主题 | 文件:行号 | 要点 |
|---|---|---|
| blob 头部布局 | src/snapshot/snapshot.cc:73-106 | N contexts/rehash/checksum/版本串/各段 offset |
| 启动入口 | src/snapshot/snapshot.cc:177-202 | Initialize:查版本+checksum→解压→InitWithSnapshot |
| 版本 FATAL | src/snapshot/snapshot.cc:735-751 | 64 字节版本串逐字节比对 |
| 序列化总入口 | src/snapshot/snapshot.cc:401-483 | RO→Shared→Startup→Context 四段,CreateSnapshotBlob |
| warmup 快照 | src/snapshot/snapshot.cc:817-852 | 冷 blob 跑脚本→再开干净 context→重序列化 |
| mksnapshot main | src/snapshot/mksnapshot.cc:225-346 | 285 挂 writer/292 code range/305 生成/307 写 embedded/339 写 blob |
| embedded 布局 | src/snapshot/embedded/embedded-data.h:212-227 | data(hash+Layout+查找表+metadata)/code 两段 |
| builtin 写入 .text | src/snapshot/embedded/embedded-file-writer.cc:168-211 | SectionText 后逐 builtin WriteBuiltin |
| short builtin calls | src/execution/isolate.cc:5860-5910;src/heap/code-range.cc:495-553 | 2GB 阈值;remap 到 code range 末端 |
| 字节码定义 | src/snapshot/serializer-deserializer.h:79-191 | kNewObject=0x00/kBackref=0x04/0x40 根/0x60 raw/0x80 repeat/0x90 hot |
| back-ref 注册 | src/snapshot/serializer.cc:564,573-575 | num_back_refs_+reference_map Add |
| 对象编码顺序 | src/snapshot/serializer.cc:505-547 | NewObject→字数→map→bit_field_ex→self-indirect |
| 反序列化分配 | src/snapshot/deserializer.cc:791-845 | 分配→装 map→Smi 哨兵→ReadData;AllocateRawOrFail:1723 |
| 字节码分发 | src/snapshot/deserializer.cc:1028-1114 | ReadSingleBytecodeData switch 总表 |
| Startup 反序列化骨架 | src/snapshot/startup-deserializer.cc:22-100 | 根迭代→deferred→FlushICache→MarkInitialized |
| RO 镜像格式 | src/snapshot/read-only-deserializer.cc:27-56 | kAllocatePage/kSegment/kReadOnlyRootsTable |
| code cache 头 | src/snapshot/code-serializer.h:117-127 | version/source/flag/RO-checksum/payload/checksum |
| code cache 校验 | src/snapshot/code-serializer.cc:780-814 | 七步 SanityCheckWithoutSource,失败 Reject 回退编译 |
| 消费接线 | src/codegen/compiler.cc:3979-3985 | kConsumeCodeCache → CodeSerializer::Deserialize |
