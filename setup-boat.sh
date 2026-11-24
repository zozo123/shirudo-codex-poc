#!/usr/bin/env bash
# Run inside a fresh, disposable Boat VM. The upstream test setup changes
# host packages and kernel settings to build a dedicated nested test guest.
set -euo pipefail

readonly ROOT=/home/user/shirudo
readonly SHIRUDO_REV=1e81ff59107abbd811f05ab16bef5382c45b82d0
readonly LAB=build/npm-publish-lab

if [[ ! -e /dev/kvm ]]; then
  echo 'This Boat VM needs /dev/kvm to boot the Shirudo test guest.' >&2
  exit 1
fi

git clone https://github.com/shirudo-dev/shirudo.git "$ROOT"
cd "$ROOT"
git checkout --detach "$SHIRUDO_REV"
testing/vm/kernel-artifact.sh download
KERNEL_CI_ARTIFACT_DIR="$PWD/build/kernel-ci-artifact" .github/scripts/tests.sh setup

. build/vm-toolchain.env
export BPF_VMLINUX_BTF="$PWD/artifacts/bpf-next-kernel-debs/vmlinux.btf"
sudo prlimit --pid "$$" --memlock=unlimited:unlimited
make -j2
make shirudo-build

# Boat's default environment provides Node and npm, typically through nvm.
if ! command -v node >/dev/null && [[ -s $HOME/.nvm/nvm.sh ]]; then
  set +u
  . "$HOME/.nvm/nvm.sh"
  nvm use default
  set -u
fi
node_root=$(dirname "$(dirname "$(readlink -f "$(command -v node)")")")
npm_root=$(dirname "$(dirname "$(readlink -f "$(command -v npm)")")")
test -f "$npm_root/bin/npm-cli.js"
mkdir -p "$LAB/node/bin" "$LAB/node/lib/node_modules"
install -m 0755 "$node_root/bin/node" "$LAB/node/bin/node"
cp -a "$npm_root" "$LAB/node/lib/node_modules/npm"
ln -sfn ../lib/node_modules/npm/bin/npm-cli.js "$LAB/node/bin/npm"

make -C testing vm VM_NAME=npm-publish-lab LOCAL_STACK=0 TEST_VM_MEMORY=2G \
  TEST_VM_BUNDLE_DIR="$PWD/build/test-vm/host-bundle-npm-publish" \
  TEST_VM_HOST_PRIVATE_DIR=/home/user/shirudo-npm-private
