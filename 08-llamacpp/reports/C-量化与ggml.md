# C 篇 · 量化体系与 ggml 张量库(llama.cpp 源码深读)

> 调研对象:llama.cpp 仓库(本卷快照)。核心文件:`ggml/src/ggml-common.h`(1911 行)、`ggml/src/ggml-quants.c`(5667 行)、`src/llama-quant.cpp`(1486 行)、`ggml/src/ggml.c`(8139 行)、`ggml/src/ggml-impl.h`(795 行)、`ggml/src/ggml-backend.cpp`(2506 行)、`ggml/src/ggml-cpu/ggml-cpu.c`(3936 行)。所有结论均标注 `文件:行号`。

---

## ① 全景:量化 = 让 LLM 进家用内存的核心

llama.cpp 的产品主张是"在消费级硬件上跑 LLM",这件事的物理前提是**把权重从 FP16 压到 2~6 bit/权重(bpw)**。整个量化体系分三层:

1. **格式层**(`ggml-common.h`):每种量化类型定义一个 C 结构体,即"块布局契约"。所有后端(CUDA/Metal/CPU/Vulkan…)通过 `GGML_COMMON_DECL_*` 宏共享同一份结构定义(`ggml-common.h:60-72`),并用 `static_assert` 钉死字节大小(如 `ggml-common.h:199`)。GGUF 文件里的量化数据就是这些结构体的朴素数组,无任何封装——文件格式与内存布局零拷贝对齐。
2. **算法层**(`ggml-quants.c`):`quantize_*_ref` 系列是"建文件的确定性参考实现"(注释见 `ggml-quants.c:39,112,275`),K-quant/i-quant 系列带 imatrix(重要性矩阵)加权的搜索式标定(`ggml-quants.c:799-878,1553-1624`)。
3. **运行时层**:推理时激活按块动态量化为 Q8(由 `type_traits_cpu` 表的 `from_float`/`vec_dot`/`vec_dot_type` 三元组驱动,`ggml-cpu/ggml-cpu.c:215-259`),点积走纯整数路径(`ggml-cpu/arch/x86/quants.c:701-857`)。

一块权重的旅程:**GGUF mmap →(量化工具链时)浮点统计 + 逐块标定 →(推理时)块结构直接驻留显存/内存 → vec_dot 整数点积 → 每块乘 scale 累加浮点和**。整个过程没有任何"反量化成大矩阵再乘"的中间态,这是 llama.cpp 在 8GB 内存机器上能跑 7B/13B 模型的根本原因。

---

## ② 量化格式逐字节解读

### 2.1 基本块:q4_0 / q4_1 / q5_0 / q8_0

`QK4_0 = 32`(`ggml-common.h:194`),即每 32 个权重为一个块,块内共享 scale。

```
block_q4_0(18 B / 32 权重 = 4.5 bpw)          ggml-common.h:195-198
+--------+----------------------------+
| d (2B) | qs[16] (16B, 32 个 4bit)   |
| f16    | 低 nibble=偶位, 高=奇位     |
+--------+----------------------------+
反量化: x[j] = d * (q[j] - 8)      q ∈ [0,15] → 范围 [-8d, +7d]

block_q4_1(20 B / 32 = 5.0 bpw)               ggml-common.h:202-212
+---------+---------+------------------+
| d (2B)  | m (2B)  | qs[16] (16B)     |
| scale   | min     | 32 个 4bit 无符号 |
+---------+---------+------------------+
反量化: x[j] = d * q[j] + m    (仿射,多一个 min 平移)

block_q5_0(22 B / 32 = 5.5 bpw)               ggml-common.h:230-235
+--------+-----------+------------+
| d (2B) | qh[4](4B) | qs[16](16B)|
+--------+-----------+------------+
第 5 位单独放: q = (qh>>j &1)<<4 | nibble   → 5 bit 无符号, x = d*(q-16)

block_q8_0(34 B / 32 = 8.5 bpw)               ggml-common.h:251-256
+--------+------------------+
| d (2B) | qs[32] (int8×32) |
+--------+------------------+
x[j] = d * q[j],  q ∈ [-128,127](实际由 roundf(x/d) 决定,|q|≤127)
```

注意 q4_0 的标定技巧:`d = max / -8`(`ggml-quants.c:132`)——scale 带符号,把"绝对值最大的那个权重"映射到码字 0 而不是 15,配合 `x0 + 8.5f` 的舍入(`ggml-quants.c:141`)实现对称量化,省掉了 q4_1 的 min 字段。q8_1(`ggml-common.h:258-269`)则额外存 `s = d * sum(qs[i])`,这是 K-quant 点积里"min 校正项"的快速通道。

### 2.2 super-block(K-quant):scale 的分层量化

K-quant 把 super-block 定为 `QK_K = 256`(`ggml-common.h:89`),内部再切 8×32 或 16×16 的子块;**子块 scale 本身又被量化**(4/5-bit 用 6-bit,6-bit 用 8-bit),配一个 f16 的 super-block scale `d`。以 q4_K 为例(`ggml-common.h:327-338`):

```
block_q4_K(144 B / 256 = 4.5 bpw)
+--------------+--------------------+----------------+
| dm (4B:f16×2)| scales[12] (12B)   | qs[128] (128B) |
| d | dmin     | 8×6bit scale+min   | 256×4bit       |
+--------------+--------------------+----------------+
w = d * sc[j] * q - dmin * m[j]   (j = 子块号, 8 个子块×32 元素)
有效位宽 = (4 + 12 + 128)×8 / 256 = 1152/256 = 4.5 bpw(注释 ggml-common.h:326)
```

12 字节装 16 个 6-bit 数(8 scale + 8 min)的位压缩是理解 K-quant 的门槛:前 4 对 scale/min 各占 1 字节的低 6 位(`scales[0..3]`、`scales[4..7]`),剩下 8 个 6-bit 的高 2 位挤进 `scales[8..11]` 的位流里。解包代码(`ggml-cpu/arch/x86/quants.c:2069-2074`)用三个掩码完成:

```c
static const uint32_t kmask1 = 0x3f3f3f3f;   // 低 6 位×4
static const uint32_t kmask2 = 0x0f0f0f0f;   // 高字节低 4 位
static const uint32_t kmask3 = 0x03030303;   // 高 2 位
memcpy(utmp, x[i].scales, 12);
utmp[3] = ((utmp[2] >> 4) & kmask2) | (((utmp[1] >> 6) & kmask3) << 4);
const uint32_t uaux = utmp[1] & kmask1;
utmp[1] = (utmp[2] & kmask2) | (((utmp[0] >> 6) & kmask3) << 4);
utmp[2] = uaux;  utmp[0] &= kmask1;
```

其余 K-quant 同理,注释直接标了 bpw:q2_K=2.625(`ggml-common.h:297`)、q3_K=3.4375(`:314`)、q5_K=5.5(`:343`)、q6_K=6.5625(`:361`)。q6_K 的 scale 用 int8 直接存(`ggml-common.h:365`),不再二次量化。

这套分层设计的内在逻辑值得展开:如果只用 32 权重一块的 per-block scale,要把 bpw 压到 4 以下,scale 的字节开销占比会急剧上升(例如每 16 权重一个 f16 scale 就是 8.9% 的开销);而 super-block 方案用"256 权重共享一个 f16 + 16 个子块各 6-bit"的结构,把 scale 的摊销成本降到每权重不足 1 bit,同时保留了块内自适应能力。q2_K 是最极端的例子:它连子块的 min 都单独量化并配了独立的 super-block scale `dmin`(`ggml-common.h:303-304`),因为 2-bit 码字只有 0~3,动态范围极小,min 偏置的精度直接决定误差大小。另一个细节是所有块结构体都显式排除了编译器填充——`static_assert(sizeof(block_q4_0) == sizeof(ggml_half) + QK4_0/2)`(`ggml-common.h:199`)逐字节锁死布局,这样 GGUF 文件的字节流可以被直接 `reinterpret_cast` 成块指针,任何隐式 padding 都会破坏文件与内存的一致性;q4_1/q4_K 等结构体里的 `GGML_EXTENSION union`(`ggml-common.h:203-209`)则是为了让 CUDA 侧能用 `half2` 向量化读取 d/m 这一对标量。

### 2.3 i-quant(重要性量化)概览

iq 系列把"块共享 scale"换成**码本查找**:`iq4_nl` 用 16 个 int8 的非线性码本 `kvalues_iq4nl = {-127,-104,...,113}`(`ggml-common.h:1120-1122`),4-bit 索引→码字,块 18B/32=4.5 bpw,super-block 版 iq4_xs 为 4.25 bpw(`ggml-common.h:454-460`)。iq2/iq1 系列更进一步:qs 字段是预先生成的 256 个/2048 个 8 权重组模式表(`iq1s_grid`,`ggml-common.h:1131-1135`)的索引,即"这一组 8 个权重的符号/分布"是从离线搜索出的最优字典里挑的,配合 imatrix 加权标定,把 bpw 压到 1.5~2.5(`block_iq1_s` 1.5625 bpw,`ggml-common.h:424-430`)。这类格式**强依赖 imatrix**,缺了直接拒绝量化(`src/llama-quant.cpp:1099-1110`、`ggml/src/ggml.c:8021-8027`)。另有与硬件规范对齐的 mxfp4(E8M0 scale + E2M1 码本,`ggml-common.h:214-219,1124-1129`)与 nvfp4。

### 2.4 有效位宽速查表(全部可由 sizeof/256 验证)

| 类型 | 块字节 | 块权重 | bpw | 结构体位置 |
|---|---|---|---|---|
| q4_0 | 18 | 32 | 4.50 | ggml-common.h:195 |
| q4_1 | 20 | 32 | 5.00 | :202 |
| q5_0 | 22 | 32 | 5.50 | :230 |
| q8_0 | 34 | 32 | 8.50 | :251 |
| q2_K | 84 | 256 | 2.625 | :298 |
| q3_K | 110 | 256 | 3.4375 | :315 |
| q4_K | 144 | 256 | 4.50 | :327 |
| q6_K | 210 | 256 | 6.5625 | :362 |
| iq2_xs | 74 | 256 | 2.3125 | :388 |
| iq1_s | 50 | 256 | 1.5625 | :425 |
| iq4_xs | 136 | 256 | 4.25 | :454 |
| mxfp4 | 17 | 32 | 4.25 | :215 |

---

## ③ 量化核的实现要点:整数 dot 路径

### 3.1 参考量化器:quantize_row_q8_0_ref

```c
// ggml-quants.c:276-299(节选)
for (int i = 0; i < nb; i++) {
    float amax = 0.0f;
    for (int j = 0; j < QK8_0; j++)
        amax = MAX(amax, fabsf(x[i*QK8_0 + j]));
    const float d  = amax / ((1 << 7) - 1);   // scale = amax/127
    const float id = d ? 1.0f/d : 0.0f;
    y[i].d = GGML_FP32_TO_FP16(d);
    for (int j = 0; j < QK8_0; ++j)
        y[i].qs[j] = roundf(x[i*QK8_0 + j]*id);
}
```

要点:scale 存 f16(半精度舍入是格式契约的一部分);`roundf` 而非 `(int)` 截断,保证对称误差;`d==0` 时 `id=0` 防全零块除零。q4_0 的 ref 版(`ggml-quants.c:113-148`)结构相同,多一个 nibble 打包。

### 3.2 运行时核:ggml_vec_dot_q4_0_q8_0

推理时 src1(激活)会先经 `from_float = quantize_row_q8_0` 转成 Q8_0(`ggml-cpu/ggml-cpu.c:240-249` 的 traits 表;转换发生在 mul_mat 的 `params->wdata` 工作区,`ggml-cpu/ggml-cpu.c:1323-1358`),于是两个操作数都是整数。标量兜底路径(`ggml-cpu/arch/x86/quants.c:840-854`)最能说明数学本质:

```c
for (; ib < nb; ++ib) {
    int sumi0 = 0, sumi1 = 0;
    for (int j = 0; j < qk/2; ++j) {
        const int v0 = (x[ib].qs[j] & 0x0F) - 8;   // 拆 nibble 并中心化
        const int v1 = (x[ib].qs[j] >>   4) - 8;
        sumi0 += v0 * y[ib].qs[j];                 // int8×int8 → int32
        sumi1 += v1 * y[ib].qs[j + qk/2];
    }
    sumf += (sumi0+sumi1)
          * GGML_CPU_FP16_TO_FP32(x[ib].d) * GGML_CPU_FP16_TO_FP32(y[ib].d);
}
```

三个设计决定:
- **整数只累加到块级**:32 个 |v|≤8 与 |q|≤127 的乘积最大约 0.5M,离 int32 溢出很远;块与块之间用 float 累加,避免大动态范围下的整数扩张,也保住数值精度。
- **中心化移到解码侧**:`-8` 在点积时做而不是量化时做,省一次内存写。
- **AVX2 路径**(`ggml-cpu/arch/x86/quants.c:718-741`):`bytes_from_nibbles_32` 一次拆 32 个 4-bit,`_mm256_sub_epi8` 减 8,`mul_sum_i8_pairs_float` 做 8-bit 乘加水平求和,最后 `_mm256_fmadd_ps(d, q, acc)` 把 `d = x.d*y.d` 融进 FMA——每块只有 2 条浮点指令。

### 3.3 K-quant 核:ggml_vec_dot_q4_K_q8_K

q4_K×q8_K 的 AVX2 路径(`ggml-cpu/arch/x86/quants.c:2038-2115`)展示分层 scale 如何在点积里展开:`_mm256_maddubs_epi16(q4l, q8l)` 做无符号×有符号 8-bit 乘加得 int16,再 `_mm256_madd_epi16(scale_l, p16l)` 把子块 scale(经 shuffle 广播)**在整数域乘进去**,得到 int32。min 校正项不逐元素算,而是用 `block_q8_K.bsums`(每 16 个量化值的和,`ggml-common.h:374`)与解包出的 min 做 `_mm_madd_epi16` 后乘 `dmin = -y.d * x.dmin` 一次算完(`ggml-cpu/arch/x86/quants.c:2066-2084`)——这就是 q8_1/q8_K 里 `bsums`/`s` 字段存在的意义:**把加性偏置的点积降为一次内积 + 一次 16-bit 求和**。

数学上,带 min 的量化 W ≈ d·q − m,则 W·X = d·(q·X) − m·(∑X)。若逐块现算 ∑X,每块要额外扫一遍激活;而激活本身也是按块量化的,q8_1 直接把 `s = d·∑qs` 存进块尾(`ggml-quants.c:320-333`),于是 −m·s 变成两个标量的乘法。bsums 把这个技巧细化到 16 元素粒度,以匹配 q4_K/q5_K 的 32 元素子块(两半各 16)。整条流水里,权重侧完全不动,所有为减少运行期计算而做的冗余(q8_1 的 s、q8_K 的 bsums)都堆在**激活量化**这一侧——激活是推理时新生成的,写入成本一次、读取成本随行数摊销,这个不对称性决定了优化放哪边。

### 3.4 建文件时的 imatrix 加权标定(以 q4_K 为例)

`quantize_row_q4_K_impl`(`ggml-quants.c:1553-1624`)分三步:
1. 子块权重 = imatrix × 激活幅度融合:`weights[l] = qw[l] * sqrtf(sigma2 + x²)`,无 imatrix 时退化为 `av_x + |x|`(`ggml-quants.c:1574-1579`);
2. `make_qkx3_quants`(nstep=36 次网格搜索 + 加权最小二乘闭式解)为每个 32 元素子块找 scale/min(`ggml-quants.c:1583`;搜索框架在 `:993-1075`,同族函数 `make_qkx2_quants` 的闭式解在 `:851-858`);
3. 8 个子块 scale 再经 `make_qp_quants` 量化成 6-bit 并打包进 12 字节(`ggml-quants.c:1586-1598`)。

即:**scale 本身也要量化**,两级 scale 的误差在标定时被联合优化,这是 K-quant 比"朴素 per-block 量化"精度高得多的原因。

---

## ④ llama-quant 的工作流

### 4.1 主流程与双阶段遍历

`llama_model_quantize_impl`(`src/llama-quant.cpp:913`)先做一遍**预备遍历**(`:1077-1112`):对每个张量判 `allows_quantization`(`:1087`)、选定 `target_type`(`:1090`)、判 `requires_imatrix`(`:1095`),缺 imatrix 的低比特类型直接抛错并打出醒目横幅(`:1103-1110`)。然后进入**主循环**(`:1173-1340`),按 slab 处理:`max_buf_size` 默认 8 GiB(`:42,1133`),`bytes_per_row = row_size_src + row_size_dst + n_per_row*sizeof(float)` 推出每次处理的行数(`:1287-1288`),确保"反量化 f32 缓冲 + 量化输出"不超限。多线程是自管理的 `std::thread` + mutex 计数器动态领 chunk(`llama_tensor_quantize_impl`,`:747-816`),每个 chunk 写完立刻 `ggml_validate_row_data` 校验(`:762,799`)。MoE 专家矩阵按 `ne[2]` 拆 imatrix 切片,chunk 不跨专家边界(`:750-759`)。

### 4.2 张量准入与分类

`tensor_allows_quantization`(`src/llama-quant.cpp:287-335`)是一条白名单式过滤:只量化 2D/3D 的 `*weight` 结尾张量,排除 norm、专家路由门控 `ffn_gate_inp`、BERT 位置编码、Mamba conv1d 等小张量。分类用简单字符串匹配归为 13 类(`tensor_get_category`,`:119-154`),注释明确说"不同于 LLM_TN,我们要的是粗类别"(`:25,116`)。**attn_v 系(QKV 融合、kv_b)被单独标记为量化敏感**(`category_is_attn_v`,`:157-161`)——这是全社区多年踩坑的结晶:attention 的 V 投影误差对输出扰动是非对称放大的。

### 4.3 per-layer 混合精度策略

`llama_tensor_get_type_impl`(`src/llama-quant.cpp:428-680`)是量化质量的"菜谱":
- `use_more_bits`:`i_layer < n/8 || i_layer >= 7n/8 || (i_layer - n/8)%3 == 2` 的 FFN 层升一档(`:434-436`)——首尾层敏感、每三层补偿一次,是经验调参;
- output/tied-embd 强制 Q6_K/Q8_0(`:456-477`);
- IQ 低比特文件里 attn_v 视 `n_gqa >= 4` 升到 Q4_K(`:511-515`);
- 70B 模型因 GQA 共享,V 矩阵只有 1/8 大小,"升到 Q5_K 几乎不增加体积"(`:559-564`);
- Mixtral 8-expert 的 attn_v/attn_k 直接 Q8_0,"只多花 ~128MB"(`:565-576`)。

### 4.4 fallback 链

`tensor_type_fallback`(`src/llama-quant.cpp:372-425`)处理 `ncols % block_size != 0`:IQ 系全部退 IQ4_NL(块 32);Q2_K/Q3_K 退 Q4_0;Q4_K→Q5_0→…→若 32 都不整除则保底 F16(`:411-421`)。每次 fallback 计数并告警,结束时汇报 `n_fallback`(`:1355-1358`)。

### 4.5 imatrix 从哪来

`tools/imatrix/imatrix.cpp:234-355` 的 `collect_imatrix` 通过 scheduler 的 eval 回调,拦截所有 `MUL_MAT`(src1 即激活,要求 ≥16 token)与 `MUL_MAT_ID`,把 `x²` 按列累加进 `e.values`,按专家分别计数(`:329-333`)。因此 imatrix 本质是**激活二阶矩 E[x²] 的列和统计**,量化时作为加权最小二乘的权重 w——"误差出现在激活大的通道代价更高"。llama-quant 侧只做消费:校验有限性(`:968-976`)、尺寸匹配 `ne[0]*ne[2]`(`:1247`)、专家切片(`:750-752`)。

---

## ⑤ ggml 张量表示与计算图

### 5.1 ggml_tensor:纯 C 的 POD

```c
// ggml/include/ggml.h:685-717(节选)
struct ggml_tensor {
    enum ggml_type type;
    struct ggml_backend_buffer * buffer;      // 归属的 backend 缓冲
    int64_t ne[GGML_MAX_DIMS];   // 形状,4 维
    size_t  nb[GGML_MAX_DIMS];   // 字节 stride:
                                 //   nb[0] = ggml_type_size(type)
                                 //   nb[1] = nb[0]*(ne[0]/blck_size) + padding
                                 //   nb[i] = nb[i-1]*ne[i-1]
    enum ggml_op op;
    int32_t op_params[GGML_MAX_OP_PARAMS / sizeof(int32_t)]; // 64B 算子参数
    int32_t flags;
    struct ggml_tensor * src[GGML_MAX_SRC];   // 10 个前驱
    struct ggml_tensor * view_src;  size_t view_offs;  // 视图
    void * data;
    char name[GGML_MAX_NAME];
    void * extra;                              // 后端私有(CUDA tensor slice 等)
};
```

单结构 368 字节左右,既是**张量**(ne/nb/data)也是**计算图节点**(op/src)。strides 用"块"语义:量化张量的 `nb[0]` 是整个块的字节数,行大小 `ggml_row_size = type_size*ne/blck_size`(`ggml/src/ggml.c:1339-1344`)。`ggml_nbytes` 对块型张量走 `ne[0]*nb[0]/blck_size + (ne[i]-1)*nb[i]`(`ggml.c:1298-1321`),天然支持任意 stride 的视图/转置,量化格式与视图机制互不干扰。op 分派是巨大的 switch(`ggml.c` 附近 `GGML_OP_MUL_MAT` → `ggml_compute_forward_mul_mat`,CPU 侧分派在 `ggml-cpu/ggml-cpu.c:1861-1868`),无虚函数、无 RTTI。

### 5.2 内存池:bump allocator

```c
// ggml/src/ggml.c:1708-1748(节选)
static struct ggml_object * ggml_new_object(struct ggml_context * ctx,
        enum ggml_object_type type, size_t size) {
    const size_t cur_end  = cur_offs + cur_size;      // 池顶
    size_t size_needed = GGML_PAD(size, GGML_MEM_ALIGN);
    struct ggml_object * const obj_new =
        (struct ggml_object *)(mem_buffer + cur_end); // 对象头就地写在池顶
    ...
}
```

`ggml_context` 就是一块 `mem_buffer` + 对象链表(`ggml.c:975-985`);每个对象头部 `ggml_object`(offs/size/next/type,`ggml.c:958-967`)串成单链,分配只是**指针上移**,永不释放单个对象——张量数据紧跟在 `ggml_tensor` 头之后内联分配:`data = (void*)(result + 1)`(`ggml.c:1804-1820`)。`no_alloc` 模式只建元数据、数据由 backend buffer 接管(`ggml.c:1797-1800`),这正是 llama.cpp 模型权重与 KV cache 的分配路径。计算图本体也是一个 object:`ggml_graph_nbytes` 按 size 摊派 nodes/leafs/hash 空间(`ggml.c:7423-7442`)。

### 5.3 计算图:懒构建 + 后序拓扑

图构建即"从结果张量递归走 src":`ggml_visit_parents_graph`(`ggml.c:7208-7274`)用开放寻址 hash set(以指针作 key,低 4 位对齐保证为 0,`ggml-impl.h:266-269`)判重,首次访问的 `GGML_OP_NONE` 无参张量进 leafs,其余按后序进 nodes,同时累计 `use_counts`(供后端做节点融合判断,`ggml-impl.h:641-653,711`)。图是**增量**的:`ggml_build_forward_expand` 可反复向同一图追加子树(`ggml.c:7309-7311`),llama.cpp 的 build_graph 每层只 append 不重建。图还带 `uid` 用于跨 step 识别同构图(`ggml-impl.h:356-358`),调度器据此复用分配计划。

所谓"懒构建",是指 ggml 没有独立的前端/IR/编译期:每个推理 step,上层(llama 的 build_graph)用 `ggml_*` 构造函数直接在 context 池里"边造张量边连边",图的拓扑就是构造顺序的隐式产物——张量创建时不会分配数据(`no_alloc`),也不会立即执行,直到后端调度器拿走整张图。与之配套的是 `GGML_TENSOR_FLAG_COMPUTE`:visit 时打上该标记的张量才参与计算(`ggml.c:7209-7211,7237-7227`),配合 `ggml_build_forward_select`(`ggml.c:7295-7307`)可以在同一张图里构造多个候选分支而只算被选中的那个,这是 speculative decoding 等机制的底层支撑。整张图连同 nodes/leafs/hash 表都嵌在同一个 object 里(`ggml.c:7423-7442`),一次 `memcpy` 级别的代价即可随 context 销毁回收。

---

## ⑥ backend 调度与 CPU 线程池

### 6.1 sched:multi-backend 切图

`ggml_backend_sched`(`ggml-backend.cpp:786-841`)持有按优先级排序的 backend 数组(下标小者优先,CPU 恒为最后一个)与共享的 `gallocr`。`ggml_backend_sched_split_graph`(`:1066`)分四步:

1. **pass 1**(`:1087-1122`):预分配张量(权重/输入)按其 buffer 归属定后端。核心规则在 `ggml_backend_sched_backend_id_from_cur`(`:921-985`):**带权重的算子优先跑在权重所在后端**(遍历 src 找 `BUFFER_USAGE_WEIGHTS`,`:962-982`),`op_offload` 允许更高优先级的 GPU 把 CPU 上的算子抢走;ROPE/FLASH_ATTN 的小辅助张量被显式豁免(`:955-959`)。
2. **pass 2**(`:1124-1202`):对未定节点做"expand down/up"四次线性扫描,把已定后端向邻域传播,GPU 后端向上向下扩、CPU 作为最低优先级只在权重确实在 CPU 时使用(`:1126-1128` 的注释)。
3. **pass 3**(`:1204-1240`):把能跑更高优先级后端的节点升级(同 buffer type 才升,保守但正确)。
4. 之后在"后端切换点"把图切成 `splits`,split 之间插入拷贝张量,并用 events 支持相邻 split 的流水线并行(`:815-819`)。

**权重 placement** 的最终含义:模型加载时每个权重被放入某个 `ggml_backend_buffer`,sched 保证消费它的算子要么同后端、要么生成一次显式拷贝——用户看到的 `--n-gpu-layers` 就是"哪些权重放进 GPU buffer"的粗粒度版本。

### 6.2 CPU 线程池

```c
// ggml/src/ggml-cpu/ggml-cpu.c:481-505(节选)
struct ggml_threadpool {
    ggml_mutex_t mutex;  ggml_cond_t cond;
    struct ggml_cgraph * cgraph;  struct ggml_cplan * cplan;
    atomic_int n_graph;                    // 低 16 位打包参与线程数(:206-207)
    atomic_int GGML_CACHE_ALIGN n_barrier, n_barrier_passed;
    atomic_int GGML_CACHE_ALIGN current_chunk;  // mul_mat 动态分块游标
    atomic_bool stop, pause;  atomic_int abort;
    struct ggml_compute_state * workers;  int n_threads;
    int32_t prio;  uint32_t poll;          // 线程优先级/自旋轮数
};
```

- **每线程全图遍历**:主循环里每个 worker 都从头走 `cgraph->nodes`(`ggml_graph_compute_thread`,`:3101-3174`),先尝试算子融合 `ggml_cpu_try_fuse_ops`(`:3143`),然后 `ggml_compute_forward`,**每个节点后 barrier**(`:3156-3158`)——节点内并行、节点间串行,依赖关系不需要显式 DAG 调度。
- **静态分派 + 动态窃取**:`ggml_get_n_tasks`(`:2245-2361`)按算子给并发度(逐元素算子给 n_threads,SUM/ARGMAX 等给 1);mul_mat 内部把输出切成 chunk,线程从 `current_chunk` 原子变量自增领取(`:1432-1459`),chunk 数不足 `nth*4` 或 NUMA 时改为按线程整分(`:1404-1425`)。
- **自旋 + 条件变量混合等待**:空转 `128K × poll` 轮 `pause` 指令后转 `cond_wait`(`:3208-3226`),poll 级别可调,以换取图间低延迟。
- **work buffer 一次性规划**:`ggml_graph_plan` 遍历全图求 `work_size` 最大值(`:2829-3056`),mul_mat 把 src1 按 `vec_dot_type` 量化进 `wdata`(`:1323-1358`)——激活量化的内存成本在 plan 期已知,推理期零动态分配。

---

## ⑦ 设计动机与取舍:为何自研 ggml

ggml 的自我定位写在头文件开头:"provide a **minimalistic** approach for various machine learning tasks…computation graph…value and/or gradient"(`ggml/include/ggml.h:19-30`)。结合代码可见的取舍:

- **零依赖与可移植性优先**:`ggml-common.h` 用纯 C 结构体 + static_assert 把量化契约钉进类型系统,同一份头被 CUDA/Metal/SYCL/CPU 等十几个后端 include(`ggml-common.h:60-72`);CPU 后端甚至自带线程池、NUMA、自旋锁(`ggml-cpu.c:481-575`),不依赖任何运行时。PyTorch/ONNX Runtime 的图优化、设备抽象都要求庞大的依赖树,这与"单文件可分发、Windows/Mac/树莓派/手机开箱即用"的目标冲突。
- **格式即内存布局**:量化数据不经过任何容器,块结构体直接 mmap 进地址空间(law:`ggml_nbytes` 与文件偏移一致),省掉加载期的转换。PyTorch 的 tensor 必须先实例化再搬运,对"比内存更大的模型"(mmap 部分 page out)无法支持。
- **量化是一等公民**:PyTorch 的量化原语面向训练/推理框架,而 llama.cpp 需要 2.31 bpw 这种极端格式 + per-tensor 混合精度 + 自定义 dot 核,sched 的 `ggml_backend_supports_op` 按 op×dtype 逐个协商(`ggml-backend.cpp:895-899`),自研才能让新格式从文件格式到 CUDA kernel 一条链贯通。
- **推断专用,图可牺牲通用性**:图是每次 forward 重建的平坦数组、无自动微调优、无形状符号推理;换来的是构建开销接近零、uid 判同图后分配计划可复用(`ggml-impl.h:356-358`)。训练需要的东西(backward、optimizer)以可选模块存在(`ggml_build_backward_expand`,`ggml.c:7317`)而非核心。
- **代价也很明显**:张量结构硬编码 4 维/10 src(`ggml.h:222-226`);per-layer 量化菜谱是几百行 if-else 的经验规则(`llama-quant.cpp:428-680`),可维护性靠测试保障;CPU 图执行"每线程全遍历 + barrier"在节点粒度细时会放大同步开销——这些都是用领域约束换简单性的自觉选择。

---

## ⑧ FAQ

**Q1:为什么 q4_0 是 4.5 bpw 而不是 4.0?**
每 32 权重多存一个 f16 scale(2 字节),18B×8/32=4.5。scale 是 per-block 的代价,换 K-quant 的分层 scale 可摊薄到 4.25(iq4_xs)但仍不是整数。

**Q2:Q4_K_M 里的 "M" 是什么?**
ftype 层的混合策略标签(S/M/M/L),同一 ftype 下不同张量用不同 ggml_type,规则在 `llama_tensor_get_type_impl`(`src/llama-quant.cpp:428-680`),如 Q4_K_M 的 ffn_down 敏感层升 Q6_K(`:612-618`)。

**Q3:推理时激活也要量化吗?用什么格式?**
是。mul_mat 把 f32 的 src1 按 src0 的 `vec_dot_type` 现场量化进 work buffer:q4_0 配 q8_0、q4_1 配 q8_1(带 sum)、K-quant 配 q8_K(带 bsums),映射表在 traits(`ggml-cpu/ggml-cpu.c:215-259`)。

**Q4:为什么点积块内用整数、块间用浮点累加?**
块内 32 个 8-bit 乘积的 int32 累加无溢出风险且能吃上整数 SIMD 吞吐;块间若继续整数累加会要求更宽类型并破坏 scale 独立性,float FMA 每块一次即可。

**Q5:imatrix 是权重的重要性还是激活的?**
是激活的列二阶矩(∑x²,`tools/imatrix/imatrix.cpp:329-333`),量化时作为加权最小二乘的 w。名字里 "matrix" 指其形状与权重列对齐。

**Q6:哪些量化必须给 imatrix?**
IQ1_S/IQ2_XXS/IQ2_XS/IQ2_S/IQ1_M/IQ3_XXS 以及 Q2_K_S 文件中的 Q2_K(`src/llama-quant.cpp:822-841`);缺失时工具直接报错退出(`:1099-1110`)。

**Q7:张量列数不整除 256 会怎样?**
走 fallback 链降块长:IQ 系→IQ4_NL,Q2_K/Q3_K→Q4_0,Q4_K→Q5_0…最后兜底 F16(`src/llama-quant.cpp:372-425`)。

**Q8:ggml 如何避免内存分配成为瓶颈?**
三层:context 池是 bump allocator(`ggml.c:1708-1764`);计算图缓冲由 gallocr 按 measure-then-alloc 规划(`ggml-alloc.c:121-312`);CPU 运行期唯一的工作区 `wdata` 在 plan 期定死大小(`ggml-cpu.c:2829-3056`)。

**Q9:CPU 多线程为何每节点 barrier,而 mul_mat 内又动态窃取?**
节点间 barrier 保证依赖与 work buffer 复用安全;节点内 mul_mat 矩阵大、行耗时方差大,`current_chunk` 原子窃取(`ggml-cpu.c:1432-1459`)缓解长尾。

**Q10:GGUF 里的 QNT_VERSION 有何用?**
当前为 2(`ggml/include/ggml.h:219`),量化工具写进 KV(`src/llama-quant.cpp:991`),加载器据此判断格式代际兼容性;块布局变更必须 bump。

---

## ⑨ 深挖问题

1. **q8_K 的 bsums 用 int16 存 16 个 int8 之和**,理论上 16×127=2032 不会溢出,但 q8_K 的 `d` 是 f32 而非 f16(`ggml-common.h:370-375`),与 q8_0 的 f16 scale 不一致——scale 精度在激活侧是否可观测?对低比特 IQ 格式的 WER 影响值得做消融。
2. **`make_qkx3_quants` 的网格搜索**(rmin=-0.9, rdelta=0.05, nstep=36,`ggml-quants.c:1583`)是 O(nstep×n) 每子块,全模型量化耗时主要在此;搜索步长与最终 perplexity 的 Pareto 边界没有理论刻画,是否存在可学习的标定(替代网格)是开放问题。
3. **sched 的 pass 2"四次线性扫描"是 O(4n) 启发式**,遇 op 支持度交错的图(如部分算子只有 CPU 实现)可能产生比必要更多的 split 与拷贝(`ggml-backend.cpp:1124-1240`);split 边界与 KV cache 状态张量的交互(每 token 重入图)是否造成隐性拷贝,需要用 `--no-op-offload`/debug 日志实测。
4. **CPU 图执行的 barrier 语义**:每节点全线程 barrier(`ggml-cpu.c:3156-3158`)在 64+ 核与小型逐元素算子密集的图(如 MoE routing)下,同步开销可能超过计算;`ggml_get_n_tasks` 给部分算子 n_tasks=1(`:2279`)只是缓解,值得测量 barrier 次数/图。
5. **imatrix 统计与量化吞吐的矛盾**:MUL_MAT_ID 的统计要按专家拆分累加(`imatrix.cpp:270-341`),意味着 MoE 模型的 imatrix 采集开销远高于稠密模型;`n_out_freq` 定期落盘(`:343-354`)只是容错,采集 token 数与最终 bpw-质量曲线(官方建议几百 chunk)缺乏自适应机制。

---

*报告完。核心代码引用均可在本卷快照仓库中按行号复核。*
