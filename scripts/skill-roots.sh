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
  config_home=${XDG_CONFIG_HOME:-$home/.config}

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
        printf '%s\n' "$config_home/openclaw/skills"
      fi
      ;;
    hermes)
      if [ -n "${HERMES_HOME:-}" ]; then
        printf '%s\n' "$HERMES_HOME/skills"
      else
        printf '%s\n' "$home/.hermes/skills"
        printf '%s\n' "$config_home/hermes/skills"
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

oceans_valid_runtime_name() {
  case "$1" in codex|agents|claude|openclaw|hermes|custom) return 0 ;; esac
  return 1
}

oceans_runtime_registry_path() {
  if [ -n "${OCEANS_RUNTIME_ROOTS_FILE:-}" ]; then
    printf '%s\n' "$OCEANS_RUNTIME_ROOTS_FILE"
    return
  fi
  state_home=${XDG_STATE_HOME:-$(oceans_home)/.local/state}
  printf '%s/oceans777-skills/runtime-roots\n' "$state_home"
}

oceans_safe_runtime_record_value() {
  value=$1
  [ -n "$value" ] || return 1
  if printf '%s' "$value" | LC_ALL=C grep -q '[|[:cntrl:]]'; then return 1; fi
  return 0
}

oceans_register_runtime_root() (
  runtime=$1
  install_root=$2
  oceans_valid_runtime_name "$runtime" || {
    echo "Cannot register unsupported runtime: $runtime" >&2
    return 1
  }
  [ -d "$install_root" ] && [ ! -L "$install_root" ] || {
    echo "Cannot register unsafe runtime root: $install_root" >&2
    return 1
  }
  resolved=$(absolute_path "$install_root")
  oceans_safe_runtime_record_value "$resolved" || {
    echo "Runtime root contains unsupported characters: $resolved" >&2
    return 1
  }

  registry=$(oceans_runtime_registry_path)
  registry_parent=$(dirname "$registry")
  mkdir -p "$registry_parent"
  [ ! -L "$registry_parent" ] || {
    echo "Runtime registry parent must not be a symlink: $registry_parent" >&2
    return 1
  }
  [ ! -e "$registry" ] || [ -f "$registry" ] || {
    echo "Runtime registry is not a regular file: $registry" >&2
    return 1
  }
  [ ! -L "$registry" ] || {
    echo "Runtime registry must not be a symlink: $registry" >&2
    return 1
  }

  lock=$registry.lock
  if ! mkdir "$lock" 2>/dev/null; then
    echo "Another runtime registry update is active: $registry" >&2
    return 1
  fi
  cleanup_registry_update() {
    rm -f "${tmp:-}"
    rm -rf "$lock"
  }
  trap cleanup_registry_update EXIT HUP INT TERM

  tmp=$(mktemp "$registry_parent/.runtime-roots.XXXXXX") || return 1
  if [ -f "$registry" ]; then
    while IFS='|' read -r existing_runtime existing_path extra || [ -n "${existing_runtime:-}${existing_path:-}${extra:-}" ]; do
      [ -z "${extra:-}" ] || {
        echo "Malformed runtime registry record: $registry" >&2
        return 1
      }
      oceans_valid_runtime_name "${existing_runtime:-}" || {
        echo "Malformed runtime registry runtime: ${existing_runtime:-}" >&2
        return 1
      }
      oceans_safe_runtime_record_value "${existing_path:-}" || {
        echo "Malformed runtime registry path." >&2
        return 1
      }
      [ "$existing_path" = "$resolved" ] || printf '%s|%s\n' "$existing_runtime" "$existing_path" >> "$tmp"
    done < "$registry"
  fi
  printf '%s|%s\n' "$runtime" "$resolved" >> "$tmp"
  LC_ALL=C sort -u "$tmp" -o "$tmp"
  mv "$tmp" "$registry"
  tmp=
)

oceans_list_registered_root_records() {
  registry=$(oceans_runtime_registry_path)
  [ -f "$registry" ] || return 0
  [ ! -L "$registry" ] || {
    echo "Runtime registry must not be a symlink: $registry" >&2
    return 1
  }
  while IFS='|' read -r runtime resolved extra || [ -n "${runtime:-}${resolved:-}${extra:-}" ]; do
    [ -z "${extra:-}" ] || {
      echo "Malformed runtime registry record: $registry" >&2
      return 1
    }
    oceans_valid_runtime_name "${runtime:-}" || {
      echo "Malformed runtime registry runtime: ${runtime:-}" >&2
      return 1
    }
    oceans_safe_runtime_record_value "${resolved:-}" || {
      echo "Malformed runtime registry path." >&2
      return 1
    }
    if [ -d "$resolved" ] && [ ! -L "$resolved" ]; then
      printf '%s|%s\n' "$runtime" "$(absolute_path "$resolved")"
    fi
  done < "$registry"
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
    runtime_candidates "$runtime" | while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      resolved=$(absolute_path "$candidate")
      if [ -d "$resolved" ]; then
        print_root_record "$runtime" exists "$resolved" "runtime skills root exists"
      else
        print_root_record "$runtime" missing "$resolved" "runtime skills root not found"
      fi
      echo
    done
  done
  oceans_list_registered_root_records | while IFS='|' read -r runtime resolved; do
    [ -n "$runtime" ] || continue
    print_root_record "$runtime" exists "$resolved" "registered runtime skills root"
    echo
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
  list_existing_root_records | while IFS='|' read -r runtime resolved; do
    [ -n "$runtime" ] || continue
    print_root_record "$runtime" exists "$resolved" "known runtime skills root"
    echo
  done
}

list_existing_root_records() {
  records=$(mktemp "${TMPDIR:-/tmp}/oceans-runtime-roots.XXXXXX") || return 1
  for runtime in codex agents claude openclaw hermes; do
    candidates=$(runtime_candidates "$runtime")
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      resolved=$(absolute_path "$candidate")
      if [ -d "$resolved" ] && [ ! -L "$resolved" ]; then
        printf '%s|%s\n' "$runtime" "$resolved" >> "$records"
      fi
    done <<EOF
$candidates
EOF
  done
  oceans_list_registered_root_records >> "$records" || {
    rm -f "$records"
    return 1
  }
  awk -F'|' 'NF == 2 && !seen[$2]++ { print $1 "|" $2 }' "$records"
  rm -f "$records"
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

oceans_valid_runtime_name "$RUNTIME" || {
  echo "unsupported-runtime: $RUNTIME" >&2
  exit 2
}

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
