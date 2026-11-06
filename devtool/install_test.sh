#!/bin/sh
# Tests install.sh without the network: zig build check runs it.
set -eu

script=${1:-install.sh}
fail() {
  printf 'install_test: %s\n' "$*" >&2
  exit 1
}

# A download cut short at any line runs nothing: given --help, no prefix of
# the script prints the usage, which the whole script does.
lines=$(wc -l <"$script")
i=1
while [ "$i" -lt "$lines" ]; do
  output=$(head -n "$i" "$script" | sh -s -- --help 2>/dev/null) || true
  [ -z "$output" ] || fail "the first $i lines of $script run: $output"
  i=$((i + 1))
done
sh "$script" --help | grep -q '^Usage: install.sh' ||
  fail "$script --help does not print its usage"

# An install from a release, served from a directory by a stand-in curl, on
# a PATH with only the programs the script names; sed is not among them.
work=$(mktemp -d)
shell=$(command -v sh)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/release" "$work/kai"
for tool in uname mktemp rm cut tar gzip mkdir cp chmod mv grep cat sha256sum; do
  ln -s "$(command -v "$tool")" "$work/bin/$tool"
done
cat >"$work/bin/curl" <<'CURL'
#!/bin/sh
while [ $# -gt 1 ]; do
  [ "$1" = -o ] && out=$2
  shift
done
cat "$KAI_TEST_RELEASE/${1##*/}" >"$out"
CURL
printf '#!/bin/sh\necho flakes\n' >"$work/bin/nix"
printf '#!/bin/sh\necho kai 9.9.9\n' >"$work/kai/kai"
chmod +x "$work/bin/curl" "$work/bin/nix" "$work/kai/kai"
system=$(uname -m)-linux
[ "$(uname -s)" = Linux ] || system=$(uname -m)-darwin
archive=kai-9.9.9-$system.tar.gz
tar -czf "$work/release/$archive" -C "$work/kai" kai
{
  printf '%s  %s\n' "$(sha256sum "$work/release/$archive" | cut -d ' ' -f 1)" "$archive"
  # The last line has no newline.
  printf '%064d  kai-9.9.9-riscv64-linux.tar.gz' 0
} >"$work/release/SHA256SUMS"
installed=$(KAI_TEST_RELEASE=$work/release PATH=$work/bin \
  "$shell" "$script" --version 9.9.9 --dir "$work/out" 2>&1) ||
  fail "installing from a release fails: $installed"
[ "$("$work/out/kai")" = "kai 9.9.9" ] || fail "kai is not installed"

# A release with no build for this system names those it has.
grep -v "$system" "$work/release/SHA256SUMS" >"$work/sums" || true
mv "$work/sums" "$work/release/SHA256SUMS"
missing=$(KAI_TEST_RELEASE=$work/release PATH=$work/bin \
  "$shell" "$script" --version 9.9.9 --dir "$work/out" 2>&1) &&
  fail "installing a release with no $system build succeeds"
case $missing in
*"has no kai for $system; it supports: riscv64-linux") ;;
*) fail "a release with no $system build says: $missing" ;;
esac

# A missing program is named.
rm "$work/bin/tar"
missing=$(PATH=$work/bin "$shell" "$script" --dir "$work/out" 2>&1) &&
  fail "installing without tar succeeds"
case $missing in
*"needs tar, which is not on PATH") ;;
*) fail "installing without tar says: $missing" ;;
esac
