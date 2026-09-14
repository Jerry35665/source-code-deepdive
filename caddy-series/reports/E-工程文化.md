# E 章 · 工程文化：xcaddy、caddytest、goreleaser 与"默认安全"

> 调研对象：caddyserver/caddy，commit `56e3a88`（2026-09-13，master）。
> 本文是第五系列卷末章：A–D 章讲了模块系统、HTTPS、HTTP 栈与反代，这一章讲"项目自身"——
> Caddy 怎么构建、怎么测试、怎么发布、怎么把自己默认配置成安全的。

---

## 1. 全景：一个现代 Go 项目的工程四柱

Caddy 的工程体系可以画成四根柱子，每一根都由一两个"少而精"的工具扛起来：

```
                    ┌──────────────────────────────────────────────┐
                    │        Caddy 工程四柱 (commit 56e3a88)        │
                    ├──────────────┬───────────────┬───────────────┤
   构建柱            │   测试柱      │   发布柱       │   安全柱       │
   xcaddy           │   caddytest  │   goreleaser  │   默认安全清单  │
                    │              │   + 提案式发布 │   + 供应链防护  │
├──────────────┤    ├──────────────┤ ├─────────────┤ ├──────────────┤
│ 插件 = Go 包   │    │ 单元: 表驱动   │ │ tag 签名校验  │ │ 自动 HTTPS    │
│ 构建 = import │    │ 集成: 真服务器 │ │ cosign 签名   │ │ admin 只听    │
│       +编译    │    │ fuzz: 7 个目标│ │ SBOM + deb   │ │  localhost   │
│ 标准版 = 空导入│    │ 矩阵: 3 OS +  │ │ sha512 校验   │ │ 默认不信任    │
│  modules/    │    │  10 GOOS 交叉 │ │ 无 CHANGELOG, │ │  X-Forwarded-*│
│  standard    │    │ golangci/    │ │ commit 即日志 │ │ on-demand    │
│              │    │ govulncheck  │ │              │ │  TLS 先 "ask" │
└──────────────┘    └──────────────┘ └─────────────┘ └──────────────┘
        │                 │               │                │
        ▼                 ▼               ▼                ▼
   README.md:145      caddytest/     .goreleaser.yml   admin.go:1453
   standard/imports.go  129 *_test.go  release.yml     SECURITY.md
```

四柱的共同哲学写在贡献指南里：**少依赖、小 PR、测试先行**（.github/CONTRIBUTING.md:38-46），以及协作规则
"PR 必须再由一到两位协作者批准才能合并"（.github/CONTRIBUTING.md:171）。仓库甚至为 AI 编码代理准备了
229 行的项目守则 AGENTS.md（AGENTS.md:1-229），开头一句就是使命宣言："**Every site on HTTPS.**
Caddy is a security-first, modular, extensible server platform."（AGENTS.md:5）。

四柱不是孤立产品选择——它们互相咬合：测试桩自己就是一个"迷你 xcaddy 构建"（见 §3.1）；
发布流水线在产物里再打一份"可复现构建材料"；安全柱的默认值全部可以在测试里被断言（origin 校验有
admin_origin_case_test.go、admin_checkhost_case_test.go 专测）。

---

## 2. xcaddy 专节：插件经济学的构建面

### 2.1 插件 = Go 包，构建 = import + 编译

与 01 章（模块系统）讲的 `RegisterModule` 呼应：插件不是二进制补丁、不是动态库，而是**普通的 Go 包**。
"装插件"等价于"在你的 main 包里写一行空导入再 go build"。README 把 xcaddy 做的事完整摊开（README.md:143-158）：

1. 建目录；2. 复制 `cmd/caddy/main.go`；3. `go mod init caddy`；
4. `go get github.com/caddyserver/caddy/v2@version` 固定版本；
5. 加一行 `_ "import/path/here"` 引入插件；6. `go build -tags=nobadger,nomysql,nopgx`。

而"官方标准发行版"本身也没走后门——它就是这份 main.go 加上一个**纯空导入清单**：

```go
// modules/standard/imports.go:6-19
import (
	// standard Caddy modules
	_ "github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	_ "github.com/caddyserver/caddy/v2/modules/caddyevents"
	_ "github.com/caddyserver/caddy/v2/modules/caddyevents/eventsconfig"
	_ "github.com/caddyserver/caddy/v2/modules/caddyfs"
	_ "github.com/caddyserver/caddy/v2/modules/caddyhttp/standard"
	_ "github.com/caddyserver/caddy/v2/modules/caddypki"
	_ "github.com/caddyserver/caddy/v2/modules/caddypki/acmeserver"
	_ "github.com/caddyserver/caddy/v2/modules/caddytls"
	// ...共 13 个空导入
)
```

（modules/standard/imports.go:7-19）。下载的"caddy 标准版"与"你的定制版"在结构上没有任何差别——
这是插件经济学最硬的承诺：**官方版只是插件数量恰好多一点的用户**。

### 2.2 官方发行版也用 xcaddy 这条路

.goreleaser.yml 的 `before.hooks` 证明官方产物不是直接 `go build ./cmd/caddy`，而是同样走"临时模块"路线
（.goreleaser.yml:9-31）：把 main.go 复制进 caddy-build/、`go mod init caddy`、`go mod edit -require=...@{{.Env.TAG}}`、
vendor 后编译；甚至 Windows 的版本信息资源（.syso 文件）也是先跑 `XCADDY_SKIP_BUILD=1 GOOS=windows xcaddy build`
生成再拷回（.goreleaser.yml:16-17）。man 手册页与 bash 补全则由编译出的二进制自己生成
（`go run cmd/caddy/main.go manpage --directory`，.goreleaser.yml:29-31）——文档也是构建产物。

版本号嵌入走的是 Go 工具链原生方案：`Version()` 先读 `debug.ReadBuildInfo`，再读 VCS 信息，
拿不到就返回 `(devel)`（caddy.go:985-997）；外部可用 `CustomVersion` 变量加 `-ldflags -X` 覆盖
（caddy.go:943-955）。构建矩阵覆盖 4 个 OS × 6 个架构（darwin/linux/windows/freebsd ×
amd64/arm/arm64/s390x/ppc64le/riscv64），以 ignore 表排除非法组合（.goreleaser.yml:39-80），
统一 `CGO_ENABLED=0`、`-trimpath -mod=readonly -ldflags "-s -w"`（.goreleaser.yml:34-35, 81-85）。

---

## 3. 测试专节：caddytest——把"真服务器"塞进 go test

### 3.1 测试桩自带一个迷你构建

caddytest 包的 import 块就是 §2.1 的翻版——它空导入了 `modules/standard`，让测试二进制"变成一个完整 Caddy"
（caddytest/caddytest.go:30-31）。首次调用时它甚至以进程内方式启动真正的服务器：

```go
// caddytest/caddytest.go:291-299
os.Args = []string{"caddy", "run", "--config", f.Name(), "--adapter", "caddyfile"}
go func() {
    caddycmd.Main()
}()
// wait for caddy to start serving the initial config
for retries := 10; retries > 0 && isCaddyAdminRunning(tc) != nil; retries-- {
    time.Sleep(1 * time.Second)
}
```

之后测试通过**管理 API**下发配置：`InitServer` 把 Caddyfile/JSON POST 到 `localhost:2999/load`
（caddytest/caddytest.go:178；2999 端口是特意避开开发者本机真实例的默认 2019，见
caddytest/caddytest.go:47-52 注释），再轮询 `/config/` 用 `reflect.DeepEqual` 确认生效——最多 10 次、
每次 1 秒（caddytest/caddytest.go:250-257）。测试失败时 cleanup 会把当时的完整配置 dump 进日志
（caddytest/caddytest.go:143-157）。所有对外请求经 `CreateTestingTransport` 强制改拨 127.0.0.1
（caddytest/caddytest.go:339-350），防止集成测试真正访问外网域名。

### 3.2 断言风格：curl 式的一行式请求断言

集成测试（caddytest/integration/，19 个 _test.go）遵循 arrange-act-assert 三段式，断言 API 是"人类 curl 味"的：

```go
// caddytest/integration/caddyfile_test.go:9-24（节选）
func TestRespond(t *testing.T) {
	tester := caddytest.NewTester(t)
	tester.InitServer(`
  {
    admin localhost:2999
    http_port     9080
    https_port    9443
    grace_period  1ns
  }
  localhost:9080 {
    respond /version 200 { body "hello from localhost" }
  }`, "caddyfile")
	// act and assert
	tester.AssertGetResponse("http://localhost:9080/version", 200, "hello from localhost")
}
```

断言族全家福：`AssertResponseCode`（caddytest.go:507）、`AssertResponse`（:523）、
`AssertGetResponse`（:546）、`AssertPostResponseBody`（:570）、`AssertRedirect`（:377）、
`AssertLoadError`（:365，预期加载失败的配置）。integration 目录里 `Assert*` 调用共约 75 处；
最大单体是 reverseproxy_test.go（895 行，含 13 个 Tester 实例）。错误路径也测：
"ambiguous site definition" 这类配置冲突以 `caddytest.AssertLoadError` 断言
（caddytest/integration/caddyfile_test.go:60-73）。

### 3.3 矩阵覆盖：单元表驱动 + 黄金文件 + fuzz + 交叉编译

- **单元测试表驱动**：全仓 129 个 _test.go，其中 39 个使用 `for i, tc := range []struct{...}` 表驱动模式；
  典型如 headers 的处理器测试（modules/caddyhttp/headers/headers_test.go:30-40）。
- **Caddyfile→JSON 黄金文件**：caddytest/integration/caddyfile_adapt/ 下 241 个 `.caddyfiletest` 文件，
  格式是"Caddyfile + `----------` 分隔线 + 期望 JSON"；harness 按分隔线切分后逐文件跑子测试
  （caddytest/integration/caddyfile_adapt_test.go:17-46，切分在 :43）。
- **DNS 类测试走插件系统**：mockdns_test.go 直接 `caddy.RegisterModule(MockDNSProvider{})` 注册
  `dns.providers.mock`（caddytest/integration/mockdns_test.go:16-30）——测试基建本身也是插件。
- **fuzz**：7 个 `//go:build gofuzz` 目标（replacer_fuzz.go:15、duration_fuzz.go:15、listeners_fuzz.go:15、
  caddyconfig/caddyfile/lexer_fuzz.go:15 等），是 go-fuzz（dvyukov）风格
  `func FuzzReplacer(data []byte) (score int)`（replacer_fuzz.go:17），仓库内无 Go 1.18 原生 `testing.F` 目标；
  这些目标平时不参与 `go test ./...` 编译。
- **CI 矩阵**（.github/workflows/ci.yml）：linux/mac/windows × Go 1.26（ci.yml:29-40），步骤含
  构建 + 冒烟（`caddy start`/`caddy stop`，ci.yml:116-120）与 `go test -short -race ./...`（ci.yml:137）。
  注意关键细节：`-short` 下集成测试会自跳过（caddytest/caddytest.go:132-135 `if testing.Short()`）——
  所以 GitHub 托管矩阵只跑单元+短测；**完整集成测试跑在自备的 IBM Z s390x 远程硬件上**
  （ci.yml:155-214，`go test -p 1 ./...` 无 -short，且 `continue-on-error: true`，ci.yml:162）。
  另有 10 个 GOOS 的交叉编译矩阵（cross-build.yml:33-43，aix/solaris/illumos/dragonfly/openbsd/netbsd 等）。
- **静态检查三件套**：golangci-lint 三平台矩阵（lint.yml:22-64）、govulncheck（lint.yml:69-84）、
  PR 依赖变更审查 dependency-review（lint.yml:86-105）。

---

## 4. 发布与安全专节

### 4.1 提案式发布：比 goreleaser 多三道门

Caddy 的发布不是"打 tag 即发布"，而是一条带审批的流水线：

1. **提案 PR**：维护者手动触发 Release Proposal 工作流，输入版本号与 commit，先做 semver 正则校验
   （release-proposal.yml:12-20；`^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$`，:46-48），生成带
   `release-proposal` 标签的 PR 供他人批准；auto-release-pr.yml 负责跟踪审批状态（auto-release-pr.yml:1-10）。
2. **tag 签名校验**：push tag 后，release.yml 用 `git verify-tag` 按 SSH allowed_signers 校验签名，
   失败即**删除远端 tag 并中止**（release.yml:110-115）；然后校验 tag 指向的 commit 与提案 PR 标注的
   Target Commit 一致，不一致同样删 tag（release.yml:239-256）。
3. **产物与分发**：goreleaser 产二进制 + cosign 签名 + syft SBOM（CycloneDX）（.goreleaser.yml:91-110）
   + sha512 校验和（:153-154）；还把 caddy-build/ 目录原样打成 "buildable-artifact" tarball，
   让用户能重建与官方逐字节等价的构建环境（.goreleaser.yml:126-139 注释原文即此意）。
   deb 包走 Gemfury（正式版）与 Cloudsmith stable/testing（测试版/预发布）双通道（release.yml:444-496）。

**没有 CHANGELOG 文件**：变更日志由 goreleaser 从 git 提交信息实时过滤生成——排除 `chore:/ci:/docs:/tests:`
前缀及所有"不带包名冒号前缀"的提交（.goreleaser.yml:207-216，最后一条正则注释自嘲为 "a hack"）。
发布为 draft + `prerelease: auto`（.goreleaser.yml:200-205）；发布节奏无固定日程，依赖提案流程而非日历。
版本策略是严格语义化（提案校验正则即是），且 SECURITY.md 明确只支持 `2.latest`（.github/SECURITY.md:8-11）。

### 4.2 "默认安全"清单（逐项对照前文各章）

| # | 默认项 | 代码锚点 | 默认行为 |
|---|--------|----------|----------|
| 1 | 自动 HTTPS | modules/caddyhttp/autohttps.go:240-244 | 公网域名自动配证书并**自动启用 HTTP→HTTPS 重定向**；默认端口 80/443（modules/caddyhttp/caddyhttp.go:328-332） |
| 2 | admin API 本地化 | admin.go:1451-1453 | `DefaultAdminListen = "localhost:2019"`；可用 CADDY_ADMIN 环境变量改（admin.go:59-66） |
| 3 | admin 防 CSRF/DNS rebinding | admin.go:873-886 | 带 Origin/Sec-Fetch 头或显式 `enforce_origin` 时校验 Origin；`enforce_host` 时 `checkHost` 防 DNS rebinding；拒绝 `Origin: null`（admin.go:858-866） |
| 4 | 不信任转发头 | modules/caddyhttp/reverseproxy/reverseproxy.go:141-147 | "By default, **no proxies are trusted**"——X-Forwarded-* 一律不信任，须显式 `trusted_proxies`（可简写 `private_ranges`，caddyfile.go:706-712） |
| 5 | on-demand TLS 须授权 | modules/caddytls/ondemand.go:39-46 | "this feature can easily be abused, Caddy must ask permission"——握手期签证书必须配 permission 模块（如 PermissionByHTTP 回调询问） |
| 6 | 供应链加固 | ci.yml:67-70 等 | 所有 job 跑 step-security/harden-runner（egress-policy: audit）；OpenSSF Scorecard 周检（scorecard.yml:1-16）；Actions 版本全部 pin commit SHA |
| 7 | 依赖漏洞扫描 | lint.yml:69-84 | 每次 CI 跑 govulncheck；PR 跑 dependency-review（lint.yml:99-105） |
| 8 | 静态二进制 | .goreleaser.yml:34-35 | CGO_ENABLED=0，全平台无 C 依赖 |

清单背后是产品哲学：安全默认值不是文档建议而是**代码里的零值行为**——不写配置就得到重定向（#1）、
本地 admin（#2）、不信任转发头（#4）。这正是 AGENTS.md:5 使命 "Every site on HTTPS" 的工程化表达。

### 4.3 漏洞披露流程： scope 极窄 + 强制 AI 披露

.github/SECURITY.md 的流程有两个鲜明特点：

- **收窄范围到"源码里的洞"**：配置错误、客户端侧漏洞、依赖（含 Go 标准库）漏洞、未发布代码一概不收
  （SECURITY.md:14-30）；"Many reports are not security bugs and can be addressed by updating the
  documentation."（SECURITY.md:28）。提交渠道是 GitHub 私密漏洞报告（SECURITY.md:56），不加密、无赏金、
  默认不公开报告者身份（SECURITY.md:58-62）。
- **强制 LLM 披露**："YOU MUST DISCLOSE WHETHER YOU USED LLMs ('AI') IN ANY WAY... FAILURE TO INCLUDE A
  DISCLOSURE EVEN IF YOU DO NOT USE AI MAY LEAD TO IMMEDIATE DISMISSAL"（SECURITY.md:39）。
  这与 CONTRIBUTING.md 的社区规则同源："We prefer to interact with humans in this project"（:26），
  AI 可辅助但必须披露且人类需逐行理解代码（:56-64）；仓库还部署了 AI Moderator 工作流自动给
  issue/评论打 spam/ai-generated 标签（.github/workflows/ai.yml:14-29）。

文档策略则是"文档即代码、但分仓"：主仓不存文档，caddyserver.com/docs 的源码在 caddyserver/website 仓库
（CONTRIBUTING.md:148-152）；第三方插件的文档由插件作者自托管（CONTRIBUTING.md:152）——与 xcaddy 的
插件自治一脉相承。协作者守则甚至写明审查时反问"Does the change incur any new dependencies?
(Avoid these!)"（CONTRIBUTING.md:167）。

### 4.4 依赖哲学：stdlib 优先，但不是"零依赖原教旨"

go.mod（go.mod:3-51）声明 Go 1.25.1，直接 require 约 46 项。关键直接依赖大多来自"自家或深度绑定"生态：
certmagic v0.25.4（go.mod:12，ACME/证书管理核心，01/02 章主角）、zerossl、acmez（:22），
加 smallstep PKI 三件套（:25-27）、zap（:43）、quic-go（:24）、Prometheus/OpenTelemetry（:23, 34-40）。
测试专用依赖极少：testify（:30）与 aryann/difflib（:11，caddytest 的黄金对比）。

两条铁律写在协作者守则：**"Caddy must not export any types defined by those dependencies"**
（CONTRIBUTING.md:175——依赖类型不得泄漏进公共 API，用户可随时替换实现）；同时用 build tags 裁剪重依赖：
标准构建一律 `-tags=nobadger,nomysql,nopgx`（ci.yml:16、.goreleaser.yml:86-89、README 步骤 7），
把 Badger/MySQL/Postgres 存储后端挡在默认二进制之外。零依赖做不到（web 服务器的领域面太宽），
但"依赖可裁剪、类型不泄漏、默认最小链接"做到了。

---

## 5. 与前作对照

- **vs Git（卷一 07，C 文化）**：Git 用 C89 与零外部依赖换 30 年可移植性；Caddy 用 Go 工具链把"依赖管理"
  变成语言内建（go.mod + vendor 进源码包，.goreleaser.yml:141-150），但两者在文化内核上同构——
  都把"拒绝无谓依赖"当成工程纪律（Git 不链 libcurl，Caddy 禁止导出依赖类型并审查每个新依赖）。
- **vs zstd（测试三层）**：zstd 是"单元→fuzz→长时间大语料"的压缩器三层；Caddy 同为三层但把第二层换成了
  **整个服务器在环**的集成断言（caddytest 起真进程、走管理 API、发真 HTTP），fuzz 只做 7 个纯函数目标——
  配置解析器比压缩核更需要"黑盒端到端"。
- **vs curl（8 周节奏）**：curl 以日历驱动、每 8 周一版并手工撰写变更日志；Caddy 无固定日程，以
  "release proposal PR + 双人批准 + tag 签名"为门禁，changelog 直接从 conventional commit 过滤生成
  （.goreleaser.yml:207-216）——curl 的节奏是承诺，Caddy 的节奏是审批。

---

## 6. 设计动机

1. **Go 模块生态下的插件分发**：Go 的静态编译让"运行时插件"（.so/dll）既脆又不可移植。Caddy 的答案是
   把分发问题还原为**包管理问题**：插件就是 go.mod 里的一行 require 加一行空导入（README.md:143-158）。
   xcaddy 只是个脚手架，官方发行版（modules/standard/imports.go:7-19）与 goreleaser 的构建钩子
   （.goreleaser.yml:9-31）走完全相同的路径——没有特权构建，就没有"官方版更特殊"的认知负担。
2. **文档即营销**：文档放在网站仓而非代码仓（CONTRIBUTING.md:150），是因为 Caddy 的站点同时是
   交互式文档与 Caddyfile 试用场；文档更新走 issue 而非直接 PR（CONTRIBUTING.md:150），
   反映"文档是面向用户的产品、代码仓面向开发者"的两群人分治。
3. **默认安全作为产品差异化**：竞争对手卖"HTTPS 插件"，Caddy 把 HTTPS/本地 admin/不信任转发头做成
   零值行为（§4.2 清单），并把这条哲学写进给 AI 的编码守则（AGENTS.md:5）。安全清单每项都可被
   单元测试钉死（admin_origin_case_test.go 等），默认值因此不敢悄悄退化。
4. **流程对抗规模**：SECURITY.md 的窄 scope 与"大量无效报告"自述（SECURITY.md:35, 54）、AI Moderator
   工作流（ai.yml）、强制披露规则（SECURITY.md:39），都是同一个动机：热门项目的注意力是最稀缺资源，
   用流程把低质量输入挡在人工审查之前。

---

## 7. FAQ 素材

1. **Caddy 官方二进制是怎么构建的？** 不是直接 go build，而是 goreleaser 钩子里临时建一个 Go 模块，
   复制 main.go、require 固定 tag、vendor 后编译（.goreleaser.yml:9-31）；Windows 的 .syso 版本资源
   由 xcaddy 生成（:16-17）。
2. **"标准版"和插件定制版有区别吗？** 没有结构区别——标准版只是空导入了 13 个官方模块
   （modules/standard/imports.go:7-19）；你的定制版 = 同一份 main.go + 你自己的导入。
3. **集成测试需要真实证书/网络吗？** 不需要外网：测试证书在 caddytest/ 下随仓分发，配置里的
   `/caddy.localhost.crt` 会被正则替换为绝对路径（caddytest/caddytest.go:329-336）；拨号强制改到
   127.0.0.1（:339-350）。
4. **CI 到底跑不跑集成测试？** GitHub 托管矩阵用 `-short -race`，集成测试此时自跳过
   （caddytest/caddytest.go:132-135 与 ci.yml:137）；完整集成测试在自备 s390x 硬件上跑
   （ci.yml:155-214），允许失败。
5. **为什么看不到 CHANGELOG？** 变更日志由 goreleaser 从提交信息过滤生成，排除 chore/ci/docs/tests
   与无包名前缀的提交（.goreleaser.yml:207-216）。
6. **发布产物如何防篡改？** tag 必须 SSH 签名且与提案 commit 一致，否则流水线直接删 tag
   （release.yml:110-115, 239-256）；二进制有 cosign 签名、SBOM、sha512 与可重建的 buildable-artifact
   （.goreleaser.yml:91-139, 153-154）。
7. **Caddy 是零依赖项目吗？** 不是，直接依赖约 46 项（go.mod:5-51）；但依赖类型禁止泄漏出公共 API
   （CONTRIBUTING.md:175），重存储后端用 build tags 裁出默认构建。
8. **反代默认信任 X-Forwarded-For 吗？** 默认一个代理都不信任（reverseproxy.go:141-147），
   必须显式 `trusted_proxies`；才会在追加 XFF 时保留既有链（:925-945）。
9. **admin API 默认对公网开放吗？** 默认只听 localhost:2019（admin.go:1453），带 Origin 头的请求做
   跨站校验、可启用 host 校验防 DNS rebinding（admin.go:873-886），`Origin: null` 直接拒绝（:858-866）。
10. **AI 写的代码/报告能提交吗？** 可以辅助但必须披露；安全报告不披露 AI 使用可被直接拒绝并封禁
    （SECURITY.md:39）；社区明确"优先与人交互"（CONTRIBUTING.md:26-28）。

## 深挖线索

1. **caddytest 的"进程内服务器"实现**：测试直接调用 `caddycmd.Main()` 而非 exec 子进程
   （caddytest/caddytest.go:291-294），配合 AdminPort 2999 隔离——研究它如何优雅处理测试间配置残留
   （每次 InitServer POST /load 覆盖，无需重启）。
2. **s390x 远程 CI 的工程史**：ci.yml:162 注释"August 2020: s390x VM is down due to weather and power
   issues"保留至今——大端架构上的 `go test -p 1`（禁并行）暗示字节序/原子性问题在 IBM Z 上会被暴露。
3. **黄金文件的双向利用**：`.caddyfiletest` 里期望部分若不是 `{` 开头则被当作**期望的错误文本**做包含断言
   （caddyfile_adapt_test.go:56-70）——一个文件格式同时承载正反两用例。
4. **发布提案的状态机**：release-proposal（建 PR）→ auto-release-pr（跟踪批准）→ release.yml（验签 +
   commit 比对 + 打标签 release-in-progress/released + 关分支删分支，release.yml:498-565）——
   一套完全跑在 GitHub PR 语义上的发布状态机，值得与內部发布系统对照。
5. **AGENTS.md 现象**：229 行的 AI 代理守则把模块生命周期（New→Provision→Validate→Cleanup）、接口守卫、
   结构化日志等模式写成"给 LLM 的 style guide"（AGENTS.md:33-70 附近），是"工程文化如何传导给非人类
   贡献者"的罕见样本。

---

## 写作要点速查表

| 事实 | 文件:行号 |
|------|-----------|
| xcaddy 构建七步（插件=空导入+编译） | README.md:143-158 |
| 标准发行版=13 个空导入 | modules/standard/imports.go:7-19 |
| 官方构建走临时模块+xcaddy 生成 syso | .goreleaser.yml:9-31（syso :16-17） |
| 构建矩阵 4 OS×6 arch，CGO_ENABLED=0 | .goreleaser.yml:33-89（CGO :34-35） |
| cosign 签名 + syft SBOM + sha512 | .goreleaser.yml:91-110, 153-154 |
| changelog 从提交过滤（无 CHANGELOG 文件） | .goreleaser.yml:207-216 |
| 测试桩空导入 standard，进程内起服务器 | caddytest/caddytest.go:31, 291-299 |
| -short 跳过集成；断言族 AssertGetResponse | caddytest/caddytest.go:132-135, 546 |
| CI 矩阵 3 OS×Go1.26，-short -race | .github/workflows/ci.yml:29-40, 137 |
| s390x 真集成测试（远程 IBM Z，可失败） | .github/workflows/ci.yml:155-214（:162, :194） |
| 241 个 Caddyfile 黄金文件，`----------` 切分 | caddytest/integration/caddyfile_adapt_test.go:17-46（:43） |
| tag 验签失败/commit 不符即删 tag | .github/workflows/release.yml:110-115, 239-256 |
| 安全报告窄 scope + 强制 AI 披露 | .github/SECURITY.md:14-30, :39 |
| 默认 admin=localhost:2019 + origin/host 校验 | admin.go:1453, :873-886 |
| 反代默认不信任任何代理的 XFF | modules/caddyhttp/reverseproxy/reverseproxy.go:141-147 |
| on-demand TLS 必须 ask/permission | modules/caddytls/ondemand.go:39-46 |
| 文档在 website 分仓；禁止导出依赖类型 | .github/CONTRIBUTING.md:150, :175 |
| 使命宣言与 AI 编码守则 | AGENTS.md:5（全文 229 行） |
