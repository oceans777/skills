#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/skill-publish-rules.sh"
. "$SCRIPT_DIR/skill-catalog.sh"
. "$SCRIPT_DIR/directory-transaction.sh"

URL=
SKILL_PATH=
SOURCE_REF_OVERRIDE=
TARGET=community
ALLOW_RISK=0
REPLACE_EXISTING=0
ALLOW_SOURCE_CHANGE=0
DRY_RUN=0
LOCAL_REPOSITORY=
CATALOG_ROOT=$REPO_ROOT/catalog
MAX_FILES=${OCEANS_INTAKE_MAX_FILES:-1000}
MAX_BYTES=${OCEANS_INTAKE_MAX_BYTES:-20971520}
TEMP_ROOT=
LOCK_HELD=0

cleanup() {
  [ "$LOCK_HELD" -eq 0 ] || oceans_catalog_release_lock
  [ -z "$TEMP_ROOT" ] || rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

need_value() {
  option=$1
  [ "$#" -ge 2 ] && [ -n "${2:-}" ] || { echo "$option needs a value." >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) need_value "$1" "${2:-}"; URL=$2; shift 2 ;;
    --skill-path) need_value "$1" "${2:-}"; SKILL_PATH=$2; shift 2 ;;
    --source-ref) need_value "$1" "${2:-}"; SOURCE_REF_OVERRIDE=$2; shift 2 ;;
    --target) need_value "$1" "${2:-}"; TARGET=$2; shift 2 ;;
    --allow-risk) ALLOW_RISK=1; shift ;;
    --replace-existing) REPLACE_EXISTING=1; shift ;;
    --allow-source-change) ALLOW_SOURCE_CHANGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --local-repository) need_value "$1" "${2:-}"; LOCAL_REPOSITORY=$2; shift 2 ;;
    --catalog-root) need_value "$1" "${2:-}"; CATALOG_ROOT=$2; shift 2 ;;
    --first-party-root|--first-party-skills-root|--community-root|--community-skills-root)
      echo "$1 is no longer used by intake; candidates remain in catalog/review-queue until activation." >&2
      exit 2
      ;;
    --activate)
      echo "Direct activation during URL intake is not supported. Review the candidate, then run catalog activate." >&2
      exit 2
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$URL" ] || { echo "--url is required." >&2; exit 2; }
case "$TARGET" in oceans|community) ;; *) echo "Unsupported target: $TARGET" >&2; exit 2 ;; esac
case "$MAX_FILES:$MAX_BYTES" in *[!0-9:]*|:*|*:) echo "Intake budgets must be positive integers." >&2; exit 2 ;; esac
[ "$MAX_FILES" -gt 0 ] && [ "$MAX_BYTES" -gt 0 ] || { echo "Intake budgets must be positive integers." >&2; exit 2; }
if [ -n "$LOCAL_REPOSITORY" ] && [ "${OCEANS_TEST_MODE:-0}" != 1 ]; then
  echo "--local-repository is test-only and requires OCEANS_TEST_MODE=1." >&2
  exit 2
fi

clean_url=${URL%%\?*}
clean_url=${clean_url%%\#*}
clean_url=${clean_url%/}
case "$clean_url" in *%*) echo "Percent-encoded GitHub paths are not accepted; provide the canonical visible URL." >&2; exit 1 ;; esac
case "$clean_url" in https://github.com/*/*) ;; *) echo "Only https://github.com skill URLs are supported." >&2; exit 1 ;; esac

url_tail=${clean_url#https://github.com/}
owner=${url_tail%%/*}
repo_and_tail=${url_tail#*/}
repo_segment=${repo_and_tail%%/*}
repo=${repo_segment%.git}
printf '%s\n' "$owner" | grep -E -q '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$' || { echo "Invalid GitHub owner: $owner" >&2; exit 1; }
printf '%s\n' "$repo" | grep -E -q '^[A-Za-z0-9._-]{1,100}$' || { echo "Invalid GitHub repository: $repo" >&2; exit 1; }
upstream_repository=https://github.com/$owner/$repo
clone_url=$upstream_repository.git
remaining=${repo_and_tail#"$repo_segment"}
remaining=${remaining#/}
url_kind=repository
ref_and_path=
case "$remaining" in
  "") ;;
  tree/*) url_kind=tree; ref_and_path=${remaining#tree/}; [ -n "$ref_and_path" ] || { echo "GitHub tree URL is missing a ref." >&2; exit 1; } ;;
  blob/*) url_kind=blob; ref_and_path=${remaining#blob/}; [ -n "$ref_and_path" ] || { echo "GitHub blob URL is missing a ref and path." >&2; exit 1; } ;;
  *) echo "Unsupported GitHub URL shape. Use a repository, tree directory, or SKILL.md blob URL." >&2; exit 1 ;;
esac

list_source_refs() {
  if [ -n "$LOCAL_REPOSITORY" ]; then
    git -C "$LOCAL_REPOSITORY" for-each-ref --format='%(refname:short)' refs/heads refs/tags
  else
    git ls-remote --heads --tags "$clone_url" | awk '{ sub(/^refs\/heads\//, "", $2); sub(/^refs\/tags\//, "", $2); sub(/\^\{\}$/, "", $2); print $2 }' | awk 'NF && !seen[$0]++'
  fi
}

source_ref=$SOURCE_REF_OVERRIDE
url_skill_path=
if [ "$url_kind" != repository ]; then
  if [ -z "$source_ref" ]; then
    best_ref=
    refs_file=$(mktemp "${TMPDIR:-/tmp}/oceans-source-refs.XXXXXX")
    list_source_refs > "$refs_file"
    while IFS= read -r candidate_ref; do
      [ -n "$candidate_ref" ] || continue
      case "$ref_and_path" in
        "$candidate_ref"|"$candidate_ref"/*)
          if [ "${#candidate_ref}" -gt "${#best_ref}" ]; then best_ref=$candidate_ref; fi
          ;;
      esac
    done < "$refs_file"
    rm -f "$refs_file"
    if [ -n "$best_ref" ]; then source_ref=$best_ref; else source_ref=${ref_and_path%%/*}; fi
  fi
  [ "$ref_and_path" = "$source_ref" ] || url_skill_path=${ref_and_path#"$source_ref"/}
fi

if [ "$url_kind" = blob ]; then
  case "$url_skill_path" in
    SKILL.md) url_skill_path= ;;
    */SKILL.md) url_skill_path=${url_skill_path%/SKILL.md} ;;
    *) echo "Blob URL must point to SKILL.md." >&2; exit 1 ;;
  esac
fi
if [ -n "$SKILL_PATH" ]; then url_skill_path=$SKILL_PATH; fi
case "$url_skill_path" in /*|../*|*/../*|*/..|..|*\\*) echo "Unsafe skill path: $url_skill_path" >&2; exit 1 ;; esac

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-skill-intake.XXXXXX")
CLONE_ROOT=$TEMP_ROOT/repository

if [ -n "$LOCAL_REPOSITORY" ]; then
  [ -d "$LOCAL_REPOSITORY/.git" ] || { echo "--local-repository must point to a Git repository." >&2; exit 1; }
  GIT_LFS_SKIP_SMUDGE=1 git clone --quiet --filter=blob:none --no-checkout "$LOCAL_REPOSITORY" "$CLONE_ROOT"
  if [ -n "$source_ref" ]; then
    resolved_ref=$(git -C "$LOCAL_REPOSITORY" rev-parse --verify "$source_ref^{commit}")
    git -C "$CLONE_ROOT" checkout --quiet --detach "$resolved_ref"
  else
    git -C "$CLONE_ROOT" checkout --quiet
  fi
else
  if [ -n "$source_ref" ]; then
    GIT_LFS_SKIP_SMUDGE=1 git clone --quiet --filter=blob:none --no-checkout "$clone_url" "$CLONE_ROOT"
    git -C "$CLONE_ROOT" fetch --quiet --depth 1 origin "$source_ref"
    git -C "$CLONE_ROOT" checkout --quiet --detach FETCH_HEAD
  else
    GIT_LFS_SKIP_SMUDGE=1 git clone --quiet --depth 1 --filter=blob:none "$clone_url" "$CLONE_ROOT"
  fi
fi

source_commit=$(git -C "$CLONE_ROOT" rev-parse HEAD)
if [ -z "$source_ref" ]; then
  source_ref=$(git -C "$CLONE_ROOT" symbolic-ref --quiet --short HEAD || true)
  [ -n "$source_ref" ] || source_ref=$source_commit
fi

if [ -n "$url_skill_path" ]; then
  source_skill=$CLONE_ROOT/$url_skill_path
  [ -d "$source_skill" ] && [ -f "$source_skill/SKILL.md" ] || { echo "The selected path does not contain SKILL.md: $url_skill_path" >&2; exit 1; }
elif [ -f "$CLONE_ROOT/SKILL.md" ]; then
  source_skill=$CLONE_ROOT
  url_skill_path=.
else
  matches_file=$TEMP_ROOT/matches
  find "$CLONE_ROOT" -type f -name SKILL.md -not -path '*/.git/*' -print > "$matches_file"
  match_count=$(awk 'NF { count++ } END { print count + 0 }' "$matches_file")
  [ "$match_count" -gt 0 ] || { echo "No SKILL.md was found in the repository." >&2; exit 1; }
  if [ "$match_count" -gt 1 ]; then
    echo "Multiple skills were found; rerun with --skill-path." >&2
    sed "s|^$CLONE_ROOT/||" "$matches_file" >&2
    exit 1
  fi
  skill_file=$(sed -n '1p' "$matches_file")
  source_skill=${skill_file%/SKILL.md}
  url_skill_path=${source_skill#"$CLONE_ROOT"/}
fi

[ ! -L "$source_skill" ] || { echo "Selected skill path is a symlink." >&2; exit 1; }
source_skill_real=$(CDPATH= cd "$source_skill" && pwd -P)
clone_root_real=$(CDPATH= cd "$CLONE_ROOT" && pwd -P)
case "$source_skill_real" in "$clone_root_real"|"$clone_root_real"/*) ;; *) echo "Selected skill escapes the cloned repository." >&2; exit 1 ;; esac
source_skill=$source_skill_real

skill_name=$(oceans_frontmatter_value "$source_skill" name || true)
[ -n "$skill_name" ] || { echo "The selected SKILL.md has no name." >&2; exit 1; }
oceans_valid_skill_name "$skill_name" || { echo "Invalid skill name: $skill_name" >&2; exit 1; }
metadata_issues=$(oceans_skill_metadata_issues "$source_skill" "$skill_name")
[ -z "$metadata_issues" ] || { echo "Invalid skill metadata: $skill_name" >&2; printf '%s\n' "$metadata_issues" >&2; exit 1; }
path_issues=$(oceans_skill_path_issues "$source_skill")
[ -z "$path_issues" ] || { printf '%s\n' "$path_issues" >&2; exit 1; }

files_file=$TEMP_ROOT/included-files
oceans_find_included_skill_files "$source_skill" > "$files_file"
file_count=$(awk 'NF { count++ } END { print count + 0 }' "$files_file")
[ "$file_count" -le "$MAX_FILES" ] || { echo "Skill exceeds intake file budget: $file_count > $MAX_FILES" >&2; exit 1; }
total_bytes=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  size=$(wc -c < "$file" | tr -d '[:space:]')
  total_bytes=$((total_bytes + size))
  [ "$total_bytes" -le "$MAX_BYTES" ] || { echo "Skill exceeds intake size budget: $total_bytes > $MAX_BYTES" >&2; exit 1; }
done < "$files_file"

PREPARED_ROOT=$TEMP_ROOT/prepared
PREPARED_SKILL=$PREPARED_ROOT/$skill_name
mkdir -p "$PREPARED_SKILL"
cp -R "$source_skill"/. "$PREPARED_SKILL"
oceans_remove_excluded_paths "$PREPARED_SKILL"

package_repository=community-skills
[ "$TARGET" = oceans ] && package_repository=oceans-skills
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

- Repository: $upstream_repository
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

symlinks=$(find "$PREPARED_SKILL" -type l -print 2>/dev/null)
[ -z "$symlinks" ] || { echo "Candidate contains unsupported symlinks: $skill_name" >&2; exit 1; }
risks=$(oceans_scan_skill_risks "$PREPARED_SKILL")
if [ -n "$risks" ] && [ "$ALLOW_RISK" -ne 1 ]; then
  echo "risk-blocked: $skill_name" >&2
  printf '%s\n' "$risks" >&2
  exit 1
fi
candidate_content_sha256=$(oceans_skill_content_sha256 "$PREPARED_SKILL")

record_path=$(oceans_catalog_record_path "$CATALOG_ROOT" "$skill_name")
if [ -f "$record_path" ] && [ "$REPLACE_EXISTING" -ne 1 ]; then
  existing_status=$(oceans_catalog_record_value "$record_path" status || true)
  echo "Skill already exists in catalog state $existing_status: $skill_name" >&2
  echo "Use --replace-existing for an intentional candidate update." >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "candidate-plan-skill: $skill_name"
  echo "candidate-plan-repository: $package_repository"
  echo "candidate-plan-source: $upstream_repository@$source_commit"
  echo "candidate-plan-content-sha256: $candidate_content_sha256"
  echo "candidate-plan-files: $file_count"
  echo "candidate-plan-bytes: $total_bytes"
  exit 0
fi

oceans_catalog_acquire_lock "$CATALOG_ROOT" "$skill_name"
LOCK_HELD=1
record_path=$(oceans_catalog_record_path "$CATALOG_ROOT" "$skill_name")
existing=0
if [ -f "$record_path" ]; then
  existing=1
  [ "$REPLACE_EXISTING" -eq 1 ] || { echo "Skill was added concurrently: $skill_name" >&2; exit 1; }
  current_status=$(oceans_catalog_record_value "$record_path" status || true)
  case "$current_status" in active|pending-review) ;; *) echo "Restore or unblock $skill_name before queuing an update from $current_status." >&2; exit 1 ;; esac
  existing_package_repository=$(oceans_catalog_record_value "$record_path" package_repository || true)
  [ "$existing_package_repository" = "$package_repository" ] || { echo "Existing skill belongs to $existing_package_repository; refusing cross-repository migration." >&2; exit 1; }
  current_upstream_repository=$(oceans_catalog_record_value "$record_path" upstream_repository || true)
  if [ -n "$current_upstream_repository" ] && [ "$current_upstream_repository" != "$upstream_repository" ] && [ "$ALLOW_SOURCE_CHANGE" -ne 1 ]; then
    echo "Upstream repository changed from $current_upstream_repository to $upstream_repository." >&2
    echo "Use --allow-source-change only after an explicit provenance review." >&2
    exit 1
  fi
  current_upstream_path=$(oceans_catalog_record_value "$record_path" upstream_path || true)
  current_upstream_ref=$(oceans_catalog_record_value "$record_path" upstream_ref || true)
  current_upstream_commit=$(oceans_catalog_record_value "$record_path" upstream_commit || true)
  current_content_sha256=$(oceans_catalog_record_value "$record_path" content_sha256 || true)
  current_replacement=$(oceans_catalog_record_value "$record_path" replacement || true)
  current_status_reason=$(oceans_catalog_record_value "$record_path" status_reason || true)
else
  current_status=pending-review
  current_upstream_repository=
  current_upstream_path=
  current_upstream_ref=
  current_upstream_commit=
  current_content_sha256=
  current_replacement=
  current_status_reason=
fi

review_path=$(oceans_catalog_review_path "$CATALOG_ROOT" "$package_repository" "$skill_name")
backup_path=$TEMP_ROOT/review-backup
if [ -d "$review_path" ]; then mkdir -p "$backup_path"; cp -R "$review_path"/. "$backup_path"; fi
staging_path=$(oceans_new_staging_directory "$review_path")
cp -R "$PREPARED_SKILL"/. "$staging_path"
if ! oceans_commit_staged_directory "$staging_path" "$review_path"; then
  echo "Failed to stage candidate review content: $skill_name" >&2
  exit 1
fi

if ! oceans_catalog_write_record "$CATALOG_ROOT" "$skill_name" "$current_status" "$package_repository" \
  "$current_upstream_repository" "$current_upstream_path" "$current_upstream_ref" "$current_upstream_commit" \
  "$upstream_repository" "$url_skill_path" "$source_ref" "$source_commit" \
  "$current_replacement" "$current_status_reason" "queued candidate $source_commit with content $candidate_content_sha256" \
  "$current_content_sha256" "$candidate_content_sha256"; then
  if [ -d "$backup_path" ]; then
    restore_stage=$(oceans_new_staging_directory "$review_path")
    cp -R "$backup_path"/. "$restore_stage"
    oceans_commit_staged_directory "$restore_stage" "$review_path" || true
  else
    rm -rf "$review_path"
  fi
  echo "Catalog candidate registration failed and was rolled back: $skill_name" >&2
  exit 1
fi

echo "candidate-added: $skill_name"
echo "catalog-state: $current_status"
echo "candidate-commit: $source_commit"
echo "candidate-content-sha256: $candidate_content_sha256"
if [ "$existing" -eq 1 ]; then
  echo "active-package-preserved: $skill_name"
fi
echo "next: review catalog/review-queue/$package_repository/$skill_name, then run ./oceans catalog activate --skill $skill_name"
