#!/usr/bin/env bash
# Transfer a small source file via Boat's command API.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 BOAT_SANDBOX LOCAL_FILE REMOTE_FILE" >&2
  exit 2
fi

payload=$(base64 < "$2" | tr -d '\r\n')
boat exec "$1" --json --timeout 30 -- bash -c +  'set -euo pipefail; printf %s "$1" | base64 -d > "$2"' _ "$payload" "$3" |
  python3 -c 'import json, sys; result=json.load(sys.stdin); sys.exit(result["exitCode"])'
