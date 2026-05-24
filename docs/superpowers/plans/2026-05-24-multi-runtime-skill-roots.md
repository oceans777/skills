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

- [ ] Write tests that set temporary runtime home env vars and assert root listing includes `codex`, `agents`, `claude`, `openclaw`, and `hermes`.
- [ ] Assert default install target is Codex only.
- [ ] Assert all-existing mode returns only existing runtime roots.
- [ ] Assert explicit `custom` requires a path.
- [ ] Run both tests and verify they fail because `skill-roots` scripts do not exist.

### Task 2: Root Registry Implementation

**Files:**
- Create: `scripts/skill-roots.ps1`
- Create: `scripts/skill-roots.sh`

- [ ] Implement runtime definitions for Codex, agents, Claude, OpenClaw, Hermes, and custom.
- [ ] Implement list mode with `runtime`, `status`, `path`, and `reason` fields.
- [ ] Implement resolve mode for `scan`, `stage`, and `install`.
- [ ] Run root tests and verify they pass.
- [ ] Commit root registry and tests.

### Task 3: Import Multi-Root Scan

**Files:**
- Modify: `scripts/import-skills.ps1`
- Modify: `scripts/import-skills.sh`
- Modify: `scripts/test-import.ps1`
- Modify: `scripts/test-import.sh`

- [ ] Add failing tests for multiple existing roots and duplicate local runtime skill names.
- [ ] Update import scripts to source root registry and scan all existing roots by default.
- [ ] Preserve `SourceRoot` / `--source-root` as custom single-root scan.
- [ ] Print `runtime`, `source_root`, and `source_path` for every skill item.
- [ ] Run import tests and verify they pass.
- [ ] Commit import changes.

### Task 4: Stage Runtime Selection

**Files:**
- Modify: `scripts/stage-skill.ps1`
- Modify: `scripts/stage-skill.sh`
- Modify: `oceans.ps1`
- Modify: `oceans`
- Modify: `scripts/test-stage-skill.ps1`
- Modify: `scripts/test-stage-skill.sh`

- [ ] Add failing tests for `Runtime agents` / `--runtime agents`.
- [ ] Add failing tests that explicit source root wins over runtime.
- [ ] Wire wrapper runtime arguments to stage scripts.
- [ ] Resolve source root through root registry when runtime is supplied.
- [ ] Run stage tests and verify they pass.
- [ ] Commit stage changes.

### Task 5: Install Runtime Selection

**Files:**
- Modify: `scripts/install-skills.ps1`
- Modify: `scripts/install-skills.sh`
- Modify: `oceans.ps1`
- Modify: `oceans`
- Modify: `scripts/test-install-local-first.ps1`
- Modify: `scripts/test-install-local-first.sh`

- [ ] Add failing tests for `Runtime claude` / `--runtime claude`.
- [ ] Add failing tests for all-existing runtime install.
- [ ] Keep default install as Codex only.
- [ ] Write `runtime=` and `install_root=` into `.oceans-skill-source`.
- [ ] Preserve local-first duplicate behavior.
- [ ] Run install tests and verify they pass.
- [ ] Commit install changes.

### Task 6: Documentation and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/commands.md`
- Modify: `docs/skill-sync-policy.md`

- [ ] Update docs with runtime root table and command examples.
- [ ] Run PowerShell syntax, shell syntax, `git diff --check`.
- [ ] Run all PowerShell and shell tests.
- [ ] Run setup and wrapper smoke tests with temporary homes.
- [ ] Review final diff for path safety and docs consistency.
- [ ] Merge to main and push.
