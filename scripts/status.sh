#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
. "$REPO_ROOT/scripts/common.sh"

RUNTIME=
ALL_EXISTING_RUNTIMES=0

REQUESTED_RUNTIME=$RUNTIME
REQUESTED_ALL_EXISTING_RUNTIMES=$ALL_EXISTING_RUNTIMES
SKILL_ROOTS_LIB_ONLY=1
. "$REPO_ROOT/scripts/skill-roots.sh"
unset SKILL_ROOTS_LIB_ONLY
RUNTIME=$REQUESTED_RUNTIME
ALL_EXISTING_RUNTIMES=$REQUESTED_ALL_EXISTING_RUNTIMES

need_value() {
  option=$1
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    echo "$option needs a value." >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime)
      need_value "$1" "${2:-}"
      RUNTIME=$2
      shift 2
      ;;
    --all-existing-runtimes)
      ALL_EXISTING_RUNTIMES=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

case "$RUNTIME" in
  ""|codex|agents|claude|openclaw|hermes)
    ;;
  custom)
    echo "custom-runtime-requires-path" >&2
    exit 2
    ;;
  *)
    echo "unsupported-runtime: $RUNTIME" >&2
    exit 2
    ;;
esac

if [ -n "$RUNTIME" ] && [ "$ALL_EXISTING_RUNTIMES" -eq 1 ]; then
  echo "runtime-and-all-existing-runtimes-are-mutually-exclusive" >&2
  exit 2
fi

managed_skill_count() {
  root=$1
  count=0

  if [ ! -d "$root" ]; then
    echo "not_available"
    return
  fi

  for skill_path in "$root"/*; do
    if [ -d "$skill_path" ] && [ -f "$skill_path/.oceans-skill-source" ]; then
      count=$((count + 1))
    fi
  done

  echo "$count"
}

print_status_root() {
  runtime=$1
  status=$2
  path=$3
  reason=$4

  echo "  runtime: $runtime"
  echo "  status: $status"
  echo "  path: $path"
  echo "  reason: $reason"
  echo "  managed_oceans_skills: $(managed_skill_count "$path")"
}

print_status_for_runtime() {
  runtime=$1
  only_existing=${2:-0}
  seen=
  candidates=$(runtime_candidates "$runtime")

  while IFS= read -r candidate; do
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
      print_status_root "$runtime" exists "$resolved" "runtime skills root exists"
      echo
    elif [ "$only_existing" -eq 0 ]; then
      print_status_root "$runtime" missing "$resolved" "runtime skills root not found"
      echo
    fi
  done <<EOF
$candidates
EOF

  return 0
}

echo "Repository:"
invoke_git "Read repository status" status --short --branch

echo
echo "Child repositories:"
invoke_git "Read child repository status" submodule status

echo
echo "Runtime skill roots:"
if [ -n "$RUNTIME" ]; then
  print_status_for_runtime "$RUNTIME" 0
elif [ "$ALL_EXISTING_RUNTIMES" -eq 1 ]; then
  any_existing=0
  for runtime_name in codex agents claude openclaw hermes; do
    candidates=$(runtime_candidates "$runtime_name")
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      resolved=$(absolute_path "$candidate")
      if [ -d "$resolved" ]; then
        print_status_root "$runtime_name" exists "$resolved" "runtime skills root exists"
        echo
        any_existing=1
        break
      fi
    done <<EOF
$candidates
EOF
    true
  done
  if [ "$any_existing" -eq 0 ]; then
    echo "  No existing runtime skill roots found."
  fi
else
  for runtime_name in codex agents claude openclaw hermes; do
    print_status_for_runtime "$runtime_name" 0
  done
fi
