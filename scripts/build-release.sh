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
# Also runs project and Nix checks, validates both native
# CLI archives, and tests the exact x86_64 CLI and platform archives together.
###############
set -euo pipefail

# Get the current dir of the script so that
# we can switch back here later
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Get the version number we're bumping from
version_file="$root_dir/xkai-bin/VERSION"

if (($# != 0)); then
  echo "usage: $0" >&2
  echo "error: the release version is read from xkai-bin/VERSION" >&2
  exit 1
fi

# Validate version format is X.Y.Z
version="$(<"$version_file")"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "error: xkai-bin/VERSION must contain a semantic version (X.Y.Z)" >&2
  exit 1
fi

# pull the version out of build.zig.zon and check
# that it matches VERSION file
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

# make a /tmp working dir for the script run
work_dir="$(mktemp -d -p "$root_dir" .release-build.XXXXXX)"
cleanup() {
  rm -rf "$work_dir"
}
# cleanup the working dir at the end
trap cleanup EXIT

# Preliminary release requirement checks
echo "Running project CI..."
zig build ci -Doptimize=ReleaseSafe

echo "Checking Nix formatting..."
nix fmt -- --check flake.nix

echo "Running Nix flake checks..."
nix flake check

# Build the kai platform bundle
echo "Building platform bundle..."
zig build bundle -Doptimize=ReleaseSafe

# Number of bundles
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

# archive paths
x64_cli_archive="$root_dir/dist/kai-${version}-x86_64-linux.tar.gz"
arm64_cli_archive="$root_dir/dist/kai-${version}-aarch64-linux.tar.gz"

# copy the archives in tmp to the archive paths
cp "$x64_archive_store" "$x64_cli_archive"
cp "$arm64_archive_store" "$arm64_cli_archive"

# unbundle on this machine for smoke test
echo "Checking packaged x86_64 Linux CLI..."
mkdir "$work_dir/x64-cli-test"
tar -xzf "$x64_cli_archive" -C "$work_dir/x64-cli-test"

# ensures that we can run kai from an unzipped archive
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

# TODO: we probably want to generalize this to the machine
#       at some point instead of hardcoding
echo "Testing exact x86_64 CLI and platform archives..."
platform_test_dir="$work_dir/platform-test"
mkdir "$platform_test_dir"

(
  cd "$platform_test_dir"
  roc unbundle "$bundle"
)

bundle_hash="$(basename "$bundle" .tar.zst)"
bundle_dir="$platform_test_dir/$bundle_hash"
bundle_files=(
  main.roc
  Host.roc
  Kai.roc
  LICENSE
  package.roc
  Plugin.roc
  targets/x64musl/crt1.o
  targets/x64musl/libc.a
  targets/x64musl/libhost.a
  targets/arm64musl/crt1.o
  targets/arm64musl/libc.a
  targets/arm64musl/libhost.a
  targets/x64mac/libhost.a
  targets/arm64mac/libhost.a
)

for file in "${bundle_files[@]}"; do
  if [[ ! -f "$bundle_dir/$file" ]]; then
    echo "error: platform bundle is missing: $file" >&2
    exit 1
  fi
done

if ! grep -Fq 'kai: "./package.roc"' "$bundle_dir/main.roc"; then
  echo "error: bundled platform does not use its bundled API package" >&2
  exit 1
fi

# do a platform smoke test to check that the platform
# created from the associated kai binary works with it
cat >"$platform_test_dir/kai.roc" <<EOF
app [config] {
    kai: platform "./${bundle_hash}/main.roc",
}

config = [
    {
        implementation: {
            actions: [WriteConfigUtf8({ path: "smoke-output.txt" })],
            backend: { name: "file" },
            command: {
                argv: [],
                backends: [],
                name: "smoke",
            },
            requirement: None,
        },
        rendered_config: "release smoke test\\n",
    },
]
EOF

printf 'release smoke test\n' >"$platform_test_dir/expected-output.txt"

(
  cd "$platform_test_dir"
  "$work_dir/x64-cli-test/kai" smoke
)

# if ! cmp?
if ! cmp -s \
  "$platform_test_dir/expected-output.txt" \
  "$platform_test_dir/smoke-output.txt"; then
  echo "error: packaged x86_64 CLI did not write the expected output" >&2
  exit 1
fi

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
