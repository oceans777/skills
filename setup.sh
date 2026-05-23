#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "$REPO_ROOT"
. "$REPO_ROOT/scripts/common.sh"

echo "Setting up oceans777 skills..."

require_command git "Git is required but was not found in PATH."

echo "Initializing child repositories..."
invoke_git_with_retry "Initialize child repositories" 3 5 submodule update --init --recursive

sh "$REPO_ROOT/scripts/validate-skills.sh"
sh "$REPO_ROOT/scripts/install-skills.sh"

echo
echo "Setup complete."
echo "Next commands:"
echo "  ./oceans sync"
echo "  ./oceans status"
