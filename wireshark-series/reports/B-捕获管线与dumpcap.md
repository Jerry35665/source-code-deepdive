# 报告 B · 捕获管线与 dumpcap(Wireshark)

> 基线:tag v4.7.3,commit f6e0bf22...。一句话总结:Wireshark 把"碰内核/碰权限"的抓包整体外包给 6374 行的独立进程 dumpcap——前端只负责拼命令行、fork/exec、用 4 字节头自制协议收"文件名+计数+错误",包数据由 dumpcap 直接写捕获文件,前端尾读该文件;权限上 dumpcap 在 pcap_activate 之后立即降权或清能力。

## 1. 纠偏清单(以本 tag 源码为准)

1. **capture_stop_conditions.c/.h 在 v4.7.3 已不存在**。全树 `grep -rn stop_condition` 零命中(本仓库浅克隆已核实);旧版的"停止条件对象"已内联为 dumpcap.c 主循环里的普通判断:时长类在 update 间隔检查(dumpcap.c:4385-4403),包数/大小类在每写一个包的回调里检查(dumpcap.c:4740-4775)。
2. **不存在 PS_ 消息,更没有 RTSP**。统计回传只有两种 sync pipe 消息:SP_PACKET_COUNT 'P'(dumpcap.c:6180-6194)与 SP_DROPS 'D'(dumpcap.c:6293-6315),常量定义于 capture/sync_pipe.h:47-62。默认推送节奏是 update_interval=100ms(ui/capture_opts.c:121),不是每秒;"每秒一次"的是独立的 `-S` stdout 统计模式(dumpcap.c:1147-1160)。
3. **ring buffer 文件名没有 `%d_%c` 模板**。实际命名为 `前缀_%05u_YYYYmmddHHMMSS.后缀`(nametimenum 时时间在前),由 ringbuffer.c:109-118 硬编码拼接;计数器对 RINGBUFFER_MAX_NUM_FILES=100000 取模(ringbuffer.h:23)。
4. **sync 模式下抓包数据不过管道**。前端活动捕获时 spawn dumpcap 传 `data_read_fd=NULL`(capture/capture_sync.c:971-975),即不创建 stdout 数据管道;dumpcap 直接写 `-w` 文件或临时文件,前端收到 SP_FILE 后尾读文件。stdout 数据管道仅用于 -D/-L 等一次性查询(capture_sync.c:1065-1077)。
5. **主捕获路径早已不用 pcap_open_live**。dumpcap.c:5361 的注释仍写 pcap_open_live,但实际打开走 pcap_create/.../pcap_activate 新 API(capture/capture-pcap-util.c:1759-1855);pcap_open_live 只剩 -S 统计模式在用(dumpcap.c:1163 附近)。
6. 旧说法"dumpcap 全程 root"不准:非 libcap 时 setuid 降权发生在**打开输入源之后**(dumpcap.c:3263-3272,即 pcap_activate 返回后);libcap 时启动即丢 suid 只留 NET_RAW/NET_ADMIN(dumpcap.c:5422-5427),输入源打开后清掉全部能力(dumpcap.c:3270-3272)。

## 2. dumpcap main():从隐藏选项 -Z 到 capture_loop_start

main() 共约 1000 行(dumpcap.c:5102-6105)。第一步不是解析参数,而是**低配扫描 argv 找 -Z**:capture_child 模式必须最早确定,因为此后所有 stderr 输出都要改造成"类型+长度+内容"格式回传父进程(dumpcap.c:5159-5199 注释)。

```c
// dumpcap.c:5200-5212
ws_opterr = 0;
while ((opt = ws_getopt_long(argc, argv, optstring, long_options, NULL)) != -1) {
    switch (opt) {
    case 'Z':
        capture_child    = true;
        machine_readable = true;  /* request machine-readable output */
        if (strcmp(ws_optarg, SIGNAL_PIPE_CTRL_ID_NONE) != 0) {
            if (!ws_strtoi(ws_optarg, NULL, &sync_pipe_fd) || sync_pipe_fd <= 0) { ... }
```

sync_pipe_fd 默认 2(stderr,dumpcap.c:135);Windows 上 -Z 传的是句柄值而非 fd,需 `_open_osfhandle` 转换(dumpcap.c:5213-5226)。随后:日志初始化(5240)、Windows 加载 wpcap(5279)、安装 SIGTERM/SIGINT/SIGPIPE/SIGHUP→capture_cleanup_handler(5330-5335)、`init_process_policies()` 保存 ruid/euid(5420;wsutil/privileges.c:134-143)、libcap 下立即 `relinquish_privs_except_capture()`(5426)。

真正的参数解析(5469-5659)把捕获类选项整体委托给 `capture_opts_add_opt`(ui/capture_opts.c,5516);隐藏选项 `--ifname/--ifdescr` 必须跟在某个 -i 之后(5526-5548)。几个要点:

- `-C/-N`(GAsyncQueue 字节/包上限)非零即强制 `use_threads`,默认 1,000,000 字节/1000 包(5679-5687);
- 多接口强制 `use_threads=true` 且 `use_pcapng=true`(5731-5734);
- ring buffer 校验:必须有落盘文件名(5750-5753)、必须有 filesize/duration/interval/packets 之一(5754-5764)、duration 与 interval 互斥(5765-5769);
- `-D/-L/-d/-k/-S` 互斥,只允许一个(5715-5718),各走一条"打印即退出"支路(5777-5899, 5912-6003, 6083-6087)。

最终一切汇聚于 `capture_loop_start(&global_capture_opts, ...)`(6096),返回即退出。capture_loop_start 的编排(dumpcap.c:4137-4660):open_input(4181)→逐接口 init_filter(4194)→open_output(4219)→init_output 写文件头(4225)→报告首个文件名(4243)→建停止条件(4251-4269)→(多接口)每接口一个读线程 + GAsyncQueue(4283-4294)→主循环(4295-4405)→收尾 join/排空队列(4408-4425)、写 ISB(3553-3585)、汇报丢包(4600-4622)。

```c
// dumpcap.c:4295-4311 —— 主循环:单线程直接 dispatch,多线程从队列取
while (global_ld.go) {
    if (use_threads) {
        bool dequeued = capture_loop_dequeue_packet();
        inpkts = dequeued ? 1 : 0;
    } else {
        pcap_src = g_array_index(global_ld.pcaps, capture_src *, 0);
        inpkts = capture_loop_dispatch(errmsg, sizeof(errmsg), pcap_src);
    }
```

读线程 pcap_read_handler 循环调用 capture_loop_dispatch(4043-4060);dispatch 内部用 `pcap_dispatch()`(非 pcap_loop)以便信号/pcap_breakloop 能打断,select 等待时超时为 CAP_READ_TIMEOUT=250ms(dumpcap.c:442, 3613-3746)。

## 3. 权限分离与降权时序

为什么前端不能直接抓包:libpcap 需要 root 或文件能力(CAP_NET_RAW/NET_ADMIN),而 GUI 进程保持普通用户身份是安全底线。dumpcap.c:5347-5418 用 60 行注释枚举了 6 种运行形态及各自动作,核心代码两处:

```c
// dumpcap.c:5422-5427(main 内,libcap:启动即收权)
#ifdef HAVE_LIBCAP
    /* If 'started with special privileges' (and using libcap)  */
    /*   Set to keep only NET_RAW and NET_ADMIN capabilities;   */
    /*   Set euid/egid = ruid/rgid to remove suid privileges    */
    relinquish_privs_except_capture();
#endif
```

`relinquish_privs_except_capture`(dumpcap.c:1298-1340 起)用 `prctl(PR_SET_KEEPCAPS,1)` + cap_set_proc 只保留 NET_ADMIN/NET_RAW,再 setuid 回 ruid;setresuid/setresgid 的无 libcap 版本在 wsutil/privileges.c:211-239(先 gid 后 uid,uid 最后丢)。输入源打开完毕后:

```c
// dumpcap.c:3263-3272(capture_loop_open_input 末尾)
#ifndef HAVE_LIBCAP
    relinquish_special_privs_perm();   /* setuid(ruid) */
#else
    relinquish_all_capabilities();     /* cap_set_proc(空集) */
#endif
```

即**特权窗口被压缩到 pcap_activate 前后**;写文件、跑主循环时进程已是普通身份。同理,`-d` 打印 BPF 的支路也在编译完过滤器后立刻降权(dumpcap.c:865-873)。Windows 无此问题(抓包权限在 npcap 服务侧),relinquish_special_privs_perm 是空函数(wsutil/privileges.c:75-78)。

## 4. 与 libpcap 的边界:create → set → activate → BPF

打开设备的完整序列在 capture/capture-pcap-util.c 的 `open_capture_device_pcap_create`(1748-1900;入口 `open_capture_device` 2036,由 dumpcap.c:3114 调用):

```c
// capture/capture-pcap-util.c:1759-1787(摘)
pcap_h = pcap_create(interface_opts->name, *open_status_str);
if (interface_opts->has_snaplen)
    status = pcap_set_snaplen(pcap_h, interface_opts->snaplen);
status = pcap_set_promisc(pcap_h, interface_opts->promisc_mode);
status = pcap_set_timeout(pcap_h, timeout);          // timeout=CAP_READ_TIMEOUT 250ms
// 1811: request_high_resolution_timestamp() 请求纳秒时间戳(失败也继续)
// 1821: pcap_set_tstamp_type()(若指定 --time-stamp-type)
// 1836: pcap_set_buffer_size(pcap_h, buffer_size*1024*1024)  默认 2MB(ui/capture_opts.h:509)
// 1847: pcap_set_rfmon(pcap_h, 1)(若 -I monitor mode)
status = pcap_activate(pcap_h);                       // capture-pcap-util.c:1855
```

设备打不开时 fallback 到"捕获管道"(stdin/FIFO/pcapng 管道),`from_cap_pipe=true`,dumpcap.c:3162-3196。BPF 过滤器在 dumpcap 进程内编译并安装:

```c
// dumpcap.c:3332-3344(capture_loop_init_filter)
if (cfilter && !from_cap_pipe) {          /* 捕获管道不支持 BPF */
    if (!compile_capture_filter(name, pcap_h, &fcode, cfilter, optimize))
        return INITFILTER_BAD_FILTER;
    if (pcap_setfilter(pcap_h, &fcode) < 0) { pcap_freecode(&fcode);
        return INITFILTER_OTHER_ERROR; }
    pcap_freecode(&fcode);
}
```

`compile_capture_filter`(dumpcap.c:770-801)先用 pcap_lookupnet 查掩码、失败则置 0 继续(dumpcap.c:779-791),再 `pcap_compile(pcap_h, fcode, cfilter, optimize, netmask)`(799)。编译失败返回 INITFILTER_BAD_FILTER 时,主循环经 report_cfilter_error 发 SP_BAD_FILTER 'B'(含接口序号,dumpcap.c:6239-6263),前端 sync_pipe_input_cb 收到后会先尝试把它当显示过滤器解析,以提示"捕获/显示过滤器语法不同"(capture/capture_sync.c:2014-2026;提示逻辑见 3335-3337 注释)。`-L` 能力查询另有一份精简版 activate 序列 get_if_capabilities_pcap_create(pcap_create 1587 → pcap_can_set_rfmon 1605 → pcap_set_rfmon 1644 → pcap_activate 1669,capture-pcap-util.c)。

## 5. 进程协作:spawn dumpcap 与管道协议

前端三个入口都走同一条路:GUI 的 capture_start(ui/capture.c:118-132)和 tshark 的 sync_pipe_start(tshark.c:3065)。ui/capture.c 中没有任何 pcap_ 调用(已核实),前端与 libpcap 完全隔离。capture_sync.c 的 sync_pipe_start(691-997)把 capture_opts **重新拼回命令行**:

- argv[0] = dumpcap 绝对路径(init_pipe_args,capture_sync.c:256-294),外加 `--log-level` 透传(279-285)与 `--application-flavor`(287-288);
- `-F pcapng|pcap`(729-733)、ring buffer 各条件拆成多个 `-b filesize:/duration:/interval:/packets:/files:`(747-802)、`-a duration/files`、`-c`(812-831);
- 每接口 `-i name [--ifname][--ifdescr] -f cfilter -s snaplen -y linktype -p -B buf -I`(844-945),extcap 接口替换为 FIFO 路径(848-860);
- `-w file`(956-959)、`--compress-type`(963-966)。

Unix 侧 spawn(capture_sync.c:598-627):fork 后子进程把数据管道 dup2 到 stdout(仅一次性查询用;活动捕获不建数据管道,971-975),追加 `-Z <sync_pipe写端fd>`,`execv` 失败则回写 SP_EXEC_FAILED+errno 并 `_exit(1)`(617-626)。Windows 侧:CreatePipe×2 + CreateNamedPipe 信号管道 `\\.\pipe\wireshark.<pid>.signal`(439-442;格式常量 sync_pipe.h:138),`-Z <HANDLE>`(508-510)、`--signal-pipe <pid>`(950-952),win32_create_process(550)。父进程关闭写端以保证 EOF 语义(644-658),用 g_io_add_watch 挂回调(1000-1002)。

管道协议极简:**1 字节类型 + 3 字节大端长度 + 正文**(sync_pipe_write.c:27-40;上限 SP_MAX_MSG_LEN=512,000,sync_pipe.h:38)。消息类型单字符定义(sync_pipe.h:47-62):

| 类型 | 含义 | 发送点(dumpcap.c) |
|---|---|---|
| 'F' SP_FILE | 新捕获文件名;pcapng 直通时推迟到首个 SHB 落盘(4831-4836) | report_new_capture_file 6197-6207 |
| 'P' SP_PACKET_COUNT | 自上次以来新增落盘包数(字符串化 uint) | report_packet_count 6180-6194 |
| 'D' SP_DROPS | 接口丢包统计 `drops:name` | report_packet_drops 6293-6315 |
| 'E'/'W' | 主/次错误或警告(正文是两条嵌套子消息) | sync_pipe_write.c:119-144 |
| 'B' SP_BAD_FILTER | `序号:错误` | 6239-6263 |
| 'S' SP_SUCCESS | 非捕获操作成功应答 | 5957 等 |
| 'L' SP_LOG_MSG | 子进程日志转发(级别:文本) | dumpcap_log_writer 6142-6164 |
| 'X' SP_EXEC_FAILED | exec 失败 errno(fork 子进程发出) | capture_sync.c:617 |
| 'T'/'I'/'Q' | 工具栏控制/接口列表/Win32 停止 | sync_pipe.h:56-62 |

父进程解析在 sync_pipe_input_cb(capture_sync.c:1878-2049):EOF 意味捕获结束,顺带 waitpid 收尸(1907-1929);'F' 触发 new_file 回调(前端开始读文件),'P' 累加 count 并刷新包列表,'D' 触发 drops 回调。注意**活动捕获时前端拿到的不是包,而是"文件名 + 计数"**,包数据始终在文件里。

### 前端↔dumpcap 进程协作与数据流图

```
      Wireshark GUI / TShark(普通权限)                dumpcap(特权,随后降权)
      ================================              ============================
        capture_start (ui/capture.c:118)
            |
        sync_pipe_start (capture_sync.c:691)
            |  拼 argv: -i eth0 -f "tcp" -w x.pcapng -b ...
            |  pipe(sync_pipe) 创建
            +------- fork+execv("dumpcap", argv -Z <fd>') --->  main: 早扫 -Z (dumpcap.c:5204)
            |                                                       | capture_child=true
        g_io_add_watch(sync_pipe_read_io)                     init_process_policies (5420)
            |                                                 [libcap] 保留 NET_RAW/ADMIN (5426)
            |                                                 capture_loop_start (4137)
            |                                                   ├ pcap_create/set_*/pcap_activate
            |                                                   ├ pcap_compile+pcap_setfilter (3340)
            |                                                   ├ 打开输出文件 (4219)
            |   <---- 'S' SP_SUCCESS(仅查询类) ------------------┤ [降权] setuid(ruid)/清能力 (3268)
            |   <---- 'F' SP_FILE "x_00001_2026...pcapng" -------┤
            |                                                   │
        cf_open/尾读捕获文件 <=====(文件系统,非管道)============== 写 SHB+IDB+包 (4779-4839)
            |                                                   │
        收 'P' → 包列表刷新(每 100ms) <--------------------------┤ 主循环: dispatch→写盘→inpkts++
        收 'D' → 丢包统计(结束时) <------------------------------┤ 停止条件检查(4385-4403/4740-4775)
            |                                                   │  ring buffer 切换 (3994)
        用户点"停止" ---- SIGUSR1/SIGTERM(Unix) -----------------> capture_loop_stop→pcap_breakloop(4672)
                       ---- 信号管道 'Q'(Windows) -------------> 
        EOF → waitpid 收尸 (1907)                            写 ISB/收尾 (3553-3585) → exit
```

## 6. ring buffer:触发条件与文件命名

进入多文件模式的开关在命令行 `-b ...`(capture_opts_add_opt 置 multi_files_on,ui/capture_opts.c:493-498)。四类切换触发,两类在主循环(时间驱动)、两类在每包回调(数据驱动):

```c
// dumpcap.c:4385-4403(update 间隔内,时间驱动)
if (autostop_duration_timer != NULL && g_timer_elapsed(...) >= capture_opts->autostop_duration)
    global_ld.go = false;                          /* -a duration:整体停止 */
if (global_ld.file_duration_timer != NULL && g_timer_elapsed(...) >= capture_opts->file_duration)
    if (!do_file_switch_or_stop(capture_opts)) continue;   /* -b duration:切文件 */
if (global_ld.interval_s && time(NULL) >= global_ld.next_interval_time)
    if (!do_file_switch_or_stop(capture_opts)) continue;   /* -b interval:对齐墙钟切文件 */
```

```c
// dumpcap.c:4751-4774(capture_loop_wrote_one_packet,数据驱动)
if (has_autostop_packets && packets_captured >= autostop_packets) { go=false; }      /* -c */
if (has_autostop_written_packets && packets_captured >= autostop_written_packets) { go=false; }
if (has_file_packets && packets_written >= file_packets) do_file_switch_or_stop(...); /* -b packets */
if (has_autostop_filesize && autostop_filesize>0 &&
    bytes_written/1000 >= autostop_filesize) do_file_switch_or_stop(...);             /* -a/-b filesize */
```

注意 filesize 的单位是 kB 且以 `bytes_written/1000` 判断(4768-4770),并在主循环启动前钳到 2,000,000,000 kB(4256-4259);`-b interval` 用 get_next_time_interval 对齐整分整秒(dumpcap.c:3971-3976)。do_file_switch_or_stop(3980-4039)先看 `-a files:N` 是否用尽(3986-3991,用尽则整体停止),再 ringbuf_switch_file(ringbuffer.c:304)、清零计数(3998-3999)、重写 pcapng SHB/IDB 或 pcap 文件头(4000-4007)、重置计时器(4015-4020)、向前端发新 'F'(4027)。

命名(ringbuffer.c:104-119):`%05u` 序号 = (当前号+1) % 100000;时间戳 `%Y%m%d%H%M%S` 本地时间;nametimenum(b 输出 nametimenum:2,capture_sync.c:790-795)决定序号/时间顺序。ringbuf_init(140-242)负责拆前缀/后缀并识别压缩扩展名(186-206);`-b files:0` 表示不限量、只保留不断递增的文件(ringbuffer.h:18;ringbuffer.c:221-224);文件权限 0600(-g 时 0640,ringbuffer.c:127-128)。ring buffer 与 stdout/命名管道互斥(dumpcap.c:3799-3805)。

## 7. 停止条件与统计回传

条件类型只有五种加信号:**-c 包数、-a duration 时长、-a/-b filesize、-b packets、-b/-a files,以及 -b interval 对齐切换**;全部是普通布尔判断,没有独立条件对象(见第 1 节纠偏 1)。触发停止统一置 `global_ld.go=false`,dispatch 回调看到后停写;外部停止:Unix 靠信号(SIGTERM/SIGINT→capture_cleanup_handler,dumpcap.c:5330-5335→capture_loop_stop 4663-4675→pcap_breakloop),Windows 靠父进程经信号管道写入任意字节,dumpcap 每轮循环 PeekNamedPipe 探测(6322-6360),父进程死亡/管道断即停。

统计回传分三层:

1. **进度**:'P' 消息。主循环只在 update_interval(默认 100ms,可用 --update-interval 调,dumpcap.c:5513)到期时才 flush+上报累积的 inpkts_to_sync_pipe(4348-4382),注释明说是为了"不过载慢显示、减少两进程上下文切换";
2. **丢包**:捕获结束时逐接口 `pcap_stats()` 取 ps_drop,加上 dumpcap 自身 dropped/flushed,合成 `总丢包:接口名` 发 'D'(4600-4622, 6293-6315);单接口 pcapng 结束时另写 ISB(3553-3585,"Counters provided by dumpcap");
3. **-S 模式**:dumpcap 独立以 `pcap_open_live(name, MIN_PACKET_SIZE, 0, 0)` 打开全部接口(dumpcap.c:1163 附近),每秒 `pcap_stats` 打印 `接口 收包 丢包`(1150-1160),机器可读模式为 `name\trecv\tdrop`(1157),永不退出(1177 注释)。

## 8. 设计动机、FAQ、深挖与蒸馏

设计动机(源码证据):
1. **权限面最小化**:全仓库只有 dumpcap 碰 libpcap,GUI 无 pcap_ 调用;特权窗口压到 activate 前后(dumpcap.c:3263-3272, 5347-5418)。
2. **崩溃与安全隔离**:解析器/GUI 在另一进程,dumpcap 仅 6374 行、无 dissectors,攻击面小;libcap 路径连 root 的文件权限都主动放弃(dumpcap.c:5358-5365)。
3. **节奏解耦**:100ms 批量上报防止 UI 拖慢抓包热路径(dumpcap.c:4348-4353 注释)。
4. **多接口统一抽象**:强制线程+pcapng,每接口独立 IDB,pcapng 直通时 SHB 原样透传(dumpcap.c:3066-3081, 3244-3261, 5731-5734)。
5. **文件即接口**:前端只认文件名,崩溃后文件仍在;'F' 推迟到首个 SHB 落盘后发送,保证前端打开即可读到头(dumpcap.c:4831-4836)。
6. **零依赖自制协议**:1+3 字节定长头,单写单读,注释里明确否决了 Thrift/Protobuf(sync_pipe.h:40-46)。
7. **背压可控**:GAsyncQueue + 字节/包双上限(-C/-N),超限丢新包保内存(dumpcap.c:121-125, 423-430, 5679-5687)。

FAQ 候选(一句话答案):
1. dumpcap 为什么能 suid 而整个 Wireshark 不 suid?——因为唯一需要 NET_RAW 的 libpcap 调用都封装在这个小进程里,且它在打开设备后立即降权(dumpcap.c:3263-3272)。
2. 隐藏选项 -Z 是什么?——声明 capture_child 模式:输出改为"1B 类型+3B 长度+正文",参数是 sync pipe 的 fd(默认 2)或 Windows 句柄(dumpcap.c:5204-5226)。
3. GUI 和 dumpcap 之间有几条管道?——活动捕获只有 1 条消息管道(Unix)加 1 条命名信号管道(Windows);stdout 数据管道只在 -D/-L 等一次性查询时创建(capture_sync.c:971-975 vs 1076)。
4. 捕获的包会流经 GUI 进程吗?——不会,dumpcap 直接写文件,GUI 尾读文件,管道只传文件名与计数。
5. 前端何时开始读文件?——收到 'F' 之后;pcapng 直通模式该消息被推迟到第一个 SHB 写盘(dumpcap.c:4831-4836)。
6. BPF 在哪编译、失败了怎么办?——dumpcap 内 pcap_compile+pcap_setfilter(3340),失败发 'B',前端尝试按显示过滤器解析以给出提示(capture_sync.c:2014-2026)。
7. 多接口为什么强制 pcapng?——pcap 头只有一个 linktype,无法表达每接口 IDB(dumpcap.c:3480-3482)。
8. ring buffer 最多几个文件、名字长什么样?——上限 100000,名字如 `cap_00001_20260919123000.pcapng`(ringbuffer.h:23;ringbuffer.c:109-118)。
9. 丢包数从哪来?——pcap_stats 的 ps_drop 加 dumpcap 自身 dropped/flushed/ps_ifdrop,结束时按接口发 'D'(dumpcap.c:6294-6315)。
10. Windows 上父进程怎么叫停 dumpcap?——向 `\\.\pipe\wireshark.<pid>.signal` 写入字节,dumpcap 每轮循环 PeekNamedPipe 检查(dumpcap.c:6322-6360;sync_pipe.h:138)。

深挖方向:
1. 捕获管道(cap_pipe)状态机:stdin/FIFO 上的 pcap/pcapng 解析、Windows cap_thread_read + pending/done 双队列(dumpcap.c:312-382, 1642-1713)。
2. 多线程背压与丢包语义:GAsyncQueue 超限策略、WRITER_THREAD_TIMEOUT=100ms(dumpcap.c:463, 4062-4110)。
3. Windows 专项:wpcap 动态加载(capture/capture-wpcap.c:54-95 函数指针表)、_open_osfhandle 句柄↔fd 双向转换。
4. extcap FIFO 如何伪装成捕获接口进入同一管线(capture_sync.c:848-860;dumpcap 端按 cap_pipe 处理)。
5. 无线:-I monitor mode 能力探测与 -k 设信道(capture-pcap-util.c:1594-1667;dumpcap.c:5886-5899;capture/ws80211_utils.c)。

### 正文蒸馏要点

1. dumpcap 以隐藏选项 -Z 进入 capture_child 模式,该模式必须在参数解析前确定,因为它改变所有后续输出的格式(dumpcap.c:5159-5235)。
2. 消息管道协议为 1 字节类型 + 3 字节大端长度 + 正文,类型是单字符 'F/P/D/E/W/B/S/L/X'(sync_pipe.h:47-62;sync_pipe_write.c:27-40)。
3. 主捕获路径用 pcap_create→pcap_set_snaplen(1768)→pcap_set_promisc(1779)→pcap_set_timeout(1787,250ms)→pcap_set_buffer_size(1836,默认 2MB)→pcap_activate(1855) 的新式序列(capture/capture-pcap-util.c)。
4. BPF 过滤器在 dumpcap 内 pcap_compile(dumpcap.c:799)+pcap_setfilter(3340),捕获管道输入不支持 BPF(dumpcap.c:3332)。
5. 无 libcap 时降权(setuid 回 ruid)发生在打开输入源之后、主循环之前;libcap 时启动保留 NET_RAW/NET_ADMIN、activate 后清全部能力(dumpcap.c:3268-3272, 5422-5427)。
6. 活动捕获不建数据管道:dumpcap 直接写捕获文件,前端经 'F' 获知文件名后尾读;数据管道仅服务 -D/-L 一次性查询(capture_sync.c:971-975, 1065-1077)。
7. 前端进度来自 'P' 消息,默认 100ms 一批,由 update_interval 控制;丢包统计在捕获结束时以 'D' 按接口上报(dumpcap.c:4372-4382, 4600-4622;capture_opts.c:121)。
8. 停止条件全部内联于 dumpcap.c:时长/interval 在主循环 update 分支(4385-4403),包数/文件大小在每包回调(4740-4775);v4.7.3 无 capture_stop_conditions 模块(全树 grep 零命中)。
9. ring buffer 切换由 filesize/duration/interval/packets 四条件触发,切换时重写文件头并重置计时器,`-a files:N` 用尽即整体停止(dumpcap.c:3980-4039);文件名 = 前缀 + %05u 序号 + 本地时间戳(ringbuffer.c:109-118)。
10. 多接口捕获强制 use_threads + pcapng:每接口一个读线程推 GAsyncQueue,主循环单写者消费(dumpcap.c:4283-4311, 5731-5734)。
11. Unix 停止靠信号→pcap_breakloop,Windows 靠命名信号管道+每轮 PeekNamedPipe 探测父进程存亡(dumpcap.c:4663-4675, 6322-6360)。
12. GUI(ui/capture.c)与 tshark(tshark.c:3065)共用 capture_sync 一套 spawn/解析代码,前端不含任何 libpcap 调用——这是"权限分离"架构的守门处。
