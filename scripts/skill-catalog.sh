#!/bin/sh

OCEANS_CATALOG_SCHEMA_VERSION=2
OCEANS_CATALOG_STATES="active pending-review deprecated archived blocked"
OCEANS_CATALOG_REQUIRED_KEYS="schema_version name status package_repository upstream_repository upstream_path upstream_ref upstream_commit candidate_upstream_repository candidate_upstream_path candidate_upstream_ref candidate_upstream_commit replacement status_reason transition_note updated_at"
OCEANS_CATALOG_OPTIONAL_KEYS="content_sha256 candidate_content_sha256"
OCEANS_CATALOG_KEYS="$OCEANS_CATALOG_REQUIRED_KEYS $OCEANS_CATALOG_OPTIONAL_KEYS"
. "$(CDPATH= cd "$(dirname "$0")" && pwd)/skill-content-hash.sh"


oceans_catalog_valid_skill_name() {
  name=$1
  case "$name" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|""|-*|*-|*--*) return 1 ;;
  esac
  [ "${#name}" -le 64 ]
}


oceans_catalog_valid_state() {
  requested_state=$1
  for known_state in $OCEANS_CATALOG_STATES; do
    [ "$requested_state" = "$known_state" ] && return 0
  done
  return 1
}


oceans_catalog_record_path() {
  catalog_root=$1
  skill_name=$2
  printf '%s/skills/%s.skill\n' "$catalog_root" "$skill_name"
}


oceans_catalog_review_path() {
  catalog_root=$1
  package_repository=$2
  skill_name=$3
  printf '%s/review-queue/%s/%s\n' "$catalog_root" "$package_repository" "$skill_name"
}


oceans_catalog_record_value() {
  record_path=$1
  key=$2
  [ -f "$record_path" ] || return 1
  awk -v key="$key" '
    index($0, key "=") == 1 {
      print substr($0, length(key) + 2)
      exit
    }
  ' "$record_path"
}


oceans_catalog_state_for_skill() {
  catalog_root=$1
  skill_name=$2
  record_path=$(oceans_catalog_record_path "$catalog_root" "$skill_name")
  [ -f "$record_path" ] || return 1
  status=$(oceans_catalog_record_value "$record_path" status || true)
  oceans_catalog_valid_state "$status" || return 2
  printf '%s\n' "$status"
}


oceans_catalog_repository_for_skill() {
  catalog_root=$1
  skill_name=$2
  record_path=$(oceans_catalog_record_path "$catalog_root" "$skill_name")
  [ -f "$record_path" ] || return 1
  oceans_catalog_record_value "$record_path" package_repository
}


oceans_catalog_record_has_candidate() {
  record_path=$1
  candidate_commit=$(oceans_catalog_record_value "$record_path" candidate_upstream_commit || true)
  [ -n "$candidate_commit" ]
}


oceans_catalog_safe_value() {
  value=$1
  if LC_ALL=C printf '%s' "$value" | grep -q '[[:cntrl:]]'; then return 1; fi
  return 0
}


oceans_catalog_valid_repository_url() {
  value=$1
  printf '%s\n' "$value" | grep -E -q '^https://github[.]com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$'
}


oceans_catalog_valid_upstream_path() {
  value=$1
  [ -n "$value" ] || return 1
  [ "$value" = "." ] && return 0
  case "$value" in
    /*|../*|*/../*|*/..|..|*\\*) return 1 ;;
  esac
  oceans_catalog_safe_value "$value"
}


oceans_catalog_acquire_lock() {
  catalog_root=$1
  skill_name=$2
  oceans_catalog_valid_skill_name "$skill_name" || {
    echo "Invalid catalog skill name: $skill_name" >&2
    return 1
  }
  lock_root=$catalog_root/.locks
  lock_path=$lock_root/$skill_name.lock
  mkdir -p "$lock_root"
  if [ -L "$lock_path" ]; then
    echo "Refusing unsafe catalog lock: $lock_path" >&2
    return 1
  fi
  if ! mkdir "$lock_path" 2>/dev/null; then
    if [ -d "$lock_path" ] && find "$lock_path" -maxdepth 0 -mmin +30 -print 2>/dev/null | grep -q .; then
      rm -rf "$lock_path"
      mkdir "$lock_path" 2>/dev/null || {
        echo "Another catalog operation is active: $skill_name" >&2
        return 1
      }
    else
      echo "Another catalog operation is active: $skill_name" >&2
      return 1
    fi
  fi
  printf '%s\n' "$$" > "$lock_path/pid"
  OCEANS_CATALOG_LOCK_PATH=$lock_path
}


oceans_catalog_release_lock() {
  lock_path=${OCEANS_CATALOG_LOCK_PATH:-}
  if [ -n "$lock_path" ] && [ -d "$lock_path" ] && [ ! -L "$lock_path" ]; then
    rm -rf "$lock_path"
  fi
  OCEANS_CATALOG_LOCK_PATH=
}


oceans_catalog_write_record() {
  catalog_root=$1
  skill_name=$2
  status=$3
  package_repository=$4
  upstream_repository=$5
  upstream_path=$6
  upstream_ref=$7
  upstream_commit=$8
  candidate_upstream_repository=$9
  candidate_upstream_path=${10}
  candidate_upstream_ref=${11}
  candidate_upstream_commit=${12}
  replacement=${13}
  status_reason=${14}
  transition_note=${15}
  content_sha256=${16:-}
  candidate_content_sha256=${17:-}

  oceans_catalog_valid_skill_name "$skill_name" || {
    echo "Invalid catalog skill name: $skill_name" >&2
    return 1
  }
  oceans_catalog_valid_state "$status" || {
    echo "Unsupported catalog state: $status" >&2
    return 1
  }
  case "$package_repository" in
    oceans-skills|community-skills) ;;
    *) echo "Unsupported package repository: $package_repository" >&2; return 1 ;;
  esac
  for value in "$skill_name" "$status" "$package_repository" "$upstream_repository" "$upstream_path" "$upstream_ref" "$upstream_commit" "$candidate_upstream_repository" "$candidate_upstream_path" "$candidate_upstream_ref" "$candidate_upstream_commit" "$replacement" "$status_reason" "$transition_note" "$content_sha256" "$candidate_content_sha256"; do
    oceans_catalog_safe_value "$value" || {
      echo "Catalog values must be single-line text." >&2
      return 1
    }
  done
  if [ -n "$content_sha256" ] && ! oceans_valid_sha256 "$content_sha256"; then
    echo "Invalid content SHA-256 for $skill_name" >&2
    return 1
  fi
  if [ -n "$candidate_content_sha256" ] && ! oceans_valid_sha256 "$candidate_content_sha256"; then
    echo "Invalid candidate content SHA-256 for $skill_name" >&2
    return 1
  fi

  skills_dir=$catalog_root/skills
  mkdir -p "$skills_dir"
  record_path=$(oceans_catalog_record_path "$catalog_root" "$skill_name")
  staging_path=$(mktemp "$skills_dir/.${skill_name}.skill.XXXXXX") || return 1
  updated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  {
    printf 'schema_version=%s\n' "$OCEANS_CATALOG_SCHEMA_VERSION"
    printf 'name=%s\n' "$skill_name"
    printf 'status=%s\n' "$status"
    printf 'package_repository=%s\n' "$package_repository"
    printf 'upstream_repository=%s\n' "$upstream_repository"
    printf 'upstream_path=%s\n' "$upstream_path"
    printf 'upstream_ref=%s\n' "$upstream_ref"
    printf 'upstream_commit=%s\n' "$upstream_commit"
    printf 'candidate_upstream_repository=%s\n' "$candidate_upstream_repository"
    printf 'candidate_upstream_path=%s\n' "$candidate_upstream_path"
    printf 'candidate_upstream_ref=%s\n' "$candidate_upstream_ref"
    printf 'candidate_upstream_commit=%s\n' "$candidate_upstream_commit"
    printf 'content_sha256=%s\n' "$content_sha256"
    printf 'candidate_content_sha256=%s\n' "$candidate_content_sha256"
    printf 'replacement=%s\n' "$replacement"
    printf 'status_reason=%s\n' "$status_reason"
    printf 'transition_note=%s\n' "$transition_note"
    printf 'updated_at=%s\n' "$updated_at"
  } > "$staging_path"
  mv "$staging_path" "$record_path"
}


oceans_catalog_record_schema_issues() {
  record_path=$1
  seen_file=$(mktemp "${TMPDIR:-/tmp}/oceans-catalog-keys.XXXXXX") || return 1
  : > "$seen_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*} ;;
      *) echo "Malformed catalog line in ${record_path##*/}"; continue ;;
    esac
    case " $OCEANS_CATALOG_KEYS " in
      *" $key "*) ;;
      *) echo "Unknown catalog key in ${record_path##*/}: $key" ;;
    esac
    if grep -F -x -q "$key" "$seen_file"; then
      echo "Duplicate catalog key in ${record_path##*/}: $key"
    else
      printf '%s\n' "$key" >> "$seen_file"
    fi
  done < "$record_path"
  for required_key in $OCEANS_CATALOG_REQUIRED_KEYS; do
    if ! grep -F -x -q "$required_key" "$seen_file"; then
      echo "Missing catalog key in ${record_path##*/}: $required_key"
    fi
  done
  rm -f "$seen_file"
}


oceans_catalog_validation_issues() {
  catalog_root=$1
  first_party_skills_root=$2
  community_skills_root=$3

  [ -d "$catalog_root" ] || { echo "Missing catalog root: $catalog_root"; return; }
  [ -d "$catalog_root/skills" ] || echo "Missing catalog skills directory: $catalog_root/skills"
  [ -d "$catalog_root/review-queue" ] || echo "Missing catalog review queue: $catalog_root/review-queue"

  for legacy_state in $OCEANS_CATALOG_STATES; do
    if [ -d "$catalog_root/$legacy_state" ] && find "$catalog_root/$legacy_state" -type f -name '*.skill' -print -quit 2>/dev/null | grep -q .; then
      echo "Legacy state-directory catalog records are not supported: $catalog_root/$legacy_state"
    fi
  done

  for record_path in "$catalog_root/skills"/*.skill; do
    [ -f "$record_path" ] || continue
    record_file=${record_path##*/}
    skill_name=${record_file%.skill}
    oceans_catalog_record_schema_issues "$record_path"

    schema_version=$(oceans_catalog_record_value "$record_path" schema_version || true)
    name=$(oceans_catalog_record_value "$record_path" name || true)
    status=$(oceans_catalog_record_value "$record_path" status || true)
    package_repository=$(oceans_catalog_record_value "$record_path" package_repository || true)
    upstream_repository=$(oceans_catalog_record_value "$record_path" upstream_repository || true)
    upstream_path=$(oceans_catalog_record_value "$record_path" upstream_path || true)
    upstream_ref=$(oceans_catalog_record_value "$record_path" upstream_ref || true)
    upstream_commit=$(oceans_catalog_record_value "$record_path" upstream_commit || true)
    candidate_repository=$(oceans_catalog_record_value "$record_path" candidate_upstream_repository || true)
    candidate_path=$(oceans_catalog_record_value "$record_path" candidate_upstream_path || true)
    candidate_ref=$(oceans_catalog_record_value "$record_path" candidate_upstream_ref || true)
    candidate_commit=$(oceans_catalog_record_value "$record_path" candidate_upstream_commit || true)
    content_sha256=$(oceans_catalog_record_value "$record_path" content_sha256 || true)
    candidate_content_sha256=$(oceans_catalog_record_value "$record_path" candidate_content_sha256 || true)
    replacement=$(oceans_catalog_record_value "$record_path" replacement || true)
    status_reason=$(oceans_catalog_record_value "$record_path" status_reason || true)
    updated_at=$(oceans_catalog_record_value "$record_path" updated_at || true)

    [ "$schema_version" = "$OCEANS_CATALOG_SCHEMA_VERSION" ] || echo "Unsupported catalog schema for $skill_name: $schema_version"
    oceans_catalog_valid_skill_name "$skill_name" || echo "Invalid catalog filename: $record_file"
    [ "$name" = "$skill_name" ] || echo "Catalog name mismatch: $skill_name"
    oceans_catalog_valid_state "$status" || echo "Unsupported catalog status for $skill_name: $status"
    case "$package_repository" in
      oceans-skills) repository_root=$first_party_skills_root ;;
      community-skills) repository_root=$community_skills_root ;;
      *) echo "Unsupported package repository for $skill_name: $package_repository"; repository_root= ;;
    esac

    current_count=0
    [ -n "$upstream_repository" ] && current_count=$((current_count + 1))
    [ -n "$upstream_path" ] && current_count=$((current_count + 1))
    [ -n "$upstream_ref" ] && current_count=$((current_count + 1))
    [ -n "$upstream_commit" ] && current_count=$((current_count + 1))
    candidate_count=0
    [ -n "$candidate_repository" ] && candidate_count=$((candidate_count + 1))
    [ -n "$candidate_path" ] && candidate_count=$((candidate_count + 1))
    [ -n "$candidate_ref" ] && candidate_count=$((candidate_count + 1))
    [ -n "$candidate_commit" ] && candidate_count=$((candidate_count + 1))

    if [ "$current_count" -ne 0 ] && [ "$current_count" -ne 4 ]; then echo "Partial current provenance for $skill_name"; fi
    if [ "$candidate_count" -ne 0 ] && [ "$candidate_count" -ne 4 ]; then echo "Partial candidate provenance for $skill_name"; fi
    if [ -n "$content_sha256" ] && ! oceans_valid_sha256 "$content_sha256"; then echo "Invalid content SHA-256 for $skill_name"; fi
    if [ -n "$candidate_content_sha256" ] && ! oceans_valid_sha256 "$candidate_content_sha256"; then echo "Invalid candidate content SHA-256 for $skill_name"; fi
    if [ "$current_count" -eq 0 ] && [ -n "$content_sha256" ]; then echo "Content SHA-256 exists without current provenance: $skill_name"; fi
    if [ "$candidate_count" -eq 0 ] && [ -n "$candidate_content_sha256" ]; then echo "Candidate content SHA-256 exists without candidate provenance: $skill_name"; fi

    if [ "$current_count" -eq 4 ]; then
      oceans_catalog_valid_repository_url "$upstream_repository" || echo "Invalid upstream repository for $skill_name"
      oceans_catalog_valid_upstream_path "$upstream_path" || echo "Invalid upstream path for $skill_name: $upstream_path"
      case "$upstream_commit" in ''|*[!0-9a-f]*|???????????????????????????????????????|?????????????????????????????????????????*) echo "Invalid upstream commit for $skill_name" ;; esac
      if [ -n "$content_sha256" ] && [ -n "$repository_root" ] && [ -d "$repository_root/$skill_name" ]; then
        actual_content_sha256=$(oceans_skill_content_sha256 "$repository_root/$skill_name" 2>/dev/null || true)
        [ -n "$actual_content_sha256" ] || echo "Unable to calculate published content SHA-256 for $skill_name"
        [ -z "$actual_content_sha256" ] || [ "$actual_content_sha256" = "$content_sha256" ] || echo "Published content SHA-256 mismatch for $skill_name"
      fi
    fi
    if [ "$candidate_count" -eq 4 ]; then
      oceans_catalog_valid_repository_url "$candidate_repository" || echo "Invalid candidate repository for $skill_name"
      oceans_catalog_valid_upstream_path "$candidate_path" || echo "Invalid candidate path for $skill_name: $candidate_path"
      case "$candidate_commit" in ''|*[!0-9a-f]*|???????????????????????????????????????|?????????????????????????????????????????*) echo "Invalid candidate commit for $skill_name" ;; esac
      [ -n "$candidate_content_sha256" ] || echo "Candidate content SHA-256 is missing: $skill_name"
      review_path=$(oceans_catalog_review_path "$catalog_root" "$package_repository" "$skill_name")
      if [ ! -d "$review_path" ]; then
        echo "Candidate review content is missing: $package_repository/$skill_name"
      elif [ -n "$candidate_content_sha256" ] && oceans_valid_sha256 "$candidate_content_sha256"; then
        actual_candidate_sha256=$(oceans_skill_content_sha256 "$review_path" 2>/dev/null || true)
        [ -n "$actual_candidate_sha256" ] || echo "Unable to calculate candidate content SHA-256 for $skill_name"
        [ -z "$actual_candidate_sha256" ] || [ "$actual_candidate_sha256" = "$candidate_content_sha256" ] || echo "Candidate content SHA-256 mismatch for $skill_name"
      fi
    fi

    case "$status" in
      pending-review)
        [ "$current_count" -eq 0 ] || echo "Pending new skill must not have current provenance: $skill_name"
        [ "$candidate_count" -eq 4 ] || echo "Pending new skill must have a complete candidate: $skill_name"
        [ -z "$repository_root" ] || [ ! -d "$repository_root/$skill_name" ] || echo "Pending new skill already exists in package repository: $skill_name"
        [ -z "$status_reason" ] || echo "Pending skill must not keep a status reason: $skill_name"
        ;;
      active)
        [ "$current_count" -eq 4 ] || echo "Active skill lacks current provenance: $skill_name"
        [ -z "$status_reason" ] || echo "Active skill must not keep a status reason: $skill_name"
        [ -z "$repository_root" ] || [ -d "$repository_root/$skill_name" ] || echo "Active skill package is missing: $package_repository/$skill_name"
        ;;
      deprecated|archived|blocked)
        [ "$current_count" -eq 4 ] || echo "$status skill lacks current provenance: $skill_name"
        [ "$candidate_count" -eq 0 ] || echo "$status skill cannot have a pending candidate: $skill_name"
        [ -n "$status_reason" ] || echo "Missing lifecycle reason for $status skill: $skill_name"
        [ -z "$repository_root" ] || [ -d "$repository_root/$skill_name" ] || echo "$status skill package is missing: $package_repository/$skill_name"
        ;;
    esac

    if [ -n "$replacement" ]; then
      oceans_catalog_valid_skill_name "$replacement" || echo "Invalid replacement for $skill_name: $replacement"
      [ "$replacement" != "$skill_name" ] || echo "Skill cannot replace itself: $skill_name"
      replacement_record=$(oceans_catalog_record_path "$catalog_root" "$replacement")
      if [ ! -f "$replacement_record" ]; then
        echo "Replacement skill is missing from catalog: $skill_name -> $replacement"
      else
        replacement_status=$(oceans_catalog_record_value "$replacement_record" status || true)
        [ "$replacement_status" = active ] || echo "Replacement skill is not active: $skill_name -> $replacement"
      fi
    fi
    printf '%s\n' "$updated_at" | grep -E -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || echo "Invalid updated_at for $skill_name"
  done

  for repository_entry in "oceans-skills|$first_party_skills_root" "community-skills|$community_skills_root"; do
    package_repository=${repository_entry%%|*}
    skills_root=${repository_entry#*|}
    [ -d "$skills_root" ] || continue
    for skill_path in "$skills_root"/*; do
      [ -d "$skill_path" ] || continue
      skill_name=${skill_path##*/}
      record_path=$(oceans_catalog_record_path "$catalog_root" "$skill_name")
      if [ ! -f "$record_path" ]; then
        echo "Skill is missing from catalog: $package_repository/$skill_name"
        continue
      fi
      record_repository=$(oceans_catalog_record_value "$record_path" package_repository || true)
      [ "$record_repository" = "$package_repository" ] || echo "Catalog repository mismatch for $skill_name: $record_repository"
      status=$(oceans_catalog_record_value "$record_path" status || true)
      [ "$status" != pending-review ] || echo "Pending new skill must not exist in active package directory: $skill_name"
    done
  done

  for package_repository in oceans-skills community-skills; do
    review_root=$catalog_root/review-queue/$package_repository
    [ -d "$review_root" ] || continue
    for review_path in "$review_root"/*; do
      [ -d "$review_path" ] || continue
      skill_name=${review_path##*/}
      record_path=$(oceans_catalog_record_path "$catalog_root" "$skill_name")
      if [ ! -f "$record_path" ]; then
        echo "Orphan candidate review content: $package_repository/$skill_name"
        continue
      fi
      record_repository=$(oceans_catalog_record_value "$record_path" package_repository || true)
      candidate_commit=$(oceans_catalog_record_value "$record_path" candidate_upstream_commit || true)
      candidate_content_sha256=$(oceans_catalog_record_value "$record_path" candidate_content_sha256 || true)
      [ "$record_repository" = "$package_repository" ] || echo "Candidate repository mismatch for $skill_name: $record_repository"
      [ -n "$candidate_commit" ] || echo "Orphan candidate review content: $package_repository/$skill_name"
      [ -n "$candidate_content_sha256" ] || echo "Candidate content SHA-256 is missing: $package_repository/$skill_name"
    done
  done
}
