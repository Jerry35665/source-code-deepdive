# 第 02 章 · avio 与 demuxer:从磁盘字节到 AVPacket

> 基线:commit `9f63b36a`。行号均以该版本源码为准。

## 2.0 全景:两个正交的"插件系统"

FFmpeg 的 libavformat 有两个互相正交的插件系统:

1. **协议层(URLProtocol)**:解决"从哪里拿字节"。每个协议实现一张回调表(url.h:59-97):`url_open/url_read/url_write/url_seek/url_close`;全部协议以静态数组编译期生成(protocols.c:84),支持 `tls+https` 嵌套;
2. **格式层(AVInputFormat)**:解决"字节如何组成流"。每个 demuxer 实现五个回调(demux.h:66-106):`read_probe/read_header/read_packet/read_close/read_seek`。

两者之间靠**带缓冲的 AVIOContext** 解耦:上层 demuxer 只看到 `avio_read/avio_seek`,不感知磁盘还是 HTTP。

```
avformat_open_input()
  ① avio 层: AVIOContext(带缓冲) ←→ URLProtocol 回调表
  ② 内容探测: av_probe_input_buffer2 → AVInputFormat
  ③ demuxer.read_header → AVStream[n] + codecpar
av_read_frame() → AVPacket
```

## 2.1 AVIOContext:双回调 + 双缓冲

### 两层对象

`avio_open` 的路径:URL 前缀提取 scheme(avio.c:312-315)→ 查 URLProtocol → 分配 URLContext(filename 柔性附在尾部,144-151)→ `ffurl_connect` 执行白/黑名单 + `url_open2`(225-254)→ `ffio_fdopen` 套 32KB 缓冲层(470-527)。

URLContext 挂通用选项:`protocol_whitelist/protocol_blacklist/rw_timeout`——**SSRF 防护与网络超时的入口**。

### 读缓冲:三指针 + 绝对偏移

```
buffer          buf_ptr       buf_end      buffer+buffer_size
  │                │             │                │
  ▼                ▼             ▼                ▼
  ┌──────────────────┬───────────┬────────────────┐
  │ 已读(可回退)      │ 待消费     │    空闲         │
  └──────────────────┴───────────┴────────────────┘
```

- `fill_buffer()`(aviobuf.c:514-566):优先在 `buf_end` 后追加以保留回退能力;**探测结束后自动缩容**回 32KB(538-549);
- `avio_read()` **旁路**:`size > buffer_size` 时绕过内部缓冲直读用户缓冲(622-644)——让 mov 这类按索引大块读的 demuxer 不做无谓拷贝;
- **seek 五级降级**(236-319):缓冲内移动 → 回退重读 → 底层 seek → flush+seek → 重开连接。从低代价到高代价依次尝试。

### 探测的"数据归还"——零成本不是巧合

`av_probe_input_buffer2` 读完的探测数据经 `ffio_rewind_with_probe_data`(aviobuf.c:1151)**直接变成 AVIOContext 的新缓冲区**——在不可 seek 的管道上安全探测并重读头部成为可能。这是 avio 层最精巧却最少被文档提及的机制。

## 2.2 demux 框架三阶段

### 阶段一:avformat_open_input

探测 → 选 demuxer → `read_header` → 构建 AVStream[] + codecpar。

### 阶段二:avformat_find_stream_info

**"把解码器当探测器"**:受 `probesize`(默认 5MB)/ `max_analyze_duration`(默认 5s,flv 90s/ts 7s 特例)双重预算约束,真的打开解码器解帧补 codecpar;demuxer 返回的包**全部缓冲进 packet_buffer 原样转交用户**——探测不丢数据(demux.c:2799-2815)。MP4 因 header 信息完备可在第一轮就提前退出(2766-2777)。

### 阶段三:av_read_frame

逐 packet 读取,交给上层解码。时间戳由 `compute_pkt_fields` 补齐——但 MP4 因索引精确可跳过大部分修补。

## 2.3 MP4 demuxer:盒子树解析

MP4(MOV)文件由嵌套的"盒子"(box)组成:

```
ftyp                          ← 文件类型标识
├── moov                      ← 元数据容器
│   ├── mvhd                  ← 全局时长/时间Scale
│   ├── trak                  ← 每轨一个
│   │   ├── tkhd              ← 轨头
│   │   └── mdia
│   │       ├── mdhd          ← 媒体时间Scale
│   │       └── minf
│   │           └── stbl      ← 采样表(核心!)
│   │               ├── stsd  ← 采样描述(codec配置)
│   │               ├── stts  ← 时间-采样(delta)
│   │               ├── ctts  ← 合成时间偏移(B帧PTS)
│   │               ├── stsc  ← 采样-Chunk映射
│   │               ├── stsz  ← 采样大小
│   │               └── stco  ← Chunk偏移
│   └── iods
└── mdat                      ← 媒体数据(压缩帧)
```

**pts/dts 合成公式**:dts 由 `mov_build_index` 从 stts 增量展开写入 AVIndexEntry.timestamp(mov.c:5137-5139);`pts = dts + dts_shift + ctts_offset` 在 mov_finalize_packet 合成(mov.c:11982-11997)。seek 只是索引数组二分——**这是 MP4 可精确 seek 的根本原因**。

## 2.4 FAQ

**Q1:avformat_find_stream_info 为什么慢?**
它在用解码器做探测(解帧补 codecpar),受 5MB/5s 双重预算约束;MP4 因 header 完备可提前退出,但 TS/FLV 必须解够数据。

**Q2:探测数据丢了吗?**
不丢。探测读入的数据经 `ffio_rewind_with_probe_data` 变成新缓冲,demuxer 从头重新消费。

**Q3:avio_read 大块读会拷贝两次吗?**
不会:`size > buffer_size` 时走旁路直读用户缓冲,绕过内部缓冲。

**Q4:为什么 seek 在某些流上不工作?**
avio_open 时用 `ffurl_seek(0, SEEK_SET)` 试探;失败标记 `is_streamed=1`,此后 seek 五级降级全部不可用。

**Q5:SSRF 防护在哪?**
URLContext 的 `protocol_whitelist/blacklist`(avio.c:64-70),由调用方限制可用的协议白名单。

## 2.5 小结与深挖方向

本章结论:**avio 层 = "回调表协议 + 32KB 双缓冲 + 五级 seek 降级 + 零成本探测回读"**;demux 层 = "五回调接口 + 三阶段初始化 + 时间戳修补"。深挖:

1. `ffio_rewind_with_probe_data` 在不可 seek 管道上的内存上界;
2. `avio_read` 旁路与 CRC 校验的互斥条件;
3. `compute_pkt_fields` 的 DTS 修补算法全貌;
4. mov.c 的 `mov_build_index` 对 edit list(编辑列表)的处理。

> 下一章进入解码层:packet 如何变成 frame——send/receive 管线与 H.264 案例。
