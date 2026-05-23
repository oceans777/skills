#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
. "$REPO_ROOT/scripts/common.sh"

if [ -n "${CODEX_HOME:-}" ]; then
  INSTALL_ROOT=$CODEX_HOME/skills
else
  INSTALL_ROOT=$HOME/.codex/skills
fi

echo "Repository:"
invoke_git "Read repository status" status --short --branch

echo
echo "Child repositories:"
invoke_git "Read child repository status" submodule status

echo
echo "Install root:"
echo "  $INSTALL_ROOT"

if [ -d "$INSTALL_ROOT" ]; then
  managed_count=0
  for skill_path in "$INSTALL_ROOT"/*; do
    if [ -d "$skill_path" ] && [ -f "$skill_path/.oceans-skill-source" ]; then
      managed_count=$((managed_count + 1))
    fi
  done
  echo "Managed oceans777 skills: $managed_count"
else
  echo "Install root does not exist yet."
fi
