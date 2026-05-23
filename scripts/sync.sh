#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
. "$REPO_ROOT/scripts/common.sh"

invoke_git_with_retry "Pull entry repository" 3 5 pull --ff-only
invoke_git "Sync child repository URLs" submodule sync --recursive
invoke_git_with_retry "Update child repositories" 3 5 submodule update --init --recursive
