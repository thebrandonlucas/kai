#!/usr/bin/env bash
###############
# Builds a bundle containing the kai config platform,
# ready for consumption and distribution by Roc apps.
# #############
set -euo pipefail
shopt -s nullglob

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform_dir="$root_dir/platform"
output_dir="$root_dir/dist"

mkdir -p "$output_dir"
rm -f "$output_dir"/*.tar.zst

cd "$platform_dir"

required_native_files=(
  targets/x64musl/crt1.o
  targets/x64musl/libc.a
  targets/x64musl/libhost.a
  targets/arm64musl/crt1.o
  targets/arm64musl/libc.a
  targets/arm64musl/libhost.a
  targets/x64mac/libhost.a
  targets/arm64mac/libhost.a
)

for file in "${required_native_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "error: required platform input is missing: $file" >&2
    exit 1
  fi
done

[[ -f main.roc ]] || {
  echo "error: platform/main.roc does not exist" >&2
  exit 1
}

roc_files=(main.roc)

for file in *.roc blueprint/*.roc; do
  [[ "$file" == main.roc ]] || roc_files+=("$file")
done

native_files=(
  targets/*/*.o
  targets/*/*.a
  targets/*/*.lib
)

license_files=(
  LICENSE
  blueprint/LICENSE
)

if ((${#native_files[@]} == 0)); then
  echo "error: no platform native files found" >&2
  exit 1
fi

echo "Bundling platform files:"
printf ' %s\n' \
  "${roc_files[@]}" \
  "${native_files[@]}" \
  "${license_files[@]}"

roc bundle \
  "${roc_files[@]}" \
  "${native_files[@]}" \
  "${license_files[@]}" \
  --output-dir "$output_dir"
