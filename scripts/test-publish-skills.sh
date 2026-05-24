#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
PUBLISH_SCRIPT=$REPO_ROOT/scripts/publish-skills.sh
SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-publish-test-XXXXXX")

assert_equal() {
  actual=$1
  expected=$2
  message=$3

  if [ "$actual" != "$expected" ]; then
    echo "$message Expected '$expected', got '$actual'." >&2
    exit 1
  fi
}

assert_not_equal() {
  actual=$1
  unexpected=$2
  message=$3

  if [ "$actual" = "$unexpected" ]; then
    echo "$message Value should not be '$unexpected'." >&2
    exit 1
  fi
}

assert_git_clean() {
  repo_path=$1
  status=$(git -C "$repo_path" status --porcelain)
  if [ -n "$status" ]; then
    echo "Expected git repository to be clean: $repo_path" >&2
    echo "$status" >&2
    exit 1
  fi
}

cleanup() {
  if [ ! -d "$SANDBOX_ROOT" ]; then
    return
  fi

  temp_root=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd)
  sandbox_parent=$(CDPATH= cd "$(dirname "$SANDBOX_ROOT")" && pwd)
  sandbox_leaf=${SANDBOX_ROOT##*/}
  if [ "$sandbox_parent" != "$temp_root" ] || [ "${sandbox_leaf#oceans-publish-test-}" = "$sandbox_leaf" ]; then
    echo "Unsafe cleanup target: $SANDBOX_ROOT" >&2
    exit 1
  fi

  rm -rf "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

git_run() {
  repo_path=$1
  shift

  git -C "$repo_path" "$@"
}

git_quiet() {
  repo_path=$1
  shift

  git -C "$repo_path" "$@" >/dev/null 2>&1
}

git_global_quiet() {
  git "$@" >/dev/null 2>&1
}

init_bare_repository() {
  bare_path=$1
  seed_path=$2
  kind=$3

  mkdir -p "$(dirname "$bare_path")" "$seed_path"
  git_global_quiet init "$seed_path"
  git_quiet "$seed_path" checkout -q -B main
  git_quiet "$seed_path" config user.email publish-test@example.invalid
  git_quiet "$seed_path" config user.name "Publish Test"
  git_quiet "$seed_path" config core.autocrlf false

  if [ "$kind" = "entry" ]; then
    printf '%s\n' "entry fixture" > "$seed_path/README.md"
  else
    mkdir -p "$seed_path/skills"
    : > "$seed_path/skills/.gitkeep"
  fi

  git_quiet "$seed_path" add .
  git_quiet "$seed_path" commit -m initial
  git_global_quiet init --bare "$bare_path"
  git_quiet "$seed_path" remote add origin "$bare_path"
  git_quiet "$seed_path" push -u origin main
  git --git-dir="$bare_path" symbolic-ref HEAD refs/heads/main
}

new_fixture() {
  fixture_name=$1

  FIXTURE_ROOT=$SANDBOX_ROOT/$fixture_name
  REMOTE_ROOT=$FIXTURE_ROOT/remote
  WORK_ROOT=$FIXTURE_ROOT/work
  SEED_ROOT=$FIXTURE_ROOT/seed
  ENTRY_REMOTE=$REMOTE_ROOT/entry.git
  FIRST_PARTY_REMOTE=$REMOTE_ROOT/oceans-skills.git
  COMMUNITY_REMOTE=$REMOTE_ROOT/community-skills.git
  ENTRY_REPO=$WORK_ROOT/entry

  init_bare_repository "$ENTRY_REMOTE" "$SEED_ROOT/entry" entry
  init_bare_repository "$FIRST_PARTY_REMOTE" "$SEED_ROOT/oceans-skills" skills
  init_bare_repository "$COMMUNITY_REMOTE" "$SEED_ROOT/community-skills" skills

  mkdir -p "$WORK_ROOT"
  git_global_quiet clone "$ENTRY_REMOTE" "$ENTRY_REPO"
  git_quiet "$ENTRY_REPO" config user.email publish-test@example.invalid
  git_quiet "$ENTRY_REPO" config user.name "Publish Test"
  git_quiet "$ENTRY_REPO" config core.autocrlf false
  git_quiet "$ENTRY_REPO" reset --hard HEAD

  git -C "$ENTRY_REPO" -c protocol.file.allow=always submodule add -b main "$FIRST_PARTY_REMOTE" repos/oceans-skills >/dev/null 2>&1
  git -C "$ENTRY_REPO" -c protocol.file.allow=always submodule add -b main "$COMMUNITY_REMOTE" repos/community-skills >/dev/null 2>&1
  git_quiet "$ENTRY_REPO" commit -m "add skill submodules"
  git_quiet "$ENTRY_REPO" push origin main

  FIRST_PARTY_REPO=$ENTRY_REPO/repos/oceans-skills
  COMMUNITY_REPO=$ENTRY_REPO/repos/community-skills
  for child_repo in "$FIRST_PARTY_REPO" "$COMMUNITY_REPO"; do
    git_quiet "$child_repo" config user.email publish-test@example.invalid
    git_quiet "$child_repo" config user.name "Publish Test"
    git_quiet "$child_repo" config core.autocrlf false
    git_quiet "$child_repo" reset --hard HEAD
  done

  assert_git_clean "$ENTRY_REPO"
  assert_git_clean "$FIRST_PARTY_REPO"
  assert_git_clean "$COMMUNITY_REPO"
}

run_publish() {
  expected=$1
  shift

  if [ ! -f "$PUBLISH_SCRIPT" ]; then
    echo "Missing publish script: $PUBLISH_SCRIPT" >&2
    exit 1
  fi

  publish_env_home=$FIXTURE_ROOT/publish-env-home
  mkdir -p "$publish_env_home/.config"

  set +e
  output=$(
    cd "$ENTRY_REPO" && \
    GIT_TERMINAL_PROMPT=0 \
    HOME="$publish_env_home" \
    USERPROFILE="$publish_env_home" \
    XDG_CONFIG_HOME="$publish_env_home/.config" \
    GIT_CONFIG_GLOBAL="$publish_env_home/.gitconfig" \
    sh "$PUBLISH_SCRIPT" \
      --repo-root "$ENTRY_REPO" \
      --first-party-repo "$FIRST_PARTY_REPO" \
      --community-repo "$COMMUNITY_REPO" \
      "$@" 2>&1
  )
  status=$?
  set -e

  if [ "$expected" = "failure" ]; then
    if [ "$status" -eq 0 ]; then
      echo "Expected publish-skills.sh to fail. Output:" >&2
      echo "$output" >&2
      exit 1
    fi
  elif [ "$status" -ne 0 ]; then
    echo "Expected publish-skills.sh to pass. Exit code: $status Output:" >&2
    echo "$output" >&2
    exit 1
  fi

  printf '%s' "$output"
}

run_publish_success() {
  run_publish success "$@"
}

run_publish_failure() {
  run_publish failure "$@"
}

get_head() {
  repo_path=$1

  git_run "$repo_path" rev-parse HEAD
}

get_remote_main() {
  repo_path=$1

  git_run "$repo_path" ls-remote origin refs/heads/main | awk '{print $1}'
}

get_submodule_pointer() {
  entry_repo=$1
  submodule_path=$2

  git_run "$entry_repo" ls-tree HEAD "$submodule_path" | awk '{print $3}'
}

add_first_party_skill_change() {
  skill_name=$1
  stage_change=$2
  skill_path=$FIRST_PARTY_REPO/skills/$skill_name

  mkdir -p "$skill_path"
  cat > "$skill_path/SKILL.md" <<EOF
---
name: $skill_name
description: Publish test skill.
---
EOF

  if [ "$stage_change" = "stage" ]; then
    git_quiet "$FIRST_PARTY_REPO" add .
  fi
}

add_community_skill_change() {
  skill_name=$1
  validity=$2
  skill_path=$COMMUNITY_REPO/skills/$skill_name

  mkdir -p "$skill_path"
  cat > "$skill_path/SKILL.md" <<EOF
---
name: $skill_name
description: Community publish test skill.
---
EOF

  if [ "$validity" = "valid" ]; then
    printf '%s\n' \
      "Original repository: https://example.invalid/$skill_name" \
      "Original author: Example" \
      "License: MIT" > "$skill_path/UPSTREAM.md"
    printf '%s\n' "No local patches." > "$skill_path/PATCHES.md"
    printf '%s\n' "MIT test license" > "$skill_path/LICENSE"
  fi
}

assert_published_child_and_entry() {
  child_repo=$1
  submodule_path=$2
  old_child_head=$3
  old_entry_head=$4

  new_child_head=$(get_head "$child_repo")
  new_entry_head=$(get_head "$ENTRY_REPO")
  assert_not_equal "$new_child_head" "$old_child_head" "Expected child repository to receive a commit."
  assert_not_equal "$new_entry_head" "$old_entry_head" "Expected entry repository to receive a submodule pointer commit."
  assert_equal "$(get_remote_main "$child_repo")" "$new_child_head" "Expected child commit to be pushed."
  assert_equal "$(get_remote_main "$ENTRY_REPO")" "$new_entry_head" "Expected entry commit to be pushed."
  assert_equal "$(get_submodule_pointer "$ENTRY_REPO" "$submodule_path")" "$new_child_head" "Expected entry submodule pointer to reference child HEAD."
  assert_git_clean "$child_repo"
  assert_git_clean "$ENTRY_REPO"
}

assert_resumed_ahead_child_and_entry() {
  child_repo=$1
  submodule_path=$2
  ahead_child_head=$3
  old_entry_head=$4
  output=$5

  new_entry_head=$(get_head "$ENTRY_REPO")
  assert_equal "$(get_head "$child_repo")" "$ahead_child_head" "Expected child HEAD to remain at the already-created commit."
  assert_equal "$(get_remote_main "$child_repo")" "$ahead_child_head" "Expected interrupted child commit to be pushed on rerun."
  assert_not_equal "$new_entry_head" "$old_entry_head" "Expected entry repository to receive a submodule pointer commit on rerun."
  assert_equal "$(get_remote_main "$ENTRY_REPO")" "$new_entry_head" "Expected entry rerun commit to be pushed."
  assert_equal "$(get_submodule_pointer "$ENTRY_REPO" "$submodule_path")" "$ahead_child_head" "Expected entry submodule pointer to reference ahead child HEAD."
  case "$output" in
    *publish-no-changes*)
      echo "Interrupted publish rerun must not print publish-no-changes." >&2
      exit 1
      ;;
  esac
  assert_git_clean "$child_repo"
  assert_git_clean "$ENTRY_REPO"
}

new_fixture no-child-changes
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
FIRST_PARTY_HEAD=$(get_head "$FIRST_PARTY_REPO")
COMMUNITY_HEAD=$(get_head "$COMMUNITY_REPO")
run_publish_success >/dev/null
assert_equal "$(get_head "$ENTRY_REPO")" "$ENTRY_HEAD" "No child changes should not commit entry."
assert_equal "$(get_head "$FIRST_PARTY_REPO")" "$FIRST_PARTY_HEAD" "No child changes should not commit first-party repo."
assert_equal "$(get_head "$COMMUNITY_REPO")" "$COMMUNITY_HEAD" "No child changes should not commit community repo."

new_fixture first-party-child-change
add_first_party_skill_change publish-ocean-skill unstage
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
CHILD_HEAD=$(get_head "$FIRST_PARTY_REPO")
run_publish_success >/dev/null
assert_published_child_and_entry "$FIRST_PARTY_REPO" repos/oceans-skills "$CHILD_HEAD" "$ENTRY_HEAD"

new_fixture resume-ahead-first-party-child
add_first_party_skill_change ahead-ocean-skill unstage
git_quiet "$FIRST_PARTY_REPO" add skills
git_quiet "$FIRST_PARTY_REPO" commit -m "skills: publish staged first-party skills"
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
AHEAD_CHILD_HEAD=$(get_head "$FIRST_PARTY_REPO")
CHILD_REMOTE_HEAD=$(get_remote_main "$FIRST_PARTY_REPO")
assert_not_equal "$AHEAD_CHILD_HEAD" "$CHILD_REMOTE_HEAD" "Fixture should leave child repo ahead of origin/main."
OUTPUT=$(run_publish_success)
assert_resumed_ahead_child_and_entry "$FIRST_PARTY_REPO" repos/oceans-skills "$AHEAD_CHILD_HEAD" "$ENTRY_HEAD" "$OUTPUT"

new_fixture community-child-change
add_community_skill_change publish-community-skill valid
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
CHILD_HEAD=$(get_head "$COMMUNITY_REPO")
run_publish_success >/dev/null
assert_published_child_and_entry "$COMMUNITY_REPO" repos/community-skills "$CHILD_HEAD" "$ENTRY_HEAD"

new_fixture validate-failure
add_community_skill_change invalid-community-skill invalid
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
CHILD_HEAD=$(get_head "$COMMUNITY_REPO")
run_publish_failure >/dev/null
assert_equal "$(get_head "$ENTRY_REPO")" "$ENTRY_HEAD" "Validate failure should not commit entry."
assert_equal "$(get_head "$COMMUNITY_REPO")" "$CHILD_HEAD" "Validate failure should not commit child."

new_fixture entry-dirty-outside-child-repos
add_first_party_skill_change dirty-blocked-skill unstage
printf '%s\n' "dirty entry file" > "$ENTRY_REPO/ENTRY-DIRTY.txt"
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
CHILD_HEAD=$(get_head "$FIRST_PARTY_REPO")
run_publish_failure >/dev/null
assert_equal "$(get_head "$ENTRY_REPO")" "$ENTRY_HEAD" "Dirty entry repo should not commit entry."
assert_equal "$(get_head "$FIRST_PARTY_REPO")" "$CHILD_HEAD" "Dirty entry repo should not commit child."

new_fixture only-child-staged-skill-changes
add_first_party_skill_change staged-ocean-skill stage
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
CHILD_HEAD=$(get_head "$FIRST_PARTY_REPO")
run_publish_success >/dev/null
assert_published_child_and_entry "$FIRST_PARTY_REPO" repos/oceans-skills "$CHILD_HEAD" "$ENTRY_HEAD"

new_fixture entry-behind-origin-main
OTHER_ENTRY=$WORK_ROOT/other-entry
git_global_quiet clone "$ENTRY_REMOTE" "$OTHER_ENTRY"
git_quiet "$OTHER_ENTRY" config user.email publish-test@example.invalid
git_quiet "$OTHER_ENTRY" config user.name "Publish Test"
printf '%s\n' "remote main advanced" > "$OTHER_ENTRY/REMOTE-AHEAD.txt"
git_quiet "$OTHER_ENTRY" add .
git_quiet "$OTHER_ENTRY" commit -m "advance origin main"
git_quiet "$OTHER_ENTRY" push origin main
add_first_party_skill_change behind-blocked-skill unstage
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
CHILD_HEAD=$(get_head "$FIRST_PARTY_REPO")
run_publish_failure >/dev/null
assert_equal "$(get_head "$ENTRY_REPO")" "$ENTRY_HEAD" "Behind origin/main should not commit entry."
assert_equal "$(get_head "$FIRST_PARTY_REPO")" "$CHILD_HEAD" "Behind origin/main should not commit child."

new_fixture dry-run
add_first_party_skill_change dry-run-skill unstage
ENTRY_HEAD=$(get_head "$ENTRY_REPO")
CHILD_HEAD=$(get_head "$FIRST_PARTY_REPO")
ENTRY_REMOTE_HEAD=$(get_remote_main "$ENTRY_REPO")
CHILD_REMOTE_HEAD=$(get_remote_main "$FIRST_PARTY_REPO")
run_publish_success --dry-run >/dev/null
assert_equal "$(get_head "$ENTRY_REPO")" "$ENTRY_HEAD" "Dry run should not commit entry."
assert_equal "$(get_head "$FIRST_PARTY_REPO")" "$CHILD_HEAD" "Dry run should not commit child."
assert_equal "$(get_remote_main "$ENTRY_REPO")" "$ENTRY_REMOTE_HEAD" "Dry run should not push entry."
assert_equal "$(get_remote_main "$FIRST_PARTY_REPO")" "$CHILD_REMOTE_HEAD" "Dry run should not push child."

echo "Shell publish contract tests passed."
