# Y 章 · FFmpeg 加密栈：从 AES 原语到容器级 CENC

> 调研基线：master 分支 commit 9f63b36a。所有行号均以该快照 `grep -n` / Read 实际核对。
> 本文是 09 章（HLS）的延伸：把"AES-128 分片下沉给 crypto 协议"这一层与包级 SAMPLE-AES、容器级 CENC 一次讲透。

---

## 1. 全景：加密的四个层次

FFmpeg 的加密能力不是一座"DRM 大厦"，而是四层彼此独立的积木。自底向上：

```
┌─────────────────────────────────────────────────────────────────────┐
│ L4 容器级 CENC（MP4/fMP4）                                          │
│   demux: mov.c 解析 schm/tenc/senc/saiz/saio/pssh                  │
│          → 就地解密 或 挂 AV_PKT_DATA_ENCRYPTION_INFO side data     │
│   mux : movenc.c + movenccenc.c 写出 senc/saiz/saio/sinf(tenc)     │
├─────────────────────────────────────────────────────────────────────┤
│ L3 包级 SAMPLE-AES（HLS TS/fMP4 专有）                              │
│   hls.c 识别 METHOD=SAMPLE-AES → hls_sample_encryption.c           │
│   对已解析出的 AVPacket 逐 NALU/逐音频帧部分解密（1:9 模式）          │
├─────────────────────────────────────────────────────────────────────┤
│ L2 流式协议 crypto:（URLProtocol）                                  │
│   crypto.c 整段字节流的 AES-128-CBC 解密/加密 + PKCS7               │
│   HLS 的 KEY_AES_128 分片在此"下沉"解密（09 章下游）                 │
├─────────────────────────────────────────────────────────────────────┤
│ L1 AES 原语（libavutil）                                            │
│   aes.c: 单块加密机 + CBC/ECB 组合（av_aes_crypt）                  │
│   aes_ctr.c: CTR 计数器模式封装（av_aes_ctr_*）                     │
└─────────────────────────────────────────────────────────────────────┘
```

四层的分工与"知识边界"差异极大，这也是理解整个栈的钥匙：

- **L1 不懂任何格式**。`av_aes_crypt` 只见 16 字节块（libavutil/aes.h:63）。
- **L2 只懂字节流**。crypto: 对上层容器一无所知，对下层的 http:/file: 也只通过嵌套 URLProtocol 交流（libavformat/crypto.c:146）。
- **L3 懂编码格式**。SAMPLE-AES 必须能找 H.264 NALU 边界、ADTS/AC3 音频帧头（libavformat/hls_sample_encryption.c:175,271,301）。
- **L4 懂容器格式**。CENC 的密钥、IV、subsample 元数据全部记录在 MP4 盒子里，与媒体数据同生命周期（libavformat/mov.c:10078-10084）。

**FFmpeg 的定位：解密为主，加密写出为辅。** demux 侧四种 scheme（cenc/cbc1/cens/cbcs）全都能解（libavformat/mov.c:8883-8897）；mux 侧只支持 `cenc-aes-ctr` 一种（libavformat/movenc.c:8469-8486）。密钥管理（KMS、DRM license）完全不在树内——key 一律由调用者通过 AVOption 传入。另外两个容易误判的点：

- 树中**有** RTMPE 实现：libavformat/rtmpproto.c（握手入口 `rtmp_handshake`，libavformat/rtmpproto.c:1264，加密连接分支 1294-1310），Makefile 注册见 libavformat/Makefile:710。
- 树中**有** SRTP 实现：libavformat/srtp.c（用 av_aes_crypt 做 AES-CTR keystream，libavformat/srtp.c:42-63；HMAC-SHA1 完整性 libavformat/srtp.c:93-95），注册 libavformat/Makefile:718。
- TLS 相反：树内只有绑定层 tls.o，实际密码学全部外包给 OpenSSL/mbedTLS/GnuTLS 等外部库（libavformat/Makefile:724-731）。自带 AES 的动机是给上述**媒体加密基础设施**供货，而不是做 TLS。

---

## 2. crypto: 协议专节

### 2.1 URLProtocol 包装

crypto.c 是一个标准 URLProtocol，名字 "crypto"，带 `URL_PROTOCOL_FLAG_NESTED_SCHEME`——即 `crypto:后面的部分` 会被当作新的 URL 递归打开（libavformat/crypto.c:392-402，前缀解析 crypto.c:120-125 同时接受 `crypto+`）：

```c
// libavformat/crypto.c:392-402
const URLProtocol ff_crypto_protocol = {
    .name            = "crypto",
    .url_open2       = crypto_open2,
    .url_seek        = crypto_seek,
    .url_read        = crypto_read,
    .url_write       = crypto_write,
    .url_close       = crypto_close,
    .priv_data_size  = sizeof(CryptoContext),
    .priv_data_class = &crypto_class,
    .flags           = URL_PROTOCOL_FLAG_NESTED_SCHEME,
};
```

选项有两组语义重叠的名字（libavformat/crypto.c:69-77）：通用的 `key`/`iv`（读写皆可），以及方向明确的 `decryption_key/decryption_iv`（仅读）与 `encryption_key/encryption_iv`（仅写）。`set_aes_arg` 强制密钥与 IV 必须恰好 16 字节（BLOCKSIZE），否则 EINVAL（libavformat/crypto.c:104-109）——这从协议层就锁死了 AES-128。

打开时按读写方向选好密钥后，为嵌套 URL `ffurl_open_whitelist`（libavformat/crypto.c:146-151），再 `av_aes_init(..., BLOCKSIZE*8, 1/0)` 初始化 128 位 AES 解密/加密上下文（libavformat/crypto.c:159,174）。写模式强制 `is_streamed=1`：AES-128-CBC 只能线性写（libavformat/crypto.c:177-179）。

### 2.2 HLS → crypto: 的完整参数流

09 章 hls.c:1528-1544 的"下沉"在这里补全全链路：

1. **播放列表解析**：`#EXT-X-KEY:` 行（libavformat/hls.c:917），`METHOD=AES-128` → `KEY_AES_128`（libavformat/hls.c:923），`IV=0x…` 十六进制转字节（libavformat/hls.c:927-929）。未写 IV= 时，用**媒体序号**垫底：`AV_WB64(seg->iv + 8, seq)`，即 IV 前 8 字节为 0、后 8 字节为 media sequence number（libavformat/hls.c:1070-1076）。
2. **取 key**：分片切换且 key URI 变化时 `read_key` 打开 URI 读**恰好 16 字节**进 `pls->key`（libavformat/hls.c:1436-1464，调用点 1520-1526）。
3. **拼 URL + 传参**（09 章引用处）：

```c
// libavformat/hls.c:1528-1540
if (seg->key_type == KEY_AES_128) {
    char iv[33], key[33], url[MAX_URL_SIZE];
    ff_data_to_hex(iv, seg->iv, sizeof(seg->iv), 0);
    ff_data_to_hex(key, pls->key, sizeof(pls->key), 0);
    if (strstr(seg->url, "://"))
        snprintf(url, sizeof(url), "crypto+%s", seg->url);   // :1533
    else
        snprintf(url, sizeof(url), "crypto:%s", seg->url);   // :1535
    av_dict_set(&opts, "key", key, 0);                       // :1537
    av_dict_set(&opts, "iv", iv, 0);                         // :1538
    ret = open_url(pls->parent, in, url, &c->avio_opts, opts, &is_http);
```

key/IV 以 **hex 字符串**走 AVDictionary 进 crypto 协议的 binary 选项；每个分片一个全新 crypto: URL，所以"换 key""换 IV"天然按分片粒度生效——这正是它不做 key 管理也能支持 HLS 轮换的原因。

### 2.3 CBC 流式解密与 seek 重置

`crypto_read` 的核心难点是 CBC 的**块边界 + PKCS7 尾块**：

```c
// libavformat/crypto.c:203-218（节选）
while (c->indata - c->indata_used < 2*BLOCKSIZE) {   // 至少攒 2 块
    int n = ffurl_read(c->hd, c->inbuffer + c->indata, ...);
    ...
}
blocks = (c->indata - c->indata_used) / BLOCKSIZE;
if (!c->eof)
    blocks--;                       // 保留最后一块，等 EOF 判定
av_aes_crypt(c->aes_decrypt, c->outbuffer, c->inbuffer + c->indata_used,
             blocks, c->decrypt_iv, 1);
```

- 未到 EOF 时永远扣住最后一块不解密（libavformat/crypto.c:199-216），因为它可能含 PKCS7 padding；EOF 后按尾字节值剥 padding（libavformat/crypto.c:228-232）。
- `av_aes_crypt` 的 IV 是**就地推进**的：解密侧每块后 `memcpy(iv, src, 16)`（libavutil/aes.c:163），所以 `c->decrypt_iv` 始终等于"下一块的 CBC 链值"——这是 seek 正确性的前提。

`crypto_seek`（libavformat/crypto.c:236-328）不能只 seek 底层协议——CBC 链断了。做法：

- 清空输入输出缓冲（libavformat/crypto.c:275-278）；
- 目标偏移落在第 0 块 → 直接把种子 IV 从 `c->iv` 拷回 `c->decrypt_iv`（libavformat/crypto.c:283-286）；
- 落在第 N 块 → 底层 seek 到 **N-1 块**，然后用"丢弃式读"把上一块解密一遍，让 `av_aes_crypt` 顺手把 IV 推进到正确链值，解密结果被丢弃（libavformat/crypto.c:287-294、305-325）。

> 细节 quirk：恢复种子 IV 用的是通用选项 `c->iv`（crypto.c:285）。如果调用者只传了 `decryption_iv` 而没传 `iv`，`c->ivlen == 0`，这次 memcpy 是空操作，seek 回 0 块会带着旧链值解错。HLS 路径传的是通用 `iv`，不受影响。

写侧对称：`crypto_write` 把不满 16 字节的尾巴攒在 `c->pad`（libavformat/crypto.c:336-366），`crypto_close` 补齐 PKCS7 padding 写出最后一块（libavformat/crypto.c:376-383）。

---

## 3. SAMPLE-AES 专节（包级解密）

### 3.1 与 crypto: 的分工

SAMPLE-AES 是 Apple 的私有方案：**同一分片内明文与密文交织**（NALU 头明文、按 1:9 模式部分加密），字节流级的 crypto: 完全无能为力——解密必须知道"哪里是 NALU/音频帧"。因此它不在 I/O 层做，而在 HLS demuxer 拿到 AVPacket **之后**做。

hls.c 的分流逻辑：TS 分片在本地解（分配 HLSCryptoContext，libavformat/hls.c:2531-2539），fMP4（mov）分片则把 key 以 `decryption_key` 选项**透传给 mov demuxer**，走第 4 节的 CENC 通道（libavformat/hls.c:2526-2530）：

```c
// libavformat/hls.c:2526-2531
if (seg && seg->key_type == KEY_SAMPLE_AES) {
    if (strstr(in_fmt->name, "mov")) {
        char key[33];
        ff_data_to_hex(key, pls->key, sizeof(pls->key), 0);
        av_dict_set(&options, "decryption_key", key, 0);   // 交给 mov.c
    } else if (!c->crypto_ctx.aes_ctx) {
        c->crypto_ctx.aes_ctx = av_aes_alloc();            // TS 本地解
```

TS 路径的每包触发点：`ff_hls_senc_decrypt_frame(codec_id, &c->crypto_ctx, pls->pkt)`，IV/key 每包从当前分片与 pls->key 拷入（libavformat/hls.c:2807-2811）。`METHOD=SAMPLE-AES` 的识别在 libavformat/hls.c:917-925（枚举 libavformat/hls.c:72-74）。

### 3.2 视频路径：H.264 逐 NALU 的 1:9 模式

`decrypt_video_frame`（libavformat/hls_sample_encryption.c:235-269）扫描 Annex B 起始码切 NALU（`get_next_nal_unit`，175-201），只解 **type 1（非 IDR slice）/ 5（IDR）且长度 > 48** 的 NALU（libavformat/hls_sample_encryption.c:254）。

```c
// libavformat/hls_sample_encryption.c:210-230（节选）
ret = av_aes_init(crypto_ctx->aes_ctx, crypto_ctx->key, 16 * 8, 1);
remove_scep_3_bytes(nalu);            // 去防竞争字节 0x03（:155-173）
data = nalu.data + 32;                // 前 32 字节明文
memcpy(iv, crypto_ctx->iv, 16);       // 每个 NALU 重置 IV
while (rem_bytes > 0) {
    if (rem_bytes > 16) {
        av_aes_crypt(..., data, data, 1, iv, 1);   // 解密 16 字节
        data += 16; rem_bytes -= 16;
    }
    data += FFMIN(144, rem_bytes);    // 跳过 144 字节明文
    rem_bytes -= FFMIN(144, rem_bytes);
}
```

三个结构性事实：每 NALU 重新 `av_aes_init`（210）、每 NALU 从分片 IV 重新起步（220）、前 32 字节恒明文（217-218）——所谓 SAMPLE-AES 的"16 加密 : 144 明文"模式。去 SCEP 后 NALU 变短，用 memmove 压实并 `av_shrink_packet` 收尾（libavformat/hls_sample_encryption.c:259-266）。

### 3.3 音频路径：AAC/AC3/EAC3 整帧后半解密

音频没有 subsample 表，规则是**帧头 + 前 16 字节明文，其余全解**（libavformat/hls_sample_encryption.c:353-357），且仅当负载 > 31 字节才动手（libavformat/hls_sample_encryption.c:384）。AAC 走 ADTS 同步字（271-299），AC3/EAC3 走 0x0B77 同步字（301-331）。加密音频流的参数（zaac/zac3/zec3 fourcc + dec3 配置）来自 ID3 tag 里的 audio setup info，解析在同文件（libavformat/hls_sample_encryption.c:61-92、94-150；hls.c 消费点 2453-2495、2573）。

总入口分发只认 H264/AAC/AC3/EAC3，其余返回 AVERROR_INVALIDDATA（libavformat/hls_sample_encryption.c:395-403）。注意：**这个文件实现的是 Apple TS 方案，与 cbcs 无关**；fMP4 SAMPLE-AES 的 cbcs/cenc 处理在 mov.c（下一节）。

---

## 4. CENC 专节：MP4 容器的 Common Encryption

### 4.1 mux 侧：movenc 写出加密盒子的行号链

**配置与初始化：**

- 选项 `encryption_key` / `encryption_kid` / `encryption_scheme`（libavformat/movenc.c:81-83）；
- 只认 `cenc-aes-ctr`，key 必须 16 字节、KID 必须 16 字节（libavformat/movenc.c:8469-8487）；
- 每轨 `ff_mov_cenc_init`，且 H264/HEVC/VVC/AV1 启用 subsample（libavformat/movenc.c:8713-8718）；内部 `av_aes_ctr_init` + 非 bitexact 时随机 IV（libavformat/movenccenc.c:600-631）。

**每帧（写 packet）：** `mov_cenc_start_packet` 先把当前 8 字节 IV 写进辅助信息（libavformat/movenccenc.c:115-138，写 IV 在 :120）；正文经 `mov_cenc_write_encrypted` 用 CTR 异步加密 4KB 分块写出（libavformat/movenccenc.c:95-110）；`mov_cenc_end_packet` **IV 顺序 +1** 进入下一帧（libavformat/movenccenc.c:147，递增实现 libavutil/aes_ctr.c:95-100）。视频轨不整体加密，而是保护 NALU：

```c
// libavformat/movenccenc.c:258-276（ff_mov_cenc_avc_write_nal_units 节选）
avio_write(pb, buf_in, nal_length_size + 1);       // NAL 长度+类型 明文
...
mov_cenc_write_encrypted(ctx, pb, buf_in + 1, nalsize - 1);  // NAL 体加密
auxiliary_info_add_subsample(ctx, nal_length_size + 1, nalsize - 1);
```

subsample 条目是固定 6 字节：2 字节明文长 + 4 字节密文长（libavformat/movenccenc.c:64-90）。AV1 特殊：经 CBS 解析 OBU，帧头明文、tile group 密文（libavformat/movenccenc.c:287-482，解码头类型表 592-598）。各编码的写包分派在 libavformat/movenc.c:7282-7305。

**盒子布局（每 moof 或 moov）：** `ff_mov_cenc_write_stbl_atoms` 依次写三个盒子（libavformat/movenccenc.c:542-550）：

| 盒子 | 函数 | 行号 | 关键内容 |
|---|---|---|---|
| senc | mov_cenc_write_senc_tag | movenccenc.c:495-507 | 带 subsample 时 version/flags=0x02，逐帧 IV+subsample 表 |
| saio | mov_cenc_write_saio_tag | movenccenc.c:509-526 | 辅助信息相对 moof 的偏移（>4GB 自动升 v1） |
| saiz | mov_cenc_write_saiz_tag | movenccenc.c:528-540 | 每帧辅助信息长度（无 subsample 时 default=8） |

非分片 MP4 写进 moov 的 stbl（libavformat/movenc.c:3465-3466），fMP4 写进每个 moof 的 traf（libavformat/movenc.c:5937-5938），分片间 `ff_mov_cenc_flush` 清空辅助信息（libavformat/movenc.c:6888-6889，实现 movenccenc.c:633-637）。样本条目侧包一层 `sinf`：frma 保存原 fourcc、schm 声明 scheme="cenc"/版本 0x10000、schi 内 tenc v0（isEncrypted=1、IV 大小 8、KID）（libavformat/movenccenc.c:552-590；调用点 libavformat/movenc.c:1579、3077）。

**cbcs vs cenc 的差异在此可见一斑：** FFmpeg mux 侧根本没有 cbcs 写出——tenc 恒 v0、无 pattern 字节、IV 恒 8 字节顺序递增（movenccenc.c:558-563,147）。cbcs 只是 demux 侧能解。

### 4.2 demux 侧：mov.c 的 senc/saiz/saio

原子分派表注册了整套加密盒子（libavformat/mov.c:10078-10084：senc/saiz/saio/pssh/tenc；schm 在 :8429）。信息流分两路：`tenc`+`schm` 给出**默认加密参数**（scheme、pattern、KID、per-sample IV 大小、常量 IV——libavformat/mov.c:8460-8535，pattern 高低 nibble 拆成 crypt/skip_byte_block 仅 tenc v>0，:8489-8492）；`senc` 或 `saiz`+`saio` 给出**每帧 IV/subsample**。saio 只存偏移，`mov_parse_auxiliary_info` 自己 seek 过去按 saiz 的长度表逐帧解析（libavformat/mov.c:8067-8127，seek 失败降级仅用 senc，:8087-8089）；senc 与 saiz/saio 双路并存时后者被忽略去重（libavformat/mov.c:8023-8025、8140-8144）。每帧解析在 `mov_read_sample_encryption_info`：克隆默认项、读 per-sample IV（8/16 字节）、读 subsample 对（libavformat/mov.c:7957-8009）。fragment 与流级两套索引由 `get_current_encryption_info` 归一（libavformat/mov.c:7906-7955）。

**真正解密发生在每包出口** `cenc_filter`（libavformat/mov.c:8917-8990，调用点 mov_read_packet 内 libavformat/mov.c:12232）：按帧号对齐加密索引，没给 key 就挂 side data；给了 key 就按 scheme 分派就地解密：

```c
// libavformat/mov.c:8883-8897 cenc_decrypt
if (sample->scheme == MKBETAG('c','e','n','c') && !sample->crypt_byte_block && !sample->skip_byte_block)
    return cenc_scheme_decrypt(...);   // AES-CTR，整样本
else if (sample->scheme == MKBETAG('c','b','c','1') && !... )
    return cbc1_scheme_decrypt(...);   // AES-CBC，样本内链式
else if (sample->scheme == MKBETAG('c','e','n','s'))
    return cens_scheme_decrypt(...);   // CTR + pattern
else if (sample->scheme == MKBETAG('c','b','c','s'))
    return cbcs_scheme_decrypt(...);   // CBC + pattern
```

四种实现（libavformat/mov.c:8608-8877）的差异集中在两点：

- **IV 语义**：cenc/cens 每样本设完整 IV（:8631）；cbc1 每样本起点设 IV 后 subsample 间链式传递（:8688 起）；**cbcs 每个 subsample 都重置为样本 IV**（`memcpy(iv, sample->iv, 16)`，libavformat/mov.c:8847）——即常量 IV 语义。
- **pattern 循环**：cens/cbcs 按 `16*crypt_byte_block 加密、16*skip_byte_block 跳过` 交替（libavformat/mov.c:8786-8793、8850-8857），且 cbc1/cenc 强制 pattern 为 0、cbcs/cens 强制 pattern 非零（libavformat/mov.c:8880-8886）。

key 查找支持**按 KID 多 key**：`decryption_keys` 字典以 KID hex 为键，`decryption_key` 作默认兜底（libavformat/mov.c:8568-8606，选项注册 :12496-12497）。FATE 用例直接演示了用法：tests/fate/mov.mak:63、66、69（`-decryption_key 12345678901234567890123456789012`）。

### 4.3 pssh：只有 demux 侧的"系统头"

`mov_read_pssh`（libavformat/mov.c:8308-8420）把 system id、KID 列表、data 解析成 `AVEncryptionInitInfo` 挂到 `AV_PKT_DATA_ENCRYPTION_INIT_INFO` side data（libavformat/mov.c:8394、8420）。mux 侧不写 pssh——DRM 头生成同样被划在 FFmpeg 边界之外。

---

## 5. AV_PKT_DATA_ENCRYPTION_INFO：语义与消费方

```c
// libavcodec/packet.h:250-253
/**
 * This side data contains encryption info for how to decrypt the packet.
 * The format is not part of ABI, use av_encryption_info_* methods to access.
 */
AV_PKT_DATA_ENCRYPTION_INFO,
```

语义：当 demuxer **没有** key 时，CENC 元数据不丢，而是随包下发，让上层（播放器、DRM 模块）自行解密。序列化格式非 ABI，必须经 libavutil/encryption_info 的访问器读写：`av_encryption_info_get_side_data` / `av_encryption_info_add_side_data`（libavutil/encryption_info.h:157-167）。载荷结构 `AVEncryptionInfo` 恰好一一对应 tenc/senc 字段：scheme、crypt_byte_block/skip_byte_block（pattern）、key_id[16]、iv、subsample 数组（libavutil/encryption_info.h:44-79）——mov.c 就是 `av_encryption_info_add_side_data(encrypted_sample, &size)` 一行挂包（libavformat/mov.c:8973-8979）。

**消费方现状**：全树 grep，生产者只有 mov.c:8977；没有任何 libav* 组件读取它（packet.c:297 只是调试名）。它是一个纯**对外契约**：ffprobe 不展示解密结果，ffplay 不解密——设计意图是让外部 DRM 插件层消费。姊妹 side data `AV_PKT_DATA_ENCRYPTION_INIT_INFO`（libavcodec/packet.h:245-247）对应 pssh，同样是只出不进。

---

## 6. 设计动机

**为什么 crypto: 是 URLProtocol 而不是 demuxer？**（呼应 09 章）三点：其一，AES-128-CBC 全分片加密**不改变容器结构**，解密后就是完整 TS/fMP4，任何 demuxer 无感复用——放 I/O 层是复用面最大的位置；其二，URLProtocol 有嵌套机制（NESTED_SCHEME，crypto.c:401），`crypto:https://…`、`crypto:file://…` 免费获得全部协议能力；其三，key 生命周期恰好是"一个分片"——每次 `open_input` 都是新 URL、新 key/IV 选项（hls.c:1533-1538），轮换零成本。代价是它只能表达"单 key、整段、CBC"这个最小模型，于是 SAMPLE-AES 与 CENC 必须另起炉灶。

**为什么 SAMPLE-AES 必须包级？** 因为密文/明文以 **NALU 内部**的粒度交织（16:144 模式、头 32 字节明文、音频帧头明文），且需要 Annex B/ADTS/AC3 同步帧解析才能定位。这是"懂编码格式"的活儿，I/O 层和通用 bit filter 都不该背；它顺理成章地长在唯一合法宿主——HLS demuxer 的读包路径里（hls.c:2807-2811）。

**CENC 的 DRM 生态位与 FFmpeg 的边界。** CENC 的价值是"一份密文，多家 DRM"：加密规格标准化（cenc/cbcs），key 交付留给 pssh+license server。FFmpeg 精准地站在**格式转换器**的位置：盒子读写全包（senc/saiz/saio/sinf/tenc/pssh），IV 生成给随机或顺序递增两种（movenccenc.c:615-617、147），知道 key 时可以顺手就地解密（mov.c:8970）——但 KMS、license 协议、硬件级保护一概不做。side data 是它对外的全部接口承诺。写侧只支持 cenc-aes-ctr（movenc.c:8469-8486）也符合"能生产符合 CENC-CTR 的密文流供打包器/DRM 包装"这一最低闭环；cbcs（FairPlay/离线常见）需求落在专业打包器手里。

---

## 7. FAQ 素材

1. **`av_aes_crypt` 的 iv 传 NULL 是什么模式？** ECB（libavutil/aes.h:60-61）；非 NULL 即 CBC，且 IV 就地推进（libavutil/aes.c:149,163）。
2. **crypto: 支持多大 key？** 仅 AES-128：`set_aes_arg` 强制 16 字节（crypto.c:104-109），`av_aes_init(..., BLOCKSIZE*8, ...)`（crypto.c:159,174）。
3. **HLS 播放列表没写 IV= 怎么办？** 用媒体序号填充 IV 高位（大端 64 位）：libavformat/hls.c:1070-1076。
4. **为什么 SAMPLE-AES 的 AES 上下文每帧重建？** `decrypt_nal_unit`/`decrypt_sync_frame` 每次都 `av_aes_init`（hls_sample_encryption.c:210,349）——正确性无碍（轮密钥相同），纯实现取舍，可作性能话题。
5. **mov muxer 能写 cbcs 吗？** 不能。仅 `cenc-aes-ctr`，tenc 恒 v0 无 pattern（movenc.c:8469-8486；movenccenc.c:558-563）。
6. **mov demux 遇到不认识的加密 scheme？** `cenc_decrypt` 报 "invalid encryption scheme"（mov.c:8895-8897）；认识但没 key 则挂 side data 放行（mov.c:8973-8979）。
7. **cbcs 与 cbc1 都基于 CBC，差别？** cbc1 subsample 间链式延续；cbcs 每个 subsample 从样本 IV 重新开始（mov.c:8847 vs :8688 起）。
8. **muxer 侧每帧 IV 怎么变？** 8 字节 IV 写入 senc 后顺序 +1（movenccenc.c:120,147；递增实现 libavutil/aes_ctr.c:95-100）；首个 IV 随机（movenccenc.c:615-617），bitexact 时从 0 起。
9. **树里有 RTMPE/SRTP 吗？** 都有：RTMPE 在 libavformat/rtmpproto.c:1264-1310（握手），SRTP 在 libavformat/srtp.c:42-95（复用 av_aes_crypt 与 av_hmac）。别想当然写"无此实现"。
10. **AES-192/256 有用户吗？** 公共 API 支持（libavutil/aes.h:48, libavutil/aes.c:246-247），但栈内调用方（crypto:、aes_ctr、SAMPLE-AES、CENC、SRTP）全是 128 位。

## 深挖方向

1. **crypto_seek 的 IV 恢复缺陷**：只从通用 `iv` 选项恢复种子 IV（crypto.c:283-286），`decryption_iv`-only 时 seek 回 0 块会解错；"回退一块 + 丢弃式读"的链值重建技巧（crypto.c:287-325）本身值得精读。
2. **saiz/saio 无 senc 的解析路径**：`mov_parse_auxiliary_info` 需要真实 seek 到文件内偏移，不可 seek 时优雅降级（mov.c:8067-8127）——对比 senc 内嵌方案（mov.c:8011-8064），是讲 fMP4 索引设计的好材料。
3. **tenc v0/v1 语义分叉**：pattern 只在 version>0 出现（mov.c:8489-8492），per_sample_iv_size=0 走 default_constant_IV（mov.c:8515-8524）——cbcs 部署（FairPlay HLS fMP4）几乎都踩这两处。
4. **AV1 加密与 CBS**：mux 侧用 cbs_av1 拆 OBU，仅加密 tile group 数据（movenccenc.c:287-482）；demux 侧 cens 对 AV1 尚无对称处理，可对比展开。
5. **hls.c 的 TS/fMP4 分流**：同为 SAMPLE-AES，TS 本地解（hls.c:2531-2539、2807-2811）、fMP4 透传 key 给 mov.c（hls.c:2526-2530）——两条信任路径在同一 demuxer 内并存的案例。

---

## 写作要点速查表

| 主题 | 函数/位置 | 文件:行号 |
|---|---|---|
| AES 公共 API（CBC/ECB） | av_aes_crypt | libavutil/aes.h:63 |
| CBC IV 就地推进（解密侧） | aes_decrypt | libavutil/aes.c:155-169（:163） |
| 轮密钥展开 / 128-192-256 校验 | av_aes_init | libavutil/aes.c:231-283（:235,246） |
| sbox/multbl 一次性线程安全生成 | aes_init_static | libavutil/aes.c:202-228 |
| CTR 封装 / IV 递增 | av_aes_ctr_crypt / increment_iv | libavutil/aes_ctr.c:102-135 / 95-100 |
| crypto: 选项与 16 字节强制 | crypto_options / set_aes_arg | libavformat/crypto.c:69-77 / 86-111 |
| crypto: 流式读 + PKCS7 | crypto_read | libavformat/crypto.c:186-234 |
| crypto: seek 链值重建 | crypto_seek | libavformat/crypto.c:236-328 |
| HLS 拼 crypto: URL + 传 key/iv | open_input | libavformat/hls.c:1528-1540 |
| HLS 默认 IV=媒体序号 | parse_playlist | libavformat/hls.c:1070-1076 |
| SAMPLE-AES TS 每包解密入口 | ff_hls_senc_decrypt_frame 调用 | libavformat/hls.c:2807-2811 |
| SAMPLE-AES fMP4 透传 key | read_header SAMPLE-AES 分支 | libavformat/hls.c:2526-2530 |
| H.264 1:9 模式逐 NALU 解密 | decrypt_nal_unit | libavformat/hls_sample_encryption.c:203-233 |
| mux 初始化（随机 IV/subsample） | ff_mov_cenc_init | libavformat/movenccenc.c:600-631 |
| mux 每帧 IV 写入与递增 | start_packet / end_packet | libavformat/movenccenc.c:115-171（:120,147） |
| mux 写 senc/saio/saiz | ff_mov_cenc_write_stbl_atoms | libavformat/movenccenc.c:495-550 |
| mux sinf/frma/schm/tenc | ff_mov_cenc_write_sinf_tag | libavformat/movenccenc.c:552-590 |
| demux tenc/schm 解析 | mov_read_tenc / mov_read_schm | libavformat/mov.c:8460-8535 / 8429-8458 |
| demux senc 与 saiz/saio | mov_read_senc / mov_read_saiz / mov_read_saio | libavformat/mov.c:8011 / 8129 / 8213 |
| 四 scheme 解密分派 | cenc_decrypt | libavformat/mov.c:8883-8897 |
| cbcs 每 subsample 重置 IV | cbcs_scheme_decrypt | libavformat/mov.c:8847 |
| 每包出口：解密或挂 side data | cenc_filter（调用点） | libavformat/mov.c:8917-8990（:12232） |
| side data 定义与访问器 | AV_PKT_DATA_ENCRYPTION_INFO | libavcodec/packet.h:250-253；libavutil/encryption_info.h:157-167 |
| demux key 按 KID 查找 | get_key_from_kid | libavformat/mov.c:8568-8606 |
| mux 仅支持 cenc-aes-ctr | mov_write_header 前置校验 | libavformat/movenc.c:8469-8487 |
