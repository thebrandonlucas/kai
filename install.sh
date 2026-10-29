#!/bin/sh
# Installs kai from a GitHub release:
#
#   curl -fsSL https://github.com/thebrandonlucas/kai/releases/latest/download/install.sh | sh
#
# Pass options after `sh -s --`; see `--help`. Kai needs Nix (or Guix): when
# neither is on PATH this offers to install Nix, and only asks at a terminal.
set -eu

releases=https://github.com/thebrandonlucas/kai/releases
nix_installer=https://nixos.org/nix/install
guix_installer=https://guix.gnu.org/manual/en/html_node/Binary-Installation.html
# Where the multi-user Nix installer puts nix.
default_nix=/nix/var/nix/profiles/default/bin/nix

usage() {
  cat <<EOF
Install kai from a release of $releases.

Usage: install.sh [--version VERSION] [--dir DIR] [--yes]

  --version VERSION  install VERSION, such as 0.0.10, instead of the latest
                     release (or set KAI_VERSION)
  --dir DIR          install kai into DIR (or set KAI_INSTALL_DIR;
                     default: \$HOME/.local/bin)
  --yes              install Nix without asking when neither Nix nor Guix
                     is installed (or set KAI_INSTALL_NIX=1)
  --help             show this help

Through a pipe, pass options after \`sh -s --\`:

  curl -fsSL $releases/latest/download/install.sh | sh -s -- --yes
EOF
}

say() { printf 'kai-install: %s\n' "$*"; }
die() {
  printf 'kai-install: %s\n' "$*" >&2
  exit 1
}

version=${KAI_VERSION:-}
dir=${KAI_INSTALL_DIR:-}
install_nix=${KAI_INSTALL_NIX:-0}
while [ $# -gt 0 ]; do
  case $1 in
  --help | -h)
    usage
    exit 0
    ;;
  --yes | -y) install_nix=1 ;;
  --version | --dir)
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
    --version) version=$2 ;;
    *) dir=$2 ;;
    esac
    shift
    ;;
  --version=*) version=${1#*=} ;;
  --dir=*) dir=${1#*=} ;;
  *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
[ "$install_nix" = 1 ] || install_nix=0
version=${version#v}
if [ -z "$dir" ]; then
  [ -n "${HOME:-}" ] || die "HOME is not set; choose a directory with --dir"
  dir=$HOME/.local/bin
fi

# Downloads URL to FILE.
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    die "needs curl or wget to download kai"
  fi
}

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
  die "needs sha256sum or shasum to check the download"
fi

os=$(uname -s)
arch=$(uname -m)
case $arch in
amd64) arch=x86_64 ;;
arm64) arch=aarch64 ;;
esac
case $os in
Linux) system=$arch-linux ;;
Darwin) system=$arch-darwin ;;
*) system=$arch-$os ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

# The release's SHA256SUMS names its archives, kai-VERSION-SYSTEM.tar.gz, so
# the latest release's names its version.
if [ -n "$version" ]; then
  base=$releases/download/v$version
  what="Kai $version"
else
  base=$releases/latest/download
  what="the latest Kai release"
fi
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" ||
  die "could not download SHA256SUMS of $what from $base"
line=$(sed -n "/^[0-9a-f]\{64\}  \*\{0,1\}kai-[0-9.]*-$system\.tar\.gz\$/p" \
  "$tmp/SHA256SUMS" | head -n 1)
if [ -z "$line" ]; then
  systems=$(sed -n 's/^.*  \*\{0,1\}kai-[0-9.]*-\(.*\)\.tar\.gz$/\1/p' \
    "$tmp/SHA256SUMS" | tr '\n' ' ')
  die "$what has no kai for $system; it supports: ${systems% }"
fi
expected=${line%% *}
archive=${line##* }
archive=${archive#\*}
version=${archive#kai-}
version=${version%-"$system".tar.gz}

say "downloading $archive"
fetch "$releases/download/v$version/$archive" "$tmp/$archive" ||
  die "could not download $releases/download/v$version/$archive"
actual=$(sha256 "$tmp/$archive")
[ "$actual" = "$expected" ] ||
  die "$archive does not match its SHA256SUMS (expected $expected, got $actual); not installing"
tar -xzf "$tmp/$archive" -C "$tmp" kai || die "could not unpack $archive"

mkdir -p "$dir" || die "could not create $dir"
if ! { cp "$tmp/kai" "$dir/.kai.tmp" && chmod 0755 "$dir/.kai.tmp" &&
  mv -f "$dir/.kai.tmp" "$dir/kai"; }; then
  die "could not install kai into $dir"
fi
say "installed kai $version to $dir/kai"
"$dir/kai" --version

case :${PATH:-}: in
*:"$dir":*) ;;
*)
  say "$dir is not on PATH; add it, for example in your shell's profile:"
  # shellcheck disable=SC2016 # prints $PATH for the profile to expand
  printf '\n  export PATH="%s:$PATH"\n\n' "$dir"
  ;;
esac

# Whether NIX enables flakes.
has_flakes() {
  {
    "$1" config show experimental-features 2>/dev/null ||
      "$1" show-config 2>/dev/null | sed -n 's/^experimental-features = //p'
  } | grep -qw flakes
}

# The official installer leaves flakes off; enable them for this user.
enable_flakes() {
  conf=${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf
  if [ -x "$1" ] && has_flakes "$1"; then
    return 0
  fi
  mkdir -p "${conf%/*}"
  printf 'extra-experimental-features = nix-command flakes\n' >>"$conf"
  say "enabled flakes in $conf"
}

install_nix() {
  say "installing Nix with the official installer from $nix_installer"
  fetch "$nix_installer" "$tmp/nix-install" || die "could not download $nix_installer"
  if [ "$install_nix" = 1 ]; then
    sh "$tmp/nix-install" --daemon --yes || die "the Nix installer failed"
  else
    sh "$tmp/nix-install" --daemon </dev/tty || die "the Nix installer failed"
  fi
  enable_flakes "$default_nix"
  say "open a new shell so that nix is on PATH, then run kai"
}

if command -v nix >/dev/null 2>&1; then
  has_flakes nix ||
    say "Kai needs Nix flakes; enable them by adding 'extra-experimental-features = nix-command flakes' to ~/.config/nix/nix.conf"
elif command -v guix >/dev/null 2>&1; then
  :
elif [ -x "$default_nix" ]; then
  say "Nix is installed but not on PATH; open a new shell before running kai"
else
  say "Kai needs Nix (or Guix), and neither is installed."
  if [ "$install_nix" != 1 ] && (: </dev/tty) 2>/dev/null; then
    printf 'kai-install: Install Nix now with the official Nix installer? [y/N] ' >/dev/tty
    read -r answer </dev/tty || answer=
    case $answer in
    [yY] | [yY][eE][sS]) install_nix="tty" ;;
    esac
  fi
  if [ "$install_nix" = 0 ]; then
    say "to install Nix, run the official installer, then enable flakes:"
    printf '\n  sh <(curl -L %s) --daemon\n' "$nix_installer"
    printf "  echo 'extra-experimental-features = nix-command flakes' >>~/.config/nix/nix.conf\n\n"
    say "or rerun this script with --yes to do both; for Guix, see $guix_installer"
  else
    install_nix
  fi
fi
