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
