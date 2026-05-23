# Skill Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe, cross-platform `stage` and `publish` commands so maintainers can upload individual local skills into oceans777 skill repositories without leaking private data or breaking submodule pins.

**Architecture:** Keep `import` report-only. Add focused `stage-skill` scripts for local-to-submodule staging and focused `publish-skills` scripts for Git validation, child-repository commits, child pushes, entry submodule pointer commits, and entry push. Maintain PowerShell and POSIX shell parity through mirrored fixtures and tests.

**Tech Stack:** PowerShell scripts, POSIX shell scripts, Git, existing `scripts/common.ps1` and `scripts/common.sh` retry helpers, temporary local Git repositories for publish tests.

---

## File Map

Create:

```text
scripts/stage-skill.ps1
scripts/stage-skill.sh
scripts/publish-skills.ps1
scripts/publish-skills.sh
scripts/test-stage-skill.ps1
scripts/test-stage-skill.sh
scripts/test-publish-skills.ps1
scripts/test-publish-skills.sh
```

Modify:

```text
oceans.ps1
oceans
README.md
docs/commands.md
docs/superpowers/specs/2026-05-23-skill-publishing-design.md
```

Verification commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-stage-skill.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-publish-skills.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-install-local-first.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-import.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-validate-duplicates.ps1
```

```sh
sh ./scripts/test-stage-skill.sh
sh ./scripts/test-publish-skills.sh
sh ./scripts/test-install-local-first.sh
sh ./scripts/test-import.sh
sh ./scripts/test-validate-duplicates.sh
```

---

### Task 1: Add Stage Contract Tests

**Files:**

```text
Create: scripts/test-stage-skill.ps1
Create: scripts/test-stage-skill.sh
```

- [ ] **Step 1: Create the PowerShell failing test**

Create `scripts/test-stage-skill.ps1` with temp roots only. It must build:

```text
<temp>/source/good-skill/SKILL.md
<temp>/source/community-skill/SKILL.md
<temp>/source/community-skill/LICENSE.source
<temp>/source/risky-skill/SKILL.md
<temp>/repo/oceans-skills/skills/
<temp>/repo/community-skills/skills/
```

The test must call:

```powershell
& "$RepoRoot\scripts\stage-skill.ps1" `
  -SourceRoot $SourceRoot `
  -Skill "good-skill" `
  -Target "oceans" `
  -FirstPartySkillsRoot $FirstPartyRoot `
  -CommunitySkillsRoot $CommunityRoot
```

Expected assertions:

```text
staged-skill: good-skill
target_repository: oceans-skills
risk_status: none detected
<temp>/repo/oceans-skills/skills/good-skill/SKILL.md exists
.oceans-skill-source does not exist in staged output
```

The same test file must also assert:

```text
.system is rejected
missing SKILL.md is rejected
secret-like text is rejected without -AllowRisk
local absolute path is rejected without -AllowRisk
files larger than 1 MB are rejected without -AllowRisk
community target without upstream/license inputs is rejected
community target with UpstreamUrl, UpstreamAuthor, UpstreamLicense, LicenseFile writes UPSTREAM.md, PATCHES.md, LICENSE
dry run prints dry_run: true and does not create a target skill directory
same skill name in the other repository is rejected even with -ReplaceExisting
target repository detached HEAD is rejected
target repository dirty outside skills/ is rejected
```

- [ ] **Step 2: Verify the PowerShell test fails before implementation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-stage-skill.ps1
```

Expected: fails because `scripts/stage-skill.ps1` does not exist.

- [ ] **Step 3: Create the POSIX shell failing test**

Create `scripts/test-stage-skill.sh` with the same fixture shape and assertions as the PowerShell test. The core success command must be:

```sh
sh "$REPO_ROOT/scripts/stage-skill.sh" \
  --source-root "$SOURCE_ROOT" \
  --skill good-skill \
  --target oceans \
  --first-party-root "$FIRST_PARTY_ROOT" \
  --community-root "$COMMUNITY_ROOT"
```

- [ ] **Step 4: Verify the POSIX test fails before implementation**

Run:

```sh
sh ./scripts/test-stage-skill.sh
```

Expected: fails because `scripts/stage-skill.sh` does not exist.

---

### Task 2: Implement Stage Scripts

**Files:**

```text
Create: scripts/stage-skill.ps1
Create: scripts/stage-skill.sh
Test: scripts/test-stage-skill.ps1
Test: scripts/test-stage-skill.sh
```

- [ ] **Step 1: Implement PowerShell argument contract**

`scripts/stage-skill.ps1` must accept:

```powershell
param(
  [string] $SourceRoot,
  [Parameter(Mandatory = $true)]
  [string] $Skill,
  [Parameter(Mandatory = $true)]
  [ValidateSet("oceans", "community")]
  [string] $Target,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,
  [switch] $AllowRisk,
  [switch] $ReplaceExisting,
  [switch] $DryRun,
  [string] $UpstreamUrl,
  [string] $UpstreamAuthor,
  [string] $UpstreamLicense,
  [string] $LicenseFile,
  [string] $PatchSummary
)
```

Default roots:

```text
SourceRoot: CODEX_HOME/skills, otherwise $HOME/.codex/skills
FirstPartySkillsRoot: repos/oceans-skills/skills
CommunitySkillsRoot: repos/community-skills/skills
```

- [ ] **Step 2: Implement PowerShell validations**

Implement functions:

```text
Resolve-DefaultSourceRoot
Test-SkillName
Test-RepositoryOnMain
Test-RepositoryDirtyOutsideSkills
Get-RiskNotes
Test-CommunityAttribution
Copy-SkillDirectory
Assert-PathInsideRoot
```

Validation outcomes must print stable status text used by tests:

```text
invalid-skill-name: <skill>
skip-system: .system
missing-source-skill: <path>
missing-skill-md: <skill>
risk-blocked: <skill>
duplicate-existing-target: <skill>
duplicate-cross-repository: <skill>
target-not-main: <repo>
target-dirty-outside-skills: <repo>
missing-community-attribution: <skill>
staged-skill: <skill>
```

- [ ] **Step 3: Implement PowerShell copy rules**

Copy recursively while excluding:

```text
.git
.oceans-skill-source
.DS_Store
Thumbs.db
.pytest_cache
__pycache__
node_modules
```

Before removing an existing target with `-ReplaceExisting`, resolve the target path and target skills root to absolute paths and verify the target path is inside the target skills root.

- [ ] **Step 4: Implement community attribution in PowerShell**

For `-Target community`:

If source already contains non-empty `UPSTREAM.md`, `PATCHES.md`, and `LICENSE`, keep them.

Otherwise require:

```text
UpstreamUrl
UpstreamAuthor
UpstreamLicense
LicenseFile path to an existing file
```

Write `UPSTREAM.md` with:

```text
# Upstream

Original repository: <UpstreamUrl>
Original author: <UpstreamAuthor>
License: <UpstreamLicense>
Imported by: oceans777
```

Write `PATCHES.md` with either `PatchSummary` or:

```text
# Patches

No local changes.
```

Copy `LicenseFile` to `LICENSE`.

- [ ] **Step 5: Implement POSIX shell script with the same contract**

`scripts/stage-skill.sh` must support:

```text
--source-root
--skill
--target
--first-party-root
--community-root
--allow-risk
--replace-existing
--dry-run
--upstream-url
--upstream-author
--upstream-license
--license-file
--patch-summary
```

The shell script must print the same stable status text as the PowerShell script.

- [ ] **Step 6: Run stage tests until green**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-stage-skill.ps1
```

Run:

```sh
sh ./scripts/test-stage-skill.sh
```

Expected: both pass.

- [ ] **Step 7: Commit stage implementation**

```powershell
git add scripts/stage-skill.ps1 scripts/stage-skill.sh scripts/test-stage-skill.ps1 scripts/test-stage-skill.sh
git commit -m "scripts: add skill staging command"
```

---

### Task 3: Add Publish Contract Tests

**Files:**

```text
Create: scripts/test-publish-skills.ps1
Create: scripts/test-publish-skills.sh
```

- [ ] **Step 1: Create local Git fixture helper**

Each publish test must create temp repositories:

```text
<temp>/remote/entry.git
<temp>/remote/oceans-skills.git
<temp>/remote/community-skills.git
<temp>/work/entry
<temp>/work/entry/repos/oceans-skills
<temp>/work/entry/repos/community-skills
```

Use local bare repositories as remotes. Do not connect to GitHub.

- [ ] **Step 2: Create PowerShell publish failing test**

`scripts/test-publish-skills.ps1` must assert:

```text
no child repo changes -> no commit
first-party child change -> child commit, child push, entry submodule pointer commit
community child change -> child commit, child push, entry submodule pointer commit
validate failure -> no child commit and no entry commit
entry repo dirty outside repos/oceans-skills and repos/community-skills -> publish stops
entry repo with only child staged skill changes -> publish continues
local branch behind origin/main -> publish stops
dry run -> no commit and no push
```

- [ ] **Step 3: Verify PowerShell publish test fails before implementation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-publish-skills.ps1
```

Expected: fails because `scripts/publish-skills.ps1` does not exist.

- [ ] **Step 4: Create and red-run POSIX publish test**

Create `scripts/test-publish-skills.sh` with the same cases and run:

```sh
sh ./scripts/test-publish-skills.sh
```

Expected: fails because `scripts/publish-skills.sh` does not exist.

---

### Task 4: Implement Publish Scripts

**Files:**

```text
Create: scripts/publish-skills.ps1
Create: scripts/publish-skills.sh
Modify: scripts/common.ps1 if a small reusable helper is needed
Modify: scripts/common.sh if a small reusable helper is needed
Test: scripts/test-publish-skills.ps1
Test: scripts/test-publish-skills.sh
```

- [ ] **Step 1: Implement PowerShell publish parameters**

`scripts/publish-skills.ps1` must accept:

```powershell
param(
  [switch] $DryRun,
  [string] $RepoRoot,
  [string] $FirstPartyRepoPath,
  [string] $CommunityRepoPath
)
```

Default paths:

```text
RepoRoot: repository root
FirstPartyRepoPath: repos/oceans-skills
CommunityRepoPath: repos/community-skills
```

- [ ] **Step 2: Implement PowerShell Git checks**

Use existing `Invoke-Git` and `Invoke-GitWithRetry`.

Checks:

```text
entry repo branch is main
child repo branches are main
each repo has an origin remote
fetch origin main succeeds with retry
local main is not behind origin/main
entry repo has no changes outside repos/oceans-skills and repos/community-skills
validate-skills.ps1 passes
```

- [ ] **Step 3: Implement PowerShell commit and push**

For each dirty child repo:

```text
git -C <child> add skills
git -C <child> commit -m "<message>"
git -C <child> push origin main
```

Then in entry repo:

```text
git add repos/oceans-skills repos/community-skills
git commit -m "repos: update skill submodules"
git push origin main
```

If no child repo changed, print:

```text
publish-no-changes
```

- [ ] **Step 4: Implement POSIX publish with the same contract**

`scripts/publish-skills.sh` must support:

```text
--dry-run
--repo-root
--first-party-repo
--community-repo
```

It must print the same status strings as PowerShell.

- [ ] **Step 5: Run publish tests until green**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-publish-skills.ps1
```

Run:

```sh
sh ./scripts/test-publish-skills.sh
```

Expected: both pass.

- [ ] **Step 6: Commit publish implementation**

```powershell
git add scripts/publish-skills.ps1 scripts/publish-skills.sh scripts/test-publish-skills.ps1 scripts/test-publish-skills.sh scripts/common.ps1 scripts/common.sh
git commit -m "scripts: add skill publishing command"
```

---

### Task 5: Wire Entrypoints And Docs

**Files:**

```text
Modify: oceans.ps1
Modify: oceans
Modify: README.md
Modify: docs/commands.md
```

- [ ] **Step 1: Add PowerShell entrypoint commands**

Update `oceans.ps1` command validation to include:

```text
stage
publish
```

Forward `stage` parameters to `scripts/stage-skill.ps1`. Forward `publish` to `scripts/publish-skills.ps1`.

- [ ] **Step 2: Add POSIX entrypoint commands**

Update `oceans` case statement:

```sh
stage)
  sh "$REPO_ROOT/scripts/stage-skill.sh" "$@"
  ;;
publish)
  sh "$REPO_ROOT/scripts/publish-skills.sh" "$@"
  ;;
```

- [ ] **Step 3: Update docs**

Document maintainer flow:

```text
./oceans import
./oceans stage --source-root "$HOME/.codex/skills" --skill frontend-design --target oceans
./oceans publish
```

Document safety defaults:

```text
explicit single skill only
no default overwrite
no default risky content
community requires real upstream/license records
publish never force-pushes
```

- [ ] **Step 4: Run entrypoint smoke tests**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\oceans.ps1 help
```

Run:

```sh
sh ./oceans help
```

Expected: both help outputs include `stage` and `publish`.

- [ ] **Step 5: Commit entrypoint and docs**

```powershell
git add oceans.ps1 oceans README.md docs/commands.md
git commit -m "docs: document skill publishing commands"
```

---

### Task 6: Full Verification And Push

**Files:**

```text
All changed files
```

- [ ] **Step 1: Run syntax checks**

PowerShell:

```powershell
$ErrorActionPreference = 'Stop'
$HasErrors = $false
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
  $Tokens = $null
  $ParseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref] $Tokens, [ref] $ParseErrors) | Out-Null
  if ($ParseErrors.Count -gt 0) {
    $HasErrors = $true
    Write-Error "$($_.FullName): $($ParseErrors | Out-String)"
  }
}
if ($HasErrors) { exit 1 }
Write-Host 'PowerShell syntax passed.'
```

Shell:

```powershell
$ErrorActionPreference = 'Stop'
$Sh = 'C:\Program Files\Git\bin\sh.exe'
$Files = @('setup.sh', 'oceans') + @(Get-ChildItem -Path scripts -Filter *.sh | ForEach-Object { $_.FullName })
foreach ($File in $Files) {
  & $Sh -n $File
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Write-Host 'Shell syntax passed.'
```

- [ ] **Step 2: Run all script tests**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-stage-skill.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-publish-skills.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-install-local-first.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-import.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-validate-duplicates.ps1
```

Run:

```sh
sh ./scripts/test-stage-skill.sh
sh ./scripts/test-publish-skills.sh
sh ./scripts/test-install-local-first.sh
sh ./scripts/test-import.sh
sh ./scripts/test-validate-duplicates.sh
```

- [ ] **Step 3: Run setup and wrapper smoke tests with temporary CODEX_HOME**

Run:

```powershell
$TestRoot = Join-Path $env:TEMP ('oceans-publish-verify-' + [Guid]::NewGuid().ToString('N'))
$OldCodeHome = $env:CODEX_HOME
$env:CODEX_HOME = Join-Path $TestRoot 'codex'
try {
  & .\setup.ps1
  & .\oceans.ps1 validate
  & .\oceans.ps1 install
} finally {
  if ($null -eq $OldCodeHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $OldCodeHome }
  if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}
```

Run:

```sh
test_root=$(mktemp -d)
CODEX_HOME="$test_root/codex" sh ./setup.sh
CODEX_HOME="$test_root/codex" sh ./oceans validate
CODEX_HOME="$test_root/codex" sh ./oceans install
rm -rf "$test_root"
```

- [ ] **Step 4: Check repository cleanliness**

Run:

```powershell
git diff --check
git status --short --branch
git -C repos/oceans-skills status --short
git -C repos/community-skills status --short
```

Expected: no submodule pollution from tests.

- [ ] **Step 5: Push final commits**

Run:

```powershell
git push git@github.com:oceans777/skills.git main:main
git fetch git@github.com:oceans777/skills.git main:refs/remotes/origin/main
git status --short --branch
```

Expected:

```text
## main...origin/main
```
