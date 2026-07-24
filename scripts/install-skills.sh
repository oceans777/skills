#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SKILL_ROOTS_LIB_ONLY=1 . "$SCRIPT_DIR/skill-roots.sh"
. "$SCRIPT_DIR/directory-transaction.sh"
. "$SCRIPT_DIR/skill-catalog.sh"

INSTALL_ROOT=
RUNTIME=codex
ALL_EXISTING_RUNTIMES=0
FIRST_PARTY_SKILLS_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_SKILLS_ROOT=$REPO_ROOT/repos/community-skills/skills
CATALOG_ROOT=$REPO_ROOT/catalog
CATALOG_EXPLICIT=0
CUSTOM_SOURCE_ROOTS=0
WITHOUT_CATALOG=0
RECONCILE_ONLY=0
TARGET_SKILL=
LIFECYCLE_RECONCILE=0
BEST_EFFORT_ROOTS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-root) [ "$#" -ge 2 ] || { echo "--install-root needs a path." >&2; exit 2; }; INSTALL_ROOT=$2; shift 2 ;;
    --runtime) [ "$#" -ge 2 ] || { echo "--runtime needs a value." >&2; exit 2; }; RUNTIME=$2; shift 2 ;;
    --all-existing-runtimes) ALL_EXISTING_RUNTIMES=1; shift ;;
    --first-party-root|--first-party-skills-root) [ "$#" -ge 2 ] || { echo "$1 needs a path." >&2; exit 2; }; FIRST_PARTY_SKILLS_ROOT=$2; CUSTOM_SOURCE_ROOTS=1; shift 2 ;;
    --community-root|--community-skills-root) [ "$#" -ge 2 ] || { echo "$1 needs a path." >&2; exit 2; }; COMMUNITY_SKILLS_ROOT=$2; CUSTOM_SOURCE_ROOTS=1; shift 2 ;;
    --catalog-root) [ "$#" -ge 2 ] || { echo "--catalog-root needs a path." >&2; exit 2; }; CATALOG_ROOT=$2; CATALOG_EXPLICIT=1; shift 2 ;;
    --without-catalog) WITHOUT_CATALOG=1; shift ;;
    --reconcile-only) RECONCILE_ONLY=1; shift ;;
    --target-skill) [ "$#" -ge 2 ] || { echo "--target-skill needs a value." >&2; exit 2; }; TARGET_SKILL=$2; shift 2 ;;
    --lifecycle-reconcile) LIFECYCLE_RECONCILE=1; shift ;;
    --best-effort-roots) BEST_EFFORT_ROOTS=1; shift ;;
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
if [ "$RECONCILE_ONLY" -eq 1 ] && [ "$WITHOUT_CATALOG" -eq 1 ]; then
  echo "--reconcile-only requires lifecycle catalog governance." >&2
  exit 2
fi
if [ "$LIFECYCLE_RECONCILE" -eq 1 ] && [ "$WITHOUT_CATALOG" -eq 1 ]; then
  echo "--lifecycle-reconcile requires lifecycle catalog governance." >&2
  exit 2
fi
if [ -n "$TARGET_SKILL" ] && ! oceans_catalog_valid_skill_name "$TARGET_SKILL"; then
  echo "Invalid target skill name: $TARGET_SKILL" >&2
  exit 2
fi

CATALOG_ENABLED=1
[ "$WITHOUT_CATALOG" -eq 0 ] || CATALOG_ENABLED=0

if [ "$LIFECYCLE_RECONCILE" -eq 0 ]; then
  set -- --first-party-root "$FIRST_PARTY_SKILLS_ROOT" --community-root "$COMMUNITY_SKILLS_ROOT"
  if [ "$WITHOUT_CATALOG" -eq 1 ]; then set -- "$@" --without-catalog; else set -- "$@" --catalog-root "$CATALOG_ROOT"; fi
  if ! sh "$SCRIPT_DIR/validate-skills.sh" "$@" >/dev/null; then
    echo "Refusing to install from an invalid or unsafe skill repository." >&2
    exit 1
  fi
elif [ -n "$TARGET_SKILL" ]; then
  target_record=$(oceans_catalog_record_path "$CATALOG_ROOT" "$TARGET_SKILL")
  [ -f "$target_record" ] || {
    echo "Missing catalog record for lifecycle reconciliation: $TARGET_SKILL" >&2
    exit 1
  }
  target_state=$(oceans_catalog_state_for_skill "$CATALOG_ROOT" "$TARGET_SKILL" 2>/dev/null || true)
  [ -n "$target_state" ] || {
    echo "Invalid catalog state for lifecycle reconciliation: $TARGET_SKILL" >&2
    exit 1
  }
fi

INSTALL_TARGETS_FILE=$(mktemp "${TMPDIR:-/tmp}/oceans-install-targets.XXXXXX") || exit 1
cleanup_install_targets() { rm -f "$INSTALL_TARGETS_FILE"; }
trap 'cleanup_install_targets' EXIT
trap 'cleanup_install_targets; exit 129' HUP
trap 'cleanup_install_targets; exit 130' INT
trap 'cleanup_install_targets; exit 143' TERM

target_already_added() {
  wanted=$1
  while IFS='|' read -r ignored existing; do
    [ "$existing" != "$wanted" ] || return 0
  done < "$INSTALL_TARGETS_FILE"
  return 1
}

add_install_target() {
  runtime=$1
  install_root=$2
  create=$3
  [ "$create" -eq 0 ] || mkdir -p "$install_root"
  [ -d "$install_root" ] || { echo "Install root does not exist: $install_root" >&2; exit 1; }
  [ ! -L "$install_root" ] || { echo "Install root must not be a symlink: $install_root" >&2; exit 1; }
  install_root_real=$(absolute_path "$install_root")
  target_already_added "$install_root_real" && return 0
  oceans_register_runtime_root "$runtime" "$install_root_real" || exit 1
  printf '%s|%s\n' "$runtime" "$install_root_real" >> "$INSTALL_TARGETS_FILE"
}

add_first_existing_runtime_target() {
  runtime=$1
  create=$2
  [ "$runtime" != custom ] || { echo "custom-runtime-requires-path" >&2; exit 1; }
  first=
  candidates=$(runtime_candidates "$runtime")
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    candidate_real=$(absolute_path "$candidate")
    [ -n "$first" ] || first=$candidate_real
    if [ -d "$candidate_real" ]; then add_install_target "$runtime" "$candidate_real" 0; return; fi
  done <<EOF_CANDIDATES
$candidates
EOF_CANDIDATES
  [ "$create" -eq 0 ] || add_install_target "$runtime" "$first" 1
}

if [ -n "$INSTALL_ROOT" ]; then
  add_install_target custom "$INSTALL_ROOT" 1
elif [ "$ALL_EXISTING_RUNTIMES" -eq 1 ]; then
  roots_file=$(mktemp "${TMPDIR:-/tmp}/oceans-known-roots.XXXXXX") || exit 1
  if ! list_existing_root_records > "$roots_file"; then
    rm -f "$roots_file"
    echo "Unable to read known runtime roots." >&2
    exit 1
  fi
  while IFS='|' read -r known_runtime known_root; do
    [ -n "$known_runtime" ] || continue
    add_install_target "$known_runtime" "$known_root" 0
  done < "$roots_file"
  rm -f "$roots_file"
else
  add_first_existing_runtime_target "$RUNTIME" 1
fi

if [ ! -s "$INSTALL_TARGETS_FILE" ]; then
  if [ "$RECONCILE_ONLY" -eq 1 ]; then echo "runtime-reconcile: no-existing-roots"; exit 0; fi
  echo "No existing runtime skill roots found for install." >&2
  exit 1
fi

marker_value() {
  marker=$1
  key=$2
  sed -n "s/^$key=//p" "$marker" | sed -n '1p'
}

is_known_oceans_source() {
  repository=$1
  [ "$repository" = oceans-skills ] || [ "$repository" = community-skills ]
}

marker_is_managed() {
  marker=$1
  expected_skill=$2
  expected_root=$3
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  source_repository=$(marker_value "$marker" source_repository)
  is_known_oceans_source "$source_repository" || return 1
  marker_skill=$(marker_value "$marker" skill_name)
  marker_root=$(marker_value "$marker" install_root)
  [ -z "$marker_skill" ] || [ "$marker_skill" = "$expected_skill" ] || return 1
  [ -z "$marker_root" ] || [ "$marker_root" = "$expected_root" ] || return 1
  return 0
}

catalog_status_for_skill() {
  skill_name=$1
  [ "$CATALOG_ENABLED" -eq 1 ] || { printf 'active\n'; return; }
  state=$(oceans_catalog_state_for_skill "$CATALOG_ROOT" "$skill_name") || {
    echo "Missing or invalid catalog record: $skill_name" >&2
    return 1
  }
  printf '%s\n' "$state"
}

managed_disabled_root() {
  install_root_real=$1
  parent=$(dirname "$install_root_real")
  leaf=$(basename "$install_root_real")
  disabled_base=$parent/.oceans-disabled
  [ ! -L "$disabled_base" ] || { echo "Refusing unsafe disabled base: $disabled_base" >&2; return 1; }
  [ ! -e "$disabled_base" ] || [ -d "$disabled_base" ] || { echo "Disabled base is not a directory: $disabled_base" >&2; return 1; }
  disabled_root=$disabled_base/$leaf
  [ ! -L "$disabled_root" ] || { echo "Refusing unsafe disabled root: $disabled_root" >&2; return 1; }
  [ ! -e "$disabled_root" ] || [ -d "$disabled_root" ] || { echo "Disabled root is not a directory: $disabled_root" >&2; return 1; }
  printf '%s\n' "$disabled_root"
}

preserve_disabled_skill() {
  source_path=$1
  disabled_root=$2
  state=$3
  skill_name=$4
  [ ! -L "$source_path" ] || { echo "Refusing to disable symlinked managed skill: $skill_name" >&2; return 1; }
  destination=$disabled_root/$state/$skill_name
  staging=$(oceans_new_staging_directory "$destination") || return 1
  if ! cp -R "$source_path"/. "$staging"; then rm -rf "$staging"; return 1; fi
  if ! oceans_commit_staged_directory "$staging" "$destination"; then rm -rf "$staging"; return 1; fi
  rm -rf "$source_path"
  echo "Disabled managed $state skill: $skill_name"
  echo "Preserved at: $destination"
}

remove_disabled_copies() {
  disabled_root=$1
  skill_name=$2
  for state in pending-review deprecated archived blocked; do
    path=$disabled_root/$state/$skill_name
    if [ -d "$path" ] && [ ! -L "$path" ]; then rm -rf "$path"; fi
  done
}

reconcile_managed_skills() {
  install_root_real=$1
  [ "$CATALOG_ENABLED" -eq 1 ] || return 0
  disabled_root=$(managed_disabled_root "$install_root_real") || return 1
  reconcile_error=0

  if [ -n "$TARGET_SKILL" ]; then
    set -- "$install_root_real/$TARGET_SKILL"
  else
    set -- "$install_root_real"/*
  fi

  for installed_path in "$@"; do
    [ -d "$installed_path" ] || continue
    skill_name=${installed_path##*/}
    state=$(oceans_catalog_state_for_skill "$CATALOG_ROOT" "$skill_name" 2>/dev/null || true)
    if [ -z "$state" ]; then
      if [ -n "$TARGET_SKILL" ]; then
        echo "Missing or invalid catalog state during reconciliation: $skill_name" >&2
        reconcile_error=1
      fi
      continue
    fi

    marker=$installed_path/.oceans-skill-source
    managed=0
    if [ ! -L "$installed_path" ] && marker_is_managed "$marker" "$skill_name" "$install_root_real"; then managed=1; fi

    if [ "$state" = blocked ] && [ "$managed" -eq 0 ]; then
      echo "WARNING: Blocked skill has an unmanaged local copy that cannot be disabled automatically: $installed_path" >&2
      reconcile_error=1
      continue
    fi
    [ "$managed" -eq 1 ] || continue

    case "$state" in
      archived|blocked|pending-review)
        if ! preserve_disabled_skill "$installed_path" "$disabled_root" "$state" "$skill_name"; then
          echo "Failed to disable managed $state skill at: $installed_path" >&2
          reconcile_error=1
        fi
        ;;
      deprecated)
        echo "Retained deprecated managed skill without updating: $skill_name"
        ;;
    esac
  done

  if [ "$reconcile_error" -ne 0 ]; then
    echo "runtime-reconcile-conflict: one or more runtime copies require manual remediation." >&2
    return 1
  fi
}

report_catalog_only_pending() {
  [ "$CATALOG_ENABLED" -eq 1 ] || return 0
  if [ -n "$TARGET_SKILL" ]; then
    record_path=$(oceans_catalog_record_path "$CATALOG_ROOT" "$TARGET_SKILL")
    [ -f "$record_path" ] || return 0
    status=$(oceans_catalog_record_value "$record_path" status || true)
    [ "$status" = pending-review ] && echo "Skipped pending-review skill: $TARGET_SKILL"
    return 0
  fi
  for record_path in "$CATALOG_ROOT/skills"/*.skill; do
    [ -f "$record_path" ] || continue
    status=$(oceans_catalog_record_value "$record_path" status || true)
    [ "$status" = pending-review ] || continue
    skill_name=$(oceans_catalog_record_value "$record_path" name || true)
    [ -n "$skill_name" ] || continue
    echo "Skipped pending-review skill: $skill_name"
  done
}

catalog_allows_install() {
  repository_name=$1
  skill_name=$2
  [ "$CATALOG_ENABLED" -eq 1 ] || return 0
  state=$(catalog_status_for_skill "$skill_name") || return 2
  record_path=$(oceans_catalog_record_path "$CATALOG_ROOT" "$skill_name")
  catalog_repository=$(oceans_catalog_record_value "$record_path" package_repository || true)
  [ "$catalog_repository" = "$repository_name" ] || { echo "Catalog repository mismatch for $skill_name: $catalog_repository" >&2; return 2; }
  if [ "$state" != active ]; then
    echo "Skipped $state skill: $skill_name"
    return 1
  fi
  return 0
}

verify_source_package() {
  skill_path=$1
  skill_name=$2
  expected=
  if [ "$CATALOG_ENABLED" -eq 1 ]; then
    record_path=$(oceans_catalog_record_path "$CATALOG_ROOT" "$skill_name")
    expected=$(oceans_catalog_record_value "$record_path" content_sha256 || true)
  fi
  actual=$(oceans_skill_content_sha256 "$skill_path") || return 1
  if [ -n "$expected" ]; then
    oceans_valid_sha256 "$expected" || {
      echo "Invalid published content SHA-256 for $skill_name" >&2
      return 1
    }
    [ "$actual" = "$expected" ] || {
      echo "Published package content SHA-256 mismatch for $skill_name. Expected $expected, got $actual" >&2
      return 1
    }
  elif [ "$LIFECYCLE_RECONCILE" -eq 1 ]; then
    echo "Lifecycle reconciliation requires a published content SHA-256: $skill_name" >&2
    return 1
  else
    echo "WARNING: installing legacy package without catalog content SHA-256: $skill_name" >&2
  fi
  printf '%s\n' "$actual"
}

restore_runtime_target() {
  target=$1
  backup=$2
  had_target=$3
  if [ "$had_target" -eq 1 ]; then
    restore_stage=$(oceans_new_staging_directory "$target") || return 1
    if ! cp -R "$backup"/. "$restore_stage"; then rm -rf "$restore_stage"; return 1; fi
    oceans_commit_staged_directory "$restore_stage" "$target"
  else
    rm -rf "$target"
  fi
}

install_one_skill() {
  repository_name=$1
  skill_path=$2
  runtime=$3
  install_root_real=$4
  skill_name=${skill_path##*/}

  if catalog_allows_install "$repository_name" "$skill_name"; then
    :
  else
    catalog_result=$?
    [ "$catalog_result" -eq 1 ] && return 0
    return 1
  fi

  verified_content_sha=$(verify_source_package "$skill_path" "$skill_name") || return 1
  disabled_root=$(managed_disabled_root "$install_root_real") || return 1
  target=$install_root_real/$skill_name
  case "$target" in "$install_root_real"/*) ;; *) echo "Refusing to install outside install root: $target" >&2; return 1 ;; esac

  if [ -L "$target" ]; then
    echo "duplicate-local-wins: $skill_name"
    [ "$LIFECYCLE_RECONCILE" -eq 0 ] || return 1
    return 0
  fi

  is_update=0
  if [ -e "$target" ]; then
    marker=$target/.oceans-skill-source
    if ! marker_is_managed "$marker" "$skill_name" "$install_root_real"; then
      echo "duplicate-local-wins: $skill_name"
      [ "$LIFECYCLE_RECONCILE" -eq 0 ] || return 1
      return 0
    fi
    existing_source=$(marker_value "$marker" source_repository)
    if [ "$existing_source" != "$repository_name" ]; then
      echo "duplicate-managed-source-mismatch: $skill_name"
      [ "$LIFECYCLE_RECONCILE" -eq 0 ] || return 1
      return 0
    fi
    is_update=1
  fi

  backup_root=$(mktemp -d "${TMPDIR:-/tmp}/oceans-runtime-backup.XXXXXX") || return 1
  backup_path=$backup_root/package
  had_target=0
  if [ -d "$target" ]; then
    mkdir -p "$backup_path"
    if ! cp -R "$target"/. "$backup_path"; then rm -rf "$backup_root"; return 1; fi
    had_target=1
  fi

  staging_path=$(oceans_new_staging_directory "$target") || { rm -rf "$backup_root"; return 1; }
  if ! cp -R "$skill_path"/. "$staging_path"; then
    rm -rf "$staging_path" "$backup_root"
    echo "Failed to prepare skill update; existing installation was preserved: $skill_name" >&2
    return 1
  fi
  oceans_remove_excluded_paths "$staging_path"
  if ! oceans_normalize_skill_permissions "$staging_path"; then
    rm -rf "$staging_path" "$backup_root"
    return 1
  fi
  staged_content_sha=$(oceans_skill_content_sha256 "$staging_path") || {
    rm -rf "$staging_path" "$backup_root"
    return 1
  }
  if [ "$staged_content_sha" != "$verified_content_sha" ]; then
    rm -rf "$staging_path" "$backup_root"
    echo "Runtime staging content SHA-256 mismatch for $skill_name" >&2
    return 1
  fi

  record_path=$(oceans_catalog_record_path "$CATALOG_ROOT" "$skill_name")
  catalog_updated_at=
  [ "$CATALOG_ENABLED" -eq 0 ] || catalog_updated_at=$(oceans_catalog_record_value "$record_path" updated_at || true)
  {
    echo "source_repository=$repository_name"
    echo "source_path=$skill_path"
    echo "skill_name=$skill_name"
    echo "content_sha256=$staged_content_sha"
    echo "runtime=$runtime"
    echo "install_root=$install_root_real"
    echo "catalog_status=active"
    echo "catalog_updated_at=$catalog_updated_at"
  } > "$staging_path/.oceans-skill-source" || {
    rm -rf "$staging_path" "$backup_root"
    return 1
  }

  if ! oceans_commit_staged_directory "$staging_path" "$target"; then
    rm -rf "$staging_path" "$backup_root"
    echo "Failed to commit skill update; existing installation was restored: $skill_name" >&2
    return 1
  fi

  final_content_sha=$(oceans_skill_content_sha256 "$target" || true)
  if [ "$final_content_sha" != "$verified_content_sha" ]; then
    echo "Runtime content SHA-256 mismatch after commit for $skill_name; restoring previous copy." >&2
    restore_runtime_target "$target" "$backup_path" "$had_target" || \
      echo "CRITICAL: failed to restore runtime copy after content mismatch: $target" >&2
    rm -rf "$backup_root"
    return 1
  fi

  rm -rf "$backup_root"
  remove_disabled_copies "$disabled_root" "$skill_name"
  if [ "$is_update" -eq 1 ]; then echo "Updated managed oceans777 skill: $skill_name"; else echo "Installed skill: $skill_name"; fi
}

install_from_repository() {
  repository_name=$1
  source_path=$2
  runtime=$3
  install_root_real=$4
  if [ ! -d "$source_path" ]; then echo "Skipping missing source: $source_path"; return 0; fi

  if [ -n "$TARGET_SKILL" ]; then
    skill_path=$source_path/$TARGET_SKILL
    [ -d "$skill_path" ] || return 0
    install_one_skill "$repository_name" "$skill_path" "$runtime" "$install_root_real"
    return
  fi

  for skill_path in "$source_path"/*; do
    [ -d "$skill_path" ] || continue
    skill_name=${skill_path##*/}
    case "$skill_name" in
      ''|*[!a-z0-9-]*)
        echo "Skipping invalid skill folder name in $repository_name: $skill_name" >&2
        continue
        ;;
    esac
    install_one_skill "$repository_name" "$skill_path" "$runtime" "$install_root_real" || return 1
  done
}

overall_failure=0
while IFS='|' read -r target_runtime install_root_real; do
  [ -n "$target_runtime" ] || continue
  root_failure=0

  if ! reconcile_managed_skills "$install_root_real"; then
    root_failure=1
  fi
  report_catalog_only_pending

  if [ "$RECONCILE_ONLY" -eq 0 ]; then
    if ! install_from_repository oceans-skills "$FIRST_PARTY_SKILLS_ROOT" "$target_runtime" "$install_root_real"; then
      root_failure=1
    fi
    if ! install_from_repository community-skills "$COMMUNITY_SKILLS_ROOT" "$target_runtime" "$install_root_real"; then
      root_failure=1
    fi
  fi

  if [ "$root_failure" -eq 0 ]; then
    if [ "$RECONCILE_ONLY" -eq 1 ]; then
      echo "Reconciled lifecycle state for install root: $install_root_real"
    else
      echo "Install root: $install_root_real"
    fi
  else
    overall_failure=1
    [ "$BEST_EFFORT_ROOTS" -eq 1 ] || exit 1
  fi
done < "$INSTALL_TARGETS_FILE"

if [ "$overall_failure" -ne 0 ]; then
  echo "One or more runtime roots could not be reconciled." >&2
  exit 1
fi
