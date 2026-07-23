#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-url-intake-test.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM

UPSTREAM=$TEST_ROOT/upstream
FIRST_REPO=$TEST_ROOT/oceans
COMMUNITY_REPO=$TEST_ROOT/community
CATALOG=$TEST_ROOT/catalog
INSTALL=$TEST_ROOT/install

init_repo() {
  path=$1
  mkdir -p "$path"
  git init -q "$path"
  git -C "$path" checkout -q -B main
  git -C "$path" config user.email test@example.invalid
  git -C "$path" config user.name Test
}
init_repo "$UPSTREAM"
mkdir -p "$UPSTREAM/skills/sample-import"
cat > "$UPSTREAM/skills/sample-import/SKILL.md" <<'EOF_SKILL'
---
name: sample-import
description: Imported fixture skill.
---
EOF_SKILL
printf '%s\n' 'MIT fixture license' > "$UPSTREAM/LICENSE"
git -C "$UPSTREAM" add .
git -C "$UPSTREAM" commit -q -m initial

init_repo "$FIRST_REPO"
mkdir -p "$FIRST_REPO/skills"
: > "$FIRST_REPO/skills/.gitkeep"
git -C "$FIRST_REPO" add .
git -C "$FIRST_REPO" commit -q -m initial

init_repo "$COMMUNITY_REPO"
mkdir -p "$COMMUNITY_REPO/skills"
: > "$COMMUNITY_REPO/skills/.gitkeep"
git -C "$COMMUNITY_REPO" add .
git -C "$COMMUNITY_REPO" commit -q -m initial

mkdir -p "$CATALOG/active" "$CATALOG/pending-review" "$CATALOG/deprecated" "$CATALOG/archived" "$CATALOG/blocked"

OUTPUT=$(sh "$REPO_ROOT/scripts/add-skill-from-url.sh" \
  --url https://github.com/example/upstream/tree/main/skills/sample-import \
  --local-repository "$UPSTREAM" \
  --target community \
  --first-party-root "$FIRST_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills" \
  --catalog-root "$CATALOG")
case "$OUTPUT" in *"catalog-state: pending-review"*) ;; *) echo "Intake did not create pending review state." >&2; exit 1 ;; esac
for required in SKILL.md UPSTREAM.md PATCHES.md LICENSE; do
  [ -s "$COMMUNITY_REPO/skills/sample-import/$required" ] || { echo "Missing staged file: $required" >&2; exit 1; }
done
[ -f "$CATALOG/pending-review/sample-import.skill" ] || { echo "Missing pending catalog record." >&2; exit 1; }

sh "$REPO_ROOT/scripts/validate-skills.sh" \
  --first-party-root "$FIRST_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills" \
  --catalog-root "$CATALOG" >/dev/null

INSTALL_OUTPUT=$(sh "$REPO_ROOT/scripts/install-skills.sh" \
  --install-root "$INSTALL" \
  --first-party-root "$FIRST_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills" \
  --catalog-root "$CATALOG")
[ ! -e "$INSTALL/sample-import" ] || { echo "Pending imported skill must not install." >&2; exit 1; }
case "$INSTALL_OUTPUT" in *"Skipped pending-review skill: sample-import"*) ;; *) echo "Pending intake skip was not reported." >&2; exit 1 ;; esac

sh "$REPO_ROOT/scripts/catalog-skill.sh" activate --catalog-root "$CATALOG" --skill sample-import >/dev/null
sh "$REPO_ROOT/scripts/install-skills.sh" \
  --install-root "$INSTALL" \
  --first-party-root "$FIRST_REPO/skills" \
  --community-root "$COMMUNITY_REPO/skills" \
  --catalog-root "$CATALOG" >/dev/null
[ -f "$INSTALL/sample-import/SKILL.md" ] || { echo "Activated imported skill was not installed." >&2; exit 1; }

printf 'Shell URL intake test passed.\n'
