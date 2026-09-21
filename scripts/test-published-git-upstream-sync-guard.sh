#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-published-git-upstream-sync-guard.XXXXXX")
TEST_ROOT=$(CDPATH= cd "$TEST_ROOT" && pwd -P)
. "$REPO_ROOT/scripts/skill-content-hash.sh"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

assert_contains() { case "$1" in *"$2"*) ;; *) echo "Expected output to contain: $2" >&2; exit 1 ;; esac; }
assert_path_exists() { [ -e "$1" ] || { echo "Expected path to exist: $1" >&2; exit 1; }; }
assert_path_missing() { [ ! -e "$1" ] || { echo "Expected path to be absent: $1" >&2; exit 1; }; }
assert_file_contains() { grep -F -q "$2" "$1" || { echo "Expected $1 to contain: $2" >&2; exit 1; }; }

SKILL_NAME=git-upstream-sync-guard
PUBLISHED_SKILL=$REPO_ROOT/repos/oceans-skills/skills/$SKILL_NAME
CATALOG_RECORD=$REPO_ROOT/catalog/skills/$SKILL_NAME.skill
CONTENT_SHA256=$(oceans_skill_content_sha256 "$PUBLISHED_SKILL")
printf '%s-content-sha256=%s\n' "$SKILL_NAME" "$CONTENT_SHA256"
assert_file_contains "$CATALOG_RECORD" "status=active"
assert_file_contains "$CATALOG_RECORD" "content_sha256=$CONTENT_SHA256"

for archived in agent-operating-system discuz-x5 experience-triage idea-ledger ui-ux-pro-max; do
  assert_file_contains "$REPO_ROOT/catalog/skills/$archived.skill" "status=archived"
done

CODEX_HOME=$TEST_ROOT/codex
AGENTS_HOME=$TEST_ROOT/agents
CLAUDE_HOME=$TEST_ROOT/claude
OPENCLAW_HOME=$TEST_ROOT/openclaw
HERMES_HOME=$TEST_ROOT/hermes
HOME=$TEST_ROOT/home
export CODEX_HOME AGENTS_HOME CLAUDE_HOME OPENCLAW_HOME HERMES_HOME HOME
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1

for runtime_home in "$CODEX_HOME" "$AGENTS_HOME" "$CLAUDE_HOME" "$OPENCLAW_HOME" "$HERMES_HOME"; do
  mkdir -p "$runtime_home/skills"
done

OUTPUT=$(sh "$REPO_ROOT/scripts/install-skills.sh" --all-existing-runtimes 2>&1)
assert_contains "$OUTPUT" "Installed skill: $SKILL_NAME"

verify_runtime() {
  runtime=$1
  root=$2
  skill=$root/$SKILL_NAME
  marker=$skill/.oceans-skill-source
  assert_path_exists "$skill/SKILL.md"
  assert_path_exists "$skill/README.md"
  assert_path_exists "$skill/references/operating-contract.md"
  assert_path_exists "$skill/scripts/init-upstream.sh"
  assert_path_exists "$skill/scripts/sync-upstream.sh"
  assert_file_contains "$skill/SKILL.md" "name: git-upstream-sync-guard"
  assert_file_contains "$marker" "source_repository=oceans-skills"
  assert_file_contains "$marker" "runtime=$runtime"
  for archived in agent-operating-system discuz-x5 experience-triage idea-ledger ui-ux-pro-max; do
    assert_path_missing "$root/$archived"
  done
}

verify_runtime codex "$CODEX_HOME/skills"
verify_runtime agents "$AGENTS_HOME/skills"
verify_runtime claude "$CLAUDE_HOME/skills"
verify_runtime openclaw "$OPENCLAW_HOME/skills"
verify_runtime hermes "$HERMES_HOME/skills"

printf '%s\n' "$OUTPUT"
printf '%s\n' "Published git-upstream-sync-guard install and archive verification passed."
