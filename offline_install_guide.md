# Claude Code 离线安装部署指南

目标服务器已探测为：

- IP：`192.168.222.138`
- 用户：`fzq`
- 系统：Kylin Linux Advanced Server V11 (Swan25)
- 架构：`x86_64`
- libc：glibc 2.38
- Node：`v20.18.2`
- npm：未检测到可用命令
- sudo：需要密码

## 结论

本机应使用 `linux-x64` 平台包。推荐离线安装方式是直接从 `@anthropic-ai/claude-code-linux-x64` npm tarball 解出原生 `claude` 二进制并放入 `~/.local/bin`。这样无需 root、无需联网、启动时不依赖 npm。

Claude Code 是在线 AI 编程工具；“离线/断网完全独立启动”可以做到，但真正发起模型对话仍需要可达的 Anthropic/Bedrock/Vertex/代理 API。本文配置会禁用自动更新、遥测、错误上报和官方 marketplace 自动安装，避免非必要外联。

## 必须提前下载的文件

固定版本：`Claude Code 2.1.179`。

1. Claude Code wrapper npm 包
   - 文件：`offline_bundle/npm-tarballs/anthropic-ai-claude-code-2.1.179.tgz`
   - 官方链接：`https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.179.tgz`
   - 作用：npm 包元数据、postinstall、wrapper。

2. Claude Code Linux x64 平台包
   - 文件：`offline_bundle/npm-tarballs/anthropic-ai-claude-code-linux-x64-2.1.179.tgz`
   - 官方链接：`https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.179.tgz`
   - 作用：包含 Linux x64 原生 `claude` 二进制，是本方案的核心安装包。

3. Claude Code release manifest
   - 文件：`offline_bundle/claude-code-2.1.179/manifest.json`
   - 官方链接：`https://downloads.claude.ai/claude-code-releases/2.1.179/manifest.json`
   - 作用：记录各平台二进制 SHA256。

4. Claude Code manifest 签名
   - 文件：`offline_bundle/claude-code-2.1.179/manifest.json.sig`
   - 官方链接：`https://downloads.claude.ai/claude-code-releases/2.1.179/manifest.json.sig`
   - 作用：用于验证 manifest 来源。

5. Claude Code 发布签名公钥
   - 文件：`offline_bundle/claude-code-2.1.179/claude-code.asc`
   - 官方链接：`https://downloads.claude.ai/keys/claude-code.asc`
   - 官方指纹：`31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`

6. Node.js/npm 运行时备用包
   - 文件：`offline_bundle/node/node-v20.18.2-linux-x64.tar.xz`
   - 官方链接：`https://nodejs.org/dist/v20.18.2/node-v20.18.2-linux-x64.tar.xz`
   - 作用：目标机已有 Node 但无 npm；如需走 npm 全局安装或排障，可解压该包获得 node/npm/npx。

可选裸二进制：

- 链接：`https://downloads.claude.ai/claude-code-releases/2.1.179/linux-x64/claude`
- manifest 中 `linux-x64` SHA256：`6d8422de5ac8ac2077b20e2a6307083f85609aaf45f8c783ec2f7d71e8781e70`
- 说明：体积约 251MB；本次优先使用 npm 平台 tarball，未把裸二进制列为必须物料。

## 拷贝到内网服务器

在有网机器执行：

```bash
tar -czf claude-code-offline-bundle-2.1.179-linux-x64.tar.gz offline_bundle manifest.txt dependencies.json offline_install_guide.md setup_log.md
scp claude-code-offline-bundle-2.1.179-linux-x64.tar.gz fzq@192.168.222.138:/home/fzq/
```

如果 `scp` 不能自动输入密码，可在终端手动执行上述命令并输入目标用户密码。

## 目标机离线安装

登录目标机后执行：

```bash
cd /home/fzq
tar -xzf claude-code-offline-bundle-2.1.179-linux-x64.tar.gz
chmod +x offline_bundle/scripts/install_claude_offline.sh
offline_bundle/scripts/install_claude_offline.sh
export PATH="$HOME/.local/bin:$PATH"
claude --version
```

安装结果：

- `~/.local/bin/claude`：原生 Claude Code CLI
- `~/.claude/settings.json`：首次安装时写入离线/禁外联相关环境变量
- `~/.bashrc`、`~/.zshrc`：如果文件存在，会追加 `~/.local/bin` 到 PATH

## npm 全局安装备用路线

只有在必须保留 npm wrapper 安装形态时使用此路线。

```bash
cd /home/fzq/offline_bundle
mkdir -p "$HOME/.local/node-v20.18.2"
tar -xJf node/node-v20.18.2-linux-x64.tar.xz -C "$HOME/.local"
export PATH="$HOME/.local/node-v20.18.2-linux-x64/bin:$PATH"
node -v
npm -v

mkdir -p "$HOME/.npm-offline-cache"
npm cache add npm-tarballs/anthropic-ai-claude-code-linux-x64-2.1.179.tgz --cache "$HOME/.npm-offline-cache"
npm cache add npm-tarballs/anthropic-ai-claude-code-2.1.179.tgz --cache "$HOME/.npm-offline-cache"
npm install -g --offline --cache "$HOME/.npm-offline-cache" \
  npm-tarballs/anthropic-ai-claude-code-linux-x64-2.1.179.tgz \
  npm-tarballs/anthropic-ai-claude-code-2.1.179.tgz
claude --version
```

如果 npm 全局安装提示权限错误，不要使用 `sudo npm install -g`。改用用户级 prefix：

```bash
mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"
```

## 完整性校验

在目标机执行：

```bash
sha256sum offline_bundle/claude-code-2.1.179/manifest.json
sha256sum offline_bundle/npm-tarballs/*.tgz
sha256sum offline_bundle/node/node-v20.18.2-linux-x64.tar.xz
```

如目标机有 `gpg`：

```bash
gpg --import offline_bundle/claude-code-2.1.179/claude-code.asc
gpg --fingerprint security@anthropic.com
gpg --verify offline_bundle/claude-code-2.1.179/manifest.json.sig offline_bundle/claude-code-2.1.179/manifest.json
```

确认指纹包含：

```text
31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE
```

## 离线运行注意事项

为避免启动时触发更新或非必要远程请求，脚本会在 `~/.claude/settings.json` 写入：

```json
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
```

如已有 `~/.claude/settings.json`，脚本不会覆盖，需要手动合并这些环境变量。


export PATH="$HOME/.local/bin:$PATH"

export ANTHROPIC_BASE_URL="你的API地址"
export ANTHROPIC_API_KEY="你的APIKey"

claude