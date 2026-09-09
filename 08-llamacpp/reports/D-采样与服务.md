# D 篇 · 采样、词法与推理服务：llama.cpp 的"最后一公里"

> 调研对象：llama.cpp 4.5.0-dev（本仓库快照 `CMakeLists.txt:13-15`）。注意：本系列任务书提到的 `src/llama-sampling.cpp` 在 4.5 分支已重构为 `src/llama-sampler.cpp`（4385 行），`tools/cli/main.cpp` 只剩 5 行壳，真正的 CLI 在 `tools/cli/cli-context.cpp`。下文所有引用均以本仓库实际文件为准。

---

## ① 全景：从 logits 到 token 的完整链路

一次 `decode` 之后，一个 shape 为 `[n_vocab]` 的 logits 向量要经过以下环节才变成用户看到的字符：

```
 llama_decode()                                       (llama-context, 异步)
      │  llama_synchronize()
      ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │ common_sampler_sample()  common/sampling.cpp:594                │
 │   1. set_logits: 取 logits / 后端采样缓存 → cur_p 数组  :130-162 │
 │   2. rbudget 采样器(推理预算)先裁剪                     :632    │
 │   3. llama_sampler_apply(chain) 按链顺序改写 cur_p      :638    │
 │      penalties→dry→top_n_sigma→top_k→typical→top_p→min_p→xtc→temp│
 │      →dist (默认顺序定义于 common/common.h:261-271)             │
 │   4. 语法拒绝采样：抽出的 token 先单点校验, 不合法则整词表重采样 │
 │      :646-675                                                   │
 └─────────────────────────────────────────────────────────────────┘
      │  llama_token id
      ▼
 common_sampler_accept()  :467        ← 喂回 grammar/penalties 的历史
      │
      ▼
 llama_vocab detokenize → piece (src/llama-vocab.cpp:3719)
      │  streaming 截断不完整 UTF-8 (server-context.cpp:282)
      ▼
 server_slot::process_token → SSE 推给客户端 (server-context.cpp:1833)
```

关键点有三处：

1. **logits → 概率化的时机不是固定的**。早期版本进入采样器就 softmax；现在 `dist`（分布采样）之前所有"硬截断"类采样器（top-k/min-p/top-n-sigma/penalties）直接操作 logit，只有 top-p/typical/xtc/mirostat 内部需要概率时才局部 softmax（`src/llama-sampler.cpp:293` 的 `llama_sampler_softmax_impl`）。logit 空间比概率空间数值稳定、可用 `-INFINITY` 表达"绝对禁止"。
2. **CPU 采样与后端采样双轨制**。4.5 引入了 `llama_sampler_backend_*` 接口（如 top_p 的 `backend_apply`，`src/llama-sampler.cpp:1627-1659` 用 ggml 算子 `ggml_argsort + ggml_soft_max` 在 GPU 上完成），`common_sampler_sample` 开头若发现 `llama_get_sampled_token_ith` 已有结果就直接返回（`common/sampling.cpp:611-629`）。语法/推理预算与后端采样互斥（`common/sampling.cpp:415-425`）。
3. **采样器是无状态流水线 + 有状态旁路**。`llama_sampler` 是 C 风格接口对象（`name/accept/apply/reset/clone/free/backend_*` 十一个函数指针，见 `src/llama-sampler.cpp:1092-1105` 的 greedy 接口表），`apply` 负责改写 `cur_p`，`accept` 负责维护自身历史（penalties 的 token 计数、grammar 的推演栈、DRY 的 last_tokens 环形缓冲）。`common_sampler` 在链外再包了 grammar（`grmr`）和 reasoning-budget（`rbudget`）两个旁路采样器，以及 `prev` 环形缓冲（`common/sampling.cpp:111-122`，环形缓冲实现 ：20-109）。

---

## ② 采样器链逐段解读

### 2.1 链的组装

`common_sampler_init`（`common/sampling.cpp:187-438`）按用户顺序（默认 `common/common.h:261-271`）把每个枚举实例化为 `llama_sampler` 并 `llama_sampler_chain_add` 进 chain。默认顺序即**penalties → dry → top_n_sigma → top_k → typical → top_p → min_p → xtc → temperature → dist**。顺序语义非常重要：penalties/DRY 必须在排序截断前修改 logit；temperature 必须在所有截断之后、dist 之前缩放（截断类采样器阈值都与最高 logit 相关，先降温会改变相对形状）。mirostat 是例外路径：`mirostat==1/2` 时整条链替换为 `temp + mirostat`（`common/sampling.cpp:401-409`），因为它自己完成截断与抽样。另有 `adaptive_p`（按目标概率选 token 的自适应采样，:383-389）。

### 2.2 基础原语：softmax / top-k / dist

softmax（`src/llama-sampler.cpp:293-319`）：减去最大 logit 防溢出，两遍完成；若数组已排序则跳过 max 扫描。top-k（:321-338）：用**部分排序**只把前 k 个排出来——`llama_token_data_array_partial_sort_inplace`（:193-215）在 `k≤128` 时 `std::partial_sort`，否则走 histogram-bucket 加速的 `partial_sort`（:155-190 附近），避免对 12 万+词表全排序。

`dist` 是链上唯一切实体出 token 的采样器（`src/llama-sampler.cpp:1150-1223`）。它做了一个巧妙的单遍优化：

```cpp
// src/llama-sampler.cpp:1190-1208
const double rnd = dist(ctx->rng);
      double sum_run = 0.0f;
const double sum_tgt = sum_cum*rnd;   // 目标累积和
for (size_t i = 0; i < cur_p->size; ++i) {
    if (!found) {
        sum_run += cur_p->data[i].p;
        if (sum_run >= sum_tgt) { cur_p->selected = i; found = true; }
    }
    cur_p->data[i].p /= sum_cum;      // 采样与归一化合并成一遍
}
```

注释标注这在 gpt-oss 词表上比"先归一化再 `discrete_distribution`"快约 3 倍（:1188）。`temp<=0` 时 `llama_sampler_temp_impl` 退化为 argmax（:270-286），保证 greedy 路径零随机性。

### 2.3 top-p（nucleus）

`llama_sampler_top_p_apply`（`src/llama-sampler.cpp:1549-1602`）是性能最讲究的一段：

```cpp
// src/llama-sampler.cpp:1556-1593 (节选)
llama_sampler_softmax_impl(cur_p, false);
size_t k = cur_p->size;
auto * pdata = cur_p->data;
// if not sorted, try adaptive top-k sorting
if (!cur_p->sorted && cur_p->size > 1024) {
    k = std::min<size_t>(256, cur_p->size);      // 先只排前 256
    llama_token_data_array_partial_sort(*cur_p, k, buf_sort);
    pdata = buf_sort.data();
} else if (!cur_p->sorted) {
    llama_token_data_array_partial_sort_inplace(cur_p, k);
}
float cum_sum = 0.0f;
for (size_t i = 0; i < cur_p->size; ++i) {
    cum_sum += pdata[i].p;
    if (cum_sum >= ctx->p && i + 1 >= ctx->min_keep) { last_idx = i + 1; break; }
    // we exceeded the current top-k heuristic -> increase k and continue
    if (!cur_p->sorted && i == k - 1) { k = cur_p->size; /* 退化成全排 */ }
}
```

核心思想：**期望 top-p 集合几乎总落在前 256 名内**，先用 256 的部分排序开始累积，只有当累积和到尾部还没达到 p 时才升级为全排序（:1588-1592），把大词表下的均值复杂度从 O(N logN) 拉到接近 O(N)。`cur_p->sorted` 标志在链上传递——若上游 top-k 已经排序，下游直接复用。

### 2.4 min-p

min-p 与 top-p 的区别：截断阈值是 `p_max * min_p`（相对最高概率），而不是累积和。未排序路径甚至不需要排序——因为阈值只依赖 max logit：

```cpp
// src/llama-sampler.cpp:1762-1772
float max_logit = -FLT_MAX;
for (size_t i = 0; i < cur_p->size; ++i)
    max_logit = std::max(max_logit, cur_p->data[i].logit);
const float min_logit = max_logit + logf(ctx->p);  // p_i >= p * p_max ⇔ logit >= max + ln(p)
for (size_t i = 0; i < cur_p->size; ++i)
    if (cur_p->data[i].logit >= min_logit) filtered_tokens.push_back(...);
```

对数域一次减法完成阈值换算（:1766），O(N) 无排序；只有结果数小于 `min_keep` 时才回退到排序实现（:1783-1800）。后端版用 `ggml_argmax + ggml_scale_bias + ggml_step + ggml_log` 把掩码表达成可加的 logit 偏置（:1845-1861）。

### 2.5 typical / top-n-sigma / xtc

- **typical**（:1910-1968）：softmax 求熵 `H = -Σ p·log p`，再按 `|−log p − H|` 升序排序，累积到 `p` 截断——保留"信息量接近整体熵"的 token。
- **top-n-sigma**（:3237-3274）：线性域求 mean/σ（跳过 `-INFINITY`），把 `logit < max − n·σ` 置 `-INFINITY`，无需 softmax。
- **xtc**（:2344-2375）：以 `xtc_probability` 掷骰决定本次是否生效，然后**删除概率 ≥ threshold 的头部 token**（`cur_p->data += pos_last` 指针平移，:2371-2374），即"故意排除最优解"以提升创造性，是少见的"反向截断"。

### 2.6 mirostat v1/v2

v1（:2460-2494）：softmax 后用前 m 个 token 的概率对数斜率做最小二乘估计 Zipf 指数 `ŝ`，解出满足目标惊奇值 `τ` 的 top-k 大小 `k`，`top_k` 截断后抽样；用观测惊奇 `-log2 p` 与 `τ` 的误差以学习率 `η` 更新 `μ`（:2489-2493）。v2（:2573-2599）去掉 Zipf 估计，直接以 `−log2 p > μ` 截断，本质是**在线控制生成熵的反馈回路**。两者都持有跨 step 的 `mu` 与 `mt19937` 状态，所以 `clone/reset` 必须复制 rng（:2511-2516）。

### 2.7 penalties 与 DRY

penalties（:2950-2980）：维护 `last_n` 内 token 计数哈希，`logit<=0` 时乘 repeat 惩罚、否则除（:2968-2974 注释解释：论文原版用除法，负 logit 会越罚越强，此处是常见修正），再加 `count*freq + (count>0)*present`。DRY（:3386 起）：先扫描 restart 序列（如 `\n`）限定重复上限（:3402-3461），再用**反向 Z-algorithm** 求"当前后缀在历史中最大重复长度"（:3463-3483 注释给出 a b c c b c 的示例），对超出 `allowed_length` 的延续 token 施加 `multiplier * base^(len-allowed)` 惩罚——对"代码重复/口吃"比线性 penalties 精准得多。

### 2.8 采样流水线图

```
logits [n_vocab]
   │
   ▼
(0) logit_bias / suppress_tokens ─ -inf 直接压掉           sampling.cpp:326-338
   │
   ▼
(1) penalties   logit ← ÷repeat − freq·cnt − present·1     llama-sampler.cpp:2950
   │
   ▼
(2) dry         Z-alg 重复长度 → base^len 惩罚              :3386
   │
   ▼
(3) top_n_sigma max−n·σ 以下 → -inf（不排序）               :3237
   │
   ▼
(4) top_k       partial_sort → size=k                      :321
   │
   ▼
(5) typical     softmax→熵→|−logp−H| 升序累积截断           :1910
   │
   ▼
(6) top_p       softmax→自适应 256 部分排序→累积≥p 截断      :1549
   │
   ▼
(7) min_p       logit ≥ max+ln(min_p)（无排序 O(N)）        :1749
   │
   ▼
(8) xtc         概率性丢弃头部高概率段                      :2344
   │
   ▼
(9) temperature logit /= temp; temp≤0 ⇒ argmax              :265
   │
   ▼
(10) dist       单遍 softmax+离散抽样 → selected             :1150
   │
   ▼
(旁路) grmr     先单点校验选中 token, 不合法 ⇒ grammar 先行+整链重采样  sampling.cpp:646-675
   │
   ▼
 id → accept(penalties/grammar/prev) → detokenize → stream
```

---

## ③ GBNF 语法约束的推演机制

`src/llama-grammar.cpp`（1525 行）实现了一个**非确定性下推自动机（NPDA）**：GBNF 文本编译为规则向量 + 推演栈集合，采样时对候选 token 逐个模拟推进、不匹配者 logit 置 `-INFINITY`。

### 3.1 编译期：文法 → 规则 + 初始栈

`llama_grammar_parser::parse`（自递归下降，`llama-grammar.h:86-117`）把 `root ::= ...` 产出为 `llama_grammar_rule = vector<llama_grammar_element>`，每个元素是 `{type, value}` 二元组（`llama-grammar.h:47-50`），type 覆盖 END/ALT/RULE_REF/CHAR/CHAR_NOT/CHAR_RNG_UPPER/CHAR_ALT/CHAR_ANY，4.5 新增 **TOKEN / TOKEN_NOT**（:40-44）——允许 `<[token-id]>` 直接引用 token 级规则（`llama_grammar_match_token`，`llama-grammar.cpp:841-852`）。

编译期做两项关键校验：规则引用合法性（:1145-1155）与**左递归检测** `llama_grammar_detect_left_recursion`（:958-1009，三色 DFS + 可空规则传播），左递归会导致推演栈无限展开，直接拒绝。然后对 root 规则的每个 alternate 调 `llama_grammar_advance_stack` 生成初始栈集（:1264-1284）。

### 3.2 推演栈

栈是"指向 rule 元素的指针数组"，从底到顶表示"消费完这个 token 后还剩什么要匹配"。`llama_grammar_advance_stack`（:856-937）把栈顶展开到终结符为止：遇 `RULE_REF` 则弹出引用、压入"引用之后的剩余序列 + 子规则首个 alternate"，循环直到栈顶是 CHAR/TOKEN 类终结符；用 `std::set` 去重避免组合爆炸。字符匹配 `llama_grammar_match_char`（:761-786）处理 `[a-z]`/`[^…]`/`.`，返回 `(匹配?, 下一元素指针)`。

### 3.3 采样期掩码

`llama_grammar_apply_impl`（:1354-1395）三步走：若有空栈则放行 EOG token；否则把每个候选 token 的 piece 做 `decode_utf8`（带 `partial_utf8` 半字节状态，:34-91）转成码点流；对全部候选调 `llama_grammar_reject_candidates`（:939-956）——它对**每条栈**串联过滤 `reject_candidates_for_stack`，被所有栈拒绝的 token 才真正被拒（栈集是"任一"语义）。

`reject_candidates_for_stack`（:1056-1125）是递归前瞻：逐码点匹配栈顶字符，能吃掉的进入 `next_candidates`，再 `advance_stack` 推进栈后递归；部分 UTF-8 用 `llama_grammar_match_partial_char`（:791-837）——把已收到的位左移后构造 `[low, high]` 码点区间与字符范围求交，**允许 token 边界切在多字节字符中间**。

```cpp
// src/llama-grammar.cpp:1117-1124 (递归前瞻)
llama_grammar_stacks next_stacks;
llama_grammar_advance_stack(rules, stack_after, next_stacks);
auto next_rejects = llama_grammar_reject_candidates(rules, next_stacks, next_candidates);
for (const auto & tok : next_rejects)
    rejects.push_back({ tok.index, tok.code_points - 1, ... }); // 回退一个码点
```

### 3.4 accept 与惰性触发

`llama_grammar_accept_token`（:1471-1524）对每条存活栈逐码点推进，全灭则抛异常（说明掩码与 accept 之间状态不一致）。惰性语法（lazy grammar）服务 tool-call 场景：`awaiting_trigger=true` 时掩码不生效，token 进 `trigger_buffer`，命中 trigger token 或正则 pattern 后把重叠 token **重放进语法**再开始约束（:1402-1442）。`common/sampling.cpp:297-308` 还会把模板已生成的 generation prompt 预喂给 grammar（仅 output-format/tool-call 语法，判定见 `common/common.h:218-221`）。JSON schema → GBNF 的转换入口在 `common/json-schema-to-grammar.cpp:1237`。

---

## ④ 分词三模型要点

`src/llama-vocab.cpp`（4458 行）按 `LLAMA_VOCAB_TYPE` 分发到四种实现：SPM/BPE/WPM 之外还有 UGM(unigram) 与 RWKV/PLAMO2 等新模型（:897、:1306、:1361）。

**SPM（SentencePiece BPE）**（:115-239）：文本先按 UTF-8 字节切成 `llm_symbol` 双向链表，用大顶堆（按 score，平局取左侧，:97-109）反复合并"能组成词表 token 的相邻对"；最终对每个符号走 `resegment`（:177-201）递归还原成 token，查不到就按字节 fallback。`▁` 空格约定由 `precompiled_charsmap` 归一化支持（`impl` 字段 ：1857，来自 GGUF 内嵌的 SPM precompiled charsmap）。

**BPE**（:264-768）：GPT 风格。先按 `pre_type` 对应的预分词正则切块（正则表 ：280-560，LLAMA3 的 `(?:'[sS]|...)` 改写规避了 `(?i:)` 不可移植，:286-291；DEEPSEEK_LLM 是 6 条正则串行 ：309-318），块内再跑"rank 驱动的 bigram 合并"——`find_bpe_rank` 查 `unordered_map<pair<string,string>,int>`（:1848），rank 最小者先合并，与 SPM 用 score 相同而比较方向相反。字节 fallback 两种形态：byte_encode 走 GPT2 的 Ġ 形态字节字符，非 byte_encode（Gemma4）拼 `<0xXX>`（:711-727）。

**WPM（BERT）**（:781-890）：preprocess 做 NFD 去重音/小写化/标点切字（含中文逐字切分判定 `is_chinese_char`，:873-885），加 `▁` 幻影空格后做**最长匹配贪心**（`max_token_len` 内从长到短，:801-818），一个词只要失败就整词丢弃并打 UNK——比 BPE 激进得多。

**预编译/缓存优化**（4.5 实际存在的三处）：
1. **token→piece 全表缓存**：加载完成后一次性构建 `cache_token_to_piece`（:3027-3042，启动日志打印其 MB 大小），语法掩码、detokenize 走 O(1) 查表（:3715-3717）。
2. **special token 缓存**：控制类 token 按文本长度降序排序，供 `tokenizer_st_partition`（:3226）在线性扫描中切分可解析的 special 片段。
3. **unicode 类别位表**：`src/unicode-data.cpp` 由 `scripts/gen-unicode-data.py` 生成（:1），`unicode_cpt_flags` 用 16 bit 位域表达 `\p{L}` 等 12 类（`src/unicode.h:8-90`），常用 GPT2/LLAMA3/QWEN2 的预分词正则被改写成**手写扫描器**（`unicode_regex_split_custom_*`，`src/unicode.cpp:215/333/474/610/777/948`），只有未匹配的 pre_type 才 fallback 到 `std::regex`（:743-753）——这是对 `std::regex` 性能与 `\p{...}` 支持不齐的双重规避。

---

## ⑤ chat template：双轨制与差分自动解析器

4.5 存在两条模板管线：

**legacy 轨**（`src/llama-chat.cpp`）：手写 50+ 模板枚举（名字表 ：28-83）+ 字符串启发式识别 `llm_chat_detect_template`（:89-240，如 `<|im_start|>`→ChatML、`[INST]`+`[SYSTEM_PROMPT]`→MISTRAL_V7、`<|start_header_id|>`→LLAMA_3），再由 `llm_chat_apply_template`（:244 起）用 `stringstream` 拼 prompt。注释明言"It is not a jinja parser"（:243）——快但覆盖不全。

**Jinja 轨**（`common/chat.cpp` + `common/jinja/`，7818 行的自研 Jinja 引擎）：`common_chat_templates_apply`（:1414-1418）按 `use_jinja` 分派。`common_chat_templates_apply_jinja`（:1205-1346）先做能力探测（`caps`：是否支持 system role/tool calls 等）、一堆 workaround（developer→system、content 非空化），然后**优先尝试专用模板**，失败则进入 4.5 新的**差分自动解析器（differential autoparser）**：

```cpp
// common/chat.cpp:1311-1342 (节选)
if (auto result = common_chat_try_specialized_template(tmpl, src, params))
    return *result;
// using differential autoparser
struct autoparser::autoparser autoparser;
autoparser.analyze_template(tmpl);
auto auto_params = autoparser::peg_generator::generate_parser(tmpl, params, autoparser);
```

它对任意 Jinja 模板做静态分析，推断出消息定界符与 reasoning 标签，并**生成一个 PEG 解析器**（`chat-peg-parser.cpp`，`data.parser` 存回 `common_chat_params`）供推理时把模型输出流式解析回 `content / reasoning_content / tool_calls` 结构——这取代了旧版为每个模型手写的 `common_chat_..._template` 工具调用解析器。tool-call 与 JSON schema 输出还会联动生成 grammar（`params.grammar`）与 trigger patterns，接回 ②③ 的采样链。

模板初始化时还会用固定对话跑一遍 `common_chat_format_example`（:677-702）供 `/props` 展示与校验（`common_chat_verify_template`，:684）。

---

## ⑥ server 的并发模型：slots 与 continuous batching

### 6.1 模块分层

`tools/server/` 已完全模块化：`server.cpp`（562 行壳：信号、路由注册、router 模式、MCP/tools 装配）、`server-http.cpp`（cpp-httplib 封装，`server-http.cpp:7` include；独立 HTTP 线程 ：465）、`server-context.cpp`（5558 行核心：模型加载 + 主循环 + 全部推理逻辑）、`server-queue.cpp`（任务队列）、`server-task.cpp`（任务/结果类型）、`server-chat.cpp`（OAI 兼容层）、`server-stream.cpp`（可恢复 SSE 会话）等。`server.cpp:246-304` 集中注册 40+ 路由，`ex_wrapper`（:54-86）把 handler 异常统一转为 4xx/5xx JSON。4.5 还新增 **router 模式**：不加载模型的纯代理 server，按需 spawn 子进程加载模型（`server.cpp:135-244`）。

### 6.2 单线程主循环 + 任务队列

HTTP 线程从不碰 llama_context，只把 `server_task`（类型表 `server-task.h:15-29`）投进 `server_queue` 并在 `server_response` 上等待结果。主循环 `start_loop`（`server-queue.cpp:278` 起）严格遵循头文件注释的四拍（`server-queue.h:80-95`）：

```
process_new_tasks() → callback_update_slots()(即 update_slots) → 等新任务 → (可选休眠)
```

任务分三级队列：`queue_tasks / queue_tasks_deferred`（等 slot 空出，`pop_deferred_task` 按 slot 唤醒）/ `queue_tasks_unhandled`（yield 期间拒收的回灌）。`yield_to_queue`（`server-queue.h:97-104`）允许在 decode 运行期间把"读状态"任务丢给 worker 线程处理（PR #27041，metrics 不被长 decode 阻塞）。空闲 `idle_sleep_ms` 后进入 sleeping 状态，按注册逆序回调（模型可换页/释放）。

### 6.3 slot 与 continuous batching

`server_slot`（`server-context.cpp:239-368`）是一个请求的全部执行状态：独立采样器 `smpl`（每请求 `common_sampler_init`，:1783）、KV 内存句柄 `common_memory mem`、speculative 草稿、prompt 缓存等。`n_parallel` 个 slot 共享一个 llama_context 与统一 KV pool（`n_parallel<0` 时自动取 4 并开 `kv_unified`，`server.cpp:152-157`；`--kv-unified-per-slot` 自动算 `n_ctx`，:162-170）——**同一 batch 里每个 token 通过 `seq_id=slot.id` 隔离各自的 KV 序列**（`common_batch_add(batch, ..., {t.id_slot}, ...)`，:207）。

每个主循环迭代的 `update_slots`（:2793-2907）：

1. 全 idle 直接返回；
2. `pre_decode()`（:2909 起）：逐 slot 处理 context shift（`seq_rm + seq_add` 丢一半旧 token，:2934-2952）、采样器已在 launch 时就绪；
3. 把所有 slot 的"下一 token"汇进一个 `llama_batch`，按 `n_batch` 切视图逐段 `decode`（:2870-2891）；
4. `post_decode()`（:3784-4024）：对每个 `i_batch` 命中的 slot 调 `common_sampler_sample` + `accept`（:3856-3861），`process_token` 检查停止条件（EOS/停止串/n_predict/上下文耗尽）后 `send_final_response` 或继续流式发送；speculative 分支用 `common_sampler_sample_and_accept_n` 验证草稿并按 checkpoint 回滚（:3911-3954）。

这就是 **continuous batching**：没有 epoch 界限，任何 slot 在任意迭代结束即可退出、任何新任务在任意迭代加入，batch 大小随空闲 slot 自然伸缩。

### 6.4 slot 调度与 prompt 缓存

`get_available_slot`（:1547-1656）三级策略：指定 id → **LCP 相似度**（与各 slot 缓存 prompt 求最长公共前缀，超过 `slot_prompt_similarity` 阈值者复用其 KV，:1560-1610）→ LRU。选中后若会丢弃较多旧上下文，先 `prompt_save` 把 KV 状态存入 `server_prompt_cache`（RAM/磁盘 LRU），再尝试 `prompt_load` 精确匹配新 prompt（:1642-1656）——这是 server 层的 prompt cache，与 llama 本体的 KV 复用互补。

### 6.5 CLI 概览

`tools/cli/main.cpp`（5 行）→ `cli.cpp` 的 `llama_cli`（65 行）→ `cli_context::run()`。4.5 的 CLI 不再直接驱动 llama_context，而是**内嵌一个 llama-server**（`cli-server.h:36-55`：随机端口起线程跑 `llama_server(params, 0, nullptr)`），或经 `--server-base` 连外部 server；交互状态就是一个 `impl->messages` JSON 消息数组（`cli-context.cpp:509/531/632` 附近），支持 `/clear`、`/regen`、`/image`、`/read`、`/glob` 等斜杠命令（:502-560），流式输出经 `generate_completion` 拆出 reasoning/content。 SIGINT 处理为"第一次中断停止生成、第二次退出"（`cli.cpp:22-31`）。

---

## ⑦ 设计动机与取舍

1. **logit 空间 + 惰性 softmax**：截断类采样器全部在 logit 域工作，只在需要概率时局部 softmax——省一次全词表 exp，也避免了多次归一化的精度漂移；代价是 `sorted` 标志必须随 `cur_p` 小心传递（min_p 未排序路径失败要回退重排，`src/llama-sampler.cpp:1783`）。
2. **common 层采样链（可执行参数化）而非编译期组合**：全部由 `common_params_sampling::samplers` 数组运行时拼装，`-s` 单字符语法（`common_sampler_type_to_chr`，`common/sampling.cpp:795-810`）沿用至今。代价是链上每个采样器都要实现 11 个接口函数 + backend 双实现。
3. **语法约束的"乐观路径"**：默认先采后验（单 token 单点校验，`common/sampling.cpp:646-657`），绝大多数 token 合法时整词表掩码被完全跳过——这是对"全词表 GBNF 掩码代价高"的工程化解；`grammar_first` 模式留给"所有候选必须合法"的场景（如 n_probs 展示）。
4. **双 track 模板 + PEG 自动解析**：手写 legacy 保证零依赖可用，Jinja+autoparser 换取任意新模型开箱即用；代价是 common/chat 代码复杂度暴涨（chat.cpp 1450+ 行、jinja 目录近 8000 行）。
5. **server 单线程推理循环**：所有 llama_context 操作集中在一个线程，靠任务队列传递，彻底免除锁——HTTP/worker/主循环三线程分工明确；代价是长 decode 期间新任务排队，需要 `yield_to_queue`、deferred 队列等补丁维持响应性。
6. **CLI 退化为 server 的客户端**：消除两套推理循环的维护成本，`--server-base` 直接复用远端；代价是本地交互多一层 HTTP/JSON 序列化。

---

## ⑧ FAQ

**Q1: 为什么 temp 必须放在 top-p/min-p 之后？**
截断阈值依赖相对形状：min-p 阈值是 `max_logit + ln(min_p)`（`src/llama-sampler.cpp:1766`），top-p 依赖 softmax 归一。先降温会改变分布尾部形状，同样的 top_p 值会切出不同的集合。官方默认序把 temperature 放在倒数第二（`common/common.h:261-271`）。

**Q2: top_k=0 / top_p=1 / min_p=0 时这些采样器还有开销吗？**
基本为零：top_k `k<=0` 直接 return（:326-328）；top_p `p>=1.0f` return（:1552-1554）；min_p `p<=0` return（:1752-1754）。

**Q3: 语法约束下采样一定更慢吗？**
不一定。走"先采后验"时只有被拒的 token 才触发全词表掩码+重采样（`common/sampling.cpp:646-675`）。真正慢的场景是 `grammar_first`、n_probs>1（需要所有候选合法）以及大栈集的惰性语法。llguidance 可替换内置引擎（`common/sampling.cpp:213-218`）。

**Q4: greedy (temp=0) 会走随机数路径吗？**
不会。temp_impl 把非最大 logit 全置 `-INFINITY`（:270-286），dist 在 `size==1` 时仍按后端对齐消耗一次 rng（:1163-1168）以保证与后端采样种子序列一致——纯粹的对齐用意，不影响结果。

**Q5: 为什么聊天时输出乱码/开头多了奇怪 token？多半是模板问题。**
模板识别错误的典型症状。legacy 识别靠特征串（`src/llama-chat.cpp:89-240`），识别不出会返回 UNKNOWN；建议 `--jinja` 走 Jinja 轨并用 `/props` 检查 `chat_template`。GGUF 元数据里含模板原文（`common/chat.cpp:757`）。

**Q6: BPE 分词为什么和 HF tokenizer 有差异？**
预分词正则从 `tokenizer.json` 的 PCRE 手工改写（去 `(?i:)`，`src/llama-vocab.cpp:286-291`），并用手写扫描器近似实现（`src/unicode.cpp:1050-1078`）；未覆盖的 pre_type 走 `std::regex`（ECMAScript 方言不支持 `\p{N}` 完整语义），边缘 unicode 差异由此而来。

**Q7: server 里 `-np` 与 `-c` 什么关系？**
`n_parallel` 是 slot 数，`n_ctx` 是总 KV 池。统一 KV 下每 slot 可用上下文约为 `n_ctx / n_parallel`；`--kv-unified-per-slot` 会反向自动设 `n_ctx = n_parallel * kv_unified_per_slot`（`server.cpp:162-170`）。

**Q8: streaming 的 SSE 里 token 是逐个发的吗？中间会不会断 UTF-8？**
不是逐字节。slot 维护 `n_sent_text`，`server-context.cpp:282` 明确注释按"已完整 UTF-8 的字符数"发送，多字节字符攒齐才推，避免客户端收到半个汉字。

**Q9: 同一 prompt 反复请求为何第二次快很多？**
两级缓存：KV 复用（LCP 选 slot，`server-context.cpp:1584`）+ `server_prompt_cache` 把整段 KV 状态序列化到内存/磁盘（`slot.prompt_save`，:299-323），命中时免 prefill。

**Q10: 一个请求独占一个 slot 吗？并行请求会互相等待吗？**
空闲 slot 足够时互不等待（deferred 队列只容纳超出 slot 数的任务，`server-queue.h:58-59`）；父子任务（parallel tool calls）会拆成多 slot，不够就 defer（`server-context.cpp:2422-2425`）。

---

## ⑨ 深挖问题

1. **后端采样的最终形态**：`backend_apply` 已覆盖 greedy/dist/top_p/min_p/penalties 等（`src/llama-sampler.cpp:1627-1659`、`3030`），但 grammar 与 reasoning-budget 被硬性排除（`common/sampling.cpp:415-425`）。问题：掩码类操作能否下沉为 ggml 算子而不引入 D2H 拷贝？`n_outputs_max_per_seq>1` 时 penalties 拒绝后端化（:3018-3021）的边界何时能打破？
2. **推演栈集的规模控制**：`advance_stack` 仅用指针字典序 `std::set` 去重（`llama-grammar.cpp:871`），对高歧义文法（大量嵌套 alternation）栈集可能指数增长；现有实现无栈数上限或合并策略，是否可引入 LR(0) 项目集/图结构压缩？
3. **差分 autoparser 的鲁棒性**：`autoparser.analyze_template` 从 Jinja AST 反推定界符（`common/chat.cpp:1316-1342`），对含条件分支的模板（如 `{% if tool %}` 两套格式）如何选择？失败即抛异常（:1343-1345），缺降级路径——是否值得保留 legacy 手写解析器作为后备？
4. **update_slots 的公平性**：continuous batching 中所有 slot 每 iteration 各产 1 token，但 prefill 大 prompt 的 slot 会让整个 batch 停在 `SLOT_STATE_PROCESSING_PROMPT`；缺少抢占式调度/分片 prefill，多租户下首 token 延迟如何保障？`yield_to_queue`（PR #27041）只是部分缓解。
5. **采样确定性 vs 投机解码**：`common_sampler_sample_and_accept_n` 在草稿验证时用同一采样器连续采样（`common/sampling.cpp:678-706`），依赖"草稿 token == 主模型采样"即接受；这与严格拒绝采样（按概率比接受）不等价，温度非 0 时输出分布相对普通采样是否有偏？speculative checkpoint 回滚（`server-context.cpp:3931-3954`）恢复了 KV 状态，但 sampler 的 `prev` 历史/grammar 栈靠 `common_sampler_copy` 整体还原——语义上是否完备？
