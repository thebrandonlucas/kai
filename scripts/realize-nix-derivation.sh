#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 ARTIFACT_DIR" >&2
}

if (($# != 1)); then
  usage
  exit 2
fi

artifact_dir=$1
for file in format root.drv derivations.json store.export; do
  if [[ ! -s "$artifact_dir/$file" ]]; then
    echo "error: artifact file is missing or empty: $artifact_dir/$file" >&2
    exit 1
  fi
done

if [[ "$(<"$artifact_dir/format")" != 'kai-nix-derivation-v1' ]]; then
  echo "error: unsupported artifact format: $artifact_dir/format" >&2
  exit 1
fi

roots=()
while IFS= read -r root || [[ -n "$root" ]]; do
  roots[${#roots[@]}]=$root
done <"$artifact_dir/root.drv"
if ((${#roots[@]} != 1)) || [[ -z "${roots[0]}" || "${roots[0]}" != /*.drv ]]; then
  echo "error: artifact must contain exactly one derivation root" >&2
  exit 1
fi
root=${roots[0]}

# Import is only needed after GC or transfer. Skipping it when the root is
# already valid also avoids unsigned-import restrictions in multi-user stores.
if ! nix-store --check-validity "$root" >/dev/null 2>&1; then
  nix-store --import <"$artifact_dir/store.export" >/dev/null
  nix-store --check-validity "$root"
fi

nix-store --realise "$root"
