#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 INSTALLABLE ARTIFACT_DIR" >&2
}

if (($# != 2)); then
  usage
  exit 2
fi

installable=$1
artifact_dir=$2

if [[ -z "$installable" || -z "$artifact_dir" ]]; then
  usage
  exit 2
fi

if [[ -e "$artifact_dir" || -L "$artifact_dir" ]]; then
  echo "error: artifact already exists: $artifact_dir" >&2
  exit 1
fi

artifact_parent=$(dirname -- "$artifact_dir")
artifact_name=$(basename -- "$artifact_dir")
mkdir -p "$artifact_parent"

staging_dir=$(mktemp -d "$artifact_parent/.${artifact_name}.tmp.XXXXXX")
cleanup() {
  if [[ -n "${staging_dir:-}" && -d "$staging_dir" ]]; then
    rm -rf "$staging_dir"
  fi
}
trap cleanup EXIT

# This is the only command that receives the installable. Everything after it
# operates on the resulting store derivation path.
root=$(nix path-info --derivation "$installable")
if [[ -z "$root" || "$root" == *$'\n'* || "$root" != /*.drv ]]; then
  echo "error: installable must resolve to exactly one derivation" >&2
  exit 1
fi

printf '%s\n' 'kai-nix-derivation-v1' >"$staging_dir/format"
printf '%s\n' "$root" >"$staging_dir/root.drv"
nix derivation show --recursive "$root" >"$staging_dir/derivations.json"

closure_output=$(nix-store --query --requisites "$root")
if [[ -z "$closure_output" ]]; then
  echo "error: derivation closure is empty: $root" >&2
  exit 1
fi
closure=()
while IFS= read -r path || [[ -n "$path" ]]; do
  closure[${#closure[@]}]=$path
done <<<"$closure_output"

root_found=false
for path in "${closure[@]}"; do
  if [[ "$path" == "$root" ]]; then
    root_found=true
    break
  fi
done
if [[ "$root_found" != true ]]; then
  echo "error: derivation closure does not contain its root: $root" >&2
  exit 1
fi

nix-store --export "${closure[@]}" >"$staging_dir/store.export"

mv -- "$staging_dir" "$artifact_dir"
staging_dir=
trap - EXIT

printf 'imported %s\nartifact: %s\n' "$root" "$artifact_dir"
