# 报告 B4 · ukify 与 systemd-stub(systemd 卷四)

> 基线:1f66b524(`nspawn: align config PrivateUsersOwnership default with CLI`)——本报告核实:ukify 用 Python+pefile 手工向 stub PE 追加统一命名段并外调 sbsign/pesign/systemd-sbsign 与 systemd-measure 完成 SB 签名与 PCR 策略预签名;systemd-stub(C 源位于 `src/boot/`,非 `src/efi/`)启动时从内存 PE 段表解包 `.linux/.initrd/.cmdline` 等段,按 PCR 11/12/13 测量并重组 initrd 后移交内核。

路径约定:下文 `ukify.py:N` 指 `src/ukify/ukify.py`;`stub.c:N`、`pe.c:N`、`measure.c:N`、`cpio.c:N`、`random-seed.c:N`、`boot-secret.c:N`、`linux.c:N` 指 `src/boot/` 下同名文件;`uki.h:N`、`tpm2-pcr.h:N` 指 `src/fundamental/`;`measure-tool.c:N` 指 `src/measure/`。

## 一、第一处纠偏:源码位置与工具清单

- 本 commit 中 systemd-stub 的 C 源在 `src/boot/`(含 stub.c、pe.c、measure.c 等 60 余个文件),`src/efi/` 不存在(实测 `ls src/` 无 efi 目录;历史上曾有 `src/boot/efi/` 子目录,现已被摊平到 `src/boot/`)。
- ukify 仅 2706 行(`wc -l ukify.py`),依赖 `pefile`(ukify.py:61)做 PE 解析与手工改写;子命令只有三个:`VERBS = ('build', 'genkey', 'inspect')`(ukify.py:2020);`inspect` 按 `DEFAULT_SECTIONS_TO_SHOW`(text/binary)输出 size+sha256,`.dtbauto/.efifw` 属 `MULTI_INSTANCE_SECTIONS`、JSON 中恒为数组(ukify.py:407-432、1760-1820)。
- 签名与测量全部外调外部工具:签名走 `SignTool` 三实现 `pesign`/`sbsign`/`systemd-sbsign`(ukify.py:522-531),测量走 `systemd-measure` 的 `calculate`/`policy-digest`/`sign` 子命令(ukify.py:868-871、922-924)。ukify 唯一"内置"的密码学是 `genkey`:用 python-cryptography 现场生成 RSA-2048 自签证书与 PCR 密钥对,自签证书 CN 走 X.509 的 64 字节上限(ukify.py:1623-1702、1711-1728)。

```python
    @staticmethod
    def from_string(name: str) -> type['SignTool']:
        if name == 'pesign':
            return PeSign
        elif name == 'sbsign':
            return SbSign
        elif name == 'systemd-sbsign':
            return SystemdSbSign
        else:
            raise ValueError(f'Invalid sign tool: {name!r}')
```

(ukify.py:522-531)

## 二、ukify:make_uki 的 UKI 组装流程

`make_uki`(ukify.py:1370)是 build 的核心。组装前的预处理:内核若不是合法 PE(部分发行版 vmlinuz 是 gzip/zboot),先 `maybe_decompress` 解压(ukify.py:1382-1395;zboot 检测在 get_zboot_kernel,ukify.py:167);`--uname` 未给时自动从内核抓版本号,顺序为 x86 real-mode 头(0x202 处 `HdrS` 魔数→0x20E 偏移)→ ELF note → 全文正则 `Linux version …`(ukify.py:343-362、399-410)。多个 `--initrd=` 用 `join_initrds` 直接拼接,每段补零到 4 字节对齐(ukify.py:968-981):

```python
def join_initrds(initrds: list[Path]) -> Union[Path, bytes, None]:
    if not initrds:
        return None
    if len(initrds) == 1:
        return initrds[0]
    seq = []
    for file in initrds:
        initrd = file.read_bytes()
        n = len(initrd)
        padding = b'\0' * (round_up(n, 4) - n)  # pad to 32 bit alignment
        seq += [initrd, padding]
    return b''.join(seq)
```

(ukify.py:968-981)

段清单与**文件内顺序**硬编码在 make_uki 中(ukify.py:1462-1476):

```python
sections = [
    # name,      content,         measure?
    ('.osrel',   opts.os_release, True),
    ('.cmdline', opts.cmdline,    True),
    ('.dtb',     opts.devicetree, True),
    *(('.dtbauto', dtb, True) for dtb in opts.devicetree_auto),
    ('.hwids',   hwids,           True),
    ('.uname',   opts.uname,      True),
    ('.splash',  opts.splash,     True),
    ('.pcrpkey', pcrpkey,         True),
    ('.linux',   linux,           True),
    ('.initrd',  initrd,          True),
    *(('.efifw', parse_efifw_dir(fw), False) for fw in opts.efifw),
    ('.ucode',   opts.microcode,  True),
]
```

(ukify.py:1462-1476,节选)

随后:`.profile` 若作为独立 profile 构建,必须排第一(ukify.py:1478-1480);用户 `--sections` 追加其后(ukify.py:1487-1488);`.sbat` 段合并 stub、内核与 `--sbat=` 文本(merge_sbat,ukify.py:1184-1233;未提供时用内置 STUB_SBAT/ADDON_SBAT,ukify.py:1359-1366、1496-1502);`--join-profile` 时基础 `.profile` 排最后,使之前的段跨 profile 共享(ukify.py:1505-1509)。`.pcrpkey` 未显式给时,由 systemd-keyutil 从单一 PCR 公钥/证书/私钥提取(ukify.py:1417-1449);`.hwids` 可从 `--hwids=` 目录或 `/usr/lib/systemd/boot/hwids/<arch>` 生成(ukify.py:1453-1460,pack 逻辑 parse_hwid_dir ukify.py:1263)。

## 三、ukify:手工 PE 改写与 PE 签名(无 sbattach)

`pe_add_sections`(ukify.py:997)不用 objcopy,直接以 pefile 改写 stub 镜像:先剥离文件尾符号表(ukify.py:1001-1011),把旧 stub 未对齐的 `PointerToRawData/SizeOfRawData` 整体右移补齐(ukify.py:1016-1034),再把 `SizeOfHeaders` 圆整到 FileAlignment 以腾出段表空间(ukify.py:1039-1042)。若 stub 已带签名表则拒绝("Stub image is signed, refusing",ukify.py:1055-1061)。追加段时:`.linux` 段标记 `IMAGE_SCN_CNT_CODE`,且内核 PE 未设 NX_COMPAT 时同步清掉 UKI 的该标志(ukify.py:1089-1102);`.sbat` 特殊处理——stub 已有同名段,原地换数据而非追加(ukify.py:1109-1128);最后清 CheckSum、重算 SizeOfImage 并写出(ukify.py:1175-1181)。

最终签名在文件写完之后:`signtool.sign(unsigned_output, opts.output)`(ukify.py:1597-1601)。三个实现都是 `subprocess.check_call` 包外部命令,SbSign 的一例:

```python
class SbSign(SignTool):
    @staticmethod
    def sign(input_f: str, output_f: str, opts: UkifyConfig) -> None:
        tool = find_tool('sbsign', opts=opts, msg='sbsign, required for signing, is not installed')
        cmd = [
            tool,
            '--key', opts.sb_key,
            '--cert', opts.sb_cert,
            *(['--engine', opts.signing_engine] if opts.signing_engine is not None else []),
            input_f,
            '--output', output_f,
        ]  # fmt: skip

        print('+', shell_join(cmd), file=sys.stderr)
        subprocess.check_call(cmd)
```

(ukify.py:567-584,节选;PeSign 调 `pesign -s -n <certdir> -c <nickname>`,ukify.py:540-552;SystemdSbSign 调 `systemd-sbsign sign`,ukify.py:605-636,支持 engine/provider 私钥源)

`--signtool` 可自动推断:给了 `--secureboot-private-key/certificate` 推 sbsign(ukify.py:2596-2605),给了 `--secureboot-certificate-name` 推 pesign(ukify.py:2607-2612),`--signing-provider` 只允许配 systemd-sbsign(ukify.py:2615-2618)。`--sign-kernel` 未显式给时,先用 `sbverify --list`/`pesign -S` 探测内核是否已签名来决定是否顺带签内核(ukify.py:1397-1408、554-596);`find_tool` 支持 `--tools=` 目录优先于 PATH(ukify.py:721-735)。

## 四、ukify 与 systemd-measure 的联动:PCR 策略短语

`call_systemd_measure`(ukify.py:812)负责 PCR 期望值计算与签名。测量集合取 `uki.sections` 中 `measure=True` 的段,`.dtbauto` 被单独摘出,为每个 DTB 变体各跑一遍策略(ukify.py:825-834、857-859)。命令形如 `systemd-measure calculate|sign --osrel=… --cmdline=… --bank=SHA256 --phase=enter-initrd…`(ukify.py:868-877):

```python
            for phase_paths, policyref in policy_groups:
                cmd = [
                    measure_tool,
                    'calculate' if opts.measure else 'policy-digest',
                    '--json',
                    opts.json,
                    *(f'--{s.name.removeprefix(".")}={s.content}' for s in to_measure.values()),
                    *(f'--bank={bank}' for bank in banks),
                    *(f'--phase={phase_path}' for phase_path in phase_paths),
                ]
```

(ukify.py:867-878,节选;签名字路径加 `--private-key/--certificate/--phase/--policyref`,ukify.py:914-958)

要点:

- `--pcr-banks` 仅做逗号/空白切分,无合法性校验,源码留有 `TODO: do some sanity checking here`(ukify.py:643-646)。
- `--phases=` 的合法阶段白名单 `KNOWN_PHASES = enter-initrd/leave-initrd/sysinit/ready/shutdown/final`(ukify.py:649-668);`--policy-digest` 模式要求恰好一个 PCR 公钥/证书且不与 `--pcr-private-key` 同用(ukify.py:2539-2546,finalize_options 校验)。
- `--sign-initrd-pcrs` 会用第一把 PCR 私钥追加一组只限 `enter-initrd` 阶段、policyref 为 `initrd` 的签名(`INITRD_PCR_POLICY`,ukify.py:86、793-801)。
- 离线签名 JSON 需要预留空间:`combined += ' ' * 1024 * combined.count('"pol":')`——每个策略摘要按 4KB/签名上限填 1024 个空格(ukify.py:905-910),之后 `.pcrsig` 段加入 UKI(ukify.py:963);`--join-profile` 时对每个 profile PE 复制其段并按 `profile_start` 分段测量签名,再合并 JSON(combine_signatures,ukify.py:742-769、1542-1583)。

## 五、systemd-stub:run() 的启动时序

`run()`(stub.c:1192)时序:取 LoadedImage → `process_arguments`(剥离 EFI shell 前缀、解析 `@N` profile,stub.c:206-269)→ `find_sections`(stub.c:1091-1137)→ `measure_profile` + `measure_sections` → splash → random-seed → boot-secret → cmdline 定夺 → 加载 addon PE → 拼装 initrd → `linux_exec`(stub.c:1215-1310)。

段解析完全基于内存:`pe_section_table_from_base` 从 ImageBase 读 DOS/PE 头与段表(pe.c:700-724),`pe_locate_profile_sections` 先取基础段(profile=UINT_MAX),再用所选 profile 覆盖(stub.c:1107-1131);`.linux` 缺失直接报错退出(stub.c:1133-1134)。**多 profile 用多个 `.profile` 段做分界**:第 N 个 `.profile` 之后到下一个 `.profile` 之前的段属于 profile N(pe.c:818-874),profile 上限 256(`UNIFIED_PROFILES_MAX`,uki.h)。内核 cmdline 上的 `@N` 前缀被 parse_profile_from_cmdline 剥掉且只吞一个空格,避免扰动后续测量(stub.c:150-182)。

cmdline 的合成顺序(由"最硬"到"最动态",注释见 stub.c:1247-1250):LoadOptions 自定义 → 内嵌 `.cmdline`(settle_command_line,stub.c:1139-1173)→ `\loader\addons` 全局与 per-UKI dropin 目录下 `*.addon.efi` 的 `.cmdline`(load_addons,stub.c:1019-1076、633-638)→ SMBIOS Type11 `io.systemd.stub.kernel-cmdline-extra=`(机密 VM 下跳过,stub.c:763-792)→ 控制台参数(cmdline_append_console,stub.c:1254)。安全约束集中在 settle_command_line:

```c
        /* We'll suppress the custom cmdline if we are in Secure Boot mode, and if either there is already
         * a cmdline baked into the UKI or we are in confidential VM mode. */
        if (!isempty(*cmdline)) {
                if (secure_boot_enabled() && (PE_SECTION_VECTOR_IS_SET(sections + UNIFIED_SECTION_CMDLINE) || is_confidential_vm()))
                        *cmdline = mfree(*cmdline);
                else {
                        bool m = false;
                        (void) tpm_log_load_options(*cmdline, &m);
                        combine_measured_flag(parameters_measured, m);
                }
        }
        if (isempty(*cmdline)) /* suppressed or absent: fall back to embedded .cmdline */
                *cmdline = mangle_stub_cmdline(pe_section_to_str16(loaded_image, sections + UNIFIED_SECTION_CMDLINE));
```

(stub.c:1149-1172,节选;`mangle_stub_cmdline` 做首尾空白清理与控制字符折叠,util.c:59-74)

addon PE 必须经 `shim_load_image` 验证,且含 `.linux` 段者判定为 UKI 而拒收(stub.c:584、617-621),`.uname` 不匹配也拒收(stub.c:625-631);addon 文件名要求 ASCII、≤255 字符、以 `.addon.efi` 结尾,排序后处理以保证测量顺序与目录读取顺序无关(stub.c:305-314、566-568)。

## 六、TPM 测量:哪些段进哪个 PCR

`measure_sections`(stub.c:721-761)遍历统一段枚举,对每个"应测量"段先后测量**段名字符串**与**段数据**,两次 `tpm_log_ipl_event_ascii` 都进 `TPM2_PCR_KERNEL_BOOT` 即 PCR 11(stub.c:743-758)。唯一例外是 `.pcrsig`:uki.h 的 `unified_section_measure` 只排除它(uki.h `static inline bool unified_section_measure`;stub.c:888-895 注释解释:签名是测量的期望值,不能又当测量输入)。

```c
for (UnifiedSection section = 0; section < _UNIFIED_SECTION_MAX; section++) {
        if (!unified_section_measure(section)) /* shall not measure? */
                continue;
        if (!PE_SECTION_VECTOR_IS_SET(sections + section)) /* not found */
                continue;
        /* First measure the name of the section */
        bool m = false;
        (void) tpm_log_ipl_event_ascii(TPM2_PCR_KERNEL_BOOT, ...统一段名...);
        m = false;
        (void) tpm_log_ipl_event_ascii(TPM2_PCR_KERNEL_BOOT, ...段数据...);
}
```

(stub.c:733-760,删节)

PCR 布局(tpm2-pcr.h:28-38):PCR 11=镜像静态段(可预计算,注释 stub.c:730-732);PCR 12=cmdline、addon cmdline、credentials、confext、DT addon、initrd/ucode addon、profile 编号(tpm_log_load_options measure.c:366-384;各处 TPM2_PCR_KERNEL_CONFIG);PCR 13=sysext;SMBIOS 进 PCR 1(measure_smbios,stub.c:1259-1261)。测量动作是 TCG2 `HashLogExtendEvent`,新式事件用 EV_EVENT_TAG+事件标签(measure.c:29-51),旧式 EV_IPL(measure.c:66-79);CC(机密计算)协议与 TCG2 双写以防 CVE-2021-42299 类碰撞(measure.c:302、341-342),完成后写 EFI 变量 `StubPcrKernelImage=11`、`StubPcrKernelParameters=12`、`StubPcrInitRDSysExts=13`、`StubPcrInitRDConfExts=12`(stub.c:971-988)。**发现一处不对称**:`.efifw` 在 ukify 侧 `measure=False` 不参与策略计算(ukify.py:1474),systemd-measure 却有 `--efifw=` 选项(measure-tool.c:263),而 stub 侧只排除 `.pcrsig`,会把 `.efifw` 量进 PCR 11——即本 commit 中 ukify 预签名策略未覆盖 stub 实际测量的一类段(带 .efifw 的 UKI 用 PCR11 策略解锁会失配)。

## 七、sidecar initrd:credentials/sysext/confext、随机数与 boot-secret

initrd 合并槽位顺序由枚举固定(stub.c:36-52):`UCODE → PREVIOUS(LoadFile2 上游已注册) → BASE(.initrd) → CREDENTIAL → GLOBAL_CREDENTIAL → SYSEXT → GLOBAL_SYSEXT → CONFEXT → GLOBAL_CONFEXT → PCRSIG → PCRPKEY → OSREL → PROFILE → BOOT_SECRET`。`generate_sidecar_initrds`(stub.c:804-878)扫描 UKI 同目录与 `\loader\credentials`/`\loader\extensions` 全局目录,把 `.cred`、`.raw`(排除 `.confext.raw`)、`.confext.raw` 打包成 cpio;落盘路径与 PCR 归属在 cpio.c 的规范表:

```c
const CpioTarget cpio_target_credentials = {
        .directory = ".extra/credentials",
        .dir_mode = 0500,
        .access_mode = 0400,
        .tpm_pcr = TPM2_PCR_KERNEL_CONFIG,
};

const CpioTarget cpio_target_sysext = {
        .directory = ".extra/sysext",
        .dir_mode = 0555,
        .access_mode = 0444,
        .tpm_pcr = TPM2_PCR_SYSEXTS,
};
```

(cpio.c:512-531,节选;`.extra/confext|global_confext` 同为 PCR12,元数据 `.extra` 的 tpm_pcr=UINT32_MAX 表示不测量,cpio.c:540-566)

`.pcrsig/.pcrpkey/.profile/.osrel` 四段被包装成 initrd 文件 `/.extra/tpm2-pcr-signature.json`、`tpm2-pcr-public-key.pem`、`profile`、`os-release` 交给用户态(stub.c:880-929),其中前两者的注释明确说明 `.pcrsig` "既不作为原始段、也不作为 cpio 被测量"(stub.c:888-895)。

最终合并顺序及理由写在注释里(stub.c:1274-1282):ucode addon 反序插到最前(内核取第一个匹配的 microcode 文件,stub.c:474-476、1283),其后依次是 UKI 自身槽位、initrd addon;多于一个 initrd 时 `combine_initrds` 拼接(stub.c:1291-1304),经 `initrd_register` 以 LoadFile2 协议 LINUX_INITRD_MEDIA_GUID 交给内核(initrd.c:69-152)。random-seed:仅当 sd-boot 未初始化(LoaderFeatures 位)时,stub 打开/创建 ESP 的 `\loader\random-seed`,SHA256 混入旧种子、UEFI 单调计数器与 RTC 时间,回写新种子并把派生值装进 `LINUX_EFI_RANDOM_SEED_TABLE` 配置表(random-seed.c:240-296、328-348、400-417)。boot-secret:从该种子表+仅启动期可见的 EFI 变量秘密+ESP mixin+`.osrel` 的 ID 派生,作为 `boot-secret` initrd 文件传递(boot-secret.c:8-23、331-360;stub.c:1231-1233、931-949)。

## 八、契约对照与 ASCII 图

ukify 写入的段名与 stub 读取的段名同源于一份规范清单:`unified_sections[]`(uki.c:7-27,ukify 侧由 pe_strip_section_name 匹配 `.pcrsig` 等,ukify.py:1148;段名必须 ≤8 字符,ukify.py:483-489 与 uki.c 注释互为印证)。测量顺序=枚举顺序(`.linux` 打头,uki.h 注释"PLEASE DO NOT REORDER"),与 PE 文件布局顺序(ukify.py:1462-1476)是两个独立概念:

```c
const char* const unified_sections[_UNIFIED_SECTION_MAX + 1] = {
        [UNIFIED_SECTION_LINUX]   = ".linux",
        [UNIFIED_SECTION_OSREL]   = ".osrel",
        [UNIFIED_SECTION_CMDLINE] = ".cmdline",
        [UNIFIED_SECTION_INITRD]  = ".initrd",
        [UNIFIED_SECTION_UCODE]   = ".ucode",
        [UNIFIED_SECTION_SPLASH]  = ".splash",
        [UNIFIED_SECTION_DTB]     = ".dtb",
        /* … 中略:.uname/.sbat/.pcrsig/.pcrpkey/.profile … */
        [UNIFIED_SECTION_DTBAUTO] = ".dtbauto",
        [UNIFIED_SECTION_HWIDS]   = ".hwids",
        [UNIFIED_SECTION_EFIFW]   = ".efifw",
        NULL,
};
```

(uki.c:7-27,节选)

不存在 `.dtbadd` 段:DTB 附加=内嵌 `.dtb/.dtbauto` + addon PE 的 `.dtb/.dtbauto`(stub.c:642-666),`.dtbauto` 优先于 `.dtb` 安装(stub.c:1003-1009),硬件匹配靠 DT `compatible` 属性(devicetree.c:184-194)。

图 1:UKI 文件段布局(构建顺序)

```text
┌─────────────────────────────────────────────────────────────┐
│ systemd-stub PE (.text/.data/.sbat/.sdmagic …)  ← UKI 底座  │ ukify.py:1414
├──────────────┬──────────────────────────────────────────────┤
│ .profile     │ (join_profiles 时排最末;独立 profile 排首)   │ ukify.py:1478,1508
│ .osrel/.cmdline/.dtb/.dtbauto/.hwids/.uname         [PCR11] │
│ .splash/.pcrpkey                                    [PCR11] │
│ .linux       │ 内核 PE,CODE 段属性 + NX 联动       [PCR11]  │ ukify.py:1089-1102
│ .initrd      │ join_initrds 拼接(4B 对齐)          [PCR11]  │ ukify.py:968-981
│ .efifw       │ 固件(ukify 不测,stub 会测!)        [⚠]     │ ukify.py:1474
│ .ucode       │ 微码(文件内靠后,启动时插最前)     [PCR11]  │ stub.c:36,1274
│ .sbat        │ stub+内核 SBAT 原地合并                      │ ukify.py:1109-1128
│ .pcrsig      │ systemd-measure 预签名 JSON(不测)  [跳过]  │ ukify.py:963
└──────────────┴──────────────────────────────────────────────┘
   之后整体交 sbsign/pesign/systemd-sbsign 签名 → 最终输出
```

图 2:stub 启动时的解包/测量/重组流程

```text
固件/shim 验证 UKI PE → stub run() (stub.c:1192)
  1 process_arguments: 剥 "@N" profile、EFI shell 前缀     stub.c:150-269
  2 find_sections: 内存段表 → 基础段 + profile 段覆盖      stub.c:1091-1137, pe.c:876
  3 measure_profile(@N→PCR12) + measure_sections          stub.c:1223-1224
      段名+段数据 → PCR11(.pcrsig 除外)                    stub.c:733-760
  4 splash;refresh_random_seed(ESP \loader\random-seed)    stub.c:1227-1229
  5 settle_command_line: SB 下弃自定义;量 cmdline → PCR12  stub.c:1139-1173
  6 load_all_addons(\loader\addons + per-UKI dropin)        stub.c:1019-1076
  7 DT:.dtbauto>.dtb;addon DT 量入 PCR12                   stub.c:1264-1265
  8 组 initrd:ucode→previous→.initrd→cred/sysext/confext  stub.c:36-52,1283-1285
      →.pcrsig/.pcrpkey/.osrel/.profile cpio→addons
  9 export_pcr_variables;combine_initrds → LoadFile2 注册   stub.c:1288,971-988,1291-1304
 10 linux_exec:.linux 段作 PE 装载/交接( cmdline+initrd )  stub.c:1306-1310, linux.c:175
```

## 九、纠偏清单(以 1f66b524 为准)

1. "EFI 源码在 src/efi/"——错,在 `src/boot/`(ls 实测;`src/efi/` 不存在,详见 §一)。
2. "ukify 用 sbattach 剥/挂签名、内置签名器或自算 PCR 摘要"——全错:签名是三种 subprocess 外调(ukify.py:540-584、605-636),内核是否已签靠 sbverify/pesign 探测(ukify.py:1401-1403),PCR 一律 exec systemd-measure(ukify.py:812-817),`--pcr-banks` 仅字符串切分无校验(ukify.py:643-646),全程无 sbattach(grep 实测)。
3. "`.dtbadd` 段"——不存在;DTB 扩展靠 `.dtb/.dtbauto` 段与 `*.addon.efi`(grep "dtbadd" 零命中;stub.c:642-666)。
4. "`.pcrsig` 也被测量进 PCR11"——错:全段表唯它被显式排除(uki.h unified_section_measure;stub.c:888-895)。
5. "PE 内段顺序即启动时 initrd 顺序"——错:`.ucode` 在文件内排 `.initrd` 之后(ukify.py:1472-1475),启动时却插到合并 initrd 最前(stub.c:36-39、474-476、1283)。
6. "ukify 预签名策略覆盖全部被测段"——本 commit 不成立:`.efifw` 被 stub 测量却未参与 ukify 的 systemd-measure 调用(ukify.py:1474 vs stub.c:733-760)(见 §六)。

## 十、设计动机

1. 单 PE 即完整启动资产:内核/initrd/cmdline 全部入段,SecureBoot 只验一个实体;内核段再经 LoadImage 安全回调二次校验(linux.c:62-83)。
2. PCR11 只收"可预计算"的静态镜像数据,可变输入分流 PCR12/13,使磁盘解锁策略能离线算出(stub.c:730-732;tpm2-pcr.h:23-28 注释)。
3. PCR 策略离线预签名进 `.pcrsig`,随镜像分发并在启动时以 `/.extra/tpm2-pcr-signature.json` 交给用户态,免去启动期 TPM 在线签名的运维负担(stub.c:888-895)。
4. 多 profile UKI 用 `.profile` 分界共享未变段,不同 ID 的 profile 可选择性签 PCR(ukify.py:1505-1509、1574-1579),运行时用 `@N` 零成本切换(stub.c:150-182)。
5. addon 机制(`\loader\addons` + per-UKI dropin)允许不动 UKI 就扩展 cmdline/DTB/initrd/ucode,但 addon 自身必须过 SB/MoK 验证且不得含 `.linux`(stub.c:584、617-621),扩展性不以放弃验签为代价。
6. ucode 插最前是因为内核取"第一个匹配"的微码 cpio;其余 initrd 后写覆盖先写——同一合并流里同时表达两种语义(stub.c:1274-1282);随机种子每启动演进并写入 Linux random-seed 配置表,为无 TPM 环境提供熵与 boot-secret 兜底(random-seed.c:400-417;boot-secret.c:9-23)。

## 十一、FAQ 候选

1. ukify 用什么给 UKI 签名?sbsign/pesign/systemd-sbsign 三选一(`--signtool`),全部是外部进程调用,无内置实现(ukify.py:522-641)。
2. `--pcr-banks=` 写错会怎样?ukify 只按逗号/空白切分直接透传 `--bank=`,不校验(ukify.py:643-646)。
3. `.pcrsig` 里的 JSON 为什么先填 1024 个空格?为离线 `--pcrsig` 追加签名预留空间,按每 `"pol":` 条目 1024 字节填充(ukify.py:905-910)。
4. stub 怎么读取自己的段?固件已把 PE 映射进内存,stub 直接按 ImageBase 解析段表取 `memory_offset/size`(pe.c:700-753;stub.c:61-85)。
5. `.pcrsig` 为什么不测量?它是"测量的期望值",再量进去会自指;全段表只有它被排除(uki.h unified_section_measure)。
6. credentials 文件从哪来、进哪个 PCR?UKI 同目录与 `\loader\credentials` 的 `.cred` 打包为 `/.extra/credentials|global_credentials`,量入 PCR12(stub.c:819-837;cpio.c:512-524)。
7. sysext 和 confext 进哪个 PCR?sysext 进 PCR13,confext 进 PCR12(cpio.c:526-552)。
8. 什么时候自定义内核 cmdline 会被丢弃?SecureBoot 开启且 UKI 自带 `.cmdline`(或处于机密 VM)时(stub.c:1155-1158)。
9. 随机种子文件在哪、怎么演进?ESP 的 `\loader\random-seed`,SHA256 混入旧种子、UEFI 单调计数器与 RTC 后回写并装成配置表(random-seed.c:267-272、328-348、414)。
10. 多 profile UKI 怎么选中某 profile?内核 cmdline 首个参数 `@N`(或 shell Argv),stub 按第 N 个 `.profile` 段分界覆盖基础段,上限 256 档(stub.c:150-204;pe.c:818-874;uki.h)。

## 十二、深挖方向

1. `pe_add_sections` 的手工 PE 重写细节:符号表剥离、`SizeOfHeaders` 腾挪、pefile 256MB 限制与告警即错误(ukify.py:1044-1052),对超大 initrd(全量固件+模块)的影响。
2. systemd-measure 的 phase 策略语义:`enter-initrd…final` 六阶段如何映射 PCR12 digest 序列,`--policy-ref` 与 `INITRD_PCR_POLICY` 的双签名怎么被 systemd-cryptenroll 消费(ukify.py:793-801;measure-tool.c:297-306)。
3. shim 16 `SHIM_IMAGE_LOADER` 协作路径:load_via_boot_services 与 install_security_override 的分支矩阵(linux.c:50-114、229-247),以及 `.linux` 无重定位检查(pe_kernel_check_no_relocation,linux.c:258)。
4. `.dtbauto` 的 compatible 匹配算法与 `.hwids` CHID 生成(parse_hwid_dir ukify.py:1263-1322;devicetree.c:109-194;generate-hwids-section.py)。
5. boot-secret 生命周期:EFI 变量秘密获取/演进、`\loader\boot-secret-mixin` 与用户态消费方(boot-secret.c:8-23、55-90、300-360)。

## 十三、正文蒸馏要点

1. UKI=stub PE 为底座、按固定顺序追加段的 PE 文件;段序 `.profile? → .osrel/.cmdline/.dtb/.dtbauto/.hwids/.uname/.splash/.pcrpkey/.linux/.initrd/.efifw/.ucode → --sections → .sbat → .profile? → .pcrsig`(ukify.py:1462-1509)。
2. ukify 自身不实现签名与摘要:SB 签名外调 sbsign/pesign/systemd-sbsign(ukify.py:522-641),PCR 计算与签名外调 systemd-measure(ukify.py:812-817),底座改写靠 python-pefile 手工重排(ukify.py:997-1181);唯一例外是 genkey 用 python-cryptography 生成密钥(ukify.py:1623-1702)。
3. PCR11 收全部静态段(段名+段数据各量一次),仅 `.pcrsig` 排除;PCR12 收 cmdline/credentials/confext/addon/profile,PCR13 收 sysext(stub.c:733-760;tpm2-pcr.h:28-38;cpio.c:512-552)。
4. `.pcrpkey/.pcrsig/.profile/.osrel` 四段在启动时被包装成 `/.extra/` 下的 initrd 文件交给用户态(stub.c:880-929)。
5. 合并 initrd 槽位序固定:ucode 最前(kernel 取首个匹配)→previous→`.initrd`→credentials→sysext→confext→meta→boot-secret→addons 最后可覆盖(stub.c:36-52、1274-1285)。
6. 自定义 cmdline 在 SecureBoot+内嵌 `.cmdline` 或机密 VM 下被丢弃,且与 SMBIOS Type11 附加项都会量入 PCR12(stub.c:1155-1158、763-792)。
7. 多 profile 用 `.profile` 段分界 + cmdline `@N` 选择,profile 编号本身量入 PCR12;ukify 支持按 profile ID 分别签 PCR 策略并合并 JSON(stub.c:150-182、1175-1190;pe.c:818-874;ukify.py:1574-1583)。
8. addon PE 全局(`\loader\addons`)先于 per-UKI dropin 加载,须过 shim/MoK 验证、禁含 `.linux`、可按 `.uname` 锁版本(stub.c:584、617-631、1042-1075)。
9. random-seed 每启动演进并经 `LINUX_EFI_RANDOM_SEED_TABLE` 传内核;boot-secret 由此派生并作为兜底秘密传 initrd(random-seed.c:400-417;boot-secret.c:9-23、331-360)。
10. `.linux` 段携带 CODE 属性并联动 NX_COMPAT 标志;最终内核以 LoadImage/安全回调或旧 EFI handover 交接(linux.c:190-199;ukify.py:1089-1102)。
11. 本 commit 一致性缺口:`.efifw` 被 stub 量入 PCR11 但 ukify 未传给 systemd-measure,含 `.efifw` 的 UKI 其 PCR11 预签名策略与实际测量不符(ukify.py:1474;stub.c:733-760;measure-tool.c:263)。
12. 段名 ≤8 字符是硬约束(ukify.py:483-489),`unified_sections[]`(uki.c:7-27)是 ukify↔stub 命名契约的唯一定义点。
