#!/usr/bin/env bash
# Temporary parity gate for the Bash and Roc release artifact builders.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if (($# != 1)); then
  echo "usage: $0 DEVTOOL" >&2
  exit 1
fi

devtool="$(realpath "$1")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/kai-release-parity.XXXXXX")"
bash_root="$work_dir/bash"
roc_root="$work_dir/roc"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

copy_source() {
  local destination="$1"
  mkdir -p "$destination"
  git -C "$root_dir" ls-files --cached --others --exclude-standard -z |
    while IFS= read -r -d '' path; do
      if [[ -e "$root_dir/$path" ]] || [[ -L "$root_dir/$path" ]]; then
        printf '%s\0' "$path"
      fi
    done |
    tar --directory="$root_dir" --create --file=- --null --files-from=- |
    tar --directory="$destination" --extract --file=-
  git -C "$destination" init --quiet --initial-branch=master
  git -C "$destination" add --all
  git -C "$destination" \
    -c user.name="Release Parity" \
    -c user.email="release-parity@example.invalid" \
    commit --quiet --no-gpg-sign --message="test: release builder parity"
}

show_failure() {
  local builder="$1"
  local log="$2"
  echo "$builder release build failed:" >&2
  cat "$log" >&2
  exit 1
}

assert_no_workspaces() {
  local source_root="$1"
  local leftovers
  leftovers="$(find "$source_root" -maxdepth 1 -type d -name '.release-build.*' -print)"
  if [[ -n "$leftovers" ]]; then
    fail "release builder left temporary workspaces: $leftovers"
  fi
}

validate_build() {
  local builder="$1"
  local source_root="$2"
  local version="$3"
  local dist="$source_root/dist"
  local x64="kai-${version}-x86_64-linux.tar.gz"
  local arm64="kai-${version}-aarch64-linux.tar.gz"
  local actual_inventory
  local expected_inventory
  local checksum_names
  local expected_checksum_names
  local extract_root="$work_dir/verify-$builder"

  actual_inventory="$(find "$dist" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)"
  expected_inventory="$(printf '%s\n' SHA256SUMS "$arm64" "$x64" | sort)"
  if [[ "$actual_inventory" != "$expected_inventory" ]]; then
    fail "$builder artifact inventory differs: $actual_inventory"
  fi
  for artifact in SHA256SUMS "$arm64" "$x64"; do
    if [[ ! -f "$dist/$artifact" ]] || [[ -L "$dist/$artifact" ]]; then
      fail "$builder artifact is not a regular file: $artifact"
    fi
  done

  if [[ "$(tar -tzf "$dist/$x64")" != "kai" ]] ||
    [[ "$(tar -tzf "$dist/$arm64")" != "kai" ]]; then
    fail "$builder archive contents differ"
  fi

  mkdir -p "$extract_root/x64" "$extract_root/arm64"
  tar -xzf "$dist/$x64" -C "$extract_root/x64"
  tar -xzf "$dist/$arm64" -C "$extract_root/arm64"
  if [[ ! -x "$extract_root/x64/kai" ]] || [[ ! -x "$extract_root/arm64/kai" ]]; then
    fail "$builder archive does not contain executable binaries"
  fi
  if [[ "$("$extract_root/x64/kai" version)" != "kai version $version" ]]; then
    fail "$builder x86_64 version output differs"
  fi
  if ! file "$extract_root/arm64/kai" | grep -F 'ARM aarch64' >/dev/null; then
    fail "$builder ARM64 architecture check differs"
  fi

  checksum_names="$(awk '{ print $2 }' "$dist/SHA256SUMS" | sort)"
  expected_checksum_names="$(printf '%s\n' "$arm64" "$x64" | sort)"
  if [[ "$checksum_names" != "$expected_checksum_names" ]]; then
    fail "$builder checksum inventory differs: $checksum_names"
  fi
  (cd "$dist" && sha256sum -c SHA256SUMS >/dev/null)
  assert_no_workspaces "$source_root"
}

copy_source "$bash_root"
copy_source "$roc_root"
version="$(<"$root_dir/xkai-bin/VERSION")"

if ! (cd "$bash_root" && ./scripts/build-release.sh) >"$work_dir/bash-success.log" 2>&1; then
  show_failure "Bash" "$work_dir/bash-success.log"
fi
if ! (cd "$roc_root" && "$devtool" build-release) >"$work_dir/roc-success.log" 2>&1; then
  show_failure "Roc" "$work_dir/roc-success.log"
fi

validate_build bash "$bash_root" "$version"
validate_build roc "$roc_root" "$version"
if ! cmp --silent "$bash_root/dist/SHA256SUMS" "$roc_root/dist/SHA256SUMS"; then
  fail "Bash and Roc checksum contents differ"
fi

fake_bin="$work_dir/fake-bin"
mkdir "$fake_bin"
cat >"$fake_bin/file" <<'EOF'
#!/usr/bin/env bash
printf '%s: ELF 64-bit LSB executable, x86-64\n' "${1:-binary}"
EOF
chmod +x "$fake_bin/file"

set +e
(cd "$bash_root" && PATH="$fake_bin:$PATH" ./scripts/build-release.sh) >"$work_dir/bash-failure.log" 2>&1
bash_status=$?
(cd "$roc_root" && PATH="$fake_bin:$PATH" "$devtool" build-release) >"$work_dir/roc-failure.log" 2>&1
roc_status=$?
set -e

if ((bash_status == 0 || roc_status == 0)); then
  echo "Bash failure status: $bash_status" >&2
  echo "Roc failure status: $roc_status" >&2
  fail "release builders did not both reject the wrong ARM64 architecture"
fi
assert_no_workspaces "$bash_root"
assert_no_workspaces "$roc_root"
if [[ -e "$roc_root/dist" ]]; then
  fail "Roc release builder retained partial dist output after failure"
fi

wrong_version_root="$work_dir/wrong-version"
wrong_version_archive="$work_dir/wrong-version-x64.tar.gz"
version_bin="$work_dir/version-bin"
real_nix="$(command -v nix)"
mkdir -p "$wrong_version_root" "$version_bin"
cat >"$wrong_version_root/kai" <<'EOF'
#!/usr/bin/env bash
echo "kai version 999.999.999"
EOF
chmod +x "$wrong_version_root/kai"
tar -czf "$wrong_version_archive" -C "$wrong_version_root" kai
cat >"$version_bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

release_x64=false
print_paths=false
for argument in "$@"; do
  case "$argument" in
    .#release-x86_64-linux) release_x64=true ;;
    --print-out-paths) print_paths=true ;;
  esac
done

if [[ "$release_x64" == true && "$print_paths" == true ]]; then
  printf '%s\n' "$WRONG_X64_ARCHIVE"
else
  exec "$REAL_NIX" "$@"
fi
EOF
chmod +x "$version_bin/nix"

set +e
(
  cd "$bash_root" &&
    PATH="$version_bin:$PATH" \
      REAL_NIX="$real_nix" \
      WRONG_X64_ARCHIVE="$wrong_version_archive" \
      ./scripts/build-release.sh
) >"$work_dir/bash-version-failure.log" 2>&1
bash_status=$?
(
  cd "$roc_root" &&
    PATH="$version_bin:$PATH" \
      REAL_NIX="$real_nix" \
      WRONG_X64_ARCHIVE="$wrong_version_archive" \
      "$devtool" build-release
) >"$work_dir/roc-version-failure.log" 2>&1
roc_status=$?
set -e

if ((bash_status == 0 || roc_status == 0)); then
  echo "Bash failure status: $bash_status" >&2
  echo "Roc failure status: $roc_status" >&2
  fail "release builders did not both reject wrong x86_64 version output"
fi
assert_no_workspaces "$bash_root"
assert_no_workspaces "$roc_root"
if [[ -e "$roc_root/dist" ]]; then
  fail "Roc release builder retained partial dist output after version failure"
fi

echo "Bash and Roc release builders have parity."
