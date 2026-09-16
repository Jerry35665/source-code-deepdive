# zstd 扩展:流式 API 与 Seekable Format

> zstd 精简卷补篇。基线:commit `d79e723`。行号以 lib/compress/zstd_compress.c、contrib/seekable_format/ 为准。

## 流式压缩:compressStream2 唯一入口

```
创建 CStream(= CCtx 别名)→ 循环调用 ZSTD_compressStream2(cctx,out,in,endOp)
  → 返回 0(e_end 时)=帧完整→free
三 endOp(zstd.h:784-793):
  e_continue:攒不满一块直接返回,零输出,压缩率优先
  e_flush:强制压成完整块,帧不关,后续仍可背引用
  e_end:末块置 lastBlock 关帧,历史作废
```

单线程双状态机 `zcss_load→zcss_flush`(zstd_compress_internal.h:47):load 把用户输入攒进 inBuff,满一块才压缩;压缩不可中断,先进 outBuff,flush 拷给用户(:6278-6294)。消费模型:in/out 各含 {指针,size,pos},**库只更新 pos,所有权在调用者**(lib/zstd.h:701-711)。

## Seekable Format:随机访问压缩

**格式**=N 个独立 zstd 帧+一个 skippable frame 装 seek table;表项 {Compressed_Size,Decompressed_Size,[Checksum]},footer 9 字节含 Number_Of_Frames+magic 0x8F92EAB1(zstdseek_compression_format.md:34-114)。**随机访问**:读尾 9 字节 footer→载表→按 dOffset 二分定位帧(:296-315)→seek 到帧起点+dummy 解压丢弃前缀+直接输出+checksum(:489-582)。放 contrib 因为只是帧排列约定——普通解码器自动忽略跳过帧、向后兼容。

## 设计动机

1. **为什么流式 API 是"回调式"**:in/out 缓冲区所有权在调用者——嵌入式的零拷贝需求(与 05 章 FFmpeg 的 buffer 所有权模式同族);
2. **为什么 Seekable 放 contrib**:绑 fseek/FILE 语义与应用层切帧策略——普通解码器自动忽略跳过帧,**向后兼容零成本**;
3. **flush 与 end 的代价**:flush 强制出块(压缩率损失),end 关帧(历史作废)——SSE 场景用 flush 保实时,日志场景用 end 保比率;
4. **hostageByte**:解压尾部输出不足时扣住数据等更多输入(:2364-2382)——防"解压完了但还没写够"的边界。

## FAQ

**Q1:compressStream2 返回值是什么?**
不是错误码:是"内部待 flush 剩余量"下界(:6571);0=e_end 完成。

**Q2:e_continue 什么时候有输出?**
攒满一块才压缩输出(:6198-6202);MT 下"任一进展"即回(:6543-6549)。

**Q3:e_flush 和 e_end 差在哪?**
flush:帧不关,后续可继续背引用;end:关帧+历史作废(:6236-6300)。

**Q4:Seekable 能和普通 zstd 混用吗?**
能:seekable 帧是标准帧+skippable 帧,普通解码器自动跳过 skippable。

**Q5:随机访问的原理?**
seek table 记录每帧偏移(:296-315):二分定位帧→seek→dummy 解压丢前缀→输出。

**Q6:hostageByte 是什么?**
(:2364-2382):解压尾部输出不足时扣住数据——防截断。

**Q7:window 怎么滑动?**
ZSTD_window_update(:1376-1412):非连续输入把旧 prefix 降格 extDict。

**Q8:MT 模式的流式接口?**
compressStream2 透明路由到 MT(:6428-6446):用户无感。

## 小结与深挖方向

本章结论:**流式="双状态机+三 endOp+所有权在调用者";Seekable="skippable 帧+seek table+随机访问"**。深挖:

1. MT 下 e_flush 的阻塞语义(:6543-6549)与延迟;
2. Seekable 的 maxFrameSize 与随机访问粒度的权衡;
3. hostageByte(:2364-2382)在 pipeline 解压的边界;
4. windowLog 溢出回卷(:1154-1251)的正确性论证;
5. Seekable checksum 的安全用途。

> zstd 扩展完——流式与 Seekable 补齐了使用面的最后空白。
