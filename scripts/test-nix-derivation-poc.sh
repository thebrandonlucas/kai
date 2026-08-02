#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
import_script="$root_dir/scripts/import-nix-derivation.sh"
realize_script="$root_dir/scripts/realize-nix-derivation.sh"
real_nix=$(command -v nix)
real_nix_store=$(command -v nix-store)

if [[ $(uname -s) != Linux ]]; then
  echo "SKIP: real isolated-store transfer test requires Linux"
  exit 0
fi

case $(uname -m) in
x86_64) zig_target=x86_64-linux-musl ;;
aarch64) zig_target=aarch64-linux-musl ;;
*)
  echo "SKIP: unsupported test architecture: $(uname -m)"
  exit 0
  ;;
esac

work_dir=$(mktemp -d)
cleanup() {
  chmod -R u+w "$work_dir" 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$work_dir/bin" "$work_dir/source"

cat >"$work_dir/builder.c" <<'EOF'
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
  const char *out = getenv("out");
  const char message[] = "persisted-without-evaluation\n";
  int fd = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0666);

  if (fd < 0) return 1;
  if (write(fd, message, sizeof(message) - 1) != sizeof(message) - 1) return 2;
  return close(fd) != 0;
}
EOF

zig cc \
  -target "$zig_target" \
  -static \
  -Os \
  "$work_dir/builder.c" \
  -o "$work_dir/builder"
builder_store=$(nix-store --add "$work_dir/builder")
system=$(nix eval --impure --raw --expr builtins.currentSystem)
token=${work_dir##*.}

cat >"$work_dir/source/flake.nix" <<EOF
{
  inputs.builder = {
    url = "path:$builder_store";
    flake = false;
  };
  outputs = { self, builder }: {
    packages."$system".default = derivation {
      name = "kai-persisted-$token";
      system = "$system";
      builder = "\${builder}";
    };
  };
}
EOF

cat >"$work_dir/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$1" >>"$NIX_COMMAND_LOG"
printf ' %q' "${@:2}" >>"$NIX_COMMAND_LOG"
printf '\n' >>"$NIX_COMMAND_LOG"
exec "$REAL_NIX" "$@"
EOF
chmod +x "$work_dir/bin/nix"
ln -s "$real_nix_store" "$work_dir/bin/nix-store"

export NIX_COMMAND_LOG="$work_dir/nix-commands.log"
export REAL_NIX="$real_nix"
installable="path:$work_dir/source"
PATH="$work_dir/bin:$PATH" \
  "$import_script" "$installable" "$work_dir/artifact" >/dev/null

if [[ $(grep -F -c -- "$installable" "$NIX_COMMAND_LOG") != 1 ]]; then
  echo "error: import did not receive the installable exactly once" >&2
  exit 1
fi

root=$(<"$work_dir/artifact/root.drv")
grep -F "path-info --derivation $installable" "$NIX_COMMAND_LOG" >/dev/null
grep -F "derivation show --recursive $root" "$NIX_COMMAND_LOG" >/dev/null
grep -F "\"$(basename "$root")\"" \
  "$work_dir/artifact/derivations.json" >/dev/null
[[ -s "$work_dir/artifact/store.export" ]]

rm -rf "$work_dir/source" "$work_dir/builder" "$work_dir/builder.c"
cat >"$work_dir/bin/nix" <<'EOF'
#!/usr/bin/env bash
: >"$NIX_EVAL_MARKER"
echo "error: realization invoked Nix evaluation" >&2
exit 99
EOF
chmod +x "$work_dir/bin/nix"

mkdir "$work_dir/store-root"
realize_nix_config='substituters ='
effective_substituters=$(
  NIX_CONFIG="$realize_nix_config" \
    NIX_REMOTE="$work_dir/store-root" \
    "$real_nix" config show substituters
)
if [[ -n "$effective_substituters" ]]; then
  echo "error: isolated store still has substituters: $effective_substituters" >&2
  exit 1
fi

output=$(
  NIX_CONFIG="$realize_nix_config" \
    NIX_EVAL_MARKER="$work_dir/evaluation-invoked" \
    NIX_REMOTE="$work_dir/store-root" \
    PATH="$work_dir/bin:$PATH" \
    "$realize_script" "$work_dir/artifact"
)

if [[ -e "$work_dir/evaluation-invoked" ]]; then
  echo "error: realization invoked the poisoned nix executable" >&2
  exit 1
fi

if [[ "$(<"$work_dir/store-root$output")" != 'persisted-without-evaluation' ]]; then
  echo "error: persisted derivation produced unexpected output" >&2
  exit 1
fi

printf 'PASS: imported once and realized %s without evaluation\n' "$root"
