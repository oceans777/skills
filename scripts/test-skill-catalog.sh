#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-catalog-test.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM

FIRST=$TEST_ROOT/oceans/skills
COMMUNITY=$TEST_ROOT/community/skills
CATALOG=$TEST_ROOT/catalog
INSTALL=$TEST_ROOT/install
mkdir -p "$FIRST/active-skill" "$FIRST/archived-skill" "$COMMUNITY/pending-skill"
mkdir -p "$CATALOG/active" "$CATALOG/pending-review" "$CATALOG/deprecated" "$CATALOG/archived" "$CATALOG/blocked"

write_skill() {
  path=$1
  name=$2
  cat > "$path/SKILL.md" <<EOF_SKILL
---
name: $name
description: Catalog test skill.
---
EOF_SKILL
}
write_skill "$FIRST/active-skill" active-skill
write_skill "$FIRST/archived-skill" archived-skill
write_skill "$COMMUNITY/pending-skill" pending-skill
printf '%s\n' upstream > "$COMMUNITY/pending-skill/UPSTREAM.md"
printf '%s\n' patches > "$COMMUNITY/pending-skill/PATCHES.md"
printf '%s\n' license > "$COMMUNITY/pending-skill/LICENSE"

. "$REPO_ROOT/scripts/skill-catalog.sh"
COMMIT=0123456789012345678901234567890123456789
oceans_catalog_write_record "$CATALOG" active active-skill oceans-skills https://github.com/example/oceans skills/active-skill main "$COMMIT" '' ''
oceans_catalog_write_record "$CATALOG" archived archived-skill oceans-skills https://github.com/example/oceans skills/archived-skill main "$COMMIT" '' 'retired'
oceans_catalog_write_record "$CATALOG" pending-review pending-skill community-skills https://github.com/example/community skills/pending-skill main "$COMMIT" '' ''

sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG" >/dev/null
OUTPUT=$(sh "$REPO_ROOT/scripts/install-skills.sh" --install-root "$INSTALL" --first-party-root "$FIRST" --community-root "$COMMUNITY" --catalog-root "$CATALOG")
[ -f "$INSTALL/active-skill/SKILL.md" ] || { echo "Active skill was not installed." >&2; exit 1; }
[ ! -e "$INSTALL/archived-skill" ] || { echo "Archived skill must not be installed." >&2; exit 1; }
[ ! -e "$INSTALL/pending-skill" ] || { echo "Pending skill must not be installed." >&2; exit 1; }
case "$OUTPUT" in *"Skipped archived skill: archived-skill"*) ;; *) echo "Archive skip was not reported." >&2; exit 1 ;; esac
case "$OUTPUT" in *"Skipped pending-review skill: pending-skill"*) ;; *) echo "Pending skip was not reported." >&2; exit 1 ;; esac

sh "$REPO_ROOT/scripts/catalog-skill.sh" restore --catalog-root "$CATALOG" --skill archived-skill >/dev/null
[ -f "$CATALOG/active/archived-skill.skill" ] || { echo "Restore did not activate the skill." >&2; exit 1; }
sh "$REPO_ROOT/scripts/catalog-skill.sh" archive --catalog-root "$CATALOG" --skill archived-skill --reason 'retired again' >/dev/null
[ -f "$CATALOG/archived/archived-skill.skill" ] || { echo "Archive did not move the record." >&2; exit 1; }

printf 'Shell skill catalog test passed.\n'
