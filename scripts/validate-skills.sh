#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
FIRST_PARTY_SKILLS_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_SKILLS_ROOT=$REPO_ROOT/repos/community-skills/skills
failures=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --first-party-root)
      if [ "$#" -lt 2 ]; then
        echo "--first-party-root needs a path." >&2
        exit 2
      fi
      FIRST_PARTY_SKILLS_ROOT=$2
      shift 2
      ;;
    --community-root)
      if [ "$#" -lt 2 ]; then
        echo "--community-root needs a path." >&2
        exit 2
      fi
      COMMUNITY_SKILLS_ROOT=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

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

    if [ -L "$skill_path" ]; then
      add_failure "Unsupported symlink in $repository_name: $skill_name"
    fi

    symlinks=$(find "$skill_path" -type l -print)
    if [ -n "$symlinks" ]; then
      old_ifs=$IFS
      IFS='
'
      for symlink_path in $symlinks; do
        add_failure "Unsupported symlink in $repository_name: $skill_name: ${symlink_path#"$skill_path"/}"
      done
      IFS=$old_ifs
    fi

    if [ "$require_upstream" = "true" ]; then
      for required in UPSTREAM.md PATCHES.md LICENSE; do
        if [ ! -f "$skill_path/$required" ] || [ -z "$(tr -d '[:space:]' < "$skill_path/$required" 2>/dev/null)" ]; then
          add_failure "Missing or empty $required in $repository_name: $skill_name"
        fi
      done
    fi
  done
}

test_duplicate_names() {
  first_party_path=$1
  community_path=$2

  [ -d "$first_party_path" ] || return
  [ -d "$community_path" ] || return

  for skill_path in "$first_party_path"/*; do
    [ -d "$skill_path" ] || continue
    skill_name=${skill_path##*/}
    if [ -d "$community_path/$skill_name" ]; then
      add_failure "Duplicate skill name across repositories: $skill_name"
    fi
  done
}

test_skill_directory "oceans-skills" "$FIRST_PARTY_SKILLS_ROOT" "false"
test_skill_directory "community-skills" "$COMMUNITY_SKILLS_ROOT" "true"
test_duplicate_names "$FIRST_PARTY_SKILLS_ROOT" "$COMMUNITY_SKILLS_ROOT"

if [ "$failures" -gt 0 ]; then
  echo "Validation failed with $failures issue(s)." >&2
  exit 1
fi

echo "Validation passed."
