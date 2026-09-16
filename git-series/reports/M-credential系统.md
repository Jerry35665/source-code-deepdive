# Git credential 凭证系统深读（存储 / 填充 / 协议）

> 调研对象：git.git @ commit 47ce805（"A bit more for -rc1"）。
> 本文所有行号均以该 commit 的仓库相对路径核对（grep -n / Read 实测）。

---

## 1. 全景：一次 `git push` 的凭证流程

HTTP(S) push 的完整凭证生命周期，从 URL 到 approve/erase 全链路：

```
git push https://github.com/user/repo.git
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ remote-curl / http.c                                        │
│   http_init(url)                                            │
│     credential_from_url(&http_auth, url)   http.c:1498      │
│     解析 protocol/host/path/username/password 进 credential │
└──────────────────────────┬──────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ credential_fill()                          credential.c:504 │
│   ① 读 credential.* 配置 → helpers 列表    credential.c:172 │
│   ② 逐个启动 helper 子进程: get            credential.c:519 │
│        git credential-store get                             │
│        git credential-cache get                             │
│      stdin/stdout 走 key=value 行协议                       │
│   ③ 第一个补齐 username+password 的 helper 赢               │
│   ④ 都没有 → askpass/终端询问用户           credential.c:542│
└──────────────────────────┬──────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ HTTP 认证                                   http.c:638      │
│   CURLOPT_HTTPAUTH = http_auth_methods     http.c:1658      │
│   CURLOPT_USERNAME / CURLOPT_PASSWORD      http.c:664-665   │
│   或 Authorization: <authtype> <credential> http.c:628-632  │
└──────────────────────────┬──────────────────────────────────┘
                           ▼
              ┌────────────┴────────────┐
        2xx 成功                    401 未授权
              ▼                         ▼
 credential_approve()        credential_reject()
 http.c:1928                 http.c:1952
 → 向全部 helper 广播 store  → 向全部 helper 广播 erase
 → helper 把凭证持久化       → helper 删除坏凭证；内存密钥清零
 （重试逻辑 HTTP_REAUTH: http.c:1973）
```

三个入口函数即 credential.h:44-48 注释中的三个基本操作：fill（获取）、
approve（标记成功并存储）、reject（标记失败并擦除），函数声明在 credential.h:227-249。
对外命令行形态是 `git credential fill|approve|reject`（builtin/credential.c:9-10、36-45）：
从 stdin 读 key=value 描述，调同一套 C API，结果写 stdout——`git credential`
本身就是协议的"零号 helper"调度器。

---

## 2. credential 结构专节：字段与前缀匹配

### 2.1 字段清单

`struct credential` 定义在 credential.h:131-194。关键字段：

| 字段 | 行号 | 含义 |
|---|---|---|
| `helpers` | credential.h:141 | string_list，按配置顺序排列的 helper 命令 |
| `wwwauth_headers`；`state_headers`/`state_headers_to_send` | credential.h:148/153/158 | 服务端 WWW-Authenticate 头；多阶段认证 state 透传 |
| `username` / `password` | credential.h:180-181 | 经典用户名/密码对 |
| `credential` + `authtype` | credential.h:182/193 | 新式凭据（如 Bearer token），authtype 为 NULL 时 curl 自由协商 |
| `protocol` / `host` / `path` | credential.h:183-185 | 凭证的"主键"上下文 |
| `password_expiry_utc`；`oauth_refresh_token` | credential.h:186-187 | 密码过期时间戳；OAuth 刷新令牌 |
| 位标志 `approved/ephemeral/quit/use_http_path/...` | credential.h:167-175 | 状态开关 |

所有字符串字段都是堆分配或 NULL（credential.h:122-124 注释），初始化必须走
`CREDENTIAL_INIT`（credential.h:196-204），它把 `password_expiry_utc` 置为
TIME_MAX（永不过期）、`sanitize_prompt` 与 `protect_protocol` 默认开。

### 2.2 URL → credential 字段的解析

`credential_from_url_1()`（credential.c:620-693）手工解析三种形态
（注释见 credential.c:627-632）：

```c
/* credential.c:651-668（节选） */
if (!at || slash <= at) {
        /* Case (1) proto://<host>/... */
        host = cp;
}
else if (!colon || at <= colon) {
        /* Case (2) proto://<user>@<host>/... */
        c->username = url_decode_mem(cp, at - cp);
        ...
} else {
        /* Case (3) proto://<user>:<pass>@<host>/... */
        c->username = url_decode_mem(cp, colon - cp);
        c->password = url_decode_mem(colon + 1, at - (colon + 1));
```

解析后逐组件检查换行注入（check_url_component，credential.c:583-595、685-690）——
value 带 `\n` 直接判定为坏 URL，堵死"URL 里藏回车伪造协议行"的攻击面。不可解析时
`credential_from_url()` die（credential.c:706-710），温和版返回 -1（credential.c:701-704）。
`git credential fill` 的 stdin 也允许直接给一行 `url=...`，由 credential_read
转调 credential_from_url（credential.c:376-377）。

### 2.3 前缀匹配的粒度：credential_match

helper 返回的凭证与"想要的凭证"之间用 `credential_match()`（credential.c:89-100）：

```c
/* credential.c:92-99 */
#define CHECK(x) (!want->x || (have->x && !strcmp(want->x, have->x)))
        return CHECK(protocol) &&
               CHECK(host) &&
               CHECK(path) &&
               CHECK(username) &&
               (!match_password || CHECK(password)) &&
               (!match_password || CHECK(credential));
```

语义是**逐字段精确相等、want 为空即通配**——这是 helper 侧（cache/store）
的匹配粒度，不是子目录前缀匹配：`path=foo/bar` 不会匹配 `path=foo`。

配置层的匹配（`credential.https://example.com.helper` 这类 URL 化的 config key）
才走 urlmatch 的层级归并：credential_apply_config（credential.c:172-208）把当前
credential 百分号编码格式化成 URL（credential_format，credential.c:223-239）后交给
urlmatch_config_entry。另一个细节：HTTP 协议默认丢掉 path，除非
`credential.useHttpPath=true`（proto_is_http 判定 credential.c:140-145，丢弃
credential.c:205-207）——即默认粒度是 **protocol://host**。

---

## 3. helper 协议专节：子进程与 key=value 行协议

### 3.1 helper 命令的构造与子进程启动

`credential_do()`（credential.c:484-502）把 helper 名翻译成命令：`!` 开头取余下
部分直接作为 shell 命令（credential.c:490-491）；绝对路径原样执行（:492-493）；
其他拼 `git credential-<name>`（:494-495）；最后追加操作参数 `get|store|erase`
（:497）。`run_credential_helper()`（credential.c:444-482）用 child_process 起子进程：

```c
/* credential.c:451-464（节选） */
strvec_push(&helper.args, cmd);
helper.use_shell = 1;
helper.in = -1;
if (want_output)
        helper.out = -1;      /* get：要读 helper 的 stdout */
else
        helper.no_stdout = 1; /* store/erase：丢弃输出 */
...
credential_write(c, fp, want_output ? CREDENTIAL_OP_HELPER
                                    : CREDENTIAL_OP_RESPONSE);
```

注意 sigchain 压住 SIGPIPE（credential.c:463-466）：helper 提前退出时 Git 不至于被写管道炸死。

### 3.2 stdin/stdout 的 key=value 行协议

写协议 `credential_write()`（credential.c:409-442）：每行 `key=value\n`，先写
capability 行（若有），再写 `protocol`（必填）、`host`（必填）、
`path/username/password/oauth_refresh_token/password_expiry_utc`（可选）
（credential.c:423-433），最后 wwwauth[] 与 state[]（:434-440）。`credential_write_item()`
有两道防线：value 含 `\n` 直接 die（credential.c:400-401）；含 `\r` 且
`protect_protocol` 开启也 die（credential.c:402-405）——CR 防护是 CVE-2020-5260
一类注入的后续加固，注释明示可用 `credential.protectProtocol=false` 关闭。

读协议 `credential_read()`（credential.c:314-390）：按行找第一个 `=`（:320-321），
空行结束（:323-324），无法识别的行警告并返回 -1（:326-330），**未知 key 静默忽略
以向前兼容**（:381-385 注释）。已识别的 key 包括 username/password/credential/
protocol/host/path/ephemeral/wwwauth[]/state[]/capability[]/continue/
password_expiry_utc/oauth_refresh_token/authtype/url/quit（:333-380）。
`quit=true` 让 fill 立即中止（credential.c:537-539），`url=` 就地展开成字段。

能力协商三阶段：`capability[]=authtype/state` 只在上一阶段声明过时才向下游转发——
`credential_has_capability()` 的级联判断（credential.c:296-312）：OP_HELPER 看
request_initial，OP_RESPONSE 要 request_initial && request_helper。
`git credential capability` 子命令可探测本版 Git 支持什么（builtin/credential.c:27-31；
credential_announce_capabilities，credential.c:83-87）。

### 3.3 多 helper 链式调用：第一个赢，广播存储

`credential_fill()`（credential.c:504-545）核心循环：

```c
/* credential.c:519-540（节选） */
for (i = 0; i < c->helpers.nr; i++) {
        credential_do(c, c->helpers.items[i].string, "get");

        if (c->password_expiry_utc < time(NULL)) {
                credential_clear_secrets(c);
                c->password_expiry_utc = TIME_MAX;
        }
        if ((c->username && c->password) || c->credential) {
                strvec_clear(&c->wwwauth_headers);
                return;                  /* ← 第一个补齐的 helper 赢 */
        }
        if (c->quit)
                die("credential helper '%s' told us to quit", ...);
}
```

要点：

1. **每个 helper 依序 get，后一个能看到前一个的输出**（credential_read 把字段
   并回同一结构），helper 链可"接力补全"：一旦 username+password 齐（或
   credential 非空）立即 return（credential.c:533-536），与 gitcredentials.adoc:194-197
   "提供完整凭证后不再试后续"一致。
2. **过期密码不直接采用**：password_expiry_utc 已过就清空 secrets 继续找
   （credential.c:522-532，注释解释为何不能用 credential_clear）。
3. helper 列表来自配置归并：`credential.helper` 逐条 append，**空值清空整个列表**
   （lower-priority 覆盖语义，credential.c:119-123；gitcredentials.adoc:199-202）。
4. 全部落空 → getpass：`credential.interactive=false/never` 拒绝交互
   （credential.c:268-282），否则 Username 带回显、Password 走 askpass
   （credential.c:285-290，flag 定义 prompt.h:4-5）。

`credential_approve()`（credential.c:547-563）与 `credential_reject()`
（credential.c:565-581）则是**广播**：遍历全部 helper 依次发 `store`/`erase`
（credential.c:560-561、573-574）。approve 有幂等闸 `approved`（credential.c:551-552）
与完整性闸（半截或过期凭证不广播，credential.c:553-554）；reject 清空内存密钥与
username，为下一轮 fill 复位（credential.c:576-580）。

测试对照：t/t0300-credentials.sh:86（fill 调 helper）、:163（多 helper）、
:346（approve 调全部 helper）、:425（reject 调全部 helper）。

---

## 4. store / cache 对比专节：明文文件 vs socket daemon

### 4.1 credential-store：.git-credentials 明文文件

默认路径解析（builtin/credential-store.c:195-203）：`--file` 优先；否则
`~/.git-credentials` 加 `$XDG_CONFIG_HOME/git/credentials` 两个都收；写入优先选
**已存在**的第一个文件，全不存在则创建 fns[0]（store_credential，store.c:114-139）。

存储格式是**每行一个 URL**：`proto://user:pass@host/path`，逐段百分号编码
（store_credential_file，store.c:93-112）。文件是明文，git-credential-store.adoc:90
明说 "stored in plaintext"；进程入口先 `umask(077)` 兜底权限（store.c:188）。

查找（lookup_credential，store.c:160-167）逐行用 credential_from_url_gently 解析，
要求 username、password 双全且 credential_match 匹配（parse_credential_file，
store.c:33-44）。erase 走**锁文件 + 重写整文件**：rewrite_credential_file
（store.c:65-78，锁超时可用 credentialStore.lockTimeoutMs 调，:70-72），把不匹配的
行原样抄回、匹配的行丢弃；erase 要求匹配模式非全空，防"空输入=全删"
（remove_credential 防御性注释，store.c:146-154）；store 也走同一重写路径
（追加一行，:73-75）。

### 4.2 credential-cache：unix socket 上的内存 daemon

客户端 builtin/credential-cache.c：

- socket 默认 `~/.git-credential-cache/socket`，目录存在则用之，否则
  `$XDG_CACHE_HOME/git/credential/socket`（get_socket_path，cache.c:120-131）；
- 默认 TTL **900 秒**（`int timeout = 900`，cache.c:147；git-credential-cache.adoc:34
  亦载），可用 `cache --timeout=3600` 覆盖；
- `store` 动作带 FLAG_SPAWN：连接失败先拉起 daemon 重试（do_cache，cache.c:96-118；
  spawn_daemon，:71-94，等待 daemon 打印 "ok\n" 握手，:89-90）；
- `get/erase` 用 FLAG_RELAY 把 stdin 的凭证描述原样转发（:177-180）。

daemon 端 builtin/credential-cache--daemon.c：

- 凭证存内存数组 `entries[]`，每条带 `expiration = time(NULL) + timeout`
  （cache_credential，daemon.c:23-34）；
- 过期清扫 + 决定 daemon 存活：check_expirations（daemon.c:59-101）——空表时再等
  30 秒新凭证，没等到返回 0 让主循环退出，实现**按需自毁**；
- 主循环 poll 等连接，逐个 accept、dup、xfdopen 后 serve_one_client
  （serve_cache_loop，daemon.c:189-229）；
- socket 监听：unix_stream_listen 后先向父进程打 "ok\n" 再关 stdout
  （serve_cache，daemon.c:231-251）；
- 客户端私协议：第一行 `action=`、第二行 `timeout=`，之后复用标准 key=value
  凭证描述（read_request，daemon.c:103-124）；
- 安全细节：socket 目录权限过松直接拒绝启动；必须以 0700 **创建**目录而非事后
  chmod，避免竞态（init_socket_directory 注释，daemon.c:253-289）。

### 4.3 对比小结

| 维度 | credential-store | credential-cache |
|---|---|---|
| 载体 | 明文文件 ~/.git-credentials（store.c:198） | 进程内存 + unix socket（daemon.c:236） |
| 生命周期 | 永久，直到 erase | TTL 默认 900s（cache.c:147），daemon 空闲自毁（daemon.c:94-98） |
| 查找 | 逐行 URL 解析 + credential_match（store.c:33-44） | 内存数组 + credential_match（daemon.c:36-45） |
| 写入 | 锁文件 + 全文件重写（store.c:65-78） | remove 后 cache_credential 追加（daemon.c:170-180） |
| 主要风险 | 文件泄露即密码泄露（umask 077 兜底，store.c:188） | socket 目录权限（daemon.c:253-289） |

---

## 5. 与 HTTP 认证的联动专节

http.c 持有四个独立 credential 实例：`http_auth`（仓库认证，http.c:125）、
`proxy_auth`（http.c:121）、`cert_auth` 与 `proxy_cert_auth`（客户端证书密码，
http.c:80/132）。联动点：

1. **URL 注入**：http_init 里 `credential_from_url(&http_auth, url)`
   （http.c:1497-1503）；重定向后 base_url 变化时重新解析（http.c:2429-2434）；
   代理 URL 同理（http.c:1300-1304）。
2. **curl 参数设置**：每个请求槽位先 `CURLOPT_HTTPAUTH = http_auth_methods`
   （http.c:1658；初值 CURLAUTH_ANY，http.c:134），需要时才调 init_curl_http_auth
   （http.c:638-667）：

```c
/* http.c:652-665（节选） */
credential_fill(the_repository, &http_auth, 1);
if (http_auth.password) {
        if (always_auth_proactively())
                curl_easy_setopt(result, CURLOPT_HTTPAUTH, CURLAUTH_BASIC);
        curl_easy_setopt(result, CURLOPT_USERNAME, http_auth.username);
        curl_easy_setopt(result, CURLOPT_PASSWORD, http_auth.password);
}
```

   有 authtype+credential（如 Bearer）时则不走 CURLOPT_*，而是拼
   `Authorization: <authtype> <credential>` 头（http_append_auth_header，
   http.c:625-636），remote-curl 亦复用此函数（remote-curl.c:890/965）。
   空密码探测技巧：`CURLOPT_USERPWD, ":"` 触发 401 以枚举服务端支持的方案
   （http.c:642-643；empty_auth_useless 定义 http.c:136-141）。
3. **结果 → approve/reject**：handle_curl_result（http.c:1922-1988）——CURLE_OK
   即 approve 三件套（http.c:1928-1930）；SSL 证书问题 reject cert_auth
   （http.c:1932-1940）；**401 且已有凭证时 reject http_auth**（http.c:1945-1955），
   若 helper 标了 multistage（continue=true）则只清 secrets 留上下文换下一阶段
   （http.c:1948-1951）；407 reject proxy_auth（http.c:1980-1981）。
4. **方案收敛**：401 后 `http_auth_methods &= results->auth_avail` 把 curl 可选
   方案收缩到服务端宣告的交集（http.c:1969-1972）；auto 模式下先给 Negotiate 一次
   机会再剥离（http.c:1957-1968）。重试循环在 http_request_recoverable
   （HTTP_REAUTH 最多 3 次，http.c:2410/2437-2438），重试前经 http_reauth_prepare
   再走一轮 credential_fill（http.c:669-683）。客户端证书密码用伪 protocol="cert"、
   path=证书路径编码进 credential 主键（has_cert_password，http.c:736-748）。

这与 curl 系列 02 章的 CURLOPT_USERNAME/PASSWORD/HTTPAUTH 语义一一对应：
Git 把"凭证从哪来"交给 helper 体系，把"凭证怎么用"交给 libcurl 的认证状态机。

---

## 6. 设计动机

1. **helper 为什么是外部进程**：凭证后端天然碎片化——macOS 钥匙串、Windows
   凭证管理器、GNOME Keyring、1Password、getpass……内置任何一个都会把 Git 绑死在
   某平台 API 上。外部进程 + 行协议等于免费的插件体系：第三方只需实现一个能读
   stdin 的可执行程序（`!` 前缀甚至不要求安装成 git 子命令，credential.c:490-491）。
   credential.h:9-29 的 ASCII 图明确画出 Git 代码、helper、用户以管道相连。密钥也
   不必长期驻留 Git 进程内存。
2. **三阶段协议的必要性**：fill/approve/reject 把"取凭证"与"验证凭证"解耦——
   只有 Git 知道服务器是否接受（helper 无法预知），所以必须由调用方拿到 HTTP 结果后
   回填结论（http.c:1927-1955）。没有 approve，helper 只能盲目存储可能错误的密码；
   没有 reject，坏凭证会一直被优先命中。approve 的幂等闸（credential.c:551-552）与
   reject 的内存清零（credential.c:576-580）分别防重复存储与密钥残留。
3. **协议可进化性**：capability 协商（credential.h:108-118、credential.c:296-312）
   让 authtype/state 这类新特性渐进铺开——老 helper 不认识 capability 行会被
   credential_read 的"未知 key 忽略"逻辑吃掉（credential.c:381-385），新 Git 也不会
   向未声明的 helper 发送新字段。
4. **与 13 章 gossip 的一句话对比**：gossip 场景里"凭证/信任状"是对等节点间传播、
   靠多数共识维持的活性数据，而 git credential 是单机边界上的静态秘密——前者解决
   "谁在网内可信"，后者只解决"这台机器如何替用户向一台服务器自证"。

---

## 7. FAQ 素材

1. **Q: `git credential fill` 的输入字段从哪来？** stdin 按 key=value 解析进 struct credential（credential.c:314-390），`url=` 一行会被 credential_from_url 就地展开（credential.c:376-377）。
2. **Q: 多个 helper 都返回凭证，用哪个？** 按配置顺序遍历，第一个把 username+password 补齐（或给出 credential）的赢，立即返回（credential.c:519-536）。
3. **Q: helper 存的密码错了会自动重试吗？** 401 触发 credential_reject 广播 erase 并返回 HTTP_REAUTH，重试最多 3 次（http.c:1952、2410）。
4. **Q: 怎么让后配置的 helper 覆盖系统级配置？** `credential.helper` 置空串清空此前累积的列表（credential.c:122-123；gitcredentials.adoc:199-202）。
5. **Q: HTTPS 下 path 参与匹配吗？** 默认不参与——非 useHttpPath 时 HTTP(S) 的 path 置 NULL（credential.c:205-207）；helper 侧 credential_match 也只在 want 非空时才比 path（credential.c:92-98）。
6. **Q: .git-credentials 是加密的吗？** 不是，明文 URL 每行一条（git-credential-store.adoc:90；写入逻辑 store.c:93-112），仅靠 umask 077（store.c:188）兜底；要安全存储请用 osxkeychain/wincred/libsecret。
7. **Q: credential-cache 的 daemon 何时退出？** 空表后再等 30 秒无新凭证即自毁（daemon.c:59-101）；也可 `git credential-cache exit`（daemon.c:157-167）。
8. **Q: 为什么 HTTP 默认丢 path 而 cert 不丢？** proto_is_http 判定 + useHttpPath 开关（credential.c:140-145、205-207）；cert 凭证反而靠 path 携带证书路径作主键（http.c:740-745）。
9. **Q: 协议里的 `quit=true` 是什么？** helper 可令 fill 直接中止（credential.c:537-539），表达"别再问任何 helper/用户"。
10. **Q: URL 里自带的密码会被怎样处理？** `proto://user:pass@host` 解析时进 c->password（credential.c:661-667），fill 阶段直接短路返回（credential.c:509-510）。

## 8. 深挖方向

1. **CVE-2020-5260 与 credential.protectProtocol**：恶意服务器可借 `\r` 注入伪造 credential 行；现在 credential_write_item 对 CR 直接 die（credential.c:402-405），可对照 commit 历史看加固时序。
2. **capability 状态机的三段级联**：`credential_has_capability` 要求前一阶段声明才转发（credential.c:296-312），t0300:182 专测"helper 无能力时响应不带 capability"——理解协议兼容性的最佳切片。
3. **multistage/continue 与 OAuth 流**：helper 声明 `continue=1`（credential.c:363-364）后，http.c:1948-1951 只清 secrets 保留 authtype 上下文，支持多轮协商（state[] 头透传，credential.c:436-441）。
4. **store 的锁与并发**：rewrite_credential_file 用 hold_lock_file_for_update（store.c:71-77），锁超时可配；可对比 index/ref 的锁策略。
5. **oss-fuzz/fuzz-credential-from-url-gently**（Makefile:2615）：URL 解析器有专属模糊测试目标，可结合 check_url_component 的换行校验（credential.c:583-595）看解析类输入攻击的防御。

---

## 写作要点速查表

| 关键点 | 文件:行号 |
|---|---|
| credential 结构定义（全部字段） | credential.h:131-194 |
| fill/approve/reject 三操作声明 | credential.h:44-48, 227-249 |
| credential_match 通配式精确匹配 | credential.c:89-100 |
| credential.helper 解析（空值清列表）/HTTP 默认丢 path | credential.c:119-123, 205-207 |
| credential_read / credential_write 行协议 | credential.c:314-390, 392-442 |
| helper 子进程启动与命令构造 | credential.c:444-502 |
| credential_fill 主循环（第一个赢） | credential.c:504-545 |
| credential_approve / credential_reject 广播 | credential.c:547-581 |
| URL 解析三形态 | credential.c:620-693 |
| store 默认路径 ~/.git-credentials + XDG | builtin/credential-store.c:195-203 |
| store 明文 URL 格式 + 锁重写 | builtin/credential-store.c:93-112, 65-78 |
| cache 客户端 TTL=900 + spawn daemon | builtin/credential-cache.c:147, 71-118 |
| cache daemon socket 监听 + 0700 目录 | builtin/credential-cache--daemon.c:231-251, 258-289 |
| daemon 过期清扫与自毁 | builtin/credential-cache--daemon.c:59-101 |
| http URL 注入 credential | http.c:1497-1503 |
| curl 认证参数设置 | http.c:638-667, 625-636, 1658 |
| 结果回调 approve/reject + 401 收敛 | http.c:1922-1988 |
| `git credential` 命令入口 | builtin/credential.c:12-52 |
