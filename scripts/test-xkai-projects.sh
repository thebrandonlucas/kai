#!/usr/bin/env bash
set -euo pipefail

repo_root=$(pwd -P)
xkai="$repo_root/$1"
plugin="$repo_root/examples/custom-plugin/CustomPlugin.roc"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir "$work_dir/bin" "$work_dir/tmp"
cat >"$work_dir/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${KAI_BACKEND_LOG:?}"
EOF
chmod +x "$work_dir/bin/nix"
cp "$repo_root/examples/custom-plugin/config.kai" "$work_dir/config.kai"
cat >>"$work_dir/config.kai" <<'EOF'
on linux {
  shell {
    pkgs: ["roc"]
  }
}
on macos {
  shell {
    pkgs: ["roc"]
  }
}
EOF

export KAI_BACKEND_LOG="$work_dir/backend.log"
export PATH="$work_dir/bin:$PATH"
export TMPDIR="$work_dir/tmp"

cd "$work_dir"
cat >InvalidPlugin.roc <<'EOF'
plugin = 1 + "invalid"
EOF
if "$xkai" build "$work_dir/InvalidPlugin.roc" >build-error.log 2>&1; then
  echo 'expected invalid plugin build to fail' >&2
  exit 1
fi
test ! -e kai
test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"

"$xkai" build "$plugin"

test -x kai
test ! -e .kai
test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"

./kai custom-write
# Input custom message -> expected file contents: "custom plugin worked"
test "$(<custom-plugin-output.txt)" = 'custom plugin worked'
test ! -s "$KAI_BACKEND_LOG"

./kai shell
# Expected backend command: "develop path:.kai#default"
grep -Fxq 'develop path:.kai#default' "$KAI_BACKEND_LOG"
# Input package "roc" -> expected generated flake fragment: ."roc"
grep -Fq '."roc"' .kai/flake.nix
test "$(find .kai -type f | wc -l)" -eq 1
