#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SKILL_ROOTS_LIB_ONLY=1 . "$SCRIPT_DIR/skill-roots.sh"

INSTALL_ROOT=
RUNTIME=codex
ALL_EXISTING_RUNTIMES=0
FIRST_PARTY_SKILLS_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_SKILLS_ROOT=$REPO_ROOT/repos/community-skills/skills

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-root)
      if [ "$#" -lt 2 ]; then
        echo "--install-root needs a path." >&2
        exit 2
      fi
      INSTALL_ROOT=$2
      shift 2
      ;;
    --runtime)
      if [ "$#" -lt 2 ]; then
        echo "--runtime needs a value." >&2
        exit 2
      fi
      RUNTIME=$2
      shift 2
      ;;
    --all-existing-runtimes)
      ALL_EXISTING_RUNTIMES=1
      shift
      ;;
    --first-party-root)
      if [ "$#" -lt 2 ]; then
        echo "--first-party-root needs a path." >&2
        exit 2
      fi
      FIRST_PARTY_SKILLS_ROOT=$2
      shift 2
      ;;
    --community-root)
      if [ "$#" -lt 2 ]; then
        echo "--community-root needs a path." >&2
        exit 2
      fi
      COMMUNITY_SKILLS_ROOT=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

INSTALL_TARGETS_FILE=${TMPDIR:-/tmp}/oceans-install-targets.$$
: > "$INSTALL_TARGETS_FILE"

cleanup_install_targets() {
  rm -f "$INSTALL_TARGETS_FILE"
}
trap cleanup_install_targets EXIT INT TERM

add_install_target() {
  runtime=$1
  install_root=$2
  create=$3

  if [ "$create" -eq 1 ]; then
    mkdir -p "$install_root"
  fi

  if [ ! -d "$install_root" ]; then
    echo "Install root does not exist: $install_root" >&2
    exit 1
  fi

  install_root_real=$(absolute_path "$install_root")
  printf '%s|%s\n' "$runtime" "$install_root_real" >> "$INSTALL_TARGETS_FILE"
}

add_first_existing_runtime_target() {
  runtime=$1
  create=$2

  if [ "$runtime" = "custom" ]; then
    echo "custom-runtime-requires-path" >&2
    exit 1
  fi

  first=
  candidates=$(runtime_candidates "$runtime")
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    candidate_real=$(absolute_path "$candidate")
    if [ -z "$first" ]; then
      first=$candidate_real
    fi
    if [ -d "$candidate_real" ]; then
      add_install_target "$runtime" "$candidate_real" 0
      return
    fi
  done <<EOF
$candidates
EOF

  if [ "$create" -eq 1 ]; then
    add_install_target "$runtime" "$first" 1
  fi
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

if [ ! -s "$INSTALL_TARGETS_FILE" ]; then
  echo "No existing runtime skill roots found for install." >&2
  exit 1
fi

source_repository_from_marker() {
  marker=$1
  sed -n 's/^source_repository=//p' "$marker" | sed -n '1p'
}

is_known_oceans_source() {
  repository=$1
  [ "$repository" = "oceans-skills" ] || [ "$repository" = "community-skills" ]
}

install_from_repository() {
  repository_name=$1
  source_path=$2
  runtime=$3
  install_root_real=$4

  if [ ! -d "$source_path" ]; then
    echo "Skipping missing source: $source_path"
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

    target=$install_root_real/$skill_name
    case "$target" in
      "$install_root_real"/*)
        ;;
      *)
        echo "Refusing to install outside install root: $target" >&2
        exit 1
        ;;
    esac

    if [ -e "$target" ]; then
      marker=$target/.oceans-skill-source
      if [ ! -f "$marker" ]; then
        echo "duplicate-local-wins: $skill_name"
        continue
      fi

      existing_source=$(source_repository_from_marker "$marker")
      if ! is_known_oceans_source "$existing_source"; then
        echo "duplicate-unknown-marker: $skill_name"
        continue
      fi

      if [ "$existing_source" != "$repository_name" ]; then
        echo "duplicate-managed-source-mismatch: $skill_name"
        continue
      fi

      rm -rf "$target"
      is_update=1
    else
      is_update=0
    fi

    cp -R "$skill_path" "$target"
    {
      echo "source_repository=$repository_name"
      echo "source_path=$skill_path"
      echo "runtime=$runtime"
      echo "install_root=$install_root_real"
    } > "$target/.oceans-skill-source"
    if [ "$is_update" -eq 1 ]; then
      echo "Updated managed oceans777 skill: $skill_name"
    else
      echo "Installed skill: $skill_name"
    fi
  done
}

while IFS='|' read -r target_runtime install_root_real; do
  [ -n "$target_runtime" ] || continue
  install_from_repository "oceans-skills" "$FIRST_PARTY_SKILLS_ROOT" "$target_runtime" "$install_root_real"
  install_from_repository "community-skills" "$COMMUNITY_SKILLS_ROOT" "$target_runtime" "$install_root_real"
  echo "Install root: $install_root_real"
done < "$INSTALL_TARGETS_FILE"
