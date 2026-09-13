#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_rev=$(git -C "$repo_root" rev-parse HEAD)
source_url="git+file://$repo_root?rev=$source_rev"
workspace=$(mktemp -d -t kai-installer-smoke.XXXXXXXX)
qemu_pid=

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  if [[ -n "$qemu_pid" ]]; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  rm -rf "$workspace"
}
trap cleanup EXIT

: "${KAI_OVMF_CODE:?run inside the Kai Nix development shell}"
: "${KAI_OVMF_VARS:?run inside the Kai Nix development shell}"

cat > "$workspace/Kaifile" <<EOF
environment smoke {
  packages: ["kai"]
  overlays: ["$source_url"]
}

machine smoke {
  environment: smoke
  system: "x86_64-linux"
  users: ["kai"]
  bootloader: "limine"
  storage: "single-disk"
}
EOF
cp "$repo_root/Kaifile.lock" "$workspace/Kaifile.lock"

nix build "$source_url#kai" --out-link "$workspace/kai"
(
  cd "$workspace"
  "$workspace/kai/bin/kai" installer smoke
)

iso="$workspace/.kai/artifacts/installers/smoke/result/iso/smoke.iso"
test -f "$iso"
qemu-img create -q -f qcow2 "$workspace/disk.qcow2" 20G
cp "$KAI_OVMF_VARS" "$workspace/OVMF_VARS.fd"
chmod u+w "$workspace/OVMF_VARS.fd"
mkfifo "$workspace/serial.in"
exec 3<> "$workspace/serial.in"

qemu-system-x86_64 \
  -machine q35,accel=tcg \
  -m 2048 \
  -drive "if=pflash,format=raw,readonly=on,file=$KAI_OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$workspace/OVMF_VARS.fd" \
  -drive "file=$workspace/disk.qcow2,format=qcow2,if=virtio" \
  -drive "file=$iso,media=cdrom,readonly=on" \
  -boot once=d \
  -display none \
  -serial stdio \
  -nic none \
  -no-reboot <&3 > "$workspace/serial.log" 2>&1 &
qemu_pid=$!
sleep 5
printf t >&3
sleep 2
printf '\r' >&3

for _ in $(seq 1 180); do
  if grep -q KAI_INSTALLER_READY "$workspace/serial.log" 2>/dev/null; then
    printf 'installer ISO reached the guided installer\n'
    exit 0
  fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    printf 'QEMU exited before the installer became ready\n' >&2
    cat "$workspace/serial.log" >&2
    exit 1
  fi
  sleep 1
done

printf 'timed out waiting for the guided installer\n' >&2
cat "$workspace/serial.log" >&2
exit 1
