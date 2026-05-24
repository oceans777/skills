#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SCRIPT_PATH=$REPO_ROOT/scripts/skill-roots.sh
SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-roots-test.XXXXXX")

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

run_roots_success() {
  output=$(sh "$SCRIPT_PATH" "$@")
  printf '%s' "$output"
}

run_roots_failure() {
  set +e
  output=$(sh "$SCRIPT_PATH" "$@" 2>&1)
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "Expected skill-roots.sh to fail. Output:" >&2
    echo "$output" >&2
    exit 1
  fi
  printf '%s' "$output"
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

for root in "$CODEX_HOME" "$AGENTS_HOME" "$CLAUDE_HOME" "$OPENCLAW_HOME" "$HERMES_HOME"; do
  mkdir -p "$root/skills"
done

OUTPUT=$(run_roots_success --mode list)
assert_contains "$OUTPUT" "runtime: codex"
assert_contains "$OUTPUT" "runtime: agents"
assert_contains "$OUTPUT" "runtime: claude"
assert_contains "$OUTPUT" "runtime: openclaw"
assert_contains "$OUTPUT" "runtime: hermes"
assert_contains "$OUTPUT" "status: exists"
assert_contains "$OUTPUT" "path: $CODEX_HOME/skills"

OUTPUT=$(run_roots_success --mode install-default)
assert_contains "$OUTPUT" "runtime: codex"
assert_contains "$OUTPUT" "path: $CODEX_HOME/skills"
assert_not_contains "$OUTPUT" "runtime: claude"
assert_not_contains "$OUTPUT" "runtime: agents"

OUTPUT=$(run_roots_success --mode install-all-existing)
assert_contains "$OUTPUT" "runtime: codex"
assert_contains "$OUTPUT" "runtime: agents"
assert_contains "$OUTPUT" "runtime: claude"
assert_contains "$OUTPUT" "runtime: openclaw"
assert_contains "$OUTPUT" "runtime: hermes"

HOME=$SANDBOX_ROOT/fallback-home
export HOME
unset OPENCLAW_HOME HERMES_HOME
mkdir -p "$HOME/.openclaw/skills" "$HOME/.config/openclaw/skills"
mkdir -p "$HOME/.hermes/skills" "$HOME/.config/hermes/skills"
OUTPUT=$(run_roots_success --mode install-all-existing)
assert_contains "$OUTPUT" "path: $HOME/.openclaw/skills"
assert_contains "$OUTPUT" "path: $HOME/.config/openclaw/skills"
assert_contains "$OUTPUT" "path: $HOME/.hermes/skills"
assert_contains "$OUTPUT" "path: $HOME/.config/hermes/skills"

OUTPUT=$(run_roots_success --mode stage --runtime agents)
assert_contains "$OUTPUT" "runtime: agents"
assert_contains "$OUTPUT" "path: $AGENTS_HOME/skills"

CUSTOM_ROOT=$SANDBOX_ROOT/custom-skills
mkdir -p "$CUSTOM_ROOT"
OUTPUT=$(run_roots_success --mode stage --source-root "$CUSTOM_ROOT")
assert_contains "$OUTPUT" "runtime: custom"
assert_contains "$OUTPUT" "path: $CUSTOM_ROOT"

OUTPUT=$(run_roots_failure --mode install --runtime custom)
assert_contains "$OUTPUT" "custom-runtime-requires-path"

echo "Shell skill roots test passed."
