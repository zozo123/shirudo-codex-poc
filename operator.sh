#!/usr/bin/env bash
set -euo pipefail
cd /home/user/shirudo
readonly VM=npm-publish-lab
readonly DIR=build/npm-publish-lab
readonly SHARE=/workspace/shirudo/build/npm-publish-lab
readonly KEYS=/home/user/shirudo-npm-private/operator-keys/keys
readonly OWN=build/test-vm/host-bundle-npm-publish/fixtures/own.der
readonly RESULT="build/test-vm/vms/$VM/result"

guest() { make -s -C testing vm-ssh VM_NAME="$VM" "VM_SSH_COMMAND=$1"; }
lab() { guest "bash $SHARE/guest.sh $1"; }
runtime() { guest "shirudo-runtime $1"; }

operator_env() {
  . build/vm-toolchain.env
  export SHIRUDO_BUILD="$PWD/tools/shirudo-build/shirudo-build"
  sudo prlimit --pid "$$" --memlock=unlimited:unlimited
}

digest() {
  ./shirudo upatch info --json "$DIR/$1.upatch" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["payload_sha256"])'
}

build_patch() {
  ./shirudo build "$DIR/registry-guard.bpf.c" --name "$1" \
    --keys-dir "$KEYS" --extra-cflags "-DLAB_UID=20001 -DLAB_IPV4=0x7f000001 -DLAB_PORT=$2" \
    -o "$DIR/$1.upatch"
  ./shirudo build --unload "$1" --keys-dir "$KEYS" \
    --payload-sha256 "$(digest "$1")" -o "$DIR/$1.unload.upatch"
}

evidence() {
  local nonce=$1 label=$2
  runtime "attest --nonce=$nonce --output=/mnt/shirudo-out/npm-lab-$label.json"
}

attest() {
  local label=$1
  shift
  local nonce expected ak
  nonce=$(openssl rand -hex 32)
  expected=$(./shirudo attest predict --cert="$KEYS/cert.der" --cert="$OWN" "$@" |
    awk '/^register_after_events:/ {print $2}')
  test -n "$expected"
  ak=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ak"]["name"])' "$RESULT/npm-lab-baseline.json")
  evidence "$nonce" "$label"
  ./shirudo attest verify --evidence="$RESULT/npm-lab-$label.json" \
    --nonce="$nonce" --ak-name="$ak" --expect-chain="$expected" | tail -8
}

case "${1:-}" in
  prepare)
    operator_env
    lab setup
    echo 'Negative-control listener before Shirudo (same worker UID):'
    lab witness
    evidence "$(openssl rand -hex 32)" baseline
    build_patch npm-lab-guard 4873
    # The second upatch intersects with the first. There is no allowed
    # shared endpoint while both are loaded.
    build_patch npm-lab-hold 1
    runtime "upatch load $SHARE/npm-lab-guard.upatch"
    echo 'Same listener after Shirudo (worker must receive EACCES):'
    if response=$(lab witness 2>&1); then
      printf '%s\n' "$response" >&2
      exit 1
    fi
    printf '%s\n' "$response"
    [[ "$response" == *'"errno": "EACCES"'* ]]
    echo 'Trusted control still reaches the witness listener:'
    lab witness-root
    lab inspect
    attest guard "--event=load:npm-lab-guard=$(digest npm-lab-guard)"
    ;;
  inject)
    operator_env
    runtime "upatch load $SHARE/npm-lab-hold.upatch"
    attest hold "--event=load:npm-lab-guard=$(digest npm-lab-guard)" \
      "--event=load:npm-lab-hold=$(digest npm-lab-hold)"
    ;;
  rollback)
    operator_env
    runtime "upatch unload $SHARE/npm-lab-hold.unload.upatch"
    attest restored "--event=load:npm-lab-guard=$(digest npm-lab-guard)" \
      "--event=load:npm-lab-hold=$(digest npm-lab-hold)" \
      "--event=unload:npm-lab-hold=$(digest npm-lab-hold)"
    lab inspect
    ;;
  inspect|publish|view|install|state|audit|reset-registry) lab "$1" ;;
  *) echo "Unknown operator action" >&2; exit 2 ;;
esac
