# 第 06 章 · wiretap 与工程质量:双句柄双路径与多层门禁

> 基线:tag `v4.7.3`(commit `f6e0bf22`)。核心:wiretap/file_access.c / pcapng.c / writecap/pcapio.c / fuzz/fuzzshark.c / tools/。

## 6.0 全景:双读路径与格式探测

```
        wtap_open_offline(file_access.c:848)
          │ 管道/stdin 禁随机读(:877-917)
   ┌──────┴────────────────────────┐
   ▼ fh(顺序读)                    ▼ random_fh(随机读,do_random)
 try_open 探测:                    两句柄共享 fast_seek 压缩流索引
 ① magic 表 36 项全扫               (file_access.c:998-1002)
 ② 启发式 39 项按扩展名三遍排序     wth->subtype_seek_read
   (file_access.c:779-826)         例 pcapng 反向扫 sections 恢复字节序
   ▼ 命中者挂 subtype_read          (pcapng.c:3853,3874-3887)
 例 pcapng_read:internal 块自消化,
 遇包块才返回(pcapng.c:3786-3840)
   └──────────► wtap_rec ◄─────────┘
      tshark -2 第二遍 = frame_data_sequence_find + wtap_seek_read(tshark.c:3955-3962)
```

纠偏:wiretap 注册 **102** 个 file type/subtype(去重实测;libpcap.c 的 register_pcap 一家占 7 个 pcap 变体),且**探测顺序≠注册顺序**——探测表 libpcap_open 第 1、pcapng_open 第 2(file_access.c:280-281),类型注册反而先 pcapng 后 pcap,目的是保存对话框以 pcapng 打头(file_access.c:1150-1159)。

## 6.1 wtap 抽象:钩子表而非虚函数

`struct wtap`(wtap_module.h:58-115)挂双句柄 fh/random_fh——动机原文:"We need two independent descriptors for random access, so they have different file positions"(file_access.c:907-913);只有管道/stdin 时显式拒绝随机访问。格式实现各自静态填 `subtype_read/subtype_seek_read` 钩子,核心零虚表开销,配套 sequential_close/close 两级清理(wtap_module.h:79-82)。`wtap_read`/`wtap_seek_read` 是对称薄路径(wtap.c:1864-1953, 2161-2197);压缩文件不能天真 seek,file_wrappers 维护 fast_seek_point 索引、双句柄共享(file_access.c:998-1002; file_wrappers.c:233)。

## 6.2 pcapng:块模型 + 运行时四元组分发表

块类型常量集中在 pcapng_module.h:26-32(SHB/IDB/PB/SPB/NRB/ISB/EPB);分发不是 switch-case,而是运行时注册的函数表,每块类型一个 {read, process, write, options} 四元组(pcapng.c:6647-6691)。SHB 被排除在表外特判——**节的字节序由 SHB 块内 byte-order magic 定义**(pcapng.c:3200-3205);对总长非 4 倍数的坏文件容忍并 ROUNDUP 补齐(:3258-3285)。顺序主循环自消化 internal 块、只外吐包块;多 section 的接口号经 `shb_iface_to_global` 双向映射(pcapng.c:3346, 5124-5129);随机读按偏移反向线性扫 sections 恢复字节序(自认 O(n) 但"sections 不会多",:3865-3887)。经典 pcap 的复杂度在变体识别:标准/交换/纳秒/AIX/Ixia 等一个 switch 分辨(libpcap.c:204-282);pcap-common 做 encap 双向映射与十几种 pseudo-header 读写(pcap-common.c:714-780)。

## 6.3 写侧分工:wiretap 通用 vs dumpcap 私有

通用写钩子表 `wtap_dumper`{add_idb/write/finish} 服务 editcap/tshark/GUI,压缩流不可 seek 靠 writing_must_seek 声明(wtap_module.h:163-202, 225-244)。**dumpcap 完全绕开这条路**:pcapio 在顶层 writecap/(非 wiretap/),头注释三条理由——只有 fd 可用、旧 libpcap/WinPcap 无 pcap_dump_fopen 且跨 CRT、pcap_dump 无错误返回(writecap/pcapio.c:1-17);dumpcap 经 ringbuffer 走 fd 流,实时捕获**默认写 pcapng**(-P 才退回 pcap,dumpcap.c:57, 577-578)。extcap 采集端(ciscodump 等)也直接用 pcapio。

## 6.4 质量体系:pytest 基线 + 按 dissector 模糊 + 脚本门禁

test/ 下 57 个 .py、30+ 个 suite_*.py,主形态是**基线对比**:tshark 输出与 test/baseline/ 逐字节比较,基线重生成命令写在 README.test(test/README.test:12-17)。fuzzshark 按 dissector 拆分:CMake 为 8 个目标各编一个可执行,编译期宏固定目标、以 postdissector 挂载,输入整帧裸字节;预关分片/重组降噪,`WIRESHARK_DEBUG_WMEM_OVERRIDE=simple` 强制简单分配器放大内存错误(fuzz/CMakeLists.txt:17-29; fuzzshark.c:129-137, 230, 344)。门禁是脚本群:checkAPIs.pl(封禁危险函数)、check_typed_item_calls.py(查协议树 API 误用)、git_hooks/commit-codecheck;纠偏:**无 ABI 门禁**(grep abidiff/libabigail 无果);风格统一靠 **uncrustify**(ws-coding-style.cfg:5-9)而非 clang-format。

## 6.5 文档与双产品发布

doc/README.dissector 3,862 行、README.developer 1,001 行,文档重心已迁 Asciidoc(wsdg_src + man_pages 35 个 .adoc,含 strato/stratoshark)。单树双产品:CMake 同时定义 PROJECT_VERSION 4.7.3 与 STRATOSHARK_VERSION 0.10.x,共享 patch 号(CMakeLists.txt:164-177),tag 双轨 v*/ssv*,CI 是 .gitlab-ci.yml(59 个 script 块)。

## 6.6 设计动机

1. **双句柄双路径**:顺序流式扫与随机点读的文件位置必须互不干扰(file_access.c:907-917);
2. **钩子表而非 C++ 虚函数**:87 个格式静态填表,零虚表开销、实现完全隔离(wtap_module.h:79-82);
3. **pcapng 分发表**:新块类型只注册一个四元组,读/处理/写三钩子分离(pcapng.c:6647-6691);
4. **magic+三遍扩展名探测**:强证据优先,弱证据按"声明匹配>无声明>声明了别的"降权(file_access.c:793-815);
5. **dumpcap 私有写路径**:fd-only+ringbuffer 切换+确定错误返回,libpcap 给不了(writecap/pcapio.c:1-17);
6. **探测顺序即排错史**:XML 类须在 MIME 前、VWR 被七格式夹住——顺序本身是回归资产(file_access.c:301-339)。

## 6.7 FAQ

**Q1:为什么 wtap 要两个句柄?**
顺序读与随机读的文件位置必须独立;管道只有一句柄时拒绝随机访问(file_access.c:907-917)。

**Q2:文件进来先试谁?**
先全扫 36 个 magic 探测器,全部 NOT_MINE 才进 39 个启发式(file_access.c:278-384)。

**Q3:SHB 为什么在读循环里特判?**
节的字节序由 SHB 块内 magic 定义(pcapng.c:3200-3205)。

**Q4:tshark -2 第二遍怎么读?**
第一遍记录每帧偏移,第二遍逐帧 wtap_seek_read(tshark.c:3955-3962)。

**Q5:.pcapng.gz 怎么 seek?**
fast_seek 索引,双句柄共享(file_access.c:998-1002)。

**Q6:dumpcap 为什么不用 wiretap 写?**
只有 fd、要 ringbuffer 切换、要确定错误返回(writecap/pcapio.c:1-17)。

**Q7:多 section 接口号冲突吗?**
读取记 shb_iface_to_global 平移表,写出按 section 反向平移(pcapng.c:5124-5129)。

**Q8:fuzzshark 怎么只测目标 dissector?**
每目标一个可执行,编译期宏固定名字挂 postdissector(fuzz/CMakeLists.txt:17-29)。

**Q9:格式 ID 编译期写死吗?**
不是,运行时注册数组下标,重名拒绝、注销槽位可复用(file_access.c:1199-1232)。

**Q10:有 ABI 兼容门禁吗?**
没有;门禁是 checkAPIs 系脚本+git 钩子+测试套件。

## 6.8 小结与深挖方向

本章结论:**wiretap=运行时格式注册表+双句柄双读路径;质量=基线化 pytest+按 dissector 模糊+API 门禁脚本**。深挖:

1. wtap_opttypes 选项系统(TSRESOL/FCSLEN)如何驱动 pcapng 选项解析;
2. file_wrappers 压缩层 fast_seek 点的生成策略与两遍模式性能;
3. pcapng 自定义块 CB_COPY/CB_NO_COPY 与企业 PEN 分发(pcapng.c:6680-6687);
4. merge.c 与 wtap_dump_params 如何继承 SHB/IDB/NRB/DSB(wtap.c:575-660);
5. oss-fuzz 全链路:tools/oss-fuzzshark/build.sh 与 CI fuzz 段的调度。
