# 第 21 章 · measure 与 pcrlock:预签名预期值与 NV index 间接层

> 基线:commit `1f66b524`。核心:src/measure/measure-tool.c(1,110 行——纠偏:不存在 measure.c)与 src/pcrlock/pcrlock.c(5,817 行)+ pcrlock.d/ 组件库。

## 21.0 全景:两条互补路线

```
 systemd-measure(构建期):UKI 各段 → 虚拟 extend → PCR11 已知预期值
   → 每相位×每 bank 折成 PolicyPCR 摘要 → "摘要‖policyRef" TBS → 私钥签名 → .pcrsig
 systemd-pcrlock(运行期):TCG 固件日志 + userspace JSON 日志 + pcrlock.d 组件库
   → 未来 PCR 状态枚举成有限组合(≤8,PolicyOR 分支上限)→ 折叠 → 写 TPM NV index
   → cryptenroll 只以 PolicyAuthorizeNV 钉住 NV public——组件更新只需重写 NV 内容
 分工:measure 解决"我知道内核会测什么";pcrlock 解决"固件测什么不知道,但可枚举"
```

纠偏:measure 的 `sign` **签的是 PolicyPCR 摘要而非裸 PCR 值**,且签名摘要恒为 SHA256、与 `--bank` 无关(measure-tool.c:1006-1021);`.pcrsig` 永不进 PCR 11(:256),`.pcrpkey` 会进;段序按枚举死锁(uki.h:8-10 "PLEASE DO NOT REORDER")而非 PE 布局序。

## 21.1 measure:每段两次 extend

每 bank 一个 PcrState 初值全零;按 UnifiedSection 枚举 0→MAX 遍历(这正是规范测量序),每段先 extend `hash(段名+NUL)` 再 extend `hash(段内容)`,16KiB 流式;空文件跳过且注明"stub 也这么做"(measure-tool.c:525-655)。相位缺省硬编码 4 个(enter-initrd→leave-initrd→sysinit→ready),相位词逐个 extend `hash(word)`——与组件库 `pcrlock.d/750-enter-initrd.pcrlock` 的 digest 逐字节吻合;多相位复用靠 pcr_states_save/restore 避免重算(:815-866)。`assert_cc(UNIFIED_SECTION_EFIFW+1==_UNIFIED_SECTION_MAX)` 保证新增段必须同步输入表(:266)。

## 21.2 pcrlock:双日志、自校验与 NV 枢纽

日志源两个:固件 TCG log(binary_bios_measurements,头校验 "Spec ID Event03")与 userspace JSON log(0x1E 分隔);**sticky bit 标记日志不完整**(写者死于两步之间),照常加载但相关 PCR 校验会失败(pcrlock.c:1219-1227)。自校验:对含原始负载的事件重算哈希比对,EV_IPL 负载是 UTF-16 段名但哈希按 UTF-8+NUL 计,故提供"替身哈希"二次尝试(:1518-1559)。**NV index 间接层是整个设计的枢纽**:cryptenroll 的 LUKS2 token 不含预测值,只钉 NV public——"组件更新 → make-policy 重写 NV 内容 → 旧 token 无改动即换策略";恢复 PIN 被封到同一 NV 策略下,更新策略必须先过旧策略(dogfood,:3647-3649)。纠偏:不存在 "lock-fast"——锁定/解除是 lock-*/unlock-* 动词族,策略轮换=重写 NV 内容;默认 PCR 掩码刻意排除 PCR 12 防概念自指(:137)。

## 21.3 pcrlock 也是服务

systemd-pcrlock 既是 CLI(约 20 个动词)也是 **root-only Varlink 常驻服务**:绑定 io.systemd.PCRLock 的 ReadEventLog/ListComponents/MakePolicy/RemovePolicy/Lock 与 io.systemd.SysUpdate.Notify.OnCompletedUpdate 六个方法(pcrlock.c:5778-5811)——sysupdate 完成更新后它同样收到广播,自动重算策略。变体组合上限 8,源于 TPM PolicyOR 分支限制(tpm2-util.c:9742)。

## 21.4 设计动机

1. **预签名换零交互**:构建期算尽 PCR11,解锁期 TPM 只比对策略,无人工密钥输入(measure-tool.c:30-31);
2. **签策略不签值**:换 bank/重排测量序不必重签——策略摘要层隔开了细节(:1012-1021);
3. **NV 间接层**:预测值与 LUKS2 token 解耦,组件更新零 token 改动(pcrlock.c:3647-3649);
4. **组件库即时间轴**:pcrlock.d 数字前缀排序=启动相位序列,内置相位词与 stub 测量词逐字节一致;
5. **枚举有限组合**:固件不确定性被组件库压到 PolicyOR ≤8 分支可表达(pcrlock.c:3632-3655);
6. **自校验日志**:替身哈希+严格类型白名单,坏日志不静默通过(:1489-1567)。

## 21.5 FAQ

**Q1:measure 签的是 PCR 值吗?**
不是,是 PolicyPCR 摘要+"policyRef"的 TBS;签名摘要恒 SHA256(measure-tool.c:1012-1021)。

**Q2:measure.c 在哪?**
文件名是 measure-tool.c;仓库无 measure.c。

**Q3:.pcrsig 进 PCR 11 吗?**
永不;它本身是对策略的签名(measure-tool.c:256)。

**Q4:pcrlock 怎么应对固件更新?**
枚举组合+PolicyOR;更新后 make-policy 重写 NV 内容,LUKS2 token 不动。

**Q5:恢复 PIN 也走 NV 策略吗?**
是,被封进同一策略,更新策略须先过旧策略(dogfood)(pcrlock.c:3974-4000)。

**Q6:策略分支为什么最多 8 个?**
TPM PolicyOR 分支上限(tpm2-util.c:9742)。

**Q7:pcrlock 是一次性工具吗?**
也是常驻 Varlink 服务,订阅 sysupdate 通知自动重算(pcrlock.c:5778-5811)。

**Q8:日志不完整怎么发现?**
sticky bit 标记;照常加载但相关 PCR 校验失败(pcrlock.c:1219-1227)。

**Q9:PCR 12 为什么被 pcrlock 排除?**
防概念自指——pcrlock 自己的策略不该锁住自己的输入(pcrlock.c:137)。

**Q10:相位词从哪来?**
pcrlock.d 组件库数字前缀排序;750-enter-initrd 的 digest=SHA256("enter-initrd")。

## 21.6 小结与深挖方向

本章结论:**measure=构建期虚拟 extend+策略摘要签名;pcrlock=运行期日志枚举+NV index 间接层;两者在 PolicyAuthorize/PolicyAuthorizeNV 处汇合**。深挖:

1. StartupLocality 伪事件与 PCR0 初值最低字节(pcrlock.c:986-997);
2. Hyper-V 固件算法顺序错乱的配对搜索(:1030-1038);
3. policy-digest 的 tbs 输出与 HSM 离线签名流程(:1049);
4. userspace JSON 日志的写入方(pcrextend)与锁协议(tpm2-util.c:8445-8451);
5. 组件库自定义(.pcrlock 文件)的字段 schema。
