oceans_secret_pattern='(api[_-]?key[[:space:]]*[:=]|secret[[:space:]]*[:=]|token[[:space:]]*[:=]|password[[:space:]]*[:=]|authorization[[:space:]]*:?[[:space:]]*bearer|sk-[a-zA-Z0-9_-]{10,})'
oceans_local_path_pattern='(^|[^A-Za-z0-9_])(/Users/[^/]+(/|$)|/home/[^/]+(/|$)|[A-Za-z]:[\\/][Uu]sers[\\/][^\\/]+([\\/]|$)|/private/(var|tmp|etc)(/|$))'

oceans_valid_skill_name() {
  name=$1
  case "$name" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|""|-*|*-|*--*)
      return 1
      ;;
  esac

  [ "${#name}" -le 64 ] || return 1

  return 0
}

oceans_is_valid_utf8() {
  file=$1

  if command -v perl >/dev/null 2>&1; then
    perl -MEncode=decode -0777 -ne 'index($_, "\0") < 0 or exit 1; eval { decode("UTF-8", $_, 1); 1 } or exit 1' "$file" 2>/dev/null
    return
  fi

  if command -v iconv >/dev/null 2>&1; then
    original_size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]') || return 1
    without_nul_size=$(LC_ALL=C tr -d '\000' < "$file" 2>/dev/null | wc -c | tr -d '[:space:]') || return 1
    [ "$original_size" = "$without_nul_size" ] || return 1
    utf8_output=$(mktemp "${TMPDIR:-/tmp}/oceans-utf8-check.XXXXXX") || return 1
    if iconv -f UTF-8 -t UTF-8 "$file" > "$utf8_output" 2>/dev/null; then
      rm -f "$utf8_output"
      return 0
    fi
    rm -f "$utf8_output"
    return 1
  fi

  # grep -Iq above still rejects NUL bytes. Without a strict decoder available,
  # fail closed rather than claiming arbitrary byte sequences are safe text.
  return 1
}

oceans_is_excluded_relative_path() {
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

oceans_frontmatter_value() {
  skill_path=$1
  key=$2
  skill_file=$skill_path/SKILL.md

  [ -f "$skill_file" ] || return 1

  awk -v key="$key" '
    {
      sub(/\r$/, "")
    }
    NR == 1 {
      if ($0 != "---") {
        exit 2
      }
      next
    }
    in_block && $0 == "---" {
      exit 0
    }
    in_block {
      if ($0 ~ /^[^ \t][A-Za-z0-9_-]*[ \t]*:/) {
        exit 0
      }
      line = $0
      sub(/^[ \t]*/, "", line)
      sub(/[ \t]*$/, "", line)
      if (line != "") {
        print line
        exit 0
      }
      next
    }
    $0 == "---" {
      exit 0
    }
    {
      if ($0 ~ /^[ \t]/) {
        next
      }
      line = $0
      sub(/^[ \t]*/, "", line)
      match_line = tolower(line)
      pattern = "^" key "[ \t]*:"
      if (match_line ~ pattern) {
        sub(/^[^:]*:[ \t]*/, "", line)
        gsub(/^[ \t]+/, "", line)
        gsub(/[ \t]+$/, "", line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == "'"'"'" && substr(line, length(line), 1) == "'"'"'")) {
          line = substr(line, 2, length(line) - 2)
        }
        if (line ~ /^[|>][-+]?[0-9]*$/) {
          in_block = 1
          next
        }
        print line
        exit 0
      }
    }
  ' "$skill_file"
}

oceans_has_frontmatter() {
  skill_path=$1
  skill_file=$skill_path/SKILL.md

  [ -f "$skill_file" ] || return 1
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit 1; next }
    $0 == "---" { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$skill_file"
}

oceans_frontmatter_structure_issues() {
  skill_path=$1
  skill_file=$skill_path/SKILL.md
  [ -f "$skill_file" ] || return 0

  awk '
    BEGIN {
      allowed["name"] = allowed["description"] = allowed["license"] = 1
      allowed["allowed-tools"] = allowed["metadata"] = 1
    }
    { sub(/\r$/, "") }
    NR == 1 { next }
    $0 == "---" { exit }
    /^[^ \t][A-Za-z0-9_-]*[ \t]*:/ {
      line = $0
      sub(/[ \t]*:.*/, "", line)
      key = tolower(line)
      if (++seen[key] > 1) print "risk: duplicate frontmatter key: " key
      if (!allowed[key]) print "risk: unsupported frontmatter key: " key
    }
  ' "$skill_file"
}

oceans_skill_metadata_issues() {
  skill_path=$1
  expected_name=$2

  if ! oceans_valid_skill_name "$expected_name"; then
    echo "risk: invalid skill folder name"
  fi

  [ -f "$skill_path/SKILL.md" ] || return 0

  if ! oceans_has_frontmatter "$skill_path"; then
    echo "risk: missing or unterminated skill frontmatter"
    return 0
  fi

  oceans_frontmatter_structure_issues "$skill_path"

  skill_name=$(oceans_frontmatter_value "$skill_path" name || true)
  if [ -z "$skill_name" ]; then
    echo "risk: missing skill name"
  else
    if ! oceans_valid_skill_name "$skill_name"; then
      echo "risk: invalid skill name"
    fi
    if [ "$skill_name" != "$expected_name" ]; then
      echo "risk: skill name does not match folder name"
    fi
  fi

  description=$(oceans_frontmatter_value "$skill_path" description || true)
  if [ -z "$description" ]; then
    echo "risk: missing skill description"
  elif [ "${#description}" -gt 1024 ]; then
    echo "risk: skill description is too long"
  elif printf '%s' "$description" | grep -q '[<>]'; then
    echo "risk: skill description contains angle brackets"
  fi
}

oceans_missing_license_reference() {
  skill_path=$1

  if ! oceans_has_frontmatter "$skill_path"; then
    return 1
  fi

  license_value=$(oceans_frontmatter_value "$skill_path" license || true)
  [ -n "$license_value" ] || return 1

  references=$(printf '%s\n' "$license_value" | grep -E -o 'LICENSE([.][A-Za-z0-9._-]+)?' || true)
  [ -n "$references" ] || return 1

  old_ifs=$IFS
  IFS='
'
  for reference in $references; do
    if [ ! -f "$skill_path/$reference" ]; then
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs

  return 1
}

oceans_find_included_skill_files() {
  skill_path=$1

  find "$skill_path" \
    \( -name .git -o \
       -name .oceans-skill-source -o \
       -name .DS_Store -o \
       -name Thumbs.db -o \
       -name .pytest_cache -o \
       -name __pycache__ -o \
       -name node_modules \) -prune -o \
    -type f -print
}

oceans_skill_path_issues() {
  skill_path=$1
  find "$skill_path" -mindepth 1 -exec sh -c '
    root=$1
    shift
    for path do
      rel=${path#"$root"/}
      case "$rel" in
        *"|"*) echo "risk: unsafe filesystem path"; continue ;;
      esac
      newline_count=$(printf "%s" "$rel" | wc -l | tr -d "[:space:]")
      if [ "$newline_count" -ne 0 ] || printf "%s" "$rel" | LC_ALL=C grep -q "[[:cntrl:]]"; then
        echo "risk: unsafe filesystem path"
      fi
    done
  ' sh "$skill_path" {} + | awk 'NF && !seen[$0]++'
}

oceans_scan_skill_risks() {
  skill_path=$1

  path_issues=$(oceans_skill_path_issues "$skill_path")
  if [ -n "$path_issues" ]; then
    printf '%s\n' "$path_issues"
    return
  fi

  {
    if oceans_missing_license_reference "$skill_path"; then
      echo "risk: missing referenced license file"
    fi

    oceans_find_included_skill_files "$skill_path" | while IFS= read -r file; do
      rel=${file#"$skill_path"/}
      if oceans_is_excluded_relative_path "$rel"; then
        continue
      fi

      if ! size_output=$(wc -c < "$file" 2>/dev/null); then
        echo "risk: binary or unreadable file"
        continue
      fi

      size=$(printf '%s' "$size_output" | tr -d ' ')
      case "$size" in
        ""|*[!0123456789]*)
          echo "risk: binary or unreadable file"
          continue
          ;;
      esac

      if [ "$size" -gt 1048576 ]; then
        echo "risk: file larger than 1 MB"
        continue
      fi

      if ! oceans_is_valid_utf8 "$file"; then
        echo "risk: binary or unreadable file"
        continue
      fi

      if grep -E -i -q "$oceans_secret_pattern" "$file" 2>/dev/null; then
        echo "risk: secret-like text"
      else
        grep_status=$?
        if [ "$grep_status" -gt 1 ]; then
          echo "risk: binary or unreadable file"
          continue
        fi
      fi

      if grep -E -q "$oceans_local_path_pattern" "$file" 2>/dev/null; then
        echo "risk: local absolute path"
      else
        grep_status=$?
        if [ "$grep_status" -gt 1 ]; then
          echo "risk: binary or unreadable file"
          continue
        fi
      fi
    done
  } | awk 'NF && !seen[$0]++'
}
