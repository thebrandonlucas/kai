#!/usr/bin/env bash
set -euo pipefail

repo_root=$(pwd -P)
xkai="$repo_root/$1"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir "$work_dir/source"
cp -R \
  "$repo_root/examples" \
  "$repo_root/platform" \
  "$repo_root/plugins" \
  "$repo_root/xkai-bin" \
  "$work_dir/source/"
cp "$repo_root/kai.roc" "$work_dir/source/kai.roc"
cp "$xkai" "$work_dir/xkai"

mkdir "$work_dir/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '{' \
  "  printf \"%s\" \"\${0##*/}\"" \
  "  printf \" %s\" \"\$@\"" \
  '  printf "\n"' \
  "} >>\"\${KAI_BACKEND_LOG:?}\"" \
  >"$work_dir/bin/backend"
chmod +x "$work_dir/bin/backend"
ln -s backend "$work_dir/bin/guix"
ln -s backend "$work_dir/bin/nix"

export KAI_BACKEND_LOG="$work_dir/backend.log"
export PATH="$work_dir/bin:$PATH"

run_kai() {
  local project_dir=$1
  local command=$2

  (
    cd "$work_dir/source/$project_dir"
    "$work_dir/xkai" build
    ./kai "$command"
  )
}

: >"$KAI_BACKEND_LOG"
run_kai . shell
grep -Fxq 'nix develop path:.kai#default' "$KAI_BACKEND_LOG"
grep -Fq 'nixpkgs."legacyPackages"."x86_64-linux"."roc"' \
  "$work_dir/source/.kai/flake.nix"

: >"$KAI_BACKEND_LOG"
run_kai examples/external-plugin external-write
test ! -s "$KAI_BACKEND_LOG"
test "$(<"$work_dir/source/examples/external-plugin/external-plugin-output.txt")" = \
  'external plugin worked'

: >"$KAI_BACKEND_LOG"
run_kai examples/kai-nix-cowsay shell
grep -Fxq 'nix develop path:.kai#default' "$KAI_BACKEND_LOG"
grep -Fq 'nixpkgs."legacyPackages"."x86_64-linux"."cowsay"' \
  "$work_dir/source/examples/kai-nix-cowsay/.kai/flake.nix"

: >"$KAI_BACKEND_LOG"
run_kai examples/guix-shell shell
grep -Fxq 'guix shell --manifest=.kai/manifest.scm' "$KAI_BACKEND_LOG"
grep -Fxq '(specifications->manifest (list "hello"))' \
  "$work_dir/source/examples/guix-shell/.kai/manifest.scm"
