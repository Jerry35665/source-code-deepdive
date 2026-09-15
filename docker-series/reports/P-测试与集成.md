# P 章 · 测试与集成:containerd 的重型 CI vs runc 的规范即测试

> 源码版本:containerd `f6132db`、runc `579be22`(均为 shallow clone);行号以 2026-09 核对为准。
> 卷一 06 章讲过 OCI 落地与 runc rootless 幂集测试,本章系统对比两个项目的测试/CI/发布工程。

## 1. 全景:工程四柱对照

```
             containerd                                 runc
构建     Makefile 多平台分文件(Makefile.linux/         单 Makefile;BUILDTAGS=seccomp,libpathrs
         darwin/windows,Makefile:147-148);            (Makefile:14);VERSION 文件驱动
         版本走 git describe(Makefile:35)+ldflags
单元测试 make test / make root-test(-test.root)      make localunittest(go test ./...,
         (Makefile:209-216);排除 /integration           3m 超时,Makefile:163-165)+
         (Makefile:114)                                libcontainer/integration Go 测试
集成测试 双轨:integration/client(client API)        tests/integration/*.bats(bats 框架,
         + integration/(CRI,编译为 cri-integration     46 个文件)+ helpers.bash;
         .test 二进制,Makefile:224-231)              make localintegration=bats -t(Makefile:175-177)
CI       ci.yml 18 个 workflow 文件;OS×go×           test.yml 一个矩阵:4 OS×2 go×
         cgroup_driver×runtime 大矩阵 + Lima VM        libpathrs×rootless×race×criu(test.yml:35-53)
         + Windows + K8s node-e2e(ci.yml:395-774)
发布     GPG 签名 tag 检查(release.yml:36-46)、      容器内静态构建 8 架构(Makefile:114-128)、
         buildx 6 平台(release.yml:72-84)、           CHANGELOG 规范检查(Makefile:239-244)、
         nightly 每日(nightly.yml:3-4)               维护者 PGP keyring(Makefile:252-253)
节奏     4 个月一版,与 K8s 对齐(RELEASES.md:44-48)   6 个月一版,4/10 月底(RELEASES.md:19-24)
```

## 2. containerd 测试专节:单元 / 集成 / CRI 集成的三层

### 2.1 第一层:单元测试(make test / make root-test)

`Makefile:114` 把 `/integration` 从单元测试包列表中剔除,其余全部走 `go test`:

```makefile
PACKAGES := $(shell $(GO) list ${GO_TAGS} ./... | grep -v /integration)
```

需要 root 的测试不单独成目录,而是用 `testutil.RequiresRoot` 标记,Makefile 用 `git grep` 动态收集(Makefile:116-119),`make root-test` 加 `-test.root` 运行(Makefile:214-216)。辅助设施在 `pkg/testutil`:`helpers.go:57` 的 `DumpDir`、`helpers.go:92` 的 `DumpDirOnFailure`(失败时倾倒目录)、`registry.go`(注册表测试用内存 registry)。CI 中 `make test` 与 `sudo make root-test` 先后执行(ci.yml:490-498)。

### 2.2 第二层:client API 集成(integration/client)

`make integration`(Makefile:218-222)进入 `integration/client` 目录跑 `-test.root -parallel 8`,覆盖 Go client 全 API 面(container/snapshot/content/lease/transfer 等 33 个文件),这是对**对外稳定 API**(RELEASES.md:412 将 client 列为 Stable)的直接验收。

### 2.3 第三层:CRI 集成(integration/ + critest)

`integration/` 下的 59 个文件是**白盒 CRI 端到端测试**:整体被 `go test -c` 编译成单个二进制再由脚本驱动:

```makefile
$(CRI_INTEGRATION_TEST_BINARY):
	@$(GO) test -c ./integration -o $(CRI_INTEGRATION_TEST_BINARY)

cri-integration: binaries $(CRI_INTEGRATION_TEST_BINARY)
	@bash ./script/test/cri-integration.sh
```

(Makefile:224-231,示例行有删节)

- 测试骨架 `integration/main_test.go`:import `k8s.io/cri-api`(:44),TestMain 里 `ConnectDaemons()` 连接 CRI gRPC 与 containerd 双客户端(:76-134),提供 `RestartContainerd`(:843-859,杀掉守护进程再等待重连)、`EnsureImageExists`(:863-876)、`PodSandboxConfigWithCleanup`(:314-324)等 helper;`--cri-endpoint/--runtime-handler/--containerd-bin` 是命令行参数(:71-74)。
- 驱动脚本 `script/test/cri-integration.sh:53-61`:先由 `script/test/utils.sh` 生成 CRI 配置并拉起 containerd,再执行 `bin/cri-integration.test --cri-endpoint=... --runtime-handler=...`;失败时把 containerd.log 搬进 GitHub report 目录。
- **故障注入是容器化的**:`integration/failpoint/cmd/` 提供四个包装器——`containerd-shim-runc-fp-v1`、`cni-bridge-fp`、`runc-fp`、`loopback-v2`(Makefile:233-251 逐个构建),`utils.sh:100-103` 用 `pod_annotations = ["io.containerd.runtime.v2.shim.failpoint.*"]` 把 failpoint 通配进 Pod 注解,可以模拟 shim/CNI 半路挂掉。
- **黑盒一致性测试 critest** 独立成步:CI 拉 cri-tools v1.37.0(`script/setup/critools-version`)跑 `./script/critest.sh`(ci.yml:553-559),对 kubelet 视角做协议级验收。

### 2.4 对 kubelet 场景的端到端:node-e2e 与 CRI-in-UserNS

- `node-e2e.yml`:CI 同时 checkout `kubernetes/kubernetes`(:44-51),用 K8s 自带的 node e2e 框架把 containerd 二进制塞给 kubelet 跑真 Pod;由 ci.yml:771-774 以 reusable workflow 调用,仅 PR 触发(不在 merge queue 内)。
- `tests-cri-in-userns`(ci.yml:684-737):用 rootless Podman 构建 `contrib/Dockerfile.test` 的 cri-in-userns 镜像并 `--privileged` 运行(:713-737),验证"整套 CRI 栈跑在 user namespace 里"。
- `integration-vm`(ci.yml:595-682):Lima 虚拟机里跑 `script/vm/test-integration.sh`、`test-cri-integration.sh`、`test-cri.sh`(:671-676),覆盖 Fedora/AlmaLinux 真实 systemd 环境。

## 3. runc 测试专节:bats 集成 + 静态二进制 release

### 3.1 integration 的组织:不是裸 shell,是 bats

`tests/integration/` 共 59 个条目,主体是约 46 个 `.bats` 文件(bats = Bash Automated Testing System),配 `helpers.bash`、镜像自举脚本和 `testdata/`。`tests/integration/README.md` 明确分工:单元测试求彻底,集成测试只做特性端到端验收。helpers 头部:

```bash
bats_require_minimum_version 1.5.0
INTEGRATION_ROOT=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
IMAGES=$("${INTEGRATION_ROOT}"/get-images.sh)
eval "$IMAGES"
: "${RUNC:="${INTEGRATION_ROOT}/../../runc"}"
TESTBINDIR=${INTEGRATION_ROOT}/../cmd/_bin
```

(tests/integration/helpers.bash:6-16,有删节)

典型用例风格(run.bats:1-13):

```bash
load helpers

function setup() {
	setup_busybox
	update_config '.process.args = ["/bin/echo", "Hello World"]'
}
function teardown() {
	teardown_bundle
}
@test "runc run" {
	runc run test_hello
	[ "$status" -eq 0 ]
	runc state test_hello
	[ "$status" -ne 0 ]
}
```

用 jq 风格的 `update_config` 改 `config.json`,`requires` 谓词按内核/rootless/systemd 能力跳过(如 run.bats:39-40 `requires no_systemd`)。辅助守护进程由 `tests/cmd/` 的 7 个小工具提供(recvtty、seccompagent、fs-idmap、pidfd-kill 等),`make test-binaries` 编到 `tests/cmd/_bin`(Makefile:90-98;tests/cmd/README.md)。shell 质量用 `make shellcheck` 把 `*.bats` 一并扫掉(Makefile:216-221)。

入口链:`make localintegration` = `bats -t tests/integration$(TESTPATH)`(Makefile:175-177);`make test` = unittest + integration + rootlessintegration 三合一(Makefile:149-153)。

### 3.2 与卷一 F 的呼应:rootless 幂集

卷一 06 章提过的 `tests/rootless.sh`(227 行)本章只引用结论:`ALL_FEATURES=("idmap" "cgroup")`(:25),每个特性配 `enable_*/disable_*` 钩子(:40/:72/:107/:158),然后:

```bash
# Iterate over the powerset of all features.
for ROOTLESS_FEATURES in $features_powerset; do
	((++idx))
	printf "[%.2d] run rootless tests ... (${ROOTLESS_FEATURES%%+})\n" "$idx"
	...
	hook_func="disable_$feature"
	grep -E "(^|\+)$feature(\+|$)" <<<"$ROOTLESS_FEATURES" &>/dev/null && hook_func="enable_$feature"
	"$hook_func"
done
```

(tests/rootless.sh:190-199,有删节;powerset 函数定义在 :174-178)

CI 里由 `script/setup_rootless.sh` 建用户后执行(test.yml:169-188)。

### 3.3 静态二进制 release 构建

`make release` 的套路是"容器即构建机":起 `runcimage`(Dockerfile,ARG 里钉死 GO_VERSION=1.26、BATS v1.12.0、LIBSECCOMP 2.6.1、LIBPATHRS 0.2.6,Dockerfile:1-4),在容器内 `make localrelease` → `script/release_build.sh`(Makefile:118-128),最后 `script/release_sign.sh -S` 签名(Makefile:124)。`releaseall` 一次覆盖 8 个架构:386/amd64/arm64/armel/armhf/ppc64le/riscv64/s390x(Makefile:114-116)。构建脚本自建动态库依赖再静态链接:

```bash
: "${LIBSECCOMP_VERSION:=2.6.1}"
: "${LIBPATHRS_VERSION:=0.2.6}"
...
	# Download and build libseccomp.
	"$root/script/build-seccomp.sh" "$LIBSECCOMP_VERSION" "$dylibdir" "${arches[@]}"
	# Download and build libpathrs.
	"$root/script/build-libpathrs.sh" "$LIBPATHRS_VERSION" "$dylibdir" "${arches[@]}"
	local ldflags="-w -s -buildid="
	local make_args=(COMMIT_NO= EXTRA_FLAGS="-a" EXTRA_LDFLAGS="${ldflags}" static)
```

(script/release_build.sh:22-65,有删节)

`-w -s -buildid=` 三件套是为了可复现构建(release_build.sh:61-63 注释)。发版前还有 `make verify-changelog` 对 CHANGELOG.md 做正则卫生检查(行尾空白、引用格式,Makefile:239-244)。

### 3.4 版本与安全响应

- runc 用单文件 `VERSION`(当前内容 `1.5.0-rc.1+dev`),RC 期分支冻结后手工推进;RELEASES.md:26-31 规定 rc1 在正式版前 2 个月切 `release-1.x` 分支并 feature freeze,通常 2-3 个 RC。
- `SECURITY.md:3-4`:漏洞不得走 GitHub issue,统一走 opencontainers/org 的安全披露流程;CI validate.yml:33-38 专门有 `keyring` job 跑 `make validate-keyring`(Makefile:252-253),校验仓库根的 `runc.keyring`(维护者 PGP 公钥集)。

## 4. CI 矩阵对照专节:组合面

### containerd(ci.yml,18 个 workflow 文件)

| 维度 | 取值 | 出处 |
|---|---|---|
| lint OS | ubuntu-latest / ubuntu-24.04-arm / macos / windows | ci.yml:29 |
| go 版本 | 1.26.8 / 1.27.1("1.25 is not supported due to k8s 1.36 requiring 1.26") | ci.yml:203-204 |
| 二进制构建 | 上述 4 OS × 2 go | ci.yml:201-204 |
| Linux 集成 | ubuntu-22.04/24.04/24.04-arm × cgroupfs/systemd × runc/crun(注释:crun 可加)× runtime `io.containerd.runc.v2` | ci.yml:401-410 |
| 集成跑法 | 同套件跑两遍:串行 `-race` + 并行 `TESTFLAGS_PARALLEL=1`(见 PR #1759 注释) | ci.yml:504-533 |
| VM 集成 | Lima:fedora-44(×cgroupfs/systemd×runc/crun)+ almalinux-8/9/10(×cgroupfs/systemd)共 10 组 | ci.yml:605-636 |
| Windows | windows-2022 + cgroupfs,90 分钟超时;critest 带 ws2022 专项 skip 列表 | ci.yml:222-235, 374-383 |
| 特殊栈 | CRI-in-UserNS(cgroupfs/systemd)、macOS 仅单元、K8s node-e2e | ci.yml:684-737, 739-769, 771-774 |
| 汇总 | `results` job 聚合为单一 required check | ci.yml:776-791 |

另外:交叉编译矩阵覆盖 linux/arm/v5、arm/v7、freebsd、loong64、windows/arm64(ci.yml:127-144);发布流水线 buildx 出 linux/amd64/arm64/ppc64le/s390x/riscv64 + windows/amd64 六平台 tar.gz(release.yml:72-84, 120)。

### runc(test.yml + validate.yml)

| 维度 | 取值 | 出处 |
|---|---|---|
| OS | ubuntu-24.04 / 24.04-arm / 26.04 / 26.04-arm(26.04 连 sudo-rs 都要换回原版 sudo,test.yml:93-96) | test.yml:38 |
| go | 1.26.x / 1.27.x | test.yml:39 |
| libpathrs | 开(Rust 库,script/build-libpathrs.sh 编译)/ 关(-libpathrs tag) | test.yml:40, 98-106 |
| rootless | 有 / 无 | test.yml:41 |
| race | `-race`(仅最新 go)/ 无 | test.yml:42, 51-53 |
| criu | 发行版 criu / criu-dev 源码编译(continue-on-error) | test.yml:43, 128-138, 175-180 |
| cgroup 驱动 | fs 与 systemd 各跑一遍(test.yml:175-188) |
| 32 位 | cross-i386:无 32 位 ARM CI,用 i386 顶上(test.yml:190-194) |
| VM | Lima:almalinux-8/9、centos-stream-10、fedora、fedora-rawhide(rawhide 不挡合并) | test.yml:247-249 |
| 汇总 | `all-done` 只 echo 一句 | test.yml:311-318 |

静态检查拆到 validate.yml:golangci-lint 主配置 + `.golangci-extra.yml --new-from-rev=HEAD~1` 只对增量代码加严(validate.yml:54-62),另有 actionlint、keyring、scheduled 等小 workflow。

对照结论:containerd 的矩阵是**环境维度主导**(OS/cgroup 驱动/发行版/runtime),runc 是**特性开关维度主导**(libpathrs/rootless/race/criu)。前者矩阵膨胀在"部署形态",后者在"代码路径"。

## 5. vendor 与模块策略:两种姿态

- **containerd:vendor 全量入库 + CI 校验**。`vendor/github.com` 下 57 个顶级依赖目录;CI 有专门一步 `make verify-vendor`("verify go modules and vendor directory",ci.yml:72-76;Makefile:498)。API 独立成 `github.com/containerd/containerd/api` 子模块(RELEASES.md:444-450),integration/client 也随主模块管理。
- **runc:vendor 保留,但持续"瘦身外抽"**。vendor/github.com 仅 15 个顶级目录;最关键的分化是把 cgroup 管理抽成独立模块 `github.com/opencontainers/cgroups v0.1.0`(go.mod:19),安全路径处理抽成 `cyphar.com/go-pathrs v0.2.6`(go.mod:6)并在 CI 里做成开关维度(test.yml:40)。`make vendor` 三连 tidy/vendor/verify(Makefile:233-237)。
- 语义差异:containerd 的 vendor 服务于"K8s 依赖我,构建必须可复现、可审计";runc 的外抽模块服务于"libcontainer 的通用能力应成为上游公共件,runc 本体保持薄"。containerd 甚至用 depguard **反向禁止**依赖 runc:`.golangci.yml:21-22` "We don't want to depend on runc (libcontainer)"。

## 6. 设计动机

1. **containerd 为什么需要 heavyweight CI**:RELEASES.md:151-168 给出硬约束——K8s 每个版本只认一组 containerd 版本,且 "This cadence is synchronized with the Kubernetes release schedule"(RELEASES.md:46-48)。它承诺的不只是二进制,而是 kubelet 生产路径,所以 cgroup 驱动、发行版、Windows、userns、node-e2e 每一层都要真机验证。RELEASES.md:202-249 甚至把"平台支持"形式化为 Tier 1/2/3,并逐条映射到 release.yml/nightly.yml/ci.yml 的哪个 job(RELEASES.md:244-249)。
2. **runc 的"规范即测试"哲学**:PRINCIPLES.md 通篇是约束清单("Don't merge it unless you test it!"、"Less code is better")。bats 用例几乎逐条对齐 runtime spec 的字段语义(create/delete/kill/hooks/seccomp/selinux/idmap 各一个文件),`script/check-config.sh` 在每个 CI job 里先校验内核配置(test.yml:83)——测试的锚点是 OCI 规范与内核能力,而非上游消费者的部署形态。集成测试还要 `script -e -c` 伪造终端(test.yml:1-2 注释),因为 runc 的 TTY 行为本身就是规范的一部分。
3. **发布节奏对照**:containerd 4 个月一版、Beta 8-10 周 / RC 2-4 周、常规支持 8 个月、每年一个 LTS 支持 2 年+(RELEASES.md:44-48, 79-84, 86-103);runc 6 个月一版(4 月/10 月底)、rc1 提前 2 个月(feature.freeze)(RELEASES.md:19-31)。节奏差 = 消费方差:K8s 一年三版拖着 containerd 走;runc 的下游(Docker/containerd/cri-o)各自内嵌它,升级压力被解耦。
4. **测试哲学与代码规模的同构**:containerd 用"编译产物 + shell 驱动"(cri-integration.test 二进制,Makefile:224-231)换取可并行、可按 FOCUS 过滤、可附带 coverage(Makefile:479-484);runc 用 bats 换取"一个用例 = 一段可读 shell",任何发行版工程师都能读懂并贡献。

## 7. FAQ 素材

1. **containerd 的 integration/ 是脚本风格还是 Go test?** 是 Go test,但不在 `make test` 里跑:整个目录被 `go test -c` 编成 `bin/cri-integration.test`,由 `script/test/cri-integration.sh` 传参驱动(Makefile:224-231;cri-integration.sh:53-61)。
2. **runc 的 integration 是裸 shell 吗?** 不是,是 bats 框架的 `.bats` 文件(46 个),共享 `helpers.bash` 的 `requires`/`testcontainer`/`update_config` 等原语(tests/integration/README.md;helpers.bash:6-40)。
3. **为什么 containerd 集成套件每个 PR 跑两遍?** 第一遍串行带 `-race`,第二遍并行 `-short`;注释指向 PR #1759 的历史讨论(ci.yml:504-533,521)。
4. **containerd 如何测"CNI/shim 半路死掉"?** failpoint 包装器四件套 + Pod 注解通配 `io.containerd.runtime.v2.shim.failpoint.*`(Makefile:233-251;utils.sh:100-103)。
5. **runc 静态二进制为什么自己编 libseccomp/libpathrs?** 版本钉死 + 可复现(ldflags `-w -s -buildid=`),8 架构交叉全部自足(release_build.sh:22-65;Makefile:114-116)。
6. **两个项目的版本号从哪来?** runc 读 `VERSION` 文件(现为 `1.5.0-rc.1+dev`);containerd 无 VERSION 文件,`git describe --match 'v[0-9]*' --dirty='.m'` 在链接期注入 `version.Version`(Makefile:35,105;version/version.go:26-27)。
7. **cri-integration 和 critest 重复吗?** 不重复:前者白盒(failpoint、内部状态断言、可重启 containerd,main_test.go:843-859),后者是 CRI 协议一致性黑盒(ci.yml:553-559)。
8. **lint 上最容易踩的坑?** containerd 禁 import runc(depguard,.golangci.yml:21-22);runc 禁 `os.Create`(O_TRUNC 可被利用覆盖宿主文件,注释点名 CVE-2024-45310,.golangci.yml:39-45)。
9. **为什么 runc CI 里到处是 `script -e -c` / `ssh -tt`?** Actions 环境没有终端,而 runc 的 tty 语义必须被测试(test.yml:1-2,292-293)。
10. **两边如何防"矩阵改了但 required check 没改"?** containerd 用固定标题的 `results` 聚合 job(ci.yml:776-791);runc 用 `all-done` 空收尾(test.yml:311-318)。

## 8. 深挖课题

1. **"集成测试二进制化"的工程账**:cri-integration.test 把 59 个 Go 测试文件收进一个产物,shell 只管环境;对比 runc 的 bats 解释执行,分析两者的失败复现成本与并行度差异(可对照 Makefile:218-231 与 Makefile:175-177)。
2. **failpoint 即接口**:`integration/failpoint/cmd` 四个包装器 + Pod 注解通配构成一套最小故障注入 DSL,值得与 chaos 工程工具(如 chaos-mesh)做能力对照(utils.sh:100-103)。
3. **平台分级的制度化**:Tier 1/2/3 不是文档修辞,`RELEASES.md:259-278` 定义了晋升的硬条件(必须能 gate merge 的可靠 CI),并写明降级程序(:280-295)——开源项目治理"承诺管理"的范本。
4. **lint 的代际分层**:runc 用 `--new-from-rev=HEAD~1` 对存量豁免、增量加严(validate.yml:62),containerd 用 gosec 排除清单 + TODO 注释逐步收紧(.golangci.yml:27-38),两种"还债"路线的收敛速度对比。
5. **签名信任链的两种粒度**:containerd 在 release workflow 里 `git tag -v` 校验签名 tag(release.yml:36-46);runc 把维护者公钥固化进仓库 `runc.keyring` 并每次 CI 校验(validate.yml:33-38,Makefile:252-253)。

## 9. 写作要点速查表

| 文件:行号 | 要点 |
|---|---|
| containerd Makefile:209-231 | test/root-test/integration/cri-integration 四级目标 |
| containerd Makefile:114,116-119 | 单测排除 /integration;RequiresRoot 动态收集 |
| containerd Makefile:35,105 | git describe 版本 + ldflags 注入 |
| containerd Makefile:233-251 | failpoint 四包装器构建 |
| containerd integration/main_test.go:71-134 | CRI 测试骨架:flags/ConnectDaemons |
| containerd script/test/cri-integration.sh:53-61 | cri-integration.test 驱动参数 |
| containerd ci.yml:203-204,401-410 | go 版本矩阵;Linux 集成矩阵 |
| containerd ci.yml:504-533 | 集成跑两遍(-race / parallel) |
| containerd ci.yml:605-636,684-737 | Lima VM 矩阵;CRI-in-UserNS |
| containerd release.yml:36-46,72-84 | 签名 tag 校验;6 平台 buildx |
| containerd RELEASES.md:44-48,86-103 | 4 个月节奏对齐 K8s;8 个月支持/年度 LTS |
| containerd .golangci.yml:21-22 | depguard 禁依赖 runc |
| runc Makefile:149-153,175-189 | test 三合一;bats/rootless 入口 |
| runc Makefile:114-128,252-253 | 8 架构 release;keyring 校验 |
| runc tests/integration/helpers.bash:6-40 | bats 基础设施:版本要求/镜像注入/TESTBINDIR |
| runc tests/rootless.sh:25,174-190 | ALL_FEATURES 与幂集循环(卷一 F 呼应) |
| runc script/release_build.sh:22-65 | 自建 libseccomp/libpathrs + 可复现 ldflags |
| runc test.yml:35-53,247-249 | 特性开关大矩阵;Lima 发行版矩阵 |
| runc .golangci.yml:39-45 | forbidigo 禁 os.Create(CVE-2024-45310) |
| runc go.mod:19 | opencontainers/cgroups 独立模块 |
