#!/bin/sh

OCEANS_CATALOG_STATES="active pending-review deprecated archived blocked"

oceans_catalog_valid_state() {
  requested_state=$1
  for known_state in $OCEANS_CATALOG_STATES; do
    [ "$requested_state" = "$known_state" ] && return 0
  done
  return 1
}

oceans_catalog_record_path() {
  catalog_root=$1
  state=$2
  skill_name=$3
  printf '%s/%s/%s.skill\n' "$catalog_root" "$state" "$skill_name"
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

oceans_catalog_states_for_skill() {
  catalog_root=$1
  skill_name=$2
  for state in $OCEANS_CATALOG_STATES; do
    record_path=$(oceans_catalog_record_path "$catalog_root" "$state" "$skill_name")
    [ -f "$record_path" ] && printf '%s\n' "$state"
  done
}

oceans_catalog_state_for_skill() {
  catalog_root=$1
  skill_name=$2
  states=$(oceans_catalog_states_for_skill "$catalog_root" "$skill_name")
  [ -n "$states" ] || return 1
  state_count=$(printf '%s\n' "$states" | awk 'NF { count++ } END { print count + 0 }')
  [ "$state_count" -eq 1 ] || return 2
  printf '%s\n' "$states"
}

oceans_catalog_repository_for_skill() {
  catalog_root=$1
  skill_name=$2
  state=$(oceans_catalog_state_for_skill "$catalog_root" "$skill_name") || return $?
  record_path=$(oceans_catalog_record_path "$catalog_root" "$state" "$skill_name")
  oceans_catalog_record_value "$record_path" repository
}

oceans_catalog_safe_value() {
  value=$1
  if LC_ALL=C printf '%s' "$value" | grep -q '[[:cntrl:]]'; then
    return 1
  fi
  return 0
}

oceans_catalog_write_record() {
  catalog_root=$1
  state=$2
  skill_name=$3
  repository=$4
  source_url=$5
  source_path=$6
  source_ref=$7
  source_commit=$8
  replacement=$9
  shift 9
  reason=${1:-}

  oceans_catalog_valid_state "$state" || {
    echo "Unsupported catalog state: $state" >&2
    return 1
  }

  case "$repository" in
    oceans-skills|community-skills) ;;
    *) echo "Unsupported catalog repository: $repository" >&2; return 1 ;;
  esac

  for value in "$skill_name" "$repository" "$source_url" "$source_path" "$source_ref" "$source_commit" "$replacement" "$reason"; do
    oceans_catalog_safe_value "$value" || {
      echo "Catalog values must be single-line text." >&2
      return 1
    }
  done

  state_dir=$catalog_root/$state
  mkdir -p "$state_dir"
  record_path=$(oceans_catalog_record_path "$catalog_root" "$state" "$skill_name")
  staging_path=$(mktemp "$state_dir/.${skill_name}.skill.XXXXXX") || return 1
  updated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  {
    printf 'name=%s\n' "$skill_name"
    printf 'repository=%s\n' "$repository"
    printf 'source_url=%s\n' "$source_url"
    printf 'source_path=%s\n' "$source_path"
    printf 'source_ref=%s\n' "$source_ref"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'replacement=%s\n' "$replacement"
    printf 'reason=%s\n' "$reason"
    printf 'updated_at=%s\n' "$updated_at"
  } > "$staging_path"
  mv "$staging_path" "$record_path"
}

oceans_catalog_move_record() {
  catalog_root=$1
  skill_name=$2
  target_state=$3
  replacement=${4:-}
  reason=${5:-}

  oceans_catalog_valid_state "$target_state" || {
    echo "Unsupported catalog state: $target_state" >&2
    return 1
  }

  current_state=$(oceans_catalog_state_for_skill "$catalog_root" "$skill_name") || {
    status=$?
    if [ "$status" -eq 1 ]; then
      echo "catalog-skill-not-found: $skill_name" >&2
    else
      echo "catalog-duplicate-state: $skill_name" >&2
    fi
    return 1
  }
  current_record=$(oceans_catalog_record_path "$catalog_root" "$current_state" "$skill_name")

  repository=$(oceans_catalog_record_value "$current_record" repository)
  source_url=$(oceans_catalog_record_value "$current_record" source_url)
  source_path=$(oceans_catalog_record_value "$current_record" source_path)
  source_ref=$(oceans_catalog_record_value "$current_record" source_ref)
  source_commit=$(oceans_catalog_record_value "$current_record" source_commit)
  current_replacement=$(oceans_catalog_record_value "$current_record" replacement || true)
  current_reason=$(oceans_catalog_record_value "$current_record" reason || true)

  [ -n "$replacement" ] || replacement=$current_replacement
  [ -n "$reason" ] || reason=$current_reason

  oceans_catalog_write_record "$catalog_root" "$target_state" "$skill_name" "$repository" \
    "$source_url" "$source_path" "$source_ref" "$source_commit" "$replacement" "$reason"

  target_record=$(oceans_catalog_record_path "$catalog_root" "$target_state" "$skill_name")
  if [ "$current_record" != "$target_record" ]; then
    rm -f "$current_record"
  fi
}

oceans_catalog_validation_issues() {
  catalog_root=$1
  first_party_skills_root=$2
  community_skills_root=$3

  if [ ! -d "$catalog_root" ]; then
    echo "Missing catalog root: $catalog_root"
    return
  fi

  for state in $OCEANS_CATALOG_STATES; do
    state_dir=$catalog_root/$state
    if [ ! -d "$state_dir" ]; then
      echo "Missing catalog state directory: $state_dir"
      continue
    fi

    for record_path in "$state_dir"/*.skill; do
      [ -f "$record_path" ] || continue
      record_file=${record_path##*/}
      skill_name=${record_file%.skill}
      name=$(oceans_catalog_record_value "$record_path" name || true)
      repository=$(oceans_catalog_record_value "$record_path" repository || true)
      source_url=$(oceans_catalog_record_value "$record_path" source_url || true)
      source_path=$(oceans_catalog_record_value "$record_path" source_path || true)
      source_ref=$(oceans_catalog_record_value "$record_path" source_ref || true)
      source_commit=$(oceans_catalog_record_value "$record_path" source_commit || true)
      reason=$(oceans_catalog_record_value "$record_path" reason || true)

      [ "$name" = "$skill_name" ] || echo "Catalog name mismatch in $state: $skill_name"
      case "$repository" in
        oceans-skills) repository_root=$first_party_skills_root ;;
        community-skills) repository_root=$community_skills_root ;;
        *) echo "Unsupported catalog repository for $skill_name: $repository"; repository_root= ;;
      esac
      case "$source_url" in
        https://github.com/*) ;;
        *) echo "Invalid catalog source_url for $skill_name" ;;
      esac
      [ "$source_path" = "skills/$skill_name" ] || echo "Invalid catalog source_path for $skill_name: $source_path"
      [ -n "$source_ref" ] || echo "Missing catalog source_ref for $skill_name"
      case "$source_commit" in
        ''|*[!0-9a-f]*) echo "Invalid catalog source_commit for $skill_name" ;;
        *) [ "${#source_commit}" -eq 40 ] || echo "Invalid catalog source_commit for $skill_name" ;;
      esac
      if { [ "$state" = "archived" ] || [ "$state" = "blocked" ]; } && [ -z "$reason" ]; then
        echo "Missing lifecycle reason for $state skill: $skill_name"
      fi
      if [ -n "$repository_root" ] && [ ! -d "$repository_root/$skill_name" ]; then
        echo "Catalog record points to a missing skill: $repository/$skill_name"
      fi

      states=$(oceans_catalog_states_for_skill "$catalog_root" "$skill_name")
      state_count=$(printf '%s\n' "$states" | awk 'NF { count++ } END { print count + 0 }')
      [ "$state_count" -eq 1 ] || echo "Skill exists in multiple catalog states: $skill_name"
    done
  done

  for repository_entry in "oceans-skills|$first_party_skills_root" "community-skills|$community_skills_root"; do
    repository=${repository_entry%%|*}
    skills_root=${repository_entry#*|}
    [ -d "$skills_root" ] || continue
    for skill_path in "$skills_root"/*; do
      [ -d "$skill_path" ] || continue
      skill_name=${skill_path##*/}
      if state=$(oceans_catalog_state_for_skill "$catalog_root" "$skill_name"); then
        status=0
      else
        status=$?
      fi
      if [ "$status" -eq 1 ]; then
        echo "Skill is missing from catalog: $repository/$skill_name"
        continue
      fi
      if [ "$status" -eq 2 ]; then
        echo "Skill exists in multiple catalog states: $skill_name"
        continue
      fi
      record_path=$(oceans_catalog_record_path "$catalog_root" "$state" "$skill_name")
      record_repository=$(oceans_catalog_record_value "$record_path" repository || true)
      [ "$record_repository" = "$repository" ] || echo "Catalog repository mismatch for $skill_name: $record_repository"
    done
  done
}
