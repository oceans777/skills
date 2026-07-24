#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-runtime-reconcile-test.XXXXXX")
FIRST=$TEST_ROOT/oceans/skills
COMMUNITY=$TEST_ROOT/community/skills
CATALOG=$TEST_ROOT/catalog
ROOT_A=$TEST_ROOT/runtime-a/skills
ROOT_B=$TEST_ROOT/runtime-b/skills
ROOT_C=$TEST_ROOT/runtime-c/skills
export HOME=$TEST_ROOT/home
export OCEANS_RUNTIME_ROOTS_FILE=$TEST_ROOT/runtime-roots
export CODEX_HOME=$TEST_ROOT/missing-codex
export AGENTS_HOME=$TEST_ROOT/missing-agents
export CLAUDE_HOME=$TEST_ROOT/missing-claude
export OPENCLAW_HOME=$TEST_ROOT/missing-openclaw
export HERMES_HOME=$TEST_ROOT/missing-hermes
COMMIT_A=0123456789012345678901234567890123456789

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$FIRST" "$COMMUNITY" "$CATALOG/skills" \
  "$CATALOG/review-queue/oceans-skills" "$CATALOG/review-queue/community-skills" \
  "$ROOT_A" "$ROOT_B"

. "$REPO_ROOT/scripts/skill-publish-rules.sh"
. "$REPO_ROOT/scripts/skill-catalog.sh"

fail() { echo "$*" >&2; exit 1; }
assert_file_contains() { grep -F -q "$2" "$1" || fail "Expected $1 to contain: $2"; }

write_skill() {
  root=$1
  name=$2
  version=$3
  mkdir -p "$root/$name"
  cat > "$root/$name/SKILL.md" <<EOF_SKILL
---
name: $name
description: Runtime reconciliation fixture.
---
version=$version
EOF_SKILL
}

write_record() {
  skill=$1
  digest=$(oceans_skill_content_sha256 "$FIRST/$skill")
  oceans_catalog_write_record "$CATALOG" "$skill" active oceans-skills \
    https://github.com/example/oceans "skills/$skill" main "$COMMIT_A" \
    "" "" "" "" "" "" "fixture active" "$digest" ""
}

write_skill "$FIRST" danger-skill safe
write_skill "$FIRST" unrelated-skill stable
write_record danger-skill
write_record unrelated-skill

sh "$REPO_ROOT/scripts/install-skills.sh" \
  --install-root "$ROOT_A" \
  --first-party-root "$FIRST" \
  --community-root "$COMMUNITY" \
  --catalog-root "$CATALOG" >/dev/null
sh "$REPO_ROOT/scripts/install-skills.sh" \
  --install-root "$ROOT_B" \
  --first-party-root "$FIRST" \
  --community-root "$COMMUNITY" \
  --catalog-root "$CATALOG" >/dev/null

[ "$(wc -l < "$OCEANS_RUNTIME_ROOTS_FILE" | tr -d '[:space:]')" -eq 2 ] || fail "Custom runtime roots were not persisted."
assert_file_contains "$ROOT_A/danger-skill/.oceans-skill-source" "content_sha256="
assert_file_contains "$ROOT_A/danger-skill/.oceans-skill-source" "skill_name=danger-skill"

rm -f "$ROOT_A/danger-skill/.oceans-skill-source"
UNRELATED_RECORD=$CATALOG/skills/unrelated-skill.skill
cp "$UNRELATED_RECORD" "$TEST_ROOT/unrelated-record"
printf '%s\n' 'unknown_field=value' >> "$UNRELATED_RECORD"

if sh "$REPO_ROOT/scripts/catalog-skill.sh" block \
  --catalog-root "$CATALOG" \
  --first-party-root "$FIRST" \
  --community-root "$COMMUNITY" \
  --skill danger-skill \
  --reason security-incident >"$TEST_ROOT/block-output" 2>"$TEST_ROOT/block-error"; then
  fail "Block incorrectly reported complete success despite an unmanaged runtime conflict."
fi

DANGER_RECORD=$CATALOG/skills/danger-skill.skill
[ "$(oceans_catalog_record_value "$DANGER_RECORD" status)" = blocked ] || fail "Block state was not committed."
[ -f "$ROOT_A/danger-skill/SKILL.md" ] || fail "Unmanaged conflicting copy was removed."
[ ! -e "$ROOT_B/danger-skill" ] || fail "A later managed runtime root was not reconciled after an earlier conflict."
DISABLED_B=$TEST_ROOT/runtime-b/.oceans-disabled/skills/blocked/danger-skill
[ -f "$DISABLED_B/SKILL.md" ] || fail "Managed blocked copy was not preserved."
assert_file_contains "$TEST_ROOT/block-error" "one or more runtime roots were not reconciled"

rm -rf "$ROOT_A/danger-skill"
cp "$TEST_ROOT/unrelated-record" "$UNRELATED_RECORD"
sh "$REPO_ROOT/scripts/catalog-skill.sh" unblock \
  --catalog-root "$CATALOG" \
  --first-party-root "$FIRST" \
  --community-root "$COMMUNITY" \
  --skill danger-skill \
  --reason remediated >/dev/null
assert_file_contains "$ROOT_A/danger-skill/SKILL.md" "version=safe"
assert_file_contains "$ROOT_B/danger-skill/SKILL.md" "version=safe"

printf '%s\n' 'tampered-source' >> "$FIRST/danger-skill/SKILL.md"
if sh "$REPO_ROOT/scripts/install-skills.sh" \
  --install-root "$ROOT_C" \
  --first-party-root "$FIRST" \
  --community-root "$COMMUNITY" \
  --catalog-root "$CATALOG" \
  --target-skill danger-skill \
  --lifecycle-reconcile >"$TEST_ROOT/tamper-output" 2>"$TEST_ROOT/tamper-error"; then
  fail "Runtime installation accepted a source package that no longer matched the catalog fingerprint."
fi
[ ! -e "$ROOT_C/danger-skill" ] || fail "Tampered source was installed."
assert_file_contains "$TEST_ROOT/tamper-error" "Published package content SHA-256 mismatch"

write_skill "$FIRST" danger-skill safe
chmod 755 "$FIRST/danger-skill/SKILL.md"
sh "$REPO_ROOT/scripts/install-skills.sh" \
  --install-root "$ROOT_C" \
  --first-party-root "$FIRST" \
  --community-root "$COMMUNITY" \
  --catalog-root "$CATALOG" \
  --target-skill danger-skill \
  --lifecycle-reconcile >/dev/null
[ ! -x "$ROOT_C/danger-skill/SKILL.md" ] || fail "Runtime copy kept an executable bit instead of canonical permissions."
assert_file_contains "$ROOT_C/danger-skill/.oceans-skill-source" "content_sha256="

echo "Shell runtime reconciliation test passed."
