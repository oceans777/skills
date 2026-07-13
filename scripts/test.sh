#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)

for test_script in "$SCRIPT_DIR"/test-*.sh; do
  [ -f "$test_script" ] || continue
  printf '[TEST] %s\n' "$(basename "$test_script")"
  sh "$test_script"
done

printf 'All shell tests passed.\n'
