#!/usr/bin/env bash
set -euo pipefail

if ! command -v unshare >/dev/null 2>&1; then
  echo "ERROR: unshare is required for child-process network isolation." >&2
  exit 127
fi

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude not found. Run install_claude_offline.sh first." >&2
  exit 127
fi

exec unshare -Urn env \
  PATH="${PATH}" \
  HOME="${HOME}" \
  USER="${USER:-}" \
  SHELL="${SHELL:-/bin/sh}" \
  DISABLE_AUTOUPDATER=1 \
  DISABLE_UPDATES=1 \
  DISABLE_TELEMETRY=1 \
  DISABLE_ERROR_REPORTING=1 \
  DISABLE_FEEDBACK_COMMAND=1 \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1 \
  CLAUDE_CODE_SIMPLE=1 \
  claude --bare "$@"
