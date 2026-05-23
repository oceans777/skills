#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SOURCE_ROOT=${CODEX_HOME:+$CODEX_HOME/skills}
FORMAT=text

if [ -z "${SOURCE_ROOT:-}" ]; then
  SOURCE_ROOT=$HOME/.codex/skills
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-root)
      if [ "$#" -lt 2 ]; then
        echo "--source-root needs a path." >&2
        exit 2
      fi
      SOURCE_ROOT=$2
      shift 2
      ;;
    --format)
      if [ "$#" -lt 2 ]; then
        echo "--format needs a value." >&2
        exit 2
      fi
      FORMAT=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$FORMAT" != "text" ]; then
  echo "Unsupported format: $FORMAT" >&2
  exit 2
fi

if [ ! -d "$SOURCE_ROOT" ]; then
  echo "Local skills root does not exist: $SOURCE_ROOT" >&2
  exit 1
fi

SOURCE_ROOT_REAL=$(CDPATH= cd "$SOURCE_ROOT" && pwd -P)
FIRST_PARTY_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_ROOT=$REPO_ROOT/repos/community-skills/skills

managed_source() {
  skill_path=$1
  marker=$skill_path/.oceans-skill-source

  if [ ! -f "$marker" ]; then
    return 1
  fi

  sed -n 's/^source_repository=//p' "$marker" | sed -n '1p'
}

print_risks() {
  skill_path=$1
  printed=0

  if find "$skill_path" -type f ! -path '*/.git/*' -exec grep -E -i -q '(api[_-]?key[[:space:]]*[:=]|secret[[:space:]]*[:=]|token[[:space:]]*[:=]|password[[:space:]]*[:=]|authorization:[[:space:]]*bearer|sk-[a-zA-Z0-9_-]{10,})' {} + 2>/dev/null; then
    echo "  risk: secret-like text"
    printed=1
  fi

  if find "$skill_path" -type f ! -path '*/.git/*' -exec grep -E -i -q '(/Users/|/home/|[A-Z]:\\Users\\|[A-Z]:/Users/|/private/)' {} + 2>/dev/null; then
    echo "  risk: local absolute path"
    printed=1
  fi

  if [ "$printed" -eq 0 ]; then
    echo "  risk: none detected"
  fi
}

print_item() {
  skill_path=$1
  skill_name=${skill_path##*/}

  echo "- $skill_name"

  if [ "$skill_name" = ".system" ]; then
    echo "  status: skip-system"
    echo "  destination: do not publish"
    echo "  reason: Codex system skills are not oceans777 source skills."
    echo "  risk: not scanned"
    return
  fi

  if [ ! -f "$skill_path/SKILL.md" ]; then
    echo "  status: missing-skill-md"
    echo "  destination: manual repair before import"
    echo "  reason: A publishable skill must include SKILL.md."
    print_risks "$skill_path"
    return
  fi

  source_repository=$(managed_source "$skill_path" || true)
  case "$source_repository" in
    oceans-skills)
      echo "  status: already-managed"
      echo "  destination: repos/oceans-skills/skills/$skill_name"
      echo "  reason: Local skill has an oceans777 first-party source marker."
      print_risks "$skill_path"
      ;;
    community-skills)
      echo "  status: already-managed"
      echo "  destination: repos/community-skills/skills/$skill_name"
      echo "  reason: Local skill has an oceans777 community source marker."
      print_risks "$skill_path"
      ;;
    *)
      echo "  status: review-source"
      echo "  destination: oceans-skills if you created it; community-skills if third-party; do not publish if private"
      echo "  reason: No oceans777 source marker found."
      print_risks "$skill_path"
      ;;
  esac
}

echo "oceans777 local skill import report"
echo "Source root: $SOURCE_ROOT_REAL"
echo "First-party target: $FIRST_PARTY_ROOT"
echo "Community target: $COMMUNITY_ROOT"
echo "Mode: report only"
echo "No files were copied."
echo

found=0
for skill_path in "$SOURCE_ROOT_REAL"/* "$SOURCE_ROOT_REAL"/.[!.]* "$SOURCE_ROOT_REAL"/..?*; do
  [ -d "$skill_path" ] || continue
  skill_name=${skill_path##*/}
  [ "$skill_name" != "." ] || continue
  [ "$skill_name" != ".." ] || continue
  found=1
  print_item "$skill_path"
done

if [ "$found" -eq 0 ]; then
  echo "No local skill directories found."
fi
