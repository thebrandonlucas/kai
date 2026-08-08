#!/usr/bin/env bash
set -euo pipefail

repo_root=$(pwd -P)
xkai="$repo_root/$1"
plugin="$repo_root/examples/custom-plugin/CustomPlugin.roc"
modular="$repo_root/examples/modular-plugin"
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
expect_build_failure() {
  rm -f kai
  if "$xkai" build "$@" >build-error.log 2>&1; then
    echo 'expected plugin build to fail' >&2
    exit 1
  fi
  test ! -e kai
  test -z "$(find . -maxdepth 1 -name '.xkai-output-*' -print -quit)"
  test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"
}

printf '%s\n' 'plugin = 1 + "invalid"' >InvalidPlugin.roc
printf '%s\n' 'not a plugin' >NotPlugin.txt
ln -s "$modular/Plugin.roc" LinkedPlugin.roc
ln -s "$modular" linked-root
mkdir linked-tree manifest-tree unreadable-tree
cp "$modular/Plugin.roc" linked-tree/Plugin.roc
ln -s "$modular/commands" linked-tree/commands
cp "$modular/Plugin.roc" manifest-tree/Plugin.roc
mkdir manifest-tree/commands
printf '%s\n' 'package [] {}' >manifest-tree/commands/main.roc
cp "$modular/Plugin.roc" unreadable-tree/Plugin.roc
mkdir unreadable-tree/commands
cp "$modular/commands/Write.roc" unreadable-tree/commands/Write.roc
chmod 000 unreadable-tree/commands/Write.roc
expect_build_failure InvalidPlugin.roc
expect_build_failure NotPlugin.txt
grep -Fq 'plugin top-level path must end in .roc' build-error.log
expect_build_failure LinkedPlugin.roc
expect_build_failure linked-root/Plugin.roc
expect_build_failure "$modular/../modular-plugin/Plugin.roc"
expect_build_failure linked-tree/Plugin.roc
expect_build_failure manifest-tree/Plugin.roc
grep -Fq 'main.roc is reserved' build-error.log
expect_build_failure unreadable-tree/Plugin.roc

cp -R "$modular" modular-a
cp -R "$modular" modular-b
mkdir modular-a/commands/helpers
printf '%s\n' 'Name := [].{ value = "modular-write" }' >modular-a/commands/helpers/Name.roc
sed -i 's/import kai.Plugin as PluginApi/import kai.Plugin as PluginApi\nimport helpers.Name/; s/name: "modular-write"/name: Name.value/' modular-a/commands/Write.roc
mv modular-b/Plugin.roc modular-b/PluginTwo.roc
sed -i 's/Plugin :=/PluginTwo :=/; s/Plugin.definition/PluginTwo.definition/' modular-b/PluginTwo.roc
"$xkai" build modular-a/Plugin.roc modular-b/PluginTwo.roc
test -x kai
test ! -e .kai
test -z "$(find . -maxdepth 1 -name '.xkai-output-*' -print -quit)"
test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"
rm kai

"$xkai" build "$plugin"

test -x kai
test ! -e .kai
test -z "$(find . -maxdepth 1 -name '.xkai-output-*' -print -quit)"
test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"

./kai custom-write
test "$(<custom-plugin-output.txt)" = 'custom plugin worked'
test ! -s "$KAI_BACKEND_LOG"

./kai shell
grep -Fxq 'develop path:.kai#default' "$KAI_BACKEND_LOG"
grep -Fq '."roc"' .kai/flake.nix
test "$(find .kai -type f | wc -l)" -eq 1
