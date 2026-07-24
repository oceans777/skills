#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-content-hash-test.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM

. "$REPO_ROOT/scripts/skill-content-hash.sh"

LF_ROOT=$TEST_ROOT/lf
CRLF_ROOT=$TEST_ROOT/crlf
mkdir -p "$LF_ROOT/nested" "$CRLF_ROOT/nested"

printf 'first\nsecond' > "$LF_ROOT/SKILL.md"
printf 'first\r\nsecond' > "$CRLF_ROOT/SKILL.md"
printf 'alpha\nbeta\ngamma\n' > "$LF_ROOT/nested/reference.md"
printf 'alpha\rbeta\r\ngamma\r\n' > "$CRLF_ROOT/nested/reference.md"

LF_HASH=$(oceans_skill_content_sha256 "$LF_ROOT")
CRLF_HASH=$(oceans_skill_content_sha256 "$CRLF_ROOT")
[ "$LF_HASH" = "$CRLF_HASH" ] || {
  echo "Canonical hashes differ: LF=$LF_HASH CRLF=$CRLF_HASH" >&2
  exit 1
}

printf 'first\nchanged' > "$CRLF_ROOT/SKILL.md"
CHANGED_HASH=$(oceans_skill_content_sha256 "$CRLF_ROOT")
[ "$LF_HASH" != "$CHANGED_HASH" ] || {
  echo "Content mutation did not change the canonical hash." >&2
  exit 1
}

printf 'Canonical content hash test passed: %s\n' "$LF_HASH"
