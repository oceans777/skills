#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/skill-publish-rules.sh"
. "$SCRIPT_DIR/skill-catalog.sh"
. "$SCRIPT_DIR/directory-transaction.sh"
SKILL_ROOTS_LIB_ONLY=1 . "$SCRIPT_DIR/skill-roots.sh"

ACTION=${1:-list}
if [ "$#" -gt 0 ]; then shift; fi
CATALOG_ROOT=$REPO_ROOT/catalog
FIRST_PARTY_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_ROOT=$REPO_ROOT/repos/community-skills/skills
INSTALL_ROOT=
SKIP_RUNTIME_RECONCILE=0
SKILL=
REASON=
REPLACEMENT=
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog-root) [ "$#" -ge 2 ] || { echo "--catalog-root needs a path." >&2; exit 2; }; CATALOG_ROOT=$2; shift 2 ;;
    --first-party-root|--first-party-skills-root) [ "$#" -ge 2 ] || { echo "$1 needs a path." >&2; exit 2; }; FIRST_PARTY_ROOT=$2; shift 2 ;;
    --community-root|--community-skills-root) [ "$#" -ge 2 ] || { echo "$1 needs a path." >&2; exit 2; }; COMMUNITY_ROOT=$2; shift 2 ;;
    --install-root) [ "$#" -ge 2 ] || { echo "--install-root needs a path." >&2; exit 2; }; INSTALL_ROOT=$2; shift 2 ;;
    --skip-runtime-reconcile) SKIP_RUNTIME_RECONCILE=1; shift ;;
    --skill) [ "$#" -ge 2 ] || { echo "--skill needs a value." >&2; exit 2; }; SKILL=$2; shift 2 ;;
    --reason) [ "$#" -ge 2 ] || { echo "--reason needs a value." >&2; exit 2; }; REASON=$2; shift 2 ;;
    --replacement) [ "$#" -ge 2 ] || { echo "--replacement needs a value." >&2; exit 2; }; REPLACEMENT=$2; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

list_catalog() {
  printf 'status|repository|name|candidate|replacement|reason\n'
  for record_path in "$CATALOG_ROOT/skills"/*.skill; do
    [ -f "$record_path" ] || continue
    name=$(oceans_catalog_record_value "$record_path" name || true)
    status=$(oceans_catalog_record_value "$record_path" status || true)
    repository=$(oceans_catalog_record_value "$record_path" package_repository || true)
    candidate_commit=$(oceans_catalog_record_value "$record_path" candidate_upstream_commit || true)
    replacement=$(oceans_catalog_record_value "$record_path" replacement || true)
    reason=$(oceans_catalog_record_value "$record_path" status_reason || true)
    candidate=no
    [ -z "$candidate_commit" ] || candidate=yes
    printf '%s|%s|%s|%s|%s|%s\n' "$status" "$repository" "$name" "$candidate" "$replacement" "$reason"
  done
}

require_skill() {
  [ -n "$SKILL" ] || { echo "--skill is required." >&2; exit 2; }
  oceans_catalog_valid_skill_name "$SKILL" || { echo "Invalid skill name: $SKILL" >&2; exit 2; }
}

load_record() {
  RECORD_PATH=$(oceans_catalog_record_path "$CATALOG_ROOT" "$SKILL")
  [ -f "$RECORD_PATH" ] || { echo "catalog-skill-not-found: $SKILL" >&2; exit 1; }
  STATUS=$(oceans_catalog_record_value "$RECORD_PATH" status || true)
  PACKAGE_REPOSITORY=$(oceans_catalog_record_value "$RECORD_PATH" package_repository || true)
  UPSTREAM_REPOSITORY=$(oceans_catalog_record_value "$RECORD_PATH" upstream_repository || true)
  UPSTREAM_PATH=$(oceans_catalog_record_value "$RECORD_PATH" upstream_path || true)
  UPSTREAM_REF=$(oceans_catalog_record_value "$RECORD_PATH" upstream_ref || true)
  UPSTREAM_COMMIT=$(oceans_catalog_record_value "$RECORD_PATH" upstream_commit || true)
  CANDIDATE_REPOSITORY=$(oceans_catalog_record_value "$RECORD_PATH" candidate_upstream_repository || true)
  CANDIDATE_PATH=$(oceans_catalog_record_value "$RECORD_PATH" candidate_upstream_path || true)
  CANDIDATE_REF=$(oceans_catalog_record_value "$RECORD_PATH" candidate_upstream_ref || true)
  CANDIDATE_COMMIT=$(oceans_catalog_record_value "$RECORD_PATH" candidate_upstream_commit || true)
  CONTENT_SHA256=$(oceans_catalog_record_value "$RECORD_PATH" content_sha256 || true)
  CANDIDATE_CONTENT_SHA256=$(oceans_catalog_record_value "$RECORD_PATH" candidate_content_sha256 || true)
  CURRENT_REPLACEMENT=$(oceans_catalog_record_value "$RECORD_PATH" replacement || true)
  CURRENT_STATUS_REASON=$(oceans_catalog_record_value "$RECORD_PATH" status_reason || true)
}

acquire_skill_lock() {
  oceans_catalog_acquire_lock "$CATALOG_ROOT" "$SKILL"
  LOCK_HELD=1
}

reconcile_runtime() {
  target_status=$1
  if [ "$SKIP_RUNTIME_RECONCILE" -eq 1 ]; then
    echo "runtime-reconcile: explicitly-skipped"
    return
  fi

  set -- --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" --catalog-root "$CATALOG_ROOT"
  if [ -n "$INSTALL_ROOT" ]; then
    set -- "$@" --install-root "$INSTALL_ROOT"
  else
    existing_roots=$(list_existing_root_records)
    if [ -z "$existing_roots" ]; then
      echo "runtime-reconcile: no-existing-roots"
      return
    fi
    set -- "$@" --all-existing-runtimes
  fi
  [ "$target_status" = active ] || set -- "$@" --reconcile-only

  if ! sh "$SCRIPT_DIR/install-skills.sh" "$@"; then
    echo "Lifecycle state was committed, but runtime reconciliation failed." >&2
    exit 1
  fi
}

validate_candidate() {
  candidate_root=$1
  [ -d "$candidate_root" ] && [ ! -L "$candidate_root" ] || { echo "Candidate review content is missing or unsafe: $SKILL" >&2; return 1; }
  [ -f "$candidate_root/SKILL.md" ] || { echo "Candidate is missing SKILL.md: $SKILL" >&2; return 1; }
  metadata_issues=$(oceans_skill_metadata_issues "$candidate_root" "$SKILL")
  [ -z "$metadata_issues" ] || { printf '%s\n' "$metadata_issues" >&2; return 1; }
  path_issues=$(oceans_skill_path_issues "$candidate_root")
  [ -z "$path_issues" ] || { printf '%s\n' "$path_issues" >&2; return 1; }
  symlinks=$(find "$candidate_root" -type l -print 2>/dev/null)
  [ -z "$symlinks" ] || { echo "Candidate contains unsupported symlinks: $SKILL" >&2; return 1; }
  risks=$(oceans_scan_skill_risks "$candidate_root")
  [ -z "$risks" ] || { printf '%s\n' "$risks" >&2; return 1; }
  if [ "$PACKAGE_REPOSITORY" = community-skills ]; then
    for required in UPSTREAM.md PATCHES.md LICENSE; do
      [ -s "$candidate_root/$required" ] || { echo "Candidate is missing $required: $SKILL" >&2; return 1; }
    done
  fi
  oceans_valid_sha256 "$CANDIDATE_CONTENT_SHA256" || { echo "Candidate content SHA-256 is missing or invalid: $SKILL" >&2; return 1; }
  actual_candidate_sha256=$(oceans_skill_content_sha256 "$candidate_root") || return 1
  [ "$actual_candidate_sha256" = "$CANDIDATE_CONTENT_SHA256" ] || {
    echo "Candidate content changed after intake: $SKILL. Expected $CANDIDATE_CONTENT_SHA256, got $actual_candidate_sha256" >&2
    return 1
  }
  printf '%s\n' "$actual_candidate_sha256"
}

restore_target_from_backup() {
  target_path=$1
  backup_path=$2
  if [ -d "$backup_path" ]; then
    restore_stage=$(oceans_new_staging_directory "$target_path") || return 1
    cp -R "$backup_path"/. "$restore_stage"
    oceans_commit_staged_directory "$restore_stage" "$target_path"
  else
    rm -rf "$target_path"
  fi
}

remove_hold_best_effort() {
  hold_path=$1
  [ ! -e "$hold_path" ] && return 0
  if ! rm -rf "$hold_path"; then
    echo "WARNING: committed lifecycle state is valid, but temporary review hold could not be removed: $hold_path" >&2
  fi
}

promote_candidate() {
  load_record
  case "$STATUS" in pending-review|active) ;; *) echo "catalog-transition-not-allowed: $STATUS -> active" >&2; exit 1 ;; esac
  [ -n "$CANDIDATE_COMMIT" ] || { echo "catalog-candidate-not-found: $SKILL" >&2; exit 1; }
  REVIEW_PATH=$(oceans_catalog_review_path "$CATALOG_ROOT" "$PACKAGE_REPOSITORY" "$SKILL")
  expected_content_sha256=$(validate_candidate "$REVIEW_PATH") || exit 1

  case "$PACKAGE_REPOSITORY" in
    oceans-skills) target_root=$FIRST_PARTY_ROOT ;;
    community-skills) target_root=$COMMUNITY_ROOT ;;
    *) echo "Unsupported package repository: $PACKAGE_REPOSITORY" >&2; exit 1 ;;
  esac
  target_path=$target_root/$SKILL
  if [ "$STATUS" = pending-review ] && [ -e "$target_path" ]; then
    echo "Pending new skill already exists in package repository: $SKILL" >&2
    exit 1
  fi

  TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-catalog-promote.XXXXXX")
  backup_path=$TEMP_ROOT/package-backup
  if [ -d "$target_path" ]; then mkdir -p "$backup_path"; cp -R "$target_path"/. "$backup_path"; fi
  review_hold=$(dirname "$REVIEW_PATH")/.$SKILL.promoting.$$
  [ ! -e "$review_hold" ] || { echo "Candidate promotion hold already exists: $review_hold" >&2; exit 1; }
  mv "$REVIEW_PATH" "$review_hold"

  promotion_ok=0
  staging_path=$(oceans_new_staging_directory "$target_path") || {
    mv "$review_hold" "$REVIEW_PATH"
    exit 1
  }
  if cp -R "$review_hold"/. "$staging_path" && oceans_remove_excluded_paths "$staging_path"; then
    staged_content_sha256=$(oceans_skill_content_sha256 "$staging_path" || true)
    if [ "$staged_content_sha256" = "$expected_content_sha256" ] && oceans_commit_staged_directory "$staging_path" "$target_path"; then
      published_content_sha256=$(oceans_skill_content_sha256 "$target_path" || true)
      if [ "$published_content_sha256" = "$expected_content_sha256" ] && oceans_catalog_write_record "$CATALOG_ROOT" "$SKILL" active "$PACKAGE_REPOSITORY" \
        "$CANDIDATE_REPOSITORY" "$CANDIDATE_PATH" "$CANDIDATE_REF" "$CANDIDATE_COMMIT" \
        "" "" "" "" "" "" "activated reviewed candidate $CANDIDATE_COMMIT with content $published_content_sha256" \
        "$published_content_sha256" ""; then
        promotion_ok=1
      fi
    fi
  fi

  if [ "$promotion_ok" -eq 1 ]; then
    remove_hold_best_effort "$review_hold"
    echo "catalog-state: active"
    echo "skill: $SKILL"
    echo "activated-commit: $CANDIDATE_COMMIT"
    echo "activated-content-sha256: $expected_content_sha256"
    return
  fi

  restore_target_from_backup "$target_path" "$backup_path" || echo "CRITICAL: failed to restore package after candidate activation failure: $SKILL" >&2
  [ ! -e "$review_hold" ] || mv "$review_hold" "$REVIEW_PATH"
  echo "Candidate activation failed and was rolled back: $SKILL" >&2
  exit 1
}

reject_candidate() {
  load_record
  [ -n "$CANDIDATE_COMMIT" ] || { echo "catalog-candidate-not-found: $SKILL" >&2; exit 1; }
  review_path=$(oceans_catalog_review_path "$CATALOG_ROOT" "$PACKAGE_REPOSITORY" "$SKILL")
  review_hold=$(dirname "$review_path")/.$SKILL.rejecting.$$
  [ -d "$review_path" ] || { echo "Candidate review content is missing: $SKILL" >&2; exit 1; }
  mv "$review_path" "$review_hold"

  if [ "$STATUS" = pending-review ]; then
    if rm -f "$RECORD_PATH"; then
      remove_hold_best_effort "$review_hold"
      echo "catalog-candidate-rejected: $SKILL"
      echo "catalog-record-removed: $SKILL"
      return
    fi
  elif oceans_catalog_write_record "$CATALOG_ROOT" "$SKILL" "$STATUS" "$PACKAGE_REPOSITORY" \
    "$UPSTREAM_REPOSITORY" "$UPSTREAM_PATH" "$UPSTREAM_REF" "$UPSTREAM_COMMIT" \
    "" "" "" "" "$CURRENT_REPLACEMENT" "$CURRENT_STATUS_REASON" "rejected candidate $CANDIDATE_COMMIT" \
    "$CONTENT_SHA256" ""; then
    remove_hold_best_effort "$review_hold"
    echo "catalog-candidate-rejected: $SKILL"
    echo "catalog-state: $STATUS"
    return
  fi

  [ ! -e "$review_hold" ] || mv "$review_hold" "$review_path"
  echo "Candidate rejection failed and was rolled back: $SKILL" >&2
  exit 1
}

transition_status() {
  target_status=$1
  transition_kind=$2
  load_record
  [ -z "$CANDIDATE_COMMIT" ] || { echo "Resolve the pending candidate before changing lifecycle status: $SKILL" >&2; exit 1; }
  case "$transition_kind:$STATUS" in
    restore:deprecated|restore:archived|unblock:blocked|deprecate:active|archive:active|archive:deprecated|block:active|block:deprecated|block:archived) ;;
    *) echo "catalog-transition-not-allowed: $STATUS -> $target_status" >&2; exit 1 ;;
  esac

  replacement=$REPLACEMENT
  [ -n "$replacement" ] || replacement=$CURRENT_REPLACEMENT
  status_reason=
  transition_note=$transition_kind
  case "$target_status" in
    deprecated|archived|blocked)
      [ -n "$REASON" ] || { echo "--reason is required for $transition_kind." >&2; exit 2; }
      status_reason=$REASON
      transition_note=$REASON
      ;;
    active)
      replacement=
      [ -n "$REASON" ] && transition_note=$REASON
      ;;
  esac

  oceans_catalog_write_record "$CATALOG_ROOT" "$SKILL" "$target_status" "$PACKAGE_REPOSITORY" \
    "$UPSTREAM_REPOSITORY" "$UPSTREAM_PATH" "$UPSTREAM_REF" "$UPSTREAM_COMMIT" \
    "" "" "" "" "$replacement" "$status_reason" "$transition_note" "$CONTENT_SHA256" ""
  reconcile_runtime "$target_status"
  echo "catalog-state: $target_status"
  echo "skill: $SKILL"
}

case "$ACTION" in
  list) list_catalog ;;
  activate)
    require_skill; acquire_skill_lock; promote_candidate ;;
  reject|cancel-review)
    require_skill; acquire_skill_lock; reject_candidate ;;
  restore)
    require_skill; acquire_skill_lock; transition_status active restore ;;
  unblock)
    require_skill; [ -n "$REASON" ] || { echo "--reason is required for unblock." >&2; exit 2; }; acquire_skill_lock; transition_status active unblock ;;
  deprecate)
    require_skill; acquire_skill_lock; transition_status deprecated deprecate ;;
  archive)
    require_skill; acquire_skill_lock; transition_status archived archive ;;
  block)
    require_skill; acquire_skill_lock; transition_status blocked block ;;
  *)
    echo "Unsupported catalog action: $ACTION" >&2
    echo "Supported actions: list, activate, reject, restore, unblock, deprecate, archive, block" >&2
    exit 2
    ;;
esac
