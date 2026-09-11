#!/bin/bash
set -e
# Copy ffmpeg-series into the main repo and push from there
cd "C:/Users/Jerry/.zcode/workspace/default/source-code-deepdive"
mkdir -p ffmpeg-series
cp -r "C:/Users/Jerry/source-code-deepdive-publish/ffmpeg-series/"* ffmpeg-series/
rm -f ffmpeg-series/push.sh ffmpeg-series/setup-and-push.sh ffmpeg-series/update-push.sh ffmpeg-series/clean-push.sh ffmpeg-series/ffmpeg-push.sh

git config user.name "Jerry35665"
git config user.email "Jerry35665@users.noreply.github.com"

git add ffmpeg-series/
git commit -m "第二系列《多媒体引擎:FFmpeg 深读》首卷(GLM 生成)

9 篇正文 + 6 份子系统调研报告:
- 02 avio I/O 层与 demuxer 框架(MP4 盒子解析案例)
- 03 编解码器框架(send/receive 管线、H.264 入口、BSF)
- 04 滤镜图框架(activate 调度、framesync、有理数时间戳)
- 05 mux 框架(交织算法、faststart、hwaccel、FATE)
- 07 音频管线(swresample 多相 FIR、rematrix、AAC/Opus)
- 08 视频编解码器(H.264 NAL→DPB、多线程、CABAC、HEVC/VP9)
- 全部结论标注 文件:行号,可对照源码验证
- AI 编码助手:GLM-5.3-Flash(ZCode 多智能体)"

echo "=== COMMIT DONE ==="

GIT_SSH_COMMAND="ssh -o ConnectTimeout=15 -p 443 -o StrictHostKeyChecking=no" \
  git push git@ssh.github.com:Jerry35665/source-code-deepdive.git main

echo "=== PUSH DONE ==="
