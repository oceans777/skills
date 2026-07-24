#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-catalog-test.XXXXXX")
FIRST=$TEST_ROOT/oceans/skills
COMMUNITY=$TEST_ROOT/community/skills
CATALOG=$TEST_ROOT/catalog
INSTALL=$TEST_ROOT/runtime/skills
COMMIT_A=0123456789012345678901234567890123456789
COMMIT_B=abcdefabcdefabcdefabcdefabcdefabcdefabcd
export OCEANS_RUNTIME_ROOTS_FILE=$TEST_ROOT/runtime-roots
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$FIRST" "$COMMUNITY" "$CATALOG/skills" "$CATALOG/review-queue/oceans-skills" "$CATALOG/review-queue/community-skills" "$INSTALL"
. "$REPO_ROOT/scripts/skill-publish-rules.sh"
. "$REPO_ROOT/scripts/skill-catalog.sh"

fail() { echo "$*" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "Expected output to contain: $2" ;; esac; }
assert_file_contains() { grep -F -q "$2" "$1" || fail "Expected $1 to contain: $2"; }
write_skill() {
  root=$1; name=$2; version=$3
  mkdir -p "$root/$name"
  cat > "$root/$name/SKILL.md" <<EOF_SKILL
---
name: $name
description: Catalog lifecycle fixture.
---
version=$version
EOF_SKILL
}
write_record() {
  skill=$1; status=$2; commit=$3; reason=${4:-}; replacement=${5:-}
  digest=$(oceans_skill_content_sha256 "$FIRST/$skill")
  oceans_catalog_write_record "$CATALOG" "$skill" "$status" oceans-skills \
    https://github.com/example/oceans "skills/$skill" main "$commit" \
    "" "" "" "" "$replacement" "$reason" "fixture $status" "$digest" ""
}

write_skill "$FIRST" active-skill old
write_skill "$FIRST" archived-skill archived
write_skill "$FIRST" blocked-skill blocked
write_skill "$FIRST" deprecated-skill deprecated
write_record active-skill active "$COMMIT_A"
write_record archived-skill archived "$COMMIT_A" retired active-skill
write_record blocked-skill blocked "$COMMIT_A" security-incident
write_record deprecated-skill deprecated "$COMMIT_A" superseded active-skill

mkdir -p "$INSTALL/archived-skill"
printf '%s\n' managed-archive > "$INSTALL/archived-skill/SKILL.md"
printf '%s\n' source_repository=oceans-skills > "$INSTALL/archived-skill/.oceans-skill-source"
mkdir -p "$INSTALL/blocked-skill"
printf '%s\n' managed-blocked-copy > "$INSTALL/blocked-skill/SKILL.md"
printf '%s\n' source_repository=oceans-skills > "$INSTALL/blocked-skill/.oceans-skill-source"
mkdir -p "$INSTALL/deprecated-skill"
printf '%s\n' installed-deprecated-version > "$INSTALL/deprecated-skill/SKILL.md"
printf '%s\n' source_repository=oceans-skills > "$INSTALL/deprecated-skill/.oceans-skill-source"

sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG" >/dev/null
OUTPUT=$(sh "$REPO_ROOT/scripts/install-skills.sh" --install-root "$INSTALL" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG")
[ -f "$INSTALL/active-skill/SKILL.md" ] || fail "Active skill was not installed."
[ ! -e "$INSTALL/archived-skill" ] || fail "Managed archived copy remained active."
[ ! -e "$INSTALL/blocked-skill" ] || fail "Managed blocked copy remained active."
DISABLED_ARCHIVED=$TEST_ROOT/runtime/.oceans-disabled/skills/archived/archived-skill
DISABLED_BLOCKED=$TEST_ROOT/runtime/.oceans-disabled/skills/blocked/blocked-skill
[ -f "$DISABLED_ARCHIVED/SKILL.md" ] || fail "Managed archived copy was not preserved."
[ -f "$DISABLED_BLOCKED/SKILL.md" ] || fail "Managed blocked copy was not preserved."
assert_contains "$OUTPUT" "Disabled managed archived skill: archived-skill"
assert_contains "$OUTPUT" "Disabled managed blocked skill: blocked-skill"
assert_contains "$OUTPUT" "Retained deprecated managed skill without updating: deprecated-skill"
assert_file_contains "$INSTALL/deprecated-skill/SKILL.md" installed-deprecated-version

sh "$REPO_ROOT/scripts/catalog-skill.sh" restore --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --install-root "$INSTALL" --skill archived-skill >/dev/null
RECORD=$(oceans_catalog_record_path "$CATALOG" archived-skill)
[ "$(oceans_catalog_record_value "$RECORD" status)" = active ] || fail "Restore did not activate archived skill."
[ -z "$(oceans_catalog_record_value "$RECORD" status_reason)" ] || fail "Restore kept stale status reason."
[ -z "$(oceans_catalog_record_value "$RECORD" replacement)" ] || fail "Restore kept stale replacement."
assert_file_contains "$INSTALL/archived-skill/SKILL.md" version=archived

sh "$REPO_ROOT/scripts/catalog-skill.sh" block --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --install-root "$INSTALL" --skill archived-skill --reason reblocked >/dev/null
[ ! -e "$INSTALL/archived-skill" ] || fail "Block did not immediately disable the managed runtime copy."
if sh "$REPO_ROOT/scripts/catalog-skill.sh" restore --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --skill archived-skill >/dev/null 2>&1; then fail "Blocked skill was restored through ordinary restore."; fi
if sh "$REPO_ROOT/scripts/catalog-skill.sh" unblock --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --skill archived-skill >/dev/null 2>&1; then fail "Unblock succeeded without repair reason."; fi
sh "$REPO_ROOT/scripts/catalog-skill.sh" unblock --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --install-root "$INSTALL" --skill archived-skill --reason remediated >/dev/null
assert_file_contains "$INSTALL/archived-skill/SKILL.md" version=archived

rm -f "$INSTALL/archived-skill/.oceans-skill-source"
if sh "$REPO_ROOT/scripts/catalog-skill.sh" block --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --install-root "$INSTALL" --skill archived-skill --reason second-incident >"$TEST_ROOT/block-output" 2>"$TEST_ROOT/block-error"; then
  fail "Block incorrectly reported success for an unmanaged local copy."
fi
assert_file_contains "$TEST_ROOT/block-error" "one or more runtime roots were not reconciled"
assert_file_contains "$INSTALL/archived-skill/SKILL.md" version=archived
[ "$(oceans_catalog_record_value "$RECORD" status)" = blocked ] || fail "Security state did not remain blocked after unmanaged runtime conflict."
rm -rf "$INSTALL/archived-skill"

REVIEW=$CATALOG/review-queue/oceans-skills/active-skill
write_skill "$CATALOG/review-queue/oceans-skills" active-skill candidate
CANDIDATE_DIGEST=$(oceans_skill_content_sha256 "$REVIEW")
RECORD=$(oceans_catalog_record_path "$CATALOG" active-skill)
CURRENT_DIGEST=$(oceans_catalog_record_value "$RECORD" content_sha256 || true)
oceans_catalog_write_record "$CATALOG" active-skill active oceans-skills \
  https://github.com/example/oceans skills/active-skill main "$COMMIT_A" \
  https://github.com/example/upstream skill main "$COMMIT_B" "" "" "queued candidate" "$CURRENT_DIGEST" "$CANDIDATE_DIGEST"
sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG" >/dev/null
sh "$REPO_ROOT/scripts/install-skills.sh" --install-root "$INSTALL" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG" >/dev/null
assert_file_contains "$INSTALL/active-skill/SKILL.md" version=old

printf '%s\n' tampered-after-review >> "$REVIEW/SKILL.md"
if sh "$REPO_ROOT/scripts/catalog-skill.sh" activate --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --skill active-skill >"$TEST_ROOT/tamper-output" 2>"$TEST_ROOT/tamper-error"; then
  fail "Tampered candidate was activated."
fi
assert_file_contains "$TEST_ROOT/tamper-error" "content changed"
write_skill "$CATALOG/review-queue/oceans-skills" active-skill candidate

sh "$REPO_ROOT/scripts/catalog-skill.sh" activate --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --skill active-skill >/dev/null
assert_file_contains "$FIRST/active-skill/SKILL.md" version=candidate
[ ! -e "$REVIEW" ] || fail "Activated candidate remained in review queue."
RECORD=$(oceans_catalog_record_path "$CATALOG" active-skill)
[ "$(oceans_catalog_record_value "$RECORD" upstream_commit)" = "$COMMIT_B" ] || fail "Candidate provenance was not promoted."
[ -z "$(oceans_catalog_record_value "$RECORD" candidate_upstream_commit)" ] || fail "Candidate fields were not cleared."
[ "$(oceans_catalog_record_value "$RECORD" content_sha256)" = "$CANDIDATE_DIGEST" ] || fail "Candidate content fingerprint was not promoted."
[ -z "$(oceans_catalog_record_value "$RECORD" candidate_content_sha256)" ] || fail "Candidate content fingerprint was not cleared."
sh "$REPO_ROOT/scripts/install-skills.sh" --install-root "$INSTALL" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG" >/dev/null
assert_file_contains "$INSTALL/active-skill/SKILL.md" version=candidate

PENDING_PATH=$CATALOG/review-queue/oceans-skills/pending-skill
write_skill "$CATALOG/review-queue/oceans-skills" pending-skill candidate
PENDING_DIGEST=$(oceans_skill_content_sha256 "$PENDING_PATH")
OCEANS_PENDING=$(oceans_catalog_record_path "$CATALOG" pending-skill)
oceans_catalog_write_record "$CATALOG" pending-skill pending-review oceans-skills \
  "" "" "" "" https://github.com/example/upstream skill main "$COMMIT_B" "" "" "new candidate" "" "$PENDING_DIGEST"
sh "$REPO_ROOT/scripts/catalog-skill.sh" reject --catalog-root "$CATALOG" --first-party-root "$FIRST" --community-root "$COMMUNITY" --skill pending-skill >/dev/null
[ ! -e "$OCEANS_PENDING" ] || fail "Rejected new skill record remains."
[ ! -e "$PENDING_PATH" ] || fail "Rejected new skill candidate remains."

RECORD=$(oceans_catalog_record_path "$CATALOG" active-skill)
cp "$RECORD" "$TEST_ROOT/record-backup"
printf '%s\n' unknown_field=value >> "$RECORD"
if sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG" >/dev/null 2>"$TEST_ROOT/schema-error"; then fail "Unknown catalog field passed validation."; fi
assert_file_contains "$TEST_ROOT/schema-error" "Unknown catalog key"
cp "$TEST_ROOT/record-backup" "$RECORD"
sed 's/^upstream_commit=.*/upstream_commit=abc123/' "$RECORD" > "$TEST_ROOT/short-sha-record"
mv "$TEST_ROOT/short-sha-record" "$RECORD"
if sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG" >/dev/null 2>"$TEST_ROOT/short-sha-error"; then fail "Short commit hash passed validation."; fi
assert_file_contains "$TEST_ROOT/short-sha-error" "Invalid upstream commit"
cp "$TEST_ROOT/record-backup" "$RECORD"
mkdir -p "$CATALOG/.locks/active-skill.lock"
if sh "$REPO_ROOT/scripts/catalog-skill.sh" deprecate --catalog-root "$CATALOG" --skill active-skill --reason locked >/dev/null 2>&1; then fail "Concurrent catalog mutation ignored lock."; fi
rm -rf "$CATALOG/.locks/active-skill.lock"

echo "Shell skill catalog test passed."
