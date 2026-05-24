#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-validate-test.XXXXXX")

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
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

FIRST_PARTY_ROOT=$TEST_ROOT/oceans-skills
COMMUNITY_ROOT=$TEST_ROOT/community-skills

mkdir -p "$FIRST_PARTY_ROOT/duplicate-skill"
cat > "$FIRST_PARTY_ROOT/duplicate-skill/SKILL.md" <<'EOF'
---
name: duplicate-skill
description: First party.
---
EOF

mkdir -p "$COMMUNITY_ROOT/duplicate-skill"
cat > "$COMMUNITY_ROOT/duplicate-skill/SKILL.md" <<'EOF'
---
name: duplicate-skill
description: Community.
---
EOF
printf '%s\n' "upstream" > "$COMMUNITY_ROOT/duplicate-skill/UPSTREAM.md"
printf '%s\n' "patches" > "$COMMUNITY_ROOT/duplicate-skill/PATCHES.md"
printf '%s\n' "license" > "$COMMUNITY_ROOT/duplicate-skill/LICENSE"

if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected duplicate validation to fail." >&2
  exit 1
fi

assert_contains "$OUTPUT" "Duplicate skill name across repositories: duplicate-skill"

mkdir -p "$COMMUNITY_ROOT/empty-attribution-skill"
cat > "$COMMUNITY_ROOT/empty-attribution-skill/SKILL.md" <<'EOF'
---
name: empty-attribution-skill
description: Empty attribution.
---
EOF
: > "$COMMUNITY_ROOT/empty-attribution-skill/UPSTREAM.md"
printf '%s\n' "   " > "$COMMUNITY_ROOT/empty-attribution-skill/PATCHES.md"
: > "$COMMUNITY_ROOT/empty-attribution-skill/LICENSE"

if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected empty community attribution validation to fail." >&2
  exit 1
fi

assert_contains "$OUTPUT" "Missing or empty UPSTREAM.md in community-skills: empty-attribution-skill"
assert_contains "$OUTPUT" "Missing or empty PATCHES.md in community-skills: empty-attribution-skill"
assert_contains "$OUTPUT" "Missing or empty LICENSE in community-skills: empty-attribution-skill"

echo "Shell validate duplicate test passed."
