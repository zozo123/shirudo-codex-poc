#!/usr/bin/env bash
set -euo pipefail

readonly LAB=/var/tmp/switchboard-npm
readonly SRC=/workspace/shirudo/build/npm-publish-lab
readonly NS=switchboard-npm
readonly ARTIFACT=switchboard-demo-linter@1.2.3
readonly ENDPOINT=http://127.0.0.1:4873/
readonly LAB_UID=20001
readonly LAB_GID=20001
readonly TOKEN_FILE=$LAB/private/registry-token

as_worker() {
  ip netns exec "$NS" setpriv --reuid "$LAB_UID" --regid "$LAB_GID" --clear-groups --no-new-privs \
    env -i "HOME=$LAB/home" "PATH=$SRC/node/bin:/usr/bin:/bin" LANG=C.UTF-8 "$@"
}

npm_in_lab() {
  as_worker npm --registry "$ENDPOINT" --fetch-retries=0 --fetch-timeout=5000 \
    --userconfig "$LAB/home/user.npmrc" --globalconfig "$LAB/home/global.npmrc" \
    --no-audit --no-fund --no-update-notifier "$@"
}

inside() {
  ip netns exec "$NS" env -i PATH=/usr/bin:/bin "$@"
}

start_registry() {
  nohup ip netns exec "$NS" python3 -u "$SRC/registry.py" serve \
    --bind 127.0.0.1 --port 4873 --token-file "$TOKEN_FILE" >"$LAB/registry.log" 2>&1 </dev/null &
  echo "$!" > "$LAB/registry.pid"
  for _ in {1..40}; do
    if inside curl -fsS --noproxy '*' --max-time 1 "${ENDPOINT}-/ping" >/dev/null 2>&1; then
      return 0
    fi
    sleep .1
  done
  cat "$LAB/registry.log" >&2
  return 1
}

reset_consumer() {
  rm -rf -- "$LAB/consumer/cache" "$LAB/consumer/node_modules" "$LAB/consumer/package-lock.json"
  printf '{"name":"switchboard-lab-consumer","version":"0.0.0","private":true}\n' > "$LAB/consumer/package.json"
  chown "$LAB_UID:$LAB_GID" "$LAB/consumer/package.json"
}

witness() {
  local -a invoke=(inside)
  if [[ $1 == worker ]]; then invoke=(as_worker); fi
  "${invoke[@]}" python3 -c '
import errno
import http.client
import json
conn = http.client.HTTPConnection("127.0.0.1", 4874, timeout=3)
try:
    conn.request("GET", "/")
    response = conn.getresponse()
    print(json.dumps({"target": "127.0.0.1:4874", "http": response.status}))
except OSError as exc:
    print(json.dumps({"target": "127.0.0.1:4874", "errno": errno.errorcode.get(exc.errno)}))
    raise SystemExit(13 if exc.errno == errno.EACCES else 1)
'
}

case "${1:-}" in
  setup)
    test ! -e "$LAB"
    if getent passwd "$LAB_UID" >/dev/null || getent group "$LAB_GID" >/dev/null; then
      echo "Dedicated lab UID or GID already in use" >&2
      exit 1
    fi
    groupadd --gid "$LAB_GID" switchboard-npm
    useradd --uid "$LAB_UID" --gid "$LAB_GID" --home-dir "$LAB/home" \
      --shell /usr/sbin/nologin --no-create-home switchboard-npm
    install -d "$LAB" "$LAB/witness"
    install -d -m 0700 "$LAB/private"
    install -d -o "$LAB_UID" -g "$LAB_GID" "$LAB/home" "$LAB/project" "$LAB/consumer"
    touch "$LAB/home/user.npmrc" "$LAB/home/global.npmrc"
    python3 "$SRC/registry.py" init "$LAB/project" --registry "$ENDPOINT" --token-file "$TOKEN_FILE"
    chown -R "$LAB_UID:$LAB_GID" "$LAB/home" "$LAB/project"
    install -m 0600 -o "$LAB_UID" -g "$LAB_GID" "$LAB/project/.npmrc" "$LAB/consumer/.npmrc"
    reset_consumer
    ip netns add "$NS"
    ip -n "$NS" link set lo up
    start_registry
    nohup ip netns exec "$NS" python3 -m http.server 4874 --bind 127.0.0.1 \
      --directory "$LAB/witness" >"$LAB/witness.log" 2>&1 </dev/null &
    echo "$!" > "$LAB/witness.pid"
    ready=0
    for _ in {1..40}; do
      if inside curl -fsS --noproxy '*' --max-time 1 http://127.0.0.1:4874/ >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep .1
    done
    test "$ready" -eq 1
    as_worker node --version
    as_worker npm --version
    ip -n "$NS" -br link
    test -z "$(ip -n "$NS" route show default)"
    test -z "$(ip -n "$NS" -6 route show default)"
    ;;
  inspect)
    cd "$LAB/project"
    as_worker node -e 'let p=require("./package.json"); console.log(p.name+"@"+p.version, p.publishConfig.registry)'
    npm_in_lab ping
    ;;
  publish)
    cd "$LAB/project"
    npm_in_lab publish --ignore-scripts
    ;;
  view)
    cd "$LAB/consumer"
    npm_in_lab view "$ARTIFACT" version --prefer-online
    ;;
  install)
    cd "$LAB/consumer"
    npm_in_lab --cache "$LAB/consumer/cache" install --ignore-scripts --save-exact "$ARTIFACT"
    as_worker node -e 'const x=require("switchboard-demo-linter"); if (!x("fixture ")) process.exit(2); console.log("Installed fixture smoke check: PASS")'
    ;;
  state) inside curl -fsS --noproxy '*' "${ENDPOINT}_lab/state"; printf '\n' ;;
  audit) cat "$LAB/registry.log" ;;
  witness) witness worker ;;
  witness-root) witness root ;;
  reset-registry)
    # The namespace and servers belong only to this disposable guest.
    kill "$(cat "$LAB/registry.pid")"
    for _ in {1..40}; do
      if ! inside curl -fsS --noproxy '*' --max-time 1 "${ENDPOINT}-/ping" >/dev/null 2>&1; then
        break
      fi
      sleep .1
    done
    reset_consumer
    start_registry
    ;;
  *) printf 'Unknown lab action\n' >&2; exit 2 ;;
esac
