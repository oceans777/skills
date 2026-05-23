#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)

SOURCE_ROOT=${CODEX_HOME:+$CODEX_HOME/skills}
FIRST_PARTY_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_ROOT=$REPO_ROOT/repos/community-skills/skills
SKILL=
TARGET=
ALLOW_RISK=0
REPLACE_EXISTING=0
DRY_RUN=0
UPSTREAM_URL=
UPSTREAM_AUTHOR=
UPSTREAM_LICENSE=
LICENSE_FILE=
PATCH_SUMMARY=

if [ -z "${SOURCE_ROOT:-}" ]; then
  SOURCE_ROOT=$HOME/.codex/skills
fi

need_value() {
  option=$1
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    echo "$option needs a value." >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-root)
      need_value "$1" "${2:-}"
      SOURCE_ROOT=$2
      shift 2
      ;;
    --skill)
      need_value "$1" "${2:-}"
      SKILL=$2
      shift 2
      ;;
    --target)
      need_value "$1" "${2:-}"
      TARGET=$2
      shift 2
      ;;
    --first-party-skills-root|--first-party-root)
      need_value "$1" "${2:-}"
      FIRST_PARTY_ROOT=$2
      shift 2
      ;;
    --community-skills-root|--community-root)
      need_value "$1" "${2:-}"
      COMMUNITY_ROOT=$2
      shift 2
      ;;
    --allow-risk)
      ALLOW_RISK=1
      shift
      ;;
    --replace-existing)
      REPLACE_EXISTING=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --upstream-url)
      need_value "$1" "${2:-}"
      UPSTREAM_URL=$2
      shift 2
      ;;
    --upstream-author)
      need_value "$1" "${2:-}"
      UPSTREAM_AUTHOR=$2
      shift 2
      ;;
    --upstream-license)
      need_value "$1" "${2:-}"
      UPSTREAM_LICENSE=$2
      shift 2
      ;;
    --license-file)
      need_value "$1" "${2:-}"
      LICENSE_FILE=$2
      shift 2
      ;;
    --patch-summary)
      need_value "$1" "${2:-}"
      PATCH_SUMMARY=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$SKILL" ]; then
  echo "--skill is required." >&2
  exit 2
fi

case "$TARGET" in
  oceans|community)
    ;;
  "")
    echo "--target is required." >&2
    exit 2
    ;;
  *)
    echo "Unsupported target: $TARGET" >&2
    exit 2
    ;;
esac

if [ "$SKILL" = ".system" ]; then
  echo "skip-system: .system"
  exit 1
fi

case "$SKILL" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|""|-*|*-|*--*)
    echo "invalid-skill-name: $SKILL"
    exit 1
    ;;
esac

case "$TARGET" in
  oceans)
    TARGET_ROOT=$FIRST_PARTY_ROOT
    OTHER_ROOT=$COMMUNITY_ROOT
    TARGET_REPOSITORY=oceans-skills
    ;;
  community)
    TARGET_ROOT=$COMMUNITY_ROOT
    OTHER_ROOT=$FIRST_PARTY_ROOT
    TARGET_REPOSITORY=community-skills
    ;;
esac

TARGET_REPO=$(CDPATH= cd "$TARGET_ROOT/.." && pwd -P)

git_text() {
  repo=$1
  shift
  git -C "$repo" "$@" 2>/dev/null || true
}

branch=$(git_text "$TARGET_REPO" rev-parse --abbrev-ref HEAD)
if [ "$branch" != "main" ]; then
  echo "target-not-main: $TARGET_REPOSITORY"
  exit 1
fi

status=$(git -C "$TARGET_REPO" status --porcelain)
if [ -n "$status" ]; then
  old_ifs=$IFS
  IFS='
'
  for line in $status; do
    path=${line#???}
    case "$path" in
      *" -> "*)
        paths_to_check=$(printf '%s\n' "$path" | sed 's/ -> /\
/g')
        ;;
      *)
        paths_to_check=$path
        ;;
    esac
    for path_to_check in $paths_to_check; do
      path_to_check=$(printf '%s' "$path_to_check" | sed 's/^"//; s/"$//')
      case "$path_to_check" in
        skills/*)
          ;;
        *)
          IFS=$old_ifs
          echo "target-dirty-outside-skills: $TARGET_REPOSITORY"
          exit 1
          ;;
      esac
    done
  done
  IFS=$old_ifs
fi

SOURCE_SKILL=$SOURCE_ROOT/$SKILL
if [ ! -d "$SOURCE_SKILL" ]; then
  echo "missing-source-skill: $SOURCE_SKILL"
  exit 1
fi

SOURCE_SKILL=$(CDPATH= cd "$SOURCE_SKILL" && pwd -P)
if [ ! -f "$SOURCE_SKILL/SKILL.md" ]; then
  echo "missing-skill-md: $SKILL"
  exit 1
fi

is_excluded_path() {
  rel=$1
  old_ifs=$IFS
  IFS='/'
  for part in $rel; do
    case "$part" in
      .git|.oceans-skill-source|.DS_Store|Thumbs.db|.pytest_cache|__pycache__|node_modules)
        IFS=$old_ifs
        return 0
        ;;
    esac
  done
  IFS=$old_ifs
  return 1
}

RISK_NOTES_FILE=${TMPDIR:-/tmp}/stage-skill-risks.$$
: > "$RISK_NOTES_FILE"

add_risk() {
  risk=$1
  if ! grep -F -x -q "$risk" "$RISK_NOTES_FILE" 2>/dev/null; then
    printf '%s\n' "$risk" >> "$RISK_NOTES_FILE"
  fi
}

find "$SOURCE_SKILL" -type f | while IFS= read -r file; do
  rel=${file#"$SOURCE_SKILL"/}
  if is_excluded_path "$rel"; then
    continue
  fi

  size=$(wc -c < "$file" | tr -d ' ')
  if [ "$size" -gt 1048576 ]; then
    add_risk "risk: file larger than 1 MB"
    continue
  fi

  if ! LC_ALL=C grep -Iq . "$file" 2>/dev/null && [ "$size" -gt 0 ]; then
    add_risk "risk: binary or unreadable file"
    continue
  fi

  if command -v perl >/dev/null 2>&1 &&
     ! perl -MEncode=decode -0777 -ne 'eval { decode("UTF-8", $_, 1); 1 } or exit 1' "$file" 2>/dev/null; then
    add_risk "risk: binary or unreadable file"
    continue
  fi

  if command -v iconv >/dev/null 2>&1 &&
     ! iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1; then
    add_risk "risk: binary or unreadable file"
    continue
  fi

  if grep -E -i -q '(api[_-]?key[[:space:]]*[:=]|secret[[:space:]]*[:=]|token[[:space:]]*[:=]|password[[:space:]]*[:=]|authorization[[:space:]]*:?[[:space:]]*bearer|sk-[a-zA-Z0-9_-]{10,})' "$file" 2>/dev/null; then
    add_risk "risk: secret-like text"
  fi

  if grep -E -i -q '(/Users/|/home/|[A-Z]:\\Users\\|[A-Z]:/Users/|/private/)' "$file" 2>/dev/null; then
    add_risk "risk: local absolute path"
  fi
done
RISKS=$(cat "$RISK_NOTES_FILE")
rm -f "$RISK_NOTES_FILE"

if [ -n "$RISKS" ] && [ "$ALLOW_RISK" -ne 1 ]; then
  echo "risk-blocked: $SKILL"
  printf '%s' "$RISKS"
  echo "risk_status: blocked"
  exit 1
fi

non_empty_file() {
  path=$1
  [ -f "$path" ] || return 1
  [ -n "$(tr -d '[:space:]' < "$path")" ]
}

if [ "$TARGET" = "community" ]; then
  if ! non_empty_file "$SOURCE_SKILL/UPSTREAM.md" &&
     { [ -z "$UPSTREAM_URL" ] ||
       [ -z "$UPSTREAM_AUTHOR" ] ||
       [ -z "$UPSTREAM_LICENSE" ]; }; then
    echo "missing-community-attribution: $SKILL"
    exit 1
  fi

  if ! non_empty_file "$SOURCE_SKILL/LICENSE" &&
     { [ -z "$LICENSE_FILE" ] || [ ! -f "$LICENSE_FILE" ]; }; then
    echo "missing-community-attribution: $SKILL"
    exit 1
  fi
fi

TARGET_PATH=$TARGET_ROOT/$SKILL
OTHER_PATH=$OTHER_ROOT/$SKILL
if [ -d "$OTHER_PATH" ]; then
  echo "duplicate-cross-repository: $SKILL"
  exit 1
fi

if [ -d "$TARGET_PATH" ] && [ "$REPLACE_EXISTING" -ne 1 ]; then
  echo "duplicate-existing-target: $SKILL"
  exit 1
fi

absolute_path() {
  path=$1
  if [ -e "$path" ]; then
    if [ -d "$path" ]; then
      (CDPATH= cd "$path" && pwd -P)
    else
      dir=$(dirname "$path")
      base=$(basename "$path")
      printf '%s/%s\n' "$(CDPATH= cd "$dir" && pwd -P)" "$base"
    fi
  else
    dir=$(dirname "$path")
    base=$(basename "$path")
    printf '%s/%s\n' "$(CDPATH= cd "$dir" && pwd -P)" "$base"
  fi
}

assert_path_inside_root() {
  path=$(absolute_path "$1")
  root=$(absolute_path "$2")
  case "$path" in
    "$root"/*)
      ;;
    *)
      echo "Unsafe target path outside skills root: $path" >&2
      exit 1
      ;;
  esac
}

assert_path_inside_root "$TARGET_PATH" "$TARGET_ROOT"

if [ -z "$RISKS" ]; then
  RISK_STATUS="none detected"
else
  RISK_STATUS=allowed
fi

print_success() {
  dry_run_value=$1
  echo "staged-skill: $SKILL"
  echo "target_repository: $TARGET_REPOSITORY"
  echo "target_path: $TARGET_PATH"
  echo "risk_status: $RISK_STATUS"
  echo "dry_run: $dry_run_value"
  echo "next: run validate, then publish"
}

if [ "$DRY_RUN" -eq 1 ]; then
  print_success true
  exit 0
fi

if [ -d "$TARGET_PATH" ]; then
  assert_path_inside_root "$TARGET_PATH" "$TARGET_ROOT"
  rm -rf "$TARGET_PATH"
fi

mkdir -p "$TARGET_PATH"
(CDPATH= cd "$SOURCE_SKILL" && find . -mindepth 1 -print) | while IFS= read -r item; do
  rel=${item#./}
  if is_excluded_path "$rel"; then
    continue
  fi

  if [ -d "$SOURCE_SKILL/$rel" ]; then
    mkdir -p "$TARGET_PATH/$rel"
  elif [ -f "$SOURCE_SKILL/$rel" ]; then
    mkdir -p "$TARGET_PATH/$(dirname "$rel")"
    cp "$SOURCE_SKILL/$rel" "$TARGET_PATH/$rel"
  fi
done

if [ "$TARGET" = "community" ]; then
  if ! non_empty_file "$TARGET_PATH/UPSTREAM.md"; then
    {
      echo "# Upstream"
      echo
      echo "Original repository: $UPSTREAM_URL"
      echo "Original author: $UPSTREAM_AUTHOR"
      echo "License: $UPSTREAM_LICENSE"
      echo "Imported by: oceans777"
    } > "$TARGET_PATH/UPSTREAM.md"
  fi

  if ! non_empty_file "$TARGET_PATH/PATCHES.md"; then
    {
      echo "# Patches"
      echo
      if [ -n "$PATCH_SUMMARY" ]; then
        echo "$PATCH_SUMMARY"
      else
        echo "No local changes."
      fi
    } > "$TARGET_PATH/PATCHES.md"
  fi

  if ! non_empty_file "$TARGET_PATH/LICENSE"; then
    cp "$LICENSE_FILE" "$TARGET_PATH/LICENSE"
  fi
fi

print_success false
