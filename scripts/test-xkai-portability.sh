#!/usr/bin/env bash
# e2e test for testing that
# xkai is not dependent on source files
# being colocated with it.
set -euo pipefail

repo_root=$(pwd -P)
source_version="$repo_root/xkai-bin/VERSION"
xkai="$repo_root/$1"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

cp "$xkai" "$work_dir/xkai"
cd "$work_dir"
./xkai build

test -x kai
test -f .kai/Executor.roc
test -f .kai/package.roc
test -f .kai/Plugin.roc
test -f .kai/VERSION
cmp -s "$source_version" .kai/VERSION
grep -Fq 'kai: "./package.roc"' .kai/cli.roc
