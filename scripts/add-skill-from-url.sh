#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/skill-publish-rules.sh"
. "$SCRIPT_DIR/skill-catalog.sh"

URL=
SKILL_PATH=
TARGET=community
ACTIVATE=0
ALLOW_RISK=0
DRY_RUN=0
LOCAL_REPOSITORY=
FIRST_PARTY_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_ROOT=$REPO_ROOT/repos/community-skills/skills
CATALOG_ROOT=$REPO_ROOT/catalog

need_value() {
  option=$1
  [ "$#" -ge 2 ] && [ -n "${2:-}" ] || { echo "$option needs a value." >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) need_value "$1" "${2:-}"; URL=$2; shift 2 ;;
    --skill-path) need_value "$1" "${2:-}"; SKILL_PATH=$2; shift 2 ;;
    --target) need_value "$1" "${2:-}"; TARGET=$2; shift 2 ;;
    --activate) ACTIVATE=1; shift ;;
    --allow-risk) ALLOW_RISK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --local-repository) need_value "$1" "${2:-}"; LOCAL_REPOSITORY=$2; shift 2 ;;
    --first-party-root|--first-party-skills-root) need_value "$1" "${2:-}"; FIRST_PARTY_ROOT=$2; shift 2 ;;
    --community-root|--community-skills-root) need_value "$1" "${2:-}"; COMMUNITY_ROOT=$2; shift 2 ;;
    --catalog-root) need_value "$1" "${2:-}"; CATALOG_ROOT=$2; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$URL" ] || { echo "--url is required." >&2; exit 2; }
case "$TARGET" in oceans|community) ;; *) echo "Unsupported target: $TARGET" >&2; exit 2 ;; esac

clean_url=${URL%%\?*}
clean_url=${clean_url%%\#*}
clean_url=${clean_url%/}
case "$clean_url" in
  https://github.com/*/*) ;;
  *) echo "Only https://github.com skill URLs are supported." >&2; exit 1 ;;
esac

url_tail=${clean_url#https://github.com/}
owner=${url_tail%%/*}
repo_and_tail=${url_tail#*/}
repo_segment=${repo_and_tail%%/*}
repo=${repo_segment%.git}
[ -n "$owner" ] && [ -n "$repo" ] || { echo "Invalid GitHub repository URL." >&2; exit 1; }
remaining=${repo_and_tail#"$repo_segment"}
remaining=${remaining#/}
source_ref=
url_skill_path=
case "$remaining" in
  "") ;;
  tree/*)
    tree_tail=${remaining#tree/}
    source_ref=${tree_tail%%/*}
    if [ "$tree_tail" != "$source_ref" ]; then url_skill_path=${tree_tail#*/}; fi
    ;;
  blob/*)
    blob_tail=${remaining#blob/}
    source_ref=${blob_tail%%/*}
    [ "$blob_tail" != "$source_ref" ] || { echo "GitHub blob URL is missing a file path." >&2; exit 1; }
    blob_path=${blob_tail#*/}
    case "$blob_path" in */SKILL.md) url_skill_path=${blob_path%/SKILL.md} ;; SKILL.md) url_skill_path= ;; *) echo "Blob URL must point to SKILL.md." >&2; exit 1 ;; esac
    ;;
  *) echo "Unsupported GitHub URL shape. Use a repository, tree directory, or SKILL.md blob URL." >&2; exit 1 ;;
esac

if [ -n "$SKILL_PATH" ]; then url_skill_path=$SKILL_PATH; fi
case "$url_skill_path" in /*|../*|*/../*|*/..|..) echo "Unsafe skill path: $url_skill_path" >&2; exit 1 ;; esac

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-skill-intake.XXXXXX")
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT HUP INT TERM
CLONE_ROOT=$TEMP_ROOT/repository

if [ -n "$LOCAL_REPOSITORY" ]; then
  [ -d "$LOCAL_REPOSITORY/.git" ] || { echo "--local-repository must point to a Git repository." >&2; exit 1; }
  git clone --quiet "$LOCAL_REPOSITORY" "$CLONE_ROOT"
  if [ -n "$source_ref" ]; then git -C "$CLONE_ROOT" checkout --quiet "$source_ref"; fi
else
  clone_url=https://github.com/$owner/$repo.git
  if [ -n "$source_ref" ]; then
    git clone --quiet --depth 1 --branch "$source_ref" "$clone_url" "$CLONE_ROOT"
  else
    git clone --quiet --depth 1 "$clone_url" "$CLONE_ROOT"
  fi
fi

source_commit=$(git -C "$CLONE_ROOT" rev-parse HEAD)
if [ -z "$source_ref" ]; then source_ref=$(git -C "$CLONE_ROOT" rev-parse --abbrev-ref HEAD); fi

if [ -n "$url_skill_path" ]; then
  source_skill=$CLONE_ROOT/$url_skill_path
  [ -d "$source_skill" ] && [ -f "$source_skill/SKILL.md" ] || {
    echo "The selected path does not contain SKILL.md: $url_skill_path" >&2
    exit 1
  }
elif [ -f "$CLONE_ROOT/SKILL.md" ]; then
  source_skill=$CLONE_ROOT
  url_skill_path=.
else
  matches_file=$TEMP_ROOT/matches
  find "$CLONE_ROOT" -type f -name SKILL.md -not -path '*/.git/*' -print > "$matches_file"
  match_count=$(awk 'NF { count++ } END { print count + 0 }' "$matches_file")
  if [ "$match_count" -eq 0 ]; then
    echo "No SKILL.md was found in the repository." >&2
    exit 1
  fi
  if [ "$match_count" -gt 1 ]; then
    echo "Multiple skills were found; rerun with --skill-path." >&2
    sed "s|^$CLONE_ROOT/||" "$matches_file" >&2
    exit 1
  fi
  skill_file=$(sed -n '1p' "$matches_file")
  source_skill=${skill_file%/SKILL.md}
  url_skill_path=${source_skill#"$CLONE_ROOT"/}
fi

skill_name=$(oceans_frontmatter_value "$source_skill" name || true)
[ -n "$skill_name" ] || { echo "The selected SKILL.md has no name." >&2; exit 1; }
oceans_valid_skill_name "$skill_name" || { echo "Invalid skill name: $skill_name" >&2; exit 1; }
metadata_issues=$(oceans_skill_metadata_issues "$source_skill" "$skill_name")
[ -z "$metadata_issues" ] || { echo "Invalid skill metadata: $skill_name" >&2; printf '%s\n' "$metadata_issues" >&2; exit 1; }

if state=$(oceans_catalog_state_for_skill "$CATALOG_ROOT" "$skill_name"); then
  echo "Skill already exists in catalog state $state: $skill_name" >&2
  exit 1
else
  catalog_status=$?
  [ "$catalog_status" -eq 1 ] || { echo "Skill exists in multiple catalog states: $skill_name" >&2; exit 1; }
fi

PREPARED_ROOT=$TEMP_ROOT/prepared
PREPARED_SKILL=$PREPARED_ROOT/$skill_name
mkdir -p "$PREPARED_SKILL"
cp -R "$source_skill"/. "$PREPARED_SKILL"
rm -rf "$PREPARED_SKILL/.git"

if [ "$TARGET" = community ]; then
  if [ ! -s "$PREPARED_SKILL/LICENSE" ]; then
    license_source=
    for candidate in LICENSE LICENSE.md LICENSE.txt COPYING COPYING.md; do
      if [ -s "$CLONE_ROOT/$candidate" ]; then license_source=$CLONE_ROOT/$candidate; break; fi
    done
    [ -n "$license_source" ] || { echo "Community skill has no preserved license file." >&2; exit 1; }
    cp "$license_source" "$PREPARED_SKILL/LICENSE"
  fi
  if [ ! -s "$PREPARED_SKILL/UPSTREAM.md" ]; then
    cat > "$PREPARED_SKILL/UPSTREAM.md" <<UPSTREAM
# Upstream

- Repository: https://github.com/$owner/$repo
- Submitted URL: $clean_url
- Author or owner: $owner
- Imported commit: $source_commit
- Imported path: $url_skill_path
- License: preserved in LICENSE
UPSTREAM
  fi
  if [ ! -s "$PREPARED_SKILL/PATCHES.md" ]; then
    cat > "$PREPARED_SKILL/PATCHES.md" <<PATCHES
# Local changes

- Added oceans777 packaging and attribution metadata during intake.
- No functional source changes were made by the intake command.
PATCHES
  fi
fi

set -- --source-root "$PREPARED_ROOT" --skill "$skill_name" --target "$TARGET" \
  --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT"
if [ "$ALLOW_RISK" -eq 1 ]; then set -- "$@" --allow-risk; fi
if [ "$DRY_RUN" -eq 1 ]; then set -- "$@" --dry-run; fi
sh "$SCRIPT_DIR/stage-skill.sh" "$@"

state=pending-review
[ "$ACTIVATE" -eq 1 ] && state=active
repository=community-skills
[ "$TARGET" = oceans ] && repository=oceans-skills
if [ "$DRY_RUN" -eq 1 ]; then
  echo "catalog-plan-state: $state"
  echo "catalog-plan-skill: $skill_name"
  exit 0
fi

target_root=$COMMUNITY_ROOT
[ "$TARGET" = oceans ] && target_root=$FIRST_PARTY_ROOT
if ! oceans_catalog_write_record "$CATALOG_ROOT" "$state" "$skill_name" "$repository" \
  "$clean_url" "skills/$skill_name" "$source_ref" "$source_commit" "" ""; then
  rm -rf "$target_root/$skill_name"
  echo "Catalog registration failed; staged skill was rolled back: $skill_name" >&2
  exit 1
fi

echo "added-skill: $skill_name"
echo "catalog-state: $state"
echo "source-commit: $source_commit"
if [ "$state" = pending-review ]; then
  echo "next: review files, then run ./oceans catalog activate --skill $skill_name"
else
  echo "next: run ./oceans validate, then ./oceans publish"
fi
