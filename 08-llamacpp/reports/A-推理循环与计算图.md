# A 篇 · 推理主循环与计算图构建（llama.cpp 第八卷原始材料）

> 调研基线：master tarball（2026-09 世代，版本号已从代码移除）。所有结论均以实际源码为准，标注格式为 `文件:行号`。行号基于当前解压快照。

---

## ① 全景：一次推理到底发生了什么

llama.cpp 的推理是一条环：**tokenize → 组 batch → 切 ubatch → 分配 KV 槽位 → 构图（或复用图）→ sched 切图到多后端 → 异步执行 → 抽取 logits/embedding → 采样 → 把新 token 拼回 batch**，再进入下一轮。

各环节的落点：

1. **tokenize**：由 `llama_vocab` 的各实现类完成（BPE/SentencePiece/LLaMA 等各自实现 `tokenize` 虚函数，src/llama-vocab.cpp:118、613、781、977、1325）。词表在模型加载时由 `load_vocab` 挂到模型上（src/llama.cpp:356 → src/llama-model.cpp:1397-1401）。
2. **模型加载编排**：`llama_model_load` 串起整条装载线——构造 `llama_model_loader` → `llama_model_create` → `load_hparams`（GGUF 元数据 → hparams）→ `load_vocab` → `load_stats` → `load_tensors`（src/llama.cpp:316-378）。设备选择在 `llama_prepare_model_devices` 中完成：默认枚举所有 GPU/RPC/iGPU，`SPLIT_MODE_TENSOR` 时把多卡包成一个 "Meta device" 做张量并行（src/llama.cpp:158-313）。
3. **hparams 解析**：`load_hparams` 从 GGUF KV 逐项读入 `n_ctx_train / n_embd / n_layer / n_head / n_head_kv / n_ff / rope 系列`，标量或按层数组均可（`get_key_or_arr`，src/llama-model.cpp:1225-1307），最后调 per-arch 的 `load_arch_hparams`（src/llama-model.cpp:1382）并推导 `rope_type`（src/llama-model.cpp:1394）。
4. **load_tensors**：先给每层分配设备（按显存比例切分，输入层恒留 CPU，src/llama-model.cpp:1492-1508），再按 arch 的 `load_arch_tensors` 声明全部权重（如 llama：src/models/llama.cpp:34-92），为每个 ggml_context 创建后端 buffer（支持 mmap 直接托管，src/llama-model.cpp:1747-1767），最后 `ml.load_all_data` 灌数据（src/llama-model.cpp:1841-1845）。
5. **上下文构造**：`llama_context` 构造函数填充 cparams（n_batch/n_ubatch/n_ctx_seq 等，src/llama-context.cpp:99-304）、初始化后端列表（GPU→ACCEL→CPU 顺序，src/llama-context.cpp:330-357）、预分配输出 buffer（src/llama-context.cpp:373-382）、创建 memory 模块（KV cache 等，src/llama-context.cpp:385-396），最后 `sched_reserve()` 用最坏情况图预分配计算 buffer（src/llama-context.cpp:461、582-712）。
6. **每轮 decode**：`llama_context::decode`（src/llama-context.cpp:1644-2037）是主循环核心，内部调用 `process_ubatch`（src/llama-context.cpp:1334-1404）完成"构图→分配→set_inputs→计算"。
7. **采样**：默认在宿主侧由 llama-sampler 链完成；若配置了 backend sampler，采样算子会被直接编进计算图（`build_sampling`，src/llama-graph.cpp:3764 起；图构建总入口在 `llama_model::build_graph`，src/llama-model.cpp:2733-2751）。

用一句话概括分层：**llama_model 是静态的权重+hparams；llama_context 是动态的执行状态（KV、计算 buffer、调度器）；llama_graph_context 是"模型结构 → ggml 节点"的翻译器；ggml_backend_sched 是"节点 → 物理设备"的放置器。**

---

## ② ubatch 切分逻辑逐段（llama-batch.cpp）

### 2.1 llama_batch 与 llama_ubatch

用户侧的 `llama_batch` 是一排平行数组（token/pos/seq_id/logits），`llama_batch_init` 直接 malloc 对应容量（src/llama-batch.cpp:945-973）。`llama_ubatch` 则是切分后送进计算图的"微批"，核心字段（src/llama-batch.h:15-69）：

```cpp
uint32_t n_tokens;     // 总 token 数 = n_seq_tokens * n_seqs
uint32_t n_seq_tokens; // 每个序列集的 token 数
uint32_t n_seqs;       // 序列集数
uint32_t n_seqs_unq;   // 去重后的序列 id 数
llama_token * token;  float * embd;  llama_pos * pos;
llama_seq_id ** seq_id;  int8_t * output; // 即 logits 标志
```

`b_equal_seqs` 标志本 ubatch 内各序列集是否等长——等长时注意力可以按 stream 切成 4D 张量并行处理（src/llama-graph.cpp:36、2605-2607）。注意 `token` 与 `embd` 互斥：文本走 token 查嵌入表，多模态/MT 直接喂向量。

### 2.2 init：清洗 + 补全 + 一致性校验

`llama_batch_allocr::init`（src/llama-batch.cpp:25-391）做四件事：

- **校验**：token 越界、seq_id 越界直接失败（src/llama-batch.cpp:49-67）。
- **补全缺省字段**：没给 `seq_id` 就全填 0；没给 `pos` 就按 memory（KV cache）中各序列的最大位置 +1 连续递推（src/llama-batch.cpp:90-118）；没给 `logits` 时——输出模型只标最后一个 token，embedding 模型标全部（src/llama-batch.cpp:120-130）：

```cpp
if (!batch.logits) {
    if (output_all) {
        output.resize(batch.n_tokens, true);
    } else {
        output.resize(batch.n_tokens, false);
        output[output.size() - 1] = true;   // 只对最后一个 token 出 logits
    }
    batch.logits = output.data();
}
```

这就是 **decode 与 prefill 共用一套代码但行为不同的关键机关**：prefill 一大串 token 只有最后一个带 `logits=1`，图里 `build_inp_out_ids` 只收拢这些行，输出矩阵从 `n_tokens×n_vocab` 缩成 `n_outputs×n_vocab`。
- **耦合序列检测**：一个 token 同时属于多个序列（并行采样 fork 出来的），记入 `seq_cpl`（src/llama-batch.cpp:162-182）；耦合序列的 KV 范围必须一致，否则报错（src/llama-batch.cpp:323-335）。
- **位置连续性**：单 RoPE 要求每序列位置严格 `Y = X+1` 连续；M-RoPE（n_pos_per_embd>1，如 Qwen-VL 的 4 维位置）放宽为只许前跳（src/llama-batch.cpp:255-321）。还禁止"部分序列子集"和"序列位置回退"两种排布（注释给了反例图，src/llama-batch.cpp:337-386）。

### 2.3 三种切分策略

`llama_kv_cache::init_batch` 按流数选择（src/llama-kv-cache.cpp:708-720）：

```cpp
while (true) {
    auto ubatch = n_stream == 1 ? balloc.split_simple(n_ubatch)
                                : balloc.split_equal(n_ubatch, true, 0);
    if (ubatch.n_tokens == 0) break;
    ubatches.push_back(std::move(ubatch));
}
```

- **split_simple**（src/llama-batch.cpp:476-508）：顺序取前 `n_ubatch` 个未用 token。序列集长度可以不等，`b_equal_seqs=false`。单序列（或统一 KV）prefill 走这条，最简单、无空洞。
- **split_equal**（src/llama-batch.cpp:510-679）：多序列并行时的"方阵切法"。先把 token 按 `seq_set`（bitset<LLAMA_MAX_SEQ>）分组，一个 ubatch 只收**互不相交**的序列集（src/llama-batch.cpp:522-551），然后各序列集轮流各取一个 token，直到 `(每序列 token 数+1)*n_seqs > n_ubatch`（src/llama-batch.cpp:589-603）。这样 `n_tokens = n_seq_tokens × n_seqs` 是规整方阵，图里能变成 `[n_kv, n_seq_tokens, 1, n_streams]` 的 4D mask/k/v（src/llama-graph.cpp:41）。`sequential=true` 时还要求序列 id 递增出现。`n_keep_tail` 参数保证递归模型（Mamba 类）每序列尾部若干 token 不被跨 ubatch 腰斩（src/llama-batch.cpp:605-669）。
- **split_seq**（src/llama-batch.cpp:681-721）：整个 ubatch 只装**一个**序列集，适合 recurrent/hybrid memory——状态按序列串行推进，不能把两个序列混在一个微批里。

每个 ubatch 由 `ubatch_add` 物化（src/llama-batch.cpp:749-844）：数据深拷进 `shared_ptr<data_t>`（ubatch 可能活得比 decode 的栈帧久，图复用时要查它的 seq_id）；M-RoPE 文本 token 的 1D 位置广播到 4 个 RoPE 段，图像 embd 则按段原样拷贝（src/llama-batch.cpp:781-788）；输出 token 的原始 batch 下标记入 `out_ids`（src/llama-batch.cpp:800-802）——这是后面"输出重排"的依据。

### 2.4 切分的"失败"语义

三种切分都依赖 `used[]` 位图记录哪些 token 已进 ubatch（`split_reset` 清零，src/llama-batch.cpp:467-474）。一个微妙之处：切分可能"用不满"——例如 split_equal 的序列集互斥约束导致某些 token 始终无法入组。调用方（KV cache 的 `init_batch`）用 `balloc.get_n_used() < balloc.get_n_tokens()` 判定失败并返回 `FAILED_PREPARE`（src/llama-kv-cache.cpp:722-725），上层 decode 才有机会走 defrag 重试。`out_ids`（输出 token 的原始下标，按 ubatch 处理顺序追加）在每次 `ubatch_add` 时填充、`split_reset` 时清空（src/llama-batch.cpp:467-474、800-802），因此 decode 结束后它恰好就是"输出行号 → batch 下标"的对照表。

### 2.5 KV 槽位与重试

切好的 ubatch 交给 `memory->init_batch`（src/llama-context.cpp:1750），KV cache 为它们 `prepare` 槽位；若 `FAILED_PREPARE`（比如碎片化找不到连续槽），decode 会做一次 `memory_update(true)`（cache 重排/defrag）后重试一次，仍失败返回 1（src/llama-context.cpp:1765-1780）。若某个 ubatch 计算失败，还会把该 ubatch 各序列从失败位置起 `seq_rm` 回滚掉，保证 KV 与实际计算一致（src/llama-context.cpp:1829-1850）。

---

## ③ 计算图构建逐段（llama-graph.cpp）

### 3.1 构图的容器与时机

每个 `llama_context` 持有两个 `llm_graph_result`（`gf_res_prev` 用于真实计算、`gf_res_reserve` 用于预算 buffer，src/llama-context.cpp:602-603）。`reset()` 里按 `max_nodes` 预留纯元数据 buffer，再 `ggml_new_graph_custom` 造出空图（src/llama-graph.cpp:1343-1353）——**张量的 shape/名字等元数据在 CPU 侧小 buffer，数据 buffer 由 ggml-alloc/sched 统一分配**。`max_nodes` 的估算按 arch 区分，普通模型 `max(1024, 8×n_tensors)` 加上 LoRA 与采样节点（src/llama-context.cpp:2305-2353）。

`process_ubatch`（src/llama-context.cpp:1334-1404）是每微批的必经之路，最大的亮点是**图复用**：

```cpp
const auto gparams = graph_params(res, ubatch, mctx, gtype);
if (!graph_reuse_disable && res->can_reuse(gparams)) {
    // 拓扑相同 → 跳过构图与 sched 重新切图
    if (cparams.pipeline_parallel) ggml_backend_sched_synchronize(sched.get());
    n_reused++;
} else {
    res->reset();
    ggml_backend_sched_reset(sched.get());
    gf = model.build_graph(gparams);
    if (!ggml_backend_sched_alloc_graph(sched.get(), gf)) { ... }
}
res->set_inputs(&ubatch);          // 只写输入张量的数据
const auto status = graph_compute(res->get_gf(), ubatch.n_tokens > 1);
```

`can_reuse` 要求 ubatch 形状全等、n_outputs 相等、sampler 集相同；equal_seqs 时还逐个比对参与序列（src/llama-graph.h:815-867）。decode 阶段逐 token 步进时形状完全不变，因此**稳态生成每步都零构图开销**。

### 3.2 输入端三件套

- **build_inp_embd**（src/llama-graph.cpp:2358-2445）：同时建两个输入分支——token 分支 `ggml_get_rows(tok_embd, inp_tokens)`（带 LoRA 增量），embd 分支直接用输入张量；用 `ggml_build_forward_select(gf, inps, 2, ubatch.token ? 0 : 1)` 按本批内容选一支（src/llama-graph.cpp:2418）。两个分支都进图但只计算被选中的，拓扑因而与批内容无关，保住了图复用与流水线并行的前提（同款注释见 src/llama-graph.cpp:2475-2483 对 out_ids 的取舍）。
- **build_inp_pos**（src/llama-graph.cpp:2447-2458）：1D I32 位置张量，M-RoPE 时是 `n_tokens×4`，`set_input` 时文本把 1D 广播成 4D、第 4 维置 0（src/llama-graph.cpp:127-147）。
- **build_inp_out_ids**（src/llama-graph.cpp:2475-2494）：I32 `n_outputs` 向量。最后一层结束后 `ggml_get_rows(cur, inp_out_ids)` 只抽输出行（src/models/llama.cpp:174-177），head 矩阵乘从 `n_tokens` 行降到 `n_outputs` 行——prefill 的最大省算力点。

### 3.3 单层 Transformer 的 ggml 节点图

以标准 llama 层为例（src/models/llama.cpp:126-228），一层的数据流如下（`(...)` 内是 ggml 算子名）：

```text
inp_tokens(I32)   tok_embd(W)
     └────────┴─► get_rows ─► [embd]  （pos → inp_pos(I32)）
                                   │
  ┌────────────────────────────────┘
  ├─ rms_norm ─► mul(attn_norm)                     # pre-attention RMSNorm
  ├─ mul_mat(wq)/mul_mat(wk)/mul_mat(wv) [+LoRA]    # build_qkv
  │     └─ reshape_3d → (head,bs)                   # Qcur/Kcur/Vcur
  ├─ rope_ext(Qcur, inp_pos)  rope_ext(Kcur, ...)   # 仅 Q/K
  ├─ [KV 层] cpy_k→cache  cpy_v→cache               # 写缓存（build_attn, graph.cpp:2877-2878）
  ├─ get_k(cache,il) get_v(cache,il)                # 读回含历史的全量 K/V
  ├─ mul_mat(k,q) ─► soft_max_ext(mask, scale) ─► mul_mat(v, ·)
  │     （或 flash_attn_ext(q,k,v,mask)）            # build_attn_mha
  ├─ mul_mat(wo)                                    # 注意力输出投影
  └─ add(·, inpSA) ─► rms_norm ─► mul_mat(ffn_gate/up) 
        ─► silu ─► mul  （SwiGLU，LLM_FFN_PAR）     # build_ffn
        ─► mul_mat(ffn_down) ─► add(·, ffn_inp)     # 残差
  = 下一层输入 inpL
最后一层后：rms_norm(output_norm) ─► get_rows(out_ids) ─► mul_mat(output) → logits
```

要点逐个说：

- **build_norm**（src/llama-graph.cpp:1583-1616）：LLM_NORM_RMS→`ggml_rms_norm`+`mul(mw)`(+`add(mb)`)，一个函数覆盖 norm/rms/group 三种。
- **build_qkv**（src/llama-graph.cpp:1619-1745）：优先走融合权重 `wqkv`——一次 matmul 后用三个 `ggml_view_3d` 按 head 维切出 Q/K/V（src/llama-graph.cpp:1666-1675），省两次 GEMM 启动；否则三路独立 `build_lora_mm`（内部是 `mul_mat` + LoRA 的 `mul_mat(a)→mul_mat(b)→scale→add`，src/llama-graph.cpp:1514-1543）再 `reshape_3d`。
- **build_attn（KV 版）**（src/llama-graph.cpp:2839-2912）：先把 q/v/k 依次 `build_forward_expand`（注释明说：k 最后展开是为了让 rope 能融合写入 KV cache，src/llama-graph.cpp:2863-2868），然后 `mctx->cpy_k/cpy_v` 把本批 K/V 散射进 cache，注意力本体从 cache 读全量 K/V。
- **mask**：形状 `[n_kv, n_tokens, 1, n_streams]`，flash attention 时必须是 F16（src/llama-graph.cpp:29-46）。数据由 KV cache 在 `set_input` 阶段填：因果位 `p0>p1`、SWA 窗外、（Alibi 时取 `-|p0-p1|`）落 `mask_drop`（-INF），其余 `mask_keep`（0）（src/llama-kv-cache.cpp:1664-1699）。
- **build_attn_mha**（src/llama-graph.cpp:2591-2727）：两条路径。开 FA 且无 kq_bias 时用 `ggml_flash_attn_ext`（并把该算子登记为 fused node，供 `resolve_fused_ops` 检查设备支持，src/llama-graph.cpp:2632-2634；src/llama-context.cpp:505-580）；否则手写 `kq=mul_mat(k,q)→soft_max_ext(mask)→kqv=mul_mat(v,kq)`，且 `ggml_prec_set_acc(kq, GGML_PREC_F32)` 强制 F32 累加防溢出（src/llama-graph.cpp:2660-2694）。没有 `offload_kqv` 时把注意力输出节点硬钉到 CPU 后端（src/llama-graph.cpp:2718-2721）。
- **build_ffn**（src/llama-graph.cpp:1748-1947）：LLaMA 的 SwiGLU 是 `LLM_FFN_PAR`——gate/up 两个 matmul 并行算完再用融合算子 `ggml_swiglu_split` 一次算 `silu(gate)*up`（src/llama-graph.cpp:1851）；LLaMA 类模型的 down 投影因 F16 累加有数值问题被强制 F32（GLM4/JAIS2，src/llama-graph.cpp:1925-1930）。
- **收尾**（src/llama-model.cpp:2733-2751）：arch 专属图建完后统一追加 `build_pooling`（embedding 模型）、`build_sampling`（backend sampler 进图）、`build_dense_out`，最后 `set_outputs` 给 logits/embd 等打 `ggml_set_output` 标记（src/llama-graph.cpp:1362-1404）。

### 3.4 架构差异如何映射到同一张"母版图"

`llm_graph_context` 的公共构件是一套"积木"，各 arch 的构建器（src/models/*.cpp，数百个文件）按需拼装，差异被压缩到很小的分支点上：

- **MLA（DeepSeek 系列）**：FA 路径下注意力输出再过一个 `v_mla` 投影还原头维（`mul_mat(v_mla, ·)` 前后用 permute 把 n_tokens 摆到维度 1 以走 GEMM，src/llama-graph.cpp:2641-2656）；非 FA 路径同样是 kqv 后 `mul_mat(v_mla)`（src/llama-graph.cpp:2707-2711）。
- **logit soft-cap（Gemma/Grok 类）**：非 FA 路径手工展开 `scale→tanh→scale` 三节点（src/llama-graph.cpp:2680-2687）；Grok 的 tanh 变换同理（2667-2678）。注意 `use_flash_attn = cparams.flash_attn && kq_b == nullptr`（src/llama-graph.cpp:2615）——凡有 KQ 偏置或 soft-cap 的层会自动退回手写注意力。
- **注意力温度（tensioner 类模型）**：`build_inp_attn_scale` 生成随位置增长的 1×1×N 输入张量，`set_input` 时按 `log(floor(pos/floor_scale)+1)*scale+1` 逐位现算（src/llama-graph.cpp:157-174、2460-2473）——把"依赖数据的标量"做成输入而非常量，同样是保拓扑恒定的手法。
- **MoE**：`build_moe_ffn` 内部用 `ggml_mul_mat_id` 按路由 id 选专家矩阵；`build_lora_mm_id` 连 LoRA 也走 id 版 matmul（src/llama-graph.cpp:1545-1581）。

### 3.5 后端采样进图

配置了 backend sampler 时，`build_sampling` 把每个输出行的 logits 切成 `ggml_view_1d` 交给 sampler 的 `backend_apply`，由它向图中追加 top-k/top-p/温度等算子，产出 `t_sampled/t_sampled_probs/t_candidates`（src/llama-graph.cpp:3764-3830）。采样从而与模型前向同图同批执行，host 侧只剩取回一个 token id。无 backend sampler 的序列仍走传统 CPU 采样，`needs_raw_logits` 决定是否要把原始 logits 拷回 host（src/llama-context.cpp:1627-1642）。

---

## ④ decode 与 prefill 两模式对比

llama.cpp 没有两个代码路径——同一个 `decode()`，差异全部来自**批的形状与标志**：

| 维度 | prefill（prompt processing，pp） | decode（token generation，tg） |
|---|---|---|
| 典型形状 | n_tokens = n_batch（如 512/2048），被 n_ubatch 再切 | n_tokens = 1（每序列） |
| logits 标志 | 只有最后 token `logits=1`（src/llama-batch.cpp:120-128） | 唯一 token 就是输出 |
| ubatch 切分 | 单流 `split_simple`；多流 `split_equal` 方阵 | 天然就是 n_seqs×1 |
| 限制 | causal 时 `n_batch = min(n_ctx, n_batch)`（src/llama-context.cpp:245）；非因果要求 `n_ubatch >= n_tokens`（src/llama-context.cpp:1724） | 无 |
| 线程数 | `n_threads_batch` | `n_threads`（`graph_compute` 按 `n_tokens>1` 选择，src/llama-context.cpp:2492-2509） |
| 计算瓶颈 | GEMM（算力受限） | GEMV + KV 读取（带宽受限） |
| 图规模 | 节点数多，split 数与 bs=1 不同，分别 reserve（src/llama-context.cpp:632-661，日志区分 "with bs=N / bs=1"） | 图最小，可逐 token 复用 |
| KV | 只写 | 读全部历史 + 写 1 |
| encode（另类 prefill） | T5 等编码器：`split_simple` 一次整批、强制非因果、单 ubatch（src/llama-context.cpp:1432-1474） | — |

工程上最重要的两点：

1. **`n_ubatch` 是 prefill 的算力/显存旋钮**。切得小，激活显存省但 GEMM 效率差；`sched_reserve` 用 worst-case（`min(n_ctx, n_ubatch)` 个 token）预算 buffer（src/llama-context.cpp:595-596），保证任意真实 ubatch 都能装下。
2. **输出行裁剪 + get_rows** 使 prefill 的 head 计算与 prompt 长度解耦：`n_outputs` 在构图前就被统计并写进 `n_outputs`（src/llama-context.cpp:1809-1823，注释 "needs to happen before the graph is built"），图内 `inp_out_ids` 只抽这些行。

---

## ⑤ llama_context 编排细节：输出重排、异步与预算

### 5.1 输出缓冲与重排（output_reorder）

所有输出（logits/embd/nextn/层间输入/backend 采样数据）住在一块 host 侧 `buf_output` 里，`output_reserve` 按需扩容并在其中手工切偏移（src/llama-context.cpp:2096-2157）。关键不变式：**计算按"ubatch 内输出顺序"密集写行，用户按"原始 batch 下标"读行**，两者靠 `output_ids[out_id] = 行号` 映射（src/llama-context.cpp:1994-1999）。

当切分导致输出乱序（典型是 recurrent 模型的 `split_seq`），decode 用选择排序把 `out_ids` 排回原序，但**不搬数据**，只把每次 swap 记进 `output_swaps`（src/llama-context.cpp:2004-2030）：

```cpp
std::swap(out_ids[i], out_ids[j_min]);
// remember the swaps and apply them lazily upon logits/embeddings access
output_swaps.push_back({ i, j_min });
```

真正交换发生在用户第一次调 `get_logits* / get_embeddings* / get_sampled_*` 时的 `output_reorder()`（src/llama-context.cpp:2233-2299）——惰性物化：多数生成循环从不逐位读 logits，交换成本直接省掉。

### 5.2 异步与流水线

- decode 主循环**不等待**计算完成：每个 ubatch 后用 `ggml_backend_tensor_get_async` 把 logits/采样数据拷到 host 队列（src/llama-context.cpp:1874-1886、1969-1977），同步推迟到用户真正取数据（src/llama-context.cpp:2033-2034 的注释）或 `synchronize()`（src/llama-context.cpp:714-746，顺带结算 perf 统计）。
- **pipeline parallelism**（层间流水）只在多卡 layer-split 且所有设备支持 async+events 时开启（src/llama-context.cpp:427-455）。开启后 `process_ubatch` 复用图分支必须先 `sched_synchronize`，防止上一张图还在读输入就被覆写（src/llama-context.cpp:1351-1356）。
- sched 执行侧：`compute_splits` 逐 split 拷贝跨后端输入，用 event 做细粒度同步；MoE 场景还先读回 expert ids、只拷贝被选中专家的权重（按连续 id 分组批量拷，src/ggml-backend.cpp:1690-1774），这是 CPU-RAM 承载 MoE 专家 + GPU 算注意力组合的关键优化。
- backend sampler 输出走 `copy_tensor_async_rows` 按行异步拷贝并记录实际行数 count（src/llama-context.cpp:1592-1625）。

### 5.3 预算与自适应

`sched_reserve` 的三段式预算很讲究（src/llama-context.cpp:582-712）：先以 pp 最坏图分配 buffer，再以 tg 图（n_tokens=n_seqs）跑一遍只为统计 split/节点数，最后再以 pp 图重 reserve 一次"把 ggml-alloc 喂饱"避免推理中途再分配。`resolve_fused_ops` 在预算期用探针图（如 1 token/seq 的 FA 探针）实际切图，检查 fused 算子落点设备与该层权重设备是否一致，不一致则自动关闭该融合特性（src/llama-context.cpp:505-580）——这就是 `flash_attn=auto` 的实现。

### 5.4 backend sampler 的数据流（补充）

backend 采样是"一次 batch 一个事务"：decode 开头对每个 sampler 调 `llama_sampler_backend_begin`（src/llama-context.cpp:1798-1801），图内 `build_sampling` 先 `backend_reset` 再按行 `backend_apply`；计算完成后用 `copy_tensor_async_rows` 把 sampled token / 候选 / 概率按行拷进 host 端 `sampling.*` 缓冲并记录每行实际元素数 count（src/llama-context.cpp:1969-1977）。`output_reserve` 为这些数据预留 `2×n_vocab×n_outputs` 浮点 + `(1+n_vocab)×n_outputs` token 的容量（src/llama-context.cpp:2084-2089）。约束是每序列输出数不得超过 `n_outputs_max_per_seq`，decode 入口就预检并拒绝超限 batch（src/llama-context.cpp:1675-1703）。

### 5.5 sched 切图算法（ggml-backend）

`ggml_backend_sched_split_graph` 五个 pass（ggml/src/ggml-backend.cpp:1066-1390）：pass1 按"权重在谁家就归谁"初始指派（`backend_id_from_cur` 优先含权重 buffer 的后端，ggml-backend.cpp:888-919）；pass2 对未指派节点沿图序上下四轮扩散（GPU 先扩、CPU 最后兜底，ggml-backend.cpp:1124-1202）；pass3 同 buffer 类型时升级到高优先级后端；pass4 补 view/src；pass5 沿节点序把**后端相同的连续节点**合成一个 split，后端变更处插入 copy（ggml-backend.cpp:1297-1395）。`llama_context::graph_get_cb` 还会手动干预：小批或全量 offload 时把每层的 `norm/l_last` 钉在本层设备，避免 sched 把 norm 顺延到下一层设备造成来回搬运（src/llama-context.cpp:2521-2546）。

---

## ⑥ 设计动机与取舍

1. **"图是形状的函数，不是数据的函数"**：`build_forward_select` 双输入、固定拓扑的 `inp_out_ids`、backend sampler 的 dummy row（src/llama-graph.cpp:3795-3797）都是为了让 decode 稳态可以无限复用同一张图。代价是图里会存在死分支节点（选中的另一支不 compute，`ggml_build_forward_select` 以 `compute=i==idx` 标记，ggml/src/ggml.c:7295-7307）。
2. **预分配到底**：meta buffer、计算 buffer、输出 buffer、KV 全部在 `sched_reserve`/`output_reserve` 一次到位，运行期零 malloc。代价是启动慢（pp/tg/pp 三次切图），析构时还要校验"实际 buffer 尺寸 vs 预期"以防训练等场景悄悄越界（src/llama-context.cpp:485-501）。
3. **ubatch 抽象统一了异构内存**：KV/NSM/hybrid/recurrent 各 memory 模块只负责"给我 ubatch 序列"，切分策略（simple/equal/seq）作为可插拔件由它们挑选（src/llama-kv-cache.cpp:713；src/llama-memory-recurrent.cpp:438-445）。这是同一份 llama-graph 能同时服务 Transformer/Mamba/混合架构的原因。
4. **正确性边界前置到 batch 校验**：位置连续性、耦合序列、序列子集合法性全在 `init` 里拒绝（fail fast），图构建与后端执行可以假定输入干净。失败时的 KV 回滚（`seq_rm`）保住了"cache 状态 = 已成功计算的前缀"这一不变式。
5. **单 host 输出 buffer + 异步拷**：GPU→host 只发生一次大块拷贝且不阻塞下一 ubatch；代价是 `output_reorder` 这种补偿层。相比"每 token 同步取 logits"的朴素实现，这是 continuous batching 吞吐的基础。
6. **取舍点**：图复用使 `can_reuse` 检查（每输入节点一次虚调用）成为逐 token 的固定开销；`output_swaps` 的选择排序是 O(n²)（注释自认 "TODO: is there something more efficient"，src/llama-context.cpp:2007），但 n_outputs 通常很小。

---

## ⑦ FAQ

**Q1：ubatch 和 batch 的区别？**
batch 是用户提交的 token 数组（≤n_batch）；ubatch 是实际进计算图的微批（≤n_ubatch）。prefill 时一个大 batch 会被切成多个 ubatch 循环处理（`do { ... } while (mctx->next())`，src/llama-context.cpp:1806-1981），每个 ubatch 独立构图（或复用）、独立写 KV。

**Q2：为什么我传了 512 个 token 的 prompt，只有最后一个 token 有 logits？**
`balloc->init` 在用户未设 `logits` 数组时只标最后一个 token（src/llama-batch.cpp:120-128）。想全要，就自己在 batch.logits 里标，或用 embedding 模式（`output_all`）。

**Q3：`llama_get_logits_ith(i)` 的 i 是什么下标？**
是**原始 batch 里 token 的下标**，不是输出缓冲的行号。`output_resolve_row` 用 `output_ids[i]` 翻译成缓冲行（src/llama-context.cpp:858-885），未标输出的 token 会抛 "batch.logits[i] != true"。

**Q4：flash_attn=auto 是怎么决定的？**
预算阶段用 1-token 探针图真实切图一次，看 `ggml_flash_attn_ext` 节点被 sched 指到的设备是否就是该层权重所在设备；不是（后端不支持/被卸载）则关 FA（src/llama-context.cpp:519-558）。所以 FA 与 `--no-kv-offload`、分层卸载比例存在联动。

**Q5：为什么多序列并行时我的 KV cache 是分开的，但有时又报 "coupled"？**
默认 `n_seq_max` 个独立 KV 流；`--kv-unified` 时所有序列共享一个流（`n_ctx_seq = n_ctx`，src/llama-context.cpp:290-304）。一个 token 标多个 seq_id 即 fork，fork 出的序列在 KV 中共享历史（耦合），之后位置范围必须保持一致（src/llama-batch.cpp:323-335）。

**Q6：计算 buffer 为什么在启动时就要花那么久？**
`sched_reserve` 要跑 pp→tg→pp 三次完整切图+分配，外加每个 fused-op 探针一次（src/llama-context.cpp:621-681）。它换来的是推理期零分配、零 ggml-alloc 抖动。

**Q7：图的节点数上限是多少，超了会怎样？**
`graph_max_nodes` 按 `max(1024, 8×n_tensors)` + LoRA + 采样节点估（src/llama-context.cpp:2305-2353）；个别长图 arch（KIMI_K3 等）单独调高。超限会在 `ggml_visit_parents_graph` 的 `GGML_ASSERT(cgraph->n_nodes < cgraph->size)` 处硬失败（ggml/src/ggml.c:7263）。

**Q8：decode 时 log 说 "graph nodes = X (with bs=N), Y (with bs=1)" 是什么意思？**
pp 与 tg 两种形状的图节点数不同（shape 影响节点数量），`sched_reserve` 分别 reserve 并打印（src/llama-context.cpp:696-706）。运行时两类图各自可复用，交替出现时最多两次构图。

**Q9：RoPE 为什么只加在 Q/K 上，V 不加？**
见 src/models/llama.cpp:146-160：只有 Qcur/Kcur 过 `ggml_rope_ext`。RoPE 是相对位置编码，作用在点积两侧即可注入位置差；V 进注意力只做值加权，加旋转会破坏数值语义。且 K 的 rope 在写 KV 前完成（k 最后 expand 以便融合写入，src/llama-graph.cpp:2863-2868）。

**Q10：encode() 和 decode() 我该调哪个？**
有 memory 模块的模型调 decode（decoder 类 LM）；纯编码器（BERT/T5-enc/embedding）调 encode——它强制非因果、整批单 ubatch、无 KV（src/llama-context.cpp:1432-1474）。decode 遇到无 memory 的 context 会直接转发 encode（src/llama-context.cpp:1649-1652）。

---

## ⑧ 深挖问题（建议后续章节跟进）

1. **KV cache 槽位分配与 defrag 细节**：`prepare(ubatches)`/`find_slot` 如何在多流间腾挪、`memory_update(true)` 的 optimize 路径具体做什么（src/llama-kv-cache.cpp:727 与 llama-context.cpp:792-846 只见入口）——连续 batching 满载性能的真正决定者。
2. **ggml-alloc 与 sched 的内存复用协议**：图内张量生命周期（`use_counts`、ggml_new_graph_custom 的 hash 表，ggml/src/ggml.c:7449-7492）如何支撑"一个 buffer 跑整张图"，以及 `ggml_backend_sched_alloc_graph` 失败（GGML_STATUS_ALLOC_FAILED）时的降级路径。
3. **图复用与 backend sampler 的交互**：`build_sampling` 用 dummy row 维持单输出图拓扑恒定（src/llama-graph.cpp:3795-3797），但多序列多 sampler 时 `t_sampled` 数量随行数变化——`allow_reuse` 的 sampler 检查（llama-graph.h:851-867）在何种 batch 模式下会退化成每步重建图，值得实测。
4. **M-RoPE / iswa / DSA 等 KV 变体的 mask 与 ubatch 语义**：`n_pos_per_embd>1` 的位置校验放宽（src/llama-batch.cpp:255-288）、`llama_kv_cache_iswa` 的双 cache 联动（split_equal 两次，src/llama-kv-cache-iswa.cpp:173-209）——多模态与滑动窗口模型的行为差异。
5. **Meta device（张量并行）的运行时行为**：`ggml_backend_meta_device` 把多卡伪装成一个设备后，sched 切图与 `resolve_fused_ops` 的设备一致性判定如何随之变化（src/llama.cpp:170-220 引入的 `get_split_state_ud`）。

---

### 附：本篇直接覆盖文件

- src/llama.cpp（加载编排、设备选择）
- src/llama-context.cpp（构造/sched_reserve/decode/encode/process_ubatch/输出重排/预算）
- src/llama-batch.cpp + src/llama-batch.h（batch 校验与三种切分、ubatch 结构）
- src/llama-graph.cpp + src/llama-graph.h（输入/norm/qkv/ffn/attn/采样构建、图结果与复用）
- src/llama-model.cpp（load_hparams/load_tensors/build_graph 总装）
- src/models/llama.cpp（llama arch 的逐层构图实例）
- src/llama-kv-cache.cpp（init_batch 切分选择、KQ mask 填充）
- ggml/src/ggml.c（cgraph 结构、forward expand/visit）
- ggml/src/ggml-backend.cpp（sched 五 pass 切图、compute_splits）
