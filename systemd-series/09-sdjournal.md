# 第 09 章 · sd-journal:日志查询库与过滤引擎(卷二)

> 基线:commit `1f66b524`。核心:src/libsystemd/sd-journal/sd-journal.c(3836 行)、journal-file.c 读侧;journalctl 已拆 6 个文件。

## 9.0 全景:一次带 Match 的查询

```
sd_journal_next → 对每个文件独立推进(k 个候选):
  有 Match(DISCARETE "_PID=731"):①data hash 表定位字段值对象
    ②在该对象的 entry 偏移链上二分出 after_offset 之后第一条 —— 匹配是"跳"不是"试"
  AND 项:gallop 循环收敛交集;OR 项:各子项取最小 offset
  → compare_locations 五级键跨文件归并取最小:seqnum(同域)→boot_id(估值)→realtime→xor_hash
  → set_location 全局游标 →(follow:目录 inotify→重入归并循环)
纠偏:无全局索引;bisection table 已被 ChainCacheItem 链缓存取代;bbox 记账已不存在(AND 交集就是 gallop 循环)
```

## 9.1 游标是值,不是位置

游标字符串六键自描述:`s=seqnum_id;i=seqnum;b=boot_id;m=monotonic;t=realtime;x=xor_hash`——不绑定文件、可序列化、拷到别的机器也能 `--after-cursor` 续读(sd_journal_test_cursor 逐键校验)。seek 族都是"重置 location 只设键",真定位推迟到 next。跨 boot 排序靠 newest_by_boot_id prioq 估值(仅同源机器可比),无 RTC 机器可能选错文件——`exact_match` 修正:若某文件恰好持有游标的精确 (seqnum_id,seqnum) 则强制采纳(issue #31516)。

## 9.2 Match:四层树与链跳转

`add_match` 把 FIELD=value 收进固定四层树(level0 AND term→level1 OR→level2 AND→level3 OR→level4 具体匹配);`add_disjunction`/`add_conjunction` 以"置空下层指针"的顺序 API 拼出任意 AND/OR 形状。求值核心:DISCRETE 一次哈希定位 data 对象+链上二分——**复杂度与命中数的对数相关,与文件总条数无关**;新式 keyed-hash 因每文件种子不同不能预存哈希,求值时现算。正则(--grep)因 MESSAGE 值无序才退回逐条扫描——**索引的边界恰好画在"值是否可序"上**。

## 9.3 二分:链缓存 + 双重二分求交

generic_array_bisect 在 entry-array 单链上二分:ChainCacheItem 记录"上次停在哪个 array、累计多少项"(≤20 项),顺序扫描天然命中,写侧零维护;坏条目(EBADMSG)收缩右界或回退。双重二分求交是教科书实现:"找某 boot 内含某字段且时刻 ≥t 的第一条"——在 _BOOT_ID 链上按 monotonic 二分,再在字段链上按 offset 二分,两个结果不一致就交替逼近直至收敛(journal-file.c:3732-3803)。实时跟随:目录级 inotify(文件会轮转换 inode),溢出则 generation 全量重枚举兜底;归并中选中的文件被 vacuum 掉(-EIDRM)则剔除重试——剔除保证下轮必有进展。

## 9.4 journalctl 要点

定位四策略:cursor 续读→--reverse/-n 先 seek tail→--since 按 realtime→默认 head。**--grep 无降级**:没有 PCRE2 直接报错,不匹配走逐条过滤(隐含 --reverse 自尾回扫,全不命中模仿 grep 返回非零);大小写自动(模式含大写即敏感)。-F 值枚举沿 field 值链遍历跨文件去重,并用 journal_file_pin_object 固定对象防窗口换出。

## 9.5 设计动机

1. **游标是值**:文件会轮转/vacuum/跨机拷贝,偏移会失效;六键游标让"位置"成为可序列化数据,--cursor-file 因此能做断点续传采集;
2. **k 路归并而非全局索引**:写侧主动切文件,全局索引要与轮转竞争;每文件内部天然有序,归并只需 O(k) 次文件内推进;
3. **Match 走 data 链跳转**:命中位置写侧已串进倒排链,复杂度与总条数无关;
4. **链缓存取代 bisect 表**:静态加速结构随追加失效;链缓存是纯运行时记忆,写侧零维护;
5. **grep 不建 ngram 索引**:典型查询是"字段等值+时间范围",为少数派维护倒排会放大写放大。

## 9.6 FAQ

**Q1:journalctl 怎么跨文件排序?**
五级键归并:同 seqnum_id 比 seqnum、同 boot 比 monotonic、再 realtime、xor_hash 兜底。

**Q2:游标拷到别的机器能用吗?**
能:六键自描述,test_cursor 逐键校验。

**Q3:AND 条件怎么求交?**
gallop 循环:反复跳到当前已知最小命中之后;无 bbox 记账(已移除)。

**Q4:-b 快捷路径为什么快?**
sd_id128_get_boot 一步拿当前 boot id,避免逐 boot 遍历。

**Q5:文件被 vacuum 删了查询会崩吗?**
-EIDRM 剔除该文件重试;剔除保证下轮必有进展。

**Q6:inotify 溢出怎么办?**
generation 全量重枚举兜底;"事件增量+全量兜底"经典组合。

**Q7:没有 PCRE2 时 --grep 会怎样?**
直接报错退出(-EOPNOTSUPP),无逐字降级。

**Q8:同一日志在两个文件里会输出两次吗?**
不会:五键全等判重,由"最赢得比较"的文件提供。

**Q9:monotonic 能跨 boot 比较吗?**
不能:仅 boot 内有效,不匹配返回 -ESTALE;跨 boot 走 prioq 估值。

**Q10:-F 列出字段值为什么需要 pin?**
沿值链遍历时防止当前对象被缓冲池窗口换出。

## 9.7 小结与深挖方向

本章结论:**查询侧="每文件跳转+k 路归并+值游标+链缓存二分,索引边界画在'值是否可序'"**。深挖:

1. compare_boot_ids 估值与 newest_machine_id 校正(journal-remote 场景);
2. ChainCacheItem 在随机 seek 下的退化行为;
3. --list-boots 的 discover_next_id 扫描算法;
4. short-delta 输出的时钟线性映射(map_clock_usec_raw);
5. 7168 文件上限与内存占用的权衡。
