#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oceans-stage-test.XXXXXX")

assert_contains() {
  text=$1
  expected=$2

  case "$text" in
    *"$expected"*)
      ;;
    *)
      echo "Expected output to contain: $expected" >&2
      exit 1
      ;;
  esac
}

assert_path_exists() {
  path=$1

  if [ ! -e "$path" ]; then
    echo "Expected path to exist: $path" >&2
    exit 1
  fi
}

assert_path_missing() {
  path=$1

  if [ -e "$path" ]; then
    echo "Expected path not to exist: $path" >&2
    exit 1
  fi
}

assert_file_contains() {
  path=$1
  expected=$2

  assert_path_exists "$path"
  assert_contains "$(cat "$path")" "$expected"
}

cleanup() {
  rm -rf "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

git_quiet() {
  repo_path=$1
  shift

  git -C "$repo_path" "$@" >/dev/null 2>&1
}

init_test_repository() {
  repo_path=$1

  mkdir -p "$repo_path/skills"
  git -C "$repo_path" init >/dev/null 2>&1
  git_quiet "$repo_path" checkout -q -B main
  git_quiet "$repo_path" config user.email stage-test@example.invalid
  git_quiet "$repo_path" config user.name "Stage Test"
  : > "$repo_path/skills/.gitkeep"
  git_quiet "$repo_path" add .
  git_quiet "$repo_path" commit -m initial
}

new_fixture() {
  fixture_name=$1

  FIXTURE_ROOT=$SANDBOX_ROOT/$fixture_name
  SOURCE_ROOT=$FIXTURE_ROOT/source
  FIRST_PARTY_REPO=$FIXTURE_ROOT/repo/oceans-skills
  COMMUNITY_REPO=$FIXTURE_ROOT/repo/community-skills
  FIRST_PARTY_ROOT=$FIRST_PARTY_REPO/skills
  COMMUNITY_ROOT=$COMMUNITY_REPO/skills

  mkdir -p "$SOURCE_ROOT"
  init_test_repository "$FIRST_PARTY_REPO"
  init_test_repository "$COMMUNITY_REPO"

  mkdir -p "$SOURCE_ROOT/good-skill"
  cat > "$SOURCE_ROOT/good-skill/SKILL.md" <<'EOF'
---
name: good-skill
description: Safe test skill.
---
EOF

  mkdir -p "$SOURCE_ROOT/community-skill"
  cat > "$SOURCE_ROOT/community-skill/SKILL.md" <<'EOF'
---
name: community-skill
description: Community test skill.
---
EOF
  printf '%s\n' "Example source license" > "$SOURCE_ROOT/community-skill/LICENSE.source"

  mkdir -p "$SOURCE_ROOT/risky-skill"
  cat > "$SOURCE_ROOT/risky-skill/SKILL.md" <<'EOF'
---
name: risky-skill
description: Risky test skill.
---
api_key: test-value
EOF
}

run_stage_success() {
  output=$(sh "$REPO_ROOT/scripts/stage-skill.sh" "$@")
  printf '%s' "$output"
}

run_stage_failure() {
  set +e
  output=$(sh "$REPO_ROOT/scripts/stage-skill.sh" "$@" 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "Expected stage-skill.sh to fail. Output:" >&2
    echo "$output" >&2
    exit 1
  fi

  printf '%s' "$output"
}

run_stage_success_common() {
  skill=$1
  target=$2
  shift 2

  run_stage_success \
    --source-root "$SOURCE_ROOT" \
    --skill "$skill" \
    --target "$target" \
    --first-party-root "$FIRST_PARTY_ROOT" \
    --community-root "$COMMUNITY_ROOT" \
    "$@"
}

run_stage_failure_common() {
  skill=$1
  target=$2
  shift 2

  run_stage_failure \
    --source-root "$SOURCE_ROOT" \
    --skill "$skill" \
    --target "$target" \
    --first-party-root "$FIRST_PARTY_ROOT" \
    --community-root "$COMMUNITY_ROOT" \
    "$@"
}

new_fixture success
OUTPUT=$(sh "$REPO_ROOT/scripts/stage-skill.sh" \
  --source-root "$SOURCE_ROOT" \
  --skill good-skill \
  --target oceans \
  --first-party-skills-root "$FIRST_PARTY_ROOT" \
  --community-skills-root "$COMMUNITY_ROOT")

assert_contains "$OUTPUT" "staged-skill: good-skill"
assert_contains "$OUTPUT" "target_repository: oceans-skills"
assert_contains "$OUTPUT" "risk_status: none detected"
assert_path_exists "$FIRST_PARTY_ROOT/good-skill/SKILL.md"
assert_path_missing "$FIRST_PARTY_ROOT/good-skill/.oceans-skill-source"

new_fixture runtime-source
AGENTS_HOME=$FIXTURE_ROOT/agents-home
export AGENTS_HOME
mkdir -p "$AGENTS_HOME/skills/agents-skill"
cat > "$AGENTS_HOME/skills/agents-skill/SKILL.md" <<'EOF'
---
name: agents-skill
description: Agents runtime skill.
---
EOF
OUTPUT=$(sh "$REPO_ROOT/scripts/stage-skill.sh" \
  --runtime agents \
  --skill agents-skill \
  --target oceans \
  --first-party-skills-root "$FIRST_PARTY_ROOT" \
  --community-skills-root "$COMMUNITY_ROOT")
assert_contains "$OUTPUT" "staged-skill: agents-skill"
assert_path_exists "$FIRST_PARTY_ROOT/agents-skill/SKILL.md"

new_fixture source-root-wins
AGENTS_HOME=$FIXTURE_ROOT/agents-home
export AGENTS_HOME
mkdir -p "$AGENTS_HOME/skills"
OUTPUT=$(sh "$REPO_ROOT/scripts/stage-skill.sh" \
  --source-root "$SOURCE_ROOT" \
  --runtime agents \
  --skill good-skill \
  --target oceans \
  --first-party-skills-root "$FIRST_PARTY_ROOT" \
  --community-skills-root "$COMMUNITY_ROOT")
assert_contains "$OUTPUT" "staged-skill: good-skill"
assert_path_exists "$FIRST_PARTY_ROOT/good-skill/SKILL.md"

new_fixture system-rejected
mkdir -p "$SOURCE_ROOT/.system"
cat > "$SOURCE_ROOT/.system/SKILL.md" <<'EOF'
---
name: system
description: System skill.
---
EOF
OUTPUT=$(run_stage_failure_common .system oceans)
assert_contains "$OUTPUT" "skip-system: .system"

new_fixture missing-skill-md
mkdir -p "$SOURCE_ROOT/missing-skill"
printf '%s\n' "Missing SKILL.md" > "$SOURCE_ROOT/missing-skill/README.md"
OUTPUT=$(run_stage_failure_common missing-skill oceans)
assert_contains "$OUTPUT" "missing-skill-md: missing-skill"

new_fixture secret-risk
OUTPUT=$(run_stage_failure_common risky-skill oceans)
assert_contains "$OUTPUT" "risk-blocked: risky-skill"
assert_contains "$OUTPUT" "risk: secret-like text"

new_fixture path-risk
mkdir -p "$SOURCE_ROOT/path-skill"
cat > "$SOURCE_ROOT/path-skill/SKILL.md" <<'EOF'
---
name: path-skill
description: Uses /Users/example/private-notes.
---
EOF
OUTPUT=$(run_stage_failure_common path-skill oceans)
assert_contains "$OUTPUT" "risk-blocked: path-skill"
assert_contains "$OUTPUT" "risk: local absolute path"

new_fixture large-risk
mkdir -p "$SOURCE_ROOT/large-skill"
cat > "$SOURCE_ROOT/large-skill/SKILL.md" <<'EOF'
---
name: large-skill
description: Large file skill.
---
EOF
dd if=/dev/zero of="$SOURCE_ROOT/large-skill/large.bin" bs=1048577 count=1 >/dev/null 2>&1
OUTPUT=$(run_stage_failure_common large-skill oceans)
assert_contains "$OUTPUT" "risk-blocked: large-skill"
assert_contains "$OUTPUT" "risk: file larger than 1 MB"

new_fixture binary-risk
mkdir -p "$SOURCE_ROOT/binary-skill"
cat > "$SOURCE_ROOT/binary-skill/SKILL.md" <<'EOF'
---
name: binary-skill
description: Binary file skill.
---
EOF
printf '\377\376\375' > "$SOURCE_ROOT/binary-skill/invalid.bin"
OUTPUT=$(run_stage_failure_common binary-skill oceans)
assert_contains "$OUTPUT" "risk-blocked: binary-skill"
assert_contains "$OUTPUT" "risk: binary or unreadable file"

new_fixture spaced-path-risk
mkdir -p "$SOURCE_ROOT/spaced-skill/dir with space"
cat > "$SOURCE_ROOT/spaced-skill/SKILL.md" <<'EOF'
---
name: spaced-skill
description: Risk file below a spaced path.
---
EOF
printf '%s\n' "api_key: spaced-secret" > "$SOURCE_ROOT/spaced-skill/dir with space/secret.txt"
OUTPUT=$(run_stage_failure_common spaced-skill oceans)
assert_contains "$OUTPUT" "risk-blocked: spaced-skill"
assert_contains "$OUTPUT" "risk: secret-like text"

new_fixture symlink-rejected
mkdir -p "$SOURCE_ROOT/symlink-skill"
cat > "$SOURCE_ROOT/symlink-skill/SKILL.md" <<'EOF'
---
name: symlink-skill
description: Symlink skill.
---
EOF
printf '%s\n' "api_key: external-secret" > "$FIXTURE_ROOT/external-secret.txt"
if ln -s "$FIXTURE_ROOT/external-secret.txt" "$SOURCE_ROOT/symlink-skill/secret-link.txt" 2>/dev/null &&
   [ -L "$SOURCE_ROOT/symlink-skill/secret-link.txt" ]; then
  OUTPUT=$(run_stage_failure_common symlink-skill oceans --allow-risk)
  assert_contains "$OUTPUT" "unsupported-symlink: symlink-skill"
  assert_path_missing "$FIRST_PARTY_ROOT/symlink-skill/secret-link.txt"

  new_fixture excluded-symlink
  mkdir -p "$SOURCE_ROOT/excluded-link-skill/node_modules"
  cat > "$SOURCE_ROOT/excluded-link-skill/SKILL.md" <<'EOF'
---
name: excluded-link-skill
description: Excluded symlink skill.
---
EOF
  ln -s "$FIXTURE_ROOT/external-secret.txt" "$SOURCE_ROOT/excluded-link-skill/node_modules/external-link.txt"
  OUTPUT=$(run_stage_success_common excluded-link-skill oceans)
  assert_contains "$OUTPUT" "staged-skill: excluded-link-skill"
  assert_path_exists "$FIRST_PARTY_ROOT/excluded-link-skill/SKILL.md"
  assert_path_missing "$FIRST_PARTY_ROOT/excluded-link-skill/node_modules/external-link.txt"
else
  echo "Skipping symlink stage test: symbolic links are not available in this environment."
fi

new_fixture community-missing-attribution
OUTPUT=$(run_stage_failure_common community-skill community)
assert_contains "$OUTPUT" "missing-community-attribution: community-skill"

new_fixture community-attribution
OUTPUT=$(run_stage_success_common community-skill community \
  --upstream-url https://example.invalid/community-skill \
  --upstream-author "Example Author" \
  --upstream-license MIT \
  --license-file "$SOURCE_ROOT/community-skill/LICENSE.source" \
  --patch-summary "Adjusted metadata for oceans777.")
COMMUNITY_TARGET=$COMMUNITY_ROOT/community-skill
assert_contains "$OUTPUT" "staged-skill: community-skill"
assert_file_contains "$COMMUNITY_TARGET/UPSTREAM.md" "Original repository: https://example.invalid/community-skill"
assert_file_contains "$COMMUNITY_TARGET/UPSTREAM.md" "Original author: Example Author"
assert_file_contains "$COMMUNITY_TARGET/UPSTREAM.md" "License: MIT"
assert_file_contains "$COMMUNITY_TARGET/PATCHES.md" "Adjusted metadata for oceans777."
assert_file_contains "$COMMUNITY_TARGET/LICENSE" "Example source license"

new_fixture community-partial-attribution
printf '%s\n' "# Custom upstream" "Original project notes" > "$SOURCE_ROOT/community-skill/UPSTREAM.md"
printf '%s\n' "Custom existing license" > "$SOURCE_ROOT/community-skill/LICENSE"
OUTPUT=$(run_stage_success_common community-skill community \
  --upstream-url https://example.invalid/replacement \
  --upstream-author "Replacement Author" \
  --upstream-license Apache-2.0 \
  --license-file "$SOURCE_ROOT/community-skill/LICENSE.source" \
  --patch-summary "Added local patch notes.")
COMMUNITY_TARGET=$COMMUNITY_ROOT/community-skill
assert_contains "$OUTPUT" "staged-skill: community-skill"
assert_file_contains "$COMMUNITY_TARGET/UPSTREAM.md" "Original project notes"
assert_file_contains "$COMMUNITY_TARGET/LICENSE" "Custom existing license"
assert_file_contains "$COMMUNITY_TARGET/PATCHES.md" "Added local patch notes."

new_fixture dry-run
OUTPUT=$(run_stage_success_common good-skill oceans --dry-run)
assert_contains "$OUTPUT" "dry_run: true"
assert_path_missing "$FIRST_PARTY_ROOT/good-skill"

new_fixture cross-repository-duplicate
mkdir -p "$COMMUNITY_ROOT/good-skill"
cat > "$COMMUNITY_ROOT/good-skill/SKILL.md" <<'EOF'
---
name: good-skill
description: Other repo copy.
---
EOF
git_quiet "$COMMUNITY_REPO" add .
git_quiet "$COMMUNITY_REPO" commit -m "add duplicate"
OUTPUT=$(run_stage_failure_common good-skill oceans --replace-existing)
assert_contains "$OUTPUT" "duplicate-cross-repository: good-skill"

new_fixture detached-head
git_quiet "$FIRST_PARTY_REPO" checkout -q --detach HEAD
OUTPUT=$(run_stage_failure_common good-skill oceans)
assert_contains "$OUTPUT" "target-not-main: oceans-skills"

new_fixture dirty-outside-skills
printf '%s\n' "dirty outside skills" > "$FIRST_PARTY_REPO/README.md"
OUTPUT=$(run_stage_failure_common good-skill oceans)
assert_contains "$OUTPUT" "target-dirty-outside-skills: oceans-skills"

new_fixture dirty-rename-outside-skills
printf '%s\n' "tracked readme" > "$FIRST_PARTY_REPO/README.md"
git_quiet "$FIRST_PARTY_REPO" add README.md
git_quiet "$FIRST_PARTY_REPO" commit -m "add readme"
git_quiet "$FIRST_PARTY_REPO" mv README.md skills/renamed-readme.md
OUTPUT=$(run_stage_failure_common good-skill oceans)
assert_contains "$OUTPUT" "target-dirty-outside-skills: oceans-skills"

echo "Shell stage skill test passed."
