#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
DEFAULT_REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$DEFAULT_REPO_ROOT
FIRST_PARTY_REPO_PATH=repos/oceans-skills
COMMUNITY_REPO_PATH=repos/community-skills
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --repo-root) [ "$#" -ge 2 ] || { echo "--repo-root needs a path." >&2; exit 2; }; REPO_ROOT=$2; shift 2 ;;
    --first-party-repo) [ "$#" -ge 2 ] || { echo "--first-party-repo needs a path." >&2; exit 2; }; FIRST_PARTY_REPO_PATH=$2; shift 2 ;;
    --community-repo) [ "$#" -ge 2 ] || { echo "--community-repo needs a path." >&2; exit 2; }; COMMUNITY_REPO_PATH=$2; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

absolute_path() {
  path=$1
  if [ -d "$path" ]; then (CDPATH= cd "$path" && pwd -P); return; fi
  parent=$(dirname "$path")
  leaf=$(basename "$path")
  if [ -d "$parent" ]; then printf '%s/%s\n' "$(CDPATH= cd "$parent" && pwd -P)" "$leaf"; return; fi
  case "$path" in /*) printf '%s\n' "$path" ;; *) printf '%s/%s\n' "$(pwd -P)" "$path" ;; esac
}

resolve_repo_path() {
  root=$1
  path=$2
  case "$path" in /*|[A-Za-z]:*) absolute_path "$path" ;; *) absolute_path "$root/$path" ;; esac
}

REPO_ROOT=$(absolute_path "$REPO_ROOT")
FIRST_PARTY_REPO=$(resolve_repo_path "$REPO_ROOT" "$FIRST_PARTY_REPO_PATH")
COMMUNITY_REPO=$(resolve_repo_path "$REPO_ROOT" "$COMMUNITY_REPO_PATH")
CATALOG_ROOT=$REPO_ROOT/catalog

set -- --repo-root "$REPO_ROOT" --first-party-repo "$FIRST_PARTY_REPO" --community-repo "$COMMUNITY_REPO"
[ "$DRY_RUN" -eq 0 ] || set -- "$@" --dry-run

if [ ! -d "$CATALOG_ROOT" ] || [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- catalog)" ]; then
  exec sh "$SCRIPT_DIR/publish-skills.sh" "$@"
fi

sh "$SCRIPT_DIR/validate-skills.sh" \
  --first-party-root "$FIRST_PARTY_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills" \
  --catalog-root "$CATALOG_ROOT"

stash_before=$(git -C "$REPO_ROOT" rev-parse -q --verify refs/stash 2>/dev/null || true)
git -C "$REPO_ROOT" stash push -u -m oceans-catalog-publish -- catalog >/dev/null
stash_after=$(git -C "$REPO_ROOT" rev-parse -q --verify refs/stash 2>/dev/null || true)
if [ -z "$stash_after" ] || [ "$stash_after" = "$stash_before" ]; then
  echo "Failed to isolate catalog changes for publishing." >&2
  exit 1
fi
stash_active=1

restore_catalog() {
  [ "${stash_active:-0}" -eq 1 ] || return 0
  if git -C "$REPO_ROOT" stash apply --index "$stash_after" >/dev/null; then
    git -C "$REPO_ROOT" stash drop "$stash_after" >/dev/null
    stash_active=0
    return 0
  fi
  echo "Failed to restore catalog changes from $stash_after." >&2
  return 1
}

trap 'restore_catalog' EXIT HUP INT TERM

sh "$SCRIPT_DIR/publish-skills.sh" "$@"
restore_catalog
trap - EXIT HUP INT TERM

sh "$SCRIPT_DIR/validate-skills.sh" \
  --first-party-root "$FIRST_PARTY_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills" \
  --catalog-root "$CATALOG_ROOT"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "plan-commit-entry-catalog: catalog: update skill lifecycle"
  echo "plan-push-entry-catalog: entry"
  exit 0
fi

git -C "$REPO_ROOT" add catalog
if ! git -C "$REPO_ROOT" diff --cached --quiet -- catalog; then
  git -C "$REPO_ROOT" commit -m "catalog: update skill lifecycle"
fi
if ! git -C "$REPO_ROOT" diff --quiet origin/main..HEAD -- .; then
  git -C "$REPO_ROOT" push --quiet origin main
fi
