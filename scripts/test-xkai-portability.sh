#!/usr/bin/env bash
set -euo pipefail

repo_root=$(pwd -P)
xkai="$repo_root/$1"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir "$work_dir/bin" "$work_dir/tmp"
cp "$xkai" "$work_dir/xkai"
cat >"$work_dir/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${KAI_BACKEND_LOG:?}"
EOF
chmod +x "$work_dir/bin/nix"

cat >"$work_dir/config.kai" <<'EOF'
on linux {
  shell {
    pkgs: ["cowsay"]
  }
}
on macos {
  shell {
    pkgs: ["cowsay"]
  }
}
EOF

export KAI_BACKEND_LOG="$work_dir/backend.log"
export PATH="$work_dir/bin:$PATH"
export TMPDIR="$work_dir/tmp"

cd "$work_dir"
./xkai build

test -x kai
test ! -e .kai
test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"
test -f config.kai
test -f kai
test -f xkai
test "$(find . -maxdepth 1 -type f | wc -l)" -eq 3

./kai shell
# Expected backend command: "develop path:.kai#default"
grep -Fxq 'develop path:.kai#default' "$KAI_BACKEND_LOG"
# Input package "cowsay" -> expected generated flake fragment: ."cowsay"
grep -Fq '."cowsay"' .kai/flake.nix
test "$(find .kai -type f | wc -l)" -eq 1
