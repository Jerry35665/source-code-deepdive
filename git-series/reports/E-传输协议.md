# E. 传输协议：fetch/push smart protocol 与 protocol v2

> 源码版本：Git commit `47ce805`（shallow clone）。所有行号均为该提交下仓库相对路径的实测行号（grep -n / Read 核对）。
> 前置章节：01（对象模型，graft）、02（引用与事务）。

---

## 1. 全景：一次 fetch / push 会话的时序

### 1.1 protocol v0 的 fetch（HTTP 上是每次 POST 一次的 stateless-rpc）

```
 客户端(fetch-pack)                          服务端(upload-pack)
      │                                            │
      │  ◄── 引用广告：<oid> <ref>\0cap-list ...    │  upload-pack.c:1383-1404
      │      (flush 结尾，附 shallow 广告)          │  write_v0_ref: upload-pack.c:1196-1237
      │                                            │
      │  want <oid> <caps>、shallow/deepen、flush ─►│  receive_needs: upload-pack.c:1048-1156
      │                                            │
      │  have <oid> … flush ──────────────────────► │  get_common_commits: upload-pack.c:538-611
      │  ◄── ACK <oid> [continue/common/ready]/NAK  │  (多轮，直到 ready/done)
      │                                            │
      │  done ────────────────────────────────────► │  upload-pack.c:600-607
      │  ◄── ACK/NAK + 打包数据(PACK, sideband)     │  create_pack_file: upload-pack.c:299
```

### 1.2 protocol v2 的 fetch（命令式）

```
 客户端                                         服务端(serve.c 派发)
      │                                            │
      │  ◄── "version 2" + capability 列表 + flush  │  protocol_v2_advertise_capabilities
      │                                            │    serve.c:192-222
      │                                            │
      │  command=ls-refs / agent / object-format ──►│  process_request: serve.c:286-360
      │  delim(0001)、peel、symrefs、ref-prefix …   │  ls_refs: ls-refs.c:161-216
      │  flush(0000)                               │
      │  ◄── <oid> <ref>[ symref-target:… peeled:…] │  send_ref: ls-refs.c:78-121
      │      … flush + response-end(0002)           │
      │                                            │
      │  command=fetch / args / delim ────────────► │  upload_pack_v2: upload-pack.c:1735-1798
      │  want/have/done、thin-pack、filter …        │  process_args: upload-pack.c:1555-1649
      │  flush                                     │
      │  ◄── acknowledgments(ACK/NAK/ready)         │  send_acks: upload-pack.c:1651-1673
      │      或直接 packfile 段                      │  状态机: upload-pack.c:1744-1794
      │  （可多轮，每轮一个 command=fetch 请求）      │
```

### 1.3 push（至今仍是 v0 语义，`builtin/receive-pack.c:2534-2540` 明确忽略 v2 请求）

```
 客户端(send-pack)                            服务端(receive-pack)
      │                                            │
      │  ◄── 引用广告 <oid> <ref>\0cap + flush      │  write_head_info: builtin/receive-pack.c:324-355
      │                                            │
      │  <old> <new> <ref>\0cap … flush ──────────►│  read_head_info: builtin/receive-pack.c:2193-2280
      │  [PACK 数据( thin/ofs-delta )] ───────────►│  unpack_with_sideband: 2293
      │                                            │  pre-receive: 2081 → update: 1592 → 迁移引用
      │  ◄── unpack ok / ok <ref> / ng <ref> 原因   │  report: builtin/receive-pack.c:2412-2434
      │                                            │  post-receive: 2604
```

传输入口都在 `connect.c` 的 `git_connect()`（connect.c:1444-1553）：本地路径直接 fork `git-upload-pack`/`git-receive-pack` 子进程并注入 `GIT_PROTOCOL=version=N` 环境变量（connect.c:1526-1529）；ssh 走 `fill_ssh_args`（SendEnv，connect.c:1326-1334）；git:// 走 `git_connect_git` 的二进制请求包（connect.c:1300-1314）。HTTP 则由 remote-curl 把同样的 pkt-line 流装进 POST body（stateless-rpc）。v2 只对 upload-pack 生效：`if (version == protocol_v2 && service != GIT_CONNECT_UPLOAD_PACK) version = protocol_v0;`（connect.c:1459-1460）。

---

## 2. pkt-line 专节：传输层的"字节 backbone"

所有 fetch/push 的会话流都被切成统一帧：**4 字节小写十六进制长度前缀（含这 4 字节自身）+ payload**。

- 编码：`set_packet_header()` 把长度拆成 4 个 hex 字符（pkt-line.c:134-144）；`format_packet()` 先写占位 `"0000"` 再回填真实长度（pkt-line.c:146-162）。
- 解码：`packet_length()` 按 4/8/12 位左移拼回整数（pkt-line.c:377-385）。
- 尺寸上限：普通包 1000 字节（`DEFAULT_PACKET_MAX`），最大 65520（`LARGE_PACKET_MAX`，数据区 65516），定义在 pkt-line.h:232-234。头部注释（pkt-line.h:6-20）解释了设计动机：流式分包使读取方"永远不会读进 pack 数据区"，pack 可以交给另一个进程处理。

三个保留帧（pkt-line.c:93-112 的写侧、pkt-line.c:434-445 的读侧）：

| 帧 | 字节 | 语义 | 典型用途 |
|---|---|---|---|
| flush-pkt | `0000` | 段落结束（相当于消息边界） | 广告列表结尾、请求参数结尾 |
| delim-pkt | `0001` | 命令头与命令参数的分隔 | v2 `command=xxx` 之后的参数区 |
| response-end | `0002` | 一次 HTTP 请求响应的结束 | v2 stateless-rpc 每个响应末尾 |

读侧统一由 `packet_read_with_status()` 判定：len==0 → `PACKET_READ_FLUSH`，len==1 → `PACKET_READ_DELIM`，len==2 → `PACKET_READ_RESPONSE_END`，len<4 报协议错误（pkt-line.c:427-451）。上层可用同步的 `struct packet_reader`（pkt-line.h:165-200），支持 `peek` 不消费（serve.c 的 `process_request` 就靠 peek 看 flush/delim，serve.c:306-347）。

另有一个 sideband 通道（band 1=数据、2=progress、3=错误），读侧在 `PACKET_READ_USE_SIDEBAND` 下只对 band 1 去 `\n`（pkt-line.c:466-485）。

---

## 3. protocol v2 专节：从"一次广告全部"到"命令式"

### 3.1 版本判定与协商

- 客户端配置：`get_protocol_version_config()` 读 `protocol.version`，未配置时**默认 v2**（protocol.c:21-47，注意 46 行 `return protocol_v2;`）。
- 服务端判定：从 `GIT_PROTOCOL` 环境变量取 `version=` 键，多个取最大（`determine_protocol_version_server()`，protocol.c:49-83）。
- 客户端确认：peek 服务端首行，`version 2` → v2；flush/EOF → v0（`discover_version()`，connect.c:143-181；`determine_protocol_version_client()`，protocol.c:85-99）。

### 3.2 为什么改成命令式：v0 广告的 O(n) 问题

v0 里 `git upload-pack` 开场必须遍历**全部引用**：`refs_head_ref_namespaced(...send_ref)` + `for_each_namespaced_ref_1(send_ref)`（upload-pack.c:1387-1389），每条引用一个 pkt-line，第一条还捎带全部 capability（`write_v0_ref`，upload-pack.c:1196-1237）。百万引用的托管仓库（如大型 mirror 场景）中，每次 fetch——哪怕只想要 `refs/heads/main` 一个 ref——都要生成、传输、解析整个广告列表，再叠加 HTTP stateless-rpc 的多进程重启，成本为 O(引用总数)。

v2 的解法是把"会话"拆成两个可独立调用的**命令**（serve.c:146-190 的能力表）：

- `ls-refs`：客户端显式发起，且支持 `ref-prefix <prefix>` 前缀过滤（ls-refs.c:181-184），服务端在 `send_ref` 中逐条 `ref_match` 丢弃不匹配引用（ls-refs.c:54-67, 88-89）。前缀超过 65536 个则整体放弃过滤退化为全量（`TOO_MANY_PREFIXES`，ls-refs.c:48, 199-200）——防止恶意超大请求，也说明过滤本来就是为"少"设计的。
- `fetch`：只有真正需要打包时才调用。

行号链（ls-refs 一次调用）：客户端 `get_remote_refs()` 发 `command=ls-refs\n` + capability + delim + `peel`/`symrefs`/`unborn`/`ref-prefix …` + flush（connect.c:569-621）→ 服务端 `process_request()` 解析出命令对象并调用 `command->command(r, &reader)`（serve.c:260-279, 357）→ `ls_refs()` 读参数直到 flush（ls-refs.c:173-192）→ `send_ref` 输出 `<oid> <ref>[ symref-target:…][ peeled:…]`（ls-refs.c:91-118）→ flush 结尾。

### 3.3 capability 协商与会话化

v0 的 capability 是"塞进第一条引用广告"（upload-pack.c:1200-1226）；v2 的 capability 是独立响应：`protocol_v2_advertise_capabilities()` 先写 `version 2`，再逐个询问 `capabilities[]` 表的 `advertise` 回调，逐行输出 `name[=value]`，flush 收尾（serve.c:192-222）。能力表里 `ls-refs`、`fetch`、`object-info`、`bundle-uri` 同时也是命令（serve.c:151-159, 175-184）。

服务端会话是一个 for 循环：`protocol_v2_serve_loop()` 反复 `process_request()`，客户端 flush 且无命令即退出（serve.c:362-378）；HTTP 下 `stateless_rpc` 只处理一次（serve.c:371-372）。fetch 命令内部又是一个状态机 `UPLOAD_PROCESS_ARGS → UPLOAD_SEND_ACKS → UPLOAD_SEND_PACK → UPLOAD_DONE`（upload-pack.c:1728-1794）：无 have 直接打包；有 have 先发 acknowledgments，收到 `ready` 才进 pack 阶段。

v2 的响应按**段（section）**组织：`acknowledgments`、`shallow-info`、`wanted-refs`、`packfile-uris`、`packfile`，段头是普通 pkt-line，段间用 delim/flush 分隔；客户端 `process_section_header()` 逐段校验（fetch-pack.c:1464-1485），并强制"有 ready 才允许 packfile 段"（fetch-pack.c:1520-1538）。

---

## 4. 协商专节：have/ACK 多轮的代价与 negotiator 演进

协商的目标：找到双方都有的最新提交（cut），让服务端只打包差异。代价在"慢仓库、多轮往返"上最为明显。

### 4.1 v0 的 have/ACK 多轮

客户端 `find_common()`（fetch-pack.c:349-644）：

- 第一条 want 捎带 capability（fetch-pack.c:403-424），随后按窗口发 have。窗口大小 `INITIAL_FLUSH=16` 起步（fetch-pack.c:272），非 stateless 每轮 `+= 32`（`PIPESAFE_FLUSH`，fetch-pack.c:273, 284-287），stateless 翻倍直至 16384（`LARGE_FLUSH`，fetch-pack.c:274, 278-281）——窗口放大是为了减少 HTTP 往返。
- 服务端在 `get_common_commits()` 里逐 have 回 ACK：`multi_ack_detailed` 下区分 `ACK <oid> common`（双方共有）、`ACK <oid> ready`（我方 ok_to_give_up，可打包了）、`ACK <oid> continue`（继续），plain v0 只对第一个公共点回一次 `ACK <oid>`（upload-pack.c:573-608）。
- 客户端 `get_ack()` 解析出 `enum ack_type { NAK, ACK, ACK_continue, ACK_common, ACK_ready }`（fetch-pack.c:196-202, 224-247）。`MAX_IN_VAIN=256`：连续 256 个 have 无新 ACK 就放弃遍历（fetch-pack.c:64-68, 604-607）；`no-done` + `ready` 允许跳过最后一轮 done（fetch-pack.c:616-619）。

### 4.2 v2 与 negotiator 抽象

v2 的客户端状态机 `do_fetch_pack_v2()`（fetch-pack.c:1671-1850）把协商拆为 `FETCH_CHECK_LOCAL → FETCH_SEND_REQUEST ⇄ FETCH_PROCESS_ACKS → FETCH_GET_PACK`（fetch-pack.c:1660-1666），每轮 `send_fetch_request()` 发 `command=fetch` + want/common/have（fetch-pack.c:1378-1456），haves 数量同样从 16 翻倍（`add_haves()` 里 `*haves_to_send = next_flush(1, …)`，fetch-pack.c:1373）。协议文本变了，但**协商算法被抽象成 `struct fetch_negotiator`**（`known_common/add_tip/next/ack/have_sent/release`，fetch-negotiator.c:8-25 按配置分发）：

- `consecutive`（即 v0 时代的 default，negotiator/default.c）：按提交日期的优先队列逐个弹出，弹出的提交**每次都把父链继续入队**（`get_rev()`，default.c:108-150）——发送顺序是严格逐层回溯，历史越长，前几十个 have 命中率越低。
- `skipping`（negotiator/skipping.c）：核心是给队列条目一个 **TTL**：不发送父提交，而是消耗其 TTL；父被弹出时若 TTL 未耗尽就跳过不发送，TTL 用尽才发 have。TTL 逐层放大 `original_ttl * 3 / 2 + 1`（skipping.c:160-166），因此发送呈指数跳步，能用更少的 have 覆盖更深的历史。`feature.experimental` 与 `fetch.negotiationAlgorithm=skipping` 都会启用它（repo-settings.c:53-54, 121-123；默认值仍是 consecutive，fetch-negotiator.c:21-23）。
- 两个实现都靠 `COMMON/SEEN/POPPED` 等对象标志位 + `mark_common()` 沿父链传播"共有"状态（default.c:57-103；skipping.c:92-121），`ack()` 回调把服务端确认的提交标 COMMON。

慢协商问题的本质是**round-trip 数**：v0 每轮窗口固定小、stateless HTTP 下每轮还要重建进程；v2 通过命令式会话 + 窗口翻倍 + negotiator 可替换（skipping 的指数跳步）三管齐下压低轮数——`do_fetch_pack_v2` 甚至为每轮协商打 trace2 region（fetch-pack.c:1765-1800），便于线上观测总轮数（`total_rounds`，fetch-pack.c:1816-1817）。

---

## 5. push 专节：更新行、force 的 zero-old 与报告

### 5.1 更新行格式

客户端 `send_pack()` 在收到服务端广告后回发命令行：`<old-oid> <new-oid> <refname>`，第一条后跟 NUL + capability 列表（`report-status [report-status-v2] side-band-64k quiet atomic push-options object-format=… agent=…`，send-pack.c:584-601 组装、666-675 发送）：

```c
packet_buf_write(&req_buf,
                 "%s %s %s%c%s",
                 old_hex, new_hex, ref->name, 0,
                 cap_buf.buf);          /* send-pack.c:667-670 */
```

- **删除引用 / 新建引用都用 null-oid 表达**：删除时 old=真实当前值、new=0000…；新建则 old=0000…。服务端用 `is_null_oid()` 判定（builtin/receive-pack.c:1534, 1563-1564, 1604）。"强制更新"并没有专门指令——客户端算好非 fast-forward 的新值直接发，服务端 `deny_non_fast_forwards` 检查不过就拒绝（builtin/receive-pack.c:1563-1591），客户端在 `--force` 时只是不做本地预先拒绝。
- 命令行解析在服务端 `queue_command()`：严格 `parse_oid_hex → ' ' → parse_oid_hex → ' ' → refname`（builtin/receive-pack.c:2134-2155）。
- 删除需服务端广告 `delete-refs` 能力，否则标记 `REF_STATUS_REJECT_NODELETE`（send-pack.c:536-537, 608-610）。

### 5.2 服务端 hook 链与事务（呼应 02 章引用事务）

`execute_commands()` 的顺序：连通性检查 → `pre-receive`（一次拿到全部命令，任一拒绝则全体拒绝，builtin/receive-pack.c:2081-2087）→ 对象事务迁移 → 每条命令执行 `update` hook（参数 `refname old new`，builtin/receive-pack.c:964-988）与 `ref_transaction_update/delete`（builtin/receive-pack.c:1615-1640）→ `post-receive`（builtin/receive-pack.c:2604-2606）。hook 只在 02 章事务的提交点前后插桩，成败回写进 `cmd->error_string`。

### 5.3 report-status

命令行里客户端用 `report-status`/`report-status-v2` 请求回报（服务端在 `read_head_info` 里解析，builtin/receive-pack.c:2219-2222；客户端在 send-pack.c:532-535 探测）。服务端打包结束后 `report()` 输出：`unpack ok|<错误>` + 每条命令 `ok <ref>` 或 `ng <ref> <原因>`，flush 结尾（builtin/receive-pack.c:2412-2434）。v2 版本追加 `option refname/old-oid/new-oid/forced-update` 行（builtin/receive-pack.c:2436-2470），客户端 `receive_status()` 逐行解析并匹配回本地 ref（send-pack.c:131-250）。进度与错误走 sideband band 2/3（`send_sideband`，builtin/receive-pack.c:2429-2432）。

push 也有可选协商：`push.negotiate=true` 时 send-pack 会 fork `git fetch --negotiate-only` 拿公共点，减小 thin pack 体积（`get_commons_through_negotiation()`，send-pack.c:402-476, 516-524）——但失败不阻塞 push（send-pack.c:469-474）。

---

## 6. 浅克隆专节：deepen 与"骗过" commit 解析的 graft

- **请求**：客户端发 `deepen <depth>` / `deepen-since` / `deepen-not` / `shallow <oid>`（v0：fetch-pack.c:436-450 组装；服务端 `receive_needs` 里 `process_shallow/process_deepen/process_deepen_since/process_deepen_not` 逐条识别，upload-pack.c:1065-1072、918-990。v2 同样参数进 `process_args`，upload-pack.c:1599-1613）。
- **计算**：服务端 `deepen()` 调 `get_shallow_commits()` 得到切割点，`send_shallow()` 发 `shallow <oid>`，`send_unshallow()` 对客户端已声明但服务端其实完整的点发 `unshallow <oid>`（upload-pack.c:787-858）。`--depth` 与 `--deepen-since` 互斥（upload-pack.c:877-878）。
- **存储**：客户端把收到的 shallow oid 写入 `$GIT_DIR/shallow`（`setup_temporary_shallow`/`commit_shallow_file`，shallow.c:440-461, 102-114）。下次 `is_repository_shallow()` 打开该文件逐行 `register_shallow()`（shallow.c:61-93）。
- **骗过解析**：`register_shallow()` 注册一个 `nr_parent = -1` 的 **commit_graft**，并把已解析提交的 parents 置空（shallow.c:32-45）。commit 解析层（01 章）遇到 graft 就用伪造的父链替换真实父链，于是"深度截止"不需要修改任何对象——对象库保持内容寻址完整性。服务端广告自己也是浅仓库时，`advertise_shallow_grafts()` 把 nr_parent==-1 的 graft 逐个发成 `shallow <oid>` 行（shallow.c:463-476），push 场景接收方用它做 `shallow_update`（builtin/receive-pack.c:2204-2210, 2578-2592）。

---

## 7. 设计动机

1. **v0 广告的全量性是"无状态脚本"时代的合理默认**：一次 fork、一次广告、一次 want、一次打包，服务端无会话状态。引用数涨到十万级后，"全部引用一条 pkt-line"的 O(n) 成本落在每次 fetch 上，且 HTTP 下每个 RPC 都重付。v2 把广告改成 `ls-refs` 按需 + `ref-prefix` 过滤（ls-refs.c:181-184），把 fetch 拆成幂等命令，正是为超大仓库与智能代理（如 CDN 后的 git server）服务。
2. **v2 会话化的另一收益是错误与扩展的正交**：capability 不再挤在第一条引用行里（对比 upload-pack.c:1214 与 serve.c:200-217），`object-format` 成为显式握手（serve.c:56-73; 352-355 校验一致），bundle-uri、object-info、promisor-remote 等都能以"新命令/新能力"增量添加而无需动 v0 的广告格式。
3. **push 为什么没有 v2**：push 的重头是 PACK 上传与引用事务，几乎没有"客户端要从服务端目录里挑东西"的场景——服务端广告一次引用就够，且 push 频率远低于 fetch，O(n) 广告成本可接受。所以 `cmd_receive_pack` 收到 v2 请求直接回落 v0（builtin/receive-pack.c:2534-2540），`git_connect` 也把一切非 upload-pack 服务压回 v0（connect.c:1453-1460）。真正给 push 提速的是增量机制（`push.negotiate`、bitmaps），而非换协议版本。
4. **hook 与事务的服务端呼应**：smart protocol 的服务端把"是否接受"拆成三级——pre-receive（整体门禁）、update（每条引用门禁）、引用事务的原子提交（02 章 ref_transaction），最后 report-status 把每条结果精确回传客户端。这让服务端策略（如禁止删除分支 builtin/receive-pack.c:1534-1539、deny_non_fast_forwards 1563-1591）与协议解耦：协议只传 `old new ref` 事实，策略全在 hook/配置。
5. **pkt-line 的极简主义**：4 字节 hex 长度让任何语言可在数行内实现解析器，flush/delim 两个保留值承担了"消息边界"语义，使 v2 能在同一字节流上多路复用命令与会话，而无需引入真正的二进制序列化层。

---

## 8. FAQ 与深挖素材

### FAQ

1. `0000/0001/0002` 为什么用长度字段区分？——解析器读前 4 字节即可分派，无需转义；长度 0/1/2 本不可能属于合法包（最小合法包为 `0004`），是零成本的保留值（pkt-line.c:434-451）。
2. fetch 时服务端怎么知道我有哪些提交？——客户端逐轮发 `have <oid>`，服务端以 ACK 告知命中；v0 由 `multi_ack*` 控制回执粒度（upload-pack.c:1090-1095），v2 统一为 acknowledgments 段（upload-pack.c:1651-1673）。
3. `MAX_IN_VAIN=256` 是什么？——客户端连续发出 256 个 have 都没换来新 ACK 时，判定双方历史分叉过远，停止遍历直接发 done（fetch-pack.c:64-68, 604-607, 1443-1447）。
4. 为什么浅克隆后 `git log` 不会报错？——shallow 点被注册成 `nr_parent=-1` 的 graft，父链显示为止于该点的"根"（shallow.c:32-45）。
5. push --force 在协议层面长什么样？——和普通 push 完全一样：`old new ref` 三元组；force 只是客户端跳过本地 fast-forward 预检，服务端 `deny_non_fast_forwards` 未开启就照单全收。
6. `report-status` 与 `report-status-v2` 的区别？——v2 多了 `option` 行，可回报每条 ref 的实际 refname/new-oid/forced-update，供服务端（proc-receive 场景）改写结果（builtin/receive-pack.c:2455-2470）。
7. 如何让服务端只给我一个分支的广告？——v2 下传 `ref-prefix refs/heads/main/`（connect.c:602-605）；v0 做不到，广告永远全量。
8. v1 是什么？——就是 v0 加一行 `version 1` 头，无任何语义变化（builtin/receive-pack.c:2541-2548）。
9. stateless-rpc 下每轮协商都要重新发 want 吗？——服务端无状态，所以客户端在 req_buf 里保留"头部"（want/shallow 等）并在每轮重放（fetch-pack.c:453, 535；`state_len` 机制）。
10. `GIT_PROTOCOL` 环境变量谁设置？——本地/ssh 传输由 `git_connect` 注入（connect.c:1526-1529；ssh 经 SendEnv，connect.c:1329-1334），服务端 `determine_protocol_version_server` 读取（protocol.c:49-83）。

### 深挖

1. **skipping negotiator 的 TTL 推导**：从 skipping.c:130-171 的 `push_parent` 出发，分析 `original_ttl*3/2+1` 的增长如何产生指数跳步，并与 default.c:108-150 的逐层遍历对比 have 数量-覆盖率曲线（可复现实验：`fetch.negotiationAlgorithm=skipping`）。
2. **v2 状态机与 trace2 观测**：upload-pack.c:1728-1794 的四态与 fetch-pack.c:1660-1666 的五态一一对应，配合 `trace2_region_enter("fetch-pack","negotiation_v2",…)` 可量化真实轮数分布（fetch-pack.c:1765-1817）。
3. **push-cert 与 nonce**：`generate_push_cert()`（send-pack.c:320-380）签名的是整个命令块，服务端 `reject_invalid_nonce`（send-pack.c:382-400）防重放——可与 report-status 一起看作 push 协议的"v1.5"扩展路径。
4. **sideband 的演进**：从 v0 的可选 `side-band-64k`（upload-pack.c:1100-1103）到 v2 默认开启（upload-pack.c:1743）再到 `sideband-all`（握手后控制通道也走 band，upload-pack.c:1622-1626），观察进度/错误信息如何与 PACK 字节流复用。
5. **`ref-prefix` 的服务端成本模型**：`refs_for_each_ref_in_prefixes`（ls-refs.c:209-210）是否真的避免遍历全部引用取决于 ref backend（files vs reftable），可结合 02 章引用存储讨论 prefix 过滤的下限。

---

## 9. 写作要点速查表

| 主题 | 位置 | 要点 |
|---|---|---|
| 帧编码 | pkt-line.c:134-144 | 4 字节 hex 长度回填 |
| flush/delim/response-end 写 | pkt-line.c:93-112 | 0000/0001/0002 |
| 特殊帧读侧判定 | pkt-line.c:427-451 | len 0/1/2 分派 |
| 包上限 | pkt-line.h:232-234 | 1000 / 65520 |
| v2 默认版本 | protocol.c:46 | 未配置默认 protocol_v2 |
| 服务端版本判定 | protocol.c:49-83 | GIT_PROTOCOL version= 取最大 |
| 版本发现(客户端) | connect.c:143-181 | peek 首包判版本 |
| v2 能力表/命令分发 | serve.c:146-190, 260-279, 286-360 | ls-refs/fetch 等为命令 |
| v2 能力广告 | serve.c:192-222 | `version 2` + 每能力一行 |
| ls-refs 命令 | ls-refs.c:161-216 | peel/symrefs/unborn/ref-prefix |
| ref-prefix 过滤 | ls-refs.c:48, 54-67 | 65536 上限防滥用 |
| v0 引用广告 | upload-pack.c:1383-1404, 1196-1237 | 全量广告+首条捎 capability |
| v0 want 解析 | upload-pack.c:1048-1156 | want/shallow/deepen/filter |
| v0 ACK 循环 | upload-pack.c:538-611 | common/continue/ready 三态 |
| v2 fetch 状态机 | upload-pack.c:1728-1798 | PROCESS_ARGS→SEND_ACKS→SEND_PACK |
| v2 参数解析 | upload-pack.c:1555-1649 | want/have/done/等待 done |
| v0 客户端协商 | fetch-pack.c:349-644 | 窗口 16→32 倍增/累加 |
| 窗口常量 | fetch-pack.c:272-274 | INITIAL_FLUSH=16, LARGE=16384 |
| in-vain 放弃线 | fetch-pack.c:64-68, 604-607 | MAX_IN_VAIN=256 |
| v2 客户端状态机 | fetch-pack.c:1671-1850 | CHECK_LOCAL⇄SEND_REQUEST→GET_PACK |
| negotiator 分发 | fetch-negotiator.c:8-25 | skipping/noop/consecutive |
| default 协商 | negotiator/default.c:108-150 | 逐层弹出父链 |
| skipping 协商 | negotiator/skipping.c:130-171 | TTL*3/2+1 指数跳步 |
| push 命令行发送 | send-pack.c:666-675 | `old new ref\0caps` |
| push 广告/能力 | builtin/receive-pack.c:261-287, 324-355 | report-status 等能力 |
| push 命令解析 | builtin/receive-pack.c:2134-2155 | 严格 old SP new SP ref |
| pre-receive/update/post-receive | builtin/receive-pack.c:2081, 964-988+1592, 2604 | 三级 hook 位点 |
| report/report_v2 | builtin/receive-pack.c:2412-2479 | unpack + ok/ng [+option] |
| push 拒绝 v2 | builtin/receive-pack.c:2534-2540 | 回落 v0 |
| deepen 计算与回发 | upload-pack.c:787-858, 872-916 | shallow/unshallow 行 |
| shallow→graft | shallow.c:32-45, 61-93 | nr_parent=-1 骗过父链 |
| shallow 广告 | shallow.c:463-476 | `shallow <oid>` 行 |
| 传输入口 | connect.c:1444-1553 | local/ssh/git:// 封装与 GIT_PROTOCOL 注入(1526-1529) |
| v2 仅限 fetch | connect.c:1453-1460 | 非 upload-pack 回落 v0 |
| v2 ls-refs 客户端 | connect.c:569-621 | command=ls-refs + ref-prefix |
| v2 命令与能力封装 | connect.c:712-744 | `command=%s` + delim |
