#!/usr/bin/env bash
###############
# Builds a self-contained Kai platform bundle,
# ready for consumption and distribution by Roc apps.
###############
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform_dir="$root_dir/platform"
api_dir="$root_dir/xkai-bin"
output_dir="$root_dir/dist"

# generic platform
platform_files=(
  main.roc
  Host.roc
  Kai.roc
  LICENSE
)

# xkai core library plugin
api_files=(
  package.roc
  Plugin.roc
)

# supported machines: x64 and arm linux and mac
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

# Ensure expected files present

for file in "${platform_files[@]}"; do
  if [[ ! -f "$platform_dir/$file" ]]; then
    echo "error: required platform input is missing: $file" >&2
    exit 1
  fi
done

for file in "${api_files[@]}"; do
  if [[ ! -f "$api_dir/$file" ]]; then
    echo "error: required API input is missing: xkai-bin/$file" >&2
    exit 1
  fi
done

for file in "${required_native_files[@]}"; do
  if [[ ! -f "$platform_dir/$file" ]]; then
    echo "error: required platform input is missing: $file" >&2
    exit 1
  fi
done

mapfile -t native_files < <(
  cd "$platform_dir"
  find targets -type f \
    \( -name '*.o' -o -name '*.a' -o -name '*.lib' \) \
    -print | LC_ALL=C sort
)

if ((${#native_files[@]} == 0)); then
  echo "error: no platform native files found" >&2
  exit 1
fi

# Roc's bundler requires the staging and output directories to share a root.
stage_dir="$(mktemp -d -p "$root_dir" .platform-bundle.XXXXXX)"
cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

for file in "${platform_files[@]}"; do
  cp "$platform_dir/$file" "$stage_dir/$file"
done

for file in "${api_files[@]}"; do
  cp "$api_dir/$file" "$stage_dir/$file"
done

for file in "${native_files[@]}"; do
  mkdir -p "$stage_dir/$(dirname "$file")"
  cp "$platform_dir/$file" "$stage_dir/$file"
done

if ! grep -Fq 'kai: "../xkai-bin/package.roc"' "$stage_dir/main.roc"; then
  echo "error: platform/main.roc does not contain the expected API package path" >&2
  exit 1
fi

sed -i \
  's#kai: "../xkai-bin/package\.roc"#kai: "./package.roc"#' \
  "$stage_dir/main.roc"

if ! grep -Fq 'kai: "./package.roc"' "$stage_dir/main.roc"; then
  echo "error: failed to rewrite the staged API package path" >&2
  exit 1
fi

bundle_files=(
  main.roc
  Host.roc
  Kai.roc
  package.roc
  Plugin.roc
  "${native_files[@]}"
  LICENSE
)

echo "Bundling platform files:"
printf ' %s\n' "${bundle_files[@]}"

mkdir -p "$output_dir"
rm -f "$output_dir"/*.tar.zst

(
  cd "$stage_dir"
  roc bundle \
    "${bundle_files[@]}" \
    --output-dir "$output_dir"
)
