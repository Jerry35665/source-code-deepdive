# 第 02 章 · 捕获管线与 dumpcap:特权压缩与"文件即接口"

> 基线:tag `v4.7.3`(commit `f6e0bf22`)。核心:dumpcap.c / capture/capture_sync.c / capture/capture-pcap-util.c。

## 2.0 全景:前端与抓包进程的协作

```
 Wireshark GUI / TShark(普通权限)                dumpcap(启动特权,随后降权)
   capture_start (ui/capture.c:118)
       |  sync_pipe_start:拼 argv(-i eth0 -f "tcp" -w x.pcapng -b ...)
       +-- fork+execv("dumpcap ... -Z <fd>") ──►  main 早扫 -Z(dumpcap.c:5204)
       |                                            | capture_child=true
   g_io_add_watch(消息管道)                    capture_loop_start(4137)
       |                                          ├ pcap_create→set_*→pcap_activate
       | ◄── 'F' 新文件名 / 'P' 计数 / 'D' 丢包 ──┤ ├ pcap_compile+setfilter(3340)
       |                                          │ └ [降权] setuid(ruid)/清能力(3268)
   cf_open 尾读捕获文件 ══(文件系统,非管道)═════ 写 SHB+IDB+包
   用户点停止 ── SIGUSR1/SIGTERM ──────────────► pcap_breakloop(4663)
```

纠偏:**抓包数据从不流经前端管道**——活动捕获时 `sync_pipe_start` 传 `data_read_fd=NULL`,不创建数据管道;dumpcap 直接写捕获文件,前端只收 'F'/'P'/'D' 消息后尾读文件;stdout 数据管道仅用于 -D/-L 一次性查询(capture_sync.c:971-975, 1065-1077)。"GUI 通过管道收包"是流传最广的误读。

## 2.1 main():先定 -Z,再谈参数

dumpcap main 约 1000 行(dumpcap.c:5102-6105),第一步不是解析参数,而是低配扫描 argv 找隐藏选项 `-Z`:capture_child 模式必须最早确定,因为此后所有输出都要改造成"1 字节类型+3 字节大端长度+正文"回传父进程(dumpcap.c:5159-5235);Windows 传句柄需 `_open_osfhandle` 转换(:5213-5226)。参数解析把捕获类选项整体委托 `capture_opts_add_opt`;多接口强制 `use_threads=true` 且 `use_pcapng=true`(5731-5734);ring buffer 必须有文件名且四条件之一(5750-5769)。一切汇聚于 `capture_loop_start`(6096):open_input→init_filter→open_output→报告首文件名→主循环(dumpcap.c:4137-4405)。dispatch 用 `pcap_dispatch` 而非 pcap_loop,以便信号/`pcap_breakloop` 打断,select 超时 250ms(dumpcap.c:442)。

## 2.2 权限分离:60 行注释枚举 6 种形态

为什么前端不能直接抓包:libpcap 需要 CAP_NET_RAW/NET_ADMIN,而 GUI 保持普通身份是安全底线。dumpcap.c:5347-5418 用 60 行注释枚举 6 种运行形态;libcap 时启动即只留 NET_RAW/NET_ADMIN 并丢 suid(`relinquish_privs_except_capture`,5422-5427);非 libcap 时 `setuid(ruid)` 推迟到**输入源打开完成后**(3263-3272)。特权窗口被精确压缩到 pcap_activate 前后——写文件、跑主循环时进程已是普通身份。ui/capture.c 中没有任何 pcap_ 调用(已核实),这是"权限分离"的守门处。

## 2.3 与 libpcap 的边界:create→set→activate→BPF

打开设备走新式序列(capture-pcap-util.c:1759-1855):`pcap_create` → set_snaplen/promisc/timeout(250ms)/buffer_size(默认 2MB)/rfmon → `pcap_activate`。BPF 在 dumpcap 进程内编译安装:pcap_lookupnet 失败则掩码置 0 继续,`pcap_compile`+`pcap_setfilter`(dumpcap.c:799, 3332-3344);捕获管道输入不支持 BPF。编译失败发 'B' 消息,前端会尝试把它当显示过滤器解析,以提示"捕获/显示过滤器语法不同"(capture_sync.c:2014-2026)。

## 2.4 管道协议:1+3 字节头,注释否决了 Protobuf

消息 = 1 字节类型 + 3 字节大端长度 + 正文(上限 512,000,sync_pipe.h:38;sync_pipe_write.c:27-40),注释明确否决 Thrift/Protobuf(sync_pipe.h:40-46)。类型单字符(sync_pipe.h:47-62):'F' 新捕获文件名(pcapng 直通时推迟到首个 SHB 落盘后发送,dumpcap.c:4831-4836,保证前端打开即可读到头)、'P' 自上次以来新增包数(默认 100ms 一批,ui/capture_opts.c:121)、'D' 丢包 `drops:name`、'E'/'W' 错误警告、'B' 过滤器错误、'X' exec 失败 errno、'L' 日志转发。Unix 停止靠信号,Windows 靠命名管道 `\\.\pipe\wireshark.<pid>.signal` + 每轮 PeekNamedPipe 探测父进程存亡(dumpcap.c:6322-6360)。

## 2.5 ring buffer:四条件切换与文件命名

时间驱动的 duration/interval 在主循环 update 分支检查(dumpcap.c:4385-4403),数据驱动的 packets/filesize 在每包回调检查(4740-4775;filesize 单位 kB,以 bytes_written/1000 判断)。切换 `do_file_switch_or_stop`(3980-4039):先看 `-a files:N` 是否用尽(用尽整体停止),再 ringbuf_switch_file、清零计数、重写文件头、重置计时器、发新 'F'。纠偏:文件名没有 `%d_%c` 模板——实际是 `前缀_%05u_YYYYmmddHHMMSS.后缀`(ringbuffer.c:109-118),序号对 100000 取模(ringbuffer.h:23)。纠偏:v4.7.3 已**不存在** capture_stop_conditions.c/.h(全树 grep 零命中),旧版"停止条件对象"已内联为普通布尔判断。

## 2.6 设计动机

1. **权限面最小化**:全仓库只有 dumpcap 碰 libpcap,特权窗口压到 activate 前后(dumpcap.c:3263-3272);
2. **崩溃与安全隔离**:dumpcap 仅 6.4K 行、无 dissectors,解析器崩溃不伤抓包(sync_pipe.h:40-46 侧证其定位);
3. **节奏解耦**:100ms 批量上报防 UI 拖慢抓包热路径(dumpcap.c:4348-4353);
4. **文件即接口**:前端只认文件名,崩溃后文件仍在(dumpcap.c:4831-4836);
5. **多接口统一抽象**:强制线程+pcapng——pcap 头只有一个 linktype,无法表达每接口 IDB(dumpcap.c:3480-3482);
6. **背压可控**:GAsyncQueue+字节/包双上限,超限丢新包保内存(dumpcap.c:5679-5687)。

## 2.7 FAQ

**Q1:dumpcap 为什么能 suid 而整个 Wireshark 不 suid?**
唯一需要特权的 libpcap 调用都在这个小进程里,且打开设备后立即降权(dumpcap.c:3263-3272)。

**Q2:GUI 和 dumpcap 之间有几条管道?**
活动捕获只有 1 条消息管道(Unix)或命名信号管道(Windows);数据管道只在 -D/-L 查询时创建(capture_sync.c:971-975 vs 1076)。

**Q3:捕获的包流经 GUI 吗?**
不会,dumpcap 直接写文件,GUI 尾读,管道只传文件名与计数。

**Q4:前端何时开始读文件?**
收到 'F' 后;pcapng 直通时该消息推迟到首个 SHB 写盘(dumpcap.c:4831-4836)。

**Q5:BPF 失败了怎么办?**
发 'B',前端尝试按显示过滤器解析以给出语法提示(capture_sync.c:2014-2026)。

**Q6:多接口为什么强制 pcapng?**
pcap 头只有一个 linkType,表达不了每接口 IDB(dumpcap.c:3480-3482)。

**Q7:ring buffer 名字长什么样?**
`cap_00001_20260919123000.pcapng`:前缀+5 位序号+本地时间戳(ringbuffer.c:109-118)。

**Q8:丢包数从哪来?**
pcap_stats 的 ps_drop 加 dumpcap 自身 dropped/flushed,结束时按接口发 'D'(dumpcap.c:6293-6315)。

**Q9:Windows 怎么叫停 dumpcap?**
向信号命名管道写字节,dumpcap 每轮 PeekNamedPipe 检查(dumpcap.c:6322-6360)。

**Q10:主循环为什么用 pcap_dispatch 不用 pcap_loop?**
为了信号/breakloop 能打断;select 等待超时 250ms(dumpcap.c:442)。

## 2.8 小结与深挖方向

本章结论:**抓包=独立小进程+压缩特权窗口+自制消息协议+文件即接口,前端零 libpcap**。深挖:

1. 捕获管道(cap_pipe)状态机:stdin/FIFO 上的 pcap/pcapng 解析(dumpcap.c:312-382);
2. 多线程背压与丢包语义:GAsyncQueue 超限与 100ms 写者超时(dumpcap.c:4062-4110);
3. Windows 专项:wpcap 动态加载函数指针表(capture-wpcap.c:54-95);
4. extcap FIFO 如何伪装成捕获接口进入同一管线(capture_sync.c:848-860);
5. 无线 -I monitor mode 能力探测与 -k 设信道(capture-pcap-util.c:1594-1667)。
