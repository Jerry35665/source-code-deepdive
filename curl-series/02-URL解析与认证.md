# 第 02 章 · URL 解析与认证:语义层的安全边界

> 基线:commit `0b04700`。行号以 lib/urlapi.c、lib/http.c、lib/url.c、lib/cookie.c、lib/cf-h1-proxy.c 为准。

## 2.0 全景:一次带重定向+认证+cookie 的请求

```
URL 解析(urlapi)→ 连接(01 章)→ 请求头组装 → [401] → 选认证器 → 再请求
                ↘ cookie 引擎随行        ↘ 3xx → Curl_http_follow → 协议白名单/凭据剥离 → 重路由
```

## 2.1 URL 解析器:五阶段与 WHATWG 分歧

`parseurl`(urlapi.c:1223)五阶段:scheme(Curl_is_absolute_url :213,scheme 强制小写)→authority(parse_authority :700:拆 user:pass@+端口+IPv4/IPv6 检查)→fragment(:1284)→query(:1293)→path(dedotdotify :834,按 RFC 3986 5.2.4)。规范化细节:小写 %xx 重写为大写(:164);空格在 query 变 `+`(:149-156);`host:` 空端口=默认端口(:416-425);IPv6 zone id `%25eth0`(:465-483,上限 16 字节);IPv4 十六/八进制简写展开(:568);容忍 1-3 个斜杠(:1057-1062)。**立场:RFC 3986 plus,不对齐 WHATWG**(docs/URL-SYNTAX.md:61)——curl 是工具不是浏览器,解析器一致性让位于语法严格性。相对 URL 拼接在 redirect_url(:1333);same_origin 判定含默认端口归一(:2175)——**重定向安全决策的基座**。

## 2.2 重定向:白名单与凭据剥离

`Curl_http_follow`(http.c:1175):maxredirs 上限判定(:1190-1196,默认 30,url.c:335;超限 CURLE_TOO_MANY_REDIRECTS);**协议白名单**执行点 url.c:1164-1184(默认 HTTP(S)/FTP(S),protocol.h:69——`--proto-redir` 语义:重定向不许把你带去 file:// 或奇怪协议);**跨 host 凭据闸**:vauth/vauth.c:145(CURLOPT_UNRESTRICTED_AUTH→allow_auth_to_other_hosts,setopt.c:468)——默认跨 host 剥凭据,防"重定向到攻击者站点带走你的 Authorization"。

## 2.3 认证轮:多认证器的协商状态机

`struct auth` 五字段 want/avail/picked/done/multipass(urldata.h:476)。闭环:Curl_http_output_auth(:798)发前 picked=want(:844-854),未决则裸发第一轮;401 时 Curl_http_input_auth(:1067)识别 scheme 入 avail;`pickoneauth`(:349)按偏好序 **Negotiate>Bearer>Digest>NTLM>Basic** 挑一个,克隆 URL 到 req.newurl 走 FOLLOW_RETRY 轮(multi.c:2107)。三个细节:authneg 探针(:880-889)让大 body **等认证完成再发**(免白传 10MB 只吃 401);NTLM 绑定连接强制 HTTP/1.1(:581,凭据钉在 conn 上);Basic/Bearer 一步 done(:747/:763),Negotiate 是 gss_init_sec_context 的 token 往返(:155)。邮件协议的 SASL(curl_sasl.c)同思想。

## 2.4 cookie 引擎与 CONNECT 隧道

cookie:tailmatch 点边界匹配(cookie.c:73);**libpsl 公共后缀闸**(:800;无 libpsl 退化为"域内有点"启发 :317)——防 evil.com 设置 .com cookie。凭据链优先级:CREDS_OPTION > CREDS_URL > CREDS_NETRC(creds.h:29-32;**netrc 永不覆盖 -u**,:1355-1442)。CONNECT 隧道:cf-h1-proxy.c:631 的 H1_CONNECT 六状态机:407→newurl→回 INIT 重发 CONNECT,隧道建成即清代理认证头(:181-196)。globbing(URL []{} 展开)**只在命令行工具层**(tool_urlglob.c:569),libcurl 从无此功能。

## 2.5 设计动机

1. **为什么自研 URL 解析器**:libcurl 曾依赖各平台的残缺解析;自研=语法严格(RFC 3986)+安全边界(same_origin)可控——对照浏览器(WHATWG)的分歧是立场而非疏忽;
2. **认证做成"轮"**:HTTP 认证本质是挑战-响应,状态机轮次是对协议最诚实的建模;authneg 的"先探后传"是带宽与延迟的交换;
3. **cookie 的安全边界在库层**:libpsl 闸让"所有用 libcurl 的软件"默认安全——**安全默认值要住在库里**;
4. **凭据链显式化**:三来源优先级固定(netrc 永不覆盖 -u)——安全相关的"谁说了算"绝不模糊。

## 2.6 FAQ

**Q1:重定向会带 Authorization 去别的域吗?**
默认剥(:145 闸);开 CURLOPT_UNRESTRICTED_AUTH 才跨 host——安全默认。

**Q2:file:// 重定向会被跟吗?**
不会:白名单默认 HTTP(S)/FTP(S)(protocol.h:69),url.c:1164 执行。

**Q3:为什么 Negotiate 优先级最高?**
(:349 偏好序):最强认证优先协商,失败降级 Digest/NTLM/Basic。

**Q4:cookie 能设置 .com 吗?**
libpsl 在场时被拒(:800);缺失时退化为弱启发(:317)——装 libpsl 是安全建议。

**Q5:URL 里的空格去哪了?**
query 里变 `+`(:149-156):curl 的 query 规范化立场。

**Q6:代理 407 怎么处理?**
CONNECT 状态机回 INIT 重发(:631):代理认证与目标认证是两条独立轮。

**Q7:netrc 和 -u 同时给听谁的?**
-u(:1355-1442):命令行显式永远赢。

**Q8:大文件上传遇 401 会白传吗?**
不会:authneg 探针先发 Expect 探测(:880-889)——先探后传。

**Q9:URL 大小写敏感吗?**
scheme/host 强制小写(:213):语义位归一;path 保留原样。

**Q10:globbing 是 libcurl 的吗?**
不是:仅 curl 工具层(tool_urlglob.c:569),`-g` 关闭——库与工具的边界。

## 2.7 小结与深挖方向

本章结论:**语义层="URL 严格解析+认证轮状态机+cookie 库级安全+凭据链显式化"**;安全默认值住在库里。深挖:

1. dedotdotify(:834)与 WHATWG 的路径归一差异案例;
2. pickoneauth 偏好序(:349)在混合认证服务器的降级链实测;
3. libpsl 缺失时的 cookie 安全面量化(:317);
4. CONNECT 六状态机(:631)对非标准代理的容错;
5. zone id(:465-483)与代理组合的行为。

> 下一章:HTTP 栈——cfilter 洋葱与三代 HTTP。
