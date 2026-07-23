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
failures=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --first-party-root)
      [ "$#" -ge 2 ] || { echo "--first-party-root needs a path." >&2; exit 2; }
      FIRST_PARTY_SKILLS_ROOT=$2
      CUSTOM_SOURCE_ROOTS=1
      shift 2
      ;;
    --community-root)
      [ "$#" -ge 2 ] || { echo "--community-root needs a path." >&2; exit 2; }
      COMMUNITY_SKILLS_ROOT=$2
      CUSTOM_SOURCE_ROOTS=1
      shift 2
      ;;
    --catalog-root)
      [ "$#" -ge 2 ] || { echo "--catalog-root needs a path." >&2; exit 2; }
      CATALOG_ROOT=$2
      CATALOG_EXPLICIT=1
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

CATALOG_ENABLED=1
if [ "$CUSTOM_SOURCE_ROOTS" -eq 1 ] && [ "$CATALOG_EXPLICIT" -eq 0 ]; then
  CATALOG_ENABLED=0
fi

add_failure() {
  echo "ERROR: $*" >&2
  failures=$((failures + 1))
}

test_skill_directory() {
  repository_name=$1
  skills_path=$2
  require_upstream=$3

  if [ ! -d "$skills_path" ]; then
    add_failure "Missing skills path: $skills_path"
    return
  fi

  for skill_path in "$skills_path"/*; do
    [ -d "$skill_path" ] || continue
    skill_name=${skill_path##*/}

    metadata_issues=$(oceans_skill_metadata_issues "$skill_path" "$skill_name")
    if [ -n "$metadata_issues" ]; then
      old_ifs=$IFS
      IFS='
'
      for issue in $metadata_issues; do
        add_failure "Invalid skill metadata in $repository_name: $skill_name: $issue"
      done
      IFS=$old_ifs
    fi

    if [ ! -f "$skill_path/SKILL.md" ]; then
      add_failure "Missing SKILL.md in $repository_name: $skill_name"
    elif oceans_missing_license_reference "$skill_path"; then
      add_failure "Missing referenced license file in $repository_name: $skill_name"
    fi

    risk_notes=$(oceans_scan_skill_risks "$skill_path")
    if [ -n "$risk_notes" ]; then
      old_ifs=$IFS
      IFS='
'
      for risk_note in $risk_notes; do
        [ "$risk_note" = "risk: missing referenced license file" ] && continue
        add_failure "Unsafe skill content in $repository_name: $skill_name: $risk_note"
      done
      IFS=$old_ifs
    fi

    if [ -L "$skill_path" ]; then
      add_failure "Unsupported symlink in $repository_name: $skill_name"
    fi

    symlinks=$(find "$skill_path" -type l -print 2>/dev/null)
    if [ -n "$symlinks" ]; then
      old_ifs=$IFS
      IFS='
'
      for symlink_path in $symlinks; do
        add_failure "Unsupported symlink in $repository_name: $skill_name: ${symlink_path#"$skill_path"/}"
      done
      IFS=$old_ifs
    fi

    if [ "$require_upstream" = "true" ]; then
      for required in UPSTREAM.md PATCHES.md LICENSE; do
        if [ ! -f "$skill_path/$required" ] || [ -z "$(tr -d '[:space:]' < "$skill_path/$required" 2>/dev/null)" ]; then
          add_failure "Missing or empty $required in $repository_name: $skill_name"
        fi
      done
    fi
  done
}

test_duplicate_names() {
  first_party_path=$1
  community_path=$2

  [ -d "$first_party_path" ] || return
  [ -d "$community_path" ] || return

  for skill_path in "$first_party_path"/*; do
    [ -d "$skill_path" ] || continue
    skill_name=${skill_path##*/}
    if [ -d "$community_path/$skill_name" ]; then
      add_failure "Duplicate skill name across repositories: $skill_name"
    fi
  done
}

test_skill_directory "oceans-skills" "$FIRST_PARTY_SKILLS_ROOT" "false"
test_skill_directory "community-skills" "$COMMUNITY_SKILLS_ROOT" "true"
test_duplicate_names "$FIRST_PARTY_SKILLS_ROOT" "$COMMUNITY_SKILLS_ROOT"

if [ "$CATALOG_ENABLED" -eq 1 ]; then
  catalog_issues=$(oceans_catalog_validation_issues "$CATALOG_ROOT" "$FIRST_PARTY_SKILLS_ROOT" "$COMMUNITY_SKILLS_ROOT")
  if [ -n "$catalog_issues" ]; then
    old_ifs=$IFS
    IFS='
'
    for catalog_issue in $catalog_issues; do
      add_failure "$catalog_issue"
    done
    IFS=$old_ifs
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo "Validation failed with $failures issue(s)." >&2
  exit 1
fi

echo "Validation passed."
