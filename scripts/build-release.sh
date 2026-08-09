#!/usr/bin/env bash
# Build and validate the portable Linux kai CLI archives and their checksums.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$root_dir/xkai-bin/VERSION"

if (($# != 0)); then
  echo "usage: $0" >&2
  echo "error: the release version is read from xkai-bin/VERSION" >&2
  exit 1
fi

version="$(<"$version_file")"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "error: xkai-bin/VERSION must contain a semantic version (X.Y.Z)" >&2
  exit 1
fi

manifest_version="$(
  awk -F'"' '/^[[:space:]]*\.version =/ { print $2; exit }' "$root_dir/build.zig.zon"
)"
if [[ "$manifest_version" != "$version" ]]; then
  echo "error: build.zig.zon version $manifest_version does not match xkai-bin/VERSION $version" >&2
  exit 1
fi

cd "$root_dir"

rm -rf dist
mkdir -p dist

work_dir="$(mktemp -d -p "$root_dir" .release-build.XXXXXX)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

echo "Running project CI..."
zig build ci

echo "Checking Nix formatting..."
nix fmt -- --check flake.nix

echo "Running Nix flake checks..."
nix flake check

echo "Building portable Linux CLI archives through Nix..."
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
cp "$x64_archive_store" "$x64_cli_archive"
cp "$arm64_archive_store" "$arm64_cli_archive"

echo "Checking packaged x86_64 Linux CLI..."
mkdir "$work_dir/x64-cli-test"
tar -xzf "$x64_cli_archive" -C "$work_dir/x64-cli-test"
# Expected output: "kai version $version"
if [[ "$("$work_dir/x64-cli-test/kai" version)" != "kai version $version" ]]; then
  echo "error: packaged x86_64 CLI is missing or not executable" >&2
  exit 1
fi

echo "Checking packaged aarch64 Linux CLI..."
mkdir "$work_dir/arm64-cli-test"
tar -xzf "$arm64_cli_archive" -C "$work_dir/arm64-cli-test"
if [[ ! -x "$work_dir/arm64-cli-test/kai" ]]; then
  echo "error: packaged aarch64 CLI is missing or not executable" >&2
  exit 1
fi
# Expected file description to contain: "ARM aarch64"
if ! file "$work_dir/arm64-cli-test/kai" | grep -F 'ARM aarch64' >/dev/null; then
  echo "error: packaged aarch64 CLI has the wrong architecture" >&2
  exit 1
fi

echo "Generating checksums..."
(
  cd dist
  sha256sum \
    "$(basename "$x64_cli_archive")" \
    "$(basename "$arm64_cli_archive")" \
    >SHA256SUMS
  sha256sum -c SHA256SUMS
)

echo
echo "Release artifacts:"
find dist -maxdepth 1 -type f -print | sort | while IFS= read -r artifact; do
  printf '  %s\n' "${artifact##*/}"
done
