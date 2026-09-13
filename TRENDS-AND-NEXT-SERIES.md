# 2025–2026 重大行业变化汇总与走向预测

> ⚠️ 历史记录声明(2026-09-13):本文是第一系列收官与第二系列选型时的快照。文中"GitHub 上传未成功"等遗留事项均已解决(现走 ssh.github.com:443 推送);预算亦已取消。当前全库状态以 [README.md](README.md) 为准。

> 生成:GLM-5.3-Flash,2026-09-10。基于公开报道与行业报告的网络检索汇总(来源见文末),预测部分为分析推断,置信度已逐条标注。

## 一、本年度世界级变化的定位

2025–2026 年对**软件工程行业**而言,发生了一个符合"世界级、对行业产生长远影响"标准的变化:

**AI 编码智能体(Coding Agent)从"辅助补全工具"跃迁为"软件生产的执行主体"。**

这不是一个渐进式改进,而是软件生产行业二十年一遇的范式切换——上一次同级别切换是 2010 年代初"云计算吃掉自建机房"。判据:

1. **收入量级跨越**:Cursor 于 2026 年 2 月达到约 20 亿美元 ARR(估值 99 亿美元);Claude Code 上线约 6 个月达到 10 亿美元 run-rate 收入。一个全新软件品类在 24 个月内做出 10 亿美元级收入,历史上只有极少数先例(浏览器、智能手机 App Store);
2. **企业渗透率**:IDC 与多家机构口径下,全球 45%–60% 的企业已在核心业务流程部署具备自主决策能力的 AI Agent(含编码场景);中国预测口径到 2026 年为 60% 企业部署;
3. **工作形态质变**:2026 年的主导交互从"AI 建议代码、人来写"变为"AI Agent 自主完成整个特性/修复,人做规划与验收"。主流工具收敛为五家:Cursor、Claude Code、OpenAI Codex、GitHub Copilot、Cline(加 Google Antigravity 作为新变量);
4. **角色重定义**:开发者角色从"写代码的人"转变为"管理 AI Agent 的人"——多家来源独立指出"管理 AI Agent 是 2026 年最有价值的技能";初级开发者招聘收缩是各来源共识的最高风险项。

## 二、对行业的五层长远影响(2025–2026 已发生的事实)

| 层 | 变化 | 状态 |
|---|---|---|
| 生产工具 | 编码 Agent 成为 IDE/终端标配,工具市场 70–100 亿美元 | 已发生 |
| 生产关系 | "PR 由 Agent 提交、人做 review"成为大厂默认流程 | 已发生(头部公司) |
| 人才结构 | 初级岗位收缩;新岗位(Agent 开发、AI 评测、RAG/工具链)出现真实招聘需求 | 进行中 |
| 软件供给 | 软件生产成本下降一个数量级 → "长尾软件"爆发(过去不值得一做的定制软件变得可行) | 进行中 |
| 竞争格局 | 模型厂商(Anthropic/OpenAI)向上吃掉 DevTools 市场,传统 IDE 厂商被迫转型 | 已发生 |

## 三、未来走向预测(2026 下半年–2028)

按"准确率"自评从高到低排列(准确率为对"发生与否"的主观置信度,非精确概率):

1. **初级工程师岗位结构性收缩不可逆,但"AI 输出审查者"成为正式职级**(置信度 ~90%)。各家已开始的 junior hiring 冻结不会因经济周期恢复而回弹;code review、安全审计、Agent 输出验收将写入职位描述与职级体系。
2. **编码 Agent 市场两年内收敛到 3–4 家赢家,独立 IDE 品类消失**(置信度 ~85%)。Cursor/Claude Code/Codex 三家吃掉大部分付费份额;IDE 作为独立产品形态退化为 Agent 的宿主(VS Code 已事实上成为 Agent 宿主壳)。
3. **软件工程的核心技能从"写代码"迁移到"系统设计 + 约束表达 + 验证"**(置信度 ~85%)。规格说明(spec)、测试即规格、可验证性成为一级工程学科;这正是本系列八卷反复出现的"约束越确定,设计越激进"在行业层面的投影。
4. **企业级 Agent 平台化:Agent 控制平面(control plane)成为新的基础设施层**(置信度 ~80%)。多 Agent 编排、权限、审计、成本核算将催生独立的基础设施品类(类比 K8s 之于容器);IBM 等已有明确产品动向。
5. **模型厂商与云厂商的垂直整合加深,独立 SaaS 在 Agent 时代被"动作化"重构**(置信度 ~75%)。软件的交付形态从"界面 + API"变为"Agent 可调用的能力 + 少量人类界面"。
6. **开源项目贡献形态改变:AI 生成的 PR 占比显著上升,维护者审查成为开源生态瓶颈**(置信度 ~75%)。大型开源项目将普遍引入"AI 生成标记 + 增强验证"的门禁机制。

一条反直觉判断:**"AI 取代程序员"不会发生,但"AI 取代程序员的工作方式"已经发生**——职业不会消失,而是被重新定义为由人设定约束与目标、由 Agent 执行、由人验证的闭环。本系列八卷的结论("约束越确定,设计越激进")恰是这个新时代的核心工程素养:给 Agent 的约束越精确,产出越可靠。

## 四、数据来源

- [艾瑞咨询:中国企业级 AI Agent 发展洞察报告(2026)](https://report.iresearch.cn/report/202607/4848.shtml)
- [中国 AI Agent 行业研究报告(2026 年 60% 企业部署预测)](https://pdf.dfcfw.com/pdf/H3_AP202503131644339445_1.pdf)
- [2026 Agentic AI 十大发展趋势 - OFweek](https://m.ofweek.com/ai/2026-01/ART-201700-8420-30678222.html)
- [AI Coding Assistant Statistics 2026(Cursor $2B ARR)](https://uvik.net/blog/ai-coding-assistant-statistics/)
- [Claude Code vs Cursor vs Copilot($9.9B 估值 / $1B run-rate)](https://www.mintmcp.com/blog/claude-code-cursor-vs-copilot)
- [Best AI Coding Agents for 2026 - Faros](https://www.faros.ai/blog/best-ai-coding-agents-2026)
- [The Next Two Years of Software Engineering - Addy Osmani](https://addyosmani.com/blog/next-two-years/)
- [How AI Is Changing Software Engineering Careers - Mindrift](https://mindrift.ai/blog/ai-changing-software-engineering)
- [企业级 AI Agent 应用最佳实践报告 - 沙丘社区](https://www.shaqiu.cn/article/zZM5V483VRxb)

---

# 第二系列选型报告

## 一、选型要求回顾

在八大卷(系统软件主线:内存系统→磁盘系统→存储引擎→分布式共识→网络服务→分布式日志→云原生→AI 推理)之后,第二系列应:① 与第一系列互补而非重叠;② 有同等级的"读完后世界观升级"价值;③ **经检索确认各主要平台无同类逐行深读系列**。

## 二、候选评估

| 候选 | 价值 | 现有解读状况(检索结论) | 结论 |
|---|---|---|---|
| PostgreSQL 内核 | 最强(百万行,查询引擎之王) | 中文有大量"源码解析"文章与书,已拥挤 | ✗ 重叠 |
| Chromium | 强 | 官方文档多,深读系列英文已有若干 | ✗ 重叠 |
| **FFmpeg** | 强(多媒体基础设施,音视频行业核心) | 中文有 API 使用文章;**逐模块源码深读系列罕见,且多停留在旧版本(0.x/2.x 时代的 decode 流程),当前架构(新 filter/demuxer 体系)无系统解读** | ✓ 首选 |
| OpenSSL | 中(重要但代码可读性差,受众窄) | 深读极少;但需求密度低 | 备选 |
| Redis 源码(第二系列再来) | — | 与本系列卷一重复 | ✗ |
| PyTorch internals | 强 | 英文有 ephemeral blog 散篇;中文系统性系列缺乏 | ✓ 备选 |
| QEMU | 中高 | 极少;但受众更窄 | 备选 |

## 三、选定:第二系列《多媒体引擎:FFmpeg 深读》

**理由**:

1. **行业地位**:FFmpeg 是音视频行业的地基——B 站/抖音/Zoom/WebRTC 直播的每一帧都经过它;视频行业正处在"AI 生成视频爆炸 → 转码/处理需求同步爆炸"的拐点,与第一系列"AI 推理"卷呼应;
2. **解读空窗已确认**:检索显示中文社区现有 FFmpeg 内容以 API 教程(`av_read_frame`/`avcodec_send_packet` 用法)与 2015 年前后的旧版源码文章为主;针对**当前 master(新 SW filter 架构、chapters/metadata 体系、dnn 滤镜)的系统性逐模块深读系列,各主要平台(掘金/知乎/CSDN/B 站/公众号)未见**;英文社区亦无活跃的同粒度系列;
3. **体量适配**:约 60-80 万行 C,但可聚焦 libavformat/libavcodec/libavfilter/libavutil 四大库的主干,规模与本系列单卷模式匹配(预计 6-8 卷);
4. **与第一系列的叙事衔接**:第一系列讲"计算与存储",FFmpeg 讲"带宽与媒体"——AI 生成内容时代,媒体管线是下一个被 AI 重构的系统层。

**拟定卷目**(供后续会话执行): demux/mux 与 avio → 编解码器框架与 decode 管线 → filter 图 → 音频重采样与 swr → 硬件加速(hwaccel/vaapi/nvdec)→ 封装格式案例(MP4/TS/HLS)→ 工程文化与 FATE 测试。

## 四、遗留事项说明(诚实记录)

- **GitHub 上传未成功**:三次尝试(直连 ×2、gh-proxy ×1)均无法确认内容到达(直连 HTTP 000,代理 404 验证失败);本地 git 仓库已就绪(3 个 commit,含"GLM 生成"标注),在有 GitHub 访问能力的网络中执行 `git push https://github.com/Jerry35665/source-code-deepdive.git main` 即可完成上传;
- 八卷正文本体已全部完成并本地提交,未受上传问题影响。
