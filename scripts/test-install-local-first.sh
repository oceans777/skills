#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-install-test.XXXXXX")
FIRST_PARTY_ROOT=$TEST_ROOT/first-party/skills
COMMUNITY_ROOT=$TEST_ROOT/community/skills
SKILL_NAMES="local-first-test managed-update-test unknown-marker-test source-mismatch-test"

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

assert_file_contains() {
  path=$1
  expected=$2

  if ! grep -F -q "$expected" "$path"; then
    echo "Expected $path to contain: $expected" >&2
    exit 1
  fi
}

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$FIRST_PARTY_ROOT" "$COMMUNITY_ROOT"

for skill_name in $SKILL_NAMES; do
  mkdir -p "$FIRST_PARTY_ROOT/$skill_name"
  {
    echo "---"
    echo "name: $skill_name"
    echo "description: Repository version."
    echo "---"
    echo "repo-version"
  } > "$FIRST_PARTY_ROOT/$skill_name/SKILL.md"
done

INSTALL_ROOT=$TEST_ROOT/skills

mkdir -p "$INSTALL_ROOT/local-first-test"
printf '%s\n' "local-version" > "$INSTALL_ROOT/local-first-test/SKILL.md"

mkdir -p "$INSTALL_ROOT/managed-update-test"
printf '%s\n' "old-managed-version" > "$INSTALL_ROOT/managed-update-test/SKILL.md"
printf '%s\n' "source_repository=oceans-skills" > "$INSTALL_ROOT/managed-update-test/.oceans-skill-source"

mkdir -p "$INSTALL_ROOT/unknown-marker-test"
printf '%s\n' "unknown-marker-version" > "$INSTALL_ROOT/unknown-marker-test/SKILL.md"
printf '%s\n' "source_repository=other-repo" > "$INSTALL_ROOT/unknown-marker-test/.oceans-skill-source"

mkdir -p "$INSTALL_ROOT/source-mismatch-test"
printf '%s\n' "community-managed-version" > "$INSTALL_ROOT/source-mismatch-test/SKILL.md"
printf '%s\n' "source_repository=community-skills" > "$INSTALL_ROOT/source-mismatch-test/.oceans-skill-source"

OUTPUT=$(sh "$REPO_ROOT/scripts/install-skills.sh" \
  --install-root "$INSTALL_ROOT" \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT")

assert_contains "$OUTPUT" "duplicate-local-wins: local-first-test"
assert_contains "$OUTPUT" "Updated managed oceans777 skill: managed-update-test"
assert_contains "$OUTPUT" "duplicate-unknown-marker: unknown-marker-test"
assert_contains "$OUTPUT" "duplicate-managed-source-mismatch: source-mismatch-test"

assert_file_contains "$INSTALL_ROOT/local-first-test/SKILL.md" "local-version"
assert_file_contains "$INSTALL_ROOT/managed-update-test/SKILL.md" "repo-version"
assert_file_contains "$INSTALL_ROOT/unknown-marker-test/SKILL.md" "unknown-marker-version"
assert_file_contains "$INSTALL_ROOT/source-mismatch-test/SKILL.md" "community-managed-version"

echo "Shell install local-first test passed."
