#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)

if [ -n "${CODEX_HOME:-}" ]; then
  INSTALL_ROOT=$CODEX_HOME/skills
else
  INSTALL_ROOT=$HOME/.codex/skills
fi

mkdir -p "$INSTALL_ROOT"
INSTALL_ROOT_REAL=$(CDPATH= cd "$INSTALL_ROOT" && pwd -P)

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
        echo "Skipping local unmanaged skill: $skill_name"
        continue
      fi
      rm -rf "$target"
    fi

    cp -R "$skill_path" "$target"
    {
      echo "source_repository=$repository_name"
      echo "source_path=$skill_path"
    } > "$target/.oceans-skill-source"
    echo "Installed skill: $skill_name"
  done
}

install_from_repository "oceans-skills" "$REPO_ROOT/repos/oceans-skills/skills"
install_from_repository "community-skills" "$REPO_ROOT/repos/community-skills/skills"

echo "Install root: $INSTALL_ROOT"
