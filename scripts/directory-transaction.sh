#!/bin/sh

# Directory replacement primitives shared by installers and staging commands.
# The caller prepares a complete sibling directory, then commits it with one
# rename. Existing content is kept as a rollback backup until the rename wins.

oceans_new_staging_directory() {
  oceans_transaction_target=$1
  oceans_transaction_parent=$(dirname "$oceans_transaction_target")
  oceans_transaction_name=$(basename "$oceans_transaction_target")

  [ -d "$oceans_transaction_parent" ] || mkdir -p "$oceans_transaction_parent"
  mktemp -d "$oceans_transaction_parent/.${oceans_transaction_name}.oceans-stage.XXXXXX"
}

oceans_remove_excluded_paths() {
  oceans_transaction_root=$1
  find "$oceans_transaction_root" -depth \
    \( -name .git -o -name .oceans-skill-source -o -name .DS_Store -o \
       -name Thumbs.db -o -name .pytest_cache -o -name __pycache__ -o \
       -name node_modules \) -exec rm -rf {} +
}

oceans_commit_staged_directory() (
  oceans_transaction_staged=$1
  oceans_transaction_target=$2
  oceans_transaction_parent=$(dirname "$oceans_transaction_target")
  oceans_transaction_name=$(basename "$oceans_transaction_target")
  oceans_transaction_backup=$oceans_transaction_parent/.${oceans_transaction_name}.oceans-backup
  oceans_transaction_lock=$oceans_transaction_parent/.${oceans_transaction_name}.oceans-lock

  oceans_release_transaction() {
    if [ -e "$oceans_transaction_backup" ] && [ ! -e "$oceans_transaction_target" ]; then
      if [ -L "$oceans_transaction_backup" ]; then
        echo "CRITICAL: refusing to restore unsafe backup: $oceans_transaction_backup" >&2
      else
        mv "$oceans_transaction_backup" "$oceans_transaction_target" || \
          echo "CRITICAL: failed to restore directory backup: $oceans_transaction_backup" >&2
      fi
    fi
    if [ -d "$oceans_transaction_lock" ] && [ ! -L "$oceans_transaction_lock" ]; then
      rm -rf "$oceans_transaction_lock"
    fi
  }

  if [ ! -d "$oceans_transaction_staged" ] || [ -L "$oceans_transaction_staged" ]; then
    echo "Invalid staged directory: $oceans_transaction_staged" >&2
    return 1
  fi

  case "$oceans_transaction_staged" in
    "$oceans_transaction_parent"/.*.oceans-stage.*) ;;
    *)
      echo "Staged directory must be a sibling of its target: $oceans_transaction_staged" >&2
      return 1
      ;;
  esac

  if [ -L "$oceans_transaction_target" ]; then
    echo "Refusing to replace a symlink target: $oceans_transaction_target" >&2
    return 1
  fi

  if ! mkdir "$oceans_transaction_lock" 2>/dev/null; then
    if [ -L "$oceans_transaction_lock" ] || [ ! -d "$oceans_transaction_lock" ]; then
      echo "Refusing unsafe transaction lock: $oceans_transaction_lock" >&2
      return 1
    fi
    oceans_lock_pid=$(sed -n '1p' "$oceans_transaction_lock/pid" 2>/dev/null || true)
    case "$oceans_lock_pid" in
      ''|*[!0-9]*) oceans_lock_active=1 ;;
      *) if kill -0 "$oceans_lock_pid" 2>/dev/null; then oceans_lock_active=1; else oceans_lock_active=0; fi ;;
    esac
    if [ "$oceans_lock_active" -eq 1 ]; then
      echo "Another directory transaction is active: $oceans_transaction_target" >&2
      return 1
    fi
    rm -rf "$oceans_transaction_lock"
    mkdir "$oceans_transaction_lock" || return 1
  fi
  printf '%s\n' "$$" > "$oceans_transaction_lock/pid"
  trap 'oceans_release_transaction; exit 129' HUP
  trap 'oceans_release_transaction; exit 130' INT
  trap 'oceans_release_transaction; exit 143' TERM
  trap 'oceans_release_transaction' EXIT

  if [ -e "$oceans_transaction_backup" ]; then
    if [ -L "$oceans_transaction_backup" ]; then
      echo "Refusing unsafe transaction backup: $oceans_transaction_backup" >&2
      return 1
    fi
    if [ -e "$oceans_transaction_target" ]; then
      rm -rf "$oceans_transaction_backup"
    else
      mv "$oceans_transaction_backup" "$oceans_transaction_target" || return 1
    fi
  fi

  if [ -e "$oceans_transaction_target" ]; then
    if ! mv "$oceans_transaction_target" "$oceans_transaction_backup"; then
      return 1
    fi
  fi

  if mv "$oceans_transaction_staged" "$oceans_transaction_target"; then
    if [ -e "$oceans_transaction_backup" ]; then
      rm -rf "$oceans_transaction_backup"
    fi
    rm -rf "$oceans_transaction_lock"
    oceans_transaction_lock=
    oceans_transaction_backup=
    return 0
  fi

  if [ -e "$oceans_transaction_backup" ] && [ ! -e "$oceans_transaction_target" ]; then
    mv "$oceans_transaction_backup" "$oceans_transaction_target" || {
      echo "CRITICAL: failed to restore directory backup: $oceans_transaction_backup" >&2
      return 1
    }
  fi
  return 1
)
