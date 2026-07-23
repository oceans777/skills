#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/skill-publish-rules.sh"
. "$SCRIPT_DIR/skill-catalog.sh"

FIRST_PARTY_SKILLS_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_SKILLS_ROOT=$REPO_ROOT/repos/community-skills/skills
CATALOG_ROOT=$REPO_ROOT/catalog
CATALOG_EXPLICIT=0
CUSTOM_SOURCE_ROOTS=0
WITHOUT_CATALOG=0
failures=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --first-party-root|--first-party-skills-root)
      [ "$#" -ge 2 ] || { echo "$1 needs a path." >&2; exit 2; }
      FIRST_PARTY_SKILLS_ROOT=$2; CUSTOM_SOURCE_ROOTS=1; shift 2 ;;
    --community-root|--community-skills-root)
      [ "$#" -ge 2 ] || { echo "$1 needs a path." >&2; exit 2; }
      COMMUNITY_SKILLS_ROOT=$2; CUSTOM_SOURCE_ROOTS=1; shift 2 ;;
    --catalog-root)
      [ "$#" -ge 2 ] || { echo "--catalog-root needs a path." >&2; exit 2; }
      CATALOG_ROOT=$2; CATALOG_EXPLICIT=1; shift 2 ;;
    --without-catalog) WITHOUT_CATALOG=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$CUSTOM_SOURCE_ROOTS" -eq 1 ] && [ "$CATALOG_EXPLICIT" -eq 0 ] && [ "$WITHOUT_CATALOG" -eq 0 ]; then
  echo "Custom skill roots require --catalog-root. Use --without-catalog only for an intentional legacy fixture." >&2
  exit 2
fi
if [ "$WITHOUT_CATALOG" -eq 1 ] && [ "$CATALOG_EXPLICIT" -eq 1 ]; then
  echo "--without-catalog cannot be combined with --catalog-root." >&2
  exit 2
fi

add_failure() {
  echo "ERROR: $*" >&2
  failures=$((failures + 1))
}

test_skill_path() {
  repository_name=$1
  skill_name=$2
  skill_path=$3
  require_upstream=$4

  if [ ! -d "$skill_path" ]; then add_failure "Missing skill path in $repository_name: $skill_name"; return; fi
  metadata_issues=$(oceans_skill_metadata_issues "$skill_path" "$skill_name")
  if [ -n "$metadata_issues" ]; then
    old_ifs=$IFS; IFS='
'
    for issue in $metadata_issues; do add_failure "Invalid skill metadata in $repository_name: $skill_name: $issue"; done
    IFS=$old_ifs
  fi
  if [ ! -f "$skill_path/SKILL.md" ]; then
    add_failure "Missing SKILL.md in $repository_name: $skill_name"
  elif oceans_missing_license_reference "$skill_path"; then
    add_failure "Missing referenced license file in $repository_name: $skill_name"
  fi
  risk_notes=$(oceans_scan_skill_risks "$skill_path")
  if [ -n "$risk_notes" ]; then
    old_ifs=$IFS; IFS='
'
    for risk_note in $risk_notes; do
      [ "$risk_note" = "risk: missing referenced license file" ] && continue
      add_failure "Unsafe skill content in $repository_name: $skill_name: $risk_note"
    done
    IFS=$old_ifs
  fi
  if [ -L "$skill_path" ]; then add_failure "Unsupported symlink in $repository_name: $skill_name"; fi
  symlinks=$(find "$skill_path" -type l -print 2>/dev/null)
  if [ -n "$symlinks" ]; then
    old_ifs=$IFS; IFS='
'
    for symlink_path in $symlinks; do add_failure "Unsupported symlink in $repository_name: $skill_name: ${symlink_path#"$skill_path"/}"; done
    IFS=$old_ifs
  fi
  if [ "$require_upstream" = true ]; then
    for required in UPSTREAM.md PATCHES.md LICENSE; do
      if [ ! -f "$skill_path/$required" ] || [ -z "$(tr -d '[:space:]' < "$skill_path/$required" 2>/dev/null)" ]; then
        add_failure "Missing or empty $required in $repository_name: $skill_name"
      fi
    done
  fi
}

test_skill_directory() {
  repository_name=$1
  skills_path=$2
  require_upstream=$3
  if [ ! -d "$skills_path" ]; then add_failure "Missing skills path: $skills_path"; return; fi
  for skill_path in "$skills_path"/*; do
    [ -d "$skill_path" ] || continue
    test_skill_path "$repository_name" "${skill_path##*/}" "$skill_path" "$require_upstream"
  done
}

test_duplicate_names() {
  [ -d "$FIRST_PARTY_SKILLS_ROOT" ] && [ -d "$COMMUNITY_SKILLS_ROOT" ] || return
  for skill_path in "$FIRST_PARTY_SKILLS_ROOT"/*; do
    [ -d "$skill_path" ] || continue
    skill_name=${skill_path##*/}
    [ ! -d "$COMMUNITY_SKILLS_ROOT/$skill_name" ] || add_failure "Duplicate skill name across repositories: $skill_name"
  done
}

test_skill_directory oceans-skills "$FIRST_PARTY_SKILLS_ROOT" false
test_skill_directory community-skills "$COMMUNITY_SKILLS_ROOT" true
test_duplicate_names

if [ "$WITHOUT_CATALOG" -eq 0 ]; then
  catalog_issues=$(oceans_catalog_validation_issues "$CATALOG_ROOT" "$FIRST_PARTY_SKILLS_ROOT" "$COMMUNITY_SKILLS_ROOT")
  if [ -n "$catalog_issues" ]; then
    old_ifs=$IFS; IFS='
'
    for catalog_issue in $catalog_issues; do add_failure "$catalog_issue"; done
    IFS=$old_ifs
  fi

  for record_path in "$CATALOG_ROOT/skills"/*.skill; do
    [ -f "$record_path" ] || continue
    skill_name=${record_path##*/}; skill_name=${skill_name%.skill}
    candidate_commit=$(oceans_catalog_record_value "$record_path" candidate_upstream_commit || true)
    [ -n "$candidate_commit" ] || continue
    package_repository=$(oceans_catalog_record_value "$record_path" package_repository || true)
    candidate_path=$(oceans_catalog_review_path "$CATALOG_ROOT" "$package_repository" "$skill_name")
    require_upstream=false
    [ "$package_repository" != community-skills ] || require_upstream=true
    test_skill_path "review-queue/$package_repository" "$skill_name" "$candidate_path" "$require_upstream"
  done
else
  echo "WARNING: catalog validation explicitly disabled." >&2
fi

if [ "$failures" -gt 0 ]; then
  echo "Validation failed with $failures issue(s)." >&2
  exit 1
fi

echo "Validation passed."
