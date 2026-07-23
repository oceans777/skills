#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/skill-catalog.sh"

ACTION=${1:-list}
if [ "$#" -gt 0 ]; then shift; fi
CATALOG_ROOT=$REPO_ROOT/catalog
SKILL=
REASON=
REPLACEMENT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog-root)
      [ "$#" -ge 2 ] || { echo "--catalog-root needs a path." >&2; exit 2; }
      CATALOG_ROOT=$2
      shift 2
      ;;
    --skill)
      [ "$#" -ge 2 ] || { echo "--skill needs a value." >&2; exit 2; }
      SKILL=$2
      shift 2
      ;;
    --reason)
      [ "$#" -ge 2 ] || { echo "--reason needs a value." >&2; exit 2; }
      REASON=$2
      shift 2
      ;;
    --replacement)
      [ "$#" -ge 2 ] || { echo "--replacement needs a value." >&2; exit 2; }
      REPLACEMENT=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

list_catalog() {
  printf 'state|repository|name|replacement|reason\n'
  for state in $OCEANS_CATALOG_STATES; do
    state_dir=$CATALOG_ROOT/$state
    [ -d "$state_dir" ] || continue
    for record_path in "$state_dir"/*.skill; do
      [ -f "$record_path" ] || continue
      name=$(oceans_catalog_record_value "$record_path" name || true)
      repository=$(oceans_catalog_record_value "$record_path" repository || true)
      replacement=$(oceans_catalog_record_value "$record_path" replacement || true)
      reason=$(oceans_catalog_record_value "$record_path" reason || true)
      printf '%s|%s|%s|%s|%s\n' "$state" "$repository" "$name" "$replacement" "$reason"
    done
  done
}

case "$ACTION" in
  list)
    list_catalog
    ;;
  activate|restore)
    [ -n "$SKILL" ] || { echo "--skill is required." >&2; exit 2; }
    oceans_catalog_move_record "$CATALOG_ROOT" "$SKILL" active "$REPLACEMENT" "$REASON"
    echo "catalog-state: active"
    echo "skill: $SKILL"
    ;;
  deprecate)
    [ -n "$SKILL" ] || { echo "--skill is required." >&2; exit 2; }
    [ -n "$REASON" ] || { echo "--reason is required for deprecate." >&2; exit 2; }
    oceans_catalog_move_record "$CATALOG_ROOT" "$SKILL" deprecated "$REPLACEMENT" "$REASON"
    echo "catalog-state: deprecated"
    echo "skill: $SKILL"
    ;;
  archive)
    [ -n "$SKILL" ] || { echo "--skill is required." >&2; exit 2; }
    [ -n "$REASON" ] || { echo "--reason is required for archive." >&2; exit 2; }
    oceans_catalog_move_record "$CATALOG_ROOT" "$SKILL" archived "$REPLACEMENT" "$REASON"
    echo "catalog-state: archived"
    echo "skill: $SKILL"
    ;;
  block)
    [ -n "$SKILL" ] || { echo "--skill is required." >&2; exit 2; }
    [ -n "$REASON" ] || { echo "--reason is required for block." >&2; exit 2; }
    oceans_catalog_move_record "$CATALOG_ROOT" "$SKILL" blocked "$REPLACEMENT" "$REASON"
    echo "catalog-state: blocked"
    echo "skill: $SKILL"
    ;;
  *)
    echo "Unsupported catalog action: $ACTION" >&2
    echo "Supported actions: list, activate, deprecate, archive, block, restore" >&2
    exit 2
    ;;
esac
