#!/bin/sh
set -eu

format_git_command() {
  printf 'git'
  for arg in "$@"; do
    printf ' %s' "$arg"
  done
}

require_command() {
  if [ "$#" -lt 2 ]; then
    echo "require_command needs a command name and an error message." >&2
    return 2
  fi

  command_name=$1
  message=$2

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$message" >&2
    exit 1
  fi
}

invoke_git() {
  if [ "$#" -lt 2 ]; then
    echo "invoke_git needs a description and a Git command." >&2
    return 2
  fi

  description=$1
  shift

  set +e
  git "$@"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    command_text=$(format_git_command "$@")
    echo "$description failed: $command_text exited with code $status." >&2
    return "$status"
  fi
}

invoke_git_with_retry() {
  if [ "$#" -lt 4 ]; then
    echo "invoke_git_with_retry needs a description, attempts, delay, and a Git command." >&2
    return 2
  fi

  description=$1
  attempts=$2
  delay_seconds=$3
  shift 3
  attempt=1
  status=0

  while [ "$attempt" -le "$attempts" ]; do
    set +e
    git "$@"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
      return 0
    fi

    if [ "$attempt" -lt "$attempts" ]; then
      echo "Warning: $description failed with exit code $status. Retrying in $delay_seconds seconds ($attempt/$attempts)..." >&2
      sleep "$delay_seconds"
    fi

    attempt=$((attempt + 1))
  done

  command_text=$(format_git_command "$@")
  echo "$description failed after $attempts attempts. Last command: $command_text. Last exit code: $status. Check network and GitHub access, then rerun the same oceans777 command." >&2
  return "$status"
}
