# B 篇 · URL 解析与认证体系

> 调研对象:curl 源码,shallow clone,commit `0b04700`("urlapi: run the urlparser perf test faster",2026-09-13)。以下所有行号以该 commit 为准,行文格式为 `仓库相对路径:行号`。

---

## 1. 全景:一次"带重定向 + 认证 + cookie"的请求解剖

以 `curl -L -u alice:s3cret --cookie-jar jar.txt https://a.example/` 为例(伪代码式流程,方括号内为关键函数):

```
用户输入 "https://a.example/"
   |
   v
[tool_operate.c:1263] 命令行层:若未加 -g(--globoff),先做 {} [] glob 展开(仅工具层,libcurl 无此功能)
   |
   v
[lib/url.c:2099] curl_url_set(CURLUPART_URL, url, CURLU_GUESS_SCHEME|...)
   |     └─> [lib/urlapi.c:1223 parseurl] 状态机分阶段解析:scheme → authority → fragment → query → path
   v
[lib/url.c:1355 url_set_data_creds] 凭据来源链:CURLOPT_USERPWD(CREDS_OPTION) > URL 内 user:pass(CREDS_URL)> .netrc(CREDS_NETRC)
   |
   v
[lib/url.c:1164 url_set_conn_scheme] 协议白名单:allowed_protocols / 重定向时 redir_protocols;HSTS 升级(url.c:1201)
   |                    （有代理则先走 CONNECT 隧道,见第 6 节）
   v
(1) 第一轮请求 GET / (带 Cookie: 头 http.c:2552 http_cookies,数据来自 cookie.c 域匹配)
   |
   v
<-- HTTP/1.1 401 Unauthorized   WWW-Authenticate: Negotiate, NTLM, Basic realm="x"
   |
[lib/http.c:1067 Curl_http_input_auth] 逐个识别 scheme,置位 state.authhost.avail(1110-1142)
[lib/http.c:555 Curl_http_auth_act] pickoneauth 按偏好顺序挑一种(http.c:349-391):
   |     Negotiate > Bearer > Digest > NTLM > Basic > AWS_SIGV4 > HTTPSIG
   |     挑中后 data->req.newurl = 当前 URL 克隆(611-615)→ 触发"轮"
   |
   v
[lib/multi.c:2107-2113] multi 循环发现 newurl → multi_follow(..., FOLLOW_RETRY)(区别于 FOLLOW_REDIR)
[lib/http.c:1175 Curl_http_follow] 重放请求:重置请求体(rewind),再次输出认证头
   |
   v
(2) 第二轮请求,Authorization 头由 output_auth_headers(http.c:646)按 picked 生成:
   |     Negotiate → [http_negotiate.c:155] GSS token 往返;NTLM → [http_ntlm.c:116] type1/2/3;Digest → [http_digest.c:109]
   |     Basic/Bearer 一步到位,置 done=TRUE(http.c:747/763)
   |
   v
<-- HTTP/1.1 200 OK        (若仍有 401 且已 done → http_should_fail http.c:486 判定终败)
   |
   v
<-- Set-Cookie: sid=...; Domain=.example.com; Secure
[lib/http.c:3557 Curl_cookie_add] 存入 cookie 引擎:PSL 检查 + tailmatch 域检查(cookie.c:505/800)
   |
   v
<-- 302 Location: https://b.example/next
[lib/http.c:1175 Curl_http_follow(FOLLOW_REDIR)]  maxredirs 检查(1190-1198)、相对 URL 拼接(urlapi.c:1333 redirect_url)
   |   跨 host:Digest 缓存清空(http.c:1276-1282);凭据默认不外带(vauth.c:145 Curl_auth_allowed_to_origin)
   v
下一轮连接 …… followlocation 计数直至 maxredirs(默认 30,url.c:335)
```

两条主线贯穿全篇:**URL 先被规范化成结构化的 `Curl_URL`**,一切(host 匹配、cookie、same-origin 判断)都基于这个规范化结果;**认证被建模成"轮"(round)**——`struct auth`(urldata.h:476-486)的 want/avail/picked/done/multipass 五个字段驱动多轮协商。

---

## 2. URL 解析器专节:lib/urlapi.c

### 2.1 历史与定位

curl 7.62.0 起引入 `curl_url` API 与 `lib/urlapi.c` 自研解析器,取代此前散落在 lib/url.c 里的过程式解析;同时它**不是** WHATWG URL 实现——官方立场是"RFC 3986 plus"(docs/URL-SYNTAX.md:61-63),只在少数几处向现实妥协。顶层结构 `struct Curl_URL` 是十个部件 + 四个状态位(urlapi-int.h:30-45),其中 `query_present/fragment_present` 单独存在,是为了区分"没有 query"与"空 query"。

### 2.2 解析状态机(parseurl,五阶段)

主函数 `parseurl`(urlapi.c:1223-1311)按固定顺序推进:

1. **scheme 阶段**:`Curl_is_absolute_url`(urlapi.c:213-253)用"ALPHA 后跟 `+-.` 字符、再遇冒号"的扫描判定绝对 URL,scheme 一律转小写(227/232 行 `Curl_raw_tolower`);guess 模式下必须冒号后跟 `/` 才算 scheme,否则 `data:` 会被误判为主机名 `data` + 端口(239-243 行注释)。`file:` 走独立分支 `parse_file`(urlapi.c:941-1031):只接受空主机、`localhost`、`127.0.0.1`(991-1001),Windows 盘符仅限 Windows 平台(1011-1022)。
2. **authority 阶段**:`parse_authority`(urlapi.c:700-746)串起四个子步骤——`parse_hostname_login`(276-380,拆 `user:password;options@`,仅 IMAP 类 scheme 保留 options)→ `parse_port`(383-441)→ `urldecode_host`(674-698,主机名百分号解码)→ IPv6/IPv4/域名三选一检查。
3. **fragment 阶段**:`handle_fragment`(urlapi.c:1119-1143),`memchr(path,'#')` 找到即截断。
4. **query 阶段**:`handle_query`(urlapi.c:1145-1176),空 query(`?` 结尾)也保留 `""` 以维持 `query_present`。
5. **path 阶段**:`handle_path`(urlapi.c:1178-1221),除非 `CURLU_PATH_AS_IS`,否则跑 `dedotdotify` 按 RFC 3986 5.2.4 消解 `./ ../`(768-770 的注释引用原文;`needs_dedotdot` 793-815 做预扫描,没点没 `%` 直接跳过)。

```c
/* lib/urlapi.c:1281-1302(节选) */
  if(!ures) {
    /* The path might at this point contain a fragment and/or a query */
    const char *fragment = memchr(path, '#', pathlen);
    if(fragment) {
      size_t fraglen = pathlen - (fragment - path);
      ures = handle_fragment(u, fragment, fraglen, flags);
      /* after this, pathlen still contains the query */
      pathlen -= fraglen;
    }
  }
  if(!ures) {
    const char *query = memchr(path, '?', pathlen);
    ...
```

### 2.3 规范化规则

- **百分号编码**:`urlencode_str`(urlapi.c:124-203)只在 `CURLU_URLENCODE` 下工作:空格 → `%20`(query 里是 `+`,149-156 行,由 QUERY_NO/NOT_YET/YES 三态区分,urlapi-int.h:52-54);控制字节与 >=0x7f 的字节转 `%XX`(157-163);**已有 `%xx` 但十六进制是小写时重写为大写**(164-175)——这是 curl 的归一化细节,非法百分号序列原样保留(114 行注释)。
- **默认端口与大小写**:端口解析 `parse_port`(urlapi.c:383-441)规定"冒号后无数字 → 忽略冒号用默认端口,与 Firefox/Chrome/Safari 一致"(416-419 注释);IPv6 用 `]` 后找 `:`(395-407)。scheme 本身不分大小写(2.2),域名检查前转小写由 cookie/比较函数按需处理。
- **IPv6 与 zone id**:`ipv6_parse`(urlapi.c:448-502)先白名单字符校验 `strspn(hostname,"0-9a-fA-F:.")`(461),再支持 `[fe80::1%25eth0]` 与 `[fe80::1%eth0]` 两种 zone id 写法(465-483,`25` 是被编码的 `%`),zone id 上限 `MAX_ZONEID_LEN` 16 字节(56);最后 `inet_pton`+`inet_ntop` 往返做**地址规范化**(489-500,如 `[0000::1]` → `[::1]`)。
- **IPv4 简写**:`ipv4_normalize`(urlapi.c:568-671)接受十进制/十六进制(`0x7f`)/八进制(`0177`)及 1-4 段混合简写(`16843009`、`0x7f.1`),统一输出成点分四段。
- **主机名黑名单**:`invalid_host_char[256]` 表(urlapi.c:507-516)禁掉空格、`" \r\n\t/:#?!@{}[]\\$'\"^`*<>=;,+&()%|` 等;`hostname_check`(519-534)禁止连续两个尾点与孤立单点。
- **scheme 猜测**:`guess_scheme`(urlapi.c:1091-1117)按主机名前缀猜:`ftp.` → ftp、`dict.`/`ldap.`/`imap.`/`smtp.`/`pop3.` 各归其主,其余一律 http(1096-1109);这是 curl 命令行的历史遗产,`CURLU_NO_GUESS_SCHEME` 可在 get 时隐藏猜测结果(1693-1694)。
- **斜杠容忍**:`parse_scheme`(urlapi.c:1033-1089)允许 scheme 后 1-3 个斜杠,超过 3 个报 `CURLUE_BAD_SLASHES`(1057-1062)——WHATWG 允许无限斜杠,这是两者的显式分歧点(docs/URL-SYNTAX.md:83-89)。

### 2.4 与 WHATWG URL 的异同(带出处)

| 维度 | curl(urlapi.c) | WHATWG |
|---|---|---|
| 基础规范 | RFC 3986(docs/URL-SYNTAX.md:14) | 自成一体的活标准 |
| 多余斜杠 | 容忍 1-3 个(1057-1062) | 1 到无限个(docs/URL-SYNTAX.md:83-89) |
| 空格 | 默认拒绝(`badoctets` urlapi.c:256-266),仅 `CURLU_ALLOW_SPACE`(重定向 Location 用,http.c:1247)后重编码为 %20(docs/URL-SYNTAX.md:69-76) | 自动容忍 |
| IPvFuture | 不支持(docs/URL-SYNTAX.md:209-211) | 支持 |
| IDNA | libidn2 用 IDNA 2008,WinIDN 用 2003 过渡处理(docs/URL-SYNTAX.md:227-235) | IDNA 2008(非过渡) |
| 反斜杠 | `parse_port` 遇 `\` 显式报 `CURLUE_BACKSLASH`(426-432) | 作为路径字符 |

### 2.5 curl_url API 与相对 URL 拼接

- `curl_url_set(CURLUPART_URL, "")` 空串有特殊语义:已有完整 URL 时,视为"去掉 fragment 的自引用"(RFC 3986 5.2.2,urlapi.c:1833-1849)。
- 相对 URL 拼接 `redirect_url`(urlapi.c:1333-1407)是手写的分支机:`//host` 换 authority、`/path` 换 path、`#frag` 只换 fragment、纯 query 换 query,最后重新走一遍 `parseurl_and_replace`。这正是处理 `Location: next` 的引擎。
- `Curl_url_same_origin`(urlapi.c:2175-2208)实现 same-origin 判断:scheme、host、端口(含"一边缺省 = 默认端口"的归一,2188-2196)、zoneid 四重比较;重定向时用它决定是否清 Digest 缓存(http.c:1276-1282)。

---

## 3. 重定向专节:Curl_http_follow 的安全规则

历史上的 `Curl_follow` 现名为 `Curl_http_follow`,已收编进 lib/http.c:1175-1414(独立 redirect.c 已不存在)。触发点在 multi 主循环:`data->req.newurl` 非空即 `multi_follow`,认证重试标 `FOLLOW_RETRY`,真重定向标 `FOLLOW_REDIR`(multi.c:2107-2113)。

**规则 1:次数上限。** `maxredirs != -1` 且 `followlocation >= maxredirs` 时转为 `FOLLOW_FAKE`——只把目标 URL 写进 `data->info.wouldredirect` 供应用查询,然后报 `CURLE_TOO_MANY_REDIRECTS`(http.c:1190-1195、1294-1296);默认上限 30(url.c:335)。

**规则 2:协议白名单(降级限制)。** 检查不在 follow 里,而在建连时:`url_set_conn_scheme`(url.c:1164-1184)要求 scheme 同时满足 `allowed_protocols` 与——`this_is_a_follow` 为真时——`redir_protocols`;默认白名单 `CURLPROTO_REDIR = HTTP|HTTPS|FTP|FTPS`(lib/protocol.h:69-70),即**重定向到 file:/scp:/smtp: 等一律被拒**,应用可用 `CURLOPT_REDIR_PROTOCOLS` 收紧。这是 `--proto-redir` 语义的实现层。

**规则 3:端口锁定。** 非 401/407 引发的、目标是绝对 URL 的重定向,禁止沿用用户强制端口:`disallowport = TRUE` → `data->state.allow_port = FALSE`(http.c:1235-1241、1301-1302)。

**规则 4:凭据剥离(默认不跨 host)。** 新机制不再"删字符串",而是**判断发送时**:`Curl_auth_allowed_to_origin`(vauth/vauth.c:145-150)只有当目标是初始 origin(`state.initial_origin`)或 `CURLOPT_UNRESTRICTED_AUTH` 打开(`allow_auth_to_other_hosts`,setopt.c:468-474)才放行;`Curl_http_output_auth`(http.c:874-878)在放行失败时直接置 `authhost->done=TRUE` 不再发 Authorization。自定义的 Authorization/Cookie 头同样被拦(dynhds_add_custom,http_proxy.c:157-162;http.c:676)。此外跨 host 重定向会清掉 Digest 协商缓存(http.c:1276-1282),NTLM/Negotiate 则因连接级凭据绑定天然无法跨连接复用(http_ntlm.c:192-197 把 creds 钉在 conn 上)。

**规则 5:方法降级。** 301/302 的 POST 默认转 GET(`post301/post302` 可保),303 一律转 GET(`post303` 可保),`http_switch_to_get` 还会丢弃 custom request(http.c:1153-1168、1334-1388)。`CURLFOLLOW_FIRSTONLY/OBEYCODE` 控制行为(1157-1164)。

**规则 6:解析宽松度。** Location 头重定向用 `CURLU_URLENCODE | CURLU_ALLOW_SPACE` 解析(http.c:1244-1248)——现实中的 Location 常带未编码空格,这是对 RFC 3986 的让步(docs/URL-SYNTAX.md:69-76)。 Referer 自动带上时会**剥掉用户名/密码/fragment** 再发(http.c:1209-1231)。

---

## 4. 认证专节:多认证的"轮"状态机

### 4.1 状态容器与调度

每个易用句柄有两套 `struct auth`:`state.authhost`(源服务器)与 `state.authproxy`(代理)(urldata.h:476-486):

```c
struct auth {
  uint32_t want;    /* 应用通过 CURLOPT_HTTPAUTH 设置的位掩码 */
  uint32_t picked;  /* 本轮实际选中的单一 scheme */
  uint32_t avail;   /* 服务器在 401/407 里通告的 scheme */
  BIT(done);        /* 认证阶段结束 */
  BIT(multipass);   /* 正处于多轮协商中 */
};
```

一次轮转的完整闭环:

1. **发请求前** `Curl_http_output_auth`(http.c:798-894):若 `want` 有值但还没 `picked`,先把 `picked = want`(844-854)——单一 bit 时立即生效(第一轮就带上 Basic);多 bit 时第一轮不带认证头裸发。若是 PUT/POST 且认证未完成,置 `req.authneg = TRUE` 做零长度探针请求,避免大请求体反复重发(880-889)。
2. **收到 401/407** `Curl_http_input_auth`(http.c:1067-1151):逗号分隔逐个 scheme 识别,`authcmp` 保证 "NegotiateX" 不误匹配(921-926);命中的置入 `authp->avail`。Negotiate 的挑战 token 在此处被消费并置 `GSS_AUTHRECV`(930-959)。
3. **头收完后** `Curl_http_auth_act`(http.c:555-639):`pickoneauth`(349-391)从 `avail & want & mask` 中按**固定偏好序**挑一个——Negotiate > Bearer > Digest > NTLM > Basic > AWS_SIGV4 > HTTPSIG(360-383),Digest/Basic 还要求有用户名口令;挑中后克隆当前 URL 到 `req.newurl`,由 multi 循环发起下一轮(603-616)。NTLM 被选中时强制 HTTP/1.1 并关闭连接复用(581-587,NTLM 认证状态绑定连接)。
4. **下一轮** 回到第 1 步,这次 `picked` 已是单一 scheme,`output_auth_headers`(646-796)分发到各实现,生成 `Authorization:` 或 `Proxy-Authorization:`。

`done` 与 `multipass` 的组合决定何时终结:Basic/Bearer 一步到位置 done(http.c:747、763);NTLM/Negotiate/Digest 首轮置 `multipass = !done`(785)。若已 done 又收到 401/407,`http_should_fail`(486-547)判死——防止无限循环。

### 4.2 各认证器一句话机制

- **Basic**(http.c:727-748):`user:pass` base64 一发即中,done=TRUE。
- **Bearer**(http.c:751-764):`Authorization: Bearer <token>`,token 来自 `CURLOPT_PROXYTOKEN`/`CREDS` 的 oauth_bearer(creds.h:37)。
- **Digest**(http_digest.c:109 起,核心算法在 vauth/digest.c):从 401 挑战里存 nonce/algorithm(http.c:992-1009 的 auth_digest),第二轮按 RFC 2617 计算 response;md5-sess 类每轮需要挑战,天然多轮。
- **NTLM**(http_ntlm.c:116-249):三步握手 type1(裸发)→ type2(从 401 挑战解析)→ type3(算出响应后 done=TRUE,231 行);**认证状态 `ntlmdata` 挂在 connectdata 上**(vauth.c:163-173 的 conn_meta),连接一断认证即失效,这正是 NTLM 强制连接粘性的原因。连接建立后 type3 → LAST 状态不再发头(176-179)。
- **Negotiate/SPNEGO**(http_negotiate.c:155-259 + vauth/spnego_gssapi.c):GSS-API `gss_init_sec_context` 的 token 往返——客户端发初始 token,服务器回挑战,循环直到 `GSS_S_COMPLETE`(spnego_gssapi.c:213-230);curl 侧状态机 `GSS_AUTHNONE → AUTHRECV → AUTHSENT → AUTHDONE → AUTHSUCC`(urldata.h:173-177),成功后连接内持续免认证(259 行 done=TRUE)。
- **AWS_SIGV4 / HTTPSIG**(http.c:662-684):请求签名类,无协商轮,但 HTTPSIG 受跨 host 边界约束(672-683)。

### 4.3 SASL(邮件协议,简述)

lib/curl_sasl.c 把同样的"协商"思想用于 SMTP/IMAP/POP3:`Curl_sasl_start`(506-510)依据服务器 `AUTH` 能力位与 `SASL_AUTH_*` 掩码选机制(curl_sasl.h:32-42,LOGIN/PLAIN/CRAM-MD5/DIGEST-MD5/GSSAPI/NTLM/XOAUTH2/OAUTHBEARER/SCRAM-SHA-1/256),`Curl_sasl_continue`(579 起)按 `SASL_STOP…` 状态机逐消息推进(curl_sasl.h:66-77)。与 HTTP 的差别:机制列表来自服务器一次通告 + 客户端多轮 base64 消息。

### 4.4 凭据来源链与 .netrc

`struct Curl_creds`(creds.h:34-44)带 `source` 标记,构建优先级在 `url_set_data_creds`(url.c:1355-1442):

1. `CURLOPT_USERNAME/PASSWORD/BEARER/...` → `CREDS_OPTION`(1360-1371),**永不**被 .netrc 覆盖(url.c:1265-1270);
2. URL 内嵌 `user:pass`(URL 解码、控制字节拒绝,1388-1427)→ `CREDS_URL`;
3. .netrc → `CREDS_NETRC`(url.c:1253-1352):三种模式 `CURL_NETRC_OPTIONAL/IGNORED/REQUIRED`,REQUIRED 时 URL 凭据的密码被丢弃只留登录名(1271-1275),否则仅"补缺"(1276-1283)。

`Curl_netrc_scan`(netrc.c:579-640)查找顺序:`NETRC` 环境变量 → `$HOME/.netrc`(599-601)→ Windows `USERPROFILE`(623-625);文件格式限制:单行 16384 字节、整文件 128KB(netrc.c:76-78)。凭据里若含控制字节且协议不支持,直接报错(url.c:1315-1324)。环境变量只此一处参与凭据,没有"密码环境变量"机制。

---

## 5. cookie 引擎专节:lib/cookie.c

### 5.1 存储与解析

cookie 按**域名最后两段**散列到 63 个桶(`cookiehash` cookie.c:190-201,`COOKIE_HASH_SIZE 63` cookie.h:54),桶内链表;`remove_expired`(cookie.c:273-315)惰性清理,并用 `next_expiration` 记录最早到期时间,未到期可整轮跳过(287-291)——大量长会话 cookie 时的性能细节。Set-Cookie 解析走 `Curl_cookie_add`(cookie.c:995 起):头字段(name/value/domain/path)加属性段(secure/httponly/expires/max-age),值中控制字节一律拒绝(`invalid_octets` 345-356,理由注释:某些服务器会对含控制字节的请求回 400)。

### 5.2 域匹配与安全边界

- **tailmatch(cookie → 主机)**:`cookie_tailmatch`(cookie.c:73-100)是"主机名以 cookie 域结尾,且交界处必须是点"的精确实现——`example.com` 匹配 `www.example.com`,但不匹配 `notexample.com`(95-99 的点边界检查)。
- **设置方向的检查(Set-Cookie 时)**:服务器给 `Domain=` 时,该域必须是当前主机的尾匹配,否则拒收(cookie.c:505-521 "skipped cookie with bad tailmatch domain");无 `Domain=` 则仅对当前主机精确匹配、不开 tailmatch。
- **Public Suffix**:编译进 libpsl 时,`is_public_suffix`(cookie.c:800-878)调 `psl_is_cookie_domain_acceptable`(840)阻止 `com`/`co.uk` 级别 cookie;若 cookie 域本身就是公共后缀还强制关掉 tailmatch(844-847)。**没有 libpsl 时退化为 `bad_domain`**(317-334):域内必须有个非尾点的 `.` 或是 localhost——安全强度明显打折,这是构建选项,不是运行时开关。
- **路径匹配**:`pathmatch`(cookie.c:106-156)按 RFC 6265 5.1.4,前缀一致 + 交界是 `/` 或等长。
- **发送**:`Curl_cookie_getlist`(cookie.c:1321-1421)收集匹配项:secure cookie 只在 TLS(或 localhost/127.0.0.1/::1,`Curl_secure_context` 1303-1309)下发送(1348),域匹配三选一(1351-1354:无域 / tailmatch 且非 IP / 精确相等),再 pathmatch(1364);发送上限 `MAX_COOKIE_SEND_AMOUNT 150`(cookie.h:102,1371);同名 cookie 按路径长度排序,长者优先(1403)。

### 5.3 引擎开关

cookie 引擎不是常开的:必须先有"激活事件"(设了 `CURLOPT_COOKIEFILE`/`COOKIEJAR` 等)置 `data->state.cookie_engine = TRUE`(cookie.c:1217、1238;setopt.c:1531、2131),发送侧还要 `data->cookies && data->state.cookie_engine` 双条件(http.c:2565)。`CURLOPT_COOKIEFILE ""` 是经典的"只开引擎不读文件"用法。

---

## 6. CONNECT 隧道专节

代理在 curl 中是**过滤器链上的一层**(cfilters),而非协议内嵌逻辑。三层分工:`http_proxy.c` 造请求/解读响应;`cf-h1-proxy.c`(HTTP/1.x)、`cf-h2-proxy.c`、cf-h3 三个子过滤器负责具体收发;`http_proxy.c:543-659` 的 `http_proxy_cf_connect` 按 ALPN 决定装哪个子过滤器(596-638)。

**造 CONNECT 请求** `http_proxy_create_CONNECT`(http_proxy.c:197-274):authority 为 `host:port`(IPv6 加方括号,211-215);关键是它在隧道阶段就调用 `Curl_http_output_auth(..., is_connect=TRUE)`(228-229)生成 `Proxy-Authorization`;补 `Host:`、`User-Agent`、`Proxy-Connection: Keep-Alive`(234-261);用户自定义头经 `dynhds_add_custom` 过滤后加入——其中自定义 `Authorization`/`Cookie` 头在跨 host 场景被拦(157-162),`Content-Length` 在 authneg 探针期被拦(148-152)。

**H1 隧道状态机** `H1_CONNECT`(cf-h1-proxy.c:631-751),状态枚举 46-53:

```
H1_TUNNEL_INIT ──start_CONNECT──> H1_TUNNEL_CONNECT ──发完──>
H1_TUNNEL_RECEIVE ──响应到齐──> H1_TUNNEL_RESPONSE ──┬─ req.newurl 有值 → 回 INIT 再来一轮(407 重试)
                                                    └─ 无 → 2xx 判定 ──> H1_TUNNEL_ESTABLISHED
```

- 建隧道前检查 `PROTOPT_NOTCPPROXY`(该协议不允许 CONNECT,126-129)。
- 响应逐字节读取避免竞态(500-505);EOF 但代理要求认证时视为"代理主动断开"而非错误(523-529)。
- 407 响应带 `Proxy-Authenticate` 时喂给 `Curl_http_input_auth`(统一入口,http_proxy.c:481-497),返回 `PROXY_INSPECT_AUTH_RETRY` → 状态机回到 INIT 重发 CONNECT(689-708;连接要重建时返回 `CURLE_AGAIN` 让外层重连,695-704)。
- 非 2xx 且无下一轮 URL → `H1_TUNNEL_FAILED` + `CURLE_COULDNT_CONNECT`(732-738)。
- 隧道建成时清理代理认证痕迹:`authproxy.done=TRUE`、释放 `hd_proxy_auth` 防止泄漏给源站请求(181-196)——这是"代理凭据不外流"的兜底。
- HTTP/2/3 代理与 CONNECT-UDP(RFC 9298,Masque)在同一框架内:CONNECT-UDP 的 101/2xx 判定在 719-729。

---

## 7. 设计动机

**为什么自研 URL 解析器?** 一是**需要把 URL 变成结构**——libcurl 要拿 host 建连、拿 scheme 选协议、拿 port 复用连接,浏览器式"只出字符串"不够;二是**要兼容 25 年的命令行遗产**:`ftp.host` 猜 scheme、1-3 个斜杠、`%` 简写 IPv4 都是浏览器永远不会支持的行为(docs/URL-SYNTAX.md:61-63 的"RFC 3986 plus"宣言);三是**解析结果要可质疑**——重定向的 Location 是攻击者可控输入,每次拼接(`redirect_url`)后重新完整解析,并且用 `Curl_url_same_origin` 做安全决策,把"字符串拼接"这种经典漏洞面收窄成一个受控函数。WHATWG 规范"会漂移"(docs/URL-SYNTAX.md:21-28)也是拒绝照搬的公开理由。

**认证为什么做成"轮"?** 因为 HTTP 认证方案的协商天然是服务器主导的:第一轮 curl 自己都不知道服务器要什么(除非应用硬指定单 bit)。`want/avail/picked` 三位掩码 + `done/multipass` 两个布尔,把"应用意愿、服务器通告、本轮选择"三个正交维度拆开,一套机制同时覆盖零轮(Basic 直发)、一轮(Digest/NTLM type3)、多轮(Negotiate token 往返)。"轮"的另一个动机是**保护请求体**:authneg 探针(http.c:880-889)与 `http_perhapsrewind` 对 NTLM/Negotiate 已建连时的特殊保留(http.c:433-455)共同保证:能不发大 body 就不发,必须发时保持同一连接(NTLM 的会话绑定在连接上)。

**cookie 域匹配的安全边界在哪?** 三道防线:tailmatch 的点边界(cookie.c:95-99)挡"notexample.com 偷 example.com 的 cookie";设置方向的反向 tailmatch(cookie.c:505-521)挡 `evil.com` 给 `example.com` 发 Domain cookie;PSL(cookie.c:800-878)挡"注册局域名(如 com.br)被某租户设成全局 cookie"。没有 libpsl 时第三道防线退化为"有个点就行"——curl 的已知风险位,docs/KNOWN_RISKS.md 亦承认 WHATWG/PSL 解析分歧不在安全豁免范围。

---

## 8. FAQ 素材

1. **`[]` `{}` globbing 现在还在吗?** 还在,但只在 curl 命令行工具层(src/tool_urlglob.c:569 `glob_url`;src/tool_operate.c:1263 仅当未给 `-g` 时展开),libcurl 从无此功能;它默认开启,`--globoff`(docs/cmdline-opts/globoff.md:6)关闭。IPv6 地址里的 `[]` 自动豁免(globoff.md 第 23-25 行)。
2. **curl 的 URL 解析和浏览器一样吗?** 不一样。定位是 RFC 3986 plus;斜杠容忍、IPvFuture、IDNA 细节、反斜杠处理都不同(第 2.4 节表格)。
3. **`http://example.com:` (冒号后没端口) 会报错吗?** 不会,等价于没写端口,与三大浏览器行为对齐(urlapi.c:416-425)。
4. **重定向到别的协议为什么失败?** 默认白名单只有 HTTP(S)/FTP(S)(protocol.h:69-70),在 url_set_conn_scheme(url.c:1173-1174)执行;`CURLOPT_REDIR_PROTOCOLS` 可改。
5. **为什么凭据没有带到重定向后的 host?** 默认只对初始 origin 发认证与敏感头;`CURLOPT_UNRESTRICTED_AUTH` 放开(setopt.c:468-474,vauth.c:145-150)。
6. **401 之后请求体会重发吗?** 会先做零长度探针(authneg,http.c:880-889),协商完成才发真 body;NTLM/Negotiate 协商中会尽量保连接续传(http.c:433-455)。
7. **NTLM 为什么对 HTTP/2 不友好?** NTLM 认证状态绑定单条连接,选中即强制 HTTP/1.1 并关复用(http.c:581-587)。
8. **.netrc 里 machine 匹配的是 host 还是 URL?** 是 origin 主机名(url.c:1292-1296);`CREDS_OPTION` 的凭据优先级高于 netrc,netrc 永不覆盖 -u。
9. **cookie 是什么时候开始生效的?** 必须激活引擎(cookiefile 等);发送侧还要求引擎开着(http.c:2565),只 set 不 activate 是常见的"cookie 没带上"根因。
10. **Set-Cookie 的 Domain=co.uk 会成功吗?** 有 libpsl 会被拒(psl_is_cookie_domain_acceptable);没有则仅剩"域内有点"检查(cookie.c:317-334)。
11. **zone id 怎么写?** `http://[fe80::1%25eth0]/` 或 `[fe80::1%eth0]` 均可,内部归一为 zoneid 字段,上限 16 字节(urlapi.c:56、465-483)。

## 9. 深挖素材

1. **parseurl 的五阶段顺序为什么是 fragment→query→path?** fragment 先切因为 `#` 优先级最高且不能再出现;query 次之;剩余才是 path——而 dedotdotify 只作用于 path(urlapi.c:824 注释明确禁止含 query/fragment),顺序颠倒会把 `?a=../..` 误归一。
2. **`Curl_url_same_origin` 的默认端口归一**(urlapi.c:2188-2196):一边显式 443、一边缺省,视为同源——这是 Digest 缓存跨重定向清除决策(http.c:1278)与后续潜在 cookie/认证决策的公共基座,值得对照浏览器 same-origin 讲。
3. **NTLM 的连接级凭据与连接复用**:url_match_init 把 want NTLM/Negotiate 作为连接匹配参数(url.c:2174-2192),http_ntlm.c:192-197 断言 creds 与连接绑定——"认证状态改变连接语义"是理解 curl 连接复用键的钥匙。
4. **zone id 的 `%25` 双重解码**:ipv6_parse 先跳 `25` 前缀(urlapi.c:471-472),而 get 时又重组 `host%25zoneid`(1614-1624)——编码态/解码态在内存里的表示(解析后存解码值)是 urlapi 的一致性约定(urlapi-int.h:29 注释 "Point to URL-encoded strings",注意此注释与实现演进间的张力)。
5. **CONNECT 隧道的 407 重试循环上限**:H1_CONNECT 的 do-while 以 `req.newurl` 是否存在驱动(cf-h1-proxy.c:716),重试次数与 maxredirs 的关系(认证重试计入 followlocation,http.c:1197-1198 注释)——边界行为值得写测试。

---

## 写作要点速查表

| # | 函数/结构 | 位置 | 一句话 |
|---|---|---|---|
| 1 | `parseurl` 五阶段主流程 | lib/urlapi.c:1223-1311 | scheme→authority→fragment→query→path |
| 2 | `Curl_is_absolute_url` | lib/urlapi.c:213-253 | scheme 判定 + 小写化,guess 语义 |
| 3 | `urlencode_str` | lib/urlapi.c:124-203 | 空格/%20/+,小写 %xx 转大写 |
| 4 | `parse_port` | lib/urlapi.c:383-441 | 空端口容忍(416-425),`\` 拒绝 |
| 5 | `ipv6_parse` / zone id | lib/urlapi.c:448-502 | %25 zoneid,inet_pton/ntop 归一 |
| 6 | `ipv4_normalize` | lib/urlapi.c:568-671 | 十六/八进制与 1-4 段简写展开 |
| 7 | `dedotdotify` | lib/urlapi.c:834-936 | RFC 3986 5.2.4 去点段 |
| 8 | `redirect_url` | lib/urlapi.c:1333-1407 | 相对 URL 拼接四分支 |
| 9 | `Curl_url_same_origin` | lib/urlapi.c:2175-2208 | 同源判定(含默认端口归一) |
| 10 | `Curl_http_follow` | lib/http.c:1175-1414 | maxredirs(1190)/端口锁(1235)/方法降级(1334-1388) |
| 11 | `url_set_conn_scheme` | lib/url.c:1164-1184 | 重定向协议白名单执行点 |
| 12 | `CURLPROTO_REDIR` | lib/protocol.h:69-70 | 默认 HTTP(S)/FTP(S) |
| 13 | `pickoneauth` | lib/http.c:349-391 | 偏好序 Negotiate>Bearer>Digest>NTLM>Basic |
| 14 | `struct auth` | lib/urldata.h:476-486 | want/avail/picked/done/multipass |
| 15 | `Curl_http_output_auth` | lib/http.c:798-894 | want→picked(844-854)、authneg 探针(880-889) |
| 16 | `Curl_http_input_auth` | lib/http.c:1067-1151 | 401/407 scheme 识别入口 |
| 17 | `Curl_output_ntlm` | lib/http_ntlm.c:116-249 | type1/2/3,creds 绑定连接(192-197) |
| 18 | `Curl_output_negotiate` | lib/http_negotiate.c:155-259 | GSS token 往返 + 持久化策略 |
| 19 | `url_set_data_creds` | lib/url.c:1355-1442 | OPTION>URL>NETRC 凭据链 |
| 20 | `cookie_tailmatch` | lib/cookie.c:73-100 | 点边界尾匹配 |
| 21 | `Curl_cookie_getlist` | lib/cookie.c:1321-1421 | 发送侧匹配 + 150 上限 |
| 22 | `is_public_suffix` | lib/cookie.c:800-878 | libpsl 安全闸 |
| 23 | `H1_CONNECT` 状态机 | lib/cf-h1-proxy.c:631-751 | CONNECT 六状态 + 407 重试 |
| 24 | `http_proxy_create_CONNECT` | lib/http_proxy.c:197-274 | 隧道请求构造 + is_connect 认证 |

(正文完)
