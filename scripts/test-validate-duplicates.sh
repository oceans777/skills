#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-validate-test.XXXXXX")
TEST_ROOT=$(CDPATH= cd "$TEST_ROOT" && pwd -P)

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

mkdir -p "$FIRST_PARTY_ROOT/missing-license-reference"
cat > "$FIRST_PARTY_ROOT/missing-license-reference/SKILL.md" <<'EOF'
---
name: missing-license-reference
description: Missing license reference.
license: Complete terms in LICENSE.txt
---
EOF
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected validate to fail for missing referenced license file." >&2
  exit 1
fi
assert_contains "$OUTPUT" "Missing referenced license file in oceans-skills: missing-license-reference"

mkdir -p "$FIRST_PARTY_ROOT/metadata-mismatch"
cat > "$FIRST_PARTY_ROOT/metadata-mismatch/SKILL.md" <<'EOF'
---
name: different-name
description: Name mismatch.
---
EOF
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected validate to fail for skill metadata mismatch." >&2
  exit 1
fi
assert_contains "$OUTPUT" "Invalid skill metadata in oceans-skills: metadata-mismatch: risk: skill name does not match folder name"

mkdir -p "$FIRST_PARTY_ROOT/bad folder"
printf '%s\n' "Missing SKILL.md." > "$FIRST_PARTY_ROOT/bad folder/README.md"
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected validate to fail for invalid folder name without SKILL.md." >&2
  exit 1
fi
assert_contains "$OUTPUT" "Invalid skill metadata in oceans-skills: bad folder: risk: invalid skill folder name"

mkdir -p "$FIRST_PARTY_ROOT/secret-risk"
cat > "$FIRST_PARTY_ROOT/secret-risk/SKILL.md" <<'EOF'
---
name: secret-risk
description: Risk scan fixture.
---
api_key=sk-example-not-a-real-secret
EOF
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected validate to fail for secret-like content." >&2
  exit 1
fi
assert_contains "$OUTPUT" "Unsafe skill content in oceans-skills: secret-risk: risk: secret-like text"

mkdir -p "$FIRST_PARTY_ROOT/valid-utf8"
cat > "$FIRST_PARTY_ROOT/valid-utf8/SKILL.md" <<'EOF'
---
name: valid-utf8
description: Valid UTF-8 fixture.
---
中文内容应当在 macOS 和 Linux 上通过严格 UTF-8 检查。
EOF
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected earlier invalid fixtures to keep validation failing." >&2
  exit 1
fi
assert_not_contains "$OUTPUT" "Unsafe skill content in oceans-skills: valid-utf8: risk: binary or unreadable file"

mkdir -p "$FIRST_PARTY_ROOT/blank-utf8"
cat > "$FIRST_PARTY_ROOT/blank-utf8/SKILL.md" <<'EOF'
---
name: blank-utf8
description: Blank UTF-8 fixture.
---

EOF
printf '\n' > "$FIRST_PARTY_ROOT/blank-utf8/blank.txt"
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected earlier invalid fixtures to keep validation failing." >&2
  exit 1
fi
assert_not_contains "$OUTPUT" "Unsafe skill content in oceans-skills: blank-utf8: risk: binary or unreadable file"

mkdir -p "$FIRST_PARTY_ROOT/invalid-utf8"
cat > "$FIRST_PARTY_ROOT/invalid-utf8/SKILL.md" <<'EOF'
---
name: invalid-utf8
description: Invalid UTF-8 fixture.
---
EOF
printf '\377\376' >> "$FIRST_PARTY_ROOT/invalid-utf8/SKILL.md"
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected validate to fail for invalid UTF-8." >&2
  exit 1
fi
assert_contains "$OUTPUT" "Unsafe skill content in oceans-skills: invalid-utf8: risk: binary or unreadable file"

mkdir -p "$FIRST_PARTY_ROOT/unterminated-frontmatter"
cat > "$FIRST_PARTY_ROOT/unterminated-frontmatter/SKILL.md" <<'EOF'
---
name: unterminated-frontmatter
description: This frontmatter never closes.
EOF
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected unterminated frontmatter to fail." >&2
  exit 1
fi
assert_contains "$OUTPUT" "risk: missing or unterminated skill frontmatter"

mkdir -p "$FIRST_PARTY_ROOT/duplicate-key"
cat > "$FIRST_PARTY_ROOT/duplicate-key/SKILL.md" <<'EOF'
---
name: duplicate-key
name: shadow-name
description: Duplicate key fixture.
---
EOF
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected duplicate frontmatter key to fail." >&2
  exit 1
fi
assert_contains "$OUTPUT" "risk: duplicate frontmatter key: name"

mkdir -p "$FIRST_PARTY_ROOT/block-description"
cat > "$FIRST_PARTY_ROOT/block-description/SKILL.md" <<'EOF'
---
name: block-description
description: |
  Valid multiline description.
---
EOF
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected earlier invalid fixtures to keep validation failing." >&2
  exit 1
fi
assert_not_contains "$OUTPUT" "Invalid skill metadata in oceans-skills: block-description"

mkdir -p "$FIRST_PARTY_ROOT/unsafe-nested-path"
cat > "$FIRST_PARTY_ROOT/unsafe-nested-path/SKILL.md" <<'EOF'
---
name: unsafe-nested-path
description: Unsafe nested path fixture.
---
EOF
UNSAFE_NESTED_NAME=$(printf 'bad\nname.txt')
printf '%s\n' unsafe > "$FIRST_PARTY_ROOT/unsafe-nested-path/$UNSAFE_NESTED_NAME"
if OUTPUT=$(sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" 2>&1); then
  echo "Expected unsafe nested path to fail." >&2
  exit 1
fi
assert_contains "$OUTPUT" "Unsafe skill content in oceans-skills: unsafe-nested-path: risk: unsafe filesystem path"

echo "Shell validate duplicate test passed."
