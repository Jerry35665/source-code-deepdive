# 第 13 章 · credential 系统:凭证的可插拔存储(卷三开篇)

> 基线:commit `47ce805`。行号以 credential.c、builtin/credential-store.c、builtin/credential-cache.c 为准。卷一 11 章讲了 builtin 架构——本章讲 Git 如何安全存储与获取远程仓库凭证。

## 13.0 全景:三阶段协议

```
credential_fill(credential.c:504-545):
  补齐 username+password 或 credential
  → 归并 credential.* 配置生成 helper 列表(:172-208)
  → 依序启动 helper 子进程发 get
  → 第一个补齐凭证的 helper 赢,立即 return(:519-536)
  → 全部落空才 askpass/终端询问(:542)

credential_approve(:547-563):HTTP 2xx 后向全部 helper 广播 store
credential_reject(:565-581):401 后向全部 helper 广播 erase
```

## 13.1 helper 协议:子进程的 stdin/stdout

helper 名翻译:`!cmd` shell 命令/绝对路径/`git credential-<name>`(credential.c:484-502);子进程 use_shell+SIGPIPE 压制(:444-482)。stdin/stdout 是 **key=value 行协议**:credential_write(:409-442)含 `\n`/`\r` 注入即 die(:400-405,**CVE-2020-5260 加固**);credential_read(:314-390)未知 key 静默忽略向前兼容;`url=`/`quit=` 特殊行。capability 三段级联协商(:296-312)——**上一阶段声明过才转发**。

credential_match(:89-100):逐字段精确相等、want 空即通配;**path 不做前缀匹配**;HTTP 默认丢 path(useHttpPath 开关 :205-207)。URL 解析三形态(user:pass@host,:620-693),换行组件校验(:685-690)。

## 13.2 store/cache:明文 vs daemon

**credential-store**(builtin/credential-store.c:188/:198):umask(077)+默认明文 `~/.git-credentials`(格式 proto://user:pass@host,:93-112)——**最简单但最不安全**。

**credential-cache**(builtin/credential-cache.c:147+daemon.c:59-101):**默认 TTL 900s**;daemon 空表 30 秒后自毁;socket 目录强制 0700 创建(daemon.c:253-289)——安全性与便利的折中。

## 13.3 与 HTTP 认证的联动

http.c:1498+(:638-667):URL 注入 http_auth;**CURLOPT_USERNAME/PASSWORD/HTTPAUTH** 设置(:1658 设 http_auth_methods=CURLAUTH_ANY,初值 http.c:134);handle_curl_result(:1922-1988):OK→approve 三件套(:1928-1930),401→reject+方案收敛 auth_avail(:1969-1972),multistage 只清 secrets 重试(:1948-1951)。**与 curl 系列 02 章呼应**:Git 把"凭证从哪来"交给 helper 外部进程体系(可插拔后端),"凭证怎么用"交给 libcurl 认证状态机。

## 13.4 设计动机

1. **为什么 helper 是外部进程而非内置存储**:**可插拔凭证后端**——macOS Keychain/Windows Credential Manager/libsecret 各有专属 API,内置只能选一个;外部进程让用户自由组合;
2. **三阶段协议的必要性**:fill(获取)→approve(确认有效)→reject(标记无效)——**三个生命周期阶段对应三种操作**;
3. **CVE-2020-5260 的教训**:凭证中的换行可以注入任意协议指令——**输入校验是协议安全的第一道防线**;
4. **capability 级联协商**:上一阶段声明过才转发(:296-312)——**能力协商是协议演进的兼容机制**。

## 13.5 FAQ

**Q1:凭证存在哪?**
helper 决定:store 明文文件/cache 内存 TTL/Keychain 等系统存储——helper 是可插拔后端。

**Q2:第一个 helper 没找到凭证,会问第二个吗?**
会:链式调用直到某个 helper 补齐凭证(:519-536)——序即优先级。

**Q3:approve/reject 是广播还是"第一个赢"?**
广播:全部 helper 都收到 store/erase(:560-561/:573-574)——与 fill 的"第一个赢"相反。

**Q4:.git-credentials 安全吗?**
不安全(明文):umask 077 保护(:188-198),但 root 可读——生产建议用 cache 或 Keychain helper。

**Q5:credential-cache 的 TTL 是多少?**
默认 900s(:147);可配置 credential.helper "cache --timeout <seconds>"。

**Q6:凭证中的换行有什么风险?**
CVE-2020-5260:换行注入可伪造协议指令(:400-405)——加固后直接 die。

**Q7:path 匹配默认开启吗?**
默认关(useHttpPath 开关 :205-207):同 host 不同 path 共享凭证——S3 风格签名需要区分。

**Q8:模块能提供凭证吗?**
不能:credential 是 builtin 架构;但 helper 外部进程可以实现任意后端。

**Q9:askpass 什么时候触发?**
全部 helper 落空时(:542):终端询问或 SSH_ASKPASS——**最后的人机交互兜底**。

**Q10:凭证过期怎么处理?**
HTTP 401→credential_reject 广播 erase(:565-581)→下次 fill 重新获取——**401 驱动的凭证生命周期**。

## 13.6 小结与深挖方向

本章结论:**credential="三阶段协议+可插拔 helper 链式调用+CVE 加固的行协议"**。深挖:

1. capability 协商(:296-312)在多 helper 混合的降级行为;
2. credential_match(:89-100)的 path 通配在 monorepo 多 remote 的误匹配;
3. cache daemon 的 socket 安全(:253-289)在多用户系统的隔离;
4. OAuth token 流程(GitHub/GitLab)与 credential helper 的集成点;
5. `credential.useHttpPath` 在 monorepo 多 path 的行为差异。

> credential 系统完——Git 卷三的落脚点:安全的第一道门。
