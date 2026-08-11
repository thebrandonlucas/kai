#!/usr/bin/env bash
# Exercise protected release preparation against disposable Git repositories.
set -euo pipefail

if (($# != 1)); then
  echo "usage: $0 DEVTOOL" >&2
  exit 1
fi

devtool="$(realpath "$1")"
real_git="$(command -v git)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/kai-prepare-release.XXXXXX")"
fake_bin="$work_dir/bin"
origin_url="git@github.com:example-owner/example-repo.git"

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_EXEC_PATH
if [[ -n "${GIT_CONFIG_COUNT:-}" ]]; then
  for ((config_index = 0; config_index < GIT_CONFIG_COUNT; config_index++)); do
    unset "GIT_CONFIG_KEY_$config_index" "GIT_CONFIG_VALUE_$config_index"
  done
  unset GIT_CONFIG_COUNT
fi
mkdir -p "$work_dir/home" "$work_dir/xdg"
export HOME="$work_dir/home"
export XDG_CONFIG_HOME="$work_dir/xdg"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_ALLOW_PROTOCOL=ssh:file

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

mkdir "$fake_bin"
cat >"$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

host="${@: -2:1}"
command_string="${@: -1}"
printf '%s\t%s\n' "$host" "$command_string" >>"$FAKE_SSH_LOG"
[[ "$host" == "git@github.com" ]] || {
  echo "unexpected SSH host: $host" >&2
  exit 2
}
case "$command_string" in
  "git-upload-pack 'example-owner/example-repo.git'") exec git-upload-pack "$FAKE_GIT_REMOTE" ;;
  "git-receive-pack 'example-owner/example-repo.git'")
    set +e
    git-receive-pack "$FAKE_GIT_REMOTE"
    status=$?
    set -e
    if [[ "$status" -eq 0 && "${FAKE_SSH_AMBIGUOUS:-false}" == true ]]; then
      exit 1
    fi
    exit "$status"
    ;;
  *)
    echo "unexpected SSH command: $command_string" >&2
    exit 2
    ;;
esac
EOF
cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s' "$1" >>"$FAKE_GIT_LOG"
for argument in "${@:2}"; do
  printf '\t%s' "$argument" >>"$FAKE_GIT_LOG"
done
printf '\n' >>"$FAKE_GIT_LOG"
exec "$REAL_GIT" "$@"
EOF
cat >"$fake_bin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_ZIG_LOG"
if (($# != 2)) || [[ "$1" != "build" ]] || [[ "$2" != "build-release" ]]; then
  echo "unexpected Zig command: $*" >&2
  exit 2
fi
if [[ "$PWD" != "$FAKE_REPOSITORY" ]]; then
  echo "release build ran from unexpected directory: $PWD" >&2
  exit 2
fi
cmp --silent xkai-bin/VERSION <(printf '%s' "0.0.3") || exit 3
cmp --silent xkai-bin/RELEASE_NAME <(printf '%s' "Example 0.0.3") || exit 3
cmp --silent build.zig.zon <(printf '%s' '.{
    .name = .example,
    .version = "0.0.3",
    .paths = .{},
}
') || exit 3
changed="$("$REAL_GIT" diff --name-only | sort)"
expected="$(printf '%s\n' build.zig.zon xkai-bin/RELEASE_NAME xkai-bin/VERSION | sort)"
[[ "$changed" == "$expected" ]] || exit 3
"$REAL_GIT" diff --cached --quiet || exit 3
[[ "$("$REAL_GIT" branch --show-current)" == "release/v0.0.3" ]] || exit 3
if [[ "${FAKE_ZIG_FAIL:-false}" == true ]]; then
  mkdir -p dist .release-build.fixture
  touch dist/partial
  exit 23
fi
EOF
chmod +x "$fake_bin/git" "$fake_bin/ssh" "$fake_bin/zig"

create_fixture() {
  local name="$1"
  local root="$work_dir/$name"
  local repository="$root/repository"
  local remote="$root/remote.git"

  mkdir -p "$repository/xkai-bin"
  git -C "$repository" init --quiet --initial-branch=master
  git -C "$repository" config user.name "Release Test"
  git -C "$repository" config user.email "release-test@example.invalid"
  cat >"$repository/build.zig.zon" <<'EOF'
.{
    .name = .example,
    .version = "0.0.2",
    .paths = .{},
}
EOF
  printf '%s' "Example 0.0.2" >"$repository/xkai-bin/RELEASE_NAME"
  printf '%s' "0.0.2" >"$repository/xkai-bin/VERSION"
  git -C "$repository" add -- build.zig.zon xkai-bin/RELEASE_NAME xkai-bin/VERSION
  git -C "$repository" commit --quiet --no-gpg-sign --message="test: initial release state"
  git clone --quiet --bare "$repository" "$remote"
  git -C "$repository" remote add origin "$origin_url"
}

assert_master_restored() {
  local repository="$1"
  local initial_head="$2"
  local branch
  local head
  local status

  branch="$(git -C "$repository" branch --show-current)"
  head="$(git -C "$repository" rev-parse HEAD)"
  status="$(git -C "$repository" status --porcelain --untracked-files=all)"
  [[ "$branch" == "master" ]] || fail "release test did not restore master"
  [[ "$head" == "$initial_head" ]] || fail "release test changed local master"
  [[ -z "$status" ]] || fail "release test left a dirty worktree: $status"
}

assert_no_local_release_ref() {
  local repository="$1"
  if git -C "$repository" show-ref --verify --quiet refs/heads/release/v0.0.3; then
    fail "release test retained a local release branch"
  fi
}

assert_release_only_push() {
  local git_log="$1"
  local push_lines
  local expected
  push_lines="$(awk -F '\t' '{ for (field = 1; field <= NF; field++) if ($field == "push") { print; next } }' "$git_log")"
  expected=$'-c\tpush.followTags=false\tpush\t--force-with-lease=refs/heads/release/v0.0.3:\torigin\trefs/heads/release/v0.0.3:refs/heads/release/v0.0.3'
  [[ "$push_lines" == "$expected" ]] || fail "unexpected Git push invocation: $push_lines"
}

assert_no_push() {
  local git_log="$1"
  local ssh_log="$2"
  if [[ -f "$git_log" ]] &&
    ! awk -F '\t' '{ for (field = 1; field <= NF; field++) if ($field == "push") exit 1 }' "$git_log"; then
    fail "release preflight invoked Git push"
  fi
  if [[ -f "$ssh_log" ]] && grep -F "git-receive-pack " "$ssh_log" >/dev/null; then
    fail "release preflight invoked the receive-pack transport"
  fi
}

run_devtool() {
  local repository="$1"
  local remote="$2"
  local log="$3"
  local name="$4"
  local version="$5"
  shift 5
  (
    cd "$repository"
    PATH="$fake_bin:$PATH" \
      GIT_SSH_COMMAND="$fake_bin/ssh" \
      GIT_SSH_VARIANT=ssh \
      REAL_GIT="$real_git" \
      FAKE_GIT_LOG="${log%-zig.log}.git.log" \
      FAKE_SSH_LOG="${log%-zig.log}.ssh.log" \
      FAKE_GIT_REMOTE="$remote" \
      FAKE_REPOSITORY="$repository" \
      FAKE_ZIG_LOG="$log" \
      "$@" \
      "$devtool" prepare-release "$name" "$version"
  )
}

create_fixture success
success_repository="$work_dir/success/repository"
success_remote="$work_dir/success/remote.git"
success_initial="$(git -C "$success_repository" rev-parse HEAD)"
if ! run_devtool \
  "$success_repository" \
  "$success_remote" \
  "$work_dir/success-zig.log" \
  "Example 0.0.3" \
  0.0.3 \
  env >"$work_dir/success.log" 2>&1; then
  cat "$work_dir/success.log" >&2
  fail "successful release preparation failed"
fi

assert_master_restored "$success_repository" "$success_initial"
assert_no_local_release_ref "$success_repository"
success_local_refs="$(git -C "$success_repository" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | sort)"
[[ "$success_local_refs" == "refs/heads/master $success_initial" ]] ||
  fail "successful preparation left unexpected local refs: $success_local_refs"
[[ "$(<"$work_dir/success-zig.log")" == "build build-release" ]] ||
  fail "release preparation did not invoke the release builder exactly once"
assert_release_only_push "$work_dir/success.git.log"
release_head="$(git --git-dir="$success_remote" rev-parse refs/heads/release/v0.0.3)"
remote_master="$(git --git-dir="$success_remote" rev-parse refs/heads/master)"
[[ "$remote_master" == "$success_initial" ]] || fail "release preparation moved remote master"
[[ "$(git --git-dir="$success_remote" rev-parse "$release_head^")" == "$success_initial" ]] ||
  fail "release commit does not descend directly from master"
[[ "$(git --git-dir="$success_remote" show --format=%s --no-patch "$release_head")" == "chore: release 0.0.3" ]] ||
  fail "release commit message differs"
changed_files="$(git --git-dir="$success_remote" diff-tree --no-commit-id --name-only -r "$release_head" | sort)"
expected_files="$(printf '%s\n' build.zig.zon xkai-bin/RELEASE_NAME xkai-bin/VERSION | sort)"
[[ "$changed_files" == "$expected_files" ]] || fail "release commit changed unexpected files: $changed_files"
git --git-dir="$success_remote" show "$release_head:xkai-bin/VERSION" >"$work_dir/committed-version"
git --git-dir="$success_remote" show "$release_head:xkai-bin/RELEASE_NAME" >"$work_dir/committed-name"
git --git-dir="$success_remote" show "$release_head:build.zig.zon" >"$work_dir/committed-manifest"
cmp --silent "$work_dir/committed-version" <(printf '%s' "0.0.3") || fail "release commit version differs"
cmp --silent "$work_dir/committed-name" <(printf '%s' "Example 0.0.3") || fail "release commit name differs"
cmp --silent "$work_dir/committed-manifest" <(printf '%s' '.{
    .name = .example,
    .version = "0.0.3",
    .paths = .{},
}
') || fail "release commit manifest differs"
[[ -z "$(git --git-dir="$success_remote" tag --list)" ]] || fail "release preparation created a tag"
remote_refs="$(git --git-dir="$success_remote" for-each-ref --format='%(refname)' | sort)"
expected_refs="$(printf '%s\n' refs/heads/master refs/heads/release/v0.0.3 | sort)"
[[ "$remote_refs" == "$expected_refs" ]] || fail "release preparation created unexpected remote refs: $remote_refs"
grep -F "https://github.com/example-owner/example-repo/compare/master...release%2Fv0.0.3?expand=1" \
  "$work_dir/success.log" >/dev/null || fail "release preparation did not print the pull request URL"

create_fixture rollback
rollback_repository="$work_dir/rollback/repository"
rollback_remote="$work_dir/rollback/remote.git"
rollback_initial="$(git -C "$rollback_repository" rev-parse HEAD)"
set +e
run_devtool \
  "$rollback_repository" \
  "$rollback_remote" \
  "$work_dir/rollback-zig.log" \
  "Example 0.0.3" \
  0.0.3 \
  env FAKE_ZIG_FAIL=true >"$work_dir/rollback.log" 2>&1
rollback_status=$?
set -e
[[ "$rollback_status" -ne 0 ]] || fail "release preparation accepted a failed release build"
assert_master_restored "$rollback_repository" "$rollback_initial"
assert_no_local_release_ref "$rollback_repository"
if git --git-dir="$rollback_remote" show-ref --verify --quiet refs/heads/release/v0.0.3; then
  fail "failed release preparation pushed a release branch"
fi
[[ "$(git --git-dir="$rollback_remote" rev-parse refs/heads/master)" == "$rollback_initial" ]] ||
  fail "failed release preparation moved remote master"
[[ ! -e "$rollback_repository/dist" ]] || fail "rollback retained partial release output"
[[ ! -e "$rollback_repository/.release-build.fixture" ]] || fail "rollback retained a release workspace"
assert_no_push "$work_dir/rollback.git.log" "$work_dir/rollback.ssh.log"
rollback_local_refs="$(git -C "$rollback_repository" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | sort)"
rollback_remote_refs="$(git --git-dir="$rollback_remote" for-each-ref --format='%(refname) %(objectname)' | sort)"
[[ "$rollback_local_refs" == "refs/heads/master $rollback_initial" ]] ||
  fail "rollback left unexpected local refs: $rollback_local_refs"
[[ "$rollback_remote_refs" == "refs/heads/master $rollback_initial" ]] ||
  fail "rollback left unexpected remote refs: $rollback_remote_refs"

create_fixture ambiguous
ambiguous_repository="$work_dir/ambiguous/repository"
ambiguous_remote="$work_dir/ambiguous/remote.git"
ambiguous_initial="$(git -C "$ambiguous_repository" rev-parse HEAD)"
set +e
run_devtool \
  "$ambiguous_repository" \
  "$ambiguous_remote" \
  "$work_dir/ambiguous-zig.log" \
  "Example 0.0.3" \
  0.0.3 \
  env FAKE_SSH_AMBIGUOUS=true >"$work_dir/ambiguous.log" 2>&1
ambiguous_status=$?
set -e
[[ "$ambiguous_status" -ne 0 ]] || fail "ambiguous push was reported as successful"
assert_release_only_push "$work_dir/ambiguous.git.log"
[[ "$(git -C "$ambiguous_repository" branch --show-current)" == "release/v0.0.3" ]] ||
  fail "ambiguous push did not retain the local release branch"
ambiguous_local="$(git -C "$ambiguous_repository" rev-parse refs/heads/release/v0.0.3)"
ambiguous_remote_head="$(git --git-dir="$ambiguous_remote" rev-parse refs/heads/release/v0.0.3)"
[[ "$ambiguous_local" == "$ambiguous_remote_head" ]] ||
  fail "ambiguous push did not retain matching local and remote release state"
ambiguous_local_refs="$(git -C "$ambiguous_repository" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | sort)"
ambiguous_remote_refs="$(git --git-dir="$ambiguous_remote" for-each-ref --format='%(refname) %(objectname)' | sort)"
expected_ambiguous_refs="$(printf '%s\n' "refs/heads/master $ambiguous_initial" "refs/heads/release/v0.0.3 $ambiguous_local" | sort)"
[[ "$ambiguous_local_refs" == "$expected_ambiguous_refs" ]] ||
  fail "ambiguous push left unexpected local refs: $ambiguous_local_refs"
[[ "$ambiguous_remote_refs" == "$expected_ambiguous_refs" ]] ||
  fail "ambiguous push left unexpected remote refs: $ambiguous_remote_refs"
[[ "$(git -C "$ambiguous_repository" rev-parse refs/heads/master)" == "$ambiguous_initial" ]] ||
  fail "ambiguous push changed local master"
[[ "$(git --git-dir="$ambiguous_remote" rev-parse refs/heads/master)" == "$ambiguous_initial" ]] ||
  fail "ambiguous push changed remote master"
grep -F "push status is ambiguous; local release state was retained" "$work_dir/ambiguous.log" >/dev/null ||
  fail "ambiguous push did not print recovery guidance"

preflight_scenarios=(
  dirty wrong-branch local-ahead remote-ahead diverged
  invalid-name invalid-version equal-version older-version
  invalid-metadata mismatched-metadata
  local-tag remote-tag local-branch remote-branch
  unsupported-host extra-path mismatched-push multiple-fetch multiple-push
)
for scenario in "${preflight_scenarios[@]}"; do
  fixture="preflight-$scenario"
  create_fixture "$fixture"
  repository="$work_dir/$fixture/repository"
  remote="$work_dir/$fixture/remote.git"
  requested_name="Example 0.0.3"
  requested_version="0.0.3"
  case "$scenario" in
  dirty) touch "$repository/untracked" ;;
  wrong-branch) git -C "$repository" switch --quiet --create topic ;;
  local-ahead)
    printf '%s\n' local >"$repository/local-change"
    git -C "$repository" add local-change
    git -C "$repository" commit --quiet --no-gpg-sign --message="test: advance local master"
    ;;
  remote-ahead | diverged)
    if [[ "$scenario" == diverged ]]; then
      printf '%s\n' local >"$repository/local-change"
      git -C "$repository" add local-change
      git -C "$repository" commit --quiet --no-gpg-sign --message="test: advance local master"
    fi
    updater="$work_dir/$fixture-updater"
    git clone --quiet "$remote" "$updater"
    git -C "$updater" config user.name "Release Test"
    git -C "$updater" config user.email "release-test@example.invalid"
    printf '%s\n' remote >"$updater/remote-change"
    git -C "$updater" add remote-change
    git -C "$updater" commit --quiet --no-gpg-sign --message="test: advance remote master"
    git -C "$updater" push --quiet origin master
    ;;
  invalid-name) requested_name="" ;;
  invalid-version) requested_version="not-a-version" ;;
  equal-version) requested_version="0.0.2" ;;
  older-version) requested_version="0.0.1" ;;
  invalid-metadata)
    printf '%s' invalid >"$repository/xkai-bin/VERSION"
    git -C "$repository" add xkai-bin/VERSION
    git -C "$repository" commit --quiet --no-gpg-sign --message="test: invalidate release metadata"
    git -C "$repository" push --quiet "$remote" master:master
    ;;
  mismatched-metadata)
    printf '%s' "0.0.1" >"$repository/xkai-bin/VERSION"
    git -C "$repository" add xkai-bin/VERSION
    git -C "$repository" commit --quiet --no-gpg-sign --message="test: mismatch release metadata"
    git -C "$repository" push --quiet "$remote" master:master
    ;;
  local-tag) git -C "$repository" tag v0.0.3 ;;
  remote-tag) git --git-dir="$remote" tag v0.0.3 master ;;
  local-branch) git -C "$repository" branch release/v0.0.3 ;;
  remote-branch) git --git-dir="$remote" update-ref refs/heads/release/v0.0.3 refs/heads/master ;;
  unsupported-host) git -C "$repository" remote set-url origin git@gitlab.com:example-owner/example-repo.git ;;
  extra-path) git -C "$repository" remote set-url origin git@github.com:example-owner/example-repo/extra.git ;;
  mismatched-push) git -C "$repository" remote set-url --push origin git@github.com:other-owner/example-repo.git ;;
  multiple-fetch) git -C "$repository" config --add remote.origin.url "$origin_url" ;;
  multiple-push)
    git -C "$repository" config --add remote.origin.pushurl "$origin_url"
    git -C "$repository" config --add remote.origin.pushurl "$origin_url"
    ;;
  esac

  branch_before="$(git -C "$repository" branch --show-current)"
  head_before="$(git -C "$repository" rev-parse HEAD)"
  status_before="$(git -C "$repository" status --porcelain --untracked-files=all)"
  local_refs_before="$(git -C "$repository" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | sort)"
  remote_refs_before="$(git --git-dir="$remote" for-each-ref --format='%(refname) %(objectname)' | sort)"

  set +e
  run_devtool \
    "$repository" \
    "$remote" \
    "$work_dir/$fixture-zig.log" \
    "$requested_name" \
    "$requested_version" \
    env >"$work_dir/$fixture.log" 2>&1
  preflight_status=$?
  set -e

  [[ "$preflight_status" -ne 0 ]] || fail "$scenario preflight was accepted"
  [[ ! -s "$work_dir/$fixture-zig.log" ]] || fail "$scenario preflight invoked the release builder"
  assert_no_push "$work_dir/$fixture.git.log" "$work_dir/$fixture.ssh.log"
  [[ "$(git -C "$repository" branch --show-current)" == "$branch_before" ]] ||
    fail "$scenario preflight changed the current branch"
  [[ "$(git -C "$repository" rev-parse HEAD)" == "$head_before" ]] ||
    fail "$scenario preflight changed HEAD"
  [[ "$(git -C "$repository" status --porcelain --untracked-files=all)" == "$status_before" ]] ||
    fail "$scenario preflight changed worktree state"
  [[ "$(git -C "$repository" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | sort)" == "$local_refs_before" ]] ||
    fail "$scenario preflight changed local refs"
  [[ "$(git --git-dir="$remote" for-each-ref --format='%(refname) %(objectname)' | sort)" == "$remote_refs_before" ]] ||
    fail "$scenario preflight changed remote refs"
done

echo "Protected release preparation integration tests passed."
