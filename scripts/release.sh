#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$root_dir/xkai-bin/VERSION"
manifest_file="$root_dir/build.zig.zon"
semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if (($# != 2)); then
  echo "usage: $0 NAME X.Y.Z" >&2
  exit 1
fi

release_name="$1"
version="$2"
tag="v$version"

if [[ ! "$release_name" =~ [^[:space:]] ]]; then
  echo "error: release name must not be empty" >&2
  exit 1
fi

if [[ "$release_name" == *$'\n'* || "$release_name" == *$'\r'* ]]; then
  echo "error: release name must fit on one line" >&2
  exit 1
fi

if [[ ! "$version" =~ $semver_pattern ]]; then
  echo "error: version must be a semantic version in X.Y.Z form" >&2
  exit 1
fi

cd "$root_dir"

if [[ "$(git branch --show-current)" != "master" ]]; then
  echo "error: releases must be made from the master branch" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "error: the working tree must be clean before releasing" >&2
  exit 1
fi

if ! git fetch --quiet origin master:refs/remotes/origin/master; then
  echo "error: failed to fetch origin/master" >&2
  exit 1
fi

starting_head="$(git rev-parse HEAD)"
if [[ "$starting_head" != "$(git rev-parse refs/remotes/origin/master)" ]]; then
  echo "error: local master must exactly match origin/master; pull or push changes first" >&2
  exit 1
fi

current_version="$(<"$version_file")"
if [[ ! "$current_version" =~ $semver_pattern ]]; then
  echo "error: xkai-bin/VERSION does not contain a valid semantic version" >&2
  exit 1
fi

manifest_version="$(
  awk -F'"' '/^[[:space:]]*\.version =/ { print $2; exit }' "$manifest_file"
)"
if [[ "$manifest_version" != "$current_version" ]]; then
  echo "error: build.zig.zon version $manifest_version does not match xkai-bin/VERSION $current_version" >&2
  exit 1
fi

if [[ "$version" != "$current_version" ]] &&
  [[ "$(printf '%s\n%s\n' "$current_version" "$version" | sort -V | tail -n 1)" != "$version" ]]; then
  echo "error: release version $version must not be older than $current_version" >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/$tag"; then
  echo "error: local tag $tag already exists" >&2
  exit 1
fi

if [[ -n "$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")" ]]; then
  echo "error: tag $tag already exists on origin" >&2
  exit 1
fi

version_changed=false
release_committed=false
tag_created=false
push_started=false
cleanup() {
  status=$?
  trap - EXIT

  if ((status == 0)); then
    exit 0
  fi

  if [[ "$push_started" == true ]]; then
    echo "error: push status is ambiguous; local release state was retained" >&2
    echo "error: inspect origin/master and $tag before retrying" >&2
    exit "$status"
  fi

  if [[ "$tag_created" == true ]]; then
    git tag --delete "$tag" >/dev/null 2>&1 || true
  fi

  if [[ "$release_committed" == true ]]; then
    git reset --hard "$starting_head" >/dev/null 2>&1 || true
  elif [[ "$version_changed" == true ]]; then
    git reset --quiet -- build.zig.zon xkai-bin/VERSION 2>/dev/null || true
    printf '%s' "$current_version" >"$version_file"
    perl -0pi -e \
      's/([[:space:]]*\.version = ")[^"]+("[,]?)/$1'"$current_version"'$2/' \
      "$manifest_file"
  fi

  echo "error: release failed; local release changes were rolled back" >&2
  exit "$status"
}
trap cleanup EXIT

if [[ "$version" != "$current_version" ]]; then
  version_changed=true
  printf '%s' "$version" >"$version_file"
  perl -0pi -e \
    's/([[:space:]]*\.version = ")[^"]+("[,]?)/$1'"$version"'$2/' \
    "$manifest_file"
else
  echo "Using the already prepared, unreleased version $version."
fi

echo "Building and checking $release_name ($version)..."
nix develop --command ./scripts/build-release.sh

status="$(git status --porcelain --untracked-files=all)"
if [[ "$version_changed" == true ]]; then
  expected_status=$' M build.zig.zon\n M xkai-bin/VERSION'
else
  expected_status=""
fi

if [[ "$status" != "$expected_status" ]]; then
  echo "error: release checks changed unexpected files:" >&2
  printf '%s\n' "$status" >&2
  exit 1
fi

if [[ "$version_changed" == true ]]; then
  git add -- build.zig.zon xkai-bin/VERSION
  expected_staged=$'build.zig.zon\nxkai-bin/VERSION'
  if [[ "$(git diff --cached --name-only)" != "$expected_staged" ]]; then
    echo "error: refusing to commit files other than the version files" >&2
    exit 1
  fi

  git commit --no-gpg-sign -m "chore: release $version"
  release_committed=true
fi

git tag --annotate "$tag" --message "$release_name"
tag_created=true

echo "Pushing master and $tag..."
push_started=true
git push --atomic origin master "refs/tags/$tag"
push_started=false

release_committed=false
tag_created=false
echo "Release $release_name ($tag) pushed; GitHub Actions will publish the artifacts."
