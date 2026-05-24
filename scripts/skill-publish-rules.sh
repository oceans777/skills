oceans_secret_pattern='(api[_-]?key[[:space:]]*[:=]|secret[[:space:]]*[:=]|token[[:space:]]*[:=]|password[[:space:]]*[:=]|authorization[[:space:]]*:?[[:space:]]*bearer|sk-[a-zA-Z0-9_-]{10,})'
oceans_local_path_pattern='(^|[^A-Za-z0-9_])(/Users/[^/]+(/|$)|/home/[^/]+(/|$)|[A-Za-z]:[\\/][Uu]sers[\\/][^\\/]+([\\/]|$)|/private/(var|tmp|etc)(/|$))'

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

oceans_missing_license_reference() {
  skill_path=$1
  skill_file=$skill_path/SKILL.md

  [ -f "$skill_file" ] || return 1

  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))

    if [ "$line_number" -eq 1 ]; then
      [ "$line" = "---" ] || return 1
      continue
    fi

    [ "$line" = "---" ] && break

    if printf '%s\n' "$line" | grep -E -i -q '^[[:space:]]*license[[:space:]]*:'; then
      references=$(printf '%s\n' "$line" | grep -E -o 'LICENSE([.][A-Za-z0-9._-]+)?' || true)
      [ -n "$references" ] || continue

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
    fi
  done < "$skill_file"

  return 1
}

oceans_scan_skill_risks() {
  skill_path=$1

  {
    if oceans_missing_license_reference "$skill_path"; then
      echo "risk: missing referenced license file"
    fi

    find "$skill_path" -type f | while IFS= read -r file; do
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

      if ! LC_ALL=C grep -Iq . "$file" 2>/dev/null && [ "$size" -gt 0 ]; then
        echo "risk: binary or unreadable file"
        continue
      fi

      if command -v perl >/dev/null 2>&1 &&
         ! perl -MEncode=decode -0777 -ne 'eval { decode("UTF-8", $_, 1); 1 } or exit 1' "$file" 2>/dev/null; then
        echo "risk: binary or unreadable file"
        continue
      fi

      if command -v iconv >/dev/null 2>&1 &&
         ! iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1; then
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
