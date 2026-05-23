#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-import-test.XXXXXX")
REPO_SKILL_ROOT=$REPO_ROOT/repos/oceans-skills/skills
REPO_SKILL_NAME=my-skill

assert_contains() {
  text=$1
  expected=$2

  case "$text" in
    *"$expected"*)
      ;;
    *)
      echo "Expected output to contain: $expected" >&2
      exit 1
      ;;
  esac
}

cleanup() {
  rm -rf "$REPO_SKILL_ROOT/$REPO_SKILL_NAME"
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

rm -rf "$REPO_SKILL_ROOT/$REPO_SKILL_NAME"
mkdir -p "$REPO_SKILL_ROOT/$REPO_SKILL_NAME"
cat > "$REPO_SKILL_ROOT/$REPO_SKILL_NAME/SKILL.md" <<'EOF'
---
name: my-skill
description: Repository version.
---
EOF

mkdir -p "$TEST_ROOT/my-skill"
cat > "$TEST_ROOT/my-skill/SKILL.md" <<'EOF'
---
name: my-skill
description: Test skill.
---
EOF

mkdir -p "$TEST_ROOT/risky-skill"
cat > "$TEST_ROOT/risky-skill/SKILL.md" <<'EOF'
---
name: risky-skill
description: Uses /Users/example/private-notes.
---
api_key: test-value
EOF

mkdir -p "$TEST_ROOT/no-skill"
printf '%s\n' 'Missing SKILL.md' > "$TEST_ROOT/no-skill/README.md"

mkdir -p "$TEST_ROOT/.system"
cat > "$TEST_ROOT/.system/SKILL.md" <<'EOF'
---
name: system
description: System skill.
---
EOF

OUTPUT=$(sh "$REPO_ROOT/scripts/import-skills.sh" --source-root "$TEST_ROOT")

assert_contains "$OUTPUT" "No files were copied."
assert_contains "$OUTPUT" "my-skill"
assert_contains "$OUTPUT" "duplicate-local-wins"
assert_contains "$OUTPUT" "repository_match: oceans-skills"
assert_contains "$OUTPUT" "action: keep local skill; repository version will not overwrite it"
assert_contains "$OUTPUT" "risky-skill"
assert_contains "$OUTPUT" "risk: secret-like text"
assert_contains "$OUTPUT" "risk: local absolute path"
assert_contains "$OUTPUT" "no-skill"
assert_contains "$OUTPUT" "missing-skill-md"
assert_contains "$OUTPUT" ".system"
assert_contains "$OUTPUT" "skip-system"

echo "Shell import test passed."
