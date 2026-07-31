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

if [[ ! -f "$project_path/kai.roc" ]]; then
  printf 'project config does not exist: %s/kai.roc\n' "$project_arg" >&2
  exit 1
fi
project_dir="$(cd "$project_path" && pwd -P)"

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

cat >"$workspace/Main.roc" <<ROC
app [config, module_changes] {
	kai: platform "./platform/main.roc",
}

import kai.Kai
import kai.Command
import KaiProject

config = KaiProject.config

module_changes : List(Kai.CommandChange)
module_changes = []

expect {
	registry = Kai.registry(Kai.config(config), module_changes)?
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
