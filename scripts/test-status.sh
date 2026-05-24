#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SCRIPT_PATH=$REPO_ROOT/scripts/status.sh
WRAPPER_PATH=$REPO_ROOT/oceans
SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-status-test.XXXXXX")

assert_contains() {
  text=$1
  expected=$2

  case "$text" in
    *"$expected"*)
      ;;
    *)
      echo "Expected output to contain: $expected" >&2
      echo "Actual output:" >&2
      echo "$text" >&2
      exit 1
      ;;
  esac
}

assert_not_contains() {
  text=$1
  unexpected=$2

  case "$text" in
    *"$unexpected"*)
      echo "Expected output not to contain: $unexpected" >&2
      echo "Actual output:" >&2
      echo "$text" >&2
      exit 1
      ;;
  esac
}

cleanup() {
  rm -rf "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

CODEX_HOME=$SANDBOX_ROOT/codex-home
AGENTS_HOME=$SANDBOX_ROOT/agents-home
CLAUDE_HOME=$SANDBOX_ROOT/claude-home
OPENCLAW_HOME=$SANDBOX_ROOT/openclaw-home
HERMES_HOME=$SANDBOX_ROOT/hermes-home
export CODEX_HOME AGENTS_HOME CLAUDE_HOME OPENCLAW_HOME HERMES_HOME

mkdir -p "$CODEX_HOME/skills/codex-managed"
mkdir -p "$CLAUDE_HOME/skills/claude-managed"
mkdir -p "$CLAUDE_HOME/skills/claude-private"
printf '%s\n' "source_repository=oceans-skills" > "$CODEX_HOME/skills/codex-managed/.oceans-skill-source"
printf '%s\n' "source_repository=community-skills" > "$CLAUDE_HOME/skills/claude-managed/.oceans-skill-source"

OUTPUT=$(sh "$SCRIPT_PATH")
assert_contains "$OUTPUT" "Runtime skill roots:"
assert_contains "$OUTPUT" "runtime: codex"
assert_contains "$OUTPUT" "path: $CODEX_HOME/skills"
assert_contains "$OUTPUT" "runtime: claude"
assert_contains "$OUTPUT" "path: $CLAUDE_HOME/skills"
assert_contains "$OUTPUT" "runtime: agents"
assert_contains "$OUTPUT" "status: missing"
assert_contains "$OUTPUT" "managed_oceans_skills: 1"

OUTPUT=$(sh "$SCRIPT_PATH" --runtime claude)
assert_contains "$OUTPUT" "runtime: claude"
assert_contains "$OUTPUT" "path: $CLAUDE_HOME/skills"
assert_not_contains "$OUTPUT" "path: $CODEX_HOME/skills"

OUTPUT=$(sh "$SCRIPT_PATH" --all-existing-runtimes)
assert_contains "$OUTPUT" "runtime: codex"
assert_contains "$OUTPUT" "runtime: claude"
assert_not_contains "$OUTPUT" "path: $AGENTS_HOME/skills"

OUTPUT=$(sh "$WRAPPER_PATH" status --runtime claude)
assert_contains "$OUTPUT" "runtime: claude"
assert_contains "$OUTPUT" "path: $CLAUDE_HOME/skills"
assert_not_contains "$OUTPUT" "path: $CODEX_HOME/skills"

echo "Shell status test passed."
