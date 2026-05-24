#!/bin/sh
set -eu

MODE=list
RUNTIME=codex
SOURCE_ROOT=
INSTALL_ROOT=

oceans_home() {
  printf '%s\n' "$HOME"
}

runtime_candidates() {
  runtime=$1
  home=$(oceans_home)

  case "$runtime" in
    codex)
      if [ -n "${CODEX_HOME:-}" ]; then printf '%s\n' "$CODEX_HOME/skills"; else printf '%s\n' "$home/.codex/skills"; fi
      ;;
    agents)
      if [ -n "${AGENTS_HOME:-}" ]; then printf '%s\n' "$AGENTS_HOME/skills"; else printf '%s\n' "$home/.agents/skills"; fi
      ;;
    claude)
      if [ -n "${CLAUDE_HOME:-}" ]; then printf '%s\n' "$CLAUDE_HOME/skills"; else printf '%s\n' "$home/.claude/skills"; fi
      ;;
    openclaw)
      if [ -n "${OPENCLAW_HOME:-}" ]; then
        printf '%s\n' "$OPENCLAW_HOME/skills"
      else
        printf '%s\n' "$home/.openclaw/skills"
        printf '%s\n' "$home/.config/openclaw/skills"
      fi
      ;;
    hermes)
      if [ -n "${HERMES_HOME:-}" ]; then
        printf '%s\n' "$HERMES_HOME/skills"
      else
        printf '%s\n' "$home/.hermes/skills"
        printf '%s\n' "$home/.config/hermes/skills"
      fi
      ;;
    *)
      echo "unsupported-runtime: $runtime" >&2
      return 2
      ;;
  esac
}

absolute_path() {
  path=$1
  if [ -d "$path" ]; then
    (CDPATH= cd "$path" && pwd -P)
    return
  fi

  parent=$(dirname "$path")
  leaf=$(basename "$path")
  if [ -d "$parent" ]; then
    parent_abs=$(CDPATH= cd "$parent" && pwd -P)
    printf '%s/%s\n' "$parent_abs" "$leaf"
    return
  fi

  case "$path" in
    /*|[A-Za-z]:*)
      printf '%s\n' "$path"
      ;;
    *)
      printf '%s/%s\n' "$(pwd -P)" "$path"
      ;;
  esac
}

print_root_record() {
  runtime=$1
  status=$2
  path=$3
  reason=$4

  echo "runtime: $runtime"
  echo "status: $status"
  echo "path: $path"
  echo "reason: $reason"
}

list_runtime_roots() {
  for runtime in codex agents claude openclaw hermes; do
    seen=
    runtime_candidates "$runtime" | while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      resolved=$(absolute_path "$candidate")
      case "
$seen
" in
        *"
$resolved
"*)
          continue
          ;;
      esac
      seen="${seen}
$resolved"
      if [ -d "$resolved" ]; then
        print_root_record "$runtime" exists "$resolved" "runtime skills root exists"
      else
        print_root_record "$runtime" missing "$resolved" "runtime skills root not found"
      fi
      echo
    done
  done
}

first_runtime_root() {
  runtime=$1
  create=${2:-0}

  if [ "$runtime" = "custom" ]; then
    echo "custom-runtime-requires-path" >&2
    return 1
  fi

  first=
  runtime_candidates "$runtime" | while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    resolved=$(absolute_path "$candidate")
    if [ -z "$first" ]; then
      first=$resolved
    fi
    if [ -d "$resolved" ]; then
      print_root_record "$runtime" exists "$resolved" "runtime skills root exists"
      exit 0
    fi
  done
}

resolve_runtime_root() {
  runtime=$1
  explicit_path=$2
  create=${3:-0}

  if [ -n "$explicit_path" ]; then
    if [ "$create" -eq 1 ]; then
      mkdir -p "$explicit_path"
    fi
    if [ ! -d "$explicit_path" ]; then
      echo "skill-root-missing: $explicit_path" >&2
      return 1
    fi
    print_root_record custom exists "$(absolute_path "$explicit_path")" "explicit path"
    return
  fi

  if [ "$runtime" = "custom" ]; then
    echo "custom-runtime-requires-path" >&2
    return 1
  fi

  first=
  found=
  candidates=$(runtime_candidates "$runtime")
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    resolved=$(absolute_path "$candidate")
    if [ -z "$first" ]; then
      first=$resolved
    fi
    if [ -d "$resolved" ]; then
      found=$resolved
      break
    fi
  done <<EOF
$candidates
EOF

  if [ -n "$found" ]; then
    print_root_record "$runtime" exists "$found" "runtime skills root exists"
    return
  fi

  if [ "$create" -eq 1 ]; then
    mkdir -p "$first"
    print_root_record "$runtime" exists "$(absolute_path "$first")" "created runtime skills root"
    return
  fi

  echo "skill-root-missing: $runtime" >&2
  return 1
}

list_existing_roots() {
  for runtime in codex agents claude openclaw hermes; do
    candidates=$(runtime_candidates "$runtime")
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      resolved=$(absolute_path "$candidate")
      if [ -d "$resolved" ]; then
        print_root_record "$runtime" exists "$resolved" "runtime skills root exists"
        echo
        break
      fi
    done <<EOF
$candidates
EOF
  done
}

if [ "${SKILL_ROOTS_LIB_ONLY:-0}" = "1" ]; then
  return 0
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
    --mode)
      need_value "$1" "${2:-}"
      MODE=$2
      shift 2
      ;;
    --runtime)
      need_value "$1" "${2:-}"
      RUNTIME=$2
      shift 2
      ;;
    --source-root)
      need_value "$1" "${2:-}"
      SOURCE_ROOT=$2
      shift 2
      ;;
    --install-root)
      need_value "$1" "${2:-}"
      INSTALL_ROOT=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

case "$RUNTIME" in
  codex|agents|claude|openclaw|hermes|custom)
    ;;
  *)
    echo "unsupported-runtime: $RUNTIME" >&2
    exit 2
    ;;
esac

case "$MODE" in
  list)
    list_runtime_roots
    ;;
  scan)
    if [ -n "$SOURCE_ROOT" ]; then
      resolve_runtime_root custom "$SOURCE_ROOT" 0
    else
      list_existing_roots
    fi
    ;;
  stage)
    resolve_runtime_root "$RUNTIME" "$SOURCE_ROOT" 0
    ;;
  install)
    resolve_runtime_root "$RUNTIME" "$INSTALL_ROOT" 1
    ;;
  install-default)
    resolve_runtime_root codex "" 1
    ;;
  install-all-existing)
    list_existing_roots
    ;;
  *)
    echo "unsupported-mode: $MODE" >&2
    exit 2
    ;;
esac
