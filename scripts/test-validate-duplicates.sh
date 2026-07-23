#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-validate-test.XXXXXX")
FIRST_PARTY_ROOT=$TEST_ROOT/oceans-skills
COMMUNITY_ROOT=$TEST_ROOT/community-skills
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM
mkdir -p "$FIRST_PARTY_ROOT" "$COMMUNITY_ROOT"

assert_contains() { case "$1" in *"$2"*) ;; *) echo "Expected output to contain: $2" >&2; exit 1 ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) echo "Expected output not to contain: $2" >&2; exit 1 ;; esac; }
run_validate() { sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_PARTY_ROOT" --community-root "$COMMUNITY_ROOT" --without-catalog 2>&1; }
expect_failure() { if OUTPUT=$(run_validate); then echo "$1" >&2; exit 1; fi; }
write_skill() {
  root=$1; folder=$2; name=$3; description=$4
  mkdir -p "$root/$folder"
  cat > "$root/$folder/SKILL.md" <<EOF_SKILL
---
name: $name
description: $description
---
EOF_SKILL
}

write_skill "$FIRST_PARTY_ROOT" duplicate-skill duplicate-skill "First party."
write_skill "$COMMUNITY_ROOT" duplicate-skill duplicate-skill "Community."
printf '%s\n' upstream > "$COMMUNITY_ROOT/duplicate-skill/UPSTREAM.md"
printf '%s\n' patches > "$COMMUNITY_ROOT/duplicate-skill/PATCHES.md"
printf '%s\n' license > "$COMMUNITY_ROOT/duplicate-skill/LICENSE"
expect_failure "Expected duplicate validation to fail."
assert_contains "$OUTPUT" "Duplicate skill name across repositories: duplicate-skill"

write_skill "$COMMUNITY_ROOT" empty-attribution-skill empty-attribution-skill "Empty attribution."
: > "$COMMUNITY_ROOT/empty-attribution-skill/UPSTREAM.md"
printf '%s\n' '   ' > "$COMMUNITY_ROOT/empty-attribution-skill/PATCHES.md"
: > "$COMMUNITY_ROOT/empty-attribution-skill/LICENSE"
expect_failure "Expected empty attribution validation to fail."
assert_contains "$OUTPUT" "Missing or empty UPSTREAM.md in community-skills: empty-attribution-skill"
assert_contains "$OUTPUT" "Missing or empty PATCHES.md in community-skills: empty-attribution-skill"
assert_contains "$OUTPUT" "Missing or empty LICENSE in community-skills: empty-attribution-skill"

mkdir -p "$FIRST_PARTY_ROOT/missing-license-reference"
cat > "$FIRST_PARTY_ROOT/missing-license-reference/SKILL.md" <<'EOF_SKILL'
---
name: missing-license-reference
description: Missing license reference.
license: Complete terms in LICENSE.txt
---
EOF_SKILL
expect_failure "Expected missing license reference to fail."
assert_contains "$OUTPUT" "Missing referenced license file in oceans-skills: missing-license-reference"

write_skill "$FIRST_PARTY_ROOT" metadata-mismatch different-name "Name mismatch."
expect_failure "Expected metadata mismatch to fail."
assert_contains "$OUTPUT" "risk: skill name does not match folder name"
mkdir -p "$FIRST_PARTY_ROOT/bad folder"
printf '%s\n' missing > "$FIRST_PARTY_ROOT/bad folder/README.md"
expect_failure "Expected invalid folder to fail."
assert_contains "$OUTPUT" "risk: invalid skill folder name"

mkdir -p "$FIRST_PARTY_ROOT/secret-risk"
cat > "$FIRST_PARTY_ROOT/secret-risk/SKILL.md" <<'EOF_SKILL'
---
name: secret-risk
description: Risk scan fixture.
---
api_key=sk-example-not-a-real-secret
EOF_SKILL
expect_failure "Expected secret-like content to fail."
assert_contains "$OUTPUT" "secret-risk: risk: secret-like text"

write_skill "$FIRST_PARTY_ROOT" valid-utf8 valid-utf8 "Valid UTF-8 fixture."
printf '%s\n' '中文内容应当通过严格 UTF-8 检查。' >> "$FIRST_PARTY_ROOT/valid-utf8/SKILL.md"
expect_failure "Earlier invalid fixtures must keep validation failing."
assert_not_contains "$OUTPUT" "valid-utf8: risk: binary or unreadable file"
write_skill "$FIRST_PARTY_ROOT" blank-utf8 blank-utf8 "Blank UTF-8 fixture."
printf '\n' > "$FIRST_PARTY_ROOT/blank-utf8/blank.txt"
expect_failure "Earlier invalid fixtures must keep validation failing."
assert_not_contains "$OUTPUT" "blank-utf8: risk: binary or unreadable file"

write_skill "$FIRST_PARTY_ROOT" invalid-utf8 invalid-utf8 "Invalid UTF-8 fixture."
printf '\377\376' >> "$FIRST_PARTY_ROOT/invalid-utf8/SKILL.md"
expect_failure "Expected invalid UTF-8 to fail."
assert_contains "$OUTPUT" "invalid-utf8: risk: binary or unreadable file"

mkdir -p "$FIRST_PARTY_ROOT/unterminated-frontmatter"
printf '%s\n' '---' 'name: unterminated-frontmatter' 'description: This frontmatter never closes.' > "$FIRST_PARTY_ROOT/unterminated-frontmatter/SKILL.md"
expect_failure "Expected unterminated frontmatter to fail."
assert_contains "$OUTPUT" "risk: missing or unterminated skill frontmatter"

mkdir -p "$FIRST_PARTY_ROOT/duplicate-key"
cat > "$FIRST_PARTY_ROOT/duplicate-key/SKILL.md" <<'EOF_SKILL'
---
name: duplicate-key
name: shadow-name
description: Duplicate key fixture.
---
EOF_SKILL
expect_failure "Expected duplicate frontmatter key to fail."
assert_contains "$OUTPUT" "risk: duplicate frontmatter key: name"

mkdir -p "$FIRST_PARTY_ROOT/block-description"
cat > "$FIRST_PARTY_ROOT/block-description/SKILL.md" <<'EOF_SKILL'
---
name: block-description
description: |
  Valid multiline description.
---
EOF_SKILL
expect_failure "Earlier invalid fixtures must keep validation failing."
assert_not_contains "$OUTPUT" "Invalid skill metadata in oceans-skills: block-description"

write_skill "$FIRST_PARTY_ROOT" unsafe-nested-path unsafe-nested-path "Unsafe nested path fixture."
UNSAFE_NESTED_NAME=$(printf 'bad\nname.txt')
printf '%s\n' unsafe > "$FIRST_PARTY_ROOT/unsafe-nested-path/$UNSAFE_NESTED_NAME"
expect_failure "Expected unsafe nested path to fail."
assert_contains "$OUTPUT" "unsafe-nested-path: risk: unsafe filesystem path"

echo "Shell validate duplicate test passed."
