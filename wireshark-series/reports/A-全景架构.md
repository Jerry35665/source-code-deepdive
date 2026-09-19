# 报告 A · 全景架构(Wireshark)

> 基线:tag v4.7.3,commit f6e0bf224bdabf5f09b897da64fe6b10c66173d4(本地 `git log -1` 核实,提交题为 "Build: Wireshark 4.7.3 and Stratoshark 0.10.3",同一提交上同时打了 `v4.7.3` 与 `ssv0.10.3` 两个 tag)。
> 一句话总结:Wireshark 是"三库(epan/wiretap/wsutil)+ 多前端(Qt GUI、tshark、strato、sharkd…)+ 一个特权隔离的抓包子进程 dumpcap"的组合——数据面走临时捕获文件、控制面走同步管道;全部解析能力集中在 epan(1700 个 dissector),全部抓包能力集中在 dumpcap(不链 epan/wiretap)。

---

## 一、顶层目录地图(经 ls 核实)与程序家族

根目录即"多程序单仓":16 个程序入口 `.c` 直接放在仓库根——tshark.c、dumpcap.c、strato.c、tfshark.c、rawshark.c、sharkd.c、capinfos.c、captype.c、editcap.c、mergecap.c、text2pcap.c、randpkt.c、reordercap.c、dftest.c、mmdbresolve.c、extcap.c(ls 逐项核实);另有前端共享逻辑 file.c / fileset.c / ringbuffer.c(dumpcap 环形缓冲)/ extcap_parser.c 等。子目录定位一句话:

| 目录 | 定位(一句话) |
|---|---|
| `epan/` | 核心协议引擎:1700 个协议 dissector(epan/dissectors 下 `packet-*.c` 恰 1700 个,`ls | grep -c` 核实)、字段树 proto_tree、dfilter 显示过滤、tvbuff 缓冲抽象、wmem 内存池、tap 统计 |
| `wiretap/` | 捕获文件读写库:87 个 `.c`(ls 核实),含 pcap/pcapng 及百余种专有格式,注册入口 wtap_register_file_type_subtype |
| `writecap/` | 捕获文件**写**侧独立小库(pcapio.c),专供 dumpcap 使用(writecap/CMakeLists.txt:21) |
| `capture/` | 前端侧"抓包子进程控制":capchild/caputils/iface_monitor 三静态库 + 同步管道(capture/CMakeLists.txt:36,73,90) |
| `ui/` | UI 抽象层(静态库 ui,ui/CMakeLists.txt:79):capture.c(抓包控制)、capture_opts、tap-* 统计分析等;子目录 cli/qt/stratoshark/macosx/win32/stylesheets(ls 核实,**无 gtk**) |
| `ui/qt/` | Qt 版 GUI 全部源码(main.cpp、wireshark_main_window_slots.cpp、各对话框 .ui) |
| `extcap/` | 外置捕获工具源码:androiddump/sshdump/ciscodump/dpauxmon/wifidump/udpdump/etwdump/sdjournal/falcodump 等 11 个(extcap/ ls 核实) |
| `plugins/` | 仓内自带插件:epan 类 14 个(dfilter、mate、opcua、profinet、falco_events…)、codecs 类 11 个、wiretap 类 1 个(usbdump)、ui 类 1 个(plugins/ ls 核实) |
| `doc/` | man_pages/ 下 35 个 adoc 手册(ls 核实);README.developer/README.dissector/README.capture/README.design 等开发文档;用户/开发者指南源 wsug_src、wsdg_src |
| `tools/` | 开发辅助脚本(python/perl/shell:check_apis.py、asn2deb、bsd-setup.sh 等,ls 核实) |
| `test/` | pytest 回归套件(test/README.test,ls 核实);`fuzz/` 为 fuzzshark 模糊测试入口(fuzz/fuzzshark.c) |
| `packaging/` | 平台打包:appimage/debian/macosx/msys2/nsis/portableapps/rpm/source/wix(packaging/ ls 核实) |
| `cmake/` | 构建模块:modules/ 下数十个 Find*.cmake(FindPCAP、FindLUA…,ls 核实) |
| `include/` | 对外公共头:wireshark.h、ws_symbol_export.h、ws_attributes.h 等(include/ ls 核实) |
| `app/` | "应用风味"抽象:wireshark_flavor.c 与 stratoshark_flavor.c + application_flavor.h(app/ ls 核实) |
| `wka/`、`fix/` | FIX 协议词典 XML(fix/ 下 FIX40.xml 等,ls 核实) |
| `libpcap/` | 内嵌 libpcap **头文件垫片**(libpcap/pcap/bpf.h、dlt.h、bluetooth.h 等,ls 核实),构建 dissectors 时无需真实 libpcap 头 |
| `randpkt_core/` | randpkt 的共享实现(randpkt.c 引用,ls 核实) |

**程序家族与目标定义**(均在顶层 CMakeLists.txt,行号逐一核实):

| 程序 | add_executable | 链接库 | 一句话定位 |
|---|---|---|---|
| wireshark(Qt GUI) | 行 3303 | ui, qtui, uiqt_plugin, capchild, caputils, iface_monitor, wiretap, epan, summary(行 3277-3291) | 主 GUI,经 dumpcap 抓包 |
| stratoshark(Qt GUI) | 行 3423 | 同族 + 系统事件源 | 系统事件"挖掘"GUI |
| tshark | 行 3595 | ui, capchild, caputils, wiretap, epan, iface_monitor, wsutil(行 3573-3583) | 命令行版 Wireshark |
| strato | 行 3624 | 同 tshark 族(行 3611-3621) | "Text-mode variant of Stratoshark… Adapted from tshark.c"(strato.c:3-5) |
| tfshark | 行 3647 | — | 实验性,默认 OFF(CMakeOptions.txt:9) |
| rawshark | 行 3668 | — | "Opens a specified file or named pipe" 做字段抽取(rawshark.c:16-19) |
| sharkd | 行 3694 | — | "Daemon variant of Wireshark"(sharkd.c:3) |
| dumpcap | 行 3916 | writecap, wsutil_static, pcap(行 3870-3879) | 唯一抓包进程 |
| editcap / mergecap / text2pcap / capinfos / captype / randpkt / reordercap / dftest / idl2wrs / mmdbresolve | 行 3862 / 3781 / 3762 / 3821 / 3842 / 3737 / 3800 / 3713 / 3966 / 4013 | wsutil 等 | 捕获文件加工、信息、生成与辅助 |
| extcap 家族(androiddump、sshdump、ciscodump、dpauxmon、randpktdump、wifidump、udpdump 等) | CMakeOptions.txt:24-43 开关 | extcap/ 源码 | 经外部进程/远程方式取"类包"数据 |

## 二、三大库划分:CMake target(带行号)

三大动态库均为 `add_library` + `set_target_properties`;**本仓不存在 `SetLibraryProperties` 函数**(在 cmake/ 全目录及各 CMakeLists.txt grep 无匹配,已核实)。

```cmake
# epan/CMakeLists.txt:265-290(节选)
add_library(epan
        ...
        $<TARGET_OBJECTS:crypt>
        $<TARGET_OBJECTS:dfilter>
        $<TARGET_OBJECTS:dissectors>
        $<TARGET_OBJECTS:dissectors-corba>
        $<TARGET_OBJECTS:dissector-registration>
        $<TARGET_OBJECTS:ftypes>
        $<$<BOOL:${LUA_FOUND}>:$<TARGET_OBJECTS:wslua>>
        ...)
set_target_properties(epan PROPERTIES
        OUTPUT_NAME "wireshark" PREFIX "lib" ...)  # 行 287-289 → libwireshark
```

- **libwireshark = epan target**:epan/CMakeLists.txt:265 定义;OUTPUT_NAME "wireshark"(行 287-289);内部由 crypt/dfilter/dissectors/dissectors-corba/dissector-registration/ftypes/wslua 七个对象库拼装(行 265-278)——即"1700 个 dissector"物理上编进这一个对象库组。
- **libwiretap**:wiretap/CMakeLists.txt:182 `add_library(wiretap ...)`,行 187-194 设 VERSION/SOVERSION 与 FOLDER "DLLs"。
- **libwsutil**:wsutil/CMakeLists.txt:384 `add_library(wsutil ...)`(行 396-403 设属性),另有静态变体 `wsutil_static`(行 461);它是基础工具层,被 wiretap PUBLIC 链接(wiretap/CMakeLists.txt:202-204)、被 epan PUBLIC 链接(epan/CMakeLists.txt:293-295)。
- **依赖方向**:epan PRIVATE 依赖 wiretap(epan/CMakeLists.txt:296-298)——解析引擎需要读文件能力,但 wiretap/epan 都不需要"抓网卡"能力,后者只在 dumpcap 与 capchild 里。
- **支撑静态库**:ui(ui/CMakeLists.txt:79)、summary(ui/CMakeLists.txt:94)、caputils/capchild/iface_monitor(capture/CMakeLists.txt:36,73,90)、writecap(writecap/CMakeLists.txt:21)。

库依赖方向(ASCII,行号见上):

```
epan ──PUBLIC──> wsutil            (epan/CMakeLists.txt:293-295)
 │ PRIVATE                         (epan/CMakeLists.txt:296-298)
 └────> wiretap ──PUBLIC──> wsutil (wiretap/CMakeLists.txt:202-204)

前端(wireshark/tshark/strato)──> ui + capchild + caputils + epan + wiretap
dumpcap ────────────────────────> writecap + wsutil_static + libpcap(不过 epan/wiretap)
```

注意"抓包能力"是构建期显式条件:`ENABLE_PCAP` 关闭或找不到 libpcap 时,dumpcap 直接不建并告警 "Dumpcap was requested but libpcap dependency is not available. Wireshark will be built without packet capture capability."(CMakeLists.txt:3952-3955)——即整个产品可退化为"纯离线分析器"。

## 三、进程模型:为什么抓包必须单独一个 dumpcap

**(1) 权限最小化动机**,README.md:66-72 原文:

```
In order to capture packets from the network, you need to make the
dumpcap program set-UID to root ... Although it might be tempting to
make the Wireshark and TShark executables setuid root, or to run them as
root please don't.  The capture process has been isolated in dumpcap;
this simple program is less likely to contain security holes and is thus
safer to run as root.                                  (README.md:67-72)
```

**(2) 性能动机(两任务模型)**,doc/README.capture:59-63:捕获进程(须避免丢包)与解析显示进程(可能很慢)强制分离;子进程循环"取包→写盘→定期发 new packets 消息"(doc/README.capture:69-73),父进程收到消息后才从文件读包解析显示(行 75-77)。

**(3) dumpcap 自身的特权处理总注释**,枚举 6 种运行场景,策略统一为"打开 pcap 后立即弃权":

```
/* Privilege and capability handling                                 */   /* dumpcap.c:5348 */
/* 1. Running not as root or suid root; no special capabilities.     */
/* 3. Running logged in as root (euid=0; ruid=0). Using libcap.      */
/*      ... after pcap_open_live() in capture_loop_open_input()      */
/*         drop all capabilities (NET_RAW and NET_ADMIN);            */   /* dumpcap.c:5356-5360 */
/* 4/5. suid root 场景:同样在 pcap_open_live 之后 drop suid/能力       */   /* dumpcap.c:5370-5406 */
/* ToDo: -S (stats) should drop privileges/capabilities ...          */   /* dumpcap.c:5415   */
```

六场景分别对应:非特权、root、root+libcap、suid root、suid+libcap、文件能力 cap_net_raw/cap_net_admin(dumpcap.c:5349-5410)。

**(4) 前端如何拉起 dumpcap**——所有前端共用同一条链:

- Qt GUI:ui/qt/wireshark_main_window_slots.cpp:955 及 ui/qt/main.cpp:1072(命令行 `-k`)调用 `capture_start()`;
- `capture_start()` → `sync_pipe_start()`(ui/capture.c:114,128);
- tshark 实时抓包同样直接调 `sync_pipe_start()`(tshark.c:3065)——**tshark 与 GUI 的抓包路径完全一致**;
- fork/exec 参数在 capture/capture_sync.c:255-296 构造:`init_pipe_args()` 以 `get_executable_path("dumpcap")` 定位子程序(行 260-261),`sync_pipe_open_command()` 打开两条管道:数据 stdout + 日志 stderr(行 309-311 注释;Windows 下无 fork,行 596-600 注释 "Child process - run dumpcap")。

**(5) dumpcap 的链接集合证明其"小"**:

```cmake
# CMakeLists.txt:3870-3879
set(dumpcap_LIBS
        writecap
        wsutil_static
        pcap::pcap
        ${CAP_LIBRARIES}        # libcap(可选)
        ${NL_LIBRARIES} ... )
```

即 dumpcap 只链 writecap + wsutil + libpcap,**不链 epan、不链 wiretap**——纯采集器、零解析能力;安装期按发行版配置权限位(DUMPCAP_SETUID)或文件能力 `setcap cap_net_raw,cap_net_admin+ep`(CMakeLists.txt:3897-3915)。

## 四、版本与构建

- **版本定义**:顶层 CMakeLists.txt:32 的 `project(${_project_name} C CXX)` **没有** VERSION 关键字;版本用 set 拼装:

```cmake
# CMakeLists.txt:162-172
set(PROJECT_MAJOR_VERSION 4)
set(PROJECT_MINOR_VERSION 7)
set(PROJECT_PATCH_VERSION 3)
set(PROJECT_BUILD_VERSION 0)
set(PROJECT_VERSION_EXTENSION "")
set(PROJECT_VERSION "${PROJECT_MAJOR_VERSION}.${PROJECT_MINOR_VERSION}.${PROJECT_PATCH_VERSION}${PROJECT_VERSION_EXTENSION}")
```

同处定义 Stratoshark 版本 0.10.x(行 174-177);这些值经 configure 注入 `WIRESHARK_VERSION_MAJOR/MINOR/MICRO`(ws_version.h.in:6-8);开发构建默认标记 "Development Build"(行 554-557)。
- **代表性构建选项**(CMakeOptions.txt):程序开关 `BUILD_wireshark ON`(行 5)、`BUILD_stratoshark OFF`(行 6)、`BUILD_tshark ON`(行 7)、`BUILD_tfshark OFF`(行 9)、`BUILD_dumpcap ON`(行 11)、`BUILD_sharkd ON`(行 53);能力开关 `ENABLE_PCAP`(行 90,注明 "required for capturing")、`ENABLE_PLUGINS`(行 93);压缩族 `ENABLE_ZLIB/ZLIBNG/LZ4/BROTLI/SNAPPY/ZSTD`(行 96-104);编解码与脚本族 `ENABLE_LUA`(行 107)、`ENABLE_SBC/BCG729/OPUS...`(行 125-131)、`ENABLE_SINSP`(行 132,Stratoshark 的系统事件源);质量开关 `ENABLE_WERROR`(行 57)、`ENABLE_ASAN/TSAN/UBSAN`(行 70-73)。
- **平台支持**:README.md 自述 "for Linux, macOS, *BSD and other Unix and Unix-like operating systems and for Windows. It uses Qt… and libpcap and npcap as packet capture and filtering libraries"(README.md:2-5);平台专属 README:README.bsd、README.linux、README.macos、README.msys2(Windows/MSYS2 构建)、README.DECT(ls 核实;无 README.windows/solaris 专文,Windows 构建指引在 README.msys2 与开发者指南)。
- **Windows 抓包依赖的版本被钉死在构建脚本里**:Npcap 1.88、USBPcap 1.5.4.0(CMakeLists.txt:354,366)——即官方 Windows 包自带抓包驱动安装器,这也是"libpcap/npcap 是外部依赖而非本仓代码"的旁证(libpcap/ 目录只放头文件垫片,见第一节)。
- **打包与预设**:CMakePresets.json 在仓库根(ls 核实,预设化构建入口);packaging/ 覆盖 appimage/debian/macosx/msys2/nsis/portableapps/rpm/wix 九类(packaging/ ls 核实),与第 6 节程序家族共同说明"单仓多平台发行"的工程形态。

## 五、数据流总图(ASCII)与逐环节证据

```
                          网卡 NIC
                             │ libpcap/npcap(README.md:4-5)
                             ▼
┌────────── dumpcap.c:独立进程,唯一持特权者(CMakeLists.txt:3870-3879) ──────────┐
│  capture_loop:pcap_open_live → BPF 捕获过滤 → ringbuffer.c 环形分文件           │
│  → writecap/pcapio.c 写临时捕获文件(doc/README.capture:72)                    │
└──────┬───────────────────────────────────────────────────┬──────────────────┘
       │ 控制面:同步管道单字符消息                            │ 数据面:临时 pcap/pcapng 文件
       │  'F'新文件名  'P'包计数  'D'丢包  'E'错误  'X'失败    │ (doc/README.capture:72-73)
       │  (capture/sync_pipe.h:47-62)                     │
       ▼                                                   ▼
┌─ 前端进程:wireshark(Qt)/ tshark / strato ── wiretap 读文件 ──────────────────┐
│  ui/capture.c:capture_input_read_all(:230) → wtap_read(:514)              │
│   ├ 轻量协议计数:try_capture_dissector(ui/capture.c:519,供 Capture Info)   │
│   └ 完整解析:epan_dissect_run(epan/epan_dissect.c:755) → dissect_record(:764)│
│        → 帧 dissector(epan/packet.c:760)→ 协议 dissector 调用链(:990)      │
│        → proto_tree 字段树 + expert 信息 + tap 统计(epan/proto.c;epan/tap.c)│
│   ├ 显示过滤器引擎 epan/dfilter/;着色规则 epan/color_filters.c              │
│   ▼                                                                       │
│  输出:Qt 包列表/协议树/字节视图 │ tshark 文本·JSON(tshark.c:270,3299 单双遍) │
└────────────────────────────────────────────────────────────────────────────┘
 离线变体:rawshark 对"文件或命名管道"按 DLT/decode-as 抽字段(rawshark.c:16-19)
```

逐环节证据链:
1. GUI 点击开始 → `capture_start`(ui/qt/wireshark_main_window_slots.cpp:955)→ `sync_pipe_start`(ui/capture.c:128)。
2. dumpcap 被定位并拉起(capture/capture_sync.c:261),以自身参数集运行,写盘用 writecap/pcapio。
3. 子进程经管道上报 'F'(新捕获文件名)、'P'(新增包数)、'D'(丢包数)等(capture/sync_pipe.h:48-56;发送侧 dumpcap.c,语义注释同文件)。
4. 前端收到 'P' 后批量 `wtap_read` 临时文件(ui/capture.c:514),先用 capture dissector 做**计数**直方图(ui/capture.c:519-527),再完整解析。
5. 完整解析入口 `epan_dissect_run` → `dissect_record`(epan/epan_dissect.c:755-764),由帧 dissector(epan/packet.c:760)逐层 `call_dissector_work`(epan/packet.c:990)构造 proto_tree。
6. 显示过滤与着色在树建好后应用:引擎在 epan/dfilter/(目录 ls 核实),着色规则在 epan/color_filters.c(ls 核实);tshark 侧按需决定是否建树(tshark.c:3264-3299)。

两条离线支线(与 dumpcap 无关):
- tshark 读既有文件时走单遍或双遍处理:`process_packet_single_pass`(tshark.c:270,入口 `epan_dissect_new` 在 tshark.c:3299)与 `process_packet_first_pass/second_pass`(tshark.c:3498,3752);双遍是为统计与"全部显示过滤"服务的补树。
- 加工工具(editcap/mergecap/capinfos/captype/reordercap/text2pcap)只依赖 wiretap 对文件格式做转码/合并/索引,不触碰 libpcap 与网卡(各目标链接表见 CMakeLists.txt:3781-3862 一带;此推断基于链接库集合,函数级未逐一核实)。

## 六、设计动机与纠偏

**设计动机列表:**
1. 特权最小化:全系统只有 dumpcap 需要抓包特权,把高风险面缩到一个"简单程序"(README.md:72)。
2. 防丢包:捕获进程与耗时的解析/显示进程分离,互不阻塞(doc/README.capture:61-63)。
3. 代码复用:tshark/wireshark/strato 共享同一 ui 库与 epan 引擎,三处链接表同族(CMakeLists.txt:3277-3291,3573-3583,3611-3621)。
4. 弃权窗口最小:dumpcap 在 pcap_open_live 成功后立即 drop 全部特权/能力(dumpcap.c:5356-5360)。
5. 面分离:控制消息(单字符)与包数据(文件)走不同通道,管道只传元信息,不传载荷(capture/sync_pipe.h:47-62)。
6. 引擎可插拔:epan 由 dissectors/dfilter/ftypes/crypt/wslua 对象库拼装,再叠加运行时 plugins 与 extcap 外进程(epan/CMakeLists.txt:265-278;CMakeOptions.txt:93)。
7. 单仓多程序共生:同一提交同时产出 Wireshark 4.7.3 与 Stratoshark 0.10.3,二者共享 epan/wiretap/ui 与"应用风味"抽象 app/(git log -1;app/ ls 核实),避免两产品源码漂移。

**纠偏(以本 tag 源码为准):**
1. ❌"epan/wiretap 用 SetLibraryProperties 设置属性"——本仓无此函数,实为 `add_library` + `set_target_properties`(epan/CMakeLists.txt:265,281;wiretap/CMakeLists.txt:182,187;grep 全 cmake/ 无匹配)。
2. ❌"wiretap 有 190 个捕获文件格式"——本 tag 各格式模块调用 `wtap_register_file_type_subtype` 共 **103 处**(grep wiretap/*.c 计数;注册函数定义 wiretap/file_access.c:1174),wiretap/ 共 87 个 .c。
3. ❌"epan 含抓包能力"——抓包全在 dumpcap;epan 的 `capture_dissectors` 只是对原始字节做轻量协议**计数**的机制(epan/capture_dissectors.h:38,106-113),且在前端读临时文件时调用(ui/capture.c:514-527);dumpcap 根本不链接 epan(CMakeLists.txt:3870-3879)。
4. ❌"Qt GUI 直接调 libpcap 抓包"——GUI 最深只到 `capture_start`→`sync_pipe_start`(ui/qt/wireshark_main_window_slots.cpp:955 → ui/capture.c:128),open 网卡的是子进程 dumpcap。
5. ❌"仍有 GTK 前端"——ui/ 下仅 cli/macosx/plugins/qt/stratoshark/stylesheets/win32,无 gtk 目录(ls 核实)。
6. ❌"版本由 project(VERSION) 声明"——project() 无 VERSION 关键字(CMakeLists.txt:32),版本在行 162-177 set 拼装。

## 七、FAQ 候选与深挖方向

**FAQ 候选 10 条(每条一句话):**
1. Q:为什么抓包要单独一个 dumpcap 进程?A:特权最小化(防解析器漏洞波及 root)+ 防丢包(采集与显示解耦)双重动机(README.md:72;doc/README.capture:61-63)。
2. Q:libwireshark 对应哪个 CMake target?A:epan,OUTPUT_NAME "wireshark" + PREFIX "lib"(epan/CMakeLists.txt:265,287-289)。
3. Q:tshark 抓包与 GUI 有何不同?A:没有不同,同样 sync_pipe_start 拉起 dumpcap(tshark.c:3065;ui/capture.c:128)。
4. Q:dumpcap 与前端之间传包数据吗?A:不传,数据走临时捕获文件,管道只传 'F'/'P'/'D'/'E' 等单字符控制消息(capture/sync_pipe.h:47-62;doc/README.capture:72-77)。
5. Q:版本号 4.7.3 定义在哪?A:CMakeLists.txt:162-172 set 拼装,再注入 ws_version.h.in:6-8。
6. Q:dumpcap 拿到 root 后何时放手?A:pcap_open_live 打开成功后立即丢弃全部特权/能力(dumpcap.c:5346-5419,尤其 5356-5360)。
7. Q:有多少协议 dissector 与多少捕获文件格式?A:epan/dissectors 下 1700 个 packet-*.c(ls 计数);wiretap 注册 103 种文件类型子类型(grep 计数)。
8. Q:rawshark 凭什么能读管道?A:其自述"Opens a specified file or named pipe",按指定 DLT/decode-as 解封装后抽字段(rawshark.c:16-19)。
9. Q:Stratoshark 是这个仓库的一部分吗?A:是,strato.c 改编自 tshark.c,同一提交发 Wireshark 4.7.3 与 Stratoshark 0.10.3(strato.c:3-5;git tag v4.7.3/ssv0.10.3)。
10. Q:Linux 上如何给 dumpcap 授权?A:安装期二选一:保留 setuid 权限位(DUMPCAP_SETUID)或 setcap cap_net_raw,cap_net_admin+ep(CMakeLists.txt:3897-3915)。

**深挖方向 5 条:**
1. dissector 分发机制:proto_register/dissector table 注册与 `call_dissector_work` 调用链(epan/packet.c:63 起的表结构,990 起的分发),抽样解剖 2-3 个 packet-*.c 的注册模式。
2. 显示过滤器引擎:epan/dfilter/ 的编译-执行管线,以及 `create_proto_tree` 按需建树的优化(tshark.c:3264-3299)。
3. dumpcap 内核侧:capture_loop 的 ringbuffer 分文件、-b/-a 停止条件与 pcapio 写盘路径(dumpcap.c + ringbuffer.c + writecap/pcapio.c)。
4. 同步管道协议全集与跨平台差异:SP_* 消息语义、Windows 无信号时用第二条管道替代 break 信号(doc/README.capture:90-92;capture/sync_pipe.h:47-62)。
5. sharkd JSON 服务与质量体系:sharkd_session.c 的请求面,test/ pytest 与 fuzz/fuzzshark.c(fuzz/fuzzshark.c,默认 OFF,CMakeOptions.txt:55)。

## 八、正文蒸馏要点

(以下 12 条为后续正文写作的核心论断,均已在源码中复核到行号级。)

1. 仓库是"三库 + 多前端 + 一特权子进程"结构:epan/wiretap/wsutil 三动态库分别定义于 epan/CMakeLists.txt:265、wiretap/CMakeLists.txt:182、wsutil/CMakeLists.txt:384。
2. libwireshark 实为 epan target,OUTPUT_NAME "wireshark"、PREFIX "lib"(epan/CMakeLists.txt:287-289),由 crypt/dfilter/dissectors/ftypes/wslua 等对象库拼成(行 265-278)。
3. 抓包特权的官方立场:不要让 GUI/tshark 提权,只提权 dumpcap,因为它"更简单、更少安全洞"(README.md:67-72)。
4. 两任务模型动机:捕获要防丢包、显示可能很慢,故拆成父子进程(doc/README.capture:59-63)。
5. dumpcap 打开 pcap 后立即丢弃特权,六种运行场景(非特权/root/root+libcap/suid/suid+libcap/文件能力)统一收口(dumpcap.c:5346-5419)。
6. dumpcap 链接表仅 writecap+wsutil_static+libpcap,无 epan/wiretap——纯采集器、零解析能力(CMakeLists.txt:3870-3879)。
7. 前端与 dumpcap 的通道:控制面同步管道单字符消息(capture/sync_pipe.h:47-62),数据面临时捕获文件(doc/README.capture:72-77)。
8. tshark/GUI/strato 的实时抓包完全同构:capture_start → sync_pipe_start → fork dumpcap(ui/capture.c:114,128;tshark.c:3065;ui/qt/wireshark_main_window_slots.cpp:955)。
9. 数据流主干:网卡→libpcap→dumpcap 写盘→wiretap 读→epan_dissect_run→dissect_record→帧/协议 dissector 链→proto_tree→dfilter/着色→输出(epan/epan_dissect.c:755-764;epan/packet.c:760,990)。
10. 规模计数(本 tag 实测):1700 个协议 dissector(`ls epan/dissectors` 计数)、103 个注册的捕获文件类型子类型(grep wiretap/*.c 计数)、wiretap 87 个 .c、man_pages 35 篇。
11. 版本 4.7.3 不走 project(VERSION),而是 CMakeLists.txt:162-177 set 拼装 + ws_version.h.in:6-8 注入;同提交并发 Stratoshark 0.10.3(tag v4.7.3 与 ssv0.10.3 指向同一提交)。
12. 本 tag 无 GTK 前端(ui/ ls 核实);程序家族含 wireshark/stratoshark/tshark/strato/tfshark/rawshark/sharkd/dumpcap/editcap/mergecap/text2pcap/capinfos/captype/randpkt/reordercap/dftest/idl2wrs/mmdbresolve 等目标(CMakeLists.txt:3303-4013)。
