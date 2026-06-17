# Claude Code 离线安装项目日志

日期：2026-06-17  
工作目录：`/Users/fuziqiang/Desktop/claudecode`

## 目标

为无法访问外网的虚拟机服务器准备 Claude Code 完全离线安装包、依赖清单和部署指南。目标机 IP：`192.168.222.138`，默认用户：`fzq` 或 `root`。按要求尽量不使用 `su`，优先普通用户无 root 安装。

## 已执行操作与命令

1. 检查本地项目目录和基础工具。

```bash
pwd && ls -la && command -v ssh || true && command -v scp || true && command -v npm || true && command -v node || true
```

结果：

- 当前目录：`/Users/fuziqiang/Desktop/claudecode`
- 初始目录为空
- 本机存在 `ssh`、`scp`、`npm`、`node`

2. 尝试 SSH 批处理免密探测。

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 fzq@192.168.222.138 'printf reachable'
```

结果：

- 目标机 SSH 可达
- 批处理登录失败：`Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password)`
- 处理：改用 `expect` 进行密码交互，只运行只读探测命令。日志不记录明文密码。

3. 查询 Claude Code 官方安装信息和 npm 包信息。

```bash
npm view @anthropic-ai/claude-code version dist.tarball dist.integrity optionalDependencies dependencies bin --json
npm view @anthropic-ai/claude-code-linux-x64 version dist.tarball dist.integrity dependencies optionalDependencies bin --json
```

结果：

- Claude Code 当前查询版本：`2.1.179`
- 主包无普通 dependencies
- 主包有平台 optionalDependencies
- 目标平台包：`@anthropic-ai/claude-code-linux-x64@2.1.179`

4. 使用 `expect` 探测目标机系统。

```bash
expect <<'EOF'
set timeout 10
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/claude_offline_known_hosts -o ConnectTimeout=8 fzq@192.168.222.138 "printf 'USER='; id -un; printf 'UNAME='; uname -a; printf 'ARCH='; uname -m; printf 'OS='; (cat /etc/os-release 2>/dev/null || true); printf 'NODE='; (node -v 2>/dev/null || true); printf 'NPM='; (npm -v 2>/dev/null || true); printf 'SUDO='; (sudo -n true >/dev/null 2>&1 && echo nopass || echo needs-pass)"
expect {
  -re "(?i)password:" { send "<REDACTED>\r"; exp_continue }
  -re "(?i)yes/no" { send "yes\r"; exp_continue }
  eof
}
EOF
```

结果：

- 用户：`fzq`
- 系统：`Kylin Linux Advanced Server V11 (Swan25)`
- 架构：`x86_64`
- Node：`v20.18.2`
- npm：未输出版本，判定不可用或不在 PATH
- sudo：`needs-pass`

5. 查询官方 npm registry tarball 地址。

```bash
npm config get registry
npm view @anthropic-ai/claude-code@2.1.179 dist.tarball dist.integrity --registry=https://registry.npmjs.org/ --json
npm view @anthropic-ai/claude-code-linux-x64@2.1.179 dist.tarball dist.integrity --registry=https://registry.npmjs.org/ --json
```

结果：

- 本机 npm 默认 registry 为 `https://registry.npmmirror.com`
- 官方主包链接：`https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.179.tgz`
- 官方平台包链接：`https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.179.tgz`

6. 下载 Claude Code release manifest、签名、公钥，并查询 manifest 内容。

```bash
curl -fsSL https://downloads.claude.ai/claude-code-releases/2.1.179/manifest.json | head -c 4000
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc | gpg --show-keys --fingerprint --with-colons
```

问题：

- 本机没有 `gpg`：`zsh:1: command not found: gpg`

处理：

- 保留 `claude-code.asc`、`manifest.json.sig` 到离线包
- 文档中写入目标机或有 gpg 环境的验证步骤
- 本机使用 SHA256 作为基础完整性校验

7. 第二次目标机探测时，第一次 expect 命令写法错误。

错误命令片段：

```bash
spawn ssh ... "printf 'PATH=%s\n' "$PATH"; ..."
```

错误：

```text
can't read "PATH": no such variable
```

处理：

- 改用 expect 的 `{...}` 形式包裹远程命令，避免本地 expect 展开 `$PATH`。

8. 重新探测目标机 PATH、glibc、安装目录。

```bash
expect <<'EOF'
set timeout 10
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/claude_offline_known_hosts -o ConnectTimeout=8 fzq@192.168.222.138 {printf 'PATH=%s\n' "$PATH"; printf 'HOME=%s\n' "$HOME"; command -v claude || true; command -v npm || true; command -v node || true; ldd --version 2>&1 | head -n 1 || true; getconf GNU_LIBC_VERSION 2>/dev/null || true; ls -ld ~/.local ~/.local/bin 2>/dev/null || true}
expect {
  -re "(?i)password:" { send "<REDACTED>\r"; exp_continue }
  -re "(?i)yes/no" { send "yes\r"; exp_continue }
  eof
}
EOF
```

结果：

- PATH：`/usr/lib/qtchooser:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin`
- HOME：`/home/fzq`
- `node`：`/usr/bin/node`
- glibc：`2.38`
- `~/.local` 已存在，`~/.local/bin` 未列出

9. 查看官方原生安装脚本。

```bash
curl -fsSL https://claude.ai/install.sh | sed -n '1,260p'
```

结论：

- 官方脚本根据 OS/arch/libc 选择平台
- 下载 `manifest.json`
- 按 manifest 校验 SHA256
- 下载 `https://downloads.claude.ai/claude-code-releases/<version>/<platform>/claude`

10. 创建离线包目录并开始下载物料。

```bash
mkdir -p offline_bundle/claude-code-2.1.179/linux-x64 offline_bundle/npm-tarballs offline_bundle/node offline_bundle/scripts offline_bundle/docs
curl -fsSL -o offline_bundle/claude-code-2.1.179/manifest.json https://downloads.claude.ai/claude-code-releases/2.1.179/manifest.json
curl -fsSL -o offline_bundle/claude-code-2.1.179/manifest.json.sig https://downloads.claude.ai/claude-code-releases/2.1.179/manifest.json.sig
curl -fsSL -o offline_bundle/claude-code-2.1.179/claude-code.asc https://downloads.claude.ai/keys/claude-code.asc
curl -fsSL -o offline_bundle/claude-code-2.1.179/linux-x64/claude https://downloads.claude.ai/claude-code-releases/2.1.179/linux-x64/claude
chmod +x offline_bundle/claude-code-2.1.179/linux-x64/claude
(cd offline_bundle/npm-tarballs && npm pack --registry=https://registry.npmjs.org/ @anthropic-ai/claude-code@2.1.179 @anthropic-ai/claude-code-linux-x64@2.1.179)
curl -fL -o offline_bundle/node/node-v20.18.2-linux-x64.tar.xz https://nodejs.org/dist/v20.18.2/node-v20.18.2-linux-x64.tar.xz
```

问题：

- 裸二进制下载长时间没有正常结束，检查发现文件只有约 48M，小于 manifest 记录的 251418320 字节。

处理：

- 中断该会话，删除半成品裸二进制
- 改为优先下载 npm 平台 tarball；它包含同一 Linux x64 原生 `claude`，更适合离线分发

11. 断点续传裸二进制测试。

```bash
curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o offline_bundle/claude-code-2.1.179/linux-x64/claude https://downloads.claude.ai/claude-code-releases/2.1.179/linux-x64/claude
```

问题：

- 下载速度过慢，约到 22% 时仍需较长时间。

处理：

- 中断裸二进制下载
- 删除半成品文件
- 裸二进制改列为可选下载项

12. 重新下载 npm tarball 和 Node 包。

```bash
rm -f offline_bundle/claude-code-2.1.179/linux-x64/claude
(cd offline_bundle/npm-tarballs && npm pack --registry=https://registry.npmjs.org/ @anthropic-ai/claude-code@2.1.179 @anthropic-ai/claude-code-linux-x64@2.1.179)
curl -fL --retry 5 --retry-delay 3 --progress-bar -o offline_bundle/node/node-v20.18.2-linux-x64.tar.xz https://nodejs.org/dist/v20.18.2/node-v20.18.2-linux-x64.tar.xz
```

状态：

- 主包 `anthropic-ai-claude-code-2.1.179.tgz` 已完成，大小约 18K
- 平台包正在下载

13. 查看主包内容和安装脚本。

```bash
tar -tzf offline_bundle/npm-tarballs/anthropic-ai-claude-code-2.1.179.tgz | sed -n '1,120p'
tar -xOf offline_bundle/npm-tarballs/anthropic-ai-claude-code-2.1.179.tgz package/package.json
tar -xOf offline_bundle/npm-tarballs/anthropic-ai-claude-code-2.1.179.tgz package/install.cjs | sed -n '1,260p'
tar -xOf offline_bundle/npm-tarballs/anthropic-ai-claude-code-2.1.179.tgz package/cli-wrapper.cjs | sed -n '1,220p'
```

结论：

- 主包 `postinstall` 会根据平台查找 optional dependency 平台包
- 找到 `@anthropic-ai/claude-code-linux-x64` 后，把其 `claude` 原生二进制硬链接或复制到主包 `bin/claude.exe`
- 运行后的 `claude` 是原生二进制，不常驻 Node
- 对目标环境更稳的无 root 离线方式：直接解压平台 tarball 中的 `package/claude` 到 `~/.local/bin/claude`

14. 查询 npm 包大小和 integrity。

```bash
npm view @anthropic-ai/claude-code-linux-x64@2.1.179 dist.unpackedSize dist.fileCount dist.integrity dist.shasum --registry=https://registry.npmjs.org/ --json
npm view @anthropic-ai/claude-code@2.1.179 dist.unpackedSize dist.fileCount dist.integrity dist.shasum --registry=https://registry.npmjs.org/ --json
```

结果：

- 主包 unpackedSize：151069，fileCount：7
- 平台包 unpackedSize：251418906，fileCount：4

15. 生成离线安装脚本和指南。

```bash
apply_patch
```

新增文件：

- `offline_bundle/scripts/install_claude_offline.sh`
- `offline_install_guide.md`
- `setup_log.md`

## 最终补齐状态

- 平台 tarball 下载完成后的文件大小和 SHA256：已补齐
- Node tarball 下载完成后的文件大小和 SHA256：已补齐
- `manifest.txt`：已生成
- `dependencies.json`：已生成

## 继续托管安装记录

16. 用户确认继续托管安装后，重新检查目标机网络和工具。

```bash
expect <<'EOF'
set timeout 12
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/claude_offline_known_hosts -o ConnectTimeout=8 fzq@192.168.222.138 {printf 'USER='; id -un; printf '\n'; printf 'NET_TEST='; timeout 6 curl -I -L -s https://registry.npmjs.org/ >/dev/null && echo ok || echo fail; printf 'TOOLS='; for c in tar sha256sum curl install mktemp; do command -v $c >/dev/null && printf "$c:ok " || printf "$c:missing "; done; printf '\n'; command -v claude || true; claude --version 2>/dev/null || true}
expect {
  -re "(?i)password:" { send "<REDACTED>\r"; exp_continue }
  -re "(?i)yes/no" { send "yes\r"; exp_continue }
  eof
}
EOF
```

结果：

- 目标机可访问 `registry.npmjs.org`
- `tar`、`sha256sum`、`curl`、`install`、`mktemp` 均可用
- 当时尚未安装 `claude`

17. 尝试使用官方安装器安装固定版本。

```bash
curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh
bash /tmp/claude-install.sh 2.1.179
```

问题：

- 官方安装器下载 `https://downloads.claude.ai/claude-code-releases/2.1.179/linux-x64/claude`
- 裸二进制约 251MB，目标机下载速度很慢
- 观察到 `/home/fzq/.claude/downloads/claude-2.1.179-linux-x64` 仅约 8.6MB

处理：

- 停止官方安装器进程
- 删除半成品裸二进制
- 改用 npm 平台压缩包路线

18. 使用 npm tarball 路线安装。

```bash
mkdir -p /tmp/claude-code-install
cd /tmp/claude-code-install
curl -fL --retry 8 --retry-all-errors --retry-delay 3 -C - --progress-bar -o anthropic-ai-claude-code-2.1.179.tgz https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.179.tgz
curl -fL --retry 8 --retry-all-errors --retry-delay 3 -C - --progress-bar -o anthropic-ai-claude-code-linux-x64-2.1.179.tgz https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.179.tgz
test "$(sha1sum anthropic-ai-claude-code-2.1.179.tgz | awk '{print $1}')" = "e64d876dc0b43eda5a250aae3aff897613fdc544"
test "$(sha1sum anthropic-ai-claude-code-linux-x64-2.1.179.tgz | awk '{print $1}')" = "160ec040aedbd8320205e96b9e0fe98fa009d902"
tar -xzf anthropic-ai-claude-code-linux-x64-2.1.179.tgz -C /tmp/claude-code-install/extract
install -m 0755 /tmp/claude-code-install/extract/package/claude ~/.local/bin/claude
```

问题：

- 官方 npm registry 下载平台包仍偏慢。

处理：

- 测试目标机可访问 `https://registry.npmmirror.com/`
- 停止官方 registry 平台包下载
- 对同一文件改用 npmmirror 断点续传
- 下载完成后仍使用官方 npm `dist.shasum` 校验，确保包内容一致

19. 写入离线运行环境变量。

```bash
cat > ~/.claude/settings.json <<'JSON'
{
  "env": {
    "DISABLE_AUTOUPDATER": "1",
    "DISABLE_UPDATES": "1",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_FEEDBACK_COMMAND": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1"
  }
}
JSON
grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc 2>/dev/null || printf '\n# Claude Code local install\nexport PATH="$HOME/.local/bin:$PATH"\n' >> ~/.bashrc
```

20. 验证目标机安装。

```bash
export PATH="$HOME/.local/bin:$PATH"
command -v claude
claude --version
sha256sum ~/.local/bin/claude
sha1sum /tmp/claude-code-install/anthropic-ai-claude-code-linux-x64-2.1.179.tgz
```

结果：

- `claude` 路径：`/home/fzq/.local/bin/claude`
- 版本：`2.1.179 (Claude Code)`
- 二进制 SHA256：`6d8422de5ac8ac2077b20e2a6307083f85609aaf45f8c783ec2f7d71e8781e70`
- 平台 tarball SHA1：`160ec040aedbd8320205e96b9e0fe98fa009d902`
- 平台 tarball 大小：`75999335` bytes

21. 回收完整平台 tarball 到本项目离线包目录。

```bash
scp fzq@192.168.222.138:/tmp/claude-code-install/anthropic-ai-claude-code-linux-x64-2.1.179.tgz offline_bundle/npm-tarballs/anthropic-ai-claude-code-linux-x64-2.1.179.tgz
```

结果：

- 完整平台包已保存到 `offline_bundle/npm-tarballs/`

22. 下载 Node.js/npm 备用运行时。

```bash
curl -fL --retry 5 --retry-all-errors --retry-delay 3 -C - --progress-bar -o offline_bundle/node/node-v20.18.2-linux-x64.tar.xz https://npmmirror.com/mirrors/node/v20.18.2/node-v20.18.2-linux-x64.tar.xz
```

说明：

- 官方源：`https://nodejs.org/dist/v20.18.2/node-v20.18.2-linux-x64.tar.xz`
- 实际使用镜像源下载同一版本包
- 此包仅作为 npm-wrapper 安装备用；当前目标机已通过原生二进制安装成功

23. 生成最终清单。

```bash
shasum -a 256 offline_bundle/claude-code-2.1.179/manifest.json offline_bundle/claude-code-2.1.179/manifest.json.sig offline_bundle/claude-code-2.1.179/claude-code.asc offline_bundle/npm-tarballs/*.tgz offline_bundle/node/node-v20.18.2-linux-x64.tar.xz offline_bundle/scripts/install_claude_offline.sh
shasum offline_bundle/npm-tarballs/*.tgz offline_bundle/node/node-v20.18.2-linux-x64.tar.xz
```

新增最终交付文件：

- `manifest.txt`
- `dependencies.json`

24. 生成并传输完整离线交付包。

```bash
tar -czf claude-code-offline-bundle-2.1.179-linux-x64.tar.gz offline_bundle manifest.txt dependencies.json offline_install_guide.md setup_log.md
shasum -a 256 claude-code-offline-bundle-2.1.179-linux-x64.tar.gz
scp claude-code-offline-bundle-2.1.179-linux-x64.tar.gz fzq@192.168.222.138:/home/fzq/
ssh fzq@192.168.222.138 'sha256sum /home/fzq/claude-code-offline-bundle-2.1.179-linux-x64.tar.gz; export PATH="$HOME/.local/bin:$PATH"; claude --version'
```

结果：

- 本地交付包：`claude-code-offline-bundle-2.1.179-linux-x64.tar.gz`
- 大小：约 `97M`
- SHA256：`3f5c33ff3169ee2dbbd62055678a30652cad92836930c8e1fe4f00f5eb497bd2`
- 远程保存位置：`/home/fzq/claude-code-offline-bundle-2.1.179-linux-x64.tar.gz`
- 远程 SHA256 与本地一致
- 远程 `claude --version`：`2.1.179 (Claude Code)`
