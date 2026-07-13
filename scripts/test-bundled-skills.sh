#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-bundled-skills-test.XXXXXX")
SANDBOX_ROOT=$(CDPATH= cd "$SANDBOX_ROOT" && pwd -P)
AOS_ROOT=$REPO_ROOT/repos/oceans-skills/skills/agent-operating-system
UIUX_ROOT=$REPO_ROOT/repos/community-skills/skills/ui-ux-pro-max

cleanup() {
  rm -rf "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

test -f "$AOS_ROOT/scripts/bootstrap-agent-os.sh"
test -f "$AOS_ROOT/scripts/start-agent-task.sh"
test -f "$UIUX_ROOT/scripts/search.py"

REMOTE_ROOT=$SANDBOX_ROOT/origin.git
PROJECT_ROOT=$SANDBOX_ROOT/project
WORKTREE_ROOT=$SANDBOX_ROOT/worktrees

git init --bare --initial-branch=main "$REMOTE_ROOT" >/dev/null
git init -b main "$PROJECT_ROOT" >/dev/null
git -C "$PROJECT_ROOT" config user.name "Oceans Skills Test"
git -C "$PROJECT_ROOT" config user.email "skills-test@example.invalid"
printf '%s\n' '# Test project' > "$PROJECT_ROOT/README.md"
git -C "$PROJECT_ROOT" add README.md
git -C "$PROJECT_ROOT" commit -m "test: initialize repository" >/dev/null
git -C "$PROJECT_ROOT" remote add origin "$REMOTE_ROOT"
git -C "$PROJECT_ROOT" push -u origin main >/dev/null
git --git-dir="$REMOTE_ROOT" symbolic-ref HEAD refs/heads/main

if (cd "$PROJECT_ROOT" && sh "$AOS_ROOT/scripts/agent-standards-hook.sh" pre-commit >/dev/null 2>&1); then
  echo 'Expected read-only guard to reject a missing AGENTS.md.' >&2
  exit 1
fi
if [ -e "$PROJECT_ROOT/AGENTS.md" ]; then
  echo 'Guard must not create AGENTS.md as a pre-commit side effect.' >&2
  exit 1
fi

sh "$AOS_ROOT/scripts/bootstrap-agent-os.sh" --project-root "$PROJECT_ROOT" >/dev/null
test -f "$PROJECT_ROOT/AGENTS.md"
test -x "$PROJECT_ROOT/scripts/agent-bootstrap.sh"
if grep -q 'yes长官' "$PROJECT_ROOT/AGENTS.md"; then
  echo "Generated AGENTS.md contains a personal response rule." >&2
  exit 1
fi
git -C "$PROJECT_ROOT" add AGENTS.md
(cd "$PROJECT_ROOT" && sh "$AOS_ROOT/scripts/agent-standards-hook.sh" pre-commit >/dev/null)

if sh "$AOS_ROOT/scripts/start-agent-task.sh" \
  --project-root "$PROJECT_ROOT" \
  --task-name invalid-ignore \
  --branch-name 'bad..branch' \
  --ensure-ignore >/dev/null 2>&1; then
  echo 'Expected invalid branch name to be rejected.' >&2
  exit 1
fi
if [ -e "$PROJECT_ROOT/.gitignore" ]; then
  echo 'Failed task setup must not create .gitignore.' >&2
  exit 1
fi

if sh "$AOS_ROOT/scripts/start-agent-task.sh" \
  --project-root "$PROJECT_ROOT" \
  --task-name escaped-ignore \
  --branch-name codex/escaped-ignore \
  --worktree-dir ../escaped-worktrees \
  --no-fetch \
  --ensure-ignore >/dev/null 2>&1; then
  echo 'Expected escaped ensure-ignore path to be rejected.' >&2
  exit 1
fi
if [ -e "$PROJECT_ROOT/.gitignore" ]; then
  echo 'Escaped task setup must not create .gitignore.' >&2
  exit 1
fi

(cd "$PROJECT_ROOT" && sh scripts/agent-bootstrap.sh --skip-verify >/dev/null)
sh "$AOS_ROOT/scripts/start-agent-task.sh" \
  --project-root "$PROJECT_ROOT" \
  --task-name bundled-skill-smoke \
  --branch-name codex/bundled-skill-smoke \
  --worktree-dir "$WORKTREE_ROOT" >/dev/null
test "$(git -C "$WORKTREE_ROOT/bundled-skill-smoke" branch --show-current)" = "codex/bundled-skill-smoke"

SEARCH_OUTPUT=$(python3 "$UIUX_ROOT/scripts/search.py" "button spacing contrast" --domain ux -n 1)
test -n "$SEARCH_OUTPUT"
if python3 "$UIUX_ROOT/scripts/search.py" "dashboard" -n -1 >/dev/null 2>&1; then
  echo 'Expected negative max-results to be rejected.' >&2
  exit 1
fi
python3 -m unittest discover -s "$UIUX_ROOT/tests" >/dev/null

printf 'Bundled skill smoke tests passed.\n'
