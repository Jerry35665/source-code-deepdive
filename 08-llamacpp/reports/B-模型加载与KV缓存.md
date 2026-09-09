# B 章 · 模型加载与 KV 缓存

> 调研对象:llama.cpp(github.com/ggml-org/llama.cpp,本地解压快照)。文中行号均指该仓库快照,路径省略前缀 `repos/llamacpp/`。
> 特别说明:本快照是**重构后的新版本**——KV cache 已引入 stream(多序列流)、`slot_info` 分散写入(`ggml_set_rows`)、`llama_memory_i` 统一内存接口,并且**经典 defrag 已被移除**、旧版基于 `u_pos` 时间戳的驱逐也已不复存在。下文所有结论均以本快照代码为准,凡与社区旧资料冲突处会显式标注。

---

## ① 全景:从 GGUF 文件到可推理模型的流水线

整条流水线分四个阶段(`src/llama.cpp:316-378`):

```
GGUF 文件
  │  gguf_init_from_file()           只读 header + KV + 张量索引,no_alloc
  ▼
llama_model_loader                  建权重索引 weights_map、meta 校验、按架构取超参
  │  model->load_hparams(ml)        src/llama.cpp:348
  │  model->load_vocab(ml)          src/llama.cpp:356
  │  model->load_tensors(ml)        src/llama.cpp:369  → create_tensor + load_all_data(mmap/异步上传)
  ▼
llama_model(权重就位,含 arch/hparams)
  │  llama_init_from_model → llama_context
  │  model.create_memory(params, cparams)          src/llama-context.cpp:386-396
  ▼
llama_kv_cache / llama_kv_cache_iswa / llama_memory_hybrid ...   (llama_memory_i 接口族)
  │  init_batch → prepare(找 slot) → build graph → apply_ubatch(set_rows 写入)
  ▼
每 token 逐 ubatch 解码
```

- 阶段一由 `ggml/src/gguf.cpp` 完成:解析 magic、version、KV 元数据、张量索引,并按需把张量二进制段挂进一个 `no_alloc` 的 ggml context(`ggml/src/gguf.cpp:798-905`)。
- 阶段二由 `src/llama-model-loader.cpp` 完成:`gguf_init_from_file` 以 `no_alloc=true` 拿到**纯元数据视图**(`src/llama-model-loader.cpp:562-575`),然后为每个张量建立 `(文件, 偏移, 形状)` 的 `llama_tensor_weight` 索引(`src/llama-model-loader.h:34-51`);架构名从 `general.architecture` 读出后经 `llm_arch_from_string` 变成枚举(`src/llama-model-loader.cpp:576-577`)。
- 阶段三把权重真正灌进各后端 buffer:`load_all_data()`(`src/llama-model-loader.cpp:1486-1790`)走 mmap 直接指针或「pinned memory + event 异步上传 GPU」两条路。
- 阶段四在 `llama_context` 构造时按架构分派内存对象(`src/llama-model.cpp:2245` 起 `create_memory` 巨型 switch):普通稠密模型 → `llama_kv_cache_iswa`(SWA 模型)或单个 `llama_kv_cache`;注意力+递归混合模型 → `llama_memory_hybrid(_iswa/_idx)`;纯编码器(BERT 系)→ `nullptr`(`src/llama-model.cpp:2254-2268`)。

---

## ② GGUF 格式逐字段解读

### 2.1 文件布局

```
偏移        内容                                   读取位置(ggml/src/gguf.cpp)
0x00       "GGUF" magic (4B)                       :457-479
0x04       version  u32 (当前 GGUF_VERSION=3)      :485-514   ggml/include/gguf.h:42
0x08       n_tensors i64                           :516-525
0x10       n_kv      i64                           :527-536
─── KV 元数据区(顺序读 n_kv 条) ─────────────────  :544-605
   key      string  = u64 长度 + UTF-8 bytes       :341-356
   type     i32    (gguf_type;若为 ARRAY:)         :575-580
     ├─ arr_type i32
     └─ n        u64
   value    按 type 定长 / 字符串再带 u64 长度
   ※ 重复 key 直接判非法                              :565-570
─── 张量信息区(顺序读 n_tensors 条) ─────────────  :632-756
   name     string(name ≥ GGML_MAX_NAME 拒绝)      :647-651,重名拒绝 :655-661
   n_dims   u32(≤ GGML_MAX_DIMS=4)                 :669-675
   ne[0..n_dims-1]  i64(其余维度补 1)              :677-690,溢出检查 :694-704
   type     i32(ggml_type,须 < GGML_TYPE_COUNT)    :711-720
   offset   u64(相对 data 段起点,须按 ALIGNMENT 对齐) :752-753,注释 :215
─── padding 到 alignment 2 的幂校验 ──────────────  :614-628(data 段前) :766-770
─── tensor data 二进制段 ─────────────────────────  :772-796
   第 i 个张量数据位于 data_offset + info[i].offset
   校验:offset 必须严格等于前面所有张量 PAD(nbytes, alignment) 的累加  :777-796
```

要点:

1. **头里 n_tensors 在 n_kv 之前**(读 `:516-536`、写 `:1633-1634`),这与很多博客写的顺序相反,是 GGUFv2/v3 的实际布局。
2. **13 种元数据类型**(`gguf.cpp:93-108`,`static_assert(GGUF_TYPE_COUNT == 13)`),BOOL 按 i8 存。字符串统一 `u64 长度前缀 + 内容`,上限 1 GiB(`:19,:346-353`);数组在 KV 区表现为「外层 type=ARRAY + 内层元素类型 + u64 元素个数」三层嵌套(`:576-580`),词表 `tokenizer.json` 这类大数组因此单条 KV 就可占数 MB。
3. **张量信息区逐字段语义**:`name` 限定在 `GGML_MAX_NAME` 内并查重(:647-661);`n_dims` 允许 1..4,不足 4 的维度在内存里补 1(:677-690),四维乘积的 int64 溢出检查防恶意文件(:694-704);`type` 写成 i32 读回后校验范围与「最内维必须整除该量化类型的 block size」(:715-731)——这一条保证任何张量都能按行做 dequant;`nb[0..3]` 步长由 type_size 与 ne 现场重算,不占文件空间(:742-746);最后的 `offset` 是相对 data 段的无符号 64 位偏移。
4. **对齐**:`general.alignment` KV 可覆盖默认 32(`ggml/include/gguf.h:46`),必须是 2 的幂(`gguf.cpp:624-628`);每个张量尺寸向上 PAD 到对齐后紧凑排列(`gguf_add_tensor`,`:1385-1398`)。
5. **mmap 友好性**:header/KV/张量索引总是一个很小的前缀;`ctx->offset = gr.tell()` 记下 data 段起点(`:772-773`),加载器只需 `data_offset + tensor.offset` 即可得到文件内绝对偏移——这正是 `llama_tensor_weight` 的构造(`src/llama-model-loader.h:46`)。读取端抽象成 `gguf_reader` 回调(`gguf.cpp:231-420`),文件/内存 buffer/远端分块(`gguf_init_from_callback`,`:910-917`)都能当数据源。
6. **版本防御**:v1 直接拒绝(`:503-506`);高于实现版本拒绝(`:507-511`);`version & 0xFFFF == 0` 提示大小端不匹配(`:498-501`)。空 key、重复 key 同样是硬错误(:561-570)。
7. 若 `params.ctx` 非空且 `no_alloc=false`,gguf 层会把整个 data 段读进一个 1D I8 张量 "GGUF tensor data binary blob",再让每个新 tensor 的 `data` 指进 blob(`:852,:892`)。llama 的模型加载走 `no_alloc=true`,把"指向数据"的动作推迟到 mmap 建立之后。
8. **写侧镜像对称**:`gguf_write_out` 依次写 header、逐条 KV、逐条张量元信息,再 pad 到对齐,最后逐张量写数据且每张量后再 pad(`:1622-1659`);`gguf_set_tensor_type` 改量化类型时会重算后续所有张量的 offset(:1418-1422)。`gguf_get_meta_size` 借助"只写元数据"的 dry-run 得到 header 大小,供转换器预留空间(:1696-1701)。

---

## ③ 模型加载流水线逐段(llama-model-loader)

入口 `llama_model_load`(`src/llama.cpp:316-378`)按固定次序装配:`llama_model_loader` 构造(解析全部元数据)→ `llama_model_create` → `load_hparams`(`src/llama.cpp:348`)→ `load_vocab`(:356)→ `load_stats`(:361)→ `load_tensors`(:369);任何一步抛异常都被翻译成带阶段的错误信息并整体放弃,不会留下半初始化模型。`load_hparams` 阶段即"按架构分派"的第一现场:每个架构在 `src/models/` 下的实现负责把自己的 KV 集合读进 `hparams`;`load_tensors` 阶段再按同一套 `LLM_TN` 命名表创建并灌入权重。

### 3.1 元数据读取与覆盖(kv_overrides)

`GGUFMeta::GKV<T>` 是带类型检查的取值模板(`src/llama-model-loader.cpp:159-271`):`get_kv` 先比对 GGUF 类型不符即抛异常(`:164-172`);`try_override` 支持 bool/int/float/str 四类用户覆盖(`:215-253`),验证失败打 WARN 后回退到文件值。所有超参读取都经 `get_key / get_arr / get_key_or_arr`(`:419-529`),后者允许「标量或长度恰好为 n 的数组」两种形态,兼容新版本模型把 per-layer 标量升级成数组的演进。

### 3.2 权重索引与 split 合并

构造函数为每个 GGUF 分片建立统一 `weights_map`(名字 → `llama_tensor_weight{文件 idx, 文件内偏移, 元 tensor}`),重名即抛错(`:585-594`);`split.no`/`split.count`/`split.tensors.count` 三条 KV 保证分片齐全且顺序正确(`:595-674`)。`llama_tensor_weight` 构造时立刻做**边界校验**:`offs + nbytes 不得越界文件`,防损坏文件(`src/llama-model-loader.h:47-49`)。权重表用 `weight_name_comparer` 按 `blk.%d.` 抽出的层号排序(`src/llama-model-loader.h:54-65`),使日志与加载顺序都按层递增。构造器同时统计各量化类型的张量数**猜测 ftype** 并打上 `LLAMA_FTYPE_GUESSED` 标记(`:718-783`),文件里有 `general.file_type` 时以文件为准——日志里的"mostly Q4_K"就是这么来的,它只是展示信息,不参与任何加载决策。

### 3.3 create_tensor:张量 → (buffer type, ggml context)

`create_tensor()`(`:1109-1383`)是"按架构分派 + 分设备放置"的核心:

1. 由 `LLM_TN` 张量名查到 `llm_tensor_info`(`src/llama-arch.cpp:1049-1051`),其中登记了每个张量的 **layer 类别(INPUT/OUTPUT/REPEATING)和主算子(op)**;
2. `op == GGML_OP_NONE` 的"无用张量"直接跳过不加载(`:1171-1179`);
3. `weight_buft_supported()`(`:920-1057`)为每个候选 buffer type 构造一个仅含元信息的哑算子图,调用 `ggml_backend_dev_supports_op` 试探,选中第一个能跑的设备(`select_weight_buft`,`:1060-1071`);
4. 用户可用正则 `tensor_buft_overrides` 强制某些层上/下 GPU(`:1228-1253`);mmap 开启时避免用 device 的 host buffer,改用 CPU 普通 buffer(`:1262-1270`);
5. `token_embd` 作为 output 复用时按 `TENSOR_DUPLICATED` 复制一份(`:1364-1382`)。

### 3.4 load_all_data:mmap 与异步上传双通道

- **mmap 路径**(`:1635-1664`):`ggml_backend_tensor_alloc(buf_mmap, cur, mapping->addr() + weight->offs)` 把权重直接"钉"在映射地址上,零拷贝;`check_tensors` 时用 `std::async` 并行校验每个张量的量化参数(`:1643-1647`,汇总 `:1756-1767`)。
- **非 mmap 路径**:若设备支持 async/host_buffer/events,建 4 个 1 MiB pinned staging buffer + event 做**双缓冲异步上传**,按读对齐切块(`:1513` 注释:64 MiB 适合 NVMe;`:1560-1729`);否则同步 `read_raw` + `tensor_set`。
- mmap 加载完成后,把**头部之前与尾部之后未用到的页段 unmap 掉**(`:1770-1781`),减少常驻虚拟内存。

### 3.5 懒加载(lazy read)

`lazy_read`(`src/llama-model-loader.h:88-118`,`src/llama-model-loader.cpp:1073-1107`)允许超大张量(默认阈值 4 GiB,`:1087`)不进 mmap 主映射,而是登记到 `ranges`,后续按行按需 `load_data_range`(`:1464-1484`)。主要服务于 PLE/engrams 这类 embedding 大表。

---

## ④ KV cache 统一抽象逐段解读

### 4.1 llama_memory_i:把"KV cache"泛化成"memory"

接口只有三个生命周期方法(`src/llama-memory.h:88-98`):`init_batch`(切 ubatch 并预占 slot)、`init_full`(满 cache 摆给 reserve 用)、`init_update`(处理挂起的 shift/跨流拷贝),外加 `seq_rm/seq_cp/seq_keep/seq_add/seq_div` 五个序列操作与 `state_write/read`(`:108-126`)。实现者:`llama_kv_cache`、`llama_kv_cache_iswa`、`llama_memory_hybrid(_iswa/_idx)`、`llama_memory_recurrent`、DSA/DSV4/MSA 专用 cache。配套的 `llama_memory_context_i` 只暴露 `next()/apply()/get_ubatch()`(`:51-67`)——**唯一允许改 memory 状态的入口是 `apply()`**,这把"找位"与"落子"分成了两个可回滚的阶段。

`init_batch` 内部先把用户 batch 切成若干 `n_ubatch` 大小的微批:单流走 `split_simple`(按 token 顺序切块,同一序列的 token 可跨 ubatch),多流走 `split_equal`(按序列等分,保证每个微批内各流 token 数相同)(`src/llama-kv-cache.cpp:708-725`)。切分失败(单条序列超过总量)或 prepare 失败,统一返回 `LLAMA_MEMORY_STATUS_FAILED_PREPARE`,由上层决定降级重试或报错。`init_full` 则虚构一个占满整个 cache 的假 slot_info,专供计算缓冲区的最坏情形预估(:739-741 与 :2670-2685 的 dummy slot_info)。

### 4.2 cell 状态机(llama_kv_cells)

每个 cell 是四元组(`src/llama-kv-cells.h:491-524`):

```
pos[i]   : llama_pos,-1 = 空          shift[i] : 自上次 reset_shift 累计的位移
seq[i]   : bitset<256>(LLAMA_MAX_SEQ)  ext[i]   : {x,y}(M-RoPE 2D 位), tok(n-gram 用)
used     : std::set<uint32_t> 非空 cell 索引(有序,支持 min/max)
seq_pos[s]: set<(pos, cell)> 按 pos 有序 → seq_pos_min/max O(1),upper_bound O(log n)
```

状态迁移:

```
            pos_set(idx, ubatch.pos[i])            ┌──────────────────────────┐
  空 ───────────────────────────────────────▶ 占用 │ seq[i] ⊇ {s1..sk}, pos≥0 │
  ▲                                            ────┴──────────────┬───────────┘
  │  seq_rm(i,s) 且 seq[i].none()                                 │ seq_add(i,s') 共享
  │  seq_keep 清空、pos_add 越界(<0)自毁 (:440-464)                 ▼
  └────────────────────────────────────────────────────── 多序列共享同一 cell
```

- `pos_add(i,d)` 同时把 `shift[i]+=d` 并置 `has_shift=true`(`:440-464`);pos 变负则整个 cell 自毁返回 true——这是 context shift 裁掉头部 cell 的机制。
- `seq_pos[s]` 是本快照新增的按位置有序索引(`:516-524`),让 `seq_pos_min/max`、以及 find_slot 的 SWA 判断都能对数完成;key 里带上 cell 索引是因为**同一 seq 的 pos 可能重复**(cache 复用的 rm+add 过渡态、视觉模型重复 pos)。
- `ext.tok` 供 n-gram embedding 哈希回溯前驱 token:`seq_pos_tok_le(seq,p)` 找 ≤p 的最近 cell(`:325-337`)。

### 4.3 多序列 → stream 的映射

`llama_kv_cache` 构造时 `n_stream(unified ? 1 : n_seq_max)`(`src/llama-kv-cache.cpp:84`):unified 模式全部序列共享 1 个 cell 环;非 unified 每序列一个独立环。`seq_to_stream[]` 把 seq_id 映射到 stream(`:148-155`),K/V 张量第三维即 n_stream(`:233-234`),每 stream 一个 2D view(`:242-245`)。`kv_unified` 由参数传入(`include/llama.h:406`),unified 时 `n_ctx_seq = n_ctx`,否则 `n_ctx/n_seq_max` 并 pad 到 256(`src/llama-context.cpp:290-304`)。

### 4.4 find_slot:驱逐与放置策略(画图)

`find_slot(ubatch, cont)`(`src/llama-kv-cache.cpp:898-1095`)。注意:**本快照没有 u_pos 时间戳**。旧版(2024 年)的"基于 cell 最近使用时间 u_pos 驱逐"已被三层策略替代:

1. **head 环形指针**:`v_heads[strm]` 记录每流下一次搜索起点(`:294-296` 注释);
2. **空闲 cell 优先**:一个 cell 可用当且仅当**为空**;
3. **SWA 过期覆盖**:cell 只被一个序列占用、且其 pos 已被该序列当前 SWA 窗口抛弃时,可直接抢占(`:1042-1061`):

```cpp
bool can_use = cells.is_empty(idx);
if (!can_use && cells.seq_count(idx) == 1) {
    const llama_pos pos_cell = cells.pos_get(idx);
    // SWA mask: 用该序列在 cache 中的最大 pos 判过期
    if (llama_hparams::is_masked_swa(n_swa, swa_type, pos_cell,
                                     cells.seq_pos_max(seq_id_cell) + 1)) {
        can_use = true;      // llama-kv-cache.cpp:1053-1060
    }
}
```

环形扫描示意(每流独立):

```
        head                                    head=回绕
   cells: [. . . A A A . B B B . .]   →   [. . . A A A . B B B . .]
            ▲ head 从这里开始             测试到末尾未凑满 → head=0 重扫 (:1021-1024)
   启发式: 若 head 前面的空闲足以装下本 ubatch(head > used + 2*n_tokens),
          直接把 head 拉回 0,优先把 cache 前段填满 (:1004-1007)
   cont=true(整段连续,供无 set_rows 后端):任一 cell 不可用即整段作废重找 (:1016-1018, 1066-1078)
   n_tested ≥ cells.size() → 返回空 slot_info,prepare 失败 (:1080-1083)
```

`prepare()`(`:751-815`)对整批 ubatch 做**试探性原子分配**:逐个 `find_slot` + `apply_ubatch`,同时把旧 cells 快照压栈(`:779-789`);任一 ubatch 放不下就整体回滚(`:797-808`)。这保证了多 ubatch 批次要么全部有位、要么不产生任何脏状态——旧版"先删后补"的两阶段提交被这个快照栈替代。

`apply_ubatch`(`:1097-1186`)落子时维护一条不变式:每个序列在 cache 中 `[pos_min, pos_max]` 区间必须连续存在,因此**覆写会抬高某序列 pos_max 时,把它更早的残余 cell 一并清除**(purge,`:1160-1178`,出处 PR #13746)。SWA cache 的"投机抢占"由此才不产生空洞。最后 `head = idxs.back() + 1`(`:1181-1185`)。

`get_n_kv`(`:1250-1264`)决定注意力实际看到的 K/V 长度:取本批各流 `used_max_p1` 的最大值,并向上 pad 到 `max(n_pad, 256)`,使计算图形状按 256 粒度增长——图复用(同一图反复提交)与部分后端的分块性能都依赖这一点(:1254 注释引 PR #16812)。空 cell 位于 `used_max_p1` 之后,天然被排除在注意力之外;`[0, used_max_p1)` 之间的空洞则由 KQ mask 负责置 -inf。

KQ mask 的 CPU 填充(`set_input_kq_mask_impl`,`:1554-1702`)有两个值得注意的工程细节:一是**同序列 mask 复用**——同一序列内多数 token 的 mask 行完全相同,只记录"位置接近批内最小 pos 的那些 cell"(阈值 `n_swa+32`)并在后续 token 上做增量修补(:1603-1628,PR #18842),不兼容 Alibi 时自动退回全量扫描;二是 SWA 与 non-causal 的组合逻辑——`llama_non_causal_type` 为 `SWA_ONLY` 时仅 SWA 层放开因果、dense 层保持因果(:1759-1761),`SWA_FULL`(deepseek 4)则在本 ubatch 内部不施 SWA(:1683-1689)。M-RoPE 的 2D 因果(先比 y 再比 x)也嵌在同一模板里(:1664-1679)。

### 4.5 写入路径:i_batch 与"回填"的现代形态

旧版的 `i_batch`(ubatch token → 全 batch logits 下标映射)在本快照中已不存在(`grep i_batch` 在 `src/llama-batch.*`、`src/llama-context.cpp` 零命中),输出位置改由 `n_outputs/outputs` 数组在 `llama_batch_allocr` 内消化。KV 的回填也不再是 `ggml_cpy` 整块拷贝,而是 **scatter**:

- `build_input_k_idxs/v_idxs` 生成 I64 索引张量(`:1409-1433`),CPU 端 `set_input_k_idxs/v_idxs` 按 `sinfo.idxs` 填 `全局 cell 下标 = strm*kv_size + idx`(`:1476-1523`);
- `cpy_k/cpy_v` 用 `ggml_set_rows(cache, cur, idxs)` 把本 ubatch 的 K/V 精确散写进任意分散的 cell(`:1350,:1385`)。**因为写地址可以乱序,cell 不再需要连续段,这正是 defrag 得以删除、find_slot 可以走碎片化路径的物理前提。**
- 唯一例外:非 FA 的转置 V(v_trans)路径,索引要展开成 `n_tokens × n_embd_v_gqa` 的逐元素坐标(`:1508-1522`),把每行的每列当独立"行"散写(`:1401-1406`)。

---

## ⑤ defrag 与序列操作语义

### 5.1 defrag:已删除

经典实现里 KV cache 有 `defrag_fragment()`:当碎片率超过 `n_batch/thold` 时把 cell 数据向头部搬移。本快照中:

- `include/llama.h:384`:`float defrag_thold; // [DEPRECATED]`,且默认值 `-1.0f`(禁用,`src/llama-context.cpp:3639`);
- `src/llama-kv-cells.h:105-123`:cell 搬移函数 `mv()` 整段被注释掉,注释仍写 "used during defrag"——遗迹;
- 全仓 `grep defrag` 除上述两处与一个模型注释外无任何实现。

结论:**defrag 机制已从代码中整体移除**(API 字段仅保留兼容)。碎片问题从两端消解:① `ggml_set_rows` 让写入可以是任意分散 cell;② 非 cont 模式下 find_slot 逐 cell 挑位,不再要求连续段。只有当后端不支持 set_rows 时才退化请求连续段(`cont=true` 分支)。

### 5.2 序列操作语义(src/llama-kv-cache.cpp)

| 操作 | 行为 | 关键行号 |
|---|---|---|
| `seq_rm(seq, p0, p1)` | seq_id≥0:逐 cell 摘除该 seq,cell 变空则回收;seq_id=-1:所有流直接 `rm`。** freeing 后把 head 回退到最早空位** | :382-449(head 回退 :417-420, :441-444) |
| `seq_cp(src, dst, p0, p1)` | 同流(s0==s1):零拷贝,只 `cells.seq_add(i, dst)` 共享 K/V;跨流:断言整 buffer 全量拷贝,`sc_info` 入队到下一次 update 才真正 `ggml_backend_tensor_copy` | :451-541(同流 :463-491;断言 :506;入队 :508-511;执行 :827-855) |
| `seq_keep(seq)` | 其余序列全部摘除,head 回退 | :543-568 |
| `seq_add(seq, p0, p1, shift)` | pos 整体平移(K-shift 的元数据半边),越界 cell 自毁;head 复位到空位或 0 | :570-618(:617) |
| `seq_div(seq, p0, p1, d)` | pos 除 d(配额减半场景),shift 记录差值 | :620-657 |

细节:

- **跨流 seq_cp 的 pos 修正**(:516-530):拷贝时先把源 cell 的 `pos - shift` 还原成"真实 pos"再写入目标流、再 `pos_add(shift)` 重新加上——避免把未应用的 K-shift 物理拷贝过去却带着旧坐标。
- **共享 cells 的镜像 cache**(`mem_other`,`:86-98`,`TAG_KV_CACHE_SHARE_CELLS`):qwen4exp 之类的 indexer cache 直接复用主 cache 的 `v_cells_impl`,所以它所有 seq_* 操作都是 no-op 直接 return(`:384-386` 等),状态读写走 `state_read_sinfo` 的 `sinfos_in` 镜像布局(`:2393-2417`)。
- **K-shift 计算图**:元数据平移只改 `pos/shift[]`;真正的 RoPE 重旋在 `update()` 里构建 `build_graph_shift`(`:857-893`,`:2001-2051`):只取每层 K 的前 `n_rot` 列做 view(`:2036-2041`),量化 K 则 cast 到 f32 → Hadamard 旋出 → rope → Hadamard 旋回 → 量化写回(`:1949-1963`)。

### 5.3 上下文移位(context shift)还在吗?

**在,但只剩底层机制,策略上移到了 server**。KV cache 侧的完整链路:`llama_memory_seq_add`(公开 API,`include/llama.h:772`)→ `cells.pos_add` 置 `has_shift` → 下次 decode 前 `init_update` 返回带 `do_shift` 的 context(`src/llama-kv-cache.cpp:743-749`)→ `update()` 建图重旋 K(`:857-893`)。server 侧在 `pre_decode()` 里判断"生成中且 prompt 将满"时主动调用,多模态槽位与 `ctx_shift=false` 时禁用(`tools/server/server-context.cpp:2911-2930`)。主库 `llama_context` 不再自动触发 shift。

---

## ⑥ SWA / FA / 量化 KV 的落点

### 6.1 iSWA:基座 + SWA 双 cache 交替

`llama_kv_cache_iswa`(`src/llama-kv-cache-iswa.cpp:34-106`)按 `hparams.is_swa(il)` 把层**一分为二**,各建一个 `llama_kv_cache`:

- base cache:过滤 `!is_swa(il)`,`n_swa=0`、`LLAMA_SWA_TYPE_NONE`(:53-59, :95-98);
- SWA cache:过滤 `is_swa(il)`,带 `hparams.n_swa/swa_type`(:61-67, :102-105);
- **SWA cache 尺寸** `size_swa = PAD(min(size_base, n_swa*(unified ? n_seq_max : 1) + n_ubatch), 256)`(:73)——只需覆盖一个窗口加上一个 ubatch 的余量;`--swa-full` 时强制等于 base(:76-81);
- 所有 seq_* 操作都双发到两个 cache(:108-140);`seq_pos_min/max` 只看 SWA cache(base 是其超集,:142-149);
- `init_batch` 依次尝试 `split_simple`(仅 unified)与 `split_equal`(非 unified 必须等分,因为两 cache 的 slot 要逐 token 对齐),分别 prepare 两套 `sinfos`(:159-243);
- `get_can_shift()` 额外要求两 cache 尺寸相等(:253-257);state 保存用 `LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY` 区分是否跳过 base(:259-273)。

层交替模式由 `set_swa_pattern` 描述(`src/llama-hparams.cpp:8-22`):`n_pattern=3, dense_first=false` ⇒ 层 0,1 SWA、层 2 dense、循环(gemma 系);`is_masked_swa` 是唯一的窗口谓词,三种窗口几何都在这一个函数里(`src/llama-hparams.h:466-500`):STANDARD 滑窗 / CHUNKED 块状(窗口起点按 `p1/n_swa` 对齐)/ SYMMETRIC 双向窗口。find_slot 抢占、KQ mask、state 保存过滤共用它。

### 6.2 Flash Attention 与"V 不转置缓存"

`v_trans` 的唯一来源是 `!cparams.flash_attn`(`src/llama-model.cpp:2569,2589,2609` 等注释 `/* attn_v_trans */ !cparams.flash_attn`),cache 构造时决定 V 张量的内存布局:

- **FA 开启(v_trans=false)**:V 按 `[n_embd_v_gqa, kv_size, n_stream]` 行主存,`get_v` 直接给 4D view(`src/llama-kv-cache.cpp:1299-1306`),`cpy_v` 走 `ggml_set_rows` 一条路(:1372-1385);图构建时 `ggml_flash_attn_ext` 无需任何转置(`src/llama-graph.cpp:2615-2632`,仅当 v_trans 时补 transpose :2619-2621)。
- **FA 关闭**:V 存**转置布局**(`v->nb[1] > v->nb[2]`,`build_attn_mha` 用这个判据反向探测,:2602),非 FA 分支 `mul_mat(v, softmax)` 恰好按行乘(:2704);若此时误入 FA 分支要先 `ggml_transpose`。非 FA + 非 v_trans 的组合则要 `ggml_cont(transpose(v))` 补拷贝(:2698-2702,注释 "avoid this branch")。
- **量化 V 必须开 FA**:两个硬闸,构造期检查(`src/llama-context.cpp:3702-3711`)与 reserve 期检查(:463-467)——转置布局 + 量化无法高效就地写。AUTO 模式会自动把 FA 打开(:3703-3705)。量化 K 还要求 `n_embd_head_k % blck_size == 0`(:3713-3722)。MLA 模型强制 type_k == type_v(:3697-3699)。
- KQ mask 类型随 FA 切换 F16/F32(`src/llama-graph.cpp:977`)。

### 6.3 量化 KV 的精度补丁:Hadamard 旋转

量化 K/V 的离群值(outlier)问题在本快照用**缓存侧 Hadamard 正交旋转**缓解:构造期判定 `attn_rot_k/v = 量化类型 && head_dim % 64 == 0`(`src/llama-kv-cache.cpp:321-338`),预生成 64…n 的 Walsh-Hadamard 矩阵(`ggml_gen_hadamard`,`:23-59`,性质 `R² == I`)。写入前在图里对 K_cur 旋进(`llama_mul_mat_hadamard`),读取/K-shift 时旋回;RoPE 只作用于未旋转坐标,shift 重旋时按"旋出→rope→旋进"完成(`:1949-1963`)。V 用最小 64×64 旋转块即可受益(PR #21038,:1456-1471)。旋转矩阵常驻主机内存、经 `set_input_k_rot/v_rot` 每次提交图时拷进输入张量(:1813-1829),K 侧取能整除 head_dim 的最大旋转块、V 侧固定 64,是不对称的启发式(:1438-1454)。DeepSeek lightning indexer 一类架构会无条件强制开启 K 旋转(:327-332)。这一机制与状态保存/恢复天然兼容:磁盘上的 K 已经是旋转后的量化值,restore 不需要任何额外处理。

---

## ⑦ 设计动机与取舍

1. **GGUF 无索引表、顺序布局**:代价是 `gguf_find_key/find_tensor` 都是 O(n) 线性扫(`gguf.cpp:1034-1048,1173-1187`);收益是格式极简、写流式、header 可整体 mmap。对一次加载长期推理的场景,线性扫几万条 KV 的开销可忽略。
2. **加载器把"决策"与"搬运"分离**:`create_tensor` 只建元 tensor 并选 buft(逐算子试探后端能力),`load_all_data` 才碰数据。这让 no_alloc / lazy / mmap / 异步上传成为同一管线的开关组合,而非平行实现。
3. **cells 的 set-of-seqs 位图 + 有序 pos 索引**:一个 cell 可被多序列共享(seq_cp 零拷贝),`seq_pos[s]` 用 `set<(pos,cell)>` 把 min/max/区间查全对数化——是 purge 不变式与 SWA 抢占能够 O(log n) 判定的基础;代价是每次 pos/seq 变更都要同步维护多个索引(`seq_pos_rm/add`,`llama-kv-cells.h:539-554`)。
4. **prepare 的快照回滚 vs 旧的两阶段删除**:旧版先驱逐再写入,失败后 cache 留洞;现在试摆失败整体恢复(`src/llama-kv-cache.cpp:797-808`),代价是 `cells.cp()` 拷贝,收益是批内原子性与 server 层无需重试逻辑。
5. **删除 defrag 换来 set_rows 的自由度**:把碎片整理的复杂度从"运行时搬数据"转移到"后端实现 scatter 写",同时消灭了 defrag 与并发 decode 的竞态面。`defrag_thold` 字段保留只是 ABI 兼容。
6. **v_trans 与 FA 绑定**:转置 V 是为 `mul_mat(V^T, softmax)` 的访存局部性服务的前 FA 时代优化;FA 自带在线 softmax 后转置不再必要,于是布局直接二值化成 `v_trans = !FA`,并顺势禁止"量化 V + 非 FA"这一无法高效落地的组合。
7. **stream 抽象**:unified=1 流时多序列共享一个环(配合 seq 位图共享 cell),非 unified 时每序列独占环避免互相驱逐;跨流 seq_cp 被推迟到 update 统一执行,保证拷贝发生在无并发写窗口。
8. **元数据即 schema**:`LLM_KV::operator()` 把枚举格式化成 `<arch>.<字段名>` 字符串(`src/llama-arch.cpp:992-1003`),`LLM_TN_IMPL::str()` 同理拼张量名(:1005-1020)。新增架构不需要改加载器主体,只需在 `LLM_ARCH_NAMES / LLM_KV_NAMES / LLM_TENSOR_NAMES / LLM_TENSOR_INFOS` 四张表里登记;张量登记表还绑定「所属层类别 + 主算子」两个属性,后者被加载器反过用来探测后端能力——用一张数据表同时承担命名、分派与设备放置三种职责。
9. **KV 元数据每 cell 约 40 字节的取舍**:`pos(4)+shift(4)+seq(32B bitset)+ext(12)` 的每 cell 元数据在 64K 上下文下约 3 MB/C流,相对 K/V 数据可忽略,却换来了 O(log n) 的 pos 索引与 O(1) 的共享计数;`ext` 只在 M-RoPE/PLE 模型参与序列化(`has_cell_ext()`,`:1831-1834`),常规模型状态保存不为其付费。

---

## ⑧ FAQ

**Q1:GGUF 的 header 顺序到底是怎样?**
`magic → version(u32) → n_tensors(i64) → n_kv(i64) → n_kv 条 KV → n_tensors 条张量信息 → pad → data`。读:`ggml/src/gguf.cpp:457-536`;写:`:1627-1659`。

**Q2:张量数据在文件里必须连续吗?**
必须。读入时校验每个 `info[i].offset == 前面所有 PAD(nbytes, alignment) 的累加`(`gguf.cpp:777-786`),不满足直接判损坏。

**Q3:为什么找不到 defrag?它去哪了?**
本快照已删除。写入用 `ggml_set_rows` 散写(`src/llama-kv-cache.cpp:1350,1385`),cell 无需连续,碎片整理失去意义;`defrag_thold` 只是 deprecated API 字段(`include/llama.h:384`)。

**Q4:find_slot 何时会驱逐别人的 cell?**
仅当该 cell 只有一个序列、且其 pos 已被该序列 SWA 窗口排除(`src/llama-kv-cache.cpp:1053-1060`)。普通 dense cache 里非空 cell 绝不抢占,找不到空位就返回失败。旧资料里的 u_pos 时间戳驱逐在本快照不存在。

**Q5:一个 cell 能同时属于多个序列吗?K/V 会不会写两份?**
能,且只有一份。`seq[i]` 是 256 位位图;`seq_cp` 同流只改位图(`:463-491`)。KQ mask 按 `cells.seq_has(j, seq_id)` 过滤(`:1649-1651`)。

**Q6:量化 V cache 为什么必须开 Flash Attention?**
非 FA 时 V 以转置布局存储服务于 `mul_mat`,量化转置布局既无法 `set_rows` 高效散写也无法整块 cpy;两处硬检查见 `src/llama-context.cpp:463-467` 与 `:3702-3711`,AUTO 模式自动改开 FA。

**Q7:量化 KV 的精度损失有缓解手段吗?**
有:量化 K/V 默认启用 Hadamard 正交旋转(`attn_rot_k/v`,`src/llama-kv-cache.cpp:321-338`),写入/读取前旋进旋出,把离群值摊平到各分量;K-shift 重旋也按"旋出→RoPE→旋进"处理(:1949-1963)。可用 `LLAMA_ATTN_ROT_DISABLE` 关闭。

**Q8:context shift 还存在吗?**
机制完整保留(seq_add → has_shift → build_graph_shift 重旋 K,`src/llama-kv-cache.cpp:570-618, 857-893`),但主库不再自动触发;由 server 在槽位将满时显式调用(`tools/server/server-context.cpp:2911-2930`),多模态禁用。

**Q9:iSWA 模型 SWA cache 有多小?**
`PAD(min(n_ctx_seq, n_swa*(unified? n_seq_max:1) + n_ubatch), 256)`(`src/llama-kv-cache-iswa.cpp:73`),即一个窗口加一个 ubatch;`--swa-full` 可强制全尺寸换取无驱逐。

**Q10:LoRA 加载时如何校验?**
`general.type == "adapter"`、`general.architecture` 与基座一致、`adapter.type == "lora"` 三道元数据门(`src/llama-adapter.cpp:202-216`);每个 `*.lora_a/b` 必须在基座中存在同名张量且形状匹配(:330-368);落在带 repack 的 extra buffer type 上时回退 CPU(:337-350)。推理时 `build_lora_mm` 把 `scale·B·A·x` 加到 `W·x` 上(`src/llama-graph.cpp:1514-1543`)。

**Q11:adapter 文件本身是什么格式?**
也是 GGUF,但元数据走 `adapter.*` 前缀;张量必须以 `.lora_a`/`.lora_b` 结尾成对出现,`_norm.weight` 被显式忽略(:287-290)。MoE 的 `build_lora_mm_id` 走 `mul_mat_id` 版本,scale 用 `alpha/rank` 计算(`src/llama-graph.cpp:1560-1578`);aLoRA(按触发 token 激活)的调用序列存在 `adapter.alora_invocation_tokens`(`src/llama-adapter.cpp:221-238`)。

**Q12:`kv_unified` 该开还是该关?**
unified(单流)让所有序列共享一个 cell 环,配合 seq 位图实现零拷贝 fork(seq_cp),内存利用率高;非 unified 每序列独占 `n_ctx/n_seq_max` 的环,互不驱逐,且要求 `split_equal` 等分 ubatch(`src/llama-kv-cache-iswa.cpp:204-237`)。并行多会话且各序列长度差异大时 unified 更省;需要严格隔离(如 server 多槽位)时非 unified 更可预期。

---

## ⑨ 深挖问题(供后续章节/实验)

1. **prepare() 快照回滚的成本边界**:`cells.cp(idxs)` 按 slot 逐 cell 拷贝(`src/llama-kv-cache.cpp:782-788`),大 batch × 长 prompt 时回滚栈内存与时间随 `n_ubatch × n_tokens` 线性增长;是否值得为失败路径预付这份拷贝,可以用失败注入实验量化。
2. **`get_n_kv` 的 256 对齐启发式**:`n_pad_cur = max(n_pad, 256)` 使图形状按 256 粒度增长以复用计算图(`:1255-1260`);它与 SWA cache 尺寸 pad 256、`n_ctx` pad 256(`src/llama-context.cpp:288`)形成一组同源常数,值得追查对极端小窗口(如 n_swa=128)模型是否造成浪费。
3. **跨流 seq_cp 的全量断言**:`GGML_ASSERT(is_full)` 限制跨流复制只能整 buffer(`:506`),p0/p1 部分复制在非 unified 模式下是否可行、`sc_info` 推迟执行与 decode 失败路径(FAILED_COMPUTE)之间的一致性如何保证,代码中未见回滚。
4. **Hadamard 旋转对已有量化模型精度的实际影响**:`attn_rot` 对 Q4_0/Q8_0/Q5_1 等 block 布局统一旋 64 倍数维度,旋转是在量化域外(f32 域)进行再写回量化,理论上会重新量化;不同 K 量化类型的 PPL 回归值得实测,并核对 `LLAMA_ATTN_ROT_DISABLE` 作为 A/B 开关。
5. **镜像 cache(`other`)的状态一致性**:qwen4exp indexer 等共享 `v_cells_impl` 的 cache,`state_read_sinfo` 用 `sinfos_in` 强制同布局(`:2393-2417`),注释直言"两个 cache 各自 find_slot 只能靠运气一致"(`src/llama-kv-cache.h:172`);主从两 cache 的 save/restore 顺序约定仅由调用方保证,值得审查 `llama-context` 状态接口是否强制了顺序。

---

### 附:本报告覆盖的文件

| 文件 | 行数 | 内容 |
|---|---|---|
| `ggml/src/gguf.cpp` | 1707 | GGUF 读写全量解析 |
| `ggml/include/gguf.h` | 常量 | magic/version/alignment |
| `src/llama-model-loader.cpp/.h` | 1804+265 | 加载流水线、buft 选择、mmap/异步 |
| `src/llama.cpp` | (316-495) | 模型装载入口 |
| `src/llama-arch.cpp/.h` | 1158+790 | LLM_ARCH/LLM_KV/张量名与算子表 |
| `src/llama-hparams.cpp/.h` | 353+506 | 超参、SWA 模式与窗口谓词 |
| `src/llama-kv-cache.cpp/.h` | 2815+464 | KV cache 主体 |
| `src/llama-kv-cells.h` | 557 | cell 状态机 |
| `src/llama-kv-cache-iswa.cpp` | 364 | iSWA 双 cache |
| `src/llama-memory.h` | 130 | 统一内存接口 |
| `src/llama-graph.cpp` | (片段) | build_attn_mha / build_lora_mm |
| `src/llama-model.cpp` | (片段) | create_memory 分派、v_trans |
| `src/llama-context.cpp` | (片段) | FA/量化检查、kv_unified |
| `src/llama-adapter.cpp/.h` | 500+91 | cvec 与 LoRA |
| `tools/server/server-context.cpp` | (片段) | context shift 策略 |
