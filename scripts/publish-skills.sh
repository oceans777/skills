#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
FIRST_PARTY_REPO_PATH=
COMMUNITY_REPO_PATH=repos/community-skills
CATALOG_PATH=catalog
DRY_RUN=0
. "$SCRIPT_DIR/common.sh"

need_value() {
  option=$1
  [ "$#" -ge 2 ] && [ -n "${2:-}" ] || { echo "$option needs a value." >&2; exit 2; }
}

absolute_path() {
  path=$1
  if [ -d "$path" ]; then (CDPATH= cd "$path" && pwd -P); return; fi
  parent=$(dirname "$path"); leaf=$(basename "$path")
  if [ -d "$parent" ]; then printf '%s/%s\n' "$(CDPATH= cd "$parent" && pwd -P)" "$leaf"; return; fi
  case "$path" in /*) printf '%s\n' "$path" ;; *) printf '%s/%s\n' "$(pwd -P)" "$path" ;; esac
}

resolve_repo_path() {
  root=$1; path=$2
  case "$path" in /*|[A-Za-z]:*) absolute_path "$path" ;; *) absolute_path "$root/$path" ;; esac
}

relative_git_path() {
  root=$(absolute_path "$1"); path=$(absolute_path "$2")
  case "$path" in "$root") printf '.\n' ;; "$root"/*) printf '%s\n' "${path#"$root"/}" ;; *) echo "Repository path is outside repo root: $path" >&2; exit 1 ;; esac
}

assert_on_main() {
  repo=$1; name=$2
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  [ "$branch" = main ] || { echo "publish-not-main: $name" >&2; exit 1; }
}

assert_origin_remote() {
  repo=$1; name=$2
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || { echo "publish-missing-origin: $name" >&2; exit 1; }
}

update_origin_main() {
  repo=$1; name=$2
  invoke_git_with_retry "fetch origin main for $name" 3 1 -C "$repo" fetch --quiet origin main
}

assert_not_behind_origin_main() {
  repo=$1; name=$2
  git -C "$repo" merge-base --is-ancestor origin/main HEAD >/dev/null 2>&1 || { echo "publish-behind-origin-main: $name" >&2; exit 1; }
}

is_allowed_path() {
  path=$(printf '%s' "$1" | sed 's/^"//; s/"$//; s|\\|/|g')
  shift
  for allowed_root in "$@"; do
    allowed=$(printf '%s' "$allowed_root" | sed 's|\\|/|g; s|/*$||')
    case "$path" in "$allowed"|"$allowed"/*) return 0 ;; esac
  done
  return 1
}

assert_repo_clean_outside_paths() {
  repo=$1; name=$2; shift 2
  status=$(git -C "$repo" status --porcelain --untracked-files=all)
  [ -n "$status" ] || return 0
  old_ifs=$IFS
  IFS='
'
  for line in $status; do
    path=$(printf '%s' "$line" | cut -c4-)
    case "$path" in
      *" -> "*) old_path=${path%% -> *}; new_path=${path##* -> }; is_allowed_path "$old_path" "$@" && is_allowed_path "$new_path" "$@" || { IFS=$old_ifs; echo "publish-dirty-outside-allowed-paths: $name" >&2; exit 1; } ;;
      *) is_allowed_path "$path" "$@" || { IFS=$old_ifs; echo "publish-dirty-outside-allowed-paths: $name" >&2; exit 1; } ;;
    esac
  done
  IFS=$old_ifs
}

assert_ahead_changes_inside_paths() {
  repo=$1; name=$2; shift 2
  head=$(git -C "$repo" rev-parse HEAD); origin_main=$(git -C "$repo" rev-parse origin/main)
  [ "$head" != "$origin_main" ] || return 0
  diff_paths=$(git -C "$repo" -c core.quotePath=false diff --name-only origin/main..HEAD -- .)
  old_ifs=$IFS
  IFS='
'
  for path in $diff_paths; do
    [ -n "$path" ] || continue
    is_allowed_path "$path" "$@" || { IFS=$old_ifs; echo "publish-ahead-outside-allowed-paths: $name" >&2; echo "ahead_path: $path" >&2; exit 1; }
  done
  IFS=$old_ifs
}

repo_has_changes_under_path() {
  repo=$1; path=$2
  [ -n "$(git -C "$repo" status --porcelain --untracked-files=all -- "$path")" ]
}

repo_ahead() {
  repo=$1
  [ "$(git -C "$repo" rev-parse HEAD)" != "$(git -C "$repo" rev-parse origin/main)" ]
}

staged_changes_under_path() {
  repo=$1; path=$2
  set +e
  git -C "$repo" diff --cached --quiet -- "$path"
  status=$?
  set -e
  [ "$status" -eq 1 ] && return 0
  [ "$status" -eq 0 ] && return 1
  echo "git diff --cached failed for $repo." >&2
  exit "$status"
}

prepare_child_commit() {
  repo=$1; name=$2; message=$3
  if repo_has_changes_under_path "$repo" skills; then
    invoke_git "stage $name skills" -C "$repo" add skills
    if staged_changes_under_path "$repo" skills; then invoke_git "commit $name skills" -C "$repo" commit -m "$message"; fi
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --repo-root) need_value "$1" "${2:-}"; REPO_ROOT=$2; shift 2 ;;
    --first-party-repo) need_value "$1" "${2:-}"; FIRST_PARTY_REPO_PATH=$2; shift 2 ;;
    --community-repo) need_value "$1" "${2:-}"; COMMUNITY_REPO_PATH=$2; shift 2 ;;
    --catalog-path) need_value "$1" "${2:-}"; CATALOG_PATH=$2; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

publish_discovered_skill_repos() {
  [ -f "$REPO_ROOT/.gitmodules" ] || { echo "publish-missing-gitmodules" >&2; exit 1; }
  names_file=$(mktemp "${TMPDIR:-/tmp}/oceans-publish-skills.XXXXXX") || exit 1
  git config -f "$REPO_ROOT/.gitmodules" --get-regexp '^submodule\..*\.path$' | while read -r _key path; do
    case "$path" in
      repos/community-skills|repos/oceans-skills) ;;
      repos/*)
        name=${path#repos/}
        case "$name" in */*) ;; *) printf '%s\n' "$name" ;; esac
        ;;
    esac
  done > "$names_file"

  assert_on_main "$REPO_ROOT" entry
  assert_origin_remote "$REPO_ROOT" entry
  update_origin_main "$REPO_ROOT" entry
  assert_not_behind_origin_main "$REPO_ROOT" entry
  assert_on_main "$COMMUNITY_REPO" community-skills
  assert_origin_remote "$COMMUNITY_REPO" community-skills
  update_origin_main "$COMMUNITY_REPO" community-skills
  assert_not_behind_origin_main "$COMMUNITY_REPO" community-skills

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    repo=$REPO_ROOT/repos/$name
    assert_on_main "$repo" "$name"
    assert_origin_remote "$repo" "$name"
    update_origin_main "$repo" "$name"
    assert_not_behind_origin_main "$repo" "$name"
  done < "$names_file"

  set -- catalog "$COMMUNITY_REL"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    set -- "$@" "repos/$name"
  done < "$names_file"
  assert_repo_clean_outside_paths "$REPO_ROOT" entry "$@"
  assert_repo_clean_outside_paths "$COMMUNITY_REPO" community-skills skills
  assert_ahead_changes_inside_paths "$REPO_ROOT" entry "$@"
  assert_ahead_changes_inside_paths "$COMMUNITY_REPO" community-skills skills

  sh "$SCRIPT_DIR/validate-skills.sh" \
    --first-party-root "$REPO_ROOT/repos" \
    --community-root "$COMMUNITY_REPO/skills" \
    --catalog-root "$CATALOG_ROOT"

  skill_changed=0
  community_changed=0
  entry_changed=0
  repo_has_changes_under_path "$COMMUNITY_REPO" skills && community_changed=1
  entry_skill_changed=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if repo_has_changes_under_path "$REPO_ROOT" "repos/$name"; then entry_skill_changed=1; fi
  done < "$names_file"
  if [ "$entry_skill_changed" -eq 1 ] || repo_has_changes_under_path "$REPO_ROOT" "$COMMUNITY_REL" || repo_has_changes_under_path "$REPO_ROOT" "$CATALOG_PATH"; then
    entry_changed=1
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if repo_has_changes_under_path "$REPO_ROOT/repos/$name" . || repo_ahead "$REPO_ROOT/repos/$name"; then skill_changed=1; fi
  done < "$names_file"
  community_ahead=0
  entry_ahead=0
  repo_ahead "$COMMUNITY_REPO" && community_ahead=1
  repo_ahead "$REPO_ROOT" && entry_ahead=1

  if [ "$skill_changed" -eq 0 ] && [ "$community_changed" -eq 0 ] && [ "$entry_changed" -eq 0 ] && [ "$community_ahead" -eq 0 ] && [ "$entry_ahead" -eq 0 ]; then
    rm -f "$names_file"
    echo "publish-no-changes"
    exit 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      repo=$REPO_ROOT/repos/$name
      if repo_has_changes_under_path "$repo" .; then echo "plan-commit-child: $name"; fi
      if repo_has_changes_under_path "$repo" . || repo_ahead "$repo"; then echo "plan-push-child: $name"; fi
    done < "$names_file"
    [ "$community_changed" -eq 0 ] || echo "plan-commit-child: community-skills"
    [ "$community_changed" -eq 0 ] && [ "$community_ahead" -eq 0 ] || echo "plan-push-child: community-skills"
    echo "plan-commit-entry: release: publish skills and catalog"
    echo "plan-push-entry-last: entry"
    rm -f "$names_file"
    exit 0
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    repo=$REPO_ROOT/repos/$name
    if repo_has_changes_under_path "$repo" .; then
      invoke_git "stage $name" -C "$repo" add -A
      if staged_changes_under_path "$repo" .; then
        invoke_git "commit $name" -C "$repo" commit -m "skills: publish $name"
      fi
    fi
  done < "$names_file"
  prepare_child_commit "$COMMUNITY_REPO" community-skills "skills: publish staged community skills"

  sh "$SCRIPT_DIR/validate-skills.sh" \
    --first-party-root "$REPO_ROOT/repos" \
    --community-root "$COMMUNITY_REPO/skills" \
    --catalog-root "$CATALOG_ROOT"

  invoke_git "stage entry release state" -C "$REPO_ROOT" add catalog "$COMMUNITY_REL"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    invoke_git "stage entry pin $name" -C "$REPO_ROOT" add "repos/$name"
  done < "$names_file"
  entry_needs_commit=0
  if repo_has_changes_under_path "$REPO_ROOT" catalog || repo_has_changes_under_path "$REPO_ROOT" "$COMMUNITY_REL"; then
    entry_needs_commit=1
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if repo_has_changes_under_path "$REPO_ROOT" "repos/$name"; then entry_needs_commit=1; fi
  done < "$names_file"
  if [ "$entry_needs_commit" -eq 1 ]; then
    invoke_git "commit entry release state" -C "$REPO_ROOT" commit -m "release: publish skills and catalog"
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    repo=$REPO_ROOT/repos/$name
    if repo_ahead "$repo"; then invoke_git_with_retry "push $name main" 3 1 -C "$repo" push --quiet origin main; fi
  done < "$names_file"
  if repo_ahead "$COMMUNITY_REPO"; then invoke_git_with_retry "push community-skills main" 3 1 -C "$COMMUNITY_REPO" push --quiet origin main; fi
  if repo_ahead "$REPO_ROOT"; then invoke_git_with_retry "push entry main last" 3 1 -C "$REPO_ROOT" push --quiet origin main; fi
  rm -f "$names_file"
}

REPO_ROOT=$(absolute_path "$REPO_ROOT")
COMMUNITY_REPO=$(resolve_repo_path "$REPO_ROOT" "$COMMUNITY_REPO_PATH")
COMMUNITY_REL=$(relative_git_path "$REPO_ROOT" "$COMMUNITY_REPO")
CATALOG_ROOT=$REPO_ROOT/$CATALOG_PATH
if [ -z "$FIRST_PARTY_REPO_PATH" ]; then
  publish_discovered_skill_repos
  exit 0
fi
FIRST_PARTY_REPO=$(resolve_repo_path "$REPO_ROOT" "$FIRST_PARTY_REPO_PATH")
FIRST_PARTY_REL=$(relative_git_path "$REPO_ROOT" "$FIRST_PARTY_REPO")

for repo_info in "entry|$REPO_ROOT" "oceans-skills|$FIRST_PARTY_REPO" "community-skills|$COMMUNITY_REPO"; do
  name=${repo_info%%|*}; repo=${repo_info#*|}
  assert_on_main "$repo" "$name"
  assert_origin_remote "$repo" "$name"
  update_origin_main "$repo" "$name"
  assert_not_behind_origin_main "$repo" "$name"
done

assert_repo_clean_outside_paths "$REPO_ROOT" entry "$FIRST_PARTY_REL" "$COMMUNITY_REL" "$CATALOG_PATH"
assert_repo_clean_outside_paths "$FIRST_PARTY_REPO" oceans-skills skills
assert_repo_clean_outside_paths "$COMMUNITY_REPO" community-skills skills
assert_ahead_changes_inside_paths "$REPO_ROOT" entry "$FIRST_PARTY_REL" "$COMMUNITY_REL" "$CATALOG_PATH"
assert_ahead_changes_inside_paths "$FIRST_PARTY_REPO" oceans-skills skills
assert_ahead_changes_inside_paths "$COMMUNITY_REPO" community-skills skills

sh "$SCRIPT_DIR/validate-skills.sh" \
  --first-party-root "$FIRST_PARTY_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills" \
  --catalog-root "$CATALOG_ROOT"

FIRST_PARTY_CHANGED=0; COMMUNITY_CHANGED=0; ENTRY_CHANGED=0
repo_has_changes_under_path "$FIRST_PARTY_REPO" skills && FIRST_PARTY_CHANGED=1
repo_has_changes_under_path "$COMMUNITY_REPO" skills && COMMUNITY_CHANGED=1
if repo_has_changes_under_path "$REPO_ROOT" "$FIRST_PARTY_REL" || repo_has_changes_under_path "$REPO_ROOT" "$COMMUNITY_REL" || repo_has_changes_under_path "$REPO_ROOT" "$CATALOG_PATH"; then ENTRY_CHANGED=1; fi
FIRST_PARTY_AHEAD=0; COMMUNITY_AHEAD=0; ENTRY_AHEAD=0
repo_ahead "$FIRST_PARTY_REPO" && FIRST_PARTY_AHEAD=1
repo_ahead "$COMMUNITY_REPO" && COMMUNITY_AHEAD=1
repo_ahead "$REPO_ROOT" && ENTRY_AHEAD=1

if [ "$FIRST_PARTY_CHANGED" -eq 0 ] && [ "$COMMUNITY_CHANGED" -eq 0 ] && [ "$ENTRY_CHANGED" -eq 0 ] && [ "$FIRST_PARTY_AHEAD" -eq 0 ] && [ "$COMMUNITY_AHEAD" -eq 0 ] && [ "$ENTRY_AHEAD" -eq 0 ]; then
  echo "publish-no-changes"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  [ "$FIRST_PARTY_CHANGED" -eq 0 ] || echo "plan-commit-child: oceans-skills"
  [ "$COMMUNITY_CHANGED" -eq 0 ] || echo "plan-commit-child: community-skills"
  [ "$FIRST_PARTY_CHANGED" -eq 0 ] && [ "$FIRST_PARTY_AHEAD" -eq 0 ] || echo "plan-push-child: oceans-skills"
  [ "$COMMUNITY_CHANGED" -eq 0 ] && [ "$COMMUNITY_AHEAD" -eq 0 ] || echo "plan-push-child: community-skills"
  echo "plan-commit-entry: release: publish skills and catalog"
  echo "plan-push-entry-last: entry"
  exit 0
fi

prepare_child_commit "$FIRST_PARTY_REPO" oceans-skills "skills: publish staged first-party skills"
prepare_child_commit "$COMMUNITY_REPO" community-skills "skills: publish staged community skills"

# Revalidate the exact child commits and catalog before creating the visible entry commit.
sh "$SCRIPT_DIR/validate-skills.sh" \
  --first-party-root "$FIRST_PARTY_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills" \
  --catalog-root "$CATALOG_ROOT"

invoke_git "stage entry release state" -C "$REPO_ROOT" add "$FIRST_PARTY_REL" "$COMMUNITY_REL" "$CATALOG_PATH"
if staged_changes_under_path "$REPO_ROOT" "$FIRST_PARTY_REL" || staged_changes_under_path "$REPO_ROOT" "$COMMUNITY_REL" || staged_changes_under_path "$REPO_ROOT" "$CATALOG_PATH"; then
  invoke_git "commit entry release state" -C "$REPO_ROOT" commit -m "release: publish skills and catalog"
fi

# Child commits may become orphaned on failure, but users remain on the old consistent entry commit.
if repo_ahead "$FIRST_PARTY_REPO"; then invoke_git_with_retry "push oceans-skills main" 3 1 -C "$FIRST_PARTY_REPO" push --quiet origin main; fi
if repo_ahead "$COMMUNITY_REPO"; then invoke_git_with_retry "push community-skills main" 3 1 -C "$COMMUNITY_REPO" push --quiet origin main; fi
if repo_ahead "$REPO_ROOT"; then invoke_git_with_retry "push entry main last" 3 1 -C "$REPO_ROOT" push --quiet origin main; fi
