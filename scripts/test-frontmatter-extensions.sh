#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/skill-publish-rules.sh"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-frontmatter-test.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

assert_contains() { case "$1" in *"$2"*) ;; *) echo "Expected output to contain: $2" >&2; exit 1 ;; esac; }
assert_empty() { [ -z "$1" ] || { echo "Expected no metadata issues, found:" >&2; printf '%s\n' "$1" >&2; exit 1; }; }

write_skill() {
  name=$1
  shift
  mkdir -p "$TEST_ROOT/$name"
  cat > "$TEST_ROOT/$name/SKILL.md"
}

write_skill explicit-extension <<'EOF_SKILL'
---
name: explicit-extension
description: Valid explicit-invocation runtime metadata.
compatibility: Requires Python 3.10 or later.
argument-hint: "[new|audit] [topic]"
disable-model-invocation: true
user-invocable: true
background: false
when_to_use: Use only after an explicit invocation token.
arguments: "command and topic"
disallowed-tools: Bash
model: inherit
effort: medium
context: fork
agent: general-purpose
hooks:
  Stop: []
paths:
  - docs/**
shell: bash
metadata:
  version: "1.0.0"
---
EOF_SKILL
assert_empty "$(oceans_skill_metadata_issues "$TEST_ROOT/explicit-extension" explicit-extension)"

write_skill invalid-boolean <<'EOF_SKILL'
---
name: invalid-boolean
description: Invalid boolean fixture.
disable-model-invocation: "true"
---
EOF_SKILL
assert_contains "$(oceans_skill_metadata_issues "$TEST_ROOT/invalid-boolean" invalid-boolean)" "risk: disable-model-invocation must be a boolean"

write_skill invalid-compatibility <<'EOF_SKILL'
---
name: invalid-compatibility
description: Invalid compatibility fixture.
compatibility: |
  Requires Python.
---
EOF_SKILL
assert_contains "$(oceans_skill_metadata_issues "$TEST_ROOT/invalid-compatibility" invalid-compatibility)" "risk: compatibility must be a non-empty single-line string"

write_skill invalid-argument-hint <<'EOF_SKILL'
---
name: invalid-argument-hint
description: Invalid argument hint fixture.
argument-hint: |
  first line
  second line
---
EOF_SKILL
assert_contains "$(oceans_skill_metadata_issues "$TEST_ROOT/invalid-argument-hint" invalid-argument-hint)" "risk: argument-hint must be a non-empty single-line string"

write_skill unsupported-extension <<'EOF_SKILL'
---
name: unsupported-extension
description: Unknown extension fixture.
mystery-runtime-field: true
---
EOF_SKILL
assert_contains "$(oceans_skill_metadata_issues "$TEST_ROOT/unsupported-extension" unsupported-extension)" "risk: unsupported frontmatter key: mystery-runtime-field"

echo "Shell frontmatter extension test passed."
