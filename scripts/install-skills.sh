#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
INSTALL_ROOT=${CODEX_HOME:+$CODEX_HOME/skills}

if [ -z "${INSTALL_ROOT:-}" ]; then
  INSTALL_ROOT=$HOME/.codex/skills
fi

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
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$INSTALL_ROOT"
INSTALL_ROOT_REAL=$(CDPATH= cd "$INSTALL_ROOT" && pwd -P)

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

    target=$INSTALL_ROOT_REAL/$skill_name
    case "$target" in
      "$INSTALL_ROOT_REAL"/*)
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

      rm -rf "$target"
      is_update=1
    else
      is_update=0
    fi

    cp -R "$skill_path" "$target"
    {
      echo "source_repository=$repository_name"
      echo "source_path=$skill_path"
    } > "$target/.oceans-skill-source"
    if [ "$is_update" -eq 1 ]; then
      echo "Updated managed oceans777 skill: $skill_name"
    else
      echo "Installed skill: $skill_name"
    fi
  done
}

install_from_repository "oceans-skills" "$REPO_ROOT/repos/oceans-skills/skills"
install_from_repository "community-skills" "$REPO_ROOT/repos/community-skills/skills"

echo "Install root: $INSTALL_ROOT"
