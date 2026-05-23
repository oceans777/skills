#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
failures=0

add_failure() {
  echo "ERROR: $*" >&2
  failures=$((failures + 1))
}

test_skill_directory() {
  repository_name=$1
  skills_path=$2
  require_upstream=$3

  if [ ! -d "$skills_path" ]; then
    add_failure "Missing skills path: $skills_path"
    return
  fi

  for skill_path in "$skills_path"/*; do
    [ -d "$skill_path" ] || continue
    skill_name=${skill_path##*/}

    case "$skill_name" in
      ''|*[!a-z0-9-]*)
        add_failure "Invalid skill folder name in $repository_name: $skill_name"
        ;;
    esac

    if [ ! -f "$skill_path/SKILL.md" ]; then
      add_failure "Missing SKILL.md in $repository_name: $skill_name"
    fi

    if [ "$require_upstream" = "true" ]; then
      for required in UPSTREAM.md PATCHES.md LICENSE; do
        if [ ! -f "$skill_path/$required" ]; then
          add_failure "Missing $required in $repository_name: $skill_name"
        fi
      done
    fi
  done
}

test_skill_directory "oceans-skills" "$REPO_ROOT/repos/oceans-skills/skills" "false"
test_skill_directory "community-skills" "$REPO_ROOT/repos/community-skills/skills" "true"

if [ "$failures" -gt 0 ]; then
  echo "Validation failed with $failures issue(s)." >&2
  exit 1
fi

echo "Validation passed."
