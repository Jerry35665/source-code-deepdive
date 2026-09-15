# 第 08 章 · 快照与 code cache:冷启动的两级加速

> 基线:commit `c6a1f7c2`。行号以 src/snapshot/、src/execution/isolate.cc 为准。

## 8.0 全景:三级加速

```
V8 冷启动 = 建内置对象 + 编译 builtins + 编译用户 JS,三样都有缓存:
① embedded blob:1500+ 个 builtins 的机器码编进二进制 .text(启动免编译)
② snapshot blob:内置对象图的堆"照片"(启动免建对象)
③ code cache:用户 JS 的编译产物(SFI+字节码,免解析编译)
```

mksnapshot 在**构建期起真 Isolate 跑 bootstrap**(mksnapshot.cc:225-346),产出互不重叠的三样——**用构建时间换启动时间**的总设计。

## 8.1 embedded blob:builtins 机器码入二进制

builtins 机器码写成 C 数组编进 .text(embedded-file-writer.cc:168-211);数据段含 hash、每 builtin 的 LayoutDescription 与按 offset_end 排序的二分查找表(embedded-data.h:212-227)。**short builtin calls 优化**:把 blob remap 一份到 code range 末端,使 PC 相对跳转可达(isolate.cc:5890-5906;code-range.cc:495-553,老生代阈值 2GB)——跨 2GB 距离的调用要 trampoline,remap 消灭它。mksnapshot 特意把 code range 设为 PC 相对可达上限(:292-300)。

## 8.2 snapshot blob:四段堆对象图

snapshot.cc:73-106 头部布局(N contexts/rehash/checksum/版本串/各段 offset);`Snapshot::Create`(:401-483)四序列化器汇成 blob:RO→Shared→Startup→Context;zlib raw 压缩(:498-523);可 warmup 预热(:817-852)。**序列化格式**是单字节操作码流(serializer-deserializer.h:79-191):kNewObject=0x00+4 空间号、kBackref=0x04(对象→序号)、根表常量 0x40-0x5f(前 32 个根 1 字节)、kFixedRawData=0x60、8 槽热对象 0x90;环用 kRegister/kResolvePendingForwardRef 前向引用(serializer.cc:348-373)。反序列化按"分配→装 map→其余字段填 Smi 哨兵→逐槽覆盖"(deserializer.cc:818-845)——**填字段时 GC 可遍历**,底层走常规 AllocateRawOrFail(:1723);RO 段独立页镜像(read-only-deserializer.cc:27-56)。

## 8.3 code cache:用户 JS 的第三级

`ScriptCompiler::CreateCodeCache`(api.cc:2990)写用户 JS 的 SFI+字节码对象图,`kConsumeCodeCache`(compiler.cc:3979)消费。头部六槽(version/source/flag/RO-checksum/payload/checksum,code-serializer.h:117-127);**SanityCheckWithoutSource 七步校验**(:780-814)不匹配即 Reject 回退全量编译;快照本体用 64 字节版本串硬校验,**不匹配 FATAL**(snapshot.cc:735-751)——内置快照与用户缓存的容错等级刻意不同。

## 8.4 设计动机

1. **为什么 builtins 机器码嵌二进制**:免编译+**short builtin calls**(生成代码与 builtins 距离近,PC 相对寻址直达)——性能与安全(只读)双赢;
2. **快照是"可重定位对象图字节码"而非页 dump**:对 ASLR/多实例友好——代价是 back/forward-ref 重定位与严格版本绑定;
3. **三级容错梯度**:embedded(错则 FATAL)/snapshot(版本错 FATAL)/code cache(不匹配 Reject 回退)——**越靠近二进制的越严格**;
4. **反序列化的 GC 安全次序**:先 map 后 Smi 哨兵再逐槽——每一步堆都可遍历(:818-845 注释)。

## 8.5 FAQ

**Q1:node 启动为什么比浏览器慢?**
node 的 context snapshot 比浏览器大(内置模块):反序列化对象更多。

**Q2:V8 升级后旧 code cache 还能用吗?**
不能:version hash/flag hash/RO checksum 任一不匹配即拒(:780-814)。

**Q3:embedded blob 在内存哪里?**
.code 段+可选 remap 到 code range 末端(:5890-5906)——PC 相对跳转可达。

**Q4:snapshot 能自定义吗?**
能:v8::SnapshotCreator(自定义 context 快照)——嵌入式定制启动状态。

**Q5:反序列化时 GC 会跑吗?**
会:每步都保持堆可遍历(:818-845)——分配走常规路径。

**Q6:为什么 code cache 错了只回退而快照错了 FATAL?**
code cache 是用户数据(可重编译);embedded/snapshot 是二进制一致性(错=二进制坏)。

**Q7:warmup 是什么?**
(:817-852):快照生成时预跑代码,让 IC/反馈进快照——自定义 context 的热启动。

**Q8:RO 段为什么独立?**
只读空间跨 isolate 共享、可写保护(read-only-deserializer.cc:27-56)。

**Q9:kHotObject=0x90 是什么?**
高频重复引用的 8 槽快速编码(:79-191):序列化流的自压缩。

**Q10:压缩用的是 zlib raw?**
是(:498-523):无头部开销,长度自管。

## 8.6 小结与深挖方向

本章结论:**快照="构建期真跑 bootstrap+三级缓存(embedded/snapshot/code cache)+字节码式对象图+分级容错"**。深挖:

1. remap(:5890-5906)在 2GB+ 堆配置下的回退行为;
2. kHotObject(:79-191)的命中分布统计;
3. code cache 的 flag hash 对调参用户的重编译频率;
4. RO 页镜像(:27-56)与 CRIU 类快照的兼容;
5. SnapshotCreator 的自定义 context 在多租户的安全边界。

> 下一章(卷二卷末):V8 测试体系与工程。
