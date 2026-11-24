#!/usr/bin/env bash
set -euo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
if [[ $# -lt 2 || $# -gt 3 || ( $1 != allowed && $1 != revoked ) || -z $2 ]]; then
  echo "Usage: $0 {allowed|revoked} BOAT_SANDBOX [RESULTS_DIRECTORY]" >&2
  exit 2
fi
CASE=$1
SANDBOX=$2
BOAT=${BOAT_BIN:-$(command -v boat)}
OUT=${3:-$BASE/results}
umask 077
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
TRACE="$OUT/$CASE-actions.jsonl"
test ! -e "$TRACE"
CWD=$(mktemp -d)
trap 'rmdir "$CWD"' EXIT
ARGS=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \
  "$BASE/lab-mcp.py" --boat "$BOAT" --sandbox "$SANDBOX" --case "$CASE" --trace "$TRACE")
codex -a never exec --ignore-user-config --ignore-rules --ephemeral \
  --skip-git-repo-check --sandbox read-only --disable shell_tool --json -C "$CWD" \
  -c 'mcp_servers.npm_lab.command="python3"' \
  -c "mcp_servers.npm_lab.args=$ARGS" \
  -c 'mcp_servers.npm_lab.required=true' \
  -c 'mcp_servers.npm_lab.tools.npm_action.approval_mode="approve"' \
  -c 'mcp_servers.npm_lab.tool_timeout_sec=280' \
  - < "$BASE/prompt.txt" | tee "$OUT/$CASE-codex.jsonl"
