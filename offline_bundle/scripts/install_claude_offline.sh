#!/usr/bin/env bash
set -euo pipefail

VERSION="2.1.179"
PLATFORM="linux-x64"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_BIN_DIR="${HOME}/.local/bin"
CLAUDE_HOME="${HOME}/.claude"
PLATFORM_TGZ="${ROOT_DIR}/npm-tarballs/anthropic-ai-claude-code-linux-x64-${VERSION}.tgz"
MAIN_TGZ="${ROOT_DIR}/npm-tarballs/anthropic-ai-claude-code-${VERSION}.tgz"
NODE_TARBALL="${ROOT_DIR}/node/node-v20.18.2-linux-x64.tar.xz"

echo "Claude Code offline installer"
echo "Version: ${VERSION}"
echo "Platform: ${PLATFORM}"

case "$(uname -s)" in
  Linux) ;;
  *) echo "ERROR: this bundle is for Linux x64 only." >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) echo "ERROR: expected x86_64/amd64 architecture, got $(uname -m)." >&2; exit 1 ;;
esac

if ldd /bin/ls 2>&1 | grep -qi musl; then
  echo "ERROR: musl Linux detected. Use claude-code-linux-x64-musl instead." >&2
  exit 1
fi

if [[ ! -f "${PLATFORM_TGZ}" ]]; then
  echo "ERROR: missing platform tarball: ${PLATFORM_TGZ}" >&2
  exit 1
fi

if [[ ! -f "${MAIN_TGZ}" ]]; then
  echo "WARN: missing wrapper tarball: ${MAIN_TGZ}" >&2
  echo "      Native install can continue, but npm-wrapper install will not be possible."
fi

mkdir -p "${INSTALL_BIN_DIR}" "${CLAUDE_HOME}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

tar -xzf "${PLATFORM_TGZ}" -C "${tmpdir}"
if [[ ! -x "${tmpdir}/package/claude" && ! -f "${tmpdir}/package/claude" ]]; then
  echo "ERROR: package/claude not found in ${PLATFORM_TGZ}" >&2
  exit 1
fi

install -m 0755 "${tmpdir}/package/claude" "${INSTALL_BIN_DIR}/claude"

settings_file="${CLAUDE_HOME}/settings.json"
if [[ ! -f "${settings_file}" ]]; then
  cat > "${settings_file}" <<'JSON'
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
else
  echo "Existing ${settings_file} preserved. Ensure offline env vars are configured manually."
fi

profile_line='export PATH="$HOME/.local/bin:$PATH"'
for profile in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [[ -f "${profile}" ]] && ! grep -Fq "${profile_line}" "${profile}"; then
    printf '\n# Claude Code offline install\n%s\n' "${profile_line}" >> "${profile}"
  fi
done

echo "Installed: ${INSTALL_BIN_DIR}/claude"
echo "Run this in the current shell if needed:"
echo "  export PATH=\"${INSTALL_BIN_DIR}:\$PATH\""
echo "Verify:"
echo "  claude --version"

if ! command -v npm >/dev/null 2>&1 && [[ -f "${NODE_TARBALL}" ]]; then
  echo
  echo "npm is not currently on PATH. Optional Node/npm runtime is bundled at:"
  echo "  ${NODE_TARBALL}"
  echo "Native Claude Code installed above does not require npm at runtime."
fi
