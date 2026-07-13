#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/directory-transaction.sh"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-directory-transaction-test.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

TARGET=$TEST_ROOT/managed-skill
mkdir -p "$TARGET"
printf '%s\n' old > "$TARGET/version"

STAGED=$(oceans_new_staging_directory "$TARGET")
printf '%s\n' new > "$STAGED/version"
oceans_commit_staged_directory "$STAGED" "$TARGET"
test "$(cat "$TARGET/version")" = new

OUTSIDE=$TEST_ROOT/outside
mkdir -p "$OUTSIDE"
printf '%s\n' private > "$OUTSIDE/version"
ln -s "$OUTSIDE" "$TEST_ROOT/symlink-target"
STAGED=$(oceans_new_staging_directory "$TEST_ROOT/symlink-target")
printf '%s\n' replacement > "$STAGED/version"
if oceans_commit_staged_directory "$STAGED" "$TEST_ROOT/symlink-target" 2>/dev/null; then
  echo 'Expected symlink target replacement to fail.' >&2
  exit 1
fi
test "$(cat "$OUTSIDE/version")" = private
rm -rf "$STAGED"

RECOVERY_TARGET=$TEST_ROOT/recovery-skill
RECOVERY_BACKUP=$TEST_ROOT/.recovery-skill.oceans-backup
RECOVERY_LOCK=$TEST_ROOT/.recovery-skill.oceans-lock
mkdir -p "$RECOVERY_BACKUP" "$RECOVERY_LOCK"
printf '%s\n' recoverable > "$RECOVERY_BACKUP/version"
printf '%s\n' 999999 > "$RECOVERY_LOCK/pid"
STAGED=$(oceans_new_staging_directory "$RECOVERY_TARGET")
printf '%s\n' recovered-update > "$STAGED/version"
oceans_commit_staged_directory "$STAGED" "$RECOVERY_TARGET"
test "$(cat "$RECOVERY_TARGET/version")" = recovered-update
test ! -e "$RECOVERY_BACKUP"
test ! -e "$RECOVERY_LOCK"

LOCKED_TARGET=$TEST_ROOT/locked-skill
mkdir -p "$LOCKED_TARGET" "$TEST_ROOT/.locked-skill.oceans-lock"
printf '%s\n' locked-old > "$LOCKED_TARGET/version"
printf '%s\n' "$$" > "$TEST_ROOT/.locked-skill.oceans-lock/pid"
STAGED=$(oceans_new_staging_directory "$LOCKED_TARGET")
printf '%s\n' locked-new > "$STAGED/version"
if oceans_commit_staged_directory "$STAGED" "$LOCKED_TARGET" 2>/dev/null; then
  echo 'Expected active transaction lock to block replacement.' >&2
  exit 1
fi
test "$(cat "$LOCKED_TARGET/version")" = locked-old
rm -rf "$STAGED" "$TEST_ROOT/.locked-skill.oceans-lock"

FILTER_ROOT=$TEST_ROOT/filter-root
mkdir -p "$FILTER_ROOT/node_modules/pkg" "$FILTER_ROOT/kept"
printf '%s\n' remove > "$FILTER_ROOT/node_modules/pkg/file"
printf '%s\n' keep > "$FILTER_ROOT/kept/file"
oceans_remove_excluded_paths "$FILTER_ROOT"
test ! -e "$FILTER_ROOT/node_modules"
test -f "$FILTER_ROOT/kept/file"

printf 'Shell directory transaction tests passed.\n'
