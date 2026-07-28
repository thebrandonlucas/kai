#!/usr/bin/env bash

################
# Build release artifacts:
#
# - kai platform bundle,
#   can target arm/x64 linux and macos,
#   format: <HASH>.tar.zst
# - The kai platform, in the format <SHA256>.tar.zst
# - The kai CLI executable
# - x86_64 Linux Kai CLI archive
# - aarch64 Linux Kai CLI archive
# - SHA256SUMS for verification
#
# Also runs project and Nix checks, tests the native
# CLI archive, and smoke-tests the exact platform bundle.
###############
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 1
fi

cd "$root_dir"

project_version="$(
  awk -F'"' '/^[[:space:]]*\.version =/ { print $2; exit }' build.zig.zon
)"

if [[ "$version" != "$project_version" ]]; then
  echo "error: requested version $version does not match build.zig.zon $project_version" >&2
  exit 1
fi

rm -rf dist
mkdir -p dist

work_dir="$(mktemp -d -p "$root_dir" .release-build.XXXXXX)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

echo "Running project CI..."
zig build ci -Doptimize=ReleaseSafe

# Build the kai platform bundle
echo "Building platform bundle..."
zig build bundle -Doptimize=ReleaseSafe

mapfile -t bundles < <(
  find "$root_dir/dist" -maxdepth 1 -name '*.tar.zst' -print | sort
)

if ((${#bundles[@]} != 1)); then
  echo "error: expected one platform bundle, found ${#bundles[@]}" >&2
  exit 1
fi

bundle="${bundles[0]}"

# TODO: test building on macos
echo "Building Linux CLI archives through Nix..."

x64_archive_store="$(
  nix build \
    .#release-x86_64-linux \
    --no-link \
    --print-out-paths
)"

arm64_archive_store="$(
  nix build \
    .#release-aarch64-linux \
    --no-link \
    --print-out-paths
)"

x64_cli_archive="$root_dir/dist/kai-${version}-x86_64-linux.tar.gz"
arm64_cli_archive="$root_dir/dist/kai-${version}-aarch64-linux.tar.gz"

cp "$x64_archive_store" "$cli_archive"
cp "$arm64_archive_store" "$arm64_cli_archive"

echo "Checking packaged x86_64 Linux CLI..."
mkdir "$work_dir/x64-cli-test"
tar -xzf "$x64_cli_archive" -C "$work_dir/x64-cli-test"

if [[ "$("$work_dir/x64-cli-test/kai" version)" != "kai version $version" ]]; then
  echo "error: packaged x64 CLI is missing or not executable" >&2
  exit 1
fi

echo "Checking packaged aarch64 Linux CLI..."
mkdir "$work_dir/arm64-cli-test"
tar -xzf "$arm64_cli_archive" -C "$work_dir/arm64-cli-test"

if [[ ! -x "$work_dir/arm64-cli-test/kai" ]]; then
  echo "error: packaged aarch64 CLI is missing or not executable" >&2
  exit 1
fi

if ! file "$work_dir/arm64-cli-test/kai" | grep -F 'ARM aarch64' >/dev/null; then
  echo "error: packaged aarch64 CLI has the wrong architecture" >&2
  exit 1
fi

echo "Testing exact platform archive..."
mkdir "$work_dir/platform-test"

(
  cd "$work_dir/platform-test"
  roc unbundle "$bundle"
)

bundle_hash="$(basename "$bundle" .tar.zst)"
mkdir "$work_dir/platform-test/app"

# Test examples
sed \
  "s#../../platform/main\.roc#../${bundle_hash}/main.roc#" \
  examples/kai-nix-cowsay/main.roc \
  >"$work_dir/platform-test/app/main.roc"

roc build \
  "$work_dir/platform-test/app/main.roc" \
  --opt=dev \
  --output="$work_dir/platform-test/kai-config"

"$work_dir/platform-test/kai-config" \
  >"$work_dir/platform-test/generated.nix"

grep -F '"cowsay"' "$work_dir/platform-test/generated.nix" >/dev/null

echo "Generating checksums..."
(
  cd dist
  sha256sum \
    "$(basename "$bundle")" \
    "$(basename "$x64_cli_archive")" \
    "$(basename "$arm64_cli_archive")" \
    >SHA256SUMS
)

echo
echo "Release artifacts:"
find dist -maxdepth 1 -type f -printf '  %f\n' | sort
