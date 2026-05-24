# Multi-Runtime Skill Roots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shared multi-runtime skill root registry so import, stage, and install handle Codex, agents, Claude, OpenClaw, Hermes, and custom paths correctly.

**Architecture:** Create focused PowerShell and shell root resolver scripts, then wire existing commands through them. Keep GitHub repository layout runtime-neutral and keep default install conservative.

**Tech Stack:** PowerShell scripts, POSIX sh scripts, Git, existing contract test style.

---

### Task 1: Root Registry Contract Tests

**Files:**
- Create: `scripts/test-skill-roots.ps1`
- Create: `scripts/test-skill-roots.sh`

- [x] Write tests that set temporary runtime home env vars and assert root listing includes `codex`, `agents`, `claude`, `openclaw`, and `hermes`.
- [x] Assert default install target is Codex only.
- [x] Assert all-existing mode returns only existing runtime roots.
- [x] Assert explicit `custom` requires a path.
- [x] Run both tests and verify they fail because `skill-roots` scripts do not exist.

### Task 2: Root Registry Implementation

**Files:**
- Create: `scripts/skill-roots.ps1`
- Create: `scripts/skill-roots.sh`

- [x] Implement runtime definitions for Codex, agents, Claude, OpenClaw, Hermes, and custom.
- [x] Implement list mode with `runtime`, `status`, `path`, and `reason` fields.
- [x] Implement resolve mode for `scan`, `stage`, and `install`.
- [x] Run root tests and verify they pass.
- [x] Commit root registry and tests.

### Task 3: Import Multi-Root Scan

**Files:**
- Modify: `scripts/import-skills.ps1`
- Modify: `scripts/import-skills.sh`
- Modify: `scripts/test-import.ps1`
- Modify: `scripts/test-import.sh`

- [x] Add failing tests for multiple existing roots and duplicate local runtime skill names.
- [x] Update import scripts to source root registry and scan all existing roots by default.
- [x] Preserve `SourceRoot` / `--source-root` as custom single-root scan.
- [x] Print `runtime`, `source_root`, and `source_path` for every skill item.
- [x] Run import tests and verify they pass.
- [x] Commit import changes.

### Task 4: Stage Runtime Selection

**Files:**
- Modify: `scripts/stage-skill.ps1`
- Modify: `scripts/stage-skill.sh`
- Modify: `oceans.ps1`
- Modify: `oceans`
- Modify: `scripts/test-stage-skill.ps1`
- Modify: `scripts/test-stage-skill.sh`

- [x] Add failing tests for `Runtime agents` / `--runtime agents`.
- [x] Add failing tests that explicit source root wins over runtime.
- [x] Wire wrapper runtime arguments to stage scripts.
- [x] Resolve source root through root registry when runtime is supplied.
- [x] Run stage tests and verify they pass.
- [x] Commit stage changes.

### Task 5: Install Runtime Selection

**Files:**
- Modify: `scripts/install-skills.ps1`
- Modify: `scripts/install-skills.sh`
- Modify: `oceans.ps1`
- Modify: `oceans`
- Modify: `scripts/test-install-local-first.ps1`
- Modify: `scripts/test-install-local-first.sh`

- [x] Add failing tests for `Runtime claude` / `--runtime claude`.
- [x] Add failing tests for all-existing runtime install.
- [x] Keep default install as Codex only.
- [x] Write `runtime=` and `install_root=` into `.oceans-skill-source`.
- [x] Preserve local-first duplicate behavior.
- [x] Run install tests and verify they pass.
- [x] Commit install changes.

### Task 6: Status, Documentation, and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/commands.md`
- Modify: `docs/skill-sync-policy.md`

- [x] Add status tests for default, one-runtime, and all-existing runtime reports.
- [x] Wire status through the shared root registry.
- [x] Update docs with runtime root table and command examples.
- [x] Run PowerShell syntax, shell syntax, `git diff --check`.
- [x] Run all PowerShell and shell tests.
- [x] Run setup and wrapper smoke tests with temporary homes.
- [x] Review final diff for path safety and docs consistency.
- [x] Merge to main and push.
