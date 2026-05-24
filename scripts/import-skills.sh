#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SKILL_ROOTS_LIB_ONLY=1 . "$SCRIPT_DIR/skill-roots.sh"
. "$SCRIPT_DIR/skill-publish-rules.sh"

SOURCE_ROOT=
RUNTIME=
FIRST_PARTY_ROOT=$REPO_ROOT/repos/oceans-skills/skills
COMMUNITY_ROOT=$REPO_ROOT/repos/community-skills/skills
FORMAT=text

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
    --runtime)
      if [ "$#" -lt 2 ]; then
        echo "--runtime needs a value." >&2
        exit 2
      fi
      RUNTIME=$2
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
    --first-party-root)
      if [ "$#" -lt 2 ]; then
        echo "--first-party-root needs a path." >&2
        exit 2
      fi
      FIRST_PARTY_ROOT=$2
      shift 2
      ;;
    --community-root)
      if [ "$#" -lt 2 ]; then
        echo "--community-root needs a path." >&2
        exit 2
      fi
      COMMUNITY_ROOT=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

case "$FORMAT" in
  text|json)
    ;;
  *)
  echo "Unsupported format: $FORMAT" >&2
  exit 2
    ;;
esac

ROOTS_FILE=$(mktemp "${TMPDIR:-/tmp}/oceans-import-roots.XXXXXX") || exit 1
RECORDS_FILE=$(mktemp "${TMPDIR:-/tmp}/oceans-import-records.XXXXXX") || {
  rm -f "$ROOTS_FILE"
  exit 1
}

cleanup_import_roots() {
  rm -f "$ROOTS_FILE" "$RECORDS_FILE"
}
trap 'cleanup_import_roots' EXIT
trap 'cleanup_import_roots; exit 129' HUP
trap 'cleanup_import_roots; exit 130' INT
trap 'cleanup_import_roots; exit 143' TERM

add_scan_root() {
  runtime=$1
  root_path=$2

  if [ ! -d "$root_path" ]; then
    echo "Local skills root does not exist: $root_path" >&2
    exit 1
  fi

  root_real=$(absolute_path "$root_path")
  printf '%s|%s\n' "$runtime" "$root_real" >> "$ROOTS_FILE"
}

add_first_existing_runtime_root() {
  runtime=$1
  candidates=$(runtime_candidates "$runtime")
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    candidate_real=$(absolute_path "$candidate")
    if [ -d "$candidate_real" ]; then
      add_scan_root "$runtime" "$candidate_real"
      return
    fi
  done <<EOF
$candidates
EOF
}

if [ -n "$SOURCE_ROOT" ]; then
  add_scan_root custom "$SOURCE_ROOT"
elif [ -n "$RUNTIME" ]; then
  add_first_existing_runtime_root "$RUNTIME"
else
  list_existing_root_records | while IFS='|' read -r known_runtime known_root; do
    [ -n "$known_runtime" ] || continue
    add_scan_root "$known_runtime" "$known_root"
  done
fi

if [ ! -s "$ROOTS_FILE" ]; then
  echo "No local skill roots found. Create a supported runtime skills directory or pass --source-root." >&2
  exit 1
fi

repository_match() {
  skill_name=$1
  matches=

  if [ -d "$FIRST_PARTY_ROOT/$skill_name" ]; then
    matches=oceans-skills
  fi

  if [ -d "$COMMUNITY_ROOT/$skill_name" ]; then
    if [ -n "$matches" ]; then
      matches="$matches, community-skills"
    else
      matches=community-skills
    fi
  fi

  if [ -z "$matches" ]; then
    echo "none"
  else
    echo "$matches"
  fi
}

managed_source() {
  skill_path=$1
  marker=$skill_path/.oceans-skill-source

  if [ ! -f "$marker" ]; then
    return 1
  fi

  sed -n 's/^source_repository=//p' "$marker" | sed -n '1p'
}

item_risks() {
  skill_path=$1
  skill_name=$2

  if [ "$skill_name" = ".system" ]; then
    echo "risk: not scanned"
    return
  fi

  metadata_risks=$(oceans_skill_metadata_issues "$skill_path" "$skill_name")
  scan_risks=$(oceans_scan_skill_risks "$skill_path")
  risks=$(printf '%s\n%s\n' "$metadata_risks" "$scan_risks" | awk 'NF && !seen[$0]++')

  if [ -z "$risks" ]; then
    echo "risk: none detected"
    return
  fi

  printf '%s\n' "$risks"
}

print_risks() {
  skill_path=$1
  skill_name=$2

  item_risks "$skill_path" "$skill_name" | sed 's/^/  /'
}

item_status() {
  skill_path=$1
  local_runtime_match=$2
  repository_match_value=$3
  skill_name=${skill_path##*/}
  duplicate_local_runtime=0
  case "$local_runtime_match" in
    *", "*)
      duplicate_local_runtime=1
      ;;
  esac

  if [ "$skill_name" = ".system" ]; then
    echo "skip-system|do not publish|do not publish|Codex system skills are not oceans777 source skills."
    return
  fi

  metadata_risks=$(oceans_skill_metadata_issues "$skill_path" "$skill_name")
  if [ -n "$metadata_risks" ]; then
    case "$metadata_risks" in
      *"risk: invalid skill folder name"*)
        echo "invalid-skill-name|manual repair before import|repair folder name and SKILL.md frontmatter before deciding whether to publish|A publishable skill must have a valid folder name, SKILL.md name, and description."
        ;;
      *)
        echo "invalid-skill-metadata|manual repair before import|repair folder name and SKILL.md frontmatter before deciding whether to publish|A publishable skill must have a valid folder name, SKILL.md name, and description."
        ;;
    esac
    return
  fi

  if [ ! -f "$skill_path/SKILL.md" ]; then
    echo "missing-skill-md|manual repair before import|repair SKILL.md before deciding whether to publish|A publishable skill must include SKILL.md."
    return
  fi

  source_repository=$(managed_source "$skill_path" || true)
  case "$source_repository" in
    oceans-skills)
      echo "already-managed|repos/oceans-skills/skills/$skill_name|managed by oceans777; install may update it|Local skill has an oceans777 first-party source marker."
      ;;
    community-skills)
      echo "already-managed|repos/community-skills/skills/$skill_name|managed by oceans777; install may update it|Local skill has an oceans777 community source marker."
      ;;
    *)
      if [ "$duplicate_local_runtime" -eq 1 ]; then
        echo "duplicate-local-runtime|choose one local runtime source before staging|stage with an explicit runtime or source root after review|The same local skill folder name exists in more than one runtime root."
      elif [ "$repository_match_value" != "none" ]; then
        echo "duplicate-local-wins|local skill stays installed|keep local skill; repository version will not overwrite it|A repository skill has the same name, but this local skill has no oceans777 source marker."
      else
        echo "review-source|oceans-skills if you created it; community-skills if third-party; do not publish if private|review source before publishing|No oceans777 source marker found."
      fi
      ;;
  esac
}

print_item() {
  skill_path=$1
  runtime=$2
  source_root=$3
  local_runtime_match=$4
  skill_name=${skill_path##*/}
  repository_match_value=$(repository_match "$skill_name")
  status_record=$(item_status "$skill_path" "$local_runtime_match" "$repository_match_value")
  status=$(printf '%s' "$status_record" | cut -d '|' -f 1)
  destination=$(printf '%s' "$status_record" | cut -d '|' -f 2)
  action=$(printf '%s' "$status_record" | cut -d '|' -f 3)
  reason=$(printf '%s' "$status_record" | cut -d '|' -f 4-)

  echo "- $skill_name"
  echo "  runtime: $runtime"
  echo "  source_root: $source_root"
  echo "  source_path: $skill_path"

  if [ "$skill_name" = ".system" ]; then
    echo "  status: $status"
    echo "  destination: $destination"
    echo "  repository_match: $repository_match_value"
    echo "  local_runtime_match: $local_runtime_match"
    echo "  action: $action"
    echo "  reason: $reason"
    echo "  risk: not scanned"
    return
  fi

  if [ ! -f "$skill_path/SKILL.md" ]; then
    echo "  status: $status"
    echo "  destination: $destination"
    echo "  repository_match: $repository_match_value"
    echo "  local_runtime_match: $local_runtime_match"
    echo "  action: $action"
    echo "  reason: $reason"
    print_risks "$skill_path" "$skill_name"
    return
  fi

  if [ "$status" = "invalid-skill-name" ] || [ "$status" = "invalid-skill-metadata" ]; then
    echo "  status: $status"
    echo "  destination: $destination"
    echo "  repository_match: $repository_match_value"
    echo "  local_runtime_match: $local_runtime_match"
    echo "  action: $action"
    echo "  reason: $reason"
    print_risks "$skill_path" "$skill_name"
    return
  fi

  echo "  status: $status"
  echo "  destination: $destination"
  echo "  repository_match: $repository_match_value"
  echo "  local_runtime_match: $local_runtime_match"
  echo "  action: $action"
  echo "  reason: $reason"
  print_risks "$skill_path" "$skill_name"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

print_json_report() {
  printf '{'
  printf '"source_roots":['
  first=1
  while IFS='|' read -r runtime source_root; do
    [ -n "$runtime" ] || continue
    if [ "$first" -eq 0 ]; then printf ','; fi
    first=0
    printf '{"runtime":'
    json_string "$runtime"
    printf ',"path":'
    json_string "$source_root"
    printf '}'
  done < "$ROOTS_FILE"
  printf ']'
  printf ',"first_party_target":'
  json_string "$FIRST_PARTY_ROOT"
  printf ',"community_target":'
  json_string "$COMMUNITY_ROOT"
  printf ',"mode":"report only","copied_files":0'
  printf ',"items":['
  first=1
  sort "$RECORDS_FILE" | while IFS='|' read -r skill_name runtime source_root skill_path; do
    [ -n "$skill_name" ] || continue
    local_runtime_match=$(awk -F'|' -v name="$skill_name" '
      $1 == name && !seen[$2]++ {
        if (out == "") {
          out = $2
        } else {
          out = out ", " $2
        }
      }
      END { print out }
    ' "$RECORDS_FILE")
    repository_match_value=$(repository_match "$skill_name")
    status_record=$(item_status "$skill_path" "$local_runtime_match" "$repository_match_value")
    status=$(printf '%s' "$status_record" | cut -d '|' -f 1)
    destination=$(printf '%s' "$status_record" | cut -d '|' -f 2)
    action=$(printf '%s' "$status_record" | cut -d '|' -f 3)
    reason=$(printf '%s' "$status_record" | cut -d '|' -f 4-)
    if [ "$first" -eq 0 ]; then printf ','; fi
    first=0
    printf '{"name":'; json_string "$skill_name"
    printf ',"runtime":'; json_string "$runtime"
    printf ',"source_root":'; json_string "$source_root"
    printf ',"source_path":'; json_string "$skill_path"
    printf ',"status":'; json_string "$status"
    printf ',"destination":'; json_string "$destination"
    printf ',"repository_match":'; json_string "$repository_match_value"
    printf ',"local_runtime_match":'; json_string "$local_runtime_match"
    printf ',"action":'; json_string "$action"
    printf ',"reason":'; json_string "$reason"
    printf ',"risks":['
    first_risk=1
    item_risks "$skill_path" "$skill_name" | while IFS= read -r risk; do
      [ -n "$risk" ] || continue
      if [ "$first_risk" -eq 0 ]; then printf ','; fi
      first_risk=0
      json_string "$risk"
    done
    printf ']'
    printf '}'
  done
  printf ']}'
  echo
}

while IFS='|' read -r runtime source_root; do
  [ -n "$runtime" ] || continue
  for skill_path in "$source_root"/* "$source_root"/.[!.]* "$source_root"/..?*; do
    [ -d "$skill_path" ] || continue
    skill_name=${skill_path##*/}
    [ "$skill_name" != "." ] || continue
    [ "$skill_name" != ".." ] || continue
    printf '%s|%s|%s|%s\n' "$skill_name" "$runtime" "$source_root" "$skill_path" >> "$RECORDS_FILE"
  done
done < "$ROOTS_FILE"

if [ "$FORMAT" = "json" ]; then
  print_json_report
  exit 0
fi

echo "oceans777 local skill import report"
echo "Source roots:"
while IFS='|' read -r runtime source_root; do
  [ -n "$runtime" ] || continue
  echo "  $runtime: $source_root"
done < "$ROOTS_FILE"
echo "First-party target: $FIRST_PARTY_ROOT"
echo "Community target: $COMMUNITY_ROOT"
echo "Mode: report only"
echo "No files were copied."
echo

found=0
sort "$RECORDS_FILE" | while IFS='|' read -r skill_name runtime source_root skill_path; do
  [ -n "$skill_name" ] || continue
  found=1
  local_runtime_match=$(awk -F'|' -v name="$skill_name" '
    $1 == name && !seen[$2]++ {
      if (out == "") {
        out = $2
      } else {
        out = out ", " $2
      }
    }
    END { print out }
  ' "$RECORDS_FILE")
  print_item "$skill_path" "$runtime" "$source_root" "$local_runtime_match"
done

if [ ! -s "$RECORDS_FILE" ]; then
  echo "No local skill directories found."
fi
