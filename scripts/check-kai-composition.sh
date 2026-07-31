#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

if (($# < 2 || $# > 3)); then
  printf '%s\n' \
    'usage: check-kai-composition.sh <project-dir> <expected-shell-id> [build-output]' >&2
  exit 1
fi

caller_dir="$(pwd -P)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root_dir="$(cd "$script_dir/.." && pwd -P)"
project_arg="$1"
expected_shell_id="$2"
build_output_arg="${3:-}"

case "$expected_shell_id" in
"" | *[!A-Za-z0-9._-]*)
  printf '%s\n' 'invalid expected shell implementation id' >&2
  exit 1
  ;;
esac

case "$project_arg" in
/*) project_path="$project_arg" ;;
*) project_path="$caller_dir/$project_arg" ;;
esac

if [[ ! -d "$project_path" ]]; then
  printf 'project directory does not exist: %s\n' "$project_arg" >&2
  exit 1
fi
project_dir="$(cd "$project_path" && pwd -P)"

if [[ ! -f "$project_dir/kai.roc" ]]; then
  printf 'project config does not exist: %s/kai.roc\n' "$project_dir" >&2
  exit 1
fi

build_output=""
if [[ -n "$build_output_arg" ]]; then
  case "$build_output_arg" in
  /*) build_output_path="$build_output_arg" ;;
  *) build_output_path="$caller_dir/$build_output_arg" ;;
  esac

  build_output_parent="$(dirname "$build_output_path")"
  mkdir -p "$build_output_parent"
  build_output_parent="$(cd "$build_output_parent" && pwd -P)"
  build_output="$build_output_parent/$(basename "$build_output_path")"
fi

workspace="$(mktemp -d)"
cleanup() {
  rm -rf "$workspace"
}
trap cleanup EXIT

ln -s "$root_dir/platform" "$workspace/platform"
cp "$project_dir/kai.roc" "$workspace/KaiProject.roc"

has_manifest=false
if [[ -f "$project_dir/kai.modules.roc" ]]; then
  has_manifest=true
  cp "$project_dir/kai.modules.roc" "$workspace/KaiModules.roc"

  declare -A staged_basenames=(
    ["Main.roc"]=1
    ["KaiProject.roc"]=1
    ["KaiModules.roc"]=1
  )

  shopt -s nullglob
  command_modules=("$project_dir"/commands/*.roc)
  shopt -u nullglob

  for module_path in "${command_modules[@]}"; do
    module_basename="$(basename "$module_path")"
    if [[ -n "${staged_basenames[$module_basename]:-}" ]]; then
      printf 'duplicate or reserved command module basename: %s\n' \
        "$module_basename" >&2
      exit 1
    fi
    staged_basenames[$module_basename]=1
    cp "$module_path" "$workspace/$module_basename"
  done
fi

cat >"$workspace/Main.roc" <<'ROC'
app [config, module_changes] {
	kai: platform "./platform/main.roc",
}

import kai.Kai
import kai.Command
import KaiProject
ROC

if [[ "$has_manifest" == true ]]; then
  cat >>"$workspace/Main.roc" <<'ROC'
import KaiModules

config = KaiProject.config
module_changes = KaiModules.changes(KaiProject.config)
ROC
else
  cat >>"$workspace/Main.roc" <<'ROC'

config = KaiProject.config

module_changes : List(Kai.CommandChange)
module_changes = []
ROC
fi

cat >>"$workspace/Main.roc" <<ROC

expect {
	normalized_config = Kai.config(config)
	registry = Kai.registry(normalized_config, module_changes)?
	selected = Command.select(
		registry,
		"shell",
		Command.Backend.Nix,
	)?

	selected.id == "$expected_shell_id"
}
ROC

(
  cd "$workspace"
  roc check Main.roc
  roc test Main.roc

  if [[ -n "$build_output" ]]; then
    roc build Main.roc --output="$build_output"
  fi
)
