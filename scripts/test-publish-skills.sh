#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
PUBLISH=$REPO_ROOT/scripts/publish-skills.sh
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/oceans-publish-test.XXXXXX")
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT HUP INT TERM

fail() { echo "$*" >&2; exit 1; }
assert_equal() { [ "$1" = "$2" ] || fail "$3 Expected '$2', got '$1'."; }
assert_not_equal() { [ "$1" != "$2" ] || fail "$3 Value must differ from '$2'."; }
gitq() { git "$@" >/dev/null 2>&1; }

init_bare() {
  bare=$1; seed=$2; kind=$3
  mkdir -p "$(dirname "$bare")" "$seed"
  gitq init "$seed"; gitq -C "$seed" checkout -B main
  gitq -C "$seed" config user.email test@example.invalid; gitq -C "$seed" config user.name Test; gitq -C "$seed" config core.autocrlf false
  if [ "$kind" = entry ]; then
    printf '%s\n' entry > "$seed/README.md"
    mkdir -p "$seed/catalog/skills" "$seed/catalog/review-queue/oceans-skills" "$seed/catalog/review-queue/community-skills"
    : > "$seed/catalog/skills/.gitkeep"; : > "$seed/catalog/review-queue/oceans-skills/.gitkeep"; : > "$seed/catalog/review-queue/community-skills/.gitkeep"
  else
    mkdir -p "$seed/skills"; : > "$seed/skills/.gitkeep"
  fi
  gitq -C "$seed" add .; gitq -C "$seed" commit -m initial
  gitq init --bare "$bare"; gitq -C "$seed" remote add origin "$bare"; gitq -C "$seed" push -u origin main
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
}

new_fixture() {
  name=$1
  ROOT=$SANDBOX/$name; REMOTE=$ROOT/remote; SEED=$ROOT/seed; WORK=$ROOT/work
  ENTRY_REMOTE=$REMOTE/entry.git; FIRST_REMOTE=$REMOTE/oceans.git; COMMUNITY_REMOTE=$REMOTE/community.git
  init_bare "$ENTRY_REMOTE" "$SEED/entry" entry
  init_bare "$FIRST_REMOTE" "$SEED/oceans" child
  init_bare "$COMMUNITY_REMOTE" "$SEED/community" child
  mkdir -p "$WORK"
  gitq clone "$ENTRY_REMOTE" "$WORK/entry"
  ENTRY=$WORK/entry
  gitq -C "$ENTRY" config user.email test@example.invalid; gitq -C "$ENTRY" config user.name Test; gitq -C "$ENTRY" config core.autocrlf false
  git -C "$ENTRY" -c protocol.file.allow=always submodule add -b main "$FIRST_REMOTE" repos/oceans-skills >/dev/null 2>&1
  git -C "$ENTRY" -c protocol.file.allow=always submodule add -b main "$COMMUNITY_REMOTE" repos/community-skills >/dev/null 2>&1
  gitq -C "$ENTRY" add .; gitq -C "$ENTRY" commit -m submodules; gitq -C "$ENTRY" push origin main
  FIRST=$ENTRY/repos/oceans-skills; COMMUNITY=$ENTRY/repos/community-skills
  for repo in "$FIRST" "$COMMUNITY"; do gitq -C "$repo" config user.email test@example.invalid; gitq -C "$repo" config user.name Test; gitq -C "$repo" config core.autocrlf false; done
  ENTRY_BASE=$(git -C "$ENTRY" rev-parse HEAD)
  FIRST_BASE=$(git -C "$FIRST" rev-parse HEAD)
}

write_active_change() {
  name=$1; version=$2
  mkdir -p "$FIRST/skills/$name"
  cat > "$FIRST/skills/$name/SKILL.md" <<EOF_SKILL
---
name: $name
description: Publish fixture.
---
version=$version
EOF_SKILL
  cat > "$ENTRY/catalog/skills/$name.skill" <<EOF_RECORD
schema_version=2
name=$name
status=active
package_repository=oceans-skills
upstream_repository=https://github.com/example/upstream
upstream_path=skills/$name
upstream_ref=main
upstream_commit=0123456789012345678901234567890123456789
candidate_upstream_repository=
candidate_upstream_path=
candidate_upstream_ref=
candidate_upstream_commit=
replacement=
status_reason=
transition_note=publish fixture
updated_at=2026-07-23T00:00:00Z
EOF_RECORD
}

run_publish() {
  expected=$1; shift
  home=$ROOT/home; mkdir -p "$home/.config"
  set +e
  OUTPUT=$(cd "$ENTRY" && HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" GIT_CONFIG_GLOBAL="$home/.gitconfig" GIT_TERMINAL_PROMPT=0 sh "$PUBLISH" --repo-root "$ENTRY" --first-party-repo "$FIRST" --community-repo "$COMMUNITY" "$@" 2>&1)
  CODE=$?
  set -e
  if [ "$expected" = success ]; then [ "$CODE" -eq 0 ] || { echo "$OUTPUT" >&2; fail "Publish failed."; }
  else [ "$CODE" -ne 0 ] || fail "Publish unexpectedly succeeded."; fi
}

remote_head() { git --git-dir="$1" rev-parse refs/heads/main; }
entry_pointer() { git --git-dir="$ENTRY_REMOTE" ls-tree refs/heads/main "$1" | awk '{print $3}'; }
entry_has_path() { git --git-dir="$ENTRY_REMOTE" cat-file -e "refs/heads/main:$1" 2>/dev/null; }

# No changes is a no-op.
new_fixture no-changes
run_publish success
assert_equal "$(git -C "$ENTRY" rev-parse HEAD)" "$ENTRY_BASE" "No-op changed entry."
assert_equal "$(git -C "$FIRST" rev-parse HEAD)" "$FIRST_BASE" "No-op changed child."
case "$OUTPUT" in *publish-no-changes*) ;; *) fail "No-op did not report publish-no-changes." ;; esac

# Child package and catalog are published behind one entry commit.
new_fixture coherent-success
write_active_change coherent-skill one
run_publish success
CHILD_HEAD=$(remote_head "$FIRST_REMOTE")
ENTRY_HEAD=$(remote_head "$ENTRY_REMOTE")
assert_not_equal "$CHILD_HEAD" "$FIRST_BASE" "Child was not published."
assert_not_equal "$ENTRY_HEAD" "$ENTRY_BASE" "Entry was not published."
assert_equal "$(entry_pointer repos/oceans-skills)" "$CHILD_HEAD" "Entry pointer does not reference child commit."
entry_has_path catalog/skills/coherent-skill.skill || fail "Catalog record is missing from visible entry commit."

# If the final entry push fails, remote users remain on the old coherent entry state.
new_fixture entry-push-failure
write_active_change retry-skill one
mkdir -p "$ENTRY_REMOTE/hooks"
cat > "$ENTRY_REMOTE/hooks/pre-receive" <<'EOF_HOOK'
#!/bin/sh
exit 1
EOF_HOOK
chmod +x "$ENTRY_REMOTE/hooks/pre-receive"
run_publish failure
CHILD_AFTER_FAILURE=$(remote_head "$FIRST_REMOTE")
ENTRY_AFTER_FAILURE=$(remote_head "$ENTRY_REMOTE")
assert_not_equal "$CHILD_AFTER_FAILURE" "$FIRST_BASE" "Child commit should be pushed before final entry failure."
assert_equal "$ENTRY_AFTER_FAILURE" "$ENTRY_BASE" "Entry main changed despite rejected final push."
[ "$(entry_pointer repos/oceans-skills)" != "$CHILD_AFTER_FAILURE" ] || fail "Old entry unexpectedly references orphan child commit."
if entry_has_path catalog/skills/retry-skill.skill; then fail "Catalog became visible without matching entry release."; fi
rm -f "$ENTRY_REMOTE/hooks/pre-receive"
run_publish success
assert_equal "$(remote_head "$ENTRY_REMOTE")" "$(git -C "$ENTRY" rev-parse HEAD)" "Retry did not publish prepared entry commit."
assert_equal "$(entry_pointer repos/oceans-skills)" "$CHILD_AFTER_FAILURE" "Retry entry pointer is wrong."
entry_has_path catalog/skills/retry-skill.skill || fail "Retry did not publish catalog."

# Invalid package/catalog pairing is rejected before any remote moves.
new_fixture validation-failure
mkdir -p "$FIRST/skills/orphan-skill"
printf '%s\n' '---' 'name: orphan-skill' 'description: Orphan.' '---' > "$FIRST/skills/orphan-skill/SKILL.md"
run_publish failure
assert_equal "$(remote_head "$FIRST_REMOTE")" "$FIRST_BASE" "Validation failure pushed child."
assert_equal "$(remote_head "$ENTRY_REMOTE")" "$ENTRY_BASE" "Validation failure pushed entry."

# Dry-run reports order without creating commits.
new_fixture dry-run
write_active_change dry-skill one
run_publish success --dry-run
assert_equal "$(git -C "$FIRST" rev-parse HEAD)" "$FIRST_BASE" "Dry-run committed child."
assert_equal "$(git -C "$ENTRY" rev-parse HEAD)" "$ENTRY_BASE" "Dry-run committed entry."
case "$OUTPUT" in *plan-push-entry-last*) ;; *) fail "Dry-run did not document entry-last order." ;; esac

echo "Shell publish skills test passed."
