#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-url-intake-test.XXXXXX")
UPSTREAM=$TEST_ROOT/upstream
OTHER_UPSTREAM=$TEST_ROOT/other-upstream
FIRST_REPO=$TEST_ROOT/oceans
COMMUNITY_REPO=$TEST_ROOT/community
CATALOG=$TEST_ROOT/catalog
INSTALL=$TEST_ROOT/runtime/skills
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM

fail() { echo "$*" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "Expected output to contain: $2" ;; esac; }
assert_file_contains() { grep -F -q "$2" "$1" || fail "Expected $1 to contain: $2"; }
init_repo() {
  path=$1
  mkdir -p "$path"
  git init -q "$path"
  git -C "$path" checkout -q -B main
  git -C "$path" config user.email test@example.invalid
  git -C "$path" config user.name Test
  git -C "$path" config core.autocrlf false
}
write_upstream_skill() {
  repo=$1; version=$2
  mkdir -p "$repo/skills/sample-import"
  cat > "$repo/skills/sample-import/SKILL.md" <<EOF_SKILL
---
name: sample-import
description: Imported fixture skill.
---
version=$version
EOF_SKILL
  printf '%s\n' helper > "$repo/skills/sample-import/helper.txt"
  printf '%s\n' 'MIT fixture license' > "$repo/LICENSE"
}

init_repo "$UPSTREAM"
write_upstream_skill "$UPSTREAM" one
git -C "$UPSTREAM" add .
git -C "$UPSTREAM" commit -q -m initial
git -C "$UPSTREAM" checkout -q -b feature/skill
printf '%s\n' branch-marker >> "$UPSTREAM/skills/sample-import/helper.txt"
git -C "$UPSTREAM" add .
git -C "$UPSTREAM" commit -q -m branch

init_repo "$OTHER_UPSTREAM"
write_upstream_skill "$OTHER_UPSTREAM" foreign
git -C "$OTHER_UPSTREAM" add .
git -C "$OTHER_UPSTREAM" commit -q -m initial

init_repo "$FIRST_REPO"
mkdir -p "$FIRST_REPO/skills"; : > "$FIRST_REPO/skills/.gitkeep"; git -C "$FIRST_REPO" add .; git -C "$FIRST_REPO" commit -q -m initial
init_repo "$COMMUNITY_REPO"
mkdir -p "$COMMUNITY_REPO/skills"; : > "$COMMUNITY_REPO/skills/.gitkeep"; git -C "$COMMUNITY_REPO" add .; git -C "$COMMUNITY_REPO" commit -q -m initial
mkdir -p "$CATALOG/skills" "$CATALOG/review-queue/oceans-skills" "$CATALOG/review-queue/community-skills" "$INSTALL"

OUTPUT=$(sh "$REPO_ROOT/scripts/add-skill-from-url.sh" \
  --url https://github.com/example/upstream/tree/feature/skill/skills/sample-import \
  --local-repository "$UPSTREAM" --target community --catalog-root "$CATALOG")
assert_contains "$OUTPUT" "catalog-state: pending-review"
assert_contains "$OUTPUT" "candidate-added: sample-import"
[ ! -e "$COMMUNITY_REPO/skills/sample-import" ] || fail "Intake wrote directly into the active child repository."
REVIEW=$CATALOG/review-queue/community-skills/sample-import
for required in SKILL.md UPSTREAM.md PATCHES.md LICENSE; do [ -s "$REVIEW/$required" ] || fail "Missing candidate file: $required"; done
assert_file_contains "$REVIEW/SKILL.md" version=one
RECORD=$CATALOG/skills/sample-import.skill
[ -f "$RECORD" ] || fail "Pending catalog record is missing."
assert_file_contains "$RECORD" candidate_upstream_ref=feature/skill

sh "$REPO_ROOT/scripts/validate-skills.sh" --first-party-root "$FIRST_REPO/skills" --community-root "$COMMUNITY_REPO/skills" --catalog-root "$CATALOG" >/dev/null
INSTALL_OUTPUT=$(sh "$REPO_ROOT/scripts/install-skills.sh" --install-root "$INSTALL" --first-party-root "$FIRST_REPO/skills" --community-root "$COMMUNITY_REPO/skills" --catalog-root "$CATALOG")
[ ! -e "$INSTALL/sample-import" ] || fail "Pending new candidate was installed."
assert_contains "$INSTALL_OUTPUT" "Skipped pending-review skill: sample-import"

sh "$REPO_ROOT/scripts/catalog-skill.sh" activate --catalog-root "$CATALOG" --first-party-root "$FIRST_REPO/skills" --community-root "$COMMUNITY_REPO/skills" --skill sample-import >/dev/null
[ -f "$COMMUNITY_REPO/skills/sample-import/SKILL.md" ] || fail "Approved candidate was not promoted."
sh "$REPO_ROOT/scripts/install-skills.sh" --install-root "$INSTALL" --first-party-root "$FIRST_REPO/skills" --community-root "$COMMUNITY_REPO/skills" --catalog-root "$CATALOG" >/dev/null
assert_file_contains "$INSTALL/sample-import/SKILL.md" version=one

# Queue an update without interrupting the active package.
printf '%s\n' 'version=two' >> "$UPSTREAM/skills/sample-import/SKILL.md"
git -C "$UPSTREAM" add .; git -C "$UPSTREAM" commit -q -m update
OUTPUT=$(sh "$REPO_ROOT/scripts/add-skill-from-url.sh" \
  --url https://github.com/example/upstream/tree/feature/skill/skills/sample-import \
  --local-repository "$UPSTREAM" --target community --catalog-root "$CATALOG" --replace-existing)
assert_contains "$OUTPUT" "catalog-state: active"
assert_contains "$OUTPUT" "active-package-preserved: sample-import"
assert_file_contains "$COMMUNITY_REPO/skills/sample-import/SKILL.md" version=one
sh "$REPO_ROOT/scripts/install-skills.sh" --install-root "$INSTALL" --first-party-root "$FIRST_REPO/skills" --community-root "$COMMUNITY_REPO/skills" --catalog-root "$CATALOG" >/dev/null
assert_file_contains "$INSTALL/sample-import/SKILL.md" version=one
sh "$REPO_ROOT/scripts/catalog-skill.sh" reject --catalog-root "$CATALOG" --skill sample-import >/dev/null
assert_file_contains "$COMMUNITY_REPO/skills/sample-import/SKILL.md" version=one
[ ! -e "$REVIEW" ] || fail "Rejected update candidate remains."

# Provenance changes, path escape, direct activation, and resource overflow fail closed.
if sh "$REPO_ROOT/scripts/add-skill-from-url.sh" --url https://github.com/other/upstream/tree/main/skills/sample-import --local-repository "$OTHER_UPSTREAM" --target community --catalog-root "$CATALOG" --replace-existing >/dev/null 2>&1; then fail "Source repository change was accepted without explicit approval."; fi
if sh "$REPO_ROOT/scripts/add-skill-from-url.sh" --url https://github.com/example/upstream --local-repository "$UPSTREAM" --skill-path ../escape --target community --catalog-root "$CATALOG" >/dev/null 2>&1; then fail "Path traversal was accepted."; fi
if sh "$REPO_ROOT/scripts/add-skill-from-url.sh" --url https://github.com/example/upstream --local-repository "$UPSTREAM" --target community --catalog-root "$CATALOG" --activate >/dev/null 2>&1; then fail "Direct activation during intake was accepted."; fi
if OCEANS_INTAKE_MAX_FILES=1 sh "$REPO_ROOT/scripts/add-skill-from-url.sh" --url https://github.com/example/upstream/tree/feature/skill/skills/sample-import --local-repository "$UPSTREAM" --target community --catalog-root "$CATALOG" --replace-existing >/dev/null 2>&1; then fail "File budget overflow was accepted."; fi

echo "Shell URL intake test passed."
