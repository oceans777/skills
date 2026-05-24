#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
FIRST_PARTY_REPO_PATH=repos/oceans-skills
COMMUNITY_REPO_PATH=repos/community-skills
DRY_RUN=0

. "$SCRIPT_DIR/common.sh"

need_value() {
  option=$1
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    echo "$option needs a value." >&2
    exit 2
  fi
}

absolute_path() {
  path=$1
  if [ -d "$path" ]; then
    (CDPATH= cd "$path" && pwd -P)
    return
  fi

  parent=$(dirname "$path")
  leaf=$(basename "$path")
  if [ -d "$parent" ]; then
    parent_abs=$(CDPATH= cd "$parent" && pwd -P)
    printf '%s/%s\n' "$parent_abs" "$leaf"
    return
  fi

  case "$path" in
    /*)
      printf '%s\n' "$path"
      ;;
    *)
      printf '%s/%s\n' "$(pwd -P)" "$path"
      ;;
  esac
}

resolve_repo_path() {
  root=$1
  path=$2

  case "$path" in
    /*|[A-Za-z]:*)
      absolute_path "$path"
      ;;
    *)
      absolute_path "$root/$path"
      ;;
  esac
}

relative_git_path() {
  root=$(absolute_path "$1")
  path=$(absolute_path "$2")

  case "$path" in
    "$root")
      printf '.\n'
      ;;
    "$root"/*)
      rel=${path#"$root"/}
      printf '%s\n' "$rel"
      ;;
    *)
      echo "Repository path is outside repo root: $path" >&2
      exit 1
      ;;
  esac
}

assert_on_main() {
  repo=$1
  name=$2

  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  if [ "$branch" != "main" ]; then
    echo "publish-not-main: $name"
    exit 1
  fi
}

assert_origin_remote() {
  repo=$1
  name=$2

  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    echo "publish-missing-origin: $name"
    exit 1
  fi
}

update_origin_main() {
  repo=$1
  name=$2

  invoke_git_with_retry "fetch origin main for $name" 3 1 -C "$repo" fetch --quiet origin main
}

assert_not_behind_origin_main() {
  repo=$1
  name=$2

  if ! git -C "$repo" merge-base --is-ancestor origin/main HEAD >/dev/null 2>&1; then
    echo "publish-behind-origin-main: $name"
    exit 1
  fi
}

is_allowed_path() {
  path=$(printf '%s' "$1" | sed 's/^"//; s/"$//; s|\\|/|g')
  shift

  for allowed_root in "$@"; do
    allowed=$(printf '%s' "$allowed_root" | sed 's|\\|/|g; s|/*$||')
    case "$path" in
      "$allowed"|"$allowed"/*)
        return 0
        ;;
    esac
  done

  return 1
}

assert_repo_clean_outside_paths() {
  repo=$1
  name=$2
  shift 2

  status=$(git -C "$repo" status --porcelain --untracked-files=all)
  [ -n "$status" ] || return 0

  old_ifs=$IFS
  IFS='
'
  for line in $status; do
    path=$(printf '%s' "$line" | cut -c4-)
    case "$path" in
      *" -> "*)
        old_path=${path%% -> *}
        new_path=${path##* -> }
        if ! is_allowed_path "$old_path" "$@" || ! is_allowed_path "$new_path" "$@"; then
          IFS=$old_ifs
          echo "publish-dirty-outside-allowed-paths: $name"
          exit 1
        fi
        ;;
      *)
        if ! is_allowed_path "$path" "$@"; then
          IFS=$old_ifs
          echo "publish-dirty-outside-allowed-paths: $name"
          exit 1
        fi
        ;;
    esac
  done
  IFS=$old_ifs
}

repo_has_changes_under_path() {
  repo=$1
  path=$2

  [ -n "$(git -C "$repo" status --porcelain --untracked-files=all -- "$path")" ]
}

staged_changes_under_path() {
  repo=$1
  path=$2

  set +e
  git -C "$repo" diff --cached --quiet -- "$path"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    return 1
  fi

  if [ "$status" -eq 1 ]; then
    return 0
  fi

  echo "git diff --cached failed for $repo." >&2
  exit "$status"
}

repo_head_differs_from_origin_main() {
  repo=$1

  head=$(git -C "$repo" rev-parse HEAD)
  origin_main=$(git -C "$repo" rev-parse origin/main)
  [ "$head" != "$origin_main" ]
}

publish_child_repository() {
  repo=$1
  name=$2
  message=$3
  has_working_tree_changes=$4
  is_ahead_of_origin=$5

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry_run: true"
    if [ "$has_working_tree_changes" -eq 1 ]; then
      echo "plan-commit-child: $name"
    fi
    if [ "$has_working_tree_changes" -eq 1 ] || [ "$is_ahead_of_origin" -eq 1 ]; then
      echo "plan-push-child: $name"
    fi
    return
  fi

  if [ "$has_working_tree_changes" -eq 1 ]; then
    invoke_git "stage $name skills" -C "$repo" add skills
    if staged_changes_under_path "$repo" skills; then
      invoke_git "commit $name skills" -C "$repo" commit -m "$message"
    fi
  fi

  if repo_head_differs_from_origin_main "$repo"; then
    invoke_git_with_retry "push $name main" 3 1 -C "$repo" push --quiet origin main
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --repo-root)
      need_value "$1" "${2:-}"
      REPO_ROOT=$2
      shift 2
      ;;
    --first-party-repo)
      need_value "$1" "${2:-}"
      FIRST_PARTY_REPO_PATH=$2
      shift 2
      ;;
    --community-repo)
      need_value "$1" "${2:-}"
      COMMUNITY_REPO_PATH=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT=$(absolute_path "$REPO_ROOT")
FIRST_PARTY_REPO=$(resolve_repo_path "$REPO_ROOT" "$FIRST_PARTY_REPO_PATH")
COMMUNITY_REPO=$(resolve_repo_path "$REPO_ROOT" "$COMMUNITY_REPO_PATH")
FIRST_PARTY_REL=$(relative_git_path "$REPO_ROOT" "$FIRST_PARTY_REPO")
COMMUNITY_REL=$(relative_git_path "$REPO_ROOT" "$COMMUNITY_REPO")

for repo_info in \
  "entry|$REPO_ROOT" \
  "oceans-skills|$FIRST_PARTY_REPO" \
  "community-skills|$COMMUNITY_REPO"
do
  name=${repo_info%%|*}
  repo=${repo_info#*|}
  assert_on_main "$repo" "$name"
  assert_origin_remote "$repo" "$name"
  update_origin_main "$repo" "$name"
  assert_not_behind_origin_main "$repo" "$name"
done

assert_repo_clean_outside_paths "$REPO_ROOT" entry "$FIRST_PARTY_REL" "$COMMUNITY_REL"
assert_repo_clean_outside_paths "$FIRST_PARTY_REPO" oceans-skills skills
assert_repo_clean_outside_paths "$COMMUNITY_REPO" community-skills skills

sh "$SCRIPT_DIR/validate-skills.sh" \
  --first-party-root "$FIRST_PARTY_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills"

FIRST_PARTY_CHANGED=0
COMMUNITY_CHANGED=0
FIRST_PARTY_AHEAD=0
COMMUNITY_AHEAD=0
ENTRY_SUBMODULE_CHANGED=0
ENTRY_AHEAD=0
if repo_has_changes_under_path "$FIRST_PARTY_REPO" skills; then
  FIRST_PARTY_CHANGED=1
fi
if repo_has_changes_under_path "$COMMUNITY_REPO" skills; then
  COMMUNITY_CHANGED=1
fi
if repo_head_differs_from_origin_main "$FIRST_PARTY_REPO"; then
  FIRST_PARTY_AHEAD=1
fi
if repo_head_differs_from_origin_main "$COMMUNITY_REPO"; then
  COMMUNITY_AHEAD=1
fi
if repo_has_changes_under_path "$REPO_ROOT" "$FIRST_PARTY_REL" || \
   repo_has_changes_under_path "$REPO_ROOT" "$COMMUNITY_REL"; then
  ENTRY_SUBMODULE_CHANGED=1
fi
if repo_head_differs_from_origin_main "$REPO_ROOT"; then
  ENTRY_AHEAD=1
fi

if [ "$FIRST_PARTY_CHANGED" -eq 0 ] && [ "$COMMUNITY_CHANGED" -eq 0 ] && \
   [ "$FIRST_PARTY_AHEAD" -eq 0 ] && [ "$COMMUNITY_AHEAD" -eq 0 ] && \
   [ "$ENTRY_SUBMODULE_CHANGED" -eq 0 ] && [ "$ENTRY_AHEAD" -eq 0 ]; then
  echo "publish-no-changes"
  exit 0
fi

if [ "$FIRST_PARTY_CHANGED" -eq 1 ] || [ "$FIRST_PARTY_AHEAD" -eq 1 ]; then
  publish_child_repository "$FIRST_PARTY_REPO" oceans-skills "skills: publish staged first-party skills" "$FIRST_PARTY_CHANGED" "$FIRST_PARTY_AHEAD"
fi

if [ "$COMMUNITY_CHANGED" -eq 1 ] || [ "$COMMUNITY_AHEAD" -eq 1 ]; then
  publish_child_repository "$COMMUNITY_REPO" community-skills "skills: publish staged community skills" "$COMMUNITY_CHANGED" "$COMMUNITY_AHEAD"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "plan-commit-entry: repos: update skill submodules"
  echo "plan-push-entry: entry"
  exit 0
fi

invoke_git "stage skill submodules" -C "$REPO_ROOT" add "$FIRST_PARTY_REL" "$COMMUNITY_REL"

if staged_changes_under_path "$REPO_ROOT" "$FIRST_PARTY_REL" || \
   staged_changes_under_path "$REPO_ROOT" "$COMMUNITY_REL"; then
  invoke_git "commit skill submodule updates" -C "$REPO_ROOT" commit -m "repos: update skill submodules"
fi

if repo_head_differs_from_origin_main "$REPO_ROOT"; then
  invoke_git_with_retry "push entry main" 3 1 -C "$REPO_ROOT" push --quiet origin main
fi
