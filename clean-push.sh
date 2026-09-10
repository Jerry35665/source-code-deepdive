#!/bin/bash
set -e
cd "C:/Users/Jerry/source-code-deepdive-publish"

# Remove operational helper files from git tracking
git rm --cached push.sh setup-and-push.sh UPLOAD-GUIDE.md 2>/dev/null || true

# Remove old git history entirely (contains personal email)
rm -rf .git
git init -b main

# Set clean author identity (GitHub noreply format)
git config user.name "Jerry35665"
git config user.email "Jerry35665@users.noreply.github.com"

# Add exclude rules
cat > .gitignore << 'EOG'
push.sh
setup-and-push.sh
UPLOAD-GUIDE.md
*.log
EOG

# Commit with clean identity
git add -A
git commit -m "源码深读·系统开源项目解读系列:八卷完整交付(GLM 生成)

八卷 65 篇正文 + 38 份子系统调研报告:
- 卷一 Redis / 卷二 SQLite / 卷三 LevelDB / 卷四 etcd-raft
- 卷五 Nginx / 卷六 Kafka / 卷七 Kubernetes / 卷八 llama.cpp
- 全部结论标注 文件:行号,可对照源码验证
- AI 编码助手:GLM-5.3-Flash(ZCode 多智能体)"

echo "=== COMMIT AUTHOR ==="
git log --format="%an <%ae>"
echo "=== FILES ==="
git ls-files | wc -l
echo "=== NO SENSITIVE FILES ==="
git ls-files | grep -cE "push\.sh|setup-and-push|UPLOAD-GUIDE" || echo "0 (clean)"

echo "=== PUSHING ==="
GIT_SSH_COMMAND="ssh -o ConnectTimeout=15 -p 443 -o StrictHostKeyChecking=no" \
  git push git@ssh.github.com:Jerry35665/source-code-deepdive.git main

echo "=== PUSH DONE ==="
