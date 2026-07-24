#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-published-idea-ledger.XXXXXX")
TEST_ROOT=$(CDPATH= cd "$TEST_ROOT" && pwd -P)
. "$REPO_ROOT/scripts/skill-content-hash.sh"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

assert_contains() { case "$1" in *"$2"*) ;; *) echo "Expected output to contain: $2" >&2; exit 1 ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) echo "Expected output not to contain: $2" >&2; exit 1 ;; *) ;; esac; }
assert_path_exists() { [ -e "$1" ] || { echo "Expected path to exist: $1" >&2; exit 1; }; }
assert_file_contains() { grep -F -q "$2" "$1" || { echo "Expected $1 to contain: $2" >&2; exit 1; }; }

PUBLISHED_SKILL=$REPO_ROOT/repos/oceans-skills/skills/idea-ledger
CONTENT_SHA256=$(oceans_skill_content_sha256 "$PUBLISHED_SKILL")
printf 'idea-ledger-content-sha256=%s\n' "$CONTENT_SHA256"
assert_file_contains "$REPO_ROOT/catalog/skills/idea-ledger.skill" "content_sha256=$CONTENT_SHA256"

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
assert_not_contains "$OUTPUT" "legacy package without catalog content SHA-256: idea-ledger"

verify_runtime() {
  runtime=$1
  root=$2
  skill=$root/idea-ledger
  marker=$skill/.oceans-skill-source
  cli=$skill/scripts/idea_ledger.py

  assert_contains "$OUTPUT" "Install root: $root"
  assert_path_exists "$skill/SKILL.md"
  assert_path_exists "$skill/LICENSE"
  assert_path_exists "$cli"
  assert_file_contains "$skill/SKILL.md" "disable-model-invocation: true"
  assert_file_contains "$marker" "source_repository=oceans-skills"
  assert_file_contains "$marker" "runtime=$runtime"
  version=$(python "$cli" --version)
  [ "$version" = "2.1.0" ] || { echo "Unexpected idea-ledger version in $runtime: $version" >&2; exit 1; }
}

verify_runtime codex "$CODEX_HOME/skills"
verify_runtime agents "$AGENTS_HOME/skills"
verify_runtime claude "$CLAUDE_HOME/skills"
verify_runtime openclaw "$OPENCLAW_HOME/skills"
verify_runtime hermes "$HERMES_HOME/skills"

PROJECT_ROOT=$TEST_ROOT/project
mkdir -p "$PROJECT_ROOT"
CODEX_CLI=$CODEX_HOME/skills/idea-ledger/scripts/idea_ledger.py
python "$CODEX_CLI" init --root "$PROJECT_ROOT" >/dev/null
python "$CODEX_CLI" validate --root "$PROJECT_ROOT" >/dev/null
python "$CODEX_CLI" status --root "$PROJECT_ROOT" --json >/dev/null
assert_path_exists "$PROJECT_ROOT/.idea-ledger/config.json"

printf '%s\n' "$OUTPUT"
printf '%s\n' "Published idea-ledger install and runtime verification passed."
