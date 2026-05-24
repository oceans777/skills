#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-import-test.XXXXXX")
LOCAL_SKILLS_ROOT=$SANDBOX_ROOT/local-skills
FIRST_PARTY_ROOT=$SANDBOX_ROOT/repo/oceans-skills/skills
COMMUNITY_ROOT=$SANDBOX_ROOT/repo/community-skills/skills
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
  rm -rf "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$LOCAL_SKILLS_ROOT" "$FIRST_PARTY_ROOT" "$COMMUNITY_ROOT"

mkdir -p "$FIRST_PARTY_ROOT/$REPO_SKILL_NAME"
cat > "$FIRST_PARTY_ROOT/$REPO_SKILL_NAME/SKILL.md" <<'EOF'
---
name: my-skill
description: Repository version.
---
EOF

mkdir -p "$LOCAL_SKILLS_ROOT/my-skill"
cat > "$LOCAL_SKILLS_ROOT/my-skill/SKILL.md" <<'EOF'
---
name: my-skill
description: Test skill.
---
EOF

mkdir -p "$LOCAL_SKILLS_ROOT/risky-skill"
cat > "$LOCAL_SKILLS_ROOT/risky-skill/SKILL.md" <<'EOF'
---
name: risky-skill
description: Uses /Users/example/private-notes.
---
api_key: test-value
EOF

mkdir -p "$LOCAL_SKILLS_ROOT/no-skill"
printf '%s\n' 'Missing SKILL.md' > "$LOCAL_SKILLS_ROOT/no-skill/README.md"

mkdir -p "$LOCAL_SKILLS_ROOT/.system"
cat > "$LOCAL_SKILLS_ROOT/.system/SKILL.md" <<'EOF'
---
name: system
description: System skill.
---
EOF

OUTPUT=$(sh "$REPO_ROOT/scripts/import-skills.sh" \
  --source-root "$LOCAL_SKILLS_ROOT" \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT")

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

CODEX_HOME=$SANDBOX_ROOT/codex-home
AGENTS_HOME=$SANDBOX_ROOT/agents-home
CLAUDE_HOME=$SANDBOX_ROOT/claude-home
export CODEX_HOME AGENTS_HOME CLAUDE_HOME
mkdir -p "$CODEX_HOME/skills" "$AGENTS_HOME/skills" "$CLAUDE_HOME/skills"

mkdir -p "$CODEX_HOME/skills/codex-only-skill"
cat > "$CODEX_HOME/skills/codex-only-skill/SKILL.md" <<'EOF'
---
name: codex-only-skill
description: Codex only.
---
EOF

mkdir -p "$AGENTS_HOME/skills/shared-runtime-skill"
cat > "$AGENTS_HOME/skills/shared-runtime-skill/SKILL.md" <<'EOF'
---
name: shared-runtime-skill
description: Agents copy.
---
EOF

mkdir -p "$CLAUDE_HOME/skills/shared-runtime-skill"
cat > "$CLAUDE_HOME/skills/shared-runtime-skill/SKILL.md" <<'EOF'
---
name: shared-runtime-skill
description: Claude copy.
---
EOF

OUTPUT=$(sh "$REPO_ROOT/scripts/import-skills.sh" \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT")

assert_contains "$OUTPUT" "Source roots:"
assert_contains "$OUTPUT" "runtime: codex"
assert_contains "$OUTPUT" "runtime: agents"
assert_contains "$OUTPUT" "runtime: claude"
assert_contains "$OUTPUT" "source_root: $CODEX_HOME/skills"
assert_contains "$OUTPUT" "source_path: $AGENTS_HOME/skills/shared-runtime-skill"
assert_contains "$OUTPUT" "shared-runtime-skill"
assert_contains "$OUTPUT" "status: duplicate-local-runtime"
assert_contains "$OUTPUT" "local_runtime_match: agents, claude"

echo "Shell import test passed."
