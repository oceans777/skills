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

assert_not_contains() {
  text=$1
  unexpected=$2

  case "$text" in
    *"$unexpected"*)
      echo "Expected output not to contain: $unexpected" >&2
      echo "$text" >&2
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

INVALID_ROOT=$SANDBOX_ROOT/invalid-local-skills
mkdir -p "$INVALID_ROOT/bad skill" "$INVALID_ROOT/folder-name" "$INVALID_ROOT/missing-description" "$INVALID_ROOT/bad missing"
cat > "$INVALID_ROOT/bad skill/SKILL.md" <<'EOF'
---
name: bad skill
description: Invalid directory name.
---
EOF
cat > "$INVALID_ROOT/folder-name/SKILL.md" <<'EOF'
---
name: different-name
description: Name mismatch.
---
EOF
cat > "$INVALID_ROOT/missing-description/SKILL.md" <<'EOF'
---
name: missing-description
---
EOF
printf '%s\n' "Missing SKILL.md and invalid folder name." > "$INVALID_ROOT/bad missing/README.md"
OUTPUT=$(sh "$REPO_ROOT/scripts/import-skills.sh" \
  --source-root "$INVALID_ROOT" \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT")
assert_contains "$OUTPUT" "bad skill"
assert_contains "$OUTPUT" "status: invalid-skill-name"
assert_contains "$OUTPUT" "folder-name"
assert_contains "$OUTPUT" "status: invalid-skill-metadata"
assert_contains "$OUTPUT" "risk: skill name does not match folder name"
assert_contains "$OUTPUT" "missing-description"
assert_contains "$OUTPUT" "risk: missing skill description"
assert_contains "$OUTPUT" "bad missing"
assert_contains "$OUTPUT" "risk: invalid skill folder name"
assert_not_contains "$OUTPUT" "risk: none detected"

LICENSE_ROOT=$SANDBOX_ROOT/license-local-skills
mkdir -p "$LICENSE_ROOT/missing-license-skill"
cat > "$LICENSE_ROOT/missing-license-skill/SKILL.md" <<'EOF'
---
name: missing-license-skill
description: Missing license reference.
license: Complete terms in LICENSE.txt
---
EOF
OUTPUT=$(sh "$REPO_ROOT/scripts/import-skills.sh" \
  --source-root "$LICENSE_ROOT" \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT")
assert_contains "$OUTPUT" "missing-license-skill"
assert_contains "$OUTPUT" "risk: missing referenced license file"

BENIGN_ROOT=$SANDBOX_ROOT/benign-local-skills
mkdir -p "$BENIGN_ROOT/benign-route-skill/data/__pycache__"
cat > "$BENIGN_ROOT/benign-route-skill/SKILL.md" <<'EOF'
---
name: benign-route-skill
description: Benign route path.
---
app/api/users/route.ts
/homework/project
EOF
printf '%s\n' 'C:\Users\example\cache-only' > "$BENIGN_ROOT/benign-route-skill/data/__pycache__/cache.pyc"
OUTPUT=$(sh "$REPO_ROOT/scripts/import-skills.sh" \
  --source-root "$BENIGN_ROOT" \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT")
assert_contains "$OUTPUT" "benign-route-skill"
assert_contains "$OUTPUT" "risk: none detected"
assert_not_contains "$OUTPUT" "risk: local absolute path"

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

OUTPUT=$(sh "$REPO_ROOT/scripts/import-skills.sh" \
  --source-root "$LOCAL_SKILLS_ROOT" \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT" \
  --format json)
assert_contains "$OUTPUT" '"mode":"report only"'
assert_contains "$OUTPUT" '"name":"my-skill"'
assert_contains "$OUTPUT" '"status":"duplicate-local-wins"'
assert_contains "$OUTPUT" '"risks":["risk: secret-like text","risk: local absolute path"]'

HOME=$SANDBOX_ROOT/fallback-home
export HOME
unset OPENCLAW_HOME HERMES_HOME
mkdir -p "$HOME/.openclaw/skills/openclaw-home-skill"
cat > "$HOME/.openclaw/skills/openclaw-home-skill/SKILL.md" <<'EOF'
---
name: openclaw-home-skill
description: OpenClaw home root.
---
EOF
mkdir -p "$HOME/.config/openclaw/skills/openclaw-config-skill"
cat > "$HOME/.config/openclaw/skills/openclaw-config-skill/SKILL.md" <<'EOF'
---
name: openclaw-config-skill
description: OpenClaw config root.
---
EOF

OUTPUT=$(sh "$REPO_ROOT/scripts/import-skills.sh" \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT")
assert_contains "$OUTPUT" "source_root: $HOME/.openclaw/skills"
assert_contains "$OUTPUT" "source_root: $HOME/.config/openclaw/skills"
assert_contains "$OUTPUT" "openclaw-home-skill"
assert_contains "$OUTPUT" "openclaw-config-skill"

echo "Shell import test passed."
