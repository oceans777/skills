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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-root) [ "$#" -ge 2 ] || { echo "--install-root needs a path." >&2; exit 2; }; INSTALL_ROOT=$2; shift 2 ;;
    --runtime) [ "$#" -ge 2 ] || { echo "--runtime needs a value." >&2; exit 2; }; RUNTIME=$2; shift 2 ;;
    --all-existing-runtimes) ALL_EXISTING_RUNTIMES=1; shift ;;
    --first-party-root|--first-party-skills-root) [ "$#" -ge 2 ] || { echo "$1 needs a path." >&2; exit 2; }; FIRST_PARTY_SKILLS_ROOT=$2; CUSTOM_SOURCE_ROOTS=1; shift 2 ;;
    --community-root|--community-skills-root) [ "$#" -ge 2 ] || { echo "$1 needs a path." >&2; exit 2; }; COMMUNITY_SKILLS_ROOT=$2; CUSTOM_SOURCE_ROOTS=1; shift 2 ;;
    --catalog-root) [ "$#" -ge 2 ] || { echo "--catalog-root needs a path." >&2; exit 2; }; CATALOG_ROOT=$2; CATALOG_EXPLICIT=1; shift 2 ;;
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

set -- --first-party-root "$FIRST_PARTY_SKILLS_ROOT" --community-root "$COMMUNITY_SKILLS_ROOT"
if [ "$WITHOUT_CATALOG" -eq 1 ]; then set -- "$@" --without-catalog; else set -- "$@" --catalog-root "$CATALOG_ROOT"; fi
if ! sh "$SCRIPT_DIR/validate-skills.sh" "$@" >/dev/null; then
  echo "Refusing to install from an invalid or unsafe skill repository." >&2
  exit 1
fi
CATALOG_ENABLED=1
[ "$WITHOUT_CATALOG" -eq 0 ] || CATALOG_ENABLED=0

INSTALL_TARGETS_FILE=$(mktemp "${TMPDIR:-/tmp}/oceans-install-targets.XXXXXX") || exit 1
cleanup_install_targets() { rm -f "$INSTALL_TARGETS_FILE"; }
trap 'cleanup_install_targets' EXIT
trap 'cleanup_install_targets; exit 129' HUP
trap 'cleanup_install_targets; exit 130' INT
trap 'cleanup_install_targets; exit 143' TERM

add_install_target() {
  runtime=$1; install_root=$2; create=$3
  [ "$create" -eq 0 ] || mkdir -p "$install_root"
  [ -d "$install_root" ] || { echo "Install root does not exist: $install_root" >&2; exit 1; }
  [ ! -L "$install_root" ] || { echo "Install root must not be a symlink: $install_root" >&2; exit 1; }
  install_root_real=$(absolute_path "$install_root")
  printf '%s|%s\n' "$runtime" "$install_root_real" >> "$INSTALL_TARGETS_FILE"
}

add_first_existing_runtime_target() {
  runtime=$1; create=$2
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
  list_existing_root_records | while IFS='|' read -r known_runtime known_root; do
    [ -n "$known_runtime" ] || continue
    add_install_target "$known_runtime" "$known_root" 0
  done
else
  add_first_existing_runtime_target "$RUNTIME" 1
fi
[ -s "$INSTALL_TARGETS_FILE" ] || { echo "No existing runtime skill roots found for install." >&2; exit 1; }

marker_value() {
  marker=$1; key=$2
  sed -n "s/^$key=//p" "$marker" | sed -n '1p'
}

is_known_oceans_source() {
  repository=$1
  [ "$repository" = oceans-skills ] || [ "$repository" = community-skills ]
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
  printf '%s/.oceans-disabled/%s\n' "$parent" "$leaf"
}

preserve_disabled_skill() {
  source_path=$1; disabled_root=$2; state=$3; skill_name=$4
  [ ! -L "$source_path" ] || { echo "Refusing to disable symlinked managed skill: $skill_name" >&2; return 1; }
  [ ! -L "$disabled_root" ] || { echo "Refusing unsafe disabled root: $disabled_root" >&2; return 1; }
  destination=$disabled_root/$state/$skill_name
  staging=$(oceans_new_staging_directory "$destination") || return 1
  if ! cp -R "$source_path"/. "$staging"; then rm -rf "$staging"; return 1; fi
  if ! oceans_commit_staged_directory "$staging" "$destination"; then rm -rf "$staging"; return 1; fi
  rm -rf "$source_path"
  echo "Disabled managed $state skill: $skill_name"
  echo "Preserved at: $destination"
}

remove_disabled_copies() {
  disabled_root=$1; skill_name=$2
  for state in pending-review deprecated archived blocked; do
    path=$disabled_root/$state/$skill_name
    if [ -d "$path" ] && [ ! -L "$path" ]; then rm -rf "$path"; fi
  done
}

reconcile_managed_skills() {
  install_root_real=$1
  [ "$CATALOG_ENABLED" -eq 1 ] || return 0
  disabled_root=$(managed_disabled_root "$install_root_real")
  for installed_path in "$install_root_real"/*; do
    [ -d "$installed_path" ] || continue
    [ ! -L "$installed_path" ] || continue
    skill_name=${installed_path##*/}
    marker=$installed_path/.oceans-skill-source
    [ -f "$marker" ] || continue
    existing_source=$(marker_value "$marker" source_repository)
    is_known_oceans_source "$existing_source" || continue
    if state=$(catalog_status_for_skill "$skill_name"); then :; else continue; fi
    case "$state" in
      archived|blocked|pending-review)
        preserve_disabled_skill "$installed_path" "$disabled_root" "$state" "$skill_name"
        ;;
      deprecated)
        echo "Retained deprecated managed skill without updating: $skill_name"
        ;;
    esac
  done
}

catalog_allows_install() {
  repository_name=$1; skill_name=$2
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

install_from_repository() {
  repository_name=$1; source_path=$2; runtime=$3; install_root_real=$4
  if [ ! -d "$source_path" ]; then echo "Skipping missing source: $source_path"; return; fi
  disabled_root=$(managed_disabled_root "$install_root_real")

  for skill_path in "$source_path"/*; do
    [ -d "$skill_path" ] || continue
    skill_name=${skill_path##*/}
    case "$skill_name" in ''|*[!a-z0-9-]*) echo "Skipping invalid skill folder name in $repository_name: $skill_name" >&2; continue ;; esac
    if catalog_allows_install "$repository_name" "$skill_name"; then :; else
      catalog_status=$?
      [ "$catalog_status" -eq 1 ] && continue
      exit 1
    fi

    target=$install_root_real/$skill_name
    case "$target" in "$install_root_real"/*) ;; *) echo "Refusing to install outside install root: $target" >&2; exit 1 ;; esac
    if [ -L "$target" ]; then echo "duplicate-local-wins: $skill_name"; continue; fi

    if [ -e "$target" ]; then
      marker=$target/.oceans-skill-source
      if [ ! -f "$marker" ]; then echo "duplicate-local-wins: $skill_name"; continue; fi
      existing_source=$(marker_value "$marker" source_repository)
      if ! is_known_oceans_source "$existing_source"; then echo "duplicate-unknown-marker: $skill_name"; continue; fi
      if [ "$existing_source" != "$repository_name" ]; then echo "duplicate-managed-source-mismatch: $skill_name"; continue; fi
      is_update=1
    else
      is_update=0
    fi

    staging_path=$(oceans_new_staging_directory "$target") || exit 1
    if ! cp -R "$skill_path"/. "$staging_path"; then
      rm -rf "$staging_path"
      echo "Failed to prepare skill update; existing installation was preserved: $skill_name" >&2
      exit 1
    fi
    oceans_remove_excluded_paths "$staging_path"
    record_path=$(oceans_catalog_record_path "$CATALOG_ROOT" "$skill_name")
    catalog_updated_at=
    [ "$CATALOG_ENABLED" -eq 0 ] || catalog_updated_at=$(oceans_catalog_record_value "$record_path" updated_at || true)
    {
      echo "source_repository=$repository_name"
      echo "source_path=$skill_path"
      echo "runtime=$runtime"
      echo "install_root=$install_root_real"
      echo "catalog_status=active"
      echo "catalog_updated_at=$catalog_updated_at"
    } > "$staging_path/.oceans-skill-source" || { rm -rf "$staging_path"; exit 1; }

    if ! oceans_commit_staged_directory "$staging_path" "$target"; then
      rm -rf "$staging_path"
      echo "Failed to commit skill update; existing installation was restored: $skill_name" >&2
      exit 1
    fi
    remove_disabled_copies "$disabled_root" "$skill_name"
    if [ "$is_update" -eq 1 ]; then echo "Updated managed oceans777 skill: $skill_name"; else echo "Installed skill: $skill_name"; fi
  done
}

while IFS='|' read -r target_runtime install_root_real; do
  [ -n "$target_runtime" ] || continue
  reconcile_managed_skills "$install_root_real"
  install_from_repository oceans-skills "$FIRST_PARTY_SKILLS_ROOT" "$target_runtime" "$install_root_real"
  install_from_repository community-skills "$COMMUNITY_SKILLS_ROOT" "$target_runtime" "$install_root_real"
  echo "Install root: $install_root_real"
done < "$INSTALL_TARGETS_FILE"
