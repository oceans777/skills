if ! command -v oceans_find_included_skill_files >/dev/null 2>&1; then
  . "$(CDPATH= cd "$(dirname "$0")" && pwd)/skill-publish-rules.sh"
fi

oceans_sha256_file() {
  file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print tolower($1) }'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{ print tolower($1) }'
    return
  fi
  echo "No SHA-256 implementation is available." >&2
  return 1
}

# Skill packages are text-only and are invoked through an explicit interpreter.
# Canonical permissions remove executable-bit drift without making the package
# fingerprint platform-dependent.
oceans_normalize_skill_permissions() {
  skill_path=$1
  [ -d "$skill_path" ] && [ ! -L "$skill_path" ] || {
    echo "Cannot normalize unsafe skill directory: $skill_path" >&2
    return 1
  }
  find "$skill_path" -type d -exec chmod 755 {} + || return 1
  find "$skill_path" -type f -exec chmod 644 {} + || return 1
}

oceans_skill_content_sha256() {
  skill_path=$1
  root=$(CDPATH= cd "$skill_path" && pwd -P) || return 1
  manifest=$(mktemp "${TMPDIR:-/tmp}/oceans-skill-manifest.XXXXXX") || return 1
  unsorted=$(mktemp "${TMPDIR:-/tmp}/oceans-skill-manifest-unsorted.XXXXXX") || { rm -f "$manifest"; return 1; }
  files=$(mktemp "${TMPDIR:-/tmp}/oceans-skill-files.XXXXXX") || { rm -f "$manifest" "$unsorted"; return 1; }

  if ! oceans_find_included_skill_files "$root" > "$files"; then
    rm -f "$manifest" "$unsorted" "$files"
    return 1
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    relative=${file#"$root"/}
    path_hex=$(printf '%s' "$relative" | od -An -tx1 | tr -d ' \n')
    file_hash=$(oceans_sha256_file "$file") || { rm -f "$manifest" "$unsorted" "$files"; return 1; }
    printf '%s %s\n' "$path_hex" "$file_hash" >> "$unsorted"
  done < "$files"
  LC_ALL=C sort "$unsorted" > "$manifest"
  digest=$(oceans_sha256_file "$manifest") || { rm -f "$manifest" "$unsorted" "$files"; return 1; }
  rm -f "$manifest" "$unsorted" "$files"
  printf '%s\n' "$digest"
}

oceans_valid_sha256() {
  value=$1
  case "$value" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#value}" -eq 64 ]
}
