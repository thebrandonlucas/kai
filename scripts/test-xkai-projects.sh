#!/usr/bin/env bash
set -euo pipefail

repo_root=$(pwd -P)
xkai="$repo_root/$1"
plugin="$repo_root/examples/custom-plugin/CustomPlugin.roc"
split_plugin="$repo_root/examples/split-plugin/Plugin.roc"
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
cat >CallbackPlugin.roc <<'EOF'
import kai.Plugin as PluginApi

CallbackPlugin := [].{
  plugin : PluginApi.Plugin
  plugin = PluginApi.Plugin.Module({
    definition: PluginApi.Definition.{
      backends: [],
      commands: [],
      implementations: [],
      name: "callback",
    },
    plan: |_, _, _, _| Err(UnknownCommand),
  })
}
EOF
if "$xkai" build "$work_dir/CallbackPlugin.roc" >build-error.log 2>&1; then
  echo 'expected callback plugin build to fail' >&2
  exit 1
fi
test ! -e kai
test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"
test -z "$(find . -maxdepth 1 -name '.xkai-kai-*' -print -quit)"

cat >InvalidRegistry.roc <<'EOF'
import kai.Plugin as PluginApi

InvalidRegistry := [].{
  plugin : PluginApi.RegistryDefinition
  plugin = {
    definition: PluginApi.Definition.{
      backends: [],
      commands: [],
      implementations: [],
      name: "invalid",
    },
    select_config: |_, _, _, _, _| Ok(Missing),
  }
}
EOF
printf 'existing output\n' >kai
if "$xkai" build "$work_dir/InvalidRegistry.roc" >validation-error.log 2>&1; then
  echo 'expected invalid registry validation to fail' >&2
  exit 1
fi
grep -Fq 'must define at least one command' validation-error.log
test "$(<kai)" = 'existing output'
rm kai
test ! -e kai
test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"
test -z "$(find . -maxdepth 1 -name '.xkai-kai-*' -print -quit)"

"$xkai" build "$plugin" "$split_plugin"

test -x kai
test ! -e .kai
test -z "$(find "$TMPDIR" -maxdepth 1 -name 'xkai-*' -print -quit)"
test -z "$(find . -maxdepth 1 -name '.xkai-kai-*' -print -quit)"

./kai custom-write
# Input custom message -> expected file contents: "custom plugin worked"
test "$(<custom-plugin-output.txt)" = 'custom plugin worked'
test ! -s "$KAI_BACKEND_LOG"

./kai split-command
# Expected split registry output: "split plugin worked"
test "$(<split-plugin-output.txt)" = 'split plugin worked'
test ! -s "$KAI_BACKEND_LOG"

./kai shell
# Expected backend command: "develop path:.kai#default"
grep -Fxq 'develop path:.kai#default' "$KAI_BACKEND_LOG"
# Input package "roc" -> expected generated flake fragment: ."roc"
grep -Fq '."roc"' .kai/flake.nix
test "$(find .kai -type f | wc -l)" -eq 1

rm custom-plugin-output.txt
cat >config.kai <<'EOF'
custom {
  message: []
}
EOF
if ./kai custom-write >invalid-config.log 2>&1; then
  echo 'expected invalid custom config to fail' >&2
  exit 1
fi
grep -Fq "field 'message' must be a string" invalid-config.log
test ! -e custom-plugin-output.txt
